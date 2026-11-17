//! Detached, typed PK plans share binder, MVCC and result rules with SQL PREPARE.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{
    .external_storage = true,
    .external_workspace = true,
    .external_results = true,
    .tables = 8,
    .columns = 6,
    .rows_per_table = 4,
    .work_rows = 64,
    .result_rows = 8,
    .integer_bits = 32,
    .text_bytes = 64,
});
const main_bytes = DB.backingBytes(32, 64, 4096) catch unreachable;
const read_bytes = DB.ReadContext.backingBytes(64) catch unreachable;
var backing: [main_bytes]u8 align(16) = undefined;
var workspace: [768]DB.Cell = undefined;
var context: DB.ReadContext = .{};
var scratch: [read_bytes]u8 align(16) = undefined;
var db: DB = .{};
var foreign: DB = .{};
var result: DB.Result = .{};
var expected: DB.Result = .{};
var result_bytes: [8 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var expected_bytes: [8 * @sizeOf(DB.Row)]u8 align(16) = undefined;
var assertions: usize = 0;
const lookup = "SELECT title AS caption,id,qty FROM points WHERE id=$1";
const minus_one: DB.Cell = .{ .integer = -1 };

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("parameterized lookup assertion {d}\n", .{assertions});
        return error.LookupContractFailed;
    }
}

fn rejected(comptime wanted: sql.Error, actual: anytype) !void {
    if (actual) |_| return error.ExpectedFailure else |err| {
        if (err != wanted) std.debug.print("expected {s}, got {s}\n", .{ @errorName(wanted), @errorName(err) });
        try check(err == wanted);
    }
}

fn run(source: []const u8) !void {
    db.execute(source, &expected) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn snap() DB.Snapshot {
    return .{ .csn = db.csn };
}

fn compare() !void {
    try check(result.command == expected.command and result.command == .select);
    try check(result.affected_rows == expected.affected_rows and result.affected_rows == 0);
    try check(result.column_count == expected.column_count and result.row_count == expected.row_count);
    for (0..result.column_count) |column| {
        try check(std.mem.eql(u8, result.column_names[column].slice(), expected.column_names[column].slice()));
        try check(result.column_types[column] == expected.column_types[column] and result.column_typmods[column] == expected.column_typmods[column]);
        for (0..result.row_count) |row| try check(std.meta.eql(result.rows[row].cells[column], expected.rows[row].cells[column]));
    }
}

fn canceled(_: ?*anyopaque) DB.SqlError!void {
    return error.QueryCanceled;
}

fn ordinary() !void {
    try run("CREATE TABLE points (id INT PRIMARY KEY, title VARCHAR(14), qty SMALLINT)");
    try run("INSERT INTO points VALUES (2,NULL,7),(-1,'older',NULL),(99,'third',3)");
    try run("PREPARE ordinary_lookup(INT) AS SELECT title AS caption,id,qty FROM points WHERE id=$1");
    try check(try context.preparePrimaryKey(&db, lookup, snap(), .integer32));
    try rejected(error.UndefinedParameter, context.run(&result));
    try context.describeResult(&result);
    try check(result.command == .select and result.row_count == 0 and result.column_count == 3 and result.column_typmods[0] == 18);
    const ast_nodes = context.workspace.nodes.len;
    for ([_]i64{ -1, 99, 999, 2, -1 }, [_][]const u8{
        "EXECUTE ordinary_lookup(-1)", "EXECUTE ordinary_lookup(99)", "EXECUTE ordinary_lookup(999)",
        "EXECUTE ordinary_lookup(2)", "EXECUTE ordinary_lookup(-1)",
    }) |number, invocation| {
        const key: DB.Cell = .{ .integer = number };
        try run(invocation);
        try check(try context.runPrimaryKey(&db, snap(), &key, &result));
        try compare();
        try check(context.workspace.nodes.len == ast_nodes);
    }
    try run("EXECUTE ordinary_lookup(NULL)");
    try check(try context.runPrimaryKey(&db, snap(), &.null_value, &result));
    try compare();
    try rejected(error.IntegerOverflow, context.runPrimaryKey(&db, snap(), &.{ .integer = 2147483648 }, &result));
    try rejected(error.TypeMismatch, context.runPrimaryKey(&db, snap(), &.{ .boolean = false }, &result));

    try check(try context.runPrimaryKey(&db, snap(), &minus_one, &result));
    var control: DB.ExecutionControl = .{ .poll = canceled };
    context.session.control = &control;
    try rejected(error.QueryCanceled, context.runPrimaryKey(&db, snap(), &minus_one, &result));
    context.session.control = null;
    try check(result.row_count == 1 and result.rows[0].cells[1].integer == -1);
    var overlap: DB.Result = .{};
    try overlap.bindMemory(scratch[0..@sizeOf(DB.Row)], 1);
    try rejected(error.InvalidParameterValue, context.runPrimaryKey(&db, snap(), &minus_one, &overlap));
    try check(overlap.row_count == 0 and overlap.command == .none);
    try check(!(try context.runPrimaryKey(&foreign, snap(), &minus_one, &result)));
    context.session.role = 12345;
    try check(!(try context.runPrimaryKey(&db, snap(), &minus_one, &result)));
    context.session.role = 10;
    context.dialect = .mysql;
    try check(!(try context.runPrimaryKey(&db, snap(), &minus_one, &result)));
    try check(!(try context.preparePrimaryKey(&db, lookup, snap(), .integer32)));
    context.dialect = .postgres;
}

fn snapshots() !void {
    const reader = try db.begin();
    try db.statement(reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &expected, .{});
    try db.statement(reader, "SELECT id FROM points WHERE id=-1", &expected, .{});
    const old = snap();
    try check(try context.preparePrimaryKey(&db, lookup, old, .integer32));
    try run("UPDATE points SET title='newer' WHERE id=-1");
    try check(!(try context.runPrimaryKey(&db, old, &minus_one, &result)));
    try check(result.row_count == 1 and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "older"));
    try check(try context.preparePrimaryKey(&db, lookup, old, .integer32));
    try check(try context.runPrimaryKey(&db, old, &minus_one, &result));
    try db.statement(reader, "SELECT title AS caption,id,qty FROM points WHERE id=-1", &expected, .{});
    try compare();
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "older"));
    db.abort(reader);
    try check(!(try context.runPrimaryKey(&db, snap(), &minus_one, &result)));
    try check(try context.preparePrimaryKey(&db, lookup, snap(), .integer32));
    try check(try context.runPrimaryKey(&db, snap(), &minus_one, &result));
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "newer"));

    const writer = try db.begin();
    try db.statement(writer, "UPDATE points SET title='mine' WHERE id=-1", &expected, .{});
    try check(try context.runPrimaryKey(&db, snap(), &minus_one, &result));
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "newer"));
    const own: DB.Snapshot = .{ .csn = db.csn, .slot = writer, .epoch = db.txs[writer].epoch, .cid = db.txs[writer].cid + 1 };
    try check(!(try context.runPrimaryKey(&db, own, &minus_one, &result)));
    try check(!(try context.preparePrimaryKey(&db, lookup, own, .integer32)));
    try db.statement(writer, "SELECT title FROM points WHERE id=-1", &expected, .{});
    try check(std.mem.eql(u8, expected.rows[0].cells[0].text.slice(), "mine"));
    db.abort(writer);

    try check(try context.preparePrimaryKey(&db, lookup, snap(), .integer32));
    try run("DROP TABLE points");
    try run("CREATE TABLE points (id INT PRIMARY KEY, qty SMALLINT, title VARCHAR(9))");
    try run("INSERT INTO points VALUES (-1,3,'replaced')");
    try check(!(try context.runPrimaryKey(&db, snap(), &minus_one, &result)));
    try check(try context.preparePrimaryKey(&db, lookup, snap(), .integer32));
    try check(try context.runPrimaryKey(&db, snap(), &minus_one, &result));
    try run("SELECT title AS caption,id,qty FROM points WHERE id=-1");
    try compare();
}

fn admission() !void {
    for ([_][]const u8{
        "SELECT qty+1 FROM points WHERE id=$1",
        "SELECT id FROM points WHERE id=$1 AND qty>0",
        "SELECT id FROM points WHERE id=$1 LIMIT 1",
        "SELECT id FROM points WHERE id=$1 FOR UPDATE",
        "SELECT id FROM points WHERE qty=$1",
    }) |source| try check(!(try context.preparePrimaryKey(&db, source, snap(), .integer32)));
    try check(!(try context.preparePrimaryKey(&db, lookup, snap(), .integer)));
    try check(try context.preparePrimaryKey(&db, "SELECT qty,id FROM points WHERE $1=id", snap(), .integer32));
    try check(try context.runPrimaryKey(&db, snap(), &minus_one, &result));
    try check(result.rows[0].cells[0].integer == 3 and result.rows[0].cells[1].integer == -1);
    try run("CREATE TABLE short_keys (id SMALLINT PRIMARY KEY)");
    try run("INSERT INTO short_keys VALUES (32767)");
    try check(try context.preparePrimaryKey(&db, "SELECT id FROM short_keys WHERE id=$1", snap(), .smallint));
    try check(try context.runPrimaryKey(&db, snap(), &.{ .integer = 32767 }, &result));
    try check(result.rows[0].cells[0].integer == 32767 and result.column_types[0] == .smallint);
    try rejected(error.NumericValueOutOfRange, context.runPrimaryKey(&db, snap(), &.{ .integer = 32768 }, &result));
    try run("CREATE TABLE wide_keys (id BIGINT PRIMARY KEY)");
    try run("INSERT INTO wide_keys VALUES (9223372036854775807)");
    try check(try context.preparePrimaryKey(&db, "SELECT id FROM wide_keys WHERE id=$1", snap(), .integer));
    try check(try context.runPrimaryKey(&db, snap(), &.{ .integer = 9223372036854775807 }, &result));
    try check(result.rows[0].cells[0].integer == 9223372036854775807 and result.column_types[0] == .integer);
    try run("CREATE TABLE composite (id INT, qty INT, PRIMARY KEY(id,qty))");
    try check(!(try context.preparePrimaryKey(&db, "SELECT id FROM composite WHERE id=$1", snap(), .integer32)));
    try run("CREATE VIEW projected AS SELECT id,title,qty FROM points");
    try check(!(try context.preparePrimaryKey(&db, "SELECT id FROM projected WHERE id=$1", snap(), .integer32)));
    try run("CREATE TABLE inherited (extra INT) INHERITS (points)");
    try check(!(try context.preparePrimaryKey(&db, lookup, snap(), .integer32)));
    try run("DROP TABLE inherited");
    try run("CREATE ROLE read_points");
    try run("GRANT SELECT ON points TO read_points");
    try run("ALTER TABLE points ENABLE ROW LEVEL SECURITY");
    try run("CREATE POLICY hide_negative ON points USING (id>0)");
    try run("SELECT oid FROM pg_roles WHERE rolname='read_points'");
    context.session.role = @intCast(expected.rows[0].cells[0].integer);
    try check(!(try context.preparePrimaryKey(&db, lookup, snap(), .integer32)));
    try context.execute(&db, "SELECT id FROM points WHERE id=-1", snap(), &result);
    try check(result.row_count == 0);
}

pub fn main() !void {
    try db.bindMemory(&backing, 32, 64, 4096);
    try db.bindWorkspace(&workspace);
    try context.bindMemory(&scratch, 64);
    try result.bindMemory(&result_bytes, 8);
    try expected.bindMemory(&expected_bytes, 8);
    ordinary() catch |err| {
        std.debug.print("ordinary lookup after {d} assertions: {s}\n", .{ assertions, @errorName(err) });
        return err;
    };
    snapshots() catch |err| {
        std.debug.print("snapshots after {d} assertions: {s}\n", .{ assertions, @errorName(err) });
        return err;
    };
    admission() catch |err| {
        std.debug.print("admission after {d} assertions: {s}\n", .{ assertions, @errorName(err) });
        return err;
    };
    std.debug.print("{{\"suite\":\"sql-parameterized-lookup\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
