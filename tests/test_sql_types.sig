//! Value-type contract (design §4.2, Q02/Q03/Q04): NUMERIC, SMALLINT,
//! REAL/DOUBLE, DATE/TIMESTAMP/TIMESTAMPTZ/INTERVAL with zones, JSON/JSONB,
//! typmods, error classes and kind-3 change-record round trips of every new
//! type. Expected strings were measured on PostgreSQL 18 (postgres:18-alpine).
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 3, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 256, .integer_bits = 32, .nulls_first_ascending = false });
const Io = DB.Io;
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlTypesContractFailed;
}

fn first(source: []const u8, buffer: []u8) ![]const u8 {
    try db.execute(source, &result);
    try check(result.row_count == 1 and result.column_count >= 1);
    const cell = &result.rows[0].cells[0];
    if (cell.* == .null_value) return "NULL";
    return Io.format(cell, false, &db.session, buffer);
}

/// SELECT whose single row's columns render to `expected` joined by '|'.
fn row(source: []const u8, expected: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    var out: [2048]u8 = undefined;
    var at: usize = 0;
    try check(result.row_count == 1);
    for (0..result.column_count) |column| {
        if (column != 0) {
            out[at] = '|';
            at += 1;
        }
        const cell = &result.rows[0].cells[column];
        var buffer: [Io.format_bytes]u8 = undefined;
        const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, &db.session, &buffer);
        @memcpy(out[at..][0..text.len], text);
        at += text.len;
    }
    if (!std.mem.eql(u8, out[0..at], expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, out[0..at], expected });
    try check(std.mem.eql(u8, out[0..at], expected));
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
}

fn rounding() !void {
    // Fixtures and overload types checked against native PostgreSQL 18.3.
    try row("SELECT ROUND(2.5),ROUND(-2.5),ROUND(2.55,1),ROUND(-2.55,1),ROUND(1234.56,-1),ROUND(150.0,-2),ROUND(-150.0,-2)","3|-3|2.6|-2.6|1230|200|-200");
    try row("SELECT ROUND(2.5::float8),ROUND(3.5::float8),ROUND(-2.5::float8),ROUND(-3.5::float8),ROUND(-0.5::float8),ROUND(0.5::float8)","2|4|-2|-4|-0|0");
    for(result.column_types[0..result.column_count]) |ty| try check(ty==.double);
    try row("SELECT ROUND(2),ROUND(2::numeric),ROUND('2.5'),ROUND(NULL),ROUND(NULL,2),ROUND(2,2)","2|2|2|NULL|NULL|2.00");
    for([_]@TypeOf(result.column_types[0]){.double,.numeric,.double,.double,.numeric,.numeric},0..) |ty,i| try check(result.column_types[i]==ty);
    try row("SELECT ROUND('NaN'::numeric,2),ROUND('Infinity'::numeric,-2),ROUND('-Infinity'::numeric,2),ROUND('NaN'::float8),ROUND('Infinity'::float8),ROUND('-Infinity'::float8)","NaN|Infinity|-Infinity|NaN|Infinity|-Infinity");
    try row("SELECT ROUND(-0.5::float8),ROUND('-0'::float8),ROUND(-0.1::float8)","-0|-0|-0");
    for(result.rows[0].cells[0..3]) |cell| try check(@as(u64,@bitCast(cell.float8))==0x8000000000000000);
    try row("SELECT ROUND(123.45,-2147483648),ROUND(0.0,-2147483648),ROUND(NULL::numeric,2147483647),ROUND(1.5,NULL)","0|0|NULL|NULL");
    try rejects("SELECT ROUND()",error.UndefinedFunction);
    try rejects("SELECT ROUND(1,2,3)",error.UndefinedFunction);
    try rejects("SELECT ROUND(TRUE)",error.UndefinedFunction);
    try rejects("SELECT ROUND(1.5::float8,2)",error.UndefinedFunction);
    try rejects("SELECT ROUND(1.5,2::bigint)",error.UndefinedFunction);
    try rejects("SELECT ROUND(1.5,2.0)",error.UndefinedFunction);
    try rejects("SELECT ROUND('bad')",error.InvalidTextRepresentation);
    try rejects("SELECT ROUND('bad',2)",error.InvalidTextRepresentation);
    try rejects("SELECT ROUND(1.0,2147483647)",error.NumericCapacity);
    try rejects("SELECT ROUND(9999999999999999999999999999999999999999999999999999999999999999::numeric,120)",error.NumericCapacity);
    var source:[160]u8=undefined;var expected:[80]u8=undefined;
    // An integer quantization model, independent of Numeric.round.
    for(0..2001) |i| {
        const coefficient=@as(i64,@intCast(i))-1000;
        const magnitude=@abs(coefficient);
        const rounded=(magnitude+5)/10;
        const sql_text=try std.fmt.bufPrint(&source,"SELECT ROUND({s}{d}.{d:0>3},2)",.{if(coefficient<0) "-" else "",magnitude/1000,magnitude%1000});
        const wanted=try std.fmt.bufPrint(&expected,"{s}{d}.{d:0>2}",.{if(coefficient<0 and rounded!=0) "-" else "",rounded/100,rounded%100});
        try row(sql_text,wanted);
    }
    // Both signs and every odd/even half-step around zero.
    for(0..129) |i| {
        const lower=@as(i64,@intCast(i))-64;
        try db.execute(try std.fmt.bufPrint(&source,"SELECT ROUND({d}::float8+0.5::float8)",.{lower}),&result);
        const wanted=if(lower&1==0) lower else lower+1;
        try check(result.rows[0].cells[0].float8==@as(f64,@floatFromInt(wanted)));
    }
    try db.execute("SELECT ROUND('4503599627370495.5'::float8),ROUND('-4503599627370495.5'::float8),ROUND('1e308'::float8)",&result);
    try check(result.rows[0].cells[0].float8==4503599627370496.0 and result.rows[0].cells[1].float8 == -4503599627370496.0 and result.rows[0].cells[2].float8==1e308);
    try db.execute("CREATE TABLE rounding_data(id INT PRIMARY KEY,g INT,v NUMERIC)",&result);
    try db.execute("INSERT INTO rounding_data VALUES(1,1,1.235),(2,1,2.345),(3,2,NULL),(4,2,-1.255)",&result);
    try row("SELECT ROUND(AVG(v),2) FROM rounding_data WHERE g=1","1.79");
    try row("SELECT g,ROUND(AVG(v),2) FROM rounding_data GROUP BY g HAVING ROUND(AVG(v),2)>0 ORDER BY g","1|1.79");
    try row("SELECT ROUND(v,g-1) FROM rounding_data WHERE id=4","-1.3");
    try row("SELECT SUM(ROUND(v,1)) FROM rounding_data","2.2");
    const previous=result;
    try rejects("SELECT ROUND(v,2147483647) FROM rounding_data",error.NumericCapacity);
    try check(result.row_count==previous.row_count and result.column_count==previous.column_count and DB.compareCells(&result.rows[0].cells[0],&previous.rows[0].cells[0])==0);
    try check(db.usage().pending_versions==0 and db.usage().transactions==0);
    try db.execute("DROP TABLE rounding_data",&result);
}

fn numeric() !void {
    try row("SELECT 12.34565::numeric(18,4), 1/3::numeric, 10/4::numeric, 1.5*2.25, 2/3.0, 100.0/3", "12.3457|0.33333333333333333333|2.5000000000000000|3.375|0.66666666666666666667|33.3333333333333333");
    try row("SELECT 0.001/7, 123456789/0.001, 1.0 * 1.00, 0.0001 * 0.0001, -1.5 * 0, 1e-10/3", "0.00014285714285714286|123456789000.00000000|1.000|0.00000001|0.0|0.0000000000333333333333333333");
    try row("SELECT -0.0::numeric, '-0'::numeric, 'NaN'::numeric, 'Infinity'::numeric, '-inf'::numeric, 'NaN'::numeric > 'Infinity'::numeric", "0.0|0|NaN|Infinity|-Infinity|t");
    try row("SELECT 99999999999999999999, 1e2, 1.0e1, 5 % 3.0, -7.5 % 2, 123.456::numeric(5,-1)", "99999999999999999999|100|10|2.0|-1.5|120");
    try row("SELECT 2.5::integer, -2.5::integer, 1 + 1.5, 2::bigint * 1.25, 1.5 = 1.50, 1 = 1.0", "3|-3|2.5|2.50|t|t");
    try rejects("SELECT 1000::numeric(5,2)", error.NumericValueOutOfRange);
    try rejects("SELECT 'Infinity'::numeric(5,2)", error.NumericValueOutOfRange);
    try rejects("SELECT 1::numeric(0,0)", error.InvalidParameterValue);
    try rejects("SELECT 1::numeric(70,0)", error.NumericCapacity);
    try rejects("SELECT 1e100", error.NumericCapacity);
    try rejects("SELECT 1.0 / 0", error.DivisionByZero);
    try rejects("SELECT 'abc'::numeric", error.InvalidTextRepresentation);
    try rejects("SELECT 'NaN'::numeric::integer", error.UnsupportedStatement);
    try rejects("SELECT 2147483648.5::integer", error.IntegerOverflow);
    // SMALLINT bounds and promotion.
    try row("SELECT (-32768)::smallint, 1::smallint + 2, 1::smallint + 2::bigint, 32767::smallint", "-32768|3|3|32767");
    try rejects("SELECT 32768::smallint", error.NumericValueOutOfRange);
    try rejects("SELECT 32767::smallint + 1::smallint", error.NumericValueOutOfRange);
    try rejects("SELECT 32767::smallint * 2::smallint", error.NumericValueOutOfRange);
    // Typmod enforcement on storage and NaN ordering.
    try db.execute("CREATE TABLE amounts (id INTEGER PRIMARY KEY, amount NUMERIC(18,4))", &result);
    try db.execute("INSERT INTO amounts VALUES (1, 12.34565)", &result);
    try db.execute("INSERT INTO amounts VALUES (2, 'NaN')", &result);
    try db.execute("INSERT INTO amounts VALUES (3, -5)", &result);
    try check(result.affected_rows == 1);
    try row("SELECT amount FROM amounts WHERE id = 1", "12.3457");
    try db.execute("SELECT id FROM amounts ORDER BY amount DESC", &result);
    try check(result.row_count == 3 and result.rows[0].cells[0].integer == 2 and result.rows[2].cells[0].integer == 3);
    try check(result.column_typmods[0] == -1);
    try db.execute("SELECT amount FROM amounts", &result);
    try check(result.column_types[0] == .numeric and result.column_typmods[0] == (18 << 16 | 4) + 4);
    try db.execute("CREATE TABLE small (id INTEGER PRIMARY KEY, amount NUMERIC(5,2))", &result);
    try rejects("INSERT INTO small VALUES (1, 1000)", error.NumericValueOutOfRange);
    try rejects("INSERT INTO small VALUES (1, 999.999)", error.NumericValueOutOfRange);
    try db.execute("INSERT INTO small VALUES (1, 999.994)", &result);
    try row("SELECT amount, amount * 2, amount / 3, -amount FROM small", "999.99|1999.98|333.3300000000000000|-999.99");
    // Base-10000 wire digits of 12.3457: weight 0, digits {12, 3457}.
    try db.execute("SELECT amount FROM amounts WHERE id = 1", &result);
    const groups = Io.Numerics.toBase10000(&result.rows[0].cells[0].numeric);
    try check(groups.ndigits == 2 and groups.weight == 0 and groups.digits[0] == 12 and groups.digits[1] == 3457);
    const back = try Io.Numerics.fromBase10000(groups.digits[0..groups.ndigits], groups.weight, false, 4);
    try check(sql.Numeric == @TypeOf(back) and Io.Numerics.compare(&back, &result.rows[0].cells[0].numeric) == 0);
}

fn floats() !void {
    try row("SELECT 0.1::float8 + 0.2::float8, 1e15::float8, 1e14::float8, 1e-5::float8, 0.0001::float8, 1.5e-7::float8", "0.30000000000000004|1e+15|100000000000000|1e-05|0.0001|1.5e-07");
    try row("SELECT 1e6::float4, 100000::float4, 1234567.5::float4, 3.4e38::float4, '-0'::float8, 1e100::float8", "1e+06|100000|1.2345675e+06|3.4e+38|-0|1e+100");
    try row("SELECT '0x1p3'::float8, '5.'::float8, '.5'::float8, ' 1.5 '::float8, 'inf'::float8, 'nan'::float8, '-Infinity'::float8", "8|5|0.5|1.5|Infinity|NaN|-Infinity");
    try row("SELECT 2.5::float8::integer, 3.5::float8::integer, (-2.5)::float8::integer, 2.5::float8::numeric, 0.1::float8::numeric, (1.0/3)::float8::numeric", "2|4|-2|2.5|0.1|0.333333333333333");
    try row("SELECT 1.5::float4 + 2.5::float4, 1.5::float4 + 1, 12.5::numeric::float8, 1::float8 = 1.0, 'NaN'::float8 = 'NaN'::float8", "4|2.5|12.5|t|t");
    try rejects("SELECT '1_0'::float8", error.InvalidTextRepresentation);
    try rejects("SELECT ''::float8", error.InvalidTextRepresentation);
    try rejects("SELECT 'x1'::float8", error.InvalidTextRepresentation);
    try rejects("SELECT '1e400'::float8", error.NumericValueOutOfRange);
    try rejects("SELECT '1e-400'::float8", error.NumericValueOutOfRange);
    try rejects("SELECT '1e308'::float8 * 10", error.NumericValueOutOfRange);
    try rejects("SELECT 1::float8 / 0", error.DivisionByZero);
    try rejects("SELECT 1.5::float8 % 1", error.UndefinedFunction);
    try rejects("SELECT 'NaN'::float8::integer", error.IntegerOverflow);
    try row("SELECT '4e-320'::float8", "4e-320");
}

fn fakeClock() ?i64 {
    return 830000000000000; // 2026-04-20 11:33:20 UTC in PostgreSQL-epoch microseconds
}

fn temporals() !void {
    db.session = .{};
    try row("SELECT '2026-10-22T12:00:00Z'::timestamptz, '2026-10-22 12:00'::timestamp, DATE '2026-01-31', '2026-01-01 12:34:56.123456789'::timestamp", "2026-10-22 12:00:00+00|2026-10-22 12:00:00|2026-01-31|2026-01-01 12:34:56.123457");
    try row("SELECT 'infinity'::timestamp, '-infinity'::timestamptz, 'epoch'::timestamp, 'epoch'::timestamptz, 'infinity'::date", "infinity|-infinity|1970-01-01 00:00:00|1970-01-01 00:00:00+00|infinity");
    try row("SELECT '2026-01-01 12:34:56.5555'::timestamp(3), '2026-01-01 12:34:56.9995'::timestamp(3), timestamp(7) '2026-01-01', '0001-01-01 BC'::date", "2026-01-01 12:34:56.556|2026-01-01 12:34:57|2026-01-01 00:00:00|0001-01-01 BC");
    try row("SELECT '1 year 2 mons 3 days 04:05:06.5'::interval, '-1 day 2 hours'::interval, '1 day -2 hours'::interval, '-1 year -2 mons'::interval, '25 hours'::interval, '0'::interval, '1.5 days'::interval", "1 year 2 mons 3 days 04:05:06.5|-1 days +02:00:00|1 day -02:00:00|-1 years -2 mons|25:00:00|00:00:00|1 day 12:00:00");
    try row("SELECT date '2026-01-31' + 1, date '2026-03-01' - date '2026-01-01', date '2026-01-31' + interval '1 month', timestamp '2026-01-31 10:00' + interval '1 month 2 hours', timestamp '2026-01-02 03:00' - timestamp '2026-01-01'", "2026-02-01|59|2026-02-28 00:00:00|2026-02-28 12:00:00|1 day 03:00:00");
    try row("SELECT timestamptz '2026-10-22 12:00:00+02' AT TIME ZONE 'UTC', '2026-10-22 12:00:00+05:30:15'::timestamptz, -interval '1 day'", "2026-10-22 10:00:00|2026-10-22 06:29:45+00|-1 days");
    try rejects("SELECT '294277-01-01'::timestamp", error.DatetimeFieldOverflow);
    try rejects("SELECT '2026-13-01'::date", error.DatetimeFieldOverflow);
    try rejects("SELECT '2026-02-30'::date", error.DatetimeFieldOverflow);
    try rejects("SELECT '5874898-01-01'::date", error.DatetimeFieldOverflow);
    try rejects("SELECT 'garbage'::date", error.InvalidDatetimeFormat);
    try rejects("SELECT 'garbage'::interval", error.InvalidDatetimeFormat);
    try rejects("SELECT '2026-01-01 12:00 Mars/Base'::timestamptz", error.InvalidSettingValue);
    // Exact text/error oracle captured from native PostgreSQL 16.15 (UTC).
    try rejects("SELECT '294277-06-01'::timestamp", error.DatetimeFieldOverflow);
    try rejects("SELECT '300000-01-01'::date::timestamp", error.DatetimeFieldOverflow);
    try rejects("SELECT '300000-01-01'::date::timestamptz", error.DatetimeFieldOverflow);
    try rejects("SELECT timestamp '294276-12-31' + interval '1 month'", error.DatetimeFieldOverflow);
    try rejects("SELECT timestamptz '294276-12-31 00:00:00+00' + interval '1 month'", error.DatetimeFieldOverflow);
    try rejects("SELECT date 'infinity' - date 'infinity'", error.DatetimeFieldOverflow);
    try rejects("SELECT date '-infinity' - date '2000-01-01'", error.DatetimeFieldOverflow);
    try rejects("SELECT date '2000-01-01' - date 'infinity'", error.DatetimeFieldOverflow);
    try rejects("SELECT date '2000-01-01' + 1::bigint", error.UndefinedFunction);
    try rejects("SELECT 1::bigint + date '2000-01-01'", error.UndefinedFunction);
    try rejects("SELECT date '2000-01-01' - 1::bigint", error.UndefinedFunction);
    try rejects("SELECT date '2000-01-01' - (-2147483648)::integer", error.DatetimeFieldOverflow);
    try row("SELECT (date '5874897-12-31' - date '4714-11-24 BC')::text, (date '4714-11-24 BC' - date '5874897-12-31')::text", "2147483493|-2147483493");
    try row("SELECT ('294276-12-31 23:59:59.999999'::timestamp(0))::text, ('4714-11-24 00:00:00.000001 BC'::timestamp(0))::text", "294277-01-01 00:00:00|4714-11-24 00:00:00 BC");
    try row("SELECT ('294277-01-01 00:00:00+01'::timestamptz)::text, (date 'infinity' + 1)::text, (date '-infinity' - 1)::text", "294276-12-31 23:00:00+00|infinity|-infinity");
    try row("SELECT 1", "1");
    try rejects("SELECT '9223372036854.9999999 seconds'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '9223372036854775807.9 microseconds'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '-9223372036854775807.9 microseconds ago'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '9223372036854776 milliseconds'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '153722867281 minutes'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '2562047789 hours'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '2147483648 days'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT '2147483648 months'::interval", error.IntervalFieldOverflow);
    try rejects("SELECT -interval '-2147483648 months'", error.DatetimeFieldOverflow);
    try rejects("SELECT interval '2147483647 months' + interval '1 month'", error.DatetimeFieldOverflow);
    try row("SELECT '-9223372036854775807.9 microseconds'::interval::text, '9223372036854775807 microseconds'::interval::text", "-2562047788:00:54.775808|2562047788:00:54.775807");
    try row("SELECT 1", "1");
    try rejects("SELECT '294277-01-09 04:00:54.775807-15:59'::timestamptz", error.DatetimeFieldOverflow);
    // Zones: fixed offset (east) and a POSIX DST rule.
    db.session.zone = .{ .kind = .fixed, .offset = 5 * 3600 + 1800 };
    try row("SELECT '2026-10-22T12:00:00Z'::timestamptz, '2026-10-22 12:00'::timestamptz", "2026-10-22 17:30:00+05:30|2026-10-22 12:00:00+05:30");
    const rule = try sql.tzif.parsePosix("EST5EDT,M3.2.0,M11.1.0");
    try check(rule.std_offset == -5 * 3600 and rule.dst_offset == -4 * 3600 and rule.has_dst);
    db.session.zone = .{ .kind = .posix, .posix = rule };
    // Spring-forward gap (offset before the transition) and fall-back overlap
    // (offset after it), PostgreSQL docs Appendix B.1.
    try row("SELECT '2026-03-08 02:30'::timestamptz, '2026-11-01 01:30'::timestamptz, '2026-10-22T12:00:00Z'::timestamptz", "2026-03-08 03:30:00-04|2026-11-01 01:30:00-05|2026-10-22 08:00:00-04");
    try row("SELECT '2026-03-08 01:00'::timestamptz + interval '1 day', '2026-03-08 01:00'::timestamptz + interval '24 hours'", "2026-03-09 01:00:00-04|2026-03-09 02:00:00-04");
    const fixed = try sql.tzif.parsePosix("<+05>-05");
    try check(!fixed.has_dst and fixed.std_offset == 5 * 3600);
    const posix_west = try sql.tzif.parsePosix("UTC+3");
    try check(posix_west.std_offset == -3 * 3600);
    try check(if (sql.tzif.parsePosix("EST5EDT,M13.1.0,M11.1.0")) |_| false else |_| true);
    db.session = .{};
    // Clocks: unavailable fails with 0A000; a clock gives transaction time.
    try rejects("SELECT now()", error.ClockUnavailable);
    db.session.transaction_us = fakeClock();
    db.session.statement_us = fakeClock();
    db.session.clock = &fakeClock;
    try row("SELECT now(), CURRENT_TIMESTAMP, now() = statement_timestamp(), clock_timestamp(), CURRENT_DATE", "2026-04-20 11:33:20+00|2026-04-20 11:33:20+00|t|2026-04-20 11:33:20+00|2026-04-20");
    db.session = .{};
    // Storage with typmod rounding.
    try db.execute("CREATE TABLE events (id INTEGER PRIMARY KEY, at TIMESTAMPTZ(3), day DATE, span INTERVAL)", &result);
    try db.execute("INSERT INTO events VALUES (1, '2026-10-22 12:00:00.12345Z', '2026-10-22', '1 day 2 hours')", &result);
    try row("SELECT at, day, span FROM events", "2026-10-22 12:00:00.123+00|2026-10-22|1 day 02:00:00");
}

/// Exercise every candidate timestamp year against wide-integer range math.
/// This is independent of the checked-i64 implementation under test.
fn temporalRangeProperties() !void {
    const t = sql.temporal;
    var text_buffer: [96]u8 = undefined;
    const zone: t.Zone = .{};
    var year: i64 = -4713;
    while (year <= 294277) : (year += 1) {
        const day = t.dateOf(year, 12, 31);
        const wide = @as(i128, day) * t.usecs_per_day;
        const valid = wide >= t.min_timestamp and wide < t.end_timestamp;
        const source = try std.fmt.bufPrint(&text_buffer, "{d:0>4}-12-31{s}", .{ @as(u64, @intCast(if (year <= 0) 1 - year else year)), if (year <= 0) " BC" else "" });
        const parsed = t.parseTimestamp(source, .timestamp, &zone, .{});
        const cast = t.dateToTimestamp(@intCast(day));
        if (valid) {
            const expected: i64 = @intCast(wide);
            const actual = parsed catch |err| {
                std.debug.print("range property {s}: {s}\n", .{ source, @errorName(err) });
                return err;
            };
            try check(actual == expected);
            try check(try cast == expected);
            const next = @as(i128, t.dateOf(year + 1, 1, 31)) * t.usecs_per_day;
            const added = t.timestampPlus(expected, .{ .months = 1 });
            if (next >= t.min_timestamp and next < t.end_timestamp) {
                try check(try added == @as(i64, @intCast(next)));
            } else if (added) |_| return error.InvalidSqlAccepted else |err| try check(err == error.DatetimeFieldOverflow);
        } else {
            if (parsed) |_| return error.InvalidSqlAccepted else |err| try check(err == error.DatetimeFieldOverflow);
            if (cast) |_| return error.InvalidSqlAccepted else |err| try check(err == error.DatetimeFieldOverflow);
        }
    }
    const west: t.Zone = .{ .kind = .fixed, .offset = -12 * 3600 };
    if (t.toUtc(&west, 9223372036854775807)) |_| return error.InvalidSqlAccepted else |err| try check(err == error.DatetimeFieldOverflow);
    for ([_]i64{ -9223372036854775808, 9223372036854775807 }) |delta| {
        if (t.datePlusDays(1, delta)) |_| return error.InvalidSqlAccepted else |err| try check(err == error.DatetimeFieldOverflow);
    }
}

/// A minimal TZif v2 file: two types (EST/EDT), two transitions in 2026,
/// footer EST5EDT rule.
fn syntheticZone(out: []u8) []const u8 {
    var at: usize = 0;
    const put = struct {
        fn bytes(buffer: []u8, position: *usize, value: []const u8) void {
            @memcpy(buffer[position.*..][0..value.len], value);
            position.* += value.len;
        }
        fn be32(buffer: []u8, position: *usize, value: u32) void {
            const b = [4]u8{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
            bytes(buffer, position, &b);
        }
        fn be64(buffer: []u8, position: *usize, value: i64) void {
            const bits: u64 = @bitCast(value);
            be32(buffer, position, @truncate(bits >> 32));
            be32(buffer, position, @truncate(bits));
        }
    };
    // v1 header with one type and no transitions.
    put.bytes(out, &at, "TZif2");
    put.bytes(out, &at, &([_]u8{0} ** 15));
    for ([_]u32{ 0, 0, 0, 0, 1, 4 }) |count| put.be32(out, &at, count);
    put.be32(out, &at, @bitCast(@as(i32, -18000)));
    put.bytes(out, &at, &.{ 0, 0 });
    put.bytes(out, &at, "EST\x00");
    // v2 header: 2 transitions, 2 types, 8 abbreviation bytes.
    put.bytes(out, &at, "TZif2");
    put.bytes(out, &at, &([_]u8{0} ** 15));
    for ([_]u32{ 0, 0, 0, 2, 2, 8 }) |count| put.be32(out, &at, count);
    put.be64(out, &at, 1772953200); // 2026-03-08 07:00 UTC
    put.be64(out, &at, 1793512800); // 2026-11-01 06:00 UTC
    put.bytes(out, &at, &.{ 1, 0 });
    put.be32(out, &at, @bitCast(@as(i32, -18000)));
    put.bytes(out, &at, &.{ 0, 0 });
    put.be32(out, &at, @bitCast(@as(i32, -14400)));
    put.bytes(out, &at, &.{ 1, 4 });
    put.bytes(out, &at, "EST\x00EDT\x00");
    put.bytes(out, &at, "\nEST5EDT,M3.2.0,M11.1.0\n");
    return out[0..at];
}

fn tzif() !void {
    var buffer: [512]u8 = undefined;
    const bytes = syntheticZone(&buffer);
    try sql.tzif.validate(bytes);
    db.session = .{ .zone = .{ .kind = .tzif, .bytes = bytes } };
    try row("SELECT '2026-03-08 02:30'::timestamptz, '2026-11-01 01:30'::timestamptz, '2026-07-01T12:00:00Z'::timestamptz, '2026-01-01T12:00:00Z'::timestamptz", "2026-03-08 03:30:00-04|2026-11-01 01:30:00-05|2026-07-01 08:00:00-04|2026-01-01 07:00:00-05");
    // Beyond the last transition the footer rule applies.
    try row("SELECT '2030-07-01T12:00:00Z'::timestamptz, '2030-12-01T12:00:00Z'::timestamptz", "2030-07-01 08:00:00-04|2030-12-01 07:00:00-05");
    try row("SELECT '2026-07-01 12:00'::timestamp AT TIME ZONE 'UTC'", "2026-07-01 08:00:00-04");
    db.session = .{};
    // Corruptions fail closed.
    var broken: [512]u8 = undefined;
    @memcpy(broken[0..bytes.len], bytes);
    broken[0] = 'X';
    try check(if (sql.tzif.validate(broken[0..bytes.len])) |_| false else |_| true);
    @memcpy(broken[0..bytes.len], bytes);
    broken[4] = '1';
    try check(if (sql.tzif.validate(broken[0..bytes.len])) |_| false else |_| true);
    try check(if (sql.tzif.validate(bytes[0 .. bytes.len - 30])) |_| false else |_| true);
    for (0..bytes.len) |index| {
        // Every truncation is rejected or still structurally valid; never a crash.
        _ = sql.tzif.validate(bytes[0..index]) catch {};
        assertions += 1;
    }
}

fn json() !void {
    try row("SELECT '{\"b\": 1, \"a\": [1, 2.50, {\"c\": null}], \"aa\": \"x\", \"a\": true}'::jsonb, '{\"b\":1,\"a\":2,\"a\":3}'::json", "{\"a\": true, \"b\": 1, \"aa\": \"x\"}|{\"b\":1,\"a\":2,\"a\":3}");
    try row("SELECT '{\"kind\":\"event\"}'::jsonb ->> 'kind', '{\"a\":{\"b\":[10,20,30]}}'::jsonb -> 'a' -> 'b' -> -1, '[1,2,3]'::jsonb -> 5, '{\"a\":1}'::jsonb -> 'z'", "event|30|NULL|NULL");
    try row("SELECT 'null'::jsonb IS NULL, '{\"a\":null}'::jsonb ->> 'a' IS NULL, '{\"a\":null}'::jsonb -> 'a'", "f|t|null");
    try row("SELECT '\"\\u00e9\"'::jsonb, '\"\\ud83d\\ude00\"'::jsonb, '\"\\u00e9\"'::json, '\"a\\tb\\\"c\\\\d\\u0001\"'::jsonb", "\"\u{e9}\"|\"\u{1f600}\"|\"\\u00e9\"|\"a\\tb\\\"c\\\\d\\u0001\"");
    try row("SELECT '1.0'::jsonb, '1e2'::jsonb, '-0'::jsonb, '1.50E-3'::jsonb, '[]'::jsonb, '{}'::jsonb, ' [ 1 , \"x\" ] '::jsonb", "1.0|100|0|0.00150|[]|{}|[1, \"x\"]");
    try row("SELECT '{\"a\":1,\"b\":{\"c\":2}}'::jsonb @> '{\"b\":{\"c\":2}}', '{\"a\":1}'::jsonb <@ '{\"a\":1,\"b\":2}', '{\"a\":1,\"b\":2}'::jsonb ? 'b', '[\"x\",\"y\"]'::jsonb ? 'y', '[1,[2,3]]'::jsonb @> '[[3]]', '[1,2]'::jsonb @> '1', '1'::jsonb @> '[1]'", "t|t|t|t|t|t|f");
    try row("SELECT '{\"a\":{\"b\":[\"x\",\"y\"]}}'::jsonb #> '{a,b,1}', '{\"a\":{\"b\":[\"x\",\"y\"]}}'::jsonb #>> '{a,b,0}', '{\"a\":1}'::jsonb #> '{}', '{\"a\":1}'::jsonb #> '{a,z}'", "\"y\"|x|{\"a\": 1}|NULL");
    try row("SELECT '{\"a\":1,\"b\":2}'::jsonb = '{\"b\":2,\"a\":1}'::jsonb, '1'::jsonb = '1.0'::jsonb, '[1,2]'::jsonb < '[1,3]'::jsonb, '[]'::jsonb < 'null'::jsonb, 'true'::jsonb < '[1]'::jsonb", "t|t|t|t|t");
    try row("SELECT jsonb_typeof('{}'), jsonb_typeof('[]'), jsonb_typeof('1'), jsonb_typeof('\"s\"'), jsonb_typeof('true'), jsonb_typeof('null'), jsonb_array_length('[1,2,3]')", "object|array|number|string|boolean|null|3");
    try rejects("SELECT '\"\\u0000\"'::jsonb", error.UntranslatableCharacter);
    try rejects("SELECT '{\"a\":}'::jsonb", error.InvalidTextRepresentation);
    try rejects("SELECT '[1,2'::json", error.InvalidTextRepresentation);
    try rejects("SELECT '\"\\ud83d\"'::jsonb", error.InvalidTextRepresentation);
    try rejects("SELECT jsonb_array_length('{}')", error.InvalidParameterValue);
    try rejects("SELECT '{\"a\":1}' -> 'a'", error.AmbiguousFunction);
    try rejects("SELECT '{\"a\":1}'::json = '{\"a\":1}'::json", error.UndefinedFunction);
    try rejects("SELECT '1'::jsonb + 1", error.UndefinedFunction);
    var deep: [200]u8 = undefined;
    @memset(deep[0..70], '[');
    @memset(deep[70..140], ']');
    var source: [256]u8 = undefined;
    const statement = try std.fmt.bufPrint(&source, "SELECT '{s}'::json", .{deep[0..140]});
    try rejects(statement, error.StatementTooComplex);
    // Canonical binary validation (change-record replay).
    try db.execute("SELECT '{\"b\":[1,\"x\"],\"a\":null}'::jsonb", &result);
    const canonical = result.rows[0].cells[0].jsonb.slice();
    try check(validJsonb(canonical));
    var flipped: [256]u8 = undefined;
    @memcpy(flipped[0..canonical.len], canonical);
    flipped[3] +%= 1;
    try check(!validJsonb(flipped[0..canonical.len]));
    try check(!validJsonb(canonical[0 .. canonical.len - 1]));
}

/// Replays a change record carrying `bytes` as a JSONB value (exercises
/// the replay validator).
fn validJsonb(bytes: []const u8) bool {
    return replayAccepts(bytes);
}

fn replayAccepts(bytes: []const u8) bool {
    var source: DB = .{};
    var r: DB.Result = .{};
    var record: [1024]u8 = undefined;
    var used: usize = 0;
    source.execute("CREATE TABLE j (id INTEGER PRIMARY KEY, doc JSONB)", &r) catch return false;
    source.executeChanges("INSERT INTO j VALUES (1, '{}')", &r, &record, &used, null, null) catch return false;
    // Patch the encoded document with `bytes` (same layout: tag 11, len, bytes).
    var patched: [1024]u8 = undefined;
    const marker = std.mem.lastIndexOfScalar(u8, record[0..used], 11) orelse return false;
    @memcpy(patched[0..marker], record[0..marker]);
    patched[marker] = 11;
    std.mem.writeInt(u32, patched[marker + 1 ..][0..4], @intCast(bytes.len), .little);
    @memcpy(patched[marker + 5 ..][0..bytes.len], bytes);
    const length = marker + 5 + bytes.len;
    var fresh: DB = .{};
    var create_record: [1024]u8 = undefined;
    var create_used: usize = 0;
    fresh.executeChanges("CREATE TABLE j (id INTEGER PRIMARY KEY, doc JSONB)", &r, &create_record, &create_used, null, null) catch return false;
    var replica: DB = .{};
    replica.applyChangeRecord(create_record[0..create_used], &scratch) catch return false;
    if (replica.applyChangeRecord(patched[0..length], &scratch)) |_| return true else |_| return false;
}

fn changeLog() !void {
    var primary: DB = .{};
    var replica: DB = .{};
    var r: DB.Result = .{};
    var record: [4096]u8 = undefined;
    const statements = [_][]const u8{
        "CREATE TABLE every (id SMALLINT PRIMARY KEY, n NUMERIC(10,3), f REAL, d DOUBLE PRECISION, t TIMESTAMPTZ(2), i INTERVAL, j JSONB, x JSON)",
        "INSERT INTO every VALUES (1, 12.3456, 1.5, 0.1, '2026-10-22 12:00:00.129Z', '1 mon 2 days 03:00', '{\"k\":[1,2.0]}', '{\"raw\" : 1}')",
        "INSERT INTO every VALUES (2, 'NaN', 'Infinity', '-0', 'infinity', '-1 day', 'null', '[]')",
        "UPDATE every SET n = n * 2 WHERE id = 1",
    };
    for (statements) |source| {
        var used: usize = 0;
        try primary.executeChanges(source, &r, &record, &used, null, null);
        try replica.applyChangeRecord(record[0..used], &scratch);
    }
    try primary.execute("SELECT * FROM every ORDER BY id", &result);
    var expected: DB.Result = .{};
    expected.copyFrom(&result);
    try replica.execute("SELECT * FROM every ORDER BY id", &result);
    try check(result.row_count == 2 and result.column_count == 8);
    for (0..2) |index| for (0..8) |column| {
        const a = &expected.rows[index].cells[column];
        const b = &result.rows[index].cells[column];
        try check(std.meta.activeTag(a.*) == std.meta.activeTag(b.*) and DB.compareCells(a, b) == 0);
    };
    try check(result.column_typmods[1] == (10 << 16 | 3) + 4 and result.column_typmods[4] == 2);
    var buffer: [Io.format_bytes]u8 = undefined;
    try check(std.mem.eql(u8, try Io.format(&result.rows[0].cells[1], false, &db.session, &buffer), "24.692"));
    try check(std.mem.eql(u8, try Io.format(&result.rows[0].cells[4], false, &db.session, &buffer), "2026-10-22 12:00:00.13+00"));
    try check(std.mem.eql(u8, try Io.format(&result.rows[0].cells[7], false, &db.session, &buffer), "{\"raw\" : 1}"));
}

pub fn main(init: std.process.Init) !void {
    try rounding();
    try numeric();
    try floats();
    try temporals();
    try temporalRangeProperties();
    try tzif();
    try json();
    try changeLog();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
