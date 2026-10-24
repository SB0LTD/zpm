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

pub fn main(init: std.process.Init) !void {
    try roundTrips();
    try corruption();
    try atomicity();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-change-log\",\"pass\":true,\"assertions\":{d},\"rejected_flips\":{d},\"accepted_flips\":{d}}}\n", .{ assertions, rejected_flips, accepted_flips });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
