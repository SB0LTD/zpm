//! Text and JSON contract (B11 wave 4 "text-json" lane): regular
//! expression positions, back references and BREs with the regexp_*
//! functions and the regex forms of substring. Every section checks values
//! in PostgreSQL text output, result metadata (type OID, typmod, column
//! name), NULLs, exact errors (SQLSTATE through the error name) with
//! statement atomicity, the statement work budget and cancellation points,
//! and change-record replay compared with sameDatabase/sameCatalog.
//!
//! The batteries (tests/sql_text_json_batteries.sig) and every other
//! expected value were checked against native PostgreSQL 18.7 in a UTF8
//! database created with LOCALE 'C'.
const std = @import("std");
const sql = @import("sql");
const batteries = @import("sql_text_json_batteries.sig");

const DB = sql.Database(.{ .tables = 8, .columns = 8, .rows_per_table = 32, .name_bytes = 63, .text_bytes = 512, .integer_bits = 32, .nulls_first_ascending = false, .sequences = 8, .expr_nodes = 1024, .work_rows = 256, .result_rows = 64 });
const Io = DB.Io;
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("text-json contract failed at assertion {d}\n", .{assertions});
        return error.SqlTextJsonContractFailed;
    }
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

var text_buffer: [16384]u8 = undefined;
/// Rows as `a|b;c|d`, NULL for null cells (PostgreSQL text output).
fn render(target: *const DB.Result, session: *const sql.Session) ![]const u8 {
    var at: usize = 0;
    for (0..target.row_count) |index| {
        if (index != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, session, &buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn shown(source: []const u8, expected: []const u8) !void {
    const got = try render(&result, &db.session);
    if (!std.mem.eql(u8, got, expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, got, expected });
    try check(std.mem.eql(u8, got, expected));
}

/// Every row of a query, columns joined by '|' and rows by ';'.
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

/// Result column `index` has this type OID, typmod and name.
fn meta(index: usize, name: []const u8, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    const got_name = result.column_names[index].slice();
    const ok = got_oid == oid and result.column_typmods[index] == typmod and std.mem.eql(u8, got_name, name);
    if (!ok) std.debug.print("column {d}: got {s} oid {d} typmod {d}, expected {s} {d} {d}\n", .{ index, got_name, got_oid, result.column_typmods[index], name, oid, typmod });
    try check(ok);
}

/// SQLSTATEs of the engine errors this contract expects (as
/// src/db/postgres.sig knownSqlstate maps them).
fn stateOf(err: anyerror) []const u8 {
    const table = [_][2][]const u8{
        .{ "InvalidRegularExpression", "2201B" }, .{ "InvalidParameterValue", "22023" },     .{ "UnsupportedStatement", "0A000" },
        .{ "InvalidEscapeSequence", "22025" },    .{ "InvalidEscapeCharacterUse", "2200C" }, .{ "UndefinedFunction", "42883" },
        .{ "ProgramLimitExceeded", "54000" },     .{ "InvalidTextRepresentation", "22P02" }, .{ "Syntax", "42601" },
        .{ "UndefinedObject", "42704" },          .{ "TextCapacity", "54000" },              .{ "StatementTooComplex", "54001" },
        .{ "QueryWorkLimit", "54000" },           .{ "QueryCanceled", "57014" },             .{ "AmbiguousFunction", "42725" },
        .{ "TypeMismatch", "42804" },             .{ "DivisionByZero", "22012" },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], @errorName(err))) return entry[1];
    return @errorName(err);
}

/// The statement fails with `wanted`; the previous result is untouched and
/// no transaction state leaks (statement atomicity).
fn rejects(source: []const u8, wanted: anyerror) !void {
    const saved = db.session.control;
    db.session.control = null;
    try exec("SELECT 4242");
    db.session.control = saved;
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(result.row_count == 1 and result.column_count == 1 and result.rows[0].cells[0].integer == 4242);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0 and usage.table_locks == 0 and usage.row_locks == 0);
}

/// One statement: `want` is its rendered result, or `!` and the
/// five-character SQLSTATE of the error it raises (statement atomicity
/// checked).
fn single(source: []const u8, want: []const u8) !void {
    var state_marker = want.len == 6 and want[0] == '!';
    if (state_marker) for (want[1..]) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'A' and byte <= 'Z'))) state_marker = false;
    };
    if (!state_marker) return rows(source, want);
    try exec("SELECT 4242");
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        const state = stateOf(err);
        if (!std.mem.eql(u8, state, want[1..])) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), want[1..] });
        try check(std.mem.eql(u8, state, want[1..]));
    }
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 4242);
    const usage = db.usage();
    try check(usage.transactions == 0 and usage.pending_versions == 0);
}

fn battery(entries: []const [2][]const u8) !void {
    for (entries) |entry| try single(entry[0], entry[1]);
}

const Cancel = struct {
    remaining: usize,
    fn poll(raw: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(raw.?));
        if (self.remaining == 0) return error.QueryCanceled;
        self.remaining -= 1;
    }
};

/// Every work budget below the statement's need fails with exactly
/// QueryWorkLimit (54000) at that budget, every cancellation point with
/// QueryCanceled (57014), and an unbudgeted rerun returns `wanted` again.
fn controlled(source: []const u8, wanted: []const u8) !void {
    try rows(source, wanted);
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try exec(source);
    const used = control.used;
    try check(used > 0);
    var limit: u64 = 1;
    while (limit < used) : (limit += @max(1, used / 97)) {
        control.reset(limit);
        try rejects(source, error.QueryWorkLimit);
        try check(control.used == limit);
    }
    var cancel: Cancel = .{ .remaining = 0 };
    control.context = &cancel;
    control.poll = Cancel.poll;
    control.poll_interval = 1;
    var point: usize = 0;
    while (point < used) : (point += @max(1, used / 61)) {
        cancel.remaining = point;
        control.reset(0);
        try rejects(source, error.QueryCanceled);
    }
    db.session.control = null;
    try rows(source, wanted);
}

fn sameResult(a: *const DB.Result, b: *const DB.Result, a_db: *DB, b_db: *DB) !bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or a.column_typmods[column] != b.column_typmods[column] or
            !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |index| for (0..a.column_count) |column| {
        const x = &a.rows[index].cells[column];
        const y = &b.rows[index].cells[column];
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*) or DB.compareCells(x, y) != 0) return false;
        if (x.* == .null_value) continue;
        var p: [Io.format_bytes]u8 = undefined;
        var q: [Io.format_bytes]u8 = undefined;
        if (!std.mem.eql(u8, try Io.format(x, false, &a_db.session, &p), try Io.format(y, false, &b_db.session, &q))) return false;
    };
    return true;
}

fn sameQuery(a: *DB, b: *DB, source: []const u8) !bool {
    var x: DB.Result = .{};
    var y: DB.Result = .{};
    try a.execute(source, &x);
    try b.execute(source, &y);
    return sameResult(&x, &y, a, b);
}

/// Logical equality of two databases over `tables`: table count, OID
/// counter, live rows, next rowids and every row.
fn sameDatabase(a: *DB, b: *DB, tables: []const []const u8) !bool {
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter) return false;
    for (tables) |name| {
        const left = a.storageStats(name);
        const right = b.storageStats(name);
        if ((left == null) != (right == null)) return false;
        if (left == null) continue;
        if (left.?.live_rows != right.?.live_rows or left.?.next_rowid != right.?.next_rowid) return false;
        var query: [64]u8 = undefined;
        if (!try sameQuery(a, b, try std.fmt.bufPrint(&query, "SELECT * FROM {s}", .{name}))) return false;
    }
    return true;
}

/// Relation OIDs, column types/typmods and the type catalog agree.
fn sameCatalog(a: *DB, b: *DB) !bool {
    for ([_][]const u8{
        "SELECT oid, relname, relkind FROM pg_class WHERE relnamespace = 2200 ORDER BY oid",
        "SELECT attrelid, attname, atttypid FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT attrelid, attnum, atttypmod FROM pg_attribute WHERE attrelid >= 16384 ORDER BY attrelid, attnum",
        "SELECT COUNT(*), SUM(oid::int8), SUM(typarray::int8) FROM pg_type",
    }) |source| if (!try sameQuery(a, b, source)) {
        std.debug.print("catalog differs: {s}\n", .{source});
        return false;
    };
    return true;
}

var replay_primary: DB = .{};
var replay_replica: DB = .{};
var replay_record: [8192]u8 = undefined;

/// Replays `statements` from a fresh primary into a replica through change
/// records; both must hold the same database and catalog and answer
/// `query` identically (types, typmods, cell tags and text).
fn replay(statements: []const []const u8, tables: []const []const u8, query: []const u8, expected_text: []const u8) !void {
    replay_primary = .{};
    replay_replica = .{};
    var r: DB.Result = .{};
    for (statements) |source| {
        var used: usize = 0;
        replay_primary.executeChanges(source, &r, &replay_record, &used, null, null) catch |err| {
            std.debug.print("replay source failed: {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        try replay_replica.applyChangeRecord(replay_record[0..used], &scratch);
    }
    try check(try sameDatabase(&replay_primary, &replay_replica, tables));
    try check(try sameCatalog(&replay_primary, &replay_replica));
    var expected: DB.Result = .{};
    try replay_primary.execute(query, &expected);
    try replay_replica.execute(query, &result);
    try check(try sameResult(&expected, &result, &replay_primary, &replay_replica));
    const got = try render(&result, &replay_replica.session);
    if (!std.mem.eql(u8, got, expected_text)) std.debug.print("replica\n  got:      {s}\n  expected: {s}\n", .{ got, expected_text });
    try check(std.mem.eql(u8, got, expected_text));
}

// ---- regular expressions -------------------------------------------------

fn regularExpressions() !void {
    // PostgreSQL's own regression cases (strings.sql, regex.sql) for the
    // regexp_* functions and substring, plus 473 match positions and
    // captures (hand-written and generated patterns: greedy and
    // non-greedy quantifiers, nested and iterated groups, alternation,
    // back references, BREs, lookarounds, case folding).
    try battery(&batteries.regex_functions_battery);

    // Result metadata.
    try rows("SELECT regexp_match('abc', '(b)'), regexp_replace('abc', 'b', 'x'), regexp_split_to_array('a b', ' '), regexp_count('aa', 'a'), regexp_instr('ab', 'b'), regexp_substr('ab', 'b'), substring('abc' FROM 'b')", "{b}|axc|{a,b}|2|2|b|b");
    try meta(0, "regexp_match", 1009, -1);
    try meta(1, "regexp_replace", 25, -1);
    try meta(2, "regexp_split_to_array", 1009, -1);
    try meta(3, "regexp_count", 23, -1);
    try meta(4, "regexp_instr", 23, -1);
    try meta(5, "regexp_substr", 25, -1);
    try meta(6, "substring", 25, -1);
    try rows("SELECT * FROM regexp_matches('a1b2', '[a-z](\\d)', 'g')", "{1};{2}");
    try meta(0, "regexp_matches", 1009, -1);
    try rows("SELECT * FROM regexp_split_to_table('a-b', '-') WITH ORDINALITY", "a|1;b|2");
    try meta(0, "regexp_split_to_table", 25, -1);
    try meta(1, "ordinality", 20, -1);
    try rows("SELECT m FROM regexp_matches('xy', '(.)', 'g') AS m", "{x};{y}");
    try meta(0, "m", 1009, -1);
    try rows("SELECT regexp_matches('ab', '(.)', 'g') AS g, 1 AS one", "{a}|1;{b}|1");
    try meta(0, "g", 1009, -1);

    // Over a table: NULLs, char(n) and varchar subjects, set-returning
    // calls inside a target, ORDER BY over the expanded rows.
    try exec("CREATE TABLE rxf(id INT PRIMARY KEY, s TEXT, c CHAR(6), v VARCHAR(10), p TEXT)");
    try exec("INSERT INTO rxf VALUES (1, 'k1=v1;k2=v2', 'ab  ', 'x-y-z', '(\\w)(\\d)'), (2, NULL, 'q', NULL, NULL), (3, 'a=b', 'zz', 'p', '=')");
    try rows("SELECT id, regexp_replace(s, '(\\w+)=(\\w+)', '\\2:\\1', 'g') FROM rxf ORDER BY id", "1|v1:k1;v2:k2;2|NULL;3|b:a");
    try rows("SELECT id, regexp_match(s, p) FROM rxf ORDER BY id", "1|{k,1};2|NULL;3|{=}");
    try rows("SELECT id, (regexp_matches(s, '(\\w+)=(\\w+)', 'g'))[2] FROM rxf ORDER BY 1, 2", "1|v1;1|v2;3|b");
    try rows("SELECT id, regexp_split_to_table(v, '-') AS piece FROM rxf ORDER BY id, piece DESC", "1|z;1|y;1|x;3|p");
    try rows("SELECT regexp_replace(c, 'b$', 'B'), regexp_count(c, ' '), c ~ 'b $' FROM rxf WHERE id = 1", "aB|0|f");
    try rows("SELECT count(*) FROM rxf WHERE regexp_count(s, '=') >= 1", "2");
    try rows("SELECT id FROM rxf WHERE regexp_substr(v, '[a-z]', 1, 3) = 'z'", "1");

    // Back references and BREs through the operators and functions.
    try rows("SELECT 'abcabc' ~ '^(abc)\\1$', regexp_match('the the end', '(\\w+) \\1'), regexp_replace('aa bb cd', '(.)\\1', '<\\1>', 'g'), regexp_match('ab(c)', '\\(.\\)', 'b')", "t|{the}|<a> <b> cd|{a}");

    // Errors: options and positions are 22023, patterns 2201B; set-returning
    // calls in WHERE, CASE, COALESCE or an aggregate are 0A000 as in
    // PostgreSQL. Two of them in one select list are 0A000 here only
    // (PostgreSQL expands them in lockstep: {a}|{b}).
    try rejects("SELECT regexp_matches('a', 'a') FROM rxf WHERE regexp_matches(s, 'a') IS NULL", error.UnsupportedStatement);
    try rejects("SELECT 1 FROM rxf WHERE regexp_split_to_table(s, ',') = 'a'", error.UnsupportedStatement);
    try rejects("SELECT regexp_matches('a', 'a'), regexp_matches('b', 'b')", error.UnsupportedStatement);
    try rejects("SELECT CASE WHEN true THEN regexp_matches('a', 'a') END", error.UnsupportedStatement);
    try rejects("SELECT COALESCE(regexp_split_to_table('a', ','), 'x')", error.UnsupportedStatement);
    try rejects("SELECT count(regexp_split_to_table('a', ','))", error.UnsupportedStatement);
    try rejects("SELECT regexp_replace('a', 'a', 'b', 0)", error.InvalidParameterValue);
    try rejects("SELECT regexp_instr('a', 'a', 1, 1, 2)", error.InvalidParameterValue);
    try rejects("SELECT * FROM regexp_matches('a', '(')", error.InvalidRegularExpression);
    try rejects("SELECT regexp_count(1, 'a')", error.UndefinedFunction);
    try rejects("SELECT regexp_instr('a', 'a', 'x')", error.InvalidTextRepresentation);
    // A result beyond the text capacity is 54000.
    try rejects("SELECT regexp_replace(repeat('a', 300), 'a', 'bb', 'g')", error.TextCapacity);

    // Every match position is budgeted and cancellable.
    try controlled("SELECT regexp_replace('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab', '(a|aa)*(a+)b', '[\\1|\\2]')", "[aa|a]");
    try controlled("SELECT count(*) FROM regexp_split_to_table('a1b22c333d4444e', '\\d+')", "5");
    try controlled("SELECT regexp_match('abcabcabcx', '^(.+)\\1+(x)')", "{abc,x}");

    // Replay: values computed by the functions are stored in text and text[]
    // columns and replicate exactly.
    try replay(&.{
        "CREATE TABLE rxr(id INT PRIMARY KEY, s TEXT, parts TEXT[])",
        "INSERT INTO rxr VALUES (1, regexp_replace('2026-11-27', '(\\d+)-(\\d+)-(\\d+)', '\\3/\\2/\\1'), regexp_split_to_array('a,b,,c', ','))",
        "INSERT INTO rxr SELECT 1 + ordinality::int, piece, regexp_match(piece, '(.)(.)?') FROM regexp_split_to_table('xy z', ' ') WITH ORDINALITY AS t(piece, ordinality)",
        "UPDATE rxr SET s = substring(s FROM '(\\d+)/') WHERE id = 1",
    }, &.{"rxr"}, "SELECT * FROM rxr ORDER BY id", "1|27|{a,b,\"\",c};2|xy|{x,y};3|z|{z,NULL}");
}

pub fn main(init: std.process.Init) !void {
    try regularExpressions();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-text-json\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
