//! Strict bounded JSON validation and borrowed field/array views for RPC envelopes.
const std = @import("std");
pub const Error = error{ InvalidJson, MissingField, WrongType, DuplicateField, Capacity };
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn ws(self: *Cursor) void {
        while (self.pos < self.bytes.len and std.mem.indexOfScalar(u8, " \t\r\n", self.bytes[self.pos]) != null) self.pos += 1;
    }
    fn take(self: *Cursor, byte: u8) Error!void {
        self.ws();
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != byte) return error.InvalidJson;
        self.pos += 1;
    }
    fn string(self: *Cursor) Error![]const u8 {
        try self.take('"');
        const start = self.pos;
        while (self.pos < self.bytes.len) {
            const byte = self.bytes[self.pos];
            self.pos += 1;
            if (byte == '"') return self.bytes[start .. self.pos - 1];
            if (byte < 32) return error.InvalidJson;
            if (byte == '\\') {
                if (self.pos == self.bytes.len) return error.InvalidJson;
                const escape = self.bytes[self.pos];
                self.pos += 1;
                if (escape == 'u') {
                    if (self.bytes.len - self.pos < 4) return error.InvalidJson;
                    for (self.bytes[self.pos..][0..4]) |digit| _ = std.fmt.charToDigit(digit, 16) catch return error.InvalidJson;
                    self.pos += 4;
                } else if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", escape) == null) return error.InvalidJson;
            }
        }
        return error.InvalidJson;
    }
    fn value(self: *Cursor, depth: usize) Error![]const u8 {
        if (depth > 24) return error.Capacity;
        self.ws();
        const start = self.pos;
        if (start == self.bytes.len) return error.InvalidJson;
        const byte = self.bytes[start];
        if (byte == '"') {
            _ = try self.string();
        } else if (byte == '{' or byte == '[') {
            self.pos += 1;
            const end: u8 = if (byte == '{') '}' else ']';
            self.ws();
            if (self.pos < self.bytes.len and self.bytes[self.pos] == end) self.pos += 1 else while (true) {
                if (byte == '{') {
                    _ = try self.string();
                    try self.take(':');
                }
                _ = try self.value(depth + 1);
                self.ws();
                if (self.pos >= self.bytes.len) return error.InvalidJson;
                if (self.bytes[self.pos] == end) {
                    self.pos += 1;
                    break;
                }
                try self.take(',');
            }
        } else if (byte == 't' or byte == 'f' or byte == 'n') {
            const literal: []const u8 = switch (byte) {
                't' => "true",
                'f' => "false",
                else => "null",
            };
            if (self.bytes.len - self.pos < literal.len or !std.mem.eql(u8, self.bytes[self.pos..][0..literal.len], literal)) return error.InvalidJson;
            self.pos += literal.len;
        } else {
            if (byte == '-') self.pos += 1;
            if (self.pos >= self.bytes.len or !std.ascii.isDigit(self.bytes[self.pos])) return error.InvalidJson;
            if (self.bytes[self.pos] == '0') self.pos += 1 else while (self.pos < self.bytes.len and std.ascii.isDigit(self.bytes[self.pos])) self.pos += 1;
            if (self.pos < self.bytes.len and self.bytes[self.pos] == '.') {
                self.pos += 1;
                const digit = self.pos;
                while (self.pos < self.bytes.len and std.ascii.isDigit(self.bytes[self.pos])) self.pos += 1;
                if (self.pos == digit) return error.InvalidJson;
            }
            if (self.pos < self.bytes.len and (self.bytes[self.pos] == 'e' or self.bytes[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.bytes.len and (self.bytes[self.pos] == '+' or self.bytes[self.pos] == '-')) self.pos += 1;
                const digit = self.pos;
                while (self.pos < self.bytes.len and std.ascii.isDigit(self.bytes[self.pos])) self.pos += 1;
                if (self.pos == digit) return error.InvalidJson;
            }
        }
        return self.bytes[start..self.pos];
    }
};
pub fn validate(bytes: []const u8) Error!void {
    // RPC keys, base58/base64 and status fields are ASCII; fail closed otherwise.
    for (bytes) |byte| if (byte >= 128) return error.InvalidJson;
    var cursor = Cursor{ .bytes = bytes };
    _ = try cursor.value(0);
    cursor.ws();
    if (cursor.pos != bytes.len) return error.InvalidJson;
}
pub fn field(bytes: []const u8, key: []const u8) Error![]const u8 {
    try validate(bytes);
    var cursor = Cursor{ .bytes = bytes };
    try cursor.take('{');
    cursor.ws();
    var found: ?[]const u8 = null;
    while (cursor.pos < bytes.len and bytes[cursor.pos] != '}') {
        const name = try cursor.string();
        try cursor.take(':');
        const value = try cursor.value(1);
        if (std.mem.eql(u8, name, key)) {
            if (found != null) return error.DuplicateField;
            found = value;
        }
        cursor.ws();
        if (bytes[cursor.pos] == '}') break;
        try cursor.take(',');
    }
    return found orelse error.MissingField;
}
pub fn item(bytes: []const u8, index: usize) Error![]const u8 {
    try validate(bytes);
    var cursor = Cursor{ .bytes = bytes };
    try cursor.take('[');
    cursor.ws();
    var current: usize = 0;
    while (cursor.pos < bytes.len and bytes[cursor.pos] != ']') {
        const value = try cursor.value(1);
        if (current == index) return value;
        current += 1;
        cursor.ws();
        if (bytes[cursor.pos] == ']') break;
        try cursor.take(',');
    }
    return error.MissingField;
}
pub fn string(bytes: []const u8) Error![]const u8 {
    try validate(bytes);
    if (bytes.len < 2 or bytes[0] != '"' or bytes[bytes.len - 1] != '"' or std.mem.indexOfScalar(u8, bytes, '\\') != null) return error.WrongType;
    return bytes[1 .. bytes.len - 1];
}
pub fn number(bytes: []const u8) Error!u64 {
    try validate(bytes);
    return std.fmt.parseInt(u64, bytes, 10) catch error.WrongType;
}
