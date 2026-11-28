//! Composite values, user casts and set-returning select lists
//! (conformance lane B11, wave 5, composite lane; docs/SQL_COMPOSITE.md):
//! ROW values and composite types (record_in / record_out, field
//! selection, (x).*, comparisons, NULL tests), composite table columns,
//! composite routine parameters and results, OUT-parameter records,
//! CREATE / DROP CAST (S211) and several set-returning functions in one
//! select list. Each section checks values (PostgreSQL text output),
//! column names and type OIDs, exact errors (SQLSTATE through the error
//! name), atomicity after a failure and replay: every committed record is
//! applied to a replica that must answer every probe like the primary, and
//! corrupted records fail closed. Every expectation was checked against
//! native PostgreSQL 18.7. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 256, .nulls_first_ascending = false,
    .integer_bits = 32, .transactions = 4, .sequences = 2, .expr_nodes = 2048, .routines = 24, .triggers = 2, .rules = 1, .casts = 4,
    .routine_args = 6, .routine_bytes = 512, .schemas = 4, .work_rows = 512, .catalog_objects = 32 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("composite contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.CompositeContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
var query_values: [DB.Result.value_bytes]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output; user
/// type names through the primary's catalog hooks).
fn render(result: *const DB.Result) ![]const u8 {
    db.installOutputHooks();
    const session = db.routineSession();
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
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn query(target: *DB, source: []const u8) ![]const u8 {
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// The OID of a user type, read from pg_type.
fn typeOid(name: []const u8) !u32 {
    var text: [128]u8 = undefined;
    var result: DB.Result = .{};
    try db.execute(try std.fmt.bufPrint(&text, "SELECT oid FROM pg_type WHERE typname = '{s}'", .{name}), &result);
    try check(result.row_count == 1);
    return @intCast(result.rows[0].cells[0].integer);
}

/// A result column's type OID as the wire reports it (a composite
/// column's typmod is its type's OID).
fn columnOid(result: *const DB.Result, column: usize) u32 {
    if (result.column_types[column] == .record) return if (result.column_typmods[column] > 0) @intCast(result.column_typmods[column]) else 2249;
    return sql.typeOid(result.column_types[column]);
}

/// Column names (`a,b`), type OIDs (below 100: the composite type of that
/// index in `composites`, comma-separated) and rows of a replicated statement.
fn expectColumns(source: []const u8, names: []const u8, oids: []const u32, composites: []const u8, wanted: []const u8) !void {
    const result = try replicate(source);
    var joined: [256]u8 = undefined;
    var at: usize = 0;
    for (0..result.column_count) |column| {
        if (column != 0) {
            joined[at] = ',';
            at += 1;
        }
        const name = result.column_names[column].slice();
        @memcpy(joined[at..][0..name.len], name);
        at += name.len;
    }
    try same(joined[0..at], names);
    try check(result.column_count == oids.len);
    for (oids, 0..) |oid, column| {
        var want = oid;
        if (oid < 100) {
            var it = std.mem.splitScalar(u8, composites, ',');
            var index: usize = 0;
            while (it.next()) |name| : (index += 1) {
                if (index == oid) want = try typeOid(name);
            }
        }
        if (columnOid(&result, column) != want) std.debug.print("{s}: column {d} type {d}, want {d}\n", .{ source, column, columnOid(&result, column), want });
        try check(columnOid(&result, column) == want);
    }
    try same(try render(&result), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    result.bindValueMemory(&query_values);
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

/// A replicated statement and its rendered result rows.
fn runRows(source: []const u8, wanted: []const u8) !void {
    const result = try replicate(source);
    try same(try render(&result), wanted);
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
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0);
}

fn fails(source: []const u8, wanted: anyerror) !void {
    try rejects(source, wanted, "SELECT 1", "1");
}

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        var copy: [16384]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        const right = try query(&replica, probe);
        try same(right, copy[0..left.len]);
    }
}

/// A change record that must fail closed on a fresh replica copy.
fn rejectRecord(bytes: []const u8, wanted: anyerror) !void {
    var probe = scratch;
    _ = &probe;
    if (replica.applyChangeRecord(bytes, &scratch)) |_| {
        std.debug.print("corrupt record accepted\n", .{});
        return error.CorruptRecordAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("corrupt record: {s} (wanted {s})\n", .{ @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

/// The record of one statement, kept for corruption probes.
fn captured(source: []const u8, out: []u8) !usize {
    var result: DB.Result = .{};
    var used: usize = 0;
    try db.executeChanges(source, &result, out, &used, null, null);
    return used;
}

fn find(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

fn le32(value: u32) [4]u8 {
    return .{ @truncate(value), @truncate(value >> 8), @truncate(value >> 16), @truncate(value >> 24) };
}

// ---- composite values ------------------------------------------------------

fn values() !void {
    try run("CREATE TYPE pt AS (x INT, y TEXT)");
    try run("CREATE TYPE doc AS (id INT, body XML)");
    try run("CREATE TYPE money_box AS (amount NUMERIC(6,2), code VARCHAR(3), at TIMESTAMP(0), tags TEXT[])");
    // Anonymous records: `row`, type record, record_out quoting.
    try expectColumns("SELECT ROW(1, 'a b', NULL), (2, 'x')", "row,row", &.{ 2249, 2249 }, "", "(1,\"a b\",)|(2,x)");
    // X014: a field of an XML attribute type.
    try expectColumns("SELECT (ROW(1, '<p/>')::doc).body, ROW(1, '<p/>')::doc", "body,row", &.{ 142, 0 }, "doc", "<p/>|(1,<p/>)");
    // record_in: quotes, doubled quotes, empty fields as NULL, spaces kept.
    try expectColumns("SELECT '(3,\"a,b\")'::pt, '(4,\"say \"\"hi\"\"\")'::pt, '(,)'::pt, '(5,\"\")'::pt, ' ( 1 , 2 ) '::pt", "pt,pt,pt,pt,pt", &.{ 0, 0, 0, 0, 0 }, "pt",
        "(3,\"a,b\")|(4,\"say \"\"hi\"\"\")|(,)|(5,\"\")|(1,\" 2 \")");
    // Fields convert explicitly to their declared types and typmods.
    try expectColumns("SELECT ROW(12.345, 'abcdef', '2024-01-02 03:04:05.6', ARRAY['p','q r'])::money_box", "row", &.{0}, "money_box",
        "(12.35,abc,\"2024-01-02 03:04:06\",\"{p,\"\"q r\"\"}\")");
    try expectColumns("SELECT (ROW(1,'a')::pt).x, (ROW(1,'a')::pt).y, (ROW(7, 8)).f2", "x,y,f2", &.{ 23, 25, 23 }, "", "1|a|8");
    try expectColumns("SELECT (ROW(1,'a')::pt).*", "x,y", &.{ 23, 25 }, "", "1|a");
    try expect("SELECT pg_typeof(ROW(1,'a')::pt), pg_typeof(ROW(1,'a')), pg_typeof((ROW(1,'a')::pt).y)", "pt|record|text");
    // record_eq / record_cmp: two NULL fields are equal, NULL sorts last.
    try expect("SELECT ROW(1,'a')::pt = ROW(1,'a')::pt, ROW(1,'a')::pt < ROW(1,'b')::pt, ROW(1,NULL)::pt = ROW(1,NULL)::pt, ROW(1,NULL)::pt > ROW(1,'z')::pt", "t|t|t|t");
    // Two row constructors compare row-wise (SQL NULL semantics).
    try expect("SELECT ROW(1,NULL) = ROW(1,NULL), ROW(1,2) < ROW(1,NULL), ROW(1,'a')::pt IS DISTINCT FROM ROW(1,NULL)::pt", "NULL|NULL|t");
    try expect("SELECT ROW(1,'a')::pt IS NULL, ROW(NULL,NULL)::pt IS NULL, ROW(1,NULL)::pt IS NOT NULL, NULL::pt IS NULL", "f|t|f|t");
    try expectColumns("SELECT ROW(1,'a')::pt::text, CAST(ROW(2,'b')::pt AS VARCHAR(4)), '(9,z)'::text::pt", "row,row,pt", &.{ 25, 1043, 0 }, "pt", "(1,a)|(2,b|(9,z)");
    try expect("SELECT row_to_json(ROW(1,'a')::pt), to_json(ROW(2,NULL)::pt), row_to_json(ROW(1,'q'), true)", "{\"x\":1,\"y\":\"a\"}|{\"x\":2,\"y\":null}|{\"f1\":1,\n \"f2\":\"q\"}");
    try expectColumns("SELECT COALESCE(NULL::pt, ROW(7,'c')::pt), CASE WHEN false THEN NULL ELSE ROW(8,'d')::pt END", "coalesce,row", &.{ 0, 0 }, "pt", "(7,c)|(8,d)");
    // record_in errors, field counts, conversions and field names.
    try fails("SELECT '(1,2,3)'::pt", error.InvalidTextRepresentation);
    try fails("SELECT '(1)'::pt", error.InvalidTextRepresentation);
    try fails("SELECT '(1,2)x'::pt", error.InvalidTextRepresentation);
    try fails("SELECT '(a,2)'::pt", error.InvalidTextRepresentation);
    try fails("SELECT ROW(1,'a',3)::pt", error.CannotCoerce);
    try fails("SELECT ROW('x','a')::pt", error.InvalidTextRepresentation);
    try fails("SELECT (1).x", error.WrongObjectType);
    try fails("SELECT (ROW(1,'a')::pt).z", error.ColumnNotFound);
    // A row constructor keeps its field types beside a composite (record_eq
    // compares column types: 42804); an untyped side is an anonymous record.
    try fails("SELECT ROW(1,'a')::pt = ROW(1,'a')", error.TypeMismatch);
    try fails("SELECT ROW(1,'a')::pt = ROW(1,'a')::doc", error.TypeMismatch);
    try fails("SELECT '(1,a)'::pt = '(1,a)'", error.UnsupportedStatement);
    try fails("SELECT '(1,a)'::record", error.UnsupportedStatement);
}

// ---- composite table columns -------------------------------------------------

fn columns() !void {
    try run("CREATE TABLE shapes(id INT PRIMARY KEY, p pt, d doc)");
    try run("INSERT INTO shapes VALUES (1, ROW(1,'a'), ROW(2, '<q/>')), (2, ROW(2,NULL), NULL), (3, NULL, '(3,<r/>)'), (4, '(1,a)', ROW(NULL, NULL)), (5, '(0,\"z z\")', NULL)");
    try expectColumns("SELECT id, p, d, (p).y, (d).body FROM shapes ORDER BY id", "id,p,d,y,body", &.{ 23, 0, 1, 25, 142 }, "pt,doc",
        "1|(1,a)|(2,<q/>)|a|<q/>;2|(2,)|NULL|NULL|NULL;3|NULL|(3,<r/>)|NULL|<r/>;4|(1,a)|(,)|a|NULL;5|(0,\"z z\")|NULL|z z|NULL");
    try expect("SELECT id FROM shapes WHERE p = ROW(1,'a')::pt ORDER BY id", "1;4");
    try expect("SELECT p, count(*) FROM shapes GROUP BY p ORDER BY p", "(0,\"z z\")|1;(1,a)|2;(2,)|1;NULL|1");
    try expect("SELECT DISTINCT p FROM shapes ORDER BY p DESC", "NULL;(2,);(1,a);(0,\"z z\")");
    try expect("SELECT id, p IS NULL, d IS NULL, d IS NOT NULL FROM shapes ORDER BY id", "1|f|f|t;2|f|t|f;3|t|f|t;4|f|t|f;5|f|t|f");
    try expectColumns("SELECT max(p), min(p) FROM shapes", "max,min", &.{ 0, 0 }, "pt", "(2,)|(0,\"z z\")");
    try runRows("UPDATE shapes SET p = ROW((p).x + 100, (p).y) WHERE id = 1 RETURNING id, p, (p).x", "1|(101,a)|101");
    try expect("SELECT attname, atttypid = (SELECT oid FROM pg_type WHERE typname = 'pt'), atttypmod FROM pg_attribute WHERE attrelid = 'shapes'::regclass AND attname = 'p'", "p|t|-1");
    const probe = "SELECT id, p FROM shapes ORDER BY id";
    const before = "1|(101,a);2|(2,);3|NULL;4|(1,a);5|(0,\"z z\")";
    try rejects("INSERT INTO shapes VALUES (6, ROW(1))", error.CannotCoerce, probe, before);
    try rejects("INSERT INTO shapes VALUES (6, 5)", error.TypeMismatch, probe, before);
    try rejects("INSERT INTO shapes VALUES (6, '(1,2,3)')", error.InvalidTextRepresentation, probe, before);
    try rejects("INSERT INTO shapes(id, d) VALUES (6, ROW(1, 'not xml <'))", error.InvalidXmlContent, probe, before);
    try rejects("DROP TYPE pt", error.DependentObjects, probe, before);
    try fails("CREATE TABLE bad(r record)", error.InvalidTableDefinition);
    try fails("CREATE TABLE bad(r no_such_type)", error.UndefinedObject);
    try run("CREATE TABLE dflt(id INT, p pt DEFAULT ROW(42, 'dflt'))");
    try run("INSERT INTO dflt(id) VALUES (1)");
    try expect("SELECT p FROM dflt", "(42,dflt)");
    try sameState(&.{ probe, "SELECT d, (d).body FROM shapes ORDER BY id", "SELECT p FROM dflt", "SELECT p, count(*) FROM shapes GROUP BY p ORDER BY p" });
}

// ---- composite routine parameters and results ------------------------------

fn routines() !void {
    try run("CREATE FUNCTION pt_label(p pt) RETURNS TEXT LANGUAGE SQL AS $$SELECT p.x || ':' || p.y$$");
    try expect("SELECT pt_label(ROW(1,'a')::pt), pt_label(ROW(2,'b')), pt_label('(3,c)')", "1:a|2:b|3:c");
    try run("CREATE FUNCTION mk(a INT) RETURNS pt LANGUAGE SQL AS $$SELECT a, 'n' || a$$");
    try run("CREATE FUNCTION mk2(a INT) RETURNS pt LANGUAGE SQL AS $$SELECT ROW(a, 'r')::pt$$");
    try run("CREATE FUNCTION swap(p pt) RETURNS pt LANGUAGE plpgsql AS $$BEGIN RETURN ROW(p.x * 10, p.y || '!')::pt; END$$");
    try expectColumns("SELECT mk(3), (mk(4)).y, mk2(5), swap(ROW(6,'s')::pt), pg_typeof(mk(1))", "mk,y,mk2,swap,pg_typeof", &.{ 0, 25, 0, 0, 2206 }, "pt", "(3,n3)|n4|(5,r)|(60,s!)|pt");
    try expectColumns("SELECT (mk(7)).*", "x,y", &.{ 23, 25 }, "", "7|n7");
    try run("CREATE FUNCTION two_out(OUT a INT, OUT b TEXT) LANGUAGE SQL AS $$SELECT 1, 'x'$$");
    try run("CREATE FUNCTION three_out(n INT, OUT a INT, OUT b TEXT) LANGUAGE plpgsql AS $$BEGIN a := n; b := 'p' || n; END$$");
    try expectColumns("SELECT two_out(), (two_out()).b, three_out(7), (three_out(8)).a, pg_typeof(two_out())", "two_out,b,three_out,a,pg_typeof", &.{ 2249, 25, 2249, 23, 2206 }, "", "(1,x)|x|(7,p7)|8|record");
    try expectColumns("SELECT (three_out(9)).*", "a,b", &.{ 23, 25 }, "", "9|p9");
    try sameState(&.{ "SELECT mk(3), (mk(4)).y, mk2(5), swap(ROW(6,'s')::pt)", "SELECT pt_label('(3,c)'), two_out(), three_out(7)" });
    // A composite type a routine uses stays (2BP01); a signature names it.
    try rejects("DROP TYPE doc", error.DependentObjects, "SELECT count(*) FROM shapes", "5");
    try run("DROP FUNCTION mk2(int)");
    try run("DROP FUNCTION swap(pt)");
    try fails("SELECT mk2(1)", error.UndefinedFunction);
    try fails("SELECT swap(ROW(1,'a')::pt)", error.UndefinedFunction);
}

// ---- user casts (S211) -------------------------------------------------------

fn casts() !void {
    try run("CREATE TYPE pair AS (x INT, y INT)");
    try run("CREATE FUNCTION pair_text(p pair) RETURNS TEXT LANGUAGE SQL AS $$SELECT p.x || ':' || p.y$$");
    try run("CREATE CAST (pair AS TEXT) WITH FUNCTION pair_text(pair)");
    try expect("SELECT castcontext, castmethod, castfunc = (SELECT oid FROM pg_proc WHERE proname = 'pair_text'), casttarget FROM pg_cast WHERE castsource = (SELECT oid FROM pg_type WHERE typname = 'pair')", "e|f|t|25");
    // The cast function wins over I/O conversion; varchar has none.
    try expectColumns("SELECT CAST(ROW(1, 2)::pair AS TEXT), ROW(1,2)::pair::text, ROW(3,4)::pair::varchar", "row,row,row", &.{ 25, 25, 1043 }, "", "1:2|1:2|(3,4)");
    try fails("CREATE CAST (pair AS TEXT) WITH FUNCTION pair_text(pair)", error.DuplicateObject);
    try run("CREATE TABLE texts(s text)");
    // An explicit-only cast leaves no assignment path (42804).
    try rejects("INSERT INTO texts VALUES (ROW(5,6)::pair)", error.TypeMismatch, "SELECT count(*) FROM texts", "0");
    try run("CREATE CAST (pair AS varchar) WITH INOUT AS ASSIGNMENT");
    try run("INSERT INTO texts VALUES (ROW(7,8)::pair::varchar)");
    try expect("SELECT s FROM texts", "(7,8)");
    try rejects("DROP FUNCTION pair_text(pair)", error.DependentObjects, "SELECT ROW(1,2)::pair::text", "1:2");
    try run("DROP FUNCTION pair_text(pair) CASCADE");
    try expect("SELECT ROW(1,2)::pair::text", "(1,2)");
    try run("CREATE TYPE wrapper AS (v INT)");
    try run("CREATE FUNCTION int_wrap(i INT) RETURNS wrapper LANGUAGE SQL AS $$SELECT ROW(i)::wrapper$$");
    try run("CREATE CAST (INT AS wrapper) WITH FUNCTION int_wrap(INT) AS ASSIGNMENT");
    try expectColumns("SELECT (5::wrapper).v", "v", &.{23}, "", "5");
    try run("CREATE TABLE wrapped(w wrapper)");
    try run("INSERT INTO wrapped VALUES (7)");
    try expect("SELECT w FROM wrapped", "(7)");
    try fails("SELECT int_wrap(1) = 1", error.UndefinedFunction);
    try sameState(&.{ "SELECT w FROM wrapped", "SELECT (5::wrapper).v", "SELECT castcontext, castmethod FROM pg_cast WHERE casttarget = (SELECT oid FROM pg_type WHERE typname = 'wrapper')" });
    try run("DROP CAST (INT AS wrapper)");
    try fails("SELECT 5::wrapper", error.CannotCoerce);
    try fails("DROP CAST (INT AS wrapper)", error.UndefinedObject);
    try run("DROP CAST IF EXISTS (INT AS wrapper)");
    // CreateCast's checks.
    try fails("CREATE CAST (int AS bigint) WITHOUT FUNCTION", error.InvalidObjectDefinition);
    try fails("CREATE CAST (int4 AS oid) WITHOUT FUNCTION", error.DuplicateObject);
    try fails("CREATE CAST (pair AS wrapper) WITHOUT FUNCTION", error.InvalidObjectDefinition);
    try fails("CREATE CAST (int AS wrapper) WITH FUNCTION pair_text(pair)", error.UndefinedFunction);
    try fails("CREATE CAST (int AS int) WITH INOUT", error.InvalidObjectDefinition);
    try fails("CREATE CAST (no_such AS int) WITH INOUT", error.UndefinedObject);
    // The function's typmod and explicitness arguments.
    try run("CREATE FUNCTION two(a int, b int) RETURNS wrapper LANGUAGE SQL AS $$SELECT ROW(a)::wrapper$$");
    try run("CREATE CAST (int AS wrapper) WITH FUNCTION two(int, int)");
    try expectColumns("SELECT 5::wrapper, CAST(6 AS wrapper)", "wrapper,wrapper", &.{ 0, 0 }, "wrapper", "(5)|(6)");
    try run("CREATE CAST (text AS pair) WITH INOUT");
    try expect("SELECT '(1,2)'::text::pair", "(1,2)");
    try sameState(&.{ "SELECT 5::wrapper", "SELECT '(1,2)'::text::pair", "SELECT count(*) FROM pg_cast WHERE oid >= 16384" });
    // DROP TYPE: a cast naming the type stays (2BP01).
    try rejects("DROP TYPE wrapper", error.DependentObjects, "SELECT 5::wrapper", "(5)");
    try run("DROP CAST (int AS wrapper)");
    try run("DROP CAST (text AS pair)");
    try run("DROP CAST (pair AS varchar)");
    try expect("SELECT count(*) FROM pg_cast WHERE oid >= 16384", "0");
}

// ---- change-log validation ---------------------------------------------------

fn corruption() !void {
    var bytes: [4096]u8 = undefined;
    // Value tag 57: the record's field type OID must be a built-in type.
    const pt = try typeOid("pt");
    var used = try captured("INSERT INTO shapes VALUES (10, ROW(7,'q'), NULL)", &bytes);
    const head = [_]u8{57} ++ le32(pt) ++ [_]u8{2};
    const at = find(bytes[0..used], &head) orelse return error.RecordTagMissing;
    const field = at + head.len;
    const original = bytes[field..][0..4].*;
    bytes[field..][0..4].* = le32(0xfffe);
    try rejectRecord(bytes[0..used], error.InvalidChangeRecord);
    // A record field may not be a record (no nesting).
    bytes[field..][0..4].* = le32(2249);
    try rejectRecord(bytes[0..used], error.InvalidChangeRecord);
    // The record's type must be the column's.
    bytes[field..][0..4].* = original;
    bytes[at + 1 ..][0..4].* = le32(2249);
    try rejectRecord(bytes[0..used], error.ChangeRecordConflict);
    bytes[at + 1 ..][0..4].* = le32(pt);
    try replica.applyChangeRecord(bytes[0..used], &scratch);
    records_applied += 1;
    // Op 121: a cast needs a known method and a live function returning
    // its target.
    try run("CREATE FUNCTION int_pair(i INT) RETURNS pair LANGUAGE SQL AS $$SELECT i, i$$");
    used = try captured("CREATE CAST (INT AS pair) WITH FUNCTION int_pair(INT)", &bytes);
    const cast_at = find(bytes[0..used], &[_]u8{121}) orelse return error.RecordTagMissing;
    // tag, payload length u32, oid, source, target, function, context, method.
    const function = cast_at + 1 + 4 + 4 + 4 + 4;
    const method = function + 4 + 1;
    bytes[method] = 'x';
    try rejectRecord(bytes[0..used], error.InvalidChangeRecord);
    bytes[method] = 'f';
    const kept = bytes[function..][0..4].*;
    bytes[function..][0..4].* = le32(0x7fff0000);
    try rejectRecord(bytes[0..used], error.ChangeRecordConflict);
    bytes[function..][0..4].* = kept;
    try replica.applyChangeRecord(bytes[0..used], &scratch);
    records_applied += 1;
    try sameState(&.{ "SELECT 3::pair", "SELECT id, p FROM shapes ORDER BY id" });
    try run("DROP CAST (INT AS pair)");
}

// ---- set-returning functions in the select list (ProjectSet) ---------------

fn projectSet() !void {
    // Every set-returning call runs in lockstep; the longest decides the
    // row count and the shorter ones yield NULL (PostgreSQL 10+).
    try expectColumns("SELECT generate_series(1,3), generate_series(1,5)", "generate_series,generate_series", &.{ 23, 23 }, "", "1|1;2|2;3|3;NULL|4;NULL|5");
    try expectColumns("SELECT generate_series(1,2), unnest(ARRAY['a','b','c'])", "generate_series,unnest", &.{ 23, 25 }, "", "1|a;2|b;NULL|c");
    try expect("SELECT generate_series(1,3) * 10, 'x'", "10|x;20|x;30|x");
    try expect("SELECT generate_series(1,3) + generate_series(10,11)", "11;13;NULL");
    try expect("SELECT unnest(ARRAY[1,2]) AS u, generate_subscripts(ARRAY[5,6,7], 1) AS s", "1|1;2|2;NULL|3");
    try expect("SELECT regexp_matches('a1b2c3', '[0-9]', 'g'), generate_series(1,2)", "{1}|1;{2}|2;{3}|NULL");
    try expect("SELECT generate_series(1,0), 5", "");
    try expectColumns("SELECT generate_series(1.5, 3.5), generate_series('2024-01-01'::timestamp, '2024-01-03', '1 day')", "generate_series,generate_series", &.{ 1700, 1114 }, "",
        "1.5|2024-01-01 00:00:00;2.5|2024-01-02 00:00:00;3.5|2024-01-03 00:00:00");
    try run("CREATE TABLE srf_t(a INT, arr INT[])");
    try run("INSERT INTO srf_t VALUES (1, '{10,20}'), (2, '{30}'), (3, NULL)");
    try expect("SELECT a, unnest(arr), generate_series(1, a) FROM srf_t ORDER BY 1, 3", "1|10|1;1|20|NULL;2|30|1;2|NULL|2;3|NULL|1;3|NULL|2;3|NULL|3");
    try expect("SELECT a, generate_series(1, a) FROM srf_t WHERE a < 3 ORDER BY 1, 2 LIMIT 2", "1|1;2|1");
    try expect("SELECT DISTINCT generate_series(1, 2) FROM srf_t ORDER BY 1", "1;2");
    // Over groups: after aggregation.
    try expect("SELECT count(*), generate_series(1,2) FROM srf_t", "3|1;3|2");
    try expect("SELECT a, generate_series(1,2) FROM srf_t GROUP BY a ORDER BY 1,2", "1|1;1|2;2|1;2|2;3|1;3|2");
    try run("CREATE FUNCTION three() RETURNS SETOF INT LANGUAGE SQL AS $$VALUES (7), (8), (9)$$");
    try expect("SELECT three(), generate_series(1,2), unnest(ARRAY['p'])", "7|1|p;8|2|NULL;9|NULL|NULL");
    try expect("SELECT three() + 1, three()", "8|7;9|8;10|9");
    try expect("SELECT jsonb_path_query('[1,2,3]', '$[*]'), generate_series(1,4)", "1|1;2|2;3|3;NULL|4");
    // Not in WHERE, CASE, COALESCE or an aggregate (0A000), a zero step
    // is 22023.
    try fails("SELECT 1 WHERE generate_series(1,2) > 0", error.UnsupportedStatement);
    try fails("SELECT CASE WHEN true THEN generate_series(1,2) END", error.UnsupportedStatement);
    try fails("SELECT COALESCE(generate_series(1,2), 0)", error.UnsupportedStatement);
    try fails("SELECT sum(generate_series(1,3))", error.UnsupportedStatement);
    try fails("SELECT generate_series(1, 3, 0)", error.InvalidParameterValue);
}

fn contract() !void {
    try values();
    try columns();
    try routines();
    try casts();
    try corruption();
    try projectSet();
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    contract() catch |err| {
        std.debug.print("composite contract stopped after {d} assertions\n", .{assertions});
        return err;
    };
    std.debug.print("composite: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
