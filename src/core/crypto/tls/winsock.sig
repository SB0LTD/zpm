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
///
/// Reads are buffered: a single `recv` fills `rbuf`, and `readFn` serves the
/// TLS layer from it. TLS asks for a 5-byte record header then the body — two
/// tiny reads per record — so an unbuffered socket meant ≥2 `recv` syscalls
/// per record, most of them for a handful of bytes. With the buffer, one `recv`
/// typically satisfies several records' worth of header+body from memory. The
/// Socket is stored inline in a pinned owner (wss.WssClient), so `ctx = self`
/// in the vtable stays valid.
pub const Socket = struct {
    fd: w32.SOCKET = w32.INVALID_SOCKET,
    rbuf: [16384]u8 = undefined,
    r_off: usize = 0,
    r_len: usize = 0,

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

    /// Read some bytes into `buf`. Serves from the internal buffer first; when
    /// empty, does one `recv` to refill. Returns 0 on a clean peer close (EOF)
    /// — the TLS/WS layers above treat 0 as end-of-stream and tear down so the
    /// app can reconnect. A negative recv (socket error / forced close on
    /// shutdown) surfaces as Error.Io, which also unwinds to reconnect.
    fn readFn(ctx: *anyopaque, buf: []u8) tls.Error!usize {
        const self: *Socket = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return 0;
        if (self.r_off >= self.r_len) {
            const got = w32.recv(self.fd, &self.rbuf, @intCast(self.rbuf.len), 0);
            if (got < 0) return tls.Error.Io;
            if (got == 0) return 0; // peer closed → EOF
            self.r_off = 0;
            self.r_len = @intCast(got);
        }
        const avail = self.r_len - self.r_off;
        const n = @min(avail, buf.len);
        @memcpy(buf[0..n], self.rbuf[self.r_off .. self.r_off + n]);
        self.r_off += n;
        return n;
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

    // Try each resolved address until one connects. Use each addrinfo's own
    // family/type/protocol (correct even if the hints ever widen to AF_UNSPEC).
    var ai: ?*w32.addrinfo = res;
    while (ai) |a| : (ai = a.ai_next) {
        const addr = a.ai_addr orelse continue;
        const fd = w32.socket(a.ai_family, a.ai_socktype, a.ai_protocol);
        if (fd == w32.INVALID_SOCKET) continue;
        if (w32.connect(fd, addr, @intCast(a.ai_addrlen)) == 0) {
            // Disable Nagle: our TLS records (ClientHello, subscribe, ping) are
            // small and latency-sensitive; coalescing them adds up to ~200 ms.
            const one: c_int = 1;
            _ = w32.setsockopt(fd, w32.IPPROTO_TCP, w32.TCP_NODELAY, @ptrCast(&one), @sizeOf(c_int));
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
