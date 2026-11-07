//! Executable COPY contracts (design §5.17): text/csv/binary row formats,
//! streamed CopyData larger than any input buffer, rows split across
//! messages (carry), CopyFail, malformed data, write-set limits, COPY TO
//! output, and a COPY row parked on a key wait then resumed (insert or
//! 23505) - every failure leaves zero uncommitted versions and locks.
const std = @import("std");
const pg = @import("postgres");
const sql = @import("sql");
const stores = @import("db_store");
const fmt = pg.copy_format;

const Raw = sql.Database(.{ .tables = 4, .columns = 4, .rows_per_table = 600, .text_bytes = 64, .tx_writes = 512, .transactions = 4 });
const Store = stores.Store(Raw);
const Session = pg.Session(Store.Connection);

var assertions: usize = 0;
var output: [Session.responseCapacity()]u8 = undefined;
var message: [200 * 1024]u8 = undefined;

fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.CopyContractFailed;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn put32(b: []u8, n: u32) void {
    b[0] = @truncate(n >> 24);
    b[1] = @truncate(n >> 16);
    b[2] = @truncate(n >> 8);
    b[3] = @truncate(n);
}

fn read32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// One frontend message `tag` + length + body in `out`.
fn frame(out: []u8, tag: u8, body: []const u8) []const u8 {
    out[0] = tag;
    put32(out[1..5], @intCast(body.len + 4));
    if (@intFromPtr(body.ptr) != @intFromPtr(out[5..].ptr)) @memcpy(out[5..][0..body.len], body);
    return out[0 .. body.len + 5];
}

const Frames = struct {
    const Frame = struct { tag: u8, body: []const u8 };
    bytes: []const u8,
    at: usize = 0,
    fn next(self: *Frames) !?Frame {
        if (self.at == self.bytes.len) return null;
        try check(self.bytes.len - self.at >= 5);
        const n = read32(self.bytes[self.at + 1 ..][0..4]);
        try check(n >= 4 and n <= self.bytes.len - self.at - 1);
        const out: Frame = .{ .tag = self.bytes[self.at], .body = self.bytes[self.at + 5 .. self.at + 1 + n] };
        self.at += 1 + n;
        return out;
    }
};

fn sqlstate(bytes: []const u8) ?[]const u8 {
    var frames: Frames = .{ .bytes = bytes };
    while (frames.next() catch return null) |f| if (f.tag == 'E') {
        var i: usize = 0;
        while (i < f.body.len and f.body[i] != 0) {
            const kind = f.body[i];
            i += 1;
            const begin = i;
            while (i < f.body.len and f.body[i] != 0) : (i += 1) {}
            if (kind == 'C') return f.body[begin..i];
            i += 1;
        }
    };
    return null;
}

fn tagOf(bytes: []const u8) ?[]const u8 {
    var frames: Frames = .{ .bytes = bytes };
    while (frames.next() catch return null) |f| if (f.tag == 'C') return f.body[0 .. f.body.len - 1];
    return null;
}

fn readyStatus(bytes: []const u8) ?u8 {
    var frames: Frames = .{ .bytes = bytes };
    var out: ?u8 = null;
    while (frames.next() catch return null) |f| if (f.tag == 'Z') {
        out = f.body[0];
    };
    return out;
}

/// Concatenated CopyData bodies of a COPY TO response.
fn copyOut(bytes: []const u8, out: []u8) ![]const u8 {
    var frames: Frames = .{ .bytes = bytes };
    var used: usize = 0;
    var saw_h = false;
    while (try frames.next()) |f| switch (f.tag) {
        'H' => saw_h = true,
        'd' => {
            @memcpy(out[used..][0..f.body.len], f.body);
            used += f.body.len;
        },
        else => {},
    };
    try check(saw_h);
    return out[0..used];
}

const Client = struct {
    session: Session = .{},
    connection: Store.Connection,

    fn handle(self: *Client, bytes: []const u8) !pg.Reply {
        return self.session.handle(&self.connection, bytes, &output);
    }

    fn query(self: *Client, source: []const u8) ![]const u8 {
        var buffer: [4096]u8 = undefined;
        @memcpy(buffer[5..][0..source.len], source);
        buffer[5 + source.len] = 0;
        const bytes = frame(&buffer, 'Q', buffer[5..][0 .. source.len + 1]);
        const reply = try self.handle(bytes);
        try check(!reply.blocked and reply.consumed == bytes.len);
        return output[0..reply.written];
    }

    fn startup(self: *Client) !void {
        var p: [64]u8 = undefined;
        var at: usize = 4;
        put32(p[at..][0..4], 196608);
        at += 4;
        for ([_][]const u8{ "user", "ramsql" }) |item| {
            @memcpy(p[at..][0..item.len], item);
            at += item.len;
            p[at] = 0;
            at += 1;
        }
        p[at] = 0;
        at += 1;
        put32(p[0..4], @intCast(at));
        const reply = try self.handle(p[0..at]);
        try check(reply.consumed == at and self.session.startup);
    }

    fn count(self: *Client, table: []const u8) !i64 {
        var buffer: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "SELECT count(*) FROM {s}", .{table});
        _ = try self.query(text);
        return self.session.result.rows[0].cells[0].integer;
    }

    /// Sends one CopyData message whole and returns the reply.
    fn data(self: *Client, body: []const u8) !pg.Reply {
        return self.handle(frame(&message, 'd', body));
    }

    fn done(self: *Client) ![]const u8 {
        var buffer: [8]u8 = undefined;
        const reply = try self.handle(frame(&buffer, 'c', ""));
        try check(reply.consumed == 5);
        return output[0..reply.written];
    }
};

fn quiet(store: *Store) !void {
    const usage = store.database.usage();
    try check(usage.transactions == 0 and usage.row_locks == 0 and usage.table_locks == 0 and usage.pending_versions == 0);
}

fn formats() !void {
    var scratch: [256]u8 = undefined;
    var fields: [4]?[]const u8 = undefined;
    const text: fmt.Options = .{};
    // \N is NULL (raw comparison); escapes decode; \<delimiter> is data.
    var n = try fmt.textFields(&text, "a\\tb\t\\N\t\\\\x\\n\\101\\x41\t\\\t", &scratch, &fields);
    try check(n == 4 and equal(fields[0].?, "a\tb") and fields[1] == null and equal(fields[2].?, "\\x\nAA") and equal(fields[3].?, "\t"));
    try check(fmt.textFields(&text, "1\t2\t3\t4\t5", &scratch, &fields) == error.BadCopyFormat);
    const csv: fmt.Options = .{ .format = .csv, .delimiter = ',', .null_string = "" };
    n = try fmt.csvFields(&csv, "1,,\"\",\"a,\"\"b\"\"\nc\"", &scratch, &fields);
    try check(n == 4 and equal(fields[0].?, "1") and fields[1] == null and equal(fields[2].?, "") and equal(fields[3].?, "a,\"b\"\nc"));
    try check(fmt.csvFields(&csv, "1,\"open", &scratch, &fields) == error.BadCopyFormat);
    const escaped: fmt.Options = .{ .format = .csv, .delimiter = ',', .null_string = "", .escape = '\\' };
    n = try fmt.csvFields(&escaped, "\"x\\\"y\",z", &scratch, &fields);
    try check(n == 2 and equal(fields[0].?, "x\"y") and equal(fields[1].?, "z"));
    // Framing: a text backslash escapes a newline; CSV quotes span lines.
    try check(fmt.lineEnd(&text, "a\\\nb\nc").? == 5);
    try check(fmt.lineEnd(&text, "abc") == null and fmt.lineEnd(&text, "ab\\") == null);
    try check(fmt.lineEnd(&csv, "\"a\nb\",c\nx").? == 8);
    try check(fmt.lineEnd(&csv, "\"a\nb") == null);
    var eol: fmt.Eol = .unknown;
    try check(equal(try fmt.stripLine("a\r\n", &eol, true), "a") and eol == .crnl);
    try check(fmt.stripLine("b\n", &eol, true) == error.BadCopyFormat);
    // Binary header and tuple framing.
    var header: [19]u8 = undefined;
    @memcpy(header[0..11], fmt.signature);
    @memset(header[11..19], 0);
    try check((try fmt.binaryHeader(&header)).? == 19);
    try check((try fmt.binaryHeader(header[0..7])) == null);
    header[0] = 'X';
    try check(fmt.binaryHeader(&header) == error.BadCopyFormat);
    header[0] = 'P';
    header[12] = 1; // WITH OIDS
    try check(fmt.binaryHeader(&header) == error.BadCopyFormat);
    const tuple = [_]u8{ 0, 2, 0, 0, 0, 4, 0, 0, 0, 7, 0xff, 0xff, 0xff, 0xff };
    try check((try fmt.tupleEnd(&tuple, 2)).? == tuple.len);
    try check((try fmt.tupleEnd(tuple[0..9], 2)) == null);
    try check(fmt.tupleEnd(&tuple, 3) == error.BadCopyFormat);
    try check((try fmt.tupleEnd(&[_]u8{ 0xff, 0xff }, 2)).? == 2);
    n = fmt.tupleFields(&tuple, &fields);
    try check(n == 2 and fields[0].?.len == 4 and fields[1] == null);
    // Output escaping.
    var out: [64]u8 = undefined;
    var sink: fmt.Sink = .{ .bytes = &out };
    try fmt.appendText(&text, "a\tb\\c\nd", &sink);
    try check(equal(sink.bytes[0..sink.at], "a\\tb\\\\c\\nd"));
    sink = .{ .bytes = &out };
    try fmt.appendCsv(&csv, "a\"b", false, &sink);
    try fmt.appendCsv(&csv, "", false, &sink);
    try fmt.appendCsv(&csv, "plain", false, &sink);
    try check(equal(sink.bytes[0..sink.at], "\"a\"\"b\"\"\"plain"));
}

fn protocol() !void {
    var store: Store = .{};
    var a: Client = .{ .connection = .{ .store = &store, .id = 1 } };
    var b: Client = .{ .connection = .{ .store = &store, .id = 2 } };
    try a.startup();
    try b.startup();
    _ = try a.query("CREATE TABLE t (id INTEGER PRIMARY KEY, label TEXT, n INTEGER GENERATED BY DEFAULT AS IDENTITY, d TEXT DEFAULT 'dflt')");

    // Column subset: identity and DEFAULT fill the rest; a row split across
    // two CopyData messages is carried.
    var reply = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN\x00"));
    var frames: Frames = .{ .bytes = output[0..reply.written] };
    const g = (try frames.next()).?;
    try check(g.tag == 'G' and g.body[0] == 0 and g.body[2] == 2);
    reply = try a.data("1\tone\n2\t\\N\n3\tth");
    try check(!reply.blocked and reply.written == 0);
    reply = try a.data("ree\n");
    try check(reply.written == 0);
    var bytes = try a.done();
    try check(equal(tagOf(bytes).?, "COPY 3") and readyStatus(bytes).? == 'I');
    _ = try a.query("SELECT id, label, n, d FROM t ORDER BY id");
    const r = &a.session.result;
    try check(r.row_count == 3 and equal(r.rows[2].cells[1].text.slice(), "three") and r.rows[1].cells[1] == .null_value);
    try check(r.rows[0].cells[2].integer == 1 and r.rows[2].cells[2].integer == 3 and equal(r.rows[0].cells[3].text.slice(), "dflt"));
    try quiet(&store);

    // CSV with HEADER and quotes.
    _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN WITH (FORMAT csv, HEADER true)\x00"));
    _ = try a.data("id,label\n10,\"x,\"\"y\"\"\"\n11,\n");
    bytes = try a.done();
    try check(equal(tagOf(bytes).?, "COPY 2"));
    _ = try a.query("SELECT label FROM t WHERE id = 10");
    try check(equal(a.session.result.rows[0].cells[0].text.slice(), "x,\"y\""));
    _ = try a.query("SELECT label FROM t WHERE id = 11");
    try check(a.session.result.rows[0].cells[0] == .null_value);

    // Binary: header, one tuple, trailer.
    _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN (FORMAT binary)\x00"));
    var bin: [64]u8 = undefined;
    var at: usize = 0;
    @memcpy(bin[0..11], fmt.signature);
    @memset(bin[11..19], 0);
    at = 19;
    const tuple = [_]u8{ 0, 2, 0, 0, 0, 4, 0, 0, 0, 20, 0, 0, 0, 3, 'b', 'i', 'n', 0xff, 0xff };
    @memcpy(bin[at..][0..tuple.len], &tuple);
    at += tuple.len;
    _ = try a.data(bin[0..at]);
    bytes = try a.done();
    try check(equal(tagOf(bytes).?, "COPY 1"));
    _ = try a.query("SELECT label FROM t WHERE id = 20");
    try check(equal(a.session.result.rows[0].cells[0].text.slice(), "bin"));
    // A wrong field count is 22P04; an int4 field of 2 bytes is 22P03.
    _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN (FORMAT binary)\x00"));
    bin[20] = 3;
    reply = try a.data(bin[0..at]);
    try check(equal(sqlstate(output[0..reply.written]).?, "22P04"));
    try check((try a.done()).len == 0);
    _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN (FORMAT binary)\x00"));
    const short = [_]u8{ 0, 2, 0, 0, 0, 2, 0, 21, 0, 0, 0, 1, 'x', 0xff, 0xff };
    @memcpy(bin[19..][0..short.len], &short);
    reply = try a.data(bin[0 .. 19 + short.len]);
    try check(equal(sqlstate(output[0..reply.written]).?, "22P03"));
    _ = try a.done();
    try check(try a.count("t") == 6);

    // Malformed rows: everything rolls back, later copy messages are dropped.
    const bad = [_]struct { data: []const u8, state: []const u8 }{
        .{ .data = "30\ta\n31\n", .state = "22P04" },
        .{ .data = "30\ta\n31\tb\textra\n", .state = "22P04" },
        .{ .data = "30\ta\nzz\tb\n", .state = "22P02" },
        .{ .data = "30\ta\n1\tdup\n", .state = "23505" },
    };
    for (bad) |case| {
        _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN\x00"));
        reply = try a.data(case.data);
        try check(equal(sqlstate(output[0..reply.written]).?, case.state) and readyStatus(output[0..reply.written]).? == 'I');
        reply = try a.data("40\tdropped\n");
        try check(reply.written == 0);
        try check((try a.done()).len == 0);
        try check(try a.count("t") == 6);
        try quiet(&store);
    }
    // CopyFail is 57014.
    _ = try a.handle(frame(&message, 'Q', "COPY t (id, label) FROM STDIN\x00"));
    _ = try a.data("50\tx\n");
    reply = try a.handle(frame(&message, 'f', "client abort\x00"));
    try check(equal(sqlstate(output[0..reply.written]).?, "57014"));
    try check(try a.count("t") == 6);
    try quiet(&store);
    // Option errors.
    for ([_]struct { sql: []const u8, state: []const u8 }{
        .{ .sql = "COPY t FROM STDIN (FORMAT binary, DELIMITER ',')\x00", .state = "42601" },
        .{ .sql = "COPY t FROM STDIN (DELIMITER 'ab')\x00", .state = "0A000" },
        .{ .sql = "COPY t FROM STDIN (FORMAT xml)\x00", .state = "22023" },
        .{ .sql = "COPY t FROM STDIN (QUOTE '\"')\x00", .state = "0A000" },
        .{ .sql = "COPY t (n, n) FROM STDIN\x00", .state = "42701" },
        .{ .sql = "COPY missing FROM STDIN\x00", .state = "42P01" },
        .{ .sql = "COPY t FROM '/etc/passwd'\x00", .state = "0A000" },
    }) |case| {
        reply = try a.handle(frame(&message, 'Q', case.sql));
        try check(equal(sqlstate(output[0..reply.written]).?, case.state) and readyStatus(output[0..reply.written]).? == 'I');
    }

    // COPY inside a block, then ROLLBACK; an error inside a block fails it.
    _ = try a.query("BEGIN");
    _ = try a.handle(frame(&message, 'Q', "COPY t (id) FROM STDIN\x00"));
    _ = try a.data("60\n61\n");
    bytes = try a.done();
    try check(equal(tagOf(bytes).?, "COPY 2") and readyStatus(bytes).? == 'T');
    _ = try a.query("ROLLBACK");
    try check(try a.count("t") == 6);
    _ = try a.query("BEGIN");
    _ = try a.handle(frame(&message, 'Q', "COPY t (id) FROM STDIN\x00"));
    reply = try a.data("x\n");
    try check(readyStatus(output[0..reply.written]).? == 'E');
    _ = try a.done();
    _ = try a.query("ROLLBACK");
    try quiet(&store);

    // A CopyData message larger than any input buffer, delivered in small
    // slices with the message header split from its body; each row is 245
    // input bytes decoding to 60 (octal escapes), so rows cross slices.
    _ = try a.query("CREATE TABLE narrow (id INTEGER PRIMARY KEY, body TEXT)");
    var big: [100 * 1024]u8 = undefined;
    var used: usize = 0;
    for (0..300) |row| {
        used += (try std.fmt.bufPrint(big[used..], "{d}\t", .{row})).len;
        for (0..60) |_| {
            @memcpy(big[used..][0..4], "\\101");
            used += 4;
        }
        big[used] = '\n';
        used += 1;
    }
    try check(used > 65536);
    _ = try a.handle(frame(&message, 'Q', "COPY narrow FROM STDIN\x00"));
    var stream: [5]u8 = undefined;
    stream[0] = 'd';
    put32(stream[1..5], @intCast(used + 4));
    reply = try a.handle(&stream);
    try check(reply.consumed == 5 and reply.written == 0);
    var offset: usize = 0;
    while (offset < used) {
        const piece = @min(used - offset, 700);
        reply = try a.handle(big[offset..][0..piece]);
        try check(reply.consumed == piece and reply.written == 0);
        offset += piece;
    }
    bytes = try a.done();
    try check(equal(tagOf(bytes).?, "COPY 300"));
    try check(try a.count("narrow") == 300);
    _ = try a.query("SELECT body FROM narrow WHERE id = 299");
    try check(a.session.result.rows[0].cells[0].text.len == 60 and a.session.result.rows[0].cells[0].text.bytes[59] == 'A');
    _ = try a.query("DELETE FROM narrow");
    // A row longer than copy_line_bytes is 54000.
    _ = try a.handle(frame(&message, 'Q', "COPY narrow FROM STDIN\x00"));
    @memset(big[0 .. Raw.copy_line_bytes + 10], 'y');
    reply = try a.data(big[0 .. Raw.copy_line_bytes + 10]);
    try check(equal(sqlstate(output[0..reply.written]).?, "54000"));
    _ = try a.done();
    try check(try a.count("narrow") == 0);
    // Write-set capacity (tx_writes 512): 53200 with nothing inserted.
    _ = try a.handle(frame(&message, 'Q', "COPY narrow FROM STDIN\x00"));
    used = 0;
    for (0..520) |index| used += (try std.fmt.bufPrint(big[used..], "{d}\tw\n", .{1000 + index})).len;
    reply = try a.data(big[0..used]);
    try check(equal(sqlstate(output[0..reply.written]).?, "53200"));
    _ = try a.done();
    try check(try a.count("narrow") == 0);
    try quiet(&store);
    _ = try a.query("DROP TABLE narrow");

    // COPY TO STDOUT text / csv / binary.
    _ = try a.query("CREATE TABLE o (id INTEGER PRIMARY KEY, label TEXT)");
    _ = try a.query("INSERT INTO o VALUES (1, 'a\tb'), (2, NULL), (3, '')");
    var out: [4096]u8 = undefined;
    try check(equal(try copyOut(try a.query("COPY o TO STDOUT"), &out), "1\ta\\tb\n2\t\\N\n3\t\n"));
    bytes = try a.query("COPY o TO STDOUT (FORMAT csv, HEADER)");
    try check(equal(tagOf(bytes).?, "COPY 3") and readyStatus(bytes).? == 'I');
    try check(equal(try copyOut(bytes, &out), "id,label\n1,a\tb\n2,\n3,\"\"\n"));
    try check(equal(try copyOut(try a.query("COPY (SELECT label FROM o WHERE id = 1) TO STDOUT"), &out), "a\\tb\n"));
    const binary_out = try copyOut(try a.query("COPY o (id) TO STDOUT (FORMAT binary)"), &out);
    try check(binary_out.len == 19 + 3 * 10 + 2 and equal(binary_out[0..11], fmt.signature) and binary_out[19 + 9] == 1 and binary_out[binary_out.len - 1] == 0xff);

    // Disconnect mid-COPY rolls it back.
    _ = try b.handle(frame(&message, 'Q', "COPY o FROM STDIN\x00"));
    _ = try b.data("70\tgone\n");
    b.connection.disconnect();
    b = .{ .connection = .{ .store = &store, .id = 3 } };
    try b.startup();
    try check(try a.count("o") == 3);
    try quiet(&store);

    // Row-level parking (CP1): A inserts key 5 in an open block; B's COPY
    // parks at row 5 with the input through that row consumed.
    for ([_]bool{ true, false }) |commit| {
        _ = try a.query("DELETE FROM o WHERE id >= 4");
        _ = try a.query("BEGIN");
        _ = try a.query("INSERT INTO o VALUES (5, 'a')");
        _ = try b.handle(frame(&message, 'Q', "COPY o FROM STDIN\x00"));
        const rows_text = "4\tb\n5\tb\n6\tb\n";
        var input: [64]u8 = undefined;
        const first = frame(&input, 'd', rows_text);
        reply = try b.handle(first);
        try check(reply.blocked and reply.written == 0 and reply.consumed == 5 + 8 and b.connection.blocked());
        // Still parked: nothing happens without progress.
        reply = try b.handle(first[reply.consumed..]);
        try check(reply.blocked and reply.consumed == 0);
        try check(!b.connection.wakeReady());
        _ = try a.query(if (commit) "COMMIT" else "ROLLBACK");
        try check(b.connection.wakeReady());
        reply = try b.handle(first[13..]);
        if (commit) {
            try check(equal(sqlstate(output[0..reply.written]).?, "23505") and reply.consumed == 0);
            // The rest of the message is discarded, then CopyDone.
            reply = try b.handle(first[13..]);
            try check(reply.consumed == first.len - 13 and reply.written == 0);
            try check((try b.done()).len == 0);
            _ = try a.query("SELECT id FROM o WHERE id >= 4");
            try check(a.session.result.row_count == 1 and a.session.result.rows[0].cells[0].integer == 5);
        } else {
            try check(reply.consumed == first.len - 13 and reply.written == 0);
            bytes = try b.done();
            try check(equal(tagOf(bytes).?, "COPY 3"));
            try check(try a.count("o") == 6);
        }
        try quiet(&store);
    }
    // Parked COPY canceled: 57014 and nothing inserted.
    _ = try a.query("DELETE FROM o WHERE id >= 4");
    _ = try a.query("BEGIN");
    _ = try a.query("INSERT INTO o VALUES (8, 'a')");
    _ = try b.handle(frame(&message, 'Q', "COPY o FROM STDIN\x00"));
    reply = try b.data("7\tb\n8\tb\n");
    try check(reply.blocked);
    b.connection.requestCancel();
    reply = try b.handle("");
    try check(equal(sqlstate(output[0..reply.written]).?, "57014"));
    _ = try b.done();
    _ = try a.query("ROLLBACK");
    try check(try a.count("o") == 3);
    try quiet(&store);
}

pub fn main(init: std.process.Init) !void {
    try formats();
    try protocol();
    var report: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&report, "{{\"suite\":\"pg-copy\",\"pass\":true,\"assertions\":{d},\"session_bytes\":{d}}}\n", .{ assertions, @sizeOf(Session) });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
