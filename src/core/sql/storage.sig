//! Versioned table storage: S01 subset (Layer 0, design §4.3).
//!
//! Each table holds a row directory {rowid, generation, newest version}, a
//! rowid -> slot open-addressing index (load <= 50%), a version arena of
//! Config.versions_per_table slots (default 2 x rows_per_table) and a
//! multi-entry primary-key index from key to version, filtered by
//! visibility. The default arrays are inline caller-owned storage. With
//! external_storage they are distinct caller-provided slices: their lengths,
//! not the inline Config profile, set row/version/index capacities. Nothing
//! allocates; values inside a version still use the configured inline cells.
//!
//! Visibility (design §4.4): a statement reads under a Snapshot {csn, tx, cid}.
//! A version's creation is visible when it committed at or before snap.csn,
//! or when the snapshot's own transaction created it in an earlier statement
//! (xmin_cid < cid); deletion uses the same rule on xmax. A statement
//! therefore sees its transaction's earlier writes but never its own (no
//! Halloween problem). Uncommitted versions carry csn 0 and are invisible to
//! every other transaction; an aborted (sub)transaction frees its versions
//! and clears its marks immediately, so no aborted version is ever observed.
//! Superseded versions are reclaimed only once their xmax_csn is at or below
//! the reclamation horizon (no pinned snapshot can still see them).
//!
//! Directory slots are allocated at a high-water mark so slot order equals
//! rowid order (the historical insertion-ordered scan). When the mark reaches
//! capacity, dead versions are reclaimed and live slots are compacted; moved
//! slots get a fresh generation, so a stale RowRef never resolves.
const types = @import("types.sig");
const Error = types.Error;

fn pow2(minimum: usize) usize {
    var capacity: usize = 2;
    while (capacity < minimum) capacity *= 2;
    return capacity;
}

pub fn mix(value: u64) usize {
    var code = value *% 0x9e3779b97f4a7c15;
    code ^= code >> 33;
    code *%= 0xff51afd7ed558ccd;
    code ^= code >> 33;
    return @truncate(code);
}

/// {slot, epoch, sub}: transaction-table slot, the transaction's unique epoch
/// (0 means "no transaction") and its subtransaction depth.
pub const TxRef = struct { slot: u16 = 0, epoch: u32 = 0, sub: u16 = 0 };

/// Statement snapshot. epoch 0 has no own transaction (committed view).
pub const Snapshot = struct {
    csn: u64,
    slot: u16 = 0,
    epoch: u32 = 0,
    cid: u32 = 0,

    pub fn own(self: Snapshot, ref: TxRef) bool {
        return self.epoch != 0 and ref.epoch == self.epoch and ref.slot == self.slot;
    }
};

/// Every committed version, nothing uncommitted.
pub const committed_view: Snapshot = .{ .csn = 0xffffffffffffffff };

pub fn Storage(comptime config: types.Config) type {
    const V = types.Values(config);
    return struct {
        pub const versions_capacity: usize = if (config.versions_per_table == 0) config.rows_per_table * 2 else config.versions_per_table;
        pub const row_index_capacity: usize = pow2(config.rows_per_table * 2);
        pub const key_index_capacity: usize = pow2(versions_capacity * 2);
        /// Opportunistic reclamation bound after a transaction publishes.
        pub const reclaim_budget: usize = 64;

        comptime {
            if (versions_capacity <= config.rows_per_table) @compileError("versions_per_table must exceed rows_per_table");
            if (versions_capacity > 0x7fffffff or config.rows_per_table > 0x7fffffff) @compileError("storage capacity exceeds u32 references");
        }

        pub const RowSlot = struct {
            rowid: u64 = 0,
            generation: u32 = 0,
            /// Version index + 1; 0 marks a free slot.
            newest: u32 = 0,
        };

        pub const Version = struct {
            /// Directory slot + 1; 0 marks a free arena slot.
            row: u32 = 0,
            xmin: TxRef = .{},
            xmin_cid: u32 = 0,
            xmin_csn: u64 = 0,
            xmax: TxRef = .{},
            xmax_cid: u32 = 0,
            xmax_csn: u64 = 0,
            /// Older version index + 1, or the next free slot + 1 while free.
            older: u32 = 0,
            cells: [config.columns]V.Cell = @splat(.null_value),
        };

        /// Stable reference to a directory slot. Resolves only while the slot
        /// still holds the same row (same generation).
        pub const RowRef = struct { slot: u32, generation: u32 };

        pub const Stats = struct {
            live_rows: usize = 0,
            row_slots: usize = 0,
            row_high: usize = 0,
            versions: usize = 0,
            pending: usize = 0,
            next_rowid: u64 = 0,
        };

        /// `live`: the slot is in use (from CREATE until reclamation). Name
        /// visibility comes from the versioned catalog; these flags only
        /// summarize it: `pending_create` until the creator publishes,
        /// `pending_drop` while an uncommitted DROP holds it, `dead_csn` once
        /// a DROP committed (storage is reclaimed when the horizon passes it).
        pub const Backing = struct {
            rows: []RowSlot,
            versions: []Version,
            row_index: []u32,
            key_index: []u32,

            pub fn valid(self: Backing) bool {
                return self.rows.len != 0 and self.rows.len <= 0x7fffffff and
                    self.versions.len > self.rows.len and self.versions.len <= 0x7fffffff and
                    self.row_index.len >= self.rows.len * 2 and powerOfTwo(self.row_index.len) and
                    self.key_index.len >= self.versions.len * 2 and powerOfTwo(self.key_index.len);
            }
        };

        fn powerOfTwo(n: usize) bool {
            return n != 0 and (n & (n - 1)) == 0;
        }

        pub const OrderState = enum { empty, one, increasing, decreasing, unordered };
        pub const OrderProof = struct { state: OrderState = .empty, last: V.Cell = .null_value };

        /// Exact committed state, derived from published row transitions (not
        /// persisted). Old snapshots and transactions with own writes scan.
        /// At most 2^31-1 rows of i64 values fit comfortably in an i128 total.
        pub const ColumnSummary = struct { nonnull: i64 = 0, total: i128 = 0 };
        pub const Summary = struct {
            valid: bool = false,
            csn: u64 = 0,
            rows: i64 = 0,
            columns: [config.columns]ColumnSummary = @splat(.{}),
        };

        pub const Table = struct {
            live: bool = false,
            pending_create: bool = false,
            pending_drop: bool = false,
            dead_csn: u64 = 0,
            oid: u32 = 0,
            name: V.Name = .{},
            column_count: usize = 0,
            columns: [config.columns]V.Column = @splat(.{}),
            primary_column: ?usize = null,
            /// Conservative strict non-NULL order over physical row slots.
            /// Updates/aborts may discard a proof, never invent one. Not persisted.
            column_order: [config.columns]OrderProof = @splat(.{}),
            summary: Summary = .{},
            next_rowid: u64 = 0,
            row_generation: u32 = 0,
            row_high: usize = 0,
            row_used: usize = 0,
            version_high: usize = 0,
            version_used: usize = 0,
            version_free: u32 = 0,
            rows: if (config.external_storage) []RowSlot else [config.rows_per_table]RowSlot = if (config.external_storage) &.{} else @splat(.{}),
            versions: if (config.external_storage) []Version else [versions_capacity]Version = if (config.external_storage) &.{} else @splat(.{}),
            row_index: if (config.external_storage) []u32 else [row_index_capacity]u32 = if (config.external_storage) &.{} else @splat(0),
            key_index: if (config.external_storage) []u32 else [key_index_capacity]u32 = if (config.external_storage) &.{} else @splat(0),
        };

        /// A table every committed reader can see (created and not dropped).
        pub fn committedTable(table: *const Table) bool {
            return table.live and !table.pending_create and table.dead_csn == 0;
        }

        /// Prepare a free table slot for a new definition. Unused capacity is
        /// neither cleared nor read; only both indices are reset.
        pub fn reset(table: *Table, oid: u32, name: V.Name, columns: []const V.Column) void {
            table.oid = oid;
            table.name = name;
            table.column_count = columns.len;
            @memcpy(table.columns[0..columns.len], columns);
            table.primary_column = null;
            for (columns, 0..) |column, index| if (column.primary_key) {
                table.primary_column = index;
            };
            table.next_rowid = 1;
            table.dead_csn = 0;
            table.pending_drop = false;
            table.row_high = 0;
            table.row_used = 0;
            table.version_high = 0;
            table.version_used = 0;
            table.version_free = 0;
            table.column_order = @splat(.{});
            table.summary = .{};
            @memset(table.row_index[0..], 0);
            if (table.primary_column != null) @memset(table.key_index[0..], 0);
        }

        /// Copy a live table's observable state into distinct storage.
        pub fn copyTable(destination: *Table, source: *const Table) void {
            destination.oid = source.oid;
            destination.name = source.name;
            destination.column_count = source.column_count;
            @memcpy(destination.columns[0..source.column_count], source.columns[0..source.column_count]);
            destination.primary_column = source.primary_column;
            destination.column_order = source.column_order;
            destination.summary = source.summary;
            destination.next_rowid = source.next_rowid;
            destination.row_generation = source.row_generation;
            destination.row_high = source.row_high;
            destination.row_used = source.row_used;
            destination.version_high = source.version_high;
            destination.version_used = source.version_used;
            destination.version_free = source.version_free;
            @memcpy(destination.rows[0..source.row_high], source.rows[0..source.row_high]);
            @memcpy(destination.versions[0..source.version_high], source.versions[0..source.version_high]);
            if (comptime config.external_storage) {
                @memset(destination.row_index, 0);
                @memset(destination.key_index, 0);
                for (0..destination.row_high) |slot| if (destination.rows[slot].newest != 0) indexRow(destination, @intCast(slot));
                if (destination.primary_column != null) for (0..destination.version_high) |version| {
                    if (destination.versions[version].row != 0) indexKeyOnly(destination, @intCast(version));
                };
            } else {
                destination.row_index = source.row_index;
                if (source.primary_column != null) destination.key_index = source.key_index;
            }
        }

        pub fn created(version: *const Version, snap: Snapshot) bool {
            if (version.xmin_csn != 0) return version.xmin_csn <= snap.csn;
            return snap.own(version.xmin) and version.xmin_cid < snap.cid;
        }

        pub fn deleted(version: *const Version, snap: Snapshot) bool {
            if (version.xmax.epoch == 0) return false;
            if (version.xmax_csn != 0) return version.xmax_csn <= snap.csn;
            return snap.own(version.xmax) and version.xmax_cid < snap.cid;
        }

        /// The version of `slot` visible to `snap`, if any.
        pub fn visibleAt(table: *const Table, slot: usize, snap: Snapshot) ?u32 {
            var ref = table.rows[slot].newest;
            while (ref != 0) {
                const version = &table.versions[ref - 1];
                if (created(version, snap)) return if (deleted(version, snap)) null else ref - 1;
                ref = version.older;
            }
            return null;
        }

        /// Committed view: the newest stamped version, unless it is dead.
        pub fn visible(table: *const Table, slot: usize) ?u32 {
            return visibleAt(table, slot, committed_view);
        }

        /// The version created right after `version` in its row's chain.
        pub fn successor(table: *const Table, version: u32) ?u32 {
            var ref = table.rows[table.versions[version].row - 1].newest;
            while (ref != 0) {
                const entry = &table.versions[ref - 1];
                if (entry.older == version + 1) return ref - 1;
                ref = entry.older;
            }
            return null;
        }

        fn rowHome(table: *const Table, entry: u32) usize {
            return mix(table.rows[entry - 1].rowid) & (table.row_index.len - 1);
        }

        fn keyHome(table: *const Table, entry: u32) usize {
            return V.hash(&table.versions[entry - 1].cells[table.primary_column.?]) & (table.key_index.len - 1);
        }

        /// Backward-shift deletion keeps linear probing tombstone-free.
        fn removeAt(table: *const Table, index: []u32, start: usize, comptime home: fn (*const Table, u32) usize) void {
            const mask = index.len - 1;
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = index[probe];
                if (entry == 0) break;
                const distance_entry = (probe -% home(table, entry)) & mask;
                const distance_hole = (probe -% hole) & mask;
                if (distance_hole <= distance_entry) {
                    index[hole] = entry;
                    hole = probe;
                }
            }
            index[hole] = 0;
        }

        pub fn findRow(table: *const Table, rowid: u64) ?u32 {
            var position = mix(rowid) & (table.row_index.len - 1);
            while (true) {
                const entry = table.row_index[position];
                if (entry == 0) return null;
                if (table.rows[entry - 1].rowid == rowid) return entry - 1;
                position = (position + 1) & (table.row_index.len - 1);
            }
        }

        fn indexRow(table: *Table, slot: u32) void {
            var position = rowHome(table, slot + 1);
            while (table.row_index[position] != 0) position = (position + 1) & (table.row_index.len - 1);
            table.row_index[position] = slot + 1;
        }

        fn unindexRow(table: *Table, slot: u32) void {
            var position = rowHome(table, slot + 1);
            while (table.row_index[position] != slot + 1) {
                if (table.row_index[position] == 0) return;
                position = (position + 1) & (table.row_index.len - 1);
            }
            removeAt(table, table.row_index[0..], position, rowHome);
        }

        /// Called only at durable publication or validated change-record replay.
        pub fn summarize(table: *Table, cells: *const [config.columns]V.Cell, add: bool, csn: u64) void {
            if (!table.summary.valid) return;
            const sign: i64 = if (add) 1 else -1;
            table.summary.rows += sign;
            table.summary.csn = csn;
            for (cells[0..table.column_count], table.summary.columns[0..table.column_count]) |*cell, *column| {
                if (cell.* == .null_value) continue;
                column.nonnull += sign;
                if (cell.* == .integer) column.total += @as(i128, cell.integer) * sign;
            }
        }

        pub fn initSummary(table: *Table, csn: u64) void {
            table.summary = .{ .valid = true, .csn = csn };
        }

        pub fn indexKey(table: *Table, version: u32) void {
            noteOrder(table, version);
            indexKeyOnly(table, version);
        }

        fn noteOrder(table: *Table, version: u32) void {
            const entry = &table.versions[version];
            for (table.column_order[0..table.column_count], 0..) |*proof, column| {
                const value = &entry.cells[column];
                if (entry.older != 0) {
                    if (entry.older == version + 1 or table.versions[entry.older - 1].row == 0) {
                        proof.state = .unordered;
                    } else if (proof.state != .unordered and V.compare(value, &table.versions[entry.older - 1].cells[column]) != 0) proof.state = .unordered;
                    continue;
                }
                // The first row after reset/full reclamation can start a new
                // proof. Other inserts must be appended to the directory.
                if (entry.row == 1 and table.row_high == 1) {
                    proof.* = .{ .state = if (value.* == .null_value) .unordered else .one, .last = value.* };
                    continue;
                }
                if (proof.state == .unordered) continue;
                if (entry.row != table.row_high or value.* == .null_value) { proof.state = .unordered; continue; }
                const compared = V.compare(value, &proof.last);
                proof.state = switch (proof.state) {
                    .one => if (compared > 0) .increasing else if (compared < 0) .decreasing else .unordered,
                    .increasing => if (compared > 0) .increasing else .unordered,
                    .decreasing => if (compared < 0) .decreasing else .unordered,
                    .empty, .unordered => .unordered,
                };
                if (proof.state != .unordered) proof.last = value.*;
            }
        }

        fn indexKeyOnly(table: *Table, version: u32) void {
            if (table.primary_column == null) return;
            var position = keyHome(table, version + 1);
            while (table.key_index[position] != 0) position = (position + 1) & (table.key_index.len - 1);
            table.key_index[position] = version + 1;
        }

        fn unindexKey(table: *Table, version: u32) void {
            if (table.primary_column == null) return;
            var position = keyHome(table, version + 1);
            while (table.key_index[position] != version + 1) {
                if (table.key_index[position] == 0) return;
                position = (position + 1) & (table.key_index.len - 1);
            }
            removeAt(table, table.key_index[0..], position, keyHome);
        }

        /// Directory slot of the row visible to `snap` whose key equals value.
        pub fn lookupKeyAt(table: *const Table, value: *const V.Cell, snap: Snapshot) ?u32 {
            const column = table.primary_column orelse return null;
            if (value.* == .null_value) return null;
            var position = V.hash(value) & (table.key_index.len - 1);
            while (true) {
                const entry = table.key_index[position];
                if (entry == 0) return null;
                const version = &table.versions[entry - 1];
                if (V.compare(&version.cells[column], value) == 0) {
                    const slot = version.row - 1;
                    if (visibleAt(table, slot, snap) == entry - 1) return slot;
                }
                position = (position + 1) & (table.key_index.len - 1);
            }
        }

        /// Directory slot of the committed row whose key equals value.
        pub fn lookupKey(table: *const Table, value: *const V.Cell) ?u32 {
            return lookupKeyAt(table, value, committed_view);
        }

        pub fn freeVersions(table: *const Table) usize {
            return table.versions.len - table.version_used;
        }

        /// Caller initializes every field of the returned version.
        pub fn allocVersion(table: *Table) u32 {
            table.version_used += 1;
            if (table.version_free != 0) {
                const version = table.version_free - 1;
                table.version_free = table.versions[version].older;
                return version;
            }
            table.version_high += 1;
            return @intCast(table.version_high - 1);
        }

        fn freeVersion(table: *Table, version: u32) void {
            table.versions[version].row = 0;
            table.versions[version].older = table.version_free;
            table.version_free = version + 1;
            table.version_used -= 1;
        }

        pub fn allocRow(table: *Table, rowid: u64) u32 {
            const slot: u32 = @intCast(table.row_high);
            table.row_high += 1;
            table.row_used += 1;
            table.row_generation +%= 1;
            table.rows[slot] = .{ .rowid = rowid, .generation = table.row_generation, .newest = 0 };
            indexRow(table, slot);
            return slot;
        }

        /// Reclamation case 3: the row's last version is gone.
        fn freeRow(table: *Table, slot: u32) void {
            unindexRow(table, slot);
            table.rows[slot].newest = 0;
            table.row_generation +%= 1;
            table.rows[slot].generation = table.row_generation;
            table.row_used -= 1;
        }

        /// Unlink, unindex and free one version; frees its row if empty.
        pub fn reclaimVersion(table: *Table, version: u32) void {
            const slot = table.versions[version].row - 1;
            const row = &table.rows[slot];
            if (row.newest == version + 1) {
                row.newest = table.versions[version].older;
            } else {
                var previous = row.newest - 1;
                while (table.versions[previous].older != version + 1) previous = table.versions[previous].older - 1;
                table.versions[previous].older = table.versions[version].older;
            }
            unindexKey(table, version);
            freeVersion(table, version);
            if (row.newest == 0) freeRow(table, slot);
        }

        /// Reclamation case 2 at the Raw's horizon (Wave 1: its current csn).
        pub fn vacuum(table: *Table, horizon: u64) usize {
            var freed: usize = 0;
            for (0..table.version_high) |index| {
                const version = &table.versions[index];
                if (version.row == 0 or version.xmax_csn == 0 or version.xmax_csn > horizon) continue;
                reclaimVersion(table, @intCast(index));
                freed += 1;
            }
            return freed;
        }

        fn compact(table: *Table) void {
            var write: usize = 0;
            for (0..table.row_high) |read| {
                if (table.rows[read].newest == 0) continue;
                if (read != write) {
                    table.rows[write] = table.rows[read];
                    table.row_generation +%= 1;
                    table.rows[write].generation = table.row_generation;
                    var ref = table.rows[write].newest;
                    while (ref != 0) : (ref = table.versions[ref - 1].older) table.versions[ref - 1].row = @intCast(write + 1);
                }
                write += 1;
            }
            table.row_high = write;
            @memset(table.row_index[0..], 0);
            for (0..write) |slot| indexRow(table, @intCast(slot));
        }

        /// On-demand reclamation so `count` new versions fit, else 53200.
        pub fn ensureVersions(table: *Table, count: usize, horizon: u64) Error!void {
            if (freeVersions(table) >= count) return;
            _ = vacuum(table, horizon);
            if (freeVersions(table) < count) return error.VersionCapacity;
        }

        /// On-demand reclamation and compaction so one new row slot fits.
        pub fn ensureRowSlot(table: *Table, horizon: u64) Error!void {
            if (table.row_high < table.rows.len) return;
            if (table.row_used == table.rows.len) _ = vacuum(table, horizon);
            if (table.row_used == table.rows.len) return error.RowCapacity;
            compact(table);
        }

        pub fn liveRows(table: *const Table) usize {
            var count: usize = 0;
            for (0..table.row_high) |slot| if (table.rows[slot].newest != 0 and visible(table, slot) != null) {
                count += 1;
            };
            return count;
        }

        pub fn stats(table: *const Table) Stats {
            var out: Stats = .{ .live_rows = liveRows(table), .row_slots = table.row_used, .row_high = table.row_high, .versions = table.version_used, .next_rowid = table.next_rowid };
            for (table.versions[0..table.version_high]) |*version| {
                if (version.row == 0) continue;
                if (version.xmin_csn == 0 or (version.xmax.epoch != 0 and version.xmax_csn == 0)) out.pending += 1;
            }
            return out;
        }
    };
}
