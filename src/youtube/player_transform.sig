// @zpm/youtube/player_transform — bounded extraction and Sig execution of
// the original player's indexed string-table transforms. No external runtime.
//
// The VM is shared with BotGuard. Prepare transforms after copying a minted
// token out of that VM; preparing a new player deliberately replaces its realm.
const js = @import("botguard/jsvm/root.sig");
const Value = js.values.Value;
const MAX_FUNCTIONS = 4096;
const MAX_FUNCTION_BYTES = 16384;
const MAX_SOURCE = 256 * 1024;
const NONE: u16 = 0xffff;
const Def = struct { name: []const u8, source: []const u8, selected: bool = false };
var defs: [MAX_FUNCTIONS]Def = undefined;
var def_count: usize = 0;
var source_buf: [MAX_SOURCE]u8 = undefined;
var source_len: usize = 0;
var table_name: []const u8 = "";
var table_value: []const u8 = "";
var table_items: [256][]const u8 = undefined;
var table_count: usize = 0;
var n_def: u16 = NONE;
var sig_def: u16 = NONE;
var n_arg0: u32 = 0;
var n_arg1: u32 = 0;
var sig_arg0: u32 = 0;
var sig_arg1: u32 = 0;
var failure_index: u16 = NONE;
var n_fn: Value = Value.UNDEFINED;
var sig_fn: Value = Value.UNDEFINED;
var ready: bool = false;
var ready_generation: u32 = 0;
var ready_realm: u32 = 0;
var attempted: bool = false;
var attempted_generation: u32 = 0;
var attempted_realm: u32 = 0;
pub const Failure = enum { none, table, capacity, functions, entry, arguments, syntax, compile, runtime, result };
pub var last_failure: Failure = .none;

pub fn preparedSourceLength() usize { return source_len; }
pub fn preparedSource() []const u8 { return source_buf[0..source_len]; }
pub fn isNReady() bool { return ready and ready_realm == js.vm.realmGeneration() and n_fn.tag == .function; }
pub fn isSignatureReady() bool { return ready and ready_realm == js.vm.realmGeneration() and sig_fn.tag == .function; }
pub fn isPreparedFor(generation: u32) bool { return ready and ready_generation == generation and ready_realm == js.vm.realmGeneration(); }

pub fn prepare(player: []const u8, generation: u32) bool {
    if (isPreparedFor(generation)) return true;
    if (attempted and attempted_generation == generation and attempted_realm == js.vm.realmGeneration()) return false;
    attempted = true; attempted_generation = generation; attempted_realm = js.vm.realmGeneration();
    ready = false; n_fn = Value.UNDEFINED; sig_fn = Value.UNDEFINED;
    last_failure = .none; source_len = 0; def_count = 0;
    n_def = NONE; sig_def = NONE; failure_index = NONE;
    if (!findTable(player)) { last_failure = .table; return false; }
    const split_index = tableIndex("split") orelse return fail(.table);
    const join_index = tableIndex("join") orelse return fail(.table);
    const empty_index = tableIndex("") orelse return fail(.table);
    var marker_buf: [128]u8 = undefined;
    const marker = makeCallMarker(&marker_buf, split_index, empty_index) orelse return fail(.capacity);

    var pos: usize = 0;
    while (findFrom(player, "=function", pos)) |at| {
        pos = at + 9;
        const name = nameBefore(player, at);
        if (name.len == 0) continue;
        const start = at + 1;
        const tail = player[start..@min(player.len, start + MAX_FUNCTION_BYTES)];
        const len = balancedValueLength(tail);
        if (len == 0) continue;
        if (def_count == defs.len) return fail(.capacity);
        const body = tail[0..len];
        const selected = refersToTable(body);
        defs[def_count] = .{ .name = name, .source = body, .selected = selected };
        if (selected and find(body, marker) != null) {
            if (find(body, "typeof ") != null and find(body, "try{") != null) {
                if (n_def != NONE) return fail(.entry);
                n_def = @intCast(def_count);
            } else if (find(body, "return") != null and find(body, "join") == null) {
                // Signature code also indexes join through the table.
                // Require a method call followed by the table's empty string.
                if (hasIndexedJoin(body, join_index, empty_index, null)) sig_def = @intCast(def_count);
            }
        }
        def_count += 1;
    }
    if (n_def == NONE and sig_def == NONE) return fail(.entry);
    if (n_def != NONE and !extractNArguments(defs[n_def].source, marker, join_index, empty_index)) return fail(.arguments);
    if (sig_def != NONE and !extractCallArguments(player, defs[sig_def].name, &sig_arg0, &sig_arg1)) sig_def = NONE;

    // The entry dispatcher may not itself refer to the string table.
    // Keep its original definition as well as all table-using helpers.
    if (n_def != NONE) {
        const body = defs[n_def].source;
        var i: usize = 0;
        while (i < def_count) : (i += 1) {
            if (!parameterNamed(body, defs[i].name) and callsNamed(body, defs[i].name)) defs[i].selected = true;
        }
    }
    if (!append("var ") or !append(table_name) or !append("=") or !append(table_value) or !append(";\n")) return fail(.capacity);
    var i: usize = 0;
    while (i < def_count) : (i += 1) {
        if (!defs[i].selected) continue;
        if (!append("var ") or !append(defs[i].name) or !append("=") or !append(defs[i].source) or !append(";\n")) return fail(.capacity);
    }
    // Preserve the entry's typeof guard value and signature helper object.
    // These are original player declarations, not substitute implementations.
    if (n_def != NONE and !appendTypeofGuard(player, defs[n_def].source)) return fail(.entry);
    if (sig_def != NONE and !appendHelperObjects(player, defs[sig_def].source)) return fail(.entry);

    js.values.reset();
    const nt = js.lexer.tokenize(source_buf[0..source_len]);
    if (nt == 0) return fail(.syntax);
    const root = js.parser.parse(nt);
    if (root == js.parser.NULL_NODE or js.parser.hasError()) return fail(.syntax);
    if (js.compiler.compile(root) == 0 or js.compiler.hasError()) return fail(.compile);
    _ = js.vm.execute();
    attempted_realm = js.vm.realmGeneration();
    if (js.vm.hasError()) return fail(.runtime);
    if (n_def != NONE) n_fn = js.vm.getGlobalVar(defs[n_def].name);
    if (sig_def != NONE) sig_fn = js.vm.getGlobalVar(defs[sig_def].name);
    ready = n_fn.tag == .function or sig_fn.tag == .function;
    ready_generation = generation;
    ready_realm = js.vm.realmGeneration();
    return ready;
}

pub fn transformN(input: []const u8, out: []u8) usize {
    if (!isNReady()) return 0;
    return invoke(n_fn, n_arg0, n_arg1, input, out, true);
}
pub fn transformSignature(input: []const u8, out: []u8) usize {
    if (!isSignatureReady()) return 0;
    return invoke(sig_fn, sig_arg0, sig_arg1, input, out, false);
}
fn invoke(fn_value: Value, a0: u32, a1: u32, input: []const u8, out: []u8, reject_failure: bool) usize {
    last_failure = .none;
    const args = [_]Value{ Value.number(@floatFromInt(a0)), Value.number(@floatFromInt(a1)), Value.string(js.values.internString(input)) };
    const value = js.vm.callExportedN(fn_value, Value.UNDEFINED, &args);
    if (js.vm.hasError()) { ready = false; last_failure = .runtime; return 0; }
    if (value.tag != .string) { last_failure = .result; return 0; }
    const result = js.values.getString(value.data.str_idx);
    if (result.len > out.len) { last_failure = .capacity; return 0; }
    if (reject_failure and failure_index != NONE) {
        const table = js.vm.getGlobalVar(table_name);
        if (table.tag == .object or table.tag == .array) {
            const prefix = js.objects.getArrayElement(table.data.obj_idx, failure_index);
            if (prefix.tag == .string and startsWith(result, js.values.getString(prefix.data.str_idx))) return failLength(.result);
        }
    }
    @memcpy(out[0..result.len], result);
    return result.len;
}
fn fail(f: Failure) bool { last_failure = f; return false; }
fn failLength(f: Failure) usize { last_failure = f; return 0; }

fn findTable(player: []const u8) bool {
    table_name = ""; table_value = ""; table_count = 0;
    var pos: usize = 0;
    while (findFrom(player, ".split(\";\")", pos)) |at| {
        pos = at + 1;
        if (at == 0 or (player[at - 1] != '\'' and player[at - 1] != '"')) continue;
        const quote = player[at - 1];
        var start = at - 1;
        while (start > 0) {
            start -= 1;
            if (player[start] == quote and !escaped(player, start)) break;
        }
        if (player[start] != quote or at - start > 8192) continue;
        var eq = start;
        while (eq > 0 and isSpace(player[eq - 1])) eq -= 1;
        if (eq == 0 or player[eq - 1] != '=') continue;
        const name = nameBefore(player, eq - 1);
        if (name.len == 0) continue;
        const text = player[start + 1 .. at - 1];
        if (find(text, ";join;") == null or find(text, ";undefined;") == null or find(text, ";n;") == null) continue;
        table_name = name; table_value = player[start .. at + 11];
        var from: usize = 0;
        for (text, 0..) |c, j| {
            if (c != ';') continue;
            if (table_count == table_items.len) return false;
            table_items[table_count] = text[from..j]; table_count += 1; from = j + 1;
        }
        if (table_count == table_items.len) return false;
        table_items[table_count] = text[from..]; table_count += 1;
        return true;
    }
    return false;
}
fn tableIndex(value: []const u8) ?u16 {
    for (table_items[0..table_count], 0..) |item, i| if (equal(item, value)) return @intCast(i);
    return null;
}
fn refersToTable(body: []const u8) bool {
    var pos: usize = 0;
    while (findFrom(body, table_name, pos)) |at| {
        pos = at + table_name.len;
        if (at > 0 and (isIdent(body[at - 1]) or body[at - 1] == '.')) continue;
        if (pos < body.len and body[pos] == '[') return true;
    }
    return false;
}
fn makeCallMarker(out: []u8, method: u16, empty: u16) ?[]const u8 {
    var n: usize = 0;
    if (!put(out, &n, "[") or !put(out, &n, table_name) or !put(out, &n, "[") or !putNumber(out, &n, method) or !put(out, &n, "]](") or !put(out, &n, table_name) or !put(out, &n, "[") or !putNumber(out, &n, empty) or !put(out, &n, "])")) return null;
    return out[0..n];
}
fn extractNArguments(body: []const u8, split_marker: []const u8, join_index: u16, empty_index: u16) bool {
    const split_at = find(body, split_marker) orelse return false;
    const nt = js.lexer.tokenize(body);
    var split_token: usize = 0;
    while (split_token < nt and js.lexer.getToken(split_token).start < split_at) : (split_token += 1) {}
    var i = split_token;
    var found_first = false;
    while (i > 1) {
        i -= 1;
        if (js.lexer.getToken(i).tt != .bit_or or js.lexer.getToken(i + 1).tt != .number) continue;
        if (js.lexer.getToken(i - 1).tt != .identifier) continue;
        n_arg0 = numberToken(i + 1) orelse continue;
        found_first = true; break;
    }
    if (!found_first) return false;
    var xor_base: u32 = 0;
    if (!hasIndexedJoin(body, join_index, empty_index, &xor_base)) return false;
    n_arg1 = xor_base ^ n_arg0;
    // Catch sentinel: table[xor ^ number] + original input.
    _ = js.lexer.tokenize(body);
    i = 0;
    while (i + 5 < nt) : (i += 1) {
        if (!tokenName(i, table_name) or js.lexer.getToken(i + 1).tt != .lbracket or js.lexer.getToken(i + 3).tt != .bit_xor or js.lexer.getToken(i + 4).tt != .number) continue;
        if (i + 7 < nt and js.lexer.getToken(i + 5).tt == .rbracket and js.lexer.getToken(i + 6).tt == .plus) {
            const mask = numberToken(i + 4) orelse continue;
            const index = xor_base ^ mask;
            if (index < table_count) failure_index = @intCast(index);
        }
    }
    return true;
}
fn hasIndexedJoin(body: []const u8, join_index: u16, empty_index: u16, xor_out: ?*u32) bool {
    const nt = js.lexer.tokenize(body);
    var i: usize = 0;
    while (i + 11 < nt) : (i += 1) {
        if (!tokenName(i, table_name) or js.lexer.getToken(i + 1).tt != .lbracket) continue;
        var close = i + 3;
        var base: u32 = 0;
        if (js.lexer.getToken(i + 2).tt == .number) {
            if ((numberToken(i + 2) orelse continue) != join_index) continue;
        } else if (js.lexer.getToken(i + 2).tt == .identifier and js.lexer.getToken(i + 3).tt == .bit_xor and js.lexer.getToken(i + 4).tt == .number) {
            base = (numberToken(i + 4) orelse continue) ^ join_index; close = i + 5;
        } else continue;
        if (js.lexer.getToken(close).tt != .rbracket or js.lexer.getToken(close + 1).tt != .rbracket or js.lexer.getToken(close + 2).tt != .lparen or !tokenName(close + 3, table_name) or js.lexer.getToken(close + 4).tt != .lbracket or js.lexer.getToken(close + 5).tt != .number or (numberToken(close + 5) orelse continue) != empty_index) continue;
        if (xor_out) |out| out.* = base;
        return true;
    }
    return false;
}
fn appendTypeofGuard(player: []const u8, body: []const u8) bool {
    const nt = js.lexer.tokenize(body);
    var i: usize = 0;
    while (i + 1 < nt) : (i += 1) {
        if (js.lexer.getToken(i).tt != .kw_typeof or js.lexer.getToken(i + 1).tt != .identifier) continue;
        const name = js.lexer.tokenText(js.lexer.getToken(i + 1));
        if (appendOriginalGlobal(player, name, false)) return true;
    }
    return false;
}
fn appendHelperObjects(player: []const u8, body: []const u8) bool {
    const nt = js.lexer.tokenize(body);
    var names: [16][]const u8 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i + 2 < nt) : (i += 1) {
        if (js.lexer.getToken(i).tt != .identifier or js.lexer.getToken(i + 1).tt != .lbracket or !tokenName(i + 2, table_name)) continue;
        const name = js.lexer.tokenText(js.lexer.getToken(i));
        if (equal(name, table_name)) continue;
        if (count == names.len) return false;
        names[count] = name; count += 1;
    }
    // Token text points into the original stable source, not a token buffer.
    var found = false;
    for (names[0..count]) |name| if (appendOriginalGlobal(player, name, true)) { found = true; };
    return found;
}
fn appendOriginalGlobal(player: []const u8, name: []const u8, object: bool) bool {
    var marker: [128]u8 = undefined;
    var m: usize = 0;
    if (!put(&marker, &m, name) or !put(&marker, &m, "=")) return false;
    var pos: usize = 0;
    while (findFrom(player, marker[0..m], pos)) |at| {
        pos = at + m;
        if (at > 0 and (isIdent(player[at - 1]) or player[at - 1] == '.')) continue;
        const value_start = at + m;
        if (value_start >= player.len) continue;
        var end = value_start;
        if (object) {
            if (player[value_start] != '{') continue;
            const len = balancedValueLength(player[value_start..@min(player.len, value_start + MAX_FUNCTION_BYTES)]);
            if (len == 0) return false;
            end += len;
            if (!refersToTable(player[value_start..end]) or find(player[value_start..end], "function(") == null) continue;
        } else {
            // typeof guard declarations are primitive literals.
            if (player[value_start] < '0' or player[value_start] > '9') continue;
            while (end < player.len and ((player[end] >= '0' and player[end] <= '9') or player[end] == '.')) : (end += 1) {}
            if (end == value_start) continue;
        }
        return append("var ") and append(name) and append("=") and append(player[value_start..end]) and append(";\n");
    }
    return false;
}
fn extractCallArguments(player: []const u8, name: []const u8, arg0: *u32, arg1: *u32) bool {
    var marker: [128]u8 = undefined; var m: usize = 0;
    if (!put(&marker, &m, name) or !put(&marker, &m, "(")) return false;
    var pos: usize = 0;
    while (findFrom(player, marker[0..m], pos)) |at| {
        pos = at + m;
        if (at > 0 and isIdent(player[at - 1])) continue;
        var p = pos;
        const a = parseNumber(player, &p) orelse continue;
        if (p >= player.len or player[p] != ',') continue; p += 1;
        const b = parseNumber(player, &p) orelse continue;
        if (p >= player.len or player[p] != ',') continue;
        arg0.* = a; arg1.* = b; return true;
    }
    return false;
}
fn callsNamed(body: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (findFrom(body, name, pos)) |at| {
        pos = at + name.len;
        if (at > 0 and isIdent(body[at - 1])) continue;
        if (pos < body.len and body[pos] == '(') return true;
    }
    return false;
}
fn parameterNamed(body: []const u8, name: []const u8) bool {
    const end = find(body, ")") orelse return false;
    const nt = js.lexer.tokenize(body[0 .. end + 1]);
    var i: usize = 2;
    while (i < nt and js.lexer.getToken(i).tt != .rparen) : (i += 1) {
        if (tokenName(i, name)) return true;
    }
    return false;
}
fn balancedValueLength(value: []const u8) usize {
    const nt = js.lexer.tokenize(value);
    var depth: usize = 0; var begun = false;
    for (0..nt) |i| {
        const t = js.lexer.getToken(i);
        if (t.tt == .lbrace) { depth += 1; begun = true; }
        if (t.tt == .rbrace and begun) {
            if (depth == 0) return 0;
            depth -= 1;
            if (depth == 0) return @as(usize, t.start) + t.len;
        }
    }
    return 0;
}
fn numberToken(i: usize) ?u32 {
    const text = js.lexer.tokenText(js.lexer.getToken(i));
    var p: usize = 0;
    const value = parseNumber(text, &p) orelse return null;
    return if (p == text.len) value else null;
}
fn tokenName(i: usize, name: []const u8) bool { return js.lexer.getToken(i).tt == .identifier and equal(js.lexer.tokenText(js.lexer.getToken(i)), name); }
fn nameBefore(data: []const u8, at: usize) []const u8 {
    var end = at;
    while (end > 0 and isSpace(data[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and isIdent(data[start - 1])) start -= 1;
    if (start == end or (start > 0 and (data[start - 1] == '.' or data[start - 1] == ']'))) return "";
    return data[start..end];
}
fn append(text: []const u8) bool { return put(&source_buf, &source_len, text); }
fn put(out: []u8, n: *usize, text: []const u8) bool {
    if (text.len > out.len - n.*) return false;
    @memcpy(out[n.* .. n.* + text.len], text); n.* += text.len; return true;
}
fn putNumber(out: []u8, n: *usize, value: u32) bool {
    var digits: [10]u8 = undefined; var len: usize = 0; var v = value;
    while (true) { digits[len] = @intCast(v % 10 + '0'); len += 1; v /= 10; if (v == 0) break; }
    while (len > 0) { len -= 1; if (!put(out, n, digits[len .. len + 1])) return false; }
    return true;
}
fn parseNumber(data: []const u8, p: *usize) ?u32 {
    while (p.* < data.len and isSpace(data[p.*])) p.* += 1;
    const start = p.*; var n: u32 = 0;
    while (p.* < data.len and data[p.*] >= '0' and data[p.*] <= '9') : (p.* += 1) {
        const digit: u32 = data[p.*] - '0';
        if (n > (0xffffffff - digit) / 10) return null;
        n = n * 10 + digit;
    }
    return if (p.* == start) null else n;
}
fn isIdent(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$'; }
fn isSpace(c: u8) bool { return c == ' ' or c == '\r' or c == '\n' or c == '\t'; }
fn escaped(data: []const u8, at: usize) bool { var p = at; var n: usize = 0; while (p > 0 and data[p - 1] == '\\') { p -= 1; n += 1; } return n % 2 == 1; }
fn equal(a: []const u8, b: []const u8) bool { if (a.len != b.len) return false; for (a, b) |x, y| if (x != y) return false; return true; }
fn startsWith(a: []const u8, b: []const u8) bool { return b.len != 0 and a.len >= b.len and equal(a[0..b.len], b); }
fn find(data: []const u8, needle: []const u8) ?usize { return findFrom(data, needle, 0); }
fn findFrom(data: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0 or start > data.len or needle.len > data.len - start) return null;
    var i = start;
    while (i <= data.len - needle.len) : (i += 1) { if (equal(data[i .. i + needle.len], needle)) return i; }
    return null;
}
