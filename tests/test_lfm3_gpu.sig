//! The LFM3 GPU backend against the CPU executor, on a synthetic four-layer
//! model (short conv, full attention, short conv, sliding attention, with
//! sandwich norms), run on the emulated Adreno: a prompt longer than one
//! matrix pass, then decode steps; logits compared at every step. Then the
//! CPU executor takes over from the GPU's own state (the fallback path), a
//! failed call is undone, a slow one waited out, two caches kept apart.

const std = @import("std");
const builtin = @import("builtin");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const adreno = @import("adreno");
const gpu = @import("lfm3_gpu");

const CAPACITY = 64;
const HIDDEN = 256;
const HEADS = 8;
const KV_HEADS = 2;
const HEAD = 128;
const FEED = 512;
const VOCAB = 16;
const KERNEL = 3;
const WINDOW = 4;
const LAYERS = 4;
const CONTEXT = 32;
const LIMITS = executor.Limits{ .hidden = HIDDEN, .feed_forward = FEED, .query = HEADS * HEAD, .key_value = KV_HEADS * HEAD, .heads = HEADS, .vocabulary = VOCAB, .batch = 16, .context = CONTEXT };

const Fixture = struct {
    bytes: [4 << 20]u8 align(64) = undefined,
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
            // (one Q6_K matrix, as Q4_K_M files have)
            try self.layer(li, "ffn_down.weight", FEED, HIDDEN, if (li == 1) 14 else 12);
            if (attention) {
                try self.layer(li, "attn_q.weight", HIDDEN, HEADS * HEAD, 12);
                try self.layer(li, "attn_k.weight", HIDDEN, KV_HEADS * HEAD, 12);
                try self.layer(li, "attn_v.weight", HIDDEN, KV_HEADS * HEAD, 14);
                try self.layer(li, "attn_gate.weight", HIDDEN, HEADS, 12);
                try self.layer(li, "attn_output.weight", HEADS * HEAD, HIDDEN, 12);
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

const Backend = gpu.Backend(CAPACITY);

var fixture: Fixture = .{};
var work: executor.Workspace(LIMITS) = .{};
var kv_cpu: [2 * 2 * KV_HEADS * CONTEXT * HEAD]u16 = @splat(0);
var conv_cpu: [2 * (KERNEL - 1) * HIDDEN]f32 = @splat(0);
var arena: [24 << 20]u8 align(4096) = undefined;
/// The GPU's own memory: a missing toDevice/fromDevice shows.
var gpu_view: [24 << 20]u8 align(4096) = undefined;
var emu: adreno.device.EmuDevice = undefined;
var asm_work: adreno.ir3_asm.Work = .{};
const unpacked: executor.PackedWeights(CAPACITY) = .{};

fn compare(step: usize, cpu: []const f32, g: []const f32) !f64 {
    var scale: f64 = 0;
    for (cpu) |v| scale = @max(scale, @abs(@as(f64, v)));
    var worst: f64 = 0;
    for (cpu, g) |a, b| worst = @max(worst, @abs(@as(f64, a) - b));
    const rel = worst / @max(scale, 1e-6);
    if (rel > 3e-2) {
        std.debug.print("step {d}: logits differ by {e} of {e}\n", .{ step, worst, scale });
        return error.TestUnexpectedResult;
    }
    return rel;
}

test "the GPU backend follows the CPU executor, and the CPU takes over from its state" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    emu = .{ .arena = &arena, .gpu_view = &gpu_view };
    var backend = try Backend.init(emu.device(), plan, &fixture.index, src, .{ .max_batch = 16 }, &asm_work);
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache();
    // A prompt of 11 (two matrix passes), then decode steps fed the CPU's tokens.
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    var token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    const gtok = (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| {
        std.debug.print("GPU forward: {s} ({s})\n", .{ @errorName(e), if (emu.last_error) |x| @errorName(x) else "-" });
        return e;
    }).?;
    var worst = try compare(0, work.logits[0..VOCAB], backend.logits());
    try std.testing.expectEqual(token, gtok);
    for (1..8) |step| {
        const next = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
        const gnext = (try backend.forward(&gc, .{ .tokens = &.{token} }, .logits)).?;
        worst = @max(worst, try compare(step, work.logits[0..VOCAB], backend.logits()));
        try std.testing.expectEqual(next, gnext);
        token = next;
    }
    try std.testing.expectEqual(ccache.position, gc.cpu.position);
    // The CPU continues on the GPU's own state (model, KV, conv) and agrees.
    backend.toCpu(&gc);
    const cpu_on_gpu_state = (try executor.forwardInput(CAPACITY, LIMITS, backend.source(), &fixture.index, plan, &unpacked, &work, &gc.cpu, .{ .tokens = &.{token} }, .logits, .{})).?;
    var logits_a: [VOCAB]f32 = undefined;
    @memcpy(&logits_a, work.logits[0..VOCAB]);
    const cpu_alone = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(cpu_alone, cpu_on_gpu_state);
    worst = @max(worst, try compare(99, work.logits[0..VOCAB], &logits_a));
    // And the GPU picks up again after the CPU step.
    const gagain = (try backend.forward(&gc, .{ .tokens = &.{cpu_alone} }, .logits)).?;
    const cagain = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{cpu_alone} }, .logits, .{})).?;
    try std.testing.expectEqual(cagain, gagain);
    std.debug.print("GPU vs CPU logits: worst relative difference {e} over {d} steps\n", .{ worst, 10 });
}

/// The CPU executor's own cache (zeroed).
fn cpuCache() executor.Cache {
    @memset(&kv_cpu, 0);
    @memset(&conv_cpu, 0);
    return .{ .kv = &kv_cpu, .conv = &conv_cpu, .context = CONTEXT };
}

/// The emulated GPU, whose next wait fails (or runs out) when asked, or
/// the wait after `fail_after` more.
const Flaky = struct {
    inner: adreno.device.Device,
    fail: ?adreno.device.Error = null,
    fail_after: u32 = 0,

    fn device(f: *Flaky) adreno.device.Device {
        return .{ .ctx = f, .vtable = &vtable };
    }
    const vtable = adreno.device.Device.VTable{ .alloc = alloc, .free = free, .submit = submit, .wait = wait, .toDevice = toDevice, .fromDevice = fromDevice };
    fn of(ctx: *anyopaque) *Flaky {
        return @ptrCast(@alignCast(ctx));
    }
    fn alloc(ctx: *anyopaque, size: usize) ?adreno.device.Buffer {
        return of(ctx).inner.alloc(size) catch null;
    }
    fn free(ctx: *anyopaque, b: adreno.device.Buffer) void {
        of(ctx).inner.free(b);
    }
    fn submit(ctx: *anyopaque, ib: adreno.device.Buffer, dwords: u32) adreno.device.Error!adreno.device.Fence {
        return of(ctx).inner.submit(ib, dwords);
    }
    fn wait(ctx: *anyopaque, f: adreno.device.Fence, timeout_us: u64) adreno.device.Error!void {
        const s = of(ctx);
        if (s.fail) |e| {
            if (s.fail_after == 0) {
                s.fail = null;
                return e;
            }
            s.fail_after -= 1;
        }
        return s.inner.wait(f, timeout_us);
    }
    fn toDevice(ctx: *anyopaque, b: adreno.device.Buffer, off: usize, len: usize) void {
        of(ctx).inner.toDevice(b, off, len);
    }
    fn fromDevice(ctx: *anyopaque, b: adreno.device.Buffer, off: usize, len: usize) void {
        of(ctx).inner.fromDevice(b, off, len);
    }
};

test "a failed GPU call leaves its cache as it was, a slow one is waited out, caches are apart, long contexts are the CPU's" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    // (memory shared, as on the Surface: what the GPU wrote of a failed call
    // is in the CPU's view, and must be undone)
    emu = .{ .arena = &arena };
    var flaky = Flaky{ .inner = emu.device() };
    var backend = try Backend.init(flaky.device(), plan, &fixture.index, src, .{ .max_batch = 16 }, &asm_work);
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache();
    const prompt = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    try std.testing.expectEqual(token, (try backend.forward(&gc, .{ .tokens = &prompt }, .logits)).?);

    // A call that does not finish: position and conv state as before it.
    var conv_before: [conv_cpu.len]f32 = undefined;
    @memcpy(&conv_before, gc.cpu.conv);
    flaky.fail = error.DeviceLost;
    try std.testing.expectError(error.DeviceLost, backend.forward(&gc, .{ .tokens = &.{token} }, .logits));
    try std.testing.expectEqual(prompt.len, gc.cpu.position);
    try std.testing.expectEqualSlices(f32, &conv_before, gc.cpu.conv);
    try std.testing.expectEqual(@as(u32, 1), backend.lost);
    // The CPU does it on that state, as the CPU alone does.
    backend.toCpu(&gc);
    const on_gpu_state = (try executor.forwardInput(CAPACITY, LIMITS, backend.source(), &fixture.index, plan, &unpacked, &work, &gc.cpu, .{ .tokens = &.{token} }, .logits, .{})).?;
    const alone = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(alone, on_gpu_state);

    // A call slower than the timeout: waited out, its result kept.
    flaky.fail = error.Timeout;
    const slow = (try backend.forward(&gc, .{ .tokens = &.{alone} }, .logits)).?;
    const slow_cpu = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{alone} }, .logits, .{})).?;
    try std.testing.expectEqual(slow_cpu, slow);
    try std.testing.expectEqual(@as(u32, 1), backend.slow);
    try std.testing.expectEqual(@as(u32, 1), backend.lost);

    // A second cache: its prompt leaves the first one's state alone.
    var other = try backend.newCache(CONTEXT);
    _ = try backend.forward(&other, .{ .tokens = &.{ 7, 7, 2, 0, 1 } }, .logits);
    const after = (try backend.forward(&gc, .{ .tokens = &.{slow} }, .logits)).?;
    const after_cpu = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{slow} }, .logits, .{})).?;
    try std.testing.expectEqual(after_cpu, after);
    try std.testing.expectEqual(@as(usize, 5), other.cpu.position);

    // Attention reaching further back than the GPU's kernel: the CPU's.
    var long = try backend.newCache(gpu.MAX_ATTENTION_SPAN + 8);
    long.cpu.position = gpu.MAX_ATTENTION_SPAN - 1;
    try std.testing.expectError(error.LongContext, backend.forward(&long, .{ .tokens = &.{ 1, 2 } }, .none));
    try std.testing.expectEqual(@as(usize, gpu.MAX_ATTENTION_SPAN - 1), long.cpu.position);
    backend.freeCache(&long);
    backend.freeCache(&other);
}

// ── Diagnose mode ───────────────────────────────────────────────────────────

const DiagLog = struct {
    var lines: usize = 0;
    var dispatch_lines: usize = 0;
    var last: [320]u8 = undefined;
    var last_len: usize = 0;
    var before_failure: [320]u8 = undefined;
    var before_failure_len: usize = 0;
    var failure: [320]u8 = undefined;
    var failure_len: usize = 0;

    fn reset() void {
        lines = 0;
        dispatch_lines = 0;
        last_len = 0;
        failure_len = 0;
        before_failure_len = 0;
    }

    fn log(what: []const u8) void {
        lines += 1;
        const n = @min(what.len, last.len);
        if (std.mem.indexOf(u8, what, "FAILED") != null) {
            @memcpy(before_failure[0..last_len], last[0..last_len]);
            before_failure_len = last_len;
            @memcpy(failure[0..n], what[0..n]);
            failure_len = n;
        }
        if (std.mem.startsWith(u8, what, "lfm3-gpu: dispatch ")) dispatch_lines += 1;
        @memcpy(last[0..n], what[0..n]);
        last_len = n;
    }
};

test "diagnose mode: a submission per dispatch, each named before it goes; the same results; a failure names its dispatch" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    emu = .{ .arena = &arena, .gpu_view = &gpu_view };
    var flaky = Flaky{ .inner = emu.device() };
    DiagLog.reset();
    var backend = try Backend.init(flaky.device(), plan, &fixture.index, src, .{ .max_batch = 16, .diagnose = DiagLog.log }, &asm_work);
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache();
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    const token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    const fence_before = emu.fence;
    const gtok = (try backend.forward(&gc, .{ .tokens = &prompt }, .logits)).?;
    try std.testing.expectEqual(token, gtok);
    _ = try compare(0, work.logits[0..VOCAB], backend.logits());
    // one submission and one line per dispatch, and a last line for the call
    try std.testing.expectEqual(@as(u64, backend.dispatches), emu.fence - fence_before);
    try std.testing.expectEqual(@as(usize, backend.dispatches), DiagLog.dispatch_lines);
    try std.testing.expectEqual(DiagLog.dispatch_lines + 1, DiagLog.lines);
    try std.testing.expect(std.mem.indexOf(u8, DiagLog.last[0..DiagLog.last_len], "dispatches done") != null);
    const per_call = backend.dispatches;

    // The normal path launches the same kernels, in one submission.
    var plain = try Backend.init(emu.device(), plan, &fixture.index, src, .{ .max_batch = 16 }, &asm_work);
    var pc = try plain.newCache(CONTEXT);
    const f0 = emu.fence;
    _ = try plain.forward(&pc, .{ .tokens = &prompt }, .logits);
    try std.testing.expectEqual(per_call, plain.dispatches);
    try std.testing.expectEqual(f0 + 1, emu.fence);

    // A dispatch that fails: the call is undone, and the log names it.
    DiagLog.reset();
    var conv_before: [conv_cpu.len]f32 = undefined;
    @memcpy(&conv_before, gc.cpu.conv);
    flaky.fail = error.DeviceLost;
    flaky.fail_after = 5;
    try std.testing.expectError(error.DeviceLost, backend.forward(&gc, .{ .tokens = &.{token} }, .logits));
    try std.testing.expectEqual(prompt.len, gc.cpu.position);
    try std.testing.expectEqualSlices(f32, &conv_before, gc.cpu.conv);
    try std.testing.expectEqual(@as(u32, 6), backend.dispatches);
    const failure = DiagLog.failure[0..DiagLog.failure_len];
    try std.testing.expect(std.mem.indexOf(u8, failure, "FAILED (DeviceLost): lfm3-gpu: dispatch 5, ") != null);
    try std.testing.expect(std.mem.endsWith(u8, failure, DiagLog.before_failure[0..DiagLog.before_failure_len]));
    std.debug.print("diagnose: {d} dispatches per call; a failure logs \"{s}\"\n", .{ per_call, failure });
    // And it picks up again.
    const again = (try backend.forward(&gc, .{ .tokens = &.{token} }, .logits)).?;
    const again_cpu = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(again_cpu, again);
}

// ── LFM3-Audio-2B's shapes ──────────────────────────────────────────────────

/// LFM3-Audio-2B as galaxy-think runs it: the GGUF's tensor list (names,
/// shapes, types, layer by layer as its header has them), with made-up
/// weights generated from the file offset. Each distinct tensor (name and
/// type) is stored once and every layer's tensor of that name and type
/// points at it: the kernels address a tensor from its start, so that
/// changes no address they compute, and the model buffer is 272 MB instead
/// of 1.1 GB (token_embd, the output matrix, is 215 MB of it).
const A2 = struct {
    const CAP = 320;
    const HID = 2048;
    const FFN = 7680;
    const NHEADS = 16;
    const NKV = 4;
    const HSIZE = 128;
    const NVOCAB = 128_000;
    const NTAPS = 7;
    const SWA = 256;
    const CTX = 64;
    const FILE_LAYERS = 24;
    /// The file's layers (its header): attention ones, the sliding ones,
    /// and which have a Q6_K ffn_down / attn_v (the others' are Q4_K).
    const attention = [_]u8{ 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22 };
    const sliding = [_]u8{ 4, 8, 12, 16, 20 };
    const down_q6k = [_]u8{ 0, 1, 2, 5, 8, 11, 14, 17, 20, 21, 22, 23 };
    const v_q6k = [_]u8{ 2, 8, 14, 20, 22 };
    const LIM = executor.Limits{ .hidden = HID, .feed_forward = FFN, .query = NHEADS * HSIZE, .key_value = NKV * HSIZE, .heads = NHEADS, .vocabulary = NVOCAB, .batch = 16, .context = CTX };

    fn has(list: []const u8, l: usize) bool {
        for (list) |x| if (x == l) return true;
        return false;
    }

    const Kind = enum { meta, norm, taps, q4k, q6k };
    const Region = struct { offset: u64, bytes: u64, kind: Kind, key: []const u8, ty: u32 };

    index: gguf.Index(CAP) = .{},
    plan: lfm3.Plan = .{},
    regions: [32]Region = undefined,
    n_regions: usize = 0,
    size: u64 = 0,
    /// Which of the file's layers each of ours is.
    layers: [FILE_LAYERS]u8 = undefined,
    n_layers: usize = 0,

    fn build(m: *A2, file_layers: []const u8) !void {
        m.* = .{};
        @memcpy(m.layers[0..file_layers.len], file_layers);
        m.n_layers = file_layers.len;
        const n = file_layers.len;
        // [0, 128): head_count_kv per layer (i32); [128, 152): sliding (u8)
        m.regions[0] = .{ .offset = 0, .bytes = 256, .kind = .meta, .key = "meta", .ty = 0 };
        m.n_regions = 1;
        m.size = 256;
        const s = &m.index.summary;
        s.architecture[0..4].* = "lfm3".*;
        s.architecture_len = 4;
        s.embedding_length = HID;
        s.block_count = @intCast(n);
        s.head_count = NHEADS;
        s.attention_key_length = HSIZE;
        s.attention_value_length = HSIZE;
        s.feed_forward_length = FFN;
        s.vocab_size = NVOCAB;
        s.rope_frequency_base = 1_000_000;
        s.rope_frequency_base_swa = 10_000;
        s.rms_norm_epsilon = 0.00001;
        s.sliding_window = SWA;
        s.shortconv_l_cache = NTAPS;
        s.head_count_kv_layers = .{ .present = true, .element_type = 5, .count = @intCast(n), .data_offset = 0 };
        s.sliding_window_pattern = .{ .present = true, .element_type = 7, .count = @intCast(n), .data_offset = 128 };
        try m.tensor("output_norm.weight", HID, 0, 0, "norm");
        try m.tensor("rope_freqs.weight", HSIZE / 2, 0, 0, "rope");
        try m.tensor("token_embd.weight", HID, NVOCAB, 14, "token_embd");
        for (file_layers, 0..) |fl, li| {
            try m.layer(li, "attn_norm.weight", HID, 0, 0, "norm");
            try m.layer(li, "ffn_norm.weight", HID, 0, 0, "norm");
            try m.layer(li, "post_attention_norm.weight", HID, 0, 0, "norm");
            try m.layer(li, "post_ffw_norm.weight", HID, 0, 0, "norm");
            try m.layer(li, "ffn_gate.weight", HID, FFN, 12, "ffn_gate");
            try m.layer(li, "ffn_up.weight", HID, FFN, 12, "ffn_up");
            try m.layer(li, "ffn_down.weight", FFN, HID, if (has(&down_q6k, fl)) 14 else 12, "ffn_down");
            if (has(&attention, fl)) {
                try m.layer(li, "attn_q.weight", HID, NHEADS * HSIZE, 12, "attn_q");
                try m.layer(li, "attn_k.weight", HID, NKV * HSIZE, 12, "attn_k");
                try m.layer(li, "attn_v.weight", HID, NKV * HSIZE, if (has(&v_q6k, fl)) 14 else 12, "attn_v");
                try m.layer(li, "attn_gate.weight", HID, NHEADS, 12, "attn_gate");
                try m.layer(li, "attn_output.weight", NHEADS * HSIZE, HID, 12, "attn_output");
                try m.layer(li, "attn_q_norm.weight", HSIZE, 0, 0, "head_norm");
                try m.layer(li, "attn_k_norm.weight", HSIZE, 0, 0, "head_norm");
            } else {
                try m.layer(li, "shortconv.in_proj.weight", HID, 3 * HID, 12, "in_proj");
                try m.layer(li, "shortconv.out_proj.weight", HID, HID, 12, "out_proj");
                try m.layer(li, "shortconv.conv.weight", NTAPS, HID, 0, "taps");
            }
        }
        try lfm3.build(CAP, m.source(), &m.index, &m.plan);
    }

    fn layer(m: *A2, l: usize, suffix: []const u8, inner: usize, outer: usize, ggml_type: u32, key: []const u8) !void {
        var name: [64]u8 = undefined;
        try m.tensor(try std.fmt.bufPrint(&name, "blk.{d}.{s}", .{ l, suffix }), inner, outer, ggml_type, key);
    }

    fn tensor(m: *A2, name: []const u8, inner: usize, outer: usize, ggml_type: u32, key: []const u8) !void {
        const elements: u64 = inner * @max(outer, 1);
        const bytes: u64 = switch (ggml_type) {
            0 => elements * 4,
            12 => elements / quantized.QK_K * quantized.Q4_K_BLOCK_BYTES,
            else => elements / quantized.QK_K * quantized.Q6_K_BLOCK_BYTES,
        };
        const kind: Kind = switch (ggml_type) {
            0 => if (std.mem.eql(u8, key, "taps")) .taps else .norm,
            12 => .q4k,
            else => .q6k,
        };
        const id = m.index.tensor_count;
        if (id >= CAP) return error.TooManyTensors;
        const info = &m.index.tensors[id];
        @memcpy(info.name[0..name.len], name);
        info.name_len = @intCast(name.len);
        info.dimension_count = if (outer == 0) 1 else 2;
        info.dimensions[0] = inner;
        if (outer != 0) info.dimensions[1] = outer;
        info.ggml_type = ggml_type;
        info.file_offset = m.stored(key, ggml_type, kind, bytes);
        info.byte_size = bytes;
        m.index.tensor_count += 1;
    }

    /// The offset of the bytes of the tensors called `key` of this type.
    fn stored(m: *A2, key: []const u8, ty: u32, kind: Kind, bytes: u64) u64 {
        for (m.regions[0..m.n_regions]) |r| {
            if (r.ty == ty and std.mem.eql(u8, r.key, key)) return r.offset;
        }
        m.size = std.mem.alignForward(u64, m.size, 32);
        m.regions[m.n_regions] = .{ .offset = m.size, .bytes = bytes, .kind = kind, .key = key, .ty = ty };
        m.n_regions += 1;
        m.size += bytes;
        return m.size - bytes;
    }

    fn mix(x: u64) u64 {
        var z = x +% 0x9e3779b97f4a7c15;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    const D4: u16 = @bitCast(@as(f16, 0.02));
    const DMIN4: u16 = @bitCast(@as(f16, 0.01));
    const D6: u16 = @bitCast(@as(f16, 0.002));

    /// The byte of the made-up file at `p`, in region `r`: random bytes,
    /// with small scales where Q4_K and Q6_K blocks keep them (as the small
    /// fixture's), norms near 1 and conv taps in [-0.5, 0.5).
    fn byteAt(m: *const A2, r: Region, p: u64) u8 {
        const rel = p - r.offset;
        switch (r.kind) {
            .meta => {
                if (rel < 128) {
                    const l = rel / 4;
                    if (l >= m.n_layers) return 0;
                    const v: u32 = if (has(&attention, m.layers[l])) NKV else 0;
                    return @truncate(v >> @intCast(8 * (rel % 4)));
                }
                const l = rel - 128;
                if (l >= m.n_layers) return 0;
                return @intFromBool(has(&sliding, m.layers[l]));
            },
            .norm, .taps => {
                const unit = @as(f32, @floatFromInt(mix(r.offset + rel / 4 * 4) % 1000)) / 1000.0;
                const v: f32 = if (r.kind == .taps) unit - 0.5 else 0.75 + unit / 2;
                return @truncate(@as(u32, @bitCast(v)) >> @intCast(8 * (rel % 4)));
            },
            .q4k => {
                const o = rel % quantized.Q4_K_BLOCK_BYTES;
                if (o < 2) return @truncate(D4 >> @intCast(8 * o));
                if (o < 4) return @truncate(DMIN4 >> @intCast(8 * (o - 2)));
                return @truncate(mix(p));
            },
            .q6k => {
                const o = rel % quantized.Q6_K_BLOCK_BYTES;
                if (o >= 208) return @truncate(D6 >> @intCast(8 * (o - 208)));
                if (o >= 192) return @bitCast(@as(i8, @intCast(@as(i32, @intCast(mix(p) % 32)) - 16)));
                return @truncate(mix(p));
            },
        }
    }

    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const m: *const A2 = @ptrCast(@alignCast(context));
        if (offset > m.size or destination.len > m.size - offset) return false;
        @memset(destination, 0);
        const end = offset + destination.len;
        for (m.regions[0..m.n_regions]) |r| {
            const lo = @max(r.offset, offset);
            const hi = @min(r.offset + r.bytes, end);
            var p = lo;
            while (p < hi) : (p += 1) destination[@intCast(p - offset)] = m.byteAt(r, p);
        }
        return true;
    }

    fn source(m: *const A2) gguf.Source {
        return .{ .context = m, .size = m.size, .read_at = read };
    }
};

const A2Backend = gpu.Backend(A2.CAP);
var a2: A2 = .{};
/// The model (272 MB), the activations for 64 tokens, the caches.
var a2_arena: [300 << 20]u8 align(4096) = undefined;
var a2_emu: adreno.device.EmuDevice = undefined;
var a2_work: executor.Workspace(A2.LIM) = .{};
var a2_kv: [11 * 2 * A2.NKV * A2.CTX * A2.HSIZE]u16 = @splat(0);
var a2_conv: [13 * (A2.NTAPS - 1) * A2.HID]f32 = @splat(0);
const a2_unpacked: executor.PackedWeights(A2.CAP) = .{};

/// The emulated GPU's failure in words (its kernel named), as the error.
fn a2Failure(b: *const A2Backend, e: anyerror) anyerror {
    var buf: [512]u8 = undefined;
    const name = b.kernelAt(a2_emu.fault.code_va);
    std.debug.print("GPU forward: {s}: {s}\n", .{ @errorName(e), a2_emu.describe(name, &buf) });
    return e;
}

/// A prompt of `n` tokens spread over the vocabulary, its last ones the
/// highest and lowest ids.
fn a2Prompt(buf: []u32, n: usize, seed: u32) []const u32 {
    var x = seed;
    for (buf[0..n]) |*t| {
        x = x *% 1664525 +% 1013904223;
        t.* = (x >> 8) % A2.NVOCAB;
    }
    if (n >= 2) {
        buf[n - 2] = A2.NVOCAB - 1;
        buf[n - 1] = 0;
    }
    return buf[0..n];
}

/// The emulator is slow unoptimized: in Debug builds the LFM3-Audio-2B
/// tests sample more thinly, and the full comparison runs only in an
/// optimized build (-OReleaseSafe: some three minutes).
const optimized = builtin.mode != .debug;

test "LFM3-Audio-2B's shapes, all 24 layers as galaxy-think runs them: every access of every dispatch inside its buffer" {
    // (sampled: every 16th workgroup in x (512th unoptimized) and the last;
    // addresses depend on the grid and the constants, not on the data, so
    // every edge is checked)
    try a2.build(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 });
    try std.testing.expectEqual(@as(usize, 287), a2.index.tensor_count);
    try std.testing.expectEqual(@as(u8, 11), a2.plan.attention_layer_count);
    a2_emu = .{ .arena = &a2_arena, .group_stride = if (optimized) 16 else 512, .sample_last = true };
    var backend = try A2Backend.init(a2_emu.device(), &a2.plan, &a2.index, a2.source(), .{ .max_batch = 64 }, &asm_work);
    var cache = try backend.newCache(A2.CTX);
    var buf: [64]u32 = undefined;
    // galaxy-think's first call: a prompt of 16 with logits
    _ = backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 16, 3) }, .logits) catch |e| return a2Failure(&backend, e);
    const per_call = backend.dispatches;
    // a decode step, batches of 39 and 7 (the 7-token matrix variant) that
    // fill the context to 63, and its last position
    _ = backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 1, 4) }, .logits) catch |e| return a2Failure(&backend, e);
    _ = backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 39, 5) }, .hidden) catch |e| return a2Failure(&backend, e);
    _ = backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 7, 8) }, .none) catch |e| return a2Failure(&backend, e);
    _ = backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 1, 6) }, .logits) catch |e| return a2Failure(&backend, e);
    try std.testing.expectEqual(@as(usize, A2.CTX), cache.cpu.position);
    try std.testing.expectError(error.ContextCapacity, backend.forward(&cache, .{ .tokens = a2Prompt(&buf, 1, 7) }, .logits));
    std.debug.print("LFM3-Audio-2B shapes, 24 layers: {d} dispatches for the 16-token prompt, all accesses inside their buffers ({d} workgroups, {d} instructions emulated)\n", .{ per_call, a2_emu.stats.workgroups, a2_emu.stats.instructions });
}

test "LFM3-Audio-2B's shapes, a layer of every kind and type: the 128,000 logits as the CPU's" {
    // the file's layers 0 (short conv, Q6_K ffn_down), 2 (attention, Q6_K
    // attn_v and ffn_down), 3 (short conv, Q4_K ffn_down), 4 (sliding
    // attention, Q4_K attn_v and ffn_down)
    if (!optimized) {
        std.debug.print("(run optimized, -OReleaseSafe: 150 million emulated instructions) ", .{});
        return error.SkipZigTest;
    }
    try a2.build(&.{ 0, 2, 3, 4 });
    a2_emu = .{ .arena = &a2_arena };
    var backend = try A2Backend.init(a2_emu.device(), &a2.plan, &a2.index, a2.source(), .{ .max_batch = 64 }, &asm_work);
    var gc = try backend.newCache(A2.CTX);
    @memset(&a2_kv, 0);
    @memset(&a2_conv, 0);
    const kv_n = try executor.requiredKvElements(&a2.plan, A2.CTX);
    const conv_n = try executor.requiredConvElements(&a2.plan);
    var cc = executor.Cache{ .kv = a2_kv[0..kv_n], .conv = a2_conv[0..conv_n], .context = A2.CTX };
    var buf: [16]u32 = undefined;
    const prompt = a2Prompt(&buf, 16, 11);
    // (the CPU reads the same bytes: the GPU's copy of the made-up file)
    const src = backend.source();
    const want = (try executor.forwardInput(A2.CAP, A2.LIM, src, &a2.index, &a2.plan, &a2_unpacked, &a2_work, &cc, .{ .tokens = prompt }, .logits, .{})).?;
    const got = (backend.forward(&gc, .{ .tokens = prompt }, .logits) catch |e| return a2Failure(&backend, e)).?;
    var worst = try compare(0, a2_work.logits[0..A2.NVOCAB], backend.logits());
    const step_want = (try executor.forwardInput(A2.CAP, A2.LIM, src, &a2.index, &a2.plan, &a2_unpacked, &a2_work, &cc, .{ .tokens = &.{want} }, .logits, .{})).?;
    const step_got = (backend.forward(&gc, .{ .tokens = &.{want} }, .logits) catch |e| return a2Failure(&backend, e)).?;
    worst = @max(worst, try compare(1, a2_work.logits[0..A2.NVOCAB], backend.logits()));
    std.debug.print("LFM3-Audio-2B shapes, 4 layers: logits within {e} of the CPU's (tokens {d}/{d}, then {d}/{d}; {d} instructions emulated)\n", .{ worst, got, want, step_got, step_want, a2_emu.stats.instructions });
}
