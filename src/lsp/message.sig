//! LSP base-protocol framing and JSON-RPC parsing — Layer 0.
//!
//! LSP frames each JSON-RPC message with an HTTP-like header block:
//!
//!     Content-Length: <N>\r\n
//!     \r\n
//!     <N bytes of JSON>
//!
//! This module parses that framing out of a byte stream and extracts the
//! JSON-RPC essentials (id, method) using the zpm `json` scanner. Emitting the
//! header is a pure byte operation. No allocator, no I/O: callers own the
//! buffers and perform the actual reads/writes.

const std = @import("std");
const json = @import("json");

pub const ParseError = error{
    Incomplete,
    MissingContentLength,
    Malformed,
};

/// A parsed request/notification. `id_present` distinguishes a request (has id,
/// expects a response) from a notification (no id).
pub const Message = struct {
    body: []const u8,
    method: []const u8,
    /// Numeric id if present. String ids are treated as absent (common clients
    /// use integers).
    id: i64 = 0,
    id_present: bool = false,
};

pub const Frame = struct {
    body: []const u8,
    consumed: usize,
};

/// Attempt to extract one complete frame from the front of `input`.
pub fn readFrame(input: []const u8) ParseError!Frame {
    const header_end = findHeaderEnd(input) orelse return error.Incomplete;
    const content_length = parseContentLength(input[0..header_end]) orelse return error.MissingContentLength;
    const body_start = header_end;
    const body_end = body_start + content_length;
    if (body_end > input.len) return error.Incomplete;
    return .{ .body = input[body_start..body_end], .consumed = body_end };
}

/// Parse the JSON-RPC essentials out of a framed body.
pub fn parse(body: []const u8) Message {
    var msg: Message = .{ .body = body, .method = "" };
    if (json.getString(body, "method\"")) |m| {
        msg.method = m;
    }
    if (json.findKey(body, "\"id\"")) |_| {
        if (json.getInt(body, "id\"")) |v| {
            msg.id = v;
            msg.id_present = true;
        }
    }
    return msg;
}

fn findHeaderEnd(input: []const u8) ?usize {
    if (input.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= input.len) : (i += 1) {
        if (input[i] == '\r' and input[i + 1] == '\n' and input[i + 2] == '\r' and input[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    const marker = "content-length:";
    var i: usize = 0;
    while (i + marker.len <= headers.len) : (i += 1) {
        if (asciiEqlIgnoreCase(headers[i .. i + marker.len], marker)) {
            var j = i + marker.len;
            while (j < headers.len and (headers[j] == ' ' or headers[j] == '\t')) : (j += 1) {}
            var value: usize = 0;
            var saw_digit = false;
            while (j < headers.len and headers[j] >= '0' and headers[j] <= '9') : (j += 1) {
                value = value * 10 + (headers[j] - '0');
                saw_digit = true;
            }
            if (saw_digit) return value;
            return null;
        }
    }
    return null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (toLower(x) != toLower(y)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Write the `Content-Length` header + separator into `out`.
pub fn writeHeader(out: []u8, body_len: usize) ![]const u8 {
    return std.fmt.bufPrint(out, "Content-Length: {d}\r\n\r\n", .{body_len});
}

test "readFrame extracts body and reports consumed bytes" {
    const input = "Content-Length: 17\r\n\r\n{\"method\":\"ping\"}TRAILING";
    const frame = try readFrame(input);
    try std.testing.expectEqualStrings("{\"method\":\"ping\"}", frame.body);
    try std.testing.expectEqual(@as(usize, 39), frame.consumed);
}

test "readFrame is incomplete until whole body present" {
    try std.testing.expectError(error.Incomplete, readFrame("Content-Length: 50\r\n\r\n{\"method\":\"x\"}"));
}

test "content-length header is case insensitive" {
    const frame = try readFrame("CONTENT-LENGTH: 2\r\n\r\n{}");
    try std.testing.expectEqualStrings("{}", frame.body);
}

test "parse distinguishes request from notification" {
    const req = parse("{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"initialize\"}");
    try std.testing.expect(req.id_present);
    try std.testing.expectEqual(@as(i64, 42), req.id);
    try std.testing.expectEqualStrings("initialize", req.method);

    const note = parse("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\"}");
    try std.testing.expect(!note.id_present);
    try std.testing.expectEqualStrings("initialized", note.method);
}

test "writeHeader formats content-length" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Content-Length: 123\r\n\r\n", try writeHeader(&buf, 123));
}

test "readFrame on empty input is incomplete" {
    try std.testing.expectError(error.Incomplete, readFrame(""));
    try std.testing.expectError(error.Incomplete, readFrame("Content-Length: 5\r\n"));
}

test "readFrame reports MissingContentLength when header lacks the field" {
    try std.testing.expectError(error.MissingContentLength, readFrame("X-Other: 1\r\n\r\n{}"));
}

test "readFrame tolerates extra headers before content-length" {
    const input = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" ++
        "Content-Length: 2\r\n\r\n{}";
    try std.testing.expectEqualStrings("{}", (try readFrame(input)).body);
}

test "readFrame handles content-length with tabs and trailing spaces" {
    try std.testing.expectEqualStrings("{\"a\":1}", (try readFrame("Content-Length:\t7 \r\n\r\n{\"a\":1}")).body);
}

test "incremental framing: draining multiple messages from one buffer" {
    const a = "Content-Length: 2\r\n\r\n{}";
    const b = "Content-Length: 17\r\n\r\n{\"method\":\"ping\"}";
    const combined = a ++ b;
    var cursor: usize = 0;
    const f1 = try readFrame(combined[cursor..]);
    try std.testing.expectEqualStrings("{}", f1.body);
    cursor += f1.consumed;
    const f2 = try readFrame(combined[cursor..]);
    try std.testing.expectEqualStrings("{\"method\":\"ping\"}", f2.body);
    cursor += f2.consumed;
    try std.testing.expectEqual(combined.len, cursor);
    try std.testing.expectError(error.Incomplete, readFrame(combined[cursor..]));
}

test "parse handles id 0 as a present request id" {
    const msg = parse("{\"id\":0,\"method\":\"shutdown\"}");
    try std.testing.expect(msg.id_present);
    try std.testing.expectEqual(@as(i64, 0), msg.id);
}

test "parse of body without method yields empty method" {
    try std.testing.expectEqualStrings("", parse("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}").method);
}
