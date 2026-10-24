//! Versioned catalog base relations (Layer 0, design §4.10, review M2).
//!
//! The catalog is ordinary MVCC data: four base relations stored with the
//! same row directory and version arena as user tables (storage.sig), so a
//! table's existence follows exactly the same snapshot visibility rules as
//! its rows and DDL is transactional:
//!
//!   cat_relations  (oid, relname, relkind, relnamespace, slot)   tables + sequences rows
//!   cat_attributes (attrelid, attnum, attname, atttypid, attnotnull, attpk)  tables x columns
//!   cat_attrdef    (adrelid, adnum, adbin)                       tables x columns (empty until defaults)
//!   cat_sequences  (seqrelid, start, increment, max, min, cycle)  sequences
//!                  (values are non-transactional and live in the sequence slots)
//!   cat_namespaces pg_catalog (11), public (2200), information_schema: static
//!
//! Every relation is sized by the user-object limits (Config.tables,
//! columns, sequences) with two versions per row, so user DDL hits
//! TableCapacity before the catalog fills; a catalog exhaustion is
//! CatalogCapacity (53200) and rolls the statement back. Every name lookup
//! reads cat_relations under the statement snapshot. A dropped table's
//! storage slot is reused only after its catalog version passes the
//! reclamation horizon.
const types = @import("types.sig");
const storage = @import("storage.sig");
const Error = types.Error;

pub const Relation = enum(u8) { relations = 0, attributes = 1, attrdef = 2, sequences = 3 };

pub const Namespace = struct { oid: u32, name: []const u8 };

pub const namespaces = [_]Namespace{
    .{ .oid = 11, .name = "pg_catalog" },
    .{ .oid = 2200, .name = "public" },
    .{ .oid = 13000, .name = "information_schema" },
};

pub const public_namespace: u32 = 2200;

pub fn Catalog(comptime config: types.Config) type {
    const rows = @max(config.tables * config.columns, config.tables + config.sequences);
    const cat_config: types.Config = .{
        .tables = 1,
        .columns = 6,
        .rows_per_table = rows,
        .name_bytes = config.name_bytes,
        .text_bytes = @max(config.name_bytes, 8),
        .integer_bits = 64,
        .tx_writes = 1,
    };
    const CV = types.Values(cat_config);
    const SC = storage.Storage(cat_config);
    return struct {
        const Self = @This();
        pub const Storage = SC;
        pub const Cell = CV.Cell;

        relations: [4]SC.Table = @splat(.{}),

        pub fn relation(self: *Self, which: Relation) *SC.Table {
            return &self.relations[@intFromEnum(which)];
        }

        pub fn relationConst(self: *const Self, which: Relation) *const SC.Table {
            return &self.relations[@intFromEnum(which)];
        }

        fn text(value: []const u8) CV.Cell {
            var out: CV.Text = .{ .len = value.len };
            @memcpy(out.bytes[0..value.len], value);
            return .{ .text = out };
        }

        fn int(value: i64) CV.Cell {
            return .{ .integer = value };
        }

        /// One catalog version created or marked by a statement.
        pub const Change = struct { relation: Relation, version: u32 };

        /// Room for one relation's catalog rows.
        pub const max_changes = 1 + config.columns;

        /// A visible relation row: kind 'r' (table) or 'S' (sequence) and
        /// its table or sequence slot.
        pub const Found = struct { kind: u8, slot: usize };

        fn sequenceRow(slot: usize) u64 {
            return config.tables + slot + 1;
        }

        /// cat_relations (relkind S) and cat_sequences rows for a sequence slot.
        pub fn createSequence(self: *Self, slot: usize, seq: anytype, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64, out: *[max_changes]Change) Error!usize {
            var count: usize = 0;
            errdefer for (out[0..count]) |change| SC.reclaimVersion(self.relation(change.relation), change.version);
            const oid: i64 = seq.oid;
            const relation_cells = [_]CV.Cell{ int(oid), text(seq.name.slice()), text("S"), int(public_namespace), int(@intCast(slot)) };
            out[count] = .{ .relation = .relations, .version = try self.addVersion(.relations, sequenceRow(slot), &relation_cells, xmin, cid, csn, horizon) };
            count += 1;
            const spec = seq.spec;
            const cells = [_]CV.Cell{ int(oid), int(spec.start), int(spec.increment), int(spec.max), int(spec.min), .{ .boolean = spec.cycle } };
            out[count] = .{ .relation = .sequences, .version = try self.addVersion(.sequences, slot + 1, &cells, xmin, cid, csn, horizon) };
            count += 1;
            return count;
        }

        pub fn dropSequence(self: *Self, slot: usize, snap: storage.Snapshot, xmax: storage.TxRef, cid: u32, csn: u64, out: *[max_changes]Change) usize {
            var count: usize = 0;
            const relations = self.relation(.relations);
            if (visibleRow(relations, sequenceRow(slot), snap)) |version| {
                mark(relations, version, xmax, cid, csn);
                out[count] = .{ .relation = .relations, .version = version };
                count += 1;
            }
            const sequences = self.relation(.sequences);
            if (visibleRow(sequences, slot + 1, snap)) |version| {
                mark(sequences, version, xmax, cid, csn);
                out[count] = .{ .relation = .sequences, .version = version };
                count += 1;
            }
            return count;
        }

        /// Any relation (table or sequence) named `name` visible to `snap`.
        pub fn find(self: *const Self, name: []const u8, snap: storage.Snapshot) ?Found {
            const relations = self.relationConst(.relations);
            for (0..relations.row_high) |row| {
                const version = SC.visibleAt(relations, row, snap) orelse continue;
                const cells = &relations.versions[version].cells;
                if (sameName(&cells[1], name)) return .{ .kind = cells[2].text.bytes[0], .slot = @intCast(cells[4].integer) };
            }
            return null;
        }

        fn addVersion(self: *Self, which: Relation, rowid: u64, cells: []const CV.Cell, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64) Error!u32 {
            const table = self.relation(which);
            SC.ensureVersions(table, 1, horizon) catch return error.CatalogCapacity;
            SC.ensureRowSlot(table, horizon) catch return error.CatalogCapacity;
            if (SC.findRow(table, rowid) != null) _ = SC.vacuum(table, horizon);
            if (SC.findRow(table, rowid) != null) return error.CatalogCapacity;
            const slot = SC.allocRow(table, rowid);
            const version = SC.allocVersion(table);
            table.versions[version] = .{ .row = slot + 1, .xmin = xmin, .xmin_cid = cid, .xmin_csn = csn };
            for (cells, 0..) |cell, index| table.versions[version].cells[index] = cell;
            table.rows[slot].newest = version + 1;
            return version;
        }

        /// Writes cat_relations and cat_attributes rows for a table slot.
        /// `csn` 0 leaves them uncommitted (owned by xmin); replay passes the
        /// record's csn. On error every version created here is freed.
        pub fn create(self: *Self, slot: usize, table: anytype, xmin: storage.TxRef, cid: u32, csn: u64, horizon: u64, out: *[max_changes]Change) Error!usize {
            var count: usize = 0;
            errdefer for (out[0..count]) |change| SC.reclaimVersion(self.relation(change.relation), change.version);
            const oid: i64 = table.oid;
            const relation_cells = [_]CV.Cell{ int(oid), text(table.name.slice()), text("r"), int(public_namespace), int(@intCast(slot)) };
            out[count] = .{ .relation = .relations, .version = try self.addVersion(.relations, slot + 1, &relation_cells, xmin, cid, csn, horizon) };
            count += 1;
            for (table.columns[0..table.column_count], 0..) |*column, index| {
                const cells = [_]CV.Cell{ int(oid), int(@intCast(index + 1)), text(column.name.slice()), int(types.typeOid(column.data_type)), .{ .boolean = column.not_null }, .{ .boolean = column.primary_key } };
                out[count] = .{ .relation = .attributes, .version = try self.addVersion(.attributes, slot * config.columns + index + 1, &cells, xmin, cid, csn, horizon) };
                count += 1;
            }
            return count;
        }

        fn visibleRow(table: *const SC.Table, rowid: u64, snap: storage.Snapshot) ?u32 {
            const slot = SC.findRow(table, rowid) orelse return null;
            return SC.visibleAt(table, slot, snap);
        }

        /// Marks a table slot's visible catalog rows deleted by xmax.
        pub fn drop(self: *Self, slot: usize, column_count: usize, snap: storage.Snapshot, xmax: storage.TxRef, cid: u32, csn: u64, out: *[max_changes]Change) usize {
            var count: usize = 0;
            const relations = self.relation(.relations);
            if (visibleRow(relations, slot + 1, snap)) |version| {
                mark(relations, version, xmax, cid, csn);
                out[count] = .{ .relation = .relations, .version = version };
                count += 1;
            }
            const attributes = self.relation(.attributes);
            for (0..column_count) |index| {
                if (visibleRow(attributes, slot * config.columns + index + 1, snap)) |version| {
                    mark(attributes, version, xmax, cid, csn);
                    out[count] = .{ .relation = .attributes, .version = version };
                    count += 1;
                }
            }
            return count;
        }

        fn mark(table: *SC.Table, version: u32, xmax: storage.TxRef, cid: u32, csn: u64) void {
            table.versions[version].xmax = xmax;
            table.versions[version].xmax_cid = cid;
            table.versions[version].xmax_csn = csn;
        }

        fn sameName(cell: *const CV.Cell, name: []const u8) bool {
            return cell.* == .text and types.same(cell.text.slice(), name);
        }

        /// Table slot whose relation row named `name` is visible to `snap`.
        pub fn lookup(self: *const Self, name: []const u8, snap: storage.Snapshot) ?usize {
            const found = self.find(name, snap) orelse return null;
            return if (found.kind == 'r') found.slot else null;
        }

        /// A live transaction other than the snapshot's own that has an
        /// uncommitted relation row with this name.
        pub fn creator(self: *const Self, name: []const u8, snap: storage.Snapshot) ?u16 {
            const relations = self.relationConst(.relations);
            for (relations.versions[0..relations.version_high]) |*version| {
                if (version.row == 0 or version.xmin_csn != 0 or snap.own(version.xmin)) continue;
                if (version.xmax.epoch != 0) continue;
                if (sameName(&version.cells[1], name)) return version.xmin.slot;
            }
            return null;
        }

        /// Column definitions of a slot as cat_attributes holds them.
        pub fn attributeCount(self: *const Self, slot: usize, snap: storage.Snapshot) usize {
            const attributes = self.relationConst(.attributes);
            var count: usize = 0;
            for (0..config.columns) |index| {
                if (visibleRow(attributes, slot * config.columns + index + 1, snap) != null) count += 1;
            }
            return count;
        }

        pub fn stamp(self: *Self, change: Change, csn: u64, creation: bool) void {
            const version = &self.relation(change.relation).versions[change.version];
            if (creation) version.xmin_csn = csn else version.xmax_csn = csn;
        }

        /// Undoes one change of an aborting (sub)transaction.
        pub fn undo(self: *Self, change: Change, creation: bool) void {
            const table = self.relation(change.relation);
            if (creation) {
                SC.reclaimVersion(table, change.version);
            } else {
                table.versions[change.version].xmax = .{};
                table.versions[change.version].xmax_cid = 0;
                table.versions[change.version].xmax_csn = 0;
            }
        }

        /// Reclaims dead catalog versions at the horizon.
        pub fn vacuum(self: *Self, horizon: u64) usize {
            var freed: usize = 0;
            for (&self.relations) |*table| freed += SC.vacuum(table, horizon);
            return freed;
        }

        /// Live (committed or pending) catalog versions, for leak checks.
        pub fn versions(self: *const Self) usize {
            var count: usize = 0;
            for (&self.relations) |*table| count += table.version_used;
            return count;
        }

        pub fn pending(self: *const Self) usize {
            var count: usize = 0;
            for (&self.relations) |*table| count += SC.stats(table).pending;
            return count;
        }

    };
}
