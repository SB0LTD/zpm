//! Session-scoped engine state (Layer 0, tx-session lane): engine
//! settings, SQL prepared statements, cursors and LISTEN/NOTIFY.
//!
//! A session's state (State) belongs to its connection: the caller owns it
//! and installs it as Database.session_state before every call (callers
//! without connections use Database.default_session_state). Nothing here
//! allocates; every capacity is a Config constant and exceeding one is
//! SessionCapacity (54000) with nothing changed.
//!
//! Settings (SET / SET LOCAL / SHOW / RESET, current_setting, set_config)
//! held here are search_path, default_transaction_isolation,
//! default_transaction_read_only, default_transaction_deferrable and
//! placeholder (`prefix.name`) settings; the transaction_* settings read and
//! write the running transaction's modes. They are transactional like
//! PostgreSQL's (guc.c): `values` is in effect, `base` is what a plain SET
//! wrote (kept at commit), `tx_start` is restored by ROLLBACK and each
//! savepoint saves both (restored by ROLLBACK TO, kept by RELEASE). SET
//! LOCAL changes `values` only, so it ends with the transaction.
//!
//! Prepared statements are not transactional (PostgreSQL's are not either):
//! PREPARE stores the statement text and declared parameter types, EXECUTE
//! re-parses and re-binds it with the arguments as parameter values.
//!
//! Cursors are materialized at DECLARE under the statement snapshot into a
//! row pool shared by every session (Config.cursors, Config.cursor_rows);
//! FETCH / MOVE then move over those rows in either direction. A cursor
//! without WITH HOLD ends with its transaction; WITH HOLD cursors survive
//! COMMIT; a cursor declared in a transaction (or subtransaction) that is
//! rolled back is dropped.
//!
//! LISTEN / UNLISTEN take effect at commit; NOTIFY entries are queued per
//! transaction (deduplicated) and appended to the shared notification ring
//! at commit, in commit order. A listener reads from its own position;
//! the ring's tail is the slowest listener, and NOTIFY fails with
//! SessionCapacity (54000, "too many notifications in the NOTIFY queue")
//! when the committed entries still unread plus every pending one would
//! not fit, so publication never fails.
const types = @import("types.sig");
const mvcc = @import("mvcc.sig");
const Error = types.Error;

pub fn Sessions(comptime config: types.Config) type {
    if (config.setting_bytes < 16 or config.setting_bytes > 0xffff) @compileError("setting_bytes must be 16..65535");
    if (config.listeners > 0xfffe or config.cursors > 0xfffe) @compileError("listeners and cursors must fit u16");
    const V = types.Values(config);
    const Level = mvcc.Mvcc(config).Level;
    const cursor_rows = if (config.cursor_rows == 0) types.resultRows(config) else config.cursor_rows;
    return struct {
        pub const Name = V.Name;
        pub const Row = V.Row;
        pub const cursor_row_capacity = cursor_rows;

        /// A bounded setting name or value.
        pub const SettingText = struct {
            bytes: [config.setting_bytes]u8 = @splat(0),
            len: u16 = 0,

            pub fn slice(self: *const SettingText) []const u8 {
                return self.bytes[0..self.len];
            }

            pub fn set(self: *SettingText, text: []const u8) Error!void {
                if (text.len > config.setting_bytes) return error.SessionCapacity;
                @memcpy(self.bytes[0..text.len], text);
                self.len = @intCast(text.len);
            }

            fn literal(comptime text: []const u8) SettingText {
                var out: SettingText = .{};
                for (text, 0..) |byte, index| out.bytes[index] = byte;
                out.len = text.len;
                return out;
            }
        };

        pub const Custom = struct { used: bool = false, name: SettingText = .{}, value: SettingText = .{} };

        /// The engine settings of a session.
        pub const Values = struct {
            isolation: Level = .read_committed,
            read_only: bool = false,
            deferrable: bool = false,
            search_path: SettingText = SettingText.literal("\"$user\", public"),
            custom: [config.custom_settings]Custom = @splat(.{}),
            /// SET ROLE (catalog-security lane): the role OID, 0 for NONE
            /// (current_user is then the session user).
            role: u32 = 0,

            pub fn findCustom(self: *const Values, name: []const u8) ?usize {
                for (&self.custom, 0..) |*entry, index| {
                    if (entry.used and sameInsensitive(entry.name.slice(), name)) return index;
                }
                return null;
            }
        };

        /// Settings at the start of savepoint level `level` (taken lazily,
        /// before the first change made at that level; guc.c's stack).
        const Saved = struct { level: usize = 0, values: Values = .{}, base: Values = .{} };

        pub const Prepared = struct {
            used: bool = false,
            name: Name = .{},
            text: [config.prepared_bytes]u8 = undefined,
            len: usize = 0,
            count: usize = 0,
            types: [config.statement_parameters]types.Type = undefined,
            typmods: [config.statement_parameters]i32 = undefined,

            pub fn source(self: *const Prepared) []const u8 {
                return self.text[0..self.len];
            }
        };

        pub const ListenKind = enum(u8) { listen, unlisten, unlisten_all };
        pub const ListenAction = struct { kind: ListenKind = .listen, channel: Name = .{}, depth: usize = 0 };

        pub const State = struct {
            /// Engine-assigned identity (0 until first use).
            id: u64 = 0,
            /// Backend process id reported with this session's notifications.
            pid: u32 = 0,
            values: Values = .{},
            base: Values = .{},
            tx_start: Values = .{},
            /// RESET / DEFAULT restore these.
            startup: Values = .{},
            /// session_user as a role OID (catalog-security lane): the
            /// bootstrap superuser (10) unless the caller installs another.
            session_role: u32 = 10,
            /// Savepoint level of the open transaction and the settings saved
            /// for levels that changed them (Config.setting_snapshots).
            level: usize = 0,
            saved: [config.setting_snapshots]Saved = undefined,
            saved_len: usize = 0,
            /// Epoch of the transaction the settings stack follows (0: none).
            tx_epoch: u32 = 0,
            prepared: [config.prepared_statements]Prepared = @splat(.{}),
            /// LISTEN / UNLISTEN of the open transaction, applied at commit.
            listen_actions: [config.listen_channels]ListenAction = undefined,
            listen_action_count: usize = 0,
            /// Index in Notify.listeners once a LISTEN committed.
            listener: ?u16 = null,

            pub fn findPrepared(self: *const State, name: []const u8) ?usize {
                for (&self.prepared, 0..) |*entry, index| {
                    if (entry.used and types.same(entry.name.slice(), name)) return index;
                }
                return null;
            }

            /// Transaction start: settings snapshot, empty savepoint stack.
            pub fn beginTransaction(self: *State, epoch: u32) void {
                self.tx_start = self.values;
                self.base = self.values;
                self.level = 0;
                self.saved_len = 0;
                self.tx_epoch = epoch;
                self.listen_action_count = 0;
            }

            pub fn endTransaction(self: *State, committed: bool) void {
                self.values = if (committed) self.base else self.tx_start;
                self.base = self.values;
                self.level = 0;
                self.saved_len = 0;
                self.tx_epoch = 0;
                self.listen_action_count = 0;
            }

            /// Before changing settings inside a savepoint: keep the level's
            /// starting values once (SessionCapacity when the stack is full).
            pub fn preserve(self: *State) Error!void {
                if (self.tx_epoch == 0 or self.level == 0) return;
                if (self.saved_len != 0 and self.saved[self.saved_len - 1].level == self.level) return;
                if (self.saved_len == config.setting_snapshots) return error.SessionCapacity;
                self.saved[self.saved_len] = .{ .level = self.level, .values = self.values, .base = self.base };
                self.saved_len += 1;
            }

            pub fn savepoint(self: *State) void {
                self.level += 1;
            }

            /// RELEASE of savepoint index `index` (and newer ones): their
            /// changes belong to the enclosing level now.
            pub fn release(self: *State, index: usize) void {
                if (index >= self.level) return;
                var first: ?usize = null;
                for (self.saved[0..self.saved_len], 0..) |entry, position| {
                    if (entry.level >= index + 1) {
                        first = position;
                        break;
                    }
                }
                if (first) |position| {
                    const parent_saved = position != 0 and self.saved[position - 1].level == index;
                    if (parent_saved or index == 0) {
                        self.saved_len = position;
                    } else {
                        self.saved[position].level = index;
                        self.saved_len = position + 1;
                    }
                }
                self.level = index;
            }

            /// ROLLBACK TO savepoint index `index`: settings as it began.
            pub fn rollbackTo(self: *State, index: usize) void {
                self.restoreFrom(index + 1);
                self.level = index + 1;
            }

            /// Restores the values saved for level `level` or deeper (the
            /// state when that level began) and forgets those levels.
            fn restoreFrom(self: *State, level: usize) void {
                for (self.saved[0..self.saved_len], 0..) |entry, position| {
                    if (entry.level < level) continue;
                    self.values = entry.values;
                    self.base = entry.base;
                    self.saved_len = position;
                    return;
                }
            }

            /// An error inside the block: back to the innermost savepoint
            /// (or the transaction start), as AtEOXact_GUC.
            pub fn failScope(self: *State) void {
                if (self.level > 0) {
                    self.restoreFrom(self.level);
                } else {
                    self.values = self.tx_start;
                    self.base = self.tx_start;
                }
            }

            /// Drops LISTEN/UNLISTEN actions taken at savepoint depth >= `min_depth`.
            pub fn discardListen(self: *State, min_depth: usize) void {
                var kept: usize = 0;
                for (self.listen_actions[0..self.listen_action_count]) |action| {
                    if (action.depth >= min_depth) continue;
                    self.listen_actions[kept] = action;
                    kept += 1;
                }
                self.listen_action_count = kept;
            }

            pub fn pushListen(self: *State, kind: ListenKind, channel: []const u8, depth: usize) Error!void {
                if (self.listen_action_count == config.listen_channels) return error.SessionCapacity;
                var action: ListenAction = .{ .kind = kind, .depth = depth };
                if (channel.len > config.name_bytes) return error.NameCapacity;
                @memcpy(action.channel.bytes[0..channel.len], channel);
                action.channel.len = channel.len;
                self.listen_actions[self.listen_action_count] = action;
                self.listen_action_count += 1;
            }
        };

        // ---- cursors ----------------------------------------------------

        pub const Cursor = struct {
            used: bool = false,
            session: u64 = 0,
            name: Name = .{},
            hold: bool = false,
            /// Backward movement allowed (not NO SCROLL).
            scroll: bool = true,
            /// The declaring transaction and its savepoint depth; a held
            /// cursor whose transaction committed has `committed` set.
            epoch: u32 = 0,
            slot: u16 = 0,
            depth: usize = 0,
            committed: bool = false,
            column_count: usize = 0,
            names: [config.columns]Name = @splat(.{}),
            column_types: [config.columns]types.DataType = @splat(.integer),
            typmods: [config.columns]i32 = @splat(-1),
            base: usize = 0,
            count: usize = 0,
            /// 0 before the first row, 1..count on a row, count+1 after the last.
            position: usize = 0,
        };

        pub const Cursors = struct {
            slots: [config.cursors]Cursor = @splat(.{}),
            rows: [cursor_rows]Row = undefined,
            used_rows: usize = 0,

            pub fn find(self: *const Cursors, session: u64, name: []const u8) ?usize {
                for (&self.slots, 0..) |*cursor, index| {
                    if (cursor.used and cursor.session == session and types.same(cursor.name.slice(), name)) return index;
                }
                return null;
            }

            pub fn free(self: *const Cursors) ?usize {
                for (&self.slots, 0..) |*cursor, index| if (!cursor.used) return index;
                return null;
            }

            /// Releases a cursor and compacts the shared row pool.
            pub fn close(self: *Cursors, index: usize) void {
                const cursor = &self.slots[index];
                if (!cursor.used) return;
                const base = cursor.base;
                const count = cursor.count;
                cursor.* = .{};
                if (count == 0) return;
                var at = base;
                while (at + count < self.used_rows) : (at += 1) self.rows[at] = self.rows[at + count];
                self.used_rows -= count;
                for (&self.slots) |*other| if (other.used and other.base > base) {
                    other.base -= count;
                };
            }

            pub fn closeSession(self: *Cursors, session: u64) void {
                for (0..config.cursors) |index| if (self.slots[index].used and self.slots[index].session == session) self.close(index);
            }

            /// Transaction end: non-held cursors close; on abort so does
            /// every cursor declared in it.
            pub fn endTransaction(self: *Cursors, slot: u16, epoch: u32, committed: bool) void {
                for (0..config.cursors) |index| {
                    const cursor = &self.slots[index];
                    if (!cursor.used or cursor.committed or cursor.slot != slot or cursor.epoch != epoch) continue;
                    if (committed and cursor.hold) cursor.committed = true else self.close(index);
                }
            }

            /// ROLLBACK TO / a failed scope: cursors this transaction
            /// declared at savepoint depth >= `min_depth` are dropped.
            pub fn rollbackTo(self: *Cursors, slot: u16, epoch: u32, min_depth: usize) void {
                for (0..config.cursors) |index| {
                    const cursor = &self.slots[index];
                    if (cursor.used and !cursor.committed and cursor.slot == slot and cursor.epoch == epoch and cursor.depth >= min_depth) self.close(index);
                }
            }

            pub fn openCount(self: *const Cursors) usize {
                var count: usize = 0;
                for (&self.slots) |*cursor| if (cursor.used) {
                    count += 1;
                };
                return count;
            }
        };

        /// One FETCH/MOVE step over `count` rows: the rows to return (in
        /// order, 1-based indices from `first` stepping by `step`) and the
        /// new position. PostgreSQL's PortalRunSelect / DoPortalRunFetch.
        pub const Move = struct { first: usize = 0, rows: usize = 0, backward: bool = false, position: usize = 0 };

        pub fn relativeMove(position: usize, total: usize, forward: bool, wanted: u64) Move {
            var out: Move = .{ .position = position, .backward = !forward };
            if (forward) {
                const available: u64 = if (position >= total) 0 else total - position;
                const take: u64 = @min(wanted, available);
                out.first = position + 1;
                out.rows = @intCast(take);
                out.position = if (take < wanted) total + 1 else position + @as(usize, @intCast(take));
            } else {
                const start = if (position > total) total + 1 else position;
                const available: u64 = if (start <= 1) 0 else start - 1;
                const take: u64 = @min(wanted, available);
                out.first = if (start == 0) 0 else start - 1;
                out.rows = @intCast(take);
                out.position = if (take < wanted) 0 else start - @as(usize, @intCast(take));
            }
            return out;
        }

        /// ABSOLUTE n (negative from the end; 0 is before the first row).
        pub fn absoluteMove(total: usize, target: i64) Move {
            if (target == 0) return .{ .position = 0 };
            if (target > 0) {
                const wanted: u64 = @intCast(target);
                if (wanted > total) return .{ .position = total + 1 };
                return .{ .first = @intCast(wanted), .rows = 1, .position = @intCast(wanted) };
            }
            const back: u64 = @abs(target);
            if (back > total) return .{ .position = 0 };
            const row: usize = total + 1 - @as(usize, @intCast(back));
            return .{ .first = row, .rows = 1, .position = row };
        }

        /// RELATIVE n; RELATIVE 0 returns the current row (if any).
        pub fn relativePosition(position: usize, total: usize, offset: i64) Move {
            if (offset == 0) {
                if (position >= 1 and position <= total) return .{ .first = position, .rows = 1, .position = position };
                return .{ .position = position };
            }
            const signed: i128 = @as(i128, position) + offset;
            if (signed <= 0) return .{ .position = 0 };
            if (signed > total) return .{ .position = total + 1 };
            const row: usize = @intCast(signed);
            return .{ .first = row, .rows = 1, .position = row };
        }

        // ---- LISTEN / NOTIFY ----------------------------------------------

        pub const Note = struct {
            channel: Name = .{},
            payload: [config.notify_payload_bytes]u8 = undefined,
            payload_len: usize = 0,
            pid: u32 = 0,

            pub fn payloadSlice(self: *const Note) []const u8 {
                return self.payload[0..self.payload_len];
            }
        };

        pub const PendingNote = struct {
            used: bool = false,
            slot: u16 = 0,
            epoch: u32 = 0,
            /// User savepoint depth and command id of the NOTIFY.
            depth: usize = 0,
            cid: u32 = 0,
            seq: u64 = 0,
            note: Note = .{},
        };

        pub const Listener = struct {
            used: bool = false,
            session: u64 = 0,
            position: u64 = 0,
            channels: [config.listen_channels]Name = undefined,
            count: usize = 0,

            pub fn listening(self: *const Listener, channel: []const u8) bool {
                for (self.channels[0..self.count]) |*name| if (types.same(name.slice(), channel)) return true;
                return false;
            }
        };

        pub const Notify = struct {
            queue: [config.notify_queue]Note = undefined,
            /// Position of the next committed entry.
            head: u64 = 0,
            pending: [config.notify_pending]PendingNote = @splat(.{}),
            pending_seq: u64 = 0,
            listeners: [config.listeners]Listener = @splat(.{}),

            pub fn tail(self: *const Notify) u64 {
                var out = self.head;
                for (&self.listeners) |*listener| if (listener.used) {
                    out = @min(out, listener.position);
                };
                return out;
            }

            pub fn pendingCount(self: *const Notify) usize {
                var count: usize = 0;
                for (&self.pending) |*entry| if (entry.used) {
                    count += 1;
                };
                return count;
            }

            /// Queues one NOTIFY of transaction `slot` (dropped when an
            /// identical one is already pending, as PostgreSQL folds them).
            pub fn enqueue(self: *Notify, slot: u16, epoch: u32, depth: usize, cid: u32, channel: []const u8, payload: []const u8, pid: u32) Error!void {
                if (channel.len == 0 or channel.len > config.name_bytes) return error.InvalidParameterValue;
                // PostgreSQL: the payload must be shorter than 8000 bytes.
                if (payload.len >= 8000) return error.InvalidParameterValue;
                if (payload.len > config.notify_payload_bytes) return error.SessionCapacity;
                for (&self.pending) |*entry| {
                    if (entry.used and entry.slot == slot and entry.epoch == epoch and types.same(entry.note.channel.slice(), channel) and types.same(entry.note.payloadSlice(), payload)) return;
                }
                const used = self.pendingCount();
                const unread = self.head - self.tail();
                if (unread + used + 1 > config.notify_queue) return error.SessionCapacity;
                for (&self.pending) |*entry| if (!entry.used) {
                    self.pending_seq += 1;
                    entry.* = .{ .used = true, .slot = slot, .epoch = epoch, .depth = depth, .cid = cid, .seq = self.pending_seq };
                    @memcpy(entry.note.channel.bytes[0..channel.len], channel);
                    entry.note.channel.len = channel.len;
                    @memcpy(entry.note.payload[0..payload.len], payload);
                    entry.note.payload_len = payload.len;
                    entry.note.pid = pid;
                    return;
                };
                return error.SessionCapacity;
            }

            /// Commit: appends the transaction's entries in NOTIFY order
            /// (space was reserved when each was queued).
            pub fn publish(self: *Notify, slot: u16, epoch: u32) void {
                while (true) {
                    var best: ?usize = null;
                    for (&self.pending, 0..) |*entry, index| {
                        if (!entry.used or entry.slot != slot or entry.epoch != epoch) continue;
                        if (best == null or entry.seq < self.pending[best.?].seq) best = index;
                    }
                    const index = best orelse return;
                    const entry = &self.pending[index];
                    if (self.head - self.tail() < config.notify_queue) {
                        self.queue[@intCast(self.head % config.notify_queue)] = entry.note;
                        self.head += 1;
                    }
                    entry.used = false;
                }
            }

            /// Abort (all), a rolled-back savepoint (depth > `depth`) or a
            /// failed statement (command id `cid`).
            pub fn discard(self: *Notify, slot: u16, epoch: u32, min_depth: usize, cid: ?u32) void {
                for (&self.pending) |*entry| {
                    if (!entry.used or entry.slot != slot or entry.epoch != epoch) continue;
                    if (cid) |statement| {
                        if (entry.cid == statement) entry.used = false;
                    } else if (entry.depth >= min_depth) entry.used = false;
                }
            }

            pub fn findListener(self: *const Notify, session: u64) ?usize {
                for (&self.listeners, 0..) |*listener, index| if (listener.used and listener.session == session) return index;
                return null;
            }

            /// Applies a session's committed LISTEN/UNLISTEN actions. A new
            /// listener starts at the head (entries committed later).
            pub fn applyListen(self: *Notify, state: *State) void {
                for (state.listen_actions[0..state.listen_action_count]) |*action| {
                    const existing = self.findListener(state.id);
                    switch (action.kind) {
                        .listen => {
                            const index = existing orelse blk: {
                                for (&self.listeners, 0..) |*listener, candidate| if (!listener.used) {
                                    listener.* = .{ .used = true, .session = state.id, .position = self.head };
                                    break :blk candidate;
                                };
                                continue; // capacity was checked when LISTEN ran
                            };
                            const listener = &self.listeners[index];
                            if (listener.listening(action.channel.slice())) continue;
                            if (listener.count == config.listen_channels) continue;
                            listener.channels[listener.count] = action.channel;
                            listener.count += 1;
                        },
                        .unlisten => if (existing) |index| {
                            const listener = &self.listeners[index];
                            var position: usize = 0;
                            while (position < listener.count) {
                                if (types.same(listener.channels[position].slice(), action.channel.slice())) {
                                    for (position + 1..listener.count) |next| listener.channels[next - 1] = listener.channels[next];
                                    listener.count -= 1;
                                } else position += 1;
                            }
                        },
                        .unlisten_all => if (existing) |index| {
                            self.listeners[index].count = 0;
                        },
                    }
                }
                state.listen_action_count = 0;
                if (self.findListener(state.id)) |index| {
                    if (self.listeners[index].count == 0) self.listeners[index] = .{};
                }
                state.listener = if (self.findListener(state.id)) |index| @intCast(index) else null;
            }

            /// Can a LISTEN of `channel` by `session` be honoured at commit?
            pub fn listenRoom(self: *const Notify, state: *const State, channel: []const u8) bool {
                var channels: usize = 0;
                if (self.findListener(state.id)) |index| {
                    const listener = &self.listeners[index];
                    if (listener.listening(channel)) return true;
                    channels = listener.count;
                } else {
                    var free_listener = false;
                    for (&self.listeners) |*listener| free_listener = free_listener or !listener.used;
                    if (!free_listener) return false;
                }
                for (state.listen_actions[0..state.listen_action_count]) |*action| if (action.kind == .listen) {
                    channels += 1;
                };
                return channels < config.listen_channels;
            }

            /// The next committed notification for a listening session.
            pub fn take(self: *Notify, session: u64, out: *Note) bool {
                const index = self.findListener(session) orelse return false;
                const listener = &self.listeners[index];
                if (self.head - listener.position > config.notify_queue) listener.position = self.head - config.notify_queue;
                while (listener.position < self.head) {
                    const entry = &self.queue[@intCast(listener.position % config.notify_queue)];
                    listener.position += 1;
                    if (listener.listening(entry.channel.slice())) {
                        out.* = entry.*;
                        return true;
                    }
                }
                return false;
            }

            pub fn removeListener(self: *Notify, session: u64) void {
                if (self.findListener(session)) |index| self.listeners[index] = .{};
            }
        };

        pub fn sameInsensitive(a: []const u8, b: []const u8) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (types.lower(x) != types.lower(y)) return false;
            return true;
        }
    };
}
