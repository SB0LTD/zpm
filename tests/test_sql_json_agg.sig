//! JSON and aggregate contracts (conformance lane B11, json-agg): string,
//! array and JSON aggregates with ORDER BY / DISTINCT / FILTER, ordered-set
//! and hypothetical-set aggregates (WITHIN GROUP), the remaining JSONB
//! modification operations, SQL/JSON path (jsonpath, jsonb_path_*, @? and
//! @@) and JSON_TABLE. Each section checks values in PostgreSQL 18 text
//! output, column names and type OIDs, NULLs and empty inputs, exact errors
//! (SQLSTATE through the error name) with an unchanged result afterwards,
//! the statement work budget / cancellation checkpoints, and replay of
//! committed change records into a replica.
//!
//! Fixtures copied from tests/sql_conformance/postgres18_oracle.json are
//! marked "oracle". Every other expectation is derived from the PostgreSQL
//! 18 documentation and source and is PENDING NATIVE VERIFICATION.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 10, .columns = 16, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 256, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 2048, .work_rows = 128, .result_rows = 64, .relations = 6 });
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .text_bytes = 128, .work_rows = 1, .result_rows = 8, .nulls_first_ascending = false, .integer_bits = 32 });

var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var small: Small = .{};
var small_result: Small.Result = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("json-agg contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.JsonAggContractFailed;
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
    try run("CREATE TABLE w(id INT PRIMARY KEY, s TEXT, f FLOAT8, b BOOLEAN, d DATE, ts TIMESTAMP, a INT[], j JSON, jb JSONB)");
    try run("INSERT INTO w VALUES(1,'a',1.5,true,'2024-01-02','2024-01-02 03:04:05',ARRAY[1,2],'{\"b\":1, \"a\":2}','{\"k\":[1,2]}')," ++
        "(2,NULL,'NaN',false,NULL,NULL,ARRAY[3,4],NULL,NULL),(3,'x\"y','-Infinity',NULL,'infinity','2024-01-02 03:04:05.5',NULL,'[1,2]','\"s\"')");
}

// ---- PG.AGG.COLLECTION ------------------------------------------------------

fn collectionAggregates() !void {
    // oracle
    try expectTyped("SELECT g,STRING_AGG(id::text,',' ORDER BY id),ARRAY_AGG(v ORDER BY id) FROM tdd_a GROUP BY g ORDER BY g", "g:23,string_agg:25,array_agg:1007", "1|1,2|{10,20};2|3,4|{30,NULL}");
    // Direction and NULL placement of the aggregate's own ORDER BY.
    try expect("SELECT array_agg(v ORDER BY v DESC) FROM tdd_a", "{NULL,30,20,10}");
    try expect("SELECT array_agg(v ORDER BY v DESC NULLS LAST) FROM tdd_a", "{30,20,10,NULL}");
    try expect("SELECT array_agg(v ORDER BY v NULLS FIRST) FROM tdd_a", "{NULL,10,20,30}");
    try expect("SELECT array_agg(id ORDER BY g DESC, id) FROM tdd_a", "{3,4,1,2}");
    try expect("SELECT string_agg(id::text, '-' ORDER BY id DESC) FROM tdd_a", "4-3-2-1");
    // string_agg skips NULL values; a NULL delimiter appends nothing and
    // the first delimiter is dropped.
    try expect("SELECT string_agg(x, d ORDER BY n) FROM (VALUES (1,'a',','),(2,NULL,';'),(3,'b',NULL),(4,'c','+')) AS t(n,x,d)", "ab+c");
    try expect("SELECT string_agg(x, d ORDER BY n) FROM (VALUES (1,NULL,','),(2,'a',';')) AS t(n,x,d)", "a");
    try expect("SELECT string_agg(s, ',' ORDER BY id) FROM w", "a,x\"y");
    try expectTyped("SELECT string_agg(s::bytea, '-'::bytea ORDER BY id) FROM w", "string_agg:17", "\\x612d782279");
    // Empty and all-NULL inputs.
    try expect("SELECT array_agg(v), string_agg(v::text, ','), array_agg(v ORDER BY id) FROM tdd_a WHERE id > 9", "NULL|NULL|NULL");
    try expect("SELECT array_agg(v), string_agg(v::text, ',') FROM tdd_a WHERE id = 4", "{NULL}|NULL");
    // DISTINCT: sorted values, one NULL.
    try expect("SELECT array_agg(DISTINCT g) FROM tdd_a", "{1,2}");
    try expect("SELECT array_agg(DISTINCT v) FROM (SELECT v FROM tdd_a UNION ALL SELECT v FROM tdd_a) s", "{10,20,30,NULL}");
    try expect("SELECT array_agg(DISTINCT g ORDER BY g DESC) FROM tdd_a", "{2,1}");
    try expect("SELECT string_agg(DISTINCT g::text, ',') FROM tdd_a", "1,2");
    // FILTER and grouped keys.
    try expect("SELECT array_agg(id ORDER BY id) FILTER (WHERE v > 10) FROM tdd_a", "{2,3}");
    try expect("SELECT g, array_agg(id ORDER BY id DESC) FILTER (WHERE v IS NOT NULL) FROM tdd_a GROUP BY g ORDER BY g", "1|{2,1};2|{3}");
    // Ordinary aggregates accept ORDER BY (inputs sorted first).
    try expect("SELECT sum(v ORDER BY id), count(v ORDER BY id DESC), max(v ORDER BY v), count(DISTINCT v ORDER BY v) FROM tdd_a", "60|3|30|3");
    try expect("SELECT g, sum(v ORDER BY id) FROM tdd_a GROUP BY g ORDER BY g", "1|30;2|30");
    // array_agg of arrays adds a dimension; element types follow the input.
    try expectTyped("SELECT array_agg(a ORDER BY id) FROM w WHERE a IS NOT NULL", "array_agg:1007", "{{1,2},{3,4}}");
    try expectTyped("SELECT array_agg(s ORDER BY id), array_agg(f ORDER BY id), array_agg(b ORDER BY id) FROM w", "array_agg:1009,array_agg:1022,array_agg:1000", "{a,NULL,\"x\\\"y\"}|{1.5,NaN,-Infinity}|{t,f,NULL}");
    try expect("SELECT array_agg(d ORDER BY id) FROM w", "{2024-01-02,NULL,infinity}");
    try expect("SELECT array_agg(x ORDER BY x) FROM (VALUES ('b'::varchar), ('a'::varchar)) AS t(x)", "{a,b}");
    try run("SELECT array_agg(x) FROM (VALUES ('b'::varchar)) AS t(x)");
    try same(try metadata(&result), "array_agg:1015");
    // Errors: untyped polymorphic input (42804), unequal sub-arrays (2202E),
    // a NULL sub-array (22004), ORDER BY on a non-aggregate (42809),
    // DISTINCT with an ORDER BY outside the arguments (42P10), window forms
    // and operators without a sorted input (0A000).
    try rejects("SELECT array_agg('a')", error.TypeMismatch);
    try rejects("SELECT array_agg(a) FROM (VALUES (ARRAY[1]), (ARRAY[1,2])) AS t(a)", error.ArraySubscriptError);
    try rejects("SELECT array_agg(a) FROM w", error.NullValueNotAllowed);
    try rejects("SELECT array_agg(a) FROM (VALUES ('{}'::int[])) AS t(a)", error.ArraySubscriptError);
    try rejects("SELECT lower('A' ORDER BY 1)", error.WrongObjectType);
    try rejects("SELECT array_agg(DISTINCT v ORDER BY id) FROM tdd_a", error.InvalidColumnReference);
    try rejects("SELECT array_agg(v ORDER BY id) OVER () FROM tdd_a", error.UnsupportedStatement);
    try rejects("SELECT array_agg(v) OVER () FROM tdd_a", error.UnsupportedStatement);
    try rejects("SELECT g, array_agg(v) FROM tdd_a GROUP BY ROLLUP(g)", error.UnsupportedStatement);
    try rejects("SELECT string_agg(id, ',') FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT string_agg(s) FROM w", error.UndefinedFunction);
    try rejects("SELECT array_agg(j ORDER BY j) FROM w", error.UndefinedFunction);
    try rejects("SELECT array_agg(*) FROM w", error.UndefinedFunction);
    try rejects("SELECT array_agg(array_agg(v)) FROM tdd_a", error.GroupingError);
    try rejects("SELECT id FROM tdd_a WHERE array_agg(v) IS NULL", error.GroupingError);
    // Results live in one cell: past text_bytes is TextCapacity (54000).
    try rejects("SELECT string_agg(repeat('x', 100), ',') FROM tdd_a", error.TextCapacity);
    // Work budget and cancellation over collection, sorting and folding.
    try controlled("SELECT g,STRING_AGG(id::text,',' ORDER BY id),ARRAY_AGG(v ORDER BY id) FROM tdd_a GROUP BY g ORDER BY g", "1|1,2|{10,20};2|3,4|{30,NULL}");
    // A one-row workspace cannot hold a group's inputs (54000).
    try smallRun("CREATE TABLE s(id INT PRIMARY KEY, v INT)");
    try smallRun("INSERT INTO s VALUES (1,1),(2,2),(3,3),(4,4),(5,5)");
    if (small.execute("SELECT array_agg(v ORDER BY id) FROM s", &small_result)) |_| {
        try check(false);
    } else |err| try check(err == error.WorkspaceCapacity);
}

fn smallRun(source: []const u8) !void {
    small.execute(source, &small_result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

// ---- PG.JSON.AGG ----------------------------------------------------------------

fn jsonAggregates() !void {
    // oracle
    try expectTyped("SELECT JSON_AGG(id ORDER BY id),JSONB_OBJECT_AGG(id::text,v) FROM tdd_a", "json_agg:114,jsonb_object_agg:3802", "[1, 2, 3, 4]|{\"1\": 10, \"2\": 20, \"3\": 30, \"4\": null}");
    try expectTyped("SELECT jsonb_agg(v ORDER BY id), json_object_agg(id, v ORDER BY id) FROM tdd_a", "jsonb_agg:3802,json_object_agg:114", "[10, 20, 30, null]|{ \"1\" : 10, \"2\" : 20, \"3\" : 30, \"4\" : null }");
    // to_json categories: strings escaped, NaN/infinity as strings, dates
    // and timestamps in XSD form, json verbatim, jsonb as text.
    try expect("SELECT json_agg(s ORDER BY id), jsonb_agg(s ORDER BY id) FROM w", "[\"a\", null, \"x\\\"y\"]|[\"a\", null, \"x\\\"y\"]");
    try expect("SELECT json_agg(f ORDER BY id), jsonb_agg(f ORDER BY id) FROM w", "[1.5, \"NaN\", \"-Infinity\"]|[1.5, \"NaN\", \"-Infinity\"]");
    try expect("SELECT json_agg(b ORDER BY id), json_agg(d ORDER BY id), json_agg(ts ORDER BY id) FROM w", "[true, false, null]|[\"2024-01-02\", null, \"infinity\"]|[\"2024-01-02T03:04:05\", null, \"2024-01-02T03:04:05.5\"]");
    try expect("SELECT json_agg(j ORDER BY id), jsonb_agg(j ORDER BY id), json_agg(jb ORDER BY id) FROM w", "[{\"b\":1, \"a\":2}, null, [1,2]]|[{\"a\": 2, \"b\": 1}, null, [1, 2]]|[{\"k\": [1, 2]}, null, \"s\"]");
    // Arrays: nested JSON arrays; json separates later ones with ", \n ".
    try expect("SELECT json_agg(a ORDER BY id), jsonb_agg(a ORDER BY id) FROM w", "[[1,2], \n [3,4], null]|[[1, 2], [3, 4], null]");
    try expect("SELECT json_agg(x) FROM (VALUES (ARRAY[[1,2],[3,4]])) AS t(x)", "[[[1,2],[3,4]]]");
    try expect("SELECT json_agg(x) FROM (VALUES ('2024-01-02 03:04:05+00'::timestamptz)) AS t(x)", "[\"2024-01-02T03:04:05+00:00\"]");
    try expect("SELECT json_agg(x) FROM (VALUES ('{}'::int[])) AS t(x)", "[[]]");
    try expect("SELECT json_agg(x), jsonb_agg(x) FROM (VALUES ('1 day'::interval)) AS t(x)", "[\"1 day\"]|[\"1 day\"]");
    try expect("SELECT json_agg(x), jsonb_agg(x) FROM (VALUES (1.50::numeric), ('NaN'::numeric)) AS t(x)", "[1.50, \"NaN\"]|[1.50, \"NaN\"]");
    // Object keys are strings; jsonb sorts keys and keeps the last duplicate.
    try expect("SELECT jsonb_object_agg(k, n ORDER BY n) FROM (VALUES ('bb',1),('a',2),('bb',3)) AS t(k,n)", "{\"a\": 2, \"bb\": 3}");
    try expect("SELECT json_object_agg(k, n ORDER BY n) FROM (VALUES ('bb',1),('a',2),('bb',3)) AS t(k,n)", "{ \"bb\" : 1, \"a\" : 2, \"bb\" : 3 }");
    try expect("SELECT json_object_agg(b, f ORDER BY id), jsonb_object_agg(d, s ORDER BY id) FILTER (WHERE d IS NOT NULL) FROM w WHERE b IS NOT NULL", "{ \"true\" : 1.5, \"false\" : \"NaN\" }|{\"2024-01-02\": \"a\"}");
    try expect("SELECT jsonb_object_agg('k', 'v'), json_object_agg('k', NULL::text)", "{\"k\": \"v\"}|{ \"k\" : null }");
    try expect("SELECT json_agg(DISTINCT g), jsonb_agg(DISTINCT g ORDER BY g DESC) FROM tdd_a", "[1, 2]|[2, 1]");
    try expect("SELECT g, json_agg(v ORDER BY id) FROM tdd_a GROUP BY g ORDER BY g", "1|[10, 20];2|[30, null]");
    try expect("SELECT json_agg(v), jsonb_object_agg(id, v) FROM tdd_a WHERE false", "NULL|NULL");
    // Errors: NULL keys (22004), non-scalar keys (22023), untyped
    // polymorphic input (42804), the result past text_bytes (54000).
    try rejects("SELECT jsonb_object_agg(s, id) FROM w", error.NullValueNotAllowed);
    try rejects("SELECT json_object_agg(NULL::text, 1)", error.NullValueNotAllowed);
    try rejects("SELECT jsonb_object_agg(a, id) FROM w WHERE a IS NOT NULL", error.InvalidParameterValue);
    try rejects("SELECT json_object_agg(j, id) FROM w WHERE j IS NOT NULL", error.InvalidParameterValue);
    try rejects("SELECT jsonb_object_agg(jb, id) FROM w WHERE jb IS NOT NULL", error.InvalidParameterValue);
    try rejects("SELECT json_agg('a')", error.TypeMismatch);
    try rejects("SELECT jsonb_agg(v, v) FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT json_agg(repeat('x', 100)) FROM tdd_a", error.TextCapacity);
    try controlled("SELECT JSON_AGG(id ORDER BY id),JSONB_OBJECT_AGG(id::text,v) FROM tdd_a", "[1, 2, 3, 4]|{\"1\": 10, \"2\": 20, \"3\": 30, \"4\": null}");
}

// ---- PG.AGG.ORDERED_SET -------------------------------------------------------

fn orderedSetAggregates() !void {
    // oracle
    try expectTyped("SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v),PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY v),MODE() WITHIN GROUP (ORDER BY g) FROM tdd_a", "percentile_cont:701,percentile_disc:23,mode:23", "20|20|1");
    // Interpolation (floor/ceil of fraction * (n - 1)) and the discrete
    // rule K = ceil(fraction * n); NULL inputs are ignored.
    try expect("SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY v), percentile_cont(0.75) WITHIN GROUP (ORDER BY v), percentile_cont(0) WITHIN GROUP (ORDER BY v), percentile_cont(1) WITHIN GROUP (ORDER BY v) FROM tdd_a", "15|25|10|30");
    try expect("SELECT percentile_disc(0.25) WITHIN GROUP (ORDER BY v), percentile_disc(0) WITHIN GROUP (ORDER BY v), percentile_disc(0.34) WITHIN GROUP (ORDER BY v), percentile_disc(1) WITHIN GROUP (ORDER BY v) FROM tdd_a", "10|10|20|30");
    try expect("SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY v DESC), percentile_disc(0.25) WITHIN GROUP (ORDER BY v DESC) FROM tdd_a", "25|30");
    try expectTyped("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) FROM (VALUES ('1 day'::interval), ('3 days 12:00'::interval)) AS t(x)", "percentile_cont:1186", "2 days 06:00:00");
    try expectTyped("SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY s) FROM w", "percentile_disc:25", "a");
    try expect("SELECT g, percentile_cont(0.5) WITHIN GROUP (ORDER BY v) FROM tdd_a GROUP BY g ORDER BY g", "1|15;2|30");
    // Direct arguments may read grouped expressions (evaluated per group).
    try expect("SELECT g, percentile_disc(g / 2.0) WITHIN GROUP (ORDER BY v) FROM tdd_a GROUP BY g ORDER BY g", "1|10;2|30");
    try expect("SELECT percentile_cont(NULL) WITHIN GROUP (ORDER BY v), percentile_cont(0.5) WITHIN GROUP (ORDER BY v) FILTER (WHERE v > 15) FROM tdd_a", "NULL|25");
    try expect("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v), mode() WITHIN GROUP (ORDER BY v) FROM tdd_a WHERE v IS NULL", "NULL|NULL");
    try expect("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY f) FROM w WHERE id = 1", "1.5");
    // mode: the most frequent value; ties go to the first in sort order.
    try expect("SELECT mode() WITHIN GROUP (ORDER BY x), mode() WITHIN GROUP (ORDER BY x DESC) FROM (VALUES (3),(1),(3),(1),(2)) AS t(x)", "1|3");
    try expect("SELECT mode() WITHIN GROUP (ORDER BY x) FROM (VALUES ('b'),('a'),('b')) AS t(x)", "b");
    // Hypothetical-set aggregates: the hypothetical row sorts before its
    // peers (after them for cume_dist); NULL rows count by NULLS LAST.
    try expectTyped("SELECT rank(20) WITHIN GROUP (ORDER BY v), dense_rank(20) WITHIN GROUP (ORDER BY v), percent_rank(20) WITHIN GROUP (ORDER BY v), cume_dist(20) WITHIN GROUP (ORDER BY v) FROM tdd_a", "rank:20,dense_rank:20,percent_rank:701,cume_dist:701", "2|2|0.25|0.6");
    try expect("SELECT rank(2, 3) WITHIN GROUP (ORDER BY g, id), dense_rank(1) WITHIN GROUP (ORDER BY g DESC) FROM tdd_a", "3|2");
    try expect("SELECT rank(NULL) WITHIN GROUP (ORDER BY v), cume_dist(NULL) WITHIN GROUP (ORDER BY v NULLS FIRST) FROM tdd_a", "4|0.4");
    try expect("SELECT rank(5) WITHIN GROUP (ORDER BY v), percent_rank(5) WITHIN GROUP (ORDER BY v), cume_dist(5) WITHIN GROUP (ORDER BY v) FROM tdd_a WHERE false", "1|0|1");
    try expect("SELECT dense_rank(30) WITHIN GROUP (ORDER BY x) FROM (VALUES (10),(10),(20),(30)) AS t(x)", "3");
    // Errors: fraction outside [0, 1] (22003), WITHIN GROUP required or
    // not allowed (42809), direct arguments over ungrouped columns (42803),
    // untyped / ambiguous keys (42804 / 42725), argument counts (42883),
    // OVER (0A000).
    try rejects("SELECT percentile_cont(1.5) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.NumericValueOutOfRange);
    try rejects("SELECT percentile_disc(-0.1) WITHIN GROUP (ORDER BY v) FROM tdd_a WHERE false", error.NumericValueOutOfRange);
    try rejects("SELECT percentile_cont('NaN'::float8) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.NumericValueOutOfRange);
    try rejects("SELECT percentile_cont(v) FROM tdd_a", error.WrongObjectType);
    try rejects("SELECT mode(v) FROM tdd_a", error.WrongObjectType);
    try rejects("SELECT sum(v) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.WrongObjectType);
    try rejects("SELECT nosuch(1) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT percentile_cont(v / 100.0) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.GroupingError);
    try rejects("SELECT mode() WITHIN GROUP (ORDER BY 'a')", error.TypeMismatch);
    try rejects("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY 'a')", error.AmbiguousFunction);
    try rejects("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY s) FROM w", error.UndefinedFunction);
    try rejects("SELECT percentile_cont(0.5, 0.6) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v, id) FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT rank(1, 2) WITHIN GROUP (ORDER BY v) FROM tdd_a", error.UndefinedFunction);
    try rejects("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) OVER () FROM tdd_a", error.UnsupportedStatement);
    try rejects("SELECT id FROM tdd_a WHERE mode() WITHIN GROUP (ORDER BY v) = 1", error.GroupingError);
    try rejects("SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY j) FROM w", error.UndefinedFunction);
    try controlled("SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v),PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY v),MODE() WITHIN GROUP (ORDER BY g) FROM tdd_a", "20|20|1");
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try collectionAggregates();
    try jsonAggregates();
    try orderedSetAggregates();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-json-agg\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
