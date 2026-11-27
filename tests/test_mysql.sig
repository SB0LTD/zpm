//! Executable MySQL wire contracts, including fragmentation and malformed input.
const std = @import("std");
const sql = @import("sql");
const mysql = @import("mysql");
const db_store = @import("db_store");
const Raw = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 4, .name_bytes = 63, .text_bytes = 64, .integer_bits = 32 });
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
    if (!value) {
        std.debug.print("MySQL assertion {d} failed\n", .{assertions});
        return error.MySqlContractFailed;
    }
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
    _ = try command(&session, &db, "CREATE TABLE data (id BIGINT PRIMARY KEY, name TEXT, active BOOLEAN, note TEXT)");
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

fn nativeIdentifierAndLimit() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);

    _ = try command(&session, &db, "SELECT 1 AS `value`");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == 1);
    try same(session.result.column_names[0].slice(), "value");
    try check(session.result.column_types[0] == .integer);
    _ = try command(&session, &db, "CREATE TABLE `tdd_a`(`id` INT PRIMARY KEY,`v``x` INT)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "INSERT INTO `tdd_a`(`id`,`v``x`) VALUES(1,10),(2,20),(3,30),(4,40)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "SELECT id FROM tdd_a ORDER BY id LIMIT 1,2");
    try check(session.result.row_count == 2 and session.result.rows[0].cells[0].integer == 2 and session.result.rows[1].cells[0].integer == 3);
    try check(session.result.column_types[0] == .integer32);
    _ = try command(&session, &db, "SELECT `a`.`v``x` AS `x``y` FROM `tdd_a` AS `a` ORDER BY `a`.`id` DESC LIMIT 1,1");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == 30);
    try same(session.result.column_names[0].slice(), "x`y");
    _ = try command(&session, &db, "SELECT id FROM tdd_a ORDER BY id LIMIT 0,0");
    try check(session.result.row_count == 0 and session.result.column_count == 1);
    _ = try command(&session, &db, "SELECT id FROM tdd_a ORDER BY id LIMIT 10,2");
    try check(session.result.row_count == 0 and session.result.column_count == 1);
    _ = try command(&session, &db, "SELECT id FROM tdd_a ORDER BY id LIMIT 2 OFFSET 1");
    try check(session.result.row_count == 2 and session.result.rows[0].cells[0].integer == 2);
    for ([_][]const u8{
        "SELECT 1 AS ``", "SELECT 1 AS `unclosed", "SELECT 1 AS `x\x00y`",
        "SELECT 1 LIMIT -1, 1", "SELECT 1 LIMIT 1, -1", "SELECT 1 LIMIT 1, 1 OFFSET 1",
        "SELECT 1 OFFSET 1 LIMIT 1, 1", "SELECT 1 LIMIT 1,",
    }) |source| {
        _ = try command(&session, &db, source);
        try check(output[4] == 0xff and output[5] == 0x28 and output[6] == 0x04);
    }

    // Native-only grammar must not be stored as a view/definition that
    // ordinary evaluation and recovery would later parse as PostgreSQL.
    _ = try command(&session, &db, "CREATE VIEW v AS SELECT id FROM tdd_a LIMIT 1,2");
    try check(output[4] == 0xff);
    _ = try command(&session, &db, "CREATE TABLE broken(id INT CHECK (`id` >= 0))");
    try check(output[4] == 0xff);
    try check(store.database.tableCount() == 1);
    _ = try command(&session, &db, "SELECT '`quoted literal`' AS \"double\"");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0] == .text);
    try same(session.result.rows[0].cells[0].text.slice(), "`quoted literal`");
}

var syntax_recovered: Raw = .{};
var syntax_replay: Raw.ReplayScratch = .{};
fn nativeGrammarAndReplay() !void {
    store = .{};
    store.database.dialect = .mysql;
    syntax_recovered = .{};
    var record: [8192]u8 = undefined;
    var result: Raw.Result = .{};
    var used: usize = 0;
    try store.database.executeChanges("CREATE TABLE `t``x`(`id` INT PRIMARY KEY,`v``x` INT)", &result, &record, &used, null, null);
    try syntax_recovered.applyChangeRecord(record[0..used], &syntax_replay);
    used = 0;
    try store.database.executeChanges("INSERT INTO `t``x` VALUES(1,10),(2,20)", &result, &record, &used, null, null);
    try syntax_recovered.applyChangeRecord(record[0..used], &syntax_replay);
    try syntax_recovered.execute("SELECT \"v`x\" FROM \"t`x\" ORDER BY id LIMIT 1 OFFSET 1", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 20);

    for ([_]sql.Dialect{ .postgres, .tds }) |dialect| {
        syntax_recovered.dialect = dialect;
        for ([_][]const u8{ "SELECT 1 AS `value`", "SELECT id FROM \"t`x\" ORDER BY id LIMIT 0,1" }) |source| {
            if (syntax_recovered.execute(source, &result)) |_| return error.UnexpectedDialectSyntax else |err| try check(err == error.Syntax);
        }
    }
    store.database.dialect = .mysql;
    if (store.database.executeLegacy("SELECT 1 AS `value`", &result)) |_| return error.UnexpectedLegacySyntax else |err|
        try check(err == error.UnsupportedLogVersion);
}

fn nativeSignedIntegerLiterals() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    const probes = [_]struct { query: []const u8, values: [4]i64 }{
        .{ .query = "SELECT 0,1,-1,+1", .values = .{ 0, 1, -1, 1 } },
        .{ .query = "SELECT -0,0001,-0001,(-(1))", .values = .{ 0, 1, -1, -1 } },
        .{
            .query = "SELECT 2147483647,2147483648,-2147483648,-2147483649",
            .values = .{ 2147483647, 2147483648, -2147483648, -2147483649 },
        },
        .{
            .query = "SELECT 9223372036854775807,-9223372036854775808,-(2147483648),+(-9223372036854775808)",
            .values = .{ 9223372036854775807, -9223372036854775808, -2147483648, -9223372036854775808 },
        },
    };
    for (probes) |probe| {
        _ = try command(&session, &db, probe.query);
        try check(session.result.row_count == 1 and session.result.column_count == probe.values.len);
        for (probe.values, 0..) |expected, index| {
            try check(session.result.column_types[index] == .integer);
            try check(session.result.rows[0].cells[index].integer == expected);
        }
    }
    _ = try command(&session, &db, "CREATE TABLE signed_values(i INT PRIMARY KEY)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "INSERT INTO signed_values VALUES(7)");
    try check(output[4] == 0);
    const reply = try command(&session, &db, "SELECT i,1,-1,+1 FROM signed_values WHERE i=7");
    try check(session.result.row_count == 1 and session.result.column_count == 4);
    var reader: Reader = .{ .source = output[0..reply.written] };
    try same(try reader.next(), &.{4});
    for ([_]u8{ 3, 8, 8, 8 }, [_]i64{ 7, 1, -1, 1 }, 0..) |kind, expected, index| {
        const metadata = try reader.next();
        try check(metadata.len >= 13 and metadata[metadata.len - 6] == kind);
        try check(metadata[metadata.len - 5] & 32 == 0 and metadata[metadata.len - 3] == 0);
        try check(session.result.rows[0].cells[index].integer == expected);
    }
    const shared = try command(&session, &db, "SELECT SUBSTRING('abcdef',2,3), LAG(i,1) OVER (ORDER BY i) FROM signed_values");
    try check(shared.written > 0 and output[4] == 2);
    try check(session.result.row_count == 1 and session.result.rows[0].cells[1] == .null_value);
    try same(session.result.rows[0].cells[0].text.slice(), "bcd");
    var result: Raw.Result = .{};
    store.database.dialect = .mysql;
    try store.database.execute("SELECT CAST(1 AS DECIMAL(5,2)), 9223372036854775808, 18446744073709551616, -9223372036854775809", &result);
    try check(result.row_count == 1 and result.column_count == 4);
    for ([_]sql.DataType{ .numeric, .mysql_bigint_unsigned, .numeric, .numeric }, result.column_types[0..4], result.rows[0].cells[0..4]) |expected, kind, cell|
        try check(kind == expected and cell == .numeric);
    if (store.database.execute("SELECT -(-9223372036854775808)", &result)) |_| return error.UnexpectedIntegerOverflow else |err|
        try check(err == error.IntegerOverflow);

    for ([_]sql.Dialect{ .postgres, .tds }) |dialect| {
        store.database.dialect = dialect;
        try store.database.execute("SELECT 1,-1,CAST(1 AS BIGINT)", &result);
        try check(result.column_types[0] == .integer32 and result.column_types[1] == .integer32 and result.column_types[2] == .integer);
    }
    store.database.dialect = .mysql;
    try store.database.executeLegacy("SELECT i FROM signed_values WHERE i=7", &result);
    try check(result.column_types[0] == .integer32);
}

fn nativeIfnullAndDateAdd() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    const statement = "SELECT IFNULL(NULL,2),DATE_ADD('2025-01-01',INTERVAL 1 DAY)";
    const reply = try command(&session, &db, statement);
    try check(session.result.row_count == 1 and session.result.column_count == 2);
    try same(session.result.column_names[0].slice(), "IFNULL(NULL,2)");
    try same(session.result.column_names[1].slice(), "DATE_ADD('2025-01-01',INTERVAL 1 DAY)");
    var reader: Reader = .{ .source = output[0..reply.written] };
    try same(try reader.next(), &.{2});
    for ([_]u8{ 8, 254 }, [_]u8{ 0, 31 }) |kind, scale| {
        const metadata = try reader.next();
        try check(metadata.len >= 13 and metadata[metadata.len - 6] == kind);
        try check(metadata[metadata.len - 5] & 32 == 0 and metadata[metadata.len - 3] == scale);
    }
    try check((try reader.next())[0] == 0xfe);
    try same(try reader.next(), "\x012\x0a2025-01-02");

    const calendar = try command(&session, &db,
        "SELECT DATE_ADD(DATE '2024-01-31',INTERVAL 1 MONTH),DATE_ADD('2024-02-29',INTERVAL -12 MONTH)," ++
        "DATE_ADD('9999-12-31',INTERVAL 1 DAY),DATE_ADD('2025-01-01',INTERVAL NULL DAY)");
    reader = .{ .source = output[0..calendar.written] };
    try same(try reader.next(), &.{4});
    const typed = try reader.next();
    try check(typed.len >= 13 and typed[typed.len - 6] == 10 and typed[typed.len - 3] == 0);
    try check(session.result.row_count == 1 and session.result.column_count == 4);
    const values = &session.result.rows[0].cells;
    try same(values[0].text.slice(), "2024-02-29");
    try same(values[1].text.slice(), "2023-02-28");
    try check(values[2] == .null_value and values[3] == .null_value);
    _ = try command(&session, &db, "SELECT IFNULL(7,9223372036854775807+1),DATE_ADD('2024-03-01',INTERVAL -1 DAY)");
    try check(session.result.row_count == 1 and session.result.column_count == 2);
    try check(values[0].integer == 7);
    try same(values[1].text.slice(), "2024-02-29");

    _ = try command(&session, &db, "CREATE TABLE date_values(d DATE,n INT)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "INSERT INTO date_values VALUES(DATE '2024-01-31',1),(NULL,NULL)");
    try check(output[4] == 0);
    _ = try command(&session, &db,
        "SELECT DATE_ADD(d, INTERVAL n MONTH) AS shifted, IFNULL(n,2) AS fallback FROM date_values ORDER BY n IS NULL, n");
    try check(output[4] == 2 and session.result.row_count == 2);
    try same(session.result.column_names[0].slice(), "shifted");
    try same(values[0].text.slice(), "2024-02-29");
    try check(values[1].integer == 1 and session.result.rows[1].cells[0] == .null_value);
    try check(session.result.rows[1].cells[1].integer == 2);

    for ([_][]const u8{
        "SELECT DATE_ADD('2025-01-01',INTERVAL 1 HOUR)",
        "SELECT DATE_ADD('2025-01-01',INTERVAL 1.9 DAY)",
        "SELECT IFNULL(NULL,2,'extra')",
        "CREATE TABLE saved (v INT DEFAULT IFNULL(NULL,2))",
    }) |source| {
        _ = try command(&session, &db, source);
        try check(output[4] == 0xff);
    }
    var result: Raw.Result = .{};
    for ([_]sql.Dialect{ .postgres, .tds }) |dialect| {
        store.database.dialect = dialect;
        if (store.database.execute(statement, &result)) |_| return error.UnexpectedDialectSyntax else |_| {}
    }
    store.database.dialect = .mysql;
    if (store.database.executeLegacy(statement, &result)) |_| return error.UnexpectedLegacySyntax else |err|
        try check(err == error.UnsupportedLogVersion);
}

fn nativeReplace() !void {
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try command(&session, &db, "CREATE TABLE replacements (id INT PRIMARY KEY, v INT NOT NULL DEFAULT 9, note TEXT)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "REPLACE INTO replacements VALUES (1,2,'before')");
    try check(output[4] == 0 and output[5] == 1);
    _ = try command(&session, &db, "REPLACE replacements(id) VALUES(1)");
    try check(output[4] == 0 and output[5] == 2);
    _ = try command(&session, &db, "SELECT v,note FROM replacements WHERE id=1");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == 9 and session.result.rows[0].cells[1] == .null_value);
    _ = try command(&session, &db, "REPLACE INTO replacements VALUES (1,3,NULL),(1,4,NULL)");
    try check(output[4] == 0 and output[5] == 4);
    _ = try command(&session, &db, "REPLACE INTO replacements VALUES (1,5,NULL),(2,NULL,NULL)");
    try check(output[4] == 0xff);
    _ = try command(&session, &db, "SELECT id,v FROM replacements ORDER BY id");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == 1 and session.result.rows[0].cells[1].integer == 4);
    _ = try command(&session, &db, "BEGIN");
    try check(output[4] == 0 and db.transactionStatus() == 'T');
    _ = try command(&session, &db, "REPLACE INTO replacements VALUES (1,7,NULL)");
    try check(output[4] == 0 and output[5] == 2);
    _ = try command(&session, &db, "ROLLBACK");
    try check(output[4] == 0 and db.transactionStatus() == 'I');
    _ = try command(&session, &db, "SELECT v FROM replacements WHERE id=1");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == 4);
    _ = try command(&session, &db, "CREATE TABLE unique_values(id INT PRIMARY KEY,v INT UNIQUE)");
    try check(output[4] == 0);
    _ = try command(&session, &db, "REPLACE INTO unique_values VALUES (1,2)");
    try check(output[4] == 0xff);
    _ = try command(&session, &db, "SELECT COUNT(*) FROM unique_values");
    try check(session.result.rows[0].cells[0].integer == 0);

    store = .{};
    store.database.dialect = .mysql;
    syntax_recovered = .{};
    var record: [8192]u8 = undefined;
    var result: Raw.Result = .{};
    for ([_][]const u8{
        "CREATE TABLE replay_replace(id INT PRIMARY KEY,v INT)",
        "INSERT INTO replay_replace VALUES(1,27)",
        "REPLACE INTO replay_replace VALUES(1,90)",
    }) |source| {
        var used: usize = 0;
        try store.database.executeChanges(source, &result, &record, &used, null, null);
        try syntax_recovered.applyChangeRecord(record[0..used], &syntax_replay);
    }
    try check(result.affected_rows == 2);
    try syntax_recovered.execute("SELECT v FROM replay_replace WHERE id=1", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 90);
    // The PostgreSQL dialect has no REPLACE: a syntax error (42601), as native.
    if (syntax_recovered.execute("REPLACE INTO replay_replace VALUES(1,0)", &result)) |_| return error.UnexpectedDialectSyntax else |err|
        try check(err == error.Syntax);
}

fn nativeAutoIncrement() !void {
    store = .{};
    var first: DB = .{ .store = &store, .id = 1 };
    var second: DB = .{ .store = &store, .id = 2 };
    var a: Session = .{};
    var b: Session = .{};
    try connect(&a, &first);
    try connect(&b, &second);
    _ = try command(&a, &first, "CREATE TABLE autos(id INT AUTO_INCREMENT PRIMARY KEY,v INT NOT NULL)");
    try check(output[4] == 0);
    _ = try command(&a, &first, "INSERT INTO autos(v) VALUES(11)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 1);
    _ = try command(&a, &first, "INSERT INTO autos VALUES(10,22)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 10);
    const last_id = try command(&a, &first, "SELECT LAST_INSERT_ID()");
    try check(a.result.row_count == 1 and a.result.rows[0].cells[0].numeric.coef() == 1);
    var last_id_fields: Reader = .{ .source = output[0..last_id.written] };
    try same(try last_id_fields.next(), &.{1});
    try unsignedField(&last_id_fields);
    _ = try command(&a, &first, "INSERT INTO autos VALUES(NULL,33),(0,44)");
    try check(output[4] == 0 and output[5] == 2 and output[6] == 11);
    _ = try command(&a, &first, "SELECT id FROM autos ORDER BY v");
    try check(a.result.row_count == 4 and a.result.rows[2].cells[0].integer == 11 and a.result.rows[3].cells[0].integer == 12);
    _ = try command(&b, &second, "SELECT LAST_INSERT_ID()");
    try check(b.result.row_count == 1 and b.result.rows[0].cells[0].numeric.coef() == 0);

    _ = try command(&a, &first, "UPDATE autos SET id=300 WHERE v=22");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 0);
    _ = try command(&a, &first, "DELETE FROM autos WHERE id=1");
    try check(output[4] == 0 and output[5] == 1);
    _ = try command(&a, &first, "BEGIN");
    _ = try command(&a, &first, "INSERT INTO autos VALUES(DEFAULT,55)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 0xfc and output[7] == 45 and output[8] == 1);
    _ = try command(&a, &first, "ROLLBACK");
    _ = try command(&a, &first, "SELECT LAST_INSERT_ID()");
    try check(a.result.row_count == 1 and a.result.rows[0].cells[0].numeric.coef() == 301);
    _ = try command(&a, &first, "INSERT INTO autos(v) VALUES(66)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 0xfc and output[7] == 46 and output[8] == 1);
    _ = try command(&a, &first, "TRUNCATE TABLE autos");
    try check(output[4] == 0 and output[5] == 0 and output[6] == 0);
    _ = try command(&a, &first, "SET SESSION sql_mode='NO_AUTO_VALUE_ON_ZERO'");
    try check(output[4] == 0);
    _ = try command(&a, &first, "INSERT INTO autos VALUES(0,77)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 0);
    _ = try command(&a, &first, "INSERT INTO autos VALUES(NULL,88)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 1);
    _ = try command(&a, &first, "REPLACE INTO autos VALUES(1,99)");
    try check(output[4] == 0 and output[5] == 2 and output[6] == 1);
    _ = try command(&a, &first, "BEGIN");
    _ = try command(&a, &first, "REPLACE INTO autos VALUES(1,100)");
    try check(output[4] == 0 and output[5] == 2);
    _ = try command(&a, &first, "ROLLBACK");
    _ = try command(&a, &first, "SELECT v FROM autos WHERE id=1");
    try check(a.result.row_count == 1 and a.result.rows[0].cells[0].integer == 99);
    _ = try command(&a, &first, "REPLACE INTO autos(v) VALUES(101)");
    try check(output[4] == 0 and output[5] == 1 and output[6] == 2);

    store = .{};
    store.database.dialect = .mysql;
    syntax_recovered = .{};
    var record: [8192]u8 = undefined;
    var result: Raw.Result = .{};
    for ([_][]const u8{
        "CREATE TABLE autos(id INT AUTO_INCREMENT PRIMARY KEY,v INT NOT NULL)",
        "INSERT INTO autos(v) VALUES(19)",
        "REPLACE INTO autos VALUES(1,24)",
        "INSERT INTO autos VALUES(77,20)",
    }) |source| {
        var used: usize = 0;
        try store.database.executeChanges(source, &result, &record, &used, null, null);
        try syntax_recovered.applyChangeRecord(record[0..used], &syntax_replay);
    }
    try syntax_recovered.execute("SELECT id FROM autos WHERE v=24", &result);
    try check(result.row_count == 1 and result.rows[0].cells[0].integer == 1);
    syntax_recovered.dialect = .mysql;
    try syntax_recovered.execute("REPLACE INTO autos(v) VALUES(21)", &result);
    try check(result.mysql_insert_id == 78 and result.mysql_generated_id == 78);
}

fn unsignedField(reader: *Reader) !void {
    const metadata = try reader.next();
    try check(metadata.len >= 13 and metadata[metadata.len - 6] == 8 and
        metadata[metadata.len - 5] == 0x20 and metadata[metadata.len - 4] == 0 and metadata[metadata.len - 3] == 0);
}

fn unsignedSumAndCasts(session: *Session, db: *DB) !void {
    const aggregate = try command(session, db, "SELECT COUNT(*),MIN(id),MAX(id),SUM(id) FROM unsigned_values");
    var result: Reader = .{ .source = output[0..aggregate.written] };
    try same(try result.next(), &.{4});
    for ([_][]const u8{ "COUNT(*)", "MIN(id)", "MAX(id)", "SUM(id)" }, 0..) |name, column|
        try same(session.result.column_names[column].slice(), name);
    const count = try result.next();
    try check(count[count.len - 6] == 8 and count[count.len - 5] == 0);
    try unsignedField(&result);
    try unsignedField(&result);
    const sum = try result.next();
    try check(sum[sum.len - 10] == 43 and sum[sum.len - 6] == 246 and
        sum[sum.len - 5] == 0 and sum[sum.len - 4] == 0 and sum[sum.len - 3] == 0);
    try check((try result.next())[0] == 0xfe);
    try same(try result.next(), "\x013\x010\x1418446744073709551615\x1427670116110564327423");
    try check((try result.next())[0] == 0xfe and result.pos == result.source.len);

    for ([_][]const u8{
        "SELECT SUM(v) AS `Exact_Total` FROM unsigned_values WHERE id=0",
        "SELECT SUM(v) AS `Exact_Total` FROM unsigned_values WHERE id=-1",
    }) |statement| {
        const empty = try command(session, db, statement);
        var nullable: Reader = .{ .source = output[0..empty.written] };
        try same(try nullable.next(), &.{1});
        const metadata = try nullable.next();
        try check(metadata[metadata.len - 6] == 246);
        try same(session.result.column_names[0].slice(), "Exact_Total");
        try check((try nullable.next())[0] == 0xfe);
        try same(try nullable.next(), &.{0xfb});
        try check((try nullable.next())[0] == 0xfe);
    }
    _ = try command(session, db,
        "SELECT SUM(v) AS exact_total,COUNT(v) FROM unsigned_values GROUP BY id=0 ORDER BY COUNT(v)");
    try check(session.result.row_count == 2 and session.result.rows[0].cells[0] == .null_value);
    try check(session.result.rows[1].cells[0].numeric.coef() == 18446744073709551616 and
        session.result.rows[1].cells[1].integer == 2);

    const casted = try command(session, db, "SELECT CAST(-1 AS UNSIGNED) AS u,CAST(18446744073709551615 AS SIGNED) AS s");
    var casts: Reader = .{ .source = output[0..casted.written] };
    try same(try casts.next(), &.{2});
    try unsignedField(&casts);
    const signed = try casts.next();
    try check(signed[signed.len - 6] == 8 and signed[signed.len - 5] == 0);
    try same(session.result.column_names[0].slice(), "u");
    try same(session.result.column_names[1].slice(), "s");
    try check((try casts.next())[0] == 0xfe);
    try same(try casts.next(), "\x1418446744073709551615\x02-1");
    try check((try casts.next())[0] == 0xfe);

    _ = try command(session, db,
        "SELECT CAST(id AS SIGNED INTEGER),CAST(v AS UNSIGNED INTEGER) AS value FROM unsigned_values WHERE id=9223372036854775808");
    try same(session.result.column_names[0].slice(), "CAST(id AS SIGNED INTEGER)");
    try same(session.result.column_names[1].slice(), "value");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == -9223372036854775808 and
        session.result.rows[0].cells[1].numeric.coef() == 18446744073709551615);
    _ = try command(session, db, "SELECT CAST(CAST(-1 AS UNSIGNED) AS SIGNED),CAST(NULL AS UNSIGNED)");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].integer == -1 and
        session.result.column_types[1] == .mysql_bigint_unsigned and session.result.rows[0].cells[1] == .null_value);
    _ = try command(session, db, "SELECT id FROM unsigned_values WHERE id=CAST(-1 AS UNSIGNED)");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].numeric.coef() == 18446744073709551615);
}

fn nativeBigintUnsigned() !void {
    const create = "CREATE TABLE unsigned_values(id BIGINT UNSIGNED PRIMARY KEY,v BIGINT UNSIGNED)";
    const insert = "INSERT INTO unsigned_values VALUES(0,NULL),(9223372036854775808,18446744073709551615),(18446744073709551615,1)";
    store = .{};
    var db: DB = .{ .store = &store, .id = 1 };
    var session: Session = .{};
    try connect(&session, &db);
    _ = try command(&session, &db, create);
    try check(output[4] == 0);
    _ = try command(&session, &db, insert);
    try check(output[4] == 0 and output[5] == 3);
    const selected = try command(&session, &db, "SELECT id,v FROM unsigned_values ORDER BY id");
    var ordered: Reader = .{ .source = output[0..selected.written] };
    try same(try ordered.next(), &.{2});
    try unsignedField(&ordered);
    try unsignedField(&ordered);
    try check((try ordered.next())[0] == 0xfe);
    try same(try ordered.next(), "\x010\xfb");
    try same(try ordered.next(), "\x139223372036854775808\x1418446744073709551615");
    try same(try ordered.next(), "\x1418446744073709551615\x011");
    try check((try ordered.next())[0] == 0xfe and ordered.pos == ordered.source.len);

    const key = try command(&session, &db, "SELECT id FROM unsigned_values WHERE id=18446744073709551615");
    var looked_up: Reader = .{ .source = output[0..key.written] };
    try same(try looked_up.next(), &.{1});
    try unsignedField(&looked_up);
    try check((try looked_up.next())[0] == 0xfe);
    try same(try looked_up.next(), "\x1418446744073709551615");
    try check((try looked_up.next())[0] == 0xfe and looked_up.pos == looked_up.source.len);
    _ = try command(&session, &db, "SELECT id FROM unsigned_values WHERE id=-1");
    try check(session.result.row_count == 0);
    _ = try command(&session, &db, "SELECT id FROM unsigned_values WHERE id IN (0,18446744073709551615) ORDER BY id");
    try check(session.result.row_count == 2 and session.result.rows[0].cells[0].numeric.coef() == 0 and
        session.result.rows[1].cells[0].numeric.coef() == 18446744073709551615);
    _ = try command(&session, &db, "SELECT id FROM unsigned_values WHERE id BETWEEN 1 AND 18446744073709551615 ORDER BY id");
    try check(session.result.row_count == 2 and session.result.rows[0].cells[0].numeric.coef() == 9223372036854775808);
    _ = try command(&session, &db, "SELECT MIN(id),MAX(id),COUNT(*) FROM unsigned_values");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].numeric.coef() == 0 and
        session.result.rows[0].cells[1].numeric.coef() == 18446744073709551615 and session.result.rows[0].cells[2].integer == 3);
    try unsignedSumAndCasts(&session, &db);

    for ([_][]const u8{
        "INSERT INTO unsigned_values VALUES(1,-1)",
        "INSERT INTO unsigned_values VALUES(1,18446744073709551616)",
        "INSERT INTO unsigned_values VALUES(1,2),(2,-1)",
        "UPDATE unsigned_values SET v=18446744073709551616 WHERE id=0",
    }) |statement| {
        _ = try command(&session, &db, statement);
        try check(output[4] == 0xff and output[5] == 0xf0 and output[6] == 4);
    }
    _ = try command(&session, &db, "INSERT INTO unsigned_values VALUES(18446744073709551615,4)");
    try check(output[4] == 0xff and output[5] == 0x26 and output[6] == 4);
    for ([_][]const u8{
        "SELECT id+1 FROM unsigned_values",
        "SELECT SUM(id) OVER () FROM unsigned_values",
        "SELECT CAST('1' AS UNSIGNED)",
        "SELECT CAST(1.5 AS UNSIGNED)",
        "ALTER TABLE unsigned_values ADD COLUMN extra BIGINT UNSIGNED",
        "ALTER TABLE unsigned_values ALTER COLUMN v SET DEFAULT 0",
        "CREATE TABLE unsigned_default(id BIGINT UNSIGNED DEFAULT 0)",
    }) |statement| {
        _ = try command(&session, &db, statement);
        try check(output[4] == 0xff);
    }
    _ = try command(&session, &db, "SELECT id,v FROM unsigned_values WHERE id<=1 ORDER BY id");
    try check(session.result.row_count == 1 and session.result.rows[0].cells[0].numeric.coef() == 0 and
        session.result.rows[0].cells[1] == .null_value);
    _ = try command(&session, &db, "UPDATE unsigned_values SET v=9223372036854775808 WHERE id=0");
    try check(output[4] == 0 and output[5] == 1);
    _ = try command(&session, &db, "UPDATE unsigned_values SET v=CAST(-1 AS UNSIGNED) WHERE id=0");
    try check(output[4] == 0 and output[5] == 1);

    store = .{};
    store.database.dialect = .mysql;
    syntax_recovered = .{};
    syntax_recovered.dialect = .mysql;
    var record: [8192]u8 = undefined;
    var result: Raw.Result = .{};
    for ([_][]const u8{
        create,
        insert,
        "UPDATE unsigned_values SET v=18446744073709551615 WHERE id=0",
        "DELETE FROM unsigned_values WHERE id=9223372036854775808",
        "CREATE TABLE exact_total AS SELECT SUM(id) AS total FROM unsigned_values",
    }) |statement| {
        var used: usize = 0;
        try store.database.executeChanges(statement, &result, &record, &used, null, null);
        try syntax_recovered.applyChangeRecord(record[0..used], &syntax_replay);
    }
    try syntax_recovered.execute("SELECT * FROM unsigned_values ORDER BY id", &result);
    try check(result.row_count == 2 and result.column_types[0] == .mysql_bigint_unsigned and
        result.column_types[1] == .mysql_bigint_unsigned);
    try check(result.rows[0].cells[0].numeric.coef() == 0 and result.rows[0].cells[1].numeric.coef() == 18446744073709551615 and
        result.rows[1].cells[0].numeric.coef() == 18446744073709551615 and result.rows[1].cells[1].numeric.coef() == 1);
    try syntax_recovered.execute("SELECT total FROM exact_total", &result);
    try check(result.column_types[0] == .numeric and result.column_typmods[0] == -1 and
        result.row_count == 1 and result.rows[0].cells[0].numeric.coef() == 18446744073709551615);
    syntax_recovered.dialect = .postgres;
    try syntax_recovered.execute("SELECT id FROM unsigned_values WHERE id=18446744073709551615", &result);
    try check(result.row_count == 1 and result.column_types[0] == .numeric and
        result.rows[0].cells[0].numeric.coef() == 18446744073709551615);
    try syntax_recovered.execute("SELECT CAST(-1 AS BIGINT)", &result);
    try check(result.row_count == 1 and result.column_types[0] == .integer and result.rows[0].cells[0].integer == -1);
    if (syntax_recovered.execute("SELECT CAST(-1 AS UNSIGNED)", &result)) |_| return error.UnexpectedDialectSyntax else |err|
        try check(err == error.UndefinedObject);
}

pub fn main(init: std.process.Init) !void {
    try handshakeAndFragmentation();
    try typedResultsAndErrors();
    try nativeIdentifierAndLimit();
    try nativeGrammarAndReplay();
    try nativeSignedIntegerLiterals();
    try nativeIfnullAndDateAdd();
    try nativeReplace();
    try nativeAutoIncrement();
    try nativeBigintUnsigned();
    try transactionsAndOutputPreflight();
    try concurrentCommittedVisibility();
    try malformedAndFuzz();
    var buffer: [256]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"mysql\",\"pass\":true,\"assertions\":{d},\"fuzz_inputs\":{d}}}\n", .{ assertions, fuzz_inputs });
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
