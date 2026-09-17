// Winsock transport + entropy for the TLS client (Windows).
// Layer 1: platform glue for the tls_client module.
//
// Provides:
//   • connectHost(host, port) → a blocking TCP socket to host:port (DNS via
//     getaddrinfo), wrapped as a tls.Transport the handshake reads/writes over.
//   • fillEntropy() → seeds tls.setEntropy() from BCryptGenRandom (a CSPRNG),
//     giving the X25519 client key and ClientHello.random real randomness
//     (forward secrecy). Call once before handshakes.
//
// This is the only Windows-specific file in the TLS stack; everything else is
// pure computation. A different OS would provide its own transport with the
// same tls.Transport shape.

const w32 = @import("win32");
const tls = @import("tls.sig");

pub const Error = tls.Error;

/// A live TCP socket bound to the tls.Transport interface.
pub const Socket = struct {
    fd: w32.SOCKET = w32.INVALID_SOCKET,

    pub fn transport(self: *Socket) tls.Transport {
        return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
    }

    pub fn close(self: *Socket) void {
        if (self.fd != w32.INVALID_SOCKET) {
            _ = w32.shutdown(self.fd, w32.SD_BOTH);
            _ = w32.closesocket(self.fd);
            self.fd = w32.INVALID_SOCKET;
        }
    }

    fn readFn(ctx: *anyopaque, buf: []u8) tls.Error!usize {
        const self: *Socket = @ptrCast(@alignCast(ctx));
        const n = w32.recv(self.fd, buf.ptr, @intCast(buf.len), 0);
        if (n < 0) return tls.Error.Io;
        return @intCast(n);
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) tls.Error!void {
        const self: *Socket = @ptrCast(@alignCast(ctx));
        var off: usize = 0;
        while (off < data.len) {
            const n = w32.send(self.fd, data[off..].ptr, @intCast(data.len - off), 0);
            if (n <= 0) return tls.Error.Io;
            off += @intCast(n);
        }
    }
};

var g_wsa_started: bool = false;

fn ensureWsa() void {
    if (g_wsa_started) return;
    var data: w32.WSADATA = .{};
    _ = w32.WSAStartup(0x0202, &data); // request Winsock 2.2
    g_wsa_started = true;
}

/// Resolve `host` and open a blocking TCP connection to host:port.
/// `host` must be null-terminated-able (we copy into a small buffer).
pub fn connectHost(host: []const u8, port: u16) Error!Socket {
    ensureWsa();

    // Null-terminate host and port for getaddrinfo.
    var host_z: [256]u8 = undefined;
    if (host.len >= host_z.len) return Error.Io;
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
    const rc = w32.getaddrinfo(@ptrCast(&host_z), @ptrCast(&port_z), &hints, &res);
    if (rc != 0 or res == null) return Error.Io;
    defer w32.freeaddrinfo(res);

    // Try each resolved address until one connects.
    var ai: ?*w32.addrinfo = res;
    while (ai) |a| : (ai = a.ai_next) {
        const addr = a.ai_addr orelse continue;
        const fd = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
        if (fd == w32.INVALID_SOCKET) continue;
        if (w32.connect(fd, addr, @intCast(a.ai_addrlen)) == 0) {
            return .{ .fd = fd };
        }
        _ = w32.closesocket(fd);
    }
    return Error.Io;
}

/// Seed the TLS entropy from the OS CSPRNG. Call once at startup (and it is
/// cheap to call again). Without this, the TLS client uses fixed dev bytes.
pub fn fillEntropy() void {
    var e: [64]u8 = undefined;
    // BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002; alg handle may be null then.
    const status = w32.BCryptGenRandom(null, &e, 64, 0x00000002);
    if (status == 0) tls.setEntropy(&e);
}

fn fmtPort(buf: *[8]u8, port: u16) usize {
    if (port == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [8]u8 = undefined;
    var tl: usize = 0;
    var v = port;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(@as(u8, @intCast(v % 10)) + '0');
        tl += 1;
    }
    var i: usize = 0;
    while (i < tl) : (i += 1) buf[i] = tmp[tl - 1 - i];
    return tl;
}
