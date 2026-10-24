//! PostgreSQL wire representations of SQL values (ZPM src/db, design §4.7).
//!
//! Text format uses the engine's output functions (DB.Result.Io.format) with
//! the session's TimeZone. Binary send/receive follows PostgreSQL's
//! *send/*recv functions: int2/int4/int8/oid big-endian, bool one byte,
//! float4/float8 IEEE bits, NUMERIC {ndigits, weight, sign, dscale,
//! base-10000 digits}, DATE i32 days and TIMESTAMP[TZ] i64 microseconds
//! since 2000-01-01, INTERVAL {us i64, days i32, months i32}, JSONB version
//! byte 1 + text, and text/name/json raw bytes. Parameters are rendered as
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
            }
            return at;
        }

        /// SQL type name used in a parameter literal `'...'::name`.
        fn castName(type_oid: u32) ?[]const u8 {
            const data_type = Io.typeFromOid(type_oid) orelse return null;
            return switch (data_type) {
                .text, .integer, .integer32, .boolean => null,
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

        fn decodeBinary(bytes: []const u8, data_type: DataType) Error!Cell {
            const need: usize = switch (data_type) {
                .smallint => 2,
                .integer32, .oid, .real, .date => 4,
                .integer, .double, .timestamp, .timestamptz => 8,
                .interval => 16,
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
                .name, .json => blk: {
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
