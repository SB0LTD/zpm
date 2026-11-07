//! Real-model LFM3 runner for host parity and speed checks.
//! Host I/O only maps the model, reads arguments, owns worker threads, records
//! time and writes output. Tokens, model arithmetic and state come from ZPM.
//!
//!   lfm3-run <model.gguf> tokens <text>
//!   lfm3-run <model.gguf> chat <threads> <max_new> <prompt>
//!   lfm3-run <model.gguf> raw <threads> <max_new> <text>
//!   lfm3-run <model.gguf> bench <threads> <prompt_tokens> <generated_tokens>
//!   lfm3-run <model.gguf> asr <threads> <max_new> <mmproj.gguf> <16k-mono.wav> [dump_prefix]
//!   lfm3-run <model.gguf> tts <threads> <max_frames> <mmproj.gguf> <female|male> <seed> <greedy|sample> <out.f32> <text>
//!   lfm3-run <model.gguf> tts-forced <threads> 0 <mmproj.gguf> <seed> <reference_prefix> <out.f32>
//!
//! asr prints the prompt ids, the greedy transcript and timings; with a dump
//! prefix it writes the mel frames, the audio rows and the first encoder
//! chunk's traced layers (llama.cpp's tensor names) as raw f32. tts writes
//! raw f32 PCM at 24 kHz and `<out>.h.bin`, the text model's hidden state of
//! every frame. tts-forced replays a llama.cpp harness run (`<ref>.txt`,
//! `<ref>.h.bin`, `<ref>.pcm.f32`): its hidden states and codes in, codes
//! and waveform compared, the codec's first twelve frames traced next to
//! `<out>`.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("sig_process");
const gguf = @import("gguf");
const plan_mod = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const codec = @import("lfm3_tokenizer");
const indexes = @import("tokenizer_index");
const worker = @import("worker_thread");
const mel = @import("lfm3_audio_mel");
const encoder = @import("lfm3_audio_encoder");
const speech = @import("lfm3_audio_gen");

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
var packed_storage: [1200 << 20]u8 align(64) = undefined;
var weights: executor.PackedWeights(capacity) = .{};
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

const Win = struct {
    extern "kernel32" fn SetProcessInformation(?*anyopaque, u32, *const anyopaque, u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessAffinityMask(?*anyopaque, *usize, *usize) callconv(.winapi) c_int;
};
const process_power_throttling = 4;

/// Spin-then-sleep worker pool. Workers claim fixed-size chunks from a shared
/// counter, so faster cores take more of a task. The caller works too, and
/// returns once every chunk is done: a worker that wakes late, or is
/// descheduled while idle, holds up only the chunk it claimed, if any.
const Pool = struct {
    threads: [MAX_WORKERS]worker.Thread = @splat(.{}),
    count: usize = 0,
    task: ?*const executor.Task = null,
    chunk: usize = 1,
    stopping: bool = false,
    // More threads than CPUs: a descheduled chunk owner may be ready behind
    // a spinning thread, so spinners yield. On dedicated CPUs a yield only
    // hands time to background work (3-10% of 24-thread prefill here).
    share_cpus: bool = false,
    // Spinning workers read `generation` while claims hit `next` and
    // completions hit `done`: one cache line each, or they ping-pong.
    generation: std.atomic.Value(u32) align(64) = .init(0),
    // (chunks << 32) | next chunk. A claim adds one, so a worker that wakes
    // late either takes a chunk of the current task or overshoots harmlessly.
    // `task` and `chunk` change only while no chunk is claimed and unfinished.
    next: std.atomic.Value(u64) align(64) = .init(0),
    done: std.atomic.Value(u32) align(64) = .init(0),
    sleepers: std.atomic.Value(u32) align(64) = .init(0),

    fn start(self: *Pool, workers: usize) !void {
        runAtFullSpeed();
        self.count = workers;
        self.share_cpus = workers + 1 > availableCpus();
        for (self.threads[0..workers]) |*thread| try thread.start(&workerMain, self);
    }

    fn availableCpus() usize {
        if (builtin.os.tag == .windows) {
            var process_mask: usize = 0;
            var system_mask: usize = 0;
            if (Win.GetProcessAffinityMask(std.os.windows.GetCurrentProcess(), &process_mask, &system_mask) == 0) return MAX_WORKERS + 1;
            return @popCount(process_mask);
        }
        return std.Thread.getCpuCount() catch MAX_WORKERS + 1;
    }

    /// Windows 11 power management throttles a background process after a few
    /// seconds of work: on the i9-14900HX it packed every thread onto the
    /// E-cores while the P-cores idled (24 threads on 16 cores). Opt out of
    /// execution-speed throttling, as ggml does per thread.
    fn runAtFullSpeed() void {
        if (builtin.os.tag != .windows) return;
        // PROCESS_POWER_THROTTLING_STATE: version 1, EXECUTION_SPEED controlled, state off.
        const state = [3]u32{ 1, 1, 0 };
        _ = Win.SetProcessInformation(std.os.windows.GetCurrentProcess(), process_power_throttling, &state, @sizeOf(@TypeOf(state)));
    }

    fn stop(self: *Pool) void {
        self.stopping = true;
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
        std.debug.assert(task.count <= std.math.maxInt(u32));
        self.task = task;
        self.chunk = @max(1, task.count / ((self.count + 1) * 4));
        const chunks: u32 = @intCast((task.count + self.chunk - 1) / self.chunk);
        self.done.store(0, .monotonic);
        self.next.store(@as(u64, chunks) << 32, .release);
        _ = self.generation.fetchAdd(1, .seq_cst);
        if (self.sleepers.load(.seq_cst) != 0) worker.wakeAll(&self.generation);
        self.drain();
        var spins: u32 = 0;
        while (self.done.load(.acquire) != chunks) : (spins +%= 1) self.relax(spins);
    }

    fn drain(self: *Pool) void {
        while (true) {
            const claim = self.next.fetchAdd(1, .acq_rel);
            const ordinal: u32 = @truncate(claim);
            if (ordinal >= claim >> 32) return;
            const task = self.task.?;
            const first = ordinal * self.chunk;
            task.execute(task.context, first, @min(task.count, first + self.chunk));
            _ = self.done.fetchAdd(1, .release);
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
                    self.relax(spins);
                } else {
                    _ = self.sleepers.fetchAdd(1, .seq_cst);
                    worker.waitForChange(&self.generation, seen, 50);
                    _ = self.sleepers.fetchSub(1, .seq_cst);
                }
            }
            seen = self.generation.load(.acquire);
            if (self.stopping) return;
            self.drain();
        }
    }

    /// One busy-wait step; past a short spin on shared CPUs, yield now and then.
    fn relax(self: *const Pool, spins: u32) void {
        if (!self.share_cpus or spins < 2048 or spins % 64 != 0) return std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
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
    if (std.mem.eql(u8, mode, "asr") or std.mem.eql(u8, mode, "tts") or std.mem.eql(u8, mode, "tts-forced")) return audioMain(init, &argv, path, mode);
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
    const pack_start = now(init.io);
    try executor.packWeights(capacity, source, &index, &plan, &packed_storage, &weights, parallel);
    const pack_ns = now(init.io) - pack_start;
    var cache = executor.Cache{
        .kv = kv_storage[0..try executor.requiredKvElements(&plan, limits.context)],
        .conv = conv_storage[0..try executor.requiredConvElements(&plan)],
        .context = limits.context,
    };
    cache.reset();
    try out.print("profile layers={d} conv={d} attention={d} threads={d} work_bytes={d} kv_bytes={d} packed_bytes={d} pack_ms={d:.1}\n", .{
        plan.layer_count, plan.conv_layer_count, plan.attention_layer_count, threads,
        @sizeOf(@TypeOf(work)), cache.kv.len * 2, weights.bytes.len, milliseconds(pack_ns),
    });

    if (std.mem.eql(u8, mode, "bench")) {
        const prompt_count = numbers[1];
        const generate_count = numbers[2];
        if (prompt_count == 0 or prompt_count + generate_count > limits.context) return error.ContextCapacity;
        for (tokens[0..prompt_count], 0..) |*token, position| token.* = @intCast(1000 + (position * 7919) % 100_000);
        // Warm the page cache and branch predictors once, as llama-bench does.
        _ = try executor.prefill(capacity, limits, source, &index, &plan, &weights, &work, &cache, tokens[0..@min(prompt_count, 16)], parallel);
        cache.reset();
        const prompt_start = now(init.io);
        var selected = try executor.prefill(capacity, limits, source, &index, &plan, &weights, &work, &cache, tokens[0..prompt_count], parallel);
        const prompt_ns = now(init.io) - prompt_start;
        const generate_start = now(init.io);
        for (0..generate_count) |_| {
            selected = (try executor.forward(capacity, limits, source, &index, &plan, &weights, &work, &cache, &.{selected}, true, parallel)).?;
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
    var selected = try executor.prefill(capacity, limits, source, &index, &plan, &weights, &work, &cache, tokens[0..prompt_count], parallel);
    const prompt_ns = now(init.io) - prompt_start;
    try printTop(out, 0, selected);
    var generated: usize = 0;
    var generate_ns: i96 = 0;
    while (generated < maximum) {
        tokens[prompt_count + generated] = selected;
        generated += 1;
        if (selected == end_turn or selected == end_text or generated == maximum) break;
        const step_start = now(init.io);
        selected = (try executor.forward(capacity, limits, source, &index, &plan, &weights, &work, &cache, &.{selected}, true, parallel)).?;
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

// ── LFM3-Audio: hearing and speaking ────────────────────────────────────────

const audio_capacity = 512;
const audio_limits = encoder.lfm3_audio_limits;
const MAX_SAMPLES = 16_000 * 120;
const MAX_FRAMES = mel.frameCount(MAX_SAMPLES);
const MAX_ROWS = encoder.positionsFor(MAX_FRAMES);

var audio_index: gguf.Index(audio_capacity) = .{};
var audio_plan: encoder.Plan = .{};
var audio_state: encoder.State(audio_limits) = .{};
var audio_work: encoder.Workspace(audio_limits) = .{};
var mel_work: mel.Workspace = .{};
var samples: [MAX_SAMPLES]f32 = undefined;
var mel_frames: [MAX_FRAMES * mel.MELS]f32 = undefined;
var audio_rows: [MAX_ROWS * audio_limits.projection]f32 = undefined;
var wav_buffer: [MAX_SAMPLES * 2 + 4096]u8 = undefined;

const Mapped = struct {
    file: std.Io.File,
    mapping: std.Io.File.MemoryMap,
    memory: Memory,

    fn open(io: std.Io, path: []const u8) !Mapped {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const size = try file.length(io);
        const mapping = try file.createMemoryMap(io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
        if (mapping.section == null) return error.NativeMappingRequired;
        return .{ .file = file, .mapping = mapping, .memory = .{ .bytes = mapping.memory } };
    }

    fn close(self: *Mapped, io: std.Io) void {
        self.mapping.destroy(io);
        self.file.close(io);
    }
};

/// 16-bit PCM samples of a WAV's "data" chunk as f32 (x / 32768, as
/// miniaudio converts them); the format must be mono at `rate`.
fn pcm16Mono(bytes: []const u8, rate: u32, out: []f32) !usize {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.NotWav;
    var at: usize = 12;
    var format_ok = false;
    while (at + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        const body = bytes[at + 8 ..][0..@min(size, bytes.len - at - 8)];
        if (std.mem.eql(u8, bytes[at..][0..4], "fmt ")) {
            if (body.len < 16) return error.NotWav;
            const tag = std.mem.readInt(u16, body[0..2], .little);
            const channels = std.mem.readInt(u16, body[2..4], .little);
            const sample_rate = std.mem.readInt(u32, body[4..8], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            if (tag != 1 or channels != 1 or bits != 16 or sample_rate != rate) return error.UnsupportedWavFormat;
            format_ok = true;
        } else if (std.mem.eql(u8, bytes[at..][0..4], "data")) {
            if (!format_ok) return error.NotWav;
            const count = body.len / 2;
            if (count > out.len) return error.AudioTooLong;
            for (out[0..count], 0..) |*value, i| value.* = @as(f32, @floatFromInt(std.mem.readInt(i16, body[2 * i ..][0..2], .little))) * 0.000030517578125;
            return count;
        }
        at += 8 + size + (size & 1);
    }
    return error.NotWav;
}

/// Feed one input through the backbone in batch-sized slices; only the last
/// slice produces `output`.
fn feed(source: gguf.Source, cache: *executor.Cache, input: executor.Input, output: executor.Output, parallel: executor.Parallel) !?u32 {
    const hidden = plan.hidden_size;
    const total = switch (input) {
        .tokens => |ids| ids.len,
        .embeddings => |rows| rows.len / hidden,
    };
    var start: usize = 0;
    while (true) {
        const end = @min(total, start + limits.batch);
        const slice: executor.Input = switch (input) {
            .tokens => |ids| .{ .tokens = ids[start..end] },
            .embeddings => |rows| .{ .embeddings = rows[start * hidden .. end * hidden] },
        };
        const result = try executor.forwardInput(capacity, limits, source, &index, &plan, &weights, &work, cache, slice, if (end == total) output else .none, parallel);
        if (end == total) return result;
        start = end;
    }
}

fn writeFloats(io: std.Io, prefix: []const u8, suffix: []const u8, values: []const f32) !void {
    var name: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&name, "{s}{s}", .{ prefix, suffix });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = std.mem.sliceAsBytes(values) });
}

fn nextArgument(argv: anytype, buffer: []u8) ![]const u8 {
    const raw = try argv.next() orelse return error.InvalidArguments;
    if (raw.len > buffer.len) return error.InvalidArguments;
    @memcpy(buffer[0..raw.len], raw);
    return buffer[0..raw.len];
}

fn audioMain(init: std.process.Init, argv: anytype, model_path: []const u8, mode: []const u8) !void {
    var threads_buffer: [16]u8 = undefined;
    var maximum_buffer: [16]u8 = undefined;
    var mmproj_buffer: [4096]u8 = undefined;
    const threads = @max(1, try std.fmt.parseInt(usize, try nextArgument(argv, &threads_buffer), 10));
    const maximum = try std.fmt.parseInt(usize, try nextArgument(argv, &maximum_buffer), 10);
    const mmproj_path = try nextArgument(argv, &mmproj_buffer);
    if (threads > MAX_WORKERS + 1) return error.InvalidArguments;

    var model = try Mapped.open(init.io, model_path);
    defer model.close(init.io);
    var projector = try Mapped.open(init.io, mmproj_path);
    defer projector.close(init.io);
    const source = model.memory.source();
    const audio_source = projector.memory.source();
    try gguf.parse(capacity, source, &index);
    try plan_mod.build(capacity, source, &index, &plan);
    try vocabulary.build(source, index.summary.tokenizer_tokens);
    try merges.build(source, index.summary.tokenizer_merges, &vocabulary);
    try specials.build(source, index.summary.tokenizer_token_types, &vocabulary);
    try gguf.parse(audio_capacity, audio_source, &audio_index);

    var output_buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;

    try pool.start(threads - 1);
    defer pool.stop();
    const parallel = pool.parallel();
    try executor.packWeights(capacity, source, &index, &plan, &packed_storage, &weights, parallel);
    var cache = executor.Cache{
        .kv = kv_storage[0..try executor.requiredKvElements(&plan, limits.context)],
        .conv = conv_storage[0..try executor.requiredConvElements(&plan)],
        .context = limits.context,
    };
    cache.reset();

    if (std.mem.eql(u8, mode, "asr")) {
        var wav_path_buffer: [4096]u8 = undefined;
        const wav_path = try nextArgument(argv, &wav_path_buffer);
        var dump_buffer: [1024]u8 = undefined;
        const dump: ?[]const u8 = if (try argv.next()) |raw| blk: {
            if (raw.len > dump_buffer.len) return error.InvalidArguments;
            @memcpy(dump_buffer[0..raw.len], raw);
            break :blk dump_buffer[0..raw.len];
        } else null;
        try hear(init.io, out, source, audio_source, &cache, parallel, wav_path, maximum, dump);
    } else if (std.mem.eql(u8, mode, "tts-forced")) {
        var seed_buffer: [16]u8 = undefined;
        var reference_buffer: [4096]u8 = undefined;
        var path_buffer: [4096]u8 = undefined;
        const seed = try std.fmt.parseInt(u32, try nextArgument(argv, &seed_buffer), 10);
        const reference = try nextArgument(argv, &reference_buffer);
        const pcm_path = try nextArgument(argv, &path_buffer);
        try speakForced(init.io, out, audio_source, parallel, seed, reference, pcm_path);
    } else {
        var voice_buffer: [16]u8 = undefined;
        var seed_buffer: [16]u8 = undefined;
        var how_buffer: [16]u8 = undefined;
        var path_buffer: [4096]u8 = undefined;
        var text_buffer_tts: [2048]u8 = undefined;
        const voice = try nextArgument(argv, &voice_buffer);
        if (!std.mem.eql(u8, voice, "female") and !std.mem.eql(u8, voice, "male")) return error.InvalidArguments;
        const seed = try std.fmt.parseInt(u32, try nextArgument(argv, &seed_buffer), 10);
        const how = try nextArgument(argv, &how_buffer);
        const pcm_path = try nextArgument(argv, &path_buffer);
        const text = try nextArgument(argv, &text_buffer_tts);
        try speak(init.io, out, source, audio_source, &cache, parallel, maximum, voice, seed, std.mem.eql(u8, how, "greedy"), pcm_path, text);
    }
    try out.flush();
}

/// Writes traced rows of the first encoder chunk to `<prefix>.<name>[-<layer>].bin`.
const TraceFiles = struct {
    io: std.Io,
    prefix: []const u8,
    active: bool = true,

    fn emit(context: ?*anyopaque, name: []const u8, layer: ?usize, values: []const f32) void {
        const self: *TraceFiles = @ptrCast(@alignCast(context.?));
        if (!self.active) return;
        var suffix: [96]u8 = undefined;
        const tail = (if (layer) |number| std.fmt.bufPrint(&suffix, ".{s}-{d}.bin", .{ name, number }) else std.fmt.bufPrint(&suffix, ".{s}.bin", .{name})) catch return;
        writeFloats(self.io, self.prefix, tail, values) catch {};
    }
};

fn hear(io: std.Io, out: anytype, source: gguf.Source, audio_source: gguf.Source, cache: *executor.Cache, parallel: executor.Parallel, wav_path: []const u8, maximum: usize, dump: ?[]const u8) !void {
    try encoder.build(audio_capacity, audio_source, &audio_index, &audio_plan);
    const wav = try std.Io.Dir.cwd().readFile(io, wav_path, &wav_buffer);
    const count = try pcm16Mono(wav, mel.SAMPLE_RATE, &samples);
    try out.print("audio samples={d} seconds={d:.2} encoder layers={d} conv={d} attention={d}\n", .{
        count, @as(f64, @floatFromInt(count)) / mel.SAMPLE_RATE, audio_plan.layer_count, audio_plan.conv_layer_count, audio_plan.attention_layer_count,
    });

    const mel_start = now(io);
    const frames = try mel.compute(samples[0..count], &mel_frames, &mel_work);
    const mel_ns = now(io) - mel_start;
    var trace_files = TraceFiles{ .io = io, .prefix = dump orelse "" };
    if (dump != null) audio_work.trace = .{ .context = &trace_files, .emit = &TraceFiles.emit };
    const encode_start = now(io);
    audio_state.reset();
    var rows: usize = 0;
    var first: usize = 0;
    const chunk = encoder.DOWNSAMPLE * audio_limits.positions;
    while (first < frames) {
        const end = @min(frames, first + chunk);
        rows += try encoder.encode(audio_capacity, audio_limits, audio_source, &audio_index, &audio_plan, &audio_state, &audio_work, mel_frames[first * mel.MELS .. end * mel.MELS], audio_rows[rows * audio_plan.projection ..], parallel);
        trace_files.active = false;
        first = end;
    }
    const encode_ns = now(io) - encode_start;
    if (dump) |prefix| {
        try writeFloats(io, prefix, ".mel.bin", mel_frames[0 .. frames * mel.MELS]);
        try writeFloats(io, prefix, ".embd.bin", audio_rows[0 .. rows * audio_plan.projection]);
    }
    if (audio_plan.projection != plan.hidden_size) return error.InvalidModel;

    // Galaxy's hearing request: the instruction as the system turn, the audio
    // alone as the user's turn.
    const prefix_text = "<|startoftext|><|im_start|>system\nPerform ASR in English.<|im_end|>\n<|im_start|>user\n";
    const suffix_text = "<|im_end|>\n<|im_start|>assistant\n";
    var prefix_ids: [64]u32 = undefined;
    var suffix_ids: [16]u32 = undefined;
    const prefix_count = try codec.encode(source, &vocabulary, &merges, &specials, prefix_text, true, &prefix_ids);
    const suffix_count = try codec.encode(source, &vocabulary, &merges, &specials, suffix_text, true, &suffix_ids);
    try printIds(out, "prefix_ids", prefix_ids[0..prefix_count]);
    try out.print("audio_rows={d}\n", .{rows});
    try printIds(out, "suffix_ids", suffix_ids[0..suffix_count]);
    if (prefix_count + rows + suffix_count + maximum > limits.context) return error.ContextCapacity;

    const prompt_start = now(io);
    _ = try feed(source, cache, .{ .tokens = prefix_ids[0..prefix_count] }, .none, parallel);
    _ = try feed(source, cache, .{ .embeddings = audio_rows[0 .. rows * plan.hidden_size] }, .none, parallel);
    var selected = (try feed(source, cache, .{ .tokens = suffix_ids[0..suffix_count] }, .logits, parallel)).?;
    const prompt_ns = now(io) - prompt_start;
    const end_turn = vocabulary.lookup(source, "<|im_end|>") orelse return error.MissingStopToken;
    var generated: usize = 0;
    const decode_start = now(io);
    while (generated < maximum) {
        tokens[generated] = selected;
        generated += 1;
        if (selected == end_turn or generated == maximum) break;
        selected = (try executor.forward(capacity, limits, source, &index, &plan, &weights, &work, cache, &.{selected}, true, parallel)).?;
    }
    const decode_ns = now(io) - decode_start;
    try printIds(out, "generated_ids", tokens[0..generated]);
    try out.writeAll("text=");
    var scratch: [512]u8 = undefined;
    var decoded: [512]u8 = undefined;
    for (tokens[0..generated]) |token| {
        if (token == end_turn) break;
        const piece = try codec.decode(source, &vocabulary, &specials, token, &scratch, &decoded);
        try out.writeAll(decoded[0..piece.bytes_written]);
    }
    try out.print("\ntiming mel_ms={d:.1} encode_ms={d:.1} prompt_tokens={d} prompt_ms={d:.1} decode_steps={d} decode_ms={d:.1}\n", .{
        milliseconds(mel_ns), milliseconds(encode_ns), prefix_count + rows + suffix_count, milliseconds(prompt_ns), generated -| 1, milliseconds(decode_ns),
    });
}

const gen_limits = speech.lfm3_audio_limits;
const MAX_SPOKEN_FRAMES = 1024;
var gen_plan: speech.Plan = .{};
var depth_work: speech.DepthWorkspace(gen_limits) = .{};
var codec_state: speech.CodecState(gen_limits) = .{};
var codec_work: speech.CodecWorkspace(gen_limits) = .{};
var pcm: [MAX_SPOKEN_FRAMES * speech.SAMPLES_PER_FRAME + speech.FFT_SIZE]f32 = undefined;
var hidden_states: [MAX_SPOKEN_FRAMES * 2048]f32 = undefined;
var feedback_row: [2048]f32 = undefined;
var feedback_scratch: [speech.CODEBOOKS * 2048]f32 = undefined;

/// LFM3-Audio's "tts" chat template (lang "en"; voice female or male).
fn ttsPrompt(buffer: []u8, voice: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "<|startoftext|><|im_start|>system\nPerform TTS in American English using a {s} voice.<|im_end|>\n" ++
        "<|im_start|>user\n{s}<|im_end|>\n<|im_start|>assistant\n<|audio_start|>", .{ voice, text });
}

/// Writes every traced call to `<prefix>.<name>.<call>.bin` (llama.cpp
/// harness naming), for the first `limit` calls of each name.
const TraceCalls = struct {
    io: std.Io,
    prefix: []const u8,
    limit: usize,
    names: [4][32]u8 = undefined,
    lengths: [4]usize = @splat(0),
    counts: [4]usize = @splat(0),
    used: usize = 0,

    fn emit(context: ?*anyopaque, name: []const u8, layer: ?usize, values: []const f32) void {
        _ = layer;
        const self: *TraceCalls = @ptrCast(@alignCast(context.?));
        var slot: usize = 0;
        while (slot < self.used and !std.mem.eql(u8, self.names[slot][0..self.lengths[slot]], name)) slot += 1;
        if (slot == self.used) {
            if (self.used == self.names.len or name.len > 32) return;
            @memcpy(self.names[slot][0..name.len], name);
            self.lengths[slot] = name.len;
            self.used += 1;
        }
        const call = self.counts[slot];
        self.counts[slot] += 1;
        if (call >= self.limit) return;
        var suffix: [96]u8 = undefined;
        const tail = std.fmt.bufPrint(&suffix, ".{s}.{d}.bin", .{ name, call }) catch return;
        writeFloats(self.io, self.prefix, tail, values) catch {};
    }
};

fn speak(io: std.Io, out: anytype, source: gguf.Source, audio_source: gguf.Source, cache: *executor.Cache, parallel: executor.Parallel, maximum: usize, voice: []const u8, seed: u32, greedy: bool, pcm_path: []const u8, text: []const u8) !void {
    try speech.build(audio_capacity, audio_source, &audio_index, &gen_plan);
    if (gen_plan.backbone != plan.hidden_size) return error.InvalidModel;
    if (maximum > MAX_SPOKEN_FRAMES) return error.InvalidArguments;
    try out.print("speech depth layers={d} codec layers={d} conv={d} attention={d} vocabulary={d} sampling temp={d:.2} top_k={d} penalty={d:.2}/{d}\n", .{
        gen_plan.depth.layer_count, gen_plan.codec.layer_count, gen_plan.codec.conv_layer_count, gen_plan.codec.attention_layer_count,
        gen_plan.vocabulary, gen_plan.temperature, gen_plan.top_k, gen_plan.penalty, gen_plan.penalty_window,
    });
    var prompt_buffer: [4096]u8 = undefined;
    const prompt = try ttsPrompt(&prompt_buffer, voice, text);
    const prompt_count = try codec.encode(source, &vocabulary, &merges, &specials, prompt, true, &tokens);
    try printIds(out, "prompt_ids", tokens[0..prompt_count]);
    if (prompt_count + maximum + 1 > limits.context) return error.ContextCapacity;

    var sampling = speech.modelSampling(&gen_plan, seed);
    if (greedy) sampling.temperature = 0;
    var speaker = speech.Speaker(gen_limits).init(sampling);
    codec_state.reset();
    const hidden = plan.hidden_size;

    const prompt_start = now(io);
    _ = try feed(source, cache, .{ .tokens = tokens[0..prompt_count] }, .hidden, parallel);
    const prompt_ns = now(io) - prompt_start;
    var h = hidden_states[0..hidden];
    @memcpy(h, work.normalized[0..hidden]);
    var samples_out: usize = 0;
    var frames: usize = 0;
    var ended = false;
    var code_ns: i96 = 0;
    var wav_ns: i96 = 0;
    var back_ns: i96 = 0;
    while (frames < maximum) : (frames += 1) {
        const code_start = now(io);
        const step = try speaker.frame(audio_capacity, audio_source, &audio_index, &gen_plan, &depth_work, h, parallel);
        try out.print("frame={d} codes=", .{frames});
        for (step.codes, 0..) |code, book| try out.print("{s}{d}", .{ if (book == 0) "" else ",", code });
        try out.writeByte('\n');
        if (step.end) {
            code_ns += now(io) - code_start;
            ended = true;
            break;
        }
        try speech.feedback(audio_capacity, audio_source, &audio_index, &gen_plan, &step.codes, &feedback_row, &feedback_scratch);
        code_ns += now(io) - code_start;
        const wav_start = now(io);
        samples_out += try speech.decode(audio_capacity, gen_limits, audio_source, &audio_index, &gen_plan, &codec_state, &codec_work, &step.codes, pcm[samples_out..], parallel);
        wav_ns += now(io) - wav_start;
        const back_start = now(io);
        _ = try feed(source, cache, .{ .embeddings = &feedback_row }, .hidden, parallel);
        back_ns += now(io) - back_start;
        h = hidden_states[(frames + 1) * hidden ..][0..hidden];
        @memcpy(h, work.normalized[0..hidden]);
    }
    samples_out += try speech.finish(gen_limits, &codec_state, pcm[samples_out..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pcm_path, .data = std.mem.sliceAsBytes(pcm[0..samples_out]) });
    try writeFloats(io, pcm_path, ".h.bin", hidden_states[0 .. frames * hidden]);
    try out.print("frames={d} eos={d} samples={d}\n", .{ frames, @intFromBool(ended), samples_out });
    try out.print("timing prompt_tokens={d} prompt_ms={d:.1} code_ms={d:.1} wav_ms={d:.1} backbone_ms={d:.1} audio_s={d:.2}\n", .{
        prompt_count, milliseconds(prompt_ns), milliseconds(code_ns), milliseconds(wav_ns), milliseconds(back_ns),
        @as(f64, @floatFromInt(samples_out)) / speech.SAMPLE_RATE,
    });
}

var reference_text: [1 << 20]u8 = undefined;
var reference_pcm_bytes: [(MAX_SPOKEN_FRAMES * speech.SAMPLES_PER_FRAME + speech.FFT_SIZE) * 4]u8 = undefined;
var reference_hidden_bytes: [MAX_SPOKEN_FRAMES * 2048 * 4]u8 align(4) = undefined;

/// Comma-separated integers after `key=` on `line`.
fn parseList(line: []const u8, key: []const u8, out: []i32) !usize {
    const at = std.mem.indexOf(u8, line, key) orelse return error.InvalidReference;
    var rest = line[at + key.len ..];
    if (std.mem.indexOfAny(u8, rest, " \r")) |end| rest = rest[0..end];
    var count: usize = 0;
    var fields = std.mem.splitScalar(u8, rest, ',');
    while (fields.next()) |field| {
        if (count == out.len) return error.InvalidReference;
        out[count] = try std.fmt.parseInt(i32, field, 10);
        count += 1;
    }
    return count;
}

/// Teacher-forced speech parity against a llama.cpp harness run
/// (`<ref>.txt` frame lines, `<ref>.h.bin` hidden states, `<ref>.pcm.f32`):
/// each frame is sampled from llama.cpp's hidden state with the same reveal
/// order, the history keeps llama.cpp's codes, and llama.cpp's codes are
/// decoded; codes must match exactly and the waveform within tolerance.
const ops_negative: f32 = -std.math.inf(f32);

/// Smallest top-1 minus top-2 logit gaps over every pick of a forced run.
const Margins = struct {
    smallest: [5]f32 = @splat(std.math.inf(f32)),
    count: usize = 0,

    fn record(self: *Margins, gap: f32) void {
        self.count += 1;
        var i: usize = self.smallest.len;
        while (i > 0 and gap < self.smallest[i - 1]) : (i -= 1) {
            if (i < self.smallest.len) self.smallest[i] = self.smallest[i - 1];
        }
        if (i < self.smallest.len) self.smallest[i] = gap;
    }
};
var margins: Margins = .{};

fn speakForced(io: std.Io, out: anytype, audio_source: gguf.Source, parallel: executor.Parallel, seed: u32, reference: []const u8, pcm_path: []const u8) !void {
    try speech.build(audio_capacity, audio_source, &audio_index, &gen_plan);
    var name: [1024]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(io, try std.fmt.bufPrint(&name, "{s}.txt", .{reference}), &reference_text);
    const hidden_bytes = try std.Io.Dir.cwd().readFile(io, try std.fmt.bufPrint(&name, "{s}.h.bin", .{reference}), &reference_hidden_bytes);
    const pcm_bytes = try std.Io.Dir.cwd().readFile(io, try std.fmt.bufPrint(&name, "{s}.pcm.f32", .{reference}), &reference_pcm_bytes);
    const hidden_rows: []const f32 = @as([*]const f32, @ptrCast(@alignCast(hidden_bytes.ptr)))[0 .. hidden_bytes.len / 4];
    const width = gen_plan.backbone;

    var speaker = speech.Speaker(gen_limits).init(.{ .temperature = 0, .top_k = 0, .penalty = gen_plan.penalty, .penalty_window = gen_plan.penalty_window, .seed = seed });
    var order_rng = speech.Mt19937.init(seed);
    var trace_calls = TraceCalls{ .io = io, .prefix = pcm_path, .limit = 12 };
    codec_work.trace = .{ .context = &trace_calls, .emit = &TraceCalls.emit };
    codec_state.reset();
    var frames: usize = 0;
    var matched: usize = 0;
    var order_matched: usize = 0;
    var samples_out: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var start = now(io);
    var code_ns: i96 = 0;
    var wav_ns: i96 = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "frame=")) continue;
        var expected: [speech.CODEBOOKS]i32 = undefined;
        var expected_order: [speech.CODEBOOKS]i32 = undefined;
        if (try parseList(line, "codes=", &expected) != speech.CODEBOOKS) return error.InvalidReference;
        if (try parseList(line, "order=", &expected_order) != speech.CODEBOOKS) return error.InvalidReference;
        if ((frames + 1) * width > hidden_rows.len) return error.InvalidReference;
        const order = speech.frameOrder(&order_rng);
        var same_order = true;
        for (order, expected_order) |a, b| same_order = same_order and a == b;
        order_matched += @intFromBool(same_order);

        start = now(io);
        const step = try speaker.frame(audio_capacity, audio_source, &audio_index, &gen_plan, &depth_work, hidden_rows[frames * width ..][0..width], parallel);
        code_ns += now(io) - start;
        // Logit gaps of the reference's picks: the passes again, revealing
        // llama.cpp's codes, recording top-1 minus the reference code's logit.
        {
            var revealed: [speech.CODEBOOKS]i32 = @splat(-1);
            var at: usize = 0;
            try speech.projectState(audio_capacity, gen_limits, audio_source, &audio_index, &gen_plan, &depth_work, hidden_rows[frames * width ..][0..width], parallel);
            for (speech.SCHEDULE) |count| {
                try speech.codePass(audio_capacity, gen_limits, audio_source, &audio_index, &gen_plan, &depth_work, &revealed, parallel);
                for (0..count) |_| {
                    const book: usize = order[at];
                    at += 1;
                    const logits = depth_work.logits[book * gen_plan.vocabulary ..][0..gen_plan.vocabulary];
                    // The history at this frame already holds this frame's codes when
                    // they did not end the audio; penalize against the frames before.
                    const saved = speaker.frames;
                    if (!step.end) speaker.frames -= 1;
                    speaker.penalize(logits, book);
                    speaker.frames = saved;
                    var best: usize = 0;
                    var second: f32 = ops_negative;
                    for (logits, 0..) |value, code| if (value > logits[best]) {
                        best = code;
                    };
                    for (logits, 0..) |value, code| if (code != best and value > second) {
                        second = value;
                    };
                    const target: usize = @intCast(expected[book]);
                    margins.record(logits[best] - second);
                    if (target != best) try out.print("frame={d} book={d} near-tie: zpm top {d} ({d:.5}) ref {d} ({d:.5}) gap {d:.5}\n", .{ frames, book, best, logits[best], target, logits[target], logits[best] - logits[target] });
                    revealed[book] = expected[book];
                }
            }
        }
        var expected_end = false;
        for (expected) |code| expected_end = expected_end or code == gen_plan.endCode();
        const same = if (expected_end) step.end else std.mem.eql(i32, &step.codes, &expected);
        matched += @intFromBool(same);
        if (!same) {
            try out.print("frame={d} MISMATCH zpm=", .{frames});
            for (step.codes, 0..) |code, book| try out.print("{s}{d}", .{ if (book == 0) "" else ",", code });
            try out.print(" ref=", .{});
            for (expected, 0..) |code, book| try out.print("{s}{d}", .{ if (book == 0) "" else ",", code });
            try out.writeByte('\n');
        }
        frames += 1;
        const end_code = gen_plan.endCode();
        var ended = false;
        for (expected) |code| ended = ended or code == end_code;
        if (ended) break;
        // The history follows llama.cpp's codes.
        if (!step.end and speaker.frames > 0) {
            for (&speaker.history[@min(speaker.frames, gen_limits.history) - 1], expected) |*slot, code| slot.* = @intCast(code);
        }
        if (frames == 1) {
            try speech.feedback(audio_capacity, audio_source, &audio_index, &gen_plan, &expected, &feedback_row, &feedback_scratch);
            try writeFloats(io, pcm_path, ".fb0.bin", &feedback_row);
        }
        start = now(io);
        samples_out += try speech.decode(audio_capacity, gen_limits, audio_source, &audio_index, &gen_plan, &codec_state, &codec_work, &expected, pcm[samples_out..], parallel);
        wav_ns += now(io) - start;
    }
    samples_out += try speech.finish(gen_limits, &codec_state, pcm[samples_out..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pcm_path, .data = std.mem.sliceAsBytes(pcm[0..samples_out]) });

    const reference_pcm: []const f32 = @as([*]const f32, @ptrCast(@alignCast(pcm_bytes.ptr)))[0 .. pcm_bytes.len / 4];
    var error_sum: f64 = 0;
    var signal_sum: f64 = 0;
    var worst: f32 = 0;
    const compared = @min(samples_out, reference_pcm.len);
    for (pcm[0..compared], reference_pcm[0..compared]) |a, b| {
        error_sum += @as(f64, a - b) * (a - b);
        signal_sum += @as(f64, b) * b;
        worst = @max(worst, @abs(a - b));
    }
    try out.print("picks={d} smallest top1-top2 gaps: {d:.4} {d:.4} {d:.4} {d:.4} {d:.4}\n", .{ margins.count, margins.smallest[0], margins.smallest[1], margins.smallest[2], margins.smallest[3], margins.smallest[4] });
    try out.print("forced frames={d} codes_identical={d} order_identical={d} samples zpm={d} ref={d} pcm_max_abs={e:.3} pcm_rel_rms={e:.3} code_ms={d:.1} wav_ms={d:.1}\n", .{
        frames, matched, order_matched, samples_out, reference_pcm.len, worst,
        if (signal_sum > 0) @sqrt(error_sum / signal_sum) else 0, milliseconds(code_ns), milliseconds(wav_ns),
    });
}
