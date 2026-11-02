//! Caller-owned, allocator-free SQL store over the READ COMMITTED engine.
//!
//! Callers serialize default method calls; opt-in detached read contexts use
//! caller-held shared immutable ownership for the complete codec call.
//! Transaction concurrency comes from interleaved transactions in one shared Raw
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
//!
//! TimeZone (design §4.2/§4.8): UTC, a number of hours (ISO sign, shown as
//! `<+05>-05`), a zone name resolved through the caller's zone provider
//! (canonical spelling reported), or a POSIX TZ string (`UTC+3`, `+05:30`,
//! west-positive like PostgreSQL). DateStyle accepts ISO with MDY/DMY/YMD
//! order; IntervalStyle accepts postgres. Each statement runs with a session
//! (zone, transaction/statement timestamps from `wall_clock`); without a
//! clock now() and friends fail with 0A000. Changes to reported settings are
//! exposed to the PostgreSQL codec through takeParameterChanges() so it can
//! send ParameterStatus before ReadyForQuery.

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

pub const DateOrder = enum { mdy, dmy, ymd };

/// Session settings this store implements. Times are milliseconds.
pub fn SettingsOf(comptime Zone: type) type {
    return struct {
        const Self = @This();
        lock_timeout_ms: u32 = 0,
        statement_timeout_ms: u32 = 0,
        application_name: [64]u8 = @splat(0),
        application_name_len: u8 = 0,
        /// TimeZone as SHOW reports it, and the resolved zone.
        timezone: [64]u8 = [_]u8{ 'U', 'T', 'C' } ++ @as([61]u8, @splat(0)),
        timezone_len: u8 = 3,
        zone: Zone = .{},
        date_order: DateOrder = .mdy,

        pub fn applicationName(self: *const Self) []const u8 {
            return self.application_name[0..self.application_name_len];
        }

        pub fn timeZone(self: *const Self) []const u8 {
            return self.timezone[0..self.timezone_len];
        }

        pub fn dateStyle(self: *const Self) []const u8 {
            return switch (self.date_order) {
                .mdy => "ISO, MDY",
                .dmy => "ISO, DMY",
                .ymd => "ISO, YMD",
            };
        }
    };
}

/// ParameterStatus names, in the order the codec reports them.
pub const reported_parameters = [_][]const u8{ "application_name", "client_encoding", "DateStyle", "integer_datetimes", "IntervalStyle", "server_encoding", "server_version", "standard_conforming_strings", "TimeZone" };

fn digitByte(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

/// A plain (possibly signed, fractional) number of hours.
fn hoursValue(text: []const u8) ?i64 {
    var index: usize = 0;
    var negative = false;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        negative = text[index] == '-';
        index += 1;
    }
    var whole: i64 = 0;
    var digits: usize = 0;
    while (index < text.len and digitByte(text[index])) : (index += 1) {
        whole = whole * 10 + (text[index] - '0');
        digits += 1;
        if (whole > 1000) return null;
    }
    var micro_hours: i64 = 0;
    if (index < text.len and text[index] == '.') {
        index += 1;
        var scale: i64 = 100000;
        while (index < text.len and digitByte(text[index])) : (index += 1) {
            micro_hours += (text[index] - '0') * scale;
            scale = @divTrunc(scale, 10);
            digits += 1;
        }
    }
    if (digits == 0 or index != text.len) return null;
    // Seconds east (SQL sign), rounded to whole seconds.
    const seconds = whole * 3600 + @divTrunc(micro_hours * 3600 + 500000, 1000000);
    return if (negative) -seconds else seconds;
}

/// pg_tzset_offset display: `<+05>-05`, `<-03:30>+03:30` (east positive).
fn offsetName(east: i64, out: *[64]u8) u8 {
    var parts: [16]u8 = undefined;
    var used: usize = 0;
    var magnitude: u64 = @abs(east);
    const push2 = struct {
        fn call(buffer: []u8, at: *usize, value: u64) void {
            buffer[at.*] = @intCast('0' + (value / 10) % 10);
            buffer[at.* + 1] = @intCast('0' + value % 10);
            at.* += 2;
        }
    }.call;
    const hours = magnitude / 3600;
    if (hours >= 100) {
        parts[used] = @intCast('0' + hours / 100);
        used += 1;
    }
    push2(&parts, &used, hours);
    magnitude %= 3600;
    if (magnitude != 0) {
        parts[used] = ':';
        used += 1;
        push2(&parts, &used, magnitude / 60);
        magnitude %= 60;
        if (magnitude != 0) {
            parts[used] = ':';
            used += 1;
            push2(&parts, &used, magnitude);
        }
    }
    const inner = if (east >= 0) "+" else "-";
    const outer = if (east >= 0) "-" else "+";
    var at: usize = 0;
    for ([_][]const u8{ "<", inner, parts[0..used], ">", outer, parts[0..used] }) |piece| {
        @memcpy(out[at..][0..piece.len], piece);
        at += piece.len;
    }
    return @intCast(at);
}

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
    // Raw adapters without session values (test doubles) get a unit zone.
    const has_session = @hasDecl(Raw, "Zone");
    const Zone = if (has_session) Raw.Zone else struct {};
    const Settings = SettingsOf(Zone);
    const has_sequences = @hasDecl(Raw, "SequenceSession");
    const SequenceSession = if (has_sequences) Raw.SequenceSession else struct {};
    const has_control = @hasDecl(Raw, "ExecutionControl");
    const ExecutionControl = if (has_control) Raw.ExecutionControl else struct {};
    const ExecutionError = if (@hasDecl(Raw, "SqlError")) Raw.SqlError else anyerror;
    return struct {
        const Self = @This();
        pub const CommitFn = *const fn (?*anyopaque, []const u8) anyerror!void;
        pub const ZoneProvider = struct {
            context: ?*anyopaque = null,
            /// Resolves a zone name; writes the canonical spelling and
            /// returns its length. Unknown names fail (22023).
            lookup: *const fn (?*anyopaque, []const u8, *Zone, *[64]u8) anyerror!usize,
        };

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
        /// Live monotonic clock for running-statement deadlines. Without one,
        /// now_ns remains the deterministic caller-driven clock used by tests.
        monotonic_clock: ?*const fn () i64 = null,
        /// Zero means no work limit. Units count expression/operator/row steps,
        /// not elapsed time. Each connection owns its execution control.
        max_query_work: u64 = 0,
        interrupt_context: ?*anyopaque = null,
        /// May service cancellation I/O, but must not execute SQL/reenter a
        /// database operation. requestCancel is safe from this callback.
        interrupt_poll: ?*const fn (?*anyopaque, u64) void = null,
        /// Wall clock in PostgreSQL-epoch microseconds; null without one
        /// (now() and friends then fail with 0A000).
        wall_clock: ?*const fn () ?i64 = null,
        /// Named time zones (RAMSQL's zone directory); null = UTC and
        /// POSIX/offset zones only.
        zone_provider: ?ZoneProvider = null,

        /// Zone name -> zone: the provider (exact, then case-insensitive),
        /// built-in UTC, then a POSIX TZ string, as PostgreSQL's pg_tzset.
        fn resolveZone(self: *const Self, name: []const u8, zone: *Zone, spelled: *[64]u8) !usize {
            if (name.len == 0 or name.len > 64) return error.InvalidSettingValue;
            if (self.zone_provider) |provider| {
                if (provider.lookup(provider.context, name, zone, spelled)) |length| return length else |err| {
                    // A full zone cache is a capacity error (53200), not an unknown name.
                    if (err == error.TimeZoneCapacity) return err;
                }
            }
            if (!has_session) return error.InvalidSettingValue;
            if (sameInsensitive(name, "UTC") or sameInsensitive(name, "GMT") or sameInsensitive(name, "Etc/UTC") or sameInsensitive(name, "Zulu")) {
                zone.* = .{};
                const label: []const u8 = if (sameInsensitive(name, "Etc/UTC")) "Etc/UTC" else if (sameInsensitive(name, "GMT")) "GMT" else if (sameInsensitive(name, "Zulu")) "Zulu" else "UTC";
                @memcpy(spelled[0..label.len], label);
                return label.len;
            }
            const rule = Raw.tzif.parsePosix(name) catch return error.InvalidSettingValue;
            zone.* = if (rule.has_dst) .{ .kind = .posix, .posix = rule } else .{ .kind = .fixed, .offset = rule.std_offset };
            for (name, 0..) |byte, index| spelled[index] = upper(byte);
            return name.len;
        }

        fn resolverLookup(context: ?*anyopaque, name: []const u8, zone: *Zone) Raw.SqlError!void {
            const self: *const Self = @ptrCast(@alignCast(context.?));
            var spelled: [64]u8 = undefined;
            _ = self.resolveZone(name, zone, &spelled) catch return error.InvalidParameterValue;
        }

        fn wallNow(self: *const Self) ?i64 {
            const clock = self.wall_clock orelse return null;
            return clock();
        }

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
            /// A COPY FROM row is parked on a key wait: the built row is
            /// Connection.copy_row (inflight); copyResume re-checks it.
            copy: bool = false,
            /// Rows the parked COPY had inserted before the blocked one.
            rows_done: usize = 0,
        };

        const SavedSettings = struct { current: Settings, base: Settings };
        const ReportedValue = struct { bytes: [64]u8 = @splat(0), len: u8 = 0, valid: bool = false };

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
            /// Opt-in immutable autocommit SELECT route. The caller owns the
            /// context and excludes ALL storage mutations for the entire codec
            /// call, including result formatting. Never set for transaction,
            /// prepared-portal, COPY or session-control execution.
            read_context: if(@hasDecl(Raw,"ReadContext")) ?*Raw.ReadContext else ?*void = null,
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
            running_statement: bool = false,
            execution: ExecutionControl = .{},
            execution_deadline_ns: ?i64 = null,
            /// Savepoint depth of the last ROLLBACK TO, for the codec's portals.
            rolled_back_to: ?usize = null,
            /// Wall-clock start of the open (or implicit) transaction and of
            /// the current statement, PostgreSQL-epoch microseconds.
            transaction_us: ?i64 = null,
            statement_us: ?i64 = null,
            /// Values last reported through ParameterStatus.
            reported: [reported_parameters.len]ReportedValue = @splat(.{}),
            /// currval/lastval state of this session.
            sequences: SequenceSession = .{},
            /// Startup `database` (current_database(); information_schema catalogs).
            database_name: [64]u8 = @splat(0),
            database_len: u8 = 0,
            /// The open COPY FROM runs in an implicit transaction.
            copy_implicit: bool = false,
            copy_rows: usize = 0,
            /// The COPY FROM row being inserted (kept while it is parked).
            copy_row: Raw.Row = .{},

            pub const CopyInfo = Raw.CopyInfo;
            pub const copy_line_bytes = Raw.copy_line_bytes;

            pub fn reportedParameters() []const []const u8 {
                return &reported_parameters;
            }

            /// Current value of reported_parameters[index].
            pub fn parameterValue(self: *const Connection, index: usize, out: *[64]u8) []const u8 {
                const value: []const u8 = switch (index) {
                    0 => self.settings.applicationName(),
                    1, 5 => "UTF8",
                    2 => self.settings.dateStyle(),
                    3, 7 => "on",
                    4 => "postgres",
                    6 => "16.0",
                    8 => self.settings.timeZone(),
                    else => unreachable,
                };
                @memcpy(out[0..value.len], value);
                return out[0..value.len];
            }

            /// Bit i set: reported_parameters[i] changed since the last call
            /// (all bits on the first call). Marks them reported.
            pub fn takeParameterChanges(self: *Connection) u16 {
                var mask: u16 = 0;
                for (&self.reported, 0..) |*entry, index| {
                    var buffer: [64]u8 = undefined;
                    const current = self.parameterValue(index, &buffer);
                    if (!entry.valid or !same(entry.bytes[0..entry.len], current)) {
                        mask |= @as(u16, 1) << @intCast(index);
                        @memcpy(entry.bytes[0..current.len], current);
                        entry.len = @intCast(current.len);
                        entry.valid = true;
                    }
                }
                return mask;
            }

            /// Session values (zone, clocks) for output formatting.
            pub fn valueSession(self: *Connection) *const Raw.SessionValues {
                if(comptime @hasDecl(Raw,"ReadContext")) if(self.read_context) |context| return &context.session;
                return &self.db().session;
            }
            pub fn detachedReadEligible(self:*const Connection) bool {
                return self.id!=0 and !self.failed and self.autocommit and !self.in_transaction and self.tx==null and
                    !self.pending.active and !self.running_statement and self.read_context==null;
            }
            /// No global Raw.session installation or mutable zone lookup hook.
            /// A caller using named-zone operations must provide a read-safe
            /// resolver or keep those operations on the serialized path.
            pub fn detachedReadSession(self:*const Connection,execution_control:*ExecutionControl,statement_us:?i64) Raw.SessionValues {
                return .{.zone=self.settings.zone,.transaction_us=statement_us,.statement_us=statement_us,
                    .clock=self.store.wall_clock,.database=if(self.database_len==0) "postgres" else self.database_name[0..self.database_len],.control=execution_control};
            }

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
                if (comptime has_sequences) raw.sequence_session = &self.sequences;
                raw.dialect = switch (self.dialect) {
                    .postgres => .postgres,
                    .mysql => .mysql,
                    .tds => .tds,
                };
                if (comptime has_session) raw.session = .{
                    .zone = self.settings.zone,
                    .resolver = .{ .context = @ptrCast(self.store), .lookup = &resolverLookup },
                    .transaction_us = self.transaction_us orelse self.statement_us,
                    .statement_us = self.statement_us,
                    .clock = self.store.wall_clock,
                    .database = if (self.database_len == 0) "postgres" else self.database_name[0..self.database_len],
                };
                if (comptime has_control) raw.session.control = if (self.running_statement) &self.execution else null;
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
                self.transaction_us = self.store.wallNow();
                self.tx_start = self.settings;
                self.base = self.settings;
                self.saved_len = 0;
            }

            fn endTransaction(self: *Connection, committed: bool) void {
                self.transaction_us = null;
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
                self.revertSettings();
            }

            /// An error inside a block reverts settings made since the
            /// innermost savepoint (or BEGIN) at once, as PostgreSQL's
            /// AbortTransaction / AbortSubTransaction (AtEOXact_GUC) do.
            fn revertSettings(self: *Connection) void {
                if (self.saved_len > 0) {
                    self.settings = self.saved[self.saved_len - 1].current;
                    self.base = self.saved[self.saved_len - 1].base;
                } else {
                    self.settings = self.tx_start;
                    self.base = self.tx_start;
                }
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
            /// the caller). Running work observes it at an execution checkpoint.
            pub fn requestCancel(self: *Connection) void {
                if (self.pending.active or self.running_statement) self.cancel_requested = true;
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
                if (same(key, "database")) {
                    if (value.len > self.database_name.len) return error.InvalidSettingValue;
                    @memcpy(self.database_name[0..value.len], value);
                    self.database_len = @intCast(value.len);
                    return;
                }
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
                    .timezone => try self.assignZone(target, value),
                    .client_encoding => if (!(value.len == 0 or sameInsensitive(value, "UTF8") or sameInsensitive(value, "UTF-8"))) return error.InvalidSettingValue,
                    .standard_conforming_strings => if (!(value.len == 0 or sameInsensitive(value, "on") or sameInsensitive(value, "true"))) return error.InvalidSettingValue,
                    .datestyle => target.date_order = try dateOrder(value, target.date_order),
                    .intervalstyle => if (!(value.len == 0 or sameInsensitive(value, "postgres"))) return error.InvalidSettingValue,
                    .deadlock_timeout, .server_version, .server_encoding, .integer_datetimes, .search_path => return error.InvalidSettingValue,
                }
            }

            fn assignZone(self: *Connection, target: *Settings, raw_value: []const u8) !void {
                var value = raw_value;
                while (value.len != 0 and whitespace(value[0])) value = value[1..];
                while (value.len != 0 and whitespace(value[value.len - 1])) value = value[0 .. value.len - 1];
                if (value.len == 0 or sameInsensitive(value, "local") or sameInsensitive(value, "default")) {
                    target.zone = .{};
                    target.timezone_len = 3;
                    @memcpy(target.timezone[0..3], "UTC");
                    return;
                }
                if (hoursValue(value)) |east| {
                    if (!has_session) return error.InvalidSettingValue;
                    // PostgreSQL limits numeric zones to +-15:59:59... via
                    // pg_tzset_offset's range; reject beyond 168 hours.
                    if (east > 168 * 3600 or east < -168 * 3600) return error.InvalidSettingValue;
                    target.zone = .{ .kind = .fixed, .offset = @intCast(east) };
                    target.timezone_len = offsetName(east, &target.timezone);
                    return;
                }
                var zone: Zone = .{};
                var spelled: [64]u8 = undefined;
                const length = try self.store.resolveZone(value, &zone, &spelled);
                target.zone = zone;
                @memcpy(target.timezone[0..length], spelled[0..length]);
                target.timezone_len = @intCast(length);
            }

            /// DateStyle: a comma list of ISO and at most one order keyword.
            fn dateOrder(value: []const u8, current: DateOrder) !DateOrder {
                if (value.len == 0) return .mdy;
                var order = current;
                var index: usize = 0;
                while (index <= value.len) {
                    var end = index;
                    while (end < value.len and value[end] != ',') end += 1;
                    var item = value[index..end];
                    while (item.len != 0 and whitespace(item[0])) item = item[1..];
                    while (item.len != 0 and whitespace(item[item.len - 1])) item = item[0 .. item.len - 1];
                    if (sameInsensitive(item, "ISO")) {
                        // The only output style implemented (non-ISO styles: F3).
                    } else if (sameInsensitive(item, "MDY") or sameInsensitive(item, "US") or sameInsensitive(item, "NONEURO") or sameInsensitive(item, "NONEUROPEAN")) {
                        order = .mdy;
                    } else if (sameInsensitive(item, "DMY") or sameInsensitive(item, "EURO") or sameInsensitive(item, "EUROPEAN")) {
                        order = .dmy;
                    } else if (sameInsensitive(item, "YMD")) {
                        order = .ymd;
                    } else if (sameInsensitive(item, "DEFAULT")) {
                        order = .mdy;
                    } else return error.InvalidSettingValue;
                    index = end + 1;
                }
                return order;
            }

            fn showValue(self: *const Connection, which: Parameter, out: []u8) []const u8 {
                const value: []const u8 = switch (which) {
                    .lock_timeout => return formatMilliseconds(self.settings.lock_timeout_ms, out),
                    .statement_timeout => return formatMilliseconds(self.settings.statement_timeout_ms, out),
                    .deadlock_timeout => return formatMilliseconds(deadlock_timeout_ms, out),
                    .application_name => self.settings.applicationName(),
                    .transaction_isolation, .default_transaction_isolation => "read committed",
                    .timezone => self.settings.timeZone(),
                    .client_encoding, .server_encoding => "UTF8",
                    .standard_conforming_strings, .integer_datetimes => "on",
                    .datestyle => self.settings.dateStyle(),
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
                if(comptime @hasDecl(Raw,"ReadContext")) if(self.read_context) |context| {
                    if(self.failed or self.in_transaction or self.tx!=null or !self.autocommit or self.pending.active) return error.InvalidParameterValue;
                    if(context.preparation_error) |err| switch(err) {
                        error.QueryCanceled,error.QueryWorkLimit=>return err,
                        else=>{},
                    };
                    // Describe may receive a transient interpolation buffer;
                    // never inspect a source retained from an earlier call.
                    return context.describe(&self.store.database,source,.{.csn=self.store.database.csn},result);
                };
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
                    .timezone => {
                        target.timezone = source.timezone;
                        target.timezone_len = source.timezone_len;
                        target.zone = source.zone;
                    },
                    .datestyle => target.date_order = source.date_order,
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
                    self.revertSettings();
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
                    .statement_deadline_ns = if (comptime has_control) self.execution_deadline_ns else if (self.settings.statement_timeout_ms != 0) now + @as(i64, self.settings.statement_timeout_ms) * 1000000 else null,
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
                if (comptime has_control) {
                    if (!resuming) {
                        self.execution.reset(self.store.max_query_work);
                        self.execution.context = self;
                        self.execution.poll = &pollExecution;
                        const now = if (self.store.monotonic_clock) |clock| clock() else self.store.now_ns;
                        self.execution_deadline_ns = if (self.settings.statement_timeout_ms != 0) now + @as(i64, self.settings.statement_timeout_ms) * 1000000 else null;
                        self.cancel_requested = false;
                    }
                }
                self.running_statement = true;
                defer {
                    self.running_statement = false;
                    if (comptime has_control) self.store.database.session.control = null;
                }
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

            fn pollExecution(context: ?*anyopaque) ExecutionError!void {
                const self: *Connection = @ptrCast(@alignCast(context.?));
                if (self.store.interrupt_poll) |poll| poll(self.store.interrupt_context, self.id);
                if (self.cancel_requested) return error.QueryCanceled;
                if (self.execution_deadline_ns) |deadline| {
                    const now = if (self.store.monotonic_clock) |clock| clock() else self.store.now_ns;
                    if (now >= deadline) return error.QueryCanceled;
                }
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

            // ---- COPY (design §4.7, §5.17) ----------------------------------

            /// Parses and validates a COPY statement and binds its target
            /// (never executes). COPY TO writes its SELECT into `select`.
            pub fn copyDescribe(self: *Connection, source: []const u8, select: []u8) !Raw.CopyInfo {
                if (self.id == 0) return error.InvalidConnection;
                if (self.failed) return error.TransactionFailed;
                if (self.pending.active and self.pending.copy) return error.QueryCanceled;
                return self.db().copyInfo(self.tx, source, select);
            }

            /// Opens COPY FROM STDIN as one statement of the open block (or
            /// an implicit transaction). Its rows stay in the statement
            /// subtransaction until copyEnd; copyFail, an error or a
            /// disconnect rolls the whole COPY back. A table-lock wait
            /// parks it (WouldBlock): re-deliver the same statement.
            pub fn copyBegin(self: *Connection, source: []const u8) !Raw.CopyInfo {
                if (self.id == 0) return error.InvalidConnection;
                if (self.pending.active) {
                    const slot = self.tx.?;
                    const implicit = self.pending.implicit;
                    if (self.pending.copy or fingerprint(source) != self.pending.fingerprint or self.cancel_requested) {
                        self.db().abortStatement(slot);
                        self.terminal(implicit);
                        return error.QueryCanceled;
                    }
                    const info = self.db().copyBegin(slot, source, true) catch |err| {
                        if (err == error.WouldBlock) {
                            try self.stillBlocked(slot, implicit);
                            unreachable;
                        }
                        self.terminal(implicit);
                        return err;
                    };
                    self.pending = .{};
                    self.cancel_requested = false;
                    self.copy_implicit = implicit;
                    self.copy_rows = 0;
                    return info;
                }
                if (self.failed) return error.TransactionFailed;
                if (!self.autocommit and !self.in_transaction) try self.beginTransaction();
                self.statement_us = self.store.wallNow();
                const implicit = !self.in_transaction;
                const slot = if (self.tx) |slot| slot else blk: {
                    const slot = try self.db().begin();
                    self.tx = slot;
                    break :blk slot;
                };
                self.store.storageReady() catch |err| {
                    self.terminal(implicit);
                    return err;
                };
                const info = self.db().copyBegin(slot, source, false) catch |err| {
                    if (err == error.WouldBlock) {
                        self.park(source, implicit);
                        return err;
                    }
                    self.terminal(implicit);
                    return err;
                };
                self.copy_implicit = implicit;
                self.copy_rows = 0;
                return info;
            }

            /// One data row (fields in COPY column order, null = NULL).
            /// WouldBlock: the row is parked on a key wait and owned by the
            /// store; call copyResume when wakeReady() reports progress.
            /// Any other error has rolled the COPY back.
            pub fn copyRow(self: *Connection, source: []const u8, fields: []const ?[]const u8) !void {
                const slot = self.tx orelse return error.NoActiveTransaction;
                if (self.pending.active) return error.QueryCanceled;
                self.db().copyBuild(slot, source, fields, &self.copy_row) catch |err| {
                    self.terminal(self.copy_implicit);
                    return err;
                };
                return self.insertCopyRow(slot);
            }

            fn insertCopyRow(self: *Connection, slot: u16) !void {
                self.db().copyInsert(slot, &self.copy_row) catch |err| {
                    if (err == error.WouldBlock) {
                        self.park("", self.copy_implicit);
                        self.pending.copy = true;
                        self.pending.rows_done = self.copy_rows;
                        return err;
                    }
                    self.terminal(self.copy_implicit);
                    return err;
                };
                self.copy_rows += 1;
            }

            /// A COPY row is parked on a key wait.
            pub fn copyBlocked(self: *const Connection) bool {
                return self.pending.active and self.pending.copy;
            }

            /// Re-checks the parked COPY row: inserted (pending cleared),
            /// still waiting (WouldBlock, timers applied) or a terminal
            /// error (23505 after the other inserter committed, 55P03,
            /// 57014, 40P01) with the COPY rolled back.
            pub fn copyResume(self: *Connection) !void {
                if (!self.copyBlocked()) return;
                const slot = self.tx.?;
                const implicit = self.pending.implicit;
                if (self.cancel_requested) {
                    self.db().abortStatement(slot);
                    self.terminal(implicit);
                    return error.QueryCanceled;
                }
                self.db().copyInsert(slot, &self.copy_row) catch |err| {
                    if (err == error.WouldBlock) return self.stillBlocked(slot, implicit);
                    self.terminal(implicit);
                    return err;
                };
                self.pending = .{};
                self.cancel_requested = false;
                self.copy_rows += 1;
            }

            /// Completes COPY FROM (CopyDone): commits an implicit
            /// transaction (53200 / storage errors abort it). Returns rows.
            pub fn copyEnd(self: *Connection) !usize {
                const slot = self.tx orelse return error.NoActiveTransaction;
                if (self.pending.active) return error.QueryCanceled;
                const rows = try self.db().copyEnd(slot);
                if (self.copy_implicit) {
                    self.tx = null;
                    try self.store.commit(slot);
                }
                return rows;
            }

            /// CopyFail, malformed data or a protocol error: rolls the COPY
            /// back (and the implicit transaction, or fails the block).
            pub fn copyFail(self: *Connection) void {
                if (self.id == 0) return;
                self.terminal(self.copy_implicit);
            }

            pub fn execute(self: *Connection, source: []const u8, result: *Result) !void {
                if (self.id == 0) return error.InvalidConnection;
                if (source.len == 0 or source.len > max_statement_bytes) return error.Syntax;
                if(comptime @hasDecl(Raw,"ReadContext")) if(self.read_context) |context| {
                    if(self.failed or self.in_transaction or self.tx!=null or !self.autocommit or self.pending.active or
                        context.database==null or context.database.?!=&self.store.database or !same(source,context.source)) return error.InvalidParameterValue;
                    // Metadata-only Describe invalidates executable preparation.
                    // Rebind under the same caller-held read snapshot before run.
                    if(context.prepared==null and context.preparation_error==null)
                        try context.prepare(&self.store.database,source,context.snapshot);
                    return context.run(result);
                };
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
                self.statement_us = self.store.wallNow();
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
