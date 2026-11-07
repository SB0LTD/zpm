//! d1 decision model runner (LiquidAI/d1-2B GGUF) on the host: parity with
//! llama.cpp's `/v1/systemone` and speed checks, and a small HTTP server of
//! the same endpoint for machines that ask it over the network (Galaxy's
//! agent in a QEMU twin asks its host). Host I/O only maps the model, reads
//! arguments, owns worker threads and sockets, records time and writes
//! output; prompts, tokens, arithmetic and answers come from ZPM
//! (d1_system_one, lfm3_executor).
//!
//!   d1-run <model.gguf> ask <threads> <set_size> @request.json
//!   d1-run <model.gguf> serve <threads> <port> [set_size] [address]
//!   d1-run <model.gguf> tokens <text>
//!
//! `ask` prints the answers (the endpoint's JSON) and a timing line. `serve`
//! answers POST /v1/systemone (and GET /health) on 127.0.0.1:<port> (a QEMU
//! twin's user network reaches the host's loopback; another address, such
//! as 0.0.0.0, only when given: the server has no authentication), one
//! request at a time; every answer's compute uses all the threads. A
//! request's own "set_size" overrides the server's (1: each question its own
//! pass, as llama.cpp reads them; 16: d1-2B's trained packing).
const std = @import("std");
const builtin = @import("builtin");
const process = @import("sig_process");
const gguf = @import("gguf");
const plan_mod = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const codec = @import("lfm3_tokenizer");
const indexes = @import("tokenizer_index");
const worker = @import("worker_thread");
const d1 = @import("d1_system_one");

const capacity = 512;
/// One pass holds the state and up to 16 questions: 2048 tokens.
const limits = executor.Limits{
    .hidden = 2048,
    .feed_forward = 7680,
    .query = 2048,
    .key_value = 512,
    .heads = 16,
    .vocabulary = 128_000,
    .batch = 2048,
    .context = 2048,
};
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
var scratch: d1.Scratch(limits) = .{};
var request: d1.Request = undefined;
var answers: [d1.MAX_QUESTIONS]d1.Answer = undefined;
var body_buffer: [256 * 1024]u8 = undefined;
var answer_buffer: [256 * 1024]u8 = undefined;
var token_buffer: [limits.batch]u32 = undefined;
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

/// d1's tokenizer view of the GGUF's codec: markup recognised.
const Tokens = struct {
    source: gguf.Source,
    pub fn encode(self: Tokens, text: []const u8, out: []u32) !usize {
        return codec.encode(self.source, &vocabulary, &merges, &specials, text, true, out);
    }
    pub fn special(_: Tokens, text: []const u8) usize {
        const found = specials.match(text, true) orelse return 0;
        return found.length;
    }
};

/// Spin-then-sleep worker pool (lfm3_run's): workers claim chunks from a
/// shared counter; the caller works too.
const Pool = struct {
    threads: [MAX_WORKERS]worker.Thread = @splat(.{}),
    count: usize = 0,
    task: ?*const executor.Task = null,
    chunk: usize = 1,
    stopping: bool = false,
    share_cpus: bool = false,
    generation: std.atomic.Value(u32) align(64) = .init(0),
    next: std.atomic.Value(u64) align(64) = .init(0),
    done: std.atomic.Value(u32) align(64) = .init(0),
    sleepers: std.atomic.Value(u32) align(64) = .init(0),

    fn start(self: *Pool, workers: usize) !void {
        self.count = workers;
        self.share_cpus = workers + 1 > (std.Thread.getCpuCount() catch MAX_WORKERS + 1);
        for (self.threads[0..workers]) |*thread| try thread.start(&workerMain, self);
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

const Loaded = struct {
    model: d1.Model(capacity),
    cache: executor.Cache,
    tokens: Tokens,
};

/// Answer `body` (a /v1/systemone request); the answer JSON and the time.
fn answer(io: std.Io, loaded: *Loaded, body: []const u8, default_set: usize, elapsed_ms: *f64) ![]const u8 {
    try d1.parseRequest(body, &request);
    const set_size = if (request.set_size != 0) request.set_size else default_set;
    const started = now(io);
    const usage = try d1.ask(capacity, limits, &loaded.model, loaded.tokens, &work, &loaded.cache, &scratch, request.state, request.list(), set_size, &answers, pool.parallel());
    elapsed_ms.* = milliseconds(now(io) - started);
    return d1.writeAnswers(request.list(), &answers, usage, &answer_buffer) orelse error.AnswerTooLong;
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

    var output_buffer: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;

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
    const tokens = Tokens{ .source = source };

    if (std.mem.eql(u8, mode, "tokens")) {
        const text = try argv.next() orelse return error.ExpectedText;
        const count = try tokens.encode(text, &token_buffer);
        try out.writeAll("ids=");
        for (token_buffer[0..count], 0..) |id, i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", id });
        try out.writeByte('\n');
        try out.flush();
        return;
    }

    const threads_text = try argv.next() orelse return error.InvalidArguments;
    const threads = @max(try std.fmt.parseInt(usize, threads_text, 10), 1);
    if (threads > MAX_WORKERS + 1) return error.InvalidArguments;
    try pool.start(threads - 1);
    defer pool.stop();
    const pack_start = now(init.io);
    try executor.packWeights(capacity, source, &index, &plan, &packed_storage, &weights, pool.parallel());
    const pack_ms = milliseconds(now(init.io) - pack_start);
    var loaded = Loaded{
        .model = .{ .source = source, .index = &index, .plan = &plan, .weights = &weights },
        .cache = .{
            .kv = kv_storage[0..try executor.requiredKvElements(&plan, limits.context)],
            .conv = conv_storage[0..try executor.requiredConvElements(&plan)],
            .context = limits.context,
        },
        .tokens = tokens,
    };
    loaded.model.readTemperatures();
    try out.print("profile layers={d} attention={d} threads={d} pack_ms={d:.1} temperature={d:.4}\n", .{
        plan.layer_count, plan.attention_layer_count, threads, pack_ms, loaded.model.temperature[1],
    });
    try out.flush();

    if (std.mem.eql(u8, mode, "ask")) {
        const set_text = try argv.next() orelse return error.InvalidArguments;
        const set_size = try std.fmt.parseInt(usize, set_text, 10);
        const raw = try argv.next() orelse return error.ExpectedText;
        const body = if (raw.len > 1 and raw[0] == '@')
            try std.Io.Dir.cwd().readFile(init.io, raw[1..], &body_buffer)
        else
            raw;
        var elapsed: f64 = 0;
        // Warm the page cache and branch predictors once.
        _ = try answer(init.io, &loaded, body, set_size, &elapsed);
        const warm = elapsed;
        const written = try answer(init.io, &loaded, body, set_size, &elapsed);
        try out.writeAll(written);
        try out.print("\ntiming set_size={d} first_ms={d:.1} warm_ms={d:.1}\n", .{ set_size, warm, elapsed });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, mode, "serve")) {
        const port_text = try argv.next() orelse return error.InvalidArguments;
        const port = try std.fmt.parseInt(u16, port_text, 10);
        const set_size: usize = if (try argv.next()) |s| try std.fmt.parseInt(usize, s, 10) else d1.MAX_SET;
        const bind = (try argv.next()) orelse "127.0.0.1";
        return serve(init.io, &loaded, bind, port, set_size, out);
    }
    return error.InvalidArguments;
}

// ── /v1/systemone over HTTP/1.1 ─────────────────────────────────────────────

var head_buffer: [16 * 1024]u8 = undefined;

fn serve(io: std.Io, loaded: *Loaded, bind: []const u8, port: u16, set_size: usize, out: *std.Io.Writer) !void {
    const address = try std.Io.net.IpAddress.parse(bind, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    try out.print("serving http://{s}:{d}/v1/systemone set_size={d}\n", .{ bind, port, set_size });
    try out.flush();
    while (true) {
        const stream = server.accept(io) catch continue;
        handle(io, loaded, stream, set_size, out) catch |err| {
            out.print("request failed: {s}\n", .{@errorName(err)}) catch {};
            out.flush() catch {};
        };
        stream.close(io);
    }
}

fn handle(io: std.Io, loaded: *Loaded, stream: std.Io.net.Stream, set_size: usize, out: *std.Io.Writer) !void {
    // The head, then as much body as Content-Length says.
    var have: usize = 0;
    var head_end: usize = 0;
    while (head_end == 0) {
        if (have == head_buffer.len) return error.HeadTooLong;
        var parts = [1][]u8{head_buffer[have..]};
        const n = try stream.read(io, &parts);
        if (n == 0) return error.EndOfStream;
        have += n;
        if (std.mem.indexOf(u8, head_buffer[0..have], "\r\n\r\n")) |at| head_end = at + 4;
    }
    const head = head_buffer[0..head_end];
    var length: usize = 0;
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length"))
            length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10);
    }
    if (length > body_buffer.len) return error.BodyTooLong;
    const early = have - head_end;
    @memcpy(body_buffer[0..early], head_buffer[head_end..have]);
    var got = early;
    while (got < length) {
        var parts = [1][]u8{body_buffer[got..length]};
        const n = try stream.read(io, &parts);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    var write_buffer: [4096]u8 = undefined;
    var w = stream.writer(io, &write_buffer);
    if (std.mem.startsWith(u8, request_line, "GET /health")) {
        try respond(&w.interface, "200 OK", "{\"status\":\"ok\"}");
        return;
    }
    if (!std.mem.startsWith(u8, request_line, "POST /v1/systemone")) {
        try respond(&w.interface, "404 Not Found", "{\"error\":\"POST /v1/systemone\"}");
        return;
    }
    var elapsed: f64 = 0;
    const written = answer(io, loaded, body_buffer[0..length], set_size, &elapsed) catch |err| {
        var eb: [128]u8 = undefined;
        const e = std.fmt.bufPrint(&eb, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":true}";
        try respond(&w.interface, "400 Bad Request", e);
        return;
    };
    try respond(&w.interface, "200 OK", written);
    try out.print("answered {d} questions in {d:.1} ms\n", .{ request.question_count, elapsed });
    try out.flush();
}

fn respond(w: *std.Io.Writer, status: []const u8, body: []const u8) !void {
    try w.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    try w.writeAll(body);
    try w.flush();
}
