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
    try one.startupParameter("options", "-c restrict_nonsystem_relation_kind=view");
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
    try one.execute("SELECT setting, vartype, source FROM pg_settings WHERE name = 'quote_all_identifiers'", &result);
    try wantText(&result, 0, "off");
    try wantText(&result, 1, "bool");
    try wantText(&result, 2, "default");
    try one.execute("CREATE TABLE archive_base(id \"pg_catalog\".\"int4\" PRIMARY KEY, label \"text\")", &result);
    try one.execute("CREATE INDEX label_idx ON archive_base USING \"btree\" (label)", &result);
    try one.execute("BEGIN", &result);
    try one.execute("SAVEPOINT unquoted", &result);
    try one.execute("SET LOCAL quote_all_identifiers = true", &result);
    try one.execute("SELECT quote_ident('plain'), quote_literal('plain')", &result);
    try wantText(&result, 0, "\"plain\"");
    try wantText(&result, 1, "'plain'");
    try one.execute("SELECT pg_get_indexdef('label_idx'::regclass, 1, true), 'public'::regnamespace::text, 'archive_base'::regclass::text", &result);
    try wantText(&result, 0, "\"label\"");
    try wantText(&result, 1, "\"public\"");
    try wantText(&result, 2, "\"archive_base\"");
    try one.execute("SELECT CAST('abcd' AS \"pg_catalog\".\"varchar\"(3))::\"text\"", &result);
    try wantText(&result, 0, "abc");
    try one.execute("SELECT format_type(25, -1), format_type(23, -1), format_type(1009, NULL)", &result);
    try wantText(&result, 0, "\"text\"");
    try wantText(&result, 1, "integer");
    try wantText(&result, 2, "\"text\"[]");
    try two.execute("SELECT quote_ident('plain')", &result);
    try wantText(&result, 0, "plain");
    try one.execute("ROLLBACK TO unquoted", &result);
    try one.execute("SELECT quote_ident('plain')", &result);
    try wantText(&result, 0, "plain");
    try one.execute("ROLLBACK", &result);
    try two.execute("SELECT set_config('quote_all_identifiers', 'on', false)", &result);
    try wantText(&result, 0, "on");
    try two.execute("SELECT quote_ident('plain')", &result);
    try wantText(&result, 0, "\"plain\"");
    try two.execute("RESET ALL", &result);
    try two.execute("SHOW quote_all_identifiers", &result);
    try wantText(&result, 0, "off");
    try one.execute("CREATE ROLE settings_login LOGIN", &result);
    try one.execute("ALTER ROLE settings_login SET quote_all_identifiers TO 'on'", &result);
    try one.execute("ALTER ROLE settings_login SET check_function_bodies = false", &result);
    try one.execute("SET row_security = off", &result);
    try one.execute("ALTER ROLE settings_login SET row_security FROM CURRENT", &result);
    try one.execute("BEGIN", &result);
    try one.execute("ALTER ROLE settings_login RESET ALL", &result);
    try one.execute("ROLLBACK", &result);

    var role_login: Store.Connection = .{ .store = &store, .id = 3 };
    try role_login.bindAuthenticatedRole("settings_login");
    role_login.finalizePostgresLogin();
    try role_login.execute("SELECT quote_ident('plain'), current_setting('row_security')", &result);
    try wantText(&result, 0, "\"plain\"");
    try wantText(&result, 1, "off");
    try role_login.execute("SELECT setting, source, reset_val FROM pg_settings WHERE name = 'quote_all_identifiers'", &result);
    try wantText(&result, 0, "on");
    try wantText(&result, 1, "user");
    try wantText(&result, 2, "on");
    try role_login.execute("SET quote_all_identifiers TO off", &result);
    try role_login.execute("RESET quote_all_identifiers", &result);
    try role_login.execute("SHOW quote_all_identifiers", &result);
    try wantText(&result, 0, "on");

    var overridden: Store.Connection = .{ .store = &store, .id = 4 };
    try overridden.startupParameter("options", "-c quote_all_identifiers=off -c row_security=on");
    try overridden.bindAuthenticatedRole("settings_login");
    overridden.finalizePostgresLogin();
    try overridden.execute("SELECT quote_ident('plain'), current_setting('row_security')", &result);
    try wantText(&result, 0, "plain");
    try wantText(&result, 1, "on");
    try overridden.execute("SHOW check_function_bodies", &result);
    try wantText(&result, 0, "off");

    try one.execute("BEGIN ISOLATION LEVEL REPEATABLE READ", &result);
    try one.execute("SELECT setrole FROM pg_db_role_setting", &result);
    try two.execute("ALTER ROLE settings_login SET row_security = on", &result);
    if (one.execute("ALTER ROLE settings_login RESET row_security", &result)) |_| {
        return error.LostRoleDefaultsUpdate;
    } else |err| {
        if (err != error.SerializationFailure) return err;
    }
    try one.execute("ROLLBACK", &result);

    try one.execute("DROP ROLE settings_login", &result);
    try one.execute("SELECT setrole FROM pg_db_role_setting", &result);
    if (result.row_count != 0) return error.OrphanRoleDefaults;
    try one.execute("SELECT name FROM pg_settings WHERE name = 'unsupported_setting'", &result);
    if (result.row_count != 0) return error.SyntheticSetting;
    std.debug.print("pg_settings: columns, sources, role defaults, startup precedence and session isolation passed\n", .{});
}
