//! PG.PRED.DISTINCT: executable null-safe equality contract.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 128 });
var db: DB = .{};
var r: DB.Result = .{};
var checks: usize = 0;
fn check(ok: bool) !void { checks += 1; if (!ok) return error.DistinctContractFailed; }
fn truth(source: []const u8, expected: bool) !void {
    db.execute(source, &r) catch |err| { std.debug.print("{s}: {s}\n", .{source,@errorName(err)}); return err; };
    try check(r.row_count == 1 and r.column_count == 1);
    try check(r.column_types[0] == .boolean);
    try check(r.rows[0].cells[0] == .boolean and r.rows[0].cells[0].boolean == expected);
}
fn scalar(source: []const u8, expected: i64) !void {
    try db.execute(source, &r);
    try check(r.row_count == 1 and r.rows[0].cells[0] == .integer and r.rows[0].cells[0].integer == expected);
}
fn canceled(_: ?*anyopaque) sql.Error!void { return error.QueryCanceled; }
pub fn main(init: std.process.Init) !void {
    const words = [_][]const u8{"NULL","-1","1"};
    var query: [256]u8 = undefined;
    for (words,0..) |left,i| for (words,0..) |right,j| {
        try truth(try std.fmt.bufPrint(&query,"SELECT {s} IS DISTINCT FROM {s}",.{left,right}),i != j);
        try truth(try std.fmt.bufPrint(&query,"SELECT {s} IS NOT DISTINCT FROM {s}",.{left,right}),i == j);
    };
    // Every currently orderable scalar family, including typed NULLs.
    const samples = [_]struct { ty: []const u8, first: []const u8, second: []const u8 }{
        .{.ty="smallint",.first="1",.second="2"},
        .{.ty="integer",.first="1",.second="2"},
        .{.ty="bigint",.first="1",.second="2"},
        .{.ty="numeric",.first="1.01",.second="1.02"},
        .{.ty="real",.first="1",.second="2"},
        .{.ty="double precision",.first="1",.second="2"},
        .{.ty="boolean",.first="FALSE",.second="TRUE"},
        .{.ty="text",.first="'a'",.second="'b'"},
        .{.ty="name",.first="'a'",.second="'b'"},
        .{.ty="oid",.first="1",.second="2"},
        .{.ty="date",.first="'2025-01-01'",.second="'2025-01-02'"},
        .{.ty="timestamp",.first="'2025-01-01 12:00:00'",.second="'2025-01-02 12:00:00'"},
        .{.ty="timestamptz",.first="'2025-01-01 12:00:00+00'",.second="'2025-01-02 12:00:00+00'"},
        .{.ty="interval",.first="'1 day'",.second="'2 days'"},
        .{.ty="jsonb",.first="'{\"a\":1}'",.second="'{\"a\":2}'"},
    };
    for (samples) |sample| {
        const values = [_][]const u8{"NULL",sample.first,sample.second};
        for(values,0..) |left,i| for(values,0..) |right,j| {
            try truth(try std.fmt.bufPrint(&query,"SELECT ({s})::{s} IS DISTINCT FROM ({s})::{s}",.{left,sample.ty,right,sample.ty}),i!=j);
            try truth(try std.fmt.bufPrint(&query,"SELECT ({s})::{s} IS NOT DISTINCT FROM ({s})::{s}",.{left,sample.ty,right,sample.ty}),i==j);
        };
    }
    try truth("SELECT 1 IS NOT DISTINCT FROM 1.0",true);
    try truth("SELECT TRUE IS DISTINCT FROM FALSE",true);
    try truth("SELECT 'a'::text IS DISTINCT FROM 'b'::text",true);
    try truth("SELECT 'NaN'::double precision IS NOT DISTINCT FROM 'NaN'::double precision",true);
    try truth("SELECT '-0'::double precision IS NOT DISTINCT FROM '0'::double precision",true);
    try truth("SELECT '2026-01-01'::date IS DISTINCT FROM '2026-01-02'::date",true);
    try truth("SELECT '{\"a\":1,\"b\":2}'::jsonb IS NOT DISTINCT FROM '{\"b\":2,\"a\":1}'::jsonb",true);
    try truth("SELECT 1 IS DISTINCT FROM 2 IS TRUE",true);
    try truth("SELECT NOT 1 IS DISTINCT FROM 1",true);
    try db.execute("CREATE TABLE t(id INT PRIMARY KEY,v INT)",&r);
    try db.execute("INSERT INTO t VALUES(1,NULL),(2,2),(3,3)",&r);
    try scalar("SELECT COUNT(*) FROM t WHERE v IS DISTINCT FROM 2",2);
    try scalar("SELECT COUNT(*) FROM t WHERE v IS NOT DISTINCT FROM NULL",1);
    // Scalar subquery and aggregate walkers must visit the right operand.
    try truth("SELECT 5 IS NOT DISTINCT FROM (SELECT SUM(v) FROM t)",true);
    try scalar("SELECT COUNT(*) FROM t a JOIN t b ON a.v IS NOT DISTINCT FROM b.v",3);
    try truth("SELECT SUM(v) IS NOT DISTINCT FROM 5 FROM t HAVING SUM(v) IS DISTINCT FROM NULL",true);
    try db.execute("CREATE SEQUENCE s",&r);
    try truth("SELECT nextval('s') IS DISTINCT FROM nextval('s')",true);
    try scalar("SELECT currval('s')",2);
    try truth("SELECT NULL::bigint IS DISTINCT FROM nextval('s')",true);
    try scalar("SELECT currval('s')",3);
    const before = r;
    if (db.execute("SELECT NULL::integer IS DISTINCT FROM (1/0)",&r)) |_| return error.ErrorSuppressed else |err| try check(err == error.DivisionByZero);
    try check(r.row_count == before.row_count and r.rows[0].cells[0].integer == before.rows[0].cells[0].integer);
    if (db.execute("SELECT 1 IS DISTINCT FROM TRUE",&r)) |_| return error.InvalidTypesAccepted else |err| try check(err == error.UndefinedFunction);
    // Source-based schema persistence must retain both operands and the operator.
    var primary: DB = .{}; var replayed: DB = .{}; var scratch: DB.ReplayScratch = .{};
    var record: [16384]u8 = undefined; var used: usize = 0;
    try primary.executeChanges("CREATE TABLE d(id INT PRIMARY KEY,v BOOLEAN DEFAULT (NULL IS DISTINCT FROM 1))",&r,&record,&used,null,null);
    try replayed.applyChangeRecord(record[0..used],&scratch);
    try replayed.execute("INSERT INTO d(id) VALUES(1)",&r);
    try replayed.execute("SELECT v FROM d",&r);
    try check(r.rows[0].cells[0] == .boolean and r.rows[0].cells[0].boolean);
    used = 0;
    try primary.executeChanges("CREATE TABLE g(id INT PRIMARY KEY,v INT,changed BOOLEAN GENERATED ALWAYS AS(v IS DISTINCT FROM NULL) STORED)",&r,&record,&used,null,null);
    try replayed.applyChangeRecord(record[0..used],&scratch);
    try replayed.execute("INSERT INTO g(id,v) VALUES(1,NULL),(2,7)",&r);
    try replayed.execute("SELECT changed FROM g ORDER BY id",&r);
    try check(r.row_count == 2 and !r.rows[0].cells[0].boolean and r.rows[1].cells[0].boolean);
    // Failure never replaces the previous caller-owned result.
    r.row_count = 11;
    var control: sql.ExecutionControl = .{ .max_work = 1 };
    db.session.control = &control;
    if (db.execute("SELECT COUNT(*) FROM t WHERE v IS DISTINCT FROM 2",&r)) |_| return error.LimitIgnored else |err| try check(err == error.QueryWorkLimit);
    try check(r.row_count == 11);
    var interrupt: sql.ExecutionControl = .{ .poll = canceled, .poll_interval = 1 };
    db.session.control = &interrupt;
    if (db.execute("SELECT COUNT(*) FROM t WHERE v IS NOT DISTINCT FROM 2",&r)) |_| return error.CancelIgnored else |err| try check(err == error.QueryCanceled);
    try check(r.row_count == 11);
    db.session.control = null;
    var buffer: [128]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer,"{{\"suite\":\"sql-distinct\",\"pass\":true,\"assertions\":{d}}}\n",.{checks});
    try std.Io.File.stdout().writeStreamingAll(init.io,report);
}
