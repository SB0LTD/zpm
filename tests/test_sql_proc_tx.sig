//! Transaction control inside procedures and DO blocks (conformance lane
//! B11 wave 5, proc-tx; docs/SQL_PROC_TX.md): COMMIT / ROLLBACK [AND [NO]
//! CHAIN] in a top-level CALL / DO run non-atomically end the transaction in
//! the middle of the statement, each COMMIT writing, syncing and publishing
//! its own change record, and the CALL / DO goes on in the next transaction
//! with its variables. Covered: the 2D000 contexts (a transaction block,
//! explicit or a multi-statement Query's, a pipelined extended command, a
//! function, trigger or SQL-language routine below, an EXCEPTION block on
//! the stack, SECURITY DEFINER and SET routines), COMMIT inside a handler,
//! nested CALL / DO chains, loops, INOUT results, AND CHAIN characteristics,
//! SET TRANSACTION after a COMMIT, an error after a COMMIT, lock waits before
//! and after a COMMIT, the extended protocol and a crash between two COMMITs.
//! Then the SEARCH sequence and CYCLE path values of recursive queries (T133):
//! record / record[] types and text, ordering by their keys and name checks.
//!
//! Every statement runs through the PostgreSQL wire over store connections
//! and reduces to command tags, SQLSTATEs, column names and data rows; every
//! committed record replays into a replica that must answer like the primary
//! after each step. Every expectation was checked against native PostgreSQL
//! 18.7, except the lock wait after a COMMIT, which PostgreSQL waits out and
//! this store fails at once (55P03; native gives the same with lock_timeout
//! set), and the marked SEARCH / CYCLE errors where PostgreSQL computes a
//! value (docs/SQL_PROC_TX.md).
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const DB = sql.Database(.{ .tables = 16, .columns = 16, .rows_per_table = 128, .name_bytes = 63, .text_bytes = 512,
    .nulls_first_ascending = false, .integer_bits = 32, .expr_nodes = 2048, .work_rows = 256, .result_rows = 128,
    .relations = 8, .subqueries = 32, .ctes = 8, .schemas = 8, .transactions = 4, .predicates = 32,
    .routines = 32, .triggers = 16, .rules = 8, .catalog_objects = 128, .cursors = 8, .cursor_rows = 128 });
const Store = @import("db_store").Store(DB);
const Session = pg.Session(Store.Connection);

var assertions: usize = 0;
var store: Store = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record_buffer: [65536]u8 = undefined;
var replayed: usize = 0;
var conns: [2]Store.Connection = undefined;
var wires: [2]Session = undefined;
var output: [Session.responseCapacity()]u8 = undefined;
var packet: [16384]u8 = undefined;
var canonical: [16384]u8 = undefined;
var result: DB.Result = .{};
var text_primary: [8192]u8 = undefined;
var text_replica: [8192]u8 = undefined;
/// What the replica is compared on after every step.
var probe: []const u8 = "";

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("proc-tx contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.ProcTxContractFailed;
    }
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn be16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn put32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

// ---- the WAL sink: every record replays into the replica; a crash -------

/// Records made durable (in order) and an injected crash: the sink fails
/// the write of record number `crash_at` (0-based), as a process that dies
/// before the record reaches the log.
var durable: [16][4096]u8 = undefined;
var durable_len: [16]usize = @splat(0);
var durable_count: usize = 0;
var crash_at: ?usize = null;

fn replicate(_: ?*anyopaque, payload: []const u8) anyerror!void {
    if (crash_at) |at| if (durable_count == at) return error.InjectedCrash;
    if (durable_count < durable.len and payload.len <= durable[0].len) {
        @memcpy(durable[durable_count][0..payload.len], payload);
        durable_len[durable_count] = payload.len;
    }
    durable_count += 1;
    try replica.applyChangeRecord(payload, &scratch);
    replayed += 1;
}

/// A fixed wall clock (PostgreSQL-epoch microseconds of 2024-06-01 UTC).
fn fixedClock() ?i64 {
    return 770_515_200_000_000;
}

fn reset() !void {
    store = .{};
    replica = .{};
    durable_count = 0;
    crash_at = null;
    probe = "";
    store.commit_fn = &replicate;
    store.encode_buffer = &record_buffer;
    store.wall_clock = &fixedClock;
    for (0..2) |index| try startup(index);
}

fn startup(index: usize) !void {
    conns[index] = .{ .store = &store, .id = index + 1 };
    wires[index] = .{};
    var at: usize = 4;
    put32(packet[at..], 196608);
    at += 4;
    for ([_][]const u8{ "user", "ramsql", "database", "w5_proc_tx", "client_encoding", "UTF8", "TimeZone", "UTC" }) |item| {
        @memcpy(packet[at..][0..item.len], item);
        at += item.len;
        packet[at] = 0;
        at += 1;
    }
    packet[at] = 0;
    at += 1;
    put32(packet[0..4], @intCast(at));
    const reply = try wires[index].handle(&conns[index], packet[0..at], &output);
    if (reply.consumed != at or !wires[index].startup or reply.close) return error.StartupFailed;
}

const Out = struct {
    len: usize = 0,
    fn put(self: *Out, bytes: []const u8) void {
        const n = @min(bytes.len, canonical.len - self.len);
        @memcpy(canonical[self.len..][0..n], bytes[0..n]);
        self.len += n;
    }
};

/// Reduces backend messages to `T:names`, `;cells|...` per row (NULL as
/// \N), ` C:tag` and ` E:state` (a failing command's rows are dropped).
fn reduce(bytes: []const u8, out: *Out) !void {
    var mark: usize = out.len;
    var at: usize = 0;
    while (at + 5 <= bytes.len) {
        const kind = bytes[at];
        const n = be32(bytes[at + 1 ..][0..4]);
        const body = bytes[at + 5 .. at + 1 + n];
        at += 1 + n;
        switch (kind) {
            'T' => {
                if (out.len != 0) out.put(" ");
                out.put("T:");
                var offset: usize = 2;
                for (0..be16(body[0..2])) |column| {
                    const end = std.mem.indexOfScalarPos(u8, body, offset, 0) orelse return error.MalformedFrame;
                    if (column != 0) out.put(",");
                    out.put(body[offset..end]);
                    offset = end + 19;
                }
            },
            'D' => {
                out.put(";");
                var offset: usize = 2;
                for (0..be16(body[0..2])) |cell| {
                    if (cell != 0) out.put("|");
                    const size: i32 = @bitCast(be32(body[offset..][0..4]));
                    offset += 4;
                    if (size < 0) out.put("\\N") else {
                        out.put(body[offset..][0..@intCast(size)]);
                        offset += @intCast(size);
                    }
                }
            },
            'C' => {
                if (out.len != 0) out.put(" ");
                out.put("C:");
                out.put(body[0 .. body.len - 1]);
                mark = out.len;
            },
            'E' => {
                out.len = mark;
                if (out.len != 0) out.put(" ");
                out.put("E:");
                var offset: usize = 0;
                while (offset < body.len and body[offset] != 0) {
                    const end = std.mem.indexOfScalarPos(u8, body, offset + 1, 0) orelse return error.MalformedFrame;
                    if (body[offset] == 'C') out.put(body[offset + 1 .. end]);
                    offset = end + 1;
                }
                mark = out.len;
            },
            else => {},
        }
    }
}

/// One simple Query on connection `index` (BLOCKED while it is parked).
fn run(index: usize, source: []const u8) ![]const u8 {
    packet[0] = 'Q';
    @memcpy(packet[5..][0..source.len], source);
    packet[5 + source.len] = 0;
    const length = 4 + source.len + 1;
    put32(packet[1..5], @intCast(length));
    const reply = try wires[index].handle(&conns[index], packet[0 .. 1 + length], &output);
    if (reply.blocked) return "BLOCKED";
    var out: Out = .{};
    try reduce(output[0..reply.written], &out);
    return canonical[0..out.len];
}

const Step = struct { []const u8, []const u8 };

/// Runs steps on connection `index`, each checked against its native
/// PostgreSQL 18.7 response; the replica answers `probe` like the primary
/// after each one.
fn steps(index: usize, list: []const Step) !void {
    for (list) |step| {
        const got = try run(index, step[0]);
        if (!std.mem.eql(u8, got, step[1])) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ step[0], got, step[1] });
        try check(std.mem.eql(u8, got, step[1]));
        if (probe.len != 0 and !conns[0].in_transaction and !conns[1].in_transaction) try sameOnReplica(probe);
    }
}

/// The extended protocol: each source as Parse / Bind / Execute (unnamed),
/// then one Sync; the responses reduce like a Query's.
fn extended(index: usize, sources: []const []const u8) ![]const u8 {
    var all: [8192]u8 = undefined;
    var all_len: usize = 0;
    for (sources) |source| {
        for ([_]u8{ 'P', 'B', 'E' }) |tag| {
            var at: usize = 5;
            switch (tag) {
                'P' => {
                    packet[at] = 0;
                    at += 1;
                    @memcpy(packet[at..][0..source.len], source);
                    at += source.len;
                    packet[at] = 0;
                    at += 1;
                    packet[at] = 0;
                    packet[at + 1] = 0;
                    at += 2;
                },
                'B' => {
                    @memset(packet[at..][0..8], 0);
                    at += 8;
                },
                else => {
                    @memset(packet[at..][0..5], 0);
                    at += 5;
                },
            }
            packet[0] = tag;
            put32(packet[1..5], @intCast(at - 1));
            const reply = try wires[index].handle(&conns[index], packet[0..at], &output);
            if (reply.blocked) return error.Blocked;
            @memcpy(all[all_len..][0..reply.written], output[0..reply.written]);
            all_len += reply.written;
        }
    }
    packet[0] = 'S';
    put32(packet[1..5], 4);
    const reply = try wires[index].handle(&conns[index], packet[0..5], &output);
    @memcpy(all[all_len..][0..reply.written], output[0..reply.written]);
    all_len += reply.written;
    var out: Out = .{};
    try reduce(all[0..all_len], &out);
    return canonical[0..out.len];
}

fn expectExtended(index: usize, sources: []const []const u8, want: []const u8) !void {
    const got = try extended(index, sources);
    if (!std.mem.eql(u8, got, want)) std.debug.print("extended {s}\n  got  {s}\n  want {s}\n", .{ sources[0], got, want });
    try check(std.mem.eql(u8, got, want));
}

/// Rows as `a|b;c|d` (NULL), engine text output.
fn render(target: *const DB.Result, buffer: []u8) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [DB.Io.format_bytes]u8 = undefined;
    for (0..target.row_count) |row| {
        if (row != 0) {
            buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try DB.Io.format(cell, false, DB.Result.default_session, &cell_buffer);
            @memcpy(buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return buffer[0..at];
}

fn read(db: *DB, source: []const u8, buffer: []u8) ![]const u8 {
    const slot = try db.begin();
    defer db.abort(slot);
    try db.statement(slot, source, &result, .{});
    return render(&result, buffer);
}

/// The replica answers like the primary.
fn sameOnReplica(source: []const u8) !void {
    const primary_rows = try read(&store.database, source, &text_primary);
    const replica_rows = try read(&replica, source, &text_replica);
    if (!std.mem.eql(u8, primary_rows, replica_rows)) std.debug.print("replica differs: {s}\n  primary {s}\n  replica {s}\n", .{ source, primary_rows, replica_rows });
    try check(std.mem.eql(u8, primary_rows, replica_rows));
}

const rows_probe = "SELECT a FROM t ORDER BY a";

// ---- COMMIT / ROLLBACK in CALL and DO ----------------------------------

fn basics() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE TABLE log(k TEXT, v TEXT)", "C:CREATE TABLE" },
    });
    probe = rows_probe;
    try steps(0, &.{
        .{ "CREATE PROCEDURE p1() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (1); COMMIT; INSERT INTO t VALUES (2); ROLLBACK; INSERT INTO t VALUES (3); END $$", "C:CREATE PROCEDURE" },
    });
    // Each COMMIT is its own record: the CALL writes two (1, then 3).
    const before = replayed;
    try steps(0, &.{
        .{ "CALL p1()", "C:CALL" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;3 C:SELECT 2" },
    });
    try check(replayed == before + 2);
    // An error after a COMMIT undoes only the work after it.
    try steps(0, &.{
        .{ "CREATE PROCEDURE p2() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (10); COMMIT; INSERT INTO t VALUES (11); PERFORM 1/0; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL p2()", "E:22012" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;3;10 C:SELECT 3" },
        .{ "DO $$ BEGIN INSERT INTO t VALUES (50); COMMIT; INSERT INTO t VALUES (51); ROLLBACK; END $$", "C:DO" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;3;10;50 C:SELECT 4" },
        // Variables survive COMMIT and ROLLBACK.
        .{ "CREATE PROCEDURE pvar() LANGUAGE plpgsql AS $$ DECLARE x int := 70; BEGIN x := x + 1; COMMIT; INSERT INTO t VALUES (x); ROLLBACK; x := x + 1; INSERT INTO t VALUES (x); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pvar()", "C:CALL" },
        .{ "SELECT a FROM t WHERE a > 60 ORDER BY a", "T:a;72 C:SELECT 1" },
        // Loops: each iteration commits or rolls back its own row.
        .{ "CREATE PROCEDURE ploop() LANGUAGE plpgsql AS $$ BEGIN FOR i IN 1..4 LOOP INSERT INTO t VALUES (100 + i); IF i % 2 = 0 THEN COMMIT; ELSE ROLLBACK; END IF; END LOOP; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL ploop()", "C:CALL" },
        .{ "SELECT a FROM t WHERE a > 100 ORDER BY a", "T:a;102;104 C:SELECT 2" },
        // INOUT results come from the variables after the COMMIT.
        .{ "CREATE PROCEDURE pinout(INOUT x int) LANGUAGE plpgsql AS $$ BEGIN x := x + 1; COMMIT; x := x * 10; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pinout(4)", "T:x;50 C:CALL" },
        // A WHILE loop with COMMIT AND CHAIN in every iteration.
        .{ "DELETE FROM t", "C:DELETE 7" },
        .{ "DO $$ DECLARE n int := 0; BEGIN WHILE n < 3 LOOP n := n + 1; INSERT INTO t VALUES (n); COMMIT AND CHAIN; END LOOP; INSERT INTO t VALUES (9); ROLLBACK AND NO CHAIN; END $$", "C:DO" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;2;3 C:SELECT 3" },
    });
}

// ---- nested CALL / DO chains, handlers --------------------------------

fn nesting() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE TABLE log(k TEXT, v TEXT)", "C:CREATE TABLE" },
    });
    probe = rows_probe;
    try steps(0, &.{
        .{ "CREATE PROCEDURE pin() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (60); COMMIT; INSERT INTO t VALUES (61); END $$", "C:CREATE PROCEDURE" },
        // The inner COMMIT also commits the caller's earlier row; the
        // caller's ROLLBACK undoes the row the inner one wrote after it.
        .{ "CREATE PROCEDURE pout() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (62); CALL pin(); ROLLBACK; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pout()", "C:CALL" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;60;62 C:SELECT 2" },
        .{ "DO $$ BEGIN CALL pin(); END $$", "C:DO" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;60;60;61;62 C:SELECT 4" },
        .{ "DO $$ BEGIN DO 'BEGIN INSERT INTO t VALUES (9); COMMIT; END'; END $$", "C:DO" },
        .{ "SELECT count(*) FROM t WHERE a = 9", "T:count;1 C:SELECT 1" },
        // An EXCEPTION block anywhere on the stack: 2D000, which a handler
        // of that block catches (the block's writes undone).
        .{ "DO $$ BEGIN BEGIN INSERT INTO t VALUES (70); CALL pin(); EXCEPTION WHEN invalid_transaction_termination THEN INSERT INTO log VALUES ('caught', SQLSTATE); END; END $$", "C:DO" },
        .{ "SELECT k, v FROM log", "T:k,v;caught|2D000 C:SELECT 1" },
        .{ "SELECT count(*) FROM t WHERE a IN (60, 70)", "T:count;2 C:SELECT 1" },
        // A handler runs outside its block's subtransaction: it may COMMIT.
        .{ "DELETE FROM t", "C:DELETE 5" },
        .{ "DO $$ BEGIN INSERT INTO t VALUES (1); PERFORM 1/0; EXCEPTION WHEN others THEN INSERT INTO t VALUES (2); COMMIT; INSERT INTO t VALUES (3); ROLLBACK; END $$", "C:DO" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;2 C:SELECT 1" },
        // A procedure that drops itself and commits keeps running.
        .{ "CREATE PROCEDURE pself() LANGUAGE plpgsql AS $$ BEGIN DROP PROCEDURE pself(); COMMIT; CREATE PROCEDURE pnew() LANGUAGE plpgsql AS 'BEGIN NULL; END'; INSERT INTO t VALUES (5); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pself()", "C:CALL" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;2;5 C:SELECT 2" },
        .{ "CALL pself()", "E:42883" },
        .{ "CALL pnew()", "C:CALL" },
    });
}

// ---- where PostgreSQL forbids it (2D000) ------------------------------

fn atomicContexts() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE PROCEDURE p1() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (1); COMMIT; INSERT INTO t VALUES (2); ROLLBACK; INSERT INTO t VALUES (3); END $$", "C:CREATE PROCEDURE" },
    });
    probe = rows_probe;
    try steps(0, &.{
        .{ "BEGIN", "C:BEGIN" },
        .{ "CALL p1()", "E:2D000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        // The implicit block of a multi-statement Query.
        .{ "CALL p1(); SELECT 1", "E:2D000" },
        .{ "SELECT count(*) FROM t", "T:count;0 C:SELECT 1" },
        // Below a function.
        .{ "CREATE FUNCTION f1() RETURNS int LANGUAGE plpgsql AS $$ BEGIN CALL p1(); RETURN 1; END $$", "C:CREATE FUNCTION" },
        .{ "SELECT f1()", "E:2D000" },
        .{ "CREATE FUNCTION fc() RETURNS int LANGUAGE plpgsql AS $$ BEGIN COMMIT; RETURN 1; END $$", "C:CREATE FUNCTION" },
        .{ "SELECT fc()", "E:2D000" },
        // Inside an EXCEPTION block.
        .{ "CREATE PROCEDURE pex() LANGUAGE plpgsql AS $$ BEGIN BEGIN INSERT INTO t VALUES (20); COMMIT; EXCEPTION WHEN division_by_zero THEN NULL; END; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pex()", "E:2D000" },
        // SECURITY DEFINER and SET routines.
        .{ "CREATE PROCEDURE pdef() LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN INSERT INTO t VALUES (30); COMMIT; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pdef()", "E:2D000" },
        .{ "CREATE PROCEDURE pset() LANGUAGE plpgsql SET search_path = public AS $$ BEGIN INSERT INTO t VALUES (40); COMMIT; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pset()", "E:2D000" },
        .{ "CREATE PROCEDURE pdefout() LANGUAGE plpgsql SECURITY DEFINER AS $$ BEGIN CALL p1(); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pdefout()", "E:2D000" },
        // A SQL-language routine calling one that commits.
        .{ "CREATE PROCEDURE psql1() LANGUAGE sql AS $$ CALL p1() $$", "C:CREATE PROCEDURE" },
        .{ "CALL psql1()", "E:2D000" },
        // A trigger function.
        .{ "CREATE TABLE trg(a INT)", "C:CREATE TABLE" },
        .{ "CREATE FUNCTION tf() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN COMMIT; RETURN NEW; END $$", "C:CREATE FUNCTION" },
        .{ "CREATE TRIGGER tt BEFORE INSERT ON trg FOR EACH ROW EXECUTE FUNCTION tf()", "C:CREATE TRIGGER" },
        .{ "INSERT INTO trg VALUES (1)", "E:2D000" },
        .{ "SELECT count(*) FROM t", "T:count;0 C:SELECT 1" },
    });
}

// ---- characteristics: AND CHAIN and SET TRANSACTION -------------------

fn characteristics() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE TABLE log(k TEXT, v TEXT)", "C:CREATE TABLE" },
    });
    probe = "SELECT k, v FROM log ORDER BY k";
    try steps(0, &.{
        .{ "CREATE PROCEDURE pchain() LANGUAGE plpgsql AS $$ BEGIN " ++
            "INSERT INTO log VALUES ('a', current_setting('transaction_isolation')); COMMIT; " ++
            "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; " ++
            "INSERT INTO log VALUES ('b', current_setting('transaction_isolation')); COMMIT AND CHAIN; " ++
            "INSERT INTO log VALUES ('c', current_setting('transaction_isolation')); ROLLBACK AND CHAIN; " ++
            "INSERT INTO log VALUES ('d', current_setting('transaction_isolation')); COMMIT; " ++
            "INSERT INTO log VALUES ('e', current_setting('transaction_isolation')); SET TRANSACTION READ ONLY; " ++
            "INSERT INTO log VALUES ('f', current_setting('transaction_read_only')); END $$", "C:CREATE PROCEDURE" },
        // f fails (25006): e, written after the last COMMIT, rolls back.
        .{ "CALL pchain()", "E:25006" },
        .{ "SELECT k, v FROM log ORDER BY k", "T:k,v;a|read committed;b|repeatable read;d|repeatable read C:SELECT 3" },
        .{ "DELETE FROM log", "C:DELETE 3" },
        // Before any COMMIT the CALL has taken its snapshot: 25001 for a new
        // isolation level, READ ONLY still allowed.
        .{ "CREATE PROCEDURE pst() LANGUAGE plpgsql AS $$ BEGIN SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; INSERT INTO log VALUES ('a', 'x'); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pst()", "E:25001" },
        .{ "CREATE PROCEDURE pro() LANGUAGE plpgsql AS $$ BEGIN SET TRANSACTION READ ONLY; INSERT INTO t VALUES (1); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pro()", "E:25006" },
        // AND CHAIN keeps READ ONLY.
        .{ "CREATE PROCEDURE pro2() LANGUAGE plpgsql AS $$ BEGIN COMMIT; SET TRANSACTION READ ONLY; COMMIT AND CHAIN; INSERT INTO t VALUES (1); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pro2()", "E:25006" },
        // After a query in the new transaction: 25001.
        .{ "CREATE PROCEDURE pro3() LANGUAGE plpgsql AS $$ BEGIN COMMIT; INSERT INTO t VALUES (5); SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pro3()", "E:25001" },
        .{ "SELECT count(*) FROM t", "T:count;0 C:SELECT 1" },
        // Two SET TRANSACTIONs before any query: the last level holds.
        .{ "CREATE PROCEDURE pro4() LANGUAGE plpgsql AS $$ BEGIN COMMIT; SET TRANSACTION ISOLATION LEVEL SERIALIZABLE; SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; INSERT INTO log VALUES ('x', current_setting('transaction_isolation')); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pro4()", "C:CALL" },
        .{ "SELECT k, v FROM log ORDER BY k", "T:k,v;x|repeatable read C:SELECT 1" },
        // The session's defaults start each new transaction.
        .{ "SET default_transaction_isolation = 'serializable'", "C:SET" },
        .{ "DO $$ BEGIN COMMIT; INSERT INTO log VALUES ('y', current_setting('transaction_isolation')); END $$", "C:DO" },
        .{ "RESET default_transaction_isolation", "C:RESET" },
        .{ "SELECT k, v FROM log ORDER BY k", "T:k,v;x|repeatable read;y|serializable C:SELECT 2" },
    });
}

// ---- lock waits before and after a COMMIT -----------------------------

fn lockWaits() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO t VALUES (1)", "C:INSERT 0 1" },
        .{ "CREATE PROCEDURE pw() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (200); UPDATE t SET a = a + 1000 WHERE a = 1; COMMIT; INSERT INTO t VALUES (300); END $$", "C:CREATE PROCEDURE" },
        .{ "CREATE PROCEDURE pl() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (400); COMMIT; UPDATE t SET a = a + 1000 WHERE a = 1001; INSERT INTO t VALUES (500); END $$", "C:CREATE PROCEDURE" },
    });
    // A wait before any COMMIT parks the CALL; once the holder ends it runs
    // from its start, so every effect happens once.
    try steps(1, &.{
        .{ "BEGIN", "C:BEGIN" },
        .{ "UPDATE t SET a = a WHERE a = 1", "C:UPDATE 1" },
    });
    try steps(0, &.{.{ "CALL pw()", "BLOCKED" }});
    try steps(1, &.{.{ "COMMIT", "C:COMMIT" }});
    try steps(0, &.{
        .{ "CALL pw()", "C:CALL" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;200;300;1001 C:SELECT 3" },
    });
    try sameOnReplica(rows_probe);
    // After a COMMIT the committed part must not run again: the wait fails
    // at once (PostgreSQL would wait; docs/SQL_PROC_TX.md) and only the work
    // after the COMMIT rolls back.
    try steps(1, &.{
        .{ "BEGIN", "C:BEGIN" },
        .{ "UPDATE t SET a = a WHERE a = 1001", "C:UPDATE 1" },
    });
    try steps(0, &.{
        .{ "CALL pl()", "E:55P03" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;200;300;400;1001 C:SELECT 4" },
    });
    try steps(1, &.{.{ "ROLLBACK", "C:ROLLBACK" }});
    try sameOnReplica(rows_probe);
    // A handler of a block after the COMMIT catches it.
    try steps(1, &.{
        .{ "BEGIN", "C:BEGIN" },
        .{ "UPDATE t SET a = a WHERE a = 1001", "C:UPDATE 1" },
    });
    try steps(0, &.{
        .{ "DO $$ BEGIN INSERT INTO t VALUES (600); COMMIT; BEGIN UPDATE t SET a = 0 WHERE a = 1001; EXCEPTION WHEN lock_not_available THEN INSERT INTO t VALUES (700); END; END $$", "C:DO" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;200;300;400;600;700;1001 C:SELECT 6" },
    });
    try steps(1, &.{.{ "ROLLBACK", "C:ROLLBACK" }});
    try sameOnReplica(rows_probe);
    try check(store.database.usage().transactions == 0);
}

// ---- the extended protocol ---------------------------------------------

fn extendedProtocol() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE PROCEDURE p1() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (1); COMMIT; INSERT INTO t VALUES (2); ROLLBACK; INSERT INTO t VALUES (3); END $$", "C:CREATE PROCEDURE" },
    });
    probe = rows_probe;
    // One CALL before Sync runs outside a transaction block.
    try expectExtended(0, &.{"CALL p1()"}, "C:CALL");
    try steps(0, &.{
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;3 C:SELECT 2" },
        .{ "DELETE FROM t", "C:DELETE 2" },
    });
    // A CALL first, then more commands: they run in its last transaction.
    try expectExtended(0, &.{ "CALL p1()", "INSERT INTO t VALUES (8)" }, "C:CALL C:INSERT 0 1");
    try steps(0, &.{
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;3;8 C:SELECT 3" },
        .{ "DELETE FROM t", "C:DELETE 3" },
    });
    // A pipelined CALL after another command is atomic: 2D000, and the
    // group rolls back.
    try expectExtended(0, &.{ "INSERT INTO t VALUES (7)", "CALL p1()" }, "C:INSERT 0 1 E:2D000");
    try expectExtended(0, &.{ "CALL p1()", "CALL p1()" }, "C:CALL E:2D000");
    try steps(0, &.{.{ "SELECT a FROM t ORDER BY a", "T:a;1 C:SELECT 1" }});
    try sameOnReplica(rows_probe);
}

// ---- deferred constraints, sequences, clocks ---------------------------

fn commitChecks() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE parent(id INT PRIMARY KEY)", "C:CREATE TABLE" },
        .{ "CREATE TABLE child(pid INT REFERENCES parent DEFERRABLE INITIALLY DEFERRED)", "C:CREATE TABLE" },
        .{ "CREATE SEQUENCE s", "C:CREATE SEQUENCE" },
    });
    probe = "SELECT id FROM parent ORDER BY id";
    try steps(0, &.{
        // A COMMIT inside the CALL checks deferred constraints: it fails
        // the CALL, rolling back the transaction it would have ended.
        .{ "CREATE PROCEDURE pd() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO parent VALUES (1); COMMIT; INSERT INTO child VALUES (5); COMMIT; INSERT INTO parent VALUES (2); END $$", "C:CREATE PROCEDURE" },
        .{ "CALL pd()", "E:23503" },
        .{ "SELECT id FROM parent ORDER BY id", "T:id;1 C:SELECT 1" },
        .{ "SELECT count(*) FROM child", "T:count;0 C:SELECT 1" },
        .{ "DO $$ BEGIN INSERT INTO child VALUES (3); INSERT INTO parent VALUES (3); COMMIT; INSERT INTO child VALUES (4); ROLLBACK; END $$", "C:DO" },
        .{ "SELECT pid FROM child ORDER BY pid", "T:pid;3 C:SELECT 1" },
        // Sequence values are never rolled back; each COMMIT logs them.
        .{ "DO $$ BEGIN PERFORM nextval('s'); ROLLBACK; PERFORM nextval('s'); COMMIT; PERFORM nextval('s'); END $$", "C:DO" },
        .{ "SELECT nextval('s')", "T:nextval;4 C:SELECT 1" },
    });
    try sameOnReplica("SELECT pid FROM child ORDER BY pid");
}

/// A wall clock that moves 1 ms per reading.
var ticks: i64 = 770_515_200_000_000;
fn movingClock() ?i64 {
    ticks += 1000;
    return ticks;
}

fn clocks() !void {
    try reset();
    store.wall_clock = &movingClock;
    try steps(0, &.{
        .{ "CREATE TABLE log(k TEXT, v TEXT)", "C:CREATE TABLE" },
        // now() is the transaction's start: after a COMMIT inside the DO it
        // moves on; statement_timestamp() stays the statement's.
        .{ "DO $$ BEGIN INSERT INTO log VALUES ('a', (now() = statement_timestamp())::text); COMMIT; " ++
            "INSERT INTO log VALUES ('b', (now() > statement_timestamp())::text); END $$", "C:DO" },
        .{ "SELECT k, v FROM log ORDER BY k", "T:k,v;a|true;b|true C:SELECT 2" },
        // The next statement's transaction starts with it again.
        .{ "SELECT now() = statement_timestamp()", "T:?column?;t C:SELECT 1" },
    });
}

// ---- SEARCH / CYCLE (T133) ----------------------------------------------

const cte_w = "WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 3) ";
const cte_g = "WITH RECURSIVE w(a, b) AS (SELECT a, b FROM g WHERE a = 1 UNION ALL SELECT g.a, g.b FROM g JOIN w ON g.a = w.b) ";

fn searchCycle() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE g(a INT, b INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO g VALUES (1, 2), (2, 3), (3, 1)", "C:INSERT 0 3" },
        // The T133 probe: marks, the record[] path and the sequence.
        .{ cte_g ++ "CYCLE a SET looped TO 'Y' DEFAULT 'N' USING path SELECT a, b, looped FROM w", "T:a,b,looped;1|2|N;2|3|N;3|1|N;1|2|Y C:SELECT 4" },
        .{ cte_g ++ "CYCLE a SET looped USING path SELECT a, looped, path FROM w", "T:a,looped,path;1|f|{(1)};2|f|{(1),(2)};3|f|{(1),(2),(3)};1|t|{(1),(2),(3),(1)} C:SELECT 4" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET ord SELECT a, ord FROM w ORDER BY ord", "T:a,ord;1|{(1)};2|{(1),(2)};3|{(1),(2),(3)} C:SELECT 3" },
        .{ cte_w ++ "SEARCH BREADTH FIRST BY a SET ord SELECT * FROM w ORDER BY ord", "T:a,ord;1|(0,1);2|(1,2);3|(2,3) C:SELECT 3" },
        .{ cte_g ++ "SEARCH DEPTH FIRST BY a, b SET ord CYCLE a, b SET looped USING path SELECT * FROM w",
            "T:a,b,ord,looped,path;1|2|{\"(1,2)\"}|f|{\"(1,2)\"};2|3|{\"(1,2)\",\"(2,3)\"}|f|{\"(1,2)\",\"(2,3)\"};3|1|{\"(1,2)\",\"(2,3)\",\"(3,1)\"}|f|{\"(1,2)\",\"(2,3)\",\"(3,1)\"};" ++
                "1|2|{\"(1,2)\",\"(2,3)\",\"(3,1)\",\"(1,2)\"}|t|{\"(1,2)\",\"(2,3)\",\"(3,1)\",\"(1,2)\"} C:SELECT 4" },
        // record_out and array_out quoting, NULL fields, empty strings.
        .{ "WITH RECURSIVE w(a, t) AS (SELECT 1, 'x y'::text UNION ALL SELECT a + 1, CASE WHEN a = 1 THEN NULL ELSE 'q\"z' END FROM w WHERE a < 4) CYCLE a, t SET c USING p SELECT * FROM w",
            "T:a,t,c,p;1|x y|f|{\"(1,\\\"x y\\\")\"};2|\\N|f|{\"(1,\\\"x y\\\")\",\"(2,)\"};3|q\"z|f|{\"(1,\\\"x y\\\")\",\"(2,)\",\"(3,\\\"q\\\"\\\"z\\\")\"};" ++
                "4|q\"z|f|{\"(1,\\\"x y\\\")\",\"(2,)\",\"(3,\\\"q\\\"\\\"z\\\")\",\"(4,\\\"q\\\"\\\"z\\\")\"} C:SELECT 4" },
        .{ "WITH RECURSIVE w(a, t) AS (SELECT 1, ''::text UNION ALL SELECT a + 1, 'a,b' FROM w WHERE a < 3) SEARCH BREADTH FIRST BY a, t SET o SELECT * FROM w", "T:a,t,o;1||(0,1,\"\");2|a,b|(1,2,\"a,b\");3|a,b|(2,3,\"a,b\") C:SELECT 3" },
        .{ "WITH RECURSIVE w(a, f) AS (SELECT 1, true UNION ALL SELECT a + 1, NOT f FROM w WHERE a < 3) SEARCH DEPTH FIRST BY f, a SET o SELECT o, a FROM w ORDER BY o", "T:o,a;{\"(t,1)\"}|1;{\"(t,1)\",\"(f,2)\"}|2;{\"(t,1)\",\"(f,2)\",\"(t,3)\"}|3 C:SELECT 3" },
        .{ "WITH RECURSIVE w(a, d) AS (SELECT 1, 1.5::numeric UNION ALL SELECT a + 1, d * 2 FROM w WHERE a < 3) CYCLE d SET m USING p SELECT * FROM w", "T:a,d,m,p;1|1.5|f|{(1.5)};2|3.0|f|{(1.5),(3.0)};3|6.0|f|{(1.5),(3.0),(6.0)} C:SELECT 3" },
        .{ "WITH RECURSIVE w(a, d) AS (SELECT 1, date '2024-01-01' UNION ALL SELECT a + 1, d + 1 FROM w WHERE a < 3) SEARCH DEPTH FIRST BY d SET o SELECT * FROM w", "T:a,d,o;1|2024-01-01|{(2024-01-01)};2|2024-01-02|{(2024-01-01),(2024-01-02)};3|2024-01-03|{(2024-01-01),(2024-01-02),(2024-01-03)} C:SELECT 3" },
        .{ "WITH RECURSIVE w(a, x) AS (SELECT 1, 1.5::float8 UNION ALL SELECT a + 1, x / 3 FROM w WHERE a < 3) SEARCH BREADTH FIRST BY x SET o SELECT * FROM w", "T:a,x,o;1|1.5|(0,1.5);2|0.5|(1,0.5);3|0.16666666666666666|(2,0.16666666666666666) C:SELECT 3" },
        // Ordering compares the records field by field, not their text.
        .{ "WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 12) SEARCH DEPTH FIRST BY a SET o SELECT a FROM w ORDER BY o DESC LIMIT 3", "T:a;12;11;10 C:SELECT 3" },
        .{ "WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 12) CYCLE a SET m USING p SELECT a FROM w ORDER BY p DESC LIMIT 2", "T:a;12;11 C:SELECT 2" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT o FROM w ORDER BY 1 DESC", "T:o;{(1),(2),(3)};{(1),(2)};{(1)} C:SELECT 3" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT x.o FROM w AS x ORDER BY x.o DESC", "T:o;{(1),(2),(3)};{(1),(2)};{(1)} C:SELECT 3" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT a FROM w ORDER BY o, a", "T:a;1;2;3 C:SELECT 3" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT * FROM w ORDER BY p DESC", "T:a,m,p;3|f|{(1),(2),(3)};2|f|{(1),(2)};1|f|{(1)} C:SELECT 3" },
        .{ cte_w ++ "SEARCH BREADTH FIRST BY a SET o SELECT o FROM w WHERE a = 2", "T:o;(1,2) C:SELECT 1" },
        .{ "WITH RECURSIVE w(a) AS (SELECT 1 UNION SELECT a + 1 FROM w WHERE a < 3) CYCLE a SET m USING p SELECT * FROM w", "T:a,m,p;1|f|{(1)};2|f|{(1),(2)};3|f|{(1),(2),(3)} C:SELECT 3" },
        // The record types: their names, text casts, equality, DISTINCT.
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT pg_typeof(o), o::text FROM w LIMIT 1", "T:pg_typeof,o;record[]|{(1)} C:SELECT 1" },
        .{ cte_w ++ "SEARCH BREADTH FIRST BY a SET o SELECT pg_typeof(o) FROM w LIMIT 1", "T:pg_typeof;record C:SELECT 1" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p::text || '!' AS t, length(p::text) FROM w", "T:t,length;{(1)}!|5;{(1),(2)}!|9;{(1),(2),(3)}!|13 C:SELECT 3" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT count(DISTINCT p), max(a) FROM w", "T:count,max;3|3 C:SELECT 1" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p = p FROM w LIMIT 1", "T:?column?;t C:SELECT 1" },
        .{ "CREATE TABLE s(x text)", "C:CREATE TABLE" },
        .{ "INSERT INTO s " ++ cte_w ++ "CYCLE a SET m USING p SELECT p FROM w", "C:INSERT 0 3" },
        .{ "SELECT x FROM s ORDER BY x", "T:x;{(1),(2),(3)};{(1),(2)};{(1)} C:SELECT 3" },
        // No table or view column has a pseudo-type (42P16).
        .{ "CREATE TABLE keep AS " ++ cte_w ++ "SEARCH BREADTH FIRST BY a SET o SELECT * FROM w", "E:42P16" },
        .{ "CREATE VIEW v AS " ++ cte_w ++ "CYCLE a SET m USING p SELECT * FROM w", "E:42P16" },
        // Names: a reference in the recursive term to a WITH column named
        // like a SEARCH / CYCLE column is ambiguous (42702); otherwise the
        // clash is 42601. Listed columns must exist (42601), once (42701).
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET a SELECT 1 FROM w", "E:42702" },
        .{ cte_w ++ "CYCLE a SET a USING p SELECT 1 FROM w", "E:42702" },
        .{ cte_w ++ "CYCLE a SET m USING a SELECT 1 FROM w", "E:42702" },
        .{ "WITH RECURSIVE w(a, b) AS (SELECT 1, 2 UNION ALL SELECT a + 1, 5 FROM w WHERE a < 3) SEARCH BREADTH FIRST BY a SET b SELECT 1 FROM w", "E:42601" },
        .{ cte_w ++ "CYCLE a SET m USING m SELECT * FROM w", "E:42601" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET m CYCLE a SET m USING p SELECT * FROM w", "E:42601" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET p CYCLE a SET m USING p SELECT * FROM w", "E:42601" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY z SET o SELECT * FROM w", "E:42601" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a, a SET o SELECT * FROM w", "E:42701" },
        .{ cte_w ++ "CYCLE z SET m USING p SELECT * FROM w", "E:42601" },
        .{ cte_w ++ "CYCLE a, a SET m USING p SELECT * FROM w", "E:42701" },
        .{ cte_w ++ "CYCLE a SET m TO 1 DEFAULT 'x' USING p SELECT * FROM w", "E:22P02" },
        .{ "WITH w(a) AS (SELECT 1) SEARCH DEPTH FIRST BY a SET o SELECT * FROM w", "E:42601" },
        .{ "WITH RECURSIVE w(a) AS (SELECT 1) SEARCH DEPTH FIRST BY a SET o SELECT * FROM w", "E:42601" },
        .{ "WITH RECURSIVE w(a, j) AS (SELECT 1, '{}'::json UNION ALL SELECT a + 1, j FROM w WHERE a < 3) CYCLE j SET m USING p SELECT a FROM w", "E:42883" },
        // NULL fields, an element spelled NULL and one with braces.
        .{ "WITH RECURSIVE w(a, t) AS (SELECT 1, 'NULL'::text UNION ALL SELECT a + 1, '{x}' FROM w WHERE a < 3) CYCLE t SET m USING p SELECT p FROM w", "T:p;{(NULL)};{(NULL),\"({x})\"};{(NULL),\"({x})\",\"({x})\"} C:SELECT 3" },
        .{ "WITH RECURSIVE w(a, t) AS (SELECT 1, NULL::text UNION ALL SELECT a + 1, NULL FROM w WHERE a < 3) SEARCH DEPTH FIRST BY t SET o SELECT a, o FROM w ORDER BY o", "T:a,o;1|{()};2|{(),()};3|{(),(),()} C:SELECT 3" },
        .{ cte_w ++ "SEARCH BREADTH FIRST BY a SET o CYCLE a SET m USING p SELECT * FROM w ORDER BY o DESC", "T:a,o,m,p;3|(2,3)|f|{(1),(2),(3)};2|(1,2)|f|{(1),(2)};1|(0,1)|f|{(1)} C:SELECT 3" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p IS NULL, p IS DISTINCT FROM p FROM w LIMIT 1", "T:?column?,?column?;f|f C:SELECT 1" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT length(p) FROM w", "E:42883" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p::int FROM w", "E:42846" },
    });
    // Not PostgreSQL's (docs/SQL_PROC_TX.md): what needs record and
    // record[] operators fails (0A000) where PostgreSQL computes it,
    // instead of acting on the values' text, and a path longer than a text
    // value is 54000.
    try steps(0, &.{
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT * FROM (SELECT o, a FROM w) q ORDER BY o DESC", "E:0A000" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p FROM w UNION SELECT p FROM w ORDER BY 1", "E:0A000" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p FROM w GROUP BY p ORDER BY p", "E:0A000" },
        .{ "WITH RECURSIVE w(a, n) AS (SELECT 1, 1.5::numeric UNION ALL SELECT a + 1, n + 1 FROM w WHERE a < 3) CYCLE n SET m USING p SELECT a FROM w ORDER BY p", "E:0A000" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT json_agg(p) FROM w", "E:0A000" },
        .{ cte_w ++ "CYCLE a SET m USING p SELECT p || 'x' FROM w", "E:0A000" },
        .{ cte_w ++ "SEARCH DEPTH FIRST BY a SET o SELECT a FROM w WHERE o > ARRAY[ROW(1)]", "E:0A000" },
        .{ "WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 120) CYCLE a SET m USING p SELECT a, p FROM w ORDER BY a DESC LIMIT 1", "E:54000" },
    });
    // A path the statement never reads is never built.
    try steps(0, &.{.{ "WITH RECURSIVE w(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM w WHERE a < 120) CYCLE a SET m USING p SELECT max(a), bool_or(m) FROM w", "T:max,bool_or;120|f C:SELECT 1" }});
    // The path text a statement stored replays like any text.
    try sameOnReplica("SELECT x FROM s ORDER BY x");
}

// ---- a crash between two COMMITs ---------------------------------------

var recovery: DB = .{};
var recovery_scratch: DB.ReplayScratch = .{};

fn crash() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "CREATE PROCEDURE p3() LANGUAGE plpgsql AS $$ BEGIN INSERT INTO t VALUES (1); COMMIT; INSERT INTO t VALUES (2); COMMIT; INSERT INTO t VALUES (3); END $$", "C:CREATE PROCEDURE" },
    });
    // The second COMMIT's record never reaches the log.
    crash_at = durable_count + 1;
    var out: DB.Result = .{};
    if (conns[0].execute("CALL p3()", &out)) |_| return error.CrashIgnored else |err| try check(err == error.InjectedCrash);
    try check(store.storage_failed and conns[0].transactionStatus() == 'I');
    try check(store.database.usage().transactions == 0);
    // Recovery from the log keeps the first COMMIT only.
    recovery = .{};
    for (0..durable_count) |index| try recovery.applyChangeRecord(durable[index][0..durable_len[index]], &recovery_scratch);
    const got = try read(&recovery, rows_probe, &text_replica);
    try check(std.mem.eql(u8, got, "1"));
    // The primary published nothing past the failed record either.
    const live = try read(&store.database, rows_probe, &text_primary);
    try check(std.mem.eql(u8, live, "1"));
    // A failed store refuses later writes (58030) until its owner recovers.
    try steps(0, &.{.{ "CALL p3()", "E:58030" }});
    store.storage_failed = false;
    crash_at = null;
    try steps(0, &.{
        .{ "CALL p3()", "C:CALL" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;1;2;3 C:SELECT 4" },
    });
    try sameOnReplica(rows_probe);
}

pub fn main() !void {
    try basics();
    try nesting();
    try atomicContexts();
    try characteristics();
    try lockWaits();
    try extendedProtocol();
    try commitChecks();
    try clocks();
    try crash();
    try searchCycle();
    try check(replayed != 0);
    std.debug.print("proc-tx contract: {d} assertions, {d} records replayed\n", .{ assertions, replayed });
}
