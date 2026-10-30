//! Kind-3 change-record contracts: encode -> decode -> apply round trips,
//! truncation and bit-flip rejection, unknown op/version rejection and
//! whole-record atomicity. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 8, .name_bytes = 16, .text_bytes = 24, .integer_bits = 32 });

var assertions: usize = 0;
var rejected_flips: usize = 0;
var accepted_flips: usize = 0;
var scratch: DB.ReplayScratch = .{};
const oid = sql.change_records.first_oid;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.ChangeLogContractFailed;
}

fn sameResult(a: *const DB.Result, b: *const DB.Result) bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |row| for (0..a.column_count) |column| {
        const x = a.rows[row].cells[column];
        const y = b.rows[row].cells[column];
        switch (x) {
            .null_value => if (y != .null_value) return false,
            .integer => |value| if (y != .integer or y.integer != value) return false,
            .boolean => |value| if (y != .boolean or y.boolean != value) return false,
            .text => |value| if (y != .text or !std.mem.eql(u8, value.slice(), y.text.slice())) return false,
            // Other types: tag and btree equality.
            else => if (std.meta.activeTag(x) != std.meta.activeTag(y) or DB.compareCells(&x, &y) != 0) return false,
        }
    };
    return true;
}

/// Logical equality over every table name that either side might hold,
/// including unordered scan (rowid) order, next rowids and OIDs.
fn sameDatabase(a: *DB, b: *DB) !bool {
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter) return false;
    for ([_][]const u8{ "t", "u", "v" }) |name| {
        const left = a.storageStats(name);
        const right = b.storageStats(name);
        if ((left == null) != (right == null)) return false;
        if (left == null) continue;
        if (left.?.live_rows != right.?.live_rows or left.?.next_rowid != right.?.next_rowid) return false;
        var query: [64]u8 = undefined;
        const source = try std.fmt.bufPrint(&query, "SELECT * FROM {s}", .{name});
        var x: DB.Result = .{};
        var y: DB.Result = .{};
        try a.execute(source, &x);
        try b.execute(source, &y);
        if (!sameResult(&x, &y)) return false;
    }
    return true;
}

const workload = [_][]const u8{
    "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT NOT NULL, flag BOOLEAN)",
    "INSERT INTO t VALUES (1, 'one', TRUE)",
    "INSERT INTO t VALUES (2, 'two; ''quoted''', NULL)",
    "INSERT INTO t (label, id) VALUES ('three', 3)",
    "UPDATE t SET label = 'uno' WHERE id = 1",
    "UPDATE t SET id = 30 WHERE id = 3",
    "UPDATE t SET flag = FALSE WHERE id = 99",
    "DELETE FROM t WHERE id = 2",
    "CREATE TABLE u (k BIGINT PRIMARY KEY, n INT)",
    "INSERT INTO u VALUES (-9223372036854775808, -2147483648)",
    "INSERT INTO u VALUES (9223372036854775807, 2147483647)",
    "DROP TABLE u",
    "CREATE TABLE u (name TEXT)",
    "INSERT INTO u VALUES ('after drop')",
    "INSERT INTO t VALUES (2, 'reused key', TRUE)",
    "DELETE FROM t WHERE id = 30",
};

fn roundTrip(primary: *DB, per_statement: *DB, combined: *DB, record: []u8, combined_used: *usize) !void {
    var single: [1024]u8 = undefined;
    for (workload) |source| {
        var result: DB.Result = .{};
        var used: usize = 0;
        try primary.executeChanges(source, &result, &single, &used, null, null);
        try check(used >= sql.change_records.header_size);
        try per_statement.applyChangeRecord(single[0..used], &scratch);
        try check(try sameDatabase(primary, per_statement));
        var other: DB.Result = .{};
        // A second encoding of the same statement into the combined record
        // comes from replaying it on an identical copy.
        try combined.executeChanges(source, &other, record, combined_used, null, null);
        try check(result.affected_rows == other.affected_rows and result.command == other.command);
    }
}

fn roundTrips() !void {
    var primary: DB = .{};
    var per_statement: DB = .{};
    var producer: DB = .{};
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    try roundTrip(&primary, &per_statement, &producer, &record, &used);
    // 16 statements; the UPDATE matching no row encodes no op.
    try check(try DB.changeRecordOps(record[0..used]) == 15);
    // One multi-statement record (an explicit transaction) applies at once.
    var combined: DB = .{};
    try combined.applyChangeRecord(record[0..used], &scratch);
    try check(try sameDatabase(&primary, &combined));
    // Counters round-trip and are monotonic.
    var counters: [256]u8 = undefined;
    var counters_used: usize = 0;
    try primary.encodeCatalogCounters(&counters, &counters_used);
    try check(try DB.changeRecordOps(counters[0..counters_used]) == 1);
    try combined.applyChangeRecord(counters[0..counters_used], &scratch);
    try check(try sameDatabase(&primary, &combined));
    var result: DB.Result = .{};
    try combined.execute("SELECT * FROM t ORDER BY id", &result);
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 1 and result.rows[1].cells[0].integer == 2);
    try check(std.mem.eql(u8, result.rows[0].cells[1].text.slice(), "uno") and result.column_types[0] == .integer32);
    // Applying the same record twice is a conflict and changes nothing.
    var before: DB = .{};
    before.copyFrom(&combined);
    if (combined.applyChangeRecord(record[0..used], &scratch)) |_| return error.DuplicateReplayAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(try sameDatabase(&before, &combined));
}

fn corruption() !void {
    var producer: DB = .{};
    var record: [4096]u8 = undefined;
    var used: usize = 0;
    var result: DB.Result = .{};
    for (workload[0..8]) |source| try producer.executeChanges(source, &result, &record, &used, null, null);
    var base: DB = .{};
    var target: DB = .{};
    // Truncation anywhere fails closed with no partial application.
    for (0..used) |length| {
        target.copyFrom(&base);
        if (target.applyChangeRecord(record[0..length], &scratch)) |_| return error.TruncatedRecordAccepted else |err| try check(err == error.InvalidChangeRecord or err == error.UnsupportedLogVersion);
        try check(target.tableCount() == 0);
    }
    // Every single-byte corruption is either rejected with nothing applied
    // or (only inside value payload bytes) decodes to another valid record.
    var copy: [4096]u8 = undefined;
    for (0..used) |position| {
        @memcpy(copy[0..used], record[0..used]);
        copy[position] ^= 0x5a;
        target.copyFrom(&base);
        if (target.applyChangeRecord(copy[0..used], &scratch)) |_| {
            accepted_flips += 1;
            try check(target.tableCount() == 1);
        } else |_| {
            rejected_flips += 1;
            try check(target.tableCount() == 0 and target.storageStats("t") == null);
        }
    }
    try check(rejected_flips > used / 2);
    // Unknown versions, flags and ops fail closed.
    @memcpy(copy[0..used], record[0..used]);
    copy[0] = 2;
    if (target.applyChangeRecord(copy[0..used], &scratch)) |_| return error.UnknownVersionAccepted else |err| try check(err == error.UnsupportedLogVersion);
    @memcpy(copy[0..used], record[0..used]);
    copy[2] = 1;
    if (target.applyChangeRecord(copy[0..used], &scratch)) |_| return error.UnknownFlagsAccepted else |err| try check(err == error.UnsupportedLogVersion);
    for ([_]u8{ 0, 10, 200 }) |tag| {
        @memcpy(copy[0..used], record[0..used]);
        copy[8] = tag;
        target.copyFrom(&base);
        if (target.applyChangeRecord(copy[0..used], &scratch)) |_| return error.UnknownOpAccepted else |err| try check(err == error.UnsupportedLogVersion);
        try check(target.tableCount() == 0);
    }
    // Sequence ops (7..9, FEAT-007) over create_table bytes are malformed
    // or name no live sequence: rejected, nothing applied.
    for ([_]u8{ 7, 8, 9 }) |tag| {
        @memcpy(copy[0..used], record[0..used]);
        copy[8] = tag;
        target.copyFrom(&base);
        if (target.applyChangeRecord(copy[0..used], &scratch)) |_| return error.MisreadSequenceOpAccepted else |err| try check(err == error.InvalidChangeRecord or err == error.ChangeRecordConflict);
        try check(target.tableCount() == 0);
    }
    // Trailing bytes after the declared ops are corruption.
    @memcpy(copy[0..used], record[0..used]);
    copy[used] = 0;
    if (target.applyChangeRecord(copy[0 .. used + 1], &scratch)) |_| return error.TrailingBytesAccepted else |err| try check(err == error.InvalidChangeRecord);
    try check(target.tableCount() == 0);
}

const Builder = struct {
    bytes: [1024]u8 = undefined,
    len: usize = 8,
    ops: u32 = 0,

    fn int(self: *Builder, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.bytes[self.len..][0..@sizeOf(T)], value, .little);
        self.len += @sizeOf(T);
    }

    fn op(self: *Builder, tag: u8, table_oid: u32, rowid: u64) void {
        self.int(u8, tag);
        self.int(u32, table_oid);
        self.int(u64, rowid);
        self.ops += 1;
    }

    fn intValue(self: *Builder, value: i64) void {
        self.int(u8, 1);
        self.int(i64, value);
    }

    fn textValue(self: *Builder, value: []const u8) void {
        self.int(u8, 3);
        self.int(u32, @intCast(value.len));
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }

    fn row(self: *Builder, tag: u8, table_oid: u32, rowid: u64, id: i64, label: []const u8) void {
        self.op(tag, table_oid, rowid);
        self.int(u8, 3);
        self.intValue(id);
        self.textValue(label);
        self.int(u8, 0);
    }

    fn name(self: *Builder, value: []const u8) void {
        self.int(u8, @intCast(value.len));
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }

    /// create_table with one INTEGER column `k` (the primary key if `keyed`).
    fn createTable(self: *Builder, table_oid: u32, table_name: []const u8, keyed: bool) void {
        self.int(u8, 1);
        self.int(u32, table_oid);
        self.name(table_name);
        self.int(u16, 1);
        self.int(u8, 1);
        self.name("k");
        self.int(u32, 23);
        self.int(i32, -1);
        self.int(u8, if (keyed) 3 else 0);
        self.int(u16, 0);
        self.ops += 1;
    }

    /// create_sequence: BIGINT, increment 1, 1..100, start 1, no owner.
    fn createSequence(self: *Builder, sequence_oid: u32, sequence_name: []const u8) void {
        self.int(u8, 7);
        self.int(u32, sequence_oid);
        self.name(sequence_name);
        self.int(u32, 20);
        self.int(i64, 1);
        self.int(i64, 1);
        self.int(i64, 100);
        self.int(i64, 1);
        self.int(u8, 0);
        self.int(u32, 0);
        self.int(u8, 0);
        self.ops += 1;
    }

    fn record(self: *Builder) []const u8 {
        std.mem.writeInt(u16, self.bytes[0..2], 1, .little);
        std.mem.writeInt(u16, self.bytes[2..4], 0, .little);
        std.mem.writeInt(u32, self.bytes[4..8], self.ops, .little);
        return self.bytes[0..self.len];
    }
};

fn atomicity() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT NOT NULL, flag BOOLEAN)", &result);
    try db.execute("INSERT INTO t VALUES (1, 'one', NULL)", &result);
    try db.execute("INSERT INTO t VALUES (2, 'two', NULL)", &result);
    var reference: DB = .{};
    reference.copyFrom(&db);
    const Case = struct { build: *const fn (*Builder) void, wanted: anyerror };
    const cases = [_]Case{
        // A valid insert followed by a rowid conflict publishes neither.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 3, "three");
                b.row(3, oid, 3, 4, "dup rowid");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // Rowids never move backwards.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 1, 9, "old rowid");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // Primary-key uniqueness is checked against database and record.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 7, "seven");
                b.row(3, oid, 4, 7, "seven again");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(4, oid, 1, 2, "key of row 2");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // A deleted row cannot be updated later in the same record.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.op(5, oid, 1);
                b.row(4, oid, 1, 1, "ghost");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // Unknown table OID and unknown rowid.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid + 7, 3, 3, "nowhere");
            }
        }.f, .wanted = error.ChangeRecordConflict },
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.op(5, oid, 99);
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // NOT NULL and type checks happen before anything applies.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 3, "fine");
                b.op(3, oid, 4);
                b.int(u8, 3);
                b.intValue(4);
                b.int(u8, 0);
                b.int(u8, 0);
            }
        }.f, .wanted = error.ChangeRecordConflict },
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.op(3, oid, 3);
                b.int(u8, 3);
                b.intValue(2147483648);
                b.textValue("int4 overflow");
                b.int(u8, 0);
            }
        }.f, .wanted = error.ChangeRecordConflict },
        // A truncated sequence definition, a value for no live sequence and
        // an unknown op after a valid row all fail closed atomically.
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 3, "three");
                b.int(u8, 7);
                b.ops += 1;
            }
        }.f, .wanted = error.InvalidChangeRecord },
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 3, "three");
                b.int(u8, 9);
                b.int(u32, 99999);
                b.int(i64, 5);
                b.int(u8, 1);
                b.ops += 1;
            }
        }.f, .wanted = error.ChangeRecordConflict },
        .{ .build = struct {
            fn f(b: *Builder) void {
                b.row(3, oid, 3, 3, "three");
                b.int(u8, 10);
                b.ops += 1;
            }
        }.f, .wanted = error.UnsupportedLogVersion },
    };
    for (cases) |case| {
        var builder: Builder = .{};
        case.build(&builder);
        if (db.applyChangeRecord(builder.record(), &scratch)) |_| return error.ConflictAccepted else |err| try check(err == case.wanted);
        try check(try sameDatabase(&db, &reference));
        const stats = db.storageStats("t").?;
        try check(stats.pending == 0 and stats.live_rows == 2 and stats.next_rowid == 3);
    }
    // M1 shape: insert, update the same row twice, delete another row.
    var builder: Builder = .{};
    builder.row(3, oid, 3, 3, "three");
    builder.row(4, oid, 3, 3, "three again");
    builder.row(4, oid, 3, 33, "rekeyed");
    builder.op(5, oid, 1);
    builder.row(3, oid, 4, 1, "key 1 reused");
    try db.applyChangeRecord(builder.record(), &scratch);
    try db.execute("SELECT * FROM t", &result);
    try check(result.row_count == 3);
    try check(result.rows[0].cells[0].integer == 2 and result.rows[1].cells[0].integer == 33 and result.rows[2].cells[0].integer == 1);
    try check(std.mem.eql(u8, result.rows[1].cells[1].text.slice(), "rekeyed"));
    const stats = db.storageStats("t").?;
    try check(stats.pending == 0 and stats.versions == 3 and stats.next_rowid == 5);
    // The same statements executed directly give the same database.
    try reference.execute("INSERT INTO t VALUES (3, 'three', NULL)", &result);
    try reference.execute("UPDATE t SET label = 'three again' WHERE id = 3", &result);
    try reference.execute("UPDATE t SET id = 33, label = 'rekeyed' WHERE id = 3", &result);
    try reference.execute("DELETE FROM t WHERE id = 1", &result);
    try reference.execute("INSERT INTO t VALUES (1, 'key 1 reused', NULL)", &result);
    try check(try sameDatabase(&db, &reference));
}

/// The records a store persists, in commit order: each is encoded by
/// prepareCommit, appended, then published (the commit path of db/store).
const Log = struct {
    bytes: [4096]u8 = undefined,
    ends: [8]usize = undefined,
    count: usize = 0,

    fn commit(self: *Log, db: *DB, slot: u16) !void {
        const start = if (self.count == 0) 0 else self.ends[self.count - 1];
        const payload = try db.prepareCommit(slot, self.bytes[start..]);
        self.ends[self.count] = start + payload.len;
        self.count += 1;
        db.publishCommit(slot);
    }

    fn record(self: *const Log, index: usize) []const u8 {
        return self.bytes[(if (index == 0) 0 else self.ends[index - 1])..self.ends[index]];
    }

    /// A restart: replays every record in commit order into `target`.
    fn replay(self: *const Log, target: *DB) !void {
        for (0..self.count) |index| try target.applyChangeRecord(self.record(index), &scratch);
    }
};

fn run(db: *DB, slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    try db.statement(slot, source, &result, .{});
}

/// Relation OIDs (tables, primary-key indexes, sequences), column counts,
/// keys and sequence definitions agree. Column names and types are compared
/// by sameDatabase. At most 3 result columns per query (Config.columns).
fn sameCatalog(a: *DB, b: *DB) !bool {
    for ([_][]const u8{
        "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
        "SELECT oid, relnatts FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
        "SELECT indexrelid, indrelid, indkey FROM pg_index ORDER BY indexrelid",
        "SELECT seqrelid, seqtypid, seqstart FROM pg_sequence ORDER BY seqrelid",
        "SELECT seqincrement, seqmax, seqmin FROM pg_sequence ORDER BY seqrelid",
    }) |source| {
        var x: DB.Result = .{};
        var y: DB.Result = .{};
        try a.execute(source, &x);
        try b.execute(source, &y);
        if (!sameResult(&x, &y)) return false;
    }
    return true;
}

fn integer(db: *DB, source: []const u8) !i64 {
    var result: DB.Result = .{};
    try db.execute(source, &result);
    return result.rows[0].cells[0].integer;
}

/// STO-01: OIDs are taken when CREATE runs, not at commit, so concurrent
/// DDL commits out of OID order. A restart must replay that log into the
/// same database (INV-CLOG-4), and later creates must not reuse an OID.
fn outOfOrderTables() !void {
    var db: DB = .{};
    var log: Log = .{};
    // A takes t (oid, key index oid + 1); C takes sequence g and aborts,
    // leaving a gap; B takes u above both and commits first.
    const a = try db.begin();
    try run(&db, a, "CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT NOT NULL)");
    try run(&db, a, "INSERT INTO t VALUES (1, 'one')");
    const c = try db.begin();
    try run(&db, c, "CREATE SEQUENCE g");
    const b = try db.begin();
    try run(&db, b, "CREATE TABLE u (k BIGINT, n INT)");
    try run(&db, b, "INSERT INTO u VALUES (7, -7)");
    try log.commit(&db, b);
    db.abort(c);
    try run(&db, a, "INSERT INTO t VALUES (2, 'two')");
    try log.commit(&db, a);
    try check(log.count == 2 and db.tableCount() == 2 and db.oid_counter == 4);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 't'") == oid);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'u'") == oid + 3);
    var restarted: DB = .{};
    try log.replay(&restarted);
    try check(try sameDatabase(&db, &restarted));
    try check(try sameCatalog(&db, &restarted));
    try check(try integer(&restarted, "SELECT COUNT(*) FROM t") == 2 and try integer(&restarted, "SELECT n FROM u WHERE k = 7") == -7);
    // t's NOT NULL and primary key were replayed with it.
    var result: DB.Result = .{};
    if (restarted.execute("INSERT INTO t VALUES (3, NULL)", &result)) |_| return error.NotNullLost else |err| try check(err == error.NotNullViolation);
    if (restarted.execute("INSERT INTO t VALUES (1, 'again')", &result)) |_| return error.PrimaryKeyLost else |err| try check(err == error.PrimaryKeyViolation);
    try check(try sameDatabase(&db, &restarted));
    // The counter kept the maximum: the next create gets the same OID.
    for ([_]*DB{ &db, &restarted }) |target| {
        try target.execute("DROP TABLE u", &result);
        try target.execute("CREATE TABLE v (x INTEGER PRIMARY KEY)", &result);
        try target.execute("CREATE SEQUENCE w", &result);
    }
    try check(try sameDatabase(&db, &restarted) and try sameCatalog(&db, &restarted));
    try check(try integer(&restarted, "SELECT oid FROM pg_class WHERE relname = 'w'") == oid + 6);
}

/// STO-01 with sequences: a bare CREATE SEQUENCE (D) and an identity table
/// with its owned sequence (A) both commit after B's higher OIDs.
fn outOfOrderSequences() !void {
    var db: DB = .{};
    var log: Log = .{};
    const d = try db.begin();
    try run(&db, d, "CREATE SEQUENCE r");
    const a = try db.begin();
    try run(&db, a, "CREATE TABLE t (id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, label TEXT DEFAULT 'd')");
    try run(&db, a, "INSERT INTO t (label) VALUES ('first')");
    const b = try db.begin();
    try run(&db, b, "CREATE SEQUENCE s START 10");
    try run(&db, b, "SELECT nextval('s')");
    try run(&db, b, "CREATE TABLE u (k INTEGER)");
    try run(&db, b, "INSERT INTO u VALUES (5)");
    try log.commit(&db, b);
    try log.commit(&db, a);
    try log.commit(&db, d);
    try check(log.count == 3 and db.oid_counter == 6);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'r'") == oid);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 't_id_seq'") == oid + 3);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'u'") == oid + 5);
    var restarted: DB = .{};
    try log.replay(&restarted);
    try check(try sameDatabase(&db, &restarted));
    try check(try sameCatalog(&db, &restarted));
    try check(try integer(&restarted, "SELECT nextval('r')") == try integer(&db, "SELECT nextval('r')"));
    // Log-ahead values: restarted sequences continue past every issued value.
    try check(try integer(&restarted, "INSERT INTO t (label) VALUES ('second') RETURNING id") > 1);
    try check(try integer(&restarted, "SELECT nextval('s')") > 10);
    var result: DB.Result = .{};
    for ([_]*DB{ &db, &restarted }) |target| try target.execute("CREATE SEQUENCE z", &result);
    try check(try integer(&restarted, "SELECT oid FROM pg_class WHERE relname = 'z'") == oid + 6);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'z'") == oid + 6);
}

/// Replay still rejects genuine OID conflicts atomically: a used table, key
/// index or sequence OID, an OID below first_oid or at the top, and two
/// creates of one OID in a record. An unused OID below the counter is
/// accepted and leaves the counter at its maximum.
fn oidConflicts() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT NOT NULL)", &result);
    try db.execute("CREATE SEQUENCE s", &result);
    try db.execute("CREATE SEQUENCE gap", &result);
    try db.execute("DROP SEQUENCE gap", &result);
    try check(db.oid_counter == 4);
    var reference: DB = .{};
    reference.copyFrom(&db);
    const Case = struct { table: ?u32 = null, keyed: bool = false, sequence: ?u32 = null };
    const cases = [_]Case{
        .{ .table = oid },
        .{ .table = oid + 1 },
        .{ .table = oid + 2 },
        .{ .table = oid + 1, .keyed = true },
        .{ .table = oid - 1 },
        .{ .table = oid - 1, .keyed = true },
        .{ .table = 0 },
        .{ .table = 0xfffffffe },
        .{ .sequence = oid },
        .{ .sequence = oid + 1 },
        .{ .sequence = oid + 2 },
        .{ .sequence = oid - 1 },
        .{ .sequence = 0xffffffff },
        .{ .table = oid + 20, .sequence = oid + 20 },
        .{ .table = oid + 20, .keyed = true, .sequence = oid + 21 },
    };
    for (cases) |case| {
        var builder: Builder = .{};
        if (case.table) |table_oid| builder.createTable(table_oid, "v", case.keyed);
        if (case.sequence) |sequence_oid| builder.createSequence(sequence_oid, "w");
        if (db.applyChangeRecord(builder.record(), &scratch)) |_| return error.OidConflictAccepted else |err| try check(err == error.ChangeRecordConflict);
        try check(try sameDatabase(&db, &reference) and try sameCatalog(&db, &reference));
    }
    // first_oid + 3 (the dropped sequence's gap) is unused: accepted after
    // w's higher OID, and it does not lower the counter (w's end, 31).
    var builder: Builder = .{};
    builder.createSequence(oid + 30, "w");
    builder.createTable(oid + 3, "v", false);
    try db.applyChangeRecord(builder.record(), &scratch);
    try check(db.oid_counter == 31 and db.tableCount() == 2);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'v'") == oid + 3);
    try db.execute("CREATE SEQUENCE x", &result);
    try check(try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'x'") == oid + 31);
}

/// A keyed table's index owns oid + 1, so a create whose INDEX OID lands on
/// a relation is a conflict (oidConflicts' oid - 1 cases stop at first_oid).
fn keyedIndexCollision() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try db.execute("CREATE SEQUENCE a", &result); // oid
    try db.execute("CREATE SEQUENCE b", &result); // oid + 1
    try db.execute("DROP SEQUENCE a", &result); // oid free, oid + 1 held by b
    try check(db.oid_counter == 2);
    var reference: DB = .{};
    reference.copyFrom(&db);
    // Database side: a keyed table at oid would put its index on b.
    var builder: Builder = .{};
    builder.createTable(oid, "v", true);
    if (db.applyChangeRecord(builder.record(), &scratch)) |_| return error.IndexOidCollisionAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(try sameDatabase(&db, &reference) and try sameCatalog(&db, &reference));
    // Record side: sequence w first, then a keyed table whose index is w.
    builder = .{};
    builder.createSequence(oid + 21, "w");
    builder.createTable(oid + 20, "v", true);
    if (db.applyChangeRecord(builder.record(), &scratch)) |_| return error.IndexOidCollisionAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(try sameDatabase(&db, &reference) and try sameCatalog(&db, &reference));
    // Control: the same OID without a key is free and is accepted.
    builder = .{};
    builder.createTable(oid, "v", false);
    try db.applyChangeRecord(builder.record(), &scratch);
    try check(db.oid_counter == 2 and try integer(&db, "SELECT oid FROM pg_class WHERE relname = 'v'") == oid);
}

/// An aborted top create rewinds the counter (mvcc abortSlice), so a later
/// create reuses that OID; out-of-order commits must still replay.
fn rewoundOidReplay() !void {
    var db: DB = .{};
    var log: Log = .{};
    const a = try db.begin();
    try run(&db, a, "CREATE TABLE t (id INTEGER PRIMARY KEY)"); // oid, oid + 1
    const b = try db.begin();
    try run(&db, b, "CREATE SEQUENCE g"); // oid + 2
    db.abort(b); // top: rewinds to oid + 2
    try check(db.oid_counter == 2);
    const c = try db.begin();
    try run(&db, c, "CREATE SEQUENCE h"); // oid + 2 again
    try log.commit(&db, c);
    try log.commit(&db, a);
    var restarted: DB = .{};
    try log.replay(&restarted);
    try check(try sameDatabase(&db, &restarted) and try sameCatalog(&db, &restarted));
}

pub fn main(init: std.process.Init) !void {
    try roundTrips();
    try corruption();
    try atomicity();
    try outOfOrderTables();
    try outOfOrderSequences();
    try oidConflicts();
    try keyedIndexCollision();
    try rewoundOidReplay();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-change-log\",\"pass\":true,\"assertions\":{d},\"rejected_flips\":{d},\"accepted_flips\":{d}}}\n", .{ assertions, rejected_flips, accepted_flips });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
