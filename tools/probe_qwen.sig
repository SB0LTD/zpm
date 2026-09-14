//! Real-model autoregressive probe for the shared bounded decoder.
//! Host I/O only maps the model, reads arguments, records time and writes output.
//! All tokens, model arithmetic and resumable state come from ZPM modules.
const std = @import("std");
const process = @import("sig_process");
const gguf = @import("gguf");
const plan_mod = @import("qwen3_decoder_plan");
const executor = @import("qwen3_executor");
const tokenizer = @import("tokenizer");
const indexes = @import("tokenizer_index");
const sha256 = @import("sha256");

const capacity = 2048;
const limits = block: {
    var value = executor.qwen3_0_6b_limits;
    value.context = 256;
    break :block value;
};
var index: gguf.Index(capacity) = .{};
var plan: plan_mod.Plan = .{};
var work: executor.WorkingSet(limits) = .{};
var kv: [28 * 2 * 8 * limits.context * 128]u16 = @splat(0);
var vocabulary: indexes.VocabularyIndex(160_000, 262_144) = .{};
var merges: indexes.MergeIndex(262_144, 512) = .{};
var tokens: [limits.context]u32 = undefined;
var fused_logits: [limits.vocabulary]f32 = undefined;
const phase_count = @intFromEnum(executor.TokenPhase.complete) + 1;
const Timing = struct { count: u64 = 0, total_ns: u64 = 0, maximum_ns: u64 = 0, over_2ms: u64 = 0 };
var timings: [phase_count]Timing = @splat(.{});

const Memory = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, len: usize, alignment: usize) ?[*]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or len > self.bytes.len - offset or alignment == 0) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Memory) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};

fn execute(io: std.Io, source: gguf.Source, token: u32, position: usize, logits: bool, rows: u32) !?u32 {
    var session: executor.TokenSession = .{};
    try executor.beginToken(capacity, limits, &index, &plan, &kv, limits.context, &session, token, position, logits, .fused, .{});
    while (true) {
        const phase = session.phase;
        const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const result = try executor.stepToken(capacity, limits, source, &index, &plan, &work, &kv, limits.context, &session, rows, .{});
        const elapsed: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds - start));
        const timing = &timings[@intFromEnum(phase)];
        timing.count += 1;
        timing.total_ns += elapsed;
        timing.maximum_ns = @max(timing.maximum_ns, elapsed);
        timing.over_2ms += @intFromBool(elapsed > 2_000_000);
        switch (result) { .pending => {}, .complete => |selected| return selected }
    }
}

pub fn main(init: std.process.Init) !void {
    // Windows's native iterator reuses its buffer, so copy arguments as read.
    var argv_buffer: [32768]u8 = undefined;
    var argv = process.Argv_Iterator.init(init.minimal.args.vector, &argv_buffer);
    _ = try argv.next();
    var path_buffer: [4096]u8 = undefined;
    const raw_path = try argv.next() orelse return error.ExpectedModelPath;
    if (raw_path.len > path_buffer.len) return error.ModelPathTooLong;
    @memcpy(path_buffer[0..raw_path.len], raw_path);
    const path = path_buffer[0..raw_path.len];
    var prompt_buffer: [4096]u8 = undefined;
    const raw_prompt = try argv.next() orelse return error.ExpectedPrompt;
    if (raw_prompt.len > prompt_buffer.len) return error.PromptTooLong;
    @memcpy(prompt_buffer[0..raw_prompt.len], raw_prompt);
    const prompt = prompt_buffer[0..raw_prompt.len];
    const maximum = if (try argv.next()) |value| try std.fmt.parseInt(usize, value, 10) else 32;
    const rows = if (try argv.next()) |value| try std.fmt.parseInt(u32, value, 10) else 32;
    if (argv.skip() or maximum == 0 or maximum > limits.context or rows == 0) return error.InvalidArguments;
    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const size = try file.length(init.io);
    if (size > ~@as(usize, 0)) return error.ModelTooLarge;
    var mapping = try file.createMemoryMap(init.io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(init.io);
    if (mapping.section == null) return error.NativeMappingRequired;
    const memory = Memory{ .bytes = mapping.memory };
    const source = memory.source();
    try gguf.parse(capacity, source, &index);
    try plan_mod.build(capacity, &index, &plan);
    if (try executor.requiredKvElements(plan, limits.context) != kv.len) return error.ModelProfileMismatch;
    if (std.mem.eql(u8, prompt, "--parity")) {
        const selected = try execute(init.io, source, 0, 0, true, rows);
        @memcpy(&fused_logits, &work.logits);
        const digest = sha256.hash(std.mem.sliceAsBytes(fused_logits[0..plan.vocabulary_size]));
        work = .{};
        @memset(&kv, 0);
        const reference = try executor.forwardWithKernels(capacity, limits, source, &index, &plan, &work, &kv, limits.context, 0, 0, true, .scalar_reference, .{});
        if (selected == null or reference != selected) return error.ArgmaxMismatch;
        var maximum_error: f32 = 0;
        for (fused_logits[0..plan.vocabulary_size], work.logits[0..plan.vocabulary_size]) |a, b|
            maximum_error = @max(maximum_error, @abs(a - b));
        if (!std.math.isFinite(maximum_error) or maximum_error > 0.0001) return error.NumericalParityFailure;
        var output_buffer: [1024]u8 = undefined;
        var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
        const out = &output_writer.interface;
        try out.print("parity token=0 selected={d} max_abs={d:.9} fused_logits_sha256=", .{ selected.?, maximum_error });
        for (digest) |byte| try out.print("{x:0>2}", .{byte});
        try out.writeByte('\n');
        try out.flush();
        return;
    }
    try vocabulary.build(source, index.summary.tokenizer_tokens);
    try merges.build(source, index.summary.tokenizer_merges, &vocabulary);
    const prompt_count = try tokenizer.encodeChatTurn(source, &vocabulary, &merges, "SB0 Nexus.", prompt, false, &tokens);
    if (prompt_count == 0 or prompt_count + maximum > tokens.len) return error.ContextCapacity;
    const end = vocabulary.lookup(source, "<|im_end|>") orelse return error.MissingStopToken;
    const eos = vocabulary.lookup(source, "<|endoftext|>") orelse return error.MissingStopToken;
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;
    try out.print("profile layers={d} prompt_tokens={d} context={d} rows={d} work_bytes={d} kv_bytes={d}\n", .{ plan.layer_count, prompt_count, limits.context, rows, @sizeOf(@TypeOf(work)), @sizeOf(@TypeOf(kv)) });
    try out.flush();
    const start = std.Io.Timestamp.now(init.io, .awake).nanoseconds;
    var selected: ?u32 = null;
    for (tokens[0..prompt_count], 0..) |token, position| {
        selected = try execute(init.io, source, token, position, position + 1 == prompt_count, rows);
    }
    const prefill_ns = std.Io.Timestamp.now(init.io, .awake).nanoseconds - start;
    try out.writeAll("response=");
    var generated: usize = 0;
    var scratch: [512]u8 = undefined;
    var decoded: [512]u8 = undefined;
    var stopped = false;
    while (generated < maximum) {
        const token = selected orelse return error.MissingLogits;
        if (token == end or token == eos) { stopped = true; break; }
        tokens[prompt_count + generated] = token;
        const text = try tokenizer.decodeToken(source, &vocabulary, token, &scratch, &decoded);
        if (text.control) return error.UnexpectedControlToken;
        try out.writeAll(decoded[0..text.bytes_written]);
        try out.flush();
        generated += 1;
        if (generated < maximum) selected = try execute(init.io, source, token, prompt_count + generated - 1, true, rows);
    }
    const total_ns = std.Io.Timestamp.now(init.io, .awake).nanoseconds - start;
    try out.print("\nresult generated={d} stopped={any} prefill_ms={d} total_ms={d}\n", .{ generated, stopped, @divTrunc(prefill_ns, 1_000_000), @divTrunc(total_ns, 1_000_000) });
    for (timings, 0..) |timing, i| {
        if (timing.count == 0) continue;
        try out.print("phase={s} count={d} mean_ns={d} max_ns={d} over_2ms={d}\n", .{ @tagName(@as(executor.TokenPhase, @enumFromInt(i))), timing.count, timing.total_ns / timing.count, timing.maximum_ns, timing.over_2ms });
    }
    try out.flush();
}
