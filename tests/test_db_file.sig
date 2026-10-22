const std = @import("std");
const builtin = @import("builtin");
const disk = @import("db_file");
const log = @import("durable_log");
const Win = struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.DatabaseFileContractFailed;
}
const Replay = struct {
    sequence: u64 = 0,
    pub fn apply(self: *Replay, sequence: u64, payload: []const u8) !void {
        try check(sequence == self.sequence + 1 and std.mem.eql(u8, payload, "durable transaction"));
        self.sequence = sequence;
    }
};
pub fn main(init: std.process.Init) !void {
    const pid: u32 = if (builtin.os.tag == .windows) Win.GetCurrentProcessId() else @intCast(std.os.linux.getpid());
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "sig-out/db-file-contract-{d}.wal", .{pid});
    var snapshot_buffer: [256]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrint(&snapshot_buffer, "sig-out/db-file-contract-{d}.snapshot", .{pid});
    var temporary_buffer: [256]u8 = undefined;
    const temporary_path = try std.fmt.bufPrint(&temporary_buffer, "sig-out/db-file-contract-{d}.snapshot.tmp", .{pid});
    // Unique, exclusively created artifacts: never overwrite unrelated files.
    var file = try disk.File.createExclusive(path);
    defer disk.remove(path) catch {};
    var open = true;
    defer if (open) file.close();
    try check(try file.length() == 0);
    if (disk.File.createExclusive(path)) |duplicate_value| {
        var duplicate = duplicate_value;
        duplicate.close();
        return error.ExclusiveCreateOverwroteFile;
    } else |_| try check(true);
    if (disk.File.open(path)) |duplicate_value| {
        var duplicate = duplicate_value;
        duplicate.close();
        return error.ConcurrentWriterAccepted;
    } else |err| try check(err == error.DataDirectoryBusy);
    try log.append(&file, 1, "durable transaction");
    const committed_length = try file.length();
    try check(committed_length == log.overhead + "durable transaction".len);
    try file.appendAll("RAMS");
    try file.sync();
    file.close();
    open = false;
    file = try disk.File.open(path);
    open = true;
    var scratch: [128]u8 = undefined;
    var replay: Replay = .{};
    const result = try log.recover(&file, &scratch, &replay, Replay.apply);
    try check(result.sequence == 1 and result.truncated_tail and try file.length() == committed_length);
    try log.append(&file, 2, "durable transaction");
    file.close();
    open = false;
    file = try disk.File.open(path);
    open = true;
    replay = .{};
    const twice = try log.recover(&file, &scratch, &replay, Replay.apply);
    try check(twice.sequence == 2 and !twice.truncated_tail);
    var empty: [0]u8 = .{};
    try check(try file.readAt(0, &empty) == 0);
    try check(try file.readAt(try file.length(), &scratch) == 0);
    // Replacing a snapshot preserves old target until the new file is synced.
    var snapshot = try disk.File.createExclusive(snapshot_path);
    defer disk.remove(snapshot_path) catch {};
    try snapshot.appendAll("old snapshot");
    try snapshot.sync();
    snapshot.close();
    var temporary = try disk.File.createExclusive(temporary_path);
    defer disk.remove(temporary_path) catch {};
    try temporary.appendAll("new snapshot");
    try temporary.sync();
    temporary.close();
    try disk.replaceAtomic(temporary_path, snapshot_path);
    snapshot = try disk.File.open(snapshot_path);
    defer snapshot.close();
    const n = try snapshot.readAt(0, &scratch);
    try check(std.mem.eql(u8, scratch[0..n], "new snapshot"));
    // Source no longer exists: failed replace leaves target readable/unmodified.
    if (disk.replaceAtomic(temporary_path, snapshot_path)) |_| return error.MissingSourceAccepted else |err| try check(err == error.FileRenameFailed);
    const again = try snapshot.readAt(0, &scratch);
    try check(std.mem.eql(u8, scratch[0..again], "new snapshot"));
    snapshot.close();
    temporary = try disk.File.createExclusive(temporary_path);
    try temporary.appendAll("new non-overwriting backup");
    try temporary.sync();
    temporary.close();
    if (disk.publishNew(temporary_path, snapshot_path)) |_| return error.ExistingTargetOverwritten else |err| try check(err == error.FileRenameFailed);
    snapshot = try disk.File.open(snapshot_path);
    const preserved = try snapshot.readAt(0, &scratch);
    try check(std.mem.eql(u8, scratch[0..preserved], "new snapshot"));
    snapshot.close();
    try disk.remove(snapshot_path);
    try disk.publishNew(temporary_path, snapshot_path);
    snapshot = try disk.File.open(snapshot_path);
    const published = try snapshot.readAt(0, &scratch);
    try check(std.mem.eql(u8, scratch[0..published], "new non-overwriting backup"));
    if (disk.File.open("bad\x00path")) |_| return error.InvalidPathAccepted else |err| try check(err == error.InvalidPath);
    file.poisoned = true;
    if (file.appendAll("no")) |_| return error.PoisonedWriteAccepted else |err| try check(err == error.WriterPoisoned);
    if (file.sync()) |_| return error.PoisonedSyncAccepted else |err| try check(err == error.WriterPoisoned);
    if (file.truncate(0)) |_| return error.PoisonedTruncateAccepted else |err| try check(err == error.WriterPoisoned);
    // Exercise native failed syscalls as well as explicit poison guards.
    var invalid_file: disk.File = .{};
    if (invalid_file.appendAll("invalid")) |_| return error.InvalidNativeWriteAccepted else |_| try check(invalid_file.poisoned);
    if (invalid_file.sync()) |_| return error.InvalidNativeSyncAccepted else |err| try check(err == error.WriterPoisoned);
    invalid_file = .{};
    if (invalid_file.sync()) |_| return error.InvalidNativeFlushAccepted else |_| try check(invalid_file.poisoned);
    var report_buf: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buf, "{{\"suite\":\"db_file\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
