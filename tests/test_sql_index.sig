//! Deterministic model-based checks for primary-key indexing and ownership.
//! The model is a flat key/value array; it never uses the database's index.
const std = @import("std");
const sql = @import("sql");
const DB = sql.Database(.{ .tables = 2, .columns = 3, .rows_per_table = 16, .name_bytes = 16, .text_bytes = 32, .predicates = 4 });
var assertions: usize = 0;
var statements: usize = 0;
var model_steps: usize = 0;
var rejected: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SqlIndexContractFailed;
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn execute(db: *DB, r: *DB.Result, source: []const u8) !void {
    statements += 1;
    try db.execute(source, r);
}
fn resultEqual(a: *const DB.Result, b: *const DB.Result) bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count or a.affected_rows != b.affected_rows) return false;
    for (0..a.column_count) |c| {
        if (a.column_types[c] != b.column_types[c] or !equal(a.column_names[c].slice(), b.column_names[c].slice())) return false;
    }
    for (0..a.row_count) |row| for (0..a.column_count) |c| {
        const x = a.rows[row].cells[c];
        const y = b.rows[row].cells[c];
        switch (x) {
            .null_value => if (y != .null_value) return false,
            .integer => |n| {
                if (y != .integer or y.integer != n) return false;
            },
            .boolean => |v| {
                if (y != .boolean or y.boolean != v) return false;
            },
            .text => |t| {
                if (y != .text or !equal(t.slice(), y.text.slice())) return false;
            },
            // This contract stores INTEGER/BOOLEAN/TEXT only.
            else => return false,
        }
    };
    return true;
}
fn rejects(db: *DB, r: *DB.Result, source: []const u8, wanted: anyerror) !void {
    const before = r.*;
    statements += 1;
    if (db.execute(source, r)) |_| return error.InvalidMutationAccepted else |err| try check(err == wanted);
    try check(resultEqual(&before, r));
    rejected += 1;
}
const Kind = enum { integer, text };
fn hashKey(comptime kind: Kind, key: u64) usize {
    // Used solely to choose adversarial inputs, never as the expected-data model.
    var code: u64 = 14695981039346656037;
    if (kind == .integer) {
        var bits = key;
        for (0..8) |_| {
            code = (code ^ @as(u8, @truncate(bits))) *% 1099511628211;
            bits >>= 8;
        }
    } else {
        var text: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&text, "k{d:0>10}", .{key}) catch unreachable;
        for (value) |byte| code = (code ^ byte) *% 1099511628211;
    }
    code ^= code >> 33;
    code *%= 0xff51afd7ed558ccd;
    code ^= code >> 33;
    return @truncate(code);
}
fn keysFor(comptime kind: Kind) [64]u64 {
    var keys: [64]u64 = undefined;
    var n: u64 = 0;
    var used: usize = 0;
    while (used < keys.len) : (n += 1) if (hashKey(kind, n) & 31 == 0) {
        keys[used] = n;
        used += 1;
    };
    return keys;
}
fn literal(comptime kind: Kind, key: u64, out: []u8) ![]const u8 {
    return if (kind == .integer) std.fmt.bufPrint(out, "{d}", .{key}) else std.fmt.bufPrint(out, "'k{d:0>10}'", .{key});
}
fn expectKey(comptime kind: Kind, cell: DB.Cell, key: u64) !void {
    if (kind == .integer) try check(cell == .integer and cell.integer == @as(i64, @intCast(key))) else {
        var text: [32]u8 = undefined;
        const wanted = try std.fmt.bufPrint(&text, "k{d:0>10}", .{key});
        try check(cell == .text and equal(cell.text.slice(), wanted));
    }
}
const Model = struct {
    live: [64]bool = @splat(false),
    values: [64]i64 = @splat(0),
    count: usize = 0,
};
fn verifyAll(comptime kind: Kind, keys: *const [64]u64, model: *const Model, db: *DB, r: *DB.Result) !void {
    try execute(db, r, "SELECT * FROM t ORDER BY id");
    try check(r.column_count == 3 and r.row_count == model.count);
    try check(r.column_types[0] == (if (kind == .integer) sql.DataType.integer32 else sql.DataType.text));
    try check(r.column_types[1] == .integer32 and r.column_types[2] == .boolean);
    var row: usize = 0;
    for (model.live, 0..) |live, i| if (live) {
        try expectKey(kind, r.rows[row].cells[0], keys[i]);
        try check(r.rows[row].cells[1] == .integer and r.rows[row].cells[1].integer == model.values[i]);
        try check(r.rows[row].cells[2] == .boolean and !r.rows[row].cells[2].boolean);
        row += 1;
    };
}
fn verifyPoint(comptime kind: Kind, keys: *const [64]u64, model: *const Model, i: usize, db: *DB, r: *DB.Result) !void {
    var text: [256]u8 = undefined;
    var key_text: [32]u8 = undefined;
    const key = try literal(kind, keys[i], &key_text);
    const source = try std.fmt.bufPrint(&text, "SELECT id, val FROM t WHERE id = {s}", .{key});
    try execute(db, r, source);
    try check(r.row_count == @as(usize, @intFromBool(model.live[i])) and r.column_count == 2);
    if (model.live[i]) {
        try expectKey(kind, r.rows[0].cells[0], keys[i]);
        try check(r.rows[0].cells[1].integer == model.values[i]);
    }
    const contradiction = try std.fmt.bufPrint(&text, "SELECT * FROM t WHERE id = {s} AND val <> {d}", .{ key, model.values[i] });
    try execute(db, r, contradiction);
    try check(r.row_count == 0);
}
fn randomModel(comptime kind: Kind) !void {
    const keys = keysFor(kind);
    var db: DB = .{};
    var result: DB.Result = .{};
    var model: Model = .{};
    try execute(&db, &result, if (kind == .integer) "CREATE TABLE t (id INTEGER PRIMARY KEY,val INTEGER,flag BOOLEAN)" else "CREATE TABLE t (id TEXT PRIMARY KEY,val INTEGER,flag BOOLEAN)");
    var seed: u64 = 0x51c7192bf00d;
    var text: [512]u8 = undefined;
    for (0..4096) |step| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const i: usize = @intCast((seed >> 32) % 64);
        const j: usize = @intCast((seed >> 48) % 64);
        const op = (seed >> 24) % 10;
        const value: i64 = @as(i64, @intCast(seed % 2000000)) - 1000000;
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        const old = try literal(kind, keys[i], &a);
        const new = try literal(kind, keys[j], &b);
        switch (op) {
            0, 1, 2 => {
                const source = try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({s},{d},FALSE)", .{ old, value });
                if (model.live[i]) try rejects(&db, &result, source, error.PrimaryKeyViolation) else if (model.count == 16) try rejects(&db, &result, source, error.RowCapacity) else {
                    try execute(&db, &result, source);
                    try check(result.affected_rows == 1);
                    model.live[i] = true;
                    model.values[i] = value;
                    model.count += 1;
                }
            },
            3 => {
                const source = try std.fmt.bufPrint(&text, "DELETE FROM t WHERE id = {s}", .{old});
                try execute(&db, &result, source);
                try check(result.affected_rows == @as(usize, @intFromBool(model.live[i])));
                if (model.live[i]) {
                    model.live[i] = false;
                    model.count -= 1;
                }
            },
            4 => {
                const source = try std.fmt.bufPrint(&text, "UPDATE t SET val = {d} WHERE id = {s}", .{ value, old });
                try execute(&db, &result, source);
                try check(result.affected_rows == @as(usize, @intFromBool(model.live[i])));
                if (model.live[i]) model.values[i] = value;
            },
            5 => {
                const source = try std.fmt.bufPrint(&text, "UPDATE t SET id = {s},val = {d} WHERE id = {s}", .{ new, value, old });
                if (model.live[i] and model.live[j] and i != j) try rejects(&db, &result, source, error.PrimaryKeyViolation) else {
                    try execute(&db, &result, source);
                    try check(result.affected_rows == @as(usize, @intFromBool(model.live[i])));
                    if (model.live[i]) {
                        model.live[i] = false;
                        model.live[j] = true;
                        model.values[j] = value;
                    }
                }
            },
            6 => {
                const source = try std.fmt.bufPrint(&text, "UPDATE t SET id = {s}", .{old});
                if (model.count > 1) try rejects(&db, &result, source, error.PrimaryKeyViolation) else {
                    try execute(&db, &result, source);
                    try check(result.affected_rows == model.count);
                    if (model.count == 1) {
                        for (model.live, 0..) |live, k| if (live) {
                            model.values[i] = model.values[k];
                            model.live[k] = false;
                            break;
                        };
                        model.live[i] = true;
                    }
                }
            },
            7 => {
                const source = try std.fmt.bufPrint(&text, "DELETE FROM t WHERE id <= {s}", .{old});
                var removed: usize = 0;
                for (0..i + 1) |k| if (model.live[k]) {
                    model.live[k] = false;
                    removed += 1;
                };
                try execute(&db, &result, source);
                try check(result.affected_rows == removed);
                model.count -= removed;
            },
            8 => {
                // The same by-value copy used by transaction snapshots must own
                // the index as well as rows, even after compaction and reuse.
                const before = db;
                try execute(&db, &result, "DELETE FROM t");
                const source = try std.fmt.bufPrint(&text, "INSERT INTO t VALUES ({s},{d},FALSE)", .{ old, value });
                try execute(&db, &result, source);
                db = before;
            },
            else => {
                const source = try std.fmt.bufPrint(&text, "DELETE FROM t WHERE id = {s}; DROP TABLE t", .{old});
                try rejects(&db, &result, source, error.Syntax);
            },
        }
        try verifyAll(kind, &keys, &model, &db, &result);
        try verifyPoint(kind, &keys, &model, i, &db, &result);
        if (step % 64 == 0) for (0..keys.len) |k| try verifyPoint(kind, &keys, &model, k, &db, &result);
        if (step % 257 == 256) {
            try execute(&db, &result, "DROP TABLE t");
            try execute(&db, &result, if (kind == .integer) "CREATE TABLE t (id INTEGER PRIMARY KEY,val INTEGER,flag BOOLEAN)" else "CREATE TABLE t (id TEXT PRIMARY KEY,val INTEGER,flag BOOLEAN)");
            model = .{};
            try verifyAll(kind, &keys, &model, &db, &result);
        }
        model_steps += 1;
    }
}
fn booleanAndMetadata() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try execute(&db, &r, "CREATE TABLE t (id BOOLEAN PRIMARY KEY,val INTEGER,flag TEXT)");
    try execute(&db, &r, "SELECT flag,id,val FROM t LIMIT 0");
    try check(r.row_count == 0 and r.column_count == 3 and r.column_types[0] == .text and r.column_types[1] == .boolean and r.column_types[2] == .integer32);
    try check(equal(r.column_names[0].slice(), "flag") and equal(r.column_names[1].slice(), "id"));
    try execute(&db, &r, "INSERT INTO t VALUES (FALSE,10,'a')");
    try execute(&db, &r, "INSERT INTO t VALUES (TRUE,20,'b')");
    try rejects(&db, &r, "INSERT INTO t VALUES (FALSE,30,'x')", error.PrimaryKeyViolation);
    try rejects(&db, &r, "UPDATE t SET id = FALSE WHERE id = TRUE", error.PrimaryKeyViolation);
    try rejects(&db, &r, "UPDATE t SET id = TRUE", error.PrimaryKeyViolation);
    try rejects(&db, &r, "INSERT INTO t VALUES (NULL,30,'x')", error.NotNullViolation);
    const snapshot = db;
    try execute(&db, &r, "DELETE FROM t WHERE id = FALSE");
    try execute(&db, &r, "SELECT val FROM t WHERE id = TRUE");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 20);
    try execute(&db, &r, "UPDATE t SET id = FALSE WHERE id = TRUE");
    try execute(&db, &r, "INSERT INTO t VALUES (TRUE,30,'c')");
    try execute(&db, &r, "SELECT val FROM t WHERE id = FALSE");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 20);
    db = snapshot;
    try execute(&db, &r, "SELECT val FROM t WHERE id = FALSE");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 10);
    try execute(&db, &r, "SELECT val FROM t WHERE id = TRUE");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 20);
    try execute(&db, &r, "SELECT * FROM t WHERE id = NULL");
    try check(r.row_count == 0 and r.column_types[0] == .boolean);
    try execute(&db, &r, "SELECT * FROM t WHERE id = TRUE AND id = FALSE");
    try check(r.row_count == 0);
    try execute(&db, &r, "SELECT flag FROM t WHERE id = FALSE LIMIT 0");
    try check(r.row_count == 0 and r.column_types[0] == .text);
}
fn boundaryKeys() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try execute(&db, &r, "CREATE TABLE t (id BIGINT PRIMARY KEY,val INTEGER)");
    try execute(&db, &r, "INSERT INTO t VALUES (-9223372036854775808,1)");
    try execute(&db, &r, "INSERT INTO t VALUES (9223372036854775807,2)");
    try execute(&db, &r, "INSERT INTO t VALUES (-1,3)");
    try execute(&db, &r, "INSERT INTO t VALUES (0,4)");
    try execute(&db, &r, "SELECT val FROM t WHERE id = -9223372036854775808");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 1);
    try execute(&db, &r, "SELECT val FROM t WHERE id = 9223372036854775807");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 2);
    try rejects(&db, &r, "UPDATE t SET id = -1 WHERE id = 0", error.PrimaryKeyViolation);
    try execute(&db, &r, "DROP TABLE t");
    try execute(&db, &r, "CREATE TABLE t (id TEXT PRIMARY KEY,val INTEGER)");
    try execute(&db, &r, "INSERT INTO t VALUES ('',1)");
    try execute(&db, &r, "INSERT INTO t VALUES ('X',2)");
    try execute(&db, &r, "INSERT INTO t VALUES ('x',3)");
    try execute(&db, &r, "INSERT INTO t VALUES ('a''b',4)");
    try execute(&db, &r, "SELECT val FROM t WHERE id = ''");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 1);
    try execute(&db, &r, "SELECT val FROM t WHERE id = 'a''b'");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 4);
    try rejects(&db, &r, "INSERT INTO t VALUES ('X',5)", error.PrimaryKeyViolation);
    try execute(&db, &r, "DELETE FROM t WHERE id = ''");
    try execute(&db, &r, "INSERT INTO t VALUES ('',6)");
    try execute(&db, &r, "SELECT val FROM t WHERE id = 'x'");
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 3);
}
fn orderedIntegralCandidates() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try execute(&db,&r,"CREATE TABLE t(id BIGINT PRIMARY KEY,val INTEGER)");
    // Dense signed keys exercise validated offset candidates. A gap, deleted
    // row, aborted low outlier and slot reuse must retain exact lookup results.
    var text:[128]u8=undefined;
    for(0..8) |i| try execute(&db,&r,try std.fmt.bufPrint(&text,"INSERT INTO t VALUES({d},{d})",.{@as(i64,@intCast(i))-4,i*17}));
    for(0..8) |i| {
        try execute(&db,&r,try std.fmt.bufPrint(&text,"SELECT val FROM t WHERE id={d}",.{@as(i64,@intCast(i))-4}));
        try check(r.row_count==1 and r.rows[0].cells[0].integer==i*17);
    }
    try execute(&db,&r,"DELETE FROM t WHERE id=-2");
    try execute(&db,&r,"SELECT val FROM t WHERE id=-2");try check(r.row_count==0);
    try execute(&db,&r,"SELECT val FROM t WHERE id=3");try check(r.row_count==1 and r.rows[0].cells[0].integer==119);
    // Explicit control statements use the session API, not execute's one-shot
    // autocommit wrapper. All statements inside the transaction share slot 0.
    try db.statement(0,"BEGIN",&r,.{});
    try db.statement(0,"INSERT INTO t VALUES(-9223372036854775808,999)",&r,.{});
    try db.statement(0,"UPDATE t SET id=100 WHERE id=-1",&r,.{});
    try db.statement(0,"SELECT val FROM t WHERE id=100",&r,.{});try check(r.row_count==1 and r.rows[0].cells[0].integer==51);
    try db.statement(0,"SELECT val FROM t WHERE id=-1",&r,.{});try check(r.row_count==0);
    try db.statement(0,"ROLLBACK",&r,.{});
    statements+=6;
    try execute(&db,&r,"SELECT val FROM t WHERE id=-1");try check(r.row_count==1 and r.rows[0].cells[0].integer==51);
    try execute(&db,&r,"SELECT val FROM t WHERE id=100");try check(r.row_count==0);
    try execute(&db,&r,"INSERT INTO t VALUES(-2,222)");
    try execute(&db,&r,"SELECT val FROM t WHERE id=-2");try check(r.row_count==1 and r.rows[0].cells[0].integer==222);
    try execute(&db,&r,"SELECT val FROM t WHERE id=9223372036854775807");try check(r.row_count==0);
}
pub fn main(init: std.process.Init) !void {
    try orderedIntegralCandidates();
    try randomModel(.integer);
    try randomModel(.text);
    try booleanAndMetadata();
    try boundaryKeys();
    var report: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"sql-index\",\"pass\":true,\"assertions\":{d},\"statements\":{d},\"model_steps\":{d},\"rejected\":{d}}}\n", .{ assertions, statements, model_steps, rejected });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
