const std = @import("std");
const log = @import("durable_log");
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.DurableLogContractFailed;
}
const Mock = struct {
    bytes: [8192]u8 = @splat(0),
    len: usize = 0,
    stable: usize = 0,
    fail_after: usize = 8192,
    fail_sync: bool = false,
    fail_read: bool = false,
    read_chunk: usize = 8192,
    fail_truncate: bool = false,
    append_calls: usize = 0,
    pub fn length(self: *Mock) !u64 {
        return self.len;
    }
    pub fn readAt(self: *Mock, offset: u64, out: []u8) !usize {
        if (self.fail_read) return error.InjectedReadFailure;
        const at: usize = @intCast(offset);
        const n = @min(out.len, self.len - @min(at, self.len), self.read_chunk);
        @memcpy(out[0..n], self.bytes[at..][0..n]);
        return n;
    }
    pub fn appendAll(self: *Mock, bytes: []const u8) !void {
        self.append_calls += 1;
        for (bytes) |byte| {
            if (self.len == self.fail_after or self.len == self.bytes.len) return error.InjectedDiskFull;
            self.bytes[self.len] = byte;
            self.len += 1;
        }
    }
    pub fn sync(self: *Mock) !void {
        if (self.fail_sync) return error.InjectedSyncFailure;
        self.stable = self.len;
    }
    pub fn truncate(self: *Mock, len: u64) !void {
        if (self.fail_truncate) return error.InjectedTruncateFailure;
        self.len = @intCast(len);
    }
};
const Replay = struct {
    count: u64 = 0,
    bytes: usize = 0,
    pub fn apply(self: *Replay, sequence: u64, payload: []const u8) !void {
        try check(sequence == self.count + 1 and payload.len > 0);
        self.count = sequence;
        self.bytes += payload.len;
    }
    pub fn fail(_: *Replay, _: u64, _: []const u8) !void {
        return error.InjectedReplayFailure;
    }
};

const positioned_payloads = [_][]const u8{ "ordinary change", "pending writes", "intervening change", "resolve", "next change" };
const positioned_kinds = [_]u16{ 3, 4, 3, 4, 3 };
const accepted_positioned = (@as(u32, 1) << 3) | (@as(u32, 1) << 4);

const PositionedReplay = struct {
    file: *Mock,
    scratch: []u8,
    seen: usize = 0,
    next_offset: u64 = 0,
    pending: ?log.Frame = null,
    reread: bool = false,

    fn apply(self: *PositionedReplay, frame: log.Frame, payload: []const u8) !void {
        try check(frame.sequence == self.seen + 1 and frame.offset == self.next_offset);
        try check(frame.kind == positioned_kinds[self.seen] and frame.payload_len == positioned_payloads[self.seen].len);
        try check(std.mem.eql(u8, payload, positioned_payloads[self.seen]));
        if (self.seen == 1) self.pending = frame;
        if (self.seen == 3) {
            const previous = try log.readFrame(self.file, self.scratch, self.pending.?);
            try check(previous.ptr == self.scratch.ptr and std.mem.eql(u8, previous, positioned_payloads[1]));
            self.reread = true;
        }
        self.next_offset += log.overhead + frame.payload_len;
        self.seen += 1;
    }

    fn applyKinds(self: *PositionedReplay, kind: u16, sequence: u64, payload: []const u8) !void {
        try check(sequence == self.seen + 1 and kind == positioned_kinds[self.seen]);
        try check(std.mem.eql(u8, payload, positioned_payloads[self.seen]));
        self.seen += 1;
    }
};

fn rejectFrame(file: *Mock, scratch: []u8, expected: log.Frame, wanted: anyerror) !void {
    const length = file.len;
    const stable = file.stable;
    if (log.readFrame(file, scratch, expected)) |_| return error.InvalidFrameAccepted else |err| try check(err == wanted);
    try check(file.len == length and file.stable == stable);
}

const EndOfAddressSpace = struct {
    header: [log.header_size]u8,
    const offset = std.math.maxInt(u64) - log.header_size;

    pub fn length(_: *EndOfAddressSpace) !u64 {
        return std.math.maxInt(u64);
    }

    pub fn readAt(self: *EndOfAddressSpace, at: u64, out: []u8) !usize {
        if (at != offset or out.len != self.header.len) return error.UnexpectedPayloadRead;
        @memcpy(out, &self.header);
        return self.header.len;
    }
};

fn testPositionedFrames() !void {
    var original: Mock = .{};
    for (positioned_payloads, positioned_kinds, 1..) |payload, kind, seq| try log.appendKind(&original, seq, payload, kind);
    var file = original;
    file.read_chunk = 1;
    var scratch: [64]u8 = undefined;
    var replay: PositionedReplay = .{ .file = &file, .scratch = &scratch };
    const recovered = try log.recoverFrames(&file, &scratch, &replay, PositionedReplay.apply, accepted_positioned);
    try check(replay.reread and replay.seen == 5 and replay.next_offset == original.len);
    try check(recovered.sequence == 5 and recovered.valid_bytes == original.len and !recovered.truncated_tail);
    const pending = replay.pending.?;

    replay.seen = 0;
    const mixed = try log.recoverKinds(&file, &scratch, &replay, PositionedReplay.applyKinds, accepted_positioned);
    try check(mixed.sequence == 5 and replay.seen == 5);
    try check(std.mem.eql(u8, try log.readFrame(&file, &scratch, pending), positioned_payloads[1]));

    var wrong = pending;
    wrong.kind = 3;
    try rejectFrame(&file, &scratch, wrong, error.UnsupportedLogVersion);
    wrong.kind = 32;
    try rejectFrame(&file, &scratch, wrong, error.UnsupportedLogVersion);
    wrong = pending;
    wrong.sequence += 1;
    try rejectFrame(&file, &scratch, wrong, error.InvalidSequence);
    wrong = pending;
    wrong.payload_len += 1;
    try rejectFrame(&file, &scratch, wrong, error.InvalidPayloadLength);
    wrong = pending;
    wrong.offset = std.math.maxInt(u64);
    try rejectFrame(&file, &scratch, wrong, error.UnexpectedEndOfLog);
    try rejectFrame(&file, scratch[0..1], pending, error.LogPayloadCapacity);

    const at: usize = @intCast(pending.offset);
    const frame_end = at + log.overhead + pending.payload_len;
    for (at..frame_end) |cut| {
        file = original;
        file.len = cut;
        try rejectFrame(&file, &scratch, pending, error.UnexpectedEndOfLog);
    }
    file = original;
    file.bytes[at + 10] ^= 1;
    try rejectFrame(&file, &scratch, pending, error.CorruptLogHeader);
    file = original;
    file.bytes[at + log.header_size] ^= 1;
    try rejectFrame(&file, &scratch, pending, error.CorruptLogRecord);
    file = original;
    file.bytes[frame_end - 1] ^= 1;
    try rejectFrame(&file, &scratch, pending, error.CorruptLogRecord);

    var near_end: EndOfAddressSpace = .{ .header = original.bytes[at..][0..log.header_size].* };
    wrong = pending;
    wrong.offset = EndOfAddressSpace.offset;
    if (log.readFrame(&near_end, &scratch, wrong)) |_| return error.OverflowingFrameAccepted else |err| try check(err == error.UnexpectedEndOfLog);

    file = original;
    file.len -= 1;
    replay = .{ .file = &file, .scratch = &scratch };
    const repaired = try log.recoverFrames(&file, &scratch, &replay, PositionedReplay.apply, accepted_positioned);
    try check(repaired.truncated_tail and repaired.sequence == 4 and replay.reread);
    try check(file.len == original.len - log.overhead - positioned_payloads[4].len and file.stable == file.len);
}

const checkpoint_marker = "snapshot generation 7";
const checkpoint_kind: u16 = 7;
const checkpoint_suffix_kinds = @as(u32, 1) << 3;

const CheckpointReplay = struct {
    expected: []const u8 = checkpoint_marker,
    sequence: u64 = 0,
    next_offset: u64 = 0,
    replayed: usize = 0,
    verified: bool = false,
    finished: bool = false,
    reject_finish: bool = false,

    fn verify(self: *CheckpointReplay, marker: log.Frame, payload: []const u8) !void {
        if (!std.mem.eql(u8, payload, self.expected)) return error.CheckpointMismatch;
        self.verified = true;
        self.sequence = marker.sequence;
        self.next_offset = marker.offset + log.overhead + marker.payload_len;
    }

    fn apply(self: *CheckpointReplay, frame: log.Frame, payload: []const u8) !void {
        try check(self.verified and !self.finished and frame.kind == 3);
        try check(frame.sequence == self.sequence + 1 and frame.offset == self.next_offset);
        try check(std.mem.eql(u8, payload, "committed change"));
        self.sequence = frame.sequence;
        self.next_offset += log.overhead + frame.payload_len;
        self.replayed += 1;
    }

    fn finish(self: *CheckpointReplay) !void {
        if (self.reject_finish) return error.InjectedFinalizerFailure;
        try check(self.verified);
        self.finished = true;
    }
};

fn rejectCheckpoint(file: *Mock, scratch: []u8, marker: log.Frame, replay: *CheckpointReplay, wanted: anyerror) !void {
    const before = file.*;
    if (log.recoverAfterFrame(file, scratch, marker, replay, CheckpointReplay.verify, CheckpointReplay.apply, CheckpointReplay.finish, checkpoint_suffix_kinds)) |_|
        return error.BadCheckpointAccepted
    else |err| try check(err == wanted);
    try check(file.len == before.len and file.stable == before.stable and std.mem.eql(u8, &file.bytes, &before.bytes));
    try check(!replay.finished);
}

fn testCheckpointSuffix() !void {
    for ([_]bool{ false, true }) |prefix| {
        var original: Mock = .{ .read_chunk = 1 };
        if (prefix) try log.appendKind(&original, 1, "covered history", 3);
        const marker: log.Frame = .{ .offset = original.len, .sequence = 2, .kind = checkpoint_kind, .payload_len = checkpoint_marker.len };
        try log.appendKind(&original, marker.sequence, checkpoint_marker, marker.kind);
        const end_of_marker = original.len;
        try log.appendKind(&original, 3, "committed change", 3);
        const end_of_first = original.len;
        try log.appendKind(&original, 4, "committed change", 3);

        var scratch: [64]u8 = undefined;
        var replay: CheckpointReplay = .{};
        var file = original;
        const all = try log.recoverAfterFrame(&file, &scratch, marker, &replay, CheckpointReplay.verify, CheckpointReplay.apply, CheckpointReplay.finish, checkpoint_suffix_kinds);
        try check(all.sequence == 4 and all.valid_bytes == original.len and !all.truncated_tail);
        try check(replay.verified and replay.finished and replay.replayed == 2 and file.stable == original.stable);

        file = original;
        file.len -= 1;
        replay = .{ .expected = "different checkpoint" };
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.CheckpointMismatch);
        try check(!replay.verified and replay.replayed == 0);

        replay = .{ .reject_finish = true };
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.InjectedFinalizerFailure);
        try check(replay.verified and replay.replayed == 1);

        replay = .{};
        const repaired = try log.recoverAfterFrame(&file, &scratch, marker, &replay, CheckpointReplay.verify, CheckpointReplay.apply, CheckpointReplay.finish, checkpoint_suffix_kinds);
        try check(repaired.truncated_tail and repaired.sequence == 3 and repaired.valid_bytes == end_of_first);
        try check(replay.finished and replay.replayed == 1 and file.len == end_of_first and file.stable == file.len);

        file = original;
        file.len = end_of_marker - 1;
        replay = .{};
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.UnexpectedEndOfLog);
        try check(!replay.verified and replay.replayed == 0);

        file = original;
        file.bytes[@as(usize, @intCast(marker.offset)) + log.header_size] ^= 1;
        replay = .{};
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.CorruptLogRecord);
        try check(!replay.verified);

        file = original;
        file.bytes[end_of_first + log.header_size] ^= 1;
        replay = .{};
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.CorruptLogRecord);
        try check(replay.verified and replay.replayed == 1);

        file = original;
        file.len = end_of_marker;
        try log.appendKind(&file, 4, "committed change", 3);
        replay = .{};
        try rejectCheckpoint(&file, &scratch, marker, &replay, error.InvalidSequence);
        try check(replay.verified and replay.replayed == 0);
    }
}

pub fn main(init: std.process.Init) !void {
    try check(log.checksum("123456789") == 0xcbf43926);
    try testPositionedFrames();
    try testCheckpointSuffix();
    // Exact staging boundary and streaming fallback retain identical framing,
    // CRCs, replay payloads and stable-storage acknowledgement.
    var staged_payload: [4096]u8 = @splat('a');
    for ([_]usize{ 1, 4048, 4049, 4096 }) |length| {
        var staged: Mock = .{};
        try log.append(&staged, 1, staged_payload[0..length]);
        try check(staged.append_calls == (if (length <= 4048) @as(usize, 1) else 3));
        try check(staged.len == length + log.overhead and staged.stable == staged.len);
        var staged_scratch: [4096]u8 = undefined;
        var staged_replay: Replay = .{};
        const result = try log.recover(&staged, &staged_scratch, &staged_replay, Replay.apply);
        try check(result.sequence == 1 and staged_replay.bytes == length and !result.truncated_tail);
        try check(std.mem.eql(u8, staged_scratch[0..length], staged_payload[0..length]));
    }
    var original: Mock = .{};
    var boundaries: [4]usize = .{ 0, 0, 0, 0 };
    for ([_][]const u8{ "CREATE TABLE test (id INTEGER)", "INSERT INTO test VALUES (1)", "UPDATE test SET id = 2" }, 0..) |payload, i| {
        try log.append(&original, i + 1, payload);
        boundaries[i + 1] = original.len;
        try check(original.stable == original.len);
    }
    var scratch: [256]u8 = undefined;
    var replay: Replay = .{};
    const recovered = try log.recover(&original, &scratch, &replay, Replay.apply);
    try check(recovered.sequence == 3 and !recovered.truncated_tail and recovered.valid_bytes == original.len);
    // Every byte cutoff, including headers, payloads and commit trailers.
    for (0..original.len + 1) |cut| {
        var file = original;
        file.len = cut;
        replay = .{};
        const result = try log.recover(&file, &scratch, &replay, Replay.apply);
        var expected: usize = 0;
        for (boundaries, 0..) |end, i| {
            if (end <= cut) expected = i;
        }
        try check(result.sequence == expected and replay.count == expected);
        try check(file.len == boundaries[expected] and result.valid_bytes == file.len);
        try check(result.truncated_tail == (cut != file.len));
    }
    // A bit flip anywhere in a complete log must never be silently accepted.
    for (0..original.len) |at| {
        for (0..8) |bit| {
            var file = original;
            file.bytes[at] ^= @as(u8, 1) << @intCast(bit);
            replay = .{};
            if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.CorruptionAccepted else |_| {}
            try check(file.len == original.len);
        }
    }
    // Disk full/short write at every append boundary, then reopen/recover.
    const payload = "INSERT INTO test VALUES (3)";
    for (0..log.overhead + payload.len) |fail_at| {
        var file = original;
        file.fail_after = file.len + fail_at;
        if (log.append(&file, 4, payload)) |_| return error.DiskFullIgnored else |err| try check(err == error.InjectedDiskFull);
        file.fail_after = file.bytes.len;
        replay = .{};
        const result = try log.recover(&file, &scratch, &replay, Replay.apply);
        try check(result.sequence == 3 and file.len == original.len and file.stable == original.len);
    }
    var file = original;
    file.fail_sync = true;
    if (log.append(&file, 4, payload)) |_| return error.SyncFailureIgnored else |err| try check(err == error.InjectedSyncFailure);
    try check(file.stable == original.len); // No successful durable acknowledgement.
    file.fail_sync = false;
    replay = .{};
    const uncertain = try log.recover(&file, &scratch, &replay, Replay.apply);
    try check(uncertain.sequence == 4); // An uncertain commit is resolved by restart.
    file = original;
    file.read_chunk = 1;
    replay = .{};
    _ = try log.recover(&file, &scratch, &replay, Replay.apply);
    try check(replay.count == 3);
    file.fail_read = true;
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.ReadFailureIgnored else |err| try check(err == error.InjectedReadFailure);
    file = original;
    if (log.recover(&file, &scratch, &replay, Replay.fail)) |_| return error.ReplayFailureIgnored else |err| try check(err == error.InjectedReplayFailure);
    try check(file.len == original.len);
    var small: [4]u8 = undefined;
    if (log.recover(&file, &small, &replay, Replay.apply)) |_| return error.CapacityIgnored else |err| try check(err == error.LogPayloadCapacity);
    file.len -= 1;
    file.fail_truncate = true;
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.TruncateFailureIgnored else |err| try check(err == error.InjectedTruncateFailure);
    file = original;
    file.len -= 1;
    file.fail_sync = true;
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.RepairSyncFailureIgnored else |err| try check(err == error.InjectedSyncFailure);
    try check(file.len == boundaries[2]);
    // Removing a whole middle record still fails sequence validation, even
    // though the remaining header/payload checksums are individually valid.
    file = original;
    const last_len = original.len - boundaries[2];
    @memcpy(file.bytes[boundaries[1]..][0..last_len], original.bytes[boundaries[2]..][0..last_len]);
    file.len = boundaries[1] + last_len;
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.MissingRecordIgnored else |err| try check(err == error.InvalidSequence);
    // One-byte reads returning premature EOF fail without destructive repair.
    file = original;
    file.read_chunk = 0;
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.PrematureReadEndIgnored else |err| try check(err == error.UnexpectedEndOfLog);
    try check(file.len == original.len);
    file = .{};
    try log.append(&file, 2, payload);
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.SequenceGapIgnored else |err| try check(err == error.InvalidSequence);
    file = .{};
    if (log.append(&file, 0, payload)) |_| return error.InvalidSequenceAccepted else |err| try check(err == error.InvalidSequence);
    if (log.append(&file, 1, "")) |_| return error.EmptyPayloadAccepted else |err| try check(err == error.InvalidPayloadLength);
    file = .{};
    try log.appendKind(&file, 1, payload, 2);
    const versioned = file;
    replay = .{};
    if (log.recover(&file, &scratch, &replay, Replay.apply)) |_| return error.PayloadVersionIgnored else |err| try check(err == error.UnsupportedLogVersion);
    try check(replay.count == 0 and file.len == versioned.len and std.mem.eql(u8, &file.bytes, &versioned.bytes));
    const versioned_recovery = try log.recoverKind(&file, &scratch, &replay, Replay.apply, 2);
    try check(versioned_recovery.sequence == 1 and replay.count == 1 and file.stable == file.len);
    if (log.appendKind(&file, 2, payload, 0)) |_| return error.ZeroKindAccepted else |err| try check(err == error.UnsupportedLogVersion);
    try log.appendKind(&file, 2, payload, 1);
    const mixed = file;
    replay = .{};
    if (log.recoverKind(&file, &scratch, &replay, Replay.apply, 2)) |_| return error.MixedPayloadVersionsAccepted else |err| try check(err == error.UnsupportedLogVersion);
    try check(file.len == mixed.len and std.mem.eql(u8, &file.bytes, &mixed.bytes));
    var report_buf: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buf, "{{\"suite\":\"durable_log\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
