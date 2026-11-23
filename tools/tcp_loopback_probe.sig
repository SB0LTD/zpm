//! Hold an experimental loopback attachment until standard input closes.
const std = @import("std");
const linux = std.os.linux;
const loopback = @import("tcp_loopback");

fn write(fd: linux.fd_t, bytes: []const u8) void {
    _ = linux.write(fd, bytes.ptr, bytes.len);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const args = init.args.vector;
    if (args.len != 4) return error.ExpectedCgroupPortAndDirection;
    const port = try std.fmt.parseInt(u16, std.mem.span(args[2]), 10);
    const direction = std.meta.stringToEnum(loopback.Direction, std.mem.span(args[3])) orelse
        return error.ExpectedRepliesOrDuplex;
    const opened = linux.openat(linux.AT.FDCWD, args[1], .{
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.CgroupOpenFailed;
    const cgroup: linux.fd_t = @intCast(opened);
    defer _ = linux.close(cgroup);

    var verifier: [16384]u8 = @splat(0);
    var log: linux.BPF.Log = .{ .level = 1, .buf = &verifier };
    const shortcut = loopback.Shortcut.init(cgroup, port, direction, &log) catch |err| {
        write(2, verifier[0 .. std.mem.indexOfScalar(u8, &verifier, 0) orelse verifier.len]);
        return err;
    };
    defer shortcut.deinit() catch |err| {
        write(2, @errorName(err));
        linux.exit(1);
    };
    write(1, "ready\n");
    var discard: [1]u8 = undefined;
    while (true) {
        const received = linux.read(0, &discard, discard.len);
        switch (linux.errno(received)) {
            .SUCCESS => if (received == 0) return,
            .INTR => continue,
            else => return error.ControlPipeFailed,
        }
    }
}
