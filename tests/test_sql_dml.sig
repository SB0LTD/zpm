//! General DML contracts (design §5.10-§5.13): multi-row VALUES, INSERT ...
//! SELECT, expression SET, RETURNING over new rows (INSERT/UPDATE) and old
//! rows (DELETE), RETURNING rows emitted exactly once across a park, and
//! atomic failure (a failing statement changes nothing and leaves the
//! caller's result untouched). The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 32, .name_bytes = 16, .text_bytes = 32, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4 });
var assertions: usize = 0;
var db: DB = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("dml contract failed at assertion {d}\n", .{assertions});
        return error.DmlContractFailed;
    }
}

var text_buffer: [4096]u8 = undefined;
/// Rows as `a|b;c|d` with NULL for null cells (PostgreSQL text output).
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

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn expect(source: []const u8, wanted: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try same(try render(&result), wanted);
}

fn names(result: *const DB.Result, wanted: []const []const u8) !void {
    try check(result.column_count == wanted.len);
    for (wanted, 0..) |name, column| try check(std.mem.eql(u8, result.column_names[column].slice(), name));
}

fn autocommit(source: []const u8) !void {
    var result: DB.Result = .{};
    db.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// The error, an untouched result and an unchanged table.
fn rejects(source: []const u8, wanted: anyerror, check_query: []const u8, unchanged: []const u8) !void {
    var result: DB.Result = .{};
    try autocommit("SELECT 7");
    db.execute("SELECT 7", &result) catch unreachable;
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
    try check(result.row_count == 1 and result.column_count == 1 and result.command == .select and result.rows[0].cells[0].integer == 7);
    try expect(check_query, unchanged);
    try empty();
}

fn empty() !void {
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0);
}

fn returning() !void {
    try autocommit("CREATE TABLE compat (id INTEGER PRIMARY KEY, flag BOOLEAN, label TEXT)");
    try autocommit("INSERT INTO compat VALUES (1, TRUE, 'one'), (2, FALSE, NULL), (3, NULL, 'three')");
    try expect("SELECT id, label FROM compat ORDER BY id", "1|one;2|NULL;3|three");
    var result: DB.Result = .{};
    try db.execute("INSERT INTO compat VALUES (4, FALSE, 'four') RETURNING label", &result);
    try check(result.command == .insert and result.affected_rows == 1 and result.row_count == 1);
    try names(&result, &.{"label"});
    try same(try render(&result), "four");
    try db.execute("INSERT INTO compat (label, id) VALUES ('five', 5), ('six', 6) RETURNING id, label, id * 10 AS tens, compat.label || '!'", &result);
    try check(result.affected_rows == 2 and result.column_count == 4);
    try names(&result, &.{ "id", "label", "tens", "?column?" });
    try same(try render(&result), "5|five|50|five!;6|six|60|six!");
    try db.execute("UPDATE compat SET flag = flag WHERE id = 5 RETURNING compat.*", &result);
    try same(try render(&result), "5|NULL|five");
    try db.execute("INSERT INTO compat SELECT id + 10, flag, label FROM compat WHERE id < 3 ORDER BY id DESC RETURNING id, label", &result);
    try check(result.affected_rows == 2);
    try same(try render(&result), "12|NULL;11|one");
    try db.execute("INSERT INTO compat (id, label) SELECT 20, 'literal' RETURNING id, label", &result);
    try same(try render(&result), "20|literal");
    try db.execute("UPDATE compat SET label = label || '+', flag = NOT flag WHERE id > 10 RETURNING id, label, flag", &result);
    try check(result.command == .update and result.affected_rows == 3);
    try same(try render(&result), "12|NULL|t;11|one+|f;20|literal+|NULL");
    try db.execute("DELETE FROM compat WHERE id >= 11 RETURNING *", &result);
    try check(result.command == .delete and result.affected_rows == 3);
    try same(try render(&result), "12|t|NULL;11|f|one+;20|NULL|literal+");
    // No RETURNING: a mutation reports only its count.
    try db.execute("UPDATE compat SET label = 'x' WHERE id = 99", &result);
    try check(result.affected_rows == 0 and result.column_count == 0 and result.row_count == 0);
    db.execute("INSERT INTO compat DEFAULT VALUES RETURNING id", &result) catch |err| try check(err == error.NotNullViolation);
    // Describe reports RETURNING columns without executing.
    try db.describe("DELETE FROM compat WHERE id = 1 RETURNING id, label AS l", &result);
    try check(result.command == .delete and result.row_count == 0);
    try names(&result, &.{ "id", "l" });
    try expect("SELECT COUNT(*) FROM compat", "6");
    try empty();
}

fn atomicity() !void {
    const all = "SELECT id FROM compat ORDER BY id";
    const before = "1;2;3;4;5;6";
    // The third row's key is taken: nothing is inserted, no row returned.
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a'), (8, TRUE, 'b'), (1, TRUE, 'c') RETURNING id", error.PrimaryKeyViolation, all, before);
    // A duplicate inside one statement.
    try rejects("INSERT INTO compat (id) VALUES (9), (9)", error.PrimaryKeyViolation, all, before);
    // A failing RETURNING expression rolls the mutation back.
    try rejects("UPDATE compat SET flag = TRUE RETURNING 10 / (id - 3)", error.DivisionByZero, "SELECT COUNT(*) FROM compat WHERE flag", "1");
    try rejects("DELETE FROM compat RETURNING 1 / (id - 6)", error.DivisionByZero, all, before);
    try rejects("INSERT INTO compat SELECT id, flag, label FROM compat", error.PrimaryKeyViolation, all, before);
    // Arity and DEFAULT placement.
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a'), (8, TRUE)", error.Syntax, all, before);
    try rejects("INSERT INTO compat (id, label) SELECT id FROM compat", error.Syntax, all, before);
    try rejects("SELECT DEFAULT", error.Syntax, all, before);
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a') RETURNING nope", error.ColumnNotFound, all, before);
    try rejects("INSERT INTO compat VALUES (7, TRUE, 'a') RETURNING other.*", error.TableNotFound, all, before);
}

fn run(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{});
    return result;
}

fn parks(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| return error.ExpectedPark else |err| try check(err == error.WouldBlock);
    try check(db.parked(slot));
}

/// RC14 and a parked multi-row INSERT: every row is written and returned
/// exactly once, in order, after the blocker commits.
fn acrossParks() !void {
    try autocommit("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)");
    try autocommit("INSERT INTO t VALUES (1, 0), (2, 0), (3, 0)");
    const a = try db.begin();
    const b = try db.begin();
    _ = try run(a, "UPDATE t SET v = 9 WHERE id = 2");
    const update = "UPDATE t SET v = v + 1 RETURNING id, v";
    try parks(b, update);
    db.publishCommit(a);
    var result: DB.Result = .{};
    try db.statement(b, update, &result, .{ .@"resume" = true });
    try check(result.command == .update and result.affected_rows == 3);
    try same(try render(&result), "1|1;2|10;3|1");
    db.publishCommit(b);
    try expect("SELECT id, v FROM t ORDER BY id", "1|1;2|10;3|1");
    // An uncommitted insert of key 5 parks the second row of a multi-row
    // INSERT; on resume row 4 is not inserted twice.
    const c = try db.begin();
    const d = try db.begin();
    _ = try run(c, "INSERT INTO t VALUES (5, 50)");
    const insert = "INSERT INTO t VALUES (4, 40), (5, 41), (6, 60) RETURNING id, v";
    try parks(d, insert);
    db.abort(c);
    try db.statement(d, insert, &result, .{ .@"resume" = true });
    try check(result.command == .insert and result.affected_rows == 3);
    try same(try render(&result), "4|40;5|41;6|60");
    db.publishCommit(d);
    try expect("SELECT id, v FROM t WHERE id > 3 ORDER BY id", "4|40;5|41;6|60");
    // DELETE RETURNING across a park returns the deleted rows' old values.
    const e = try db.begin();
    const f = try db.begin();
    _ = try run(e, "UPDATE t SET v = 99 WHERE id = 5");
    const delete = "DELETE FROM t WHERE id > 3 RETURNING id, v";
    try parks(f, delete);
    db.publishCommit(e);
    try db.statement(f, delete, &result, .{ .@"resume" = true });
    try same(try render(&result), "4|40;5|99;6|60");
    db.publishCommit(f);
    try expect("SELECT COUNT(*) FROM t", "3");
    try empty();
}

fn rejectsOnly(source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
    try empty();
}

/// CREATE SEQUENCE, nextval/currval/setval/lastval, bounds, CYCLE, option
/// errors and non-transactional values (design §5.12/§5.13).
fn sequences() !void {
    try rejectsOnly("SELECT currval('s')", error.TableNotFound);
    try autocommit("CREATE SEQUENCE s");
    try rejectsOnly("SELECT currval('s')", error.SequenceNotReady);
    try rejectsOnly("SELECT lastval()", error.SequenceNotReady);
    try expect("SELECT nextval('s')", "1");
    try expect("SELECT nextval('s'), nextval('s')", "2|3");
    try expect("SELECT currval('s'), lastval()", "3|3");
    try expect("SELECT setval('s', 10)", "10");
    try expect("SELECT nextval('S'), nextval('public.s')", "11|12");
    try expect("SELECT setval('s', 20, false), nextval('s')", "20|20");
    try rejectsOnly("SELECT setval('s', 0)", error.NumericValueOutOfRange);
    try autocommit("CREATE SEQUENCE m MAXVALUE 2");
    try expect("SELECT nextval('m'), nextval('m')", "1|2");
    try rejectsOnly("SELECT nextval('m')", error.SequenceLimit);
    try autocommit("CREATE SEQUENCE c MINVALUE 1 MAXVALUE 2 CYCLE");
    try expect("SELECT nextval('c'), nextval('c'), nextval('c')", "1|2|1");
    try autocommit("CREATE SEQUENCE d INCREMENT BY -2 START WITH -1");
    try expect("SELECT nextval('d'), nextval('d')", "-1|-3");
    try rejectsOnly("CREATE SEQUENCE z CACHE 5", error.UnsupportedStatement);
    try rejectsOnly("CREATE SEQUENCE z INCREMENT 0", error.InvalidParameterValue);
    try rejectsOnly("CREATE SEQUENCE z MINVALUE 5 MAXVALUE 5", error.InvalidParameterValue);
    try rejectsOnly("CREATE SEQUENCE z START 100 MAXVALUE 10", error.InvalidParameterValue);
    try rejectsOnly("CREATE SEQUENCE s", error.TableExists);
    try rejectsOnly("CREATE TABLE s (id INTEGER)", error.TableExists);
    try rejectsOnly("SELECT nextval('compat')", error.WrongObjectType);
    try rejectsOnly("DROP TABLE s", error.WrongObjectType);
    try rejectsOnly("DROP SEQUENCE compat", error.WrongObjectType);
    // Values are never rolled back.
    const slot = try db.begin();
    _ = try run(slot, "SELECT nextval('s')");
    _ = try run(slot, "CREATE SEQUENCE inner_seq");
    try check((try run(slot, "SELECT nextval('inner_seq')")).rows[0].cells[0].integer == 1);
    db.abort(slot);
    try expect("SELECT nextval('s')", "22");
    try rejectsOnly("SELECT nextval('inner_seq')", error.TableNotFound);
    var result: DB.Result = .{};
    try db.execute("DROP SEQUENCE m", &result);
    try check(result.command == .drop_sequence);
    try rejectsOnly("SELECT nextval('m')", error.TableNotFound);
    try autocommit("DROP SEQUENCE c");
    try autocommit("DROP SEQUENCE d");
}

fn defaults() !void {
    try autocommit("CREATE TABLE d (id INTEGER PRIMARY KEY, label TEXT DEFAULT 'default', n INTEGER DEFAULT 2 + 3 NOT NULL, flag BOOLEAN DEFAULT TRUE)");
    try expect("INSERT INTO d (id) VALUES (1) RETURNING *", "1|default|5|t");
    try expect("INSERT INTO d VALUES (2, DEFAULT, 7, DEFAULT), (3, 'x', DEFAULT, NULL) RETURNING *", "2|default|7|t;3|x|5|NULL");
    try expect("UPDATE d SET label = DEFAULT, n = n * 2 WHERE id = 3 RETURNING label, n", "default|10");
    try rejectsOnly("UPDATE d SET n = NULL", error.NotNullViolation);
    try autocommit("CREATE TABLE nn (id INTEGER PRIMARY KEY, v TEXT NOT NULL DEFAULT NULL, w INTEGER DEFAULT nextval('s'))");
    try rejectsOnly("INSERT INTO nn (id) VALUES (1)", error.NotNullViolation);
    try expect("INSERT INTO nn (id, v) VALUES (1, 'a') RETURNING w", "23");
    try rejectsOnly("CREATE TABLE bad (id INTEGER DEFAULT 'abc')", error.InvalidTextRepresentation);

    try autocommit("DROP TABLE nn");
    try autocommit("DROP TABLE d");
}

fn identity() !void {
    try autocommit("CREATE TABLE ident (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, label TEXT)");
    var result: DB.Result = .{};
    try db.execute("INSERT INTO ident (label) VALUES ('generated') RETURNING id", &result);
    try names(&result, &.{"id"});
    try same(try render(&result), "1");
    try expect("INSERT INTO ident (label) VALUES ('b'), ('c') RETURNING id", "2;3");
    try rejectsOnly("INSERT INTO ident VALUES (10, 'x')", error.GeneratedAlways);
    try rejectsOnly("INSERT INTO ident (id, label) SELECT 10, 'x'", error.GeneratedAlways);
    try expect("INSERT INTO ident OVERRIDING SYSTEM VALUE VALUES (10, 'x') RETURNING id", "10");
    try expect("INSERT INTO ident OVERRIDING USER VALUE VALUES (99, 'y') RETURNING id", "4");
    try expect("INSERT INTO ident DEFAULT VALUES RETURNING id, label", "5|NULL");
    try rejectsOnly("UPDATE ident SET id = 50", error.GeneratedAlways);
    try expect("UPDATE ident SET id = DEFAULT WHERE id = 10 RETURNING id", "6");
    // A rolled-back insert leaves a gap.
    const slot = try db.begin();
    _ = try run(slot, "INSERT INTO ident (label) VALUES ('gone')");
    db.abort(slot);
    try expect("INSERT INTO ident (label) VALUES ('kept') RETURNING id", "8");
    try expect("SELECT currval('ident_id_seq'), lastval()", "8|8");
    try rejectsOnly("DROP SEQUENCE ident_id_seq", error.DependentObjects);
    try autocommit("CREATE TABLE byd (id BIGINT GENERATED BY DEFAULT AS IDENTITY (START WITH 100 INCREMENT BY 10), v INTEGER)");
    try expect("INSERT INTO byd (v) VALUES (1) RETURNING id", "100");
    try expect("INSERT INTO byd VALUES (5, 2) RETURNING id", "5");
    try expect("INSERT INTO byd OVERRIDING USER VALUE VALUES (5, 3) RETURNING id", "110");
    try rejectsOnly("CREATE TABLE badid (id TEXT GENERATED ALWAYS AS IDENTITY)", error.TypeMismatch);
    try autocommit("DROP TABLE byd");
    try rejectsOnly("SELECT nextval('byd_id_seq')", error.TableNotFound);
    try autocommit("DROP TABLE ident");
    try rejectsOnly("SELECT nextval('ident_id_seq')", error.TableNotFound);
    try autocommit("CREATE TABLE ident (id INTEGER GENERATED ALWAYS AS IDENTITY, label TEXT)");
    try expect("INSERT INTO ident (label) VALUES ('again') RETURNING id", "1");
    try autocommit("DROP TABLE ident");
}

fn generated() !void {
    try autocommit("CREATE TABLE g (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) STORED)");
    try expect("INSERT INTO g (id, a) VALUES (1, 5) RETURNING b", "10");
    try rejectsOnly("INSERT INTO g VALUES (2, 1, 3)", error.GeneratedAlways);
    try expect("INSERT INTO g VALUES (2, 1, DEFAULT) RETURNING *", "2|1|2");
    try expect("UPDATE g SET a = 7 WHERE id = 1 RETURNING b", "14");
    try rejectsOnly("UPDATE g SET b = 1", error.GeneratedAlways);
    try expect("SELECT id, a, b FROM g ORDER BY id", "1|7|14;2|1|2");
    try autocommit("DROP TABLE g");
}

/// ON CONFLICT (design §5.11): DO NOTHING, DO UPDATE with EXCLUDED and
/// WHERE, ON CONSTRAINT, 21000 for a row hit twice, 42P10/42704/42601,
/// conflicts with the newest committed or own version, waits for an
/// in-progress inserter or deleter and re-checks on resume.
fn upsert() !void {
    try autocommit("CREATE TABLE u (id INTEGER PRIMARY KEY, label TEXT, n INTEGER)");
    try autocommit("INSERT INTO u VALUES (1, 'one', 1), (2, 'two', 2)");
    try expect("INSERT INTO u VALUES (1, 'upsert', 9) ON CONFLICT (id) DO UPDATE SET label = EXCLUDED.label RETURNING label", "upsert");
    var result: DB.Result = .{};
    try db.execute("INSERT INTO u VALUES (2, 'x', 0), (3, 'three', 3) ON CONFLICT DO NOTHING RETURNING id", &result);
    try check(result.affected_rows == 1 and result.command == .insert);
    try same(try render(&result), "3");
    try expect("INSERT INTO u AS t VALUES (2, 'b', 5) ON CONFLICT ON CONSTRAINT u_pkey DO UPDATE SET n = t.n + EXCLUDED.n, label = t.label || EXCLUDED.label RETURNING *", "2|twob|7");
    try db.execute("INSERT INTO u VALUES (3, 'z', 0) ON CONFLICT (id) DO UPDATE SET label = 'never' WHERE u.n > 100 RETURNING id", &result);
    try check(result.affected_rows == 0 and result.row_count == 0);
    try expect("INSERT INTO u VALUES (4, 'a', 1), (4, 'b', 2) ON CONFLICT DO NOTHING RETURNING label", "a");
    try rejectsOnly("INSERT INTO u VALUES (5, 'a', 1), (5, 'b', 2) ON CONFLICT (id) DO UPDATE SET n = EXCLUDED.n", error.CardinalityViolation);
    try rejectsOnly("INSERT INTO u VALUES (1, 'a', 1) ON CONFLICT (label) DO NOTHING", error.InvalidColumnReference);
    try rejectsOnly("INSERT INTO u VALUES (1, 'a', 1) ON CONFLICT ON CONSTRAINT nope DO NOTHING", error.UndefinedObject);
    try rejectsOnly("INSERT INTO u VALUES (1, 'a', 1) ON CONFLICT DO UPDATE SET n = 1", error.Syntax);
    try rejectsOnly("INSERT INTO u VALUES (1, 'a', 1) ON CONFLICT (id) DO UPDATE SET n = excluded.nope", error.ColumnNotFound);
    try rejectsOnly("INSERT INTO u VALUES (1, 'a', 1) ON CONFLICT (id) DO UPDATE SET label = label", error.AmbiguousColumn);
    try expect("INSERT INTO u SELECT id, 'copy', n * 10 FROM u WHERE id <= 2 ON CONFLICT (id) DO UPDATE SET n = EXCLUDED.n RETURNING id, n", "1|10;2|70");
    try expect("SELECT id, label, n FROM u ORDER BY id", "1|upsert|10;2|twob|70;3|three|3;4|a|1");
    // Own uncommitted rows conflict; a later statement may update them.
    const a = try db.begin();
    _ = try run(a, "INSERT INTO u VALUES (6, 'mine', 0)");
    const own = try run(a, "INSERT INTO u VALUES (6, 'again', 1) ON CONFLICT (id) DO UPDATE SET n = u.n + 1 RETURNING n");
    try check(own.row_count == 1 and own.rows[0].cells[0].integer == 1);
    // A second transaction waits for the in-progress inserter, then updates.
    const b = try db.begin();
    const wait_insert = "INSERT INTO u VALUES (6, 'b', 10) ON CONFLICT (id) DO UPDATE SET n = u.n + EXCLUDED.n RETURNING n";
    try parks(b, wait_insert);
    db.publishCommit(a);
    try db.statement(b, wait_insert, &result, .{ .@"resume" = true });
    try check(result.affected_rows == 1);
    try same(try render(&result), "11");
    db.publishCommit(b);
    // Inserter rolls back: the waiter inserts.
    const c = try db.begin();
    const d = try db.begin();
    _ = try run(c, "INSERT INTO u VALUES (7, 'c', 1)");
    const rolled = "INSERT INTO u VALUES (7, 'd', 2) ON CONFLICT (id) DO UPDATE SET n = 99 RETURNING label, n";
    try parks(d, rolled);
    db.abort(c);
    try db.statement(d, rolled, &result, .{ .@"resume" = true });
    try same(try render(&result), "d|2");
    db.publishCommit(d);
    // A deleter commits: the waiter inserts a new row.
    const e = try db.begin();
    const f = try db.begin();
    _ = try run(e, "DELETE FROM u WHERE id = 1");
    const deleted = "INSERT INTO u VALUES (1, 'new', 5) ON CONFLICT (id) DO UPDATE SET n = 99 RETURNING label, n";
    try parks(f, deleted);
    db.publishCommit(e);
    try db.statement(f, deleted, &result, .{ .@"resume" = true });
    try same(try render(&result), "new|5");
    db.publishCommit(f);
    // Different keys never wait.
    const g = try db.begin();
    const h = try db.begin();
    _ = try run(g, "INSERT INTO u VALUES (20, 'g', 1) ON CONFLICT (id) DO UPDATE SET n = 0");
    _ = try run(h, "INSERT INTO u VALUES (21, 'h', 1) ON CONFLICT (id) DO UPDATE SET n = 0");
    db.publishCommit(g);
    db.publishCommit(h);
    try expect("SELECT id, n FROM u WHERE id IN (1, 6, 7, 20, 21) ORDER BY id", "1|5;6|11;7|2;20|1;21|1");
    try empty();
    try autocommit("DROP TABLE u");
}

var primary: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;

/// Executes on `primary` and replays its change record (if any) on `replica`.
fn replicated(source: []const u8) !usize {
    var result: DB.Result = .{};
    var used: usize = 0;
    try primary.executeChanges(source, &result, &record, &used, null, null);
    if (used != 0) try replica.applyChangeRecord(record[0..used], &scratch);
    return used;
}

fn value(target: *DB, source: []const u8) !i64 {
    var result: DB.Result = .{};
    try target.execute(source, &result);
    return result.rows[0].cells[0].integer;
}

/// Change records carry identity/sequence definitions and log-ahead values
/// (SEQ_LOG_VALS = 32), a read-only SELECT writes no record, a SELECT that
/// advances a sequence does, and an aborted transaction's log-ahead value
/// is carried into the next record.
fn durability() !void {
    _ = try replicated("CREATE TABLE ident (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, label TEXT DEFAULT 'd', twice INTEGER GENERATED ALWAYS AS (id * 2) STORED)");
    for (0..3) |_| _ = try replicated("INSERT INTO ident (label) VALUES ('x')");
    try check(try value(&replica, "SELECT COUNT(*) FROM ident") == 3);
    try check(try value(&replica, "INSERT INTO ident DEFAULT VALUES RETURNING id") == 34);
    try check(try value(&replica, "SELECT twice FROM ident WHERE id = 34") == 68);
    try check(try value(&primary, "INSERT INTO ident DEFAULT VALUES RETURNING id") == 4);
    try check(try replicated("SELECT 1") == 0);
    _ = try replicated("CREATE SEQUENCE s");
    try check(try replicated("SELECT nextval('s')") != 0);
    try check(try value(&replica, "SELECT nextval('s')") == 34);
    // Carried: the aborted transaction's log-ahead value rides on the next
    // record written by anyone, here a plain SELECT.
    _ = try replicated("CREATE SEQUENCE t");
    const slot = try primary.begin();
    var result: DB.Result = .{};
    try primary.statement(slot, "SELECT nextval('t')", &result, .{});
    primary.abort(slot);
    const probe = try primary.begin();
    try check(!primary.readOnly(probe));
    primary.abort(probe);
    try check(try replicated("SELECT 2") != 0);
    try check(try replicated("SELECT 3") == 0);
    try check(try value(&replica, "SELECT nextval('t')") == 34);
    _ = try replicated("SELECT setval('s', 500)");
    try check(try value(&replica, "SELECT nextval('s')") == 501);
    _ = try replicated("DROP SEQUENCE s");
    _ = try replicated("DROP TABLE ident");
    try check(replica.catalog.find("ident_id_seq", .{ .csn = replica.csn }) == null);
    try check(replica.tableCount() == 0);
}

/// A transaction may consume another live transaction's log-ahead cache.
/// Its acknowledged commit must carry that watermark before the owner ends.
fn concurrentSequenceWatermarks() !void {
    for ([_]bool{ false, true }) |descending| {
        primary = .{};
        replica = .{};
        _ = try replicated(if (descending) "CREATE SEQUENCE shared INCREMENT BY -1" else "CREATE SEQUENCE shared");
        const owner = try primary.begin();
        var result: DB.Result = .{};
        try primary.statement(owner, "SELECT nextval('shared')", &result, .{});
        try check(result.rows[0].cells[0].integer == (if (descending) @as(i64, -1) else 1));
        // owner stays live; this consumer commits a value from its cache.
        const bytes = try replicated("SELECT nextval('shared')");
        const recovered = try value(&replica, "SELECT nextval('shared')");
        const committed: i64 = if (descending) -2 else 2;
        if (!(if (descending) recovered < committed else recovered > committed)) {
            std.debug.print("sequence replay can reissue an acknowledged value: consumer={d}, replay starts={d}, WAL bytes={d}\n", .{ committed, recovered, bytes });
            return error.LostConcurrentSequenceWatermark;
        }
        try check(bytes != 0);
        // Once the shared watermark is durable, later cache hits keep the
        // no-record path even while the original owner is still active.
        try check(try replicated("SELECT nextval('shared')") == 0);
        primary.abort(owner);
        _ = try replicated("SELECT 1");
        try check(try replicated("SELECT 2") == 0);
    }
    // An unrelated commit cannot persist a pending CREATE's definition,
    // but must not erase the creator's own obligation to persist it later.
    primary = .{};
    replica = .{};
    const creator = try primary.begin();
    var result: DB.Result = .{};
    try primary.statement(creator, "CREATE SEQUENCE private_seq", &result, .{});
    try primary.statement(creator, "SELECT nextval('private_seq')", &result, .{});
    _ = try replicated("SELECT 1");
    const payload = try primary.prepareCommit(creator, &record);
    try replica.applyChangeRecord(payload, &scratch);
    primary.publishCommit(creator);
    try check(try value(&replica, "SELECT nextval('private_seq')") == 34);
}

pub fn main(init: std.process.Init) !void {
    try returning();
    try atomicity();
    try acrossParks();
    try sequences();
    try defaults();
    try identity();
    try generated();
    try upsert();
    try durability();
    try concurrentSequenceWatermarks();
    var buffer: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-dml\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d}}}\n", .{ assertions, DB.storageBytes() });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
