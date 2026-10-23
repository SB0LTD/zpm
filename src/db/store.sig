//! Caller-owned, allocator-free SQL store over the READ COMMITTED engine.
//!
//! Callers serialize method calls (the network reactor already does this);
//! concurrency comes from interleaved transactions in one shared Raw
//! (sql.Database). Every statement takes a new snapshot; there are no
//! per-connection database copies. A statement that meets a lock held by a
//! live transaction returns error.WouldBlock and is parked: the connection
//! keeps it pending and the caller re-delivers the SAME statement bytes when
//! `wakeReady()` reports progress (wake epoch, timer or cancel); the engine
//! resumes it with the same snapshot (design §4.4-§4.5). lock_timeout (55P03),
//! statement_timeout (57014), the one-time deadlock check (40P01, after
//! deadlock_timeout) and cancel requests (57014) end a parked statement.
//!
//! Commit path (design §4.6), identical for autocommit and COMMIT: a
//! read-only transaction (empty write set) publishes without persistence;
//! otherwise payload = prepareCommit(encode_buffer) -> commit_fn(payload)
//! (flush) -> publishCommit (infallible). Nothing becomes visible to another
//! snapshot before publishCommit (flush-before-publication). A persistence
//! error aborts the transaction and marks storage failed (58030 for later
//! writes) until the owner recovers. A terminal statement error inside a
//! transaction block aborts the work since the innermost savepoint and marks
//! the block failed (25P02 until ROLLBACK / ROLLBACK TO); in autocommit it
//! aborts the implicit transaction.
//!
//! Session settings (SET/SHOW/RESET, SET LOCAL, startup `-c` options) are
//! transactional like PostgreSQL's: reverted by ROLLBACK and ROLLBACK TO,
//! SET LOCAL ends with the transaction. Hooks must not reenter this store.

pub const max_statement_bytes = 65536;

/// Per-session SQL dialect (design §4.2). MySQL and TDS sessions set it on
/// their first message; PostgreSQL keeps the default. It only changes
/// assignment coercion (integer 0/1 into BOOLEAN) and what an unqualified
/// INTEGER means; expression typing is identical in every dialect.
pub const Dialect = enum { postgres, mysql, tds };

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn upper(byte: u8) u8 {
    return if (byte >= 'a' and byte <= 'z') byte - 32 else byte;
}

fn lowerByte(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn sameInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lowerByte(x) != lowerByte(y)) return false;
    return true;
}

fn whitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

/// 64-bit FNV-1a over the statement bytes (parameters are interpolated by
/// the codecs before the store sees them).
pub fn fingerprint(source: []const u8) u64 {
    var code: u64 = 14695981039346656037;
    for (source) |byte| code = (code ^ byte) *% 1099511628211;
    return code;
}

/// A legacy durable commit batch is [u32 little-endian length][SQL bytes],
/// repeated (WAL kinds 1/2). Length framing preserves semicolons, newlines and
/// comments inside literals. Replay applies a complete batch in one
/// transaction and publishes only when every statement succeeds.
pub const BatchIterator = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *BatchIterator) !?[]const u8 {
        if (self.position == self.bytes.len) return null;
        if (self.position > self.bytes.len or self.bytes.len - self.position < 4) return error.InvalidCommitBatch;
        const header = self.bytes[self.position..][0..4];
        const length: usize = @as(usize, header[0]) | (@as(usize, header[1]) << 8) |
            (@as(usize, header[2]) << 16) | (@as(usize, header[3]) << 24);
        if (length == 0 or length > max_statement_bytes or length > self.bytes.len - self.position - 4) return error.InvalidCommitBatch;
        self.position += 4;
        const source = self.bytes[self.position..][0..length];
        self.position += length;
        return source;
    }
};

/// Session settings this store implements. Times are milliseconds.
pub const Settings = struct {
    lock_timeout_ms: u32 = 0,
    statement_timeout_ms: u32 = 0,
    application_name: [64]u8 = @splat(0),
    application_name_len: u8 = 0,

    pub fn applicationName(self: *const Settings) []const u8 {
        return self.application_name[0..self.application_name_len];
    }
};

/// One-time deadlock check delay (PostgreSQL's default deadlock_timeout).
pub const deadlock_timeout_ms: u32 = 1000;

const Parameter = enum { lock_timeout, statement_timeout, deadlock_timeout, transaction_isolation, default_transaction_isolation, timezone, application_name, client_encoding, standard_conforming_strings, datestyle, intervalstyle, server_version, server_encoding, integer_datetimes, search_path };

fn parameter(name: []const u8) ?Parameter {
    inline for (@typeInfo(Parameter).@"enum".field_names) |field| {
        if (sameInsensitive(name, field)) return @field(Parameter, field);
    }
    return null;
}

/// PostgreSQL's canonical spelling, used as the SHOW column name.
fn canonical(which: Parameter) []const u8 {
    return switch (which) {
        .timezone => "TimeZone",
        .datestyle => "DateStyle",
        .intervalstyle => "IntervalStyle",
        else => @tagName(which),
    };
}

fn parseMilliseconds(text: []const u8) !u32 {
    var index: usize = 0;
    while (index < text.len and whitespace(text[index])) index += 1;
    var value: u64 = 0;
    const start = index;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {
        value = value * 10 + (text[index] - '0');
        if (value > 0x7fffffff) return error.InvalidSettingValue;
    }
    if (index == start) return error.InvalidSettingValue;
    while (index < text.len and whitespace(text[index])) index += 1;
    const unit = text[index..];
    const scale: u64 = if (unit.len == 0 or sameInsensitive(unit, "ms")) 1 else if (sameInsensitive(unit, "s")) 1000 else if (sameInsensitive(unit, "min")) 60000 else if (sameInsensitive(unit, "h")) 3600000 else if (sameInsensitive(unit, "d")) 86400000 else return error.InvalidSettingValue;
    const total = value * scale;
    if (total > 0x7fffffff) return error.InvalidSettingValue;
    return @intCast(total);
}

/// PostgreSQL's display: the largest unit that divides the value evenly.
fn formatMilliseconds(value: u32, out: []u8) []const u8 {
    if (value == 0) {
        out[0] = '0';
        return out[0..1];
    }
    const units = [_]struct { scale: u32, name: []const u8 }{
        .{ .scale = 86400000, .name = "d" },  .{ .scale = 3600000, .name = "h" }, .{ .scale = 60000, .name = "min" },
        .{ .scale = 1000, .name = "s" },      .{ .scale = 1, .name = "ms" },
    };
    for (units) |unit| {
        if (value % unit.scale != 0) continue;
        var digits: [16]u8 = undefined;
        var count: usize = 0;
        var number = value / unit.scale;
        while (true) {
            digits[count] = @intCast('0' + number % 10);
            count += 1;
            number /= 10;
            if (number == 0) break;
        }
        for (0..count) |position| out[position] = digits[count - 1 - position];
        @memcpy(out[count..][0..unit.name.len], unit.name);
        return out[0 .. count + unit.name.len];
    }
    unreachable;
}

pub fn Store(comptime Raw: type) type {
    return struct {
        const Self = @This();
        pub const CommitFn = *const fn (?*anyopaque, []const u8) anyerror!void;

        database: Raw = .{},
        commit_ctx: ?*anyopaque = null,
        commit_fn: ?CommitFn = null,
        /// Change-record encode buffer shared by every commit (callers
        /// serialize; persistence reuses its recovery buffer, so any record
        /// written is recoverable).
        encode_buffer: []u8 = &.{},
        durability_required: bool = false,
        /// A failed durable write requires recovery before further writes.
        storage_failed: bool = false,
        /// Monotonic time in nanoseconds, set by the caller before each call
        /// (wait starts, timeouts and deadlock checks use it).
        now_ns: i64 = 0,

        fn storageReady(self: *const Self) !void {
            if (self.storage_failed or (self.durability_required and self.commit_fn == null)) return error.StorageUnavailable;
        }

        /// Read-only transactions publish directly; others persist first.
        fn commit(self: *Self, slot: u16) !void {
            const db = &self.database;
            if (db.readOnly(slot)) {
                db.publishCommit(slot);
                return;
            }
            self.storageReady() catch |err| {
                db.abort(slot);
                return err;
            };
            if (self.commit_fn) |persist| {
                if (self.encode_buffer.len == 0) {
                    db.abort(slot);
                    return error.InvalidCommitBatch;
                }
                const payload = db.prepareCommit(slot, self.encode_buffer) catch |err| {
                    db.abort(slot);
                    return err;
                };
                persist(self.commit_ctx, payload) catch |err| {
                    db.abort(slot);
                    self.storage_failed = true;
                    return err;
                };
            }
            db.publishCommit(slot);
        }

        pub const Pending = struct {
            active: bool = false,
            fingerprint: u64 = 0,
            /// The parked statement runs in an implicit (autocommit) transaction.
            implicit: bool = false,
            wake_epoch: u64 = 0,
            wait_start_ns: i64 = 0,
            deadlock_check_ns: i64 = 0,
            deadlock_checked: bool = false,
            lock_deadline_ns: ?i64 = null,
            statement_deadline_ns: ?i64 = null,
            /// Transactions waited for; a different set is a new lock wait
            /// with its own deadlock check and lock_timeout, as in PostgreSQL.
            waits: Raw.LockSet = .{},
        };

        const SavedSettings = struct { current: Settings, base: Settings };

        pub const Connection = struct {
            pub const Result = Raw.Result;
            store: *Self,
            id: u64,
            dialect: Dialect = .postgres,
            failed: bool = false,
            autocommit: bool = true,
            /// Transaction slot (explicit block or a parked implicit statement).
            tx: ?u16 = null,
            in_transaction: bool = false,
            /// Effective settings, the session value SET (non-LOCAL) writes,
            /// the values at transaction start and the startup values.
            settings: Settings = .{},
            base: Settings = .{},
            tx_start: Settings = .{},
            startup: Settings = .{},
            saved: [Raw.savepoint_capacity]SavedSettings = undefined,
            saved_len: usize = 0,
            pending: Pending = .{},
            cancel_requested: bool = false,
            /// Savepoint depth of the last ROLLBACK TO, for the codec's portals.
            rolled_back_to: ?usize = null,

            /// Number of established savepoints (portal bookkeeping).
            pub fn savepointLevel(self: *const Connection) usize {
                return self.saved_len;
            }

            /// Depth of a ROLLBACK TO executed by the last statement, once.
            pub fn takeRollbackTo(self: *Connection) ?usize {
                const depth = self.rolled_back_to;
                self.rolled_back_to = null;
                return depth;
            }

            fn db(self: *Connection) *Raw {
                const raw = &self.store.database;
                raw.dialect = switch (self.dialect) {
                    .postgres => .postgres,
                    .mysql => .mysql,
                    .tds => .tds,
                };
                return raw;
            }

            pub fn beginTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.failed) return error.TransactionFailed;
                if (self.in_transaction) return;
                if (self.pending.active) return error.TransactionFailed;
                self.tx = try self.db().begin();
                self.in_transaction = true;
                self.failed = false;
                self.tx_start = self.settings;
                self.base = self.settings;
                self.saved_len = 0;
            }

            fn endTransaction(self: *Connection, committed: bool) void {
                self.settings = if (committed) self.base else self.tx_start;
                self.base = self.settings;
                self.tx = null;
                self.in_transaction = false;
                self.failed = false;
                self.saved_len = 0;
                self.pending = .{};
                self.cancel_requested = false;
            }

            pub fn commitTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (!self.in_transaction) return;
                const slot = self.tx.?;
                if (self.failed) {
                    self.db().abort(slot);
                    self.endTransaction(false);
                    return;
                }
                self.store.commit(slot) catch |err| {
                    // The transaction is gone either way, as in PostgreSQL.
                    self.endTransaction(false);
                    return err;
                };
                self.endTransaction(true);
            }

            pub fn rollbackTransaction(self: *Connection) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (self.tx) |slot| self.db().abort(slot);
                const was = self.in_transaction;
                self.endTransaction(false);
                if (!was) self.settings = self.base;
            }

            /// A codec-level error inside a block fails it like a statement error.
            pub fn failTransaction(self: *Connection) void {
                if (self.id == 0 or !self.in_transaction or self.failed) return;
                if (self.tx) |slot| self.db().failScope(slot);
                self.failed = true;
                self.pending = .{};
            }

            pub fn transactionStatus(self: *const Connection) u8 {
                if (self.id == 0 or !self.in_transaction) return 'I';
                return if (self.failed) 'E' else 'T';
            }

            pub fn isAutocommit(self: *const Connection) bool {
                return self.autocommit;
            }

            pub fn setAutocommit(self: *Connection, enabled: bool) !void {
                if (enabled and !self.autocommit) try self.commitTransaction();
                self.autocommit = enabled;
            }

            /// Aborts any parked statement and open transaction, releasing locks.
            pub fn disconnect(self: *Connection) void {
                if (self.id == 0) return;
                self.rollbackTransaction() catch {};
                self.pending = .{};
            }

            pub fn blocked(self: *const Connection) bool {
                return self.pending.active;
            }

            /// A cancel request for this connection (key already verified by
            /// the caller). Only a parked statement can be interrupted.
            pub fn requestCancel(self: *Connection) void {
                if (self.pending.active) self.cancel_requested = true;
            }

            /// Earliest timer of a parked statement (deadlock check, lock or
            /// statement timeout).
            pub fn nextDeadline(self: *const Connection) ?i64 {
                if (!self.pending.active) return null;
                var out: ?i64 = null;
                if (!self.pending.deadlock_checked) out = self.pending.deadlock_check_ns;
                for ([_]?i64{ self.pending.lock_deadline_ns, self.pending.statement_deadline_ns }) |candidate| {
                    if (candidate) |at| out = if (out) |current| @min(current, at) else at;
                }
                return out;
            }

            /// True when the parked statement should be re-delivered now.
            pub fn wakeReady(self: *const Connection) bool {
                if (!self.pending.active) return false;
                if (self.cancel_requested) return true;
                if (self.store.database.wake_epoch != self.pending.wake_epoch) return true;
                if (self.nextDeadline()) |at| return self.store.now_ns >= at;
                return false;
            }

            pub fn waitStart(self: *const Connection) i64 {
                return self.pending.wait_start_ns;
            }

            /// Applies one startup parameter (`options` with `-c name=value`
            /// / `--name=value` items, or application_name).
            pub fn startupParameter(self: *Connection, key: []const u8, value: []const u8) !void {
                if (same(key, "application_name")) {
                    try self.assign(&self.settings, .application_name, value, true);
                } else if (same(key, "options")) {
                    var index: usize = 0;
                    while (index < value.len) {
                        while (index < value.len and whitespace(value[index])) index += 1;
                        if (index == value.len) break;
                        var start = index;
                        while (index < value.len and !whitespace(value[index])) index += 1;
                        var item = value[start..index];
                        if (same(item, "-c")) {
                            while (index < value.len and whitespace(value[index])) index += 1;
                            start = index;
                            while (index < value.len and !whitespace(value[index])) index += 1;
                            item = value[start..index];
                        } else if (item.len > 2 and item[0] == '-' and item[1] == 'c') {
                            item = item[2..];
                        } else if (item.len > 2 and item[0] == '-' and item[1] == '-') {
                            item = item[2..];
                        } else return error.InvalidSettingValue;
                        var equals: usize = 0;
                        while (equals < item.len and item[equals] != '=') equals += 1;
                        if (equals == 0 or equals == item.len) return error.InvalidSettingValue;
                        const which = parameter(item[0..equals]) orelse return error.UndefinedSetting;
                        try self.assign(&self.settings, which, item[equals + 1 ..], true);
                    }
                } else return;
                self.base = self.settings;
                self.startup = self.settings;
            }

            fn assign(self: *Connection, target: *Settings, which: Parameter, value: []const u8, is_default: bool) !void {
                _ = self;
                switch (which) {
                    .lock_timeout => target.lock_timeout_ms = if (is_default and value.len == 0) 0 else try parseMilliseconds(value),
                    .statement_timeout => target.statement_timeout_ms = if (is_default and value.len == 0) 0 else try parseMilliseconds(value),
                    .application_name => {
                        const length = @min(value.len, 63);
                        @memcpy(target.application_name[0..length], value[0..length]);
                        target.application_name_len = @intCast(length);
                    },
                    .transaction_isolation, .default_transaction_isolation => {
                        if (!(value.len == 0 or sameInsensitive(value, "read committed") or sameInsensitive(value, "read uncommitted"))) return error.UnsupportedStatement;
                    },
                    .timezone => if (!(value.len == 0 or sameInsensitive(value, "UTC") or sameInsensitive(value, "Etc/UTC"))) return error.InvalidSettingValue,
                    .client_encoding => if (!(value.len == 0 or sameInsensitive(value, "UTF8") or sameInsensitive(value, "UTF-8"))) return error.InvalidSettingValue,
                    .standard_conforming_strings => if (!(value.len == 0 or sameInsensitive(value, "on") or sameInsensitive(value, "true"))) return error.InvalidSettingValue,
                    .datestyle => if (!(value.len == 0 or sameInsensitive(value, "ISO, MDY") or sameInsensitive(value, "ISO"))) return error.InvalidSettingValue,
                    .intervalstyle => if (!(value.len == 0 or sameInsensitive(value, "postgres"))) return error.InvalidSettingValue,
                    .deadlock_timeout, .server_version, .server_encoding, .integer_datetimes, .search_path => return error.InvalidSettingValue,
                }
            }

            fn showValue(self: *const Connection, which: Parameter, out: []u8) []const u8 {
                const value: []const u8 = switch (which) {
                    .lock_timeout => return formatMilliseconds(self.settings.lock_timeout_ms, out),
                    .statement_timeout => return formatMilliseconds(self.settings.statement_timeout_ms, out),
                    .deadlock_timeout => return formatMilliseconds(deadlock_timeout_ms, out),
                    .application_name => self.settings.applicationName(),
                    .transaction_isolation, .default_transaction_isolation => "read committed",
                    .timezone => "UTC",
                    .client_encoding, .server_encoding => "UTF8",
                    .standard_conforming_strings, .integer_datetimes => "on",
                    .datestyle => "ISO, MDY",
                    .intervalstyle => "postgres",
                    .server_version => "16.0",
                    .search_path => "\"$user\", public",
                };
                @memcpy(out[0..value.len], value);
                return out[0..value.len];
            }

            fn showResult(self: *const Connection, which: Parameter, result: *Result, rows: bool) void {
                result.clear(0);
                result.command = .show;
                result.column_count = 1;
                const name = canonical(which);
                const name_length = @min(name.len, result.column_names[0].bytes.len);
                result.column_names[0] = .{ .len = name_length };
                @memcpy(result.column_names[0].bytes[0..name_length], name[0..name_length]);
                result.column_types[0] = .text;
                if (!rows) return;
                var buffer: [128]u8 = undefined;
                const value = self.showValue(which, &buffer);
                var text: Raw.Text = .{};
                const length = @min(value.len, text.bytes.len);
                text.len = length;
                @memcpy(text.bytes[0..length], value[0..length]);
                result.row_count = 1;
                result.rows[0].cells[0] = .{ .text = text };
            }

            /// Parse and bind without executing (PostgreSQL Describe).
            pub fn describe(self: *Connection, source: []const u8, result: *Result) !void {
                if (self.id == 0) return error.InvalidConnection;
                const raw = self.db();
                const command = try raw.control(source);
                switch (command) {
                    .commit, .rollback, .rollback_to => {},
                    else => if (self.failed) return error.TransactionFailed,
                }
                switch (command) {
                    .none => return raw.describeIn(self.tx, source, result),
                    .show => |name| {
                        const which = parameter(name.slice()) orelse return error.UndefinedSetting;
                        self.showResult(which, result, false);
                    },
                    else => result.clear(0),
                }
            }

            fn control(self: *Connection, command: anytype, result: *Result) !void {
                switch (command) {
                    .none => unreachable,
                    .begin => |level| {
                        if (level == .repeatable_read or level == .serializable) return error.UnsupportedStatement;
                        try self.beginTransaction();
                        result.clear(0);
                        result.command = .begin;
                    },
                    .commit => {
                        try self.commitTransaction();
                        result.clear(0);
                        result.command = .commit;
                    },
                    .rollback => {
                        try self.rollbackTransaction();
                        result.clear(0);
                        result.command = .rollback;
                    },
                    .savepoint => |name| {
                        if (!self.in_transaction) return error.NoActiveTransaction;
                        if (self.failed) return error.TransactionFailed;
                        try self.db().savepoint(self.tx.?, name.slice());
                        self.saved[self.saved_len] = .{ .current = self.settings, .base = self.base };
                        self.saved_len += 1;
                        result.clear(0);
                        result.command = .savepoint;
                    },
                    .release => |name| {
                        if (!self.in_transaction) return error.NoActiveTransaction;
                        if (self.failed) return error.TransactionFailed;
                        self.saved_len = try self.db().release(self.tx.?, name.slice());
                        result.clear(0);
                        result.command = .release;
                    },
                    .rollback_to => |name| {
                        if (!self.in_transaction) return error.NoActiveTransaction;
                        const depth = try self.db().rollbackTo(self.tx.?, name.slice());
                        self.rolled_back_to = depth;
                        self.settings = self.saved[depth].current;
                        self.base = self.saved[depth].base;
                        self.saved_len = depth + 1;
                        self.failed = false;
                        result.clear(0);
                        result.command = .rollback;
                    },
                    .set => |set| {
                        if (self.failed) return error.TransactionFailed;
                        const which = parameter(set.name.slice()) orelse return error.UndefinedSetting;
                        const value = if (set.kind == .default) "" else set.value.slice();
                        var next = self.settings;
                        if (set.kind == .default) {
                            try self.assign(&next, which, "", true);
                            restore(&next, &self.startup, which);
                        } else try self.assign(&next, which, value, false);
                        if (set.local) {
                            // Outside a block SET LOCAL has no effect (PostgreSQL warns).
                            if (self.in_transaction) self.settings = next;
                        } else {
                            self.settings = next;
                            restore(&self.base, &next, which);
                        }
                        result.clear(0);
                        result.command = .set;
                    },
                    .set_transaction => |level| {
                        if (self.failed) return error.TransactionFailed;
                        if (level == .repeatable_read or level == .serializable) return error.UnsupportedStatement;
                        result.clear(0);
                        result.command = .set;
                    },
                    .show => |name| {
                        if (self.failed) return error.TransactionFailed;
                        const which = parameter(name.slice()) orelse return error.UndefinedSetting;
                        self.showResult(which, result, true);
                    },
                    .reset => |name| {
                        if (self.failed) return error.TransactionFailed;
                        if (name) |text| {
                            const which = parameter(text.slice()) orelse return error.UndefinedSetting;
                            restore(&self.settings, &self.startup, which);
                            restore(&self.base, &self.startup, which);
                        } else {
                            self.settings = self.startup;
                            self.base = self.startup;
                        }
                        result.clear(0);
                        result.command = .reset;
                    },
                }
            }

            fn restore(target: *Settings, source: *const Settings, which: Parameter) void {
                switch (which) {
                    .lock_timeout => target.lock_timeout_ms = source.lock_timeout_ms,
                    .statement_timeout => target.statement_timeout_ms = source.statement_timeout_ms,
                    .application_name => {
                        target.application_name = source.application_name;
                        target.application_name_len = source.application_name_len;
                    },
                    else => {},
                }
            }

            /// Terminal statement error policy (§4.4).
            fn terminal(self: *Connection, implicit: bool) void {
                self.pending = .{};
                self.cancel_requested = false;
                const slot = self.tx orelse return;
                if (implicit) {
                    self.db().abort(slot);
                    self.tx = null;
                } else {
                    self.db().failScope(slot);
                    self.failed = true;
                }
            }

            fn park(self: *Connection, source: []const u8, implicit: bool) void {
                const now = self.store.now_ns;
                self.pending = .{
                    .active = true,
                    .fingerprint = fingerprint(source),
                    .implicit = implicit,
                    .wake_epoch = self.store.database.wake_epoch,
                    .wait_start_ns = now,
                    .deadlock_check_ns = now + @as(i64, deadlock_timeout_ms) * 1000000,
                    .lock_deadline_ns = if (self.settings.lock_timeout_ms != 0) now + @as(i64, self.settings.lock_timeout_ms) * 1000000 else null,
                    .statement_deadline_ns = if (self.settings.statement_timeout_ms != 0) now + @as(i64, self.settings.statement_timeout_ms) * 1000000 else null,
                    .waits = self.store.database.waitingFor(self.tx.?),
                };
                self.cancel_requested = false;
            }

            /// A re-parked statement waiting for different transactions starts
            /// a new lock wait: fresh deadlock check and lock_timeout.
            fn rewait(self: *Connection, slot: u16) void {
                const waits = self.store.database.waitingFor(slot);
                var changed = false;
                for (waits.bits, self.pending.waits.bits) |a, b| changed = changed or a != b;
                if (!changed) return;
                const now = self.store.now_ns;
                self.pending.waits = waits;
                self.pending.wait_start_ns = now;
                self.pending.deadlock_check_ns = now + @as(i64, deadlock_timeout_ms) * 1000000;
                self.pending.deadlock_checked = false;
                if (self.settings.lock_timeout_ms != 0) self.pending.lock_deadline_ns = now + @as(i64, self.settings.lock_timeout_ms) * 1000000;
            }

            fn finish(self: *Connection, slot: u16, implicit: bool, result: *Result) !void {
                self.pending = .{};
                self.cancel_requested = false;
                if (!implicit) return;
                self.tx = null;
                try self.store.commit(slot);
                self.store.database.lastOutcomeInto(result);
            }

            fn run(self: *Connection, source: []const u8, result: *Result, slot: u16, implicit: bool, resuming: bool) !void {
                const writes = if (self.store.storageReady()) |_| true else |_| false;
                self.db().statement(slot, source, result, .{ .@"resume" = resuming, .writes = writes, .hold_result = implicit }) catch |err| {
                    if (err == error.WouldBlock) {
                        if (!resuming) {
                            self.park(source, implicit);
                            return err;
                        }
                        return self.stillBlocked(slot, implicit);
                    }
                    self.terminal(implicit);
                    return if (err == error.ReadOnlyTransaction) error.StorageUnavailable else err;
                };
                return self.finish(slot, implicit, result);
            }

            /// A re-delivered statement is still waiting: apply its timers.
            fn stillBlocked(self: *Connection, slot: u16, implicit: bool) !void {
                self.rewait(slot);
                const now = self.store.now_ns;
                var outcome: ?anyerror = null;
                if (self.pending.statement_deadline_ns) |at| {
                    if (now >= at) outcome = error.QueryCanceled;
                }
                if (outcome == null) if (self.pending.lock_deadline_ns) |at| {
                    if (now >= at) outcome = error.LockNotAvailable;
                };
                if (outcome == null and !self.pending.deadlock_checked and now >= self.pending.deadlock_check_ns) {
                    self.pending.deadlock_checked = true;
                    if (self.store.database.deadlocked(slot)) outcome = error.DeadlockDetected;
                }
                if (outcome) |err| {
                    self.db().abortStatement(slot);
                    self.terminal(implicit);
                    return err;
                }
                self.pending.wake_epoch = self.store.database.wake_epoch;
                return error.WouldBlock;
            }

            fn resumeStatement(self: *Connection, source: []const u8, result: *Result) !void {
                const slot = self.tx.?;
                const implicit = self.pending.implicit;
                if (fingerprint(source) != self.pending.fingerprint or self.cancel_requested) {
                    // A different statement while one is parked is an
                    // internal invariant failure; either way it is canceled.
                    self.db().abortStatement(slot);
                    self.terminal(implicit);
                    return error.QueryCanceled;
                }
                return self.run(source, result, slot, implicit, true);
            }

            pub fn execute(self: *Connection, source: []const u8, result: *Result) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (source.len == 0 or source.len > max_statement_bytes) return error.Syntax;
                if (self.pending.active) return self.resumeStatement(source, result);
                // Bounded MySQL/TDS session commands. Long SQL still goes
                // intact to the strict parser without a second SQL-sized copy.
                var command: [256]u8 = undefined;
                var count: usize = 0;
                var pending_space = false;
                var long_command = false;
                for (source) |byte| {
                    if (whitespace(byte)) {
                        pending_space = count != 0;
                        continue;
                    }
                    if (pending_space and byte != ';') {
                        if (count == command.len) {
                            long_command = true;
                            break;
                        }
                        command[count] = ' ';
                        count += 1;
                    }
                    pending_space = false;
                    if (count == command.len) {
                        long_command = true;
                        break;
                    }
                    command[count] = upper(byte);
                    count += 1;
                }
                if (count != 0 and command[count - 1] == ';') count -= 1;
                const cmd = if (long_command) "" else command[0..count];
                if (same(cmd, "SET AUTOCOMMIT = 0") or same(cmd, "SET AUTOCOMMIT=0") or same(cmd, "SET AUTOCOMMIT = 1") or same(cmd, "SET AUTOCOMMIT=1")) {
                    if (self.failed) return error.TransactionFailed;
                    try self.setAutocommit(cmd[cmd.len - 1] == '1');
                    result.clear(0);
                    return;
                }
                if (same(cmd, "SET NAMES UTF8MB4") or same(cmd, "SET NAMES UTF8") or same(cmd, "SET TEXTSIZE 2147483647")) {
                    if (self.failed) return error.TransactionFailed;
                    result.clear(0);
                    return;
                }
                const command_kind = self.db().control(source) catch |err| {
                    self.failTransaction();
                    return err;
                };
                if (command_kind != .none) {
                    const was_block = self.in_transaction;
                    self.control(command_kind, result) catch |err| {
                        if (was_block and self.in_transaction) self.failTransaction();
                        return err;
                    };
                    return;
                }
                if (self.failed) return error.TransactionFailed;
                if (!self.autocommit and !self.in_transaction) try self.beginTransaction();
                const implicit = !self.in_transaction;
                const slot = if (self.tx) |slot| slot else blk: {
                    const slot = try self.db().begin();
                    self.tx = slot;
                    break :blk slot;
                };
                return self.run(source, result, slot, implicit, false);
            }
        };
    };
}
