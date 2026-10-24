//! Transactions, subtransactions, write sets and commit/abort (Layer 0,
//! design §4.4).
//!
//! A fixed transaction table of Config.transactions slots. Each slot holds
//! its unique epoch, the next command id, one write set (Config.tx_writes
//! entries: versions it created and versions it marked deleted, in user and
//! catalog relations), a subtransaction stack of Config.savepoints user
//! savepoints plus one reserved slot for the running statement, its lock
//! list, the pinned snapshot of a parked statement and its wait-for set.
//! Every subtransaction records the write-set index and lock-list watermark
//! at which it began: aborting it undoes exactly that slice (newest first)
//! and releases exactly the locks acquired inside it; completing or
//! releasing it merges by dropping the entry. Nothing is copied.
//!
//! Commit (store-driven, §4.6): prepare (encode the change record from the
//! write set; fallible, no state change) -> caller persists -> publish
//! (infallible: stamps every write with the next csn, advances csn, releases
//! locks, bumps wake_epoch). Abort undoes the whole write set, releases every
//! lock and bumps wake_epoch.
const types = @import("types.sig");
const storage = @import("storage.sig");
const locks = @import("locks.sig");
const sequence = @import("sequence.sig");
const Error = types.Error;

pub fn Mvcc(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const L = locks.Locks(config);
    const Q = sequence.Sequences(config);
    return struct {
        pub const write_capacity: usize = if (config.tx_writes == 0) @max(config.rows_per_table * 2, 64) else config.tx_writes;
        pub const sub_capacity: usize = config.savepoints + 1;

        pub const WriteKind = enum(u8) { insert, update, delete, create_table, drop_table, catalog_insert, catalog_delete, create_sequence, drop_sequence };

        /// `table` is the table slot (catalog relation, sequence slot);
        /// `old`/`new` are version indices.
        pub const Write = struct { kind: WriteKind, table: u8, old: u32 = 0, new: u32 = 0 };

        pub const Sub = struct {
            name: V.Name = .{},
            write_start: u32 = 0,
            lock_start: u32 = 0,
            /// The reserved statement subtransaction (not a user savepoint).
            statement: bool = false,
        };

        pub const TableWait = struct { table: u8, mode: locks.TableMode, seq: u64 };

        pub const Tx = struct {
            active: bool = false,
            epoch: u32 = 0,
            /// Command id of the most recent statement.
            cid: u32 = 0,
            writes: [write_capacity]Write = undefined,
            write_len: usize = 0,
            subs: [sub_capacity]Sub = undefined,
            sub_len: usize = 0,
            lock_list: [L.list_capacity]L.Entry = undefined,
            lock_len: usize = 0,
            /// Snapshot of a parked statement (resumed with the same snapshot).
            pin: ?storage.Snapshot = null,
            /// The parked statement touched no data yet: resume re-snapshots.
            fresh: bool = false,
            waiting_for: L.Set = .{},
            /// Pending table-lock request of a parked statement (FIFO queue).
            table_wait: ?TableWait = null,
            /// Sequences whose log-ahead value this transaction recorded
            /// (non-transactional: carried into the next append on abort).
            seq_dirty: Q.Set = .{},
            /// Source rows of the running INSERT already handled (inserted,
            /// updated or skipped by ON CONFLICT) and its affected count; a
            /// resumed statement continues after them.
            progress: usize = 0,
            progress_affected: usize = 0,
            /// The open COPY FROM statement (its statement subtransaction
            /// stays on the stack between data messages): target table,
            /// statement snapshot and rows inserted so far.
            copy_table: ?u8 = null,
            copy_snap: storage.Snapshot = .{ .csn = 0 },
            copy_rows: usize = 0,

            pub fn ref(self: *const Tx, slot: usize) storage.TxRef {
                return .{ .slot = @intCast(slot), .epoch = self.epoch, .sub = @intCast(self.sub_len) };
            }

            pub fn push(self: *Tx, entry: Write) Error!void {
                if (self.write_len == write_capacity) return error.WriteSetCapacity;
                self.writes[self.write_len] = entry;
                self.write_len += 1;
            }

            pub fn pushLock(self: *Tx, entry: L.Entry) void {
                // Bounded: each table mode and each row lock appears once.
                self.lock_list[self.lock_len] = entry;
                self.lock_len += 1;
            }

            pub fn userSavepoints(self: *const Tx) usize {
                var count: usize = 0;
                for (self.subs[0..self.sub_len]) |*sub| if (!sub.statement) {
                    count += 1;
                };
                return count;
            }
        };

        fn clearMark(version: *S.Version) void {
            version.xmax = .{};
            version.xmax_cid = 0;
            version.xmax_csn = 0;
        }

        /// Undoes writes[start..] newest first and releases locks[lock_start..].
        pub fn abortSlice(db: anytype, slot: usize, start: usize, lock_start: usize) void {
            const tx = &db.txs[slot];
            var index = tx.write_len;
            while (index > start) {
                index -= 1;
                const entry = tx.writes[index];
                switch (entry.kind) {
                    .insert => {
                        const table = &db.tables[entry.table];
                        const rowid = table.rows[table.versions[entry.new].row - 1].rowid;
                        S.reclaimVersion(table, entry.new);
                        // Keep rowids dense when nothing allocated after this one.
                        if (table.next_rowid == rowid + 1) table.next_rowid = rowid;
                    },
                    .update => {
                        const table = &db.tables[entry.table];
                        S.reclaimVersion(table, entry.new);
                        clearMark(&table.versions[entry.old]);
                    },
                    .delete => clearMark(&db.tables[entry.table].versions[entry.old]),
                    .create_table => {
                        const table = &db.tables[entry.table];
                        table.pending_create = false;
                        table.live = false;
                        const width: u32 = 1 + @as(u32, @intFromBool(table.primary_column != null));
                        if (db.oid_counter + types_first_oid == table.oid + width) db.oid_counter -= width;
                    },
                    .drop_table => db.tables[entry.table].pending_drop = false,
                    .catalog_insert => db.catalog.undo(.{ .relation = @enumFromInt(entry.table), .version = entry.new }, true),
                    .catalog_delete => db.catalog.undo(.{ .relation = @enumFromInt(entry.table), .version = entry.old }, false),
                    .create_sequence => {
                        const seq = &db.seqs[entry.table];
                        seq.live = false;
                        seq.pending_create = false;
                        if (db.oid_counter + types_first_oid == seq.oid + 1) db.oid_counter -= 1;
                        tx.seq_dirty.remove(entry.table);
                    },
                    .drop_sequence => db.seqs[entry.table].pending_drop = false,
                }
            }
            tx.write_len = start;
            releaseLocks(db, slot, lock_start);
        }

        const types_first_oid: u32 = 16384;

        pub fn releaseLocks(db: anytype, slot: usize, lock_start: usize) void {
            const tx = &db.txs[slot];
            var index = tx.lock_len;
            while (index > lock_start) {
                index -= 1;
                db.locks.release(slot, tx.lock_list[index]);
            }
            if (tx.lock_len > lock_start) db.wake_epoch +%= 1;
            tx.lock_len = lock_start;
        }

        /// Stamps every write with `csn` (the caller advances db.csn).
        pub fn stamp(db: anytype, slot: usize, csn: u64) void {
            const tx = &db.txs[slot];
            for (tx.writes[0..tx.write_len]) |entry| {
                switch (entry.kind) {
                    .insert => db.tables[entry.table].versions[entry.new].xmin_csn = csn,
                    .update => {
                        const table = &db.tables[entry.table];
                        table.versions[entry.new].xmin_csn = csn;
                        table.versions[entry.old].xmax_csn = csn;
                    },
                    .delete => db.tables[entry.table].versions[entry.old].xmax_csn = csn,
                    .create_table => db.tables[entry.table].pending_create = false,
                    .drop_table => {
                        const table = &db.tables[entry.table];
                        table.pending_drop = false;
                        table.dead_csn = csn;
                    },
                    .catalog_insert => db.catalog.stamp(.{ .relation = @enumFromInt(entry.table), .version = entry.new }, csn, true),
                    .catalog_delete => db.catalog.stamp(.{ .relation = @enumFromInt(entry.table), .version = entry.old }, csn, false),
                    .create_sequence => db.seqs[entry.table].pending_create = false,
                    .drop_sequence => {
                        const seq = &db.seqs[entry.table];
                        seq.pending_drop = false;
                        seq.dead_csn = csn;
                    },
                }
            }
        }

        /// Reclaims up to reclaim_budget superseded versions of a published
        /// transaction that no pinned snapshot can still see.
        pub fn reclaim(db: anytype, slot: usize, horizon: u64) void {
            const tx = &db.txs[slot];
            var budget: usize = S.reclaim_budget;
            for (tx.writes[0..tx.write_len]) |entry| {
                if (budget == 0) break;
                if (entry.kind != .update and entry.kind != .delete) continue;
                const table = &db.tables[entry.table];
                if (!table.live or table.dead_csn != 0) continue;
                const version = &table.versions[entry.old];
                if (version.row == 0 or version.xmax_csn == 0 or version.xmax_csn > horizon) continue;
                S.reclaimVersion(table, entry.old);
                budget -= 1;
            }
        }

    };
}
