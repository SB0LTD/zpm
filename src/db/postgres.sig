//! PostgreSQL v3 wire protocol over caller-owned input/output buffers (Layer 1).
//! No socket, allocator, borrowed statement, or borrowed parameter storage.
//! Configure SCRAM before startup for credential authentication. Trust mode is
//! intended only for a caller that explicitly binds to a trusted interface.
//! SQL semantics are those provided by DB; unsupported features return SQLSTATE.
const std = @import("std");
const scram = @import("scram");
const sql = @import("sql");
const pg_types = @import("pg_types.sig");
const pg_copy = @import("pg_copy.sig");
/// COPY data formats (text, csv, binary framing and escaping).
pub const copy_format = pg_copy;
pub const max_packet: usize = 65535;
pub const sql_capacity: usize = 65536;
pub const statement_capacity: usize = 8;
pub const portal_capacity: usize = 8;
pub const parameter_capacity: usize = 32;
/// A CancelRequest's key; the caller looks it up (the codec never does).
pub const Cancel = struct { pid: u32, secret: u32 };

const startup_version: u32 = 196608;
const cancel_code: u32 = 80877102;
const ssl_code: u32 = 80877103;
const gss_code: u32 = 80877104;

pub const StartupFrame = union(enum) {
    /// Minimum number of bytes to buffer before checking again.
    incomplete: usize,
    invalid_length,
    protocol_violation: usize,
    unsupported_protocol: usize,
    ssl_request,
    gss_request,
    cancel: Cancel,
    /// The StartupMessage parameters, excluding the length and version.
    startup: []const u8,
};

/// Classify one untyped startup frame, leaving coalesced bytes to the caller.
/// An encryption request alone never changes session or transport state.
pub fn classifyStartup(input: []const u8) StartupFrame {
    if (input.len < 4) return .{ .incomplete = 4 };
    const size: usize = read32(input[0..4]);
    if (size < 4 or size > max_packet) return .invalid_length;
    if (input.len < @min(size, 8)) return .{ .incomplete = @min(size, 8) };
    if (size < 8) return .{ .protocol_violation = size };
    if (input.len < size) return .{ .incomplete = size };
    return switch (read32(input[4..8])) {
        startup_version => .{ .startup = input[8..size] },
        ssl_code => if (size == 8) .ssl_request else .{ .protocol_violation = size },
        gss_code => if (size == 8) .gss_request else .{ .protocol_violation = size },
        cancel_code => if (size == 16) .{ .cancel = .{ .pid = read32(input[8..12]), .secret = read32(input[12..16]) } }
            else .{ .unsupported_protocol = size },
        else => .{ .unsupported_protocol = size },
    };
}

/// Inspect only the untyped startup header; never executes a session or SQL.
pub fn isCancelHeader(input: []const u8) bool {
    return input.len >= 8 and read32(input[0..4]) == 16 and read32(input[4..8]) == cancel_code;
}

pub fn parseCancel(input: []const u8) ?Cancel {
    return switch (classifyStartup(input)) {
        .cancel => |key| key,
        else => null,
    };
}
/// `blocked`: the message's statement is parked on a lock (consumed =
/// written = 0); re-deliver the same bytes when the store reports progress.
/// During COPY FROM a row parked on a key wait is already owned by the
/// store: `consumed` then covers the input through that row (written = 0);
/// keep the rest buffered and call handle() again on wake (with or without
/// new input) - the parked row is re-checked before anything is read.
/// A simple Query batch can write one result with `consumed = 0`. Keep the
/// identical input frame at the head of the buffer for the next call.
/// `cancel`: the connection carried a CancelRequest (close it afterwards).
pub const Reply = struct { consumed: usize = 0, written: usize = 0, close: bool = false, blocked: bool = false, cancel: ?Cancel = null };

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn keyword(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower(x) != lower(y)) return false;
    return true;
}
fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
fn word(source: []const u8, wanted: []const u8) bool {
    var s = trim(source);
    while (s.len >= 2 and s[0] == '-' and s[1] == '-') {
        var end: usize = 2;
        while (end < s.len and s[end] != '\n') : (end += 1) {}
        s = trim(s[end..]);
    }
    if (s.len < wanted.len) return false;
    for (s[0..wanted.len], wanted) |x, y| if (lower(x) != lower(y)) return false;
    return s.len == wanted.len or s[wanted.len] == ' ' or s[wanted.len] == '\t' or s[wanted.len] == '\r' or s[wanted.len] == '\n' or s[wanted.len] == ';';
}
fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\n' or s[a] == '\r' or s[a] == '\t' or s[a] == ';')) : (a += 1) {}
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\n' or s[b - 1] == '\r' or s[b - 1] == '\t' or s[b - 1] == ';')) : (b -= 1) {}
    return s[a..b];
}

fn needsQueryScan(source: []const u8) bool {
    const text = std.mem.trim(u8, source, " \t\r\n\x0b\x0c");
    if (text.len == 0) return false;
    if (std.mem.startsWith(u8, text, "--") or std.mem.startsWith(u8, text, "/*")) return true;
    // A single terminal semicolon is already handled by the ordinary parser.
    const end = if (text[text.len - 1] == ';') text.len - 1 else text.len;
    return std.mem.indexOfScalar(u8, text[0..end], ';') != null;
}

fn read32(s: []const u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}
fn write32(s: []u8, n: u32) void {
    s[0] = @truncate(n >> 24);
    s[1] = @truncate(n >> 16);
    s[2] = @truncate(n >> 8);
    s[3] = @truncate(n);
}
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.at) return error.ProtocolViolation;
        const v = self.bytes[self.at..][0..n];
        self.at += n;
        return v;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn u16be(self: *Reader) !u16 {
        const b = try self.take(2);
        return (@as(u16, b[0]) << 8) | b[1];
    }
    fn u32be(self: *Reader) !u32 {
        return read32(try self.take(4));
    }
    fn string(self: *Reader) ![]const u8 {
        const begin = self.at;
        while (self.at < self.bytes.len) : (self.at += 1) {
            if (self.bytes[self.at] == 0) {
                const v = self.bytes[begin..self.at];
                self.at += 1;
                return v;
            }
        }
        return error.ProtocolViolation;
    }
    fn done(self: *const Reader) !void {
        if (self.at != self.bytes.len) return error.ProtocolViolation;
    }
};
pub const StartupMethod = enum { trusted, scram };
pub const routed_startup_capacity = 10000;

/// A routed adapter handles this synchronously after verification. Its
/// slices are borrowed for the call. Commit the route and startup options
/// together, or release any provisional Store lease before returning error.
pub const StartupAdmission = struct {
    method: StartupMethod,
    user: []const u8,
    database: []const u8,
    payload: []const u8,

    pub fn parameters(self: StartupAdmission) StartupParameters {
        return .{ .reader = .{ .bytes = self.payload } };
    }
};

pub const StartupParameters = struct {
    pub const Parameter = struct { key: []const u8, value: []const u8 };
    reader: Reader,
    ended: bool = false,

    pub fn next(self: *StartupParameters) !?Parameter {
        if (self.ended) return null;
        const key = try self.reader.string();
        if (key.len == 0) {
            try self.reader.done();
            self.ended = true;
            return null;
        }
        return .{ .key = key, .value = try self.reader.string() };
    }
};

fn inspectRoutedStartup(payload: []const u8, method: StartupMethod) !StartupAdmission {
    var params: StartupParameters = .{ .reader = .{ .bytes = payload } };
    var user: ?[]const u8 = null;
    var database: ?[]const u8 = null;
    while (try params.next()) |param| {
        if (equal(param.key, "user")) {
            if (user != null) return error.ProtocolViolation;
            user = param.value;
        } else if (equal(param.key, "database")) {
            if (database != null) return error.ProtocolViolation;
            database = param.value;
        } else if (equal(param.key, "client_encoding") and !equal(param.value, "UTF8") and !equal(param.value, "UTF-8")) {
            return error.UnsupportedEncoding;
        }
    }
    const requested_user = user orelse return error.UserRequired;
    if (requested_user.len == 0) return error.UserRequired;
    const requested_db = if (database != null and database.?.len != 0) database.? else requested_user;
    if (!std.unicode.utf8ValidateSlice(requested_user) or !std.unicode.utf8ValidateSlice(requested_db)) return error.CharacterNotInRepertoire;
    return .{ .method = method, .user = requested_user, .database = requested_db, .payload = payload };
}

const Writer = struct {
    bytes: []u8,
    at: usize = 0,
    fn append(self: *Writer, bytes: []const u8) !void {
        if (bytes.len > self.bytes.len - self.at) return error.BufferTooSmall;
        @memcpy(self.bytes[self.at..][0..bytes.len], bytes);
        self.at += bytes.len;
    }
    fn byte(self: *Writer, b: u8) !void {
        try self.append(&.{b});
    }
    fn u16be(self: *Writer, n: u16) !void {
        try self.append(&.{ @truncate(n >> 8), @truncate(n) });
    }
    fn u32be(self: *Writer, n: u32) !void {
        var b: [4]u8 = undefined;
        write32(&b, n);
        try self.append(&b);
    }
    fn string(self: *Writer, s: []const u8) !void {
        try self.append(s);
        try self.byte(0);
    }
    fn begin(self: *Writer, tag: u8) !usize {
        try self.byte(tag);
        const p = self.at;
        try self.u32be(4);
        return p;
    }
    fn end(self: *Writer, p: usize) void {
        write32(self.bytes[p..][0..4], @intCast(self.at - p));
    }
    fn empty(self: *Writer, tag: u8) !void {
        _ = try self.begin(tag);
    }
    fn number(self: *Writer, value: i64) !void {
        var digits: [20]u8 = undefined;
        var n: u64 = if (value < 0) @as(u64, @intCast(-(value + 1))) + 1 else @intCast(value);
        var i = digits.len;
        while (true) {
            i -= 1;
            digits[i] = @as(u8, @intCast(n % 10)) + '0';
            n /= 10;
            if (n == 0) break;
        }
        if (value < 0) try self.byte('-');
        try self.append(digits[i..]);
    }
};

pub fn Session(comptime DB: type) type {
    return SessionWithAdmission(DB, false);
}

/// Hosts using an existing adapter may supply an optional startup callback
/// and caller-owned scratch. The configured scratch is required until the
/// connection has finished startup.
pub fn SessionWithAdmission(comptime DB: type, comptime external_admission: bool) type {
    const T = pg_types.Types(DB.Result);
    const has_copy = @hasDecl(DB, "copyBegin");
    const has_simple_batch = @hasDecl(DB, "simple_query_batches") and DB.simple_query_batches;
    const detects_admission = @hasDecl(DB, "admitPostgresStartup");
    const has_admission = detects_admission or external_admission;
    const has_primary_key = @hasDecl(DB, "executeDetachedPrimaryKey") and
        (if (@hasDecl(DB, "detached_primary_key")) DB.detached_primary_key else true);
    const has_cached_primary_key = @hasDecl(DB, "executeCachedDetachedPrimaryKey") and
        (if (@hasDecl(DB, "detached_cached_primary_key")) DB.detached_cached_primary_key else true);
    const KeyView = if (@hasDecl(DB, "DetachedKeyView") and @hasDecl(DB, "viewCachedDetachedPrimaryKey")) DB.DetachedKeyView else void;
    const primary_key_sql_capacity = 256;
    const result_format_capacity = 256;
    const CopyInfo = if (has_copy) DB.CopyInfo else struct {};
    const line_bytes: usize = if (has_copy) DB.copy_line_bytes else 1;
    const field_capacity: usize = if (has_copy) (CopyInfo{}).types.len else 1;
    return struct {
        const Self = @This();
        const utc_session: T.Session = .{};

        /// COPY FROM STDIN state (design §4.7). `remaining` counts the
        /// bytes of the current CopyData body not yet consumed (bodies are
        /// streamed, so their size is not bounded by the caller's input
        /// buffer); `carry` holds an incomplete row across messages
        /// (Config.copy_line_bytes); `discard` drops CopyData/CopyDone/
        /// CopyFail after an error, as PostgreSQL does.
        const CopyState = struct {
            mode: enum { none, in, discard } = .none,
            portal: ?usize = null,
            remaining: usize = 0,
            info: CopyInfo = .{},
            sql: [sql_capacity]u8 = undefined,
            sql_start: usize = 0,
            sql_len: usize = 0,
            carry: [line_bytes]u8 = undefined,
            carry_len: usize = 0,
            /// The carry may hold complete rows (left by a parked row).
            carry_rows: bool = false,
            scratch: [2 * line_bytes]u8 = undefined,
            header_pending: bool = false,
            binary_header: bool = false,
            ended: bool = false,
            eol: pg_copy.Eol = .unknown,
        };
        const Fed = struct { used: usize = 0, blocked: bool = false };

        const SimpleBatch = struct {
            position: usize = 0,
            remaining: usize = 0,
            source_length: usize = 0,
            /// COPY takes ownership of the complete Query in CopyState.sql.
            owned: bool = false,
        };

        const SimpleCopySource = struct {
            source: []const u8,
            command_start: usize,
        };

        fn valueSession(db: *DB) *const T.Session {
            if (@hasDecl(DB, "valueSession")) return db.valueSession();
            return &utc_session;
        }
        const Name = struct {
            bytes: [64]u8 = @splat(0),
            len: usize = 0,
            fn set(self: *Name, value: []const u8) !void {
                if (value.len > self.bytes.len) return error.NameCapacity;
                @memcpy(self.bytes[0..value.len], value);
                self.len = value.len;
            }
            fn slice(self: *const Name) []const u8 {
                return self.bytes[0..self.len];
            }
        };
        const Statement = struct {
            live: bool = false,
            name: Name = .{},
            sql: [sql_capacity]u8 = @splat(0),
            len: usize = 0,
            count: usize = 0,
            single_parameter: ?ParameterSpan = null,
            oids: [parameter_capacity]u32 = @splat(0),
            fn source(self: *const Statement) []const u8 {
                return self.sql[0..self.len];
            }
        };
        pub const DetachedPrimaryKey = struct { source: []const u8, oid: u32, key: ?i64 };
        const PrimaryKeyInput = struct {
            // One small additional buffer per portal. Larger templates keep
            // the existing rendered-SQL execution path.
            sql: [primary_key_sql_capacity]u8 = undefined,
            len: usize,
            oid: u32,
            key: ?i64,

            fn proposal(self: *const PrimaryKeyInput) DetachedPrimaryKey {
                return .{ .source = self.sql[0..self.len], .oid = self.oid, .key = self.key };
            }
        };
        const Portal = struct {
            primary_key: if (has_primary_key) ?PrimaryKeyInput else void = if (has_primary_key) null else {},
            live: bool = false,
            name: Name = .{},
            sql: [sql_capacity]u8 = @splat(0),
            len: usize = 0,
            formats: [result_format_capacity]u16 = @splat(0),
            format_count: usize = 0,
            row: usize = 0,
            complete: bool = false,
            result_rows: usize = 0,
            affected: usize = 0,
            rolled_back: bool = false,
            command: []const u8 = "",
            /// Savepoint depth when bound: ROLLBACK TO closes newer portals.
            level: usize = 0,
            fn source(self: *const Portal) []const u8 {
                return self.sql[0..self.len];
            }
            fn format(self: *const Portal, c: usize) u16 {
                return if (self.format_count == 0) 0 else self.formats[if (self.format_count == 1) 0 else c];
            }
        };
        const AdmissionState = struct {
            payload: if (detects_admission) [routed_startup_capacity]u8 else void = undefined,
            external: if (external_admission) ?AdmissionHook else void = if (external_admission) null else {},
            len: usize = 0,
            rejected: bool = false,
        };

        pub const AdmissionHook = struct {
            context: *anyopaque,
            scratch: []u8,
            admit: *const fn (*anyopaque, *DB, StartupAdmission) anyerror!void,
            /// Optional cluster utility dispatch for one simple-query frame.
            /// The returned slice is a static PostgreSQL command tag.
            utility: ?*const fn (*anyopaque, *DB, []const u8) anyerror!?[]const u8 = null,
        };

        pub fn configureStartupAdmission(self: *Self, hook: AdmissionHook) !void {
            if (comptime !external_admission) return error.UnsupportedStatement else {
                if (self.startup or self.admission.rejected or self.admission.external != null) return error.ProtocolViolation;
                if (hook.scratch.len < routed_startup_capacity) return error.BufferTooSmall;
                self.admission.external = hook;
            }
        }

        fn routing(self: *const Self) bool {
            if (comptime detects_admission) return true;
            if (comptime external_admission) return self.admission.external != null;
            return false;
        }

        fn startupScratch(self: *Self) []u8 {
            if (comptime external_admission) if (self.admission.external) |hook| return hook.scratch;
            if (comptime detects_admission) return &self.admission.payload;
            return &.{};
        }

        startup: bool = false,
        failed: bool = false,
        waiting_for_command: bool = false,
        oversize_remaining: usize = 0,
        oversize_tag: u8 = 0,
        authentication: ?scram.Server = null,
        role_authentication: bool = false,
        role_credentials: ?*const scram.Credentials = null,
        admission: if (has_admission) AdmissionState else void = if (has_admission) .{} else {},
        statements: [statement_capacity]Statement = @splat(.{}),
        portals: [portal_capacity]Portal = @splat(.{}),
        result: DB.Result = .{},
        active_portal: ?usize = null,
        commit_rolled_back: bool = false,
        backend_pid: u32 = 1,
        backend_secret: u32 = 0,
        copy: CopyState = .{},
        simple_batch: SimpleBatch = .{},

        /// Copy a verifier and a fresh CSPRNG nonce before any startup bytes.
        /// Every accepted connection needs its own unpredictable nonce; the
        /// protocol layer intentionally owns no RNG or transport configuration.
        pub fn configureAuthentication(self: *Self, verifier: *const scram.Verifier, server_nonce: []const u8) scram.Error!void {
            if (self.startup or self.authentication != null) return error.AuthenticationState;
            if (comptime has_admission) if (self.admission.rejected) return error.AuthenticationState;
            self.authentication = try scram.Server.init(verifier, server_nonce);
        }

        /// The transport calls this after verified TLS and before StartupMessage.
        pub fn configureChannelBinding(self: *Self, digest: []const u8, require: bool) scram.Error!void {
            if (self.startup) return error.AuthenticationState;
            if (self.authentication) |*auth| return auth.configureEndpoint(digest, require);
            return error.AuthenticationState;
        }

        /// Authenticate using a verifier and require its exact username to
        /// resolve to a SQL login role. Callers opt in before startup. The
        /// default SCRAM configuration retains the embedding's session role.
        pub fn configureRoleAuthentication(self: *Self, verifier: *const scram.Verifier, server_nonce: []const u8) scram.Error!void {
            if (comptime !has_admission and !@hasDecl(DB, "bindAuthenticatedRole")) return error.AuthenticationFailed;
            try self.configureAuthentication(verifier, server_nonce);
            self.role_authentication = true;
        }

        /// Borrow a validated credential set until StartupMessage is read.
        /// As with single-verifier authentication, the application supplies a
        /// fresh CSPRNG nonce. Configuration errors close the connection.
        pub fn configureRoleCredentials(self: *Self, credentials: *const scram.Credentials, server_nonce: []const u8) scram.Error!void {
            if (self.startup or self.authentication != null) return error.AuthenticationState;
            self.authentication = .{ .state = .failed };
            if (comptime !@hasDecl(DB, "bindAuthenticatedRole")) return error.AuthenticationFailed;
            if (credentials.verifiers.len == 0) return error.InvalidVerifier;
            self.authentication = try scram.Server.initUnselected(server_nonce);
            self.role_credentials = credentials;
            self.role_authentication = true;
        }

        /// An output of this size is sufficient before any SQL mutation occurs.
        pub fn responseCapacity() usize {
            if (@hasDecl(DB.Result, "storageBytesFor")) return responseCapacityFor(DB.Result.default_row_capacity) catch unreachable;
            return @sizeOf(DB.Result) * 2 + 4096;
        }

        pub fn responseCapacityFor(row_capacity: usize) error{BufferTooSmall}!usize {
            const bytes = if (@hasDecl(DB.Result, "storageBytesFor")) DB.Result.storageBytesFor(row_capacity) catch return error.BufferTooSmall else @sizeOf(DB.Result);
            const multiplied = @mulWithOverflow(bytes, 2);
            const total = @addWithOverflow(multiplied[0], 4096);
            if (multiplied[1] != 0 or total[1] != 0) return error.BufferTooSmall;
            return total[0];
        }

        pub fn requiredCapacity(self: *const Self) error{BufferTooSmall}!usize {
            return responseCapacityFor(self.result.rows.len);
        }

        /// A ReadyForQuery boundary in an open block can arm the reactor's
        /// monotonic idle timer. A partial command leaves the state intact.
        pub fn idleTransactionTimeout(self: *const Self, db: *const DB) u32 {
            if (comptime @hasDecl(DB, "idleTransactionTimeout")) {
                if (self.waiting_for_command) return db.idleTransactionTimeout();
            }
            return 0;
        }

        pub fn waitingForCopyInput(self: *const Self) bool {
            return self.copy.mode == .in;
        }

        pub fn continuingSimpleQuery(self: *const Self) bool {
            return self.simple_batch.source_length != 0;
        }

        /// A completed COPY can leave SQL work runnable without socket input.
        pub fn queuedSimpleQuery(self: *const Self) bool {
            return self.simple_batch.owned and self.copy.mode == .none;
        }

        pub const DetachedCandidate=union(enum) {metadata,describe:[]const u8,execute:[]const u8};
        /// A scheduling proposal, never authorization to execute arbitrary SQL
        /// under a read lock. The caller must bind execute/describe sources in
        /// an independent read-only context and reject unsupported plans first.
        /// Session ownership, database immutability, private Describe support,
        /// idle autocommit state and output capacity remain caller obligations.
        fn detachedReady(self: *const Self) bool {
            return self.startup and !self.failed and !self.continuingSimpleQuery() and self.copy.mode==.none and self.active_portal==null and
                self.oversize_remaining==0 and (self.authentication==null or self.authentication.?.state==.complete);
        }
        pub fn detachedCandidate(self:*Self,input:[]const u8) ?DetachedCandidate {
            if(!self.detachedReady()) return null;
            return self.detachedFrame(input) catch null;
        }

        pub const DetachedKeyExchange = struct {
            key: DetachedPrimaryKey,
            formats: []const u8,
            consumed: usize,
        };

        /// Recognize a complete unnamed Bind, unlimited Execute, and Sync.
        /// Borrow the statement and frame until the caller consumes the input.
        /// A miss leaves the ordinary decoder in charge of all three frames.
        pub fn detachedKeyExchange(self: *Self, input: []const u8) ?DetachedKeyExchange {
            if (comptime !has_cached_primary_key) return null;
            if (!self.waiting_for_command or !self.detachedReady() or input.len < 5 or input[0] != 'B') return null;
            if (comptime has_admission) if (self.admission.rejected) return null;
            const size = read32(input[1..5]);
            if (size < 4 or size > max_packet) return null;
            const end = @as(usize, size) + 1;
            const execute_sync = "E\x00\x00\x00\x09\x00\x00\x00\x00\x00S\x00\x00\x00\x04";
            if (end + execute_sync.len > input.len or !equal(input[end..][0..execute_sync.len], execute_sync)) return null;
            return self.detachedBind(input[5..end], end + execute_sync.len) catch null;
        }

        fn detachedBind(self: *Self, body: []const u8, consumed: usize) !?DetachedKeyExchange {
            var r: Reader = .{ .bytes = body };
            if (try r.byte() != 0) return null;
            const stmt = try self.statement(try r.string());
            if (stmt.count != 1 or stmt.single_parameter == null or stmt.len > primary_key_sql_capacity or !integralParameter(stmt.oids[0])) return null;
            const format_count = try r.u16be();
            if (format_count > 1) return null;
            const format = if (format_count == 0) 0 else try r.u16be();
            if (format > 1 or try r.u16be() != 1) return null;
            const length = try r.u32be();
            var key: ?i64 = null;
            if (length != 0xffffffff) {
                const bytes = try r.take(length);
                if (format == 0 and (bytes.len > 20 or !integerText(bytes))) return null;
                key = primaryKeyNumber(bytes, stmt.oids[0], format) orelse return null;
            }
            const result_count = try r.u16be();
            if (result_count > result_format_capacity) return null;
            const formats = try r.take(@as(usize, result_count) * 2);
            try r.done();
            var index: usize = 0;
            while (index < formats.len) : (index += 2) if (formats[index] != 0 or formats[index + 1] > 1) return null;
            for (&self.portals) |*portal_value| {
                if (!portal_value.live or portal_value.name.len == 0) return .{
                    .key = .{ .source = stmt.source(), .oid = stmt.oids[0], .key = key },
                    .formats = formats,
                    .consumed = consumed,
                };
            }
            return null;
        }

        /// Execute the recognized exchange under the caller's detached-read
        /// ownership. The DB must leave its result untouched on a cache miss.
        pub fn handleDetachedKeyExchange(self: *Self, db: *DB, exchange: DetachedKeyExchange, output: []u8) error{BufferTooSmall}!?Reply {
            if (comptime !has_cached_primary_key) return null;
            if (output.len < try self.requiredCapacity()) return error.BufferTooSmall;
            var w: Writer = .{ .bytes = output };
            var execution_error: ?anyerror = null;
            const view: ?KeyView = if (comptime KeyView == void) null else
                db.viewCachedDetachedPrimaryKey(exchange.key.source, exchange.key.oid, exchange.key.key, output) catch |err| failed: {
                    execution_error = err;
                    break :failed null;
                };
            const found = view != null or execution_error != null or (db.executeCachedDetachedPrimaryKey(exchange.key.source, exchange.key.oid, exchange.key.key, &self.result) catch |err| failed: {
                execution_error = err;
                break :failed true;
            });
            if (!found) return null;
            try w.empty('2');
            const bind_end = w.at;
            const columns = if (comptime KeyView == void) self.result.column_count else
                if (view) |projection| projection.columns.len else self.result.column_count;
            if (execution_error == null and exchange.formats.len > 2 and exchange.formats.len / 2 != columns)
                execution_error = error.ProtocolViolation;
            try writeNotice(db, &w);
            if (execution_error == null) {
                self.commit_rolled_back = false;
                self.writeKeyResult(db, &w, exchange.formats, view) catch |err| {
                    w.at = bind_end;
                    execution_error = err;
                };
            }
            if (execution_error) |err| {
                try failure(&w, sqlstate(err), diagnosticMessage(err));
                if (@hasDecl(DB, "failTransaction")) db.failTransaction();
            }
            // A detached read cannot open an implicit extended transaction.
            self.closeIdlePortals(db);
            try self.ready(db, &w);
            return .{ .consumed = exchange.consumed, .written = w.at };
        }

        fn writeKeyResult(self: *Self, db: *DB, w: *Writer, formats: []const u8, view: ?KeyView) !void {
            const present = if (comptime KeyView == void) self.result.row_count != 0 else
                if (view) |projection| projection.version != null else self.result.row_count != 0;
            if (comptime KeyView != void) {
                if (view) |projection| {
                    if (present) try self.projectedKeyRow(db, w, formats, projection);
                } else try self.rows(db, w, formats, 0, self.result.row_count);
            } else try self.rows(db, w, formats, 0, self.result.row_count);
            const tag = try w.begin('C');
            try w.append(if (present) "SELECT 1\x00" else "SELECT 0\x00");
            w.end(tag);
        }

        fn projectedKeyRow(self: *Self, db: *DB, w: *Writer, formats: []const u8, view: KeyView) !void {
            const session = valueSession(db);
            const tag = try w.begin('D');
            try w.u16be(@intCast(view.columns.len));
            var scratch: @TypeOf(self.result.rows[0].cells[0]) = undefined;
            for (view.types, 0..) |data_type, index| {
                const format_index = if (formats.len == 2) 1 else index * 2 + 1;
                const binary = formats.len != 0 and formats[format_index] == 1;
                try self.dataCell(w, view.cell(index, &scratch), data_type, session, binary, null);
            }
            w.end(tag);
        }

        /// Additional scheduling hint for unlimited Execute. Portal storage
        /// owns the template through the complete handler call. It does not
        /// authorize execution or replace the rendered-SQL fallback.
        pub fn detachedPrimaryKey(self: *Self, input: []const u8) ?DetachedPrimaryKey {
            if (comptime !has_primary_key) return null;
            if (!self.detachedReady() or input.len < 5 or input[0] != 'E') return null;
            const size = read32(input[1..5]);
            if (size < 4 or size > max_packet or @as(usize,size)+1 > input.len) return null;
            var r: Reader = .{.bytes=input[5..@as(usize,size)+1]};
            const frame = self.executeFrame(&r) catch return null;
            if (frame.limit != 0 or frame.portal.complete) return null;
            if (frame.portal.primary_key) |*key| return key.proposal();
            return null;
        }

        fn executeFrame(self: *Self, r: *Reader) !struct { portal: *Portal, limit: u32 } {
            const name = try r.string();
            const limit = try r.u32be();
            try r.done();
            if (limit > 0x7fffffff) return error.ProtocolViolation;
            return .{ .portal = try self.portal(name), .limit = limit };
        }
        fn detachedFrame(self:*Self,input:[]const u8) !?DetachedCandidate {
            if(input.len<5) return null;
            const size=read32(input[1..5]);
            if(size<4 or size>max_packet or @as(usize,size)+1>input.len) return null;
            var r:Reader=.{.bytes=input[5..@as(usize,size)+1]};
            switch(input[0]) {
                'Q'=>{const source=try r.string();try r.done();return .{.execute=source};},
                // These mutate only per-session protocol state. Parse's type
                // inference calls Describe, which must use the private context.
                'P'=>return if(@hasDecl(DB,"describe")) .metadata else null,
                'B','C'=>return .metadata,
                'H','S'=>{try r.done();return .metadata;},
                'D'=>{
                    const kind=try r.byte();const name=try r.string();try r.done();
                    if(kind=='P') return .{.describe=(try self.portal(name)).source()};
                    if(kind=='S') {
                        const statement_value=try self.statement(name);
                        // Parameterized statement Describe interpolates NULLs;
                        // retain its serialized path instead of a SQL-sized
                        // speculative buffer on every query's stack.
                        if(statement_value.count!=0) return null;
                        return .{.describe=statement_value.source()};
                    }
                    return null;
                },
                'E'=>{
                    const frame=try self.executeFrame(&r);
                    if(frame.limit!=0) return null; // suspended portals retain their owner
                    const portal_value=frame.portal;
                    if(portal_value.complete) return .metadata;
                    if (comptime @hasDecl(DB, "finishExtended")) {
                        // A detached read can finish without opening a store
                        // transaction only once its Sync boundary is known.
                        const following = input[@as(usize, size) + 1..];
                        if (following.len < 5 or following[0] != 'S' or read32(following[1..5]) != 4) return null;
                    }
                    return .{.execute=portal_value.source()};
                },
                else=>return null,
            }
        }

        fn discardOversize(self: *Self, db: *DB, input: []const u8, output: []u8, prefix: usize) error{BufferTooSmall}!Reply {
            const consumed = @min(input.len, self.oversize_remaining);
            self.oversize_remaining -= consumed;
            if (self.oversize_remaining != 0 or self.failed) return .{ .consumed = prefix + consumed };
            var writer: Writer = .{ .bytes = output };
            try failure(&writer, "54000", "SQL message exceeds the configured packet capacity");
            if (@hasDecl(DB, "failTransaction")) db.failTransaction();
            if (self.oversize_tag == 'Q') {
                if (comptime @hasDecl(DB, "abortExtended")) db.abortExtended();
                try self.ready(db, &writer);
            } else self.failed = true;
            return .{ .consumed = prefix + consumed, .written = writer.at };
        }

        pub fn handle(self: *Self, db: *DB, input: []const u8, output: []u8) error{BufferTooSmall}!Reply {
            if (output.len < try self.requiredCapacity()) return error.BufferTooSmall;
            if (self.oversize_remaining != 0) return self.discardOversize(db, input, output, 0);
            if (comptime has_admission) if (self.admission.rejected) return .{ .close = true };
            if (self.authentication) |*auth| if (auth.state == .failed) return .{ .close = true };
            if (has_copy and self.copy.mode != .none) return self.copyHandle(db, input, output);
            if (!self.startup) return self.handleStartup(db, input, output);
            if (self.queuedSimpleQuery()) {
                return self.dispatchFrame(db, 'Q', self.copy.sql[0 .. self.simple_batch.source_length + 1], output, 0);
            }
            const prefix: usize = 1;
            if (input.len < prefix + 4) return .{};
            const size = read32(input[prefix..][0..4]);
            var w: Writer = .{ .bytes = output };
            if (size < 4 or size > max_packet) {
                self.waiting_for_command = false;
                // Drain a bounded oversized SQL frame without retaining it.
                // A valid query that exceeds our budget gets a SQL error and
                // remains synchronized, rather than an unread-body TCP reset.
                if ((self.authentication == null or self.authentication.?.state == .complete) and size > max_packet and size <= 16 * 1024 * 1024 and
                    (input[0] == 'Q' or input[0] == 'P' or input[0] == 'B')) {
                    self.oversize_remaining = size - 4;
                    self.oversize_tag = input[0];
                    return self.discardOversize(db, input[5..], output, 5);
                }
                try failure(&w, "08P01", "invalid packet length");
                return .{ .consumed = @min(input.len, prefix + 4), .written = w.at, .close = true };
            }
            const total: usize = @as(usize, size) + prefix;
            if (input.len < total) return .{};
            return self.dispatchFrame(db, input[0], input[5..total], output, total);
        }

        /// Handle a prepared detached Execute and its immediately buffered Sync
        /// with the caller's existing read ownership. Failed or incomplete
        /// Execute retains the ordinary frame-by-frame recovery path.
        pub fn handleDetachedExecuteSync(self: *Self, db: *DB, input: []const u8, output: []u8) error{BufferTooSmall}!Reply {
            const execute_reply = try self.handle(db, input, output);
            if (input.len == 0 or input[0] != 'E' or execute_reply.consumed == 0 or
                execute_reply.close or execute_reply.blocked or execute_reply.cancel != null or !self.detachedReady()) return execute_reply;
            const next = input[execute_reply.consumed..];
            if (next.len < 5 or next[0] != 'S' or read32(next[1..5]) != 4) return execute_reply;
            // Execute has updated state by this point. If the caller's output
            // cannot hold another handler invocation, keep its completed reply.
            const remaining = output[execute_reply.written..];
            if (remaining.len < try self.requiredCapacity()) return execute_reply;
            const sync = try self.dispatchFrame(db, 'S', next[5..5], remaining, 5);
            return .{
                .consumed = execute_reply.consumed + sync.consumed,
                .written = execute_reply.written + sync.written,
                .close = sync.close,
                .blocked = sync.blocked,
                .cancel = sync.cancel,
            };
        }

        fn dispatchFrame(self: *Self, db: *DB, tag: u8, body: []const u8, output: []u8, total: usize) error{BufferTooSmall}!Reply {
            self.waiting_for_command = false;
            var w: Writer = .{ .bytes = output };
            var close = false;
            if (self.authentication != null and self.authentication.?.state != .complete) {
                close = self.authenticate(db, tag, body, &w) catch blk: {
                    self.authentication.?.state = .failed;
                    w.at = 0;
                    try authenticationFailure(&w);
                    break :blk true;
                };
            } else {
                if (self.failed and tag != 'S' and tag != 'X') return .{ .consumed = total };
                close = self.dispatch(db, tag, body, &w) catch |err| blk: {
                    const any: anyerror = err;
                    // Parked statement: nothing consumed or written.
                    if (any == error.WouldBlock) return .{ .blocked = true };
                    if (any == error.TransactionTimeout) {
                        try self.terminateTransaction(db, &w);
                        return .{ .consumed = total, .written = w.at, .close = true };
                    }
                    w.at = 0;
                    try writeNotice(db, &w);
                    try failure(&w, sqlstate(err), diagnosticMessage(err));
                    if (tag == 'Q') try self.abortSimpleBatch(db);
                    if (@hasDecl(DB, "failTransaction")) db.failTransaction();
                    if (tag == 'Q' or tag == 'S') {
                        if (comptime @hasDecl(DB, "abortExtended")) db.abortExtended();
                        self.failed = false;
                        self.closeIdlePortals(db);
                        try self.ready(db, &w);
                    } else self.failed = true;
                    break :blk false;
                };
            }
            return .{ .consumed = if (self.continuingSimpleQuery() and !self.simple_batch.owned) 0 else total, .written = w.at, .close = close };
        }

        fn handleStartup(self: *Self, db: *DB, input: []const u8, output: []u8) error{BufferTooSmall}!Reply {
            var writer: Writer = .{ .bytes = output };
            const frame = classifyStartup(input);
            switch (frame) {
                .incomplete => return .{},
                .invalid_length => {
                    try failure(&writer, "08P01", "invalid packet length");
                    return .{ .consumed = 4, .written = writer.at, .close = true };
                },
                .protocol_violation, .unsupported_protocol => |size| {
                    const err = if (frame == .protocol_violation) error.ProtocolViolation else error.UnsupportedProtocol;
                    try failure(&writer, sqlstate(err), @errorName(err));
                    return .{ .consumed = size, .written = writer.at, .close = true };
                },
                .ssl_request, .gss_request => {
                    try writer.byte('N');
                    return .{ .consumed = 8, .written = writer.at };
                },
                .cancel => |key| return .{ .consumed = 16, .close = true, .cancel = key },
                .startup => |parameters| {
                    const close = self.handshake(db, parameters, &writer) catch |err| blk: {
                        if (has_admission and self.routing()) self.admission.rejected = true;
                        writer.at = 0;
                        try failure(&writer, sqlstate(err), @errorName(err));
                        break :blk true;
                    };
                    return .{ .consumed = 8 + parameters.len, .written = writer.at, .close = close };
                },
            }
        }
        /// RAMSQL-supplied BackendKeyData (pid, secret) sent after authentication.
        pub fn configureBackendKey(self: *Self, pid: u32, secret: u32) void {
            self.backend_pid = pid;
            self.backend_secret = secret;
        }

        fn handshake(self: *Self, db: *DB, payload: []const u8, w: *Writer) !bool {
            if (has_admission and self.routing()) {
                const startup_request = try inspectRoutedStartup(payload, if (self.authentication == null) .trusted else .scram);
                if (payload.len > routed_startup_capacity) return error.ProtocolViolation;
                if (self.authentication != null) {
                    @memcpy(self.startupScratch()[0..payload.len], payload);
                    self.admission.len = payload.len;
                    try self.offerScram(startup_request.user, w);
                    return false;
                }
                if (!try self.admitStartup(db, startup_request, w)) return true;
                try self.authenticationComplete(db, w);
                return false;
            }

            var r: Reader = .{ .bytes = payload };
            var user: ?[]const u8 = null;
            while (true) {
                const key = try r.string();
                if (key.len == 0) break;
                const value = try r.string();
                if (equal(key, "user")) {
                    if (user != null) return error.ProtocolViolation;
                    user = value;
                }
                if (equal(key, "client_encoding") and !equal(value, "UTF8") and !equal(value, "UTF-8")) return error.UnsupportedEncoding;
                if (@hasDecl(DB, "startupParameter")) try db.startupParameter(key, value);
            }
            try r.done();
            if (user == null or user.?.len == 0) return error.UserRequired;
            if (self.authentication != null) {
                try self.offerScram(user.?, w);
            } else try self.authenticationComplete(db, w);
            return false;
        }

        fn offerScram(self: *Self, user: []const u8, w: *Writer) !void {
            const auth = &self.authentication.?;
            if (self.role_credentials) |credentials| {
                try auth.selectCredentials(credentials, user);
                self.role_credentials = null;
            } else auth.setUsername(user);
            const p = try w.begin('R');
            try w.u32be(10);
            if (auth.offersEndpoint()) try w.string(scram.mechanism_plus);
            if (auth.offersUnbound()) try w.string(scram.mechanism);
            try w.byte(0);
            w.end(p);
            self.startup = true;
        }

        fn admitStartup(self: *Self, db: *DB, startup_request: StartupAdmission, w: *Writer) !bool {
            self.invokeAdmission(db, startup_request) catch |err| {
                self.admission.rejected = true;
                if (self.authentication) |*auth| auth.state = .failed;
                try fatal(w, sqlstate(err), @errorName(err));
                return false;
            };
            return true;
        }

        fn invokeAdmission(self: *Self, db: *DB, request: StartupAdmission) !void {
            if (comptime external_admission) if (self.admission.external) |hook| return hook.admit(hook.context, db, request);
            if (comptime detects_admission) return db.admitPostgresStartup(request);
            return error.AdmissionDenied;
        }

        fn clusterCommand(self: *Self, db: *DB, source: []const u8) !?[]const u8 {
            if (comptime external_admission) {
                if (self.admission.external) |hook| if (hook.utility) |utility| return utility(hook.context, db, source);
            }
            return null;
        }

        fn authenticate(self: *Self, db: *DB, tag: u8, payload: []const u8, w: *Writer) !bool {
            if (tag != 'p' or payload.len > scram.max_message + 64) return error.AuthenticationFailed;
            const auth = &self.authentication.?;
            var message: [512]u8 = undefined;
            if (auth.state == .initial) {
                var r: Reader = .{ .bytes = payload };
                const name = try r.string();
                const mode: scram.Mode = if (equal(name, scram.mechanism_plus) and auth.offersEndpoint())
                    .endpoint
                else if (equal(name, scram.mechanism) and auth.offersUnbound())
                    .unbound
                else
                    return error.AuthenticationFailed;
                const length = try r.u32be();
                if (length > scram.max_message) return error.AuthenticationFailed;
                const first = try r.take(length);
                try r.done();
                const challenge = try auth.startNegotiated(mode, first, &message);
                const p = try w.begin('R');
                try w.u32be(11);
                try w.append(challenge);
                w.end(p);
            } else if (auth.state == .challenge) {
                const final = try auth.finish(payload, &message);
                if (has_admission and self.routing()) {
                    const startup_request = try inspectRoutedStartup(self.startupScratch()[0..self.admission.len], .scram);
                    self.admission.len = 0;
                    if (!try self.admitStartup(db, startup_request, w)) return true;
                } else if (self.role_authentication) {
                    if (comptime @hasDecl(DB, "bindAuthenticatedRole")) {
                        try db.bindAuthenticatedRole(auth.verifier.identity());
                    } else return error.AuthenticationFailed;
                }
                const p = try w.begin('R');
                try w.u32be(12);
                try w.append(final);
                w.end(p);
                try self.authenticationComplete(db, w);
            } else return error.AuthenticationFailed;
            return false;
        }
        fn authenticationComplete(self: *Self, db: *DB, w: *Writer) !void {
            const auth = try w.begin('R');
            try w.u32be(0);
            w.end(auth);
            if (@hasDecl(DB, "takeParameterChanges")) {
                // Every reported setting at startup (design §4.7).
                try reportParameters(db, w, db.takeParameterChanges());
            } else {
                try parameter(w, "server_version", "16.0");
                try parameter(w, "server_encoding", "UTF8");
                try parameter(w, "client_encoding", "UTF8");
                try parameter(w, "DateStyle", "ISO, MDY");
                try parameter(w, "TimeZone", "UTC");
                try parameter(w, "integer_datetimes", "on");
                try parameter(w, "standard_conforming_strings", "on");
            }
            const key = try w.begin('K');
            try w.u32be(self.backend_pid);
            try w.u32be(self.backend_secret);
            w.end(key);
            const ready_at = try w.begin('Z');
            try w.byte('I');
            w.end(ready_at);
            self.startup = true;
        }
        fn reportParameters(db: *DB, w: *Writer, mask: u16) !void {
            if (!@hasDecl(DB, "takeParameterChanges")) return;
            const names = DB.reportedParameters();
            for (names, 0..) |name, index| {
                if (mask & (@as(u16, 1) << @intCast(index)) == 0) continue;
                var buffer: [64]u8 = undefined;
                try parameter(w, name, db.parameterValue(index, &buffer));
            }
        }
        fn ready(self: *Self, db: *DB, w: *Writer) !void {
            // Committed notifications for this session (between transactions,
            // as PostgreSQL's ProcessCompletedNotifies), then changed reported
            // settings, before ReadyForQuery.
            try writeNotifications(db, w);
            if (@hasDecl(DB, "takeParameterChanges")) try reportParameters(db, w, db.takeParameterChanges());
            const p = try w.begin('Z');
            try w.byte(if (@hasDecl(DB, "transactionStatus")) db.transactionStatus() else 'I');
            w.end(p);
            self.waiting_for_command = true;
        }
        /// NotificationResponse ('A'): sender pid, channel, payload.
        fn writeNotifications(db: *DB, w: *Writer) !void {
            if (!@hasDecl(DB, "takeNotification")) return;
            var note: DB.Notification = undefined;
            while (db.takeNotification(&note)) {
                const p = try w.begin('A');
                try w.u32be(note.pid);
                try w.string(note.channel.slice());
                try w.string(note.payloadSlice());
                w.end(p);
            }
        }

        fn writeNotice(db: *DB, w: *Writer) !void {
            if (comptime @hasDecl(DB, "takeNotice")) {
                if (db.takeNotice()) |notice| {
                    try diagnostic(w, 'N', notice.level.label(), notice.state, notice.message);
                }
            }
        }

        /// Notifications committed while the client is idle (PostgreSQL
        /// sends them asynchronously): call when the connection has no
        /// pending input. Returns the bytes written.
        pub fn notifications(self: *Self, db: *DB, output: []u8) error{BufferTooSmall}!usize {
            if (!self.startup or self.copy.mode != .none) return 0;
            if (@hasDecl(DB, "transactionStatus")) if (db.transactionStatus() != 'I') return 0;
            var w: Writer = .{ .bytes = output };
            writeNotifications(db, &w) catch return error.BufferTooSmall;
            return w.at;
        }

        fn beginSimpleFrame(self: *Self, source: []const u8) !void {
            if (self.active_portal != null and !word(source, "commit") and !word(source, "rollback") and !word(source, "end") and !word(source, "abort")) return error.PortalBusy;
            self.active_portal = null;
            for (&self.statements) |*s| if (s.name.len == 0) {
                s.live = false;
            };
            for (&self.portals) |*p| if (p.name.len == 0) {
                p.live = false;
            };
        }

        fn abortSimpleBatch(self: *Self, db: *DB) error{BufferTooSmall}!void {
            if (comptime has_simple_batch) {
                if (!self.continuingSimpleQuery()) return;
                self.simple_batch = .{};
                db.finishSimpleQueryBatch(false) catch return error.BufferTooSmall;
            }
        }

        fn beginSimpleBatch(self: *Self, db: *DB, source: []const u8) !void {
            const count = try db.preflightSimpleQueryBatch(source);
            try db.beginSimpleQueryBatch();
            self.simple_batch = .{ .remaining = count, .source_length = source.len };
        }

        fn simpleResult(self: *Self, db: *DB, w: *Writer) !void {
            try writeNotice(db, w);
            if (self.result.column_count == 0) return;
            try self.description(w, null);
            try self.rows(db, w, @as([]const u16, &.{}), 0, self.result.row_count);
        }

        /// Produce one complete command's responses using the same result and
        /// output capacities as a single query. Advance only after execution;
        /// parked statements are redelivered without rerunning prior commands.
        fn simpleBatchStep(self: *Self, db: *DB, source: []const u8, w: *Writer) !void {
            if (source.len != self.simple_batch.source_length) return error.ProtocolViolation;
            var boundaries: sql.PostgresStatements = .{ .source = source, .position = self.simple_batch.position };
            const span = (try boundaries.next()) orelse return error.ProtocolViolation;
            const command_source = span.slice(source);
            try db.beginSimpleQueryStep();
            try DB.checkSimpleQueryUtility(command_source);
            const copying = has_copy and word(command_source, "copy");
            if (copying) {
                try self.startCopy(db, command_source, w, null, .{ .source = source, .command_start = span.start });
            } else {
                try self.execute(db, command_source);
                try self.simpleResult(db, w);
            }
            self.simple_batch.position = boundaries.position;
            self.simple_batch.remaining -= 1;
            if (self.copy.mode == .in) return;
            const final = self.simple_batch.remaining == 0;
            if (final) try db.finishSimpleQueryBatch(true);
            if (!copying) try self.command(w, command_source);
            if (final) {
                self.simple_batch = .{};
                self.closeIdlePortals(db);
                try self.ready(db, w);
            }
        }

        fn dispatch(self: *Self, db: *DB, tag: u8, body: []const u8, w: *Writer) !bool {
            var r: Reader = .{ .bytes = body };
            switch (tag) {
                'Q' => {
                    var source = try r.string();
                    try r.done();
                    if (comptime has_simple_batch) if (self.continuingSimpleQuery()) {
                        try self.simpleBatchStep(db, source, w);
                        return false;
                    };
                    try self.beginSimpleFrame(source);
                    if (comptime has_simple_batch) if (db.simpleQueryBatchAvailable() and needsQueryScan(source)) {
                        var boundaries: sql.PostgresStatements = .{ .source = source };
                        if (try boundaries.next()) |first| {
                            if (try boundaries.next() != null) {
                                try self.beginSimpleBatch(db, source);
                                try self.simpleBatchStep(db, source, w);
                                return false;
                            }
                            source = first.slice(source);
                        } else source = "";
                    };
                    if (trim(source).len == 0) try w.empty('I') else if (has_copy and word(source, "copy")) {
                        try self.startCopy(db, source, w, null, null);
                        // COPY FROM: ReadyForQuery follows CopyDone/CopyFail.
                        if (self.copy.mode == .in) return false;
                    } else if (try self.clusterCommand(db, source)) |command_tag| {
                        const completion = try w.begin('C');
                        try w.string(command_tag);
                        w.end(completion);
                    } else {
                        try self.execute(db, source);
                        try self.simpleResult(db, w);
                        try self.command(w, source);
                    }
                    try self.ready(db, w);
                },
                'P' => try self.parse(db, &r, w),
                'B' => try self.bind(db, &r, w),
                'D' => {
                    const kind = try r.byte();
                    const name = try r.string();
                    try r.done();
                    if (self.active_portal != null) return error.PortalBusy;
                    if (kind == 'S') {
                        const s = try self.statement(name);
                        const p = try w.begin('t');
                        try w.u16be(@intCast(s.count));
                        for (s.oids[0..s.count]) |oid| try w.u32be(if (oid == 0) 25 else oid);
                        w.end(p);
                        var query: [sql_capacity]u8 = undefined;
                        var q: Writer = .{ .bytes = &query };
                        var nulls: [parameter_capacity][]const u8 = @splat("NULL");
                        try interpolate(s.source(), nulls[0..s.count], &q);
                        if (@hasDecl(DB, "describe")) {
                            // Parse and bind only: never executes or locks.
                            try self.describeOnly(db, q.bytes[0..q.at]);
                            if (self.result.column_count != 0) try self.description(w, null) else try w.empty('n');
                        } else if (word(q.bytes[0..q.at], "select")) {
                            try self.execute(db, q.bytes[0..q.at]);
                            try self.description(w, null);
                        } else try w.empty('n');
                    } else if (kind == 'P') {
                        const p = try self.portal(name);
                        if (@hasDecl(DB, "describe")) {
                            try self.describeOnly(db, p.source());
                            if (self.result.column_count != 0) try self.description(w, p) else try w.empty('n');
                        } else if (word(p.source(), "select")) {
                            try self.execute(db, p.source());
                            try self.description(w, p);
                        } else try w.empty('n');
                    } else return error.ProtocolViolation;
                },
                'E' => {
                    const frame = try self.executeFrame(&r);
                    const limit = frame.limit;
                    const p = frame.portal;

                    const index = (@intFromPtr(p) - @intFromPtr(&self.portals[0])) / @sizeOf(Portal);
                    if (self.active_portal) |active| {
                        if (active != index) return error.PortalBusy;
                    }
                    if (p.complete) {
                        if (equal(p.command, "COPY")) {
                            try copyCommand(w, p.affected);
                        } else try commandFor(w, p.source(), p.command, p.result_rows, p.affected, p.rolled_back);
                        return false;
                    }
                    if (comptime has_copy and @hasDecl(DB, "beginExtendedGroup")) if (word(p.source(), "copy")) {
                        try db.beginExtendedGroup();
                        try self.startCopy(db, p.source(), w, index, null);
                        return false;
                    };
                    if (self.active_portal == null) {
                        try self.executePortal(db, p, limit);
                        try writeNotice(db, w);
                        self.active_portal = index;
                        p.row = 0;
                        p.result_rows = self.result.row_count;
                        p.affected = self.result.affected_rows;
                        p.rolled_back = self.commit_rolled_back;
                        p.command = self.completed();
                    }
                    if (p.format_count > 1 and p.format_count != self.result.column_count) return error.ProtocolViolation;
                    const end = if (limit == 0) self.result.row_count else @min(self.result.row_count, p.row + limit);
                    try self.rows(db, w, @as([]const u16, p.formats[0..p.format_count]), p.row, end);
                    p.row = end;
                    if (end < self.result.row_count) try w.empty('s') else {
                        try self.command(w, p.source());
                        p.complete = true;
                        self.active_portal = null;
                    }
                },
                'C' => {
                    const kind = try r.byte();
                    const name = try r.string();
                    try r.done();
                    if (kind == 'S') {
                        const s = try self.statement(name);
                        s.live = false;
                    } else if (kind == 'P') {
                        const p = try self.portal(name);
                        p.live = false;
                        if (self.active_portal) |active| if (p == &self.portals[active]) {
                            self.active_portal = null;
                        };
                    } else return error.ProtocolViolation;
                    try w.empty('3');
                },
                'S' => {
                    try r.done();
                    self.failed = false;
                    if (comptime @hasDecl(DB, "finishExtended")) db.finishExtended() catch |err| {
                        if (@as(anyerror, err) == error.TransactionTimeout) return err;
                        try failure(w, sqlstate(err), @errorName(err));
                    };
                    self.closeIdlePortals(db);
                    try self.ready(db, w);
                },
                'H' => {
                    try r.done();
                },
                'X' => {
                    try r.done();
                    return true;
                },
                else => return error.UnsupportedMessage,
            }
            return false;
        }
        fn closeIdlePortals(self: *Self, db: *DB) void {
            if (!@hasDecl(DB, "transactionStatus") or db.transactionStatus() == 'I') {
                for (&self.portals) |*p| p.live = false;
                self.active_portal = null;
            }
        }

        fn executePortal(self: *Self, db: *DB, portal_value: *const Portal, limit: u32) !void {
            if (comptime has_primary_key) if (limit == 0) {
                if (portal_value.primary_key) |*key| {
                    if (try db.executeDetachedPrimaryKey(key.proposal().source, key.oid, key.key, portal_value.source(), &self.result)) {
                        self.commit_rolled_back = false;
                        return;
                    }
                }
            };
            return self.executeMode(db, portal_value.source(), true);
        }

        fn execute(self: *Self, db: *DB, source: []const u8) !void {
            return self.executeMode(db, source, false);
        }

        fn executeMode(self: *Self, db: *DB, source: []const u8, extended: bool) !void {
            self.result.column_count = 0;
            self.result.row_count = 0;
            self.result.affected_rows = 0;
            if (@hasField(DB.Result, "command")) self.result.command = .none;
            self.commit_rolled_back = false;
            if (@hasDecl(DB, "setBackendPid")) db.setBackendPid(self.backend_pid);
            const command_source = trim(source);
            if (keyword(command_source, "begin") or keyword(command_source, "begin work") or keyword(command_source, "begin transaction") or keyword(command_source, "start transaction")) {
                if (@hasDecl(DB, "transactionStatus") and db.transactionStatus() == 'E') return error.TransactionFailed;
                if (comptime @hasDecl(DB, "sql_transaction_controls") and DB.sql_transaction_controls) {
                    try db.execute(source, &self.result);
                } else if (@hasDecl(DB, "beginTransaction")) try db.beginTransaction() else return error.UnsupportedStatement;
            } else if (keyword(command_source, "commit") or keyword(command_source, "commit work") or keyword(command_source, "commit transaction") or keyword(command_source, "end")) {
                if (@hasDecl(DB, "transactionStatus")) self.commit_rolled_back = db.transactionStatus() == 'E';
                if (comptime @hasDecl(DB, "sql_transaction_controls") and DB.sql_transaction_controls) {
                    try db.execute(source, &self.result);
                } else if (@hasDecl(DB, "commitTransaction")) try db.commitTransaction() else return error.UnsupportedStatement;
            } else if (keyword(command_source, "rollback") or keyword(command_source, "rollback work") or keyword(command_source, "rollback transaction") or keyword(command_source, "abort")) {
                if (comptime @hasDecl(DB, "sql_transaction_controls") and DB.sql_transaction_controls) {
                    try db.execute(source, &self.result);
                } else if (@hasDecl(DB, "rollbackTransaction")) try db.rollbackTransaction() else return error.UnsupportedStatement;
            } else if (word(source, "deallocate")) {
                if (@hasDecl(DB, "transactionStatus") and db.transactionStatus() == 'E') return error.TransactionFailed;
                // Protocol-level statements first; SQL PREPARE names (and
                // DEALLOCATE ALL) belong to the engine too.
                const forward = self.deallocate(source) catch |err| switch (err) {
                    error.StatementNotFound => if (@hasDecl(DB, "takeNotification")) true else return err,
                    else => return err,
                };
                if (forward and @hasDecl(DB, "takeNotification")) try db.execute(source, &self.result);
            } else {
                if (extended and @hasDecl(DB, "executeExtended")) {
                    try db.executeExtended(source, &self.result);
                } else try db.execute(source, &self.result);
                // ROLLBACK TO closes portals created after the savepoint.
                if (@hasDecl(DB, "takeRollbackTo")) if (db.takeRollbackTo()) |depth| {
                    for (&self.portals, 0..) |*p, index| {
                        if (!p.live or p.level <= depth) continue;
                        if (self.active_portal) |active| if (active == index) continue;
                        p.live = false;
                    }
                };
            }
        }
        // ---- COPY ---------------------------------------------------------

        fn copyOptions(self: *const Self) pg_copy.Options {
            return optionsOf(&self.copy.info.options);
        }

        fn optionsOf(options: anytype) pg_copy.Options {
            return .{
                .format = switch (options.format) {
                    .text => .text,
                    .csv => .csv,
                    .binary => .binary,
                },
                .delimiter = options.delimiter,
                .null_string = options.nullString(),
                .quote = options.quote,
                .escape = options.escape,
            };
        }

        fn resolveCopyQuoteColumns(self: *Self, db: *DB, query: []const u8, info: *CopyInfo) !void {
            if (comptime @hasDecl(CopyInfo, "needsQuoteColumns") and @hasDecl(CopyInfo, "resolveQuoteColumns")) {
                if (!info.needsQuoteColumns()) return;
                if (comptime @hasDecl(DB, "describe")) {
                    try db.describe(query, &self.result);
                    try info.resolveQuoteColumns(self.result.column_names[0..self.result.column_count]);
                } else return error.UnsupportedStatement;
            }
        }

        /// COPY TO STDOUT runs its SELECT and streams CopyData; COPY FROM
        /// STDIN opens the store's COPY and sends CopyInResponse.
        fn startCopy(self: *Self, db: *DB, source: []const u8, w: *Writer, portal_index: ?usize, batch: ?SimpleCopySource) !void {
            var select: [sql_capacity + 1024]u8 = undefined;
            var info = try db.copyDescribe(source, &select);
            if (info.direction == .to) {
                const query = select[0..info.select_len];
                try self.resolveCopyQuoteColumns(db, query, &info);
                try self.execute(db, query);
                try self.copyOut(db, &info, w);
                if (portal_index) |index| self.completeCopyPortal(index, self.result.row_count);
                return;
            }
            if (source.len > sql_capacity) return error.StatementCapacity;
            if (batch) |frame| if (frame.source.len >= sql_capacity) return error.StatementCapacity;
            const begun = try db.copyBegin(source);
            self.copy.mode = .in;
            self.copy.portal = portal_index;
            self.copy.remaining = 0;
            self.copy.info = begun;
            if (batch) |frame| {
                if (!self.simple_batch.owned) {
                    @memcpy(self.copy.sql[0..frame.source.len], frame.source);
                    self.copy.sql[frame.source.len] = 0;
                    self.simple_batch.owned = true;
                }
                self.copy.sql_start = frame.command_start;
            } else {
                @memcpy(self.copy.sql[0..source.len], source);
                self.copy.sql_start = 0;
            }
            self.copy.sql_len = source.len;
            self.copy.carry_len = 0;
            self.copy.carry_rows = false;
            self.copy.ended = false;
            self.copy.eol = .unknown;
            self.copy.binary_header = begun.options.format == .binary;
            self.copy.header_pending = begun.options.format != .binary and begun.options.header != .off;
            const binary: u16 = @intFromBool(begun.options.format == .binary);
            const p = try w.begin('G');
            try w.byte(@intCast(binary));
            try w.u16be(@intCast(begun.count));
            for (0..begun.count) |_| try w.u16be(binary);
            w.end(p);
        }

        fn copyOut(self: *Self, db: *DB, info: *const CopyInfo, w: *Writer) !void {
            const options = optionsOf(&info.options);
            const binary = options.format == .binary;
            const count = self.result.column_count;
            const session = valueSession(db);
            const h = try w.begin('H');
            try w.byte(@intFromBool(binary));
            try w.u16be(@intCast(count));
            for (0..count) |_| try w.u16be(@intFromBool(binary));
            w.end(h);
            if (binary) {
                const p = try w.begin('d');
                try w.append(pg_copy.signature);
                try w.u32be(0);
                try w.u32be(0);
                w.end(p);
            } else if (info.options.header != .off) {
                const p = try w.begin('d');
                var sink: pg_copy.Sink = .{ .bytes = w.bytes[w.at..] };
                for (0..count) |field| {
                    if (field != 0) try sink.byte(options.delimiter);
                    const name = self.result.column_names[field].slice();
                    if (options.format == .csv) try pg_copy.appendCsv(&options, name, count == 1, &sink) else try pg_copy.appendText(&options, name, &sink);
                }
                try sink.byte('\n');
                w.at += sink.at;
                w.end(p);
            }
            var text: [DB.Result.ValueIo.format_bytes]u8 = undefined;
            for (self.result.rows[0..self.result.row_count]) |*row| {
                const p = try w.begin('d');
                if (binary) {
                    try w.u16be(@intCast(count));
                    for (0..count) |field| {
                        const cell = &row.cells[field];
                        if (cell.* == .null_value) {
                            try w.u32be(0xffffffff);
                            continue;
                        }
                        const length = w.at;
                        try w.u32be(0);
                        const start = w.at;
                        w.at += T.sendBinary(cell, self.result.column_types[field], session, w.bytes[w.at..]) catch return error.BufferTooSmall;
                        write32(w.bytes[length..][0..4], @intCast(w.at - start));
                    }
                } else {
                    var sink: pg_copy.Sink = .{ .bytes = w.bytes[w.at..] };
                    for (0..count) |field| {
                        if (field != 0) try sink.byte(options.delimiter);
                        const cell = &row.cells[field];
                        if (cell.* == .null_value) {
                            try sink.append(options.null_string);
                            continue;
                        }
                        const nominal = try self.nominalText(field, cell, &text);
                        const length = nominal orelse (T.sendText(cell, session, &text) catch return error.BufferTooSmall);
                        if (options.format == .csv) {
                            const forced = if (comptime @hasDecl(CopyInfo, "forceQuoteColumn")) info.forceQuoteColumn(field) else false;
                            try pg_copy.appendCsvField(&options, text[0..length], count == 1, forced, &sink);
                        } else try pg_copy.appendText(&options, text[0..length], &sink);
                    }
                    try sink.byte('\n');
                    w.at += sink.at;
                }
                w.end(p);
            }
            if (binary) {
                const p = try w.begin('d');
                try w.u16be(0xffff);
                w.end(p);
            }
            try w.empty('c');
            try copyCommand(w, self.result.row_count);
        }

        fn copyCommand(w: *Writer, rows_copied: usize) error{BufferTooSmall}!void {
            const c = try w.begin('C');
            try w.append("COPY ");
            try w.number(@intCast(rows_copied));
            try w.byte(0);
            w.end(c);
        }

        fn completeCopyPortal(self: *Self, index: usize, rows_copied: usize) void {
            const bound = &self.portals[index];
            bound.complete = true;
            bound.command = "COPY";
            bound.affected = rows_copied;
        }

        fn copyHandle(self: *Self, db: *DB, input: []const u8, output: []u8) error{BufferTooSmall}!Reply {
            var w: Writer = .{ .bytes = output };
            if (self.copy.mode == .in) {
                // The parked row first, then rows the session still carries.
                if (db.copyBlocked()) {
                    db.copyResume() catch |err| {
                        if (err == error.WouldBlock) return .{ .blocked = true };
                        const close = try self.copyError(db, &w, err);
                        return .{ .written = w.at, .close = close };
                    };
                }
                if (self.copy.carry_rows) {
                    const fed = self.copyRows(db, self.copy.carry[0..self.copy.carry_len]) catch |err| {
                        const close = try self.copyError(db, &w, err);
                        return .{ .written = w.at, .close = close };
                    };
                    self.shiftCarry(fed.used);
                    if (fed.blocked) return .{ .blocked = true };
                    self.copy.carry_rows = false;
                }
            }
            if (self.copy.remaining != 0) return self.copyBody(db, input, 0, &w);
            if (input.len < 5) return .{};
            const tag = input[0];
            const size = read32(input[1..5]);
            if (size < 4) {
                if (self.copy.mode == .in) db.copyFail();
                self.copy.mode = .none;
                try failure(&w, "08P01", "invalid packet length");
                return .{ .consumed = input.len, .written = w.at, .close = true };
            }
            if (tag == 'd') {
                self.copy.remaining = size - 4;
                if (self.copy.remaining == 0) return .{ .consumed = 5 };
                return self.copyBody(db, input, 5, &w);
            }
            if (size > max_packet) {
                if (self.copy.mode == .in) db.copyFail();
                self.copy.mode = .none;
                try failure(&w, "08P01", "invalid packet length");
                return .{ .consumed = input.len, .written = w.at, .close = true };
            }
            const total: usize = @as(usize, size) + 1;
            if (input.len < total) return .{};
            const discarding = self.copy.mode == .discard;
            if (comptime @hasDecl(DB, "checkTransactionTimeout")) if (!discarding) {
                db.checkTransactionTimeout() catch {
                    try self.terminateTransaction(db, &w);
                    return .{ .consumed = total, .written = w.at, .close = true };
                };
            };
            switch (tag) {
                'c' => {
                    if (discarding) {
                        self.copy.mode = .none;
                        return .{ .consumed = total };
                    }
                    var close = false;
                    self.copyFinish(db, &w) catch |err| {
                        if (err == error.WouldBlock) return .{ .blocked = true };
                        w.at = 0;
                        close = try self.copyError(db, &w, err);
                        self.copy.mode = .none;
                    };
                    self.copy.mode = .none;
                    return .{ .consumed = total, .written = w.at, .close = close };
                },
                'f' => {
                    self.copy.mode = .none;
                    if (discarding) return .{ .consumed = total };
                    db.copyFail();
                    try failure(&w, "57014", "COPY from stdin failed");
                    try self.copyErrorBoundary(db, &w);
                    return .{ .consumed = total, .written = w.at };
                },
                // Flush and Sync are ignored in copy-in mode.
                'H' => return .{ .consumed = total },
                'S' => {
                    if (discarding and self.copy.portal != null) {
                        self.copy.mode = .none;
                        return self.handle(db, input, output);
                    }
                    return .{ .consumed = total };
                },
                else => {
                    if (discarding) {
                        self.copy.mode = .none;
                        return self.handle(db, input, output);
                    }
                    self.copy.mode = .none;
                    db.copyFail();
                    try failure(&w, "08P01", "unexpected message type during COPY from stdin");
                    try self.copyErrorBoundary(db, &w);
                    return .{ .consumed = total, .written = w.at };
                },
            }
        }

        /// Consumes CopyData body bytes at input[offset..] (the header,
        /// if any, is input[0..offset]).
        fn copyBody(self: *Self, db: *DB, input: []const u8, offset: usize, w: *Writer) error{BufferTooSmall}!Reply {
            const n = @min(self.copy.remaining, input.len - offset);
            if (n == 0) return .{ .consumed = offset };
            if (self.copy.mode == .discard) {
                self.copy.remaining -= n;
                return .{ .consumed = offset + n };
            }
            const fed = self.copyFeed(db, input[offset..][0..n]) catch |err| {
                self.copy.remaining -= n;
                const close = try self.copyError(db, w, err);
                return .{ .consumed = offset + n, .written = w.at, .close = close };
            };
            self.copy.remaining -= fed.used;
            return .{ .consumed = offset + fed.used, .blocked = fed.blocked };
        }

        /// A terminal COPY error: roll back, report, then discard the rest
        /// of the copy stream.
        fn copyError(self: *Self, db: *DB, w: *Writer, err: anyerror) error{BufferTooSmall}!bool {
            if (err == error.TransactionTimeout) {
                try self.terminateTransaction(db, w);
                return true;
            }
            db.copyFail();
            try failure(w, sqlstate(err), @errorName(err));
            try self.copyErrorBoundary(db, w);
            self.copy.mode = .discard;
            self.copy.carry_len = 0;
            self.copy.carry_rows = false;
            return false;
        }

        fn terminateTransaction(self: *Self, db: *DB, w: *Writer) error{BufferTooSmall}!void {
            self.copy.mode = .none;
            self.simple_batch = .{};
            self.waiting_for_command = false;
            if (comptime @hasDecl(DB, "terminateTimedOut")) db.terminateTimedOut();
            w.at = 0;
            try transactionTimeoutFatal(w);
        }

        fn copyErrorBoundary(self: *Self, db: *DB, w: *Writer) error{BufferTooSmall}!void {
            if (self.copy.portal != null) {
                self.failed = true;
            } else {
                try self.abortSimpleBatch(db);
                if (comptime @hasDecl(DB, "abortExtended")) db.abortExtended();
                self.closeIdlePortals(db);
                try self.ready(db, w);
            }
        }

        fn shiftCarry(self: *Self, used: usize) void {
            const rest = self.copy.carry_len - used;
            for (0..rest) |index| self.copy.carry[index] = self.copy.carry[used + index];
            self.copy.carry_len = rest;
        }

        fn copyFeed(self: *Self, db: *DB, chunk: []const u8) !Fed {
            var rest = chunk;
            var used: usize = 0;
            while (rest.len != 0) {
                if (self.copy.ended) {
                    used += rest.len;
                    break;
                }
                if (self.copy.carry_len == 0) {
                    const fed = try self.copyRows(db, rest);
                    used += fed.used;
                    rest = rest[fed.used..];
                    if (fed.blocked) return .{ .used = used, .blocked = true };
                    if (rest.len == 0 or self.copy.ended) continue;
                    if (rest.len > self.copy.carry.len) return error.TextCapacity;
                    @memcpy(self.copy.carry[0..rest.len], rest);
                    self.copy.carry_len = rest.len;
                    used += rest.len;
                    break;
                }
                const n = @min(rest.len, self.copy.carry.len - self.copy.carry_len);
                @memcpy(self.copy.carry[self.copy.carry_len..][0..n], rest[0..n]);
                self.copy.carry_len += n;
                used += n;
                rest = rest[n..];
                const fed = try self.copyRows(db, self.copy.carry[0..self.copy.carry_len]);
                self.shiftCarry(fed.used);
                if (fed.blocked) {
                    self.copy.carry_rows = self.copy.carry_len != 0;
                    return .{ .used = used, .blocked = true };
                }
                if (fed.used == 0 and self.copy.carry_len == self.copy.carry.len) return error.TextCapacity;
            }
            return .{ .used = used };
        }

        fn rowLength(self: *const Self, bytes: []const u8) !?usize {
            const options = self.copyOptions();
            if (options.format == .binary) {
                if (self.copy.binary_header) return pg_copy.binaryHeader(bytes);
                return pg_copy.tupleEnd(bytes, self.copy.info.count);
            }
            return pg_copy.lineEnd(&options, bytes);
        }

        /// Complete rows at the start of `bytes`; stops at an incomplete
        /// one, the end marker or a parked row (included in `used`).
        fn copyRows(self: *Self, db: *DB, bytes: []const u8) !Fed {
            var at: usize = 0;
            while (at < bytes.len and !self.copy.ended) {
                const length = (try self.rowLength(bytes[at..])) orelse break;
                if (length > line_bytes) return error.TextCapacity;
                const blocked = try self.copyLine(db, bytes[at..][0..length], true);
                at += length;
                if (blocked) return .{ .used = at, .blocked = true };
            }
            return .{ .used = at };
        }

        /// One row (or the binary header / a header line). Returns true when
        /// the row is parked on a key wait.
        fn copyLine(self: *Self, db: *DB, row: []const u8, terminated: bool) !bool {
            const options = self.copyOptions();
            const info = &self.copy.info;
            var fields: [field_capacity]?[]const u8 = undefined;
            if (options.format == .binary) {
                if (self.copy.binary_header) {
                    self.copy.binary_header = false;
                    return false;
                }
                if (row.len == 2 and row[0] == 0xff and row[1] == 0xff) {
                    self.copy.ended = true;
                    return false;
                }
                const count = pg_copy.tupleFields(row, &fields);
                var used: usize = 0;
                for (fields[0..count], 0..) |*field, index| if (field.*) |bytes| {
                    const out = self.copy.scratch[used..];
                    const text = T.receiveText(bytes, info.types[index], out) catch |err| return if (err == error.BufferTooSmall) error.TextCapacity else error.InvalidBinaryRepresentation;
                    if (text.len != 0 and @intFromPtr(text.ptr) == @intFromPtr(out.ptr)) used += text.len;
                    field.* = text;
                };
                return self.copyInsert(db, fields[0..count]);
            }
            const line = try pg_copy.stripLine(row, &self.copy.eol, terminated);
            if (options.format == .text and equal(line, "\\.")) {
                self.copy.ended = true;
                return false;
            }
            // HEADER skips the first line; HEADER MATCH checks its names.
            if (self.copy.header_pending and info.options.header == .on) {
                self.copy.header_pending = false;
                return false;
            }
            const capacity = @max(info.count, 1);
            const count = if (options.format == .csv)
                try pg_copy.csvFields(&options, line, &self.copy.scratch, fields[0..capacity])
            else
                try pg_copy.textFields(&options, line, &self.copy.scratch, fields[0..capacity]);
            if (count != info.count) return error.BadCopyFormat;
            if (self.copy.header_pending) {
                self.copy.header_pending = false;
                for (fields[0..count], 0..) |field, index| {
                    const value = field orelse return error.BadCopyFormat;
                    if (!equal(value, info.names[index].slice())) return error.BadCopyFormat;
                }
                return false;
            }
            return self.copyInsert(db, fields[0..count]);
        }

        fn copyInsert(self: *Self, db: *DB, fields: []const ?[]const u8) !bool {
            db.copyRow(self.copy.sql[self.copy.sql_start..][0..self.copy.sql_len], fields) catch |err| {
                if (err == error.WouldBlock) return true;
                return err;
            };
            return false;
        }

        /// CopyDone: the final unterminated row, then COPY n and ReadyForQuery.
        fn copyFinish(self: *Self, db: *DB, w: *Writer) !void {
            if (!self.copy.ended and self.copy.carry_len != 0) {
                const options = self.copyOptions();
                const length = self.copy.carry_len;
                // Owned by this call either way (a parked row is the store's).
                self.copy.carry_len = 0;
                self.copy.carry_rows = false;
                // A partial binary tuple; an open CSV quote fails in csvFields.
                if (options.format == .binary) return error.BadCopyFormat;
                if (try self.copyLine(db, self.copy.carry[0..length], false)) return error.WouldBlock;
            }
            if (self.copy.binary_header) return error.BadCopyFormat;
            const copied = try db.copyEnd();
            if (comptime has_simple_batch) {
                if (self.continuingSimpleQuery() and self.simple_batch.remaining == 0) {
                    try db.finishSimpleQueryBatch(true);
                    self.simple_batch = .{};
                    self.closeIdlePortals(db);
                }
            }
            try copyCommand(w, copied);
            if (self.copy.portal) |index| {
                self.completeCopyPortal(index, copied);
            } else if (!self.continuingSimpleQuery()) try self.ready(db, w);
        }


        fn describeOnly(self: *Self, db: *DB, source: []const u8) !void {
            self.result.column_count = 0;
            self.result.row_count = 0;
            const command_source = trim(source);
            if (word(command_source, "begin") or word(command_source, "commit") or word(command_source, "rollback") or
                word(command_source, "end") or word(command_source, "abort") or word(command_source, "deallocate") or
                word(command_source, "start") or word(command_source, "copy")) return;
            try db.describe(source, &self.result);
        }

        /// Returns true when the engine should see the command as well
        /// (DEALLOCATE ALL); a name that is no protocol statement is
        /// StatementNotFound.
        fn deallocate(self: *Self, source: []const u8) !bool {
            var tokens: Tokens = .{ .source = source };
            if (!keyword(try tokens.next(), "deallocate")) return error.Syntax;
            var name = try tokens.next();
            if (keyword(name, "prepare")) name = try tokens.next();
            if (name.len == 0) return error.Syntax;
            var next = try tokens.next();
            if (equal(next, ";")) next = try tokens.next();
            if (next.len != 0) return error.Syntax;
            if (keyword(name, "all")) {
                for (&self.statements) |*s| s.live = false;
                return true;
            }
            var unquoted: [64]u8 = undefined;
            if (name[0] == '"') {
                if (name.len < 2 or name[name.len - 1] != '"') return error.Syntax;
                var used: usize = 0;
                var i: usize = 1;
                while (i + 1 < name.len) : (i += 1) {
                    if (used == unquoted.len) return error.NameCapacity;
                    unquoted[used] = name[i];
                    used += 1;
                    if (name[i] == '"') {
                        if (i + 2 >= name.len or name[i + 1] != '"') return error.Syntax;
                        i += 1;
                    }
                }
                name = unquoted[0..used];
            } else if (!identifier(name)) return error.Syntax;
            const s = try self.statement(name);
            s.live = false;
            return false;
        }
        fn statement(self: *Self, name: []const u8) !*Statement {
            for (&self.statements) |*s| if (s.live and equal(s.name.slice(), name)) return s;
            return error.StatementNotFound;
        }
        fn portal(self: *Self, name: []const u8) !*Portal {
            for (&self.portals) |*p| if (p.live and equal(p.name.slice(), name)) return p;
            return error.PortalNotFound;
        }
        fn parse(self: *Self, db: *DB, r: *Reader, w: *Writer) !void {
            const name = try r.string();
            const source = try r.string();
            if (source.len > sql_capacity) return error.StatementCapacity;
            var next: Statement = undefined;
            next.name=.{};next.oids=@splat(0);
            try next.name.set(name);
            next.len = source.len;
            @memcpy(next.sql[0..source.len], source);
            const count = try r.u16be();
            if (count > parameter_capacity) return error.ParameterCapacity;
            for (0..count) |i| next.oids[i] = try r.u32be();
            try r.done();
            next.single_parameter = null;
            next.count = try scan(source, null, null, &next.single_parameter);
            if (count != 0 and count != next.count) return error.ProtocolViolation;
            try self.infer(db, &next);
            var slot: ?*Statement = null;
            for (&self.statements) |*s| {
                if (s.live and equal(s.name.slice(), name)) {
                    if (name.len != 0) return error.DuplicateStatement;
                    slot = s;
                    break;
                }
                if (!s.live and slot == null) slot = s;
            }
            const s = slot orelse return error.StatementCapacity;
            // SQL tails are never part of a live statement. Publish only the
            // initialized source and bounded metadata, not sql_capacity bytes.
            s.name=next.name;s.len=next.len;s.count=next.count;s.single_parameter=next.single_parameter;s.oids=next.oids;
            @memcpy(s.sql[0..next.len],next.sql[0..next.len]);s.live=true;
            try w.empty('1');
        }
        fn infer(self: *Self, db: *DB, s: *Statement) !void {
            var unknown = false;
            for (s.oids[0..s.count]) |oid| if (oid == 0) {
                unknown = true;
                break;
            };
            if (!unknown) return;
            if (self.active_portal != null) return error.PortalBusy;
            var tokens: Tokens = .{ .source = s.source() };
            const first = try tokens.next();
            if (keyword(first, "select") and try inferExplicitSelectCasts(s, tokens)) return;
            var table: []const u8 = "";
            if (keyword(first, "insert")) {
                if (!keyword(try tokens.next(), "into")) return error.Syntax;
                table = try tokens.next();
            } else if (keyword(first, "update")) table = try tokens.next() else if (keyword(first, "select") or keyword(first, "delete")) {
                while (true) {
                    const token = try tokens.next();
                    if (token.len == 0) break;
                    if (keyword(token, "from")) {
                        table = try tokens.next();
                        break;
                    }
                }
            }
            if (table.len == 0 and keyword(first, "select")) {
                // A constant SELECT has no relation. Apply the same unknown
                // text fallback used below; explicit SQL casts still bind in
                // the engine. This is not general expression type inference.
                for (s.oids[0..s.count]) |*oid| if (oid.* == 0) { oid.* = 25; };
                return;
            }
            if (table.len == 0 or !identifier(table)) return error.UnsupportedStatement;
            var text: [sql_capacity]u8 = undefined;
            var q: Writer = .{ .bytes = &text };
            try q.append("SELECT * FROM ");
            try q.append(table);
            try q.append(" LIMIT 0");
            if (@hasDecl(DB, "describe")) {
                db.describe(q.bytes[0..q.at], &self.result) catch |err| {
                    // A relation wider than the result (a system view) gives no
                    // column types: unknown parameters stay text.
                    if (err != error.ColumnCapacity) return err;
                    for (s.oids[0..s.count]) |*oid| if (oid.* == 0) {
                        oid.* = 25;
                    };
                    return;
                };
            } else try db.execute(q.bytes[0..q.at], &self.result);
            if (self.result.column_count > 256) return error.ColumnCapacity;
            if (keyword(first, "insert")) {
                var mapping: [256]usize = undefined;
                var count_columns = self.result.column_count;
                for (0..count_columns) |i| mapping[i] = i;
                var token = try tokens.next();
                if (equal(token, "(")) {
                    count_columns = 0;
                    while (true) {
                        token = try tokens.next();
                        if (equal(token, ")")) break;
                        if (equal(token, ",")) continue;
                        if (count_columns == mapping.len) return error.ColumnCapacity;
                        mapping[count_columns] = self.column(token) orelse return error.ColumnNotFound;
                        count_columns += 1;
                    }
                    token = try tokens.next();
                }
                if (!keyword(token, "values") or !equal(try tokens.next(), "(")) return error.Syntax;
                var column_index: usize = 0;
                while (true) {
                    token = try tokens.next();
                    if (token.len == 0) return error.Syntax;
                    if (equal(token, ")")) break;
                    if (equal(token, ",")) {
                        column_index += 1;
                        continue;
                    }
                    if (parameterToken(token)) {
                        if (column_index >= count_columns) return error.ColumnCapacity;
                        try inferOid(s, token, T.oid(self.result.column_types[mapping[column_index]]));
                    }
                }
            } else {
                tokens = .{ .source = s.source() };
                var column_index: ?usize = null;
                while (true) {
                    const token = try tokens.next();
                    if (token.len == 0) break;
                    if (parameterToken(token)) {
                        if (column_index) |i| try inferOid(s, token, T.oid(self.result.column_types[i]));
                    } else if (identifier(token)) {
                        column_index = self.column(token);
                    } else if (token[0] != '=' and token[0] != '<' and token[0] != '>' and token[0] != '!' and token[0] != ' ') {
                        // `col ->> $1`, `col + $1`: the operator decides the
                        // parameter type, not the column; leave it unknown.
                        column_index = null;
                    }
                }
            }
            for (s.oids[0..s.count]) |*oid| if (oid.* == 0) {
                oid.* = 25;
            };
        }

        // A parameter explicitly cast in a SELECT can be typed without
        // probing its FROM item as a table. In particular a set-returning
        // function or derived table does not have a standalone relation.
        fn inferExplicitSelectCasts(s: *Statement, scan_tokens: Tokens) !bool {
            var tokens = scan_tokens;
            var oids = s.oids;
            while (true) {
                const token = try tokens.next();
                if (token.len == 0) break;
                if (!parameterToken(token)) continue;
                const index = try parameterIndex(s, token);
                if (oids[index] != 0) continue;

                var lookahead = tokens;
                if (!equal(try lookahead.next(), "::")) return false;
                const name = try lookahead.next();
                if (name.len == 0) return false;
                const start = @intFromPtr(name.ptr) - @intFromPtr(tokens.source.ptr);
                var end = lookahead.at;
                var suffix = try lookahead.next();
                if (equal(suffix, ".")) {
                    if ((try lookahead.next()).len == 0) return false;
                    end = lookahead.at;
                    suffix = try lookahead.next();
                }
                while (equal(suffix, "[")) {
                    if (!equal(try lookahead.next(), "]")) return false;
                    end = lookahead.at;
                    suffix = try lookahead.next();
                }
                const data_type = sql.typeByName(tokens.source[start..end]) orelse return false;
                oids[index] = T.oid(data_type);
            }
            for (oids[0..s.count]) |oid| if (oid == 0) return false;
            s.oids = oids;
            return true;
        }
        fn column(self: *Self, name: []const u8) ?usize {
            for (0..self.result.column_count) |i| if (keyword(name, self.result.column_names[i].slice())) return i;
            return null;
        }
        fn bind(self: *Self, db: *DB, r: *Reader, w: *Writer) !void {
            const name = try r.string();
            const statement_name = try r.string();
            const s = try self.statement(statement_name);
            const nf = try r.u16be();
            if (nf > parameter_capacity) return error.ParameterCapacity;
            var formats: [parameter_capacity]u16 = @splat(0);
            for (0..nf) |i| {
                formats[i] = try r.u16be();
                if (formats[i] > 1) return error.ProtocolViolation;
            }
            const count = try r.u16be();
            if (count != s.count or (nf > 1 and nf != count)) return error.ProtocolViolation;
            var literals: [sql_capacity]u8 = undefined;
            var values: [parameter_capacity][]const u8 = undefined;
            var l: Writer = .{ .bytes = &literals };
            var key: ?i64 = null;
            var key_candidate = has_primary_key and count == 1 and integralParameter(s.oids[0]) and s.len <= primary_key_sql_capacity;
            for (0..count) |i| {
                const begin = l.at;
                const size = try r.u32be();
                if (size == 0xffffffff) try l.append("NULL") else {
                    const bytes = try r.take(size);
                    const fmt = if (nf == 0) 0 else formats[if (nf == 1) 0 else i];
                    if (T.handles(s.oids[i])) {
                        l.at += T.literal(bytes, s.oids[i], fmt, l.bytes[l.at..]) catch |err| return if (err == error.BufferTooSmall) error.StatementCapacity else err;
                    } else try literal(&l, bytes, s.oids[i], fmt);
                    if (key_candidate) {
                        if (primaryKeyNumber(bytes, s.oids[i], fmt)) |number| key = number else key_candidate = false;
                    }
                }
                values[i] = l.bytes[begin..l.at];
            }
            var next: Portal = undefined;
            next.name=.{};next.level=0;
            try next.name.set(name);
            next.format_count = try r.u16be();
            if (next.format_count > next.formats.len) return error.ColumnCapacity;
            for (0..next.format_count) |i| {
                next.formats[i] = try r.u16be();
                if (next.formats[i] > 1) return error.ProtocolViolation;
            }
            try r.done();
            var q: Writer = .{ .bytes = &next.sql };
            if (s.single_parameter) |span| {
                const source = s.source();
                try q.append(source[0..span.start]);
                try splice(&q, values[0], source[span.end..]);
                try q.append(source[span.end..]);
            } else try interpolate(s.source(), values[0..count], &q);
            next.len = q.at;
            if (@hasDecl(DB, "savepointLevel")) next.level = db.savepointLevel();
            var slot: ?*Portal = null;
            for (&self.portals) |*p| {
                if (p.live and equal(p.name.slice(), name)) {
                    if (name.len != 0) return error.DuplicatePortal;
                    slot = p;
                    break;
                }
                if (!p.live and slot == null) slot = p;
            }
            const p = slot orelse return error.PortalCapacity;
            if (self.active_portal) |active| {
                if (p == &self.portals[active]) return error.PortalBusy;
            }
            // Validate completely before replacing even the unnamed portal.
            // The prior SQL/format tails may contain old bytes; every accessor
            // is bounded by len/format_count and cannot observe those tails.
            p.name=next.name;p.len=next.len;p.format_count=next.format_count;p.level=next.level;
            @memcpy(p.sql[0..next.len],next.sql[0..next.len]);
            @memcpy(p.formats[0..next.format_count],next.formats[0..next.format_count]);
            if (comptime has_primary_key) {
                p.primary_key = if (key_candidate) .{ .len = s.len, .oid = s.oids[0], .key = key } else null;
                if (p.primary_key) |*bound_key| @memcpy(bound_key.sql[0..s.len], s.source());
            }
            p.row=0;p.complete=false;p.result_rows=0;p.affected=0;p.rolled_back=false;p.command="";p.live=true;
            try w.empty('2');
        }
        fn description(self: *Self, w: *Writer, portal_value: ?*const Portal) !void {
            if (self.result.column_count == 0) {
                try w.empty('n');
                return;
            }
            const p = try w.begin('T');
            try w.u16be(@intCast(self.result.column_count));
            for (0..self.result.column_count) |i| {
                try w.string(self.result.column_names[i].slice());
                try w.u32be(0);
                try w.u16be(0);
                const data_type = self.result.column_types[i];
                const nominal = if (@hasDecl(DB.Result, "nominalColumnType")) self.result.nominalColumnType(i) else null;
                try w.u32be(if (nominal) |identity| identity.oid else T.oid(data_type));
                try w.u16be(@bitCast(if (nominal) |identity| identity.len else T.length(data_type)));
                const typmod: i32 = if (@hasField(DB.Result, "column_typmods")) self.result.column_typmods[i] else -1;
                try w.u32be(@bitCast(typmod));
                if (portal_value) |v| {
                    if (v.format_count > 1 and v.format_count != self.result.column_count) return error.ProtocolViolation;
                    try w.u16be(v.format(i));
                } else try w.u16be(0);
            }
            w.end(p);
        }

        fn nominalText(self: *const Self, column_index: usize, cell: anytype, out: []u8) !?usize {
            if (comptime @hasDecl(DB.Result, "formatNominalText"))
                return self.result.formatNominalText(column_index, cell, out) catch error.BufferTooSmall;
            return null;
        }

        fn rows(self: *Self, db: *DB, w: *Writer, formats: anytype, first: usize, end: usize) !void {
            const session = valueSession(db);
            const stride = if (@TypeOf(formats) == []const u8) 2 else 1;
            const format_count = formats.len / stride;
            for (first..end) |row| {
                const p = try w.begin('D');
                try w.u16be(@intCast(self.result.column_count));
                for (0..self.result.column_count) |i| {
                    const format_index = if (format_count == 1) 0 else i;
                    const binary = format_count != 0 and formats[format_index * stride + stride - 1] == 1;
                    try self.dataCell(w, &self.result.rows[row].cells[i], self.result.column_types[i], session, binary, i);
                }
                w.end(p);
            }
        }

        fn dataCell(self: *const Self, w: *Writer, cell: anytype, data_type: @TypeOf(@as(DB.Result, undefined).column_types[0]), session: *const T.Session, binary: bool, nominal_column: ?usize) !void {
            if (cell.* == .null_value) return w.u32be(0xffffffff);
            const length = w.at;
            try w.u32be(0);
            const start = w.at;
            switch (cell.*) {
                .null_value => unreachable,
                .integer => |n| if (binary) {
                    w.at += T.sendBinary(cell, data_type, session, w.bytes[w.at..]) catch return error.BufferTooSmall;
                } else try w.number(n),
                .boolean => |b| try w.byte(if (binary) @intFromBool(b) else if (b) 't' else 'f'),
                .text => |*t| try w.append(t.slice()),
                else => {
                    const nominal = if (binary) null else if (nominal_column) |i| try self.nominalText(i, cell, w.bytes[w.at..]) else null;
                    const size = nominal orelse ((if (binary) T.sendBinary(cell, data_type, session, w.bytes[w.at..]) else T.sendText(cell, session, w.bytes[w.at..])) catch return error.BufferTooSmall);
                    w.at += size;
                },
            }
            write32(w.bytes[length..][0..4], @intCast(w.at - start));
        }
        fn command(self: *Self, w: *Writer, source: []const u8) !void {
            if (self.objectTag()) |tag| {
                const p = try w.begin('C');
                try w.append(tag);
                try w.byte(0);
                w.end(p);
                return;
            }
            try commandFor(w, source, self.completed(), self.result.row_count, self.result.affected_rows, self.commit_rolled_back);
        }
        /// Command tags of the catalog-object statements (B11 wave 3).
        fn objectTag(self: *const Self) ?[]const u8 {
            if (!@hasField(DB.Result, "command")) return null;
            return switch (self.result.command) {
                .create_role => "CREATE ROLE",
                .alter_role => "ALTER ROLE",
                .drop_role => "DROP ROLE",
                .grant => "GRANT",
                .revoke => "REVOKE",
                .grant_role => "GRANT ROLE",
                .revoke_role => "REVOKE ROLE",
                .create_policy => "CREATE POLICY",
                .alter_policy => "ALTER POLICY",
                .drop_policy => "DROP POLICY",
                .comment => "COMMENT",
                .create_foreign_data_wrapper => "CREATE FOREIGN DATA WRAPPER",
                .drop_foreign_data_wrapper => "DROP FOREIGN DATA WRAPPER",
                .create_server => "CREATE SERVER",
                .drop_server => "DROP SERVER",
                .create_publication => "CREATE PUBLICATION",
                .drop_publication => "DROP PUBLICATION",
                .create_statistics => "CREATE STATISTICS",
                .alter_statistics => "ALTER STATISTICS",
                .alter_schema => "ALTER SCHEMA",
                .drop_statistics => "DROP STATISTICS",
                .create_extension => "CREATE EXTENSION",
                .create_domain => "CREATE DOMAIN",
                .drop_domain => "DROP DOMAIN",
                .create_type => "CREATE TYPE",
                .drop_type => "DROP TYPE",
                else => null,
            };
        }
        /// The engine's own command tag for the last statement, when it has one.
        fn completed(self: *const Self) []const u8 {
            if (!@hasField(DB.Result, "command")) return "";
            const create_query_data = if (comptime @hasField(DB.Result, "create_query_data")) self.result.create_query_data else false;
            return switch (self.result.command) {
                .select => "select",
                .insert => "insert",
                .update => "update",
                .delete => "delete",
                .merge => "merge",
                .explain => "EXPLAIN",
                .create_table => "create",
                .create_table_as => if (create_query_data) "select_created" else "CREATE TABLE AS",
                .create_materialized_view => if (create_query_data) "select_created" else "CREATE MATERIALIZED VIEW",
                .refresh_materialized_view => "REFRESH MATERIALIZED VIEW",
                .create_index => "CREATE INDEX",
                .create_view => "CREATE VIEW",
                .drop_table => "drop",
                .create_sequence => "create_sequence",
                .drop_sequence => "drop_sequence",
                .truncate => "truncate",
                .vacuum => "VACUUM",
                .analyze => "ANALYZE",
                .alter_table => "alter_table",
                .alter_sequence => "alter_sequence",
                .create_schema => "create_schema",
                .drop_schema => "drop_schema",
                .begin => "begin",
                .commit => "commit",
                .rollback => "rollback",
                .savepoint => "savepoint",
                .release => "release",
                .set => "set",
                .set_constraints => "SET CONSTRAINTS",
                .show => "show",
                .reset => "reset",
                .lock_table => "lock_table",
                .declare_cursor => "declare_cursor",
                .fetch => "fetch",
                .move => "move",
                .close_cursor => "close_cursor",
                .prepare => "prepare",
                .prepare_transaction => "PREPARE TRANSACTION",
                .commit_prepared => "COMMIT PREPARED",
                .rollback_prepared => "ROLLBACK PREPARED",
                .deallocate => "deallocate",
                .listen => "listen",
                .notify => "notify",
                .unlisten => "unlisten",
                .create_function => "CREATE FUNCTION",
                .drop_function => "DROP FUNCTION",
                .create_procedure => "CREATE PROCEDURE",
                .drop_procedure => "DROP PROCEDURE",
                .call => "CALL",
                .do_block => "DO",
                .create_trigger => "CREATE TRIGGER",
                .drop_trigger => "DROP TRIGGER",
                .create_rule => "CREATE RULE",
                .drop_rule => "DROP RULE",
                else => "",
            };
        }
        fn isCommand(completed_command: []const u8, source: []const u8, wanted: []const u8) bool {
            return if (completed_command.len != 0) equal(completed_command, wanted) else word(source, wanted);
        }
        fn commandFor(w: *Writer, source: []const u8, completed_command: []const u8, row_count: usize, affected: usize, rolled_back: bool) !void {
            const p = try w.begin('C');
            if (equal(completed_command, "lock_table")) {
                try w.append("LOCK TABLE");
            } else if (equal(completed_command, "declare_cursor")) {
                try w.append("DECLARE CURSOR");
            } else if (equal(completed_command, "fetch")) {
                try w.append("FETCH ");
                try w.number(@intCast(row_count));
            } else if (equal(completed_command, "move")) {
                try w.append("MOVE ");
                try w.number(@intCast(affected));
            } else if (equal(completed_command, "close_cursor")) {
                try w.append("CLOSE CURSOR");
            } else if (equal(completed_command, "prepare")) {
                try w.append("PREPARE");
            } else if (equal(completed_command, "deallocate")) {
                try w.append(if (deallocateAll(source)) "DEALLOCATE ALL" else "DEALLOCATE");
            } else if (equal(completed_command, "listen")) {
                try w.append("LISTEN");
            } else if (equal(completed_command, "notify")) {
                try w.append("NOTIFY");
            } else if (equal(completed_command, "unlisten")) {
                try w.append("UNLISTEN");
            } else if (completed_command.len != 0 and completed_command[0] >= 'A' and completed_command[0] <= 'Z') {
                try w.append(completed_command);
            } else if (equal(completed_command, "create_sequence")) {
                try w.append("CREATE SEQUENCE");
            } else if (equal(completed_command, "drop_sequence")) {
                try w.append("DROP SEQUENCE");
            } else if (equal(completed_command, "truncate")) {
                try w.append("TRUNCATE TABLE");
            } else if (equal(completed_command, "alter_table")) {
                try w.append("ALTER TABLE");
            } else if (equal(completed_command, "alter_sequence")) {
                try w.append("ALTER SEQUENCE");
            } else if (equal(completed_command, "create_schema")) {
                try w.append("CREATE SCHEMA");
            } else if (equal(completed_command, "drop_schema")) {
                try w.append("DROP SCHEMA");
            } else if (equal(completed_command, "select_created")) {
                try w.append("SELECT ");
                try w.number(@intCast(affected));
            } else if (isCommand(completed_command, source, "select")) {
                try w.append("SELECT ");
                try w.number(@intCast(row_count));
            } else if (isCommand(completed_command, source, "insert")) {
                try w.append("INSERT 0 ");
                try w.number(@intCast(affected));
            } else if (isCommand(completed_command, source, "update")) {
                try w.append("UPDATE ");
                try w.number(@intCast(affected));
            } else if (isCommand(completed_command, source, "delete")) {
                try w.append("DELETE ");
                try w.number(@intCast(affected));
            } else if (equal(completed_command, "merge")) {
                try w.append("MERGE ");
                try w.number(@intCast(affected));
            } else if (isCommand(completed_command, source, "create")) try w.append("CREATE TABLE") else if (isCommand(completed_command, source, "drop")) try w.append("DROP TABLE") else if (equal(completed_command, "savepoint")) try w.append("SAVEPOINT") else if (equal(completed_command, "release")) try w.append("RELEASE") else if (equal(completed_command, "show")) try w.append("SHOW") else if (equal(completed_command, "reset")) try w.append("RESET") else if (equal(completed_command, "set")) try w.append("SET") else if (equal(completed_command, "begin")) try w.append("BEGIN") else if (equal(completed_command, "commit")) try w.append(if (rolled_back) "ROLLBACK" else "COMMIT") else if (equal(completed_command, "rollback")) try w.append("ROLLBACK") else if (word(source, "begin") or word(source, "start")) try w.append("BEGIN") else if (word(source, "commit") or word(source, "end")) try w.append(if (rolled_back) "ROLLBACK" else "COMMIT") else if (word(source, "rollback") or word(source, "abort")) try w.append("ROLLBACK") else if (word(source, "set")) try w.append("SET") else if (word(source, "deallocate")) try w.append("DEALLOCATE") else try w.append("OK");
            try w.byte(0);
            w.end(p);
        }
    };
}

fn deallocateAll(source: []const u8) bool {
    const text = trim(source);
    return text.len >= 3 and keyword(text[text.len - 3 ..], "all") and (text.len == 3 or text[text.len - 4] == ' ' or text[text.len - 4] == '\t' or text[text.len - 4] == '\n');
}

fn parameter(w: *Writer, key: []const u8, value: []const u8) !void {
    const p = try w.begin('S');
    try w.string(key);
    try w.string(value);
    w.end(p);
}
fn failure(w: *Writer, state: []const u8, message: []const u8) !void {
    return diagnostic(w, 'E', "ERROR", state, message);
}

fn diagnostic(w: *Writer, tag: u8, severity: []const u8, state: []const u8, message: []const u8) !void {
    const p = try w.begin(tag);
    try w.byte('S');
    try w.string(severity);
    try w.byte('V');
    try w.string(severity);
    try w.byte('C');
    try w.string(state);
    try w.byte('M');
    try w.string(message);
    try w.byte(0);
    w.end(p);
}
fn authenticationFailure(w: *Writer) !void {
    return fatal(w, "28P01", "password authentication failed");
}

pub fn connectionLimitError(output: []u8) error{BufferTooSmall}!usize {
    var writer: Writer = .{ .bytes = output };
    try fatal(&writer, "53300", "too many connections");
    return writer.at;
}
pub fn memoryLimitError(output: []u8) error{BufferTooSmall}!usize {
    var writer: Writer = .{ .bytes = output };
    try fatal(&writer, "53200", "database memory budget exhausted");
    return writer.at;
}

/// PostgreSQL terminates the session after sending this fatal response.
pub fn idleTransactionTimeoutError(output: []u8) error{BufferTooSmall}!usize {
    var writer: Writer = .{ .bytes = output };
    try fatal(&writer, "25P03", "terminating connection due to idle-in-transaction timeout");
    return writer.at;
}

pub fn transactionTimeoutError(output: []u8) error{BufferTooSmall}!usize {
    var writer: Writer = .{ .bytes = output };
    try transactionTimeoutFatal(&writer);
    return writer.at;
}

fn transactionTimeoutFatal(writer: *Writer) error{BufferTooSmall}!void {
    try fatal(writer, "25P04", "terminating connection due to transaction timeout");
}

fn fatal(w: *Writer, state: []const u8, message: []const u8) !void {
    return diagnostic(w, 'E', "FATAL", state, message);
}
fn sqlstate(err: anyerror) []const u8 {
    return knownSqlstate(err) orelse "54000";
}

fn diagnosticMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.RestrictedNonSystemView => "access to non-system view is restricted",
        error.RestrictedNonSystemForeignTable => "access to non-system foreign table is restricted",
        else => @errorName(err),
    };
}

/// SQLSTATE for every engine, store and protocol error this codec knows;
/// null means the error would fall back to 54000 (program_limit_exceeded).
pub fn knownSqlstate(err: anyerror) ?[]const u8 {
    const name = @errorName(err);
    if (equal(name, "TransactionTimeout")) return "25P04";
    if (equal(name, "DatabaseNotFound")) return "3D000";
    if (equal(name, "DuplicateDatabase")) return "42P04";
    if (equal(name, "InvalidDatabaseName")) return "42602";
    if (equal(name, "DatabaseBusy")) return "55006";
    if (equal(name, "AdmissionDenied")) return "42501";
    if (equal(name, "LeaseCapacity")) return "53300";
    if (equal(name, "UndefinedFunction")) return "42883";
    if (equal(name, "AmbiguousFunction")) return "42725";
    if (equal(name, "CannotCoerce")) return "42846";
    if (equal(name, "InvalidTextRepresentation")) return "22P02";
    if (equal(name, "DivisionByZero")) return "22012";
    if (equal(name, "InvalidArgumentForPowerFunction")) return "2201F";
    if (equal(name, "InvalidEscapeSequence")) return "22025";
    if (equal(name, "CharacterNotInRepertoire")) return "22021";
    if (equal(name, "SubstringError")) return "22011";
    if (equal(name, "InvalidArgumentForLogarithm")) return "2201E";
    if (equal(name, "ProgramLimitExceeded")) return "54000";
    if (equal(name, "UndefinedParameter")) return "42P02";
    if (equal(name, "InvalidColumnReference")) return "42P10";
    if (equal(name, "WorkspaceCapacity")) return "54000";
    if (equal(name, "QueryWorkLimit")) return "54000";
    if (equal(name, "GroupingError")) return "42803";
    if (equal(name, "WindowingError")) return "42P20";
    if (equal(name, "InvalidWindowFrameOffset")) return "22013";
    if (equal(name, "InvalidArgumentForNtile")) return "22014";
    if (equal(name, "InvalidArgumentForNthValue")) return "22016";
    if (equal(name, "NullWindowFrameOffset")) return "22004";
    if (equal(name, "AmbiguousColumn")) return "42702";
    if (equal(name, "CardinalityViolation")) return "21000";
    if (equal(name, "InvalidRowCountInLimit")) return "2201W";
    if (equal(name, "InvalidRowCountInResultOffset")) return "2201X";
    if (equal(name, "GeneratedAlways")) return "428C9";
    if (equal(name, "InvalidObjectDefinition")) return "42P17";
    if (equal(name, "SequenceLimit")) return "2200H";
    if (equal(name, "SequenceNotReady")) return "55000";
    if (equal(name, "WrongObjectType")) return "42809";
    if (equal(name, "DependentObjects")) return "2BP01";
    if (equal(name, "UndefinedObject")) return "42704";
    if (equal(name, "InvalidName")) return "42602";
    if (equal(name, "BadCopyFormat")) return "22P04";
    if (equal(name, "InvalidBinaryRepresentation")) return "22P03";
    if (equal(name, "StringDataRightTruncation")) return "22001";
    if (equal(name, "InvalidTimeZoneDisplacement")) return "22009";
    if (equal(name, "StringDataLengthMismatch")) return "22026";
    if (equal(name, "NumericValueOutOfRange")) return "22003";
    if (equal(name, "NumericCapacity")) return "54000";
    if (equal(name, "InvalidParameterValue")) return "22023";
    if (equal(name, "InvalidDatetimeFormat")) return "22007";
    if (equal(name, "DatetimeFieldOverflow")) return "22008";
    if (equal(name, "IntervalFieldOverflow")) return "22015";
    if (equal(name, "UntranslatableCharacter")) return "22P05";
    if (equal(name, "ClockUnavailable")) return "0A000";
    if (equal(name, "TimeZoneCapacity")) return "53200";
    if (equal(name, "StatementTooComplex")) return "54001";
    if (equal(name, "VersionCapacity")) return "53200";
    if (equal(name, "TableCapacity") or equal(name, "ColumnCapacity") or equal(name, "RowCapacity") or
        equal(name, "NameCapacity") or equal(name, "TextCapacity") or equal(name, "PredicateCapacity")) return "54000";
    if (equal(name, "UnsupportedLogVersion") or equal(name, "InvalidChangeRecord") or equal(name, "ChangeRecordConflict")) return "XX001";
    if (equal(name, "TableNotFound")) return "42P01";
    if (equal(name, "ColumnNotFound")) return "42703";
    if (equal(name, "TableExists")) return "42P07";
    if (equal(name, "DuplicateColumn")) return "42701";
    if (equal(name, "PrimaryKeyViolation")) return "23505";
    if (equal(name, "NotNullViolation")) return "23502";
    if (equal(name, "CheckViolation")) return "23514";
    if (equal(name, "ForeignKeyViolation")) return "23503";
    if (equal(name, "ExclusionViolation")) return "23P01";
    if (equal(name, "IndexCapacity")) return "54000";
    if (equal(name, "InvalidForeignKey")) return "42830";
    if (equal(name, "ObjectNotInPrerequisiteState") or equal(name, "RestrictedNonSystemView") or equal(name, "RestrictedNonSystemForeignTable")) return "55000";
    if (equal(name, "DuplicateObject")) return "42710";
    if (equal(name, "InvalidTableDefinition")) return "42P16";
    if (equal(name, "UndefinedSchema")) return "3F000";
    if (equal(name, "DuplicateSchema")) return "42P06";
    if (equal(name, "IndeterminateDatatype")) return "42P18";
    if (equal(name, "ArraySubscriptError")) return "2202E";
    if (equal(name, "DataException")) return "22000";
    if (equal(name, "InvalidXmlContent")) return "2200N";
    if (equal(name, "InvalidXmlDocument")) return "2200M";
    if (equal(name, "NotAnXmlDocument")) return "2200L";
    if (equal(name, "CollationMismatch")) return "42P21";
    if (equal(name, "InvalidRegularExpression")) return "2201B";
    if (equal(name, "InvalidEscapeCharacterUse")) return "2200C";
    if (equal(name, "InvalidTablesampleArgument")) return "2202H";
    if (equal(name, "InvalidTablesampleRepeat")) return "2202G";
    // Routines, triggers and rules (B11 wave 3).
    if (equal(name, "DuplicateFunction")) return "42723";
    if (equal(name, "InvalidFunctionDefinition")) return "42P13";
    if (equal(name, "RaiseException")) return "P0001";
    if (equal(name, "NoDataFound")) return "P0002";
    if (equal(name, "TooManyRows")) return "P0003";
    if (equal(name, "FunctionExecutedNoReturn")) return "2F005";
    if (equal(name, "CaseNotFound")) return "20000";
    if (equal(name, "StackDepthExceeded")) return "54001";
    if (equal(name, "NullValueNotAllowed")) return "22004";
    if (equal(name, "ErrorInAssignment")) return "22005";
    if (equal(name, "SqlJsonArrayNotFound")) return "22039";
    if (equal(name, "SqlJsonMemberNotFound")) return "2203A";
    if (equal(name, "SqlJsonObjectNotFound")) return "2203C";
    if (equal(name, "InvalidSqlJsonSubscript")) return "22033";
    if (equal(name, "SingletonSqlJsonItemRequired")) return "22038";
    if (equal(name, "NonNumericSqlJsonItem")) return "22036";
    if (equal(name, "SqlJsonNumberNotFound")) return "2203B";
    if (equal(name, "SqlJsonScalarRequired")) return "2203F";
    if (equal(name, "SqlJsonItemCannotBeCast")) return "2203G";
    if (equal(name, "MoreThanOneSqlJsonItem")) return "22034";
    if (equal(name, "NoSqlJsonItem")) return "22035";
    // Catalog objects (B11 wave 3).
    if (equal(name, "InsufficientPrivilege")) return "42501";
    if (equal(name, "ReservedName")) return "42939";
    if (equal(name, "ObjectInUse")) return "55006";
    if (equal(name, "InvalidGrantOperation")) return "0LP01";
    if (equal(name, "TypeMismatch")) return "42804";
    if (equal(name, "IntegerOverflow")) return "22003";
    if (equal(name, "ProtocolViolation")) return "08P01";
    if (equal(name, "StatementNotFound")) return "26000";
    if (equal(name, "PortalNotFound")) return "34000";
    if (equal(name, "DuplicateStatement")) return "42P05";
    if (equal(name, "DuplicatePortal")) return "42P03";
    if (equal(name, "TransactionFailed")) return "25P02";
    if (equal(name, "ActiveSqlTransaction")) return "25001";
    if (equal(name, "SessionCapacity")) return "54000";
    if (equal(name, "DatabaseBusy")) return "55P03";
    if (equal(name, "SerializationFailure")) return "40001";
    if (equal(name, "DeadlockDetected")) return "40P01";
    // WouldBlock never reaches a client (it becomes Reply.blocked).
    if (equal(name, "LockNotAvailable") or equal(name, "WouldBlock")) return "55P03";
    if (equal(name, "QueryCanceled")) return "57014";
    if (equal(name, "WriteSetCapacity") or equal(name, "LockCapacity") or equal(name, "CatalogCapacity") or equal(name, "SavepointCapacity")) return "53200";
    if (equal(name, "SavepointNotFound")) return "3B001";
    if (equal(name, "NoActiveTransaction")) return "25P01";
    if (equal(name, "ReadOnlyTransaction")) return "25006";
    if (equal(name, "UndefinedSetting")) return "42704";
    if (equal(name, "InvalidSettingValue")) return "22023";
    if (equal(name, "TransactionCapacity") or equal(name, "TransactionLogCapacity")) return "53200";
    if (equal(name, "StorageUnavailable") or equal(name, "StorageFailure") or equal(name, "FileWriteFailed") or equal(name, "FileSyncFailed") or equal(name, "FileTruncateFailed") or equal(name, "WriterPoisoned")) return "58030";
    if (equal(name, "Syntax")) return "42601";
    if (equal(name, "UnsupportedStatement") or equal(name, "UnsupportedMessage") or equal(name, "UnsupportedProtocol") or equal(name, "UnsupportedEncoding") or equal(name, "UnsupportedBinaryType")) return "0A000";
    return null;
}

// The engine tokenizer owns quote/comment/identifier boundaries. Counting and
// interpolation visit precisely its parameter tokens; every untouched byte is
// copied verbatim, including whitespace and nested comments.
const ParameterSpan = struct { start: usize, end: usize };
fn scan(source: []const u8, values: ?[]const []const u8, w: ?*Writer, single: ?*?ParameterSpan) !usize {
    var tokenizer: sql.Tokenizer = .{ .source = source, .text_limit = source.len };
    var copied: usize = 0;
    var highest: usize = 0;
    while (true) {
        const token = try tokenizer.next();
        if (token.kind == .end) break;
        if (token.kind != .parameter) continue;
        if (token.integer > parameter_capacity) return error.ParameterCapacity;
        const n: usize = @intCast(token.integer);
        if (single) |span| span.* = if (highest == 0 and n == 1) .{ .start = token.start, .end = token.end } else null;
        highest = @max(highest, n);
        if (values) |v| {
            if (n > v.len) return error.ProtocolViolation;
            if (w) |out| {
                try out.append(source[copied..token.start]);
                try splice(out, v[n - 1], source[token.end..]);
            }
        }
        copied = token.end;
    }
    if (w) |out| try out.append(source[copied..]);
    return highest;
}
/// A byte that can continue a word, number, string or quoted identifier.
fn tokenByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$' or c == '.' or c == '\'' or c == '"' or c >= 0x80;
}
/// Whether `a` directly followed by `b` could lex as one token (a word, a
/// number, `''` or `""`) or open a comment (`--`, `/*`).
fn joins(a: u8, b: u8) bool {
    return (tokenByte(a) and tokenByte(b)) or (a == '-' and b == '-') or (a == '/' and b == '*');
}
/// Appends a rendered parameter as a self-contained token sequence (NET-01):
/// a space separates it from the preceding output or the following `rest`
/// only where they would otherwise merge, so other spliced text is unchanged.
fn splice(w: *Writer, value: []const u8, rest: []const u8) !void {
    if (value.len == 0) return;
    // An exponent sign on the left: `1e-$1` must not lex as the number 1e-5.
    const sign = w.at >= 2 and (w.bytes[w.at - 1] == '-' or w.bytes[w.at - 1] == '+') and (w.bytes[w.at - 2] | 0x20) == 'e';
    if (w.at != 0 and (sign or joins(w.bytes[w.at - 1], value[0]))) try w.byte(' ');
    try w.append(value);
    if (rest.len != 0 and joins(value[value.len - 1], rest[0])) try w.byte(' ');
}
fn interpolate(source: []const u8, values: []const []const u8, w: *Writer) !void {
    _ = try scan(source, values, w, null);
}
/// `$n`: a dollar-quoted string (`$$x$$`, `$q$x$q$`) is not a parameter.
fn parameterToken(token: []const u8) bool {
    return token.len > 1 and token[0] == '$' and token[1] >= '0' and token[1] <= '9';
}
fn identifier(token: []const u8) bool {
    if (token.len == 0) return false;
    const first = lower(token[0]);
    return (first >= 'a' and first <= 'z') or first == '_';
}
// Inference and DEALLOCATE use the same tokenizer as execution, while keeping
// quoted delimiters in their borrowed source spans for existing name handling.
const Tokens = struct {
    source: []const u8,
    at: usize = 0,
    fn next(self: *Tokens) ![]const u8 {
        var tokenizer: sql.Tokenizer = .{ .source = self.source, .position = self.at, .text_limit = self.source.len };
        const token = try tokenizer.next();
        self.at = tokenizer.position;
        if (token.kind == .end) return "";
        if (token.kind == .string or token.kind == .quoted_word)
            return token.whole(self.source);
        return self.source[token.start..token.end];
    }
};
fn parameterIndex(s: anytype, token: []const u8) !usize {
    var n: usize = 0;
    for (token[1..]) |c| {
        if (c < '0' or c > '9') return error.Syntax;
        n = n * 10 + c - '0';
        if (n > parameter_capacity) return error.ParameterCapacity;
    }
    if (n == 0 or n > s.count) return error.ProtocolViolation;
    return n - 1;
}
fn inferOid(s: anytype, token: []const u8, oid: u32) !void {
    const index = try parameterIndex(s, token);
    const previous = s.oids[index];
    const integer_conversion = (oid == 20 or oid == 23) and (previous == 20 or previous == 21 or previous == 23);
    if (previous != 0 and previous != oid and !integer_conversion) return error.TypeMismatch;
    if (previous == 0) s.oids[index] = oid;
}
fn integerText(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = if (bytes[0] == '-' or bytes[0] == '+') 1 else 0;
    if (i == bytes.len) return false;
    while (i < bytes.len) : (i += 1) if (bytes[i] < '0' or bytes[i] > '9') return false;
    return true;
}
fn quoted(w: *Writer, bytes: []const u8) !void {
    try w.byte('\'');
    for (bytes) |c| {
        if (c == 0) return error.ProtocolViolation;
        try w.byte(c);
        if (c == '\'') try w.byte(c);
    }
    try w.byte('\'');
}
fn integralParameter(oid: u32) bool {
    return oid == 20 or oid == 21 or oid == 23;
}

fn binaryInteger(bytes: []const u8, oid: u32) !i64 {
    const count: usize = if (oid == 20) 8 else if (oid == 21) 2 else 4;
    if (bytes.len != count) return error.ProtocolViolation;
    var bits: u64 = if (bytes[0] & 128 != 0) 0xffffffffffffffff else 0;
    for (bytes) |b| bits = (bits << 8) | b;
    return @bitCast(bits);
}

fn primaryKeyNumber(bytes: []const u8, oid: u32, format: u16) ?i64 {
    if (format == 1) return binaryInteger(bytes, oid) catch null;
    // The ordinary literal path already enforces integerText. Only values
    // that fit their declared SQL type are eligible for the typed route.
    const value = std.fmt.parseInt(i64, bytes, 10) catch return null;
    if (oid == 21 and (value < -32768 or value > 32767)) return null;
    if (oid == 23 and (value < -2147483648 or value > 2147483647)) return null;
    return value;
}

fn literal(w: *Writer, bytes: []const u8, oid: u32, format: u16) !void {
    if (format == 1) {
        if (oid == 16) {
            if (bytes.len != 1 or bytes[0] > 1) return error.ProtocolViolation;
            try w.append(if (bytes[0] == 1) "TRUE" else "FALSE");
        } else if (integralParameter(oid)) {
            const value = try binaryInteger(bytes, oid);
            // NET-01: a negative is `(-5)`, so `x-$1` never becomes `x--5`
            // (a comment) and `$1::text` casts the whole value.
            if (value < 0) try w.byte('(');
            try w.number(value);
            if (value < 0) try w.byte(')');
        } else if (oid == 25 or oid == 1043 or oid == 1042) try quoted(w, bytes) else return error.UnsupportedBinaryType;
    } else if (oid == 20 or oid == 21 or oid == 23 or (oid == 0 and integerText(bytes))) {
        if (!integerText(bytes)) return error.TypeMismatch;
        const digits = if (bytes[0] == '+') bytes[1..] else bytes;
        // NET-01: parenthesize negatives as above. Non-negative values stay
        // bare, since LIMIT and OFFSET accept only an integer token.
        if (digits[0] == '-') try w.byte('(');
        try w.append(digits);
        if (digits[0] == '-') try w.byte(')');
    } else if (oid == 16) {
        if (keyword(bytes, "t") or keyword(bytes, "true") or keyword(bytes, "yes") or keyword(bytes, "on") or equal(bytes, "1")) try w.append("TRUE") else if (keyword(bytes, "f") or keyword(bytes, "false") or keyword(bytes, "no") or keyword(bytes, "off") or equal(bytes, "0")) try w.append("FALSE") else return error.TypeMismatch;
    } else try quoted(w, bytes);
}
