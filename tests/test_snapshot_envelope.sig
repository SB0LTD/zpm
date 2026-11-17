const std = @import("std");
const builtin = @import("builtin");
const disk = @import("db_file");
const snapshot = @import("snapshot_envelope");
const Writer = snapshot.Writer(disk.File);
const Win = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};

const payload_bytes = 4099;
const identity: snapshot.Identity = .{
    .database_id = "logical-database".*,
    .generation = 0x0807060504030201,
    .wal_sequence = 19,
    .sql_csn = 0xf000000000000003,
};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SnapshotEnvelopeContractFailed;
}

const Staging = struct {
    bytes: [payload_bytes]u8 = undefined,
    used: usize = 0,
    chunks: usize = 0,
    published: bool = false,

    fn receive(self: *Staging, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.used) return error.StagingCapacity;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        self.chunks += 1;
    }

    fn restore(self: *Staging, file: *disk.File, scratch: []u8, seal: snapshot.Seal) !void {
        try snapshot.read(file, scratch, seal, self, receive);
        self.published = true;
    }
};

fn reject(file: *disk.File, scratch: []u8, seal: snapshot.Seal, expected: anyerror, payload_seen: bool) !void {
    const before = try file.length();
    var staging: Staging = .{};
    if (staging.restore(file, scratch, seal)) |_| return error.InvalidSnapshotAccepted else |err| try check(err == expected);
    try check(!staging.published and (staging.chunks != 0) == payload_seen);
    try check(try file.length() == before);
}

fn replaceBytes(file: *disk.File, bytes: []const u8) !void {
    try file.truncate(0);
    try file.appendAll(bytes);
}

pub fn main(init: std.process.Init) !void {
    const pid: u32 = if (builtin.os.tag == .windows) Win.GetCurrentProcessId() else if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else @intCast(std.os.linux.getpid());
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "sig-out/snapshot-envelope-{d}.image", .{pid});
    var invalid_buffer: [256]u8 = undefined;
    const invalid_path = try std.fmt.bufPrint(&invalid_buffer, "sig-out/snapshot-envelope-{d}.invalid", .{pid});
    var file = try disk.File.createExclusive(path);
    defer disk.remove(path) catch {};
    defer file.close();
    var malformed = try disk.File.createExclusive(invalid_path);
    defer disk.remove(invalid_path) catch {};
    defer malformed.close();

    var payload: [payload_bytes]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 37 + i / 19);
    var writer = try Writer.begin(&file, identity);
    try writer.append(payload[0..19]);
    try writer.append(&.{});
    try writer.append(payload[19..2053]);
    try writer.append(payload[2053..]);
    const seal = try writer.finish();
    try check(seal.payload_bytes == payload.len and seal.identity.wal_sequence == 19);
    try check(seal.identity.sql_csn == 0xf000000000000003);
    if (writer.append("stale")) |_| return error.SealedWriterReused else |err| try check(err == error.SnapshotWriterClosed);
    if (writer.finish()) |_| return error.SealedWriterFinishedTwice else |err| try check(err == error.SnapshotWriterClosed);
    if (Writer.begin(&file, identity)) |_| return error.NonemptyFileAccepted else |err| try check(err == error.SnapshotDestinationNotEmpty);
    file.close();
    file = try disk.File.openReadOnly(path);
    var scratch: [137]u8 = undefined;
    try snapshot.verify(&file, &scratch, seal);
    var restored: Staging = .{};
    try restored.restore(&file, &scratch, seal);
    try check(restored.published and restored.used == payload.len and restored.chunks > 1);
    try check(std.mem.eql(u8, &restored.bytes, &payload));

    var bytes: [snapshot.overhead + payload_bytes]u8 = undefined;
    try check(try file.readAt(0, &bytes) == bytes.len);
    try check(std.mem.eql(u8, bytes[0..8], "RAMSQLS1"));
    try check(std.mem.eql(u8, bytes[24..32], &.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    try check(std.mem.eql(u8, bytes[snapshot.header_size..][0..payload.len], &payload));
    try check(std.mem.eql(u8, bytes[bytes.len - 8 ..], "RAMSQLSE"));

    var wrong = seal;
    wrong.identity.database_id[0] ^= 1;
    try reject(&file, &scratch, wrong, error.SnapshotIdentityMismatch, false);
    wrong = seal;
    wrong.identity.generation += 1;
    try reject(&file, &scratch, wrong, error.SnapshotIdentityMismatch, false);
    wrong = seal;
    wrong.identity.wal_sequence = seal.identity.sql_csn;
    wrong.identity.sql_csn = seal.identity.wal_sequence;
    try reject(&file, &scratch, wrong, error.SnapshotIdentityMismatch, false);
    wrong = seal;
    wrong.payload_bytes = snapshot.max_payload_bytes + 1;
    try reject(&file, &scratch, wrong, error.SnapshotTooLarge, false);
    try reject(&file, scratch[0..0], seal, error.SnapshotScratchEmpty, false);

    try replaceBytes(&malformed, bytes[0 .. snapshot.header_size - 1]);
    try reject(&malformed, &scratch, seal, error.TruncatedSnapshot, false);
    try replaceBytes(&malformed, bytes[0 .. bytes.len - 1]);
    try reject(&malformed, &scratch, seal, error.TruncatedSnapshot, false);
    try replaceBytes(&malformed, &bytes);
    try malformed.appendAll("stale");
    try reject(&malformed, &scratch, seal, error.TrailingSnapshotBytes, false);

    var damaged = bytes;
    damaged[0] ^= 1;
    try replaceBytes(&malformed, &damaged);
    try reject(&malformed, &scratch, seal, error.UnsupportedSnapshotFormat, false);
    damaged = bytes;
    damaged[bytes.len - snapshot.footer_size] ^= 1;
    try replaceBytes(&malformed, &damaged);
    try reject(&malformed, &scratch, seal, error.InvalidSnapshotFooter, false);
    damaged = bytes;
    damaged[snapshot.header_size + 1027] ^= 1;
    try replaceBytes(&malformed, &damaged);
    try reject(&malformed, &scratch, seal, error.SnapshotDigestMismatch, true);
    try malformed.truncate(0);
    var substitute = try Writer.begin(&malformed, identity);
    try substitute.append(damaged[snapshot.header_size..][0..payload.len]);
    const substitute_seal = try substitute.finish();
    try snapshot.verify(&malformed, &scratch, substitute_seal);
    try reject(&malformed, &scratch, seal, error.SnapshotDigestMismatch, false);

    try malformed.truncate(0);
    var empty = try Writer.begin(&malformed, .{ .database_id = identity.database_id, .generation = 1, .wal_sequence = 0, .sql_csn = 0 });
    const empty_seal = try empty.finish();
    var empty_staging: Staging = .{};
    try empty_staging.restore(&malformed, &scratch, empty_seal);
    try check(empty_staging.published and empty_staging.used == 0 and empty_staging.chunks == 0);

    try malformed.truncate(0);
    var failed = try Writer.begin(&malformed, identity);
    malformed.close();
    if (failed.append("bad")) |_| return error.ClosedNativeFileAccepted else |err| try check(err == error.FileSeekFailed);
    if (failed.finish()) |_| return error.FailedWriterSealed else |err| try check(err == error.SnapshotWriterClosed);

    var report_buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buffer, "{{\"suite\":\"snapshot_envelope\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
