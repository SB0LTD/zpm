//! Schema admission, exact SQL values, and recovery for mixed version banks.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{
    .external_storage = true,
    .split_external_versions = true,
    .integral_external_versions = true,
    .compact_integral_scans = true,
    .tables = 3,
    .columns = 8,
    .text_bytes = 64,
    .rows_per_table = 4,
    .work_rows = 128,
    .result_rows = 16,
    .tx_writes = 32,
    .integer_bits = 32,
});

const mixed: [3]DB.TableBudget = .{
    .{ .rows = 8, .versions = 16, .integral_row_words = 6 },
    .{ .rows = 8, .versions = 16 },
    .{ .rows = 4, .versions = 8, .integral_row_words = 1 },
};
const dense: [3]DB.TableBudget = .{
    .{ .rows = 8, .versions = 16 },
    .{ .rows = 8, .versions = 16 },
    .{ .rows = 4, .versions = 8 },
};
const refs = 4096;
var memory: [7][131072]u8 align(64) = undefined;
var db: DB = .{};
var recovered: DB = .{};
var copied: DB = .{};
var dense_copy: DB = .{};
var remap_source: DB = .{};
var remap_target: DB = .{};
var remap_small: DB = .{};
var remap_alias: DB = .{};
var result: DB.Result = .{};
var replay: DB.ReplayScratch = .{};
var record: [8192]u8 = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("integral versions assertion {d}\n", .{assertions});
        return error.IntegralVersionsFailed;
    }
}

fn bind(database: *DB, index: usize, budgets: [3]DB.TableBudget) !void {
    @memset(&memory[index], 0xa5);
    const bytes = try DB.backingBytesFor(budgets, refs);
    try database.bindMemoryFor(memory[index][0..bytes], budgets, refs);
}

fn rejectBadBanks() !void {
    var descriptors: [3]DB.StorageBacking = undefined;
    for (&descriptors, &db.tables) |*bank, *table| bank.* = .{
        .rows = table.rows,
        .versions = table.versions,
        .version_rows = table.version_rows,
        .integral_rows = table.integral_rows,
        .integral_row_words = table.integral_row_words,
        .row_index = table.row_index,
        .key_index = table.key_index,
        .scan_values = table.scan_values,
        .scan_nonnull = table.scan_nonnull,
        .scan_live = table.scan_live,
    };
    var bad = descriptors;
    bad[0].integral_rows = bad[0].integral_rows[0..95];
    if (copied.bindStorage(bad, db.workspace.query.refs)) |_| return error.ShortBankAccepted else |err| try check(err == error.InvalidParameterValue);
    bad = descriptors;
    bad[2].integral_rows = bad[0].integral_rows[0..8];
    if (copied.bindStorage(bad, db.workspace.query.refs)) |_| return error.AliasedBankAccepted else |err| try check(err == error.InvalidParameterValue);
    try check(copied.tables[0].versions.len == 0 and copied.tables[0].integral_rows.len == 0);
}

fn execute(database: *DB, source: []const u8) !void {
    database.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn change(source: []const u8) !void {
    var used: usize = 0;
    db.executeChanges(source, &result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    try check(used > 0);
    recovered.applyChangeRecord(record[0..used], &replay) catch |err| {
        std.debug.print("replay {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn reject(source: []const u8, expected: sql.Error) !void {
    const csn = db.csn;
    const count = db.tableCount();
    if (db.execute(source, &result)) |_| {
        std.debug.print("unexpected success: {s}\n", .{source});
        return error.UnexpectedSuccess;
    } else |err| {
        if (err != expected) std.debug.print("{s}: expected {s}, got {s}\n", .{ source, @errorName(expected), @errorName(err) });
        try check(err == expected);
    }
    try check(db.csn == csn and db.tableCount() == count);
}

fn replayReject(source: []const u8) !void {
    try dense_copy.copyFromInto(&db);
    var used: usize = 0;
    try dense_copy.executeChanges(source, &result, &record, &used, null, null);
    try check(used > 0);
    const csn = recovered.csn;
    const count = recovered.tableCount();
    if (recovered.applyChangeRecord(record[0..used], &replay)) |_| {
        return error.UnexpectedReplaySuccess;
    } else |err| try check(err == error.ChangeRecordConflict);
    try check(recovered.csn == csn and recovered.tableCount() == count);
}

fn rows(database: *DB) !void {
    try execute(database, "SELECT id,grp,store,qty,discount,amount FROM facts WHERE id=-2");
    try check(result.row_count == 1);
    const data = &result.rows[0].cells;
    try check(data[0].integer == -2 and data[1].integer == -2147483648 and data[2].integer == 4294967295);
    try check(data[3].integer == -3 and data[4] == .null_value and data[5].integer == -9223372036854775807);
    try execute(database, "SELECT id FROM facts WHERE day < DATE '1970-01-01' ORDER BY day");
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == -2);
    try execute(database, "SELECT id FROM facts WHERE day = DATE 'infinity'");
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1);
    try execute(database, "SELECT a.id,b.id,a.qty,b.qty FROM facts a JOIN facts b ON a.item=b.item WHERE a.id<>b.id ORDER BY a.id");
    try check(result.row_count == 2);
    try check(result.rows[0].cells[0].integer == -2 and result.rows[0].cells[1].integer == 1 and
        result.rows[0].cells[2].integer == -3 and result.rows[0].cells[3].integer == 5);
    try check(result.rows[1].cells[0].integer == 1 and result.rows[1].cells[1].integer == -2);
    try execute(database, "SELECT id FROM facts ORDER BY qty+1 DESC,id LIMIT 2");
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 1 and result.rows[1].cells[0].integer == -2);
    try execute(database, "SELECT label FROM labels WHERE id=1");
    try check(result.row_count == 1 and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "dense"));
}

fn packedNativePaths() !void {
    db.dialect = .tds;
    defer db.dialect = .postgres;
    try change("UPDATE facts SET discount=4 OUTPUT deleted.discount AS old_value, " ++
        "inserted.discount AS new_value, deleted.id AS old_id, inserted.id AS new_id WHERE id=-2");
    try check(result.row_count == 1 and result.column_count == 4);
    const projected = &result.rows[0].cells;
    try check(projected[0] == .null_value and projected[1].integer == 4);
    try check(projected[2].integer == -2 and projected[3].integer == -2);

    db.dialect = .postgres;
    try change("UPDATE facts SET discount=NULL WHERE id=-2 RETURNING id,discount");
    try check(result.row_count == 1 and result.column_count == 2);
    try check(result.rows[0].cells[0].integer == -2 and result.rows[0].cells[1] == .null_value);
    try execute(&db, "ANALYZE facts");
    try check(db.tables[0].summary.rows == 2 and db.tables[0].summary.columns[5].total == 2);
    try check(db.tables[0].summary.columns[6].nonnull == 1);
}

fn placementFences() !void {
    const writer = try db.begin();
    try db.statement(writer, "CREATE TABLE disposable (id INT)", &result, .{});
    try reject("DROP TABLE labels", error.SerializationFailure);
    try reject("CREATE TABLE competing (id INT)", error.SerializationFailure);
    const created = try db.prepareCommit(writer, &record);
    const target_reader = try recovered.begin();
    if (recovered.applyChangeRecord(created, &replay)) |_| return error.ReplayWhileActiveAccepted else |err| try check(err == error.InvalidParameterValue);
    recovered.abort(target_reader);
    try recovered.applyChangeRecord(created, &replay);
    db.publishCommit(writer);
    try check(db.tables[2].live and recovered.tables[2].live);

    const dropping = try db.begin();
    try db.statement(dropping, "DROP TABLE disposable", &result, .{});
    if (db.statement(dropping, "CREATE TABLE competing (id INT)", &result, .{})) |_| return error.PendingDropReused else |err| try check(err == error.SerializationFailure);
    db.abort(dropping);

    // Pin the catalog snapshot through an unrelated read, leaving DROP's
    // target unlocked. The live bank cannot be reused until the reader ends.
    const reader = try db.begin();
    try db.statement(reader, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", &result, .{});
    try db.statement(reader, "SELECT id FROM labels", &result, .{});
    try change("DROP TABLE disposable");
    try check(db.tables[2].live and db.tables[2].dead_csn != 0 and !recovered.tables[2].live);
    try reject("CREATE TABLE competing (id INT)", error.SerializationFailure);
    db.abort(reader);
}

fn remapSnapshot() !void {
    const narrow: DB.TableBudget = .{ .rows = 2, .versions = 4, .integral_row_words = 1 };
    const wide: DB.TableBudget = .{ .rows = 8, .versions = 16, .integral_row_words = 6 };
    const text: DB.TableBudget = .{ .rows = 8, .versions = 16 };
    const origin = [3]DB.TableBudget{ narrow, wide, text };
    const reordered = [3]DB.TableBudget{ wide, narrow, text };
    try bind(&remap_source, 4, origin);
    try bind(&remap_target, 5, reordered);
    try bind(&remap_small, 6, .{ wide, .{ .rows = 1, .versions = 2, .integral_row_words = 1 }, text });
    try execute(&remap_source, "CREATE TABLE small (id INT PRIMARY KEY)");
    try execute(&remap_source, "CREATE TABLE large (id BIGINT PRIMARY KEY, amount BIGINT)");
    try execute(&remap_source, "CREATE TABLE labels (id INT PRIMARY KEY, label TEXT)");
    try execute(&remap_source, "INSERT INTO small VALUES (-1),(7)");
    try execute(&remap_source, "INSERT INTO large VALUES (-3,9223372036854775807)");
    try execute(&remap_source, "INSERT INTO labels VALUES (5,'copied')");

    const wide_bank = remap_target.tables[0].integral_rows.ptr;
    const narrow_bank = remap_target.tables[1].integral_rows.ptr;
    const dense_bank = remap_target.tables[2].version_rows.ptr;
    try remap_target.copyFromInto(&remap_source);
    // First choices place small in wide and large in dense. Placing labels
    // then frees dense by rematching large to wide and small to narrow.
    try check(remap_target.tables[0].integral_rows.ptr == narrow_bank and
        remap_target.tables[1].integral_rows.ptr == wide_bank and
        remap_target.tables[2].version_rows.ptr == dense_bank);
    for (&remap_target.tables, &remap_source.tables) |*target, *source| try check(target.oid == source.oid);
    try execute(&remap_target, "SELECT SUM(id) FROM small");
    try check(result.rows[0].cells[0].integer == 6);
    try execute(&remap_target, "SELECT label FROM labels WHERE id=5");
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "copied"));

    var used: usize = 0;
    try remap_source.executeChanges("UPDATE large SET amount=-11 WHERE id=-3", &result, &record, &used, null, null);
    try remap_target.applyChangeRecord(record[0..used], &replay);
    try execute(&remap_target, "SELECT amount FROM large WHERE id=-3");
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == -11);

    try execute(&remap_small, "CREATE TABLE existing (label TEXT)");
    try execute(&remap_small, "INSERT INTO existing VALUES ('saved')");
    const old_csn = remap_small.csn;
    const old_first = remap_small.tables[0].integral_rows.ptr;
    if (remap_small.copyFromInto(&remap_source)) |_| return error.UnfitCopyAccepted else |err| try check(err == error.WorkspaceCapacity);
    try check(remap_small.csn == old_csn and remap_small.tables[0].integral_rows.ptr == old_first);
    try execute(&remap_small, "SELECT label FROM existing");
    try check(result.row_count == 1 and std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "saved"));

    const bytes = try DB.backingBytesFor(origin, refs);
    try remap_alias.bindMemoryFor(memory[4][0..bytes], origin, refs);
    if (remap_alias.copyFromInto(&remap_source)) |_| return error.AliasedCopyAccepted else |err| try check(err == error.InvalidParameterValue);
    try check(remap_alias.csn == 0 and remap_alias.tableCount() == 0);
}

pub fn main() !void {
    const dense_bytes = try DB.backingBytesFor(dense, refs);
    const mixed_bytes = try DB.backingBytesFor(mixed, refs);
    const saving = (16 + 8) * @sizeOf(DB.StorageVersionRow) - (16 * 48 + 8 * 8);
    try check(dense_bytes - mixed_bytes == saving);
    var invalid = mixed;
    invalid[0].integral_row_words = ~@as(usize, 0);
    if (DB.backingBytesFor(invalid, refs)) |_| return error.OverflowAccepted else |err| try check(err == error.InvalidParameterValue);
    try bind(&db, 0, mixed);
    try rejectBadBanks();
    try bind(&recovered, 1, mixed);
    try bind(&copied, 2, mixed);
    try bind(&dense_copy, 3, dense);

    // An incompatible schema skips the first integral bank and uses dense.
    try change("CREATE TABLE labels (id INT PRIMARY KEY, label TEXT)");
    try check(!db.tables[0].live and db.tables[1].live and recovered.tables[1].live);
    try change("INSERT INTO labels VALUES (1,'dense')");
    try reject("CREATE TABLE oversized (a BIGINT,b BIGINT,c BIGINT,d BIGINT,e BIGINT,f BIGINT,g BIGINT)", error.TableCapacity);
    try reject("CREATE TABLE unsupported (x NUMERIC)", error.TableCapacity);
    try replayReject("CREATE TABLE unsupported (x NUMERIC)");

    try change("CREATE TABLE facts (id BIGINT PRIMARY KEY, grp INT, item INT, store OID, day DATE, qty INT, discount INT, amount BIGINT, UNIQUE(item,qty))");
    try check(db.tables[0].live and recovered.tables[0].live);
    try check(DB.integralRowWords(db.tables[0].columns[0..8]) == 6);
    try check(db.tables[0].version_rows.len == 0 and db.tables[0].integral_rows.len == 16 * 6);
    try change("INSERT INTO facts VALUES (-2,-2147483648,7,4294967295::oid,DATE '1960-01-02',-3,NULL,-9223372036854775807),(1,NULL,7,0::oid,DATE 'infinity',5,0,9223372036854775807),(10,0,8,1::oid,DATE '1971-01-01',0,0,0)");
    try reject("INSERT INTO facts VALUES (2,0,7,1::oid,DATE '1971-01-01',5,0,0)", error.PrimaryKeyViolation);
    try change("UPDATE facts SET amount=-9223372036854775807 WHERE id=-2");
    try change("DELETE FROM facts WHERE id=10");
    try packedNativePaths();
    try reject("ALTER TABLE facts RENAME COLUMN qty TO units", error.UnsupportedStatement);
    try reject("ALTER TABLE labels ADD COLUMN x INT", error.UnsupportedStatement);
    try replayReject("ALTER TABLE facts RENAME COLUMN qty TO units");
    try placementFences();

    try change("CREATE TABLE flags (id SMALLINT PRIMARY KEY, value SMALLINT)");
    try check(db.tables[2].live and recovered.tables[2].live and db.tables[2].integral_rows.len == 8);
    try change("INSERT INTO flags VALUES (-32768,32767),(2,1),(1,NULL),(3,2)");
    try change("UPDATE flags SET value=NULL WHERE id=-32768");
    try change("UPDATE flags SET value=-32768 WHERE id=1");
    try reject("UPDATE flags SET value=32768 WHERE id=1", error.NumericValueOutOfRange);
    try change("DELETE FROM flags WHERE id=2 OR id=3");
    try change("INSERT INTO flags VALUES (4,4),(5,5)");
    try check(db.tables[2].row_high == 4 and db.tables[2].rows[1].rowid == 3);
    try change("DELETE FROM flags WHERE id>=4");
    try copied.copyFromInto(&db);
    try dense_copy.copyFromInto(&db);
    try copied.copyFromInto(&dense_copy);
    for ([_]*DB{ &db, &recovered, &copied, &dense_copy }) |database| {
        try rows(database);
        try execute(database, "SELECT value FROM flags ORDER BY id");
        try check(result.row_count == 2 and result.rows[0].cells[0] == .null_value and result.rows[1].cells[0].integer == -32768);
    }
    try remapSnapshot();
    std.debug.print("{{\"suite\":\"sql-integral-versions\",\"pass\":true,\"assertions\":{d},\"saved_bytes\":{d},\"fact_payload_bytes\":48}}\n", .{ assertions, saving });
}
