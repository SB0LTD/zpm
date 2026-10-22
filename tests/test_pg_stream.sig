//! Execute PostgreSQL/SQL/store over fragmented caller-owned streams.
const std = @import("std");
const sql = @import("sql");
const stores = @import("db_store");
const pg = @import("postgres");
const streams = @import("stream_server");
const Raw = sql.Database(.{ .tables = 2, .columns = 2, .rows_per_table = 4, .text_bytes = 32 });
const Store = stores.Store(Raw);
const Protocol = pg.Session(Store.Connection);
const Stream = streams.Server(Store.Connection, Protocol, 128);
var store: Store = .{};
var workspace: Raw = undefined;
var stream: Stream = .{};
var session: Protocol = .{};
var input: [2048]u8 = undefined;
var used: usize = 0;
var assertions: usize = 0;
fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) return error.PostgresStreamContractFailed;
}
fn append(bytes: []const u8) void {
    @memcpy(input[used..][0..bytes.len], bytes);
    used += bytes.len;
}
fn integer(value: usize) void {
    var bytes: [4]u8 = undefined;
    for (0..4) |i| bytes[i] = @truncate(value >> @intCast((3 - i) * 8));
    append(&bytes);
}
fn query(source: []const u8) void {
    append("Q");
    integer(source.len + 5);
    append(source);
    append("\x00");
}
fn be(bytes: []const u8) usize {
    var value: usize = 0;
    for (bytes) |b| value = value * 256 + b;
    return value;
}
const Io = struct {
    chunk: usize,
    at: usize = 0,
    count: usize = 0,
    output: [8192]u8 = undefined,
    pub fn read(self: *@This(), target: []u8) !usize {
        const n = @min(self.chunk, @min(target.len, used - self.at));
        @memcpy(target[0..n], input[self.at..][0..n]);
        self.at += n;
        return n;
    }
    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        if (bytes.len > self.output.len - self.count) return error.TestOutputCapacity;
        @memcpy(self.output[self.count..][0..bytes.len], bytes);
        self.count += bytes.len;
    }
};
pub fn main() !void {
    const startup = "\x00\x03\x00\x00user\x00ramsql\x00database\x00ramsql\x00\x00";
    integer(startup.len + 4);
    append(startup);
    query("CREATE TABLE events (id INTEGER, label TEXT)");
    query("BEGIN");
    query("INSERT INTO events VALUES (7,'private')");
    query("SELECT * FROM events");
    query("ROLLBACK");
    query("SELECT * FROM events");
    query("INSERT INTO events VALUES (8,'committed')");
    query("SELECT * FROM events");
    append("X\x00\x00\x00\x04");
    for ([_]usize{ 1, 2, 3, 7, 31, 128, 2048 }) |chunk| {
        store = .{};
        session = .{};
        var connection: Store.Connection = .{ .store = &store, .id = 1, .transaction_workspace = &workspace };
        var io: Io = .{ .chunk = chunk };
        try stream.run(&io, &connection, &session);
        try check(io.at == used);
        try check(connection.transactionStatus() == 'I');
        var offset: usize = 0;
        var ready: usize = 0;
        var rows: usize = 0;
        var commands: usize = 0;
        while (offset < io.count) {
            try check(io.count - offset >= 5);
            const tag = io.output[offset];
            const length = be(io.output[offset + 1 ..][0..4]);
            try check(length >= 4 and length + 1 <= io.count - offset);
            try check(tag != 'E');
            if (tag == 'Z') ready += 1;
            if (tag == 'D') {
                rows += 1;
                const body = io.output[offset + 5 ..][0 .. length - 4];
                try check(body.len >= 7 and be(body[0..2]) == 2 and be(body[2..6]) == 1);
                try check(body[6] == (if (rows == 1) @as(u8, '7') else '8'));
            }
            if (tag == 'C') commands += 1;
            offset += length + 1;
        }
        try check(ready == 9 and commands == 8 and rows == 2);
        var result: Raw.Result = .{};
        try store.database.execute("SELECT * FROM events", &result);
        try check(result.row_count == 1 and result.rows[0].cells[0].integer == 8);
        connection.disconnect();
    }
    std.debug.print("{{\"suite\":\"postgres-stream\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
}
