//! LFM3-Audio's hearing encoder on any GPU (lfm3_any_hear over a
//! gpu.Device) against the CPU's (lfm3_audio_encoder), with the real
//! mmproj when it is here: a synthetic clip through the mel front end,
//! streamed in chunks on the reference EmuDevice, under an ideal GPU's caps
//! and the Adreno's (no fused FMA, mad rounded twice, subgroups of 64): the
//! CPU's rows to the bit under both; the stream's state handed to the CPU
//! (the CPU's own, bit for bit) and back; a device lost mid-call leaves the
//! stream as it was.
//! Then the encoder's new kernels (lfm3_kir_hear) on the emulated RTX
//! (kir_sm120, sm120_emu) and the emulated Adreno (kir_ir3, ir3_emu), bit
//! for bit against the interpreter under the same caps; and GELU against
//! the CPU's ops.geluErf.

const std = @import("std");
const gguf = @import("gguf");
const gpu = @import("gpu");
const nvidia = @import("nvidia");
const enc = @import("lfm3_audio_encoder");
const ops = @import("lfm3_audio_ops");
const mel = @import("lfm3_audio_mel");
const any = @import("lfm3_any");
const lk = @import("lfm3_kir");
const hear = @import("lfm3_kir_hear");
const any_hear = @import("lfm3_any_hear");

const kir = gpu.kir;
const MMPROJ_PATH = "C:/Just-Things/models/lfm3/mmproj-LFM3-Audio-2B-Q8_0.gguf";
const CAPACITY = 1024;
const LIMITS = enc.lfm3_audio_limits;
/// Output rows a GPU call makes at most here (the scratch's size).
const POSITIONS = 8;
const Encoder = any_hear.Encoder(CAPACITY);

var audio_index: gguf.Index(CAPACITY) = .{};
var audio_plan: enc.Plan = .{};
var cpu_state: enc.State(LIMITS) = .{};
var cpu_work: enc.Workspace(LIMITS) = .{};
var handed: enc.State(LIMITS) = .{};
var mem: [48 << 20]u8 align(4096) = undefined;
var interp_work: [16 << 20]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var work: any.Work = .{};

const MAX_FRAMES = 64;
var clip_frames: [MAX_FRAMES * mel.MELS]f32 = undefined;
var cpu_rows: [MAX_FRAMES * 2048]f32 = undefined;
var gpu_rows: [MAX_FRAMES * 2048]f32 = undefined;
var mel_work: mel.Workspace = .{};
var samples: [400 + MAX_FRAMES * 160]f32 = undefined;

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

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn unit(seed: *u32) f32 {
    return @as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0 - 0.5;
}

/// A clip of `frames` mel frames: a rising tone with harmonics, a vowel-like
/// buzz and noise, through the mel front end (llama.cpp's).
fn makeClip(frames: usize) ![]const f32 {
    const n = 400 + (frames - 1) * 160;
    var seed: u32 = 99;
    for (samples[0..n], 0..) |*v, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / 16000.0;
        const f0 = 180.0 + 900.0 * t;
        var s: f32 = 0.3 * @sin(2.0 * std.math.pi * f0 * t);
        s += 0.15 * @sin(2.0 * std.math.pi * 2.0 * f0 * t + 0.3);
        s += 0.08 * @sin(2.0 * std.math.pi * 3.1 * f0 * t);
        s += 0.05 * @sin(2.0 * std.math.pi * 120.0 * t) * @sin(2.0 * std.math.pi * 700.0 * t);
        v.* = s + 0.02 * unit(&seed);
    }
    const count = try mel.compute(samples[0..n], &clip_frames, &mel_work);
    try std.testing.expectEqual(frames, count);
    return clip_frames[0 .. count * mel.MELS];
}

fn failure(e: anyerror, what: []const u8, encoder: ?*const Encoder) anyerror {
    std.debug.print("{s}: {s} (device {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d}; compile {s})\n", .{
        what,
        @errorName(e),
        if (emu.last_error) |x| @errorName(x) else "-",
        @tagName(emu.trap.what),
        emu.trap.pc,
        emu.trap.group,
        emu.trap.thread,
        emu.trap.binding,
        emu.trap.offset,
        if (encoder) |en| (if (en.compile_error) |x| @errorName(x) else "-") else "-",
    });
    return e;
}

/// The emulated GPU, whose `fail_in`th wait from now reports the device
/// lost (after the run has done its writes).
const Flaky = struct {
    inner: gpu.Device,
    fail_in: u32 = 0,

    fn device(fl: *Flaky) gpu.Device {
        return .{ .ctx = fl, .vtable = &vtable, .caps = fl.inner.caps };
    }
    const vtable = gpu.Device.VTable{
        .alloc = alloc,
        .free = free,
        .import = import,
        .toDevice = toDevice,
        .fromDevice = fromDevice,
        .load = load,
        .unload = unload,
        .run = run,
        .wait = wait,
        .done = done,
        .lastRunNs = lastRunNs,
    };
    fn of(ctx: *anyopaque) *Flaky {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, bytes: u64, kind: gpu.Kind) ?gpu.Buffer {
        return of(ctx).inner.vtable.alloc(of(ctx).inner.ctx, bytes, kind);
    }
    fn free(ctx: *anyopaque, b: gpu.Buffer) void {
        of(ctx).inner.free(b);
    }
    fn import(ctx: *anyopaque, cpu: []u8) ?gpu.Buffer {
        return of(ctx).inner.import(cpu);
    }
    fn toDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        of(ctx).inner.toDevice(b, off, len);
    }
    fn fromDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        of(ctx).inner.fromDevice(b, off, len);
    }
    fn load(ctx: *anyopaque, bin: *const gpu.Binary) gpu.Error!gpu.Program {
        return of(ctx).inner.load(bin);
    }
    fn unload(ctx: *anyopaque, prog: *const gpu.Program) void {
        of(ctx).inner.unload(prog);
    }
    fn run(ctx: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        return of(ctx).inner.run(ds);
    }
    fn wait(ctx: *anyopaque, fence: gpu.Fence, timeout_us: u64) gpu.Error!void {
        const fl = of(ctx);
        if (fl.fail_in > 0) {
            fl.fail_in -= 1;
            if (fl.fail_in == 0) {
                fl.inner.wait(fence, timeout_us) catch {};
                return error.DeviceLost;
            }
        }
        return fl.inner.wait(fence, timeout_us);
    }
    fn done(ctx: *anyopaque, fence: gpu.Fence) bool {
        return of(ctx).inner.done(fence);
    }
    fn lastRunNs(ctx: *anyopaque) u64 {
        return of(ctx).inner.lastRunNs();
    }
};

/// Rows compared: the count of identical bits and the largest difference
/// relative to the largest magnitude; over `tolerance` fails.
fn compareRows(what: []const u8, cpu: []const f32, g: []const f32, tolerance: f64) !f64 {
    var scale: f64 = 0;
    var worst: f64 = 0;
    var exact: usize = 0;
    for (cpu, g) |a, b| {
        scale = @max(scale, @abs(@as(f64, a)));
        worst = @max(worst, @abs(@as(f64, a) - b));
        if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) exact += 1;
    }
    const rel = worst / @max(scale, 1e-30);
    std.debug.print("  {s}: {d} of {d} values the CPU's bits, within {e} (of {e})\n", .{ what, exact, cpu.len, rel, scale });
    if (!(rel <= tolerance)) {
        var shown: usize = 0;
        for (cpu, g, 0..) |a, b, i| {
            if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) continue;
            std.debug.print("    {d}: cpu {e} gpu {e}\n", .{ i, a, b });
            shown += 1;
            if (shown == 12) break;
        }
        return error.TestUnexpectedResult;
    }
    return rel;
}

fn expectSameState(gpu_state: *const enc.State(LIMITS), cpu: *const enc.State(LIMITS)) !void {
    const p = &audio_plan;
    try std.testing.expectEqual(cpu.position, gpu_state.position);
    const f = p.mels;
    const c = p.channels;
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.ds0[0..f]), std.mem.sliceAsBytes(gpu_state.ds0[0..f])));
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.ds1[0 .. f / 2 * c]), std.mem.sliceAsBytes(gpu_state.ds1[0 .. f / 2 * c])));
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.ds2[0 .. f / 4 * c]), std.mem.sliceAsBytes(gpu_state.ds2[0 .. f / 4 * c])));
    const conv_n = p.conv_layer_count * (p.kernel - 1) * p.hidden;
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.conv[0..conv_n]), std.mem.sliceAsBytes(gpu_state.conv[0..conv_n])));
    for (0..p.attention_layer_count) |slot| {
        const at = slot * (LIMITS.window - 1) * LIMITS.kv_width;
        const len = (p.window - 1) * p.kvWidth();
        try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.keys[at..][0..len]), std.mem.sliceAsBytes(gpu_state.keys[at..][0..len])));
        try std.testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(cpu.values[at..][0..len]), std.mem.sliceAsBytes(gpu_state.values[at..][0..len])));
    }
}

/// The clip in `chunks` on the CPU and on an EmuDevice of `caps`, rows
/// compared after every chunk (chunk `lost_at` first tried on a device that
/// is lost in the call's second run); the GPU's state then handed to the
/// CPU (with `tolerance` 0: the CPU's own, bit for bit) and, with
/// `takeover`, the CPU's state handed to a new GPU stream for the rest.
fn hearAgainstCpu(caps: gpu.Caps, src: gguf.Source, frames: []const f32, chunks: []const usize, tolerance: f64, lost_at: ?usize, takeover: bool) !void {
    const p = &audio_plan;
    const f = p.mels;
    const width = p.projection;
    emu = gpu.EmuDevice.init(caps, &mem, &interp_work);
    var flaky = Flaky{ .inner = emu.device() };
    var encoder = Encoder.init(flaky.device(), p, &audio_index, src, .{ .positions = POSITIONS }, &work) catch |e| return failure(e, "encoder init", null);
    defer encoder.deinit();
    var stream = encoder.newStream() catch |e| return failure(e, "newStream", &encoder);
    defer encoder.freeStream(&stream);
    cpu_state.reset();
    const label = if (caps.fused_fma) "fused" else "unfused";
    var first: usize = 0;
    var rows: usize = 0;
    for (chunks, 0..) |count, ci| {
        const chunk = frames[first * f .. (first + count) * f];
        const a = try enc.encode(CAPACITY, LIMITS, src, &audio_index, p, &cpu_state, &cpu_work, chunk, cpu_rows[rows * width ..], .{});
        if (lost_at == ci) {
            // the device lost in the call's second run (its first ran and
            // wrote): the stream as it was, the call made again
            flaky.fail_in = 2;
            try std.testing.expectError(error.DeviceLost, encoder.encode(&stream, chunk, gpu_rows[rows * width ..]));
            try std.testing.expectEqual(rows, stream.position);
            std.debug.print("hearing encoder ({s}) chunk {d}: the device lost mid-call, the stream as it was\n", .{ label, ci });
        }
        const before = emu.total.lane_ops;
        const b = encoder.encode(&stream, chunk, gpu_rows[rows * width ..]) catch |e| return failure(e, "encode", &encoder);
        try std.testing.expectEqual(a, b);
        std.debug.print("hearing encoder ({s}) chunk {d}: {d} frames, {d} rows; {d} dispatches in {d} runs, {d} lane-ops\n", .{ label, ci, count, b, encoder.dispatches, encoder.runs, emu.total.lane_ops - before });
        var buf: [64]u8 = undefined;
        _ = try compareRows(std.fmt.bufPrint(&buf, "chunk {d} rows", .{ci}) catch "rows", cpu_rows[rows * width ..][0 .. a * width], gpu_rows[rows * width ..][0 .. b * width], tolerance);
        first += count;
        rows += a;
    }
    try std.testing.expectEqual(rows, stream.position);
    // the stream's state on the CPU: the CPU's own (exact when fused)
    try encoder.toCpu(&stream, LIMITS, &handed);
    if (tolerance == 0) try expectSameState(&handed, &cpu_state);
    if (!takeover) return;
    // the CPU's state on a new GPU stream; one more chunk on both
    var again = encoder.newStream() catch |e| return failure(e, "newStream", &encoder);
    defer encoder.freeStream(&again);
    try encoder.fromCpu(&again, LIMITS, &cpu_state);
    const tail = frames[first * f ..];
    const a = try enc.encode(CAPACITY, LIMITS, src, &audio_index, p, &cpu_state, &cpu_work, tail, cpu_rows[rows * width ..], .{});
    const b = encoder.encode(&again, tail, gpu_rows[rows * width ..]) catch |e| return failure(e, "encode after fromCpu", &encoder);
    try std.testing.expectEqual(a, b);
    _ = try compareRows("after fromCpu", cpu_rows[rows * width ..][0 .. a * width], gpu_rows[rows * width ..][0 .. b * width], tolerance);
}

test "LFM3-Audio's hearing encoder on the GPU (when its mmproj is here): a clip streamed in chunks, the CPU's rows; the state to the CPU and back" {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, MMPROJ_PATH, .{}) catch return error.SkipZigTest;
    defer file.close(io);
    const size = try file.length(io);
    var mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(io);
    const memory = Memory{ .bytes = mapping.memory };
    const src = memory.source();
    try gguf.parse(CAPACITY, src, &audio_index);
    try enc.build(CAPACITY, src, &audio_index, &audio_plan);
    const p = &audio_plan;
    std.debug.print("hearing encoder: {d} layers ({d} conv, {d} attention), hidden {d}, ff {d}, {d} heads of {d} ({d} KV), window {d}, {d} mels x {d} channels, projection {d}\n", .{ p.layer_count, p.conv_layer_count, p.attention_layer_count, p.hidden, p.feed_forward, p.heads, p.head_size, p.kv_heads, p.window, p.mels, p.channels, p.projection });
    const frames = try makeClip(48);
    // a GPU that fuses (the RTX): the CPU's bits; 16 + 16 frames, then the
    // CPU's state on a new stream for the clip's last 16
    try hearAgainstCpu(gpu.interp_caps, src, frames, &.{ 16, 16 }, 0, 1, true);
    // the Adreno's caps (mad rounded twice, no fused FMA, subgroups of 64):
    // the CPU's fused steps emulated exactly, its bits too; 16 frames, then
    // a clip's last 7
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.subgroup = 64;
    try hearAgainstCpu(caps, src, frames[0 .. 23 * p.mels], &.{ 16, 7 }, 0, null, false);
}

// ── GELU against the CPU ────────────────────────────────────────────────────

var insts: [16384]kir.Inst = undefined;
var tys: [16384]kir.Ty = undefined;
var kwork: [24 << 20]u8 align(64) = undefined;
var buf_a: [1 << 20]u8 align(16) = undefined;
var buf_b: [1 << 20]u8 align(16) = undefined;
var buf_c: [1 << 20]u8 align(16) = undefined;
var buf_d: [1 << 20]u8 align(16) = undefined;

fn storage() kir.Storage {
    return .{ .insts = &insts, .tys = &tys };
}

fn interpRun(k: *const kir.Kernel, caps: gpu.Caps, groups: [3]u32, bindings: []const []u8, params: []const u32) !gpu.interp.Stats {
    var w = gpu.Work.init(&kwork);
    var trap: gpu.interp.Trap = .{};
    return gpu.interp.runKernel(k, caps, groups, bindings, params, &w, &trap) catch |e| {
        std.debug.print("{s}: {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d}\n", .{ k.name, @errorName(e), @tagName(trap.what), trap.pc, trap.group, trap.thread, trap.binding, trap.offset });
        return e;
    };
}

fn floats(bytes: []u8) []f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, bytes));
}

fn ulps(a: f32, b: f32) u32 {
    const x: i64 = @as(i32, @bitCast(a));
    const y: i64 = @as(i32, @bitCast(b));
    const ox = if (x < 0) -(x & 0x7fffffff) else x;
    const oy = if (y < 0) -(y & 0x7fffffff) else y;
    return @intCast(@min(@abs(ox - oy), std.math.maxInt(u32)));
}

fn geluAgainstCpu(caps: gpu.Caps) !void {
    const N = 8192;
    var k = try hear.gelu(storage(), caps);
    const x = floats(buf_a[0 .. N * 4]);
    var seed: u32 = 5;
    for (x, 0..) |*v, i| {
        // values a projector gives: mostly within +-4, some to +-12, zeros
        const r = unit(&seed);
        v.* = switch (i % 16) {
            0 => r * 24,
            1 => 0,
            2 => r * 1e-3,
            else => r * 8,
        };
    }
    x[3] = -0.0;
    x[4] = 6.36396;
    x[5] = -6.36396;
    x[6] = 5.5;
    var want: [N]f32 = undefined;
    for (&want, x) |*w, v| w.* = ops.geluErf(v);
    _ = try interpRun(&k, caps, hear.geluGroups(N), &.{buf_a[0 .. N * 4]}, &.{ N, 0 });
    var exact: usize = 0;
    var worst: u32 = 0;
    for (want, x) |w, g| {
        if (@as(u32, @bitCast(w)) == @as(u32, @bitCast(g))) exact += 1;
        worst = @max(worst, ulps(w, g));
    }
    std.debug.print("gelu ({s}): {d} of {d} the CPU's bits, at most {d} ulp apart\n", .{ if (caps.fused_fma) "fused" else "unfused", exact, N, worst });
    try std.testing.expect(worst <= 1);
    try std.testing.expect(exact + 8 >= N);
}

test "GELU's erf in double-f32: ops.geluErf's bits (fused and unfused)" {
    try geluAgainstCpu(gpu.interp_caps);
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.subgroup = 64;
    try geluAgainstCpu(caps);
}

// ── The new kernels on the emulated GPUs, against the interpreter ───────────

const Rtx = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

const Adreno = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var dev: gpu.adreno_device.Emu = undefined;
};

var code: [512 << 10]u8 align(16) = undefined;
var compile_mem: [24 << 20]u8 align(16) = undefined;
var expect_buf: [4][1 << 20]u8 align(16) = undefined;

/// One kernel on `dev` and on the interpreter under the same caps, its
/// bindings filled from `inputs` (as many bytes each as given): every
/// binding's bytes the same afterwards.
fn sameOnDevice(dev: gpu.Device, what: []const u8, k: *const kir.Kernel, groups: [3]u32, inputs: []const []const u8, params: []const u32) !void {
    // the interpreter's
    var views: [4][]u8 = undefined;
    for (inputs, 0..) |in, i| {
        @memcpy(expect_buf[i][0..in.len], in);
        views[i] = expect_buf[i][0..in.len];
    }
    _ = try interpRun(k, dev.caps, groups, views[0..inputs.len], params);
    // the device's
    var cw = gpu.Work.init(&compile_mem);
    const bin = gpu.compile(k, dev.caps, &cw, &code) catch |e| {
        std.debug.print("{s} on {s}: compile {s}\n", .{ what, dev.caps.name, @errorName(e) });
        return e;
    };
    var prog = try dev.load(&bin);
    defer dev.unload(&prog);
    var bufs: [4]gpu.Buffer = undefined;
    for (inputs, 0..) |in, i| {
        bufs[i] = try dev.alloc(std.mem.alignForward(usize, in.len, 16), .host);
        @memcpy(bufs[i].cpu[0..in.len], in);
        dev.toDevice(bufs[i], 0, in.len);
    }
    defer for (bufs[0..inputs.len]) |b| dev.free(b);
    const fence = try dev.run(&.{.{ .prog = &prog, .groups = groups, .buffers = bufs[0..inputs.len], .params = params }});
    dev.wait(fence, 60_000_000) catch |e| {
        std.debug.print("{s} on {s}: {s}\n", .{ what, dev.caps.name, @errorName(e) });
        return e;
    };
    for (inputs, 0..) |in, i| {
        dev.fromDevice(bufs[i], 0, in.len);
        if (!std.mem.eql(u8, bufs[i].cpu[0..in.len], views[i])) {
            const g = floats(bufs[i].cpu[0 .. in.len & ~@as(usize, 3)]);
            const w = floats(views[i][0 .. in.len & ~@as(usize, 3)]);
            var shown: usize = 0;
            for (g, w, 0..) |a, b, j| {
                if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) continue;
                std.debug.print("{s} on {s}: binding {d} word {d}: device {e} interpreter {e}\n", .{ what, dev.caps.name, i, j, a, b });
                shown += 1;
                if (shown == 8) break;
            }
            return error.TestUnexpectedResult;
        }
    }
    std.debug.print("  {s} on {s}: the interpreter's bits\n", .{ what, dev.caps.name });
}

fn fill(bytes: []u8, seed: *u32, scale: f32) void {
    for (floats(bytes)) |*v| v.* = unit(seed) * scale;
}

/// Every new kernel on `dev` on small shapes of the encoder's.
fn kernelsOn(dev: gpu.Device) !void {
    const caps = dev.caps;
    var seed: u32 = 17;
    const a = &buf_a;
    const w = &buf_b;
    const o = &buf_c;
    const r = &buf_d;
    // conv0: 16 bins, 5 columns (an odd chunk: the column past it), 64 channels
    {
        const bins = 16;
        const columns = 5;
        const c = 64;
        var k = try hear.conv0(storage(), caps);
        fill(a[0 .. columns * bins * 4], &seed, 3);
        fill(r[0 .. bins * 4], &seed, 3);
        fill(w[0 .. (9 * c + c) * 4], &seed, 1);
        @memset(o[0 .. 3 * (bins / 2) * c * 4], 0);
        try sameOnDevice(dev, "conv0", &k, hear.conv0Groups(c, bins, 3), &.{ a[0 .. columns * bins * 4], r[0 .. bins * 4], w[0 .. (9 * c + c) * 4], o[0 .. 3 * (bins / 2) * c * 4] }, &hear.conv0Params(bins, columns, 0, 9 * c * 4, c, 0, 0, 0));
    }
    // dwpw: 8 bins, 3 columns, 64 channels; out as the features' layout
    {
        const bins = 8;
        const columns = 3;
        const c = 64;
        var k = try hear.dwpw(storage(), caps, c);
        fill(a[0 .. columns * bins * c * 4], &seed, 2);
        fill(r[0 .. bins * c * 4], &seed, 2);
        const wn = 9 * c + c + c * c + c;
        fill(w[0 .. wn * 4], &seed, 0.5);
        const out_n = 2 * (bins / 2) * c;
        @memset(o[0 .. out_n * 4], 0);
        const params = (hear.DwpwParams{ .bins = bins, .columns = columns, .c = c, .dw = 0, .dw_bias = 9 * c * 4, .pw = 10 * c * 4, .pw_bias = (10 * c + c * c) * 4, .out_column = (bins / 2) * c * 4, .out_bin = 4, .out_channel = (bins / 2) * 4 }).words();
        try sameOnDevice(dev, "dwpw", &k, hear.dwpwGroups(bins, columns), &.{ a[0 .. columns * bins * c * 4], r[0 .. bins * c * 4], w[0 .. wn * 4], o[0 .. out_n * 4] }, &params);
    }
    // head norm + rope: heads of 96, 3 heads, 2 tokens, a stride with room
    {
        const hs = 96;
        const stride = 4 * hs * 4;
        var k = try hear.headNormRope(storage(), caps, hs);
        fill(a[0 .. 2 * stride], &seed, 4);
        fill(w[0 .. hs * 4], &seed, 1);
        lk.ropeTable(floats(r[0 .. 2 * hs * 4]), 37, 2, hs, 1_000_000, null);
        try sameOnDevice(dev, "head norm + rope", &k, .{ 3, 2, 1 }, &.{ a[0 .. 2 * stride], w[0 .. hs * 4], r[0 .. 2 * hs * 4] }, &hear.headParams(3, 1e-5, 0, 0, stride));
    }
    // attention: heads of 96, 4 heads over 2 KV heads, window 6 (prefix
    // 5), 3 positions at position 3 (the clip's start still visible)
    {
        const hs = 96;
        const heads = 4;
        const kvw = 2 * hs;
        const pre = 5;
        const n = 3;
        const row = 2 * kvw * 4;
        var k = try hear.attendWindow(storage(), caps, hs);
        fill(a[0 .. n * heads * hs * 4], &seed, 2);
        fill(w[0 .. (pre + n) * row], &seed, 2);
        @memset(o[0 .. n * heads * hs * 4], 0);
        const params = (hear.AttendParams{ .heads = heads, .group_log2 = 1, .base = 3, .prefix = pre, .scale = 1.0 / @sqrt(@as(f32, hs)), .row_bytes = row, .values = kvw * 4, .kv = 0 }).words();
        try sameOnDevice(dev, "attention", &k, .{ heads, n, 1 }, &.{ a[0 .. n * heads * hs * 4], w[0 .. (pre + n) * row], o[0 .. n * heads * hs * 4] }, &params);
    }
    // the final norms: rows of 768, 2 of them
    {
        const width = 768;
        var k = try hear.rmsLayerNorm(storage(), caps);
        fill(a[0 .. 2 * width * 4], &seed, 6);
        fill(w[0 .. 3 * width * 4], &seed, 1);
        @memset(o[0 .. 2 * width * 4], 0);
        try sameOnDevice(dev, "final norms", &k, .{ 1, 2, 1 }, &.{ a[0 .. 2 * width * 4], w[0 .. 3 * width * 4], o[0 .. 2 * width * 4] }, &hear.finalParams(width, 1e-5, 1e-5, 0, width * 4, 2 * width * 4, 0, 0));
    }
    // GELU: 256 values
    {
        var k = try hear.gelu(storage(), caps);
        fill(a[0 .. 256 * 4], &seed, 10);
        try sameOnDevice(dev, "gelu", &k, hear.geluGroups(256), &.{a[0 .. 256 * 4]}, &.{ 256, 0 });
    }
}

test "the encoder's new kernels on the emulated RTX (kir_sm120) and the emulated Adreno (kir_ir3): the interpreter's bits" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    try kernelsOn(Rtx.dev.device());
    Adreno.dev.init(&Adreno.arena, &Adreno.view);
    try kernelsOn(Adreno.dev.device());
}
