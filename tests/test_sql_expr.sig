//! Q01 expression contracts (design §5.1): PostgreSQL precedence,
//! three-valued truth tables, NULL logic in IN/BETWEEN, typing and SQLSTATE
//! error classes, output names, dialect assignment rules, legacy replay
//! limits and failure-after-many-rows atomicity. The assertion counter proves
//! this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 3, .columns = 8, .rows_per_table = 16, .name_bytes = 16, .text_bytes = 32 });
/// 400 matching rows for the failure-after-many-rows contract.
const Wide = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 512, .name_bytes = 16, .text_bytes = 16 });
var wide: Wide = .{};

var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlExprContractFailed;
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn sameCell(a: anytype, b: @TypeOf(a)) bool {
    return switch (a) {
        .null_value => b == .null_value,
        .integer => |value| b == .integer and b.integer == value,
        .boolean => |value| b == .boolean and b.boolean == value,
        .text => |*value| b == .text and same(value.slice(), b.text.slice()),
    };
}

fn sameResult(a: anytype, b: @TypeOf(a)) bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count or a.affected_rows != b.affected_rows or a.command != b.command) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or !same(a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |row| for (0..a.column_count) |column| {
        if (!sameCell(a.rows[row].cells[column], b.rows[row].cells[column])) return false;
    };
    return true;
}

fn cellOf(db: anytype, result: anytype, source: []const u8) !@TypeOf(result.rows[0].cells[0]) {
    try db.execute(source, result);
    try check(result.row_count == 1);
    return result.rows[0].cells[0];
}

fn integer(db: anytype, result: anytype, source: []const u8, expected: i64) !void {
    const cell = try cellOf(db, result, source);
    try check(cell == .integer and cell.integer == expected);
}

fn truth(db: *DB, result: *DB.Result, source: []const u8, expected: ?bool) !void {
    const cell = try cellOf(db, result, source);
    if (expected) |wanted| try check(cell == .boolean and cell.boolean == wanted) else try check(cell == .null_value);
}

/// The error and an untouched result (and database) on failure.
fn rejects(db: anytype, result: anytype, source: []const u8, wanted: anyerror) !void {
    const before = result.*;
    if (db.execute(source, result)) |_| return error.InvalidSqlAccepted else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
    try check(sameResult(&before, result));
}

fn ids(db: anytype, result: anytype, source: []const u8, expected: []const i64) !void {
    try db.execute(source, result);
    try check(result.row_count == expected.len);
    for (expected, 0..) |id, row| try check(result.rows[row].cells[0].integer == id);
}

fn base(db: *DB, result: *DB.Result) !void {
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, flag BOOLEAN, label TEXT)", result);
    try db.execute("INSERT INTO t VALUES (1, TRUE, 'one')", result);
    try db.execute("INSERT INTO t VALUES (2, FALSE, NULL)", result);
    try db.execute("INSERT INTO t VALUES (3, NULL, 'three')", result);
}

fn precedence() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try integer(&db, &r, "SELECT 1 + 2 * 3", 7);
    try integer(&db, &r, "SELECT (1 + 2) * 3", 9);
    try integer(&db, &r, "SELECT 2 * 3 % 4", 2);
    try integer(&db, &r, "SELECT 10 - 4 - 3", 3);
    try integer(&db, &r, "SELECT -2 * -3", 6);
    try integer(&db, &r, "SELECT - (2 + 3)", -5);
    try integer(&db, &r, "SELECT ((((((7))))))", 7);
    try truth(&db, &r, "SELECT TRUE OR FALSE AND FALSE", true);
    try truth(&db, &r, "SELECT (TRUE OR FALSE) AND FALSE", false);
    try truth(&db, &r, "SELECT NOT FALSE AND FALSE", false);
    try truth(&db, &r, "SELECT NOT (FALSE AND FALSE)", true);
    try truth(&db, &r, "SELECT 1 = 1 IS TRUE", true);
    try truth(&db, &r, "SELECT 'a' || 'b' = 'ab'", true);
    try truth(&db, &r, "SELECT 2 + 3 BETWEEN 5 AND 5", true);
    try truth(&db, &r, "SELECT NOT 1 IN (2, 3)", true);
    try truth(&db, &r, "SELECT '7'::integer + 1 = 8", true);
    try truth(&db, &r, "SELECT /* nested /* comment */ */ 1 < 2 -- tail", true);
    try rejects(&db, &r, "SELECT 1 < 2 < 3", error.Syntax);
    // Grammar-level negation of constants keeps the int4/int8 minimums.
    try integer(&db, &r, "SELECT -2147483648", -2147483648);
    try check(r.column_types[0] == .integer32);
    try integer(&db, &r, "SELECT -9223372036854775808", std.math.minInt(i64));
    try check(r.column_types[0] == .integer);
    try integer(&db, &r, "SELECT 2147483648", 2147483648);
    try check(r.column_types[0] == .integer);
}

const Tri = enum { t, f, n };

fn word(v: Tri) []const u8 {
    return switch (v) {
        .t => "TRUE",
        .f => "FALSE",
        .n => "NULL",
    };
}

fn optional(v: Tri) ?bool {
    return switch (v) {
        .t => true,
        .f => false,
        .n => null,
    };
}

fn truthTables() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    const all = [_]Tri{ .t, .f, .n };
    var text: [128]u8 = undefined;
    for (all) |a| {
        const not_expected: ?bool = if (optional(a)) |b| !b else null;
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT NOT {s}", .{word(a)}), not_expected);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS TRUE", .{word(a)}), a == .t);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS NOT TRUE", .{word(a)}), a != .t);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS FALSE", .{word(a)}), a == .f);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS NOT FALSE", .{word(a)}), a != .f);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS UNKNOWN", .{word(a)}), a == .n);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS NOT UNKNOWN", .{word(a)}), a != .n);
        try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} IS NULL", .{word(a)}), a == .n);
        for (all) |b| {
            const and_expected: ?bool = if (a == .f or b == .f) false else if (a == .n or b == .n) null else true;
            const or_expected: ?bool = if (a == .t or b == .t) true else if (a == .n or b == .n) null else false;
            try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} AND {s}", .{ word(a), word(b) }), and_expected);
            try truth(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} OR {s}", .{ word(a), word(b) }), or_expected);
        }
    }
}

fn nullLogic() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try truth(&db, &r, "SELECT 1 IN (1, NULL)", true);
    try truth(&db, &r, "SELECT 2 IN (1, NULL)", null);
    try truth(&db, &r, "SELECT 2 NOT IN (1, NULL)", null);
    try truth(&db, &r, "SELECT 2 NOT IN (1, 3)", true);
    try truth(&db, &r, "SELECT NULL IN (1, 2)", null);
    try truth(&db, &r, "SELECT 1 BETWEEN 2 AND NULL", false);
    try truth(&db, &r, "SELECT 3 BETWEEN 2 AND NULL", null);
    try truth(&db, &r, "SELECT 1 NOT BETWEEN 2 AND NULL", true);
    try truth(&db, &r, "SELECT NULL BETWEEN 1 AND 2", null);
    try ids(&db, &r, "SELECT id FROM t WHERE id = 1 OR id = 3 ORDER BY id", &.{ 1, 3 });
    try ids(&db, &r, "SELECT id FROM t WHERE id = 1 OR id = 2 AND flag ORDER BY id", &.{1});
    try ids(&db, &r, "SELECT id FROM t WHERE NOT flag ORDER BY id", &.{2});
    try ids(&db, &r, "SELECT id FROM t WHERE flag IS NOT TRUE ORDER BY id", &.{ 2, 3 });
    try ids(&db, &r, "SELECT id FROM t WHERE label IN ('one', NULL) ORDER BY id", &.{1});
    try ids(&db, &r, "SELECT id FROM t WHERE label NOT IN ('one', NULL) ORDER BY id", &.{});
    try ids(&db, &r, "SELECT id FROM t WHERE id NOT BETWEEN 2 AND 2 ORDER BY id DESC", &.{ 3, 1 });
    try ids(&db, &r, "SELECT id FROM t WHERE COALESCE(flag, TRUE) ORDER BY id", &.{ 1, 3 });
    try ids(&db, &r, "SELECT id FROM t WHERE label LIKE '%e' ORDER BY id", &.{ 1, 3 });
    try ids(&db, &r, "SELECT id FROM t WHERE label ILIKE 'T_REE' ORDER BY id", &.{3});
    try ids(&db, &r, "SELECT id FROM t WHERE label NOT LIKE 'o%' ORDER BY id", &.{3});
    try truth(&db, &r, "SELECT 'a%' LIKE 'a\\%'", true);
    try truth(&db, &r, "SELECT 'ab' LIKE 'a\\%'", false);
    try truth(&db, &r, "SELECT 'abc' LIKE '_b_'", true);
}

fn valuesAndNames() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try db.execute("SELECT id AS \"Ident\", label l, TRUE, 1::text, CAST(id AS bigint), id::text, COALESCE(label, 'none'), NULLIF(id, 2) FROM t ORDER BY id", &r);
    try check(r.column_count == 8 and r.row_count == 3);
    const names = [_][]const u8{ "Ident", "l", "?column?", "text", "id", "id", "coalesce", "nullif" };
    const kinds = [_]sql.DataType{ .integer32, .text, .boolean, .text, .integer, .text, .text, .integer32 };
    for (names, kinds, 0..) |name, kind, column| try check(same(r.column_names[column].slice(), name) and r.column_types[column] == kind);
    try check(same(r.rows[1].cells[6].text.slice(), "none") and r.rows[1].cells[7] == .null_value and r.rows[0].cells[7].integer == 1);
    try check(same(r.rows[2].cells[5].text.slice(), "3") and r.rows[2].cells[4].integer == 3);
    try db.execute("SELECT CASE WHEN flag THEN 'yes' WHEN NOT flag THEN 'no' ELSE 'unknown' END, CASE id WHEN 2 THEN 'two' END FROM t ORDER BY id", &r);
    try check(same(r.column_names[0].slice(), "case") and same(r.rows[0].cells[0].text.slice(), "yes") and same(r.rows[1].cells[0].text.slice(), "no"));
    try check(same(r.rows[2].cells[0].text.slice(), "unknown") and r.rows[0].cells[1] == .null_value and same(r.rows[1].cells[1].text.slice(), "two"));
    try db.execute("SELECT label || '!', id || ':' || label, flag || 'x' FROM t ORDER BY id", &r);
    try check(same(r.rows[0].cells[0].text.slice(), "one!") and same(r.rows[0].cells[1].text.slice(), "1:one") and same(r.rows[0].cells[2].text.slice(), "truex"));
    try check(r.rows[1].cells[0] == .null_value and r.rows[2].cells[2] == .null_value);
    try db.execute("SELECT id, label FROM t ORDER BY 2 DESC NULLS LAST, id", &r);
    try check(r.rows[0].cells[0].integer == 3 and r.rows[1].cells[0].integer == 1 and r.rows[2].cells[0].integer == 2);
    try ids(&db, &r, "SELECT id FROM t ORDER BY id % 2, id DESC", &.{ 2, 3, 1 });
    try ids(&db, &r, "SELECT id AS k FROM t ORDER BY k DESC", &.{ 3, 2, 1 });
    try ids(&db, &r, "SELECT x.id FROM t x WHERE x.label = 'one'", &.{1});
    try integer(&db, &r, "SELECT 7 / 2", 3);
    try integer(&db, &r, "SELECT -7 / 2", -3);
    try integer(&db, &r, "SELECT -7 % 3", -1);
    try integer(&db, &r, "SELECT 7 % -3", 1);
    try integer(&db, &r, "SELECT ' 0x1F '::integer", 31);
    try integer(&db, &r, "SELECT '1_000'::bigint", 1000);
    try truth(&db, &r, "SELECT 'of'::boolean", false);
    try truth(&db, &r, "SELECT 'Y'::boolean", true);
    try truth(&db, &r, "SELECT 2::boolean", true);
    try integer(&db, &r, "SELECT TRUE::integer", 1);
    try db.describe("SELECT id + 1, label || 'x', id = 2, NULL FROM t", &r);
    try check(r.row_count == 0 and r.column_count == 4 and r.column_types[0] == .integer32 and r.column_types[1] == .text and r.column_types[2] == .boolean and r.column_types[3] == .text);
}

fn errors() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try db.execute("SELECT * FROM t ORDER BY id", &r);
    try rejects(&db, &r, "SELECT id FROM t WHERE id", error.TypeMismatch);
    try rejects(&db, &r, "SELECT id FROM t WHERE id AND flag", error.TypeMismatch);
    try rejects(&db, &r, "SELECT 1 IS TRUE", error.TypeMismatch);
    try rejects(&db, &r, "SELECT CASE WHEN 1 THEN 1 END", error.TypeMismatch);
    try rejects(&db, &r, "SELECT CASE WHEN id = 1 THEN 'x' ELSE 1 END FROM t", error.InvalidTextRepresentation);
    try rejects(&db, &r, "SELECT COALESCE(flag, 1) FROM t", error.TypeMismatch);
    try rejects(&db, &r, "SELECT label + 1 FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT id FROM t WHERE id = TRUE", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT id || 1 FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT id LIKE '1' FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT label -> 'k' FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT lower(label) FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT NULL + NULL", error.AmbiguousFunction);
    try rejects(&db, &r, "SELECT '1' + '2'", error.AmbiguousFunction);
    try rejects(&db, &r, "SELECT TRUE::bigint", error.CannotCoerce);
    try rejects(&db, &r, "SELECT 'x'::integer", error.InvalidTextRepresentation);
    try rejects(&db, &r, "SELECT 'maybe'::boolean", error.InvalidTextRepresentation);
    try rejects(&db, &r, "SELECT id FROM t WHERE id = 'x'", error.InvalidTextRepresentation);
    try rejects(&db, &r, "SELECT 2147483647 + 1", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT -2147483648 - 1", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT - (-2147483648)", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT 9223372036854775807 + 1", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT (-9223372036854775808) / -1", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT '2147483648'::integer", error.IntegerOverflow);
    try rejects(&db, &r, "SELECT 1 / 0", error.DivisionByZero);
    try rejects(&db, &r, "SELECT id % 0 FROM t", error.DivisionByZero);
    // The failing projection is on the last row: nothing reaches the result.
    try rejects(&db, &r, "SELECT 10 / (id - 3) FROM t ORDER BY id", error.DivisionByZero);
    try rejects(&db, &r, "SELECT id FROM t ORDER BY 1 / (id - 1)", error.DivisionByZero);
    try rejects(&db, &r, "SELECT 'a' LIKE 'a\\'", error.InvalidEscapeSequence);
    try rejects(&db, &r, "SELECT $1", error.UndefinedParameter);
    try rejects(&db, &r, "SELECT id FROM t ORDER BY 2", error.InvalidColumnReference);
    try rejects(&db, &r, "SELECT 1.5", error.UnsupportedStatement);
    try rejects(&db, &r, "SELECT id FROM t AS x WHERE t.id = 1", error.TableNotFound);
    try rejects(&db, &r, "SELECT *", error.Syntax);
    try rejects(&db, &r, "SELECT id", error.ColumnNotFound);
    try rejects(&db, &r, "INSERT INTO t VALUES (id, TRUE, 'x')", error.ColumnNotFound);
    var deep: [256]u8 = undefined;
    @memset(deep[0..100], '(');
    deep[100] = '1';
    @memset(deep[101..201], ')');
    var text: [300]u8 = undefined;
    try rejects(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s}", .{deep[0..201]}), error.StatementTooComplex);
    var chain: [300]u8 = undefined;
    var used: usize = 0;
    for (0..80) |_| {
        chain[used] = '-';
        chain[used + 1] = ' ';
        used += 2;
    }
    chain[used] = 'i';
    chain[used + 1] = 'd';
    try rejects(&db, &r, try std.fmt.bufPrint(&text, "SELECT {s} FROM t", .{chain[0 .. used + 2]}), error.StatementTooComplex);
}

fn assignmentAndDialects() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    // PostgreSQL assignment casts: integers and booleans into TEXT.
    try db.execute("INSERT INTO t VALUES ('4', 'yes', 44)", &r);
    try db.execute("INSERT INTO t (id, label) VALUES (5, FALSE)", &r);
    try db.execute("SELECT flag, label FROM t WHERE id = 4", &r);
    try check(r.rows[0].cells[0].boolean and same(r.rows[0].cells[1].text.slice(), "44"));
    try db.execute("SELECT label FROM t WHERE id = 5", &r);
    try check(same(r.rows[0].cells[0].text.slice(), "false"));
    try rejects(&db, &r, "INSERT INTO t VALUES (6, 1, 'x')", error.TypeMismatch);
    try rejects(&db, &r, "UPDATE t SET id = 'x'", error.InvalidTextRepresentation);
    try rejects(&db, &r, "UPDATE t SET id = label", error.TypeMismatch);
    try rejects(&db, &r, "UPDATE t SET id = 2147483647::bigint + 1 WHERE id = 1", error.IntegerOverflow);
    try rejects(&db, &r, "UPDATE t SET label = NULL, flag = NULL, id = NULL WHERE id = 1", error.NotNullViolation);
    // Integer 0/1 into BOOLEAN only in the MySQL/TDS dialects.
    db.dialect = .mysql;
    try db.execute("INSERT INTO t VALUES (6, 1, 'x')", &r);
    try db.execute("UPDATE t SET flag = 0 WHERE id = 6", &r);
    try rejects(&db, &r, "UPDATE t SET flag = 2 WHERE id = 6", error.TypeMismatch);
    try rejects(&db, &r, "SELECT id FROM t WHERE flag = 0", error.UndefinedFunction);
    try db.execute("CREATE TABLE m (n INTEGER)", &r);
    db.dialect = .tds;
    try db.execute("SELECT n FROM m", &r);
    // Outside PostgreSQL an unqualified INTEGER follows integer_bits (64 here).
    try check(r.column_types[0] == .integer);
    db.dialect = .postgres;
    try db.execute("SELECT flag FROM t WHERE id = 6", &r);
    try check(r.rows[0].cells[0] == .boolean and !r.rows[0].cells[0].boolean);
    try db.execute("CREATE TABLE p (n INTEGER, w INT8)", &r);
    try db.execute("SELECT n, w FROM p", &r);
    try check(r.column_types[0] == .integer32 and r.column_types[1] == .integer);
    // Legacy replay: alpha grammar only, alpha boolean integers in comparisons.
    try db.executeLegacy("DELETE FROM t WHERE flag = 0", &r);
    try check(r.affected_rows == 2);
    for ([_][]const u8{ "DELETE FROM t WHERE id = 1 OR id = 2", "UPDATE t SET id = id + 1", "SELECT 1", "INSERT INTO t VALUES (1 + 1, TRUE, 'x')", "SELECT \"id\" FROM t" }) |source| {
        if (db.executeLegacy(source, &r)) |_| return error.LegacyAccepted else |err| try check(err == error.UnsupportedLogVersion);
    }
}

fn keyChecks() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    // Rowid order: 1 -> 2 collides with the committed row 2 (PostgreSQL's
    // immediate unique check fails the same way for this physical order).
    try rejects(&db, &r, "UPDATE t SET id = id + 1", error.PrimaryKeyViolation);
    try db.execute("UPDATE t SET id = id + 10", &r);
    try check(r.affected_rows == 3);
    try ids(&db, &r, "SELECT id FROM t ORDER BY id", &.{ 11, 12, 13 });
    // A key released earlier in the same statement may be reused.
    try db.execute("UPDATE t SET id = id - 10, label = label || '!'", &r);
    try ids(&db, &r, "SELECT id FROM t ORDER BY id", &.{ 1, 2, 3 });
    try rejects(&db, &r, "UPDATE t SET id = 7", error.PrimaryKeyViolation);
    try db.execute("UPDATE t SET id = 7 WHERE id = 1 + 1", &r);
    try ids(&db, &r, "SELECT id FROM t WHERE id = 3 + 4", &.{7});
    try ids(&db, &r, "SELECT id FROM t WHERE id = '7' AND label IS NULL", &.{7});
    try db.execute("DELETE FROM t WHERE id = 6 + 1 OR label = 'three!'", &r);
    try check(r.affected_rows == 2);
    try ids(&db, &r, "SELECT id FROM t", &.{1});
}

const Sink = struct {
    calls: usize = 0,
    fn commit(context: ?*anyopaque, _: []const u8) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(context.?));
        self.calls += 1;
    }
};

var wide_result: Wide.Result = .{};
var wide_before: Wide.Result = .{};

fn atomicity() !void {
    const db = &wide;
    const r = &wide_result;
    try db.execute("CREATE TABLE w (id INTEGER PRIMARY KEY, v INTEGER)", r);
    var text: [96]u8 = undefined;
    for (1..401) |id| try db.execute(try std.fmt.bufPrint(&text, "INSERT INTO w VALUES ({d}, -1)", .{id}), r);
    try db.execute("SELECT * FROM w ORDER BY id", r);
    const before_stats = db.storageStats("w").?;
    const before = &wide_before;
    before.copyFrom(r);
    var record: [65536]u8 = undefined;
    var used: usize = 0;
    var sink: Sink = .{};
    // Rows 1..398 are rewritten before row 399 divides by zero.
    if (db.executeChanges("UPDATE w SET v = 100 / (id - 399)", r, &record, &used, &sink, Sink.commit)) |_| return error.DivisionAccepted else |err| try check(err == error.DivisionByZero);
    try check(used == 0 and sink.calls == 0 and sameResult(before, r));
    const after_stats = db.storageStats("w").?;
    try check(after_stats.versions == before_stats.versions and after_stats.pending == 0 and after_stats.live_rows == 400);
    try db.execute("SELECT * FROM w ORDER BY id", r);
    try check(sameResult(before, r));
    try ids(db, r, "SELECT id FROM w WHERE v <> -1", &.{});
    // The same statement shape succeeds once no row divides by zero.
    try db.executeChanges("UPDATE w SET v = 100 / (id - 401)", r, &record, &used, &sink, Sink.commit);
    try check(r.affected_rows == 400 and sink.calls == 1 and used > 0);
    try integer(db, r, "SELECT v FROM w WHERE id = 400", -100);
    try integer(db, r, "SELECT v FROM w WHERE id = 1", 0);
    // A failing WHERE after many matches deletes nothing.
    try rejects(db, r, "DELETE FROM w WHERE 1 / (id - 300) <= 0", error.DivisionByZero);
    try check(db.storageStats("w").?.live_rows == 400);
}

pub fn main(init: std.process.Init) !void {
    try precedence();
    try truthTables();
    try nullLogic();
    try valuesAndNames();
    try errors();
    try assignmentAndDialects();
    try keyChecks();
    try atomicity();
    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-expr\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d},\"wide_bytes\":{d}}}\n", .{ assertions, DB.storageBytes(), Wide.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
