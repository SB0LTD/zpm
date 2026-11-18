//! Raw PostgreSQL Query boundaries and pre-execution syntax checks.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 16, .result_rows = 16 });
var db: DB = .{};
var result: DB.Result = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("query boundary contract failed at assertion {d}\n", .{assertions});
        return error.QueryBoundaryContract;
    }
}

fn checkSpans(source: []const u8, expected: []const []const u8) !void {
    var scan: sql.PostgresStatements = .{ .source = source };
    for (expected) |word| {
        const start = scan.position;
        const span = (try scan.next()) orelse return error.StatementMissing;
        try check(span.start >= start and span.start < span.end and span.end <= scan.position);
        try check(std.mem.eql(u8, word, span.slice(source)));
        var resumed: sql.PostgresStatements = .{ .source = source, .position = start };
        const same = (try resumed.next()) orelse return error.StatementMissing;
        try check(same.start == span.start and same.end == span.end and resumed.position == scan.position);
    }
    try check(try scan.next() == null);
    try check(scan.position == source.len);
}

fn lexical() !void {
    try checkSpans(" -- first;\r\n; /* comment; /* nested; */ more; */ ; -- last;", &.{});
    try checkSpans(";; SELECT 1; -- interleaved;\r SELECT 2;;", &.{ "SELECT 1", "SELECT 2" });
    try checkSpans("SELECT ';''x', \"a;\"\"b\"; SELECT $$;--'\\$$; SELECT $q$inner; $Q$; $q$;", &.{
        "SELECT ';''x', \"a;\"\"b\"",
        "SELECT $$;--'\\$$",
        "SELECT $q$inner; $Q$; $q$",
    });
    try checkSpans("SELECT a$tail$, U&\"col;\\0062\", U&'a;!0062' UESCAPE '!'; SELECT 7;", &.{
        "SELECT a$tail$, U&\"col;\\0062\", U&'a;!0062' UESCAPE '!'",
        "SELECT 7",
    });
    const continued = "SELECT E'head;\\'' -- continuation;\r\n'escaped\\';second'";
    try checkSpans(continued ++ "; SELECT $tag$last;$tag$", &.{ continued, "SELECT $tag$last;$tag$" });
    try checkSpans("SELECT 'left\\'; SELECT 2", &.{ "SELECT 'left\\'", "SELECT 2" });
    var escaped: sql.PostgresStatements = .{ .source = "SELECT 'left\\';still'; SELECT 2", .standard_conforming_strings = false };
    const first = (try escaped.next()) orelse return error.StatementMissing;
    try check(std.mem.eql(u8, first.slice(escaped.source), "SELECT 'left\\';still'"));
    const second = (try escaped.next()) orelse return error.StatementMissing;
    try check(std.mem.eql(u8, second.slice(escaped.source), "SELECT 2"));
    try check(try escaped.next() == null);

    const dollar_routine = "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $do$ BEGIN RETURN 1; END $do$";
    const atomic_routine = "CREATE OR REPLACE FUNCTION g() RETURNS int LANGUAGE SQL BEGIN ATOMIC SELECT 1 AS end; SELECT CASE WHEN true THEN 2 END; END";
    const nested = "CREATE PROCEDURE p() LANGUAGE SQL BEGIN ATOMIC CREATE FUNCTION n() RETURNS int LANGUAGE SQL BEGIN ATOMIC SELECT 1; END; SELECT 2; END";
    try checkSpans(dollar_routine ++ "; " ++ atomic_routine ++ "; " ++ nested ++ "; SELECT 3;", &.{ dollar_routine, atomic_routine, nested, "SELECT 3" });
    const rule = "CREATE RULE r AS ON UPDATE TO t DO ALSO (SELECT 1; SELECT 2;)";
    try checkSpans(rule ++ "; SELECT ARRAY[1,2];", &.{ rule, "SELECT ARRAY[1,2]" });
    try checkSpans("SELECT 65536, $1; SELECT é$tag$, $é$tagged;$é$;", &.{ "SELECT 65536, $1", "SELECT é$tag$, $é$tagged;$é$" });
}

fn brokenLexical() !void {
    for ([_][]const u8{
        "SELECT 1; SELECT 'unclosed",
        "SELECT 1; SELECT \"unclosed",
        "SELECT 1; SELECT E'unclosed\\'",
        "SELECT 1; SELECT $q$unclosed;$Q$",
        "SELECT 1; /* open /* nested */",
        "SELECT 1; SELECT (2;",
        "SELECT 1; SELECT ARRAY[1;",
        "SELECT 1; SELECT 2)",
        "SELECT 1; CREATE PROCEDURE p() LANGUAGE SQL BEGIN ATOMIC SELECT 2;",
    }) |input| {
        var scan: sql.PostgresStatements = .{ .source = input };
        const first = (try scan.next()) orelse return error.StatementMissing;
        try check(std.mem.eql(u8, first.slice(input), "SELECT 1"));
        if (scan.next()) |_| return error.MalformedBatchAccepted else |err| try check(err == error.Syntax);
        if (db.preflightPostgresBatch(input)) |_| return error.MalformedBatchAccepted else |err| try check(err == error.Syntax);
    }
}

fn grammarWithoutEffects() !void {
    try db.execute("CREATE TABLE target (id INT)", &result);
    const before = db.csn;
    const valid = "INSERT INTO target VALUES (1); COMMIT; SELECT fn_not_yet_bound(2);";
    try check(try db.preflightPostgresBatch(valid) == 3);
    try check(try db.preflightPostgresBatch("/* comment; */ ; -- trailing;") == 0);
    try check(try db.preflightPostgresBatch("SET statement_timeout=0; SELECT 9") == 2);
    try check(try db.preflightPostgresBatch("COPY target (id) FROM STDIN; SELECT 9") == 2);
    const quoted_body = "CREATE FUNCTION deferred_body() RETURNS int LANGUAGE sql AS 'SELECT 1 +'; SELECT 1;";
    try check(try db.preflightPostgresBatch(quoted_body) == 2);
    if (db.preflightPostgresBatch("INSERT INTO target VALUES (1); COMMIT; VACUUM")) |_| {
        return error.UnsupportedBatchAccepted;
    } else |err| try check(err == error.UnsupportedStatement);
    for ([_][]const u8{
        "INSERT INTO target VALUES (1); COMMIT; SELECT 1 +;",
        "SET statement_timeout=0; SELECT 1 +;",
        "SELECT 1; SELECT '\x00'",
        "VACUUM; SELECT 1 +;",
    }) |input| {
        if (db.preflightPostgresBatch(input)) |_| return error.MalformedBatchAccepted else |err| try check(err == error.Syntax);
    }
    try check(db.csn == before);
    try db.execute("SELECT COUNT(*) FROM target", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 0);

    const simple = "SELECT 1;";
    var many: [600 * simple.len]u8 = undefined;
    for (0..600) |index| @memcpy(many[index * simple.len ..][0..simple.len], simple);
    try check(try db.preflightPostgresBatch(&many) == 600);
}

pub fn main(init: std.process.Init) !void {
    try lexical();
    try brokenLexical();
    try grammarWithoutEffects();
    var output: [128]u8 = undefined;
    const report = try std.fmt.bufPrint(&output, "{{\"suite\":\"pg-query-boundaries\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
