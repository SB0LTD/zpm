// MCP screenshot streaming — base64-encode PNG from memory buffer
// Layer 1: Platform (internal to mcp/ module)
//
// Handles the screenshot tool: requests capture from main thread via channel,
// reads the resulting PNG from the static memory buffer, and streams it as
// a base64-encoded MCP image response directly to the socket.
// No file I/O — everything stays in memory.

const w32 = @import("win32");
const http = @import("http.zig");
const ring = @import("channel.zig");
const base64 = @import("base64.zig");
const png = @import("png");

// Static buffer for base64 encoding (one screenshot at a time)
const CHUNK_SIZE = 3072; // must be multiple of 3 for clean base64
const B64_CHUNK = (CHUNK_SIZE / 3) * 4; // 4096
var s_b64_buf: [B64_CHUNK]u8 = undefined;

/// Stream a screenshot as base64-encoded PNG image in the MCP response.
pub fn stream(sock: w32.SOCKET, id: i64) void {
    // Request screenshot from main thread and wait for completion
    _ = ring.ringRequest(.{ .screenshot_req = ring.nextSeq() });

    // Read the PNG data length (set atomically by the main thread after capture)
    const png_len = @atomicLoad(u32, &png.s_png_len, .acquire);
    if (png_len == 0) {
        sendError(sock, id, "error: screenshot capture failed");
        return;
    }
    const fsize: usize = png_len;

    // Compute total content-length: JSON prefix + base64 data + JSON suffix
    const b64_len = base64.encodedLen(fsize);

    var prefix: [256]u8 = undefined;
    var pp: usize = 0;
    pp = http.appendSlice(&prefix, pp, "{\"jsonrpc\":\"2.0\",\"id\":");
    pp = http.appendInt(&prefix, pp, id);
    pp = http.appendSlice(&prefix, pp,
        \\,"result":{"content":[{"type":"image","data":"
    );

    const suffix = "\",\"mimeType\":\"image/png\"}],\"isError\":false}}";
    const total_body = pp + b64_len + suffix.len;

    // Send HTTP header with exact content-length
    http.sendHeader(sock, total_body);

    // Send JSON prefix
    http.sendBytes(sock, prefix[0..pp]);

    // Stream buffer → base64 → socket in chunks
    var offset: usize = 0;
    while (offset < fsize) {
        const remaining = fsize - offset;
        const n = @min(remaining, CHUNK_SIZE);
        const b64_n = base64.encode(png.s_png_buf[offset .. offset + n], &s_b64_buf);
        http.sendBytes(sock, s_b64_buf[0..b64_n]);
        offset += n;
    }

    // Send JSON suffix
    http.sendBytes(sock, suffix);
}

fn sendError(sock: w32.SOCKET, id: i64, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos = http.appendSlice(&buf, pos, "{\"jsonrpc\":\"2.0\",\"id\":");
    pos = http.appendInt(&buf, pos, id);
    pos = http.appendSlice(&buf, pos, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    pos = http.appendSlice(&buf, pos, msg);
    pos = http.appendSlice(&buf, pos, "\"}],\"isError\":true}}");
    http.sendResponse(sock, "200 OK", "application/json", buf[0..pos]);
}
