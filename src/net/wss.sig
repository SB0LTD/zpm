// wss — a pure-Sig `wss://` WebSocket client (Windows).
// Layer 1: Net (composition of tls_client + websocket).
//
// This is the one-call client the exchange market-data streams use. It stacks
// three owned layers, wired by internal pointers:
//
//   websocket.Client  (RFC 6455 framing)
//        │  reads/writes plaintext through a websocket.Transport
//        ▼
//   tls_client.Conn   (TLS 1.3 record encryption)
//        │  reads/writes ciphertext through a tls.Transport
//        ▼
//   tls_client.Socket (Winsock TCP + getaddrinfo DNS)
//
// Because each layer's vtable holds a pointer to the layer below, all three
// live inside a single `WssClient` that the caller PINS (init in place via a
// `*WssClient`) — never copied after `connect`. Move it and the pointers
// dangle. Allocation-free: recv/scratch buffers are caller-supplied.
//
// Usage (per background thread):
//   var c: wss.WssClient = undefined;
//   try c.connect(.{ .host = "stream.binance.com", .port = 443,
//                    .path = "/ws/btcusdt@trade",
//                    .recv_buf = &recv, .scratch = &scratch, .now = unixSecs });
//   defer c.close();
//   const msg = try c.ws.receiveMessage();
//   try c.ws.sendText("{...}");

const tlsc = @import("tls_client");
const websocket = @import("websocket");

pub const Message = websocket.Message;

/// wss client errors. Mirrors websocket.Error plus TlsFailed, so callers can
/// tell a TLS handshake / cert-validation failure apart from a WebSocket
/// upgrade or framing failure.
pub const Error = error{
    ConnectFailed,
    TlsFailed,
    IoFailed,
    HandshakeFailed,
    MessageTooBig,
    ScratchTooSmall,
    Closed,
    ProtocolError,
};

pub const ConnectOptions = struct {
    /// Server hostname (resolved via getaddrinfo, used for SNI + cert + Host).
    host: []const u8,
    /// TLS port (443 for exchanges).
    port: u16 = 443,
    /// WebSocket request path, e.g. "/ws/btcusdt@trade".
    path: []const u8,
    /// Inbound message reassembly buffer (bounds max message size).
    recv_buf: []u8,
    /// Handshake scratch buffer (~2 KiB).
    scratch: []u8,
    /// Current time as Unix seconds (for certificate validity checks).
    now: i64,
    /// Optional 16-byte Sec-WebSocket-Key nonce (see websocket.HandshakeOptions).
    key_nonce: ?[16]u8 = null,
};

/// A fully-owned wss:// client. PIN this: pass a pointer to `connect`, and do
/// not move the value afterwards (the layers point into it).
pub const WssClient = struct {
    sock: tlsc.Socket = .{},
    conn: tlsc.Conn = undefined,
    ws: websocket.Client = undefined,
    connected: bool = false,

    /// Resolve + TCP-connect + TLS-handshake + WebSocket-upgrade, in place.
    /// On any failure the partially-open socket is torn down before returning.
    pub fn connect(self: *WssClient, opts: ConnectOptions) Error!void {
        // Seed CSPRNG entropy for the TLS ephemeral key + ClientHello.random.
        tlsc.fillEntropy();

        // 1. DNS + TCP.
        self.sock = tlsc.connectHost(opts.host, opts.port) catch return Error.ConnectFailed;
        errdefer self.sock.close();

        // 2. TLS 1.3 handshake (validates the cert chain to the CA bundle).
        self.conn = tlsc.handshake(self.sock.transport(), opts.host, opts.now) catch
            return Error.TlsFailed;

        // 3. WebSocket upgrade over the encrypted Conn.
        self.ws = websocket.Client.overTransport(connTransport(&self.conn), .{
            .host = opts.host,
            .port = opts.port,
            .path = opts.path,
            .recv_buf = opts.recv_buf,
            .scratch = opts.scratch,
            .key_nonce = opts.key_nonce,
        }) catch return Error.HandshakeFailed;

        self.connected = true;
    }

    pub fn receiveMessage(self: *WssClient) Error!Message {
        return self.ws.receiveMessage();
    }

    pub fn sendText(self: *WssClient, payload: []const u8) Error!void {
        return self.ws.sendText(payload);
    }

    pub fn sendBinary(self: *WssClient, payload: []const u8) Error!void {
        return self.ws.sendBinary(payload);
    }

    pub fn sendPing(self: *WssClient, payload: []const u8) Error!void {
        return self.ws.sendPing(payload);
    }

    /// Close the WebSocket (best-effort close frame + TLS close_notify) and the
    /// socket. Safe to call once; a no-op if never connected.
    ///
    /// Call this from the SAME thread that does receive/send — it writes a WS
    /// close frame and TLS close_notify. To unblock a receive on another thread
    /// during shutdown, use `shutdownSocket()` first (see its note).
    pub fn close(self: *WssClient) void {
        if (!self.connected) {
            self.sock.close();
            return;
        }
        // ws.close() sends the WS close frame then calls the transport close,
        // which for connTransport tears down the TLS Conn; then close the sock.
        self.ws.close();
        self.sock.close();
        self.connected = false;
    }

    /// Close ONLY the underlying TCP socket, without touching the TLS/WS layers.
    ///
    /// This is the cross-thread unblock primitive: a blocking `recv` on the
    /// socket returns immediately once the fd is closed, so a controller thread
    /// can wake a worker that is parked in `receiveMessage`. It writes nothing
    /// to the wire (no close frame / close_notify — those would race the
    /// worker's reads), so it is safe to call from a different thread than the
    /// one doing I/O. The worker then observes the read failure, exits its loop,
    /// and the controller joins it. Idempotent.
    pub fn shutdownSocket(self: *WssClient) void {
        self.sock.close();
    }
};

// ── TLS Conn → websocket.Transport adapter ──────────────────────────────────
// The websocket framer wants readSome/writeAll/close over plaintext; the TLS
// Conn provides exactly that (read returns decrypted app bytes, write encrypts).

fn connTransport(conn: *tlsc.Conn) websocket.Transport {
    return .{
        .ctx = conn,
        .readSomeFn = connRead,
        .writeAllFn = connWrite,
        .closeFn = connClose,
    };
}

fn connRead(ctx: *anyopaque, buf: []u8) websocket.Error!usize {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    const n = conn.read(buf) catch |err| switch (err) {
        error.Closed => return 0, // peer close_notify → EOF for the framer
        else => return websocket.Error.IoFailed,
    };
    return n;
}

fn connWrite(ctx: *anyopaque, data: []const u8) websocket.Error!void {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    conn.write(data) catch return websocket.Error.IoFailed;
}

fn connClose(ctx: *anyopaque) void {
    const conn: *tlsc.Conn = @ptrCast(@alignCast(ctx));
    conn.close();
}

// ── Tests ──────────────────────────────────────────────────────────────
// The transport adapter is pure glue; its behavior is exercised end-to-end by
// tests/live_wss.sig (a real network harness, not part of the unit aggregate).
const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
