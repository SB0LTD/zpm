//! Privileges contract (conformance lane B11, wave 5): column privileges,
//! grant options and grant chains with their grantors, REVOKE [GRANT OPTION
//! FOR] ... CASCADE / RESTRICT, schema USAGE / CREATE (the public schema
//! included), sequence and type privileges, ALL TABLES / SEQUENCES IN
//! SCHEMA, REFERENCES on foreign keys, the TRIGGER privilege, role grants
//! keyed by grantor (PostgreSQL 16+), predefined roles, has_*_privilege and
//! pg_has_role, and the warnings / notices PostgreSQL sends.
//!
//! The programs of sql_privileges_oracle.sig were recorded from native
//! PostgreSQL 18.7 (tests/sql_conformance/record_privileges.py) and run here
//! through the PostgreSQL wire session over a store connection, one simple
//! Query per statement: the canonical head (message order, RowDescription,
//! command tags, SQLSTATEs, NoticeResponse SQLSTATE and text) and the rows
//! must match. Every committed change record is applied to a replica that
//! must answer the ACL catalogs exactly like the primary. Direct sections
//! check crafted change records (InvalidChangeRecord / ChangeRecordConflict),
//! capacity (54000), atomicity and waits on uncommitted grants.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const oracle = @import("sql_privileges_oracle.sig");

const DB = sql.Database(.{ .tables = 16, .columns = 16, .rows_per_table = 64, .name_bytes = 63, .text_bytes = 512,
    .nulls_first_ascending = false, .integer_bits = 32, .expr_nodes = 2048, .work_rows = 256, .result_rows = 128,
    .relations = 8, .subqueries = 32, .ctes = 8, .schemas = 8, .transactions = 4, .predicates = 32, .sequences = 8,
    .routines = 32, .triggers = 16, .rules = 8, .catalog_objects = 128, .cursors = 8, .cursor_rows = 128 });
const Store = @import("db_store").Store(DB);
const Session = pg.Session(Store.Connection);
/// Four catalog object versions (capacity: 54000 TableCapacity).
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 64,
    .nulls_first_ascending = false, .integer_bits = 32, .catalog_objects = 4, .object_text_bytes = 16, .policy_roles = 1 });

var assertions: usize = 0;
var store: Store = .{};
var replica: DB = .{};
var conn: Store.Connection = undefined;
var wire: Session = .{};
var scratch: DB.ReplayScratch = .{};
var encode: [65536]u8 = undefined;
var records_applied: usize = 0;
var output: [Session.responseCapacity()]u8 = undefined;
var packet: [16384]u8 = undefined;
var head: [8192]u8 = undefined;
var head_len: usize = 0;
var rows_text: [65536]u8 = undefined;
var row_ends: [512]usize = undefined;
var row_count: usize = 0;
var used: [512]bool = undefined;
var text_buffer: [16384]u8 = undefined;
var probe_copy: [16384]u8 = undefined;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("privileges contract failed at assertion {d}\n", .{assertions});
        return error.PrivilegesContractFailed;
    }
}

const Out = struct {
    buf: []u8,
    len: usize = 0,
    fn put(self: *Out, bytes: []const u8) !void {
        if (bytes.len > self.buf.len - self.len) return error.CanonicalCapacity;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
    fn byte(self: *Out, value: u8) !void {
        if (self.len == self.buf.len) return error.CanonicalCapacity;
        self.buf[self.len] = value;
        self.len += 1;
    }
    fn int(self: *Out, value: i64) !void {
        var digits: [24]u8 = undefined;
        try self.put(try std.fmt.bufPrint(&digits, "{d}", .{value}));
    }
    fn esc(self: *Out, bytes: []const u8) !void {
        const hex = "0123456789abcdef";
        for (bytes) |b| switch (b) {
            '\\', '|', ',', '/', ';', '#' => {
                try self.byte('\\');
                try self.byte(b);
            },
            else => if (b < 0x20 or b == 0x7f) {
                try self.put("\\x");
                try self.byte(hex[b >> 4]);
                try self.byte(hex[b & 15]);
            } else try self.byte(b),
        };
    }
};

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}

fn be16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn put32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value >> 24);
    bytes[1] = @truncate(value >> 16);
    bytes[2] = @truncate(value >> 8);
    bytes[3] = @truncate(value);
}

fn persist(_: ?*anyopaque, payload: []const u8) anyerror!void {
    replica.applyChangeRecord(payload, &scratch) catch |err| {
        std.debug.print("replay failed: {s}\n", .{@errorName(err)});
        return err;
    };
    records_applied += 1;
}

fn startup() !void {
    var at: usize = 4;
    put32(packet[at..], 196608);
    at += 4;
    for ([_][]const u8{ "user", "ramsql", "database", "w5_privileges_probe", "client_encoding", "UTF8", "TimeZone", "UTC" }) |item| {
        @memcpy(packet[at..][0..item.len], item);
        at += item.len;
        packet[at] = 0;
        at += 1;
    }
    packet[at] = 0;
    at += 1;
    put32(packet[0..4], @intCast(at));
    const reply = try wire.handle(&conn, packet[0..at], &output);
    if (reply.consumed != at or !wire.startup or reply.close) return error.StartupFailed;
}

fn query(source: []const u8) ![]const u8 {
    if (source.len + 6 > packet.len) return error.StatementTooLong;
    packet[0] = 'Q';
    @memcpy(packet[5..][0..source.len], source);
    packet[5 + source.len] = 0;
    const length = 4 + source.len + 1;
    put32(packet[1..5], @intCast(length));
    const reply = try wire.handle(&conn, packet[0 .. 1 + length], &output);
    if (reply.blocked) return error.Blocked;
    if (reply.close) return error.ConnectionClosed;
    if (reply.consumed != 1 + length) return error.PartialFrame;
    return output[0..reply.written];
}

const Frame = struct { kind: u8, body: []const u8 };

fn nextFrame(bytes: []const u8, at: *usize) !?Frame {
    if (at.* == bytes.len) return null;
    if (bytes.len - at.* < 5) return error.TruncatedFrame;
    const length = be32(bytes[at.* + 1 ..][0..4]);
    if (length < 4 or length > bytes.len - at.* - 1) return error.TruncatedFrame;
    const frame: Frame = .{ .kind = bytes[at.*], .body = bytes[at.* + 5 .. at.* + 1 + length] };
    at.* += 1 + length;
    return frame;
}

fn zeroEnd(body: []const u8, from: usize) !usize {
    return std.mem.indexOfScalarPos(u8, body, from, 0) orelse error.MalformedFrame;
}

fn field(body: []const u8, wanted: u8) ![]const u8 {
    var offset: usize = 0;
    while (offset < body.len and body[offset] != 0) {
        const end = try zeroEnd(body, offset + 1);
        if (body[offset] == wanted) return body[offset + 1 .. end];
        offset = end + 1;
    }
    return "";
}

/// One statement's canonical head (record_privileges.py) and rows.
fn execute(source: []const u8) !void {
    const bytes = try query(source);
    var raw: Out = .{ .buf = &head };
    var rows: Out = .{ .buf = &rows_text };
    row_count = 0;
    var status: u8 = 0;
    var at: usize = 0;
    var mark_head: usize = 0;
    var mark_rows: usize = 0;
    while (try nextFrame(bytes, &at)) |frame| {
        const body = frame.body;
        if (frame.kind == 'E') {
            raw.len = mark_head;
            row_count = mark_rows;
            rows.len = if (mark_rows == 0) 0 else row_ends[mark_rows - 1];
        }
        switch (frame.kind) {
            'T' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("T:");
                var offset: usize = 2;
                for (0..be16(body[0..2])) |column| {
                    if (column != 0) try raw.byte(',');
                    const end = try zeroEnd(body, offset);
                    try raw.esc(body[offset..end]);
                    try raw.byte('/');
                    const oid = be32(body[end + 7 ..][0..4]);
                    if (oid >= 16384) try raw.byte('#') else try raw.int(oid);
                    try raw.byte('/');
                    try raw.int(@as(i16, @bitCast(be16(body[end + 11 ..][0..2]))));
                    try raw.byte('/');
                    try raw.int(@as(i32, @bitCast(be32(body[end + 13 ..][0..4]))));
                    offset = end + 19;
                }
            },
            'D' => {
                if (row_count == row_ends.len) return error.CanonicalCapacity;
                var offset: usize = 2;
                for (0..be16(body[0..2])) |cell| {
                    if (cell != 0) try rows.byte('|');
                    const size: i32 = @bitCast(be32(body[offset..][0..4]));
                    offset += 4;
                    if (size < 0) {
                        try rows.put("\\N");
                    } else {
                        try rows.esc(body[offset..][0..@intCast(size)]);
                        offset += @intCast(size);
                    }
                }
                row_ends[row_count] = rows.len;
                row_count += 1;
            },
            'N' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("N:");
                try raw.put(try field(body, 'C'));
                try raw.byte(':');
                try raw.esc(try field(body, 'M'));
            },
            'C' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("C:");
                try raw.esc(body[0..try zeroEnd(body, 0)]);
            },
            'E' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("E:");
                try raw.put(try field(body, 'C'));
            },
            'I' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.byte('I');
            },
            'Z' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("Z:");
                try raw.byte(body[0]);
                status = body[0];
            },
            else => {},
        }
        if (frame.kind == 'C' or frame.kind == 'E' or frame.kind == 'I' or frame.kind == 'Z') {
            mark_head = raw.len;
            mark_rows = row_count;
        }
    }
    if (status == 0) return error.MissingReadyForQuery;
    head_len = raw.len;
}

fn row(index: usize) []const u8 {
    return rows_text[if (index == 0) 0 else row_ends[index - 1]..row_ends[index]];
}

fn rowsMatch(expected: []const []const u8) bool {
    if (expected.len != row_count) return false;
    @memset(used[0..row_count], false);
    outer: for (expected) |wanted| {
        for (0..row_count) |candidate| {
            if (!used[candidate] and std.mem.eql(u8, wanted, row(candidate))) {
                used[candidate] = true;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

/// ACL catalogs the replica must answer like the primary.
const state_probes = [_][]const u8{
    "SELECT relname, relacl::text FROM pg_class WHERE relacl IS NOT NULL ORDER BY relname",
    "SELECT attrelid, attname, attacl::text FROM pg_attribute WHERE attacl IS NOT NULL ORDER BY attrelid, attnum",
    "SELECT oid, nspname, nspacl::text FROM pg_namespace ORDER BY oid",
    "SELECT typname, typacl::text FROM pg_type WHERE typacl IS NOT NULL ORDER BY typname",
    "SELECT oid, roleid, member, grantor, admin_option, inherit_option, set_option FROM pg_auth_members ORDER BY oid",
    "SELECT oid, rolname FROM pg_roles ORDER BY oid",
};

fn render(target: anytype, source: []const u8) ![]const u8 {
    const T = @TypeOf(target.*);
    var result: T.Result = .{};
    target.execute(source, &result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    var at: usize = 0;
    var cell_buffer: [T.Io.format_bytes]u8 = undefined;
    for (0..result.row_count) |index| {
        if (index != 0) {
            text_buffer[at] = ';';
            at += 1;
        }
        for (0..result.column_count) |column| {
            if (column != 0) {
                text_buffer[at] = '|';
                at += 1;
            }
            const cell = &result.rows[index].cells[column];
            const text = if (cell.* == .null_value) "NULL" else try T.Io.format(cell, false, T.Result.default_session, &cell_buffer);
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

fn sameReplica(primary: *DB) !void {
    for (state_probes) |probe| {
        const left = try render(primary, probe);
        @memcpy(probe_copy[0..left.len], left);
        const right = try render(&replica, probe);
        if (!std.mem.eql(u8, probe_copy[0..left.len], right)) std.debug.print("replay differs: {s}\n  primary {s}\n  replica {s}\n", .{ probe, probe_copy[0..left.len], right });
        try check(std.mem.eql(u8, probe_copy[0..left.len], right));
    }
    try check(primary.oid_counter == replica.oid_counter);
}

fn runProgram(program: *const oracle.Program) !void {
    store = .{ .encode_buffer = &encode };
    store.commit_fn = persist;
    replica = .{};
    conn = .{ .store = &store, .id = 1 };
    wire = .{};
    try startup();
    for (program.statements, 0..) |*statement, index| {
        try execute(statement.source);
        const head_ok = std.mem.eql(u8, head[0..head_len], statement.head);
        const rows_ok = rowsMatch(statement.rows);
        if (!head_ok or !rows_ok) {
            std.debug.print("{s} #{d}: {s}\n  wanted {s}", .{ program.name, index, statement.source, statement.head });
            for (statement.rows) |wanted| std.debug.print(" [{s}]", .{wanted});
            std.debug.print("\n  got    {s}", .{head[0..head_len]});
            for (0..row_count) |got| std.debug.print(" [{s}]", .{row(got)});
            std.debug.print("\n", .{});
        }
        assertions += 2;
        if (!head_ok or !rows_ok) mismatches += 1;
    }
    try sameReplica(&store.database);
}

var mismatches: usize = 0;

// ---- direct sections ----------------------------------------------------------

var db: DB = .{};
var small: Small = .{};
var record: [65536]u8 = undefined;

fn run(source: []const u8) !void {
    var result: DB.Result = .{};
    var length: usize = 0;
    db.executeChanges(source, &result, &record, &length, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (length != 0) {
        try replica.applyChangeRecord(record[0..length], &scratch);
        records_applied += 1;
    }
}

fn expect(source: []const u8, wanted: []const u8) !void {
    const got = try render(&db, source);
    if (!std.mem.eql(u8, got, wanted)) std.debug.print("{s}\n  wanted {s}\n  got    {s}\n", .{ source, wanted, got });
    try check(std.mem.eql(u8, got, wanted));
}

fn putInt(out: []u8, at: *usize, comptime T: type, value: T) void {
    const Bits = switch (@sizeOf(T)) {
        1 => u8,
        2 => u16,
        4 => u32,
        else => @compileError("record field"),
    };
    const bits: Bits = @bitCast(value);
    for (0..@sizeOf(T)) |index| out[at.* + index] = @truncate(bits >> @intCast(index * 8));
    at.* += @sizeOf(T);
}

/// One op-70 record: kind, key, owner, flags, grant flags, no name or
/// roles, `text`, split 0.
fn objectRecord(out: []u8, kind: u8, oid: u32, target: u32, grantee: u32, sub: i32, owner: u32, flags: u32, grant_flags: u32, text: []const u8) []const u8 {
    var at: usize = 0;
    putInt(out, &at, u16, 1);
    putInt(out, &at, u16, 0);
    putInt(out, &at, u32, 1);
    putInt(out, &at, u8, 70);
    putInt(out, &at, u8, kind);
    putInt(out, &at, u32, oid);
    putInt(out, &at, u32, target);
    putInt(out, &at, u32, grantee);
    putInt(out, &at, i32, sub);
    putInt(out, &at, u32, owner);
    putInt(out, &at, u32, flags);
    putInt(out, &at, u32, grant_flags);
    putInt(out, &at, u8, 0);
    putInt(out, &at, u8, 0);
    putInt(out, &at, u16, @intCast(text.len));
    @memcpy(out[at..][0..text.len], text);
    at += text.len;
    putInt(out, &at, u16, 0);
    return out[0..at];
}

fn commit(slot: u16) !void {
    if (!db.readOnly(slot)) {
        const payload = try db.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &scratch);
        records_applied += 1;
    }
    db.publishCommit(slot);
}

fn replayFails(bytes: []const u8, wanted: anyerror) !void {
    if (replica.applyChangeRecord(bytes, &scratch)) |_| {
        std.debug.print("crafted record accepted at assertion {d}\n", .{assertions});
        return error.InvalidRecordAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("crafted record: {s} (wanted {s})\n", .{ @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn number(source: []const u8) !u32 {
    return std.fmt.parseInt(u32, try render(&db, source), 10);
}

/// Crafted grant rows fail closed; the committed state is untouched.
fn craftedRecords() !void {
    db = .{};
    replica = .{};
    try run("CREATE TABLE t(a INT, b INT)");
    try run("CREATE ROLE w5p_r");
    try run("GRANT SELECT (b) ON t TO w5p_r");
    try run("GRANT SELECT ON t TO w5p_r WITH GRANT OPTION");
    const table = try number("SELECT oid FROM pg_class WHERE relname = 't'");
    const role = try number("SELECT oid FROM pg_roles WHERE rolname = 'w5p_r'");
    var bytes: [256]u8 = undefined;
    const select_nibble = 2;
    // Column rows: odd length, options beyond privileges, a zero last
    // column, positions without privileges, flags that disagree.
    try replayFails(objectRecord(&bytes, 100, 0, table, role, 0, 10, 2, 0, &.{select_nibble}), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 100, 0, table, role, 0, 10, 2, 1, &.{ select_nibble | 0x10, 1 }), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 100, 0, table, role, 0, 10, 2, 0, &.{ select_nibble, 1, 0, 0 }), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 100, 0, table, role, 0, 10, 2, 0, &.{ select_nibble, 0 }), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 100, 0, table, role, 0, 10, 1, 0, &.{ select_nibble, 1 }), error.InvalidChangeRecord);
    // A delegated row's grantor key must name its grantor.
    try replayFails(objectRecord(&bytes, 100, 0, table, role, @bitCast(role), 10, 2, 0, &.{ select_nibble, 1 }), error.InvalidChangeRecord);
    // Beyond the table's columns, an unknown table or grantee: conflicts.
    try replayFails(objectRecord(&bytes, 100, 0, table, 10, 0, 10, 2, 0, &.{ 0, 0, 0, 0, select_nibble, 1 }), error.ChangeRecordConflict);
    try replayFails(objectRecord(&bytes, 100, 0, 99999, role, 0, 10, 2, 0, &.{ select_nibble, 1 }), error.ChangeRecordConflict);
    try replayFails(objectRecord(&bytes, 100, 0, table, 99999, 0, 10, 2, 0, &.{ select_nibble, 1 }), error.ChangeRecordConflict);
    // Table rows: PUBLIC holds no options; positions are nonzero; the
    // owner's marker carries only the marker bit and options in its flags.
    try replayFails(objectRecord(&bytes, 3, 7, table, 0, 0, 10, 2, 2, ""), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 3, 0, table, 16999, @bitCast(role), role, 2, 0, ""), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 3, 0, table, 10, 0, 10, 2, (1 << 31) | 4, ""), error.InvalidChangeRecord);
    // A grant row already present conflicts (same table, grantee, grantor).
    try replayFails(objectRecord(&bytes, 3, 9, table, role, 0, 10, 2, 0, ""), error.ChangeRecordConflict);
    // Sequence and type rows: their own privilege sets and live objects.
    try replayFails(objectRecord(&bytes, 102, 3, table, role, 0, 10, 1, 0, ""), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 102, 3, table, role, 0, 10, 2, 0, ""), error.ChangeRecordConflict);
    try replayFails(objectRecord(&bytes, 101, 3, 99999, role, 0, 10, 256, 0, ""), error.ChangeRecordConflict);
    try replayFails(objectRecord(&bytes, 101, 3, 99999, role, 0, 10, 2, 0, ""), error.InvalidChangeRecord);
    // Unknown kinds after the lane's range; memberships keyed by grantor.
    try replayFails(objectRecord(&bytes, 103, 0, table, role, 0, 10, 2, 0, ""), error.InvalidChangeRecord);
    try replayFails(objectRecord(&bytes, 2, 16999, 10, role, @bitCast(role), 10, 0, 0, ""), error.InvalidChangeRecord);
    try sameReplica(&db);
}

/// Grant rows and markers count against Config.catalog_objects (54000);
/// a failed GRANT leaves the ACL as it was.
fn capacity() !void {
    small = .{};
    var result: Small.Result = .{};
    try small.execute("CREATE TABLE t (id INT PRIMARY KEY, v INT)", &result);
    try small.execute("CREATE ROLE a", &result);
    // The role, the owner's marker, a's grant and PUBLIC's: four versions.
    try small.execute("GRANT SELECT ON t TO a", &result);
    try small.execute("GRANT INSERT ON t TO PUBLIC", &result);
    if (small.execute("GRANT SELECT (v) ON t TO a", &result)) |_| return error.CapacityAccepted else |err| try check(err == error.TableCapacity);
    if (small.execute("GRANT UPDATE ON t TO a", &result)) |_| return error.CapacityAccepted else |err| try check(err == error.TableCapacity);
    try small.execute("SELECT relacl::text FROM pg_class WHERE relname = 't'", &result);
    var cell_buffer: [Small.Io.format_bytes]u8 = undefined;
    try check(std.mem.eql(u8, try Small.Io.format(&result.rows[0].cells[0], false, Small.Result.default_session, &cell_buffer), "{ramsql=arwdDxtm/ramsql,a=r/ramsql,=a/ramsql}"));
    try check(small.usage().pending_versions == 0 and small.usage().transactions == 0);
}

/// A GRANT waits for another transaction's uncommitted grant on the same
/// object, then applies over the committed ACL.
fn concurrency() !void {
    db = .{};
    replica = .{};
    try run("CREATE TABLE t(a INT)");
    try run("CREATE ROLE w5p_a");
    try run("CREATE ROLE w5p_b");
    var result: DB.Result = .{};
    const first = try db.begin();
    try db.statement(first, "GRANT SELECT ON t TO w5p_a", &result, .{});
    const second = try db.begin();
    if (db.statement(second, "GRANT UPDATE ON t TO w5p_b", &result, .{})) |_| return error.GrantDidNotWait else |err| try check(err == error.WouldBlock);
    try check(db.parked(second));
    try commit(first);
    try db.statement(second, "GRANT UPDATE ON t TO w5p_b", &result, .{ .@"resume" = true });
    try commit(second);
    try expect("SELECT relacl::text FROM pg_class WHERE relname = 't'", "{ramsql=arwdDxtm/ramsql,w5p_a=r/ramsql,w5p_b=w/ramsql}");
    // A failed REVOKE (2BP01) is atomic.
    try run("GRANT SELECT ON t TO w5p_a WITH GRANT OPTION");
    try run("SET ROLE w5p_a");
    try run("GRANT SELECT ON t TO w5p_b");
    try run("RESET ROLE");
    var length: usize = 0;
    if (db.executeChanges("REVOKE SELECT ON t FROM w5p_a", &result, &record, &length, null, null)) |_| return error.RevokeAccepted else |err| try check(err == error.DependentObjects);
    try check(length == 0);
    try expect("SELECT relacl::text FROM pg_class WHERE relname = 't'", "{ramsql=arwdDxtm/ramsql,w5p_a=r*/ramsql,w5p_b=w/ramsql,w5p_b=r/w5p_a}");
    try check(db.usage().pending_versions == 0 and db.usage().transactions == 0);
}

pub fn main(init: std.process.Init) !void {
    for (&oracle.programs) |*program| {
        runProgram(program) catch |err| {
            std.debug.print("program {s}: {s}\n", .{ program.name, @errorName(err) });
            return err;
        };
    }
    if (mismatches != 0) {
        std.debug.print("{d} statements differ from native PostgreSQL 18.7\n", .{mismatches});
        return error.PrivilegesContractFailed;
    }
    try craftedRecords();
    try capacity();
    try concurrency();
    var summary: [160]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&summary,
        "privileges: {d} programs, {d} assertions, {d} records replayed\n", .{ oracle.programs.len, assertions, records_applied }));
}
