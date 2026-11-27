//! Versioned table storage: S01 subset (Layer 0, design §4.3).
//!
//! Each table holds a row directory {rowid, generation, newest version}, a
//! rowid -> slot open-addressing index (default load <= 50%), a version arena of
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
const character = @import("character.sig");
const mem = @import("std").mem;
const Error = types.Error;

/// Maximum load for caller-owned row and version index slices.
pub const HashLoad = enum {
    half,
    three_quarters,

    fn allows(self: HashLoad, slots: usize, entries: usize) bool {
        const limit = slots / 2 + if (self == .three_quarters) slots / 4 else 0;
        return entries <= limit;
    }

    pub fn slotsFor(self: HashLoad, entries: usize) Error!usize {
        var slots: usize = 2;
        while (!self.allows(slots, entries)) {
            const next = @mulWithOverflow(slots, 2);
            if (next[1] != 0) return error.InvalidParameterValue;
            slots = next[0];
        }
        return slots;
    }
};

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
        const compact_stamps = config.compact_external_version_stamps;
        pub const VersionRow = [config.columns]V.Cell;
        /// Stored SQL belongs to the query-expansion budget, not to the
        /// inline size of a user data cell. The existing WAL uses u16 bytes.
        pub const query_capacity = @min(@max(config.text_bytes, config.expansion_bytes), 0xffff);
        pub const QueryText = struct {
            bytes: [query_capacity]u8 = @splat(0),
            len: usize = 0,

            pub fn slice(self: *const QueryText) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        pub fn presenceWords(rows:usize) Error!usize {
            const rounded=@addWithOverflow(rows,63);if(rounded[1]!=0) return error.InvalidParameterValue;
            const words=@mulWithOverflow(rounded[0]/64,config.columns*4);if(words[1]!=0) return error.InvalidParameterValue;
            return words[0];
        }

        comptime {
            if (compact_stamps and !split_versions) @compileError("compact version stamps require split external storage");
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
            row_link: u32 = 0,
            xmin: if (compact_stamps) void else TxRef = if (compact_stamps) {} else .{},
            xmin_cid: u32 = 0,
            xmin_csn: if (compact_stamps) void else u64 = if (compact_stamps) {} else 0,
            xmax: if (compact_stamps) void else TxRef = if (compact_stamps) {} else .{},
            xmax_cid: u32 = 0,
            xmax_csn: if (compact_stamps) void else u64 = if (compact_stamps) {} else 0,
            creation_stamp: if (compact_stamps) u64 else void = if (compact_stamps) 0 else {},
            deletion_stamp: if (compact_stamps) u64 else void = if (compact_stamps) 0 else {},
            /// Older version index + 1, or the next free slot + 1 while free.
            older_link: u32 = 0,
            cells: if (split_versions) void else VersionRow = if (split_versions) {} else @splat(.null_value),

            // Both links admit at most 31 bits. Steal no bits from the CSN,
            // pending owner or command, including their maximum values.
            const committed_flag: u32 = 0x80000000;
            const link_mask: u32 = ~committed_flag;
            const PendingStamp = packed struct(u64) {
                sub: u16,
                slot: u16,
                epoch: u32,

                inline fn encode(tx: TxRef) u64 {
                    return @bitCast(PendingStamp{ .sub = tx.sub, .slot = tx.slot, .epoch = tx.epoch });
                }

                inline fn decode(word: u64) TxRef {
                    const stamp: PendingStamp = @bitCast(word);
                    return .{ .sub = stamp.sub, .slot = stamp.slot, .epoch = stamp.epoch };
                }
            };

            /// One-based links use zero for an unused version or no older version.
            pub inline fn rowLink(self: *const Version) u32 {
                return if (comptime compact_stamps) self.row_link & link_mask else self.row_link;
            }

            pub inline fn rowSlot(self: *const Version) u32 {
                return self.rowLink() - 1;
            }

            inline fn setRowLink(self: *Version, link: u32) void {
                const state = if (comptime compact_stamps) self.row_link & committed_flag else 0;
                self.row_link = state | link;
            }

            inline fn olderLink(self: *const Version) u32 {
                return if (comptime compact_stamps) self.older_link & link_mask else self.older_link;
            }

            inline fn setOlderLink(self: *Version, link: u32) void {
                const state = if (comptime compact_stamps) self.older_link & committed_flag else 0;
                self.older_link = state | link;
            }

            pub const PendingChange = struct { tx: TxRef, cid: u32 };

            pub inline fn creationCsn(self: *const Version) u64 {
                if (comptime compact_stamps) return if (self.row_link & committed_flag != 0) self.creation_stamp else 0;
                return self.xmin_csn;
            }

            pub inline fn deletionCsn(self: *const Version) u64 {
                if (comptime compact_stamps) return if (self.older_link & committed_flag != 0) self.deletion_stamp else 0;
                return self.xmax_csn;
            }

            pub inline fn pendingCreation(self: *const Version) ?PendingChange {
                if (self.creationCsn() != 0) return null;
                const tx = if (comptime compact_stamps) PendingStamp.decode(self.creation_stamp) else self.xmin;
                return .{ .tx = tx, .cid = self.xmin_cid };
            }

            pub inline fn pendingDeletion(self: *const Version) ?PendingChange {
                if (self.deletionCsn() != 0 or !self.hasDeletion()) return null;
                const tx = if (comptime compact_stamps) PendingStamp.decode(self.deletion_stamp) else self.xmax;
                return .{ .tx = tx, .cid = self.xmax_cid };
            }

            pub inline fn hasDeletion(self: *const Version) bool {
                if (comptime compact_stamps) return self.deletion_stamp != 0;
                return self.xmax.epoch != 0;
            }

            pub inline fn creationAfter(self: *const Version, snap: Snapshot) bool {
                // A live transaction's own creations are still pending.
                if (comptime compact_stamps) return self.creationCsn() > snap.csn;
                return self.creationCsn() > snap.csn and !snap.own(self.xmin);
            }

            pub inline fn deletionOwnedBy(self: *const Version, snap: Snapshot) bool {
                if (comptime compact_stamps) {
                    const change = self.pendingDeletion() orelse return false;
                    return snap.own(change.tx);
                }
                return snap.own(self.xmax);
            }

            /// Set the mutation owner and command. Publication sets its CSN.
            pub inline fn markDeletion(self: *Version, tx: TxRef, cid: u32) void {
                if (comptime compact_stamps) {
                    // TRUNCATE can walk an old snapshot. A newer committed
                    // deletion stays committed and cannot become ours.
                    if (self.older_link & committed_flag != 0) return;
                    self.deletion_stamp = if (tx.epoch == 0) 0 else PendingStamp.encode(tx);
                } else self.xmax = tx;
                self.xmax_cid = cid;
            }

            pub inline fn clearDeletion(self: *Version) void {
                if (comptime compact_stamps) {
                    self.older_link &= link_mask;
                    self.deletion_stamp = 0;
                } else {
                    self.xmax = .{};
                    self.xmax_csn = 0;
                }
                self.xmax_cid = 0;
            }

            pub inline fn publishCreation(self: *Version, csn: u64) void {
                if (comptime compact_stamps) {
                    self.row_link |= committed_flag;
                    self.creation_stamp = csn;
                } else self.xmin_csn = csn;
            }

            pub inline fn publishDeletion(self: *Version, csn: u64) void {
                if (comptime compact_stamps) {
                    self.older_link |= committed_flag;
                    self.deletion_stamp = csn;
                } else self.xmax_csn = csn;
            }

            inline fn initCreation(self: *Version, origin: VersionOrigin) void {
                self.xmin_cid = origin.cid;
                if (comptime compact_stamps) {
                    if (origin.csn == 0) {
                        self.creation_stamp = PendingStamp.encode(origin.xmin);
                    } else self.publishCreation(origin.csn);
                } else {
                    self.xmin = origin.xmin;
                    self.xmin_csn = origin.csn;
                }
            }
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
                        .varchar, .bpchar => text: {
                            const length = character.declared(column.typmod) orelse return null;
                            const bytes = @min(config.text_bytes, length * 4);
                            if (bytes > 255) return null;
                            break :text 1 + bytes;
                        },
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
            hash_load: HashLoad = .half,
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
                    self.hash_load.allows(self.row_index.len, self.rows.len) and powerOfTwo(self.row_index.len) and
                    self.hash_load.allows(self.key_index.len, self.versions.len) and powerOfTwo(self.key_index.len) and
                    self.indexRunsValid() and self.scan_index_limit <= index_capacity;
            }

            /// Words of each index run: a hash of key_index.len slots or an
            /// ordered index's node arena over every version (0: overflow).
            pub fn indexStride(self: Backing) usize {
                return indexRunWords(self.key_index.len, self.versions.len) catch 0;
            }

            fn indexRunsValid(self: Backing) bool {
                if (self.index_slots.len == 0) return true;
                const stride = self.indexStride();
                return stride != 0 and self.index_slots.len % stride == 0 and self.index_slots.len / stride <= index_capacity;
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
            /// ADD ... NOT VALID CHECK / FOREIGN KEY whose existing rows
            /// were not checked (pg_constraint.convalidated false) until
            /// VALIDATE CONSTRAINT (ddl-dml, wave 4).
            not_valid: bool = false,
            /// NOT ENFORCED CHECK / FOREIGN KEY: never checked
            /// (pg_constraint.conenforced and convalidated false).
            not_enforced: bool = false,

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
        /// Words of one inline index run: a hash index uses its first
        /// index_slot_capacity slots, an ordered index the whole run as its
        /// node arena (B11 wave 5).
        pub const index_run_capacity: usize = if (index_slot_capacity == 0) 0 else @max(index_slot_capacity, treeWordsOf(index_entry_capacity));
        /// Whether any table can hold a secondary index entry.
        pub const index_storage: bool = index_capacity != 0 and (config.external_storage or index_slot_capacity != 0);
        /// Indexes per table that Database.bindMemory carves (external only).
        pub const bound_indexes: usize = if (config.external_storage) config.external_indexes else 0;
        pub const IndexSlots = if (config.external_storage) []u32 else [index_capacity][index_run_capacity]u32;

        // ---- ordered (btree) index sizing (B11 wave 5) ----------------------

        pub const btree_fanout: usize = config.index_fanout;
        const half_fanout: usize = btree_fanout / 2;
        /// u32 words of one tree node: count | leaf flag, next leaf, previous
        /// leaf, a spare word, then `btree_fanout` cached keys (two words
        /// each), the entry references (leaf: version; internal: child node)
        /// and the version of each entry's first leaf entry.
        pub const node_words: usize = 4 + 4 * btree_fanout;

        fn depthEntries(depth: usize) usize {
            var entries: u64 = 2;
            for (0..depth) |_| {
                entries *= half_fanout;
                if (entries > 0xffffffff) return 0xffffffff;
            }
            return @intCast(entries - 1);
        }

        /// Height limit of every ordered index: Config.index_depth, or the
        /// smallest height any addressable entry count fits.
        pub const btree_depth: usize = if (config.index_depth != 0) config.index_depth else derived: {
            @setEvalBranchQuota(100000);
            var depth: usize = 1;
            while (depthEntries(depth) < 0x7fffffff) depth += 1;
            break :derived depth;
        };
        /// Entries an ordered index can hold within btree_depth: a tree of
        /// height h + 1 holds at least 2 x (fanout / 2)^h entries.
        pub const btree_entries: usize = depthEntries(btree_depth);
        comptime {
            if (btree_fanout < 8 or btree_fanout > 1024 or btree_fanout % 2 != 0) @compileError("index_fanout must be even and between 8 and 1024");
            if (btree_depth > 64) @compileError("index_depth exceeds 64");
        }

        /// Nodes of a tree of `entries` entries in the worst case (every
        /// non-root node half full).
        pub fn treeNodes(entries: usize) usize {
            var level: usize = @max(1, (entries + half_fanout - 1) / half_fanout);
            var total = level;
            while (level > 1) {
                level = (level + half_fanout - 1) / half_fanout;
                total += level;
            }
            return total;
        }

        fn treeWordsOf(entries: usize) usize {
            @setEvalBranchQuota(100000);
            return (1 + treeNodes(@min(entries, btree_entries))) * node_words;
        }

        /// u32 words of an ordered index's node arena (its metadata node
        /// included) for `entries` entries.
        pub fn treeWords(entries: usize) Error!usize {
            const nodes = 1 + treeNodes(@min(entries, btree_entries));
            const words = @mulWithOverflow(nodes, node_words);
            if (words[1] != 0) return error.InvalidParameterValue;
            return words[0];
        }

        /// Words of one external index run: a hash of `key_slots` slots or
        /// the node arena of a tree over `versions` entries.
        pub fn indexRunWords(key_slots: usize, versions: usize) Error!usize {
            return @max(key_slots, try treeWords(versions));
        }
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
            /// USING hash (change-log index flag 4). Every other index,
            /// including definitions logged before access methods were
            /// recorded, is an ordered (btree) index.
            hash: bool = false,

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

        const ScanHint = struct { slot: u32 align(64) = 0 };

        pub const Table = struct {
            live: bool = false,
            pending_create: bool = false,
            pending_late_primary: bool = false,
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
            /// Words of each bound index run (Backing.indexStride).
            index_stride: if (config.external_storage) usize else void = if (config.external_storage) 0 else {},
            /// View / materialized view defining query (SELECT text).
            query: QueryText = .{},
            /// A materialized view created WITH NO DATA is unpopulated.
            populated: bool = true,
            /// A view's WITH CHECK OPTION (F311-04, F751, B11 wave 5): 0
            /// none, 1 LOCAL, 2 CASCADED. Durable as change-log op 115.
            check_option: u8 = 0,
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
            /// Advisory position on its own cache line, outside the row directory.
            seqscan_hint: ScanHint = .{},
        };

        const seqscan_grain: usize = 256;

        pub fn supportsSynchronizedScan(table: *const Table) bool {
            return config.synchronized_scan_rows != 0 and table.row_high >= config.synchronized_scan_rows and
                table.row_high > seqscan_grain and table.row_high <= 0xffffffff and
                (table.relkind == 'r' or table.relkind == 'm') and !table.pending_create and table.pending_truncate.owner.epoch == 0;
        }

        /// Each cursor fixes its own physical range and wraps at most once.
        /// Readers share only an advisory location through relaxed atomics.
        pub const PhysicalScan = struct {
            high: usize,
            start: usize,
            next_slot: usize,
            left: usize,
            shared: bool,

            pub const Range = struct { start: usize, end: usize };

            pub fn init(table: *const Table, enabled: bool) PhysicalScan {
                const shared = enabled and supportsSynchronizedScan(table);
                const hint = if (shared) @atomicLoad(u32, &table.seqscan_hint.slot, .monotonic) else 0;
                const start = if (hint < table.row_high) hint else 0;
                return .{ .high = table.row_high, .start = start, .next_slot = start, .left = table.row_high, .shared = shared };
            }

            fn report(table: *const Table, slot: usize) void {
                const writable: *Table = @constCast(table);
                const next_hint: u32 = @intCast(slot);
                if (@atomicLoad(u32, &writable.seqscan_hint.slot, .monotonic) != next_hint) {
                    @atomicStore(u32, &writable.seqscan_hint.slot, next_hint, .monotonic);
                }
            }

            pub fn next(self: *PhysicalScan, table: *const Table, max_rows: usize) ?Range {
                if (self.left == 0) {
                    if (self.shared) {
                        report(table, self.start);
                        self.shared = false;
                    }
                    return null;
                }
                const start = self.next_slot;
                const limit = if (self.shared) @min(max_rows, seqscan_grain - start % seqscan_grain) else max_rows;
                const count = @min(@min(self.left, self.high - start), limit);
                if (self.shared and start % seqscan_grain == 0) report(table, start);
                self.left -= count;
                const end = start + count;
                self.next_slot = if (end == self.high) 0 else end;
                return .{ .start = start, .end = end };
            }
        };

        /// A bound physical bank, independent of catalog and MVCC metadata.
        pub fn backingOf(table: *const Table) Backing {
            if (comptime !config.external_storage) @compileError("backingOf requires external storage");
            return .{
                .rows = table.rows,
                .versions = table.versions,
                .version_rows = if (comptime split_versions) table.version_rows else {},
                .integral_rows = if (comptime integral_enabled) table.integral_rows else {},
                .integral_row_words = if (comptime integral_enabled) table.integral_row_words else {},
                .row_index = table.row_index,
                .key_index = table.key_index,
                .scan_values = table.scan_values,
                .scan_nonnull = table.scan_nonnull,
                .scan_live = table.scan_live,
                .scan_presence = table.scan_presence,
                .index_slots = table.index_slots,
                .scan_index_limit = table.scan_index_limit,
            };
        }

        /// The caller has validated each bank and its disjoint ownership.
        pub fn bindBacking(table: *Table, backing: Backing) void {
            if (comptime !config.external_storage) @compileError("bindBacking requires external storage");
            table.rows = backing.rows;
            table.versions = backing.versions;
            if (comptime split_versions) table.version_rows = backing.version_rows;
            if (comptime integral_enabled) {
                table.integral_rows = backing.integral_rows;
                table.integral_row_words = backing.integral_row_words;
            }
            table.row_index = backing.row_index;
            table.key_index = backing.key_index;
            table.scan_values = backing.scan_values;
            table.scan_nonnull = backing.scan_nonnull;
            table.scan_live = backing.scan_live;
            table.scan_presence = backing.scan_presence;
            table.index_slots = backing.index_slots;
            table.scan_index_limit = backing.scan_index_limit;
            table.index_stride = backing.indexStride();
        }

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
                if (version.rowLink() == 0) continue;
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
                    if (table.versions[version].rowLink() != 0) indexKeyOnly(table, @intCast(version));
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
            query: QueryText = .{},
            populated: bool = true,
            depend_count: usize = 0,
            depends: [config.tables]u32 = @splat(0),
            parent: u32 = 0,
            partition: Partition = .{},
            check_option: u8 = 0,
        };

        pub fn extrasOf(table: *const Table) Extras {
            return .{ .relkind = table.relkind, .index_count = table.index_count, .indexes = table.indexes, .query = table.query, .populated = table.populated, .depend_count = table.depend_count, .depends = table.depends, .parent = table.parent, .partition = table.partition, .check_option = table.check_option };
        }

        /// Installs the extras after reset(); index entries are rebuilt by
        /// the caller (copyRelayout, redefine or rebuildSecondary).
        pub fn setExtras(table: *Table, extras: *const Extras) void {
            table.relkind = extras.relkind;
            table.index_count = extras.index_count;
            table.indexes = extras.indexes;
            // Empty hashes and trees for the installed indexes: external
            // memory starts uninitialized and a reused slot keeps its last
            // table's entries. Callers checked indexFits; a rebuild or copy
            // fills them.
            if (comptime index_storage) for (0..activeHashCount(table)) |which| clearIndex(table, which);
            table.query = extras.query;
            table.populated = extras.populated;
            table.depend_count = extras.depend_count;
            table.depends = extras.depends;
            table.parent = extras.parent;
            table.partition = extras.partition;
            table.check_option = extras.check_option;
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

        /// The whole storage run of secondary index `which`. Callers keep
        /// which < hashCapacity(table).
        fn runOf(table: *Table, which: usize) []u32 {
            if (comptime config.external_storage) {
                const stride = table.index_stride;
                return table.index_slots[which * stride ..][0..stride];
            }
            return table.index_slots[which][0..];
        }

        fn runConst(table: *const Table, which: usize) []const u32 {
            if (comptime config.external_storage) {
                const stride = table.index_stride;
                return table.index_slots[which * stride ..][0..stride];
            }
            return table.index_slots[which][0..];
        }

        /// Entry hash of hash index `which` (a power of two of slots at the
        /// start of its run).
        fn slotsOf(table: *Table, which: usize) []u32 {
            if (comptime config.external_storage) return runOf(table, which)[0..table.key_index.len];
            return table.index_slots[which][0..index_slot_capacity];
        }

        fn slotsConst(table: *const Table, which: usize) []const u32 {
            if (comptime config.external_storage) return runConst(table, which)[0..table.key_index.len];
            return table.index_slots[which][0..index_slot_capacity];
        }

        fn hashCapacity(table: *const Table) usize {
            if (comptime !index_storage) return 0;
            if (comptime !config.external_storage) return index_capacity;
            if (table.key_index.len == 0 or table.index_stride == 0) return 0;
            return @min(index_capacity, table.index_slots.len / table.index_stride);
        }

        fn activeHashCount(table: *const Table) usize {
            if (comptime !index_storage) return 0;
            if (comptime config.external_storage) {
                if (table.scan_index_limit != 0) return @min(table.index_count, hashCapacity(table));
            }
            return table.index_count;
        }

        /// Whether index `which` has entries (a hash or a tree); others are
        /// scanned over the version arena.
        pub fn hasIndexHash(table: *const Table, which: usize) bool {
            return which < activeHashCount(table);
        }

        /// Whether index `which` is an ordered index with a tree.
        pub fn hasIndexTree(table: *const Table, which: usize) bool {
            return hasIndexHash(table, which) and !table.indexes[which].hash;
        }

        /// Logical index admission, including explicitly enabled scanned indexes.
        pub fn indexLimit(table: *const Table) usize {
            const hashes = hashCapacity(table);
            if (comptime config.external_storage) return @max(hashes, table.scan_index_limit);
            return hashes;
        }

        /// Entries one index of this table can hold: the inline entry
        /// capacity (every version under external storage), within the
        /// ordered index height limit.
        fn entryLimit() usize {
            if (comptime config.external_storage) return btree_entries;
            return @min(index_entry_capacity, btree_entries);
        }

        /// Whether this table slot can carry `count` secondary indexes over
        /// `versions` allocated versions (external entries cover every
        /// version the slot can allocate).
        pub fn indexFits(table: *const Table, count: usize, versions: usize) bool {
            if (count == 0) return true;
            if (count > indexLimit(table)) return false;
            return versions <= entryLimit();
        }

        fn clearIndex(table: *Table, which: usize) void {
            if (table.indexes[which].hash) @memset(slotsOf(table, which), 0) else @memset(runOf(table, which)[0..node_words], 0);
        }

        fn indexSecondary(table: *Table, version: u32) void {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return;
            for (0..activeHashCount(table)) |which| {
                if (!table.indexes[which].hash) {
                    treeInsert(table, which, version);
                    continue;
                }
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
                if (!table.indexes[which].hash) {
                    treeDelete(table, which, version);
                    continue;
                }
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

        /// Rebuilds the backed secondary hashes and trees from the version arena.
        pub fn rebuildSecondary(table: *Table) void {
            if (comptime !index_storage) return;
            const hashes = activeHashCount(table);
            if (hashes == 0) return;
            for (0..hashes) |which| clearIndex(table, which);
            for (0..table.version_high) |version| {
                if (table.versions[version].rowLink() != 0) indexSecondary(table, @intCast(version));
            }
        }

        /// Physical entries of a backed secondary index (a tree counts its
        /// leaf entries).
        pub fn indexEntries(table: *const Table, which: usize) usize {
            if (comptime !index_storage) return 0;
            if (!hasIndexHash(table, which)) return 0;
            if (!table.indexes[which].hash) return treeCount(runConst(table, which));
            var count: usize = 0;
            for (slotsConst(table, which)) |entry| {
                if (entry != 0) count += 1;
            }
            return count;
        }

        /// Whether `count` more versions fit every secondary index. External
        /// entries hold every version the arena can allocate.
        pub fn indexRoom(table: *const Table, count: usize) bool {
            if (table.index_count == 0) return true;
            return table.version_used + count <= entryLimit();
        }

        /// Bytes an ordered index entry spends on one value.
        fn cellBytes(cell: *const V.Cell) usize {
            return switch (cell.*) {
                .null_value => 0,
                .text, .jsonb, .bpchar, .bytea, .array, .range, .xml, .tsvector, .tsquery, .geo, .multirange => |*text| text.len,
                inline else => |value| @sizeOf(@TypeOf(value)),
            };
        }

        /// Ordered index admission of a new version (before it is created):
        /// the entry's key and INCLUDE bytes stay within index_key_bytes and
        /// every tree can still split along a full path (IndexCapacity, 54000).
        pub fn admitVersion(table: *const Table, cells: []const V.Cell) Error!void {
            if (comptime !index_storage) return;
            for (table.indexes[0..table.index_count], 0..) |*index, which| {
                if (index.hash) continue;
                var bytes: usize = 0;
                for (index.keyColumns()) |column| {
                    if (column != expression_key and column < cells.len) bytes += cellBytes(&cells[column]);
                }
                for (index.includes[0..index.include_count]) |column| {
                    if (column < cells.len) bytes += cellBytes(&cells[column]);
                }
                if (bytes > config.index_key_bytes) return error.IndexCapacity;
                if (!hasIndexHash(table, which)) continue;
                const run = runConst(table, which);
                if (freeNodes(run) < nodeConst(run, 0)[meta_height] + 1) return error.IndexCapacity;
            }
        }

        fn sameColumns(columns: []const u8, left: *const [config.columns]V.Cell, right: *const [config.columns]V.Cell) bool {
            for (columns) |column| {
                if (V.compare(&left[column], &right[column]) != 0) return false;
            }
            return true;
        }

        /// The leading plain key elements of an ordered index as an
        /// equality span over `cells` (a row in column order).
        fn plainSpan(index: *const Index, cells: *const [config.columns]V.Cell, span: *Span) void {
            span.* = .{};
            for (index.keyColumns()) |column| {
                if (column == expression_key) break;
                span.cells[span.eq] = cells[column];
                span.eq += 1;
            }
        }

        /// Versions visible to `snap` whose plain key columns of index
        /// `which` equal `cells`, found through the index (probe path).
        pub fn indexLookup(table: *const Table, which: usize, cells: *const [config.columns]V.Cell, snap: Snapshot, out: []u32) usize {
            var row_scratch: VersionRowScratch = undefined;
            if (comptime !index_storage) return 0;
            if (!hasIndexHash(table, which)) return scanLookup(table, which, cells, snap, out);
            const index = &table.indexes[which];
            var count: usize = 0;
            if (!index.hash) {
                var span: Span = undefined;
                plainSpan(index, cells, &span);
                var scan = indexScan(table, which, &span, false);
                while (scanNext(table, which, &scan)) |entry| {
                    if (!plainKeyEqual(index, borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                    if (visibleAt(table, table.versions[entry].rowSlot(), snap) != entry) continue;
                    if (count < out.len) out[count] = entry;
                    count += 1;
                }
                return count;
            }
            const slots = slotsConst(table, which);
            const mask = slots.len - 1;
            var position = secondaryHash(index, cells, mask);
            while (slots[position] != 0) : (position = (position + 1) & mask) {
                const entry = slots[position] - 1;
                const version = &table.versions[entry];
                if (!plainKeyEqual(index, borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                if (visibleAt(table, version.rowSlot(), snap) != entry) continue;
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
            var waiting: ?u16 = null;
            if (!index.hash) {
                // Every candidate is an entry with an equal key: a range of
                // the tree (unique indexes have plain key columns only).
                var span: Span = undefined;
                plainSpan(index, cells, &span);
                var scan = indexScan(table, which, &span, false);
                while (scanNext(table, which, &scan)) |entry| {
                    if (control) |accounting| try accounting.checkpoint();
                    const version = &table.versions[entry];
                    if (version.rowSlot() == own_slot) continue;
                    if (!sameColumns(index.keyColumns(), borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                    if (classify(version, entry, snap, &waiting)) |state| return state;
                }
                return if (waiting) |slot| .{ .wait = slot } else .free;
            }
            const slots = slotsConst(table, which);
            const mask = slots.len - 1;
            var position = secondaryHash(index, cells, mask);
            while (slots[position] != 0) : (position = (position + 1) & mask) {
                const entry = slots[position] - 1;
                const version = &table.versions[entry];
                if (version.rowSlot() == own_slot) continue;
                if (!sameColumns(index.keyColumns(), borrowVersionRow(table, entry, &row_scratch), cells)) continue;
                if (classify(version, entry, snap, &waiting)) |state| return state;
            }
            return if (waiting) |slot| .{ .wait = slot } else .free;
        }

        // ---- ordered (btree) index trees (B11 wave 5) -----------------------
        //
        // An ordered index is a B+tree of version references in the index's
        // run: node 0 holds the tree's metadata, every other node is a leaf
        // or an internal node of node_words words. A leaf entry is (cached
        // key, version). An internal entry is (cached key, child, version)
        // of its child's first leaf entry, so every separator is a live entry
        // of the tree: a reclaimed version never leaves a stale separator.
        // Entries order by the key elements (DESC and NULLS FIRST per
        // element, values by the engine's comparator: code-point order for
        // text), then by row slot (heap order, the order a stable sort of a
        // scan keeps for ties), then by version. Expression elements do not
        // take part in the order. Every version is an entry, visible or not,
        // until reclamation removes it; readers filter by visibility.
        //
        // Inserts split full nodes upward (the left half keeps half + 1
        // entries), deletes borrow from a sibling with more than half or
        // merge with it, so every non-root node keeps at least half its
        // fanout: the node arena sized by treeNodes always suffices and
        // every operation touches at most btree_depth nodes per level step.

        const key_at: usize = 4;
        const ref_at: usize = 4 + 2 * btree_fanout;
        const min_at: usize = 4 + 3 * btree_fanout;
        const leaf_flag: u32 = 0x10000;
        const meta_root: usize = 0;
        const meta_height: usize = 1;
        const meta_free: usize = 2;
        const meta_high: usize = 3;
        const meta_entries: usize = 4;
        const meta_free_count: usize = 5;
        /// Cached key of a value the comparator alone orders.
        const opaque_key: u64 = 0x8000000000000000;
        const null_cell: V.Cell = .null_value;

        inline fn nodeAt(run: []u32, node: u32) []u32 {
            return run[@as(usize, node) * node_words ..][0..node_words];
        }

        inline fn nodeConst(run: []const u32, node: u32) []const u32 {
            return run[@as(usize, node) * node_words ..][0..node_words];
        }

        inline fn nodeCount(n: []const u32) usize {
            return n[0] & 0xffff;
        }

        inline fn nodeLeaf(n: []const u32) bool {
            return n[0] & leaf_flag != 0;
        }

        inline fn setCount(n: []u32, count: usize) void {
            n[0] = (n[0] & leaf_flag) | @as(u32, @intCast(count));
        }

        inline fn entryKey(n: []const u32, i: usize) u64 {
            return @as(u64, n[key_at + 2 * i + 1]) << 32 | n[key_at + 2 * i];
        }

        inline fn entryRef(n: []const u32, i: usize) u32 {
            return n[ref_at + i];
        }

        inline fn entryMin(n: []const u32, i: usize) u32 {
            return n[min_at + i];
        }

        inline fn setEntry(n: []u32, i: usize, key: u64, ref: u32, min: u32) void {
            n[key_at + 2 * i] = @truncate(key);
            n[key_at + 2 * i + 1] = @truncate(key >> 32);
            n[ref_at + i] = ref;
            n[min_at + i] = min;
        }

        inline fn setMin(n: []u32, i: usize, key: u64, min: u32) void {
            n[key_at + 2 * i] = @truncate(key);
            n[key_at + 2 * i + 1] = @truncate(key >> 32);
            n[min_at + i] = min;
        }

        inline fn copyEntry(dst: []u32, di: usize, src: []const u32, si: usize) void {
            setEntry(dst, di, entryKey(src, si), entryRef(src, si), entryMin(src, si));
        }

        fn moveEntries(dst: []u32, di: usize, src: []const u32, si: usize, count: usize) void {
            for (0..count) |k| copyEntry(dst, di + k, src, si + k);
        }

        /// Opens a hole at `pos` of a node holding `count` entries.
        fn shiftRight(n: []u32, pos: usize, count: usize) void {
            var k = count;
            while (k > pos) : (k -= 1) copyEntry(n, k, n, k - 1);
        }

        /// Closes entry `pos` of a node holding `count` entries.
        fn shiftLeft(n: []u32, pos: usize, count: usize) void {
            for (pos + 1..count) |k| copyEntry(n, k - 1, n, k);
        }

        fn allocNode(run: []u32, leaf: bool) u32 {
            const meta = nodeAt(run, 0);
            var node: u32 = undefined;
            if (meta[meta_free] != 0) {
                node = meta[meta_free];
                meta[meta_free] = nodeConst(run, node)[1];
                meta[meta_free_count] -= 1;
            } else {
                if (meta[meta_high] == 0) meta[meta_high] = 1;
                node = meta[meta_high];
                meta[meta_high] += 1;
            }
            const n = nodeAt(run, node);
            n[0] = if (leaf) leaf_flag else 0;
            n[1] = 0;
            n[2] = 0;
            n[3] = 0;
            return node;
        }

        fn freeNode(run: []u32, node: u32) void {
            const meta = nodeAt(run, 0);
            const n = nodeAt(run, node);
            n[0] = 0;
            n[1] = meta[meta_free];
            meta[meta_free] = node;
            meta[meta_free_count] += 1;
        }

        /// Nodes a tree can still allocate.
        fn freeNodes(run: []const u32) usize {
            const meta = nodeConst(run, 0);
            const capacity = run.len / node_words;
            const high = @max(1, meta[meta_high]);
            if (high > capacity) return 0;
            return capacity - high + meta[meta_free_count];
        }

        fn treeCount(run: []const u32) usize {
            const meta = nodeConst(run, 0);
            if (meta[meta_root] == 0) return 0;
            var node = meta[meta_root];
            while (!nodeLeaf(nodeConst(run, node))) node = entryRef(nodeConst(run, node), 0);
            var count: usize = 0;
            while (node != 0) : (node = nodeConst(run, node)[1]) count += nodeCount(nodeConst(run, node));
            return count;
        }

        /// The order of one key element: NULLs first or last per element,
        /// values by the engine comparator, reversed for DESC.
        fn elementOrder(a: *const V.Cell, b: *const V.Cell, option: u8) i8 {
            const a_null = a.* == .null_value;
            const b_null = b.* == .null_value;
            if (a_null or b_null) {
                if (a_null and b_null) return 0;
                return if (a_null == (option & 2 != 0)) -1 else 1;
            }
            const order = V.compare(a, b);
            return if (option & 1 != 0) -order else order;
        }

        /// The order of two values of one key element with index options
        /// `option` (bit 0 DESC, bit 1 NULLS FIRST).
        pub fn keyOrder(a: *const V.Cell, b: *const V.Cell, option: u8) i8 {
            return elementOrder(a, b, option);
        }

        /// Whether two versions have equal plain key elements in index `which`.
        pub fn sameIndexKey(table: *const Table, which: usize, left: u32, right: u32) bool {
            var left_scratch: VersionRowScratch = undefined;
            var right_scratch: VersionRowScratch = undefined;
            const index = &table.indexes[which];
            const a = borrowVersionRow(table, left, &left_scratch);
            const b = borrowVersionRow(table, right, &right_scratch);
            for (index.keyColumns(), index.options[0..index.key_count]) |column, option| {
                if (column == expression_key) continue;
                if (elementOrder(&a[column], &b[column], option) != 0) return false;
            }
            return true;
        }

        fn signedKey(value: i64) u64 {
            return @as(u64, @bitCast(value)) ^ 0x8000000000000000;
        }

        fn bytesKey(bytes: []const u8) u64 {
            var key: u64 = 0;
            for (0..8) |i| {
                key <<= 8;
                if (i < bytes.len) key |= bytes[i];
            }
            return key;
        }

        /// The cached (abbreviated) key of a first key element: an order
        /// the element order never contradicts (a < b implies key(a) <=
        /// key(b)), so unequal cached keys decide and equal ones fall back
        /// to the comparator.
        pub fn abbreviate(cell: *const V.Cell, option: u8) u64 {
            if (cell.* == .null_value) return if (option & 2 != 0) 0 else 0xffffffffffffffff;
            const raw: u64 = switch (cell.*) {
                .integer => |value| signedKey(value),
                .date => |value| signedKey(value),
                .timestamp, .timestamptz, .time, .money => |value| signedKey(value),
                .boolean => |value| @intFromBool(value),
                .pg_lsn, .xid8 => |value| value,
                .regtype, .regproc => |value| value,
                .pg_internal_char => |value| value,
                .text, .bytea => |*text| bytesKey(text.slice()),
                .bpchar => |*text| bytesKey(character.trimmed(text.slice())),
                else => opaque_key,
            };
            return if (option & 1 != 0) ~raw else raw;
        }

        fn rowKey(index: *const Index, row: *const VersionRow) u64 {
            if (index.key_count == 0 or index.keys[0] == expression_key) return opaque_key;
            return abbreviate(&row[index.keys[0]], index.options[0]);
        }

        /// A position in the order: a version's own entry, or a probe of the
        /// first `count` key elements (`cells`, the last one `tail` when
        /// set) that sorts before (-1) or after (+1) every equal entry.
        const Target = struct {
            row: ?*const VersionRow = null,
            cells: [*]const V.Cell = undefined,
            tail: ?*const V.Cell = null,
            count: usize = 0,
            key: u64 = 0,
            sentinel: i8 = 0,
            slot: u32 = 0,
            version: u32 = 0,

            fn cell(self: *const Target, index: *const Index, i: usize) *const V.Cell {
                if (self.row) |row| return &row[index.keys[i]];
                if (self.tail) |tail| if (i + 1 == self.count) return tail;
                return &self.cells[i];
            }
        };

        fn probeKey(index: *const Index, target: *const Target) u64 {
            if (target.count == 0 or index.keys[0] == expression_key) return opaque_key;
            return abbreviate(target.cell(index, 0), index.options[0]);
        }

        fn versionTarget(table: *const Table, index: *const Index, version: u32, scratch: *VersionRowScratch) Target {
            const row = borrowVersionRow(table, version, scratch);
            return .{ .row = row, .count = index.key_count, .key = rowKey(index, row), .slot = table.versions[version].rowSlot(), .version = version };
        }

        /// Order of entry (version, cached key) against a target.
        fn compareEntry(table: *const Table, index: *const Index, version: u32, key: u64, target: *const Target, scratch: *VersionRowScratch) i8 {
            if (target.count != 0) {
                if (key != target.key) return if (key < target.key) -1 else 1;
                const row = borrowVersionRow(table, version, scratch);
                for (0..target.count) |i| {
                    const column = index.keys[i];
                    if (column == expression_key) continue;
                    const order = elementOrder(&row[column], target.cell(index, i), index.options[i]);
                    if (order != 0) return order;
                }
            }
            if (target.sentinel != 0) return -target.sentinel;
            const slot = table.versions[version].rowSlot();
            if (slot != target.slot) return if (slot < target.slot) -1 else 1;
            if (version != target.version) return if (version < target.version) -1 else 1;
            return 0;
        }

        /// The child of an internal node whose subtree holds the target's
        /// position: the last entry whose first version is not after it.
        fn childFor(table: *const Table, index: *const Index, n: []const u32, target: *const Target, scratch: *VersionRowScratch) usize {
            var low: usize = 0;
            var high: usize = nodeCount(n);
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (compareEntry(table, index, entryMin(n, mid), entryKey(n, mid), target, scratch) <= 0) low = mid + 1 else high = mid;
            }
            return if (low == 0) 0 else low - 1;
        }

        /// First leaf position whose entry is not before the target.
        fn lowerPos(table: *const Table, index: *const Index, n: []const u32, target: *const Target, scratch: *VersionRowScratch) usize {
            var low: usize = 0;
            var high: usize = nodeCount(n);
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (compareEntry(table, index, entryRef(n, mid), entryKey(n, mid), target, scratch) < 0) low = mid + 1 else high = mid;
            }
            return low;
        }

        const Step = struct { node: u32, pos: u32 };
        const Path = [btree_depth]Step;

        /// Descends to the leaf for `target`, recording the internal steps.
        fn descend(table: *const Table, index: *const Index, run: []const u32, target: *const Target, path: *Path, depth: *usize, scratch: *VersionRowScratch) u32 {
            var node = nodeConst(run, 0)[meta_root];
            depth.* = 0;
            while (!nodeLeaf(nodeConst(run, node))) {
                const n = nodeConst(run, node);
                const pos = childFor(table, index, n, target, scratch);
                path[depth.*] = .{ .node = node, .pos = @intCast(pos) };
                depth.* += 1;
                node = entryRef(n, pos);
            }
            return node;
        }

        /// A node's first entry changed: its ancestors' entries for it (and
        /// theirs, while it stays a first child) follow.
        fn propagateMin(run: []u32, path: *const Path, depth: usize, key: u64, min: u32) void {
            var level = depth;
            while (level != 0) {
                level -= 1;
                const step = path[level];
                setMin(nodeAt(run, step.node), step.pos, key, min);
                if (step.pos != 0) return;
            }
        }

        /// Inserts (key, ref, min) at `pos` of `node`, whose ancestors are
        /// path[0..depth], splitting full nodes upward.
        fn insertEntry(run: []u32, path: *const Path, depth_in: usize, node_in: u32, pos_in: usize, key_in: u64, ref_in: u32, min_in: u32) void {
            var depth = depth_in;
            var node = node_in;
            var pos = pos_in;
            var key = key_in;
            var ref = ref_in;
            var min = min_in;
            while (true) {
                const n = nodeAt(run, node);
                const count = nodeCount(n);
                if (count < btree_fanout) {
                    shiftRight(n, pos, count);
                    setEntry(n, pos, key, ref, min);
                    setCount(n, count + 1);
                    if (pos == 0) propagateMin(run, path, depth, key, min);
                    return;
                }
                const leaf = nodeLeaf(n);
                const right = allocNode(run, leaf);
                const r = nodeAt(run, right);
                if (pos <= half_fanout) {
                    moveEntries(r, 0, n, half_fanout, half_fanout);
                    setCount(r, half_fanout);
                    shiftRight(n, pos, half_fanout);
                    setEntry(n, pos, key, ref, min);
                    setCount(n, half_fanout + 1);
                    if (pos == 0) propagateMin(run, path, depth, key, min);
                } else {
                    moveEntries(r, 0, n, half_fanout + 1, half_fanout - 1);
                    setCount(n, half_fanout + 1);
                    const at = pos - (half_fanout + 1);
                    shiftRight(r, at, half_fanout - 1);
                    setEntry(r, at, key, ref, min);
                    setCount(r, half_fanout);
                }
                if (leaf) {
                    r[1] = n[1];
                    r[2] = node;
                    if (n[1] != 0) nodeAt(run, n[1])[2] = right;
                    n[1] = right;
                }
                if (depth == 0) {
                    const root = allocNode(run, false);
                    const t = nodeAt(run, root);
                    setEntry(t, 0, entryKey(n, 0), node, entryMin(n, 0));
                    setEntry(t, 1, entryKey(r, 0), right, entryMin(r, 0));
                    setCount(t, 2);
                    const meta = nodeAt(run, 0);
                    meta[meta_root] = root;
                    meta[meta_height] += 1;
                    return;
                }
                depth -= 1;
                const parent = path[depth];
                key = entryKey(r, 0);
                min = entryMin(r, 0);
                ref = right;
                node = parent.node;
                pos = parent.pos + 1;
            }
        }

        fn treeInsert(table: *Table, which: usize, version: u32) void {
            const index = &table.indexes[which];
            const run = runOf(table, which);
            var target_scratch: VersionRowScratch = undefined;
            var scratch: VersionRowScratch = undefined;
            const target = versionTarget(table, index, version, &target_scratch);
            const meta = nodeAt(run, 0);
            meta[meta_entries] += 1;
            if (meta[meta_root] == 0) {
                const root = allocNode(run, true);
                const n = nodeAt(run, root);
                setEntry(n, 0, target.key, version, version);
                setCount(n, 1);
                meta[meta_root] = root;
                meta[meta_height] = 1;
                return;
            }
            var path: Path = undefined;
            var depth: usize = 0;
            const leaf = descend(table, index, run, &target, &path, &depth, &scratch);
            const pos = lowerPos(table, index, nodeConst(run, leaf), &target, &scratch);
            insertEntry(run, &path, depth, leaf, pos, target.key, version, version);
        }

        /// Restores half occupancy from `node` (at path depth `depth`) up:
        /// borrow from a sibling with more than half, else merge with it;
        /// a root with one child gives way to that child.
        fn rebalance(run: []u32, path: *const Path, depth_in: usize, node_in: u32) void {
            var depth = depth_in;
            var node = node_in;
            while (depth != 0 and nodeCount(nodeConst(run, node)) < half_fanout) {
                const parent = path[depth - 1];
                const p = nodeAt(run, parent.node);
                const n = nodeAt(run, node);
                const pcount = nodeCount(p);
                const count = nodeCount(n);
                if (parent.pos > 0) {
                    const l = nodeAt(run, entryRef(p, parent.pos - 1));
                    const lcount = nodeCount(l);
                    if (lcount > half_fanout) {
                        shiftRight(n, 0, count);
                        copyEntry(n, 0, l, lcount - 1);
                        setCount(n, count + 1);
                        setCount(l, lcount - 1);
                        setMin(p, parent.pos, entryKey(n, 0), entryMin(n, 0));
                        return;
                    }
                }
                if (parent.pos + 1 < pcount) {
                    const r = nodeAt(run, entryRef(p, parent.pos + 1));
                    const rcount = nodeCount(r);
                    if (rcount > half_fanout) {
                        copyEntry(n, count, r, 0);
                        setCount(n, count + 1);
                        shiftLeft(r, 0, rcount);
                        setCount(r, rcount - 1);
                        setMin(p, parent.pos + 1, entryKey(r, 0), entryMin(r, 0));
                        return;
                    }
                }
                // Merge: the left node of the pair absorbs the right one.
                const left_pos: usize = if (parent.pos > 0) parent.pos - 1 else 0;
                const keep = entryRef(p, left_pos);
                const gone = entryRef(p, left_pos + 1);
                const k = nodeAt(run, keep);
                const g = nodeAt(run, gone);
                const kcount = nodeCount(k);
                moveEntries(k, kcount, g, 0, nodeCount(g));
                setCount(k, kcount + nodeCount(g));
                if (nodeLeaf(k)) {
                    k[1] = g[1];
                    if (g[1] != 0) nodeAt(run, g[1])[2] = keep;
                }
                freeNode(run, gone);
                shiftLeft(p, left_pos + 1, pcount);
                setCount(p, pcount - 1);
                depth -= 1;
                node = parent.node;
            }
            const meta = nodeAt(run, 0);
            while (meta[meta_root] != 0) {
                const root = meta[meta_root];
                const r = nodeConst(run, root);
                if (nodeLeaf(r) or nodeCount(r) != 1) break;
                meta[meta_root] = entryRef(r, 0);
                meta[meta_height] -= 1;
                freeNode(run, root);
            }
        }

        fn treeDelete(table: *Table, which: usize, version: u32) void {
            const index = &table.indexes[which];
            const run = runOf(table, which);
            const meta = nodeAt(run, 0);
            if (meta[meta_root] == 0) return;
            var target_scratch: VersionRowScratch = undefined;
            var scratch: VersionRowScratch = undefined;
            const target = versionTarget(table, index, version, &target_scratch);
            var path: Path = undefined;
            var depth: usize = 0;
            const leaf = descend(table, index, run, &target, &path, &depth, &scratch);
            const n = nodeAt(run, leaf);
            const count = nodeCount(n);
            const pos = lowerPos(table, index, n, &target, &scratch);
            if (pos == count or entryRef(n, pos) != version) return;
            meta[meta_entries] -= 1;
            shiftLeft(n, pos, count);
            setCount(n, count - 1);
            if (depth == 0) {
                if (count == 1) {
                    freeNode(run, leaf);
                    meta[meta_root] = 0;
                    meta[meta_height] = 0;
                }
                return;
            }
            if (pos == 0) propagateMin(run, &path, depth, entryKey(n, 0), entryMin(n, 0));
            rebalance(run, &path, depth, leaf);
        }

        /// Value-domain bounds over an ordered index: key elements
        /// 0..eq equal cells[0..eq] (a NULL cell matches NULL keys, as IS
        /// NULL does); with `ranged`, element `eq` is non-NULL and lies
        /// within the bounds that are set.
        pub const Span = struct {
            cells: [config.columns]V.Cell = undefined,
            eq: usize = 0,
            ranged: bool = false,
            has_low: bool = false,
            low_inclusive: bool = true,
            low: V.Cell = .null_value,
            has_high: bool = false,
            high_inclusive: bool = true,
            high: V.Cell = .null_value,
        };

        /// An ordered index walk between two targets, in either direction.
        pub const Scan = struct {
            start: Target,
            stop: Target,
            node: u32 = 0,
            pos: u32 = 0,
            backward: bool = false,
        };

        fn spanTargets(index: *const Index, span: *const Span, start: *Target, stop: *Target) void {
            start.* = .{ .cells = &span.cells, .count = span.eq, .sentinel = -1 };
            stop.* = .{ .cells = &span.cells, .count = span.eq, .sentinel = 1 };
            if (span.ranged and span.eq < index.key_count) {
                const option = index.options[span.eq];
                const descending = option & 1 != 0;
                const nulls_first = option & 2 != 0;
                // The bound met first in index order, then the last one.
                const first_set = if (descending) span.has_high else span.has_low;
                const first: *const V.Cell = if (descending) &span.high else &span.low;
                const first_inclusive = if (descending) span.high_inclusive else span.low_inclusive;
                const last_set = if (descending) span.has_low else span.has_high;
                const last: *const V.Cell = if (descending) &span.low else &span.high;
                const last_inclusive = if (descending) span.low_inclusive else span.high_inclusive;
                if (first_set) {
                    start.* = .{ .cells = &span.cells, .tail = first, .count = span.eq + 1, .sentinel = if (first_inclusive) -1 else 1 };
                } else if (nulls_first) {
                    start.* = .{ .cells = &span.cells, .tail = &null_cell, .count = span.eq + 1, .sentinel = 1 };
                }
                if (last_set) {
                    stop.* = .{ .cells = &span.cells, .tail = last, .count = span.eq + 1, .sentinel = if (last_inclusive) 1 else -1 };
                } else if (!nulls_first) {
                    stop.* = .{ .cells = &span.cells, .tail = &null_cell, .count = span.eq + 1, .sentinel = -1 };
                }
            }
            start.key = probeKey(index, start);
            stop.key = probeKey(index, stop);
        }

        /// Positions a walk over the entries of `span` (ordered index
        /// `which` with a tree); scanNext returns their versions in index
        /// order (reversed when `backward`), visible or not.
        pub fn indexScan(table: *const Table, which: usize, span: *const Span, backward: bool) Scan {
            var scratch: VersionRowScratch = undefined;
            const index = &table.indexes[which];
            const run = runConst(table, which);
            var scan: Scan = .{ .start = undefined, .stop = undefined, .backward = backward };
            spanTargets(index, span, &scan.start, &scan.stop);
            if (nodeConst(run, 0)[meta_root] == 0) return scan;
            var path: Path = undefined;
            var depth: usize = 0;
            const target = if (backward) &scan.stop else &scan.start;
            const leaf = descend(table, index, run, target, &path, &depth, &scratch);
            const pos = lowerPos(table, index, nodeConst(run, leaf), target, &scratch);
            scan.node = leaf;
            // Backward walks keep the position after the next entry.
            scan.pos = @intCast(pos);
            return scan;
        }

        pub fn scanNext(table: *const Table, which: usize, scan: *Scan) ?u32 {
            var scratch: VersionRowScratch = undefined;
            const index = &table.indexes[which];
            const run = runConst(table, which);
            while (scan.node != 0) {
                const n = nodeConst(run, scan.node);
                if (scan.backward) {
                    if (scan.pos == 0) {
                        scan.node = n[2];
                        if (scan.node != 0) scan.pos = @intCast(nodeCount(nodeConst(run, scan.node)));
                        continue;
                    }
                    const at = scan.pos - 1;
                    const version = entryRef(n, at);
                    if (compareEntry(table, index, version, entryKey(n, at), &scan.start, &scratch) <= 0) {
                        scan.node = 0;
                        return null;
                    }
                    scan.pos = at;
                    return version;
                }
                if (scan.pos >= nodeCount(n)) {
                    scan.node = n[1];
                    scan.pos = 0;
                    continue;
                }
                const version = entryRef(n, scan.pos);
                if (compareEntry(table, index, version, entryKey(n, scan.pos), &scan.stop, &scratch) >= 0) {
                    scan.node = 0;
                    return null;
                }
                scan.pos += 1;
                return version;
            }
            return null;
        }

        /// Structural check of tree `which` (contracts): entry order,
        /// separators equal to their child's first entry, half occupancy
        /// below the root, uniform height, leaf links, counts, and one entry
        /// per allocated version.
        pub fn indexTreeValid(table: *const Table, which: usize) bool {
            if (!hasIndexTree(table, which)) return true;
            var scratch: VersionRowScratch = undefined;
            var target_scratch: VersionRowScratch = undefined;
            const index = &table.indexes[which];
            const run = runConst(table, which);
            const meta = nodeConst(run, 0);
            if (meta[meta_root] == 0) return table.version_used == 0 and meta[meta_entries] == 0;
            var first = meta[meta_root];
            var height: usize = 1;
            while (!nodeLeaf(nodeConst(run, first))) : (height += 1) {
                if (height > btree_depth) return false;
                first = entryRef(nodeConst(run, first), 0);
            }
            if (height != meta[meta_height]) return false;
            if (!subtreeValid(run, meta[meta_root], meta[meta_root], height)) return false;
            var previous: u32 = 0;
            var last: ?u32 = null;
            var count: usize = 0;
            var node = first;
            while (node != 0) {
                const n = nodeConst(run, node);
                if (!nodeLeaf(n) or n[2] != previous) return false;
                for (0..nodeCount(n)) |i| {
                    const version = entryRef(n, i);
                    if (version >= table.version_high or table.versions[version].rowLink() == 0) return false;
                    if (entryMin(n, i) != version) return false;
                    const own = versionTarget(table, index, version, &target_scratch);
                    if (own.key != entryKey(n, i)) return false;
                    if (last) |before| {
                        if (compareEntry(table, index, before, rowKey(index, borrowVersionRow(table, before, &scratch)), &own, &scratch) >= 0) return false;
                    }
                    last = version;
                    count += 1;
                }
                if (count > table.version_high) return false;
                previous = node;
                node = n[1];
            }
            return count == table.version_used and count == meta[meta_entries];
        }

        fn subtreeValid(run: []const u32, node: u32, root: u32, height: usize) bool {
            const n = nodeConst(run, node);
            const count = nodeCount(n);
            if (count == 0 or count > btree_fanout) return false;
            if (node != root and count < half_fanout) return false;
            if (nodeLeaf(n)) return height == 1;
            if (height <= 1) return false;
            for (0..count) |i| {
                const c = nodeConst(run, entryRef(n, i));
                if (nodeCount(c) == 0) return false;
                if (entryMin(c, 0) != entryMin(n, i) or entryKey(c, 0) != entryKey(n, i)) return false;
                if (!subtreeValid(run, entryRef(n, i), root, height - 1)) return false;
            }
            return true;
        }

        /// One candidate of a unique check (PostgreSQL's dirty snapshot):
        /// a committed live row or a version this transaction still holds
        /// takes the key; another live transaction's version means waiting.
        pub fn classify(version: *const Version, index: usize, snap: Snapshot, waiting: *?u16) ?KeyState {
            const marked = version.hasDeletion();
            if (version.pendingCreation()) |creation| {
                if (snap.own(creation.tx)) {
                    if (marked and version.deletionOwnedBy(snap)) return null;
                    return .{ .taken = @intCast(index) };
                }
                if (!marked and waiting.* == null) waiting.* = creation.tx.slot;
                return null;
            }
            if (!marked) return .{ .taken = @intCast(index) };
            const deletion = version.pendingDeletion() orelse return null;
            if (snap.own(deletion.tx)) return null;
            if (waiting.* == null) waiting.* = deletion.tx.slot;
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
            destination.seqscan_hint.slot = 0;
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
                if (from.rowLink() != 0) relayoutVersion(destination, source, version, sources, fills);
            }
            rebuildIndexes(destination);
            rebuildHints(destination);
        }

        /// Replay of ALTER TABLE in place (replay keeps no old snapshots):
        /// relayout every version, install the definition, rebuild indexes.
        pub fn redefine(table: *Table, name: V.Name, columns: []const V.Column, constraints: []const Constraint, extras: *const Extras, sources: []const u8, fills: []const V.Cell) void {
            for (table.versions[0..table.version_high], 0..) |*entry, version| {
                if (entry.rowLink() != 0) relayoutVersion(table, table, version, sources, fills);
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
                if (version.rowLink() == 0 or version.rowSlot() == own_slot) continue;
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
            table.pending_late_primary = false;
            table.constraint_count = 0;
            setExtras(table, &.{});
            table.truncate_csn = 0;
            table.pending_truncate = .{};
            table.next_rowid = 1;
            table.dead_csn = 0;
            table.pending_drop = false;
            table.row_high = 0;
            table.seqscan_hint.slot = 0;
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
            destination.seqscan_hint.slot = 0;
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
                    if (entry.rowLink() == 0) continue;
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
                    if (destination.versions[version].rowLink() != 0) indexKeyOnly(destination, @intCast(version));
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
                const slot = entry.rowSlot();
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
            if (version.pendingCreation()) |creation| return snap.own(creation.tx) and creation.cid < snap.cid;
            return version.creationCsn() <= snap.csn;
        }

        pub fn deleted(version: *const Version, snap: Snapshot) bool {
            if (!version.hasDeletion()) return false;
            if (version.pendingDeletion()) |deletion| return snap.own(deletion.tx) and deletion.cid < snap.cid;
            return version.deletionCsn() <= snap.csn;
        }

        pub fn publishTruncate(table: *Table, csn: u64) void {
            table.truncate_csn = csn;
            table.pending_truncate = .{};
            table.seqscan_hint.slot = 0;
            if (table.summary.valid) table.summary.csn = csn;
        }

        /// The version of `slot` visible to `snap`, if any.
        pub fn visibleAt(table: *const Table, slot: usize, snap: Snapshot) ?u32 {
            var ref = table.rows[slot].newest;
            while (ref != 0) {
                const version = &table.versions[ref - 1];
                if (created(version, snap)) {
                    if (deleted(version, snap)) return null;
                    if (table.truncate_csn > snap.csn and version.creationCsn() != 0) return null;
                    const truncated = &table.pending_truncate;
                    if (snap.own(truncated.owner) and truncated.cid < snap.cid) {
                        const creation = version.pendingCreation() orelse return null;
                        if (creation.cid < truncated.cid) return null;
                    }
                    return ref - 1;
                }
                ref = version.olderLink();
            }
            return null;
        }

        /// Committed view: the newest stamped version, unless it is dead.
        pub fn visible(table: *const Table, slot: usize) ?u32 {
            return visibleAt(table, slot, committed_view);
        }

        /// The version created right after `version` in its row's chain.
        pub fn successor(table: *const Table, version: u32) ?u32 {
            var ref = table.rows[table.versions[version].rowSlot()].newest;
            while (ref != 0) {
                const entry = &table.versions[ref - 1];
                if (entry.olderLink() == version + 1) return ref - 1;
                ref = entry.olderLink();
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
                .varchar, .bpchar => text: {
                    var value: V.Text = .{ .len = bytes[at] };
                    @memcpy(value.bytes[0..value.len], bytes[at + 1 ..][0..value.len]);
                    break :text if (table.columns[column].data_type == .varchar) .{ .text = value } else .{ .bpchar = value };
                },
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
                    .varchar, .bpchar => {
                        const value = if (cell.* == .text) cell.text.slice() else cell.bpchar.slice();
                        bytes[at] = @intCast(value.len);
                        @memcpy(bytes[at + 1 ..][0..value.len], value);
                    },
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

        /// An exclusive DDL or replay caller may borrow an empty scalar
        /// index bank to validate an entire primary key without query scratch.
        pub fn validatePrimaryColumns(table: *Table, columns: []const u8, definitions: []const V.Column, snap: Snapshot, control: ?*types.ExecutionControl) types.Error!void {
            const bank = table.key_index[0..];
            if (columns.len == 0 or bank.len == 0 or bank.len & (bank.len - 1) != 0) return error.IndexCapacity;
            for (bank) |entry| if (entry != 0) return error.IndexCapacity;
            defer @memset(bank, 0);
            var entries: usize = 0;
            for (0..table.row_high) |row| {
                const version = visibleAt(table, row, snap) orelse continue;
                if (control) |execution| try execution.checkpoint();
                if (entries >= bank.len / 2) return error.IndexCapacity;
                var hash: u64 = 0x51ed2701a5b3c4d9;
                for (columns) |column| {
                    var scratch: V.Cell = undefined;
                    const cell = borrowVersionCell(table, version, column, &scratch);
                    if (cell.* == .null_value) return error.NotNullViolation;
                    try V.validate(&definitions[column], cell);
                    hash = mix(hash ^ V.hash(cell));
                }
                var position: usize = @intCast(hash & (bank.len - 1));
                while (bank[position] != 0) : (position = (position + 1) & (bank.len - 1)) {
                    if (control) |execution| try execution.checkpoint();
                    for (columns) |column| {
                        var scratch: V.Cell = undefined;
                        const candidate = borrowVersionCell(table, version, column, &scratch);
                        if (!versionCellEquals(table, bank[position] - 1, column, candidate)) break;
                    } else return error.PrimaryKeyViolation;
                }
                bank[position] = version + 1;
                entries += 1;
            }
        }

        fn keyPosition(table: *const Table, version: u32) ?usize {
            const column = table.primary_column orelse return null;
            var scratch: V.Cell = undefined;
            const key = borrowVersionCell(table, version, column, &scratch);
            // A historical version can predate a new primary key. The new
            // index only contains non-null keys, and validation rejects any
            // null visible under the DDL's validation snapshot.
            if (key.* == .null_value) return null;
            return V.hash(key) & (table.key_index.len - 1);
        }

        fn keyHome(table: *const Table, entry: u32) usize {
            // Deletion visits only entries inserted by indexKeyOnly.
            return keyPosition(table, entry - 1).?;
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
                if (entry.rowLink() != 1 or entry.olderLink() != 0) { hint.state = .disabled; return; }
                hint.* = .{ .state = .candidate, .base = key.integer };
            }
            // Dense key-to-slot mappings are stronger eligibility evidence
            // than monotonic order: sparse ordered keys disable speculation.
            if (@as(i128, key.integer) != @as(i128, hint.base) + entry.rowSlot())
                hint.state = .disabled;
        }

        fn noteOrder(table: *Table, version: u32) void {
            const entry = &table.versions[version];
            for (table.column_order[0..table.column_count], 0..) |*proof, column| {
                var scratch: V.Cell = undefined;
                const value = borrowVersionCell(table, version, column, &scratch);
                if (entry.olderLink() != 0) {
                    if (entry.olderLink() == version + 1 or table.versions[entry.olderLink() - 1].rowLink() == 0) {
                        proof.state = .unordered;
                    } else if (proof.state != .unordered) {
                        var previous: V.Cell = undefined;
                        const old = borrowVersionCell(table, entry.olderLink() - 1, column, &previous);
                        if (V.compare(value, old) != 0) proof.state = .unordered;
                    }
                    continue;
                }
                // The first row after reset/full reclamation can start a new
                // proof. Other inserts must be appended to the directory.
                if (entry.rowLink() == 1 and table.row_high == 1) {
                    proof.* = .{ .state = if (value.* == .null_value) .unordered else .one, .last = value.* };
                    continue;
                }
                if (proof.state == .unordered) continue;
                if (entry.rowLink() != table.row_high or value.* == .null_value) { proof.state = .unordered; continue; }
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
            var position = keyPosition(table, version) orelse return;
            while (table.key_index[position] != 0) position = (position + 1) & (table.key_index.len - 1);
            table.key_index[position] = version + 1;
        }

        fn unindexKey(table: *Table, version: u32) void {
            var position = keyPosition(table, version) orelse return;
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
                if (version.rowSlot() == own_slot) continue;
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
                    const slot = table.versions[entry - 1].rowSlot();
                    if (visibleAt(table, slot, snap) == entry - 1) return entry - 1;
                }
                position = (position + 1) & (table.key_index.len - 1);
            }
        }

        /// Directory slot of the row visible to `snap` whose key equals value.
        pub fn lookupKeyAt(table: *const Table, value: *const V.Cell, snap: Snapshot) ?u32 {
            const version = lookupVersionAt(table, value, snap) orelse return null;
            return table.versions[version].rowSlot();
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
                .row_link = origin.row + 1,
                .older_link = origin.older,
                .cells = if (comptime split_versions) {} else if (full_width) cells[0..config.columns].* else @splat(.null_value),
            };
            table.versions[version].initCreation(origin);
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
                table.version_free = table.versions[version].olderLink();
                return version;
            }
            table.version_high += 1;
            return @intCast(table.version_high - 1);
        }

        fn freeVersion(table: *Table, version: u32) void {
            table.versions[version].setRowLink(0);
            table.versions[version].setOlderLink(table.version_free);
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
            const slot = table.versions[version].rowSlot();
            const row = &table.rows[slot];
            if (row.newest == version + 1) {
                row.newest = table.versions[version].olderLink();
            } else {
                var previous = row.newest - 1;
                while (table.versions[previous].olderLink() != version + 1) previous = table.versions[previous].olderLink() - 1;
                table.versions[previous].setOlderLink(table.versions[version].olderLink());
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
                const deletion_csn = version.deletionCsn();
                if (version.rowLink() == 0 or deletion_csn == 0 or deletion_csn > horizon) continue;
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
                    while (ref != 0) : (ref = table.versions[ref - 1].olderLink()) table.versions[ref - 1].setRowLink(@intCast(write + 1));
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
                if (version.rowLink() == 0) continue;
                if (version.creationCsn() == 0 or version.pendingDeletion() != null) out.pending += 1;
            }
            return out;
        }
    };
}
