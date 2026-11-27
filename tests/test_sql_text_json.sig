//! Text and JSON contract (B11 wave 4 "text-json" lane): regular
//! expression positions, back references and BREs with the regexp_*
//! functions and the regex forms of substring; the english text search
//! configuration and default_text_search_config; non-ASCII case mapping;
//! jsonpath like_regex and keyvalue(), jsonb_path_query; JSON_EXISTS,
//! JSON_VALUE, JSON_QUERY, IS JSON, the SQL/JSON constructors and
//! aggregates. Every section checks values
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
        .{ "TypeMismatch", "42804" },             .{ "DivisionByZero", "22012" },            .{ "InvalidSettingValue", "22023" },
        .{ "SqlJsonMemberNotFound", "2203A" },    .{ "SqlJsonObjectNotFound", "2203C" },     .{ "MoreThanOneSqlJsonItem", "22034" },
        .{ "NoSqlJsonItem", "22035" },            .{ "SqlJsonScalarRequired", "2203F" },     .{ "CannotCoerce", "42846" },
        .{ "NullValueNotAllowed", "22004" },      .{ "DuplicateJsonObjectKeyValue", "22030" }, .{ "SqlJsonArrayNotFound", "22039" },
        .{ "ZeroLengthCharacterString", "2200F" }, .{ "ColumnNotFound", "42703" },           .{ "TableNotFound", "42P01" },
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

/// The error maps to this SQLSTATE in the contract's table.
fn stateCheck(err: anyerror, wanted: []const u8) !void {
    try check(std.mem.eql(u8, stateOf(err), wanted));
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

// ---- text search: english ------------------------------------------------

fn textSearchEnglish() !void {
    // The english configuration (Snowball stemmer, stop words), phrase gaps
    // of stop words, default_text_search_config and the forms using it,
    // text @@ tsquery and text @@ text.
    try battery(&batteries.fts_english_battery);
    // length, strip, setweight, tsvector_to_array, array_to_tsvector,
    // ts_delete, ts_filter, numnode and tsvector || tsvector.
    try battery(&batteries.ts_utility_battery);
    try stateCheck(error.ZeroLengthCharacterString, "2200F");
    try rows("SELECT to_tsvector('Fat Rats'), plainto_tsquery('rats'), 'a b' @@ 'b'", "'fat':1 'rat':2|'rat'|t");
    try meta(0, "to_tsvector", 3614, -1);
    try meta(1, "plainto_tsquery", 3615, -1);
    try meta(2, "?column?", 16, -1);
    try rows("SHOW default_text_search_config", "pg_catalog.english");
    try meta(0, "default_text_search_config", 25, -1);
    try rows("SELECT setting, vartype FROM pg_settings WHERE name = 'default_text_search_config'", "pg_catalog.english|string");
    // An unknown configuration is 22023 and changes nothing; the other
    // Snowball configurations are 0A000 here.
    try rejects("SET default_text_search_config = 'nosuch'", error.InvalidSettingValue);
    try rejects("SET default_text_search_config = 'french'", error.UnsupportedStatement);
    try rows("SHOW default_text_search_config", "pg_catalog.english");
    // The setting applies to later statements and RESET restores it.
    try exec("SET default_text_search_config = 'simple'");
    try rows("SELECT to_tsvector('The Rats')", "'rats':2 'the':1");
    try exec("RESET default_text_search_config");
    try rows("SELECT to_tsvector('The Rats')", "'rat':2");
    // Stemming and parsing are budgeted and cancellable.
    try controlled("SELECT to_tsvector('english', 'Generously generalized connections were relationally hopefully running') @@ to_tsquery('english', 'generous <-> generalize & connect')", "t");
}

// ---- case mapping -----------------------------------------------------------

fn caseMapping() !void {
    // upper / lower / initcap over every hundredth chunk of code points.
    try battery(&batteries.case_mapping_battery);
    // The same C.UTF-8 ctype in regular expressions (classes, allcases()
    // folding, ranges, back references, word boundaries) and in the text
    // search parser and dictionaries.
    try battery(&batteries.regex_wide_battery);
    try battery(&batteries.ts_wide_battery);
    // ILIKE compares lower() of both sides.
    try rows("SELECT 'É' ILIKE 'é', 'ǅ' ILIKE 'ǆ', chr(8490) ILIKE 'k', 'K' ILIKE chr(8490), 'ÉCOLE' ILIKE 'é%', 'école' ILIKE '_COLE', 'ß' ILIKE 'SS', 'É' LIKE 'é'", "t|t|t|t|t|t|f|f");
    try rows("SELECT 'Straße' ILIKE '%STRASSE', 'ΣΊΣΥΦΟΣ' ILIKE 'σίσυφοσ', 'ÀB' NOT ILIKE 'àb', 'x' || chr(304) ILIKE 'XI'", "f|t|f|t");
    // Case variants of a bracket range are merged into its ranges.
    try rows("SELECT 'Ж' ~* '[а-я]', 'ǅ' ~* '[\\u0100-\\u024f]', 'k' ~* '[\\u2100-\\u21ff]'", "t|t|t");
    // A lexeme growing under towlower beyond the text capacity is 54000.
    try rejects("SELECT to_tsvector('simple', repeat('\xc8\xba', 256))", error.TextCapacity);
    try rows("SELECT upper('\xc3\xa9t\xc3\xa9'), lower('\xc3\x89T\xc3\x89'), initcap('\xc3\xa9l\xc3\xa8ve-\xc3\xa9COLE')", "\xc3\x89T\xc3\x89|\xc3\xa9t\xc3\xa9|\xc3\x89l\xc3\xa8ve-\xc3\x89cole");
    try meta(0, "upper", 25, -1);
    // A result beyond the text capacity is 54000 (two-byte to three-byte
    // mappings grow the text).
    try rejects("SELECT upper(repeat('\xc9\x90', 256))", error.TextCapacity);
}

// ---- jsonpath and SQL/JSON ----------------------------------------------------

fn jsonFeatures() !void {
    try battery(&batteries.jsonpath_battery);
    try battery(&batteries.json_query_battery);
    try battery(&batteries.is_json_battery);
    try battery(&batteries.json_constructor_battery);
    try battery(&batteries.contract_mixed_battery);

    // Result metadata.
    try rows("SELECT JSON_VALUE(jsonb '{\"a\": \"xy\"}', '$.a' RETURNING varchar(5)), JSON_QUERY(jsonb '[1]', '$'), JSON_EXISTS(jsonb '1', '$'), '1' IS JSON, JSON_OBJECT('k' VALUE 1), JSON_ARRAY(1 RETURNING jsonb), JSON_SCALAR(2), JSON_SERIALIZE('[]')", "xy|[1]|t|t|{\"k\" : 1}|[1]|2|[]");
    try meta(0, "json_value", 1043, 9);
    try meta(1, "json_query", 3802, -1);
    try meta(2, "json_exists", 16, -1);
    try meta(3, "?column?", 16, -1);
    try meta(4, "json_object", 114, -1);
    try meta(5, "json_array", 3802, -1);
    try meta(6, "json_scalar", 114, -1);
    try meta(7, "json_serialize", 25, -1);
    try rows("SELECT * FROM jsonb_path_query('[1, 2]', '$[*]')", "1;2");
    try meta(0, "jsonb_path_query", 3802, -1);
    try rows("SELECT JSON_ARRAYAGG(v ORDER BY v), JSON_OBJECTAGG(k VALUE v RETURNING jsonb) FROM (VALUES ('a', 2), ('b', 1)) t(k, v)", "[1, 2]|{\"a\": 2, \"b\": 1}");
    try meta(0, "json_arrayagg", 114, -1);
    try meta(1, "json_objectagg", 3802, -1);

    // Errors with statement atomicity.
    try rejects("SELECT JSON_OBJECT(NULL VALUE 1)", error.NullValueNotAllowed);
    try rejects("SELECT JSON_OBJECT('a' VALUE 1, 'a' VALUE 2 WITH UNIQUE KEYS)", error.DuplicateJsonObjectKeyValue);
    try rejects("SELECT json_object_agg_unique(k, 1) FROM (VALUES ('x'), ('x')) v(k)", error.DuplicateJsonObjectKeyValue);
    try rejects("SELECT JSON_VALUE(jsonb '{}', 'strict $.a' ERROR ON ERROR)", error.SqlJsonMemberNotFound);
    try rejects("SELECT JSON_VALUE(1, '$')", error.CannotCoerce);
    try rejects("SELECT 1 IS JSON", error.TypeMismatch);
    try rejects("SELECT jsonb_path_query_first('1', '$.keyvalue()')", error.SqlJsonObjectNotFound);
    try rejects("SELECT jsonb_path_exists('\"x\"', '$ ? (@ like_regex \"(\")')", error.InvalidRegularExpression);
    try rejects("SELECT jsonb_path_query_first('\"2024-01-01\"', '$.date()')", error.UnsupportedStatement);
    // JSON_ARRAYAGG / JSON_OBJECTAGG RETURNING a string type: 0A000 here.
    try rejects("SELECT JSON_ARRAYAGG(1 RETURNING text)", error.UnsupportedStatement);

    // Path evaluation, like_regex and constructors are budgeted.
    try controlled("SELECT jsonb_path_query_array('[\"aab\", \"ab\", \"b\", \"aaab\"]', '$[*] ? (@ like_regex \"^(a|aa)*b$\")')", "[\"aab\", \"ab\", \"b\", \"aaab\"]");
    try controlled("SELECT count(*) FROM jsonb_path_query('{\"a\": [1, 2, 3, 4, 5, 6]}', '$.a[*] ? (@ > 2)')", "4");
    try controlled("SELECT JSON_VALUE(jsonb '{\"a\": [{\"b\": 7}]}', '$.a[0].b' RETURNING int) + JSON_QUERY(jsonb '{\"q\": 1}', '$.q' RETURNING int)", "8");

    // Replay: SQL/JSON and text search results stored in jsonb, json,
    // tsvector and text columns replicate exactly.
    try replay(&.{
        "CREATE TABLE jr(id INT PRIMARY KEY, doc JSONB, j JSON, v TSVECTOR, t TEXT)",
        "INSERT INTO jr VALUES (1, JSON_OBJECT('a' VALUE 1 RETURNING jsonb), JSON_ARRAY(1, 'x'), to_tsvector('english', 'Running foxes'), JSON_VALUE(jsonb '{\"a\": \"q\"}', '$.a'))",
        "INSERT INTO jr SELECT 1 + ordinality::int, jsonb_path_query, JSON_OBJECT('i' VALUE ordinality), to_tsvector('The quick fox'), upper('\xc3\xa9') FROM jsonb_path_query('[{\"k\": 1}, [2]]', '$[*]') WITH ORDINALITY",
        "UPDATE jr SET t = JSON_QUERY(doc, '$.k' RETURNING text WITH WRAPPER) WHERE id = 2",
    }, &.{"jr"}, "SELECT * FROM jr ORDER BY id", "1|{\"a\": 1}|[1, \"x\"]|'fox':2 'run':1|q;2|{\"k\": 1}|{\"i\" : 1}|'fox':3 'quick':2|[1];3|[2]|{\"i\" : 2}|'fox':3 'quick':2|\xc3\x89");
}

pub fn main(init: std.process.Init) !void {
    try regularExpressions();
    try textSearchEnglish();
    try caseMapping();
    try jsonFeatures();
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-text-json\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
