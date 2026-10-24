//! PostgreSQL v3 wire protocol over caller-owned input/output buffers (Layer 1).
//! No socket, allocator, borrowed statement, or borrowed parameter storage.
//! Configure SCRAM before startup for credential authentication. Trust mode is
//! intended only for a caller that explicitly binds to a trusted interface.
//! SQL semantics are those provided by DB; unsupported features return SQLSTATE.
const scram = @import("scram");
const pg_types = @import("pg_types.sig");
pub const max_packet: usize = 16384;
pub const sql_capacity: usize = 4096;
pub const statement_capacity: usize = 8;
pub const portal_capacity: usize = 8;
pub const parameter_capacity: usize = 32;
/// A CancelRequest's key; the caller looks it up (the codec never does).
pub const Cancel = struct { pid: u32, secret: u32 };
/// `blocked`: the message's statement is parked on a lock (consumed =
/// written = 0); re-deliver the same bytes when the store reports progress.
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
    const T = pg_types.Types(DB.Result);
    return struct {
        const Self = @This();
        const utc_session: T.Session = .{};

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
            oids: [parameter_capacity]u32 = @splat(0),
            fn source(self: *const Statement) []const u8 {
                return self.sql[0..self.len];
            }
        };
        const Portal = struct {
            live: bool = false,
            name: Name = .{},
            sql: [sql_capacity]u8 = @splat(0),
            len: usize = 0,
            formats: [256]u16 = @splat(0),
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
        startup: bool = false,
        failed: bool = false,
        authentication: ?scram.Server = null,
        statements: [statement_capacity]Statement = @splat(.{}),
        portals: [portal_capacity]Portal = @splat(.{}),
        result: DB.Result = .{},
        active_portal: ?usize = null,
        commit_rolled_back: bool = false,
        backend_pid: u32 = 1,
        backend_secret: u32 = 0,

        /// Copy a verifier and a fresh CSPRNG nonce before any startup bytes.
        /// Every accepted connection needs its own unpredictable nonce; the
        /// protocol layer intentionally owns no RNG or transport configuration.
        pub fn configureAuthentication(self: *Self, verifier: *const scram.Verifier, server_nonce: []const u8) scram.Error!void {
            if (self.startup or self.authentication != null) return error.AuthenticationState;
            self.authentication = try scram.Server.init(verifier, server_nonce);
        }

        /// An output of this size is sufficient before any SQL mutation occurs.
        pub fn responseCapacity() usize {
            return @sizeOf(DB.Result) * 2 + 4096;
        }

        pub fn handle(self: *Self, db: *DB, input: []const u8, output: []u8) error{BufferTooSmall}!Reply {
            if (output.len < responseCapacity()) return error.BufferTooSmall;
            if (self.authentication) |*auth| if (auth.state == .failed) return .{ .close = true };
            const prefix: usize = if (self.startup) 1 else 0;
            if (input.len < prefix + 4) return .{};
            const size = read32(input[prefix..][0..4]);
            var w: Writer = .{ .bytes = output };
            if (size < 4 or size > max_packet) {
                try failure(&w, "08P01", "invalid packet length");
                return .{ .consumed = @min(input.len, prefix + 4), .written = w.at, .close = true };
            }
            const total: usize = @as(usize, size) + prefix;
            if (input.len < total) return .{};
            // Cancellation has no response in PostgreSQL: the key goes to the
            // caller, which owns the backend-key registry.
            if (!self.startup and total >= 8 and read32(input[4..8]) == 80877102 and total == 16)
                return .{ .consumed = total, .close = true, .cancel = .{ .pid = read32(input[8..12]), .secret = read32(input[12..16]) } };
            var close = false;
            if (!self.startup) {
                self.handshake(db, input[4..total], &w) catch |err| {
                    w.at = 0;
                    try failure(&w, sqlstate(err), @errorName(err));
                    close = true;
                };
            } else if (self.authentication != null and self.authentication.?.state != .complete) {
                self.authenticate(db, input[0], input[5..total], &w) catch {
                    self.authentication.?.state = .failed;
                    w.at = 0;
                    try authenticationFailure(&w);
                    close = true;
                };
            } else {
                const tag = input[0];
                if (self.failed and tag != 'S' and tag != 'X') return .{ .consumed = total };
                close = self.dispatch(db, tag, input[5..total], &w) catch |err| blk: {
                    const any: anyerror = err;
                    // Parked statement: nothing consumed or written.
                    if (any == error.WouldBlock) return .{ .blocked = true };
                    w.at = 0;
                    try failure(&w, sqlstate(err), @errorName(err));
                    if (@hasDecl(DB, "failTransaction")) db.failTransaction();
                    if (tag == 'Q') try self.ready(db, &w) else self.failed = true;
                    break :blk false;
                };
            }
            return .{ .consumed = total, .written = w.at, .close = close };
        }
        /// RAMSQL-supplied BackendKeyData (pid, secret) sent after authentication.
        pub fn configureBackendKey(self: *Self, pid: u32, secret: u32) void {
            self.backend_pid = pid;
            self.backend_secret = secret;
        }

        fn handshake(self: *Self, db: *DB, payload: []const u8, w: *Writer) !void {
            var r: Reader = .{ .bytes = payload };
            const version = try r.u32be();
            if (version == 80877103 or version == 80877104) {
                try r.done();
                try w.byte('N');
                return;
            }
            if (version != 196608) return error.UnsupportedProtocol;
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
            if (self.authentication) |*auth| {
                auth.setUsername(user.?);
                const p = try w.begin('R');
                try w.u32be(10);
                try w.string(scram.mechanism);
                try w.byte(0);
                w.end(p);
                self.startup = true;
                return;
            }
            try self.authenticationComplete(db, w);
        }
        fn authenticate(self: *Self, db: *DB, tag: u8, payload: []const u8, w: *Writer) !void {
            if (tag != 'p' or payload.len > scram.max_message + 64) return error.AuthenticationFailed;
            const auth = &self.authentication.?;
            var message: [512]u8 = undefined;
            if (auth.state == .initial) {
                var r: Reader = .{ .bytes = payload };
                if (!equal(try r.string(), scram.mechanism)) return error.AuthenticationFailed;
                const length = try r.u32be();
                if (length > scram.max_message) return error.AuthenticationFailed;
                const first = try r.take(length);
                try r.done();
                const challenge = try auth.start(first, &message);
                const p = try w.begin('R');
                try w.u32be(11);
                try w.append(challenge);
                w.end(p);
            } else if (auth.state == .challenge) {
                const final = try auth.finish(payload, &message);
                const p = try w.begin('R');
                try w.u32be(12);
                try w.append(final);
                w.end(p);
                try self.authenticationComplete(db, w);
            } else return error.AuthenticationFailed;
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
            _ = self;
            // Changed reported settings precede ReadyForQuery, as PostgreSQL's
            // ReportChangedGUCOptions.
            if (@hasDecl(DB, "takeParameterChanges")) try reportParameters(db, w, db.takeParameterChanges());
            const p = try w.begin('Z');
            try w.byte(if (@hasDecl(DB, "transactionStatus")) db.transactionStatus() else 'I');
            w.end(p);
        }
        fn dispatch(self: *Self, db: *DB, tag: u8, body: []const u8, w: *Writer) !bool {
            var r: Reader = .{ .bytes = body };
            switch (tag) {
                'Q' => {
                    const source = try r.string();
                    try r.done();
                    if (self.active_portal != null and !word(source, "commit") and !word(source, "rollback") and !word(source, "end") and !word(source, "abort")) return error.PortalBusy;
                    self.active_portal = null;
                    for (&self.statements) |*s| if (s.name.len == 0) {
                        s.live = false;
                    };
                    for (&self.portals) |*p| if (p.name.len == 0) {
                        p.live = false;
                    };
                    if (trim(source).len == 0) try w.empty('I') else {
                        try self.execute(db, source);
                        if (self.result.column_count != 0) {
                            try self.description(w, null);
                            try self.rows(db, w, null, 0, self.result.row_count);
                        }
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
                    const name = try r.string();
                    const limit = try r.u32be();
                    try r.done();
                    if (limit > 0x7fffffff) return error.ProtocolViolation;
                    const p = try self.portal(name);
                    if (!word(p.source(), "select") and p.format_count > 1) return error.ProtocolViolation;
                    const index = (@intFromPtr(p) - @intFromPtr(&self.portals[0])) / @sizeOf(Portal);
                    if (self.active_portal) |active| {
                        if (active != index) return error.PortalBusy;
                    }
                    if (p.complete) {
                        try commandFor(w, p.source(), p.command, p.result_rows, p.affected, p.rolled_back);
                        return false;
                    }
                    if (self.active_portal == null) {
                        try self.execute(db, p.source());
                        self.active_portal = index;
                        p.row = 0;
                        p.result_rows = self.result.row_count;
                        p.affected = self.result.affected_rows;
                        p.rolled_back = self.commit_rolled_back;
                        p.command = self.completed();
                    }
                    if (p.format_count > 1 and p.format_count != self.result.column_count) return error.ProtocolViolation;
                    const end = if (limit == 0) self.result.row_count else @min(self.result.row_count, p.row + limit);
                    try self.rows(db, w, p, p.row, end);
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
                    if (!@hasDecl(DB, "transactionStatus") or db.transactionStatus() == 'I') {
                        for (&self.portals) |*p| p.live = false;
                        self.active_portal = null;
                    }
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
        fn execute(self: *Self, db: *DB, source: []const u8) !void {
            self.result.column_count = 0;
            self.result.row_count = 0;
            self.result.affected_rows = 0;
            if (@hasField(DB.Result, "command")) self.result.command = .none;
            self.commit_rolled_back = false;
            const command_source = trim(source);
            if (keyword(command_source, "begin") or keyword(command_source, "begin work") or keyword(command_source, "begin transaction") or keyword(command_source, "start transaction")) {
                if (@hasDecl(DB, "transactionStatus") and db.transactionStatus() == 'E') return error.TransactionFailed;
                if (@hasDecl(DB, "beginTransaction")) try db.beginTransaction() else return error.UnsupportedStatement;
            } else if (keyword(command_source, "commit") or keyword(command_source, "commit work") or keyword(command_source, "commit transaction") or keyword(command_source, "end")) {
                if (@hasDecl(DB, "transactionStatus")) self.commit_rolled_back = db.transactionStatus() == 'E';
                if (@hasDecl(DB, "commitTransaction")) try db.commitTransaction() else return error.UnsupportedStatement;
            } else if (keyword(command_source, "rollback") or keyword(command_source, "rollback work") or keyword(command_source, "rollback transaction") or keyword(command_source, "abort")) {
                if (@hasDecl(DB, "rollbackTransaction")) try db.rollbackTransaction() else return error.UnsupportedStatement;
            } else if (word(source, "deallocate")) {
                if (@hasDecl(DB, "transactionStatus") and db.transactionStatus() == 'E') return error.TransactionFailed;
                try self.deallocate(source);
            } else {
                try db.execute(source, &self.result);
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
        fn describeOnly(self: *Self, db: *DB, source: []const u8) !void {
            self.result.column_count = 0;
            self.result.row_count = 0;
            const command_source = trim(source);
            if (word(command_source, "begin") or word(command_source, "commit") or word(command_source, "rollback") or
                word(command_source, "end") or word(command_source, "abort") or word(command_source, "deallocate") or
                word(command_source, "start")) return;
            try db.describe(source, &self.result);
        }

        fn deallocate(self: *Self, source: []const u8) !void {
            var tokens: Tokens = .{ .source = source };
            if (!keyword(tokens.next(), "deallocate")) return error.Syntax;
            var name = tokens.next();
            if (keyword(name, "prepare")) name = tokens.next();
            if (name.len == 0) return error.Syntax;
            var next = tokens.next();
            if (equal(next, ";")) next = tokens.next();
            if (next.len != 0) return error.Syntax;
            if (keyword(name, "all")) {
                for (&self.statements) |*s| s.live = false;
                return;
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
            var next: Statement = .{};
            try next.name.set(name);
            next.len = source.len;
            @memcpy(next.sql[0..source.len], source);
            const count = try r.u16be();
            if (count > parameter_capacity) return error.ParameterCapacity;
            for (0..count) |i| next.oids[i] = try r.u32be();
            try r.done();
            next.count = try parameterCount(source);
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
            next.live = true;
            s.* = next;
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
            const first = tokens.next();
            var table: []const u8 = "";
            if (keyword(first, "insert")) {
                if (!keyword(tokens.next(), "into")) return error.Syntax;
                table = tokens.next();
            } else if (keyword(first, "update")) table = tokens.next() else if (keyword(first, "select") or keyword(first, "delete")) {
                while (true) {
                    const token = tokens.next();
                    if (token.len == 0) break;
                    if (keyword(token, "from")) {
                        table = tokens.next();
                        break;
                    }
                }
            }
            if (table.len == 0 or !identifier(table)) return error.UnsupportedStatement;
            var text: [sql_capacity]u8 = undefined;
            var q: Writer = .{ .bytes = &text };
            try q.append("SELECT * FROM ");
            try q.append(table);
            try q.append(" LIMIT 0");
            if (@hasDecl(DB, "describe")) try db.describe(q.bytes[0..q.at], &self.result) else try db.execute(q.bytes[0..q.at], &self.result);
            if (self.result.column_count > 256) return error.ColumnCapacity;
            if (keyword(first, "insert")) {
                var mapping: [256]usize = undefined;
                var count_columns = self.result.column_count;
                for (0..count_columns) |i| mapping[i] = i;
                var token = tokens.next();
                if (equal(token, "(")) {
                    count_columns = 0;
                    while (true) {
                        token = tokens.next();
                        if (equal(token, ")")) break;
                        if (equal(token, ",")) continue;
                        if (count_columns == mapping.len) return error.ColumnCapacity;
                        mapping[count_columns] = self.column(token) orelse return error.ColumnNotFound;
                        count_columns += 1;
                    }
                    token = tokens.next();
                }
                if (!keyword(token, "values") or !equal(tokens.next(), "(")) return error.Syntax;
                var column_index: usize = 0;
                while (true) {
                    token = tokens.next();
                    if (token.len == 0) return error.Syntax;
                    if (equal(token, ")")) break;
                    if (equal(token, ",")) {
                        column_index += 1;
                        continue;
                    }
                    if (token[0] == '$') {
                        if (column_index >= count_columns) return error.ColumnCapacity;
                        try inferOid(s, token, T.oid(self.result.column_types[mapping[column_index]]));
                    }
                }
            } else {
                tokens = .{ .source = s.source() };
                var column_index: ?usize = null;
                while (true) {
                    const token = tokens.next();
                    if (token.len == 0) break;
                    if (token[0] == '$') {
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
            for (0..count) |i| {
                const begin = l.at;
                const size = try r.u32be();
                if (size == 0xffffffff) try l.append("NULL") else {
                    const bytes = try r.take(size);
                    const fmt = if (nf == 0) 0 else formats[if (nf == 1) 0 else i];
                    if (T.handles(s.oids[i])) {
                        l.at += T.literal(bytes, s.oids[i], fmt, l.bytes[l.at..]) catch |err| return if (err == error.BufferTooSmall) error.StatementCapacity else err;
                    } else try literal(&l, bytes, s.oids[i], fmt);
                }
                values[i] = l.bytes[begin..l.at];
            }
            var next: Portal = .{};
            try next.name.set(name);
            next.format_count = try r.u16be();
            if (next.format_count > next.formats.len) return error.ColumnCapacity;
            for (0..next.format_count) |i| {
                next.formats[i] = try r.u16be();
                if (next.formats[i] > 1) return error.ProtocolViolation;
            }
            try r.done();
            var q: Writer = .{ .bytes = &next.sql };
            try interpolate(s.source(), values[0..count], &q);
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
            next.live = true;
            p.* = next;
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
                try w.u32be(T.oid(data_type));
                try w.u16be(@bitCast(T.length(data_type)));
                const typmod: i32 = if (@hasField(DB.Result, "column_typmods")) self.result.column_typmods[i] else -1;
                try w.u32be(@bitCast(typmod));
                if (portal_value) |v| {
                    if (v.format_count > 1 and v.format_count != self.result.column_count) return error.ProtocolViolation;
                    try w.u16be(v.format(i));
                } else try w.u16be(0);
            }
            w.end(p);
        }
        fn rows(self: *Self, db: *DB, w: *Writer, portal_value: ?*const Portal, first: usize, end: usize) !void {
            const session = valueSession(db);
            for (first..end) |row| {
                const p = try w.begin('D');
                try w.u16be(@intCast(self.result.column_count));
                for (0..self.result.column_count) |i| {
                    const cell = self.result.rows[row].cells[i];
                    if (cell == .null_value) {
                        try w.u32be(0xffffffff);
                        continue;
                    }
                    const length = w.at;
                    try w.u32be(0);
                    const start = w.at;
                    const binary = if (portal_value) |v| v.format(i) == 1 else false;
                    switch (cell) {
                        .null_value => unreachable,
                        .integer => |n| if (binary) {
                            w.at += T.sendBinary(&cell, self.result.column_types[i], session, w.bytes[w.at..]) catch return error.BufferTooSmall;
                        } else try w.number(n),
                        .boolean => |b| try w.byte(if (binary) @intFromBool(b) else if (b) 't' else 'f'),
                        .text => |t| try w.append(t.slice()),
                        else => w.at += (if (binary) T.sendBinary(&cell, self.result.column_types[i], session, w.bytes[w.at..]) else T.sendText(&cell, session, w.bytes[w.at..])) catch return error.BufferTooSmall,
                    }
                    write32(w.bytes[length..][0..4], @intCast(w.at - start));
                }
                w.end(p);
            }
        }
        fn command(self: *Self, w: *Writer, source: []const u8) !void {
            try commandFor(w, source, self.completed(), self.result.row_count, self.result.affected_rows, self.commit_rolled_back);
        }
        /// The engine's own command tag for the last statement, when it has one.
        fn completed(self: *const Self) []const u8 {
            if (!@hasField(DB.Result, "command")) return "";
            return switch (self.result.command) {
                .select => "select",
                .insert => "insert",
                .update => "update",
                .delete => "delete",
                .create_table => "create",
                .drop_table => "drop",
                .begin => "begin",
                .commit => "commit",
                .rollback => "rollback",
                .savepoint => "savepoint",
                .release => "release",
                .set => "set",
                .show => "show",
                .reset => "reset",
                else => "",
            };
        }
        fn isCommand(completed_command: []const u8, source: []const u8, wanted: []const u8) bool {
            return if (completed_command.len != 0) equal(completed_command, wanted) else word(source, wanted);
        }
        fn commandFor(w: *Writer, source: []const u8, completed_command: []const u8, row_count: usize, affected: usize, rolled_back: bool) !void {
            const p = try w.begin('C');
            if (isCommand(completed_command, source, "select")) {
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
            } else if (isCommand(completed_command, source, "create")) try w.append("CREATE TABLE") else if (isCommand(completed_command, source, "drop")) try w.append("DROP TABLE") else if (equal(completed_command, "savepoint")) try w.append("SAVEPOINT") else if (equal(completed_command, "release")) try w.append("RELEASE") else if (equal(completed_command, "show")) try w.append("SHOW") else if (equal(completed_command, "reset")) try w.append("RESET") else if (equal(completed_command, "set")) try w.append("SET") else if (equal(completed_command, "begin")) try w.append("BEGIN") else if (equal(completed_command, "commit")) try w.append(if (rolled_back) "ROLLBACK" else "COMMIT") else if (equal(completed_command, "rollback")) try w.append("ROLLBACK") else if (word(source, "begin") or word(source, "start")) try w.append("BEGIN") else if (word(source, "commit") or word(source, "end")) try w.append(if (rolled_back) "ROLLBACK" else "COMMIT") else if (word(source, "rollback") or word(source, "abort")) try w.append("ROLLBACK") else if (word(source, "set")) try w.append("SET") else if (word(source, "deallocate")) try w.append("DEALLOCATE") else try w.append("OK");
            try w.byte(0);
            w.end(p);
        }
    };
}

fn parameter(w: *Writer, key: []const u8, value: []const u8) !void {
    const p = try w.begin('S');
    try w.string(key);
    try w.string(value);
    w.end(p);
}
fn failure(w: *Writer, state: []const u8, message: []const u8) !void {
    const p = try w.begin('E');
    try w.byte('S');
    try w.string("ERROR");
    try w.byte('V');
    try w.string("ERROR");
    try w.byte('C');
    try w.string(state);
    try w.byte('M');
    try w.string(message);
    try w.byte(0);
    w.end(p);
}
fn authenticationFailure(w: *Writer) !void {
    const p = try w.begin('E');
    try w.byte('S');
    try w.string("FATAL");
    try w.byte('V');
    try w.string("FATAL");
    try w.byte('C');
    try w.string("28P01");
    try w.byte('M');
    try w.string("password authentication failed");
    try w.byte(0);
    w.end(p);
}
fn sqlstate(err: anyerror) []const u8 {
    return knownSqlstate(err) orelse "54000";
}

/// SQLSTATE for every engine, store and protocol error this codec knows;
/// null means the error would fall back to 54000 (program_limit_exceeded).
pub fn knownSqlstate(err: anyerror) ?[]const u8 {
    const name = @errorName(err);
    if (equal(name, "UndefinedFunction")) return "42883";
    if (equal(name, "AmbiguousFunction")) return "42725";
    if (equal(name, "CannotCoerce")) return "42846";
    if (equal(name, "InvalidTextRepresentation")) return "22P02";
    if (equal(name, "DivisionByZero")) return "22012";
    if (equal(name, "InvalidEscapeSequence")) return "22025";
    if (equal(name, "UndefinedParameter")) return "42P02";
    if (equal(name, "InvalidColumnReference")) return "42P10";
    if (equal(name, "NumericValueOutOfRange")) return "22003";
    if (equal(name, "NumericCapacity")) return "54000";
    if (equal(name, "InvalidParameterValue")) return "22023";
    if (equal(name, "InvalidDatetimeFormat")) return "22007";
    if (equal(name, "DatetimeFieldOverflow")) return "22008";
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
    if (equal(name, "TypeMismatch")) return "42804";
    if (equal(name, "IntegerOverflow")) return "22003";
    if (equal(name, "ProtocolViolation")) return "08P01";
    if (equal(name, "StatementNotFound")) return "26000";
    if (equal(name, "PortalNotFound")) return "34000";
    if (equal(name, "DuplicateStatement")) return "42P05";
    if (equal(name, "DuplicatePortal")) return "42P03";
    if (equal(name, "TransactionFailed")) return "25P02";
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

// One scanner serves counting and interpolation, so $ inside a quoted literal,
// quoted identifier, or line comment can never become a parameter substitution.
fn scan(source: []const u8, values: ?[]const []const u8, w: ?*Writer) !usize {
    var i: usize = 0;
    var highest: usize = 0;
    var quote: u8 = 0;
    var comment = false;
    while (i < source.len) {
        const c = source[i];
        if (comment) {
            if (c == '\n') comment = false;
        } else if (quote != 0) {
            if (c == quote) {
                if (i + 1 < source.len and source[i + 1] == quote) {
                    if (w) |out| try out.append(source[i..][0..2]);
                    i += 2;
                    continue;
                }
                quote = 0;
            }
        } else if (c == '\'' or c == '"') quote = c else if (c == '-' and i + 1 < source.len and source[i + 1] == '-') comment = true else if (c == '$') {
            var j = i + 1;
            var n: usize = 0;
            while (j < source.len and source[j] >= '0' and source[j] <= '9') : (j += 1) {
                n = n * 10 + source[j] - '0';
                if (n > parameter_capacity) return error.ParameterCapacity;
            }
            if (j == i + 1 or n == 0) return error.Syntax;
            highest = @max(highest, n);
            if (values) |v| {
                if (n > v.len) return error.ProtocolViolation;
                if (w) |out| try out.append(v[n - 1]);
            }
            i = j;
            continue;
        }
        if (w) |out| try out.byte(c);
        i += 1;
    }
    return highest;
}
fn parameterCount(source: []const u8) !usize {
    return scan(source, null, null);
}
fn interpolate(source: []const u8, values: []const []const u8, w: *Writer) !void {
    _ = try scan(source, values, w);
}
fn identifier(token: []const u8) bool {
    if (token.len == 0) return false;
    const first = lower(token[0]);
    return (first >= 'a' and first <= 'z') or first == '_';
}
const Tokens = struct {
    source: []const u8,
    at: usize = 0,
    fn next(self: *Tokens) []const u8 {
        while (self.at < self.source.len) {
            const c = self.source[self.at];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.at += 1;
                continue;
            }
            if (c == '-' and self.at + 1 < self.source.len and self.source[self.at + 1] == '-') {
                while (self.at < self.source.len and self.source[self.at] != '\n') : (self.at += 1) {}
                continue;
            }
            break;
        }
        const begin = self.at;
        if (begin == self.source.len) return "";
        self.at += 1;
        const first = self.source[begin];
        if (first == '\'' or first == '"') {
            while (self.at < self.source.len) {
                const c = self.source[self.at];
                self.at += 1;
                if (c == first) {
                    if (self.at < self.source.len and self.source[self.at] == first) {
                        self.at += 1;
                        continue;
                    }
                    break;
                }
            }
        } else if (identifier(self.source[begin .. begin + 1]) or first == '$' or (first >= '0' and first <= '9')) {
            while (self.at < self.source.len) : (self.at += 1) {
                const c = lower(self.source[self.at]);
                if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) break;
            }
        }
        return self.source[begin..self.at];
    }
};
fn inferOid(s: anytype, token: []const u8, oid: u32) !void {
    var n: usize = 0;
    for (token[1..]) |c| {
        if (c < '0' or c > '9') return error.Syntax;
        n = n * 10 + c - '0';
        if (n > parameter_capacity) return error.ParameterCapacity;
    }
    if (n == 0 or n > s.count) return error.ProtocolViolation;
    const previous = s.oids[n - 1];
    const integer_conversion = (oid == 20 or oid == 23) and (previous == 20 or previous == 21 or previous == 23);
    if (previous != 0 and previous != oid and !integer_conversion) return error.TypeMismatch;
    if (previous == 0) s.oids[n - 1] = oid;
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
fn literal(w: *Writer, bytes: []const u8, oid: u32, format: u16) !void {
    if (format == 1) {
        if (oid == 16) {
            if (bytes.len != 1 or bytes[0] > 1) return error.ProtocolViolation;
            try w.append(if (bytes[0] == 1) "TRUE" else "FALSE");
        } else if (oid == 20 or oid == 21 or oid == 23) {
            const count: usize = if (oid == 20) 8 else if (oid == 21) 2 else 4;
            if (bytes.len != count) return error.ProtocolViolation;
            var bits: u64 = if (bytes[0] & 128 != 0) 0xffffffffffffffff else 0;
            for (bytes) |b| bits = (bits << 8) | b;
            try w.number(@bitCast(bits));
        } else if (oid == 25 or oid == 1043 or oid == 1042) try quoted(w, bytes) else return error.UnsupportedBinaryType;
    } else if (oid == 20 or oid == 21 or oid == 23 or (oid == 0 and integerText(bytes))) {
        if (!integerText(bytes)) return error.TypeMismatch;
        try w.append(if (bytes[0] == '+') bytes[1..] else bytes);
    } else if (oid == 16) {
        if (keyword(bytes, "t") or keyword(bytes, "true") or keyword(bytes, "yes") or keyword(bytes, "on") or equal(bytes, "1")) try w.append("TRUE") else if (keyword(bytes, "f") or keyword(bytes, "false") or keyword(bytes, "no") or keyword(bytes, "off") or equal(bytes, "0")) try w.append("FALSE") else return error.TypeMismatch;
    } else try quoted(w, bytes);
}
