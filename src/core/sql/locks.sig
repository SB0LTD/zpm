//! Row and table locks, wait-for sets and deadlock detection (Layer 0,
//! design §4.5).
//!
//! Row write locks are implicit: an in-progress xmax on a row version. FOR
//! UPDATE / FOR SHARE locks live in a fixed table of Config.row_locks entries
//! with up to Config.share_holders holders each (LockCapacity, 53200, when
//! full). Table locks are AccessShare (SELECT), RowExclusive (DML) and
//! AccessExclusive (DROP TABLE), held until the transaction ends, with
//! PostgreSQL's conflict matrix for those three modes. Every lock a
//! transaction acquires is appended to its lock list, so aborting a
//! subtransaction releases exactly the locks acquired after its watermark.
//! A transaction holds a row at most once: FOR UPDATE after its own FOR
//! SHARE upgrades that holder in place and lists an upgrade entry, whose
//! release downgrades it to share again.
//!
//! A waiter records the set of transactions it waits for (a bitset over the
//! transaction table). Deadlock detection is an iterative DFS over those sets
//! with a fixed stack and visited set sized by Config.transactions: bounded,
//! never recursive.
const types = @import("types.sig");
const Error = types.Error;

pub const TableMode = enum(u8) { access_share = 1, row_exclusive = 2, access_exclusive = 4 };

/// `write` is UPDATE/DELETE's implicit row lock (checked, never stored).
pub const RowMode = enum(u8) { share = 1, update = 2, write = 3 };

pub fn Locks(comptime config: types.Config) type {
    if (config.transactions == 0 or config.transactions > 0xfffe) @compileError("transactions must be 1..65534");
    if (config.share_holders == 0 or config.share_holders > 255) @compileError("share_holders must be 1..255");
    if (config.row_locks > 0xffff) @compileError("row_locks must fit u16");
    const words = (config.transactions + 63) / 64;
    return struct {
        const Self = @This();
        /// Per-transaction lock-list bound: each table mode once, and per
        /// held row its grant plus at most one share -> update upgrade.
        pub const list_capacity: usize = config.tables * 3 + config.row_locks * 2;

        /// Bitset over transaction slots.
        pub const Set = struct {
            bits: [words]u64 = @splat(0),

            pub fn add(self: *Set, slot: usize) void {
                self.bits[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
            }

            pub fn remove(self: *Set, slot: usize) void {
                self.bits[slot / 64] &= ~(@as(u64, 1) << @intCast(slot % 64));
            }

            pub fn has(self: *const Set, slot: usize) bool {
                return self.bits[slot / 64] & (@as(u64, 1) << @intCast(slot % 64)) != 0;
            }

            pub fn any(self: *const Set) bool {
                for (self.bits) |word| if (word != 0) return true;
                return false;
            }

            pub fn first(self: *const Set) ?u16 {
                for (0..config.transactions) |slot| if (self.has(slot)) return @intCast(slot);
                return null;
            }
        };

        pub const Holder = struct { slot: u16 = 0, mode: RowMode = .share };

        pub const RowLock = struct {
            used: bool = false,
            table: u8 = 0,
            rowid: u64 = 0,
            count: u8 = 0,
            holders: [config.share_holders]Holder = undefined,
        };

        /// `upgrade` records an in-place share -> update upgrade of a row.
        pub const EntryKind = enum(u8) { table, row, upgrade };

        /// One acquisition in a transaction's lock list.
        pub const Entry = struct { kind: EntryKind, table: u8, mode: u8, index: u16 = 0 };

        /// Table locks: one mode mask per (table, transaction slot).
        modes: [config.tables][config.transactions]u8 = @splat(@splat(0)),
        rows: [config.row_locks]RowLock = @splat(.{}),

        fn tableConflict(requested: TableMode, held: u8) bool {
            return switch (requested) {
                .access_exclusive => held != 0,
                .access_share, .row_exclusive => held & @intFromEnum(TableMode.access_exclusive) != 0,
            };
        }

        pub fn holdsTable(self: *const Self, table: usize, slot: usize) bool {
            return self.modes[table][slot] != 0;
        }

        pub fn holdsTableMode(self: *const Self, table: usize, slot: usize, mode: TableMode) bool {
            return self.modes[table][slot] & @intFromEnum(mode) != 0;
        }

        /// Adds every other holder whose table lock conflicts with `mode`.
        pub fn tableHolders(self: *const Self, table: usize, slot: usize, mode: TableMode, out: *Set) void {
            for (0..config.transactions) |other| {
                if (other == slot) continue;
                if (tableConflict(mode, self.modes[table][other])) out.add(other);
            }
        }

        /// Records the mode; returns false when it was already held.
        pub fn grantTable(self: *Self, table: usize, slot: usize, mode: TableMode) bool {
            if (self.holdsTableMode(table, slot, mode)) return false;
            self.modes[table][slot] |= @intFromEnum(mode);
            return true;
        }

        pub fn releaseTable(self: *Self, table: usize, slot: usize, mode: u8) void {
            self.modes[table][slot] &= ~mode;
        }

        pub fn findRow(self: *const Self, table: usize, rowid: u64) ?usize {
            for (&self.rows, 0..) |*entry, index| {
                if (entry.used and entry.table == table and entry.rowid == rowid) return index;
            }
            return null;
        }

        fn rowConflict(requested: RowMode, held: RowMode) bool {
            return switch (requested) {
                .share => held == .update,
                .update, .write => true,
            };
        }

        /// Adds the first (oldest) other transaction whose FOR UPDATE/SHARE
        /// lock on the row conflicts with `mode`. Like PostgreSQL's
        /// MultiXactIdWait, a waiter waits for share holders one at a time,
        /// in acquisition order; each new holder starts a new wait.
        pub fn rowHolders(self: *const Self, table: usize, rowid: u64, slot: usize, mode: RowMode, out: *Set) void {
            const index = self.findRow(table, rowid) orelse return;
            const entry = &self.rows[index];
            for (entry.holders[0..entry.count]) |holder| {
                if (holder.slot != slot and rowConflict(mode, holder.mode)) {
                    out.add(holder.slot);
                    return;
                }
            }
        }

        pub fn holdsRow(self: *const Self, table: usize, rowid: u64, slot: usize, mode: RowMode) bool {
            const index = self.findRow(table, rowid) orelse return false;
            const entry = &self.rows[index];
            for (entry.holders[0..entry.count]) |holder| {
                if (holder.slot == slot and (holder.mode == mode or holder.mode == .update)) return true;
            }
            return false;
        }

        /// Adds a holder, or upgrades this transaction's share holder to
        /// update in place (conflicts were checked by the caller). Returns
        /// the lock-list entry to record, or null when this transaction
        /// already held the mode.
        pub fn grantRow(self: *Self, table: usize, rowid: u64, slot: usize, mode: RowMode) Error!?Entry {
            if (self.holdsRow(table, rowid, slot, mode)) return null;
            const index = self.findRow(table, rowid) orelse blk: {
                for (&self.rows, 0..) |*entry, candidate| if (!entry.used) {
                    entry.* = .{ .used = true, .table = @intCast(table), .rowid = rowid };
                    break :blk candidate;
                };
                return error.LockCapacity;
            };
            const entry = &self.rows[index];
            for (entry.holders[0..entry.count]) |*holder| if (holder.slot == slot) {
                holder.mode = mode;
                return .{ .kind = .upgrade, .table = @intCast(table), .mode = @intFromEnum(mode), .index = @intCast(index) };
            };
            if (entry.count == config.share_holders) return error.LockCapacity;
            entry.holders[entry.count] = .{ .slot = @intCast(slot), .mode = mode };
            entry.count += 1;
            return .{ .kind = .row, .table = @intCast(table), .mode = @intFromEnum(mode), .index = @intCast(index) };
        }

        /// Undoes an in-place upgrade: the holder is share again.
        pub fn downgradeRow(self: *Self, index: usize, slot: usize) void {
            const entry = &self.rows[index];
            for (entry.holders[0..entry.count]) |*holder| if (holder.slot == slot) {
                holder.mode = .share;
                return;
            };
        }

        pub fn releaseRow(self: *Self, index: usize, slot: usize, mode: RowMode) void {
            const entry = &self.rows[index];
            var position: usize = 0;
            while (position < entry.count) : (position += 1) {
                const holder = entry.holders[position];
                if (holder.slot == slot and holder.mode == mode) {
                    // Keep acquisition order for the waiters' sequence.
                    for (position + 1..entry.count) |next| entry.holders[next - 1] = entry.holders[next];
                    entry.count -= 1;
                    break;
                }
            }
            if (entry.count == 0) entry.used = false;
        }

        /// Releases one lock-list entry.
        pub fn release(self: *Self, slot: usize, entry: Entry) void {
            switch (entry.kind) {
                .table => self.releaseTable(entry.table, slot, entry.mode),
                .row => self.releaseRow(entry.index, slot, @enumFromInt(entry.mode)),
                .upgrade => self.downgradeRow(entry.index, slot),
            }
        }

        pub fn rowLocksUsed(self: *const Self) usize {
            var count: usize = 0;
            for (&self.rows) |*entry| if (entry.used) {
                count += 1;
            };
            return count;
        }

        pub fn tableLocksHeld(self: *const Self) usize {
            var count: usize = 0;
            for (&self.modes) |*table| for (table) |mask| {
                if (mask != 0) count += 1;
            };
            return count;
        }

        /// True when `start` reaches itself through the wait-for sets
        /// (`waits[slot]` lists the transactions slot waits for).
        pub fn cycle(waits: *const [config.transactions]Set, start: usize) bool {
            var visited: Set = .{};
            var stack: [config.transactions]u16 = undefined;
            var used: usize = 1;
            stack[0] = @intCast(start);
            visited.add(start);
            while (used != 0) {
                used -= 1;
                const node = stack[used];
                for (0..config.transactions) |next| {
                    if (!waits[node].has(next)) continue;
                    if (next == start) return true;
                    if (visited.has(next)) continue;
                    visited.add(next);
                    stack[used] = @intCast(next);
                    used += 1;
                }
            }
            return false;
        }
    };
}
