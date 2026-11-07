//! LFM3 on any GPU (lfm3_any over a gpu.Device) against the CPU executor,
//! on a synthetic four-layer model (short conv, full attention, short conv,
//! sliding attention, with sandwich norms), on the reference EmuDevice
//! under several devices' Caps: an ideal one, one that rounds mad twice
//! with no fused FMA and flushes denormals (an Adreno the self-test has not
//! measured), a discrete one (VRAM without a CPU view: staging and the copy
//! kernel), a non-coherent unified one (missing cache maintenance shows),
//! and subgroups of 8 and 64. Each: a prompt longer than one matrix pass,
//! then decode steps, logits compared at every step; then the CPU executor
//! takes over from the GPU's own state. Then: a failed call is undone, a
//! slow one waited out, caches kept apart, spans past max_span are the
//! CPU's; and a context past 4096 positions (today's GPU limit) on the GPU.

const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const quantized = @import("quantized_linear");
const gpu = @import("gpu");
const any = @import("lfm3_any");

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
/// Past lfm3_gpu's and lfm3_nv's MAX_ATTENTION_SPAN (4096).
const LONG = 4224;
const LIMITS = executor.Limits{ .hidden = HIDDEN, .feed_forward = FEED, .query = HEADS * HEAD, .key_value = KV_HEADS * HEAD, .heads = HEADS, .vocabulary = VOCAB, .batch = 16, .context = LONG };

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
            // (Q6_K matrices, as Q4_K_M files have: one of odd blocks a row)
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
                try self.layer(li, "shortconv.out_proj.weight", HIDDEN, HIDDEN, if (li == 2) 14 else 12);
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
    /// The file without a mapping (read only): the weights are copied.
    fn readOnly(self: *const Fixture) gguf.Source {
        return .{ .context = self, .size = self.used, .read_at = read };
    }
};

const Backend = any.Backend(CAPACITY);

var fixture: Fixture = .{};
var cpu_work: executor.Workspace(LIMITS) = .{};
var kv_cpu: [2 * 2 * KV_HEADS * LONG * HEAD]u16 = @splat(0);
var conv_cpu: [2 * (KERNEL - 1) * HIDDEN]f32 = @splat(0);
var mem: [64 << 20]u8 align(4096) = undefined;
var vram: [48 << 20]u8 align(4096) = undefined;
var shadow: [72 << 20]u8 align(4096) = undefined;
var interp_work: [16 << 20]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var work: any.Work = .{};
const unpacked: executor.PackedWeights(CAPACITY) = .{};

/// The logits' largest difference, relative to their largest magnitude.
fn compare(step: usize, cpu: []const f32, g: []const f32, tolerance: f64) !f64 {
    var scale: f64 = 0;
    for (cpu) |v| scale = @max(scale, @abs(@as(f64, v)));
    var worst: f64 = 0;
    for (cpu, g) |a, b| worst = @max(worst, @abs(@as(f64, a) - b));
    const rel = worst / @max(scale, 1e-6);
    if (!(rel <= tolerance)) {
        std.debug.print("step {d}: logits differ by {e} of {e}\n", .{ step, worst, scale });
        for (cpu, g, 0..) |a, b, i| std.debug.print("  {d}: cpu {d} gpu {d}\n", .{ i, a, b });
        return error.TestUnexpectedResult;
    }
    return rel;
}

/// The CPU executor's own cache (zeroed), for `context` positions.
fn cpuCache(context: usize) executor.Cache {
    const kv_n = executor.requiredKvElements(&fixture.plan, context) catch unreachable;
    @memset(kv_cpu[0..kv_n], 0);
    @memset(&conv_cpu, 0);
    return .{ .kv = kv_cpu[0..kv_n], .conv = &conv_cpu, .context = context };
}

const Device = enum { ideal, unfused, discrete, noncoherent, narrow, wide };

fn makeDevice(which: Device) gpu.Device {
    var caps = gpu.interp_caps;
    switch (which) {
        .ideal => {},
        .unfused => {
            caps.fused_fma = false;
            caps.mad = .unfused;
            caps.denormals = .flush;
            caps.subgroup = 64;
        },
        .discrete => {
            caps.memory = .discrete;
            caps.import = false;
        },
        .noncoherent => caps.coherent = false,
        .narrow => {
            // (and groups of at most 64: the row kernels' smaller shape)
            caps.subgroup = 8;
            caps.max_group = 64;
        },
        .wide => {
            caps.subgroup = 128;
            caps.fused_fma = false;
        },
    }
    emu = gpu.EmuDevice.init(caps, &mem, &interp_work);
    if (which == .discrete) emu.vram = &vram;
    if (which == .noncoherent) emu.shadow = &shadow;
    return emu.device();
}

fn failure(b: *const Backend, e: anyerror) anyerror {
    std.debug.print("GPU forward: {s} (device: {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d}; compile: {s})\n", .{
        @errorName(e),
        if (emu.last_error) |x| @errorName(x) else "-",
        @tagName(emu.trap.what),
        emu.trap.pc,
        emu.trap.group,
        emu.trap.thread,
        emu.trap.binding,
        emu.trap.offset,
        if (b.compile_error) |x| @errorName(x) else "-",
    });
    return e;
}

/// A prompt, decode steps, then the CPU on the GPU's state; the worst
/// relative logit difference.
fn followTheCpu(which: Device, tolerance: f64) !f64 {
    try fixture.initialize();
    const plan = &fixture.plan;
    // (the CPU executor maps its file; the discrete GPU's is read only: copied)
    const src = fixture.source();
    const gpu_src = if (which == .discrete) fixture.readOnly() else src;
    const d = makeDevice(which);
    var backend = Backend.init(d, plan, &fixture.index, gpu_src, .{ .max_batch = 16, .attention_tokens = 8 }, &work) catch |e| {
        std.debug.print("init on {s}: {s}\n", .{ @tagName(which), @errorName(e) });
        return e;
    };
    defer backend.deinit();
    if (which != .discrete) try std.testing.expect(backend.imported == (d.caps.import and d.caps.memory == .unified));
    var gc = try backend.newCache(CONTEXT);
    defer backend.freeCache(&gc);
    var ccache = cpuCache(CONTEXT);
    // A prompt of 11 (two matrix passes, two attention launches), then
    // decode steps fed the CPU's tokens.
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    var token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    const gtok = (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| return failure(&backend, e)).?;
    const prefill_ops = emu.stats.lane_ops;
    const prefill_dispatches = backend.dispatches;
    var worst = try compare(0, cpu_work.logits[0..VOCAB], backend.logits(), tolerance);
    try std.testing.expectEqual(token, gtok);
    var decode_ops: u64 = 0;
    for (1..8) |step| {
        const next = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
        const gnext = (backend.forward(&gc, .{ .tokens = &.{token} }, .logits) catch |e| return failure(&backend, e)).?;
        decode_ops += emu.stats.lane_ops;
        worst = @max(worst, try compare(step, cpu_work.logits[0..VOCAB], backend.logits(), tolerance));
        try std.testing.expectEqual(next, gnext);
        // the hidden row too
        token = next;
    }
    try std.testing.expectEqual(ccache.position, gc.cpu.position);
    // The CPU continues on the GPU's own state (model, KV, conv) and agrees.
    backend.toCpu(&gc);
    // (the model from the GPU's memory where the CPU can read it there)
    const model = if (which == .discrete) src else backend.source();
    const cpu_on_gpu_state = (try executor.forwardInput(CAPACITY, LIMITS, model, &fixture.index, plan, &unpacked, &cpu_work, &gc.cpu, .{ .tokens = &.{token} }, .logits, .{})).?;
    var logits_a: [VOCAB]f32 = undefined;
    @memcpy(&logits_a, cpu_work.logits[0..VOCAB]);
    const cpu_alone = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(cpu_alone, cpu_on_gpu_state);
    worst = @max(worst, try compare(99, cpu_work.logits[0..VOCAB], &logits_a, tolerance));
    // And the GPU picks up again after the CPU step.
    const gagain = (backend.forward(&gc, .{ .tokens = &.{cpu_alone} }, .logits) catch |e| return failure(&backend, e)).?;
    const cagain = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{cpu_alone} }, .logits, .{})).?;
    try std.testing.expectEqual(cagain, gagain);
    worst = @max(worst, try compare(100, cpu_work.logits[0..VOCAB], backend.logits(), tolerance));
    // ...and keeps the KV rows it writes from then on (they are the GPU's
    // again: a device with views apart shows when they are not)
    var t2 = cagain;
    for (101..104) |step| {
        const c2 = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{t2} }, .logits, .{})).?;
        const g2 = (backend.forward(&gc, .{ .tokens = &.{t2} }, .logits) catch |e| return failure(&backend, e)).?;
        worst = @max(worst, try compare(step, cpu_work.logits[0..VOCAB], backend.logits(), tolerance));
        try std.testing.expectEqual(c2, g2);
        t2 = c2;
    }
    // The memory speed probe (a copy of the weights' first MiB): the GPU
    // still agrees with the CPU after it (the copy writes its own buffer).
    const gbps = backend.copySpeed(1 << 20);
    // ...and the read probe (all the weights read, 16 bytes written apart
    // where their sum is the mark): built on every device, writing nothing
    // the model uses
    try std.testing.expect(backend.k.read != null);
    const read_gbps = backend.readSpeed(64 << 20);
    // (a device that keeps no dispatch times: no profile, the cache as it was)
    {
        const at = gc.cpu.position;
        try std.testing.expect(backend.profileStep(&gc, t2) == null);
        try std.testing.expectEqual(at, gc.cpu.position);
    }
    {
        const c3 = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{t2} }, .logits, .{})).?;
        const g3 = (backend.forward(&gc, .{ .tokens = &.{t2} }, .logits) catch |e| return failure(&backend, e)).?;
        worst = @max(worst, try compare(104, cpu_work.logits[0..VOCAB], backend.logits(), tolerance));
        try std.testing.expectEqual(c3, g3);
    }
    std.debug.print("{s}: copySpeed {d:.1} GB/s, readSpeed {d:.1} (-1: no timestamps)\n", .{ @tagName(which), gbps orelse -1, read_gbps orelse -1 });
    std.debug.print("{s}: logits within {e} of the CPU's over 13 steps; prefill of 11: {d} lane-ops, {d} dispatches; decode: {d} lane-ops, {d} dispatches a token\n", .{
        @tagName(which), worst, prefill_ops, prefill_dispatches, decode_ops / 7, backend.dispatches,
    });
    return worst;
}

test "a profiled run: each dispatch's time from the latest end before it, matrices by their tensor's role" {
    try std.testing.expectEqualStrings("ffn_down.weight", any.roleName("blk.17.ffn_down.weight"));
    try std.testing.expectEqualStrings("output.weight", any.roleName("output.weight"));
    const Roles = struct {
        pub fn of(_: @This(), d: any.Desc) struct { role: []const u8, bytes: u64 } {
            if (d.tensor) |t| return .{ .role = if (t == 1) "ffn_down.weight" else "attn_q.weight", .bytes = 100 };
            return .{ .role = "", .bytes = 0 };
        }
    };
    var p = any.Profile{};
    const descs = [_]any.Desc{
        .{ .kernel = "norm+quant", .layer = 0 },
        .{ .kernel = "matrix q4k", .layer = 0, .tensor = 0 },
        .{ .kernel = "matrix q6k", .layer = 0, .tensor = 1 },
        .{ .kernel = "norm+quant", .layer = 1 },
        .{ .kernel = "matrix q6k", .layer = 1, .tensor = 1 },
    };
    // (the third ends before the second: two that ran together; the
    // second's time is from the first's end, the third's 0)
    const ends = [_]u64{ 10, 50, 40, 70, 100 };
    p.addRun(&descs, &ends, 120, Roles{});
    try std.testing.expectEqual(@as(usize, 3), p.n);
    try std.testing.expectEqualStrings("norm+quant", p.slice()[0].nameSlice());
    try std.testing.expectEqual(@as(u64, 10 + 20), p.slice()[0].ns);
    try std.testing.expectEqual(@as(u32, 2), p.slice()[0].count);
    try std.testing.expectEqualStrings("matrix q4k attn_q.weight", p.slice()[1].nameSlice());
    try std.testing.expectEqual(@as(u64, 40), p.slice()[1].ns);
    try std.testing.expectEqualStrings("matrix q6k ffn_down.weight", p.slice()[2].nameSlice());
    try std.testing.expectEqual(@as(u64, 0 + 30), p.slice()[2].ns);
    try std.testing.expectEqual(@as(u64, 200), p.slice()[2].bytes);
    try std.testing.expectEqual(@as(u64, 20), p.tail_ns);
    try std.testing.expectEqual(@as(u64, 120), p.gpu_ns);
    try std.testing.expectEqual(@as(u32, 5), p.dispatches);
    // more kinds than it keeps: the rest in its last entry
    var q = any.Profile{};
    var names: [any.MAX_PROFILE + 5][8]u8 = undefined;
    for (&names, 0..) |*nm, i| {
        const t = std.fmt.bufPrint(nm, "k{d}", .{i}) catch unreachable;
        q.add(t, "", 1, 0);
    }
    try std.testing.expectEqual(@as(usize, any.MAX_PROFILE), q.n);
    try std.testing.expectEqualStrings("(more kinds)", q.slice()[any.MAX_PROFILE - 1].nameSlice());
    try std.testing.expectEqual(@as(u64, 6), q.slice()[any.MAX_PROFILE - 1].ns);
}

test "the any-GPU backend follows the CPU executor on an ideal GPU, and the CPU takes over from its state" {
    _ = try followTheCpu(.ideal, 1e-4);
}

test "...on a GPU without fused FMA, mad rounded twice, denormals flushed, subgroups of 64" {
    _ = try followTheCpu(.unfused, 1e-4);
}

test "...on discrete memory: VRAM without a CPU view, staging, the copy kernel" {
    _ = try followTheCpu(.discrete, 1e-4);
}

test "...on non-coherent unified memory (every hand-over checked)" {
    _ = try followTheCpu(.noncoherent, 1e-4);
}

test "every matrix layout for one-token passes, asked for: the CPU's logits through the model" {
    // (lanes a thread, blocks an iteration, slots side by side: a shape
    // with fewer blocks than their product keeps one block and one slot)
    for ([_][3]u32{ .{ 1, 1, 1 }, .{ 2, 1, 1 }, .{ 1, 2, 1 }, .{ 4, 2, 1 }, .{ 2, 4, 1 }, .{ 1, 1, 4 }, .{ 2, 2, 2 }, .{ 4, 1, 8 } }) |lus| {
        const lanes = lus[0];
        const unroll = lus[1];
        const slots = lus[2];
        try fixture.initialize();
        const plan = &fixture.plan;
        const src = fixture.source();
        var backend = try Backend.init(makeDevice(.ideal), plan, &fixture.index, src, .{ .max_batch = 16, .attention_tokens = 8, .matrix_lanes = lanes, .matrix_unroll = unroll, .matrix_slots = slots }, &work);
        defer backend.deinit();
        try std.testing.expect(backend.tunings().len > 0);
        for (backend.tunings()) |t| {
            try std.testing.expectEqual(lanes, t.lanes);
            if (t.blocks >= unroll * slots) {
                try std.testing.expectEqual(unroll, t.unroll);
                try std.testing.expectEqual(slots, t.slots);
            } else {
                try std.testing.expectEqual(@as(u32, 1), t.unroll);
                try std.testing.expectEqual(@as(u32, 1), t.slots);
            }
        }
        var gc = try backend.newCache(CONTEXT);
        defer backend.freeCache(&gc);
        var ccache = cpuCache(CONTEXT);
        const prompt = [_]u32{ 1, 5, 2, 7 };
        var token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
        const gtok = (try backend.forward(&gc, .{ .tokens = &prompt }, .logits)).?;
        try std.testing.expectEqual(token, gtok);
        _ = try compare(0, cpu_work.logits[0..VOCAB], backend.logits(), 1e-4);
        for (1..5) |step| {
            const next = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
            const gnext = (try backend.forward(&gc, .{ .tokens = &.{token} }, .logits)).?;
            _ = try compare(step, cpu_work.logits[0..VOCAB], backend.logits(), 1e-4);
            try std.testing.expectEqual(next, gnext);
            token = next;
        }
    }
}

test "...with subgroups of 8 (reductions through shared memory) in groups of 64, and of 128" {
    _ = try followTheCpu(.narrow, 1e-4);
    _ = try followTheCpu(.wide, 1e-4);
}

/// The emulated GPU, whose next wait fails (or runs out) when asked.
const Flaky = struct {
    inner: gpu.Device,
    fail: ?gpu.Error = null,

    fn device(f: *Flaky) gpu.Device {
        return .{ .ctx = f, .vtable = &vtable, .caps = f.inner.caps };
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
    fn unload(ctx: *anyopaque, p: *const gpu.Program) void {
        of(ctx).inner.unload(p);
    }
    fn run(ctx: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        return of(ctx).inner.run(ds);
    }
    fn wait(ctx: *anyopaque, f: gpu.Fence, timeout_us: u64) gpu.Error!void {
        const s = of(ctx);
        if (s.fail) |e| {
            s.fail = null;
            return e;
        }
        return s.inner.wait(f, timeout_us);
    }
    fn done(ctx: *anyopaque, f: gpu.Fence) bool {
        return of(ctx).inner.done(f);
    }
    fn lastRunNs(ctx: *anyopaque) u64 {
        return of(ctx).inner.lastRunNs();
    }
};

test "a failed GPU call leaves its cache as it was, a slow one is waited out, caches are apart, spans past max_span are the CPU's" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    var flaky = Flaky{ .inner = makeDevice(.ideal) };
    var backend = try Backend.init(flaky.device(), plan, &fixture.index, src, .{ .max_batch = 16, .max_span = 1024 }, &work);
    defer backend.deinit();
    var gc = try backend.newCache(CONTEXT);
    var ccache = cpuCache(CONTEXT);
    const prompt = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6 };
    const token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    try std.testing.expectEqual(token, (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| return failure(&backend, e)).?);

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
    const on_gpu_state = (try executor.forwardInput(CAPACITY, LIMITS, backend.source(), &fixture.index, plan, &unpacked, &cpu_work, &gc.cpu, .{ .tokens = &.{token} }, .logits, .{})).?;
    const alone = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(alone, on_gpu_state);

    // A call slower than the timeout: waited out, its result kept.
    flaky.fail = error.Timeout;
    const slow = (try backend.forward(&gc, .{ .tokens = &.{alone} }, .logits)).?;
    const slow_cpu = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{alone} }, .logits, .{})).?;
    try std.testing.expectEqual(slow_cpu, slow);
    try std.testing.expectEqual(@as(u32, 1), backend.slow);
    try std.testing.expectEqual(@as(u32, 1), backend.lost);

    // A second cache: its prompt leaves the first one's state alone.
    var other = try backend.newCache(CONTEXT);
    _ = try backend.forward(&other, .{ .tokens = &.{ 7, 7, 2, 0, 1 } }, .logits);
    const after = (try backend.forward(&gc, .{ .tokens = &.{slow} }, .logits)).?;
    const after_cpu = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{slow} }, .logits, .{})).?;
    try std.testing.expectEqual(after_cpu, after);
    try std.testing.expectEqual(@as(usize, 5), other.cpu.position);

    // Attention reaching further back than max_span: the CPU's.
    var long = try backend.newCache(1024 + 8);
    long.cpu.position = 1024 - 1;
    try std.testing.expectError(error.LongContext, backend.forward(&long, .{ .tokens = &.{ 1, 2 } }, .none));
    try std.testing.expectEqual(@as(usize, 1024 - 1), long.cpu.position);
    backend.freeCache(&long);
    backend.freeCache(&other);
    backend.freeCache(&gc);
}

/// Diagnose mode's lines, as a host's log gets them.
const Log = struct {
    var lines: usize = 0;
    var last: [320]u8 = undefined;
    var last_len: usize = 0;
    var first: [320]u8 = undefined;
    var first_len: usize = 0;
    var failed: usize = 0;

    fn put(what: []const u8) void {
        if (lines == 0) {
            first_len = @min(what.len, first.len);
            @memcpy(first[0..first_len], what[0..first_len]);
        }
        lines += 1;
        last_len = @min(what.len, last.len);
        @memcpy(last[0..last_len], what[0..last_len]);
        if (std.mem.indexOf(u8, what, "FAILED") != null) failed += 1;
    }
};

test "diagnose mode: a run a dispatch, each named before it is sent; the CPU's logits still; a failure names its dispatch" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    var flaky = Flaky{ .inner = makeDevice(.unfused) };
    var backend = try Backend.init(flaky.device(), plan, &fixture.index, src, .{ .max_batch = 16, .diagnose = Log.put, .diagnose_timeout_us = 1000 }, &work);
    defer backend.deinit();
    var gc = try backend.newCache(CONTEXT);
    defer backend.freeCache(&gc);
    var ccache = cpuCache(CONTEXT);
    const prompt = [_]u32{ 3, 1, 4, 1, 5, 9, 2, 6, 5 };
    Log.lines = 0;
    const token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    try std.testing.expectEqual(token, (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| return failure(&backend, e)).?);
    _ = try compare(0, cpu_work.logits[0..VOCAB], backend.logits(), 0);
    // a line a dispatch, then the summary
    try std.testing.expectEqual(@as(usize, backend.dispatches) + 1, Log.lines);
    std.debug.print("diagnose: {d} lines; the first: {s}\n  the last: {s}\n", .{ Log.lines, Log.first[0..Log.first_len], Log.last[0..Log.last_len] });
    try std.testing.expect(std.mem.startsWith(u8, Log.first[0..Log.first_len], "lfm3-any: dispatch 0, layer 0 of 4 (short conv): norm+quant, blk.0.attn_norm.weight, tokens 0-8 of 9"));
    try std.testing.expect(std.mem.indexOf(u8, Log.last[0..Log.last_len], "all ") != null);
    // a failed dispatch: logged with its name, the call undone
    flaky.fail = error.DeviceLost;
    Log.lines = 0;
    try std.testing.expectError(error.DeviceLost, backend.forward(&gc, .{ .tokens = &.{token} }, .logits));
    try std.testing.expectEqual(@as(usize, 1), Log.failed);
    std.debug.print("  on a failure: {s}\n", .{Log.last[0..Log.last_len]});
    try std.testing.expect(std.mem.startsWith(u8, Log.last[0..Log.last_len], "lfm3-any: FAILED (DeviceLost): dispatch 0, layer 0 of 4"));
    try std.testing.expectEqual(prompt.len, gc.cpu.position);
    // and the GPU goes on after it, as the CPU does
    const next = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
    try std.testing.expectEqual(next, (try backend.forward(&gc, .{ .tokens = &.{token} }, .logits)).?);
    _ = try compare(1, cpu_work.logits[0..VOCAB], backend.logits(), 0);
}

/// Random f16 keys and values at positions [0, end) of every attention
/// layer, in both caches.
fn fillHistory(gpu_kv: []u16, cpu_kv: []u16, end: usize) void {
    var seed: u32 = 4242;
    const plan = &fixture.plan;
    for (0..plan.attention_layer_count) |slot| for (0..2) |v| for (0..plan.max_kv_head_count) |h| {
        const row0 = (((slot * 2 + v) * plan.max_kv_head_count + h) * LONG) * HEAD;
        for (0..end * HEAD) |e| {
            seed = seed *% 1664525 +% 1013904223;
            const range: f32 = if (v == 0) 6.0 else 2.0;
            const x = (@as(f32, @floatFromInt(seed >> 8)) / 16777216.0 - 0.5) * range;
            const bits: u16 = @bitCast(@as(f16, @floatCast(x)));
            gpu_kv[row0 + e] = bits;
            cpu_kv[row0 + e] = bits;
        }
    };
}

test "a context past 4096 positions on the GPU: split-K attention over 4150 keys, decode and a short prefill" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const src = fixture.source();
    // (unfused, and the GPU's memory apart from the CPU's: every hand-over
    // of the history checked)
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.subgroup = 64;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &mem, &interp_work);
    emu.shadow = &shadow;
    const d = emu.device();
    var backend = try Backend.init(d, plan, &fixture.index, src, .{ .max_batch = 16, .attention_tokens = 4 }, &work);
    defer backend.deinit();
    var gc = try backend.newCache(LONG);
    defer backend.freeCache(&gc);
    var ccache = cpuCache(LONG);
    const start = 4150;
    fillHistory(gc.cpu.kv, ccache.kv, start);
    gc.kv_on_cpu = true;
    gc.cpu.position = start;
    ccache.position = start;
    // a prefill of 3 past the history, then decode steps
    const prompt = [_]u32{ 2, 9, 4 };
    var token = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    const g = (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| return failure(&backend, e)).?;
    const prefill_ops = emu.stats.lane_ops;
    var worst = try compare(0, cpu_work.logits[0..VOCAB], backend.logits(), 1e-4);
    try std.testing.expectEqual(token, g);
    var decode_ops: u64 = 0;
    for (1..4) |step| {
        const next = (try executor.forwardInput(CAPACITY, LIMITS, src, &fixture.index, plan, &unpacked, &cpu_work, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
        const gnext = (backend.forward(&gc, .{ .tokens = &.{token} }, .logits) catch |e| return failure(&backend, e)).?;
        decode_ops += emu.stats.lane_ops;
        worst = @max(worst, try compare(step, cpu_work.logits[0..VOCAB], backend.logits(), 1e-4));
        try std.testing.expectEqual(next, gnext);
        token = next;
    }
    std.debug.print("long context ({d} positions): logits within {e} of the CPU's; prefill of 3: {d} lane-ops; decode: {d} lane-ops a token\n", .{
        gc.cpu.position, worst, prefill_ops, decode_ops / 3,
    });
}

// ── LFM3-Audio-2B itself ─────────────────────────────────────────────────────

/// The model galaxy-think runs (skipped when it is not on this machine).
const REAL_PATH = "C:/Just-Things/models/lfm3/LFM3-Audio-2B-Q4_K_M.gguf";
const REAL_CAPACITY = 512;
const REAL_CONTEXT = 64;
const REAL_LIMITS = executor.Limits{ .hidden = 2048, .feed_forward = 7680, .query = 2048, .key_value = 512, .heads = 16, .vocabulary = 128_000, .batch = 16, .context = REAL_CONTEXT };
var real_index: gguf.Index(REAL_CAPACITY) = .{};
var real_plan: lfm3.Plan = .{};
var real_cpu: executor.Workspace(REAL_LIMITS) = .{};
var real_kv: [16 * 2 * 8 * REAL_CONTEXT * 128]u16 = @splat(0);
var real_conv: [24 * 8 * 2048]f32 = @splat(0);
const real_unpacked: executor.PackedWeights(REAL_CAPACITY) = .{};

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

test "LFM3-Audio-2B (its real shapes: vocabulary 128000, Q6_K rows of 30 blocks, 11 attention layers of 4 KV heads): galaxy-think's prompt of 16 on an Adreno's Caps, every access bounds-checked, the CPU's logits" {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, REAL_PATH, .{}) catch return error.SkipZigTest;
    defer file.close(io);
    const size = try file.length(io);
    var mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(io);
    const memory = Memory{ .bytes = mapping.memory };
    const src = memory.source();
    try gguf.parse(REAL_CAPACITY, src, &real_index);
    try lfm3.build(REAL_CAPACITY, src, &real_index, &real_plan);
    const plan = &real_plan;
    try std.testing.expectEqual(@as(u32, 128_000), plan.vocabulary_size);
    try std.testing.expectEqual(@as(u8, 11), plan.attention_layer_count);
    // the Surface's Adreno as measured: mad rounds twice, no fused FMA, waves of 64
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.subgroup = 64;
    emu = gpu.EmuDevice.init(caps, &mem, &interp_work);
    var backend = Backend2.init(emu.device(), plan, &real_index, src, .{ .max_batch = 16 }, &work) catch |e| {
        std.debug.print("init: {s}\n", .{@errorName(e)});
        return e;
    };
    defer backend.deinit();
    try std.testing.expect(backend.imported);
    var gc = try backend.newCache(REAL_CONTEXT);
    defer backend.freeCache(&gc);
    const kv_n = try executor.requiredKvElements(plan, REAL_CONTEXT);
    const conv_n = try executor.requiredConvElements(plan);
    @memset(real_kv[0..kv_n], 0);
    @memset(real_conv[0..conv_n], 0);
    var ccache = executor.Cache{ .kv = real_kv[0..kv_n], .conv = real_conv[0..conv_n], .context = REAL_CONTEXT };
    const prompt = [16]u32{ 1, 6, 6423, 708, 2, 1098, 22, 64400, 7, 127999, 3412, 13, 900, 41, 11500, 5 };
    var token = (try executor.forwardInput(REAL_CAPACITY, REAL_LIMITS, src, &real_index, plan, &real_unpacked, &real_cpu, &ccache, .{ .tokens = &prompt }, .logits, .{})).?;
    const g = (backend.forward(&gc, .{ .tokens = &prompt }, .logits) catch |e| return failure2(&backend, e)).?;
    var worst = try compare(0, real_cpu.logits[0..plan.vocabulary_size], backend.logits(), 1e-3);
    try std.testing.expectEqual(token, g);
    const prefill_ops = emu.stats.lane_ops;
    for (1..3) |step| {
        const next = (try executor.forwardInput(REAL_CAPACITY, REAL_LIMITS, src, &real_index, plan, &real_unpacked, &real_cpu, &ccache, .{ .tokens = &.{token} }, .logits, .{})).?;
        const gnext = (backend.forward(&gc, .{ .tokens = &.{token} }, .logits) catch |e| return failure2(&backend, e)).?;
        worst = @max(worst, try compare(step, real_cpu.logits[0..plan.vocabulary_size], backend.logits(), 1e-3));
        try std.testing.expectEqual(next, gnext);
        token = next;
    }
    std.debug.print("LFM3-Audio-2B: logits within {e} of the CPU's over a prompt of 16 and 2 decode steps; prefill {d} lane-ops, decode {d} lane-ops and {d} dispatches a token\n", .{ worst, prefill_ops, emu.stats.lane_ops, backend.dispatches });
}

const Backend2 = any.Backend(REAL_CAPACITY);

fn failure2(b: *const Backend2, e: anyerror) anyerror {
    std.debug.print("GPU forward: {s} (device: {s}, trap {s} at {d}, group {any}, thread {d}, binding {d}, offset {d})\n", .{
        @errorName(e),
        if (emu.last_error) |x| @errorName(x) else "-",
        @tagName(emu.trap.what),
        emu.trap.pc,
        emu.trap.group,
        emu.trap.thread,
        emu.trap.binding,
        emu.trap.offset,
    });
    _ = b;
    return e;
}

// ── LFM3-Audio's depthformer (lfm3_any_audio) ───────────────────────────────

const gen = @import("lfm3_audio_gen");
const any_audio = @import("lfm3_any_audio");
const MMPROJ_PATH = "C:/Just-Things/models/lfm3/mmproj-LFM3-Audio-2B-Q8_0.gguf";
const AUDIO_CAPACITY = 1024;
var audio_index: gguf.Index(AUDIO_CAPACITY) = .{};
var audio_plan: gen.Plan = .{};
var depth_work: gen.DepthWorkspace(gen.lfm3_audio_limits) = .{};

fn depthAgainstCpu(caps: gpu.Caps, src: gguf.Source, tolerance: f64) !void {
    emu = gpu.EmuDevice.init(caps, &mem, &interp_work);
    var depth = any_audio.Depth(AUDIO_CAPACITY).init(emu.device(), &audio_plan, &audio_index, src, .{}, &work) catch |e| {
        std.debug.print("depth init: {s}\n", .{@errorName(e)});
        return e;
    };
    defer depth.deinit();
    var seed: u32 = 77;
    var state: [2048]f32 = undefined;
    for (state[0..audio_plan.backbone]) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = (@as(f32, @floatFromInt(seed >> 8)) / 16777216.0 - 0.5) * 4;
    }
    try gen.projectState(AUDIO_CAPACITY, gen.lfm3_audio_limits, src, &audio_index, &audio_plan, &depth_work, state[0..audio_plan.backbone], .{});
    try depth.projectState(state[0..audio_plan.backbone]);
    const n = gen.CODEBOOKS * audio_plan.vocabulary;
    // three passes as the Speaker makes them: all masked, 4 revealed, 8 revealed
    const passes = [3][gen.CODEBOOKS]i32{
        .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 17, -1, -1, 1200, -1, -1, 5, -1, -1, 2015, -1, -1 },
        .{ 17, 300, -1, 1200, 44, -1, 5, 8, -1, 2015, 999, -1 },
    };
    for (passes, 0..) |codes, pass| {
        try gen.codePass(AUDIO_CAPACITY, gen.lfm3_audio_limits, src, &audio_index, &audio_plan, &depth_work, &codes, .{});
        const got = depth.codePass(&codes) catch |e| {
            std.debug.print("depth pass {d}: {s} (device {s}, trap {s} at {d})\n", .{ pass, @errorName(e), if (emu.last_error) |x| @errorName(x) else "-", @tagName(emu.trap.what), emu.trap.pc });
            return e;
        };
        var exact: usize = 0;
        for (depth_work.logits[0..n], got) |a, b| {
            if (@as(u32, @bitCast(a)) == @as(u32, @bitCast(b))) exact += 1;
        }
        const rel = try compare(pass, depth_work.logits[0..n], got, tolerance);
        std.debug.print("depthformer ({s}) pass {d}: logits within {e} of the CPU's, {d} of {d} its bits; {d} dispatches, {d} lane-ops\n", .{ if (caps.fused_fma) "fused" else "unfused", pass, rel, exact, n, depth.dispatches, emu.stats.lane_ops });
    }
    // Whole frames: the Speaker on the CPU's depthformer and on the GPU's
    // (frameOn), the same sampling and seed: the same codes, frame by frame.
    const L = gen.lfm3_audio_limits;
    var on_cpu = gen.Speaker(L).init(gen.modelSampling(&audio_plan, 1234));
    var on_gpu = gen.Speaker(L).init(gen.modelSampling(&audio_plan, 1234));
    for (0..3) |f| {
        for (state[0..audio_plan.backbone], 0..) |*v, i| v.* += @as(f32, @floatFromInt((i + f) % 7)) * 0.01;
        const a = try on_cpu.frame(AUDIO_CAPACITY, src, &audio_index, &audio_plan, &depth_work, state[0..audio_plan.backbone], .{});
        const b = try on_gpu.frameOn(&depth, &audio_plan, state[0..audio_plan.backbone]);
        try std.testing.expectEqual(a.end, b.end);
        try std.testing.expectEqualSlices(i32, &a.codes, &b.codes);
    }
}

test "LFM3-Audio's depthformer on the GPU (when its mmproj is here): projectState and three codePass passes, the CPU's logits" {
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, MMPROJ_PATH, .{}) catch return error.SkipZigTest;
    defer file.close(io);
    const size = try file.length(io);
    var mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(io);
    const memory = Memory{ .bytes = mapping.memory };
    const src = memory.source();
    try gguf.parse(AUDIO_CAPACITY, src, &audio_index);
    try gen.build(AUDIO_CAPACITY, src, &audio_index, &audio_plan);
    const dp = &audio_plan.depth;
    std.debug.print("depthformer: {d} layers, hidden {d}, ff {d}, {d} heads of {d} ({d} KV), vocabulary {d}\n", .{ dp.layer_count, dp.hidden, dp.feed_forward, dp.heads, dp.head_size, dp.kv_heads, audio_plan.vocabulary });
    // a GPU that fuses (the RTX): the CPU's bits
    try depthAgainstCpu(gpu.interp_caps, src, 0);
    // the Adreno's measured caps (mad rounds twice): the exact fma emulation, the CPU's bits too
    var caps = gpu.interp_caps;
    caps.fused_fma = false;
    caps.mad = .unfused;
    caps.subgroup = 64;
    try depthAgainstCpu(caps, src, 0);
}

// ── locate: where the GPU parts from the CPU ────────────────────────────────

/// The emulated GPU, running each dispatch alone and changing one word of
/// one binding after every dispatch of one program: a kernel that
/// computes wrong.
const Corrupt = struct {
    inner: gpu.Device,
    code: u64 = 0,
    binding: usize = 0,
    word: usize = 0,
    hits: usize = 0,

    fn device(c: *Corrupt) gpu.Device {
        return .{ .ctx = c, .vtable = &vtable, .caps = c.inner.caps };
    }
    const vtable = gpu.Device.VTable{ .alloc = alloc, .free = free, .import = import, .toDevice = toDevice, .fromDevice = fromDevice, .load = load, .unload = unload, .run = run, .wait = wait, .done = done, .lastRunNs = lastRunNs };
    fn of(ctx: *anyopaque) *Corrupt {
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
    fn unload(ctx: *anyopaque, p: *const gpu.Program) void {
        of(ctx).inner.unload(p);
    }
    fn run(ctx: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        const c = of(ctx);
        var f: gpu.Fence = 0;
        for (ds) |*d| {
            f = try c.inner.run(d[0..1]);
            try c.inner.wait(f, std.math.maxInt(u64));
            if (d.prog.code.gpu == c.code) {
                const b = d.buffers[c.binding];
                c.inner.fromDevice(b, 0, b.bytes);
                // (VRAM without a CPU view: emu_device's arena, from its VRAM_VA)
                const bytes = if (b.cpu.len != 0) b.cpu else vram[@intCast(b.gpu - EMU_VRAM_VA)..][0..@intCast(b.bytes)];
                // (a large change: a last-bit one can vanish in the next int8 quantization)
                const v: *align(1) f32 = @ptrCast(bytes[c.word * 4 ..][0..4]);
                v.* = v.* * 4 + 3;
                c.inner.toDevice(b, 0, b.bytes);
                c.hits += 1;
            }
        }
        return f;
    }
    fn wait(ctx: *anyopaque, f: gpu.Fence, t: u64) gpu.Error!void {
        return of(ctx).inner.wait(f, t);
    }
    fn done(ctx: *anyopaque, f: gpu.Fence) bool {
        return of(ctx).inner.done(f);
    }
    fn lastRunNs(ctx: *anyopaque) u64 {
        return of(ctx).inner.lastRunNs();
    }
};

/// emu_device's VRAM_VA: where its discrete `.device` buffers start.
const EMU_VRAM_VA: u64 = 0x2_0000_0000;

fn sayLine(what: []const u8) void {
    std.debug.print("  {s}\n", .{what});
}

fn cpuReference() Backend.CpuReference(LIMITS) {
    return .{ .source = fixture.source(), .weights = &unpacked, .work = &cpu_work, .kv = &kv_cpu, .conv = &conv_cpu };
}

test "locate: no difference on a GPU that agrees; a kernel made wrong is found and named" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    var corrupt = Corrupt{ .inner = makeDevice(.unfused) };
    var backend = try Backend.init(corrupt.device(), plan, &fixture.index, fixture.source(), .{ .max_batch = 16 }, &work);
    defer backend.deinit();
    std.debug.print("locate, nothing wrong:\n", .{});
    try std.testing.expect((try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)) == null);
    // the short convolution's output: layer 0's conv
    corrupt.code = backend.k.conv.?.code.gpu;
    corrupt.binding = 3;
    corrupt.word = 7;
    std.debug.print("locate, the conv kernel made wrong:\n", .{});
    const w1 = (try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)).?;
    try std.testing.expectEqual(@as(?u8, 0), w1.layer);
    try std.testing.expectEqualStrings("conv", w1.kernel);
    // a Q6_K matrix's output (8-token passes): layer 1's attn_v, the first Q6_K
    corrupt.code = backend.k.q6k[7].?.code.gpu;
    corrupt.binding = 4;
    corrupt.word = 3;
    std.debug.print("locate, the 8-token Q6_K matrix made wrong:\n", .{});
    const w2 = (try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)).?;
    try std.testing.expectEqual(@as(?u8, 1), w2.layer);
    try std.testing.expectEqualStrings("matrix q6k", w2.kernel);
    const t = &fixture.index.tensors[w2.tensor.?];
    try std.testing.expectEqualStrings("blk.1.attn_v.weight", t.name[0..t.name_len]);
    // attention (its combine's output), layer 1
    corrupt.code = backend.k.combine.?.code.gpu;
    corrupt.binding = 2;
    corrupt.word = 130;
    std.debug.print("locate, attention made wrong:\n", .{});
    const w3 = (try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)).?;
    try std.testing.expectEqual(@as(?u8, 1), w3.layer);
    try std.testing.expectEqualStrings("attention (scores, softmax, values, combine)", w3.kernel);
    // the logits' matrix only (the last dispatch): every layer agrees
    corrupt.code = 0;
    try std.testing.expect(corrupt.hits > 0);
}

test "locate on discrete memory: VRAM without CPU views read back through the copy kernel; a kernel made wrong is found" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    var corrupt = Corrupt{ .inner = makeDevice(.discrete) };
    var backend = try Backend.init(corrupt.device(), plan, &fixture.index, fixture.source(), .{ .max_batch = 16 }, &work);
    defer backend.deinit();
    try std.testing.expect(backend.s.hidden.cpu.len == 0 and backend.weights.cpu.len == 0);
    std.debug.print("locate (discrete), nothing wrong:\n", .{});
    try std.testing.expect((try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)) == null);
    corrupt.code = backend.k.q6k[7].?.code.gpu;
    corrupt.binding = 4;
    corrupt.word = 3;
    std.debug.print("locate (discrete), the 8-token Q6_K matrix made wrong:\n", .{});
    const w = (try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)).?;
    try std.testing.expectEqual(@as(?u8, 1), w.layer);
    try std.testing.expectEqualStrings("matrix q6k", w.kernel);
    corrupt.code = backend.k.conv.?.code.gpu;
    corrupt.binding = 3;
    corrupt.word = 7;
    std.debug.print("locate (discrete), the conv kernel made wrong:\n", .{});
    const w2 = (try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)).?;
    try std.testing.expectEqual(@as(?u8, 0), w2.layer);
    try std.testing.expectEqualStrings("conv", w2.kernel);
    corrupt.code = 0;
}

test "exact_sqrt: every fsqrt and fdiv expanded in KIR before the backend, the CPU's bits still" {
    try fixture.initialize();
    const plan = &fixture.plan;
    const prompt = [_]u32{ 1, 5, 2, 7, 3, 9, 4, 4, 11, 0, 6 };
    inline for (.{ Device.ideal, Device.unfused }) |which| {
        var backend = try Backend.init(makeDevice(which), plan, &fixture.index, fixture.source(), .{ .max_batch = 16, .exact_sqrt = true }, &work);
        defer backend.deinit();
        try std.testing.expect((try backend.locate(LIMITS, cpuReference(), .{ .tokens = &prompt }, CONTEXT, 0, sayLine)) == null);
    }
}
