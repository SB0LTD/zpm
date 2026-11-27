//! Incremental Whisper text decoder. All weights, work and KV storage are
//! borrowed. Cross-attention projections are computed once per audio window.
//! A failed operation invalidates the session; prepare() starts a new session.
const std = @import("std");
const model = @import("model.sig");
const kernels = @import("kernels.sig");

pub const Error = kernels.Error || error{ ContextCapacity, InvalidToken, NotPrepared, AliasedBuffers, EmptyPrefix };
pub const MAX_LAYERS: usize = 32;
pub const PREFILL_BATCH: usize = 64;

const Norm = struct { weight: *const model.Tensor, bias: *const model.Tensor };
const Linear = struct { weight: *const model.Tensor, bias: ?*const model.Tensor };
const Layer = struct {
    self_norm: Norm, self_q: Linear, self_k: Linear, self_v: Linear, self_out: Linear,
    cross_norm: Norm, cross_q: Linear, cross_k: Linear, cross_v: Linear, cross_out: Linear,
    mlp_norm: Norm, mlp_up: Linear, mlp_down: Linear,
};

pub const Workspace = struct {
    storage: []f32,
    state: []f32, norm: []f32, q: []f32, k: []f32, v: []f32,
    attention: []f32, projected: []f32, feed_forward: []f32,
    self_keys: []f32, self_values: []f32, cross_keys: []f32, cross_values: []f32,
    scores: []f32, logits: []f32,
    batch_state: []f32, batch_norm: []f32, batch_q: []f32, batch_k: []f32, batch_v: []f32,
    batch_attention: []f32, batch_projected: []f32, batch_feed_forward: []f32, batch_scores: []f32,
    batch_capacity: usize,
    state_dim: usize, text_context: usize, audio_context: usize, layers: usize,

    pub fn requiredFloats(h: model.HParams) Error!usize {
        try validHeader(h);
        const s: usize = h.n_text_state;
        return 11 * s + @as(usize, h.n_text_layer) * s *
            (2 * @as(usize, h.n_text_ctx) + 2 * @as(usize, h.n_audio_ctx)) +
            @max(h.n_text_ctx, h.n_audio_ctx) + h.n_vocab +
            @min(PREFILL_BATCH, @as(usize, h.n_text_ctx)) * (11 * s + @max(h.n_text_ctx, h.n_audio_ctx));
    }

    pub fn init(storage: []f32, h: model.HParams) Error!Workspace {
        const required = try requiredFloats(h);
        if (storage.len < required) return error.Capacity;
        var cursor: usize = 0;
        const s: usize = h.n_text_state;
        const self_count = @as(usize, h.n_text_layer) * h.n_text_ctx * s;
        const cross_count = @as(usize, h.n_text_layer) * h.n_audio_ctx * s;
        const capacity = @min(PREFILL_BATCH, @as(usize, h.n_text_ctx));
        const batch_count = capacity * s;
        return .{
            .storage = storage[0..required],
            .state = take(storage, &cursor, s), .norm = take(storage, &cursor, s),
            .q = take(storage, &cursor, s), .k = take(storage, &cursor, s),
            .v = take(storage, &cursor, s), .attention = take(storage, &cursor, s),
            .projected = take(storage, &cursor, s), .feed_forward = take(storage, &cursor, 4 * s),
            .self_keys = take(storage, &cursor, self_count), .self_values = take(storage, &cursor, self_count),
            .cross_keys = take(storage, &cursor, cross_count), .cross_values = take(storage, &cursor, cross_count),
            .scores = take(storage, &cursor, @max(h.n_text_ctx, h.n_audio_ctx)),
            .logits = take(storage, &cursor, h.n_vocab),
            .batch_state = take(storage, &cursor, batch_count), .batch_norm = take(storage, &cursor, batch_count),
            .batch_q = take(storage, &cursor, batch_count), .batch_k = take(storage, &cursor, batch_count),
            .batch_v = take(storage, &cursor, batch_count), .batch_attention = take(storage, &cursor, batch_count),
            .batch_projected = take(storage, &cursor, batch_count), .batch_feed_forward = take(storage, &cursor, batch_count * 4),
            .batch_scores = take(storage, &cursor, capacity * @max(h.n_text_ctx, h.n_audio_ctx)),
            .batch_capacity = capacity,
            .state_dim = s, .text_context = h.n_text_ctx, .audio_context = h.n_audio_ctx,
            .layers = h.n_text_layer,
        };
    }
};

fn take(storage: []f32, cursor: *usize, count: usize) []f32 {
    const result = storage[cursor.*..][0..count];
    cursor.* += count;
    return result;
}

pub const Decoder = struct {
    hparams: model.HParams,
    embedding: *const model.Tensor,
    positional: *const model.Tensor,
    final_norm: Norm,
    layers: [MAX_LAYERS]Layer,
    position: usize = 0,
    prepared: bool = false,
    /// GGML Whisper stores projected K/V in F16 even for F32 models. Rounding
    /// scaled keys here retains that cache precision without half arithmetic.
    round_kv_f16: bool = true,
    /// Explicit opt-in mirror in caller-owned CUDA memory. Keep the pointer
    /// stable from prepare through the final step. Host/batched reference paths
    /// remain available by leaving this null.
    gpu_kv: ?*kernels.DecoderKv = null,
    active_gpu_kv: ?*kernels.DecoderKv = null,

    pub fn init(m: *const model.Model) Error!Decoder {
        const h = m.hparams;
        try validHeader(h);
        var result: Decoder = .{
            .hparams = h,
            .embedding = try tensor(m, "decoder.token_embedding.weight", &.{ h.n_text_state, h.n_vocab }),
            .positional = try tensor(m, "decoder.positional_embedding", &.{ h.n_text_state, h.n_text_ctx }),
            .final_norm = try norm(m, "decoder.ln", h.n_text_state),
            .layers = undefined,
        };
        var name_buf: [128]u8 = undefined;
        for (result.layers[0..h.n_text_layer], 0..) |*layer, index| {
            const prefix = std.fmt.bufPrint(&name_buf, "decoder.blocks.{d}", .{index}) catch return error.InvalidModel;
            layer.* = .{
                .self_norm = try blockNorm(m, prefix, "attn_ln", h.n_text_state),
                .self_q = try blockLinear(m, prefix, "attn.query", h.n_text_state, h.n_text_state, true),
                .self_k = try blockLinear(m, prefix, "attn.key", h.n_text_state, h.n_text_state, false),
                .self_v = try blockLinear(m, prefix, "attn.value", h.n_text_state, h.n_text_state, true),
                .self_out = try blockLinear(m, prefix, "attn.out", h.n_text_state, h.n_text_state, true),
                .cross_norm = try blockNorm(m, prefix, "cross_attn_ln", h.n_text_state),
                .cross_q = try blockLinear(m, prefix, "cross_attn.query", h.n_text_state, h.n_text_state, true),
                .cross_k = try blockLinear(m, prefix, "cross_attn.key", h.n_audio_state, h.n_text_state, false),
                .cross_v = try blockLinear(m, prefix, "cross_attn.value", h.n_audio_state, h.n_text_state, true),
                .cross_out = try blockLinear(m, prefix, "cross_attn.out", h.n_text_state, h.n_text_state, true),
                .mlp_norm = try blockNorm(m, prefix, "mlp_ln", h.n_text_state),
                .mlp_up = try blockLinear(m, prefix, "mlp.0", h.n_text_state, 4 * h.n_text_state, true),
                .mlp_down = try blockLinear(m, prefix, "mlp.2", 4 * h.n_text_state, h.n_text_state, true),
            };
        }
        return result;
    }

    /// encoded is [audio_context,state] row-major. It cannot overlap workspace.
    pub fn prepare(self: *Decoder, encoded: []const f32, work: *Workspace, engine: *kernels.Engine) Error!void {
        self.prepared = false;
        self.position = 0;
        try self.checkWorkspace(work);
        try self.checkGpuKv(engine);
        self.active_gpu_kv = self.gpu_kv;
        if (self.gpu_kv) |cache| cache.reset();
        const h = self.hparams;
        const count = @as(usize, h.n_audio_ctx) * h.n_text_state;
        if (encoded.len != count) return error.Shape;
        if (overlaps(encoded, work.storage)) return error.AliasedBuffers;
        for (self.layers[0..h.n_text_layer], 0..) |layer, index| {
            const keys = work.cross_keys[index * count..][0..count];
            const values = work.cross_values[index * count..][0..count];
            try engine.linear(layer.cross_k.weight, null, encoded, keys, h.n_audio_ctx);
            try engine.linear(layer.cross_v.weight, layer.cross_v.bias, encoded, values, h.n_audio_ctx);
            if (self.round_kv_f16) roundCache(keys, values, h.n_text_state / h.n_text_head);
            if (self.gpu_kv) |cache| try cache.uploadCross(index, keys, values, engine.gpu.?, engine.scratch);
        }
        self.prepared = true;
    }

    /// Consume a known prefix in causal batches, computing vocabulary logits
    /// only for its final token. Cross-attention projections stay prepared.
    /// IDs/context are validated before KV/state mutation; an execution error
    /// invalidates the session just as step() does. No per-call allocation.
    pub fn prefill(self: *Decoder, ids: []const u32, work: *Workspace, engine: *kernels.Engine) Error![]const f32 {
        if (!self.prepared) return error.NotPrepared;
        try self.checkWorkspace(work);
        try self.checkGpuKv(engine);
        if (ids.len == 0) return error.EmptyPrefix;
        if (ids.len > @as(usize, self.hparams.n_text_ctx) - self.position) return error.ContextCapacity;
        for (ids) |id| if (id >= self.hparams.n_vocab) return error.InvalidToken;
        errdefer self.prepared = false;
        var offset: usize = 0;
        while (offset < ids.len) {
            const count = @min(work.batch_capacity, ids.len - offset);
            const last = offset + count == ids.len;
            if (count == 1) {
                _ = try self.step(ids[offset], last, work, engine);
            } else {
                try self.batch(ids[offset..][0..count], last, work, engine);
            }
            offset += count;
        }
        return work.logits;
    }

    fn batch(self: *Decoder, ids: []const u32, compute_logits: bool, work: *Workspace, engine: *kernels.Engine) Error!void {
        const h = self.hparams;
        const s: usize = h.n_text_state;
        const rows = ids.len;
        const count = rows * s;
        const p = self.position;
        const state = work.batch_state[0..count];
        const normalized = work.batch_norm[0..count];
        const queries = work.batch_q[0..count];
        const keys_new = work.batch_k[0..count];
        const values_new = work.batch_v[0..count];
        const attended = work.batch_attention[0..count];
        const projected = work.batch_projected[0..count];
        const feed_forward = work.batch_feed_forward[0 .. count * 4];
        for (ids, 0..) |id, row| {
            for (0..s) |channel| state[row * s + channel] = self.embedding.value(@as(usize, id) * s + channel) + self.positional.value((p + row) * s + channel);
        }
        for (self.layers[0..h.n_text_layer], 0..) |layer, index| {
            try kernels.layerNorm(state, normalized, layer.self_norm.weight, layer.self_norm.bias, rows, 1e-5);
            try engine.linear(layer.self_q.weight, layer.self_q.bias, normalized, queries, rows);
            try engine.linear(layer.self_k.weight, layer.self_k.bias, normalized, keys_new, rows);
            try engine.linear(layer.self_v.weight, layer.self_v.bias, normalized, values_new, rows);
            if (self.round_kv_f16) roundCache(keys_new, values_new, h.n_text_state / h.n_text_head);
            const cache_start = index * @as(usize, h.n_text_ctx) * s;
            @memcpy(work.self_keys[cache_start + p * s..][0..count], keys_new);
            @memcpy(work.self_values[cache_start + p * s..][0..count], values_new);
            if (self.gpu_kv) |cache| try cache.appendSelf(index, p, keys_new, values_new, engine.gpu.?, engine.scratch);
            const keys = work.self_keys[cache_start..][0 .. (p + rows) * s];
            const values = work.self_values[cache_start..][0 .. (p + rows) * s];
            try engine.attention(queries, keys, values, attended, rows, p + rows, s, h.n_text_head, work.batch_scores, p);
            try engine.linear(layer.self_out.weight, layer.self_out.bias, attended, projected, rows);
            try kernels.addResidual(state, projected);
            try kernels.layerNorm(state, normalized, layer.cross_norm.weight, layer.cross_norm.bias, rows, 1e-5);
            try engine.linear(layer.cross_q.weight, layer.cross_q.bias, normalized, queries, rows);
            const cross_count = @as(usize, h.n_audio_ctx) * s;
            const cross_keys = work.cross_keys[index * cross_count..][0..cross_count];
            const cross_values = work.cross_values[index * cross_count..][0..cross_count];
            try engine.attention(queries, cross_keys, cross_values, attended, rows, h.n_audio_ctx, s, h.n_text_head, work.batch_scores, null);
            try engine.linear(layer.cross_out.weight, layer.cross_out.bias, attended, projected, rows);
            try kernels.addResidual(state, projected);
            try kernels.layerNorm(state, normalized, layer.mlp_norm.weight, layer.mlp_norm.bias, rows, 1e-5);
            try engine.linear(layer.mlp_up.weight, layer.mlp_up.bias, normalized, feed_forward, rows);
            kernels.gelu(feed_forward);
            try engine.linear(layer.mlp_down.weight, layer.mlp_down.bias, feed_forward, projected, rows);
            try kernels.addResidual(state, projected);
        }
        self.position += rows;
        @memcpy(work.state, state[(rows - 1) * s..][0..s]);
        if (compute_logits) {
            try applyNorm(self.final_norm, work.state, work.norm);
            try engine.linear(self.embedding, null, work.norm, work.logits, 1);
        }
    }

    /// Consume one token exactly once. compute_logits=false is useful during
    /// prefix prefill: only the last prefix token requires a vocabulary matmul.
    /// Returned logits borrow workspace and are overwritten by the next step.
    pub fn step(self: *Decoder, id: u32, compute_logits: bool, work: *Workspace, engine: *kernels.Engine) Error!?[]const f32 {
        if (!self.prepared) return error.NotPrepared;
        try self.checkWorkspace(work);
        try self.checkGpuKv(engine);
        const h = self.hparams;
        if (id >= h.n_vocab) return error.InvalidToken;
        if (self.position >= h.n_text_ctx) return error.ContextCapacity;
        errdefer self.prepared = false;
        const s: usize = h.n_text_state;
        const p = self.position;
        for (work.state, 0..) |*value, channel|
            value.* = self.embedding.value(@as(usize, id) * s + channel) + self.positional.value(p * s + channel);

        for (self.layers[0..h.n_text_layer], 0..) |layer, index| {
            try applyNorm(layer.self_norm, work.state, work.norm);
            try project(engine, layer.self_q, work.norm, work.q);
            try project(engine, layer.self_k, work.norm, work.k);
            try project(engine, layer.self_v, work.norm, work.v);
            if (self.round_kv_f16) roundCache(work.k, work.v, h.n_text_state / h.n_text_head);
            const cache_start = index * @as(usize, h.n_text_ctx) * s;
            @memcpy(work.self_keys[cache_start + p * s..][0..s], work.k);
            @memcpy(work.self_values[cache_start + p * s..][0..s], work.v);
            if (self.gpu_kv) |cache| try cache.appendSelf(index, p, work.k, work.v, engine.gpu.?, engine.scratch);
            const keys = work.self_keys[cache_start..][0..(p + 1) * s];
            const values = work.self_values[cache_start..][0..(p + 1) * s];
            if (self.gpu_kv) |cache| {
                try cache.attention(index, false, p + 1, work.q, work.attention, engine.gpu.?, engine.scratch);
            } else try engine.attention(work.q, keys, values, work.attention, 1, p + 1, s, h.n_text_head, work.scores, p);
            try project(engine, layer.self_out, work.attention, work.projected);
            try kernels.addResidual(work.state, work.projected);

            try applyNorm(layer.cross_norm, work.state, work.norm);
            try project(engine, layer.cross_q, work.norm, work.q);
            const cross_count = @as(usize, h.n_audio_ctx) * s;
            const cross_keys = work.cross_keys[index * cross_count..][0..cross_count];
            const cross_values = work.cross_values[index * cross_count..][0..cross_count];
            if (self.gpu_kv) |cache| {
                try cache.attention(index, true, h.n_audio_ctx, work.q, work.attention, engine.gpu.?, engine.scratch);
            } else try engine.attention(work.q, cross_keys, cross_values, work.attention, 1, h.n_audio_ctx, s, h.n_text_head, work.scores, null);
            try project(engine, layer.cross_out, work.attention, work.projected);
            try kernels.addResidual(work.state, work.projected);

            try applyNorm(layer.mlp_norm, work.state, work.norm);
            try project(engine, layer.mlp_up, work.norm, work.feed_forward);
            kernels.gelu(work.feed_forward);
            try project(engine, layer.mlp_down, work.feed_forward, work.projected);
            try kernels.addResidual(work.state, work.projected);
        }
        self.position += 1;
        if (!compute_logits) return null;
        try applyNorm(self.final_norm, work.state, work.norm);
        try engine.linear(self.embedding, null, work.norm, work.logits, 1);
        return work.logits;
    }

    fn checkWorkspace(self: *const Decoder, work: *const Workspace) Error!void {
        const h = self.hparams;
        if (work.state_dim != h.n_text_state or work.audio_context != h.n_audio_ctx or
            work.text_context != h.n_text_ctx or work.layers != h.n_text_layer or
            work.logits.len != h.n_vocab or work.batch_capacity == 0 or
            work.batch_capacity > PREFILL_BATCH or work.batch_capacity > h.n_text_ctx) return error.Shape;
    }

    fn checkGpuKv(self: *const Decoder, engine: *const kernels.Engine) Error!void {
        if (self.prepared and self.active_gpu_kv != self.gpu_kv) return error.NotPrepared;
        if (self.gpu_kv) |cache| {
            const h = self.hparams;
            if (cache.layers != h.n_text_layer or cache.text_context != h.n_text_ctx or
                cache.audio_context != h.n_audio_ctx or cache.state != h.n_text_state or cache.heads != h.n_text_head) return error.Shape;
            if (engine.attention_precision != .f16) return error.UnsupportedTensor;
            try cache.checkGpu(engine.gpu orelse return error.GpuUnavailable);
        }
    }
};

fn roundCache(keys: []f32, values: []f32, head_dim: usize) void {
    const scale = 1 / @sqrt(@sqrt(@as(f32, @floatFromInt(head_dim))));
    for (keys) |*key| key.* = @as(f32, @floatCast(@as(f16, @floatCast(key.* * scale)))) / scale;
    for (values) |*value| value.* = @floatCast(@as(f16, @floatCast(value.*)));
}

fn applyNorm(n: Norm, input: []const f32, output: []f32) Error!void {
    try kernels.layerNorm(input, output, n.weight, n.bias, 1, 1e-5);
}
fn project(engine: *kernels.Engine, p: Linear, input: []const f32, output: []f32) Error!void {
    try engine.linear(p.weight, p.bias, input, output, 1);
}
fn validHeader(h: model.HParams) Error!void {
    if (h.n_text_state == 0 or h.n_text_state > 4096 or h.n_text_state != h.n_audio_state or
        h.n_text_head == 0 or h.n_text_state % h.n_text_head != 0 or
        h.n_text_layer == 0 or h.n_text_layer > MAX_LAYERS or
        h.n_text_ctx == 0 or h.n_text_ctx > 4096 or h.n_audio_ctx == 0 or h.n_audio_ctx > 4096 or
        h.n_vocab == 0 or h.n_vocab > 52000) return error.InvalidModel;
}
fn tensor(m: *const model.Model, name: []const u8, shape: []const u32) Error!*const model.Tensor {
    const result = m.find(name) orelse return error.MissingTensor;
    if (result.rank != shape.len) return error.Shape;
    for (shape, 0..) |dimension, axis| if (result.dimensions[axis] != dimension) return error.Shape;
    return result;
}
fn norm(m: *const model.Model, prefix: []const u8, s: u32) Error!Norm {
    var buf: [160]u8 = undefined;
    const w = try tensor(m, std.fmt.bufPrint(&buf, "{s}.weight", .{prefix}) catch return error.InvalidModel, &.{s});
    const b = try tensor(m, std.fmt.bufPrint(&buf, "{s}.bias", .{prefix}) catch return error.InvalidModel, &.{s});
    return .{ .weight = w, .bias = b };
}
fn blockNorm(m: *const model.Model, prefix: []const u8, suffix: []const u8, s: u32) Error!Norm {
    var buf: [160]u8 = undefined;
    return norm(m, std.fmt.bufPrint(&buf, "{s}.{s}", .{prefix, suffix}) catch return error.InvalidModel, s);
}
fn blockLinear(m: *const model.Model, prefix: []const u8, suffix: []const u8, in_dim: u32, out_dim: u32, bias: bool) Error!Linear {
    var buf: [192]u8 = undefined;
    const w = try tensor(m, std.fmt.bufPrint(&buf, "{s}.{s}.weight", .{prefix, suffix}) catch return error.InvalidModel, &.{ in_dim, out_dim });
    const b = if (bias) try tensor(m, std.fmt.bufPrint(&buf, "{s}.{s}.bias", .{prefix, suffix}) catch return error.InvalidModel, &.{out_dim}) else null;
    return .{ .weight = w, .bias = b };
}
fn overlaps(a: []const f32, b: []const f32) bool {
    const aa = @intFromPtr(a.ptr);
    const bb = @intFromPtr(b.ptr);
    return aa < bb + b.len * 4 and bb < aa + a.len * 4;
}
