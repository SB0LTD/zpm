//! Nested statement contracts (conformance lane B11, wave 4,
//! docs/SQL_NESTED_STATEMENTS.md): SQL statements that run inside an
//! executing statement. SQL in PL/pgSQL trigger functions and in SQL and
//! PL/pgSQL functions called from expressions, with PostgreSQL's command-id
//! and snapshot rules (a volatile routine sees every earlier change of its
//! transaction, a STABLE one its caller's snapshot), bounded nesting
//! (54001), atomicity, a lock wait that restarts the whole statement so no
//! trigger effect repeats, work control and capacity; INSTEAD OF triggers,
//! auto-updatable views, rule actions and the trigger extras build on it.
//! Each section checks values (PostgreSQL 18 text output), command tags,
//! exact errors (SQLSTATE through the error name), atomicity after a failure
//! and replay: every committed record is applied to a replica that must
//! answer every probe exactly like the primary. Expected values were checked
//! against native PostgreSQL 18.7. The assertion counter proves this suite
//! ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 16, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 4, .expr_nodes = 512, .routines = 16, .triggers = 12, .rules = 16, .routine_depth = 32, .nested_statements = 8, .work_rows = 256 });
/// A small workspace: the saved statements do not fit (54000).
const Small = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 32, .nulls_first_ascending = false, .integer_bits = 32, .expr_nodes = 256, .routines = 4, .triggers = 2, .rules = 1, .nested_statements = 8 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var small: Small = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var crafted: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("nested statements contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.NestedStatementsContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
var query_values: [DB.Result.value_bytes]u8 = undefined;
var result_slot: DB.Result = .{};
var other_slot: DB.Result = .{};

/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
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

fn query(target: *DB, source: []const u8) ![]const u8 {
    const result = &result_slot;
    result.* = .{};
    result.bindValueMemory(&query_values);
    target.execute(source, result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !*DB.Result {
    const result = &result_slot;
    result.* = .{};
    result.bindValueMemory(&query_values);
    var used: usize = 0;
    db.executeChanges(source, result, &record, &used, null, null) catch |err| {
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

/// The replicated statement returns these rows.
fn returns(source: []const u8, wanted: []const u8) !void {
    try same(try render(try replicate(source)), wanted);
}

/// The statement completes with this command tag and affected count.
fn completes(source: []const u8, tag: sql.CommandTag, affected: usize) !void {
    const result = try replicate(source);
    if (result.command != tag or result.affected_rows != affected) std.debug.print("{s}: {s} {d}\n", .{ source, @tagName(result.command), result.affected_rows });
    try check(result.command == tag and result.affected_rows == affected);
}

/// The autocommit statement fails with `wanted`; the probe answers
/// `unchanged` afterwards (atomicity) on primary and replica.
fn rejects(source: []const u8, wanted: anyerror, probe: []const u8, unchanged: []const u8) !void {
    const result = &other_slot;
    result.* = .{};
    var used: usize = 0;
    if (db.executeChanges(source, result, &record, &used, null, null)) |_| {
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

/// rejects() whose error carries PostgreSQL's errdetail (lastErrorDetail).
fn rejectsDetail(source: []const u8, wanted: anyerror, detail: []const u8, probe: []const u8, unchanged: []const u8) !void {
    const result = &other_slot;
    result.* = .{};
    var used: usize = 0;
    if (db.executeChanges(source, result, &record, &used, null, null)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try same(db.lastErrorDetail(), detail);
    try check(used == 0);
    try same(try query(&db, probe), unchanged);
    try same(try query(&replica, probe), unchanged);
    try idle();
}

fn fails(source: []const u8, wanted: anyerror) !void {
    try rejects(source, wanted, "SELECT 1", "1");
}

fn statement(slot: u16, source: []const u8) !void {
    const result = &other_slot;
    result.* = .{};
    db.statement(slot, source, result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rows(slot: u16, source: []const u8) ![]const u8 {
    const result = &other_slot;
    result.* = .{};
    db.statement(slot, source, result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(result);
}

fn statementFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    const result = &other_slot;
    result.* = .{};
    if (db.statement(slot, source, result, .{})) |_| {
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

fn resumed(slot: u16, source: []const u8) ![]const u8 {
    const result = &other_slot;
    result.* = .{};
    try db.statement(slot, source, result, .{ .@"resume" = true });
    return render(result);
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

var copy_buffer: [16384]u8 = undefined;

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        @memcpy(copy_buffer[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy_buffer[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy_buffer[0..left.len], right });
        try check(std.mem.eql(u8, copy_buffer[0..left.len], right));
    }
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

fn reset() void {
    db = .{};
    replica = .{};
}

fn idle() !void {
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0);
}

// ---- SQL in trigger functions ------------------------------------------------

/// A trigger function's statements see the rows its statement wrote so
/// far (each nested statement takes a new command id); AFTER ROW triggers
/// see all of them; statement triggers run SQL too.
fn triggerStatements() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("CREATE TABLE log (n INT, what TEXT)");
    try run("CREATE FUNCTION trg() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log SELECT count(*), TG_OP || ':' || coalesce(NEW.id, OLD.id) FROM t; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END$$");
    try run("CREATE TRIGGER b BEFORE INSERT OR UPDATE OR DELETE ON t FOR EACH ROW EXECUTE FUNCTION trg()");
    try completes("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')", .insert, 3);
    try expect("SELECT * FROM log ORDER BY n, what", "0|INSERT:1;1|INSERT:2;2|INSERT:3");
    try completes("UPDATE t SET v = v || '!' WHERE id >= 2", .update, 2);
    try expect("SELECT * FROM log ORDER BY n, what", "0|INSERT:1;1|INSERT:2;2|INSERT:3;3|UPDATE:2;3|UPDATE:3");
    try completes("DELETE FROM t WHERE id = 1", .delete, 1);
    try expect("SELECT * FROM log ORDER BY n, what", "0|INSERT:1;1|INSERT:2;2|INSERT:3;3|DELETE:1;3|UPDATE:2;3|UPDATE:3");
    try expect("SELECT * FROM t ORDER BY id", "2|b!;3|c!");
    try run("CREATE FUNCTION af() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log SELECT count(*), 'after:' || NEW.id FROM t; RETURN NULL; END$$");
    try run("CREATE TRIGGER a AFTER INSERT ON t FOR EACH ROW EXECUTE FUNCTION af()");
    try returns("INSERT INTO t VALUES (4,'d'),(5,'e') RETURNING id, v", "4|d;5|e");
    try expect("SELECT * FROM log ORDER BY n, what", "0|INSERT:1;1|INSERT:2;2|INSERT:3;2|INSERT:4;3|DELETE:1;3|INSERT:5;3|UPDATE:2;3|UPDATE:3;4|after:4;4|after:5");
    try run("CREATE FUNCTION st() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log SELECT count(*), 'stmt:' || TG_WHEN || ':' || TG_OP FROM t; RETURN NULL; END$$");
    try run("CREATE TRIGGER s1 BEFORE UPDATE ON t FOR EACH STATEMENT EXECUTE FUNCTION st()");
    try run("CREATE TRIGGER s2 AFTER UPDATE ON t FOR EACH STATEMENT EXECUTE FUNCTION st()");
    try completes("UPDATE t SET v = 'z' WHERE id = 99", .update, 0);
    try expect("SELECT * FROM log WHERE what LIKE 'stmt%' ORDER BY what", "4|stmt:AFTER:UPDATE;4|stmt:BEFORE:UPDATE");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY n, what" });
    try idle();
}

// ---- SQL in functions called from expressions ----------------------------------

/// Volatile functions see their own and every earlier change (each call
/// and each statement a new command id); STABLE ones the caller's snapshot
/// and cannot write (0A000); PL/pgSQL SELECT INTO, FOUND, GET DIAGNOSTICS,
/// PERFORM, table-reading expressions and EXCEPTION blocks.
fn functionStatements() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')");
    try run("CREATE TABLE log (n INT, what TEXT)");
    try run("CREATE FUNCTION cnt() RETURNS BIGINT LANGUAGE SQL AS $$INSERT INTO log VALUES (99, 'cnt'); SELECT count(*) FROM log$$");
    // One call per row, in the query engine, each seeing the earlier calls.
    try returns("SELECT id, cnt() FROM t ORDER BY id", "1|1;2|2;3|3");
    try returns("SELECT id, cnt() FROM t", "1|4;2|5;3|6");
    try expect("SELECT count(*) FROM log", "6");
    try run("CREATE FUNCTION vcount() RETURNS BIGINT LANGUAGE SQL AS $$SELECT count(*) FROM t WHERE v LIKE 'x%'$$");
    try run("CREATE FUNCTION scount() RETURNS BIGINT STABLE LANGUAGE SQL AS $$SELECT count(*) FROM t WHERE v LIKE 'x%'$$");
    // A volatile function sees the rows its UPDATE changed so far; a
    // STABLE one the UPDATE's own snapshot.
    try completes("UPDATE t SET v = 'x' || vcount() WHERE id <= 3", .update, 3);
    try expect("SELECT * FROM t ORDER BY id", "1|x0;2|x1;3|x2");
    try completes("UPDATE t SET v = 'y' || scount()", .update, 3);
    try expect("SELECT * FROM t ORDER BY id", "1|y3;2|y3;3|y3");
    // Non-volatile functions cannot write or lock (0A000), atomically.
    try run("CREATE FUNCTION sins() RETURNS INT STABLE LANGUAGE SQL AS $$INSERT INTO log VALUES (1,'s'); SELECT 1$$");
    try rejects("SELECT sins()", error.UnsupportedStatement, "SELECT count(*) FROM log", "6");
    try run("CREATE FUNCTION pins() RETURNS INT STABLE LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (1,'s'); RETURN 1; END$$");
    try rejects("SELECT pins()", error.UnsupportedStatement, "SELECT count(*) FROM log", "6");
    try run("CREATE FUNCTION supd() RETURNS INT STABLE LANGUAGE plpgsql AS $$BEGIN PERFORM 1 FROM t FOR UPDATE; RETURN 1; END$$");
    try rejects("SELECT supd()", error.UnsupportedStatement, "SELECT count(*) FROM log", "6");
    try run("CREATE FUNCTION iread() RETURNS BIGINT IMMUTABLE LANGUAGE SQL AS $$SELECT count(*) FROM t$$");
    try returns("SELECT iread()", "3");
    // PL/pgSQL statements: SELECT INTO / FOUND / GET DIAGNOSTICS / PERFORM.
    try run("CREATE FUNCTION pl(k INT) RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE r TEXT; n INT; BEGIN SELECT v INTO r FROM t WHERE id = k; IF NOT FOUND THEN INSERT INTO t VALUES (k, 'new'); GET DIAGNOSTICS n = ROW_COUNT; RETURN 'inserted ' || n; END IF; UPDATE t SET v = v || '+' WHERE id = k; PERFORM * FROM t WHERE id > k; RETURN r || ' found=' || FOUND; END$$");
    try returns("SELECT pl(1), pl(7), pl(3)", "y3 found=true|inserted 1|y3 found=true");
    try expect("SELECT * FROM t ORDER BY id", "1|y3+;2|y3;3|y3+;7|new");
    // An EXCEPTION block undoes its nested writes and handles the error.
    try run("CREATE FUNCTION safe(k INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES (k, 'dup'); RETURN 1; EXCEPTION WHEN unique_violation THEN INSERT INTO log VALUES (k, 'dup'); RETURN -1; END$$");
    try returns("SELECT safe(1), safe(9)", "-1|1");
    try expect("SELECT * FROM t ORDER BY id", "1|y3+;2|y3;3|y3+;7|new;9|dup");
    try expect("SELECT * FROM log WHERE what = 'dup'", "1|dup");
    try run("DELETE FROM t WHERE id = 9");
    try run("CREATE FUNCTION strict_into() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE r TEXT; BEGIN SELECT v INTO STRICT r FROM t; RETURN r; END$$");
    try fails("SELECT strict_into()", error.TooManyRows);
    // Expressions that read tables run as SELECT statements.
    try run("CREATE FUNCTION exists_check(k INT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$BEGIN IF EXISTS (SELECT 1 FROM t WHERE id = k) THEN RETURN true; END IF; RETURN false; END$$");
    try returns("SELECT exists_check(1), exists_check(42)", "t|f");
    try run("CREATE FUNCTION total() RETURNS BIGINT LANGUAGE plpgsql AS $$DECLARE n BIGINT; BEGIN n := (SELECT count(*) FROM t) + 100; RETURN n; END$$");
    try returns("SELECT total()", "104");
    // A writing function in a DELETE's WHERE runs once per row read.
    try run("CREATE FUNCTION note(k INT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (k, 'note'); RETURN k > 2; END$$");
    try completes("DELETE FROM t WHERE note(id)", .delete, 2);
    try expect("SELECT * FROM t ORDER BY id", "1|y3+;2|y3");
    try expect("SELECT n, what FROM log WHERE what = 'note' ORDER BY n", "1|note;2|note;3|note;7|note");
    // A failure after a nested write undoes the whole statement.
    try run("CREATE FUNCTION boom() RETURNS INT LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (0, 'boom'); RETURN 1/0; END$$");
    try rejects("SELECT boom()", error.DivisionByZero, "SELECT count(*) FROM log WHERE what = 'boom'", "0");
    try rejects("INSERT INTO t SELECT 5, boom()::text", error.DivisionByZero, "SELECT count(*) FROM log WHERE what = 'boom'", "0");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY n, what" });
    try idle();
}

// ---- rules of a nested statement ------------------------------------------------

/// A row a BEFORE trigger's statement already changed cannot be updated by
/// the statement that fired it (27000); recursion is 54001; both atomic.
fn nestingLimits() !void {
    reset();
    try run("CREATE TABLE u (id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO u VALUES (1, 0), (2, 0)");
    try run("CREATE FUNCTION bump() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN UPDATE u SET v = v + 10 WHERE id = 2; RETURN NEW; END$$");
    try run("CREATE TRIGGER ub BEFORE UPDATE ON u FOR EACH ROW WHEN (OLD.id = 1) EXECUTE FUNCTION bump()");
    try rejects("UPDATE u SET v = v + 1", error.TriggeredDataChangeViolation, "SELECT * FROM u ORDER BY id", "1|0;2|0");
    // The same change from an AFTER trigger is fine.
    try run("DROP TRIGGER ub ON u");
    try run("CREATE FUNCTION abump() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN UPDATE u SET v = v + 10 WHERE id = 2 AND OLD.id = 1; RETURN NULL; END$$");
    try run("CREATE TRIGGER ua AFTER UPDATE ON u FOR EACH ROW EXECUTE FUNCTION abump()");
    try completes("UPDATE u SET v = v + 1", .update, 2);
    try expect("SELECT * FROM u ORDER BY id", "1|1;2|11");
    // Runaway recursion through a trigger or a function: 54001.
    try run("CREATE TABLE r (n INT)");
    try run("CREATE FUNCTION rec() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO r VALUES (NEW.n + 1); RETURN NEW; END$$");
    try run("CREATE TRIGGER rt BEFORE INSERT ON r FOR EACH ROW EXECUTE FUNCTION rec()");
    try rejects("INSERT INTO r VALUES (1)", error.StackDepthExceeded, "SELECT count(*) FROM r", "0");
    try run("CREATE FUNCTION rf(n INT) RETURNS INT LANGUAGE plpgsql AS $$DECLARE x INT; BEGIN INSERT INTO r VALUES (-n); SELECT rf(n + 1) INTO x; RETURN x; END$$");
    try run("DROP TRIGGER rt ON r");
    try rejects("SELECT rf(1)", error.StackDepthExceeded, "SELECT count(*) FROM r", "0");
    // Bounded recursion that stops works.
    try run("CREATE FUNCTION chain() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.n < 5 THEN INSERT INTO r VALUES (NEW.n + 1); END IF; RETURN NEW; END$$");
    try run("CREATE TRIGGER rc AFTER INSERT ON r FOR EACH ROW EXECUTE FUNCTION chain()");
    try completes("INSERT INTO r VALUES (1)", .insert, 1);
    try expect("SELECT n FROM r ORDER BY n", "1;2;3;4;5");
    try sameState(&.{ "SELECT * FROM u ORDER BY id", "SELECT n FROM r ORDER BY n" });
    try idle();
}

// ---- lock waits, isolation, work control, capacity ------------------------------

/// A nested statement that must wait parks the whole statement and undoes
/// it: the re-delivered statement starts over, so every trigger and
/// function effect happens exactly once.
fn parkedStatements() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("CREATE TABLE k (id INT PRIMARY KEY)");
    try run("CREATE TABLE log (n INT, what TEXT)");
    try run("CREATE FUNCTION claim() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (NEW.id, 'before'); INSERT INTO k VALUES (NEW.id); RETURN NEW; END$$");
    try run("CREATE TRIGGER c BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION claim()");
    // T1 holds key 2; T2's trigger waits for it on row 2, after row 1.
    const t1 = try db.begin();
    const t2 = try db.begin();
    try statement(t1, "INSERT INTO k VALUES (2)");
    const insert = "INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')";
    try parks(t2, insert);
    // The parked statement left nothing behind.
    try same(try rows(t1, "SELECT count(*) FROM log"), "0");
    db.abort(t1);
    try same(try resumed(t2, insert), "");
    try same(try rows(t2, "SELECT n, what FROM log ORDER BY n"), "1|before;2|before;3|before");
    try commit(t2);
    try expect("SELECT id FROM k ORDER BY id", "1;2;3");
    // A committed holder makes the resumed statement fail (23505), and
    // nothing of it stays.
    const t3 = try db.begin();
    const t4 = try db.begin();
    try statement(t3, "INSERT INTO k VALUES (5)");
    const second = "INSERT INTO t VALUES (4,'d'),(5,'e')";
    try parks(t4, second);
    try commit(t3);
    const result = &other_slot;
    result.* = .{};
    if (db.statement(t4, second, result, .{ .@"resume" = true })) |_| return error.InvalidStatementAccepted else |err| try check(err == error.PrimaryKeyViolation);
    try same(try rows(t4, "SELECT count(*) FROM log"), "3");
    db.abort(t4);
    // A function called from a query waits the same way.
    try run("CREATE FUNCTION take(x INT) RETURNS INT LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (x, 'take'); INSERT INTO k VALUES (x); RETURN x; END$$");
    const t5 = try db.begin();
    const t6 = try db.begin();
    try statement(t5, "INSERT INTO k VALUES (8)");
    const query_text = "SELECT take(7) + take(8)";
    try parks(t6, query_text);
    db.abort(t5);
    try same(try resumed(t6, query_text), "15");
    try commit(t6);
    try expect("SELECT n, what FROM log WHERE what = 'take' ORDER BY n", "7|take;8|take");
    // An AFTER trigger waits after the statement's rows.
    try run("CREATE TABLE a (id INT PRIMARY KEY)");
    try run("CREATE FUNCTION after_claim() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (NEW.id, 'after'); INSERT INTO k VALUES (NEW.id); RETURN NULL; END$$");
    try run("CREATE TRIGGER ac AFTER INSERT ON a FOR EACH ROW EXECUTE FUNCTION after_claim()");
    const t7 = try db.begin();
    const t8 = try db.begin();
    try statement(t7, "INSERT INTO k VALUES (11)");
    const after_insert = "INSERT INTO a VALUES (10),(11),(12)";
    try parks(t8, after_insert);
    db.abort(t7);
    _ = try resumed(t8, after_insert);
    try commit(t8);
    try expect("SELECT n FROM log WHERE what = 'after' ORDER BY n", "10;11;12");
    try expect("SELECT id FROM a ORDER BY id", "10;11;12");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT id FROM k ORDER BY id", "SELECT * FROM log ORDER BY n, what", "SELECT id FROM a ORDER BY id" });
    try idle();
}

/// READ COMMITTED: a volatile function's statement sees rows committed
/// after its statement started; REPEATABLE READ keeps the transaction
/// snapshot (plus the transaction's own changes).
fn isolationSnapshots() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY)");
    try run("CREATE FUNCTION seen() RETURNS BIGINT LANGUAGE plpgsql AS $$BEGIN RETURN (SELECT count(*) FROM t); END$$");
    try run("CREATE FUNCTION seen_sql() RETURNS BIGINT LANGUAGE SQL AS $$SELECT count(*) FROM t$$");
    const rc = try db.begin();
    try same(try rows(rc, "SELECT seen()"), "0");
    try run("INSERT INTO t VALUES (1)");
    try same(try rows(rc, "SELECT seen(), seen_sql()"), "1|1");
    try statement(rc, "INSERT INTO t VALUES (2)");
    try same(try rows(rc, "SELECT seen(), seen_sql()"), "2|2");
    try commit(rc);
    const rr = try db.begin();
    try statement(rr, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ");
    try same(try rows(rr, "SELECT seen()"), "2");
    try run("INSERT INTO t VALUES (3)");
    try same(try rows(rr, "SELECT seen(), seen_sql()"), "2|2");
    try statement(rr, "INSERT INTO t VALUES (4)");
    try same(try rows(rr, "SELECT seen(), seen_sql()"), "3|3");
    try commit(rr);
    try expect("SELECT id FROM t ORDER BY id", "1;2;3;4");
    try sameState(&.{"SELECT id FROM t ORDER BY id"});
    try idle();
}

const Interrupt = struct {
    calls: usize = 0,
    fail_at: usize = 0,
    fn poll(context: ?*anyopaque) sql.Error!void {
        const self: *Interrupt = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        if (self.calls >= self.fail_at) return error.QueryCanceled;
    }
};

/// The statement under `control` fails with `wanted` (a cancel or the work
/// budget is never caught by an EXCEPTION handler) and changes nothing.
fn limited(control: *sql.ExecutionControl, source: []const u8, wanted: anyerror) !void {
    db.session.control = control;
    const result = &other_slot;
    result.* = .{};
    const outcome = db.execute(source, result);
    db.session.control = null;
    if (outcome) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try expect("SELECT count(*) FROM log", "0");
    try idle();
}

/// Nested statements are work-control checkpoints; a cancel inside one
/// ends the whole statement. The saved statements live in the query
/// workspace (54000 when it is too small) and nest Config.nested_statements
/// deep (54001).
fn workAndCapacity() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY)");
    try run("CREATE TABLE log (n INT)");
    try run("CREATE FUNCTION spin() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN FOR i IN 1..50 LOOP INSERT INTO log VALUES (i); END LOOP; RETURN NEW; END$$");
    try run("CREATE TRIGGER s BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION spin()");
    var interrupt: Interrupt = .{ .fail_at = 40 };
    var control: sql.ExecutionControl = .{ .context = &interrupt, .poll = &Interrupt.poll, .poll_interval = 1 };
    try limited(&control, "INSERT INTO t VALUES (1)", error.QueryCanceled);
    try check(interrupt.calls >= 40);
    var budget: sql.ExecutionControl = .{ .max_work = 200 };
    try limited(&budget, "INSERT INTO t VALUES (1)", error.QueryWorkLimit);
    // Inside an EXCEPTION WHEN OTHERS block too.
    try run("CREATE FUNCTION quiet() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN BEGIN FOR i IN 1..20 LOOP INSERT INTO log VALUES (i); END LOOP; EXCEPTION WHEN OTHERS THEN NULL; END; RETURN NEW; END$$");
    try run("DROP TRIGGER s ON t");
    try run("CREATE TRIGGER q BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION quiet()");
    var handled: sql.ExecutionControl = .{ .max_work = 20 };
    try limited(&handled, "INSERT INTO t VALUES (1)", error.QueryWorkLimit);
    try completes("INSERT INTO t VALUES (1)", .insert, 1);
    try expect("SELECT count(*) FROM log", "20");
    // A workspace too small for the suspended statement: 54000, atomic.
    small = .{};
    var small_result: Small.Result = .{};
    try small.execute("CREATE TABLE t (id INT PRIMARY KEY)", &small_result);
    try small.execute("CREATE TABLE log (n INT)", &small_result);
    try small.execute("CREATE FUNCTION w() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (NEW.id); RETURN NEW; END$$", &small_result);
    try small.execute("CREATE TRIGGER w BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION w()", &small_result);
    if (small.execute("INSERT INTO t SELECT a FROM (SELECT 1 AS a UNION ALL SELECT 2) s", &small_result)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.WorkspaceCapacity);
    try small.execute("SELECT count(*) FROM log", &small_result);
    try check(small_result.row_count == 1 and small_result.rows[0].cells[0].integer == 0);
    try sameState(&.{ "SELECT id FROM t", "SELECT count(*) FROM log" });
}

// ---- trigger extras ---------------------------------------------------------------

/// TG_ARGV is the trigger's arguments as text indexed from 0 (NULL beyond
/// TG_NARGS, and as a whole without arguments).
fn triggerArguments() !void {
    reset();
    try run("CREATE TABLE t (id INT, v TEXT)");
    try run("CREATE TABLE log (what TEXT)");
    try run("CREATE FUNCTION a() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (TG_NARGS || ':' || coalesce(TG_ARGV[0], 'NULL') || ':' || coalesce(TG_ARGV[1], 'NULL') || ':' || coalesce(TG_ARGV[2], 'NULL') || ':' || coalesce(TG_ARGV::text, 'NULL') || ':' || coalesce(TG_ARGV[-1], 'NULL')); RETURN NEW; END$$");
    try run("CREATE TRIGGER t1 BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION a('x', 'y z', 42)");
    try run("CREATE TRIGGER t2 BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION a()");
    try run("CREATE TRIGGER t3 BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION a('q\"uo\\te')");
    try completes("INSERT INTO t VALUES (1, 'a')", .insert, 1);
    try expect("SELECT * FROM log", "3:x:y z:42:[0:2]={x,\"y z\",42}:NULL;0:NULL:NULL:NULL:NULL:NULL;1:q\"uo\\te:NULL:NULL:[0:0]={\"q\\\"uo\\\\te\"}:NULL");
    try sameState(&.{"SELECT * FROM log"});
    try idle();
}

// ---- views as targets -------------------------------------------------------------

/// INSTEAD OF row triggers run an INSERT / UPDATE / DELETE on a view: NEW
/// and OLD have the view's columns, a NULL result skips the row, RETURNING
/// reads the row the trigger returned (OLD for DELETE).
fn insteadOfTriggers() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("INSERT INTO t VALUES (1, 'a'), (2, 'b')");
    try run("CREATE VIEW v AS SELECT id, v, id * 10 AS big FROM t");
    try run("CREATE TABLE log (what TEXT)");
    try run("CREATE FUNCTION vi() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (TG_OP || ':' || TG_WHEN || ':' || TG_LEVEL || ':' || coalesce(OLD.id::text, '-') || '->' || coalesce(NEW.id::text, '-') || ':' || coalesce(NEW.v, OLD.v)); IF TG_OP = 'INSERT' THEN INSERT INTO t VALUES (NEW.id, NEW.v); NEW.big := -1; RETURN NEW; END IF; IF TG_OP = 'UPDATE' THEN UPDATE t SET v = NEW.v WHERE id = OLD.id; RETURN NEW; END IF; DELETE FROM t WHERE id = OLD.id; RETURN OLD; END$$");
    try completes("CREATE TRIGGER vt INSTEAD OF INSERT OR UPDATE OR DELETE ON v FOR EACH ROW EXECUTE FUNCTION vi()", .create_trigger, 0);
    try returns("INSERT INTO v VALUES (3, 'c', 0) RETURNING *", "3|c|-1");
    try completes("INSERT INTO v (id, v) VALUES (4, 'd'), (5, 'e')", .insert, 2);
    try returns("UPDATE v SET v = v || '!' WHERE id >= 4 RETURNING id, v, big", "4|d!|40;5|e!|50");
    try returns("DELETE FROM v WHERE id = 5 RETURNING *", "5|e!|50");
    try expect("SELECT * FROM t ORDER BY id", "1|a;2|b;3|c;4|d!");
    try expect("SELECT * FROM log", "INSERT:INSTEAD OF:ROW:-->3:c;INSERT:INSTEAD OF:ROW:-->4:d;INSERT:INSTEAD OF:ROW:-->5:e;UPDATE:INSTEAD OF:ROW:4->4:d!;UPDATE:INSTEAD OF:ROW:5->5:e!;DELETE:INSTEAD OF:ROW:5->-:e!");
    try expect("SELECT tgname, tgtype FROM pg_trigger WHERE tgrelid = 'v'::regclass ORDER BY 1", "vt|93");
    // A NULL result does nothing and counts nothing.
    try run("CREATE FUNCTION skipper() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NULL; END$$");
    try run("CREATE VIEW w AS SELECT * FROM t");
    try run("CREATE TRIGGER wt INSTEAD OF DELETE ON w FOR EACH ROW EXECUTE FUNCTION skipper()");
    try completes("DELETE FROM w", .delete, 0);
    try expect("SELECT count(*) FROM t", "4");
    // A failing trigger undoes the whole statement.
    try run("CREATE FUNCTION partial() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO t VALUES (NEW.id, NEW.v); IF NEW.id > 10 THEN RAISE EXCEPTION 'too big'; END IF; RETURN NEW; END$$");
    try run("CREATE VIEW p AS SELECT id, v FROM t");
    try run("CREATE TRIGGER pt INSTEAD OF INSERT ON p FOR EACH ROW EXECUTE FUNCTION partial()");
    try rejects("INSERT INTO p VALUES (8, 'x'), (11, 'y')", error.RaiseException, "SELECT count(*) FROM t", "4");
    // Statement triggers of a view fire around it.
    try run("CREATE FUNCTION st() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES ('stmt:' || TG_WHEN || ':' || TG_TABLE_NAME); RETURN NULL; END$$");
    try run("CREATE TRIGGER ps BEFORE INSERT ON p FOR EACH STATEMENT EXECUTE FUNCTION st()");
    try run("CREATE TRIGGER pa AFTER INSERT ON p FOR EACH STATEMENT EXECUTE FUNCTION st()");
    try completes("INSERT INTO p VALUES (8, 'x')", .insert, 1);
    try expect("SELECT what FROM log WHERE what LIKE 'stmt%' ORDER BY what", "stmt:AFTER:p;stmt:BEFORE:p");
    // Definition errors (42809 / 0A000 as PostgreSQL).
    try fails("CREATE TRIGGER bad1 BEFORE INSERT ON v FOR EACH ROW EXECUTE FUNCTION vi()", error.WrongObjectType);
    try fails("CREATE TRIGGER bad2 INSTEAD OF INSERT ON t FOR EACH ROW EXECUTE FUNCTION vi()", error.WrongObjectType);
    try fails("CREATE TRIGGER bad3 INSTEAD OF INSERT ON v FOR EACH STATEMENT EXECUTE FUNCTION vi()", error.UnsupportedStatement);
    try fails("CREATE TRIGGER bad4 INSTEAD OF UPDATE OF v ON v FOR EACH ROW EXECUTE FUNCTION vi()", error.UnsupportedStatement);
    try fails("CREATE TRIGGER bad5 INSTEAD OF INSERT ON v FOR EACH ROW WHEN (NEW.id > 0) EXECUTE FUNCTION vi()", error.UnsupportedStatement);
    // A view without a trigger for the event and not updatable: 55000.
    try run("CREATE VIEW g AS SELECT v, count(*) AS n FROM t GROUP BY v");
    try rejectsDetail("INSERT INTO g VALUES ('z', 1)", error.ObjectNotInPrerequisiteState, DB.view_details.group, "SELECT count(*) FROM t", "5");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY what", "SELECT tgname, tgtype FROM pg_trigger ORDER BY tgname" });
    try run("DROP VIEW v");
    try expect("SELECT count(*) FROM pg_trigger WHERE tgname = 'vt'", "0");
    try sameState(&.{"SELECT count(*) FROM pg_trigger"});
    try idle();
}

/// A view over one table or view without DISTINCT, GROUP BY, HAVING, set
/// operations, WITH, LIMIT / OFFSET, aggregates or window functions is
/// automatically updatable: the statement runs on the base relation, its
/// columns mapped, and UPDATE / DELETE only reach rows of the view.
fn updatableViews() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, val TEXT, n INT DEFAULT 7, secret TEXT)");
    try run("INSERT INTO t VALUES (1, 'a', 1, 's1'), (2, 'b', 2, 's2'), (3, 'c', 30, 's3')");
    try run("CREATE VIEW v AS SELECT id, val AS label, n, n * 2 AS dbl FROM t WHERE n < 10");
    try returns("INSERT INTO v (id, label) VALUES (4, 'd') RETURNING *", "4|d|7|14");
    try returns("INSERT INTO v VALUES (5, 'e', 3) RETURNING id, label, dbl", "5|e|6");
    try rejectsDetail("INSERT INTO v VALUES (6, 'f', 4, 8)", error.UnsupportedStatement, DB.view_details.column, "SELECT count(*) FROM t", "5");
    try rejects("INSERT INTO v (id, dbl) VALUES (6, 8)", error.UnsupportedStatement, "SELECT count(*) FROM t", "5");
    try returns("UPDATE v SET label = label || '!' WHERE id <= 2 RETURNING *", "1|a!|1|2;2|b!|2|4");
    try rejects("UPDATE v SET dbl = 1", error.UnsupportedStatement, "SELECT count(*) FROM t", "5");
    // Without a check option a row may leave the view.
    try completes("UPDATE v SET n = 50 WHERE id = 1", .update, 1);
    try expect("SELECT * FROM t ORDER BY id", "1|a!|50|s1;2|b!|2|s2;3|c|30|s3;4|d|7|NULL;5|e|3|NULL");
    try returns("DELETE FROM v WHERE label LIKE 'b%' RETURNING id, dbl", "2|4");
    try completes("DELETE FROM v WHERE id = 3", .delete, 0);
    try expect("SELECT id, val FROM t ORDER BY id", "1|a!;3|c;4|d;5|e");
    // Base columns the view does not show do not exist through it.
    try rejects("UPDATE v SET label = 'x' WHERE secret = 's1'", error.ColumnNotFound, "SELECT count(*) FROM t", "4");
    // Not automatically updatable: 55000 with PostgreSQL's detail.
    const Case = struct { create: []const u8, statement: []const u8, detail: []const u8 };
    const cases = [_]Case{
        .{ .create = "CREATE VIEW agg AS SELECT n, count(*) FROM t GROUP BY n", .statement = "INSERT INTO agg VALUES (1, 1)", .detail = DB.view_details.group },
        .{ .create = "CREATE VIEW dist AS SELECT DISTINCT n FROM t", .statement = "DELETE FROM dist", .detail = DB.view_details.distinct },
        .{ .create = "CREATE VIEW j AS SELECT t.id FROM t, t t2 WHERE t.id = t2.id", .statement = "UPDATE j SET id = 1", .detail = DB.view_details.single },
        .{ .create = "CREATE VIEW lim AS SELECT * FROM t LIMIT 1", .statement = "DELETE FROM lim", .detail = DB.view_details.limit },
        .{ .create = "CREATE VIEW u AS SELECT id FROM t UNION SELECT id FROM t", .statement = "INSERT INTO u VALUES (1)", .detail = DB.view_details.set_operation },
        .{ .create = "CREATE VIEW nocols AS SELECT 1 AS one FROM t", .statement = "INSERT INTO nocols VALUES (1)", .detail = DB.view_details.no_columns },
    };
    for (cases) |item| {
        try run(item.create);
        try rejectsDetail(item.statement, error.ObjectNotInPrerequisiteState, item.detail, "SELECT count(*) FROM t", "4");
    }
    // A view with no updatable column still deletes.
    try completes("DELETE FROM nocols", .delete, 4);
    // Views over views.
    try run("CREATE VIEW vv AS SELECT id, label FROM v WHERE id > 0");
    try returns("INSERT INTO vv VALUES (9, 'nested') RETURNING *", "9|nested");
    try completes("UPDATE vv SET label = 'N' WHERE id = 9", .update, 1);
    try expect("SELECT id, val, n FROM t ORDER BY id", "9|N|7");
    // Base triggers and constraints apply; failures are atomic.
    try rejects("INSERT INTO vv VALUES (9, 'dup')", error.PrimaryKeyViolation, "SELECT count(*) FROM t", "1");
    try run("CREATE TABLE log (what TEXT)");
    try run("CREATE FUNCTION tl() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO log VALUES (TG_OP || ':' || TG_TABLE_NAME || ':' || NEW.val); RETURN NEW; END$$");
    try run("CREATE TRIGGER tl BEFORE INSERT OR UPDATE ON t FOR EACH ROW EXECUTE FUNCTION tl()");
    try completes("INSERT INTO vv VALUES (10, 'x')", .insert, 1);
    try expect("SELECT * FROM log", "INSERT:t:x");
    // The user needs the privilege on the view, its owner on the base.
    try run("CREATE ROLE viewer");
    try run("GRANT SELECT, UPDATE ON v TO viewer");
    // Base triggers run as the user.
    try run("GRANT INSERT ON log TO viewer");
    try run("SET ROLE viewer");
    try completes("UPDATE v SET label = 'by viewer' WHERE id = 10", .update, 1);
    try rejects("UPDATE t SET val = 'direct' WHERE id = 10", error.InsufficientPrivilege, "SELECT count(*) FROM v", "2");
    try rejects("DELETE FROM v WHERE id = 10", error.InsufficientPrivilege, "SELECT count(*) FROM v", "2");
    try run("RESET ROLE");
    try expect("SELECT val FROM t WHERE id = 10", "by viewer");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY what" });
    try idle();
}

// ---- rule actions ---------------------------------------------------------------

const rule_probe = "SELECT r.rulename, r.ev_type, r.is_instead, p.definition FROM pg_rewrite r JOIN pg_rules p ON p.rulename = r.rulename ORDER BY r.rulename";

/// DO [ALSO | INSTEAD] INSERT / UPDATE / DELETE actions with NEW / OLD and
/// WHERE, on tables and views: INSERT actions after the original, UPDATE
/// and DELETE actions before it, an unconditional INSTEAD rule replaces
/// it (the tag counts its last action of the same kind), a conditional
/// one keeps the original for the other rows. Rules with actions replay
/// as op 85.
fn ruleActions() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("CREATE TABLE log (what TEXT)");
    try completes("CREATE RULE ri AS ON INSERT TO t DO ALSO INSERT INTO log VALUES ('ins:' || new.id || ':' || new.v)", .create_rule, 0);
    try completes("INSERT INTO t VALUES (1, 'a'), (2, 'b')", .insert, 2);
    try run("CREATE RULE ru AS ON UPDATE TO t DO ALSO INSERT INTO log VALUES ('upd:' || old.v || '->' || new.v)");
    try completes("UPDATE t SET v = v || '!' WHERE id = 1", .update, 1);
    try run("CREATE RULE rd AS ON DELETE TO t WHERE old.id = 2 DO ALSO INSERT INTO log VALUES ('del:' || old.id)");
    try completes("DELETE FROM t WHERE id >= 1", .delete, 2);
    try expect("SELECT * FROM t ORDER BY id", "");
    try expect("SELECT * FROM log", "ins:1:a;ins:2:b;upd:a->a!;del:2");
    // Conditional and unconditional INSTEAD rules.
    try run("CREATE TABLE u (id INT, v TEXT)");
    try run("CREATE RULE ui AS ON INSERT TO u WHERE new.id < 0 DO INSTEAD INSERT INTO log VALUES ('neg:' || new.id)");
    try completes("INSERT INTO u VALUES (1, 'x'), (-1, 'y')", .insert, 1);
    try expect("SELECT * FROM u", "1|x");
    try run("CREATE RULE ui2 AS ON INSERT TO u DO INSTEAD (INSERT INTO log VALUES ('i1:' || new.id); INSERT INTO log VALUES ('i2:' || new.id))");
    try completes("INSERT INTO u VALUES (5, 'z')", .insert, 1);
    try expect("SELECT * FROM u", "1|x");
    try expect("SELECT * FROM log WHERE what LIKE 'i%' OR what LIKE 'neg%' ORDER BY what", "i1:5;i2:5;ins:1:a;ins:2:b;neg:-1");
    // Rules on a view replace its statements.
    try run("CREATE VIEW vw AS SELECT * FROM t");
    try run("CREATE RULE vi AS ON INSERT TO vw DO INSTEAD INSERT INTO t VALUES (new.id, new.v)");
    try run("CREATE RULE vu AS ON UPDATE TO vw DO INSTEAD UPDATE t SET v = new.v WHERE id = old.id");
    try run("CREATE RULE vd AS ON DELETE TO vw DO INSTEAD DELETE FROM t WHERE id = old.id");
    try completes("INSERT INTO vw VALUES (7, 'g'), (8, 'h')", .insert, 2);
    try completes("UPDATE vw SET v = 'G' WHERE id = 7", .update, 1);
    try completes("DELETE FROM vw WHERE id = 8", .delete, 1);
    try expect("SELECT * FROM t ORDER BY id", "7|G");
    // RETURNING needs a rule with RETURNING (0A000).
    try rejects("INSERT INTO vw VALUES (9, 'i') RETURNING *", error.UnsupportedStatement, "SELECT count(*) FROM t", "1");
    // UPDATE actions run before the original; defaults are evaluated again.
    try run("CREATE TABLE s (id SERIAL PRIMARY KEY, v TEXT)");
    try run("CREATE TABLE sl (n INT)");
    try run("CREATE RULE sr AS ON INSERT TO s DO ALSO INSERT INTO sl VALUES (new.id)");
    try completes("INSERT INTO s (v) VALUES ('a'), ('b')", .insert, 2);
    try expect("SELECT id FROM s ORDER BY id", "1;2");
    try expect("SELECT n FROM sl ORDER BY n", "3;4");
    // Definition errors and recursion (42P17), SELECT / NOTIFY actions (0A000).
    try fails("CREATE RULE bad AS ON INSERT TO t DO ALSO INSERT INTO log VALUES (old.v)", error.InvalidObjectDefinition);
    try fails("CREATE RULE bad2 AS ON DELETE TO t DO ALSO INSERT INTO log VALUES (new.v)", error.InvalidObjectDefinition);
    try fails("CREATE RULE s1 AS ON INSERT TO t DO ALSO SELECT 1", error.UnsupportedStatement);
    try fails("CREATE RULE n1 AS ON INSERT TO t DO ALSO NOTIFY ch", error.UnsupportedStatement);
    try run("CREATE RULE rec AS ON INSERT TO log DO ALSO INSERT INTO log VALUES ('again')");
    try rejects("INSERT INTO log VALUES ('x')", error.InvalidObjectDefinition, "SELECT count(*) FROM log", "10");
    try run("DROP RULE rec ON log");
    // A failing action undoes the whole statement.
    try run("CREATE RULE bad_action AS ON INSERT TO sl DO ALSO INSERT INTO t VALUES (new.n, 'dup')");
    try rejects("INSERT INTO sl VALUES (7)", error.PrimaryKeyViolation, "SELECT count(*) FROM sl", "2");
    try expect(rule_probe, "bad_action|3|f|CREATE RULE bad_action AS\n    ON INSERT TO public.sl DO  INSERT INTO t VALUES (new.n, 'dup');;" ++
        "rd|4|f|CREATE RULE rd AS\n    ON DELETE TO public.t\n   WHERE (old.id = 2) DO  INSERT INTO log VALUES ('del:' || old.id);;" ++
        "ri|3|f|CREATE RULE ri AS\n    ON INSERT TO public.t DO  INSERT INTO log VALUES ('ins:' || new.id || ':' || new.v);;" ++
        "ru|2|f|CREATE RULE ru AS\n    ON UPDATE TO public.t DO  INSERT INTO log VALUES ('upd:' || old.v || '->' || new.v);;" ++
        "sr|3|f|CREATE RULE sr AS\n    ON INSERT TO public.s DO  INSERT INTO sl VALUES (new.id);;" ++
        "ui|3|t|CREATE RULE ui AS\n    ON INSERT TO public.u\n   WHERE (new.id < 0) DO INSTEAD  INSERT INTO log VALUES ('neg:' || new.id);;" ++
        "ui2|3|t|CREATE RULE ui2 AS\n    ON INSERT TO public.u DO INSTEAD ( INSERT INTO log VALUES ('i1:' || new.id);\n INSERT INTO log VALUES ('i2:' || new.id);\n );;" ++
        "vd|4|t|CREATE RULE vd AS\n    ON DELETE TO public.vw DO INSTEAD  DELETE FROM t WHERE id = old.id;;" ++
        "vi|3|t|CREATE RULE vi AS\n    ON INSERT TO public.vw DO INSTEAD  INSERT INTO t VALUES (new.id, new.v);;" ++
        "vu|2|t|CREATE RULE vu AS\n    ON UPDATE TO public.vw DO INSTEAD  UPDATE t SET v = new.v WHERE id = old.id;");
    // The replica replays op 85 and its rules act alike.
    try sameState(&.{ rule_probe, "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY what", "SELECT * FROM u ORDER BY id", "SELECT n FROM sl ORDER BY n" });
    try run("INSERT INTO vw VALUES (20, 'r')");
    try run("INSERT INTO u VALUES (-2, 'q')");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM log ORDER BY what" });
    var left: DB.Result = .{};
    var right: DB.Result = .{};
    try db.execute("INSERT INTO u VALUES (-3, 'p')", &left);
    try replica.execute("INSERT INTO u VALUES (-3, 'p')", &right);
    try check(left.affected_rows == right.affected_rows);
    try sameState(&.{"SELECT * FROM log ORDER BY what"});
    try run("DROP RULE vi ON vw");
    try expect("SELECT count(*) FROM pg_rules WHERE rulename = 'vi'", "0");
    try sameState(&.{rule_probe});
    try idle();
}

/// Malformed op 85 records are rejected before anything changes; the
/// well-formed one replays.
fn ruleRecords() !void {
    reset();
    try run("CREATE TABLE t (id INT PRIMARY KEY, v TEXT)");
    try run("CREATE TABLE log (what TEXT)");
    const result = &other_slot;
    result.* = .{};
    var used: usize = 0;
    try db.executeChanges("CREATE RULE ri AS ON INSERT TO t DO ALSO INSERT INTO log VALUES (new.v)", result, &record, &used, null, null);
    const action = "INSERT INTO log VALUES (new.v)";
    const at = std.mem.indexOf(u8, record[0..used], action) orelse return error.MissingRuleAction;
    @memcpy(crafted[0..used], record[0..used]);
    crafted[at - 3] = 7;
    if (replica.applyChangeRecord(crafted[0..used], &scratch)) |_| return error.InvalidRecordAccepted else |err| try check(err == error.InvalidChangeRecord);
    @memcpy(crafted[0..used], record[0..used]);
    crafted[at] = 0;
    if (replica.applyChangeRecord(crafted[0..used], &scratch)) |_| return error.InvalidRecordAccepted else |err| try check(err == error.InvalidChangeRecord);
    try expect("SELECT count(*) FROM pg_rules", "1");
    try same(try query(&replica, "SELECT count(*) FROM pg_rules"), "0");
    try replica.applyChangeRecord(record[0..used], &scratch);
    records_applied += 1;
    try sameState(&.{rule_probe});
    try run("INSERT INTO t VALUES (1, 'a')");
    try sameState(&.{ "SELECT * FROM log", rule_probe });
    try idle();
}

// ---- set-returning bodies (routines-sig hand-off) --------------------------------

/// RETURN QUERY, set-returning and OUT-parameter SQL bodies that are not
/// inlined, data-modifying and multi-statement bodies, CALL from a
/// function and `RETURN (SELECT ...)` run through nested statements.
fn routineRows() !void {
    reset();
    try run("CREATE TABLE tc (v INT)");
    try run("INSERT INTO tc VALUES (400)");
    try run("CREATE FUNCTION evq(n INT) RETURNS SETOF INT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT i FROM generate_series(1, n) i; END$$");
    try returns("SELECT * FROM evq(3)", "1;2;3");
    try run("CREATE FUNCTION sqlmulti(a INT) RETURNS INT LANGUAGE sql AS $$SELECT 1; SELECT a + 1$$");
    try returns("SELECT sqlmulti(1)", "2");
    try run("CREATE FUNCTION upd() RETURNS INT LANGUAGE sql AS $$UPDATE tc SET v = v + 1 RETURNING v$$");
    try returns("SELECT upd()", "401");
    try run("CREATE FUNCTION rq2(n INT) RETURNS SETOF INT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT v FROM tc; RETURN QUERY SELECT n; RETURN NEXT 7; END$$");
    try returns("SELECT * FROM rq2(9)", "401;9;7");
    // The query's structure must match the result (42804).
    try run("CREATE FUNCTION rqbad() RETURNS SETOF BIGINT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT 1; END$$");
    try fails("SELECT * FROM rqbad()", error.TypeMismatch);
    try run("CREATE FUNCTION rqtab() RETURNS TABLE (a INT, b TEXT) LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT v, v::text FROM tc; END$$");
    try returns("SELECT * FROM rqtab()", "401|401");
    try run("CREATE FUNCTION ins_ret(x INT) RETURNS SETOF INT LANGUAGE sql AS $$INSERT INTO tc VALUES (x), (x + 1) RETURNING v$$");
    try returns("SELECT * FROM ins_ret(10)", "10;11");
    try run("CREATE FUNCTION two(x INT, OUT a INT, OUT b INT) LANGUAGE sql AS $$INSERT INTO tc VALUES (x); SELECT x, x * 2$$");
    try returns("SELECT * FROM two(5)", "5|10");
    try run("CREATE PROCEDURE p(x INT) LANGUAGE sql AS $$INSERT INTO tc VALUES (x)$$");
    try run("CREATE FUNCTION callp() RETURNS INT LANGUAGE plpgsql AS $$BEGIN CALL p(77); RETURN 1; END$$");
    try returns("SELECT callp()", "1");
    try run("CREATE FUNCTION rs() RETURNS BIGINT LANGUAGE plpgsql AS $$BEGIN RETURN (SELECT count(*) FROM tc); END$$");
    try returns("SELECT rs()", "5");
    try expect("SELECT v FROM tc ORDER BY v", "5;10;11;77;401");
    // A failing row source undoes the whole statement.
    try run("CREATE FUNCTION ins_bad(x INT) RETURNS SETOF INT LANGUAGE sql AS $$INSERT INTO tc VALUES (x) RETURNING v / 0$$");
    try rejects("SELECT * FROM ins_bad(1)", error.DivisionByZero, "SELECT count(*) FROM tc", "5");
    try sameState(&.{"SELECT v FROM tc ORDER BY v"});
    try idle();
}

// ---- values leaving a nested statement --------------------------------------------

/// Values captured from a nested statement (SELECT INTO, RETURNING INTO,
/// RETURN QUERY rows) are copied into the routine frame or the kept rows:
/// later statements that reuse the nested statement's workspace do not
/// change them. A value too wide for that bounded storage (wider than
/// Config.text_bytes, here a long view definition) is 54000, atomically.
fn capturedValues() !void {
    reset();
    try run("CREATE TABLE big (id INT PRIMARY KEY, t TEXT, b BYTEA, a INT[])");
    try run("INSERT INTO big VALUES (1, repeat('a', 63) || 'Z', '\\xababababababababababababababababababababababababababababab0102'::bytea, ARRAY[1,2,3,4,5,6,7,8]), (2, repeat('q', 64), '\\xcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'::bytea, ARRAY[9,9,9,9,9,9,9,9])");
    try run("CREATE FUNCTION keep() RETURNS TEXT LANGUAGE plpgsql AS $$DECLARE v TEXT; w BYTEA; x INT[]; y TEXT; n INT; BEGIN SELECT t, b, a INTO v, w, x FROM big WHERE id = 1; SELECT t INTO y FROM big WHERE id = 2; PERFORM left(t, 30) || right(b::text, 30) FROM big; UPDATE big SET t = repeat('r', 64) WHERE id = 2 RETURNING length(t) INTO n; RETURN right(v, 3) || length(v) || ':' || right(w::text, 6) || length(w::text) || ':' || x[8] || array_length(x, 1) || ':' || left(y, 2) || n; END$$");
    try returns("SELECT keep()", "aaZ64:ab010264:88:qq64");
    try run("CREATE FUNCTION rows_back() RETURNS SETOF TEXT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT t FROM big ORDER BY id; RETURN QUERY SELECT repeat('s', 64); END$$");
    try returns("SELECT length(r), right(r, 2) FROM rows_back() r", "64|aZ;64|rr;64|ss");
    try run("CREATE TABLE trg_t (id INT, note TEXT)");
    try run("CREATE FUNCTION trg_keep() RETURNS trigger LANGUAGE plpgsql AS $$DECLARE v TEXT; BEGIN SELECT t INTO v FROM big WHERE id = 1; PERFORM repeat('z', 64) FROM big; NEW.note := right(v, 4); RETURN NEW; END$$");
    try run("CREATE TRIGGER k BEFORE INSERT ON trg_t FOR EACH ROW EXECUTE FUNCTION trg_keep()");
    try completes("INSERT INTO trg_t VALUES (1, NULL), (2, NULL)", .insert, 2);
    try expect("SELECT * FROM trg_t ORDER BY id", "1|aaaZ;2|aaaZ");
    // A definition wider than an inline value cannot leave the statement.
    try run("CREATE VIEW wide AS SELECT id, t, b, a FROM big WHERE id > 0 AND id < 99 AND t > ''");
    try run("CREATE FUNCTION def_into() RETURNS INT LANGUAGE plpgsql AS $$DECLARE s TEXT; BEGIN INSERT INTO trg_t VALUES (9, 'x'); SELECT pg_get_viewdef('wide'::regclass) INTO s; RETURN length(s); END$$");
    try rejects("SELECT def_into()", error.TextCapacity, "SELECT count(*) FROM trg_t", "2");
    try run("CREATE FUNCTION def_rows() RETURNS SETOF TEXT LANGUAGE plpgsql AS $$BEGIN RETURN QUERY SELECT pg_get_viewdef('wide'::regclass); END$$");
    try rejects("SELECT count(*) FROM def_rows()", error.TextCapacity, "SELECT count(*) FROM trg_t", "2");
    // Its length is an ordinary value.
    try run("CREATE FUNCTION def_length() RETURNS INT LANGUAGE plpgsql AS $$DECLARE n INT; BEGIN SELECT length(pg_get_viewdef('wide'::regclass)) INTO n; RETURN n; END$$");
    const direct = try query(&db, "SELECT length(pg_get_viewdef('wide'::regclass))::text");
    @memcpy(copy_buffer[0..direct.len], direct);
    try check(direct.len > 0);
    try same(try query(&db, "SELECT def_length()::text"), copy_buffer[0..direct.len]);
    try sameState(&.{ "SELECT id, length(t), b::text, a::text FROM big ORDER BY id", "SELECT * FROM trg_t ORDER BY id" });
    try idle();
}

pub fn main() !void {
    try triggerStatements();
    try functionStatements();
    try nestingLimits();
    try parkedStatements();
    try isolationSnapshots();
    try workAndCapacity();
    try triggerArguments();
    try insteadOfTriggers();
    try updatableViews();
    try ruleActions();
    try ruleRecords();
    try routineRows();
    try capturedValues();
    std.debug.print("nested statements: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
