//! System-view contracts (design §4.10, §5.14/§5.15): pg_catalog and
//! information_schema views are computed at scan time from the versioned
//! catalog, the table definitions and the static type table under the
//! statement snapshot, so they change after every mutation (create, drop,
//! recreate at Config.tables = 2 without CatalogCapacity), follow
//! transactional DDL (uncommitted CREATE invisible to others, ROLLBACK
//! removes it) and survive change-record replay with the same OIDs. No code
//! path is keyed on query text. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 2, .columns = 6, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4 });
var assertions: usize = 0;
var db: DB = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("catalog contract failed at assertion {d}\n", .{assertions});
        return error.CatalogContractFailed;
    }
}

var text_buffer: [4096]u8 = undefined;
fn render(result: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
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
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn expectOn(target: *DB, source: []const u8, wanted: []const u8) !void {
    var result: DB.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    const got = try render(&result);
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ source, got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn expect(source: []const u8, wanted: []const u8) !void {
    return expectOn(&db, source, wanted);
}

fn run(source: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.execute(source, &result)) |_| return error.InvalidStatementAccepted else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
}

const public_tables = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name";
const public_classes = "SELECT relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY relname";

fn types() !void {
    try expect("SELECT oid, typname FROM pg_catalog.pg_type WHERE typname = 'int4'", "23|int4");
    try expect("SELECT COUNT(*), MIN(typnamespace), MAX(typnamespace) FROM pg_type", "16|11|11");
    try expect("SELECT typname, typlen, typcategory, typarray, typdelim, typinput FROM pg_type WHERE oid IN (16, 1700, 3802) ORDER BY oid", "bool|1|B|1000|,|boolin;numeric|-1|N|1231|,|numeric_in;jsonb|-1|U|3807|,|jsonb_in");
    try expect("SELECT typname, oid::regtype::text, format_type(oid, NULL) FROM pg_type WHERE typname IN ('int8', 'float8', 'timestamptz') ORDER BY typname", "float8|double precision|double precision;int8|bigint|bigint;timestamptz|timestamp with time zone|timestamp with time zone");
    try expect("SELECT typname FROM pg_type t WHERE t.oid = to_regtype('integer')", "int4");
    try expect("SELECT to_regtype('nope') IS NULL, to_regtype('pg_catalog.numeric(10,2)'), 'int8'::regtype = 20::oid", "t|1700|t");
    try expect("SELECT format_type(1700, 655366), format_type(1184, 3), format_type(23, -1), format_type(99999, NULL)", "numeric(10,2)|timestamp(3) with time zone|integer|???");
    try rejects("SELECT 'nope'::regtype", error.UndefinedObject);
    try expect("SELECT current_database(), current_schema()", "postgres|public");
    try expect("SELECT nspname FROM pg_namespace ORDER BY oid", "pg_catalog;public;information_schema");
    try expect("SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'public'", "public");
    try expect(public_tables, "");
}

fn lifecycle() !void {
    try run("CREATE TABLE a (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, amount NUMERIC(10,2), at TIMESTAMPTZ(3), doc JSONB, label TEXT DEFAULT 'd', n INTEGER DEFAULT 2 + 3)");
    try expect(public_tables, "a");
    try expect(public_classes, "a|r;a_id_seq|S;a_pkey|i");
    try expect("SELECT c.relname, c.relnatts FROM pg_class c WHERE c.oid = 'a'::regclass", "a|6");
    try expect("SELECT 'a'::regclass::text, 'a_pkey'::regclass::text, 'public.a_id_seq'::regclass::text, to_regclass('nope') IS NULL", "a|a_pkey|a_id_seq|t");
    try rejects("SELECT 'nope'::regclass", error.TableNotFound);
    try expect("SELECT i.indisprimary, i.indkey, c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'a'::regclass", "t|1|a_pkey");
    try expect("SELECT attname, atttypid, atttypmod, attnotnull, attidentity, atthasdef FROM pg_attribute WHERE attrelid = 'a'::regclass AND attnum > 0 ORDER BY attnum",
        "id|23|-1|t|a|f;amount|1700|655366|f||f;at|1184|3|f||f;doc|3802|-1|f||f;label|25|-1|f||t;n|23|-1|f||t");
    try expect("SELECT column_name, data_type, numeric_precision, numeric_scale, datetime_precision, is_nullable FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position",
        "id|integer|32|0|NULL|NO;amount|numeric|10|2|NULL|YES;at|timestamp with time zone|NULL|NULL|3|YES;doc|jsonb|NULL|NULL|NULL|YES;label|text|NULL|NULL|NULL|YES;n|integer|32|0|NULL|YES");
    try expect("SELECT column_name, column_default, is_identity, identity_generation FROM information_schema.columns WHERE table_name = 'a' ORDER BY ordinal_position",
        "id|NULL|YES|ALWAYS;amount|NULL|NO|NULL;at|NULL|NO|NULL;doc|NULL|NO|NULL;label|'d'::text|NO|NULL;n|(2 + 3)|NO|NULL");
    try expect("SELECT adnum, pg_get_expr(adbin, adrelid) FROM pg_attrdef WHERE adrelid = 'a'::regclass ORDER BY adnum", "5|'d'::text;6|(2 + 3)");
    try expect("SELECT seqtypid, seqstart, seqincrement, seqmax, seqcycle FROM pg_sequence WHERE seqrelid = 'a_id_seq'::regclass", "23|1|1|2147483647|f");
    try expect("SELECT tc.constraint_name, tc.constraint_type, k.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage k ON k.constraint_name = tc.constraint_name WHERE tc.table_name = 'a'", "a_pkey|PRIMARY KEY|id");
    // A second table (capacity 2), drop, recreate: no catalog exhaustion.
    try run("CREATE TABLE b (k TEXT)");
    try expect(public_tables, "a;b");
    try run("DROP TABLE a");
    try expect(public_classes, "b|r");
    try run("CREATE TABLE a (id INTEGER GENERATED BY DEFAULT AS IDENTITY, v INTEGER)");
    try expect(public_classes, "a|r;a_id_seq|S;b|r");
    try expect("SELECT identity_generation FROM information_schema.columns WHERE table_name = 'a' AND column_name = 'id'", "BY DEFAULT");
    for (0..6) |_| {
        try run("DROP TABLE a");
        try run("CREATE TABLE a (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, v INTEGER)");
    }
    try expect(public_classes, "a|r;a_id_seq|S;a_pkey|i;b|r");
    // Uncommitted DDL is visible only to its own transaction.
    const owner = try db.begin();
    var result: DB.Result = .{};
    try db.statement(owner, "DROP TABLE b", &result, .{});
    try db.statement(owner, "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'", &result, .{});
    try check(result.rows[0].cells[0].integer == 1);
    const other = try db.begin();
    try db.statement(other, "SELECT COUNT(*) FROM pg_class WHERE relname = 'b'", &result, .{});
    try check(result.rows[0].cells[0].integer == 1);
    db.abort(other);
    db.abort(owner);
    try expect(public_tables, "a;b");
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0);
}

var primary: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;

fn replicated(source: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    try primary.executeChanges(source, &result, &record, &used, null, null);
    if (used != 0) try replica.applyChangeRecord(record[0..used], &scratch);
}

/// Replay reproduces catalog metadata including OIDs (index and sequence
/// OIDs follow the table's).
fn replay() !void {
    try replicated("CREATE TABLE x (id INTEGER PRIMARY KEY, v TEXT DEFAULT 'v')");
    try replicated("CREATE TABLE y (id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY)");
    try replicated("DROP TABLE x");
    try replicated("CREATE TABLE x (k INTEGER)");
    const query = "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid";
    var a: DB.Result = .{};
    var b: DB.Result = .{};
    try primary.execute(query, &a);
    try replica.execute(query, &b);
    const left = try render(&a);
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..left.len], left);
    const right = try render(&b);
    if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("primary {s}\nreplica {s}\n", .{ copy[0..left.len], right });
    try check(std.mem.eql(u8, copy[0..left.len], right));
    try check(a.row_count == 4);
    try expectOn(&replica, "SELECT column_default FROM information_schema.columns WHERE table_name = 'x'", "NULL");
}

pub fn main(init: std.process.Init) !void {
    try types();
    try lifecycle();
    try replay();
    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-catalog\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
