//! LSP request dispatch and server lifecycle — Layer 0 (pure, no I/O).
//!
//! Owns the server state (document store + lifecycle flags) and turns a parsed
//! JSON-RPC message into a framed response body. Transport lives in the caller;
//! this module is pure: given a message it produces bytes into a caller-provided
//! buffer. No allocator, no I/O — fully unit-testable and reusable by any Sig
//! language server. The server name/version reported in `initialize` are
//! configurable so consumers brand their own server.

const std = @import("std");
const json = @import("json");
const message = @import("message");
const jwrite = @import("jwrite");
const document = @import("document");
const position = @import("position");
const symbols = @import("symbols");

/// Server identity reported in the `initialize` response. Defaults can be
/// overridden per-instance via `Server.info`.
pub const ServerInfo = struct {
    name: []const u8 = "zpm-lsp",
    version: []const u8 = "0.1.0",
};

pub const Outcome = enum { respond, none, exit };

pub const Result = struct {
    outcome: Outcome,
    body: []const u8 = "",
};

pub const Server = struct {
    info: ServerInfo = .{},
    store: document.Store = .{},
    /// Scratch for decoding JSON string escapes out of inbound document text.
    decode_buf: [document.MAX_TEXT]u8 = undefined,
    initialized: bool = false,
    shutdown_requested: bool = false,

    pub fn handle(self: *Server, msg: message.Message, out: []u8) Result {
        const m = msg.method;
        if (eql(m, "initialize")) return self.respondInitialize(msg, out);
        if (eql(m, "initialized")) return .{ .outcome = .none };
        if (eql(m, "shutdown")) return self.respondShutdown(msg, out);
        if (eql(m, "exit")) return .{ .outcome = .exit };
        if (eql(m, "textDocument/didOpen")) return self.onDidOpen(msg);
        if (eql(m, "textDocument/didChange")) return self.onDidChange(msg);
        if (eql(m, "textDocument/didClose")) return self.onDidClose(msg);
        if (eql(m, "textDocument/documentSymbol")) return self.respondDocumentSymbol(msg, out);
        if (msg.id_present) return self.respondError(msg.id, -32601, "method not found", out);
        return .{ .outcome = .none };
    }

    fn respondInitialize(self: *Server, msg: message.Message, out: []u8) Result {
        self.initialized = true;
        var w = jwrite.Writer.init(out);
        writeInitialize(&w, msg.id, self.info) catch return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondShutdown(self: *Server, msg: message.Message, out: []u8) Result {
        self.shutdown_requested = true;
        var w = jwrite.Writer.init(out);
        writeResultNull(&w, msg.id) catch return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn onDidOpen(self: *Server, msg: message.Message) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        const raw = extractText(msg.body) orelse "";
        const text = unescapeJson(raw, &self.decode_buf);
        const version = json.getInt(msg.body, "version\"") orelse 0;
        _ = self.store.open(uri, text, version) catch {};
        return .{ .outcome = .none };
    }

    fn onDidChange(self: *Server, msg: message.Message) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        const version = json.getInt(msg.body, "version\"") orelse 0;
        const raw = extractText(msg.body) orelse return .{ .outcome = .none };
        const text = unescapeJson(raw, &self.decode_buf);
        _ = self.store.replace(uri, text, version) catch {};
        return .{ .outcome = .none };
    }

    fn onDidClose(self: *Server, msg: message.Message) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return .{ .outcome = .none };
        _ = self.store.close(uri);
        return .{ .outcome = .none };
    }

    fn respondDocumentSymbol(self: *Server, msg: message.Message, out: []u8) Result {
        const uri = json.getString(msg.body, "uri\"") orelse return self.respondEmptyArray(msg.id, out);
        const doc = self.store.get(uri) orelse return self.respondEmptyArray(msg.id, out);
        var scan_result: symbols.Scan = .{};
        symbols.scan(doc.text(), &scan_result);
        var w = jwrite.Writer.init(out);
        writeDocumentSymbols(&w, msg.id, doc.text(), scan_result.slice()) catch return errorResult(msg.id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondEmptyArray(self: *Server, id: i64, out: []u8) Result {
        _ = self;
        var w = jwrite.Writer.init(out);
        writeEmptyArrayResult(&w, id) catch return errorResult(id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }

    fn respondError(self: *Server, id: i64, code: i64, msg_text: []const u8, out: []u8) Result {
        _ = self;
        var w = jwrite.Writer.init(out);
        writeError(&w, id, code, msg_text) catch return errorResult(id, out);
        return .{ .outcome = .respond, .body = w.bytes() };
    }
};

// ── Response body writers ────────────────────────────────────────────────────

fn writeResponseHead(w: *jwrite.Writer, id: i64) !void {
    try w.beginObject();
    try w.key("jsonrpc");
    try w.string("2.0");
    try w.comma();
    try w.key("id");
    try w.int(id);
    try w.comma();
}

pub fn writeInitialize(w: *jwrite.Writer, id: i64, info: ServerInfo) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginObject();
    try w.key("capabilities");
    try w.beginObject();
    try w.key("textDocumentSync");
    try w.int(1);
    try w.comma();
    try w.key("documentSymbolProvider");
    try w.boolean(true);
    try w.endObject();
    try w.comma();
    try w.key("serverInfo");
    try w.beginObject();
    try w.key("name");
    try w.string(info.name);
    try w.comma();
    try w.key("version");
    try w.string(info.version);
    try w.endObject();
    try w.endObject();
    try w.endObject();
}

pub fn writeResultNull(w: *jwrite.Writer, id: i64) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.nullValue();
    try w.endObject();
}

pub fn writeEmptyArrayResult(w: *jwrite.Writer, id: i64) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginArray();
    try w.endArray();
    try w.endObject();
}

pub fn writeError(w: *jwrite.Writer, id: i64, code: i64, msg_text: []const u8) !void {
    try writeResponseHead(w, id);
    try w.key("error");
    try w.beginObject();
    try w.key("code");
    try w.int(code);
    try w.comma();
    try w.key("message");
    try w.string(msg_text);
    try w.endObject();
    try w.endObject();
}

fn writeRange(w: *jwrite.Writer, text: []const u8, start_off: usize, end_off: usize) !void {
    const start = position.positionAt(text, start_off);
    const end = position.positionAt(text, end_off);
    try w.key("range");
    try writePositionRange(w, start, end);
    try w.comma();
    try w.key("selectionRange");
    try writePositionRange(w, start, end);
}

fn writePositionRange(w: *jwrite.Writer, start: position.Position, end: position.Position) !void {
    try w.beginObject();
    try w.key("start");
    try writePosition(w, start);
    try w.comma();
    try w.key("end");
    try writePosition(w, end);
    try w.endObject();
}

fn writePosition(w: *jwrite.Writer, p: position.Position) !void {
    try w.beginObject();
    try w.key("line");
    try w.int(@intCast(p.line));
    try w.comma();
    try w.key("character");
    try w.int(@intCast(p.character));
    try w.endObject();
}

pub fn writeDocumentSymbols(w: *jwrite.Writer, id: i64, text: []const u8, syms: []const symbols.Symbol) !void {
    try writeResponseHead(w, id);
    try w.key("result");
    try w.beginArray();
    for (syms, 0..) |sym, idx| {
        if (idx != 0) try w.comma();
        try w.beginObject();
        try w.key("name");
        try w.string(sym.name);
        try w.comma();
        try w.key("kind");
        try w.int(@intCast(@intFromEnum(sym.kind)));
        try w.comma();
        try writeRange(w, text, sym.name_offset, sym.name_offset + sym.name.len);
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

// ── helpers ─────────────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn errorResult(id: i64, out: []u8) Result {
    var w = jwrite.Writer.init(out);
    writeError(&w, id, -32603, "internal error") catch return .{ .outcome = .none };
    return .{ .outcome = .respond, .body = w.bytes() };
}

fn extractText(body: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var search_from: usize = 0;
    while (search_from < body.len) {
        const rel = json.findKey(body[search_from..], "\"text\"") orelse break;
        const after_key = search_from + rel;
        if (readStringAfter(body, after_key)) |v| {
            result = v;
        }
        search_from = after_key + 1;
    }
    return result;
}

fn unescapeJson(raw: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw.len and w < out.len) {
        const c = raw[i];
        if (c != '\\' or i + 1 >= raw.len) {
            out[w] = c;
            w += 1;
            i += 1;
            continue;
        }
        const e = raw[i + 1];
        switch (e) {
            '"' => { out[w] = '"'; w += 1; i += 2; },
            '\\' => { out[w] = '\\'; w += 1; i += 2; },
            '/' => { out[w] = '/'; w += 1; i += 2; },
            'n' => { out[w] = '\n'; w += 1; i += 2; },
            'r' => { out[w] = '\r'; w += 1; i += 2; },
            't' => { out[w] = '\t'; w += 1; i += 2; },
            'b' => { out[w] = 8; w += 1; i += 2; },
            'f' => { out[w] = 12; w += 1; i += 2; },
            'u' => {
                if (i + 6 <= raw.len) {
                    const cp = parseHex4(raw[i + 2 .. i + 6]);
                    w += encodeUtf8(cp, out[w..]);
                    i += 6;
                } else {
                    out[w] = e;
                    w += 1;
                    i += 2;
                }
            },
            else => { out[w] = e; w += 1; i += 2; },
        }
    }
    return out[0..w];
}

fn parseHex4(s: []const u8) u21 {
    var v: u21 = 0;
    for (s) |c| {
        const d: u21 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
        v = v * 16 + d;
    }
    return v;
}

fn encodeUtf8(cp: u21, out: []u8) usize {
    if (cp < 0x80) {
        if (out.len < 1) return 0;
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        if (out.len < 2) return 0;
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        if (out.len < 3) return 0;
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        if (out.len < 4) return 0;
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

fn readStringAfter(body: []const u8, from: usize) ?[]const u8 {
    var i = from;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    if (i > body.len) return null;
    return body[start..i];
}

// ── tests ─────────────────────────────────────────────────────────────────

var test_srv: Server = .{};

test "initialize advertises capabilities and configurable serverInfo" {
    const srv = &test_srv;
    srv.* = .{ .info = .{ .name = "demo-ls", .version = "9.9.9" } };
    var out: [4096]u8 = undefined;
    const res = srv.handle(message.parse("{\"id\":1,\"method\":\"initialize\"}"), &out);
    try std.testing.expectEqual(Outcome.respond, res.outcome);
    try std.testing.expect(srv.initialized);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"documentSymbolProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"name\":\"demo-ls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"version\":\"9.9.9\"") != null);
}

test "shutdown then exit" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const sd = srv.handle(message.parse("{\"id\":2,\"method\":\"shutdown\"}"), &out);
    try std.testing.expectEqual(Outcome.respond, sd.outcome);
    try std.testing.expect(std.mem.indexOf(u8, sd.body, "\"result\":null") != null);
    const ex = srv.handle(message.parse("{\"method\":\"exit\"}"), &out);
    try std.testing.expectEqual(Outcome.exit, ex.outcome);
}

test "unknown request yields MethodNotFound, unknown notification ignored" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const req = srv.handle(message.parse("{\"id\":9,\"method\":\"textDocument/nope\"}"), &out);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "-32601") != null);
    const note = srv.handle(message.parse("{\"method\":\"$/whatever\"}"), &out);
    try std.testing.expectEqual(Outcome.none, note.outcome);
}

test "didOpen then documentSymbol returns outline; didChange updates it" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [8192]u8 = undefined;
    _ = srv.handle(message.parse(
        "{\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{" ++
            "\"uri\":\"file:///d.sig\",\"version\":1," ++
            "\"text\":\"const std = @import(\\\"std\\\");\\npub fn main() void {}\\npub const Point = struct { x: i32 };\"}}}",
    ), &out);
    const ds = srv.handle(message.parse(
        "{\"id\":7,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///d.sig\"}}}",
    ), &out);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"std\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds.body, "\"name\":\"Point\"") != null);

    _ = srv.handle(message.parse(
        "{\"method\":\"textDocument/didChange\",\"params\":{\"textDocument\":{" ++
            "\"uri\":\"file:///d.sig\",\"version\":2},\"contentChanges\":[{\"text\":\"pub fn changed() void {}\"}]}}",
    ), &out);
    const ds2 = srv.handle(message.parse(
        "{\"id\":8,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///d.sig\"}}}",
    ), &out);
    try std.testing.expect(std.mem.indexOf(u8, ds2.body, "\"name\":\"changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ds2.body, "\"name\":\"Point\"") == null);
}

test "documentSymbol on unknown document returns empty array" {
    const srv = &test_srv;
    srv.* = .{};
    var out: [1024]u8 = undefined;
    const res = srv.handle(message.parse(
        "{\"id\":3,\"method\":\"textDocument/documentSymbol\",\"params\":{\"textDocument\":{\"uri\":\"file:///missing.sig\"}}}",
    ), &out);
    try std.testing.expect(std.mem.indexOf(u8, res.body, "\"result\":[]") != null);
}
