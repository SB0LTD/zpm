// Native Whisper tensor operations. All host/device storage belongs to callers.
// CPU and CUDA use the same row-major contracts. GPU errors are explicit: an
// accelerator failure never silently produces a partial or zero result.
const std = @import("std");
const model = @import("model.sig");
pub const cuda = @import("../matmul/cuda.sig");

pub const Error = error{ Shape, Capacity, UnsupportedTensor, MissingTensor, GpuUnavailable, GpuFailure, WeightCapacity, InvalidModel, AliasedBuffers };

/// Scratch is conversion space. CPU needs at least one weight row; CUDA F16
/// needs ceil(input.len/2) floats. It may be reused between sequential calls.
pub const Engine = struct {
    scratch: []f32,
    gpu: ?*Gpu = null,
    /// Whisper GGML rounds attention operands to half before each GEMM.
    /// f32 is useful for mathematical/debug references, f16 for model parity.
    attention_precision: enum { f16, f32 } = .f16,
    /// Uses the checked resident encoder when the model fits its explicit
    /// F16 profile. Disable to run the host-observable reference path.
    resident_encoder: bool = true,

    pub fn linear(self: *Engine, weight: *const model.Tensor, bias: ?*const model.Tensor, input: []const f32, output: []f32, rows: usize) Error!void {
        if (weight.rank != 2) return error.Shape;
        return self.linearFlat(weight, bias, input, output, rows, weight.dimensions[0], weight.dimensions[1]);
    }

    /// Also accepts flattened convolution weights [kernel,in,out] in GGML order.
    pub fn linearFlat(self: *Engine, weight: *const model.Tensor, bias: ?*const model.Tensor, input: []const f32, output: []f32, rows: usize, in_dim: usize, out_dim: usize) Error!void {
        if (rows == 0 or in_dim == 0 or out_dim == 0 or weight.elements() != in_dim * out_dim or input.len != rows * in_dim or output.len != rows * out_dim) return error.Shape;
        if (overlaps(input, output) or overlaps(self.scratch, input) or overlaps(self.scratch, output)) return error.AliasedBuffers;
        if (bias) |b| if (b.elements() != out_dim) return error.Shape;
        if (self.gpu) |gpu| {
            try gpu.linear(weight, input, output, rows, in_dim, out_dim, self.scratch);
        } else {
            if (self.scratch.len < in_dim) return error.Capacity;
            const block = @min(out_dim, self.scratch.len / in_dim);
            var first: usize = 0;
            while (first < out_dim) : (first += block) {
                const count = @min(block, out_dim - first);
                for (0..count * in_dim) |j| self.scratch[j] = weight.value(first * in_dim + j);
                for (0..rows) |r| {
                    const a = input[r * in_dim ..][0..in_dim];
                    for (0..count) |c| output[r * out_dim + first + c] = dot(a, self.scratch[c * in_dim ..][0..in_dim]);
                }
            }
        }
        if (bias) |b| {
            for (0..rows) |r| for (0..out_dim) |c| {
                output[r * out_dim + c] += b.value(c);
            };
        }
    }

    /// Q/K/V are [time,state], with contiguous heads inside each row. Scores
    /// holds n_q*n_k floats for the CPU path and is reused for each head.
    /// causal_offset=null is unrestricted; otherwise key<=query+offset.
    pub fn attention(self: *Engine, q: []const f32, k: []const f32, v: []const f32, output: []f32, n_q: usize, n_k: usize, state: usize, heads: usize, scores: []f32, causal_offset: ?usize) Error!void {
        if (n_q == 0 or n_k == 0 or state == 0 or heads == 0 or state % heads != 0 or q.len != n_q * state or k.len != n_k * state or v.len != n_k * state or output.len != q.len) return error.Shape;
        if (overlaps(q, output) or overlaps(k, output) or overlaps(v, output) or overlaps(self.scratch, q) or overlaps(self.scratch, k) or overlaps(self.scratch, v) or overlaps(self.scratch, output) or overlaps(scores, q) or overlaps(scores, k) or overlaps(scores, v) or overlaps(scores, output)) return error.AliasedBuffers;
        if (causal_offset) |offset| if (offset > std.math.maxInt(u32) - n_q) return error.Shape;
        if (self.gpu) |gpu| return gpu.attention(q, k, v, output, n_q, n_k, state, heads, causal_offset, self.scratch, self.attention_precision == .f16);
        if (scores.len < n_q * n_k) return error.Capacity;
        const hd = state / heads;
        const scale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
        @memset(output, 0);
        for (0..heads) |h| {
            for (0..n_q) |qi| {
                const valid = if (causal_offset) |offset| @min(n_k, qi + offset + 1) else n_k;
                const row = scores[qi * n_k ..][0..n_k];
                const query = q[qi * state + h * hd ..][0..hd];
                var largest: f32 = -std.math.inf(f32);
                for (0..valid) |ki| {
                    const key = k[ki * state + h * hd ..][0..hd];
                    var product: f32 = 0;
                    if (self.attention_precision == .f16) {
                        for (query, key) |a, b| product += roundHalf(a) * roundHalf(b);
                    } else product = dot(query, key);
                    row[ki] = product * scale;
                    largest = @max(largest, row[ki]);
                }
                var total: f32 = 0;
                for (row[0..valid]) |*s| {
                    s.* = @exp(s.* - largest);
                    total += s.*;
                }
                const inv = 1.0 / total;
                const dest = output[qi * state + h * hd ..][0..hd];
                for (0..valid) |ki| {
                    const unrounded = row[ki] * inv;
                    const probability = if (self.attention_precision == .f16) roundHalf(unrounded) else unrounded;
                    row[ki] = unrounded;
                    const values = v[ki * state + h * hd ..][0..hd];
                    var d: usize = 0;
                    if (self.attention_precision == .f16) {
                        for (dest, values) |*o, value| o.* += probability * roundHalf(value);
                        continue;
                    }
                    while (d + 8 <= hd) : (d += 8) {
                        const a: @Vector(8, f32) = dest[d..][0..8].*;
                        const b: @Vector(8, f32) = values[d..][0..8].*;
                        dest[d..][0..8].* = a + b * @as(@Vector(8, f32), @splat(probability));
                    }
                    while (d < hd) : (d += 1) dest[d] += probability * values[d];
                }
                @memset(row[valid..], 0);
            }
        }
    }
};

fn roundHalf(value: f32) f32 { return @floatCast(@as(f16, @floatCast(value))); }

fn overlaps(a: []const f32, b: []const f32) bool {
    if (a.len == 0 or b.len == 0) return false;
    const start_a = @intFromPtr(a.ptr);
    const start_b = @intFromPtr(b.ptr);
    return start_a < start_b + b.len * @sizeOf(f32) and start_b < start_a + a.len * @sizeOf(f32);
}

fn dot(a: []const f32, b: []const f32) f32 {
    var sum: @Vector(8, f32) = @splat(0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        const av: @Vector(8, f32) = a[i..][0..8].*;
        const bv: @Vector(8, f32) = b[i..][0..8].*;
        sum += av * bv;
    }
    var result = @reduce(.Add, sum);
    while (i < a.len) : (i += 1) result += a[i] * b[i];
    return result;
}

pub fn layerNorm(input: []const f32, output: []f32, weight: *const model.Tensor, bias: *const model.Tensor, rows: usize, epsilon: f32) Error!void {
    const dim = weight.elements();
    if (rows == 0 or dim == 0 or bias.elements() != dim or input.len != rows * dim or output.len != input.len or epsilon <= 0) return error.Shape;
    for (0..rows) |r| {
        const src = input[r * dim ..][0..dim];
        var mean: f32 = 0;
        for (src) |x| mean += x;
        mean /= @as(f32, @floatFromInt(dim));
        var variance: f32 = 0;
        for (src) |x| variance += (x - mean) * (x - mean);
        const inv = 1.0 / @sqrt(variance / @as(f32, @floatFromInt(dim)) + epsilon);
        for (src, 0..) |x, c| output[r * dim + c] = (x - mean) * inv * weight.value(c) + bias.value(c);
    }
}

pub fn gelu(data: []f32) void {
    for (data) |*x| x.* = 0.5 * x.* * (1.0 + std.math.tanh(0.7978845608028654 * x.* * (1.0 + 0.044715 * x.* * x.*)));
}

pub fn addResidual(output: []f32, residual: []const f32) Error!void {
    if (output.len != residual.len) return error.Shape;
    for (output, residual) |*o, r| o.* += r;
}

pub const CacheEntry = struct { tensor_data: [*]const u8, bytes: usize, device: u64 };

/// Optional caller-owned F16 decoder KV storage. Host KV remains authoritative
/// for batched prefill and inspection. This mirror avoids uploading the entire
/// history for every incremental token. One instance belongs to one sequential
/// decoder session; it must outlive every decoder using it.
pub const DecoderKv = struct {
    device: u64,
    bytes: usize,
    layers: usize,
    text_context: usize,
    audio_context: usize,
    state: usize,
    heads: usize,
    self_keys: usize,
    self_values: usize,
    cross_keys: usize,
    cross_values: usize,
    self_rows: [32]usize = @splat(0),
    cross_ready: [32]bool = @splat(false),

    pub fn requiredBytes(layers: usize, text_context: usize, audio_context: usize, state: usize, heads: usize) Error!usize {
        if (layers == 0 or layers > 32 or text_context == 0 or text_context > 4096 or
            audio_context == 0 or audio_context > 4096 or state == 0 or state > 4096 or
            heads == 0 or state % heads != 0 or state / heads > 128) return error.Shape;
        const self_bytes = std.mem.alignForward(usize, layers * text_context * state * 2, 256);
        const cross_bytes = std.mem.alignForward(usize, layers * audio_context * state * 2, 256);
        return 2 * (self_bytes + cross_bytes);
    }

    pub fn init(device: u64, bytes: usize, layers: usize, text_context: usize, audio_context: usize, state: usize, heads: usize) Error!DecoderKv {
        const required = try requiredBytes(layers, text_context, audio_context, state, heads);
        if (device == 0 or device % 256 != 0) return error.Shape;
        if (bytes < required) return error.Capacity;
        if (@addWithOverflow(device, bytes)[1] != 0) return error.Shape;
        const self_bytes = std.mem.alignForward(usize, layers * text_context * state * 2, 256);
        const cross_bytes = std.mem.alignForward(usize, layers * audio_context * state * 2, 256);
        return .{ .device = device, .bytes = bytes, .layers = layers, .text_context = text_context,
            .audio_context = audio_context, .state = state, .heads = heads,
            .self_keys = 0, .self_values = self_bytes, .cross_keys = self_bytes * 2,
            .cross_values = self_bytes * 2 + cross_bytes };
    }

    pub fn reset(self: *DecoderKv) void {
        self.self_rows = @splat(0);
        self.cross_ready = @splat(false);
    }

    pub fn checkGpu(self: *const DecoderKv, gpu: *const Gpu) Error!void {
        const end = self.device + self.bytes;
        if ((self.device < gpu.arena + gpu.arena_bytes and gpu.arena < end) or
            (self.device < gpu.scratch + gpu.scratch_bytes and gpu.scratch < end)) return error.AliasedBuffers;
    }

    pub fn uploadCross(self: *DecoderKv, layer: usize, keys: []const f32, values: []const f32, gpu: *Gpu, scratch: []f32) Error!void {
        try self.checkGpu(gpu);
        if (layer >= self.layers or keys.len != self.audio_context * self.state or values.len != keys.len) return error.Shape;
        self.cross_ready[layer] = false;
        const offset = layer * self.audio_context * self.state * 2;
        try uploadHalf(self.device + self.cross_keys + offset, keys, scratch);
        try uploadHalf(self.device + self.cross_values + offset, values, scratch);
        self.cross_ready[layer] = true;
    }

    pub fn appendSelf(self: *DecoderKv, layer: usize, position: usize, keys: []const f32, values: []const f32, gpu: *Gpu, scratch: []f32) Error!void {
        try self.checkGpu(gpu);
        if (layer >= self.layers or position > self.text_context or keys.len == 0 or keys.len % self.state != 0 or values.len != keys.len) return error.Shape;
        const rows = keys.len / self.state;
        if (self.self_rows[layer] != position or rows > self.text_context - position) return error.Shape;
        const offset = (layer * self.text_context + position) * self.state * 2;
        // A failed copy makes this layer unusable until reset().
        self.self_rows[layer] = self.text_context + 1;
        try uploadHalf(self.device + self.self_keys + offset, keys, scratch);
        try uploadHalf(self.device + self.self_values + offset, values, scratch);
        self.self_rows[layer] = position + rows;
    }

    pub fn attention(self: *const DecoderKv, layer: usize, cross: bool, count: usize, query: []const f32, output: []f32, gpu: *Gpu, scratch: []f32) Error!void {
        try self.checkGpu(gpu);
        if (layer >= self.layers or count == 0 or query.len != self.state or output.len != self.state) return error.Shape;
        if (overlaps(query, output) or overlaps(scratch, query) or overlaps(scratch, output)) return error.AliasedBuffers;
        if (cross) {
            if (!self.cross_ready[layer] or count != self.audio_context) return error.Shape;
        } else if (self.self_rows[layer] != count or count > self.text_context) return error.Shape;
        const context = if (cross) self.audio_context else self.text_context;
        const offset = layer * context * self.state * 2;
        const kd = self.device + (if (cross) self.cross_keys else self.self_keys) + offset;
        const vd = self.device + (if (cross) self.cross_values else self.self_values) + offset;
        const output_offset = std.mem.alignForward(usize, self.state * 2, 256);
        if (output_offset > gpu.scratch_bytes or self.state * 4 > gpu.scratch_bytes - output_offset) return error.Capacity;
        try uploadHalf(gpu.scratch, query, scratch);
        var qd = gpu.scratch;
        var keys = kd;
        var values = vd;
        var out = gpu.scratch + output_offset;
        var n: u32 = @intCast(count);
        var state: u32 = @intCast(self.state);
        var head_dim: u32 = @intCast(self.state / self.heads);
        var scale: f32 = 1 / @sqrt(@as(f32, @floatFromInt(head_dim)));
        var args = [_]?*anyopaque{ &qd, &keys, &values, &out, &n, &state, &head_dim, &scale };
        if (!cuda.launchKernel(gpu.decoder_attention, @intCast(self.heads), 128, 0, &args) or
            !cuda.downloadFromGpu(output.ptr, out, output.len * 4)) return error.GpuFailure;
    }
};

fn uploadHalf(device: u64, input: []const f32, scratch: []f32) Error!void {
    if (scratch.len < (input.len + 1) / 2) return error.Capacity;
    if (overlaps(input, scratch)) return error.AliasedBuffers;
    const converted: [*]f16 = @ptrCast(scratch.ptr);
    for (input, 0..) |value, i| converted[i] = @floatCast(value);
    if (!cuda.uploadToGpu(device, converted, input.len * 2)) return error.GpuFailure;
}

/// A borrowed CUDA arena and scratch region. Cache entries and arenas must stay
/// alive until all Engine calls finish. A Gpu instance is sequential, not shared
/// concurrently; callers create separate instances for parallel sessions.
pub const Gpu = struct {
    arena: u64,
    arena_bytes: usize,
    used: usize = 0,
    entries: []CacheEntry,
    entry_count: usize = 0,
    scratch: u64,
    scratch_bytes: usize,
    module: cuda.CUmodule,
    softmax: cuda.CUfunction,
    convert: cuda.CUfunction,
    encoder_norm: cuda.CUfunction,
    encoder_element: cuda.CUfunction,
    encoder_columns: cuda.CUfunction,
    encoder_expand: cuda.CUfunction,
    decoder_attention: cuda.CUfunction,
    /// Match GGML's batched F16 CUDA GEMM. Single-token decoder matvecs retain
    /// F32 output. Disable for a higher precision numerical reference.
    round_batched_f16: bool = true,

    pub fn init(arena: u64, arena_bytes: usize, entries: []CacheEntry, scratch: u64, scratch_bytes: usize) Error!Gpu {
        if (!cuda.isAvailable() or cuda.fn_cublasGemmEx == null) return error.GpuUnavailable;
        if (arena == 0 or scratch == 0 or arena_bytes == 0 or scratch_bytes == 0 or entries.len == 0) return error.Capacity;
        if (arena % 256 != 0 or scratch % 256 != 0) return error.Shape;
        const arena_end = @addWithOverflow(arena, arena_bytes);
        const scratch_end = @addWithOverflow(scratch, scratch_bytes);
        if (arena_end[1] != 0 or scratch_end[1] != 0 or (arena < scratch_end[0] and scratch < arena_end[0])) return error.AliasedBuffers;
        const module = cuda.loadModule(softmax_ptx.ptr) orelse return error.GpuFailure;
        errdefer cuda.unloadModule(module);
        const softmax = cuda.getFunction(module, "whisper_softmax") orelse return error.GpuFailure;
        const convert = cuda.getFunction(module, "whisper_half") orelse return error.GpuFailure;
        return .{ .arena = arena, .arena_bytes = arena_bytes, .entries = entries, .scratch = scratch, .scratch_bytes = scratch_bytes, .module = module, .softmax = softmax, .convert = convert,
            .encoder_norm = cuda.getFunction(module, "whisper_encoder_norm") orelse return error.GpuFailure,
            .encoder_element = cuda.getFunction(module, "whisper_encoder_element") orelse return error.GpuFailure,
            .encoder_columns = cuda.getFunction(module, "whisper_encoder_columns") orelse return error.GpuFailure,
            .encoder_expand = cuda.getFunction(module, "whisper_encoder_expand") orelse return error.GpuFailure,
            .decoder_attention = cuda.getFunction(module, "whisper_decoder_attention") orelse return error.GpuFailure,
        };
    }

    pub fn deinit(self: *Gpu) void {
        cuda.unloadModule(self.module);
        self.entry_count = 0;
        self.used = 0;
    }

    pub fn tensor(self: *Gpu, weight: *const model.Tensor) Error!u64 {
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.tensor_data == weight.data.ptr and entry.bytes == weight.data.len) return entry.device;
        }
        const aligned = std.mem.alignForward(usize, self.used, 256);
        if (self.entry_count == self.entries.len or aligned > self.arena_bytes or weight.data.len > self.arena_bytes - aligned) return error.WeightCapacity;
        const device = self.arena + aligned;
        if (!cuda.uploadToGpu(device, weight.data.ptr, weight.data.len)) return error.GpuFailure;
        self.entries[self.entry_count] = .{ .tensor_data = weight.data.ptr, .bytes = weight.data.len, .device = device };
        self.entry_count += 1;
        self.used = aligned + weight.data.len;
        return device;
    }

    fn linear(self: *Gpu, weight: *const model.Tensor, input: []const f32, output: []f32, rows: usize, in_dim: usize, out_dim: usize, host_scratch: []f32) Error!void {
        if (@max(rows, @max(in_dim, out_dim)) > std.math.maxInt(c_int)) return error.Shape;
        const half = weight.encoding == .f16;
        const half_output = half and rows > 1 and self.round_batched_f16;
        const input_bytes = input.len * @as(usize, if (half) 2 else 4);
        const output_offset = std.mem.alignForward(usize, input_bytes, 256);
        const output_bytes = output.len * @as(usize, if (half_output) 2 else 4);
        if (output_offset > self.scratch_bytes or output_bytes > self.scratch_bytes - output_offset) return error.Capacity;
        const a = self.scratch;
        const c = self.scratch + output_offset;
        const w = try self.tensor(weight);
        if (half) {
            if (host_scratch.len * 2 < input.len) return error.Capacity;
            const converted: [*]f16 = @ptrCast(host_scratch.ptr);
            for (input, 0..) |x, i| converted[i] = @floatCast(x);
            if (!cuda.uploadToGpu(a, converted, input_bytes)) return error.GpuFailure;
        } else if (!cuda.uploadToGpu(a, input.ptr, input_bytes)) return error.GpuFailure;
        const alpha: f32 = 1;
        const beta: f32 = 0;
        const alpha_half: f16 = 1;
        const beta_half: f16 = 0;
        // Row-major C[m,n]=A[m,k]W[n,k]^T is Ccm[n,m]=Wcm^T Acm.
        const status = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .T, .N, @intCast(out_dim), @intCast(rows), @intCast(in_dim), if (half_output) @ptrCast(&alpha_half) else @ptrCast(&alpha), @ptrFromInt(w), if (half) 2 else 0, @intCast(in_dim), @ptrFromInt(a), if (half) 2 else 0, @intCast(in_dim), if (half_output) @ptrCast(&beta_half) else @ptrCast(&beta), @ptrFromInt(c), if (half_output) 2 else 0, @intCast(out_dim), if (half_output) 64 else 68, -1);
        if (status != 0) return error.GpuFailure;
        if (half_output) {
            if (host_scratch.len * 2 < output.len) return error.Capacity;
            const converted: [*]f16 = @ptrCast(host_scratch.ptr);
            if (!cuda.downloadFromGpu(converted, c, output_bytes)) return error.GpuFailure;
            for (output, 0..) |*x, i| x.* = @floatCast(converted[i]);
        } else if (!cuda.downloadFromGpu(output.ptr, c, output_bytes)) return error.GpuFailure;
    }

    fn attention(self: *Gpu, q: []const f32, k: []const f32, v: []const f32, output: []f32, n_q: usize, n_k: usize, state: usize, heads: usize, causal_offset: ?usize, host_scratch: []f32, half: bool) Error!void {
        if (@max(state, @max(n_q, n_k)) > std.math.maxInt(c_int)) return error.Shape;
        const element_bytes: usize = if (half) 2 else 4;
        const q_bytes = q.len * element_bytes;
        const kv_bytes = k.len * element_bytes;
        const output_bytes = output.len * 4;
        const score_bytes = n_q * n_k * 4;
        const k_offset = std.mem.alignForward(usize, q_bytes, 256);
        const v_offset = std.mem.alignForward(usize, k_offset + kv_bytes, 256);
        const o_offset = std.mem.alignForward(usize, v_offset + kv_bytes, 256);
        const s_offset = std.mem.alignForward(usize, o_offset + output_bytes, 256);
        const p_offset = std.mem.alignForward(usize, s_offset + score_bytes, 256);
        const total = p_offset + (if (half) score_bytes / 2 else @as(usize, 0));
        if (total > self.scratch_bytes) return error.Capacity;
        const qd = self.scratch;
        const kd = self.scratch + k_offset;
        const vd = self.scratch + v_offset;
        const od = self.scratch + o_offset;
        const sd = self.scratch + s_offset;
        const pd = self.scratch + p_offset;
        if (half) {
            if (host_scratch.len * 2 < @max(q.len, k.len)) return error.Capacity;
            const converted: [*]f16 = @ptrCast(host_scratch.ptr);
            for (q, 0..) |x, i| converted[i] = @floatCast(x);
            if (!cuda.uploadToGpu(qd, converted, q_bytes)) return error.GpuFailure;
            for (k, 0..) |x, i| converted[i] = @floatCast(x);
            if (!cuda.uploadToGpu(kd, converted, kv_bytes)) return error.GpuFailure;
            for (v, 0..) |x, i| converted[i] = @floatCast(x);
            if (!cuda.uploadToGpu(vd, converted, kv_bytes)) return error.GpuFailure;
        } else if (!cuda.uploadToGpu(qd, q.ptr, q_bytes) or !cuda.uploadToGpu(kd, k.ptr, kv_bytes) or !cuda.uploadToGpu(vd, v.ptr, kv_bytes)) return error.GpuFailure;
        const hd = state / heads;
        const scale: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
        const one: f32 = 1;
        const zero: f32 = 0;
        for (0..heads) |h| {
            const head_offset = h * hd * element_bytes;
            const score_status = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .T, .N, @intCast(n_k), @intCast(n_q), @intCast(hd), &scale, @ptrFromInt(kd + head_offset), if (half) 2 else 0, @intCast(state), @ptrFromInt(qd + head_offset), if (half) 2 else 0, @intCast(state), &zero, @ptrFromInt(sd), 0, @intCast(n_k), 68, -1);
            if (score_status != 0) return error.GpuFailure;
            var score_arg: u64 = sd;
            var cols_arg: u32 = @intCast(n_k);
            var rows_arg: u32 = @intCast(n_q);
            var offset_arg: u32 = if (causal_offset) |offset| @intCast(offset) else std.math.maxInt(u32);
            var args = [_]?*anyopaque{ &score_arg, &cols_arg, &rows_arg, &offset_arg };
            if (!cuda.launchKernel(self.softmax, @intCast(n_q), 128, 0, &args)) return error.GpuFailure;
            if (half) {
                var from_arg: u64 = sd;
                var to_arg: u64 = pd;
                var count_arg: u32 = @intCast(n_q * n_k);
                var convert_args = [_]?*anyopaque{ &from_arg, &to_arg, &count_arg };
                if (!cuda.launchKernel(self.convert, @intCast((n_q * n_k + 255) / 256), 256, 0, &convert_args)) return error.GpuFailure;
            }
            // Vcm[head_dim,n_k] times Pcm[n_k,n_q] => Ocm[head_dim,n_q].
            const output_status = cuda.fn_cublasGemmEx.?(cuda.cublas_handle.?, .N, .N, @intCast(hd), @intCast(n_q), @intCast(n_k), &one, @ptrFromInt(vd + head_offset), if (half) 2 else 0, @intCast(state), @ptrFromInt(if (half) pd else sd), if (half) 2 else 0, @intCast(n_k), &zero, @ptrFromInt(od + h * hd * 4), 0, @intCast(state), 68, -1);
            if (output_status != 0) return error.GpuFailure;
        }
        if (!cuda.downloadFromGpu(output.ptr, od, output.len * 4)) return error.GpuFailure;
    }
};

// One block/row, 128-thread shared-memory max/sum reductions. PTX is authored
// here, with no external compiler/runtime or generated CUDA-C production path.
const softmax_ptx =
    \\.version 7.0
    \\.target sm_50
    \\.address_size 64
    ++ "\n" ++ @import("encoder_ptx.sig").source ++ "\n" ++ @import("decoder_ptx.sig").source ++ "\n" ++
    \\.visible .entry whisper_half(.param .u64 source, .param .u64 dest, .param .u32 count) {
    \\ .reg .pred %p;
    \\ .reg .b16 %h;
    \\ .reg .b32 %r<5>;
    \\ .reg .b64 %rd<7>;
    \\ .reg .f32 %f;
    \\ ld.param.u64 %rd0,[source];
    \\ ld.param.u64 %rd1,[dest];
    \\ ld.param.u32 %r0,[count];
    \\ mov.u32 %r1,%ctaid.x;
    \\ mov.u32 %r2,%ntid.x;
    \\ mov.u32 %r3,%tid.x;
    \\ mad.lo.u32 %r4,%r1,%r2,%r3;
    \\ setp.ge.u32 %p,%r4,%r0;
    \\ @%p bra HALF_END;
    \\ mul.wide.u32 %rd2,%r4,4;
    \\ add.u64 %rd3,%rd0,%rd2;
    \\ mul.wide.u32 %rd4,%r4,2;
    \\ add.u64 %rd5,%rd1,%rd4;
    \\ ld.global.f32 %f,[%rd3];
    \\ cvt.rn.f16.f32 %h,%f;
    \\ st.global.b16 [%rd5],%h;
    \\ HALF_END:
    \\ ret;
    \\}
    \\.visible .entry whisper_softmax(.param .u64 scores, .param .u32 columns, .param .u32 rows, .param .u32 offset) {
    \\ .reg .pred %p<8>;
    \\ .reg .b32 %r<20>;
    \\ .reg .b64 %rd<12>;
    \\ .reg .f32 %f<12>;
    \\ .shared .align 4 .b8 reduction[512];
    \\ ld.param.u64 %rd0,[scores];
    \\ ld.param.u32 %r0,[columns];
    \\ ld.param.u32 %r1,[rows];
    \\ ld.param.u32 %r2,[offset];
    \\ mov.u32 %r3,%ctaid.x;
    \\ mov.u32 %r4,%tid.x;
    \\ setp.ge.u32 %p0,%r3,%r1;
    \\ @%p0 bra END;
    \\ mul.wide.u32 %rd1,%r3,%r0;
    \\ shl.b64 %rd1,%rd1,2;
    \\ add.u64 %rd2,%rd0,%rd1;
    \\ mov.u32 %r5,%r0;
    \\ setp.eq.u32 %p1,%r2,0xffffffff;
    \\ @%p1 bra LIMIT;
    \\ add.u32 %r6,%r3,%r2;
    \\ add.u32 %r6,%r6,1;
    \\ min.u32 %r5,%r5,%r6;
    \\ LIMIT:
    \\ mov.f32 %f0,0fFF800000;
    \\ mov.u32 %r7,%r4;
    \\ MAXLOOP:
    \\ setp.ge.u32 %p2,%r7,%r5;
    \\ @%p2 bra MAXDONE;
    \\ mul.wide.u32 %rd3,%r7,4;
    \\ add.u64 %rd4,%rd2,%rd3;
    \\ ld.global.f32 %f1,[%rd4];
    \\ max.f32 %f0,%f0,%f1;
    \\ add.u32 %r7,%r7,128;
    \\ bra MAXLOOP;
    \\ MAXDONE:
    \\ mov.u64 %rd5,reduction;
    \\ mul.wide.u32 %rd6,%r4,4;
    \\ add.u64 %rd7,%rd5,%rd6;
    \\ st.shared.f32 [%rd7],%f0;
    \\ bar.sync 0;
    \\ mov.u32 %r8,64;
    \\ MAXREDUCE:
    \\ setp.ge.u32 %p3,%r4,%r8;
    \\ @%p3 bra MAXSKIP;
    \\ mul.wide.u32 %rd8,%r8,4;
    \\ add.u64 %rd9,%rd7,%rd8;
    \\ ld.shared.f32 %f1,[%rd9];
    \\ max.f32 %f0,%f0,%f1;
    \\ st.shared.f32 [%rd7],%f0;
    \\ MAXSKIP:
    \\ bar.sync 0;
    \\ shr.u32 %r8,%r8,1;
    \\ setp.ne.u32 %p4,%r8,0;
    \\ @%p4 bra MAXREDUCE;
    \\ ld.shared.f32 %f2,[%rd5];
    \\ bar.sync 0;
    \\ mov.f32 %f3,0f00000000;
    \\ mov.u32 %r7,%r4;
    \\ EXPLOOP:
    \\ setp.ge.u32 %p2,%r7,%r0;
    \\ @%p2 bra EXPDONE;
    \\ mul.wide.u32 %rd3,%r7,4;
    \\ add.u64 %rd4,%rd2,%rd3;
    \\ mov.f32 %f4,0f00000000;
    \\ setp.ge.u32 %p5,%r7,%r5;
    \\ @%p5 bra MASKED;
    \\ ld.global.f32 %f4,[%rd4];
    \\ sub.f32 %f4,%f4,%f2;
    \\ mul.f32 %f4,%f4,0f3FB8AA3B;
    \\ ex2.approx.ftz.f32 %f4,%f4;
    \\ MASKED:
    \\ st.global.f32 [%rd4],%f4;
    \\ add.f32 %f3,%f3,%f4;
    \\ add.u32 %r7,%r7,128;
    \\ bra EXPLOOP;
    \\ EXPDONE:
    \\ st.shared.f32 [%rd7],%f3;
    \\ bar.sync 0;
    \\ mov.u32 %r8,64;
    \\ SUMREDUCE:
    \\ setp.ge.u32 %p3,%r4,%r8;
    \\ @%p3 bra SUMSKIP;
    \\ mul.wide.u32 %rd8,%r8,4;
    \\ add.u64 %rd9,%rd7,%rd8;
    \\ ld.shared.f32 %f1,[%rd9];
    \\ add.f32 %f3,%f3,%f1;
    \\ st.shared.f32 [%rd7],%f3;
    \\ SUMSKIP:
    \\ bar.sync 0;
    \\ shr.u32 %r8,%r8,1;
    \\ setp.ne.u32 %p4,%r8,0;
    \\ @%p4 bra SUMREDUCE;
    \\ ld.shared.f32 %f5,[%rd5];
    \\ rcp.approx.ftz.f32 %f5,%f5;
    \\ mov.u32 %r7,%r4;
    \\ DIVLOOP:
    \\ setp.ge.u32 %p2,%r7,%r0;
    \\ @%p2 bra END;
    \\ mul.wide.u32 %rd3,%r7,4;
    \\ add.u64 %rd4,%rd2,%rd3;
    \\ ld.global.f32 %f4,[%rd4];
    \\ mul.f32 %f4,%f4,%f5;
    \\ st.global.f32 [%rd4],%f4;
    \\ add.u32 %r7,%r7,128;
    \\ bra DIVLOOP;
    \\ END:
    \\ ret;
    \\}
;
