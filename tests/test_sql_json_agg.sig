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

const DB = sql.Database(.{ .tables = 10, .columns = 16, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 256, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .expr_nodes = 2048, .work_rows = 128, .result_rows = 64, .relations = 6, .jsonpath_items = 16 });
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

// ---- PG.JSONB.MODIFY ----------------------------------------------------------

fn jsonbModify() !void {
    // oracle
    try expectTyped("SELECT jsonb_set('{\"a\":1}'::jsonb,'{a}','2'::jsonb),'{\"a\":1}'::jsonb||'{\"b\":2}'::jsonb", "jsonb_set:3802,?column?:3802", "{\"a\": 2}|{\"a\": 1, \"b\": 2}");
    // jsonb_set: replace, create (sorted into place), create_if_missing
    // false, nested paths, array indexes (negative, past either end).
    try expect("SELECT jsonb_set('{\"a\":1}', '{b}', '[1]'), jsonb_set('{\"a\":1}', '{b}', '2', false), jsonb_set('{\"b\":1}', '{a}', 'null')", "{\"a\": 1, \"b\": [1]}|{\"a\": 1}|{\"a\": null, \"b\": 1}");
    try expect("SELECT jsonb_set('{\"a\":{\"b\":[1,2,3]}}', '{a,b,1}', '\"x\"'), jsonb_set('{\"a\":1}', '{x,y}', '2'), jsonb_set('{\"a\":1}', '{}', '2')", "{\"a\": {\"b\": [1, \"x\", 3]}}|{\"a\": 1}|{\"a\": 1}");
    try expect("SELECT jsonb_set('[1,2]', '{5}', '3'), jsonb_set('[1,2]', '{-5}', '0'), jsonb_set('[1,2]', '{-1}', '9'), jsonb_set('[1,2]', '{ 0}', '7'), jsonb_set('[]', '{3}', '1')", "[1, 2, 3]|[0, 1, 2]|[1, 9]|[7, 2]|[1]");
    try expect("SELECT jsonb_set('{}', '{a}', '1', false), jsonb_set('{}', '{a}', '1'), jsonb_set('{\"a\":1}', '{a}', NULL), jsonb_set(NULL, '{a}', '1')", "{}|{\"a\": 1}|NULL|NULL");
    try expect("SELECT jsonb_set('{\"a\":1}', '{a,b}', '2'), jsonb_set('[[1]]', '{0,0}', '{\"k\":1}')", "{\"a\": 1}|[[{\"k\": 1}]]");
    // jsonb_insert: before (default) or after an array element; a new key;
    // an existing key is 22023.
    try expect("SELECT jsonb_insert('{\"a\":[0,1,2]}', '{a,1}', '\"new\"'), jsonb_insert('{\"a\":[0,1,2]}', '{a,1}', '\"new\"', true), jsonb_insert('{\"a\":1}', '{b}', '2'), jsonb_insert('[1]', '{-9}', '0')", "{\"a\": [0, \"new\", 1, 2]}|{\"a\": [0, 1, \"new\", 2]}|{\"a\": 1, \"b\": 2}|[0, 1]");
    try rejects("SELECT jsonb_insert('{\"a\":1}', '{a}', '2')", error.InvalidParameterValue);
    // jsonb_set_lax: NULL values by treatment.
    try expect("SELECT jsonb_set_lax('{\"a\":1,\"b\":2}', '{b}', NULL), jsonb_set_lax('{\"a\":1,\"b\":2}', '{b}', NULL, true, 'delete_key'), jsonb_set_lax('{\"a\":1,\"b\":2}', '{b}', NULL, true, 'return_target'), jsonb_set_lax('{\"a\":1}', '{a}', '5')", "{\"a\": 1, \"b\": null}|{\"a\": 1}|{\"a\": 1, \"b\": 2}|{\"a\": 5}");
    try expect("SELECT jsonb_set_lax(NULL, '{a}', '1'), jsonb_set_lax('{}', '{a}', '1', NULL)", "NULL|NULL");
    try rejects("SELECT jsonb_set_lax('{\"a\":1}', '{a}', NULL, true, 'raise_exception')", error.NullValueNotAllowed);
    try rejects("SELECT jsonb_set_lax('{\"a\":1}', '{a}', NULL, true, 'bogus')", error.InvalidParameterValue);
    try rejects("SELECT jsonb_set_lax('{\"a\":1}', '{a}', '1', true, NULL)", error.InvalidParameterValue);
    // Deletion: - text | integer | text[], #- and jsonb_delete_path.
    try expectTyped("SELECT '{\"a\":1,\"b\":2}'::jsonb - 'a', '[\"a\",\"b\",\"a\"]'::jsonb - 'a', '{\"a\":1,\"b\":2,\"c\":3}'::jsonb - '{a,c}'::text[]", "?column?:3802,?column?:3802,?column?:3802", "{\"b\": 2}|[\"b\"]|{\"b\": 2}");
    try expect("SELECT '[1,2,3]'::jsonb - 1, '[1,2,3]'::jsonb - -1, '[1,2,3]'::jsonb - 9, '[1,2,3]'::jsonb - -9, '{\"a\":1}'::jsonb - '{}'::text[]", "[1, 3]|[1, 2]|[1, 2, 3]|[1, 2, 3]|{\"a\": 1}");
    try expect("SELECT '{\"a\":{\"b\":1,\"c\":2}}'::jsonb #- '{a,b}', '[1,[2,3]]'::jsonb #- '{1,0}', jsonb_delete_path('{\"a\":1}', '{x}'), '{}'::jsonb #- '{a}'", "{\"a\": {\"c\": 2}}|[1, [3]]|{\"a\": 1}|{}");
    try rejects("SELECT '{\"a\":1}'::jsonb - 0", error.InvalidParameterValue);
    try rejects("SELECT '1'::jsonb - 'a'", error.InvalidParameterValue);
    try rejects("SELECT '\"x\"'::jsonb #- '{a}'", error.InvalidParameterValue);
    try rejects("SELECT '{}'::jsonb - 1::bigint", error.UndefinedFunction);
    // ?| and ?& (NULL keys skipped).
    try expectTyped("SELECT '{\"a\":1,\"b\":2}'::jsonb ?| ARRAY['b','x'], '{\"a\":1,\"b\":2}'::jsonb ?& ARRAY['a','b'], '{\"a\":1}'::jsonb ?& '{a,x}', '{\"a\":1}'::jsonb ?& '{}', '{\"a\":1}'::jsonb ?| '{}'", "?column?:16,?column?:16,?column?:16,?column?:16,?column?:16", "t|t|f|t|f");
    try expect("SELECT '[\"a\",1]'::jsonb ?| ARRAY[NULL,'a'], '\"a\"'::jsonb ?& ARRAY['a'], jsonb_exists_any('{\"k\":1}', '{k}')", "t|t|t");
    // jsonb_strip_nulls (strip_in_arrays) and jsonb_pretty.
    try expect("SELECT jsonb_strip_nulls('{\"a\":null,\"b\":[1,null],\"c\":{\"d\":null}}'), jsonb_strip_nulls('{\"a\":null,\"b\":[1,null]}', true), jsonb_strip_nulls('null')", "{\"b\": [1, null], \"c\": {}}|{\"b\": [1]}|null");
    try expectTyped("SELECT jsonb_pretty('{\"a\":1,\"b\":[1,{\"c\":2}],\"d\":{}}')", "jsonb_pretty:25", "{\n    \"a\": 1,\n    \"b\": [\n        1,\n        {\n            \"c\": 2\n        }\n    ],\n    \"d\": {\n    }\n}");
    try expect("SELECT jsonb_pretty('[]'), jsonb_pretty('\"s\"')", "[\n]|\"s\"");
    // to_json / to_jsonb.
    try expectTyped("SELECT to_json('x\"y'::text), to_jsonb(ARRAY[1,2]), to_json(1.50), to_jsonb(NULL::int), to_json(DATE '2024-01-02')", "to_json:114,to_jsonb:3802,to_json:114,to_jsonb:3802,to_json:114", "\"x\\\"y\"|[1, 2]|1.50|NULL|\"2024-01-02\"");
    // Errors: scalar targets (22023), NULL path elements (22004),
    // non-integer array steps (22P02), two-dimensional paths (2202E),
    // argument types (42883 / 42804), the result past text_bytes (54000).
    try rejects("SELECT jsonb_set('1', '{a}', '2')", error.InvalidParameterValue);
    try rejects("SELECT jsonb_set('{\"a\":1}', ARRAY[NULL::text], '2')", error.NullValueNotAllowed);
    try rejects("SELECT jsonb_set('[1]', '{x}', '2')", error.InvalidTextRepresentation);
    try rejects("SELECT jsonb_set('[1]', '{1x}', '2')", error.InvalidTextRepresentation);
    try rejects("SELECT jsonb_set('{\"a\":1}', '{{a},{b}}', '2')", error.ArraySubscriptError);
    try rejects("SELECT jsonb_set('{}'::json, '{a}', '1')", error.UndefinedFunction);
    try rejects("SELECT jsonb_set('{}', '{a}')", error.UndefinedFunction);
    try rejects("SELECT to_json('a')", error.TypeMismatch);
    try rejects("SELECT jsonb_set('{}', '{a}', to_jsonb(repeat('x', 250)))", error.TextCapacity);
    try controlled("SELECT jsonb_set('{\"a\":1}'::jsonb,'{a}','2'::jsonb),'{\"a\":1}'::jsonb||'{\"b\":2}'::jsonb", "{\"a\": 2}|{\"a\": 1, \"b\": 2}");
    try controlled("SELECT jsonb_set('{\"a\":{\"b\":[1,2,3]}}', '{a,b,-1}', '\"x\"', true), jsonb_pretty('{\"a\":[1]}')", "{\"a\": {\"b\": [1, 2, \"x\"]}}|{\n    \"a\": [\n        1\n    ]\n}");
}

// ---- PG.JSON.PATH ---------------------------------------------------------------

fn jsonPath() !void {
    // oracle
    try expectTyped("SELECT jsonb_path_exists('{\"a\":1}'::jsonb,'$.a')", "jsonb_path_exists:16", "t");
    // The jsonpath type: canonical output (jsonpath_out).
    try expectTyped("SELECT '$.a'::jsonpath", "jsonpath:4072", "$.\"a\"");
    try expect("SELECT 'strict $.a[*] ? (@ > 1 && @ < 5).b'::jsonpath, '$.a + 1'::jsonpath, '-$.a'::jsonpath, '-1'::jsonpath", "strict $.\"a\"[*]?(@ > 1 && @ < 5).\"b\"|($.\"a\" + 1)|(-$.\"a\")|-1");
    try expect("SELECT '$[0 to 2, last]'::jsonpath, '$.**{1 to last}'::jsonpath, '$.**'::jsonpath, '$.**{2}'::jsonpath, 'lax $.size()'::jsonpath", "$[0 to 2,last]|$.**{1 to last}|$.**|$.**{2}|$.size()");
    try expect("SELECT 'exists($.a)'::jsonpath, '$ ? (@.a starts with \"x\")'::jsonpath, '$.a == 1'::jsonpath, '$.\"a b\"'::jsonpath, '$var.x'::jsonpath", "exists ($.\"a\")|$?(@.\"a\" starts with \"x\")|($.\"a\" == 1)|$.\"a b\"|$\"var\".\"x\"");
    try expect("SELECT '(1 + 2) * 3'::jsonpath, '1.50'::jsonpath, '$ ? (!(@ == 1))'::jsonpath, '$ ? ((@ == 1) is unknown)'::jsonpath, '$.a.type()'::jsonpath, '$.*[*]'::jsonpath", "((1 + 2) * 3)|1.50|$?(!(@ == 1))|$?((@ == 1) is unknown)|$.\"a\".type()|$.*[*]");
    try expect("SELECT '$ <> 1'::jsonpath, '$.decimal(4,2)'::jsonpath, '$ ? (@ like_regex \"^a\" flag \"i\")'::jsonpath, '0x1F'::jsonpath, '$.a ? (@ == \"\\\"\")'::jsonpath", "($ != 1)|$.decimal(4,2)|$?(@ like_regex \"^a\" flag \"i\")|31|$.\"a\"?(@ == \"\\\"\")");
    try rejects("SELECT '$.'::jsonpath", error.Syntax);
    try rejects("SELECT '@'::jsonpath", error.Syntax);
    try rejects("SELECT 'last'::jsonpath", error.Syntax);
    try rejects("SELECT '$ ? (@)'::jsonpath", error.Syntax);
    try rejects("SELECT '$.a.nosuch()'::jsonpath", error.Syntax);
    try rejects("SELECT '1a'::jsonpath", error.Syntax);
    try rejects("SELECT '$'::jsonpath = '$'::jsonpath", error.UndefinedFunction);
    try rejects("SELECT jsonb_path_exists('{}', 'x'::text)", error.UndefinedFunction);
    // Functions: query_array / query_first / match / exists and @? @@.
    try expectTyped("SELECT jsonb_path_query_array('{\"a\":[1,2,3,4,5]}', '$.a[*] ? (@ > 2)'), jsonb_path_query_first('{\"a\":[1,2]}', '$.a[*]'), jsonb_path_query_first('{}', '$.x'), jsonb_path_match('{\"a\":1}', '$.a == 1')", "jsonb_path_query_array:3802,jsonb_path_query_first:3802,jsonb_path_query_first:3802,jsonb_path_match:16", "[3, 4, 5]|1|NULL|t");
    try expectTyped("SELECT '{\"a\":1}'::jsonb @? '$.a', '{\"a\":1}'::jsonb @@ '$.a == 2', '{\"a\":1}'::jsonb @? 'strict $.b', '{\"a\":1}'::jsonb @@ '$.a'", "?column?:16,?column?:16,?column?:16,?column?:16", "t|f|NULL|NULL");
    try expect("SELECT jsonb_path_exists('{\"a\":1}', 'strict $.b', '{}', true), jsonb_path_match('{\"a\":1}', '$.a', '{}', true), jsonb_path_exists('{\"a\":1}', '$.b'), jsonb_path_match('{}', '$.x == 1')", "NULL|NULL|f|f");
    // Variables.
    try expect("SELECT jsonb_path_query_array('[1,2,3]', '$[*] ? (@ >= $min)', '{\"min\":2}'), jsonb_path_query_array('[1,2,3]', '$[*] ? (@ == $\"m n\")', '{\"m n\":3}')", "[2, 3]|[3]");
    try rejects("SELECT jsonb_path_exists('[1]', '$[*] ? (@ == $x)')", error.UndefinedObject);
    try rejects("SELECT jsonb_path_exists('[1]', '$', '[1]')", error.InvalidParameterValue);
    // Lax unwrapping / wrapping and strict errors.
    try expect("SELECT jsonb_path_query_array('{\"a\":[{\"b\":1},{\"b\":2},{\"c\":3}]}', '$.a.b'), jsonb_path_query_array('{\"a\":1}', '$.a[0]'), jsonb_path_query_array('{\"a\":1}', '$.a[*]'), jsonb_path_query_array('[1,[2]]', '$.*')", "[1, 2]|[1]|[1]|[]");
    try rejects("SELECT jsonb_path_query_array('{\"a\":[{\"b\":1}]}', 'strict $.a.b')", error.SqlJsonMemberNotFound);
    try rejects("SELECT jsonb_path_query_array('{\"a\":{}}', 'strict $.a.b')", error.SqlJsonMemberNotFound);
    try rejects("SELECT jsonb_path_query_array('{\"a\":1}', 'strict $.a[0]')", error.SqlJsonArrayNotFound);
    try rejects("SELECT jsonb_path_query_array('{\"a\":1}', 'strict $.a.*')", error.SqlJsonObjectNotFound);
    try rejects("SELECT jsonb_path_query_array('{\"a\":1}', 'strict $.a.size()')", error.SqlJsonArrayNotFound);
    try rejects("SELECT jsonb_path_query_array('[1]', 'strict $[3]')", error.InvalidSqlJsonSubscript);
    try rejects("SELECT jsonb_path_query_array('[1]', '$[\"x\"]')", error.InvalidSqlJsonSubscript);
    // Subscripts with ranges and last.
    try expect("SELECT jsonb_path_query_array('[0,1,2,3,4]', '$[1 to 2, last, last - 1]'), jsonb_path_query_array('[0,1]', '$[10]'), jsonb_path_query_array('[0,1,2]', '$[1.7]'), jsonb_path_query_array('[0,1,2]', '$[-5 to 1]')", "[1, 2, 4, 3]|[]|[1]|[0, 1]");
    // Arithmetic and unary operators (numeric).
    try expect("SELECT jsonb_path_query_first('{\"a\":2}', '$.a * 3 + 1'), jsonb_path_query_first('{\"a\":7}', '$.a / 2'), jsonb_path_query_first('{\"a\":7}', '$.a % 4'), jsonb_path_query_array('[1,-2]', '-$[*]')", "7|3.5000000000000000|3|[-1, 2]");
    try rejects("SELECT jsonb_path_query_first('{\"a\":2}', '$.a / 0')", error.DivisionByZero);
    try rejects("SELECT jsonb_path_query_first('{\"a\":2}', '$.x + 1')", error.SingletonSqlJsonItemRequired);
    try rejects("SELECT jsonb_path_query_first('{\"a\":\"s\"}', '-$.a')", error.SqlJsonNumberNotFound);
    try expect("SELECT jsonb_path_query_first('{\"a\":2}', '$.a / 0', '{}', true)", "NULL");
    // Item methods.
    try expect("SELECT jsonb_path_query_array('[1.5,-2.5]', '$[*].abs()'), jsonb_path_query_array('[1.5,-2.5]', '$[*].floor()'), jsonb_path_query_array('[1.5,-2.5]', '$[*].ceiling()'), jsonb_path_query_array('[1,\"a\",null,[],{}]', '$[*].type()')", "[1.5, 2.5]|[1, -3]|[2, -2]|[\"number\", \"string\", \"null\", \"array\", \"object\"]");
    try expect("SELECT jsonb_path_query_first('[1,2,3]', '$.size()'), jsonb_path_query_first('\"3.5\"', '$.double()'), jsonb_path_query_first('\"42\"', '$.integer()'), jsonb_path_query_first('2.5', '$.integer()'), jsonb_path_query_first('12', '$.string()'), jsonb_path_query_first('\"yes\"', '$.boolean()')", "3|3.5|42|3|\"12\"|true");
    try expect("SELECT jsonb_path_query_first('\"1.50\"', '$.number()'), jsonb_path_query_first('1.256', '$.decimal(4,2)'), jsonb_path_query_first('true', '$.string()'), jsonb_path_query_first('[\"9\"]', '$.bigint()')", "1.50|1.26|\"true\"|9");
    try rejects("SELECT jsonb_path_query_first('\"x\"', '$.abs()')", error.NonNumericSqlJsonItem);
    try rejects("SELECT jsonb_path_query_first('\"x\"', '$.double()')", error.NonNumericSqlJsonItem);
    try rejects("SELECT jsonb_path_query_first('\"NaN\"', '$.double()')", error.NonNumericSqlJsonItem);
    try rejects("SELECT jsonb_path_query_first('2.5', '$.boolean()')", error.NonNumericSqlJsonItem);
    try rejects("SELECT jsonb_path_query_first('{}', '$.keyvalue()')", error.UnsupportedStatement);
    try rejects("SELECT jsonb_path_query_first('\"2024-01-01\"', '$.datetime()')", error.UnsupportedStatement);
    // .** levels, filters, exists, starts with, comparison semantics.
    try expect("SELECT jsonb_path_query_array('{\"a\":{\"b\":{\"c\":1}}}', '$.**.c'), jsonb_path_query_array('{\"a\":{\"b\":{\"c\":1}}}', '$.**{2}'), jsonb_path_query_array('{\"a\":{\"b\":{\"c\":1}}}', '$.**{last}')", "[1]|[{\"c\": 1}]|[1]");
    try expect("SELECT jsonb_path_query_array('{\"a\":{\"b\":1}}', '$.**'), jsonb_path_query_array('{\"a\":[1,{\"b\":2}]}', '$.**{1 to 2}')", "[{\"a\": {\"b\": 1}}, {\"b\": 1}, 1]|[[1, {\"b\": 2}], 1, {\"b\": 2}]");
    try expect("SELECT jsonb_path_query_array('[{\"a\":1},{\"b\":2}]', '$[*] ? (exists(@.a))'), jsonb_path_query_array('[\"abc\",\"xbc\",1]', '$[*] ? (@ starts with \"ab\")'), jsonb_path_query_array('[1,\"a\",null]', '$[*] ? (@ != 1)'), jsonb_path_query_array('[\"a\",\"c\"]', '$[*] ? (@ < \"b\")')", "[{\"a\": 1}]|[\"abc\"]|[null]|[\"a\"]");
    try expect("SELECT jsonb_path_query_array('[1,2,3]', '$[*] ? (@ > 1 || @ == null)'), jsonb_path_query_array('[1,\"x\"]', '$[*] ? ((@ > 0) is unknown)'), jsonb_path_query_first('[1,2]', '$[*] > 1'), jsonb_path_query_first('[\"x\"]', 'strict $[*] > 1')", "[2, 3]|[\"x\"]|true|null");
    try expect("SELECT jsonb_path_match('[1,2]', 'exists($[*] ? (@ == 2))'), jsonb_path_match('{\"a\":[true]}', '$.a[0]'), jsonb_path_query_first('{\"a\":1}', '$.a == 1'), jsonb_path_query_first('{\"a\":\"1\"}', '$.a == 1')", "t|t|true|null");
    try rejects("SELECT jsonb_path_exists('\"abc\"', '$ ? (@ like_regex \"a\")')", error.UnsupportedStatement);
    try rejects("SELECT jsonb_path_match('[true,false]', '$[*]')", error.SingletonSqlJsonItemRequired);
    try expect("SELECT jsonb_path_match('[1,2]', '$[*] > 0'), jsonb_path_match('[]', '$[*] > 0')", "t|f");
    // Capacities: parsed nodes (54001) and held items (54000).
    try rejects("SELECT '$[" ++ "1," ** 70 ++ "1]'::jsonpath", error.StatementTooComplex);
    try rejects("SELECT jsonb_path_exists('[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]', 'strict $ ? (@[*] > 100)')", error.ProgramLimitExceeded);
    try controlled("SELECT jsonb_path_exists('{\"a\":1}'::jsonb,'$.a')", "t");
    try controlled("SELECT jsonb_path_query_array('{\"a\":[1,2,3,4,5],\"b\":{\"c\":[{\"d\":3}]}}', 'strict $.**{1 to last} ? (@.type() == \"number\" && @ > 2)'), '$.a[*]'::jsonpath", "[3, 4, 5, 3]|$.\"a\"[*]");
}

// ---- PG.JSON.TABLE ---------------------------------------------------------------

fn jsonTable() !void {
    // oracle
    try expectTyped("SELECT * FROM JSON_TABLE('[{\"a\":1}]','$[*]' COLUMNS(a INT PATH '$.a')) AS j", "a:23", "1");
    // FOR ORDINALITY, the default PATH $."name", JSON_VALUE columns
    // (strings through the type's input, JSON null as NULL, conversion
    // errors as NULL ON ERROR), JSON_QUERY columns (jsonb) and EXISTS.
    try expectTyped("SELECT * FROM JSON_TABLE('[{\"a\":1,\"b\":\"x\",\"c\":[1,2]},{\"a\":\"2\",\"d\":null},{\"a\":\"bad\"}]', '$[*]' COLUMNS (n FOR ORDINALITY, a INT, b TEXT PATH '$.b', c JSONB PATH '$.c', has_c BOOLEAN EXISTS PATH '$.c', d TEXT)) AS t", "n:23,a:23,b:25,c:3802,has_c:16,d:25", "1|1|x|[1, 2]|t|NULL;2|2|NULL|NULL|f|NULL;3|NULL|NULL|NULL|f|NULL");
    // ON EMPTY / ON ERROR behaviors, wrappers and FORMAT JSON.
    try expect("SELECT * FROM JSON_TABLE('{\"x\":[1,2]}', '$' COLUMNS (e INT PATH '$.missing' DEFAULT 7 ON EMPTY, f INT PATH '$.x[*]' DEFAULT -1 ON ERROR, g TEXT PATH '$.x' DEFAULT 'err' ON ERROR, h JSONB PATH '$.x[*]' WITH WRAPPER, i TEXT FORMAT JSON PATH '$.x', k JSONB PATH '$.missing' EMPTY ARRAY ON EMPTY, l JSON PATH '$.x' , m JSONB PATH '$.x[*]' EMPTY OBJECT ON ERROR)) AS t", "7|-1|err|[1, 2]|[1, 2]|[]|[1, 2]|{}");
    try expect("SELECT * FROM JSON_TABLE('{\"s\":\"abc\"}', '$' COLUMNS (q TEXT FORMAT JSON PATH '$.s', u TEXT FORMAT JSON PATH '$.s' OMIT QUOTES, v JSON PATH '$.s', w TEXT PATH '$.s', x TEXT PATH '$.s' KEEP QUOTES)) AS t", "\"abc\"|abc|\"abc\"|abc|\"abc\"");
    try expect("SELECT (SELECT a FROM JSON_TABLE('[1]', '$' COLUMNS (a JSONB PATH '$[*]' WITH CONDITIONAL WRAPPER)) t), (SELECT a FROM JSON_TABLE('[1,2]', '$' COLUMNS (a JSONB PATH '$[*]' WITH CONDITIONAL WRAPPER)) t), (SELECT a FROM JSON_TABLE('[1,2]', '$' COLUMNS (a JSONB PATH '$[*]' WITHOUT WRAPPER)) t)", "1|[1, 2]|NULL");
    try expectTyped("SELECT * FROM JSON_TABLE('[\"abc\",\"2024-01-02\",1.5]', '$' COLUMNS (s VARCHAR(2) PATH '$[0]', d DATE PATH '$[1]', n NUMERIC PATH '$[2]', f FLOAT8 PATH '$[2]', i INT PATH '$[2]', b BOOLEAN PATH '$[3]' DEFAULT true ON EMPTY)) AS t", "s:1043,d:1082,n:1700,f:701,i:23,b:16", "NULL|2024-01-02|1.5|1.5|NULL|t");
    // PASSING variables, column aliases and the default table name.
    try expect("SELECT * FROM JSON_TABLE('[1,2,3]', '$[*] ? (@ > $min && @ < $\"Max\")' PASSING 1 AS min, 5 AS \"Max\" COLUMNS (v INT PATH '$')) AS t", "2;3");
    try expectTyped("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT PATH '$')) AS t(x)", "x:23", "1");
    try expect("SELECT json_table.v FROM JSON_TABLE('[1]', '$[*]' AS p COLUMNS (v INT PATH '$'))", "1");
    try expect("SELECT t.v + 1 FROM JSON_TABLE('[1,2]'::json, 'lax $[*]' COLUMNS (v INT PATH '$')) t ORDER BY 1 DESC", "3;2");
    // Implicitly LATERAL over earlier FROM items; NULL context items give no rows.
    try run("CREATE TABLE jt_src(id INT PRIMARY KEY, doc JSONB)");
    try run("INSERT INTO jt_src VALUES (1, '[1,2]'), (2, '[]'), (3, NULL), (4, '{\"k\":[5]}')");
    try expect("SELECT j.id, t.v FROM jt_src j, JSON_TABLE(j.doc, '$[*]' COLUMNS (v INT PATH '$')) AS t ORDER BY 1, 2", "1|1;1|2;4|NULL");
    try expect("SELECT j.id, t.v FROM jt_src j LEFT JOIN LATERAL JSON_TABLE(j.doc, '$.k[*]' COLUMNS (v INT PATH '$')) AS t ON true ORDER BY 1", "1|NULL;2|NULL;3|NULL;4|5");
    try expect("SELECT COUNT(*) FROM jt_src j, JSON_TABLE(j.doc, 'strict $.k' COLUMNS (v JSONB PATH '$')) AS t", "1");
    // Row path errors: no rows (EMPTY ON ERROR) or the error (ERROR ON ERROR).
    try expect("SELECT COUNT(*) FROM JSON_TABLE('{\"a\":1}', 'strict $.b' COLUMNS (v INT PATH '$')) AS t", "0");
    try expect("SELECT COUNT(*) FROM JSON_TABLE('{\"a\":1}', 'strict $.b' COLUMNS (v INT PATH '$') EMPTY ARRAY ON ERROR) AS t", "0");
    try rejects("SELECT * FROM JSON_TABLE('{\"a\":1}', 'strict $.b' COLUMNS (v INT PATH '$') ERROR ON ERROR) AS t", error.SqlJsonMemberNotFound);
    // Column ERROR ON ERROR (also inherited from the table), ERROR ON
    // EMPTY (handled by ON ERROR unless that is ERROR), EXISTS ON ERROR.
    try rejects("SELECT * FROM JSON_TABLE('[{\"a\":\"x\"}]', '$[*]' COLUMNS (a INT PATH '$.a' ERROR ON ERROR)) AS t", error.InvalidTextRepresentation);
    try rejects("SELECT * FROM JSON_TABLE('[{\"a\":\"x\"}]', '$[*]' COLUMNS (a INT PATH '$.a') ERROR ON ERROR) AS t", error.InvalidTextRepresentation);
    try rejects("SELECT * FROM JSON_TABLE('[{\"a\":[1,2]}]', '$[*]' COLUMNS (a INT PATH '$.a[*]' ERROR ON ERROR)) AS t", error.MoreThanOneSqlJsonItem);
    try rejects("SELECT * FROM JSON_TABLE('[{\"a\":[1]}]', '$[*]' COLUMNS (a INT PATH '$.a' ERROR ON ERROR)) AS t", error.SqlJsonScalarRequired);
    try rejects("SELECT * FROM JSON_TABLE('[{}]', '$[*]' COLUMNS (a INT PATH '$.a' ERROR ON EMPTY ERROR ON ERROR)) AS t", error.NoSqlJsonItem);
    try expect("SELECT * FROM JSON_TABLE('[{}]', '$[*]' COLUMNS (a INT PATH '$.a' ERROR ON EMPTY, b INT PATH '$.b' ERROR ON EMPTY DEFAULT 3 ON ERROR)) AS t", "NULL|3");
    try expect("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (e1 BOOLEAN EXISTS PATH 'strict $.a', e2 BOOLEAN EXISTS PATH 'strict $.a' TRUE ON ERROR, e3 BOOLEAN EXISTS PATH 'strict $.a' UNKNOWN ON ERROR, e4 INT EXISTS PATH '$', e5 TEXT EXISTS PATH '$.a')) AS t", "f|t|NULL|1|false");
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (e BOOLEAN EXISTS PATH 'strict $.a' ERROR ON ERROR)) AS t", error.SqlJsonMemberNotFound);
    // Errors at parse and bind time.
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (NESTED PATH '$' COLUMNS (v INT))) AS t", error.UnsupportedStatement);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT, v TEXT)) AS t", error.DuplicateColumn);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT EMPTY ARRAY ON EMPTY)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT EXISTS NULL ON EMPTY)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT TRUE ON ERROR)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (v INT NULL ON ERROR NULL ON EMPTY)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE(1, '$' COLUMNS (a INT)) AS t", error.TypeMismatch);
    try rejects("SELECT * FROM JSON_TABLE('[]', '$' || '' COLUMNS (a INT)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[]', '$.' COLUMNS (a INT)) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[]', '$' COLUMNS (a INT PATH '@')) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('[]', '$' COLUMNS ()) AS t", error.Syntax);
    try rejects("SELECT * FROM JSON_TABLE('{bad', '$' COLUMNS (a INT)) AS t", error.InvalidTextRepresentation);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*] ? (@ > $x)' COLUMNS (a INT PATH '$')) AS t", error.UndefinedObject);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (a INT PATH '$' DEFAULT 'x' ON EMPTY)) AS t", error.InvalidTextRepresentation);
    try rejects("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (a INT PATH '$' DEFAULT count(*) ON EMPTY)) AS t", error.GroupingError);
    if (small.execute("SELECT * FROM JSON_TABLE('[1]', '$[*]' COLUMNS (a INT, b INT, c INT, d INT, e INT)) AS t", &small_result)) |_| {
        try check(false);
    } else |err| try check(err == error.ColumnCapacity);
    try controlled("SELECT * FROM JSON_TABLE('[{\"a\":1}]','$[*]' COLUMNS(a INT PATH '$.a')) AS j", "1");
    try controlled("SELECT * FROM JSON_TABLE('[{\"a\":1,\"b\":[1,2]},{\"a\":\"x\"}]', '$[*] ? (exists(@.a))' COLUMNS (n FOR ORDINALITY, a INT, b JSONB WITH WRAPPER, e BOOLEAN EXISTS PATH '$.b')) AS t", "1|1|[[1, 2]]|t;2|NULL|NULL|f");
}

// ---- replay ---------------------------------------------------------------------

var replay_scratch: DB.ReplayScratch = .{};

fn sameResult(a: *const DB.Result, b: *const DB.Result) !bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or a.column_typmods[column] != b.column_typmods[column] or
            !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |index| for (0..a.column_count) |column| {
        const x = &a.rows[index].cells[column];
        const y = &b.rows[index].cells[column];
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*) or DB.compareCells(x, y) != 0) return false;
        if (x.* == .null_value) continue;
        var p: [DB.Io.format_bytes]u8 = undefined;
        var q: [DB.Io.format_bytes]u8 = undefined;
        if (!std.mem.eql(u8, try DB.Io.format(x, false, DB.Result.default_session, &p), try DB.Io.format(y, false, DB.Result.default_session, &q))) return false;
    };
    return true;
}

fn sameQuery(a: *DB, b: *DB, source: []const u8) !bool {
    var x: DB.Result = .{};
    var y: DB.Result = .{};
    try a.execute(source, &x);
    try b.execute(source, &y);
    return sameResult(&x, &y);
}

var replay_primary: DB = .{};
var replay_replica: DB = .{};
var record: [8192]u8 = undefined;
var last_record: [8192]u8 = undefined;
var last_len: usize = 0;

/// Autocommit on the replay primary; its change record goes to the replica.
fn replicated(source: []const u8) !void {
    var used: usize = 0;
    replay_primary.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    @memcpy(last_record[0..used], record[0..used]);
    last_len = used;
    if (used != 0) try replay_replica.applyChangeRecord(record[0..used], &replay_scratch);
}

fn primaryOnly(source: []const u8) !usize {
    var used: usize = 0;
    try replay_primary.executeChanges(source, &result, &record, &used, null, null);
    return used;
}

fn replay() !void {
    try replicated("CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)");
    try replicated("INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)");
    // Values produced by this lane's aggregates and functions, stored in
    // jsonb, json, jsonpath (and jsonpath[]) columns, replay exactly.
    try replicated("CREATE TABLE r(id INT PRIMARY KEY, a INT[], s TEXT, j JSON, b JSONB, p JSONPATH, ps JSONPATH[], f FLOAT8)");
    try replicated("INSERT INTO r SELECT 1, (SELECT array_agg(v ORDER BY id) FROM tdd_a), (SELECT string_agg(id::text, ',') FROM tdd_a), (SELECT json_agg(id ORDER BY id) FROM tdd_a), (SELECT jsonb_object_agg(id, v) FROM tdd_a), 'strict $.a[*] ? (@ > 1)', ARRAY['$'::jsonpath, '$.b'], (SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY v) FROM tdd_a)");
    try replicated("INSERT INTO tdd_a VALUES (9, 9, 90)");
    try replicated("INSERT INTO r SELECT 2, NULL, NULL, NULL, jsonb_set(b, '{9}', '90'), p, NULL, NULL FROM r WHERE id = 1");
    try replicated("UPDATE r SET b = b - '1' #- '{2}', p = '$.size()' WHERE id = 2");
    try replicated("INSERT INTO r(id, s, b) SELECT 10 + n, b, c FROM JSON_TABLE('[{\"b\":\"x\",\"c\":{\"k\":1}},{\"b\":\"y\"}]', '$[*]' COLUMNS (n FOR ORDINALITY, b TEXT, c JSONB)) t");
    for ([_][]const u8{ "SELECT * FROM r ORDER BY id", "SELECT * FROM tdd_a ORDER BY id", "SELECT jsonb_path_query_array(b, '$.*'), b @? p FROM r ORDER BY id" }) |query|
        try check(try sameQuery(&replay_primary, &replay_replica, query));
    try check(replay_primary.tableCount() == replay_replica.tableCount() and replay_primary.oid_counter == replay_replica.oid_counter);
    try replay_replica.execute("SELECT a, s, j, b, p, ps, f FROM r WHERE id = 1", &result);
    try same(try render(&result), "{10,20,30,NULL}|1,2,3,4|[1, 2, 3, 4]|{\"1\": 10, \"2\": 20, \"3\": 30, \"4\": null}|strict $.\"a\"[*]?(@ > 1)|{$,\"$.\\\"b\\\"\"}|15");
    try replay_replica.execute("SELECT b, p FROM r WHERE id = 2", &result);
    try same(try render(&result), "{\"3\": 30, \"4\": null, \"9\": 90}|$.size()");
    // A stored jsonpath must be its own canonical text: corrupt or
    // non-canonical bytes in a record are InvalidChangeRecord (XX001) and
    // nothing of the record applies.
    const length = try primaryOnly("INSERT INTO r(id, p) VALUES (3, '$.\"a\"')");
    var corrupt: [8192]u8 = undefined;
    @memcpy(corrupt[0..length], record[0..length]);
    const at = std.mem.indexOf(u8, corrupt[0..length], "$.\"a\"") orelse return error.JsonAggContractFailed;
    corrupt[at] = '!';
    try check(replay_replica.applyChangeRecord(corrupt[0..length], &replay_scratch) == error.InvalidChangeRecord);
    @memcpy(corrupt[at..][0..5], "$.a  ");
    try check(replay_replica.applyChangeRecord(corrupt[0..length], &replay_scratch) == error.InvalidChangeRecord);
    try replay_replica.execute("SELECT COUNT(*) FROM r", &result);
    try same(try render(&result), "4");
    try replay_replica.execute("SELECT id, s, b FROM r WHERE id > 10 ORDER BY id", &result);
    try same(try render(&result), "11|x|{\"k\": 1};12|y|NULL");
    try replay_replica.applyChangeRecord(record[0..length], &replay_scratch);
    try check(try sameQuery(&replay_primary, &replay_replica, "SELECT * FROM r ORDER BY id"));
}

pub fn main(init: std.process.Init) !void {
    try baseFixture();
    try collectionAggregates();
    try jsonAggregates();
    try orderedSetAggregates();
    try jsonbModify();
    try jsonPath();
    try jsonTable();
    try replay();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-json-agg\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
