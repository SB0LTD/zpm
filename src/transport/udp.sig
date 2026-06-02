// Layer 1 — UDP socket I/O for QUIC transport.
//
// Thin wrapper over Win32 Winsock2 for non-blocking UDP send/receive.
// No knowledge of QUIC — just datagrams. Zero allocator usage.

const w32 = @import("win32");

// ── Error and Result Types ──

pub const SocketError = enum(u8) {
    none,
    would_block,
    connection_reset,
    buffer_too_small,
    bind_failed,
    other,
};

pub const RecvResult = struct {
    bytes_read: u16,
    src_addr: w32.sockaddr_in,
    err: SocketError,
};

pub const SendResult = struct {
    bytes_sent: u16,
    err: SocketError,
};

// ── WSAStartup guard ──

var wsa_initialized: bool = false;

fn ensureWsa() SocketError {
    if (wsa_initialized) return .none;
    var wsa_data: w32.WSADATA = .{};
    const rc = w32.WSAStartup(0x0202, &wsa_data);
    if (rc != 0) return .other;
    wsa_initialized = true;
    return .none;
}

// ── UdpSocket ──

pub const UdpSocket = struct {
    handle: w32.SOCKET,
    bound: bool,

    pub fn init() UdpSocket {
        const wsa_err = ensureWsa();
        if (wsa_err != .none) {
            return .{ .handle = w32.INVALID_SOCKET, .bound = false };
        }
        const h = w32.socket(w32.AF_INET, w32.SOCK_DGRAM, w32.IPPROTO_UDP);
        return .{ .handle = h, .bound = false };
    }

    pub fn bind(self: *UdpSocket, addr: w32.sockaddr_in) SocketError {
        if (self.handle == w32.INVALID_SOCKET) return .other;
        const rc = w32.bind(self.handle, &addr, @sizeOf(w32.sockaddr_in));
        if (rc == w32.SOCKET_ERROR) return .bind_failed;
        // Set non-blocking
        var one: c_ulong = 1;
        const iorc = w32.ioctlsocket(self.handle, w32.FIONBIO, &one);
        if (iorc == w32.SOCKET_ERROR) return .other;
        self.bound = true;
        return .none;
    }

    pub fn recv(self: *UdpSocket, buf: []u8) RecvResult {
        var src_addr: w32.sockaddr_in = .{};
        var addr_len: c_int = @sizeOf(w32.sockaddr_in);
        const len: c_int = if (buf.len > 65535) 65535 else @intCast(buf.len);
        const rc = w32.recvfrom(self.handle, buf.ptr, len, 0, &src_addr, &addr_len);
        if (rc == w32.SOCKET_ERROR) {
            const err_code = w32.WSAGetLastError();
            const err: SocketError = if (err_code == w32.WSAEWOULDBLOCK)
                .would_block
            else if (err_code == w32.WSAECONNRESET)
                .connection_reset
            else
                .other;
            return .{ .bytes_read = 0, .src_addr = src_addr, .err = err };
        }
        return .{ .bytes_read = @intCast(rc), .src_addr = src_addr, .err = .none };
    }

    pub fn send(self: *UdpSocket, buf: []const u8, dest: w32.sockaddr_in) SendResult {
        if (buf.len > 65535) return .{ .bytes_sent = 0, .err = .buffer_too_small };
        const len: c_int = @intCast(buf.len);
        const rc = w32.sendto(self.handle, buf.ptr, len, 0, &dest, @sizeOf(w32.sockaddr_in));
        if (rc == w32.SOCKET_ERROR) {
            const err_code = w32.WSAGetLastError();
            const err: SocketError = if (err_code == w32.WSAEWOULDBLOCK)
                .would_block
            else if (err_code == w32.WSAECONNRESET)
                .connection_reset
            else
                .other;
            return .{ .bytes_sent = 0, .err = err };
        }
        return .{ .bytes_sent = @intCast(rc), .err = .none };
    }

    pub fn deinit(self: *UdpSocket) void {
        if (self.handle != w32.INVALID_SOCKET) {
            _ = w32.closesocket(self.handle);
            self.handle = w32.INVALID_SOCKET;
        }
        self.bound = false;
    }

    /// Query the locally bound address (useful after binding to port 0).
    pub fn getLocalAddr(self: *const UdpSocket) struct { addr: w32.sockaddr_in, err: SocketError } {
        var addr: w32.sockaddr_in = .{};
        var addr_len: c_int = @sizeOf(w32.sockaddr_in);
        if (self.handle == w32.INVALID_SOCKET) return .{ .addr = addr, .err = .other };
        const rc = w32.getsockname(self.handle, &addr, &addr_len);
        if (rc == w32.SOCKET_ERROR) return .{ .addr = addr, .err = .other };
        return .{ .addr = addr, .err = .none };
    }
};

// ── Tests ──

const testing = @import("std").testing;

test "init returns valid socket" {
    var sock = UdpSocket.init();
    defer sock.deinit();
    try testing.expect(sock.handle != w32.INVALID_SOCKET);
}

test "bind to localhost:0 succeeds" {
    var sock = UdpSocket.init();
    defer sock.deinit();
    const addr = w32.sockaddr_in{
        .sin_port = 0,
        .sin_addr = 0x0100007F,
    };
    const err = sock.bind(addr);
    try testing.expectEqual(SocketError.none, err);
    try testing.expect(sock.bound);
}

test "recv on empty socket returns would_block" {
    var sock = UdpSocket.init();
    defer sock.deinit();
    const addr = w32.sockaddr_in{
        .sin_port = 0,
        .sin_addr = 0x0100007F,
    };
    _ = sock.bind(addr);
    var buf: [64]u8 = undefined;
    const result = sock.recv(&buf);
    try testing.expectEqual(SocketError.would_block, result.err);
}

test "send and recv loopback" {
    var receiver = UdpSocket.init();
    defer receiver.deinit();
    const recv_addr = w32.sockaddr_in{
        .sin_port = w32.htons(19877),
        .sin_addr = 0x0100007F,
    };
    const bind_err = receiver.bind(recv_addr);
    if (bind_err != .none) return;

    var sender = UdpSocket.init();
    defer sender.deinit();
    const send_addr = w32.sockaddr_in{
        .sin_port = 0,
        .sin_addr = 0x0100007F,
    };
    try testing.expectEqual(SocketError.none, sender.bind(send_addr));

    const payload = "hello quic";
    const dest = w32.sockaddr_in{
        .sin_port = w32.htons(19877),
        .sin_addr = 0x0100007F,
    };
    const send_result = sender.send(payload, dest);
    try testing.expectEqual(SocketError.none, send_result.err);
    try testing.expectEqual(@as(u16, payload.len), send_result.bytes_sent);

    w32.Sleep(10);

    var recv_buf: [64]u8 = undefined;
    const recv_result = receiver.recv(&recv_buf);
    try testing.expectEqual(SocketError.none, recv_result.err);
    try testing.expectEqual(@as(u16, payload.len), recv_result.bytes_read);
    try testing.expectEqualSlices(u8, payload, recv_buf[0..recv_result.bytes_read]);
}

test "deinit does not crash" {
    var sock = UdpSocket.init();
    sock.deinit();
    sock.deinit();
}
