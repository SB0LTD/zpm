//! SQL values as JSON text (Layer 0, B11 json-agg lane), after
//! PostgreSQL's json.c datum_to_json_internal / jsonb.c
//! datum_to_jsonb_internal: the to_json/to_jsonb conversion json[b]_agg,
//! json[b]_object_agg and the JSON constructors use.
//!
//! Categories (json_categorize_type): booleans as true/false; int2/int4/
//! int8/float4/float8/numeric as their output text when it is a JSON number
//! (NaN and the infinities become strings); date/timestamp/timestamptz as
//! XSD strings (JsonEncodeDateTime: `T` between date and time, `+HH:MM`
//! offsets, `infinity`); json verbatim and jsonb as its text; arrays as
//! nested JSON arrays (`[1,2]`, no spaces, as array_to_json); every other
//! type as its output text in a JSON string. Object keys (`key_scalar`)
//! are always strings; an array, json or jsonb key is 22023.
//!
//! Output goes to a caller-owned bounded buffer (TextCapacity, 54000,
//! beyond it). Nothing recurses on the data except arrays, whose nesting
//! is at most array.max_dims (6) levels.
const types = @import("types.sig");
const ast = @import("ast.sig");
const value_module = @import("value.sig");
const array_module = @import("array.sig");
const Error = types.Error;
const Type = types.Type;

pub const Category = enum { boolean, number, date, timestamp, timestamptz, json, jsonb, array, other };

pub fn category(ty: Type) Category {
    if (types.isArray(ty)) return .array;
    return switch (ty) {
        .boolean => .boolean,
        .int2, .int4, .int8, .float4, .float8, .numeric => .number,
        .date => .date,
        .timestamp => .timestamp,
        .timestamptz => .timestamptz,
        .json => .json,
        .jsonb => .jsonb,
        else => .other,
    };
}

/// A bounded output buffer.
pub const Out = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn append(self: *Out, value: []const u8) Error!void {
        if (value.len > self.bytes.len - self.len) return error.TextCapacity;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
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

/// escape_json: a JSON string literal of `value`.
pub fn escaped(out: *Out, value: []const u8) Error!void {
    try out.byte('"');
    for (value) |c| {
        switch (c) {
            '\x08' => try out.append("\\b"),
            '\x0c' => try out.append("\\f"),
            '\n' => try out.append("\\n"),
            '\r' => try out.append("\\r"),
            '\t' => try out.append("\\t"),
            '"' => try out.append("\\\""),
            '\\' => try out.append("\\\\"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                try out.append(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
            } else try out.byte(c),
        }
    }
    try out.byte('"');
}

/// JsonEncodeDateTime from the ISO output of a date/timestamp[tz]: `T`
/// between date and time, and a whole-hour offset as +HH:MM.
pub fn xsdDateTime(out: *Out, iso: []const u8) Error!void {
    try out.byte('"');
    var at: usize = 0;
    var seen_time = false;
    while (at < iso.len) : (at += 1) {
        const c = iso[at];
        if (!seen_time and c == ' ' and at + 1 < iso.len and iso[at + 1] >= '0' and iso[at + 1] <= '9') {
            try out.byte('T');
            seen_time = true;
            continue;
        }
        if (seen_time and (c == '+' or c == '-')) {
            // The offset runs to the end or to " BC".
            var end = at + 1;
            while (end < iso.len and iso[end] != ' ') end += 1;
            try out.append(iso[at..end]);
            if (end - at == 3) try out.append(":00");
            at = end - 1;
            continue;
        }
        try out.byte(c);
    }
    try out.byte('"');
}

pub fn JsonBuild(comptime config: types.Config) type {
    const V = types.Values(config);
    const Io = value_module.Io(config);
    const J = Io.Documents;
    const A = V.Arrays;
    return struct {
        pub const Session = value_module.Session;

        fn validNumber(text: []const u8) bool {
            if (text.len == 0) return false;
            const first = if (text[0] == '-') @as(usize, 1) else 0;
            return first < text.len and text[first] >= '0' and text[first] <= '9';
        }

        /// to_json (`jsonb` false) / to_jsonb text of a non-NULL value of
        /// `ty`; `key` asks for an object key (always a string).
        pub fn append(out: *Out, cell: *const V.Cell, ty: Type, key: bool, jsonb: bool, session: *const Session) Error!void {
            if (cell.* == .null_value) return out.append("null");
            const kind = category(ty);
            if (key) switch (kind) {
                .array, .json => return error.InvalidParameterValue,
                .jsonb => if (jsonb) return error.InvalidParameterValue,
                else => {},
            };
            switch (kind) {
                .boolean => {
                    if (key) try out.byte('"');
                    try out.append(if (cell.boolean) "true" else "false");
                    if (key) try out.byte('"');
                },
                .number => {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    const text = try Io.format(cell, false, session, &buffer);
                    if (!key and validNumber(text)) return out.append(text);
                    try out.byte('"');
                    try out.append(text);
                    try out.byte('"');
                },
                .date, .timestamp, .timestamptz => {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    try xsdDateTime(out, try Io.format(cell, false, session, &buffer));
                },
                .json => try out.append(cell.text.slice()),
                .jsonb => {
                    var text: J.Text = .{ .bytes = out.bytes[out.len..] };
                    J.render(cell.jsonb.slice(), 0, &text) catch return error.TextCapacity;
                    out.len += text.len;
                },
                .array => try appendArray(out, cell.array.slice(), types.elementType(ty) orelse .text, jsonb, session),
                .other => {
                    var buffer: [Io.format_bytes]u8 = undefined;
                    try escaped(out, try Io.format(cell, false, session, &buffer));
                },
            }
        }

        /// array_to_json: one bracket level per dimension, elements by
        /// their own category, `,` without spaces.
        fn appendArray(out: *Out, bytes: []const u8, element: Type, jsonb: bool, session: *const Session) Error!void {
            const layout = A.shape(bytes);
            if (layout.ndim == 0) return out.append("[]");
            var reader = A.Reader.init(bytes);
            var counters: [array_module.max_dims]u32 = @splat(0);
            var cell: V.Cell = undefined;
            const total = layout.count();
            for (0..total) |index| {
                if (session.control) |control| try control.checkpoint();
                // The trailing dimensions this element starts close the
                // previous ones: `],[` once per such dimension.
                var starts: usize = layout.ndim;
                if (index != 0) {
                    starts = 0;
                    var dim = layout.ndim;
                    while (dim > 0) {
                        dim -= 1;
                        if (counters[dim] != 0) break;
                        starts += 1;
                    }
                    for (0..starts) |_| try out.byte(']');
                    try out.byte(',');
                }
                for (0..starts) |_| try out.byte('[');
                _ = reader.next(&cell);
                try append(out, &cell, element, false, jsonb, session);
                var dim = layout.ndim;
                while (dim > 0) {
                    dim -= 1;
                    counters[dim] += 1;
                    if (counters[dim] < layout.dims[dim]) break;
                    counters[dim] = 0;
                }
            }
            for (0..layout.ndim) |_| try out.byte(']');
        }

        /// The jsonb cell of the JSON text in `out`.
        pub fn jsonbOf(out: *const Out, session: *const Session) Error!V.Cell {
            return Io.jsonbCellControlled(out.slice(), session.control);
        }

        /// A json (text) cell of `out`.
        pub fn jsonOf(out: *const Out) Error!V.Cell {
            if (out.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = out.len };
            @memcpy(text.bytes[0..out.len], out.slice());
            return .{ .text = text };
        }

        /// Largest JSON text a builder may need before conversion.
        pub const buffer_bytes: usize = Io.format_bytes;
    };
}
