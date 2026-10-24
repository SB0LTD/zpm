//! Executable SQL contracts. The assertion counter proves this suite ran.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{
    .tables = 2,
    .columns = 4,
    .rows_per_table = 4,
    .name_bytes = 32,
    .text_bytes = 64,
    .predicates = 8,
});

var assertions: usize = 0;
var statements: usize = 0;
var cases: usize = 0;
var fuzz_inputs: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.SqlContractFailed;
}

fn same(actual: []const u8, expected: []const u8) !void {
    try check(std.mem.eql(u8, actual, expected));
}

fn execute(db: *DB, result: *DB.Result, source: []const u8) !void {
    try db.execute(source, result);
    statements += 1;
    // An autocommit statement publishes everything and holds nothing.
    try check(quiet(db));
}

fn equalResult(left: *const DB.Result, right: *const DB.Result) bool {
    if (left.column_count != right.column_count or left.row_count != right.row_count or
        left.affected_rows != right.affected_rows) return false;
    for (0..left.column_count) |column| {
        if (!std.mem.eql(u8, left.column_names[column].slice(), right.column_names[column].slice())) return false;
    }
    for (0..left.row_count) |row| {
        for (0..left.column_count) |column| {
            const a = left.rows[row].cells[column];
            const b = right.rows[row].cells[column];
            switch (a) {
                .null_value => switch (b) {
                    .null_value => {},
                    else => return false,
                },
                .integer => |value| switch (b) {
                    .integer => |other| {
                        if (value != other) return false;
                    },
                    else => return false,
                },
                .boolean => |value| switch (b) {
                    .boolean => |other| {
                        if (value != other) return false;
                    },
                    else => return false,
                },
                .text => |value| switch (b) {
                    .text => |other| {
                        if (!std.mem.eql(u8, value.slice(), other.slice())) return false;
                    },
                    else => return false,
                },
                // This contract's tables use INTEGER/BOOLEAN/TEXT only.
                else => return false,
            }
        }
    }
    return true;
}

fn rejects(db: *DB, result: *DB.Result, source: []const u8, expected: ?anyerror) !void {
    const before = result.*;
    if (db.execute(source, result)) |_| {
        return error.InvalidSqlAccepted;
    } else |err| {
        if (expected) |wanted| try check(err == wanted) else try check(true);
        try check(equalResult(&before, result));
        try check(quiet(db));
    }
}

/// No active transaction, held lock or uncommitted version remains.
fn quiet(db: *const DB) bool {
    const usage = db.usage();
    return usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0;
}

fn isNull(cell: DB.Cell) bool {
    return switch (cell) {
        .null_value => true,
        else => false,
    };
}

fn crud() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, active BOOLEAN, note TEXT)");
    try execute(&db, &result, "INSERT INTO people VALUES (3, 'Carol', false, NULL)");
    try check(result.affected_rows == 1);
    try execute(&db, &result, "INSERT INTO people (name, id, active) VALUES ('Alice', 1, TRUE)");
    try execute(&db, &result, "INSERT INTO people VALUES (2, 'Bob', true, 'ready')");
    try execute(&db, &result, "SELECT name, id FROM people WHERE active = TRUE AND id >= 1 ORDER BY id ASC LIMIT 1;");
    try check(result.column_count == 2 and result.row_count == 1);
    try same(result.column_names[0].slice(), "name");
    try same(result.rows[0].cells[0].text.slice(), "Alice");
    try check(result.rows[0].cells[1].integer == 1);
    try execute(&db, &result, "UPDATE people SET name = 'Bobby', note = NULL WHERE id = 2");
    try check(result.affected_rows == 1);
    try execute(&db, &result, "SELECT * FROM people ORDER BY id DESC");
    try check(result.column_count == 4 and result.row_count == 3);
    try check(result.rows[0].cells[0].integer == 3);
    try same(result.rows[1].cells[1].text.slice(), "Bobby");
    try check(isNull(result.rows[1].cells[3]));
    try execute(&db, &result, "DELETE FROM people WHERE id <> 2 AND active = FALSE");
    try check(result.affected_rows == 1);
    try execute(&db, &result, "DELETE FROM people WHERE id != 99");
    try check(result.affected_rows == 2);
    try execute(&db, &result, "SELECT * FROM people");
    try check(result.row_count == 0 and result.column_count == 4);
    cases += 1;
}

fn nullAndPredicates() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE items (id INT, value INT, flag BOOL, label TEXT)");
    try execute(&db, &result, "INSERT INTO items VALUES (1, NULL, true, 'alpha')");
    try execute(&db, &result, "INSERT INTO items VALUES (2, 10, false, 'beta')");
    try execute(&db, &result, "INSERT INTO items VALUES (3, -5, NULL, 'gamma')");
    try execute(&db, &result, "SELECT id FROM items WHERE value IS NULL");
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1);
    try execute(&db, &result, "SELECT id FROM items WHERE value IS NOT NULL AND value <= 10 AND value > -6 ORDER BY id");
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 2 and result.rows[1].cells[0].integer == 3);
    try execute(&db, &result, "SELECT id FROM items WHERE value = NULL");
    try check(result.row_count == 0);
    try execute(&db, &result, "SELECT id FROM items WHERE value != NULL");
    try check(result.row_count == 0);
    try execute(&db, &result, "SELECT id FROM items WHERE label >= 'beta' AND label < 'z' ORDER BY id DESC");
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 3);
    try execute(&db, &result, "SELECT id FROM items WHERE flag IS NULL");
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 3);
    try execute(&db, &result, "SELECT id FROM items LIMIT 0");
    try check(result.row_count == 0);
    cases += 1;
}

fn constraintsAndAtomicity() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE accounts (id INT PRIMARY KEY, name TEXT NOT NULL, balance INTEGER, enabled BOOL)");
    try execute(&db, &result, "INSERT INTO accounts VALUES (1, 'first', 10, TRUE)");
    try execute(&db, &result, "INSERT INTO accounts VALUES (2, 'second', 20, FALSE)");
    try execute(&db, &result, "SELECT * FROM accounts ORDER BY id");
    const before = result;
    try rejects(&db, &result, "INSERT INTO accounts VALUES (1, 'duplicate', 30, true)", error.PrimaryKeyViolation);
    try rejects(&db, &result, "INSERT INTO accounts VALUES (NULL, 'missing', 30, true)", error.NotNullViolation);
    try rejects(&db, &result, "INSERT INTO accounts (id, balance) VALUES (3, 30)", error.NotNullViolation);
    try rejects(&db, &result, "INSERT INTO accounts VALUES (3, 'wrong', 'thirty', true)", error.InvalidTextRepresentation);
    try rejects(&db, &result, "UPDATE accounts SET id = 7", error.PrimaryKeyViolation);
    try rejects(&db, &result, "UPDATE accounts SET balance = 999, id = 7", error.PrimaryKeyViolation);
    try rejects(&db, &result, "UPDATE accounts SET name = NULL WHERE id = 1", error.NotNullViolation);
    try rejects(&db, &result, "UPDATE accounts SET balance = TRUE WHERE id = 2", error.TypeMismatch);
    try rejects(&db, &result, "UPDATE accounts SET id = 1 WHERE id = 2", error.PrimaryKeyViolation);
    try execute(&db, &result, "SELECT * FROM accounts ORDER BY id");
    try check(equalResult(&before, &result));
    try execute(&db, &result, "UPDATE accounts SET enabled = TRUE WHERE id = 99");
    try check(result.affected_rows == 0);
    try execute(&db, &result, "DELETE FROM accounts WHERE id = 99");
    try check(result.affected_rows == 0);
    cases += 1;
}

fn malformedDoesNotMutate() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE data (id INT PRIMARY KEY, name TEXT)");
    try execute(&db, &result, "INSERT INTO data VALUES (1, 'stable')");
    try execute(&db, &result, "SELECT * FROM data");
    const before = result;
    const malformed = [_][]const u8{
        "INSERT INTO data VALUES (2, 'extra'); DELETE FROM data",
        "UPDATE data SET name = 'changed' unexpected",
        "DELETE FROM data WHERE id = 1 unexpected",
        "DROP TABLE data trailing",
        "CREATE TABLE other (id INT) trailing",
        "INSERT INTO data VALUES (2, 'unterminated)",
        "INSERT INTO data VALUES (2, 'extra',)",
        "UPDATE data SET name = 'changed', WHERE id = 1",
        "SELECT * FROM data;;",
        "SELECT * FROM data WHERE id =",
        "SELECT * FROM data WHERE id = 1 AND",
        "SELECT * FROM data LIMIT -1",
        "UPDATE data SET id = 9WHERE id = 1",
        "DELETE FROM data WHERE id = 1AND name = 'stable'",
        "SELECT * FROM data WHERE id = 1AND name = 'stable'",
        "SELECT * FROM data WHERE id = 1ORDER BY id",
        "SELECT * FROM data LIMIT 1_rows",
    };
    for (malformed) |source| try rejects(&db, &result, source, null);
    try execute(&db, &result, "SELECT * FROM data");
    try check(equalResult(&before, &result));
    try execute(&db, &result, "CREATE TABLE other (id INT)");
    try check(result.row_count == 0);
    cases += 1;
}

fn namesAndTypeErrors() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE records (id INT, note TEXT)");
    try execute(&db, &result, "SELECT * FROM records");
    try rejects(&db, &result, "CREATE TABLE RECORDS (id INT)", error.TableExists);
    try rejects(&db, &result, "CREATE TABLE repeated (id INT, ID TEXT)", error.DuplicateColumn);
    try rejects(&db, &result, "SELECT missing FROM records", error.ColumnNotFound);
    try rejects(&db, &result, "SELECT * FROM missing", error.TableNotFound);
    try rejects(&db, &result, "SELECT * FROM records WHERE absent = 1", error.ColumnNotFound);
    try rejects(&db, &result, "SELECT * FROM records WHERE id = 'wrong'", error.InvalidTextRepresentation);
    try rejects(&db, &result, "UPDATE records SET absent = 1", error.ColumnNotFound);
    try rejects(&db, &result, "UPDATE records SET id = 'wrong'", error.InvalidTextRepresentation);
    try rejects(&db, &result, "DELETE FROM records WHERE id = TRUE", error.UndefinedFunction);
    try rejects(&db, &result, "INSERT INTO records (id, ID) VALUES (1, 2)", error.DuplicateColumn);
    try rejects(&db, &result, "SELECT * FROM records ORDER BY absent", error.ColumnNotFound);
    try rejects(&db, &result, "DROP TABLE absent", error.TableNotFound);
    try execute(&db, &result, "DROP TABLE records");
    try execute(&db, &result, "CREATE TABLE records (new_column TEXT)");
    try execute(&db, &result, "SELECT * FROM records");
    try check(result.column_count == 1 and result.row_count == 0);
    try same(result.column_names[0].slice(), "new_column");
    cases += 1;
}

fn capacityAndReuse() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE items (id INT PRIMARY KEY, name TEXT)");
    try execute(&db, &result, "CREATE TABLE second (id INT)");
    try execute(&db, &result, "SELECT * FROM items");
    try rejects(&db, &result, "CREATE TABLE third (id INT)", error.TableCapacity);
    try execute(&db, &result, "DROP TABLE second");
    try rejects(&db, &result, "CREATE TABLE too_many (a INT, b INT, c INT, d INT, e INT)", error.ColumnCapacity);
    try rejects(&db, &result, "CREATE TABLE name_beyond_the_configured_thirty_two_byte_limit (id INT)", error.NameCapacity);
    try execute(&db, &result, "INSERT INTO items VALUES (1, 'one')");
    try execute(&db, &result, "INSERT INTO items VALUES (2, 'two')");
    try execute(&db, &result, "INSERT INTO items VALUES (3, 'three')");
    try execute(&db, &result, "INSERT INTO items VALUES (4, 'four')");
    try execute(&db, &result, "SELECT * FROM items ORDER BY id");
    const before = result;
    try rejects(&db, &result, "INSERT INTO items VALUES (5, 'five')", error.RowCapacity);
    try rejects(&db, &result, "UPDATE items SET name = '12345678901234567890123456789012345678901234567890123456789012345'", error.TextCapacity);
    try rejects(&db, &result, "SELECT * FROM items WHERE id > 0 AND id > 0 AND id > 0 AND id > 0 AND id > 0 AND id > 0 AND id > 0 AND id > 0 AND id > 0", error.PredicateCapacity);
    try execute(&db, &result, "SELECT * FROM items ORDER BY id");
    try check(equalResult(&before, &result));
    try execute(&db, &result, "DELETE FROM items WHERE id = 2");
    try execute(&db, &result, "INSERT INTO items VALUES (5, 'five')");
    try execute(&db, &result, "SELECT id FROM items ORDER BY id");
    try check(result.row_count == 4 and result.rows[3].cells[0].integer == 5);
    for (0..16) |_| {
        try execute(&db, &result, "DELETE FROM items");
        try check(result.affected_rows == 4 or result.affected_rows == 1);
        try execute(&db, &result, "INSERT INTO items VALUES (1, 'reused')");
    }
    try execute(&db, &result, "SELECT * FROM items");
    try check(result.row_count == 1);
    try same(result.rows[0].cells[1].text.slice(), "reused");
    cases += 1;
}

fn lexerAndOwnership() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, " \r\n cReAtE\tTaBlE People (ID InT PRIMARY KEY, Name TeXt, Flag bOoL); \n");
    var source = [_]u8{ 'I', 'N', 'S', 'E', 'R', 'T', ' ', 'I', 'N', 'T', 'O', ' ', 'P', 'e', 'o', 'p', 'l', 'e', ' ', 'V', 'A', 'L', 'U', 'E', 'S', ' ', '(', '1', ',', ' ', '\'', 'o', 'w', 'n', 'e', 'd', '\'', ',', ' ', 'T', 'R', 'U', 'E', ')' };
    try execute(&db, &result, &source);
    @memset(&source, 'x');
    try execute(&db, &result, "INSERT INTO people VALUES (2, 'O''Brien; still one value', false)");
    try execute(&db, &result, "INSERT INTO people VALUES (3, '', NULL)");
    try execute(&db, &result, "SELECT name FROM PEOPLE WHERE id = 1");
    try same(result.rows[0].cells[0].text.slice(), "owned");
    const owned = result;
    var other: DB.Result = .{};
    try execute(&db, &other, "UPDATE people SET name = 'changed' WHERE id = 1");
    try check(equalResult(&owned, &result));
    try execute(&db, &other, "DROP TABLE people");
    try same(result.rows[0].cells[0].text.slice(), "owned");
    try execute(&db, &other, "CREATE TABLE people (id INT, name TEXT)");
    try execute(&db, &other, "INSERT INTO people VALUES (1, 'O''Brien; still one value')");
    try execute(&db, &other, "INSERT INTO people VALUES (2, '')");
    try execute(&db, &other, "SELECT name FROM people ORDER BY id");
    try same(other.rows[0].cells[0].text.slice(), "O'Brien; still one value");
    try same(other.rows[1].cells[0].text.slice(), "");
    cases += 1;
}

fn integerBounds() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE numbers (value BIGINT)");
    try execute(&db, &result, "INSERT INTO numbers VALUES (-9223372036854775808)");
    try execute(&db, &result, "INSERT INTO numbers VALUES (9223372036854775807)");
    try execute(&db, &result, "INSERT INTO numbers VALUES (0)");
    try execute(&db, &result, "SELECT value FROM numbers ORDER BY value");
    try check(result.row_count == 3);
    try check(result.rows[0].cells[0].integer == std.math.minInt(i64));
    try check(result.rows[1].cells[0].integer == 0);
    try check(result.rows[2].cells[0].integer == std.math.maxInt(i64));
    const before = result;
    try rejects(&db, &result, "INSERT INTO numbers VALUES (9223372036854775808)", error.IntegerOverflow);
    try rejects(&db, &result, "INSERT INTO numbers VALUES (-9223372036854775809)", error.IntegerOverflow);
    try rejects(&db, &result, "UPDATE numbers SET value = 999999999999999999999999999999999999", error.IntegerOverflow);
    try execute(&db, &result, "SELECT value FROM numbers ORDER BY value");
    try check(equalResult(&before, &result));
    cases += 1;
}

fn parserAndSortEdges() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try execute(&db, &result, "CREATE TABLE edges (id INT, rank INT)");
    try execute(&db, &result, "INSERT INTO edges VALUES (1, 5)");
    try execute(&db, &result, "INSERT INTO edges VALUES (2, NULL)");
    try execute(&db, &result, "INSERT INTO edges VALUES (3, 5)");
    try execute(&db, &result, "INSERT INTO edges VALUES (4, 2)");
    try execute(&db, &result, "-- before statement\nSELECT id FROM edges -- before ordering\nORDER BY rank ASC; -- trailing comment");
    try check(result.row_count == 4);
    try check(result.rows[0].cells[0].integer == 2 and result.rows[1].cells[0].integer == 4);
    try check(result.rows[2].cells[0].integer == 1 and result.rows[3].cells[0].integer == 3);
    try execute(&db, &result, "SELECT id FROM edges ORDER BY rank DESC LIMIT 18446744073709551615");
    try check(result.row_count == 4);
    try check(result.rows[0].cells[0].integer == 1 and result.rows[1].cells[0].integer == 3);
    try check(result.rows[2].cells[0].integer == 4 and result.rows[3].cells[0].integer == 2);
    try rejects(&db, &result, "SELECT id FROM edges LIMIT 18446744073709551616", error.IntegerOverflow);
    try execute(&db, &result, "SELECT id FROM edges WHERE id = 1 OR id = 2 ORDER BY id");
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 1 and result.rows[1].cells[0].integer == 2);
    try rejects(&db, &result, "SELECT COUNT(*) FROM edges", null);
    try rejects(&db, &result, "CREATE TABLE two_keys (a INT PRIMARY KEY, b INT PRIMARY KEY)", error.Syntax);
    try execute(&db, &result, "CREATE TABLE abcdefghijklmnopqrstuvwxyzabcdef (value TEXT)");
    try execute(&db, &result, "INSERT INTO abcdefghijklmnopqrstuvwxyzabcdef VALUES ('1234567890123456789012345678901234567890123456789012345678901234')");
    try execute(&db, &result, "SELECT value FROM abcdefghijklmnopqrstuvwxyzabcdef");
    try same(result.rows[0].cells[0].text.slice(), "1234567890123456789012345678901234567890123456789012345678901234");
    cases += 1;
}

fn fuzzOne(baseline: *const DB, before: *const DB.Result, source: []const u8) !void {
    var db = baseline.*;
    var result = before.*;
    fuzz_inputs += 1;
    if (db.execute(source, &result)) |_| {
        // A truncation can itself be a complete valid SQL statement.
        try check(quiet(&db));
    } else |_| {
        // Failure atomicity through the MVCC API: no transaction, lock or
        // uncommitted version of the failed statement survives.
        try check(quiet(&db));
        try check(equalResult(before, &result));
        try check(db.tableCount() == baseline.tableCount());
        try execute(&db, &result, "SELECT * FROM fuzz ORDER BY id");
        try check(equalResult(before, &result));
    }
}

fn deterministicFuzz() !void {
    var baseline: DB = .{};
    var result: DB.Result = .{};
    try execute(&baseline, &result, "CREATE TABLE fuzz (id INT PRIMARY KEY, name TEXT)");
    try execute(&baseline, &result, "INSERT INTO fuzz VALUES (1, 'unchanged')");
    try execute(&baseline, &result, "INSERT INTO fuzz VALUES (2, 'also unchanged')");
    try execute(&baseline, &result, "SELECT * FROM fuzz ORDER BY id");
    const truncations = [_][]const u8{
        "CREATE TABLE extra (id INT PRIMARY KEY, name TEXT NOT NULL)",
        "INSERT INTO fuzz VALUES (3, 'O''Brien')",
        "SELECT name, id FROM fuzz WHERE id > 0 AND name IS NOT NULL ORDER BY id DESC LIMIT 2;",
        "UPDATE fuzz SET name = 'changed', id = 7 WHERE id > 0;",
        "DELETE FROM fuzz WHERE id = 1;",
        "DROP TABLE fuzz;",
    };
    for (truncations) |source| {
        for (0..source.len + 1) |length| try fuzzOne(&baseline, &result, source[0..length]);
    }
    const prefixes = [_][]const u8{
        "",                        "SELECT ",       "INSERT INTO fuzz VALUES (", "UPDATE fuzz SET name = ",
        "DELETE FROM fuzz WHERE ", "CREATE TABLE ", "DROP TABLE fuzz ",
    };
    var state: u32 = 0x52414d53;
    var source: [128]u8 = undefined;
    for (0..1024) |iteration| {
        const prefix = prefixes[iteration % prefixes.len];
        @memcpy(source[0..prefix.len], prefix);
        state = state *% 1664525 +% 1013904223;
        const length: usize = 1 + state % 96;
        for (source[prefix.len..][0..length]) |*byte| {
            state = state *% 1664525 +% 1013904223;
            byte.* = @truncate(state >> 24);
        }
        try fuzzOne(&baseline, &result, source[0 .. prefix.len + length]);
    }
    try check(fuzz_inputs > 1024);
    cases += 1;
}

fn snapshots() !void {
    var source: DB = .{};
    var target: DB = undefined;
    @memset(std.mem.asBytes(&target), 0xaa);
    var result: DB.Result = .{};
    var copied: DB.Result = undefined;
    @memset(std.mem.asBytes(&copied), 0xaa);
    source.copyFrom(&source);
    target.copyFrom(&source);
    try check(target.tableCount() == 0);
    // Empty slots must not touch or examine their poisoned row storage.
    for (std.mem.asBytes(&target.tables[0].rows)) |byte| try check(byte == 0xaa);
    try execute(&source, &result, "CREATE TABLE t (id INT PRIMARY KEY, value TEXT)");
    try execute(&source, &result, "INSERT INTO t VALUES (1, 'first')");
    try execute(&source, &result, "INSERT INTO t VALUES (2, NULL)");
    try execute(&source, &result, "CREATE TABLE unindexed (flag BOOLEAN)");
    try execute(&source, &result, "INSERT INTO unindexed VALUES (TRUE)");
    target.copyFrom(&source);
    target.copyFrom(&target);
    try check(target.tableCount() == 2);
    for (std.mem.asBytes(&target.tables[0].rows[2])) |byte| try check(byte == 0xaa);
    const queries = [_][]const u8{ "SELECT * FROM t ORDER BY id", "SELECT * FROM t WHERE id = 2", "SELECT * FROM unindexed" };
    var other: DB.Result = .{};
    for (queries) |query| {
        try execute(&source, &result, query);
        try execute(&target, &other, query);
        try check(equalResult(&result, &other));
        copied.copyFrom(&result);
        copied.copyFrom(&copied);
        try check(equalResult(&result, &copied));
    }
    try execute(&target, &result, "UPDATE t SET value = 'private' WHERE id = 1");
    try execute(&source, &result, "SELECT value FROM t WHERE id = 1");
    try same(result.rows[0].cells[0].text.slice(), "first");
    try rejects(&target, &result, "INSERT INTO t VALUES (1, 'duplicate')", error.PrimaryKeyViolation);
    try execute(&source, &result, "DELETE FROM t WHERE id = 2");
    target.copyFrom(&source);
    try execute(&target, &result, "INSERT INTO t VALUES (2, 'reused')");
    try execute(&target, &result, "SELECT value FROM t WHERE id = 2");
    try same(result.rows[0].cells[0].text.slice(), "reused");
    try execute(&source, &result, "DROP TABLE t");
    try execute(&source, &result, "DROP TABLE unindexed");
    target.copyFrom(&source);
    try check(target.tableCount() == 0);
    try execute(&target, &result, "CREATE TABLE t (name TEXT PRIMARY KEY)");
    try execute(&target, &result, "INSERT INTO t VALUES ('fresh')");
    try execute(&target, &result, "SELECT name FROM t WHERE name = 'fresh'");
    try check(result.row_count == 1);
    // A DDL result copies just the header, leaving old destination rows alone.
    @memset(std.mem.asBytes(&copied), 0xaa);
    result.clear(7);
    copied.copyFrom(&result);
    try check(copied.row_count == 0 and copied.column_count == 0 and copied.affected_rows == 7);
    for (std.mem.asBytes(&copied.rows)) |byte| try check(byte == 0xaa);
    cases += 1;
}

fn nullOrdering() !void {
    const PostgresDB = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 4, .nulls_first_ascending = false });
    var db: PostgresDB = .{};
    var result: PostgresDB.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, rank INT)", &result);
    try db.execute("INSERT INTO t VALUES (1, 5)", &result);
    try db.execute("INSERT INTO t VALUES (2, NULL)", &result);
    try db.execute("INSERT INTO t VALUES (3, 1)", &result);
    try db.execute("INSERT INTO t VALUES (4, NULL)", &result);
    const queries = [_][]const u8{
        "SELECT id FROM t ORDER BY rank ASC", "SELECT id FROM t ORDER BY rank DESC",
        "SELECT id FROM t ORDER BY rank ASC NULLS FIRST", "SELECT id FROM t ORDER BY rank ASC NULLS LAST",
        "SELECT id FROM t ORDER BY rank DESC NULLS FIRST", "SELECT id FROM t ORDER BY rank DESC NULLS LAST",
    };
    const expected = [_][4]i64{ .{ 3, 1, 2, 4 }, .{ 2, 4, 1, 3 }, .{ 2, 4, 3, 1 }, .{ 3, 1, 2, 4 }, .{ 2, 4, 1, 3 }, .{ 1, 3, 2, 4 } };
    for (queries, expected) |query, ids| {
        try db.execute(query, &result);
        try check(result.row_count == ids.len);
        for (ids, 0..) |id, row| try check(result.rows[row].cells[0].integer == id);
    }
    const before = result;
    if (db.execute("SELECT id FROM t ORDER BY rank NULLS invalid", &result)) |_| return error.InvalidNullOrder else |err| try check(err == error.Syntax);
    try check(std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&result)));
    cases += 1;
}

fn postgresIntegers() !void {
    const IntDB = sql.Database(.{ .tables = 1, .columns = 2, .rows_per_table = 4, .integer_bits = 32 });
    var db: IntDB = .{};
    var result: IntDB.Result = .{};
    try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, wide BIGINT)", &result);
    try db.execute("INSERT INTO t VALUES (-2147483648, -9223372036854775808)", &result);
    try db.execute("INSERT INTO t VALUES (2147483647, 9223372036854775807)", &result);
    try db.execute("SELECT * FROM t ORDER BY id", &result);
    try check(result.column_types[0] == .integer32 and result.column_types[1] == .integer);
    try check(result.rows[0].cells[0].integer == -2147483648 and result.rows[1].cells[0].integer == 2147483647);
    try check(result.rows[0].cells[1].integer == std.math.minInt(i64) and result.rows[1].cells[1].integer == std.math.maxInt(i64));
    const before = result;
    const invalid = [_][]const u8{ "INSERT INTO t VALUES (2147483648, 0)", "INSERT INTO t VALUES (-2147483649, 0)", "UPDATE t SET id = 2147483648", "UPDATE t SET id = -2147483649" };
    for (invalid) |query| {
        if (db.execute(query, &result)) |_| return error.OverflowAccepted else |err| try check(err == error.IntegerOverflow);
        try check(std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&result)));
    }
    try db.execute("SELECT id FROM t WHERE id < 2147483648 ORDER BY id", &result);
    try check(result.row_count == 2);
    cases += 1;
}

const BoundaryProbe = struct {
    db: *DB,
    result: *DB.Result,
    before: DB = .{},
    before_result: DB.Result = .{},
    calls: usize = 0,
    fail: bool = false,

    fn commit(context: ?*anyopaque) anyerror!void {
        const self: *BoundaryProbe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        try check(equalResult(self.result, &self.before_result));
        try check(self.db.tableCount() == self.before.tableCount());
        // An observer at the persistence boundary must see the complete old
        // state, including affected rows and indices, before publication.
        for ([_][]const u8{ "SELECT * FROM t ORDER BY id", "SELECT * FROM u ORDER BY id" }) |query| {
            var expected: DB.Result = .{};
            var observed: DB.Result = .{};
            if (self.before.execute(query, &expected)) |_| {
                // Under MVCC an unpublished DROP TABLE holds AccessExclusive:
                // a reader waits (WouldBlock) instead of seeing a change.
                if (self.db.execute(query, &observed)) |_| {
                    try check(equalResult(&expected, &observed));
                } else |err| try check(err == error.WouldBlock and self.db.usage().table_locks != 0);
            } else |err| {
                if (self.db.execute(query, &observed)) |_| return error.EarlyPublication else |other| try check(err == other);
            }
        }
        if (self.fail) return error.InjectedCommitFailure;
    }
};

fn commitBoundary() !void {
    var db: DB = .{};
    var result: DB.Result = .{};
    try db.execute("CREATE TABLE t (id INT PRIMARY KEY, value TEXT NOT NULL)", &result);
    try db.execute("INSERT INTO t VALUES (1, 'old')", &result);
    try db.execute("INSERT INTO t VALUES (2, 'two')", &result);
    var probe = BoundaryProbe{ .db = &db, .result = &result };
    const writes = [_][]const u8{
        "CREATE TABLE u (id INT PRIMARY KEY)",
        "INSERT INTO t VALUES (3, 'three')",
        "UPDATE t SET value = 'changed' WHERE id = 1",
        "UPDATE t SET id = 4 WHERE id = 1",
        "UPDATE t SET value = 'none' WHERE id = 99",
        "DELETE FROM t WHERE id = 2",
        "DELETE FROM t WHERE id = 99",
        "DROP TABLE t",
        "CREATE TABLE t (id INT PRIMARY KEY, value TEXT NOT NULL)",
        "INSERT INTO t VALUES (4, 'reused')",
        "DROP TABLE u",
    };
    for (writes) |source| {
        probe.before.copyFrom(&db);
        probe.before_result = result;
        const calls = probe.calls;
        probe.fail = true;
        if (db.executeWithCommit(source, &result, &probe, BoundaryProbe.commit)) |_| return error.CommitFailureIgnored else |err| try check(err == error.InjectedCommitFailure);
        try check(probe.calls == calls + 1 and equalResult(&result, &probe.before_result));
        probe.fail = false;
        try db.executeWithCommit(source, &result, &probe, BoundaryProbe.commit);
        try check(probe.calls == calls + 2);
        // The same validated statement must produce the same logical database
        // and affected-row result through ordinary execution and the boundary.
        var expected: DB.Result = .{};
        try probe.before.execute(source, &expected);
        try check(equalResult(&expected, &result) and expected.affected_rows == result.affected_rows);
        probe.before_result = result;
        try BoundaryProbe.commit(&probe);
    }
    const invalid = [_][]const u8{
        "CREATE TABLE t (id INT)", "CREATE TABLE u (id WRONG)",
        "CREATE TABLE u (id INT); DROP TABLE t", "DROP TABLE t trailing",
        "DROP TABLE missing", "INSERT INTO t VALUES (4, 'duplicate')",
        "INSERT INTO t VALUES (5, NULL)", "INSERT INTO t VALUES (5, 1 / 0)",
        "INSERT INTO t VALUES (5, 'bad'); DELETE FROM t",
        "UPDATE t SET value = NULL", "UPDATE t SET missing = 1",
        "UPDATE t SET id = 5 trailing", "DELETE FROM t trailing",
        "DELETE FROM missing", "SELECT * FROM t; DELETE FROM t", "VACUUM",
    };
    const calls = probe.calls;
    for (invalid) |source| {
        if (db.executeWithCommit(source, &result, &probe, BoundaryProbe.commit)) |_| return error.InvalidSqlCommitted else |_| {}
        try check(probe.calls == calls and equalResult(&result, &probe.before_result));
    }
    try db.executeWithCommit("SELECT * FROM t WHERE id = 4", &result, &probe, BoundaryProbe.commit);
    try check(probe.calls == calls and result.row_count == 1);
    try same(result.rows[0].cells[1].text.slice(), "reused");
    cases += 1;
}

pub fn main(init: std.process.Init) !void {
    if (comptime @import("builtin").os.tag == .windows) {
        if (std.mem.indexOf(u16, init.minimal.args.vector, std.unicode.utf8ToUtf16LeStringLiteral("--prove-failure")) != null)
            try check(false);
    } else {
        var args = std.process.Args.Iterator.init(init.minimal.args);
        _ = args.next();
        if (args.next()) |mode| {
            if (std.mem.eql(u8, mode, "--prove-failure")) try check(false) else return error.UnknownArgument;
        }
    }
    try crud();
    try nullAndPredicates();
    try constraintsAndAtomicity();
    try malformedDoesNotMutate();
    try namesAndTypeErrors();
    try capacityAndReuse();
    try lexerAndOwnership();
    try integerBounds();
    try parserAndSortEdges();
    try deterministicFuzz();
    try snapshots();
    try nullOrdering();
    try postgresIntegers();
    try commitBoundary();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql\",\"pass\":true,\"cases\":{d},\"assertions\":{d},\"statements\":{d},\"fuzz_inputs\":{d},\"database_bytes\":{d}}}\n", .{ cases, assertions, statements, fuzz_inputs, @sizeOf(DB) });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
