//! Value conversions (Layer 0, design §4.2): text input and output for every
//! type, casts (explicit, assignment and implicit contexts follow
//! PostgreSQL's pg_cast for the supported types), typmod coercion and the
//! operators over the Q02/Q03/Q04 types. Cells are the tagged union in
//! types.sig with inline storage bounded by Config.text_bytes.
//!
//! The per-statement Session supplies what PostgreSQL takes from GUCs and
//! the transaction: the TimeZone (output and local-time input of
//! TIMESTAMPTZ), a zone-name resolver, transaction/statement start times and
//! the wall clock. Without a clock, now() and friends fail with 0A000.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const float_text = @import("float_text.sig");
const temporal = @import("temporal.sig");
const jsonb = @import("jsonb.sig");
const expr = @import("expr.sig");
const ast = @import("ast.sig");
const Error = types.Error;
const Type = types.Type;

pub const Session = struct {
    zone: temporal.Zone = .{},
    resolver: temporal.Resolver = .{},
    /// PostgreSQL-epoch microseconds (2000-01-01 UTC); null without a clock.
    transaction_us: ?i64 = null,
    statement_us: ?i64 = null,
    /// Current wall clock in PostgreSQL-epoch microseconds.
    clock: ?*const fn () ?i64 = null,
    /// Sequence functions, identity defaults and regclass lookups (set by
    /// the Database for each statement); null rejects them (0A000).
    sequences: ?*const SequenceHook = null,
    /// current_database(): the session's startup database.
    database: []const u8 = "postgres",
    control: ?*types.ExecutionControl = null,

    pub fn checkpoint(self: *const Session) Error!void {
        if (self.control) |control| try control.checkpoint();
    }
    pub fn checkpoints(self:*const Session,count:usize) Error!void {
        if(self.control) |control| try control.advance(count);
    }
};

pub const SequenceCall = enum { nextval, currval, setval, lastval, identity, regclass };

/// `name` is the regclass text (nextval/currval/setval; or `oid` when the
/// argument is a regclass); identity passes the table slot in `oid` and the
/// column in `value`; regclass resolves a relation name to its OID (-1 when
/// missing unless `called`, which raises 42P01).
pub const SequenceHook = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, kind: SequenceCall, name: []const u8, oid: u32, value: i64, called: bool) Error!i64,
    /// regclass output: the relation named by `oid`, if any.
    relation_name: *const fn (ptr: *anyopaque, oid: u32, out: *[64]u8) ?usize,
};

pub const default_session: Session = .{};
const SessionType = Session;

pub const Context = enum { implicit, assignment, explicit };

pub fn numericCategory(ty: Type) bool {
    return switch (ty) {
        .int2, .int4, .int8, .numeric, .float4, .float8 => true,
        else => false,
    };
}

pub fn integral(ty: Type) bool {
    return ty == .int2 or ty == .int4 or ty == .int8;
}

pub fn stringType(ty: Type) bool {
    return ty == .text or ty == .name;
}

pub fn datetime(ty: Type) bool {
    return ty == .date or ty == .timestamp or ty == .timestamptz;
}

/// Promotion rank in the numeric category (int2 < ... < float8).
pub fn numericRank(ty: Type) u8 {
    return switch (ty) {
        .int2 => 0,
        .int4 => 1,
        .int8 => 2,
        .numeric => 3,
        .float4 => 4,
        .float8 => 5,
        else => 255,
    };
}

fn datetimeRank(ty: Type) u8 {
    return switch (ty) {
        .date => 0,
        .timestamp => 1,
        .timestamptz => 2,
        else => 255,
    };
}

/// Whether a cast from `from` to `to` exists in `context`.
pub fn castable(from: Type, to: Type, context: Context) bool {
    if (from == to) return true;
    if (from == .unknown) return true;
    // Implicit promotions.
    if (numericCategory(from) and numericCategory(to) and numericRank(from) < numericRank(to)) return true;
    if (datetime(from) and datetime(to) and datetimeRank(from) < datetimeRank(to)) return true;
    if (stringType(from) and stringType(to)) return true;
    if ((from == .int2 or from == .int4 or from == .int8) and to == .oid) return true;
    if (context == .implicit) return false;
    // Assignment.
    if (numericCategory(from) and numericCategory(to)) return true;
    if (datetime(from) and datetime(to)) return true;
    if (stringType(to)) return true;
    if (from == .oid and (to == .int4 or to == .int8)) return true;
    if ((from == .json and to == .jsonb) or (from == .jsonb and to == .json)) return true;
    if (context == .assignment) return false;
    // Explicit only.
    if (stringType(from)) return true;
    if ((from == .boolean and to == .int4) or (from == .int4 and to == .boolean)) return true;
    return false;
}

/// select_common_type / operator promotion for two typed operands; null
/// when they do not unify.
/// Mixed REAL comparisons resolve a float8 operator, unlike CASE/GREATEST
/// common-type selection. Rounding an exact int/numeric to float4 first can
/// turn distinct values into equal ones (e.g. 16777217 and 16777216::real).
pub fn comparisonType(a: Type, b: Type) ?Type {
    if (a != b and numericCategory(a) and numericCategory(b) and (a == .float4 or b == .float4)) return .float8;
    return common(a, b);
}

pub fn common(a: Type, b: Type) ?Type {
    if (a == b) return a;
    if (numericCategory(a) and numericCategory(b)) {
        const high = if (numericRank(a) > numericRank(b)) a else b;
        return high;
    }
    if (datetime(a) and datetime(b)) return if (datetimeRank(a) > datetimeRank(b)) a else b;
    if (stringType(a) and stringType(b)) return .text;
    // int2/int4/int8 -> oid is implicit (catalog OID comparisons).
    if ((a == .oid and (b == .int2 or b == .int4 or b == .int8)) or (b == .oid and (a == .int2 or a == .int4 or a == .int8))) return .oid;
    return null;
}

/// Arithmetic result type over two numeric-category operands. float4 with
/// a non-float operand promotes to float8 (no int/numeric x float4
/// operators exist).
pub fn arithmeticType(a: Type, b: Type) Type {
    if (a == .float8 or b == .float8) return .float8;
    if (a == .float4 or b == .float4) return if (a == b) .float4 else .float8;
    if (a == .numeric or b == .numeric) return .numeric;
    if (a == .int8 or b == .int8) return .int8;
    if (a == .int4 or b == .int4) return .int4;
    return .int2;
}

pub fn integerRange(ty: Type) struct { low: i64, high: i64 } {
    return switch (ty) {
        .int2 => .{ .low = -32768, .high = 32767 },
        .int4 => .{ .low = -2147483648, .high = 2147483647 },
        .oid => .{ .low = 0, .high = 4294967295 },
        else => .{ .low = -9223372036854775808, .high = 9223372036854775807 },
    };
}

pub fn Io(comptime config: types.Config) type {
    const V = types.Values(config);
    const N = numeric.Ops(config.numeric_digits);
    const J = jsonb.Jsonb(config.text_bytes, config.json_depth, config.numeric_digits);
    return struct {
        pub const Text = V.Text;
        pub const Cell = V.Cell;
        pub const Numerics = N;
        pub const Documents = J;
        pub const SessionValues = SessionType;
        pub const typeInfo = types.typeInfo;
        pub const typeFromOid = types.typeFromOid;
        /// Largest text form of one cell (codec buffers).
        pub const format_bytes: usize = @as(usize, @max(config.text_bytes * 8, numeric.format_bytes)) + 64;

        fn appendBytes(text: *V.Text, bytes: []const u8) Error!void {
            if (bytes.len > config.text_bytes - text.len) return error.TextCapacity;
            @memcpy(text.bytes[text.len..][0..bytes.len], bytes);
            text.len += bytes.len;
        }

        fn integerText(value: i64, buffer: []u8) []const u8 {
            var digits: [20]u8 = undefined;
            var index: usize = digits.len;
            var magnitude: u64 = if (value < 0) @as(u64, @bitCast(-%value)) else @intCast(value);
            while (true) {
                index -= 1;
                digits[index] = @intCast('0' + magnitude % 10);
                magnitude /= 10;
                if (magnitude == 0) break;
            }
            var at: usize = 0;
            if (value < 0) {
                buffer[0] = '-';
                at = 1;
            }
            @memcpy(buffer[at..][0 .. digits.len - index], digits[index..]);
            return buffer[0 .. at + digits.len - index];
        }

        /// Text output of a non-NULL cell into `buffer` (at least
        /// format_bytes long). `verbose` booleans are true/false (casts,
        /// assignment); otherwise t/f (the output function).
        pub fn format(cell: *const V.Cell, verbose: bool, session: *const Session, buffer: []u8) Error![]const u8 {
            return switch (cell.*) {
                .null_value => buffer[0..0],
                .integer => |value| integerText(value, buffer),
                .boolean => |value| copy(buffer, if (verbose) (if (value) "true" else "false") else (if (value) "t" else "f")),
                .text => |*value| copy(buffer, value.slice()),
                .float4 => |value| float_text.format(f32, value, buffer),
                .float8 => |value| float_text.format(f64, value, buffer),
                .numeric => |*value| N.format(value, buffer),
                .date => |value| temporal.formatDate(value, buffer),
                .timestamp => |value| temporal.formatTimestamp(value, null, buffer),
                .timestamptz => |value| temporal.formatTimestamp(value, &session.zone, buffer),
                .interval => |value| temporal.formatInterval(value, buffer),
                .jsonb => |*value| blk: {
                    var out: J.Text = .{ .bytes = buffer };
                    try J.render(value.slice(), 0, &out);
                    break :blk buffer[0..out.len];
                },
            };
        }

        fn copy(buffer: []u8, value: []const u8) []const u8 {
            @memcpy(buffer[0..value.len], value);
            return buffer[0..value.len];
        }

        pub fn appendCell(text: *V.Text, cell: *const V.Cell, verbose: bool, session: *const Session) Error!void {
            switch (cell.*) {
                .null_value => {},
                .text => |*value| try appendBytes(text, value.slice()),
                else => {
                    var buffer: [format_bytes]u8 = undefined;
                    try appendBytes(text, try format(cell, verbose, session, &buffer));
                },
            }
        }

        pub fn toText(cell: *const V.Cell, verbose: bool, session: *const Session) Error!V.Cell {
            if (cell.* == .null_value) return .null_value;
            var text: V.Text = .{};
            try appendCell(&text, cell, verbose, session);
            return .{ .text = text };
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            var text: V.Text = .{};
            try appendBytes(&text, bytes);
            return .{ .text = text };
        }

        pub fn jsonbCell(source: []const u8) Error!V.Cell {
            var buffer: J.Buffer = .{};
            try J.parse(source, &buffer);
            var text: V.Text = .{};
            try appendBytes(&text, buffer.bytes[0..buffer.len]);
            return .{ .jsonb = text };
        }

        /// Input function of `ty` (typmod applied).
        pub fn parse(ty: Type, typmod: i32, input: []const u8, session: *const Session) Error!V.Cell {
            const cell: V.Cell = switch (ty) {
                .int2, .int4, .int8 => .{ .integer = blk: {
                    const value = try expr.parseInteger(input, if (ty == .int2) .int4 else ty);
                    if (ty == .int2 and (value < -32768 or value > 32767)) return error.NumericValueOutOfRange;
                    break :blk value;
                } },
                .oid => .{ .integer = blk: {
                    const value = expr.parseInteger(input, .int8) catch |err| return if (err == error.IntegerOverflow) error.NumericValueOutOfRange else err;
                    // oidin accepts -2^31..2^32-1, negatives wrap.
                    if (value < -2147483648 or value > 4294967295) return error.NumericValueOutOfRange;
                    break :blk if (value < 0) value + 4294967296 else value;
                } },
                .boolean => .{ .boolean = try expr.parseBoolean(input) },
                .text, .unknown, .json => blk: {
                    if (ty == .json) try J.validateJson(input);
                    break :blk try textCell(input);
                },
                .name => try textCell(input[0..@min(input.len, 63)]),
                .numeric => .{ .numeric = try N.parse(input) },
                .float4 => .{ .float4 = try float_text.parse(f32, input) },
                .float8 => .{ .float8 = try float_text.parse(f64, input) },
                .date => .{ .date = try temporal.parseDate(input) },
                .timestamp => .{ .timestamp = try temporal.parseTimestamp(input, .timestamp, &session.zone, session.resolver) },
                .timestamptz => .{ .timestamptz = try temporal.parseTimestamp(input, .timestamptz, &session.zone, session.resolver) },
                .interval => .{ .interval = try temporal.parseInterval(input) },
                .jsonb => try jsonbCell(input),
            };
            return applyTypmod(cell, ty, typmod);
        }

        /// Length coercion: NUMERIC(p,s) and TIMESTAMP[TZ](p).
        pub fn applyTypmod(cell: V.Cell, ty: Type, typmod: i32) Error!V.Cell {
            if (typmod < 0 or cell == .null_value) return cell;
            return switch (ty) {
                .numeric => .{ .numeric = try N.applyTypmod(&cell.numeric, typmod) },
                .timestamp => .{ .timestamp = temporal.roundTimestamp(cell.timestamp, typmod) },
                .timestamptz => .{ .timestamptz = temporal.roundTimestamp(cell.timestamptz, typmod) },
                else => cell,
            };
        }

        fn floatToNumeric(value: f64, significant: usize) Error!numeric.Numeric {
            if (value != value) return numeric.nan();
            if (float_text.isInf(value)) return .{ .special = if (value < 0) .ninf else .pinf };
            if (value == 0) return .{};
            var buffer: [64]u8 = undefined;
            const text = float_text.roundedText(f64, value, significant, &buffer);
            // %g: drop trailing fraction zeros before numeric_in.
            var mantissa_end: usize = 0;
            while (mantissa_end < text.len and text[mantissa_end] != 'e') mantissa_end += 1;
            var trimmed = mantissa_end;
            var has_point = false;
            for (text[0..mantissa_end]) |c| if (c == '.') {
                has_point = true;
            };
            if (has_point) {
                while (trimmed > 0 and text[trimmed - 1] == '0') trimmed -= 1;
                if (trimmed > 0 and text[trimmed - 1] == '.') trimmed -= 1;
            }
            var joined: [64]u8 = undefined;
            @memcpy(joined[0..trimmed], text[0..trimmed]);
            @memcpy(joined[trimmed..][0 .. text.len - mantissa_end], text[mantissa_end..]);
            return N.parse(joined[0 .. trimmed + text.len - mantissa_end]);
        }

        fn numericToFloat(comptime T: type, value: *const numeric.Numeric) Error!T {
            switch (value.special) {
                .nan => return float_text.nan(T),
                .pinf => return float_text.inf(T),
                .ninf => return -float_text.inf(T),
                .finite => {},
            }
            var buffer: [numeric.format_bytes]u8 = undefined;
            return float_text.parse(T, N.format(value, &buffer));
        }

        fn checkedInteger(value: i64, ty: Type) Error!i64 {
            const range = integerRange(ty);
            if (value < range.low or value > range.high) return if (ty == .int4 or ty == .int8) error.IntegerOverflow else error.NumericValueOutOfRange;
            return value;
        }

        /// Explicit, assignment or implicit cast of a value of type `from`.
        pub fn cast(cell: V.Cell, from: Type, to: Type, typmod: i32, session: *const Session) Error!V.Cell {
            if (cell == .null_value) return .null_value;
            if (from == to and typmod < 0) return cell;
            const out: V.Cell = switch (to) {
                .int2, .int4, .int8 => switch (cell) {
                    .integer => |value| blk: {
                        if (from == .oid and to == .int4) break :blk V.Cell{ .integer = if (value > 2147483647) value - 4294967296 else value };
                        break :blk V.Cell{ .integer = try checkedInteger(value, to) };
                    },
                    .boolean => |value| V.Cell{ .integer = @intFromBool(value) },
                    .numeric => |*value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = N.toInt(value, range.low, range.high) catch |err| return if (err == error.NumericValueOutOfRange and to != .int2) error.IntegerOverflow else err };
                    },
                    .float4 => |value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = float_text.toInt(value, range.low, range.high) catch return if (to == .int2) error.NumericValueOutOfRange else error.IntegerOverflow };
                    },
                    .float8 => |value| blk: {
                        const range = integerRange(to);
                        break :blk V.Cell{ .integer = float_text.toInt(value, range.low, range.high) catch return if (to == .int2) error.NumericValueOutOfRange else error.IntegerOverflow };
                    },
                    .text => |*value| try parse(to, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .oid => switch (cell) {
                    .integer => |value| V.Cell{ .integer = if (from == .int4 and value < 0) value + 4294967296 else try checkedInteger(value, .oid) },
                    .text => |*value| try parse(.oid, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .boolean => switch (cell) {
                    .integer => |value| V.Cell{ .boolean = value != 0 },
                    .boolean => cell,
                    .text => |*value| V.Cell{ .boolean = try expr.parseBoolean(value.slice()) },
                    else => return error.CannotCoerce,
                },
                .numeric => switch (cell) {
                    .integer => |value| V.Cell{ .numeric = N.fromInt(value) },
                    .numeric => cell,
                    .float4 => |value| V.Cell{ .numeric = try floatToNumeric(value, 6) },
                    .float8 => |value| V.Cell{ .numeric = try floatToNumeric(value, 15) },
                    .text => |*value| try parse(.numeric, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .float4 => switch (cell) {
                    .integer => |value| V.Cell{ .float4 = @floatFromInt(value) },
                    .numeric => |*value| V.Cell{ .float4 = try numericToFloat(f32, value) },
                    .float4 => cell,
                    .float8 => |value| blk: {
                        const narrowed: f32 = @floatCast(value);
                        if (float_text.isInf(narrowed) and !float_text.isInf(value)) return error.NumericValueOutOfRange;
                        if (narrowed == 0 and value != 0) return error.NumericValueOutOfRange;
                        break :blk V.Cell{ .float4 = narrowed };
                    },
                    .text => |*value| try parse(.float4, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .float8 => switch (cell) {
                    .integer => |value| V.Cell{ .float8 = @floatFromInt(value) },
                    .numeric => |*value| V.Cell{ .float8 = try numericToFloat(f64, value) },
                    .float4 => |value| V.Cell{ .float8 = value },
                    .float8 => cell,
                    .text => |*value| try parse(.float8, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .text, .name => blk: {
                    if (cell == .text) {
                        const bytes = cell.text.slice();
                        break :blk try textCell(if (to == .name) bytes[0..@min(bytes.len, 63)] else bytes);
                    }
                    var buffer: [format_bytes]u8 = undefined;
                    const bytes = try format(&cell, true, session, &buffer);
                    break :blk try textCell(if (to == .name) bytes[0..@min(bytes.len, 63)] else bytes);
                },
                .json => switch (cell) {
                    .text => |*value| blk: {
                        if (from != .json) try J.validateJson(value.slice());
                        break :blk cell;
                    },
                    .jsonb => blk: {
                        var buffer: [format_bytes]u8 = undefined;
                        break :blk try textCell(try format(&cell, true, session, &buffer));
                    },
                    else => return error.CannotCoerce,
                },
                .jsonb => switch (cell) {
                    .text => |*value| try jsonbCell(value.slice()),
                    .jsonb => cell,
                    else => return error.CannotCoerce,
                },
                .date => switch (cell) {
                    .date => cell,
                    .timestamp => |value| V.Cell{ .date = temporal.timestampToDate(value) },
                    .timestamptz => |value| V.Cell{ .date = temporal.timestampToDate(if (temporal.finiteTimestamp(value)) temporal.toLocal(&session.zone, value) else value) },
                    .text => |*value| try parse(.date, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .timestamp => switch (cell) {
                    .date => |value| V.Cell{ .timestamp = try temporal.dateToTimestamp(value) },
                    .timestamp => cell,
                    .timestamptz => |value| V.Cell{ .timestamp = if (temporal.finiteTimestamp(value)) temporal.toLocal(&session.zone, value) else value },
                    .text => |*value| try parse(.timestamp, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .timestamptz => switch (cell) {
                    .date => |value| blk: {
                        const local = try temporal.dateToTimestamp(value);
                        break :blk V.Cell{ .timestamptz = if (temporal.finiteTimestamp(local)) try temporal.toUtc(&session.zone, local) else local };
                    },
                    .timestamp => |value| V.Cell{ .timestamptz = if (temporal.finiteTimestamp(value)) try temporal.toUtc(&session.zone, value) else value },
                    .timestamptz => cell,
                    .text => |*value| try parse(.timestamptz, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .interval => switch (cell) {
                    .interval => cell,
                    .text => |*value| try parse(.interval, -1, value.slice(), session),
                    else => return error.CannotCoerce,
                },
                .unknown => cell,
            };
            return applyTypmod(out, to, typmod);
        }

        // ---- operators --------------------------------------------------

        const F8 = float_text.ArithmeticOf(f64);
        const F4 = float_text.ArithmeticOf(f32);

        /// + - * / % over same-typed numeric operands (the binder casts
        /// both sides to the operator's type) and the datetime operators.
        pub fn arithmetic(op: ast.Op, left: *const V.Cell, right: *const V.Cell, result: Type, session: *const Session) Error!V.Cell {
            switch (left.*) {
                .integer => |a| switch (right.*) {
                    .integer => |b| {
                        const value = try expr.arithmetic(op, .int8, a, b);
                        return .{ .integer = try checkedInteger(value, result) };
                    },
                    .date => |b| return .{ .date = try temporal.datePlusDays(b, a) },
                    else => {},
                },
                .numeric => |*a| {
                    const b = &right.numeric;
                    return .{ .numeric = switch (op) {
                        .add => try N.add(a, b),
                        .sub => try N.sub(a, b),
                        .mul => try N.mul(a, b),
                        .div => try N.div(a, b),
                        .mod => try N.mod(a, b),
                        else => unreachable,
                    } };
                },
                .float8 => |a| {
                    const b = right.float8;
                    return .{ .float8 = switch (op) {
                        .add => try F8.add(a, b),
                        .sub => try F8.sub(a, b),
                        .mul => try F8.mul(a, b),
                        .div => try F8.div(a, b),
                        else => return error.UndefinedFunction,
                    } };
                },
                .float4 => |a| {
                    const b = right.float4;
                    return .{ .float4 = switch (op) {
                        .add => try F4.add(a, b),
                        .sub => try F4.sub(a, b),
                        .mul => try F4.mul(a, b),
                        .div => try F4.div(a, b),
                        else => return error.UndefinedFunction,
                    } };
                },
                .date => |a| switch (right.*) {
                    .integer => |b| return .{ .date = try temporal.datePlusDays(a, if (op == .sub) -b else b) },
                    .date => |b| {
                        if (!temporal.finiteDate(a) or !temporal.finiteDate(b)) return error.DatetimeFieldOverflow;
                        return .{ .integer = @as(i64, a) - b };
                    },
                    else => {},
                },
                .timestamp => |a| switch (right.*) {
                    .interval => |b| return .{ .timestamp = try temporal.timestampPlus(a, if (op == .sub) try temporal.negateInterval(b) else b) },
                    .timestamp => |b| return .{ .interval = try temporal.timestampDifference(a, b) },
                    else => {},
                },
                .timestamptz => |a| switch (right.*) {
                    .interval => |b| return .{ .timestamptz = try temporal.timestamptzPlus(a, if (op == .sub) try temporal.negateInterval(b) else b, &session.zone) },
                    .timestamptz => |b| return .{ .interval = try temporal.timestampDifference(a, b) },
                    else => {},
                },
                .interval => |a| switch (right.*) {
                    .interval => |b| return .{ .interval = try temporal.addIntervals(a, if (op == .sub) try temporal.negateInterval(b) else b) },
                    .timestamp => |b| return .{ .timestamp = try temporal.timestampPlus(b, a) },
                    .timestamptz => |b| return .{ .timestamptz = try temporal.timestamptzPlus(b, a, &session.zone) },
                    else => {},
                },
                else => {},
            }
            return error.UndefinedFunction;
        }

        pub fn negate(cell: *const V.Cell, ty: Type) Error!V.Cell {
            return switch (cell.*) {
                .integer => |value| blk: {
                    if (value == -9223372036854775808) return error.IntegerOverflow;
                    break :blk .{ .integer = try checkedInteger(-value, ty) };
                },
                .numeric => |value| .{ .numeric = N.negate(value) },
                .float4 => |value| .{ .float4 = -value },
                .float8 => |value| .{ .float8 = -value },
                .interval => |value| .{ .interval = try temporal.negateInterval(value) },
                else => error.UndefinedFunction,
            };
        }

        /// AT TIME ZONE: timestamptz -> timestamp in the zone, timestamp ->
        /// timestamptz interpreting it as local time in the zone.
        pub fn atZone(cell: *const V.Cell, zone_name: []const u8, session: *const Session) Error!V.Cell {
            var zone: temporal.Zone = .{};
            try resolveZone(zone_name, session, &zone);
            return switch (cell.*) {
                .timestamptz => |value| .{ .timestamp = if (temporal.finiteTimestamp(value)) temporal.toLocal(&zone, value) else value },
                .timestamp => |value| .{ .timestamptz = if (temporal.finiteTimestamp(value)) try temporal.toUtc(&zone, value) else value },
                else => error.UndefinedFunction,
            };
        }

        pub fn resolveZone(name: []const u8, session: *const Session, zone: *temporal.Zone) Error!void {
            if (types.keyword(name, "utc") or types.keyword(name, "gmt") or types.keyword(name, "z") or types.keyword(name, "zulu")) {
                zone.* = .{};
                return;
            }
            const lookup = session.resolver.lookup orelse return error.InvalidParameterValue;
            lookup(session.resolver.context, name, zone) catch return error.InvalidParameterValue;
        }
    };
}
