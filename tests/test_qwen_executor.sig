//! Executable numerical contracts for the public resumable Qwen decoder.
//! Uses bounded F32 tensors; no model download or heap storage is required.
const std = @import("std");
const gguf = @import("gguf");
const qwen = @import("qwen3_decoder_plan");
const executor = @import("qwen3_executor");

const CAPACITY = 32;
const LIMITS = executor.Limits{ .hidden = 4, .query = 8, .key_value = 8,
    .feed_forward = 6, .vocabulary = 7, .context = 4, .row_bytes = 32 };
const Work = executor.WorkingSet(LIMITS);
const KV_COUNT = 2 * 2 * 2 * LIMITS.context * 2;
var assertions: usize = 0;
var executed_cases: usize = 0;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.QwenContractFailed;
}
fn rejected(result: anytype, expected: anyerror) !void {
    if (result) |_| return error.InvalidOperationAccepted else |err| try check(err == expected);
}

const Fixture = struct {
    bytes: [8192]u8 = @splat(0),
    used: usize = 0,
    index: gguf.Index(CAPACITY) = .{},
    plan: qwen.Plan = .{},

    fn initialize(self: *Fixture, tied: bool) !void {
        self.* = .{};
        self.index.summary.architecture[0..5].* = "qwen3".*;
        self.index.summary.architecture_len = 5;
        self.index.summary.embedding_length = 4;
        self.index.summary.block_count = 2;
        self.index.summary.head_count = 4;
        self.index.summary.head_count_kv = 2;
        self.index.summary.attention_key_length = 2;
        self.index.summary.attention_value_length = 2;
        self.index.summary.feed_forward_length = 6;
        self.index.summary.vocab_size = 7;
        self.index.summary.rope_frequency_base = 10000;
        self.index.summary.rms_norm_epsilon = 0.00001;
        try self.add("token_embd.weight", 4, 7, false);
        try self.add("output_norm.weight", 4, 0, true);
        if (!tied) try self.add("output.weight", 4, 7, false);
        for (0..2) |layer| {
            const shapes = .{
                .{ "attn_norm.weight", 4, 0, true },
                .{ "attn_q.weight", 4, 8, false },
                .{ "attn_k.weight", 4, 4, false },
                .{ "attn_v.weight", 4, 4, false },
                .{ "attn_output.weight", 8, 4, false },
                .{ "attn_q_norm.weight", 2, 0, true },
                .{ "attn_k_norm.weight", 2, 0, true },
                .{ "ffn_norm.weight", 4, 0, true },
                .{ "ffn_gate.weight", 4, 6, false },
                .{ "ffn_up.weight", 4, 6, false },
                .{ "ffn_down.weight", 6, 4, false },
            };
            inline for (shapes) |shape| {
                var name: [64]u8 = undefined;
                const text = try std.fmt.bufPrint(&name, "blk.{d}.{s}", .{ layer, shape[0] });
                try self.add(text, shape[1], shape[2], shape[3]);
            }
        }
        try qwen.build(CAPACITY, &self.index, &self.plan);
    }

    fn add(self: *Fixture, name: []const u8, columns: usize, rows: usize, norm: bool) !void {
        const count = columns * @max(rows, 1);
        if (self.index.tensor_count == CAPACITY or name.len > 64 or
            count * 4 > self.bytes.len - self.used) return error.FixtureCapacity;
        const id = self.index.tensor_count;
        const tensor = &self.index.tensors[id];
        @memcpy(tensor.name[0..name.len], name);
        tensor.name_len = @intCast(name.len);
        tensor.dimension_count = if (rows == 0) 1 else 2;
        tensor.dimensions[0] = columns;
        if (rows != 0) tensor.dimensions[1] = rows;
        tensor.file_offset = self.used;
        tensor.byte_size = count * 4;
        for (0..count) |i| {
            const integer: i32 = @as(i32, @intCast((i * 7 + id * 3) % 19)) - 9;
            const value: f32 = if (norm) 1 else @as(f32, @floatFromInt(integer)) / 32;
            std.mem.writeInt(u32, self.bytes[self.used..][0..4], @bitCast(value), .little);
            self.used += 4;
        }
        self.index.tensor_count += 1;
    }

    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or destination.len > self.used - @as(usize, @intCast(offset))) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, length: usize, _: usize) ?[*]const u8 {
        const self: *const Fixture = @ptrCast(@alignCast(context));
        if (offset > self.used or length > self.used - @as(usize, @intCast(offset))) return null;
        return self.bytes[@intCast(offset)..].ptr;
    }
    fn source(self: *const Fixture, mapped: bool) gguf.Source {
        return .{ .context = self, .size = self.used, .read_at = read,
            .map_at = if (mapped) map else null };
    }
};

const Observation = struct {
    calls: usize = 0,
    slices: usize = 0,
    hidden: usize = 0,
    reject_stage: ?executor.Stage = null,
    reject_hidden: bool = false,

    fn report(context: *anyopaque, event: executor.ProgressEvent) bool {
        const self: *Observation = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (event.stage == .slice_begin) self.slices += 1;
        return self.reject_stage == null or self.reject_stage.? != event.stage;
    }
    fn tap(context: *anyopaque, _: u8, _: u32, values: []const f32) bool {
        const self: *Observation = @ptrCast(@alignCast(context));
        self.hidden += 1;
        return !self.reject_hidden and values.len == LIMITS.hidden;
    }
    fn progress(self: *Observation) executor.Progress {
        return .{ .context = self, .callback = report, .hidden_callback = tap };
    }
};

fn begin(fixture: *const Fixture, kv: []u16, session: *executor.TokenSession,
    token: u32, position: usize, progress: executor.Progress) executor.Error!void {
    return executor.beginToken(CAPACITY, LIMITS, &fixture.index, &fixture.plan, kv,
        LIMITS.context, session, token, position, true, .fused, progress);
}
fn step(fixture: *const Fixture, work: *Work, kv: []u16, session: *executor.TokenSession,
    rows: u32, progress: executor.Progress) executor.Error!executor.StepResult {
    return executor.stepToken(CAPACITY, LIMITS, fixture.source(true), &fixture.index,
        &fixture.plan, work, kv, LIMITS.context, session, rows, progress);
}

fn numericalParity(tied: bool, rows: u32) !void {
    var fixture: Fixture = .{};
    try fixture.initialize(tied);
    try check(fixture.plan.hidden_size == 4 and fixture.plan.query_size == 8);
    try check(fixture.plan.output_is_tied == tied);
    try check(try executor.requiredKvElements(fixture.plan, LIMITS.context) == KV_COUNT);
    var full: Work = .{};
    var sliced: Work = .{};
    var full_kv: [KV_COUNT]u16 = @splat(0);
    var sliced_kv: [KV_COUNT]u16 = @splat(0);
    var observations: Observation = .{};
    const tokens = [_]u32{ 1, 4, 2, 6 };
    for (tokens, 0..) |token, position| {
        const logits = position != 0;
        const expected = try executor.forward(CAPACITY, LIMITS, fixture.source(false),
            &fixture.index, &fixture.plan, &full, &full_kv, LIMITS.context,
            token, position, logits, .{});
        const actual = try executor.forwardSliced(CAPACITY, LIMITS, fixture.source(true),
            &fixture.index, &fixture.plan, &sliced, &sliced_kv, LIMITS.context,
            token, position, logits, .fused, rows, observations.progress());
        try check(expected == actual);
        try check((actual != null) == logits);
        for (full.hidden, sliced.hidden) |a, b| try check(a == b and std.math.isFinite(b));
        for (full.logits, sliced.logits) |a, b| try check(a == b and std.math.isFinite(b));
        for (full_kv, sliced_kv) |a, b| try check(a == b);
    }
    try check(observations.hidden == tokens.len * fixture.plan.layer_count);
    try check(observations.slices > 0);
    var nonzero = false;
    for (sliced_kv) |value| nonzero = nonzero or value != 0;
    try check(nonzero);
    executed_cases += 1;
}

fn reusedCacheParity() !void {
    var fixture: Fixture = .{};
    try fixture.initialize(false);
    var clean: Work = .{};
    var reused: Work = .{};
    var clean_kv: [KV_COUNT]u16 = @splat(0);
    // Poison every slot with F16 NaN. Any stale read contaminates the result.
    var reused_kv: [KV_COUNT]u16 = @splat(0x7e00);
    for ([_]u32{ 3, 1, 5, 0 }, 0..) |token, position| {
        const expected = try executor.forward(CAPACITY, LIMITS, fixture.source(false),
            &fixture.index, &fixture.plan, &clean, &clean_kv, LIMITS.context,
            token, position, true, .{});
        const actual = try executor.forwardSliced(CAPACITY, LIMITS, fixture.source(true),
            &fixture.index, &fixture.plan, &reused, &reused_kv, LIMITS.context,
            token, position, true, .fused, 1, .{});
        try check(expected == actual);
        for (clean.logits, reused.logits) |a, b| try check(a == b and std.math.isFinite(b));
    }
    try check(std.mem.eql(u16, &clean_kv, &reused_kv));
    executed_cases += 1;
}

fn boundsAndShape() !void {
    var fixture: Fixture = .{};
    try fixture.initialize(false);
    var work: Work = .{};
    var kv: [KV_COUNT]u16 = @splat(0);
    var session: executor.TokenSession = .{};
    try rejected(begin(&fixture, &kv, &session, 7, 0, .{}), error.InvalidToken);
    try rejected(begin(&fixture, &kv, &session, 0, LIMITS.context, .{}), error.InvalidPlan);
    try rejected(begin(&fixture, kv[0 .. kv.len - 1], &session, 0, 0, .{}), error.KvCapacity);
    try rejected(executor.beginToken(CAPACITY, LIMITS, &fixture.index, &fixture.plan,
        &kv, LIMITS.context + 1, &session, 0, 0, true, .fused, .{}), error.InvalidPlan);
    try begin(&fixture, &kv, &session, 1, 0, .{});
    try rejected(begin(&fixture, &kv, &session, 1, 0, .{}), error.InvalidPlan);
    try rejected(step(&fixture, &work, &kv, &session, 0, .{}), error.InvalidPlan);
    try check(session.phase == .idle);
    try rejected(step(&fixture, &work, &kv, &session, 1, .{}), error.InvalidPlan);

    // This configuration fits query/KV capacities but exceeds weight scratch.
    fixture.plan.head_count = 1;
    fixture.plan.kv_head_count = 1;
    fixture.plan.head_size = 8;
    fixture.plan.query_size = 8;
    fixture.plan.key_value_size = 8;
    try rejected(begin(&fixture, &kv, &session, 1, 0, .{}), error.InvalidPlan);
    try fixture.initialize(false);
    const reference = fixture.plan.layers[0].attention_output;
    fixture.index.tensors[reference.index].dimensions[0] = 4;
    fixture.index.tensors[reference.index].dimensions[1] = 8;
    try rejected(qwen.build(CAPACITY, &fixture.index, &fixture.plan), error.InvalidTensorShape);
    executed_cases += 1;
}

fn cancellationAndRestart() !void {
    var fixture: Fixture = .{};
    try fixture.initialize(false);
    var work: Work = .{};
    var kv: [KV_COUNT]u16 = @splat(0);
    var session: executor.TokenSession = .{};
    var observation = Observation{ .reject_stage = .request_begin };
    try rejected(begin(&fixture, &kv, &session, 1, 0, observation.progress()), error.Cancelled);
    try check(session.phase == .idle);

    // Cancellation must be available before every phase, including non-matrix work.
    observation = .{};
    try begin(&fixture, &kv, &session, 1, 0, observation.progress());
    var phases: usize = 0;
    while (session.active()) {
        const before = session;
        const before_work = work;
        const before_kv = kv;
        observation.reject_stage = .slice_begin;
        try rejected(step(&fixture, &work, &kv, &session, 1, observation.progress()), error.Cancelled);
        try check(session.phase == .idle);
        // Pre-phase cancellation must leave numerical storage untouched.
        try check(std.mem.eql(u8, std.mem.asBytes(&before_work), std.mem.asBytes(&work)));
        try check(std.mem.eql(u16, &before_kv, &kv));
        // Restore only the checkpoint in this test to enumerate all phases.
        session = before;
        observation.reject_stage = null;
        _ = try step(&fixture, &work, &kv, &session, 1, observation.progress());
        phases += 1;
        try check(phases < 1024);
    }
    try check(phases > 20);
    try check(observation.hidden == 2);

    observation = .{ .reject_hidden = true };
    try begin(&fixture, &kv, &session, 1, 0, observation.progress());
    var cancelled = false;
    for (0..1024) |_| {
        if (step(&fixture, &work, &kv, &session, 2, observation.progress())) |_| {} else |err| {
            try check(err == error.Cancelled);
            cancelled = true;
            break;
        }
    }
    try check(cancelled and session.phase == .idle);
    @memset(&kv, 0);
    work = .{};
    observation = .{};
    try begin(&fixture, &kv, &session, 1, 0, observation.progress());
    var actual: ?u32 = null;
    for (0..1024) |_| {
        switch (try step(&fixture, &work, &kv, &session, 3, observation.progress())) {
            .pending => {},
            .complete => |selected| { actual = selected; break; },
        }
    }
    var reference_work: Work = .{};
    var reference_kv: [KV_COUNT]u16 = @splat(0);
    const expected = try executor.forward(CAPACITY, LIMITS, fixture.source(false),
        &fixture.index, &fixture.plan, &reference_work, &reference_kv,
        LIMITS.context, 1, 0, true, .{});
    try check(actual != null and actual == expected and session.phase == .complete);
    try check(std.mem.eql(u16, &kv, &reference_kv));
    try check(std.mem.eql(f32, &work.logits, &reference_work.logits));
    const again = try step(&fixture, &work, &kv, &session, 1, observation.progress());
    try check(again == .complete and again.complete == actual);
    executed_cases += 1;
}

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag == .windows) {
        if (std.mem.indexOf(u16, init.minimal.args.vector,
            std.unicode.utf8ToUtf16LeStringLiteral("--prove-failure")) != null) try check(false);
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        if (args.next()) |argument| {
            if (std.mem.eql(u8, argument, "--prove-failure")) try check(false) else return error.UnknownArgument;
        }
    }
    inline for (.{ false, true }) |tied| {
        inline for (.{ 1, 2, 3, 32 }) |rows| try numericalParity(tied, rows);
    }
    try boundsAndShape();
    try cancellationAndRestart();
    try reusedCacheParity();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer,
        "{{\"suite\":\"qwen-executor\",\"pass\":true,\"cases\":{d},\"assertions\":{d}}}\n",
        .{ executed_cases, assertions });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
