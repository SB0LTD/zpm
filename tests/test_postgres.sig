//! Executable PostgreSQL protocol contracts, including malformed framing.
const std = @import("std");
const pg = @import("postgres");
const scram = @import("scram");
const sql = @import("sql");
const Raw = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 4, .text_bytes = 64 });
const DB = struct {
    pub const Result = Raw.Result;
    raw: Raw = .{},
    snapshot: Raw = .{},
    status: u8 = 'I',
    forced_error: ?anyerror = null,
    pub fn execute(self: *@This(), source: []const u8, result: *Result) !void {
        if (self.status == 'E') return error.TransactionFailed;
        if (self.forced_error) |err| {
            self.failTransaction();
            return err;
        }
        self.raw.execute(source, result) catch |err| {
            self.failTransaction();
            return err;
        };
    }
    pub fn beginTransaction(self: *@This()) !void {
        if (self.status == 'I') {
            self.snapshot = self.raw;
            self.status = 'T';
        }
    }
    pub fn commitTransaction(self: *@This()) !void {
        if (self.status == 'E') self.raw = self.snapshot;
        self.status = 'I';
    }
    pub fn rollbackTransaction(self: *@This()) !void {
        if (self.status != 'I') self.raw = self.snapshot;
        self.status = 'I';
    }
    pub fn failTransaction(self: *@This()) void {
        if (self.status == 'T') self.status = 'E';
    }
    pub fn transactionStatus(self: *@This()) u8 {
        return self.status;
    }
};
const Session = pg.Session(DB);
var assertions: usize = 0;
var packets: usize = 0;
var fuzz_inputs: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.PostgresContractFailed;
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn u32be(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}
fn put32(b: []u8, n: u32) void {
    b[0] = @truncate(n >> 24);
    b[1] = @truncate(n >> 16);
    b[2] = @truncate(n >> 8);
    b[3] = @truncate(n);
}
const Packet = struct {
    bytes: [pg.max_packet + 1]u8 = @splat(0),
    len: usize = 5,
    fn init(tag: u8) Packet {
        var p: Packet = .{};
        p.bytes[0] = tag;
        return p;
    }
    fn append(self: *Packet, b: []const u8) void {
        @memcpy(self.bytes[self.len..][0..b.len], b);
        self.len += b.len;
    }
    fn byte(self: *Packet, b: u8) void {
        self.bytes[self.len] = b;
        self.len += 1;
    }
    fn string(self: *Packet, b: []const u8) void {
        self.append(b);
        self.byte(0);
    }
    fn number16(self: *Packet, n: u16) void {
        self.byte(@truncate(n >> 8));
        self.byte(@truncate(n));
    }
    fn number32(self: *Packet, n: u32) void {
        put32(self.bytes[self.len..][0..4], n);
        self.len += 4;
    }
    fn slice(self: *Packet) []const u8 {
        put32(self.bytes[1..5], @intCast(self.len - 1));
        return self.bytes[0..self.len];
    }
};
const Frames = struct {
    const Frame = struct { tag: u8, body: []const u8 };
    bytes: []const u8,
    at: usize = 0,
    fn next(self: *Frames) !?Frame {
        if (self.at == self.bytes.len) return null;
        try check(self.bytes.len - self.at >= 5);
        const n = u32be(self.bytes[self.at + 1 ..][0..4]);
        try check(n >= 4 and n <= self.bytes.len - self.at - 1);
        const result: Frame = .{ .tag = self.bytes[self.at], .body = self.bytes[self.at + 5 .. self.at + 1 + n] };
        self.at += 1 + n;
        return result;
    }
};
fn tags(bytes: []const u8, wanted: []const u8) !void {
    var frames: Frames = .{ .bytes = bytes };
    for (wanted) |tag| {
        const f = (try frames.next()) orelse return error.MissingFrame;
        try check(f.tag == tag);
    }
    try check((try frames.next()) == null);
}
fn state(bytes: []const u8, wanted: []const u8) !void {
    var f: Frames = .{ .bytes = bytes };
    const first = (try f.next()) orelse return error.MissingError;
    try check(first.tag == 'E');
    var i: usize = 0;
    while (i < first.body.len and first.body[i] != 0) {
        const kind = first.body[i];
        i += 1;
        const begin = i;
        while (i < first.body.len and first.body[i] != 0) : (i += 1) {}
        try check(i < first.body.len);
        if (kind == 'C') {
            try check(equal(first.body[begin..i], wanted));
            return;
        }
        i += 1;
    }
    return error.MissingSqlstate;
}
var output: [Session.responseCapacity()]u8 = undefined;
fn send(s: *Session, db: *DB, p: *Packet) ![]const u8 {
    const bytes = p.slice();
    const reply = try s.handle(db, bytes, &output);
    try check(reply.consumed == bytes.len and !reply.close);
    packets += 1;
    return output[0..reply.written];
}
fn query(s: *Session, db: *DB, source: []const u8) ![]const u8 {
    var p = Packet.init('Q');
    p.string(source);
    return send(s, db, &p);
}
fn sync(s: *Session, db: *DB) !void {
    var p = Packet.init('S');
    try tags(try send(s, db, &p), "Z");
}
fn startup(s: *Session, db: *DB) !void {
    const ssl = "\x00\x00\x00\x08\x04\xd2\x16\x2f";
    const reply = try s.handle(db, ssl, &output);
    try check(reply.consumed == 8 and reply.written == 1 and output[0] == 'N' and !s.startup);
    const gss = "\x00\x00\x00\x08\x04\xd2\x16\x30";
    const gss_reply = try s.handle(db, gss, &output);
    try check(gss_reply.written == 1 and output[0] == 'N');
    var p = Packet.init(0);
    p.len = 4;
    p.number32(196608);
    p.string("user");
    p.string("ramsql");
    p.string("database");
    p.string("test");
    p.byte(0);
    put32(p.bytes[0..4], @intCast(p.len));
    for (0..p.len) |n| {
        const partial = try s.handle(db, p.bytes[0..n], &output);
        try check(partial.consumed == 0 and partial.written == 0 and !s.startup);
    }
    const ready = try s.handle(db, p.bytes[0..p.len], &output);
    try check(ready.consumed == p.len and s.startup and !ready.close);
    try tags(output[0..ready.written], "RSSSSSSSKZ");
}
fn parse(s: *Session, db: *DB, name: []const u8, source: []const u8, oids: []const u32) ![]const u8 {
    var p = Packet.init('P');
    p.string(name);
    p.string(source);
    p.number16(@intCast(oids.len));
    for (oids) |oid| p.number32(oid);
    return send(s, db, &p);
}
fn bind(s: *Session, db: *DB, name: []const u8, statement: []const u8, values: []const ?[]const u8, format: u16, result_format: u16) ![]const u8 {
    var p = Packet.init('B');
    p.string(name);
    p.string(statement);
    p.number16(1);
    p.number16(format);
    p.number16(@intCast(values.len));
    for (values) |v| {
        if (v) |b| {
            p.number32(@intCast(b.len));
            p.append(b);
        } else p.number32(0xffffffff);
    }
    p.number16(1);
    p.number16(result_format);
    return send(s, db, &p);
}
fn describe(s: *Session, db: *DB, kind: u8, name: []const u8) ![]const u8 {
    var p = Packet.init('D');
    p.byte(kind);
    p.string(name);
    return send(s, db, &p);
}
fn execute(s: *Session, db: *DB, name: []const u8, limit: u32) ![]const u8 {
    var p = Packet.init('E');
    p.string(name);
    p.number32(limit);
    return send(s, db, &p);
}
fn close(s: *Session, db: *DB, kind: u8, name: []const u8) ![]const u8 {
    var p = Packet.init('C');
    p.byte(kind);
    p.string(name);
    return send(s, db, &p);
}

fn normal() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    try tags(try query(&s, &db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)"), "CZ");
    try tags(try query(&s, &db, "INSERT INTO notes VALUES (1, 'hello', TRUE)"), "CZ");
    const selected = try query(&s, &db, "SELECT * FROM notes");
    try tags(selected, "TDCZ");
    var frames: Frames = .{ .bytes = selected };
    const description = (try frames.next()).?;
    try check(description.body[0] == 0 and description.body[1] == 3);
    const row = (try frames.next()).?;
    try check(equal(row.body, "\x00\x03\x00\x00\x00\x011\x00\x00\x00\x05hello\x00\x00\x00\x01t"));
    try tags(try query(&s, &db, "SELECT * FROM notes WHERE id = 999"), "TCZ");
    try tags(try query(&s, &db, " ; \t\n"), "IZ");
    const duplicate = try query(&s, &db, "INSERT INTO notes VALUES (1,'bad',FALSE)");
    try tags(duplicate, "EZ");
    try state(duplicate, "23505");
    try tags(try query(&s, &db, "SELECT body FROM notes"), "TDCZ");
    try check(equal(s.result.rows[0].cells[0].text.slice(), "hello"));
    const missing = try query(&s, &db, "SELECT * FROM missing");
    try state(missing, "42P01");
    try tags(try query(&s, &db, "BEGIN"), "CZ");
    try check(db.status == 'T');
    try tags(try query(&s, &db, "DELETE FROM notes"), "CZ");
    try tags(try query(&s, &db, "ROLLBACK"), "CZ");
    try check(db.status == 'I');
    try tags(try query(&s, &db, "SELECT * FROM notes"), "TDCZ");
    _ = try query(&s, &db, "BEGIN");
    _ = try query(&s, &db, "SELECT * FROM missing");
    try check(db.status == 'E');
    try state(try query(&s, &db, "SELECT * FROM notes"), "25P02");
    _ = try query(&s, &db, "ROLLBACK");
    try state(try query(&s, &db, "BEGIN; DELETE FROM notes"), "0A000");
    try check(db.status == 'I');
    try state(try query(&s, &db, "COMMIT junk"), "0A000");
    try check(db.status == 'I');
    var terminate = Packet.init('X');
    const reply = try s.handle(&db, terminate.slice(), &output);
    try check(reply.close and reply.written == 0);
}
fn extended() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    _ = try query(&s, &db, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)");
    try tags(try parse(&s, &db, "insert", "INSERT INTO notes VALUES ($1,$2,$3)", &.{ 20, 25, 16 }), "1");
    try tags(try bind(&s, &db, "", "insert", &.{ "42", "a'b; -- $1", "t" }, 0, 0), "2");
    try tags(try describe(&s, &db, 'P', ""), "n");
    try tags(try execute(&s, &db, "", 0), "C");
    try sync(&s, &db);
    try tags(try parse(&s, &db, "select", "SELECT * FROM notes WHERE id = $1", &.{20}), "1");
    try tags(try describe(&s, &db, 'S', "select"), "tT");
    try tags(try bind(&s, &db, "", "select", &.{"\x00\x00\x00\x00\x00\x00\x00\x2a"}, 1, 1), "2");
    const description = try describe(&s, &db, 'P', "");
    try tags(description, "T");
    const result = try execute(&s, &db, "", 0);
    try tags(result, "DC");
    var frames: Frames = .{ .bytes = result };
    const row = (try frames.next()).?;
    // INTEGER is int4 on the PostgreSQL path whatever integer_bits says.
    try check(u32be(row.body[2..6]) == 4 and equal(row.body[6..10], "\x00\x00\x00\x2a"));
    try check(equal(s.result.rows[0].cells[1].text.slice(), "a'b; -- $1"));
    try sync(&s, &db);
    try tags(try close(&s, &db, 'S', "insert"), "3");
    try tags(try parse(&s, &db, "null", "INSERT INTO notes VALUES ($1,$2,$3)", &.{ 20, 25, 16 }), "1");
    try tags(try bind(&s, &db, "", "null", &.{ "-1", null, null }, 0, 0), "2");
    try tags(try execute(&s, &db, "", 0), "C");
    try sync(&s, &db);
    try tags(try parse(&s, &db, "all", "SELECT * FROM notes ORDER BY id", &.{}), "1");
    try tags(try bind(&s, &db, "", "all", &.{}, 0, 0), "2");
    try tags(try bind(&s, &db, "other", "all", &.{}, 0, 0), "2");
    try tags(try describe(&s, &db, 'P', ""), "T");
    try tags(try execute(&s, &db, "", 1), "Ds");
    try check(s.active_portal != null);
    try tags(try close(&s, &db, 'P', "other"), "3");
    try check(s.active_portal != null);
    try tags(try execute(&s, &db, "", 1), "DC");
    try check(s.active_portal == null);
    try sync(&s, &db);
    try tags(try parse(&s, &db, "quoted", "SELECT * FROM notes WHERE body = '$9' -- $7", &.{}), "1");
    try state(try parse(&s, &db, "all", "SELECT * FROM notes", &.{}), "42P05");
    var ignored = Packet.init('P');
    ignored.string("");
    ignored.string("SELECT * FROM notes");
    ignored.number16(0);
    try tags(try send(&s, &db, &ignored), "");
    try sync(&s, &db);
    try state(try bind(&s, &db, "", "absent", &.{}, 0, 0), "26000");
    try sync(&s, &db);
    try state(try execute(&s, &db, "absent", 0), "34000");
    try sync(&s, &db);
}
fn inference() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    _ = try query(&s, &db, "CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT, ok BOOLEAN)");
    try tags(try parse(&s, &db, "insert", "INSERT INTO t (body,id,ok) VALUES ($1,$2,$3)", &.{}), "1");
    try tags(try describe(&s, &db, 'S', "insert"), "tn");
    try check(s.statements[0].oids[0] == 25 and s.statements[0].oids[1] == 23 and s.statements[0].oids[2] == 16);
    try tags(try bind(&s, &db, "", "insert", &.{ "123", "7", "true" }, 0, 0), "2");
    try tags(try execute(&s, &db, "", 0), "C");
    try sync(&s, &db);
    try tags(try parse(&s, &db, "where", "SELECT * FROM t WHERE body = $1 AND id = $2", &.{}), "1");
    try tags(try bind(&s, &db, "", "where", &.{ "123", "7" }, 0, 0), "2");
    try tags(try execute(&s, &db, "", 0), "DC");
    try check(equal(s.result.rows[0].cells[1].text.slice(), "123"));
    try sync(&s, &db);
    try tags(try parse(&s, &db, "update", "UPDATE t SET body = $1 WHERE id = $2", &.{}), "1");
    try tags(try bind(&s, &db, "", "update", &.{ "456", "7" }, 0, 0), "2");
    try tags(try execute(&s, &db, "", 0), "C");
    try sync(&s, &db);
    try tags(try parse(&s, &db, "mixed", "INSERT INTO t VALUES ($1,$2,$3)", &.{ 21, 0, 16 }), "1");
    try tags(try bind(&s, &db, "", "mixed", &.{ "\x00\x08", "999", "\x00" }, 1, 0), "2");
    try tags(try execute(&s, &db, "", 0), "C");
    try sync(&s, &db);
    try tags(try query(&s, &db, "SELECT body FROM t ORDER BY id"), "TDDCZ");
    try check(equal(s.result.rows[0].cells[0].text.slice(), "456") and equal(s.result.rows[1].cells[0].text.slice(), "999"));
}
fn statementLifecycle() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    _ = try query(&s, &db, "CREATE TABLE t (id INTEGER)");
    for (0..24) |i| {
        var names: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&names, "_pg3_{d}", .{i});
        try tags(try parse(&s, &db, name, "SELECT * FROM t", &.{}), "1");
        try tags(try bind(&s, &db, "", name, &.{}, 0, 0), "2");
        try tags(try execute(&s, &db, "", 0), "C");
        try sync(&s, &db);
        if (i % 2 == 0) {
            var sql_text: [128]u8 = undefined;
            const dealloc = try std.fmt.bufPrint(&sql_text, "DEALLOCATE \"{s}\"", .{name});
            try tags(try query(&s, &db, dealloc), "CZ");
        } else try tags(try close(&s, &db, 'S', name), "3");
    }
    try tags(try parse(&s, &db, "a", "SELECT * FROM t", &.{}), "1");
    try tags(try parse(&s, &db, "b", "SELECT * FROM t", &.{}), "1");
    try tags(try query(&s, &db, "DEALLOCATE PREPARE ALL;"), "CZ");
    for (s.statements) |statement| try check(!statement.live);
    try state(try query(&s, &db, "DEALLOCATE absent"), "26000");
    try tags(try parse(&s, &db, "c", "SELECT * FROM t", &.{}), "1");
    try state(try query(&s, &db, "DEALLOCATE c; DROP TABLE t"), "42601");
    try tags(try close(&s, &db, 'S', "c"), "3");
}
fn malformed() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    var p = Packet.init('Q');
    p.string("CREATE TABLE t (id INTEGER)");
    const packet = p.slice();
    for (0..packet.len) |i| {
        const reply = try s.handle(&db, packet[0..i], &output);
        try check(reply.consumed == 0 and reply.written == 0);
    }
    var tiny: [8]u8 = undefined;
    if (s.handle(&db, packet, &tiny)) |_| return error.SmallOutputAccepted else |err| try check(err == error.BufferTooSmall);
    try tags(try send(&s, &db, &p), "CZ");
    var nozero = Packet.init('Q');
    nozero.append("SELECT * FROM t");
    try state(try send(&s, &db, &nozero), "08P01");
    var extra = Packet.init('S');
    extra.byte(0);
    try state(try send(&s, &db, &extra), "08P01");
    try sync(&s, &db);
    var unknown = Packet.init('?');
    try state(try send(&s, &db, &unknown), "0A000");
    try sync(&s, &db);
    var bad = Packet.init('B');
    bad.string("");
    bad.string("");
    bad.number16(0xffff);
    try state(try send(&s, &db, &bad), "26000");
    try sync(&s, &db);
    try tags(try parse(&s, &db, "p", "SELECT * FROM t WHERE id = $1", &.{20}), "1");
    try state(try bind(&s, &db, "", "p", &.{"\x00"}, 1, 0), "08P01");
    try sync(&s, &db);
    try state(try bind(&s, &db, "", "p", &.{"1; DROP TABLE t"}, 0, 0), "42804");
    try sync(&s, &db);
    try tags(try bind(&s, &db, "", "p", &.{"1"}, 0, 0), "2");
    try state(try execute(&s, &db, "", 0xffffffff), "08P01");
    try sync(&s, &db);
    try tags(try query(&s, &db, "SELECT * FROM t"), "TCZ");
    var invalid: [5]u8 = .{ 'Q', 0, 0, 0, 3 };
    const reply = try s.handle(&db, &invalid, &output);
    try check(reply.close);
    try state(output[0..reply.written], "08P01");
    var oversized: [5]u8 = .{ 'Q', 0x7f, 0xff, 0xff, 0xff };
    const big = try s.handle(&db, &oversized, &output);
    try check(big.close and big.consumed == 5);
    var s2: Session = .{};
    const missing = "\x00\x00\x00\x09\x00\x03\x00\x00\x00";
    const missing_reply = try s2.handle(&db, missing, &output);
    try check(missing_reply.close and !s2.startup);
}
const scram_verifier = "SCRAM-SHA-256$4096:W22ZaJ0SNY7soEsUEjb6gQ==$WG5d8oPm3OtcPnkdi4Uo7BkeZkBFzpcXkuLmtbsT4qY=:wfPLwcE6nTWhTAmQ7tl2KeoiWGPlZqQxSrmfPwDl2dU=";
const scram_nonce = "%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
const scram_first = "n,,n=user,r=rOprNGfwEbeRWgbNEkqO";
const scram_final = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
fn authStartup(s: *Session, db: *DB, username: []const u8) !void {
    var p = Packet.init(0);
    p.len = 4;
    p.number32(196608);
    p.string("user");
    p.string(username);
    p.byte(0);
    put32(p.bytes[0..4], @intCast(p.len));
    const reply = try s.handle(db, p.bytes[0..p.len], &output);
    try check(reply.consumed == p.len and s.startup and !reply.close);
    var frames: Frames = .{ .bytes = output[0..reply.written] };
    const request = (try frames.next()) orelse return error.MissingAuthenticationRequest;
    try check(request.tag == 'R' and u32be(request.body[0..4]) == 10);
    try check(equal(request.body[4..], "SCRAM-SHA-256\x00\x00"));
    try check((try frames.next()) == null);
    try check(s.authentication.?.state == .initial);
}
fn authFirst(s: *Session, db: *DB) !void {
    var p = Packet.init('p');
    p.string(scram.mechanism);
    p.number32(scram_first.len);
    p.append(scram_first);
    const bytes = p.slice();
    for (0..bytes.len) |i| {
        const partial = try s.handle(db, bytes[0..i], &output);
        try check(partial.consumed == 0 and partial.written == 0 and s.authentication.?.state == .initial);
    }
    const reply = try s.handle(db, bytes, &output);
    try check(!reply.close and reply.consumed == bytes.len);
    var frames: Frames = .{ .bytes = output[0..reply.written] };
    const challenge = (try frames.next()) orelse return error.MissingChallenge;
    try check(challenge.tag == 'R' and u32be(challenge.body[0..4]) == 11);
    try check(equal(challenge.body[4..], "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"));
    try check((try frames.next()) == null);
}
fn authenticationContracts() !void {
    var db: DB = .{};
    var v = try scram.Verifier.parse("user", scram_verifier);
    var s: Session = .{};
    try s.configureAuthentication(&v, scram_nonce);
    // Configuration owns credential bytes, rather than borrowing caller state.
    v.stored_key[0] ^= 1;
    try authStartup(&s, &db, "user");
    try authFirst(&s, &db);
    var final = Packet.init('p');
    final.append(scram_final);
    const success = try send(&s, &db, &final);
    try tags(success, "RRSSSSSSSKZ");
    var frames: Frames = .{ .bytes = success };
    const signature = (try frames.next()).?;
    try check(u32be(signature.body[0..4]) == 12);
    try check(equal(signature.body[4..], "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    const ok = (try frames.next()).?;
    try check(u32be(ok.body[0..4]) == 0 and s.authentication.?.state == .complete);
    try tags(try query(&s, &db, "CREATE TABLE authenticated (id INTEGER PRIMARY KEY)"), "CZ");
    if (s.configureAuthentication(&v, scram_nonce)) |_| return error.AuthenticationReconfigured else |err| try check(err == error.AuthenticationState);
    v = try scram.Verifier.parse("user", scram_verifier);
    var wrong_user: Session = .{};
    try wrong_user.configureAuthentication(&v, scram_nonce);
    try authStartup(&wrong_user, &db, "unknown-user");
    try authFirst(&wrong_user, &db);
    const invalid = try wrong_user.handle(&db, final.slice(), &output);
    try check(invalid.close and wrong_user.authentication.?.state == .failed);
    try state(output[0..invalid.written], "28P01");
    try tags(output[0..invalid.written], "E");
    // No SQL, synchronization, prepared statement or replay can bypass auth.
    for ([_]u8{ 'Q', 'P', 'S', 'X', '?' }) |tag| {
        var pending: Session = .{};
        try pending.configureAuthentication(&v, scram_nonce);
        try authStartup(&pending, &db, "user");
        var packet = Packet.init(tag);
        if (tag == 'Q') packet.string("DROP TABLE authenticated");
        const rejected = try pending.handle(&db, packet.slice(), &output);
        try check(rejected.close and pending.authentication.?.state == .failed);
        try state(output[0..rejected.written], "28P01");
        const closed = try pending.handle(&db, final.slice(), &output);
        try check(closed.close and closed.written == 0);
    }
    for (0..5) |case| {
        var pending: Session = .{};
        try pending.configureAuthentication(&v, scram_nonce);
        try authStartup(&pending, &db, "user");
        var packet = Packet.init('p');
        packet.string(if (case == 0) "PLAIN" else scram.mechanism);
        packet.number32(if (case == 1) 0xffffffff else if (case == 2) 10000 else if (case == 3) 0 else scram_first.len);
        packet.append(if (case == 4) "bad-client-first" else scram_first);
        const rejected = try pending.handle(&db, packet.slice(), &output);
        try check(rejected.close);
        try state(output[0..rejected.written], "28P01");
    }
    var bad_password: Session = .{};
    try bad_password.configureAuthentication(&v, scram_nonce);
    try authStartup(&bad_password, &db, "user");
    try authFirst(&bad_password, &db);
    final.bytes[final.len - 4] ^= 1;
    const failed = try bad_password.handle(&db, final.slice(), &output);
    try check(failed.close);
    try state(output[0..failed.written], "28P01");
    try tags(try query(&s, &db, "SELECT * FROM authenticated"), "TCZ");
}
fn backendErrorStates() !void {
    var db: DB = .{};
    var s: Session = .{};
    try startup(&s, &db);
    const Case = struct { err: anyerror, state: []const u8 };
    const errors = [_]Case{
        .{ .err = error.SerializationFailure, .state = "40001" },
        .{ .err = error.TransactionCapacity, .state = "53200" },
        .{ .err = error.TransactionLogCapacity, .state = "53200" },
        .{ .err = error.StorageUnavailable, .state = "58030" },
        .{ .err = error.StorageFailure, .state = "58030" },
        .{ .err = error.FileWriteFailed, .state = "58030" },
        .{ .err = error.FileSyncFailed, .state = "58030" },
        .{ .err = error.FileTruncateFailed, .state = "58030" },
        .{ .err = error.WriterPoisoned, .state = "58030" },
    };
    for (errors) |case| {
        db.forced_error = case.err;
        const response = try query(&s, &db, "CREATE TABLE rejected (id INTEGER)");
        try state(response, case.state);
        try tags(response, "EZ");
        try check(db.raw.tableCount() == 0);
    }
}
fn fuzz() !void {
    var db: DB = .{};
    var s: Session = .{};
    s.startup = true;
    var seed: u32 = 0x52a70d33;
    var packet: [128]u8 = undefined;
    for (0..4096) |case| {
        const length = 5 + case % 123;
        for (packet[0..length]) |*b| {
            seed = seed *% 1664525 +% 1013904223;
            b.* = @truncate(seed >> 24);
        }
        if (case % 2 == 0) put32(packet[1..5], @intCast(length - 1));
        s.failed = false;
        const reply = try s.handle(&db, packet[0..length], &output);
        try check(reply.consumed <= length and reply.written <= output.len);
        if (reply.written != 0) {
            var frames: Frames = .{ .bytes = output[0..reply.written] };
            while (try frames.next()) |_| {}
        }
        fuzz_inputs += 1;
    }
}
/// Every engine error has an explicit SQLSTATE; none falls back to 54000.
fn errorStates() !void {
    inline for (@typeInfo(sql.Error).error_set.error_names.?) |name| {
        const err = @field(sql.Error, name);
        try check(pg.knownSqlstate(err) != null);
    }
    const expected = .{
        .{ error.UndefinedFunction, "42883" },         .{ error.TypeMismatch, "42804" },
        .{ error.InvalidTextRepresentation, "22P02" }, .{ error.IntegerOverflow, "22003" },
        .{ error.DivisionByZero, "22012" },            .{ error.AmbiguousFunction, "42725" },
        .{ error.CannotCoerce, "42846" },              .{ error.StatementTooComplex, "54001" },
        .{ error.VersionCapacity, "53200" },           .{ error.InvalidColumnReference, "42P10" },
    };
    inline for (expected) |pair| try check(equal(pg.knownSqlstate(pair[0]).?, pair[1]));
    try check(pg.knownSqlstate(error.SomethingUnknown) == null);
}

const stores = @import("db_store");
const Store = stores.Store(Raw);
const StoreSession = pg.Session(Store.Connection);
var store_output: [StoreSession.responseCapacity()]u8 = undefined;

fn storeSend(s: *StoreSession, db: *Store.Connection, p: *Packet) !pg.Reply {
    const reply = try s.handle(db, p.slice(), &store_output);
    packets += 1;
    return reply;
}

fn storeQuery(s: *StoreSession, db: *Store.Connection, source: []const u8) ![]const u8 {
    var p = Packet.init('Q');
    p.string(source);
    const reply = try storeSend(s, db, &p);
    try check(!reply.blocked and reply.consumed == p.len);
    return store_output[0..reply.written];
}

fn storeStartup(s: *StoreSession, db: *Store.Connection, options: []const u8) ![]const u8 {
    var p = Packet.init(0);
    p.len = 4;
    p.number32(196608);
    p.string("user");
    p.string("ramsql");
    p.string("options");
    p.string(options);
    p.byte(0);
    put32(p.bytes[0..4], @intCast(p.len));
    const reply = try s.handle(db, p.bytes[0..p.len], &store_output);
    try check(reply.consumed == p.len and s.startup);
    return store_output[0..reply.written];
}

fn commandTag(bytes: []const u8, wanted: []const u8) !void {
    var frames: Frames = .{ .bytes = bytes };
    while (try frames.next()) |f| if (f.tag == 'C') {
        try check(equal(f.body[0 .. f.body.len - 1], wanted));
        return;
    };
    return error.MissingCommandTag;
}

// READ COMMITTED wire behavior over the real store: BackendKeyData,
// CancelRequest keys, startup options, control-command tags, SHOW rows, a
// parked Execute reported as blocked, and ROLLBACK TO closing newer portals.
fn storeContracts() !void {
    var store: Store = .{};
    var a: Store.Connection = .{ .store = &store, .id = 1 };
    var b: Store.Connection = .{ .store = &store, .id = 2 };
    var sa: StoreSession = .{};
    var sb: StoreSession = .{};
    sa.configureBackendKey(7, 0xdeadbeef);
    const ready = try storeStartup(&sa, &a, "-c statement_timeout=1500");
    var frames: Frames = .{ .bytes = ready };
    var saw_key = false;
    while (try frames.next()) |f| if (f.tag == 'K') {
        try check(u32be(f.body[0..4]) == 7 and u32be(f.body[4..8]) == 0xdeadbeef);
        saw_key = true;
    };
    try check(saw_key and a.settings.statement_timeout_ms == 1500);
    _ = try storeStartup(&sb, &b, "");
    // CancelRequest goes to the caller with its key; the codec looks nothing up.
    var fresh: StoreSession = .{};
    var cancel_bytes: [16]u8 = undefined;
    put32(cancel_bytes[0..4], 16);
    put32(cancel_bytes[4..8], 80877102);
    put32(cancel_bytes[8..12], 7);
    put32(cancel_bytes[12..16], 0xdeadbeef);
    const cancel = try fresh.handle(&a, &cancel_bytes, &store_output);
    try check(cancel.close and cancel.written == 0 and cancel.cancel.?.pid == 7 and cancel.cancel.?.secret == 0xdeadbeef);

    _ = try storeQuery(&sa, &a, "CREATE TABLE w (id INTEGER PRIMARY KEY, v INTEGER)");
    _ = try storeQuery(&sa, &a, "INSERT INTO w VALUES (1, 0)");
    try commandTag(try storeQuery(&sa, &a, "SHOW statement_timeout"), "SHOW");
    try check(equal(sa.result.rows[0].cells[0].text.slice(), "1500ms"));
    try commandTag(try storeQuery(&sa, &a, "SET lock_timeout TO '2s'"), "SET");
    try commandTag(try storeQuery(&sa, &a, "RESET lock_timeout"), "RESET");
    try state(try storeQuery(&sa, &a, "SAVEPOINT outside"), "25P01");
    try commandTag(try storeQuery(&sa, &a, "BEGIN"), "BEGIN");
    try commandTag(try storeQuery(&sa, &a, "SAVEPOINT s"), "SAVEPOINT");
    try commandTag(try storeQuery(&sa, &a, "UPDATE w SET v = 1 WHERE id = 1"), "UPDATE 1");

    // b's extended-protocol Execute parks: nothing consumed or written.
    var parse_packet = Packet.init('P');
    parse_packet.string("");
    parse_packet.string("UPDATE w SET v = 2 WHERE id = 1");
    parse_packet.number16(0);
    _ = try storeSend(&sb, &b, &parse_packet);
    var bind_packet = Packet.init('B');
    bind_packet.string("");
    bind_packet.string("");
    bind_packet.number16(0);
    bind_packet.number16(0);
    bind_packet.number16(0);
    _ = try storeSend(&sb, &b, &bind_packet);
    var execute_packet = Packet.init('E');
    execute_packet.string("");
    execute_packet.number32(0);
    const parked = try storeSend(&sb, &b, &execute_packet);
    try check(parked.blocked and parked.consumed == 0 and parked.written == 0 and b.blocked());

    // A named portal bound after the savepoint is closed by ROLLBACK TO.
    var portal_parse = Packet.init('P');
    portal_parse.string("q");
    portal_parse.string("SELECT v FROM w");
    portal_parse.number16(0);
    _ = try storeSend(&sa, &a, &portal_parse);
    var portal_bind = Packet.init('B');
    portal_bind.string("late");
    portal_bind.string("q");
    portal_bind.number16(0);
    portal_bind.number16(0);
    portal_bind.number16(0);
    _ = try storeSend(&sa, &a, &portal_bind);
    try check(sa.portals[0].live or sa.portals[1].live);
    try commandTag(try storeQuery(&sa, &a, "ROLLBACK TO SAVEPOINT s"), "ROLLBACK");
    for (&sa.portals) |*p| try check(!(p.live and equal(p.name.bytes[0..p.name.len], "late")));
    // The row lock is gone: b's re-delivered Execute completes.
    try check(b.wakeReady());
    const resumed = try storeSend(&sb, &b, &execute_packet);
    try check(!resumed.blocked and resumed.consumed == execute_packet.len);
    try commandTag(store_output[0..resumed.written], "UPDATE 1");
    try commandTag(try storeQuery(&sa, &a, "RELEASE SAVEPOINT s"), "RELEASE");
    try commandTag(try storeQuery(&sa, &a, "COMMIT"), "COMMIT");
    _ = try storeQuery(&sb, &b, "SELECT v FROM w");
    try check(sb.result.rows[0].cells[0].integer == 2);
    try state(try storeQuery(&sa, &a, "BEGIN ISOLATION LEVEL SERIALIZABLE"), "0A000");
    _ = try storeQuery(&sa, &a, "SHOW transaction_isolation");
    try check(equal(sa.result.rows[0].cells[0].text.slice(), "read committed") and equal(sa.result.column_names[0].slice(), "transaction_isolation"));
    const usage = store.database.usage();
    try check(usage.row_locks == 0 and usage.pending_versions == 0);
}

pub fn main(init: std.process.Init) !void {
    try storeContracts();
    try normal();
    try extended();
    try inference();
    try errorStates();
    try statementLifecycle();
    try malformed();
    try authenticationContracts();
    try backendErrorStates();
    try fuzz();
    var report: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"postgres\",\"pass\":true,\"assertions\":{d},\"packets\":{d},\"fuzz_inputs\":{d},\"session_bytes\":{d}}}\n", .{ assertions, packets, fuzz_inputs, @sizeOf(Session) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
