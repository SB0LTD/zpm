//! Executable TDS contracts with fragmented packets, typed rows and malformed input.
const std = @import("std");
const sql = @import("sql");
const tds = @import("tds");
const db_store = @import("db_store");
const Raw = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 4, .text_bytes = 64 });
const Store = db_store.Store(Raw);
const DB = Store.Connection;
const Session = tds.Session(DB);
var assertions: usize = 0;
var fuzz_inputs: usize = 0;
var output: [Session.responseCapacity()]u8 = undefined;
var flattened: [Session.responseCapacity()]u8 = undefined;
var request: [4096]u8 = undefined;
var store: Store = .{};

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.TdsContractFailed;
}

fn same(a: []const u8, b: []const u8) !void {
    try check(std.mem.eql(u8, a, b));
}

fn number(target: []u8, value: u64) void {
    for (target, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn packet(kind: u8, status: u8, id: u8, payload: []const u8) []const u8 {
    request[0] = kind;
    request[1] = status;
    request[2] = @intCast((payload.len + 8) >> 8);
    request[3] = @truncate(payload.len + 8);
    request[4] = 0;
    request[5] = 0;
    request[6] = id;
    request[7] = 0;
    @memcpy(request[8..][0..payload.len], payload);
    return request[0 .. payload.len + 8];
}

fn flatten(reply: tds.Reply) ![]const u8 {
    var position: usize = 0;
    var written: usize = 0;
    var id: u8 = 1;
    while (position < reply.written) {
        try check(reply.written - position >= 8);
        const header = output[position..][0..8];
        const length: usize = @as(usize, header[2]) * 256 + header[3];
        try check(length >= 8 and length <= reply.written - position and length <= 4096 and header[0] == 4 and header[6] == id);
        id +%= 1;
        try check(header[1] == (if (position + length == reply.written) @as(u8, 1) else 0));
        @memcpy(flattened[written..][0 .. length - 8], output[position + 8 ..][0 .. length - 8]);
        written += length - 8;
        position += length;
    }
    return flattened[0..written];
}

const prelogin = [_]u8{ 0, 0, 11, 0, 6, 1, 0, 17, 0, 1, 0xff, 16, 0, 0, 0, 0, 0, 2 };

fn login(buffer: []u8, password_chars: usize, database: []const u8) []const u8 {
    const length = 94 + database.len * 2 + password_chars * 2;
    @memset(buffer[0..length], 0);
    number(buffer[0..4], length);
    number(buffer[4..8], 0x74000004);
    number(buffer[8..12], 512);
    inline for (.{ 36, 40, 44, 48, 52, 60, 64, 68, 82, 86 }) |offset| number(buffer[offset..][0..2], 94);
    number(buffer[68..70], 94);
    number(buffer[70..72], database.len);
    for (database, 0..) |byte, index| buffer[94 + index * 2] = byte;
    number(buffer[44..46], 94 + database.len * 2);
    number(buffer[46..48], password_chars);
    return buffer[0..length];
}

fn connect(session: *Session, db: *DB) !void {
    try check(try session.begin(&output) == 0);
    const pre = try session.handle(db, packet(0x12, 1, 0, &prelogin), &output);
    const prebody = try flatten(pre);
    try check(!pre.close and prebody.len == 24 and prebody[22] == 2 and prebody[23] == 0);
    var buffer: [256]u8 = undefined;
    const reply = try session.handle(db, packet(0x10, 1, 1, login(&buffer, 0, "ramsql")), &output);
    const body = try flatten(reply);
    try check(!reply.close and body[0] == 0xad and body[1] == 22 and body[4] == 0x74);
    try check(body[25] == 0xe3 and body[body.len - 13] == 0xfd);
}

fn headers(target: []u8) void {
    @memset(target[0..22], 0);
    number(target[0..4], 22);
    number(target[4..8], 18);
    number(target[8..10], 2);
    number(target[18..22], 1);
}

fn batch(buffer: []u8, query: []const u8) ![]const u8 {
    headers(buffer);
    var units: [1024]u16 = undefined;
    const count = try std.unicode.utf8ToUtf16Le(&units, query);
    for (units[0..count], 0..) |unit, index| number(buffer[22 + index * 2 ..][0..2], unit);
    return buffer[0 .. 22 + count * 2];
}

fn execute(session: *Session, db: *DB, query: []const u8) ![]const u8 {
    var buffer: [2048]u8 = undefined;
    return flatten(try session.handle(db, packet(1, 1, 2, try batch(&buffer, query)), &output));
}

fn session_handle_batch(session: *Session, db: *DB, buffer: *[2048]u8, query: []const u8) !tds.Reply {
    return session.handle(db, packet(1, 1, 2, try batch(buffer, query)), &output);
}

const Reader = struct {
    source: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, count: usize) ![]const u8 {
        try check(count <= self.source.len - self.pos);
        const bytes = self.source[self.pos..][0..count];
        self.pos += count;
        return bytes;
    }
    fn numeric(self: *Reader, count: usize) !u64 {
        const bytes = try self.take(count);
        var value: u64 = 0;
        for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
        return value;
    }
};

fn loginAndFragmentation() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    const pre = packet(0x12, 1, 1, &prelogin);
    for (0..pre.len) |cut| {
        const reply = try session.handle(&db, pre[0..cut], &output);
        try check(reply.consumed == 0 and reply.written == 0);
    }
    session = .{};
    try connect(&session, &db);
    var buffer: [2048]u8 = undefined;
    const source = try batch(&buffer, "CREATE TABLE fragmented (id INTEGER)");
    const split = 31; // deliberately split a UTF-16 code unit across packets
    const first = try session.handle(&db, packet(1, 0, 40, source[0..split]), &output);
    try check(first.consumed == split + 8 and first.written == 0 and store.database.tableCount() == 0);
    const last = try session.handle(&db, packet(1, 1, 41, source[split..]), &output);
    const body = try flatten(last);
    try check(body[0] == 0xfd and store.database.tableCount() == 1);
    const attention = try session.handle(&db, packet(6, 1, 42, &.{}), &output);
    const cancelled = try flatten(attention);
    try check(cancelled[0] == 0xfd and cancelled[1] == 0x20);
}

fn typedRowsAndErrors() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    const created = try execute(&session, &db, "CREATE TABLE data (id INTEGER PRIMARY KEY, name TEXT, active BOOLEAN, note TEXT)");
    try check(created[0] == 0xfd);
    const inserted = try execute(&session, &db, "INSERT INTO data VALUES (-9223372036854775808, 'עברית😀', TRUE, NULL)");
    try check(inserted[0] == 0xfd and inserted[5] == 1);
    const selected = try execute(&session, &db, "SELECT * FROM data");
    var reader: Reader = .{ .source = selected };
    try check(try reader.numeric(1) == 0x81 and try reader.numeric(2) == 4);
    for ([_]u8{ 0x26, 0xe7, 0x68, 0xe7 }) |kind| {
        try check(try reader.numeric(4) == 0 and try reader.numeric(2) == 1);
        try check(try reader.numeric(1) == kind);
        _ = try reader.take(if (kind == 0xe7) 7 else 1);
        const name_len: usize = @intCast(try reader.numeric(1));
        _ = try reader.take(name_len * 2);
    }
    try check(try reader.numeric(1) == 0xd1);
    try check(try reader.numeric(1) == 8 and try reader.numeric(8) == 0x8000000000000000);
    const text_bytes: usize = @intCast(try reader.numeric(2));
    var units: [32]u16 = undefined;
    const count = try std.unicode.utf8ToUtf16Le(&units, "עברית😀");
    try check(text_bytes == count * 2);
    for (units[0..count]) |unit| try check(try reader.numeric(2) == unit);
    try check(try reader.numeric(1) == 1 and try reader.numeric(1) == 1 and try reader.numeric(2) == 0xffff);
    try check(try reader.numeric(1) == 0xfd and try reader.numeric(2) == 0x10);
    _ = try reader.take(2);
    try check(try reader.numeric(8) == 1 and reader.pos == selected.len);
    const duplicate = try execute(&session, &db, "INSERT INTO data VALUES (-9223372036854775808, 'dup', false, NULL)");
    try check(duplicate[0] == 0xaa and duplicate[3] == 0x43 and duplicate[4] == 0x0a); // 2627
    const absent = try execute(&session, &db, "SELECT * FROM absent");
    try check(absent[0] == 0xaa and absent[3] == 208);
    const rpc = try session.handle(&db, packet(3, 1, 3, &.{}), &output);
    try check((try flatten(rpc))[0] == 0xaa);
    const empty = try execute(&session, &db, "SELECT * FROM data WHERE id = 7");
    try check(empty[0] == 0x81 and session.result.row_count == 0 and session.result.column_types[0] == .integer);
}

fn outputFragmentation() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try execute(&session, &db, "CREATE TABLE many (a TEXT, b TEXT, c TEXT, d TEXT)");
    const value = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZab";
    var source: [1024]u8 = undefined;
    const statement = try std.fmt.bufPrint(&source, "INSERT INTO many VALUES ('{s}', '{s}', '{s}', '{s}')", .{ value, value, value, value });
    for (0..4) |_| _ = try execute(&session, &db, statement);
    const selected = try execute(&session, &db, "SELECT * FROM many");
    try check(selected.len > 2048 and output[1] == 0); // multiple 512-byte packets
    var position: usize = 0;
    var packets: usize = 0;
    while (true) {
        const length: usize = @as(usize, output[position + 2]) * 256 + output[position + 3];
        try check(length <= 512);
        packets += 1;
        if (output[position + 1] == 1) break;
        position += length;
    }
    try check(packets >= 5);
}

fn transactionManagerAndPreflight() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    var buffer: [256]u8 = undefined;
    headers(&buffer);
    number(buffer[22..24], 5);
    buffer[24] = 2;
    buffer[25] = 0;
    const begin = try session.handle(&db, packet(0x0e, 1, 2, buffer[0..26]), &output);
    const begin_body = try flatten(begin);
    try check(begin_body[0] == 0xe3 and begin_body[3] == 8 and db.transactionStatus() == 'T');
    _ = try execute(&session, &db, "CREATE TABLE rolled (id INTEGER)");
    headers(&buffer);
    number(buffer[22..24], 8);
    buffer[24] = 0;
    buffer[25] = 0;
    const rollback = try session.handle(&db, packet(0x0e, 1, 3, buffer[0..26]), &output);
    const rollback_body = try flatten(rollback);
    try check(rollback_body[3] == 10 and db.transactionStatus() == 'I' and store.database.tableCount() == 0);
    _ = try execute(&session, &db, "BEGIN");
    try check(db.transactionStatus() == 'T');
    _ = try execute(&session, &db, "CREATE TABLE committed (id INTEGER)");
    const committed = try execute(&session, &db, "COMMIT");
    try check(committed[0] == 0xe3 and committed[3] == 9 and store.database.tableCount() == 1);
    var querybuf: [2048]u8 = undefined;
    const message = packet(1, 1, 4, try batch(&querybuf, "CREATE TABLE untouched (id INTEGER)"));
    if (session.handle(&db, message, output[0 .. output.len - 1])) |_| return error.ShortOutputAccepted else |err| try check(err == error.BufferTooSmall);
    try check(store.database.tableCount() == 1);
    _ = try session.handle(&db, message, &output);
    try check(store.database.tableCount() == 2);
}

fn concurrentCommittedVisibility() !void {
    store = .{};
    var first: DB = .{ .store = &store, .id = 1 };
    var second: DB = .{ .store = &store, .id = 2 };
    var a: Session = .{};
    var b: Session = .{};
    try connect(&a, &first);
    try connect(&b, &second);
    _ = try execute(&a, &first, "CREATE TABLE views (id INTEGER PRIMARY KEY)");
    _ = try execute(&a, &first, "INSERT INTO views VALUES (1)");
    _ = try execute(&a, &first, "BEGIN");
    try check(first.transactionStatus() == 'T');
    _ = try execute(&a, &first, "UPDATE views SET id = 2 WHERE id = 1");
    _ = try execute(&b, &second, "SELECT id FROM views");
    try check(b.result.row_count == 1 and b.result.rows[0].cells[0].integer == 1);
    // READ COMMITTED: the same-row writer waits (blocked, nothing consumed
    // or written), then re-checks the committed row: id is now 2, 0 rows.
    var parked_buffer: [2048]u8 = undefined;
    const parked = try session_handle_batch(&b, &second, &parked_buffer, "UPDATE views SET id = 3 WHERE id = 1");
    try check(parked.blocked and parked.consumed == 0 and parked.written == 0 and second.blocked());
    _ = try execute(&a, &first, "SELECT id FROM views");
    try check(a.result.rows[0].cells[0].integer == 2);
    const committed = try execute(&a, &first, "COMMIT");
    try check(committed[0] != 0xaa and first.transactionStatus() == 'I');
    const resumed = try execute(&b, &second, "UPDATE views SET id = 3 WHERE id = 1");
    try check(!second.blocked() and second.transactionStatus() == 'I' and b.result.affected_rows == 0);
    try check(resumed[0] != 0xaa);
    const usage = store.database.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0);
    try check(usage.pending_versions == 0);
    _ = try execute(&a, &first, "SELECT id FROM views");
    try check(first.transactionStatus() == 'I' and a.result.rows[0].cells[0].integer == 2);
    _ = try execute(&a, &first, "BEGIN");
    _ = try execute(&a, &first, "UPDATE views SET id = 4 WHERE id = 2");
    _ = try execute(&a, &first, "COMMIT");
    try check(first.transactionStatus() == 'I');
    _ = try execute(&b, &second, "SELECT id FROM views");
    try check(b.result.rows[0].cells[0].integer == 4);
}

const RpcBuilder = struct {
    target: []u8,
    pos: usize = 22,
    fn numeric(self: *RpcBuilder, value: u64, count: usize) void {
        number(self.target[self.pos..][0..count], value);
        self.pos += count;
    }
    fn unicode(self: *RpcBuilder, value: []const u8) !usize {
        var units: [1024]u16 = undefined;
        const count = try std.unicode.utf8ToUtf16Le(&units, value);
        for (units[0..count]) |unit| self.numeric(unit, 2);
        return count;
    }
    fn name(self: *RpcBuilder, value: []const u8) !void {
        self.numeric(value.len, 1);
        _ = try self.unicode(value);
        self.numeric(0, 1); // StatusFlags
    }
    fn text(self: *RpcBuilder, parameter: []const u8, value: ?[]const u8, split: bool) !void {
        try self.name(parameter);
        self.numeric(0xe7, 1);
        self.numeric(0xffff, 2);
        self.numeric(0, 5); // collation
        if (value) |string| {
            var units: [1024]u16 = undefined;
            const count = try std.unicode.utf8ToUtf16Le(&units, string);
            self.numeric(0xfffffffffffffffe, 8); // unknown PLP length
            if (split and count != 0) {
                self.numeric(1, 4); // split the first UTF-16 code unit
                self.numeric(units[0] & 255, 1);
                self.numeric(count * 2 - 1, 4);
                self.numeric(units[0] >> 8, 1);
                for (units[1..count]) |unit| self.numeric(unit, 2);
            } else if (count != 0) {
                self.numeric(count * 2, 4);
                for (units[0..count]) |unit| self.numeric(unit, 2);
            }
            self.numeric(0, 4);
        } else self.numeric(0xffffffffffffffff, 8);
    }
    fn integer(self: *RpcBuilder, parameter: []const u8, value: i64) !void {
        try self.name(parameter);
        self.numeric(0x26, 1);
        self.numeric(8, 1);
        self.numeric(8, 1);
        self.numeric(@bitCast(value), 8);
    }
    fn boolean(self: *RpcBuilder, parameter: []const u8, value: bool) !void {
        try self.name(parameter);
        self.numeric(0x68, 1);
        self.numeric(1, 1);
        self.numeric(1, 1);
        self.numeric(if (value) 1 else 0, 1);
    }
    fn begin(self: *RpcBuilder, query: []const u8, declarations: []const u8) !void {
        headers(self.target);
        self.numeric(0xffff, 2);
        self.numeric(10, 2); // sp_executesql
        self.numeric(0, 2); // OptionFlags
        try self.text("", query, true);
        try self.text("", declarations, false);
    }
};

fn rpcParameters() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try execute(&session, &db, "CREATE TABLE binds (id INTEGER PRIMARY KEY, name TEXT, active BOOLEAN, note TEXT)");
    var buffer: [4096]u8 = undefined;
    var builder: RpcBuilder = .{ .target = &buffer };
    try builder.begin("INSERT INTO binds VALUES (@P1, @P2, @P3, @P4)", "@P1 BIGINT,@P2 NVARCHAR(MAX),@P3 BIT,@P4 NVARCHAR(32)");
    try builder.integer("@P1", -9223372036854775808);
    const injection = "x'); DROP TABLE binds; -- 😀 @P1";
    try builder.text("@P2", injection, true);
    try builder.boolean("@P3", true);
    try builder.text("@P4", null, false);
    const inserted = try session.handle(&db, packet(3, 1, 2, buffer[0..builder.pos]), &output);
    const inserted_body = try flatten(inserted);
    try check(inserted_body[0] == 0xff and inserted_body[1] == 0x11 and inserted_body[5] == 1);
    try check(inserted_body[13] == 0x79 and inserted_body[18] == 0xfe and inserted_body[19] == 0);
    _ = try execute(&session, &db, "SELECT * FROM binds");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == -9223372036854775808);
    try same(session.result.rows[0].cells[1].text.slice(), injection);
    try check(session.result.rows[0].cells[2].boolean and session.result.rows[0].cells[3] == .null_value);
    // Named parameters may arrive out of declaration order; repeated references
    // bind identically and @P2 inside a quoted SQL literal remains literal text.
    builder = .{ .target = &buffer };
    try builder.begin("INSERT INTO binds VALUES (@P1, '@P2', @P3, NULL)", "@P1 INT,@P2 NVARCHAR(MAX),@P3 BIT");
    try builder.boolean("@P3", false);
    try builder.integer("@P1", 7);
    try builder.text("@P2", "unused", false);
    const quoted = try session.handle(&db, packet(3, 1, 3, buffer[0..builder.pos]), &output);
    try check((try flatten(quoted))[0] == 0xff);
    _ = try execute(&session, &db, "SELECT * FROM binds WHERE id = 7");
    try same(session.result.rows[0].cells[1].text.slice(), "@P2");
    builder = .{ .target = &buffer };
    try builder.begin("SELECT * FROM binds WHERE id = @P1", "@P1 BIGINT");
    try builder.integer("@p1", -9223372036854775808);
    const selected = try session.handle(&db, packet(3, 1, 4, buffer[0..builder.pos]), &output);
    const selected_body = try flatten(selected);
    try check(selected_body[0] == 0x81 and selected_body[selected_body.len - 13] == 0xfe and session.result.row_count == 1);
    // Duplicate/missing parameters and unsupported types fail before execution.
    builder = .{ .target = &buffer };
    try builder.begin("DELETE FROM binds WHERE id = @P1", "@P1 INT,@P2 INT");
    try builder.integer("@P1", 7);
    try builder.integer("@P1", 8);
    const duplicate = try session.handle(&db, packet(3, 1, 5, buffer[0..builder.pos]), &output);
    try check((try flatten(duplicate))[0] == 0xaa);
    builder = .{ .target = &buffer };
    try builder.begin("DELETE FROM binds WHERE id = @P1", "@P1 INT");
    const missing = try session.handle(&db, packet(3, 1, 6, buffer[0..builder.pos]), &output);
    try check((try flatten(missing))[0] == 0xaa);
    builder = .{ .target = &buffer };
    try builder.begin("DELETE FROM binds WHERE id = @P1", "@P1 INT");
    try builder.name("@P1");
    builder.numeric(0x3e, 1); // FLOAT
    const unsupported = try session.handle(&db, packet(3, 1, 7, buffer[0..builder.pos]), &output);
    try check((try flatten(unsupported))[0] == 0xaa);
    _ = try execute(&session, &db, "SELECT * FROM binds");
    try check(session.result.row_count == 2);
    // All truncations of a complete RPC parameter stream reject safely without
    // making the INSERT observable, even if the outer packet claims completion.
    builder = .{ .target = &buffer };
    try builder.begin("INSERT INTO binds VALUES (@P1, @P2, @P3, NULL)", "@P1 INT,@P2 NVARCHAR(MAX),@P3 BIT");
    try builder.integer("@P1", 8);
    try builder.text("@P2", "safe", false);
    try builder.boolean("@P3", true);
    for (0..builder.pos) |cut| {
        const reply = try session.handle(&db, packet(3, 1, 8, buffer[0..cut]), &output);
        const body = try flatten(reply);
        try check(body[0] == 0xaa);
        fuzz_inputs += 1;
    }
    _ = try execute(&session, &db, "SELECT * FROM binds");
    try check(session.result.row_count == 2);
}

fn malformedAndFuzz() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    var pre = prelogin;
    pre[17] = 1;
    const encrypted = try session.handle(&db, packet(0x12, 1, 0, &pre), &output);
    try check(encrypted.close and (try flatten(encrypted))[22] == 2);
    var buffer: [256]u8 = undefined;
    session = .{};
    _ = try session.handle(&db, packet(0x12, 1, 0, &prelogin), &output);
    const password = try session.handle(&db, packet(0x10, 1, 1, login(&buffer, 2, "ramsql")), &output);
    try check(password.close and (try flatten(password))[0] == 0xaa);
    session = .{};
    _ = try session.handle(&db, packet(0x12, 1, 0, &prelogin), &output);
    const unknown = try session.handle(&db, packet(0x10, 1, 1, login(&buffer, 0, "unknown")), &output);
    try check(unknown.close and (try flatten(unknown))[0] == 0xaa);
    session = .{};
    try connect(&session, &db);
    headers(&buffer);
    buffer[22] = 0;
    buffer[23] = 0xd8; // unpaired high surrogate
    const unicode_error = try session.handle(&db, packet(1, 1, 2, buffer[0..24]), &output);
    try check((try flatten(unicode_error))[0] == 0xaa);
    headers(&buffer);
    buffer[4] = 0; // zero header length
    if (session.handle(&db, packet(1, 1, 2, buffer[0..22]), &output)) |_| return error.HeaderAccepted else |err| try check(err == error.MalformedPacket);
    _ = try session.handle(&db, packet(1, 0, 90, &.{ 22, 0, 0, 0 }), &output);
    if (session.handle(&db, packet(1, 1, 92, &.{0}), &output)) |_| return error.SequenceAccepted else |err| try check(err == error.InvalidSequence);
    var state: u32 = 0x5aabc123;
    for (0..1024) |iteration| {
        session = .{};
        var fuzz: [128]u8 = undefined;
        const len = 1 + iteration % fuzz.len;
        for (fuzz[0..len]) |*byte| {
            state = state *% 1664525 +% 1013904223;
            byte.* = @truncate(state >> 24);
        }
        if (session.handle(&db, packet(0x12, 1, @truncate(iteration), fuzz[0..len]), &output)) |_| {
            try check(false); // arbitrary payload never meets required option table
        } else |err| try check(err == error.MalformedPacket);
        fuzz_inputs += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    try loginAndFragmentation();
    try typedRowsAndErrors();
    try outputFragmentation();
    try transactionManagerAndPreflight();
    try concurrentCommittedVisibility();
    try rpcParameters();
    try malformedAndFuzz();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"tds\",\"pass\":true,\"assertions\":{d},\"fuzz_inputs\":{d}}}\n", .{ assertions, fuzz_inputs });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
