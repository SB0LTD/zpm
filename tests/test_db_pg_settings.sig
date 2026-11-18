const std = @import("std");
const sql = @import("sql");
const store_module = @import("db_store");

const Raw = sql.Database(.{ .tables = 2, .columns = 17, .rows_per_table = 8, .text_bytes = 128 });
const Store = store_module.Store(Raw);

fn wantText(result: *const Raw.Result, column: usize, expected: []const u8) !void {
    if (result.row_count != 1 or result.rows[0].cells[column] != .text) return error.MissingSettingsCell;
    if (!std.mem.eql(u8, result.rows[0].cells[column].text.slice(), expected)) return error.UnexpectedSetting;
}

fn state(session: *Store.Connection, result: *Raw.Result, current: []const u8, source: []const u8, reset: []const u8) !void {
    try session.execute("SELECT setting, source, reset_val FROM pg_catalog.pg_settings WHERE name = 'restrict_nonsystem_relation_kind'", result);
    try wantText(result, 0, current);
    try wantText(result, 1, source);
    try wantText(result, 2, reset);
}

pub fn main() !void {
    var store: Store = .{};
    var one: Store.Connection = .{ .store = &store, .id = 1 };
    var two: Store.Connection = .{ .store = &store, .id = 2 };
    var result: Raw.Result = .{};
    try one.startupParameter("restrict_nonsystem_relation_kind", "view");
    try state(&one, &result, "view", "client", "view");
    try state(&two, &result, "", "default", "");
    try one.execute("SELECT * FROM pg_settings WHERE name = 'restrict_nonsystem_relation_kind'", &result);
    if (result.column_count != 17 or sql.typeOid(result.column_types[11]) != 1009 or result.column_types[15] != .integer32 or result.column_types[16] != .boolean) return error.BadSettingsMetadata;
    try wantText(&result, 0, "restrict_nonsystem_relation_kind");
    try wantText(&result, 6, "user");
    try wantText(&result, 7, "string");
    try wantText(&result, 12, "");
    if (result.rows[0].cells[11] != .null_value or result.rows[0].cells[14] != .null_value or result.rows[0].cells[16].boolean) return error.BadSettingsMetadata;
    try one.execute("SELECT setting, vartype FROM pg_settings WHERE name = 'check_function_bodies'", &result);
    try wantText(&result, 0, "on");
    try wantText(&result, 1, "bool");
    try one.execute("SELECT enumvals FROM pg_settings WHERE name = 'default_transaction_isolation'", &result);
    if (result.row_count != 1 or result.rows[0].cells[0] != .array) return error.MissingIsolationEnum;
    try one.execute("SELECT pg_catalog.set_config(name, 'view, foreign-table', false) FROM pg_catalog.pg_settings WHERE name = 'restrict_nonsystem_relation_kind'", &result);
    try wantText(&result, 0, "view, foreign-table");
    try state(&one, &result, "view, foreign-table", "session", "view");
    try one.execute("BEGIN", &result);
    try one.execute("SAVEPOINT earlier", &result);
    try one.execute("SET LOCAL restrict_nonsystem_relation_kind = 'foreign-table'", &result);
    try state(&one, &result, "foreign-table", "session", "view");
    try state(&two, &result, "", "default", "");
    try one.execute("ROLLBACK TO earlier", &result);
    try state(&one, &result, "view, foreign-table", "session", "view");
    try one.execute("ROLLBACK", &result);
    try one.execute("RESET restrict_nonsystem_relation_kind", &result);
    try state(&one, &result, "view", "client", "view");
    try state(&two, &result, "", "default", "");
    try one.execute("SELECT name FROM pg_settings WHERE name = 'unsupported_setting'", &result);
    if (result.row_count != 0) return error.SyntheticSetting;
    std.debug.print("pg_settings: columns, sources, setter and session isolation passed\n", .{});
}
