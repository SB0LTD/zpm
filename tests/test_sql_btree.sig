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

/// Rows that BEFORE triggers change and that referential actions update or
/// delete reach the trees through the same version writes.
fn triggersAndActions() !void {
    try both("CREATE TABLE tp (id INT PRIMARY KEY, k INT)");
    try both("CREATE TABLE tc (id INT PRIMARY KEY, pid INT REFERENCES tp (id) ON UPDATE CASCADE ON DELETE CASCADE, k INT)");
    try both("CREATE FUNCTION tk_scale() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN NEW.k := NEW.k * 10; RETURN NEW; END$$");
    try both("CREATE TRIGGER tc_scale BEFORE INSERT OR UPDATE ON tc FOR EACH ROW EXECUTE FUNCTION tk_scale()");
    try primary("CREATE INDEX tc_pid ON tc (pid)");
    try primary("CREATE INDEX tc_k ON tc (k DESC)");
    try both("INSERT INTO tp SELECT g, g % 4 FROM generate_series(1, 12) g");
    try both("INSERT INTO tc SELECT g, g % 12 + 1, g % 5 FROM generate_series(1, 60) g");
    const cases = [_][]const u8{
        "SELECT id, pid, k FROM tc WHERE pid = 3",
        "SELECT id, k FROM tc WHERE k >= 20 ORDER BY k DESC, id",
        "SELECT tp.id, tc.id FROM tp JOIN tc ON tc.pid = tp.id WHERE tp.k = 1",
        "SELECT min(k), max(k), count(*) FROM tc",
    };
    for (cases) |source| try agree(source);
    try both("UPDATE tp SET id = id + 100 WHERE id % 3 = 0");
    try both("UPDATE tc SET k = k + 1 WHERE id % 4 = 0");
    try both("DELETE FROM tp WHERE id IN (1, 2, 104)");
    for (cases) |source| try agree(source);
    try agree("SELECT id, pid FROM tc WHERE pid > 100 ORDER BY pid, id");
    try valid(&with, "tc");
    try valid(&replica, "tc");
    try replicated("SELECT id, pid, k FROM tc ORDER BY id");
    try both("DROP TABLE tc");
    try both("DROP TABLE tp");
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

// ---- capacity ----------------------------------------------------------------

fn small(entries: usize, depth: usize, key_bytes: usize) sql.Config {
    return .{ .tables = 3, .columns = 3, .rows_per_table = 40, .versions_per_table = 96, .name_bytes = 32, .text_bytes = 64, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 2, .index_fanout = 8, .index_entries = entries, .index_depth = depth, .index_key_bytes = key_bytes };
}

/// Node arena sized for 20 entries per index (index_entries).
const Entries = sql.Database(small(20, 0, 2704));
/// Height 2 at fanout 8: at most 2 x 4^2 - 1 = 31 entries.
const Shallow = sql.Database(small(0, 2, 2704));
/// Entries of at most 16 bytes of key and INCLUDE values.
const Narrow = sql.Database(small(0, 0, 16));
var entries_db: Entries = .{};
var shallow_db: Shallow = .{};
var narrow_db: Narrow = .{};
var craft_db: Entries = .{};
var craft_replica: Entries = .{};
var craft_scratch: Entries.ReplayScratch = .{};
var crafted_record: [1 << 16]u8 = undefined;

fn run(target: anytype, source: []const u8) !void {
    const T = @TypeOf(target.*);
    var result: T.Result = .{};
    statements += 1;
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn fill(target: anytype, table: []const u8, first: usize, count: usize) !void {
    var text: [128]u8 = undefined;
    for (first..first + count) |id| try run(target, try std.fmt.bufPrint(&text, "INSERT INTO {s} VALUES ({d}, {d})", .{ table, id, id % 7 }));
}

fn capacity() !void {
    // Node arena: index_entries entries, then 54000 with nothing changed.
    try run(&entries_db, "CREATE TABLE n (id INT PRIMARY KEY, a INT)");
    try run(&entries_db, "CREATE INDEX n_a ON n (a)");
    try fill(&entries_db, "n", 1, 20);
    try rejects(&entries_db, "INSERT INTO n VALUES (21, 1)", error.IndexCapacity);
    try rejects(&entries_db, "UPDATE n SET a = a + 1 WHERE id < 3", error.IndexCapacity);
    try expect(&entries_db, "SELECT count(*), sum(a) FROM n", "20|63");
    try valid(&entries_db, "n");
    try run(&entries_db, "DELETE FROM n WHERE id > 15");
    _ = entries_db.vacuum();
    try rejects(&entries_db, "INSERT INTO n VALUES (16, 1), (17, 1), (18, 1), (19, 1), (20, 1), (21, 1)", error.IndexCapacity);
    try expect(&entries_db, "SELECT count(*) FROM n", "15");
    try fill(&entries_db, "n", 16, 5);
    try valid(&entries_db, "n");
    try run(&entries_db, "CREATE TABLE m (id INT PRIMARY KEY, a INT)");
    try fill(&entries_db, "m", 1, 21);
    try rejects(&entries_db, "CREATE INDEX m_a ON m (a)", error.IndexCapacity);
    try expect(&entries_db, "SELECT count(*) FROM pg_indexes WHERE tablename = 'm'", "1");
    // Depth: a height-2 tree holds 31 entries.
    try run(&shallow_db, "CREATE TABLE d (id INT PRIMARY KEY, a INT)");
    try run(&shallow_db, "CREATE INDEX d_a ON d (a DESC)");
    try fill(&shallow_db, "d", 1, 31);
    try valid(&shallow_db, "d");
    try rejects(&shallow_db, "INSERT INTO d VALUES (32, 0)", error.IndexCapacity);
    try expect(&shallow_db, "SELECT count(*) FROM d", "31");
    try expect(&shallow_db, "SELECT id FROM d WHERE a = 6 ORDER BY id", "6;13;20;27");
    try run(&shallow_db, "CREATE TABLE d2 (id INT PRIMARY KEY, a INT)");
    try fill(&shallow_db, "d2", 1, 32);
    try rejects(&shallow_db, "CREATE INDEX d2_a ON d2 (a)", error.IndexCapacity);
    // Entry bytes: 16 bytes of key and INCLUDE values (PostgreSQL's index
    // row size limit is 54000 too).
    try run(&narrow_db, "CREATE TABLE k (id INT PRIMARY KEY, t TEXT, a INT)");
    try run(&narrow_db, "CREATE INDEX k_t ON k (t)");
    try run(&narrow_db, "INSERT INTO k VALUES (1, '0123456789abcdef', 1), (2, 'short', 2)");
    try rejects(&narrow_db, "INSERT INTO k VALUES (3, '0123456789abcdefg', 3)", error.IndexCapacity);
    try rejects(&narrow_db, "UPDATE k SET t = t || 'x' WHERE id = 1", error.IndexCapacity);
    try rejects(&narrow_db, "CREATE INDEX k_ta ON k (t, a)", error.IndexCapacity);
    try rejects(&narrow_db, "CREATE INDEX k_ai ON k (a) INCLUDE (t)", error.IndexCapacity);
    try expect(&narrow_db, "SELECT count(*) FROM pg_indexes WHERE tablename = 'k'", "2");
    try run(&narrow_db, "CREATE TABLE kh (id INT PRIMARY KEY, t TEXT)");
    try run(&narrow_db, "CREATE INDEX kh_t ON kh USING hash (t)");
    try run(&narrow_db, "INSERT INTO kh VALUES (1, '0123456789abcdefghijklmnop')");
    try expect(&narrow_db, "SELECT id FROM kh WHERE t = '0123456789abcdefghijklmnop'", "1");
    try valid(&narrow_db, "k");
}

/// Index flag 4 (USING hash) round-trips; a crafted flag fails closed; a
/// definition without the flag (any record logged before access methods
/// were recorded) replays as an ordered index.
fn craftedRecords() !void {
    var result: Entries.Result = .{};
    var used: usize = 0;
    try craft_db.executeChanges("CREATE TABLE h (id INT PRIMARY KEY, a INT)", &result, &record, &used, null, null);
    try craft_replica.applyChangeRecord(record[0..used], &craft_scratch);
    used = 0;
    try craft_db.executeChanges("CREATE INDEX crafted_h ON h USING hash (a)", &result, &record, &used, null, null);
    const valid_record = record[0..used];
    const at = (std.mem.indexOf(u8, valid_record, "\x09crafted_h") orelse return error.IndexNameNotLogged) + 10;
    try check(valid_record[at] == 4);
    for ([_]u8{ 8, 4 | 1, 4 | 8 }) |flags| {
        @memcpy(crafted_record[0..used], valid_record);
        crafted_record[at] = flags;
        try check(craft_replica.applyChangeRecord(crafted_record[0..used], &craft_scratch) == error.InvalidChangeRecord);
        try expect(&craft_replica, "SELECT count(*) FROM pg_indexes WHERE tablename = 'h'", "1");
    }
    @memcpy(crafted_record[0..used], valid_record);
    crafted_record[at] = 0;
    try craft_replica.applyChangeRecord(crafted_record[0..used], &craft_scratch);
    try expect(&craft_replica, "SELECT indexdef FROM pg_indexes WHERE indexname = 'crafted_h'", "CREATE INDEX crafted_h ON public.h USING btree (a)");
    try expect(&craft_db, "SELECT indexdef FROM pg_indexes WHERE indexname = 'crafted_h'", "CREATE INDEX crafted_h ON public.h USING hash (a)");
    used = 0;
    try craft_db.executeChanges("INSERT INTO h VALUES (1, 5), (2, 6), (3, 5)", &result, &record, &used, null, null);
    try craft_replica.applyChangeRecord(record[0..used], &craft_scratch);
    try expect(&craft_db, "SELECT id FROM h WHERE a = 5", "1;3");
    try expect(&craft_replica, "SELECT id FROM h WHERE a = 5", "1;3");
    try valid(&craft_replica, "h");
}

// ---- cost at 120k rows -------------------------------------------------------

const Big = sql.Database(.{ .external_storage = true, .compact_integral_scans = true, .tables = 2, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 16, .nulls_first_ascending = false, .integer_bits = 32, .transactions = 2, .table_indexes = 2, .external_indexes = 2, .tx_writes = 8192, .work_rows = 8192, .result_rows = 256, .expr_nodes = 512 });
const big_rows: usize = 120_000;
/// CREATE TABLE lands in slot 0; CREATE INDEX copies the table into slot 1.
const big_budget: [2]Big.TableBudget = .{ .{ .rows = 8, .versions = 16 }, .{ .rows = big_rows + 8, .versions = 2 * big_rows + 16 } };
const big_refs: usize = 32768;
const big_bytes: usize = Big.backingBytesFor(big_budget, big_refs) catch unreachable;
var big: Big = .{};
var big_region: [big_bytes]u8 align(64) = undefined;

const Cost = struct { index_ns: u64, scan_ns: u64, entries: usize };

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    const now = std.Io.Clock.awake.now(io);
    return @intCast(now.nanoseconds - start.nanoseconds);
}

/// Runs the indexed and the scanned form `rounds` times each, checks they
/// answer alike, and returns the mean time per statement.
fn cost(io: std.Io, indexed: []const u8, scanned: []const u8, rounds: usize) !Cost {
    var out: Cost = .{ .index_ns = 0, .scan_ns = 0, .entries = 0 };
    const left = try query(&big, indexed, &text_buffer);
    @memcpy(saved_buffer[0..left.len], left);
    try same(try query(&big, scanned, &text_buffer), saved_buffer[0..left.len]);
    const before = big.workspace.query.read_stats.index_entries;
    var start = std.Io.Clock.awake.now(io);
    for (0..rounds) |_| _ = try query(&big, indexed, &text_buffer);
    out.index_ns = elapsed(io, start) / rounds;
    out.entries = (big.workspace.query.read_stats.index_entries -% before);
    start = std.Io.Clock.awake.now(io);
    for (0..rounds) |_| _ = try query(&big, scanned, &text_buffer);
    out.scan_ns = elapsed(io, start) / rounds;
    return out;
}

var costs: [5]Cost = undefined;

fn benchmark(io: std.Io) !void {
    try big.bindMemoryFor(&big_region, big_budget, big_refs);
    try run(&big, "CREATE TABLE big (id INT PRIMARY KEY, k INT, g INT, u INT)");
    try run(&big, "CREATE INDEX big_k ON big (k)");
    var text: [256]u8 = undefined;
    var first: usize = 1;
    while (first <= big_rows) : (first += 4000) {
        try run(&big, try std.fmt.bufPrint(&text, "INSERT INTO big SELECT g, (g * 7919) % 120011, g % 1000, (g * 7919) % 120011 FROM generate_series({d}, {d}) g", .{ first, @min(first + 3999, big_rows) }));
    }
    try expect(&big, "SELECT count(*) FROM big", "120000");
    try valid(&big, "big");
    // k (indexed) and u (not indexed) hold the same values.
    costs[0] = try cost(io, "SELECT id FROM big WHERE k = 77777", "SELECT id FROM big WHERE u = 77777", 200);
    costs[1] = try cost(io, "SELECT id FROM big WHERE k BETWEEN 50000 AND 50099", "SELECT id FROM big WHERE u BETWEEN 50000 AND 50099", 50);
    costs[2] = try cost(io, "SELECT id, k FROM big ORDER BY k DESC LIMIT 10", "SELECT id, u FROM big ORDER BY u DESC LIMIT 10", 20);
    costs[3] = try cost(io, "SELECT min(k), max(k) FROM big", "SELECT min(u), max(u) FROM big", 20);
    costs[4] = try cost(io, "SELECT count(*), sum(g) FROM big WHERE k >= 30000 AND k < 31200", "SELECT count(*), sum(g) FROM big WHERE u >= 30000 AND u < 31200", 10);
    // An aggregate over more index rows than the workspace holds streams
    // over a scan instead, with the same answer.
    const wide = try query(&big, "SELECT count(*), sum(g) FROM big WHERE k >= 0 AND k < 60000", &text_buffer);
    @memcpy(saved_buffer[0..wide.len], wide);
    try same(try query(&big, "SELECT count(*), sum(g) FROM big WHERE u >= 0 AND u < 60000", &text_buffer), saved_buffer[0..wide.len]);
    try same(saved_buffer[0..5], "59996");
    // An index walk reads the entries of its range (plus one boundary
    // entry), never the table.
    try check(costs[0].entries <= 2 * 200 + 2);
    try check(costs[1].entries <= 101 * 50 + 2);
    try check(costs[2].entries <= 11 * 20 + 2);
    try check(costs[0].index_ns < costs[0].scan_ns and costs[1].index_ns < costs[1].scan_ns and costs[2].index_ns < costs[2].scan_ns);
}

pub fn main(init: std.process.Init) !void {
    try accessMethods();
    try shapes();
    try randomized();
    try concurrent();
    try minMax();
    try joins();
    try uniqueness();
    try triggersAndActions();
    try capacity();
    try craftedRecords();
    try benchmark(init.io);
    var buffer: [1024]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-btree\",\"pass\":true,\"assertions\":{d},\"statements\":{d},\"rows\":{d}," ++
        "\"probe_ns\":[{d},{d}],\"range100_ns\":[{d},{d}],\"top10_ns\":[{d},{d}],\"minmax_ns\":[{d},{d}],\"range1200_count_ns\":[{d},{d}]," ++
        "\"index_bytes_per_version\":{d}}}\n", .{
        assertions, statements, big_rows,
        costs[0].index_ns, costs[0].scan_ns, costs[1].index_ns, costs[1].scan_ns, costs[2].index_ns, costs[2].scan_ns,
        costs[3].index_ns, costs[3].scan_ns, costs[4].index_ns, costs[4].scan_ns,
        (try Big.indexRunWords(1 << 19, big_budget[1].versions)) * 4 / big_budget[1].versions,
    });
    std.debug.print("{s}", .{report});
}
