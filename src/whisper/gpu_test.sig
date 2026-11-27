//! Driver-backed Whisper contracts, isolated from the portable aggregate.
const std = @import("std");
const k = @import("kernels.sig");
const model = @import("model.sig");

fn tensor(comptime values: anytype, comptime in_dim: u32, comptime out_dim: u32) model.Tensor {
    return .{ .name = "test", .encoding = .f32, .rank = 2, .dimensions = .{ in_dim, out_dim, 1, 1 }, .data = std.mem.sliceAsBytes(&values) };
}

test "Whisper CUDA F16 and F32 linear and masked attention match CPU" {
    if (!k.cuda.init()) return error.SkipZigTest;
    defer k.cuda.deinit();
    const arena = k.cuda.gpuAlloc(1024 * 1024);
    if (arena == 0) return error.GpuFailure;
    defer k.cuda.gpuFree(arena);
    const scratch_device = k.cuda.gpuAlloc(1024 * 1024);
    if (scratch_device == 0) return error.GpuFailure;
    defer k.cuda.gpuFree(scratch_device);
    var entries: [8]k.CacheEntry = undefined;
    var gpu = try k.Gpu.init(arena, 1024 * 1024, &entries, scratch_device, 1024 * 1024);
    defer gpu.deinit();
    var host_scratch: [128]f32 = undefined;
    var engine: k.Engine = .{ .scratch = &host_scratch, .gpu = &gpu };
    const w = tensor([_]f32{ 1, 2, 3, -1, 0, 2 }, 3, 2);
    const b = tensor([_]f32{ 0.5, -0.25 }, 2, 1);
    const input = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var output: [4]f32 = undefined;
    try engine.linear(&w, &b, &input, &output, 2);
    try std.testing.expectEqualSlices(f32, &.{ 14.5, 4.75, 32.5, 7.75 }, &output);
    const half_values = [_]f16{ 1, 2, 3, -1, 0, 2 };
    const wh: model.Tensor = .{ .name = "half", .encoding = .f16, .rank = 2, .dimensions = .{ 3, 2, 1, 1 }, .data = std.mem.sliceAsBytes(&half_values) };
    try engine.linear(&wh, &b, &input, &output, 2);
    try std.testing.expectEqualSlices(f32, &.{ 14.5, 4.75, 32.5, 7.75 }, &output);
    try std.testing.expectEqual(@as(usize, 2), gpu.entry_count);
    const q = [_]f32{ 1, 0, 2, 0, 0, 1, 0, 2 };
    const values = [_]f32{ 10, 20, 100, 200, 30, 40, 300, 400 };
    var gpu_output: [8]f32 = undefined;
    var cpu_output: [8]f32 = undefined;
    var scores: [4]f32 = undefined;
    var cpu: k.Engine = .{ .scratch = &.{} };
    for ([_]?usize{ null, 0, 1 }) |offset| {
        try engine.attention(&q, &q, &values, &gpu_output, 2, 2, 4, 2, &.{}, offset);
        try cpu.attention(&q, &q, &values, &cpu_output, 2, 2, 4, 2, &scores, offset);
        for (gpu_output, cpu_output) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 1e-4);
    }
    // Odd dimensions exercise arena padding;257 keys exercise every lane and
    // multiple iterations of each shared-memory softmax reduction.
    var long_keys: [257]f32 = undefined;
    var long_values: [257]f32 = undefined;
    for (&long_keys, &long_values, 0..) |*key, *value, i| {
        key.* = @sin(@as(f32, @floatFromInt(i)) * 0.031);
        value.* = @cos(@as(f32, @floatFromInt(i)) * 0.071);
    }
    var larger_scratch: [512]f32 = undefined;
    engine.scratch = &larger_scratch;
    var long_scores: [3 * 257]f32 = undefined;
    var long_gpu: [3]f32 = undefined;
    var long_cpu: [3]f32 = undefined;
    for ([_]?usize{ null, 0, 254 }) |offset| {
        try engine.attention(&.{ 0.5, 0.75, 1.25 }, &long_keys, &long_values, &long_gpu, 3, 257, 1, 1, &.{}, offset);
        try cpu.attention(&.{ 0.5, 0.75, 1.25 }, &long_keys, &long_values, &long_cpu, 3, 257, 1, 1, &long_scores, offset);
        for (long_gpu, long_cpu) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 1e-5);
    }
}

test "Whisper resident decoder cache preserves half attention across heads and history boundaries" {
    if (!k.cuda.init()) return error.SkipZigTest;
    defer k.cuda.deinit();
    const arena = k.cuda.gpuAlloc(1024 * 1024);
    if (arena == 0) return error.GpuFailure;
    defer k.cuda.gpuFree(arena);
    const device_scratch = k.cuda.gpuAlloc(8 * 1024 * 1024);
    if (device_scratch == 0) return error.GpuFailure;
    defer k.cuda.gpuFree(device_scratch);
    const bytes = try k.DecoderKv.requiredBytes(2, 449, 1500, 320, 5);
    const device = k.cuda.gpuAlloc(bytes);
    if (device == 0) return error.GpuFailure;
    defer k.cuda.gpuFree(device);
    var entries: [8]k.CacheEntry = undefined;
    var gpu = try k.Gpu.init(arena, 1024 * 1024, &entries, device_scratch, 8 * 1024 * 1024);
    defer gpu.deinit();
    var cache = try k.DecoderKv.init(device, bytes, 2, 449, 1500, 320, 5);
    const Data = struct {
        var keys: [4096 * 128]f32 = undefined;
        var values: [4096 * 128]f32 = undefined;
        var scratch: [4096 * 128]f32 = undefined;
    };
    for (&Data.keys, &Data.values, 0..) |*key, *value, i| {
        key.* = @sin(@as(f32, @floatFromInt(i % 8191)) * 0.013) * 0.9;
        value.* = @cos(@as(f32, @floatFromInt(i % 7879)) * 0.037);
    }
    var query: [320]f32 = undefined;
    for (&query, 0..) |*value, i| value.* = @sin(@as(f32, @floatFromInt(i)) * 0.17) * 1.3;
    var actual: [320]f32 = undefined;
    var expected: [320]f32 = undefined;
    var cpu_expected: [320]f32 = undefined;
    var scores: [1500]f32 = undefined;
    var engine: k.Engine = .{ .scratch = &Data.scratch, .gpu = &gpu };
    var cpu: k.Engine = .{ .scratch = &.{} };
    const cross_keys = Data.keys[0 .. 1500 * 320];
    const cross_values = Data.values[0 .. 1500 * 320];
    try cache.uploadCross(1, cross_keys, cross_values, &gpu, &Data.scratch);
    try cache.attention(1, true, 1500, &query, &actual, &gpu, &Data.scratch);
    try engine.attention(&query, cross_keys, cross_values, &expected, 1, 1500, 320, 5, &.{}, null);
    try cpu.attention(&query, cross_keys, cross_values, &cpu_expected, 1, 1500, 320, 5, &scores, null);
    for (actual, expected, cpu_expected) |got, reference, mathematical| {
        try std.testing.expectApproxEqAbs(reference, got, 2e-5);
        try std.testing.expectApproxEqAbs(mathematical, got, 2e-5);
    }
    var previous: usize = 0;
    for ([_]usize{ 1, 127, 128, 129, 257, 449 }) |count| {
        try cache.appendSelf(0, previous, Data.keys[previous * 320 .. count * 320], Data.values[previous * 320 .. count * 320], &gpu, &Data.scratch);
        try cache.attention(0, false, count, &query, &actual, &gpu, &Data.scratch);
        try engine.attention(&query, Data.keys[0 .. count * 320], Data.values[0 .. count * 320], &expected, 1, count, 320, 5, &.{}, count - 1);
        for (actual, expected) |got, reference| try std.testing.expectApproxEqAbs(reference, got, 2e-5);
        previous = count;
    }
    try std.testing.expectError(error.Shape, cache.appendSelf(0, 449, query[0..1], &query, &gpu, &Data.scratch));
    try std.testing.expectError(error.Shape, cache.attention(0, false, 448, &query, &actual, &gpu, &Data.scratch));
    try std.testing.expectError(error.Shape, cache.attention(0, true, 1500, &query, &actual, &gpu, &Data.scratch));
    try std.testing.expectError(error.AliasedBuffers, cache.attention(1, true, 1500, &query, &query, &gpu, &Data.scratch));
    try std.testing.expectError(error.Capacity, cache.attention(1, true, 1500, &query, &actual, &gpu, &.{}));
    cache.reset();
    try std.testing.expectError(error.Shape, cache.attention(1, true, 1500, &query, &actual, &gpu, &Data.scratch));
    var aliased = try k.DecoderKv.init(device_scratch, bytes, 2, 449, 1500, 320, 5);
    try std.testing.expectError(error.AliasedBuffers, aliased.checkGpu(&gpu));
    try std.testing.expectError(error.Capacity, k.DecoderKv.init(device, bytes - 1, 2, 449, 1500, 320, 5));
    try std.testing.expectError(error.Shape, k.DecoderKv.requiredBytes(2, 449, 1500, 320, 2));
    // Maximum supported context and non-warp-aligned head dimensions exercise
    // the kernel's shared-memory bound and every guarded output lane.
    for ([_]usize{ 1, 3, 63, 65, 128 }) |dim| {
        var edge = try k.DecoderKv.init(device, bytes, 1, 4096, 4096, dim, 1);
        const keys = Data.keys[0 .. 4096 * dim];
        const values = Data.values[0 .. 4096 * dim];
        try edge.uploadCross(0, keys, values, &gpu, &Data.scratch);
        try edge.attention(0, true, 4096, query[0..dim], actual[0..dim], &gpu, &Data.scratch);
        try engine.attention(query[0..dim], keys, values, expected[0..dim], 1, 4096, dim, 1, &.{}, null);
        for (actual[0..dim], expected[0..dim]) |got, reference| try std.testing.expectApproxEqAbs(reference, got, 2e-5);
    }
}

test "Resident encoder GPU norm GELU residual and convolution columns match native references" {
    try @import("encoder_gpu.sig").test_support.residentContracts();
}

test "Whisper resident decoder prefill lifecycle matches CPU across audio sessions" {
    try @import("decoder_test.sig").prefillContracts(true);
}
