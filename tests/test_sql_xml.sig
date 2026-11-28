//! SQL/XML contract (conformance lane B11 wave 5 "xml"): the pure-Sig XML
//! tree and XPath 1.0 engine behind xpath(), xpath_exists() and XMLEXISTS,
//! XMLTABLE, IS DOCUMENT, XMLSERIALIZE ... INDENT, XMLAGG, the SQL/XML
//! table mappings (table_to_xml, query_to_xml, cursor_to_xml,
//! schema_to_xml, database_to_xml and their XML Schema forms), xmlbinary,
//! name mapping and XML parameters of routines.
//!
//! Every generated expectation is native PostgreSQL 18.7 output for the
//! same statements (gen_contract.py in the lane's scratch work, never
//! edited by hand): rows, result type OIDs, typmods and names, and the
//! SQLSTATE of each rejected statement with statement atomicity. The
//! hand-written sections check the Config capacities (54000), the work
//! budget and cancellation points of XML evaluation, and change-record
//! replay of XML results into a replica.
const std = @import("std");
const sql = @import("sql");

const DB = sql.Database(.{ .tables = 8, .columns = 16, .rows_per_table = 16, .name_bytes = 63, .text_bytes = 1024, .integer_bits = 32, .nulls_first_ascending = false, .expr_nodes = 2048, .work_rows = 256, .result_rows = 32, .transactions = 4, .routines = 8, .cursors = 4, .cursor_rows = 32 });
const Io = DB.Io;
var assertions: usize = 0;
var db: DB = .{};
var result: DB.Result = .{};
var scratch: DB.ReplayScratch = .{};

fn check(ok: bool) !void {
    assertions += 1;
    if (!ok) {
        std.debug.print("xml contract failed at assertion {d}\n", .{assertions});
        return error.SqlXmlContractFailed;
    }
}

fn exec(source: []const u8) !void {
    db.execute(source, &result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// A fresh database named like the oracle's (w5_xml); results keep wide
/// values (XML Schema documents, large mappings) in their own memory.
var result_values: [262144]u8 = undefined;

fn fresh() !void {
    db = .{};
    db.session.database = "w5_xml";
    result.bindValueMemory(&result_values);
}

var shown_buffer: [65536]u8 = undefined;

/// The rows of `target`, columns joined by '|' and rows by ';' (NULL as NULL).
fn render(target: *const DB.Result) ![]const u8 {
    var at: usize = 0;
    for (0..target.row_count) |index| {
        if (index != 0) {
            shown_buffer[at] = ';';
            at += 1;
        }
        for (0..target.column_count) |column| {
            if (column != 0) {
                shown_buffer[at] = '|';
                at += 1;
            }
            const cell = &target.rows[index].cells[column];
            var buffer: [Io.format_bytes]u8 = undefined;
            const text = if (cell.* == .null_value) "NULL" else try Io.format(cell, false, &db.session, &buffer);
            @memcpy(shown_buffer[at..][0..text.len], text);
            at += text.len;
        }
    }
    return shown_buffer[0..at];
}

/// Every row of a query, columns joined by '|' and rows by ';' (NULL as NULL).
fn rows(source: []const u8, expected: []const u8) !void {
    try exec(source);
    try shown(source, expected);
}

fn shown(source: []const u8, expected: []const u8) !void {
    const got = try render(&result);
    if (!std.mem.eql(u8, got, expected)) std.debug.print("{s}\n  got:      {s}\n  expected: {s}\n", .{ source, got, expected });
    try check(std.mem.eql(u8, got, expected));
}

/// Result column `index` has this PostgreSQL type OID and typmod.
fn meta(index: usize, oid: u32, typmod: i32) !void {
    const got_oid = sql.typeOid(result.column_types[index]);
    if (got_oid != oid or result.column_typmods[index] != typmod)
        std.debug.print("column {d}: got oid {d} typmod {d}, expected {d} {d}\n", .{ index, got_oid, result.column_typmods[index], oid, typmod });
    try check(got_oid == oid and result.column_typmods[index] == typmod);
}

/// Result column `index` is named `name`.
fn named(index: usize, name: []const u8) !void {
    const got = result.column_names[index].slice();
    if (!std.mem.eql(u8, got, name)) std.debug.print("column {d}: named {s}, expected {s}\n", .{ index, got, name });
    try check(std.mem.eql(u8, got, name));
}

fn rejected(source: []const u8, wanted: anyerror) !void {
    if (db.execute(source, &result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn rejects(source: []const u8, wanted: anyerror) !void {
    try rejected(source, wanted);
    // Statement atomicity: nothing pending after a failed statement.
    try check(db.usage().pending_versions == 0 and db.usage().transactions == 0);
}

/// Inside an explicit transaction block (the block stays open).
fn rejectsInBlock(source: []const u8, wanted: anyerror) !void {
    try rejected(source, wanted);
    try check(db.usage().pending_versions == 0);
}

// An explicit transaction block of one session (cursors live in it).
var session_state: DB.SessionState = .{};

fn begin() !u16 {
    session_state = .{};
    db.session_state = &session_state;
    return db.begin();
}

fn execIn(slot: u16, source: []const u8) !void {
    db.statement(slot, source, &result, .{}) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

fn rowsIn(slot: u16, source: []const u8, expected: []const u8) !void {
    try execIn(slot, source);
    try shown(source, expected);
}

fn rejectsIn(slot: u16, source: []const u8, wanted: anyerror) !void {
    if (db.statement(slot, source, &result, .{})) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
}

fn rollback(slot: u16) void {
    db.abort(slot);
    db.endSession();
}

/// SQLSTATEs of the errors this contract expects, as src/db/postgres.sig
/// maps them (each pinned to the code PostgreSQL reported).
fn sqlstate(err: anyerror, wanted: []const u8) !void {
    const table = [_]struct { name: []const u8, state: []const u8 }{
        .{ .name = "InvalidArgumentForXquery", .state = "10608" },  .{ .name = "InvalidXmlDocument", .state = "2200M" },
        .{ .name = "InvalidXmlContent", .state = "2200N" },        .{ .name = "NotAnXmlDocument", .state = "2200L" },
        .{ .name = "NullValueNotAllowed", .state = "22004" },      .{ .name = "DataException", .state = "22000" },
        .{ .name = "CardinalityViolation", .state = "21000" },     .{ .name = "StringDataRightTruncation", .state = "22001" },
        .{ .name = "Syntax", .state = "42601" },                   .{ .name = "UnsupportedStatement", .state = "0A000" },
        .{ .name = "TypeMismatch", .state = "42804" },             .{ .name = "UndefinedFunction", .state = "42883" },
        .{ .name = "UndefinedSchema", .state = "3F000" },          .{ .name = "TableNotFound", .state = "42P01" },
        .{ .name = "PortalNotFound", .state = "34000" },           .{ .name = "InternalError", .state = "XX000" },
        .{ .name = "InvalidTextRepresentation", .state = "22P02" }, .{ .name = "DivisionByZero", .state = "22012" },
        .{ .name = "ProgramLimitExceeded", .state = "54000" },     .{ .name = "QueryWorkLimit", .state = "54000" },
        .{ .name = "QueryCanceled", .state = "57014" },            .{ .name = "TextCapacity", .state = "54000" },
    };
    var state: []const u8 = "?";
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, @errorName(err))) state = entry.state;
    }
    if (!std.mem.eql(u8, state, wanted)) std.debug.print("{s}: SQLSTATE {s}, expected {s}\n", .{ @errorName(err), state, wanted });
    try check(std.mem.eql(u8, state, wanted));
}

// ---- work control ------------------------------------------------------------

const Cancel = struct {
    remaining: usize,

    fn poll(raw: ?*anyopaque) sql.Error!void {
        const self: *Cancel = @ptrCast(@alignCast(raw.?));
        if (self.remaining == 0) return error.QueryCanceled;
        self.remaining -= 1;
    }
};

/// Every work budget below the statement's need fails with exactly
/// QueryWorkLimit (54000) at that budget, every cancellation point with
/// QueryCanceled (57014), and an unbudgeted rerun returns `wanted` again.
fn controlled(source: []const u8, wanted: []const u8) !void {
    try rows(source, wanted);
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try exec(source);
    const used = control.used;
    try check(used > 0);
    var limit: u64 = 1;
    while (limit < used) : (limit += @max(1, used / 97)) {
        control.reset(limit);
        try rejects(source, error.QueryWorkLimit);
        try check(control.used == limit);
    }
    var cancel: Cancel = .{ .remaining = 0 };
    control.context = &cancel;
    control.poll = Cancel.poll;
    control.poll_interval = 1;
    var point: usize = 0;
    while (point < used) : (point += @max(1, used / 61)) {
        cancel.remaining = point;
        control.reset(0);
        try rejects(source, error.QueryCanceled);
    }
    db.session.control = null;
    try rows(source, wanted);
}

// ---- replay ------------------------------------------------------------------

fn sameResult(a: *const DB.Result, b: *const DB.Result, a_db: *DB, b_db: *DB) !bool {
    if (a.column_count != b.column_count or a.row_count != b.row_count) return false;
    for (0..a.column_count) |column| {
        if (a.column_types[column] != b.column_types[column] or a.column_typmods[column] != b.column_typmods[column] or
            !std.mem.eql(u8, a.column_names[column].slice(), b.column_names[column].slice())) return false;
    }
    for (0..a.row_count) |index| for (0..a.column_count) |column| {
        const x = &a.rows[index].cells[column];
        const y = &b.rows[index].cells[column];
        if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*) or DB.compareCells(x, y) != 0) return false;
        if (x.* == .null_value) continue;
        var p: [Io.format_bytes]u8 = undefined;
        var q: [Io.format_bytes]u8 = undefined;
        if (!std.mem.eql(u8, try Io.format(x, false, &a_db.session, &p), try Io.format(y, false, &b_db.session, &q))) return false;
    };
    return true;
}

fn sameQuery(a: *DB, b: *DB, source: []const u8) !bool {
    var x: DB.Result = .{};
    var y: DB.Result = .{};
    try a.execute(source, &x);
    try b.execute(source, &y);
    return sameResult(&x, &y, a, b);
}

/// Table count, OID counter, live rows, next rowids and every row of `tables`.
fn sameDatabase(a: *DB, b: *DB, tables: []const []const u8) !bool {
    if (a.tableCount() != b.tableCount() or a.oid_counter != b.oid_counter) return false;
    for (tables) |name| {
        const left = a.storageStats(name);
        const right = b.storageStats(name);
        if ((left == null) != (right == null)) return false;
        if (left == null) continue;
        if (left.?.live_rows != right.?.live_rows or left.?.next_rowid != right.?.next_rowid) return false;
        var query: [64]u8 = undefined;
        if (!try sameQuery(a, b, try std.fmt.bufPrint(&query, "SELECT * FROM {s}", .{name}))) return false;
    }
    return true;
}

var replay_primary: DB = .{};
var replay_replica: DB = .{};
var replay_expected: DB.Result = .{};

/// Replays `statements` from a fresh primary into a replica through change
/// records; both must hold the same tables and answer `query` identically.
fn replay(statements: []const []const u8, tables: []const []const u8, query: []const u8) !void {
    replay_primary = .{};
    replay_replica = .{};
    replay_primary.session.database = "w5_xml";
    replay_replica.session.database = "w5_xml";
    var r: DB.Result = .{};
    var record: [16384]u8 = undefined;
    for (statements) |source| {
        var used: usize = 0;
        replay_primary.executeChanges(source, &r, &record, &used, null, null) catch |err| {
            std.debug.print("replay source failed: {s}: {s}\n", .{ source, @errorName(err) });
            return err;
        };
        try replay_replica.applyChangeRecord(record[0..used], &scratch);
    }
    try check(try sameDatabase(&replay_primary, &replay_replica, tables));
    try replay_primary.execute(query, &replay_expected);
    try replay_replica.execute(query, &result);
    try check(try sameResult(&replay_expected, &result, &replay_primary, &replay_replica));
}

// ---- generated from native PostgreSQL 18.7 --------------------------------------

/// xpath(), xpath_exists() and XMLEXISTS: node sets, scalars, namespace arrays and their errors.
fn xpathFunctions() !void {
    try fresh();
    try rows("SELECT xpath('/a/b/text()', '<a><b>x</b><b>y</b></a>'), pg_typeof(xpath('/a', '<a/>'))", "{x,y}|xml[]");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 2206, -1);
    try named(1, "pg_typeof");
    try rows("SELECT xpath('//b', '<a xmlns=\"urn:x\"><b y=\"1\" xmlns:p=\"urn:p\" p:z=\"2\">t</b></a>')", "{}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try rows("SELECT xpath('//b', '<x:a xmlns:x=\"urn:x\" xmlns:y=\"urn:y\"><b y:k=\"1\"><x:c/></b></x:a>')", "{\"<b xmlns:y=\\\"urn:y\\\" xmlns:x=\\\"urn:x\\\" y:k=\\\"1\\\"><x:c/></b>\"}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try rows("SELECT xpath('//p:b', '<a xmlns:p=\"urn:p\"><p:b q=\"&#233;\"/></a>', ARRAY[ARRAY['p', 'urn:p']])", "{\"<p:b xmlns:p=\\\"urn:p\\\" q=\\\"&#xE9;\\\"/>\"}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try rows("SELECT xpath('//p:b', '<a xmlns:p=\"urn:p\"><p:b/></a>', ARRAY[ARRAY['p', 'urn:x'], ARRAY['p', 'urn:p']])", "{\"<p:b xmlns:p=\\\"urn:p\\\"/>\"}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try rows("SELECT xpath('1 div 3', '<a/>'), xpath('count(//*)', '<a><b/></a>'), xpath('true()', '<a/>'), xpath('\"a<b\"', '<a/>'), xpath('0 div 0', '<a/>')", "{0.3333333333333333}|{2}|{true}|{a&lt;b}|{NaN}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try meta(3, 143, -1);
    try named(3, "xpath");
    try meta(4, 143, -1);
    try named(4, "xpath");
    try rows("SELECT xpath('string(1 div 3)', '<a/>'), xpath('string(1e10)', '<a/>'), xpath('string(0.1+0.2)', '<a/>'), xpath('string(123456789012)', '<a/>'), xpath('string(0.000001)', '<a/>')", "{0.333333333333333}|{1e+10}|{0.3}|{1.23456789012e+11}|{1e-06}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try meta(3, 143, -1);
    try named(3, "xpath");
    try meta(4, 143, -1);
    try named(4, "xpath");
    try rows("SELECT xpath('//text()', '<a>x&lt;y<![CDATA[z<w]]></a>'), xpath('//comment()|//processing-instruction()', '<a><!--c--><?p d?></a>')", "{x&lt;y,<![CDATA[z<w]]>}|{<!--c-->,\"<?p d?>\"}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try rows("SELECT xpath('//@*', '<a x=\"1&amp;\" y=\"&lt;\"/>'), xpath('/a/namespace::*', '<a xmlns:p=\"urn:p\"/>')", "{1&amp;,&lt;}|{http://www.w3.org/XML/1998/namespace,urn:p}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try rows("SELECT xpath('/', '<?xml version=\"1.0\" standalone=\"yes\"?><!--c--><!DOCTYPE a SYSTEM \"a.dtd\"><a/>')", "{\"<!--c-->\n<!DOCTYPE a SYSTEM \\\"a.dtd\\\">\n<a/>\n\"}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try rows("SELECT (xpath('/', '<a/>'))[1]::text, (xpath('/a/b/text()', '<a><b>7</b></a>'))[1]::text::int", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a/>\n|7");
    try meta(0, 25, -1);
    try named(0, "xpath");
    try meta(1, 23, -1);
    try named(1, "xpath");
    try rows("SELECT xpath('//c[@id=\"c2\"]/d', '<r><c id=\"c1\"><d>1</d></c><c id=\"c2\"><d>2</d><d>3</d></c></r>'), xpath('//d[last()]', '<r><c><d>1</d><d>2</d></c></r>')", "{<d>2</d>,<d>3</d>}|{<d>2</d>}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try rows("SELECT xpath('//d/ancestor::*[1]', '<r><c><d/></c></r>'), xpath('/r/c[1]/following-sibling::*', '<r><c/><e/><f/></r>'), xpath('//e/preceding::*', '<r><c><d/></c><e/></r>')", "{<c><d/></c>}|{<e/>,<f/>}|{<c><d/></c>,<d/>}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try rows("SELECT xpath('substring(\"12345\", 1.5, 2.6)', '<a/>'), xpath('translate(\"hello\", \"lo\", \"01x\")', '<a/>'), xpath('normalize-space(\"  a  b \")', '<a/>'), xpath('round(-2.5)', '<a/>')", "{234}|{he001}|{\"a b\"}|{-2}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try meta(3, 143, -1);
    try named(3, "xpath");
    try rows("SELECT xpath('id(\"c2\")', '<r><c xml:id=\"c1\"/><c xml:id=\"c2\"/></r>'), xpath('//c[lang(\"en\")]', '<r xml:lang=\"en-US\"><c/></r>')", "{\"<c xml:id=\\\"c2\\\"/>\"}|{<c/>}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try rows("SELECT xpath('/a', NULL::xml), xpath(NULL, '<a/>'), xpath('/a', '<a/>', NULL), xpath('/a', '<a/>', '{}')", "NULL|NULL|NULL|{<a/>}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try meta(3, 143, -1);
    try named(3, "xpath");
    try rows("SELECT xpath_exists('/a', '<a/>'), xpath_exists('/b', '<a/>'), xpath_exists('false()', '<a/>'), xpath_exists('//p:b', '<a xmlns:p=\"urn:p\"><p:b/></a>', ARRAY[ARRAY['p', 'urn:p']])", "t|f|t|t");
    try meta(0, 16, -1);
    try named(0, "xpath_exists");
    try meta(1, 16, -1);
    try named(1, "xpath_exists");
    try meta(2, 16, -1);
    try named(2, "xpath_exists");
    try meta(3, 16, -1);
    try named(3, "xpath_exists");
    try rows("SELECT XMLEXISTS('//b' PASSING '<a><b/></a>'), XMLEXISTS('//c' PASSING BY REF '<a><b/></a>' BY VALUE), XMLEXISTS('1' PASSING BY VALUE '<a/>'), XMLEXISTS(NULL PASSING '<a/>')", "t|f|t|NULL");
    try meta(0, 16, -1);
    try named(0, "xmlexists");
    try meta(1, 16, -1);
    try named(1, "xmlexists");
    try meta(2, 16, -1);
    try named(2, "xmlexists");
    try meta(3, 16, -1);
    try named(3, "xmlexists");
    try rejects("SELECT xpath('', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('/a[', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('foo()', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('$v', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('count(1)', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('x:a', '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT xpath('/a', 'x<a/>')", error.InvalidXmlDocument);
    try rejects("SELECT xpath('/a', '<a><q:b/></a>')", error.InvalidXmlDocument);
    try rejects("SELECT xpath('/a', '<a xmlns:q=\"u v\"/>')", error.InvalidXmlDocument);
    try rejects("SELECT xpath('//p:b', '<a/>', ARRAY['p', 'urn:p'])", error.DataException);
    try rejects("SELECT xpath('//p:b', '<a/>', ARRAY[ARRAY['p', NULL]])", error.NullValueNotAllowed);
    try rejects("SELECT xpath('//p:b', '<a/>', ARRAY[ARRAY['', 'urn:p']])", error.InternalError);
    try rejects("SELECT xpath('/a', '<a/>'::text)", error.UndefinedFunction);
    try rejects("SELECT XMLEXISTS('' PASSING '<a/>')", error.InvalidArgumentForXquery);
    try rejects("SELECT XMLEXISTS('/a' PASSING '<a/>'::xml)", error.Syntax);
    try exec("CREATE TABLE d(id int, x xml)");
    try exec("INSERT INTO d VALUES (1, '<r><v>10</v><v>20</v></r>'), (2, '<r><v>5</v></r>'), (3, NULL)");
    try rows("SELECT id, xpath('sum(/r/v)', x), (xpath('/r/v/text()', x))[2]::text FROM d ORDER BY id", "1|{30}|20;2|{5}|NULL;3|NULL|NULL");
    try meta(0, 23, -1);
    try named(0, "id");
    try meta(1, 143, -1);
    try named(1, "xpath");
    try meta(2, 25, -1);
    try named(2, "xpath");
    try rows("SELECT id FROM d WHERE xpath_exists('/r/v[. > 7]', x) ORDER BY id", "1");
    try meta(0, 23, -1);
    try named(0, "id");
    try rows("SELECT id FROM d WHERE XMLEXISTS('/r/v[. = 5]' PASSING BY REF x) ORDER BY id", "2");
    try meta(0, 23, -1);
    try named(0, "id");
    try rejects("SELECT id, unnest(xpath('/r/v/text()', x)) FROM d ORDER BY 1, 2", error.UndefinedFunction);
}

/// XMLTABLE in FROM: columns, PATH, DEFAULT, NOT NULL, FOR ORDINALITY, XMLNAMESPACES, PASSING mechanisms, lateral use and errors.
fn xmlTable() !void {
    try fresh();
    try rows("SELECT * FROM XMLTABLE('/rows/row' PASSING '<rows><row a=\"1\"><b>x</b></row><row a=\"2\"><b>y</b></row></rows>' COLUMNS a INT PATH '@a', b TEXT PATH 'b')", "1|x;2|y");
    try meta(0, 23, -1);
    try named(0, "a");
    try meta(1, 25, -1);
    try named(1, "b");
    try rows("SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i>p</i><i>q</i></r>' COLUMNS n FOR ORDINALITY, v TEXT PATH '.')", "1|p;2|q");
    try meta(0, 23, -1);
    try named(0, "n");
    try meta(1, 25, -1);
    try named(1, "v");
    try rows("SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i v=\"1\"/><i/></r>' COLUMNS v INT PATH '@v' DEFAULT 0)", "1;0");
    try meta(0, 23, -1);
    try named(0, "v");
    try rows("SELECT * FROM XMLTABLE('i' PASSING '<i>9</i>' COLUMNS v INT PATH '.')", "9");
    try meta(0, 23, -1);
    try named(0, "v");
    try rows("SELECT * FROM XMLTABLE('/r/i' PASSING BY VALUE '<r><i>1</i><i>2</i></r>' BY REF COLUMNS v INT PATH '.')", "1;2");
    try meta(0, 23, -1);
    try named(0, "v");
    try rows("SELECT * FROM XMLTABLE('/r' PASSING '<r><a>1</a><a>2</a></r>' COLUMNS a xml, b text PATH 'string(a)', c bool PATH 'a=1', d int PATH 'a=1', e float8 PATH 'count(a) div 3', f xml PATH '\"<x>\"')", "<a>1</a><a>2</a>|1|t|1|0.666666666666667|&lt;x&gt;");
    try meta(0, 142, -1);
    try named(0, "a");
    try meta(1, 25, -1);
    try named(1, "b");
    try meta(2, 16, -1);
    try named(2, "c");
    try meta(3, 23, -1);
    try named(3, "d");
    try meta(4, 701, -1);
    try named(4, "e");
    try meta(5, 142, -1);
    try named(5, "f");
    try rows("SELECT * FROM XMLTABLE('/r/a' PASSING '<r><a x=\"1\"><b>t</b></a><a/></r>' COLUMNS x int, b text, \"B\" text PATH 'b', c text PATH 'c' DEFAULT 'none', d text PATH 'b' NOT NULL DEFAULT 'zz')", "NULL|t|t|none|t;NULL|NULL|NULL|none|zz");
    try meta(0, 23, -1);
    try named(0, "x");
    try meta(1, 25, -1);
    try named(1, "b");
    try meta(2, 25, -1);
    try named(2, "B");
    try meta(3, 25, -1);
    try named(3, "c");
    try meta(4, 25, -1);
    try named(4, "d");
    try rows("SELECT * FROM XMLTABLE(XMLNAMESPACES('urn:p' AS p, 'urn:q' AS \"Q\"), '/p:r/Q:a' PASSING '<r xmlns=\"urn:p\"><a xmlns=\"urn:q\">1</a><a xmlns=\"urn:q\">2</a></r>' COLUMNS v int PATH '.')", "1;2");
    try meta(0, 23, -1);
    try named(0, "v");
    try rows("SELECT * FROM XMLTABLE('//*' PASSING '<r><a/><b><c/></b></r>' COLUMNS n text PATH 'name()', d int PATH 'count(ancestor::*)') ORDER BY 1", "a|1;b|1;c|2;r|0");
    try meta(0, 25, -1);
    try named(0, "n");
    try meta(1, 23, -1);
    try named(1, "d");
    try rows("SELECT * FROM XMLTABLE('/r/@*' PASSING '<r a=\"1\" b=\"2\"/>' COLUMNS n text PATH 'name()', v text PATH '.')", "a|1;b|2");
    try meta(0, 25, -1);
    try named(0, "n");
    try meta(1, 25, -1);
    try named(1, "v");
    try rows("SELECT t.* FROM XMLTABLE('/r/a' PASSING '<r><a>1</a></r>' COLUMNS v int PATH '.', o FOR ORDINALITY) AS t(w, z)", "1|1");
    try meta(0, 23, -1);
    try named(0, "w");
    try meta(1, 23, -1);
    try named(1, "z");
    try rows("SELECT sum(v), count(*) FROM XMLTABLE('/r/a' PASSING '<r><a>1</a><a>2</a></r>' COLUMNS v int PATH '.')", "3|2");
    try meta(0, 20, -1);
    try named(0, "sum");
    try meta(1, 20, -1);
    try named(1, "count");
    try rows("SELECT * FROM XMLTABLE('count(/r)' PASSING '<r/>' COLUMNS a int PATH '.')", "");
    try meta(0, 23, -1);
    try named(0, "a");
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING NULL::xml COLUMNS a int PATH '.')", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>'::xml COLUMNS a int PATH '1')", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int PATH '1' PATH '2')", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int NULL NOT NULL)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int DEFAULT 1 DEFAULT 2)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int FOO 1)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a FOR ORDINALITY, b FOR ORDINALITY)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int, a text)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE(XMLNAMESPACES('urn:x' AS x, DEFAULT 'urn:d'), '/r' PASSING '<r/>' COLUMNS a int)", error.UnsupportedStatement);
    try rejects("SELECT * FROM XMLTABLE(XMLNAMESPACES('urn:x' AS x, 'urn:y' AS x), '/r' PASSING '<r/>' COLUMNS a int)", error.Syntax);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING 'x<r/>' COLUMNS a int)", error.InvalidXmlDocument);
    try rejects("SELECT * FROM XMLTABLE('' PASSING '<r/>' COLUMNS a int)", error.InvalidArgumentForXquery);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int PATH '')", error.InvalidArgumentForXquery);
    try rejects("SELECT * FROM XMLTABLE(NULL PASSING '<r/>' COLUMNS a int)", error.NullValueNotAllowed);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int PATH NULL)", error.NullValueNotAllowed);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r/>' COLUMNS a int PATH 'x' NOT NULL)", error.NullValueNotAllowed);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r><a>1</a><a>2</a></r>' COLUMNS a int)", error.CardinalityViolation);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING '<r><a>abc</a></r>' COLUMNS a varchar(2))", error.StringDataRightTruncation);
    try rejects("SELECT * FROM XMLTABLE('/r/a' PASSING '<r><a>x</a></r>' COLUMNS v int PATH '.')", error.InvalidTextRepresentation);
    try rejects("SELECT * FROM XMLTABLE('/r' PASSING 'text'::text COLUMNS a int)", error.Syntax);
    try exec("CREATE TABLE d(id int, x xml)");
    try exec("INSERT INTO d VALUES (1, '<r><v>10</v><v>20</v></r>'), (2, '<r><v>5</v></r>'), (3, NULL)");
    try rows("SELECT d.id, t.* FROM d, XMLTABLE('/r/v' PASSING d.x COLUMNS v int PATH '.', o FOR ORDINALITY) t ORDER BY 1, 3", "1|10|1;1|20|2;2|5|1");
    try meta(0, 23, -1);
    try named(0, "id");
    try meta(1, 23, -1);
    try named(1, "v");
    try meta(2, 23, -1);
    try named(2, "o");
    try rows("SELECT d.id, t.* FROM d LEFT JOIN LATERAL XMLTABLE('/r/v' PASSING d.x COLUMNS v int PATH '.') t ON true ORDER BY 1, 2", "1|10;1|20;2|5;3|NULL");
    try meta(0, 23, -1);
    try named(0, "id");
    try meta(1, 23, -1);
    try named(1, "v");
    try rows("SELECT * FROM XMLTABLE('/r/a' PASSING '<r><a/><a>1</a></r>' COLUMNS v xml PATH 'x' DEFAULT xpath('/z/text()', '<z>q</z>')::text::xml, w text PATH '.' DEFAULT (SELECT max(id)::text FROM d))", "{q}|;{q}|1");
    try meta(0, 142, -1);
    try named(0, "v");
    try meta(1, 25, -1);
    try named(1, "w");
}

/// IS [NOT] DOCUMENT, the xml_is_well_formed family, XMLSERIALIZE ... [NO] INDENT and XMLAGG.
fn documents() !void {
    try fresh();
    try rows("SELECT '<a/>'::xml IS DOCUMENT, 'x<a/>'::xml IS DOCUMENT, '<a/>'::xml IS NOT DOCUMENT, NULL::xml IS DOCUMENT, ''::xml IS DOCUMENT", "t|f|f|NULL|f");
    try meta(0, 16, -1);
    try named(0, "?column?");
    try meta(1, 16, -1);
    try named(1, "?column?");
    try meta(2, 16, -1);
    try named(2, "?column?");
    try meta(3, 16, -1);
    try named(3, "?column?");
    try meta(4, 16, -1);
    try named(4, "?column?");
    try rejects("SELECT 'x'::text IS DOCUMENT", error.TypeMismatch);
    try rows("SELECT xml_is_well_formed('<a/>'), xml_is_well_formed('x<a/>'), xml_is_well_formed('<a>'), xml_is_well_formed_document('x<a/>'), xml_is_well_formed_content('x<a/>')", "t|t|f|f|t");
    try meta(0, 16, -1);
    try named(0, "xml_is_well_formed");
    try meta(1, 16, -1);
    try named(1, "xml_is_well_formed");
    try meta(2, 16, -1);
    try named(2, "xml_is_well_formed");
    try meta(3, 16, -1);
    try named(3, "xml_is_well_formed_document");
    try meta(4, 16, -1);
    try named(4, "xml_is_well_formed_content");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a><b>1</b></a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<a><b/></a>' AS TEXT NO INDENT)", "<a>\n  <b>1</b>\n</a>|<a><b/></a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(CONTENT 'x<a><b/></a><c/>y' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<a/><b/>' AS TEXT INDENT)", "x\n<a>\n  <b/>\n</a>\n<c/>y|<a/>\n<b/>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a>  <b>1</b>  <c/>  </a>' AS TEXT INDENT), XMLSERIALIZE(DOCUMENT '<a>t<b>1</b></a>' AS TEXT INDENT)", "<a>\n  <b>1</b>\n  <c/>\n</a>|<a>t<b>1</b></a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a><b><c><d/></c></b><!--x--><?p q?></a>' AS TEXT INDENT)", "<a>\n  <b>\n    <c>\n      <d/>\n    </c>\n  </b>\n  <!--x-->\n  <?p q?>\n</a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<?xml version=\"1.0\" standalone=\"yes\"?><a><b/></a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<?xml version=\"1.0\"?><a><b/></a>' AS TEXT INDENT)", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<a>\n  <b/>\n</a>|<a>\n  <b/>\n</a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a b=\"&#233;\">&#233;</a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<a b=\"&#233;\">&#233;</a>' AS TEXT INDENT)", "<a b=\"é\">&#xE9;</a>|<a b=\"é\">&#xE9;</a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a xml:space=\"preserve\">  <b/>  </a>' AS TEXT INDENT), XMLSERIALIZE(DOCUMENT '<a>   </a>' AS TEXT INDENT)", "<a xml:space=\"preserve\">  <b/>  </a>|<a>   </a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<!DOCTYPE a SYSTEM \"a.dtd\"><a><b/></a>' AS TEXT INDENT), XMLSERIALIZE(CONTENT '<!DOCTYPE a><a><b/></a>' AS TEXT INDENT)", "<!DOCTYPE a SYSTEM \"a.dtd\">\n<a>\n  <b/>\n</a>|<!DOCTYPE a>\n<a>\n  <b/>\n</a>\n");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try meta(1, 25, -1);
    try named(1, "xmlserialize");
    try rows("SELECT XMLSERIALIZE(DOCUMENT '<a><b>1</b></a>' AS VARCHAR(30) INDENT), pg_typeof(XMLSERIALIZE(DOCUMENT '<a/>' AS VARCHAR(30) INDENT))", "<a>\n  <b>1</b>\n</a>|character varying");
    try meta(0, 1043, 34);
    try named(0, "xmlserialize");
    try meta(1, 2206, -1);
    try named(1, "pg_typeof");
    try rejects("SELECT XMLSERIALIZE(DOCUMENT '<a><b>1</b></a>' AS VARCHAR(10) INDENT)", error.StringDataRightTruncation);
    try rejects("SELECT XMLSERIALIZE(DOCUMENT 'x<a/>' AS TEXT INDENT)", error.NotAnXmlDocument);
    try rejects("SELECT XMLSERIALIZE(CONTENT '<a>123456789012</a>' AS VARCHAR(5))", error.StringDataRightTruncation);
    try exec("CREATE TABLE u(v TEXT)");
    try exec("INSERT INTO u VALUES ('a'), ('b')");
    try rows("SELECT XMLAGG(XMLELEMENT(NAME v, v)) FROM u", "<v>a</v><v>b</v>");
    try meta(0, 142, -1);
    try named(0, "xmlagg");
    try rows("SELECT XMLAGG(XMLELEMENT(NAME v, v)) FROM u WHERE false", "NULL");
    try meta(0, 142, -1);
    try named(0, "xmlagg");
}

/// table_to_xml, query_to_xml, cursor_to_xml and their XML Schema forms: nulls absent / xsi:nil, table forest, target namespace, data mapping, name mapping.
fn tableMapping() !void {
    try fresh();
    try exec("CREATE TABLE t(a int, b text, c varchar(5), d numeric(6,2), e float8, f bool, g date, h timestamp, i timestamptz, j bytea, k xml, l int[])");
    try exec("INSERT INTO t VALUES (1, 'x<&>y', 'v', 1.25, 2.5, true, '2024-01-02', '2024-01-02 03:04:05.5', '2024-01-02 03:04:05+02', '\\x00ff', '<k>1</k>', ARRAY[1,NULL,3])");
    try exec("INSERT INTO t (a) VALUES (2)");
    try rows("SELECT table_to_xml('t', false, false, '')", "<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n  <c>v</c>\n  <d>1.25</d>\n  <e>2.5</e>\n  <f>true</f>\n  <g>2024-01-02</g>\n  <h>2024-01-02T03:04:05.5</h>\n  <i>2024-01-02T01:04:05+00:00</i>\n  <j>AP8=</j>\n  <k><k>1</k></k>\n  <l><element>1</element><element>3</element></l>\n</row>\n\n<row>\n  <a>2</a>\n</row>\n\n</t>\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try rows("SELECT table_to_xml('t', true, false, '')", "<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n  <c>v</c>\n  <d>1.25</d>\n  <e>2.5</e>\n  <f>true</f>\n  <g>2024-01-02</g>\n  <h>2024-01-02T03:04:05.5</h>\n  <i>2024-01-02T01:04:05+00:00</i>\n  <j>AP8=</j>\n  <k><k>1</k></k>\n  <l><element>1</element><element>3</element></l>\n</row>\n\n<row>\n  <a>2</a>\n  <b xsi:nil=\"true\"/>\n  <c xsi:nil=\"true\"/>\n  <d xsi:nil=\"true\"/>\n  <e xsi:nil=\"true\"/>\n  <f xsi:nil=\"true\"/>\n  <g xsi:nil=\"true\"/>\n  <h xsi:nil=\"true\"/>\n  <i xsi:nil=\"true\"/>\n  <j xsi:nil=\"true\"/>\n  <k xsi:nil=\"true\"/>\n  <l xsi:nil=\"true\"/>\n</row>\n\n</t>\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try rows("SELECT table_to_xml('t', true, true, '')", "<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n  <c>v</c>\n  <d>1.25</d>\n  <e>2.5</e>\n  <f>true</f>\n  <g>2024-01-02</g>\n  <h>2024-01-02T03:04:05.5</h>\n  <i>2024-01-02T01:04:05+00:00</i>\n  <j>AP8=</j>\n  <k><k>1</k></k>\n  <l><element>1</element><element>3</element></l>\n</t>\n\n<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n  <a>2</a>\n  <b xsi:nil=\"true\"/>\n  <c xsi:nil=\"true\"/>\n  <d xsi:nil=\"true\"/>\n  <e xsi:nil=\"true\"/>\n  <f xsi:nil=\"true\"/>\n  <g xsi:nil=\"true\"/>\n  <h xsi:nil=\"true\"/>\n  <i xsi:nil=\"true\"/>\n  <j xsi:nil=\"true\"/>\n  <k xsi:nil=\"true\"/>\n  <l xsi:nil=\"true\"/>\n</t>\n\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try rows("SELECT table_to_xml('t', false, true, 'urn:t')", "<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"urn:t\">\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n  <c>v</c>\n  <d>1.25</d>\n  <e>2.5</e>\n  <f>true</f>\n  <g>2024-01-02</g>\n  <h>2024-01-02T03:04:05.5</h>\n  <i>2024-01-02T01:04:05+00:00</i>\n  <j>AP8=</j>\n  <k><k>1</k></k>\n  <l><element>1</element><element>3</element></l>\n</t>\n\n<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"urn:t\">\n  <a>2</a>\n</t>\n\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try rows("SELECT table_to_xmlschema('t', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"VARCHAR\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"NUMERIC\">\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DOUBLE\">\n  <xsd:restriction base=\"xsd:double\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"BOOLEAN\">\n  <xsd:restriction base=\"xsd:boolean\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DATE\">\n  <xsd:restriction base=\"xsd:date\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP_WTZ\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?(\\+|-)\\p{Nd}{2}:\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType mixed=\"true\">\n  <xsd:sequence>\n    <xsd:any name=\"element\" minOccurs=\"0\" maxOccurs=\"unbounded\" processContents=\"skip\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog._int4\">\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.t\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.text\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"c\" type=\"VARCHAR\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"d\" type=\"NUMERIC\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"e\" type=\"DOUBLE\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"f\" type=\"BOOLEAN\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"g\" type=\"DATE\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"h\" type=\"TIMESTAMP\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"i\" type=\"TIMESTAMP_WTZ\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"j\" type=\"UDT.w5_x005F_xml.pg_catalog.bytea\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"k\" type=\"XML\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"l\" type=\"UDT.w5_x005F_xml.pg_catalog._int4\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType.w5_x005F_xml.public.t\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType.w5_x005F_xml.public.t\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"t\" type=\"TableType.w5_x005F_xml.public.t\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "table_to_xmlschema");
    try rows("SELECT table_to_xmlschema('t', true, true, 'urn:t')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"\n    targetNamespace=\"urn:t\"\n    elementFormDefault=\"qualified\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"VARCHAR\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"NUMERIC\">\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DOUBLE\">\n  <xsd:restriction base=\"xsd:double\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"BOOLEAN\">\n  <xsd:restriction base=\"xsd:boolean\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DATE\">\n  <xsd:restriction base=\"xsd:date\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP_WTZ\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?(\\+|-)\\p{Nd}{2}:\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType mixed=\"true\">\n  <xsd:sequence>\n    <xsd:any name=\"element\" minOccurs=\"0\" maxOccurs=\"unbounded\" processContents=\"skip\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog._int4\">\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.t\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.text\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"c\" type=\"VARCHAR\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"d\" type=\"NUMERIC\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"e\" type=\"DOUBLE\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"f\" type=\"BOOLEAN\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"g\" type=\"DATE\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"h\" type=\"TIMESTAMP\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"i\" type=\"TIMESTAMP_WTZ\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"j\" type=\"UDT.w5_x005F_xml.pg_catalog.bytea\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"k\" type=\"XML\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"l\" type=\"UDT.w5_x005F_xml.pg_catalog._int4\" nillable=\"true\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"t\" type=\"RowType.w5_x005F_xml.public.t\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "table_to_xmlschema");
    try rows("SELECT table_to_xml_and_xmlschema('t', false, false, '')", "<t xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:noNamespaceSchemaLocation=\"#\">\n\n<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"VARCHAR\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"NUMERIC\">\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DOUBLE\">\n  <xsd:restriction base=\"xsd:double\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"BOOLEAN\">\n  <xsd:restriction base=\"xsd:boolean\"></xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"DATE\">\n  <xsd:restriction base=\"xsd:date\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"TIMESTAMP_WTZ\">\n  <xsd:restriction base=\"xsd:dateTime\">\n    <xsd:pattern value=\"\\p{Nd}{4}-\\p{Nd}{2}-\\p{Nd}{2}T\\p{Nd}{2}:\\p{Nd}{2}:\\p{Nd}{2}(.\\p{Nd}+)?(\\+|-)\\p{Nd}{2}:\\p{Nd}{2}\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType mixed=\"true\">\n  <xsd:sequence>\n    <xsd:any name=\"element\" minOccurs=\"0\" maxOccurs=\"unbounded\" processContents=\"skip\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog._int4\">\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.t\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.text\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"c\" type=\"VARCHAR\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"d\" type=\"NUMERIC\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"e\" type=\"DOUBLE\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"f\" type=\"BOOLEAN\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"g\" type=\"DATE\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"h\" type=\"TIMESTAMP\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"i\" type=\"TIMESTAMP_WTZ\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"j\" type=\"UDT.w5_x005F_xml.pg_catalog.bytea\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"k\" type=\"XML\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"l\" type=\"UDT.w5_x005F_xml.pg_catalog._int4\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType.w5_x005F_xml.public.t\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType.w5_x005F_xml.public.t\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"t\" type=\"TableType.w5_x005F_xml.public.t\"/>\n\n</xsd:schema>\n\n<row>\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n  <c>v</c>\n  <d>1.25</d>\n  <e>2.5</e>\n  <f>true</f>\n  <g>2024-01-02</g>\n  <h>2024-01-02T03:04:05.5</h>\n  <i>2024-01-02T01:04:05+00:00</i>\n  <j>AP8=</j>\n  <k><k>1</k></k>\n  <l><element>1</element><element>3</element></l>\n</row>\n\n<row>\n  <a>2</a>\n</row>\n\n</t>\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml_and_xmlschema");
    try rows("SELECT query_to_xml('SELECT a, b FROM t ORDER BY a', true, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n</row>\n\n<row>\n  <a>2</a>\n  <b xsi:nil=\"true\"/>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
    try rows("SELECT query_to_xml('SELECT a AS \"x y\", b AS \"xmlfoo\", 1 AS \"_xa\", 2 AS \":c\" FROM t WHERE a = 1', false, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <x_x0020_y>1</x_x0020_y>\n  <_x0078_mlfoo>x&lt;&amp;&gt;y</_x0078_mlfoo>\n  <_x005F_xa>1</_x005F_xa>\n  <_x003A_c>2</_x003A_c>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
    try rows("SELECT query_to_xmlschema('SELECT a, b FROM t', true, true, 'urn:q')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"\n    targetNamespace=\"urn:q\"\n    elementFormDefault=\"qualified\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" nillable=\"true\"></xsd:element>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.text\" nillable=\"true\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"row\" type=\"RowType\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "query_to_xmlschema");
    try rows("SELECT query_to_xml_and_xmlschema('SELECT a FROM t WHERE a = 1', false, true, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"row\" type=\"RowType\"/>\n\n</xsd:schema>\n\n<row xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n  <a>1</a>\n</row>\n\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml_and_xmlschema");
    try rows("SELECT query_to_xml('SELECT 1 WHERE false', false, false, ''), query_to_xml('SELECT 1 WHERE false', false, true, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n</table>\n|");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
    try meta(1, 142, -1);
    try named(1, "query_to_xml");
    try rows("SELECT query_to_xml('SELECT 1; SELECT 2 AS two', false, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <two>2</two>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
    try rows("SELECT query_to_xml('SELECT xpath(''/a'', ''<a/>'') AS x, * FROM XMLTABLE(''/r/i'' PASSING ''<r><i>1</i></r>'' COLUMNS i int PATH ''.'')', false, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <x><element><a/></element></x>\n  <i>1</i>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
    try rejects("SELECT query_to_xml('INSERT INTO t (a) VALUES (9)', false, false, '')", error.UnsupportedStatement);
    try rejects("SELECT query_to_xml('CREATE TABLE zz(a int)', false, false, '')", error.UnsupportedStatement);
    try rejects("SELECT query_to_xml('', false, false, '')", error.DataException);
    try rejects("SELECT query_to_xml('SELEC 1', false, false, '')", error.Syntax);
    try rejects("SELECT table_to_xml('nosuch', false, false, '')", error.TableNotFound);
    try rows("SELECT table_to_xml(NULL, false, false, ''), table_to_xml('t', NULL, false, '')", "NULL|NULL");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try meta(1, 142, -1);
    try named(1, "table_to_xml");
    try rows("SELECT count(*) FROM t", "2");
    try meta(0, 20, -1);
    try named(0, "count");
    try exec("CREATE TABLE \"a b\"(\"c:d\" INT, \"_x\" INT, \"xmlcol\" int, \"a.b\" int)");
    try exec("INSERT INTO \"a b\" VALUES (1, 2, 3, 4)");
    try rows("SELECT table_to_xml('\"a b\"', false, false, ''), XMLELEMENT(NAME \"x y\", 1)", "<a_x0020_b xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <c_x003A_d>1</c_x003A_d>\n  <_x005F_x>2</_x005F_x>\n  <_x0078_mlcol>3</_x0078_mlcol>\n  <a.b>4</a.b>\n</row>\n\n</a_x0020_b>\n|<x_x0020_y>1</x_x0020_y>");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try meta(1, 142, -1);
    try named(1, "xmlelement");
    try rows("SELECT table_to_xmlschema('\"a b\"', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.a_x0020_b\">\n  <xsd:sequence>\n    <xsd:element name=\"c_x003A_d\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"_x005F_x\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"_x0078_mlcol\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"a.b\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType.w5_x005F_xml.public.a_x0020_b\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType.w5_x005F_xml.public.a_x0020_b\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"a_x0020_b\" type=\"TableType.w5_x005F_xml.public.a_x0020_b\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "table_to_xmlschema");
    const tx = try begin();
    try execIn(tx, "DECLARE c CURSOR FOR SELECT a, b FROM t ORDER BY a");
    try rowsIn(tx, "SELECT cursor_to_xml('c', 1, false, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x&lt;&amp;&gt;y</b>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "cursor_to_xml");
    try rowsIn(tx, "SELECT cursor_to_xml('c', 5, true, true, 'urn:c')", "<row xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"urn:c\">\n  <a>2</a>\n  <b xsi:nil=\"true\"/>\n</row>\n\n");
    try meta(0, 142, -1);
    try named(0, "cursor_to_xml");
    try rowsIn(tx, "SELECT cursor_to_xmlschema('c', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"INTEGER\" minOccurs=\"0\"></xsd:element>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.text\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"table\" type=\"TableType\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "cursor_to_xmlschema");
    try rejectsIn(tx, "SELECT cursor_to_xml('nosuch', 1, false, false, '')", error.PortalNotFound);
    rollback(tx);
}

/// schema_to_xml and database_to_xml with their XML Schema forms.
fn schemaMapping() !void {
    try fresh();
    try exec("CREATE SCHEMA s");
    try exec("CREATE TABLE s.b(x int)");
    try exec("CREATE TABLE s.a(y text, z int)");
    try exec("CREATE VIEW s.v AS SELECT 1 AS one");
    try exec("INSERT INTO s.a VALUES ('q', NULL)");
    try exec("CREATE TABLE p(b bytea)");
    try exec("INSERT INTO p VALUES ('\\xdead')");
    try rows("SELECT schema_to_xml('s', false, false, '')", "<s xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<a>\n\n<row>\n  <y>q</y>\n</row>\n\n</a>\n\n<b>\n\n</b>\n\n<v>\n\n<row>\n  <one>1</one>\n</row>\n\n</v>\n\n</s>\n");
    try meta(0, 142, -1);
    try named(0, "schema_to_xml");
    try rows("SELECT schema_to_xml('s', true, true, '')", "<s xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<a>\n  <y>q</y>\n  <z xsi:nil=\"true\"/>\n</a>\n\n\n\n<v>\n  <one>1</one>\n</v>\n\n\n</s>\n");
    try meta(0, 142, -1);
    try named(0, "schema_to_xml");
    try rows("SELECT schema_to_xmlschema('s', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"SchemaType.w5_x005F_xml.s\">\n  <xsd:all>\n    <xsd:element name=\"a\" type=\"TableType.w5_x005F_xml.s.a\"/>\n    <xsd:element name=\"b\" type=\"TableType.w5_x005F_xml.s.b\"/>\n    <xsd:element name=\"v\" type=\"TableType.w5_x005F_xml.s.v\"/>\n  </xsd:all>\n</xsd:complexType>\n\n<xsd:element name=\"s\" type=\"SchemaType.w5_x005F_xml.s\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "schema_to_xmlschema");
    try rows("SELECT schema_to_xmlschema('s', true, true, 'urn:s')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"\n    targetNamespace=\"urn:s\"\n    elementFormDefault=\"qualified\">\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"SchemaType.w5_x005F_xml.s\">\n  <xsd:sequence>\n    <xsd:element name=\"a\" type=\"RowType.w5_x005F_xml.s.a\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n    <xsd:element name=\"b\" type=\"RowType.w5_x005F_xml.s.b\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n    <xsd:element name=\"v\" type=\"RowType.w5_x005F_xml.s.v\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"s\" type=\"SchemaType.w5_x005F_xml.s\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "schema_to_xmlschema");
    try rows("SELECT schema_to_xml_and_xmlschema('s', false, false, '')", "<s xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:noNamespaceSchemaLocation=\"#\">\n\n<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"SchemaType.w5_x005F_xml.s\">\n  <xsd:all>\n    <xsd:element name=\"a\" type=\"TableType.w5_x005F_xml.s.a\"/>\n    <xsd:element name=\"b\" type=\"TableType.w5_x005F_xml.s.b\"/>\n    <xsd:element name=\"v\" type=\"TableType.w5_x005F_xml.s.v\"/>\n  </xsd:all>\n</xsd:complexType>\n\n<xsd:element name=\"s\" type=\"SchemaType.w5_x005F_xml.s\"/>\n\n</xsd:schema>\n\n<a>\n\n<row>\n  <y>q</y>\n</row>\n\n</a>\n\n<b>\n\n</b>\n\n<v>\n\n<row>\n  <one>1</one>\n</row>\n\n</v>\n\n</s>\n");
    try meta(0, 142, -1);
    try named(0, "schema_to_xml_and_xmlschema");
    try rejects("SELECT schema_to_xml('nosuch', false, false, '')", error.UndefinedSchema);
    try rows("SELECT database_to_xml(false, false, '')", "<w5_x005F_xml xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<public>\n\n<p>\n\n<row>\n  <b>3q0=</b>\n</row>\n\n</p>\n\n</public>\n\n<s>\n\n<a>\n\n<row>\n  <y>q</y>\n</row>\n\n</a>\n\n<b>\n\n</b>\n\n<v>\n\n<row>\n  <one>1</one>\n</row>\n\n</v>\n\n</s>\n\n</w5_x005F_xml>\n");
    try meta(0, 142, -1);
    try named(0, "database_to_xml");
    try rows("SELECT database_to_xmlschema(false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"CatalogType.w5_x005F_xml\">\n  <xsd:all>\n    <xsd:element name=\"public\" type=\"SchemaType.w5_x005F_xml.public\"/>\n    <xsd:element name=\"s\" type=\"SchemaType.w5_x005F_xml.s\"/>\n  </xsd:all>\n</xsd:complexType>\n\n<xsd:element name=\"w5_x005F_xml\" type=\"CatalogType.w5_x005F_xml\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "database_to_xmlschema");
    try rows("SELECT database_to_xml_and_xmlschema(true, true, 'urn:d')", "<w5_x005F_xml xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns=\"urn:d\" xsi:schemaLocation=\"urn:d #\">\n\n<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\"\n    targetNamespace=\"urn:d\"\n    elementFormDefault=\"qualified\">\n\n<xsd:simpleType name=\"INTEGER\">\n  <xsd:restriction base=\"xsd:int\">\n    <xsd:maxInclusive value=\"2147483647\"/>\n    <xsd:minInclusive value=\"-2147483648\"/>\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.text\">\n  <xsd:restriction base=\"xsd:string\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"CatalogType.w5_x005F_xml\">\n  <xsd:all>\n    <xsd:element name=\"public\" type=\"SchemaType.w5_x005F_xml.public\"/>\n    <xsd:element name=\"s\" type=\"SchemaType.w5_x005F_xml.s\"/>\n  </xsd:all>\n</xsd:complexType>\n\n<xsd:element name=\"w5_x005F_xml\" type=\"CatalogType.w5_x005F_xml\"/>\n\n</xsd:schema>\n\n<public>\n\n<p>\n  <b>3q0=</b>\n</p>\n\n\n</public>\n\n<s>\n\n<a>\n  <y>q</y>\n  <z xsi:nil=\"true\"/>\n</a>\n\n\n\n<v>\n  <one>1</one>\n</v>\n\n\n</s>\n\n</w5_x005F_xml>\n");
    try meta(0, 142, -1);
    try named(0, "database_to_xml_and_xmlschema");
}

/// xmlbinary (base64 with CRLF every 72 characters, or hex) in XMLELEMENT, XMLFOREST and the table mappings; XML parameters of SQL and PL/pgSQL routines.
fn bytesAndRoutines() !void {
    try fresh();
    try exec("CREATE TABLE big(b bytea)");
    try exec("INSERT INTO big VALUES (('\\x' || repeat('00ff', 60))::bytea)");
    try rows("SELECT table_to_xml('big', false, false, '')", "<big xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <b>AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/\r\nAP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/\r\nAP8A/wD/AP8A/wD/</b>\n</row>\n\n</big>\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
    try rows("SELECT XMLELEMENT(NAME e, ('\\x' || repeat('00ff', 60))::bytea), XMLFOREST('\\x0102ff'::bytea AS b)", "<e>AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/\r\nAP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/AP8A/wD/\r\nAP8A/wD/AP8A/wD/</e>|<b>AQL/</b>");
    try meta(0, 142, -1);
    try named(0, "xmlelement");
    try meta(1, 142, -1);
    try named(1, "xmlforest");
    db.session.xml_binary_hex = true;
    try rows("SELECT XMLELEMENT(NAME e, '\\x0aff'::bytea), XMLFOREST('\\x01'::bytea AS b), table_to_xml('big', false, false, '')", "<e>0AFF</e>|<b>01</b>|<big xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <b>00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF</b>\n</row>\n\n</big>\n");
    try meta(0, 142, -1);
    try named(0, "xmlelement");
    try meta(1, 142, -1);
    try named(1, "xmlforest");
    try meta(2, 142, -1);
    try named(2, "table_to_xml");
    try rows("SELECT table_to_xmlschema('big', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:hexBinary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.big\">\n  <xsd:sequence>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.bytea\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType.w5_x005F_xml.public.big\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType.w5_x005F_xml.public.big\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"big\" type=\"TableType.w5_x005F_xml.public.big\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "table_to_xmlschema");
    db.session.xml_binary_hex = false;
    try rows("SELECT table_to_xmlschema('big', false, false, '')", "<xsd:schema\n    xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">\n\n<xsd:simpleType name=\"UDT.w5_x005F_xml.pg_catalog.bytea\">\n  <xsd:restriction base=\"xsd:base64Binary\">\n  </xsd:restriction>\n</xsd:simpleType>\n\n<xsd:complexType name=\"RowType.w5_x005F_xml.public.big\">\n  <xsd:sequence>\n    <xsd:element name=\"b\" type=\"UDT.w5_x005F_xml.pg_catalog.bytea\" minOccurs=\"0\"></xsd:element>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:complexType name=\"TableType.w5_x005F_xml.public.big\">\n  <xsd:sequence>\n    <xsd:element name=\"row\" type=\"RowType.w5_x005F_xml.public.big\" minOccurs=\"0\" maxOccurs=\"unbounded\"/>\n  </xsd:sequence>\n</xsd:complexType>\n\n<xsd:element name=\"big\" type=\"TableType.w5_x005F_xml.public.big\"/>\n\n</xsd:schema>");
    try meta(0, 142, -1);
    try named(0, "table_to_xmlschema");
    try exec("CREATE FUNCTION root_name(x XML) RETURNS TEXT LANGUAGE plpgsql AS $$BEGIN RETURN (xpath('name(/*)', x))[1]::text; END$$");
    try exec("CREATE FUNCTION wrap(x XML) RETURNS XML LANGUAGE SQL AS $$SELECT XMLELEMENT(NAME w, x)$$");
    try exec("CREATE FUNCTION firsts(x XML) RETURNS SETOF TEXT LANGUAGE SQL AS $$SELECT v FROM XMLTABLE('/r/i' PASSING x COLUMNS v text PATH '.')$$");
    try rows("SELECT root_name('<abc/>'), wrap('<i/>'), xpath('/w/i', wrap('<i/>'))", "abc|<w><i/></w>|{<i/>}");
    try meta(0, 25, -1);
    try named(0, "root_name");
    try meta(1, 142, -1);
    try named(1, "wrap");
    try meta(2, 143, -1);
    try named(2, "xpath");
    try rows("SELECT * FROM firsts('<r><i>1</i><i>2</i></r>')", "1;2");
    try meta(0, 25, -1);
    try named(0, "firsts");
    try rows("SELECT query_to_xml('SELECT root_name(''<q/>'') AS n', false, false, '')", "<table xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <n>q</n>\n</row>\n\n</table>\n");
    try meta(0, 142, -1);
    try named(0, "query_to_xml");
}

/// Every work budget below a statement's need fails with QueryWorkLimit at that budget and every cancellation point with QueryCanceled; an unbudgeted rerun gives the same rows.
fn workControl() !void {
    try fresh();
    try controlled("SELECT xpath('//b[position() mod 2 = 1]/text()', '<a><b>1</b><b>2</b><b>3</b><b>4</b><b>5</b></a>')", "{1,3,5}");
    try meta(0, 143, -1);
    try named(0, "xpath");
    try controlled("SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i a=\"1\">x</i><i a=\"2\">y</i></r>' COLUMNS a int PATH '@a', v text PATH '.', o FOR ORDINALITY)", "1|x|1;2|y|2");
    try meta(0, 23, -1);
    try named(0, "a");
    try meta(1, 25, -1);
    try named(1, "v");
    try meta(2, 23, -1);
    try named(2, "o");
    try controlled("SELECT XMLSERIALIZE(DOCUMENT '<a><b><c/></b><d/></a>' AS TEXT INDENT)", "<a>\n  <b>\n    <c/>\n  </b>\n  <d/>\n</a>");
    try meta(0, 25, -1);
    try named(0, "xmlserialize");
    try exec("CREATE TABLE w(a int, b text)");
    try exec("INSERT INTO w VALUES (1, 'x'), (2, 'y')");
    try controlled("SELECT table_to_xml('w', true, false, '')", "<w xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x</b>\n</row>\n\n<row>\n  <a>2</a>\n  <b>y</b>\n</row>\n\n</w>\n");
    try meta(0, 142, -1);
    try named(0, "table_to_xml");
}

/// XPath, XMLTABLE, INDENT and table-mapping results stored in xml and xml[] columns replay exactly into a replica (value tag 27; no new change record).
fn durability() !void {
    try fresh();
    try replay(&.{
        "CREATE TABLE r(id INT PRIMARY KEY, x XML, a XML[])",
        "INSERT INTO r VALUES (1, (xpath('/a/b', '<a><b c=\"1\">t</b></a>'))[1], xpath('//b/text()', '<a><b>1</b><b>2</b></a>'))",
        "INSERT INTO r SELECT 2, x, NULL FROM XMLTABLE('/r/i' PASSING '<r><i><j k=\"v\"/></i></r>' COLUMNS x xml PATH 'j')",
        "INSERT INTO r VALUES (3, XMLSERIALIZE(DOCUMENT '<a><b/></a>' AS TEXT INDENT)::xml, NULL)",
        "CREATE TABLE m(a int, b text)",
        "INSERT INTO m VALUES (1, 'x')",
        "INSERT INTO r VALUES (4, table_to_xml('m', false, false, ''), ARRAY[query_to_xml('SELECT 2 AS n', false, true, '')])",
        "UPDATE r SET x = (xpath('/t/row/b', table_to_xml('m', false, false, '')))[1] WHERE id = 3",
    }, &.{ "r", "m" }, "SELECT * FROM r ORDER BY id");
    try shown("replica", "1|<b c=\"1\">t</b>|{1,2};2|<j k=\"v\"/>|NULL;3|NULL|NULL;4|<m xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n\n<row>\n  <a>1</a>\n  <b>x</b>\n</row>\n\n</m>\n|{\"<row xmlns:xsi=\\\"http://www.w3.org/2001/XMLSchema-instance\\\">\n  <n>2</n>\n</row>\n\n\"}");
}
// ---- capacities ----------------------------------------------------------------

/// A database with small SQL/XML capacities: 16 document nodes, 12 XPath
/// expression nodes, XPath nesting 3 and 2 KiB of scratch.
const Small = sql.Database(.{ .tables = 2, .columns = 4, .rows_per_table = 32, .name_bytes = 63, .text_bytes = 256, .integer_bits = 32, .nulls_first_ascending = false, .work_rows = 64, .result_rows = 8, .xml_nodes = 16, .xpath_nodes = 12, .xpath_depth = 3, .xml_bytes = 2048 });
var small: Small = .{};
var small_result: Small.Result = .{};

fn smallRejects(source: []const u8, wanted: anyerror) !void {
    if (small.execute(source, &small_result)) |_| {
        std.debug.print("accepted: {s}\n", .{source});
        return error.InvalidSqlAccepted;
    } else |err| {
        if (err != wanted) std.debug.print("{s}: {s} (wanted {s})\n", .{ source, @errorName(err), @errorName(wanted) });
        try check(err == wanted);
    }
    try check(small.usage().pending_versions == 0 and small.usage().transactions == 0);
}

fn smallAccepts(source: []const u8) !void {
    small.execute(source, &small_result) catch |err| {
        std.debug.print("failed: {s}: {s}\n", .{ source, @errorName(err) });
        return err;
    };
}

/// Going over Config.xml_nodes, xpath_nodes, xpath_depth or xml_bytes is
/// ProgramLimitExceeded (54000) with nothing changed; the same database
/// keeps working (its scratch region is free again).
fn capacities() !void {
    small = .{};
    try smallAccepts("SELECT xpath('/a/b', '<a><b/><b/><b/><b/><b/></a>')");
    try check(small_result.row_count == 1);
    // 17 nodes: the document, 16 elements.
    try smallRejects("SELECT xpath('/a', '<a><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/><b/></a>')", error.ProgramLimitExceeded);
    // Attributes and namespace declarations are nodes too.
    try smallRejects("SELECT xpath('/a', '<a x=\"1\" y=\"2\" z=\"3\" xmlns:p=\"urn:p\"><b q=\"1\" r=\"2\"/><b/><b/><b/><b/><b/><b/><b/><b/></a>')", error.ProgramLimitExceeded);
    // 13 expression nodes.
    try smallRejects("SELECT xpath('1+1+1+1+1+1+1', '<a/>')", error.ProgramLimitExceeded);
    try smallAccepts("SELECT xpath('1+1+1+1+1+1', '<a/>')");
    // Nesting deeper than 3.
    try smallRejects("SELECT xpath('((((1))))', '<a/>')", error.ProgramLimitExceeded);
    try smallAccepts("SELECT xpath('((1))', '<a/>')");
    // The serialized result does not fit the scratch region.
    try smallAccepts("CREATE TABLE t(a int, b text)");
    var insert: [512]u8 = undefined;
    for (0..30) |row| {
        try smallAccepts(try std.fmt.bufPrint(&insert, "INSERT INTO t VALUES ({d}, '{s}')", .{ row, "x" ** 200 }));
    }
    try smallRejects("SELECT table_to_xml('t', false, false, '')", error.ProgramLimitExceeded);
    try smallRejects("SELECT * FROM XMLTABLE('/r/i' PASSING '<r><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/><i/></r>' COLUMNS v text PATH '.')", error.ProgramLimitExceeded);
    // Unchanged and usable afterwards.
    try smallAccepts("SELECT count(*), xpath('count(/a/b)', '<a><b/><b/></a>') FROM t");
    var buffer: [Small.Io.format_bytes]u8 = undefined;
    try check(std.mem.eql(u8, try Small.Io.format(&small_result.rows[0].cells[0], false, &small.session, &buffer), "30"));
    try check(std.mem.eql(u8, try Small.Io.format(&small_result.rows[0].cells[1], false, &small.session, &buffer), "{2}"));
    try sqlstate(error.ProgramLimitExceeded, "54000");
}

/// Hostile input: a quadratic path over a document stops at any work
/// budget below its need with QueryWorkLimit (every node visit is a
/// checkpoint), never hanging the worker; the cost grows with the input.
fn hostile() !void {
    try fresh();
    const source = "SELECT xpath('count(//*[count(preceding::*) >= 0][count(following::*) >= 0])', '<a><b><c/><c/><c/><c/></b><b><c/><c/><c/><c/></b><b><c/><c/><c/><c/></b><b><c/><c/><c/><c/></b></a>')";
    var control: sql.ExecutionControl = .{};
    db.session.control = &control;
    defer db.session.control = null;
    try exec(source);
    try shown(source, "{21}");
    const used = control.used;
    try check(used > 21 * 21);
    control.reset(used / 2);
    try rejects(source, error.QueryWorkLimit);
    try check(control.used == used / 2);
}

pub fn main(init: std.process.Init) !void {
    try xpathFunctions();
    try xmlTable();
    try documents();
    try tableMapping();
    try schemaMapping();
    try bytesAndRoutines();
    try workControl();
    try durability();
    try capacities();
    try hostile();
    try sqlstate(error.CardinalityViolation, "21000");
    try sqlstate(error.DataException, "22000");
    try sqlstate(error.InternalError, "XX000");
    try sqlstate(error.InvalidArgumentForXquery, "10608");
    try sqlstate(error.InvalidTextRepresentation, "22P02");
    try sqlstate(error.InvalidXmlDocument, "2200M");
    try sqlstate(error.NotAnXmlDocument, "2200L");
    try sqlstate(error.NullValueNotAllowed, "22004");
    try sqlstate(error.PortalNotFound, "34000");
    try sqlstate(error.StringDataRightTruncation, "22001");
    try sqlstate(error.Syntax, "42601");
    try sqlstate(error.TableNotFound, "42P01");
    try sqlstate(error.TypeMismatch, "42804");
    try sqlstate(error.UndefinedFunction, "42883");
    try sqlstate(error.UndefinedSchema, "3F000");
    try sqlstate(error.UnsupportedStatement, "0A000");
    try sqlstate(error.QueryWorkLimit, "54000");
    try sqlstate(error.QueryCanceled, "57014");
    var buffer: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"suite\":\"sql-xml\",\"pass\":true,\"assertions\":{d}}}\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}
