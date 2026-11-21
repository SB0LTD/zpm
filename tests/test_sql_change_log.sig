//! Kind-3 change-record contracts: encode -> decode -> apply round trips,
//! truncation and bit-flip rejection, unknown op/version rejection and
//! whole-record atomicity. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 8, .work_rows = 64, .name_bytes = 16, .text_bytes = 24, .integer_bits = 32 });

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
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter or
        a.next_constraint_oid != b.next_constraint_oid or a.next_default_oid != b.next_default_oid) return false;
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

fn constraintIdentityRoundTrip() !void {
    var primary: DB = .{};
    var restored: DB = .{};
    // A real version-1 definition has only the inline primary-key flag.
    var legacy: Builder = .{};
    legacy.createTable(oid, "t", true);
    try primary.applyChangeRecord(legacy.record(), &scratch);
    try restored.applyChangeRecord(legacy.record(), &scratch);
    try check(primary.tables[0].primary_constraint_oid == oid);
    try check(restored.next_constraint_oid == oid + 1);

    var record: [1024]u8 = undefined;
    var result: DB.Result = .{};
    for ([_][]const u8{
        "ALTER TABLE t ADD CONSTRAINT ck CHECK (k > 0)",
        "ALTER TABLE t RENAME TO v",
    }) |statement| {
        var used: usize = 0;
        try primary.executeChanges(statement, &result, &record, &used, null, null);
        try restored.applyChangeRecord(record[0..used], &scratch);
        try check(try sameDatabase(&primary, &restored));
    }
    var active: usize = 0;
    for (&primary.tables, 0..) |*table, i| {
        if (table.live and table.dead_csn == 0) active = i;
    }
    try check(primary.tables[active].primary_constraint_oid == oid and restored.tables[0].primary_constraint_oid == oid);
    try check(primary.tables[active].constraints[0].oid == oid + 1 and restored.tables[0].constraints[0].oid == oid + 1);

    var used: usize = 0;
    try primary.executeChanges("CREATE TABLE u (k INT PRIMARY KEY)", &result, &record, &used, null, null);
    var bad: [1024]u8 = undefined;
    @memcpy(bad[0..used], record[0..used]);
    std.mem.writeInt(u32, bad[used - 4 ..][0..4], oid + 1, .little);
    if (restored.applyChangeRecord(bad[0..used], &scratch)) |_|
        return error.CollidingConstraintIdentityAccepted
    else |err| try check(err == error.ChangeRecordConflict);
    try check(restored.tableCount() == 1 and restored.next_constraint_oid == oid + 2);
    try restored.applyChangeRecord(record[0..used], &scratch);
    try check(restored.tables[1].primary_constraint_oid == oid + 2);
    try check(try sameDatabase(&primary, &restored));
}

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

fn scopedIdentitySequences() !void {
    var db: DB = .{};
    var log: Log = .{};
    const namespaces = try db.begin();
    try run(&db, namespaces, "CREATE SCHEMA src");
    try run(&db, namespaces, "CREATE SCHEMA dst");
    try log.commit(&db, namespaces);

    const definition = try db.begin();
    try run(&db, definition, "CREATE TABLE src.t(id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, n INTEGER)");
    try log.commit(&db, definition);

    var restarted: DB = .{};
    try restarted.applyChangeRecord(log.record(0), &scratch);
    const destination_namespace = try integer(&restarted, "SELECT oid FROM pg_namespace WHERE nspname='dst'");
    const record = log.record(1);
    var corrupt: [4096]u8 = undefined;
    @memcpy(corrupt[0..record.len], record);
    std.mem.writeInt(u32, corrupt[record.len - 4 ..][0..4], @intCast(destination_namespace), .little);
    if (restarted.applyChangeRecord(corrupt[0..record.len], &scratch)) |_| {
        return error.CrossSchemaSequenceAccepted;
    } else |err| try check(err == error.ChangeRecordConflict);
    try check(try integer(&restarted, "SELECT count(*) FROM pg_class WHERE relname='t_id_seq'") == 0);
    try restarted.applyChangeRecord(record, &scratch);
    try check(try integer(&restarted, "SELECT last_value FROM src.t_id_seq WHERE NOT is_called") == 1);

    const second = try db.begin();
    try run(&db, second, "CREATE TABLE dst.t(id INTEGER GENERATED BY DEFAULT AS IDENTITY (START 10) PRIMARY KEY, n INTEGER)");
    try run(&db, second, "INSERT INTO src.t(n) VALUES (4)");
    try run(&db, second, "INSERT INTO dst.t(n) VALUES (5)");
    try log.commit(&db, second);
    try restarted.applyChangeRecord(log.record(2), &scratch);
    try check(try integer(&restarted, "SELECT count(*) FROM pg_class WHERE relname='t_id_seq' AND relkind='S'") == 2);
    try check(try integer(&restarted, "SELECT 'src.t_id_seq'::regclass::oid") != try integer(&restarted, "SELECT 'dst.t_id_seq'::regclass::oid"));
    try check(try integer(&restarted, "SELECT id FROM src.t") == 1);
    try check(try integer(&restarted, "SELECT id FROM dst.t") == 10);
    try check(try integer(&db, "SELECT last_value FROM src.t_id_seq WHERE is_called") == 1);
    try check(try integer(&db, "SELECT s.last_value FROM dst.t_id_seq s CROSS JOIN src.t_id_seq t WHERE t.last_value=1 AND s.is_called") == 10);
    try check(try integer(&restarted, "INSERT INTO src.t(n) VALUES (7) RETURNING id") > 1);
    try check(try integer(&restarted, "INSERT INTO dst.t(n) VALUES (8) RETURNING id") > 10);
    const drop = try db.begin();
    try run(&db, drop, "DROP SCHEMA src CASCADE");
    try log.commit(&db, drop);
    // Replay the source log into a fresh target after exercising recovered
    // identities with independent writes on the first replay target.
    var dropped: DB = .{};
    try log.replay(&dropped);
    try check(try integer(&dropped, "SELECT count(*) FROM pg_class WHERE relname='t_id_seq' AND relkind='S'") == 1);
    try check(try integer(&dropped, "SELECT id FROM dst.t") == 10);
}

fn scopedStandaloneSequences() !void {
    var db: DB = .{};
    var log: Log = .{};
    const create = try db.begin();
    try run(&db, create, "CREATE SCHEMA src");
    try run(&db, create, "CREATE SCHEMA dst");
    try run(&db, create, "CREATE SEQUENCE src.s START WITH 31");
    try run(&db, create, "CREATE SEQUENCE dst.s START WITH 48 CACHE 2");
    try run(&db, create, "SELECT setval('src.s',34,true)");
    try run(&db, create, "SELECT setval('dst.s',48,false)");
    try log.commit(&db, create);
    const alter = try db.begin();
    try run(&db, alter, "ALTER SEQUENCE src.s RESTART WITH 40");
    try log.commit(&db, alter);

    var restarted: DB = .{};
    try log.replay(&restarted);
    try check(try integer(&restarted, "SELECT last_value FROM src.s WHERE NOT is_called") == 40);
    try check(try integer(&restarted, "SELECT last_value FROM dst.s WHERE NOT is_called") == 48);
    var result: DB.Result = .{};
    if (db.execute("DROP SCHEMA src", &result)) |_| {
        return error.DroppedSchemaWithSequence;
    } else |err| try check(err == error.DependentObjects);

    const drop = try db.begin();
    try run(&db, drop, "DROP SCHEMA src CASCADE");
    try log.commit(&db, drop);
    try restarted.applyChangeRecord(log.record(2), &scratch);
    try check(try integer(&restarted, "SELECT count(*) FROM pg_class WHERE relname='s' AND relkind='S'") == 1);
    const explicit_drop = try db.begin();
    try run(&db, explicit_drop, "DROP SEQUENCE dst.s");
    try log.commit(&db, explicit_drop);
    try restarted.applyChangeRecord(log.record(3), &scratch);
    try check(try integer(&restarted, "SELECT count(*) FROM pg_class WHERE relname='s' AND relkind='S'") == 0);
}

fn addIdentityToColumn() !void {
    var db: DB = .{};
    var log: Log = .{};
    const definition = try db.begin();
    try run(&db, definition, "CREATE SCHEMA src");
    try run(&db, definition, "CREATE TABLE src.t(id INTEGER NOT NULL, n INTEGER)");
    try run(&db, definition, "INSERT INTO src.t VALUES (4, 7)");
    try log.commit(&db, definition);

    const rollback = try db.begin();
    try run(&db, rollback, "ALTER TABLE src.t ALTER id ADD GENERATED ALWAYS AS IDENTITY (SEQUENCE NAME src.old_seq)");
    db.abort(rollback);
    try check(try integer(&db, "SELECT count(*) FROM pg_class WHERE relname='old_seq'") == 0);

    const alter = try db.begin();
    try run(&db, alter, "ALTER TABLE ONLY src.t ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (SEQUENCE NAME src.new_seq INCREMENT BY 2 START WITH 40 CACHE 1)");
    try run(&db, alter, "INSERT INTO src.t(n) VALUES (11)");
    try log.commit(&db, alter);
    try check(try integer(&db, "SELECT id FROM src.t WHERE n=7") == 4);
    try check(try integer(&db, "SELECT id FROM src.t WHERE n=11") == 40);
    try check(try integer(&db, "SELECT last_value FROM src.new_seq WHERE is_called") == 40);

    var restarted: DB = .{};
    try log.replay(&restarted);
    try check(try integer(&restarted, "SELECT id FROM src.t WHERE n=7") == 4);
    try check(try integer(&restarted, "SELECT id FROM src.t WHERE n=11") == 40);
    try check(try integer(&restarted, "INSERT INTO src.t(n) VALUES (13) RETURNING id") > 40);
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

fn replayCardinality() !void {
    var producer: DB = .{};
    var replayed: DB = .{};
    var log: Log = .{};
    const initial = try producer.begin();
    try run(&producer, initial, "CREATE TABLE t(id INT PRIMARY KEY, label TEXT, flag BOOL)");
    try run(&producer, initial, "INSERT INTO t VALUES(1,'old',NULL),(2,'old',NULL),(3,'old',NULL),(4,'old',NULL),(5,'old',NULL),(6,'old',NULL),(7,'old',NULL),(8,'old',NULL)");
    try log.commit(&producer, initial);
    var result: DB.Result = .{};
    var mixed: [1024]u8 = undefined;
    var mixed_used: usize = 0;
    for ([_][]const u8{ "DELETE FROM t WHERE id=1", "INSERT INTO t VALUES(9,'new',TRUE)", "UPDATE t SET label='changed' WHERE id=8" }) |source| {
        try producer.executeChanges(source, &result, &mixed, &mixed_used, null, null);
    }
    var truncated: [1024]u8 = undefined;
    var truncated_used: usize = 0;
    try producer.executeChanges("TRUNCATE t", &result, &truncated, &truncated_used, null, null);
    try producer.executeChanges("INSERT INTO t VALUES(10,'after',FALSE),(11,'after',NULL)", &result, &truncated, &truncated_used, null, null);

    try replayed.applyChangeRecord(log.record(0), &scratch);
    try check(replayed.tables[0].summary.rows == 8 and replayed.tables[0].row_used == 8);
    try replayed.applyChangeRecord(mixed[0..mixed_used], &scratch);
    try check(replayed.tables[0].summary.rows == 8 and replayed.tables[0].row_used == 8);
    try replayed.applyChangeRecord(truncated[0..truncated_used], &scratch);
    try check(replayed.tables[0].summary.rows == 2 and replayed.tables[0].row_used == 2);
    try check(try sameDatabase(&producer, &replayed));

    // An invalid or disagreeing seed cannot admit an overflowing record.
    var full: DB = .{};
    try full.applyChangeRecord(log.record(0), &scratch);
    const summary = full.tables[0].summary;
    const old_csn = full.csn;
    var overflow: Builder = .{};
    overflow.row(3, oid, 40, 40, "overflow");
    for (0..3) |mode| {
        full.tables[0].summary = summary;
        switch (mode) {
            0 => full.tables[0].summary.valid = false,
            1 => full.tables[0].summary.rows = 0,
            else => full.tables[0].summary.csn = full.csn + 1,
        }
        if (full.applyChangeRecord(overflow.record(), &scratch)) |_| return error.FullReplayAccepted else |err| try check(err == error.ChangeRecordConflict);
        try check(full.csn == old_csn and full.tables[0].row_used == 8);
    }
    full.tables[0].summary = summary;

    // Legacy or pinned history can occupy a row slot after DELETE. Such a
    // row must stay out of the logical capacity count during validation.
    const reader = try full.begin();
    full.txs[reader].pin = .{ .csn = full.csn };
    try full.execute("DELETE FROM t WHERE id=1", &result);
    full.abort(reader);
    try check(full.tables[0].summary.rows == 7 and full.tables[0].row_used == 8);
    try full.applyChangeRecord(overflow.record(), &scratch);
    try check(full.tables[0].summary.rows == 8 and full.tables[0].row_used == 8);
    try check(try integer(&full, "SELECT id FROM t WHERE id=40") == 40);
}

fn truncateCurrentHorizon() !void {
    var primary: DB = .{};
    var restarted: DB = .{};
    var log: Log = .{};
    const setup = try primary.begin();
    try run(&primary, setup, "CREATE TABLE t(id INT PRIMARY KEY, amount INT)");
    try run(&primary, setup, "INSERT INTO t VALUES(1,10),(2,20)");
    try log.commit(&primary, setup);

    const truncator = try primary.begin();
    try run(&primary, truncator, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ");
    try run(&primary, truncator, "SELECT 1");
    const stale_reader = try primary.begin();
    try run(&primary, stale_reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ");
    try run(&primary, stale_reader, "SELECT 1");
    const concurrent = try primary.begin();
    try run(&primary, concurrent, "UPDATE t SET amount=11 WHERE id=1");
    try run(&primary, concurrent, "DELETE FROM t WHERE id=2");
    try run(&primary, concurrent, "INSERT INTO t VALUES(3,30)");
    try log.commit(&primary, concurrent);

    var result: DB.Result = .{};
    try run(&primary, truncator, "INSERT INTO t VALUES(4,40)");
    try primary.savepoint(truncator, "before_truncate");
    try run(&primary, truncator, "TRUNCATE t");
    try primary.statement(truncator, "SELECT id FROM t", &result, .{});
    try check(result.row_count == 0);
    try run(&primary, truncator, "INSERT INTO t VALUES(5,50)");
    try primary.savepoint(truncator, "before_second");
    try run(&primary, truncator, "TRUNCATE t");
    try primary.statement(truncator, "SELECT id FROM t", &result, .{});
    try check(result.row_count == 0);
    _ = try primary.rollbackTo(truncator, "before_second");
    try primary.statement(truncator, "SELECT id FROM t", &result, .{});
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 5);
    _ = try primary.rollbackTo(truncator, "before_truncate");
    try primary.statement(truncator, "SELECT id FROM t ORDER BY id", &result, .{});
    try check(result.row_count == 3 and result.rows[0].cells[0].integer == 1 and
        result.rows[1].cells[0].integer == 2 and result.rows[2].cells[0].integer == 4);
    try run(&primary, truncator, "TRUNCATE t");
    try run(&primary, truncator, "INSERT INTO t VALUES(5,50)");
    try log.commit(&primary, truncator);
    try primary.statement(stale_reader, "SELECT id FROM t", &result, .{});
    try check(result.row_count == 0);
    primary.abort(stale_reader);
    try check(try integer(&primary, "SELECT COUNT(*) FROM t") == 1);
    try check(try integer(&primary, "SELECT id FROM t") == 5);
    try check(primary.tables[0].summary.rows == 1);
    try log.replay(&restarted);
    try check(try sameDatabase(&primary, &restarted));

    const holder = try primary.begin();
    try run(&primary, holder, "SELECT id FROM t");
    const waiter = try primary.begin();
    if (primary.statement(waiter, "TRUNCATE t", &result, .{})) |_|
        return error.TruncateBypassedAccessShare
    else |err| try check(err == error.WouldBlock);
    primary.abort(waiter);
    primary.abort(holder);
    try check(try sameDatabase(&primary, &restarted));

    const stale_binding = try primary.begin();
    try run(&primary, stale_binding, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ");
    try run(&primary, stale_binding, "SELECT 1");
    try primary.execute("ALTER TABLE t ADD COLUMN extra INT", &result);
    if (primary.statement(stale_binding, "TRUNCATE t", &result, .{})) |_|
        return error.StaleTruncateBindingAccepted
    else |err| try check(err == error.SerializationFailure);
    primary.abort(stale_binding);
    try check(try integer(&primary, "SELECT id FROM t") == 5);
}

fn explicitPrimaryIdentity() !void {
    var legacy: DB = .{};
    var result: DB.Result = .{};
    var encoded: [4096]u8 = undefined;
    var used: usize = 0;
    try legacy.executeChanges("CREATE TABLE a(id INT PRIMARY KEY)", &result, &encoded, &used, null, null);
    const alias = oid + 121;
    const create_alias = "SELECT to_regclass('a_pkey')::oid";
    try check(try integer(&legacy, create_alias) == oid + 1);
    // Header, op, table OID and the one-byte name precede the definition version.
    const version_at = 8 + 1 + 4 + 1 + 1;
    try check(std.mem.readInt(u16, encoded[version_at..][0..2], .little) == 4);
    std.mem.writeInt(u16, encoded[version_at..][0..2], 5, .little);
    std.mem.writeInt(u32, encoded[used..][0..4], alias, .little);
    const explicit = encoded[0 .. used + 4];
    var fresh: DB = .{};
    var restored: DB = .{};
    var forged: Builder = .{};
    for ([_]u32{ 0, oid, 0xffffffff }) |invalid| {
        std.mem.writeInt(u32, encoded[used..][0..4], invalid, .little);
        if (fresh.applyChangeRecord(explicit, &scratch)) |_| return error.InvalidPrimaryAliasAccepted else |err| try check(err == error.InvalidChangeRecord);
        try check(fresh.csn == 0 and fresh.oid_counter == 0 and fresh.tableCount() == 0);
    }
    std.mem.writeInt(u32, encoded[used..][0..4], alias, .little);
    if (fresh.applyChangeRecord(explicit[0 .. explicit.len - 1], &scratch)) |_| return error.ShortPrimaryAliasAccepted else |err| try check(err == error.InvalidChangeRecord);
    forged.createTable(alias, "existing", false);
    const collision = forged.record()[8..];
    @memcpy(encoded[explicit.len..][0..collision.len], collision);
    std.mem.writeInt(u32, encoded[4..8], 2, .little);
    if (fresh.applyChangeRecord(encoded[0 .. explicit.len + collision.len], &scratch)) |_| return error.PrimaryAliasCollisionAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(fresh.csn == 0 and fresh.oid_counter == 0 and fresh.tableCount() == 0);
    std.mem.writeInt(u32, encoded[4..8], 1, .little);
    try restored.applyChangeRecord(forged.record(), &scratch);
    if (restored.applyChangeRecord(explicit, &scratch)) |_| return error.PrimaryAliasCollisionAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(restored.csn == 1 and restored.tableCount() == 1 and restored.oid_counter == alias + 1 - oid);
    restored = .{};
    try fresh.applyChangeRecord(explicit, &scratch);
    try restored.applyChangeRecord(explicit, &scratch);
    legacy = .{};
    try legacy.applyChangeRecord(explicit, &scratch);
    try check(fresh.oid_counter == alias + 1 - oid);
    try check(try integer(&fresh, create_alias) == alias);
    try check(try integer(&fresh, "SELECT oid FROM pg_class WHERE relname='a_pkey'") == alias);
    try check(try integer(&fresh, "SELECT indexrelid FROM pg_index WHERE indisprimary") == alias);
    try check(try integer(&fresh, "SELECT conindid FROM pg_constraint WHERE contype='p'") == alias);
    try fresh.execute("SELECT pg_get_indexdef(indexrelid, 1, false) FROM pg_index WHERE indisprimary", &result);
    try check(result.row_count == 1 and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "id"));

    forged = .{};
    forged.createTable(alias, "taken", false);
    if (fresh.applyChangeRecord(forged.record(), &scratch)) |_| return error.PrimaryAliasCollisionAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(fresh.csn == 1 and fresh.tableCount() == 1 and fresh.oid_counter == alias + 1 - oid);
    // An explicit alias leaves the historical neighboring OID free.
    forged = .{};
    forged.createTable(oid + 1, "neighbor", false);
    try fresh.applyChangeRecord(forged.record(), &scratch);
    try check(try integer(&fresh, "SELECT oid FROM pg_class WHERE relname='neighbor'") == oid + 1);
    try check(try integer(&fresh, create_alias) == alias);

    used = 0;
    try restored.executeChanges("ALTER TABLE a ADD COLUMN n INT", &result, &encoded, &used, null, null);
    try check(std.mem.readInt(u16, encoded[version_at..][0..2], .little) == 5);
    // The explicit identity survives COW and replay of ALTER.
    try legacy.applyChangeRecord(encoded[0..used], &scratch);
    try check(try integer(&restored, create_alias) == alias and try integer(&legacy, create_alias) == alias);
    fresh = .{};
    try fresh.execute("CREATE TABLE a(id INT)", &result);
    if (fresh.applyChangeRecord(encoded[0..used], &scratch)) |_| return error.NewPrimaryKeyReplayAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(fresh.csn == 1 and fresh.oid_counter == 1 and fresh.tableCount() == 1);
}

fn defaultIdentityRoundTrip() !void {
    var primary: DB = .{};
    var restored: DB = .{};
    var record: [2048]u8 = undefined;
    const statements = [_][]const u8{
        "CREATE TABLE t (id INT DEFAULT 7, n INT GENERATED ALWAYS AS (id + 1) STORED)",
        "ALTER TABLE t RENAME COLUMN n TO computed",
        "ALTER TABLE t ALTER COLUMN id SET DEFAULT 9",
        "ALTER TABLE t ALTER COLUMN id DROP DEFAULT",
        "CREATE TABLE u (id INT DEFAULT 32)",
    };
    const query = "SELECT oid,adnum,pg_get_expr(adbin,adrelid) FROM pg_attrdef ORDER BY oid";
    for (statements) |statement| {
        var used: usize = 0;
        var expected: DB.Result = .{};
        var actual: DB.Result = .{};
        try primary.executeChanges(statement, &expected, &record, &used, null, null);
        try restored.applyChangeRecord(record[0..used], &scratch);
        try primary.execute(query, &expected);
        try restored.execute(query, &actual);
        try check(sameResult(&expected, &actual));
        try check(primary.next_default_oid == restored.next_default_oid);
    }
    var result: DB.Result = .{};
    try restored.execute(query, &result);
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == oid + 1 and
        result.rows[1].cells[0].integer == oid + 3);
    var used: usize = 0;
    try primary.encodeCatalogCounters(&record, &used);
    try restored.applyChangeRecord(record[0..used], &scratch);
    try check(restored.next_default_oid == oid + 4);
}

fn legacyDefaultIdentity() !void {
    var restored: DB = .{};
    var legacy: Builder = .{};
    legacy.int(u8, 1);
    legacy.int(u32, oid);
    legacy.name("t");
    legacy.int(u16, 1);
    legacy.int(u8, 1);
    legacy.name("k");
    legacy.int(u32, 23);
    legacy.int(i32, -1);
    legacy.int(u8, 4);
    legacy.int(u16, 1);
    legacy.int(u8, '7');
    legacy.ops = 1;
    try restored.applyChangeRecord(legacy.record(), &scratch);
    var result: DB.Result = .{};
    try restored.execute("SELECT oid,pg_get_expr(adbin,adrelid) FROM pg_attrdef", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == oid and
        std.mem.eql(u8, result.rows[0].cells[1].text.slice(), "7"));
    try check(restored.next_default_oid == oid + 1);
}

pub fn main(init: std.process.Init) !void {
    try roundTrips();
    try constraintIdentityRoundTrip();
    try defaultIdentityRoundTrip();
    try legacyDefaultIdentity();
    try corruption();
    try atomicity();
    try outOfOrderTables();
    try outOfOrderSequences();
    try scopedIdentitySequences();
    try scopedStandaloneSequences();
    try addIdentityToColumn();
    try oidConflicts();
    try keyedIndexCollision();
    try explicitPrimaryIdentity();
    try rewoundOidReplay();
    try replayCardinality();
    try truncateCurrentHorizon();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-change-log\",\"pass\":true,\"assertions\":{d},\"rejected_flips\":{d},\"accepted_flips\":{d}}}\n", .{ assertions, rejected_flips, accepted_flips });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
