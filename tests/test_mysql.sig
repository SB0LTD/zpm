//! Executable MySQL wire contracts, including fragmentation and malformed input.
const std = @import("std");
const sql = @import("sql");
const mysql = @import("mysql");
const db_store = @import("db_store");
const Raw = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 4, .text_bytes = 64 });
const Store = db_store.Store(Raw);
const DB = Store.Connection;
const Session = mysql.Session(DB);
var assertions: usize = 0;
var fuzz_inputs: usize = 0;
var output: [Session.responseCapacity()]u8 = undefined;
var request: [2048]u8 = undefined;
var store: Store = .{};

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.MySqlContractFailed;
}

fn same(a: []const u8, b: []const u8) !void {
    try check(std.mem.eql(u8, a, b));
}

fn packet(payload: []const u8, sequence: u8) []const u8 {
    for (0..3) |index| request[index] = @truncate(payload.len >> @intCast(index * 8));
    request[3] = sequence;
    @memcpy(request[4..][0..payload.len], payload);
    return request[0 .. payload.len + 4];
}

fn auth(buffer: []u8, password: []const u8, database: []const u8) []const u8 {
    @memset(buffer[0..32], 0);
    const flags: u32 = 0x200 | 0x8000 | 0x80000 | 8;
    for (0..4) |index| buffer[index] = @truncate(flags >> @intCast(index * 8));
    buffer[8] = 45;
    var position: usize = 32;
    @memcpy(buffer[position..][0..5], "user\x00");
    position += 5;
    buffer[position] = @intCast(password.len);
    position += 1;
    @memcpy(buffer[position..][0..password.len], password);
    position += password.len;
    @memcpy(buffer[position..][0..database.len], database);
    position += database.len;
    buffer[position] = 0;
    position += 1;
    @memcpy(buffer[position..][0..22], "mysql_native_password\x00");
    position += 22;
    return buffer[0..position];
}

fn connect(session: *Session, db: *DB) !void {
    const n = try session.begin(&output);
    try check(n > 70 and output[3] == 0 and output[4] == 10);
    var scratch: [128]u8 = undefined;
    const reply = try session.handle(db, packet(auth(&scratch, "", "ramsql"), 1), &output);
    try check(!reply.close and reply.written == 11 and output[3] == 2 and output[4] == 0);
}

fn command(session: *Session, db: *DB, query: []const u8) !mysql.Reply {
    var scratch: [1024]u8 = undefined;
    scratch[0] = 3;
    @memcpy(scratch[1..][0..query.len], query);
    return session.handle(db, packet(scratch[0 .. query.len + 1], 0), &output);
}

const Reader = struct {
    source: []const u8,
    pos: usize = 0,
    sequence: u8 = 1,
    fn next(self: *Reader) ![]const u8 {
        try check(self.source.len - self.pos >= 4);
        const header = self.source[self.pos..][0..4];
        const length = @as(usize, header[0]) | (@as(usize, header[1]) << 8) | (@as(usize, header[2]) << 16);
        try check(header[3] == self.sequence and length <= self.source.len - self.pos - 4);
        self.sequence +%= 1;
        self.pos += 4;
        const body = self.source[self.pos..][0..length];
        self.pos += length;
        return body;
    }
};

fn handshakeAndFragmentation() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    var tiny: [1]u8 = undefined;
    if (session.begin(&tiny)) |_| return error.ShortGreetingAccepted else |err| try check(err == error.BufferTooSmall);
    try check(!session.greeted);
    _ = try session.begin(&output);
    var scratch: [128]u8 = undefined;
    const message = packet(auth(&scratch, "", "ramsql"), 1);
    for (0..message.len) |cut| {
        const reply = try session.handle(&db, message[0..cut], &output);
        try check(reply.consumed == 0 and reply.written == 0 and !session.authenticated);
    }
    const reply = try session.handle(&db, message, &output);
    try check(reply.consumed == message.len and session.authenticated);
    const ping = packet(&.{14}, 0);
    for (0..ping.len) |cut| try check((try session.handle(&db, ping[0..cut], &output)).consumed == 0);
    _ = try session.handle(&db, ping, &output);
    try check(output[4] == 0);
    const quit = try session.handle(&db, packet(&.{1}, 0), &output);
    try check(quit.close and quit.written == 0);
}

fn typedResultsAndErrors() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try command(&session, &db, "CREATE TABLE data (id INTEGER PRIMARY KEY, name TEXT, active BOOLEAN, note TEXT)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "INSERT INTO data VALUES (-9223372036854775808, 'עברית😀', TRUE, NULL)");
    try check(output[4] == 0 and output[5] == 1);
    const reply = try command(&session, &db, "SELECT * FROM data");
    var reader: Reader = .{ .source = output[0..reply.written] };
    try same(try reader.next(), &.{4});
    for ([_]u8{ 8, 253, 1, 253 }) |kind| {
        const metadata = try reader.next();
        try check(metadata.len >= 13 and metadata[metadata.len - 6] == kind);
    }
    try check((try reader.next())[0] == 0xfe);
    const row = try reader.next();
    var expected: [128]u8 = undefined;
    const text = "עברית😀";
    const integer = "-9223372036854775808";
    expected[0] = integer.len;
    @memcpy(expected[1..][0..integer.len], integer);
    const name_pos = 1 + integer.len;
    expected[name_pos] = text.len;
    @memcpy(expected[name_pos + 1 ..][0..text.len], text);
    const flag_pos = name_pos + 1 + text.len;
    @memcpy(expected[flag_pos..][0..3], &[_]u8{ 1, '1', 0xfb });
    try same(row, expected[0 .. flag_pos + 3]);
    try same(try reader.next(), &.{ 0xfe, 0, 0, 2, 0 });
    try check(reader.pos == reader.source.len);
    _ = try command(&session, &db, "INSERT INTO data VALUES (-9223372036854775808, 'duplicate', false, NULL)");
    try check(output[4] == 0xff and output[5] == 0x26 and output[6] == 4); // ER_DUP_ENTRY 1062
    _ = try command(&session, &db, "SELECT * FROM absent");
    try check(output[4] == 0xff and std.mem.eql(u8, output[8..13], "42S02"));
    _ = try command(&session, &db, "SELECT * FROM data WHERE id = 2");
    try check(session.result.column_count == 4 and session.result.row_count == 0 and session.result.column_types[0] == .integer);
    _ = try session.handle(&db, packet(&.{22}, 0), &output);
    try check(output[4] == 0xff); // prepared statement unsupported
    _ = try session.handle(&db, packet("\x02other", 0), &output);
    try check(output[4] == 0xff);
    _ = try session.handle(&db, packet("\x02ramsql", 0), &output);
    try check(output[4] == 0);
}

fn transactionsAndOutputPreflight() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try command(&session, &db, "SET AUTOCOMMIT = 0");
    try check(output[4] == 0 and output[7] == 0);
    _ = try command(&session, &db, "CREATE TABLE rolled (id INTEGER)");
    try check(db.transactionStatus() == 'T' and output[7] == 1);
    _ = try command(&session, &db, "ROLLBACK");
    try check(store.database.tableCount() == 0 and db.transactionStatus() == 'I');
    _ = try command(&session, &db, "SET AUTOCOMMIT = 1");
    var scratch: [256]u8 = undefined;
    const query = "\x03CREATE TABLE stable (id INTEGER)";
    @memcpy(scratch[0..query.len], query);
    const message = packet(scratch[0..query.len], 0);
    if (session.handle(&db, message, output[0 .. output.len - 1])) |_| return error.ShortOutputAccepted else |err| try check(err == error.BufferTooSmall);
    try check(store.database.tableCount() == 0);
    _ = try session.handle(&db, message, &output);
    try check(store.database.tableCount() == 1);
}

fn malformedAndFuzz() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var scratch: [256]u8 = undefined;
    var session: Session = .{};
    _ = try session.begin(&output);
    const password_reply = try session.handle(&db, packet(auth(&scratch, "password", "ramsql"), 1), &output);
    try check(password_reply.close and output[4] == 0xff);
    session = .{};
    _ = try session.begin(&output);
    const database_reply = try session.handle(&db, packet(auth(&scratch, "", "unknown"), 1), &output);
    try check(database_reply.close and output[4] == 0xff);
    session = .{};
    _ = try session.begin(&output);
    const malformed = packet(&.{0}, 1);
    if (session.handle(&db, malformed, &output)) |_| return error.MalformedAuthAccepted else |err| try check(err == error.MalformedPacket);
    if (session.handle(&db, &.{ 0xff, 0xff, 1, 1 }, &output)) |_| return error.OversizeAccepted else |err| try check(err == error.RequestTooLarge);
    try connectReady(&session, &db);
    if (session.handle(&db, packet(&.{14}, 1), &output)) |_| return error.SequenceAccepted else |err| try check(err == error.InvalidSequence);
    if (session.handle(&db, packet(&.{}, 0), &output)) |_| return error.EmptyCommandAccepted else |err| try check(err == error.MalformedPacket);
    var state: u32 = 0x12abc789;
    for (0..1024) |iteration| {
        var fuzz: [96]u8 = undefined;
        const len: usize = 1 + iteration % fuzz.len;
        for (fuzz[0..len]) |*byte| {
            state = state *% 1664525 +% 1013904223;
            byte.* = @truncate(state >> 24);
        }
        // Unsupported commands cannot mutate the database, regardless of body.
        fuzz[0] = 0x80 | @as(u8, @truncate(iteration));
        const reply = try session.handle(&db, packet(fuzz[0..len], 0), &output);
        try check(reply.consumed == len + 4 and output[4] == 0xff and !reply.close);
        fuzz_inputs += 1;
    }
}

fn concurrentCommittedVisibility() !void {
    store = .{};
    var first: DB = .{ .store = &store, .id = 1 };
    var second: DB = .{ .store = &store, .id = 2 };
    var a: Session = .{};
    var b: Session = .{};
    try connect(&a, &first);
    try connect(&b, &second);
    _ = try command(&a, &first, "CREATE TABLE views (id INTEGER PRIMARY KEY)");
    _ = try command(&a, &first, "INSERT INTO views VALUES (1)");
    _ = try command(&a, &first, "BEGIN");
    try check(first.transactionStatus() == 'T');
    _ = try command(&a, &first, "UPDATE views SET id = 2 WHERE id = 1");
    _ = try command(&b, &second, "SELECT id FROM views");
    try check(b.result.row_count == 1 and b.result.rows[0].cells[0].integer == 1);
    // READ COMMITTED: the same-row writer waits (blocked, nothing consumed
    // or written), then re-checks the committed row: id is now 2, UPDATE 0.
    const parked = try command(&b, &second, "UPDATE views SET id = 3 WHERE id = 1");
    try check(parked.blocked and parked.consumed == 0 and parked.written == 0 and second.blocked());
    _ = try command(&a, &first, "SELECT id FROM views");
    try check(a.result.rows[0].cells[0].integer == 2);
    _ = try command(&a, &first, "COMMIT");
    try check(output[4] == 0 and first.transactionStatus() == 'I');
    const resumed = try command(&b, &second, "UPDATE views SET id = 3 WHERE id = 1");
    try check(!resumed.blocked and output[4] == 0 and output[5] == 0 and second.transactionStatus() == 'I');
    _ = try command(&a, &first, "SELECT id FROM views");
    try check(first.transactionStatus() == 'I' and a.result.rows[0].cells[0].integer == 2);
    _ = try command(&a, &first, "BEGIN");
    _ = try command(&a, &first, "UPDATE views SET id = 4 WHERE id = 2");
    _ = try command(&a, &first, "COMMIT");
    try check(output[4] == 0 and first.transactionStatus() == 'I');
    _ = try command(&b, &second, "SELECT id FROM views");
    try check(b.result.rows[0].cells[0].integer == 4);
}

fn connectReady(session: *Session, db: *DB) !void {
    var scratch: [128]u8 = undefined;
    _ = try session.handle(db, packet(auth(&scratch, "", "ramsql"), 1), &output);
    try check(session.authenticated);
}

pub fn main(init: std.process.Init) !void {
    try handshakeAndFragmentation();
    try typedResultsAndErrors();
    try transactionsAndOutputPreflight();
    try concurrentCommittedVisibility();
    try malformedAndFuzz();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"mysql\",\"pass\":true,\"assertions\":{d},\"fuzz_inputs\":{d}}}\n", .{ assertions, fuzz_inputs });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
