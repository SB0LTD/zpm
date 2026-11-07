//! LFM3-Audio's speech codec on any GPU (lfm3_any_codec) against the CPU's
//! (lfm3_audio_gen.decode). First lfm3_kir_codec's kernels against
//! lfm3_audio_ops on synthetic rows, on the reference interpreter (an
//! ideal GPU and the Adreno's caps) and through kir_sm120 on the emulated
//! RTX; then the whole codec with the real mmproj (skipped when it is not
//! on this machine): two utterances streamed frame by frame, the polar
//! spectrum and the PCM against the CPU's, and the windows handed from the
//! GPU to the CPU and back.

const std = @import("std");
const gguf = @import("gguf");
const gpu = @import("gpu");
const nvidia = @import("nvidia");
const gen = @import("lfm3_audio_gen");
const ops = @import("lfm3_audio_ops");
const ck = @import("lfm3_kir_codec");
const any = @import("lfm3_any");
const any_codec = @import("lfm3_any_codec");

const kir = gpu.kir;
const BINS = gen.BINS;

/// The Surface's Adreno as measured: mad rounds twice, no fused FMA,
/// denormals flushed, waves of 64.
fn adrenoCaps() gpu.Caps {
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.denormals = .flush;
    caps.subgroup = 64;
    return caps;
}

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn unit(seed: *u32) f32 {
    return @as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0 - 0.5;
}

fn bitsEqual(a: []const f32, b: []const f32) usize {
    var same: usize = 0;
    for (a, b) |x, y| {
        if (@as(u32, @bitCast(x)) == @as(u32, @bitCast(y))) same += 1;
    }
    return same;
}

/// The largest difference, relative to the largest magnitude (infinite
/// where one side is not finite and the other differs: @max would drop a
/// NaN).
fn relative(a: []const f32, b: []const f32) f64 {
    var scale: f64 = 0;
    for (a) |v| scale = @max(scale, @abs(@as(f64, v)));
    var worst: f64 = 0;
    for (a, b) |x, y| {
        if (@as(u32, @bitCast(x)) == @as(u32, @bitCast(y))) continue;
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return std.math.inf(f64);
        worst = @max(worst, @abs(@as(f64, x) - y));
    }
    return worst / @max(scale, 1e-30);
}

// ── The kernels, on synthetic rows ──────────────────────────────────────────

const K = struct {
    var insts: [16384]kir.Inst = undefined;
    var tys: [16384]kir.Ty = undefined;
    var interp_mem: [16 << 20]u8 align(64) = undefined;
    var compile_mem: [8 << 20]u8 align(64) = undefined;
    var code: [512 << 10]u8 align(16) = undefined;
};

fn storage() kir.Storage {
    return .{ .insts = &K.insts, .tys = &K.tys };
}

/// The emulated RTX (kir_sm120 in sm120_emu, its hazard checks on).
const Rtx = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
    var made: ?gpu.Device = null;

    /// (made once: Emu.device sets its adapter up afresh)
    fn device() gpu.Device {
        if (made) |d| return d;
        dev.init(&arena, &view, &emu_work);
        made = dev.device();
        return made.?;
    }
};

const Where = enum { ideal, adreno, rtx };

/// `k` once on `where`, its bindings' bytes in `bindings` (every one read
/// back after the run).
fn runOn(where: Where, k: *const kir.Kernel, groups: [3]u32, bindings: []const []u8, params: []const u32) !void {
    switch (where) {
        .ideal, .adreno => {
            var w = gpu.Work.init(&K.interp_mem);
            var trap: gpu.interp.Trap = .{};
            _ = gpu.interp.runKernel(k, if (where == .ideal) gpu.interp_caps else adrenoCaps(), groups, bindings, params, &w, &trap) catch |e| {
                std.debug.print("{s}: {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d}\n", .{ k.name, @errorName(e), @tagName(trap.what), trap.pc, trap.group, trap.thread, trap.binding, trap.offset });
                return e;
            };
        },
        .rtx => {
            const d = Rtx.device();
            var cw = gpu.Work.init(&K.compile_mem);
            const bin = try gpu.compile(k, d.caps, &cw, &K.code);
            const prog = try d.load(&bin);
            defer d.unload(&prog);
            var bufs: [8]gpu.Buffer = undefined;
            for (bindings, 0..) |bytes, i| {
                bufs[i] = try d.alloc(std.mem.alignForward(u64, @max(bytes.len, 16), 16), .host);
                @memcpy(bufs[i].cpu[0..bytes.len], bytes);
                d.toDevice(bufs[i], 0, bufs[i].bytes);
            }
            defer for (bufs[0..bindings.len]) |b| d.free(b);
            const fence = try d.run(&.{.{ .prog = &prog, .groups = groups, .buffers = bufs[0..bindings.len], .params = params }});
            d.wait(fence, 60_000_000) catch |e| {
                var buf: [512]u8 = undefined;
                std.debug.print("emulated RTX, {s}: {s}: {s}\n", .{ k.name, @errorName(e), Rtx.dev.explain(&buf) });
                return e;
            };
            for (bindings, 0..) |bytes, i| {
                d.fromDevice(bufs[i], 0, bufs[i].bytes);
                @memcpy(bytes, bufs[i].cpu[0..bytes.len]);
            }
        },
    }
}

fn capsOf(where: Where) gpu.Caps {
    return switch (where) {
        .ideal => gpu.interp_caps,
        .adreno => adrenoCaps(),
        .rtx => Rtx.device().caps,
    };
}

// The codec's attention shapes: 8 heads of 64, 2 KV heads, a window of 29.
const HEADS = 8;
const KV_HEADS = 2;
const HS = 64;
const PREFIX = any_codec.PREFIX;
const MAX_T = 24;

const A = struct {
    var query: [MAX_T * HEADS * HS]f32 = undefined;
    var keys: [(PREFIX + MAX_T) * KV_HEADS * HS]f32 = undefined;
    var values: [(PREFIX + MAX_T) * KV_HEADS * HS]f32 = undefined;
    var gate: [MAX_T * HEADS]f32 = undefined;
    var cpu: [MAX_T * HEADS * HS]f32 = undefined;
    var got: [MAX_T * HEADS * HS]f32 = undefined;
};

/// lfm3_audio_gen's AttendTask with a window, as the CPU runs it.
fn attendCpu(tokens: usize, base: usize, out: []f32) void {
    var scratch: [2 * ck.MAX_ROW]f32 = undefined;
    const width = HEADS * HS;
    const group = HEADS / KV_HEADS;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(HS)));
    const row = PREFIX + tokens;
    const earliest = if (base < PREFIX) PREFIX - base else 0;
    for (0..tokens) |t| for (0..HEADS) |head| {
        const o = out[t * width + head * HS ..][0..HS];
        ops.attendHeadGgml(A.query[t * width + head * HS ..][0..HS], &A.keys, &A.values, KV_HEADS * HS, (head / group) * HS, row, @max(t, earliest), PREFIX + t, scale, &scratch, o);
        const factor = ops.sigmoid(A.gate[t * HEADS + head]);
        for (o) |*v| v.* *= factor;
    };
}

fn attendCase(where: Where, tokens: u32, base: u32, seed0: u32) !void {
    var seed = seed0;
    const width = HEADS * HS;
    // (queries and keys as RMS-normed rows are: about unit size; a few
    // large scores so the softmax has a real maximum)
    for (A.query[0 .. tokens * width]) |*v| v.* = unit(&seed) * 6;
    for (A.keys[0 .. (PREFIX + tokens) * KV_HEADS * HS]) |*v| v.* = unit(&seed) * 3;
    for (A.values[0 .. (PREFIX + tokens) * KV_HEADS * HS]) |*v| v.* = unit(&seed) * 2;
    for (A.gate[0 .. tokens * HEADS]) |*v| v.* = unit(&seed) * 8;
    attendCpu(tokens, base, &A.cpu);
    @memset(&A.got, 0);
    var k = try ck.attendWindow(storage(), capsOf(where), HS, true);
    const p = ck.WindowParams{ .heads = HEADS, .group_log2 = 2, .tokens = tokens, .prefix = PREFIX, .earliest = if (base < PREFIX) PREFIX - base else 0, .scale = 1.0 / @sqrt(@as(f32, HS)) };
    try runOn(where, &k, ck.windowGroups(HEADS, tokens), &.{
        std.mem.sliceAsBytes(A.query[0 .. tokens * width]),
        std.mem.sliceAsBytes(A.keys[0 .. (PREFIX + tokens) * KV_HEADS * HS]),
        std.mem.sliceAsBytes(A.values[0 .. (PREFIX + tokens) * KV_HEADS * HS]),
        std.mem.sliceAsBytes(A.gate[0 .. tokens * HEADS]),
        std.mem.sliceAsBytes(A.got[0 .. tokens * width]),
    }, &p.words());
    const n = tokens * width;
    const same = bitsEqual(A.cpu[0..n], A.got[0..n]);
    if (same != n) {
        std.debug.print("attendWindow ({s}, {d} positions from {d}): {d} of {d} the CPU's bits, within {e}\n", .{ @tagName(where), tokens, base, same, n, relative(A.cpu[0..n], A.got[0..n]) });
        for (0..n) |i| if (@as(u32, @bitCast(A.cpu[i])) != @as(u32, @bitCast(A.got[i]))) {
            std.debug.print("  {d}: cpu {e} gpu {e}\n", .{ i, A.cpu[i], A.got[i] });
            break;
        };
        return error.TestUnexpectedResult;
    }
}

test "attendWindow: the codec's windowed attention, the CPU's bits (young and old streams, one to four frames), on the interpreter, the Adreno's caps and the emulated RTX" {
    // (positions 6, 12, 18, 24; the stream starting, inside its first
    // window, and long past it)
    const cases = [_][2]u32{ .{ 6, 0 }, .{ 6, 12 }, .{ 12, 24 }, .{ 6, 31 }, .{ 24, 100 } };
    for ([_]Where{ .ideal, .adreno }) |where| {
        for (cases, 0..) |cs, i| try attendCase(where, cs[0], cs[1], @intCast(17 + i));
    }
    for (cases[0..3], 0..) |cs, i| try attendCase(.rtx, cs[0], cs[1], @intCast(17 + i));
}

test "fsq and upsample: a frame's codes to its rows, the CPU's bits, on the interpreter, the Adreno's caps and the emulated RTX" {
    const levels = 4;
    const codes_n = 64;
    const width = 256;
    const inputs = gen.CODEBOOKS * levels;
    const frames = 3;
    const S = struct {
        // the model's part: codebook, projection, its bias (one binding)
        var model: [codes_n * levels + width * inputs + width]f32 = undefined;
        var codes: [frames * gen.CODEBOOKS]i32 = undefined;
        var cpu: [frames * width]f32 = undefined;
        var got: [frames * width]f32 = undefined;
        var up: [frames * 6 * width]f32 = undefined;
    };
    var seed: u32 = 5;
    for (&S.model) |*v| v.* = unit(&seed) * 2;
    for (&S.codes) |*c| c.* = @intCast(lcg(&seed) % codes_n);
    const codebook = S.model[0 .. codes_n * levels];
    const w = S.model[codes_n * levels ..][0 .. width * inputs];
    const bias = S.model[codes_n * levels + width * inputs ..][0..width];
    for (0..frames) |f| {
        var x: [inputs]f32 = undefined;
        for (0..gen.CODEBOOKS) |book| {
            const code: usize = @intCast(S.codes[f * gen.CODEBOOKS + book]);
            @memcpy(x[book * levels ..][0..levels], codebook[code * levels ..][0..levels]);
        }
        ops.linearF32(w, inputs, &x, 1, S.cpu[f * width ..][0..width], bias);
    }
    for ([_]Where{ .ideal, .adreno, .rtx }) |where| {
        var k = try ck.fsq(storage(), capsOf(where));
        @memset(&S.got, 0);
        try runOn(where, &k, ck.fsqGroups(width, frames), &.{ std.mem.sliceAsBytes(S.codes[0..]), std.mem.sliceAsBytes(S.model[0..]), std.mem.sliceAsBytes(S.got[0..]) }, &.{ levels, width, 0, codes_n * levels * 4, (codes_n * levels + width * inputs) * 4 });
        try std.testing.expectEqual(S.cpu.len, bitsEqual(&S.cpu, &S.got));
        // the rows (as the in-projection's output) plus the bias, each six times
        var u = try ck.upsample(storage(), capsOf(where));
        @memset(&S.up, 0);
        try runOn(where, &u, ck.upsampleGroups(width, 6, frames), &.{ std.mem.sliceAsBytes(S.cpu[0..]), std.mem.sliceAsBytes(S.model[0..]), std.mem.sliceAsBytes(S.up[0..]) }, &.{ width, 6, (codes_n * levels + width * inputs) * 4 });
        for (0..frames * 6) |p| for (0..width) |i| {
            try std.testing.expectEqual(S.cpu[(p / 6) * width + i] + bias[i], S.up[p * width + i]);
        };
    }
}

// ── The codec, with the real mmproj ─────────────────────────────────────────

const MMPROJ_PATH = "C:/Just-Things/models/lfm3/mmproj-LFM3-Audio-2B-Q8_0.gguf";
const CAPACITY = 1024;
const L = gen.lfm3_audio_limits;
const Codec = any_codec.Codec(CAPACITY);

var index: gguf.Index(CAPACITY) = .{};
var plan: gen.Plan = .{};
var cpu_state: gen.CodecState(L) = .{};
var gpu_state: gen.CodecState(L) = .{};
var cpu_work: gen.CodecWorkspace(L) = .{};
var pcm_cpu: [L.frames * gen.SAMPLES_PER_FRAME + gen.FFT_SIZE]f32 = undefined;
var pcm_gpu: [L.frames * gen.SAMPLES_PER_FRAME + gen.FFT_SIZE]f32 = undefined;
var mem: [32 << 20]u8 align(4096) = undefined;
var interp_work: [16 << 20]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var work: any.Work = .{};

const Memory = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, len: usize, alignment: usize) ?[*]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or len > self.bytes.len - offset or alignment == 0) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Memory) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};

/// What a run of frames showed: the worst relative difference of the polar
/// spectrum, its bits, and the GPU's work a frame.
const Tally = struct {
    worst: f64 = 0,
    same: usize = 0,
    values: usize = 0,
    frames: usize = 0,
    lane_ops: u64 = 0,
    dispatches: u32 = 0,
};

/// The PCM samples compared, and those with the CPU's bits.
var pcm_values: usize = 0;
var pcm_same: usize = 0;

fn countPcm(n_cpu: usize, n_gpu: usize) void {
    pcm_values += n_cpu;
    pcm_same += bitsEqual(pcm_cpu[0..n_cpu], pcm_gpu[0..@min(n_cpu, n_gpu)]);
}

fn failure(cd: *const Codec, e: anyerror) anyerror {
    std.debug.print("GPU codec: {s} (device: {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d}; compile: {s})\n", .{
        @errorName(e),
        if (emu.last_error) |x| @errorName(x) else "-",
        @tagName(emu.trap.what),
        emu.trap.pc,
        emu.trap.group,
        emu.trap.thread,
        emu.trap.binding,
        emu.trap.offset,
        if (cd.compile_error) |x| @errorName(x) else "-",
    });
    return e;
}

/// Random valid codes (no end code) for `frames` frames.
fn makeCodes(seed: *u32, out: []i32) void {
    for (out) |*c| c.* = @intCast(lcg(seed) % @as(u32, @intCast(plan.vocabulary - 1)));
}

/// One decode call on both, compared: the polar spectrum within
/// `tolerance` (0: every bit), the PCM the same samples.
fn step(src: gguf.Source, cd: *Codec, codes: []const i32, tolerance: f64, tally: *Tally) !void {
    const n_cpu = try gen.decode(CAPACITY, L, src, &index, &plan, &cpu_state, &cpu_work, codes, &pcm_cpu, .{});
    const ops_before = emu.total.lane_ops;
    const n_gpu = cd.decode(L, &gpu_state, codes, &pcm_gpu) catch |e| return failure(cd, e);
    const frames = codes.len / gen.CODEBOOKS;
    tally.lane_ops += emu.total.lane_ops - ops_before;
    tally.frames += frames;
    tally.dispatches = cd.dispatches;
    const n = frames * gen.FRAME_STACK * 2 * BINS;
    const want = cpu_work.polar[0..n];
    const got = cd.polar();
    try std.testing.expectEqual(n, got.len);
    const rel = relative(want, got);
    tally.worst = @max(tally.worst, rel);
    tally.same += bitsEqual(want, got);
    tally.values += n;
    if (!(rel <= tolerance)) {
        std.debug.print("polar spectrum at position {d}: within {e} of the CPU's, {d} of {d} its bits\n", .{ cpu_state.position, rel, bitsEqual(want, got), n });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(n_cpu, n_gpu);
    try std.testing.expectEqual(cpu_state.position, gpu_state.position);
    countPcm(n_cpu, n_gpu);
    if (tolerance == 0) {
        try std.testing.expectEqual(n_cpu, bitsEqual(pcm_cpu[0..n_cpu], pcm_gpu[0..n_gpu]));
    } else {
        try std.testing.expect(relative(pcm_cpu[0..n_cpu], pcm_gpu[0..n_gpu]) <= 1e-4);
    }
}

/// Every bit the same (tolerance 0), or within `tolerance` relative.
fn sameWithin(want: []const f32, got: []const f32, tolerance: f64, what: []const u8) !void {
    const rel = relative(want, got);
    if (rel <= tolerance) return;
    std.debug.print("{s}: within {e}, {d} of {d} the CPU's bits\n", .{ what, rel, bitsEqual(want, got), want.len });
    return error.TestUnexpectedResult;
}

fn finishBoth(cd: *Codec, tolerance: f64) !void {
    const n_cpu = try gen.finish(L, &cpu_state, &pcm_cpu);
    const n_gpu = try cd.finish(L, &gpu_state, &pcm_gpu);
    try std.testing.expectEqual(n_cpu, n_gpu);
    countPcm(n_cpu, n_gpu);
    if (tolerance == 0) {
        try std.testing.expectEqual(n_cpu, bitsEqual(pcm_cpu[0..n_cpu], pcm_gpu[0..n_gpu]));
    } else {
        try std.testing.expect(relative(pcm_cpu[0..n_cpu], pcm_gpu[0..n_gpu]) <= 1e-4);
    }
    try std.testing.expectEqual(@as(usize, 0), gpu_state.position);
}

/// Two utterances on the GPU against the CPU: the first `single` frames one
/// call each then two frames in one call, finished; the second after the
/// reset, a frame on the GPU, the windows handed to the CPU for the next,
/// then the GPU again from the CPU's state.
fn codecAgainstCpu(where: gpu.Caps, src: gguf.Source, single: usize, tolerance: f64) !void {
    emu = gpu.EmuDevice.init(where, &mem, &interp_work);
    var cd = Codec.init(emu.device(), &plan, &index, src, .{}, &work) catch |e| {
        std.debug.print("codec init: {s} (compile: {s})\n", .{ @errorName(e), "-" });
        return e;
    };
    defer cd.deinit();
    try std.testing.expect(cd.imported);
    cpu_state.reset();
    cd.reset(L, &gpu_state);
    pcm_values = 0;
    pcm_same = 0;
    var seed: u32 = 2024;
    var codes: [2 * gen.CODEBOOKS]i32 = undefined;
    var tally = Tally{};
    var one = Tally{};
    for (0..single) |_| {
        makeCodes(&seed, codes[0..gen.CODEBOOKS]);
        try step(src, &cd, codes[0..gen.CODEBOOKS], tolerance, &one);
    }
    makeCodes(&seed, codes[0 .. 2 * gen.CODEBOOKS]);
    try step(src, &cd, codes[0 .. 2 * gen.CODEBOOKS], tolerance, &tally);
    const two_dispatches = tally.dispatches;
    try finishBoth(&cd, tolerance);
    // the second utterance
    makeCodes(&seed, codes[0..gen.CODEBOOKS]);
    try step(src, &cd, codes[0..gen.CODEBOOKS], tolerance, &one);
    // the GPU's windows to the CPU, which decodes the next frame
    try cd.save(L, &gpu_state);
    try sameWithin(cpu_state.conv[0..], gpu_state.conv[0..], tolerance, "conv state");
    try sameWithin(cpu_state.keys[0..], gpu_state.keys[0..], tolerance, "window keys");
    try sameWithin(cpu_state.values[0..], gpu_state.values[0..], tolerance, "window values");
    makeCodes(&seed, codes[0..gen.CODEBOOKS]);
    const a = try gen.decode(CAPACITY, L, src, &index, &plan, &cpu_state, &cpu_work, codes[0..gen.CODEBOOKS], &pcm_cpu, .{});
    const b = try gen.decode(CAPACITY, L, src, &index, &plan, &gpu_state, &cpu_work, codes[0..gen.CODEBOOKS], &pcm_gpu, .{});
    try std.testing.expectEqual(a, b);
    try sameWithin(pcm_cpu[0..a], pcm_gpu[0..b], if (tolerance == 0) 0 else 1e-4, "the CPU's frame after the hand-over");
    // and the GPU again, from the CPU's state
    makeCodes(&seed, codes[0..gen.CODEBOOKS]);
    try step(src, &cd, codes[0..gen.CODEBOOKS], tolerance, &one);
    try finishBoth(&cd, tolerance);
    tally.worst = @max(tally.worst, one.worst);
    std.debug.print("codec ({s}): polar spectrum within {e} of the CPU's, {d} of {d} its bits, the PCM {d} of {d} samples the CPU's bits; a frame: {d} dispatches, {d} lane-ops ({d} dispatches for two frames)\n", .{
        if (where.fused_fma) "fused" else "unfused",
        tally.worst,
        tally.same + one.same,
        tally.values + one.values,
        pcm_same,
        pcm_values,
        one.dispatches,
        one.lane_ops / one.frames,
        two_dispatches,
    });
}

test "LFM3-Audio's codec on the GPU (when its mmproj is here): two utterances frame by frame, the CPU's polar spectrum and PCM, the windows handed over both ways" {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, MMPROJ_PATH, .{}) catch return error.SkipZigTest;
    defer file.close(io);
    const size = try file.length(io);
    var mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(io);
    const memory = Memory{ .bytes = mapping.memory };
    const src = memory.source();
    try gguf.parse(CAPACITY, src, &index);
    try gen.build(CAPACITY, src, &index, &plan);
    try gen.checkLimits(L, &plan);
    const cs = &plan.codec;
    std.debug.print("codec: {d} layers ({d} conv, {d} attention), hidden {d}, ff {d}, {d} heads of {d} ({d} KV), kernel {d}, {d} levels\n", .{ cs.layer_count, cs.conv_layer_count, cs.attention_layer_count, cs.hidden, cs.feed_forward, cs.heads, cs.head_size, cs.kv_heads, cs.kernel, plan.levels });
    // a GPU that fuses (the RTX): the CPU's bits
    try codecAgainstCpu(gpu.interp_caps, src, 4, 0);
    // the Adreno's measured caps: Builder.fma's exact emulation, within 1e-6
    try codecAgainstCpu(adrenoCaps(), src, 2, 1e-6);
}
