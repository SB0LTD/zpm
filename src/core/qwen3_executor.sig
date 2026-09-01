//! Native allocation-free Qwen3 decoder.
//!
//! The executor is storage-neutral: host validation supplies positional file
//! reads while Pixel admission supplies authenticated DRAM. All mutable model
//! state, scratch, KV cache, cancellation, and progress policy are owned by the
//! caller. There is no process, thread, allocator, ELF, or foreign-runtime ABI.

const math = @import("sig_math");
const gguf = @import("gguf");
const qwen3 = @import("qwen3_decoder_plan");
const quantized = @import("quantized_linear");
const transformer = @import("transformer_ops");

pub const Error = quantized.Error || transformer.Error || error{
    InvalidPlan,
    InvalidToken,
    ContextCapacity,
    KvCapacity,
    RowCapacity,
    StorageFailure,
    ArithmeticOverflow,
    Cancelled,
};

pub const Stage = enum(u8) {
    request_begin,
    embedding,
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

pub const KernelMode = enum(u8) { fused, scalar_reference };

pub const ProgressEvent = struct {
    stage: Stage,
    layer: u8,
    completed: u32,
    total: u32,
};

pub const ProgressFn = *const fn (context: *anyopaque, event: ProgressEvent) bool;

pub const Progress = struct {
    context: ?*anyopaque = null,
    callback: ?ProgressFn = null,

    pub fn report(self: Progress, event: ProgressEvent) Error!void {
        const callback = self.callback orelse return;
        const context = self.context orelse return error.InvalidPlan;
        if (!callback(context, event)) return error.Cancelled;
    }
};

pub const Limits = struct {
    hidden: usize,
    query: usize,
    key_value: usize,
    feed_forward: usize,
    vocabulary: usize,
    context: usize,
    row_bytes: usize,
};

pub const qwen3_0_6b_limits = Limits{
    .hidden = 1024,
    .query = 2048,
    .key_value = 1024,
    .feed_forward = 3072,
    .vocabulary = 151_936,
    .context = 64,
    .row_bytes = 12_288,
};

pub fn WorkingSet(comptime limits: Limits) type {
    validateLimits(limits);
    return struct {
        hidden: [limits.hidden]f32 = @splat(0),
        normalized: [limits.hidden]f32 = @splat(0),
        weight: [limits.hidden]f32 = @splat(0),
        query: [limits.query]f32 = @splat(0),
        key: [limits.key_value]f32 = @splat(0),
        value: [limits.key_value]f32 = @splat(0),
        attention: [limits.query]f32 = @splat(0),
        gate: [limits.feed_forward]f32 = @splat(0),
        up: [limits.feed_forward]f32 = @splat(0),
        scores: [limits.context]f32 = @splat(0),
        logits: [limits.vocabulary]f32 = @splat(0),
        reference_row: [@max(@max(limits.hidden, limits.query), limits.feed_forward)]f32 = @splat(0),
        row: [limits.row_bytes]u8 = @splat(0),

        pub fn staticBytes() usize { return @sizeOf(@This()); }
    };
}

pub fn requiredKvElements(plan: qwen3.Plan, context_capacity: usize) Error!usize {
    if (context_capacity == 0 or plan.layer_count == 0 or plan.kv_head_count == 0 or plan.head_size == 0)
        return error.InvalidPlan;
    var elements = try multiply(plan.layer_count, 2);
    elements = try multiply(elements, plan.kv_head_count);
    elements = try multiply(elements, context_capacity);
    return multiply(elements, plan.head_size);
}

/// Run one token through the decoder. Intermediate prefill positions may set
/// `produce_logits=false`; the final prompt token and generated tokens set it
/// true. Returned token selection is deterministic greedy argmax.
pub fn forward(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const qwen3.Plan,
    work: *WorkingSet(limits),
    kv_storage: []u16,
    context_capacity: usize,
    token: u32,
    position: usize,
    produce_logits: bool,
    progress: Progress,
) Error!?u32 {
    return forwardWithKernels(
        tensor_capacity, limits, source, index, plan, work, kv_storage,
        context_capacity, token, position, produce_logits, .fused, progress,
    );
}

/// Slow independent quantized-row reference. It shares architecture policy
/// but expands Q4_K/Q6_K into caller-owned f32 before scalar dot products,
/// making it a pure-Sig numerical oracle for the fused vector kernels.
pub fn forwardWithKernels(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const qwen3.Plan,
    work: *WorkingSet(limits),
    kv_storage: []u16,
    context_capacity: usize,
    token: u32,
    position: usize,
    produce_logits: bool,
    kernel_mode: KernelMode,
    progress: Progress,
) Error!?u32 {
    try validateRuntime(limits, index, plan, kv_storage, context_capacity, token, position);
    const hidden_size: usize = plan.hidden_size;
    const query_size: usize = plan.query_size;
    const key_value_size: usize = plan.key_value_size;
    const feed_forward_size: usize = plan.feed_forward_size;
    const vocabulary_size: usize = plan.vocabulary_size;
    const head_size: usize = plan.head_size;

    try readEmbedding(
        source,
        tensor(index, plan.token_embedding),
        token,
        work.hidden[0..hidden_size],
        &work.row,
    );
    try progress.report(.{ .stage = .embedding, .layer = 0, .completed = 1, .total = 1 });

    for (plan.layers[0..plan.layer_count], 0..) |layer, layer_index| {
        const layer_u8: u8 = @intCast(layer_index);
        try readVector(source, tensor(index, layer.attention_norm), work.weight[0..hidden_size], &work.row);
        try transformer.rmsNorm(
            work.hidden[0..hidden_size],
            work.weight[0..hidden_size],
            work.normalized[0..hidden_size],
            plan.rms_norm_epsilon,
        );
        try matvec(
            source, tensor(index, layer.query), work.normalized[0..hidden_size],
            work.query[0..query_size], &work.row, &work.reference_row,
            kernel_mode, progress, .attention_query, layer_u8,
        );
        try matvec(
            source, tensor(index, layer.key), work.normalized[0..hidden_size],
            work.key[0..key_value_size], &work.row, &work.reference_row,
            kernel_mode, progress, .attention_key, layer_u8,
        );
        try matvec(
            source, tensor(index, layer.value), work.normalized[0..hidden_size],
            work.value[0..key_value_size], &work.row, &work.reference_row,
            kernel_mode, progress, .attention_value, layer_u8,
        );

        try readVector(source, tensor(index, layer.query_norm), work.weight[0..head_size], &work.row);
        for (0..plan.head_count) |head| {
            const values = work.query[head * head_size ..][0..head_size];
            try transformer.rmsNorm(values, work.weight[0..head_size], values, plan.rms_norm_epsilon);
        }
        try readVector(source, tensor(index, layer.key_norm), work.weight[0..head_size], &work.row);
        for (0..plan.kv_head_count) |head| {
            const values = work.key[head * head_size ..][0..head_size];
            try transformer.rmsNorm(values, work.weight[0..head_size], values, plan.rms_norm_epsilon);
        }
        try transformer.ropeSplitHalf(
            work.query[0..query_size], plan.head_count, head_size, position, plan.rope_frequency_base,
        );
        try transformer.ropeSplitHalf(
            work.key[0..key_value_size], plan.kv_head_count, head_size, position, plan.rope_frequency_base,
        );
        try storeKv(plan, kv_storage, context_capacity, layer_index, position,
            work.key[0..key_value_size], work.value[0..key_value_size]);
        try groupedAttention(
            plan, kv_storage, context_capacity, layer_index, position,
            work.query[0..query_size], work.scores[0 .. position + 1], work.attention[0..query_size],
        );
        try matvec(
            source, tensor(index, layer.attention_output), work.attention[0..query_size],
            work.normalized[0..hidden_size], &work.row, &work.reference_row,
            kernel_mode, progress, .attention_output, layer_u8,
        );
        try addResidual(work.hidden[0..hidden_size], work.normalized[0..hidden_size]);

        try readVector(source, tensor(index, layer.ffn_norm), work.weight[0..hidden_size], &work.row);
        try transformer.rmsNorm(
            work.hidden[0..hidden_size], work.weight[0..hidden_size],
            work.normalized[0..hidden_size], plan.rms_norm_epsilon,
        );
        try matvec(
            source, tensor(index, layer.ffn_gate), work.normalized[0..hidden_size],
            work.gate[0..feed_forward_size], &work.row, &work.reference_row,
            kernel_mode, progress, .feed_forward_gate, layer_u8,
        );
        try matvec(
            source, tensor(index, layer.ffn_up), work.normalized[0..hidden_size],
            work.up[0..feed_forward_size], &work.row, &work.reference_row,
            kernel_mode, progress, .feed_forward_up, layer_u8,
        );
        try transformer.siluGate(work.gate[0..feed_forward_size], work.up[0..feed_forward_size]);
        try matvec(
            source, tensor(index, layer.ffn_down), work.gate[0..feed_forward_size],
            work.normalized[0..hidden_size], &work.row, &work.reference_row,
            kernel_mode, progress, .feed_forward_down, layer_u8,
        );
        try addResidual(work.hidden[0..hidden_size], work.normalized[0..hidden_size]);
        try progress.report(.{
            .stage = .layer_complete,
            .layer = layer_u8,
            .completed = @intCast(layer_index + 1),
            .total = plan.layer_count,
        });
    }

    if (!produce_logits) return null;
    try readVector(source, tensor(index, plan.output_norm), work.weight[0..hidden_size], &work.row);
    try transformer.rmsNorm(
        work.hidden[0..hidden_size], work.weight[0..hidden_size],
        work.normalized[0..hidden_size], plan.rms_norm_epsilon,
    );
    try matvec(
        source, tensor(index, plan.output), work.normalized[0..hidden_size],
        work.logits[0..vocabulary_size], &work.row, &work.reference_row,
        kernel_mode, progress, .logits, plan.layer_count,
    );
    return @intCast(try transformer.argmax(work.logits[0..vocabulary_size]));
}

fn validateRuntime(
    comptime limits: Limits,
    index: anytype,
    plan: *const qwen3.Plan,
    kv_storage: []u16,
    context_capacity: usize,
    token: u32,
    position: usize,
) Error!void {
    if (plan.layer_count == 0 or plan.layer_count > qwen3.MAX_LAYERS or
        plan.hidden_size == 0 or plan.hidden_size > limits.hidden or
        plan.query_size == 0 or plan.query_size > limits.query or
        plan.key_value_size == 0 or plan.key_value_size > limits.key_value or
        plan.feed_forward_size == 0 or plan.feed_forward_size > limits.feed_forward or
        plan.vocabulary_size == 0 or plan.vocabulary_size > limits.vocabulary or
        plan.head_size == 0 or plan.head_count == 0 or plan.kv_head_count == 0 or
        plan.query_size != @as(u32, plan.head_count) * plan.head_size or
        plan.key_value_size != @as(u32, plan.kv_head_count) * plan.head_size or
        plan.head_count % plan.kv_head_count != 0 or
        context_capacity == 0 or context_capacity > limits.context or position >= context_capacity or
        index.tensor_count == 0) return error.InvalidPlan;
    if (token >= plan.vocabulary_size) return error.InvalidToken;
    if (kv_storage.len < try requiredKvElements(plan.*, context_capacity)) return error.KvCapacity;
}

fn tensor(index: anytype, reference: qwen3.TensorRef) *const gguf.TensorInfo {
    // Schema binding has already proved every reference present and in range.
    return &index.tensors[reference.index];
}

fn readEmbedding(
    source: gguf.Source,
    tensor_info: *const gguf.TensorInfo,
    token: u32,
    output: []f32,
    row_scratch: []u8,
) Error!void {
    if (tensor_info.dimension_count != 2 or tensor_info.dimensions[0] != output.len or
        token >= tensor_info.dimensions[1]) return error.InvalidPlan;
    const row_bytes = try matrixRowBytes(tensor_info);
    const row = try readRow(source, tensor_info, token, row_bytes, row_scratch);
    switch (tensor_info.ggml_type) {
        0 => try copyF32(row, output),
        12 => try quantized.dequantizeQ4K(output, row),
        14 => try quantized.dequantizeQ6K(output, row),
        else => return error.InvalidPlan,
    }
}

fn readVector(source: gguf.Source, tensor_info: *const gguf.TensorInfo, output: []f32, scratch: []u8) Error!void {
    if (tensor_info.dimension_count != 1 or tensor_info.dimensions[0] != output.len or
        tensor_info.ggml_type != 0) return error.InvalidPlan;
    const required = try multiply(output.len, @sizeOf(f32));
    const bytes = if (source.view(tensor_info.file_offset, required, 1)) |mapped|
        mapped
    else block: {
        if (required > scratch.len) return error.RowCapacity;
        if (!source.read(tensor_info.file_offset, scratch[0..required])) return error.StorageFailure;
        break :block scratch[0..required];
    };
    try copyF32(bytes, output);
}

fn matvec(
    source: gguf.Source,
    tensor_info: *const gguf.TensorInfo,
    input: []const f32,
    output: []f32,
    row_scratch: []u8,
    reference_row: []f32,
    kernel_mode: KernelMode,
    progress: Progress,
    stage: Stage,
    layer: u8,
) Error!void {
    if (tensor_info.dimension_count != 2 or tensor_info.dimensions[0] != input.len or
        tensor_info.dimensions[1] != output.len) return error.InvalidPlan;
    const row_bytes = try matrixRowBytes(tensor_info);
    for (output, 0..) |*destination, row_index| {
        const row = try readRow(source, tensor_info, row_index, row_bytes, row_scratch);
        destination.* = if (kernel_mode == .scalar_reference and tensor_info.ggml_type != 0) block: {
            if (reference_row.len < input.len) return error.RowCapacity;
            const expanded = reference_row[0..input.len];
            switch (tensor_info.ggml_type) {
                12 => try quantized.dequantizeQ4K(expanded, row),
                14 => try quantized.dequantizeQ6K(expanded, row),
                else => return error.InvalidPlan,
            }
            break :block scalarDot(expanded, input);
        } else switch (tensor_info.ggml_type) {
            0 => try quantized.dotF32(row, input),
            12 => try quantized.dotQ4K(row, input),
            14 => try quantized.dotQ6K(row, input),
            else => return error.InvalidPlan,
        };
        if (!math.isFinite(destination.*)) return error.NonFinite;
        if ((row_index + 1) % 256 == 0 or row_index + 1 == output.len) try progress.report(.{
            .stage = stage,
            .layer = layer,
            .completed = @intCast(row_index + 1),
            .total = @intCast(output.len),
        });
    }
}

fn scalarDot(left: []const f32, right: []const f32) f32 {
    var sum: f32 = 0;
    for (left, right) |a, b| sum += a * b;
    return sum;
}

fn matrixRowBytes(tensor_info: *const gguf.TensorInfo) Error!usize {
    if (tensor_info.dimension_count != 2 or tensor_info.dimensions[1] == 0 or
        tensor_info.byte_size % tensor_info.dimensions[1] != 0) return error.InvalidPlan;
    const bytes = tensor_info.byte_size / tensor_info.dimensions[1];
    if (bytes == 0 or bytes > math.maxInt(usize)) return error.InvalidPlan;
    return @intCast(bytes);
}

fn readRow(
    source: gguf.Source,
    tensor_info: *const gguf.TensorInfo,
    row_index: anytype,
    row_bytes: usize,
    scratch: []u8,
) Error![]const u8 {
    const relative = try multiply(@as(usize, @intCast(row_index)), row_bytes);
    const offset = @addWithOverflow(tensor_info.file_offset, @as(u64, @intCast(relative)));
    if (offset[1] != 0) return error.ArithmeticOverflow;
    if (source.view(offset[0], row_bytes, 1)) |mapped| return mapped;
    if (row_bytes > scratch.len) return error.RowCapacity;
    if (!source.read(offset[0], scratch[0..row_bytes])) return error.StorageFailure;
    return scratch[0..row_bytes];
}

fn copyF32(bytes: []const u8, output: []f32) Error!void {
    if (bytes.len < output.len * @sizeOf(f32)) return error.StorageFailure;
    for (output, 0..) |*destination, index| {
        const offset = index * 4;
        const bits = @as(u32, bytes[offset]) |
            (@as(u32, bytes[offset + 1]) << 8) |
            (@as(u32, bytes[offset + 2]) << 16) |
            (@as(u32, bytes[offset + 3]) << 24);
        destination.* = @bitCast(bits);
        if (!math.isFinite(destination.*)) return error.NonFinite;
    }
}

fn storeKv(
    plan: *const qwen3.Plan,
    storage: []u16,
    context_capacity: usize,
    layer: usize,
    position: usize,
    keys: []const f32,
    values: []const f32,
) Error!void {
    const head_size: usize = plan.head_size;
    for (0..plan.kv_head_count) |head| {
        const source_offset = head * head_size;
        const key_offset = try kvOffset(plan, context_capacity, layer, false, head, position);
        const value_offset = try kvOffset(plan, context_capacity, layer, true, head, position);
        for (0..head_size) |lane| {
            const key = keys[source_offset + lane];
            const value = values[source_offset + lane];
            if (!math.isFinite(key) or !math.isFinite(value)) return error.NonFinite;
            storage[key_offset + lane] = transformer.f32ToF16Bits(key);
            storage[value_offset + lane] = transformer.f32ToF16Bits(value);
        }
    }
}

fn groupedAttention(
    plan: *const qwen3.Plan,
    storage: []const u16,
    context_capacity: usize,
    layer: usize,
    position: usize,
    queries: []const f32,
    scores: []f32,
    output: []f32,
) Error!void {
    const head_size: usize = plan.head_size;
    const group_size = plan.head_count / plan.kv_head_count;
    const context_length = position + 1;
    const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(head_size)));
    for (0..plan.head_count) |query_head| {
        const kv_head = query_head / group_size;
        const query = queries[query_head * head_size ..][0..head_size];
        for (scores[0..context_length], 0..) |*score, token_position| {
            const key_offset = try kvOffset(plan, context_capacity, layer, false, kv_head, token_position);
            var dot: f32 = 0;
            for (0..head_size) |lane|
                dot += query[lane] * transformer.f16BitsToF32(storage[key_offset + lane]);
            score.* = dot * scale;
        }
        try transformer.softmax(scores[0..context_length]);
        const destination = output[query_head * head_size ..][0..head_size];
        @memset(destination, 0);
        for (scores[0..context_length], 0..) |score, token_position| {
            const value_offset = try kvOffset(plan, context_capacity, layer, true, kv_head, token_position);
            for (0..head_size) |lane|
                destination[lane] += score * transformer.f16BitsToF32(storage[value_offset + lane]);
        }
    }
}

fn kvOffset(
    plan: *const qwen3.Plan,
    context_capacity: usize,
    layer: usize,
    values: bool,
    head: usize,
    position: usize,
) Error!usize {
    var offset = try multiply(layer, 2);
    offset += @intFromBool(values);
    offset = try multiply(offset, plan.kv_head_count);
    offset += head;
    offset = try multiply(offset, context_capacity);
    offset += position;
    return multiply(offset, plan.head_size);
}

fn addResidual(destination: []f32, residual: []const f32) Error!void {
    if (destination.len != residual.len) return error.InvalidPlan;
    for (destination, residual) |*value, addition| {
        value.* += addition;
        if (!math.isFinite(value.*)) return error.NonFinite;
    }
}

fn multiply(left: anytype, right: anytype) Error!usize {
    const result = @mulWithOverflow(@as(usize, @intCast(left)), @as(usize, @intCast(right)));
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

fn validateLimits(comptime limits: Limits) void {
    if (limits.hidden == 0 or limits.query == 0 or limits.key_value == 0 or
        limits.feed_forward == 0 or limits.vocabulary == 0 or limits.context == 0 or
        limits.row_bytes < 4) @compileError("Qwen executor limits must be non-zero");
}

