//! Real-model LFM3 runner for host parity and speed checks.
//! Host I/O only maps the model, reads arguments, owns worker threads, records
//! time and writes output. Tokens, model arithmetic and state come from ZPM.
//!
//!   lfm3-run <model.gguf> tokens <text>
//!   lfm3-run <model.gguf> chat <threads> <max_new> <prompt>
//!   lfm3-run <model.gguf> raw <threads> <max_new> <text>
//!   lfm3-run <model.gguf> bench <threads> <prompt_tokens> <generated_tokens>
const std = @import("std");
const process = @import("sig_process");
const gguf = @import("gguf");
const plan_mod = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const codec = @import("lfm3_tokenizer");
const indexes = @import("tokenizer_index");
const worker = @import("worker_thread");

const capacity = 512;
const limits = executor.lfm3_audio_2b_limits;
const MAX_ATTENTION_LAYERS = 16;
const MAX_CONV_ROWS = 24 * 8;
const MAX_WORKERS = 64;

var index: gguf.Index(capacity) = .{};
var plan: plan_mod.Plan = .{};
var work: executor.Workspace(limits) = .{};
var kv_storage: [MAX_ATTENTION_LAYERS * 2 * 4 * limits.context * 128]u16 = @splat(0);
var conv_storage: [MAX_CONV_ROWS * limits.hidden]f32 = @splat(0);
var vocabulary: indexes.VocabularyIndex(160_000, 262_144) = .{};
var merges: indexes.MergeIndex(524_288, 512) = .{};
var specials: codec.SpecialTokens = .{};
var tokens: [limits.context]u32 = undefined;
var text_buffer: [16384]u8 = undefined;
var pool: Pool = .{};

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

/// Spin-then-sleep worker pool. Workers claim fixed-size chunks from a shared
/// counter, so faster cores take more of a task. The caller works too.
const Pool = struct {
    threads: [MAX_WORKERS]worker.Thread = @splat(.{}),
    count: usize = 0,
    generation: std.atomic.Value(u32) = .init(0),
    pending: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    next: std.atomic.Value(usize) = .init(0),
    task: ?*const executor.Task = null,
    chunk: usize = 1,
    stopping: bool = false,

    fn start(self: *Pool, workers: usize) !void {
        self.count = workers;
        for (self.threads[0..workers]) |*thread| try thread.start(&workerMain, self);
    }

    fn stop(self: *Pool) void {
        self.stopping = true;
        self.pending.store(@intCast(self.count), .seq_cst);
        _ = self.generation.fetchAdd(1, .seq_cst);
        worker.wakeAll(&self.generation);
        for (self.threads[0..self.count]) |*thread| thread.join() catch {};
    }

    fn parallel(self: *Pool) executor.Parallel {
        return .{ .context = self, .dispatch = &dispatch };
    }

    fn dispatch(context: *anyopaque, task: *const executor.Task) void {
        const self: *Pool = @ptrCast(@alignCast(context));
        if (self.count == 0 or task.count < 2) return task.execute(task.context, 0, task.count);
        self.task = task;
        self.chunk = @max(1, task.count / ((self.count + 1) * 4));
        self.next.store(0, .seq_cst);
        self.pending.store(@intCast(self.count), .seq_cst);
        _ = self.generation.fetchAdd(1, .seq_cst);
        if (self.sleepers.load(.seq_cst) != 0) worker.wakeAll(&self.generation);
        self.drain(task);
        while (self.pending.load(.acquire) != 0) std.atomic.spinLoopHint();
    }

    fn drain(self: *Pool, task: *const executor.Task) void {
        while (true) {
            const first = self.next.fetchAdd(self.chunk, .acq_rel);
            if (first >= task.count) return;
            task.execute(task.context, first, @min(task.count, first + self.chunk));
        }
    }

    fn workerMain(raw: ?*anyopaque) void {
        const self: *Pool = @ptrCast(@alignCast(raw.?));
        var seen: u32 = 0;
        while (true) {
            var spins: u32 = 0;
            while (self.generation.load(.acquire) == seen) {
                spins += 1;
                if (spins < 200_000) {
                    std.atomic.spinLoopHint();
                } else {
                    _ = self.sleepers.fetchAdd(1, .seq_cst);
                    worker.waitForChange(&self.generation, seen, 50);
                    _ = self.sleepers.fetchSub(1, .seq_cst);
                }
            }
            seen = self.generation.load(.acquire);
            if (self.stopping) {
                _ = self.pending.fetchSub(1, .acq_rel);
                return;
            }
            self.drain(self.task.?);
            _ = self.pending.fetchSub(1, .acq_rel);
        }
    }
};

fn now(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn milliseconds(nanoseconds: i96) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}

fn printIds(out: anytype, label: []const u8, ids: []const u32) !void {
    try out.print("{s}=", .{label});
    for (ids, 0..) |id, position| try out.print("{s}{d}", .{ if (position == 0) "" else ",", id });
    try out.writeByte('\n');
}

fn printTop(out: anytype, step: usize, token: u32) !void {
    var best: [5]u32 = @splat(0);
    var found: usize = 0;
    const logits = work.logits[0..plan.vocabulary_size];
    for (logits, 0..) |value, id| {
        var slot = found;
        while (slot > 0 and value > logits[best[slot - 1]]) : (slot -= 1) {}
        if (slot >= best.len) continue;
        var move: usize = @min(found, best.len - 1);
        while (move > slot) : (move -= 1) best[move] = best[move - 1];
        best[slot] = @intCast(id);
        found = @min(found + 1, best.len);
    }
    try out.print("step={d} token={d} top=", .{ step, token });
    for (best[0..found], 0..) |id, position| try out.print("{s}{d}:{d:.4}", .{ if (position == 0) "" else ",", id, logits[id] });
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var argv_buffer: [32768]u8 = undefined;
    var argv = process.Argv_Iterator.init(init.minimal.args.vector, &argv_buffer);
    _ = try argv.next();
    var path_buffer: [4096]u8 = undefined;
    const raw_path = try argv.next() orelse return error.ExpectedModelPath;
    if (raw_path.len > path_buffer.len) return error.ModelPathTooLong;
    @memcpy(path_buffer[0..raw_path.len], raw_path);
    const path = path_buffer[0..raw_path.len];
    var mode_buffer: [16]u8 = undefined;
    const raw_mode = try argv.next() orelse return error.ExpectedMode;
    if (raw_mode.len > mode_buffer.len) return error.InvalidArguments;
    @memcpy(mode_buffer[0..raw_mode.len], raw_mode);
    const mode = mode_buffer[0..raw_mode.len];
    var numbers: [3]usize = @splat(0);
    const numeric = !std.mem.eql(u8, mode, "tokens");
    const numeric_count: usize = if (std.mem.eql(u8, mode, "bench")) 3 else if (numeric) 2 else 0;
    for (numbers[0..numeric_count]) |*number| {
        const value = try argv.next() orelse return error.InvalidArguments;
        number.* = try std.fmt.parseInt(usize, value, 10);
    }
    var input_buffer: [8192]u8 = undefined;
    var input: []const u8 = "";
    if (!std.mem.eql(u8, mode, "bench")) {
        const raw_input = try argv.next() orelse return error.ExpectedText;
        if (raw_input.len > 1 and raw_input[0] == '@') {
            // `@path` reads the text verbatim, avoiding command-line quoting.
            input = try std.Io.Dir.cwd().readFile(init.io, raw_input[1..], &input_buffer);
            if (input.len == input_buffer.len) return error.TextTooLong;
        } else {
            if (raw_input.len > input_buffer.len) return error.TextTooLong;
            @memcpy(input_buffer[0..raw_input.len], raw_input);
            input = input_buffer[0..raw_input.len];
        }
    }
    if (argv.skip()) return error.InvalidArguments;

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const size = try file.length(init.io);
    var mapping = try file.createMemoryMap(init.io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(init.io);
    if (mapping.section == null) return error.NativeMappingRequired;
    const memory = Memory{ .bytes = mapping.memory };
    const source = memory.source();
    try gguf.parse(capacity, source, &index);
    try plan_mod.build(capacity, source, &index, &plan);
    try vocabulary.build(source, index.summary.tokenizer_tokens);
    try merges.build(source, index.summary.tokenizer_merges, &vocabulary);
    try specials.build(source, index.summary.tokenizer_token_types, &vocabulary);

    var output_buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;

    if (std.mem.eql(u8, mode, "tokens")) {
        const count = try codec.encode(source, &vocabulary, &merges, &specials, input, true, &tokens);
        try printIds(out, "ids", tokens[0..count]);
        try out.flush();
        return;
    }

    const threads = @max(numbers[0], 1);
    if (threads > MAX_WORKERS + 1) return error.InvalidArguments;
    try pool.start(threads - 1);
    defer pool.stop();
    const parallel = pool.parallel();
    var cache = executor.Cache{
        .kv = kv_storage[0..try executor.requiredKvElements(&plan, limits.context)],
        .conv = conv_storage[0..try executor.requiredConvElements(&plan)],
        .context = limits.context,
    };
    cache.reset();
    try out.print("profile layers={d} conv={d} attention={d} threads={d} work_bytes={d} kv_bytes={d}\n", .{
        plan.layer_count, plan.conv_layer_count, plan.attention_layer_count, threads,
        @sizeOf(@TypeOf(work)), cache.kv.len * 2,
    });

    if (std.mem.eql(u8, mode, "bench")) {
        const prompt_count = numbers[1];
        const generate_count = numbers[2];
        if (prompt_count == 0 or prompt_count + generate_count > limits.context) return error.ContextCapacity;
        for (tokens[0..prompt_count], 0..) |*token, position| token.* = @intCast(1000 + (position * 7919) % 100_000);
        // Warm the page cache and branch predictors once, as llama-bench does.
        _ = try executor.prefill(capacity, limits, source, &index, &plan, &work, &cache, tokens[0..@min(prompt_count, 16)], parallel);
        cache.reset();
        const prompt_start = now(init.io);
        var selected = try executor.prefill(capacity, limits, source, &index, &plan, &work, &cache, tokens[0..prompt_count], parallel);
        const prompt_ns = now(init.io) - prompt_start;
        const generate_start = now(init.io);
        for (0..generate_count) |_| {
            selected = (try executor.forward(capacity, limits, source, &index, &plan, &work, &cache, &.{selected}, true, parallel)).?;
        }
        const generate_ns = now(init.io) - generate_start;
        try out.print("bench threads={d} pp={d} pp_ms={d:.1} pp_tps={d:.2} tg={d} tg_ms={d:.1} tg_tps={d:.2}\n", .{
            threads, prompt_count, milliseconds(prompt_ns), @as(f64, @floatFromInt(prompt_count)) * 1000.0 / milliseconds(prompt_ns),
            generate_count, milliseconds(generate_ns), @as(f64, @floatFromInt(generate_count)) * 1000.0 / milliseconds(generate_ns),
        });
        try out.flush();
        return;
    }

    const maximum = numbers[1];
    const prompt_text = if (std.mem.eql(u8, mode, "chat")) block: {
        const length = try codec.renderChat(&.{.{ .role = .user, .content = input }}, .{}, &text_buffer);
        break :block text_buffer[0..length];
    } else input;
    const prompt_count = try codec.encode(source, &vocabulary, &merges, &specials, prompt_text, true, &tokens);
    if (prompt_count == 0 or prompt_count + maximum > limits.context) return error.ContextCapacity;
    try printIds(out, "prompt_ids", tokens[0..prompt_count]);
    const end_turn = vocabulary.lookup(source, "<|im_end|>") orelse return error.MissingStopToken;
    const end_text = vocabulary.lookup(source, "<|endoftext|>") orelse return error.MissingStopToken;

    const prompt_start = now(init.io);
    var selected = try executor.prefill(capacity, limits, source, &index, &plan, &work, &cache, tokens[0..prompt_count], parallel);
    const prompt_ns = now(init.io) - prompt_start;
    try printTop(out, 0, selected);
    var generated: usize = 0;
    var generate_ns: i96 = 0;
    while (generated < maximum) {
        tokens[prompt_count + generated] = selected;
        generated += 1;
        if (selected == end_turn or selected == end_text or generated == maximum) break;
        const step_start = now(init.io);
        selected = (try executor.forward(capacity, limits, source, &index, &plan, &work, &cache, &.{selected}, true, parallel)).?;
        generate_ns += now(init.io) - step_start;
        try printTop(out, generated, selected);
    }
    try printIds(out, "generated_ids", tokens[prompt_count..][0..generated]);
    try out.writeAll("text=");
    var scratch: [512]u8 = undefined;
    var decoded: [512]u8 = undefined;
    for (tokens[prompt_count..][0..generated]) |token| {
        const piece = try codec.decode(source, &vocabulary, &specials, token, &scratch, &decoded);
        try out.writeAll(decoded[0..piece.bytes_written]);
    }
    const steps = generated - 1;
    try out.print("\ntiming prompt_tokens={d} prompt_ms={d:.1} prompt_tps={d:.2} decode_steps={d} decode_ms={d:.1} decode_tps={d:.2}\n", .{
        prompt_count, milliseconds(prompt_ns), @as(f64, @floatFromInt(prompt_count)) * 1000.0 / milliseconds(prompt_ns),
        steps, milliseconds(generate_ns), if (steps == 0) 0 else @as(f64, @floatFromInt(steps)) * 1000.0 / milliseconds(generate_ns),
    });
    try out.flush();
}
