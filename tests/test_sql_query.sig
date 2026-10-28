//! Query-engine contracts (design §4.9, §5.5-§5.9): the stable merge sort
//! and its counted O(n log n) comparisons, ORDER BY / NULL ordering /
//! DISTINCT / DISTINCT ON / OFFSET / FETCH, aggregates and GROUP BY, joins,
//! subqueries, CTEs (including WITH RECURSIVE) and set operations, their
//! SQLSTATE error classes, and that a failing query (including workspace
//! exhaustion) leaves the caller's result untouched. The assertion counter
//! proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 4, .columns = 6, .rows_per_table = 64, .name_bytes = 16, .text_bytes = 32, .nulls_first_ascending = false, .integer_bits = 32 });
/// 512 rows for one-group/512-groups and the 512 x 512 primary-key join.
const Big = sql.Database(.{ .tables = 2, .columns = 5, .rows_per_table = 512, .name_bytes = 16, .text_bytes = 16, .nulls_first_ascending = false, .integer_bits = 32 });
/// A deliberately small workspace (WorkspaceCapacity before publication).
const Tiny = sql.Database(.{ .tables = 2, .columns = 2, .rows_per_table = 32, .name_bytes = 16, .text_bytes = 16, .work_rows = 8, .nulls_first_ascending = false, .integer_bits = 32 });

var big: Big = .{};
var big_result: Big.Result = .{};
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlQueryContractFailed;
}

// ---- merge sort -------------------------------------------------------

const Counting = struct {
    keys: []const u32,
    calls: u64 = 0,

    pub fn order(self: *Counting, a: u32, b: u32) sql.Error!i8 {
        self.calls += 1;
        const x = self.keys[a];
        const y = self.keys[b];
        return if (x < y) -1 else if (x > y) 1 else 0;
    }
};

fn ceilLog2(n: usize) u64 {
    var bits: u64 = 0;
    while ((@as(usize, 1) << @intCast(bits)) < n) bits += 1;
    return bits;
}

fn sortContract() !void {
    var keys: [4096]u32 = undefined;
    var items: [4096]u32 = undefined;
    var scratch: [4096]u32 = undefined;
    var seed: u32 = 0x9e3779b9;
    const sizes = [_]usize{ 0, 1, 2, 3, 7, 8, 9, 100, 511, 512, 513, 1000, 4096 };
    for (sizes) |n| {
        for (0..4) |shape| {
            for (0..n) |index| {
                seed = seed *% 1664525 +% 1013904223;
                keys[index] = switch (shape) {
                    0 => seed >> 24, // many ties
                    1 => @intCast(n - index), // descending
                    2 => @intCast(index), // ascending
                    else => 7, // all equal
                };
                items[index] = @intCast(index);
            }
            var counter: Counting = .{ .keys = keys[0..n] };
            const reported = try sql.mergeSort(items[0..n], scratch[0..n], &counter);
            try check(reported == counter.calls);
            // O(n log n): bottom-up merge sort makes at most n * ceil(log2 n) comparisons.
            try check(counter.calls <= @as(u64, n) * ceilLog2(n));
            for (1..@max(n, 1)) |index| {
                const a = items[index - 1];
                const b = items[index];
                try check(keys[a] <= keys[b]);
                // Stability: equal keys keep their input order.
                if (keys[a] == keys[b]) try check(a < b);
            }
        }
    }
    var seen: [4096]bool = @splat(false);
    for (items[0..4096]) |index| seen[index] = true;
    for (seen) |flag| try check(flag);
}

const StableCounting = struct {
    keys: []const u32,
    calls: u64 = 0,
    fail_at: u64 = 0,
    pub fn order(self: *StableCounting, a: u32, b: u32) sql.Error!i8 {
        self.calls += 1;
        if (self.fail_at != 0 and self.calls == self.fail_at) return error.QueryCanceled;
        if (self.keys[a] < self.keys[b]) return -1;
        if (self.keys[a] > self.keys[b]) return 1;
        return if (a < b) -1 else if (a > b) 1 else 0;
    }
};
fn topKContract() !void {
    var keys: [4096]u32 = undefined;
    var all: [4096]u32 = undefined;
    var scratch: [4096]u32 = undefined;
    var heap: [4096]u32 = undefined;
    for (0..4) |pattern| {
        for (0..keys.len) |i| {
            keys[i] = switch (pattern) { 0 => @intCast((i * 17) % 37), 1 => @intCast(keys.len-i), 2 => @intCast(i), else => 7 };
            all[i] = @intCast(i);
        }
        var reference = StableCounting{ .keys = &keys };
        _ = try sql.mergeSort(&all, &scratch, &reference);
        for ([_]usize{0,1,2,16,63,512,4096}) |k| {
            var comparator = StableCounting{ .keys = &keys };
            var used: usize = 0;
            for (0..keys.len) |i| try sql.offerTopK(heap[0..k], &used, @intCast(i), &comparator);
            try check(used == k);
            // The bound excludes final ordering, which costs O(k log k).
            try check(comparator.calls <= keys.len * (2 * ceilLog2(@max(k,1)) + 3));
            _ = try sql.mergeSort(heap[0..used], scratch[0..used], &comparator);
            for (heap[0..used], all[0..used]) |actual,wanted| try check(actual == wanted);
        }
    }
    var failing = StableCounting{ .keys = &keys, .fail_at = 2 };
    var used: usize = 0;
    try sql.offerTopK(heap[0..2], &used, 0, &failing);
    try sql.offerTopK(heap[0..2], &used, 1, &failing);
    if (sql.offerTopK(heap[0..2], &used, 2, &failing)) |_| return error.CancelIgnored else |err| try check(err == error.QueryCanceled);
}

// ---- result rendering ---------------------------------------------------

var text_buffer: [8192]u8 = undefined;

/// Rows as `a|b;c|d` with NULL for null cells (PostgreSQL text output).
fn render(comptime T: type, result: *const T.Result) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [T.Io.format_bytes]u8 = undefined;
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
            const text = if (cell.* == .null_value) "NULL" else try T.Io.format(cell, false, T.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn expect(db: *DB, r: *DB.Result, source: []const u8, wanted: []const u8) !void {
    db.execute(source, r) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    const got = try render(DB, r);
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ source, got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn names(r: *const DB.Result, wanted: []const []const u8) !void {
    try check(r.column_count == wanted.len);
    for (wanted, 0..) |name, column| try check(std.mem.eql(u8, r.column_names[column].slice(), name));
}

/// The error, and an untouched result on failure.
fn rejects(db: anytype, r: anytype, source: []const u8, wanted: anyerror) !void {
    const before_rows = r.row_count;
    const before_columns = r.column_count;
    const before_command = r.command;
    if (db.execute(source, r)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidQueryAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        try check(err == wanted);
    }
    try check(r.row_count == before_rows and r.column_count == before_columns and r.command == before_command);
}

fn base(db: *DB, r: *DB.Result) !void {
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, flag BOOLEAN, label TEXT, n INTEGER)", r);
    try db.execute("INSERT INTO t VALUES (1, TRUE, 'one', 10)", r);
    try db.execute("INSERT INTO t VALUES (2, FALSE, NULL, 20)", r);
    try db.execute("INSERT INTO t VALUES (3, NULL, 'three', 10)", r);
    try db.execute("INSERT INTO t VALUES (4, TRUE, 'four', NULL)", r);
    try db.execute("INSERT INTO t VALUES (5, FALSE, 'five', 20)", r);
}

// ---- 3.3 sorting, DISTINCT, pagination ----------------------------------

fn ordering() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try expect(&db, &r, "SELECT DISTINCT flag FROM t ORDER BY flag", "f;t;NULL");
    try expect(&db, &r, "SELECT DISTINCT n FROM t ORDER BY n DESC", "NULL;20;10");
    try expect(&db, &r, "SELECT DISTINCT flag, n FROM t ORDER BY flag NULLS FIRST, n", "NULL|10;f|20;t|10;t|NULL");
    try expect(&db, &r, "SELECT id FROM t ORDER BY n NULLS FIRST, id DESC", "4;3;1;5;2");
    try expect(&db, &r, "SELECT id FROM t ORDER BY flag DESC, n ASC NULLS LAST, id", "3;1;4;2;5");
    try expect(&db, &r, "SELECT id, n FROM t ORDER BY 2, 1 DESC OFFSET 1", "1|10;5|20;2|20;4|NULL");
    try expect(&db, &r, "SELECT id FROM t ORDER BY id LIMIT ALL OFFSET 3", "4;5");
    try expect(&db, &r, "SELECT id FROM t ORDER BY id OFFSET 1 ROWS FETCH FIRST 2 ROWS ONLY", "2;3");
    try expect(&db, &r, "SELECT id FROM t ORDER BY id FETCH NEXT ROW ONLY", "1");
    try expect(&db, &r, "SELECT id FROM t ORDER BY id OFFSET 10", "");
    try expect(&db, &r, "SELECT id FROM t ORDER BY id % 2, id DESC OFFSET 0", "4;2;5;3;1");
    // Ties keep a stable (input) order under the merge sort.
    try expect(&db, &r, "SELECT DISTINCT ON (n) n, id FROM t ORDER BY n, id DESC", "10|3;20|5;NULL|4");
    try expect(&db, &r, "SELECT DISTINCT ON (flag) flag, label FROM t ORDER BY flag, id", "f|NULL;t|one;NULL|three");
    try expect(&db, &r, "SELECT DISTINCT ON (n) id FROM t ORDER BY n DESC, id", "4;2;1");
    try expect(&db, &r, "SELECT DISTINCT label IS NULL FROM t ORDER BY 1", "f;t");
    try rejects(&db, &r, "SELECT DISTINCT flag FROM t ORDER BY id", error.InvalidColumnReference);
    try rejects(&db, &r, "SELECT DISTINCT ON (n) id FROM t ORDER BY id, n", error.InvalidColumnReference);
    try rejects(&db, &r, "SELECT id FROM t LIMIT -1", error.InvalidRowCountInLimit);
    try rejects(&db, &r, "SELECT id FROM t ORDER BY id LIMIT -1", error.InvalidRowCountInLimit);
    try rejects(&db, &r, "SELECT id FROM t OFFSET -1", error.InvalidRowCountInResultOffset);
    try rejects(&db, &r, "SELECT id FROM t ORDER BY 9 OFFSET 1", error.InvalidColumnReference);
    try rejects(&db, &r, "SELECT nope FROM t LIMIT -1", error.ColumnNotFound);
}

// ---- 3.4 aggregates and GROUP BY ------------------------------------------

fn aggregates() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try expect(&db, &r, "SELECT COUNT(*), SUM(id) FROM t", "5|15");
    try check(r.column_types[0] == .integer and r.column_types[1] == .integer);
    try names(&r, &.{ "count", "sum" });
    try expect(&db, &r, "SELECT COUNT(n), COUNT(DISTINCT n), SUM(n), AVG(n), MIN(label), MAX(label) FROM t", "4|2|60|15.0000000000000000|five|three");
    try check(r.column_types[3] == .numeric);
    try expect(&db, &r, "SELECT AVG(id), BOOL_AND(flag), BOOL_OR(flag), EVERY(id > 0) FROM t", "3.0000000000000000|f|t|t");
    try expect(&db, &r, "SELECT COUNT(*) FILTER (WHERE flag), SUM(n) FILTER (WHERE id > 2) FROM t", "2|30");
    try expect(&db, &r, "SELECT flag, COUNT(*) FROM t GROUP BY flag ORDER BY flag", "f|2;t|2;NULL|1");
    try expect(&db, &r, "SELECT n, COUNT(*) AS c FROM t GROUP BY n ORDER BY c DESC, n", "10|2;20|2;NULL|1");
    try expect(&db, &r, "SELECT n % 20 AS k, SUM(id) FROM t GROUP BY 1 ORDER BY 1", "0|7;10|4;NULL|4");
    try expect(&db, &r, "SELECT flag, n, COUNT(*) FROM t GROUP BY flag, n ORDER BY n, flag", "t|10|1;NULL|10|1;f|20|2;t|NULL|1");
    try expect(&db, &r, "SELECT n FROM t GROUP BY n HAVING COUNT(*) > 1 ORDER BY n", "10;20");
    try expect(&db, &r, "SELECT n + 1 FROM t GROUP BY n + 1 ORDER BY n + 1 NULLS FIRST", "NULL;11;21");
    try expect(&db, &r, "SELECT COUNT(*) FROM t HAVING COUNT(*) > 10", "");
    try expect(&db, &r, "SELECT k FROM (SELECT n AS k FROM t) s GROUP BY k ORDER BY k", "10;20;NULL");
    try rejects(&db, &r, "SELECT id, COUNT(*) FROM t", error.GroupingError);
    try rejects(&db, &r, "SELECT label FROM t GROUP BY flag", error.GroupingError);
    try rejects(&db, &r, "SELECT id FROM t WHERE COUNT(*) > 1", error.GroupingError);
    try rejects(&db, &r, "SELECT SUM(COUNT(*)) FROM t", error.GroupingError);
    try rejects(&db, &r, "SELECT SUM(label) FROM t", error.UndefinedFunction);
    try rejects(&db, &r, "SELECT SUM('1') FROM t", error.AmbiguousFunction);
    try db.execute("CREATE TABLE e (v BIGINT, d NUMERIC(10,2))", &r);
    try expect(&db, &r, "SELECT COUNT(*), COUNT(v), SUM(v), AVG(v), MIN(v), MAX(d) FROM e", "0|0|NULL|NULL|NULL|NULL");
    try expect(&db, &r, "SELECT v, COUNT(*) FROM e GROUP BY v", "");
    try db.execute("INSERT INTO e VALUES (9223372036854775807, 1.25)", &r);
    try db.execute("INSERT INTO e VALUES (9223372036854775807, 2.50)", &r);
    // SUM(bigint) is numeric: no overflow.
    try expect(&db, &r, "SELECT SUM(v), AVG(d), SUM(d), MIN(d) FROM e", "18446744073709551614|1.8750000000000000|3.75|1.25");
    try check(r.column_types[0] == .numeric);
    try rejects(&db, &r, "SELECT SUM(v::integer) FROM e", error.IntegerOverflow);
}

fn bigGroups() !void {
    try big.execute("CREATE TABLE a (id INTEGER PRIMARY KEY, g INTEGER, v INTEGER)", &big_result);
    try big.execute("CREATE TABLE b (id INTEGER PRIMARY KEY, w INTEGER)", &big_result);
    var statement: [96]u8 = undefined;
    for (0..512) |index| {
        const one = try std.fmt.bufPrint(&statement, "INSERT INTO a VALUES ({d}, 7, {d})", .{ index, index });
        try big.execute(one, &big_result);
        const two = try std.fmt.bufPrint(&statement, "INSERT INTO b VALUES ({d}, {d})", .{ 511 - index, index });
        try big.execute(two, &big_result);
    }
    // One group of 512 rows.
    try big.execute("SELECT g, COUNT(*), SUM(v), MIN(v), MAX(v) FROM a GROUP BY g", &big_result);
    try check(big_result.row_count == 1 and big_result.rows[0].cells[1].integer == 512 and big_result.rows[0].cells[2].integer == 130816);
    try check(big_result.rows[0].cells[3].integer == 0 and big_result.rows[0].cells[4].integer == 511);
    // 512 groups of one row, sorted descending.
    try big.execute("SELECT v, COUNT(*) FROM a GROUP BY v ORDER BY v DESC", &big_result);
    try check(big_result.row_count == 512);
    for (0..512) |index| try check(big_result.rows[index].cells[0].integer == @as(i64, @intCast(511 - index)) and big_result.rows[index].cells[1].integer == 1);
    // 512 x 512 primary-key equi-join (index probe on b.id).
    try big.execute("SELECT a.id, b.w FROM a JOIN b ON b.id = a.id ORDER BY a.id", &big_result);
    try check(big_result.row_count == 512);
    for (0..512) |index| try check(big_result.rows[index].cells[0].integer == @as(i64, @intCast(index)) and big_result.rows[index].cells[1].integer == @as(i64, @intCast(511 - index)));
    try big.execute("SELECT COUNT(*) FROM a LEFT JOIN b ON b.id = a.v + 256", &big_result);
    try check(big_result.rows[0].cells[0].integer == 512);
    try big.execute("SELECT COUNT(b.id) FROM a LEFT JOIN b ON b.id = a.v + 256", &big_result);
    try check(big_result.rows[0].cells[0].integer == 256);
}

// ---- 3.5 joins, subqueries, CTEs, set operations ----------------------------

fn joins() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try db.execute("CREATE TABLE u (id INTEGER PRIMARY KEY, tag TEXT)", &r);
    try db.execute("INSERT INTO u VALUES (1, 'joined')", &r);
    try db.execute("INSERT INTO u VALUES (3, 'three')", &r);
    try db.execute("INSERT INTO u VALUES (9, 'nine')", &r);
    try db.execute("CREATE TABLE w (k INTEGER, id INTEGER)", &r);
    try db.execute("INSERT INTO w VALUES (1, 1)", &r);
    try db.execute("INSERT INTO w VALUES (2, 1)", &r);
    try db.execute("INSERT INTO w VALUES (3, NULL)", &r);
    try expect(&db, &r, "SELECT t.label, u.tag FROM t JOIN u ON t.id = u.id ORDER BY t.id", "one|joined;three|three");
    try names(&r, &.{ "label", "tag" });
    try expect(&db, &r, "SELECT t.id, u.tag FROM t LEFT JOIN u ON u.id = t.id ORDER BY 1", "1|joined;2|NULL;3|three;4|NULL;5|NULL");
    try expect(&db, &r, "SELECT t.id, u.id FROM t RIGHT JOIN u ON u.id = t.id ORDER BY u.id", "1|1;3|3;NULL|9");
    try expect(&db, &r, "SELECT t.id, u.id FROM t FULL JOIN u ON u.id = t.id AND t.id > 1 ORDER BY t.id, u.id", "1|NULL;2|NULL;3|3;4|NULL;5|NULL;NULL|1;NULL|9");
    try expect(&db, &r, "SELECT COUNT(*) FROM t CROSS JOIN u", "15");
    try expect(&db, &r, "SELECT COUNT(*) FROM t, u WHERE t.id < u.id", "7");
    try expect(&db, &r, "SELECT id, tag FROM t JOIN u USING (id) ORDER BY id", "1|joined;3|three");
    try expect(&db, &r, "SELECT * FROM u FULL JOIN w USING (id) ORDER BY id, k", "1|joined|1;1|joined|2;3|three|NULL;9|nine|NULL;NULL|NULL|3");
    try names(&r, &.{ "id", "tag", "k" });
    try expect(&db, &r, "SELECT u.tag, w.k FROM u JOIN w ON w.id = u.id ORDER BY w.k", "joined|1;joined|2");
    try expect(&db, &r, "SELECT a.id, b.id FROM t a JOIN t b ON a.n = b.n AND a.id < b.id ORDER BY a.id", "1|3;2|5");
    try expect(&db, &r, "SELECT t.id, u.tag, w.k FROM t JOIN u ON u.id = t.id LEFT JOIN w ON w.id = u.id ORDER BY t.id, w.k", "1|joined|1;1|joined|2;3|three|NULL");
    try expect(&db, &r, "SELECT t.id FROM t JOIN u ON t.id < u.id AND u.id < 4 ORDER BY t.id", "1;2");
    try rejects(&db, &r, "SELECT id FROM t JOIN u ON t.id = u.id", error.AmbiguousColumn);
    try rejects(&db, &r, "SELECT x.id FROM t JOIN u ON t.id = u.id", error.TableNotFound);
    try rejects(&db, &r, "SELECT t.id FROM t c", error.TableNotFound);
    // Subqueries.
    try expect(&db, &r, "SELECT (SELECT tag FROM u WHERE u.id = t.id) FROM t ORDER BY id", "joined;NULL;three;NULL;NULL");
    try names(&r, &.{"tag"});
    try expect(&db, &r, "SELECT id FROM t WHERE id IN (SELECT id FROM u) ORDER BY id", "1;3");
    try expect(&db, &r, "SELECT id FROM t WHERE id NOT IN (SELECT id FROM w) ORDER BY id", "");
    try expect(&db, &r, "SELECT id FROM t WHERE id NOT IN (SELECT id FROM w WHERE id IS NOT NULL) ORDER BY id", "2;3;4;5");
    try expect(&db, &r, "SELECT id, id IN (SELECT id FROM w), NULL IN (SELECT id FROM u WHERE id > 100) FROM t WHERE id < 3 ORDER BY id", "1|t|f;2|NULL|f");
    try expect(&db, &r, "SELECT id FROM t WHERE EXISTS (SELECT 1 FROM w WHERE w.id = t.id) ORDER BY id", "1");
    try expect(&db, &r, "SELECT id FROM t WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.id = t.id) ORDER BY id", "2;4;5");
    try expect(&db, &r, "SELECT s.x FROM (SELECT id * 2 AS x FROM t WHERE id > 3) s ORDER BY x", "8;10");
    try expect(&db, &r, "SELECT (SELECT MAX(id) FROM u), (SELECT COUNT(*) FROM t WHERE n = 10)", "9|2");
    try rejects(&db, &r, "SELECT (SELECT id FROM u)", error.CardinalityViolation);
    try rejects(&db, &r, "SELECT id FROM t WHERE id IN (SELECT id, tag FROM u)", error.Syntax);
    // CTEs.
    try expect(&db, &r, "WITH s AS (SELECT label FROM t WHERE id = 1) SELECT label FROM s", "one");
    try check(r.command == .select);
    try expect(&db, &r, "WITH a AS (SELECT id FROM t WHERE id > 2), b AS (SELECT id FROM a WHERE id < 5) SELECT b.id FROM b ORDER BY 1", "3;4");
    try expect(&db, &r, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10) SELECT SUM(x), COUNT(*) FROM c", "55|10");
    try expect(&db, &r, "WITH RECURSIVE c(x) AS (SELECT 1 UNION SELECT (x % 3) + 1 FROM c) SELECT x FROM c ORDER BY x", "1;2;3");
    try expect(&db, &r, "WITH x AS (SELECT n FROM t) SELECT COUNT(*) FROM x a JOIN x b ON a.n = b.n", "8");
    // Set operations.
    try expect(&db, &r, "SELECT n FROM t UNION SELECT k FROM w ORDER BY 1", "1;2;3;10;20;NULL");
    try expect(&db, &r, "SELECT n FROM t UNION ALL SELECT n FROM t ORDER BY n LIMIT 3", "10;10;10");
    try expect(&db, &r, "SELECT n FROM t INTERSECT SELECT 10 ORDER BY 1", "10");
    try expect(&db, &r, "SELECT n FROM t INTERSECT ALL SELECT n FROM t WHERE id > 2 ORDER BY 1", "10;20;NULL");
    try expect(&db, &r, "SELECT n FROM t EXCEPT SELECT 20 ORDER BY 1", "10;NULL");
    try expect(&db, &r, "SELECT n FROM t EXCEPT ALL SELECT n FROM t WHERE id < 3 ORDER BY 1", "10;20;NULL");
    try expect(&db, &r, "SELECT 'a' UNION SELECT 'b' ORDER BY 1", "a;b");
    try check(r.column_types[0] == .text);
    try expect(&db, &r, "SELECT 1 UNION SELECT 2::bigint ORDER BY 1 DESC", "2;1");
    try check(r.column_types[0] == .integer);
    try rejects(&db, &r, "SELECT 1 UNION SELECT 1, 2", error.Syntax);
    try rejects(&db, &r, "SELECT 1 UNION SELECT TRUE", error.TypeMismatch);
    try rejects(&db, &r, "SELECT n FROM t UNION SELECT k FROM w ORDER BY n + 1", error.UnsupportedStatement);
}

fn transactions() !void {
    var db: DB = .{};
    var r: DB.Result = .{};
    try base(&db, &r);
    try db.execute("CREATE TABLE u (id INTEGER PRIMARY KEY, tag TEXT)", &r);
    // A join inside a transaction sees the transaction's own uncommitted rows.
    const slot = try db.begin();
    try db.statement(slot, "INSERT INTO u VALUES (2, 'mine')", &r, .{});
    try db.statement(slot, "SELECT t.id, u.tag FROM t JOIN u ON u.id = t.id", &r, .{});
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 2);
    try db.execute("SELECT COUNT(*) FROM t JOIN u ON u.id = t.id", &r);
    try check(r.rows[0].cells[0].integer == 0);
    db.publishCommit(slot);
    try db.execute("SELECT COUNT(*) FROM t JOIN u ON u.id = t.id", &r);
    try check(r.rows[0].cells[0].integer == 1);
}

fn capacity() !void {
    var db: Tiny = .{};
    var r: Tiny.Result = .{};
    try db.execute("CREATE TABLE a (id INTEGER PRIMARY KEY, v INTEGER)", &r);
    var statement: [64]u8 = undefined;
    for (0..20) |index| try db.execute(try std.fmt.bufPrint(&statement, "INSERT INTO a VALUES ({d}, {d})", .{ index, index % 3 }), &r);
    try db.execute("SELECT id FROM a WHERE id = 1", &r);
    try check(r.row_count == 1);
    // 20 x 20 cross join needs more than 8 workspace rows: 54000, result kept.
    try rejects(&db, &r, "SELECT COUNT(*) FROM a x, a y", error.WorkspaceCapacity);
    try rejects(&db, &r, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c", error.WorkspaceCapacity);
    try check(r.row_count == 1 and r.rows[0].cells[0].integer == 1);
    try db.execute("SELECT DISTINCT v FROM a ORDER BY v", &r);
    try check(r.row_count == 3);
}

fn projectionOwnership() !void {
    var db:DB=.{};var r:DB.Result=.{};
    const text="abcdefghijklmnopqrstuvwxyz012345";
    try db.execute("CREATE TABLE p (id INTEGER PRIMARY KEY, tag TEXT, amount NUMERIC)",&r);
    try db.execute("INSERT INTO p VALUES (1,'abcdefghijklmnopqrstuvwxyz012345',1.25),(2,NULL,NULL)",&r);
    // Both materialized inputs and outputs share the caller's arena. Repeated
    // borrowed columns must copy before the next expression can reuse scratch.
    @memset(&db.workspace.query.cells,.{.integer=0x55555555});
    try db.execute("WITH src AS (SELECT id,tag,amount FROM p) SELECT tag,tag,amount,amount+1,id+10,NULL FROM src ORDER BY 5",&r);
    try check(r.row_count==2 and r.column_count==6);
    for(0..2) |column| try check(std.mem.eql(u8,r.rows[0].cells[column].text.slice(),text));
    try check(r.rows[0].cells[2].numeric.coef()==125 and r.rows[0].cells[2].numeric.dscale==2);
    try check(r.rows[0].cells[3].numeric.coef()==225 and r.rows[0].cells[3].numeric.dscale==2);
    try check(r.rows[0].cells[4].integer==11 and r.rows[0].cells[5]==.null_value);
    for(0..4) |column| try check(r.rows[1].cells[column]==.null_value);
    try check(r.rows[1].cells[4].integer==12 and r.rows[1].cells[5]==.null_value);
    // Result ownership survives poisoning/reuse of every temporary input.
    @memset(&db.workspace.query.cells,.{.integer=0x66666666});
    try check(std.mem.eql(u8,r.rows[0].cells[0].text.slice(),text));
    try check(r.rows[0].cells[3].numeric.coef()==225);
    try rejects(&db,&r,"SELECT tag,amount,1/(id-id) FROM p",error.DivisionByZero);
    try check(std.mem.eql(u8,r.rows[0].cells[1].text.slice(),text));
    try expect(&db,&r,"SELECT id+10,id,id+20,id,id+30,id FROM p ORDER BY 1","11|1|21|1|31|1;12|2|22|2|32|2");
}

pub fn main(init: std.process.Init) !void {
    try sortContract();
    try topKContract();
    try ordering();
    try aggregates();
    try bigGroups();
    try joins();
    try transactions();
    try capacity();
    try projectionOwnership();
    var buffer: [200]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-query\",\"pass\":true,\"assertions\":{d},\"database_bytes\":{d},\"big_bytes\":{d},\"work_rows\":{d}}}\n", .{ assertions, DB.storageBytes(), Big.storageBytes(), Big.work_rows });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
