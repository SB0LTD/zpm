const std = @import("std");
const large = @import("sql").large_object_pages;
const Pages = large.Pages;
const size = large.page_bytes;

var assertions: usize = 0;

fn expect(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("large-object page contract failed at assertion {d}\n", .{assertions});
        return error.LargeObjectPageContractFailed;
    }
}

fn Backing(comptime rows: usize, comptime versions: usize, comptime hash_rows: usize, comptime hash_versions: usize) type {
    return struct {
        rows: [rows]Pages.RowSlot = undefined,
        versions: [versions]Pages.Version = undefined,
        payloads: [versions]Pages.PageRow = undefined,
        row_index: [hash_rows]u32 = undefined,
        key_index: [hash_versions]u32 = undefined,

        fn open(self: *@This()) !Pages {
            return Pages.init(self.backing());
        }

        fn backing(self: *@This()) Pages.Backing {
            return .{
                .rows = &self.rows, .versions = &self.versions, .version_rows = &self.payloads,
                .row_index = &self.row_index, .key_index = &self.key_index,
            };
        }
    };
}

fn writeView(csn: u64, slot: u16, epoch: u32, command: u32, horizon: u64) large.Mutation {
    return .{
        .snapshot = .{ .csn = csn, .slot = slot, .epoch = epoch, .cid = command },
        .owner = .{ .slot = slot, .epoch = epoch },
        .horizon = horizon,
    };
}

fn snapshotAndSparseRead() !void {
    var backing: Backing(5, 12, 16, 32) = .{};
    var pages = try backing.open();
    var changes: [2]Pages.Change = undefined;
    const start = size - 2;
    const end = 4 * size + 2;
    const first = writeView(10, 0, 1, 1, 10);
    try expect((try pages.stageWrite(43000, start, "abcde", first, &changes)) == 2);
    try expect(pages.page(.{ .oid = 43000, .page = 0 }, first.snapshot) == null);
    try expect(pages.page(.{ .oid = 43000, .page = 0 }, .{ .csn = 10 }) == null);
    var own = first.snapshot;
    own.cid += 1;
    try expect(pages.page(.{ .oid = 43000, .page = 0 }, own).?.len == size);
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 43000, .page = 1 }, own).?, "cde"));
    pages.publish(&changes, 11);

    const second = writeView(11, 1, 2, 1, 10);
    try expect((try pages.stageWrite(43000, end - 2, "xy", second, &changes)) == 1);
    pages.publish(changes[0..1], 12);
    var output: [2 * size + 7]u8 = undefined;
    try expect((try pages.read(43000, end, start - 2, &output, .{ .csn = 12 })) == output.len);
    try expect(std.mem.eql(u8, output[0..7], "\x00\x00abcde"));
    for (output[7..]) |byte| if (byte != 0) return error.HoleWasNotZero;
    try expect((try pages.read(43000, end, end - 5, output[0..6], .{ .csn = 12 })) == 5);
    try expect(std.mem.eql(u8, output[0..5], "\x00\x00\x00xy"));
    try expect((try pages.read(43000, end, end, &output, .{ .csn = 12 })) == 0);
    try expect(pages.page(.{ .oid = 43000, .page = 2 }, .{ .csn = 12 }) == null);
    try expect(pages.page(.{ .oid = 43001, .page = 4 }, .{ .csn = 12 }) == null);

    const third = writeView(12, 0, 3, 1, 11);
    try expect((try pages.stageWrite(43000, start + 2, "Z", third, &changes)) == 1);
    own = third.snapshot;
    own.cid += 1;
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 43000, .page = 1 }, own).?, "Zde"));
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 43000, .page = 1 }, .{ .csn = 12 }).?, "cde"));
    const concurrent = writeView(12, 2, 4, 1, 11);
    if (pages.stagePage(.{ .oid = 43000, .page = 1 }, "race", concurrent)) |_| {
        return error.ForeignWriterChangedPage;
    } else |err| try expect(err == error.SerializationFailure);
    pages.rollback(changes[0..1]);
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 43000, .page = 1 }, own).?, "cde"));
    changes[0] = (try pages.stagePage(.{ .oid = 43000, .page = 1 }, null, third)).?;
    pages.publish(changes[0..1], 13);
    try expect(pages.page(.{ .oid = 43000, .page = 1 }, .{ .csn = 13 }) == null);
    try expect(pages.reclaim(12) == 0);
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 43000, .page = 1 }, .{ .csn = 12 }).?, "cde"));
    if (pages.stagePage(.{ .oid = 43000, .page = 1 }, "stale", concurrent)) |_| {
        return error.StaleWriterChangedPage;
    } else |err| try expect(err == error.SerializationFailure);
    try expect(pages.reclaim(13) == 1);
}

fn atomicCapacityFailure() !void {
    var backing: Backing(1, 4, 2, 8) = .{};
    var pages = try backing.open();
    var changes: [2]Pages.Change = undefined;
    const owner = writeView(1, 0, 5, 1, 1);
    changes[0] = (try pages.stagePage(.{ .oid = 500, .page = 0 }, "base", owner)).?;
    pages.publish(changes[0..1], 2);
    const replacement = writeView(2, 0, 6, 1, 2);
    if (pages.stageWrite(500, size - 1, "two pages", replacement, &changes)) |_| {
        return error.MissingCapacityError;
    } else |err| try expect(err == error.RowCapacity);
    var own = replacement.snapshot;
    own.cid += 1;
    try expect(std.mem.eql(u8, pages.page(.{ .oid = 500, .page = 0 }, own).?, "base"));
    try expect(pages.page(.{ .oid = 500, .page = 1 }, own) == null);
    if (pages.stageWrite(500, size - 1, "two pages", replacement, changes[0..1])) |_| {
        return error.MissingWriteSetError;
    } else |err| try expect(err == error.WriteSetCapacity);
    if (pages.stageWrite(500, large.max_size, "x", replacement, &changes)) |_| {
        return error.UncheckedOffset;
    } else |err| try expect(err == error.InvalidParameterValue);
}

fn savepointAndReclaim() !void {
    var backing: Backing(1, 3, 2, 8) = .{};
    var pages = try backing.open();
    const key: large.Key = .{ .oid = 41, .page = 0 };
    var changes: [2]Pages.Change = undefined;
    changes[0] = (try pages.stagePage(key, "old", writeView(5, 0, 10, 1, 5))).?;
    pages.publish(changes[0..1], 6);

    changes[0] = (try pages.stagePage(key, "kept", writeView(6, 0, 11, 1, 6))).?;
    var saved = writeView(6, 0, 11, 2, 6);
    saved.owner.sub = 1;
    changes[1] = (try pages.stagePage(key, "rolled back", saved)).?;
    saved.snapshot.cid += 1;
    try expect(std.mem.eql(u8, pages.page(key, saved.snapshot).?, "rolled back"));
    try expect(std.mem.eql(u8, pages.page(key, .{ .csn = 6 }).?, "old"));
    if (pages.stagePage(key, "overflow", saved)) |_| {
        return error.MissingVersionCapacityError;
    } else |err| try expect(err == error.VersionCapacity);
    pages.rollback(changes[1..2]);
    try expect(std.mem.eql(u8, pages.page(key, saved.snapshot).?, "kept"));
    pages.publish(changes[0..1], 7);
    try expect(pages.reclaim(6) == 0);
    try expect(std.mem.eql(u8, pages.page(key, .{ .csn = 6 }).?, "old"));
    try expect(pages.reclaim(7) == 1);
    try expect(std.mem.eql(u8, pages.page(key, .{ .csn = 7 }).?, "kept"));
}

var stress_backing: Backing(1024, 1152, 2048, 4096) = .{};

fn alignedTransfer() !void {
    var backing: Backing(8, 17, 16, 64) = .{};
    var pages = try backing.open();
    var changes: [8]Pages.Change = undefined;
    var input: [8 * size]u8 = undefined;
    for (&input, 0..) |*byte, index| byte.* = @truncate(index ^ (index / size));
    const first = writeView(1, 0, 12, 1, 1);
    try expect((try pages.stageWrite(42, 0, &input, first, &changes)) == 8);
    pages.publish(&changes, 2);
    const second = writeView(2, 0, 13, 1, 1);
    input[size - 1] = 29;
    input[size] = 73;
    try expect((try pages.stageWrite(42, 0, &input, second, &changes)) == 8);
    pages.publish(&changes, 3);
    var output: [input.len]u8 = undefined;
    try expect((try pages.read(42, input.len, 0, &output, .{ .csn = 3 })) == output.len);
    try expect(std.mem.eql(u8, &input, &output));
    try expect((try pages.read(42, input.len, size - 1, output[0..2], .{ .csn = 2 })) == 2);
    try expect(output[0] == 255 and output[1] == 1);
}

fn distantPages() !void {
    var pages = try stress_backing.open();
    const owner = writeView(1, 0, 7, 1, 1);
    const final_page: u32 = @intCast(large.max_size / size);
    var change: [1]Pages.Change = undefined;
    for (0..768) |index| {
        const position = large.max_size - 1 - @as(u64, index) * 1000003 * size;
        const value: u8 = @truncate(index);
        try expect((try pages.stageWrite(55000, position, &.{value}, owner, &change)) == 1);
        pages.publish(&change, 2);
    }
    const next = writeView(2, 0, 8, 1, 2);
    change[0] = (try pages.stagePage(.{ .oid = 55000, .page = final_page }, "", next)).?;
    pages.publish(&change, 3);
    try expect(pages.page(.{ .oid = 55000, .page = final_page }, .{ .csn = 3 }).?.len == 0);
    var bytes: [3]u8 = undefined;
    for (0..768) |index| {
        const position = large.max_size - 1 - @as(u64, index) * 1000003 * size;
        try expect((try pages.read(55000, large.max_size, position - 2, &bytes, .{ .csn = 3 })) == 3);
        try expect(bytes[0] == 0 and bytes[1] == 0 and bytes[2] == @as(u8, @truncate(index)));
    }
}

const DB = @import("sql").Database(.{
    .external_storage = true, .tables = 1, .columns = 8, .text_bytes = 4096,
    .rows_per_table = 4, .work_rows = 16, .result_rows = 16, .transactions = 4,
    .catalog_objects = 32, .tx_writes = 64,
});
const layout = large.Layout.plan(2) catch unreachable;
const Arena = struct {
    ordinary: [DB.backingBytes(4, 8, 64) catch unreachable]u8 align(@alignOf(DB.StorageVersion)) = undefined,
    pages: [layout.bytes]u8 align(large.Layout.alignment) = undefined,

    fn bind(self: *Arena, db: *DB) !void {
        try db.bindMemory(&self.ordinary, 4, 8, 64);
        try db.bindLargeObjectPages(try layout.backing(&self.pages));
    }
};
var primary: DB = .{};
var replica: DB = .{};
var copied: DB = .{};
var checkpointed: DB = .{};
var primary_arena: Arena = .{};
var replica_arena: Arena = .{};
var copy_arena: Arena = .{};
var checkpoint_arena: Arena = .{};
var replay_scratch: DB.ReplayScratch = .{};

fn queryBytes(db: *DB, sql: []const u8, expected: []const u8) !void {
    var result: DB.Result = .{};
    try db.execute(sql, &result);
    try expect(result.row_count == 1 and result.rows[0].cells[0] == .bytea);
    try expect(std.mem.eql(u8, result.rows[0].cells[0].bytea.slice(), expected));
}

fn executeWAL(db: *DB, sql: []const u8, wal: []u8) ![]u8 {
    var result: DB.Result = .{};
    var used: usize = 0;
    try db.executeChanges(sql, &result, wal, &used, null, null);
    try expect(used != 0);
    return wal[0..used];
}

fn rejectsReplay(db: *DB, wal: []const u8, wanted: anyerror) !void {
    const before = db.csn;
    if (db.applyChangeRecord(wal, &replay_scratch)) |_| return error.InvalidPageWALAccepted else |err| try expect(err == wanted);
    try expect(db.csn == before);
}

fn descriptorContract() !void {
    const command = @import("sql").large_object_command;
    const slot = try primary.begin();
    const reader = (try primary.largeObjectStatement(slot, .{ .open = .{ .oid = 55000, .mode = command.inv_read } }, &.{}, true)).int4;
    try primary.savepoint(slot, "inner");
    const removed = (try primary.largeObjectStatement(slot, .{ .open = .{ .oid = 55000, .mode = command.inv_read } }, &.{}, true)).int4;
    _ = try primary.rollbackTo(slot, "inner");
    if (primary.largeObjectStatement(slot, .{ .close = removed }, &.{}, true)) |_| return error.RolledBackDescriptorOpen else |err| try expect(err == error.InvalidParameterValue);
    const writer = (try primary.largeObjectStatement(slot, .{ .open = .{ .oid = 55000, .mode = command.inv_write } }, &.{}, true)).int4;
    _ = try primary.largeObjectStatement(slot, .{ .seek = .{ .fd = writer, .offset = 6, .whence = 0, .wide = true } }, &.{}, true);
    const request = (try command.parseSql("SELECT pg_catalog.lowrite(1,'\\x00FF')")).?.request.?;
    try expect((try primary.largeObjectStatement(slot, request, &.{}, true)).int4 == 2);
    _ = try primary.largeObjectStatement(slot, .{ .seek = .{ .fd = writer, .offset = 0, .whence = 0, .wide = false } }, &.{}, true);
    var bytes: [16]u8 = undefined;
    const written = (try primary.largeObjectStatement(slot, .{ .read = .{ .fd = writer, .count = 16 } }, &bytes, true)).bytes;
    try expect(std.mem.eql(u8, bytes[0..written], "abc\x00\x00\x00\x00\xff"));
    const original = (try primary.largeObjectStatement(slot, .{ .read = .{ .fd = reader, .count = 16 } }, &bytes, true)).bytes;
    try expect(std.mem.eql(u8, bytes[0..original], "abc"));
    primary.abort(slot);
    const next = try primary.begin();
    if (primary.largeObjectStatement(next, .{ .close = reader }, &.{}, true)) |_| return error.CommittedDescriptorOpen else |err| try expect(err == error.InvalidParameterValue);
    primary.abort(next);
}

fn sqlPageRecovery() !void {
    try primary_arena.bind(&primary);
    try replica_arena.bind(&replica);
    try copy_arena.bind(&copied);
    var wal: [4096]u8 = undefined;
    const creation = try executeWAL(&primary, "SELECT lo_from_bytea(55000,'abc'::bytea)", &wal);
    try queryBytes(&primary, "SELECT lo_get(55000)", "abc");
    try descriptorContract();
    try queryBytes(&primary, "SELECT lo_get(55000,1,3)", "bc");
    try queryBytes(&primary, "SELECT lo_get(55000,100,10)", "");
    const op = creation.len - 14;
    try expect(creation[op] == 72);
    try rejectsReplay(&replica, creation[0..creation.len - 1], error.InvalidChangeRecord);
    creation[op + 5] = 1;
    try rejectsReplay(&replica, creation, error.ChangeRecordConflict);
    creation[op + 5] = 0;
    try replica.applyChangeRecord(creation, &replay_scratch);
    try queryBytes(&replica, "SELECT lo_get(55000)", "abc");

    const slot = try primary.begin();
    try primary.savepoint(slot, "lo");
    var result: DB.Result = .{};
    try primary.statement(slot, "SELECT lo_unlink(55000)", &result, .{});
    try expect(result.rows[0].cells[0].integer == 1);
    _ = try primary.rollbackTo(slot, "lo");
    try primary.statement(slot, "SELECT lo_get(55000)", &result, .{});
    try expect(std.mem.eql(u8, result.rows[0].cells[0].bytea.slice(), "abc"));
    primary.abort(slot);

    try copied.copyFromInto(&primary);
    try queryBytes(&copied, "SELECT lo_get(55000)", "abc");

    const role = try executeWAL(&primary, "CREATE ROLE page_reader", &wal);
    try replica.applyChangeRecord(role, &replay_scratch);
    try primary.execute("SET ROLE page_reader", &result);
    if (primary.execute("SELECT lo_get(55000)", &result)) |_| return error.UnauthorizedPageRead else |err| try expect(err == error.InsufficientPrivilege);
    try primary.execute("RESET ROLE", &result);
    const acl = try executeWAL(&primary, "GRANT SELECT ON LARGE OBJECT 55000 TO page_reader", &wal);
    try replica.applyChangeRecord(acl, &replay_scratch);
    try replica.execute("SET ROLE page_reader", &result);
    try queryBytes(&replica, "SELECT lo_get(55000)", "abc");
    try replica.execute("RESET ROLE", &result);

    // A syntactically valid record that drops the metadata alone would
    // leave an orphan page. Validate the entire frame before publishing.
    const removal = try executeWAL(&primary, "SELECT lo_unlink(55000)", &wal);
    try expect(removal[8] == 72);
    var orphan: [1024]u8 = undefined;
    @memcpy(orphan[0..8], removal[0..8]);
    orphan[4] -= 1;
    @memcpy(orphan[8..][0..removal.len - 19], removal[19..]);
    try rejectsReplay(&replica, orphan[0..removal.len - 11], error.ChangeRecordConflict);
    try queryBytes(&replica, "SELECT lo_get(55000)", "abc");
    try replica.applyChangeRecord(removal, &replay_scratch);
    try queryBytes(&copied, "SELECT lo_get(55000)", "abc");
    if (replica.execute("SELECT lo_get(55000)", &result)) |_| return error.DeletedPageStillVisible else |err| try expect(err == error.UndefinedObject);

    const crossed = try executeWAL(&primary, "SELECT lo_from_bytea(55000,'" ++ "A" ** size ++ "BCD'::bytea)", &wal);
    try replica.applyChangeRecord(crossed, &replay_scratch);
    try queryBytes(&replica, "SELECT lo_get(55000,2047,4)", "ABCD");
    try queryBytes(&primary, "SELECT lo_get(55000,2047,4)", "ABCD");
    if (primary.execute("SELECT lo_from_bytea(55001,'full'::bytea)", &result)) |_| return error.FullPageArenaAccepted else |err| try expect(err == error.RowCapacity);
    try primary.execute("SELECT COUNT(*) FROM pg_largeobject_metadata WHERE oid=55001", &result);
    try expect(result.rows[0].cells[0].integer == 0);
}

const ImageBuffer = struct {
    bytes: [16384]u8 = undefined,
    used: usize = 0,

    pub fn appendAll(self: *ImageBuffer, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.used) return error.BufferTooSmall;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    pub fn length(self: *const ImageBuffer) !u64 {
        return self.used;
    }

    pub fn readAt(self: *const ImageBuffer, offset: u64, output: []u8) !usize {
        if (offset > self.used) return 0;
        const at: usize = @intCast(offset);
        const count = @min(output.len, self.used - at);
        @memcpy(output[0..count], self.bytes[at..][0..count]);
        return count;
    }
};

fn compactRoundTrip() !void {
    var image: ImageBuffer = .{};
    var bytes: [4096]u8 = undefined;
    var result: DB.Result = .{};
    try primary.execute("GRANT SELECT ON LARGE OBJECT 55000 TO page_reader", &result);
    try primary.execute("COMMENT ON LARGE OBJECT 55000 IS 'compact bytes'", &result);
    try DB.BaseSnapshot.write(&primary, &image, &bytes);
    try expect(std.mem.eql(u8, image.bytes[0..8], "RSBASE06"));
    try expect(image.used < 3072);

    try checkpoint_arena.bind(&checkpointed);
    try DB.BaseSnapshot.restore(&checkpointed, &image, primary.csn, &bytes, &replay_scratch);
    try checkpointed.execute("SET ROLE page_reader", &result);
    try queryBytes(&checkpointed, "SELECT lo_get(55000,2047,4)", "ABCD");
    try checkpointed.execute("RESET ROLE", &result);
    try checkpointed.execute("SELECT obj_description(oid,'pg_largeobject') FROM pg_largeobject_metadata WHERE oid=55000", &result);
    try expect(std.mem.eql(u8, result.rows[0].cells[0].text.slice(), "compact bytes"));
    const suffix = try executeWAL(&primary, "SELECT lo_unlink(55000)", &bytes);
    try checkpointed.applyChangeRecord(suffix, &replay_scratch);
    try checkpointed.execute("SELECT COUNT(*) FROM pg_largeobject WHERE loid=55000", &result);
    try expect(result.rows[0].cells[0].integer == 0);
}

fn truncateRecovery() !void {
    const command = @import("sql").large_object_command;
    const wide_end = large.max_size;
    var wal: [4096]u8 = undefined;
    var result: DB.Result = .{};
    const creation = try executeWAL(&primary, "SELECT lo_from_bytea(55010,'abcdef'::bytea)", &wal);
    try checkpointed.applyChangeRecord(creation, &replay_scratch);
    const slot = try primary.begin();
    const descriptor = (try primary.largeObjectStatement(slot, .{ .open = .{ .oid = 55010, .mode = command.inv_write } }, &.{}, true)).int4;
    const frozen = (try primary.largeObjectStatement(slot, .{ .open = .{ .oid = 55010, .mode = command.inv_read } }, &.{}, true)).int4;
    try expect(descriptor == 0);
    _ = try primary.largeObjectStatement(slot, .{ .seek = .{ .fd = descriptor, .offset = 4, .whence = 0, .wide = true } }, &.{}, true);

    try primary.savepoint(slot, "truncate");
    try primary.statement(slot, "SELECT lo_truncate64(0,6149)", &result, .{});
    try expect(result.rows[0].cells[0].integer == 0);
    try expect((try primary.largeObjectStatement(slot, .{ .tell = .{ .fd = descriptor, .wide = true } }, &.{}, true)).int8 == 4);
    try primary.statement(slot, "SELECT lo_get(55010,6145,16)", &result, .{});
    try expect(std.mem.eql(u8, result.rows[0].cells[0].bytea.slice(), &.{0, 0, 0, 0}));
    var old: [12]u8 = undefined;
    const prior = (try primary.largeObjectStatement(slot, .{ .read = .{ .fd = frozen, .count = 12 } }, &old, true)).bytes;
    try expect(std.mem.eql(u8, old[0..prior], "abcdef"));
    _ = try primary.rollbackTo(slot, "truncate");
    try primary.statement(slot, "SELECT lo_get(55010)", &result, .{});
    try expect(std.mem.eql(u8, result.rows[0].cells[0].bytea.slice(), "abcdef"));

    _ = try primary.largeObjectStatement(slot, .{ .truncate = .{ .fd = descriptor, .length = wide_end } }, &.{}, true);
    try expect((try primary.largeObjectStatement(slot, .{ .seek = .{ .fd = descriptor, .offset = 0, .whence = 2, .wide = true } }, &.{}, true)).int8 == wide_end);
    const growth = try primary.prepareCommit(slot, &wal);
    try expect(growth.len < 256);
    try checkpointed.applyChangeRecord(growth, &replay_scratch);
    primary.publishCommit(slot);
    try checkpointed.execute("SELECT COUNT(*) FROM pg_largeobject WHERE loid=55010", &result);
    try expect(result.rows[0].cells[0].integer == 2);
    try checkpointed.execute("SELECT data FROM pg_largeobject WHERE loid=55010 AND pageno=2147483647", &result);
    try expect(result.row_count == 1 and result.rows[0].cells[0].bytea.len == 0);

    const shrink = try primary.begin();
    _ = try primary.largeObjectStatement(shrink, .{ .open = .{ .oid = 55010, .mode = command.inv_write } }, &.{}, true);
    try primary.statement(shrink, "SELECT lo_truncate(0,2)", &result, .{});
    try primary.statement(shrink, "SELECT lo_truncate(0,9)", &result, .{});
    const shrink_growth = try primary.prepareCommit(shrink, &wal);
    try checkpointed.applyChangeRecord(shrink_growth, &replay_scratch);
    primary.publishCommit(shrink);
    try queryBytes(&checkpointed, "SELECT lo_get(55010)", &.{ 'a', 'b', 0, 0, 0, 0, 0, 0, 0 });

    const zero = try primary.begin();
    _ = try primary.largeObjectStatement(zero, .{ .open = .{ .oid = 55010, .mode = command.inv_write } }, &.{}, true);
    try primary.statement(zero, "SELECT lo_truncate(0,0)", &result, .{});
    const clear = try primary.prepareCommit(zero, &wal);
    try checkpointed.applyChangeRecord(clear, &replay_scratch);
    primary.publishCommit(zero);
    try checkpointed.execute("SELECT data FROM pg_largeobject WHERE loid=55010 AND pageno=0", &result);
    try expect(result.row_count == 1 and result.rows[0].cells[0].bytea.len == 0);

    const removal = try executeWAL(&primary, "SELECT lo_unlink(55010)", &wal);
    try expect(removal[8] == 72 and removal[4] == 2);
    var orphan: [128]u8 = undefined;
    @memcpy(orphan[0..8], removal[0..8]);
    orphan[4] -= 1;
    @memcpy(orphan[8..][0..removal.len - 19], removal[19..]);
    try rejectsReplay(&checkpointed, orphan[0..removal.len - 11], error.ChangeRecordConflict);
    try checkpointed.applyChangeRecord(removal, &replay_scratch);
    try checkpointed.execute("SELECT COUNT(*) FROM pg_largeobject WHERE loid=55010", &result);
    try expect(result.rows[0].cells[0].integer == 0);
}

const FileFixture = struct {
    var input: [3001]u8 = undefined;
    var output: [3001]u8 = undefined;
    var offset: usize = 0;
    var written: usize = 0;
    var opens: usize = 0;
    var closes: usize = 0;
    var fail_read: bool = false;
    var fail_close: bool = false;

    pub fn open(path: []const u8, writing: bool) !usize {
        if (std.mem.eql(u8, path, "absent")) return error.FileNotFound;
        if (std.mem.eql(u8, path, "denied")) return error.FilePermissionDenied;
        opens += 1;
        offset = 0;
        written = 0;
        return if (writing) 2 else 1;
    }

    pub fn read(_: usize, bytes: []u8) !usize {
        if (fail_read) return error.FileReadFailed;
        const count = @min(17, @min(bytes.len, input.len - offset));
        @memcpy(bytes[0..count], input[offset..][0..count]);
        offset += count;
        return count;
    }

    pub fn write(_: usize, bytes: []const u8) !void {
        if (bytes.len > output.len - written) return error.FileWriteFailed;
        @memcpy(output[written..][0..bytes.len], bytes);
        written += bytes.len;
    }

    pub fn close(_: usize) !void {
        closes += 1;
        if (fail_close) return error.FileCloseFailed;
    }
};

var file_db: DB = .{};
var file_replay: DB = .{};
var file_arena: Arena = .{};
var file_replay_arena: Arena = .{};

fn fileTransfers() !void {
    try file_arena.bind(&file_db);
    try file_replay_arena.bind(&file_replay);
    const Access = @import("sql").LargeObjectFiles;
    file_db.setLargeObjectFiles(Access.native(FileFixture));
    for (&FileFixture.input, 0..) |*byte, index| byte.* = @truncate(index * 17);
    var wal: [8192]u8 = undefined;
    const creation = try executeWAL(&file_db, "SELECT lo_import('source',56000)", &wal);
    try file_replay.applyChangeRecord(creation, &replay_scratch);
    var result: DB.Result = .{};
    try file_replay.execute("SELECT lo_get(56000)", &result);
    try expect(std.mem.eql(u8, result.rows[0].cells[0].bytea.slice(), &FileFixture.input));
    try file_db.execute("SELECT lo_export(56000,'output')", &result);
    try expect(result.rows[0].cells[0].integer == 1);
    try expect(FileFixture.written == FileFixture.input.len);
    try expect(std.mem.eql(u8, &FileFixture.output, &FileFixture.input));
    try expect(FileFixture.opens == FileFixture.closes);

    try file_db.execute("CREATE ROLE file_reader", &result);
    try file_db.execute("SET ROLE file_reader", &result);
    const previous = FileFixture.opens;
    if (file_db.execute("SELECT lo_import('source')", &result)) |_| return error.UnprivilegedFileImport else |err| try expect(err == error.InsufficientPrivilege);
    if (file_db.execute("SELECT lo_export(56000,'output')", &result)) |_| return error.UnprivilegedFileExport else |err| try expect(err == error.InsufficientPrivilege);
    try expect(FileFixture.opens == previous);
    try file_db.execute("RESET ROLE", &result);
    try file_db.execute("SELECT lo_unlink(56000)", &result);
    if (file_db.execute("SELECT lo_import('absent',56001)", &result)) |_| return error.MissingFileAccepted else |err| try expect(err == error.UndefinedFile);
    if (file_db.execute("SELECT lo_import('denied',56001)", &result)) |_| return error.DeniedFileAccepted else |err| try expect(err == error.InsufficientPrivilege);
    FileFixture.fail_read = true;
    if (file_db.execute("SELECT lo_import('source',56001)", &result)) |_| return error.FailedReadCommitted else |err| try expect(err == error.FileAccessFailure);
    FileFixture.fail_read = false;
    FileFixture.fail_close = true;
    if (file_db.execute("SELECT lo_import('source',56001)", &result)) |_| return error.FailedCloseCommitted else |err| try expect(err == error.FileAccessFailure);
    FileFixture.fail_close = false;
    try file_db.execute("SELECT COUNT(*) FROM pg_largeobject_metadata WHERE oid=56001", &result);
    try expect(result.rows[0].cells[0].integer == 0);
    try expect(FileFixture.opens == FileFixture.closes);
}

var grant_db: DB = .{};
var grant_replay: DB = .{};
var grant_checkpoint: DB = .{};
var grant_arena: Arena = .{};
var grant_replay_arena: Arena = .{};
var grant_checkpoint_arena: Arena = .{};

fn grantBoth(statement: []const u8) !void {
    var wal: [8192]u8 = undefined;
    try grant_replay.applyChangeRecord(try executeWAL(&grant_db, statement, &wal), &replay_scratch);
}

fn deniedFile(db: *DB, statement: []const u8) !void {
    var result: DB.Result = .{};
    const before = FileFixture.opens;
    if (db.execute(statement, &result)) |_| return error.UnauthorizedFileCall else |err| try expect(err == error.InsufficientPrivilege);
    try expect(before == FileFixture.opens);
}

fn fileExecuteGrants() !void {
    try grant_arena.bind(&grant_db);
    try grant_replay_arena.bind(&grant_replay);
    const Access = @import("sql").LargeObjectFiles;
    grant_db.setLargeObjectFiles(Access.native(FileFixture));
    grant_replay.setLargeObjectFiles(Access.native(FileFixture));
    var result: DB.Result = .{};
    try grantBoth("CREATE ROLE file_delegate");
    try grantBoth("CREATE ROLE file_member");
    try grantBoth("GRANT file_delegate TO file_member");
    try grantBoth("GRANT EXECUTE ON FUNCTION pg_catalog.lo_import(text,oid) TO file_delegate WITH GRANT OPTION");
    for ([_]*DB{ &grant_db, &grant_replay }) |db| {
        try db.execute("SET ROLE file_member", &result);
        try db.execute("SELECT lo_import(NULL::text,0::oid)", &result);
        try expect(result.rows[0].cells[0] == .null_value);
        try deniedFile(db, "SELECT lo_import(NULL::text)");
        try deniedFile(db, "SELECT lo_export(NULL::oid,NULL::text)");
        try db.execute("RESET ROLE", &result);
    }
    try grant_db.execute("SET ROLE file_delegate", &result);
    try grantBoth("GRANT ALL ON FUNCTION lo_import(text,oid) TO file_member");
    try grant_db.execute("RESET ROLE", &result);
    if (grant_db.execute("REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION lo_import(text,oid) FROM file_delegate", &result)) |_| return error.DependentGrantLost else |err| try expect(err == error.DependentObjects);
    try grantBoth("REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION lo_import(text,oid) FROM file_delegate CASCADE");
    try grantBoth("REVOKE file_delegate FROM file_member");
    try grant_replay.execute("SET ROLE file_member", &result);
    try deniedFile(&grant_replay, "SELECT lo_import(NULL::text,0::oid)");
    try grant_replay.execute("RESET ROLE", &result);
    try grant_db.execute("SET ROLE file_delegate", &result);
    var wal: [8192]u8 = undefined;
    try grant_replay.applyChangeRecord(try executeWAL(&grant_db, "SELECT lo_import('source',56020)", &wal), &replay_scratch);
    try grant_db.execute("RESET ROLE", &result);
    try grantBoth("GRANT EXECUTE ON FUNCTION lo_export(oid,text) TO file_member");
    try grant_db.execute("SET ROLE file_member", &result);
    try deniedFile(&grant_db, "SELECT lo_export(56020,'output')");
    try grant_db.execute("RESET ROLE", &result);
    try grant_db.execute("SET ROLE file_delegate", &result);
    try grantBoth("GRANT SELECT ON LARGE OBJECT 56020 TO file_member");
    try grant_db.execute("RESET ROLE", &result);
    try grant_db.execute("SET ROLE file_member", &result);
    try grant_db.execute("SELECT lo_export(56020,'output')", &result);
    try expect(FileFixture.written == FileFixture.input.len);
    try grant_db.execute("RESET ROLE", &result);
    try grantBoth("GRANT EXECUTE ON FUNCTION lo_import(text) TO PUBLIC");
    const tx = try grant_db.begin();
    try grant_db.statement(tx, "REVOKE EXECUTE ON FUNCTION lo_import(text) FROM PUBLIC", &result, .{});
    grant_db.abort(tx);
    try grant_db.execute("SET ROLE file_member", &result);
    try grant_db.execute("SELECT lo_import(NULL::text)", &result);
    try grant_db.execute("RESET ROLE", &result);
    if (grant_db.execute("DROP ROLE file_member", &result)) |_| return error.GrantRoleDependencyLost else |err| try expect(err == error.DependentObjects);
    var image: ImageBuffer = .{};
    try DB.BaseSnapshot.write(&grant_db, &image, &wal);
    try expect(std.mem.eql(u8, image.bytes[0..8], "RSBASE08"));
    try grant_checkpoint_arena.bind(&grant_checkpoint);
    try DB.BaseSnapshot.restore(&grant_checkpoint, &image, grant_db.csn, &wal, &replay_scratch);
    grant_checkpoint.setLargeObjectFiles(Access.native(FileFixture));
    try grant_checkpoint.execute("SET ROLE file_member", &result);
    try grant_checkpoint.execute("SELECT lo_export(56020,'output')", &result);
    try grant_checkpoint.execute("SELECT lo_import(NULL::text)", &result);
    try grant_checkpoint.execute("RESET ROLE", &result);
    const revoked = try executeWAL(&grant_db, "REVOKE ALL PRIVILEGES ON FUNCTION pg_catalog.lo_export(oid,text) FROM file_member", &wal);
    try grant_replay.applyChangeRecord(revoked, &replay_scratch);
    try grant_checkpoint.applyChangeRecord(revoked, &replay_scratch);
    for ([_]*DB{ &grant_db, &grant_replay, &grant_checkpoint }) |db| {
        try db.execute("SET ROLE file_member", &result);
        try deniedFile(db, "SELECT lo_export(56020,'output')");
        try db.execute("RESET ROLE", &result);
    }
}

pub fn main(init: std.process.Init) !void {
    try snapshotAndSparseRead();
    try atomicCapacityFailure();
    try savepointAndReclaim();
    try alignedTransfer();
    try distantPages();
    try sqlPageRecovery();
    try compactRoundTrip();
    try truncateRecovery();
    try fileTransfers();
    try fileExecuteGrants();
    var line: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&line, "{{\"suite\":\"sql-large-object-pages\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
