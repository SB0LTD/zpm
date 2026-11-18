//! PostgreSQL relation identity visibility, including absent and hidden OIDs.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 8, .columns = 8, .work_rows = 128, .rows_per_table = 8, .text_bytes = 96, .integer_bits = 32 });
var db: DB = .{};
var result: DB.Result = .{};
var checks: usize = 0;

fn run(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("SQL {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn single(source: []const u8, value: ?bool) !void {
    try run(source);
    try std.testing.expectEqual(@as(usize, 1), result.row_count);
    try std.testing.expectEqual(@as(usize, 1), result.column_count);
    try std.testing.expect(result.column_types[0] == .boolean);
    const cell = result.rows[0].cells[0];
    if (value) |expected| {
        try std.testing.expect(cell == .boolean);
        try std.testing.expectEqual(expected, cell.boolean);
    } else try std.testing.expect(cell == .null_value);
    checks += 1;
}

const public_seen = "SELECT pg_table_is_visible(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='v_seen' AND n.nspname='public'";
const hidden_seen = "SELECT pg_table_is_visible(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='v_seen' AND n.nspname='v_hidden'";

pub fn main() !void {
    try single("SELECT pg_table_is_visible(NULL)", null);
    try single("SELECT pg_table_is_visible(0::oid)", null);
    try single("SELECT pg_table_is_visible(4294967295::oid)", null);
    try single("SELECT pg_table_is_visible(1259)", true);
    try run("SET search_path TO \"$user\", public");
    try run("CREATE SCHEMA v_hidden");
    try run("CREATE TABLE public.v_seen(id INT PRIMARY KEY, n INT)");
    try run("CREATE TABLE v_hidden.v_seen(id INT PRIMARY KEY, n INT)");
    try run("CREATE VIEW v_view AS SELECT id FROM v_seen");
    try run("CREATE SEQUENCE v_seq");
    try run("CREATE INDEX v_idx ON v_seen(n)");
    try run("CREATE TYPE v_composite AS (n INT)");
    try run("CREATE TABLE public.pg_class(id INT)");
    try single(public_seen, true);
    try single(hidden_seen, false);
    try single("SELECT pg_table_is_visible('v_seen'::regclass)", true);
    try single("SELECT pg_table_is_visible((SELECT oid FROM pg_class WHERE relname='v_view'))", true);
    try single("SELECT pg_table_is_visible((SELECT oid FROM pg_class WHERE relname='v_seq'))", true);
    try single("SELECT pg_table_is_visible((SELECT oid FROM pg_class WHERE relname='v_idx'))", true);
    try single("SELECT pg_table_is_visible((SELECT oid FROM pg_class WHERE relname='v_composite'))", true);
    try single("SELECT pg_table_is_visible(oid) FROM pg_class WHERE relname='pg_class' AND relnamespace=2200", false);
    try single("SELECT pg_table_is_visible(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='v_seen_pkey' AND n.nspname='public'", true);
    try single("SELECT pg_table_is_visible(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relname='v_seen_pkey' AND n.nspname='v_hidden'", false);

    try run("CREATE ROLE v_reader");
    try run("SET ROLE v_reader");
    try single(public_seen, true);
    try single(hidden_seen, false);
    try run("RESET ROLE");

    try run("SELECT oid FROM pg_class WHERE relname='v_seq'");
    const oid = result.rows[0].cells[0].integer;
    var source: [128]u8 = undefined;
    const lookup = try std.fmt.bufPrint(&source, "SELECT pg_table_is_visible({d}::oid)", .{oid});
    try run("DROP SEQUENCE v_seq");
    try single(lookup, null);
    std.debug.print("PASS PostgreSQL table visibility: {d} catalog checks\n", .{checks});
}
