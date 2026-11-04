//! The LFM3 RTX backend (lfm3_nv) against the CPU executor, on a synthetic
//! four-layer model (short conv, full attention, short conv, sliding
//! attention, with sandwich norms) at the narrowest widths the sm_120
//! kernels take: hidden 1024, 16 heads of 128 over 4 KV heads (as
//! LFM3-Audio-2B's), an FFN of 1280. Q4_K matrices, a Q6_K attn_output (K
//! 2048) and a Q6_K ffn_down of 5 blocks a row (so the FFN runs padded to
//! 2048, as LFM3-Audio-2B's 7680 runs at 8192). It runs on the emulated RTX
//! with every control field checked at NAK's level (strict): a hazard in
//! any launch fails the call. A prompt longer than one matrix pass, decode
//! steps, then prefill batches of 1 to 8 tokens (every matrix variant);
//! logits compared at every step, greedy tokens identical. Then the CPU
//! executor takes over from the GPU's own state and hands it back, a
//! failed call is undone, a slow one waited out, two caches kept apart, a
//! long context left to the CPU.

const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const nvidia = @import("nvidia");
const nv = @import("lfm3_nv");

const nvd = nvidia.device;
const emu = nvidia.sm120_emu;
const testing = std.testing;

const CAPACITY = 64;
const HIDDEN = 1024;
const HEADS = 16;
const KV_HEADS = 4;
const HEAD = 128;
/// 5 blocks a row: ffn_down's Q6_K rows are padded to 8 on the GPU.
const FEED = 1280;
/// (two matrix CTAs of 32 rows for the logits, the second part-empty)
const VOCAB = 40;
const KERNEL = 3;
const WINDOW = 4;
const LAYERS = 4;
const CONTEXT = 64;
const LIMITS = executor.Limits{ .hidden = HIDDEN, .feed_forward = FEED, .query = HEADS * HEAD, .key_value = KV_HEADS * HEAD, .heads = HEADS, .vocabulary = VOCAB, .batch = 16, .context = CONTEXT };

const Fixture = struct {
    bytes: [24 << 20]u8 align(64) = undefined,
    used: usize = 0,
    index: gguf.Index(CAPACITY) = .{},
    plan: lfm3.Plan = .{},
    seed: u32 = 1,

    fn initialize(self: *Fixture) !void {
        self.used = 0;
        self.index = .{};
        self.seed = 1;
        const summary = &self.index.summary;
        summary.architecture[0..4].* = "lfm3".*;
        summary.architecture_len = 4;
        summary.embedding_length = HIDDEN;
        summary.block_count = LAYERS;
        summary.head_count = HEADS;
        summary.attention_key_length = HEAD;
        summary.attention_value_length = HEAD;
        summary.feed_forward_length = FEED;
        summary.vocab_size = VOCAB;
        summary.rope_frequency_base = 1_000_000;
        summary.rope_frequency_base_swa = 10_000;
        summary.rms_norm_epsilon = 0.00001;
        summary.sliding_window = WINDOW;
        summary.shortconv_l_cache = KERNEL;
        const kv_heads = [LAYERS]i32{ 0, KV_HEADS, 0, KV_HEADS };
        const sliding = [LAYERS]u8{ 0, 0, 0, 1 };
        summary.head_count_kv_layers = .{ .present = true, .element_type = 5, .count = LAYERS, .data_offset = self.used };
        for (kv_heads) |count| self.put(std.mem.asBytes(&count));
        summary.sliding_window_pattern = .{ .present = true, .element_type = 7, .count = LAYERS, .data_offset = self.used };
        self.put(&sliding);
        try self.tensor("token_embd.weight", HIDDEN, VOCAB, 12);
        try self.tensor("output_norm.weight", HIDDEN, 0, 0);
        try self.tensor("rope_freqs.weight", HEAD / 2, 0, 0);
        for (0..LAYERS) |li| {
            const attention = kv_heads[li] != 0;
            try self.layer(li, "attn_norm.weight", HIDDEN, 0, 0);
            try self.layer(li, "ffn_norm.weight", HIDDEN, 0, 0);
            try self.layer(li, "post_attention_norm.weight", HIDDEN, 0, 0);
            try self.layer(li, "post_ffw_norm.weight", HIDDEN, 0, 0);
            try self.layer(li, "ffn_gate.weight", HIDDEN, FEED, 12);
            try self.layer(li, "ffn_up.weight", HIDDEN, FEED, 12);
            // (one Q6_K ffn_down, as Q4_K_M files have them: 5 blocks a row)
            try self.layer(li, "ffn_down.weight", FEED, HIDDEN, if (li == 2) 14 else 12);
            if (attention) {
                try self.layer(li, "attn_q.weight", HIDDEN, HEADS * HEAD, 12);
                try self.layer(li, "attn_k.weight", HIDDEN, KV_HEADS * HEAD, 12);
                try self.layer(li, "attn_v.weight", HIDDEN, KV_HEADS * HEAD, 12);
                try self.layer(li, "attn_gate.weight", HIDDEN, HEADS, 12);
                // (a Q6_K one of 8 blocks a row, as the kernel takes them)
                try self.layer(li, "attn_output.weight", HEADS * HEAD, HIDDEN, if (li == 1) 14 else 12);
                try self.layer(li, "attn_q_norm.weight", HEAD, 0, 0);
                try self.layer(li, "attn_k_norm.weight", HEAD, 0, 0);
            } else {
                try self.layer(li, "shortconv.in_proj.weight", HIDDEN, 3 * HIDDEN, 12);
                try self.layer(li, "shortconv.out_proj.weight", HIDDEN, HIDDEN, 12);
                try self.layer(li, "shortconv.conv.weight", KERNEL, HIDDEN, 0);
            }
        }
        try lfm3.build(CAPACITY, self.source(), &self.index, &self.plan);
    }

    fn layer(self: *Fixture, l: usize, suffix: []const u8, inner: usize, outer: usize, ggml_type: u32) !void {
        var name: [64]u8 = undefined;
        try self.tensor(try std.fmt.bufPrint(&name, "blk.{d}.{s}", .{ l, suffix }), inner, outer, ggml_type);
    }

    fn tensor(self: *Fixture, name: []const u8, inner: usize, outer: usize, ggml_type: u32) !void {
        self.used = std.mem.alignForward(usize, self.used, 32);
        const id = self.index.tensor_count;
        const info = &self.index.tensors[id];
        @memcpy(info.name[0..name.len], name);
        info.name_len = @intCast(name.len);
        info.dimension_count = if (outer == 0) 1 else 2;
        info.dimensions[0] = inner;
        if (outer != 0) info.dimensions[1] = outer;
        info.ggml_type = ggml_type;
        info.file_offset = self.used;
        const elements = inner * @max(outer, 1);
        const block: usize = if (ggml_type == 12) quantized.Q4_K_BLOCK_BYTES else quantized.Q6_K_BLOCK_BYTES;
        info.byte_size = if (ggml_type == 0) elements * 4 else elements / quantized.QK_K * block;
        if (self.used + info.byte_size > self.bytes.len) return error.OutOfMemory;
        if (ggml_type == 0) {
            const taps = std.mem.endsWith(u8, name, "conv.weight");
            for (0..elements) |_| {
                const unit = @as(f32, @floatFromInt(self.next() % 1000)) / 1000.0;
                const value: f32 = if (taps) unit - 0.5 else 0.75 + unit / 2;
                self.put(std.mem.asBytes(&value));
            }
        } else {
            for (0..info.byte_size / block) |_| {
                var b: [quantized.Q6_K_BLOCK_BYTES]u8 = undefined;
                for (b[0..block]) |*byte| byte.* = @truncate(self.next());
                if (ggml_type == 12) {
                    std.mem.writeInt(u16, b[0..2], @bitCast(@as(f16, 0.02)), .little);
                    std.mem.writeInt(u16, b[2..4], @bitCast(@as(f16, 0.01)), .little);
                } else {
                    // Q6_K: small signed scales, then d
                    for (b[192..208]) |*sc| sc.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast(self.next() % 32)) - 16)));
                    std.mem.writeInt(u16, b[208..210], @bitCast(@as(f16, 0.002)), .little);
                }
                self.put(b[0..block]);
            }
        }
        self.index.tensor_count += 1;
    }

    fn put(self: *Fixture, data: []const u8) void {
        @memcpy(self.bytes[self.used..][0..data.len], data);
        self.used += data.len;
    }
    fn next(self: *Fixture) u32 {
        self.seed = self.seed *% 1664525 +% 1013904223;
        return self.seed >> 8;
    }
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or destination.len > self.used - @as(usize, @intCast(offset))) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, length: usize, alignment: usize) ?[*]const u8 {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or length > self.used - @as(usize, @intCast(offset))) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Fixture) gguf.Source {
        return .{ .context = self, .size = self.used, .read_at = read, .map_at = map };
    }
};

const Backend = nv.Backend(CAPACITY);

var fixture: Fixture = .{};
var work: executor.Workspace(LIMITS) = .{};
var kv_cpu: [2 * 2 * KV_HEADS * CONTEXT * HEAD]u16 = @splat(0);
var conv_cpu: [2 * (KERNEL - 1) * HIDDEN]f32 = @splat(0);
/// (the model's 20.5 MB, its padded ffn_downs' 5.3, a 16.8 MB KV cache of
/// MAX_ATTENTION_SPAN + 8 positions, the rest)
var arena: [56 << 20]u8 align(4096) = undefined;
/// The GPU's own memory: a missing toDevice/fromDevice shows.
var gpu_view: [56 << 20]u8 align(4096) = undefined;
var emu_dev: nvd.EmuDevice = undefined;
var emu_work: emu.Work = .{};
var asm_work: nvidia.sm120_asm.Work = .{};
const unpacked: executor.PackedWeights(CAPACITY) = .{};

/// A fresh emulated RTX (the Legion's GB206 as one TPC), checking every
/// control field at NAK's level; with `apart`, its memory seen by the CPU
/// only through toDevice and fromDevice (VRAM behind BAR1).
fn freshEmu(apart: bool) void {
    emu_dev = .{ .arena = &arena, .gpu_view = if (apart) &gpu_view else &.{}, .work = &emu_work, .tpcs = 1 };
    emu_work.strict = true;
}

/// GPU-mapped system memory (Galaxy's nvDevice(.system)) on the same
/// emulated RTX: buffers from its arena at GPU addresses of their own, far
/// from VRAM's.
const HOST_VA: u64 = 0x20_0000_0000;

const HostMemory = struct {
    gpu: *nvd.EmuDevice,
    next: u64 = HOST_VA,

    fn device(h: *HostMemory) nvd.Device {
        return .{ .ctx = h, .vtable = &vtable };
    }
    const vtable = nvd.Device.VTable{ .alloc = alloc, .free = free, .submit = submit, .wait = wait, .toDevice = toDevice, .fromDevice = fromDevice };
    fn of(ctx: *anyopaque) *HostMemory {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, size: usize) ?nvd.Buffer {
        const h = of(ctx);
        const b = h.gpu.allocAt(h.next, size) orelse return null;
        h.next += std.mem.alignForward(u64, size, 4096) + 4096;
        return b;
    }
    fn free(ctx: *anyopaque, b: nvd.Buffer) void {
        _ = ctx;
        _ = b;
    }
    fn submit(ctx: *anyopaque, pb: nvd.Buffer, dwords: u32) nvd.Error!nvd.Fence {
        return of(ctx).gpu.device().submit(pb, dwords);
    }
    fn wait(ctx: *anyopaque, f: nvd.Fence, timeout_us: u64) nvd.Error!void {
        return of(ctx).gpu.device().wait(f, timeout_us);
    }
    fn toDevice(ctx: *anyopaque, b: nvd.Buffer, off: usize, len: usize) void {
        of(ctx).gpu.device().toDevice(b, off, len);
    }
    fn fromDevice(ctx: *anyopaque, b: nvd.Buffer, off: usize, len: usize) void {
        of(ctx).gpu.device().fromDevice(b, off, len);
    }
};

fn inHost(va: u64) bool {
    return va >= HOST_VA;
}

fn compare(step: usize, cpu: []const f32, g: []const f32) !f64 {
    var scale: f64 = 0;
    for (cpu) |v| scale = @max(scale, @abs(@as(f64, v)));
    var worst: f64 = 0;
    for (cpu, g) |a, b| worst = @max(worst, @abs(@as(f64, a) - b));
    const rel = worst / @max(scale, 1e-6);
    if (rel > 3e-2) {
        std.debug.print("step {d}: outputs differ by {e} of {e}\n", .{ step, worst, scale });
        return error.TestUnexpectedResult;
    }
    return rel;
}

/// The backend's call, with what the emulated RTX says when it fails, and
/// every launch run clean.
fn gpuForward(b: *Backend, c: *nv.Cache, input: executor.Input, output: executor.Output) !?u32 {
    const before = emu_dev.launches;
    const got = b.forward(c, input, output) catch |e| {
        var buf: [256]u8 = undefined;
        std.debug.print("RTX forward: {s} (the emulator: {s}: {s})\n", .{ @errorName(e), if (emu_dev.last_error) |x| @errorName(x) else "-", emu.explain(&emu_work, &buf) });
        return e;
    };
    try testing.expectEqual(@as(?anyerror, null), emu_dev.last_error);
    try testing.expectEqual(@as(u64, b.last_launches), emu_dev.launches - before);
    return got;
}

fn cpuForward(src: gguf.Source, cache: *executor.Cache, input: executor.Input, output: executor.Output) !?u32 {
    return executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, &fixture.plan, &unpacked, &work, cache, input, output, .{});
}

/// The CPU executor's own cache (zeroed).
fn cpuCache() executor.Cache {
    @memset(&kv_cpu, 0);
    @memset(&conv_cpu, 0);
    return .{ .kv = &kv_cpu, .conv = &conv_cpu, .context = CONTEXT };
}

fn halfOf(h: u16) f32 {
    return @floatCast(@as(f16, @bitCast(h)));
}

/// The GPU's KV rows (after toCpu) against the CPU's, each head's block's
/// positions below `end`, as the logits are compared (the GPU's RMSNorms
/// and softmax are float paths a little apart from the CPU's, so the
/// activations feeding the K and V matrices are too); and the rows past
/// `end` still zero.
fn expectKv(gpu: []const u16, cpu: []const u16, end: usize) !void {
    const block = CONTEXT * HEAD;
    const S = struct {
        var a: [CONTEXT * HEAD]f32 = undefined;
        var b: [CONTEXT * HEAD]f32 = undefined;
    };
    for (0..gpu.len / block) |blk| {
        for (0..end * HEAD) |e| {
            S.a[e] = halfOf(gpu[blk * block + e]);
            S.b[e] = halfOf(cpu[blk * block + e]);
        }
        _ = try compare(200 + blk, S.b[0 .. end * HEAD], S.a[0 .. end * HEAD]);
        for (gpu[blk * block + end * HEAD ..][0 .. (CONTEXT - end) * HEAD]) |x| try testing.expectEqual(@as(u16, 0), x);
    }
}

test "the RTX backend follows the CPU executor, and the CPU takes over from its state and hands it back" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    freshEmu(true);
    var host = HostMemory{ .gpu = &emu_dev };
    var backend = try Backend.init(emu_dev.device(), plan, &fixture.index, src, .{ .max_batch = 16, .host = host.device() }, &asm_work);
    defer backend.deinit();
    // (the FFN at 2048: ffn_down's Q6_K rows padded to whole groups of 8)
    try testing.expectEqual(@as(u32, 2048), backend.ffn_width);
    var gc = try backend.newCache(CONTEXT);
    // What the CPU reads every call in system memory, the rest in VRAM.
    try testing.expect(inHost(backend.out_logits.va) and inHost(backend.out_hidden.va) and inHost(backend.conv_snapshot.va) and inHost(gc.conv.va));
    try testing.expect(!inHost(gc.kv.va) and !inHost(backend.model.va) and !inHost(backend.padded.va) and !inHost(backend.code.va) and !inHost(backend.s.act_q.va));
    var ccache = cpuCache();
    // A prompt of 11 (two matrix passes: 8 and 3), then decode steps fed the
    // CPU's tokens.
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    var token = (try cpuForward(src, &ccache, .{ .tokens = &prompt }, .logits)).?;
    const gtok = (try gpuForward(&backend, &gc, .{ .tokens = &prompt }, .logits)).?;
    var worst = try compare(0, work.logits[0..VOCAB], backend.logits());
    try testing.expectEqual(token, gtok);
    // (two passes a matrix: every slot init made for 16 tokens. A layer:
    // two norms, two residuals, SwiGLU and its quantization, the mixer's
    // conv and quantization or prepare, attention and quantization; its
    // 5 or 8 matrices in passes of 8. Then the output norm and logits.)
    try testing.expectEqual(@as(u32, 2 * (8 + 5 * 2) + 2 * (9 + 8 * 2) + 2), backend.slot_count);
    try testing.expectEqual(backend.slot_count, backend.last_launches);
    for (1..8) |step| {
        const next = (try cpuForward(src, &ccache, .{ .tokens = &.{token} }, .logits)).?;
        const gnext = (try gpuForward(&backend, &gc, .{ .tokens = &.{token} }, .logits)).?;
        worst = @max(worst, try compare(step, work.logits[0..VOCAB], backend.logits()));
        try testing.expectEqual(next, gnext);
        token = next;
    }
    try testing.expectEqual(ccache.position, gc.cpu.position);
    // The GPU's state, handed to the CPU: its KV rows as the CPU wrote
    // them, its conv state close to the CPU's.
    backend.toCpu(&gc);
    try expectKv(gc.cpu.kv, &kv_cpu, gc.cpu.position);
    _ = try compare(98, &conv_cpu, gc.cpu.conv);
    // The CPU continues on the GPU's own state (model, KV, conv) and agrees.
    const cpu_on_gpu_state = (try cpuForward(backend.source(), &gc.cpu, .{ .tokens = &.{token} }, .logits)).?;
    var logits_a: [VOCAB]f32 = undefined;
    @memcpy(&logits_a, work.logits[0..VOCAB]);
    const cpu_alone = (try cpuForward(src, &ccache, .{ .tokens = &.{token} }, .logits)).?;
    try testing.expectEqual(cpu_alone, cpu_on_gpu_state);
    worst = @max(worst, try compare(99, work.logits[0..VOCAB], &logits_a));
    // And the GPU picks up again after the CPU's steps (the rows the CPU
    // wrote go back with the next call).
    var t = cpu_alone;
    for (0..3) |step| {
        const gagain = (try gpuForward(&backend, &gc, .{ .tokens = &.{t} }, .logits)).?;
        const cagain = (try cpuForward(src, &ccache, .{ .tokens = &.{t} }, .logits)).?;
        worst = @max(worst, try compare(100 + step, work.logits[0..VOCAB], backend.logits()));
        try testing.expectEqual(cagain, gagain);
        t = cagain;
    }
    try testing.expectEqual(backend.launches, emu_dev.launches);
    try testing.expect(emu_dev.stats.hazard_checks > 0);
    std.debug.print("RTX vs CPU logits: worst relative difference {e} over 12 calls; {d} launches, {d} thread instructions, {d} control checks\n", .{ worst, emu_dev.launches, emu_dev.stats.thread_instructions, emu_dev.stats.hazard_checks });
}

test "prefill batches of 1 to 8 tokens (every matrix variant): no output, the hidden row, the logits" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    freshEmu(true);
    var host = HostMemory{ .gpu = &emu_dev };
    var backend = try Backend.init(emu_dev.device(), plan, &fixture.index, src, .{ .max_batch = 8, .host = host.device() }, &asm_work);
    defer backend.deinit();
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache();
    var seq: [36]u32 = undefined;
    for (&seq, 0..) |*s, i| s.* = @intCast((i * 7 + 3) % VOCAB);
    var at: usize = 0;
    var worst: f64 = 0;
    for (1..9) |n| {
        const input = executor.Input{ .tokens = seq[at..][0..n] };
        const output: executor.Output = switch (n) {
            3 => .none,
            5 => .hidden,
            else => .logits,
        };
        const cpu = try cpuForward(src, &ccache, input, output);
        const g = try gpuForward(&backend, &gc, input, output);
        switch (output) {
            .none => {
                try testing.expectEqual(@as(?u32, null), cpu);
                try testing.expectEqual(@as(?u32, null), g);
            },
            .hidden => worst = @max(worst, try compare(n, work.normalized[0..HIDDEN], backend.hidden())),
            .logits => {
                worst = @max(worst, try compare(n, work.logits[0..VOCAB], backend.logits()));
                worst = @max(worst, try compare(n, work.normalized[0..HIDDEN], backend.hidden()));
                try testing.expectEqual(cpu.?, g.?);
            },
        }
        at += n;
        try testing.expectEqual(@as(usize, at), gc.cpu.position);
    }
    try testing.expectEqual(ccache.position, gc.cpu.position);
    std.debug.print("RTX vs CPU, batches of 1 to 8: worst relative difference {e}; {d} launches\n", .{ worst, emu_dev.launches });
}

/// The emulated GPU, whose next wait fails (or runs out) when asked.
const Flaky = struct {
    inner: nvd.Device,
    fail: ?nvd.Error = null,

    fn device(f: *Flaky) nvd.Device {
        return .{ .ctx = f, .vtable = &vtable };
    }
    const vtable = nvd.Device.VTable{ .alloc = alloc, .free = free, .submit = submit, .wait = wait, .toDevice = toDevice, .fromDevice = fromDevice };
    fn of(ctx: *anyopaque) *Flaky {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, size: usize) ?nvd.Buffer {
        return of(ctx).inner.alloc(size) catch null;
    }
    fn free(ctx: *anyopaque, b: nvd.Buffer) void {
        of(ctx).inner.free(b);
    }
    fn submit(ctx: *anyopaque, pb: nvd.Buffer, dwords: u32) nvd.Error!nvd.Fence {
        return of(ctx).inner.submit(pb, dwords);
    }
    fn wait(ctx: *anyopaque, f: nvd.Fence, timeout_us: u64) nvd.Error!void {
        const s = of(ctx);
        if (s.fail) |e| {
            s.fail = null;
            return e;
        }
        return s.inner.wait(f, timeout_us);
    }
    fn toDevice(ctx: *anyopaque, b: nvd.Buffer, off: usize, len: usize) void {
        of(ctx).inner.toDevice(b, off, len);
    }
    fn fromDevice(ctx: *anyopaque, b: nvd.Buffer, off: usize, len: usize) void {
        of(ctx).inner.fromDevice(b, off, len);
    }
};

test "a failed call leaves its cache as it was, a slow one is waited out, caches are apart, long contexts are the CPU's" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    // (memory shared, as GPU-mapped system memory is: what the GPU wrote of
    // a failed call is in the CPU's view, and must be undone; no host
    // Device, so everything is the main one's)
    freshEmu(false);
    var flaky = Flaky{ .inner = emu_dev.device() };
    var backend = try Backend.init(flaky.device(), plan, &fixture.index, src, .{ .max_batch = 16 }, &asm_work);
    defer backend.deinit();
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache();
    const prompt = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const token = (try cpuForward(src, &ccache, .{ .tokens = &prompt }, .logits)).?;
    try testing.expectEqual(token, (try gpuForward(&backend, &gc, .{ .tokens = &prompt }, .logits)).?);

    // A call that does not finish: position and conv state as before it.
    var conv_before: [conv_cpu.len]f32 = undefined;
    @memcpy(&conv_before, gc.cpu.conv);
    flaky.fail = error.DeviceLost;
    try testing.expectError(error.DeviceLost, backend.forward(&gc, .{ .tokens = &.{token} }, .logits));
    try testing.expectEqual(prompt.len, gc.cpu.position);
    try testing.expectEqualSlices(f32, &conv_before, gc.cpu.conv);
    try testing.expectEqual(@as(u32, 1), backend.lost);
    try testing.expectEqual(@as(?nvd.Error, error.DeviceLost), backend.last_failure);
    // And one the emulated RTX itself gives up on (a kernel past its step
    // limit, as a hung one): the same.
    emu_work.max_steps = 1;
    try testing.expectError(error.DeviceLost, backend.forward(&gc, .{ .tokens = &.{token} }, .logits));
    emu_work.max_steps = emu.DEFAULT_MAX_STEPS;
    try testing.expectEqual(@as(?anyerror, error.Timeout), emu_dev.last_error);
    try testing.expectEqual(prompt.len, gc.cpu.position);
    try testing.expectEqualSlices(f32, &conv_before, gc.cpu.conv);
    try testing.expectEqual(@as(u32, 2), backend.lost);
    // The CPU does it on that state, as the CPU alone does.
    backend.toCpu(&gc);
    const on_gpu_state = (try cpuForward(backend.source(), &gc.cpu, .{ .tokens = &.{token} }, .logits)).?;
    const alone = (try cpuForward(src, &ccache, .{ .tokens = &.{token} }, .logits)).?;
    try testing.expectEqual(alone, on_gpu_state);

    // A call slower than the timeout: waited out, its result kept.
    flaky.fail = error.Timeout;
    const slow = (try gpuForward(&backend, &gc, .{ .tokens = &.{alone} }, .logits)).?;
    const slow_cpu = (try cpuForward(src, &ccache, .{ .tokens = &.{alone} }, .logits)).?;
    try testing.expectEqual(slow_cpu, slow);
    try testing.expectEqual(@as(u32, 1), backend.slow);
    try testing.expectEqual(@as(u32, 2), backend.lost);

    // A second cache: its prompt leaves the first one's state alone.
    var other = try backend.newCache(CONTEXT);
    _ = try gpuForward(&backend, &other, .{ .tokens = &.{ 7, 7, 2, 0, 1 } }, .logits);
    const after = (try gpuForward(&backend, &gc, .{ .tokens = &.{slow} }, .logits)).?;
    const after_cpu = (try cpuForward(src, &ccache, .{ .tokens = &.{slow} }, .logits)).?;
    try testing.expectEqual(after_cpu, after);
    try testing.expectEqual(@as(usize, 5), other.cpu.position);

    // What the GPU does not take, before it touches anything.
    var many: [17]u32 = @splat(1);
    try testing.expectError(error.BatchCapacity, backend.forward(&gc, .{ .tokens = &many }, .logits));
    try testing.expectError(error.BatchCapacity, backend.forward(&gc, .{ .tokens = &.{} }, .logits));
    try testing.expectError(error.InvalidToken, backend.forward(&gc, .{ .tokens = &.{VOCAB} }, .logits));
    try testing.expectEqual(@as(usize, prompt.len + 3), gc.cpu.position);
    var small = try backend.newCache(4);
    try testing.expectError(error.ContextCapacity, backend.forward(&small, .{ .tokens = &.{ 1, 2, 3, 4, 5 } }, .none));
    try testing.expectEqual(@as(usize, 0), small.cpu.position);
    backend.freeCache(&small);

    // Attention reaching further back than the GPU's kernel: the CPU's.
    var long = try backend.newCache(nv.MAX_ATTENTION_SPAN + 8);
    long.cpu.position = nv.MAX_ATTENTION_SPAN - 1;
    try testing.expectError(error.LongContext, backend.forward(&long, .{ .tokens = &.{ 1, 2 } }, .none));
    try testing.expectEqual(@as(usize, nv.MAX_ATTENTION_SPAN - 1), long.cpu.position);
    backend.freeCache(&long);
    backend.freeCache(&other);
    backend.freeCache(&gc);
}

test "init takes only what the kernels do" {
    try fixture.initialize();
    freshEmu(false);
    const d = emu_dev.device();
    const src = fixture.source();
    try testing.expectError(error.Unsupported, Backend.init(d, &fixture.plan, &fixture.index, src, .{ .max_batch = 0 }, &asm_work));
    try testing.expectError(error.Unsupported, Backend.init(d, &fixture.plan, &fixture.index, src, .{ .max_batch = 65 }, &asm_work));
    // (a hidden size the residual and norm kernels have no variant for)
    const S = struct {
        var plan: lfm3.Plan = .{};
        var index: gguf.Index(CAPACITY) = .{};
    };
    S.plan = fixture.plan;
    S.plan.hidden_size = 512;
    try testing.expectError(error.Unsupported, Backend.init(d, &S.plan, &fixture.index, src, .{}, &asm_work));
    // (a Q6_K matrix other than ffn_down whose rows are not whole 2048s)
    S.index = fixture.index;
    S.index.tensors[fixture.plan.layers[1].attn_v.index].ggml_type = 14;
    try testing.expectError(error.Unsupported, Backend.init(d, &fixture.plan, &S.index, src, .{}, &asm_work));
    // (nothing allocated by the refusals)
    try testing.expectEqual(@as(usize, 0), emu_dev.n_regions);
}
