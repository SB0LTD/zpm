//! PostgreSQL wire representations of SQL values (ZPM src/db, design §4.7).
//!
//! Text format uses the engine's output functions (DB.Result.Io.format) with
//! the session's TimeZone. Binary send/receive follows PostgreSQL's
//! *send/*recv functions: int2/int4/int8/oid big-endian, bool one byte,
//! float4/float8 IEEE bits, NUMERIC {ndigits, weight, sign, dscale,
//! base-10000 digits}, DATE i32 days and TIMESTAMP[TZ] i64 microseconds
//! since 2000-01-01, INTERVAL {us i64, days i32, months i32}, JSONB version
//! byte 1 + text, and text/name/json/varchar/bpchar raw bytes (bpchar
//! padded), UUID 16 bytes, BYTEA raw bytes (hex text), TIME i64
//! microseconds, TIMETZ {i64 microseconds, i32 seconds west} and BIT/VARBIT
//! {i32 bit length, packed bits}, MONEY i64 cents and pg_lsn/xid8 u64.
//! Arrays use array_send/array_recv: {i32 ndim, i32 has-NULL flag, element
//! type OID, ndim x (i32 dim, i32 lower bound), then per element an i32
//! length (-1 for NULL) and the element's binary form}.
//! Parameters are rendered as
//! SQL literals `'...'::type` (integers and booleans stay bare, as before),
//! so binary input is decoded and re-encoded as text; malformed binary input
//! is a protocol violation (08P01).

pub const Error = error{ BufferTooSmall, ProtocolViolation, UnsupportedBinaryType };

fn put(out: []u8, at: *usize, bytes: []const u8) Error!void {
    if (bytes.len > out.len - at.*) return error.BufferTooSmall;
    @memcpy(out[at.*..][0..bytes.len], bytes);
    at.* += bytes.len;
}

fn Bits(comptime T: type) type {
    return switch (@sizeOf(T)) {
        2 => u16,
        4 => u32,
        8 => u64,
        else => @compileError("unsupported wire integer"),
    };
}

fn putInt(comptime T: type, out: []u8, at: *usize, value: T) Error!void {
    const Unsigned = Bits(T);
    const bits: Unsigned = @bitCast(value);
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (0..@sizeOf(T)) |index| bytes[index] = @truncate(bits >> @intCast((@sizeOf(T) - 1 - index) * 8));
    return put(out, at, &bytes);
}

fn getInt(comptime T: type, bytes: []const u8) T {
    var bits: Bits(T) = 0;
    for (bytes[0..@sizeOf(T)]) |byte| bits = (bits << 8) | byte;
    return @bitCast(bits);
}

pub fn Types(comptime Result: type) type {
    const Io = Result.ValueIo;
    const Cell = Io.Cell;
    const N = Io.Numerics;
    const DataType = @TypeOf(@as(Result, undefined).column_types[0]);
    return struct {
        pub const Session = Io.SessionValues;

        pub fn oid(data_type: DataType) u32 {
            return Io.typeInfo(data_type).oid;
        }

        /// RowDescription typlen (-1 for variable length).
        pub fn length(data_type: DataType) i16 {
            return switch (data_type) {
                .interval => 16,
                else => Io.typeInfo(data_type).len,
            };
        }

        pub fn sendText(cell: *const Cell, session: *const Session, out: []u8) Error!usize {
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = Io.format(cell, false, session, &buffer) catch return error.BufferTooSmall;
            var at: usize = 0;
            try put(out, &at, text);
            return at;
        }

        pub fn sendBinary(cell: *const Cell, data_type: DataType, session: *const Session, out: []u8) Error!usize {
            var at: usize = 0;
            switch (cell.*) {
                .null_value => {},
                .integer => |value| switch (data_type) {
                    .smallint => try putInt(i16, out, &at, @intCast(value)),
                    .integer32 => try putInt(i32, out, &at, @intCast(value)),
                    .oid => try putInt(u32, out, &at, @intCast(value)),
                    else => try putInt(i64, out, &at, value),
                },
                .boolean => |value| try put(out, &at, &.{@intFromBool(value)}),
                .text => |*value| try put(out, &at, value.slice()),
                .float4 => |value| try putInt(u32, out, &at, @bitCast(value)),
                .float8 => |value| try putInt(u64, out, &at, @bitCast(value)),
                .numeric => |*value| {
                    const groups = N.toBase10000(value);
                    try putInt(i16, out, &at, @intCast(groups.ndigits));
                    try putInt(i16, out, &at, groups.weight);
                    const sign: u16 = switch (value.special) {
                        .nan => 0xc000,
                        .pinf => 0xd000,
                        .ninf => 0xf000,
                        .finite => if (value.negative) 0x4000 else 0,
                    };
                    try putInt(u16, out, &at, sign);
                    try putInt(u16, out, &at, value.dscale);
                    for (groups.digits[0..groups.ndigits]) |group| try putInt(u16, out, &at, group);
                },
                .date => |value| try putInt(i32, out, &at, value),
                .timestamp, .timestamptz => |value| try putInt(i64, out, &at, value),
                .interval => |value| {
                    try putInt(i64, out, &at, value.us);
                    try putInt(i32, out, &at, value.days);
                    try putInt(i32, out, &at, value.months);
                },
                .jsonb => {
                    try put(out, &at, &.{1});
                    at += try sendText(cell, session, out[at..]);
                },
                .bpchar => |*value| try put(out, &at, value.slice()),
                .uuid => |*value| try put(out, &at, value),
                .bytea => |*value| try put(out, &at, value.slice()),
                .time => |value| try putInt(i64, out, &at, value),
                .timetz => |value| {
                    try putInt(i64, out, &at, value.us);
                    try putInt(i32, out, &at, value.zone);
                },
                .bits => |*value| {
                    try putInt(i32, out, &at, @intCast(value.len));
                    try put(out, &at, value.slice());
                },
                .money => |value| try putInt(i64, out, &at, value),
                .pg_lsn, .xid8 => |value| try putInt(u64, out, &at, value),
                .array => |*items| {
                    const element = Io.elementData(data_type) orelse return error.UnsupportedBinaryType;
                    const shape = Io.Arrays.shape(items.slice());
                    try putInt(i32, out, &at, @intCast(shape.ndim));
                    try putInt(i32, out, &at, @intFromBool(shape.has_nulls));
                    try putInt(u32, out, &at, Io.typeInfo(element).oid);
                    for (0..shape.ndim) |dim| {
                        try putInt(i32, out, &at, @intCast(shape.dims[dim]));
                        try putInt(i32, out, &at, shape.lbounds[dim]);
                    }
                    var reader = Io.Arrays.Reader.init(items.slice());
                    var item: Cell = undefined;
                    while (reader.next(&item)) {
                        if (item == .null_value) {
                            try putInt(i32, out, &at, -1);
                            continue;
                        }
                        if (out.len - at < 4) return error.BufferTooSmall;
                        const size = try sendBinary(&item, element, session, out[at + 4 ..]);
                        try putInt(i32, out, &at, @intCast(size));
                        at += size;
                    }
                },
            }
            return at;
        }

        /// Parameter cast names of array types (`int4[]`; bit as varbit).
        const array_cast_names = blk: {
            const fields = @typeInfo(DataType).@"enum".field_names;
            var names: [fields.len][]const u8 = undefined;
            for (fields, 0..) |field, index| {
                const element = @field(DataType, field);
                names[index] = (if (element == .bit) "varbit" else Io.typeInfo(element).name) ++ "[]";
            }
            break :blk names;
        };

        /// SQL type name used in a parameter literal `'...'::name`.
        fn castName(type_oid: u32) ?[]const u8 {
            const data_type = Io.typeFromOid(type_oid) orelse return null;
            if (Io.elementData(data_type)) |element| return array_cast_names[@intFromEnum(element)];
            return switch (data_type) {
                .text, .integer, .integer32, .boolean => null,
                // `::bit` would mean BIT(1); varbit keeps every bit and is
                // implicitly castable to BIT(n).
                .bit => "varbit",
                else => Io.typeInfo(data_type).name,
            };
        }

        /// Whether this module renders parameters of `type_oid` (other than
        /// the integer, boolean and text forms the codec renders itself).
        pub fn handles(type_oid: u32) bool {
            return castName(type_oid) != null;
        }

        fn quote(out: []u8, at: *usize, bytes: []const u8) Error!void {
            try put(out, at, "'");
            for (bytes) |c| {
                if (c == 0) return error.ProtocolViolation;
                try put(out, at, &.{c});
                if (c == '\'') try put(out, at, "'");
            }
            try put(out, at, "'");
        }

        /// A parameter value as a typed SQL literal.
        pub fn literal(bytes: []const u8, type_oid: u32, format: u16, out: []u8) Error!usize {
            const name = castName(type_oid) orelse return error.UnsupportedBinaryType;
            var at: usize = 0;
            if (format == 0) {
                try quote(out, &at, bytes);
            } else {
                var text: [Io.format_bytes]u8 = undefined;
                const cell = try decodeBinary(bytes, Io.typeFromOid(type_oid).?);
                const utc: Session = .{};
                const rendered = Io.format(&cell, true, &utc, &text) catch return error.ProtocolViolation;
                try quote(out, &at, rendered);
            }
            try put(out, &at, "::");
            try put(out, &at, name);
            return at;
        }

        /// A binary COPY field as the text its input function accepts
        /// (PostgreSQL *recv lengths are exact: anything else is
        /// ProtocolViolation, which COPY reports as 22P03). Text-like values
        /// are returned in place; others are rendered into `out`.
        pub fn receiveText(bytes: []const u8, data_type: DataType, out: []u8) Error![]const u8 {
            switch (data_type) {
                .text, .name, .json, .varchar, .bpchar => return bytes,
                .jsonb => {
                    if (bytes.len == 0 or bytes[0] != 1) return error.ProtocolViolation;
                    return bytes[1..];
                },
                .boolean => {
                    if (bytes.len != 1) return error.ProtocolViolation;
                    return if (bytes[0] != 0) "t" else "f";
                },
                else => {},
            }
            const cell: Cell = switch (data_type) {
                .integer32 => blk: {
                    if (bytes.len != 4) return error.ProtocolViolation;
                    break :blk .{ .integer = getInt(i32, bytes) };
                },
                .integer => blk: {
                    if (bytes.len != 8) return error.ProtocolViolation;
                    break :blk .{ .integer = getInt(i64, bytes) };
                },
                else => try decodeBinary(bytes, data_type),
            };
            var text: [Io.format_bytes]u8 = undefined;
            const utc: Session = .{};
            const rendered = Io.format(&cell, true, &utc, &text) catch return error.ProtocolViolation;
            if (rendered.len > out.len) return error.BufferTooSmall;
            @memcpy(out[0..rendered.len], rendered);
            return out[0..rendered.len];
        }

        /// array_recv: the declared element type must match, at most six
        /// dimensions, a flag of 0 or 1, exact element lengths and no
        /// trailing bytes. Each element goes through its own receive and
        /// input functions.
        fn decodeArray(bytes: []const u8, data_type: DataType) Error!Cell {
            const element = Io.elementData(data_type) orelse return error.UnsupportedBinaryType;
            if (bytes.len < 12) return error.ProtocolViolation;
            const ndim = getInt(i32, bytes[0..4]);
            const flags = getInt(i32, bytes[4..8]);
            if (ndim < 0 or ndim > 6 or (flags != 0 and flags != 1) or getInt(u32, bytes[8..12]) != Io.typeInfo(element).oid) return error.ProtocolViolation;
            var at: usize = 12;
            var shape: Io.ArrayShape = .{ .element = element, .ndim = @intCast(ndim) };
            var empty = ndim == 0;
            for (0..shape.ndim) |dim| {
                if (bytes.len - at < 8) return error.ProtocolViolation;
                const size = getInt(i32, bytes[at..][0..4]);
                if (size < 0) return error.ProtocolViolation;
                shape.dims[dim] = @intCast(size);
                shape.lbounds[dim] = getInt(i32, bytes[at + 4 ..][0..4]);
                if (size == 0) empty = true;
                at += 8;
            }
            if (empty) shape.ndim = 0;
            var result: Io.Text = .{};
            var writer = Io.Arrays.Writer.begin(&result, &shape) catch |err| return if (err == error.TextCapacity) error.BufferTooSmall else error.ProtocolViolation;
            const utc: Session = .{};
            var text: [Io.format_bytes]u8 = undefined;
            while (!writer.complete()) {
                if (bytes.len - at < 4) return error.ProtocolViolation;
                const size = getInt(i32, bytes[at..][0..4]);
                at += 4;
                var cell: Cell = .null_value;
                if (size != -1) {
                    if (size < 0 or bytes.len - at < @as(usize, @intCast(size))) return error.ProtocolViolation;
                    const end = at + @as(usize, @intCast(size));
                    const rendered = try receiveText(bytes[at..end], element, &text);
                    cell = Io.parse(Io.typeOfData(element), -1, rendered, &utc) catch return error.ProtocolViolation;
                    at = end;
                }
                writer.append(&cell) catch |err| return if (err == error.TextCapacity) error.BufferTooSmall else error.ProtocolViolation;
            }
            if (at != bytes.len) return error.ProtocolViolation;
            return .{ .array = result };
        }

        fn decodeBinary(bytes: []const u8, data_type: DataType) Error!Cell {
            if (Io.elementData(data_type) != null) return decodeArray(bytes, data_type);
            const need: usize = switch (data_type) {
                .smallint => 2,
                .integer32, .oid, .real, .date => 4,
                .integer, .double, .timestamp, .timestamptz, .time, .money, .pg_lsn, .xid8 => 8,
                .timetz => 12,
                .interval, .uuid => 16,
                else => 0,
            };
            if (need != 0 and bytes.len != need) return error.ProtocolViolation;
            return switch (data_type) {
                .smallint => .{ .integer = getInt(i16, bytes) },
                .oid => .{ .integer = getInt(u32, bytes) },
                .real => .{ .float4 = @bitCast(getInt(u32, bytes)) },
                .double => .{ .float8 = @bitCast(getInt(u64, bytes)) },
                .date => .{ .date = getInt(i32, bytes) },
                .timestamp => .{ .timestamp = getInt(i64, bytes) },
                .timestamptz => .{ .timestamptz = getInt(i64, bytes) },
                .interval => .{ .interval = .{ .us = getInt(i64, bytes[0..8]), .days = getInt(i32, bytes[8..12]), .months = getInt(i32, bytes[12..16]) } },
                .uuid => .{ .uuid = bytes[0..16].* },
                .money => .{ .money = getInt(i64, bytes) },
                .pg_lsn => .{ .pg_lsn = getInt(u64, bytes) },
                .xid8 => .{ .xid8 = getInt(u64, bytes) },
                .time => blk: {
                    const us = getInt(i64, bytes);
                    if (us < 0 or us > 86400000000) return error.ProtocolViolation;
                    break :blk Cell{ .time = us };
                },
                .timetz => blk: {
                    const us = getInt(i64, bytes[0..8]);
                    const zone = getInt(i32, bytes[8..12]);
                    if (us < 0 or us > 86400000000 or zone < -57599 or zone > 57599) return error.ProtocolViolation;
                    break :blk Cell{ .timetz = .{ .us = us, .zone = zone } };
                },
                .numeric => blk: {
                    if (bytes.len < 8) return error.ProtocolViolation;
                    const ndigits: usize = getInt(u16, bytes[0..2]);
                    const weight = getInt(i16, bytes[2..4]);
                    const sign = getInt(u16, bytes[4..6]);
                    const dscale = getInt(u16, bytes[6..8]);
                    if (bytes.len != 8 + ndigits * 2 or ndigits > 40) return error.ProtocolViolation;
                    switch (sign) {
                        0xc000 => break :blk Cell{ .numeric = .{ .special = .nan } },
                        0xd000 => break :blk Cell{ .numeric = .{ .special = .pinf } },
                        0xf000 => break :blk Cell{ .numeric = .{ .special = .ninf } },
                        0, 0x4000 => {},
                        else => return error.ProtocolViolation,
                    }
                    var groups: [40]u16 = undefined;
                    for (0..ndigits) |index| groups[index] = getInt(u16, bytes[8 + index * 2 ..][0..2]);
                    const value = N.fromBase10000(groups[0..ndigits], weight, sign == 0x4000, dscale) catch return error.ProtocolViolation;
                    break :blk Cell{ .numeric = value };
                },
                .jsonb => blk: {
                    if (bytes.len == 0 or bytes[0] != 1) return error.ProtocolViolation;
                    var text: Io.Text = .{};
                    if (bytes.len - 1 > text.bytes.len) return error.ProtocolViolation;
                    @memcpy(text.bytes[0 .. bytes.len - 1], bytes[1..]);
                    text.len = bytes.len - 1;
                    break :blk Cell{ .text = text };
                },
                .bit, .varbit => blk: {
                    const BitString = @TypeOf(@as(Cell, undefined).bits);
                    if (bytes.len < 4) return error.ProtocolViolation;
                    const bit_count = getInt(i32, bytes[0..4]);
                    if (bit_count < 0 or @as(usize, @intCast(bit_count)) > BitString.max_bits) return error.ProtocolViolation;
                    const count: usize = @intCast(@divTrunc(bit_count + 7, 8));
                    if (bytes.len != 4 + count) return error.ProtocolViolation;
                    var value: BitString = .{ .len = @intCast(bit_count) };
                    @memcpy(value.bytes[0..count], bytes[4..]);
                    // varbit_recv: VARBIT_PAD clears the unused low bits.
                    if (@mod(bit_count, 8) != 0) value.bytes[count - 1] &= @as(u8, @truncate(@as(u16, 0xff00) >> @intCast(@mod(bit_count, 8))));
                    break :blk Cell{ .bits = value };
                },
                .bytea => blk: {
                    var raw: Io.Text = .{};
                    if (bytes.len > raw.bytes.len) return error.ProtocolViolation;
                    @memcpy(raw.bytes[0..bytes.len], bytes);
                    raw.len = bytes.len;
                    break :blk Cell{ .bytea = raw };
                },
                .name, .json, .varchar, .bpchar => blk: {
                    var text: Io.Text = .{};
                    if (bytes.len > text.bytes.len) return error.ProtocolViolation;
                    @memcpy(text.bytes[0..bytes.len], bytes);
                    text.len = bytes.len;
                    break :blk Cell{ .text = text };
                },
                else => error.UnsupportedBinaryType,
            };
        }
    };
}
