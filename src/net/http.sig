//! Minimal HTTP/1.1 Client (RFC 7230/7231)
//!
//! GET and PUT request construction, response parsing.
//! Supports chunked transfer-encoding and custom headers.
//! Connection: close semantics (no keep-alive).
//!
//! Designed for the GCP metadata server (169.254.169.254:80):
//!   - Short-lived TCP connections
//!   - Small request/response bodies
//!   - Custom header: Metadata-Flavor: Google
//!
//! Zero allocation — static buffers, operates over the TCP module.

const tcp = @import("net_tcp");

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

pub const MAX_HEADER_SIZE: usize = 512;
pub const MAX_BODY_SIZE: usize = 4096;
pub const MAX_URL_SIZE: usize = 256;

const CRLF = "\r\n";

// ══════════════════════════════════════════════════════════════════════════════
// HTTP Response
// ══════════════════════════════════════════════════════════════════════════════

pub const Response = struct {
    status_code: u16,
    body: []const u8,
    body_len: usize,
    content_length: u32,
    chunked: bool,
    complete: bool, // True when full response has been received
};

// ══════════════════════════════════════════════════════════════════════════════
// Request Builder
// ══════════════════════════════════════════════════════════════════════════════

/// Build an HTTP GET request into `buf`.
/// Returns the request length, or null if buffer too small.
///
/// Example output:
///   GET /computeMetadata/v1/instance/hostname HTTP/1.1\r\n
///   Host: 169.254.169.254\r\n
///   Metadata-Flavor: Google\r\n
///   Connection: close\r\n
///   \r\n
pub fn buildGet(
    buf: []u8,
    path: []const u8,
    host: []const u8,
    extra_headers: []const u8,
) ?usize {
    var offset: usize = 0;

    // Request line
    offset = appendStr(buf, offset, "GET ") orelse return null;
    offset = appendStr(buf, offset, path) orelse return null;
    offset = appendStr(buf, offset, " HTTP/1.1\r\n") orelse return null;

    // Host header
    offset = appendStr(buf, offset, "Host: ") orelse return null;
    offset = appendStr(buf, offset, host) orelse return null;
    offset = appendStr(buf, offset, "\r\n") orelse return null;

    // Extra headers (e.g., "Metadata-Flavor: Google\r\n")
    if (extra_headers.len > 0) {
        offset = appendStr(buf, offset, extra_headers) orelse return null;
    }

    // Connection: close
    offset = appendStr(buf, offset, "Connection: close\r\n") orelse return null;

    // End of headers
    offset = appendStr(buf, offset, "\r\n") orelse return null;

    return offset;
}

/// Build an HTTP PUT request with a body into `buf`.
/// Returns the request length, or null if buffer too small.
pub fn buildPut(
    buf: []u8,
    path: []const u8,
    host: []const u8,
    extra_headers: []const u8,
    body: []const u8,
) ?usize {
    var offset: usize = 0;

    // Request line
    offset = appendStr(buf, offset, "PUT ") orelse return null;
    offset = appendStr(buf, offset, path) orelse return null;
    offset = appendStr(buf, offset, " HTTP/1.1\r\n") orelse return null;

    // Host header
    offset = appendStr(buf, offset, "Host: ") orelse return null;
    offset = appendStr(buf, offset, host) orelse return null;
    offset = appendStr(buf, offset, "\r\n") orelse return null;

    // Content-Length
    offset = appendStr(buf, offset, "Content-Length: ") orelse return null;
    offset = appendUint(buf, offset, @intCast(body.len)) orelse return null;
    offset = appendStr(buf, offset, "\r\n") orelse return null;

    // Content-Type
    offset = appendStr(buf, offset, "Content-Type: text/plain\r\n") orelse return null;

    // Extra headers
    if (extra_headers.len > 0) {
        offset = appendStr(buf, offset, extra_headers) orelse return null;
    }

    // Connection: close
    offset = appendStr(buf, offset, "Connection: close\r\n") orelse return null;

    // End of headers
    offset = appendStr(buf, offset, "\r\n") orelse return null;

    // Body
    if (body.len > 0) {
        if (offset + body.len > buf.len) return null;
        @memcpy(buf[offset..][0..body.len], body);
        offset += body.len;
    }

    return offset;
}

// ══════════════════════════════════════════════════════════════════════════════
// Response Parser
// ══════════════════════════════════════════════════════════════════════════════

/// Parse state for incremental response parsing.
pub const Parser = struct {
    state: ParseState,
    status_code: u16,
    content_length: u32,
    chunked: bool,
    headers_end: usize, // Offset where body starts in the buffer
    body_received: usize,

    pub fn init() Parser {
        return .{
            .state = .reading_status,
            .status_code = 0,
            .content_length = 0,
            .chunked = false,
            .headers_end = 0,
            .body_received = 0,
        };
    }

    /// Feed received data to the parser. Call repeatedly as TCP data arrives.
    /// `data` is the full receive buffer accumulated so far.
    /// Returns a Response when complete, or null if more data needed.
    pub fn feed(self: *Parser, data: []const u8) ?Response {
        switch (self.state) {
            .reading_status => {
                // Look for end of status line
                const status_end = findCrlf(data, 0) orelse return null;
                self.status_code = parseStatusCode(data[0..status_end]);
                self.state = .reading_headers;
                return self.feed(data); // Continue parsing
            },
            .reading_headers => {
                // Look for end of headers (double CRLF)
                const headers_end = findDoubleCrlf(data) orelse return null;
                self.headers_end = headers_end;

                // Parse headers for Content-Length and Transfer-Encoding
                self.parseHeaders(data[0..headers_end]);
                self.state = .reading_body;
                return self.feed(data); // Continue parsing
            },
            .reading_body => {
                const body_start = self.headers_end;
                if (body_start > data.len) return null;

                const body_data = data[body_start..];

                if (self.chunked) {
                    // For chunked encoding, look for "0\r\n\r\n" terminator
                    if (findChunkedEnd(body_data)) |end| {
                        const decoded = decodeChunked(body_data[0..end]);
                        self.state = .complete;
                        return .{
                            .status_code = self.status_code,
                            .body = decoded.data,
                            .body_len = decoded.len,
                            .content_length = @intCast(decoded.len),
                            .chunked = true,
                            .complete = true,
                        };
                    }
                    return null; // Need more data
                } else {
                    // Content-Length based
                    if (body_data.len >= self.content_length) {
                        self.state = .complete;
                        return .{
                            .status_code = self.status_code,
                            .body = body_data[0..self.content_length],
                            .body_len = self.content_length,
                            .content_length = self.content_length,
                            .chunked = false,
                            .complete = true,
                        };
                    }
                    // If content_length is 0 and connection closed, treat as complete
                    if (self.content_length == 0 and body_data.len == 0) {
                        self.state = .complete;
                        return .{
                            .status_code = self.status_code,
                            .body = &.{},
                            .body_len = 0,
                            .content_length = 0,
                            .chunked = false,
                            .complete = true,
                        };
                    }
                    return null; // Need more data
                }
            },
            .complete => {
                return null;
            },
        }
    }

    fn parseHeaders(self: *Parser, headers: []const u8) void {
        var pos: usize = 0;
        // Skip status line
        pos = (findCrlf(headers, 0) orelse return) + 2;

        while (pos < headers.len) {
            const line_end = findCrlf(headers, pos) orelse break;
            const line = headers[pos..line_end];

            if (startsWithIgnoreCase(line, "content-length:")) {
                self.content_length = parseUint(trimLeft(line["content-length:".len..]));
            } else if (startsWithIgnoreCase(line, "transfer-encoding:")) {
                const val = trimLeft(line["transfer-encoding:".len..]);
                if (startsWithIgnoreCase(val, "chunked")) {
                    self.chunked = true;
                }
            }

            pos = line_end + 2;
        }
    }
};

const ParseState = enum(u8) {
    reading_status,
    reading_headers,
    reading_body,
    complete,
};

// ══════════════════════════════════════════════════════════════════════════════
// High-Level API (blocking, for use in kernel tick loop)
// ══════════════════════════════════════════════════════════════════════════════

/// Perform a blocking HTTP GET via TCP. Sends the request over the given
/// TCP connection handle and polls until the response is received.
///
/// Parameters:
///   handle      — TCP connection handle (from tcp.connect())
///   path        — URL path (e.g., "/computeMetadata/v1/instance/hostname")
///   host        — Host header value (e.g., "169.254.169.254")
///   extra_hdrs  — Additional headers (e.g., "Metadata-Flavor: Google\r\n")
///   response_buf — Buffer to accumulate response data
///
/// Returns status code on success, 0 on timeout/error.
pub fn doGet(
    handle: u8,
    path: []const u8,
    host: []const u8,
    extra_hdrs: []const u8,
    response_buf: []u8,
) u16 {
    var req_buf: [MAX_HEADER_SIZE]u8 = undefined;
    const req_len = buildGet(&req_buf, path, host, extra_hdrs) orelse return 0;

    // Send request
    const sent = tcp.send(handle, req_buf[0..req_len]);
    if (sent == 0) return 0;

    // Read response into buffer
    var recv_total: usize = 0;
    var parser = Parser.init();
    var polls: u32 = 0;
    const MAX_POLLS: u32 = 5_000_000; // ~5s timeout

    while (polls < MAX_POLLS) : (polls += 1) {
        const n = tcp.recv(handle, response_buf[recv_total..]);
        recv_total += n;

        if (recv_total > 0) {
            if (parser.feed(response_buf[0..recv_total])) |resp| {
                return resp.status_code;
            }
        }

        // Check if connection was closed by peer (indicates end of response)
        if (tcp.getState(handle) == .close_wait and recv_total > 0) {
            // Try to parse what we have
            if (parser.feed(response_buf[0..recv_total])) |resp| {
                return resp.status_code;
            }
            // Force-parse with what we have
            if (parser.status_code != 0) return parser.status_code;
            break;
        }
    }

    return 0; // Timeout
}

// ══════════════════════════════════════════════════════════════════════════════
// GCP Metadata Server Helpers
// ══════════════════════════════════════════════════════════════════════════════

/// The standard extra header for GCP metadata requests.
pub const GCP_METADATA_HEADERS = "Metadata-Flavor: Google\r\n";

/// The GCP metadata server IP (link-local, always reachable on NIC's L2 segment).
pub const GCP_METADATA_IP: [4]u8 = .{ 169, 254, 169, 254 };

/// The GCP metadata server port.
pub const GCP_METADATA_PORT: u16 = 80;

/// GCP metadata host header value.
pub const GCP_METADATA_HOST = "metadata.google.internal";

// ══════════════════════════════════════════════════════════════════════════════
// Internal Helpers
// ══════════════════════════════════════════════════════════════════════════════

fn appendStr(buf: []u8, offset: usize, s: []const u8) ?usize {
    if (offset + s.len > buf.len) return null;
    @memcpy(buf[offset..][0..s.len], s);
    return offset + s.len;
}

fn appendUint(buf: []u8, offset: usize, val: u32) ?usize {
    // Convert u32 to decimal string
    var num_buf: [10]u8 = undefined;
    var n = val;
    var len: usize = 0;

    if (n == 0) {
        if (offset + 1 > buf.len) return null;
        buf[offset] = '0';
        return offset + 1;
    }

    while (n > 0) : (len += 1) {
        num_buf[len] = @intCast('0' + (n % 10));
        n /= 10;
    }

    if (offset + len > buf.len) return null;

    // Reverse into output
    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[offset + i] = num_buf[len - 1 - i];
    }
    return offset + len;
}

fn findCrlf(data: []const u8, start: usize) ?usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n') return i;
    }
    return null;
}

fn findDoubleCrlf(data: []const u8) ?usize {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and
            data[i + 2] == '\r' and data[i + 3] == '\n')
        {
            return i + 4; // Offset past the double CRLF
        }
    }
    return null;
}

fn parseStatusCode(status_line: []const u8) u16 {
    // "HTTP/1.1 200 OK" — status code at offset 9..12
    if (status_line.len < 12) return 0;
    const d0: u16 = if (status_line[9] >= '0' and status_line[9] <= '9')
        status_line[9] - '0'
    else
        return 0;
    const d1: u16 = if (status_line[10] >= '0' and status_line[10] <= '9')
        status_line[10] - '0'
    else
        return 0;
    const d2: u16 = if (status_line[11] >= '0' and status_line[11] <= '9')
        status_line[11] - '0'
    else
        return 0;
    return d0 * 100 + d1 * 10 + d2;
}

fn parseUint(s: []const u8) u32 {
    var val: u32 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 10 + (c - '0');
        } else break;
    }
    return val;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (toLower(h) != toLower(n)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

const ChunkedResult = struct {
    data: []const u8,
    len: usize,
};

fn findChunkedEnd(data: []const u8) ?usize {
    // Look for "0\r\n\r\n" which terminates chunked encoding
    var i: usize = 0;
    while (i + 4 < data.len) : (i += 1) {
        if (data[i] == '0' and data[i + 1] == '\r' and data[i + 2] == '\n' and
            data[i + 3] == '\r' and data[i + 4] == '\n')
        {
            return i + 5;
        }
    }
    return null;
}

// Static decode buffer for chunked responses
var chunked_decode_buf: [MAX_BODY_SIZE]u8 = @splat(0);
var chunked_decode_len: usize = 0;

fn decodeChunked(data: []const u8) ChunkedResult {
    chunked_decode_len = 0;
    var pos: usize = 0;

    while (pos < data.len) {
        // Parse chunk size (hex)
        const size_end = findCrlf(data, pos) orelse break;
        const chunk_size = parseHex(data[pos..size_end]);
        if (chunk_size == 0) break; // Final chunk

        pos = size_end + 2; // Skip CRLF after size
        if (pos + chunk_size > data.len) break;

        // Copy chunk data
        const to_copy = if (chunked_decode_len + chunk_size > MAX_BODY_SIZE)
            MAX_BODY_SIZE - chunked_decode_len
        else
            chunk_size;

        @memcpy(chunked_decode_buf[chunked_decode_len..][0..to_copy], data[pos..][0..to_copy]);
        chunked_decode_len += to_copy;
        pos += chunk_size + 2; // Skip chunk data + trailing CRLF
    }

    return .{
        .data = chunked_decode_buf[0..chunked_decode_len],
        .len = chunked_decode_len,
    };
}

fn parseHex(s: []const u8) usize {
    var val: usize = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val * 16 + (c - '0');
        } else if (c >= 'a' and c <= 'f') {
            val = val * 16 + (c - 'a' + 10);
        } else if (c >= 'A' and c <= 'F') {
            val = val * 16 + (c - 'A' + 10);
        } else break;
    }
    return val;
}
