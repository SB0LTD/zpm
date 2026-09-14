//! Execute session contracts using the real tokenizer and shared executor.
//! The tiny deterministic F32 model exercises orchestration, not model quality.
const std = @import("std");
const api = @import("inference_session");
const gguf = @import("gguf");
const executor = @import("qwen3_executor");
const cache = @import("kv_cache");

const VOCAB = 262;
const EMBEDDING_BASE = 8192;
var session: api.Session = undefined;
var model: [32768]u8 = @splat(0);
var arena: [8192]u8 align(64) = undefined;
var assertions: usize = 0;
var allocations: usize = 0;
var reads: usize = 0;
var embeddings: [128]u32 = undefined;
var embedding_count: usize = 0;
var fail_weights = false;
var fail_decode = false;
var cancel_forward = false;
var source_context: u8 = 0;

fn require(value: bool) !void {
    assertions += 1;
    if (!value) return error.InferenceSessionContractFailed;
}
fn allocate(bytes: usize, alignment: usize) ?[*]u8 {
    allocations += 1;
    if (bytes > arena.len or alignment > 64) return null;
    return &arena;
}
fn readAt(_: *const anyopaque, offset: u64, out: []u8) bool {
    reads += 1;
    if (fail_weights and offset >= EMBEDDING_BASE) return false;
    if (fail_decode and offset < EMBEDDING_BASE) return false;
    if (offset >= EMBEDDING_BASE and offset < EMBEDDING_BASE + VOCAB * 8) {
        if (embedding_count == embeddings.len) return false;
        embeddings[embedding_count] = @intCast((offset - EMBEDDING_BASE) / 8);
        embedding_count += 1;
    }
    @memcpy(out, model[@intCast(offset)..][0..out.len]);
    return true;
}
fn progress(_: *anyopaque, event: executor.ProgressEvent) bool {
    return !(cancel_forward and event.stage == .request_begin);
}
fn source() gguf.Source {
    return .{ .context = &source_context, .size = model.len, .read_at = readAt };
}
fn appendString(offset: *usize, value: []const u8) void {
    std.mem.writeInt(u64, model[offset.*..][0..8], value.len, .little);
    offset.* += 8;
    @memcpy(model[offset.*..][0..value.len], value);
    offset.* += value.len;
}
fn tensor(index: usize, cols: usize, rows: usize, offset: usize, vector: bool) void {
    session.index.tensors[index] = .{
        .dimension_count = if (vector) 1 else 2,
        .dimensions = .{ cols, if (vector) 0 else rows, 0, 0 },
        .ggml_type = 0, .file_offset = offset, .byte_size = cols * rows * 4,
    };
}
fn storeF32(offset: usize, value: f32) void {
    std.mem.writeInt(u32, model[offset..][0..4], @bitCast(value), .little);
}
fn setup() !void {
    fail_weights = false;
    fail_decode = false;
    cancel_forward = false;
    @memset(&model, 0);
    var offset: usize = 0;
    // Every byte-level token plus the exact published chat delimiters.
    for (0..256) |raw| {
        const byte: u8 = @intCast(raw);
        const included = (byte >= 33 and byte <= 126) or (byte >= 161 and byte <= 172) or byte >= 174;
        const excluded: u16 = if (included) 0 else if (byte <= 32) byte else if (byte <= 160) @intCast(33 + raw - 127) else 67;
        const cp: u16 = if (included) byte else 256 + excluded;
        var encoded: [2]u8 = undefined;
        if (cp < 128) {
            encoded[0] = @intCast(cp);
            appendString(&offset, encoded[0..1]);
        } else {
            encoded[0] = 0xc0 | @as(u8, @intCast(cp >> 6));
            encoded[1] = 0x80 | @as(u8, @intCast(cp & 63));
            appendString(&offset, &encoded);
        }
    }
    for ([_][]const u8{ "<|endoftext|>", "<|im_end|>", "<|im_start|>", "<think>", "</think>", "AB" }) |token|
        appendString(&offset, token);
    session.source = source();
    session.index = .{};
    session.index.tensor_count = 15;
    session.index.summary.tokenizer_tokens = .{ .present = true, .element_type = 8, .count = VOCAB, .data_offset = 0 };
    try session.vocabulary.build(session.source, session.index.summary.tokenizer_tokens);
    try session.merges.build(session.source, .{ .present = true, .element_type = 8, .count = 0, .data_offset = offset }, &session.vocabulary);
    session.plan = .{
        .layer_count = 1, .hidden_size = 2, .feed_forward_size = 2,
        .head_count = 1, .kv_head_count = 1, .head_size = 2,
        .query_size = 2, .key_value_size = 2, .vocabulary_size = VOCAB,
        .rope_frequency_base = 10000, .rms_norm_epsilon = 0.00001,
        .token_embedding = .{ .index = 0 }, .output_norm = .{ .index = 1 }, .output = .{ .index = 2 },
    };
    session.plan.layers[0] = .{
        .attention_norm = .{ .index = 3 }, .query = .{ .index = 4 }, .key = .{ .index = 5 },
        .value = .{ .index = 6 }, .attention_output = .{ .index = 7 },
        .query_norm = .{ .index = 8 }, .key_norm = .{ .index = 9 },
        .ffn_norm = .{ .index = 10 }, .ffn_gate = .{ .index = 11 },
        .ffn_up = .{ .index = 12 }, .ffn_down = .{ .index = 13 },
    };
    tensor(0, 2, VOCAB, EMBEDDING_BASE, false);
    for (0..VOCAB) |token| storeF32(EMBEDDING_BASE + token * 8, 1);
    const output_base = EMBEDDING_BASE + VOCAB * 8;
    tensor(2, 2, VOCAB, output_base, false);
    storeF32(output_base + 'A' * 8, 1);
    var data_offset: usize = output_base + VOCAB * 8;
    for (1..14) |index| {
        if (index == 2) continue;
        const vector = index == 1 or index == 3 or index == 8 or index == 9 or index == 10;
        tensor(index, 2, if (vector) 1 else 2, data_offset, vector);
        if (vector) { storeF32(data_offset, 1); storeF32(data_offset + 4, 1); }
        data_offset += if (vector) @as(usize, 8) else 16;
    }
    session.config = .{ .progress_fn = progress, .progress_ctx = &source_context };
    session.alloc_fn = allocate;
    session.cache = try cache.KvCache.init(allocate, 1, 1, 2, session.config.max_context);
    session.work = .{};
    session.position = 0;
    session.generated_count = 0;
    session.prompt_len = 0;
    session.generation = 0;
    session.finished = true;
    session.eos_token = 256;
    session.eot_token = 257;
    reads = 0;
    embedding_count = 0;
}

pub fn main(init: std.process.Init) !void {
    try require((api.SessionConfig{}).max_context == executor.qwen3_0_6b_limits.context);
    const empty = gguf.Source{ .context = &source_context, .size = 0, .read_at = readAt };
    if (session.init(allocate, empty, .{ .max_context = 65 })) |_| return error.InvalidContextAccepted
    else |err| try require(err == error.ContextCapacity);
    try require(allocations == 0 and reads == 0);
    if (session.init(allocate, empty, .{ .max_context = 0 })) |_| return error.ZeroContextAccepted
    else |err| try require(err == error.ContextCapacity);
    if (session.init(allocate, empty, .{ .progress_fn = progress })) |_| return error.MissingProgressContextAccepted
    else |err| try require(err == error.InvalidPlan);

    try setup();
    try require(session.vocabulary.count == VOCAB); // Previously failed at 97 tokens.
    var iter = try session.generate("Hi", .{ .max_tokens = 2, .sampling = .GREEDY });
    const prompt_length = session.prompt_len;
    try require(embedding_count == prompt_length and prompt_length > 0);
    for (embeddings[0..embedding_count], session.token_buf[0..prompt_length]) |actual, expected|
        try require(actual == expected);
    const first = (try iter.next()).?;
    try require(first.token_id == 'A' and std.mem.eql(u8, first.bytes, "A"));
    try require(session.token_buf[prompt_length] == 'A');
    try require(embedding_count == prompt_length + 1 and embeddings[prompt_length] == 'A');
    _ = (try iter.next()).?;
    try require(iter.done() and (try iter.next()) == null);
    try require(iter.tokensGenerated() == 2 and session.contextUsed() == prompt_length + 2);
    try require(session.cache.contextLength() == session.contextUsed());

    var stale = iter;
    session.reset();
    if (stale.next()) |_| return error.StaleIteratorAccepted
    else |err| try require(err == error.StaleGeneration);
    try require(stale.done() and stale.tokensGenerated() == 0);
    iter = try session.generate("Hi", .{ .max_tokens = 0 });
    try require(iter.done() and session.contextUsed() == 0);

    embedding_count = 0;
    session.config.max_context = 8;
    if (session.generate("Hi", .{})) |_| return error.OversizedPromptAccepted
    else |err| try require(err == error.TokenCapacity or err == error.ContextCapacity);
    try require(embedding_count == 0 and session.finished);
    session.config.max_context = executor.qwen3_0_6b_limits.context;
    if (session.generate("Hi", .{ .sampling = .{ .temperature = -1 } })) |_| return error.InvalidSamplingAccepted
    else |err| try require(err == error.InvalidSampling);

    iter = try session.generate("Hi", .{ .max_tokens = 2, .sampling = .GREEDY });
    fail_decode = true;
    if (iter.next()) |_| return error.DecodeFailureHidden
    else |err| try require(err == error.UnexpectedEof);
    try require(iter.done() and iter.tokensGenerated() == 0);
    fail_decode = false;
    embedding_count = 0;
    iter = try session.generate("Hi", .{ .max_tokens = 2, .sampling = .GREEDY });
    fail_weights = true;
    if (iter.next()) |_| return error.StorageFailureHidden
    else |err| try require(err == error.StorageFailure);
    try require(iter.done() and iter.tokensGenerated() == 0);
    fail_weights = false;
    embedding_count = 0;
    iter = try session.generate("Hi", .{ .max_tokens = 2, .sampling = .GREEDY });
    cancel_forward = true;
    if (iter.next()) |_| return error.CancellationHidden
    else |err| try require(err == error.Cancelled);
    try require(iter.done() and iter.tokensGenerated() == 0);
    cancel_forward = false;

    // The complete API rejects capacity exhaustion rather than succeeding with
    // a truncated byte sequence. Normal completion still returns exact bytes.
    embedding_count = 0;
    var output: [2]u8 = undefined;
    const count = try api.generateComplete(&session, "Hi", .{ .max_tokens = 2, .sampling = .GREEDY }, &output);
    try require(count == 2 and std.mem.eql(u8, &output, "AA"));
    embedding_count = 0;
    if (api.generateComplete(&session, "Hi", .{ .max_tokens = 2, .sampling = .GREEDY }, output[0..1])) |_| return error.OutputCapacityHidden
    else |err| try require(err == error.OutputCapacity);
    try require(session.finished);
    var message: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&message, "PASS inference-session: {d} executed assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
