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
pub fn main(init: std.process.Init) !void {
    try check(log.checksum("123456789") == 0xcbf43926);
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
