// MCP server — Streamable HTTP transport over Winsock2 TCP
// Layer 1: Platform (entry point for mcp/ module)
//
// Runs a minimal HTTP server on 127.0.0.1:3001 in a background thread.
// Handles JSON-RPC: initialize, tools/list, tools/call.
// Delegates action delivery to channel.zig, RPC dispatch to rpc.zig.

const w32 = @import("win32");
const FrameState = @import("core").ui.frame_state.FrameState;
const SeqLock = @import("seqlock").SeqLock;
const log = @import("logging");
const http = @import("http.zig");
const rpc = @import("rpc.zig");

pub const channel = @import("channel.zig");

const PORT: u16 = 3001;
const LISTEN_ADDR: u32 = 0x0100007F; // 127.0.0.1 in network byte order
const BUF_SIZE: usize = 8192;

// ── Re-exports for backward compatibility ───────────────────────────

pub const ringPush = channel.ringPush;
pub const poll = channel.poll;
pub const ringRequest = channel.ringRequest;
pub const writeResponse = channel.writeResponse;
pub const nextSeq = channel.nextSeq;
pub const loadFrameState = channel.loadFrameState;

// ── Server state ────────────────────────────────────────────────────

var g_listen: w32.SOCKET = w32.INVALID_SOCKET;
var g_thread: w32.THREAD_HANDLE = null;
var g_running: bool = false;

pub fn init(state: *const SeqLock(FrameState)) void {
    var wsa: w32.WSADATA = .{};
    if (w32.WSAStartup(0x0202, &wsa) != 0) {
        log.err("mcp: WSAStartup failed");
        return;
    }

    channel.setState(state);

    g_listen = w32.socket(w32.AF_INET, w32.SOCK_STREAM, w32.IPPROTO_TCP);
    if (g_listen == w32.INVALID_SOCKET) {
        log.err("mcp: socket() failed");
        return;
    }

    var opt: c_int = 1;
    _ = w32.setsockopt(g_listen, w32.SOL_SOCKET, w32.SO_REUSEADDR, @ptrCast(&opt), @sizeOf(c_int));

    var addr = w32.sockaddr_in{
        .sin_family = @intCast(w32.AF_INET),
        .sin_port = htons(PORT),
        .sin_addr = LISTEN_ADDR,
    };

    if (w32.bind(g_listen, &addr, @sizeOf(w32.sockaddr_in)) == w32.SOCKET_ERROR) {
        log.err("mcp: bind() failed");
        _ = w32.closesocket(g_listen);
        g_listen = w32.INVALID_SOCKET;
        return;
    }

    if (w32.listen(g_listen, 4) == w32.SOCKET_ERROR) {
        log.err("mcp: listen() failed");
        _ = w32.closesocket(g_listen);
        g_listen = w32.INVALID_SOCKET;
        return;
    }

    @atomicStore(bool, &g_running, true, .release);
    g_thread = w32.CreateThread(null, 0, &serverThread, null, 0, null);
    if (g_thread == null) {
        log.err("mcp: CreateThread failed");
        @atomicStore(bool, &g_running, false, .release);
        _ = w32.closesocket(g_listen);
        g_listen = w32.INVALID_SOCKET;
        return;
    }

    log.info("mcp: listening on 127.0.0.1:3001");
}

pub fn deinit() void {
    @atomicStore(bool, &g_running, false, .release);
    if (g_listen != w32.INVALID_SOCKET) {
        _ = w32.closesocket(g_listen);
        g_listen = w32.INVALID_SOCKET;
    }
    if (g_thread) |t| {
        _ = w32.WaitForSingleObject(t, 3000);
        _ = w32.CloseHandle(@ptrCast(t));
        g_thread = null;
    }
    _ = w32.WSACleanup();
}

// ── Background thread ───────────────────────────────────────────────

fn serverThread(_: ?*anyopaque) callconv(.c) w32.DWORD {
    var mode: c_ulong = 1;
    _ = w32.ioctlsocket(g_listen, w32.FIONBIO, &mode);

    while (@atomicLoad(bool, &g_running, .acquire)) {
        var read_fds = w32.fd_set{};
        read_fds.fd_count = 1;
        read_fds.fd_array[0] = g_listen;
        var tv = w32.timeval{ .tv_sec = 0, .tv_usec = 200_000 };

        const sel = w32.select(0, &read_fds, null, null, &tv);
        if (sel <= 0) continue;

        const client = w32.accept(g_listen, null, null);
        if (client == w32.INVALID_SOCKET) continue;

        var block_mode: c_ulong = 0;
        _ = w32.ioctlsocket(client, w32.FIONBIO, &block_mode);

        handleClient(client);
        _ = w32.shutdown(client, w32.SD_BOTH);
        _ = w32.closesocket(client);
    }
    return 0;
}

fn handleClient(sock: w32.SOCKET) void {
    var buf: [BUF_SIZE]u8 = undefined;
    var total: usize = 0;

    while (total < BUF_SIZE) {
        const n = w32.recv(sock, buf[total..].ptr, @intCast(BUF_SIZE - total), 0);
        if (n <= 0) break;
        total += @intCast(n);
        if (http.findHeaderEnd(buf[0..total])) |hdr_end| {
            const content_len = http.parseContentLength(buf[0..hdr_end]);
            if (total >= hdr_end + content_len) break;
        }
    }
    if (total == 0) return;

    const req = buf[0..total];

    if (!http.startsWith(req, "POST ")) {
        if (http.startsWith(req, "GET ")) {
            http.sendResponse(sock, "405 Method Not Allowed", "application/json", "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"GET not supported, use POST\"}}");
            return;
        }
        if (http.startsWith(req, "DELETE ")) {
            http.sendResponse(sock, "200 OK", "application/json", "");
            return;
        }
        http.sendResponse(sock, "405 Method Not Allowed", "application/json", "");
        return;
    }

    const path = http.extractPath(req) orelse {
        http.sendResponse(sock, "400 Bad Request", "application/json", "");
        return;
    };

    if (!http.eql(path, "/mcp")) {
        http.sendResponse(sock, "404 Not Found", "application/json", "");
        return;
    }

    const body = http.extractBody(req) orelse {
        http.sendResponse(sock, "400 Bad Request", "application/json", "");
        return;
    };

    rpc.dispatch(sock, body);
}

fn htons(v: u16) u16 {
    return (v >> 8) | (v << 8);
}
