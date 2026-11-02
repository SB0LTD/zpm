//! The LFM3 GPU backend against the CPU executor, on a synthetic four-layer
//! model (short conv, full attention, short conv, sliding attention, with
//! sandwich norms), run on the emulated Adreno: a prompt longer than one
//! matrix pass, then decode steps; logits compared at every step. Then the
//! CPU executor takes over from the GPU's own state (the fallback path), a
//! failed call is undone, a slow one waited out, two caches kept apart.

const std = @import("std");
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

/// The emulated GPU, whose next wait fails (or runs out) when asked.
const Flaky = struct {
    inner: adreno.device.Device,
    fail: ?adreno.device.Error = null,

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
            s.fail = null;
            return e;
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
