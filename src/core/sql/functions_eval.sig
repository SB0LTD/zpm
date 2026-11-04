//! Evaluation of the B11 builtin function families (Layer 0).
//!
//! `Builtins(config, E)` is instantiated by expr.sig's `Eval` (`E`); it
//! evaluates the bound argument list left to right (PostgreSQL evaluates
//! every argument before applying a strict function's NULL rule), then calls
//! the allocator-free kernels in functions_string.sig and friends. A planned
//! NULL call (a syntactic NULL argument, see binder.bindSignature) returns
//! NULL without executing its arguments.
const types = @import("types.sig");
const ast = @import("ast.sig");
const strings = @import("functions_string.sig");
const numeric = @import("numeric.sig");
const numeric_math = @import("numeric_math.sig");
const float_text = @import("float_text.sig");
const temporal = @import("temporal.sig");
const times = @import("functions_temporal.sig");
const formats = @import("functions_format.sig");
const unicode = @import("functions_unicode.sig");
const std = @import("std");
const Error = types.Error;
const none = ast.none;

pub fn Builtins(comptime config: types.Config, comptime E: type) type {
    const V = types.Values(config);
    return struct {
        const max_args = 6;

        fn node(ctx: *const E.Context, id: u16) *const ast.Node {
            return &ctx.pool.nodes[id];
        }

        /// Evaluates every argument; true when one is NULL (strict result).
        fn arguments(ctx: *const E.Context, n: *const ast.Node, cells: *[max_args]V.Cell) Error!bool {
            var any_null = false;
            var item = n.b;
            var index: usize = 0;
            while (item != none) : (item = node(ctx, item).next) {
                if (index == max_args) return error.UndefinedFunction;
                cells[index] = try E.eval(ctx, item);
                if (cells[index] == .null_value) any_null = true;
                index += 1;
            }
            return any_null;
        }

        /// The bytes of a bound text argument (CHAR(n) keeps its padding).
        fn textOf(cell: *const V.Cell) []const u8 {
            return switch (cell.*) {
                .bpchar => |*value| value.slice(),
                else => cell.text.slice(),
            };
        }

        fn int32Of(cell: *const V.Cell) i32 {
            return @intCast(cell.integer);
        }

        fn textCell(bytes: []const u8) Error!V.Cell {
            if (bytes.len > config.text_bytes) return error.TextCapacity;
            var text: V.Text = .{ .len = bytes.len };
            @memcpy(text.bytes[0..bytes.len], bytes);
            return .{ .text = text };
        }

        pub fn call(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            if (n.planned_null) return .null_value;
            const control = ctx.session.control;
            switch (n.func) {
                .concat, .concat_ws => return concat(ctx, n),
                .overlaps, .overlaps_tz => return overlaps(ctx, n),
                else => {},
            }
            var cells: [max_args]V.Cell = undefined;
            if (try arguments(ctx, n, &cells)) return .null_value;
            var result: V.Text = .{};
            var out: strings.Out = .{ .bytes = &result.bytes };
            const count = argumentCount(ctx, n);
            switch (n.func) {
                .lower => try strings.mapCase(textOf(&cells[0]), .lower, &out, control),
                .upper => try strings.mapCase(textOf(&cells[0]), .upper, &out, control),
                .initcap => try strings.mapCase(textOf(&cells[0]), .initcap, &out, control),
                .char_length => return .{ .integer = @intCast(try strings.charLength(textOf(&cells[0]), control)) },
                .octet_length => return .{ .integer = @intCast(textOf(&cells[0]).len) },
                .bit_length => return .{ .integer = @as(i64, @intCast(textOf(&cells[0]).len)) * 8 },
                .ascii => return .{ .integer = strings.ascii(textOf(&cells[0])) },
                .substring => return textCell(try strings.substring(textOf(&cells[0]), cells[1].integer, if (count == 3) cells[2].integer else null, control)),
                .btrim, .ltrim, .rtrim => {
                    const set = if (count == 2) textOf(&cells[1]) else " ";
                    return textCell(try strings.trim(textOf(&cells[0]), set, n.func != .rtrim, n.func != .ltrim, control));
                },
                .strpos => return .{ .integer = try strings.position(textOf(&cells[0]), textOf(&cells[1]), control) },
                .starts_with => return .{ .boolean = strings.startsWith(textOf(&cells[0]), textOf(&cells[1])) },
                .replace => try strings.replace(textOf(&cells[0]), textOf(&cells[1]), textOf(&cells[2]), &out, control),
                .translate => try strings.translate(textOf(&cells[0]), textOf(&cells[1]), textOf(&cells[2]), &out, control),
                .left => return textCell(try strings.left(textOf(&cells[0]), int32Of(&cells[1]), control)),
                .right => return textCell(try strings.right(textOf(&cells[0]), int32Of(&cells[1]), control)),
                .repeat => try strings.repeat(textOf(&cells[0]), int32Of(&cells[1]), &out, control),
                .reverse => try strings.reverse(textOf(&cells[0]), &out, control),
                .lpad, .rpad => try strings.pad(textOf(&cells[0]), int32Of(&cells[1]), if (count == 3) textOf(&cells[2]) else " ", n.func == .lpad, &out, control),
                .split_part => return textCell(try strings.splitPart(textOf(&cells[0]), textOf(&cells[1]), int32Of(&cells[2]), control)),
                .chr => try strings.chr(cells[0].integer, &out),
                .overlay => {
                    const placing = textOf(&cells[1]);
                    const length: i32 = if (count == 4) int32Of(&cells[3]) else @intCast(try strings.charLength(placing, control));
                    try strings.overlay(textOf(&cells[0]), placing, int32Of(&cells[2]), length, &out, control);
                },
                .to_hex => try strings.toHex(cells[0].integer, if (node(ctx, n.b).ty == .int8) 64 else 32, &out),
                .power, .ln, .log, .log10, .exp, .mod, .div, .pi, .degrees, .radians, .cbrt, .sin, .cos, .tan, .cot, .asin, .acos, .atan, .atan2,
                .gcd, .lcm, .scale, .min_scale, .trim_scale => return mathematical(n, &cells, count, control),
                .extract, .extract_tz, .date_part, .date_part_tz, .date_trunc, .date_trunc_tz, .age, .age_tz, .justify_days, .justify_hours,
                .justify_interval, .make_date, .make_timestamp, .isfinite => return temporalValue(ctx, n, &cells, count),
                .to_date, .to_number, .to_timestamp => return formatValue(ctx, n, &cells, count),
                .normalize, .is_normalized => {
                    const form = if (count == 2) unicode.formOf(textOf(&cells[1])) orelse return error.InvalidParameterValue else .nfc;
                    const input = textOf(&cells[0]);
                    if (n.func == .normalize) {
                        result.len = try unicode.normalize(input, form, &result.bytes, control);
                        return .{ .text = result };
                    }
                    // A form longer than the buffer cannot equal the input.
                    const length = unicode.normalize(input, form, &result.bytes, control) catch |err| {
                        if (err == error.TextCapacity) return .{ .boolean = false };
                        return err;
                    };
                    return .{ .boolean = length == input.len and types.same(result.bytes[0..length], input) };
                },
                else => unreachable,
            }
            result.len = out.len;
            return .{ .text = result };
        }

        const M = numeric_math.Math(config.numeric_digits);
        const NOps = numeric.Ops(config.numeric_digits);

        fn node_numeric(cells: *const [max_args]V.Cell) bool {
            return cells[0] == .numeric;
        }

        /// check_float8_val: an infinite result from finite input overflows,
        /// a zero result from non-zero input underflows (22003).
        fn checked(result: f64, input_infinite: bool, may_be_zero: bool) Error!V.Cell {
            if (float_text.isInf(result) and !input_infinite) return error.NumericValueOutOfRange;
            if (result == 0 and !may_be_zero) return error.NumericValueOutOfRange;
            return .{ .float8 = result };
        }

        fn nan() f64 {
            return float_text.nan(f64);
        }

        /// dpow.
        fn powFloat(x: f64, y: f64) Error!V.Cell {
            if (x != x) return .{ .float8 = if (y != y or y != 0) nan() else 1 };
            if (y != y) return .{ .float8 = if (x != 1) nan() else 1 };
            if (x == 0 and y < 0) return error.InvalidArgumentForPowerFunction;
            if (x < 0 and @floor(y) != y) return error.InvalidArgumentForPowerFunction;
            if (float_text.isInf(y)) {
                const magnitude = @abs(x);
                if (magnitude == 1) return .{ .float8 = 1 };
                if (y > 0) return .{ .float8 = if (magnitude > 1) y else 0 };
                return .{ .float8 = if (magnitude > 1) 0 else -y };
            }
            if (float_text.isInf(x)) {
                if (y == 0) return .{ .float8 = 1 };
                if (x > 0) return .{ .float8 = if (y > 0) x else 0 };
                const half = y / 2;
                const odd = @floor(half) != half;
                if (y > 0) return .{ .float8 = if (odd) x else -x };
                return .{ .float8 = if (odd) -0.0 else 0.0 };
            }
            const odd = @abs(y) < 9007199254740992 and @rem(y, 2) != 0;
            if (x == 0) {
                if (y == 0) return .{ .float8 = 1 };
                const negative_zero = odd and @as(u64, @bitCast(x)) >> 63 != 0;
                return .{ .float8 = if (negative_zero) -0.0 else 0.0 };
            }
            return .{ .float8 = try numeric_math.Doubles.pow(x, y, x < 0 and odd) };
        }

        fn logFloat(x: f64, base10: bool) Error!V.Cell {
            if (x == 0) return error.InvalidArgumentForLogarithm;
            if (x < 0) return error.InvalidArgumentForLogarithm;
            if (x != x or float_text.isInf(x)) return .{ .float8 = x };
            return .{ .float8 = if (base10) try numeric_math.Doubles.log10(x) else try numeric_math.Doubles.ln(x) };
        }

        /// dsin/dcos/dtan/dcot: NaN passes through, infinities are 22003.
        fn trigonometric(func: ast.Func, x: f64) Error!V.Cell {
            if (x != x) return .{ .float8 = nan() };
            if (float_text.isInf(x)) return error.NumericValueOutOfRange;
            const result = switch (func) {
                .sin => @sin(x),
                .cos => @cos(x),
                .tan => @tan(x),
                .cot => 1.0 / @tan(x),
                else => unreachable,
            };
            if (func != .cot and func != .tan and float_text.isInf(result)) return error.NumericValueOutOfRange;
            return .{ .float8 = result };
        }

        fn integerGcd(a: i64, b: i64, ty: ast.Type, control: strings.Control) Error!i128 {
            var x: i128 = if (a < 0) -@as(i128, a) else a;
            var y: i128 = if (b < 0) -@as(i128, b) else b;
            while (y != 0) {
                if (control) |active| try active.checkpoint();
                const t = @rem(x, y);
                x = y;
                y = t;
            }
            const high: i128 = if (ty == .int8) 9223372036854775807 else 2147483647;
            if (x > high) return error.IntegerOverflow;
            return x;
        }

        fn mathematical(n: *const ast.Node, cells: *const [max_args]V.Cell, count: usize, control: strings.Control) Error!V.Cell {
            // One-argument numeric overloads; log(x) is log(10, x).
            const unary_numeric = count == 1 and node_numeric(cells);
            if (unary_numeric) {
                const value = &cells[0].numeric;
                switch (n.func) {
                    .ln => return .{ .numeric = try M.ln(value, control) },
                    .log, .log10 => {
                        const base = M.make(10, 0) catch return error.NumericCapacity;
                        return .{ .numeric = try M.log(&base, value, control) };
                    },
                    .exp => return .{ .numeric = try M.exp(value, control) },
                    .scale => return if (value.special != .finite) .null_value else .{ .integer = value.dscale },
                    .min_scale => return if (M.minScale(value)) |scale| .{ .integer = scale } else .null_value,
                    .trim_scale => return .{ .numeric = M.trimScale(value) },
                    else => {},
                }
            }
            switch (n.func) {
                .power => return if (n.ty == .numeric) .{ .numeric = try M.power(&cells[0].numeric, &cells[1].numeric, control) } else powFloat(cells[0].float8, cells[1].float8),
                .log => if (count == 2) return .{ .numeric = try M.log(&cells[0].numeric, &cells[1].numeric, control) },
                .div => return .{ .numeric = try M.divTrunc(&cells[0].numeric, &cells[1].numeric) },
                .mod => {
                    if (n.ty == .numeric) return .{ .numeric = try NOps.mod(&cells[0].numeric, &cells[1].numeric) };
                    const a = cells[0].integer;
                    const b = cells[1].integer;
                    if (b == 0) return error.DivisionByZero;
                    return .{ .integer = if (b == -1) 0 else @rem(a, b) };
                },
                .gcd, .lcm => {
                    if (n.ty == .numeric) return .{ .numeric = try M.gcdLcm(&cells[0].numeric, &cells[1].numeric, n.func == .lcm, control) };
                    const a = cells[0].integer;
                    const b = cells[1].integer;
                    const divisor = try integerGcd(a, b, n.ty, control);
                    if (n.func == .gcd) return .{ .integer = @intCast(divisor) };
                    if (a == 0 or b == 0) return .{ .integer = 0 };
                    const product = @divTrunc(@as(i128, a), divisor) * @as(i128, b);
                    const magnitude = if (product < 0) -product else product;
                    const high: i128 = if (n.ty == .int8) 9223372036854775807 else 2147483647;
                    if (magnitude > high) return error.IntegerOverflow;
                    return .{ .integer = @intCast(magnitude) };
                },
                .pi => return .{ .float8 = 3.14159265358979323846 },
                else => {},
            }
            const x = cells[0].float8;
            switch (n.func) {
                .ln => return logFloat(x, false),
                .log, .log10 => return logFloat(x, true),
                .exp => {
                    if (x != x) return .{ .float8 = x };
                    if (float_text.isInf(x)) return .{ .float8 = if (x > 0) x else 0 };
                    return .{ .float8 = try numeric_math.Doubles.exp(x) };
                },
                .cbrt => return checked(std.math.cbrt(x), float_text.isInf(x), x == 0),
                .degrees => return checked(x / radians_per_degree, float_text.isInf(x), x == 0),
                .radians => return checked(x * radians_per_degree, float_text.isInf(x), x == 0),
                .sin, .cos, .tan, .cot => return trigonometric(n.func, x),
                .asin, .acos => {
                    if (x != x) return .{ .float8 = x };
                    if (x < -1 or x > 1) return error.NumericValueOutOfRange;
                    return .{ .float8 = if (n.func == .asin) std.math.asin(x) else std.math.acos(x) };
                },
                .atan => return .{ .float8 = if (x != x) x else std.math.atan(x) },
                .atan2 => {
                    const y = cells[1].float8;
                    if (x != x or y != y) return .{ .float8 = nan() };
                    return .{ .float8 = std.math.atan2(x, y) };
                },
                else => unreachable,
            }
        }

        const radians_per_degree: f64 = 0.0174532925199432957692;

        // ---- date/time ------------------------------------------------------

        fn partCell(part: times.Part) Error!V.Cell {
            return switch (part) {
                .integer => |value| .{ .numeric = NOps.fromInt(value) },
                .decimal => |decimal| .{ .numeric = try M.make(decimal.value, decimal.scale) },
                .julian => |julian| blk: {
                    const day = NOps.fromInt(julian.day);
                    const fraction = try NOps.div(&NOps.fromInt(julian.time), &NOps.fromInt(86400000000));
                    break :blk .{ .numeric = try NOps.add(&day, &fraction) };
                },
                .float => |value| .{ .float8 = value },
                .infinity => |positive| .{ .numeric = .{ .special = if (positive) .pinf else .ninf } },
                .none => .null_value,
            };
        }

        /// date_part's double precision form of a part.
        fn floatPart(part: times.Part) V.Cell {
            return switch (part) {
                .integer => |value| .{ .float8 = @floatFromInt(value) },
                .decimal => |decimal| .{ .float8 = @as(f64, @floatFromInt(decimal.value)) / (if (decimal.scale == 3) @as(f64, 1000.0) else 1000000.0) },
                .julian => |julian| .{ .float8 = @as(f64, @floatFromInt(julian.day)) + @as(f64, @floatFromInt(julian.time)) / 1000000.0 / 86400.0 },
                .float => |value| .{ .float8 = value },
                .infinity => |positive| .{ .float8 = if (positive) float_text.inf(f64) else -float_text.inf(f64) },
                .none => .null_value,
            };
        }

        fn offsetSeconds(local: i64, utc: i64) i64 {
            return @divTrunc(local - utc, 1000000);
        }

        fn temporalValue(ctx: *const E.Context, n: *const ast.Node, cells: *const [max_args]V.Cell, count: usize) Error!V.Cell {
            const zone = &ctx.session.zone;
            switch (n.func) {
                .extract, .extract_tz, .date_part, .date_part_tz => {
                    const numeric_result = n.func == .extract or n.func == .extract_tz;
                    const field = times.decodeField(textOf(&cells[0]), true);
                    const part: times.Part = switch (cells[1]) {
                        .date => |days| try times.datePart(field, days),
                        .timestamp => |us| try times.timestampPart(field, us, @as(i128, us) + 946684800000000, null, numeric_result),
                        .timestamptz => |us| blk: {
                            const local = if (temporal.finiteTimestamp(us)) temporal.toLocal(zone, us) else us;
                            break :blk try times.timestampPart(field, local, @as(i128, us) + 946684800000000, offsetSeconds(local, us), numeric_result);
                        },
                        .interval => |span| try times.intervalPart(field, span, numeric_result),
                        else => unreachable,
                    };
                    return if (numeric_result) partCell(part) else floatPart(part);
                },
                .date_trunc, .date_trunc_tz => {
                    const field = times.decodeField(textOf(&cells[0]), false);
                    switch (cells[1]) {
                        .interval => |span| return .{ .interval = try times.truncateInterval(field, span) },
                        .timestamp, .timestamptz => |us| {
                            const zoned = cells[1] == .timestamptz;
                            if (!temporal.finiteTimestamp(us)) {
                                var ignored = false;
                                _ = times.truncate(field, 0, &ignored) catch |err| return err;
                                return cells[1];
                            }
                            const local = if (zoned) temporal.toLocal(zone, us) else us;
                            var whole_days = false;
                            const truncated = try times.truncate(field, local, &whole_days);
                            if (!zoned) return .{ .timestamp = truncated };
                            // Units of a day or more re-resolve the zone offset
                            // (DetermineTimeZoneOffset); smaller ones keep it.
                            const utc = if (whole_days) try temporal.toUtc(zone, truncated) else truncated - (local - us);
                            return .{ .timestamptz = utc };
                        },
                        else => unreachable,
                    }
                },
                .age, .age_tz => {
                    const zoned = n.func == .age_tz and (cells[0] == .timestamptz);
                    var first: i64 = undefined;
                    var second: i64 = undefined;
                    if (count == 1) {
                        // age(x) = age(current_date at midnight, x).
                        const now = ctx.session.transaction_us orelse return error.ClockUnavailable;
                        const today = temporal.timestampToDate(temporal.toLocal(zone, now));
                        const midnight = try temporal.dateToTimestamp(today);
                        first = midnight;
                        second = if (cells[0] == .timestamptz) localOf(zone, cells[0].timestamptz) else cells[0].timestamp;
                    } else if (zoned) {
                        first = localOf(zone, cells[0].timestamptz);
                        second = localOf(zone, cells[1].timestamptz);
                    } else {
                        first = cells[0].timestamp;
                        second = cells[1].timestamp;
                    }
                    return .{ .interval = try times.age(first, second) };
                },
                .justify_days => return .{ .interval = try times.justifyDays(cells[0].interval) },
                .justify_hours => return .{ .interval = try times.justifyHours(cells[0].interval) },
                .justify_interval => return .{ .interval = try times.justifyInterval(cells[0].interval) },
                .make_date => return .{ .date = try times.makeDate(cells[0].integer, cells[1].integer, cells[2].integer) },
                .make_timestamp => return .{ .timestamp = try times.makeTimestamp(cells[0].integer, cells[1].integer, cells[2].integer, cells[3].integer, cells[4].integer, cells[5].float8) },
                .isfinite => return .{ .boolean = switch (cells[0]) {
                    .date => |days| temporal.finiteDate(days),
                    .timestamp, .timestamptz => |us| temporal.finiteTimestamp(us),
                    else => true,
                } },
                else => unreachable,
            }
        }

        /// An OVERLAPS endpoint: the start, or start + interval (SQL form).
        fn endpoint(ctx: *const E.Context, start: *const V.Cell, end: *const V.Cell) Error!?i64 {
            if (end.* == .null_value) return null;
            if (end.* != .interval) return if (end.* == .timestamp) end.timestamp else end.timestamptz;
            if (start.* == .null_value) return null;
            return if (start.* == .timestamp) try temporal.timestampPlus(start.timestamp, end.interval) else try temporal.timestamptzPlus(start.timestamptz, end.interval, &ctx.session.zone);
        }

        fn instant(cell: *const V.Cell) ?i64 {
            return switch (cell.*) {
                .timestamp => |us| us,
                .timestamptz => |us| us,
                else => null,
            };
        }

        /// overlaps_timestamp, including its NULL rules.
        fn overlaps(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            var cells: [4]V.Cell = undefined;
            var item = n.b;
            for (&cells) |*cell| {
                cell.* = try E.eval(ctx, item);
                item = node(ctx, item).next;
            }
            var s1 = instant(&cells[0]);
            var e1 = try endpoint(ctx, &cells[0], &cells[1]);
            var s2 = instant(&cells[2]);
            var e2 = try endpoint(ctx, &cells[2], &cells[3]);
            if (s1 == null) {
                if (e1 == null) return .null_value;
                s1 = e1;
                e1 = null;
            } else if (e1 != null and s1.? > e1.?) {
                const swap = s1;
                s1 = e1;
                e1 = swap;
            }
            if (s2 == null) {
                if (e2 == null) return .null_value;
                s2 = e2;
                e2 = null;
            } else if (e2 != null and s2.? > e2.?) {
                const swap = s2;
                s2 = e2;
                e2 = swap;
            }
            const a = s1.?;
            const b = s2.?;
            if (a > b) {
                const end2 = e2 orelse return .null_value;
                if (a < end2) return .{ .boolean = true };
                if (e1 == null) return .null_value;
                return .{ .boolean = false };
            }
            if (a < b) {
                const end1 = e1 orelse return .null_value;
                if (b < end1) return .{ .boolean = true };
                if (e2 == null) return .null_value;
                return .{ .boolean = false };
            }
            if (e1 == null or e2 == null) return .null_value;
            return .{ .boolean = true };
        }

        /// to_date / to_timestamp / to_number.
        fn formatValue(ctx: *const E.Context, n: *const ast.Node, cells: *const [max_args]V.Cell, count: usize) Error!V.Cell {
            const control = ctx.session.control;
            switch (n.func) {
                .to_date => return .{ .date = try formats.toDate(try formats.parseTimestamp(textOf(&cells[0]), textOf(&cells[1]), control)) },
                .to_timestamp => {
                    if (count == 1) return .{ .timestamptz = try epochTimestamp(cells[0].float8) };
                    const local = try formats.toLocalTimestamp(try formats.parseTimestamp(textOf(&cells[0]), textOf(&cells[1]), control));
                    const utc = try temporal.toUtc(&ctx.session.zone, local);
                    if (!temporal.validTimestamp(utc)) return error.DatetimeFieldOverflow;
                    return .{ .timestamptz = utc };
                },
                .to_number => {
                    // An empty template is NULL (numeric_to_number).
                    if (textOf(&cells[1]).len == 0) return .null_value;
                    var number: formats.Number = .{};
                    try formats.toNumber(textOf(&cells[0]), textOf(&cells[1]), &number, control);
                    const text = number.bytes[0..number.len];
                    var any_digit = false;
                    for (text) |byte| if (byte >= '0' and byte <= '9') {
                        any_digit = true;
                    };
                    if (!any_digit) return error.InvalidTextRepresentation;
                    const parsed = try NOps.parse(text);
                    // numeric_in with typmod (pre + post, post): round, then
                    // the integer digits must fit (22003).
                    const rounded = try NOps.round(&parsed, @intCast(number.post));
                    var whole = rounded.coef() / @as(u256, @intCast(numeric.pow10[rounded.dscale]));
                    var digits: usize = 0;
                    while (whole != 0) : (whole /= 10) digits += 1;
                    if (digits > number.pre) return error.NumericValueOutOfRange;
                    return .{ .numeric = rounded };
                },
                else => unreachable,
            }
        }

        /// float8_timestamptz: Unix seconds to timestamptz (22008 for NaN or
        /// beyond the Julian timestamp range).
        fn epochTimestamp(seconds: f64) Error!i64 {
            if (seconds != seconds) return error.DatetimeFieldOverflow;
            if (float_text.isInf(seconds)) return if (seconds < 0) temporal.timestamp_no_begin else temporal.timestamp_no_end;
            // SECS_PER_DAY * (DATETIME_MIN_JULIAN or TIMESTAMP_END_JULIAN - UNIX_EPOCH_JDATE).
            if (seconds < -210866803200.0 or seconds >= 9224318016000.0) return error.DatetimeFieldOverflow;
            const micros = float_text.rint((seconds - 946684800.0) * 1000000.0);
            const result: i64 = @intFromFloat(micros);
            if (!temporal.validTimestamp(result)) return error.DatetimeFieldOverflow;
            return result;
        }

        fn localOf(zone: *const temporal.Zone, us: i64) i64 {
            return if (temporal.finiteTimestamp(us)) temporal.toLocal(zone, us) else us;
        }

        fn argumentCount(ctx: *const E.Context, n: *const ast.Node) usize {
            var count: usize = 0;
            var item = n.b;
            while (item != none) : (item = node(ctx, item).next) count += 1;
            return count;
        }

        /// concat/concat_ws: NULL arguments are skipped; each value prints
        /// through its output function (booleans as t/f). concat_ws with a
        /// NULL separator is NULL.
        fn concat(ctx: *const E.Context, n: *const ast.Node) Error!V.Cell {
            var result: V.Text = .{};
            var separator: V.Cell = .null_value;
            var item = n.b;
            if (n.func == .concat_ws) {
                separator = try E.eval(ctx, item);
                item = node(ctx, item).next;
            }
            // Every argument is evaluated before the (non-strict) call.
            const null_separator = n.func == .concat_ws and separator == .null_value;
            var first = true;
            while (item != none) : (item = node(ctx, item).next) {
                const cell = try E.eval(ctx, item);
                if (cell == .null_value or null_separator) continue;
                if (!first and n.func == .concat_ws) try E.appendCell(&result, &separator, false, ctx.session);
                try E.appendCell(&result, &cell, false, ctx.session);
                first = false;
            }
            return if (null_separator) .null_value else .{ .text = result };
        }
    };
}
