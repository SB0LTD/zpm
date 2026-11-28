//! information_schema and CURRENT_CATALOG / CURRENT_SCHEMA contract (B11
//! wave 5, catalog lane; F021, F231, F341, F501, F502, F762, F763, F869,
//! T321-06, T321-07).
//!
//! Part 1 runs the scripts of tests/sql_conformance/catalog_views/ through
//! the PostgreSQL wire session over a store connection, one simple Query
//! per statement, continuing after errors, and compares every response
//! with the native PostgreSQL 18.7 recording in
//! test_sql_catalog_views_cases.sig (tools/capture_sql_catalog_views.py):
//! message order, RowDescription name/type/typlen/typmod (domains report
//! their base type: sql_identifier 19/64/-1, cardinal_number 23/4/-1,
//! character_data 1043/-1/-1, yes_or_no 1043/-1/7), command tags,
//! SQLSTATEs, ReadyForQuery status and DataRow text with NULLs. Rows are
//! compared in order when the statement has ORDER BY.
//!
//! Part 2 checks what the recording cannot: the views read the statement
//! snapshot (a transaction sees its own uncommitted DDL, another does not;
//! an aborted DDL leaves no trace), a replica built from the change records
//! answers every view like the primary, and a view wider than a small
//! configuration's workspace fails cleanly with 54000, leaving the state
//! unchanged.
const std = @import("std");
const sql = @import("sql");
const pg = @import("postgres");
const cases = @import("test_sql_catalog_views_cases.sig");

const DB = sql.Database(.{ .tables = 16, .columns = 16, .projection_columns = 96, .rows_per_table = 64, .name_bytes = 63, .text_bytes = 256,
    .nulls_first_ascending = false, .integer_bits = 32, .expr_nodes = 2048, .work_rows = 512, .result_rows = 256,
    .relations = 8, .subqueries = 32, .ctes = 8, .schemas = 8, .transactions = 4, .predicates = 32,
    .routines = 32, .triggers = 16, .rules = 8, .catalog_objects = 128, .cursors = 8, .cursor_rows = 128 });
const Store = @import("db_store").Store(DB);
const Session = pg.Session(Store.Connection);
/// A workspace of 64 cells: unfiltered information_schema.columns is 54000.
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 8, .name_bytes = 32, .text_bytes = 64,
    .nulls_first_ascending = false, .integer_bits = 32 });

var store: Store = .{};
var conn: Store.Connection = undefined;
var wire: Session = .{};
var output: [Session.responseCapacity()]u8 = undefined;
var packet: [16384]u8 = undefined;
var raw_head: [8192]u8 = undefined;
var head: [8192]u8 = undefined;
var head_len: usize = 0;
var rows_text: [1 << 18]u8 = undefined;
var row_ends: [1024]usize = undefined;
var row_count: usize = 0;
var used_rows: [1024]bool = undefined;
var assertions: usize = 0;

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("catalog-views contract failed at assertion {d}\n", .{assertions});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
        return error.CatalogViewsContractFailed;
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

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startup() !void {
    var at: usize = 4;
    put32(packet[at..], 196608);
    at += 4;
    for ([_][]const u8{ "user", "ramsql", "database", cases.database, "client_encoding", "UTF8", "TimeZone", "UTC" }) |item| {
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

/// Runs one statement and leaves its canonical head and rows in the buffers
/// (the canonical form of tests/sql_conformance/feature_probes.py).
fn execute(source: []const u8) !void {
    const bytes = try query(source);
    var raw: Out = .{ .buf = &raw_head };
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
                if (body.len < 2) return error.MalformedFrame;
                var offset: usize = 2;
                for (0..be16(body[0..2])) |column| {
                    if (column != 0) try raw.byte(',');
                    const end = try zeroEnd(body, offset);
                    if (body.len - end < 19) return error.MalformedFrame;
                    try raw.esc(body[offset..end]);
                    try raw.byte('/');
                    try raw.int(be32(body[end + 7 ..][0..4]));
                    try raw.byte('/');
                    try raw.int(@as(i16, @bitCast(be16(body[end + 11 ..][0..2]))));
                    try raw.byte('/');
                    try raw.int(@as(i32, @bitCast(be32(body[end + 13 ..][0..4]))));
                    offset = end + 19;
                }
            },
            'D' => {
                if (row_count == row_ends.len) return error.CanonicalCapacity;
                if (body.len < 2) return error.MalformedFrame;
                var offset: usize = 2;
                for (0..be16(body[0..2])) |cell| {
                    if (cell != 0) try rows.byte('|');
                    if (body.len - offset < 4) return error.MalformedFrame;
                    const size: i32 = @bitCast(be32(body[offset..][0..4]));
                    offset += 4;
                    if (size < 0) {
                        try rows.put("\\N");
                    } else {
                        if (@as(usize, @intCast(size)) > body.len - offset) return error.MalformedFrame;
                        try rows.esc(body[offset..][0..@intCast(size)]);
                        offset += @intCast(size);
                    }
                }
                row_ends[row_count] = rows.len;
                row_count += 1;
            },
            'C' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("C:");
                try raw.esc(body[0..try zeroEnd(body, 0)]);
            },
            'E' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.put("E:");
                var offset: usize = 0;
                while (offset < body.len and body[offset] != 0) {
                    const end = try zeroEnd(body, offset + 1);
                    if (body[offset] == 'C') try raw.put(body[offset + 1 .. end]);
                    offset = end + 1;
                }
            },
            'I' => {
                if (raw.len != 0) try raw.byte(';');
                try raw.byte('I');
            },
            'Z' => {
                if (body.len != 1) return error.MalformedFrame;
                if (raw.len != 0) try raw.byte(';');
                try raw.put("Z:");
                try raw.byte(body[0]);
                status = body[0];
            },
            'G', 'H', 'W' => return error.UnexpectedCopy,
            else => {},
        }
        if (frame.kind == 'C' or frame.kind == 'E' or frame.kind == 'I' or frame.kind == 'Z') {
            mark_head = raw.len;
            mark_rows = row_count;
        }
    }
    if (status == 0) return error.MissingReadyForQuery;
    @memcpy(head[0..raw.len], raw_head[0..raw.len]);
    head_len = raw.len;
}

fn row(index: usize) []const u8 {
    return rows_text[if (index == 0) 0 else row_ends[index - 1]..row_ends[index]];
}

fn rowsMatch(expected: []const []const u8, ordered: bool) bool {
    if (expected.len != row_count) return false;
    if (ordered) {
        for (expected, 0..) |wanted, index| {
            if (!same(wanted, row(index))) return false;
        }
        return true;
    }
    @memset(used_rows[0..row_count], false);
    outer: for (expected) |wanted| {
        for (0..row_count) |candidate| {
            if (!used_rows[candidate] and same(wanted, row(candidate))) {
                used_rows[candidate] = true;
                continue :outer;
            }
        }
        return false;
    }
    return true;
}

/// Part 1: every recorded statement on a fresh store per script.
fn recordedScripts() !usize {
    var statements: usize = 0;
    for (&cases.scripts) |*script| {
        store = .{};
        conn = .{ .store = &store, .id = 1 };
        wire = .{};
        try startup();
        for (script.statements) |*statement| {
            try execute(statement.source);
            const head_ok = same(head[0..head_len], statement.head);
            const rows_ok = rowsMatch(statement.rows, statement.ordered);
            if (!head_ok or !rows_ok) {
                std.debug.print("{s}: {s}\n  head {s}\n  want {s}\n", .{ script.name, statement.source, head[0..head_len], statement.head });
                for (0..@min(row_count, 8)) |index| std.debug.print("  got  {s}\n", .{row(index)});
                for (statement.rows[0..@min(statement.rows.len, 8)]) |wanted| std.debug.print("  want {s}\n", .{wanted});
            }
            try check(head_ok and rows_ok);
            statements += 1;
        }
    }
    return statements;
}

// ---- Part 2: snapshots, atomicity, replay and capacity ----------------------

var primary: DB = .{};
var replica: DB = .{};
var scratch: DB.ReplayScratch = .{};
var record: [65536]u8 = undefined;
var text_buffer: [65536]u8 = undefined;

fn render(comptime T: type, result: *const T.Result) ![]const u8 {
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
            if (text.len > text_buffer.len - at) return error.RenderCapacity;
            @memcpy(text_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return text_buffer[0..at];
}

var probe_result: DB.Result = .{};
/// Results live in globals: DB.Result is megabytes (a stack local overflows).
var statement_result: DB.Result = .{};

fn rowsOf(target: *DB, source: []const u8) ![]const u8 {
    target.execute(source, &probe_result) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(DB, &probe_result);
}

fn expectOn(target: *DB, source: []const u8, wanted: []const u8) !void {
    const got = try rowsOf(target, source);
    if (!same(got, wanted)) std.debug.print("{s}\n  got  {s}\n  want {s}\n", .{ source, got, wanted });
    try check(same(got, wanted));
}

fn rowsIn(slot: u16, source: []const u8) ![]const u8 {
    primary.statement(slot, source, &probe_result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    return render(DB, &probe_result);
}

fn statementIn(slot: u16, source: []const u8) !void {
    const result = &statement_result;
    primary.statement(slot, source, result, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// Autocommit on the primary; its change record goes to the replica.
fn durable(source: []const u8) !void {
    const result = &statement_result;
    var used: usize = 0;
    primary.executeChanges(source, result, &record, &used, null, null) catch |err| {
        std.debug.print("{s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
    if (used != 0) try replica.applyChangeRecord(record[0..used], &scratch);
}

fn commit(slot: u16) !void {
    if (!primary.readOnly(slot)) {
        const payload = try primary.prepareCommit(slot, &record);
        try replica.applyChangeRecord(payload, &scratch);
    }
    primary.publishCommit(slot);
}

const tables_probe = "SELECT table_schema, table_name, table_type, is_insertable_into FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema') ORDER BY table_schema, table_name";
const columns_probe = "SELECT table_name, column_name, ordinal_position, is_nullable, data_type, column_default FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position";

/// Views every replica must answer like its primary.
const replay_probes = [_][]const u8{
    tables_probe,
    columns_probe,
    "SELECT table_name, check_option, is_updatable, is_insertable_into FROM information_schema.views WHERE table_schema = 'public' ORDER BY table_name",
    "SELECT constraint_name, table_name, constraint_type, is_deferrable, initially_deferred, enforced, nulls_distinct FROM information_schema.table_constraints WHERE table_schema = 'public' ORDER BY table_name, constraint_name",
    "SELECT constraint_name, check_clause FROM information_schema.check_constraints WHERE constraint_schema = 'public' ORDER BY constraint_name",
    "SELECT constraint_name, table_name, column_name, ordinal_position, position_in_unique_constraint FROM information_schema.key_column_usage WHERE table_schema = 'public' ORDER BY constraint_name, ordinal_position",
    "SELECT constraint_name, unique_constraint_name, match_option, update_rule, delete_rule FROM information_schema.referential_constraints ORDER BY constraint_name",
    "SELECT grantor, grantee, table_name, privilege_type, is_grantable FROM information_schema.table_privileges WHERE table_schema = 'public' ORDER BY table_name, grantee, privilege_type",
    "SELECT routine_name, routine_type, data_type, external_language, security_type FROM information_schema.routines WHERE routine_schema = 'public' ORDER BY routine_name",
    "SELECT specific_name, ordinal_position, parameter_mode, parameter_name, data_type, parameter_default FROM information_schema.parameters WHERE specific_schema = 'public' ORDER BY specific_name, ordinal_position",
    "SELECT sequence_name, data_type, start_value, minimum_value, maximum_value, increment, cycle_option FROM information_schema.sequences ORDER BY sequence_name",
    "SELECT domain_name, data_type, numeric_precision FROM information_schema.domains WHERE domain_schema = 'public' ORDER BY domain_name",
    "SELECT trigger_name, event_manipulation, event_object_table, action_order, action_statement, action_orientation, action_timing FROM information_schema.triggers ORDER BY trigger_name, event_manipulation",
    "SELECT view_name, table_name, column_name FROM information_schema.view_column_usage WHERE view_schema = 'public' ORDER BY view_name, table_name, column_name",
    "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name",
    "SELECT role_name FROM information_schema.enabled_roles ORDER BY role_name",
    "SELECT grantee, role_name, is_grantable FROM information_schema.applicable_roles ORDER BY grantee, role_name",
};

var primary_text: [65536]u8 = undefined;

fn sameState() !void {
    for (replay_probes) |probe| {
        const left = try rowsOf(&primary, probe);
        @memcpy(primary_text[0..left.len], left);
        const right = try rowsOf(&replica, probe);
        if (!same(primary_text[0..left.len], right)) std.debug.print("{s}\n  primary {s}\n  replica {s}\n", .{ probe, primary_text[0..left.len], right });
        try check(same(primary_text[0..left.len], right));
    }
}

fn snapshotsAndReplay() !void {
    try durable("CREATE ROLE w5c_member");
    try durable("CREATE ROLE w5c_group");
    try durable("GRANT w5c_group TO w5c_member WITH ADMIN OPTION");
    try durable("CREATE SCHEMA s1");
    try durable("CREATE TABLE p (id INT PRIMARY KEY, u INT UNIQUE, c INT CONSTRAINT c_pos CHECK (c > 0), n TEXT NOT NULL DEFAULT 'x')");
    try durable("CREATE TABLE f (x INT CONSTRAINT f_fk REFERENCES p ON DELETE CASCADE, y INT REFERENCES p (u))");
    try durable("CREATE TABLE s1.t (id INT GENERATED ALWAYS AS IDENTITY, v VARCHAR(5))");
    try durable("CREATE VIEW v AS SELECT id, u FROM p WHERE c > 0");
    try durable("CREATE VIEW v2 AS SELECT id + 1 AS x FROM p");
    try durable("CREATE SEQUENCE sq START 7 INCREMENT 3");
    try durable("CREATE DOMAIN dpos AS INT CHECK (VALUE > 0)");
    try durable("CREATE FUNCTION fx(a INT, b TEXT DEFAULT 'q') RETURNS INT LANGUAGE SQL AS 'SELECT a'");
    try durable("CREATE PROCEDURE px(INOUT z INT) LANGUAGE SQL AS 'SELECT 1'");
    try durable("CREATE FUNCTION tf() RETURNS TRIGGER LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$");
    try durable("CREATE TRIGGER tr BEFORE INSERT OR UPDATE OF c ON p FOR EACH ROW EXECUTE FUNCTION tf()");
    try durable("GRANT SELECT, UPDATE ON p TO w5c_member WITH GRANT OPTION");
    try durable("GRANT INSERT ON f TO PUBLIC");
    try sameState();
    try expectOn(&replica, "SELECT constraint_name, constraint_type FROM information_schema.table_constraints WHERE table_name = 'p' ORDER BY constraint_name",
        "c_pos|CHECK;p_id_not_null|CHECK;p_n_not_null|CHECK;p_pkey|PRIMARY KEY;p_u_key|UNIQUE");
    try expectOn(&replica, "SELECT view_name, table_name, column_name FROM information_schema.view_column_usage WHERE view_schema = 'public' ORDER BY 1, 2, 3", "v|p|c;v|p|id;v|p|u;v2|p|id");
    // A transaction sees its own uncommitted DDL; another snapshot does not.
    const writer = try primary.begin();
    try statementIn(writer, "CREATE TABLE pending (k INT PRIMARY KEY)");
    try statementIn(writer, "CREATE VIEW pending_v AS SELECT k FROM pending");
    try check(same(try rowsIn(writer, "SELECT table_name, table_type FROM information_schema.tables WHERE table_name LIKE 'pending%' ORDER BY 1"), "pending|BASE TABLE;pending_v|VIEW"));
    try check(same(try rowsIn(writer, "SELECT constraint_name FROM information_schema.table_constraints WHERE table_name = 'pending' ORDER BY 1"), "pending_k_not_null;pending_pkey"));
    try expectOn(&primary, "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'pending%'", "0");
    try expectOn(&primary, "SELECT count(*) FROM information_schema.columns WHERE table_name LIKE 'pending%'", "0");
    try commit(writer);
    try expectOn(&primary, "SELECT table_name, column_name FROM information_schema.columns WHERE table_name LIKE 'pending%' ORDER BY 1", "pending|k;pending_v|k");
    try expectOn(&replica, "SELECT table_name, column_name FROM information_schema.columns WHERE table_name LIKE 'pending%' ORDER BY 1", "pending|k;pending_v|k");
    // An aborted transaction leaves no trace in any view.
    const aborted = try primary.begin();
    try statementIn(aborted, "CREATE TABLE gone (g INT REFERENCES pending)");
    try statementIn(aborted, "CREATE FUNCTION gone_f() RETURNS INT LANGUAGE SQL AS 'SELECT 1'");
    try check(same(try rowsIn(aborted, "SELECT count(*) FROM information_schema.referential_constraints"), "3"));
    primary.abort(aborted);
    try expectOn(&primary, "SELECT count(*) FROM information_schema.tables WHERE table_name = 'gone'", "0");
    try expectOn(&primary, "SELECT count(*) FROM information_schema.referential_constraints", "2");
    try expectOn(&primary, "SELECT count(*) FROM information_schema.routines WHERE routine_name = 'gone_f'", "0");
    // A failing statement (duplicate column) is atomic too.
    const result = &statement_result;
    var used: usize = 0;
    if (primary.executeChanges("CREATE TABLE dup (a INT, a TEXT)", result, &record, &used, null, null)) |_| return error.InvalidStatementAccepted else |err| try check(err == error.DuplicateColumn);
    try check(used == 0);
    try expectOn(&primary, "SELECT count(*) FROM information_schema.columns WHERE table_name = 'dup'", "0");
    // DROP removes every row the object contributed.
    try durable("DROP TABLE f");
    try durable("DROP VIEW pending_v");
    try durable("DROP FUNCTION fx(INT, TEXT)");
    try sameState();
    try expectOn(&replica, "SELECT count(*) FROM information_schema.referential_constraints", "0");
    try expectOn(&replica, "SELECT count(*) FROM information_schema.parameters WHERE specific_schema = 'public'", "1");
    // Privilege filtering follows the role (SET ROLE), on both sides.
    try primary.execute("SET ROLE w5c_member", result);
    try expectOn(&primary, tables_probe, "public|p|BASE TABLE|YES");
    try expectOn(&primary, "SELECT grantor, grantee, table_name, privilege_type, is_grantable FROM information_schema.table_privileges WHERE table_schema = 'public' ORDER BY privilege_type",
        "ramsql|w5c_member|p|SELECT|YES;ramsql|w5c_member|p|UPDATE|YES");
    try expectOn(&primary, "SELECT role_name FROM information_schema.enabled_roles ORDER BY 1", "w5c_group;w5c_member");
    try expectOn(&primary, "SELECT constraint_name FROM information_schema.check_constraints WHERE constraint_schema = 'public'", "");
    try primary.execute("RESET ROLE", result);
    try sameState();
}

var small: Small = .{};
var small_result: Small.Result = .{};

/// The 64-cell workspace of `Small` cannot hold unfiltered
/// information_schema.columns: 54000, cleanly, and nothing changes.
fn capacity() !void {
    try small.execute("CREATE TABLE k (a INT, b TEXT)", &small_result);
    if (small.execute("SELECT table_name, column_name FROM information_schema.columns ORDER BY 1, 2", &small_result)) |_| return error.WideViewAccepted else |err| {
        // WorkspaceCapacity is SQLSTATE 54000 (program_limit_exceeded).
        try check(err == error.WorkspaceCapacity);
    }
    try small.execute("SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'k' ORDER BY ordinal_position", &small_result);
    try check(small_result.row_count == 2 and std.mem.eql(u8, small_result.rows[1].cells[1].text.slice(), "text"));
    try check(small.usage().transactions == 0 and small.usage().pending_versions == 0);
    // A view wider than the projection is 54000 too (ColumnCapacity).
    if (small.execute("SELECT * FROM information_schema.columns", &small_result)) |_| return error.WideViewAccepted else |err| try check(err == error.ColumnCapacity);
}

pub fn main(init: std.process.Init) !void {
    const statements = try recordedScripts();
    try snapshotsAndReplay();
    try capacity();
    var summary: [160]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&summary,
        "{{\"suite\":\"sql-catalog-views\",\"pass\":true,\"scripts\":{d},\"statements\":{d},\"assertions\":{d}}}\n",
        .{ cases.scripts.len, statements, assertions }));
}
