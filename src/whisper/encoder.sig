//! Whisper audio encoder: two padded convolutions followed by pre-norm
//! bidirectional transformer blocks. Mel is channel-major; activations/output
//! are row-major [time,state]. No hidden allocations, shared mutable buffers,
//! or dependency on an external inference runtime.
const std = @import("std");
const model = @import("model.sig");
const kernels = @import("kernels.sig");
const resident = @import("encoder_gpu.sig");
pub const Error = kernels.Error;
pub const MAX_LAYERS: usize = 128;

pub const Stage = enum { conv1, conv2, layer, final };
pub const Observer = struct {
    context: ?*anyopaque,
    observe: *const fn (?*anyopaque, Stage, usize, []const f32, usize, usize) void,
};

pub const Layer = struct {
    attn_norm_w: *const model.Tensor,
    attn_norm_b: *const model.Tensor,
    query_w: *const model.Tensor,
    query_b: *const model.Tensor,
    key_w: *const model.Tensor,
    value_w: *const model.Tensor,
    value_b: *const model.Tensor,
    out_w: *const model.Tensor,
    out_b: *const model.Tensor,
    mlp_norm_w: *const model.Tensor,
    mlp_norm_b: *const model.Tensor,
    fc1_w: *const model.Tensor,
    fc1_b: *const model.Tensor,
    fc2_w: *const model.Tensor,
    fc2_b: *const model.Tensor,
};

pub const Encoder = struct {
    hparams: model.HParams,
    conv1_w: *const model.Tensor,
    conv1_b: *const model.Tensor,
    conv2_w: *const model.Tensor,
    conv2_b: *const model.Tensor,
    positional: *const model.Tensor,
    ln_w: *const model.Tensor,
    ln_b: *const model.Tensor,
    layers: [MAX_LAYERS]Layer = undefined,
    observer: ?Observer = null,

    /// Binding verifies every required tensor before inference can mutate the
    /// caller's workspace. The borrowed model/tensor directory must stay alive.
    pub fn init(m: *const model.Model) Error!Encoder {
        const h = m.hparams;
        if (h.n_audio_ctx == 0 or h.n_audio_state == 0 or h.n_audio_head == 0 or h.n_audio_state % h.n_audio_head != 0 or h.n_audio_layer == 0 or h.n_audio_layer > MAX_LAYERS or h.n_mels == 0) return error.InvalidModel;
        const d = h.n_audio_state;
        var e: Encoder = .{
            .hparams = h,
            .conv1_w = try require(m, "encoder.conv1.weight"),
            .conv1_b = try require(m, "encoder.conv1.bias"),
            .conv2_w = try require(m, "encoder.conv2.weight"),
            .conv2_b = try require(m, "encoder.conv2.bias"),
            .positional = try require(m, "encoder.positional_embedding"),
            .ln_w = try require(m, "encoder.ln_post.weight"),
            .ln_b = try require(m, "encoder.ln_post.bias"),
        };
        try convolutionShape(e.conv1_w, h.n_mels, d);
        try convolutionShape(e.conv2_w, d, d);
        try vectorShape(e.conv1_b, d);
        try vectorShape(e.conv2_b, d);
        try matrixShape(e.positional, d, h.n_audio_ctx);
        try vectorShape(e.ln_w, d);
        try vectorShape(e.ln_b, d);
        for (e.layers[0..h.n_audio_layer], 0..) |*layer, i| {
            layer.* = .{
                .attn_norm_w = try requireLayer(m, i, "attn_ln.weight"),
                .attn_norm_b = try requireLayer(m, i, "attn_ln.bias"),
                .query_w = try requireLayer(m, i, "attn.query.weight"),
                .query_b = try requireLayer(m, i, "attn.query.bias"),
                .key_w = try requireLayer(m, i, "attn.key.weight"),
                .value_w = try requireLayer(m, i, "attn.value.weight"),
                .value_b = try requireLayer(m, i, "attn.value.bias"),
                .out_w = try requireLayer(m, i, "attn.out.weight"),
                .out_b = try requireLayer(m, i, "attn.out.bias"),
                .mlp_norm_w = try requireLayer(m, i, "mlp_ln.weight"),
                .mlp_norm_b = try requireLayer(m, i, "mlp_ln.bias"),
                .fc1_w = try requireLayer(m, i, "mlp.0.weight"),
                .fc1_b = try requireLayer(m, i, "mlp.0.bias"),
                .fc2_w = try requireLayer(m, i, "mlp.2.weight"),
                .fc2_b = try requireLayer(m, i, "mlp.2.bias"),
            };
            inline for (.{ "attn_norm_w", "attn_norm_b", "query_b", "value_b", "out_b", "mlp_norm_w", "mlp_norm_b", "fc2_b" }) |field| try vectorShape(@field(layer, field), d);
            try vectorShape(layer.fc1_b, 4 * d);
            inline for (.{ "query_w", "key_w", "value_w", "out_w" }) |field| try matrixShape(@field(layer, field), d, d);
            try matrixShape(layer.fc1_w, d, 4 * d);
            try matrixShape(layer.fc2_w, 4 * d, d);
        }
        return e;
    }

    /// Exactly 2*n_audio_ctx frames, already normalized and silence-padded by
    /// the frontend. The output borrows workspace and is overwritten next call.
    pub fn encode(self: *const Encoder, mel: []const f32, workspace: *Workspace, engine: *kernels.Engine) Error![]const f32 {
        const h = self.hparams;
        const ctx: usize = h.n_audio_ctx;
        const d: usize = h.n_audio_state;
        const frames = ctx * 2;
        if (mel.len != frames * h.n_mels or workspace.context != ctx or workspace.state != d or workspace.mels != h.n_mels) return error.Shape;
        if (engine.gpu) |gpu| {
            if (engine.resident_encoder and resident.supported(self)) return resident.run(gpu, self, mel, workspace);
        }
        const conv1_columns = workspace.ff[0 .. frames * 3 * h.n_mels];
        try im2col(mel, conv1_columns, frames, h.n_mels, frames, 1, .channel_major);
        try engine.linearFlat(self.conv1_w, self.conv1_b, conv1_columns, workspace.conv, frames, 3 * h.n_mels, d);
        kernels.gelu(workspace.conv);
        self.observe(.conv1, 0, workspace.conv, frames, d);
        const conv2_columns = workspace.ff[0 .. ctx * 3 * d];
        try im2col(workspace.conv, conv2_columns, frames, d, ctx, 2, .row_major);
        try engine.linearFlat(self.conv2_w, self.conv2_b, conv2_columns, workspace.x, ctx, 3 * d, d);
        kernels.gelu(workspace.x);
        self.observe(.conv2, 0, workspace.x, ctx, d);
        for (workspace.x, 0..) |*x, i| x.* += self.positional.value(i);
        const ff = workspace.ff[0 .. ctx * d * 4];
        for (self.layers[0..h.n_audio_layer], 0..) |layer, i| {
            try kernels.layerNorm(workspace.x, workspace.norm, layer.attn_norm_w, layer.attn_norm_b, ctx, 1e-5);
            try engine.linear(layer.query_w, layer.query_b, workspace.norm, workspace.q, ctx);
            try engine.linear(layer.key_w, null, workspace.norm, workspace.k, ctx);
            try engine.linear(layer.value_w, layer.value_b, workspace.norm, workspace.v, ctx);
            try engine.attention(workspace.q, workspace.k, workspace.v, workspace.attended, ctx, ctx, d, h.n_audio_head, workspace.scores, null);
            try engine.linear(layer.out_w, layer.out_b, workspace.attended, workspace.norm, ctx);
            try kernels.addResidual(workspace.x, workspace.norm);
            try kernels.layerNorm(workspace.x, workspace.norm, layer.mlp_norm_w, layer.mlp_norm_b, ctx, 1e-5);
            try engine.linear(layer.fc1_w, layer.fc1_b, workspace.norm, ff, ctx);
            kernels.gelu(ff);
            try engine.linear(layer.fc2_w, layer.fc2_b, ff, workspace.norm, ctx);
            try kernels.addResidual(workspace.x, workspace.norm);
            self.observe(.layer, i, workspace.x, ctx, d);
        }
        try kernels.layerNorm(workspace.x, workspace.norm, self.ln_w, self.ln_b, ctx, 1e-5);
        self.observe(.final, 0, workspace.norm, ctx, d);
        return workspace.norm;
    }

    pub fn observe(self: *const Encoder, stage: Stage, layer: usize, data: []const f32, rows: usize, cols: usize) void {
        if (self.observer) |observer| observer.observe(observer.context, stage, layer, data, rows, cols);
    }
};

pub const Workspace = struct {
    context: usize,
    state: usize,
    mels: usize,
    x: []f32,
    norm: []f32,
    q: []f32,
    k: []f32,
    v: []f32,
    attended: []f32,
    conv: []f32,
    ff: []f32,
    scores: []f32,

    pub fn requiredFloats(h: model.HParams) Error!usize {
        if (h.n_audio_ctx == 0 or h.n_audio_state == 0 or h.n_mels == 0) return error.InvalidModel;
        const tokens = try mul(h.n_audio_ctx, h.n_audio_state);
        const stem = try mul(try mul(h.n_audio_ctx, h.n_mels), 6);
        const ff = @max(try mul(tokens, 4), stem);
        return add(try add(try mul(tokens, 8), ff), try mul(h.n_audio_ctx, h.n_audio_ctx));
    }

    pub fn init(storage: []f32, h: model.HParams) Error!Workspace {
        const required = try requiredFloats(h);
        if (storage.len < required) return error.Capacity;
        const tokens = @as(usize, h.n_audio_ctx) * h.n_audio_state;
        const ff = @max(tokens * 4, @as(usize, h.n_audio_ctx) * h.n_mels * 6);
        var offset: usize = 0;
        return .{
            .context = h.n_audio_ctx, .state = h.n_audio_state, .mels = h.n_mels,
            .x = take(storage, &offset, tokens), .norm = take(storage, &offset, tokens),
            .q = take(storage, &offset, tokens), .k = take(storage, &offset, tokens),
            .v = take(storage, &offset, tokens), .attended = take(storage, &offset, tokens),
            .conv = take(storage, &offset, tokens * 2), .ff = take(storage, &offset, ff),
            .scores = take(storage, &offset, @as(usize, h.n_audio_ctx) * h.n_audio_ctx),
        };
    }
};

pub const Layout = enum { row_major, channel_major };

/// Cross-correlation columns, kernel width3 and symmetric zero padding1.
/// GGML weights flatten as [out,in,kernel]; output rows use [in,kernel].
pub fn im2col(input: []const f32, output: []f32, input_frames: usize, channels: usize, output_frames: usize, stride: usize, layout: Layout) Error!void {
    if (stride == 0 or channels == 0 or input.len != input_frames * channels or output.len != output_frames * channels * 3 or output_frames != (input_frames + stride - 1) / stride) return error.Shape;
    for (0..output_frames) |t| for (0..channels) |c| for (0..3) |kernel| {
        const center = t * stride + kernel;
        const value: f32 = if (center == 0 or center > input_frames) 0 else switch (layout) {
            .row_major => input[(center - 1) * channels + c],
            .channel_major => input[c * input_frames + center - 1],
        };
        output[(t * channels + c) * 3 + kernel] = value;
    };
}

fn require(m: *const model.Model, name: []const u8) Error!*const model.Tensor { return m.find(name) orelse error.MissingTensor; }
fn requireLayer(m: *const model.Model, layer: usize, suffix: []const u8) Error!*const model.Tensor {
    var name: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&name, "encoder.blocks.{d}.{s}", .{ layer, suffix }) catch return error.InvalidModel;
    return require(m, formatted);
}
fn vectorShape(t: *const model.Tensor, elements: usize) Error!void { if (t.elements() != elements) return error.Shape; }
fn matrixShape(t: *const model.Tensor, in_dim: usize, out_dim: usize) Error!void {
    if (t.rank != 2 or t.dimensions[0] != in_dim or t.dimensions[1] != out_dim) return error.Shape;
}
fn convolutionShape(t: *const model.Tensor, in_dim: usize, out_dim: usize) Error!void {
    if (t.rank != 3 or t.dimensions[0] != 3 or t.dimensions[1] != in_dim or t.dimensions[2] != out_dim) return error.Shape;
}
fn take(storage: []f32, offset: *usize, size: usize) []f32 { const result = storage[offset.*..][0..size]; offset.* += size; return result; }
fn mul(a: usize, b: usize) Error!usize { const r = @mulWithOverflow(a, b); if (r[1] != 0) return error.Capacity; return r[0]; }
fn add(a: usize, b: usize) Error!usize { const r = @addWithOverflow(a, b); if (r[1] != 0) return error.Capacity; return r[0]; }

test "Whisper convolution columns preserve channel order stride and padding" {
    var columns: [18]f32 = undefined;
    try im2col(&.{ 1, 2, 3, 10, 20, 30 }, &columns, 3, 2, 3, 1, .channel_major);
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 0, 10, 20, 1, 2, 3, 10, 20, 30, 2, 3, 0, 20, 30, 0 }, &columns);
    var stride: [12]f32 = undefined;
    try im2col(&.{ 1, 10, 2, 20, 3, 30, 4, 40 }, &stride, 4, 2, 2, 2, .row_major);
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 0, 10, 20, 2, 3, 4, 20, 30, 40 }, &stride);
}
