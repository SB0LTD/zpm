// Layer 2 — QUIC/HTTP3 Server.
//
// Event-driven server that accepts QUIC connections over a single UDP socket,
// multiplexes streams, and dispatches HTTP/3 requests to application handlers.
//
// Design principles:
//   - Single-threaded event loop (no locks, no atomics in the hot path)
//   - Zero allocator usage (fixed connection pool, pre-allocated buffers)
//   - No TCP fallback (QUIC-only; modern clients required)
//   - Integrated TLS 1.3 (RFC 9001, part of the QUIC handshake)
//   - HTTP/3 native (RFC 9114, frames directly on QUIC streams)
//
// Concurrency model:
//   The server tick() processes ONE UDP recv batch, advances all connection
//   state machines, and calls application handlers inline. For CPU-bound
//   response generation (compression, crypto, AI inference), the handler
//   posts work to the zpm thread pool and streams results back.
//
// Connection lifecycle:
//   1. UDP packet arrives → parse QUIC header → route by DCID
//   2. New DCID → allocate from connection pool → handshake
//   3. Handshake complete → H3 control stream exchange
//   4. Request stream opened → parse HEADERS → dispatch to handler
//   5. Handler writes response HEADERS + DATA frames
//   6. Stream closes → connection stays alive for next request
//   7. Idle timeout or GOAWAY → drain → close → return to pool

const conn = @import("conn");
const packet = @import("packet");
const streams = @import("streams");
const udp = @import("udp");
const h3 = @import("h3");
const telemetry = @import("telemetry");

// ══════════════════════════════════════════════════════════════════════════════
// Configuration
// ══════════════════════════════════════════════════════════════════════════════

/// Maximum concurrent QUIC connections.
pub const max_connections: u16 = 256;

/// Maximum concurrent streams per connection (set in transport params).
pub const max_streams_per_conn: u16 = 64;

/// Server receive buffer size (UDP).
pub const recv_buf_size: u32 = 65536;

/// Maximum request header section size.
pub const max_header_size: u32 = 65536;

// ══════════════════════════════════════════════════════════════════════════════
// Request / Response Types
// ══════════════════════════════════════════════════════════════════════════════

/// Parsed HTTP/3 request presented to the application handler.
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8,
    scheme: []const u8,
    headers: []const h3.HeaderField,
    header_count: usize,
    body: []const u8,
    stream_id: u64,
    conn_index: u16,
};

/// Response builder. The handler populates this; the server serializes it.
pub const Response = struct {
    status: u16 = 200,
    headers: [32][2][]const u8 = undefined,
    header_count: usize = 0,
    body: []const u8 = "",

    pub fn setStatus(self: *Response, code: u16) void {
        self.status = code;
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) void {
        if (self.header_count < 32) {
            self.headers[self.header_count] = .{ name, value };
            self.header_count += 1;
        }
    }

    pub fn setBody(self: *Response, body: []const u8) void {
        self.body = body;
    }
};

/// Application request handler function signature.
pub const Handler = *const fn (req: *const Request, resp: *Response) void;

// ══════════════════════════════════════════════════════════════════════════════
// Route Table
// ══════════════════════════════════════════════════════════════════════════════

/// A route maps a path prefix to a handler.
pub const Route = struct {
    path: []const u8,
    handler: Handler,
    /// If true, matches any path that STARTS with `path` (prefix match).
    /// If false, exact match only.
    prefix: bool = false,
};

/// Maximum routes.
pub const max_routes: u16 = 128;

// ══════════════════════════════════════════════════════════════════════════════
// Server State
// ══════════════════════════════════════════════════════════════════════════════

pub const Server = struct {
    socket: udp.UdpSocket,
    routes: [max_routes]Route,
    route_count: u16,
    settings: h3.Settings,
    running: bool,

    // Connection pool (fixed-size, pre-allocated externally)
    connections: [*]conn.Connection,
    stream_arrays: [*]streams.StreamArray,
    conn_active: [max_connections]bool,
    conn_count: u16,

    // TLS certificate (PEM pointers — caller owns the data)
    cert_pem_ptr: ?[*]const u8,
    cert_pem_len: u32,
    key_pem_ptr: ?[*]const u8,
    key_pem_len: u32,

    // Stats
    total_requests: u64,
    total_connections: u64,
    active_connections: u16,

    /// Initialize server bound to the given port. Caller provides the
    /// connection and stream storage (they're too large for the stack).
    pub fn init(
        port: u16,
        connections_buf: [*]conn.Connection,
        streams_buf: [*]streams.StreamArray,
    ) Server {
        var s = Server{
            .socket = udp.UdpSocket.init(),
            .routes = undefined,
            .route_count = 0,
            .settings = .{},
            .running = false,
            .connections = connections_buf,
            .stream_arrays = streams_buf,
            .conn_active = @splat(false),
            .conn_count = 0,
            .cert_pem_ptr = null,
            .cert_pem_len = 0,
            .key_pem_ptr = null,
            .key_pem_len = 0,
            .total_requests = 0,
            .total_connections = 0,
            .active_connections = 0,
        };
        const addr = udp.w32.sockaddr_in{
            .sin_port = udp.w32.htons(port),
            .sin_addr = 0x00000000, // INADDR_ANY
        };
        _ = s.socket.bind(addr);
        return s;
    }

    /// Register a route. Routes are matched in registration order.
    pub fn route(self: *Server, path: []const u8, handler: Handler) void {
        if (self.route_count < max_routes) {
            self.routes[self.route_count] = .{ .path = path, .handler = handler };
            self.route_count += 1;
        }
    }

    /// Register a prefix route (matches any path starting with prefix).
    pub fn routePrefix(self: *Server, prefix: []const u8, handler: Handler) void {
        if (self.route_count < max_routes) {
            self.routes[self.route_count] = .{ .path = prefix, .handler = handler, .prefix = true };
            self.route_count += 1;
        }
    }

    /// Start the server event loop (blocks).
    pub fn listen(self: *Server) void {
        self.running = true;
        while (self.running) {
            self.tick();
        }
    }

    /// Process one batch of events. Call this in your own loop for integration.
    pub fn tick(self: *Server) void {
        // 1. Receive UDP packets
        var recv_buf: [recv_buf_size]u8 = undefined;
        const result = self.socket.recv(&recv_buf);
        if (result.err == .none and result.bytes_read > 0) {
            self.handlePacket(recv_buf[0..result.bytes_read], result.src_addr);
        }

        // 2. Advance all active connections (timers, retransmits, idle, H3 dispatch)
        for (0..max_connections) |i| {
            if (self.conn_active[i]) {
                self.tickConnection(@intCast(i));
            }
        }
    }

    /// Graceful shutdown — send GOAWAY to all active connections, then drain.
    pub fn shutdown(self: *Server) void {
        self.running = false;
        // Send GOAWAY on each active connection's control stream
        for (0..max_connections) |i| {
            if (self.conn_active[i]) {
                var c = &self.connections[i];
                if (c.state == .connected) {
                    // GOAWAY with stream_id = highest client bidi stream we've processed
                    var goaway_buf: [16]u8 = undefined;
                    const goaway_len = h3.serializeGoaway(self.total_requests * 4, &goaway_buf);
                    if (goaway_len > 0) {
                        // Write GOAWAY to control stream (unidirectional stream 3 = server uni)
                        _ = c.stream_mgr.writeToStream(3, goaway_buf[0..goaway_len]);
                    }
                    c.close(0, "shutdown");
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // Internal
    // ══════════════════════════════════════════════════════════════════════

    fn handlePacket(self: *Server, data: []const u8, src: udp.w32.sockaddr_in) void {
        // Parse QUIC header to route by DCID
        const hdr_result = packet.parseHeader(data);
        if (hdr_result.err != .none) return;
        const header = hdr_result.header;

        // Find existing connection by DCID
        const conn_idx = self.findConnection(header.dst_cid) orelse {
            // Only accept Initial packets for new connections
            if (!header.is_long or header.pkt_type != .initial) return;

            // New connection — allocate from pool
            const idx = self.allocConnection() orelse return;
            self.conn_active[idx] = true;
            self.active_connections += 1;
            self.total_connections += 1;

            // Initialize as server connection (port 0 — uses shared listen socket)
            self.connections[idx] = conn.Connection.initServer(
                &self.stream_arrays[idx],
                0,
            );

            // Load TLS certificate and set ALPN on this connection
            var c = &self.connections[idx];
            if (self.cert_pem_ptr) |cert| {
                if (self.key_pem_ptr) |key| {
                    _ = c.loadTlsCertificatePem(cert[0..self.cert_pem_len], key[0..self.key_pem_len]);
                }
            }
            c.setTlsAlpn("h3");

            // Feed the Initial packet — drives handshake
            const state = c.feedAndRespond(data, src);
            _ = state;

            // Send any response produced (ServerHello, etc.) via the listen socket
            if (c.last_send_len > 0) {
                _ = self.socket.send(c.send_buf[0..c.last_send_len], src);
            }
            return;
        };

        self.processPacket(conn_idx, data, src);
    }

    /// Feed a packet into an existing connection's state machine, then
    /// check for completed HTTP/3 requests and dispatch them.
    fn processPacket(self: *Server, idx: u16, data: []const u8, src: udp.w32.sockaddr_in) void {
        var c = &self.connections[idx];

        // Drive the connection: decrypt, dispatch frames, assemble response
        const state = c.feedAndRespond(data, src);

        // Send any outgoing data via the shared listen socket
        if (c.last_send_len > 0) {
            _ = self.socket.send(c.send_buf[0..c.last_send_len], src);
        }

        // If connected, check for HTTP/3 request data on streams
        if (state == .connected) {
            self.dispatchH3Requests(idx);
        }

        // Handle connection closure — return slot to pool
        if (state == .closed) {
            self.conn_active[idx] = false;
            if (self.active_connections > 0) self.active_connections -= 1;
        }
    }

    /// Advance a connection's timers (idle timeout, loss detection, retransmit).
    /// Also checks for pending stream data that may have arrived across multiple
    /// packets and dispatches any complete H3 requests.
    fn tickConnection(self: *Server, idx: u16) void {
        var c = &self.connections[idx];

        // Use tick() to advance timers and handle retransmissions
        const state = c.tick();

        // Send any data produced by the tick (retransmits, ACKs, keepalives)
        if (c.last_send_len > 0) {
            _ = self.socket.send(c.send_buf[0..c.last_send_len], c.peer_addr);
        }

        // Dispatch any pending H3 requests
        if (state == .connected) {
            self.dispatchH3Requests(idx);
        }

        // Handle connection closure — return slot to pool
        if (state == .closed) {
            self.conn_active[idx] = false;
            if (self.active_connections > 0) self.active_connections -= 1;
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // HTTP/3 Request Dispatch
    // ══════════════════════════════════════════════════════════════════════

    /// Scan all streams on a connection for readable data, parse HTTP/3
    /// HEADERS frames, dispatch to application handlers, and write the
    /// response back into the stream's send buffer.
    fn dispatchH3Requests(self: *Server, conn_idx: u16) void {
        var c = &self.connections[conn_idx];
        const sm = &c.stream_mgr;

        // Iterate all active streams looking for client-initiated bidi streams
        // with data to read. Client bidi stream IDs: 0, 4, 8, 12, ...
        for (0..sm.stream_count) |i| {
            const s = &sm.streams[i];

            // Only process client-initiated bidirectional request streams
            // Stream ID bits: 0b00 = client bidi
            if (s.id & 0x03 != 0x00) continue;

            // Need data available to parse
            const avail = s.recv_buf.available();
            if (avail == 0) continue;

            // Only dispatch streams in open or half_closed_remote state
            // (half_closed_remote means client sent FIN — request fully received)
            if (s.state != .open and s.state != .half_closed_remote) continue;

            // Read stream data into a scratch buffer for H3 frame parsing
            var stream_data: [max_header_size]u8 = undefined;
            const read_len = s.recv_buf.read(stream_data[0..@min(avail, max_header_size)]);
            if (read_len == 0) continue;

            // Parse H3 frame header
            const frame_hdr = h3.parseFrameHeader(stream_data[0..read_len]) orelse continue;

            // We only handle HEADERS frames for request dispatch
            if (frame_hdr.frame_type != @intFromEnum(h3.FrameType.headers)) continue;

            // Ensure we have the complete HEADERS payload
            const payload_end = frame_hdr.header_len + @as(usize, @intCast(frame_hdr.payload_len));
            if (read_len < payload_end) continue; // incomplete, need more data

            // Decode QPACK headers from the HEADERS frame payload
            const headers_payload = stream_data[frame_hdr.header_len..payload_end];
            var decoded_headers: [32]h3.HeaderField = undefined;
            const header_count = h3.decodeHeaders(headers_payload, &decoded_headers);
            if (header_count == 0) continue;

            // Extract pseudo-headers (:method, :path, :authority, :scheme)
            var method: []const u8 = "GET";
            var path: []const u8 = "/";
            var authority: []const u8 = "";
            var scheme: []const u8 = "https";

            for (decoded_headers[0..header_count]) |hf| {
                if (strEql(hf.name, ":method")) method = hf.value
                else if (strEql(hf.name, ":path")) path = hf.value
                else if (strEql(hf.name, ":authority")) authority = hf.value
                else if (strEql(hf.name, ":scheme")) scheme = hf.value;
            }

            // Check for DATA frame following HEADERS (request body)
            var body: []const u8 = "";
            var body_buf: [4096]u8 = undefined;
            if (read_len > payload_end) {
                const remaining = stream_data[payload_end..read_len];
                const data_hdr = h3.parseFrameHeader(remaining);
                if (data_hdr) |dh| {
                    if (dh.frame_type == @intFromEnum(h3.FrameType.data)) {
                        const data_end = dh.header_len + @as(usize, @intCast(dh.payload_len));
                        if (remaining.len >= data_end) {
                            const body_len = @min(dh.payload_len, body_buf.len);
                            @memcpy(body_buf[0..body_len], remaining[dh.header_len..][0..body_len]);
                            body = body_buf[0..body_len];
                        }
                    }
                }
            }

            // Build Request
            const req = Request{
                .method = method,
                .path = path,
                .authority = authority,
                .scheme = scheme,
                .headers = &decoded_headers,
                .header_count = header_count,
                .body = body,
                .stream_id = s.id,
                .conn_index = conn_idx,
            };

            // Match route and invoke handler
            var resp = Response{};
            const handler = self.matchRoute(path) orelse {
                // No route matched — 404
                resp.setStatus(404);
                resp.addHeader("content-type", "text/plain");
                resp.setBody("not found");
                self.sendH3Response(conn_idx, s.id, &resp);
                self.total_requests += 1;
                continue;
            };

            handler(&req, &resp);
            self.sendH3Response(conn_idx, s.id, &resp);
            self.total_requests += 1;
        }
    }

    /// Serialize an HTTP/3 response (HEADERS + DATA frames) and write it
    /// into the stream's send buffer for the next packet assembly.
    fn sendH3Response(self: *Server, conn_idx: u16, stream_id: u64, resp: *const Response) void {
        var c = &self.connections[conn_idx];

        // Build response headers: :status + application headers
        var resp_headers: [34][2][]const u8 = undefined;
        var rh_count: usize = 0;

        // :status pseudo-header
        var status_buf: [3]u8 = undefined;
        status_buf[0] = '0' + @as(u8, @intCast(resp.status / 100));
        status_buf[1] = '0' + @as(u8, @intCast((resp.status / 10) % 10));
        status_buf[2] = '0' + @as(u8, @intCast(resp.status % 10));
        resp_headers[rh_count] = .{ ":status", &status_buf };
        rh_count += 1;

        // Application headers
        for (0..resp.header_count) |i| {
            if (rh_count >= 34) break;
            resp_headers[rh_count] = resp.headers[i];
            rh_count += 1;
        }

        // Encode HEADERS frame (QPACK static-only + frame header)
        var h3_buf: [4096]u8 = undefined;
        var h3_len: usize = 0;
        h3_len += h3.encodeHeadersFrame(resp_headers[0..rh_count], h3_buf[h3_len..]);

        // Encode DATA frame (if body present)
        if (resp.body.len > 0) {
            h3_len += h3.encodeDataFrameHeader(resp.body.len, h3_buf[h3_len..]);
            const copy_len = @min(resp.body.len, h3_buf.len - h3_len);
            @memcpy(h3_buf[h3_len..][0..copy_len], resp.body[0..copy_len]);
            h3_len += copy_len;
        }

        // Write the complete H3 response into the stream's send buffer
        _ = c.stream_mgr.writeToStream(stream_id, h3_buf[0..h3_len]);

        // Half-close the stream (server done sending)
        c.stream_mgr.closeStream(stream_id);
    }

    // ══════════════════════════════════════════════════════════════════════
    // TLS Configuration
    // ══════════════════════════════════════════════════════════════════════

    /// Load a TLS certificate (PEM-encoded) for all future connections.
    /// Must be called before listen(). The server stores pointers to the
    /// PEM data — caller must ensure the data outlives the server.
    pub fn loadCertificate(self: *Server, cert_pem: []const u8, key_pem: []const u8) void {
        self.cert_pem_ptr = cert_pem.ptr;
        self.cert_pem_len = @intCast(cert_pem.len);
        self.key_pem_ptr = key_pem.ptr;
        self.key_pem_len = @intCast(key_pem.len);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Connection Pool
    // ══════════════════════════════════════════════════════════════════════

    fn findConnection(self: *Server, dcid: packet.ConnectionId) ?u16 {
        for (0..max_connections) |i| {
            if (self.conn_active[i]) {
                const c = &self.connections[i];
                // Check all local CIDs on this connection
                for (0..c.local_cid_count) |ci| {
                    if (cidEql(c.local_cids[ci], dcid)) return @intCast(i);
                }
            }
        }
        return null;
    }

    fn allocConnection(self: *Server) ?u16 {
        for (0..max_connections) |i| {
            if (!self.conn_active[i]) return @intCast(i);
        }
        return null; // pool exhausted
    }

    fn cidEql(a: packet.ConnectionId, b: packet.ConnectionId) bool {
        if (a.len != b.len) return false;
        for (0..a.len) |i| {
            if (a.buf[i] != b.buf[i]) return false;
        }
        return true;
    }

    /// Match a request path against registered routes.
    /// Exact matches are checked first (in registration order), then prefix matches.
    fn matchRoute(self: *Server, path: []const u8) ?Handler {
        // First pass: exact matches only
        for (self.routes[0..self.route_count]) |r| {
            if (!r.prefix and strEql(path, r.path)) return r.handler;
        }
        // Second pass: longest prefix match
        var best: ?Handler = null;
        var best_len: usize = 0;
        for (self.routes[0..self.route_count]) |r| {
            if (r.prefix and path.len >= r.path.len and
                strEql(path[0..r.path.len], r.path) and r.path.len > best_len)
            {
                best = r.handler;
                best_len = r.path.len;
            }
        }
        return best;
    }
};

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}
