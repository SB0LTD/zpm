//! Extended PostgreSQL type contract (conformance lane B11 wave 4
//! "types-ext"): the void pseudo-type and the void-returning session
//! functions (blocking advisory locks, pg_notify), the remaining array
//! functions and forms (unnest, ARRAY(subquery), element and slice
//! assignment, array_agg/string_agg windows), multiranges, the remaining
//! geometric types, macaddr8 and inet arithmetic, and XML (XPath, XMLTABLE
//! and the publishing functions).
//!
//! Every section checks exact values and result metadata (type OID,
//! typmod), NULLs, rejected input with its exact error (SQLSTATE),
//! statement atomicity and, for storable types, change-record replay
//! compared with sameDatabase/sameCatalog. Expected values were checked
//! against native PostgreSQL 18.7.
const std = @import("std");
const sql = @import("sql");
const pg_types = @import("pg_types");

const DB = sql.Database(.{ .tables = 4, .columns = 12, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 256, .integer_bits = 32, .nulls_first_ascending = false, .work_rows = 128, .result_rows = 48, .transactions = 4 });
const Io = DB.Io;
const Wire = pg_types.Types(DB.Result);
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};
var session_a: DB.SessionState = .{};
var session_b: DB.SessionState = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("types-ext contract failed at assertion {d}\n", .{assertions});
        return error.SqlTypesExtContractFailed;
    }
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

var shown_buffer: [8192]u8 = undefined;

/// The rows of `target`, columns joined by '|' and rows by ';' (NULL as NULL).
fn render(target: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    for (0..target.row_count) |index| {
        if (index != 0) {
            shown_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                shown_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, &db.session, &buffer);
            @memcpy(shown_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return shown_buffer[0..at];
}

/// Every row of a query, columns joined by '|' and rows by ';' (NULL as NULL).
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

fn shown(source: []const u8, expected: []const u8) !void {
    const got = try render(&result);
    if (!std.mem.eql(u8, got, expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, got, expected });
    try check(std.mem.eql(u8, got, expected));
}

/// Result column `index` has this PostgreSQL type OID and typmod.
fn meta(index: usize, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    if (got_oid != oid or result.column_typmods[index] != typmod)
        std.debug.print("column {d}: got oid {d} typmod {d}, expected {d} {d}\n", .{ index, got_oid, result.column_typmods[index], oid, typmod });
    try check(got_oid == oid and result.column_typmods[index] == typmod);
}

/// Result column `index` is named `name`.
fn named(index: usize, name: []const u8) !void {
    const got = result.column_names[index].slice();
    if (!std.mem.eql(u8, got, name)) std.debug.print("column {d}: named {s}, expected {s}\n", .{ index, got, name });
    try check(std.mem.eql(u8, got, name));
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
/// knownSqlstate maps them (test_postgres checks every engine error is
/// mapped; this pins the exact codes).
fn sqlstate(err: anyerror, wanted: []const u8) !void {
    const table = [_]struct { name: []const u8, state: []const u8 }{
        .{ .name = "InvalidTextRepresentation", .state = "22P02" },
        .{ .name = "InvalidParameterValue", .state = "22023" },
        .{ .name = "NumericValueOutOfRange", .state = "22003" },
        .{ .name = "UndefinedFunction", .state = "42883" },
        .{ .name = "UndefinedObject", .state = "42704" },
        .{ .name = "CannotCoerce", .state = "42846" },
        .{ .name = "TypeMismatch", .state = "42804" },
        .{ .name = "UnsupportedStatement", .state = "0A000" },
        .{ .name = "InvalidTableDefinition", .state = "42P16" },
        .{ .name = "TextCapacity", .state = "54000" },
        .{ .name = "ArraySubscriptError", .state = "2202E" },
        .{ .name = "DataException", .state = "22000" },
        .{ .name = "InvalidXmlContent", .state = "2200N" },
        .{ .name = "InvalidXmlDocument", .state = "2200M" },
        .{ .name = "NotAnXmlDocument", .state = "2200L" },
        .{ .name = "NullValueNotAllowed", .state = "22004" },
        .{ .name = "AmbiguousFunction", .state = "42725" },
        .{ .name = "Syntax", .state = "42601" },
        .{ .name = "StringDataRightTruncation", .state = "22001" },
        .{ .name = "ProgramLimitExceeded", .state = "54000" },
        .{ .name = "DivisionByZero", .state = "22012" },
        .{ .name = "WrongObjectType", .state = "42809" },
        .{ .name = "InvalidBinaryRepresentation", .state = "22P03" },
        .{ .name = "DatetimeFieldOverflow", .state = "22008" },
        .{ .name = "InvalidXmlProcessingInstruction", .state = "2200T" },
        .{ .name = "InvalidXmlComment", .state = "2200S" },
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
}

// ---- replay ------------------------------------------------------------------

fn sameResult(a: *const DB.Result, b: *const DB.Result, a_db: *DB, b_db: *DB) !bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or a.column_typmods[column] != b.column_typmods[column] or
            !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |index| for (0..a.column_count) |column| {
        const x = &a.rows[index].cells[column];
        const y = &b.rows[index].cells[column];
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*) or DB.compareCells(x, y) != 0) return false;
        if (x.* == .null_value) continue;
        var p: [Io.format_bytes]u8 = undefined;
        var q: [Io.format_bytes]u8 = undefined;
        if (!std.mem.eql(u8, try Io.format(x, false, &a_db.session, &p), try Io.format(y, false, &b_db.session, &q))) return false;
    };
    return true;
}

fn sameQuery(a: *DB, b: *DB, source: []const u8) !bool {
    var x: DB.Result = .{};
    var y: DB.Result = .{};
    try a.execute(source, &x);
    try b.execute(source, &y);
    return sameResult(&x, &y, a, b);
}

/// Table count, OID counter, live rows, next rowids and every row (scan
/// order, cell tags, btree equality and text form) of `tables`.
fn sameDatabase(a: *DB, b: *DB, tables: []const []const u8) !bool {
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter) return false;
    for (tables) |name| {
        const left = a.storageStats(name);
        const right = b.storageStats(name);
        if ((left == null) != (right == null)) return false;
        if (left == null) continue;
        if (left.?.live_rows != right.?.live_rows or left.?.next_rowid != right.?.next_rowid) return false;
        var query: [64]u8 = undefined;
        if (!try sameQuery(a, b, try std.fmt.bufPrint(&query, "SELECT * FROM {s}", .{name}))) return false;
    }
    return true;
}

fn sameCatalog(a: *DB, b: *DB) !bool {
    for ([_][]const u8{
        "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
        "SELECT attrelid, attname, atttypid FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT attrelid, attnum, atttypmod FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT COUNT(*), SUM(oid::int8), SUM(typarray::int8) FROM pg_type",
    }) |source| if (!try sameQuery(a, b, source)) {
        std.debug.print("catalog differs: {s}\n", .{source});
        return false;
    };
    return true;
}

var replay_primary: DB = .{};
var replay_replica: DB = .{};
var replay_expected: DB.Result = .{};

/// Replays `statements` from a fresh primary into a replica through kind-3
/// change records; both must hold the same database and catalog and answer
/// `query` identically (types, typmods, cell tags and text).
fn replay(statements: []const []const u8, tables: []const []const u8, query: []const u8) !void {
    replay_primary = .{};
    replay_replica = .{};
    var r: DB.Result = .{};
    var record: [8192]u8 = undefined;
    for (statements) |source| {
        var used: usize = 0;
        replay_primary.executeChanges(source, &r, &record, &used, null, null) catch |err| {
            std.debug.print("replay source failed: {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        try replay_replica.applyChangeRecord(record[0..used], &scratch);
    }
    try check(try sameDatabase(&replay_primary, &replay_replica, tables));
    try check(try sameCatalog(&replay_primary, &replay_replica));
    try replay_primary.execute(query, &replay_expected);
    try replay_replica.execute(query, &result);
    try check(try sameResult(&replay_expected, &result, &replay_primary, &replay_replica));
}

// ---- transactions and sessions ------------------------------------------------

fn expect(slot: u16, source: []const u8, wanted: []const u8) !void {
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try shown(source, wanted);
}

fn fails(slot: u16, source: []const u8, wanted: anyerror) !void {
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn blocks(slot: u16, source: []const u8) !void {
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("did not block: {s}\n", .{source});
        return error.ExpectedBlock;
    } else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

fn stillBlocks(slot: u16, source: []const u8) !void {
    if (db.statement(slot, source, &result, .{ .@"resume" = true })) |_| {
        std.debug.print("did not block on resume: {s}\n", .{source});
        return error.ExpectedBlock;
    } else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

fn resumed(slot: u16, source: []const u8, wanted: []const u8) !void {
    db.statement(slot, source, &result, .{ .@"resume" = true }) catch |err| {
        std.debug.print("resume {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try shown(source, wanted);
}

fn commit(slot: u16) !void {
    var record: [4096]u8 = undefined;
    if (!db.readOnly(slot)) _ = try db.prepareCommit(slot, &record);
    db.publishCommit(slot);
}

fn use(state: *DB.SessionState) void {
    db.session_state = state;
}

// ---- void -----------------------------------------------------------------------

fn voidType() !void {
    db = .{};
    // void_out is the empty string (not NULL); void_in ignores its input.
    try rows("SELECT pg_notify('c', 'p'), ''::void, 'abc'::void, NULL::void, pg_typeof('x'::void), ''::void IS NULL, length('x'::void::text)", "|||NULL|void|f|0");
    try meta(0, 2278, -1);
    try meta(1, 2278, -1);
    try named(0, "pg_notify");
    try named(1, "void");
    try rows("SELECT pg_typeof(pg_notify('c', 'p')), pg_typeof(pg_advisory_unlock_all()), CAST('' AS void), ''::void::varchar(3), ''::text::void", "void|void|||");
    try rows("SELECT format_type(2278, -1), 'void'::regtype::oid, typname, typlen, typtype, typcategory, typarray, typinput FROM pg_type WHERE oid = 2278", "void|2278|void|4|p|P|0|void_in");
    try rows("SELECT COUNT(*) FROM (SELECT pg_notify('c', 'p')) s", "1");
    try rows("SELECT CASE WHEN true THEN pg_advisory_unlock_all() END, 1 WHERE pg_advisory_unlock_all() IS NOT NULL", "|1");
    try rejects("SELECT 1::void", error.CannotCoerce);
    try sqlstate(error.CannotCoerce, "42846");
    try rejects("SELECT ''::void = ''::void", error.UndefinedFunction);
    try rejects("SELECT pg_advisory_unlock_all() ORDER BY 1", error.UndefinedFunction);
    try rejects("SELECT DISTINCT pg_advisory_unlock_all()", error.UndefinedFunction);
    try rejects("SELECT pg_advisory_unlock_all() UNION SELECT pg_advisory_unlock_all()", error.UndefinedFunction);
    try sqlstate(error.UndefinedFunction, "42883");
    try rejects("SELECT ARRAY[''::void]", error.UndefinedObject);
    try rejects("SELECT '{}'::void[]", error.UndefinedObject);
    try sqlstate(error.UndefinedObject, "42704");
    try rejects("CREATE TABLE tv(v void)", error.InvalidTableDefinition);
    try sqlstate(error.InvalidTableDefinition, "42P16");
    // Signatures: pg_advisory_lock(int8) / (int4, int4); pg_notify(text, text).
    for ([_][]const u8{
        "SELECT pg_advisory_lock(1, 2, 3)", "SELECT pg_advisory_lock(1.5)", "SELECT pg_advisory_lock(1::int8, 2)",
        "SELECT pg_advisory_unlock_all(1)", "SELECT pg_notify(1, 2)",         "SELECT pg_notify('c')",
    }) |source| try rejects(source, error.UndefinedFunction);
    // pg_notify is not strict: a NULL or empty channel is 22023, a NULL
    // payload is empty; payloads of 8000 bytes or more are 22023.
    try rejects("SELECT pg_notify(NULL, 'p')", error.InvalidParameterValue);
    try rejects("SELECT pg_notify('', 'p')", error.InvalidParameterValue);
    try sqlstate(error.InvalidParameterValue, "22023");
    try rows("SELECT pg_notify('c', NULL), pg_advisory_lock(NULL), pg_advisory_xact_lock(NULL, 1)", "|NULL|NULL");

    // pg_notify queues like NOTIFY: delivered at commit, dropped with a
    // failed statement or a rolled-back transaction.
    use(&session_a);
    const listen = try db.begin();
    try expect(listen, "LISTEN ch", "");
    try commit(listen);
    const t1 = try db.begin();
    try expect(t1, "SELECT pg_notify('ch', 'one'), pg_notify('ch', 'one'), pg_notify('other', 'x')", "||");
    try fails(t1, "SELECT pg_notify('ch', 'lost'), 1 / 0", error.DivisionByZero);
    try expect(t1, "SELECT pg_notify('ch', 'two')", "");
    try commit(t1);
    const t2 = try db.begin();
    try expect(t2, "SELECT pg_notify('ch', 'rolled back')", "");
    db.abort(t2);
    var note: DB.Notification = undefined;
    try check(db.takeNotification(&note) and std.mem.eql(u8, note.channel.slice(), "ch") and std.mem.eql(u8, note.payloadSlice(), "one"));
    try check(db.takeNotification(&note) and std.mem.eql(u8, note.payloadSlice(), "two"));
    try check(!db.takeNotification(&note));
    db.endSession();

    // Blocking advisory locks: session-level ones survive the transaction,
    // transaction-level ones end with it; a conflicting request parks the
    // statement until the holder releases (re-delivered with .resume).
    session_a = .{};
    session_b = .{};
    use(&session_a);
    const a1 = try db.begin();
    try expect(a1, "SELECT pg_advisory_lock(1), pg_advisory_lock(1, 2), pg_advisory_lock_shared(3), pg_advisory_xact_lock(4)", "|||");
    try meta(0, 2278, -1);
    try named(3, "pg_advisory_xact_lock");
    use(&session_b);
    const b1 = try db.begin();
    try expect(b1, "SELECT pg_try_advisory_lock(1), pg_try_advisory_lock_shared(3), pg_try_advisory_lock(4)", "f|t|f");
    try blocks(b1, "SELECT pg_advisory_xact_lock(9), pg_advisory_lock(1, 2)");
    try check(db.waitingFor(b1).has(a1));
    use(&session_a);
    try expect(a1, "SELECT pg_advisory_unlock(1, 2), pg_try_advisory_lock(9)", "t|f");
    try commit(a1);
    use(&session_b);
    // The re-delivered statement counts its acquisitions once.
    try resumed(b1, "SELECT pg_advisory_xact_lock(9), pg_advisory_lock(1, 2)", "|");
    try expect(b1, "SELECT pg_advisory_unlock(1, 2), pg_advisory_unlock(1, 2)", "t|f");
    // A holder outside any transaction: unlock wakes the waiter.
    try blocks(b1, "SELECT pg_advisory_lock(1)");
    try stillBlocks(b1, "SELECT pg_advisory_lock(1)");
    use(&session_a);
    try check(db.parked(b1));
    const a2 = try db.begin();
    try expect(a2, "SELECT pg_advisory_unlock_all()", "");
    try commit(a2);
    use(&session_b);
    try resumed(b1, "SELECT pg_advisory_lock(1)", "");
    try commit(b1);
    use(&session_a);
    const a3 = try db.begin();
    try expect(a3, "SELECT pg_try_advisory_lock(1), pg_try_advisory_xact_lock(9), pg_try_advisory_lock_shared(3)", "f|t|t");
    db.abort(a3);
    use(&session_b);
    const b2 = try db.begin();
    try expect(b2, "SELECT pg_advisory_unlock_all(), pg_advisory_lock_shared(5)", "|");
    try commit(b2);
    use(&session_a);
    const a4 = try db.begin();
    try expect(a4, "SELECT pg_advisory_lock_shared(5), pg_try_advisory_lock(5)", "|f");
    try expect(a4, "SELECT pg_advisory_unlock_shared(5), pg_try_advisory_lock(1)", "t|t");
    db.abort(a4);
    db.endSession();
    use(&session_b);
    db.endSession();
    db.session_state = null;
    try check(db.sessionUsage().advisory_locks == 0);
}

// ---- arrays ------------------------------------------------------------------

fn arrays() !void {
    db = .{};
    // array_position(s): IS NOT DISTINCT FROM, one dimension only (0A000),
    // the array's own subscripts, a NULL start position is 22004.
    try rows("SELECT array_position(ARRAY[1,2,3,2], 2), array_position(ARRAY[1,2,3,2], 2, 3), array_position(ARRAY[1,NULL,3], NULL), array_position(ARRAY[1,2], 5), array_position(NULL::int[], 1)", "2|4|2|NULL|NULL");
    try meta(0, 23, -1);
    try named(0, "array_position");
    try rows("SELECT array_position('[0:2]={1,2,3}'::int[], 2), array_position(ARRAY['a','b'], 'b'), array_position(ARRAY[1,2], 1.0), array_position(ARRAY[1.5,2], 2), array_position(ARRAY[1,2], 2, -1), array_position(ARRAY[1,2]::int8[], 2), array_position('{1,2}', 2)", "1|2|1|2|2|2|2");
    try rows("SELECT array_positions(ARRAY[1,2,1,NULL,1], 1), array_positions(ARRAY[1,NULL], NULL), array_positions(ARRAY[1,2], 3), array_positions(NULL::int[], 1), array_positions('[3:5]={1,2,1}'::int[], 1), array_positions(ARRAY[1.0,1.00,1], 1), array_positions('{}'::int[], 1)", "{1,3,5}|{2}|{}|NULL|{3,5}|{1,2,3}|{}");
    try meta(0, 1007, -1);
    try rejects("SELECT array_position(ARRAY[[1,2],[3,4]], 3)", error.UnsupportedStatement);
    try rejects("SELECT array_positions(ARRAY[[1,2],[3,4]], 3)", error.UnsupportedStatement);
    try sqlstate(error.UnsupportedStatement, "0A000");
    try rejects("SELECT array_position(ARRAY[1,2], 2, NULL)", error.NullValueNotAllowed);
    try sqlstate(error.NullValueNotAllowed, "22004");
    try rejects("SELECT array_position(ARRAY[1,2], 'x')", error.InvalidTextRepresentation);
    // array_replace (any dimension, anycompatible), trim_array (2202E).
    try rows("SELECT array_replace(ARRAY[1,2,1], 1, 9), array_replace(ARRAY[1,NULL,1], NULL, 0), array_replace(ARRAY[[1,2],[1,3]], 1, 7), array_replace('[2:3]={5,6}'::int[], 6, 7), array_replace(NULL::int[], 1, 2), array_replace(ARRAY[1,2], 1, NULL), array_replace('{1,2}', 1, 3)", "{9,2,9}|{1,0,1}|{{7,2},{7,3}}|[2:3]={5,7}|NULL|{NULL,2}|{3,2}");
    try rows("SELECT array_replace(ARRAY[1,2], 1.5, 2), pg_typeof(array_replace(ARRAY[1,2], 1.5, 2))", "{1,2}|numeric[]");
    try rows("SELECT trim_array(ARRAY[1,2,3,4], 2), trim_array(ARRAY[1,2], 0), trim_array(ARRAY[1,2], 2), trim_array('[0:3]={1,2,3,4}'::int[], 1), trim_array(ARRAY[[1,2],[3,4],[5,6]], 1), trim_array(NULL::int[], 1), trim_array(ARRAY[1], NULL), trim_array('{}'::int[], 0)", "{1,2}|{1,2}|{}|{1,2,3}|{{1,2},{3,4}}|NULL|NULL|{}");
    for ([_][]const u8{ "SELECT trim_array(ARRAY[1,2], 3)", "SELECT trim_array(ARRAY[1,2], -1)", "SELECT trim_array('{}'::int[], 1)" }) |source| try rejects(source, error.ArraySubscriptError);
    try sqlstate(error.ArraySubscriptError, "2202E");
    try rejects("SELECT trim_array('{1,2}', 1)", error.TypeMismatch);
    try rejects("SELECT array_reverse('{1,2}')", error.TypeMismatch);
    try sqlstate(error.TypeMismatch, "42804");
    // array_fill.
    try rows("SELECT array_fill(7, ARRAY[3]), array_fill(7, ARRAY[2,2]), array_fill(7, ARRAY[3], ARRAY[2]), array_fill('x'::text, ARRAY[2]), array_fill(NULL::int, ARRAY[2]), array_fill(1, ARRAY[0]), array_fill(1, '{}'::int[]), array_fill(1, '{2}', '{3}')", "{7,7,7}|{{7,7},{7,7}}|[2:4]={7,7,7}|{x,x}|{NULL,NULL}|{}|{}|[3:4]={1,1}");
    try meta(0, 1007, -1);
    try meta(3, 1009, -1);
    try rejects("SELECT array_fill(1, NULL)", error.NullValueNotAllowed);
    try rejects("SELECT array_fill(1, ARRAY[2], NULL)", error.NullValueNotAllowed);
    try rejects("SELECT array_fill(1, ARRAY[NULL])", error.UndefinedFunction);
    try rejects("SELECT array_fill(1, ARRAY[2], ARRAY[1,1])", error.ArraySubscriptError);
    try rejects("SELECT array_fill(1, ARRAY[[2]])", error.ArraySubscriptError);
    try rejects("SELECT array_fill(1, ARRAY[-1])", error.ProgramLimitExceeded);
    try rejects("SELECT array_fill(1, ARRAY[1,1,1,1,1,1,1])", error.ProgramLimitExceeded);
    try rejects("SELECT array_fill(1, ARRAY[2], ARRAY[2147483647])", error.ProgramLimitExceeded);
    try sqlstate(error.ProgramLimitExceeded, "54000");
    try rejects("SELECT array_fill(NULL, ARRAY[2])", error.TypeMismatch);
    try rejects("SELECT array_fill(ARRAY[1], ARRAY[2])", error.UndefinedObject);
    // array_reverse / array_sort (PostgreSQL 18).
    try rows("SELECT array_reverse(ARRAY[1,2,3]), array_reverse(ARRAY[[1,2],[3,4],[5,6]]), array_reverse('[3:5]={1,2,3}'::int[]), array_reverse('{}'::int[]), array_reverse(NULL::int[]), array_reverse(ARRAY[1,NULL]), array_reverse('[2:3][1:2]={{1,2},{3,4}}'::int[])", "{3,2,1}|{{5,6},{3,4},{1,2}}|[3:5]={3,2,1}|{}|NULL|{NULL,1}|[2:3][1:2]={{3,4},{1,2}}");
    try rows("SELECT array_sort(ARRAY[3,1,NULL,2]), array_sort(ARRAY[3,1,NULL,2], true), array_sort(ARRAY[3,1,NULL,2], false, true), array_sort(ARRAY[3,1,NULL,2], true, false), array_sort(ARRAY['b','a','C']), array_sort(ARRAY[[3,4],[1,2]]), array_sort('[2:4]={3,1,2}'::int[]), array_sort('{}'::int[])", "{1,2,3,NULL}|{NULL,3,2,1}|{NULL,1,2,3}|{3,2,1,NULL}|{C,a,b}|{{1,2},{3,4}}|[2:4]={1,2,3}|{}");
    try rows("SELECT array_sort(NULL::int[]), array_sort(ARRAY[2,1], NULL), array_sort(ARRAY[2,1], true, NULL), array_sort(ARRAY[point(1,1)])", "NULL|NULL|NULL|{\"(1,1)\"}");
    try rejects("SELECT array_sort(ARRAY[point(1,1), point(0,0)])", error.UnsupportedStatement);
    // array_sample / array_shuffle: random, so only their deterministic
    // properties (sizes, members, bounds and errors).
    try rows("SELECT array_sample(ARRAY[1,2,3], 0), array_sample(ARRAY[7], 1), cardinality(array_sample(ARRAY[1,2,3,4], 3)), array_shuffle(ARRAY[5]), array_shuffle('{}'::int[]), cardinality(array_shuffle(ARRAY[1,2,3])), array_sample(NULL::int[], 1), array_shuffle(NULL::int[])", "{}|{7}|3|{5}|{}|3|NULL|NULL");
    try rows("SELECT array_sample('[3:5]={1,1,1}'::int[], 2), array_shuffle('[3:5]={1,1,1}'::int[]), array_sample('[3:4][2:3]={{1,1},{1,1}}'::int[], 1), array_shuffle(ARRAY[[1,2]])", "{1,1}|[3:5]={1,1,1}|[1:1][2:3]={{1,1}}|{{1,2}}");
    try rows("SELECT array_sort(array_shuffle(ARRAY[3,1,2,NULL,5,4])), array_sort(array_shuffle(ARRAY[[1,2],[3,4],[5,6]])), (SELECT SUM(x) FROM unnest(array_sample(ARRAY[1,2,3,4], 4)) x)", "{1,2,3,4,5,NULL}|{{1,2},{3,4},{5,6}}|10");
    try rejects("SELECT array_sample(ARRAY[1,2], 3)", error.InvalidParameterValue);
    try rejects("SELECT array_sample(ARRAY[1,2], -1)", error.InvalidParameterValue);
    // string_to_array and width_bucket(operand, thresholds).
    try rows("SELECT string_to_array('a,b,,c', ','), string_to_array('a,b,,c', ',', ''), string_to_array('abc', NULL), string_to_array('abc', ''), string_to_array('', ','), string_to_array(NULL, ','), string_to_array('a.b', '.', 'b'), pg_typeof(string_to_array('1', ','))", "{a,b,\"\",c}|{a,b,NULL,c}|{a,b,c}|{abc}|{}|NULL|{a,NULL}|text[]");
    try rows("SELECT string_to_array('a,b', ',', 'a'), string_to_array('abc', NULL, 'b'), string_to_array('', '', 'x'), string_to_array('xx', 'x'), string_to_array('a', 'abc'), string_to_array('a,', ',')", "{NULL,b}|{a,NULL,c}|{}|{\"\",\"\",\"\"}|{a}|{a,\"\"}");
    try meta(0, 1009, -1);
    try rows("SELECT width_bucket(5, ARRAY[1,3,5,7]), width_bucket(0, ARRAY[1,3]), width_bucket(9, ARRAY[1,3]), width_bucket(2.5, ARRAY[1,2,3]), width_bucket(NULL::int, ARRAY[1]), width_bucket(1, '{}'::int[]), width_bucket(1, ARRAY[3,1]), width_bucket('b', ARRAY['a','c'])", "3|0|2|2|NULL|0|2|1");
    try meta(0, 23, -1);
    try rejects("SELECT width_bucket(1, ARRAY[[1,2]])", error.ArraySubscriptError);
    try rejects("SELECT width_bucket(1, ARRAY[1,NULL])", error.NullValueNotAllowed);

    // Set-returning forms: unnest of several arrays (FROM), WITH
    // ORDINALITY, generate_subscripts, and several SRFs in a target list
    // (lockstep, shorter ones padded with NULL).
    try rows("SELECT * FROM unnest(ARRAY[1,2], ARRAY['a','b','c'])", "1|a;2|b;NULL|c");
    try named(0, "unnest");
    try named(1, "unnest");
    try meta(1, 25, -1);
    try rows("SELECT * FROM unnest(ARRAY[1,2], ARRAY['a','b','c']) WITH ORDINALITY AS u(x, y, n)", "1|a|1;2|b|2;NULL|c|3");
    try named(2, "n");
    try meta(2, 20, -1);
    try rows("SELECT * FROM unnest(ARRAY[[1,2],[3,4]]) WITH ORDINALITY", "1|1;2|2;3|3;4|4");
    try rows("SELECT * FROM unnest(NULL::int[], ARRAY[1])", "NULL|1");
    try rows("SELECT x, n FROM unnest('[3:4]={9,8}'::int[]) WITH ORDINALITY AS u(x, n)", "9|1;8|2");
    try rows("SELECT * FROM unnest(ARRAY[1,2]) AS u", "1;2");
    try named(0, "u");
    try rows("SELECT * FROM unnest(ARRAY[1,2], ARRAY[3]) AS u(a)", "1|3;2|NULL");
    try named(0, "a");
    try named(1, "unnest");
    try rejects("SELECT * FROM unnest(ARRAY[1], NULL)", error.AmbiguousFunction);
    try rejects("SELECT * FROM unnest('{1}')", error.AmbiguousFunction);
    try rejects("SELECT unnest(ARRAY[1,2], ARRAY['a'])", error.UndefinedFunction);
    try rows("SELECT * FROM generate_subscripts(ARRAY[[1,2,3]], 2, true) WITH ORDINALITY", "3|1;2|2;1|3");
    try rows("SELECT * FROM generate_subscripts('[3:4]={1,2}'::int[], 1) g", "3;4");
    try named(0, "g");
    try meta(0, 23, -1);
    try rows("SELECT COUNT(*) FROM generate_subscripts(ARRAY[1], 1, NULL)", "0");
    try rows("SELECT generate_subscripts(ARRAY[5,6,7], 1)", "1;2;3");
    try named(0, "generate_subscripts");
    try rows("SELECT unnest(ARRAY[1,2]) AS x, generate_subscripts(ARRAY[5,6,7], 1) AS s, 10 AS k", "1|1|10;2|2|10;NULL|3|10");
    try rows("SELECT unnest(ARRAY[1,2]), unnest(ARRAY['a','b','c'])", "1|a;2|b;NULL|c");
    try rows("SELECT unnest(NULL::int[]), generate_subscripts(ARRAY[1,2], 1)", "NULL|1;NULL|2");
    try rows("SELECT COUNT(*) FROM (SELECT generate_subscripts('{}'::int[], 1), generate_subscripts(NULL::int[], 1), generate_subscripts(ARRAY[1], NULL)) s", "0");
    try rejects("SELECT generate_subscripts('{1}', 1)", error.TypeMismatch);
    try rejects("SELECT generate_subscripts(1, 1)", error.UndefinedFunction);
    // ARRAY(subquery).
    try exec("CREATE TABLE t(id INT PRIMARY KEY, g INT, v TEXT, a INT[])");
    try exec("INSERT INTO t VALUES(1, 1, 'x', '{1,2,3}'), (2, 1, 'y', NULL), (3, 2, NULL, '{4}'), (4, 2, 'w', '{}'), (5, 3, 'z', '[0:1]={7,8}')");
    try rows("SELECT ARRAY(SELECT id FROM t ORDER BY id DESC), ARRAY(SELECT v FROM t WHERE false), ARRAY(SELECT 1 UNION SELECT 2)", "{5,4,3,2,1}|{}|{1,2}");
    try meta(0, 1007, -1);
    try meta(1, 1009, -1);
    try rows("SELECT id, ARRAY(SELECT x FROM unnest(a) x ORDER BY x DESC) FROM t ORDER BY id", "1|{3,2,1};2|{};3|{4};4|{};5|{8,7}");
    try rejects("SELECT ARRAY(SELECT a FROM t WHERE id IN (1, 3))", error.ArraySubscriptError);
    try rejects("SELECT ARRAY(SELECT id, g FROM t)", error.Syntax);

    // array_agg / string_agg as window functions (FILTER, frames,
    // exclusions) and in GROUPING SETS / ROLLUP / CUBE.
    try rows("SELECT id, array_agg(id) OVER (ORDER BY id) FROM t ORDER BY id", "1|{1};2|{1,2};3|{1,2,3};4|{1,2,3,4};5|{1,2,3,4,5}");
    try meta(1, 1007, -1);
    try named(1, "array_agg");
    try rows("SELECT id, array_agg(v) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM t ORDER BY id", "1|{x,y};2|{x,y};3|{NULL,w};4|{NULL,w};5|{z}");
    try rows("SELECT id, string_agg(v, ',') OVER (PARTITION BY g ORDER BY id) FROM t ORDER BY id", "1|x;2|x,y;3|NULL;4|w;5|z");
    try meta(1, 25, -1);
    try rows("SELECT id, string_agg(v, '-') OVER w, array_agg(v) OVER w FROM t WINDOW w AS (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) ORDER BY id", "1|x|{x};2|x-y|{x,y};3|y|{y,NULL};4|w|{NULL,w};5|w-z|{w,z}");
    try rows("SELECT id, array_agg(id) FILTER (WHERE id > 2) OVER (ORDER BY id) FROM t ORDER BY id", "1|NULL;2|NULL;3|{3};4|{3,4};5|{3,4,5}");
    try rows("SELECT id, array_agg(id) OVER (ORDER BY g RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING EXCLUDE TIES), array_agg(g) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) FROM t ORDER BY id", "1|{1,3,4,5}|{1};2|{2,3,4,5}|{1,2};3|{3,5}|{1,2};4|{4,5}|{2,3};5|{5}|{2}");
    try rejects("SELECT id, array_agg(a) OVER (ORDER BY id ROWS 1 PRECEDING) FROM t WHERE id IN (1, 5) ORDER BY id", error.ArraySubscriptError);
    try rows("SELECT id, array_agg(a) OVER (ORDER BY id ROWS 1 PRECEDING) FROM t WHERE id IN (1, 5) AND id < 5 ORDER BY id", "1|{{1,2,3}}");
    try rejects("SELECT id, array_agg(id ORDER BY id DESC) OVER (PARTITION BY g) FROM t", error.UnsupportedStatement);
    try rejects("SELECT id, array_agg(DISTINCT g) OVER () FROM t", error.UnsupportedStatement);
    try rows("SELECT g, v, array_agg(id), GROUPING(g, v) FROM t GROUP BY GROUPING SETS ((g), (v), ()) ORDER BY g NULLS LAST, v NULLS LAST", "1|NULL|{1,2}|1;2|NULL|{3,4}|1;3|NULL|{5}|1;NULL|w|{4}|2;NULL|x|{1}|2;NULL|y|{2}|2;NULL|z|{5}|2;NULL|NULL|{3}|2;NULL|NULL|{1,2,3,4,5}|3");
    try rows("SELECT g, array_agg(id ORDER BY id), string_agg(v, ',' ORDER BY v), COUNT(DISTINCT v) FROM t GROUP BY ROLLUP(g) ORDER BY g NULLS LAST", "1|{1,2}|x,y|2;2|{3,4}|w|1;3|{5}|z|1;NULL|{1,2,3,4,5}|w,x,y,z|4");
    try rows("SELECT g, string_agg(v, ';' ORDER BY id) FROM t GROUP BY CUBE(g) HAVING COUNT(*) > 1 ORDER BY 1 NULLS LAST", "1|x;y;2|w;NULL|x;y;w;z");
    try rows("SELECT array_agg(id) FROM t WHERE false GROUP BY GROUPING SETS ((), (g))", "NULL");
    try rejects("SELECT g, array_agg(a) FROM t GROUP BY ROLLUP(g)", error.NullValueNotAllowed);

    // UPDATE element and slice assignment (array_set_element /
    // array_set_slice): extension with NULLs in one dimension, bounds
    // checks otherwise, a NULL array becomes the assigned shape.
    try exec("CREATE TABLE u(id INT PRIMARY KEY, a INT[], t VARCHAR(2)[], m INT[])");
    try exec("INSERT INTO u VALUES(1, '{1,2,3}', '{a,b}', '{{1,2},{3,4}}'), (2, NULL, NULL, NULL), (3, '[0:1]={5,6}', '{}', '{}')");
    try exec("UPDATE u SET a[2] = 20 WHERE id = 1");
    try exec("UPDATE u SET a[5] = 50 WHERE id = 1");
    try exec("UPDATE u SET a[-1] = -10 WHERE id = 3");
    try exec("UPDATE u SET a[1] = 1 WHERE id = 2");
    try rows("SELECT id, a FROM u ORDER BY id", "1|{1,20,3,NULL,50};2|{1};3|[-1:1]={-10,5,6}");
    try exec("UPDATE u SET a[2:3] = ARRAY[7,8] WHERE id = 1");
    try exec("UPDATE u SET t[3] = 'c', t[1] = 'z' WHERE id = 1");
    try exec("UPDATE u SET t[2:3] = '{x,y}' WHERE id = 3");
    try exec("UPDATE u SET t[1:2] = '{p,q}' WHERE id = 2");
    try rows("SELECT id, a, t FROM u ORDER BY id", "1|{1,7,8,NULL,50}|{z,b,c};2|{1}|{p,q};3|[-1:1]={-10,5,6}|[2:3]={x,y}");
    try meta(2, 1015, 6);
    try exec("UPDATE u SET m[1][2] = 9 WHERE id = 1");
    try exec("UPDATE u SET m[2:2][1:2] = '{{7,7}}' WHERE id = 1");
    try exec("UPDATE u SET m[1][1] = 5 WHERE id = 3");
    try rows("SELECT id, m FROM u ORDER BY id", "1|{{1,9},{7,7}};2|NULL;3|{{5}}");
    try exec("UPDATE u SET a[1] = 1.5, a['2'] = 2 WHERE id = 1");
    try rows("SELECT a FROM u WHERE id = 1", "{2,2,8,NULL,50}");
    try exec("UPDATE u SET a[1:] = '{9,9,9,9,9,9}' WHERE id = 1");
    try exec("UPDATE u SET a[:2] = '{4,4}' WHERE id = 1");
    try exec("UPDATE u SET a[3] = NULL, a[1:2] = NULL WHERE id = 1");
    try exec("UPDATE u SET a[10] = 1 WHERE id = 3");
    try rows("SELECT id, a FROM u ORDER BY id", "1|{4,4,NULL,9,9};2|{1};3|[-1:10]={-10,5,6,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1}");
    for ([_][]const u8{
        "UPDATE u SET m[3][1] = 0 WHERE id = 1", "UPDATE u SET m[1] = 0 WHERE id = 1",
        "UPDATE u SET a[1:2] = '{1}' WHERE id = 1", "UPDATE u SET a[1:3][1] = '{}' WHERE id = 1",
        "UPDATE u SET a[2] = 0, m[9][9] = 1",
    }) |source| try rejects(source, error.ArraySubscriptError);
    try rejects("UPDATE u SET a[NULL] = 1 WHERE id = 1", error.NullValueNotAllowed);
    try rejects("UPDATE u SET a[1] = 'x' WHERE id = 1", error.InvalidTextRepresentation);
    try rejects("UPDATE u SET t[1] = 'abc' WHERE id = 1", error.StringDataRightTruncation);
    try rejects("UPDATE u SET id[1] = 1", error.TypeMismatch);
    try rejects("UPDATE u SET a[1] = 1, a = '{}' WHERE id = 1", error.Syntax);
    try rejects("UPDATE u SET a = '{}', a[1] = 1 WHERE id = 1", error.Syntax);
    try rejects("UPDATE u SET a[2147483647] = 1 WHERE id = 1", error.ProgramLimitExceeded);
    try rows("SELECT id, a, m FROM u ORDER BY id", "1|{4,4,NULL,9,9}|{{1,9},{7,7}};2|{1}|NULL;3|[-1:10]={-10,5,6,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,1}|{{5}}");

    // Durability: assignments replay as ordinary row versions.
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, a INT[], t TEXT[])",
        "INSERT INTO r VALUES(1, '{1,2}', NULL), (2, NULL, '{x}')",
        "UPDATE r SET a[4] = 4, t[2:3] = '{y,z}'",
        "UPDATE r SET a = array_replace(array_reverse(a), 2, 20) WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|{4,NULL,20,1}|[2:3]={y,z};2|[4:4]={4}|{x,y,z}");
}

// ---- network: macaddr8, inet arithmetic and functions ----------------------------

fn sendBinary(cell: *const DB.Cell, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const length = try Wire.sendBinary(cell, data_type, &db.session, &out);
    if (!std.mem.eql(u8, out[0..length], expected)) std.debug.print("binary got {any}\n  expected {any}\n", .{ out[0..length], expected });
    try check(std.mem.eql(u8, out[0..length], expected));
}

fn receive(bytes: []const u8, data_type: sql.DataType, expected: []const u8) !void {
    var out: [512]u8 = undefined;
    const text = try Wire.receiveText(bytes, data_type, &out);
    if (!std.mem.eql(u8, text, expected)) std.debug.print("receive got {s}\n  expected {s}\n", .{ text, expected });
    try check(std.mem.eql(u8, text, expected));
}

fn networkTypes() !void {
    db = .{};
    // macaddr8_in: pairs of hex digits with one consistent separator; six
    // bytes become EUI-64 with FF:FE inserted.
    try rows("SELECT '08:00:2b:01:02:03:04:05'::macaddr8, '08-00-2b-01-02-03-04-05'::macaddr8, '08002b:0102030405'::macaddr8, '0800.2b01.0203.0405'::macaddr8, '08002b0102030405'::macaddr8, '0800:2b01:0203:0405'::macaddr8, ' 08:00:2B:01:02:03:04:AB '::macaddr8",
        "08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:ab");
    try meta(0, 774, -1);
    try named(0, "macaddr8");
    try rows("SELECT '08:00:2b:01:02:03'::macaddr8, '08002b010203'::macaddr8, '0800.2b01.0203'::macaddr8, '08002b:01:02:03:04:05'::macaddr8, '08:00:2b:01:02:03:04:05:'::macaddr8, '08:00:2b:01:02:03:04:05x'::macaddr8",
        "08:00:2b:ff:fe:01:02:03|08:00:2b:ff:fe:01:02:03|08:00:2b:ff:fe:01:02:03|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05");
    for ([_][]const u8{
        "SELECT '08:0:2b:1:2:3:4:5'::macaddr8",          "SELECT '08:00:2b:01:02:03:04'::macaddr8",
        "SELECT '08:00:2b:01:02:03:04:05:06'::macaddr8", "SELECT 'xx'::macaddr8",
        "SELECT ''::macaddr8",                            "SELECT '08:00:2b:01:02:03:04:0g'::macaddr8",
        "SELECT '08:00-2b:01:02:03:04:05'::macaddr8",    "SELECT '0800-2b01:0203-0405'::macaddr8",
        "SELECT '08 00 2b 01 02 03 04 05'::macaddr8",    "SELECT '08:00:2b:01:02:03:04:5'::macaddr8",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    // Conversions (implicit both ways; FF:FE required to narrow, 22003).
    try rows("SELECT macaddr8('08:00:2b:01:02:03'::macaddr), macaddr('08:00:2b:ff:fe:01:02:03'::macaddr8), '08:00:2b:01:02:03'::macaddr::macaddr8, pg_typeof(macaddr8('08:00:2b:01:02:03'::macaddr)), '08:00:2b:01:02:03:04:05'::macaddr8::text, '08:00:2b:01:02:03:04:05'::text::macaddr8", "08:00:2b:ff:fe:01:02:03|08:00:2b:01:02:03|08:00:2b:ff:fe:01:02:03|macaddr8|08:00:2b:01:02:03:04:05|08:00:2b:01:02:03:04:05");
    try meta(1, 829, -1);
    try rejects("SELECT macaddr('08:00:2b:01:02:03:04:05'::macaddr8)", error.NumericValueOutOfRange);
    try sqlstate(error.NumericValueOutOfRange, "22003");
    try rows("SELECT trunc('12:34:56:78:90:ab'::macaddr), trunc('12:34:56:78:90:ab:cd:ef'::macaddr8), macaddr8_set7bit('00:34:56:ab:cd:ef:01:02'::macaddr8), macaddr8_set7bit('02:34:56:ab:cd:ef:01:02'::macaddr8)", "12:34:56:00:00:00|12:34:56:00:00:00:00:00|02:34:56:ab:cd:ef:01:02|02:34:56:ab:cd:ef:01:02");
    try meta(1, 774, -1);
    try named(0, "trunc");
    try rows("SELECT '12:34:56:78:90:ab'::macaddr & '0f:0f:0f:0f:0f:0f'::macaddr, '12:34:56:78:90:ab'::macaddr | 'f0:00:00:00:00:01'::macaddr, ~ '12:34:56:78:90:ab'::macaddr", "02:04:06:08:00:0b|f2:34:56:78:90:ab|ed:cb:a9:87:6f:54");
    try named(0, "?column?");
    try rows("SELECT '12:34:56:78:90:ab:cd:ef'::macaddr8 & 'ff:00:ff:00:ff:00:ff:00'::macaddr8, '12:34:56:78:90:ab:cd:ef'::macaddr8 | '00:00:00:00:00:00:00:01'::macaddr8, ~ '12:34:56:78:90:ab:cd:ef'::macaddr8", "12:00:56:00:90:00:cd:00|12:34:56:78:90:ab:cd:ef|ed:cb:a9:87:6f:54:32:10");
    try meta(2, 774, -1);
    try rows("SELECT '08:00:2b:01:02:03'::macaddr8 = '08:00:2b:ff:fe:01:02:03'::macaddr8, '01:00:00:00:00:00:00:00'::macaddr8 < '02:00:00:00:00:00:00:00'::macaddr8", "t|t");
    try rejects("SELECT '08:00:2b:01:02:03'::macaddr = '08:00:2b:01:02:03:04:05'::macaddr8", error.AmbiguousFunction);
    try sqlstate(error.AmbiguousFunction, "42725");
    try rows("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (774, 775) ORDER BY oid", "macaddr8|8|U|775|macaddr8_in;_macaddr8|-1|A|0|array_in");
    // Columns: ordering, grouping, DISTINCT, arrays; atomicity.
    try exec("CREATE TABLE m(id INT PRIMARY KEY, a MACADDR8, l MACADDR8[])");
    try exec("INSERT INTO m VALUES(1, '01:02:03:04:05:06:07:08', '{08:00:2b:01:02:03}'), (2, '01:02:03:04:05:06:07:07', NULL), (3, NULL, '{}'), (4, '01:02:03:04:05:06:07:08', NULL)");
    try rows("SELECT a FROM m ORDER BY a NULLS LAST", "01:02:03:04:05:06:07:07;01:02:03:04:05:06:07:08;01:02:03:04:05:06:07:08;NULL");
    try rows("SELECT a, COUNT(*) FROM m GROUP BY a ORDER BY a", "01:02:03:04:05:06:07:07|1;01:02:03:04:05:06:07:08|2;NULL|1");
    try rows("SELECT COUNT(DISTINCT a), MIN(id) FROM m WHERE a > '01:02:03:04:05:06:07:07'", "1|1");
    try rows("SELECT l, l[1] FROM m WHERE id = 1", "{08:00:2b:ff:fe:01:02:03}|08:00:2b:ff:fe:01:02:03");
    try meta(0, 775, -1);
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'm' AND column_name = 'a'", "macaddr8");
    try rejects("INSERT INTO m(id, a) VALUES(5, '01:02:03:04:05:06:07:08'), (6, 'bad')", error.InvalidTextRepresentation);
    try rows("SELECT COUNT(*) FROM m", "4");
    // Wire: eight bytes (macaddr8_recv also takes six).
    try exec("SELECT '08:00:2b:01:02:03:04:05'::macaddr8");
    const mac8_bytes = [_]u8{ 8, 0, 0x2b, 1, 2, 3, 4, 5 };
    try check(Wire.oid(.macaddr8) == 774 and Wire.length(.macaddr8) == 8);
    try sendBinary(&result.rows[0].cells[0], .macaddr8, &mac8_bytes);
    try receive(&mac8_bytes, .macaddr8, "08:00:2b:01:02:03:04:05");
    try receive(&.{ 8, 0, 0x2b, 1, 2, 3 }, .macaddr8, "08:00:2b:ff:fe:01:02:03");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(mac8_bytes[0..7], .macaddr8, &out)) |_| false else |err| err == error.ProtocolViolation);

    // inet arithmetic (internal_inetpl / inetmi) and bitwise operators.
    try rows("SELECT '192.168.1.6'::inet + 25, 25 + '192.168.1.6'::inet, '192.168.1.43'::inet - 36, '192.168.1.43'::inet - '192.168.1.19'::inet, '::1'::inet + 1, '192.168.1.6/24'::inet + 300, '10.0.0.0/8'::cidr + 1, pg_typeof('10.0.0.0/8'::cidr + 1), '192.168.1.19'::inet - '192.168.1.43'::inet",
        "192.168.1.31|192.168.1.31|192.168.1.7|24|::2|192.168.2.50/24|10.0.0.1/8|inet|-24");
    try meta(0, 869, -1);
    try meta(3, 20, -1);
    try named(0, "?column?");
    try rows("SELECT 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'::inet - '::'::inet, '::'::inet + 9223372036854775807, '1.2.3.4'::inet - '1'::int2, '1.2.3.4'::inet + 1::int8, '1.2.3.4'::inet - '1.2.3.3'", "-1|::7fff:ffff:ffff:ffff|1.2.3.3|1.2.3.5|1");
    for ([_][]const u8{
        "SELECT '255.255.255.255'::inet + 1",            "SELECT '0.0.0.0'::inet - 1",
        "SELECT '1.2.3.4'::inet + 9223372036854775807", "SELECT '::'::inet - (-9223372036854775807-1)",
    }) |source| try rejects(source, error.NumericValueOutOfRange);
    try rejects("SELECT '::1'::inet - '1.2.3.4'::inet", error.InvalidParameterValue);
    try rejects("SELECT '1.2.3.4'::inet & '::1'::inet", error.InvalidParameterValue);
    try rejects("SELECT '1.2.3.4' + 1", error.InvalidTextRepresentation);
    try rejects("SELECT 1::numeric + '1.2.3.4'::inet", error.UndefinedFunction);
    try rows("SELECT '192.168.1.6'::inet & '0.0.0.255'::inet, '192.168.1.6'::inet | '0.0.0.255'::inet, ~ '192.168.1.6'::inet, '10.1.0.0/16'::cidr & '255.0.0.0'::inet, ~ '10.0.0.0/8'::cidr, '::1'::inet | '::2'::inet",
        "0.0.0.6|192.168.1.255|63.87.254.249|10.0.0.0|245.255.255.255/8|::3");
    // abbrev / set_masklen / hostmask / inet_merge / inet_same_family.
    try rows("SELECT abbrev('10.1.0.0/16'::inet), abbrev('10.1.0.0/16'::cidr), abbrev('10.1.0.0/32'::inet), abbrev('10.1.2.0/24'::cidr), abbrev('2001:db8::/32'::cidr), abbrev('::1'::inet), abbrev('10.0.0.0/8'::cidr), abbrev('0.0.0.0/0'::cidr), abbrev('1.2.3.4/32'::cidr)",
        "10.1.0.0/16|10.1/16|10.1.0.0|10.1.2/24|2001:db8/32|::1|10/8|0/0|1.2.3.4/32");
    try meta(0, 25, -1);
    try named(0, "abbrev");
    try rows("SELECT abbrev('2001:db8:1::/48'::cidr), abbrev('::/0'::cidr), abbrev('fe80::/10'::cidr), abbrev('2001:db8::1/128'::cidr), abbrev('::ffff:1.2.3.0/120'::cidr), abbrev('::1.2.3.4/128'::cidr), abbrev('1:0:0:1::/64'::cidr), abbrev('0:0:1::/48'::cidr), abbrev('8000::/1'::cidr), abbrev('2001:db8:0:0:1::/80'::cidr)",
        "2001:db8:1/48|::/0|fe80::/10|2001:db8::1/128|::ffff:1.2.3/120|::1.2.3.4/128|1::1/64|::1/48|8000::/1|2001:db8::1/80");
    try rows("SELECT abbrev('::ffff:1.2.0.0/112'::cidr), abbrev('::ffff:0.0.0.0/96'::cidr), abbrev('::1.2.3.0/120'::cidr), abbrev('128.0.0.0/1'::cidr), abbrev('10.128.0.0/9'::cidr), abbrev('10.1.2.2/31'::cidr)", "::ffff:1.2/112|::ffff/96|::1.2.3/120|128/1|10.128/9|10.1.2.2/31");
    try rows("SELECT set_masklen('192.168.1.5/24'::inet, 16), set_masklen('192.168.1.0/24'::cidr, 16), set_masklen('192.168.1.5'::inet, -1), set_masklen('::1'::inet, 64), pg_typeof(set_masklen('192.168.1.0/24'::cidr, 16)), set_masklen('10.1.0.0/16'::cidr, 24)",
        "192.168.1.5/16|192.168.0.0/16|192.168.1.5|::1/64|cidr|10.1.0.0/24");
    try meta(1, 650, -1);
    try rejects("SELECT set_masklen('192.168.1.5'::inet, 33)", error.InvalidParameterValue);
    try rejects("SELECT set_masklen('192.168.1.5'::inet, -2)", error.InvalidParameterValue);
    try rows("SELECT hostmask('192.168.23.20/30'::inet), hostmask('::1/64'::inet), hostmask('10.0.0.0/8'::cidr), pg_typeof(hostmask('10.0.0.0/8'::cidr))", "0.0.0.3|::ffff:ffff:ffff:ffff|0.255.255.255|inet");
    try rows("SELECT inet_merge('192.168.1.5/24'::inet, '192.168.2.5/24'::inet), inet_merge('10.0.0.1'::inet, '10.0.0.1'::inet), inet_merge('::1'::inet, '::2'::inet), pg_typeof(inet_merge('10.0.0.1'::inet, '10.0.0.1'::inet)), inet_merge('10.0.0.1/8'::inet, '11.0.0.1/32'::inet)",
        "192.168.0.0/22|10.0.0.1/32|::/126|cidr|10.0.0.0/7");
    try meta(0, 650, -1);
    try rejects("SELECT inet_merge('1.2.3.4'::inet, '::1'::inet)", error.InvalidParameterValue);
    try rows("SELECT inet_same_family('192.168.1.5/24'::inet, '::1'::inet), inet_same_family('1.2.3.4'::inet, '10.0.0.0/8'::cidr), inet_same_family(NULL, '::1'::inet), set_masklen('192.168.1.5'::inet, NULL), abbrev(NULL::inet), hostmask(NULL::inet)", "f|t|NULL|NULL|NULL|NULL");

    // Durability: change-record value tag 46 (macaddr8).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, a MACADDR8, l MACADDR8[], n INET)",
        "INSERT INTO r VALUES(1, '08:00:2b:01:02:03', '{01:02:03:04:05:06:07:08,NULL}', '10.0.0.1/8'), (2, NULL, NULL, NULL)",
        "UPDATE r SET a = ~a, n = n + 255 WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|f7:ff:d4:00:01:fe:fd:fc|{01:02:03:04:05:06:07:08,NULL}|10.0.1.0/8;2|NULL|NULL|NULL");
    try meta(1, 774, -1);
    try meta(2, 775, -1);
}

// ---- geometric: lseg, line, path, polygon, circle ------------------------------

fn geometry() !void {
    db = .{};
    // Input forms and output (path_decode / line_in / circle_in / path_encode).
    try rows("SELECT '[(1,2),(3,4)]'::lseg, '((1,2),(3,4))'::lseg, '(1,2),(3,4)'::lseg, '1,2,3,4'::lseg, ' [ ( 1 , 2 ) , ( 3 , 4 ) ] '::lseg", "[(1,2),(3,4)]|[(1,2),(3,4)]|[(1,2),(3,4)]|[(1,2),(3,4)]|[(1,2),(3,4)]");
    try meta(0, 601, -1);
    try named(0, "lseg");
    try rows("SELECT '{1,2,3}'::line, '{1,-1,0}'::line, '[(0,0),(1,1)]'::line, '((0,0),(0,1))'::line, '(0,0),(2,1)'::line, '0,0,1,0'::line", "{1,2,3}|{1,-1,0}|{1,-1,0}|{-1,0,0}|{0.5,-1,0}|{0,-1,0}");
    try meta(0, 628, -1);
    try rows("SELECT '((1,2),(3,4),(5,6))'::path, '[(1,2),(3,4)]'::path, '(1,2),(3,4)'::path, '1,2,3,4'::path, '(1,2)'::path, '((1,2))'::path, '[(1,2)]'::path", "((1,2),(3,4),(5,6))|[(1,2),(3,4)]|((1,2),(3,4))|((1,2),(3,4))|((1,2))|((1,2))|[(1,2)]");
    try meta(0, 602, -1);
    try rows("SELECT '((1,2),(3,4),(5,6))'::polygon, '(1,2),(3,4)'::polygon, '1,2,3,4'::polygon, '(1,2)'::polygon, '((1,2))'::polygon", "((1,2),(3,4),(5,6))|((1,2),(3,4))|((1,2),(3,4))|((1,2))|((1,2))");
    try meta(0, 604, -1);
    try rows("SELECT '<(1,2),3>'::circle, '((1,2),3)'::circle, '(1,2),3'::circle, '1,2,3'::circle, '<(1,2),0>'::circle, ' < ( 1 , 2 ) , 3 > '::circle", "<(1,2),3>|<(1,2),3>|<(1,2),3>|<(1,2),3>|<(1,2),0>|<(1,2),3>");
    try meta(0, 718, -1);
    for ([_][]const u8{
        "SELECT '{0,0,1}'::line",      "SELECT '[(0,0),(0,0)]'::line",  "SELECT '[(1,2)]'::polygon",
        "SELECT '<(1,2),-1>'::circle", "SELECT '(1,2),3,4'::circle",    "SELECT '((1,2),(3,4)'::path",
        "SELECT '(1,2),(3'::lseg",     "SELECT '1,2,3'::path",
    }) |source| try rejects(source, error.InvalidTextRepresentation);
    try rows("SELECT typname, typlen, typcategory, typarray, typinput FROM pg_type WHERE oid IN (601, 628, 602, 604, 718) ORDER BY oid", "lseg|32|G|1018|lseg_in;path|-1|G|1019|path_in;polygon|-1|G|1027|poly_in;line|24|G|629|line_in;circle|24|G|719|circle_in");
    // Functions.
    try rows("SELECT area('<(0,0),1>'::circle), area('((0,0),(2,0),(2,2))'::path), area('[(0,0),(2,0),(2,2)]'::path), center('<(1,2),3>'::circle), length('[(0,0),(3,4)]'::lseg), length('((0,0),(3,4))'::path), length('[(0,0),(3,4)]'::path), npoints('((1,2),(3,4),(5,6))'::path), npoints('((1,2),(3,4))'::polygon), radius('<(1,2),3>'::circle), diameter('<(1,2),3>'::circle)",
        "3.141592653589793|2|NULL|(1,2)|5|10|5|3|2|3|6");
    try meta(0, 701, -1);
    try meta(7, 23, -1);
    try rows("SELECT isclosed('((1,2),(3,4))'::path), isopen('((1,2),(3,4))'::path), pclose('[(1,2),(3,4)]'::path), popen('((1,2),(3,4))'::path), slope(point(0,0), point(1,2)), slope(point(0,0), point(0,2)), slope(point(0,0), point(2,0)), diagonal('(1,2),(3,4)'::box), width('(1,2),(4,4)'::box), height('(1,2),(4,4)'::box)",
        "t|f|((1,2),(3,4))|[(1,2),(3,4)]|2|Infinity|0|[(3,4),(1,2)]|3|2");
    try rows("SELECT box('<(1,2),3>'::circle), box(point(1,2)), box('((0,0),(2,0),(2,2))'::polygon), bound_box('(1,1),(0,0)'::box, '(3,3),(2,2)'::box), circle('(1,1),(0,0)'::box), circle(point(1,2), 3), circle('((0,0),(2,0),(2,2),(0,2))'::polygon), line(point(0,0), point(1,1)), lseg('(1,1),(0,0)'::box), lseg(point(1,2), point(3,4))",
        "(3.1213203435596424,4.121320343559642),(-1.1213203435596424,-0.12132034355964239)|(1,2),(1,2)|(2,2),(0,0)|(3,3),(0,0)|<(0.5,0.5),0.7071067811865476>|<(1,2),3>|<(1,1),1.4142135623730951>|{1,-1,0}|[(1,1),(0,0)]|[(1,2),(3,4)]");
    try rows("SELECT path('((0,0),(1,1),(2,0))'::polygon), point('(1,1),(0,0)'::box), point('<(1,2),3>'::circle), point('[(0,0),(2,2)]'::lseg), point('((0,0),(2,0),(2,2),(0,2))'::polygon), polygon('(1,1),(0,0)'::box), polygon(4, '<(0,0),1>'::circle), polygon('((0,0),(1,1),(2,0))'::path), circle(point(1,2), -1)",
        "((0,0),(1,1),(2,0))|(0.5,0.5)|(1,2)|(1,1)|(1,1)|((0,0),(0,1),(1,1),(1,0))|((-1,0),(-6.123233995736766e-17,1),(1,1.2246467991473532e-16),(1.8369701987210297e-16,-1))|((0,0),(1,1),(2,0))|<(1,2),-1>");
    try rows("SELECT ishorizontal('[(0,0),(1,0)]'::lseg), isvertical('[(0,0),(0,1)]'::lseg), ishorizontal(point(0,1), point(5,1)), isvertical(point(1,0), point(1,5)), ishorizontal('{0,-1,3}'::line), isvertical('{-1,0,3}'::line), isparallel('{1,-1,0}'::line, '{2,-2,5}'::line), isperp('{1,-1,0}'::line, '{1,1,0}'::line), isparallel('[(0,0),(1,1)]'::lseg, '[(1,0),(2,1)]'::lseg), isperp('[(0,0),(1,1)]'::lseg, '[(0,0),(1,-1)]'::lseg)",
        "t|t|t|t|t|t|t|t|t|t");
    try rejects("SELECT polygon('[(0,0),(1,1),(2,0)]'::path)", error.InvalidParameterValue);
    try rejects("SELECT polygon(3, '<(0,0),0>'::circle)", error.UnsupportedStatement);
    try rejects("SELECT polygon(1, '<(0,0),1>'::circle)", error.InvalidParameterValue);
    try rejects("SELECT line(point(1,1), point(1,1))", error.InvalidParameterValue);
    try rejects("SELECT area('((0,0),(2,0),(2,2),(0,2))'::polygon)", error.UndefinedFunction);
    // Casts (assignment for point->box, path<->polygon, box->polygon).
    try rows("SELECT '(1,1),(0,0)'::box::polygon, '((0,0),(1,1),(2,0))'::path::polygon, '((0,0),(1,1))'::polygon::path, point('(1,2),(3,4)'::box)::box, '<(0,0),1>'::circle::box = box('<(0,0),1>'::circle)", "((0,0),(0,1),(1,1),(1,0))|((0,0),(1,1),(2,0))|((0,0),(1,1))|(2,3),(2,3)|t");
    try rejects("SELECT '[(0,0),(1,1)]'::path::polygon", error.InvalidParameterValue);
    try rejects("SELECT '[(0,0),(1,1)]'::lseg::box", error.CannotCoerce);
    // Operators.
    try rows("SELECT '<(0,0),2>'::circle @> point(1,1), point(3,0) <@ '<(0,0),2>'::circle, '((0,0),(2,0),(2,2),(0,2))'::polygon @> point(1,1), point(3,3) <@ '((0,0),(2,0),(2,2),(0,2))'::polygon, '((0,0),(2,0),(2,2),(0,2))'::polygon @> point(2,1), '<(0,0),3>'::circle @> '<(1,0),1>'::circle, '<(0,0),1>'::circle && '<(3,0),1>'::circle, '<(0,0),1>'::circle && '<(2,0),1>'::circle",
        "t|f|t|f|t|t|f|t");
    try rows("SELECT point(0,0) <-> '<(3,4),1>'::circle, '<(0,0),1>'::circle <-> '<(5,0),1>'::circle, point(0,1) <-> '[(-1,0),(1,0)]'::lseg, point(0,1) <-> '{0,-1,0}'::line, point(3,3) <-> '(1,1),(0,0)'::box, '{1,-1,0}'::line <-> '{1,-1,5}'::line, point(1,1) <-> '((0,0),(0,2),(2,2))'::path, point(5,5) <-> '((0,0),(2,0),(2,2),(0,2))'::polygon, point(1,1) <-> '((0,0),(2,0),(2,2),(0,2))'::polygon, point(1,2) <-> point(4,6)",
        "4|3|1|1|2.8284271247461903|3.5355339059327373|0|4.242640687119286|0|5");
    try meta(0, 701, -1);
    try named(0, "?column?");
    try rows("SELECT '[(0,0),(1,1)]'::lseg = '[(0,0),(1,1)]'::lseg, '[(0,0),(1,1)]'::lseg < '[(0,0),(2,2)]'::lseg, '(2,2),(0,0)'::box = '(4,1),(0,0)'::box, '(2,2),(0,0)'::box < '(3,3),(0,0)'::box, '<(0,0),1>'::circle = '<(5,5),1>'::circle, '<(0,0),1>'::circle < '<(0,0),2>'::circle, '((0,0),(1,1))'::path = '[(5,5),(6,6)]'::path, '{1,-1,0}'::line = '{2,-2,0}'::line, '<(0,0),1>'::circle ~= '<(0,0),1>'::circle, '((0,0),(1,0),(1,1))'::polygon ~= '((1,0),(1,1),(0,0))'::polygon",
        "t|t|t|t|t|t|t|t|t|t");
    try rows("SELECT '<(0,0),1>'::circle << '<(3,0),1>'::circle, '<(3,0),1>'::circle >> '<(0,0),1>'::circle, '<(0,0),1>'::circle &< '<(1,0),1>'::circle, '<(1,0),1>'::circle &> '<(0,0),1>'::circle, point(1,2) <> point(1,3)", "t|t|t|t|t");
    try rows("SELECT point(1,2) + point(3,4), point(1,2) - point(3,4), point(1,2) * point(3,4), point(1,2) / point(3,4), '(1,1),(0,0)'::box + point(1,1), '(1,1),(0,0)'::box * point(2,0), '<(1,1),2>'::circle + point(1,1), '<(1,1),2>'::circle * point(0,1), '((0,0),(1,1))'::path + point(1,1), '[(0,0),(1,1)]'::path + '[(2,2),(3,3)]'::path, '<(1,1),2>'::circle / point(2,0), '(4,4),(2,2)'::box / point(2,0)",
        "(4,6)|(-2,-2)|(-5,10)|(0.44,0.08)|(2,2),(1,1)|(2,2),(0,0)|<(2,2),2>|<(-1,1),2>|((1,1),(2,2))|[(0,0),(1,1),(2,2),(3,3)]|<(0.5,0.5),1>|(2,2),(1,1)");
    try rows("SELECT '[(0,0),(1,1)]'::path + '((2,2),(3,3))'::path, pt_contained_circle(point(1,1), '<(0,0),2>'::circle), pt_contained_poly(point(1,1), '((0,0),(2,0),(2,2),(0,2))'::polygon), point(1,1) <@ '[(0,0),(2,2)]'::lseg, point(1,1) <@ '{1,-1,0}'::line, '((0,0),(2,0),(2,2))'::path @> point(1,1), '[(0,0),(2,0)]'::path @> point(1,0)", "NULL|t|t|t|t|t|t");
    try rows("SELECT '(3,3),(0,0)'::box @> '(2,2),(1,1)'::box, '(1,1),(0,0)'::box << '(3,3),(2,2)'::box, '(3,3),(2,2)'::box >> '(1,1),(0,0)'::box, '(1,1),(0,0)'::box &< '(3,3),(0,0)'::box, '(2,2),(1,1)'::box <@ '(3,3),(0,0)'::box", "t|t|t|t|t");
    try rejects("SELECT point(1,2) / point(0,0)", error.DivisionByZero);
    try sqlstate(error.DivisionByZero, "22012");
    try rejects("SELECT point(1,2) = point(1,2)", error.UndefinedFunction);
    try rejects("SELECT '<(0,0),1>'::circle + '<(0,0),1>'::circle", error.UndefinedFunction);
    // Subscripts: point and line as float8 arrays, box and lseg as points.
    try rows("SELECT (point(1,2))[0], (point(1,2))[1], (point(1,2))[2], ('(1,2),(3,4)'::box)[0], ('(1,2),(3,4)'::box)[0][1], ('[(1,2),(3,4)]'::lseg)[1], ('{1,2,3}'::line)[2], ('{1,2,3}'::line)[3]", "1|2|NULL|(3,4)|NULL|(3,4)|3|NULL");
    try meta(0, 701, -1);
    try meta(3, 600, -1);
    // Columns: no ordering, grouping or DISTINCT (42883); atomicity.
    try exec("CREATE TABLE g(id INT PRIMARY KEY, s LSEG, l LINE, p PATH, q POLYGON, c CIRCLE)");
    try exec("INSERT INTO g VALUES(1, '[(0,0),(1,1)]', '{1,-1,0}', '[(0,0),(1,1),(2,0)]', '((0,0),(2,0),(2,2))', '<(1,1),1>'), (2, NULL, NULL, NULL, NULL, NULL)");
    try rows("SELECT * FROM g ORDER BY id", "1|[(0,0),(1,1)]|{1,-1,0}|[(0,0),(1,1),(2,0)]|((0,0),(2,0),(2,2))|<(1,1),1>;2|NULL|NULL|NULL|NULL|NULL");
    try rows("SELECT id FROM g WHERE c @> point(1,1.5) AND q @> point(1,0.5)", "1");
    try rejects("SELECT c FROM g ORDER BY c", error.UndefinedFunction);
    try rejects("SELECT DISTINCT q FROM g", error.UndefinedFunction);
    try rejects("SELECT s, COUNT(*) FROM g GROUP BY s", error.UndefinedFunction);
    try rejects("INSERT INTO g(id, c) VALUES(3, '<(0,0),1>'), (4, '<(0,0),-1>')", error.InvalidTextRepresentation);
    try rows("SELECT COUNT(*), data_type FROM information_schema.columns WHERE table_name = 'g' AND column_name = 'q' GROUP BY data_type", "1|polygon");
    // Wire: float8 words; path: closed byte and count; polygon: count.
    try exec("SELECT '[(1,2),(3,4)]'::lseg, '[(1,2)]'::path, '((1,2))'::polygon, '<(1,2),3>'::circle");
    try sendBinary(&result.rows[0].cells[0], .lseg, &.{ 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x08, 0, 0, 0, 0, 0, 0, 0x40, 0x10, 0, 0, 0, 0, 0, 0 });
    try sendBinary(&result.rows[0].cells[1], .path, &.{ 0, 0, 0, 0, 1, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0 });
    try sendBinary(&result.rows[0].cells[2], .polygon, &.{ 0, 0, 0, 1, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0 });
    try receive(&.{ 0, 0, 0, 0, 1, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0 }, .path, "[(1,2)]");
    try receive(&.{ 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x08, 0, 0, 0, 0, 0, 0 }, .circle, "<(1,2),3>");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0 }, .line, &out)) |_| false else |err| err == error.ProtocolViolation);
    try check(if (Wire.receiveText(&.{ 0, 0, 0, 0, 0 }, .polygon, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability: change-record value tag 41 (validated on replay).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, s LSEG, l LINE, p PATH, q POLYGON, c CIRCLE)",
        "INSERT INTO r VALUES(1, '[(0,0),(1,1)]', '{1,-1,0}', '[(0,0),(1,1),(2,0)]', '((0,0),(2,0),(2,2))', '<(1,1),1>'), (2, NULL, NULL, NULL, NULL, NULL)",
        "UPDATE r SET p = pclose(p) + point(1,1), c = c * point(2,0) WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|[(0,0),(1,1)]|{1,-1,0}|((1,1),(2,2),(3,1))|((0,0),(2,0),(2,2))|<(2,2),2>;2|NULL|NULL|NULL|NULL|NULL");
    try meta(5, 718, -1);
}

// ---- multiranges ---------------------------------------------------------------

fn multiranges() !void {
    db = .{};
    // multirange_in: canonical (sorted, merged, no empty ranges).
    try rows("SELECT '{}'::int4multirange, '{[1,3)}'::int4multirange, '{[1,3), [5,7)}'::int4multirange, '{[1,3],[2,8)}'::int4multirange, '{[3,4),[1,2)}'::int4multirange, '{(1,3),empty,[3,5]}'::int4multirange, ' { [1,2) } '::int4multirange, '{[1,2),[2,3)}'::int4multirange",
        "{}|{[1,3)}|{[1,3),[5,7)}|{[1,8)}|{[1,2),[3,4)}|{[2,6)}|{[1,2)}|{[1,3)}");
    try meta(0, 4451, -1);
    try named(0, "int4multirange");
    try rows("SELECT '{[1.5,2.5],(3,4)}'::nummultirange, '{[2026-01-01,2026-01-05),[2026-01-05,2026-01-07]}'::datemultirange, '{[2026-01-01 10:00,2026-01-01 11:00)}'::tsmultirange, '{(,5),[10,)}'::int8multirange, '{(,)}'::int4multirange",
        "{[1.5,2.5],(3,4)}|{[2026-01-01,2026-01-08)}|{[\"2026-01-01 10:00:00\",\"2026-01-01 11:00:00\")}|{(,5),[10,)}|{(,)}");
    try meta(0, 4532, -1);
    try meta(1, 4535, -1);
    try meta(3, 4536, -1);
    for ([_][]const u8{ "SELECT '{[1,3)'::int4multirange", "SELECT '[1,3)'::int4multirange", "SELECT '{[1,3),}'::int4multirange" }) |source|
        try rejects(source, error.InvalidTextRepresentation);
    try rejects("SELECT '{[3,1)}'::int4multirange", error.DataException);
    try rows("SELECT typname, typlen, typtype, typcategory, typarray, typinput FROM pg_type WHERE oid IN (4451, 4532, 4533, 4534, 4535, 4536) ORDER BY oid",
        "int4multirange|-1|m|R|6150|multirange_in;nummultirange|-1|m|R|6151|multirange_in;tsmultirange|-1|m|R|6152|multirange_in;tstzmultirange|-1|m|R|6153|multirange_in;datemultirange|-1|m|R|6155|multirange_in;int8multirange|-1|m|R|6157|multirange_in");
    try rows("SELECT pg_typeof('{}'::int4multirange), format_type(4451, -1), 4536::regtype::text", "int4multirange|int4multirange|int8multirange");
    // Constructors and conversions.
    try rows("SELECT int4multirange(), int4multirange(int4range(1,3)), int4multirange(int4range(5,6), int4range(1,3), 'empty'), nummultirange(numrange(1,2), numrange(1.5,3)), int4multirange(NULL::int4range)", "{}|{[1,3)}|{[1,3),[5,6)}|{[1,3)}|NULL");
    try rejects("SELECT int4multirange(int4range(1,2), NULL)", error.NullValueNotAllowed);
    try rows("SELECT multirange(int4range(1,3)), pg_typeof(multirange(int4range(1,3))), int4range(1,3)::int4multirange, '{[1,3)}'::int4multirange::text, '{[1,2)}'::text::int4multirange, ARRAY['{[1,2)}'::int4multirange]", "{[1,3)}|int4multirange|{[1,3)}|{[1,3)}|{[1,2)}|{\"{[1,2)}\"}");
    try meta(5, 6150, -1);
    // Accessors.
    try rows("SELECT lower('{[1,3),[5,7)}'::int4multirange), upper('{[1,3),[5,7)}'::int4multirange), isempty('{}'::int4multirange), lower_inc('{[1,3)}'::int4multirange), upper_inc('{[1,3)}'::int4multirange), lower_inf('{(,3)}'::int4multirange), upper_inf('{(,3)}'::int4multirange), lower('{}'::int4multirange), range_merge('{[1,3),[5,7)}'::int4multirange)",
        "1|7|t|t|f|t|f|NULL|[1,7)");
    try meta(0, 23, -1);
    try meta(8, 3904, -1);
    try rows("SELECT range_merge(int4range(1,2), int4range(5,7)), range_merge('empty'::int4range, int4range(1,2))", "[1,7)|[1,2)");
    // Operators.
    try rows("SELECT '{[1,3),[5,7)}'::int4multirange @> 2, '{[1,3),[5,7)}'::int4multirange @> 4, 6 <@ '{[1,3),[5,7)}'::int4multirange, '{[1,3),[5,7)}'::int4multirange @> int4range(5,6), '{[1,3),[5,7)}'::int4multirange @> '{[1,2),[5,6)}'::int4multirange, int4range(0,10) @> '{[1,3),[5,7)}'::int4multirange, '{[1,3)}'::int4multirange <@ int4range(0,5), '{[1,3)}'::int4multirange @> NULL::int4",
        "t|f|t|t|t|t|t|NULL");
    try rows("SELECT '{[1,3),[5,7)}'::int4multirange && int4range(3,5), '{[1,3),[5,7)}'::int4multirange && '{[2,3)}'::int4multirange, int4range(6,8) && '{[1,3),[5,7)}'::int4multirange, '{[1,3)}'::int4multirange << '{[5,7)}'::int4multirange, '{[1,3)}'::int4multirange -|- '{[3,7)}'::int4multirange, '{[1,3)}'::int4multirange &< int4range(2,5), '{[1,3)}'::int4multirange &> int4range(2,5)",
        "f|t|t|t|t|t|f");
    try rows("SELECT '{[1,3),[5,7)}'::int4multirange + '{[3,5)}'::int4multirange, '{[1,3),[5,7)}'::int4multirange * '{[2,6)}'::int4multirange, '{[1,10)}'::int4multirange - '{[3,5),[7,8)}'::int4multirange, '{[1,3)}'::int4multirange - '{}'::int4multirange",
        "{[1,7)}|{[2,3),[5,6)}|{[1,3),[5,7),[8,10)}|{[1,3)}");
    try meta(0, 4451, -1);
    try rows("SELECT '{[1,3)}'::int4multirange = '{[1,2],[3,3)}'::int4multirange, '{[1,3)}'::int4multirange < '{[1,4)}'::int4multirange, '{}'::int4multirange < '{[1,2)}'::int4multirange, '{[1,3),[5,7)}'::int4multirange < '{[1,3)}'::int4multirange, '{[1,3)}'::int4multirange <> '{[1,3)}'::int4multirange",
        "t|t|t|f|f");
    try rejects("SELECT int4range(1,5) - '{[2,3)}'::int4multirange", error.UndefinedFunction);
    try rejects("SELECT '{[1,2)}'::int4multirange = '{[1,2)}'::nummultirange", error.UndefinedFunction);
    // Aggregates and unnest; MIN/MAX are not defined over ranges (42883).
    try rows("SELECT range_agg(r), range_intersect_agg(r) FROM (VALUES (int4range(1,3)), (int4range(2,5)), (NULL), (int4range(8,9))) v(r)", "{[1,5),[8,9)}|empty");
    try meta(0, 4451, -1);
    try meta(1, 3904, -1);
    try rows("SELECT range_agg(r) FROM (VALUES (int4range(1,3)), ('empty')) v(r)", "{[1,3)}");
    try rows("SELECT range_agg(m), range_intersect_agg(m) FROM (VALUES ('{[1,3),[5,7)}'::int4multirange), ('{[2,6)}'::int4multirange)) v(m)", "{[1,7)}|{[2,3),[5,6)}");
    try rows("SELECT range_agg(r), range_intersect_agg(r) FROM (VALUES (NULL::int4range)) v(r)", "NULL|NULL");
    try rows("SELECT unnest('{[1,3),[5,7)}'::int4multirange)", "[1,3);[5,7)");
    try meta(0, 3904, -1);
    try rows("SELECT * FROM unnest('{[1,3),[5,7)}'::int4multirange) WITH ORDINALITY", "[1,3)|1;[5,7)|2");
    try rejects("SELECT min(r) FROM (VALUES (int4range(1,3))) v(r)", error.UndefinedFunction);
    // Columns: ordering, grouping and hash consistency; atomicity.
    try exec("CREATE TABLE mr(id INT PRIMARY KEY, m INT4MULTIRANGE, d DATEMULTIRANGE)");
    try exec("INSERT INTO mr VALUES(1, '{[1,3),[5,7)}', '{[2026-01-01,2026-02-01)}'), (2, '{}', NULL), (3, '{[1,2)}', '{}'), (4, NULL, NULL), (5, '{[1,2],[5,6),[6,7)}', NULL)");
    try rows("SELECT m FROM mr ORDER BY m NULLS LAST", "{};{[1,2)};{[1,3),[5,7)};{[1,3),[5,7)};NULL");
    try rows("SELECT m, COUNT(*) FROM mr GROUP BY m ORDER BY m", "{}|1;{[1,2)}|1;{[1,3),[5,7)}|2;NULL|1");
    try rows("SELECT COUNT(DISTINCT m), MIN(id) FROM mr WHERE m @> 6", "1|1");
    try rows("SELECT data_type FROM information_schema.columns WHERE table_name = 'mr' AND column_name = 'm'", "int4multirange");
    try rejects("INSERT INTO mr(id, m) VALUES(6, '{[1,2)}'), (7, '{[2,1)}')", error.DataException);
    try rejects("INSERT INTO mr(id, m) VALUES(6, int4range(1,2))", error.TypeMismatch);
    try rows("SELECT COUNT(*) FROM mr", "5");
    // Wire: int32 count, then each range_send with its length.
    try exec("SELECT '{[1,3),[5,7)}'::int4multirange, '{}'::int4multirange");
    const set_bytes = [_]u8{ 0, 0, 0, 2, 0, 0, 0, 17, 0x02, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 17, 0x02, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 4, 0, 0, 0, 7 };
    try check(Wire.oid(.int4multirange) == 4451 and Wire.length(.int4multirange) == -1);
    try sendBinary(&result.rows[0].cells[0], .int4multirange, &set_bytes);
    try sendBinary(&result.rows[0].cells[1], .int4multirange, &.{ 0, 0, 0, 0 });
    try receive(&set_bytes, .int4multirange, "{[1,3),[5,7)}");
    var out: [64]u8 = undefined;
    try check(if (Wire.receiveText(set_bytes[0..20], .int4multirange, &out)) |_| false else |err| err == error.ProtocolViolation);

    // Durability: change-record value tag 40 (canonical ranges only).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, m INT4MULTIRANGE, n NUMMULTIRANGE, t TSTZMULTIRANGE)",
        "INSERT INTO r VALUES(1, '{[1,3),[5,7)}', '{(1.5,)}', '{[2026-01-01 00:00+00,2026-01-02 00:00+00)}'), (2, '{}', NULL, '{}'), (3, NULL, '{}', NULL)",
        "UPDATE r SET m = m + '{[3,5)}' WHERE id = 1",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|{[1,7)}|{(1.5,)}|{[\"2026-01-01 00:00:00+00\",\"2026-01-02 00:00:00+00\")};2|{}|NULL|{};3|NULL|{}|NULL");
    try meta(1, 4451, -1);
}

// ---- XML publishing -----------------------------------------------------------

fn xmlPublishing() !void {
    db = .{};
    try rows("SELECT xmlelement(name foo), xmlelement(name foo, 'a<b&c>d'), xmlelement(name foo, xmlattributes('x\"y<z&' as a, 1 as b, NULL as c)), xmlelement(name foo, NULL), xmlelement(name \"Foo Bar\", 'x'), xmlelement(name foo, xmlelement(name bar), 'txt', '<a/>'::xml)",
        "<foo/>|<foo>a&lt;b&amp;c&gt;d</foo>|<foo a=\"x&quot;y&lt;z&amp;\" b=\"1\"/>|<foo/>|<Foo_x0020_Bar>x</Foo_x0020_Bar>|<foo><bar/>txt<a/></foo>");
    try meta(0, 142, -1);
    try named(0, "xmlelement");
    try rows("SELECT xmlelement(name foo, true, 1.50, 2::int, '2026-01-02'::date, '2026-01-02 03:04:05.5'::timestamp, 'ab'::bytea, ARRAY[1,2])",
        "<foo>true1.5022026-01-022026-01-02T03:04:05.5YWI=<element>1</element><element>2</element></foo>");
    try rows("SELECT xmlforest('a' as x, NULL as y, 2 as \"Z z\", '<q/>'::xml as w), xmlforest(NULL as n)", "<x>a</x><Z_x0020_z>2</Z_x0020_z><w><q/></w>|NULL");
    try named(0, "xmlforest");
    try exec("CREATE TABLE xt(a INT, b TEXT)");
    try exec("INSERT INTO xt VALUES(1, 'one'), (2, NULL)");
    try rows("SELECT xmlforest(a, b) FROM xt ORDER BY a", "<a>1</a><b>one</b>;<a>2</a>");
    try rows("SELECT xmlelement(name e, xmlattributes(a, b)) FROM xt ORDER BY a", "<e a=\"1\" b=\"one\"/>;<e a=\"2\"/>");
    try rejects("SELECT xmlelement(name e, xmlattributes(1 + 1))", error.Syntax);
    try rejects("SELECT xmlelement(name foo, xmlattributes(1 as a, 2 as a))", error.Syntax);
    try sqlstate(error.Syntax, "42601");
    try rows("SELECT xmlconcat('<a/>', '<b/>'), xmlconcat(NULL, '<b/>'), xmlconcat(NULL, NULL), pg_typeof(xmlconcat('<a/>'))", "<a/><b/>|<b/>|NULL|xml");
    try rejects("SELECT xmlconcat(1)", error.TypeMismatch);
    try rows("SELECT xmlagg(xmlelement(name x, a) ORDER BY a DESC), xmlagg(b::xml) FROM xt", "<x>2</x><x>1</x>|one");
    try meta(0, 142, -1);
    try rows("SELECT xmlagg(x) FROM (SELECT NULL::xml x) s", "NULL");
    try rows("SELECT xmlpi(name php, 'echo \"hi\";'), xmlpi(name foo), xmlpi(name foo, NULL), xmlpi(name foo, '  lead')", "<?php echo \"hi\";?>|<?foo?>|NULL|<?foo lead?>");
    try rejects("SELECT xmlpi(name xml, 'x')", error.InvalidXmlProcessingInstruction);
    try rejects("SELECT xmlpi(name foo, 'a?>b')", error.InvalidXmlProcessingInstruction);
    try sqlstate(error.InvalidXmlProcessingInstruction, "2200T");
    try rows("SELECT xmlcomment('hello'), xmlcomment(NULL), xmlcomment('')", "<!--hello-->|NULL|<!---->");
    try rejects("SELECT xmlcomment('a--b')", error.InvalidXmlComment);
    try rejects("SELECT xmlcomment('a-')", error.InvalidXmlComment);
    try sqlstate(error.InvalidXmlComment, "2200S");
    try rows("SELECT xmlroot('<a/>', version '1.0', standalone yes), xmlroot('<a/>', version no value), xmlroot('<?xml version=\"1.1\"?><a/>', version '1.0', standalone no value), xmlroot(NULL, version '1.0'), xmlroot('<a/>', version NULL, standalone no)",
        "<?xml version=\"1.0\" standalone=\"yes\"?><a/>|<a/>|<a/>|NULL|<?xml version=\"1.0\" standalone=\"no\"?><a/>");
    try named(0, "xmlroot");
    // Durability: published values store as ordinary xml (value tag 27).
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, x XML)",
        "INSERT INTO r VALUES(1, xmlelement(name a, xmlattributes(1 AS n), xmlcomment('c'))), (2, xmlforest(2 AS b))",
    }, &.{"r"}, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|<a n=\"1\"><!--c--></a>;2|<b>2</b>");
}

pub fn main(init: std.process.Init) !void {
    try voidType();
    try arrays();
    try networkTypes();
    try geometry();
    try multiranges();
    try xmlPublishing();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-ext\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
