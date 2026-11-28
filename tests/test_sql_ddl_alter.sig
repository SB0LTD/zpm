//! DDL alter contracts (conformance lane B11, wave 5, ddl-alter): ALTER
//! COLUMN TYPE [USING] as a table rewrite (op 105), the remaining ALTER
//! COLUMN forms, DROP COLUMN ... CASCADE through view, generated-column and
//! foreign-key dependencies, ALTER CONSTRAINT [NOT] DEFERRABLE, CREATE
//! SCHEMA with schema elements, NOT NULL constraints in pg_constraint and
//! column collations. Each section checks values (PostgreSQL 18 text
//! output), exact errors (SQLSTATE through the error name), atomicity after
//! a failure, lock waits where a lock decides, and replay: every committed
//! record is applied to a replica that must answer every probe exactly like
//! the primary. Crafted op 105 records are rejected before anything
//! applies. Expectations were checked against native PostgreSQL 18.7 (row
//! order only where PostgreSQL defines it). The assertion counter proves
//! this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 16, .columns = 8, .rows_per_table = 32, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 4, .sequences = 8, .schemas = 8, .expr_nodes = 1024 });

var assertions: usize = 0;
var db: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var crafted: [65536]u8 = undefined;
var records_applied: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("ddl-alter contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.DdlAlterContractFailed;
    }
}

var text_buffer: [16384]u8 = undefined;
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
    var result: DB.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn expect(source: []const u8, wanted: []const u8) !void {
    try same(try query(&db, source), wanted);
}

/// Autocommit on the primary; its change record (if any) is applied to the
/// replica. Returns the completed statement's result.
fn replicate(source: []const u8) !DB.Result {
    var result: DB.Result = .{};
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

/// The statement writes no change record (nothing durable changes).
fn quiet(source: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    db.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try check(used == 0);
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
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0 and db.usage().table_locks == 0);
}

fn statement(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rows(slot: u16, source: []const u8) ![]const u8 {
    var result: DB.Result = .{};
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(&result);
}

fn statementFails(slot: u16, source: []const u8, wanted: anyerror) !void {
    var result: DB.Result = .{};
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("accepted in transaction: {s}\n", .{source});
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

fn resumed(slot: u16, source: []const u8) !DB.Result {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{ .@"resume" = true });
    return result;
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

/// Every probe answers identically on the primary and the replay.
fn sameState(probes: []const []const u8) !void {
    for (probes) |probe| {
        const left = try query(&db, probe);
        var copy: [16384]u8 = undefined;
        @memcpy(copy[0..left.len], left);
        const right = try query(&replica, probe);
        if (!std.mem.eql(u8, copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, copy[0..left.len], right });
        try check(std.mem.eql(u8, copy[0..left.len], right));
    }
    try check(db.tableCount() == replica.tableCount());
    try check(db.oid_counter == replica.oid_counter);
}

fn reset() void {
    db = .{};
    replica = .{};
}

// ---- ALTER COLUMN TYPE [USING] ------------------------------------------------

const type_probes = [_][]const u8{
    "SELECT a, b, pg_typeof(a), pg_typeof(b) FROM t ORDER BY a",
    "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 't' ORDER BY ordinal_position",
};

fn alterColumnType() !void {
    reset();
    // F382 / F387 probes (checked against native PostgreSQL 18.7).
    try run("CREATE TABLE t(a INT, b TEXT)");
    try run("INSERT INTO t VALUES (1, '10'), (2, '20')");
    try run("ALTER TABLE t ALTER COLUMN a TYPE BIGINT");
    try run("ALTER TABLE t ALTER COLUMN b SET DATA TYPE INT USING b::int");
    try expect(type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE DATE", error.TypeMismatch, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE DATE USING a", error.TypeMismatch, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE INT USING (SELECT 1)", error.UnsupportedStatement, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE INT USING sum(a)", error.GroupingError, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE INT USING row_number() OVER ()", error.WindowingError, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE VARCHAR(1) USING b * 10", error.StringDataRightTruncation, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE SMALLINT USING b * 10000", error.NumericValueOutOfRange, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    try rejects("ALTER TABLE t ALTER COLUMN zz TYPE INT", error.ColumnNotFound, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    // "cannot alter type of column twice" (0A000).
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE INT, ALTER COLUMN b TYPE BIGINT", error.UnsupportedStatement, type_probes[0], "1|10|bigint|integer;2|20|bigint|integer");
    // A USING expression reads the old row: every column, old types.
    try run("CREATE INDEX t_b ON t (b)");
    try run("ALTER TABLE t ALTER COLUMN b TYPE TEXT USING (a * 100 + b)::text || '!'");
    try check(db.indexTreesValid("t").? and replica.indexTreesValid("t").?);
    try expect(type_probes[0], "1|110!|bigint|text;2|220!|bigint|text");
    try expect(type_probes[1], "a|bigint;b|text");
    try run("ALTER TABLE t ALTER COLUMN a TYPE NUMERIC(6,2), ALTER COLUMN b TYPE VARCHAR(8) USING left(b, 3)");
    try expect(type_probes[0], "1.00|110|numeric|character varying;2.00|220|numeric|character varying");
    // A failed conversion of one row leaves the table as it was.
    try run("INSERT INTO t VALUES (3, 'x')");
    try rejects("ALTER TABLE t ALTER COLUMN b TYPE INT USING b::int", error.InvalidTextRepresentation, type_probes[0], "1.00|110|numeric|character varying;2.00|220|numeric|character varying;3.00|x|numeric|character varying");
    try sameState(&type_probes);
    try check(db.usage().pending_versions == 0);

    // F387: SET DEFAULT and TYPE in one statement; identity needs NOT NULL.
    try run("CREATE TABLE d(a INT, b VARCHAR(5))");
    try run("ALTER TABLE d ALTER COLUMN a SET DEFAULT 1, ALTER COLUMN b TYPE VARCHAR(10)");
    try run("INSERT INTO d(b) VALUES ('abcdefgh')");
    try rejects("ALTER TABLE d ALTER COLUMN a ADD GENERATED BY DEFAULT AS IDENTITY", error.ObjectNotInPrerequisiteState, "SELECT a, b FROM d", "1|abcdefgh");
    try run("ALTER TABLE d ALTER COLUMN a DROP DEFAULT");
    try rejects("ALTER TABLE d ALTER COLUMN a ADD GENERATED BY DEFAULT AS IDENTITY", error.ObjectNotInPrerequisiteState, "SELECT a, b FROM d", "1|abcdefgh");
    try sameState(&.{"SELECT a, b, pg_typeof(b) FROM d"});

    // Defaults, generated and identity columns.
    try run("CREATE TABLE g(a INT, c INT GENERATED ALWAYS AS (a * 2) STORED, d INT DEFAULT 5, i INT GENERATED ALWAYS AS IDENTITY)");
    try run("INSERT INTO g(a) VALUES (1), (2)");
    // "cannot alter type of a column used by a generated column" (0A000).
    try rejects("ALTER TABLE g ALTER COLUMN a TYPE BIGINT", error.UnsupportedStatement, "SELECT a, c, d, i FROM g ORDER BY a", "1|2|5|1;2|4|5|2");
    // "cannot specify USING when altering type of generated column" (42611).
    try rejects("ALTER TABLE g ALTER COLUMN c TYPE BIGINT USING 1", error.InvalidColumnDefinition, "SELECT a, c, d, i FROM g ORDER BY a", "1|2|5|1;2|4|5|2");
    try run("ALTER TABLE g ALTER COLUMN c TYPE BIGINT");
    // "column cannot be cast automatically" covers the default too (42804).
    try rejects("ALTER TABLE g ALTER COLUMN d TYPE DATE USING NULL", error.TypeMismatch, "SELECT a, c, d, i FROM g ORDER BY a", "1|2|5|1;2|4|5|2");
    try run("ALTER TABLE g ALTER COLUMN d TYPE TEXT");
    try expect("SELECT pg_get_expr(adbin, adrelid) FROM pg_attrdef WHERE adrelid = 'g'::regclass ORDER BY adnum", "(a * 2);5");
    // An identity column stays an integer (22023); its sequence follows.
    try rejects("ALTER TABLE g ALTER COLUMN i TYPE TEXT", error.InvalidParameterValue, "SELECT a, c, d, i FROM g ORDER BY a", "1|2|5|1;2|4|5|2");
    try run("ALTER TABLE g ALTER COLUMN i TYPE BIGINT");
    try expect("SELECT seqtypid FROM pg_sequence WHERE seqrelid = pg_get_serial_sequence('g', 'i')::regclass", "20");
    try run("INSERT INTO g(a) VALUES (3)");
    try sameState(&.{ "SELECT a, c, d, i, pg_typeof(c), pg_typeof(d), pg_typeof(i) FROM g ORDER BY a", "SELECT seqtypid, seqmax FROM pg_sequence" });

    // Constraints and indexes over a rewritten column are checked again.
    try run("CREATE TABLE k(id INT PRIMARY KEY, v TEXT UNIQUE, n INT NOT NULL, e INT CHECK (e > 0))");
    try run("INSERT INTO k VALUES (1, 'a', 1, 1), (2, 'b', 2, 2)");
    try run("CREATE INDEX k_n ON k (n)");
    try run("CREATE INDEX k_ve ON k (v, e)");
    try rejects("ALTER TABLE k ALTER COLUMN id TYPE INT USING 7", error.PrimaryKeyViolation, "SELECT * FROM k ORDER BY id", "1|a|1|1;2|b|2|2");
    try rejects("ALTER TABLE k ALTER COLUMN v TYPE INT USING 1", error.PrimaryKeyViolation, "SELECT * FROM k ORDER BY id", "1|a|1|1;2|b|2|2");
    try rejects("ALTER TABLE k ALTER COLUMN n TYPE INT USING NULL", error.NotNullViolation, "SELECT * FROM k ORDER BY id", "1|a|1|1;2|b|2|2");
    try rejects("ALTER TABLE k ALTER COLUMN e TYPE INT USING -e", error.CheckViolation, "SELECT * FROM k ORDER BY id", "1|a|1|1;2|b|2|2");
    try run("ALTER TABLE k ALTER COLUMN id TYPE BIGINT USING id + 100, ALTER COLUMN v TYPE VARCHAR(4) USING v || v");
    try run("ALTER TABLE k ALTER COLUMN n TYPE TEXT USING (n * 10)::text");
    // The ordered indexes are rebuilt over the rewritten keys (B+trees).
    try check(db.indexTreesValid("k").? and replica.indexTreesValid("k").?);
    try expect("SELECT id FROM k WHERE n = '20'", "102");
    try expect("SELECT id FROM k WHERE v = 'aa' AND e = 1", "101");
    try expect("SELECT * FROM k WHERE id = 102", "102|bb|20|2");
    try expect("SELECT id FROM k WHERE v = 'aa'", "101");
    try rejects("INSERT INTO k VALUES (101, 'z', 1, 1)", error.PrimaryKeyViolation, "SELECT count(*) FROM k", "2");
    try rejects("INSERT INTO k VALUES (5, 'aa', 1, 1)", error.PrimaryKeyViolation, "SELECT count(*) FROM k", "2");
    try sameState(&.{ "SELECT * FROM k ORDER BY id", "SELECT * FROM k WHERE id = 101", "SELECT id FROM k WHERE v = 'bb'" });

    // Foreign keys: incompatible key types (42804); changed keys (23503).
    try run("CREATE TABLE p(id INT PRIMARY KEY)");
    try run("CREATE TABLE f(r INT REFERENCES p)");
    try run("INSERT INTO p VALUES (1), (2)");
    try run("INSERT INTO f VALUES (1)");
    try rejects("ALTER TABLE p ALTER COLUMN id TYPE TEXT", error.TypeMismatch, "SELECT id FROM p ORDER BY id", "1;2");
    try rejects("ALTER TABLE f ALTER COLUMN r TYPE TEXT", error.TypeMismatch, "SELECT r FROM f", "1");
    try rejects("ALTER TABLE p ALTER COLUMN id TYPE INT USING id + 10", error.ForeignKeyViolation, "SELECT id FROM p ORDER BY id", "1;2");
    try run("ALTER TABLE p ALTER COLUMN id TYPE BIGINT");
    try run("ALTER TABLE f ALTER COLUMN r TYPE BIGINT");
    try rejects("INSERT INTO f VALUES (3)", error.ForeignKeyViolation, "SELECT r FROM f", "1");
    try sameState(&.{ "SELECT id, pg_typeof(id) FROM p ORDER BY id", "SELECT r, pg_typeof(r) FROM f" });

    // Views using the column: "cannot alter type of a column used by a
    // view or rule" (0A000); columns the view does not use can change.
    try run("CREATE TABLE w(a INT, b INT, c INT)");
    try run("INSERT INTO w VALUES (1, 2, 3)");
    try run("CREATE VIEW wv AS SELECT a FROM w WHERE b > 0");
    try rejects("ALTER TABLE w ALTER COLUMN a TYPE BIGINT", error.UnsupportedStatement, "SELECT * FROM wv", "1");
    try rejects("ALTER TABLE w ALTER COLUMN b TYPE BIGINT", error.UnsupportedStatement, "SELECT * FROM wv", "1");
    try run("ALTER TABLE w ALTER COLUMN c TYPE TEXT USING c || 'c'");
    try expect("SELECT a, c FROM w", "1|3c");
    try sameState(&.{ "SELECT a, b, c, pg_typeof(c) FROM w", "SELECT * FROM wv" });

    // Composite columns (checked against native 18.7): to text by I/O
    // conversion, back with USING, to int only with USING (42804 without).
    try run("CREATE TYPE pt AS (x INT, y INT)");
    try run("CREATE TABLE cp(id INT, p pt)");
    try run("INSERT INTO cp VALUES (1, ROW(1, 2))");
    try run("ALTER TABLE cp ALTER COLUMN p TYPE TEXT");
    try expect("SELECT p FROM cp", "(1,2)");
    try run("ALTER TABLE cp ALTER COLUMN p TYPE pt USING p::pt");
    try expect("SELECT (p).y FROM cp", "2");
    try rejects("ALTER TABLE cp ALTER COLUMN p TYPE INT", error.TypeMismatch, "SELECT (p).x FROM cp", "1");
    try rejects("ALTER TABLE cp ALTER COLUMN id TYPE pt", error.TypeMismatch, "SELECT (p).x FROM cp", "1");
    try run("ALTER TABLE cp ALTER COLUMN p TYPE INT USING (p).x");
    try expect("SELECT p FROM cp", "1");
    // User casts: an assignment cast converts without USING, an explicit
    // one does not (42804).
    try run("CREATE FUNCTION d2i(date) RETURNS int LANGUAGE sql IMMUTABLE AS 'SELECT extract(year from $1)::int'");
    try run("CREATE CAST (date AS int) WITH FUNCTION d2i(date) AS ASSIGNMENT");
    try run("CREATE FUNCTION t2b(text) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT length($1) > 2'");
    try run("CREATE CAST (text AS boolean) WITH FUNCTION t2b(text)");
    try run("CREATE TABLE uc(d DATE, s TEXT)");
    try run("INSERT INTO uc VALUES ('2024-01-01', 'abc')");
    try run("ALTER TABLE uc ALTER COLUMN d TYPE INT");
    try rejects("ALTER TABLE uc ALTER COLUMN s TYPE BOOLEAN", error.TypeMismatch, "SELECT d, s FROM uc", "2024|abc");
    try run("ALTER TABLE uc ALTER COLUMN s TYPE BOOLEAN USING s::boolean");
    try expect("SELECT d, s FROM uc", "2024|t");
    try sameState(&.{ "SELECT p FROM cp", "SELECT d, s FROM uc" });

    // xml in and out (X410).
    try run("CREATE TABLE x(v TEXT)");
    try run("INSERT INTO x VALUES ('<a/>')");
    try run("ALTER TABLE x ALTER COLUMN v TYPE XML USING v::xml");
    try expect("SELECT v, pg_typeof(v) FROM x", "<a/>|xml");
    try run("ALTER TABLE x ALTER COLUMN v TYPE TEXT");
    try expect("SELECT v, pg_typeof(v) FROM x", "<a/>|text");
    try sameState(&.{"SELECT v, pg_typeof(v) FROM x"});
}

// ---- ALTER COLUMN TYPE inside transactions ------------------------------------

fn alterTypeTransactions() !void {
    reset();
    try run("CREATE TABLE t(id INT PRIMARY KEY, a INT, b TEXT)");
    try run("INSERT INTO t VALUES (1, 1, '10'), (2, 2, '20'), (3, 3, '30')");
    // Writes before and after the rewrite in one transaction replay in
    // order: the rewrite record carries the rows as the ALTER left them.
    const tx = try db.begin();
    try statement(tx, "INSERT INTO t VALUES (4, 4, '40')");
    try statement(tx, "UPDATE t SET b = '22' WHERE id = 2");
    try statement(tx, "DELETE FROM t WHERE id = 3");
    try statement(tx, "ALTER TABLE t ALTER COLUMN b TYPE INT USING b::int * 2");
    try statement(tx, "UPDATE t SET b = b + 1 WHERE id = 1");
    try statement(tx, "INSERT INTO t VALUES (5, 5, 50)");
    try statement(tx, "DELETE FROM t WHERE id = 4");
    try same(try rows(tx, "SELECT * FROM t ORDER BY id"), "1|1|21;2|2|44;5|5|50");
    try commit(tx);
    try sameState(&.{ "SELECT id, a, b, pg_typeof(b) FROM t ORDER BY id", "SELECT * FROM t WHERE id = 5" });
    // ROLLBACK TO SAVEPOINT discards the rewrite and the writes after it.
    const tx2 = try db.begin();
    try db.savepoint(tx2, "s");
    try statement(tx2, "ALTER TABLE t ALTER COLUMN b TYPE TEXT");
    try statement(tx2, "UPDATE t SET b = b || 'x'");
    _ = try db.rollbackTo(tx2, "s");
    try same(try rows(tx2, "SELECT b, pg_typeof(b) FROM t ORDER BY id"), "21|integer;44|integer;50|integer");
    try statement(tx2, "ALTER TABLE t ALTER COLUMN id TYPE BIGINT USING id + 100");
    try db.savepoint(tx2, "s2");
    try statement(tx2, "UPDATE t SET a = 0");
    _ = try db.rollbackTo(tx2, "s2");
    try statement(tx2, "ALTER TABLE t ALTER COLUMN a TYPE NUMERIC(5,1)");
    try commit(tx2);
    try expect("SELECT * FROM t ORDER BY id", "101|1.0|21;102|2.0|44;105|5.0|50");
    try sameState(&.{ "SELECT * FROM t ORDER BY id", "SELECT * FROM t WHERE id = 102" });
    // An aborted rewrite leaves nothing behind.
    const tx3 = try db.begin();
    try statement(tx3, "ALTER TABLE t ALTER COLUMN b TYPE TEXT USING 'gone'");
    db.abort(tx3);
    try expect("SELECT b FROM t ORDER BY id", "21;44;50");
    try check(db.usage().transactions == 0 and db.usage().pending_versions == 0 and db.usage().table_locks == 0);
    // ALTER waits for a writer (ACCESS EXCLUSIVE), then rewrites its row.
    const writer = try db.begin();
    try statement(writer, "INSERT INTO t VALUES (7, 7, 70)");
    const alterer = try db.begin();
    try parks(alterer, "ALTER TABLE t ALTER COLUMN b TYPE BIGINT USING b * 10");
    try commit(writer);
    _ = try resumed(alterer, "ALTER TABLE t ALTER COLUMN b TYPE BIGINT USING b * 10");
    try commit(alterer);
    try expect("SELECT id, b FROM t ORDER BY id", "7|700;101|210;102|440;105|500");
    try sameState(&.{ "SELECT id, b, pg_typeof(b) FROM t ORDER BY id", "SELECT b FROM t WHERE id = 7" });
    // A REPEATABLE READ snapshot older than a committed row cannot be
    // rewritten consistently for that transaction (40001).
    const reader = try db.begin();
    try statement(reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ");
    try same(try rows(reader, "SELECT count(*) FROM t"), "4");
    try run("INSERT INTO t VALUES (8, 8, 80)");
    try statementFails(reader, "ALTER TABLE t ALTER COLUMN b TYPE TEXT", error.SerializationFailure);
    db.abort(reader);
    try expect("SELECT count(*), pg_typeof(min(b)) FROM t", "5|bigint");
    try sameState(&.{"SELECT id, b FROM t ORDER BY id"});
}

// ---- crafted op 105 records ---------------------------------------------------

fn craftedRewrites() !void {
    reset();
    try run("CREATE TABLE cr(a INT, b TEXT)");
    try run("INSERT INTO cr VALUES (1, 'x'), (2, 'y')");
    var result: DB.Result = .{};
    var used: usize = 0;
    // A primary statement whose record the replica never sees: mutations of
    // its bytes are applied to the replica, which must reject each one.
    try db.executeChanges("ALTER TABLE cr ALTER COLUMN a TYPE BIGINT USING a * 10", &result, &record, &used, null, null);
    const good = record[0..used];
    // Layout: ... sources (0xfe, 0, 1), row count u32, then two rows of
    // rowid u64, count u8, int8 value (tag 1 + i64), text (tag 3 + len u32 + 1 byte).
    const row_bytes = 8 + 1 + 9 + 6;
    const second = good.len - row_bytes;
    const first = second - row_bytes;
    const count_at = first - 4;
    try check(good[count_at] == 2 and good[count_at - 3] == 0xfe and good[count_at - 2] == 0 and good[count_at - 1] == 1);
    const probe = "SELECT a, b, pg_typeof(a) FROM cr ORDER BY a";
    const before = "1|x|integer;2|y|integer";
    const Mutation = struct { at: usize, value: u8, wanted: anyerror };
    const mutations = [_]Mutation{
        // Row count other than the live rows.
        .{ .at = count_at, .value = 3, .wanted = error.ChangeRecordConflict },
        .{ .at = count_at, .value = 1, .wanted = error.ChangeRecordConflict },
        // The same rowid twice.
        .{ .at = second, .value = good[first], .wanted = error.InvalidChangeRecord },
        // A rowid the table does not have.
        .{ .at = second, .value = 99, .wanted = error.ChangeRecordConflict },
        // A value of another type (bool tag for the bigint column).
        .{ .at = first + 9, .value = 2, .wanted = error.InvalidChangeRecord },
        // A rewritten column from an old column that does not exist.
        .{ .at = count_at - 2, .value = 5, .wanted = error.ChangeRecordConflict },
        // The same old column twice.
        .{ .at = count_at - 1, .value = 0, .wanted = error.ChangeRecordConflict },
        // A wrong column count in a row.
        .{ .at = first + 8, .value = 3, .wanted = error.ChangeRecordConflict },
    };
    for (mutations) |mutation| {
        @memcpy(crafted[0..good.len], good);
        crafted[mutation.at] = mutation.value;
        if (replica.applyChangeRecord(crafted[0..good.len], &scratch)) |_| {
            std.debug.print("crafted record accepted (offset {d})\n", .{mutation.at});
            return error.CraftedRecordAccepted;
        } else |err| {
            if (err != mutation.wanted) std.debug.print("crafted offset {d}: {s} (wanted {s})\n", .{ mutation.at, @errorName(err), @errorName(mutation.wanted) });
            try check(err == error.ChangeRecordConflict or err == error.InvalidChangeRecord);
        }
        try same(try query(&replica, probe), before);
    }
    // Truncated anywhere: rejected, nothing applied.
    var cut: usize = 9;
    while (cut < good.len) : (cut += 7) {
        if (replica.applyChangeRecord(good[0..cut], &scratch)) |_| return error.CraftedRecordAccepted else |err| {
            try check(err == error.InvalidChangeRecord or err == error.ChangeRecordConflict);
        }
        try same(try query(&replica, probe), before);
    }
    // The same bytes as op 12 (0xfe is no source there).
    @memcpy(crafted[0..good.len], good);
    crafted[8] = 12;
    if (replica.applyChangeRecord(crafted[0..good.len], &scratch)) |_| return error.CraftedRecordAccepted else |err| {
        try check(err == error.InvalidChangeRecord or err == error.ChangeRecordConflict);
    }
    try same(try query(&replica, probe), before);
    // The record itself applies.
    try replica.applyChangeRecord(good, &scratch);
    try same(try query(&replica, probe), "10|x|bigint;20|y|bigint");
    try sameState(&.{probe});
    // A rewritten primary key: duplicate keys in the rows are rejected.
    try run("CREATE TABLE ck(id INT PRIMARY KEY, v INT)");
    try run("INSERT INTO ck VALUES (1, 1), (2, 2)");
    used = 0;
    try db.executeChanges("ALTER TABLE ck ALTER COLUMN id TYPE BIGINT USING id * 5", &result, &record, &used, null, null);
    const keyed = record[0..used];
    // Rows: rowid u64, count u8, int8 key, int4 value (tag 1 + i64 each).
    const keyed_row = 8 + 1 + 9 + 9;
    const keyed_second = keyed.len - keyed_row;
    const keyed_first = keyed_second - keyed_row;
    @memcpy(crafted[0..keyed.len], keyed);
    // Second row's key := first row's key (5).
    @memcpy(crafted[keyed_second + 9 ..][0..9], keyed[keyed_first + 9 ..][0..9]);
    if (replica.applyChangeRecord(crafted[0..keyed.len], &scratch)) |_| return error.CraftedRecordAccepted else |err| try check(err == error.ChangeRecordConflict);
    try replica.applyChangeRecord(keyed, &scratch);
    try sameState(&.{ "SELECT id, v FROM ck ORDER BY id", "SELECT v FROM ck WHERE id = 10" });
}

// ---- DROP COLUMN ... CASCADE --------------------------------------------------

const drop_probes = [_][]const u8{
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY 1",
    "SELECT * FROM t",
};

fn dropColumnCascade() !void {
    reset();
    // F033 probe.
    try run("CREATE TABLE t(a INT, b INT, c INT)");
    try run("INSERT INTO t VALUES (1, 2, 3)");
    try run("ALTER TABLE t DROP COLUMN b");
    try expect(drop_probes[1], "1|3");
    try rejects("ALTER TABLE t DROP COLUMN b", error.ColumnNotFound, drop_probes[1], "1|3");
    try run("ALTER TABLE t DROP COLUMN IF EXISTS b");
    try run("CREATE VIEW v AS SELECT c FROM t");
    try run("CREATE VIEW v2 AS SELECT * FROM v");
    try run("CREATE VIEW va AS SELECT a FROM t");
    try rejects("ALTER TABLE t DROP COLUMN c RESTRICT", error.DependentObjects, drop_probes[0], "t;v;v2;va");
    try rejects("ALTER TABLE t DROP COLUMN c", error.DependentObjects, drop_probes[0], "t;v;v2;va");
    // The views using it (and their own dependents) go; va stays.
    try run("ALTER TABLE t DROP COLUMN c CASCADE");
    try expect(drop_probes[1], "1");
    try expect(drop_probes[0], "t;va");
    try expect("SELECT * FROM va", "1");
    try sameState(&drop_probes);
    // SELECT * uses every column.
    try run("ALTER TABLE t ADD COLUMN d INT");
    try run("CREATE VIEW vs AS SELECT * FROM t");
    try rejects("ALTER TABLE t DROP COLUMN d", error.DependentObjects, drop_probes[0], "t;va;vs");
    try run("ALTER TABLE t DROP COLUMN d CASCADE");
    try expect(drop_probes[0], "t;va");
    // Generated columns over it go with CASCADE (2BP01 otherwise).
    try run("CREATE TABLE g(a INT, b INT GENERATED ALWAYS AS (a + 1) STORED, c INT, e INT GENERATED ALWAYS AS (a * 2) STORED)");
    try run("INSERT INTO g(a, c) VALUES (1, 7)");
    try rejects("ALTER TABLE g DROP COLUMN a", error.DependentObjects, "SELECT * FROM g", "1|2|7|2");
    try run("ALTER TABLE g DROP COLUMN a CASCADE");
    try expect("SELECT * FROM g", "7");
    // Foreign keys of other tables over it are dropped with CASCADE.
    try run("CREATE TABLE p(id INT PRIMARY KEY, k INT UNIQUE)");
    try run("CREATE TABLE f(x INT CONSTRAINT f_k REFERENCES p(k), y INT CONSTRAINT f_id REFERENCES p(id))");
    try rejects("ALTER TABLE p DROP COLUMN k", error.DependentObjects, "SELECT conname FROM pg_constraint WHERE conrelid = 'f'::regclass AND contype = 'f' ORDER BY 1", "f_id;f_k");
    try run("ALTER TABLE p DROP COLUMN k CASCADE");
    try expect("SELECT conname FROM pg_constraint WHERE conrelid = 'f'::regclass AND contype = 'f' ORDER BY 1", "f_id");
    try run("INSERT INTO f VALUES (99, NULL)");
    // A view that reads only other columns of the table is kept.
    try run("CREATE TABLE w(a INT, b INT)");
    try run("CREATE VIEW wv AS SELECT a FROM w WHERE b > 0");
    try run("CREATE VIEW wv2 AS SELECT a FROM w");
    try run("ALTER TABLE w DROP COLUMN b CASCADE");
    try expect(drop_probes[0], "f;g;p;t;va;w;wv2");
    try sameState(&.{ drop_probes[0], "SELECT * FROM g", "SELECT * FROM f", "SELECT conname FROM pg_constraint WHERE conrelid = 'f'::regclass ORDER BY 1" });
}

// ---- column options and constraint timing ------------------------------------

fn columnOptionsAndTiming() !void {
    reset();
    try run("CREATE TABLE u(a INT, b TEXT)");
    // Accepted and stored nowhere (no change record), as PostgreSQL's
    // checks require (42703, 22023, 42804).
    try quiet("ALTER TABLE u ALTER COLUMN b SET STATISTICS 100");
    try quiet("ALTER TABLE u ALTER COLUMN b SET STATISTICS 20000");
    try quiet("ALTER TABLE u ALTER COLUMN b SET STORAGE EXTERNAL");
    try quiet("ALTER TABLE u ALTER COLUMN a SET STORAGE PLAIN");
    try quiet("ALTER TABLE u ALTER COLUMN b SET COMPRESSION pglz, ALTER COLUMN b SET COMPRESSION default");
    try rejects("ALTER TABLE u ALTER COLUMN b SET STATISTICS -2", error.InvalidParameterValue, "SELECT count(*) FROM u", "0");
    try rejects("ALTER TABLE u ALTER COLUMN a SET STORAGE EXTERNAL", error.TypeMismatch, "SELECT count(*) FROM u", "0");
    try rejects("ALTER TABLE u ALTER COLUMN b SET STORAGE fast", error.InvalidParameterValue, "SELECT count(*) FROM u", "0");
    try rejects("ALTER TABLE u ALTER COLUMN b SET COMPRESSION zstd", error.InvalidParameterValue, "SELECT count(*) FROM u", "0");
    try rejects("ALTER TABLE u ALTER COLUMN zz SET STATISTICS 1", error.ColumnNotFound, "SELECT count(*) FROM u", "0");
    // ALTER CONSTRAINT [NOT] DEFERRABLE [INITIALLY ...]: foreign keys only.
    try run("CREATE TABLE p(id INT PRIMARY KEY, c INT CONSTRAINT c_pos CHECK (c > 0))");
    try run("CREATE TABLE f(x INT CONSTRAINT f_fk REFERENCES p)");
    const timing = "SELECT conname, condeferrable, condeferred FROM pg_constraint WHERE conname = 'f_fk'";
    try run("ALTER TABLE f ALTER CONSTRAINT f_fk DEFERRABLE INITIALLY DEFERRED");
    try expect(timing, "f_fk|t|t");
    try run("ALTER TABLE f ALTER CONSTRAINT f_fk NOT DEFERRABLE");
    try expect(timing, "f_fk|f|f");
    try run("ALTER TABLE f ALTER CONSTRAINT f_fk INITIALLY DEFERRED");
    try expect(timing, "f_fk|t|t");
    try run("ALTER TABLE f ALTER CONSTRAINT f_fk DEFERRABLE");
    try expect(timing, "f_fk|t|f");
    try rejects("ALTER TABLE p ALTER CONSTRAINT c_pos DEFERRABLE", error.WrongObjectType, timing, "f_fk|t|f");
    try rejects("ALTER TABLE p ALTER CONSTRAINT p_pkey DEFERRABLE", error.WrongObjectType, timing, "f_fk|t|f");
    try rejects("ALTER TABLE f ALTER CONSTRAINT nope DEFERRABLE", error.UndefinedObject, timing, "f_fk|t|f");
    try rejects("ALTER TABLE f ALTER CONSTRAINT f_fk NOT DEFERRABLE INITIALLY DEFERRED", error.Syntax, timing, "f_fk|t|f");
    // A deferrable key can be deferred: the reference may come later.
    const tx = try db.begin();
    try statement(tx, "SET CONSTRAINTS f_fk DEFERRED");
    try statement(tx, "INSERT INTO f VALUES (1)");
    try statement(tx, "INSERT INTO p VALUES (1, 1)");
    try commit(tx);
    try sameState(&.{ timing, "SELECT * FROM f" });
}

// ---- CREATE SCHEMA with schema elements ---------------------------------------

const schema_probes = [_][]const u8{
    "SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname LIKE 's%' ORDER BY 1, 2",
    "SELECT nspname FROM pg_namespace WHERE nspname LIKE 's%' ORDER BY 1",
    "SELECT schemaname, viewname, definition FROM pg_views WHERE schemaname LIKE 's%' ORDER BY 1, 2",
};

fn schemaElements() !void {
    reset();
    // F311-01 probe.
    try run("CREATE SCHEMA s");
    try quiet("CREATE SCHEMA IF NOT EXISTS s");
    try rejects("CREATE SCHEMA s", error.DuplicateSchema, schema_probes[1], "s");
    try run("CREATE SCHEMA s2 CREATE TABLE x(a INT) CREATE VIEW y AS SELECT a FROM x");
    try run("INSERT INTO s2.x VALUES (1)");
    try expect("SELECT a FROM s2.y", "1");
    // Views before tables, indexes and sequences: PostgreSQL's order
    // (sequences, tables, views, indexes, triggers, grants).
    try run("CREATE SCHEMA s3 CREATE VIEW v AS SELECT a FROM x CREATE TABLE x(a INT) CREATE INDEX ix ON x(a) CREATE SEQUENCE q");
    try expect(schema_probes[0], "s2|x|r;s2|y|v;s3|ix|i;s3|q|S;s3|v|v;s3|x|r");
    // The stored view text names its schema (resolved like PostgreSQL's
    // stored parse tree), whatever the search path is later.
    try expect(schema_probes[2], "s2|y|SELECT a FROM s2.x;s3|v|SELECT a FROM s3.x");
    try run("CREATE TABLE x(a INT)");
    try run("INSERT INTO x VALUES (99)");
    try expect("SELECT a FROM s2.y", "1");
    // The search path is the session's again afterwards.
    try expect("SHOW search_path", "\"$user\", public");
    // Tables in statement order: a reference to a later table is 42P01;
    // another schema's name is 42P15; a duplicate is 42P07; CREATE DOMAIN
    // is no schema element (42601); IF NOT EXISTS has none (0A000). Each
    // failure leaves no schema behind.
    try rejects("CREATE SCHEMA s4 CREATE TABLE a(v INT REFERENCES b) CREATE TABLE b(v INT PRIMARY KEY)", error.TableNotFound, schema_probes[1], "s;s2;s3");
    try rejects("CREATE SCHEMA s4 CREATE TABLE other.a(v INT)", error.InvalidSchemaDefinition, schema_probes[1], "s;s2;s3");
    try rejects("CREATE SCHEMA s4 CREATE TABLE a(v INT) CREATE TABLE a(w INT)", error.TableExists, schema_probes[1], "s;s2;s3");
    try rejects("CREATE SCHEMA s4 CREATE DOMAIN d AS INT", error.Syntax, schema_probes[1], "s;s2;s3");
    try rejects("CREATE SCHEMA IF NOT EXISTS s4 CREATE TABLE a(v INT)", error.UnsupportedStatement, schema_probes[1], "s;s2;s3");
    try run("CREATE SCHEMA s4 CREATE TABLE s4.a(v INT PRIMARY KEY) CREATE TABLE b(w INT REFERENCES s4.a(v))");
    try rejects("INSERT INTO s4.b VALUES (1)", error.ForeignKeyViolation, "SELECT count(*) FROM s4.b", "0");
    // Triggers and grants run as their own statements do.
    try run("CREATE FUNCTION tf() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.a := NEW.a + 1; RETURN NEW; END $$");
    try run("CREATE SCHEMA s5 CREATE TABLE t(a INT) CREATE TRIGGER tr BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION public.tf() GRANT SELECT ON t TO PUBLIC");
    try run("INSERT INTO s5.t VALUES (1)");
    try expect("SELECT a FROM s5.t", "2");
    try expect("SELECT tgname FROM pg_trigger WHERE tgrelid = 's5.t'::regclass", "tr");
    // A CREATE VIEW outside CREATE SCHEMA qualifies names resolved through
    // a schema other than public as well.
    try run("SET search_path = s4, public");
    try run("CREATE VIEW s4.av AS SELECT v FROM a");
    try run("RESET search_path");
    try expect("SELECT definition FROM pg_views WHERE viewname = 'av'", "SELECT v FROM s4.a");
    try sameState(&.{ schema_probes[0], schema_probes[1], schema_probes[2], "SELECT a FROM s2.y", "SELECT a FROM s5.t" });
}

// ---- NOT NULL constraints and column collations (definition format 8) ---------

const constraint_probes = [_][]const u8{
    "SELECT conname, contype FROM pg_constraint WHERE conrelid = 't'::regclass ORDER BY conname",
    "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 't' ORDER BY 1",
};

const collation_probes = [_][]const u8{
    "SELECT column_name, collation_name FROM information_schema.columns WHERE table_name = 'c' ORDER BY ordinal_position",
    "SELECT attname, attcollation FROM pg_attribute WHERE attrelid = 'c'::regclass AND attnum > 0 ORDER BY attnum",
    "SELECT s FROM c ORDER BY s",
};

fn constraintsAndCollations() !void {
    reset();
    // F491 probe: NOT NULL constraints are pg_constraint rows (contype 'n',
    // a "char"), named or `<table>_<column>_not_null`, primary key columns too.
    try run("CREATE TABLE t(a INT CONSTRAINT a_pos CHECK (a > 0), b INT CONSTRAINT b_nn NOT NULL, CONSTRAINT t_pk PRIMARY KEY (a))");
    try rejects("INSERT INTO t VALUES (-1, 1)", error.CheckViolation, "SELECT count(*) FROM t", "0");
    try rejects("INSERT INTO t VALUES (1, NULL)", error.NotNullViolation, "SELECT count(*) FROM t", "0");
    try expect(constraint_probes[0], "a_pos|c;b_nn|n;t_a_not_null|n;t_pk|p");
    try expect(constraint_probes[1], "a_pos|CHECK;b_nn|CHECK;t_a_not_null|CHECK;t_pk|PRIMARY KEY");
    try run("ALTER TABLE t DROP CONSTRAINT a_pos");
    try run("INSERT INTO t VALUES (-1, 1)");
    try run("ALTER TABLE t RENAME CONSTRAINT t_pk TO t_key");
    try expect("SELECT conname FROM pg_constraint WHERE conrelid = 't'::regclass AND contype = 'p'", "t_key");
    // Names survive renames of the table and column; SET NOT NULL names
    // the new constraint after the current names.
    try run("ALTER TABLE t RENAME COLUMN b TO bb");
    try run("ALTER TABLE t ALTER COLUMN bb DROP NOT NULL");
    try run("ALTER TABLE t ALTER COLUMN bb SET NOT NULL");
    try expect(constraint_probes[0], "t_a_not_null|n;t_bb_not_null|n;t_key|p");
    try run("ALTER TABLE t RENAME CONSTRAINT t_bb_not_null TO bb_set");
    try rejects("ALTER TABLE t RENAME CONSTRAINT bb_set TO t_key", error.DuplicateObject, constraint_probes[0], "bb_set|n;t_a_not_null|n;t_key|p");
    // A primary key column keeps its NOT NULL (42P16); DROP CONSTRAINT of
    // another one is DROP NOT NULL.
    try rejects("ALTER TABLE t DROP CONSTRAINT t_a_not_null", error.InvalidTableDefinition, constraint_probes[0], "bb_set|n;t_a_not_null|n;t_key|p");
    try run("ALTER TABLE t DROP CONSTRAINT bb_set");
    try run("INSERT INTO t VALUES (2, NULL)");
    try expect(constraint_probes[0], "t_a_not_null|n;t_key|p");
    try expect("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 't_a_not_null'", "NOT NULL a");
    // Inherited and partition NOT NULL constraints keep the parent's name.
    try run("CREATE TABLE m(id INT NOT NULL, v INT)");
    try run("CREATE TABLE mc(v INT NOT NULL) INHERITS (m)");
    try expect("SELECT conname FROM pg_constraint WHERE conrelid = 'mc'::regclass ORDER BY 1", "m_id_not_null;mc_v_not_null");
    try sameState(&constraint_probes);
    try sameState(&.{"SELECT conname, contype FROM pg_constraint WHERE conrelid = 'mc'::regclass ORDER BY 1"});
    // F690 probe: column collations ("C", "POSIX", "default", ucs_basic and
    // the C.utf8 libc collation; code point order like the database's).
    try expect("SELECT 'a' < 'B' COLLATE \"C\", 'a' < 'B' COLLATE \"POSIX\", 'abc' COLLATE \"C\" = 'abc'", "f|f|t");
    try run("CREATE TABLE c(s TEXT COLLATE \"C\", u TEXT, v VARCHAR(3) COLLATE \"C.utf8\", w TEXT COLLATE \"default\", x TEXT COLLATE ucs_basic)");
    try run("INSERT INTO c VALUES ('b', 'b', 'b', 'b', 'b'), ('B', 'B', 'B', 'B', 'B'), ('a', 'a', 'a', 'a', 'a')");
    try expect(collation_probes[2], "B;a;b");
    try expect("SELECT s FROM c ORDER BY s COLLATE \"C\" DESC", "b;a;B");
    try expect(collation_probes[0], "s|C;u|NULL;v|C.utf8;w|NULL;x|ucs_basic");
    try expect(collation_probes[1], "s|950;u|100;v|12359;w|100;x|962");
    // ALTER COLUMN TYPE takes COLLATE, else the new type's default.
    try run("ALTER TABLE c ALTER COLUMN u TYPE VARCHAR(5) COLLATE \"POSIX\"");
    try run("ALTER TABLE c ALTER COLUMN s TYPE VARCHAR(5)");
    try expect(collation_probes[0], "s|NULL;u|POSIX;v|C.utf8;w|NULL;x|ucs_basic");
    try rejects("CREATE TABLE ci(i INT COLLATE \"C\")", error.TypeMismatch, "SELECT count(*) FROM c", "3");
    try rejects("CREATE TABLE ci(i TEXT COLLATE \"nope\")", error.UndefinedObject, "SELECT count(*) FROM c", "3");
    try rejects("ALTER TABLE c ALTER COLUMN w TYPE INT COLLATE \"C\" USING 1", error.TypeMismatch, "SELECT count(*) FROM c", "3");
    // ICU collations are not available here (0A000).
    try rejects("CREATE TABLE ci(i TEXT COLLATE \"unicode\")", error.UnsupportedStatement, "SELECT count(*) FROM c", "3");
    try sameState(&collation_probes);
    // Crafted format-8 definitions: an unknown collation, a collation on
    // an integer column, unknown flags.
    var result: DB.Result = .{};
    var used: usize = 0;
    try db.executeChanges("CREATE TABLE k8(a TEXT COLLATE \"POSIX\")", &result, &record, &used, null, null);
    const good = record[0..used];
    // The extension block ends the record: flags u8 then the OID 951.
    try check(good[good.len - 5] == 1 and good[good.len - 4] == 0xb7 and good[good.len - 3] == 3);
    for ([_]struct { at: usize, value: u8 }{ .{ .at = good.len - 4, .value = 0xb8 }, .{ .at = good.len - 5, .value = 9 }, .{ .at = good.len - 5, .value = 0 }, .{ .at = good.len - 5, .value = 2 } }) |mutation| {
        @memcpy(crafted[0..good.len], good);
        crafted[mutation.at] = mutation.value;
        if (replica.applyChangeRecord(crafted[0..good.len], &scratch)) |_| return error.CraftedRecordAccepted else |err| {
            try check(err == error.InvalidChangeRecord or err == error.ChangeRecordConflict);
        }
    }
    try replica.applyChangeRecord(good, &scratch);
    try sameState(&.{"SELECT attname, attcollation FROM pg_attribute WHERE attrelid = 'k8'::regclass AND attnum > 0"});
}

pub fn main() !void {
    try alterColumnType();
    try alterTypeTransactions();
    try craftedRewrites();
    try dropColumnCascade();
    try columnOptionsAndTiming();
    try schemaElements();
    try constraintsAndCollations();
    std.debug.print("contract-sql-ddl-alter: {d} assertions, {d} records replayed\n", .{ assertions, records_applied });
}
