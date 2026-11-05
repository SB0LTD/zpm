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
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .work_rows = 1, .result_rows = 8, .nulls_first_ascending = false, .integer_bits = 32 });

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

// ---- PG.QUERY.VALUES_TABLE ------------------------------------------------

fn valuesAndTable() !void {
    // oracle
    try expectTyped("VALUES (1),(2)", "column1:23", "1;2");
    try expectTyped("TABLE tdd_a ORDER BY id", "id:23,g:23,v:23", "1|1|10;2|1|20;3|2|30;4|2|NULL");
    // Each column takes its items' common type; untyped literals are text.
    try expectTyped("VALUES (1,'a',NULL),(2.5,'b',NULL)", "column1:1700,column2:25,column3:25", "1|a|NULL;2.5|b|NULL");
    try expectTyped("VALUES (1),(20000000000)", "column1:20", "1;20000000000");
    try expectTyped("VALUES (NULL),(NULL)", "column1:25", "NULL;NULL");
    try expectTyped("VALUES (1::smallint,'x'::text)", "column1:21,column2:25", "1|x");
    // Duplicates and row order are preserved; ORDER BY / OFFSET / LIMIT apply.
    try expect("VALUES (2),(1),(2)", "2;1;2");
    try expect("VALUES (2,'x'),(1,'y'),(2,'w') ORDER BY 1,column2", "1|y;2|w;2|x");
    try expect("VALUES (3),(1),(2) ORDER BY column1 DESC LIMIT 2 OFFSET 1", "2;1");
    try expect("VALUES (1) LIMIT 0", "");
    // In FROM, CTEs, set operations and subqueries, also correlated.
    try expect("SELECT column1+1 FROM (VALUES (1),(2)) v ORDER BY 1", "2;3");
    try expect("WITH w AS (VALUES (1,'a'),(2,'b')) SELECT column2 FROM w WHERE column1=2", "b");
    try expect("VALUES (1) UNION ALL SELECT 2 UNION ALL VALUES (3) ORDER BY 1", "1;2;3");
    try expect("VALUES (1),(1) UNION VALUES (1)", "1");
    try expect("SELECT id FROM tdd_a WHERE id IN (VALUES (2),(4)) ORDER BY id", "2;4");
    try expectTyped("SELECT (VALUES (7))", "column1:23", "7");
    try expect("SELECT EXISTS (VALUES (1))", "t");
    try expect("SELECT a.id,(VALUES (a.v)) FROM tdd_a a ORDER BY a.id", "1|10;2|20;3|30;4|NULL");
    try expect("TABLE nb ORDER BY k NULLS FIRST,y", "NULL|n;1|p;2|q;2|r;4|s");
    try expect("SELECT COUNT(*) FROM (TABLE tdd_b) t", "3");
    try expect("TABLE tdd_b UNION ALL TABLE tdd_b ORDER BY 1 LIMIT 3", "1|11;1|11;3|33");
    try expect("TABLE ONLY tdd_b ORDER BY id DESC LIMIT 1", "5|55");
    // Volatile items are evaluated once per row, in row order.
    try run("CREATE SEQUENCE vs");
    try expect("VALUES (nextval('vs')),(nextval('vs')),(nextval('vs'))", "1;2;3");
    // Errors.
    try rejects("VALUES (1),(2,3)", error.Syntax);
    try rejects("VALUES (DEFAULT)", error.Syntax);
    try rejects("VALUES ()", error.Syntax);
    try rejects("VALUES (1),('a')", error.InvalidTextRepresentation);
    try rejects("VALUES (1),(true)", error.TypeMismatch);
    try rejects("VALUES (1/0)", error.DivisionByZero);
    try rejects("VALUES (COUNT(*))", error.GroupingError);
    try rejects("VALUES (1) ORDER BY column2", error.ColumnNotFound);
    try rejects("VALUES (1) ORDER BY 2", error.InvalidColumnReference);
    try rejects("VALUES (1) ORDER BY column1+1", error.UnsupportedStatement);
    try rejects("TABLE missing", error.TableNotFound);
    try rejects("VALUES (1) LIMIT -1", error.InvalidRowCountInLimit);
    try controlled("VALUES (3),(1),(2),(1) ORDER BY 1", "1;1;2;3");
    try controlled("TABLE tdd_a ORDER BY id", "1|1|10;2|1|20;3|2|30;4|2|NULL");
}

// ---- PG.QUERY.LIMIT_EXPR --------------------------------------------------

fn limitExpressions() !void {
    // oracle
    try expectTyped("SELECT id FROM tdd_a ORDER BY id LIMIT (1+1) OFFSET (1+0)", "id:23", "2;3");
    // Constant expressions fold; untyped and NULL counts.
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT 2*1 OFFSET 3-2", "2;3");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT '2'", "1;2");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT NULL::int OFFSET NULL::bigint", "1;2;3;4");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT 1::smallint+1::smallint", "1;2");
    // Subqueries are evaluated once per execution of the query block.
    try expect("SELECT id FROM tdd_a ORDER BY id OFFSET (SELECT 3)", "4");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT (SELECT COUNT(*) FROM tdd_b)-1", "1;2");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT (SELECT NULL::int)", "1;2;3;4");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT (SELECT 0)", "");
    // Correlated counts follow the outer row.
    try expect("SELECT o.id,(SELECT COUNT(*) FROM (SELECT i.id FROM tdd_a i ORDER BY i.id LIMIT o.id) s) FROM tdd_a o ORDER BY o.id", "1|1;2|2;3|3;4|4");
    try expect("SELECT o.g,(SELECT SUM(v) FROM (SELECT v FROM tdd_b ORDER BY id OFFSET o.g) s) FROM tdd_a o WHERE o.id IN (1,3) ORDER BY o.g", "1|88;2|55");
    // A volatile count is evaluated exactly once.
    try run("CREATE SEQUENCE ls");
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT nextval('ls')", "1");
    try expect("SELECT currval('ls')", "1");
    // Set operations, VALUES and FETCH counts.
    try expect("SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 ORDER BY 1 LIMIT 1+1 OFFSET 1", "2;3");
    try expect("VALUES (1),(2),(3) LIMIT (SELECT 1)", "1");
    try expect("SELECT id FROM tdd_a ORDER BY id FETCH FIRST (1+1) ROWS ONLY", "1;2");
    try expect("SELECT id FROM tdd_a ORDER BY id OFFSET (1) ROWS FETCH NEXT (SELECT 2) ROWS ONLY", "2;3");
    try expect("SELECT id FROM tdd_a ORDER BY id FETCH FIRST NULL ROWS ONLY", "1;2;3;4");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY g ORDER BY g LIMIT (SELECT 1) OFFSET 1-0", "2|2");
    // Literal forms keep their behavior.
    try expect("SELECT id FROM tdd_a ORDER BY id LIMIT (2)", "1;2");
    try rejects("SELECT id FROM tdd_a LIMIT (-1)", error.InvalidRowCountInLimit);
    // Errors (PostgreSQL transformLimitClause / ExecLimit).
    try rejects("SELECT id FROM tdd_a LIMIT 1-2", error.InvalidRowCountInLimit);
    try rejects("SELECT id FROM tdd_a OFFSET 1-2 LIMIT 1-2", error.InvalidRowCountInResultOffset);
    try rejects("SELECT id FROM tdd_a LIMIT (SELECT -1)", error.InvalidRowCountInLimit);
    try rejects("SELECT id FROM tdd_a OFFSET (SELECT -1)", error.InvalidRowCountInResultOffset);
    try rejects("SELECT id FROM tdd_a LIMIT id", error.InvalidColumnReference);
    try rejects("SELECT id FROM tdd_a LIMIT COUNT(*)", error.GroupingError);
    try rejects("SELECT id FROM tdd_a LIMIT 1.5", error.TypeMismatch);
    try rejects("SELECT id FROM tdd_a LIMIT true", error.TypeMismatch);
    try rejects("SELECT id FROM tdd_a LIMIT 'x'", error.InvalidTextRepresentation);
    try rejects("SELECT id FROM tdd_a LIMIT 1/0", error.DivisionByZero);
    try rejects("SELECT id FROM tdd_a LIMIT (SELECT 1 UNION SELECT 2)", error.CardinalityViolation);
    try rejects("SELECT id FROM tdd_a LIMIT (SELECT id)", error.UnsupportedStatement);
    try controlled("SELECT id FROM tdd_a ORDER BY id LIMIT (SELECT COUNT(*) FROM tdd_b) OFFSET (SELECT 1)", "2;3;4");
}

// ---- PG.QUERY.FETCH_TIES --------------------------------------------------

fn fetchTies() !void {
    // oracle
    try expectTyped("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 1 ROW WITH TIES", "g:23", "1;1");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 2 ROWS WITH TIES", "1;1");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 3 ROWS WITH TIES", "1;1;2;2");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 9 ROWS WITH TIES", "1;1;2;2");
    try expect("SELECT g FROM tdd_a ORDER BY g DESC FETCH NEXT 1 ROW WITH TIES", "2;2");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST ROW WITH TIES", "1;1");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 0 ROWS WITH TIES", "");
    // Ties use every ORDER BY key; NULLs are peers.
    try expect("SELECT g,v FROM tdd_a ORDER BY g,v FETCH FIRST 1 ROW WITH TIES", "1|10");
    try expect("SELECT column1 FROM (VALUES (NULL::int),(NULL),(1)) v ORDER BY column1 NULLS FIRST FETCH FIRST 1 ROW WITH TIES", "NULL;NULL");
    try expectBag("SELECT id FROM tdd_a ORDER BY g FETCH FIRST 1 ROW WITH TIES", "1;2");
    // OFFSET applies first.
    try expect("SELECT g FROM tdd_a ORDER BY g OFFSET 1 ROW FETCH FIRST 1 ROW WITH TIES", "1");
    try expect("SELECT g FROM tdd_a ORDER BY g OFFSET 2 ROWS FETCH FIRST 1 ROW WITH TIES", "2;2");
    // Expression counts, set operations, grouping and DISTINCT.
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST (1+0) ROWS WITH TIES", "1;1");
    try expect("SELECT g FROM tdd_a ORDER BY g FETCH FIRST (SELECT 1) ROWS WITH TIES", "1;1");
    try expect("SELECT g FROM tdd_a UNION ALL SELECT 1 ORDER BY 1 FETCH FIRST 1 ROW WITH TIES", "1;1;1");
    try expectBag("SELECT g,COUNT(*) FROM tdd_a GROUP BY g ORDER BY COUNT(*) DESC FETCH FIRST 1 ROW WITH TIES", "1|2;2|2");
    try expect("SELECT DISTINCT g FROM tdd_a ORDER BY g FETCH FIRST 1 ROW WITH TIES", "1");
    try expect("VALUES (2),(1),(1) ORDER BY 1 FETCH FIRST 1 ROW WITH TIES", "1;1");
    try expect("SELECT (SELECT COUNT(*) FROM (SELECT g FROM tdd_a i WHERE i.g>=o.g ORDER BY i.g FETCH FIRST 1 ROW WITH TIES) s) FROM tdd_a o WHERE o.id IN (1,4) ORDER BY o.id", "2;2");
    // Errors.
    try rejects("SELECT g FROM tdd_a FETCH FIRST 1 ROW WITH TIES", error.Syntax);
    try rejects("SELECT g FROM tdd_a ORDER BY g LIMIT 1 WITH TIES", error.Syntax);
    try rejects("SELECT g FROM tdd_a ORDER BY g FETCH FIRST 1 ROW WITH", error.Syntax);
    try rejects("SELECT g FROM tdd_a ORDER BY g FETCH FIRST NULL ROWS WITH TIES", error.InvalidRowCountInLimit);
    try rejects("SELECT g FROM tdd_a ORDER BY g FETCH FIRST (SELECT NULL::int) ROWS WITH TIES", error.InvalidRowCountInLimit);
    try rejects("SELECT g FROM tdd_a ORDER BY g FETCH FIRST -1 ROWS WITH TIES", error.InvalidRowCountInLimit);
    try controlled("SELECT g FROM tdd_a ORDER BY g DESC FETCH FIRST 1 ROW WITH TIES", "2;2");
}

// ---- PG.GROUP.SETS / PG.GROUP.CUBE ----------------------------------------

fn groupingSets() !void {
    // oracle
    try expectTyped("SELECT g,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),()) ORDER BY GROUPING(g),g", "g:23,count:20", "1|2;2|2;NULL|4");
    try expect("SELECT g,v,SUM(v),GROUPING(g),GROUPING(v),GROUPING(g,v) FROM tdd_a GROUP BY GROUPING SETS ((g),(v),()) ORDER BY GROUPING(g,v),g,v NULLS FIRST",
        "1|NULL|30|0|1|1;2|NULL|30|0|1|1;NULL|NULL|NULL|1|0|2;NULL|10|10|1|0|2;NULL|20|20|1|0|2;NULL|30|30|1|0|2;NULL|NULL|60|1|1|3");
    // Repeated sets repeat their groups unless GROUP BY DISTINCT.
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),(g)) ORDER BY g", "1|2;1|2;2|2;2|2");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY DISTINCT GROUPING SETS ((g),(g)) ORDER BY g", "1|2;2|2");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY ROLLUP(g),g ORDER BY g", "1|2;1|2;2|2;2|2");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY ALL GROUPING SETS ((g)) ORDER BY g", "1|2;2|2");
    // Elements combine by cross product; composite and nested elements.
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY g,GROUPING SETS ((v),()) ORDER BY g,GROUPING(v),v NULLS FIRST", "1|10|1;1|20|1;1|NULL|2;2|NULL|1;2|30|1;2|NULL|2");
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY ROLLUP((g,v)) ORDER BY GROUPING(g,v),g,v", "1|10|1;1|20|1;2|30|1;2|NULL|1;NULL|NULL|4");
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS (g,ROLLUP(v),GROUPING SETS ((),())) ORDER BY GROUPING(g,v),g,v NULLS FIRST", "1|NULL|2;2|NULL|2;NULL|NULL|1;NULL|10|1;NULL|20|1;NULL|30|1;NULL|NULL|4;NULL|NULL|4;NULL|NULL|4");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY (g) ORDER BY g", "1|2;2|2");
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY (g,v) ORDER BY g,v", "1|10|1;1|20|1;2|30|1;2|NULL|1");
    // Expression keys, HAVING, DISTINCT aggregates, windows and joins.
    try expect("SELECT g+1,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g+1),()) ORDER BY 1", "2|2;3|2;NULL|4");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),()) HAVING COUNT(*)>2", "NULL|4");
    try expect("SELECT g,COUNT(DISTINCT v) FROM tdd_a GROUP BY GROUPING SETS ((g),()) ORDER BY GROUPING(g),g", "1|2;2|1;NULL|3");
    try expect("SELECT g,COUNT(*),RANK() OVER (ORDER BY COUNT(*) DESC) FROM tdd_a GROUP BY GROUPING SETS ((g),()) ORDER BY GROUPING(g),g", "1|2|2;2|2|2;NULL|4|1");
    try expect("SELECT g,a.v,COUNT(*) FROM tdd_a a JOIN tdd_b b USING (id) GROUP BY GROUPING SETS ((g,a.v),(g),(a.v),()) ORDER BY GROUPING(g,a.v),g,a.v", "1|10|1;2|30|1;1|NULL|1;2|NULL|1;NULL|10|1;NULL|30|1;NULL|NULL|2");
    // Empty input: only sets without keys produce a row.
    try expect("SELECT g,COUNT(*) FROM tdd_a WHERE false GROUP BY GROUPING SETS ((g),())", "NULL|0");
    try expect("SELECT g,COUNT(*),GROUPING(g) FROM tdd_a WHERE false GROUP BY GROUPING SETS ((),(g))", "NULL|0|1");
    try expect("SELECT g,COUNT(*) FROM tdd_a WHERE false GROUP BY GROUPING SETS ((g))", "");
    try expect("SELECT COUNT(*) FROM tdd_a WHERE false GROUP BY GROUPING SETS ((),())", "0;0");
    // A volatile input is evaluated once per row and shared by every set.
    try run("CREATE SEQUENCE gs");
    try expect("SELECT GROUPING(g),SUM(nextval('gs')) FROM tdd_a GROUP BY GROUPING SETS ((g),()) ORDER BY 1,2", "0|3;0|7;1|10");
    try expect("SELECT currval('gs')", "4");
    // Errors.
    try rejects("SELECT v,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),())", error.GroupingError);
    try rejects("SELECT GROUPING(v) FROM tdd_a GROUP BY GROUPING SETS ((g))", error.GroupingError);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ()", error.Syntax);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY ROLLUP(())", error.Syntax);
    try rejects("SELECT g,COUNT(DISTINCT v+1) FROM tdd_a GROUP BY GROUPING SETS ((g),())", error.UnsupportedStatement);
    try rejects("SELECT g,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),()) HAVING 1/(COUNT(*)-COUNT(*))>0", error.DivisionByZero);
    // 4096 sets exceed the statement's expression-node budget (54001).
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((id),()),GROUPING SETS ((g),()),GROUPING SETS ((v),()),GROUPING SETS ((id+1),()),GROUPING SETS ((g+1),()),GROUPING SETS ((v+1),()),GROUPING SETS ((id+2),()),GROUPING SETS ((g+2),()),GROUPING SETS ((v+2),()),GROUPING SETS ((id+3),()),GROUPING SETS ((g+3),()),GROUPING SETS ((v+3),())", error.StatementTooComplex);
    try controlled("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY GROUPING SETS ((g),(v),()) ORDER BY GROUPING(g,v),g,v NULLS FIRST", "1|NULL|2;2|NULL|2;NULL|NULL|1;NULL|10|1;NULL|20|1;NULL|30|1;NULL|NULL|4");
    // A one-row workspace cannot hold the groups (54000), atomically.
    try small.execute("CREATE TABLE t(id INTEGER PRIMARY KEY,k INTEGER)", &small_result);
    try small.execute("INSERT INTO t VALUES(1,1),(2,2),(3,3)", &small_result);
    try small.execute("SELECT 123", &small_result);
    if (small.execute("SELECT k,COUNT(*) FROM t GROUP BY GROUPING SETS ((k),())", &small_result)) |_| return error.ExpectedCapacity else |err| try check(err == error.WorkspaceCapacity);
    try check(small_result.row_count == 1 and small_result.rows[0].cells[0].integer == 123);
}

fn groupingCube() !void {
    // oracle
    try expectTyped("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY CUBE(g,v) ORDER BY GROUPING(g,v),g NULLS LAST,v NULLS LAST", "g:23,v:23,count:20",
        "1|10|1;1|20|1;2|30|1;2|NULL|1;1|NULL|2;2|NULL|2;NULL|10|1;NULL|20|1;NULL|30|1;NULL|NULL|1;NULL|NULL|4");
    try expect("SELECT g+1,COUNT(*) FROM tdd_a GROUP BY CUBE(g+1) ORDER BY 1", "2|2;3|2;NULL|4");
    try expect("SELECT g,COUNT(*) FROM tdd_a GROUP BY CUBE(g) HAVING COUNT(*)>2", "NULL|4");
    try expect("SELECT g,COUNT(DISTINCT v) FROM tdd_a GROUP BY CUBE(g) ORDER BY GROUPING(g),g", "1|2;2|1;NULL|3");
    try expect("SELECT g,a.v,COUNT(*) FROM tdd_a a JOIN tdd_b b USING (id) GROUP BY CUBE(g,a.v) ORDER BY GROUPING(g,a.v),g,a.v", "1|10|1;2|30|1;1|NULL|1;2|NULL|1;NULL|10|1;NULL|30|1;NULL|NULL|2");
    // Composite items and a CUBE crossed with plain keys.
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY CUBE((g,v)) ORDER BY GROUPING(g,v),g,v", "1|10|1;1|20|1;2|30|1;2|NULL|1;NULL|NULL|4");
    try expect("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY g,CUBE(v) ORDER BY g,GROUPING(v),v NULLS FIRST", "1|10|1;1|20|1;1|NULL|2;2|NULL|1;2|30|1;2|NULL|2");
    try expectBag("SELECT COUNT(*) FROM tdd_a GROUP BY CUBE(g,g)", "2;2;2;2;2;2;4");
    // Empty input and a column named cube.
    try expect("SELECT g,COUNT(*),GROUPING(g) FROM tdd_a WHERE false GROUP BY CUBE(g)", "NULL|0|1");
    try expect("SELECT cube,COUNT(*) FROM (SELECT g AS cube FROM tdd_a) c GROUP BY cube ORDER BY cube", "1|2;2|2");
    // Volatile input once per row.
    try expect("SELECT GROUPING(g),SUM(nextval('gs')) FROM tdd_a GROUP BY CUBE(g) ORDER BY 1,2", "0|11;0|15;1|26");
    // Errors: PostgreSQL limits CUBE to 12 elements (54000); 4096 sets
    // exceed the expression-node budget here (54001).
    try rejects("SELECT GROUPING(v) FROM tdd_a GROUP BY CUBE(g)", error.GroupingError);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY CUBE()", error.Syntax);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY CUBE(())", error.Syntax);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY CUBE(id,g,v,id+1,g+1,v+1,id+2,g+2,v+2,id+3,g+3,v+3,id+4)", error.ProgramLimitExceeded);
    try rejects("SELECT COUNT(*) FROM tdd_a GROUP BY CUBE(id,g,v,id+1,g+1,v+1,id+2,g+2,v+2,id+3,g+3,v+3)", error.StatementTooComplex);
    try rejects("SELECT g,COUNT(DISTINCT v+1) FROM tdd_a GROUP BY CUBE(g)", error.UnsupportedStatement);
    try controlled("SELECT g,v,COUNT(*) FROM tdd_a GROUP BY CUBE(g,v) ORDER BY GROUPING(g,v),g NULLS LAST,v NULLS LAST",
        "1|10|1;1|20|1;2|30|1;2|NULL|1;1|NULL|2;2|NULL|2;NULL|10|1;NULL|20|1;NULL|30|1;NULL|NULL|1;NULL|NULL|4");
    if (small.execute("SELECT k,COUNT(*) FROM t GROUP BY CUBE(k)", &small_result)) |_| return error.ExpectedCapacity else |err| try check(err == error.WorkspaceCapacity);
    try check(small_result.row_count == 1 and small_result.rows[0].cells[0].integer == 123);
}

// ---- PG.QUERY.CTE_MATERIALIZATION -----------------------------------------

fn cteMaterialization() !void {
    // oracle
    try expectTyped("WITH x AS NOT MATERIALIZED (SELECT id FROM tdd_a) SELECT * FROM x ORDER BY id", "id:23", "1;2;3;4");
    try expect("WITH x AS MATERIALIZED (SELECT id FROM tdd_a) SELECT * FROM x ORDER BY id", "1;2;3;4");
    try expect("WITH x(a) AS MATERIALIZED (SELECT id FROM tdd_a WHERE id<3), y AS NOT MATERIALIZED (SELECT a*10 AS b FROM x) SELECT a,b FROM x JOIN y ON b=a*10 ORDER BY a", "1|10;2|20");
    try expect("WITH RECURSIVE r(n) AS MATERIALIZED (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) SELECT * FROM r", "1;2;3");
    try expect("WITH RECURSIVE r(n) AS NOT MATERIALIZED (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<3) SELECT COUNT(*) FROM r", "3");
    // A volatile body is never inlined: every reference sees one evaluation.
    try run("CREATE SEQUENCE ms");
    try expect("WITH s AS NOT MATERIALIZED (SELECT nextval('ms') AS n) SELECT a.n,b.n FROM s a,s b", "1|1");
    try expect("WITH s AS MATERIALIZED (SELECT nextval('ms') AS n) SELECT a.n=b.n FROM s a,s b", "t");
    try expect("SELECT currval('ms')", "2");
    // Duplicates, NULLs and empty bodies pass through unchanged.
    try expect("WITH x AS NOT MATERIALIZED (SELECT v FROM tdd_a UNION ALL SELECT v FROM tdd_a WHERE v IS NULL) SELECT v FROM x ORDER BY v NULLS FIRST", "NULL;NULL;10;20;30");
    try expect("WITH x AS MATERIALIZED (SELECT id FROM tdd_a WHERE false) SELECT COUNT(*) FROM x", "0");
    // An unreferenced CTE is not executed.
    try expect("WITH x AS NOT MATERIALIZED (SELECT 1/0) SELECT 1", "1");
    // Errors.
    try rejects("WITH x AS NOT (SELECT 1) SELECT 1", error.Syntax);
    try rejects("WITH x AS MATERIALIZED SELECT 1", error.Syntax);
    try rejects("WITH x AS MATERIALIZED MATERIALIZED (SELECT 1) SELECT 1", error.Syntax);
    try rejects("WITH x AS NOT MATERIALIZED (SELECT 1), x AS (SELECT 2) SELECT 1", error.Syntax);
    try controlled("WITH x AS NOT MATERIALIZED (SELECT id FROM tdd_a) SELECT * FROM x ORDER BY id", "1;2;3;4");
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try naturalJoins();
    try joinTrees();
    try valuesAndTable();
    try limitExpressions();
    try fetchTies();
    try groupingSets();
    try groupingCube();
    try cteMaterialization();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-query-composition\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
