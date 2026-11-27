//! Multirange types (Layer 0), after multirangetypes.c (B11 wave 4,
//! types-ext lane): int4multirange, int8multirange, nummultirange,
//! datemultirange, tsmultirange and tstzmultirange.
//!
//! A multirange lives inline in one cell's byte budget: [0] its range
//! type's DataType ordinal, [1..3] the u16 range count, then every range
//! as a u16 length and its range.sig encoding. Every stored multirange is
//! canonical: its ranges are non-empty, sorted, and neither overlap nor
//! touch, so equality is structural and hashing follows it. Ordering is
//! multirange_cmp: range by range (range_cmp_bounds of the lower, then
//! upper bounds), then fewer ranges first; the empty multirange is least.
//! A multirange that does not fit the cell is TextCapacity (54000).
const types = @import("types.sig");
const Error = types.Error;
const DataType = types.DataType;
const Type = types.Type;

/// The multirange type over a range type, and back.
pub fn ofRange(range: DataType) ?DataType {
    return switch (range) {
        .int4range => .int4multirange,
        .int8range => .int8multirange,
        .numrange => .nummultirange,
        .daterange => .datemultirange,
        .tsrange => .tsmultirange,
        .tstzrange => .tstzmultirange,
        else => null,
    };
}

pub fn rangeOf(multirange: DataType) ?DataType {
    return switch (multirange) {
        .int4multirange => .int4range,
        .int8multirange => .int8range,
        .nummultirange => .numrange,
        .datemultirange => .daterange,
        .tsmultirange => .tsrange,
        .tstzmultirange => .tstzrange,
        else => null,
    };
}

pub fn isMultirange(ty: Type) bool {
    return rangeOf(types.dataTypeOf(ty)) != null and types.elementType(ty) == null;
}

pub fn Multiranges(comptime V: type) type {
    const R = V.Ranges;
    return struct {
        pub const header: usize = 3;

        pub fn rangeType(bytes: []const u8) DataType {
            return @enumFromInt(bytes[0]);
        }

        pub fn count(bytes: []const u8) usize {
            return @as(usize, bytes[1]) | @as(usize, bytes[2]) << 8;
        }

        /// The ranges in order.
        pub const Iterator = struct {
            bytes: []const u8,
            at: usize = header,
            index: usize = 0,

            pub fn next(self: *Iterator) ?R.Range {
                const raw = self.nextBytes() orelse return null;
                return R.decode(raw);
            }

            pub fn nextBytes(self: *Iterator) ?[]const u8 {
                if (self.index == count(self.bytes)) return null;
                const len = @as(usize, self.bytes[self.at]) | @as(usize, self.bytes[self.at + 1]) << 8;
                const raw = self.bytes[self.at + 2 ..][0..len];
                self.at += 2 + len;
                self.index += 1;
                return raw;
            }
        };

        pub fn iterate(bytes: []const u8) Iterator {
            return .{ .bytes = bytes };
        }

        pub fn first(bytes: []const u8) ?R.Range {
            var it = iterate(bytes);
            return it.next();
        }

        pub fn last(bytes: []const u8) ?R.Range {
            var it = iterate(bytes);
            var found: ?R.Range = null;
            while (it.next()) |range| found = range;
            return found;
        }

        /// The empty multirange of `range_type`.
        pub fn empty(range_type: DataType, out: *V.Text) void {
            out.len = header;
            out.bytes[0] = @intFromEnum(range_type);
            out.bytes[1] = 0;
            out.bytes[2] = 0;
        }

        fn appendRange(out: *V.Text, range: *const R.Range) Error!void {
            var encoded: V.Text = .{};
            try R.encode(range, &encoded);
            if (encoded.len > 0xffff or 2 + encoded.len > out.bytes.len - out.len) return error.TextCapacity;
            const total = count(out.bytes[0..out.len]) + 1;
            if (total > 0xffff) return error.TextCapacity;
            out.bytes[out.len] = @truncate(encoded.len);
            out.bytes[out.len + 1] = @truncate(encoded.len >> 8);
            @memcpy(out.bytes[out.len + 2 ..][0..encoded.len], encoded.bytes[0..encoded.len]);
            out.len += 2 + encoded.len;
            out.bytes[1] = @truncate(total);
            out.bytes[2] = @truncate(total >> 8);
        }

        /// Whether `a` and `b` overlap or touch (they merge into one range).
        fn mergeable(a: *const R.Range, b: *const R.Range) Error!bool {
            return R.overlaps(a, b) or try R.adjacent(a, b);
        }

        /// Adds a range to a canonical multirange (in place, through `scratch`).
        pub fn add(set: *V.Text, range_in: *const R.Range, scratch: *V.Text) Error!void {
            if (range_in.empty) return;
            var range = range_in.*;
            empty(rangeType(set.bytes[0..set.len]), scratch);
            var it = iterate(set.bytes[0..set.len]);
            var placed = false;
            while (it.next()) |existing| {
                if (!placed and try mergeable(&existing, &range)) {
                    range = try R.merge(&existing, &range);
                    continue;
                }
                if (!placed and R.compareRanges(&range, &existing) < 0) {
                    try appendRange(scratch, &range);
                    placed = true;
                }
                try appendRange(scratch, &existing);
            }
            if (!placed) try appendRange(scratch, &range);
            set.* = scratch.*;
        }

        pub fn compare(a: []const u8, b: []const u8) i8 {
            if (a[0] != b[0]) return if (a[0] < b[0]) -1 else 1;
            var x = iterate(a);
            var y = iterate(b);
            while (true) {
                const p = x.next();
                const q = y.next();
                if (p == null and q == null) return 0;
                if (p == null) return -1;
                if (q == null) return 1;
                var order = R.compareBounds(&p.?.lower, &q.?.lower);
                if (order == 0) order = R.compareBounds(&p.?.upper, &q.?.upper);
                if (order != 0) return order;
            }
        }

        pub fn hash(bytes: []const u8) u64 {
            var code: u64 = 0x9e3779b97f4a7c15 ^ @as(u64, bytes[0]);
            var it = iterate(bytes);
            while (it.nextBytes()) |raw| {
                code = (code ^ R.hash(raw)) *% 0xff51afd7ed558ccd;
                code ^= code >> 33;
            }
            return code;
        }

        /// The smallest range covering every range (empty for {}).
        pub fn span(bytes: []const u8) R.Range {
            const subtype = types.dataTypeOf(types.rangeSubtype(types.typeOfData(rangeType(bytes))).?);
            const low = first(bytes) orelse return .{ .subtype = subtype, .empty = true };
            const high = last(bytes).?;
            return .{ .subtype = subtype, .lower = low.lower, .upper = high.upper };
        }

        pub fn containsElement(bytes: []const u8, value: *const V.Cell) bool {
            var it = iterate(bytes);
            while (it.next()) |range| if (R.containsElement(&range, value)) return true;
            return false;
        }

        pub fn containsRange(bytes: []const u8, range: *const R.Range) bool {
            if (range.empty) return true;
            var it = iterate(bytes);
            while (it.next()) |component| if (R.contains(&component, range)) return true;
            return false;
        }

        pub fn containsMultirange(a: []const u8, b: []const u8) bool {
            var it = iterate(b);
            while (it.next()) |range| if (!containsRange(a, &range)) return false;
            return true;
        }

        pub fn overlapsRange(bytes: []const u8, range: *const R.Range) bool {
            var it = iterate(bytes);
            while (it.next()) |component| if (R.overlaps(&component, range)) return true;
            return false;
        }

        pub fn overlapsMultirange(a: []const u8, b: []const u8) bool {
            var it = iterate(b);
            while (it.next()) |range| if (overlapsRange(a, &range)) return true;
            return false;
        }

        /// a + b.
        pub fn unite(a: []const u8, b: []const u8, out: *V.Text, scratch: *V.Text) Error!void {
            if (a.len > out.bytes.len) return error.TextCapacity;
            @memcpy(out.bytes[0..a.len], a);
            out.len = a.len;
            var it = iterate(b);
            while (it.next()) |range| try add(out, &range, scratch);
        }

        /// a * b.
        pub fn intersect(a: []const u8, b: []const u8, out: *V.Text, scratch: *V.Text) Error!void {
            empty(rangeType(a), out);
            var x = iterate(a);
            while (x.next()) |p| {
                var y = iterate(b);
                while (y.next()) |q| {
                    if (!R.overlaps(&p, &q)) continue;
                    const piece = try R.intersect(&p, &q);
                    try add(out, &piece, scratch);
                }
            }
        }

        /// a - b: every range of a without the parts b covers.
        pub fn subtract(a: []const u8, b: []const u8, out: *V.Text, scratch: *V.Text) Error!void {
            empty(rangeType(a), out);
            var x = iterate(a);
            while (x.next()) |p| {
                var rest = p;
                var y = iterate(b);
                while (y.next()) |q| {
                    if (rest.empty) break;
                    if (!R.overlaps(&rest, &q)) continue;
                    // The part of `rest` before q, then the part after it.
                    if (R.compareBounds(&rest.lower, &q.lower) < 0) {
                        var upper = q.lower;
                        upper.lower = false;
                        upper.inclusive = !q.lower.inclusive;
                        const before = try R.make(rest.subtype, rest.lower, upper, false);
                        try add(out, &before, scratch);
                    }
                    if (R.compareBounds(&rest.upper, &q.upper) > 0) {
                        var lower = q.upper;
                        lower.lower = true;
                        lower.inclusive = !q.upper.inclusive;
                        rest = try R.make(rest.subtype, lower, rest.upper, false);
                    } else rest = .{ .subtype = rest.subtype, .empty = true };
                }
                if (!rest.empty) try add(out, &rest, scratch);
            }
        }
    };
}

/// multirange_in / multirange_out over a RangeText instance (`Io`).
pub fn MultirangeText(comptime config: types.Config, comptime Io: type) type {
    const V = types.Values(config);
    const M = Multiranges(V);
    return struct {
        fn space(byte: u8) bool {
            return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
        }

        /// `{` [range {`,` range}] `}` with optional whitespace; each range
        /// is range_in text (quotes and backslashes respected).
        pub fn parse(multirange_type: Type, input: []const u8, session: *const Io.SessionValues) Error!V.Cell {
            const range_data = rangeOf(types.dataTypeOf(multirange_type)) orelse return error.UndefinedFunction;
            const range_type = types.typeOfData(range_data);
            var result: V.Text = .{};
            var scratch: V.Text = .{};
            M.empty(range_data, &result);
            var at: usize = 0;
            while (at < input.len and space(input[at])) at += 1;
            if (at == input.len or input[at] != '{') return error.InvalidTextRepresentation;
            at += 1;
            while (at < input.len and space(input[at])) at += 1;
            if (at < input.len and input[at] == '}') {
                at += 1;
            } else while (true) {
                while (at < input.len and space(input[at])) at += 1;
                const start = at;
                if (at < input.len and (input[at] == '[' or input[at] == '(')) {
                    var quoted = false;
                    at += 1;
                    while (true) {
                        if (at == input.len) return error.InvalidTextRepresentation;
                        const c = input[at];
                        at += 1;
                        if (c == '\\') {
                            if (at == input.len) return error.InvalidTextRepresentation;
                            at += 1;
                        } else if (c == '"') {
                            quoted = !quoted;
                        } else if (!quoted and (c == ']' or c == ')')) break;
                    }
                } else {
                    while (at < input.len and input[at] != ',' and input[at] != '}' and !space(input[at])) at += 1;
                }
                const cell = try Io.RangeText.parse(range_type, input[start..at], session);
                const range = V.Ranges.decode(cell.range.slice());
                try M.add(&result, &range, &scratch);
                while (at < input.len and space(input[at])) at += 1;
                if (at == input.len) return error.InvalidTextRepresentation;
                if (input[at] == '}') {
                    at += 1;
                    break;
                }
                if (input[at] != ',') return error.InvalidTextRepresentation;
                at += 1;
            }
            while (at < input.len and space(input[at])) at += 1;
            if (at != input.len) return error.InvalidTextRepresentation;
            return .{ .multirange = result };
        }

        pub fn format(bytes: []const u8, session: *const Io.SessionValues, buffer: []u8) Error![]const u8 {
            var at: usize = 0;
            if (buffer.len < 2) return error.TextCapacity;
            buffer[0] = '{';
            at = 1;
            var it = M.iterate(bytes);
            var index: usize = 0;
            while (it.nextBytes()) |raw| : (index += 1) {
                if (index != 0) {
                    if (at == buffer.len) return error.TextCapacity;
                    buffer[at] = ',';
                    at += 1;
                }
                const text = try Io.RangeText.format(raw, session, buffer[at..]);
                at += text.len;
            }
            if (at == buffer.len) return error.TextCapacity;
            buffer[at] = '}';
            return buffer[0 .. at + 1];
        }
    };
}
