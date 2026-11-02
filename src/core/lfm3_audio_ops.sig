//! Shared allocation-free building blocks of the three LFM3-Audio networks in
//! the mmproj GGUF: the hearing encoder, the MaskGIT depthformer and the codec
//! decoder. All three are LFM blocks (RMSNorm, short convolution or GQA with
//! per-head RMSNorm and NeoX RoPE, SwiGLU) over Q8_0 matrices and f32 vectors.
//!
//! Numerics follow ggml's CPU backend as llama.cpp's clip graphs run it:
//! matrix inputs are quantized to Q8_0 once per matrix and multiplied with
//! the integer kernels of quantized_linear; norms sum squares in f64; softmax
//! sums in f64; the encoder's flash attention rounds K and V to f16 (the
//! `half_kv` option). Work is split through the host's `Parallel` dispatcher.

const gguf = @import("gguf");
const quantized = @import("quantized_linear");
const executor = @import("lfm3_executor");
const lfm3 = @import("lfm3_plan");

/// shortConvChannels keeps one window of this many taps on the stack.
pub const MAX_CONV_KERNEL = lfm3.MAX_CONV_KERNEL;

pub const Parallel = executor.Parallel;
pub const Task = executor.Task;
pub const Q80Block = quantized.Q80Block;
pub const QK8_0 = quantized.QK8_0;

pub const Error = quantized.Error || error{
    InvalidModel,
    StorageNotMapped,
    ArithmeticOverflow,
    Capacity,
    InvalidInput,
    NonFinite,
};

pub const NEGATIVE_INFINITY: f32 = @bitCast(@as(u32, 0xff800000));

/// Optional host hook that sees named intermediate rows (the names of
/// llama.cpp's graph callbacks), for layer-by-layer parity checks.
pub const Trace = struct {
    context: ?*anyopaque = null,
    emit: ?*const fn (context: ?*anyopaque, name: []const u8, layer: ?usize, values: []const f32) void = null,

    pub fn put(self: Trace, name: []const u8, layer: ?usize, values: []const f32) void {
        if (self.emit) |emit| emit(self.context, name, layer, values);
    }
};

/// A tensor of the parsed index; NONE when the file has no such tensor.
pub const Ref = u16;
pub const NONE: Ref = 0xffff;

pub fn present(reference: Ref) bool {
    return reference != NONE;
}

pub fn find(index: anytype, name: []const u8) Ref {
    for (index.tensors[0..index.tensor_count], 0..) |*tensor, position| {
        if (eql(tensor.nameSlice(), name)) return @intCast(position);
    }
    return NONE;
}

/// find() of `prefix` ++ decimal(layer) ++ `suffix`.
pub fn findLayer(index: anytype, prefix: []const u8, layer: usize, suffix: []const u8) Ref {
    var buffer: [96]u8 = undefined;
    if (prefix.len + suffix.len + 4 > buffer.len) return NONE;
    @memcpy(buffer[0..prefix.len], prefix);
    var length = prefix.len;
    var digits: [4]u8 = undefined;
    var count: usize = 0;
    var value = layer;
    while (true) {
        digits[count] = @intCast('0' + value % 10);
        count += 1;
        value /= 10;
        if (value == 0 or count == digits.len) break;
    }
    while (count > 0) {
        count -= 1;
        buffer[length] = digits[count];
        length += 1;
    }
    @memcpy(buffer[length..][0..suffix.len], suffix);
    return find(index, buffer[0 .. length + suffix.len]);
}

fn eql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

/// A Q8_0 matrix of `rows` rows of `columns` inputs (every dimension past the
/// first counts as rows: a [n, vocab, books] table is books * vocab rows).
pub const Matrix = struct {
    bytes: []const u8,
    rows: usize,
    columns: usize,
    row_bytes: usize,

    pub fn row(self: Matrix, index: usize) []const u8 {
        return self.bytes[index * self.row_bytes ..][0..self.row_bytes];
    }
};

pub fn matrix(source: gguf.Source, index: anytype, reference: Ref) Error!Matrix {
    if (!present(reference)) return error.InvalidModel;
    const tensor = &index.tensors[reference];
    if (tensor.ggml_type != 8 or tensor.dimension_count < 2) return error.InvalidModel;
    const columns: usize = @intCast(tensor.dimensions[0]);
    if (columns % QK8_0 != 0) return error.InvalidModel;
    var rows: usize = 1;
    for (tensor.dimensions[1..tensor.dimension_count]) |extent| rows = try multiply(rows, @intCast(extent));
    const row_bytes = columns / QK8_0 * quantized.Q8_0_BLOCK_BYTES;
    if (try multiply(rows, row_bytes) != tensor.byte_size) return error.InvalidModel;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), 1) orelse return error.StorageNotMapped;
    return .{ .bytes = bytes, .rows = rows, .columns = columns, .row_bytes = row_bytes };
}

/// An f32 tensor of exactly `elements` values.
pub fn vector(source: gguf.Source, index: anytype, reference: Ref, elements: usize) Error![]const f32 {
    if (!present(reference)) return error.InvalidModel;
    const tensor = &index.tensors[reference];
    if (tensor.ggml_type != 0 or tensor.byte_size != try multiply(elements, 4)) return error.InvalidModel;
    const bytes = source.view(tensor.file_offset, @intCast(tensor.byte_size), @alignOf(f32)) orelse return error.StorageNotMapped;
    const values: [*]const f32 = @ptrCast(@alignCast(bytes.ptr));
    return values[0..elements];
}

pub fn optionalVector(source: gguf.Source, index: anytype, reference: Ref, elements: usize) Error!?[]const f32 {
    if (!present(reference)) return null;
    return try vector(source, index, reference, elements);
}

/// Element count of a tensor's first dimension (0 when absent).
pub fn dimension(index: anytype, reference: Ref, axis: usize) usize {
    if (!present(reference)) return 0;
    const tensor = &index.tensors[reference];
    if (axis >= tensor.dimension_count) return 1;
    return @intCast(tensor.dimensions[axis]);
}

/// Run `context.run(first, end)` over [0, count) through the host dispatcher.
pub fn forRange(parallel: Parallel, count: usize, context: anytype) void {
    const Context = @typeInfo(@TypeOf(context)).pointer.child;
    const Adapter = struct {
        fn execute(raw: *const anyopaque, first: usize, end: usize) void {
            const self: *const Context = @ptrCast(@alignCast(raw));
            self.run(first, end);
        }
    };
    parallel.run(&.{ .context = context, .count = count, .execute = &Adapter.execute });
}

/// Quantize `rows` rows of `width` inputs (width a multiple of 32) to Q8_0.
pub fn quantizeRows(parallel: Parallel, input: []const f32, activations: []Q80Block) Error!void {
    if (input.len % QK8_0 != 0) return error.InvalidInput;
    if (activations.len < input.len / QK8_0) return error.Capacity;
    const task = QuantizeTask{ .input = input, .activations = activations };
    forRange(parallel, input.len / QK8_0, &task);
}

const QuantizeTask = struct {
    input: []const f32,
    activations: []Q80Block,

    fn run(self: *const QuantizeTask, first: usize, end: usize) void {
        quantized.quantizeQ80(self.input[first * QK8_0 .. end * QK8_0], self.activations[first..end]) catch unreachable;
    }
};

/// output[t * rows + r] = W[r] . x[t] (+ bias[r]) for `tokens` quantized rows.
pub fn linear(parallel: Parallel, weights: Matrix, activations: []const Q80Block, tokens: usize, output: []f32, bias: ?[]const f32) Error!void {
    const blocks = weights.columns / QK8_0;
    if (tokens == 0 or output.len < tokens * weights.rows or activations.len < tokens * blocks) return error.Capacity;
    if (bias) |values| if (values.len != weights.rows) return error.InvalidModel;
    const task = MatmulTask{ .weights = weights, .activations = activations, .blocks = blocks, .tokens = tokens, .output = output, .bias = bias };
    forRange(parallel, weights.rows, &task);
    if (!allFinite(output[0 .. tokens * weights.rows])) return error.NonFinite;
}

/// One Q8_0 row as f32 (ggml_get_rows of a Q8_0 table).
pub fn dequantizeRow(row: []const u8, out: []f32) Error!void {
    try quantized.dequantizeQ80(out, row);
}

/// One Q8_0 row against one quantized activation row of the same width.
pub fn dotRow(row: []const u8, activations: []const Q80Block) f32 {
    return quantized.dotQ80Q80Tile(1, row, .{activations.ptr}, activations.len)[0];
}

/// Quantize then multiply: the common pattern of every matrix input.
pub fn project(parallel: Parallel, weights: Matrix, input: []const f32, tokens: usize, activations: []Q80Block, output: []f32, bias: ?[]const f32) Error!void {
    if (input.len < tokens * weights.columns) return error.Capacity;
    try quantizeRows(parallel, input[0 .. tokens * weights.columns], activations);
    try linear(parallel, weights, activations, tokens, output, bias);
}

const MatmulTask = struct {
    weights: Matrix,
    activations: []const Q80Block,
    blocks: usize,
    tokens: usize,
    output: []f32,
    bias: ?[]const f32,

    fn run(self: *const MatmulTask, first: usize, end: usize) void {
        const width = self.weights.rows;
        for (first..end) |row| {
            const bytes = self.weights.row(row);
            const offset: f32 = if (self.bias) |values| values[row] else 0;
            var slot: usize = 0;
            while (slot < self.tokens) {
                const count = @min(self.tokens - slot, quantized.MAX_TILE);
                inline for (1..quantized.MAX_TILE + 1) |tile| {
                    if (count == tile) {
                        var rows: [tile][*]const Q80Block = undefined;
                        inline for (0..tile) |index| rows[index] = self.activations[(slot + index) * self.blocks ..].ptr;
                        const results = quantized.dotQ80Q80Tile(tile, bytes, rows, self.blocks);
                        inline for (0..tile) |index| {
                            self.output[(slot + index) * width + row] = if (self.bias != null) results[index] + offset else results[index];
                        }
                    }
                }
                slot += count;
            }
        }
    }
};

/// output[t * outputs + o] = sum_i W[o * inputs + i] * x[t * inputs + i] + bias[o]
/// for an f32 matrix (ggml_mul_mat of an F32 tensor: f32 products).
pub fn linearF32(weights: []const f32, inputs: usize, input: []const f32, tokens: usize, output: []f32, bias: ?[]const f32) void {
    const outputs = weights.len / inputs;
    for (0..tokens) |token| {
        const x = input[token * inputs ..][0..inputs];
        for (0..outputs) |o| {
            var sum: f32 = 0;
            for (weights[o * inputs ..][0..inputs], x) |w, value| sum += w * value;
            output[token * outputs + o] = if (bias) |values| sum + values[o] else sum;
        }
    }
}

/// RMSNorm of one row as ggml_rms_norm: each square rounded to f32, the
/// squares summed in f64, then x * (1 / sqrt(mean + eps)) * weight.
pub fn rmsNorm(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
    var squares: f64 = 0;
    for (input) |value| squares += value * value;
    const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(mean + epsilon);
    for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
}

/// LayerNorm of one row with weight and bias (ggml_norm: f64 sums).
pub fn layerNorm(input: []const f32, weight: []const f32, bias: []const f32, output: []f32, epsilon: f32) void {
    var sum: f64 = 0;
    for (input) |value| sum += value;
    const mean: f32 = @floatCast(sum / @as(f64, @floatFromInt(input.len)));
    var squares: f64 = 0;
    for (input, output[0..input.len]) |value, *destination| {
        const centered = value - mean;
        destination.* = centered;
        squares += @as(f64, centered * centered);
    }
    const variance: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
    const inverse = 1.0 / @sqrt(variance + epsilon);
    for (output[0..input.len], weight, bias) |*destination, scale, offset| destination.* = destination.* * inverse * scale + offset;
}

/// ggml_v_silu: x / (1 + ggml_v_expf(0 - x)).
pub fn silu(value: f32) f32 {
    return value / (1.0 + expGgml(0.0 - value));
}

/// ggml_v_expf, the vector exp of ggml's CPU backend (x86 AVX2/AVX-512 and
/// NEON share the algorithm and constants): lane-independent, so this scalar
/// port gives its bits. SiLU and softmax go through it in llama.cpp.
pub fn expGgml(x: f32) f32 {
    const r: f32 = 0x1.8p23;
    const z = @mulAdd(f32, x, 0x1.715476p+0, r);
    const n = z - r;
    const b = @mulAdd(f32, -n, 0x1.7f7d1cp-20, @mulAdd(f32, -n, 0x1.62e4p-1, x));
    const e: u32 = @as(u32, @bitCast(z)) << 23;
    const k: f32 = @bitCast(e +% @as(u32, @bitCast(@as(f32, 1.0))));
    const u = b * b;
    const j = @mulAdd(f32, @mulAdd(f32, @mulAdd(f32, 0x1.0e4020p-7, b, 0x1.573e2ep-5), u, @mulAdd(f32, 0x1.555e66p-3, b, 0x1.fffdb6p-2)), u, 0x1.ffffecp-1 * b);
    if (!(@abs(n) > 126)) return @mulAdd(f32, j, k, k);
    const g: u32 = if (n <= 0) 0x82000000 else 0;
    const s1: f32 = @bitCast(g +% 0x7f000000);
    const s2: f32 = @bitCast(e -% g);
    if (@abs(n) > 192) return s1 * s1;
    return @mulAdd(f32, s2, j, s2) * s1;
}

/// ggml_vec_dot_f32 on x86 AVX2: four 8-lane FMA accumulators over 32-wide
/// steps, reduced (0+2, 1+3, then 0+1, then lo+hi and two horizontal adds),
/// then the tail accumulated one product at a time (fused, as clang
/// contracts `sumf += x*y`).
pub fn dotGgml(x: []const f32, y: []const f32) f32 {
    const Lanes = @Vector(8, f32);
    const n = x.len;
    const np = n & ~@as(usize, 31);
    var sums: [4]Lanes = @splat(@splat(0));
    var i: usize = 0;
    while (i < np) : (i += 32) {
        inline for (0..4) |lane| {
            const ax: Lanes = x[i + lane * 8 ..][0..8].*;
            const ay: Lanes = y[i + lane * 8 ..][0..8].*;
            sums[lane] = @mulAdd(Lanes, ax, ay, sums[lane]);
        }
    }
    sums[0] += sums[2];
    sums[1] += sums[3];
    sums[0] += sums[1];
    const t0 = @shuffle(f32, sums[0], undefined, [4]i32{ 0, 1, 2, 3 }) + @shuffle(f32, sums[0], undefined, [4]i32{ 4, 5, 6, 7 });
    // _mm_hadd_ps(t0, t0) = [t0+t1, t2+t3, ..]; again: (t0+t1) + (t2+t3).
    var total: f32 = (t0[0] + t0[1]) + (t0[2] + t0[3]);
    while (i < n) : (i += 1) total = @mulAdd(f32, x[i], y[i], total);
    return total;
}

pub fn sigmoid(value: f32) f32 {
    return 1.0 / (1.0 + @exp(-value));
}

/// GELU with the exact error function: 0.5 x (1 + erf(x / sqrt 2)).
pub fn geluErf(value: f32) f32 {
    const scaled: f32 = value * 0.70710678118654752440;
    const e: f32 = @floatCast(erf(scaled));
    return 0.5 * value * (1.0 + e);
}

/// erf in f64 from the everywhere-positive series
/// erf(x) = 2/sqrt(pi) e^(-x^2) sum_n 2^n x^(2n+1) / (1*3*...*(2n+1)),
/// which has no cancellation; |x| >= 6 is +-1 to f64 precision.
pub fn erf(x: f64) f64 {
    const magnitude = @abs(x);
    if (magnitude == 0 or magnitude != magnitude) return x;
    if (magnitude >= 6.0) return if (x < 0) -1.0 else 1.0;
    const square = magnitude * magnitude;
    var term = magnitude;
    var sum = magnitude;
    var n: f64 = 0;
    while (true) {
        n += 1;
        term *= 2.0 * square / (2.0 * n + 1.0);
        sum += term;
        if (term <= sum * 1e-17 or n > 200) break;
    }
    const result = 1.1283791670955125739 * @exp(-square) * sum;
    return if (x < 0) -result else result;
}

/// NeoX RoPE of `heads` heads at `position`: ggml's rope cache (theta
/// multiplied by base^(-2/d) per lane pair).
pub const ropeNeox = executor.ropeNeox;

pub fn roundHalf(value: f32) f32 {
    return @floatCast(@as(f16, @floatCast(value)));
}

/// llama.cpp's attention without flash attention, for one query head over a
/// key row of `row` keys of which [first, last] are visible: Q.K with
/// ggml_vec_dot_f32, scale, softmax over the whole row (masked keys give
/// ggml_v_expf(-inf) = 0) summing groups of eight in f32 into an f64 total
/// (tail through libm exp), then each output lane as ggml_vec_dot_f32 of the
/// value column with the weights. `scratch` holds 2 * row floats.
pub fn attendHeadGgml(
    query: []const f32,
    keys: []const f32,
    values: []const f32,
    kv_width: usize,
    kv_offset: usize,
    row: usize,
    first: usize,
    last: usize,
    scale: f32,
    scratch: []f32,
    output: []f32,
) void {
    const head_size = query.len;
    const weights = scratch[0..row];
    const column = scratch[row .. 2 * row];
    var maximum: f32 = NEGATIVE_INFINITY;
    for (weights, 0..) |*weight, key| {
        if (key < first or key > last) {
            weight.* = NEGATIVE_INFINITY;
            continue;
        }
        weight.* = dotGgml(keys[key * kv_width + kv_offset ..][0..head_size], query) * scale + 0.0;
        maximum = @max(maximum, weight.*);
    }
    var total: f64 = 0;
    var key: usize = 0;
    while (key + 8 <= row) : (key += 8) {
        var group: [8]f32 = undefined;
        for (&group, weights[key..][0..8]) |*value, score| value.* = expGgml(score - maximum);
        @memcpy(weights[key..][0..8], &group);
        const quarter = [4]f32{ group[4] + group[0], group[5] + group[1], group[6] + group[2], group[7] + group[3] };
        total += (quarter[0] + quarter[2]) + (quarter[1] + quarter[3]);
    }
    while (key < row) : (key += 1) {
        weights[key] = @exp(weights[key] - maximum);
        total += weights[key];
    }
    const inverse: f32 = @floatCast(1.0 / total);
    for (weights) |*weight| weight.* *= inverse;
    for (output[0..head_size], 0..) |*destination, lane| {
        for (column, 0..) |*value, index| value.* = values[index * kv_width + kv_offset + lane];
        destination.* = dotGgml(column, weights);
    }
}

/// One query head against keys [first, last] (rows of `kv_width`, the head's
/// lanes at `kv_offset`): scaled scores, softmax with an f64 sum, weighted
/// values. `half_kv` rounds keys and values to f16 first (flash attention).
pub fn attendHead(
    query: []const f32,
    keys: []const f32,
    values: []const f32,
    kv_width: usize,
    kv_offset: usize,
    first: usize,
    last: usize,
    scale: f32,
    half_kv: bool,
    scores: []f32,
    output: []f32,
) void {
    const head_size = query.len;
    var maximum: f32 = NEGATIVE_INFINITY;
    for (first..last + 1) |key| {
        const row = keys[key * kv_width + kv_offset ..][0..head_size];
        var sum: f32 = 0;
        if (half_kv) {
            for (query, row) |q, k| sum += q * roundHalf(k);
        } else {
            for (query, row) |q, k| sum += q * k;
        }
        const score = sum * scale;
        scores[key - first] = score;
        maximum = @max(maximum, score);
    }
    var total: f64 = 0;
    for (scores[0 .. last + 1 - first]) |*score| {
        score.* = @exp(score.* - maximum);
        total += score.*;
    }
    const inverse: f32 = @floatCast(1.0 / total);
    @memset(output[0..head_size], 0);
    for (first..last + 1) |key| {
        const weight = scores[key - first] * inverse;
        const row = values[key * kv_width + kv_offset ..][0..head_size];
        if (half_kv) {
            for (output[0..head_size], row) |*accumulator, v| accumulator.* += weight * roundHalf(v);
        } else {
            for (output[0..head_size], row) |*accumulator, v| accumulator.* += weight * v;
        }
    }
}

/// Depthwise causal convolution of a short-conv block for channels [first,
/// end): `mixed` holds `tokens` rows of [B | C | X]; each channel convolves
/// B*X over `state` (kernel - 1 oldest-first rows) and the new tokens, scales
/// by C and leaves its last kernel - 1 inputs in `state`.
pub const shortConvChannels = executor.shortConvChannels;

pub fn allFinite(values: []const f32) bool {
    for (values) |value| {
        const bits: u32 = @bitCast(value);
        if (bits & 0x7f800000 == 0x7f800000) return false;
    }
    return true;
}

pub fn multiply(left: usize, right: usize) Error!usize {
    const result = @mulWithOverflow(left, right);
    if (result[1] != 0) return error.ArithmeticOverflow;
    return result[0];
}

const testing = @import("std").testing;

test "erf series matches known values" {
    try testing.expectApproxEqAbs(@as(f64, 0.0), erf(0.0), 1e-17);
    try testing.expectApproxEqRel(@as(f64, 0.52049987781304653768), erf(0.5), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 0.84270079294971486934), erf(1.0), 1e-15);
    try testing.expectApproxEqRel(@as(f64, -0.99532226501895273416), erf(-2.0), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 0.99999998458274209972), erf(4.0), 1e-15);
    try testing.expectEqual(@as(f64, 1.0), erf(7.0));
    try testing.expectApproxEqRel(@as(f32, 0.8413447), geluErf(1.0), 1e-6);
}

test "layer and RMS norms" {
    const input = [_]f32{ 1, 2, 3, 4 };
    const ones = [_]f32{ 1, 1, 1, 1 };
    const zeros = [_]f32{ 0, 0, 0, 0 };
    var output: [4]f32 = undefined;
    layerNorm(&input, &ones, &zeros, &output, 0);
    // mean 2.5, variance 1.25
    try testing.expectApproxEqAbs(@as(f32, -1.5 / @sqrt(1.25)), output[0], 1e-6);
    rmsNorm(&input, &ones, &output, 0);
    try testing.expectApproxEqAbs(@as(f32, 4.0 / @sqrt(7.5)), output[3], 1e-6);
}

test "attention over one key returns its value" {
    const query = [_]f32{ 1, 0 };
    const keys = [_]f32{ 0, 0, 3, 1, 5, 5 };
    const values = [_]f32{ 0, 0, 7, -2, 9, 9 };
    var scores: [3]f32 = undefined;
    var output: [2]f32 = undefined;
    attendHead(&query, &keys, &values, 2, 0, 1, 1, 1.0, false, &scores, &output);
    try testing.expectEqual(@as(f32, 7), output[0]);
    try testing.expectEqual(@as(f32, -2), output[1]);
    // Two keys, scores 3 and 5: weights e^-2/(1+e^-2) and 1/(1+e^-2).
    attendHead(&query, &keys, &values, 2, 0, 1, 2, 1.0, false, &scores, &output);
    const low: f32 = @exp(@as(f32, -2.0)) / (1.0 + @exp(@as(f32, -2.0)));
    try testing.expectApproxEqAbs(low * 7 + (1 - low) * 9, output[0], 1e-5);
}

test "findLayer formats layer names" {
    const Index = gguf.Index(4);
    var index = Index{};
    const name = "a.blk.12.ln1.weight";
    @memcpy(index.tensors[1].name[0..name.len], name);
    index.tensors[1].name_len = name.len;
    index.tensor_count = 2;
    try testing.expectEqual(@as(Ref, 1), findLayer(&index, "a.blk.", 12, ".ln1.weight"));
    try testing.expectEqual(NONE, findLayer(&index, "a.blk.", 1, ".ln1.weight"));
}
