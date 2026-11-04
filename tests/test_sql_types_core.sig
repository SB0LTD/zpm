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

fn sqlstate(err: anyerror, wanted: []const u8) !void {
    // Exact SQLSTATE mapping used by the PostgreSQL codec.
    const name = @errorName(err);
    const state: []const u8 = if (std.mem.eql(u8, name, "StringDataRightTruncation")) "22001" else if (std.mem.eql(u8, name, "StringDataLengthMismatch")) "22026" else if (std.mem.eql(u8, name, "InvalidTextRepresentation")) "22P02" else if (std.mem.eql(u8, name, "InvalidParameterValue")) "22023" else if (std.mem.eql(u8, name, "InvalidDatetimeFormat")) "22007" else if (std.mem.eql(u8, name, "DatetimeFieldOverflow")) "22008" else if (std.mem.eql(u8, name, "NumericValueOutOfRange")) "22003" else "?";
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

pub fn main(init: std.process.Init) !void {
    try character();
    try uuid();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-core\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
