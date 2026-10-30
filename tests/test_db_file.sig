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
    const pid: u32 = if (builtin.os.tag == .windows) Win.GetCurrentProcessId() else if (builtin.os.tag == .macos) @intCast(std.c.getpid()) else @intCast(std.os.linux.getpid());
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
    if (builtin.os.tag == .macos) {
        // Persistent handles must not leak across exec; creation must never
        // grant group/other access (the process umask can restrict it further).
        try check(std.c.fcntl(file.handle, std.c.F.GETFD) & std.c.FD_CLOEXEC != 0);
        var metadata: std.c.Stat = undefined;
        try check(std.c.fstat(file.handle, &metadata) == 0);
        try check(metadata.mode & 0o077 == 0);
    }
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
    // Read-only resource handles (zone data) share with the locked writer,
    // read the same bytes and never create files.
    var reader = try disk.File.openReadOnly(path);
    var shared: [64]u8 = undefined;
    try check(try reader.length() == committed_length);
    const shared_count = try reader.readAt(0, &shared);
    try check(shared_count == @min(shared.len, committed_length));
    reader.close();
    var missing_buffer: [256]u8 = undefined;
    const missing_path = try std.fmt.bufPrint(&missing_buffer, "sig-out/db-file-contract-{d}.missing", .{pid});
    if (disk.File.openReadOnly(missing_path)) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.close();
        return error.ReadOnlyOpenCreatedFile;
    } else |err| try check(err == error.FileOpenFailed);
    try file.appendAll("RAMS");
    try file.sync();
    file.close();
    open = false;
    // openExisting reports absence as FileNotFound (missing file or missing
    // directory component), still opens an existing file and never creates.
    var existing = try disk.File.openExisting(path);
    try check(try existing.length() == committed_length + 4);
    existing.close();
    if (disk.File.openExisting(missing_path)) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.close();
        return error.MissingFileOpened;
    } else |err| try check(err == error.FileNotFound);
    var absent_buffer: [256]u8 = undefined;
    const absent_path = try std.fmt.bufPrint(&absent_buffer, "sig-out/db-file-contract-{d}.absent/child.wal", .{pid});
    if (disk.File.openExisting(absent_path)) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.close();
        return error.MissingDirectoryOpened;
    } else |err| try check(err == error.FileNotFound);
    // Creating opens never report FileNotFound; nothing above created a file
    // or directory (exclusive creation proves the file was still absent).
    if (disk.File.open(absent_path)) |unexpected_value| {
        var unexpected = unexpected_value;
        unexpected.close();
        return error.MissingDirectoryCreated;
    } else |err| try check(err == error.FileOpenFailed);
    var fresh = try disk.File.createExclusive(missing_path);
    try check(try fresh.length() == 0);
    fresh.close();
    try disk.remove(missing_path);
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
    if (builtin.os.tag == .macos) {
        var link_buffer: [256]u8 = undefined;
        const link_bytes = try std.fmt.bufPrint(link_buffer[0 .. link_buffer.len - 1], "sig-out/db-file-contract-{d}.link", .{pid});
        link_buffer[link_bytes.len] = 0;
        const link_path = link_buffer[0..link_bytes.len :0];
        // Relative target is interpreted from the symlink's own directory.
        var target_buffer: [256]u8 = undefined;
        const target_bytes = try std.fmt.bufPrint(target_buffer[0 .. target_buffer.len - 1], "db-file-contract-{d}.snapshot", .{pid});
        target_buffer[target_bytes.len] = 0;
        const target_name = target_buffer[0..target_bytes.len :0];
        try check(std.c.symlinkat(target_name.ptr, std.c.AT.FDCWD, link_path.ptr) == 0);
        defer disk.remove(link_path) catch {};
        if (disk.File.open(link_path)) |unexpected_value| {
            var unexpected = unexpected_value;
            unexpected.close();
            return error.SymlinkDatabaseOpened;
        } else |err| try check(err == error.FileOpenFailed);
        if (disk.publishNew(temporary_path, link_path)) |_| return error.SymlinkTargetOverwritten else |err| try check(err == error.FileRenameFailed);
        var link_contents: [256]u8 = undefined;
        const link_len = std.c.readlinkat(std.c.AT.FDCWD, link_path.ptr, &link_contents, link_contents.len);
        try check(link_len == target_name.len and std.mem.eql(u8, link_contents[0..target_name.len], target_name));
    }
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
