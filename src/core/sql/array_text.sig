//! Array text input and output, element-wise casts and typmods (Layer 0),
//! after arrayfuncs.c array_in/array_out and array_coerce.
//!
//! array_in accepts optional dimension decoration `[lb:ub]...=` and nested
//! braces; elements are separated by `,`, may be double-quoted with
//! backslash escapes (unquoted elements may also use backslashes), and
//! surrounding whitespace is ignored. An unquoted NULL (any case) is a NULL
//! element. Sub-arrays must be rectangular and every element must sit at
//! the same depth. Anything else is 22P02; more than six dimensions are
//! 54000. Each element goes through its type's input function with the
//! column typmod. array_out quotes empty strings, NULL, and text containing
//! `"`, `\`, `{`, `}`, `,` or whitespace, and prints the dimension
//! decoration when a lower bound is not 1.
const types = @import("types.sig");
const array = @import("array.sig");
const Error = types.Error;
const Type = types.Type;

pub fn ArrayText(comptime config: types.Config, comptime Io: type) type {
    const V = types.Values(config);
    const A = V.Arrays;
    return struct {
        fn space(byte: u8) bool {
            return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
        }

        const Out = struct {
            buffer: []u8,
            len: usize = 0,

            fn bytes(self: *Out, value: []const u8) Error!void {
                if (value.len > self.buffer.len - self.len) return error.TextCapacity;
                @memcpy(self.buffer[self.len..][0..value.len], value);
                self.len += value.len;
            }

            fn byte(self: *Out, value: u8) Error!void {
                return self.bytes(&.{value});
            }

            fn number(self: *Out, value: i64) Error!void {
                var digits: [24]u8 = undefined;
                var index: usize = digits.len;
                var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
                while (true) {
                    index -= 1;
                    digits[index] = @intCast('0' + magnitude % 10);
                    magnitude /= 10;
                    if (magnitude == 0) break;
                }
                if (value < 0) try self.byte('-');
                try self.bytes(digits[index..]);
            }
        };

        /// `[lb:ub]` for every dimension (array_dims and the decoration).
        pub fn dimensions(layout: *const array.Shape, buffer: []u8) Error![]const u8 {
            var out: Out = .{ .buffer = buffer };
            for (0..layout.ndim) |dim| {
                try out.byte('[');
                try out.number(layout.lbounds[dim]);
                try out.byte(':');
                try out.number(layout.upper(dim));
                try out.byte(']');
            }
            return buffer[0..out.len];
        }

        fn needsQuote(text: []const u8) bool {
            if (text.len == 0) return true;
            if (text.len == 4 and types.keyword(text, "null")) return true;
            for (text) |c| {
                if (c == '"' or c == '\\' or c == '{' or c == '}' or c == ',' or space(c)) return true;
            }
            return false;
        }

        /// array_out into `buffer`.
        pub fn format(bytes: []const u8, session: *const Io.SessionValues, buffer: []u8) Error![]const u8 {
            const layout = A.shape(bytes);
            var out: Out = .{ .buffer = buffer };
            if (layout.ndim == 0) {
                try out.bytes("{}");
                return buffer[0..out.len];
            }
            var decorated = false;
            for (layout.lbounds[0..layout.ndim]) |lbound| decorated = decorated or lbound != 1;
            if (decorated) {
                out.len += (try dimensions(&layout, buffer)).len;
                try out.byte('=');
            }
            for (0..layout.ndim) |_| try out.byte('{');
            var reader = A.Reader.init(bytes);
            var cell: V.Cell = undefined;
            var element: [Io.format_bytes]u8 = undefined;
            while (reader.next(&cell)) {
                const index = reader.index - 1;
                if (index != 0) {
                    // Close and reopen every dimension that rolled over.
                    var rolled: usize = 0;
                    var span: usize = 1;
                    var dim = layout.ndim;
                    while (dim > 1) {
                        dim -= 1;
                        span *= layout.dims[dim];
                        if (index % span != 0) break;
                        rolled += 1;
                    }
                    for (0..rolled) |_| try out.byte('}');
                    try out.byte(',');
                    for (0..rolled) |_| try out.byte('{');
                }
                if (cell == .null_value) {
                    try out.bytes("NULL");
                    continue;
                }
                const text = try Io.format(&cell, false, session, &element);
                if (!needsQuote(text)) {
                    try out.bytes(text);
                    continue;
                }
                try out.byte('"');
                for (text) |c| {
                    if (c == '"' or c == '\\') try out.byte('\\');
                    try out.byte(c);
                }
                try out.byte('"');
            }
            for (0..layout.ndim) |_| try out.byte('}');
            return buffer[0..out.len];
        }

        // ---- array_in ------------------------------------------------------

        const Token = union(enum) { open, close, delimiter, item: Item, end };
        const Item = struct { start: usize, end: usize, quoted: bool, escaped: bool };

        const Scanner = struct {
            input: []const u8,
            at: usize,

            fn next(self: *Scanner) Error!Token {
                while (self.at < self.input.len and space(self.input[self.at])) self.at += 1;
                if (self.at == self.input.len) return .end;
                const c = self.input[self.at];
                switch (c) {
                    '{' => {
                        self.at += 1;
                        return .open;
                    },
                    '}' => {
                        self.at += 1;
                        return .close;
                    },
                    ',' => {
                        self.at += 1;
                        return .delimiter;
                    },
                    '"' => {
                        self.at += 1;
                        const start = self.at;
                        var escaped = false;
                        while (true) {
                            if (self.at == self.input.len) return error.InvalidTextRepresentation;
                            const byte = self.input[self.at];
                            if (byte == '\\') {
                                if (self.at + 1 == self.input.len) return error.InvalidTextRepresentation;
                                escaped = true;
                                self.at += 2;
                                continue;
                            }
                            if (byte == '"') break;
                            self.at += 1;
                        }
                        const end = self.at;
                        self.at += 1;
                        return .{ .item = .{ .start = start, .end = end, .quoted = true, .escaped = escaped } };
                    },
                    else => {
                        const start = self.at;
                        var end = self.at;
                        var escaped = false;
                        while (self.at < self.input.len) {
                            const byte = self.input[self.at];
                            if (byte == '\\') {
                                if (self.at + 1 == self.input.len) return error.InvalidTextRepresentation;
                                escaped = true;
                                self.at += 2;
                                end = self.at;
                                continue;
                            }
                            if (byte == ',' or byte == '}') break;
                            if (byte == '{' or byte == '"') return error.InvalidTextRepresentation;
                            self.at += 1;
                            if (!space(byte)) end = self.at;
                        }
                        return .{ .item = .{ .start = start, .end = end, .quoted = false, .escaped = escaped } };
                    },
                }
            }
        };

        /// Element text with escapes removed into `out`; null for an
        /// unquoted NULL.
        fn itemText(input: []const u8, item: Item, out: *V.Text) Error!?[]const u8 {
            const raw = input[item.start..item.end];
            if (!item.quoted and !item.escaped and raw.len == 4 and types.keyword(raw, "null")) return null;
            out.len = 0;
            var index: usize = 0;
            while (index < raw.len) : (index += 1) {
                var c = raw[index];
                if (c == '\\') {
                    index += 1;
                    c = raw[index];
                }
                if (out.len == config.text_bytes) return error.TextCapacity;
                out.bytes[out.len] = c;
                out.len += 1;
            }
            return out.slice();
        }

        fn readInt(input: []const u8, at: *usize) Error!i64 {
            while (at.* < input.len and space(input[at.*])) at.* += 1;
            var negative = false;
            if (at.* < input.len and (input[at.*] == '-' or input[at.*] == '+')) {
                negative = input[at.*] == '-';
                at.* += 1;
            }
            const start = at.*;
            var value: i64 = 0;
            while (at.* < input.len and types.digit(input[at.*])) : (at.* += 1) {
                value = value * 10 + (input[at.*] - '0');
                if (value > 2147483648) return error.InvalidTextRepresentation;
            }
            if (at.* == start) return error.InvalidTextRepresentation;
            while (at.* < input.len and space(input[at.*])) at.* += 1;
            const signed = if (negative) -value else value;
            if (signed < -2147483648 or signed > 2147483647) return error.InvalidTextRepresentation;
            return signed;
        }

        /// The structure of the braces after the decoration: dimensions,
        /// each consistent across sibling sub-arrays, every element at the
        /// same depth and no level mixing elements with sub-arrays.
        fn structure(input: []const u8, start: usize, layout: *array.Shape) Error!void {
            const Kind = enum { none, items, arrays };
            var scanner: Scanner = .{ .input = input, .at = start };
            if ((try scanner.next()) != .open) return error.InvalidTextRepresentation;
            var depth: usize = 1;
            var counts: [array.max_dims]u32 = @splat(0);
            var kinds: [array.max_dims]Kind = @splat(.none);
            var known: [array.max_dims]bool = @splat(false);
            var leaf: usize = 0;
            var expect_value = true;
            var after_open = true;
            while (true) {
                switch (try scanner.next()) {
                    .open => {
                        if (!expect_value or kinds[depth - 1] == .items) return error.InvalidTextRepresentation;
                        if (leaf != 0 and depth >= leaf) return error.InvalidTextRepresentation;
                        if (depth == array.max_dims) return error.ProgramLimitExceeded;
                        kinds[depth - 1] = .arrays;
                        depth += 1;
                        counts[depth - 1] = 0;
                        kinds[depth - 1] = .none;
                        after_open = true;
                    },
                    .item => {
                        if (!expect_value or kinds[depth - 1] == .arrays) return error.InvalidTextRepresentation;
                        if (leaf == 0) leaf = depth else if (depth != leaf) return error.InvalidTextRepresentation;
                        kinds[depth - 1] = .items;
                        counts[depth - 1] += 1;
                        expect_value = false;
                        after_open = false;
                    },
                    .delimiter => {
                        if (expect_value) return error.InvalidTextRepresentation;
                        expect_value = true;
                    },
                    .close => {
                        if (after_open) {
                            // `{}`: only the whole value may be empty.
                            if (depth != 1 or (try scanner.next()) != .end) return error.InvalidTextRepresentation;
                            layout.ndim = 0;
                            return;
                        }
                        if (expect_value) return error.InvalidTextRepresentation;
                        const dim = depth - 1;
                        if (known[dim]) {
                            if (layout.dims[dim] != counts[dim]) return error.InvalidTextRepresentation;
                        } else {
                            known[dim] = true;
                            layout.dims[dim] = counts[dim];
                        }
                        depth -= 1;
                        if (depth == 0) {
                            if ((try scanner.next()) != .end) return error.InvalidTextRepresentation;
                            layout.ndim = leaf;
                            return;
                        }
                        counts[depth - 1] += 1;
                        expect_value = false;
                    },
                    .end => return error.InvalidTextRepresentation,
                }
            }
        }

        /// array_in for arrays of `element` (element typmod `typmod`).
        pub fn parse(element: Type, typmod: i32, input: []const u8, session: *const Io.SessionValues) Error!V.Cell {
            var layout: array.Shape = .{ .element = types.dataTypeOf(element) };
            var at: usize = 0;
            while (at < input.len and space(input[at])) at += 1;
            var explicit: usize = 0;
            var lbounds: [array.max_dims]i32 = @splat(1);
            var uppers: [array.max_dims]i64 = @splat(0);
            if (at < input.len and input[at] == '[') {
                while (at < input.len and input[at] == '[') {
                    if (explicit == array.max_dims) return error.ProgramLimitExceeded;
                    at += 1;
                    const first = try readInt(input, &at);
                    var lower: i64 = 1;
                    var upper = first;
                    if (at < input.len and input[at] == ':') {
                        at += 1;
                        lower = first;
                        upper = try readInt(input, &at);
                    }
                    if (at == input.len or input[at] != ']') return error.InvalidTextRepresentation;
                    at += 1;
                    if (upper < lower) return error.ArraySubscriptError;
                    lbounds[explicit] = @intCast(lower);
                    uppers[explicit] = upper;
                    explicit += 1;
                    while (at < input.len and space(input[at])) at += 1;
                }
                if (at == input.len or input[at] != '=') return error.InvalidTextRepresentation;
                at += 1;
                while (at < input.len and space(input[at])) at += 1;
            }
            if (at == input.len or input[at] != '{') return error.InvalidTextRepresentation;
            try structure(input, at, &layout);
            if (explicit != 0) {
                if (explicit != layout.ndim) return error.InvalidTextRepresentation;
                for (0..explicit) |dim| {
                    if (uppers[dim] - lbounds[dim] + 1 != layout.dims[dim]) return error.InvalidTextRepresentation;
                    layout.lbounds[dim] = lbounds[dim];
                }
            }
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &layout);
            var scanner: Scanner = .{ .input = input, .at = at };
            var text: V.Text = .{};
            while (true) {
                const token = try scanner.next();
                switch (token) {
                    .item => |item| {
                        try session.checkpoint();
                        const cell: V.Cell = if (try itemText(input, item, &text)) |bytes| try Io.parse(element, typmod, bytes, session) else .null_value;
                        try writer.append(&cell);
                    },
                    .end => break,
                    else => {},
                }
            }
            return .{ .array = result };
        }

        /// array_coerce: every element cast from `from` to `to` (typmod applies
        /// to the elements), keeping the shape.
        pub fn cast(bytes: []const u8, from: Type, to: Type, typmod: i32, session: *const Io.SessionValues) Error!V.Cell {
            var layout = A.shape(bytes);
            layout.element = types.dataTypeOf(to);
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &layout);
            var reader = A.Reader.init(bytes);
            var cell: V.Cell = undefined;
            while (reader.next(&cell)) {
                try session.checkpoint();
                const converted = try Io.cast(cell, from, to, typmod, session);
                try writer.append(&converted);
            }
            return .{ .array = result };
        }

        /// The element typmod coercion of an array value (`explicit`: the
        /// truncating explicit-cast kind).
        pub fn applyTypmod(bytes: []const u8, element: Type, typmod: i32, explicit: bool) Error!V.Cell {
            var layout = A.shape(bytes);
            var result: V.Text = .{};
            var writer = try A.Writer.begin(&result, &layout);
            var reader = A.Reader.init(bytes);
            var cell: V.Cell = undefined;
            while (reader.next(&cell)) {
                const coerced = if (explicit) try Io.applyTypmodExplicit(cell, element, typmod) else try Io.applyTypmod(cell, element, typmod);
                try writer.append(&coerced);
            }
            return .{ .array = result };
        }
    };
}
