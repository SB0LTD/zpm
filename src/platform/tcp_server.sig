//! Bounded nonblocking IPv4 TCP sockets for single-threaded servers (Layer 1).
//! Caller-owned receive/send buffers; no allocator and no background threads.
//! The small wait wrapper uses Winsock select or native POSIX poll.
//! The caller-backed wait uses WSAPoll, Linux syscalls or Darwin libSystem.
const std = @import("std");
const builtin = @import("builtin");
const win = @import("win32.sig");
const linux = std.os.linux;
const darwin = std.c;
const is_windows = builtin.os.tag == .windows;

pub const Socket = if (is_windows) win.SOCKET else linux.fd_t;
pub const invalid_socket: Socket = if (is_windows) win.INVALID_SOCKET else -1;
/// Capacity of the legacy stack-backed wait wrapper. Winsock select reserves
/// one additional descriptor for the listener.
pub const max_clients: usize = 63;
pub const WaitDescriptor = if (is_windows) win.WSAPOLLFD else if (builtin.os.tag == .macos) darwin.pollfd else linux.pollfd;
pub const Error = error{
    UnsupportedPlatform,
    StartupFailed,
    SocketFailed,
    BindFailed,
    ListenFailed,
    ConfigureFailed,
    AcceptFailed,
    ReceiveFailed,
    SendFailed,
    WaitFailed,
    InvalidSet,
    AddressFailed,
};

/// Pair each successful init with deinit; Winsock maintains its own refcount.
pub fn init() Error!void {
    if (is_windows) {
        var data: win.WSADATA = .{};
        if (win.WSAStartup(0x0202, &data) != 0) return error.StartupFailed;
    } else if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
}

pub fn deinit() void {
    if (is_windows) _ = win.WSACleanup();
}

/// Listen on the exact IPv4 address supplied by the application. Port 0 asks
/// the OS for an ephemeral port; use localPort to retrieve it.
pub fn listen(address: [4]u8, port: u16) Error!Socket {
    if (is_windows) {
        const fd = win.socket(win.AF_INET, win.SOCK_STREAM, win.IPPROTO_TCP);
        if (fd == invalid_socket) return error.SocketFailed;
        errdefer close(fd);
        try nonblocking(fd);
        var addr: win.sockaddr_in = .{ .sin_port = networkPort(port), .sin_addr = @bitCast(address) };
        if (win.bind(fd, &addr, @sizeOf(win.sockaddr_in)) != 0) return error.BindFailed;
        if (win.listen(fd, 128) != 0) return error.ListenFailed;
        return fd;
    } else if (builtin.os.tag == .linux) {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        const fd: Socket = @intCast(rc);
        errdefer close(fd);
        const enabled: c_int = 1;
        if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&enabled), @sizeOf(c_int))) != .SUCCESS)
            return error.ConfigureFailed;
        const addr: linux.sockaddr.in = .{ .port = networkPort(port), .addr = @bitCast(address) };
        if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
        if (linux.errno(linux.listen(fd, 128)) != .SUCCESS) return error.ListenFailed;
        return fd;
    } else if (builtin.os.tag == .macos) {
        const fd = darwin.socket(darwin.AF.INET, darwin.SOCK.STREAM, darwin.IPPROTO.TCP);
        if (fd < 0) return error.SocketFailed;
        errdefer close(fd);
        try nonblocking(fd);
        const enabled: c_int = 1;
        if (darwin.setsockopt(fd, darwin.SOL.SOCKET, darwin.SO.REUSEADDR, &enabled, @sizeOf(c_int)) != 0) return error.ConfigureFailed;
        const addr: darwin.sockaddr.in = .{ .port = networkPort(port), .addr = @bitCast(address) };
        if (darwin.bind(fd, @ptrCast(&addr), @sizeOf(darwin.sockaddr.in)) != 0) return error.BindFailed;
        if (darwin.listen(fd, 128) != 0) return error.ListenFailed;
        return fd;
    } else return error.UnsupportedPlatform;
}

pub fn localPort(fd: Socket) Error!u16 {
    if (is_windows) {
        var addr: win.sockaddr_in = .{};
        var size: c_int = @sizeOf(win.sockaddr_in);
        if (win.getsockname(fd, &addr, &size) != 0) return error.AddressFailed;
        return networkPort(addr.sin_port);
    } else if (builtin.os.tag == .linux) {
        var addr: linux.sockaddr.in = .{ .port = 0, .addr = 0 };
        var size: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        if (linux.errno(linux.getsockname(fd, @ptrCast(&addr), &size)) != .SUCCESS) return error.AddressFailed;
        return networkPort(addr.port);
    } else if (builtin.os.tag == .macos) {
        var addr: darwin.sockaddr.in = .{ .port = 0, .addr = 0 };
        var size: darwin.socklen_t = @sizeOf(darwin.sockaddr.in);
        if (darwin.getsockname(fd, @ptrCast(&addr), &size) != 0) return error.AddressFailed;
        return networkPort(addr.port);
    } else return error.UnsupportedPlatform;
}

/// null means the accept queue is empty. Accepted sockets are nonblocking,
/// have TCP_NODELAY enabled, and must be closed by the caller.
pub fn accept(listener: Socket) Error!?Socket {
    while (true) {
        if (is_windows) {
            const fd = win.accept(listener, null, null);
            if (fd == invalid_socket) {
                const code = win.WSAGetLastError();
                if (code == win.WSAEWOULDBLOCK) return null;
                if (code == 10004 or code == 10053) continue; // WSAEINTR, WSAECONNABORTED
                return error.AcceptFailed;
            }
            errdefer close(fd);
            try nonblocking(fd);
            const enabled: c_int = 1;
            if (win.setsockopt(fd, win.IPPROTO_TCP, win.TCP_NODELAY, &enabled, @sizeOf(c_int)) != 0) return error.ConfigureFailed;
            return fd;
        } else if (builtin.os.tag == .linux) {
            const rc = linux.accept4(listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return null,
                .INTR, .CONNABORTED => continue,
                else => return error.AcceptFailed,
            }
            const fd: Socket = @intCast(rc);
            errdefer close(fd);
            const enabled: c_int = 1;
            if (linux.errno(linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&enabled), @sizeOf(c_int))) != .SUCCESS)
                return error.ConfigureFailed;
            return fd;
        } else if (builtin.os.tag == .macos) {
            const fd = darwin.accept(listener, null, null);
            if (fd < 0) {
                switch (darwin.errno(fd)) {
                    .AGAIN => return null,
                    .INTR, .CONNABORTED => continue,
                    else => return error.AcceptFailed,
                }
            }
            errdefer close(fd);
            try nonblocking(fd);
            const enabled: c_int = 1;
            if (darwin.setsockopt(fd, darwin.IPPROTO.TCP, darwin.TCP.NODELAY, &enabled, @sizeOf(c_int)) != 0) return error.ConfigureFailed;
            return fd;
        } else return error.UnsupportedPlatform;
    }
}

/// null means would-block; zero means an orderly peer shutdown when buf is
/// nonempty. Empty buffers return zero without probing the connection.
pub fn recv(fd: Socket, buf: []u8) Error!?usize {
    if (buf.len == 0) return 0;
    while (true) {
        if (is_windows) {
            const rc = win.recv(fd, buf.ptr, @intCast(@min(buf.len, 0x7fffffff)), 0);
            if (rc >= 0) return @intCast(rc);
            const code = win.WSAGetLastError();
            if (code == win.WSAEWOULDBLOCK) return null;
            if (code == 10004) continue;
            return error.ReceiveFailed;
        } else if (builtin.os.tag == .linux) {
            const rc = linux.recvfrom(fd, buf.ptr, buf.len, linux.MSG.DONTWAIT, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .AGAIN => return null,
                .INTR => continue,
                else => return error.ReceiveFailed,
            }
        } else if (builtin.os.tag == .macos) {
            const rc = darwin.recv(fd, buf.ptr, buf.len, 0);
            if (rc >= 0) return @intCast(rc);
            switch (darwin.errno(rc)) {
                .AGAIN => return null,
                .INTR => continue,
                else => return error.ReceiveFailed,
            }
        } else return error.UnsupportedPlatform;
    }
}

/// May send fewer bytes than requested. null means would-block. Linux uses
/// MSG_NOSIGNAL and Darwin sockets have SO_NOSIGPIPE, preventing termination
/// when a disconnected peer is written to.
pub fn send(fd: Socket, buf: []const u8) Error!?usize {
    if (buf.len == 0) return 0;
    while (true) {
        if (is_windows) {
            const rc = win.send(fd, buf.ptr, @intCast(@min(buf.len, 0x7fffffff)), 0);
            if (rc >= 0) return @intCast(rc);
            const code = win.WSAGetLastError();
            if (code == win.WSAEWOULDBLOCK) return null;
            if (code == 10004) continue;
            return error.SendFailed;
        } else if (builtin.os.tag == .linux) {
            const rc = linux.sendto(fd, buf.ptr, buf.len, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .AGAIN => return null,
                .INTR => continue,
                else => return error.SendFailed,
            }
        } else if (builtin.os.tag == .macos) {
            const rc = darwin.send(fd, buf.ptr, buf.len, 0);
            if (rc >= 0) return @intCast(rc);
            switch (darwin.errno(rc)) {
                .AGAIN => return null,
                .INTR => continue,
                else => return error.SendFailed,
            }
        } else return error.UnsupportedPlatform;
    }
}

pub const timed_receive_available = builtin.os.tag == .linux and @sizeOf(usize) == 8;

/// Enable bounded blocking receive on an exclusively owned Linux socket.
/// Ordinary recv and send remain nonblocking even on this descriptor.
pub fn enableTimedReceive(fd: Socket, timeout_ms: u32) Error!void {
    if (comptime !timed_receive_available) return error.UnsupportedPlatform;
    if (timeout_ms == 0) return error.ConfigureFailed;
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.ConfigureFailed;
    const nonblock: u32 = @bitCast(@as(linux.O, .{ .NONBLOCK = true }));
    if (flags & nonblock == 0) return error.ConfigureFailed;
    const timeout: linux.timeval = .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @as(i64, timeout_ms % 1000) * 1000,
    };
    if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO,
        @ptrCast(&timeout), @sizeOf(linux.timeval))) != .SUCCESS) return error.ConfigureFailed;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags & ~@as(usize, nonblock))) != .SUCCESS)
        return error.ConfigureFailed;
}

/// Only for a descriptor configured by enableTimedReceive. A timeout or
/// interrupt returns control to the reactor without restarting the wait.
pub fn recvTimed(fd: Socket, buf: []u8) Error!?usize {
    if (comptime !timed_receive_available) return error.UnsupportedPlatform;
    if (buf.len == 0) return 0;
    const received = linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
    return switch (linux.errno(received)) {
        .SUCCESS => received,
        .AGAIN, .INTR => null,
        else => error.ReceiveFailed,
    };
}

pub fn close(fd: Socket) void {
    if (fd == invalid_socket) return;
    if (is_windows) {
        _ = win.closesocket(fd);
    } else if (builtin.os.tag == .linux) {
        // Do not retry close on EINTR: Linux has already released the fd.
        _ = linux.close(fd);
    } else if (builtin.os.tag == .macos) {
        // A retry could close a descriptor reused by another operation.
        _ = darwin.close(fd);
    }
}

/// Wait with fixed-size stack storage. Returns listener readiness. Invalid
/// socket entries are ignored. readable and writable must match clients.len.
/// writable is an input/output mask: request write readiness only for sockets
/// with pending output; all active sockets are monitored for reads/errors.
/// EINTR returns no readiness promptly so the application can check shutdown.
pub fn wait(listener: Socket, clients: []const Socket, readable: []bool, writable: []bool, timeout_ms: u32) Error!bool {
    if (clients.len > max_clients or clients.len != readable.len or clients.len != writable.len) return error.InvalidSet;
    @memset(readable, true);
    return waitMasked(listener, clients, readable, writable, timeout_ms);
}

/// Like wait, with readable also an input/output interest mask. Disable read
/// interest while a connection has a pending response to apply TCP backpressure
/// without a busy loop on its already-buffered next request. Error/hangup events
/// may still mark a socket readable so a disconnected client can be released.
pub fn waitMasked(listener: Socket, clients: []const Socket, readable: []bool, writable: []bool, timeout_ms: u32) Error!bool {
    if (clients.len > max_clients or clients.len != readable.len or clients.len != writable.len) return error.InvalidSet;
    if (is_windows) {
        var reads: win.fd_set = .{};
        var writes: win.fd_set = .{};
        var errors: win.fd_set = .{};
        if (listener != invalid_socket) add(&reads, listener);
        for (clients, readable, writable) |fd, wants_read, wants_write| {
            if (fd == invalid_socket) continue;
            if (wants_read) add(&reads, fd);
            add(&errors, fd);
            if (wants_write) add(&writes, fd);
        }
        @memset(readable, false);
        @memset(writable, false);
        if (reads.fd_count == 0 and writes.fd_count == 0 and errors.fd_count == 0) return error.InvalidSet;
        var timeout: win.timeval = .{ .tv_sec = @intCast(timeout_ms / 1000), .tv_usec = @intCast((timeout_ms % 1000) * 1000) };
        const rc = win.select(0, &reads, &writes, &errors, &timeout);
        if (rc == win.SOCKET_ERROR) {
            if (win.WSAGetLastError() == 10004) return false;
            return error.WaitFailed;
        }
        for (clients, readable, writable) |fd, *r, *w| {
            if (fd == invalid_socket) continue;
            r.* = contains(&reads, fd) or contains(&errors, fd);
            w.* = contains(&writes, fd);
        }
        return listener != invalid_socket and contains(&reads, listener);
    }
    var descriptors: [max_clients + 1]WaitDescriptor = undefined;
    return waitMaskedWithScratch(listener, clients, readable, writable, timeout_ms, &descriptors);
}

/// The caller supplies at least clients.len + 1 native descriptors, including
/// a slot for the listener. Interest and readiness follow waitMasked. Socket,
/// mask and scratch memory must be disjoint. The caller owns the socket set
/// throughout the wait. Hosted Windows needs at least one valid descriptor.
pub fn waitMaskedWithScratch(listener: Socket, clients: []const Socket, readable: []bool, writable: []bool, timeout_ms: u32, scratch: []WaitDescriptor) Error!bool {
    if (clients.len != readable.len or clients.len != writable.len or
        clients.len >= std.math.maxInt(u32) or scratch.len <= clients.len) return error.InvalidSet;
    if (comptime !is_windows and builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const Poll = if (is_windows) win.SOCKET_POLL else if (builtin.os.tag == .macos) darwin.POLL else linux.POLL;
    // Winsock's priority band is the exceptional condition monitored by the
    // small select wrapper. It also supplies interest on write-blocked sockets.
    const priority: i16 = if (is_windows) win.SOCKET_POLL.RDBAND else 0;
    const descriptors = scratch[0 .. clients.len + 1];
    descriptors[0] = .{ .fd = listener, .events = Poll.IN, .revents = 0 };
    var has_socket = listener != invalid_socket;
    for (clients, readable, writable, descriptors[1..]) |fd, wants_read, wants_write, *item| {
        has_socket = has_socket or fd != invalid_socket;
        const events = @as(i16, if (wants_read) Poll.IN else 0) | @as(i16, if (wants_write) Poll.OUT else 0) | priority;
        item.* = .{ .fd = fd, .events = events, .revents = 0 };
    }
    @memset(readable, false);
    @memset(writable, false);
    const timeout: i32 = @intCast(@min(timeout_ms, 0x7fffffff));
    if (is_windows) {
        if (!has_socket) return error.InvalidSet;
        if (win.WSAPoll(descriptors.ptr, @intCast(descriptors.len), timeout) == win.SOCKET_ERROR) {
            if (win.WSAGetLastError() == 10004) return false;
            return error.WaitFailed;
        }
    } else if (builtin.os.tag == .linux) {
        const rc = linux.poll(descriptors.ptr, descriptors.len, timeout);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return false,
            else => return error.WaitFailed,
        }
    } else if (darwin.poll(descriptors.ptr, @intCast(descriptors.len), timeout) < 0) {
        if (darwin.errno(@as(c_int, -1)) == .INTR) return false;
        return error.WaitFailed;
    }
    for (readable, writable, descriptors[1..]) |*r, *w, descriptor| {
        if (descriptor.fd == invalid_socket) continue;
        r.* = descriptor.revents & (Poll.IN | Poll.ERR | Poll.HUP | Poll.NVAL | priority) != 0;
        w.* = descriptor.revents & Poll.OUT != 0;
    }
    return listener != invalid_socket and descriptors[0].revents & Poll.IN != 0;
}

fn nonblocking(fd: Socket) Error!void {
    if (is_windows) {
        var enabled: c_ulong = 1;
        if (win.ioctlsocket(fd, win.FIONBIO, &enabled) != 0) return error.ConfigureFailed;
    } else if (builtin.os.tag == .macos) {
        const flags = darwin.fcntl(fd, darwin.F.GETFL);
        if (flags < 0) return error.ConfigureFailed;
        const nonblock: c_int = @bitCast(@as(darwin.O, .{ .NONBLOCK = true }));
        if (darwin.fcntl(fd, darwin.F.SETFL, flags | nonblock) < 0) return error.ConfigureFailed;
        if (darwin.fcntl(fd, darwin.F.SETFD, @as(c_int, darwin.FD_CLOEXEC)) < 0) return error.ConfigureFailed;
        const enabled: c_int = 1;
        if (darwin.setsockopt(fd, darwin.SOL.SOCKET, darwin.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0) return error.ConfigureFailed;
    }
}

fn add(set: *win.fd_set, fd: Socket) void {
    set.fd_array[set.fd_count] = fd;
    set.fd_count += 1;
}

fn contains(set: *const win.fd_set, fd: Socket) bool {
    for (set.fd_array[0..set.fd_count]) |value| if (value == fd) return true;
    return false;
}

fn networkPort(value: u16) u16 {
    return if (builtin.cpu.arch.endian() == .little) @byteSwap(value) else value;
}
