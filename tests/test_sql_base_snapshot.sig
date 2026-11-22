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
const budgets: [3]DB.TableBudget = .{
    .{ .rows = 8, .versions = 16, .integral_row_words = 6 },
    .{ .rows = 8, .versions = 16 },
    .{ .rows = 4, .versions = 8, .integral_row_words = 1 },
};
var backing: [2][131072]u8 align(64) = undefined;
var live: DB = .{};
var restored: DB = .{};
var result: DB.Result = .{};
var replay: DB.ReplayScratch = .{};
var assertions: usize = 0;

const Image = struct {
    bytes: [4096]u8 = undefined,
    used: usize = 0,

    pub fn appendAll(self: *Image, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.used) return error.ImageFixtureCapacity;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    pub fn length(self: *const Image) !u64 {
        return self.used;
    }

    pub fn readAt(self: *const Image, offset: u64, bytes: []u8) !usize {
        if (offset >= self.used) return 0;
        const start: usize = @intCast(offset);
        const count = @min(bytes.len, self.used - start, 17);
        @memcpy(bytes[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("base snapshot assertion {d}\n", .{assertions});
        return error.BaseSnapshotFailed;
    }
}

fn reset(db: *DB, i: usize) !void {
    db.* = .{};
    const refs = 4096;
    const bytes = try DB.backingBytesFor(budgets, refs);
    @memset(backing[i][0..bytes], 0xa5);
    try db.bindMemoryFor(backing[i][0..bytes], budgets, refs);
}

fn exercise(integral: bool) !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    try live.execute("CREATE TABLE old (id INT DEFAULT 1)", &result);
    try live.execute("DROP TABLE old", &result);
    try live.execute(if (integral)
        "CREATE TABLE ledger (id INT PRIMARY KEY, amount BIGINT, detail DATE)"
    else
        "CREATE TABLE ledger (id INT PRIMARY KEY, amount BIGINT, detail TEXT)", &result);
    try live.execute(if (integral)
        "INSERT INTO ledger VALUES (1,10,DATE '2000-01-01'),(2,20,NULL),(3,30,NULL),(4,NULL,DATE 'infinity'),(5,-50,NULL),(6,60,NULL)"
    else
        "INSERT INTO ledger VALUES (1,10,'alpha'),(2,20,NULL),(3,30,NULL),(4,NULL,'delta'),(5,-50,NULL),(6,60,NULL)", &result);
    try live.execute("UPDATE ledger SET id=8 WHERE id=3", &result);
    try live.execute("DELETE FROM ledger WHERE id=6", &result);
    const bank: usize = if (integral) 0 else 1;
    const csn = live.csn;
    try check(live.tables[bank].live and live.tables[bank].next_rowid == 7);
    var scratch: [192]u8 = undefined;
    var image: Image = .{};
    const active = try live.begin();
    if (DB.BaseSnapshot.write(&live, &image, &scratch)) |_| return error.ActiveImageAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    live.abort(active);
    try check(image.used == 0);
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(image.used > scratch.len and std.mem.eql(u8, image.bytes[0..8], "RSBASE01"));
    if (DB.BaseSnapshot.restore(&restored, &image, csn + 1, &scratch, &replay)) |_| return error.WrongCsnAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try check(restored.csn == 0 and restored.tableCount() == 0);
    var wrong_bank = image;
    // Both candidate banks have room so this exercises the placement check.
    wrong_bank.bytes[16] = if (integral) 1 else 0;
    if (DB.BaseSnapshot.restore(&restored, &wrong_bank, csn, &scratch, &replay)) |_| return error.WrongBankAccepted else |err| try check(err == error.ChangeRecordConflict);
    try check(restored.csn == 0 and restored.tableCount() == 0);
    var trailing = image;
    try trailing.appendAll("old");
    if (DB.BaseSnapshot.restore(&restored, &trailing, csn, &scratch, &replay)) |_| return error.TrailingImageAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try reset(&restored, 1);
    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.next_constraint_oid == live.next_constraint_oid);
    try check(restored.next_default_oid == live.next_default_oid);
    try check(restored.tables[bank].primary_constraint_oid == live.tables[bank].primary_constraint_oid);
    try check(restored.tables[bank].primary_index_oid == live.tables[bank].primary_index_oid);
    try check(restored.tables[bank].oid == live.tables[bank].oid and restored.tables[bank].next_rowid == 7);
    try check((restored.tables[bank].integral_rows.len != 0) == integral);
    try check(restored.tables[bank].version_used == 5 and restored.tables[bank].summary.rows == 5);
    try restored.execute("SELECT id,amount,CAST(detail AS TEXT) FROM ledger ORDER BY id", &result);
    try check(result.row_count == 5 and result.rows[4].cells[0].integer == 8);
    try check(result.rows[4].cells[1].integer == 30 and result.rows[1].cells[2] == .null_value);
    try check(std.mem.eql(u8, result.rows[0].cells[2].text.slice(), if (integral) "2000-01-01" else "alpha"));

    var record: [2048]u8 = undefined;
    const slot = try live.begin();
    try live.statement(slot, "UPDATE ledger SET amount=amount+2 WHERE id=2", &result, .{});
    try live.statement(slot, "DELETE FROM ledger WHERE id=1", &result, .{});
    try live.statement(slot, "INSERT INTO ledger VALUES (9,90,NULL)", &result, .{});
    const changes = try live.prepareCommit(slot, &record);
    live.publishCommit(slot);
    try restored.applyChangeRecord(changes, &replay);
    try check(restored.csn == live.csn and restored.tables[bank].next_rowid == live.tables[bank].next_rowid);
    for ([_]*DB{ &live, &restored }) |db| {
        try db.execute("SELECT id,amount FROM ledger ORDER BY id", &result);
        try check(result.row_count == 5 and result.rows[0].cells[0].integer == 2 and result.rows[0].cells[1].integer == 22);
        try check(result.rows[4].cells[0].integer == 9 and result.rows[4].cells[1].integer == 90);
        try db.execute("SELECT COUNT(*),SUM(amount) FROM ledger", &result);
        try check(result.rows[0].cells[0].integer == 5);
    }

    var truncated = image;
    truncated.used -= 1;
    try reset(&restored, 1);
    if (DB.BaseSnapshot.restore(&restored, &truncated, csn, &scratch, &replay)) |_| return error.TruncatedImageAccepted else |err| try check(err == error.InvalidSnapshotImage);
}

fn takePart(image: *const Image, offset: *usize, tag: u8) ![]const u8 {
    const part = image.bytes[offset.*..][0..5];
    if (part[0] != tag) return error.UnexpectedFixturePart;
    const len = std.mem.readInt(u32, part[1..5], .little);
    offset.* += part.len;
    const record = image.bytes[offset.*..][0..len];
    offset.* += len;
    return record;
}

fn exerciseMultiple() !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    try live.execute("CREATE TABLE old (id INT)", &result);
    try live.execute("DROP TABLE old", &result);
    try live.execute("CREATE TABLE amounts (id INT PRIMARY KEY, value BIGINT)", &result);
    try live.execute("CREATE TABLE mirror (id INT PRIMARY KEY, value BIGINT)", &result);
    try live.execute("CREATE TABLE tiny (id SMALLINT PRIMARY KEY)", &result);
    try live.execute("INSERT INTO amounts VALUES (8,8),(9,9),(10,100),(30,NULL)", &result);
    try live.execute("DELETE FROM amounts WHERE id < 10", &result);
    try live.execute("INSERT INTO mirror VALUES (1,11),(2,22)", &result);
    try live.execute("INSERT INTO tiny VALUES (5)", &result);
    try live.execute("DELETE FROM tiny", &result);
    try check(live.tables[0].integral_rows.len != 0 and live.tables[1].integral_rows.len == 0 and live.tables[2].integral_rows.len != 0);
    const csn = live.csn;
    var scratch: [192]u8 = undefined;
    var image: Image = .{};
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(std.mem.eql(u8, image.bytes[0..8], "RSBASE02"));
    try check(std.mem.readInt(u32, image.bytes[16..20], .little) == 3);

    var offset: usize = 24;
    var second_header: usize = undefined;
    var second_insert: usize = undefined;
    for (0..3) |bank| {
        if (bank == 1) second_header = offset;
        try check(std.mem.readInt(u32, image.bytes[offset..][0..4], .little) == bank);
        var rows = std.mem.readInt(u32, image.bytes[offset + 4 ..][0..4], .little);
        try check(rows == if (bank == 2) @as(u32, 0) else 2);
        offset += 8;
        _ = try takePart(&image, &offset, 1);
        if (bank == 1) second_insert = offset + 5;
        while (rows != 0) {
            const record = try takePart(&image, &offset, 3);
            const count = std.mem.readInt(u32, record[4..8], .little);
            if (count == 0 or count > rows) return error.UnexpectedFixturePart;
            rows -= count;
        }
    }
    const counter_record = offset + 5;
    const counters = try takePart(&image, &offset, 6);
    try check(counters[8] == 17);
    try check(offset == image.used and image.bytes[counter_record + 13] == 3);

    var bad = image;
    bad.bytes[20] = 1;
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.ReservedHeaderAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try check(restored.csn == 0);

    bad = image;
    bad.bytes[second_header] = 0;
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.DuplicateBankAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try reset(&restored, 1);

    bad = image;
    // Both tables accept the encoded row and its RowID is free in amounts.
    // Changing the first mirror row's OID still breaks section ownership.
    std.mem.writeInt(u32, bad.bytes[second_insert + 9 ..][0..4], live.tables[0].oid, .little);
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.CrossTableRowAccepted else |err| try check(err == error.ChangeRecordConflict);
    try reset(&restored, 1);

    bad = image;
    std.mem.writeInt(u32, bad.bytes[counter_record + 26 ..][0..4], live.tables[0].oid, .little);
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.DuplicateCounterAccepted else |err| try check(err == error.InvalidChangeRecord);
    try reset(&restored, 1);

    bad = image;
    bad.used = second_header + 4;
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.TruncatedTableHeaderAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try reset(&restored, 1);

    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.tableCount() == 3 and restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.next_constraint_oid == live.next_constraint_oid);
    for (&live.tables, &restored.tables, 0..) |*source, *target, bank| {
        try check(target.oid == source.oid and target.next_rowid == source.next_rowid);
        try check(target.primary_constraint_oid == source.primary_constraint_oid and target.primary_index_oid == source.primary_index_oid);
        try check((target.integral_rows.len != 0) == (bank != 1));
        try check(target.summary.rows == source.summary.rows and target.version_used == target.row_used);
    }
    try check(restored.tables[2].next_rowid == 2 and restored.tables[2].row_used == 0);
    try restored.execute("SELECT id,value FROM amounts ORDER BY id", &result);
    try check(result.row_count == 2 and result.rows[0].cells[0].integer == 10 and result.rows[1].cells[1] == .null_value);
    try restored.execute("SELECT id,value FROM mirror ORDER BY id", &result);
    try check(result.row_count == 2 and result.rows[0].cells[1].integer == 11 and result.rows[1].cells[1].integer == 22);

    var record: [2048]u8 = undefined;
    const slot = try live.begin();
    try live.statement(slot, "UPDATE amounts SET value=101 WHERE id=10", &result, .{});
    try live.statement(slot, "DELETE FROM mirror WHERE id=1", &result, .{});
    try live.statement(slot, "INSERT INTO mirror VALUES (3,NULL)", &result, .{});
    try live.statement(slot, "INSERT INTO tiny VALUES (7)", &result, .{});
    const changes = try live.prepareCommit(slot, &record);
    live.publishCommit(slot);
    try restored.applyChangeRecord(changes, &replay);
    try check(restored.csn == live.csn);
    for ([_]*DB{ &live, &restored }) |db| {
        try db.execute("SELECT value FROM amounts WHERE id=10", &result);
        try check(result.row_count == 1 and result.rows[0].cells[0].integer == 101);
        try db.execute("SELECT id,value FROM mirror ORDER BY id", &result);
        try check(result.row_count == 2 and result.rows[0].cells[0].integer == 2 and result.rows[1].cells[1] == .null_value);
        try db.execute("SELECT id FROM tiny", &result);
        try check(result.row_count == 1 and result.rows[0].cells[0].integer == 7 and db.tables[2].next_rowid == 3);
    }

    // A vacant earlier compatible bank would shift mirror during recovery.
    try live.execute("DROP TABLE amounts", &result);
    image.used = 0;
    if (DB.BaseSnapshot.write(&live, &image, &scratch)) |_| return error.UnstablePlacementAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    try check(image.used == 0);
}

fn exerciseSequences(with_table: bool) !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    if (with_table) {
        try live.execute("CREATE TABLE facts(id INT PRIMARY KEY, value TEXT)", &result);
        try live.execute("INSERT INTO facts VALUES (1,'retained')", &result);
    }
    try live.execute("CREATE SEQUENCE allocated START 10 INCREMENT 2 CACHE 4", &result);
    try live.execute("CREATE SEQUENCE unused START 101 INCREMENT -2 MINVALUE 0 MAXVALUE 101", &result);
    try live.execute("CREATE SEQUENCE discarded", &result);
    try live.execute("DROP SEQUENCE discarded", &result);
    try live.execute("SELECT nextval('allocated')", &result);
    try check(result.rows[0].cells[0].integer == 10);
    const reserved = live.seqs[0].logged_value;
    try check(reserved > 16 and live.seqs[0].logged_called);
    const csn = live.csn;
    var image: Image = .{};
    var scratch: [192]u8 = undefined;
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(std.mem.eql(u8, image.bytes[0..8], "RSBASE03"));

    var bad = image;
    std.mem.writeInt(u32, bad.bytes[20..24], 0, .little);
    if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.EmptySequenceSectionAccepted else |err| try check(err == error.InvalidSnapshotImage);
    try check(restored.csn == 0);
    if (!with_table) {
        const end = 29 + std.mem.readInt(u32, image.bytes[25..29], .little);
        bad = image;
        std.mem.writeInt(i64, bad.bytes[end - 9 ..][0..8], 0, .little);
        if (DB.BaseSnapshot.restore(&restored, &bad, csn, &scratch, &replay)) |_| return error.InvalidSequenceReservationAccepted else |err| try check(err == error.InvalidChangeRecord);
        try check(restored.csn == 0 and !restored.seqs[0].live);
    }

    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.seqs[0].oid == live.seqs[0].oid and restored.seqs[0].last_value == reserved);
    if (with_table) {
        try restored.execute("SELECT value FROM facts", &result);
        try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "retained"));
    }
    try restored.execute("SELECT nextval('allocated')", &result);
    try check(result.rows[0].cells[0].integer == reserved + 2);
    try restored.execute("SELECT nextval('unused')", &result);
    try check(result.rows[0].cells[0].integer == 101);
}

fn exerciseOwnedSequences() !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    try live.execute("CREATE TABLE orders (id INT GENERATED ALWAYS AS IDENTITY (START 7) PRIMARY KEY, ordinal SERIAL, label TEXT DEFAULT 'ready')", &result);
    try live.execute("INSERT INTO orders DEFAULT VALUES", &result);
    try live.execute("SELECT setval('orders_ordinal_seq',20,true)", &result);
    try live.execute("CREATE SEQUENCE audit_ticket START 17", &result);
    try live.execute("ALTER SEQUENCE audit_ticket OWNED BY orders.label", &result);
    const reserved = live.seqs[0].logged_value;
    const csn = live.csn;
    var image: Image = .{};
    var scratch: [512]u8 = undefined;
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(std.mem.eql(u8, image.bytes[0..8], "RSBASE04"));
    try check(std.mem.readInt(u32, image.bytes[20..24], .little) == 3);

    // Make the first sequence standalone without disturbing its framing.
    // The missing identity association is invalid even though every part
    // remains syntactically valid.
    var missing = image;
    var offset: usize = 32;
    for (0..2) |_| offset += 5 + std.mem.readInt(u32, image.bytes[offset + 1 ..][0..4], .little);
    try check(image.bytes[offset + 5 + sql.change_records.header_size] == 7); // CREATE SEQUENCE without CACHE
    offset += 5 + std.mem.readInt(u32, image.bytes[offset + 1 ..][0..4], .little);
    try check(std.mem.readInt(u32, image.bytes[offset - 19 ..][0..4], .little) == live.seqs[0].owner);
    @memset(missing.bytes[offset - 19 ..][0..5], 0);
    if (DB.BaseSnapshot.restore(&restored, &missing, csn, &scratch, &replay)) |_|
        return error.MissingIdentityOwnerAccepted
    else |err| try check(err == error.InvalidSnapshotImage);
    try reset(&restored, 1);

    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.seqs[0].oid == live.seqs[0].oid and restored.seqs[0].last_value == reserved);
    try check(restored.seqs[1].last_value == 20 and restored.seqs[1].is_called);
    try check(restored.seqs[2].owner == live.seqs[0].owner and restored.seqs[2].owner_column == 2);
    try restored.execute("SELECT id,ordinal,label FROM orders", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 7 and result.rows[0].cells[1].integer == 1);
    try check(std.mem.eql(u8, result.rows[0].cells[2].text.slice(), "ready"));

    const slot = try live.begin();
    try live.statement(slot, "INSERT INTO orders DEFAULT VALUES", &result, .{});
    var record: [512]u8 = undefined;
    const changes = try live.prepareCommit(slot, &record);
    live.publishCommit(slot);
    try restored.applyChangeRecord(changes, &replay);
    try restored.execute("SELECT id,ordinal,label FROM orders WHERE id=8", &result);
    try check(result.row_count == 1 and result.rows[0].cells[1].integer == 21);
    try check(std.mem.eql(u8, result.rows[0].cells[2].text.slice(), "ready"));
    try restored.execute("INSERT INTO orders DEFAULT VALUES RETURNING id,ordinal,label", &result);
    try check(result.rows[0].cells[0].integer > reserved and result.rows[0].cells[1].integer > 21);
}

fn exerciseNamedSchemas() !void {
    try reset(&live, 0);
    try reset(&restored, 1);
    try live.execute("CREATE SCHEMA src", &result);
    try live.execute("CREATE SCHEMA dst", &result);
    try live.execute("CREATE TABLE src.orders (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ordinal SERIAL, n INT DEFAULT 23)", &result);
    try live.execute("CREATE TABLE dst.orders (id INT PRIMARY KEY, n INT DEFAULT 41)", &result);
    try live.execute("CREATE SEQUENCE src.audit START 53", &result);
    try live.execute("ALTER SEQUENCE src.audit OWNED BY src.orders.n", &result);
    try live.execute("CREATE SEQUENCE dst.audit START 73", &result);
    try live.execute("INSERT INTO src.orders DEFAULT VALUES", &result);
    try live.execute("INSERT INTO dst.orders(id) VALUES (2)", &result);

    const csn = live.csn;
    var image: Image = .{};
    var scratch: [512]u8 = undefined;
    try DB.BaseSnapshot.write(&live, &image, &scratch);
    try check(std.mem.eql(u8, image.bytes[0..8], "RSBASE05"));
    try check(std.mem.readInt(u32, image.bytes[24..28], .little) == 2);
    var invalid = image;
    @memset(invalid.bytes[24..28], 0);
    if (DB.BaseSnapshot.restore(&restored, &invalid, csn, &scratch, &replay)) |_|
        return error.EmptySchemaSectionAccepted
    else |err| try check(err == error.InvalidSnapshotImage);
    try check(restored.csn == 0);

    try DB.BaseSnapshot.restore(&restored, &image, csn, &scratch, &replay);
    try check(restored.csn == csn and restored.oid_counter == live.oid_counter);
    try check(restored.schemas[0].oid == live.schemas[0].oid and restored.schemas[1].oid == live.schemas[1].oid);
    try restored.execute("SELECT id,ordinal,n FROM src.orders", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1 and result.rows[0].cells[1].integer == 1 and result.rows[0].cells[2].integer == 23);
    try restored.execute("SELECT id,n FROM dst.orders", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 2 and result.rows[0].cells[1].integer == 41);
    try restored.execute("SELECT pg_get_serial_sequence('src.orders','n')", &result);
    try check(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "src.audit"));
    try restored.execute("SELECT nextval('src.audit'),nextval('dst.audit')", &result);
    try check(result.rows[0].cells[0].integer == 53 and result.rows[0].cells[1].integer == 73);
    try restored.execute("INSERT INTO src.orders DEFAULT VALUES RETURNING id,ordinal", &result);
    try check(result.rows[0].cells[0].integer > 1 and result.rows[0].cells[1].integer > 1);
}

pub fn main() !void {
    try exerciseSequences(false);
    try exerciseSequences(true);
    try exerciseOwnedSequences();
    try exerciseNamedSchemas();
    try exercise(true);
    try exercise(false);
    try exerciseMultiple();
    try live.execute("CREATE ROLE image_reader", &result);
    var image: Image = .{};
    var scratch: [192]u8 = undefined;
    if (DB.BaseSnapshot.write(&live, &image, &scratch)) |_| return error.CatalogImageAccepted else |err| try check(err == error.SnapshotUnsupportedState);
    try check(image.used == 0);
    std.debug.print("{{\"suite\":\"sql_base_snapshot\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
