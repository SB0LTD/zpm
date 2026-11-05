//! Query-composition contracts (conformance lane B11): NATURAL joins,
//! parenthesized join trees, standalone VALUES/TABLE, expression LIMIT /
//! OFFSET, FETCH WITH TIES, GROUPING SETS / CUBE, CTE materialization
//! clauses, LATERAL, table functions, recursive SEARCH/CYCLE, data-modifying
//! CTEs and TABLESAMPLE. Each section checks values in PostgreSQL 18 text
//! output, ordering and multiplicity, NULLs and empty inputs, exact errors
//! (SQLSTATE through the error name) with an unchanged result afterwards,
//! and the statement work budget / cancellation checkpoints.
//!
//! Fixtures copied from tests/sql_conformance/postgres18_oracle.json are
//! marked "oracle". Every other expectation is derived from the PostgreSQL
//! 18 documentation and source and is PENDING NATIVE VERIFICATION.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 10, .columns = 16, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 2048, .work_rows = 256, .result_rows = 64, .relations = 6 });
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .work_rows = 4, .result_rows = 8, .nulls_first_ascending = false, .integer_bits = 32 });

var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var small: Small = .{};
var small_result: Small.Result = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("query-composition contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.QueryCompositionContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(target: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..target.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

var meta_buffer: [1024]u8 = undefined;
/// Column metadata as `name:oid,name:oid`.
fn metadata(target: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    for (0..target.column_count) |column| {
        const piece = try std.fmt.bufPrint(meta_buffer[at..], "{s}{s}:{d}", .{ if (column == 0) "" else ",", target.column_names[column].slice(), sql.typeOid(target.column_types[column]) });
        at += piece.len;
    }
    return meta_buffer[0..at];
}

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn run(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try run(source);
    try same(try render(&result), wanted);
}

/// Values and column metadata (`name:oid,...`).
fn expectTyped(source: []const u8, columns: []const u8, wanted: []const u8) !void {
    try run(source);
    try same(try metadata(&result), columns);
    try same(try render(&result), wanted);
}

/// The bag of rows, ignoring order (unordered PostgreSQL fixtures).
fn expectBag(source: []const u8, wanted_sorted: []const u8) !void {
    try run(source);
    const text = try render(&result);
    var rows: [64][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |row| {
        if (row.len == 0 and text.len == 0) break;
        rows[count] = row;
        count += 1;
    }
    std.mem.sort([]const u8, rows[0..count], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var joined: [16384]u8 = undefined;
    var at: usize = 0;
    for (rows[0..count], 0..) |row, index| {
        if (index != 0) {
            joined[at] = ';';
            at += 1;
        }
        @memcpy(joined[at..][0..row.len], row);
        at += row.len;
    }
    try same(joined[0..at], wanted_sorted);
}

/// The statement fails with `wanted`; the previous result is untouched
/// (failure atomicity) and no transaction state leaks.
fn rejects(source: []const u8, wanted: anyerror) !void {
    const saved = db.session.control;
    db.session.control = null;
    try run("SELECT 4242");
    db.session.control = saved;
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(result.row_count == 1 and result.column_count == 1 and result.rows[0].cells[0].integer == 4242);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0 and usage.row_locks == 0);
}

const Cancel = struct {
    remaining: usize,
    fn poll(raw: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(raw.?));
        if (self.remaining == 0) return error.QueryCanceled;
        self.remaining -= 1;
    }
};

/// Every work budget below the statement's need fails with exactly
/// QueryWorkLimit (54000) at that budget, every cancellation point with
/// QueryCanceled (57014), and an unbudgeted rerun returns `wanted` again.
fn controlled(source: []const u8, wanted: []const u8) !void {
    try expect(source, wanted);
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try run(source);
    const used = control.used;
    try check(used > 0);
    var limit: u64 = 1;
    while (limit < used) : (limit += @max(1, used / 97)) {
        control.reset(limit);
        try rejects(source, error.QueryWorkLimit);
        try check(control.used == limit);
    }
    var cancel: Cancel = .{ .remaining = 0 };
    control.context = &cancel;
    control.poll = Cancel.poll;
    control.poll_interval = 1;
    var point: usize = 0;
    while (point < used) : (point += @max(1, used / 61)) {
        cancel.remaining = point;
        control.reset(0);
        try rejects(source, error.QueryCanceled);
    }
    db.session.control = null;
    try expect(source, wanted);
}

fn baseFixture() !void {
    // The conformance driver's `base` fixture (cases.json).
    try run("CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)");
    try run("INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)");
    try run("CREATE TABLE tdd_b(id INT PRIMARY KEY,v INT)");
    try run("INSERT INTO tdd_b VALUES(1,11),(3,33),(5,55)");
    try run("CREATE TABLE na(id INT, k INT, x TEXT)");
    try run("INSERT INTO na VALUES(1,1,'a'),(2,2,'b'),(3,NULL,'c')");
    try run("CREATE TABLE nb(k INT, y TEXT)");
    try run("INSERT INTO nb VALUES(1,'p'),(2,'q'),(2,'r'),(NULL,'n'),(4,'s')");
    try run("CREATE TABLE nc(id BIGINT, k INT, z INT)");
    try run("INSERT INTO nc VALUES(1,1,10),(2,5,20)");
}

// ---- PG.JOIN.NATURAL ------------------------------------------------------

fn naturalJoins() !void {
    // oracle: common columns id and v; no row agrees on both.
    try expectTyped("SELECT id FROM tdd_a NATURAL JOIN tdd_b ORDER BY id", "id:23", "");
    // Merged columns first (left order), then the rest of each side.
    try expectTyped("SELECT * FROM na NATURAL JOIN nb ORDER BY k,y", "k:23,id:23,x:25,y:25", "1|1|a|p;2|2|b|q;2|2|b|r");
    try expect("SELECT * FROM na NATURAL INNER JOIN nb ORDER BY k,y", "1|1|a|p;2|2|b|q;2|2|b|r");
    // NULL keys never match; outer joins null-extend.
    try expect("SELECT * FROM na NATURAL LEFT JOIN nb ORDER BY id,y", "1|1|a|p;2|2|b|q;2|2|b|r;NULL|3|c|NULL");
    try expect("SELECT * FROM na NATURAL LEFT OUTER JOIN nb WHERE y IS NULL", "NULL|3|c|NULL");
    try expect("SELECT * FROM na NATURAL RIGHT JOIN nb ORDER BY k NULLS FIRST,y", "NULL|NULL|NULL|n;1|1|a|p;2|2|b|q;2|2|b|r;4|NULL|NULL|s");
    try expect("SELECT * FROM na NATURAL FULL JOIN nb ORDER BY k NULLS FIRST,id,y", "NULL|3|c|NULL;NULL|NULL|NULL|n;1|1|a|p;2|2|b|q;2|2|b|r;4|NULL|NULL|s");
    try expect("SELECT k,na.k,nb.k FROM na NATURAL FULL JOIN nb WHERE k=4 OR k IS NULL ORDER BY y NULLS FIRST", "NULL|NULL|NULL;NULL|NULL|NULL;4|NULL|4");
    // The merged column has the operands' common type (int4 with int8).
    try expectTyped("SELECT id,k,z FROM nc NATURAL JOIN na", "id:20,k:23,z:23", "1|1|10");
    try expectTyped("SELECT id FROM na JOIN nc USING (id) ORDER BY id", "id:20", "1;2");
    try expectTyped("SELECT id FROM na RIGHT JOIN nc USING (id) ORDER BY id", "id:20", "1;2");
    // Without a common name NATURAL is a cross product.
    try expect("SELECT COUNT(*) FROM na NATURAL JOIN (SELECT 1 AS w UNION ALL SELECT 2) s", "6");
    // Chained: the second NATURAL sees the first join's merged k once.
    try expect("SELECT * FROM na NATURAL JOIN nb NATURAL JOIN (SELECT 2 AS k,'q' AS y) t", "2|q|2|b");
    // Empty operands.
    try expect("SELECT * FROM na NATURAL JOIN nb WHERE false", "");
    try expect("SELECT * FROM (SELECT * FROM na WHERE id<0) e NATURAL LEFT JOIN nb", "");
    try expect("SELECT COUNT(*) FROM na NATURAL RIGHT JOIN (SELECT * FROM nb WHERE k<0) e", "0");
    // Errors.
    try rejects("SELECT * FROM na NATURAL JOIN nb ON true", error.Syntax);
    try rejects("SELECT * FROM na NATURAL JOIN nb USING (k)", error.Syntax);
    try rejects("SELECT * FROM na NATURAL CROSS JOIN nb", error.Syntax);
    try rejects("SELECT * FROM na NATURAL nb", error.Syntax);
    // PostgreSQL: common column name "k" appears more than once in left table.
    try rejects("SELECT * FROM na JOIN nc ON na.id=nc.id NATURAL JOIN nb", error.AmbiguousColumn);
    try rejects("SELECT * FROM nb NATURAL JOIN (SELECT 1 AS k,2 AS k) d", error.AmbiguousColumn);
    try rejects("SELECT * FROM na JOIN nb USING (k,k)", error.DuplicateColumn);
    try rejects("SELECT id FROM na NATURAL JOIN nb WHERE q=1", error.ColumnNotFound);
    // Own writes are visible to the statement snapshot; aborts remove them.
    const tx = try db.begin();
    try db.statement(tx, "INSERT INTO nb VALUES(1,'o')", &result, .{});
    try db.statement(tx, "SELECT x,y FROM na NATURAL JOIN nb ORDER BY k,y", &result, .{});
    try same(try render(&result), "a|o;a|p;b|q;b|r");
    db.abort(tx);
    try controlled("SELECT * FROM na NATURAL FULL JOIN nb ORDER BY k NULLS FIRST,id,y", "NULL|3|c|NULL;NULL|NULL|NULL|n;1|1|a|p;2|2|b|q;2|2|b|r;4|NULL|NULL|s");
}

// ---- PG.JOIN.TREE ---------------------------------------------------------

fn joinTrees() !void {
    // oracle
    try expectTyped("SELECT a.id FROM (tdd_a a JOIN tdd_b b ON a.id=b.id) LEFT JOIN tdd_b c ON c.id=a.id ORDER BY a.id", "id:23", "1;3");
    // A left operand group is already left-deep; redundant parentheses.
    try expect("SELECT a.id,c.v FROM ((tdd_a a JOIN tdd_b b ON a.id=b.id)) LEFT JOIN tdd_b c ON c.id=a.id+2 ORDER BY a.id", "1|33;3|55");
    try expect("SELECT a.id,c.v FROM (((tdd_a a JOIN tdd_b b ON a.id=b.id)) LEFT JOIN tdd_b c ON c.id=a.id+2) ORDER BY a.id", "1|33;3|55");
    // A right operand group is joined as a whole: null-extended once.
    try expect("SELECT a.id,b.id,c.id FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON b.id=a.id ORDER BY a.id", "1|1|1;2|NULL|NULL;3|3|3;4|NULL|NULL");
    // Flattening would lose every row here: the group itself is empty.
    try expect("SELECT a.id,b.id,c.id FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON c.v=b.v+100) ON b.id=a.id ORDER BY a.id", "1|NULL|NULL;2|NULL|NULL;3|NULL|NULL;4|NULL|NULL");
    // The outer condition sees every item of the group.
    try expect("SELECT a.id,b.id,c.id FROM tdd_a a JOIN (tdd_b b JOIN tdd_b c ON c.id>b.id) ON a.id=c.id ORDER BY a.id,b.id", "3|1|3");
    try expect("SELECT a.id,b.id,c.id FROM tdd_a a RIGHT JOIN (tdd_b b CROSS JOIN tdd_b c) ON a.id=b.id AND c.id=5 ORDER BY b.id,c.id", "NULL|1|1;NULL|1|3;1|1|5;NULL|3|1;NULL|3|3;3|3|5;NULL|5|1;NULL|5|3;NULL|5|5");
    try expect("SELECT a.id,b.id FROM tdd_a a FULL JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON a.id=b.id ORDER BY a.id NULLS LAST,b.id", "1|1;2|NULL;3|3;4|NULL;NULL|5");
    // Nested right groups and a group after a comma.
    try expect("SELECT a.id,b.id,c.id,d.id FROM tdd_a a LEFT JOIN (tdd_b b JOIN (tdd_b c JOIN tdd_b d ON d.id=c.id) ON c.id=b.id) ON b.id=a.id WHERE a.id<3 ORDER BY a.id", "1|1|1|1;2|NULL|NULL|NULL");
    try expect("SELECT COUNT(*) FROM tdd_a a, (tdd_b b LEFT JOIN tdd_b c ON c.id=b.id+2)", "12");
    // USING over a group's merged column; star order follows the tree.
    try expect("SELECT k,y,x FROM nb JOIN (na JOIN tdd_b ON tdd_b.id=na.id) USING (k) ORDER BY y", "1|p|a");
    try expectTyped("SELECT * FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c USING (id)) USING (id) ORDER BY id", "id:23,g:23,v:23,v:23,v:23", "1|1|10|11|11;2|1|20|NULL|NULL;3|2|30|33|33;4|2|NULL|NULL|NULL");
    try expect("SELECT COUNT(*) FROM tdd_a a NATURAL LEFT JOIN (tdd_b b JOIN nc USING (id))", "4");
    // WHERE filters after the tree; aggregates over it.
    try expect("SELECT a.g,COUNT(b.id) FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON b.id=a.id WHERE a.v IS NOT NULL GROUP BY a.g ORDER BY a.g", "1|1;2|1");
    try expect("SELECT a.id FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON b.id=a.id WHERE b.id IS NULL ORDER BY a.id", "2;4");
    // Empty operands.
    try expect("SELECT COUNT(*) FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON false) ON true", "4");
    try expect("SELECT COUNT(*) FROM (SELECT * FROM tdd_a WHERE false) a RIGHT JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON true", "3");
    // Scope: a group's own condition sees only the group (42P01 / 42703).
    try rejects("SELECT * FROM tdd_a a JOIN (tdd_b b JOIN tdd_b c ON c.id=a.id) ON true", error.TableNotFound);
    try rejects("SELECT * FROM tdd_a a JOIN (tdd_b b JOIN tdd_b c ON c.id=g) ON true", error.ColumnNotFound);
    try rejects("SELECT * FROM tdd_a a JOIN (tdd_b b JOIN na ON na.k=b.id) USING (id)", error.AmbiguousColumn);
    // An alias on a join tree is outside the subset; `(t)` is not a join.
    try rejects("SELECT * FROM (tdd_a a JOIN tdd_b b ON a.id=b.id) j", error.UnsupportedStatement);
    try rejects("SELECT * FROM (tdd_a a JOIN tdd_b b ON a.id=b.id) AS j", error.UnsupportedStatement);
    try rejects("SELECT * FROM (tdd_a a)", error.Syntax);
    try rejects("SELECT * FROM (tdd_a a, tdd_b b)", error.Syntax);
    try rejects("SELECT * FROM (tdd_a a JOIN tdd_b b ON true", error.Syntax);
    try controlled("SELECT a.id,b.id,c.id FROM tdd_a a LEFT JOIN (tdd_b b JOIN tdd_b c ON c.id=b.id) ON b.id=a.id ORDER BY a.id", "1|1|1;2|NULL|NULL;3|3|3;4|NULL|NULL");
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try naturalJoins();
    try joinTrees();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-query-composition\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
