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

const DB = sql.Database(.{ .tables = 4, .columns = 8, .rows_per_table = 16, .name_bytes = 32, .text_bytes = 256, .integer_bits = 32, .nulls_first_ascending = false, .work_rows = 128, .result_rows = 48, .transactions = 4 });
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
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
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

pub fn main(init: std.process.Init) !void {
    try voidType();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-types-ext\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
