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
            return Pages.init(.{
                .rows = &self.rows, .versions = &self.versions, .version_rows = &self.payloads,
                .row_index = &self.row_index, .key_index = &self.key_index,
            });
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

pub fn main(init: std.process.Init) !void {
    try snapshotAndSparseRead();
    try atomicCapacityFailure();
    try savepointAndReclaim();
    try alignedTransfer();
    try distantPages();
    var line: [160]u8 = undefined;
    const report = try std.fmt.bufPrint(&line, "{{\"suite\":\"sql-large-object-pages\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
