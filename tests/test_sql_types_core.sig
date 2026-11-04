//! Core PostgreSQL scalar type contract (conformance lane B11 "types"):
//! VARCHAR(n)/CHAR(n)/BPCHAR, UUID, BYTEA, TIME/TIMETZ, BIT/VARBIT and MONEY.
//! Every section checks exact values and result metadata (type OID, typmod),
//! NULLs, ordering and comparison, casts to and from text, accepted input
//! forms, rejected input with its exact error (SQLSTATE), statement
//! atomicity, the wire representation (pg_types) and change-record replay.
//!
//! Expected values follow PostgreSQL 18.3. Fixtures that are also in
//! tests/sql_conformance/postgres18_oracle.json are marked "oracle"; every
//! other expectation is derived from the PostgreSQL 18 documentation and
//! source and is pending native verification (no PostgreSQL server was
//! available when this contract was written).
const std = @import("std");
const sql = @import("sql");
const pg_types = @import("pg_types");

const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 128, .integer_bits = 32, .nulls_first_ascending = false, .work_rows = 48, .result_rows = 48 });
const Io = DB.Io;
const Wire = pg_types.Types(DB.Result);
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlTypesCoreContractFailed;
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// Every row of a query, columns joined by '|' and rows by ';' (NULL as NULL).
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

/// The current result rendered as in rows().
fn shown(source: []const u8, expected: []const u8) !void {
    var out: [4096]u8 = undefined;
    var at: usize = 0;
    for (0..result.row_count) |index| {
        if (index != 0) {
            out[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                out[at] = '|';
                at += 1;
            }
            const cell = &result.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, &db.session, &buffer);
            @memcpy(out[at..][0..text.len], text);
            at += text.len;
        }
    }
    if (!std.mem.eql(u8, out[0..at], expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, out[0..at], expected });
    try check(std.mem.eql(u8, out[0..at], expected));
}

/// Result column `index` has this PostgreSQL type OID and typmod.
fn meta(index: usize, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    if (got_oid != oid or result.column_typmods[index] != typmod)
        std.debug.print("column {d}: got oid {d} typmod {d}, expected {d} {d}\n", .{ index, got_oid, result.column_typmods[index], oid, typmod });
    try check(got_oid == oid and result.column_typmods[index] == typmod);
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    // Statement atomicity: nothing pending after a failed statement.
    try check(db.usage().pending_versions == 0 and db.usage().transactions == 0);
}

/// SQLSTATEs of the errors this contract expects, as src/db/postgres.sig
/// knownSqlstate maps them (test_postgres checks that every engine error is
/// mapped; this pins the exact codes of the B11 type errors).
fn sqlstate(err: anyerror, wanted: []const u8) !void {
    const table = [_]struct { name: []const u8, state: []const u8 }{
        .{ .name = "StringDataRightTruncation", .state = "22001" },
        .{ .name = "StringDataLengthMismatch", .state = "22026" },
        .{ .name = "InvalidTimeZoneDisplacement", .state = "22009" },
        .{ .name = "InvalidTextRepresentation", .state = "22P02" },
        .{ .name = "InvalidParameterValue", .state = "22023" },
        .{ .name = "InvalidDatetimeFormat", .state = "22007" },
        .{ .name = "DatetimeFieldOverflow", .state = "22008" },
        .{ .name = "NumericValueOutOfRange", .state = "22003" },
        .{ .name = "IntegerOverflow", .state = "22003" },
        .{ .name = "AmbiguousFunction", .state = "42725" },
        .{ .name = "DivisionByZero", .state = "22012" },
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
}

fn sendText(cell: *const DB.Cell, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.sendText(cell, &db.session, &out);
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn sendBinary(cell: *const DB.Cell, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.sendBinary(cell, data_type, &db.session, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("binary got {any}\n  expected {any}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn literal(bytes: []const u8, oid: u32, format: u16, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.literal(bytes, oid, format, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("literal got {s}\n  expected {s}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn receive(bytes: []const u8, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const text = try Wire.receiveText(bytes, data_type, &out);
    if (!std.mem.eql(u8, text, expected)) std.debug.print("receive got {s}\n  expected {s}\n", .{ text, expected });
    try check(std.mem.eql(u8, text, expected));
}

/// Replays `statements` from a fresh primary into a replica through kind-3
/// change records and checks both databases answer `query` identically,
/// including result types, typmods and cell tags.
fn replay(statements: []const []const u8, query: []const u8) !void {
    var primary: DB = .{};
    var replica: DB = .{};
    var r: DB.Result = .{};
    var record: [4096]u8 = undefined;
    for (statements) |source| {
        var used: usize = 0;
        primary.executeChanges(source, &r, &record, &used, null, null) catch |err| {
            std.debug.print("replay source failed: {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        try replica.applyChangeRecord(record[0..used], &scratch);
    }
    var expected: DB.Result = .{};
    try primary.execute(query, &expected);
    try replica.execute(query, &result);
    try check(result.row_count == expected.row_count and result.column_count == expected.column_count);
    for (0..result.column_count) |column| {
        try check(result.column_types[column] == expected.column_types[column]);
        try check(result.column_typmods[column] == expected.column_typmods[column]);
    }
    for (0..result.row_count) |index| for (0..result.column_count) |column| {
        const a = &expected.rows[index].cells[column];
        const b = &result.rows[index].cells[column];
        try check(std.meta.activeTag(a.*) == std.meta.activeTag(b.*) and DB.compareCells(a, b) == 0);
        var x: [Io.format_bytes]u8 = undefined;
        var y: [Io.format_bytes]u8 = undefined;
        if (a.* != .null_value) try check(std.mem.eql(u8, try Io.format(a, false, &primary.session, &x), try Io.format(b, false, &replica.session, &y)));
    };
}

// ---- VARCHAR(n) / CHAR(n) / BPCHAR ---------------------------------------

fn character() !void {
    // oracle: PG.TYPE.CHARACTER.
    try exec("CREATE TABLE tdd_type(v VARCHAR(8))");
    try exec("INSERT INTO tdd_type VALUES('abc'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "abc;NULL");
    try meta(0, 1043, 12);
    try exec("DROP TABLE tdd_type");

    // Declarations: VARCHAR(n) typmod n+4, CHAR without length is CHAR(1),
    // BPCHAR and VARCHAR without length have no typmod.
    try exec("CREATE TABLE ch(id INT PRIMARY KEY, v VARCHAR(8), c CHAR(3), b BPCHAR, u CHARACTER VARYING, one CHARACTER, w CHAR VARYING(2))");
    try exec("INSERT INTO ch VALUES(1, 'abc', 'ab', 'x  ', 'free text', 'z', 'ok')");
    try rows("SELECT v, c, b, u, one, w FROM ch", "abc|ab |x  |free text|z|ok");
    try meta(0, 1043, 12);
    try meta(1, 1042, 7);
    try meta(2, 1042, -1);
    try meta(3, 1043, -1);
    try meta(4, 1042, 5);
    try meta(5, 1043, 6);
    try rows("SELECT * FROM ch", "1|abc|ab |x  |free text|z|ok");
    try meta(1, 1043, 12);
    try meta(2, 1042, 7);
    try rows("SELECT atttypmod FROM pg_attribute WHERE attrelid = 'ch'::regclass ORDER BY attnum", "-1;12;7;-1;-1;5;6");
    try rows("SELECT data_type, character_maximum_length FROM information_schema.columns WHERE table_name = 'ch' ORDER BY ordinal_position",
        "integer|NULL;character varying|8;character|3;character|NULL;character varying|NULL;character|1;character varying|2");
    try rows("SELECT format_type(1043, 12), format_type(1042, 7), format_type(1043, -1), 'varchar'::regtype::text, 'char'::regtype::text, 'bpchar'::regtype::text",
        "character varying(8)|character(3)|character varying|character varying|character|character");

    // Assignment: excess characters must be spaces (22001 otherwise); CHAR pads.
    try exec("INSERT INTO ch(id, v, c) VALUES(2, 'abcdefgh   ', 'abc   ')");
    try rows("SELECT v, c FROM ch WHERE id = 2", "abcdefgh|abc");
    try rejects("INSERT INTO ch(id, v) VALUES(3, 'abcdefghi')", error.StringDataRightTruncation);
    try sqlstate(error.StringDataRightTruncation, "22001");
    try rejects("INSERT INTO ch(id, c) VALUES(3, 'abcd')", error.StringDataRightTruncation);
    try rejects("INSERT INTO ch(id, w) VALUES(3, 'abc')", error.StringDataRightTruncation);
    try rejects("INSERT INTO ch(id, one) VALUES(3, 'zz')", error.StringDataRightTruncation);
    // Atomic multi-row INSERT and UPDATE: the failing row undoes the statement.
    try rejects("INSERT INTO ch(id, v) VALUES(3, 'fine'), (4, 'way too long')", error.StringDataRightTruncation);
    try rows("SELECT COUNT(*) FROM ch", "2");
    try rejects("UPDATE ch SET v = v || 'xxxxxx' WHERE id <= 2", error.StringDataRightTruncation);
    try rows("SELECT v FROM ch ORDER BY id", "abc;abcdefgh");
    // Integers assign through their text form (I/O assignment cast).
    try exec("INSERT INTO ch(id, v, c) VALUES(5, 12345, 7)");
    try rows("SELECT v, c FROM ch WHERE id = 5", "12345|7  ");
    try rejects("INSERT INTO ch(id, v) VALUES(6, 123456789)", error.StringDataRightTruncation);
    // Characters, not bytes, are counted (UTF-8).
    try exec("INSERT INTO ch(id, v, c) VALUES(7, '\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6', '\xc3\xa4')");
    try rows("SELECT v, c FROM ch WHERE id = 7", "\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6|\xc3\xa4  ");
    try rejects("INSERT INTO ch(id, v) VALUES(8, '\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc')", error.StringDataRightTruncation);

    // Explicit casts truncate silently; CHAR pads; typed literals.
    try rows("SELECT 'abcdef'::varchar(3), 'ab'::char(4), 'abcdef'::char(3), 'abc  '::varchar(3), CAST('abc' AS CHARACTER VARYING(2))", "abc|ab  |abc|abc|ab");
    try meta(0, 1043, 7);
    try meta(1, 1042, 8);
    try rows("SELECT 'abc'::char, 'abc '::bpchar, 'abc'::character(2), VARCHAR(2) 'xyz', CHAR(2) 'q', 'x'::varchar", "a|abc |ab|xy|q |x");
    try meta(0, 1042, 5);
    try meta(1, 1042, -1);
    try meta(5, 1043, -1);
    try rows("SELECT '\xc3\xa4\xc3\xb6\xc3\xbc'::varchar(2), '\xc3\xa4'::char(2)", "\xc3\xa4\xc3\xb6|\xc3\xa4 ");
    try rows("SELECT NULL::varchar(3), NULL::char(2)", "NULL|NULL");
    try meta(0, 1043, 7);
    try meta(1, 1042, 6);
    try rejects("SELECT 'x'::varchar(0)", error.InvalidParameterValue);
    try sqlstate(error.InvalidParameterValue, "22023");
    try rejects("CREATE TABLE bad(v VARCHAR(0))", error.InvalidParameterValue);
    try rejects("CREATE TABLE bad(c CHAR(10485761))", error.InvalidParameterValue);
    try rejects("CREATE TABLE bad(c CHAR(-1))", error.Syntax);

    // Comparison: CHAR ignores trailing spaces; CHAR to TEXT compares as TEXT
    // (the CHAR side loses its trailing spaces); VARCHAR compares as TEXT.
    try rows("SELECT c = 'ab', c = 'ab   ', c < 'ac', 'ab '::char(3) = 'ab'::char(5), 'a '::char(2) = 'a '::text, 'a'::varchar = 'a'::text, 'b'::varchar > 'a'::text FROM ch WHERE id = 1",
        "t|t|t|t|f|t|t");
    try rows("SELECT id FROM ch WHERE c = 'ab' ORDER BY id", "1");
    try rows("SELECT id FROM ch WHERE v = 'abc' AND c IN ('ab', 'zz')", "1");
    try rows("SELECT 'ab '::char(3)::text || '|', 'ab'::char(3) || 'x', 'ab'::varchar(5) || 'x', v || '!' FROM ch WHERE id = 1", "ab||abx|abx|abc!");
    try meta(0, 25, -1);
    try meta(3, 25, -1);
    try rows("SELECT v::text, c::varchar, c::text, b::text, '42 '::char(4)::int, 12::varchar(1) FROM ch WHERE id = 1", "abc|ab|ab|x|42|1");
    try meta(0, 25, -1);
    try meta(1, 1043, -1);
    try rows("SELECT v LIKE 'ab%', c LIKE 'ab', c LIKE 'ab_', v NOT LIKE 'b%' FROM ch WHERE id = 1", "t|f|t|t");
    try rows("SELECT COALESCE(v, 'none'), COALESCE(NULL::varchar(4), 'dflt') FROM ch WHERE id = 1", "abc|dflt");
    try meta(0, 1043, -1);
    try rows("SELECT MIN(v), MAX(v), MIN(c), MAX(c) FROM ch", "12345|\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6|7  |\xc3\xa4  ");
    try meta(0, 25, -1);
    try meta(2, 1042, -1);

    // Ordering, NULLs and grouping (byte order: PostgreSQL C collation).
    try exec("INSERT INTO ch(id, v, c, b) VALUES(9, NULL, NULL, 'x'), (10, 'Abc', 'b', 'x ')");
    try rows("SELECT v FROM ch ORDER BY v NULLS LAST", "12345;Abc;abc;abcdefgh;\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6\xc3\xbc\xc3\xa4\xc3\xb6;NULL");
    try rows("SELECT c FROM ch ORDER BY c DESC NULLS FIRST", "NULL;\xc3\xa4  ;b  ;abc;ab ;7  ");
    try rows("SELECT COUNT(DISTINCT b), COUNT(b) FROM ch", "1|3");
    try rows("SELECT COUNT(*) FROM ch GROUP BY b ORDER BY 1", "3;3");
    try rows("SELECT a.id, b.id FROM ch a JOIN ch b ON a.b = b.b AND a.id < b.id ORDER BY a.id, b.id", "1|9;1|10;9|10");
    try exec("DROP TABLE ch");

    // Wire: OIDs/typlen, text and binary send, binary receive and parameters.
    try check(Wire.oid(.varchar) == 1043 and Wire.oid(.bpchar) == 1042 and Wire.length(.varchar) == -1 and Wire.length(.bpchar) == -1);
    try exec("SELECT 'ab'::varchar(4), 'ab'::char(4)");
    try sendText(&result.rows[0].cells[0], "ab");
    try sendText(&result.rows[0].cells[1], "ab  ");
    try sendBinary(&result.rows[0].cells[0], .varchar, "ab");
    try sendBinary(&result.rows[0].cells[1], .bpchar, "ab  ");
    try receive("x y", .varchar, "x y");
    try receive("pad ", .bpchar, "pad ");
    try literal("it's", 1043, 0, "'it''s'::varchar");
    try literal("ab ", 1042, 1, "'ab '::bpchar");

    // Durability: committed CHARACTER data and typmods survive replay.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, v VARCHAR(8), c CHAR(3), b BPCHAR)",
        "INSERT INTO r VALUES(1, 'abc', 'ab', 'x  '), (2, NULL, NULL, NULL), (3, '\xc3\xa4\xc3\xb6', 'q', '')",
        "UPDATE r SET v = v || 'de', c = 'z' WHERE id = 1",
        "DELETE FROM r WHERE id = 3",
    }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|abcde|z  |x  ;2|NULL|NULL|NULL");
    try meta(1, 1043, 12);
    try meta(2, 1042, 7);
}

// ---- UUID ------------------------------------------------------------------

fn uuid() !void {
    // oracle: PG.TYPE.UUID.
    try exec("CREATE TABLE tdd_type(v UUID)");
    try exec("INSERT INTO tdd_type VALUES('12345678-1234-1234-1234-123456789abc'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "12345678-1234-1234-1234-123456789abc;NULL");
    try meta(0, 2950, -1);
    try exec("DROP TABLE tdd_type");

    // Every input form uuid_in accepts: case-insensitive hex, optional
    // braces, hyphens after any group of four digits.
    const canonical = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11";
    for ([_][]const u8{
        "SELECT 'A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11'::uuid",
        "SELECT '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}'::uuid",
        "SELECT 'a0eebc999c0b4ef8bb6d6bb9bd380a11'::uuid",
        "SELECT 'a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11'::uuid",
        "SELECT '{a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11}'::uuid",
        "SELECT CAST('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11' AS UUID)",
        "SELECT UUID 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'",
    }) |source| {
        try rows(source, canonical);
        try meta(0, 2950, -1);
    }
    for ([_][]const u8{
        "SELECT 'xyz'::uuid",
        "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1'::uuid",
        "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a111'::uuid",
        "SELECT '{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}'::uuid",
        "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11-'::uuid",
        "SELECT '-a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT 'a0eeb-c99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT 'a0eebc99--9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT ' a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11 '::uuid",
        "SELECT 'g0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
        "SELECT ''::uuid",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    try sqlstate(error.InvalidTextRepresentation, "22P02");

    try exec("CREATE TABLE ids(id UUID PRIMARY KEY, label TEXT, other UUID)");
    try exec("INSERT INTO ids VALUES('ffffffff-ffff-ffff-ffff-ffffffffffff', 'max', NULL), ('00000000-0000-0000-0000-000000000000', 'nil', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'), ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'a', '00000000-0000-0000-0000-000000000001')");
    try rows("SELECT id, label FROM ids ORDER BY id", "00000000-0000-0000-0000-000000000000|nil;a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11|a;ffffffff-ffff-ffff-ffff-ffffffffffff|max");
    try rows("SELECT other FROM ids ORDER BY other DESC NULLS LAST", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11;00000000-0000-0000-0000-000000000001;NULL");
    try rows("SELECT label FROM ids WHERE id = '{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}'", "a");
    try rows("SELECT label FROM ids WHERE id > '80000000-0000-0000-0000-000000000000' ORDER BY id", "a;max");
    try rows("SELECT a.label, b.label FROM ids a JOIN ids b ON a.other = b.id ORDER BY a.label", "nil|a");
    try rows("SELECT COUNT(DISTINCT other), COUNT(*) FROM ids", "2|3");
    try rejects("INSERT INTO ids VALUES('A0EEBC999C0B4EF8BB6D6BB9BD380A11', 'dup', NULL)", error.PrimaryKeyViolation);
    try rejects("INSERT INTO ids(id) VALUES('00000000-0000-0000-0000-00000000000g')", error.InvalidTextRepresentation);
    try rejects("INSERT INTO ids(id, label) VALUES('11111111-1111-1111-1111-111111111111', 'ok'), ('bad', 'no')", error.InvalidTextRepresentation);
    try rows("SELECT COUNT(*) FROM ids", "3");
    // Casts: to text by assignment or explicitly; from text explicitly only.
    try rows("SELECT id::text, CAST(other AS VARCHAR(8)) FROM ids WHERE label = 'nil'", "00000000-0000-0000-0000-000000000000|a0eebc99");
    try meta(0, 25, -1);
    try exec("UPDATE ids SET label = id WHERE label = 'a'");
    try rows("SELECT label FROM ids WHERE id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'", canonical);
    try rows("SELECT label::uuid = id FROM ids WHERE id = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'", "t");
    try rejects("UPDATE ids SET other = label", error.TypeMismatch);
    try rejects("SELECT id = label FROM ids", error.UndefinedFunction);
    try rejects("SELECT 1::uuid", error.CannotCoerce);
    try rows("SELECT NULL::uuid, format_type(2950, NULL), 'uuid'::regtype::text", "NULL|uuid|uuid");
    try meta(0, 2950, -1);
    try exec("DROP TABLE ids");

    // Wire: 16-byte binary form.
    try check(Wire.oid(.uuid) == 2950 and Wire.length(.uuid) == 16);
    try exec("SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid");
    const binary = [_]u8{ 0xa0, 0xee, 0xbc, 0x99, 0x9c, 0x0b, 0x4e, 0xf8, 0xbb, 0x6d, 0x6b, 0xb9, 0xbd, 0x38, 0x0a, 0x11 };
    try sendText(&result.rows[0].cells[0], canonical);
    try sendBinary(&result.rows[0].cells[0], .uuid, &binary);
    try receive(&binary, .uuid, canonical);
    try literal(&binary, 2950, 1, "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid");
    try literal(canonical, 2950, 0, "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(binary[0..15], .uuid, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability.
    try replay(&.{
        "CREATE TABLE r(id UUID PRIMARY KEY, v UUID)",
        "INSERT INTO r VALUES('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', NULL), ('00000000-0000-0000-0000-000000000000', 'ffffffff-ffff-ffff-ffff-ffffffffffff')",
        "UPDATE r SET v = id WHERE v IS NULL",
    }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff;a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11|a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11");
    try meta(0, 2950, -1);
}

// ---- BYTEA -----------------------------------------------------------------

fn bytea() !void {
    // oracle: PG.TYPE.BINARY.
    try exec("CREATE TABLE tdd_type(v BYTEA)");
    try exec("INSERT INTO tdd_type VALUES('\\x00ff'::bytea),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "\\x00ff;NULL");
    try meta(0, 17, -1);
    try exec("DROP TABLE tdd_type");

    // Hex input (whitespace between digit pairs) and escape input; hex output.
    try rows("SELECT '\\x'::bytea, '\\xDEADbeef'::bytea, '\\x de ad\tbe ef '::bytea, 'abc'::bytea, ''::bytea", "\\x|\\xdeadbeef|\\xdeadbeef|\\x616263|\\x");
    try meta(0, 17, -1);
    try rows("SELECT 'a\\\\b'::bytea, '\\001\\377'::bytea, '\\000x'::bytea, CAST('\\x41' AS BYTEA), BYTEA '\\x42'", "\\x615c62|\\x01ff|\\x0078|\\x41|\\x42");
    try rejects("SELECT '\\x0'::bytea", error.InvalidParameterValue);
    try rejects("SELECT '\\x0g'::bytea", error.InvalidParameterValue);
    try rejects("SELECT '\\x0 1'::bytea", error.InvalidParameterValue);
    try sqlstate(error.InvalidParameterValue, "22023");
    try rejects("SELECT '\\X00'::bytea", error.InvalidTextRepresentation);
    try rejects("SELECT '\\400'::bytea", error.InvalidTextRepresentation);
    try rejects("SELECT '\\'::bytea", error.InvalidTextRepresentation);
    try rejects("SELECT 'a\\9'::bytea", error.InvalidTextRepresentation);

    try exec("CREATE TABLE blobs(k BYTEA PRIMARY KEY, label TEXT)");
    try exec("INSERT INTO blobs VALUES('\\xff', 'ff'), ('\\x0000', 'zz'), ('\\x', 'empty'), ('\\x00', 'z'), ('\\x01', 'one')");
    try rows("SELECT label FROM blobs ORDER BY k", "empty;z;zz;one;ff");
    try rows("SELECT label FROM blobs ORDER BY k DESC LIMIT 2", "ff;one");
    try rows("SELECT label FROM blobs WHERE k = '\\x0000'", "zz");
    try rows("SELECT label FROM blobs WHERE k > '\\x00' AND k < '\\xff' ORDER BY k", "zz;one");
    try rows("SELECT COUNT(*) FROM blobs WHERE k IN ('\\x01', '\\xff', '\\x02')", "2");
    try rejects("INSERT INTO blobs VALUES('\\xFF', 'dup')", error.PrimaryKeyViolation);
    try rejects("INSERT INTO blobs VALUES('\\x10', 'ok'), ('\\x1', 'odd')", error.InvalidParameterValue);
    try rows("SELECT COUNT(*) FROM blobs", "5");
    // Concatenation (byteacat) and casts.
    try rows("SELECT '\\x01'::bytea || '\\x0203'::bytea, k || '\\xaa', k || k FROM blobs WHERE label = 'one'", "\\x010203|\\x01aa|\\x0101");
    try meta(0, 17, -1);
    try meta(1, 17, -1);
    try rows("SELECT k::text, CAST(k AS VARCHAR(3)) FROM blobs WHERE label = 'ff'", "\\xff|\\xf");
    try meta(0, 25, -1);
    try exec("UPDATE blobs SET label = k WHERE label = 'one'");
    try rows("SELECT label FROM blobs WHERE k = '\\x01'", "\\x01");
    try rows("SELECT label::bytea = k FROM blobs WHERE k = '\\x01'", "t");
    try rejects("UPDATE blobs SET k = label", error.TypeMismatch);
    try rejects("SELECT k = label FROM blobs", error.UndefinedFunction);
    try rejects("SELECT 1::bytea", error.CannotCoerce);
    try rows("SELECT NULL::bytea, NULL::bytea || '\\x01', format_type(17, NULL), 'bytea'::regtype::text", "NULL|NULL|bytea|bytea");
    try exec("DROP TABLE blobs");

    // Capacity: values are bounded by Config.text_bytes (54000 beyond).
    var hex: [98]u8 = undefined;
    @memcpy(hex[0..2], "\\x");
    for (0..48) |index| @memcpy(hex[2 + index * 2 ..][0..2], "ab");
    var source: [400]u8 = undefined;
    const twice = try std.fmt.bufPrint(&source, "SELECT '{s}'::bytea || '{s}'::bytea", .{ hex, hex });
    try exec(twice);
    try check(result.rows[0].cells[0] == .bytea and result.rows[0].cells[0].bytea.len == 96);
    const thrice = try std.fmt.bufPrint(&source, "SELECT '{s}'::bytea || '{s}'::bytea || '{s}'::bytea", .{ hex, hex, hex });
    try rejects(thrice, error.TextCapacity);

    // Wire: raw bytes in binary, hex in text and in received COPY text.
    try check(Wire.oid(.bytea) == 17 and Wire.length(.bytea) == -1);
    try exec("SELECT '\\x00ff5c27'::bytea");
    try sendText(&result.rows[0].cells[0], "\\x00ff5c27");
    try sendBinary(&result.rows[0].cells[0], .bytea, "\x00\xff\\'");
    try receive("\x00\xff\\'", .bytea, "\\x00ff5c27");
    try receive("", .bytea, "\\x");
    try literal("\x00\xff", 17, 1, "'\\x00ff'::bytea");
    try literal("\\x00ff", 17, 0, "'\\x00ff'::bytea");

    // Durability.
    try replay(&.{
        "CREATE TABLE r(k BYTEA PRIMARY KEY, v BYTEA)",
        "INSERT INTO r VALUES('\\x00ff', NULL), ('\\x', '\\x5c00'), ('\\x01', 'abc')",
        "UPDATE r SET v = k || '\\x02' WHERE v IS NULL",
        "DELETE FROM r WHERE k = '\\x01'",
    }, "SELECT * FROM r ORDER BY k");
    try shown("replica", "\\x|\\x5c00;\\x00ff|\\x00ff02");
    try meta(1, 17, -1);
}

// ---- TIME / TIMETZ -----------------------------------------------------------

fn time() !void {
    // oracle: PG.TYPE.TIME.
    try exec("CREATE TABLE tdd_type(v TIME)");
    try exec("INSERT INTO tdd_type VALUES(TIME '12:34:56'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "12:34:56;NULL");
    try meta(0, 1083, -1);
    try exec("DROP TABLE tdd_type");

    // Input forms (DecodeTimeOnly subset); TIME ignores a zone.
    try rows("SELECT '04:05:06.789'::time, '04:05'::time, '040506'::time, '04:05 PM'::time, '12:00 AM'::time, '12:30 pm'::time",
        "04:05:06.789|04:05:00|04:05:06|16:05:00|00:00:00|12:30:00");
    try rows("SELECT '04:05:06-08:00'::time, '2003-04-12 04:05:06'::time, 'allballs'::time, '24:00:00'::time, '23:59:60'::time, ' 1:02:03 '::time",
        "04:05:06|04:05:06|00:00:00|24:00:00|24:00:00|01:02:03");
    try rows("SELECT '12:34:56.1234567'::time, '00:00:00.0000004'::time, CAST('7:08' AS TIME WITHOUT TIME ZONE), TIME WITHOUT TIME ZONE '09:10'", "12:34:56.123457|00:00:00|07:08:00|09:10:00");
    try meta(2, 1083, -1);
    // Multiword type names before a literal are not a column with an alias.
    try rows("SELECT TIMESTAMP WITHOUT TIME ZONE '2026-01-01', CHARACTER VARYING 'xy', DOUBLE PRECISION '1.5'", "2026-01-01 00:00:00|xy|1.5");
    try rejects("SELECT '25:00'::time", error.DatetimeFieldOverflow);
    try sqlstate(error.DatetimeFieldOverflow, "22008");
    try rejects("SELECT '24:00:01'::time", error.DatetimeFieldOverflow);
    try rejects("SELECT '12:60'::time", error.DatetimeFieldOverflow);
    try rejects("SELECT '13:00 PM'::time", error.DatetimeFieldOverflow);
    try rejects("SELECT 'abc'::time", error.InvalidDatetimeFormat);
    try sqlstate(error.InvalidDatetimeFormat, "22007");
    try rejects("SELECT ''::time", error.InvalidDatetimeFormat);
    try rejects("SELECT '12:34:56 xyz!'::time", error.InvalidDatetimeFormat);

    // TIME(p): typmod p, half-up rounding; precision above 6 is 6.
    try rows("SELECT '12:34:56.789'::time(1), '23:59:59.9'::time(0), TIME(2) '01:02:03.456', '01:02:03.4'::time(7)", "12:34:56.8|24:00:00|01:02:03.46|01:02:03.4");
    try meta(0, 1083, 1);
    try meta(1, 1083, 0);
    try meta(2, 1083, 2);
    try meta(3, 1083, 6);

    try exec("CREATE TABLE times(id INT PRIMARY KEY, t TIME, p TIME(3), z TIMETZ, ts TIMESTAMP)");
    try exec("INSERT INTO times VALUES(1, '23:00', '10:00:00.12345', '12:00+01', '2026-01-02 03:04:05.5'), (2, '01:00', NULL, '11:00+00', NULL), (3, NULL, '00:00:00.0005', NULL, NULL), (4, '12:00', '23:59:59.9999', '12:00-01', 'infinity')");
    try rows("SELECT t FROM times ORDER BY t NULLS LAST", "01:00:00;12:00:00;23:00:00;NULL");
    try rows("SELECT p FROM times ORDER BY id", "10:00:00.123;NULL;00:00:00.001;24:00:00");
    try meta(0, 1083, 3);
    try rows("SELECT id FROM times WHERE t > '11:59' ORDER BY id", "1;4");
    try rows("SELECT id FROM times WHERE t BETWEEN '00:30' AND '12:00' ORDER BY id", "2;4");
    try rows("SELECT MIN(t), MAX(t), MIN(z), MAX(z), COUNT(DISTINCT t) FROM times", "01:00:00|23:00:00|12:00:00+01|12:00:00-01|3");
    try meta(0, 1083, -1);
    try meta(2, 1266, -1);
    try rejects("INSERT INTO times(id, t) VALUES(5, '10:00'), (6, '99:00')", error.DatetimeFieldOverflow);
    try rows("SELECT COUNT(*) FROM times", "4");
    // Assignment from TIMESTAMP keeps the time of day; infinity gives NULL.
    try exec("UPDATE times SET t = ts WHERE ts IS NOT NULL");
    try rows("SELECT t FROM times WHERE id IN (1, 4) ORDER BY id", "03:04:05.5;NULL");

    // Operators.
    try rows("SELECT TIME '12:00' - TIME '10:30', TIME '23:00' + INTERVAL '2 hours', TIME '01:00' - INTERVAL '2 hours', INTERVAL '1 hour' + TIME '10:00', TIME '10:00' - '09:00'",
        "01:30:00|01:00:00|23:00:00|11:00:00|01:00:00");
    try meta(0, 1186, -1);
    try meta(1, 1083, -1);
    try rows("SELECT DATE '2026-01-02' + TIME '03:04:05', TIME '03:04:05' + DATE '2026-01-02', DATE 'infinity' + TIME '01:00'", "2026-01-02 03:04:05|2026-01-02 03:04:05|infinity");
    try meta(0, 1114, -1);
    try rejects("SELECT TIME '10:00' + '1 hour'", error.AmbiguousFunction);
    try rejects("SELECT TIME '10:00' + TIME '01:00'", error.UndefinedFunction);
    try rejects("SELECT TIME '10:00' * 2", error.UndefinedFunction);
    // Casts.
    try rows("SELECT TIME '12:34:56'::text, TIMESTAMP '2026-01-02 03:04:05.5'::time, 'infinity'::timestamp::time, TIME '01:02:03'::interval, INTERVAL '1 day 02:00'::time, INTERVAL '-1 hour'::time",
        "12:34:56|03:04:05.5|NULL|01:02:03|02:00:00|23:00:00");
    try meta(3, 1186, -1);
    try rejects("SELECT TIME '10:00' = '10:00'::text", error.UndefinedFunction);
    try rejects("SELECT 1::time", error.CannotCoerce);
    try rows("SELECT NULL::time, format_type(1083, 3), format_type(1266, -1), 'time'::regtype::text, 'timetz'::regtype::text",
        "NULL|time(3) without time zone|time with time zone|time without time zone|time with time zone");
    try rows("SELECT data_type, datetime_precision FROM information_schema.columns WHERE table_name = 'times' AND column_name IN ('t', 'p', 'z') ORDER BY ordinal_position",
        "time without time zone|6;time without time zone|3;time with time zone|6");

    // TIMETZ: zone kept and printed, east positive; the session zone (UTC
    // here) fills a missing one. Order is UTC-equivalent time, then zone.
    try rows("SELECT '12:34:56+05:30'::timetz, '12:34:56-08'::timetz, '12:34:56'::timetz, '12:34:56 UTC'::timetz, '01:02:03.5+01:02:03'::timetz, TIME WITH TIME ZONE '01:00+02'",
        "12:34:56+05:30|12:34:56-08|12:34:56+00|12:34:56+00|01:02:03.5+01:02:03|01:00:00+02");
    try meta(0, 1266, -1);
    try rows("SELECT '12:00+01'::timetz = '11:00+00'::timetz, '12:00+01'::timetz < '11:00+00'::timetz, '12:00+01'::timetz = '12:00+01:00'::timetz, '10:00'::timetz(0) > '09:00+00'",
        "f|t|t|t");
    try rows("SELECT z FROM times ORDER BY z NULLS FIRST", "NULL;12:00:00+01;11:00:00+00;12:00:00-01");
    try rows("SELECT TIME '10:00'::timetz, '10:00+05'::timetz::time, TIMESTAMPTZ '2026-01-02 03:04:05+00'::timetz, '23:30+02'::timetz + INTERVAL '1 hour', '12:34:56.789+01'::timetz(1)",
        "10:00:00+00|10:00:00|03:04:05+00|00:30:00+02|12:34:56.8+01");
    try meta(4, 1266, 1);
    try rows("SELECT DATE '2026-01-02' + '03:00+02'::timetz", "2026-01-02 01:00:00+00");
    try meta(0, 1184, -1);
    try rejects("SELECT '12:00+16'::timetz", error.InvalidTimeZoneDisplacement);
    try sqlstate(error.InvalidTimeZoneDisplacement, "22009");
    try rejects("SELECT '12:00+05:60'::timetz", error.InvalidTimeZoneDisplacement);
    try exec("DROP TABLE times");

    // Wire: TIME is i64 microseconds; TIMETZ adds i32 seconds west of UTC.
    try check(Wire.oid(.time) == 1083 and Wire.length(.time) == 8 and Wire.oid(.timetz) == 1266 and Wire.length(.timetz) == 12);
    try exec("SELECT '12:34:56'::time, '12:34:56+05:30'::timetz");
    const time_bytes = [_]u8{ 0, 0, 0, 0x0a, 0x8b, 0xda, 0x1c, 0x00 };
    const timetz_bytes = time_bytes ++ [_]u8{ 0xff, 0xff, 0xb2, 0xa8 };
    try sendText(&result.rows[0].cells[0], "12:34:56");
    try sendBinary(&result.rows[0].cells[0], .time, &time_bytes);
    try sendText(&result.rows[0].cells[1], "12:34:56+05:30");
    try sendBinary(&result.rows[0].cells[1], .timetz, &timetz_bytes);
    try receive(&time_bytes, .time, "12:34:56");
    try receive(&timetz_bytes, .timetz, "12:34:56+05:30");
    try literal(&time_bytes, 1083, 1, "'12:34:56'::time");
    try literal(&timetz_bytes, 1266, 1, "'12:34:56+05:30'::timetz");
    var out: [64]u8 = undefined;
    const late = [_]u8{ 0, 0, 0, 0x14, 0x1d, 0xd7, 0x60, 0x01 };
    try check(if (Wire.receiveText(&late, .time, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(time_bytes[0..7], .time, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, t TIME, p TIME(2), z TIMETZ(3))",
        "INSERT INTO r VALUES(1, '12:34:56', '01:02:03.456', '04:05:06.7891-07:30'), (2, NULL, '24:00', NULL)",
        "UPDATE r SET t = t + INTERVAL '1 minute' WHERE id = 1",
    }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|12:35:56|01:02:03.46|04:05:06.789-07:30;2|NULL|24:00:00|NULL");
    try meta(2, 1083, 2);
    try meta(3, 1266, 3);
}

// ---- BIT / BIT VARYING -------------------------------------------------------

fn bit() !void {
    // oracle: PG.TYPE.BIT.
    try exec("CREATE TABLE tdd_type(v BIT(3))");
    try exec("INSERT INTO tdd_type VALUES(B'101'),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "101;NULL");
    try meta(0, 1560, 3);
    try exec("DROP TABLE tdd_type");

    // Bit-string constants are BIT without a typmod.
    try rows("SELECT B'101', b'0', B''", "101|0|");
    try meta(0, 1560, -1);
    // Explicit casts pad/truncate BIT(n) and truncate BIT VARYING(n);
    // input takes binary digits or, after an x, hex digits.
    try rows("SELECT '101'::bit(3), '1'::bit(3), '10101'::bit(3), '101'::bit, '1'::varbit(3), '10101'::varbit(3)", "101|100|101|1|1|101");
    try meta(0, 1560, 3);
    try meta(3, 1560, 1);
    try meta(4, 1562, 3);
    try rows("SELECT 'x1F'::bit(8), 'X1f'::varbit, 'b101'::bit(3)", "00011111|00011111|101");
    try meta(1, 1562, -1);
    try rows("SELECT CAST(B'1' AS BIT VARYING(4)), BIT(2) '10', BIT VARYING '0110', VARBIT(2) '1'", "1|10|0110|1");
    try meta(0, 1562, 4);
    try meta(1, 1560, 2);
    try rejects("SELECT '102'::bit(3)", error.InvalidTextRepresentation);
    try rejects("SELECT 'xg'::bit(4)", error.InvalidTextRepresentation);
    try rejects("SELECT ' 101'::varbit", error.InvalidTextRepresentation);
    try rejects("SELECT B'12'", error.InvalidTextRepresentation);
    try rejects("SELECT '1'::bit(0)", error.InvalidParameterValue);
    try rejects("CREATE TABLE bad(v VARBIT(0))", error.InvalidParameterValue);

    try exec("CREATE TABLE bits(id INT PRIMARY KEY, f BIT(3), v VARBIT(3), u BIT VARYING)");
    try exec("INSERT INTO bits VALUES(1, B'101', B'1', B'1000'), (2, '011', '', '1'), (3, NULL, B'111', B'0'), (4, B'111', NULL, NULL)");
    try rows("SELECT f, v, u FROM bits ORDER BY id", "101|1|1000;011||1;NULL|111|0;111|NULL|NULL");
    try meta(0, 1560, 3);
    try meta(1, 1562, 3);
    try meta(2, 1562, -1);
    // Assignment: BIT(n) needs exactly n bits (22026); VARBIT(n) at most n (22001).
    try rejects("INSERT INTO bits(id, f) VALUES(5, B'10')", error.StringDataLengthMismatch);
    try sqlstate(error.StringDataLengthMismatch, "22026");
    try rejects("INSERT INTO bits(id, f) VALUES(5, B'1010')", error.StringDataLengthMismatch);
    try rejects("INSERT INTO bits(id, f) VALUES(5, '11')", error.StringDataLengthMismatch);
    try rejects("INSERT INTO bits(id, v) VALUES(5, B'1010')", error.StringDataRightTruncation);
    try rejects("INSERT INTO bits(id, f) VALUES(5, B'111'), (6, B'1')", error.StringDataLengthMismatch);
    try rejects("UPDATE bits SET v = u", error.StringDataRightTruncation);
    try rows("SELECT COUNT(*), COUNT(v) FROM bits", "4|3");
    try exec("UPDATE bits SET u = f WHERE id = 4");
    try rows("SELECT u FROM bits WHERE id = 4", "111");
    // bit_cmp ordering: common bytes, then the shorter string first.
    try rows("SELECT u FROM bits ORDER BY u", "0;1;1000;111");
    try rows("SELECT v FROM bits ORDER BY v DESC NULLS FIRST", "NULL;111;1;");
    try rows("SELECT id FROM bits WHERE f = B'101' OR v = '111' ORDER BY id", "1;3");
    try rows("SELECT B'101' = B'101', B'10' < B'101', B'11' > B'101', B'0' < B'1', B'1' < B'1000', B'101' = '101'::varbit, B'1' <> B'10'", "t|t|t|t|t|t|t");
    try rows("SELECT COUNT(DISTINCT u) FROM bits", "4");
    // Integer casts (explicit only).
    try rows("SELECT B'101'::int4, B'11111111111111111111111111111111'::int4, 5::bit(3), (-1)::bit(4), 5::bigint::bit(4), B'101'::bigint, (-2)::bit(36)",
        "5|-1|101|1111|0101|5|111111111111111111111111111111111110");
    try meta(0, 23, -1);
    try meta(2, 1560, 3);
    try rejects("SELECT B'111111111111111111111111111111111'::int4", error.IntegerOverflow);
    try sqlstate(error.IntegerOverflow, "22003");
    try rejects("SELECT 1.5::bit", error.CannotCoerce);
    try rejects("SELECT 1::smallint::bit(2)", error.CannotCoerce);
    try rejects("SELECT B'1'::int4 + B'1'", error.UndefinedFunction);
    try rejects("SELECT B'1'::varbit::int4", error.CannotCoerce);
    // Text casts and type names.
    try rows("SELECT B'101'::text, CAST(f AS VARCHAR(2)), f::varbit FROM bits WHERE id = 1", "101|10|101");
    try meta(0, 25, -1);
    try rejects("SELECT f = '101'::text FROM bits", error.UndefinedFunction);
    try rows("SELECT NULL::bit(2), format_type(1560, 3), format_type(1562, 5), format_type(1562, -1), 'varbit'::regtype::text, 'bit'::regtype::text",
        "NULL|bit(3)|bit varying(5)|bit varying|bit varying|bit");
    try rows("SELECT data_type, character_maximum_length FROM information_schema.columns WHERE table_name = 'bits' AND column_name <> 'id' ORDER BY ordinal_position",
        "bit|3;bit varying|3;bit varying|NULL");
    try exec("DROP TABLE bits");
    // Capacity: Config.text_bytes * 8 bits per value.
    try exec("SELECT 5::bit(1024)");
    try check(result.rows[0].cells[0] == .bits and result.rows[0].cells[0].bits.len == 1024);
    try rejects("SELECT 5::bit(1025)", error.TextCapacity);

    // Wire: i32 bit length then the packed bits (zero padded).
    try check(Wire.oid(.bit) == 1560 and Wire.oid(.varbit) == 1562 and Wire.length(.bit) == -1 and Wire.length(.varbit) == -1);
    try exec("SELECT B'101', '1000000011'::varbit");
    try sendText(&result.rows[0].cells[0], "101");
    try sendBinary(&result.rows[0].cells[0], .bit, &.{ 0, 0, 0, 3, 0xa0 });
    try sendBinary(&result.rows[0].cells[1], .varbit, &.{ 0, 0, 0, 10, 0x80, 0xc0 });
    try receive(&.{ 0, 0, 0, 3, 0xbf }, .bit, "101");
    try receive(&.{ 0, 0, 0, 0 }, .varbit, "");
    try literal(&.{ 0, 0, 0, 3, 0xa0 }, 1560, 1, "'101'::varbit");
    try literal(&.{ 0, 0, 0, 2, 0x40 }, 1562, 1, "'01'::varbit");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 9, 0xff }, .varbit, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0xff, 0xff, 0xff, 0xff }, .varbit, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, f BIT(3), v VARBIT(12))",
        "INSERT INTO r VALUES(1, B'101', '100000001'), (2, NULL, ''), (3, '000', NULL)",
        "UPDATE r SET v = f WHERE id = 3",
    }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|101|100000001;2|NULL|;3|000|000");
    try meta(1, 1560, 3);
    try meta(2, 1562, 12);
}

// ---- MONEY -------------------------------------------------------------------

fn moneyType() !void {
    // oracle: PG.TYPE.MONEY (lc_monetary = C).
    try exec("CREATE TABLE tdd_type(v MONEY)");
    try exec("INSERT INTO tdd_type VALUES(1),(NULL)");
    try rows("SELECT v FROM tdd_type ORDER BY v NULLS LAST", "$1.00;NULL");
    try meta(0, 790, -1);
    try exec("DROP TABLE tdd_type");

    // cash_in forms: symbol, separators, signs, parentheses, rounding of a
    // third fraction digit.
    try rows("SELECT '12.34'::money, '$1,234.5'::money, '-$1.00'::money, '(2.50)'::money, '12.345'::money, '12.344'::money, ' 7 '::money, '1000000'::money",
        "$12.34|$1,234.50|-$1.00|-$2.50|$12.35|$12.34|$7.00|$1,000,000.00");
    try meta(0, 790, -1);
    try rows("SELECT '0.001'::money, '-0.005'::money, '0.005'::money, '+$3'::money, '$-4'::money, '5-'::money, MONEY '6.1'",
        "$0.00|-$0.01|$0.01|$3.00|-$4.00|-$5.00|$6.10");
    try rows("SELECT '92233720368547758.07'::money, '-92233720368547758.08'::money", "$92,233,720,368,547,758.07|-$92,233,720,368,547,758.08");
    try rejects("SELECT '92233720368547758.08'::money", error.NumericValueOutOfRange);
    try sqlstate(error.NumericValueOutOfRange, "22003");
    try rejects("SELECT '100000000000000000000'::money", error.NumericValueOutOfRange);
    try rejects("SELECT 'abc'::money", error.InvalidTextRepresentation);
    try rejects("SELECT '1.2.3'::money", error.InvalidTextRepresentation);
    try rejects("SELECT '12 34'::money", error.InvalidTextRepresentation);

    // Casts: int4/int8/numeric -> money by assignment; money -> numeric;
    // text by I/O; no float casts.
    try rows("SELECT 1::money, 12345678901::bigint::money, 1.555::money, '1.5'::money::numeric, (-2.5)::money::numeric, '1'::money::text",
        "$1.00|$12,345,678,901.00|$1.56|1.50|-2.50|$1.00");
    try meta(3, 1700, -1);
    try meta(5, 25, -1);
    try rejects("SELECT 100000000000000000::bigint::money", error.NumericValueOutOfRange);
    try rejects("SELECT 1.5::float8::money", error.CannotCoerce);
    try rejects("SELECT '1'::money::float8", error.CannotCoerce);
    try rejects("SELECT '1'::money::int4", error.CannotCoerce);

    // Operators.
    try rows("SELECT '1.50'::money + '2.25'::money, '5'::money - '7.5'::money, '1.50'::money * 2, 2 * '1.50'::money, '1'::money * 1.5, '10'::money / 4, '10'::money / 3, '-10'::money / 3",
        "$3.75|-$2.50|$3.00|$3.00|$1.50|$2.50|$3.33|-$3.33");
    try meta(0, 790, -1);
    try meta(4, 790, -1);
    try rows("SELECT '10'::money / 4.0, '10'::money / '4'::money, '0.03'::money * 0.5, '0.05'::money * 0.5, '1'::money + '2'", "$2.50|2.5|$0.02|$0.02|$3.00");
    try meta(1, 701, -1);
    try rejects("SELECT '1'::money / 0", error.DivisionByZero);
    try sqlstate(error.DivisionByZero, "22012");
    try rejects("SELECT '1'::money / '0'::money", error.DivisionByZero);
    try rejects("SELECT '1'::money / 0.0", error.DivisionByZero);
    try rejects("SELECT '92233720368547758.07'::money + '0.01'::money", error.NumericValueOutOfRange);
    try rejects("SELECT '92233720368547758.07'::money * 2", error.NumericValueOutOfRange);
    try rejects("SELECT '1'::money + 1", error.UndefinedFunction);
    try rejects("SELECT '1'::money = 1", error.UndefinedFunction);
    try rejects("SELECT '1'::money * '2'::money", error.UndefinedFunction);

    try exec("CREATE TABLE cash(id INT PRIMARY KEY, amount MONEY NOT NULL, fee MONEY)");
    try exec("INSERT INTO cash VALUES(1, '12.50', NULL), (2, 3, '0.25'), (3, -1.005, '1'), (4, '$1,000', '0.25')");
    try rows("SELECT amount FROM cash ORDER BY amount", "-$1.01;$3.00;$12.50;$1,000.00");
    try rows("SELECT id FROM cash WHERE amount > '2.99' AND fee = '0.25' ORDER BY id", "2;4");
    try rows("SELECT SUM(amount), MIN(amount), MAX(fee), COUNT(DISTINCT fee), SUM(fee) FROM cash", "$1,014.49|-$1.01|$1.00|2|$1.50");
    try meta(0, 790, -1);
    try meta(1, 790, -1);
    try rows("SELECT amount + COALESCE(fee, '0') FROM cash ORDER BY id", "$12.50;$3.25;-$0.01;$1,000.25");
    try rejects("INSERT INTO cash VALUES(5, 'oops', NULL)", error.InvalidTextRepresentation);
    try rejects("INSERT INTO cash VALUES(5, 1, NULL), (6, NULL, NULL)", error.NotNullViolation);
    try rejects("UPDATE cash SET amount = amount * 100000000000000", error.NumericValueOutOfRange);
    try rows("SELECT COUNT(*), SUM(amount) FROM cash", "4|$1,014.49");
    try rejects("INSERT INTO cash VALUES(5, 1.5::float8, NULL)", error.TypeMismatch);
    try rows("SELECT NULL::money, format_type(790, NULL), 'money'::regtype::text", "NULL|money|money");
    try rows("SELECT data_type, numeric_precision FROM information_schema.columns WHERE table_name = 'cash' AND column_name = 'fee'", "money|NULL");
    try exec("DROP TABLE cash");

    // Wire: i64 cents.
    try check(Wire.oid(.money) == 790 and Wire.length(.money) == 8);
    try exec("SELECT '-1234.56'::money");
    try sendText(&result.rows[0].cells[0], "-$1,234.56");
    try sendBinary(&result.rows[0].cells[0], .money, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0x1d, 0xc0 });
    try receive(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0x1d, 0xc0 }, .money, "-$1,234.56");
    try literal(&.{ 0, 0, 0, 0, 0, 0, 0, 100 }, 790, 1, "'$1.00'::money");
    try literal("$1,000.00", 790, 0, "'$1,000.00'::money");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 1 }, .money, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, m MONEY)",
        "INSERT INTO r VALUES(1, '12.34'), (2, NULL), (3, '-92233720368547758.08')",
        "UPDATE r SET m = m * 2 WHERE id = 1",
    }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|$24.68;2|NULL;3|-$92,233,720,368,547,758.08");
    try meta(1, 790, -1);
}

// ---- TIME/TIMETZ with session zones and zone names ---------------------------

/// A caller zone provider that knows one fixed-offset name.
fn testZone(context: ?*anyopaque, name: []const u8, zone: *sql.temporal.Zone) sql.Error!void {
    _ = context;
    if (!std.mem.eql(u8, name, "Test/Plus2")) return error.InvalidParameterValue;
    zone.* = .{ .kind = .fixed, .offset = 7200 };
}

fn timeZones() !void {
    db.session.resolver = .{ .lookup = &testZone };
    defer db.session.resolver = .{};
    try rows("SELECT '12:00 Test/Plus2'::timetz, '12:00 Test/Plus2'::time, '2026-07-01 12:00 Test/Plus2'::timetz", "12:00:00+02|12:00:00|12:00:00+02");
    try rejects("SELECT '12:00 Nowhere/Zone'::time", error.InvalidParameterValue);
    try rejects("SELECT '12:00 Nowhere/Zone'::timetz", error.InvalidParameterValue);
    // A date far beyond the timestamp range has no offset: 22008, no overflow.
    try rejects("SELECT '999999999-01-01 12:00 Test/Plus2'::timetz", error.DatetimeFieldOverflow);
    // Without a zone in the input, TIMETZ takes the session zone's offset.
    db.session.zone = .{ .kind = .fixed, .offset = 5 * 3600 + 1800 };
    defer db.session.zone = .{};
    try rows("SELECT '12:00'::timetz, TIME '10:00'::timetz, TIMESTAMPTZ '2026-01-02 03:04:05+00'::timetz, TIMESTAMPTZ '2026-01-02 23:00:00+00'::time",
        "12:00:00+05:30|10:00:00+05:30|08:34:05+05:30|04:30:00");
}

pub fn main(init: std.process.Init) !void {
    try character();
    try uuid();
    try bytea();
    try time();
    try bit();
    try moneyType();
    try timeZones();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-core\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
