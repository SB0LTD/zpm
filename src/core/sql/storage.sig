//! Versioned table storage: S01 subset (Layer 0, design §4.3).
//!
//! Each table holds a row directory {rowid, generation, newest version}, a
//! rowid -> slot open-addressing index (load <= 50%), a version arena of
//! Config.versions_per_table slots (default 2 x rows_per_table) and a
//! multi-entry primary-key index from key to version, filtered by
//! visibility. The default arrays are inline caller-owned storage. With
//! external_storage they are distinct caller-provided slices: their lengths,
//! not the inline Config profile, set row/version/index capacities. Nothing
//! allocates. External storage may give dense values their own row arena.
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
const mem = @import("std").mem;
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
        pub const compact_enabled = config.compact_integral_scans and config.external_storage and config.columns <= 64;
        pub const presence_enabled = compact_enabled and config.block_presence_filters;
        pub const split_versions = config.split_external_versions and config.external_storage;
        pub const integral_enabled = split_versions and config.integral_external_versions;
        pub const VersionRow = [config.columns]V.Cell;

        pub fn presenceWords(rows:usize) Error!usize {
            const rounded=@addWithOverflow(rows,63);if(rounded[1]!=0) return error.InvalidParameterValue;
            const words=@mulWithOverflow(rounded[0]/64,config.columns*4);if(words[1]!=0) return error.InvalidParameterValue;
            return words[0];
        }

        comptime {
            if (versions_capacity <= config.rows_per_table) @compileError("versions_per_table must exceed rows_per_table");
            if (versions_capacity > 0x7fffffff or config.rows_per_table > 0x7fffffff) @compileError("storage capacity exceeds u32 references");
        }

        const Truncation = struct {
            owner: TxRef = .{},
            cid: u32 = 0,
        };

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
            cells: if (split_versions) void else VersionRow = if (split_versions) {} else @splat(.null_value),
        };

        pub const VersionOrigin = struct {
            row: u32,
            xmin: TxRef,
            cid: u32,
            csn: u64 = 0,
            /// Previous version index + 1, or 0 for an insert.
            older: u32 = 0,
        };

        /// Dense versions lend rows directly. Integral banks decode here.
        pub const VersionRowScratch = if (integral_enabled) VersionRow else [0]V.Cell;

        const IntegralLayout = struct {
            offsets: [config.columns]usize = undefined,
            bytes: usize = 0,

            fn forColumns(columns: []const V.Column) ?IntegralLayout {
                var layout: IntegralLayout = .{ .bytes = (columns.len + 7) / 8 };
                for (columns, 0..) |column, i| {
                    layout.offsets[i] = layout.bytes;
                    layout.bytes += switch (column.data_type) {
                        .smallint => @as(usize, 2),
                        .integer32, .oid, .date => 4,
                        .integer => 8,
                        else => return null,
                    };
                }
                return layout;
            }
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
            /// Split external banks supply one dense row for every version.
            version_rows: if (split_versions) []VersionRow else void = if (split_versions) &.{} else {},
            integral_rows: if (integral_enabled) []u64 else void = if (integral_enabled) &.{} else {},
            integral_row_words: if (integral_enabled) usize else void = if (integral_enabled) 0 else {},
            row_index: []u32,
            key_index: []u32,
            scan_values: []i64 = &.{},
            scan_nonnull: []u64 = &.{},
            scan_live: []u8 = &.{},
            scan_presence: []u64 = &.{},
            /// Explicitly request MVCC scan fallback with all scan spans empty.
            omit_compact_scan: bool = false,
            /// Secondary index entry hashes: one run of key_index.len slots
            /// per bound index (at most table_indexes runs; empty binds none).
            index_slots: []u32 = &.{},
            /// Up to this many logical indexes may use the version arena
            /// when their entry hashes are absent. Zero keeps hash-only admission.
            scan_index_limit: usize = 0,

            pub fn valid(self: Backing) bool {
                if (self.omit_compact_scan) {
                    if (self.scan_values.len != 0 or self.scan_nonnull.len != 0 or
                        self.scan_live.len != 0 or self.scan_presence.len != 0) return false;
                } else if (comptime compact_enabled) {
                    const scan_cells = @mulWithOverflow(self.rows.len, config.columns);
                    if (scan_cells[1] != 0 or self.scan_values.len < scan_cells[0] or
                        self.scan_nonnull.len < self.rows.len or self.scan_live.len < self.rows.len) return false;
                    if (comptime presence_enabled) if (self.scan_presence.len < (presenceWords(self.rows.len) catch return false)) return false;
                }
                if (comptime integral_enabled) {
                    if (self.integral_row_words != 0) {
                        const required = @mulWithOverflow(self.integral_row_words, self.versions.len);
                        if (required[1] != 0 or self.version_rows.len != 0 or self.integral_rows.len < required[0]) return false;
                    } else if (self.integral_rows.len != 0 or self.version_rows.len < self.versions.len) return false;
                } else if (comptime split_versions) {
                    if (self.version_rows.len < self.versions.len) return false;
                }
                return self.rows.len != 0 and self.rows.len <= 0x7fffffff and
                    self.versions.len > self.rows.len and self.versions.len <= 0x7fffffff and
                    self.row_index.len >= self.rows.len * 2 and powerOfTwo(self.row_index.len) and
                    self.key_index.len >= self.versions.len * 2 and powerOfTwo(self.key_index.len) and
                    self.index_slots.len % self.key_index.len == 0 and self.index_slots.len / self.key_index.len <= index_capacity and
                    self.scan_index_limit <= index_capacity;
            }
        };

        fn powerOfTwo(n: usize) bool {
            return n != 0 and (n & (n - 1)) == 0;
        }

        pub const OrderState = enum { empty, one, increasing, decreasing, unordered };
        pub const OrderProof = struct { state: OrderState = .empty, last: V.Cell = .null_value };
        pub const PrimaryDirectory = struct {
            state: enum { empty, candidate, disabled } = .empty,
            base: i64 = 0,
        };

        /// Exact committed state, derived from published row transitions (not
        /// persisted). Old snapshots and transactions with own writes scan.
        /// At most 2^31-1 rows of i64 values fit comfortably in an i128 total.
        pub const ColumnSummary = struct { nonnull: i64 = 0, total: i128 = 0 };
        /// Conservative bounds over every inserted version, including pending
        /// and aborted writes. Never narrowed by deletion or reclamation.
        pub const IntegerBounds = struct { known: bool = false, low: i64 = 0, high: i64 = 0 };
        pub const Summary = struct {
            valid: bool = false,
            csn: u64 = 0,
            rows: i64 = 0,
            primary_bounds: IntegerBounds = .{},
            columns: [config.columns]ColumnSummary = @splat(.{}),
        };
        pub const SummaryGroup = struct {
            key: V.Cell = .null_value,
            rows: i64 = 0,
            columns: [config.columns]ColumnSummary = @splat(.{}),
        };
        pub const Rollup = struct {
            valid: bool = false,
            used: usize = 0,
            groups: [config.summary_groups]SummaryGroup = @splat(.{}),
            buckets: [pow2(config.summary_groups * 2)]u32 = @splat(0),
        };

        /// Per-table constraints beyond NOT NULL and a single-column PRIMARY
        /// KEY (that one keeps Column.primary_key and the key index; a
        /// `primary` entry with one column only records its name). CHECK keeps
        /// its source text (bound per statement like a generation expression);
        /// UNIQUE and composite PRIMARY KEY list their key columns and are
        /// enforced by uniqueCheck over every version (no secondary index).
        pub const constraint_capacity: usize = config.table_constraints;
        pub const ConstraintKind = enum(u8) { check = 1, unique = 2, primary = 3, foreign = 4, exclusion = 5 };
        /// FOREIGN KEY referential actions (pg_constraint confdeltype letters).
        pub const ForeignAction = enum(u8) { no_action = 0, restrict = 1, cascade = 2, set_null = 3, set_default = 4 };
        /// EXCLUDE element operators: `=` (btree/hash equality) and `&&`
        /// (overlap; ranges once a range type exists).
        pub const ExclusionOperator = enum(u8) { equal = 1, overlap = 2 };
        pub const Constraint = struct {
            kind: ConstraintKind = .check,
            name: V.Name = .{},
            /// Primary constraints use Table.primary_constraint_oid, including
            /// an implicit single-column primary key with no Constraint entry.
            oid: u32 = 0,
            nulls_not_distinct: bool = false,
            column_count: u8 = 0,
            columns: [config.columns]u8 = @splat(0),
            expression: V.Text = .{},
            /// DEFERRABLE [INITIALLY DEFERRED] (UNIQUE, PRIMARY KEY, FOREIGN
            /// KEY, EXCLUDE): checked at COMMIT while deferred.
            deferrable: bool = false,
            initially_deferred: bool = false,
            /// FOREIGN KEY: referenced table OID and its key columns (a
            /// primary key or UNIQUE constraint of that table), MATCH SIMPLE.
            ref_oid: u32 = 0,
            ref_columns: [config.columns]u8 = @splat(0),
            on_delete: ForeignAction = .no_action,
            on_update: ForeignAction = .no_action,
            /// EXCLUDE: operator of each key column.
            operators: [config.columns]ExclusionOperator = @splat(.equal),

            pub fn keyColumns(self: *const Constraint) []const u8 {
                return self.columns[0..self.column_count];
            }

            pub fn refColumns(self: *const Constraint) []const u8 {
                return self.ref_columns[0..self.column_count];
            }
        };

        /// Secondary indexes per table and entries per index (types.Config).
        /// Inline storage keeps index_slot_capacity slots per index in the
        /// table. External storage binds Table.index_slots (Backing): each
        /// bound index owns key_index.len slots, the primary-key index's
        /// size (>= 2 x the table's runtime versions), so its entries cover
        /// every version and never cap a table that has version room.
        pub const index_capacity: usize = config.table_indexes;
        pub const index_entry_capacity: usize = if (config.index_entries != 0) config.index_entries else if (config.external_storage) 0 else versions_capacity;
        pub const index_slot_capacity: usize = if (index_entry_capacity == 0 or index_capacity == 0) 0 else pow2(index_entry_capacity * 2);
        /// Whether any table can hold a secondary index entry.
        pub const index_storage: bool = index_capacity != 0 and (config.external_storage or index_slot_capacity != 0);
        /// Indexes per table that Database.bindMemory carves (external only).
        pub const bound_indexes: usize = if (config.external_storage) config.external_indexes else 0;
        pub const IndexSlots = if (config.external_storage) []u32 else [index_capacity][index_slot_capacity]u32;
        comptime {
            if (config.external_storage and config.index_entries != 0) @compileError("index_entries sizes inline index storage; external_storage binds index slots (external_indexes)");
            if (!config.external_storage and config.external_indexes != 0) @compileError("external_indexes requires external_storage");
            if (config.external_indexes > config.table_indexes) @compileError("external_indexes exceeds table_indexes");
        }
        /// Key element that is an expression (its text is in `expressions`).
        pub const expression_key: u8 = 0xff;

        /// CREATE [UNIQUE] INDEX stores the key elements, INCLUDE columns and
        /// partial predicate. Each optional hash entry stores version + 1
        /// under its plain keys and validates visibility on probes.
        /// Scanned indexes use the same version arena. Expression
        /// elements and predicates are definitions bound per statement;
        /// unique indexes use plain columns only.
        pub const Index = struct {
            oid: u32 = 0,
            name: V.Name = .{},
            unique: bool = false,
            nulls_not_distinct: bool = false,
            key_count: u8 = 0,
            keys: [config.columns]u8 = @splat(0),
            /// DESC per key element (bit 0) and NULLS FIRST (bit 1).
            options: [config.columns]u8 = @splat(0),
            include_count: u8 = 0,
            includes: [config.columns]u8 = @splat(0),
            /// Expression elements' source texts in key order, NUL-separated.
            expressions: V.Text = .{},
            /// Partial-index WHERE source text (empty: none).
            predicate: V.Text = .{},

            pub fn keyColumns(self: *const Index) []const u8 {
                return self.keys[0..self.key_count];
            }
        };

        /// PARTITION BY strategy of a partitioned table ('p') and the bound
        /// of a partition (`parent` != 0 with relkind 'r').
        pub const PartitionStrategy = enum(u8) { none = 0, range = 1, list = 2 };
        pub const PartitionBound = enum(u8) { none = 0, range = 1, list = 2, default = 3 };
        pub const partition_values: usize = 4;
        pub const Partition = struct {
            strategy: PartitionStrategy = .none,
            key: u8 = 0,
            bound: PartitionBound = .none,
            /// RANGE: values[0] FROM, values[1] TO; bit 0 / bit 1 of
            /// `unbounded` mark MINVALUE / MAXVALUE. LIST: `count` values.
            count: u8 = 0,
            unbounded: u8 = 0,
            values: [partition_values]V.Cell = @splat(.null_value),
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
            /// Schema OID (cat_namespaces); public unless created in a schema.
            namespace: u32 = 2200,
            primary_constraint_oid: u32 = 0,
            /// Zero retains the legacy table OID + 1 identity.
            primary_index_oid: u32 = 0,
            constraint_count: usize = 0,
            constraints: [constraint_capacity]Constraint = @splat(.{}),
            /// pg_class relkind: 'r' table, 'v' view, 'm' materialized view,
            /// 'p' partitioned table (views and partitioned tables hold no rows).
            relkind: u8 = 'r',
            /// Logical indexes and the backed prefix of their entry hashes.
            index_count: usize = 0,
            indexes: [index_capacity]Index = @splat(.{}),
            index_slots: IndexSlots = if (config.external_storage) &.{} else @splat(@splat(0)),
            scan_index_limit: if (config.external_storage) usize else void = if (config.external_storage) 0 else {},
            /// View / materialized view defining query (SELECT text).
            query: V.Text = .{},
            /// A materialized view created WITH NO DATA is unpopulated.
            populated: bool = true,
            /// OIDs of the relations a view reads (DROP dependency checks).
            depend_count: usize = 0,
            depends: [config.tables]u32 = @splat(0),
            /// INHERITS / PARTITION OF parent table OID (0: none).
            parent: u32 = 0,
            partition: Partition = .{},
            primary_column: ?usize = null,
            primary_directory: PrimaryDirectory = .{},
            /// Conservative strict non-NULL order over physical row slots.
            /// Updates/aborts may discard a proof, never invent one. Not persisted.
            column_order: [config.columns]OrderProof = @splat(.{}),
            summary: Summary = .{},
            /// Conservative bounds on integer cells and DATE day numbers.
            integer_bounds: [config.columns]IntegerBounds = @splat(.{}),
            rollups: [config.columns]Rollup = @splat(.{}),
            // TRUNCATE replaces the relation's contents even for older
            // snapshots that did not already lock the table.
            truncate_csn: u64 = 0,
            pending_truncate: Truncation = .{},
            next_rowid: u64 = 0,
            row_generation: u32 = 0,
            row_high: usize = 0,
            row_used: usize = 0,
            version_high: usize = 0,
            version_used: usize = 0,
            version_free: u32 = 0,
            /// Column-major committed values. Every element below scan_high is
            /// initialized, including directory holes and unsupported columns.
            /// Integer values and exact DATE day counts occupy i64 lanes; a
            /// reader reconstructs the declared Cell tag before evaluation.
            scan_high: usize = 0,
            scan_values: []i64 = &.{},
            scan_nonnull: []u64 = &.{},
            scan_live: []u8 = &.{},
            scan_presence: []u64 = &.{},
            rows: if (config.external_storage) []RowSlot else [config.rows_per_table]RowSlot = if (config.external_storage) &.{} else @splat(.{}),
            versions: if (config.external_storage) []Version else [versions_capacity]Version = if (config.external_storage) &.{} else @splat(.{}),
            version_rows: if (split_versions) []VersionRow else void = if (split_versions) &.{} else {},
            integral_rows: if (integral_enabled) []u64 else void = if (integral_enabled) &.{} else {},
            integral_row_words: if (integral_enabled) usize else void = if (integral_enabled) 0 else {},
            integral_layout: if (integral_enabled) IntegralLayout else void = if (integral_enabled) .{} else {},
            row_index: if (config.external_storage) []u32 else [row_index_capacity]u32 = if (config.external_storage) &.{} else @splat(0),
            key_index: if (config.external_storage) []u32 else [key_index_capacity]u32 = if (config.external_storage) &.{} else @splat(0),
        };

        /// A table every committed reader can see (created and not dropped).
        pub fn committedTable(table: *const Table) bool {
            return table.live and !table.pending_create and table.dead_csn == 0;
        }

        /// The PRIMARY KEY constraint entry (named or composite), if any.
        pub fn primaryConstraint(table: *const Table) ?usize {
            for (table.constraints[0..table.constraint_count], 0..) |*constraint, index| {
                if (constraint.kind == .primary) return index;
            }
            return null;
        }

        /// A table with a primary key owns the next OID for its index.
        pub fn keyed(table: *const Table) bool {
            return table.primary_column != null or primaryConstraint(table) != null;
        }

        /// OIDs a table definition owns: itself and its primary-key index.
        pub fn primaryIndexAlias(table_oid: u32, has_key: bool, explicit_oid: u32) u32 {
            if (!has_key) return 0;
            return if (explicit_oid == 0) table_oid + 1 else explicit_oid;
        }

        pub fn primaryIndexOid(table: *const Table) u32 {
            return primaryIndexAlias(table.oid, keyed(table), table.primary_index_oid);
        }

        /// Contiguous allocation width. An explicit primary alias is separate.
        pub fn oidWidth(table: *const Table) u32 {
            return 1 + @as(u32, @intFromBool(keyed(table) and table.primary_index_oid == 0));
        }

        fn observeBounds(bounds: *IntegerBounds, cell: *const V.Cell) void {
            const value: i64 = switch (cell.*) {
                .integer => cell.integer,
                .date => cell.date,
                else => return,
            };
            if (!bounds.known) {
                bounds.* = .{ .known = true, .low = value, .high = value };
            } else {
                bounds.low = @min(bounds.low, value);
                bounds.high = @max(bounds.high, value);
            }
        }

        /// Conservative hints recomputed from every allocated version after
        /// a relayout: value bounds, no order proof, no dense key directory.
        pub fn rebuildHints(table: *Table) void {
            var row_scratch: VersionRowScratch = undefined;
            table.integer_bounds = @splat(.{});
            for (table.versions[0..table.version_high], 0..) |*version, index| {
                if (version.row == 0) continue;
                for (versionValues(table, index, &row_scratch), table.integer_bounds[0..table.column_count]) |*cell, *bounds| {
                    observeBounds(bounds, cell);
                }
            }
            table.column_order = @splat(.{ .state = .unordered });
            table.primary_directory.state = .disabled;
        }

        /// Rebuilds the row and key indexes from the directory and arena.
        fn rebuildIndexes(table: *Table) void {
            @memset(table.row_index[0..], 0);
            for (0..table.row_high) |slot| if (table.rows[slot].newest != 0) indexRow(table, @intCast(slot));
            if (table.primary_column != null) {
                @memset(table.key_index[0..], 0);
                for (0..table.version_high) |version| {
                    if (table.versions[version].row != 0) indexKeyOnly(table, @intCast(version));
                }
            }
            rebuildSecondary(table);
        }

        /// Relation-level definition beyond columns and constraints: kind,
        /// secondary indexes, view query and dependencies, inheritance and
        /// partitioning. Copied whole by CREATE, ALTER and replay.
        pub const Extras = struct {
            relkind: u8 = 'r',
            index_count: usize = 0,
            indexes: [index_capacity]Index = @splat(.{}),
            query: V.Text = .{},
            populated: bool = true,
            depend_count: usize = 0,
            depends: [config.tables]u32 = @splat(0),
            parent: u32 = 0,
            partition: Partition = .{},
        };

        pub fn extrasOf(table: *const Table) Extras {
            return .{ .relkind = table.relkind, .index_count = table.index_count, .indexes = table.indexes, .query = table.query, .populated = table.populated, .depend_count = table.depend_count, .depends = table.depends, .parent = table.parent, .partition = table.partition };
        }

        /// Installs the extras after reset(); index entries are rebuilt by
        /// the caller (copyRelayout, redefine or rebuildSecondary).
        pub fn setExtras(table: *Table, extras: *const Extras) void {
            table.relkind = extras.relkind;
            table.index_count = extras.index_count;
            // Empty hashes for the installed indexes: external memory starts
            // uninitialized and a reused slot keeps its last table's entries.
            // Callers checked indexFits; a rebuild or copy fills them.
            if (comptime index_storage) for (0..activeHashCount(table)) |which| @memset(slotsOf(table, which), 0);
            table.indexes = extras.indexes;
            table.query = extras.query;
            table.populated = extras.populated;
            table.depend_count = extras.depend_count;
            table.depends = extras.depends;
            table.parent = extras.parent;
            table.partition = extras.partition;
        }

        /// Whether a partition bound admits a key value (NULL only into a
        /// DEFAULT partition or a list naming NULL).
        pub fn partitionContains(partition: *const Partition, key: *const V.Cell) bool {
            switch (partition.bound) {
                .none, .default => return false,
                .range => {
                    if (key.* == .null_value) return false;
                    if (partition.unbounded & 1 == 0 and V.compare(key, &partition.values[0]) < 0) return false;
                    if (partition.unbounded & 2 == 0 and V.compare(key, &partition.values[1]) >= 0) return false;
                    return true;
                },
                .list => {
                    for (partition.values[0..partition.count]) |*value| {
                        if (key.* != .null_value and V.compare(key, value) == 0) return true;
                    }
                    return false;
                },
            }
        }

        /// Whether two sibling partition bounds share a key value.
        pub fn partitionsOverlap(a: *const Partition, b: *const Partition) bool {
            if (a.bound == .default and b.bound == .default) return true;
            if (a.bound != b.bound) return false;
            switch (a.bound) {
                .range => {
                    // [a0, a1) and [b0, b1) meet iff a0 < b1 and b0 < a1.
                    const a_below = (a.unbounded & 1 != 0) or (b.unbounded & 2 != 0) or V.compare(&a.values[0], &b.values[1]) < 0;
                    const b_below = (b.unbounded & 1 != 0) or (a.unbounded & 2 != 0) or V.compare(&b.values[0], &a.values[1]) < 0;
                    return a_below and b_below;
                },
                .list => {
                    for (a.values[0..a.count]) |*value| if (partitionContains(b, value)) return true;
                    return false;
                },
                else => return false,
            }
        }

        /// Whether any part of the definition needs format version 3.
        pub fn extended(table: *const Table) bool {
            if (table.relkind != 'r' or table.index_count != 0 or table.parent != 0 or table.partition.strategy != .none) return true;
            for (table.columns[0..table.column_count]) |*column| if (column.virtual) return true;
            for (table.constraints[0..table.constraint_count]) |*constraint| {
                if (constraint.kind == .foreign or constraint.kind == .exclusion or constraint.deferrable) return true;
            }
            return false;
        }

        fn secondaryHash(index: *const Index, cells: *const [config.columns]V.Cell, mask: usize) usize {
            var hash: u64 = 0x51ed2701a5b3c4d9;
            for (index.keyColumns()) |column| {
                if (column == expression_key) continue;
                const cell = &cells[column];
                const part: u64 = if (cell.* == .null_value) 0x9e3779b9 else V.hash(cell);
                hash = mix(hash ^ part);
            }
            return @intCast(hash & mask);
        }

        /// Entry hash of secondary index `which` (a power of two of slots).
        /// Callers keep which < hashCapacity(table).
        fn slotsOf(table: *Table, which: usize) []u32 {
            if (comptime config.external_storage) {
                const stride = table.key_index.len;
                return table.index_slots[which * stride ..][0..stride];
            }
            return table.index_slots[which][0..];
        }

        fn slotsConst(table: *const Table, which: usize) []const u32 {
            if (comptime config.external_storage) {
                const stride = table.key_index.len;
                return table.index_slots[which * stride ..][0..stride];
            }
            return table.index_slots[which][0..];
        }

        fn hashCapacity(table: *const Table) usize {
            if (comptime !index_storage) return 0;
            if (comptime !config.external_storage) return index_capacity;
            if (table.key_index.len == 0) return 0;
            return @min(index_capacity, table.index_slots.len / table.key_index.len);
        }

        fn activeHashCount(table: *const Table) usize {
            if (comptime !index_storage) return 0;
            if (comptime config.external_storage) {
                if (table.scan_index_limit != 0) return @min(table.index_count, hashCapacity(table));
            }
            return table.index_count;
        }

        pub fn hasIndexHash(table: *const Table, which: usize) bool {
            return which < activeHashCount(table);
        }

        /// Logical index admission, including explicitly enabled scanned indexes.
        pub fn indexLimit(table: *const Table) usize {
            const hashes = hashCapacity(table);
            if (comptime config.external_storage) return @max(hashes, table.scan_index_limit);
            return hashes;
        }

        /// Whether this table slot can carry `count` secondary indexes over
        /// `versions` allocated versions (external entries cover every
        /// version the slot can allocate).
        pub fn indexFits(table: *const Table, count: usize, versions: usize) bool {
            if (count == 0) return true;
            if (count > indexLimit(table)) return false;
            return config.external_storage or versions <= index_entry_capacity;
        }

        fn indexSecondary(table: *Table, version: u32) void {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return;
            for (0..activeHashCount(table)) |which| {
                const slots = slotsOf(table, which);
                const mask = slots.len - 1;
                var position = secondaryHash(&table.indexes[which], borrowVersionRow(table, version, &row_scratch), mask);
                while (slots[position] != 0) position = (position + 1) & mask;
                slots[position] = version + 1;
            }
        }

        /// Backward-shift deletion of slot `start` of secondary index `which`.
        fn removeSecondaryAt(table: *Table, which: usize, start: usize) void {
            var row_scratch: VersionRowScratch = undefined;
            const slots = slotsOf(table, which);
            const mask = slots.len - 1;
            var hole = start;
            var probe = start;
            while (true) {
                probe = (probe + 1) & mask;
                const entry = slots[probe];
                if (entry == 0) break;
                const home = secondaryHash(&table.indexes[which], borrowVersionRow(table, entry - 1, &row_scratch), mask);
                if (((probe -% hole) & mask) <= ((probe -% home) & mask)) {
                    slots[hole] = entry;
                    hole = probe;
                }
            }
            slots[hole] = 0;
        }

        fn unindexSecondary(table: *Table, version: u32) void {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return;
            for (0..activeHashCount(table)) |which| {
                const slots = slotsOf(table, which);
                const mask = slots.len - 1;
                var position = secondaryHash(&table.indexes[which], borrowVersionRow(table, version, &row_scratch), mask);
                while (slots[position] != version + 1) {
                    if (slots[position] == 0) break;
                    position = (position + 1) & mask;
                }
                if (slots[position] == version + 1) removeSecondaryAt(table, which, position);
            }
        }

        /// Rebuilds the backed secondary hashes from the version arena.
        pub fn rebuildSecondary(table: *Table) void {
            if (comptime !index_storage) return;
            const hashes = activeHashCount(table);
            if (hashes == 0) return;
            for (0..hashes) |which| @memset(slotsOf(table, which), 0);
            for (0..table.version_high) |version| {
                if (table.versions[version].row != 0) indexSecondary(table, @intCast(version));
            }
        }

        /// Physical entries of a backed secondary index.
        pub fn indexEntries(table: *const Table, which: usize) usize {
            if (comptime !index_storage) return 0;
            if (!hasIndexHash(table, which)) return 0;
            var count: usize = 0;
            for (slotsConst(table, which)) |entry| {
                if (entry != 0) count += 1;
            }
            return count;
        }

        /// Whether `count` more versions fit every secondary index. External
        /// entries hold every version the arena can allocate.
        pub fn indexRoom(table: *const Table, count: usize) bool {
            if (table.index_count == 0 or config.external_storage) return true;
            return table.version_used + count <= index_entry_capacity;
        }

        fn sameColumns(columns: []const u8, left: *const [config.columns]V.Cell, right: *const [config.columns]V.Cell) bool {
            for (columns) |column| {
                if (V.compare(&left[column], &right[column]) != 0) return false;
            }
            return true;
        }

        /// Versions visible to `snap` whose plain key columns of index
        /// `which` equal `cells`, found through the index (probe path).
        pub fn indexLookup(table: *const Table, which: usize, cells: *const [config.columns]V.Cell, snap: Snapshot, out: []u32) usize {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return 0;
            if (!hasIndexHash(table, which)) return scanLookup(table, which, cells, snap, out);
            const index = &table.indexes[which];
            const slots = slotsConst(table, which);
            const mask = slots.len - 1;
            var count: usize = 0;
            var position = secondaryHash(index, cells, mask);
            while (slots[position] != 0) : (position = (position + 1) & mask) {
                const entry = slots[position] - 1;
                const version = &table.versions[entry];
                if (!plainKeyEqual(index, borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                if (visibleAt(table, version.row - 1, snap) != entry) continue;
                if (count < out.len) out[count] = entry;
                count += 1;
            }
            return count;
        }

        fn plainKeyEqual(index: *const Index, left: *const [config.columns]V.Cell, right: *const [config.columns]V.Cell) bool {
            for (index.keyColumns()) |column| {
                if (column == expression_key) continue;
                const a = &left[column];
                const b = &right[column];
                if ((a.* == .null_value) != (b.* == .null_value)) return false;
                if (a.* != .null_value and V.compare(a, b) != 0) return false;
            }
            return true;
        }

        /// The same versions found by scanning every row (scan path).
        pub fn scanLookup(table: *const Table, which: usize, cells: *const [config.columns]V.Cell, snap: Snapshot, out: []u32) usize {
            var row_scratch: VersionRowScratch = undefined;
            var count: usize = 0;
            for (0..table.row_high) |slot| {
                if (table.rows[slot].newest == 0) continue;
                const version = visibleAt(table, slot, snap) orelse continue;
                if (!plainKeyEqual(&table.indexes[which], borrowVersionRow(table, version, &row_scratch), cells)) continue;
                if (count < out.len) out[count] = version;
                count += 1;
            }
            return count;
        }

        /// UNIQUE index check with the same dirty-snapshot rules on both paths.
        pub fn indexUniqueCheck(table: *const Table, which: usize, cells: *const [config.columns]V.Cell, own_slot: u32, snap: Snapshot, control: ?*types.ExecutionControl) Error!KeyState {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return .free;
            const index = &table.indexes[which];
            if (!index.nulls_not_distinct) for (index.keyColumns()) |column| {
                if (cells[column] == .null_value) return .free;
            };
            if (!hasIndexHash(table, which)) return scanUnique(table, index.keyColumns(), cells, own_slot, snap, control);
            const slots = slotsConst(table, which);
            const mask = slots.len - 1;
            var waiting: ?u16 = null;
            var position = secondaryHash(index, cells, mask);
            while (slots[position] != 0) : (position = (position + 1) & mask) {
                const entry = slots[position] - 1;
                const version = &table.versions[entry];
                if (version.row - 1 == own_slot) continue;
                if (!sameColumns(index.keyColumns(), borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                if (classify(version, entry, snap, &waiting)) |state| return state;
            }
            return if (waiting) |slot| .{ .wait = slot } else .free;
        }

        /// One candidate of a unique check (PostgreSQL's dirty snapshot):
        /// a committed live row or a version this transaction still holds
        /// takes the key; another live transaction's version means waiting.
        pub fn classify(version: *const Version, index: usize, snap: Snapshot, waiting: *?u16) ?KeyState {
            const marked = version.xmax.epoch != 0;
            if (version.xmin_csn == 0) {
                if (snap.own(version.xmin)) {
                    if (marked and snap.own(version.xmax)) return null;
                    return .{ .taken = @intCast(index) };
                }
                if (!marked and waiting.* == null) waiting.* = version.xmin.slot;
                return null;
            }
            if (!marked) return .{ .taken = @intCast(index) };
            if (version.xmax_csn != 0 or snap.own(version.xmax)) return null;
            if (waiting.* == null) waiting.* = version.xmax.slot;
            return null;
        }

        fn relayoutVersion(destination: *Table, source: *const Table, version: usize, sources: []const u8, fills: []const V.Cell) void {
            var old: [config.columns]V.Cell = undefined;
            copyVersionRow(source, version, &old);
            const cells = mutableVersionRow(destination, version);
            for (sources, 0..) |origin, column| cells[column] = if (origin == 0xff) fills[column] else old[origin];
            for (cells[sources.len..]) |*cell| cell.* = .null_value;
        }

        /// ALTER TABLE: copies every row slot and version of `source` into
        /// `destination` (reset with the new definition), keeping rowids,
        /// generations and MVCC headers; new column i reads old column
        /// sources[i], or fills[i] when sources[i] is 0xff. The caller checked
        /// capacity. Committed summaries are rebuilt at publication.
        pub fn copyRelayout(destination: *Table, source: *const Table, sources: []const u8, fills: []const V.Cell) void {
            destination.truncate_csn = source.truncate_csn;
            destination.pending_truncate = source.pending_truncate;
            destination.next_rowid = source.next_rowid;
            destination.row_generation = source.row_generation;
            destination.row_high = source.row_high;
            destination.row_used = source.row_used;
            destination.version_high = source.version_high;
            destination.version_used = source.version_used;
            destination.version_free = source.version_free;
            @memcpy(destination.rows[0..source.row_high], source.rows[0..source.row_high]);
            for (source.versions[0..source.version_high], destination.versions[0..source.version_high], 0..) |*from, *to, version| {
                to.* = from.*;
                if (from.row != 0) relayoutVersion(destination, source, version, sources, fills);
            }
            rebuildIndexes(destination);
            rebuildHints(destination);
        }

        /// Replay of ALTER TABLE in place (replay keeps no old snapshots):
        /// relayout every version, install the definition, rebuild indexes.
        pub fn redefine(table: *Table, name: V.Name, columns: []const V.Column, constraints: []const Constraint, extras: *const Extras, sources: []const u8, fills: []const V.Cell) void {
            for (table.versions[0..table.version_high], 0..) |*entry, version| {
                if (entry.row != 0) relayoutVersion(table, table, version, sources, fills);
            }
            table.name = name;
            table.column_count = columns.len;
            @memcpy(table.columns[0..columns.len], columns);
            table.primary_column = null;
            for (columns, 0..) |column, index| if (column.primary_key) {
                table.primary_column = index;
            };
            setConstraints(table, constraints);
            setExtras(table, extras);
            rebuildIndexes(table);
            rebuildHints(table);
        }

        /// Recomputes the committed summary, rollups and scan projection
        /// from the committed view (publication or replay of a relayout).
        pub fn rebuildCommitted(table: *Table, csn: u64) void {
            initSummary(table, csn);
            table.scan_high = 0;
            for (0..table.row_high) |slot| {
                if (table.rows[slot].newest == 0) continue;
                if (visible(table, slot)) |version| {
                    summarize(table, version, true, csn);
                    scanPublish(table, version, true);
                } else scanPublish(table, table.rows[slot].newest - 1, false);
            }
            rebuildPresence(table);
        }

        /// Installs constraints after reset(); the caller checked capacity.
        pub fn setConstraints(table: *Table, constraints: []const Constraint) void {
            table.constraint_count = constraints.len;
            @memcpy(table.constraints[0..constraints.len], constraints);
        }

        /// Constraints enforced by uniqueCheck: UNIQUE and a composite (or
        /// named multi-column) PRIMARY KEY. A single-column primary key uses
        /// the key index instead.
        pub fn scannedUnique(table: *const Table, constraint: *const Constraint) bool {
            return switch (constraint.kind) {
                .check, .foreign, .exclusion => false,
                .unique => true,
                .primary => table.primary_column == null,
            };
        }

        pub const KeyState = union(enum) { free, taken: u32, wait: u16 };

        /// Whether a proposed key can conflict at all: with NULLS DISTINCT
        /// (the default) a key with any NULL member never does.
        pub fn comparableKey(constraint: *const Constraint, cells: *const [config.columns]V.Cell) bool {
            if (constraint.nulls_not_distinct or constraint.kind == .primary) return true;
            for (constraint.keyColumns()) |column| if (cells[column] == .null_value) return false;
            return true;
        }

        /// Whether an update changed any key column of the constraint.
        pub fn keyChanged(constraint: *const Constraint, old: *const [config.columns]V.Cell, new: *const [config.columns]V.Cell) bool {
            for (constraint.keyColumns()) |column| {
                if (@as(V.CellTag, old[column]) != @as(V.CellTag, new[column]) or V.compare(&old[column], &new[column]) != 0) return true;
            }
            return false;
        }

        /// UNIQUE check against the newest state, with exactly the
        /// dirty-snapshot rules of the primary-key keyCheck: a committed live
        /// row or a version this transaction still holds takes the key; a
        /// version created, or deleted, by another live transaction makes the
        /// inserter wait for it. Row `own_slot` (the row being updated) never
        /// conflicts. Scans the version arena: O(versions x key columns).
        pub fn uniqueCheck(table: *const Table, constraint: *const Constraint, cells: *const [config.columns]V.Cell, own_slot: u32, snap: Snapshot) KeyState {
            if (!comparableKey(constraint, cells)) return .free;
            return scanUnique(table, constraint.keyColumns(), cells, own_slot, snap, null) catch unreachable;
        }

        fn scanUnique(table: *const Table, columns: []const u8, cells: *const [config.columns]V.Cell, own_slot: u32, snap: Snapshot, control: anytype) Error!KeyState {
            var row_scratch: VersionRowScratch = undefined;
            var waiting: ?u16 = null;
            for (table.versions[0..table.version_high], 0..) |*version, entry| {
                if (comptime @TypeOf(control) != @TypeOf(null)) if (control) |accounting| try accounting.checkpoint();
                if (version.row == 0 or version.row - 1 == own_slot) continue;
                if (!sameColumns(columns, borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                if (classify(version, entry, snap, &waiting)) |state| return state;
            }
            return if (waiting) |slot| .{ .wait = slot } else .free;
        }

        /// Prepare a free table slot for a new definition. Unused capacity is
        /// neither cleared nor read; only both indices are reset.
        pub fn reset(table: *Table, oid: u32, name: V.Name, columns: []const V.Column) void {
            table.oid = oid;
            table.name = name;
            if (comptime integral_enabled) if (integralBank(table)) {
                table.integral_layout = IntegralLayout.forColumns(columns).?;
            };
            table.column_count = columns.len;
            @memcpy(table.columns[0..columns.len], columns);
            table.primary_column = null;
            for (columns, 0..) |column, index| if (column.primary_key) {
                table.primary_column = index;
            };
            table.namespace = 2200;
            table.primary_constraint_oid = 0;
            table.primary_index_oid = 0;
            table.constraint_count = 0;
            setExtras(table, &.{});
            table.truncate_csn = 0;
            table.pending_truncate = .{};
            table.next_rowid = 1;
            table.dead_csn = 0;
            table.pending_drop = false;
            table.row_high = 0;
            table.row_used = 0;
            table.version_high = 0;
            table.version_used = 0;
            table.version_free = 0;
            table.scan_high = 0;
            table.column_order = @splat(.{});
            table.primary_directory = .{};
            table.summary = .{};
            table.integer_bounds = @splat(.{});
            resetRollups(table);
            @memset(table.row_index[0..], 0);
            if (table.primary_column != null) @memset(table.key_index[0..], 0);
        }

        /// Copy a live table's observable state into distinct storage.
        pub fn copyTable(destination: *Table, source: *const Table) void {
            destination.oid = source.oid;
            destination.name = source.name;
            destination.column_count = source.column_count;
            @memcpy(destination.columns[0..source.column_count], source.columns[0..source.column_count]);
            if (comptime integral_enabled) if (integralBank(destination)) {
                destination.integral_layout = IntegralLayout.forColumns(destination.columns[0..destination.column_count]).?;
            };
            destination.namespace = source.namespace;
            destination.primary_constraint_oid = source.primary_constraint_oid;
            destination.primary_index_oid = source.primary_index_oid;
            destination.constraint_count = source.constraint_count;
            @memcpy(destination.constraints[0..source.constraint_count], source.constraints[0..source.constraint_count]);
            setExtras(destination, &extrasOf(source));
            // Entries are version indices, identical in an inline copy; an
            // external copy rehashes them for its own masks (below).
            if (comptime !config.external_storage) destination.index_slots = source.index_slots;
            destination.primary_column = source.primary_column;
            destination.primary_directory = source.primary_directory;
            destination.column_order = source.column_order;
            destination.summary = source.summary;
            destination.integer_bounds = source.integer_bounds;
            destination.rollups = source.rollups;
            destination.truncate_csn = source.truncate_csn;
            destination.pending_truncate = source.pending_truncate;
            destination.next_rowid = source.next_rowid;
            destination.row_generation = source.row_generation;
            destination.row_high = source.row_high;
            destination.row_used = source.row_used;
            destination.version_high = source.version_high;
            destination.version_used = source.version_used;
            destination.version_free = source.version_free;
            const copy_projection = hasCompactScan(destination) and hasCompactScan(source);
            destination.scan_high = 0;
            if (copy_projection) {
                destination.scan_high = source.scan_high;
                @memcpy(destination.scan_live[0..source.scan_high], source.scan_live[0..source.scan_high]);
                @memcpy(destination.scan_nonnull[0..source.scan_high], source.scan_nonnull[0..source.scan_high]);
                for (0..config.columns) |column| @memcpy(destination.scan_values[column * destination.rows.len..][0..source.scan_high], source.scan_values[column * source.rows.len..][0..source.scan_high]);
                if(comptime presence_enabled) {
                    const blocks=(source.scan_high+63)/64;
                    for(0..config.columns) |column| @memcpy(destination.scan_presence[presenceAt(destination,column,0)..][0..blocks*4],source.scan_presence[presenceAt(source,column,0)..][0..blocks*4]);
                }
            }
            @memcpy(destination.rows[0..source.row_high], source.rows[0..source.row_high]);
            @memcpy(destination.versions[0..source.version_high], source.versions[0..source.version_high]);
            if (comptime split_versions) {
                for (source.versions[0..source.version_high], 0..) |*entry, version| {
                    if (entry.row == 0) continue;
                    if (comptime integral_enabled) if (integralBank(destination)) {
                        var row_scratch: VersionRowScratch = undefined;
                        writeIntegral(destination, version, borrowVersionRow(source, version, &row_scratch));
                        continue;
                    };
                    copyVersionRow(source, version, mutableVersionRow(destination, version));
                }
            }
            if (comptime config.external_storage) {
                @memset(destination.row_index, 0);
                @memset(destination.key_index, 0);
                for (0..destination.row_high) |slot| if (destination.rows[slot].newest != 0) indexRow(destination, @intCast(slot));
                if (destination.primary_column != null) for (0..destination.version_high) |version| {
                    if (destination.versions[version].row != 0) indexKeyOnly(destination, @intCast(version));
                };
                rebuildSecondary(destination);
            } else {
                destination.row_index = source.row_index;
                if (source.primary_column != null) destination.key_index = source.key_index;
            }
            if (!copy_projection and hasCompactScan(destination)) rebuildScanFromVersions(destination);
        }

        pub inline fn hasCompactScan(table: *const Table) bool {
            return compact_enabled and table.scan_values.len != 0;
        }

        /// The copy has no active writers. Build the optional projection from
        /// committed versions, initializing holes and trailing deleted slots.
        fn rebuildScanFromVersions(table: *Table) void {
            scanEnsure(table, table.row_high);
            for (0..table.row_high) |slot| {
                if (visible(table, slot)) |version| scanPublish(table, version, true);
            }
        }

        fn scanEnsure(table: *Table, high: usize) void {
            if (high <= table.scan_high) return;
            if(comptime presence_enabled) {
                const first=(table.scan_high+63)/64;const end=(high+63)/64;
                for(0..config.columns) |column| @memset(table.scan_presence[presenceAt(table,column,first)..][0..(end-first)*4],0);
            }
            @memset(table.scan_live[table.scan_high..high], 0);
            @memset(table.scan_nonnull[table.scan_high..high], 0);
            for (0..config.columns) |column| @memset(table.scan_values[column * table.rows.len + table.scan_high..column * table.rows.len + high], 0);
            table.scan_high = high;
        }

        fn presenceAt(table:*const Table,column:usize,block:usize) usize {
            return (column*((table.rows.len+63)/64)+block)*4;
        }
        fn presenceAdd(table:*Table,slot:usize,column:usize,value:i64) void {
            const residue:u8=@truncate(@as(u64,@bitCast(value)));
            table.scan_presence[presenceAt(table,column,slot/64)+residue/64]|=@as(u64,1)<<@as(u6,@truncate(residue));
        }
        /// Absence is definitive; presence can be a residue collision or a
        /// retained old/deleted value. Call only on a snapshot-safe projection.
        pub fn blockMayContain(table:*const Table,column:usize,start:usize,count:usize,value:i64) bool {
            if(comptime !presence_enabled) return true;
            if (table.scan_presence.len == 0) return true;
            if(start%64!=0 or count>64 or start>=table.scan_high or count>table.scan_high-start) return true;
            const residue:u8=@truncate(@as(u64,@bitCast(value)));
            return table.scan_presence[presenceAt(table,column,start/64)+residue/64]&(@as(u64,1)<<@as(u6,@truncate(residue)))!=0;
        }
        fn rebuildPresence(table:*Table) void {
            if(comptime presence_enabled) {
                if (table.scan_presence.len == 0) return;
                const blocks=(table.scan_high+63)/64;
                for(0..config.columns) |column| @memset(table.scan_presence[presenceAt(table,column,0)..][0..blocks*4],0);
                for(0..table.scan_high) |slot| {
                    if(table.scan_live[slot]==0) continue;
                    for(0..table.column_count) |column| {
                        const ty=table.columns[column].data_type;
                        if(ty!=.integer and ty!=.integer32 and ty!=.smallint and ty!=.oid and ty!=.date) continue;
                        if(table.scan_nonnull[slot]&(@as(u64,1)<<@intCast(column))!=0) presenceAdd(table,slot,column,table.scan_values[column*table.rows.len+slot]);
                    }
                }
            }
        }

        /// Publication/replay only, after durable success. Private versions and
        /// aborts never alter this projection. No allocation or fallible work.
        pub fn scanPublish(table: *Table, version: u32, live: bool) void {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime compact_enabled) {
                if (!hasCompactScan(table)) return;
                const entry = &table.versions[version];
                const slot = entry.row - 1;
                scanEnsure(table, @as(usize, slot) + 1);
                table.scan_live[slot] = @intFromBool(live);
                var mask: u64 = 0;
                for (versionValues(table, version, &row_scratch), 0..) |*cell, column| {
                    if (cell.* != .null_value) mask |= @as(u64, 1) << @intCast(column);
                    table.scan_values[column * table.rows.len + slot] = switch(cell.*) {
                        .integer=>cell.integer,.date=>cell.date,else=>0,
                    };
                    if(comptime presence_enabled) if(live and (cell.*==.integer or cell.*==.date)) presenceAdd(table,slot,column,table.scan_values[column*table.rows.len+slot]);
                }
                table.scan_nonnull[slot] = mask;
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

        pub fn publishTruncate(table: *Table, csn: u64) void {
            table.truncate_csn = csn;
            table.pending_truncate = .{};
            if (table.summary.valid) table.summary.csn = csn;
        }

        /// The version of `slot` visible to `snap`, if any.
        pub fn visibleAt(table: *const Table, slot: usize, snap: Snapshot) ?u32 {
            var ref = table.rows[slot].newest;
            while (ref != 0) {
                const version = &table.versions[ref - 1];
                if (created(version, snap)) {
                    if (deleted(version, snap)) return null;
                    if (version.xmin_csn != 0 and table.truncate_csn > snap.csn) return null;
                    const truncated = &table.pending_truncate;
                    if (snap.own(truncated.owner) and truncated.cid < snap.cid and
                        (version.xmin_csn != 0 or version.xmin_cid < truncated.cid)) return null;
                    return ref - 1;
                }
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

        inline fn rowAtVersion(table: *const Table, version: usize) *const VersionRow {
            if (comptime split_versions) return &table.version_rows[version];
            return &table.versions[version].cells;
        }

        inline fn mutableVersionRow(table: *Table, version: usize) *VersionRow {
            if (comptime split_versions) return &table.version_rows[version];
            return &table.versions[version].cells;
        }

        pub inline fn integralBank(table: *const Table) bool {
            if (comptime integral_enabled) return table.integral_row_words != 0;
            return false;
        }

        pub fn anyIntegralBank(tables: *const [config.tables]Table) bool {
            if (comptime integral_enabled) for (tables) |*table| {
                if (integralBank(table)) return true;
            };
            return false;
        }

        pub fn integralRowWords(columns: []const V.Column) ?usize {
            const layout = IntegralLayout.forColumns(columns) orelse return null;
            return @max(1, (layout.bytes + 7) / 8);
        }

        /// The bound bank size and schema must agree before a table is installed.
        pub fn schemaFits(table: *const Table, columns: []const V.Column) bool {
            if (comptime integral_enabled) if (integralBank(table)) {
                const words = integralRowWords(columns) orelse return false;
                return words <= table.integral_row_words;
            };
            return true;
        }

        pub fn createBankFits(table: *const Table, columns: []const V.Column, indexes: usize) bool {
            if (comptime integral_enabled) return schemaFits(table, columns) and indexFits(table, indexes, 0);
            return true;
        }

        fn readIntegral(table: *const Table, version: usize, column: usize) V.Cell {
            const stride = table.integral_row_words;
            const bytes = mem.sliceAsBytes(table.integral_rows[version * stride ..][0..stride]);
            const bit: u8 = @as(u8, 1) << @as(u3, @truncate(column));
            if ((bytes[column / 8] & bit) == 0) return .null_value;
            const at = table.integral_layout.offsets[column];
            return switch (table.columns[column].data_type) {
                .smallint => .{ .integer = mem.readInt(i16, bytes[at..][0..2], .little) },
                .integer32 => .{ .integer = mem.readInt(i32, bytes[at..][0..4], .little) },
                .oid => .{ .integer = mem.readInt(u32, bytes[at..][0..4], .little) },
                .date => .{ .date = mem.readInt(i32, bytes[at..][0..4], .little) },
                .integer => .{ .integer = mem.readInt(i64, bytes[at..][0..8], .little) },
                else => unreachable,
            };
        }

        /// Values have already passed DML coercion or change-record validation.
        fn writeIntegral(table: *Table, version: usize, cells: []const V.Cell) void {
            const stride = table.integral_row_words;
            const bytes = mem.sliceAsBytes(table.integral_rows[version * stride ..][0..stride]);
            @memset(bytes[0 .. (table.column_count + 7) / 8], 0);
            for (cells[0..table.column_count], 0..) |*cell, column| {
                if (cell.* == .null_value) continue;
                const bit: u8 = @as(u8, 1) << @as(u3, @truncate(column));
                bytes[column / 8] |= bit;
                const at = table.integral_layout.offsets[column];
                switch (table.columns[column].data_type) {
                    .smallint => mem.writeInt(i16, bytes[at..][0..2], @intCast(cell.integer), .little),
                    .integer32 => mem.writeInt(i32, bytes[at..][0..4], @intCast(cell.integer), .little),
                    .oid => mem.writeInt(u32, bytes[at..][0..4], @intCast(cell.integer), .little),
                    .date => mem.writeInt(i32, bytes[at..][0..4], cell.date, .little),
                    .integer => mem.writeInt(i64, bytes[at..][0..8], cell.integer, .little),
                    else => unreachable,
                }
            }
        }

        /// The view can borrow the arena or the caller's scratch. Use one
        /// scratch per live row and keep it in scope until the last read.
        pub inline fn borrowVersionRow(table: *const Table, version: usize, scratch: *VersionRowScratch) *const VersionRow {
            if (comptime integral_enabled) if (integralBank(table)) {
                copyVersionRow(table, version, scratch);
                return scratch;
            };
            return rowAtVersion(table, version);
        }

        /// Materialize a row the caller can modify or retain independently.
        pub inline fn copyVersionRow(table: *const Table, version: usize, destination: *VersionRow) void {
            if (comptime integral_enabled) if (integralBank(table)) {
                for (destination[0..table.column_count], 0..) |*cell, column| cell.* = readIntegral(table, version, column);
                @memset(destination[table.column_count..], .null_value);
                return;
            };
            destination.* = rowAtVersion(table, version).*;
        }

        /// A single logical cell, valid until its scratch is reused.
        pub inline fn borrowVersionCell(table: *const Table, version: usize, column: usize, scratch: *V.Cell) *const V.Cell {
            if (comptime integral_enabled) if (integralBank(table)) {
                scratch.* = readIntegral(table, version, column);
                return scratch;
            };
            return &rowAtVersion(table, version)[column];
        }

        /// Logical values in storage column order, excluding dense padding.
        pub inline fn versionValues(table: *const Table, version: usize, scratch: *VersionRowScratch) []const V.Cell {
            return borrowVersionRow(table, version, scratch)[0..table.column_count];
        }

        pub inline fn versionCellEquals(table: *const Table, version: usize, column: usize, value: *const V.Cell) bool {
            var scratch: V.Cell = undefined;
            return V.compare(borrowVersionCell(table, version, column, &scratch), value) == 0;
        }

        fn keyHome(table: *const Table, entry: u32) usize {
            var scratch: V.Cell = undefined;
            return V.hash(borrowVersionCell(table, entry - 1, table.primary_column.?, &scratch)) & (table.key_index.len - 1);
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
        pub fn summarize(table: *Table, version: u32, add: bool, csn: u64) void {
            changeSummary(table, version, add, csn);
            if (table.summary.valid and table.summary.rows == 0) {
                resetRollups(table);
                table.summary.primary_bounds = .{};
            }
        }

        pub fn summarizeUpdate(table: *Table, old: u32, new: u32, csn: u64) void {
            // An update does not empty/reinitialize the table's summaries.
            changeSummary(table, old, false, csn);
            changeSummary(table, new, true, csn);
        }

        fn changeSummary(table: *Table, version: u32, add: bool, csn: u64) void {
            var row_scratch: VersionRowScratch = undefined;
            if (!table.summary.valid) return;
            const cells = versionValues(table, version, &row_scratch);
            observeSummary(&table.summary, cells, table.primary_column, add, csn);
            summarizeGroups(table, cells, add);
        }

        pub fn observeSummary(summary: *Summary, cells: []const V.Cell, primary_column: ?usize, add: bool, csn: u64) void {
            const sign: i64 = if (add) 1 else -1;
            summary.rows += sign;
            summary.csn = csn;
            if (add) if (primary_column) |primary| {
                const value = &cells[primary];
                if (value.* == .integer) {
                    const bounds = &summary.primary_bounds;
                    if (!bounds.known) bounds.* = .{ .known = true, .low = value.integer, .high = value.integer }
                    else { bounds.low = @min(bounds.low, value.integer); bounds.high = @max(bounds.high, value.integer); }
                }
            };
            for (cells, summary.columns[0..cells.len]) |*cell, *column| {
                if (cell.* == .null_value) continue;
                column.nonnull += sign;
                if (cell.* == .integer) column.total += @as(i128, cell.integer) * sign;
            }
        }

        pub fn initSummary(table: *Table, csn: u64) void {
            table.summary = .{ .valid = true, .csn = csn };
            resetRollups(table);
        }

        fn resetRollups(table: *Table) void {
            if (comptime config.summary_groups != 0) for (&table.rollups) |*rollup| {
                rollup.valid = true;
                rollup.used = 0;
                @memset(&rollup.buckets, 0);
            };
        }

        /// Equality must also preserve the displayed representative. NUMERIC
        /// scale, float signed zero and equivalent interval forms need more
        /// representative tracking, so retain ordinary grouping for those.
        pub fn summaryKeyType(data_type: types.DataType) bool {
            return switch (data_type) {
                .integer, .integer32, .smallint, .oid, .text, .name, .boolean,
                .date, .timestamp, .timestamptz => true,
                else => false,
            };
        }

        fn summarizeGroups(table: *Table, cells: []const V.Cell, add: bool) void {
            if (comptime config.summary_groups != 0) {
                const sign: i64 = if (add) 1 else -1;
                for (table.columns[0..table.column_count], table.rollups[0..table.column_count], 0..) |definition, *rollup, key_column| {
                    if (!rollup.valid) continue;
                    if (!summaryKeyType(definition.data_type)) continue;
                    const key = &cells[key_column];
                    const hash: usize = if (key.* == .null_value) 0x9e3779b9 else V.hash(key);
                    const mask = rollup.buckets.len - 1;
                    var bucket = hash & mask;
                    while (rollup.buckets[bucket] != 0 and V.compare(&rollup.groups[rollup.buckets[bucket] - 1].key, key) != 0) bucket = (bucket + 1) & mask;
                    const at: usize = if (rollup.buckets[bucket] == 0) rollup.used else rollup.buckets[bucket] - 1;
                    if (rollup.buckets[bucket] == 0) {
                        if (!add or at == rollup.groups.len) { rollup.valid = false; continue; }
                        rollup.groups[at] = .{ .key = key.* };
                        rollup.buckets[bucket] = @intCast(at + 1);
                        rollup.used += 1;
                    }
                    const group = &rollup.groups[at];
                    if (!add and group.rows == 0) { rollup.valid = false; continue; }
                    group.rows += sign;
                    for (cells, group.columns[0..table.column_count]) |*cell, *column| {
                        if (cell.* == .null_value) continue;
                        column.nonnull += sign;
                        if (cell.* == .integer) column.total += @as(i128, cell.integer) * sign;
                    }
                }
            }
        }

        pub fn indexKey(table: *Table, version: u32) void {
            var row_scratch: VersionRowScratch = undefined;
            for (versionValues(table, version, &row_scratch), table.integer_bounds[0..table.column_count]) |*cell, *bounds| {
                observeBounds(bounds, cell);
            }
            noteOrder(table, version);
            notePrimaryDirectory(table, version);
            indexKeyOnly(table, version);
            indexSecondary(table, version);
        }

        fn notePrimaryDirectory(table: *Table, version: u32) void {
            const column = table.primary_column orelse return;
            const hint = &table.primary_directory;
            if (hint.state == .disabled) return;
            const entry = &table.versions[version];
            var scratch: V.Cell = undefined;
            const key = borrowVersionCell(table, version, column, &scratch);
            if (key.* != .integer) { hint.state = .disabled; return; }
            if (hint.state == .empty) {
                if (entry.row != 1 or entry.older != 0) { hint.state = .disabled; return; }
                hint.* = .{ .state = .candidate, .base = key.integer };
            }
            // Dense key-to-slot mappings are stronger eligibility evidence
            // than monotonic order: sparse ordered keys disable speculation.
            if (@as(i128, key.integer) != @as(i128, hint.base) + entry.row - 1)
                hint.state = .disabled;
        }

        fn noteOrder(table: *Table, version: u32) void {
            const entry = &table.versions[version];
            for (table.column_order[0..table.column_count], 0..) |*proof, column| {
                var scratch: V.Cell = undefined;
                const value = borrowVersionCell(table, version, column, &scratch);
                if (entry.older != 0) {
                    if (entry.older == version + 1 or table.versions[entry.older - 1].row == 0) {
                        proof.state = .unordered;
                    } else if (proof.state != .unordered) {
                        var previous: V.Cell = undefined;
                        const old = borrowVersionCell(table, entry.older - 1, column, &previous);
                        if (V.compare(value, old) != 0) proof.state = .unordered;
                    }
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

        /// Probe the primary-key index using the dirty-snapshot rules shared
        /// with secondary unique indexes. The row being updated never conflicts.
        pub fn primaryKeyCheck(table: *const Table, key: *const V.Cell, own_slot: u32, snap: Snapshot) KeyState {
            const column = table.primary_column orelse return .free;
            if (key.* == .null_value) return .free;
            var waiting: ?u16 = null;
            const mask = table.key_index.len - 1;
            var position = V.hash(key) & mask;
            while (true) : (position = (position + 1) & mask) {
                const entry = table.key_index[position];
                if (entry == 0) break;
                const index = entry - 1;
                if (!versionCellEquals(table, index, column, key)) continue;
                const version = &table.versions[index];
                if (version.row - 1 == own_slot) continue;
                if (classify(version, index, snap, &waiting)) |state| return state;
            }
            return if (waiting) |slot| .{ .wait = slot } else .free;
        }

        /// Visible version whose primary key equals value. Returning the hit
        /// avoids walking its MVCC chain twice in read execution.
        pub fn lookupVersionAt(table: *const Table, value: *const V.Cell, snap: Snapshot) ?u32 {
            const column = table.primary_column orelse return null;
            if (value.* == .null_value) return null;
            // Ordered integral keys often share an offset with directory slots.
            // This is only a candidate: validate the canonical visible version
            // and its exact key before accepting it. Holes, compaction, key
            // changes and unmatched older/own versions retain the hash probe.
            if (value.* == .integer and table.primary_directory.state == .candidate) {
                const offset = @as(i128, value.integer) - table.primary_directory.base;
                if (offset >= 0 and offset < table.row_high) {
                    if (visibleAt(table, @intCast(offset), snap)) |candidate| {
                        var scratch: V.Cell = undefined;
                        const key = borrowVersionCell(table, candidate, column, &scratch);
                        if (key.* == .integer and key.integer == value.integer) return candidate;
                    }
                }
            }
            var position = V.hash(value) & (table.key_index.len - 1);
            while (true) {
                const entry = table.key_index[position];
                if (entry == 0) return null;
                if (versionCellEquals(table, entry - 1, column, value)) {
                    const slot = table.versions[entry - 1].row - 1;
                    if (visibleAt(table, slot, snap) == entry - 1) return entry - 1;
                }
                position = (position + 1) & (table.key_index.len - 1);
            }
        }

        /// Directory slot of the row visible to `snap` whose key equals value.
        pub fn lookupKeyAt(table: *const Table, value: *const V.Cell, snap: Snapshot) ?u32 {
            const version = lookupVersionAt(table, value, snap) orelse return null;
            return table.versions[version].row - 1;
        }

        /// Directory slot of the committed row whose key equals value.
        pub fn lookupKey(table: *const Table, value: *const V.Cell) ?u32 {
            return lookupKeyAt(table, value, committed_view);
        }

        pub fn freeVersions(table: *const Table) usize {
            return table.versions.len - table.version_used;
        }

        /// Installs a logical row after the caller has reserved capacity.
        /// Linking the version does not publish it to other snapshots.
        /// Indexing and the transaction or replay bookkeeping are separate.
        pub inline fn createVersion(table: *Table, origin: VersionOrigin, cells: []const V.Cell) u32 {
            const version = allocVersion(table);
            const full_width = cells.len == config.columns;
            table.versions[version] = .{
                .row = origin.row + 1,
                .xmin = origin.xmin,
                .xmin_cid = origin.cid,
                .xmin_csn = origin.csn,
                .older = origin.older,
                .cells = if (comptime split_versions) {} else if (full_width) cells[0..config.columns].* else @splat(.null_value),
            };
            if (comptime integral_enabled) if (integralBank(table)) {
                writeIntegral(table, version, cells);
                table.rows[origin.row].newest = version + 1;
                return version;
            };
            if (comptime split_versions) {
                mutableVersionRow(table, version).* = if (full_width) cells[0..config.columns].* else @splat(.null_value);
            }
            if (!full_width) @memcpy(mutableVersionRow(table, version)[0..cells.len], cells);
            table.rows[origin.row].newest = version + 1;
            return version;
        }

        fn allocVersion(table: *Table) u32 {
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
            unindexSecondary(table, version);
            freeVersion(table, version);
            if (row.newest == 0) freeRow(table, slot);
        }

        /// Reclamation case 2 at the Raw's horizon (Wave 1: its current csn).
        pub fn vacuum(table: *Table, horizon: u64) usize {
            return vacuumRange(table, horizon, 0, table.version_high);
        }

        pub fn vacuumRange(table: *Table, horizon: u64, first: usize, end: usize) usize {
            var freed: usize = 0;
            for (first..end) |index| {
                const version = &table.versions[index];
                if (version.row == 0 or version.xmax_csn == 0 or version.xmax_csn > horizon) continue;
                reclaimVersion(table, @intCast(index));
                freed += 1;
            }
            return freed;
        }

        fn compact(table: *Table) void {
            const maintain_projection = hasCompactScan(table);
            var write: usize = 0;
            for (0..table.row_high) |read| {
                if (table.rows[read].newest == 0) continue;
                if (maintain_projection) {
                    if (read == write and read >= table.scan_high) {
                        table.scan_live[write] = 0;
                        table.scan_nonnull[write] = 0;
                        for (0..config.columns) |column| table.scan_values[column * table.rows.len + write] = 0;
                    }
                }
                if (read != write) {
                    table.primary_directory.state = .disabled;
                    if (maintain_projection) {
                        if (read < table.scan_high) {
                            table.scan_live[write] = table.scan_live[read];
                            table.scan_nonnull[write] = table.scan_nonnull[read];
                            for (0..config.columns) |column| table.scan_values[column * table.rows.len + write] = table.scan_values[column * table.rows.len + read];
                        } else {
                            // An unpublished appended row has no committed data.
                            table.scan_live[write] = 0;
                            table.scan_nonnull[write] = 0;
                            for (0..config.columns) |column| table.scan_values[column * table.rows.len + write] = 0;
                        }
                    }
                    table.rows[write] = table.rows[read];
                    table.row_generation +%= 1;
                    table.rows[write].generation = table.row_generation;
                    var ref = table.rows[write].newest;
                    while (ref != 0) : (ref = table.versions[ref - 1].older) table.versions[ref - 1].row = @intCast(write + 1);
                }
                write += 1;
            }
            table.row_high = write;
            if (maintain_projection) {
                table.scan_high = write;
                rebuildPresence(table);
            }
            @memset(table.row_index[0..], 0);
            for (0..write) |slot| indexRow(table, @intCast(slot));
        }

        /// On-demand reclamation so `count` new versions fit, else 53200.
        pub fn ensureVersions(table: *Table, count: usize, horizon: u64) Error!void {
            if (freeVersions(table) >= count and indexRoom(table, count)) return;
            _ = vacuum(table, horizon);
            if (freeVersions(table) < count) return error.VersionCapacity;
            if (!indexRoom(table, count)) return error.IndexCapacity;
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
