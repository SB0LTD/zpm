// Socket extensions over tls_client.winsock: per-socket timeouts, a connect
// deadline, and last-error capture (Req 5.1-5.3, 7.3).
//
// tls_client.connectHost stays the simple blocking resolve+connect. These
// helpers add the robustness the HTTP client needs on top of a Socket.fd:
//   setRecvTimeout / setSendTimeout -> SO_RCVTIMEO / SO_SNDTIMEO (ms)
//   connectDeadline                 -> non-blocking connect bounded by a deadline
//   lastError                       -> WSAGetLastError for Trace.wsa_last_error

const std = @import("std");
const w32 = @import("win32");
const tlsc = @import("tls_client");
const errors = @import("errors.sig");

pub const Error = errors.Error;

/// Winsock last-error code, for diagnostics (Trace.wsa_last_error).
pub fn lastError() i32 {
    return @intCast(w32.WSAGetLastError());
}

/// Set the receive timeout (ms) on a socket. 0 clears it (block forever).
pub fn setRecvTimeout(fd: w32.SOCKET, ms: u32) void {
    var v: w32.DWORD = ms;
    _ = w32.setsockopt(fd, w32.SOL_SOCKET, w32.SO_RCVTIMEO, @ptrCast(&v), @sizeOf(w32.DWORD));
}

/// Set the send timeout (ms) on a socket.
pub fn setSendTimeout(fd: w32.SOCKET, ms: u32) void {
    var v: w32.DWORD = ms;
    _ = w32.setsockopt(fd, w32.SOL_SOCKET, w32.SO_SNDTIMEO, @ptrCast(&v), @sizeOf(w32.DWORD));
}

/// Non-blocking connect bounded by `connect_ms`. Resolves host, connects with
/// a select() deadline, and returns a connected BLOCKING tlsc.Socket on success
/// (so subsequent read/write use the SO_*TIMEO timeouts). On failure returns
/// Error.Timeout (deadline) or Error.ConnectFailed (resolve/connect/other).
pub fn connectDeadline(host: []const u8, port: u16, connect_ms: u32) Error!tlsc.Socket {
    // Ensure Winsock is up (idempotent; tls_client also starts it).
    var wsa: w32.WSADATA = .{};
    _ = w32.WSAStartup(0x0202, &wsa);

    // Null-terminate host + port for getaddrinfo.
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return Error.ConnectFailed;
    @memcpy(host_z[0..host.len], host);
    host_z[host.len] = 0;
    var port_z: [8]u8 = undefined;
    const pl = fmtPort(&port_z, port);
    port_z[pl] = 0;

    var hints: w32.addrinfo = .{};
    hints.ai_family = w32.AF_INET;
    hints.ai_socktype = w32.SOCK_STREAM;
    hints.ai_protocol = w32.IPPROTO_TCP;
    var res: ?*w32.addrinfo = null;
    if (w32.getaddrinfo(@ptrCast(&host_z), @ptrCast(&port_z), &hints, &res) != 0 or res == null) {
        return Error.DnsFailed;
    }
    defer w32.freeaddrinfo(res);

    var ai: ?*w32.addrinfo = res;
    while (ai) |a| : (ai = a.ai_next) {
        const addr = a.ai_addr orelse continue;
        const fd = w32.socket(a.ai_family, a.ai_socktype, a.ai_protocol);
        if (fd == w32.INVALID_SOCKET) continue;

        // Non-blocking for the deadline connect.
        var nb: c_ulong = 1;
        _ = w32.ioctlsocket(fd, w32.FIONBIO, &nb);

        const rc = w32.connect(fd, addr, @intCast(a.ai_addrlen));
        var ok = (rc == 0);
        if (!ok) {
            const e = w32.WSAGetLastError();
            if (e == w32.WSAEWOULDBLOCK or e == w32.WSAEINPROGRESS) {
                ok = waitWritable(fd, connect_ms);
            }
        }

        if (ok and connectSucceeded(fd)) {
            // Back to blocking so SO_*TIMEO govern read/write.
            var block: c_ulong = 0;
            _ = w32.ioctlsocket(fd, w32.FIONBIO, &block);
            return tlsc.Socket{ .fd = fd };
        }
        _ = w32.closesocket(fd);
    }
    return Error.ConnectFailed;
}

/// Wait up to `ms` for the socket to become writable (connect completed).
/// Returns true if writable before the deadline, false on timeout/error.
fn waitWritable(fd: w32.SOCKET, ms: u32) bool {
    var wfds = w32.fd_set{};
    wfds.fd_count = 1;
    wfds.fd_array[0] = fd;
    var efds = w32.fd_set{};
    efds.fd_count = 1;
    efds.fd_array[0] = fd;
    var tv = w32.timeval{
        .tv_sec = @intCast(ms / 1000),
        .tv_usec = @intCast((ms % 1000) * 1000),
    };
    // nfds is ignored on Windows; pass 0.
    const n = w32.select(0, null, &wfds, &efds, &tv);
    if (n <= 0) return false; // 0 = timeout, SOCKET_ERROR < 0
    // If it landed in the exception set, the connect failed.
    if (efds.fd_count != 0 and efds.fd_array[0] == fd and wfds.fd_count == 0) return false;
    return true;
}

/// After select reports writable, confirm the connect truly succeeded via
/// SO_ERROR (0 == success).
fn connectSucceeded(fd: w32.SOCKET) bool {
    var err: c_int = 0;
    var len: c_int = @sizeOf(c_int);
    const rc = w32.getsockopt(fd, w32.SOL_SOCKET, w32.SO_ERROR, @ptrCast(&err), &len);
    if (rc != 0) return false;
    return err == 0;
}

fn fmtPort(buf: []u8, port: u16) usize {
    if (port == 0) { buf[0] = '0'; return 1; }
    var tmp: [5]u8 = undefined;
    var n: usize = 0;
    var p = port;
    while (p > 0) : (p /= 10) { tmp[n] = '0' + @as(u8, @intCast(p % 10)); n += 1; }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = tmp[n - 1 - i];
    return n;
}

// Tests (inline, std.testing). The network paths (connectDeadline) are
// exercised by the live integration test; here we cover the pure helper.
const testing = std.testing;

test "socket_ext: fmtPort formats decimal ports" {
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), fmtPort(&buf, 443));
    try testing.expectEqualSlices(u8, "443", buf[0..3]);
    try testing.expectEqual(@as(usize, 2), fmtPort(&buf, 80));
    try testing.expectEqualSlices(u8, "80", buf[0..2]);
    try testing.expectEqual(@as(usize, 5), fmtPort(&buf, 65535));
    try testing.expectEqualSlices(u8, "65535", buf[0..5]);
    try testing.expectEqual(@as(usize, 1), fmtPort(&buf, 0));
    try testing.expectEqualSlices(u8, "0", buf[0..1]);
}
