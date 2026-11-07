//! Range text input and output and constructors (Layer 0), after
//! rangetypes.c range_parse/range_bound_escape/range_constructor3.
//!
//! range_in: optional whitespace, then `empty` (any case) or a bracket or
//! parenthesis, the lower bound, a comma, the upper bound and the closing
//! bracket or parenthesis. An empty bound is infinite; a bound may be
//! double-quoted ("" inside quotes is a quote) and a backslash escapes the
//! next byte. Malformed text is 22P02. The bounds go through the subtype's
//! input function, then make_range validates and canonicalizes.
//! range_out quotes a bound that is empty or contains `"`, `\`, `(`, `)`,
//! `[`, `]`, `,` or whitespace, doubling `"` and `\` inside the quotes.
const types = @import("types.sig");
const range = @import("range.sig");
const Error = types.Error;
const Type = types.Type;

pub fn RangeText(comptime config: types.Config, comptime Io: type) type {
    const V = types.Values(config);
    const R = V.Ranges;
    return struct {
        fn space(byte: u8) bool {
            return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
        }

        fn subtypeOf(range_type: Type) Error!Type {
            return types.rangeSubtype(range_type) orelse error.UndefinedFunction;
        }

        /// range_parse_bound: the bound text into `out`; null when infinite.
        fn bound(input: []const u8, at: *usize, out: *V.Text) Error!?[]const u8 {
            if (at.* == input.len) return error.InvalidTextRepresentation;
            const first = input[at.*];
            if (first == ',' or first == ')' or first == ']') return null;
            out.len = 0;
            var quoted = false;
            while (true) {
                if (at.* == input.len) return error.InvalidTextRepresentation;
                const c = input[at.*];
                if (!quoted and (c == ',' or c == ')' or c == ']')) break;
                at.* += 1;
                var kept: ?u8 = c;
                if (c == '\\') {
                    if (at.* == input.len) return error.InvalidTextRepresentation;
                    kept = input[at.*];
                    at.* += 1;
                } else if (c == '"') {
                    kept = null;
                    if (!quoted) {
                        quoted = true;
                    } else if (at.* < input.len and input[at.*] == '"') {
                        // A doubled quote inside quotes.
                        kept = '"';
                        at.* += 1;
                    } else quoted = false;
                }
                if (kept) |byte| {
                    if (out.len == config.text_bytes) return error.TextCapacity;
                    out.bytes[out.len] = byte;
                    out.len += 1;
                }
            }
            return out.slice();
        }

        /// range_in for `range_type`.
        pub fn parse(range_type: Type, input: []const u8, session: *const Io.SessionValues) Error!V.Cell {
            const subtype = try subtypeOf(range_type);
            const data_subtype = types.dataTypeOf(subtype);
            var at: usize = 0;
            while (at < input.len and space(input[at])) at += 1;
            if (input.len - at >= 5 and types.keyword(input[at..][0..5], "empty")) {
                at += 5;
                while (at < input.len and space(input[at])) at += 1;
                if (at != input.len) return error.InvalidTextRepresentation;
                return encoded(&.{ .subtype = data_subtype, .empty = true });
            }
            if (at == input.len or (input[at] != '[' and input[at] != '(')) return error.InvalidTextRepresentation;
            var lower: R.Bound = .{ .lower = true, .inclusive = input[at] == '[' };
            at += 1;
            var text: V.Text = .{};
            if (try bound(input, &at, &text)) |bytes| {
                lower.value = try Io.parse(subtype, -1, bytes, session);
                lower.infinite = false;
            }
            if (at == input.len or input[at] != ',') return error.InvalidTextRepresentation;
            at += 1;
            var upper: R.Bound = .{ .lower = false };
            if (try bound(input, &at, &text)) |bytes| {
                upper.value = try Io.parse(subtype, -1, bytes, session);
                upper.infinite = false;
            }
            if (at == input.len or (input[at] != ']' and input[at] != ')')) return error.InvalidTextRepresentation;
            upper.inclusive = input[at] == ']';
            at += 1;
            while (at < input.len and space(input[at])) at += 1;
            if (at != input.len) return error.InvalidTextRepresentation;
            const made = try R.make(data_subtype, lower, upper, false);
            return encoded(&made);
        }

        pub fn encoded(value: *const R.Range) Error!V.Cell {
            var out: V.Text = .{};
            try R.encode(value, &out);
            return .{ .range = out };
        }

        /// range_constructor2/3: NULL bounds are infinite; `flags` is one of
        /// `[)`, `[]`, `(]`, `()` (42601 otherwise).
        pub fn construct(range_type: Type, lower_value: *const V.Cell, upper_value: *const V.Cell, flags: []const u8) Error!V.Cell {
            const subtype = types.dataTypeOf(try subtypeOf(range_type));
            if (flags.len != 2 or (flags[0] != '[' and flags[0] != '(') or (flags[1] != ']' and flags[1] != ')')) return error.Syntax;
            var lower: R.Bound = .{ .lower = true, .inclusive = flags[0] == '[' };
            var upper: R.Bound = .{ .lower = false, .inclusive = flags[1] == ']' };
            if (lower_value.* != .null_value) {
                lower.value = lower_value.*;
                lower.infinite = false;
            }
            if (upper_value.* != .null_value) {
                upper.value = upper_value.*;
                upper.infinite = false;
            }
            const made = try R.make(subtype, lower, upper, false);
            return encoded(&made);
        }

        const Out = struct {
            buffer: []u8,
            len: usize = 0,
            fn byte(self: *Out, value: u8) Error!void {
                if (self.len == self.buffer.len) return error.TextCapacity;
                self.buffer[self.len] = value;
                self.len += 1;
            }
        };

        fn escaped(out: *Out, text: []const u8) Error!void {
            var quote = text.len == 0;
            for (text) |c| {
                if (c == '"' or c == '\\' or c == '(' or c == ')' or c == '[' or c == ']' or c == ',' or space(c)) quote = true;
            }
            if (quote) try out.byte('"');
            for (text) |c| {
                if (c == '"' or c == '\\') try out.byte(c);
                try out.byte(c);
            }
            if (quote) try out.byte('"');
        }

        /// range_out into `buffer`.
        pub fn format(bytes: []const u8, session: *const Io.SessionValues, buffer: []u8) Error![]const u8 {
            const value = R.decode(bytes);
            var out: Out = .{ .buffer = buffer };
            if (value.empty) {
                for ("empty") |c| try out.byte(c);
                return buffer[0..out.len];
            }
            var element: [Io.format_bytes]u8 = undefined;
            try out.byte(if (value.lower.inclusive) '[' else '(');
            if (!value.lower.infinite) try escaped(&out, try Io.format(&value.lower.value, false, session, &element));
            try out.byte(',');
            if (!value.upper.infinite) try escaped(&out, try Io.format(&value.upper.value, false, session, &element));
            try out.byte(if (value.upper.inclusive) ']' else ')');
            return buffer[0..out.len];
        }
    };
}
