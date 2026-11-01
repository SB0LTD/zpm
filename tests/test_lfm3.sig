//! Executable contracts for the LFM3 hybrid decoder: metadata-driven layer
//! schedule, rolling short-convolution state, sliding-window bounds, RoPE
//! frequency factors, batch- and schedule-invariant execution, the LLAMA3
//! pre-split and the chat template. A synthetic four-layer Q4_K model lives in
//! static storage; no download or heap storage is required.
const std = @import("std");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const codec = @import("lfm3_tokenizer");
const quantized = @import("quantized_linear");

const CAPACITY = 64;
const HIDDEN = 256;
const HEADS = 2;
const HEAD = 128;
const FEED = 256;
const VOCAB = 8;
const KERNEL = 3;
const WINDOW = 4;
const LAYERS = 4;
const CONTEXT = 16;
const LIMITS = executor.Limits{ .hidden = HIDDEN, .feed_forward = FEED, .query = HEADS * HEAD,
    .key_value = HEAD, .heads = HEADS, .vocabulary = VOCAB, .batch = 8, .context = CONTEXT };
const Work = executor.Workspace(LIMITS);
const KV_ELEMENTS = 2 * 2 * 1 * CONTEXT * HEAD;
const CONV_ELEMENTS = 2 * (KERNEL - 1) * HIDDEN;

var assertions: usize = 0;
var executed_cases: usize = 0;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.Lfm3ContractFailed;
}
fn rejected(result: anytype, expected: anyerror) !void {
    if (result) |_| return error.InvalidOperationAccepted else |err| try check(err == expected);
}

/// Conv, full attention, conv, sliding attention: the LFM3 pattern in small.
const Schedule = struct {
    kv_heads: [LAYERS]i32 = .{ 0, 1, 0, 1 },
    sliding: [LAYERS]u8 = .{ 0, 0, 0, 1 },
    omit: []const u8 = "",
    sandwich: bool = true,
};

const Fixture = struct {
    bytes: [1536 * 1024]u8 = undefined,
    used: usize = 0,
    index: gguf.Index(CAPACITY) = .{},
    plan: lfm3.Plan = .{},
    seed: u32 = 1,

    fn initialize(self: *Fixture, schedule: Schedule) !void {
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
        summary.head_count_kv_layers = .{ .present = true, .element_type = 5, .count = LAYERS, .data_offset = self.used };
        for (schedule.kv_heads) |count| self.put(std.mem.asBytes(&count));
        summary.sliding_window_pattern = .{ .present = true, .element_type = 7, .count = LAYERS, .data_offset = self.used };
        self.put(&schedule.sliding);

        try self.matrix("token_embd.weight", HIDDEN, VOCAB, schedule);
        try self.vector("output_norm.weight", HIDDEN, schedule);
        try self.vector("rope_freqs.weight", HEAD / 2, schedule);
        for (0..LAYERS) |layer| {
            const attention = schedule.kv_heads[layer] != 0;
            try self.layerVector(layer, "attn_norm.weight", HIDDEN, schedule);
            try self.layerVector(layer, "ffn_norm.weight", HIDDEN, schedule);
            if (schedule.sandwich) {
                try self.layerVector(layer, "post_attention_norm.weight", HIDDEN, schedule);
                try self.layerVector(layer, "post_ffw_norm.weight", HIDDEN, schedule);
            }
            try self.layerMatrix(layer, "ffn_gate.weight", HIDDEN, FEED, schedule);
            try self.layerMatrix(layer, "ffn_up.weight", HIDDEN, FEED, schedule);
            try self.layerMatrix(layer, "ffn_down.weight", FEED, HIDDEN, schedule);
            if (attention) {
                try self.layerMatrix(layer, "attn_q.weight", HIDDEN, HEADS * HEAD, schedule);
                try self.layerMatrix(layer, "attn_k.weight", HIDDEN, HEAD, schedule);
                try self.layerMatrix(layer, "attn_v.weight", HIDDEN, HEAD, schedule);
                try self.layerMatrix(layer, "attn_gate.weight", HIDDEN, HEADS, schedule);
                try self.layerMatrix(layer, "attn_output.weight", HEADS * HEAD, HIDDEN, schedule);
                try self.layerVector(layer, "attn_q_norm.weight", HEAD, schedule);
                try self.layerVector(layer, "attn_k_norm.weight", HEAD, schedule);
            } else {
                try self.layerMatrix(layer, "shortconv.in_proj.weight", HIDDEN, 3 * HIDDEN, schedule);
                try self.layerMatrix(layer, "shortconv.out_proj.weight", HIDDEN, HIDDEN, schedule);
                var name: [64]u8 = undefined;
                try self.tensor(try std.fmt.bufPrint(&name, "blk.{d}.shortconv.conv.weight", .{layer}), KERNEL, HIDDEN, 0, schedule);
            }
        }
    }

    fn build(self: *Fixture) lfm3.Error!void {
        return lfm3.build(CAPACITY, self.source(), &self.index, &self.plan);
    }

    fn layerVector(self: *Fixture, layer: usize, suffix: []const u8, length: usize, schedule: Schedule) !void {
        var name: [64]u8 = undefined;
        try self.vector(try std.fmt.bufPrint(&name, "blk.{d}.{s}", .{ layer, suffix }), length, schedule);
    }
    fn layerMatrix(self: *Fixture, layer: usize, suffix: []const u8, inputs: usize, outputs: usize, schedule: Schedule) !void {
        var name: [64]u8 = undefined;
        try self.matrix(try std.fmt.bufPrint(&name, "blk.{d}.{s}", .{ layer, suffix }), inputs, outputs, schedule);
    }
    fn vector(self: *Fixture, name: []const u8, length: usize, schedule: Schedule) !void {
        try self.tensor(name, length, 0, 0, schedule);
    }
    fn matrix(self: *Fixture, name: []const u8, inputs: usize, outputs: usize, schedule: Schedule) !void {
        try self.tensor(name, inputs, outputs, 12, schedule);
    }

    /// F32 vectors are 0.75..1.25 (norm-like) or small taps; Q4_K rows get
    /// patterned quants with small positive f16 scales.
    fn tensor(self: *Fixture, name: []const u8, inner: usize, outer: usize, ggml_type: u32, schedule: Schedule) !void {
        if (std.mem.eql(u8, name, schedule.omit)) return;
        self.used = std.mem.alignForward(usize, self.used, 32);
        const id = self.index.tensor_count;
        if (id == CAPACITY or name.len > 64) return error.FixtureCapacity;
        const info = &self.index.tensors[id];
        @memcpy(info.name[0..name.len], name);
        info.name_len = @intCast(name.len);
        info.dimension_count = if (outer == 0) 1 else 2;
        info.dimensions[0] = inner;
        if (outer != 0) info.dimensions[1] = outer;
        info.ggml_type = ggml_type;
        info.file_offset = self.used;
        const elements = inner * @max(outer, 1);
        info.byte_size = if (ggml_type == 0) elements * 4 else elements / quantized.QK_K * quantized.Q4_K_BLOCK_BYTES;
        if (self.used + info.byte_size > self.bytes.len) return error.FixtureCapacity;
        if (ggml_type == 0) {
            const taps = std.mem.endsWith(u8, name, "conv.weight");
            for (0..elements) |_| {
                const unit = @as(f32, @floatFromInt(self.next() % 1000)) / 1000.0;
                const value: f32 = if (taps) unit - 0.5 else 0.75 + unit / 2;
                self.put(std.mem.asBytes(&value));
            }
        } else {
            for (0..info.byte_size / quantized.Q4_K_BLOCK_BYTES) |_| {
                var block: [quantized.Q4_K_BLOCK_BYTES]u8 = undefined;
                for (&block) |*byte| byte.* = @truncate(self.next());
                const d: u16 = @bitCast(@as(f16, 0.02));
                const dmin: u16 = @bitCast(@as(f16, 0.01));
                std.mem.writeInt(u16, block[0..2], d, .little);
                std.mem.writeInt(u16, block[2..4], dmin, .little);
                self.put(&block);
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

var fixture: Fixture align(64) = .{};
var work: Work = .{};
var kv_a: [KV_ELEMENTS]u16 = @splat(0);
var kv_b: [KV_ELEMENTS]u16 = @splat(0);
var conv_a: [CONV_ELEMENTS]f32 = @splat(0);
var conv_b: [CONV_ELEMENTS]f32 = @splat(0);
const unpacked: executor.PackedWeights(CAPACITY) = .{};
var logits_a: [VOCAB]f32 = undefined;
var packed_storage: [1536 * 1024]u8 align(64) = undefined;
var packed_weights: executor.PackedWeights(CAPACITY) = .{};

fn layerSchedule() !void {
    try fixture.initialize(.{});
    try fixture.build();
    const plan = &fixture.plan;
    try check(plan.layer_count == LAYERS and plan.conv_layer_count == 2 and plan.attention_layer_count == 2);
    try check(plan.layers[0].kind == .short_conv and plan.layers[1].kind == .attention and
        plan.layers[2].kind == .short_conv and plan.layers[3].kind == .attention);
    try check(plan.layers[0].slot == 0 and plan.layers[1].slot == 0 and plan.layers[2].slot == 1 and plan.layers[3].slot == 1);
    try check(!plan.layers[1].sliding_window and plan.layers[3].sliding_window);
    try check(plan.layers[1].kv_head_count == 1 and plan.max_kv_head_count == 1 and plan.layers[0].kv_head_count == 0);
    try check(plan.sandwich_norms and plan.output_is_tied and plan.rope_factors.present());
    try check(plan.conv_kernel == KERNEL and plan.sliding_window == WINDOW and plan.head_size == HEAD);
    try check(lfm3.layerKind(0) == .short_conv and lfm3.layerKind(4) == .attention);
    try check(try executor.requiredKvElements(plan, CONTEXT) == KV_ELEMENTS);
    try check(try executor.requiredConvElements(plan) == CONV_ELEMENTS);

    try fixture.initialize(.{ .sandwich = false });
    try fixture.build();
    try check(!fixture.plan.sandwich_norms);
    executed_cases += 1;
}

fn scheduleRejections() !void {
    try fixture.initialize(.{ .omit = "blk.2.shortconv.conv.weight" });
    try rejected(fixture.build(), error.MissingTensor);
    try fixture.initialize(.{ .omit = "blk.3.attn_gate.weight" });
    try rejected(fixture.build(), error.MissingTensor);
    try fixture.initialize(.{ .omit = "blk.1.post_ffw_norm.weight" });
    try rejected(fixture.build(), error.MissingTensor);
    try fixture.initialize(.{ .omit = "rope_freqs.weight" });
    try rejected(fixture.build(), error.MissingTensor);
    // llama.cpp refuses lfm3 without sliding layers and so do we.
    try fixture.initialize(.{ .sliding = .{ 0, 0, 0, 0 } });
    try rejected(fixture.build(), error.InvalidLayerSchedule);
    // A convolution layer cannot be windowed.
    try fixture.initialize(.{ .sliding = .{ 1, 0, 0, 1 } });
    try rejected(fixture.build(), error.InvalidLayerSchedule);
    // KV heads must divide the query heads.
    try fixture.initialize(.{ .kv_heads = .{ 0, 3, 0, 1 } });
    try rejected(fixture.build(), error.InvalidLayerSchedule);
    // Metadata that calls a convolution layer attention finds its conv tensors.
    try fixture.initialize(.{});
    const kv_offset: usize = @intCast(fixture.index.summary.head_count_kv_layers.data_offset);
    std.mem.writeInt(i32, fixture.bytes[kv_offset + 2 * 4 ..][0..4], 1, .little);
    try rejected(fixture.build(), error.UnexpectedTensor);
    try fixture.initialize(.{});
    fixture.index.summary.architecture[0..4].* = "lfm2".*;
    try rejected(fixture.build(), error.UnsupportedArchitecture);
    executed_cases += 1;
}

fn slidingWindowBounds() !void {
    for (0..WINDOW) |position| try check(lfm3.firstVisiblePosition(true, WINDOW, position) == 0);
    try check(lfm3.firstVisiblePosition(true, WINDOW, WINDOW) == 1);
    try check(lfm3.firstVisiblePosition(true, WINDOW, 10) == 7);
    try check(lfm3.firstVisiblePosition(false, WINDOW, 10) == 0);
    // The window always holds exactly WINDOW positions once full.
    for (WINDOW..40) |position| try check(position + 1 - lfm3.firstVisiblePosition(true, WINDOW, position) == WINDOW);
    executed_cases += 1;
}

fn ropeFactors() !void {
    var plain: [2 * HEAD]f32 = undefined;
    var scaled: [2 * HEAD]f32 = undefined;
    for (&plain, 0..) |*value, lane| value.* = @as(f32, @floatFromInt(lane % 17)) / 8.0 - 1.0;
    scaled = plain;
    var original = plain;
    executor.ropeNeox(&original, 2, HEAD, 0, 10_000, null);
    try check(std.mem.eql(f32, &original, &plain));
    // Dividing every angle by two at position 6 equals position 3: scaling by
    // a power of two keeps every rounding of the angle recurrence identical.
    const halves: [HEAD / 2]f32 = @splat(2.0);
    executor.ropeNeox(&plain, 2, HEAD, 3, 10_000, null);
    executor.ropeNeox(&scaled, 2, HEAD, 6, 10_000, &halves);
    try check(std.mem.eql(f32, &plain, &scaled));
    executed_cases += 1;
}

const CONV_TOKENS = 7;
const CONV_KERNEL = 4;
const CONV_CHANNELS = 5;

/// Batch and token-by-token convolution, and the direct causal formula over a
/// zero history, must agree bit for bit; the state keeps the last K-1 inputs.
fn convolutionState() !void {
    var mixed: [CONV_TOKENS * 3 * CONV_CHANNELS]f32 = undefined;
    var taps: [CONV_CHANNELS * CONV_KERNEL]f32 = undefined;
    var seed: u32 = 9;
    for (&mixed) |*value| value.* = patterned(&seed);
    for (&taps) |*value| value.* = patterned(&seed);

    var batch_state: [(CONV_KERNEL - 1) * CONV_CHANNELS]f32 = @splat(0);
    var batch: [CONV_TOKENS * CONV_CHANNELS]f32 = undefined;
    executor.shortConvChannels(CONV_KERNEL, CONV_CHANNELS, &taps, &batch_state, &mixed, CONV_TOKENS, &batch, 0, CONV_CHANNELS);

    var step_state: [(CONV_KERNEL - 1) * CONV_CHANNELS]f32 = @splat(0);
    var stepped: [CONV_TOKENS * CONV_CHANNELS]f32 = undefined;
    for (0..CONV_TOKENS) |token| {
        // Two channel ranges, as two workers would split them.
        executor.shortConvChannels(CONV_KERNEL, CONV_CHANNELS, &taps, &step_state, mixed[token * 3 * CONV_CHANNELS ..][0 .. 3 * CONV_CHANNELS], 1, stepped[token * CONV_CHANNELS ..][0..CONV_CHANNELS], 0, 2);
        executor.shortConvChannels(CONV_KERNEL, CONV_CHANNELS, &taps, &step_state, mixed[token * 3 * CONV_CHANNELS ..][0 .. 3 * CONV_CHANNELS], 1, stepped[token * CONV_CHANNELS ..][0..CONV_CHANNELS], 2, CONV_CHANNELS);
    }
    try check(std.mem.eql(f32, &batch, &stepped));
    try check(std.mem.eql(f32, &batch_state, &step_state));

    for (0..CONV_TOKENS) |token| {
        for (0..CONV_CHANNELS) |channel| {
            var sum: f32 = 0;
            for (0..CONV_KERNEL) |tap| {
                const source_token = @as(isize, @intCast(token + tap)) - (CONV_KERNEL - 1);
                const input = if (source_token < 0) 0 else gatedInput(&mixed, @intCast(source_token), channel);
                sum += input * taps[channel * CONV_KERNEL + tap];
            }
            const expected = mixed[token * 3 * CONV_CHANNELS + CONV_CHANNELS + channel] * sum;
            try check(batch[token * CONV_CHANNELS + channel] == expected);
        }
    }
    for (0..CONV_KERNEL - 1) |row| {
        for (0..CONV_CHANNELS) |channel| {
            const token = CONV_TOKENS - (CONV_KERNEL - 1) + row;
            try check(batch_state[row * CONV_CHANNELS + channel] == gatedInput(&mixed, token, channel));
        }
    }
    executed_cases += 1;
}

fn gatedInput(mixed: []const f32, token: usize, channel: usize) f32 {
    const row = mixed[token * 3 * CONV_CHANNELS ..][0 .. 3 * CONV_CHANNELS];
    return row[channel] * row[2 * CONV_CHANNELS + channel];
}

fn patterned(seed: *u32) f32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return @as(f32, @floatFromInt(seed.* >> 8)) / 16777216.0 - 0.5;
}

/// Runs every range of a task in reverse order and in pieces of three, as an
/// adversarial stand-in for a worker pool.
const ReversedPool = struct {
    calls: usize = 0,
    fn dispatch(context: *anyopaque, task: *const executor.Task) void {
        const self: *ReversedPool = @ptrCast(@alignCast(context));
        self.calls += 1;
        var end = task.count;
        while (end > 0) {
            const first = end -| 3;
            task.execute(task.context, first, end);
            end = first;
        }
    }
    fn parallel(self: *ReversedPool) executor.Parallel {
        return .{ .context = self, .dispatch = &dispatch };
    }
};

fn newCache(kv: []u16, conv: []f32) executor.Cache {
    var cache = executor.Cache{ .kv = kv, .conv = conv, .context = CONTEXT };
    cache.reset();
    return cache;
}

/// Twelve tokens cross the sliding window (4) and the batch (8). One prefill
/// split into batches, and one token at a time through a reordering
/// dispatcher, must reach bit-identical logits and recurrent state.
fn batchInvariance() !void {
    try fixture.initialize(.{});
    try fixture.build();
    const source = fixture.source();
    const prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 0, 3, 3, 5, 1 };
    var cache_a = newCache(&kv_a, &conv_a);
    const selected = try executor.prefill(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache_a, &prompt, .{});
    logits_a = work.logits;
    for (logits_a) |value| try check(std.math.isFinite(value));

    var pool = ReversedPool{};
    var cache_b = newCache(&kv_b, &conv_b);
    var stepped: ?u32 = null;
    for (prompt, 0..) |token, position| {
        stepped = try executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache_b, &.{token}, position + 1 == prompt.len, pool.parallel());
    }
    try check(pool.calls > 0 and stepped != null and stepped.? == selected);
    try check(std.mem.eql(f32, &logits_a, &work.logits));
    try check(std.mem.eql(f32, &conv_a, &conv_b));
    try check(std.mem.eql(u16, kv_a[0..], kv_b[0..]));
    try check(cache_a.position == prompt.len and cache_b.position == prompt.len);

    // Reset discards the history: replaying the prompt reproduces it.
    cache_a.reset();
    try check(try executor.prefill(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache_a, &prompt, .{}) == selected);
    try check(std.mem.eql(f32, &logits_a, &work.logits));
    executed_cases += 1;
}

/// Eight-row packed weights: one prefill and stepping through a reordering
/// dispatcher stay bit-identical, and both stay within float summation error
/// of the canonical row kernels. Matrices whose rows do not split into
/// eight-row groups (attn_gate, two rows) keep the canonical path.
fn packedExecution() !void {
    try fixture.initialize(.{});
    try fixture.build();
    const source = fixture.source();
    const required = try executor.requiredPackedBytes(CAPACITY, &fixture.index, &fixture.plan);
    try check(required > 0 and required <= packed_storage.len);
    try rejected(executor.packWeights(CAPACITY, source, &fixture.index, &fixture.plan, packed_storage[0 .. required - 1], &packed_weights, .{}), error.PackedCapacity);
    var pool = ReversedPool{};
    try executor.packWeights(CAPACITY, source, &fixture.index, &fixture.plan, &packed_storage, &packed_weights, pool.parallel());
    try check(packed_weights.bytes.len == required);
    for (fixture.plan.layers[0..LAYERS]) |layer| {
        try check(packed_weights.offsets[layer.ffn_down.index] != executor.NOT_PACKED);
        if (layer.attn_gate.present()) try check(packed_weights.offsets[layer.attn_gate.index] == executor.NOT_PACKED);
    }

    const prompt = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 0, 3, 3, 5, 1 };
    var cache_a = newCache(&kv_a, &conv_a);
    const canonical = try executor.prefill(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache_a, &prompt, .{});
    logits_a = work.logits;
    cache_a.reset();
    const selected = try executor.prefill(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &packed_weights, &work, &cache_a, &prompt, .{});
    try check(selected == canonical);
    for (logits_a, work.logits) |expected, actual| try check(@abs(actual - expected) <= 1e-5 * @max(1.0, @abs(expected)));
    logits_a = work.logits;

    var cache_b = newCache(&kv_b, &conv_b);
    var stepped: ?u32 = null;
    for (prompt, 0..) |token, position| {
        stepped = try executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &packed_weights, &work, &cache_b, &.{token}, position + 1 == prompt.len, pool.parallel());
    }
    try check(stepped != null and stepped.? == selected);
    try check(std.mem.eql(f32, &logits_a, &work.logits));
    try check(std.mem.eql(f32, &conv_a, &conv_b));
    try check(std.mem.eql(u16, kv_a[0..], kv_b[0..]));

    // An offset past the packed bytes is rejected before any worker runs.
    var truncated = packed_weights;
    truncated.bytes = truncated.bytes[0 .. truncated.bytes.len - 1];
    cache_b.reset();
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &truncated, &work, &cache_b, &.{1}, true, .{}), error.InvalidPlan);
    executed_cases += 1;
}

fn runtimeBounds() !void {
    try fixture.initialize(.{});
    try fixture.build();
    const source = fixture.source();
    var cache = newCache(&kv_a, &conv_a);
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache, &.{VOCAB}, true, .{}), error.InvalidToken);
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache, &.{}, true, .{}), error.BatchCapacity);
    const nine: [9]u32 = @splat(1);
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache, &nine, true, .{}), error.BatchCapacity);
    var short = executor.Cache{ .kv = kv_a[0 .. KV_ELEMENTS - 1], .conv = &conv_a, .context = CONTEXT };
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &short, &.{1}, true, .{}), error.KvCapacity);
    var shallow = executor.Cache{ .kv = &kv_a, .conv = conv_a[0 .. CONV_ELEMENTS - 1], .context = CONTEXT };
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &shallow, &.{1}, true, .{}), error.ConvCapacity);
    cache.position = CONTEXT - 1;
    try rejected(executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache, &.{ 1, 2 }, true, .{}), error.ContextCapacity);
    try check(try executor.forward(CAPACITY, LIMITS, source, &fixture.index, &fixture.plan, &unpacked, &work, &cache, &.{1}, false, .{}) == null);
    try check(cache.position == CONTEXT);
    executed_cases += 1;
}

fn pieces(text: []const u8, expected: []const []const u8) !void {
    var position: usize = 0;
    for (expected) |piece| {
        const length = codec.nextPiece(text[position..]);
        try check(std.mem.eql(u8, text[position..][0..length], piece));
        position += length;
    }
    try check(position == text.len);
}

/// Expected splits follow llama.cpp's unicode_regex_split_custom_llama3; the
/// real-vocabulary comparison lives in tools/lfm3_run.
fn preTokenizer() !void {
    try pieces("Hello world! It's 2026", &.{ "Hello", " world", "!", " It", "'s", " ", "202", "6" });
    try pieces("  x", &.{ " ", " x" });
    try pieces("a\n\n b", &.{ "a", "\n\n", " b" });
    try pieces("x = (1);\r\n", &.{ "x", " =", " (", "1", ");\r\n" });
    try pieces("I'LL go", &.{ "I", "'LL", " go" });
    try pieces("Größe 日本語 café", &.{ "Größe", " 日本語", " café" });
    try pieces("tail   ", &.{ "tail", "   " });
    executed_cases += 1;
}

fn specialTokens() !void {
    var specials = codec.SpecialTokens{};
    for ([_][]const u8{ "<|im_start|>", "<tool_call>", "<|im_end|>" }, [_]bool{ true, false, true }, 0..) |text, control, entry| {
        @memcpy(specials.text[entry][0..text.len], text);
        specials.lengths[entry] = @intCast(text.len);
        specials.control[entry] = control;
        specials.ids[entry] = @intCast(100 + entry);
    }
    specials.count = 3;
    try check(specials.match("<|im_start|>user", true).?.token == 100);
    try check(specials.match("<|im_start|>user", false) == null);
    // User-defined tokens are parsed even without control parsing.
    try check(specials.match("<tool_call>\n", false).?.length == "<tool_call>".len);
    try check(specials.match("<tool", true) == null);
    try check(specials.isControl(102) and !specials.isControl(101));
    executed_cases += 1;
}

fn chatTemplate() !void {
    var buffer: [1024]u8 = undefined;
    const tool = "{\"name\": \"set_timer\", \"parameters\": {}}";
    var length = try codec.renderChat(&.{
        .{ .role = .system, .content = "Be brief." },
        .{ .role = .user, .content = "Hi" },
        .{ .role = .assistant, .content = "<think>plan</think>\n Hello!" },
        .{ .role = .tool, .content = "{\"ok\": true}" },
        .{ .role = .user, .content = "Thanks" },
    }, .{ .tools = &.{tool} }, &buffer);
    try check(std.mem.eql(u8, buffer[0..length],
        "<|startoftext|><|im_start|>system\nBe brief.\n\n<tools>\n" ++ tool ++ "\n</tools><|im_end|>\n" ++
        "<|im_start|>user\nHi<|im_end|>\n" ++
        "<|im_start|>assistant\nHello!<|im_end|>\n" ++
        "<|im_start|>tool\n<tool_response>\n{\"ok\": true}\n</tool_response><|im_end|>\n" ++
        "<|im_start|>user\nThanks<|im_end|>\n<|im_start|>assistant\n"));
    // Thinking after the last user turn is kept; no system turn without a
    // system prompt or tools.
    length = try codec.renderChat(&.{
        .{ .role = .user, .content = "Hi" },
        .{ .role = .assistant, .content = "<think>x</think>y" },
    }, .{ .add_generation_prompt = false }, &buffer);
    try check(std.mem.eql(u8, buffer[0..length],
        "<|startoftext|><|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n<think>x</think>y<|im_end|>\n"));
    try rejected(codec.renderChat(&.{.{ .role = .user, .content = "Hi" }}, .{}, buffer[0..20]), error.TemplateCapacity);
    executed_cases += 1;
}

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag == .windows) {
        if (std.mem.indexOf(u16, init.minimal.args.vector,
            std.unicode.utf8ToUtf16LeStringLiteral("--prove-failure")) != null) try check(false);
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        if (args.next()) |argument| {
            if (std.mem.eql(u8, argument, "--prove-failure")) try check(false) else return error.UnknownArgument;
        }
    }
    try layerSchedule();
    try scheduleRejections();
    try slidingWindowBounds();
    try ropeFactors();
    try convolutionState();
    try batchInvariance();
    try packedExecution();
    try runtimeBounds();
    try preTokenizer();
    try specialTokens();
    try chatTemplate();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer,
        "{{\"suite\":\"lfm3\",\"pass\":true,\"cases\":{d},\"assertions\":{d}}}\n",
        .{ executed_cases, assertions });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
