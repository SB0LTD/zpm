//! PostgreSQL arrays (Layer 0), after arrayfuncs.c.
//!
//! An array value lives inline in one cell's caller-owned byte budget
//! (Config.text_bytes); anything larger is TextCapacity (54000). Layout:
//!   [0] element DataType ordinal, [1] ndim (0..6), [2] flags (bit 0: some
//!   element is NULL), [3] 0, then ndim x {dim u32, lbound i32} (native
//!   byte order), then every element in row-major order: 0 for NULL, or 1
//!   and the element payload (fixed width for scalar types, a length prefix
//!   for text-like values and bit strings).
//! A zero-dimensional array is the empty array '{}'. Nested arrays are
//! multi-dimensional arrays of the same element type; there are no arrays
//! of arrays. The element payload is an in-memory encoding: durable change
//! records and the wire use their own portable forms.
//!
//! Ordering is array_cmp: element by element (two NULLs are equal and NULL
//! sorts after every value), then fewer elements first, then fewer
//! dimensions, then smaller dimensions and lower bounds. Equality (array_eq)
//! is ordering equality, and hashing is consistent with it.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const Error = types.Error;
const DataType = types.DataType;

/// MAXDIM.
pub const max_dims: usize = 6;
const header_bytes: usize = 4;

pub const Shape = struct {
    element: DataType = .integer,
    ndim: usize = 0,
    dims: [max_dims]u32 = @splat(0),
    lbounds: [max_dims]i32 = @splat(1),
    has_nulls: bool = false,

    /// Number of elements (0 for the empty array).
    pub fn count(self: *const Shape) usize {
        if (self.ndim == 0) return 0;
        var total: usize = 1;
        for (self.dims[0..self.ndim]) |dim| total *= dim;
        return total;
    }

    /// The checked element count of a shape being built: 54000 when it
    /// cannot be represented (ArrayGetNItems), 22P02 for a negative upper
    /// bound below the lower bound.
    pub fn checkedCount(self: *const Shape) Error!usize {
        if (self.ndim == 0) return 0;
        var total: u64 = 1;
        for (self.dims[0..self.ndim]) |dim| {
            const product = @mulWithOverflow(total, @as(u64, dim));
            if (product[1] != 0 or product[0] > 0x7ffffff) return error.ProgramLimitExceeded;
            total = product[0];
        }
        for (self.dims[0..self.ndim], self.lbounds[0..self.ndim]) |dim, lbound| {
            // ArrayCheckBounds: lbound + dim - 1 must not overflow int4.
            if (@as(i64, lbound) + @as(i64, dim) - 1 > 2147483647) return error.ProgramLimitExceeded;
        }
        return @intCast(total);
    }

    pub fn upper(self: *const Shape, dim: usize) i64 {
        return @as(i64, self.lbounds[dim]) + @as(i64, self.dims[dim]) - 1;
    }
};

/// The subscript layout of an array_subscript call (its node `integer`):
/// the count in bits 32.., and three bits per subscript at 3 * index:
/// `slice` (written with a colon), `lower` and `upper` present. Its
/// arguments are the base and then, per subscript, the lower expression
/// (the index of a non-slice subscript) and the upper expression, each only
/// when present.
pub const Subscripts = struct {
    count: usize = 0,
    flags: [max_dims]u3 = @splat(0),

    pub const slice_flag: u3 = 1;
    pub const lower_flag: u3 = 2;
    pub const upper_flag: u3 = 4;

    pub fn encode(self: *const Subscripts) i64 {
        var word: i64 = @as(i64, @intCast(self.count)) << 32;
        for (self.flags[0..self.count], 0..) |flag, index| word |= @as(i64, flag) << @intCast(index * 3);
        return word;
    }

    pub fn decode(word: i64) Subscripts {
        var out: Subscripts = .{ .count = @intCast((word >> 32) & 7) };
        if (out.count > max_dims) out.count = max_dims;
        for (0..out.count) |index| out.flags[index] = @truncate(@as(u64, @bitCast(word)) >> @intCast(index * 3));
        return out;
    }

    /// Any subscript written as a slice makes the whole access a slice.
    pub fn slice(self: *const Subscripts) bool {
        for (self.flags[0..self.count]) |flag| if (flag & slice_flag != 0) return true;
        return false;
    }
};

fn Unsigned(comptime T: type) type {
    return switch (@sizeOf(T)) {
        2 => u16,
        4 => u32,
        8 => u64,
        else => @compileError("unsupported array integer"),
    };
}

pub fn Arrays(comptime V: type) type {
    return struct {
        const Cell = V.Cell;
        const Text = V.Text;
        pub const capacity: usize = @as(Text, .{}).bytes.len;

        pub fn shape(bytes: []const u8) Shape {
            var out: Shape = .{ .element = @enumFromInt(bytes[0]), .ndim = bytes[1], .has_nulls = bytes[2] & 1 != 0 };
            var at: usize = header_bytes;
            for (0..out.ndim) |dim| {
                out.dims[dim] = getInt(u32, bytes, &at);
                out.lbounds[dim] = getInt(i32, bytes, &at);
            }
            return out;
        }

        pub fn elementType(bytes: []const u8) DataType {
            return @enumFromInt(bytes[0]);
        }

        fn bodyStart(bytes: []const u8) usize {
            return header_bytes + @as(usize, bytes[1]) * 8;
        }

        fn put(out: *Text, bytes: []const u8) Error!void {
            if (bytes.len > capacity - out.len) return error.TextCapacity;
            @memcpy(out.bytes[out.len..][0..bytes.len], bytes);
            out.len += bytes.len;
        }

        /// Little-endian integer bytes by shifts (no array bit casts: the
        /// native SB0 compiler rejects them).
        fn putInt(out: *Text, comptime T: type, value: T) Error!void {
            const Bits = Unsigned(T);
            const bits: Bits = @bitCast(value);
            var raw: [@sizeOf(T)]u8 = undefined;
            for (0..@sizeOf(T)) |index| raw[index] = @truncate(bits >> @intCast(index * 8));
            try put(out, &raw);
        }

        fn getInt(comptime T: type, bytes: []const u8, at: *usize) T {
            const Bits = Unsigned(T);
            var bits: Bits = 0;
            for (0..@sizeOf(T)) |index| bits |= @as(Bits, bytes[at.* + index]) << @intCast(index * 8);
            at.* += @sizeOf(T);
            return @bitCast(bits);
        }

        /// Builds an array of `shape` into `out`; elements follow with
        /// append() in row-major order.
        pub const Writer = struct {
            out: *Text,
            element: DataType,
            expected: usize,
            written: usize = 0,

            pub fn begin(out: *Text, layout: *const Shape) Error!Writer {
                const total = try layout.checkedCount();
                out.len = 0;
                try put(out, &.{ @intFromEnum(layout.element), @intCast(layout.ndim), 0, 0 });
                for (0..layout.ndim) |dim| {
                    try putInt(out, u32, layout.dims[dim]);
                    try putInt(out, i32, layout.lbounds[dim]);
                }
                return .{ .out = out, .element = layout.element, .expected = total };
            }

            pub fn append(self: *Writer, cell: *const Cell) Error!void {
                if (self.written == self.expected) return error.InvalidChangeRecord;
                self.written += 1;
                if (cell.* == .null_value) {
                    self.out.bytes[2] |= 1;
                    return put(self.out, &.{0});
                }
                if (@as(V.CellTag, cell.*) != V.cellTag(self.element)) return error.TypeMismatch;
                try put(self.out, &.{1});
                try encode(self.out, self.element, cell);
            }

            /// Every element of the shape was appended.
            pub fn complete(self: *const Writer) bool {
                return self.written == self.expected;
            }
        };

        /// Element payloads for other in-cell layouts (range bounds).
        pub fn encodeElement(out: *Text, element: DataType, cell: *const Cell) Error!void {
            return encode(out, element, cell);
        }

        pub fn decodeElement(bytes: []const u8, at: *usize, element: DataType) Cell {
            return decode(bytes, at, element);
        }

        pub fn putBytes(out: *Text, bytes: []const u8) Error!void {
            return put(out, bytes);
        }

        fn putText(out: *Text, bytes: []const u8) Error!void {
            if (bytes.len > 0xffff) return error.TextCapacity;
            try putInt(out, u16, @intCast(bytes.len));
            try put(out, bytes);
        }

        fn encode(out: *Text, element: DataType, cell: *const Cell) Error!void {
            switch (cell.*) {
                .null_value => unreachable,
                .integer => |value| switch (element) {
                    .smallint => {
                        if (value < -32768 or value > 32767) return error.NumericValueOutOfRange;
                        try putInt(out, i16, @intCast(value));
                    },
                    .integer32 => {
                        if (value < -2147483648 or value > 2147483647) return error.IntegerOverflow;
                        try putInt(out, i32, @intCast(value));
                    },
                    .oid => {
                        if (value < 0 or value > 4294967295) return error.NumericValueOutOfRange;
                        try putInt(out, u32, @intCast(value));
                    },
                    else => try putInt(out, i64, value),
                },
                .boolean => |value| try put(out, &.{@intFromBool(value)}),
                .text, .jsonb, .bpchar, .bytea, .range => |*text| try putText(out, text.slice()),
                .float4 => |value| try putInt(out, u32, @bitCast(value)),
                .float8 => |value| try putInt(out, u64, @bitCast(value)),
                .numeric => |*value| {
                    var limbs: usize = value.limbs.len;
                    while (limbs != 0 and value.limbs[limbs - 1] == 0) limbs -= 1;
                    try put(out, &.{ @intFromEnum(value.special), @intFromBool(value.negative), @intCast(limbs) });
                    try putInt(out, u16, value.dscale);
                    for (value.limbs[0..limbs]) |limb| try putInt(out, u64, limb);
                },
                .date => |value| try putInt(out, i32, value),
                .timestamp, .timestamptz, .time, .money => |value| try putInt(out, i64, value),
                .interval => |value| {
                    try putInt(out, i32, value.months);
                    try putInt(out, i32, value.days);
                    try putInt(out, i64, value.us);
                },
                .uuid => |*value| try put(out, value),
                .timetz => |value| {
                    try putInt(out, i64, value.us);
                    try putInt(out, i32, value.zone);
                },
                .bits => |*value| {
                    try putInt(out, u32, @intCast(value.len));
                    try put(out, value.slice());
                },
                .pg_lsn, .xid8 => |value| try putInt(out, u64, value),
                .array => return error.TypeMismatch,
            }
        }

        fn takeText(bytes: []const u8, at: *usize) Text {
            const len = getInt(u16, bytes, at);
            var text: Text = .{ .len = len };
            @memcpy(text.bytes[0..len], bytes[at.*..][0..len]);
            at.* += len;
            return text;
        }

        fn decode(bytes: []const u8, at: *usize, element: DataType) Cell {
            return switch (V.cellTag(element)) {
                .null_value, .array => unreachable,
                .integer => .{ .integer = switch (element) {
                    .smallint => getInt(i16, bytes, at),
                    .integer32 => getInt(i32, bytes, at),
                    .oid => getInt(u32, bytes, at),
                    else => getInt(i64, bytes, at),
                } },
                .boolean => blk: {
                    at.* += 1;
                    break :blk .{ .boolean = bytes[at.* - 1] != 0 };
                },
                .text => .{ .text = takeText(bytes, at) },
                .jsonb => .{ .jsonb = takeText(bytes, at) },
                .bpchar => .{ .bpchar = takeText(bytes, at) },
                .bytea => .{ .bytea = takeText(bytes, at) },
                .range => .{ .range = takeText(bytes, at) },
                .float4 => .{ .float4 = @bitCast(getInt(u32, bytes, at)) },
                .float8 => .{ .float8 = @bitCast(getInt(u64, bytes, at)) },
                .numeric => blk: {
                    var value: numeric.Numeric = .{ .special = @enumFromInt(bytes[at.*]), .negative = bytes[at.* + 1] != 0 };
                    const limbs = bytes[at.* + 2];
                    at.* += 3;
                    value.dscale = getInt(u16, bytes, at);
                    for (0..limbs) |index| value.limbs[index] = getInt(u64, bytes, at);
                    break :blk .{ .numeric = value };
                },
                .date => .{ .date = getInt(i32, bytes, at) },
                .timestamp => .{ .timestamp = getInt(i64, bytes, at) },
                .timestamptz => .{ .timestamptz = getInt(i64, bytes, at) },
                .time => .{ .time = getInt(i64, bytes, at) },
                .money => .{ .money = getInt(i64, bytes, at) },
                .interval => blk: {
                    const months = getInt(i32, bytes, at);
                    const days = getInt(i32, bytes, at);
                    break :blk .{ .interval = .{ .months = months, .days = days, .us = getInt(i64, bytes, at) } };
                },
                .uuid => blk: {
                    at.* += 16;
                    break :blk .{ .uuid = bytes[at.* - 16 ..][0..16].* };
                },
                .timetz => blk: {
                    const us = getInt(i64, bytes, at);
                    break :blk .{ .timetz = .{ .us = us, .zone = getInt(i32, bytes, at) } };
                },
                .bits => blk: {
                    const len = getInt(u32, bytes, at);
                    var value: V.BitString = .{ .len = len };
                    const count = (len + 7) / 8;
                    @memcpy(value.bytes[0..count], bytes[at.*..][0..count]);
                    at.* += count;
                    break :blk .{ .bits = value };
                },
                .pg_lsn => .{ .pg_lsn = getInt(u64, bytes, at) },
                .xid8 => .{ .xid8 = getInt(u64, bytes, at) },
            };
        }

        /// Sequential element access in row-major order.
        pub const Reader = struct {
            bytes: []const u8,
            element: DataType,
            at: usize,
            index: usize = 0,
            total: usize,

            pub fn init(bytes: []const u8) Reader {
                const layout = shape(bytes);
                return .{ .bytes = bytes, .element = layout.element, .at = bodyStart(bytes), .total = layout.count() };
            }

            /// The next element (NULL as null_value); false after the last.
            pub fn next(self: *Reader, out: *Cell) bool {
                if (self.index == self.total) return false;
                self.index += 1;
                const flag = self.bytes[self.at];
                self.at += 1;
                out.* = if (flag == 0) .null_value else decode(self.bytes, &self.at, self.element);
                return true;
            }

            /// Skips the next element.
            pub fn skip(self: *Reader) void {
                var ignored: Cell = undefined;
                _ = self.next(&ignored);
            }
        };

        /// array_cmp.
        pub fn compare(a: []const u8, b: []const u8) i8 {
            const left = shape(a);
            const right = shape(b);
            if (left.element != right.element) return if (@intFromEnum(left.element) < @intFromEnum(right.element)) -1 else 1;
            var x = Reader.init(a);
            var y = Reader.init(b);
            var p: Cell = undefined;
            var q: Cell = undefined;
            while (x.index < x.total and y.index < y.total) {
                _ = x.next(&p);
                _ = y.next(&q);
                const p_null = p == .null_value;
                const q_null = q == .null_value;
                if (p_null and q_null) continue;
                if (p_null) return 1;
                if (q_null) return -1;
                const order = V.compare(&p, &q);
                if (order != 0) return order;
            }
            if (x.total != y.total) return if (x.total < y.total) -1 else 1;
            if (left.ndim != right.ndim) return if (left.ndim < right.ndim) -1 else 1;
            for (0..left.ndim) |dim| if (left.dims[dim] != right.dims[dim]) return if (left.dims[dim] < right.dims[dim]) -1 else 1;
            for (0..left.ndim) |dim| if (left.lbounds[dim] != right.lbounds[dim]) return if (left.lbounds[dim] < right.lbounds[dim]) -1 else 1;
            return 0;
        }

        /// A hash word consistent with compare: the element type, the shape
        /// and every element's own hash (NULL elements as a fixed word).
        pub fn hash(bytes: []const u8) u64 {
            const layout = shape(bytes);
            var code: u64 = 0x9e3779b97f4a7c15 ^ @as(u64, @intFromEnum(layout.element));
            code = mixWord(code, layout.ndim);
            for (0..layout.ndim) |dim| {
                code = mixWord(code, layout.dims[dim]);
                code = mixWord(code, @as(u32, @bitCast(layout.lbounds[dim])));
            }
            var reader = Reader.init(bytes);
            var cell: Cell = undefined;
            while (reader.next(&cell)) code = mixWord(code, if (cell == .null_value) 0x6a09e667f3bcc908 else V.hash(&cell));
            return code;
        }

        fn mixWord(code: u64, word: u64) u64 {
            var out = (code ^ word) *% 0xff51afd7ed558ccd;
            out ^= out >> 33;
            return out;
        }
    };
}
