const std = @import("std");
const model = @import("model.sig");
const decoder = @import("decoder.sig");
const kernels = @import("kernels.sig");

fn addTensor(directory: []model.Tensor, names: [][128]u8, count: *usize, name: []const u8, values: []const f32, shape: []const u32) void {
    @memcpy(names[count.*][0..name.len], name);
    var dimensions: [4]u32 = @splat(1);
    @memcpy(dimensions[0..shape.len], shape);
    directory[count.*] = .{ .name = names[count.*][0..name.len], .encoding = .f32, .rank = @intCast(shape.len), .dimensions = dimensions, .data = std.mem.sliceAsBytes(values) };
    count.* += 1;
}

pub fn prefillContracts(comptime with_gpu: bool) !void {
    var directory: [64]model.Tensor = undefined;
    var names: [64][128]u8 = undefined;
    var count: usize = 0;
    const h: model.HParams = .{ .n_vocab = 8, .n_audio_ctx = 3, .n_audio_state = 2, .n_audio_head = 2, .n_audio_layer = 1, .n_text_ctx = 70, .n_text_state = 2, .n_text_head = 2, .n_text_layer = 2, .n_mels = 1, .ftype = 0 };
    const gain = [_]f32{ 1.1, 0.9 };
    const bias = [_]f32{ 0.02, -0.01 };
    const matrix = [_]f32{ 0.2, -0.3, 0.4, 0.5 };
    var embedding: [16]f32 = undefined;
    var positional: [140]f32 = undefined;
    var expanded: [16]f32 = undefined;
    const ffn_bias = [_]f32{ 0.01, -0.02, 0.03, -0.04, 0.05, -0.06, 0.07, -0.08 };
    for (&embedding, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.71);
    for (&positional, 0..) |*v, i| v.* = @cos(@as(f32, @floatFromInt(i)) * 0.13);
    for (&expanded, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.23) * 0.3;
    addTensor(&directory, &names, &count, "decoder.token_embedding.weight", &embedding, &.{ 2, 8 });
    addTensor(&directory, &names, &count, "decoder.positional_embedding", &positional, &.{ 2, 70 });
    addTensor(&directory, &names, &count, "decoder.ln.weight", &gain, &.{2});
    addTensor(&directory, &names, &count, "decoder.ln.bias", &bias, &.{2});
    var buffer: [128]u8 = undefined;
    for (0..2) |layer| {
        for ([_][]const u8{ "attn_ln", "cross_attn_ln", "mlp_ln" }) |prefix| {
            addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.{s}.weight", .{ layer, prefix }), &gain, &.{2});
            addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.{s}.bias", .{ layer, prefix }), &bias, &.{2});
        }
        for ([_][]const u8{ "attn.query", "attn.key", "attn.value", "attn.out", "cross_attn.query", "cross_attn.key", "cross_attn.value", "cross_attn.out" }) |prefix| {
            addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.{s}.weight", .{ layer, prefix }), &matrix, &.{ 2, 2 });
            if (!std.mem.endsWith(u8, prefix, ".key")) addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.{s}.bias", .{ layer, prefix }), &bias, &.{2});
        }
        addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.mlp.0.weight", .{layer}), &expanded, &.{ 2, 8 });
        addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.mlp.0.bias", .{layer}), &ffn_bias, &.{8});
        addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.mlp.2.weight", .{layer}), &expanded, &.{ 8, 2 });
        addTensor(&directory, &names, &count, try std.fmt.bufPrint(&buffer, "decoder.blocks.{d}.mlp.2.bias", .{layer}), &bias, &.{2});
    }
    const m: model.Model = .{ .hparams = h, .tensors = directory[0..count], .vocabulary = &.{}, .filters = .{ .n_mels = 1, .n_fft = 201, .data = &.{} } };
    var sequential = try decoder.Decoder.init(&m);
    var batched = try decoder.Decoder.init(&m);
    var storage_a: [10000]f32 = undefined;
    var storage_b: [10000]f32 = undefined;
    var a = try decoder.Workspace.init(&storage_a, h);
    var b = try decoder.Workspace.init(&storage_b, h);
    var scratch: [512]f32 = undefined;
    var engine: kernels.Engine = .{ .scratch = &scratch };
    const encoded = [_]f32{ 0.2, 0.4, 0.6, 0.1, -0.3, -0.5 };
    try sequential.prepare(&encoded, &a, &engine);
    try batched.prepare(&encoded, &b, &engine);
    for ([_]u32{ 1, 2, 3 }) |id| {
        _ = try sequential.step(id, false, &a, &engine);
        _ = try batched.step(id, false, &b, &engine);
    }
    var ids: [65]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast((i * 3 + 2) % 8);
    var reference: []const f32 = &.{};
    for (ids, 0..) |id, i| if (try sequential.step(id, i == ids.len - 1, &a, &engine)) |logits| {
        reference = logits;
    };
    const actual = try batched.prefill(&ids, &b, &engine);
    try std.testing.expectEqual(@as(usize, 68), batched.position);
    for (reference, actual) |expected, got| try std.testing.expectApproxEqAbs(expected, got, 2e-6);
    for (0..h.n_text_layer) |layer| {
        const offset = layer * @as(usize, h.n_text_ctx) * h.n_text_state;
        const used = batched.position * h.n_text_state;
        for (a.self_keys[offset..][0..used], b.self_keys[offset..][0..used]) |expected, got| try std.testing.expectApproxEqAbs(expected, got, 2e-6);
        for (a.self_values[offset..][0..used], b.self_values[offset..][0..used]) |expected, got| try std.testing.expectApproxEqAbs(expected, got, 2e-6);
    }
    try std.testing.expectError(error.InvalidToken, batched.prefill(&.{ 1, 999 }, &b, &engine));
    try std.testing.expectError(error.ContextCapacity, batched.prefill(&.{ 1, 2, 3 }, &b, &engine));
    try std.testing.expectError(error.EmptyPrefix, batched.prefill(&.{}, &b, &engine));
    try std.testing.expectEqual(@as(usize, 68), batched.position);
    try std.testing.expect(batched.prepared);
    _ = try batched.step(2, true, &b, &engine);
    try std.testing.expectEqual(@as(usize, 69), batched.position);

    if (!with_gpu) return;
    if (!kernels.cuda.init()) return error.SkipZigTest;
    defer kernels.cuda.deinit();
    const arena = kernels.cuda.gpuAlloc(1024 * 1024);
    if (arena == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(arena);
    const device_scratch = kernels.cuda.gpuAlloc(1024 * 1024);
    if (device_scratch == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(device_scratch);
    const cache_bytes = try kernels.DecoderKv.requiredBytes(h.n_text_layer, h.n_text_ctx, h.n_audio_ctx, h.n_text_state, h.n_text_head);
    const device_cache = kernels.cuda.gpuAlloc(cache_bytes);
    if (device_cache == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(device_cache);
    var entries: [64]kernels.CacheEntry = undefined;
    var gpu = try kernels.Gpu.init(arena, 1024 * 1024, &entries, device_scratch, 1024 * 1024);
    defer gpu.deinit();
    var cache = try kernels.DecoderKv.init(device_cache, cache_bytes, h.n_text_layer, h.n_text_ctx, h.n_audio_ctx, h.n_text_state, h.n_text_head);
    var accelerated = try decoder.Decoder.init(&m);
    accelerated.gpu_kv = &cache;
    var checked = try decoder.Decoder.init(&m);
    var gpu_engine: kernels.Engine = .{ .scratch = &scratch, .gpu = &gpu };
    // Reuse the now idle caller-owned workspaces. Test the64+1 prefill boundary,
    // incremental continuation and reset across two audio sessions.
    for (0..2) |_| {
        try checked.prepare(&encoded, &a, &engine);
        try accelerated.prepare(&encoded, &b, &gpu_engine);
        const cpu_logits = try checked.prefill(&ids, &a, &engine);
        const gpu_logits = try accelerated.prefill(&ids, &b, &gpu_engine);
        for (cpu_logits, gpu_logits) |expected, got| try std.testing.expectApproxEqAbs(expected, got, 2e-4);
        for ([_]u32{ 2, 5, 1 }) |id| {
            const ref = (try checked.step(id, true, &a, &engine)).?;
            const got = (try accelerated.step(id, true, &b, &gpu_engine)).?;
            for (ref, got) |expected, observed| try std.testing.expectApproxEqAbs(expected, observed, 2e-4);
        }
        try std.testing.expectEqual(@as(usize, 68), accelerated.position);
        for (cache.self_rows[0..h.n_text_layer]) |rows| try std.testing.expectEqual(accelerated.position, rows);
    }
    accelerated.gpu_kv = null;
    try std.testing.expectError(error.NotPrepared, accelerated.step(1, true, &b, &gpu_engine));
    accelerated.gpu_kv = &cache;
    gpu_engine.attention_precision = .f32;
    try std.testing.expectError(error.UnsupportedTensor, accelerated.step(1, true, &b, &gpu_engine));
}

test "Whisper batched prefill preserves causal KV and sequential logits across64-token chunks" {
    try prefillContracts(false);
}
