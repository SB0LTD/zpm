//! Local-model integration check; independent oracle tensors remain dev only.
const std = @import("std");
const model = @import("whisper/model.sig");
const tokenizer = @import("whisper/tokenizer.sig");
const decoder = @import("whisper/decoder.sig");
const kernels = @import("whisper/kernels.sig");
const Mapping = @import("whisper_encoder_parity.sig").Mapping;
extern "kernel32" fn GetCommandLineA() callconv(.winapi) [*:0]const u8;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

var tensors: [1024]model.Tensor = undefined;
var vocabulary: [52000]model.Token = undefined;
var storage_a: [22 * 1024 * 1024]f32 = undefined;
var storage_b: [22 * 1024 * 1024]f32 = undefined;
var scratch_host: [4 * 1024 * 1024]f32 = undefined;
var entries: [1024]kernels.CacheEntry = undefined;

fn best(logits: []const f32) u32 { var index: usize = 0; for (logits, 0..) |value, i| if (value > logits[index]) { index = i; }; return @intCast(index); }
fn compare(a: []const f32, b: []const f32, label: []const u8, threshold: f64) !void {
    var square: f64 = 0;
    var largest: f32 = 0;
    for (a, b) |x, y| { const delta = @abs(x - y); largest = @max(largest, delta); square += @as(f64, delta) * delta; }
    const rms = @sqrt(square / @as(f64, @floatFromInt(a.len)));
    std.debug.print("{s}: max_abs={d:.6} RMS={d:.6}\n", .{ label, largest, rms });
    if (rms > threshold) return error.NumericalMismatch;
}

pub fn main() !void {
    var args = std.mem.tokenizeScalar(u8, std.mem.span(GetCommandLineA()), ' ');
    _ = args.next();
    const model_path = args.next() orelse return error.Usage;
    const encoded_path = args.next() orelse return error.Usage;
    const oracle_dir = args.next() orelse return error.Usage;
    const mm = try Mapping.open(model_path); defer mm.close();
    const m = try model.parse(mm.bytes, &tensors, &vocabulary);
    const encoded = try Mapping.open(encoded_path); defer encoded.close();
    var a = try decoder.Decoder.init(&m);
    var b = try decoder.Decoder.init(&m);
    var wa = try decoder.Workspace.init(&storage_a, m.hparams);
    var wb = try decoder.Workspace.init(&storage_b, m.hparams);
    if (!kernels.cuda.init()) return error.GpuUnavailable;
    defer kernels.cuda.deinit();
    const arena = kernels.cuda.gpuAlloc(2 * 1024 * 1024 * 1024);
    if (arena == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(arena);
    const scratch = kernels.cuda.gpuAlloc(64 * 1024 * 1024);
    if (scratch == 0) return error.GpuFailure;
    defer kernels.cuda.gpuFree(scratch);
    var gpu = try kernels.Gpu.init(arena, 2 * 1024 * 1024 * 1024, &entries, scratch, 64 * 1024 * 1024);
    defer gpu.deinit();
    var engine: kernels.Engine = .{ .scratch = &scratch_host, .gpu = &gpu };
    try a.prepare(encoded.floats(), &wa, &engine);
    try b.prepare(encoded.floats(), &wb, &engine);
    var prompt: [4]u32 = undefined;
    const n = try tokenizer.transcriptionPrompt(m.hparams.n_vocab, "he", false, &prompt);
    var reference: []const f32 = &.{};
    for (prompt[0..n], 0..) |id, i| if (try a.step(id, i == n - 1, &wa, &engine)) |logits| { reference = logits; };
    var actual = try b.prefill(prompt[0..n], &wb, &engine);
    try compare(reference, actual, "four-token prefix", 0.05);
    var generated: [16]u32 = undefined;
    for (0..16) |step| {
        var filename: [4096]u8 = undefined;
        const path = try std.fmt.bufPrint(&filename, "{s}/logits-step-{d}.f32", .{ oracle_dir, step });
        const oracle = try Mapping.open(path); defer oracle.close();
        const token = best(oracle.floats());
        std.debug.print("step={d} sequential={d} batched={d} oracle={d}\n", .{ step, best(reference), best(actual), token });
        if (best(reference) != token or best(actual) != token) return error.TokenMismatch;
        try compare(oracle.floats(), actual, "oracle logits", 0.075);
        generated[step] = token;
        if (step != 15) { reference = (try a.step(token, true, &wa, &engine)).?; actual = (try b.step(token, true, &wb, &engine)).?; }
    }
    // Use a97-token fixture to exercise64+33 chunks and an existing KV prefix.
    var carry: [97]u32 = undefined;
    for (&carry, 0..) |*id, i| id.* = generated[i % generated.len];
    carry[carry.len - 1] = prompt[0];
    const start_a = GetTickCount64();
    for (carry, 0..) |id, i| if (try a.step(id, i == carry.len - 1, &wa, &engine)) |logits| { reference = logits; };
    const sequential_ms = GetTickCount64() - start_a;
    const start_b = GetTickCount64();
    actual = try b.prefill(&carry, &wb, &engine);
    const batched_ms = GetTickCount64() - start_b;
    try compare(reference, actual, "97-token carry logits", 0.075);
    if (best(reference) != best(actual)) return error.TokenMismatch;
    for (0..m.hparams.n_text_layer) |layer| {
        const offset = layer * @as(usize, m.hparams.n_text_ctx) * m.hparams.n_text_state;
        const used = a.position * m.hparams.n_text_state;
        try compare(wa.self_keys[offset..][0..used], wb.self_keys[offset..][0..used], "causal KV keys", 0.01);
        try compare(wa.self_values[offset..][0..used], wb.self_values[offset..][0..used], "causal KV values", 0.01);
    }
    std.debug.print("PASS16/16 independent oracle tokens;97-token prefill sequential={d}ms batch={d}ms positions={d}/{d}\n", .{ sequential_ms, batched_ms, a.position, b.position });
}
