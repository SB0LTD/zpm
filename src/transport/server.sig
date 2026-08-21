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
            .total_requests = 0,
            .total_connections = 0,
            .active_connections = 0,
        };
        _ = s.socket.bind(port);
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

        // 2. Advance all active connections (timers, retransmits, idle)
        for (0..max_connections) |i| {
            if (self.conn_active[i]) {
                self.tickConnection(@intCast(i));
            }
        }
    }

    /// Graceful shutdown — send GOAWAY to all connections.
    pub fn shutdown(self: *Server) void {
        self.running = false;
        // TODO: send GOAWAY on each connection's control stream
    }

    // ══════════════════════════════════════════════════════════════════════
    // Internal
    // ══════════════════════════════════════════════════════════════════════

    fn handlePacket(self: *Server, data: []const u8, src: udp.w32.sockaddr_in) void {
        _ = src;
        // Parse QUIC header to route by DCID
        const header = packet.parseHeader(data) orelse return;

        // Find existing connection by DCID
        const conn_idx = self.findConnection(header.dst_cid) orelse {
            // New connection — allocate from pool
            const idx = self.allocConnection() orelse return;
            self.conn_active[idx] = true;
            self.active_connections += 1;
            self.total_connections += 1;
            // Initialize as server connection
            self.connections[idx] = conn.Connection.initServer(
                &self.stream_arrays[idx],
                0,
            );
            // Process the initial packet on the new connection
            self.processPacket(idx, data);
            return;
        };

        self.processPacket(conn_idx, data);
    }

    fn processPacket(self: *Server, idx: u16, data: []const u8) void {
        _ = self;
        _ = idx;
        _ = data;
        // TODO: feed packet into connection state machine
        // connection.receivePacket(data) → advances handshake or delivers stream data
        // then check for new stream data → parse H3 frames → dispatch
    }

    fn tickConnection(self: *Server, idx: u16) void {
        _ = self;
        _ = idx;
        // TODO: advance connection timers, send pending ACKs/data
    }

    fn findConnection(self: *Server, dcid: packet.ConnectionId) ?u16 {
        for (0..max_connections) |i| {
            if (self.conn_active[i]) {
                const c = &self.connections[i];
                if (cidEql(c.local_cid, dcid)) return @intCast(i);
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
    fn matchRoute(self: *Server, path: []const u8) ?Handler {
        for (self.routes[0..self.route_count]) |r| {
            if (r.prefix) {
                if (path.len >= r.path.len and strEql(path[0..r.path.len], r.path)) {
                    return r.handler;
                }
            } else {
                if (strEql(path, r.path)) return r.handler;
            }
        }
        return null;
    }
};

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}
