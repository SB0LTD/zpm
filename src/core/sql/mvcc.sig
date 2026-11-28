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
const catalog_objects = @import("catalog_objects.sig");
const Error = types.Error;

pub fn Mvcc(comptime config: types.Config) type {
    const V = types.Values(config);
    const S = storage.Storage(config);
    const L = locks.Locks(config);
    const Q = sequence.Sequences(config);
    return struct {
        pub const write_capacity: usize = if (config.tx_writes == 0) @max(config.rows_per_table * 2, 64) else config.tx_writes;
        pub const sub_capacity: usize = config.savepoints + 1;

        /// `truncate`: the table's latest committed rows and our earlier
        /// writes were marked deleted in place with xmax = (this transaction,
        /// `old` as command id). One entry covers the whole table. `new`
        /// saves the previous pending truncate command for savepoint rollback.
        /// `refresh_rows` uses the same WAL operation with ordinary visibility.
        /// `alter_table`: ALTER TABLE copied table slot `old` into slot `table`
        /// (same OID, new definition) at command id `new`; the old slot dies
        /// at commit, the new one is discarded at abort.
        /// `alter_sequence`: ALTER SEQUENCE copied sequence slot `old` into
        /// slot `table` (same OID, new options/state).
        /// `create_schema` / `drop_schema`: schema slot `table`.
        /// `create_object` / `drop_object` (B11 wave 3): routine, trigger or
        /// rule slot `table` of class `new` (routine_catalog.Class).
        /// `object_insert` / `object_delete`: catalog object entry `new` /
        /// `old` (catalog_objects.sig, B11 wave 3); an insert's `table` is 1
        /// when the version took a fresh OID.
        pub const WriteKind = enum(u8) { insert, update, delete, create_table, drop_table, catalog_insert, catalog_delete, create_sequence, drop_sequence, truncate, alter_table, alter_sequence, create_schema, drop_schema, create_object, drop_object, object_insert, object_delete, refresh_rows, large_object_page };

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

        /// A SET CONSTRAINTS name: the table OID and constraint name.
        pub const ConstraintMode = struct { oid: u32, name: V.Name, deferred: bool };

        /// Effective isolation levels (READ UNCOMMITTED is READ COMMITTED,
        /// as in PostgreSQL).
        pub const Level = enum(u8) { read_committed, repeatable_read, serializable, read_uncommitted };

        pub const Tx = struct {
            large_objects: @import("large_object_command.sig").Descriptors = .{},
            active: bool = false,
            prepared: bool = false,
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
            /// Statement body currently executing, including a resumed body.
            /// Reclamation must retain its snapshot until the call returns.
            running_snap: ?storage.Snapshot = null,
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
            mysql_insert_value: ?struct { value: i64, generated: bool } = null,
            mysql_first_generated: u64 = 0,
            mysql_explicit_insert_id: u64 = 0,
            /// The open COPY FROM statement (its statement subtransaction
            /// stays on the stack between data messages): target table,
            /// statement snapshot and rows inserted so far.
            copy_table: ?u8 = null,
            copy_snap: storage.Snapshot = .{ .csn = 0 },
            copy_rows: usize = 0,
            /// A deferred constraint skipped a check: COMMIT (or SET
            /// CONSTRAINTS ... IMMEDIATE) re-checks this transaction's rows.
            deferred_checks: bool = false,
            /// A non-deferrable FOREIGN KEY found its row missing (or a NO
            /// ACTION key still referenced) mid-statement: the statement's
            /// end re-checks its rows, as PostgreSQL's AFTER-trigger RI
            /// checks do (ddl-dml, wave 4).
            statement_checks: bool = false,
            /// SET CONSTRAINTS ALL mode (null: each constraint's INITIALLY).
            constraints_all: ?bool = null,
            /// Per trigger slot (B11 wave 5): the write-set index below which
            /// a constraint trigger's events were handled (fired, or before
            /// it existed); its deferred events are the matching writes from
            /// here on. A rolled-back slice lowers it (abortSlice).
            trigger_handled: [config.triggers]u32 = @splat(0),
            /// SET CONSTRAINTS name modes, newest last.
            constraint_modes: [config.constraint_modes]ConstraintMode = undefined,
            constraint_mode_count: usize = 0,
            /// Transaction modes (tx-session lane): isolation level (RC, RR
            /// or SERIALIZABLE), READ ONLY and DEFERRABLE.
            isolation: Level = .read_committed,
            read_only: bool = false,
            deferrable: bool = false,
            /// REPEATABLE READ / SERIALIZABLE: the transaction snapshot
            /// (commit sequence number), taken by the first statement that
            /// needs one (command id `snapshot_cid`).
            snapshot_csn: ?u64 = null,
            snapshot_cid: u32 = 0,
            /// The session (engine session-state id) that began it.
            session: u64 = 0,
            /// SERIALIZABLE conflict tracking record (ssi.sig), if any.
            ssi: ?u16 = null,

            pub fn ref(self: *const Tx, slot: usize) storage.TxRef {
                return .{ .slot = @intCast(slot), .epoch = self.epoch, .sub = @intCast(self.sub_len) };
            }

            pub fn push(self: *Tx, entry: Write) Error!void {
                if (self.write_len == write_capacity) return error.WriteSetCapacity;
                self.writes[self.write_len] = entry;
                self.write_len += 1;
            }

            /// Bounded by L.list_capacity (each table mode once, each held
            /// row's grant and upgrade once); checked all the same.
            pub fn pushLock(self: *Tx, entry: L.Entry) Error!void {
                if (self.lock_len == L.list_capacity) return error.LockCapacity;
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

        /// Undoes writes[start..] newest first and releases locks[lock_start..].
        pub fn abortSlice(db: anytype, slot: usize, start: usize, lock_start: usize) void {
            const tx = &db.txs[slot];
            for (&tx.trigger_handled) |*mark| mark.* = @min(mark.*, @as(u32, @intCast(start)));
            var index = tx.write_len;
            while (index > start) {
                index -= 1;
                const entry = tx.writes[index];
                switch (entry.kind) {
                    .insert => {
                        const table = &db.tables[entry.table];
                        const rowid = table.rows[table.versions[entry.new].rowSlot()].rowid;
                        S.reclaimVersion(table, entry.new);
                        // Keep rowids dense when nothing allocated after this one.
                        if (table.next_rowid == rowid + 1) table.next_rowid = rowid;
                    },
                    .update => {
                        const table = &db.tables[entry.table];
                        S.reclaimVersion(table, entry.new);
                        table.versions[entry.old].clearDeletion();
                    },
                    .delete => db.tables[entry.table].versions[entry.old].clearDeletion(),
                    .create_table => {
                        const table = &db.tables[entry.table];
                        table.pending_create = false;
                        table.live = false;
                        const width: u32 = S.oidWidth(table);
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
                    .truncate, .refresh_rows => {
                        const table = &db.tables[entry.table];
                        for (table.versions[0..table.version_high]) |*version| {
                            if (truncated(version, tx, slot, entry.old)) version.clearDeletion();
                        }
                        if (entry.kind == .truncate) {
                            table.pending_truncate = if (entry.new != 0) .{ .owner = tx.ref(slot), .cid = entry.new } else .{};
                        }
                    },
                    .alter_table => {
                        const copy = &db.tables[entry.table];
                        if (copy.pending_late_primary and copy.primary_index_oid != 0 and
                            db.oid_counter + types_first_oid == copy.primary_index_oid + 1) db.oid_counter -= 1;
                        // Index OIDs this ALTER took, when still the tail.
                        var position = copy.index_count;
                        while (position > 0) {
                            position -= 1;
                            const taken = copy.indexes[position].oid;
                            var kept = false;
                            const old = &db.tables[entry.old];
                            for (old.indexes[0..old.index_count]) |*existing| kept = kept or existing.oid == taken;
                            if (taken != 0 and !kept and db.oid_counter + types_first_oid == taken + 1) db.oid_counter -= 1;
                        }
                        copy.live = false;
                        copy.pending_create = false;
                        db.tables[entry.old].pending_drop = false;
                    },
                    .alter_sequence => {
                        const copy = &db.seqs[entry.table];
                        copy.live = false;
                        copy.pending_create = false;
                        tx.seq_dirty.remove(entry.table);
                        db.seqs[entry.old].pending_drop = false;
                    },
                    .create_schema => {
                        const schema = &db.schemas[entry.table];
                        schema.live = false;
                        schema.pending_create = false;
                        if (db.oid_counter + types_first_oid == schema.oid + 1) db.oid_counter -= 1;
                    },
                    .drop_schema => db.schemas[entry.table].pending_drop = false,
                    .create_object, .drop_object => db.undoObject(entry.kind == .create_object, entry.new, entry.table),
                    .object_insert => {
                        const object = &db.catalog_objects.items[entry.new];
                        // `table` 1: this version took a fresh OID.
                        if (entry.table == 1 and catalog_objects.ownsOid(object.kind) and db.oid_counter + types_first_oid == object.oid + 1) db.oid_counter -= 1;
                        db.catalog_objects.undoInsert(entry.new);
                    },
                    .object_delete => db.catalog_objects.undoDelete(entry.old),
                    .large_object_page => {
                        const pages = &db.large_pages.?;
                        pages.rollback(&.{pages.changeFromVersions(entry.old, entry.new)});
                    },
                }
            }
            tx.write_len = start;
            releaseLocks(db, slot, lock_start);
        }

        const types_first_oid: u32 = 16384;

        /// A version this transaction's TRUNCATE (command `cid`) marked and
        /// has not published.
        pub fn truncated(version: *const S.Version, tx: *const Tx, slot: usize, cid: u32) bool {
            if (version.rowLink() == 0) return false;
            const deletion = version.pendingDeletion() orelse return false;
            return deletion.tx.epoch == tx.epoch and deletion.tx.slot == slot and deletion.cid == cid;
        }

        /// Lists a lock just granted to `slot`. When the list is full the
        /// grant is released again, so the failing statement leaves the
        /// lock table as it found it.
        pub fn recordLock(db: anytype, slot: usize, entry: L.Entry) Error!void {
            db.txs[slot].pushLock(entry) catch |err| {
                db.locks.release(slot, entry);
                return err;
            };
        }

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
                    .insert => {
                        const table = &db.tables[entry.table];
                        S.summarize(table, entry.new, true, csn);
                        S.scanPublish(table, entry.new, true);
                        table.versions[entry.new].publishCreation(csn);
                    },
                    .update => {
                        const table = &db.tables[entry.table];
                        S.summarizeUpdate(table, entry.old, entry.new, csn);
                        S.scanPublish(table, entry.new, true);
                        table.versions[entry.new].publishCreation(csn);
                        table.versions[entry.old].publishDeletion(csn);
                    },
                    .delete => {
                        const table = &db.tables[entry.table];
                        S.summarize(table, entry.old, false, csn);
                        S.scanPublish(table, entry.old, false);
                        table.versions[entry.old].publishDeletion(csn);
                    },
                    .create_table => {
                        db.tables[entry.table].pending_create = false;
                        S.initSummary(&db.tables[entry.table], csn);
                    },
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
                    .truncate, .refresh_rows => {
                        const table = &db.tables[entry.table];
                        for (table.versions[0..table.version_high], 0..) |*version, index| {
                            if (!truncated(version, tx, slot, entry.old)) continue;
                            S.summarize(table, @intCast(index), false, csn);
                            S.scanPublish(table, @intCast(index), false);
                            version.publishDeletion(csn);
                        }
                        if (entry.kind == .truncate) S.publishTruncate(table, csn);
                    },
                    .alter_table => {
                        const old = &db.tables[entry.old];
                        old.pending_drop = false;
                        old.dead_csn = csn;
                        // The copy's own versions from statements before the
                        // ALTER have no write entries in this slot: publish
                        // them here. Later statements' entries follow.
                        const copy = &db.tables[entry.table];
                        copy.pending_create = false;
                        for (copy.versions[0..copy.version_high]) |*version| {
                            if (version.rowLink() == 0) continue;
                            if (version.pendingCreation()) |creation| {
                                if (creation.tx.epoch == tx.epoch and creation.tx.slot == slot and creation.cid < entry.new) version.publishCreation(csn);
                            }
                            if (version.pendingDeletion()) |deletion| {
                                if (deletion.tx.epoch == tx.epoch and deletion.tx.slot == slot and deletion.cid < entry.new) version.publishDeletion(csn);
                            }
                        }
                        const inherited = copy.pending_truncate;
                        if (inherited.owner.epoch == tx.epoch and inherited.owner.slot == slot and inherited.cid < entry.new)
                            S.publishTruncate(copy, csn);
                        S.rebuildCommitted(copy, csn);
                    },
                    .alter_sequence => {
                        const old = &db.seqs[entry.old];
                        old.pending_drop = false;
                        old.dead_csn = csn;
                        db.seqs[entry.table].pending_create = false;
                    },
                    .create_schema => db.schemas[entry.table].pending_create = false,
                    .drop_schema => {
                        const schema = &db.schemas[entry.table];
                        schema.pending_drop = false;
                        schema.dead_csn = csn;
                    },
                    .create_object, .drop_object => db.stampObject(entry.kind == .create_object, entry.new, entry.table, csn),
                    .object_insert => db.catalog_objects.stampInsert(entry.new, csn),
                    .object_delete => db.catalog_objects.stampDelete(entry.old, csn),
                    .large_object_page => {
                        const pages = &db.large_pages.?;
                        pages.publish(&.{pages.changeFromVersions(entry.old, entry.new)}, csn);
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
                // A published TRUNCATE frees its table's dead versions at once.
                if (entry.kind == .truncate or entry.kind == .refresh_rows) {
                    const table = &db.tables[entry.table];
                    if (table.live and table.dead_csn == 0) _ = S.vacuum(table, horizon);
                    continue;
                }
                if (budget == 0) break;
                if (entry.kind == .large_object_page) {
                    db.large_pages.?.reclaimPrevious(entry.old, horizon);
                    budget -= 1;
                    continue;
                }
                if (entry.kind != .update and entry.kind != .delete) continue;
                const table = &db.tables[entry.table];
                if (!table.live or table.dead_csn != 0) continue;
                const version = &table.versions[entry.old];
                const deletion_csn = version.deletionCsn();
                if (version.rowLink() == 0 or deletion_csn == 0 or deletion_csn > horizon) continue;
                S.reclaimVersion(table, entry.old);
                budget -= 1;
            }
        }

    };
}
