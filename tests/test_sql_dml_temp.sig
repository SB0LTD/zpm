//! DML, query-shape, cursor, transaction and view contracts (conformance
//! lane B11 wave 5, dml-temp): subqueries in UPDATE / DELETE / INSERT under
//! the statement snapshot, row comparisons with row subqueries, JOIN USING
//! aliases, catalog-qualified names, ORDER BY / FETCH / OFFSET inside
//! parenthesized set operands, COMMIT / ROLLBACK AND CHAIN, SET TIME ZONE
//! INTERVAL, positioned UPDATE / DELETE (WHERE CURRENT OF), pg_cursors,
//! CREATE VIEW ... WITH CHECK OPTION (replayed from change-log op 115 on a
//! replica that must answer like the primary) and a CHECK constraint on
//! CURRENT_DATE.
//!
//! Every statement runs through the PostgreSQL wire over store connections,
//! one simple Query each, and each response reduces to its command tags,
//! SQLSTATEs, column names and data rows. Every expectation was checked
//! against native PostgreSQL 18.7 (statement by statement, values, NULLs,
//! SQLSTATEs and row order where the statement orders). Deviations that
//! native does not share are listed in docs/SQL_DML_TEMP.md.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const DB = sql.Database(.{ .tables = 16, .columns = 16, .rows_per_table = 64, .name_bytes = 63, .text_bytes = 512,
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

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("dml-temp contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.DmlTempContractFailed;
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

/// Every committed record replays into the replica (the store's WAL sink).
fn replicate(_: ?*anyopaque, payload: []const u8) anyerror!void {
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
    for ([_][]const u8{ "user", "ramsql", "database", "w5_dml_temp", "client_encoding", "UTF8", "TimeZone", "UTC" }) |item| {
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

/// One simple Query on connection `index`, reduced to `T:names` (column
/// names), `;cells|...` per data row (NULL as \N), ` C:tag` and ` E:state`.
fn run(index: usize, source: []const u8) ![]const u8 {
    packet[0] = 'Q';
    @memcpy(packet[5..][0..source.len], source);
    packet[5 + source.len] = 0;
    const length = 4 + source.len + 1;
    put32(packet[1..5], @intCast(length));
    const reply = try wires[index].handle(&conns[index], packet[0 .. 1 + length], &output);
    if (reply.blocked) return error.Blocked;
    const bytes = output[0..reply.written];
    var out: Out = .{};
    // A failing statement's RowDescription and DataRows are dropped, as
    // clients drop them (libpq returns only the error).
    var mark: usize = 0;
    var at: usize = 0;
    while (at + 5 <= bytes.len) {
        const kind = bytes[at];
        const n = be32(bytes[at + 1 ..][0..4]);
        const body = bytes[at + 5 .. at + 1 + n];
        at += 1 + n;
        switch (kind) {
            'T' => {
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
            },
            else => {},
        }
    }
    return canonical[0..out.len];
}

const Step = struct { []const u8, []const u8 };

/// Runs steps on connection `index`, each checked against its native
/// PostgreSQL 18.7 response.
fn steps(index: usize, list: []const Step) !void {
    for (list) |step| {
        const got = try run(index, step[0]);
        if (!std.mem.eql(u8, got, step[1])) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ step[0], got, step[1] });
        try check(std.mem.eql(u8, got, step[1]));
    }
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

// ---- subqueries in DML (E153, F781, F471) -----------------------------

fn dmlSubqueries() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE u(a INT, b INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO u VALUES (1, 0), (2, 0), (3, 0)", "C:INSERT 0 3" },
        .{ "UPDATE u SET b = 1 WHERE a IN (SELECT a FROM u WHERE a > 1)", "C:UPDATE 2" },
        // The subquery reads the statement snapshot: rows this UPDATE
        // writes are invisible to it (max stays 3 for every row).
        .{ "UPDATE u SET a = (SELECT max(a) FROM u) + a", "C:UPDATE 3" },
        .{ "DELETE FROM u WHERE a = (SELECT min(a) FROM u)", "C:DELETE 1" },
        .{ "INSERT INTO u VALUES ((SELECT max(a) FROM u), 5), ((SELECT count(*) FROM u), 6)", "C:INSERT 0 2" },
        .{ "UPDATE u SET b = (SELECT count(*) FROM u w WHERE w.a < u.a)", "C:UPDATE 4" },
        .{ "SELECT * FROM u ORDER BY a, b", "T:a,b;2|0;5|1;6|2;6|2 C:SELECT 4" },
        // A scalar subquery with two rows fails the statement atomically.
        .{ "UPDATE u SET b = (SELECT a FROM u)", "E:21000" },
        .{ "DELETE FROM u WHERE EXISTS (SELECT 1 FROM u w WHERE w.a > u.a)", "C:DELETE 2" },
        .{ "SELECT * FROM u ORDER BY a, b", "T:a,b;6|2;6|2 C:SELECT 2" },
    });
    try sameOnReplica("SELECT a, b FROM u ORDER BY a, b");
    // The probes' shapes (self reference, other tables, views).
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO t VALUES (1), (2)", "C:INSERT 0 2" },
        .{ "INSERT INTO t SELECT a + 10 FROM t", "C:INSERT 0 2" },
        .{ "UPDATE t SET a = a + (SELECT max(a) FROM t) WHERE a < 3", "C:UPDATE 2" },
        .{ "DELETE FROM t WHERE a = (SELECT min(a) FROM t)", "C:DELETE 1" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;12;13;14 C:SELECT 3" },
        .{ "CREATE TABLE s(a INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO s VALUES (13)", "C:INSERT 0 1" },
        .{ "CREATE VIEW sv AS SELECT a FROM t WHERE a IN (SELECT a FROM s)", "C:CREATE VIEW" },
        .{ "UPDATE sv SET a = 30", "C:UPDATE 1" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;12;14;30 C:SELECT 3" },
    });
    try sameOnReplica("SELECT a FROM t ORDER BY a");
}

// ---- query shapes (F641, F404, F651, F855, F856, F863) ----------------

fn queryShapes() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE a(id INT, x TEXT)", "C:CREATE TABLE" },
        .{ "CREATE TABLE b(id INT, y TEXT)", "C:CREATE TABLE" },
        .{ "INSERT INTO a VALUES (1, 'a'), (2, 'b')", "C:INSERT 0 2" },
        .{ "INSERT INTO b VALUES (2, 'c'), (3, 'd')", "C:INSERT 0 2" },
        // Row subqueries.
        .{ "SELECT id FROM a WHERE (id, x) = (SELECT 2, 'b')", "T:id;2 C:SELECT 1" },
        .{ "SELECT id FROM a WHERE (id, x) = (SELECT 1)", "E:42601" },
        .{ "SELECT id FROM a WHERE (id, x) = (SELECT id, x FROM a)", "E:21000" },
        .{ "SELECT id FROM a WHERE (id, x) = (SELECT 3, 'z' WHERE false)", "T:id C:SELECT 0" },
        .{ "SELECT id FROM a WHERE (id, x) < (SELECT 2, 'b') ORDER BY 1", "T:id;1 C:SELECT 1" },
        .{ "SELECT id FROM a WHERE (id, x) <> (SELECT 2, 'b') ORDER BY 1", "T:id;1 C:SELECT 1" },
        .{ "SELECT id, (id, x) IS DISTINCT FROM (SELECT 2, 'b') FROM a", "E:42601" },
        // JOIN ... USING (...) AS alias names the merged columns only.
        .{ "SELECT j.id, x, y FROM a JOIN b USING (id) AS j", "T:id,x,y;2|b|c C:SELECT 1" },
        .{ "SELECT j.x FROM a JOIN b USING (id) AS j", "E:42703" },
        .{ "SELECT j.id, a.id, b.id FROM a LEFT JOIN b USING (id) AS j ORDER BY 2", "T:id,id,id;1|1|\\N;2|2|2 C:SELECT 2" },
        .{ "SELECT j.id FROM a FULL JOIN b USING (id) AS j ORDER BY 1", "T:id;1;2;3 C:SELECT 3" },
        .{ "SELECT j.id FROM a RIGHT JOIN b USING (id) AS j ORDER BY 1", "T:id;2;3 C:SELECT 2" },
        // Catalog-qualified names: this database only.
        .{ "INSERT INTO w5_dml_temp.public.a VALUES (3, 'q')", "C:INSERT 0 1" },
        .{ "UPDATE w5_dml_temp.public.a SET x = 'r' WHERE id = 3", "C:UPDATE 1" },
        .{ "SELECT w5_dml_temp.public.a.x, public.a.id FROM w5_dml_temp.public.a WHERE id = 3", "T:x,id;r|3 C:SELECT 1" },
        .{ "DELETE FROM w5_dml_temp.public.a WHERE id = 3", "C:DELETE 1" },
        .{ "SELECT x FROM otherdb.public.a", "E:0A000" },
        .{ "INSERT INTO otherdb.public.a VALUES (1)", "E:0A000" },
        // ORDER BY / FETCH / OFFSET inside parenthesized operands.
        .{ "(SELECT 2 AS x ORDER BY 1) UNION ALL (SELECT 1 ORDER BY 1)", "T:x;2;1 C:SELECT 2" },
        .{ "SELECT x FROM ((SELECT 3 AS x UNION SELECT 1 ORDER BY x LIMIT 1) UNION ALL SELECT 5) s ORDER BY x", "T:x;1;5 C:SELECT 2" },
        .{ "(SELECT id FROM a ORDER BY id FETCH FIRST 1 ROW ONLY) UNION ALL (SELECT id FROM b ORDER BY id DESC FETCH FIRST 1 ROW ONLY)", "T:id;1;3 C:SELECT 2" },
        .{ "(SELECT id FROM a ORDER BY id OFFSET 1) UNION ALL (SELECT id FROM b ORDER BY id DESC OFFSET 1)", "T:id;2;2 C:SELECT 2" },
        .{ "(SELECT 1 LIMIT 2) LIMIT 1", "E:42601" },
        .{ "(SELECT 1 AS v UNION SELECT 2) ORDER BY 1 DESC", "T:v;2;1 C:SELECT 2" },
        // A parenthesized derived table inside a join group stays a join.
        .{ "SELECT * FROM ((SELECT 1 AS q) s JOIN a ON true) ORDER BY 2", "T:q,id,x;1|1|a;1|2|b C:SELECT 2" },
        .{ "SELECT * FROM ((SELECT 1 AS q)) s", "T:q;1 C:SELECT 1" },
        .{ "SELECT * FROM (((SELECT 1 AS q)) UNION ALL (SELECT 2)) s ORDER BY 1", "T:q;1;2 C:SELECT 2" },
    });
    // Capacity: more catalog qualifiers than one statement holds (54001).
    try steps(0, &.{.{ "SELECT 1 FROM w5_dml_temp.public.a a1, w5_dml_temp.public.a a2, w5_dml_temp.public.a a3, w5_dml_temp.public.a a4, " ++
        "w5_dml_temp.public.a a5, w5_dml_temp.public.a a6, w5_dml_temp.public.a a7, w5_dml_temp.public.a a8, w5_dml_temp.public.a a9", "E:54001" }});
}

// ---- transactions and session (T261, F761) ----------------------------

fn transactions() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT)", "C:CREATE TABLE" },
        .{ "BEGIN ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE", "C:BEGIN" },
        .{ "COMMIT AND CHAIN", "C:COMMIT" },
        .{ "SHOW transaction_isolation", "T:transaction_isolation;serializable C:SHOW" },
        .{ "SHOW transaction_read_only", "T:transaction_read_only;on C:SHOW" },
        .{ "SHOW transaction_deferrable", "T:transaction_deferrable;on C:SHOW" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN ISOLATION LEVEL REPEATABLE READ", "C:BEGIN" },
        .{ "INSERT INTO t VALUES (1)", "C:INSERT 0 1" },
        .{ "COMMIT AND CHAIN", "C:COMMIT" },
        .{ "SHOW transaction_isolation", "T:transaction_isolation;repeatable read C:SHOW" },
        .{ "INSERT INTO t VALUES (2)", "C:INSERT 0 1" },
        .{ "ROLLBACK AND CHAIN", "C:ROLLBACK" },
        .{ "SHOW transaction_isolation", "T:transaction_isolation;repeatable read C:SHOW" },
        .{ "COMMIT AND NO CHAIN", "C:COMMIT" },
        .{ "SELECT a FROM t", "T:a;1 C:SELECT 1" },
        // Outside a block: 25P01 for every spelling.
        .{ "COMMIT AND CHAIN", "E:25P01" },
        .{ "END AND CHAIN", "E:25P01" },
        .{ "ROLLBACK AND CHAIN", "E:25P01" },
        .{ "ABORT WORK AND CHAIN", "E:25P01" },
        // A failure outside any savepoint undoes the characteristics.
        .{ "BEGIN", "C:BEGIN" },
        .{ "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "C:SET" },
        .{ "INSERT INTO t VALUES (3)", "C:INSERT 0 1" },
        .{ "SELECT 1/0", "E:22012" },
        .{ "COMMIT AND CHAIN", "C:ROLLBACK" },
        .{ "SHOW transaction_isolation", "T:transaction_isolation;read committed C:SHOW" },
        .{ "INSERT INTO t VALUES (4)", "C:INSERT 0 1" },
        .{ "END TRANSACTION AND CHAIN", "C:COMMIT" },
        .{ "INSERT INTO t VALUES (5)", "C:INSERT 0 1" },
        .{ "ABORT AND CHAIN", "C:ROLLBACK" },
        .{ "COMMIT", "C:COMMIT" },
        // ... inside a savepoint it keeps them.
        .{ "BEGIN ISOLATION LEVEL REPEATABLE READ", "C:BEGIN" },
        .{ "SAVEPOINT s", "C:SAVEPOINT" },
        .{ "SELECT 1/0", "E:22012" },
        .{ "ROLLBACK AND CHAIN", "C:ROLLBACK" },
        .{ "SHOW transaction_isolation", "T:transaction_isolation;repeatable read C:SHOW" },
        .{ "COMMIT", "C:COMMIT" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;1;4 C:SELECT 2" },
    });
    try sameOnReplica("SELECT a FROM t ORDER BY a");
    try steps(0, &.{
        .{ "SET TIME ZONE INTERVAL '+02:00' HOUR TO MINUTE", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<+02>-02 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '-05:30' HOUR TO MINUTE", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<-05:30>+05:30 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '3' HOUR", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<+03>-03 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '90' MINUTE", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<+01:30>-01:30 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '01:30:45'", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<+01:30:45>-01:30:45 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '01:30:45' HOUR TO MINUTE", "C:SET" },
        .{ "SHOW TimeZone", "T:TimeZone;<+01:30>-01:30 C:SHOW" },
        .{ "SET TIME ZONE INTERVAL '1 day'", "E:22023" },
        .{ "SET TIME ZONE INTERVAL '1' DAY", "E:42601" },
        .{ "SELECT TIMESTAMPTZ '2024-01-01 00:00:00+00'", "T:timestamptz;2024-01-01 01:30:00+01:30 C:SELECT 1" },
        .{ "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY", "C:SET" },
        .{ "CREATE TABLE ro(a INT)", "E:25006" },
        .{ "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "C:SET" },
    });
}

// ---- cursors (E121-06, E121-07, E121-08) ------------------------------

fn cursors() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT, b INT)", "C:CREATE TABLE" },
        .{ "CREATE TABLE u(a INT)", "C:CREATE TABLE" },
        .{ "INSERT INTO t VALUES (1, 0), (2, 0), (3, 0)", "C:INSERT 0 3" },
        .{ "INSERT INTO u VALUES (1)", "C:INSERT 0 1" },
        // A sorted scan without FOR UPDATE is not simply updatable.
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE c CURSOR FOR SELECT a FROM t ORDER BY a", "C:DECLARE CURSOR" },
        .{ "UPDATE t SET b = 1 WHERE CURRENT OF c", "E:24000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE d CURSOR FOR SELECT t.a FROM t JOIN u ON t.a = u.a", "C:DECLARE CURSOR" },
        .{ "FETCH d", "T:a;1 C:FETCH 1" },
        .{ "UPDATE t SET b = 1 WHERE CURRENT OF d", "E:24000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "UPDATE t SET b = 1 WHERE CURRENT OF nosuch", "E:34000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE f CURSOR FOR SELECT a, b FROM t WHERE a >= 2 FOR UPDATE", "C:DECLARE CURSOR" },
        .{ "UPDATE t SET b = 1 WHERE CURRENT OF f", "E:24000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE f CURSOR FOR SELECT a, b FROM t WHERE a >= 2 FOR UPDATE", "C:DECLARE CURSOR" },
        .{ "FETCH f", "T:a,b;2|0 C:FETCH 1" },
        .{ "UPDATE t SET b = b + 10 WHERE CURRENT OF f RETURNING a, b", "T:a,b;2|10 C:UPDATE 1" },
        .{ "UPDATE t SET b = b + 10 WHERE CURRENT OF f RETURNING a, b", "T:a,b;2|20 C:UPDATE 1" },
        .{ "UPDATE u SET a = 5 WHERE CURRENT OF f", "E:24000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE f CURSOR FOR SELECT a, b FROM t WHERE a >= 2 ORDER BY a DESC FOR UPDATE", "C:DECLARE CURSOR" },
        .{ "FETCH f", "T:a,b;3|0 C:FETCH 1" },
        .{ "DELETE FROM t WHERE CURRENT OF f RETURNING *", "T:a,b;3|0 C:DELETE 1" },
        .{ "DELETE FROM t WHERE CURRENT OF f", "C:DELETE 0" },
        .{ "FETCH f", "T:a,b;2|0 C:FETCH 1" },
        .{ "UPDATE t SET b = 7 WHERE CURRENT OF f", "C:UPDATE 1" },
        .{ "FETCH f", "T:a,b C:FETCH 0" },
        .{ "UPDATE t SET b = 8 WHERE CURRENT OF f", "E:24000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE f CURSOR FOR SELECT a, b FROM t WHERE a >= 2 ORDER BY a DESC FOR UPDATE", "C:DECLARE CURSOR" },
        .{ "FETCH f", "T:a,b;3|0 C:FETCH 1" },
        .{ "DELETE FROM t WHERE CURRENT OF f", "C:DELETE 1" },
        .{ "FETCH f", "T:a,b;2|0 C:FETCH 1" },
        .{ "UPDATE t SET b = 7 WHERE CURRENT OF f", "C:UPDATE 1" },
        .{ "COMMIT", "C:COMMIT" },
        .{ "SELECT a, b FROM t ORDER BY a", "T:a,b;1|0;2|7 C:SELECT 2" },
        // A plain scan is simply updatable; WITH HOLD only in its own
        // transaction.
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE h CURSOR WITH HOLD FOR SELECT a FROM t", "C:DECLARE CURSOR" },
        .{ "DECLARE n NO SCROLL CURSOR FOR SELECT a FROM t", "C:DECLARE CURSOR" },
        .{ "SELECT name, statement, is_holdable, is_binary, is_scrollable, creation_time IS NOT NULL FROM pg_cursors ORDER BY name",
            "T:name,statement,is_holdable,is_binary,is_scrollable,?column?;h|DECLARE h CURSOR WITH HOLD FOR SELECT a FROM t|t|f|t|t;n|DECLARE n NO SCROLL CURSOR FOR SELECT a FROM t|f|f|f|t C:SELECT 2" },
        .{ "FETCH h", "T:a;1 C:FETCH 1" },
        .{ "UPDATE t SET b = 5 WHERE CURRENT OF h", "C:UPDATE 1" },
        .{ "COMMIT", "C:COMMIT" },
        .{ "UPDATE t SET b = 6 WHERE CURRENT OF h", "E:24000" },
        .{ "SELECT name, is_holdable FROM pg_cursors", "T:name,is_holdable;h|t C:SELECT 1" },
        .{ "CLOSE h", "C:CLOSE CURSOR" },
        .{ "SELECT count(*) FROM pg_cursors", "T:count;0 C:SELECT 1" },
        .{ "SELECT a, b FROM t ORDER BY a", "T:a,b;1|5;2|7 C:SELECT 2" },
    });
    // Another session's cursors are not listed.
    try steps(0, &.{
        .{ "BEGIN", "C:BEGIN" },
        .{ "DECLARE mine CURSOR FOR SELECT 1", "C:DECLARE CURSOR" },
    });
    try steps(1, &.{.{ "SELECT count(*) FROM pg_cursors", "T:count;0 C:SELECT 1" }});
    try steps(0, &.{.{ "COMMIT", "C:COMMIT" }});
    try sameOnReplica("SELECT a, b FROM t ORDER BY a");
}

// ---- WITH CHECK OPTION (F311-04, F751) and CURRENT_DATE CHECK (F672) ---

fn checkOptions() !void {
    try reset();
    try steps(0, &.{
        .{ "CREATE TABLE t(a INT, b INT DEFAULT 0)", "C:CREATE TABLE" },
        .{ "CREATE VIEW v1 AS SELECT a, b FROM t WHERE a > 0", "C:CREATE VIEW" },
        .{ "CREATE VIEW v2 AS SELECT a, b FROM v1 WHERE a < 10 WITH LOCAL CHECK OPTION", "C:CREATE VIEW" },
        .{ "CREATE VIEW v3 AS SELECT a, b FROM v1 WHERE a < 10 WITH CASCADED CHECK OPTION", "C:CREATE VIEW" },
        .{ "CREATE VIEW v4 AS SELECT a, b FROM v3 WHERE a <> 5", "C:CREATE VIEW" },
        .{ "CREATE VIEW v5 WITH (check_option = local) AS SELECT a FROM t WHERE a % 2 = 0", "C:CREATE VIEW" },
        .{ "CREATE VIEW v6 AS SELECT a FROM t x WHERE x.a IS NOT NULL WITH CHECK OPTION", "C:CREATE VIEW" },
        .{ "INSERT INTO v2 VALUES (-5, 1)", "C:INSERT 0 1" },
        .{ "INSERT INTO v2 VALUES (20, 1)", "E:44000" },
        .{ "INSERT INTO v3 VALUES (-5, 1)", "E:44000" },
        .{ "INSERT INTO v3 VALUES (5, 1)", "C:INSERT 0 1" },
        .{ "INSERT INTO v4 VALUES (5, 2)", "C:INSERT 0 1" },
        .{ "INSERT INTO v4 VALUES (50, 2)", "E:44000" },
        .{ "INSERT INTO v4 VALUES (-1, 2)", "E:44000" },
        .{ "INSERT INTO v5 VALUES (3)", "E:44000" },
        .{ "INSERT INTO v5 VALUES (4)", "C:INSERT 0 1" },
        .{ "INSERT INTO v6 VALUES (NULL)", "E:44000" },
        .{ "INSERT INTO v6 (a) VALUES (7)", "C:INSERT 0 1" },
        .{ "UPDATE v2 SET a = 30 WHERE a = 5", "E:44000" },
        .{ "UPDATE v2 SET a = 6 WHERE a = 5", "C:UPDATE 2" },
        .{ "UPDATE v3 SET a = -6 WHERE a = 6", "E:44000" },
        .{ "UPDATE v3 SET b = 9", "C:UPDATE 4" },
        .{ "SELECT a, b FROM t ORDER BY a, b", "T:a,b;-5|1;4|9;6|9;6|9;7|9 C:SELECT 5" },
        .{ "CREATE VIEW bad AS SELECT count(*) FROM t WITH CHECK OPTION", "E:0A000" },
        .{ "CREATE VIEW bad2 WITH (check_option = sideways) AS SELECT a FROM t", "E:22023" },
        .{ "CREATE OR REPLACE VIEW v5 AS SELECT a FROM t WHERE a % 2 = 0", "C:CREATE VIEW" },
        .{ "INSERT INTO v5 VALUES (3)", "C:INSERT 0 1" },
        .{ "CREATE OR REPLACE VIEW v5 AS SELECT a FROM t WHERE a % 2 = 0 WITH CHECK OPTION", "C:CREATE VIEW" },
        .{ "INSERT INTO v5 VALUES (9)", "E:44000" },
        .{ "BEGIN", "C:BEGIN" },
        .{ "INSERT INTO v2 VALUES (8, 8) RETURNING *", "T:a,b;8|8 C:INSERT 0 1" },
        .{ "INSERT INTO v2 VALUES (88, 8)", "E:44000" },
        .{ "ROLLBACK", "C:ROLLBACK" },
        // Constraints fail before the check option.
        .{ "CREATE TABLE p(id INT PRIMARY KEY)", "C:CREATE TABLE" },
        .{ "CREATE VIEW vp AS SELECT id FROM p WHERE id < 5 WITH CHECK OPTION", "C:CREATE VIEW" },
        .{ "INSERT INTO p VALUES (7)", "C:INSERT 0 1" },
        .{ "INSERT INTO vp VALUES (7)", "E:23505" },
        .{ "SELECT a FROM t ORDER BY a", "T:a;-5;3;4;6;6;7 C:SELECT 6" },
    });
    try sameOnReplica("SELECT a, b FROM t ORDER BY a, b");
    // The replica replayed op 115: its views enforce the same options.
    for ([_][]const u8{ "INSERT INTO v2 VALUES (20, 1)", "INSERT INTO v4 VALUES (-1, 2)", "INSERT INTO v5 VALUES (9)", "INSERT INTO v6 VALUES (NULL)" }) |source| {
        const slot = try replica.begin();
        defer replica.abort(slot);
        if (replica.statement(slot, source, &result, .{})) |_| return error.ReplicaAcceptedViolation else |err| try check(err == error.WithCheckOptionViolation);
    }
    {
        const slot = try replica.begin();
        defer replica.abort(slot);
        try replica.statement(slot, "INSERT INTO v3 VALUES (9, 0)", &result, .{});
    }
    // Crafted op 115 records: a bad option byte and a table that is not a
    // view are InvalidChangeRecord, an unknown OID a conflict.
    const view_oid = try oidOf("v2");
    const table_oid = try oidOf("t");
    try crafted(view_oid, 3, error.InvalidChangeRecord);
    try crafted(view_oid, 0, error.InvalidChangeRecord);
    try crafted(table_oid, 1, error.InvalidChangeRecord);
    try crafted(0x7fff_0000, 1, error.ChangeRecordConflict);
    try crafted(view_oid, 2, null);

    // CHECK on CURRENT_DATE (F672), with the store's wall clock.
    try steps(0, &.{
        .{ "CREATE TABLE d(d DATE CHECK (d <= CURRENT_DATE))", "C:CREATE TABLE" },
        .{ "INSERT INTO d VALUES (DATE '2000-01-01')", "C:INSERT 0 1" },
        .{ "INSERT INTO d VALUES (DATE '9999-01-01')", "E:23514" },
        .{ "SELECT count(*) FROM d", "T:count;1 C:SELECT 1" },
    });
}

fn oidOf(name: []const u8) !u32 {
    var source: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&source, "SELECT oid::int8 FROM pg_class WHERE relname = '{s}'", .{name});
    const slot = try replica.begin();
    defer replica.abort(slot);
    try replica.statement(slot, text, &result, .{});
    try check(result.row_count == 1);
    return @intCast(result.rows[0].cells[0].integer);
}

var crafted_record: [64]u8 = undefined;

fn crafted(oid: u32, option: u8, wanted: ?anyerror) !void {
    const bytes = &crafted_record;
    std.mem.writeInt(u16, bytes[0..2], 1, .little);
    std.mem.writeInt(u16, bytes[2..4], 0, .little);
    std.mem.writeInt(u32, bytes[4..8], 1, .little);
    bytes[8] = 115;
    std.mem.writeInt(u32, bytes[9..13], oid, .little);
    bytes[13] = option;
    if (replica.applyChangeRecord(bytes[0..14], &scratch)) |_| {
        try check(wanted == null);
    } else |err| {
        if (wanted == null or err != wanted.?) std.debug.print("crafted op 115: {s}\n", .{@errorName(err)});
        try check(wanted != null and err == wanted.?);
    }
}

pub fn main() !void {
    try dmlSubqueries();
    try queryShapes();
    try transactions();
    try cursors();
    try checkOptions();
    try check(replayed != 0);
    std.debug.print("dml-temp contract: {d} assertions, {d} records replayed\n", .{ assertions, replayed });
}
