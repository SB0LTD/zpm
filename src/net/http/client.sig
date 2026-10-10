// HTTP client module root.
//
// This is a placeholder implementation for the HTTP client module. It will be
// fully implemented in subsequent tasks.
//
// The module provides a pure-Sig HTTP/1.1 client that composes on the existing
// tls_client stack, mirroring the proven wss.sig layering.

pub const url = @import("url.sig");
const url_mod = url;
pub const errors = @import("errors.sig");
pub const request = @import("request.sig");
pub const response = @import("response.sig");
pub const body = @import("body.sig");
pub const cookie = @import("cookie.sig");
pub const transport = @import("transport.sig");
pub const socket_ext = @import("socket_ext.sig");
pub const protocol = @import("protocol.sig");
pub const retry = @import("retry.sig");
pub const redirect = @import("redirect.sig");

// ── One-shot fetch over the real stack ──────────────────────────────────────
//
// Composes the full lifecycle, allocation-free, into a single call:
//   connectDeadline -> (https: tlsc.handshake cert-verified | http: Plain)
//   -> set SO_*TIMEO -> Http1.send -> Http1.read -> absorb cookies -> close.
// Redirects (Req 9) and retries (Req 6) wrap the lifecycle; a typed Error +
// TlsFailKind is produced on every failure path, and an optional *Trace is
// filled as phases complete.

const std = @import("std");
const tlsc = @import("tls_client");
const w32 = @import("win32");

pub const Error = errors.Error;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Buffers = protocol.Buffers;
pub const CookieJar = cookie.CookieJar;
pub const CHROME_UA = cookie.CHROME_UA;
pub const Method = errors.Method;
pub const Trace = errors.Trace;
pub const TlsFailKind = errors.TlsFailKind;

var g_entropy_seeded: bool = false;

fn seedEntropyOnce() void {
    if (g_entropy_seeded) return;
    tlsc.fillEntropy();
    g_entropy_seeded = true;
}

fn classifyTls(e: tlsc.tls.Error, trace: ?*Trace) Error {
    const kind: TlsFailKind = switch (e) {
        error.CertInvalid => .cert_invalid,
        error.Io, error.Closed => .transport,
        else => .protocol,
    };
    if (trace) |t| t.tls_kind = kind;
    return Error.TlsFailed;
}

/// Perform one request/response lifecycle against an already-parsed URL over a
/// fresh connection. No redirect/retry logic here. Fills timing into `trace`.
fn fetchOnce(u: url_mod.Url, req: *const Request, bufs: Buffers, now: i64, keep_alive: bool, trace: ?*Trace) Error!Response {
    seedEntropyOnce();

    // 1. Connect with a deadline.
    var sock = socket_ext.connectDeadline(u.host, u.port, req.timeouts.connect_ms) catch |e| {
        if (trace) |t| t.wsa_last_error = socket_ext.lastError();
        return e;
    };
    errdefer sock.close();

    // 2. Apply socket-level recv/send timeouts.
    socket_ext.setRecvTimeout(sock.fd, req.timeouts.recv_ms);
    socket_ext.setSendTimeout(sock.fd, req.timeouts.send_ms);

    // 3. Build the transport: TLS for https, plaintext for http.
    var conn: tlsc.Conn = undefined;
    var plain: transport.PlainTransport = undefined;
    var tr: transport.Transport = undefined;
    if (u.scheme == .https) {
        conn = tlsc.handshake(sock.transport(), u.host, now) catch |e| {
            return classifyTls(e, trace);
        };
        tr = transport.connTransport(&conn);
    } else {
        plain = transport.PlainTransport.init(&sock);
        tr = plain.transport();
    }

    // 4. Send + read over the HTTP/1.1 protocol.
    try protocol.Http1.send(u, req, &tr, bufs, keep_alive);
    var resp = Response{};
    try protocol.Http1.read(&tr, bufs, req.method, &resp);

    // 5. Absorb cookies into the jar if present.
    if (req.jar) |jar| resp.absorbCookies(jar);

    // 6. One-shot: close the connection.
    tr.close();
    sock.close();
    return resp;
}

/// One-shot fetch: resolve, connect, (TLS), request, response, cookies, close.
/// Follows redirects up to req.max_redirects and retries transient failures
/// per req.retry. `now` is Unix seconds for cert validity. Allocation-free.
pub fn fetch(req: Request, bufs: Buffers, now: i64) Error!Response {
    if (req.trace) |t| t.* = .{};

    // Mutable current-request state across redirects.
    var cur_url_buf: [2048]u8 = undefined;
    var cur_url_len: usize = req.url.len;
    if (req.url.len > cur_url_buf.len) return Error.InvalidUrl;
    @memcpy(cur_url_buf[0..req.url.len], req.url);

    var cur = req; // copy; we mutate method/body/url across hops
    var redirects: u8 = 0;
    var attempt: u8 = 0;

    while (true) {
        // Parse the current URL.
        var host_buf: [256]u8 = undefined;
        const cur_raw = cur_url_buf[0..cur_url_len];
        const u = url_mod.Url.parse(cur_raw, &host_buf) catch return Error.InvalidUrl;
        cur.url = cur_raw;

        const result = fetchOnce(u, &cur, bufs, now, false, req.trace);

        if (result) |resp| {
            // Success path: check for a redirect to follow.
            if (redirect.isRedirect(resp.status)) {
                if (redirects >= cur.max_redirects) return Error.TooManyRedirects;
                const loc = resp.header("location") orelse return resp; // 3xx without Location: hand back
                var next_buf: [2048]u8 = undefined;
                const next = redirect.resolveLocation(u, cur_raw, loc, &next_buf) catch return Error.BadResponse;
                // Parse target to enforce scheme policy.
                var nhb: [256]u8 = undefined;
                const nu = url_mod.Url.parse(next, &nhb) catch return Error.BadResponse;
                if (redirect.insecureDowngrade(u.scheme, nu.scheme) and !cur.allow_insecure_redirect) {
                    return Error.ConnectFailed; // refuse https->http downgrade
                }
                // Rewrite method/body per status.
                const rw = redirect.rewriteMethod(cur.method, resp.status);
                cur.method = rw.method;
                if (rw.drop_body) { cur.body = ""; cur.content_type = ""; }
                // Adopt the new URL.
                if (next.len > cur_url_buf.len) return Error.InvalidUrl;
                @memcpy(cur_url_buf[0..next.len], next);
                cur_url_len = next.len;
                redirects += 1;
                if (req.trace) |t| t.redirects = redirects;
                continue;
            }
            // Not a redirect: possibly a retriable HTTP status.
            if (retry.shouldRetryStatus(cur.retry, resp.status) and retry.methodRetriable(cur.method, cur.retry_non_idempotent)) {
                if (attempt < cur.retry.max) {
                    attempt += 1;
                    if (req.trace) |t| t.attempts = attempt;
                    sleepBackoff(cur.retry, attempt, resp.status, resp.header("retry-after"), cur.timeouts.total_ms);
                    continue;
                }
                return Error.RetryExhausted;
            }
            return resp;
        } else |err| {
            // Transport-level failure: retry if transient + method allows.
            if (retry.shouldRetryError(err) and retry.methodRetriable(cur.method, cur.retry_non_idempotent) and attempt < cur.retry.max) {
                attempt += 1;
                if (req.trace) |t| t.attempts = attempt;
                sleepBackoff(cur.retry, attempt, 0, null, cur.timeouts.total_ms);
                continue;
            }
            return err;
        }
    }
}

fn sleepBackoff(policy: retry.RetryPolicy, attempt: u8, status: u16, retry_after: ?[]const u8, total_ms: u32) void {
    const d = retry.nextDelayMs(policy, attempt, status, retry_after, total_ms) orelse return;
    sleepMs(d);
}

fn sleepMs(ms: u32) void {
    w32.Sleep(ms);
}


// ── Keep-alive Client (pinned) ──────────────────────────────────────────────
//
// A connection-holding client for repeated requests to one host:port:scheme.
// PIN it: the transport vtables point into `self` (conn/plain), exactly like
// wss.WssClient, so it must not be moved after connect/send. Reuses the live
// connection when the previous response was keep-alive and fully consumed;
// reconnects on Connection: close, EOF, or a host/scheme change.
pub const Client = struct {
    sock: tlsc.Socket = .{},
    conn: tlsc.Conn = undefined,
    plain: transport.PlainTransport = undefined,
    scheme: url_mod.Scheme = .https,
    host_buf: [256]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 443,
    connected: bool = false,

    fn hostSlice(self: *const Client) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    /// True if a live connection matches the given target.
    fn matches(self: *const Client, u: url_mod.Url) bool {
        return self.connected and self.scheme == u.scheme and self.port == u.port and
            eqBytes(self.hostSlice(), u.host);
    }

    fn openTo(self: *Client, u: url_mod.Url, req: *const Request, now: i64) Error!void {
        seedEntropyOnce();
        self.sock = socket_ext.connectDeadline(u.host, u.port, req.timeouts.connect_ms) catch |e| {
            if (req.trace) |t| t.wsa_last_error = socket_ext.lastError();
            return e;
        };
        errdefer self.sock.close();
        socket_ext.setRecvTimeout(self.sock.fd, req.timeouts.recv_ms);
        socket_ext.setSendTimeout(self.sock.fd, req.timeouts.send_ms);
        if (u.scheme == .https) {
            self.conn = tlsc.handshake(self.sock.transport(), u.host, now) catch |e| {
                return classifyTls(e, req.trace);
            };
        } else {
            self.plain = transport.PlainTransport.init(&self.sock);
        }
        // Record the pinned target.
        if (u.host.len > self.host_buf.len) return Error.InvalidUrl;
        @memcpy(self.host_buf[0..u.host.len], u.host);
        self.host_len = u.host.len;
        self.scheme = u.scheme;
        self.port = u.port;
        self.connected = true;
    }

    fn transportFor(self: *Client, u: url_mod.Url) transport.Transport {
        if (u.scheme == .https) return transport.connTransport(&self.conn);
        return self.plain.transport();
    }

    /// Send a request, reusing the live connection when possible. On a stale
    /// connection (server closed / EOF) it transparently reconnects once.
    /// The URL host:port:scheme must be consistent across calls; a mismatch
    /// transparently reconnects to the new target.
    pub fn send(self: *Client, req: Request, bufs: Buffers, now: i64) Error!Response {
        if (req.trace) |t| t.* = .{};
        var host_buf: [256]u8 = undefined;
        const u = url_mod.Url.parse(req.url, &host_buf) catch return Error.InvalidUrl;

        // Reconnect if we have no live conn or the target changed.
        if (!self.matches(u)) {
            self.close();
            try self.openTo(u, &req, now);
        }

        // First attempt over the (possibly reused) connection.
        if (self.attempt(u, &req, bufs)) |resp| {
            self.afterResponse(&resp);
            return resp;
        } else |err| {
            // A reused connection may have been closed by the server between
            // requests; reconnect once and retry on a transient failure.
            if (err == Error.PrematureClose or err == Error.RecvFailed or err == Error.SendFailed) {
                self.close();
                try self.openTo(u, &req, now);
                const resp = try self.attempt(u, &req, bufs);
                self.afterResponse(&resp);
                return resp;
            }
            return err;
        }
    }

    fn attempt(self: *Client, u: url_mod.Url, req: *const Request, bufs: Buffers) Error!Response {
        var tr = self.transportFor(u);
        try protocol.Http1.send(u, req, &tr, bufs, true); // keep-alive
        var resp = Response{};
        try protocol.Http1.read(&tr, bufs, req.method, &resp);
        if (req.jar) |jar| resp.absorbCookies(jar);
        return resp;
    }

    /// Drop the connection if the server will not keep it alive.
    fn afterResponse(self: *Client, resp: *const Response) void {
        if (!resp.keep_alive or !resp.complete) self.close();
    }

    /// Close the connection (TLS close_notify if https, then the socket).
    pub fn close(self: *Client) void {
        if (self.connected and self.scheme == .https) self.conn.close();
        self.sock.close();
        self.connected = false;
    }

    /// Close ONLY the socket, to unblock a receive on another thread (wss
    /// parity). Writes nothing to the wire; safe cross-thread.
    pub fn shutdownSocket(self: *Client) void {
        self.sock.close();
    }
};

fn eqBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

// Tests (inline, std.testing). Connection reuse is validated end-to-end by the
// live-http harness (two sequential requests over one Client); here we cover
// the pure matching helper.
const testing = std.testing;

test "client: eqBytes host comparison" {
    try testing.expect(eqBytes("a.com", "a.com"));
    try testing.expect(!eqBytes("a.com", "b.com"));
    try testing.expect(!eqBytes("a.com", "a.co"));
}

test "client: fresh Client is not connected" {
    const c = Client{};
    try testing.expect(!c.connected);
    try testing.expectEqual(@as(usize, 0), c.host_len);
}
