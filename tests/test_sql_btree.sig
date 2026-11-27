//! Ordered (btree) secondary indexes (B11 wave 5, btree lane).
//!
//! CREATE INDEX defaults to btree; USING hash keeps the hash entries. A
//! btree index is a bounded B+tree of row-version references in the
//! index's storage run (inline or bound in the external region). These
//! checks prove:
//! - results are identical with and without the index: every query runs on
//!   a database with the indexes and on one without, and must render the
//!   same rows in the same order (randomized over every operator, with
//!   concurrent writers, rollbacks, savepoints and reclamation);
//! - the planner uses the index (EXPLAIN shapes, read statistics) for
//!   equality prefixes, ranges, BETWEEN, IN lists, IS [NOT] NULL, ORDER BY
//!   (ASC / DESC, NULLS FIRST / LAST) with LIMIT, min / max, partial
//!   indexes whose predicate the WHERE implies, INCLUDE (index-only
//!   shapes) and the inner side of nested-loop joins;
//! - UNIQUE through the btree with dirty-snapshot waits;
//! - USING hash (PostgreSQL 18's 0A000 restrictions, pg_am, relam,
//!   indexdef), checked against native PostgreSQL 18.7;
//! - replay rebuilds every tree (replica answers like the primary) and the
//!   hash flag round-trips; crafted flags are InvalidChangeRecord;
//! - capacity: node arena (index_entries), depth (index_depth) and entry
//!   bytes (index_key_bytes) are 54000 with nothing changed;
//! - after every change each tree is structurally valid.
//! A 120k-row external database measures probe and range costs against a
//! full scan (printed; entry counts asserted).
const std = @import("std");
const sql = @import("sql");

fn profile(comptime fanout: usize) sql.Config {
    return .{ .tables = 6, .columns = 6, .rows_per_table = 160, .versions_per_table = 640, .name_bytes = 32, .text_bytes = 128, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 6, .expr_nodes = 1024, .predicates = 16, .index_fanout = fanout, .result_rows = 192, .work_rows = 384, .tx_writes = 512 };
}

/// Fanout 8: trees of depth 4 and more at a few hundred versions, so splits,
/// borrows and merges run constantly.
const DB = sql.Database(profile(8));

var assertions: usize = 0;
var statements: usize = 0;
var with: DB = .{};
var without: DB = .{};
var replica: DB = .{};
var replay_scratch: DB.ReplayScratch = .{};
var record: [1 << 18]u8 = undefined;
var text_buffer: [1 << 16]u8 = undefined;
var saved_buffer: [1 << 16]u8 = undefined;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) {
        std.debug.print("btree contract failed at assertion {d}\n", .{assertions});
        return error.BtreeContractFailed;
    }
}

fn render(comptime T: type, result: *const T.Result, out: []u8) ![]const u8 {
    var at: usize = 0;
    var cell_buffer: [T.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |row| {
        if (row != 0) {
            out[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                out[at] = '|';
                at += 1;
            }
            const cell = &result.rows[row].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try T.Io.format(cell, false, T.Result.default_session, &cell_buffer);
            if (at + text.len + 2 > out.len) return error.RenderCapacity;
            @memcpy(out[at..][0..text.len], text);
            at += text.len;
        }
    }
    return out[0..at];
}

fn same(got: []const u8, wanted: []const u8) !void {
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("  got  {s}\n  want {s}\n", .{ got, wanted });
    try check(std.mem.eql(u8, got, wanted));
}

fn query(target: anytype, source: []const u8, out: []u8) ![]const u8 {
    const T = @TypeOf(target.*);
    var result: T.Result = .{};
    statements += 1;
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(T, &result, out);
}

fn expect(target: anytype, source: []const u8, wanted: []const u8) !void {
    try same(try query(target, source, &text_buffer), wanted);
}

/// Runs a statement on the indexed primary (logging it into the replica)
/// and on the database without indexes.
fn both(source: []const u8) !void {
    try primary(source);
    try plain(source);
}

fn primary(source: []const u8) !void {
    var result: DB.Result = .{};
    var used: usize = 0;
    statements += 1;
    with.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) try replica.applyChangeRecord(record[0..used], &replay_scratch);
}

fn plain(source: []const u8) !void {
    var result: DB.Result = .{};
    statements += 1;
    without.execute(source, &result) catch |err| {
        std.debug.print("(plain) {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// The same rows, in the same order, with and without the indexes.
fn agree(source: []const u8) !void {
    const left = try query(&with, source, &text_buffer);
    @memcpy(saved_buffer[0..left.len], left);
    const right = try query(&without, source, &text_buffer);
    if (!std.mem.eql(u8, saved_buffer[0..left.len], right)) std.debug.print("index path differs: {s}\n  with    {s}\n  without {s}\n", .{ source, saved_buffer[0..left.len], right });
    try check(std.mem.eql(u8, saved_buffer[0..left.len], right));
}

/// The same answer on the replica as on the primary.
fn replicated(source: []const u8) !void {
    const left = try query(&with, source, &text_buffer);
    @memcpy(saved_buffer[0..left.len], left);
    const right = try query(&replica, source, &text_buffer);
    if (!std.mem.eql(u8, saved_buffer[0..left.len], right)) std.debug.print("replica differs: {s}\n  primary {s}\n  replica {s}\n", .{ source, saved_buffer[0..left.len], right });
    try check(std.mem.eql(u8, saved_buffer[0..left.len], right));
}

fn rejects(target: anytype, source: []const u8, wanted: anyerror) !void {
    const T = @TypeOf(target.*);
    var result: T.Result = .{};
    statements += 1;
    if (target.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidStatementAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn valid(target: anytype, table: []const u8) !void {
    try check(target.indexTreesValid(table).?);
    try check(target.indexConsistent(table).?);
}

/// EXPLAIN (FORMAT JSON [, ANALYZE]) top node.
fn explains(target: anytype, source: []const u8, node: []const u8) !void {
    var wanted: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&wanted, "[{{\"Plan\":{{\"Node Type\":\"{s}\"}}}}]", .{node});
    var statement_text: [512]u8 = undefined;
    const explain = try std.fmt.bufPrint(&statement_text, "EXPLAIN (FORMAT JSON) {s}", .{source});
    try expect(target, explain, text);
}

fn indexScans(target: anytype) usize {
    return target.workspace.query.read_stats.index_scans;
}

// ---- access methods ----------------------------------------------------------

fn accessMethods() !void {
    try both("CREATE TABLE am (id INT PRIMARY KEY, a INT, b INT, c TEXT)");
    // Checked against native PostgreSQL 18.7 (DefineIndex order).
    try rejects(&with, "CREATE UNIQUE INDEX am_u ON am USING hash (a)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_i ON am USING hash (a) INCLUDE (b)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_m ON am USING hash (a, b)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_d ON am USING hash (a DESC)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_n ON am USING hash (a NULLS FIRST)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_g ON am USING gist (a)", error.UnsupportedStatement);
    try rejects(&with, "CREATE INDEX am_f ON am USING foo (a)", error.UndefinedObject);
    try primary("CREATE INDEX am_h ON am USING hash (a)");
    try primary("CREATE INDEX am_b ON am (a)");
    try primary("CREATE INDEX am_e ON am USING btree (b DESC NULLS LAST, c)");
    const listing = "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'am' ORDER BY indexname";
    try expect(&with, listing, "am_b|CREATE INDEX am_b ON public.am USING btree (a);" ++
        "am_e|CREATE INDEX am_e ON public.am USING btree (b DESC NULLS LAST, c);" ++
        "am_h|CREATE INDEX am_h ON public.am USING hash (a);" ++
        "am_pkey|CREATE UNIQUE INDEX am_pkey ON public.am USING btree (id)");
    try expect(&with, "SELECT c.relname, a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.relname LIKE 'am%' ORDER BY 1", "am|heap;am_b|btree;am_e|btree;am_h|hash;am_pkey|btree");
    try expect(&with, "SELECT oid, amname, amhandler, amtype FROM pg_am WHERE amtype = 'i' ORDER BY oid", "403|btree|bthandler|i;405|hash|hashhandler|i");
    try replicated(listing);
    try replicated("SELECT c.relname, a.amname FROM pg_class c JOIN pg_am a ON a.oid = c.relam WHERE c.relname LIKE 'am%' ORDER BY 1");
    try both("INSERT INTO am VALUES (1, 5, 1, 'x'), (2, 5, 2, 'y'), (3, NULL, 3, NULL), (4, 7, NULL, 'z')");
    try agree("SELECT id FROM am WHERE a = 5");
    try agree("SELECT id, b FROM am WHERE b < 3 ORDER BY b DESC");
    try valid(&with, "am");
    try valid(&replica, "am");
    try both("DROP TABLE am");
}

// ---- randomized equivalence --------------------------------------------------

var seed: u64 = 0x9e3779b97f4a7c15;

fn next() u64 {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return seed;
}

fn below(n: u64) u64 {
    return next() % n;
}

const words = [_][]const u8{ "", "a", "ab", "abc", "b", "Z", "z", "zz", "\xc3\xa9", "\xc3\xa9t\xc3\xa9", "\xe4\xb8\xad", "a\xe4\xb8\xad", "mm", "m", "aaaaaaaaab", "aaaaaaaaaa" };

fn literalA(buffer: []u8) ![]const u8 {
    return switch (below(8)) {
        0 => "NULL",
        else => std.fmt.bufPrint(buffer, "{d}", .{@as(i64, @intCast(below(25))) - 12}),
    };
}

fn literalT(buffer: []u8) ![]const u8 {
    if (below(9) == 0) return "NULL";
    return std.fmt.bufPrint(buffer, "'{s}'", .{words[below(words.len)]});
}

var next_id: usize = 1;

fn randomWrite(target_slot: ?[2]u16) !void {
    var text: [256]u8 = undefined;
    var a: [24]u8 = undefined;
    var a2: [24]u8 = undefined;
    var t: [40]u8 = undefined;
    const source = switch (below(10)) {
        0...3 => blk: {
            next_id += 1;
            break :blk try std.fmt.bufPrint(&text, "INSERT INTO r VALUES ({d}, {s}, {d}, {s}, {s})", .{ next_id, try literalA(&a), below(6), try literalT(&t), try literalA(&a2) });
        },
        4...6 => try std.fmt.bufPrint(&text, "UPDATE r SET a = {s}, t = {s} WHERE id % 7 = {d}", .{ try literalA(&a), try literalT(&t), below(7) }),
        7 => try std.fmt.bufPrint(&text, "UPDATE r SET b = (b + 1) % 6 WHERE a > {d}", .{@as(i64, @intCast(below(25))) - 12}),
        else => try std.fmt.bufPrint(&text, "DELETE FROM r WHERE id % 11 = {d}", .{below(11)}),
    };
    if (target_slot) |slots| {
        var result: DB.Result = .{};
        statements += 2;
        try with.statement(slots[0], source, &result, .{});
        try without.statement(slots[1], source, &result, .{});
    } else try both(source);
}

const orders = [_][]const u8{ "a", "a DESC", "a NULLS FIRST", "a DESC NULLS LAST", "t", "t DESC", "b, a DESC NULLS FIRST", "b DESC, a NULLS LAST", "a, t", "a DESC, t DESC" };

fn randomQuery(buffer: []u8) ![]const u8 {
    var x: [24]u8 = undefined;
    var y: [24]u8 = undefined;
    var z: [40]u8 = undefined;
    const ops = [_][]const u8{ "=", "<", "<=", ">", ">=", "<>" };
    const where: []const u8 = switch (below(14)) {
        0 => try std.fmt.bufPrint(&z, "a {s} {s}", .{ ops[below(ops.len)], try literalA(&x) }),
        1 => try std.fmt.bufPrint(&z, "{s} {s} a", .{ try literalA(&x), ops[below(ops.len)] }),
        2 => try std.fmt.bufPrint(&z, "a BETWEEN {s} AND {s}", .{ try literalA(&x), try literalA(&y) }),
        3 => try std.fmt.bufPrint(&z, "a IN ({s}, {s}, {d})", .{ try literalA(&x), try literalA(&y), below(5) }),
        4 => if (below(2) == 0) "a IS NULL" else "a IS NOT NULL",
        5 => try std.fmt.bufPrint(&z, "b = {d} AND a {s} {s}", .{ below(6), ops[below(5)], try literalA(&x) }),
        6 => try std.fmt.bufPrint(&z, "b = {d} AND a IS NULL", .{below(6)}),
        7 => try std.fmt.bufPrint(&z, "t {s} {s}", .{ ops[below(ops.len)], try literalT(&x) }),
        8 => try std.fmt.bufPrint(&z, "t BETWEEN {s} AND {s}", .{ try literalT(&x), try literalT(&y) }),
        9 => try std.fmt.bufPrint(&z, "a = {s} AND t > {s}", .{ try literalA(&x), try literalT(&y) }),
        10 => try std.fmt.bufPrint(&z, "c >= {s} AND a < {s}", .{ try literalA(&x), try literalA(&y) }),
        11 => try std.fmt.bufPrint(&z, "b IN ({d}, {d}) AND a >= {s}", .{ below(6), below(6), try literalA(&x) }),
        12 => try std.fmt.bufPrint(&z, "a > {s} AND a < {s} AND b > 1", .{ try literalA(&x), try literalA(&y) }),
        else => "TRUE",
    };
    const columns = if (below(3) == 0) "a, b" else "id, a, b, t, c";
    return switch (below(4)) {
        0 => std.fmt.bufPrint(buffer, "SELECT {s} FROM r WHERE {s}", .{ columns, where }),
        1 => std.fmt.bufPrint(buffer, "SELECT {s} FROM r WHERE {s} ORDER BY {s}", .{ columns, where, orders[below(orders.len)] }),
        2 => std.fmt.bufPrint(buffer, "SELECT {s} FROM r WHERE {s} ORDER BY {s} LIMIT {d}", .{ columns, where, orders[below(orders.len)], below(9) }),
        else => std.fmt.bufPrint(buffer, "SELECT {s} FROM r WHERE {s} LIMIT {d}", .{ columns, where, below(12) }),
    };
}

fn randomized() !void {
    try both("CREATE TABLE r (id INT PRIMARY KEY, a INT, b INT, t TEXT, c INT)");
    try primary("CREATE INDEX r_a ON r (a)");
    try primary("CREATE INDEX r_ba ON r (b, a DESC NULLS FIRST)");
    try primary("CREATE INDEX r_t ON r (t DESC) INCLUDE (a)");
    try primary("CREATE INDEX r_at ON r (a NULLS FIRST, t)");
    for (0..60) |_| try randomWrite(null);
    var text: [512]u8 = undefined;
    var scans_before = indexScans(&with);
    var used_index: usize = 0;
    for (0..1500) |round| {
        if (round % 5 == 0) {
            try randomWrite(null);
            try valid(&with, "r");
        }
        const source = try randomQuery(&text);
        const before = with.workspace.query.read_stats.index_scans;
        try agree(source);
        if (with.workspace.query.read_stats.index_scans != before or indexScans(&with) != scans_before) used_index += 1;
        scans_before = indexScans(&with);
        if (round % 50 == 0) {
            _ = with.vacuum();
            _ = without.vacuum();
            try valid(&with, "r");
        }
    }
    // Most generated predicates narrow by an index.
    try check(used_index > 500);
    try valid(&replica, "r");
    try replicated("SELECT id, a, b, t, c FROM r ORDER BY id");
}

/// Writers in open transactions: other snapshots see neither their versions
/// nor their deletions; rollback and ROLLBACK TO SAVEPOINT leave no entry.
fn concurrent() !void {
    var text: [512]u8 = undefined;
    for (0..40) |round| {
        const w1 = try with.begin();
        const w2 = try without.begin();
        try with.savepoint(w1, "s");
        try without.savepoint(w2, "s");
        for (0..4) |_| try randomWrite(.{ w1, w2 });
        if (round % 3 == 0) {
            _ = try with.rollbackTo(w1, "s");
            _ = try without.rollbackTo(w2, "s");
            try valid(&with, "r");
            for (0..2) |_| try randomWrite(.{ w1, w2 });
        }
        // Readers outside the writer.
        for (0..12) |_| try agree(try randomQuery(&text));
        // The writer reads its own writes through the index.
        for (0..6) |_| {
            const source = try randomQuery(&text);
            var left_result: DB.Result = .{};
            var right_result: DB.Result = .{};
            statements += 2;
            try with.statement(w1, source, &left_result, .{});
            try without.statement(w2, source, &right_result, .{});
            const left = try render(DB, &left_result, &text_buffer);
            @memcpy(saved_buffer[0..left.len], left);
            const right = try render(DB, &right_result, &text_buffer);
            if (!std.mem.eql(u8, saved_buffer[0..left.len], right)) std.debug.print("in-transaction differs: {s}\n  with    {s}\n  without {s}\n", .{ source, saved_buffer[0..left.len], right });
            try check(std.mem.eql(u8, saved_buffer[0..left.len], right));
        }
        if (round % 2 == 0) {
            with.abort(w1);
            without.abort(w2);
        } else {
            const payload = try with.prepareCommit(w1, &record);
            if (!with.readOnly(w1)) try replica.applyChangeRecord(payload, &replay_scratch);
            with.publishCommit(w1);
            _ = try without.prepareCommit(w2, &record);
            without.publishCommit(w2);
        }
        try valid(&with, "r");
        for (0..6) |_| try agree(try randomQuery(&text));
    }
    try replicated("SELECT id, a, b, t, c FROM r ORDER BY id");
    try valid(&replica, "r");
}

// ---- planner shapes --------------------------------------------------------

fn shapes() !void {
    try both("CREATE TABLE s (id INT PRIMARY KEY, a INT, b INT, t TEXT)");
    try both("INSERT INTO s SELECT g, g % 10, g % 3, 'k' || (g % 7) FROM generate_series(1, 150) g");
    try primary("CREATE INDEX s_a ON s (a)");
    try primary("CREATE INDEX s_bt ON s (b, t) INCLUDE (a)");
    try primary("CREATE UNIQUE INDEX s_u ON s (id, a)");
    try primary("CREATE INDEX s_p ON s (a) WHERE b > 1");
    // A selective equality without ORDER BY: rows come back in heap order.
    try explains(&with, "SELECT id FROM s WHERE a = 3", "Bitmap Heap Scan");
    try explains(&with, "SELECT id FROM s WHERE a BETWEEN 2 AND 4", "Bitmap Heap Scan");
    try explains(&with, "SELECT id FROM s WHERE a IN (1, 2)", "Bitmap Heap Scan");
    try explains(&with, "SELECT a FROM s WHERE a = 3", "Index Only Scan");
    try explains(&with, "SELECT b, t, a FROM s WHERE b = 1 AND t >= 'k3'", "Index Only Scan");
    try explains(&with, "SELECT id FROM s WHERE a = 3 ORDER BY id", "Sort");
    try explains(&with, "SELECT id FROM s ORDER BY a LIMIT 3", "Limit");
    try explains(&with, "SELECT id, a FROM s WHERE b = 2 ORDER BY t", "Index Scan");
    try explains(&with, "SELECT id FROM s WHERE id = 4 AND a = 4", "Select Plan");
    try explains(&with, "SELECT id FROM s WHERE t = 'k1'", "Select Plan");
    try explains(&with, "SELECT id FROM s WHERE b = 2", "Bitmap Heap Scan");
    try explains(&with, "SELECT id FROM s WHERE a + 0 = 3", "Select Plan");
    try explains(&with, "SELECT id FROM s ORDER BY a", "Select Plan");
    try expect(&with, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM s ORDER BY a DESC LIMIT 4", "[{\"Plan\":{\"Node Type\":\"Limit\",\"Actual Rows\":4,\"Actual Loops\":1}}]");
    try expect(&with, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id, b FROM s WHERE b = 2 ORDER BY t DESC", "[{\"Plan\":{\"Node Type\":\"Index Scan\",\"Actual Rows\":50,\"Actual Loops\":1}}]");
    try expect(&with, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM s WHERE a = 7", "[{\"Plan\":{\"Node Type\":\"Bitmap Heap Scan\",\"Actual Rows\":15,\"Actual Loops\":1}}]");
    // ORDER BY ... LIMIT stops after LIMIT rows: index entries read stay small.
    const before = with.workspace.query.read_stats.index_entries;
    try agree("SELECT id, a FROM s ORDER BY a DESC LIMIT 3");
    try check(with.workspace.query.read_stats.index_entries - before <= 32);
    for ([_][]const u8{ "SELECT id FROM s WHERE a = 3", "SELECT id FROM s WHERE a BETWEEN 2 AND 4 ORDER BY a, id", "SELECT b, t, a FROM s WHERE b = 1 AND t >= 'k3'", "SELECT id, a FROM s WHERE b = 2 ORDER BY t", "SELECT id, a FROM s ORDER BY a DESC LIMIT 7", "SELECT id, a, t FROM s ORDER BY a NULLS FIRST LIMIT 12" }) |source| try agree(source);
    try valid(&with, "s");
    try both("DROP TABLE s");
    // Partial and expression indexes. Entries cover every row, so the
    // planner may use a partial index only when the WHERE implies its
    // predicate (PostgreSQL predicate_implied_by: equal conjuncts, IS NOT
    // NULL by a strict comparison, narrower integer comparisons).
    try both("CREATE TABLE q (id INT PRIMARY KEY, a INT, b INT, t TEXT)");
    try both("INSERT INTO q SELECT g, g % 10, g % 4, CASE WHEN g % 9 = 0 THEN NULL ELSE 'T' || (g % 5) END FROM generate_series(1, 120) g");
    try primary("CREATE INDEX q_p ON q (a) WHERE b > 1");
    try primary("CREATE INDEX q_n ON q (b) WHERE t IS NOT NULL");
    try primary("CREATE INDEX q_x ON q (lower(t))");
    try primary("CREATE INDEX q_e ON q (id, (a + 1))");
    for ([_][2][]const u8{
        .{ "SELECT id FROM q WHERE a = 3 AND b > 1", "Bitmap Heap Scan" },
        .{ "SELECT id FROM q WHERE a = 3 AND b = 2", "Bitmap Heap Scan" },
        .{ "SELECT id FROM q WHERE a = 3 AND b >= 3", "Bitmap Heap Scan" },
        .{ "SELECT id FROM q WHERE a = 3 AND b > 0", "Select Plan" },
        .{ "SELECT id FROM q WHERE a = 3 AND b = 1", "Select Plan" },
        .{ "SELECT id FROM q WHERE a = 3", "Select Plan" },
        .{ "SELECT id FROM q WHERE b = 2 AND t = 'T1'", "Bitmap Heap Scan" },
        .{ "SELECT id FROM q WHERE b = 2 AND t > 'T'", "Bitmap Heap Scan" },
        .{ "SELECT id FROM q WHERE b = 2", "Select Plan" },
        // Expression elements are outside the tree order: no lookup on them.
        .{ "SELECT id FROM q WHERE lower(t) = 't1'", "Select Plan" },
        .{ "SELECT id FROM q WHERE id > 100 AND a + 1 = 3", "Bitmap Heap Scan" },
    }) |case| {
        try explains(&with, case[0], case[1]);
        try agree(case[0]);
    }
    try valid(&with, "q");
    try both("DROP TABLE q");
}

// ---- min / max and joins ---------------------------------------------------

fn streamProbes(target: anytype) usize {
    return target.workspace.query.stream_stats.index_probes;
}

fn minMax() !void {
    const cases = [_][]const u8{
        "SELECT min(a), max(a) FROM r",
        "SELECT max(t), min(t) FROM r",
        "SELECT min(b), max(b) FROM r",
        "SELECT max(a) FROM r HAVING max(a) > 3",
        "SELECT max(a) FROM r HAVING max(a) > 300",
        "SELECT min(a) + 1, max(t) || '!' FROM r",
    };
    for (cases) |source| {
        try agree(source);
        try check(streamProbes(&with) != 0);
    }
    // Not served: no index on c, a WHERE, DISTINCT, FILTER.
    for ([_][]const u8{ "SELECT min(c) FROM r", "SELECT min(a) FROM r WHERE b = 1", "SELECT max(DISTINCT a) FROM r", "SELECT max(a) FILTER (WHERE b > 2) FROM r" }) |source| {
        try agree(source);
        try check(streamProbes(&with) == 0);
    }
    // An open deleter: other snapshots keep the old extreme, the deleter
    // sees the next one.
    const w1 = try with.begin();
    const w2 = try without.begin();
    var result: DB.Result = .{};
    try with.statement(w1, "DELETE FROM r WHERE a >= 9 OR t >= 'z'", &result, .{});
    try without.statement(w2, "DELETE FROM r WHERE a >= 9 OR t >= 'z'", &result, .{});
    for (cases[0..3]) |source| try agree(source);
    var left_result: DB.Result = .{};
    var right_result: DB.Result = .{};
    try with.statement(w1, cases[0], &left_result, .{});
    try without.statement(w2, cases[0], &right_result, .{});
    const left = try render(DB, &left_result, &text_buffer);
    @memcpy(saved_buffer[0..left.len], left);
    try same(try render(DB, &right_result, &text_buffer), saved_buffer[0..left.len]);
    with.abort(w1);
    without.abort(w2);
    try both("CREATE TABLE e (id INT PRIMARY KEY, a INT)");
    try primary("CREATE INDEX e_a ON e (a DESC)");
    try agree("SELECT min(a), max(a) FROM e");
    try both("INSERT INTO e VALUES (1, NULL), (2, NULL)");
    try agree("SELECT min(a), max(a) FROM e");
    try both("INSERT INTO e VALUES (3, 4), (4, -2), (5, NULL)");
    try agree("SELECT min(a), max(a), count(*) FROM e");
    try agree("SELECT min(a), max(a) FROM e");
    try both("DROP TABLE e");
}

fn joins() !void {
    try both("CREATE TABLE p (id INT PRIMARY KEY, k INT, v TEXT)");
    try both("CREATE TABLE c (id INT PRIMARY KEY, pk INT, w INT)");
    try both("INSERT INTO p SELECT g, g % 13, 'v' || g FROM generate_series(1, 60) g");
    try both("INSERT INTO c SELECT g, (g * 7) % 70, g % 5 FROM generate_series(1, 140) g");
    try both("INSERT INTO c VALUES (500, NULL, 1), (501, 3, NULL)");
    try primary("CREATE INDEX c_pk ON c (pk)");
    try primary("CREATE INDEX p_k ON p (k DESC)");
    const cases = [_][]const u8{
        "SELECT p.id, c.id, c.w FROM p JOIN c ON c.pk = p.id ORDER BY p.id, c.id",
        "SELECT p.id, c.id FROM p JOIN c ON c.pk = p.id",
        "SELECT p.id, c.id FROM p LEFT JOIN c ON c.pk = p.id AND c.w > 1",
        "SELECT c.id, p.id FROM c JOIN p ON p.k = c.w WHERE c.id < 25",
        "SELECT c.id, p.v FROM c LEFT JOIN p ON p.k = c.pk WHERE c.w < 3 AND c.id < 70",
        "SELECT p.id, c.id, d.id FROM p JOIN c ON c.pk = p.id JOIN c d ON d.pk = c.w WHERE p.id < 20",
        "SELECT p.id, count(c.id) FROM p LEFT JOIN c ON c.pk = p.id GROUP BY p.id ORDER BY 2 DESC, 1",
    };
    for (cases) |source| {
        try agree(source);
        try check(streamProbes(&with) != 0);
    }
    // A probe column that is not an index's first element scans.
    try agree("SELECT p.id, c.id FROM p JOIN c ON c.w = p.id");
    try check(streamProbes(&with) == 0);
    try both("UPDATE c SET pk = pk + 1 WHERE id % 3 = 0");
    try both("DELETE FROM p WHERE id % 4 = 1");
    for (cases) |source| try agree(source);
    try valid(&with, "c");
    try valid(&with, "p");
    try both("DROP TABLE c");
    try both("DROP TABLE p");
}

// ---- UNIQUE through the btree ----------------------------------------------

fn parks(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    if (with.statement(slot, source, &result, .{})) |_| return error.InvalidStatementAccepted else |err| try check(err == error.WouldBlock);
    try check(with.parked(slot));
}

fn resumed(slot: u16, source: []const u8) ?anyerror {
    var result: DB.Result = .{};
    with.statement(slot, source, &result, .{ .@"resume" = true }) catch |err| return err;
    return null;
}

fn statementOn(slot: u16, source: []const u8) !void {
    var result: DB.Result = .{};
    try with.statement(slot, source, &result, .{});
}

fn commitOn(slot: u16) !void {
    if (!with.readOnly(slot)) {
        const payload = try with.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &replay_scratch);
    }
    with.publishCommit(slot);
}

fn uniqueness() !void {
    try primary("CREATE TABLE u (id INT PRIMARY KEY, k INT, n TEXT)");
    try primary("INSERT INTO u VALUES (1, 1, 'a'), (2, 2, 'b'), (3, 3, NULL), (4, 3, NULL)");
    // Existing duplicates: 23505 and no index.
    try rejects(&with, "CREATE UNIQUE INDEX u_k ON u (k)", error.PrimaryKeyViolation);
    try expect(&with, "SELECT count(*) FROM pg_indexes WHERE tablename = 'u'", "1");
    try primary("DELETE FROM u WHERE id = 4");
    try primary("CREATE UNIQUE INDEX u_k ON u (k)");
    try primary("CREATE UNIQUE INDEX u_n ON u (n) NULLS NOT DISTINCT");
    try rejects(&with, "INSERT INTO u VALUES (5, 2, 'x')", error.PrimaryKeyViolation);
    try rejects(&with, "UPDATE u SET k = 1 WHERE id = 3", error.PrimaryKeyViolation);
    try rejects(&with, "INSERT INTO u VALUES (5, 5, NULL)", error.PrimaryKeyViolation);
    try rejects(&with, "INSERT INTO u VALUES (5, 5, 'e'), (6, 5, 'f')", error.PrimaryKeyViolation);
    try expect(&with, "SELECT id, k, n FROM u ORDER BY id", "1|1|a;2|2|b;3|3|NULL");
    try primary("INSERT INTO u VALUES (5, NULL, 'e'), (6, NULL, 'f')");
    try primary("UPDATE u SET k = 4 WHERE id = 3");
    try primary("UPDATE u SET k = 3 WHERE id = 3");
    // A concurrent inserter of the same key waits (dirty snapshot), then
    // fails after the first commits or inserts after it aborts.
    const first = try with.begin();
    const second = try with.begin();
    try statementOn(first, "INSERT INTO u VALUES (10, 10, 'j')");
    try parks(second, "INSERT INTO u VALUES (11, 10, 'k')");
    try commitOn(first);
    const outcome = resumed(second, "INSERT INTO u VALUES (11, 10, 'k')");
    try check(outcome != null and outcome.? == error.PrimaryKeyViolation);
    with.abort(second);
    const third = try with.begin();
    const fourth = try with.begin();
    try statementOn(third, "INSERT INTO u VALUES (12, 12, 'l')");
    try parks(fourth, "INSERT INTO u VALUES (13, 12, 'm')");
    with.abort(third);
    try check(resumed(fourth, "INSERT INTO u VALUES (13, 12, 'm')") == null);
    try commitOn(fourth);
    // An uncommitted delete of the key: the inserter waits for it.
    const deleter = try with.begin();
    const inserter = try with.begin();
    try statementOn(deleter, "DELETE FROM u WHERE k = 2");
    try parks(inserter, "INSERT INTO u VALUES (14, 2, 'n')");
    try commitOn(deleter);
    try check(resumed(inserter, "INSERT INTO u VALUES (14, 2, 'n')") == null);
    try commitOn(inserter);
    // ON CONFLICT arbitrates through the unique btree.
    try primary("INSERT INTO u VALUES (15, 3, 'o') ON CONFLICT (k) DO UPDATE SET n = 'conflict'");
    try primary("INSERT INTO u VALUES (16, 16, 'p') ON CONFLICT (k) DO NOTHING");
    const rows = "SELECT id, k, n FROM u ORDER BY id";
    try expect(&with, rows, "1|1|a;3|3|conflict;5|NULL|e;6|NULL|f;10|10|j;13|12|m;14|2|n;16|16|p");
    try replicated(rows);
    try valid(&with, "u");
    try valid(&replica, "u");
    try explains(&with, "SELECT id FROM u WHERE k = 12", "Index Scan");
    try primary("DROP TABLE u");
}

pub fn main() !void {
    try accessMethods();
    try shapes();
    try randomized();
    try concurrent();
    try minMax();
    try joins();
    try uniqueness();
    var buffer: [512]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-btree\",\"pass\":true,\"assertions\":{d},\"statements\":{d}}}\n", .{ assertions, statements });
    std.debug.print("{s}", .{report});
}
