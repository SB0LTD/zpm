//! SERIALIZABLE: serializable snapshot isolation at relation granularity
//! (Layer 0, tx-session lane).
//!
//! Every SERIALIZABLE transaction (except a READ ONLY DEFERRABLE one, which
//! runs on a safe snapshot) has a record here from its first snapshot:
//! the tables it read (SIREAD) and wrote, and its rw-antidependency edges
//! to the other records (Cahill/Fekete; PostgreSQL's predicate.c). An edge
//! R -> W exists when R read a table that a concurrent W wrote (the write
//! is invisible to R's snapshot). A transaction with both an incoming and
//! an outgoing edge is a pivot of a dangerous structure: when an edge makes
//! either endpoint a pivot, the transaction creating the edge fails with
//! 40001 and is doomed (its COMMIT fails with 40001 too, even after ROLLBACK
//! TO SAVEPOINT). Every serialization anomaly among SERIALIZABLE
//! transactions contains such a pivot, so no non-serializable history of
//! them commits.
//!
//! Granularity is the whole relation (PostgreSQL tracks tuples, pages and
//! relations and promotes to relation locks only under memory pressure),
//! and the rule is the conservative pivot test without PostgreSQL's
//! "T3 committed first" and read-only refinements. Both only add
//! serialization failures (false positives); none is ever missed.
//! Committed records stay while an active SERIALIZABLE transaction overlaps
//! them; dropping one folds its edges into its neighbours' summary flags.
//! A full record table is SessionCapacity (54000).
const types = @import("types.sig");
const Error = types.Error;

pub fn Ssi(comptime config: types.Config) type {
    const capacity: usize = if (config.serializable_transactions == 0) config.transactions * 2 else config.serializable_transactions;
    if (capacity > 0xfffe) @compileError("serializable_transactions must fit u16");
    const table_words = (config.tables + 63) / 64;
    const record_words = (capacity + 63) / 64;
    return struct {
        const Self = @This();
        pub const record_capacity = capacity;

        pub fn Bits(comptime words: usize) type {
            return struct {
                bits: [words]u64 = @splat(0),

                pub fn add(self: *@This(), index: usize) void {
                    self.bits[index / 64] |= @as(u64, 1) << @intCast(index % 64);
                }
                pub fn remove(self: *@This(), index: usize) void {
                    self.bits[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
                }
                pub fn has(self: *const @This(), index: usize) bool {
                    return self.bits[index / 64] & (@as(u64, 1) << @intCast(index % 64)) != 0;
                }
                pub fn any(self: *const @This()) bool {
                    for (self.bits) |word| if (word != 0) return true;
                    return false;
                }
            };
        }
        pub const Tables = Bits(table_words);
        pub const Records = Bits(record_words);

        pub const Record = struct {
            used: bool = false,
            active: bool = false,
            slot: u16 = 0,
            epoch: u32 = 0,
            snapshot: u64 = 0,
            /// Commit sequence number once committed.
            commit: u64 = 0,
            doomed: bool = false,
            reads: Tables = .{},
            writes: Tables = .{},
            /// rw-antidependencies: readers of this record's writes (in) and
            /// writers of what it read (out); `*_summary` keeps edges to
            /// records already dropped.
            in_edges: Records = .{},
            out_edges: Records = .{},
            in_summary: bool = false,
            out_summary: bool = false,

            fn pivot(self: *const Record) bool {
                return (self.in_edges.any() or self.in_summary) and (self.out_edges.any() or self.out_summary);
            }
        };

        records: [capacity]Record = @splat(.{}),

        /// R's reads miss W's writes: W is uncommitted, or committed after
        /// R's snapshot; and R overlaps W (R active or committed after W's
        /// snapshot).
        fn concurrent(reader: *const Record, writer: *const Record) bool {
            const writer_unseen = writer.active or writer.commit > reader.snapshot;
            const reader_overlaps = reader.active or reader.commit > writer.snapshot;
            return writer_unseen and reader_overlaps;
        }

        /// Drops committed records no active record overlaps.
        pub fn prune(self: *Self) void {
            for (&self.records, 0..) |*record, index| {
                if (!record.used or record.active) continue;
                var needed = false;
                for (&self.records) |*other| {
                    if (other.used and other.active and other.snapshot < record.commit) needed = true;
                }
                if (!needed) self.drop(index, true);
            }
        }

        fn unlink(self: *Self, index: usize, committed: bool) void {
            for (&self.records) |*other| {
                if (!other.used) continue;
                if (other.in_edges.has(index)) {
                    other.in_edges.remove(index);
                    if (committed) other.in_summary = true;
                }
                if (other.out_edges.has(index)) {
                    other.out_edges.remove(index);
                    if (committed) other.out_summary = true;
                }
            }
        }

        fn drop(self: *Self, index: usize, committed: bool) void {
            self.unlink(index, committed);
            self.records[index] = .{};
        }

        pub fn register(self: *Self, slot: u16, epoch: u32, snapshot: u64) Error!u16 {
            self.prune();
            for (&self.records, 0..) |*record, index| if (!record.used) {
                record.* = .{ .used = true, .active = true, .slot = slot, .epoch = epoch, .snapshot = snapshot };
                return @intCast(index);
            };
            return error.SessionCapacity;
        }

        fn edge(self: *Self, current: usize, reader: usize, writer: usize) Error!void {
            if (reader == writer) return;
            self.records[reader].out_edges.add(writer);
            self.records[writer].in_edges.add(reader);
            if (self.records[reader].pivot() or self.records[writer].pivot()) {
                // This transaction can no longer commit, even after a
                // savepoint rollback. Its edges cannot constrain survivors.
                self.records[current].doomed = true;
                self.unlink(current, false);
                return error.SerializationFailure;
            }
        }

        /// SIREAD on `table`, then edges to concurrent writers of it.
        pub fn read(self: *Self, index: u16, table: usize) Error!void {
            const record = &self.records[index];
            if (record.doomed) return error.SerializationFailure;
            record.reads.add(table);
            for (&self.records, 0..) |*other, other_index| {
                if (!other.used or other.doomed or other_index == index or !other.writes.has(table)) continue;
                if (concurrent(record, other)) try self.edge(index, index, other_index);
            }
        }

        /// A write of `table`, then edges from concurrent readers of it.
        pub fn write(self: *Self, index: u16, table: usize) Error!void {
            const record = &self.records[index];
            if (record.doomed) return error.SerializationFailure;
            record.writes.add(table);
            for (&self.records, 0..) |*other, other_index| {
                if (!other.used or other.doomed or other_index == index or !other.reads.has(table)) continue;
                if (concurrent(other, record)) try self.edge(index, other_index, index);
            }
        }

        /// Commit-time check (fallible, changes nothing).
        pub fn check(self: *const Self, index: u16) Error!void {
            const record = &self.records[index];
            if (record.doomed or record.pivot()) return error.SerializationFailure;
        }

        pub fn commit(self: *Self, index: u16, csn: u64) void {
            const record = &self.records[index];
            record.active = false;
            record.commit = csn;
            self.prune();
        }

        pub fn abort(self: *Self, index: u16) void {
            self.drop(index, false);
            self.prune();
        }

        pub fn used(self: *const Self) usize {
            var count: usize = 0;
            for (&self.records) |*record| if (record.used) {
                count += 1;
            };
            return count;
        }
    };
}
