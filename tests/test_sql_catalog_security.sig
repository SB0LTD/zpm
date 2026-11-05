//! Catalog and security contracts (conformance lane B11, wave 3): roles,
//! role membership and table privileges, row-level security, object
//! comments, the namespace and extension catalogs, foreign-data wrappers and
//! servers, and publications (catalog_objects.sig). Each section checks
//! values and column metadata (PostgreSQL 18 text output), exact errors
//! (SQLSTATE through the error name), atomicity after a failure,
//! concurrency where a lock or an uncommitted object decides, and replay:
//! every committed record is applied to a replica that must answer every
//! probe exactly like the primary (committed state = replay(WAL)), and
//! crafted change records fail closed. Expectations outside the frozen
//! postgres18_oracle.json programs are pending native verification.
//! The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 16, .rows_per_table = 32, .result_rows = 128, .work_rows = 128, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 4, .expr_nodes = 1024 });
/// Four object versions, 16 text bytes, one role per policy.
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .catalog_objects = 4, .object_text_bytes = 16, .policy_roles = 1 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("catalog-security contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.CatalogSecurityContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn queryOn(target: anytype, source: []const u8) ![]const u8 {
    var result: @TypeOf(target.*).Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return renderResult(@TypeOf(target.*), &result);
}

fn renderResult(comptime T: type, result: *const T.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [T.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |row| {
        if (row != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &result.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try T.Io.format(cell, false, T.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn query(target: *DB, source: []const u8) ![]const u8 {
    return queryOn(target, source);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    var used: usize = 0;
    db.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) {
        replica.applyChangeRecord(record[0..used], &scratch) catch |err| {
            std.debug.print("replay of {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        records_applied += 1;
    }
    return result;
}

fn run(source: []const u8) !void {
    _ = try replicate(source);
}

/// The autocommit statement fails with `wanted`; the probe answers
/// `unchanged` afterwards (atomicity) on primary and replica.
fn rejects(source: []const u8, wanted: anyerror, probe: []const u8, unchanged: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    if (db.executeChanges(source, &result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(used == 0);
    const role = db.session.role;
    db.session.role = 10;
    defer db.session.role = role;
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0 and db.usage().table_locks == 0);
}

/// The statement fails with `wanted` (no state probe).
fn fails(source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    if (db.executeChanges(source, &result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(used == 0 and db.usage().transactions == 0 and db.usage().pending_versions == 0);
}

fn statement(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rows(slot: u16, source: []const u8) ![]const u8 {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return renderResult(DB, &result);
}

fn statementFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn parks(slot: u16, source: []const u8) !void {
    try statementFails(slot, source, error.WouldBlock);
    try check(db.parked(slot));
}

fn resumed(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
}

fn resumeFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{ .@"resume" = true })) |_| {
        std.debug.print("resumed: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

/// Encodes, replays and publishes a transaction (Store.commit order).
fn commit(slot: u16) !void {
    if (!db.readOnly(slot)) {
        const payload = db.prepareCommit(slot, &record) catch |err| {
            std.debug.print("commit of slot {d} after assertion {d}: {s}\n", .{ slot, assertions, @errorName(err) });
            return err;
        };
        try replica.applyChangeRecord(payload, &scratch);
        records_applied += 1;
    }
    db.publishCommit(slot);
}

const state_probes = [_][]const u8{
    "SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolconnlimit, rolbypassrls, oid FROM pg_roles ORDER BY oid",
    "SELECT oid, roleid, member, grantor, admin_option FROM pg_auth_members ORDER BY oid",
    "SELECT grantor, grantee, table_name, privilege_type, is_grantable FROM information_schema.table_privileges ORDER BY table_name, grantee, privilege_type",
    "SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check FROM pg_policies ORDER BY tablename, policyname",
    "SELECT oid, polname, polrelid, polcmd, polpermissive, polroles FROM pg_policy ORDER BY oid",
    "SELECT objoid, classoid, objsubid, description FROM pg_description ORDER BY objoid, objsubid",
    "SELECT objoid, classoid, description FROM pg_shdescription ORDER BY objoid",
    "SELECT oid, fdwname, fdwowner, fdwhandler, fdwvalidator FROM pg_foreign_data_wrapper ORDER BY oid",
    "SELECT oid, srvname, srvowner, srvfdw, srvtype, srvversion FROM pg_foreign_server ORDER BY oid",
    "SELECT oid, pubname, pubowner, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate, pubviaroot FROM pg_publication ORDER BY oid",
    "SELECT schemaname, tablename, tableowner, rowsecurity FROM pg_tables ORDER BY tablename",
};

/// Every probe answers identically on the primary and the replay.
fn sameState() !void {
    const role = db.session.role;
    db.session.role = 10;
    defer db.session.role = role;
    for (state_probes) |probe| {
        const left = try query(&db, probe);
        var copy: [16384]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy[0..left.len], right });
        try check(std.mem.eql(u8, copy[0..left.len], right));
    }
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

fn reset() !void {
    db = .{};
    replica = .{};
    try run("CREATE TABLE tdd_a(id INT PRIMARY KEY,g INT,v INT)");
    try run("INSERT INTO tdd_a VALUES(1,1,10),(2,1,20),(3,2,30),(4,2,NULL)");
    try run("CREATE TABLE tdd_b(id INT PRIMARY KEY,v INT)");
    try run("INSERT INTO tdd_b VALUES(1,11),(3,33),(5,55)");
}

fn roleOid(name: []const u8) !u32 {
    var source_buffer: [128]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "SELECT oid FROM pg_roles WHERE rolname = '{s}'", .{name});
    const role = db.session.role;
    db.session.role = 10;
    defer db.session.role = role;
    const text = try query(&db, source);
    return std.fmt.parseInt(u32, text, 10);
}

fn as(name: []const u8) !void {
    db.session.role = if (std.mem.eql(u8, name, "ramsql")) 10 else try roleOid(name);
}

/// Column names, type OIDs and typmods of a result.
fn metadata(source: []const u8, names: []const []const u8, oids: []const u32) !void {
    var result: DB.Result = .{};
    try db.execute(source, &result);
    try check(result.column_count == names.len);
    for (names, oids, 0..) |name, oid, index| {
        try same(result.column_names[index].slice(), name);
        try check(sql.typeOid(result.column_types[index]) == oid);
        try check(result.column_typmods[index] == -1);
    }
}

// ---- the oracle programs ------------------------------------------------------

/// The seven programs as the core driver runs them: one transaction over
/// the base fixture (PG.TYPE.ENUM_DOMAIN_COMPOSITE is not implemented).
fn oraclePrograms() !void {
    const programs = [_]struct { statements: []const []const u8, last: []const u8, name: []const u8, oid: u32 }{
        .{ .statements = &.{}, .last = "information_schema;pg_catalog;pg_toast;public", .name = "SELECT nspname FROM pg_namespace ORDER BY nspname", .oid = 19 },
        .{ .statements = &.{}, .last = "plpgsql", .name = "SELECT extname FROM pg_extension ORDER BY extname", .oid = 19 },
        .{ .statements = &.{}, .last = "", .name = "SELECT pubname FROM pg_publication ORDER BY pubname", .oid = 19 },
        .{ .statements = &.{"COMMENT ON TABLE tdd_a IS 'tdd'"}, .last = "tdd", .name = "SELECT obj_description('tdd_a'::regclass)", .oid = 25 },
        .{ .statements = &.{ "CREATE FOREIGN DATA WRAPPER tdd_fdw", "CREATE SERVER tdd_server FOREIGN DATA WRAPPER tdd_fdw" }, .last = "tdd_server", .name = "SELECT srvname FROM pg_foreign_server WHERE srvname='tdd_server'", .oid = 19 },
        .{ .statements = &.{ "ALTER TABLE tdd_a ENABLE ROW LEVEL SECURITY", "CREATE POLICY tdd_policy ON tdd_a USING(id>1)" }, .last = "tdd_policy", .name = "SELECT policyname FROM pg_policies WHERE policyname='tdd_policy'", .oid = 19 },
        .{ .statements = &.{ "CREATE ROLE ramsql_tdd_role", "GRANT SELECT ON tdd_a TO ramsql_tdd_role", "REVOKE SELECT ON tdd_a FROM ramsql_tdd_role", "DROP ROLE ramsql_tdd_role" }, .last = "", .name = "", .oid = 0 },
    };
    for (programs) |program| {
        try reset();
        const tx = try db.begin();
        for (program.statements) |source| try statement(tx, source);
        if (program.name.len != 0) {
            var result: DB.Result = .{};
            try db.statement(tx, program.name, &result, .{});
            try check(result.column_count == 1);
            try check(sql.typeOid(result.column_types[0]) == program.oid and result.column_typmods[0] == -1);
            try same(try renderResult(DB, &result), program.last);
        }
        db.abort(tx);
        try check(db.usage().pending_versions == 0);
    }
    // Column names and command tags of the programs.
    try reset();
    try metadata("SELECT obj_description('tdd_a'::regclass)", &.{"obj_description"}, &.{25});
    try metadata("SELECT nspname FROM pg_namespace", &.{"nspname"}, &.{19});
    try metadata("SELECT policyname FROM pg_policies", &.{"policyname"}, &.{19});
    const tags = [_]struct { source: []const u8, tag: sql.CommandTag }{
        .{ .source = "CREATE ROLE tag_role", .tag = .create_role },
        .{ .source = "GRANT SELECT ON tdd_a TO tag_role", .tag = .grant },
        .{ .source = "REVOKE SELECT ON tdd_a FROM tag_role", .tag = .revoke },
        .{ .source = "ALTER TABLE tdd_a ENABLE ROW LEVEL SECURITY", .tag = .alter_table },
        .{ .source = "CREATE POLICY tag_policy ON tdd_a USING (id > 1)", .tag = .create_policy },
        .{ .source = "COMMENT ON TABLE tdd_a IS 'tdd'", .tag = .comment },
        .{ .source = "CREATE FOREIGN DATA WRAPPER tag_fdw", .tag = .create_foreign_data_wrapper },
        .{ .source = "CREATE SERVER tag_server FOREIGN DATA WRAPPER tag_fdw", .tag = .create_server },
        .{ .source = "CREATE PUBLICATION tag_publication", .tag = .create_publication },
        .{ .source = "DROP POLICY tag_policy ON tdd_a", .tag = .drop_policy },
        .{ .source = "DROP ROLE tag_role", .tag = .drop_role },
    };
    for (tags) |entry| {
        const result = try replicate(entry.source);
        try check(result.command == entry.tag and result.column_count == 0 and result.affected_rows == 0);
    }
    try sameState();
}

// ---- namespaces and extensions --------------------------------------------------

fn namespacesAndExtensions() !void {
    try reset();
    try expect("SELECT oid, nspname FROM pg_namespace ORDER BY oid", "11|pg_catalog;99|pg_toast;2200|public;13000|information_schema");
    try expect("SELECT schema_name FROM information_schema.schemata ORDER BY schema_name", "information_schema;pg_catalog;pg_toast;public");
    // pg_toast is not writable and never dropped.
    try rejects("CREATE TABLE pg_toast.t (id INT)", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_class WHERE relnamespace = 99", "0");
    try rejects("DROP SCHEMA pg_toast", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_namespace", "4");
    try rejects("CREATE SCHEMA pg_toast", error.DuplicateSchema, "SELECT COUNT(*) FROM pg_namespace", "4");
    try fails("SELECT * FROM pg_toast.t", error.TableNotFound);
    // plpgsql: catalog-only (extension lifecycle is not provided).
    try expect("SELECT extname, extowner, extnamespace, extrelocatable, extversion, extconfig, extcondition FROM pg_extension", "plpgsql|10|11|f|1.0|NULL|NULL");
    try metadata("SELECT oid, extname, extconfig FROM pg_extension", &.{ "oid", "extname", "extconfig" }, &.{ 26, 19, 1028 });
    try rejects("CREATE EXTENSION plpgsql", error.DuplicateObject, "SELECT COUNT(*) FROM pg_extension", "1");
    const noop = try replicate("CREATE EXTENSION IF NOT EXISTS plpgsql");
    try check(noop.command == .create_extension);
    try rejects("CREATE EXTENSION pg_trgm", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_extension", "1");
    try rejects("DROP EXTENSION plpgsql", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_extension", "1");
    try rejects("COMMENT ON EXTENSION plpgsql IS 'x'", error.UnsupportedStatement, "SELECT COUNT(*) FROM pg_description", "0");
    try sameState();
}

// ---- comments -------------------------------------------------------------------

fn comments() !void {
    try reset();
    const probe = "SELECT objoid = 'tdd_a'::regclass, classoid, objsubid, description FROM pg_description ORDER BY objoid, objsubid";
    try run("COMMENT ON TABLE tdd_a IS 'tdd'");
    try expect("SELECT obj_description('tdd_a'::regclass)", "tdd");
    try expect("SELECT obj_description('tdd_a'::regclass, 'pg_class')", "tdd");
    try expect("SELECT obj_description('tdd_a'::regclass, 'pg_namespace')", "NULL");
    try expect("SELECT obj_description('tdd_b'::regclass)", "NULL");
    try expect("SELECT obj_description(NULL)", "NULL");
    try run("COMMENT ON COLUMN tdd_a.v IS 'value column'");
    try run("COMMENT ON COLUMN public.tdd_a.g IS 'group'");
    try expect("SELECT col_description('tdd_a'::regclass, 3), col_description('tdd_a'::regclass, 2), col_description('tdd_a'::regclass, 1)", "value column|group|NULL");
    try expect(probe, "t|1259|0|tdd;t|1259|2|group;t|1259|3|value column");
    // A new comment replaces the old; NULL and '' remove it.
    try run("COMMENT ON TABLE tdd_a IS 'it''s replaced'");
    try expect("SELECT obj_description('tdd_a'::regclass)", "it's replaced");
    try run("COMMENT ON COLUMN tdd_a.g IS ''");
    try run("COMMENT ON COLUMN tdd_a.g IS NULL");
    try expect("SELECT col_description('tdd_a'::regclass, 2)", "NULL");
    try sameState();
    // Sequences, views, schemas, roles (shared) and policies.
    try run("CREATE SEQUENCE tdd_seq");
    try run("COMMENT ON SEQUENCE tdd_seq IS 'counter'");
    try expect("SELECT obj_description('tdd_seq'::regclass, 'pg_class')", "counter");
    try run("CREATE VIEW tdd_view AS SELECT id FROM tdd_a");
    try run("COMMENT ON VIEW tdd_view IS 'a view'");
    try run("COMMENT ON COLUMN tdd_view.id IS 'view column'");
    try expect("SELECT obj_description('tdd_view'::regclass), col_description('tdd_view'::regclass, 1)", "a view|view column");
    try run("CREATE SCHEMA tdd_schema");
    try run("COMMENT ON SCHEMA tdd_schema IS 'schema'");
    try run("COMMENT ON SCHEMA public IS 'standard public schema'");
    try expect("SELECT description FROM pg_description WHERE classoid = 2615 ORDER BY objoid", "standard public schema;schema");
    try expect("SELECT obj_description(2200, 'pg_namespace')", "standard public schema");
    try run("CREATE ROLE tdd_commented");
    try run("COMMENT ON ROLE tdd_commented IS 'a role'");
    const role = try roleOid("tdd_commented");
    var source_buffer: [128]u8 = undefined;
    try expect(try std.fmt.bufPrint(&source_buffer, "SELECT shobj_description({d}, 'pg_authid')", .{role}), "a role");
    // Role comments are shared: obj_description does not see them.
    try expect(try std.fmt.bufPrint(&source_buffer, "SELECT obj_description({d}), obj_description({d}, 'pg_authid')", .{ role, role }), "NULL|a role");
    try expect("SELECT classoid, description FROM pg_shdescription", "1260|a role");
    try run("CREATE POLICY tdd_policy ON tdd_a USING (id > 1)");
    try run("COMMENT ON POLICY tdd_policy ON tdd_a IS 'a policy'");
    try expect("SELECT d.description FROM pg_description d JOIN pg_policy p ON p.oid = d.objoid WHERE d.classoid = 3256", "a policy");
    try sameState();
    // Errors: 42P01, 42703, 42809, 3F000, 42704, 0A000; nothing changes.
    const count = "SELECT COUNT(*) FROM pg_description";
    try rejects("COMMENT ON TABLE missing IS 'x'", error.TableNotFound, count, "8");
    try rejects("COMMENT ON TABLE nosuch.tdd_a IS 'x'", error.UndefinedSchema, count, "8");
    try rejects("COMMENT ON COLUMN tdd_a.missing IS 'x'", error.ColumnNotFound, count, "8");
    try rejects("COMMENT ON VIEW tdd_a IS 'x'", error.WrongObjectType, count, "8");
    try rejects("COMMENT ON TABLE tdd_view IS 'x'", error.WrongObjectType, count, "8");
    try rejects("COMMENT ON SEQUENCE tdd_a IS 'x'", error.WrongObjectType, count, "8");
    try rejects("COMMENT ON SCHEMA nosuch IS 'x'", error.UndefinedSchema, count, "8");
    try rejects("COMMENT ON ROLE nosuch IS 'x'", error.UndefinedObject, count, "8");
    try rejects("COMMENT ON POLICY nosuch ON tdd_a IS 'x'", error.UndefinedObject, count, "8");
    try rejects("COMMENT ON SERVER nosuch IS 'x'", error.UndefinedObject, count, "8");
    try rejects("COMMENT ON INDEX tdd_a_pkey IS 'x'", error.UnsupportedStatement, count, "8");
    try rejects("COMMENT ON FUNCTION f() IS 'x'", error.UnsupportedStatement, count, "8");
    try rejects("COMMENT ON TABLE tdd_a IS 42", error.Syntax, count, "8");
    // Transactional: an aborted COMMENT leaves the old one.
    const tx = try db.begin();
    try statement(tx, "COMMENT ON TABLE tdd_a IS 'uncommitted'");
    try same(try rows(tx, "SELECT obj_description('tdd_a'::regclass)"), "uncommitted");
    try expect("SELECT obj_description('tdd_a'::regclass)", "it's replaced");
    db.abort(tx);
    try expect("SELECT obj_description('tdd_a'::regclass)", "it's replaced");
    try check(db.usage().pending_versions == 0);
    // ALTER TABLE: column comments follow their column or go with it.
    try run("DROP VIEW tdd_view");
    try expect(count, "6");
    try run("ALTER TABLE tdd_a DROP COLUMN g");
    try expect("SELECT col_description('tdd_a'::regclass, 2), col_description('tdd_a'::regclass, 3)", "value column|NULL");
    try run("ALTER TABLE tdd_a ADD COLUMN w INT");
    try expect("SELECT col_description('tdd_a'::regclass, 2), col_description('tdd_a'::regclass, 3)", "value column|NULL");
    try sameState();
    // Dropping an object drops its comments (and a table's policies' comments).
    try run("DROP SEQUENCE tdd_seq");
    try run("DROP SCHEMA tdd_schema");
    try run("DROP ROLE tdd_commented");
    try expect("SELECT COUNT(*) FROM pg_shdescription", "0");
    try expect(count, "4");
    try run("DROP TABLE tdd_a");
    try expect("SELECT classoid, objsubid, description FROM pg_description ORDER BY description", "2615|0|standard public schema");
    try sameState();
}

// ---- roles and membership -------------------------------------------------------

fn roles() !void {
    try reset();
    const listing = "SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication, rolconnlimit, rolbypassrls FROM pg_roles ORDER BY oid";
    try expect(listing, "ramsql|t|t|t|t|t|t|-1|t");
    try expect("SELECT current_user, session_user, current_role, user", "ramsql|ramsql|ramsql|ramsql");
    try metadata("SELECT current_user", &.{"current_user"}, &.{19});
    try run("CREATE ROLE r_plain");
    try run("CREATE USER r_user WITH CREATEDB CONNECTION LIMIT 3");
    try run("CREATE ROLE r_admin WITH CREATEROLE NOINHERIT LOGIN BYPASSRLS");
    try expect(listing, "ramsql|t|t|t|t|t|t|-1|t;r_plain|f|t|f|f|f|f|-1|f;r_user|f|t|f|t|t|f|3|f;r_admin|f|f|t|f|t|f|-1|t");
    try expect("SELECT COUNT(*) FROM pg_authid WHERE rolname LIKE 'r\\_%'", "3");
    try metadata("SELECT rolname, rolconnlimit, oid FROM pg_roles", &.{ "rolname", "rolconnlimit", "oid" }, &.{ 19, 23, 26 });
    // OIDs come from the database counter (tables took 16384..16387).
    try check(try roleOid("r_plain") == 16388 and try roleOid("r_user") == 16389 and try roleOid("r_admin") == 16390);
    try sameState();
    // 42710, 42939, 42601 (conflicting options), 0A000 (passwords).
    const count = "SELECT COUNT(*) FROM pg_roles";
    try rejects("CREATE ROLE r_plain", error.DuplicateObject, count, "4");
    try rejects("CREATE ROLE ramsql", error.DuplicateObject, count, "4");
    try rejects("CREATE ROLE public", error.ReservedName, count, "4");
    try rejects("CREATE ROLE pg_reader", error.ReservedName, count, "4");
    try rejects("CREATE ROLE r_bad SUPERUSER NOSUPERUSER", error.Syntax, count, "4");
    try rejects("CREATE ROLE r_bad PASSWORD 'secret'", error.UnsupportedStatement, count, "4");
    try rejects("CREATE ROLE r_bad VALID UNTIL 'infinity'", error.UnsupportedStatement, count, "4");
    try rejects("CREATE ROLE r_bad IN ROLE nosuch", error.UndefinedObject, count, "4");
    try rejects("CREATE ROLE r_bad CONNECTION LIMIT -2", error.InvalidParameterValue, count, "4");
    // ALTER ROLE: attributes and rename.
    try run("ALTER ROLE r_plain WITH LOGIN CONNECTION LIMIT 5");
    try run("ALTER ROLE r_user RENAME TO r_renamed");
    try expect("SELECT rolname, rolcanlogin, rolconnlimit FROM pg_roles WHERE rolname IN ('r_plain', 'r_renamed') ORDER BY oid", "r_plain|t|5;r_renamed|t|3");
    try rejects("ALTER ROLE nosuch LOGIN", error.UndefinedObject, count, "4");
    try rejects("ALTER ROLE r_plain RENAME TO r_admin", error.DuplicateObject, count, "4");
    try rejects("ALTER ROLE r_plain RENAME TO pg_x", error.ReservedName, count, "4");
    try rejects("ALTER ROLE ramsql NOLOGIN", error.UnsupportedStatement, count, "4");
    try sameState();
    // Membership: GRANT role TO role, IN ROLE, ADMIN OPTION, cycles (0LP01).
    try run("CREATE ROLE r_group");
    try run("CREATE ROLE r_member IN ROLE r_group");
    const result = try replicate("GRANT r_group TO r_plain WITH ADMIN OPTION");
    try check(result.command == .grant_role);
    const members = "SELECT g.rolname, m.rolname, a.admin_option FROM pg_auth_members a JOIN pg_roles g ON g.oid = a.roleid JOIN pg_roles m ON m.oid = a.member ORDER BY a.oid";
    try expect(members, "r_group|r_member|f;r_group|r_plain|t");
    try expect("SELECT COUNT(*) FROM pg_auth_members WHERE grantor = 10", "2");
    try rejects("GRANT r_plain TO r_group", error.InvalidGrantOperation, members, "r_group|r_member|f;r_group|r_plain|t");
    try rejects("GRANT r_group TO r_group", error.InvalidGrantOperation, members, "r_group|r_member|f;r_group|r_plain|t");
    try rejects("GRANT nosuch TO r_plain", error.UndefinedObject, members, "r_group|r_member|f;r_group|r_plain|t");
    try rejects("GRANT r_group TO nosuch", error.UndefinedObject, members, "r_group|r_member|f;r_group|r_plain|t");
    try run("REVOKE ADMIN OPTION FOR r_group FROM r_plain");
    try expect(members, "r_group|r_member|f;r_group|r_plain|f");
    const revoked = try replicate("REVOKE r_group FROM r_member");
    try check(revoked.command == .revoke_role);
    try expect(members, "r_group|r_plain|f");
    try sameState();
    // current_user follows the session role (session_user stays).
    try as("r_plain");
    try expect("SELECT current_user, session_user", "r_plain|ramsql");
    // Non-superusers: CREATE ROLE needs CREATEROLE (42501).
    try rejects("CREATE ROLE r_denied", error.InsufficientPrivilege, count, "6");
    try as("r_admin");
    try rejects("CREATE ROLE r_denied SUPERUSER", error.InsufficientPrivilege, count, "6");
    try rejects("CREATE ROLE r_denied REPLICATION", error.InsufficientPrivilege, count, "6");
    try run("CREATE ROLE r_created BYPASSRLS");
    try rejects("DROP ROLE r_plain", error.InsufficientPrivilege, count, "7");
    try as("ramsql");
    // DROP ROLE: 42704, IF EXISTS, 55006 for the current user, 2BP01 for
    // the bootstrap superuser and for a role with grants.
    try rejects("DROP ROLE nosuch", error.UndefinedObject, count, "7");
    try run("DROP ROLE IF EXISTS nosuch, r_created");
    try rejects("DROP ROLE ramsql", error.ObjectInUse, count, "6");
    try run("GRANT SELECT ON tdd_a TO r_renamed");
    try rejects("DROP ROLE r_renamed", error.DependentObjects, count, "6");
    try run("REVOKE SELECT ON tdd_a FROM r_renamed");
    db.session.role = try roleOid("r_admin");
    db.session.session_role = db.session.role;
    try rejects("DROP ROLE r_admin", error.ObjectInUse, count, "6");
    db.session.role = 10;
    db.session.session_role = 10;
    // Dropping a role drops its memberships.
    try run("DROP ROLE r_group, r_renamed");
    try expect(members, "");
    try expect(listing, "ramsql|t|t|t|t|t|t|-1|t;r_plain|f|t|f|f|t|f|5|f;r_admin|f|f|t|f|t|f|-1|t;r_member|f|t|f|f|f|f|-1|f");
    try sameState();
    // Abort returns the role and its OID.
    const counter = db.oid_counter;
    const tx = try db.begin();
    try statement(tx, "CREATE ROLE r_aborted");
    try same(try rows(tx, "SELECT COUNT(*) FROM pg_roles WHERE rolname = 'r_aborted'"), "1");
    db.abort(tx);
    try check(db.oid_counter == counter);
    try expect("SELECT COUNT(*) FROM pg_roles WHERE rolname = 'r_aborted'", "0");
    // A concurrent creator of the same name is waited for: 42710 after its
    // commit, success after its abort.
    const first = try db.begin();
    const second = try db.begin();
    try statement(first, "CREATE ROLE r_race");
    try parks(second, "CREATE ROLE r_race");
    try commit(first);
    try resumeFails(second, "CREATE ROLE r_race", error.DuplicateObject);
    db.abort(second);
    const third = try db.begin();
    const fourth = try db.begin();
    try statement(third, "DROP ROLE r_race");
    try parks(fourth, "ALTER ROLE r_race LOGIN");
    db.abort(third);
    try resumed(fourth, "ALTER ROLE r_race LOGIN");
    try commit(fourth);
    try expect("SELECT rolcanlogin FROM pg_roles WHERE rolname = 'r_race'", "t");
    try sameState();
}

// ---- table privileges -------------------------------------------------------------

fn privileges() !void {
    try reset();
    try run("CREATE ROLE reader");
    try run("CREATE ROLE writer");
    try run("CREATE ROLE grp");
    try run("CREATE ROLE grp_member IN ROLE grp");
    try run("CREATE ROLE no_inherit NOINHERIT IN ROLE grp");
    const grants = "SELECT grantor, grantee, table_name, privilege_type, is_grantable FROM information_schema.table_privileges WHERE grantee <> 'ramsql' ORDER BY table_name, grantee, privilege_type";
    // The owner holds every privilege with grant option (acldefault).
    try expect("SELECT privilege_type, is_grantable, with_hierarchy FROM information_schema.table_privileges WHERE table_name = 'tdd_b' AND grantee = 'ramsql' ORDER BY privilege_type", "DELETE|YES|NO;INSERT|YES|NO;MAINTAIN|YES|NO;REFERENCES|YES|NO;SELECT|YES|YES;TRIGGER|YES|NO;TRUNCATE|YES|NO;UPDATE|YES|NO");
    try metadata("SELECT grantor, privilege_type FROM information_schema.table_privileges", &.{ "grantor", "privilege_type" }, &.{ 19, 25 });
    // Without a grant every read and write is 42501 (also through a view).
    try as("reader");
    try fails("SELECT * FROM tdd_a", error.InsufficientPrivilege);
    try fails("SELECT id FROM tdd_b WHERE id IN (SELECT id FROM tdd_a)", error.InsufficientPrivilege);
    try fails("INSERT INTO tdd_a VALUES (9, 9, 9)", error.InsufficientPrivilege);
    try fails("TRUNCATE tdd_a", error.InsufficientPrivilege);
    try fails("SELECT * FROM pg_authid", error.InsufficientPrivilege);
    try expect("SELECT COUNT(*) FROM pg_roles", "6");
    try as("ramsql");
    try run("GRANT SELECT ON tdd_a TO reader");
    try run("GRANT INSERT, UPDATE ON TABLE tdd_a, tdd_b TO writer WITH GRANT OPTION");
    try run("GRANT ALL PRIVILEGES ON tdd_b TO grp");
    try expect(grants, "ramsql|reader|tdd_a|SELECT|NO;ramsql|writer|tdd_a|INSERT|YES;ramsql|writer|tdd_a|UPDATE|YES;ramsql|grp|tdd_b|DELETE|NO;ramsql|grp|tdd_b|INSERT|NO;ramsql|grp|tdd_b|MAINTAIN|NO;ramsql|grp|tdd_b|REFERENCES|NO;ramsql|grp|tdd_b|SELECT|NO;ramsql|grp|tdd_b|TRIGGER|NO;ramsql|grp|tdd_b|TRUNCATE|NO;ramsql|grp|tdd_b|UPDATE|NO;ramsql|writer|tdd_b|INSERT|YES;ramsql|writer|tdd_b|UPDATE|YES");
    try sameState();
    try as("reader");
    try expect("SELECT id FROM tdd_a ORDER BY id", "1;2;3;4");
    try fails("SELECT * FROM tdd_b", error.InsufficientPrivilege);
    try fails("UPDATE tdd_a SET v = 0", error.InsufficientPrivilege);
    try fails("CREATE TABLE mine (id INT)", error.InsufficientPrivilege);
    try fails("DROP TABLE tdd_a", error.InsufficientPrivilege);
    try fails("ALTER TABLE tdd_a ADD COLUMN x INT", error.InsufficientPrivilege);
    try fails("GRANT SELECT ON tdd_a TO writer", error.InsufficientPrivilege);
    // INSERT and UPDATE without WHERE need no SELECT; filtering needs it.
    try as("writer");
    try run("INSERT INTO tdd_a VALUES (5, 3, 50)");
    try run("UPDATE tdd_b SET v = 0");
    try fails("UPDATE tdd_a SET v = 1 WHERE id = 1", error.InsufficientPrivilege);
    try fails("INSERT INTO tdd_a VALUES (6, 3, 60) RETURNING id", error.InsufficientPrivilege);
    try fails("DELETE FROM tdd_a", error.InsufficientPrivilege);
    // WITH GRANT OPTION lets the grantee grant; the grant is recorded by the owner.
    try run("GRANT INSERT ON tdd_a TO reader");
    try fails("GRANT DELETE ON tdd_a TO reader", error.InsufficientPrivilege);
    // Roles inherit their groups' privileges unless NOINHERIT.
    try as("grp_member");
    try expect("SELECT id, v FROM tdd_b ORDER BY id", "1|0;3|0;5|0");
    try run("DELETE FROM tdd_b WHERE id = 5");
    try as("no_inherit");
    try fails("SELECT * FROM tdd_b", error.InsufficientPrivilege);
    try as("ramsql");
    try expect("SELECT * FROM tdd_a WHERE id = 5", "5|3|50");
    try expect("SELECT * FROM tdd_b ORDER BY id", "1|0;3|0");
    try sameState();
    // PUBLIC grants reach every role; REVOKE removes privileges again.
    try run("GRANT SELECT ON tdd_b TO PUBLIC");
    try as("no_inherit");
    try expect("SELECT COUNT(*) FROM tdd_b", "2");
    try as("ramsql");
    try run("REVOKE SELECT ON tdd_b FROM PUBLIC");
    try run("REVOKE GRANT OPTION FOR INSERT ON tdd_a FROM writer");
    try run("REVOKE ALL ON tdd_b FROM grp, writer");
    try run("REVOKE SELECT ON tdd_a FROM reader");
    try expect(grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    try as("reader");
    try fails("SELECT * FROM tdd_a", error.InsufficientPrivilege);
    try as("ramsql");
    try rejects("GRANT SELECT ON missing TO reader", error.TableNotFound, grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    try rejects("GRANT SELECT ON tdd_a TO nosuch", error.UndefinedObject, grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    try rejects("GRANT SELECT (id) ON tdd_a TO reader", error.UnsupportedStatement, grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    try rejects("GRANT USAGE ON SCHEMA public TO reader", error.UnsupportedStatement, grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    try rejects("GRANT SELECT ON tdd_a TO reader GRANTED BY ramsql", error.UnsupportedStatement, grants, "ramsql|reader|tdd_a|INSERT|NO;ramsql|writer|tdd_a|INSERT|NO;ramsql|writer|tdd_a|UPDATE|YES");
    // OWNER TO: the new owner holds every privilege and may grant.
    try run("ALTER TABLE tdd_b OWNER TO reader");
    try expect("SELECT tablename, tableowner FROM pg_tables ORDER BY tablename", "tdd_a|ramsql;tdd_b|reader");
    try as("reader");
    try expect("SELECT COUNT(*) FROM tdd_b", "2");
    try run("GRANT SELECT ON tdd_b TO writer");
    try run("COMMENT ON TABLE tdd_b IS 'reader''s'");
    try fails("ALTER TABLE tdd_b OWNER TO writer", error.InsufficientPrivilege);
    try as("ramsql");
    try expect("SELECT grantor, grantee, privilege_type FROM information_schema.table_privileges WHERE table_name = 'tdd_b' AND grantee = 'writer'", "reader|writer|SELECT");
    try rejects("DROP ROLE reader", error.DependentObjects, "SELECT COUNT(*) FROM pg_roles", "6");
    try sameState();
    // DROP TABLE drops its grants, owner entry and comment.
    try run("DROP TABLE tdd_b");
    try expect("SELECT COUNT(*) FROM information_schema.table_privileges WHERE table_name = 'tdd_b'", "0");
    try run("REVOKE ALL ON tdd_a FROM reader, writer");
    try run("DROP ROLE reader, writer");
    try sameState();
    // GRANT holds AccessShare: DROP TABLE waits for the granting transaction.
    try run("CREATE ROLE late");
    const granting = try db.begin();
    try statement(granting, "GRANT SELECT ON tdd_a TO late");
    const dropping = try db.begin();
    try parks(dropping, "DROP TABLE tdd_a");
    try commit(granting);
    try resumed(dropping, "DROP TABLE tdd_a");
    try commit(dropping);
    try expect("SELECT COUNT(*) FROM information_schema.table_privileges", "0");
    try run("DROP ROLE late");
    try sameState();
}

// ---- row-level security --------------------------------------------------------

fn rowSecurity() !void {
    try reset();
    try run("CREATE ROLE alice");
    try run("CREATE ROLE bob");
    try run("CREATE ROLE boss BYPASSRLS");
    try run("GRANT SELECT, INSERT, UPDATE, DELETE ON tdd_a TO alice, bob, boss");
    const enabled = try replicate("ALTER TABLE tdd_a ENABLE ROW LEVEL SECURITY");
    try check(enabled.command == .alter_table);
    try expect("SELECT tablename, rowsecurity FROM pg_tables ORDER BY tablename", "tdd_a|t;tdd_b|f");
    // Enabled without policies: default deny for everyone but the owner.
    try as("alice");
    try expect("SELECT COUNT(*) FROM tdd_a", "0");
    try fails("INSERT INTO tdd_a VALUES (8, 8, 8)", error.InsufficientPrivilege);
    try fails("SELECT COUNT(*) FROM tdd_b", error.InsufficientPrivilege);
    try as("ramsql");
    try expect("SELECT COUNT(*) FROM tdd_a", "4");
    // The oracle program's policy, then per-role and per-command ones.
    try run("CREATE POLICY tdd_policy ON tdd_a USING(id>1)");
    try run("CREATE POLICY bob_reads ON tdd_a AS PERMISSIVE FOR SELECT TO bob USING (g = 1)");
    try run("CREATE POLICY no_nulls ON tdd_a AS RESTRICTIVE FOR ALL TO alice USING (v IS NOT NULL)");
    try run("CREATE POLICY alice_inserts ON tdd_a FOR INSERT TO alice WITH CHECK (v < 100)");
    const policies = "SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check FROM pg_policies ORDER BY policyname";
    try expect(policies, "public|tdd_a|alice_inserts|PERMISSIVE|{alice}|INSERT|NULL|(v < 100);public|tdd_a|bob_reads|PERMISSIVE|{bob}|SELECT|(g = 1)|NULL;public|tdd_a|no_nulls|RESTRICTIVE|{alice}|ALL|(v IS NOT NULL)|NULL;public|tdd_a|tdd_policy|PERMISSIVE|{public}|ALL|(id > 1)|NULL");
    try expect("SELECT polname, polcmd, polpermissive, polroles FROM pg_policy WHERE polname IN ('tdd_policy', 'bob_reads') ORDER BY polname", "bob_reads|r|t|{16389};tdd_policy|*|t|{0}");
    try metadata("SELECT policyname, roles, qual FROM pg_policies", &.{ "policyname", "roles", "qual" }, &.{ 19, 1003, 25 });
    try sameState();
    // SELECT: permissive OR-ed, restrictive AND-ed.
    try as("alice");
    try expect("SELECT id FROM tdd_a ORDER BY id", "2;3");
    try expect("SELECT a.id, b.id FROM tdd_a a JOIN tdd_a b ON a.id = b.id ORDER BY a.id", "2|2;3|3");
    try as("bob");
    try expect("SELECT id FROM tdd_a ORDER BY id", "1;2;3;4");
    try as("boss");
    try expect("SELECT COUNT(*) FROM tdd_a", "4");
    // INSERT WITH CHECK: alice's insert policy (and USING of ALL policies).
    try as("alice");
    try run("INSERT INTO tdd_a VALUES (6, 6, 60)");
    // Permissive checks are OR-ed: tdd_policy's USING (id > 1) admits v = 700.
    try run("INSERT INTO tdd_a VALUES (7, 7, 700)");
    try fails("INSERT INTO tdd_a VALUES (0, 7, 700)", error.InsufficientPrivilege);
    try fails("INSERT INTO tdd_a VALUES (8, 7, NULL)", error.InsufficientPrivilege);
    // A passing row still meets the (hidden) key: 23505.
    try fails("INSERT INTO tdd_a VALUES (1, 7, 70)", error.PrimaryKeyViolation);
    // UPDATE / DELETE see only visible rows; new rows are checked too.
    const updated = try replicate("UPDATE tdd_a SET v = v + 1");
    try check(updated.affected_rows == 4);
    try fails("UPDATE tdd_a SET id = 0 WHERE id = 2", error.InsufficientPrivilege);
    try fails("UPDATE tdd_a SET v = NULL WHERE id = 2", error.InsufficientPrivilege);
    const deleted = try replicate("DELETE FROM tdd_a WHERE g = 2");
    try check(deleted.affected_rows == 1);
    try as("ramsql");
    try expect("SELECT * FROM tdd_a ORDER BY id", "1|1|10;2|1|21;4|2|NULL;6|6|61;7|7|701");
    try sameState();
    // Rejected statements change nothing.
    try as("alice");
    try fails("UPDATE tdd_a SET id = id - 10", error.InsufficientPrivilege);
    try as("ramsql");
    try expect("SELECT v FROM tdd_a ORDER BY id", "10;21;NULL;61;701");
    // COPY FROM and MERGE under row security are not provided (0A000).
    try as("alice");
    var info_ok = true;
    const copy_tx = try db.begin();
    _ = db.copyBegin(copy_tx, "COPY tdd_a FROM STDIN", false) catch |err| blk: {
        info_ok = false;
        try check(err == error.UnsupportedStatement);
        break :blk undefined;
    };
    try check(!info_ok);
    db.abort(copy_tx);
    try fails("INSERT INTO tdd_a VALUES (9, 9, 9) ON CONFLICT DO NOTHING", error.UnsupportedStatement);
    // FORCE: the owner is subject to its policies; superusers never are.
    try as("ramsql");
    try run("ALTER TABLE tdd_a OWNER TO bob");
    try as("bob");
    try expect("SELECT COUNT(*) FROM tdd_a", "5");
    try run("ALTER TABLE tdd_a FORCE ROW LEVEL SECURITY");
    try expect("SELECT id FROM tdd_a ORDER BY id", "1;2;4;6;7");
    try run("DROP POLICY bob_reads ON tdd_a");
    try expect("SELECT id FROM tdd_a ORDER BY id", "2;4;6;7");
    try run("ALTER TABLE tdd_a NO FORCE ROW LEVEL SECURITY");
    try expect("SELECT COUNT(*) FROM tdd_a", "5");
    try as("ramsql");
    try sameState();
    // ALTER POLICY: rename, roles, expressions.
    try run("ALTER POLICY tdd_policy ON tdd_a RENAME TO renamed");
    try run("ALTER POLICY renamed ON tdd_a TO alice, boss USING (id > 2)");
    try expect("SELECT policyname, roles, qual FROM pg_policies WHERE policyname = 'renamed'", "renamed|{alice,boss}|(id > 2)");
    try as("alice");
    try expect("SELECT id FROM tdd_a ORDER BY id", "6;7");
    try as("ramsql");
    // Errors: 42710, 42704, 42601, 42809, 42501, 42703, 0A000.
    const count = "SELECT COUNT(*) FROM pg_policy";
    try rejects("CREATE POLICY renamed ON tdd_a USING (true)", error.DuplicateObject, count, "3");
    try rejects("CREATE POLICY p ON missing USING (true)", error.TableNotFound, count, "3");
    try rejects("CREATE POLICY p ON tdd_a TO nosuch USING (true)", error.UndefinedObject, count, "3");
    try rejects("CREATE POLICY p ON tdd_a FOR INSERT USING (true)", error.Syntax, count, "3");
    try rejects("CREATE POLICY p ON tdd_a FOR SELECT WITH CHECK (true)", error.Syntax, count, "3");
    try rejects("CREATE POLICY p ON tdd_a USING (missing > 1)", error.ColumnNotFound, count, "3");
    try rejects("CREATE POLICY p ON tdd_a USING (id)", error.TypeMismatch, count, "3");
    try rejects("CREATE POLICY p ON tdd_a USING (id IN (SELECT id FROM tdd_b))", error.UnsupportedStatement, count, "3");
    try rejects("ALTER POLICY nosuch ON tdd_a USING (true)", error.UndefinedObject, count, "3");
    try rejects("DROP POLICY nosuch ON tdd_a", error.UndefinedObject, count, "3");
    try run("DROP POLICY IF EXISTS nosuch ON tdd_a");
    try run("CREATE VIEW tdd_view AS SELECT id FROM tdd_a");
    try rejects("CREATE POLICY p ON tdd_view USING (true)", error.WrongObjectType, count, "3");
    try rejects("ALTER TABLE tdd_view ENABLE ROW LEVEL SECURITY", error.WrongObjectType, count, "3");
    try as("alice");
    try rejects("CREATE POLICY p ON tdd_b USING (true)", error.InsufficientPrivilege, count, "3");
    try rejects("ALTER TABLE tdd_b ENABLE ROW LEVEL SECURITY", error.InsufficientPrivilege, count, "3");
    // Views run with their owner's rights: no policy applies through them.
    try fails("SELECT * FROM tdd_view", error.InsufficientPrivilege);
    try as("ramsql");
    try run("GRANT SELECT ON tdd_view TO alice");
    try as("alice");
    try expect("SELECT COUNT(*) FROM tdd_view", "5");
    try as("ramsql");
    try sameState();
    // DISABLE turns enforcement off; the policies stay.
    try run("ALTER TABLE tdd_a DISABLE ROW LEVEL SECURITY");
    try as("alice");
    try expect("SELECT COUNT(*) FROM tdd_a", "5");
    try as("ramsql");
    try expect(count, "3");
    // CREATE POLICY takes AccessExclusive: a live reader blocks it.
    const reading = try db.begin();
    try same(try rows(reading, "SELECT COUNT(*) FROM tdd_a"), "5");
    const creating = try db.begin();
    try parks(creating, "CREATE POLICY later ON tdd_a USING (true)");
    try commit(reading);
    try resumed(creating, "CREATE POLICY later ON tdd_a USING (true)");
    try commit(creating);
    // DROP TABLE drops its policies.
    try run("DROP VIEW tdd_view");
    try run("DROP TABLE tdd_a");
    try expect(count, "0");
    try sameState();
}

// ---- foreign-data wrappers, servers and publications ------------------------------

fn foreignAndPublications() !void {
    try reset();
    try run("CREATE FOREIGN DATA WRAPPER tdd_fdw");
    try run("CREATE FOREIGN DATA WRAPPER plain_fdw NO HANDLER NO VALIDATOR");
    try run("CREATE SERVER tdd_server FOREIGN DATA WRAPPER tdd_fdw");
    try run("CREATE SERVER typed TYPE 'oracle' VERSION '19' FOREIGN DATA WRAPPER tdd_fdw");
    try run("CREATE SERVER IF NOT EXISTS typed FOREIGN DATA WRAPPER plain_fdw");
    try expect("SELECT fdwname, fdwowner, fdwhandler, fdwvalidator, fdwacl, fdwoptions FROM pg_foreign_data_wrapper ORDER BY oid", "tdd_fdw|10|0|0|NULL|NULL;plain_fdw|10|0|0|NULL|NULL");
    try expect("SELECT s.srvname, w.fdwname, s.srvowner, s.srvtype, s.srvversion, s.srvoptions FROM pg_foreign_server s JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw ORDER BY s.oid", "tdd_server|tdd_fdw|10|NULL|NULL|NULL;typed|tdd_fdw|10|oracle|19|NULL");
    try metadata("SELECT srvname, srvfdw, srvtype FROM pg_foreign_server", &.{ "srvname", "srvfdw", "srvtype" }, &.{ 19, 26, 25 });
    try sameState();
    const servers = "SELECT srvname FROM pg_foreign_server ORDER BY srvname";
    try rejects("CREATE FOREIGN DATA WRAPPER tdd_fdw", error.DuplicateObject, servers, "tdd_server;typed");
    try rejects("CREATE SERVER tdd_server FOREIGN DATA WRAPPER tdd_fdw", error.DuplicateObject, servers, "tdd_server;typed");
    try rejects("CREATE SERVER s FOREIGN DATA WRAPPER nosuch", error.UndefinedObject, servers, "tdd_server;typed");
    try rejects("CREATE SERVER s FOREIGN DATA WRAPPER tdd_fdw OPTIONS (host 'x')", error.UnsupportedStatement, servers, "tdd_server;typed");
    try rejects("CREATE FOREIGN DATA WRAPPER f HANDLER h", error.UnsupportedStatement, servers, "tdd_server;typed");
    try rejects("CREATE FOREIGN TABLE ft (id INT) SERVER tdd_server", error.UnsupportedStatement, servers, "tdd_server;typed");
    try rejects("CREATE USER MAPPING FOR ramsql SERVER tdd_server", error.UnsupportedStatement, servers, "tdd_server;typed");
    try rejects("DROP FOREIGN DATA WRAPPER tdd_fdw", error.DependentObjects, servers, "tdd_server;typed");
    try rejects("DROP SERVER nosuch", error.UndefinedObject, servers, "tdd_server;typed");
    // Wrappers need a superuser; servers need USAGE on the wrapper.
    try run("CREATE ROLE outsider");
    try as("outsider");
    try rejects("CREATE FOREIGN DATA WRAPPER mine", error.InsufficientPrivilege, servers, "tdd_server;typed");
    try rejects("CREATE SERVER mine FOREIGN DATA WRAPPER tdd_fdw", error.InsufficientPrivilege, servers, "tdd_server;typed");
    try rejects("DROP SERVER tdd_server", error.InsufficientPrivilege, servers, "tdd_server;typed");
    try rejects("CREATE PUBLICATION mine", error.InsufficientPrivilege, servers, "tdd_server;typed");
    try as("ramsql");
    try run("COMMENT ON SERVER typed IS 'typed server'");
    try run("COMMENT ON FOREIGN DATA WRAPPER tdd_fdw IS 'wrapper'");
    try expect("SELECT obj_description(oid, 'pg_foreign_server') FROM pg_foreign_server WHERE srvname = 'typed'", "typed server");
    try run("DROP SERVER IF EXISTS nosuch, tdd_server");
    try run("DROP FOREIGN DATA WRAPPER tdd_fdw CASCADE");
    try expect(servers, "");
    try expect("SELECT COUNT(*) FROM pg_description", "0");
    try sameState();
    // Publications: catalog entries; no logical decoding or subscriptions.
    try expect("SELECT pubname FROM pg_publication ORDER BY pubname", "");
    try run("CREATE PUBLICATION all_pub FOR ALL TABLES");
    try run("CREATE PUBLICATION some_pub WITH (publish = 'insert, delete', publish_via_partition_root = true)");
    try run("CREATE PUBLICATION plain_pub");
    try expect("SELECT pubname, pubowner, puballtables, pubinsert, pubupdate, pubdelete, pubtruncate, pubviaroot, pubgencols FROM pg_publication ORDER BY pubname", "all_pub|10|t|t|t|t|t|f|n;plain_pub|10|f|t|t|t|t|f|n;some_pub|10|f|t|f|t|f|t|n");
    try metadata("SELECT pubname, puballtables FROM pg_publication", &.{ "pubname", "puballtables" }, &.{ 19, 16 });
    const publications = "SELECT pubname FROM pg_publication ORDER BY pubname";
    try rejects("CREATE PUBLICATION all_pub", error.DuplicateObject, publications, "all_pub;plain_pub;some_pub");
    try rejects("CREATE PUBLICATION p FOR TABLE tdd_a", error.UnsupportedStatement, publications, "all_pub;plain_pub;some_pub");
    try rejects("CREATE PUBLICATION p WITH (publish = 'insert, merge')", error.InvalidParameterValue, publications, "all_pub;plain_pub;some_pub");
    try rejects("CREATE SUBSCRIPTION s CONNECTION 'host=x' PUBLICATION all_pub", error.UnsupportedStatement, publications, "all_pub;plain_pub;some_pub");
    try rejects("DROP PUBLICATION nosuch", error.UndefinedObject, publications, "all_pub;plain_pub;some_pub");
    try run("COMMENT ON PUBLICATION some_pub IS 'some'");
    try run("DROP PUBLICATION IF EXISTS nosuch, some_pub");
    try expect(publications, "all_pub;plain_pub");
    try expect("SELECT COUNT(*) FROM pg_description", "0");
    // Transactional: an aborted CREATE leaves nothing and returns its OID.
    const counter = db.oid_counter;
    const tx = try db.begin();
    try statement(tx, "CREATE PUBLICATION aborted");
    try statement(tx, "CREATE FOREIGN DATA WRAPPER aborted_fdw");
    db.abort(tx);
    try check(db.oid_counter == counter);
    try expect(publications, "all_pub;plain_pub");
    try sameState();
}

// ---- change records -----------------------------------------------------------

fn put(out: []u8, at: *usize, comptime T: type, value: T) void {
    const Bits = switch (@sizeOf(T)) {
        1 => u8,
        2 => u16,
        4 => u32,
        else => @compileError("record field"),
    };
    const bits: Bits = @bitCast(value);
    for (0..@sizeOf(T)) |index| out[at.* + index] = @truncate(bits >> @intCast(index * 8));
    at.* += @sizeOf(T);
}

/// A one-op record: header (version 1, flags 0, one op) and the op bytes.
fn objectRecord(out: []u8, op: u8, kind: u8, oid: u32, target: u32, grantee: u32, sub: i32, tail: []const u8) []const u8 {
    var at: usize = 0;
    put(out, &at, u16, 1);
    put(out, &at, u16, 0);
    put(out, &at, u32, 1);
    put(out, &at, u8, op);
    put(out, &at, u8, kind);
    put(out, &at, u32, oid);
    put(out, &at, u32, target);
    put(out, &at, u32, grantee);
    put(out, &at, i32, sub);
    @memcpy(out[at..][0..tail.len], tail);
    return out[0..at + tail.len];
}

fn replayFails(bytes: []const u8, wanted: anyerror) !void {
    if (replica.applyChangeRecord(bytes, &scratch)) |_| {
        std.debug.print("crafted record accepted at assertion {d}\n", .{assertions});
        return error.InvalidRecordAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("crafted record: {s} (wanted {s})\n", .{ @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn changeRecords() !void {
    try reset();
    try run("CREATE ROLE logged");
    try run("GRANT SELECT ON tdd_a TO logged");
    try run("COMMENT ON TABLE tdd_a IS 'logged'");
    try sameState();
    // Every object create carries owner, flags, name, roles and text; a
    // record that GRANTs on a table writes op 70 (acl kind 3).
    var used: usize = 0;
    var result: DB.Result = .{};
    try db.executeChanges("GRANT INSERT ON tdd_b TO logged", &result, &record, &used, null, null);
    try check(used > 8 and record[8] == 70 and record[9] == 3);
    try replica.applyChangeRecord(record[0..used], &scratch);
    records_applied += 1;
    used = 0;
    try db.executeChanges("REVOKE INSERT ON tdd_b FROM logged", &result, &record, &used, null, null);
    try check(record[8] == 71 and record[9] == 3);
    try replica.applyChangeRecord(record[0..used], &scratch);
    records_applied += 1;
    try sameState();
    const before = replica.oid_counter;
    var buffer: [256]u8 = undefined;
    const tail_ok = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 1, 'x', 0, 0, 0, 0, 0 };
    // Unknown kind, truncated bytes, bad key fields: InvalidChangeRecord.
    try replayFails(objectRecord(&buffer, 70, 10, 20000, 0, 0, 0, &tail_ok), error.InvalidChangeRecord);
    try replayFails(objectRecord(&buffer, 70, 1, 20000, 0, 0, 0, tail_ok[0..5]), error.InvalidChangeRecord);
    try replayFails(objectRecord(&buffer, 70, 1, 20000, 5, 0, 0, &tail_ok), error.InvalidChangeRecord);
    try replayFails(objectRecord(&buffer, 71, 6, 0, 1, 9999, 0, &.{}), error.InvalidChangeRecord);
    // A role with unknown attribute bits, a role named like a reserved one.
    var role_tail = tail_ok;
    role_tail[4] = 0x80;
    try replayFails(objectRecord(&buffer, 70, 1, 20000, 0, 0, 0, &role_tail), error.InvalidChangeRecord);
    const reserved_tail = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 6, 'p', 'u', 'b', 'l', 'i', 'c', 0, 0, 0, 0, 0 };
    try replayFails(objectRecord(&buffer, 70, 1, 20000, 0, 0, 0, &reserved_tail), error.ChangeRecordConflict);
    // OIDs below 16384 or already taken; names already taken.
    try replayFails(objectRecord(&buffer, 70, 1, 100, 0, 0, 0, &tail_ok), error.ChangeRecordConflict);
    try replayFails(objectRecord(&buffer, 70, 1, 16384, 0, 0, 0, &tail_ok), error.ChangeRecordConflict);
    const logged = try roleOid("logged");
    const taken_tail = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 6, 'l', 'o', 'g', 'g', 'e', 'd', 0, 0, 0, 0, 0 };
    try replayFails(objectRecord(&buffer, 70, 1, 20000, 0, 0, 0, &taken_tail), error.ChangeRecordConflict);
    // Grants on a missing table or to a missing role; dropping a missing
    // object; a dangling grant left by a dropped role.
    var acl_tail = [_]u8{ 10, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try replayFails(objectRecord(&buffer, 70, 3, 0, 99999, logged, 0, &acl_tail), error.ChangeRecordConflict);
    try replayFails(objectRecord(&buffer, 70, 3, 0, 16384, 99999, 0, &acl_tail), error.ChangeRecordConflict);
    acl_tail[4] = 0;
    try replayFails(objectRecord(&buffer, 70, 3, 0, 16384, logged, 0, &acl_tail), error.InvalidChangeRecord);
    try replayFails(objectRecord(&buffer, 71, 3, 0, 16386, logged, 0, &.{}), error.ChangeRecordConflict);
    try replayFails(objectRecord(&buffer, 71, 1, logged, 0, 0, 0, &.{}), error.ChangeRecordConflict);
    // A comment on a column past the table's last one.
    const comment_tail = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 0, 0, 1, 0, 'c', 0, 0 };
    try replayFails(objectRecord(&buffer, 70, 6, 0, 16384, 1259, 9, &comment_tail), error.ChangeRecordConflict);
    // Ops 72..79 are reserved for this lane: unknown today.
    try replayFails(objectRecord(&buffer, 72, 1, 20000, 0, 0, 0, &tail_ok), error.UnsupportedLogVersion);
    try check(replica.oid_counter == before);
    try sameState();
    // A record that is valid applies (a role created by a crafted op).
    try replica.applyChangeRecord(objectRecord(&buffer, 70, 1, 20000, 0, 0, 0, &tail_ok), &scratch);
    try same(try queryOn(&replica, "SELECT rolname, oid FROM pg_roles WHERE rolname = 'x'"), "x|20000");
    try check(replica.oid_counter == 20001 - 16384);
}

// ---- capacities -------------------------------------------------------------------

var small: Small = .{};

fn smallFails(source: []const u8, wanted: anyerror) !void {
    var result: Small.Result = .{};
    if (small.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(small.usage().pending_versions == 0 and small.usage().transactions == 0);
}

fn capacities() !void {
    var result: Small.Result = .{};
    try small.execute("CREATE TABLE t (id INT PRIMARY KEY, v INT)", &result);
    // object_text_bytes: a 17-byte comment is 54000; 16 fit.
    try smallFails("COMMENT ON TABLE t IS '12345678901234567'", error.TextCapacity);
    try small.execute("COMMENT ON TABLE t IS '1234567890123456'", &result);
    // policy_roles: one role per policy.
    try small.execute("CREATE ROLE a", &result);
    try smallFails("CREATE POLICY p ON t TO a, PUBLIC USING (true)", error.ProgramLimitExceeded);
    try small.execute("CREATE POLICY p ON t TO a USING (id > 0)", &result);
    try smallFails("CREATE POLICY q ON t USING (id > 0 AND v > 0 AND id < 10)", error.TextCapacity);
    // catalog_objects: four versions in all, also inside one statement.
    try small.execute("CREATE ROLE b", &result);
    try smallFails("CREATE ROLE c", error.TableCapacity);
    try smallFails("ALTER ROLE b LOGIN", error.TableCapacity);
    try small.execute("DROP ROLE b", &result);
    try smallFails("CREATE ROLE c IN ROLE a", error.TableCapacity);
    try small.execute("CREATE ROLE c", &result);
    try same(try queryOn(&small, "SELECT rolname FROM pg_roles ORDER BY oid"), "ramsql;a;c");
    // Lists in one statement: eight names.
    try smallFails("DROP ROLE IF EXISTS n1, n2, n3, n4, n5, n6, n7, n8, n9", error.ProgramLimitExceeded);
}

pub fn main() !void {
    try oraclePrograms();
    try namespacesAndExtensions();
    try comments();
    try roles();
    try privileges();
    try rowSecurity();
    try foreignAndPublications();
    try changeRecords();
    try capacities();
    std.debug.print("catalog security: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
