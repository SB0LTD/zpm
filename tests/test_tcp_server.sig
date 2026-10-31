//! Executable loopback contracts; does not rely on compiler test discovery.
const std = @import("std");
const builtin = @import("builtin");
const tcp = @import("tcp_server");
const linux = std.os.linux;
const windows = builtin.os.tag == .windows;
const Win = struct {
    const Address = extern struct { family: u16 = 2, port: u16, addr: u32, zero: [8]u8 = @splat(0) };
    extern "ws2_32" fn socket(c_int, c_int, c_int) callconv(.c) usize;
    extern "ws2_32" fn connect(usize, *const Address, c_int) callconv(.c) c_int;
    extern "ws2_32" fn getsockopt(usize, c_int, c_int, *c_int, *c_int) callconv(.c) c_int;
};
var assertions: usize = 0;
var report_io: std.Io = undefined;
var phase: []const u8 = "startup";

fn check(value: bool) !void {
    assertions += 1;
    if (!value) {
        var buffer: [256]u8 = undefined;
        const report = std.fmt.bufPrint(&buffer, "{{\"suite\":\"tcp_server\",\"pass\":false,\"assertion\":{d},\"phase\":\"{s}\"}}\n", .{ assertions, phase }) catch return error.TcpContractFailed;
        std.Io.File.stderr().writeStreamingAll(report_io, report) catch {};
        return error.TcpContractFailed;
    }
}

fn connect(port: u16) !tcp.Socket {
    const wire_port = if (builtin.cpu.arch.endian() == .little) @byteSwap(port) else port;
    const address: u32 = @bitCast([4]u8{ 127, 0, 0, 1 });
    if (windows) {
        const fd = Win.socket(2, 1, 6);
        if (fd == tcp.invalid_socket) return error.ClientSocketFailed;
        errdefer tcp.close(fd);
        const addr: Win.Address = .{ .port = wire_port, .addr = address };
        if (Win.connect(fd, &addr, @sizeOf(Win.Address)) != 0) return error.ClientConnectFailed;
        return fd;
    } else if (builtin.os.tag == .macos) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, std.c.IPPROTO.TCP);
        if (fd < 0) return error.ClientSocketFailed;
        errdefer tcp.close(fd);
        const addr: std.c.sockaddr.in = .{ .port = wire_port, .addr = address };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.ClientConnectFailed;
        // send() must remain safe even after a peer's close, including clients
        // used by the native backend contract rather than accepted sockets.
        const enabled: c_int = 1;
        if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) return error.ClientSocketFailed;
        return fd;
    } else {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
        if (linux.errno(rc) != .SUCCESS) return error.ClientSocketFailed;
        const fd: tcp.Socket = @intCast(rc);
        errdefer tcp.close(fd);
        const addr: linux.sockaddr.in = .{ .port = wire_port, .addr = address };
        if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.ClientConnectFailed;
        return fd;
    }
}

fn ready(listener: tcp.Socket, sockets: []const tcp.Socket, read: []bool, write: []bool) !bool {
    return tcp.wait(listener, sockets, read, write, 1000);
}

fn noDelay(fd: tcp.Socket) !void {
    phase = "accepted socket flags";
    var value: c_int = 0;
    if (windows) {
        var len: c_int = @sizeOf(c_int);
        try check(Win.getsockopt(fd, 6, 1, &value, &len) == 0);
    } else if (builtin.os.tag == .macos) {
        var len: std.c.socklen_t = @sizeOf(c_int);
        try check(std.c.getsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &value, &len) == 0);
        var no_signal: c_int = 0;
        len = @sizeOf(c_int);
        try check(std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &no_signal, &len) == 0 and no_signal == 1);
        const status = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblock: c_int = @bitCast(@as(std.c.O, .{ .NONBLOCK = true }));
        try check(status >= 0 and status & nonblock != 0);
        try check(std.c.fcntl(fd, std.c.F.GETFD) & std.c.FD_CLOEXEC != 0);
    } else {
        var len: linux.socklen_t = @sizeOf(c_int);
        try check(linux.errno(linux.getsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&value), &len)) == .SUCCESS);
    }
    // Darwin returns the nonzero TF_NODELAY flag (currently 0x4), whereas
    // Winsock and Linux normalize this boolean socket option to 1. Verify the
    // enabled state, then exercise both transitions on Darwin so accepting its
    // native boolean representation cannot conceal a missing setsockopt call.
    try check(if (builtin.os.tag == .macos) value != 0 else value == 1);
    if (builtin.os.tag == .macos) {
        phase = "TCP_NODELAY transitions";
        const disabled: c_int = 0;
        try check(std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &disabled, @sizeOf(c_int)) == 0);
        var len: std.c.socklen_t = @sizeOf(c_int);
        value = -1;
        try check(std.c.getsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &value, &len) == 0);
        try check(value == 0);
        const enabled: c_int = 1;
        try check(std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &enabled, @sizeOf(c_int)) == 0);
        len = @sizeOf(c_int);
        try check(std.c.getsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP.NODELAY, &value, &len) == 0);
        try check(value != 0);
    }
}

fn backpressure(listener: tcp.Socket, port: u16) !void {
    phase = "backpressure connect";
    const client = try connect(port);
    defer tcp.close(client);
    var empty: [0]bool = .{};
    try check(try ready(listener, &.{}, &empty, &empty));
    const accepted = (try tcp.accept(listener)) orelse return error.AcceptNotReady;
    defer tcp.close(accepted);
    const data: [65536]u8 = @splat(0x5a);
    var saw_backpressure = false;
    var total: usize = 0;
    for (0..2048) |_| {
        phase = "backpressure fill";
        const sent = (try tcp.send(accepted, &data)) orelse {
            saw_backpressure = true;
            break;
        };
        try check(sent > 0 and sent <= data.len);
        total += sent;
    }
    try check(saw_backpressure and total > 0);
    // Buffer pressure is local to this connection; the accept queue remains
    // usable and the reactor must still return promptly when another connects.
    const other_client = try connect(port);
    defer tcp.close(other_client);
    var read: [1]bool = .{false};
    var write: [1]bool = .{true};
    phase = "backpressure accept fairness";
    // Readiness is for any requested descriptor: the pressured writer can
    // become writable before Darwin reports the newly connected listener.
    // Retain write interest and the original total 1s deadline, rather than
    // requiring both events to occur in a single poll wakeup.
    const accept_deadline = std.Io.Timestamp.now(report_io, .awake).toMilliseconds() + 1000;
    var accept_ready = false;
    while (true) {
        const remaining = accept_deadline - std.Io.Timestamp.now(report_io, .awake).toMilliseconds();
        if (remaining <= 0) break;
        write[0] = true;
        if (try tcp.wait(listener, &.{accepted}, &read, &write, @intCast(remaining))) {
            accept_ready = true;
            break;
        }
    }
    try check(accept_ready);
    const other = (try tcp.accept(listener)) orelse return error.AcceptNotReady;
    defer tcp.close(other);
    try check((try tcp.send(other_client, "x")) == 1);
    var buf: [1]u8 = undefined;
    var other_read: [1]bool = .{false};
    var other_write: [1]bool = .{false};
    phase = "backpressure peer readability";
    const read_deadline = std.Io.Timestamp.now(report_io, .awake).toMilliseconds() + 1000;
    while (true) {
        const remaining = read_deadline - std.Io.Timestamp.now(report_io, .awake).toMilliseconds();
        if (remaining <= 0) break;
        _ = try tcp.wait(listener, &.{other}, &other_read, &other_write, @intCast(remaining));
        if (other_read[0]) break;
    }
    try check(other_read[0]);
    phase = "backpressure peer payload";
    try check((try tcp.recv(other, &buf)) == 1 and buf[0] == 'x');
}

pub fn main(init: std.process.Init) !void {
    report_io = init.io;
    try tcp.init();
    defer tcp.deinit();
    const listener = try tcp.listen(.{ 127, 0, 0, 1 }, 0);
    defer tcp.close(listener);
    const port = try tcp.localPort(listener);
    try check(port != 0);
    if (tcp.listen(.{ 127, 0, 0, 1 }, port)) |duplicate| {
        tcp.close(duplicate);
        return error.DuplicateBindAccepted;
    } else |err| try check(err == error.BindFailed);
    try check(try tcp.accept(listener) == null);
    var no_read: [0]bool = .{};
    var no_write: [0]bool = .{};
    try check(!try tcp.wait(listener, &.{}, &no_read, &no_write, 0));
    const client = try connect(port);
    var client_closed = false;
    defer if (!client_closed) tcp.close(client);
    try check(try ready(listener, &.{}, &no_read, &no_write));
    const accepted = (try tcp.accept(listener)) orelse return error.AcceptNotReady;
    defer tcp.close(accepted);
    try noDelay(accepted);
    phase = "initial readiness";
    try check(try tcp.accept(listener) == null);
    var buf: [64]u8 = undefined;
    try check(try tcp.recv(accepted, &buf) == null);
    var read: [2]bool = .{ false, false };
    var write: [2]bool = .{ true, true };
    try check(!try ready(listener, &.{ accepted, tcp.invalid_socket }, &read, &write));
    try check(!read[0] and !read[1] and write[0] and !write[1]);
    try check((try tcp.send(client, "hello")) == 5);
    var masked_read: [1]bool = .{false};
    var masked_write: [1]bool = .{false};
    phase = "read interest masking";
    try check(!try tcp.waitMasked(listener, &.{accepted}, &masked_read, &masked_write, 0));
    try check(!masked_read[0] and !masked_write[0]);
    masked_read[0] = true;
    try check(!try tcp.waitMasked(listener, &.{accepted}, &masked_read, &masked_write, 1000));
    try check(masked_read[0] and !masked_write[0]);
    write = .{ false, false };
    phase = "bidirectional bytes";
    try check(!try ready(listener, &.{ accepted, tcp.invalid_socket }, &read, &write));
    try check(read[0] and !read[1]);
    try check((try tcp.recv(accepted, &buf)) == 5);
    try check(std.mem.eql(u8, buf[0..5], "hello"));
    try check((try tcp.send(accepted, "world")) == 5);
    try check((try tcp.recv(client, &buf)) == 5);
    try check(std.mem.eql(u8, buf[0..5], "world"));
    try check((try tcp.send(accepted, "")) == 0);
    try check((try tcp.recv(accepted, buf[0..0])) == 0);
    // Both interfaces reject mismatched and over-capacity readiness sets.
    phase = "invalid readiness sets";
    if (tcp.wait(listener, &.{accepted}, &no_read, &no_write, 0)) |_| {
        return error.InvalidSetAccepted;
    } else |err| try check(err == error.InvalidSet);
    var many: [tcp.max_clients + 1]tcp.Socket = @splat(tcp.invalid_socket);
    var many_read: [tcp.max_clients + 1]bool = @splat(false);
    var many_write: [tcp.max_clients + 1]bool = @splat(false);
    if (tcp.wait(listener, &many, &many_read, &many_write, 0)) |_| {
        return error.InvalidSetAccepted;
    } else |err| try check(err == error.InvalidSet);
    tcp.close(client);
    client_closed = true;
    phase = "peer EOF";
    write = .{ false, false };
    _ = try ready(listener, &.{ accepted, tcp.invalid_socket }, &read, &write);
    try check(read[0]);
    try check((try tcp.recv(accepted, &buf)) == 0);
    tcp.close(tcp.invalid_socket);
    try backpressure(listener, port);
    var report_buf: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buf, "{{\"suite\":\"tcp_server\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
