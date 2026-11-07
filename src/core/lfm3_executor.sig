//! Native allocation-free LFM3 decoder for CPUs.
//!
//! One call runs a batch of consecutive tokens through every layer: prefill
//! reads each weight row once per batch instead of once per token. All mutable
//! state (activations, the rolling short-convolution state, the f16 KV cache)
//! is caller-owned; the executor never allocates and never creates threads.
//! Hosts with workers pass a `Parallel` dispatcher that splits independent row,
//! channel and head ranges; without one every range runs inline.
//!
//! Numerics follow llama.cpp's CPU backend with flash attention off, so greedy
//! output can be compared token for token: matrix inputs are quantized once to
//! Q8_K and multiplied with integer Q4_K/Q6_K kernels (on caller-owned
//! eight-row packed copies when the host provides them), the KV cache is f16,
//! queries and attention weights are rounded to f16 before their products, and
//! RoPE angles advance by repeated multiplication as in ggml's rope cache.

const math = @import("sig_math");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const quantized = @import("quantized_linear");
const transformer = @import("transformer_ops");

const NEGATIVE_INFINITY: f32 = @bitCast(@as(u32, 0xff800000));

pub const Error = quantized.Error || transformer.Error || error{
    InvalidPlan,
    InvalidToken,
    ContextCapacity,
    KvCapacity,
    ConvCapacity,
    BatchCapacity,
    StorageNotMapped,
    ArithmeticOverflow,
    PackedCapacity,
};

/// Comptime capacity of one workspace. `batch` bounds the tokens of one call;
/// `context` bounds positions and sizes each attention worker's score row.
pub const Limits = struct {
    hidden: usize,
    feed_forward: usize,
    query: usize,
    key_value: usize,
    heads: usize,
    vocabulary: usize,
    batch: usize,
    context: usize,
};

pub const lfm3_audio_2b_limits = Limits{
    .hidden = 2048,
    .feed_forward = 7680,
    .query = 2048,
    .key_value = 512,
    .heads = 16,
    .vocabulary = 128_000,
    .batch = 64,
    .context = 4096,
};

/// One range of independent work. `execute` may run concurrently on disjoint
/// ranges of [0, count) and must not fail: inputs are validated before dispatch.
pub const Task = struct {
    context: *const anyopaque,
    count: usize,
    execute: *const fn (context: *const anyopaque, first: usize, end: usize) void,
};

/// Host data parallelism. `dispatch` must run every index of the task exactly
/// once and return only after all ranges completed.
pub const Parallel = struct {
    context: ?*anyopaque = null,
    dispatch: ?*const fn (context: *anyopaque, task: *const Task) void = null,

    pub fn run(self: Parallel, task: *const Task) void {
        if (task.count == 0) return;
        if (self.dispatch) |dispatch| {
            if (self.context) |context| return dispatch(context, task);
        }
        task.execute(task.context, 0, task.count);
    }
};

/// Caller-owned recurrent state: the f16 KV cache of every attention layer and
/// the last `conv_kernel - 1` B*X rows of every short-convolution layer.
pub const Cache = struct {
    kv: []u16,
    conv: []f32,
    context: usize,
    position: usize = 0,

    /// Start a new sequence. KV rows past `position` are never read, so only
    /// the convolution history needs clearing.
    pub fn reset(self: *Cache) void {
        @memset(self.conv, 0);
        self.position = 0;
    }
};

/// Caller-owned eight-row interleaved copies of the matrices (see
/// quantized.packQ4KX8 and packQ6KX8), filled once by `packWeights`. `offsets[tensor]`
/// locates a tensor's copy in `bytes`; matrices without one, and every matrix
/// of an empty value, run on the canonical row kernels.
pub fn PackedWeights(comptime tensor_capacity: usize) type {
    return struct {
        bytes: []const u8 = &.{},
        offsets: [tensor_capacity]usize = @splat(NOT_PACKED),
    };
}

pub const NOT_PACKED = ~@as(usize, 0);

/// Bytes of storage `packWeights` fills: packed copies keep canonical sizes.
pub fn requiredPackedBytes(comptime tensor_capacity: usize, index: *const gguf.Index(tensor_capacity), plan: *const lfm3.Plan) Error!usize {
    var total: usize = 0;
    var matrices = Matrices.init(plan);
    while (matrices.next()) |reference| {
        if (packable(index, reference)) total = try add(total, @intCast(index.tensors[reference.index].byte_size));
    }
    return total;
}

/// Pack every matrix the forward pass multiplies whose rows split into
/// PACKED_ROWS-row groups into `storage` and record them in `out`. Prefill
/// then reads each activation once per eight rows instead of once per row.
pub fn packWeights(
    comptime tensor_capacity: usize,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const lfm3.Plan,
    storage: []u8,
    out: *PackedWeights(tensor_capacity),
    parallel: Parallel,
) Error!void {
    out.* = .{};
    if (storage.len < try requiredPackedBytes(tensor_capacity, index, plan)) return error.PackedCapacity;
    var used: usize = 0;
    var matrices = Matrices.init(plan);
    while (matrices.next()) |reference| {
        if (!packable(index, reference)) continue;
        const view = try matrixView(source, index, reference);
        const task = PackTask{
            .source = view.bytes,
            .output = storage[used..][0..view.bytes.len],
            .blocks = view.columns / quantized.QK_K,
            .q4 = view.ggml_type == 12,
        };
        forRange(parallel, view.rows / quantized.PACKED_ROWS, &task);
        out.offsets[reference.index] = used;
        used += view.bytes.len;
    }
    out.bytes = storage[0..used];
}

/// Every matrix `forward` multiplies, each once.
const Matrices = struct {
    plan: *const lfm3.Plan,
    layer: usize = 0,
    slot: usize = 0,

    fn init(plan: *const lfm3.Plan) Matrices {
        return .{ .plan = plan };
    }

    fn next(self: *Matrices) ?lfm3.TensorRef {
        while (self.layer < self.plan.layer_count) {
            const layer = &self.plan.layers[self.layer];
            const references = [_]lfm3.TensorRef{
                layer.in_proj,   layer.out_proj,    layer.attn_q,   layer.attn_k, layer.attn_v,
                layer.attn_gate, layer.attn_output, layer.ffn_gate, layer.ffn_up, layer.ffn_down,
            };
            while (self.slot < references.len) {
                const reference = references[self.slot];
                self.slot += 1;
                if (reference.present()) return reference;
            }
            self.layer += 1;
            self.slot = 0;
        }
        if (self.layer == self.plan.layer_count) {
            self.layer += 1;
            if (self.plan.output.present()) return self.plan.output;
        }
        return null;
    }
};

fn packable(index: anytype, reference: lfm3.TensorRef) bool {
    const tensor = &index.tensors[reference.index];
    return tensor.dimension_count == 2 and (tensor.ggml_type == 12 or tensor.ggml_type == 14) and
        tensor.dimensions[1] % quantized.PACKED_ROWS == 0 and tensor.dimensions[0] % quantized.QK_K == 0;
}

const PackTask = struct {
    source: []const u8,
    output: []u8,
    blocks: usize,
    q4: bool,

    fn run(self: *const PackTask, first: usize, end: usize) void {
        const block_bytes: usize = if (self.q4) quantized.Q4_K_BLOCK_BYTES else quantized.Q6_K_BLOCK_BYTES;
        const group_bytes = quantized.PACKED_ROWS * self.blocks * block_bytes;
        for (first..end) |group| {
            const output = self.output[group * group_bytes ..][0..group_bytes];
            const rows = self.source[group * group_bytes ..][0..group_bytes];
            const packed_group = if (self.q4) quantized.packQ4KX8(output, rows, self.blocks) else quantized.packQ6KX8(output, rows, self.blocks);
            packed_group catch unreachable;
        }
    }
};

pub fn requiredKvElements(plan: *const lfm3.Plan, context: usize) Error!usize {
    if (context == 0 or plan.max_kv_head_count == 0 or plan.head_size == 0) return error.InvalidPlan;
    var elements = try multiply(plan.attention_layer_count, 2);
    elements = try multiply(elements, plan.max_kv_head_count);
    elements = try multiply(elements, context);
    return multiply(elements, plan.head_size);
}

pub fn requiredConvElements(plan: *const lfm3.Plan) Error!usize {
    if (plan.conv_kernel < 2) return error.InvalidPlan;
    const rows = try multiply(plan.conv_layer_count, plan.conv_kernel - 1);
    return multiply(rows, plan.hidden_size);
}

pub fn Workspace(comptime limits: Limits) type {
    validateLimits(limits);
    const widest_input = @max(@max(limits.hidden, limits.query), limits.feed_forward);
    return struct {
        hidden: [limits.batch * limits.hidden]f32 = @splat(0),
        normalized: [limits.batch * limits.hidden]f32 = @splat(0),
        mixed: [limits.batch * 3 * limits.hidden]f32 = @splat(0),
        query: [limits.batch * limits.query]f32 = @splat(0),
        key: [limits.batch * limits.key_value]f32 = @splat(0),
        value: [limits.batch * limits.key_value]f32 = @splat(0),
        gate: [limits.batch * limits.heads]f32 = @splat(0),
        mixer: [limits.batch * @max(limits.query, limits.hidden)]f32 = @splat(0),
        projected: [limits.batch * limits.hidden]f32 = @splat(0),
        ffn_gate: [limits.batch * limits.feed_forward]f32 = @splat(0),
        ffn_up: [limits.batch * limits.feed_forward]f32 = @splat(0),
        activations: [limits.batch * (widest_input / quantized.QK_K)]quantized.Q8KBlock = @splat(.{}),
        logits: [limits.vocabulary]f32 = @splat(0),

        pub fn staticBytes() usize {
            return @sizeOf(@This());
        }
    };
}

/// Run `tokens` at the cache's next positions and advance it. When
/// `produce_logits` is set, `work.logits` holds the scores after the last token
/// and the greedy choice is returned.
pub fn forward(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const lfm3.Plan,
    weights: *const PackedWeights(tensor_capacity),
    work: *Workspace(limits),
    cache: *Cache,
    tokens: []const u32,
    produce_logits: bool,
    parallel: Parallel,
) Error!?u32 {
    return forwardInput(tensor_capacity, limits, source, index, plan, weights, work, cache, .{ .tokens = tokens }, if (produce_logits) .logits else .none, parallel);
}

/// A batch of consecutive positions: token ids, or rows of `hidden_size`
/// input embeddings (audio from the hearing encoder, feedback of spoken
/// frames) that take the place of token embeddings.
pub const Input = union(enum) {
    tokens: []const u32,
    embeddings: []const f32,

    fn count(self: Input, hidden: usize) usize {
        return switch (self) {
            .tokens => |tokens| tokens.len,
            .embeddings => |rows| rows.len / hidden,
        };
    }
};

/// What the last position leaves behind: nothing; the output-normed hidden
/// state in `work.normalized[0..hidden_size]` (llama.cpp's embeddings, what the
/// speech generator reads); or that and the logits with the greedy token.
pub const Output = enum { none, hidden, logits };

pub fn forwardInput(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const lfm3.Plan,
    weights: *const PackedWeights(tensor_capacity),
    work: *Workspace(limits),
    cache: *Cache,
    input: Input,
    output: Output,
    parallel: Parallel,
) Error!?u32 {
    const hidden: usize = plan.hidden_size;
    if (hidden == 0) return error.InvalidPlan;
    const count = input.count(hidden);
    try validateRuntime(limits, index, plan, cache, count);
    const feed_forward: usize = plan.feed_forward_size;
    switch (input) {
        .tokens => |tokens| {
            for (tokens) |token| if (token >= plan.vocabulary_size) return error.InvalidToken;
            const embedding = try matrixView(source, index, plan.token_embedding);
            for (tokens, 0..) |token, slot| {
                const row = embedding.bytes[@as(usize, token) * embedding.row_bytes ..][0..embedding.row_bytes];
                const destination = work.hidden[slot * hidden ..][0..hidden];
                switch (embedding.ggml_type) {
                    12 => try quantized.dequantizeQ4K(destination, row),
                    else => try quantized.dequantizeQ6K(destination, row),
                }
            }
        },
        .embeddings => |rows| {
            if (rows.len % hidden != 0) return error.InvalidToken;
            if (!allFinite(rows)) return error.NonFinite;
            @memcpy(work.hidden[0..rows.len], rows);
        },
    }

    for (plan.layers[0..plan.layer_count]) |*layer| {
        const operator_norm = NormQuantizeTask{
            .input = work.hidden[0 .. count * hidden],
            .weight = try vectorView(source, index, layer.attn_norm, hidden),
            .epsilon = plan.rms_norm_epsilon,
            .output = work.normalized[0 .. count * hidden],
            .activations = &work.activations,
        };
        forRange(parallel, count, &operator_norm);
        switch (layer.kind) {
            .short_conv => {
                try linear(source, index, weights, layer.in_proj, &work.activations, count, work.mixed[0 .. count * 3 * hidden], parallel);
                const state = cache.conv[@as(usize, layer.slot) * (plan.conv_kernel - 1) * hidden ..][0 .. (plan.conv_kernel - 1) * hidden];
                const conv = ConvTask{
                    .kernel = plan.conv_kernel,
                    .hidden = hidden,
                    .taps = try matrixF32View(source, index, layer.conv, @as(usize, plan.conv_kernel) * hidden),
                    .state = state,
                    .mixed = work.mixed[0 .. count * 3 * hidden],
                    .tokens = count,
                    .output = work.mixer[0 .. count * hidden],
                };
                forRange(parallel, hidden, &conv);
                quantizeBlocks(parallel, work.mixer[0 .. count * hidden], &work.activations);
                try linear(source, index, weights, layer.out_proj, &work.activations, count, work.projected[0 .. count * hidden], parallel);
            },
            .attention => try attentionBlock(tensor_capacity, limits, source, index, plan, weights, layer, work, cache, count, parallel),
        }
        try addResidual(source, index, plan, layer.post_attention_norm, work.hidden[0 .. count * hidden], work.projected[0 .. count * hidden], parallel);

        const ffn_norm = NormQuantizeTask{
            .input = work.hidden[0 .. count * hidden],
            .weight = try vectorView(source, index, layer.ffn_norm, hidden),
            .epsilon = plan.rms_norm_epsilon,
            .output = work.normalized[0 .. count * hidden],
            .activations = &work.activations,
        };
        forRange(parallel, count, &ffn_norm);
        try linear(source, index, weights, layer.ffn_gate, &work.activations, count, work.ffn_gate[0 .. count * feed_forward], parallel);
        try linear(source, index, weights, layer.ffn_up, &work.activations, count, work.ffn_up[0 .. count * feed_forward], parallel);
        const swiglu = SwiGluQuantizeTask{
            .gate = work.ffn_gate[0 .. count * feed_forward],
            .up = work.ffn_up[0 .. count * feed_forward],
            .activations = &work.activations,
        };
        forRange(parallel, count * feed_forward / quantized.QK_K, &swiglu);
        try linear(source, index, weights, layer.ffn_down, &work.activations, count, work.projected[0 .. count * hidden], parallel);
        try addResidual(source, index, plan, layer.post_ffw_norm, work.hidden[0 .. count * hidden], work.projected[0 .. count * hidden], parallel);
    }
    cache.position += count;
    if (output == .none) return null;

    const output_norm = NormQuantizeTask{
        .input = work.hidden[(count - 1) * hidden ..][0..hidden],
        .weight = try vectorView(source, index, plan.output_norm, hidden),
        .epsilon = plan.rms_norm_epsilon,
        .output = work.normalized[0..hidden],
        .activations = &work.activations,
    };
    output_norm.run(0, 1);
    if (output == .hidden) return null;
    try linear(source, index, weights, plan.output, &work.activations, 1, work.logits[0..plan.vocabulary_size], parallel);
    return @intCast(try transformer.argmax(work.logits[0..plan.vocabulary_size]));
}

/// Feed a prompt of any length in batch-sized slices; returns the greedy token
/// after its last position.
pub fn prefill(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const lfm3.Plan,
    weights: *const PackedWeights(tensor_capacity),
    work: *Workspace(limits),
    cache: *Cache,
    tokens: []const u32,
    parallel: Parallel,
) Error!u32 {
    if (tokens.len == 0) return error.InvalidToken;
    var start: usize = 0;
    while (true) {
        const end = @min(tokens.len, start + limits.batch);
        const selected = try forward(tensor_capacity, limits, source, index, plan, weights, work, cache, tokens[start..end], end == tokens.len, parallel);
        if (end == tokens.len) return selected.?;
        start = end;
    }
}

fn attentionBlock(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const lfm3.Plan,
    weights: *const PackedWeights(tensor_capacity),
    layer: *const lfm3.Layer,
    work: *Workspace(limits),
    cache: *Cache,
    count: usize,
    parallel: Parallel,
) Error!void {
    const hidden: usize = plan.hidden_size;
    const head_size: usize = plan.head_size;
    const heads: usize = plan.head_count;
    const kv_heads: usize = layer.kv_head_count;
    const query_width = heads * head_size;
    const key_value_width = kv_heads * head_size;
    try linear(source, index, weights, layer.attn_q, &work.activations, count, work.query[0 .. count * query_width], parallel);
    try linear(source, index, weights, layer.attn_k, &work.activations, count, work.key[0 .. count * key_value_width], parallel);
    try linear(source, index, weights, layer.attn_v, &work.activations, count, work.value[0 .. count * key_value_width], parallel);
    try linear(source, index, weights, layer.attn_gate, &work.activations, count, work.gate[0 .. count * heads], parallel);
    // Every slot this batch writes is checked once, before workers index it.
    _ = try kvOffset(plan, cache.context, layer.slot, true, kv_heads - 1, cache.position + count - 1);

    const prepare = PrepareTask{
        .query = work.query[0 .. count * query_width],
        .key = work.key[0 .. count * key_value_width],
        .value = work.value[0 .. count * key_value_width],
        .query_norm = try vectorView(source, index, layer.attn_q_norm, head_size),
        .key_norm = try vectorView(source, index, layer.attn_k_norm, head_size),
        .factors = if (layer.sliding_window) null else try vectorView(source, index, plan.rope_factors, head_size / 2),
        .base = if (layer.sliding_window) plan.rope_frequency_base_swa else plan.rope_frequency_base,
        .epsilon = plan.rms_norm_epsilon,
        .heads = heads,
        .kv_heads = kv_heads,
        .head_size = head_size,
        .first_position = cache.position,
        .kv = cache.kv,
        .context = cache.context,
        .slot = layer.slot,
        .max_kv_heads = plan.max_kv_head_count,
    };
    forRange(parallel, count, &prepare);

    const attention = AttentionTask(limits.context){
        .kv = cache.kv,
        .context = cache.context,
        .slot = layer.slot,
        .max_kv_heads = plan.max_kv_head_count,
        .heads = heads,
        .kv_heads = kv_heads,
        .head_size = head_size,
        .first_position = cache.position,
        .sliding_window = layer.sliding_window,
        .window = plan.sliding_window,
        .query = work.query[0 .. count * query_width],
        .gate = work.gate[0 .. count * heads],
        .output = work.mixer[0 .. count * query_width],
    };
    forRange(parallel, count * heads, &attention);
    quantizeBlocks(parallel, work.mixer[0 .. count * query_width], &work.activations);
    try linear(source, index, weights, layer.attn_output, &work.activations, count, work.projected[0 .. count * hidden], parallel);
}

/// Run `context.run(first, end)` over [0, count) through the host dispatcher.
fn forRange(parallel: Parallel, count: usize, context: anytype) void {
    const Context = @typeInfo(@TypeOf(context)).pointer.child;
    const Adapter = struct {
        fn execute(raw: *const anyopaque, first: usize, end: usize) void {
            const self: *const Context = @ptrCast(@alignCast(raw));
            self.run(first, end);
        }
    };
    parallel.run(&.{ .context = context, .count = count, .execute = &Adapter.execute });
}

/// RMSNorm without validation for worker tasks: callers validated shapes, and
/// non-finite values propagate to the next checked residual instead of
/// leaving a stale row behind. Same arithmetic as transformer.rmsNorm.
fn rmsNormRow(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
    var squares: f64 = 0;
    for (input) |value| squares += @as(f64, value) * value;
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
}

/// Per token: RMSNorm a hidden row, then quantize it as the next matrix input.
const NormQuantizeTask = struct {
    input: []const f32,
    weight: []const f32,
    epsilon: f32,
    output: []f32,
    activations: []quantized.Q8KBlock,

    fn run(self: *const NormQuantizeTask, first: usize, end: usize) void {
        const width = self.weight.len;
        const blocks = width / quantized.QK_K;
        for (first..end) |slot| {
            const row = self.output[slot * width ..][0..width];
            rmsNormRow(self.input[slot * width ..][0..width], self.weight, row, self.epsilon);
            quantized.quantizeQ8K(row, self.activations[slot * blocks ..][0..blocks]) catch unreachable;
        }
    }
};

/// Per 256-lane block: silu(gate) * up, then quantize it for ffn_down.
const SwiGluQuantizeTask = struct {
    gate: []f32,
    up: []const f32,
    activations: []quantized.Q8KBlock,

    fn run(self: *const SwiGluQuantizeTask, first: usize, end: usize) void {
        for (first..end) |block| {
            const gate = self.gate[block * quantized.QK_K ..][0..quantized.QK_K];
            const up = self.up[block * quantized.QK_K ..][0..quantized.QK_K];
            for (gate, up) |*value, scale| value.* = (value.* / (1.0 + @exp(-value.*))) * scale;
            quantized.quantizeQ8K(gate, self.activations[block..][0..1]) catch unreachable;
        }
    }
};

fn quantizeBlocks(parallel: Parallel, input: []const f32, activations: []quantized.Q8KBlock) void {
    const task = QuantizeTask{ .input = input, .activations = activations };
    forRange(parallel, input.len / quantized.QK_K, &task);
}

const QuantizeTask = struct {
    input: []const f32,
    activations: []quantized.Q8KBlock,

    fn run(self: *const QuantizeTask, first: usize, end: usize) void {
        quantized.quantizeQ8K(self.input[first * quantized.QK_K .. end * quantized.QK_K], self.activations[first..end]) catch unreachable;
    }
};

/// hidden += post_norm(block) per token (the norm only with sandwich norms),
/// then one finiteness check of the updated residual stream.
fn addResidual(source: gguf.Source, index: anytype, plan: *const lfm3.Plan, norm: lfm3.TensorRef, hidden: []f32, block: []f32, parallel: Parallel) Error!void {
    const task = ResidualTask{
        .hidden = hidden,
        .block = block,
        .weight = if (plan.sandwich_norms) try vectorView(source, index, norm, plan.hidden_size) else null,
        .width = plan.hidden_size,
        .epsilon = plan.rms_norm_epsilon,
    };
    forRange(parallel, hidden.len / plan.hidden_size, &task);
    if (!allFinite(hidden)) return error.NonFinite;
}

const ResidualTask = struct {
    hidden: []f32,
    block: []f32,
    weight: ?[]const f32,
    width: usize,
    epsilon: f32,

    fn run(self: *const ResidualTask, first: usize, end: usize) void {
        for (first..end) |slot| {
            const row = self.block[slot * self.width ..][0..self.width];
            if (self.weight) |weight| rmsNormRow(row, weight, row, self.epsilon);
            for (self.hidden[slot * self.width ..][0..self.width], row) |*value, delta| value.* += delta;
        }
    }
};

/// Per token: Q/K head RMSNorm, RoPE, the f16 query copy ggml multiplies keys
/// with, and the f16 K/V cache rows at the token's position.
const PrepareTask = struct {
    query: []f32,
    key: []f32,
    value: []const f32,
    query_norm: []const f32,
    key_norm: []const f32,
    factors: ?[]const f32,
    base: f32,
    epsilon: f32,
    heads: usize,
    kv_heads: usize,
    head_size: usize,
    first_position: usize,
    kv: []u16,
    context: usize,
    slot: u8,
    max_kv_heads: usize,

    fn run(self: *const PrepareTask, first: usize, end: usize) void {
        const query_width = self.heads * self.head_size;
        const key_value_width = self.kv_heads * self.head_size;
        for (first..end) |slot| {
            const position = self.first_position + slot;
            const query = self.query[slot * query_width ..][0..query_width];
            const key = self.key[slot * key_value_width ..][0..key_value_width];
            const value = self.value[slot * key_value_width ..][0..key_value_width];
            for (0..self.heads) |head| {
                const row = query[head * self.head_size ..][0..self.head_size];
                rmsNormRow(row, self.query_norm, row, self.epsilon);
            }
            for (0..self.kv_heads) |head| {
                const row = key[head * self.head_size ..][0..self.head_size];
                rmsNormRow(row, self.key_norm, row, self.epsilon);
            }
            ropeNeox(query, self.heads, self.head_size, position, self.base, self.factors);
            ropeNeox(key, self.kv_heads, self.head_size, position, self.base, self.factors);
            for (query) |*element| element.* = transformer.f16BitsToF32(transformer.f32ToF16Bits(element.*));
            for (0..self.kv_heads) |head| {
                const keys = self.kv[self.cacheRow(false, head, position)..][0..self.head_size];
                const values = self.kv[self.cacheRow(true, head, position)..][0..self.head_size];
                for (keys, values, key[head * self.head_size ..][0..self.head_size], value[head * self.head_size ..][0..self.head_size]) |*k, *v, key_value, value_value| {
                    k.* = transformer.f32ToF16Bits(key_value);
                    v.* = transformer.f32ToF16Bits(value_value);
                }
            }
        }
    }

    fn cacheRow(self: *const PrepareTask, values: bool, head: usize, position: usize) usize {
        return ((((@as(usize, self.slot) * 2 + @intFromBool(values)) * self.max_kv_heads + head) * self.context) + position) * self.head_size;
    }
};

// NeoX rotary embedding over `heads` contiguous heads, mirroring ggml's rope
/// cache: theta starts at the position and is multiplied by base^(-2/d) per
/// lane pair; optional frequency factors divide each pair's angle. Every head
/// shares one cosine and sine per lane pair.
pub fn ropeNeox(values: []f32, heads: usize, head_size: usize, position: usize, base: f32, factors: ?[]const f32) void {
    const half = head_size / 2;
    const exponent = -2.0 / @as(f64, @floatFromInt(head_size));
    const theta_scale: f32 = @floatCast(@exp(exponent * @log(@as(f64, base))));
    var theta: f32 = @floatFromInt(position);
    for (0..half) |lane| {
        const angle = if (factors) |divisors| theta / divisors[lane] else theta;
        const cosine = @cos(angle);
        const sine = @sin(angle);
        for (0..heads) |head| {
            const row = values[head * head_size ..][0..head_size];
            const low = row[lane];
            const high = row[lane + half];
            row[lane] = low * cosine - high * sine;
            row[lane + half] = low * sine + high * cosine;
        }
        theta *= theta_scale;
    }
}

/// Depthwise causal convolution of the gated short-conv block for channels
/// [first, end). `mixed` holds `tokens` rows of [B | C | X]; each channel
/// convolves B*X over `state` (oldest row first) followed by the new tokens,
/// scales the result by C, and leaves its last `kernel - 1` inputs in `state`.
/// Summation runs oldest tap first, as ggml_ssm_conv does.
pub fn shortConvChannels(
    kernel: usize,
    hidden: usize,
    taps: []const f32,
    state: []f32,
    mixed: []const f32,
    tokens: usize,
    output: []f32,
    first: usize,
    end: usize,
) void {
    var window: [lfm3.MAX_CONV_KERNEL]f32 = undefined;
    const history = kernel - 1;
    for (first..end) |channel| {
        for (0..history) |row| window[row] = state[row * hidden + channel];
        const weights = taps[channel * kernel ..][0..kernel];
        for (0..tokens) |slot| {
            const row = mixed[slot * 3 * hidden ..][0 .. 3 * hidden];
            window[history] = row[channel] * row[2 * hidden + channel];
            var sum: f32 = 0;
            for (window[0..kernel], weights) |input, weight| sum += input * weight;
            output[slot * hidden + channel] = row[hidden + channel] * sum;
            for (0..history) |shift| window[shift] = window[shift + 1];
        }
        for (0..history) |row| state[row * hidden + channel] = window[row];
    }
}

const ConvTask = struct {
    kernel: usize,
    hidden: usize,
    taps: []const f32,
    state: []f32,
    mixed: []const f32,
    tokens: usize,
    output: []f32,

    fn run(self: *const ConvTask, first: usize, end: usize) void {
        shortConvChannels(self.kernel, self.hidden, self.taps, self.state, self.mixed, self.tokens, self.output, first, end);
    }
};

fn AttentionTask(comptime context_capacity: usize) type {
    return struct {
        const Self = @This();
        kv: []const u16,
        context: usize,
        slot: u8,
        max_kv_heads: usize,
        heads: usize,
        kv_heads: usize,
        head_size: usize,
        first_position: usize,
        sliding_window: bool,
        window: u32,
        query: []const f32,
        gate: []const f32,
        output: []f32,

        /// One unit is one (token, query head): scores over the visible keys,
        /// softmax, f16 weights times f16 values, then the head's sigmoid gate.
        fn run(self: *const Self, first: usize, end: usize) void {
            var scores: [context_capacity]f32 = undefined;
            const width = self.heads * self.head_size;
            const group = self.heads / self.kv_heads;
            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(self.head_size)));
            for (first..end) |unit| {
                const slot = unit / self.heads;
                const head = unit % self.heads;
                const kv_head = head / group;
                const position = self.first_position + slot;
                const visible = lfm3.firstVisiblePosition(self.sliding_window, self.window, position);
                const query = self.query[slot * width + head * self.head_size ..][0..self.head_size];
                const keys = self.kv[self.block(false, kv_head)..];
                var maximum: f32 = NEGATIVE_INFINITY;
                for (visible..position + 1) |key_position| {
                    const key = keys[key_position * self.head_size ..][0..self.head_size];
                    const score = dotHalf(query, key) * scale;
                    scores[key_position - visible] = score;
                    maximum = @max(maximum, score);
                }
                const length = position + 1 - visible;
                var total: f64 = 0;
                for (scores[0..length]) |*score| {
                    score.* = @exp(score.* - maximum);
                    total += score.*;
                }
                const inverse: f32 = @floatCast(1.0 / total);
                const values = self.kv[self.block(true, kv_head)..];
                const destination = self.output[slot * width + head * self.head_size ..][0..self.head_size];
                @memset(destination, 0);
                for (scores[0..length], visible..) |score, key_position| {
                    const weight = transformer.f16BitsToF32(transformer.f32ToF16Bits(score * inverse));
                    const value = values[key_position * self.head_size ..][0..self.head_size];
                    for (destination, value) |*accumulator, element| accumulator.* += weight * transformer.f16BitsToF32(element);
                }
                const logit = self.gate[slot * self.heads + head];
                const gate = 1.0 / (1.0 + @exp(-logit));
                for (destination) |*element| element.* *= gate;
            }
        }

        fn block(self: *const Self, values: bool, kv_head: usize) usize {
            return (((@as(usize, self.slot) * 2 + @intFromBool(values)) * self.max_kv_heads + kv_head) * self.context) * self.head_size;
        }
    };
}

fn dotHalf(query: []const f32, key: []const u16) f32 {
    const Vector = @Vector(8, f32);
    var sum: Vector = @splat(0);
    var lane: usize = 0;
    while (lane + 8 <= query.len) : (lane += 8) {
        const halves: @Vector(8, f16) = @bitCast(@as(@Vector(8, u16), key[lane..][0..8].*));
        const widened: Vector = @floatCast(halves);
        const q: Vector = query[lane..][0..8].*;
        sum += q * widened;
    }
    var total = @reduce(.Add, sum);
    while (lane < query.len) : (lane += 1) total += query[lane] * transformer.f16BitsToF32(key[lane]);
    return total;
}

const MatrixView = struct { bytes: []const u8, row_bytes: usize, ggml_type: u32, rows: usize, columns: usize };

fn matrixView(source: gguf.Source, index: anytype, reference: lfm3.TensorRef) Error!MatrixView {
    const tensor = &index.tensors[reference.index];
    if (tensor.dimension_count != 2 or (tensor.ggml_type != 12 and tensor.ggml_type != 14)) return error.InvalidPlan;
    const rows: usize = @intCast(tensor.dimensions[1]);
    const columns: usize = @intCast(tensor.dimensions[0]);
    if (columns % quantized.QK_K != 0) return error.InvalidPlan;
    const block_bytes: usize = if (tensor.ggml_type == 12) quantized.Q4_K_BLOCK_BYTES else quantized.Q6_K_BLOCK_BYTES;
    const row_bytes = (columns / quantized.QK_K) * block_bytes;
    if (try multiply(rows, row_bytes) != tensor.byte_size) return error.InvalidPlan;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), 1) orelse return error.StorageNotMapped;
    return .{ .bytes = bytes, .row_bytes = row_bytes, .ggml_type = tensor.ggml_type, .rows = rows, .columns = columns };
}

fn matrixF32View(source: gguf.Source, index: anytype, reference: lfm3.TensorRef, elements: usize) Error![]const f32 {
    const tensor = &index.tensors[reference.index];
    if (tensor.ggml_type != 0 or tensor.byte_size != try multiply(elements, 4)) return error.InvalidPlan;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), @alignOf(f32)) orelse return error.StorageNotMapped;
    const values: [*]const f32 = @ptrCast(@alignCast(bytes.ptr));
    return values[0..elements];
}

fn vectorView(source: gguf.Source, index: anytype, reference: lfm3.TensorRef, elements: usize) Error![]const f32 {
    return matrixF32View(source, index, reference, elements);
}

/// output[token][row] = W[row] . activations[token] for every weight row.
fn linear(
    source: gguf.Source,
    index: anytype,
    weights: anytype,
    reference: lfm3.TensorRef,
    activations: []const quantized.Q8KBlock,
    tokens: usize,
    output: []f32,
    parallel: Parallel,
) Error!void {
    const view = try matrixView(source, index, reference);
    const blocks = view.columns / quantized.QK_K;
    if (tokens == 0 or output.len != tokens * view.rows or activations.len < tokens * blocks) return error.InvalidPlan;
    const offset = weights.offsets[reference.index];
    const is_packed = offset != NOT_PACKED;
    if (is_packed and (!packable(index, reference) or offset > weights.bytes.len or view.bytes.len > weights.bytes.len - offset))
        return error.InvalidPlan;
    const task = MatmulTask{
        .weights = if (is_packed) weights.bytes[offset..][0..view.bytes.len] else view.bytes,
        .unit_rows = if (is_packed) quantized.PACKED_ROWS else 1,
        .row_bytes = view.row_bytes,
        .q4 = view.ggml_type == 12,
        .activations = activations[0 .. tokens * blocks],
        .blocks = blocks,
        .tokens = tokens,
        .output = output,
        .width = view.rows,
    };
    forRange(parallel, view.rows / task.unit_rows, &task);
    if (!allFinite(output)) return error.NonFinite;
}

/// One unit is one canonical row, or one PACKED_ROWS-row group of a packed
/// matrix.
const MatmulTask = struct {
    weights: []const u8,
    unit_rows: usize,
    row_bytes: usize,
    q4: bool,
    activations: []const quantized.Q8KBlock,
    blocks: usize,
    tokens: usize,
    output: []f32,
    width: usize,

    /// Weight rows are visited in blocks that stay cache-resident while every
    /// token tile sweeps them, and each tile's activations stay in L1 across
    /// the block: prefill streams each weight row and activation row once.
    fn run(self: *const MatmulTask, first: usize, end: usize) void {
        const unit_block = 32 / self.unit_rows;
        const unit_bytes = self.unit_rows * self.row_bytes;
        var block_start = first;
        while (block_start < end) : (block_start += unit_block) {
            const block_end = @min(end, block_start + unit_block);
            var slot: usize = 0;
            while (slot < self.tokens) {
                const count = @min(self.tokens - slot, quantized.MAX_TILE);
                for (block_start..block_end) |unit| {
                    const bytes = self.weights[unit * unit_bytes ..][0..unit_bytes];
                    inline for (1..quantized.MAX_TILE + 1) |width| {
                        if (count == width) {
                            if (self.unit_rows == 1) self.tile(width, bytes, unit, slot) else self.packedTile(width, bytes, unit, slot);
                        }
                    }
                }
                slot += count;
            }
        }
    }

    /// Shapes were validated by `linear`, so every row holds `blocks` blocks.
    inline fn tile(self: *const MatmulTask, comptime count: usize, bytes: []const u8, row: usize, first_slot: usize) void {
        const rows = self.tokenRows(count, first_slot);
        const results = if (self.q4)
            quantized.dotQ4KQ8KTile(count, bytes, rows, self.blocks)
        else
            quantized.dotQ6KQ8KTile(count, bytes, rows, self.blocks);
        inline for (0..count) |offset| self.output[(first_slot + offset) * self.width + row] = results[offset];
    }

    inline fn packedTile(self: *const MatmulTask, comptime count: usize, bytes: []const u8, group: usize, first_slot: usize) void {
        const rows = self.tokenRows(count, first_slot);
        const results = if (self.q4)
            quantized.dotQ4KX8Q8KTile(count, bytes, rows, self.blocks)
        else
            quantized.dotQ6KX8Q8KTile(count, bytes, rows, self.blocks);
        inline for (0..count) |offset| {
            self.output[(first_slot + offset) * self.width + group * quantized.PACKED_ROWS ..][0..quantized.PACKED_ROWS].* = results[offset];
        }
    }

    inline fn tokenRows(self: *const MatmulTask, comptime count: usize, first_slot: usize) [count][*]const quantized.Q8KBlock {
        var rows: [count][*]const quantized.Q8KBlock = undefined;
        inline for (0..count) |offset| rows[offset] = self.activations[(first_slot + offset) * self.blocks ..].ptr;
        return rows;
    }
};

fn validateRuntime(comptime limits: Limits, index: anytype, plan: *const lfm3.Plan, cache: *const Cache, count: usize) Error!void {
    if (plan.layer_count == 0 or plan.layer_count > lfm3.MAX_LAYERS or
        plan.hidden_size == 0 or plan.hidden_size > limits.hidden or plan.hidden_size % quantized.QK_K != 0 or
        plan.queryWidth() == 0 or plan.queryWidth() > limits.query or plan.queryWidth() % quantized.QK_K != 0 or
        @as(usize, plan.max_kv_head_count) * plan.head_size > limits.key_value or
        plan.head_count > limits.heads or
        plan.feed_forward_size == 0 or plan.feed_forward_size > limits.feed_forward or plan.feed_forward_size % quantized.QK_K != 0 or
        plan.vocabulary_size == 0 or plan.vocabulary_size > limits.vocabulary or
        plan.conv_kernel < 2 or plan.conv_kernel > lfm3.MAX_CONV_KERNEL or
        index.tensor_count == 0 or index.tensor_count > index.tensors.len) return error.InvalidPlan;
    if (count == 0 or count > limits.batch) return error.BatchCapacity;
    if (cache.context == 0 or cache.context > limits.context or cache.position > cache.context or
        count > cache.context - cache.position) return error.ContextCapacity;
    if (cache.kv.len < try requiredKvElements(plan, cache.context)) return error.KvCapacity;
    if (cache.conv.len < try requiredConvElements(plan)) return error.ConvCapacity;
}

fn kvOffset(plan: *const lfm3.Plan, context: usize, slot: u8, values: bool, head: usize, position: usize) Error!usize {
    var offset = try multiply(slot, 2);
    offset += @intFromBool(values);
    offset = try multiply(offset, plan.max_kv_head_count);
    offset += head;
    offset = try multiply(offset, context);
    offset += position;
    return multiply(offset, plan.head_size);
}

/// math.isFinite over a slice, sixteen exponents per step: the check runs
/// serially after every parallel matmul and residual.
fn allFinite(values: []const f32) bool {
    const Lanes = @Vector(16, u32);
    const exponent: Lanes = @splat(0x7f800000);
    var largest: Lanes = @splat(0);
    var index: usize = 0;
    while (index + 16 <= values.len) : (index += 16) {
        const bits: Lanes = @bitCast(@as(@Vector(16, f32), values[index..][0..16].*));
        largest = @max(largest, bits & exponent);
    }
    if (@reduce(.Max, largest) == 0x7f800000) return false;
    for (values[index..]) |value| if (!math.isFinite(value)) return false;
    return true;
}

fn add(left: usize, right: usize) Error!usize {
    const result = @addWithOverflow(left, right);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn multiply(left: anytype, right: anytype) Error!usize {
    const result = @mulWithOverflow(@as(usize, @intCast(left)), @as(usize, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn validateLimits(comptime limits: Limits) void {
    if (limits.hidden == 0 or limits.feed_forward == 0 or limits.query == 0 or limits.key_value == 0 or
        limits.heads == 0 or limits.vocabulary == 0 or limits.batch == 0 or limits.context == 0)
        @compileError("LFM3 executor limits must be non-zero");
}
