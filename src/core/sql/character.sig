//! VARCHAR(n) / CHAR(n) length semantics (Layer 0), after PostgreSQL's
//! varchar.c: typmods store n + VARHDRSZ (4), lengths count characters of
//! the UTF-8 server encoding, never bytes, and truncation keeps whole
//! characters (pg_mbcharcliplen).
//!
//! Input functions and assignment (implicit) coercion accept a longer value
//! only when every excess character is a space, which is clipped off; any
//! other excess is 22001 string_data_right_truncation. Explicit casts
//! truncate silently. CHAR(n) pads with spaces to n characters; its
//! comparisons, hashing and casts to the other string types ignore trailing
//! spaces (bcTruelen).
//!
//! Capacity: a stored value is at most Config.text_bytes bytes after
//! padding. CHAR(n) with n beyond that capacity is still declarable (as in
//! PostgreSQL, up to 10485760) but every non-NULL value then raises
//! TextCapacity (54000).
const types = @import("types.sig");
const lexer = @import("lexer.sig");
const Error = types.Error;

/// PostgreSQL MaxAttrSize: the largest declarable length.
pub const max_length: u64 = 10485760;
/// VARHDRSZ: character typmods are n + 4.
pub const header: i32 = 4;

/// Typmod of a declared length (`length for type ... must be at least 1` /
/// `cannot exceed 10485760` are 22023).
pub fn typmodOf(length: u64) Error!i32 {
    if (length < 1 or length > max_length) return error.InvalidParameterValue;
    return @intCast(length + header);
}

/// Whether `typmod` is -1 or a valid character typmod (change records).
pub fn validTypmod(typmod: i32) bool {
    return typmod == -1 or (typmod >= header + 1 and typmod <= @as(i32, @intCast(max_length)) + header);
}

/// The declared length in characters, or null without a typmod.
pub fn declared(typmod: i32) ?usize {
    if (typmod <= header) return null;
    return @intCast(typmod - header);
}

fn leading(byte: u8) bool {
    return byte & 0xc0 != 0x80;
}

/// Number of characters (UTF-8 sequences) in `bytes`.
pub fn characters(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (leading(byte)) count += 1;
    }
    return count;
}

/// Byte length of the first `count` characters of `bytes`.
pub fn clip(bytes: []const u8, count: usize) usize {
    var seen: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (leading(byte)) {
            if (seen == count) return index;
            seen += 1;
        }
    }
    return bytes.len;
}

/// `bytes` without trailing ASCII spaces (bcTruelen).
pub fn trimmed(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end != 0 and bytes[end - 1] == ' ') end -= 1;
    return bytes[0..end];
}

/// Assignment/input (implicit) or explicit length coercion.
pub const Mode = enum { implicit, explicit };

/// Shape of a coerced value: keep `keep` bytes of the input, then append
/// `pad` spaces (CHAR only).
pub const Shape = struct { keep: usize, pad: usize = 0 };

fn clipped(bytes: []const u8, length: usize, mode: Mode) Error!usize {
    const keep = clip(bytes, length);
    if (mode == .implicit) {
        for (bytes[keep..]) |byte| if (byte != ' ') return error.StringDataRightTruncation;
    }
    return keep;
}

/// PostgreSQL character input uses UTF-8 and rejects embedded NUL.
pub fn validateText(bytes: []const u8) Error!void {
    var check: lexer.Utf8Check = .{};
    for (bytes) |byte| check.feed(byte);
    if (!check.finish()) return error.CharacterNotInRepertoire;
}

/// An internal-char cast can form one raw byte followed by bpchar padding.
/// Its stored representation is valid even if the byte is NUL or non-UTF-8.
pub fn validateBpchar(bytes: []const u8) Error!void {
    if (!rawInternalChar(bytes)) try validateText(bytes);
}

/// varchar(): the bytes a VARCHAR(n) value keeps.
pub fn varchar(bytes: []const u8, typmod: i32, mode: Mode) Error!Shape {
    try validateText(bytes);
    const length = declared(typmod) orelse return .{ .keep = bytes.len };
    if (bytes.len <= length) return .{ .keep = bytes.len };
    return .{ .keep = try clipped(bytes, length, mode) };
}

/// bpchar(): the bytes a CHAR(n) value keeps and the spaces it gains.
pub fn bpchar(bytes: []const u8, typmod: i32, mode: Mode) Error!Shape {
    try validateBpchar(bytes);
    const length = declared(typmod) orelse return .{ .keep = bytes.len };
    // bpchar(internal char) carries one raw byte, even when it is not a
    // complete UTF-8 sequence. A zero ends its character count but remains
    // in the binary value before its padding.
    if (rawInternalChar(bytes)) {
        const prefix: usize = if (bytes[0] == 0) 1 else 0;
        const count = bytes.len - prefix;
        return if (count > length) .{ .keep = length + prefix } else .{ .keep = bytes.len, .pad = length - count };
    }
    const count = characters(bytes);
    if (count > length) return .{ .keep = try clipped(bytes, length, mode) };
    return .{ .keep = bytes.len, .pad = length - count };
}

fn rawInternalChar(bytes: []const u8) bool {
    if (bytes.len == 0 or (bytes[0] != 0 and bytes[0] < 128)) return false;
    for (bytes[1..]) |byte| if (byte != ' ') return false;
    return true;
}

pub fn fitsBpchar(bytes: []const u8, typmod: i32) bool {
    const length = declared(typmod) orelse return true;
    if (rawInternalChar(bytes)) return bytes.len - @as(usize, @intFromBool(bytes[0] == 0)) <= length;
    return fits(bytes, typmod);
}

/// Stored-value check: a value never exceeds its declared length.
pub fn fits(bytes: []const u8, typmod: i32) bool {
    const length = declared(typmod) orelse return true;
    return bytes.len <= length or characters(bytes) <= length;
}
