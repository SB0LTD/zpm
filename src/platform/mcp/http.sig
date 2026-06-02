// HTTP request parsing and response formatting
// Layer 1: Platform

const w32 = @import("win32");

pub fn sendResponse(sock: w32.SOCKET, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr: [512]u8 = undefined;
    var pos: usize = 0;
    pos = appendSlice(&hdr, pos, "HTTP/1.1 ");
    pos = appendSlice(&hdr, pos, status);
    pos = appendSlice(&hdr, pos, "\r\nContent-Type: ");
    pos = appendSlice(&hdr, pos, content_type);
    pos = appendSlice(&hdr, pos, "\r\nContent-Length: ");
    pos = appendUint(&hdr, pos, body.len);
    pos = appendSlice(&hdr, pos, "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");

    _ = w32.send(sock, hdr[0..pos].ptr, @intCast(pos), 0);
    if (body.len > 0) {
        _ = w32.send(sock, body.ptr, @intCast(body.len), 0);
    }
}

/// Send HTTP response header with a known content-length. Body is sent separately via sendBytes.
pub fn sendHeader(sock: w32.SOCKET, content_length: usize) void {
    var hdr: [512]u8 = undefined;
    var pos: usize = 0;
    pos = appendSlice(&hdr, pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ");
    pos = appendUint(&hdr, pos, content_length);
    pos = appendSlice(&hdr, pos, "\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n");
    _ = w32.send(sock, hdr[0..pos].ptr, @intCast(pos), 0);
}

/// Send raw bytes to socket. Used for streaming body after sendHeader.
pub fn sendBytes(sock: w32.SOCKET, data: []const u8) void {
    var sent: usize = 0;
    while (sent < data.len) {
        const chunk = @min(data.len - sent, 65536);
        const n = w32.send(sock, data[sent..].ptr, @intCast(chunk), 0);
        if (n <= 0) break;
        sent += @intCast(n);
    }
}

pub fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

pub fn parseContentLength(headers: []const u8) usize {
    var i: usize = 0;
    while (i + 15 < headers.len) : (i += 1) {
        if (toLower(headers[i]) == 'c' and
            toLower(headers[i + 1]) == 'o' and
            toLower(headers[i + 2]) == 'n' and
            toLower(headers[i + 3]) == 't' and
            toLower(headers[i + 4]) == 'e' and
            toLower(headers[i + 5]) == 'n' and
            toLower(headers[i + 6]) == 't' and
            headers[i + 7] == '-' and
            toLower(headers[i + 8]) == 'l' and
            toLower(headers[i + 9]) == 'e' and
            toLower(headers[i + 10]) == 'n' and
            toLower(headers[i + 11]) == 'g' and
            toLower(headers[i + 12]) == 't' and
            toLower(headers[i + 13]) == 'h' and
            headers[i + 14] == ':')
        {
            var j = i + 15;
            while (j < headers.len and headers[j] == ' ') : (j += 1) {}
            var val: usize = 0;
            while (j < headers.len and headers[j] >= '0' and headers[j] <= '9') : (j += 1) {
                val = val * 10 + (headers[j] - '0');
            }
            return val;
        }
    }
    return 0;
}

pub fn extractPath(req: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < req.len and req[i] != ' ') : (i += 1) {}
    i += 1;
    const start = i;
    while (i < req.len and req[i] != ' ' and req[i] != '?') : (i += 1) {}
    if (i == start) return null;
    return req[start..i];
}

pub fn extractBody(req: []const u8) ?[]const u8 {
    const hdr_end = findHeaderEnd(req) orelse return null;
    if (hdr_end >= req.len) return null;
    return req[hdr_end..];
}

pub fn startsWith(data: []const u8, prefix: []const u8) bool {
    if (data.len < prefix.len) return false;
    return eql(data[0..prefix.len], prefix);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn appendSlice(buf: anytype, pos: usize, s: []const u8) usize {
    const cap = buf.len;
    if (pos + s.len > cap) return pos;
    @memcpy(buf[pos .. pos + s.len], s);
    return pos + s.len;
}

pub fn appendInt(buf: anytype, pos: usize, val: i64) usize {
    if (val < 0) {
        if (pos >= buf.len) return pos;
        buf[pos] = '-';
        return appendUint(buf, pos + 1, @intCast(-val));
    }
    return appendUint(buf, pos, @intCast(val));
}

pub fn appendUint(buf: anytype, pos: usize, val: usize) usize {
    if (val == 0) {
        if (pos >= buf.len) return pos;
        buf[pos] = '0';
        return pos + 1;
    }
    var v = val;
    var tmp: [20]u8 = undefined;
    var tl: usize = 0;
    while (v > 0) : (v /= 10) {
        tmp[tl] = @intCast(v % 10 + '0');
        tl += 1;
    }
    if (pos + tl > buf.len) return pos;
    var p = pos;
    var ri = tl;
    while (ri > 0) : (ri -= 1) {
        buf[p] = tmp[ri - 1];
        p += 1;
    }
    return p;
}
