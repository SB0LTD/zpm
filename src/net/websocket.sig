// websocket — a pure-Sig RFC 6455 WebSocket *client*.
// Layer 1: Platform / Net.
//
// The frame layer speaks to an abstract byte `Transport` (a tiny read/write/
// close vtable), so it is independent of how bytes reach the peer:
//   • plaintext over `std.Io.net.Stream` (cross-platform, used by the CDP
//     tooling client against ws://127.0.0.1);
//   • encrypted over a pure-Sig TLS 1.3 `Conn` (wss://), wired up in
//     `src/net/wss.sig` for the exchange market-data streams.
//
// There are no OS `#if`s here and no libc — the framer is pure computation over
// the Transport. TLS and DNS live behind the Transport, not in this file.
//
// Scope: everything a client needs to hold a real conversation with a server:
//   • opening handshake (HTTP/1.1 Upgrade, Sec-WebSocket-Key/Accept per §4.1)
//   • client frame masking (§5.3) — mandatory for clients
//   • send/receive of text & binary frames, including 16- and 64-bit lengths
//   • message reassembly across continuation frames (§5.4)
//   • control frames: ping→pong auto-reply, pong, and close handshake (§5.5)
//   • graceful close with status code
//
// It is allocation-free: the caller supplies the receive buffer (which bounds
// the largest message that can be reassembled) and a small scratch buffer for
// the handshake. Nothing here touches the heap.
//
// Deliberately out of scope: permessage-deflate compression, server role.
//
// Plaintext (CDP) usage:
//   var ws = try websocket.Client.connectStream(io, .{
//       .host = "127.0.0.1", .port = 9222, .path = "/devtools/page/ABC123",
//       .recv_buf = &recv, .scratch = &scratch,
//   });
//   defer ws.close();
//   try ws.sendText("{\"id\":1,\"method\":\"Page.enable\"}");
//   const msg = try ws.receiveMessage();     // msg.data is a text payload
//
// wss usage: see src/net/wss.sig, which builds the Transport from a TLS Conn.

const std = @import("std");
const net = std.Io.net;
const Sha1 = std.crypto.hash.Sha1;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
    _,

    fn isControl(op: Opcode) bool {
        return (@intFromEnum(op) & 0x8) != 0;
    }
};

pub const Error = error{
    /// The TCP connection could not be established.
    ConnectFailed,
    /// A socket read or write failed, or the peer closed mid-message.
    IoFailed,
    /// The server did not complete the HTTP Upgrade handshake correctly
    /// (missing "101 Switching Protocols" or a bad Sec-WebSocket-Accept).
    HandshakeFailed,
    /// A received frame's payload does not fit in the caller's recv buffer.
    MessageTooBig,
    /// The scratch buffer given for the handshake was too small.
    ScratchTooSmall,
    /// The peer sent a Close frame (normal end of stream when reading).
    Closed,
    /// A malformed frame (reserved bits, bad length, server-set mask, ...).
    ProtocolError,
};

/// A completed, reassembled application message.
pub const Message = struct {
    opcode: Opcode, // .text or .binary
    data: []const u8, // points into the client's recv buffer
};

// ── Transport ────────────────────────────────────────────────────────────
// The byte pipe the framer reads/writes through. `readSome` returns >0 bytes
// (0 means the peer closed), `writeAll` writes the whole slice, `close` tears
// the underlying connection down. This mirrors the TLS Conn / socket shape so
// either can back a WebSocket without the framer knowing which.
pub const Transport = struct {
    ctx: *anyopaque,
    readSomeFn: *const fn (ctx: *anyopaque, buf: []u8) Error!usize,
    writeAllFn: *const fn (ctx: *anyopaque, data: []const u8) Error!void,
    closeFn: *const fn (ctx: *anyopaque) void,

    fn readSome(self: *const Transport, buf: []u8) Error!usize {
        return self.readSomeFn(self.ctx, buf);
    }
    fn writeAll(self: *const Transport, data: []const u8) Error!void {
        return self.writeAllFn(self.ctx, data);
    }
    fn closeIt(self: *const Transport) void {
        self.closeFn(self.ctx);
    }
};

/// Options for the WebSocket opening handshake (transport already connected).
pub const HandshakeOptions = struct {
    /// Host used in the HTTP `Host:` header (the server's hostname).
    host: []const u8,
    /// Port for the `Host:` header. 0 omits the `:port` suffix (default ports).
    port: u16 = 0,
    /// Request-URI, e.g. "/ws/btcusdt@trade".
    path: []const u8,
    /// Buffer that holds a reassembled inbound message. Its length is the
    /// maximum message size the client can receive.
    recv_buf: []u8,
    /// Small scratch buffer used only during the opening handshake. 2 KiB is
    /// comfortable.
    scratch: []u8,
    /// A 16-byte nonce for Sec-WebSocket-Key. If null, a fixed dev nonce is
    /// used (the key is not a secret; it only guards against caching proxies).
    key_nonce: ?[16]u8 = null,
};

/// The magic GUID appended to the client key before hashing, per RFC 6455 §4.2.
const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// A connected WebSocket client. Holds a Transport plus the caller's receive
/// buffer. Fixed-size; no heap. Byte-at-a-time header reads are served from a
/// small internal buffer (`rbuf`) that `readSome` refills.
pub const Client = struct {
    transport: Transport,
    recv_buf: []u8,
    got_close: bool = false,
    /// Rolling source for the 4-byte client mask key (see `nextMaskKey`).
    mask_counter: u32 = 0x1a2b3c4d,
    /// Small buffered-read window over the transport for header byte reads.
    rbuf: [4096]u8 = undefined,
    r_off: usize = 0,
    r_len: usize = 0,

    // ── Construction ───────────────────────────────────────────────────────

    /// Run the WebSocket opening handshake over an already-connected transport.
    /// The transport is owned by the returned Client (closed by `close()`).
    ///
    /// The caller must keep the object backing `transport.ctx` alive for the
    /// lifetime of the Client (the vtable holds a pointer to it). For plaintext
    /// use `StreamTransport.connect` then pass `.transport()` here; for wss use
    /// src/net/wss.sig, which owns the TLS Conn + socket in a stable holder.
    pub fn overTransport(transport: Transport, opts: HandshakeOptions) Error!Client {
        var self = Client{ .transport = transport, .recv_buf = opts.recv_buf };
        try self.handshake(opts);
        return self;
    }

    // ── Opening handshake ───────────────────────────────────────────────────

    fn handshake(self: *Client, opts: HandshakeOptions) Error!void {
        const nonce = opts.key_nonce orelse default_nonce;
        var key_b64: [24]u8 = undefined; // base64 of 16 bytes = 24 chars
        _ = std.base64.standard.Encoder.encode(&key_b64, &nonce);

        // Build the request into scratch. Omit :port for default ports so the
        // Host header matches what servers expect (e.g. wss on 443).
        const req = if (opts.port == 0 or opts.port == 80 or opts.port == 443)
            std.fmt.bufPrint(opts.scratch,
                "GET {s} HTTP/1.1\r\n" ++
                    "Host: {s}\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Key: {s}\r\n" ++
                    "Sec-WebSocket-Version: 13\r\n" ++
                    "\r\n",
                .{ opts.path, opts.host, key_b64 },
            ) catch return Error.ScratchTooSmall
        else
            std.fmt.bufPrint(opts.scratch,
                "GET {s} HTTP/1.1\r\n" ++
                    "Host: {s}:{d}\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Key: {s}\r\n" ++
                    "Sec-WebSocket-Version: 13\r\n" ++
                    "\r\n",
                .{ opts.path, opts.host, opts.port, key_b64 },
            ) catch return Error.ScratchTooSmall;

        self.transport.writeAll(req) catch return Error.IoFailed;

        const status_ok = try self.readHandshakeResponse(opts.scratch, key_b64);
        if (!status_ok) return Error.HandshakeFailed;
    }

    /// Read the HTTP response until "\r\n\r\n", verify status 101 and that the
    /// Sec-WebSocket-Accept header matches base64(sha1(key ++ guid)).
    fn readHandshakeResponse(self: *Client, scratch: []u8, key_b64: [24]u8) Error!bool {
        var len: usize = 0;
        while (true) {
            if (len >= scratch.len) return Error.ScratchTooSmall;
            scratch[len] = try self.takeByte();
            len += 1;
            if (len >= 4 and
                scratch[len - 4] == '\r' and scratch[len - 3] == '\n' and
                scratch[len - 2] == '\r' and scratch[len - 1] == '\n') break;
        }
        const head = scratch[0..len];

        if (!containsSeq(head, "101")) return false;
        if (!containsCaseInsensitive(head, "upgrade")) return false;

        var sha: [Sha1.digest_length]u8 = undefined;
        var h = Sha1.init(.{});
        h.update(&key_b64);
        h.update(ws_guid);
        h.final(&sha);
        var expected: [28]u8 = undefined; // base64 of 20 bytes = 28 chars
        _ = std.base64.standard.Encoder.encode(&expected, &sha);

        return containsSeq(head, &expected);
    }

    // ── Buffered reads over the transport ────────────────────────────────────

    /// Read exactly one byte, refilling the internal window from the transport.
    fn takeByte(self: *Client) Error!u8 {
        if (self.r_off >= self.r_len) try self.refill();
        const b = self.rbuf[self.r_off];
        self.r_off += 1;
        return b;
    }

    /// Read exactly `dest.len` bytes: drain the window first, then pull the
    /// remainder straight from the transport.
    fn readExact(self: *Client, dest: []u8) Error!void {
        var off: usize = 0;
        // Serve from the buffered window.
        if (self.r_off < self.r_len) {
            const avail = self.r_len - self.r_off;
            const n = @min(avail, dest.len);
            @memcpy(dest[0..n], self.rbuf[self.r_off .. self.r_off + n]);
            self.r_off += n;
            off = n;
        }
        // Pull the rest directly.
        while (off < dest.len) {
            const n = self.transport.readSome(dest[off..]) catch return Error.IoFailed;
            if (n == 0) return Error.IoFailed;
            off += n;
        }
    }

    fn refill(self: *Client) Error!void {
        const n = self.transport.readSome(self.rbuf[0..]) catch return Error.IoFailed;
        if (n == 0) return Error.IoFailed;
        self.r_off = 0;
        self.r_len = n;
    }

    // ── Sending ──────────────────────────────────────────────────────────────

    pub fn sendText(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.text, payload);
    }

    pub fn sendBinary(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.binary, payload);
    }

    /// Write a single, unfragmented, masked client frame.
    fn sendFrame(self: *Client, op: Opcode, payload: []const u8) Error!void {
        var header: [14]u8 = undefined;
        var hlen: usize = 0;

        header[0] = 0x80 | @as(u8, @intFromEnum(op)); // FIN=1
        const mask_bit: u8 = 0x80; // clients MUST mask
        if (payload.len <= 125) {
            header[1] = mask_bit | @as(u8, @intCast(payload.len));
            hlen = 2;
        } else if (payload.len <= 0xFFFF) {
            header[1] = mask_bit | 126;
            header[2] = @intCast((payload.len >> 8) & 0xFF);
            header[3] = @intCast(payload.len & 0xFF);
            hlen = 4;
        } else {
            header[1] = mask_bit | 127;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                const shift: u6 = @intCast((7 - i) * 8);
                header[2 + i] = @intCast((payload.len >> shift) & 0xFF);
            }
            hlen = 10;
        }

        const key = self.nextMaskKey();
        header[hlen] = key[0];
        header[hlen + 1] = key[1];
        header[hlen + 2] = key[2];
        header[hlen + 3] = key[3];
        hlen += 4;

        self.transport.writeAll(header[0..hlen]) catch return Error.IoFailed;

        // Write masked payload in chunks so we never need a full copy buffer.
        var chunk: [1024]u8 = undefined;
        var off: usize = 0;
        while (off < payload.len) {
            const n = @min(chunk.len, payload.len - off);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                chunk[i] = payload[off + i] ^ key[(off + i) & 3];
            }
            self.transport.writeAll(chunk[0..n]) catch return Error.IoFailed;
            off += n;
        }
    }

    // ── Receiving ──────────────────────────────────────────────────────────

    /// Read frames until a full application message is assembled into
    /// `recv_buf`. Control frames are handled transparently: ping→pong, and a
    /// close frame ends the stream with `error.Closed`.
    pub fn receiveMessage(self: *Client) Error!Message {
        var total: usize = 0;
        var msg_op: Opcode = .continuation;

        while (true) {
            const fr = try self.readFrameHeader();

            if (fr.opcode.isControl()) {
                try self.handleControlFrame(fr);
                if (fr.opcode == .close) return Error.Closed;
                continue;
            }

            if (fr.opcode != .continuation) msg_op = fr.opcode;
            if (total + fr.payload_len > self.recv_buf.len) return Error.MessageTooBig;
            try self.readExact(self.recv_buf[total .. total + fr.payload_len]);
            total += fr.payload_len;

            if (fr.fin) {
                return Message{ .opcode = msg_op, .data = self.recv_buf[0..total] };
            }
        }
    }

    const FrameHeader = struct {
        fin: bool,
        opcode: Opcode,
        payload_len: usize,
    };

    /// Read and parse a frame header (server→client frames are never masked).
    fn readFrameHeader(self: *Client) Error!FrameHeader {
        const b0 = try self.takeByte();
        const b1 = try self.takeByte();

        const fin = (b0 & 0x80) != 0;
        const rsv = b0 & 0x70;
        if (rsv != 0) return Error.ProtocolError; // no extensions negotiated
        const opcode: Opcode = @enumFromInt(b0 & 0x0F);
        const masked = (b1 & 0x80) != 0;
        if (masked) return Error.ProtocolError; // servers MUST NOT mask

        var plen: usize = b1 & 0x7F;
        if (plen == 126) {
            const hi = try self.takeByte();
            const lo = try self.takeByte();
            plen = (@as(usize, hi) << 8) | lo;
        } else if (plen == 127) {
            var v: u64 = 0;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                v = (v << 8) | try self.takeByte();
            }
            plen = @intCast(v);
        }

        if (opcode.isControl() and (plen > 125 or !fin)) return Error.ProtocolError;

        return .{ .fin = fin, .opcode = opcode, .payload_len = plen };
    }

    /// Answer a ping with a pong (echoing the payload), record close frames.
    fn handleControlFrame(self: *Client, fr: FrameHeader) Error!void {
        var buf: [125]u8 = undefined;
        const body = buf[0..fr.payload_len];
        try self.readExact(body);

        switch (fr.opcode) {
            .ping => try self.sendFrame(.pong, body),
            .pong => {}, // unsolicited pong: ignore
            .close => {
                self.got_close = true;
                self.sendFrame(.close, body) catch {};
            },
            else => {},
        }
    }

    /// Send an application-level ping (keepalive). Some servers (e.g. KuCoin)
    /// expect periodic client pings.
    pub fn sendPing(self: *Client, payload: []const u8) Error!void {
        return self.sendFrame(.ping, payload);
    }

    // ── Teardown ─────────────────────────────────────────────────────────────

    /// Send a Close frame (status 1000) if we haven't already, then close the
    /// underlying transport. Safe to call once.
    pub fn close(self: *Client) void {
        if (!self.got_close) {
            const status = [_]u8{ 0x03, 0xe8 }; // 1000 normal closure
            self.sendFrame(.close, &status) catch {};
        }
        self.transport.closeIt();
    }

    // ── Masking key source ───────────────────────────────────────────────────

    fn nextMaskKey(self: *Client) [4]u8 {
        var x = self.mask_counter;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.mask_counter = x;
        return .{
            @intCast((x >> 24) & 0xFF),
            @intCast((x >> 16) & 0xFF),
            @intCast((x >> 8) & 0xFF),
            @intCast(x & 0xFF),
        };
    }
};

// ── Plaintext transport over std.Io.net.Stream (CDP) ───────────────────────
// A small adapter that presents a std.Io.net.Stream as a websocket.Transport.
// Kept here (not in a platform file) because it depends only on std.Io.
pub const StreamTransport = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    io: std.Io,
    rbuf: [4096]u8 = undefined,
    wbuf: [4096]u8 = undefined,

    pub fn connect(io: std.Io, host: []const u8, port: u16) !StreamTransport {
        const addr = try net.IpAddress.parse(host, port);
        const stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream, .protocol = .tcp });
        var self = StreamTransport{
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
            .io = io,
        };
        self.reader = stream.reader(io, self.rbuf[0..]);
        self.writer = stream.writer(io, self.wbuf[0..]);
        return self;
    }

    pub fn transport(self: *StreamTransport) Transport {
        return .{
            .ctx = self,
            .readSomeFn = readSomeFn,
            .writeAllFn = writeAllFn,
            .closeFn = closeFn,
        };
    }

    fn readSomeFn(ctx: *anyopaque, buf: []u8) Error!usize {
        const self: *StreamTransport = @ptrCast(@alignCast(ctx));
        const r = &self.reader.interface;
        // Block for at least one byte; std reader fills opportunistically.
        const b = r.takeByte() catch return Error.IoFailed;
        buf[0] = b;
        var n: usize = 1;
        // Drain whatever else is already buffered without blocking further.
        while (n < buf.len) {
            const more = r.takeByte() catch break;
            buf[n] = more;
            n += 1;
        }
        return n;
    }

    fn writeAllFn(ctx: *anyopaque, data: []const u8) Error!void {
        const self: *StreamTransport = @ptrCast(@alignCast(ctx));
        const w = &self.writer.interface;
        w.writeAll(data) catch return Error.IoFailed;
        w.flush() catch return Error.IoFailed;
    }

    fn closeFn(ctx: *anyopaque) void {
        const self: *StreamTransport = @ptrCast(@alignCast(ctx));
        self.stream.close(self.io);
    }
};

/// A fixed 16-byte nonce for tooling clients (see key_nonce).
const default_nonce = [16]u8{
    0x73, 0x62, 0x30, 0x2d, 0x77, 0x73, 0x2d, 0x6b,
    0x65, 0x79, 0x2d, 0x30, 0x31, 0x32, 0x33, 0x34,
};

// ── small byte-search helpers (no allocation) ──

fn containsSeq(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (lower(haystack[i + j]) != lower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "Sec-WebSocket-Accept matches the RFC 6455 example" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    var sha: [Sha1.digest_length]u8 = undefined;
    var h = Sha1.init(.{});
    h.update(key);
    h.update(ws_guid);
    h.final(&sha);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &sha);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "opcode control classification" {
    try testing.expect(Opcode.ping.isControl());
    try testing.expect(Opcode.pong.isControl());
    try testing.expect(Opcode.close.isControl());
    try testing.expect(!Opcode.text.isControl());
    try testing.expect(!Opcode.binary.isControl());
    try testing.expect(!Opcode.continuation.isControl());
}

// A trivial in-memory transport for exercising the framer without a network.
const MemTransport = struct {
    inbox: []const u8,
    in_off: usize = 0,
    outbox: [4096]u8 = undefined,
    out_len: usize = 0,

    fn transport(self: *MemTransport) Transport {
        return .{ .ctx = self, .readSomeFn = rd, .writeAllFn = wr, .closeFn = cl };
    }
    fn rd(ctx: *anyopaque, buf: []u8) Error!usize {
        const s: *MemTransport = @ptrCast(@alignCast(ctx));
        if (s.in_off >= s.inbox.len) return 0;
        const n = @min(buf.len, s.inbox.len - s.in_off);
        @memcpy(buf[0..n], s.inbox[s.in_off .. s.in_off + n]);
        s.in_off += n;
        return n;
    }
    fn wr(ctx: *anyopaque, data: []const u8) Error!void {
        const s: *MemTransport = @ptrCast(@alignCast(ctx));
        @memcpy(s.outbox[s.out_len .. s.out_len + data.len], data);
        s.out_len += data.len;
    }
    fn cl(ctx: *anyopaque) void {
        _ = ctx;
    }
};

test "mask key stream is non-constant and 4 bytes" {
    var c = Client{ .transport = undefined, .recv_buf = &.{} };
    const k1 = c.nextMaskKey();
    const k2 = c.nextMaskKey();
    try testing.expect(!std.mem.eql(u8, &k1, &k2));
}

test "receive a single unmasked text frame over a MemTransport" {
    // Server frame: FIN|text, len 5, "hello".
    const frame = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var mem = MemTransport{ .inbox = &frame };
    var recv: [64]u8 = undefined;
    var c = Client{ .transport = mem.transport(), .recv_buf = &recv };
    const msg = try c.receiveMessage();
    try testing.expectEqual(Opcode.text, msg.opcode);
    try testing.expectEqualStrings("hello", msg.data);
}

test "sendText emits a masked client frame with correct header" {
    var mem = MemTransport{ .inbox = &.{} };
    var recv: [64]u8 = undefined;
    var c = Client{ .transport = mem.transport(), .recv_buf = &recv };
    try c.sendText("hi");
    // Expect: 0x81 (FIN|text), 0x82 (mask|len2), 4-byte key, 2 masked bytes.
    try testing.expectEqual(@as(usize, 8), mem.out_len);
    try testing.expectEqual(@as(u8, 0x81), mem.outbox[0]);
    try testing.expectEqual(@as(u8, 0x82), mem.outbox[1]);
    const key = mem.outbox[2..6];
    try testing.expectEqual(@as(u8, 'h') ^ key[0], mem.outbox[6]);
    try testing.expectEqual(@as(u8, 'i') ^ key[1], mem.outbox[7]);
}

test "ping is answered with a pong carrying the same payload" {
    const frame = [_]u8{ 0x89, 0x02, 0x41, 0x42 }; // ping "AB"
    var mem = MemTransport{ .inbox = &frame };
    var recv: [64]u8 = undefined;
    var c = Client{ .transport = mem.transport(), .recv_buf = &recv };
    // receiveMessage will handle the ping then hit end-of-inbox (IoFailed).
    try testing.expectError(Error.IoFailed, c.receiveMessage());
    // A pong (0x8A) must have been written, masked, echoing "AB".
    try testing.expectEqual(@as(u8, 0x8a), mem.outbox[0]);
    try testing.expectEqual(@as(u8, 0x82), mem.outbox[1]);
    const key = mem.outbox[2..6];
    try testing.expectEqual(@as(u8, 0x41) ^ key[0], mem.outbox[6]);
    try testing.expectEqual(@as(u8, 0x42) ^ key[1], mem.outbox[7]);
}

test "containsSeq / case-insensitive header search" {
    const head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n";
    try testing.expect(containsSeq(head, "101"));
    try testing.expect(containsCaseInsensitive(head, "UPGRADE"));
    try testing.expect(containsCaseInsensitive(head, "WebSocket"));
    try testing.expect(!containsSeq(head, "404"));
}
