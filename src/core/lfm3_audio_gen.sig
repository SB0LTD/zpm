//! LFM3-Audio speaking: the text model's hidden state to speech codes, codes
//! back into the text model, and codes to 24 kHz mono PCM. Allocation-free;
//! every buffer and all state are caller-owned.
//!
//! Each audio frame (80 ms) is 12 codes from 2016-entry codebooks, plus a
//! shared end-of-audio code. The graph and the loop are llama.cpp's
//! (clip_graph_lfm3a_gen, lfm3a_gen_audio_pipeline):
//!
//!   - `codePass`: one MaskGIT pass of a 3-layer depthformer over 12
//!     positions (one per codebook): the projected hidden state plus each
//!     revealed code's embedding or the mask embedding, bidirectional GQA with
//!     a per-head sigmoid gate, RMSNorm, per-codebook RMSNorm, then logits
//!     against the (tied) code embeddings.
//!   - `Speaker.frame`: a random reveal order of the codebooks, three passes
//!     revealing 4 codebooks each, a CTRL repetition penalty over the codes a
//!     codebook took before, then greedy or top-k/temperature sampling.
//!   - `feedback`: the sum of the 12 codes' output embeddings, the next input
//!     row of the text model.
//!   - `Codec`: FSQ decode, a linear map to 512, 6x upsampling, 8 causal LFM
//!     layers with sandwich norms (short convolution or 30-position sliding-
//!     window gated GQA), a projection to 641 log-magnitudes and phases per
//!     STFT frame, and a streaming ISTFT (1280-point, hop 320).

const gguf = @import("gguf");
const ops = @import("lfm3_audio_ops");

pub const Error = ops.Error;
pub const Parallel = ops.Parallel;
const Ref = ops.Ref;
const NONE = ops.NONE;

pub const CODEBOOKS: usize = 12;
/// Codebooks revealed per depthformer pass (interleaved_n_* of the checkpoint).
pub const SCHEDULE = [_]usize{ 4, 4, 4 };
pub const MAX_DEPTH_LAYERS: usize = 8;
pub const MAX_CODEC_LAYERS: usize = 16;

// LiquidCodecConfig values llama.cpp hard-codes for this projector.
pub const SAMPLE_RATE: u32 = 24_000;
pub const FRAME_STACK: usize = 6;
pub const FFT_SIZE: usize = 1280;
pub const HOP: usize = 320;
pub const BINS: usize = FFT_SIZE / 2 + 1;
pub const SAMPLES_PER_FRAME: usize = FRAME_STACK * HOP;
const CODEC_WINDOW: usize = 30;
/// Longest key row of one attention call: the codec's window plus a chunk.
const MAX_KEY_ROW: usize = 256;
const CODEC_EPSILON: f32 = 1e-5;
const ROPE_BASE: f32 = 1_000_000;

pub const Limits = struct {
    depth_hidden: usize,
    depth_feed_forward: usize,
    depth_kv_width: usize,
    depth_heads: usize,
    vocabulary: usize,
    backbone: usize,
    codec_hidden: usize,
    codec_feed_forward: usize,
    codec_kv_width: usize,
    codec_heads: usize,
    codec_layers: usize,
    codec_kernel: usize,
    /// Codec frames per `Codec.decode` call.
    frames: usize,
    /// Frames the repetition penalty can look back on.
    history: usize,
};

pub const lfm3_audio_limits = Limits{
    .depth_hidden = 1024,
    .depth_feed_forward = 2816,
    .depth_kv_width = 256,
    .depth_heads = 32,
    .vocabulary = 2017,
    .backbone = 2048,
    .codec_hidden = 512,
    .codec_feed_forward = 2304,
    .codec_kv_width = 128,
    .codec_heads = 8,
    .codec_layers = 8,
    .codec_kernel = 7,
    .frames = 4,
    .history = 512,
};

pub const Layer = struct {
    attention: bool = false,
    slot: u8 = 0,
    ln1: Ref = NONE,
    ln2: Ref = NONE,
    attn_post_norm: Ref = NONE,
    ffn_post_norm: Ref = NONE,
    ffn_gate: Ref = NONE,
    ffn_up: Ref = NONE,
    ffn_down: Ref = NONE,
    conv_dw: Ref = NONE,
    conv_in: Ref = NONE,
    conv_out: Ref = NONE,
    q: Ref = NONE,
    k: Ref = NONE,
    v: Ref = NONE,
    o: Ref = NONE,
    gate: Ref = NONE,
    q_norm: Ref = NONE,
    k_norm: Ref = NONE,
};

/// Shape of one LFM stack (depthformer or codec decoder).
pub const Stack = struct {
    hidden: usize = 0,
    feed_forward: usize = 0,
    heads: usize = 0,
    kv_heads: usize = 0,
    head_size: usize = 0,
    kernel: usize = 0,
    epsilon: f32 = 0,
    layer_count: usize = 0,
    conv_layer_count: usize = 0,
    attention_layer_count: usize = 0,

    pub fn kvWidth(self: *const Stack) usize {
        return self.kv_heads * self.head_size;
    }
};

pub const Plan = struct {
    depth: Stack = .{},
    depth_layers: [MAX_DEPTH_LAYERS]Layer = @splat(.{}),
    codec: Stack = .{},
    codec_layers: [MAX_CODEC_LAYERS]Layer = @splat(.{}),
    /// Codes per codebook including the end-of-audio code (the last one).
    vocabulary: usize = 0,
    backbone: usize = 0,
    levels: usize = 0,
    temperature: f32 = 1,
    top_k: u32 = 0,
    penalty: f32 = 1,
    penalty_window: u32 = 0,
    code_embd: Ref = NONE,
    head_norm: Ref = NONE,
    mask_embd: Ref = NONE,
    out_embd: Ref = NONE,
    output_norm: Ref = NONE,
    proj_in_w: Ref = NONE,
    proj_in_b: Ref = NONE,
    fsq_codebook: Ref = NONE,
    fsq_out_w: Ref = NONE,
    fsq_out_b: Ref = NONE,
    codec_in_w: Ref = NONE,
    codec_in_b: Ref = NONE,
    codec_out_w: Ref = NONE,
    codec_out_b: Ref = NONE,
    codec_norm: Ref = NONE,
    codec_proj: usize = 0,

    pub fn endCode(self: *const Plan) i32 {
        return @intCast(self.vocabulary - 1);
    }
};

pub fn build(comptime tensor_capacity: usize, source: gguf.Source, index: *const gguf.Index(tensor_capacity), out: *Plan) Error!void {
    out.* = .{};
    out.depth.hidden = try metadataSize(source, "clip.gen.audio.embedding_length");
    out.depth.feed_forward = try metadataSize(source, "clip.gen.audio.feed_forward_length");
    out.depth.layer_count = try metadataSize(source, "clip.gen.audio.block_count");
    out.depth.heads = try metadataSize(source, "clip.gen.audio.attention.head_count");
    out.depth.kv_heads = try metadataSize(source, "clip.gen.audio.attention.head_count_kv");
    out.backbone = try metadataSize(source, "clip.gen.audio.projection_dim");
    out.depth.epsilon = @floatCast(try metadataFloat(source, "clip.gen.audio.attention.layer_norm_epsilon", null));
    out.temperature = @floatCast(try metadataFloat(source, "clip.gen.audio.sampling.temp", 0.4));
    out.top_k = @intFromFloat(try metadataFloat(source, "clip.gen.audio.sampling.top_k", 0));
    out.penalty = @floatCast(try metadataFloat(source, "clip.gen.audio.sampling.penalty_repeat", 1.2));
    out.penalty_window = @intFromFloat(try metadataFloat(source, "clip.gen.audio.sampling.penalty_last_n", 64));
    if (out.depth.layer_count == 0 or out.depth.layer_count > MAX_DEPTH_LAYERS) return error.InvalidModel;

    out.code_embd = ops.find(index, "a.gen.code.embd.weight");
    out.head_norm = ops.find(index, "a.gen.code.head_norm.weight");
    out.mask_embd = ops.find(index, "a.gen.code.mask_embd");
    out.out_embd = ops.find(index, "a.gen.code.out_embd.weight");
    out.output_norm = ops.find(index, "a.gen.code.output_norm.weight");
    out.proj_in_w = ops.find(index, "a.gen.code.proj_in.weight");
    out.proj_in_b = ops.find(index, "a.gen.code.proj_in.bias");
    if (ops.dimension(index, out.code_embd, 2) != CODEBOOKS or ops.dimension(index, out.code_embd, 0) != out.depth.hidden) return error.InvalidModel;
    out.vocabulary = ops.dimension(index, out.code_embd, 1);
    try findStack(index, "a.gen.code.blk.", &out.depth, &out.depth_layers);

    out.fsq_codebook = ops.find(index, "a.gen.wav.quant.first.codebook.weight");
    out.fsq_out_w = ops.find(index, "a.gen.wav.quant.first.out_proj.weight");
    out.fsq_out_b = ops.find(index, "a.gen.wav.quant.first.out_proj.bias");
    out.codec_in_w = ops.find(index, "a.gen.wav.tfm.in_proj.weight");
    out.codec_in_b = ops.find(index, "a.gen.wav.tfm.in_proj.bias");
    out.codec_out_w = ops.find(index, "a.gen.wav.tfm.out_proj.weight");
    out.codec_out_b = ops.find(index, "a.gen.wav.tfm.out_proj.bias");
    out.codec_norm = ops.find(index, "a.gen.wav.tfm.output_norm.weight");
    out.levels = ops.dimension(index, out.fsq_codebook, 0);
    if (ops.dimension(index, out.fsq_codebook, 1) + 1 != out.vocabulary) return error.InvalidModel;
    out.codec.hidden = ops.dimension(index, out.codec_norm, 0);
    out.codec.epsilon = CODEC_EPSILON;
    out.codec_proj = ops.dimension(index, out.codec_out_w, 1);
    if (out.codec_proj != 2 * BINS) return error.InvalidModel;
    var count: usize = 0;
    while (count < MAX_CODEC_LAYERS and ops.present(ops.findLayer(index, "a.gen.wav.tfm.blk.", count, ".ln1.weight"))) count += 1;
    out.codec.layer_count = count;
    try findStack(index, "a.gen.wav.tfm.blk.", &out.codec, &out.codec_layers);
    out.codec.feed_forward = ops.dimension(index, out.codec_layers[0].ffn_up, 1);
    try validate(tensor_capacity, source, index, out);
}

fn metadataSize(source: gguf.Source, key: []const u8) Error!usize {
    const value = (gguf.metadataNumber(source, key) catch return error.InvalidModel) orelse return error.InvalidModel;
    if (value < 1 or value > 1 << 24) return error.InvalidModel;
    return @intFromFloat(value);
}

fn metadataFloat(source: gguf.Source, key: []const u8, default: ?f64) Error!f64 {
    const value = gguf.metadataNumber(source, key) catch return error.InvalidModel;
    return value orelse default orelse error.InvalidModel;
}

fn findStack(index: anytype, prefix: []const u8, stack: *Stack, layers: []Layer) Error!void {
    if (stack.layer_count == 0 or stack.layer_count > layers.len) return error.InvalidModel;
    for (layers[0..stack.layer_count], 0..) |*layer, number| {
        layer.ln1 = ops.findLayer(index, prefix, number, ".ln1.weight");
        layer.ln2 = ops.findLayer(index, prefix, number, ".ln2.weight");
        layer.attn_post_norm = ops.findLayer(index, prefix, number, ".attn_post_norm.weight");
        layer.ffn_post_norm = ops.findLayer(index, prefix, number, ".ffn_post_norm.weight");
        layer.ffn_gate = ops.findLayer(index, prefix, number, ".ffn_gate.weight");
        layer.ffn_up = ops.findLayer(index, prefix, number, ".ffn_up.weight");
        layer.ffn_down = ops.findLayer(index, prefix, number, ".ffn_down.weight");
        layer.conv_dw = ops.findLayer(index, prefix, number, ".conv_dw.weight");
        if (ops.present(layer.conv_dw)) {
            layer.conv_in = ops.findLayer(index, prefix, number, ".conv_pw1.weight");
            layer.conv_out = ops.findLayer(index, prefix, number, ".conv_pw2.weight");
            layer.slot = @intCast(stack.conv_layer_count);
            stack.conv_layer_count += 1;
            const kernel = ops.dimension(index, layer.conv_dw, 0);
            if (stack.kernel == 0) stack.kernel = kernel;
            if (kernel != stack.kernel) return error.InvalidModel;
        } else {
            layer.attention = true;
            layer.q = ops.findLayer(index, prefix, number, ".attn_q.weight");
            layer.k = ops.findLayer(index, prefix, number, ".attn_k.weight");
            layer.v = ops.findLayer(index, prefix, number, ".attn_v.weight");
            layer.o = ops.findLayer(index, prefix, number, ".attn_out.weight");
            layer.gate = ops.findLayer(index, prefix, number, ".attn_gate.weight");
            layer.q_norm = ops.findLayer(index, prefix, number, ".attn_q_norm.weight");
            layer.k_norm = ops.findLayer(index, prefix, number, ".attn_k_norm.weight");
            layer.slot = @intCast(stack.attention_layer_count);
            stack.attention_layer_count += 1;
            const head_size = ops.dimension(index, layer.q_norm, 0);
            if (head_size == 0) return error.InvalidModel;
            if (stack.head_size == 0) stack.head_size = head_size;
            if (head_size != stack.head_size) return error.InvalidModel;
            // Head counts come from the tensors (llama.cpp: "from the tensors").
            const heads = ops.dimension(index, layer.q, 1) / head_size;
            const kv_heads = ops.dimension(index, layer.k, 1) / head_size;
            if (stack.heads == 0) stack.heads = heads;
            if (stack.kv_heads == 0) stack.kv_heads = kv_heads;
            if (heads != stack.heads or kv_heads != stack.kv_heads) return error.InvalidModel;
        }
    }
    if (stack.attention_layer_count > 0 and (stack.kv_heads == 0 or stack.heads % stack.kv_heads != 0)) return error.InvalidModel;
}

fn validate(comptime tensor_capacity: usize, source: gguf.Source, index: *const gguf.Index(tensor_capacity), plan: *const Plan) Error!void {
    const d = plan.depth.hidden;
    const table = try ops.matrix(source, index, plan.code_embd);
    if (table.columns != d or table.rows != CODEBOOKS * plan.vocabulary) return error.InvalidModel;
    _ = try ops.vector(source, index, plan.head_norm, CODEBOOKS * d);
    _ = try ops.vector(source, index, plan.mask_embd, d);
    try expectMatrix(source, index, plan.out_embd, plan.backbone, CODEBOOKS * plan.vocabulary);
    _ = try ops.vector(source, index, plan.output_norm, d);
    try expectMatrix(source, index, plan.proj_in_w, plan.backbone, CODEBOOKS * d);
    _ = try ops.vector(source, index, plan.proj_in_b, CODEBOOKS * d);
    try validateStack(source, index, &plan.depth, plan.depth_layers[0..plan.depth.layer_count]);
    const c = plan.codec.hidden;
    _ = try ops.vector(source, index, plan.fsq_codebook, plan.levels * (plan.vocabulary - 1));
    const fsq_out = ops.dimension(index, plan.fsq_out_w, 1);
    _ = try ops.vector(source, index, plan.fsq_out_w, CODEBOOKS * plan.levels * fsq_out);
    _ = try ops.vector(source, index, plan.fsq_out_b, fsq_out);
    try expectMatrix(source, index, plan.codec_in_w, fsq_out, c);
    _ = try ops.vector(source, index, plan.codec_in_b, c);
    try expectMatrix(source, index, plan.codec_out_w, c, plan.codec_proj);
    _ = try ops.vector(source, index, plan.codec_out_b, plan.codec_proj);
    _ = try ops.vector(source, index, plan.codec_norm, c);
    try validateStack(source, index, &plan.codec, plan.codec_layers[0..plan.codec.layer_count]);
}

fn validateStack(source: gguf.Source, index: anytype, stack: *const Stack, layers: []const Layer) Error!void {
    const h = stack.hidden;
    for (layers) |*layer| {
        _ = try ops.vector(source, index, layer.ln1, h);
        _ = try ops.vector(source, index, layer.ln2, h);
        _ = try ops.optionalVector(source, index, layer.attn_post_norm, h);
        _ = try ops.optionalVector(source, index, layer.ffn_post_norm, h);
        try expectMatrix(source, index, layer.ffn_gate, h, stack.feed_forward);
        try expectMatrix(source, index, layer.ffn_up, h, stack.feed_forward);
        try expectMatrix(source, index, layer.ffn_down, stack.feed_forward, h);
        if (layer.attention) {
            try expectMatrix(source, index, layer.q, h, stack.heads * stack.head_size);
            try expectMatrix(source, index, layer.k, h, stack.kvWidth());
            try expectMatrix(source, index, layer.v, h, stack.kvWidth());
            try expectMatrix(source, index, layer.o, stack.heads * stack.head_size, h);
            if (ops.present(layer.gate)) try expectMatrix(source, index, layer.gate, h, stack.heads);
            _ = try ops.vector(source, index, layer.q_norm, stack.head_size);
            _ = try ops.vector(source, index, layer.k_norm, stack.head_size);
        } else {
            _ = try ops.vector(source, index, layer.conv_dw, stack.kernel * h);
            try expectMatrix(source, index, layer.conv_in, h, 3 * h);
            try expectMatrix(source, index, layer.conv_out, h, h);
        }
    }
}

fn expectMatrix(source: gguf.Source, index: anytype, reference: Ref, columns: usize, rows: usize) Error!void {
    const view = try ops.matrix(source, index, reference);
    if (view.columns != columns or view.rows != rows) return error.InvalidModel;
}

pub fn checkLimits(comptime limits: Limits, plan: *const Plan) Error!void {
    const depth = &plan.depth;
    const codec = &plan.codec;
    if (depth.hidden > limits.depth_hidden or depth.feed_forward > limits.depth_feed_forward or
        depth.kvWidth() > limits.depth_kv_width or depth.heads > limits.depth_heads or
        depth.heads * depth.head_size > limits.depth_hidden or plan.vocabulary > limits.vocabulary or
        plan.backbone > limits.backbone or codec.hidden > limits.codec_hidden or
        codec.feed_forward > limits.codec_feed_forward or codec.kvWidth() > limits.codec_kv_width or
        codec.heads > limits.codec_heads or codec.heads * codec.head_size > limits.codec_hidden or
        codec.layer_count > limits.codec_layers or codec.kernel > limits.codec_kernel or
        codec.kernel > ops.MAX_CONV_KERNEL or plan.levels * CODEBOOKS > 64 or plan.codec_proj != 2 * BINS) return error.Capacity;
}

// ── Depthformer ─────────────────────────────────────────────────────────────

pub fn DepthWorkspace(comptime limits: Limits) type {
    const n = CODEBOOKS;
    const widest = @max(@max(limits.backbone, limits.depth_feed_forward), limits.depth_hidden);
    return struct {
        projected_state: [n * limits.depth_hidden]f32 = @splat(0),
        hidden: [n * limits.depth_hidden]f32 = @splat(0),
        normalized: [n * limits.depth_hidden]f32 = @splat(0),
        // (the depthformer has no short-conv layers; the shared layer code names it)
        mixed: [0]f32 = .{},
        query: [n * limits.depth_hidden]f32 = @splat(0),
        keys: [n * limits.depth_kv_width]f32 = @splat(0),
        values: [n * limits.depth_kv_width]f32 = @splat(0),
        gate: [n * limits.depth_heads]f32 = @splat(0),
        mixer: [n * limits.depth_hidden]f32 = @splat(0),
        projected: [n * limits.depth_hidden]f32 = @splat(0),
        ffn_gate: [n * limits.depth_feed_forward]f32 = @splat(0),
        ffn_up: [n * limits.depth_feed_forward]f32 = @splat(0),
        activations: [n * widest / ops.QK8_0]ops.Q80Block = @splat(.{}),
        logits: [n * limits.vocabulary]f32 = @splat(0),
        trace: ops.Trace = .{},
    };
}

/// One MaskGIT pass: `codes[i]` is codebook i's code when revealed, -1 when
/// masked. Writes `CODEBOOKS * plan.vocabulary` logits, codebook-major, to
/// `work.logits`. `projected_state` must hold proj_in(h_state) from
/// `projectState` (it does not change between the passes of a frame).
pub fn codePass(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const Plan,
    work: *DepthWorkspace(limits),
    codes: *const [CODEBOOKS]i32,
    parallel: Parallel,
) Error!void {
    try checkLimits(limits, plan);
    const d = plan.depth.hidden;
    const n = CODEBOOKS;
    const table = try ops.matrix(source, index, plan.code_embd);
    const mask = try ops.vector(source, index, plan.mask_embd, d);
    var embedding: [1024]f32 = undefined;
    if (d > embedding.len) return error.Capacity;
    for (0..n) |book| {
        const row = work.hidden[book * d ..][0..d];
        @memcpy(row, work.projected_state[book * d ..][0..d]);
        const code = codes[book];
        if (code >= 0) {
            if (code >= plan.vocabulary) return error.InvalidInput;
            try ops.dequantizeRow(table.row(book * plan.vocabulary + @as(usize, @intCast(code))), embedding[0..d]);
            for (row, embedding[0..d]) |*value, delta| value.* += delta;
        } else {
            for (row, mask) |*value, delta| value.* += delta;
        }
    }
    work.trace.put("depth_inp", null, work.hidden[0 .. n * d]);
    for (plan.depth_layers[0..plan.depth.layer_count]) |*layer| {
        try lfmLayer(source, index, &plan.depth, layer, work, n, null, parallel);
    }
    // Final RMSNorm, then each position's own codebook RMSNorm.
    const norm = try ops.vector(source, index, plan.output_norm, d);
    const head_norm = try ops.vector(source, index, plan.head_norm, n * d);
    for (0..n) |book| {
        const row = work.hidden[book * d ..][0..d];
        ops.rmsNorm(row, norm, work.normalized[book * d ..][0..d], plan.depth.epsilon);
        ops.rmsNorm(work.normalized[book * d ..][0..d], head_norm[book * d ..][0..d], row, plan.depth.epsilon);
    }
    try ops.quantizeRows(parallel, work.hidden[0 .. n * d], &work.activations);
    const task = LogitsTask{ .table = table, .vocabulary = plan.vocabulary, .blocks = d / ops.QK8_0, .activations = &work.activations, .logits = work.logits[0 .. n * plan.vocabulary] };
    ops.forRange(parallel, n * plan.vocabulary, &task);
    if (!ops.allFinite(work.logits[0 .. n * plan.vocabulary])) return error.NonFinite;
}

/// proj_in(h_state) + bias: the per-codebook starting rows of a frame.
pub fn projectState(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const Plan,
    work: *DepthWorkspace(limits),
    hidden_state: []const f32,
    parallel: Parallel,
) Error!void {
    try checkLimits(limits, plan);
    if (hidden_state.len != plan.backbone) return error.InvalidInput;
    try ops.project(parallel, try ops.matrix(source, index, plan.proj_in_w), hidden_state, 1, &work.activations, work.projected_state[0 .. CODEBOOKS * plan.depth.hidden], try ops.vector(source, index, plan.proj_in_b, CODEBOOKS * plan.depth.hidden));
}

/// One unit per (codebook, code): that codebook's slice of the tied table.
const LogitsTask = struct {
    table: ops.Matrix,
    vocabulary: usize,
    blocks: usize,
    activations: []const ops.Q80Block,
    logits: []f32,

    pub fn run(self: *const LogitsTask, first: usize, end: usize) void {
        for (first..end) |unit| {
            const book = unit / self.vocabulary;
            self.logits[unit] = ops.dotRow(self.table.row(unit), self.activations[book * self.blocks ..][0..self.blocks]);
        }
    }
};

/// The next text-model input row: the sum over codebooks of each code's
/// output embedding (ggml_sum_rows: f64 sums in codebook order).
pub fn feedback(
    comptime tensor_capacity: usize,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const Plan,
    codes: *const [CODEBOOKS]i32,
    out: []f32,
    scratch: []f32,
) Error!void {
    const table = try ops.matrix(source, index, plan.out_embd);
    if (out.len != plan.backbone or scratch.len < CODEBOOKS * plan.backbone) return error.Capacity;
    for (codes, 0..) |code, book| {
        if (code < 0 or code >= plan.vocabulary) return error.InvalidInput;
        try ops.dequantizeRow(table.row(book * plan.vocabulary + @as(usize, @intCast(code))), scratch[book * plan.backbone ..][0..plan.backbone]);
    }
    for (out, 0..) |*value, lane| {
        var sum: f64 = 0;
        for (0..CODEBOOKS) |book| sum += scratch[book * plan.backbone + lane];
        value.* = @floatCast(sum);
    }
}

/// Workspace fields one LFM layer reads and writes.
fn lfmLayer(
    source: gguf.Source,
    index: anytype,
    stack: *const Stack,
    layer: *const Layer,
    work: anytype,
    positions: usize,
    window: ?*const CodecWindow,
    parallel: Parallel,
) Error!void {
    const h = stack.hidden;
    try normRows(parallel, work.hidden[0 .. positions * h], try ops.vector(source, index, layer.ln1, h), stack.epsilon, work.normalized[0 .. positions * h]);
    if (layer.attention) {
        try attention(source, index, stack, layer, work, positions, window, parallel);
    } else {
        const conv = window orelse return error.InvalidModel;
        try ops.project(parallel, try ops.matrix(source, index, layer.conv_in), work.normalized[0 .. positions * h], positions, &work.activations, work.mixed[0 .. positions * 3 * h], null);
        const task = ConvTask{
            .kernel = stack.kernel,
            .hidden = h,
            .taps = try ops.vector(source, index, layer.conv_dw, stack.kernel * h),
            .state = conv.conv_state(layer.slot),
            .mixed = work.mixed[0 .. positions * 3 * h],
            .tokens = positions,
            .output = work.mixer[0 .. positions * h],
        };
        ops.forRange(parallel, h, &task);
        try ops.project(parallel, try ops.matrix(source, index, layer.conv_out), work.mixer[0 .. positions * h], positions, &work.activations, work.projected[0 .. positions * h], null);
    }
    if (try ops.optionalVector(source, index, layer.attn_post_norm, h)) |post| try normRows(parallel, work.projected[0 .. positions * h], post, stack.epsilon, work.projected[0 .. positions * h]);
    for (work.hidden[0 .. positions * h], work.projected[0 .. positions * h]) |*value, delta| value.* += delta;

    try normRows(parallel, work.hidden[0 .. positions * h], try ops.vector(source, index, layer.ln2, h), stack.epsilon, work.normalized[0 .. positions * h]);
    const ff = stack.feed_forward;
    try ops.quantizeRows(parallel, work.normalized[0 .. positions * h], &work.activations);
    try ops.linear(parallel, try ops.matrix(source, index, layer.ffn_gate), &work.activations, positions, work.ffn_gate[0 .. positions * ff], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.ffn_up), &work.activations, positions, work.ffn_up[0 .. positions * ff], null);
    for (work.ffn_gate[0 .. positions * ff], work.ffn_up[0 .. positions * ff]) |*gate, up| gate.* = ops.silu(gate.*) * up;
    try ops.project(parallel, try ops.matrix(source, index, layer.ffn_down), work.ffn_gate[0 .. positions * ff], positions, &work.activations, work.projected[0 .. positions * h], null);
    if (try ops.optionalVector(source, index, layer.ffn_post_norm, h)) |post| try normRows(parallel, work.projected[0 .. positions * h], post, stack.epsilon, work.projected[0 .. positions * h]);
    for (work.hidden[0 .. positions * h], work.projected[0 .. positions * h]) |*value, delta| value.* += delta;
    if (!ops.allFinite(work.hidden[0 .. positions * h])) return error.NonFinite;
}

/// Gated GQA with per-head RMSNorm and NeoX RoPE. Without a window (the
/// depthformer) the positions are 0..n-1 and every position sees every
/// other; with one (the codec) keys follow the carried window causally.
fn attention(
    source: gguf.Source,
    index: anytype,
    stack: *const Stack,
    layer: *const Layer,
    work: anytype,
    positions: usize,
    window: ?*const CodecWindow,
    parallel: Parallel,
) Error!void {
    const h = stack.hidden;
    const q_width = stack.heads * stack.head_size;
    const kv = stack.kvWidth();
    const prefix: usize = if (window != null) CODEC_WINDOW - 1 else 0;
    const base: usize = if (window) |w| w.position else 0;
    const keys = work.keys[0 .. (prefix + positions) * kv];
    const values = work.values[0 .. (prefix + positions) * kv];
    if (window) |w| {
        @memcpy(keys[0 .. prefix * kv], w.keys(layer.slot));
        @memcpy(values[0 .. prefix * kv], w.values(layer.slot));
    }
    try ops.quantizeRows(parallel, work.normalized[0 .. positions * h], &work.activations);
    try ops.linear(parallel, try ops.matrix(source, index, layer.q), &work.activations, positions, work.query[0 .. positions * q_width], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.k), &work.activations, positions, keys[prefix * kv ..], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.v), &work.activations, positions, values[prefix * kv ..], null);
    const gated = ops.present(layer.gate);
    if (gated) try ops.linear(parallel, try ops.matrix(source, index, layer.gate), &work.activations, positions, work.gate[0 .. positions * stack.heads], null);
    const q_norm = try ops.vector(source, index, layer.q_norm, stack.head_size);
    const k_norm = try ops.vector(source, index, layer.k_norm, stack.head_size);
    for (0..positions) |t| {
        const query = work.query[t * q_width ..][0..q_width];
        const key = keys[(prefix + t) * kv ..][0..kv];
        for (0..stack.heads) |head| {
            const row = query[head * stack.head_size ..][0..stack.head_size];
            ops.rmsNorm(row, q_norm, row, stack.epsilon);
        }
        for (0..stack.kv_heads) |head| {
            const row = key[head * stack.head_size ..][0..stack.head_size];
            ops.rmsNorm(row, k_norm, row, stack.epsilon);
        }
        ops.ropeNeox(query, stack.heads, stack.head_size, base + t, ROPE_BASE, null);
        ops.ropeNeox(key, stack.kv_heads, stack.head_size, base + t, ROPE_BASE, null);
    }
    const task = AttendTask{
        .query = work.query[0 .. positions * q_width],
        .keys = keys,
        .values = values,
        .gate = if (gated) work.gate[0 .. positions * stack.heads] else null,
        .heads = stack.heads,
        .kv_heads = stack.kv_heads,
        .head_size = stack.head_size,
        .positions = positions,
        .prefix = prefix,
        .base = base,
        .causal = window != null,
        .output = work.mixer[0 .. positions * q_width],
    };
    ops.forRange(parallel, positions * stack.heads, &task);
    if (window) |w| {
        @memcpy(w.keys(layer.slot), keys[positions * kv ..][0 .. prefix * kv]);
        @memcpy(w.values(layer.slot), values[positions * kv ..][0 .. prefix * kv]);
    }
    try ops.project(parallel, try ops.matrix(source, index, layer.o), work.mixer[0 .. positions * q_width], positions, &work.activations, work.projected[0 .. positions * h], null);
}

const AttendTask = struct {
    query: []const f32,
    keys: []const f32,
    values: []const f32,
    gate: ?[]const f32,
    heads: usize,
    kv_heads: usize,
    head_size: usize,
    positions: usize,
    prefix: usize,
    base: usize,
    causal: bool,
    output: []f32,

    pub fn run(self: *const AttendTask, first: usize, end: usize) void {
        var scratch: [2 * MAX_KEY_ROW]f32 = undefined;
        const width = self.heads * self.head_size;
        const kv_width = self.kv_heads * self.head_size;
        const group = self.heads / self.kv_heads;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(self.head_size)));
        // The whole [window | chunk] key row, masked keys included, as the
        // reference's softmax and value products see it.
        const row = self.prefix + self.positions;
        for (first..end) |unit| {
            const t = unit / self.heads;
            const head = unit % self.heads;
            var first_key: usize = 0;
            var last_key: usize = self.positions - 1;
            if (self.causal) {
                const earliest = if (self.base < self.prefix) self.prefix - self.base else 0;
                first_key = @max(t, earliest);
                last_key = self.prefix + t;
            }
            const out = self.output[t * width + head * self.head_size ..][0..self.head_size];
            ops.attendHeadGgml(self.query[t * width + head * self.head_size ..][0..self.head_size], self.keys, self.values, kv_width, (head / group) * self.head_size, row, first_key, last_key, scale, &scratch, out);
            if (self.gate) |gate| {
                const factor = ops.sigmoid(gate[t * self.heads + head]);
                for (out) |*value| value.* *= factor;
            }
        }
    }
};

const ConvTask = struct {
    kernel: usize,
    hidden: usize,
    taps: []const f32,
    state: []f32,
    mixed: []const f32,
    tokens: usize,
    output: []f32,

    pub fn run(self: *const ConvTask, first: usize, end: usize) void {
        ops.shortConvChannels(self.kernel, self.hidden, self.taps, self.state, self.mixed, self.tokens, self.output, first, end);
    }
};

fn normRows(parallel: Parallel, input: []const f32, weight: []const f32, epsilon: f32, output: []f32) Error!void {
    const task = NormTask{ .input = input, .weight = weight, .epsilon = epsilon, .output = output };
    ops.forRange(parallel, input.len / weight.len, &task);
}

const NormTask = struct {
    input: []const f32,
    weight: []const f32,
    epsilon: f32,
    output: []f32,

    pub fn run(self: *const NormTask, first: usize, end: usize) void {
        const width = self.weight.len;
        for (first..end) |row| ops.rmsNorm(self.input[row * width ..][0..width], self.weight, self.output[row * width ..][0..width], self.epsilon);
    }
};

// ── Sampling ────────────────────────────────────────────────────────────────

/// MT19937, the generator llama.cpp seeds per request.
pub const Mt19937 = struct {
    state: [624]u32 = @splat(0),
    index: usize = 624,

    pub fn init(seed: u32) Mt19937 {
        var self = Mt19937{};
        self.state[0] = seed;
        for (1..624) |i| {
            const previous = self.state[i - 1];
            self.state[i] = 1812433253 *% (previous ^ (previous >> 30)) +% @as(u32, @intCast(i));
        }
        return self;
    }

    pub fn next(self: *Mt19937) u32 {
        if (self.index >= 624) {
            for (0..624) |i| {
                const y = (self.state[i] & 0x80000000) | (self.state[(i + 1) % 624] & 0x7fffffff);
                var value = self.state[(i + 397) % 624] ^ (y >> 1);
                if (y & 1 != 0) value ^= 0x9908b0df;
                self.state[i] = value;
            }
            self.index = 0;
        }
        var y = self.state[self.index];
        self.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c5680;
        y ^= (y << 15) & 0xefc60000;
        y ^= y >> 18;
        return y;
    }

    /// Uniform in [0, 1) from two draws (53 bits).
    pub fn unit(self: *Mt19937) f64 {
        const low: u64 = self.next() >> 5;
        const high: u64 = self.next() >> 6;
        return @as(f64, @floatFromInt(low * 67108864 + high)) / 9007199254740992.0;
    }
};

/// Codebook reveal order of a frame: Fisher-Yates over the codebooks with
/// raw generator outputs, j = r mod (i + 1) for i = 11 down to 1.
pub fn frameOrder(rng: *Mt19937) [CODEBOOKS]u8 {
    var order: [CODEBOOKS]u8 = undefined;
    for (&order, 0..) |*value, i| value.* = @intCast(i);
    var i: usize = CODEBOOKS - 1;
    while (i > 0) : (i -= 1) {
        const j = rng.next() % @as(u32, @intCast(i + 1));
        const swap = order[i];
        order[i] = order[j];
        order[j] = swap;
    }
    return order;
}

pub const Sampling = struct {
    /// 0 picks the best code (greedy).
    temperature: f32,
    top_k: u32,
    penalty: f32,
    penalty_window: u32,
    seed: u32,
};

pub fn modelSampling(plan: *const Plan, seed: u32) Sampling {
    return .{ .temperature = plan.temperature, .top_k = plan.top_k, .penalty = plan.penalty, .penalty_window = plan.penalty_window, .seed = seed };
}

/// What one frame step produced: twelve codes, or the end of the audio.
pub const Frame = struct {
    codes: [CODEBOOKS]i32,
    end: bool,
};

/// The per-utterance sampler: generator, settings and the codes so far.
pub fn Speaker(comptime limits: Limits) type {
    return struct {
        const Self = @This();
        sampling: Sampling,
        rng: Mt19937,
        history: [limits.history][CODEBOOKS]u16 = undefined,
        frames: usize = 0,

        pub fn init(sampling: Sampling) Self {
            return .{ .sampling = sampling, .rng = Mt19937.init(sampling.seed) };
        }

        /// One audio frame from the text model's output-normed hidden state.
        pub fn frame(
            self: *Self,
            comptime tensor_capacity: usize,
            source: gguf.Source,
            index: *const gguf.Index(tensor_capacity),
            plan: *const Plan,
            work: *DepthWorkspace(limits),
            hidden_state: []const f32,
            parallel: Parallel,
        ) Error!Frame {
            const order = frameOrder(&self.rng);
            var codes: [CODEBOOKS]i32 = @splat(-1);
            try projectState(tensor_capacity, limits, source, index, plan, work, hidden_state, parallel);
            var revealed: usize = 0;
            for (SCHEDULE) |count| {
                try codePass(tensor_capacity, limits, source, index, plan, work, &codes, parallel);
                for (0..count) |_| {
                    const book: usize = order[revealed];
                    revealed += 1;
                    const logits = work.logits[book * plan.vocabulary ..][0..plan.vocabulary];
                    self.penalize(logits, book);
                    codes[book] = @intCast(self.pick(logits));
                }
            }
            const end_code = plan.endCode();
            for (codes) |code| if (code == end_code) return .{ .codes = @splat(end_code), .end = true };
            if (self.frames < limits.history) {
                for (&self.history[self.frames], codes) |*slot, code| slot.* = @intCast(code);
            } else {
                // Keep the newest `history` frames.
                for (0..limits.history - 1) |i| self.history[i] = self.history[i + 1];
                for (&self.history[limits.history - 1], codes) |*slot, code| slot.* = @intCast(code);
            }
            self.frames += 1;
            return .{ .codes = codes, .end = false };
        }

        /// CTRL penalty over the distinct codes this codebook took in the last
        /// `penalty_window` frames.
        pub fn penalize(self: *const Self, logits: []f32, book: usize) void {
            const penalty = self.sampling.penalty;
            if (penalty <= 1.0 or self.sampling.penalty_window == 0) return;
            const kept = @min(self.frames, limits.history);
            const count = @min(kept, self.sampling.penalty_window);
            var seen: [4096]bool = undefined;
            const vocabulary = @min(logits.len, seen.len);
            @memset(seen[0..vocabulary], false);
            for (kept - count..kept) |f| {
                const code: usize = self.history[f][book];
                if (code < vocabulary and !seen[code]) {
                    seen[code] = true;
                    logits[code] = if (logits[code] > 0) logits[code] / penalty else logits[code] * penalty;
                }
            }
        }

        /// Greedy at temperature 0; else top-k (ties kept) then a draw.
        pub fn pick(self: *Self, logits: []const f32) usize {
            var best: usize = 0;
            for (logits, 0..) |value, code| {
                if (value > logits[best]) best = code;
            }
            const temperature = self.sampling.temperature;
            if (temperature <= 0) return best;
            var floor = ops.NEGATIVE_INFINITY;
            const k = self.sampling.top_k;
            if (k > 0 and k < logits.len) floor = kthLargest(logits, k);
            const maximum = logits[best];
            var total: f64 = 0;
            for (logits) |value| {
                if (value >= floor) total += @exp(@as(f64, value - maximum) / temperature);
            }
            var remaining = self.rng.unit() * total;
            for (logits, 0..) |value, code| {
                if (value < floor) continue;
                remaining -= @exp(@as(f64, value - maximum) / temperature);
                if (remaining <= 0) return code;
            }
            return logits.len - 1;
        }
    };
}

/// The k-th largest value (k >= 1) by insertion into a bounded copy; k above
/// 256 is treated as 256 (LFM3-Audio's checkpoint uses 128).
fn kthLargest(values: []const f32, k: u32) f32 {
    var top: [256]f32 = undefined;
    const keep = @min(@as(usize, k), top.len);
    var count: usize = 0;
    for (values) |value| {
        if (count < keep) {
            var i = count;
            while (i > 0 and top[i - 1] < value) : (i -= 1) top[i] = top[i - 1];
            top[i] = value;
            count += 1;
        } else if (value > top[keep - 1]) {
            var i = keep - 1;
            while (i > 0 and top[i - 1] < value) : (i -= 1) top[i] = top[i - 1];
            top[i] = value;
        }
    }
    return top[keep - 1];
}

// ── Codec decoder ───────────────────────────────────────────────────────────

/// What the codec carries between calls: position, the short-convolution
/// taps and the attention windows of its layers, and the ISTFT overlap.
pub fn CodecState(comptime limits: Limits) type {
    const history = limits.codec_kernel - 1;
    const prefix = CODEC_WINDOW - 1;
    return struct {
        position: usize = 0,
        conv: [limits.codec_layers * history * limits.codec_hidden]f32 = @splat(0),
        keys: [limits.codec_layers * prefix * limits.codec_kv_width]f32 = @splat(0),
        values: [limits.codec_layers * prefix * limits.codec_kv_width]f32 = @splat(0),
        istft: Istft = .{},

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }
    };
}

/// Per-layer slices of a CodecState, sized by the plan.
const CodecWindow = struct {
    position: usize,
    conv: []f32,
    key_rows: []f32,
    value_rows: []f32,
    conv_width: usize,
    kv_width: usize,

    fn conv_state(self: *const CodecWindow, slot: u8) []f32 {
        return self.conv[@as(usize, slot) * self.conv_width ..][0..self.conv_width];
    }
    fn keys(self: *const CodecWindow, slot: u8) []f32 {
        return self.key_rows[@as(usize, slot) * self.kv_width ..][0..self.kv_width];
    }
    fn values(self: *const CodecWindow, slot: u8) []f32 {
        return self.value_rows[@as(usize, slot) * self.kv_width ..][0..self.kv_width];
    }
};

pub fn CodecWorkspace(comptime limits: Limits) type {
    const p = limits.frames * FRAME_STACK;
    const prefix = CODEC_WINDOW - 1;
    if (prefix + p > MAX_KEY_ROW) @compileError("codec frames per call exceed the attention key row");
    const widest = @max(@max(limits.codec_hidden, limits.codec_feed_forward), 256);
    return struct {
        frames: [limits.frames * limits.codec_hidden]f32 = @splat(0),
        fsq: [limits.frames * 256]f32 = @splat(0),
        hidden: [p * limits.codec_hidden]f32 = @splat(0),
        normalized: [p * limits.codec_hidden]f32 = @splat(0),
        mixed: [p * 3 * limits.codec_hidden]f32 = @splat(0),
        mixer: [p * limits.codec_hidden]f32 = @splat(0),
        projected: [p * limits.codec_hidden]f32 = @splat(0),
        query: [p * limits.codec_hidden]f32 = @splat(0),
        keys: [(prefix + p) * limits.codec_kv_width]f32 = @splat(0),
        values: [(prefix + p) * limits.codec_kv_width]f32 = @splat(0),
        gate: [p * limits.codec_heads]f32 = @splat(0),
        ffn_gate: [p * limits.codec_feed_forward]f32 = @splat(0),
        ffn_up: [p * limits.codec_feed_forward]f32 = @splat(0),
        polar: [p * 2 * BINS]f32 = @splat(0),
        activations: [p * widest / ops.QK8_0]ops.Q80Block = @splat(.{}),
        trace: ops.Trace = .{},
    };
}

/// Decode `codes` (frame-major, CODEBOOKS per frame, no end code) that follow
/// what `state` has decoded; appends the PCM samples to `pcm` and returns
/// their count (SAMPLES_PER_FRAME per frame, less the ISTFT's initial trim).
pub fn decode(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const Plan,
    state: *CodecState(limits),
    work: *CodecWorkspace(limits),
    codes: []const i32,
    pcm: []f32,
    parallel: Parallel,
) Error!usize {
    try checkLimits(limits, plan);
    if (codes.len == 0 or codes.len % CODEBOOKS != 0) return error.InvalidInput;
    const count = codes.len / CODEBOOKS;
    if (count > limits.frames) return error.Capacity;
    const positions = count * FRAME_STACK;
    if (pcm.len < positions * HOP) return error.Capacity;
    const c = plan.codec.hidden;
    const levels = plan.levels;
    const codebook = try ops.vector(source, index, plan.fsq_codebook, levels * (plan.vocabulary - 1));
    const fsq_inputs = CODEBOOKS * levels;
    const fsq_w = try ops.vector(source, index, plan.fsq_out_w, fsq_inputs * ops.dimension(index, plan.fsq_out_w, 1));
    const fsq_b = try ops.vector(source, index, plan.fsq_out_b, ops.dimension(index, plan.fsq_out_w, 1));
    const fsq_width = fsq_b.len;
    if (fsq_width > 256) return error.Capacity;
    var quantized_codes: [64]f32 = undefined;
    for (0..count) |f| {
        for (0..CODEBOOKS) |book| {
            const code = codes[f * CODEBOOKS + book];
            if (code < 0 or code >= plan.vocabulary - 1) return error.InvalidInput;
            @memcpy(quantized_codes[book * levels ..][0..levels], codebook[@as(usize, @intCast(code)) * levels ..][0..levels]);
        }
        ops.linearF32(fsq_w, fsq_inputs, quantized_codes[0..fsq_inputs], 1, work.fsq[f * fsq_width ..][0..fsq_width], fsq_b);
    }
    try ops.project(parallel, try ops.matrix(source, index, plan.codec_in_w), work.fsq[0 .. count * fsq_width], count, &work.activations, work.frames[0 .. count * c], try ops.vector(source, index, plan.codec_in_b, c));
    // Nearest upsampling: each frame becomes FRAME_STACK positions.
    for (0..positions) |p| @memcpy(work.hidden[p * c ..][0..c], work.frames[(p / FRAME_STACK) * c ..][0..c]);

    const history = plan.codec.kernel - 1;
    const prefix = CODEC_WINDOW - 1;
    const window = CodecWindow{
        .position = state.position,
        .conv = state.conv[0 .. limits.codec_layers * history * c],
        .key_rows = state.keys[0 .. limits.codec_layers * prefix * plan.codec.kvWidth()],
        .value_rows = state.values[0 .. limits.codec_layers * prefix * plan.codec.kvWidth()],
        .conv_width = history * c,
        .kv_width = prefix * plan.codec.kvWidth(),
    };
    for (plan.codec_layers[0..plan.codec.layer_count]) |*layer| {
        try lfmLayer(source, index, &plan.codec, layer, work, positions, &window, parallel);
    }
    const norm = try ops.vector(source, index, plan.codec_norm, c);
    try normRows(parallel, work.hidden[0 .. positions * c], norm, plan.codec.epsilon, work.normalized[0 .. positions * c]);
    try ops.project(parallel, try ops.matrix(source, index, plan.codec_out_w), work.normalized[0 .. positions * c], positions, &work.activations, work.polar[0 .. positions * 2 * BINS], try ops.vector(source, index, plan.codec_out_b, 2 * BINS));
    work.trace.put("polar_out", null, work.polar[0 .. positions * 2 * BINS]);
    state.position += positions;

    var written: usize = 0;
    var spectrum: [2 * BINS]f32 = undefined;
    for (0..positions) |p| {
        const row = work.polar[p * 2 * BINS ..][0 .. 2 * BINS];
        for (0..BINS) |j| {
            const magnitude = @exp(row[j]);
            spectrum[2 * j] = magnitude * @cos(row[BINS + j]);
            spectrum[2 * j + 1] = magnitude * @sin(row[BINS + j]);
        }
        written += state.istft.frame(&spectrum, pcm[written..]);
    }
    return written;
}

/// The samples the ISTFT still holds after the last frame (the reference's
/// centered padding trimmed off); resets the state for a new utterance.
pub fn finish(comptime limits: Limits, state: *CodecState(limits), pcm: []f32) Error!usize {
    if (pcm.len < (FFT_SIZE - HOP) / 2) return error.Capacity;
    const count = state.istft.flush(pcm);
    state.reset();
    return count;
}

// ── Streaming ISTFT (mtmd_audio_streaming_istft) ────────────────────────────

const istft_sin = istftTrig(true);
const istft_cos = istftTrig(false);

fn istftTrig(comptime sine: bool) [FFT_SIZE]f32 {
    @setEvalBranchQuota(400_000);
    var table: [FFT_SIZE]f32 = undefined;
    for (&table, 0..) |*value, i| {
        const theta: f32 = @floatCast(2.0 * @import("std").math.pi * @as(f64, @floatFromInt(i)) / @as(f64, FFT_SIZE));
        value.* = if (sine) @sin(theta) else @cos(theta);
    }
    return table;
}

const istft_window = blk: {
    @setEvalBranchQuota(400_000);
    var table: [FFT_SIZE]f32 = undefined;
    for (&table, 0..) |*value, i| {
        const angle: f32 = @floatCast(2.0 * @import("std").math.pi * @as(f64, @floatFromInt(i)) / @as(f64, FFT_SIZE));
        value.* = @floatCast(0.5 * (1.0 - @as(f64, @cos(angle))));
    }
    break :blk table;
};

pub const Istft = struct {
    overlap: [FFT_SIZE]f32 = @splat(0),
    window_sum: [FFT_SIZE]f32 = @splat(0),
    padding: usize = (FFT_SIZE - HOP) / 2,
    input: [FFT_SIZE * 8]f32 = @splat(0),
    output: [FFT_SIZE * 8]f32 = @splat(0),

    /// One STFT frame of BINS interleaved complex values: HOP samples less
    /// whatever initial padding is still to be removed.
    pub fn frame(self: *Istft, spectrum: *const [2 * BINS]f32, out: []f32) usize {
        @memcpy(self.input[0 .. 2 * BINS], spectrum);
        for (1..BINS - 1) |j| {
            const mirror = FFT_SIZE - j;
            self.input[2 * mirror] = self.input[2 * j];
            self.input[2 * mirror + 1] = -self.input[2 * j + 1];
        }
        ifft(self.input[0..].ptr, FFT_SIZE, self.output[0..].ptr);
        for (0..FFT_SIZE) |j| {
            self.window_sum[j] += istft_window[j] * istft_window[j];
            self.overlap[j] += self.output[2 * j] * istft_window[j];
        }
        var samples: [HOP]f32 = undefined;
        for (&samples, 0..) |*sample, i| sample.* = if (self.window_sum[i] > 1e-8) self.overlap[i] / self.window_sum[i] else self.overlap[i];
        self.shift(HOP);
        const skip = @min(self.padding, HOP);
        self.padding -= skip;
        @memcpy(out[0 .. HOP - skip], samples[skip..]);
        return HOP - skip;
    }

    /// The overlap beyond the last frame, minus the trailing padding.
    pub fn flush(self: *Istft, out: []f32) usize {
        var written: usize = 0;
        var remaining: usize = FFT_SIZE - HOP;
        var all: [FFT_SIZE - HOP]f32 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, HOP);
            for (0..chunk) |i| all[written + i] = if (self.window_sum[i] > 1e-8) self.overlap[i] / self.window_sum[i] else self.overlap[i];
            self.shift(chunk);
            written += chunk;
            remaining -= chunk;
        }
        const keep = written - @min(written, (FFT_SIZE - HOP) / 2);
        @memcpy(out[0..keep], all[0..keep]);
        return keep;
    }

    fn shift(self: *Istft, count: usize) void {
        for (0..FFT_SIZE - count) |i| {
            self.overlap[i] = self.overlap[i + count];
            self.window_sum[i] = self.window_sum[i + count];
        }
        @memset(self.overlap[FFT_SIZE - count ..], 0);
        @memset(self.window_sum[FFT_SIZE - count ..], 0);
    }
};

/// ggml's fft_impl<true, false>: complex input, 0.5 per radix-2 level and
/// 1/n for the odd remainder's DFT.
fn ifft(in: [*]f32, n: usize, out: [*]f32) void {
    if (n == 1) {
        out[0] = in[0];
        out[1] = in[1];
        return;
    }
    const half = n / 2;
    if (n % 2 == 1) return idft(in, n, out);
    const even = in + n * 2;
    for (0..half) |i| {
        even[2 * i] = in[4 * i];
        even[2 * i + 1] = in[4 * i + 1];
    }
    const even_fft = out + 2 * n;
    ifft(even, half, even_fft);
    const odd = even;
    for (0..half) |i| {
        odd[2 * i] = in[4 * i + 2];
        odd[2 * i + 1] = in[4 * i + 3];
    }
    const odd_fft = even_fft + n;
    ifft(odd, half, odd_fft);
    const step = FFT_SIZE / n;
    for (0..half) |k| {
        const re = istft_cos[k * step];
        const im = istft_sin[k * step];
        const re_odd = odd_fft[2 * k];
        const im_odd = odd_fft[2 * k + 1];
        out[2 * k] = 0.5 * (even_fft[2 * k] + re * re_odd - im * im_odd);
        out[2 * k + 1] = 0.5 * (even_fft[2 * k + 1] + re * im_odd + im * re_odd);
        out[2 * (k + half)] = 0.5 * (even_fft[2 * k] - re * re_odd + im * im_odd);
        out[2 * (k + half) + 1] = 0.5 * (even_fft[2 * k + 1] - re * im_odd - im * re_odd);
    }
}

fn idft(in: [*]const f32, n: usize, out: [*]f32) void {
    const step = FFT_SIZE / n;
    const scale = 1.0 / @as(f32, @floatFromInt(n));
    for (0..n) |k| {
        var re: f32 = 0;
        var im: f32 = 0;
        for (0..n) |j| {
            const index = (k * j * step) % FFT_SIZE;
            const c = istft_cos[index];
            const s = istft_sin[index];
            re += in[2 * j] * c - in[2 * j + 1] * s;
            im += in[2 * j] * s + in[2 * j + 1] * c;
        }
        out[2 * k] = re * scale;
        out[2 * k + 1] = im * scale;
    }
}

const testing = @import("std").testing;

test "MT19937 matches the standard generator" {
    var rng = Mt19937.init(5489);
    try testing.expectEqual(@as(u32, 3499211612), rng.next());
    var skip = Mt19937.init(5489);
    for (0..9999) |_| _ = skip.next();
    // The 10000th output of the default-seeded generator (C++ [rand.predef]).
    try testing.expectEqual(@as(u32, 4123659995), skip.next());
    const value = rng.unit();
    try testing.expect(value >= 0 and value < 1);
}

test "the streaming ISTFT inverts a same-padded STFT" {
    const frames = 10;
    const pad = (FFT_SIZE - HOP) / 2;
    var signal: [frames * HOP]f32 = undefined;
    for (&signal, 0..) |*value, i| {
        const t = @as(f64, @floatFromInt(i)) / SAMPLE_RATE;
        value.* = @floatCast(0.4 * @sin(2 * @import("std").math.pi * 440.0 * t) + 0.2 * @sin(2 * @import("std").math.pi * 1234.5 * t));
    }
    var istft = Istft{};
    var out: [frames * HOP]f32 = undefined;
    var written: usize = 0;
    for (0..frames) |f| {
        // Analysis of padded[f * HOP .. f * HOP + FFT_SIZE) with the same window.
        var spectrum: [2 * BINS]f32 = undefined;
        for (0..BINS) |k| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..FFT_SIZE) |n| {
                const at = @as(isize, @intCast(f * HOP + n)) - pad;
                if (at < 0 or at >= signal.len) continue;
                const x = @as(f64, signal[@intCast(at)]) * istft_window[n];
                const angle = -2.0 * @import("std").math.pi * @as(f64, @floatFromInt(k * n % FFT_SIZE)) / FFT_SIZE;
                re += x * @cos(angle);
                im += x * @sin(angle);
            }
            spectrum[2 * k] = @floatCast(re);
            spectrum[2 * k + 1] = @floatCast(im);
        }
        written += istft.frame(&spectrum, out[written..]);
    }
    written += istft.flush(out[written..]);
    try testing.expectEqual(signal.len, written);
    for (signal, out) |expected, actual| try testing.expect(@abs(expected - actual) < 1e-4);
}
