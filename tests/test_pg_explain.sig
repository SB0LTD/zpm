//! EXPLAIN reports real SELECT observations and uses the normal SQL lifecycle.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const Raw = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .result_rows = 1, .text_bytes = 128 });
const Store = @import("db_store").Store(Raw);
const Wire = pg.Session(Store.Connection);

var store: Store = .{};
var result: Raw.Result = .{};
var protocol: Wire = .{};
var output: [Wire.responseCapacity()]u8 = undefined;
var assertions: usize = 0;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) {
        std.debug.print("EXPLAIN contract failed at assertion {d}\n", .{assertions});
        return error.ExplainContractFailed;
    }
}

fn reject(expected: anyerror, actual: anytype) !void {
    if (actual) |_| return error.ExpectedExplainFailure else |err| {
        if (err != expected) std.debug.print("expected {s}, got {s}\n", .{ @errorName(expected), @errorName(err) });
        try check(err == expected);
    }
}

fn report(db: *Store.Connection, query: []const u8, expected: []const u8) !void {
    db.execute(query, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
        return err;
    };
    try check(result.command == .explain and result.column_count == 1 and result.row_count == 1);
    try check(result.column_types[0] == .json and result.column_typmods[0] == -1);
    try check(std.mem.eql(u8, result.column_names[0].slice(), "QUERY PLAN"));
    const actual = result.rows[0].cells[0].text.slice();
    if (!std.mem.eql(u8, actual, expected)) std.debug.print("expected {s}, got {s}\n", .{ expected, actual });
    try check(std.mem.eql(u8, actual, expected));
}

fn send(db: *Store.Connection, tag: u8, payload: []const u8) ![]const u8 {
    var packet: [512]u8 = undefined;
    packet[0] = tag;
    std.mem.writeInt(u32, packet[1..5], @intCast(payload.len + 4), .big);
    @memcpy(packet[5..][0..payload.len], payload);
    const message = packet[0 .. 5 + payload.len];
    const reply = try protocol.handle(db, message, &output);
    try check(reply.consumed == message.len and !reply.close and !reply.blocked);
    return output[0..reply.written];
}

fn frame(bytes: *[]const u8, tag: u8) ![]const u8 {
    try check(bytes.*.len >= 5 and bytes.*[0] == tag);
    const length = std.mem.readInt(u32, bytes.*[1..5], .big);
    try check(length >= 4 and length < bytes.*.len);
    const payload = bytes.*[5 .. 1 + length];
    bytes.* = bytes.*[1 + length ..];
    return payload;
}

fn canceled(_: ?*anyopaque) Raw.SqlError!void {
    return error.QueryCanceled;
}

pub fn main() !void {
    const select_key = "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM explain_test WHERE id=2";
    const key_result = "[{\"Plan\":{\"Node Type\":\"Primary Key Lookup\",\"Actual Rows\":1,\"Actual Loops\":1}}]";
    var admin: Store.Connection = .{ .store = &store, .id = 1 };
    defer admin.disconnect();
    try admin.execute("CREATE TABLE explain_test (id INT PRIMARY KEY, value INT)", &result);
    try admin.execute("INSERT INTO explain_test VALUES (1,20),(2,10),(3,30)", &result);
    try report(&admin, select_key, key_result);
    try report(&admin, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT id FROM explain_test WHERE id=4",
        "[{\"Plan\":{\"Node Type\":\"Primary Key Lookup\",\"Actual Rows\":0,\"Actual Loops\":1}}]");
    try report(&admin, "EXPLAIN (FORMAT JSON, ANALYZE ON) SELECT id FROM explain_test WHERE value>0",
        "[{\"Plan\":{\"Node Type\":\"Table Scan\",\"Actual Rows\":3,\"Actual Loops\":1}}]");
    try report(&admin, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM explain_test ORDER BY value",
        "[{\"Plan\":{\"Node Type\":\"Sort\",\"Actual Rows\":3,\"Actual Loops\":1}}]");
    try report(&admin, "EXPLAIN (FORMAT JSON, ANALYZE 1) SELECT id FROM explain_test LIMIT 0",
        "[{\"Plan\":{\"Node Type\":\"Limit\",\"Actual Rows\":0,\"Actual Loops\":1}}]");
    try reject(error.UnsupportedStatement, admin.execute("EXPLAIN (FORMAT XML, ANALYZE) SELECT 1", &result));
    try reject(error.UnsupportedStatement, admin.execute("EXPLAIN (FORMAT JSON, BUFFERS) SELECT 1", &result));
    try reject(error.UnsupportedStatement, admin.execute("EXPLAIN (FORMAT JSON, ANALYZE) DELETE FROM explain_test", &result));
    try reject(error.Syntax, admin.execute("EXPLAIN (FORMAT JSON, ANALYZE, ANALYZE) SELECT 1", &result));
    try reject(error.UnsupportedStatement, admin.execute("EXPLAIN (FORMAT JSON) SELECT count(*) FROM explain_test", &result));

    try admin.execute("CREATE SEQUENCE explain_seq START 10", &result);
    try admin.execute("/* comment */ EXPLAIN (FORMAT JSON, ANALYZE FALSE) SELECT nextval('explain_seq')", &result);
    try check(std.mem.indexOf(u8, result.rows[0].cells[0].text.slice(), "Actual Rows") == null);
    try admin.execute("SELECT nextval('explain_seq')", &result);
    try check(result.rows[0].cells[0].integer == 10);
    try admin.execute("EXPLAIN (FORMAT JSON, ANALYZE) SELECT nextval('explain_seq')", &result);
    try check(std.mem.indexOf(u8, result.rows[0].cells[0].text.slice(), "\"Actual Rows\":1") != null);
    try admin.execute("SELECT nextval('explain_seq')", &result);
    try check(result.rows[0].cells[0].integer == 12);
    try admin.execute("EXPLAIN (FORMAT JSON, ANALYZE) SELECT nextval('explain_seq') FROM explain_test WHERE id<=2", &result);
    try check(std.mem.indexOf(u8, result.rows[0].cells[0].text.slice(), "\"Actual Rows\":2") != null);
    try admin.execute("SELECT nextval('explain_seq')", &result);
    try check(result.rows[0].cells[0].integer == 15);

    var other: Store.Connection = .{ .store = &store, .id = 2 };
    try admin.beginTransaction();
    try report(&admin, "EXPLAIN (FORMAT JSON) SELECT id FROM explain_test WHERE id=1 FOR UPDATE", "[{\"Plan\":{\"Node Type\":\"Select Plan\"}}]");
    try other.execute("UPDATE explain_test SET value=99 WHERE id=1", &result);
    try admin.rollbackTransaction();
    try admin.beginTransaction();
    try report(&admin, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM explain_test WHERE id=1 FOR UPDATE",
        "[{\"Plan\":{\"Node Type\":\"Lock Rows\",\"Actual Rows\":1,\"Actual Loops\":1}}]");
    try reject(error.WouldBlock, other.execute("UPDATE explain_test SET value=99 WHERE id=1", &result));
    other.disconnect();
    try admin.rollbackTransaction();
    try admin.execute("BEGIN READ ONLY", &result);
    try report(&admin, "EXPLAIN (FORMAT JSON) SELECT id FROM explain_test WHERE id=1 FOR UPDATE", "[{\"Plan\":{\"Node Type\":\"Select Plan\"}}]");
    try reject(error.ReadOnlyTransaction, admin.execute("EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM explain_test WHERE id=1 FOR UPDATE", &result));
    try admin.rollbackTransaction();

    try admin.execute("CREATE ROLE explainer LOGIN", &result);
    var reader: Store.Connection = .{ .store = &store, .id = 3 };
    defer reader.disconnect();
    try reader.bindAuthenticatedRole("explainer");
    try reject(error.InsufficientPrivilege, reader.execute(select_key, &result));
    try reject(error.InsufficientPrivilege, reader.execute("EXPLAIN (FORMAT JSON) SELECT id FROM explain_test", &result));
    try admin.execute("GRANT SELECT ON explain_test TO explainer", &result);
    try admin.execute("ALTER TABLE explain_test ENABLE ROW LEVEL SECURITY", &result);
    try admin.execute("CREATE POLICY explain_visible ON explain_test USING (id > 1)", &result);
    try report(&reader, "EXPLAIN (FORMAT JSON, ANALYZE) SELECT id FROM explain_test",
        "[{\"Plan\":{\"Node Type\":\"Query Plan\",\"Actual Rows\":2,\"Actual Loops\":1}}]");

    var control: Raw.ExecutionControl = .{ .poll = &canceled };
    store.database.session.control = &control;
    try reject(error.QueryCanceled, store.database.execute(select_key, &result));
    try check(result.command == .explain and result.row_count == 1);
    store.database.session.control = null;

    const startup = "\x00\x00\x00\x15\x00\x03\x00\x00user\x00ramsql\x00\x00";
    const accepted = try protocol.handle(&admin, startup, &output);
    try check(accepted.consumed == startup.len and !accepted.close);
    var simple = try send(&admin, 'Q', select_key ++ "\x00");
    const description = "\x00\x01QUERY PLAN\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x72\xff\xff\xff\xff\xff\xff\x00\x00";
    try check(std.mem.eql(u8, try frame(&simple, 'T'), description));
    const data = try frame(&simple, 'D');
    try check(std.mem.eql(u8, data[6..], key_result));
    try check(std.mem.eql(u8, try frame(&simple, 'C'), "EXPLAIN\x00"));
    _ = try frame(&simple, 'Z');
    try check(simple.len == 0);

    var parsed = try send(&admin, 'P', "\x00" ++ select_key ++ "\x00\x00\x00");
    try check((try frame(&parsed, '1')).len == 0);
    var bound = try send(&admin, 'B', "\x00\x00\x00\x00\x00\x00\x00\x00");
    try check((try frame(&bound, '2')).len == 0);
    var described = try send(&admin, 'D', "P\x00");
    try check(std.mem.eql(u8, try frame(&described, 'T'), description));
    var executed = try send(&admin, 'E', "\x00\x00\x00\x00\x00");
    try check(std.mem.eql(u8, (try frame(&executed, 'D'))[6..], key_result));
    try check(std.mem.eql(u8, try frame(&executed, 'C'), "EXPLAIN\x00"));
    try check(executed.len == 0);
    std.debug.print("PASS PostgreSQL EXPLAIN: {d} assertions\n", .{assertions});
}
