//! PostgreSQL COPY data formats over caller-owned buffers (ZPM src/db,
//! design §4.7/§5.17): row framing, field splitting and output escaping for
//! FORMAT text, csv and binary, as PostgreSQL's copyfromparse.c / copyto.c.
//!
//! Text: one line per row ended by `\n` (or `\r\n`, fixed by the first
//! line), fields split on the delimiter, backslash escapes `\b \f \n \r \t
//! \v \\`, `\ooo`, `\xhh` and `\<any>`; a raw field equal to the NULL string
//! (default `\N`) is NULL; a `\.` line ends the data. CSV: fields may be
//! quoted (QUOTE, ESCAPE; quoted fields may span lines), an unquoted field
//! equal to the NULL string (default empty) is NULL. Binary: the 11-byte
//! signature, flags (no OIDs, no unknown critical flags), header extension,
//! then tuples {i16 count, {i32 length | -1, bytes}} and an optional -1
//! trailer. Malformed data is BadCopyFormat (22P04). No allocation: field
//! slices point into the row or the caller's scratch buffer.

pub const Error = error{ BadCopyFormat, TextCapacity };

pub const Format = enum { text, csv, binary };

/// The validated options a codec needs (from the engine's CopyOptions).
pub const Options = struct {
    format: Format = .text,
    delimiter: u8 = '\t',
    null_string: []const u8 = "\\N",
    quote: u8 = '"',
    escape: u8 = '"',
};

pub const signature = "PGCOPY\n\xff\r\n\x00";
/// Signature, flags and header-extension length.
pub const binary_header_bytes = 19;

fn read16(bytes: []const u8) i16 {
    return @bitCast((@as(u16, bytes[0]) << 8) | bytes[1]);
}

fn read32(bytes: []const u8) i32 {
    return @bitCast((@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3]);
}

/// Length of the first complete row in `bytes` (terminator included), or
/// null when more data is needed. Text: a backslash escapes the next byte
/// (so `\<newline>` is data). CSV: newlines inside quotes are data.
pub fn lineEnd(options: *const Options, bytes: []const u8) ?usize {
    var index: usize = 0;
    var quoted = false;
    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (options.format == .text) {
            if (byte == '\\') {
                if (index + 1 >= bytes.len) return null;
                index += 1;
                continue;
            }
            if (byte == '\n') return index + 1;
            continue;
        }
        if (quoted) {
            if (byte == options.escape and options.escape != options.quote and index + 1 < bytes.len and (bytes[index + 1] == options.quote or bytes[index + 1] == options.escape)) {
                index += 1;
                continue;
            }
            if (byte == options.escape and options.escape != options.quote and index + 1 >= bytes.len) return null;
            if (byte == options.quote) quoted = false;
            continue;
        }
        if (byte == options.quote) {
            quoted = true;
            continue;
        }
        if (byte == '\n') return index + 1;
    }
    return null;
}

/// Bytes of the binary header (signature, flags, extension) at the start
/// of `bytes`, or null when incomplete. Validates the signature and flags.
pub fn binaryHeader(bytes: []const u8) Error!?usize {
    if (bytes.len < binary_header_bytes) {
        const prefix = @min(bytes.len, signature.len);
        for (bytes[0..prefix], signature[0..prefix]) |byte, wanted| if (byte != wanted) return error.BadCopyFormat;
        return null;
    }
    for (signature, 0..) |byte, index| if (bytes[index] != byte) return error.BadCopyFormat;
    const flags: u32 = @bitCast(read32(bytes[11..15]));
    // Bit 16 is WITH OIDS; other high bits are unknown critical flags.
    if (flags & (1 << 16) != 0 or (flags >> 16) != 0) return error.BadCopyFormat;
    const extension = read32(bytes[15..19]);
    if (extension < 0) return error.BadCopyFormat;
    const total = binary_header_bytes + @as(usize, @intCast(extension));
    return if (bytes.len < total) null else total;
}

/// Length of the first complete binary tuple (or the 2-byte trailer), or
/// null when incomplete. A field count other than `expected` or a field
/// length below -1 is BadCopyFormat.
pub fn tupleEnd(bytes: []const u8, expected: usize) Error!?usize {
    if (bytes.len < 2) return null;
    const count = read16(bytes[0..2]);
    if (count == -1) return 2;
    if (count < 0 or @as(usize, @intCast(count)) != expected) return error.BadCopyFormat;
    var at: usize = 2;
    for (0..expected) |_| {
        if (bytes.len - at < 4) return null;
        const length = read32(bytes[at..][0..4]);
        at += 4;
        if (length == -1) continue;
        if (length < -1) return error.BadCopyFormat;
        const size: usize = @intCast(length);
        if (bytes.len - at < size) return null;
        at += size;
    }
    return at;
}

/// A binary tuple's fields (null = SQL NULL), slices into `tuple`.
pub fn tupleFields(tuple: []const u8, out: []?[]const u8) usize {
    const count: usize = @intCast(read16(tuple[0..2]));
    var at: usize = 2;
    for (0..count) |index| {
        const length = read32(tuple[at..][0..4]);
        at += 4;
        if (length == -1) {
            out[index] = null;
            continue;
        }
        const size: usize = @intCast(length);
        out[index] = tuple[at..][0..size];
        at += size;
    }
    return count;
}

/// Line terminator style, fixed by the first line as PostgreSQL does.
pub const Eol = enum { unknown, nl, crnl };

/// Strips the terminator of a complete line (or a final line without one).
/// A terminator differing from the first line's is BadCopyFormat.
pub fn stripLine(line: []const u8, eol: *Eol, terminated: bool) Error![]const u8 {
    if (!terminated) return line;
    const crnl = line.len >= 2 and line[line.len - 2] == '\r';
    switch (eol.*) {
        .unknown => eol.* = if (crnl) .crnl else .nl,
        .nl => if (crnl) return error.BadCopyFormat,
        .crnl => if (!crnl) return error.BadCopyFormat,
    }
    return line[0 .. line.len - @as(usize, if (crnl) 2 else 1)];
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// Splits a text-format line (terminator stripped) into fields decoded into
/// `scratch`. Returns the field count; more than `out.len` fields is
/// BadCopyFormat ("extra data after last expected column").
pub fn textFields(options: *const Options, line: []const u8, scratch: []u8, out: []?[]const u8) Error!usize {
    var count: usize = 0;
    var index: usize = 0;
    var used: usize = 0;
    while (true) {
        if (count == out.len) return error.BadCopyFormat;
        const raw_start = index;
        const start = used;
        while (index < line.len and line[index] != options.delimiter) {
            var byte = line[index];
            index += 1;
            if (byte == '\\' and index < line.len) {
                const next = line[index];
                index += 1;
                switch (next) {
                    '0'...'7' => {
                        var value: u32 = next - '0';
                        var digits: usize = 1;
                        while (digits < 3 and index < line.len and line[index] >= '0' and line[index] <= '7') : (digits += 1) {
                            value = value * 8 + (line[index] - '0');
                            index += 1;
                        }
                        byte = @truncate(value);
                    },
                    'x' => {
                        if (index < line.len and hexValue(line[index]) != null) {
                            var value: u8 = hexValue(line[index]).?;
                            index += 1;
                            if (index < line.len) if (hexValue(line[index])) |low| {
                                value = value * 16 + low;
                                index += 1;
                            };
                            byte = value;
                        } else byte = 'x';
                    },
                    'b' => byte = 8,
                    'f' => byte = 12,
                    'n' => byte = '\n',
                    'r' => byte = '\r',
                    't' => byte = '\t',
                    'v' => byte = 11,
                    else => byte = next,
                }
            }
            if (used == scratch.len) return error.TextCapacity;
            scratch[used] = byte;
            used += 1;
        }
        const raw = line[raw_start..index];
        out[count] = if (equal(raw, options.null_string)) null else scratch[start..used];
        count += 1;
        if (index == line.len) break;
        index += 1;
    }
    return count;
}

/// Splits a CSV record (terminator stripped; may contain quoted newlines).
/// An unterminated quoted field is BadCopyFormat.
pub fn csvFields(options: *const Options, line: []const u8, scratch: []u8, out: []?[]const u8) Error!usize {
    var count: usize = 0;
    var index: usize = 0;
    var used: usize = 0;
    while (true) {
        if (count == out.len) return error.BadCopyFormat;
        const raw_start = index;
        const start = used;
        var saw_quote = false;
        field: while (true) {
            while (index < line.len) {
                const byte = line[index];
                if (byte == options.delimiter) break :field;
                index += 1;
                if (byte == options.quote) break;
                if (used == scratch.len) return error.TextCapacity;
                scratch[used] = byte;
                used += 1;
            } else break :field;
            saw_quote = true;
            while (true) {
                if (index >= line.len) return error.BadCopyFormat;
                const byte = line[index];
                index += 1;
                if (byte == options.escape and index < line.len and (line[index] == options.quote or line[index] == options.escape)) {
                    if (used == scratch.len) return error.TextCapacity;
                    scratch[used] = line[index];
                    used += 1;
                    index += 1;
                    continue;
                }
                if (byte == options.quote) break;
                if (used == scratch.len) return error.TextCapacity;
                scratch[used] = byte;
                used += 1;
            }
        }
        const raw = line[raw_start..index];
        out[count] = if (!saw_quote and equal(raw, options.null_string)) null else scratch[start..used];
        count += 1;
        if (index >= line.len) break;
        index += 1;
    }
    return count;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

pub const Sink = struct {
    bytes: []u8,
    at: usize = 0,

    pub fn append(self: *Sink, data: []const u8) error{BufferTooSmall}!void {
        if (data.len > self.bytes.len - self.at) return error.BufferTooSmall;
        @memcpy(self.bytes[self.at..][0..data.len], data);
        self.at += data.len;
    }

    pub fn byte(self: *Sink, value: u8) error{BufferTooSmall}!void {
        return self.append(&.{value});
    }
};

/// CopyAttributeOutText: control characters as `\b \f \n \r \t \v`, a
/// backslash or the delimiter preceded by a backslash.
pub fn appendText(options: *const Options, value: []const u8, out: *Sink) error{BufferTooSmall}!void {
    for (value) |byte| {
        const escaped: ?u8 = switch (byte) {
            8 => 'b',
            12 => 'f',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            11 => 'v',
            else => null,
        };
        if (escaped) |letter| {
            try out.byte('\\');
            try out.byte(letter);
        } else if (byte == '\\' or byte == options.delimiter) {
            try out.byte('\\');
            try out.byte(byte);
        } else try out.byte(byte);
    }
}

/// CopyAttributeOutCSV: quoted when it contains the delimiter, the quote,
/// CR or LF, equals the NULL string, or is `\.` alone in a one-column row;
/// quote and escape characters inside are preceded by the escape.
pub fn appendCsv(options: *const Options, value: []const u8, single: bool, out: *Sink) error{BufferTooSmall}!void {
    var use_quote = equal(value, options.null_string);
    if (!use_quote and single and equal(value, "\\.")) use_quote = true;
    if (!use_quote) for (value) |byte| {
        if (byte == options.delimiter or byte == options.quote or byte == '\n' or byte == '\r') {
            use_quote = true;
            break;
        }
    };
    if (!use_quote) return out.append(value);
    try out.byte(options.quote);
    for (value) |byte| {
        if (byte == options.quote or byte == options.escape) try out.byte(options.escape);
        try out.byte(byte);
    }
    try out.byte(options.quote);
}
