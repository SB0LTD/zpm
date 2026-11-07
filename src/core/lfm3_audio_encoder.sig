//! LFM3-Audio hearing encoder: log-mel frames to rows of the text model's
//! input embeddings, allocation-free and streaming.
//!
//! The graph is llama.cpp's clip_graph_lfm3a: three stride-2 convolutions
//! (8x fewer positions in time and frequency; full 3x3, then depthwise 3x3 +
//! pointwise, twice; SiLU after each), a linear map of the 16 x 256 features
//! to 768, a causal LFM2 stack (RMSNorm; short convolution or GQA with a
//! 32-position sliding window, per-head RMSNorm and NeoX RoPE; SwiGLU), a
//! final RMSNorm, then LayerNorm -> Linear -> GELU(erf) -> Linear to 2048.
//!
//! The encoder streams like llama.cpp's: `State` carries the left column of
//! each convolution, the short-convolution taps, the last 31 keys and values
//! of each attention layer and the position, so encoding a clip in chunks
//! gives the same rows as encoding it at once. A chunk must hold a multiple
//! of 8 frames except the last one of a clip. All storage is caller-owned.

const gguf = @import("gguf");
const ops = @import("lfm3_audio_ops");

pub const Error = ops.Error;
pub const Parallel = ops.Parallel;
const Ref = ops.Ref;
const NONE = ops.NONE;

pub const MAX_LAYERS: usize = 32;
pub const DOWNSAMPLE: usize = 8;

/// Comptime capacities. `positions` bounds the output rows of one `encode`
/// call (8 * positions mel frames); the rest are model widths.
pub const Limits = struct {
    positions: usize,
    hidden: usize,
    feed_forward: usize,
    query: usize,
    kv_width: usize,
    mels: usize,
    channels: usize,
    projection: usize,
    window: usize,
    kernel: usize,
    layers: usize,
};

pub const lfm3_audio_limits = Limits{
    .positions = 32,
    .hidden = 768,
    .feed_forward = 1792,
    .query = 768,
    .kv_width = 384,
    .mels = 128,
    .channels = 256,
    .projection = 2048,
    .window = 32,
    .kernel = 3,
    .layers = 17,
};

pub const Layer = struct {
    attention: bool = false,
    /// Index among the conv layers or among the attention layers.
    slot: u8 = 0,
    ln1: Ref = NONE,
    ln2: Ref = NONE,
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
    q_norm: Ref = NONE,
    k_norm: Ref = NONE,
};

pub const Plan = struct {
    hidden: usize = 0,
    feed_forward: usize = 0,
    heads: usize = 0,
    kv_heads: usize = 0,
    head_size: usize = 0,
    mels: usize = 0,
    channels: usize = 0,
    projection: usize = 0,
    window: usize = 0,
    kernel: usize = 0,
    epsilon: f32 = 0,
    rope_base: f32 = 1_000_000,
    layer_count: usize = 0,
    conv_layer_count: usize = 0,
    attention_layer_count: usize = 0,
    layers: [MAX_LAYERS]Layer = @splat(.{}),
    conv0_w: Ref = NONE,
    conv0_b: Ref = NONE,
    dw1_w: Ref = NONE,
    dw1_b: Ref = NONE,
    pw1_w: Ref = NONE,
    pw1_b: Ref = NONE,
    dw2_w: Ref = NONE,
    dw2_b: Ref = NONE,
    pw2_w: Ref = NONE,
    pw2_b: Ref = NONE,
    pre_out_w: Ref = NONE,
    pre_out_b: Ref = NONE,
    post_norm: Ref = NONE,
    mm0_w: Ref = NONE,
    mm0_b: Ref = NONE,
    mm1_w: Ref = NONE,
    mm1_b: Ref = NONE,
    mm3_w: Ref = NONE,
    mm3_b: Ref = NONE,

    pub fn kvWidth(self: *const Plan) usize {
        return self.kv_heads * self.head_size;
    }
    /// Features per position entering the linear map: (mels / 8) * channels.
    pub fn features(self: *const Plan) usize {
        return self.mels / DOWNSAMPLE * self.channels;
    }
};

/// Output rows for `frames` mel frames encoded from a clip's start.
pub fn positionsFor(frames: usize) usize {
    return (((frames + 1) / 2 + 1) / 2 + 1) / 2;
}

/// Read the encoder's shape from `clip.audio.*` metadata and find its tensors.
pub fn build(comptime tensor_capacity: usize, source: gguf.Source, index: *const gguf.Index(tensor_capacity), out: *Plan) Error!void {
    out.* = .{};
    out.hidden = try metadataSize(source, "clip.audio.embedding_length");
    out.feed_forward = try metadataSize(source, "clip.audio.feed_forward_length");
    out.layer_count = try metadataSize(source, "clip.audio.block_count");
    out.heads = try metadataSize(source, "clip.audio.attention.head_count");
    out.kv_heads = try metadataSize(source, "clip.audio.attention.head_count_kv");
    out.mels = try metadataSize(source, "clip.audio.num_mel_bins");
    out.window = try metadataSize(source, "clip.audio.window_size");
    out.projection = try metadataSize(source, "clip.audio.projection_dim");
    const epsilon = (gguf.metadataNumber(source, "clip.audio.attention.layer_norm_epsilon") catch return error.InvalidModel) orelse return error.InvalidModel;
    out.epsilon = @floatCast(epsilon);
    if (out.layer_count == 0 or out.layer_count > MAX_LAYERS or out.mels % DOWNSAMPLE != 0 or out.window < 2) return error.InvalidModel;

    out.conv0_w = ops.find(index, "a.conv1d.0.weight");
    out.conv0_b = ops.find(index, "a.conv1d.0.bias");
    out.dw1_w = ops.find(index, "a.conv1d.2.weight");
    out.dw1_b = ops.find(index, "a.conv1d.2.bias");
    out.pw1_w = ops.find(index, "a.conv1d.3.weight");
    out.pw1_b = ops.find(index, "a.conv1d.3.bias");
    out.dw2_w = ops.find(index, "a.conv1d.5.weight");
    out.dw2_b = ops.find(index, "a.conv1d.5.bias");
    out.pw2_w = ops.find(index, "a.conv1d.6.weight");
    out.pw2_b = ops.find(index, "a.conv1d.6.bias");
    out.pre_out_w = ops.find(index, "a.pre_encode.out.weight");
    out.pre_out_b = ops.find(index, "a.pre_encode.out.bias");
    out.post_norm = ops.find(index, "a.post_ln.weight");
    out.mm0_w = ops.find(index, "mm.a.mlp.0.weight");
    out.mm0_b = ops.find(index, "mm.a.mlp.0.bias");
    out.mm1_w = ops.find(index, "mm.a.mlp.1.weight");
    out.mm1_b = ops.find(index, "mm.a.mlp.1.bias");
    out.mm3_w = ops.find(index, "mm.a.mlp.3.weight");
    out.mm3_b = ops.find(index, "mm.a.mlp.3.bias");
    out.channels = ops.dimension(index, out.conv0_w, 3);

    for (out.layers[0..out.layer_count], 0..) |*layer, number| {
        layer.ln1 = ops.findLayer(index, "a.blk.", number, ".ln1.weight");
        layer.ln2 = ops.findLayer(index, "a.blk.", number, ".ln2.weight");
        layer.ffn_gate = ops.findLayer(index, "a.blk.", number, ".ffn_gate.weight");
        layer.ffn_up = ops.findLayer(index, "a.blk.", number, ".ffn_up.weight");
        layer.ffn_down = ops.findLayer(index, "a.blk.", number, ".ffn_down.weight");
        layer.conv_dw = ops.findLayer(index, "a.blk.", number, ".conv_dw.weight");
        if (ops.present(layer.conv_dw)) {
            layer.conv_in = ops.findLayer(index, "a.blk.", number, ".conv_pw1.weight");
            layer.conv_out = ops.findLayer(index, "a.blk.", number, ".conv_pw2.weight");
            layer.slot = @intCast(out.conv_layer_count);
            out.conv_layer_count += 1;
            const kernel = ops.dimension(index, layer.conv_dw, 0);
            if (out.kernel == 0) out.kernel = kernel;
            if (kernel != out.kernel) return error.InvalidModel;
        } else {
            layer.attention = true;
            layer.q = ops.findLayer(index, "a.blk.", number, ".attn_q.weight");
            layer.k = ops.findLayer(index, "a.blk.", number, ".attn_k.weight");
            layer.v = ops.findLayer(index, "a.blk.", number, ".attn_v.weight");
            layer.o = ops.findLayer(index, "a.blk.", number, ".attn_out.weight");
            layer.q_norm = ops.findLayer(index, "a.blk.", number, ".attn_q_norm.weight");
            layer.k_norm = ops.findLayer(index, "a.blk.", number, ".attn_k_norm.weight");
            layer.slot = @intCast(out.attention_layer_count);
            out.attention_layer_count += 1;
            const head_size = ops.dimension(index, layer.q_norm, 0);
            if (out.head_size == 0) out.head_size = head_size;
            if (head_size != out.head_size) return error.InvalidModel;
        }
    }
    if (out.heads == 0 or out.kv_heads == 0 or out.heads % out.kv_heads != 0) return error.InvalidModel;
    if (out.attention_layer_count > 0 and out.head_size * out.heads != out.hidden) return error.InvalidModel;
    try validate(tensor_capacity, source, index, out);
}

fn metadataSize(source: gguf.Source, key: []const u8) Error!usize {
    const value = (gguf.metadataNumber(source, key) catch return error.InvalidModel) orelse return error.InvalidModel;
    if (value < 1 or value > 1 << 24) return error.InvalidModel;
    return @intFromFloat(value);
}

/// Every tensor exists with the shape and type `encode` reads.
fn validate(comptime tensor_capacity: usize, source: gguf.Source, index: *const gguf.Index(tensor_capacity), plan: *const Plan) Error!void {
    const c = plan.channels;
    if (c == 0) return error.InvalidModel;
    _ = try ops.vector(source, index, plan.conv0_w, 9 * c);
    _ = try ops.vector(source, index, plan.conv0_b, c);
    _ = try ops.vector(source, index, plan.dw1_w, 9 * c);
    _ = try ops.vector(source, index, plan.dw1_b, c);
    _ = try ops.vector(source, index, plan.pw1_w, c * c);
    _ = try ops.vector(source, index, plan.pw1_b, c);
    _ = try ops.vector(source, index, plan.dw2_w, 9 * c);
    _ = try ops.vector(source, index, plan.dw2_b, c);
    _ = try ops.vector(source, index, plan.pw2_w, c * c);
    _ = try ops.vector(source, index, plan.pw2_b, c);
    try expectMatrix(source, index, plan.pre_out_w, plan.features(), plan.hidden);
    _ = try ops.vector(source, index, plan.pre_out_b, plan.hidden);
    _ = try ops.vector(source, index, plan.post_norm, plan.hidden);
    _ = try ops.vector(source, index, plan.mm0_w, plan.hidden);
    _ = try ops.vector(source, index, plan.mm0_b, plan.hidden);
    try expectMatrix(source, index, plan.mm1_w, plan.hidden, plan.projection);
    _ = try ops.vector(source, index, plan.mm1_b, plan.projection);
    try expectMatrix(source, index, plan.mm3_w, plan.projection, plan.projection);
    _ = try ops.vector(source, index, plan.mm3_b, plan.projection);
    for (plan.layers[0..plan.layer_count]) |*layer| {
        _ = try ops.vector(source, index, layer.ln1, plan.hidden);
        _ = try ops.vector(source, index, layer.ln2, plan.hidden);
        try expectMatrix(source, index, layer.ffn_gate, plan.hidden, plan.feed_forward);
        try expectMatrix(source, index, layer.ffn_up, plan.hidden, plan.feed_forward);
        try expectMatrix(source, index, layer.ffn_down, plan.feed_forward, plan.hidden);
        if (layer.attention) {
            try expectMatrix(source, index, layer.q, plan.hidden, plan.hidden);
            try expectMatrix(source, index, layer.k, plan.hidden, plan.kvWidth());
            try expectMatrix(source, index, layer.v, plan.hidden, plan.kvWidth());
            try expectMatrix(source, index, layer.o, plan.hidden, plan.hidden);
            _ = try ops.vector(source, index, layer.q_norm, plan.head_size);
            _ = try ops.vector(source, index, layer.k_norm, plan.head_size);
        } else {
            _ = try ops.vector(source, index, layer.conv_dw, plan.kernel * plan.hidden);
            try expectMatrix(source, index, layer.conv_in, plan.hidden, 3 * plan.hidden);
            try expectMatrix(source, index, layer.conv_out, plan.hidden, plan.hidden);
        }
    }
}

fn expectMatrix(source: gguf.Source, index: anytype, reference: Ref, columns: usize, rows: usize) Error!void {
    const view = try ops.matrix(source, index, reference);
    if (view.columns != columns or view.rows != rows) return error.InvalidModel;
}

/// The model fits the comptime capacities.
pub fn checkLimits(comptime limits: Limits, plan: *const Plan) Error!void {
    if (plan.hidden > limits.hidden or plan.feed_forward > limits.feed_forward or plan.heads * plan.head_size > limits.query or
        plan.kvWidth() > limits.kv_width or plan.mels > limits.mels or plan.channels > limits.channels or
        plan.projection > limits.projection or plan.window > limits.window or plan.kernel > limits.kernel or
        plan.layer_count > limits.layers or plan.kernel > ops.MAX_CONV_KERNEL) return error.Capacity;
}

/// What carries over between chunks of one clip. `reset` starts a new clip.
pub fn State(comptime limits: Limits) type {
    return struct {
        position: usize = 0,
        ds0: [limits.mels]f32 = @splat(0),
        ds1: [limits.mels / 2 * limits.channels]f32 = @splat(0),
        ds2: [limits.mels / 4 * limits.channels]f32 = @splat(0),
        conv: [limits.layers * (limits.kernel - 1) * limits.hidden]f32 = @splat(0),
        keys: [limits.layers * (limits.window - 1) * limits.kv_width]f32 = @splat(0),
        values: [limits.layers * (limits.window - 1) * limits.kv_width]f32 = @splat(0),

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }
    };
}

pub fn Workspace(comptime limits: Limits) type {
    const p = limits.positions;
    const c = limits.channels;
    const f = limits.mels;
    const prefix = limits.window - 1;
    const widest = @max(@max(limits.mels / DOWNSAMPLE * c, limits.feed_forward), @max(limits.projection, limits.hidden));
    return struct {
        stage0: [4 * p * (f / 2) * c]f32 = @splat(0),
        depthwise: [2 * p * (f / 4) * c]f32 = @splat(0),
        stage1: [2 * p * (f / 4) * c]f32 = @splat(0),
        stage2: [p * (f / 8) * c]f32 = @splat(0),
        features: [p * (f / 8) * c]f32 = @splat(0),
        hidden: [p * limits.hidden]f32 = @splat(0),
        normalized: [p * limits.hidden]f32 = @splat(0),
        mixed: [p * 3 * limits.hidden]f32 = @splat(0),
        mixer: [p * limits.hidden]f32 = @splat(0),
        projected: [p * limits.hidden]f32 = @splat(0),
        query: [p * limits.query]f32 = @splat(0),
        keys: [(prefix + p) * limits.kv_width]f32 = @splat(0),
        values: [(prefix + p) * limits.kv_width]f32 = @splat(0),
        ffn_gate: [p * limits.feed_forward]f32 = @splat(0),
        ffn_up: [p * limits.feed_forward]f32 = @splat(0),
        wide: [p * limits.projection]f32 = @splat(0),
        activations: [p * widest / ops.QK8_0]ops.Q80Block = @splat(.{}),
        trace: ops.Trace = .{},
    };
}

/// Encode `frames` mel frames (frame-major, `frames.len / plan.mels` of them)
/// that follow whatever `state` has seen; writes one row of `plan.projection`
/// values per output position into `out` and returns the row count.
pub fn encode(
    comptime tensor_capacity: usize,
    comptime limits: Limits,
    source: gguf.Source,
    index: *const gguf.Index(tensor_capacity),
    plan: *const Plan,
    state: *State(limits),
    work: *Workspace(limits),
    frames: []const f32,
    out: []f32,
    parallel: Parallel,
) Error!usize {
    try checkLimits(limits, plan);
    if (frames.len == 0 or frames.len % plan.mels != 0) return error.InvalidInput;
    const count = frames.len / plan.mels;
    if (count > DOWNSAMPLE * limits.positions) return error.Capacity;
    const t1 = (count + 1) / 2;
    const t2 = (t1 + 1) / 2;
    const positions = (t2 + 1) / 2;
    if (out.len < positions * plan.projection) return error.Capacity;
    const c = plan.channels;
    const f0 = plan.mels;

    // Stage 0: full 3x3 conv, 1 -> c channels, stride 2, then SiLU.
    const stage0 = Conv0Task{
        .input = frames,
        .left = state.ds0[0..f0],
        .columns = count,
        .bins = f0,
        .channels = c,
        .weight = try ops.vector(source, index, plan.conv0_w, 9 * c),
        .bias = try ops.vector(source, index, plan.conv0_b, c),
        .output = work.stage0[0 .. t1 * (f0 / 2) * c],
    };
    ops.forRange(parallel, t1, &stage0);
    @memcpy(state.ds0[0..f0], frames[(count - 1) * f0 ..][0..f0]);

    // Stages 1 and 2: depthwise 3x3 stride 2, pointwise c -> c, SiLU.
    try downsample(source, index, plan, parallel, work.stage0[0 .. t1 * (f0 / 2) * c], t1, f0 / 2, state.ds1[0 .. f0 / 2 * c], plan.dw1_w, plan.dw1_b, plan.pw1_w, plan.pw1_b, work.depthwise[0..], work.stage1[0..]);
    try downsample(source, index, plan, parallel, work.stage1[0 .. t2 * (f0 / 4) * c], t2, f0 / 4, state.ds2[0 .. f0 / 4 * c], plan.dw2_w, plan.dw2_b, plan.pw2_w, plan.pw2_b, work.depthwise[0..], work.stage2[0..]);

    work.trace.put("downsample.conv", null, work.stage2[0 .. positions * (f0 / DOWNSAMPLE) * c]);
    // [t][f][c] -> [t][c][f]: ggml flattens frequency fastest.
    const bins = f0 / DOWNSAMPLE;
    const features = bins * c;
    for (0..positions) |t| {
        for (0..bins) |bin| for (0..c) |channel| {
            work.features[t * features + channel * bins + bin] = work.stage2[(t * bins + bin) * c + channel];
        };
    }
    const hidden = plan.hidden;
    try ops.project(parallel, try ops.matrix(source, index, plan.pre_out_w), work.features[0 .. positions * features], positions, &work.activations, work.hidden[0 .. positions * hidden], try ops.vector(source, index, plan.pre_out_b, hidden));
    work.trace.put("downsample.out", null, work.hidden[0 .. positions * hidden]);

    for (plan.layers[0..plan.layer_count], 0..) |*layer, number| {
        try normRows(parallel, work.hidden[0 .. positions * hidden], try ops.vector(source, index, layer.ln1, hidden), plan.epsilon, work.normalized[0 .. positions * hidden]);
        work.trace.put("operator_norm", number, work.normalized[0 .. positions * hidden]);
        if (layer.attention) {
            try attentionBlock(limits, source, index, plan, layer, state, work, positions, parallel);
            work.trace.put("attn_out", number, work.projected[0 .. positions * hidden]);
        } else {
            try convBlock(limits, source, index, plan, layer, state, work, positions, parallel);
            work.trace.put("conv_out_proj", number, work.projected[0 .. positions * hidden]);
        }
        addRows(work.hidden[0 .. positions * hidden], work.projected[0 .. positions * hidden]);
        try normRows(parallel, work.hidden[0 .. positions * hidden], try ops.vector(source, index, layer.ln2, hidden), plan.epsilon, work.normalized[0 .. positions * hidden]);
        work.trace.put("ffn_norm", number, work.normalized[0 .. positions * hidden]);
        try feedForward(source, index, plan, layer, work, positions, parallel);
        work.trace.put("ffn_out", number, work.projected[0 .. positions * hidden]);
        addRows(work.hidden[0 .. positions * hidden], work.projected[0 .. positions * hidden]);
        if (!ops.allFinite(work.hidden[0 .. positions * hidden])) return error.NonFinite;
    }

    // Final RMSNorm, then the projector.
    const post = try ops.vector(source, index, plan.post_norm, hidden);
    const norm_w = try ops.vector(source, index, plan.mm0_w, hidden);
    const norm_b = try ops.vector(source, index, plan.mm0_b, hidden);
    for (0..positions) |t| {
        const row = work.hidden[t * hidden ..][0..hidden];
        const normalized = work.normalized[t * hidden ..][0..hidden];
        ops.rmsNorm(row, post, normalized, plan.epsilon);
        ops.layerNorm(normalized, norm_w, norm_b, row, 1e-5);
    }
    work.trace.put("embedding_norm", null, work.normalized[0 .. positions * hidden]);
    const projection = plan.projection;
    try ops.project(parallel, try ops.matrix(source, index, plan.mm1_w), work.hidden[0 .. positions * hidden], positions, &work.activations, work.wide[0 .. positions * projection], try ops.vector(source, index, plan.mm1_b, projection));
    const gelu = GeluTask{ .values = work.wide[0 .. positions * projection], .width = projection };
    ops.forRange(parallel, positions, &gelu);
    try ops.project(parallel, try ops.matrix(source, index, plan.mm3_w), work.wide[0 .. positions * projection], positions, &work.activations, out[0 .. positions * projection], try ops.vector(source, index, plan.mm3_b, projection));
    state.position += positions;
    return positions;
}

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

fn addRows(hidden: []f32, block: []const f32) void {
    for (hidden, block) |*value, delta| value.* += delta;
}

const GeluTask = struct {
    values: []f32,
    width: usize,

    pub fn run(self: *const GeluTask, first: usize, end: usize) void {
        for (self.values[first * self.width .. end * self.width]) |*value| value.* = ops.geluErf(value.*);
    }
};

/// Full 3x3 convolution of the mel image (one input channel), stride 2 in
/// time and frequency, frequency padded by one on both sides; time column 0
/// is the carried left column and the column past the chunk is zero.
const Conv0Task = struct {
    input: []const f32,
    left: []const f32,
    columns: usize,
    bins: usize,
    channels: usize,
    weight: []const f32,
    bias: []const f32,
    output: []f32,

    fn sample(self: *const Conv0Task, column: usize, bin: isize) f32 {
        if (bin < 0 or bin >= @as(isize, @intCast(self.bins))) return 0;
        const b: usize = @intCast(bin);
        if (column == 0) return self.left[b];
        if (column > self.columns) return 0;
        return self.input[(column - 1) * self.bins + b];
    }

    pub fn run(self: *const Conv0Task, first: usize, end: usize) void {
        const out_bins = self.bins / 2;
        for (first..end) |t| {
            for (0..out_bins) |oh| {
                // ggml_conv_2d builds its im2col in f16 and multiplies it as
                // an f16 matrix: patch and kernel are rounded to f16, the
                // nine exact products summed in f64.
                var patch: [9]f32 = undefined;
                for (0..3) |kh| for (0..3) |kw| {
                    patch[kh * 3 + kw] = ops.roundHalf(self.sample(2 * t + kw, @as(isize, @intCast(2 * oh + kh)) - 1));
                };
                const destination = self.output[(t * out_bins + oh) * self.channels ..][0..self.channels];
                for (destination, 0..) |*value, channel| {
                    const w = self.weight[channel * 9 ..][0..9];
                    var sum: f64 = 0;
                    for (0..9) |tap| sum += ops.roundHalf(w[tap]) * patch[tap];
                    const product: f32 = @floatCast(sum);
                    value.* = ops.silu(product + self.bias[channel]);
                }
            }
        }
    }
};

/// One depthwise (stride 2) + pointwise downsampling stage over `columns`
/// time columns of `bins` x channels, with its carried left column.
fn downsample(
    source: gguf.Source,
    index: anytype,
    plan: *const Plan,
    parallel: Parallel,
    input: []const f32,
    columns: usize,
    bins: usize,
    left: []f32,
    dw_w: Ref,
    dw_b: Ref,
    pw_w: Ref,
    pw_b: Ref,
    depthwise: []f32,
    output: []f32,
) Error!void {
    const c = plan.channels;
    const out_columns = (columns + 1) / 2;
    const out_bins = bins / 2;
    const dw = DepthwiseTask{
        .input = input,
        .left = left,
        .columns = columns,
        .bins = bins,
        .channels = c,
        .weight = try ops.vector(source, index, dw_w, 9 * c),
        .bias = try ops.vector(source, index, dw_b, c),
        .output = depthwise[0 .. out_columns * out_bins * c],
    };
    ops.forRange(parallel, out_columns, &dw);
    @memcpy(left, input[(columns - 1) * bins * c ..][0 .. bins * c]);
    const pw = PointwiseTask{
        .input = depthwise[0 .. out_columns * out_bins * c],
        .channels = c,
        .weight = try ops.vector(source, index, pw_w, c * c),
        .bias = try ops.vector(source, index, pw_b, c),
        .output = output[0 .. out_columns * out_bins * c],
    };
    ops.forRange(parallel, out_columns * out_bins, &pw);
}

const DepthwiseTask = struct {
    input: []const f32,
    left: []const f32,
    columns: usize,
    bins: usize,
    channels: usize,
    weight: []const f32,
    bias: []const f32,
    output: []f32,

    fn column(self: *const DepthwiseTask, index: usize) ?[]const f32 {
        const width = self.bins * self.channels;
        if (index == 0) return self.left[0..width];
        if (index > self.columns) return null;
        return self.input[(index - 1) * width ..][0..width];
    }

    pub fn run(self: *const DepthwiseTask, first: usize, end: usize) void {
        const c = self.channels;
        const out_bins = self.bins / 2;
        for (first..end) |t| {
            for (0..out_bins) |oh| {
                const destination = self.output[(t * out_bins + oh) * c ..][0..c];
                for (destination, 0..) |*value, channel| {
                    const w = self.weight[channel * 9 ..][0..9];
                    var sum: f32 = 0;
                    for (0..3) |kh| {
                        const bin = @as(isize, @intCast(2 * oh + kh)) - 1;
                        if (bin < 0 or bin >= @as(isize, @intCast(self.bins))) continue;
                        for (0..3) |kw| {
                            const values = self.column(2 * t + kw) orelse continue;
                            sum += w[kh * 3 + kw] * values[@as(usize, @intCast(bin)) * c + channel];
                        }
                    }
                    value.* = sum + self.bias[channel];
                }
            }
        }
    }
};

/// One output row per (time, frequency) cell: c -> c channels, bias, SiLU.
const PointwiseTask = struct {
    input: []const f32,
    channels: usize,
    weight: []const f32,
    bias: []const f32,
    output: []f32,

    pub fn run(self: *const PointwiseTask, first: usize, end: usize) void {
        const c = self.channels;
        const Lanes = @Vector(8, f32);
        for (first..end) |cell| {
            const x = self.input[cell * c ..][0..c];
            const destination = self.output[cell * c ..][0..c];
            for (destination, 0..) |*value, out_channel| {
                const w = self.weight[out_channel * c ..][0..c];
                var lanes: Lanes = @splat(0);
                var i: usize = 0;
                while (i + 8 <= c) : (i += 8) lanes = @mulAdd(Lanes, w[i..][0..8].*, x[i..][0..8].*, lanes);
                var sum = @reduce(.Add, lanes);
                while (i < c) : (i += 1) sum += w[i] * x[i];
                value.* = ops.silu(sum + self.bias[out_channel]);
            }
        }
    }
};

fn convBlock(
    comptime limits: Limits,
    source: gguf.Source,
    index: anytype,
    plan: *const Plan,
    layer: *const Layer,
    state: *State(limits),
    work: *Workspace(limits),
    positions: usize,
    parallel: Parallel,
) Error!void {
    const hidden = plan.hidden;
    const history = plan.kernel - 1;
    try ops.project(parallel, try ops.matrix(source, index, layer.conv_in), work.normalized[0 .. positions * hidden], positions, &work.activations, work.mixed[0 .. positions * 3 * hidden], null);
    work.trace.put("conv_in_proj", layer.slot, work.mixed[0 .. positions * 3 * hidden]);
    const task = ConvTask{
        .kernel = plan.kernel,
        .hidden = hidden,
        .taps = try ops.vector(source, index, layer.conv_dw, plan.kernel * hidden),
        .state = state.conv[@as(usize, layer.slot) * history * hidden ..][0 .. history * hidden],
        .mixed = work.mixed[0 .. positions * 3 * hidden],
        .tokens = positions,
        .output = work.mixer[0 .. positions * hidden],
    };
    ops.forRange(parallel, hidden, &task);
    try ops.project(parallel, try ops.matrix(source, index, layer.conv_out), work.mixer[0 .. positions * hidden], positions, &work.activations, work.projected[0 .. positions * hidden], null);
}

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

fn attentionBlock(
    comptime limits: Limits,
    source: gguf.Source,
    index: anytype,
    plan: *const Plan,
    layer: *const Layer,
    state: *State(limits),
    work: *Workspace(limits),
    positions: usize,
    parallel: Parallel,
) Error!void {
    const hidden = plan.hidden;
    const kv = plan.kvWidth();
    const prefix = plan.window - 1;
    const slot: usize = layer.slot;
    const state_keys = state.keys[slot * (limits.window - 1) * limits.kv_width ..][0 .. prefix * kv];
    const state_values = state.values[slot * (limits.window - 1) * limits.kv_width ..][0 .. prefix * kv];
    // Keys and values of [carried window | this chunk].
    @memcpy(work.keys[0 .. prefix * kv], state_keys);
    @memcpy(work.values[0 .. prefix * kv], state_values);
    try quantizeOnce(parallel, work, positions, hidden);
    try ops.linear(parallel, try ops.matrix(source, index, layer.q), &work.activations, positions, work.query[0 .. positions * hidden], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.k), &work.activations, positions, work.keys[prefix * kv ..][0 .. positions * kv], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.v), &work.activations, positions, work.values[prefix * kv ..][0 .. positions * kv], null);
    const prepare = PrepareTask{
        .query = work.query[0 .. positions * hidden],
        .keys = work.keys[prefix * kv ..][0 .. positions * kv],
        .query_norm = try ops.vector(source, index, layer.q_norm, plan.head_size),
        .key_norm = try ops.vector(source, index, layer.k_norm, plan.head_size),
        .heads = plan.heads,
        .kv_heads = plan.kv_heads,
        .head_size = plan.head_size,
        .base = state.position,
        .rope_base = plan.rope_base,
        .epsilon = plan.epsilon,
    };
    ops.forRange(parallel, positions, &prepare);
    const attend = AttendTask(limits.window){
        .query = work.query[0 .. positions * hidden],
        .keys = work.keys[0 .. (prefix + positions) * kv],
        .values = work.values[0 .. (prefix + positions) * kv],
        .heads = plan.heads,
        .kv_heads = plan.kv_heads,
        .head_size = plan.head_size,
        .prefix = prefix,
        .base = state.position,
        .output = work.mixer[0 .. positions * hidden],
    };
    ops.forRange(parallel, positions * plan.heads, &attend);
    // The last `prefix` rows of [window | chunk] are the next chunk's window.
    @memcpy(state_keys, work.keys[positions * kv ..][0 .. prefix * kv]);
    @memcpy(state_values, work.values[positions * kv ..][0 .. prefix * kv]);
    try ops.project(parallel, try ops.matrix(source, index, layer.o), work.mixer[0 .. positions * hidden], positions, &work.activations, work.projected[0 .. positions * hidden], null);
}

fn quantizeOnce(parallel: Parallel, work: anytype, positions: usize, hidden: usize) Error!void {
    try ops.quantizeRows(parallel, work.normalized[0 .. positions * hidden], &work.activations);
}

const PrepareTask = struct {
    query: []f32,
    keys: []f32,
    query_norm: []const f32,
    key_norm: []const f32,
    heads: usize,
    kv_heads: usize,
    head_size: usize,
    base: usize,
    rope_base: f32,
    epsilon: f32,

    pub fn run(self: *const PrepareTask, first: usize, end: usize) void {
        const query_width = self.heads * self.head_size;
        const key_width = self.kv_heads * self.head_size;
        for (first..end) |t| {
            const query = self.query[t * query_width ..][0..query_width];
            const key = self.keys[t * key_width ..][0..key_width];
            for (0..self.heads) |head| {
                const row = query[head * self.head_size ..][0..self.head_size];
                ops.rmsNorm(row, self.query_norm, row, self.epsilon);
            }
            for (0..self.kv_heads) |head| {
                const row = key[head * self.head_size ..][0..self.head_size];
                ops.rmsNorm(row, self.key_norm, row, self.epsilon);
            }
            ops.ropeNeox(query, self.heads, self.head_size, self.base + t, self.rope_base, null);
            ops.ropeNeox(key, self.kv_heads, self.head_size, self.base + t, self.rope_base, null);
        }
    }
};

/// One unit per (position, head): the causal window of `prefix + 1` keys
/// ending at the position, minus keys before the clip's start; keys and
/// values rounded to f16 as llama.cpp's flash attention reads them.
fn AttendTask(comptime window: usize) type {
    return struct {
        query: []const f32,
        keys: []const f32,
        values: []const f32,
        heads: usize,
        kv_heads: usize,
        head_size: usize,
        prefix: usize,
        base: usize,
        output: []f32,

        pub fn run(self: *const @This(), first: usize, end: usize) void {
            var scores: [window]f32 = undefined;
            const width = self.heads * self.head_size;
            const kv_width = self.kv_heads * self.head_size;
            const group = self.heads / self.kv_heads;
            const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(self.head_size)));
            for (first..end) |unit| {
                const t = unit / self.heads;
                const head = unit % self.heads;
                const last = self.prefix + t;
                const earliest = if (self.base < self.prefix) self.prefix - self.base else 0;
                const first_key = @max(t, earliest);
                ops.attendHead(
                    self.query[t * width + head * self.head_size ..][0..self.head_size],
                    self.keys,
                    self.values,
                    kv_width,
                    (head / group) * self.head_size,
                    first_key,
                    last,
                    scale,
                    true,
                    &scores,
                    self.output[t * width + head * self.head_size ..][0..self.head_size],
                );
            }
        }
    };
}

fn feedForward(source: gguf.Source, index: anytype, plan: *const Plan, layer: *const Layer, work: anytype, positions: usize, parallel: Parallel) Error!void {
    const hidden = plan.hidden;
    const ff = plan.feed_forward;
    try ops.quantizeRows(parallel, work.normalized[0 .. positions * hidden], &work.activations);
    try ops.linear(parallel, try ops.matrix(source, index, layer.ffn_gate), &work.activations, positions, work.ffn_gate[0 .. positions * ff], null);
    try ops.linear(parallel, try ops.matrix(source, index, layer.ffn_up), &work.activations, positions, work.ffn_up[0 .. positions * ff], null);
    for (work.ffn_gate[0 .. positions * ff], work.ffn_up[0 .. positions * ff]) |*gate, up| gate.* = ops.silu(gate.*) * up;
    try ops.project(parallel, try ops.matrix(source, index, layer.ffn_down), work.ffn_gate[0 .. positions * ff], positions, &work.activations, work.projected[0 .. positions * hidden], null);
}
