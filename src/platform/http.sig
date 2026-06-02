// Reusable HTTP helpers — session, GET request, body read
// Layer 1: Platform
//
// Wraps WinHTTP boilerplate into simple functions. Every REST caller
// in the codebase does the same open→connect→request→send→receive→read
// dance — this module eliminates that duplication.

const w32 = @import("win32");

/// Open a WinHTTP session with timeouts. Caller must close with WinHttpCloseHandle.
pub fn openSession() ?w32.HINTERNET {
    const session = w32.WinHttpOpen(
        w32.L("SB0Trade/1.0"),
        w32.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        null,
        null,
        0,
    ) orelse return null;
    setTimeouts(session);
    return session;
}

/// Set reasonable timeouts on a WinHTTP session to prevent indefinite hangs.
/// resolve=10s, connect=15s, send=15s, receive=30s.
pub fn setTimeouts(session: w32.HINTERNET) void {
    _ = w32.WinHttpSetTimeouts(session, 10000, 15000, 15000, 30000);
}

/// Connect to a host on a given port. Caller must close with WinHttpCloseHandle.
pub fn connect(session: w32.HINTERNET, host: [*:0]const u16, port: u16) ?w32.HINTERNET {
    return w32.WinHttpConnect(session, host, port, 0);
}

/// Perform an HTTPS GET and read the response body into `buf`.
/// Returns the number of bytes read, or 0 on failure.
/// `conn` is from connect(), `path` is a null-terminated UTF-16 path.
pub fn get(conn: w32.HINTERNET, path: [*:0]const u16, buf: []u8) usize {
    return getWithStatus(conn, path, buf).body_len;
}

pub const HttpResult = struct {
    body_len: usize = 0,
    status: u32 = 0,
};

/// Perform an HTTPS GET, returning both body length and HTTP status code.
/// status=429 means rate limited, status=418 means IP banned (Binance).
pub fn getWithStatus(conn: w32.HINTERNET, path: [*:0]const u16, buf: []u8) HttpResult {
    const request = w32.WinHttpOpenRequest(
        conn,
        w32.L("GET"),
        path,
        null,
        null,
        null,
        w32.WINHTTP_FLAG_SECURE,
    ) orelse return .{};
    defer _ = w32.WinHttpCloseHandle(request);

    if (w32.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return .{};
    if (w32.WinHttpReceiveResponse(request, null) == 0) return .{};

    // Query HTTP status code
    var status_code: u32 = 0;
    var size: u32 = @sizeOf(u32);
    _ = w32.WinHttpQueryHeaders(
        request,
        w32.WINHTTP_QUERY_STATUS_CODE | w32.WINHTTP_QUERY_FLAG_NUMBER,
        null,
        @ptrCast(&status_code),
        &size,
        null,
    );

    const body_len = readBody(request, buf);
    return .{ .body_len = body_len, .status = status_code };
}

/// Read the full response body from an already-received request.
/// Useful when the caller needs to set custom headers or use POST.
pub fn readBody(request: w32.HINTERNET, buf: []u8) usize {
    var total: usize = 0;
    while (true) {
        var avail: u32 = 0;
        if (w32.WinHttpQueryDataAvailable(request, &avail) == 0) break;
        if (avail == 0) break;
        const to_read = @min(avail, @as(u32, @intCast(buf.len - total)));
        if (to_read == 0) break;
        var read: u32 = 0;
        if (w32.WinHttpReadData(request, buf[total..].ptr, to_read, &read) == 0) break;
        total += read;
    }
    return total;
}
