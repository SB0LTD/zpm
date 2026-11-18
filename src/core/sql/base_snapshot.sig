//! Bounded logical image of one committed public base table.
//! The caller freezes the source and owns an unpublished, fresh destination.
//! The caller verifies the enclosing snapshot seal before publication.
const std = @import("std");
const types = @import("types.sig");
const storage = @import("storage.sig");
const objects = @import("catalog_objects.sig");
const change_log = @import("change_log.sig");

const magic = "RSBASE01";
const header_size = 24;
const part_size = 5;

fn appendPart(sink: anytype, kind: change_log.Op, record: []const u8) !void {
    var header: [part_size]u8 = undefined;
    header[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(record.len), .little);
    try sink.appendAll(&header);
    try sink.appendAll(record);
}

fn readExact(file: anytype, offset: u64, out: []u8, length: u64) !void {
    if (offset > length or out.len > length - offset) return error.InvalidSnapshotImage;
    var used: usize = 0;
    while (used < out.len) {
        const n = try file.readAt(offset + used, out[used..]);
        if (n == 0 or n > out.len - used) return error.InvalidSnapshotImage;
        used += n;
    }
}

pub fn Image(comptime config: types.Config, comptime Database: type) type {
    const S = storage.Storage(config);
    const O = objects.Objects(config);
    const C = change_log.ChangeLog(config);

    return struct {
        fn checkCatalog(db: *const Database) !void {
            for (&db.txs) |*tx| if (tx.active) return error.SnapshotUnsupportedState;
            for (&db.schemas) |*schema| if (schema.live) return error.SnapshotUnsupportedState;
            for (&db.seqs) |*seq| if (seq.live) return error.SnapshotUnsupportedState;
            const snap: storage.Snapshot = .{ .csn = db.csn };
            for (&db.catalog_objects.items) |*object| if (O.visible(object, snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.routines) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.triggers) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.rules) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
        }

        fn exportBank(db: *const Database) !usize {
            try checkCatalog(db);
            var selected: ?usize = null;
            for (&db.tables, 0..) |*table, bank| {
                if (!S.committedTable(table)) continue;
                if (selected != null or !C.supportsBaseImage(table)) return error.SnapshotUnsupportedState;
                selected = bank;
            }
            const bank = selected orelse return error.SnapshotUnsupportedState;
            const table = &db.tables[bank];
            for (db.tables[0..bank]) |*earlier| {
                if (S.createBankFits(earlier, table.columns[0..table.column_count], 0)) return error.SnapshotUnsupportedState;
            }
            return bank;
        }

        /// Write a schema definition, batches of committed rows and exact
        /// allocation counters. Scratch need only hold one schema or row.
        pub fn write(db: *const Database, sink: anytype, scratch: []u8) !void {
            if (scratch.len > 0xffffffff or config.tx_writes == 0) return error.SnapshotWorkspaceTooSmall;
            const bank = try exportBank(db);
            const table = &db.tables[bank];
            if (db.csn == 0) return error.SnapshotUnsupportedState;
            var definition = try change_log.Writer.init(scratch, 0);
            try C.encodeCreate(&definition, table);
            const definition_len = try definition.finish();
            var header: [header_size]u8 = undefined;
            @memcpy(header[0..8], magic);
            std.mem.writeInt(u64, header[8..16], db.csn, .little);
            std.mem.writeInt(u32, header[16..20], @intCast(bank), .little);
            std.mem.writeInt(u32, header[20..24], @intCast(S.liveRows(table)), .little);
            try sink.appendAll(&header);
            try appendPart(sink, .create_table, scratch[0..definition_len]);

            var row: S.VersionRowScratch = undefined;
            var position: usize = 0;
            while (position < table.row_high) {
                var batch = try change_log.Writer.init(scratch, 0);
                while (position < table.row_high and batch.ops < config.tx_writes) {
                    const version = S.visible(table, position) orelse {
                        position += 1;
                        continue;
                    };
                    var next = batch;
                    C.encodeRow(&next, .insert, table.oid, table.rows[position].rowid, S.versionValues(table, version, &row)) catch |err| {
                        if (err == error.TransactionLogCapacity and batch.ops != 0) break;
                        return err;
                    };
                    batch = next;
                    position += 1;
                }
                if (batch.ops != 0) try appendPart(sink, .insert, scratch[0..try batch.finish()]);
            }
            var counters = try change_log.Writer.init(scratch, 0);
            try C.encodeCounters(&counters, change_log.first_oid + db.oid_counter, &db.tables);
            try appendPart(sink, .catalog_counters, scratch[0..try counters.finish()]);
        }

        /// A failure discards this staged destination. The enclosing receipt
        /// provides the expected SQL CSN independently of the WAL sequence.
        pub fn restore(db: *Database, file: anytype, expected_csn: u64, scratch: []u8, replay: *C.Scratch) !void {
            try checkCatalog(db);
            if (db.csn != 0 or db.oid_counter != 0) return error.SnapshotUnsupportedState;
            for (&db.tables) |*table| if (table.live) return error.SnapshotUnsupportedState;
            if (comptime config.external_storage) if (db.workspace.query.refs.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_workspace) if (db.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            const length: u64 = try file.length();
            var header: [header_size]u8 = undefined;
            try readExact(file, 0, &header, length);
            if (!std.mem.eql(u8, header[0..8], magic)) return error.InvalidSnapshotImage;
            const csn = std.mem.readInt(u64, header[8..16], .little);
            const bank = std.mem.readInt(u32, header[16..20], .little);
            const rows = std.mem.readInt(u32, header[20..24], .little);
            if (csn == 0 or csn != expected_csn or bank >= db.tables.len or rows > db.tables[bank].rows.len) return error.InvalidSnapshotImage;

            var offset: u64 = header_size;
            var defined = false;
            var restored_rows: u32 = 0;
            while (offset < length) {
                var part: [part_size]u8 = undefined;
                try readExact(file, offset, &part, length);
                offset += part.len;
                const count = std.mem.readInt(u32, part[1..5], .little);
                if (count > scratch.len) return error.SnapshotWorkspaceTooSmall;
                const record = scratch[0..count];
                try readExact(file, offset, record, length);
                offset += count;
                if (!defined) {
                    if (part[0] != @intFromEnum(change_log.Op.create_table)) return error.InvalidSnapshotImage;
                    try C.applyBaseImageRecord(db, record, replay, csn, bank, .create_table);
                    defined = true;
                } else if (part[0] == @intFromEnum(change_log.Op.insert)) {
                    const added = try change_log.opCount(record);
                    if (added > rows - restored_rows) return error.InvalidSnapshotImage;
                    try C.applyBaseImageRecord(db, record, replay, csn, bank, .insert);
                    restored_rows += added;
                } else if (part[0] == @intFromEnum(change_log.Op.catalog_counters)) {
                    if (offset != length or restored_rows != rows or try file.length() != length) return error.InvalidSnapshotImage;
                    return C.applyBaseImageRecord(db, record, replay, csn, bank, .catalog_counters);
                } else return error.InvalidSnapshotImage;
            }
            return error.InvalidSnapshotImage;
        }
    };
}
