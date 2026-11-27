//! Bounded logical image of committed base tables, schemas and sequences.
//! The caller freezes the source and owns an unpublished, fresh destination.
//! The caller verifies the enclosing snapshot seal before publication.
const std = @import("std");
const types = @import("types.sig");
const storage = @import("storage.sig");
const catalog = @import("catalog.sig");
const objects = @import("catalog_objects.sig");
const change_log = @import("change_log.sig");
const large = @import("large_object_pages.sig");
const routine_catalog = @import("routine_catalog.sig");

const single_magic = "RSBASE01";
const multi_magic = "RSBASE02";
const sequence_magic = "RSBASE03";
const defaults_magic = "RSBASE04";
// Version 5 inserts a schema count and checked definitions before tables.
const schemas_magic = "RSBASE05";
const pages_magic = "RSBASE06";
const large_defaults_magic = "RSBASE07";
const builtin_acl_magic = "RSBASE08";
const routine_defaults_magic = "RSBASE09";
const routine_objects_magic = "RSBASE10";
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
    const RC = routine_catalog.Catalog(config);

    return struct {
        const CatalogImage = struct {
            counts: [catalog_kinds.len]u32 = @splat(0),
            routines: [3]u32 = @splat(0),
            pages: usize = 0,

            fn hasObjects(self: CatalogImage) bool {
                for (self.counts) |count| if (count != 0) return true;
                return self.hasRoutines();
            }

            fn hasRoutines(self: CatalogImage) bool {
                for (self.routines) |count| if (count != 0) return true;
                return false;
            }

            fn hasLargeDefaults(self: CatalogImage) bool {
                return self.counts[4] != 0;
            }

            fn hasBuiltinAcls(self: CatalogImage) bool {
                return self.counts[5] != 0;
            }

            fn hasRoutineDefaults(self: CatalogImage) bool {
                return self.counts[6] != 0;
            }
        };

        const catalog_kinds = [_]objects.Kind{ .role, .large_object, .large_object_acl, .comment, .large_object_default_acl, .builtin_routine_acl, .routine_default_acl };
        const routine_classes = .{
            .{ .field = "routines", .op = change_log.Op.create_routine },
            .{ .field = "triggers", .op = change_log.Op.create_trigger },
            .{ .field = "rules", .op = change_log.Op.create_rule },
        };

        fn writeRoutineObjects(db: *const Database, sink: anytype, scratch: []u8) !void {
            const snap: storage.Snapshot = .{ .csn = db.csn };
            // Roles, schemas and tables precede all routines. Functions
            // precede triggers so every dependency can be validated normally.
            inline for (routine_classes) |class| {
                for (&@field(db.objects, class.field)) |*item| {
                    if (!item.live or !item.stamp.visible(snap)) continue;
                    var bytes: [RC.payload_bytes]u8 = undefined;
                    var payload: RC.Payload = .{ .buffer = &bytes };
                    switch (class.op) {
                        .create_routine => try RC.encodeRoutine(&payload, item),
                        .create_trigger => try RC.encodeTrigger(&payload, item),
                        .create_rule => try RC.encodeRule(&payload, item),
                        else => unreachable,
                    }
                    var writer = try change_log.Writer.init(scratch, 0);
                    try C.encodeObject(&writer, class.op, bytes[0..payload.used]);
                    try appendPart(sink, class.op, scratch[0..try writer.finish()]);
                }
            }
        }

        fn writeCatalog(db: *const Database, sink: anytype, scratch: []u8, kind: objects.Kind) !void {
            const snap: storage.Snapshot = .{ .csn = db.csn };
            const passes: usize = if (objects.defaultAcl(kind)) 2 else 1;
            for (0..passes) |pass| {
                for (&db.catalog_objects.items) |*object| {
                    if (object.kind != kind or !O.visible(object, snap)) continue;
                    if (passes == 2 and (object.oid == 0) != (pass == 1)) continue;
                    var writer = try change_log.Writer.init(scratch, 0);
                    try writer.op(.object_create);
                    try O.encodeCreate(&writer, object);
                    try appendPart(sink, .object_create, scratch[0..try writer.finish()]);
                }
            }
        }

        fn restoreCatalog(db: *Database, file: anytype, size: u64, offset: *u64, scratch: []u8, replay: *C.Scratch, csn: u64, kind: objects.Kind, count: u32) !void {
            for (0..count) |_| {
                const frame = try readPart(file, offset, size, scratch, .object_create);
                try C.applyBaseImageRecord(db, frame, replay, .{ .csn = csn, .op = .object_create, .catalog_kind = kind });
            }
        }

        fn writePages(db: *const Database, sink: anytype) !void {
            const pages = if (db.large_pages) |*value| value else return;
            const snap: storage.Snapshot = .{ .csn = db.csn };
            var cursor: large.Pages.Cursor = .{};
            while (cursor.next(pages, snap)) |entry| {
                const data = pages.versionBytes(entry.version);
                var header: [10]u8 = undefined;
                std.mem.writeInt(u32, header[0..4], entry.key.oid, .little);
                std.mem.writeInt(u32, header[4..8], entry.key.page, .little);
                std.mem.writeInt(u16, header[8..10], @intCast(data.len), .little);
                try sink.appendAll(&header);
                try sink.appendAll(data);
            }
        }

        fn restorePages(db: *Database, file: anytype, file_len: u64, offset: *u64, scratch: []u8, csn: u64, count: u32) !void {
            if (count == 0) return;
            const pages = if (db.large_pages) |*value| value else return error.SnapshotUnsupportedState;
            if (count > pages.capacity() or pages.committed_count != 0) return error.InvalidSnapshotImage;
            const snap: storage.Snapshot = .{ .csn = csn };
            var previous: u32 = 0;
            var object_length: u64 = 0;
            for (0..count) |_| {
                var header: [10]u8 = undefined;
                try readExact(file, offset.*, &header, file_len);
                offset.* += header.len;
                const key: large.Key = .{
                    .oid = std.mem.readInt(u32, header[0..4], .little),
                    .page = std.mem.readInt(u32, header[4..8], .little),
                };
                const size = std.mem.readInt(u16, header[8..10], .little);
                if (key.oid == 0 or key.page > large.end_page or size > large.page_bytes or
                    (key.page == large.end_page and size != 0)) return error.InvalidSnapshotImage;
                if (key.oid != previous) {
                    const object: O.Object = .{ .kind = .large_object, .target = key.oid };
                    const index = db.catalog_objects.findKey(&object, snap) orelse return error.InvalidSnapshotImage;
                    object_length = db.catalog_objects.items[index].largeObjectLength();
                    previous = key.oid;
                }
                if (@as(u64, key.page) * large.page_bytes + size > object_length or pages.page(key, snap) != null)
                    return error.InvalidSnapshotImage;
                if (size > scratch.len) return error.SnapshotWorkspaceTooSmall;
                try readExact(file, offset.*, scratch[0..size], file_len);
                offset.* += size;
                pages.replay(key, scratch[0..size], csn);
            }
        }

        fn checkCatalog(db: *const Database) !CatalogImage {
            for (&db.txs) |*tx| if (tx.active) return error.SnapshotUnsupportedState;
            const snap: storage.Snapshot = .{ .csn = db.csn };
            var image: CatalogImage = .{ .pages = if (db.large_pages) |*pages| pages.committed_count else 0 };
            for (&db.catalog_objects.items) |*object| {
                if (!O.visible(object, snap)) continue;
                if (object.kind == .comment and object.grantee != objects.class_large_object)
                    return error.SnapshotUnsupportedState;
                const position = std.mem.indexOfScalar(objects.Kind, &catalog_kinds, object.kind) orelse return error.SnapshotUnsupportedState;
                image.counts[position] += 1;
            }
            inline for (routine_classes, 0..) |class, index| {
                for (&@field(db.objects, class.field)) |*item|
                    if (item.live and item.stamp.visible(snap)) { image.routines[index] += 1; };
            }
            if (image.hasObjects() and image.counts[1] == 0 and !image.hasLargeDefaults() and !image.hasBuiltinAcls() and !image.hasRoutineDefaults() and !image.hasRoutines()) return error.SnapshotUnsupportedState;
            return image;
        }

        fn exportTables(db: *const Database) !struct { count: usize, first_bank: usize, with_defaults: bool } {
            if (db.csn == 0) return error.SnapshotUnsupportedState;
            var count: usize = 0;
            var first_bank: usize = 0;
            var with_defaults = false;
            for (&db.tables, 0..) |*table, bank| {
                if (!S.committedTable(table)) continue;
                if (!C.supportsBaseImage(table) or !liveNamespace(db, table.namespace)) return error.SnapshotUnsupportedState;
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

        fn liveNamespace(db: *const Database, oid: u32) bool {
            if (oid == catalog.public_namespace) return true;
            for (&db.schemas) |*schema| {
                if (schema.live and schema.dead_csn == 0 and schema.oid == oid) return true;
            }
            return false;
        }

        fn ownerBank(db: *const Database, oid: u32) ?usize {
            for (&db.tables, 0..) |*table, bank| {
                if (S.committedTable(table) and table.oid == oid) return bank;
            }
            return null;
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
                const bank = ownerBank(db, seq.owner) orelse return false;
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
            const catalog_image = try checkCatalog(db);
            const with_pages = catalog_image.hasObjects();
            const selected = try exportTables(db);
            var schema_count: u32 = 0;
            for (&db.schemas) |*schema| {
                if (!schema.live or schema.dead_csn != 0) continue;
                if (schema.pending_create or schema.pending_drop or schema.owner != objects.bootstrap_role)
                    return error.SnapshotUnsupportedState;
                schema_count += 1;
            }
            var sequence_count: usize = 0;
            var with_defaults = selected.with_defaults;
            for (&db.seqs) |*seq| {
                if (!seq.live or seq.dead_csn != 0) continue;
                if (seq.pending_create or seq.pending_drop or !liveNamespace(db, seq.namespace))
                    return error.SnapshotUnsupportedState;
                with_defaults = with_defaults or seq.owner != 0;
                sequence_count += 1;
            }
            if (with_defaults and !validSequenceOwnership(db)) return error.SnapshotUnsupportedState;
            if (selected.count == 0 and sequence_count == 0 and schema_count == 0 and !with_pages) return error.SnapshotUnsupportedState;
            if (sequence_count != 0 and config.tx_writes < 2) return error.SnapshotWorkspaceTooSmall;
            var header: [header_size]u8 = undefined;
            std.mem.writeInt(u64, header[8..16], db.csn, .little);
            if (!with_pages and selected.count == 1 and sequence_count == 0 and schema_count == 0 and !with_defaults) {
                @memcpy(header[0..8], single_magic);
                const table = &db.tables[selected.first_bank];
                writeTableHeader(header[16..24], selected.first_bank, table);
                try sink.appendAll(&header);
                try writeTable(table, sink, scratch);
            } else {
                @memcpy(header[0..8], if (catalog_image.hasRoutines()) routine_objects_magic else if (catalog_image.hasRoutineDefaults()) routine_defaults_magic else if (catalog_image.hasBuiltinAcls()) builtin_acl_magic else if (catalog_image.hasLargeDefaults()) large_defaults_magic else if (with_pages) pages_magic else if (schema_count != 0) schemas_magic else if (with_defaults) defaults_magic else if (sequence_count == 0) multi_magic else sequence_magic);
                std.mem.writeInt(u32, header[16..20], @intCast(selected.count), .little);
                std.mem.writeInt(u32, header[20..24], @intCast(sequence_count), .little);
                try sink.appendAll(&header);
                if (with_pages) {
                    var counts: [44]u8 = undefined;
                    const groups: usize = if (catalog_image.hasRoutines() or catalog_image.hasRoutineDefaults()) 7 else if (catalog_image.hasBuiltinAcls()) 6 else if (catalog_image.hasLargeDefaults()) 5 else 4;
                    for (catalog_image.counts[0..groups], 0..) |count, index| std.mem.writeInt(u32, counts[index * 4 ..][0..4], count, .little);
                    std.mem.writeInt(u32, counts[groups * 4 ..][0..4], @intCast(catalog_image.pages), .little);
                    if (catalog_image.hasRoutines()) for (catalog_image.routines, 0..) |count, index| {
                        std.mem.writeInt(u32, counts[(groups + 1 + index) * 4 ..][0..4], count, .little);
                    };
                    const count_len = (groups + 1 + @as(usize, if (catalog_image.hasRoutines()) 3 else 0)) * 4;
                    try sink.appendAll(counts[0..count_len]);
                    try writeCatalog(db, sink, scratch, .role);
                }
                if (with_pages or schema_count != 0) {
                    var count: [4]u8 = undefined;
                    std.mem.writeInt(u32, &count, schema_count, .little);
                    try sink.appendAll(&count);
                    for (&db.schemas) |*schema| {
                        if (!schema.live or schema.dead_csn != 0) continue;
                        var definition = try change_log.Writer.init(scratch, 0);
                        try C.encodeCreateSchema(&definition, schema);
                        try appendPart(sink, .create_schema, scratch[0..try definition.finish()]);
                    }
                }
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
                var automatic = false;
                if (seq.namespace != catalog.public_namespace and seq.owner != 0) {
                    const owner = &db.tables[ownerBank(db, seq.owner).?];
                    const kind = owner.columns[seq.owner_column].default_kind;
                    automatic = kind != .identity_always and kind != .identity_by_default;
                }
                try C.encodeCreateSequence(&state, seq, automatic);
                // Preserve the WAL's reservation boundary, including numbers
                // reserved in live session caches that restart discards.
                try C.encodeSequenceValue(&state, seq.oid, seq.logged_value, seq.logged_called);
                try appendPart(sink, .create_sequence, scratch[0..try state.finish()]);
            };
            if (with_pages) {
                for (catalog_kinds[1..]) |kind| try writeCatalog(db, sink, scratch, kind);
                try writePages(db, sink);
                if (catalog_image.hasRoutines()) try writeRoutineObjects(db, sink, scratch);
            }
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

        fn restoreTable(db: *Database, file: anytype, length: u64, offset: *u64, header: *const [table_header_size]u8, csn: u64, previous_bank: ?usize, scratch: []u8, replay: *C.Scratch, with_defaults: bool, with_schemas: bool) !usize {
            const bank = std.mem.readInt(u32, header[0..4], .little);
            const rows = std.mem.readInt(u32, header[4..8], .little);
            if (bank >= db.tables.len or (previous_bank != null and bank <= previous_bank.?) or
                rows > db.tables[bank].rows.len or rows > db.tables[bank].versions.len) return error.InvalidSnapshotImage;
            const definition = try readPart(file, offset, length, scratch, .create_table);
            try C.applyBaseImageRecord(db, definition, replay, .{ .csn = csn, .op = .create_table, .bank = bank, .with_defaults = with_defaults, .with_schemas = with_schemas });
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
            const empty = try checkCatalog(db);
            if (empty.hasObjects() or empty.pages != 0) return error.SnapshotUnsupportedState;
            if (db.csn != 0 or db.oid_counter != 0 or db.next_constraint_oid != change_log.first_oid or db.next_default_oid != change_log.first_oid) return error.SnapshotUnsupportedState;
            for (&db.schemas) |*schema| if (schema.live) return error.SnapshotUnsupportedState;
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
            const with_routines = std.mem.eql(u8, header[0..8], routine_objects_magic);
            const with_routine_defaults = with_routines or std.mem.eql(u8, header[0..8], routine_defaults_magic);
            const with_builtin_acls = with_routine_defaults or std.mem.eql(u8, header[0..8], builtin_acl_magic);
            const with_large_defaults = with_builtin_acls or std.mem.eql(u8, header[0..8], large_defaults_magic);
            const with_pages = with_large_defaults or std.mem.eql(u8, header[0..8], pages_magic);
            const with_schemas = with_pages or std.mem.eql(u8, header[0..8], schemas_magic);
            const groups: usize = if (with_routine_defaults) 7 else if (with_builtin_acls) 6 else if (with_large_defaults) 5 else 4;
            var counts: [catalog_kinds.len]u32 = @splat(0);
            var routine_counts: [3]u32 = @splat(0);
            var page_count: u32 = 0;
            if (with_pages) {
                var encoded: [44]u8 = undefined;
                const encoded_len = (groups + 1 + @as(usize, if (with_routines) 3 else 0)) * 4;
                try readExact(file, offset, encoded[0..encoded_len], length);
                offset += encoded_len;
                var objects_total: u64 = 0;
                for (counts[0..groups], 0..) |*count, index| {
                    count.* = std.mem.readInt(u32, encoded[index * 4 ..][0..4], .little);
                    objects_total += count.*;
                }
                page_count = std.mem.readInt(u32, encoded[groups * 4 ..][0..4], .little);
                var routines_total: u64 = 0;
                if (with_routines) inline for (routine_classes, 0..) |class, index| {
                    const count = std.mem.readInt(u32, encoded[(groups + 1 + index) * 4 ..][0..4], .little);
                    if (count > @field(db.objects, class.field).len) return error.InvalidSnapshotImage;
                    routine_counts[index] = count;
                    routines_total += count;
                };
                if ((objects_total == 0 and routines_total == 0) or objects_total > db.catalog_objects.items.len or
                    (with_routines and routines_total == 0) or
                    (!with_routines and with_routine_defaults and counts[6] == 0) or
                    (!with_routine_defaults and with_builtin_acls and counts[5] == 0) or
                    (!with_builtin_acls and with_large_defaults and counts[4] == 0) or
                    (page_count != 0 and (db.large_pages == null or page_count > db.large_pages.?.capacity())))
                    return error.InvalidSnapshotImage;
                try restoreCatalog(db, file, length, &offset, scratch, replay, csn, .role, counts[0]);
            }
            const with_defaults = with_schemas or std.mem.eql(u8, header[0..8], defaults_magic);
            const table_count = blk: {
                if (std.mem.eql(u8, header[0..8], single_magic)) {
                    _ = try restoreTable(db, file, length, &offset, header[16..24], csn, null, scratch, replay, false, false);
                    break :blk 1;
                }
                const count = std.mem.readInt(u32, header[16..20], .little);
                sequence_count = std.mem.readInt(u32, header[20..24], .little);
                if (count > db.tables.len) return error.InvalidSnapshotImage;
                if (with_schemas) {
                    if (sequence_count > db.seqs.len) return error.InvalidSnapshotImage;
                    var total: [4]u8 = undefined;
                    try readExact(file, offset, &total, length);
                    offset += total.len;
                    const schema_count = std.mem.readInt(u32, &total, .little);
                    if ((!with_pages and schema_count == 0) or schema_count > db.schemas.len) return error.InvalidSnapshotImage;
                    for (0..schema_count) |_| {
                        const schema = try readPart(file, &offset, length, scratch, .create_schema);
                        try C.applyBaseImageRecord(db, schema, replay, .{ .csn = csn, .op = .create_schema, .with_schemas = true });
                    }
                } else if (with_defaults) {
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
                    previous_bank = try restoreTable(db, file, length, &offset, &table_header, csn, previous_bank, scratch, replay, with_defaults, with_schemas);
                }
                break :blk count;
            };
            for (0..sequence_count) |_| {
                const state = try readPart(file, &offset, length, scratch, .create_sequence);
                try C.applyBaseImageRecord(db, state, replay, .{ .csn = csn, .op = .create_sequence, .with_defaults = with_defaults, .with_schemas = with_schemas });
            }
            if (with_defaults and !validSequenceOwnership(db)) return error.InvalidSnapshotImage;
            if (with_pages) {
                for (catalog_kinds[1..groups], counts[1..groups]) |kind, count| {
                    try restoreCatalog(db, file, length, &offset, scratch, replay, csn, kind, count);
                }
                if (counts[2] != 0 or counts[5] != 0) {
                    replay.object_overlay.init(&db.catalog_objects);
                    try replay.object_overlay.verifyLargeObjectGrants();
                }
                try restorePages(db, file, length, &offset, scratch, csn, page_count);
                if (with_routines) inline for (routine_classes, 0..) |class, index| {
                    for (0..routine_counts[index]) |_| {
                        const frame = try readPart(file, &offset, length, scratch, class.op);
                        try C.applyBaseImageRecord(db, frame, replay, .{ .csn = csn, .op = class.op, .with_routines = true });
                    }
                };
            }
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
