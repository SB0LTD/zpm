//! Row and table locks, wait-for sets and deadlock detection (Layer 0,
//! design §4.5).
//!
//! Row write locks are implicit: an in-progress xmax on a row version. FOR
//! UPDATE / NO KEY UPDATE / SHARE / KEY SHARE locks live in a fixed table of
//! Config.row_locks entries with up to Config.share_holders holders each
//! (LockCapacity, 53200, when full), with PostgreSQL's row-lock conflict
//! matrix (KEY SHARE conflicts only with UPDATE; SHARE with NO KEY UPDATE
//! and UPDATE; NO KEY UPDATE with SHARE, NO KEY UPDATE and UPDATE; UPDATE
//! with all). UPDATE/DELETE's implicit row lock conflicts with every
//! explicit lock (PostgreSQL's FOR UPDATE strength; a non-key UPDATE there
//! is NO KEY UPDATE and lets KEY SHARE proceed: not distinguished here).
//! Table locks are PostgreSQL's eight modes with its conflict matrix:
//! AccessShare (SELECT), RowShare (SELECT FOR ...), RowExclusive (DML),
//! AccessExclusive (DDL) and every LOCK TABLE mode, held until the
//! transaction ends. Every lock a transaction acquires is appended to its
//! lock list, so aborting a subtransaction releases exactly the locks
//! acquired after its watermark. A transaction holds a row at most once: a
//! stronger row lock after its own weaker one upgrades that holder in place
//! (the four strengths form a chain, so the strongest mode is exact) and
//! lists an upgrade entry, whose release restores the previous strength.
//!
//! Advisory locks (pg_advisory_*): a fixed table of Config.advisory_locks
//! keys with up to Config.share_holders holders each (SessionCapacity,
//! 54000, when full). A holder is a session (session-level locks, counted,
//! kept across transactions) or a transaction slot of a session
//! (transaction-level, released with the transaction or the
//! subtransaction that took them through the lock list). Holders of the
//! same session never conflict; exclusive conflicts with everything else.
//!
//! A waiter records the set of transactions it waits for (a bitset over the
//! transaction table). Deadlock detection is an iterative DFS over those sets
//! with a fixed stack and visited set sized by Config.transactions: bounded,
//! never recursive.
const types = @import("types.sig");
const Error = types.Error;

/// Table lock modes as mask bits (each mode is held at most once).
pub const TableMode = enum(u8) { access_share = 1, row_exclusive = 2, access_exclusive = 4, row_share = 8, share_update_exclusive = 16, share = 32, share_row_exclusive = 64, exclusive = 128 };

/// The modes a requested table mode conflicts with (PostgreSQL's matrix).
pub fn tableConflicts(requested: TableMode) u8 {
    const as: u8 = 1;
    const re: u8 = 2;
    const ae: u8 = 4;
    const rs: u8 = 8;
    const sue: u8 = 16;
    const sh: u8 = 32;
    const sre: u8 = 64;
    const ex: u8 = 128;
    return switch (requested) {
        .access_share => ae,
        .row_share => ex | ae,
        .row_exclusive => sh | sre | ex | ae,
        .share_update_exclusive => sue | sh | sre | ex | ae,
        .share => re | sue | sre | ex | ae,
        .share_row_exclusive => re | sue | sh | sre | ex | ae,
        .exclusive => rs | re | sue | sh | sre | ex | ae,
        .access_exclusive => as | rs | re | sue | sh | sre | ex | ae,
    };
}

/// `write` is UPDATE/DELETE's implicit row lock (checked, never stored).
pub const RowMode = enum(u8) { share = 1, update = 2, write = 3, key_share = 4, no_key_update = 5 };

/// Strength order of the stored row modes (a conflict-set chain).
pub fn rowRank(mode: RowMode) u8 {
    return switch (mode) {
        .key_share => 1,
        .share => 2,
        .no_key_update => 3,
        .update, .write => 4,
    };
}

/// Advisory lock key: pg_advisory_*(bigint) or (int4, int4) (`pair`).
pub const AdvisoryKey = struct { key: i64 = 0, pair: bool = false };

pub fn Locks(comptime config: types.Config) type {
    if (config.transactions == 0 or config.transactions > 0xfffe) @compileError("transactions must be 1..65534");
    if (config.share_holders == 0 or config.share_holders > 255) @compileError("share_holders must be 1..255");
    if (config.row_locks > 0xffff) @compileError("row_locks must fit u16");
    if (config.advisory_locks > 0xffff) @compileError("advisory_locks must fit u16");
    const words = (config.transactions + 63) / 64;
    return struct {
        const Self = @This();
        /// Per-transaction lock-list bound: each table mode once, per held
        /// row its grant plus its upgrades (at most three) and per advisory
        /// key one transaction-level entry per acquisition (checked).
        pub const list_capacity: usize = config.tables * 8 + config.row_locks * 4 + config.advisory_locks * 2;

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

        /// An advisory holder: `session` owns it; transaction-level holders
        /// also name their transaction slot. `count` acquisitions.
        pub const AdvisoryHolder = struct { session: u64 = 0, slot: u16 = 0, xact: bool = false, exclusive: bool = false, count: u32 = 0 };

        pub const Advisory = struct {
            used: bool = false,
            key: AdvisoryKey = .{},
            count: u8 = 0,
            holders: [config.share_holders]AdvisoryHolder = undefined,
        };

        pub const RowLock = struct {
            used: bool = false,
            table: u8 = 0,
            rowid: u64 = 0,
            count: u8 = 0,
            holders: [config.share_holders]Holder = undefined,
        };

        /// `upgrade` records an in-place upgrade of a row lock (`prior` is
        /// the strength before it); `advisory` one transaction-level
        /// advisory acquisition (`mode` 1 = exclusive).
        pub const EntryKind = enum(u8) { table, row, upgrade, advisory };

        /// One acquisition in a transaction's lock list.
        pub const Entry = struct { kind: EntryKind, table: u8, mode: u8, index: u16 = 0, prior: u8 = 0 };

        /// Table locks: one mode mask per (table, transaction slot).
        modes: [config.tables][config.transactions]u8 = @splat(@splat(0)),
        rows: [config.row_locks]RowLock = @splat(.{}),
        advisory: [config.advisory_locks]Advisory = @splat(.{}),

        fn tableConflict(requested: TableMode, held: u8) bool {
            return held & tableConflicts(requested) != 0;
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
                .key_share => held == .update or held == .write,
                .share => held == .update or held == .write or held == .no_key_update,
                .no_key_update => held != .key_share,
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
                if (holder.slot == slot and rowRank(holder.mode) >= rowRank(mode)) return true;
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
                const prior = holder.mode;
                holder.mode = mode;
                return .{ .kind = .upgrade, .table = @intCast(table), .mode = @intFromEnum(mode), .index = @intCast(index), .prior = @intFromEnum(prior) };
            };
            if (entry.count == config.share_holders) return error.LockCapacity;
            entry.holders[entry.count] = .{ .slot = @intCast(slot), .mode = mode };
            entry.count += 1;
            return .{ .kind = .row, .table = @intCast(table), .mode = @intFromEnum(mode), .index = @intCast(index) };
        }

        /// Undoes an in-place upgrade: the holder has its prior strength.
        pub fn downgradeRow(self: *Self, index: usize, slot: usize, prior: u8) void {
            const entry = &self.rows[index];
            for (entry.holders[0..entry.count]) |*holder| if (holder.slot == slot) {
                holder.mode = switch (prior) {
                    1, 2, 3, 4, 5 => @enumFromInt(prior),
                    else => .share,
                };
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
                .upgrade => self.downgradeRow(entry.index, slot, entry.prior),
                .advisory => self.releaseAdvisoryXact(entry.index, slot),
            }
        }

        // ---- advisory locks ----------------------------------------------

        fn findAdvisory(self: *const Self, key: AdvisoryKey) ?usize {
            for (&self.advisory, 0..) |*entry, index| {
                if (entry.used and entry.key.key == key.key and entry.key.pair == key.pair) return index;
            }
            return null;
        }

        /// Adds every transaction of another session whose holder conflicts
        /// with the request; `idle` is set when a conflicting holder is a
        /// session-level lock of a session outside any transaction.
        pub fn advisoryHolders(self: *const Self, key: AdvisoryKey, session: u64, exclusive: bool, session_slots: []const ?u16, sessions: []const u64, out: *Set, conflict: *bool) void {
            conflict.* = false;
            const index = self.findAdvisory(key) orelse return;
            const entry = &self.advisory[index];
            for (entry.holders[0..entry.count]) |holder| {
                if (holder.session == session) continue;
                if (!exclusive and !holder.exclusive) continue;
                conflict.* = true;
                if (holder.xact) {
                    out.add(holder.slot);
                    continue;
                }
                for (sessions, session_slots) |owner, maybe| if (owner == holder.session) if (maybe) |slot| out.add(slot);
            }
        }

        /// Records one acquisition (conflicts were checked by the caller).
        /// Returns the table index (for a transaction-level lock-list entry).
        pub fn grantAdvisory(self: *Self, key: AdvisoryKey, session: u64, slot: u16, xact: bool, exclusive: bool) Error!usize {
            const index = self.findAdvisory(key) orelse blk: {
                for (&self.advisory, 0..) |*entry, candidate| if (!entry.used) {
                    entry.* = .{ .used = true, .key = key };
                    break :blk candidate;
                };
                return error.SessionCapacity;
            };
            const entry = &self.advisory[index];
            for (entry.holders[0..entry.count]) |*holder| {
                if (holder.session == session and holder.xact == xact and holder.exclusive == exclusive and (!xact or holder.slot == slot)) {
                    holder.count +|= 1;
                    return index;
                }
            }
            if (entry.count == config.share_holders) {
                if (entry.count == 0) entry.used = false;
                return error.SessionCapacity;
            }
            entry.holders[entry.count] = .{ .session = session, .slot = slot, .xact = xact, .exclusive = exclusive, .count = 1 };
            entry.count += 1;
            return index;
        }

        fn dropHolder(entry: *Advisory, position: usize) void {
            for (position + 1..entry.count) |next| entry.holders[next - 1] = entry.holders[next];
            entry.count -= 1;
            if (entry.count == 0) entry.used = false;
        }

        /// One transaction-level acquisition of `slot` ends.
        pub fn releaseAdvisoryXact(self: *Self, index: usize, slot: usize) void {
            if (index >= config.advisory_locks) return;
            const entry = &self.advisory[index];
            var position: usize = 0;
            while (position < entry.count) : (position += 1) {
                const holder = &entry.holders[position];
                if (!holder.xact or holder.slot != slot) continue;
                holder.count -= 1;
                if (holder.count == 0) dropHolder(entry, position);
                return;
            }
        }

        /// pg_advisory_unlock[_shared]: one session-level acquisition; false
        /// when the session holds none in that mode.
        pub fn releaseAdvisorySession(self: *Self, key: AdvisoryKey, session: u64, exclusive: bool) bool {
            const index = self.findAdvisory(key) orelse return false;
            const entry = &self.advisory[index];
            for (entry.holders[0..entry.count], 0..) |*holder, position| {
                if (holder.xact or holder.session != session or holder.exclusive != exclusive) continue;
                holder.count -= 1;
                if (holder.count == 0) dropHolder(entry, position);
                return true;
            }
            return false;
        }

        /// pg_advisory_unlock_all / session end: every session-level lock.
        pub fn releaseAdvisoryAll(self: *Self, session: u64) void {
            for (&self.advisory) |*entry| {
                if (!entry.used) continue;
                var position: usize = 0;
                while (position < entry.count) {
                    const holder = entry.holders[position];
                    if (!holder.xact and holder.session == session) dropHolder(entry, position) else position += 1;
                }
            }
        }

        /// Advisory keys in use (holders or not).
        pub fn advisoryUsed(self: *const Self) usize {
            var count: usize = 0;
            for (&self.advisory) |*entry| if (entry.used) {
                count += 1;
            };
            return count;
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
