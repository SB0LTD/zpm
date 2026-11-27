const std = @import("std");
const k = @import("kernels.sig");
const model = @import("model.sig");

fn tensor(comptime values: anytype, comptime in_dim: u32, comptime out_dim: u32) model.Tensor {
    return .{ .name = "test", .encoding = .f32, .rank = 2, .dimensions = .{ in_dim, out_dim, 1, 1 }, .data = std.mem.sliceAsBytes(&values) };
}

test "Whisper linear row-major and bias match explicit dot products" {
    const w = tensor([_]f32{ 1, 2, 3, -1, 0, 2 }, 3, 2);
    const b = tensor([_]f32{ 0.5, -0.25 }, 2, 1);
    const input = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var output: [4]f32 = undefined;
    var scratch: [3]f32 = undefined;
    var engine: k.Engine = .{ .scratch = &scratch };
    try engine.linear(&w, &b, &input, &output, 2);
    try std.testing.expectEqualSlices(f32, &.{ 14.5, 4.75, 32.5, 7.75 }, &output);
    try std.testing.expectError(error.Shape, engine.linear(&w, null, &input, &output, 1));
}

test "Whisper norm and GELU preserve expected reference values" {
    const w = tensor([_]f32{ 1, 2 }, 2, 1);
    const b = tensor([_]f32{ 0.5, -0.5 }, 2, 1);
    var out: [4]f32 = undefined;
    try k.layerNorm(&.{ 1, 3, 5, 5 }, &out, &w, &b, 2, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -0.499995), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.49999), out[1], 1e-5);
    try std.testing.expectEqual(@as(f32, 0.5), out[2]);
    try std.testing.expectEqual(@as(f32, -0.5), out[3]);
    var values = [_]f32{ -2, -1, 0, 1, 2 };
    k.gelu(&values);
    for (values, [_]f32{ -0.0454023, -0.158808, 0, 0.841192, 1.9545977 }) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 2e-6);
}

test "Whisper bidirectional and causal attention keep independent heads" {
    var engine: k.Engine = .{ .scratch = &.{}, .attention_precision = .f32 };
    const q = [_]f32{ 1, 0, 2, 0, 0, 1, 0, 2 };
    const keys = [_]f32{ 1, 0, 2, 0, 0, 1, 0, 2 };
    const values = [_]f32{ 10, 20, 100, 200, 30, 40, 300, 400 };
    var output: [8]f32 = undefined;
    var scores: [4]f32 = undefined;
    try engine.attention(&q, &keys, &values, &output, 2, 2, 4, 2, &scores, null);
    const probability: f32 = 1.0 / (1.0 + @exp(@as(f32, -1.0 / @sqrt(2.0))));
    try std.testing.expectApproxEqAbs(10 * probability + 30 * (1 - probability), output[0], 1e-5);
    try std.testing.expect(output[2] < 120);
    try engine.attention(&q, &keys, &values, &output, 2, 2, 4, 2, &scores, 0);
    try std.testing.expectEqualSlices(f32, values[0..4], output[0..4]);
    try engine.attention(q[4..8], &keys, &values, output[0..4], 1, 2, 4, 2, scores[0..2], 1);
    try std.testing.expect(output[0] > 20);
}
