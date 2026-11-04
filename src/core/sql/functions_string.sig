//! PostgreSQL text functions for a UTF-8 database (Layer 0, B11).
//!
//! Character positions and lengths count characters as pg_mblen does: the
//! UTF-8 lead byte gives the width, clamped at the end of the value. Results
//! are either subslices of an argument or bytes appended to a caller-owned
//! fixed buffer (`Out`, TextCapacity 54000 beyond it). Every loop whose
//! length depends on the input calls the statement's execution checkpoint.
//!
//! Case mapping (lower/upper/initcap) follows PostgreSQL's C/POSIX ctype
//! (asc_tolower and friends): only ASCII letters change. Locale-specific
//! folding of other characters is not modelled.
const types = @import("types.sig");
const Error = types.Error;

pub const Control = ?*types.ExecutionControl;

fn tick(control: Control) Error!void {
    if (control) |active| try active.checkpoint();
}

/// A caller-owned output buffer.
pub const Out = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn append(self: *Out, data: []const u8) Error!void {
        if (data.len > self.bytes.len - self.len) return error.TextCapacity;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn byte(self: *Out, value: u8) Error!void {
        if (self.len == self.bytes.len) return error.TextCapacity;
        self.bytes[self.len] = value;
        self.len += 1;
    }

    pub fn slice(self: *const Out) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// pg_utf_mblen.
pub fn leadWidth(byte: u8) usize {
    if (byte & 0x80 == 0) return 1;
    if (byte & 0xe0 == 0xc0) return 2;
    if (byte & 0xf0 == 0xe0) return 3;
    if (byte & 0xf8 == 0xf0) return 4;
    return 1;
}

/// Width of the character at `at`, clamped to the value (pg_mblen_range).
pub fn widthAt(text: []const u8, at: usize) usize {
    return @min(leadWidth(text[at]), text.len - at);
}

/// pg_mbstrlen_with_len.
pub fn charLength(text: []const u8, control: Control) Error!usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (count += 1) {
        try tick(control);
        at += widthAt(text, at);
    }
    return count;
}

/// Byte offset after the first `limit` characters (pg_mbcharcliplen);
/// a limit <= 0 is 0.
pub fn clip(text: []const u8, limit: i64, control: Control) Error!usize {
    var at: usize = 0;
    var count: i64 = 0;
    while (at < text.len and count < limit) : (count += 1) {
        try tick(control);
        at += widthAt(text, at);
    }
    return at;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn asciiUpper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
}

pub const Case = enum { lower, upper, initcap };

/// lower/upper/initcap under C/POSIX ctype (asc_tolower, asc_toupper,
/// asc_initcap: words are runs of ASCII letters and digits).
pub fn mapCase(text: []const u8, mode: Case, out: *Out, control: Control) Error!void {
    var in_word = false;
    for (text) |byte| {
        try tick(control);
        const mapped = switch (mode) {
            .lower => asciiLower(byte),
            .upper => asciiUpper(byte),
            .initcap => if (in_word) asciiLower(byte) else asciiUpper(byte),
        };
        in_word = (mapped >= 'A' and mapped <= 'Z') or (mapped >= 'a' and mapped <= 'z') or (mapped >= '0' and mapped <= '9');
        try out.byte(mapped);
    }
}

/// text_substring: characters [start, start+count) intersected with
/// [1, end]; a negative count is 22011; no count runs to the end.
pub fn substring(text: []const u8, start: i64, count: ?i64, control: Control) Error![]const u8 {
    const first = @max(start, 1);
    var end_position: ?i64 = null;
    if (count) |length| {
        if (length < 0) return error.SubstringError;
        const end = start + length;
        if (end <= first) return text[0..0];
        end_position = end;
    }
    const from = try clip(text, first - 1, control);
    if (end_position) |end| {
        const rest = text[from..];
        return rest[0..try clip(rest, end - first, control)];
    }
    return text[from..];
}

/// The byte offset of the first occurrence of `needle` at or after `from`.
fn find(haystack: []const u8, needle: []const u8, from: usize, control: Control) Error!?usize {
    if (needle.len > haystack.len) return null;
    var at = from;
    while (at + needle.len <= haystack.len) : (at += 1) {
        try tick(control);
        if (types.same(haystack[at..][0..needle.len], needle)) return at;
    }
    return null;
}

/// strpos/position: 1-based character position of the first match; 0 if
/// none; an empty needle is found at 1.
pub fn position(haystack: []const u8, needle: []const u8, control: Control) Error!i64 {
    if (needle.len == 0) return 1;
    const at = (try find(haystack, needle, 0, control)) orelse return 0;
    return @as(i64, @intCast(try charLength(haystack[0..at], control))) + 1;
}

/// replace: every non-overlapping match, left to right. An empty `from`
/// returns the input.
pub fn replace(text: []const u8, from: []const u8, to: []const u8, out: *Out, control: Control) Error!void {
    if (from.len == 0) return out.append(text);
    var at: usize = 0;
    while (try find(text, from, at, control)) |match| {
        try out.append(text[at..match]);
        try out.append(to);
        at = match + from.len;
    }
    try out.append(text[at..]);
}

/// text_left: the first n characters; negative n drops the last |n|.
pub fn left(text: []const u8, n: i32, control: Control) Error![]const u8 {
    if (n >= 0) return text[0..try clip(text, n, control)];
    const total: i64 = @intCast(try charLength(text, control));
    return text[0..try clip(text, total + n, control)];
}

/// text_right: the last n characters; negative n drops the first |n|.
/// `-n` wraps for INT_MIN as in C, keeping the whole value.
pub fn right(text: []const u8, n: i32, control: Control) Error![]const u8 {
    const skip: i64 = if (n < 0) -%n else @as(i64, @intCast(try charLength(text, control))) - n;
    return text[try clip(text, skip, control)..];
}

/// repeat: a negative count is zero.
pub fn repeat(text: []const u8, count: i32, out: *Out, control: Control) Error!void {
    var remaining = @max(count, 0);
    if (text.len == 0) return;
    while (remaining > 0) : (remaining -= 1) {
        try tick(control);
        try out.append(text);
    }
}

/// reverse: characters in reverse order.
pub fn reverse(text: []const u8, out: *Out, control: Control) Error!void {
    if (text.len > out.bytes.len - out.len) return error.TextCapacity;
    var at: usize = 0;
    const base = out.len;
    while (at < text.len) {
        try tick(control);
        const width = widthAt(text, at);
        const target = base + text.len - at - width;
        @memcpy(out.bytes[target..][0..width], text[at..][0..width]);
        at += width;
    }
    out.len = base + text.len;
}

/// lpad/rpad: pad with `fill` (cycled) or truncate to `length` characters.
pub fn pad(text: []const u8, length: i32, fill: []const u8, at_left: bool, out: *Out, control: Control) Error!void {
    var wanted: i64 = @max(length, 0);
    var keep: i64 = @intCast(try charLength(text, control));
    if (keep > wanted) keep = wanted;
    if (fill.len == 0) wanted = keep;
    const kept = text[0..try clip(text, keep, control)];
    if (!at_left) try out.append(kept);
    var missing = wanted - keep;
    var at: usize = 0;
    while (missing > 0) : (missing -= 1) {
        try tick(control);
        const width = widthAt(fill, at);
        try out.append(fill[at..][0..width]);
        at += width;
        if (at == fill.len) at = 0;
    }
    if (at_left) try out.append(kept);
}

fn member(set: []const u8, character: []const u8, control: Control) Error!bool {
    var at: usize = 0;
    while (at < set.len) {
        try tick(control);
        const width = widthAt(set, at);
        if (types.same(set[at..][0..width], character)) return true;
        at += width;
    }
    return false;
}

/// btrim/ltrim/rtrim: strip characters found in `set` (default one space).
pub fn trim(text: []const u8, set: []const u8, leading: bool, trailing: bool, control: Control) Error![]const u8 {
    if (text.len == 0 or set.len == 0) return text;
    var start: usize = 0;
    if (leading) {
        while (start < text.len) {
            const width = widthAt(text, start);
            if (!try member(set, text[start..][0..width], control)) break;
            start += width;
        }
    }
    var end = text.len;
    if (trailing) {
        // One forward pass: the start of the final run of set members.
        var run: ?usize = null;
        var at = start;
        while (at < text.len) {
            const width = widthAt(text, at);
            if (try member(set, text[at..][0..width], control)) {
                if (run == null) run = at;
            } else run = null;
            at += width;
        }
        end = run orelse text.len;
    }
    return text[start..end];
}

/// split_part: field 0 is 22023; negative fields count from the end.
pub fn splitPart(text: []const u8, separator: []const u8, field_in: i32, control: Control) Error![]const u8 {
    if (field_in == 0) return error.InvalidParameterValue;
    if (text.len == 0) return text;
    var field: i64 = field_in;
    if (separator.len == 0) return if (field == 1 or field == -1) text else text[0..0];
    const first = (try find(text, separator, 0, control)) orelse return if (field == 1 or field == -1) text else text[0..0];
    if (field < 0) {
        var fields: i64 = 2;
        var last = first;
        var at = first + separator.len;
        while (try find(text, separator, at, control)) |match| {
            fields += 1;
            last = match;
            at = match + separator.len;
        }
        if (field == -1) return text[last + separator.len ..];
        field += fields + 1;
        if (field <= 0) return text[0..0];
    }
    var start: usize = 0;
    var end: ?usize = first;
    while (field > 1) : (field -= 1) {
        const finish = end orelse return text[0..0];
        start = finish + separator.len;
        end = try find(text, separator, start, control);
    }
    return text[start .. end orelse text.len];
}

pub fn startsWith(text: []const u8, prefix: []const u8) bool {
    return prefix.len <= text.len and types.same(text[0..prefix.len], prefix);
}

/// ascii: the first character's code point (0 for empty text).
pub fn ascii(text: []const u8) i64 {
    if (text.len == 0) return 0;
    const lead = text[0];
    if (lead <= 127) return lead;
    var value: i64 = 0;
    var extra: usize = 0;
    if (lead >= 0xf0) {
        value = lead & 0x07;
        extra = 3;
    } else if (lead >= 0xe0) {
        value = lead & 0x0f;
        extra = 2;
    } else {
        value = lead & 0x1f;
        extra = 1;
    }
    for (1..extra + 1) |index| {
        if (index >= text.len) break;
        value = (value << 6) + (text[index] & 0x3f);
    }
    return value;
}

/// chr: a negative code is 22023; 0, code points above U+10FFFF and
/// surrogates are 54000.
pub fn chr(code: i64, out: *Out) Error!void {
    if (code < 0) return error.InvalidParameterValue;
    if (code == 0 or code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return error.ProgramLimitExceeded;
    const value: u32 = @intCast(code);
    if (value < 0x80) return out.byte(@intCast(value));
    if (value < 0x800) {
        try out.byte(@intCast(0xc0 | (value >> 6)));
    } else if (value < 0x10000) {
        try out.byte(@intCast(0xe0 | (value >> 12)));
        try out.byte(@intCast(0x80 | ((value >> 6) & 0x3f)));
    } else {
        try out.byte(@intCast(0xf0 | (value >> 18)));
        try out.byte(@intCast(0x80 | ((value >> 12) & 0x3f)));
        try out.byte(@intCast(0x80 | ((value >> 6) & 0x3f)));
    }
    try out.byte(@intCast(0x80 | (value & 0x3f)));
}

/// translate: each character found in `from` becomes the character at the
/// same index of `to`, or is deleted when `to` is shorter.
pub fn translate(text: []const u8, from: []const u8, to: []const u8, out: *Out, control: Control) Error!void {
    var at: usize = 0;
    while (at < text.len) {
        const width = widthAt(text, at);
        const character = text[at..][0..width];
        var index: usize = 0;
        var scan: usize = 0;
        var found = false;
        while (scan < from.len) {
            try tick(control);
            const step = widthAt(from, scan);
            if (types.same(from[scan..][0..step], character)) {
                found = true;
                break;
            }
            scan += step;
            index += 1;
        }
        if (!found) {
            try out.append(character);
        } else {
            var target: usize = 0;
            var skipped: usize = 0;
            while (skipped < index and target < to.len) : (skipped += 1) {
                try tick(control);
                target += widthAt(to, target);
            }
            if (target < to.len) try out.append(to[target..][0..widthAt(to, target)]);
        }
        at += width;
    }
}

/// text_overlay: a start below 1 is 22011; start + count overflowing int4
/// is 22003.
pub fn overlay(text: []const u8, placing: []const u8, start: i32, count: i32, out: *Out, control: Control) Error!void {
    if (start <= 0) return error.SubstringError;
    const after = @addWithOverflow(start, count);
    if (after[1] != 0) return error.NumericValueOutOfRange;
    try out.append(try substring(text, 1, start - 1, control));
    try out.append(placing);
    try out.append(try substring(text, after[0], null, control));
}

/// to_hex: two's-complement digits of an int4 or int8, lower case.
pub fn toHex(value: i64, bits: u7, out: *Out) Error!void {
    var magnitude: u64 = if (bits == 32) @as(u32, @bitCast(@as(i32, @truncate(value)))) else @bitCast(value);
    var digits: [16]u8 = undefined;
    var index: usize = digits.len;
    while (true) {
        index -= 1;
        digits[index] = "0123456789abcdef"[@intCast(magnitude & 15)];
        magnitude >>= 4;
        if (magnitude == 0) break;
    }
    try out.append(digits[index..]);
}
