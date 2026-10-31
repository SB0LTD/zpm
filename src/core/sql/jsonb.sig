//! JSON / JSONB values (Layer 0, Q04). Deliberately separate from
//! src/core/json.sig (a non-validating key finder): this file implements
//! PostgreSQL's input validation, canonical JSONB form and operators.
//!
//! JSON keeps the validated input text verbatim. JSONB is a canonical binary
//! held in a text cell: object keys ordered by (length, bytes) with duplicate
//! keys last-wins, numbers as NUMERIC, nesting depth up to Config.json_depth
//! (deeper is 54001), encoded size up to Config.text_bytes (54000). Input must
//! be RFC 8259 JSON with PostgreSQL's escape rules: surrogate pairs combine,
//! a lone surrogate or bad text is 22P02 and `\u0000` is 22P05 for JSONB.
//! Output uses PostgreSQL's spacing (`{"a": 1, "b": [1, 2]}`). Operators:
//! -> ->> #> #>> @> <@ ?, btree ordering (PostgreSQL's compareJsonbContainers:
//! object > array > boolean > number > string > null, containers by size
//! first, a top-level scalar as a one-element pseudo array), jsonb_typeof and
//! jsonb_array_length. Strings compare bytewise (the reference compares them
//! with the database collation; ASCII-only data agrees).
//!
//! Binary format (little-endian): value = tag u8 + body;
//! 0 null, 1 false, 2 true, 3 number {special u8, negative u8, dscale u16,
//! n u8, n coefficient bytes}, 4 string {len u16, bytes}, 5 array {count u16,
//! size u16, elements}, 6 object {count u16, size u16, (key string body,
//! value)*}. `size` counts the bytes after the header.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const Error = types.Error;

pub const Tag = enum(u8) { null_value = 0, false_value = 1, true_value = 2, number = 3, string = 4, array = 5, object = 6 };

fn get16(bytes: []const u8) usize {
    return @as(usize, bytes[0]) | (@as(usize, bytes[1]) << 8);
}

fn put16(bytes: []u8, value: usize) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}

/// Total encoded size of the value starting at `at`.
pub fn sizeAt(bytes: []const u8, at: usize) usize {
    return switch (@as(Tag, @enumFromInt(bytes[at]))) {
        .null_value, .false_value, .true_value => 1,
        .number => 6 + bytes[at + 5],
        .string => 3 + get16(bytes[at + 1 ..]),
        .array, .object => 5 + get16(bytes[at + 3 ..]),
    };
}

pub fn tagOf(bytes: []const u8) Tag {
    return @enumFromInt(bytes[0]);
}

/// Structural check of untrusted JSONB bytes (change-record replay): every
/// tag, length and count stays within bounds, numbers are well formed and
/// object keys are in canonical order without duplicates.
pub fn validBinary(bytes: []const u8, depth_limit: usize, digits: usize) bool {
    if (bytes.len == 0) return false;
    const end = validAt(bytes, 0, bytes.len, depth_limit, digits) orelse return false;
    return end == bytes.len;
}

fn validAt(bytes: []const u8, at: usize, limit: usize, depth: usize, digits: usize) ?usize {
    if (at >= limit or bytes[at] > 6) return null;
    switch (@as(Tag, @enumFromInt(bytes[at]))) {
        .null_value, .false_value, .true_value => return at + 1,
        .number => {
            if (limit - at < 6 or bytes[at + 1] > 3 or bytes[at + 2] > 1 or bytes[at + 5] > 32) return null;
            const end = at + 6 + bytes[at + 5];
            if (end > limit or get16(bytes[at + 3 ..]) > numeric.max_scale) return null;
            const value = numberAt(bytes, at);
            if (numeric.digitCount(value.coef()) > digits) return null;
            return end;
        },
        .string => {
            if (limit - at < 3) return null;
            const end = at + 3 + get16(bytes[at + 1 ..]);
            return if (end <= limit) end else null;
        },
        .array, .object => {
            if (depth == 0 or limit - at < 5) return null;
            const object = bytes[at] == @intFromEnum(Tag.object);
            const end = at + 5 + get16(bytes[at + 3 ..]);
            if (end > limit) return null;
            var position = at + 5;
            var count: usize = 0;
            var previous: ?[]const u8 = null;
            while (position < end) : (count += 1) {
                if (object) {
                    if (end - position < 2) return null;
                    const length = get16(bytes[position..]);
                    if (end - position - 2 < length) return null;
                    const key = bytes[position + 2 ..][0..length];
                    if (previous) |last| if (keyOrder(last, key) >= 0) return null;
                    previous = key;
                    position += 2 + length;
                }
                position = validAt(bytes, position, end, depth - 1, digits) orelse return null;
            }
            if (position != end or count != get16(bytes[at + 1 ..])) return null;
            return end;
        },
    }
}

pub fn numberAt(bytes: []const u8, at: usize) numeric.Numeric {
    var out: numeric.Numeric = .{ .special = @enumFromInt(bytes[at + 1]), .negative = bytes[at + 2] != 0, .dscale = @intCast(get16(bytes[at + 3 ..])) };
    var raw: u256 = 0;
    const count = bytes[at + 5];
    var index: usize = count;
    while (index > 0) {
        index -= 1;
        raw = (raw << 8) | bytes[at + 6 + index];
    }
    out.setCoef(raw);
    return out;
}

pub fn stringAt(bytes: []const u8, at: usize) []const u8 {
    return bytes[at + 3 ..][0..get16(bytes[at + 1 ..])];
}

pub fn countAt(bytes: []const u8, at: usize) usize {
    return get16(bytes[at + 1 ..]);
}

/// Iterates container members (array elements, or object key/value pairs).
pub const Members = struct {
    bytes: []const u8,
    at: usize,
    end: usize,
    object: bool,

    pub fn init(bytes: []const u8, container: usize) Members {
        return .{ .bytes = bytes, .at = container + 5, .end = container + 5 + get16(bytes[container + 3 ..]), .object = bytes[container] == @intFromEnum(Tag.object) };
    }

    pub const Member = struct { key: []const u8 = "", value: usize };

    pub fn next(self: *Members) ?Member {
        if (self.at >= self.end) return null;
        var out: Member = .{ .value = self.at };
        if (self.object) {
            const length = get16(self.bytes[self.at..]);
            out.key = self.bytes[self.at + 2 ..][0..length];
            out.value = self.at + 2 + length;
        }
        self.at = out.value + sizeAt(self.bytes, out.value);
        return out;
    }
};

fn keyOrder(a: []const u8, b: []const u8) i8 {
    if (a.len != b.len) return if (a.len < b.len) -1 else 1;
    return types.bytesOrder(a, b);
}

pub fn Jsonb(comptime capacity: usize, comptime depth_limit: usize, comptime digits: usize) type {
    if (capacity > 65535) @compileError("JSONB values are limited to 65535 encoded bytes");
    const N = numeric.Ops(digits);
    return struct {
        pub const Buffer = struct {
            bytes: [capacity]u8 = undefined,
            len: usize = 0,

            fn reserve(self: *Buffer, count: usize) Error![]u8 {
                if (count > capacity - self.len) return error.TextCapacity;
                const out = self.bytes[self.len..][0..count];
                self.len += count;
                return out;
            }

            fn byte(self: *Buffer, value: u8) Error!void {
                (try self.reserve(1))[0] = value;
            }

            fn append(self: *Buffer, value: []const u8) Error!void {
                @memcpy(try self.reserve(value.len), value);
            }
        };

        // ---- parsing ----------------------------------------------------

        const Parser = struct {
            text: []const u8,
            at: usize = 0,
            /// null: validate only (JSON); otherwise unsorted JSONB output.
            out: ?*Buffer,
            depth: usize = 0,
            control: ?*types.ExecutionControl = null,

            fn skip(self: *Parser) void {
                while (self.at < self.text.len) : (self.at += 1) {
                    const c = self.text[self.at];
                    if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
                }
            }

            fn peek(self: *const Parser) u8 {
                return if (self.at < self.text.len) self.text[self.at] else 0;
            }

            fn word(self: *Parser, expected: []const u8) Error!void {
                if (self.text.len - self.at < expected.len or !types.same(self.text[self.at..][0..expected.len], expected)) return error.InvalidTextRepresentation;
                self.at += expected.len;
            }

            fn hex(self: *Parser) Error!u21 {
                if (self.text.len - self.at < 4) return error.InvalidTextRepresentation;
                var value: u21 = 0;
                for (self.text[self.at..][0..4]) |c| {
                    const digit_value: u21 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return error.InvalidTextRepresentation;
                    value = value * 16 + digit_value;
                }
                self.at += 4;
                return value;
            }

            fn emitCode(buffer: *Buffer, code: u21) Error!void {
                if (code < 0x80) return buffer.byte(@intCast(code));
                if (code < 0x800) {
                    try buffer.byte(@intCast(0xc0 | (code >> 6)));
                    return buffer.byte(@intCast(0x80 | (code & 0x3f)));
                }
                if (code < 0x10000) {
                    try buffer.byte(@intCast(0xe0 | (code >> 12)));
                    try buffer.byte(@intCast(0x80 | ((code >> 6) & 0x3f)));
                    return buffer.byte(@intCast(0x80 | (code & 0x3f)));
                }
                try buffer.byte(@intCast(0xf0 | (code >> 18)));
                try buffer.byte(@intCast(0x80 | ((code >> 12) & 0x3f)));
                try buffer.byte(@intCast(0x80 | ((code >> 6) & 0x3f)));
                return buffer.byte(@intCast(0x80 | (code & 0x3f)));
            }

            /// String body after the opening quote; writes {len u16, bytes}.
            fn string(self: *Parser, jsonb: bool) Error!void {
                var header: usize = 0;
                if (self.out) |out| {
                    header = out.len;
                    _ = try out.reserve(2);
                }
                var poll_at = self.at;
                while (true) {
                    if (self.at >= poll_at) {
                        if (self.control) |control| try control.checkpoint();
                        poll_at = self.at + 256;
                    }
                    if (self.at >= self.text.len) return error.InvalidTextRepresentation;
                    const c = self.text[self.at];
                    self.at += 1;
                    if (c == '"') break;
                    if (c < 0x20) return error.InvalidTextRepresentation;
                    if (c != '\\') {
                        if (self.out) |out| try out.byte(c);
                        continue;
                    }
                    if (self.at >= self.text.len) return error.InvalidTextRepresentation;
                    const escape = self.text[self.at];
                    self.at += 1;
                    const decoded: u8 = switch (escape) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => {
                            var code = try self.hex();
                            if (!jsonb and self.out == null) continue;
                            if (code >= 0xd800 and code <= 0xdbff) {
                                if (self.text.len - self.at < 2 or self.text[self.at] != '\\' or self.text[self.at + 1] != 'u') return error.InvalidTextRepresentation;
                                self.at += 2;
                                const low = try self.hex();
                                if (low < 0xdc00 or low > 0xdfff) return error.InvalidTextRepresentation;
                                code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                            } else if (code >= 0xdc00 and code <= 0xdfff) return error.InvalidTextRepresentation;
                            if (code == 0 and jsonb) return error.UntranslatableCharacter;
                            if (self.out) |out| try emitCode(out, code);
                            continue;
                        },
                        else => return error.InvalidTextRepresentation,
                    };
                    if (self.out) |out| try out.byte(decoded);
                }
                if (self.out) |out| {
                    const length = out.len - header - 2;
                    put16(out.bytes[header..], length);
                }
            }

            fn number(self: *Parser) Error!void {
                const start = self.at;
                if (self.peek() == '-') self.at += 1;
                if (self.peek() == '0') {
                    self.at += 1;
                } else if (self.peek() >= '1' and self.peek() <= '9') {
                    while (types.digit(self.peek())) self.at += 1;
                } else return error.InvalidTextRepresentation;
                if (self.peek() == '.') {
                    self.at += 1;
                    if (!types.digit(self.peek())) return error.InvalidTextRepresentation;
                    while (types.digit(self.peek())) self.at += 1;
                }
                if (self.peek() == 'e' or self.peek() == 'E') {
                    self.at += 1;
                    if (self.peek() == '+' or self.peek() == '-') self.at += 1;
                    if (!types.digit(self.peek())) return error.InvalidTextRepresentation;
                    while (types.digit(self.peek())) self.at += 1;
                }
                if (self.control) |control| try control.advance((self.at - start) / 256);
                const out = self.out orelse return;
                const value = N.parse(self.text[start..self.at]) catch |err| switch (err) {
                    error.NumericValueOutOfRange => return error.NumericValueOutOfRange,
                    error.NumericCapacity => return error.NumericCapacity,
                    else => return error.InvalidTextRepresentation,
                };
                try writeNumber(out, &value);
            }

            fn parseValue(self: *Parser, jsonb: bool) Error!void {
                if (self.control) |control| try control.checkpoint();
                self.skip();
                switch (self.peek()) {
                    '{', '[' => {
                        const object = self.peek() == '{';
                        self.depth += 1;
                        if (self.depth > depth_limit) return error.StatementTooComplex;
                        self.at += 1;
                        var header: usize = 0;
                        if (self.out) |out| {
                            header = out.len;
                            const reserved = try out.reserve(5);
                            reserved[0] = @intFromEnum(if (object) Tag.object else Tag.array);
                        }
                        var count: usize = 0;
                        self.skip();
                        const close: u8 = if (object) '}' else ']';
                        if (self.peek() == close) {
                            self.at += 1;
                        } else while (true) {
                            if (object) {
                                self.skip();
                                if (self.peek() != '"') return error.InvalidTextRepresentation;
                                self.at += 1;
                                try self.string(jsonb);
                                self.skip();
                                if (self.peek() != ':') return error.InvalidTextRepresentation;
                                self.at += 1;
                            }
                            try self.parseValue(jsonb);
                            count += 1;
                            self.skip();
                            if (self.peek() == ',') {
                                self.at += 1;
                                continue;
                            }
                            if (self.peek() != close) return error.InvalidTextRepresentation;
                            self.at += 1;
                            break;
                        }
                        if (self.out) |out| {
                            if (count > 65535) return error.TextCapacity;
                            put16(out.bytes[header + 1 ..], count);
                            put16(out.bytes[header + 3 ..], out.len - header - 5);
                        }
                        self.depth -= 1;
                    },
                    '"' => {
                        self.at += 1;
                        if (self.out) |out| try out.byte(@intFromEnum(Tag.string));
                        try self.string(jsonb);
                    },
                    't' => {
                        try self.word("true");
                        if (self.out) |out| try out.byte(@intFromEnum(Tag.true_value));
                    },
                    'f' => {
                        try self.word("false");
                        if (self.out) |out| try out.byte(@intFromEnum(Tag.false_value));
                    },
                    'n' => {
                        try self.word("null");
                        if (self.out) |out| try out.byte(@intFromEnum(Tag.null_value));
                    },
                    else => {
                        if (self.peek() == '-' or types.digit(self.peek())) return self.number();
                        return error.InvalidTextRepresentation;
                    },
                }
            }
        };

        pub fn writeNumber(out: *Buffer, value: *const numeric.Numeric) Error!void {
            var raw = value.coef();
            var coefficient: [32]u8 = undefined;
            var count: usize = 0;
            while (raw != 0) : (count += 1) {
                coefficient[count] = @truncate(raw);
                raw >>= 8;
            }
            const header = try out.reserve(6);
            header[0] = @intFromEnum(Tag.number);
            header[1] = @intFromEnum(value.special);
            header[2] = @intFromBool(value.negative);
            put16(header[3..], value.dscale);
            header[5] = @intCast(count);
            try out.append(coefficient[0..count]);
        }

        /// Validates JSON text (the JSON type keeps it verbatim).
        pub fn validateJson(text: []const u8) Error!void {
            return validateJsonControlled(text, null);
        }

        pub fn validateJsonControlled(text: []const u8, control: ?*types.ExecutionControl) Error!void {
            var parser: Parser = .{ .text = text, .out = null, .control = control };
            try parser.parseValue(false);
            parser.skip();
            if (parser.at != text.len) return error.InvalidTextRepresentation;
        }

        /// Text to canonical JSONB.
        pub fn parse(text: []const u8, out: *Buffer) Error!void {
            return parseControlled(text, out, null);
        }

        pub fn parseControlled(text: []const u8, out: *Buffer, control: ?*types.ExecutionControl) Error!void {
            var raw: Buffer = .{};
            var parser: Parser = .{ .text = text, .out = &raw, .control = control };
            try parser.parseValue(true);
            parser.skip();
            if (parser.at != text.len) return error.InvalidTextRepresentation;
            out.len = 0;
            try canonical(raw.bytes[0..raw.len], out, control);
        }

        fn offsetLess(bytes: []const u8, a: u16, b: u16, control: ?*types.ExecutionControl) Error!bool {
            if (control) |c| try c.checkpoint();
            const order = keyOrder(keyAt(bytes, a), keyAt(bytes, b));
            // The input offset breaks duplicate-key ties: the last input wins.
            return order < 0 or (order == 0 and a < b);
        }

        fn siftKeys(bytes: []const u8, keys: []u16, start: usize, control: ?*types.ExecutionControl) Error!void {
            var root = start;
            while (root < keys.len / 2) {
                var child = root * 2 + 1;
                if (child + 1 < keys.len and try offsetLess(bytes, keys[child], keys[child + 1], control)) child += 1;
                if (!try offsetLess(bytes, keys[root], keys[child], control)) break;
                const saved = keys[root]; keys[root] = keys[child]; keys[child] = saved;
                root = child;
            }
        }

        fn sortKeys(bytes: []const u8, keys: []u16, control: ?*types.ExecutionControl) Error!void {
            var root = keys.len / 2;
            while (root != 0) { root -= 1; try siftKeys(bytes, keys, root, control); }
            var end = keys.len;
            while (end > 1) {
                end -= 1;
                const saved = keys[0]; keys[0] = keys[end]; keys[end] = saved;
                try siftKeys(bytes, keys[0..end], 0, control);
            }
        }

        /// Iterative DFS uses one key pool for the whole document, rather than
        /// capacity-sized arrays in every recursive frame. Heapsort bounds the
        /// sorting work even for reverse-ordered or duplicate-heavy objects.
        fn canonical(bytes: []const u8, out: *Buffer, control: ?*types.ExecutionControl) Error!void {
            const Frame = struct {
                members: Members,
                header: usize,
                base: usize,
                total: usize = 0,
                index: usize = 0,
                count: usize = 0,
            };
            var frames: [depth_limit + 1]Frame = undefined;
            var keys: [capacity / 3 + 1]u16 = undefined;
            var key_top: usize = 0;
            var depth: usize = 0;
            var pending: ?usize = 0;
            while (true) {
                if (control) |c| try c.checkpoint();
                if (pending) |at| {
                    pending = null;
                    const tag: Tag = @enumFromInt(bytes[at]);
                    if (tag != .object and tag != .array) {
                        try out.append(bytes[at..][0..sizeAt(bytes, at)]);
                    } else {
                        if (depth >= depth_limit) return error.StatementTooComplex;
                        const header = out.len;
                        _ = try out.reserve(5);
                        out.bytes[header] = bytes[at];
                        var frame: Frame = .{ .members = Members.init(bytes, at), .header = header, .base = key_top };
                        if (tag == .object) {
                            var members = frame.members;
                            while (members.next()) |member| {
                                if (control) |c| try c.checkpoint();
                                if (key_top == keys.len) return error.TextCapacity;
                                keys[key_top] = @intCast(member.value - member.key.len - 2);
                                key_top += 1;
                            }
                            frame.total = key_top - frame.base;
                            try sortKeys(bytes, keys[frame.base..key_top], control);
                        }
                        frames[depth] = frame;
                        depth += 1;
                    }
                }
                while (depth != 0) {
                    const frame = &frames[depth - 1];
                    if (frame.members.object) {
                        while (frame.index < frame.total) {
                            const index = frame.index;
                            frame.index += 1;
                            const offset = keys[frame.base + index];
                            if (index + 1 < frame.total and types.same(keyAt(bytes, offset), keyAt(bytes, keys[frame.base + index + 1]))) continue;
                            const key = keyAt(bytes, offset);
                            try out.append(bytes[offset..][0..2 + key.len]);
                            pending = offset + 2 + key.len;
                            frame.count += 1;
                            break;
                        }
                    } else if (frame.members.next()) |member| {
                        pending = member.value;
                        frame.count += 1;
                    }
                    if (pending != null) break;
                    put16(out.bytes[frame.header + 1 ..], frame.count);
                    put16(out.bytes[frame.header + 3 ..], out.len - frame.header - 5);
                    key_top = frame.base;
                    depth -= 1;
                }
                if (pending == null and depth == 0) break;
            }
        }

        fn keyAt(bytes: []const u8, offset: usize) []const u8 {
            return bytes[offset + 2 ..][0..get16(bytes[offset..])];
        }

        // ---- output -----------------------------------------------------

        pub const Text = struct {
            bytes: []u8,
            len: usize = 0,

            fn append(self: *Text, value: []const u8) Error!void {
                if (value.len > self.bytes.len - self.len) return error.TextCapacity;
                @memcpy(self.bytes[self.len..][0..value.len], value);
                self.len += value.len;
            }

            fn byte(self: *Text, value: u8) Error!void {
                return self.append(&.{value});
            }
        };

        fn escaped(out: *Text, value: []const u8) Error!void {
            try out.byte('"');
            for (value) |c| switch (c) {
                '"' => try out.append("\\\""),
                '\\' => try out.append("\\\\"),
                0x08 => try out.append("\\b"),
                0x0c => try out.append("\\f"),
                '\n' => try out.append("\\n"),
                '\r' => try out.append("\\r"),
                '\t' => try out.append("\\t"),
                else => if (c < 0x20) {
                    const hex_digits = "0123456789abcdef";
                    try out.append(&.{ '\\', 'u', '0', '0', hex_digits[c >> 4], hex_digits[c & 15] });
                } else try out.byte(c),
            };
            try out.byte('"');
        }

        pub fn render(bytes: []const u8, at: usize, out: *Text) Error!void {
            switch (@as(Tag, @enumFromInt(bytes[at]))) {
                .null_value => try out.append("null"),
                .false_value => try out.append("false"),
                .true_value => try out.append("true"),
                .number => {
                    var buffer: [numeric.format_bytes]u8 = undefined;
                    const value = numberAt(bytes, at);
                    try out.append(N.format(&value, &buffer));
                },
                .string => try escaped(out, stringAt(bytes, at)),
                .array, .object => {
                    const object = bytes[at] == @intFromEnum(Tag.object);
                    try out.byte(if (object) '{' else '[');
                    var members = Members.init(bytes, at);
                    var first = true;
                    while (members.next()) |member| {
                        if (!first) try out.append(", ");
                        first = false;
                        if (object) {
                            try escaped(out, member.key);
                            try out.append(": ");
                        }
                        try render(bytes, member.value, out);
                    }
                    try out.byte(if (object) '}' else ']');
                },
            }
        }

        /// ->> text of a sub-value: strings unquoted, JSON null is SQL NULL.
        pub fn renderText(bytes: []const u8, at: usize, out: *Text) Error!bool {
            switch (@as(Tag, @enumFromInt(bytes[at]))) {
                .null_value => return false,
                .string => try out.append(stringAt(bytes, at)),
                else => try render(bytes, at, out),
            }
            return true;
        }

        // ---- operators --------------------------------------------------

        pub fn field(bytes: []const u8, key: []const u8) ?usize {
            if (bytes[0] != @intFromEnum(Tag.object)) return null;
            var members = Members.init(bytes, 0);
            while (members.next()) |member| if (types.same(member.key, key)) return member.value;
            return null;
        }

        pub fn element(bytes: []const u8, index: i64) ?usize {
            // A top-level scalar is a one-element pseudo array (PostgreSQL).
            if (scalar(bytes[0])) return if (index == 0 or index == -1) 0 else null;
            if (bytes[0] != @intFromEnum(Tag.array)) return null;
            const count: i64 = @intCast(countAt(bytes, 0));
            const wanted = if (index < 0) count + index else index;
            if (wanted < 0 or wanted >= count) return null;
            var members = Members.init(bytes, 0);
            var position: i64 = 0;
            while (members.next()) |member| : (position += 1) if (position == wanted) return member.value;
            return null;
        }

        fn subField(bytes: []const u8, at: usize, key: []const u8) ?usize {
            if (bytes[at] != @intFromEnum(Tag.object)) return null;
            var members = Members.init(bytes, at);
            while (members.next()) |member| if (types.same(member.key, key)) return member.value;
            return null;
        }

        fn subElement(bytes: []const u8, at: usize, step: []const u8) ?usize {
            if (bytes[at] != @intFromEnum(Tag.array)) return null;
            const index = pathIndex(step) orelse return null;
            const count: i64 = @intCast(countAt(bytes, at));
            const wanted = if (index < 0) count + index else index;
            if (wanted < 0 or wanted >= count) return null;
            var members = Members.init(bytes, at);
            var position: i64 = 0;
            while (members.next()) |member| : (position += 1) if (position == wanted) return member.value;
            return null;
        }

        /// #> over a '{a,b,...}' text-array literal; null when absent.
        pub fn path(bytes: []const u8, literal: []const u8) Error!?usize {
            var items: [32][]const u8 = undefined;
            const count = try parsePath(literal, &items);
            var at: usize = 0;
            for (items[0..count]) |step| {
                at = switch (@as(Tag, @enumFromInt(bytes[at]))) {
                    .object => subField(bytes, at, step) orelse return null,
                    .array => subElement(bytes, at, step) orelse return null,
                    else => return null,
                };
            }
            return at;
        }

        /// A text[] literal `{a,"b c",1}` (no NULL elements, no nesting).
        pub fn parsePath(literal: []const u8, items: *[32][]const u8) Error!usize {
            var start: usize = 0;
            var end = literal.len;
            while (start < end and literal[start] == ' ') start += 1;
            while (end > start and literal[end - 1] == ' ') end -= 1;
            if (end - start < 2 or literal[start] != '{' or literal[end - 1] != '}') return error.InvalidTextRepresentation;
            var at = start + 1;
            const close = end - 1;
            var count: usize = 0;
            while (at < close and literal[at] == ' ') at += 1;
            if (at == close) return 0;
            while (true) {
                while (at < close and literal[at] == ' ') at += 1;
                var item_start = at;
                var item_end = at;
                if (at < close and literal[at] == '"') {
                    item_start = at + 1;
                    at += 1;
                    while (at < close and literal[at] != '"') : (at += 1) if (literal[at] == '\\') return error.UnsupportedStatement;
                    if (at >= close) return error.InvalidTextRepresentation;
                    item_end = at;
                    at += 1;
                } else {
                    while (at < close and literal[at] != ',') : (at += 1) {
                        if (literal[at] == '{' or literal[at] == '}' or literal[at] == '"' or literal[at] == '\\') return error.InvalidTextRepresentation;
                    }
                    item_end = at;
                    while (item_end > item_start and literal[item_end - 1] == ' ') item_end -= 1;
                    if (item_end == item_start) return error.InvalidTextRepresentation;
                    if (types.keyword(literal[item_start..item_end], "null")) return error.UnsupportedStatement;
                }
                if (count == items.len) return error.TextCapacity;
                items[count] = literal[item_start..item_end];
                count += 1;
                while (at < close and literal[at] == ' ') at += 1;
                if (at == close) break;
                if (literal[at] != ',') return error.InvalidTextRepresentation;
                at += 1;
            }
            return count;
        }

        fn startContainer(out: *Buffer, tag: Tag) Error!void {
            out.len = 0;
            const header = try out.reserve(5);
            header[0] = @intFromEnum(tag);
        }

        fn finishContainer(out: *Buffer, count: usize) void {
            put16(out.bytes[1..], count);
            put16(out.bytes[3..], out.len - 5);
        }

        fn copyMember(out: *Buffer, bytes: []const u8, member: Members.Member, object: bool) Error!void {
            if (object) {
                put16(try out.reserve(2), member.key.len);
                try out.append(member.key);
            }
            try out.append(bytes[member.value..][0..sizeAt(bytes, member.value)]);
        }

        fn depthFits(bytes: []const u8, at: usize, depth: usize, control: ?*types.ExecutionControl) Error!bool {
            if (control) |c| try c.checkpoint();
            if (bytes[at] != @intFromEnum(Tag.object) and bytes[at] != @intFromEnum(Tag.array)) return true;
            if (depth == 0) return false;
            var members = Members.init(bytes, at);
            while (members.next()) |member| if (!try depthFits(bytes, member.value, depth - 1, control)) return false;
            return true;
        }

        /// Shallow JSONB concatenation. Inputs are canonical and do not alias
        /// the caller-owned output. Object merge is linear, with right wins.
        pub fn concat(a: []const u8, b: []const u8, out: *Buffer) Error!void {
            return concatControlled(a, b, out, null);
        }

        pub fn concatControlled(a: []const u8, b: []const u8, out: *Buffer, control: ?*types.ExecutionControl) Error!void {
            const objects = tagOf(a) == .object and tagOf(b) == .object;
            try startContainer(out, if (objects) .object else .array);
            var count: usize = 0;
            if (objects) {
                var ai = Members.init(a, 0);
                var bi = Members.init(b, 0);
                var av = ai.next();
                var bv = bi.next();
                while (av != null or bv != null) {
                    if (control) |c| try c.checkpoint();
                    const order: i8 = if (av == null) 1 else if (bv == null) -1 else keyOrder(av.?.key, bv.?.key);
                    if (order < 0) {
                        try copyMember(out, a, av.?, true);
                        av = ai.next();
                    } else {
                        try copyMember(out, b, bv.?, true);
                        bv = bi.next();
                        if (order == 0) av = ai.next();
                    }
                    count += 1;
                }
            } else {
                for ([_][]const u8{ a, b }) |bytes| {
                    if (tagOf(bytes) == .array) {
                        try out.append(bytes[5..]);
                        count += countAt(bytes, 0);
                    } else {
                        try out.append(bytes);
                        count += 1;
                    }
                }
            }
            finishContainer(out, count);
            if (!try depthFits(out.bytes[0..out.len], 0, depth_limit, control)) return error.StatementTooComplex;
        }

        pub const JsonSelector = union(enum) { field: []const u8, index: i64, path: []const u8 };
        const RawSpan = struct { start: usize, end: usize };

        /// Extraction decodes escapes throughout the document like PostgreSQL,
        /// but returns the original lexical substring (JSON is not JSONB).
        fn rawDocument(text: []const u8, control: ?*types.ExecutionControl) Error!RawSpan {
            var parser: Parser = .{ .text = text, .out = null, .control = control };
            parser.skip();
            const start = parser.at;
            try parser.parseValue(true);
            const end = parser.at;
            parser.skip();
            if (parser.at != text.len) return error.InvalidTextRepresentation;
            return .{ .start = start, .end = end };
        }

        fn rawField(text: []const u8, span: RawSpan, key: []const u8, control: ?*types.ExecutionControl) Error!?RawSpan {
            if (text[span.start] != '{') return null;
            var parser: Parser = .{ .text = text, .at = span.start + 1, .out = null, .control = control };
            var found: ?RawSpan = null;
            parser.skip();
            while (parser.peek() != '}') {
                if (parser.peek() != '"') return error.InvalidTextRepresentation;
                parser.at += 1;
                var decoded: Buffer = .{};
                parser.out = &decoded;
                try parser.string(true);
                parser.out = null;
                const matches = types.same(decoded.bytes[2..decoded.len], key);
                parser.skip();
                if (parser.peek() != ':') return error.InvalidTextRepresentation;
                parser.at += 1;
                parser.skip();
                const start = parser.at;
                try parser.parseValue(true);
                if (matches) found = .{ .start = start, .end = parser.at };
                parser.skip();
                if (parser.peek() == '}') break;
                if (parser.peek() != ',') return error.InvalidTextRepresentation;
                parser.at += 1;
                parser.skip();
            }
            return found;
        }

        fn rawElement(text: []const u8, span: RawSpan, index: i64, control: ?*types.ExecutionControl) Error!?RawSpan {
            if (text[span.start] != '[') return null;
            var wanted = index;
            if (wanted < 0) {
                var scan: Parser = .{ .text = text, .at = span.start + 1, .out = null, .control = control };
                var count: i64 = 0;
                scan.skip();
                while (scan.peek() != ']') {
                    try scan.parseValue(true);
                    count += 1;
                    scan.skip();
                    if (scan.peek() == ']') break;
                    scan.at += 1;
                    scan.skip();
                }
                wanted += count;
            }
            if (wanted < 0) return null;
            var parser: Parser = .{ .text = text, .at = span.start + 1, .out = null, .control = control };
            var position: i64 = 0;
            parser.skip();
            while (parser.peek() != ']') : (position += 1) {
                const start = parser.at;
                try parser.parseValue(true);
                if (position == wanted) return .{ .start = start, .end = parser.at };
                parser.skip();
                if (parser.peek() == ']') break;
                parser.at += 1;
                parser.skip();
            }
            return null;
        }

        fn pathIndex(step: []const u8) ?i64 {
            var at: usize = 0;
            while (at < step.len and (step[at] == ' ' or (step[at] >= 9 and step[at] <= 13))) at += 1;
            var negative = false;
            if (at < step.len and (step[at] == '-' or step[at] == '+')) {
                negative = step[at] == '-';
                at += 1;
            }
            if (at == step.len) return null;
            var number: i64 = 0;
            const limit: i64 = if (negative) 2147483648 else 2147483647;
            while (at < step.len) : (at += 1) {
                if (!types.digit(step[at])) return null;
                const digit: i64 = step[at] - '0';
                if (number > @divTrunc(limit - digit, 10)) return null;
                number = number * 10 + digit;
            }
            return if (negative) -number else number;
        }

        /// Returns false for SQL NULL (missing member, wrong structure, or
        /// JSON null requested as text). An empty path selects the root.
        pub fn extractJson(text: []const u8, selector: JsonSelector, as_text: bool, out: *Buffer) Error!bool {
            return extractJsonControlled(text, selector, as_text, out, null);
        }

        pub fn extractJsonControlled(text: []const u8, selector: JsonSelector, as_text: bool, out: *Buffer, control: ?*types.ExecutionControl) Error!bool {
            var span = try rawDocument(text, control);
            switch (selector) {
                .field => |key| span = (try rawField(text, span, key, control)) orelse return false,
                .index => |index| span = (try rawElement(text, span, index, control)) orelse return false,
                .path => |literal| {
                    var items: [32][]const u8 = undefined;
                    const count = try parsePath(literal, &items);
                    for (items[0..count]) |step| {
                        span = if (text[span.start] == '{') (try rawField(text, span, step, control)) orelse return false
                            else if (text[span.start] == '[') (try rawElement(text, span, pathIndex(step) orelse return false, control)) orelse return false
                            else return false;
                    }
                },
            }
            out.len = 0;
            if (as_text and text[span.start] == 'n') return false;
            if (as_text and text[span.start] == '"') {
                var parser: Parser = .{ .text = text, .at = span.start + 1, .out = out, .control = control };
                try parser.string(true);
                const length = out.len - 2;
                for (0..length) |i| out.bytes[i] = out.bytes[i + 2];
                out.len = length;
            } else try out.append(text[span.start..span.end]);
            return true;
        }

        /// The `?` operator.
        pub fn exists(bytes: []const u8, key: []const u8) bool {
            switch (@as(Tag, @enumFromInt(bytes[0]))) {
                .object => return field(bytes, key) != null,
                .array => {
                    var members = Members.init(bytes, 0);
                    while (members.next()) |member| {
                        if (bytes[member.value] == @intFromEnum(Tag.string) and types.same(stringAt(bytes, member.value), key)) return true;
                    }
                    return false;
                },
                .string => return types.same(stringAt(bytes, 0), key),
                else => return false,
            }
        }

        fn scalar(tag: u8) bool {
            return tag != @intFromEnum(Tag.array) and tag != @intFromEnum(Tag.object);
        }

        fn scalarEqual(a: []const u8, ai: usize, b: []const u8, bi: usize) bool {
            if (a[ai] != b[bi]) return false;
            return switch (@as(Tag, @enumFromInt(a[ai]))) {
                .number => blk: {
                    const left = numberAt(a, ai);
                    const right = numberAt(b, bi);
                    break :blk N.compare(&left, &right) == 0;
                },
                .string => types.same(stringAt(a, ai), stringAt(b, bi)),
                else => true,
            };
        }

        /// JsonbDeepContains: does `a` (at ai) contain `b` (at bi)?
        fn deepContains(a: []const u8, ai: usize, b: []const u8, bi: usize) bool {
            if (a[ai] != b[bi]) return false;
            if (a[ai] == @intFromEnum(Tag.object)) {
                var wanted = Members.init(b, bi);
                while (wanted.next()) |pair| {
                    const found = subField(a, ai, pair.key) orelse return false;
                    if (scalar(b[pair.value])) {
                        if (!scalarEqual(a, found, b, pair.value)) return false;
                    } else if (!deepContains(a, found, b, pair.value)) return false;
                }
                return true;
            }
            if (a[ai] == @intFromEnum(Tag.array)) {
                var wanted = Members.init(b, bi);
                outer: while (wanted.next()) |item| {
                    var have = Members.init(a, ai);
                    while (have.next()) |candidate| {
                        if (scalar(b[item.value])) {
                            if (scalarEqual(a, candidate.value, b, item.value)) continue :outer;
                        } else if (a[candidate.value] == b[item.value] and deepContains(a, candidate.value, b, item.value)) continue :outer;
                    }
                    return false;
                }
                return true;
            }
            return scalarEqual(a, ai, b, bi);
        }

        /// The `@>` operator over whole values (top-level scalars are
        /// one-element pseudo arrays, as in PostgreSQL).
        pub fn contains(a: []const u8, b: []const u8) bool {
            const a_scalar = scalar(a[0]);
            const b_scalar = scalar(b[0]);
            if (a_scalar and b_scalar) return scalarEqual(a, 0, b, 0);
            if (a_scalar) return false;
            if (b_scalar) {
                if (a[0] != @intFromEnum(Tag.array)) return false;
                var have = Members.init(a, 0);
                while (have.next()) |candidate| if (scalarEqual(a, candidate.value, b, 0)) return true;
                return false;
            }
            return deepContains(a, 0, b, 0);
        }

        fn typeRank(tag: u8) u8 {
            // jbvNull < jbvString < jbvNumeric < jbvBool < array < object.
            return switch (@as(Tag, @enumFromInt(tag))) {
                .null_value => 0,
                .string => 1,
                .number => 2,
                .false_value, .true_value => 3,
                .array => 16,
                .object => 17,
            };
        }

        fn compareScalar(a: []const u8, ai: usize, b: []const u8, bi: usize) i8 {
            const ra = typeRank(a[ai]);
            const rb = typeRank(b[bi]);
            if (ra != rb) return if (ra < rb) -1 else 1;
            return switch (@as(Tag, @enumFromInt(a[ai]))) {
                .null_value => 0,
                .string => types.bytesOrder(stringAt(a, ai), stringAt(b, bi)),
                .number => blk: {
                    const left = numberAt(a, ai);
                    const right = numberAt(b, bi);
                    break :blk N.compare(&left, &right);
                },
                .false_value, .true_value => if (a[ai] == b[bi]) 0 else if (a[ai] < b[bi]) -1 else 1,
                else => unreachable,
            };
        }

        const Shape = struct { rank: u8, count: usize, raw: bool };

        fn shapeOf(bytes: []const u8, at: usize, top: bool) Shape {
            if (scalar(bytes[at])) return .{ .rank = 16, .count = 1, .raw = top };
            return .{ .rank = typeRank(bytes[at]), .count = countAt(bytes, at), .raw = false };
        }

        fn compareContainer(a: []const u8, ai: usize, b: []const u8, bi: usize, top: bool) i8 {
            const sa = shapeOf(a, ai, top);
            const sb = shapeOf(b, bi, top);
            if (sa.rank != sb.rank) return if (sa.rank < sb.rank) -1 else 1;
            var result: i8 = 0;
            if (sa.raw != sb.raw) result = if (sa.raw) -1 else 1;
            if (sa.count != sb.count) result = if (sa.count > sb.count) 1 else -1;
            if (result != 0) return result;
            if (sa.raw) return compareScalar(a, ai, b, bi);
            var left = Members.init(a, ai);
            var right = Members.init(b, bi);
            while (left.next()) |l| {
                const r = right.next().?;
                if (left.object) {
                    const order = types.bytesOrder(l.key, r.key);
                    if (order != 0) return order;
                }
                const lv = l.value;
                const rv = r.value;
                if (scalar(a[lv]) and scalar(b[rv])) {
                    const order = compareScalar(a, lv, b, rv);
                    if (order != 0) return order;
                } else if (scalar(a[lv]) != scalar(b[rv])) {
                    // A scalar element against a container: by type.
                    const ra = typeRank(a[lv]);
                    const rb = typeRank(b[rv]);
                    if (ra != rb) return if (ra < rb) -1 else 1;
                } else {
                    const order = compareContainer(a, lv, b, rv, false);
                    if (order != 0) return order;
                }
            }
            return 0;
        }

        /// btree order of whole values.
        pub fn compare(a: []const u8, b: []const u8) i8 {
            return compareContainer(a, 0, b, 0, true);
        }

        /// Hash consistent with compare (number scale ignored).
        pub fn hash(bytes: []const u8, at: usize, code: *u64) void {
            const mix = struct {
                fn byte(state: *u64, value: u8) void {
                    state.* = (state.* ^ value) *% 1099511628211;
                }
            };
            mix.byte(code, typeRank(bytes[at]));
            switch (@as(Tag, @enumFromInt(bytes[at]))) {
                .number => {
                    const value = numberAt(bytes, at);
                    for (N.hashKey(&value)) |limb| {
                        var bits = limb;
                        for (0..8) |_| {
                            mix.byte(code, @truncate(bits));
                            bits >>= 8;
                        }
                    }
                },
                .string => for (stringAt(bytes, at)) |c| mix.byte(code, c),
                .array, .object => {
                    var members = Members.init(bytes, at);
                    while (members.next()) |member| {
                        for (member.key) |c| mix.byte(code, c);
                        hash(bytes, member.value, code);
                    }
                },
                else => {},
            }
        }

        pub fn typeName(bytes: []const u8) []const u8 {
            return switch (@as(Tag, @enumFromInt(bytes[0]))) {
                .null_value => "null",
                .false_value, .true_value => "boolean",
                .number => "number",
                .string => "string",
                .array => "array",
                .object => "object",
            };
        }

        /// jsonb_array_length: arrays only (22023 otherwise).
        pub fn arrayLength(bytes: []const u8) Error!i64 {
            if (bytes[0] != @intFromEnum(Tag.array)) return error.InvalidParameterValue;
            return @intCast(countAt(bytes, 0));
        }

        /// A self-contained sub-value as its own JSONB value.
        pub fn copyValue(bytes: []const u8, at: usize, out: []u8) []const u8 {
            const size = sizeAt(bytes, at);
            @memcpy(out[0..size], bytes[at..][0..size]);
            return out[0..size];
        }
    };
}
