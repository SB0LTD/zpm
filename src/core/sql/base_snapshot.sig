//! Bounded logical image of committed public base tables and sequences.
//! The caller freezes the source and owns an unpublished, fresh destination.
//! The caller verifies the enclosing snapshot seal before publication.
const std = @import("std");
const types = @import("types.sig");
const storage = @import("storage.sig");
const catalog = @import("catalog.sig");
const objects = @import("catalog_objects.sig");
const change_log = @import("change_log.sig");

const single_magic = "RSBASE01";
const multi_magic = "RSBASE02";
const sequence_magic = "RSBASE03";
const defaults_magic = "RSBASE04";
const header_size = 24;
const table_header_size = 8;
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

fn readPart(file: anytype, offset: *u64, length: u64, scratch: []u8, kind: change_log.Op) ![]u8 {
    var part: [part_size]u8 = undefined;
    try readExact(file, offset.*, &part, length);
    offset.* += part.len;
    if (part[0] != @intFromEnum(kind)) return error.InvalidSnapshotImage;
    const count = std.mem.readInt(u32, part[1..5], .little);
    if (count > scratch.len) return error.SnapshotWorkspaceTooSmall;
    const record = scratch[0..count];
    try readExact(file, offset.*, record, length);
    offset.* += count;
    return record;
}

pub fn Image(comptime config: types.Config, comptime Database: type) type {
    const S = storage.Storage(config);
    const O = objects.Objects(config);
    const C = change_log.ChangeLog(config);

    return struct {
        fn checkCatalog(db: *const Database) !void {
            for (&db.txs) |*tx| if (tx.active) return error.SnapshotUnsupportedState;
            for (&db.schemas) |*schema| if (schema.live) return error.SnapshotUnsupportedState;
            const snap: storage.Snapshot = .{ .csn = db.csn };
            for (&db.catalog_objects.items) |*object| if (O.visible(object, snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.routines) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.triggers) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
            for (&db.objects.rules) |*item| if (item.live and item.stamp.visible(snap)) return error.SnapshotUnsupportedState;
        }

        fn exportTables(db: *const Database) !struct { count: usize, first_bank: usize, with_defaults: bool } {
            try checkCatalog(db);
            if (db.csn == 0) return error.SnapshotUnsupportedState;
            var count: usize = 0;
            var first_bank: usize = 0;
            var with_defaults = false;
            for (&db.tables, 0..) |*table, bank| {
                if (!S.committedTable(table)) continue;
                if (!C.supportsBaseImage(table)) return error.SnapshotUnsupportedState;
                for (table.columns[0..table.column_count]) |*column| {
                    with_defaults = with_defaults or column.default_kind != .none;
                }
                // Earlier committed banks are installed first. An earlier
                // vacant compatible bank would change first-fit placement
                // on restore and could change where WAL suffix DDL lands.
                for (db.tables[0..bank]) |*earlier| {
                    if (!S.committedTable(earlier) and S.createBankFits(earlier, table.columns[0..table.column_count], 0))
                        return error.SnapshotUnsupportedState;
                }
                if (count == 0) first_bank = bank;
                count += 1;
            }
            return .{ .count = count, .first_bank = first_bank, .with_defaults = with_defaults };
        }

        /// The identity generator is part of the column definition. An
        /// ordinary owned sequence may coexist with other automatic links.
        fn validSequenceOwnership(db: *const Database) bool {
            const Bits = std.StaticBitSet(config.columns);
            var linked: [config.tables]Bits = @splat(.empty);
            for (&db.seqs) |*seq| {
                if (!seq.live or seq.dead_csn != 0) continue;
                if (seq.owner == 0) {
                    if (seq.owner_column != 0) return false;
                    continue;
                }
                const bank = for (&db.tables, 0..) |*table, index| {
                    if (S.committedTable(table) and table.oid == seq.owner) break index;
                } else return false;
                const owner = &db.tables[bank];
                if (seq.namespace != owner.namespace or seq.owner_column >= owner.column_count) return false;
                const column = &owner.columns[seq.owner_column];
                if (column.default_kind == .identity_always or column.default_kind == .identity_by_default) {
                    if (linked[bank].isSet(seq.owner_column)) return false;
                    linked[bank].set(seq.owner_column);
                }
            }
            for (&db.tables, &linked) |*table, *set| {
                if (!S.committedTable(table)) continue;
                for (table.columns[0..table.column_count], 0..) |*column, index| {
                    if ((column.default_kind == .identity_always or column.default_kind == .identity_by_default) and
                        !set.isSet(index)) return false;
                }
            }
            return true;
        }

        /// Write schema definitions, batches of committed rows and exact
        /// allocation counters. Scratch need only hold one schema or row.
        pub fn write(db: *const Database, sink: anytype, scratch: []u8) !void {
            if (scratch.len > 0xffffffff or config.tx_writes == 0) return error.SnapshotWorkspaceTooSmall;
            const selected = try exportTables(db);
            var sequence_count: usize = 0;
            var with_defaults = selected.with_defaults;
            for (&db.seqs) |*seq| {
                if (!seq.live or seq.dead_csn != 0) continue;
                if (seq.pending_create or seq.pending_drop or seq.namespace != catalog.public_namespace)
                    return error.SnapshotUnsupportedState;
                with_defaults = with_defaults or seq.owner != 0;
                sequence_count += 1;
            }
            if (with_defaults and !validSequenceOwnership(db)) return error.SnapshotUnsupportedState;
            if (selected.count == 0 and sequence_count == 0) return error.SnapshotUnsupportedState;
            if (sequence_count != 0 and config.tx_writes < 2) return error.SnapshotWorkspaceTooSmall;
            var header: [header_size]u8 = undefined;
            std.mem.writeInt(u64, header[8..16], db.csn, .little);
            if (selected.count == 1 and sequence_count == 0 and !with_defaults) {
                @memcpy(header[0..8], single_magic);
                const table = &db.tables[selected.first_bank];
                writeTableHeader(header[16..24], selected.first_bank, table);
                try sink.appendAll(&header);
                try writeTable(table, sink, scratch);
            } else {
                @memcpy(header[0..8], if (with_defaults) defaults_magic else if (sequence_count == 0) multi_magic else sequence_magic);
                std.mem.writeInt(u32, header[16..20], @intCast(selected.count), .little);
                std.mem.writeInt(u32, header[20..24], @intCast(sequence_count), .little);
                try sink.appendAll(&header);
                for (&db.tables, 0..) |*table, bank| {
                    if (!S.committedTable(table)) continue;
                    var table_header: [table_header_size]u8 = undefined;
                    writeTableHeader(&table_header, bank, table);
                    try sink.appendAll(&table_header);
                    try writeTable(table, sink, scratch);
                }
            }
            if (sequence_count != 0) for (&db.seqs) |*seq| {
                if (!seq.live or seq.dead_csn != 0) continue;
                var state = try change_log.Writer.init(scratch, 0);
                try C.encodeCreateSequence(&state, seq, false);
                // Preserve the WAL's reservation boundary, including numbers
                // reserved in live session caches that restart discards.
                try C.encodeSequenceValue(&state, seq.oid, seq.logged_value, seq.logged_called);
                try appendPart(sink, .create_sequence, scratch[0..try state.finish()]);
            };
            var counters = try change_log.Writer.init(scratch, 0);
            try C.encodeCounters(&counters, change_log.first_oid + db.oid_counter, db.next_constraint_oid, db.next_default_oid, &db.tables);
            try appendPart(sink, .catalog_counters, scratch[0..try counters.finish()]);
        }

        fn writeTableHeader(header: *[table_header_size]u8, bank: usize, table: *const S.Table) void {
            std.mem.writeInt(u32, header[0..4], @intCast(bank), .little);
            std.mem.writeInt(u32, header[4..8], @intCast(S.liveRows(table)), .little);
        }

        fn writeTable(table: *const S.Table, sink: anytype, scratch: []u8) !void {
            var definition = try change_log.Writer.init(scratch, 0);
            try C.encodeCreate(&definition, table);
            try appendPart(sink, .create_table, scratch[0..try definition.finish()]);

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
        }

        fn restoreTable(db: *Database, file: anytype, length: u64, offset: *u64, header: *const [table_header_size]u8, csn: u64, previous_bank: ?usize, scratch: []u8, replay: *C.Scratch, with_defaults: bool) !usize {
            const bank = std.mem.readInt(u32, header[0..4], .little);
            const rows = std.mem.readInt(u32, header[4..8], .little);
            if (bank >= db.tables.len or (previous_bank != null and bank <= previous_bank.?) or
                rows > db.tables[bank].rows.len or rows > db.tables[bank].versions.len) return error.InvalidSnapshotImage;
            const definition = try readPart(file, offset, length, scratch, .create_table);
            try C.applyBaseImageRecord(db, definition, replay, .{ .csn = csn, .op = .create_table, .bank = bank, .with_defaults = with_defaults });
            var remaining = rows;
            while (remaining != 0) {
                const record = try readPart(file, offset, length, scratch, .insert);
                const added = try change_log.opCount(record);
                if (added == 0 or added > remaining) return error.InvalidSnapshotImage;
                try C.applyBaseImageRecord(db, record, replay, .{ .csn = csn, .op = .insert, .bank = bank });
                remaining -= added;
            }
            return bank;
        }

        /// A failure discards this staged destination. The enclosing receipt
        /// provides the expected SQL CSN independently of the WAL sequence.
        pub fn restore(db: *Database, file: anytype, expected_csn: u64, scratch: []u8, replay: *C.Scratch) !void {
            try checkCatalog(db);
            if (db.csn != 0 or db.oid_counter != 0 or db.next_constraint_oid != change_log.first_oid or db.next_default_oid != change_log.first_oid) return error.SnapshotUnsupportedState;
            for (&db.tables) |*table| if (table.live) return error.SnapshotUnsupportedState;
            for (&db.seqs) |*seq| if (seq.live) return error.SnapshotUnsupportedState;
            if (comptime config.external_storage) if (db.workspace.query.refs.len == 0) return error.InvalidParameterValue;
            if (comptime config.external_workspace) if (db.workspace.query.cells.len == 0) return error.InvalidParameterValue;
            const length: u64 = try file.length();
            var header: [header_size]u8 = undefined;
            try readExact(file, 0, &header, length);
            const csn = std.mem.readInt(u64, header[8..16], .little);
            if (csn == 0 or csn != expected_csn) return error.InvalidSnapshotImage;

            var offset: u64 = header_size;
            var sequence_count: u32 = 0;
            const with_defaults = std.mem.eql(u8, header[0..8], defaults_magic);
            const table_count = blk: {
                if (std.mem.eql(u8, header[0..8], single_magic)) {
                    _ = try restoreTable(db, file, length, &offset, header[16..24], csn, null, scratch, replay, false);
                    break :blk 1;
                }
                const count = std.mem.readInt(u32, header[16..20], .little);
                sequence_count = std.mem.readInt(u32, header[20..24], .little);
                if (count > db.tables.len) return error.InvalidSnapshotImage;
                if (with_defaults) {
                    if (count == 0 or sequence_count > db.seqs.len) return error.InvalidSnapshotImage;
                } else if (std.mem.eql(u8, header[0..8], sequence_magic)) {
                    if (sequence_count == 0 or sequence_count > db.seqs.len) return error.InvalidSnapshotImage;
                } else if (!std.mem.eql(u8, header[0..8], multi_magic) or count < 2 or sequence_count != 0) {
                    return error.InvalidSnapshotImage;
                }
                var previous_bank: ?usize = null;
                for (0..count) |_| {
                    var table_header: [table_header_size]u8 = undefined;
                    try readExact(file, offset, &table_header, length);
                    offset += table_header.len;
                    previous_bank = try restoreTable(db, file, length, &offset, &table_header, csn, previous_bank, scratch, replay, with_defaults);
                }
                break :blk count;
            };
            for (0..sequence_count) |_| {
                const state = try readPart(file, &offset, length, scratch, .create_sequence);
                try C.applyBaseImageRecord(db, state, replay, .{ .csn = csn, .op = .create_sequence, .with_defaults = with_defaults });
            }
            if (with_defaults and !validSequenceOwnership(db)) return error.InvalidSnapshotImage;
            const counters = try readPart(file, &offset, length, scratch, .catalog_counters);
            if (offset != length or try file.length() != length) return error.InvalidSnapshotImage;
            const counter_op: change_log.Op = if (counters.len <= 8) .catalog_counters else switch (counters[8]) {
                @intFromEnum(change_log.Op.catalog_counters_with_constraints) => .catalog_counters_with_constraints,
                @intFromEnum(change_log.Op.catalog_counters_with_defaults) => .catalog_counters_with_defaults,
                else => .catalog_counters,
            };
            return C.applyBaseImageRecord(db, counters, replay, .{ .csn = csn, .op = counter_op, .table_count = table_count });
        }
    };
}
