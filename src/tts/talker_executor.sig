//! Resumable pure-Sig decoder for Qwen3-TTS Talker and code predictor.
//!
//! Input embeddings are caller-owned because TTS combines projected text,
//! codec, language, speaker, and prior acoustic embeddings before each pass.
//! Matrix phases are row-sliced so the Nexus scheduler can service microphone,
//! display, cancellation, and PCM playback between bounded units of work.

const std = @import("std");
const plan_module = @import("tts_talker_plan");
const backend = @import("tts_talker_backend");
const transformer = @import("transformer_ops");
const kernels = @import("tts_kernels");

const HIDDEN = plan_module.HIDDEN;
const QUERY = plan_module.QUERY;
const KEY_VALUE = plan_module.KEY_VALUE;
const FEED_FORWARD = plan_module.FEED_FORWARD;
const HEAD_SIZE = plan_module.HEAD_DIM;
const HEAD_COUNT = plan_module.HEADS;
const KV_HEAD_COUNT = plan_module.KV_HEADS;

pub const Error = backend.Error || transformer.Error || error{
    InvalidPlan,
    ContextCapacity,
    KvCapacity,
    ArithmeticOverflow,
    Cancelled,
};

pub const Stage = enum(u8) {
    attention_query,
    attention_key,
    attention_value,
    attention_output,
    feed_forward_gate,
    feed_forward_up,
    feed_forward_down,
    layer_complete,
    logits,
};

pub const ProgressEvent = struct {
    stage: Stage,
    layer: u8,
    completed: u32,
    total: u32,
};

pub const Progress = struct {
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque, ProgressEvent) bool = null,

    fn report(self: Progress, event: ProgressEvent) Error!void {
        const callback = self.callback orelse return;
        const context = self.context orelse return error.InvalidPlan;
        if (!callback(context, event)) return error.Cancelled;
    }
};

pub const Phase = enum(u8) {
    idle,
    attention_norm,
    attention_query,
    attention_key,
    attention_value,
    attention_mix,
    attention_output,
    attention_residual,
    feed_forward_norm,
    feed_forward_gate,
    feed_forward_up,
    feed_forward_activate,
    feed_forward_down,
    feed_forward_residual,
    layer_complete,
    output_norm,
    logits,
    complete,
};

pub const Session = struct {
    phase: Phase = .idle,
    layer_index: usize = 0,
    row_index: usize = 0,
    position: usize = 0,
    produce_logits: bool = false,
    head: plan_module.TensorRef = .{},
    selected_token: ?u16 = null,

    pub fn active(self: Session) bool {
        return self.phase != .idle and self.phase != .complete;
    }
};

pub const StepResult = union(enum) {
    pending,
    complete: ?u16,
};

pub fn WorkingSet(comptime context_capacity: usize) type {
    if (context_capacity == 0) @compileError("Qwen3-TTS context capacity must be positive");
    return struct {
        hidden: [HIDDEN]f32 = @splat(0),
        normalized: [HIDDEN]f32 = @splat(0),
        weight: [HIDDEN]f32 = @splat(0),
        query: [QUERY]f32 = @splat(0),
        key: [KEY_VALUE]f32 = @splat(0),
        value: [KEY_VALUE]f32 = @splat(0),
        attention: [QUERY]f32 = @splat(0),
        gate: [FEED_FORWARD]f32 = @splat(0),
        up: [FEED_FORWARD]f32 = @splat(0),
        scores: [context_capacity]f32 = @splat(0),
        logits: [plan_module.CODEC_VOCABULARY]f32 = @splat(0),
        tensor_scratch: backend.Scratch = .{},

        pub fn staticBytes() usize {
            return @sizeOf(@This());
        }
    };
}

pub fn requiredKvElements(layer_count: usize, context_capacity: usize) Error!usize {
    if (layer_count == 0 or layer_count > plan_module.TALKER_LAYERS or context_capacity == 0)
        return error.InvalidPlan;
    return multiply(try multiply(try multiply(layer_count, 2 * KV_HEAD_COUNT), context_capacity), HEAD_SIZE);
}

pub fn begin(
    comptime context_capacity: usize,
    decoder: *const plan_module.Decoder,
    kv_storage: []u16,
    session: *Session,
    work: *WorkingSet(context_capacity),
    input_embedding: []const f32,
    position: usize,
    output_head: ?plan_module.TensorRef,
) Error!void {
    if (session.active() or decoder.layer_count == 0 or decoder.layer_count > plan_module.TALKER_LAYERS or
        input_embedding.len != HIDDEN or position >= context_capacity or
        (output_head != null and !output_head.?.present()))
        return error.InvalidPlan;
    if (kv_storage.len < try requiredKvElements(decoder.layer_count, context_capacity))
        return error.KvCapacity;
    @memcpy(&work.hidden, input_embedding);
    session.* = .{
        .phase = .attention_norm,
        .position = position,
        .produce_logits = output_head != null,
        .head = output_head orelse .{},
    };
}

pub fn step(
    comptime tensor_capacity: usize,
    comptime context_capacity: usize,
    source: backend.Source,
    index: *const backend.Index(tensor_capacity),
    decoder: *const plan_module.Decoder,
    work: *WorkingSet(context_capacity),
    kv_storage: []u16,
    session: *Session,
    row_budget: usize,
    progress: Progress,
) Error!StepResult {
    if (row_budget == 0 or session.phase == .idle or index.tensor_count == 0 or
        decoder.layer_count == 0 or session.position >= context_capacity or
        kv_storage.len < try requiredKvElements(decoder.layer_count, context_capacity))
        return error.InvalidPlan;
    if (session.phase == .complete)
        return .{ .complete = session.selected_token };
    const layer = if (session.layer_index < decoder.layer_count)
        &decoder.layers[session.layer_index]
    else
        null;
    const layer_u8: u8 = @intCast(@min(session.layer_index, decoder.layer_count));

    switch (session.phase) {
        .idle => unreachable,
        .attention_norm => {
            const current = layer orelse return error.InvalidPlan;
            try backend.readVector(source, tensor(index, current.attention_norm), &work.weight, &work.tensor_scratch);
            try transformer.rmsNorm(&work.hidden, &work.weight, &work.normalized, plan_module.RMS_EPSILON);
            session.phase = .attention_query;
        },
        .attention_query => {
            // Q, K, V all read `normalized` — compute them together so the GPU
            // path does one upload + one synchronizing download for all three.
            const cur = layer orelse return error.InvalidPlan;
            const infos = [_]*const backend.TensorInfo{
                tensor(index, cur.query),
                tensor(index, cur.key),
                tensor(index, cur.value),
            };
            const outs = [_][]f32{ &work.query, &work.key, &work.value };
            try backend.matvecMany(source, &infos, &work.normalized, &outs, &work.tensor_scratch);
            try progress.report(.{ .stage = .attention_value, .layer = layer_u8, .completed = @intCast(KEY_VALUE), .total = @intCast(KEY_VALUE) });
            session.phase = .attention_mix;
        },
        .attention_key => return error.InvalidPlan, // folded into attention_query
        .attention_value => return error.InvalidPlan, // folded into attention_query
        .attention_mix => {
            const current = layer orelse return error.InvalidPlan;
            try backend.readVector(source, tensor(index, current.query_norm), work.weight[0..HEAD_SIZE], &work.tensor_scratch);
            for (0..HEAD_COUNT) |head| {
                const values = work.query[head * HEAD_SIZE ..][0..HEAD_SIZE];
                try transformer.rmsNorm(values, work.weight[0..HEAD_SIZE], values, plan_module.RMS_EPSILON);
            }
            try backend.readVector(source, tensor(index, current.key_norm), work.weight[0..HEAD_SIZE], &work.tensor_scratch);
            for (0..KV_HEAD_COUNT) |head| {
                const values = work.key[head * HEAD_SIZE ..][0..HEAD_SIZE];
                try transformer.rmsNorm(values, work.weight[0..HEAD_SIZE], values, plan_module.RMS_EPSILON);
            }
            // Talker MRoPE receives equal temporal/height/width positions for
            // text/audio generation, reducing exactly to split-half RoPE.
            try transformer.ropeSplitHalf(&work.query, HEAD_COUNT, HEAD_SIZE, session.position, plan_module.ROPE_THETA);
            try transformer.ropeSplitHalf(&work.key, KV_HEAD_COUNT, HEAD_SIZE, session.position, plan_module.ROPE_THETA);
            try storeKv(decoder.layer_count, kv_storage, context_capacity, session.layer_index, session.position, &work.key, &work.value);
            try groupedAttention(decoder.layer_count, kv_storage, context_capacity, session.layer_index, session.position, &work.query, work.scores[0 .. session.position + 1], &work.attention);
            session.phase = .attention_output;
        },
        .attention_output => try stepMatrix(source, tensor(index, layer.?.attention_output), &work.attention, &work.normalized, &work.tensor_scratch, session, row_budget, progress, .attention_output, layer_u8, .attention_residual),
        .attention_residual => {
            try addResidual(&work.hidden, &work.normalized);
            session.phase = .feed_forward_norm;
        },
        .feed_forward_norm => {
            const current = layer orelse return error.InvalidPlan;
            try backend.readVector(source, tensor(index, current.ffn_norm), &work.weight, &work.tensor_scratch);
            try transformer.rmsNorm(&work.hidden, &work.weight, &work.normalized, plan_module.RMS_EPSILON);
            session.phase = .feed_forward_gate;
        },
        .feed_forward_gate => {
            // gate and up both read `normalized` — batch them.
            const cur = layer orelse return error.InvalidPlan;
            const infos = [_]*const backend.TensorInfo{
                tensor(index, cur.ffn_gate),
                tensor(index, cur.ffn_up),
            };
            const outs = [_][]f32{ &work.gate, &work.up };
            try backend.matvecMany(source, &infos, &work.normalized, &outs, &work.tensor_scratch);
            try progress.report(.{ .stage = .feed_forward_up, .layer = layer_u8, .completed = @intCast(FEED_FORWARD), .total = @intCast(FEED_FORWARD) });
            session.phase = .feed_forward_activate;
        },
        .feed_forward_up => return error.InvalidPlan, // folded into feed_forward_gate
        .feed_forward_activate => {
            try transformer.siluGate(&work.gate, &work.up);
            session.phase = .feed_forward_down;
        },
        .feed_forward_down => try stepMatrix(source, tensor(index, layer.?.ffn_down), &work.gate, &work.normalized, &work.tensor_scratch, session, row_budget, progress, .feed_forward_down, layer_u8, .feed_forward_residual),
        .feed_forward_residual => {
            try addResidual(&work.hidden, &work.normalized);
            session.phase = .layer_complete;
        },
        .layer_complete => {
            try progress.report(.{
                .stage = .layer_complete,
                .layer = layer_u8,
                .completed = @intCast(session.layer_index + 1),
                .total = decoder.layer_count,
            });
            session.layer_index += 1;
            session.phase = if (session.layer_index < decoder.layer_count) .attention_norm else .output_norm;
        },
        .output_norm => {
            try backend.readVector(source, tensor(index, decoder.output_norm), &work.weight, &work.tensor_scratch);
            try transformer.rmsNorm(&work.hidden, &work.weight, &work.normalized, plan_module.RMS_EPSILON);
            session.phase = if (session.produce_logits) .logits else .complete;
        },
        .logits => {
            const head = tensor(index, session.head);
            const rows = backend.matrixRows(head) orelse return error.InvalidPlan;
            const columns = backend.matrixColumns(head) orelse return error.InvalidPlan;
            if (columns != HIDDEN or rows > work.logits.len)
                return error.InvalidPlan;
            try stepMatrix(source, head, &work.normalized, work.logits[0..rows], &work.tensor_scratch, session, row_budget, progress, .logits, decoder.layer_count, .complete);
            if (session.phase == .complete)
                session.selected_token = @intCast(try argmax(work.logits[0..rows]));
        },
        .complete => unreachable,
    }
    return if (session.phase == .complete)
        .{ .complete = session.selected_token }
    else
        .pending;
}

fn stepMatrix(
    source: backend.Source,
    info: *const backend.TensorInfo,
    input: []const f32,
    output: []f32,
    scratch: *backend.Scratch,
    session: *Session,
    row_budget: usize,
    progress: Progress,
    stage: Stage,
    layer: u8,
    next_phase: Phase,
) Error!void {
    if (session.row_index == 0) try backend.prepareMatvec(input, scratch);
    session.row_index = try backend.matvecRows(source, info, input, output, null, session.row_index, row_budget, scratch);
    try progress.report(.{
        .stage = stage,
        .layer = layer,
        .completed = @intCast(session.row_index),
        .total = @intCast(output.len),
    });
    if (session.row_index == output.len) {
        session.row_index = 0;
        session.phase = next_phase;
    }
}

fn tensor(index: anytype, reference: plan_module.TensorRef) *const backend.TensorInfo {
    if (!reference.present() or reference.index >= index.tensor_count) unreachable;
    return &index.tensors[reference.index];
}

fn storeKv(
    layer_count: usize,
    storage: []u16,
    context_capacity: usize,
    layer: usize,
    position: usize,
    keys: []const f32,
    values: []const f32,
) Error!void {
    if (layer >= layer_count or keys.len != KEY_VALUE or values.len != KEY_VALUE)
        return error.InvalidPlan;
    for (0..KV_HEAD_COUNT) |head| {
        const source_offset = head * HEAD_SIZE;
        const key_offset = try kvOffset(layer_count, context_capacity, layer, false, head, position);
        const value_offset = try kvOffset(layer_count, context_capacity, layer, true, head, position);
        for (0..HEAD_SIZE) |lane| {
            const key = keys[source_offset + lane];
            const value = values[source_offset + lane];
            if (!std.math.isFinite(key) or !std.math.isFinite(value)) return error.NonFinite;
            storage[key_offset + lane] = transformer.f32ToF16Bits(key);
            storage[value_offset + lane] = transformer.f32ToF16Bits(value);
        }
    }
}

fn groupedAttention(
    layer_count: usize,
    storage: []const u16,
    context_capacity: usize,
    layer: usize,
    position: usize,
    queries: []const f32,
    scores: []f32,
    output: []f32,
) Error!void {
    if (queries.len != QUERY or output.len != QUERY or position >= context_capacity)
        return error.InvalidPlan;
    const group_size = HEAD_COUNT / KV_HEAD_COUNT;
    const context_length = position + 1;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(HEAD_SIZE)));
    for (0..HEAD_COUNT) |query_head| {
        const kv_head = query_head / group_size;
        const query = queries[query_head * HEAD_SIZE ..][0..HEAD_SIZE];
        for (scores[0..context_length], 0..) |*score, token_position| {
            const key_offset = try kvOffset(layer_count, context_capacity, layer, false, kv_head, token_position);
            var dot: f32 = 0;
            for (0..HEAD_SIZE) |lane|
                dot += query[lane] * transformer.f16BitsToF32(storage[key_offset + lane]);
            score.* = dot * scale;
        }
        try transformer.softmax(scores[0..context_length]);
        const destination = output[query_head * HEAD_SIZE ..][0..HEAD_SIZE];
        @memset(destination, 0);
        for (scores[0..context_length], 0..) |score, token_position| {
            const value_offset = try kvOffset(layer_count, context_capacity, layer, true, kv_head, token_position);
            for (0..HEAD_SIZE) |lane|
                destination[lane] += score * transformer.f16BitsToF32(storage[value_offset + lane]);
        }
    }
}

fn kvOffset(
    layer_count: usize,
    context_capacity: usize,
    layer: usize,
    values: bool,
    head: usize,
    position: usize,
) Error!usize {
    if (layer >= layer_count or head >= KV_HEAD_COUNT or position >= context_capacity)
        return error.InvalidPlan;
    var offset = try multiply(layer, 2);
    offset += @intFromBool(values);
    offset = try multiply(offset, KV_HEAD_COUNT);
    offset += head;
    offset = try multiply(offset, context_capacity);
    offset += position;
    return multiply(offset, HEAD_SIZE);
}

fn addResidual(destination: []f32, residual: []const f32) Error!void {
    if (destination.len != residual.len) return error.InvalidPlan;
    for (destination, residual) |*value, addition| {
        value.* += addition;
        if (!std.math.isFinite(value.*)) return error.NonFinite;
    }
}

fn argmax(values: []const f32) Error!usize {
    if (values.len == 0 or !std.math.isFinite(values[0])) return error.NonFinite;
    var best: usize = 0;
    for (values[1..], 1..) |value, index| {
        if (!std.math.isFinite(value)) return error.NonFinite;
        if (value > values[best]) best = index;
    }
    return best;
}

fn multiply(left: anytype, right: anytype) Error!usize {
    const result = @mulWithOverflow(@as(usize, @intCast(left)), @as(usize, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

test "released Talker and predictor KV footprints are exact" {
    try std.testing.expectEqual(@as(usize, 7_340_032), try requiredKvElements(plan_module.TALKER_LAYERS, 128));
    try std.testing.expectEqual(@as(usize, 163_840), try requiredKvElements(plan_module.PREDICTOR_LAYERS, 16));
    const TalkerWork = WorkingSet(128);
    try std.testing.expect(TalkerWork.staticBytes() < 128 * 1024);
}

test "single-position grouped attention returns each shared value" {
    var storage: [2 * KV_HEAD_COUNT * HEAD_SIZE]u16 = @splat(0);
    var keys: [KEY_VALUE]f32 = @splat(0.25);
    var values: [KEY_VALUE]f32 = undefined;
    for (&values, 0..) |*value, index| value.* = @floatFromInt(index % HEAD_SIZE);
    try storeKv(1, &storage, 1, 0, 0, &keys, &values);
    var queries: [QUERY]f32 = @splat(1);
    var scores: [1]f32 = undefined;
    var output: [QUERY]f32 = undefined;
    try groupedAttention(1, &storage, 1, 0, 0, &queries, &scores, &output);
    for (0..HEAD_COUNT) |head|
        try std.testing.expectEqualSlices(f32, values[(head / 2) * HEAD_SIZE ..][0..HEAD_SIZE], output[head * HEAD_SIZE ..][0..HEAD_SIZE]);
}

// ═══════════════════════════════════════════════════════════════════════════
// GPU-resident decoder forward — a device mirror of the row-sliced step()
// state machine, running one token through all layers (+ optional logits head)
// without per-matmul host round-trips. Used for both the Talker (28 layers,
// context 128) and the code predictor (5 layers, context 16); each gets its own
// GpuForward instance with an independent f32 KV cache.
//
// Grouped-query attention (16 q-heads / 8 kv-heads), per-head q/k RMSNorm,
// split-half RoPE (theta 1e6), full causal attention over the growing context.
// Full f32 (more faithful than the CPU Q4×Q8 path). Elementwise + attention on
// custom CUDA kernels; matmuls on cuBLAS over resident f32 weights. Downloads
// the final `normalized` (for past_hidden) and, when a head is given, `logits`
// (the sampler runs on the host as before).
// ═══════════════════════════════════════════════════════════════════════════

pub const GpuForward = struct {
    ready: bool = false,
    layers: usize = 0,
    context: usize = 0,
    hidden: kernels.CUdeviceptr = 0,
    normalized: kernels.CUdeviceptr = 0,
    q: kernels.CUdeviceptr = 0,
    k: kernels.CUdeviceptr = 0,
    v: kernels.CUdeviceptr = 0,
    attn: kernels.CUdeviceptr = 0,
    proj: kernels.CUdeviceptr = 0,
    gate: kernels.CUdeviceptr = 0,
    up: kernels.CUdeviceptr = 0,
    down: kernels.CUdeviceptr = 0,
    logits: kernels.CUdeviceptr = 0,
    // Per-layer f32 KV caches [context, KEY_VALUE].
    keys: [plan_module.TALKER_LAYERS]kernels.CUdeviceptr = @splat(0),
    values: [plan_module.TALKER_LAYERS]kernels.CUdeviceptr = @splat(0),

    pub fn init(self: *GpuForward, layers: usize, context: usize) bool {
        if (self.ready) return true;
        if (!kernels.ready()) return false;
        if (layers > plan_module.TALKER_LAYERS) return false;
        self.layers = layers;
        self.context = context;
        self.hidden = kernels.alloc(HIDDEN);
        self.normalized = kernels.alloc(HIDDEN);
        self.q = kernels.alloc(QUERY);
        self.k = kernels.alloc(KEY_VALUE);
        self.v = kernels.alloc(KEY_VALUE);
        self.attn = kernels.alloc(QUERY);
        self.proj = kernels.alloc(HIDDEN);
        self.gate = kernels.alloc(FEED_FORWARD);
        self.up = kernels.alloc(FEED_FORWARD);
        self.down = kernels.alloc(HIDDEN);
        self.logits = kernels.alloc(plan_module.CODEC_VOCABULARY);
        var ok = self.hidden != 0 and self.normalized != 0 and self.q != 0 and self.k != 0 and
            self.v != 0 and self.attn != 0 and self.proj != 0 and self.gate != 0 and self.up != 0 and
            self.down != 0 and self.logits != 0;
        for (0..layers) |i| {
            self.keys[i] = kernels.alloc(context * KEY_VALUE);
            self.values[i] = kernels.alloc(context * KEY_VALUE);
            ok = ok and self.keys[i] != 0 and self.values[i] != 0;
        }
        if (!ok) {
            self.deinit();
            return false;
        }
        self.ready = true;
        return true;
    }

    pub fn deinit(self: *GpuForward) void {
        kernels.free(self.hidden);
        kernels.free(self.normalized);
        kernels.free(self.q);
        kernels.free(self.k);
        kernels.free(self.v);
        kernels.free(self.attn);
        kernels.free(self.proj);
        kernels.free(self.gate);
        kernels.free(self.up);
        kernels.free(self.down);
        kernels.free(self.logits);
        for (0..plan_module.TALKER_LAYERS) |i| {
            kernels.free(self.keys[i]);
            kernels.free(self.values[i]);
        }
        const layers = self.layers;
        const context = self.context;
        self.* = .{};
        _ = layers;
        _ = context;
    }

    pub fn resetKv(self: *GpuForward) void {
        if (!self.ready) return;
        for (0..self.layers) |i| {
            _ = kernels.zeroDevice(self.keys[i], self.context * KEY_VALUE);
            _ = kernels.zeroDevice(self.values[i], self.context * KEY_VALUE);
        }
    }

    /// Preload every layer weight (+ output_norm + optional head) into VRAM.
    pub fn preload(self: *GpuForward, comptime capacity: usize, source: backend.Source, index: *const backend.Index(capacity), decoder: *const plan_module.Decoder, head: ?plan_module.TensorRef) bool {
        if (!self.init(decoder.layer_count, self.context)) return false;
        var ok = true;
        for (decoder.layers[0..decoder.layer_count]) |layer| {
            ok = ok and gfpre(source, index, layer.attention_norm);
            ok = ok and gfpre(source, index, layer.query);
            ok = ok and gfpre(source, index, layer.key);
            ok = ok and gfpre(source, index, layer.value);
            ok = ok and gfpre(source, index, layer.attention_output);
            ok = ok and gfpre(source, index, layer.query_norm);
            ok = ok and gfpre(source, index, layer.key_norm);
            ok = ok and gfpre(source, index, layer.ffn_norm);
            ok = ok and gfpre(source, index, layer.ffn_gate);
            ok = ok and gfpre(source, index, layer.ffn_up);
            ok = ok and gfpre(source, index, layer.ffn_down);
        }
        ok = ok and gfpre(source, index, decoder.output_norm);
        if (head) |h| ok = ok and gfpre(source, index, h);
        return ok;
    }

    /// Preload an additional logits head (the predictor has one per code group).
    pub fn preloadHead(self: *GpuForward, source: backend.Source, index: anytype, head: plan_module.TensorRef) bool {
        _ = self;
        return gfpre(source, index, head);
    }

    /// Run one token through all layers. `input_embedding` (HIDDEN) is uploaded;
    /// `position` is the current absolute step. Writes `normalized_out` (HIDDEN,
    /// the output_norm result — used as past_hidden). If `head` is given, also
    /// writes `logits_out` (head.rows wide) for the sampler. Mirrors step().
    pub fn forward(
        self: *GpuForward,
        comptime capacity: usize,
        source: backend.Source,
        index: *const backend.Index(capacity),
        decoder: *const plan_module.Decoder,
        input_embedding: *const [HIDDEN]f32,
        position: usize,
        head: ?plan_module.TensorRef,
        normalized_out: *[HIDDEN]f32,
        logits_out: ?[]f32,
    ) Error!void {
        _ = source;
        if (!self.ready) return error.InvalidPlan;
        if (!kernels.upload(self.hidden, input_embedding[0..HIDDEN])) return error.NonFinite;

        for (decoder.layers[0..decoder.layer_count], 0..) |layer, li| {
            // attention rmsNorm
            try gfrms(index, layer.attention_norm, self.hidden, self.normalized);
            // Q/K/V
            try gfgemm(index, layer.query, self.normalized, self.q, QUERY, HIDDEN);
            try gfgemm(index, layer.key, self.normalized, self.k, KEY_VALUE, HIDDEN);
            try gfgemm(index, layer.value, self.normalized, self.v, KEY_VALUE, HIDDEN);
            // per-head q/k RMSNorm (shared HEAD_SIZE weight)
            if (!kernels.headRmsNorm(self.q, gfwp(index, layer.query_norm), HEAD_COUNT, HEAD_SIZE, plan_module.RMS_EPSILON)) return error.NonFinite;
            if (!kernels.headRmsNorm(self.k, gfwp(index, layer.key_norm), KV_HEAD_COUNT, HEAD_SIZE, plan_module.RMS_EPSILON)) return error.NonFinite;
            // RoPE (equal MRoPE positions -> split-half)
            if (!kernels.rope(self.q, HEAD_COUNT, HEAD_SIZE, position, plan_module.ROPE_THETA)) return error.NonFinite;
            if (!kernels.rope(self.k, KV_HEAD_COUNT, HEAD_SIZE, position, plan_module.ROPE_THETA)) return error.NonFinite;
            // store into the linear KV cache at `position`, then GQA attention
            if (!kernels.storeKvLinear(self.keys[li], self.k, position, KEY_VALUE)) return error.NonFinite;
            if (!kernels.storeKvLinear(self.values[li], self.v, position, KEY_VALUE)) return error.NonFinite;
            if (!kernels.gqaAttention(self.q, self.keys[li], self.values[li], self.attn, position, HEAD_COUNT, KV_HEAD_COUNT, HEAD_SIZE)) return error.NonFinite;
            // o_proj + residual (plain add)
            try gfgemm(index, layer.attention_output, self.attn, self.proj, HIDDEN, QUERY);
            if (!kernels.residualAdd(self.hidden, self.proj, HIDDEN)) return error.NonFinite;
            // ffn
            try gfrms(index, layer.ffn_norm, self.hidden, self.normalized);
            try gfgemm(index, layer.ffn_gate, self.normalized, self.gate, FEED_FORWARD, HIDDEN);
            try gfgemm(index, layer.ffn_up, self.normalized, self.up, FEED_FORWARD, HIDDEN);
            if (!kernels.siluGate(self.gate, self.up, FEED_FORWARD)) return error.NonFinite;
            try gfgemm(index, layer.ffn_down, self.gate, self.down, HIDDEN, FEED_FORWARD);
            if (!kernels.residualAdd(self.hidden, self.down, HIDDEN)) return error.NonFinite;
        }
        // output norm -> normalized
        try gfrms(index, decoder.output_norm, self.hidden, self.normalized);
        if (!kernels.sync()) return error.NonFinite;
        if (!kernels.download(normalized_out[0..HIDDEN], self.normalized)) return error.NonFinite;

        if (head) |h| {
            const out = logits_out orelse return error.InvalidPlan;
            const info = tensor(index, h);
            const rows = backend.matrixRows(info) orelse return error.InvalidPlan;
            const cols = backend.matrixColumns(info) orelse return error.InvalidPlan;
            if (cols != HIDDEN or rows > out.len) return error.InvalidPlan;
            try gfgemm(index, h, self.normalized, self.logits, rows, HIDDEN);
            if (!kernels.sync()) return error.NonFinite;
            if (!kernels.download(out[0..rows], self.logits)) return error.NonFinite;
        }
        for (normalized_out.*) |value| if (!std.math.isFinite(value)) return error.NonFinite;
    }
};

pub fn gpuAvailable() bool {
    return kernels.ready();
}

fn gfpre(source: backend.Source, index: anytype, ref: plan_module.TensorRef) bool {
    if (!ref.present() or ref.index >= index.tensor_count) return false;
    return kernels.preloadWeight(source, &index.tensors[ref.index]);
}

fn gfwp(index: anytype, ref: plan_module.TensorRef) kernels.CUdeviceptr {
    return kernels.weightPtr(index.tensors[ref.index].data_offset);
}

fn gfrms(index: anytype, ref: plan_module.TensorRef, in: kernels.CUdeviceptr, out: kernels.CUdeviceptr) Error!void {
    const w = gfwp(index, ref);
    if (w == 0) return error.InvalidPlan;
    if (!kernels.rmsNorm(in, w, out, HIDDEN, plan_module.RMS_EPSILON)) return error.NonFinite;
}

fn gfgemm(index: anytype, ref: plan_module.TensorRef, in: kernels.CUdeviceptr, out: kernels.CUdeviceptr, rows: usize, cols: usize) Error!void {
    const w = gfwp(index, ref);
    if (w == 0) return error.InvalidPlan;
    if (!kernels.gemmDevice(w, in, out, rows, cols)) return error.NonFinite;
}
