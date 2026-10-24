//! General DML contracts (design §5.10-§5.13): multi-row VALUES, INSERT ...
//! SELECT, expression SET, RETURNING over new rows (INSERT/UPDATE) and old
//! rows (DELETE), RETURNING rows emitted exactly once across a park, and
//! atomic failure (a failing statement changes nothing and leaves the
//! caller's result untouched). The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 32, .name_bytes = 16, .text_bytes = 32, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4 });
var assertions: usize = 0;
var db: DB = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("dml contract failed at assertion {d}\n", .{assertions});
        return error.DmlContractFailed;
    }
}

var text_buffer: [4096]u8 = undefined;
/// Rows as `a|b;c|d` with NULL for null cells (PostgreSQL text output).
fn render(result: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &result.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn expect(source: []const u8, wanted: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try same(try render(&result), wanted);
}

fn names(result: *const DB.Result, wanted: []const []const u8) !void {
    try check(result.column_count == wanted.len);
    for (wanted, 0..) |name, column| try check(std.mem.eql(u8, result.column_names[column].slice(), name));
}

fn autocommit(source: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// The error, an untouched result and an unchanged table.
fn rejects(source: []const u8, wanted: anyerror, check_query: []const u8, unchanged: []const u8) !void {
    var result: DB.Result = .{};
    try autocommit("SELECT 7");
    db.execute("SELECT 7", &result) catch unreachable;
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
    try check(result.row_count == 1 and result.column_count == 1 and result.command == .select and result.rows[0].cells[0].integer == 7);
    try expect(check_query, unchanged);
    try empty();
}

fn empty() !void {
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0);
}

fn returning() !void {
    try autocommit("CREATE TABLE compat (id INTEGER PRIMARY KEY, flag BOOLEAN, label TEXT)");
    try autocommit("INSERT INTO compat VALUES (1, TRUE, 'one'), (2, FALSE, NULL), (3, NULL, 'three')");
    try expect("SELECT id, label FROM compat ORDER BY id", "1|one;2|NULL;3|three");
    var result: DB.Result = .{};
    try db.execute("INSERT INTO compat VALUES (4, FALSE, 'four') RETURNING label", &result);
    try check(result.command == .insert and result.affected_rows == 1 and result.row_count == 1);
    try names(&result, &.{"label"});
    try same(try render(&result), "four");
    try db.execute("INSERT INTO compat (label, id) VALUES ('five', 5), ('six', 6) RETURNING id, label, id * 10 AS tens, compat.label || '!'", &result);
    try check(result.affected_rows == 2 and result.column_count == 4);
    try names(&result, &.{ "id", "label", "tens", "?column?" });
    try same(try render(&result), "5|five|50|five!;6|six|60|six!");
    try db.execute("UPDATE compat SET flag = flag WHERE id = 5 RETURNING compat.*", &result);
    try same(try render(&result), "5|NULL|five");
    try db.execute("INSERT INTO compat SELECT id + 10, flag, label FROM compat WHERE id < 3 ORDER BY id DESC RETURNING id, label", &result);
    try check(result.affected_rows == 2);
    try same(try render(&result), "12|NULL;11|one");
    try db.execute("INSERT INTO compat (id, label) SELECT 20, 'literal' RETURNING id, label", &result);
    try same(try render(&result), "20|literal");
    try db.execute("UPDATE compat SET label = label || '+', flag = NOT flag WHERE id > 10 RETURNING id, label, flag", &result);
    try check(result.command == .update and result.affected_rows == 3);
    try same(try render(&result), "12|NULL|t;11|one+|f;20|literal+|NULL");
    try db.execute("DELETE FROM compat WHERE id >= 11 RETURNING *", &result);
    try check(result.command == .delete and result.affected_rows == 3);
    try same(try render(&result), "12|t|NULL;11|f|one+;20|NULL|literal+");
    // No RETURNING: a mutation reports only its count.
    try db.execute("UPDATE compat SET label = 'x' WHERE id = 99", &result);
    try check(result.affected_rows == 0 and result.column_count == 0 and result.row_count == 0);
    db.execute("INSERT INTO compat DEFAULT VALUES RETURNING id", &result) catch |err| try check(err == error.NotNullViolation);
    // Describe reports RETURNING columns without executing.
    try db.describe("DELETE FROM compat WHERE id = 1 RETURNING id, label AS l", &result);
    try check(result.command == .delete and result.row_count == 0);
    try names(&result, &.{ "id", "l" });
    try expect("SELECT COUNT(*) FROM compat", "6");
    try empty();
}

fn atomicity() !void {
    const all = "SELECT id FROM compat ORDER BY id";
    const before = "1;2;3;4;5;6";
    // The third row's key is taken: nothing is inserted, no row returned.
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a'), (8, TRUE, 'b'), (1, TRUE, 'c') RETURNING id", error.PrimaryKeyViolation, all, before);
    // A duplicate inside one statement.
    try rejects("INSERT INTO compat (id) VALUES (9), (9)", error.PrimaryKeyViolation, all, before);
    // A failing RETURNING expression rolls the mutation back.
    try rejects("UPDATE compat SET flag = TRUE RETURNING 10 / (id - 3)", error.DivisionByZero, "SELECT COUNT(*) FROM compat WHERE flag", "1");
    try rejects("DELETE FROM compat RETURNING 1 / (id - 6)", error.DivisionByZero, all, before);
    try rejects("INSERT INTO compat SELECT id, flag, label FROM compat", error.PrimaryKeyViolation, all, before);
    // Arity and DEFAULT placement.
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a'), (8, TRUE)", error.Syntax, all, before);
    try rejects("INSERT INTO compat (id, label) SELECT id FROM compat", error.Syntax, all, before);
    try rejects("SELECT DEFAULT", error.Syntax, all, before);
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a') RETURNING nope", error.ColumnNotFound, all, before);
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a') RETURNING other.*", error.TableNotFound, all, before);
}

fn run(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{});
    return result;
}

fn parks(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| return error.ExpectedPark else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

/// RC14 and a parked multi-row INSERT: every row is written and returned
/// exactly once, in order, after the blocker commits.
fn acrossParks() !void {
    try autocommit("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
    try autocommit("INSERT INTO t VALUES (1, 0), (2, 0), (3, 0)");
    const a = try db.begin();
    const b = try db.begin();
    _ = try run(a, "UPDATE t SET v = 9 WHERE id = 2");
    const update = "UPDATE t SET v = v + 1 RETURNING id, v";
    try parks(b, update);
    db.publishCommit(a);
    var result: DB.Result = .{};
    try db.statement(b, update, &result, .{ .@"resume" = true });
    try check(result.command == .update and result.affected_rows == 3);
    try same(try render(&result), "1|1;2|10;3|1");
    db.publishCommit(b);
    try expect("SELECT id, v FROM t ORDER BY id", "1|1;2|10;3|1");
    // An uncommitted insert of key 5 parks the second row of a multi-row
    // INSERT; on resume row 4 is not inserted twice.
    const c = try db.begin();
    const d = try db.begin();
    _ = try run(c, "INSERT INTO t VALUES (5, 50)");
    const insert = "INSERT INTO t VALUES (4, 40), (5, 41), (6, 60) RETURNING id, v";
    try parks(d, insert);
    db.abort(c);
    try db.statement(d, insert, &result, .{ .@"resume" = true });
    try check(result.command == .insert and result.affected_rows == 3);
    try same(try render(&result), "4|40;5|41;6|60");
    db.publishCommit(d);
    try expect("SELECT id, v FROM t WHERE id > 3 ORDER BY id", "4|40;5|41;6|60");
    // DELETE RETURNING across a park returns the deleted rows' old values.
    const e = try db.begin();
    const f = try db.begin();
    _ = try run(e, "UPDATE t SET v = 99 WHERE id = 5");
    const delete = "DELETE FROM t WHERE id > 3 RETURNING id, v";
    try parks(f, delete);
    db.publishCommit(e);
    try db.statement(f, delete, &result, .{ .@"resume" = true });
    try same(try render(&result), "4|40;5|99;6|60");
    db.publishCommit(f);
    try expect("SELECT COUNT(*) FROM t", "3");
    try empty();
}

pub fn main(init: std.process.Init) !void {
    try returning();
    try atomicity();
    try acrossParks();
    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-dml\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
