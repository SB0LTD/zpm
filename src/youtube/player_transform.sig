// @zpm/youtube/player_transform — bounded extraction and Sig execution of
// the original player's indexed string-table transforms. No external runtime.
//
// The VM is shared with BotGuard. Prepare transforms after copying a minted
// token out of that VM; preparing a new player deliberately replaces its realm.
const js = @import("botguard/jsvm/root.sig");
const Value = js.values.Value;
const MAX_FUNCTIONS = 16384;
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
var n_split_at: usize = 0;
var n_xor_base: u32 = 0;
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
pub var failure_detail: []const u8 = "";
var dependency_failure: [256]u8 = undefined;

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
    last_failure = .none; failure_detail = ""; source_len = 0; def_count = 0;
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
        var split_at: usize = 0;
        var split_base: u32 = 0;
        if (selected and hasIndexedMethod(body, split_index, empty_index, &split_base, &split_at)) {
            if (find(body, "typeof ") != null and find(body, "try{") != null) {
                if (n_def != NONE) return fail(.entry);
                n_def = @intCast(def_count);
                n_split_at = split_at;
                n_xor_base = split_base;
            } else if (find(body, "return") != null and find(body, "join") == null) {
                // Signature code also indexes join through the table.
                // Require a method call followed by the table's empty string.
                if (hasIndexedJoin(body, join_index, empty_index, null)) sig_def = @intCast(def_count);
            }
        }
        def_count += 1;
    }
    if (n_def == NONE and sig_def == NONE) return fail(.entry);
    if (n_def != NONE) defs[n_def].selected = true;
    if (n_def != NONE and !extractNArguments(defs[n_def].source, marker, join_index, empty_index) and !extractSelectorArguments(defs[n_def].source, n_split_at, n_xor_base, &n_arg0, &n_arg1)) return fail(.arguments);
    if (n_def != NONE) extractFailureIndex(defs[n_def].source, n_arg0 ^ n_arg1);
    if (sig_def != NONE) {
        var signature_base: u32 = 0;
        var signature_split: usize = 0;
        if (!hasIndexedJoin(defs[sig_def].source, join_index, empty_index, &signature_base)) sig_def = NONE
        else if (!extractCallArguments(player, defs[sig_def].name, &sig_arg0, &sig_arg1, if (signature_base == 0) null else signature_base)) {
            var split_base: u32 = 0;
            if (!hasIndexedMethod(defs[sig_def].source, split_index, empty_index, &split_base, &signature_split) or split_base != signature_base or !extractSelectorArguments(defs[sig_def].source, signature_split, signature_base, &sig_arg0, &sig_arg1)) sig_def = NONE;
        }
    }
    if (sig_def != NONE) defs[sig_def].selected = true;

    // Helpers can be passed as array values and can reference more helpers.
    // Resolve that closure with a fixed hash table, not an all-pairs scan.
    if (!selectDependencies()) return fail(if (last_failure == .none) .capacity else last_failure);
    if (!append("var ") or !append(table_name) or !append("=") or !append(table_value) or !append(";\n")) return fail(.capacity);
    var i: usize = 0;
    while (i < def_count) : (i += 1) {
        if (!defs[i].selected) continue;
        if (!append("var ") or !append(defs[i].name) or !append("=") or !append(defs[i].source) or !append(";\n")) return fail(.capacity);
    }
    // Preserve the entry's typeof guard value and signature helper object.
    // These are original player declarations, not substitute implementations.
    if (n_def != NONE and !appendTypeofGuard(player, defs[n_def].source)) { failure_detail = "typeof guard"; return fail(.entry); }
    if (sig_def != NONE and !appendHelperObjects(player, defs[sig_def].source)) { failure_detail = defs[sig_def].name; return fail(.entry); }

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
    while (findFrom(player, ".split(", pos)) |at| {
        pos = at + 1;
        // Player profiles choose their own table delimiter. Recognize a
        // quoted one-byte separator rather than assuming a semicolon.
        var split_end = at + 7;
        while (split_end < player.len and isSpace(player[split_end])) split_end += 1;
        if (split_end + 3 >= player.len or (player[split_end] != '"' and player[split_end] != '\'')) continue;
        const separator = player[split_end+1];
        if (separator == '\\' or separator == player[split_end] or player[split_end+2] != player[split_end]) continue;
        split_end += 3;
        while (split_end < player.len and isSpace(player[split_end])) split_end += 1;
        if (split_end >= player.len or player[split_end] != ')') continue;
        split_end += 1;
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
        table_name = name; table_value = player[start .. split_end];
        table_count = 0;
        var from: usize = 0;
        var overflow = false;
        for (text, 0..) |c, j| {
            if (c != separator) continue;
            if (table_count == table_items.len) { overflow = true; break; }
            table_items[table_count] = text[from..j]; table_count += 1; from = j + 1;
        }
        if (overflow or table_count == table_items.len) continue;
        table_items[table_count] = text[from..]; table_count += 1;
        if (tableIndex("join") == null or tableIndex("undefined") == null or tableIndex("n") == null or tableIndex("split") == null) continue;
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
    return true;
}
fn extractFailureIndex(body: []const u8, xor_base: u32) void {
    // Catch sentinel: table[xor ^ number] + original input.
    const nt = js.lexer.tokenize(body);
    var i: usize = 0;
    while (i + 5 < nt) : (i += 1) {
        if (!tokenName(i, table_name) or js.lexer.getToken(i + 1).tt != .lbracket or js.lexer.getToken(i + 3).tt != .bit_xor or js.lexer.getToken(i + 4).tt != .number) continue;
        if (i + 7 < nt and js.lexer.getToken(i + 5).tt == .rbracket and js.lexer.getToken(i + 6).tt == .plus) {
            const mask = numberToken(i + 4) orelse continue;
            const index = xor_base ^ mask;
            if (index < table_count) failure_index = @intCast(index);
        }
    }
}
fn hasIndexedJoin(body: []const u8, join_index: u16, empty_index: u16, xor_out: ?*u32) bool {
    return hasIndexedMethod(body, join_index, empty_index, xor_out, null);
}
// Dispatcher selectors are encoded in the player's own branch predicates.
// Evaluate only constant arithmetic on the first parameter; never execute a
// candidate transform or guess a fingerprint/guard value. Other guarded arms
// must be provably inactive. Unsupported predicates fail extraction explicitly.
fn extractSelectorArguments(body: []const u8, split_at: usize, xor_base: u32, arg0: *u32, arg1: *u32) bool {
    const nt = js.lexer.tokenize(body);
    var braces: usize = 0;
    var ordinal: usize = 0;
    var wanted: ?usize = null;
    for (0..nt) |i| {
        const token = js.lexer.getToken(i);
        if (token.start >= split_at) break;
        if (token.tt == .lbrace) braces += 1;
        if (token.tt == .rbrace and braces > 0) braces -= 1;
        if (braces == 1 and token.tt == .kw_if) { wanted = ordinal; ordinal += 1; }
    }
    const wanted_if = wanted orelse return false;
    const root = js.parser.parse(nt);
    if (root == js.parser.NULL_NODE or js.parser.hasError()) return false;
    const program = js.parser.getNode(root);
    const top = js.parser.getList(program.left, program.right);
    if (top.len != 1) return false;
    const function = js.parser.getNode(top[0]);
    if (function.tag != .func_decl or function.op == 0) return false;
    const params = js.parser.getList(function.extra, function.op);
    const parameter = js.parser.getNode(params[0]);
    if (parameter.tag != .identifier) return false;
    const name = js.lexer.tokenText(js.lexer.getToken(parameter.token_idx));
    const block = js.parser.getNode(function.right);
    const statements = js.parser.getList(block.left, block.right);
    for (0..256) |candidate| {
        var if_index: usize = 0;
        var found = false;
        var valid = true;
        for (statements) |index| {
            const statement = js.parser.getNode(index);
            if (statement.tag == .if_stmt) {
                const result = selectorValue(statement.left, name, @floatFromInt(candidate), 0) orelse { valid = false; break; };
                const desired = if_index == wanted_if;
                if ((result != 0) != desired) { valid = false; break; }
                if (desired) found = true;
                if_index += 1;
            } else if (statement.tag == .expr_stmt) {
                const expression = js.parser.getNode(statement.left);
                if (expression.tag != .logical_expr) continue;
                const result = selectorValue(expression.left, name, @floatFromInt(candidate), 0) orelse { valid = false; break; };
                const op: js.lexer.TokenType = @enumFromInt(expression.op);
                if ((op == .logical_and and result != 0) or (op == .logical_or and result == 0) or (op != .logical_and and op != .logical_or)) { valid = false; break; }
            }
        }
        if (valid and found) { arg0.* = @intCast(candidate); arg1.* = arg0.* ^ xor_base; return true; }
    }
    return false;
}
fn selectorInt(number: f64) i32 {
    if (number != number or number == 0) return 0;
    return @bitCast(@as(u32, @intFromFloat(@mod(@trunc(number), 4294967296.0))));
}
fn selectorValue(index: js.parser.NodeIdx, name: []const u8, candidate: f64, depth: usize) ?f64 {
    if (depth >= 32 or index == js.parser.NULL_NODE) return null;
    const node = js.parser.getNode(index);
    if (node.tag == .literal_num) return @floatFromInt(numberToken(node.token_idx) orelse return null);
    if (node.tag == .literal_bool) return if (js.lexer.getToken(node.token_idx).tt == .true_lit) 1 else 0;
    if (node.tag == .identifier) return if (tokenName(node.token_idx, name)) candidate else null;
    const op: js.lexer.TokenType = @enumFromInt(node.op);
    if (node.tag == .unary_expr) {
        const value = selectorValue(node.left, name, candidate, depth + 1) orelse return null;
        return switch (op) { .minus => -value, .plus => value, .not => if (value == 0) 1 else 0, .bit_not => @floatFromInt(~selectorInt(value)), else => null };
    }
    if (node.tag != .binary_expr and node.tag != .logical_expr) return null;
    const left = selectorValue(node.left, name, candidate, depth + 1) orelse return null;
    if (op == .logical_and and left == 0) return 0;
    if (op == .logical_or and left != 0) return left;
    const right = selectorValue(node.right, name, candidate, depth + 1) orelse return null;
    return switch (op) {
        .plus => left + right, .minus => left - right, .star => left * right,
        .bit_and => @floatFromInt(selectorInt(left) & selectorInt(right)),
        .bit_or => @floatFromInt(selectorInt(left) | selectorInt(right)),
        .bit_xor => @floatFromInt(selectorInt(left) ^ selectorInt(right)),
        .lshift => @floatFromInt(selectorInt(left) << @as(u5, @truncate(@as(u32, @bitCast(selectorInt(right)))))),
        .rshift => @floatFromInt(selectorInt(left) >> @as(u5, @truncate(@as(u32, @bitCast(selectorInt(right)))))),
        .urshift => @floatFromInt(@as(u32, @bitCast(selectorInt(left))) >> @as(u5, @truncate(@as(u32, @bitCast(selectorInt(right)))))),
        .eq, .strict_eq => if (left == right) 1 else 0,
        .neq, .strict_neq => if (left != right) 1 else 0,
        .lt => if (left < right) 1 else 0, .gt => if (left > right) 1 else 0,
        .lte => if (left <= right) 1 else 0, .gte => if (left >= right) 1 else 0,
        .logical_and, .logical_or => right,
        else => null,
    };
}
var def_slots: [32768]u16 = undefined;
var def_queue: [MAX_FUNCTIONS]u16 = undefined;
var local_defs: [MAX_FUNCTIONS]bool = undefined;
var property_key_tokens: [js.lexer.MAX_TOKENS]bool = undefined;
fn nameHash(name: []const u8) usize { var hash: u32 = 2166136261; for (name) |c| hash = (hash ^ c) *% 16777619; return hash & (def_slots.len - 1); }
fn lookupDef(name: []const u8) ?u16 {
    var slot = nameHash(name);
    while (def_slots[slot] != NONE) : (slot = (slot + 1) & (def_slots.len - 1)) {
        const index = def_slots[slot];
        if (equal(defs[index].name, name)) return index;
    }
    return null;
}
fn markBinding(index: js.parser.NodeIdx, depth: usize) void {
    if (index == js.parser.NULL_NODE or depth >= 32) return;
    const node = js.parser.getNode(index);
    if (node.tag == .identifier) {
        if (lookupDef(js.lexer.tokenText(js.lexer.getToken(node.token_idx)))) |def| local_defs[def] = true;
    } else if (node.tag == .assign_expr or node.tag == .spread_expr) markBinding(node.left, depth + 1)
    else if (node.tag == .array_expr or node.tag == .object_expr) {
        for (js.parser.getList(node.left, node.right)) |child| markBinding(child, depth + 1);
    } else if (node.tag == .property) markBinding(node.right, depth + 1);
}
fn selectDependencies() bool {
    @memset(&def_slots, NONE);
    var dependency_queued: [MAX_FUNCTIONS]bool = @splat(false);
    var dependency_parent: [MAX_FUNCTIONS]u16 = @splat(NONE);
    var queued: usize = 0;
    for (defs[0..def_count], 0..) |def, index| {
        var slot = nameHash(def.name);
        while (def_slots[slot] != NONE and !equal(defs[def_slots[slot]].name, def.name)) slot = (slot + 1) & (def_slots.len - 1);
        def_slots[slot] = @intCast(index);
        if (index == n_def) { def_queue[queued] = @intCast(index); queued += 1; dependency_queued[index] = true; }
    }
    var head: usize = 0;
    while (head < queued) : (head += 1) {
        const definition = def_queue[head];
        const body = defs[definition].source;
        const nt = js.lexer.tokenize(body);
        // Keep the original table-using dispatchers, but resolve external
        // helpers only in the selected n arm. Unrelated URL/network arms have
        // a large application dependency graph and are never invoked here.
        var arm_end = body.len;
        if (definition == n_def) {
            var depth: usize = 0;
            var arm_depth: usize = 0;
            for (0..nt) |t| {
                const token = js.lexer.getToken(t);
                if (token.tt == .lbrace) depth += 1;
                if (token.start <= n_split_at) arm_depth = depth;
                if (token.tt == .rbrace) {
                    if (token.start > n_split_at and depth == arm_depth) { arm_end = token.start; break; }
                    if (depth > 0) depth -= 1;
                }
            }
        }
        _ = js.parser.parse(nt);
        if (js.parser.hasError()) {
            var at: usize = 0;
            var current = definition;
            while (current != NONE and at < dependency_failure.len) {
                if (at > 0 and !put(&dependency_failure, &at, " <- ")) break;
                if (!put(&dependency_failure, &at, defs[current].name)) break;
                current = dependency_parent[current];
            }
            failure_detail = dependency_failure[0..at]; last_failure = .syntax; return false;
        }
        @memset(local_defs[0..def_count], false);
        @memset(property_key_tokens[0..nt], false);
        for (0..js.parser.nodeCount()) |i| {
            const node = js.parser.getNode(@intCast(i));
            if (node.tag == .property and !node.flags.is_computed and node.left != node.right) {
                const key = js.parser.getNode(node.left);
                if (key.tag == .identifier) property_key_tokens[key.token_idx] = true;
            }
            if (node.tag == .var_decl) {
                const bindings = js.parser.getList(node.left, node.right);
                var b: usize = 0;
                while (b < bindings.len) : (b += 2) markBinding(bindings[b], 0);
            } else if (node.tag == .func_expr or node.tag == .func_decl) {
                markBinding(node.left, 0);
                for (js.parser.getList(node.extra, node.op)) |param| markBinding(param, 0);
            } else if (node.tag == .try_stmt) {
                const catch_finally = js.parser.getList(node.extra, 2);
                if (catch_finally.len == 2) markBinding(catch_finally[0], 0);
            }
        }
        for (0..js.parser.nodeCount()) |i| {
            const node = js.parser.getNode(@intCast(i));
            if (node.tag != .identifier) continue;
            const token = js.lexer.getToken(node.token_idx);
            if (property_key_tokens[node.token_idx]) continue;
            if (definition == n_def and (token.start < n_split_at or token.start >= arm_end)) continue;
            if (node.token_idx > 0 and js.lexer.getToken(node.token_idx - 1).tt == .dot) continue;
            const name = js.lexer.tokenText(js.lexer.getToken(node.token_idx));
            const index = lookupDef(name) orelse continue;
            // A table-using dispatcher may already be emitted, but its own
            // dependencies still need traversal when the selected arm uses it.
            if (local_defs[index] or dependency_queued[index]) continue;
            defs[index].selected = true;
            if (queued == def_queue.len) return false;
            def_queue[queued] = index; queued += 1;
            dependency_queued[index] = true;
            dependency_parent[index] = definition;
        }
    }
    return true;
}
const Index = struct { close: usize, base: ?u32, variable: []const u8 };
fn indexedString(at: usize, expected: u16, nt: usize) ?Index {
    if (at + 3 >= nt or !tokenName(at, table_name) or js.lexer.getToken(at + 1).tt != .lbracket) return null;
    if (js.lexer.getToken(at + 2).tt == .number and js.lexer.getToken(at + 3).tt == .rbracket) {
        if ((numberToken(at + 2) orelse return null) != expected) return null;
        return .{ .close = at + 3, .base = null, .variable = "" };
    }
    if (at + 5 >= nt or js.lexer.getToken(at + 2).tt != .identifier or js.lexer.getToken(at + 3).tt != .bit_xor or js.lexer.getToken(at + 4).tt != .number or js.lexer.getToken(at + 5).tt != .rbracket) return null;
    return .{ .close = at + 5, .base = (numberToken(at + 4) orelse return null) ^ expected, .variable = js.lexer.tokenText(js.lexer.getToken(at + 2)) };
}
fn hasIndexedMethod(body: []const u8, method_index: u16, empty_index: u16, xor_out: ?*u32, position_out: ?*usize) bool {
    const nt = js.lexer.tokenize(body);
    var i: usize = 0;
    while (i + 8 < nt) : (i += 1) {
        const method = indexedString(i, method_index, nt) orelse continue;
        const close = method.close;
        if (close + 3 >= nt or js.lexer.getToken(close + 1).tt != .rbracket or js.lexer.getToken(close + 2).tt != .lparen) continue;
        const argument = indexedString(close + 3, empty_index, nt) orelse continue;
        if (argument.close + 1 >= nt or js.lexer.getToken(argument.close + 1).tt != .rparen) continue;
        if (method.base != null and argument.base != null and (method.base.? != argument.base.? or !equal(method.variable, argument.variable))) continue;
        if (xor_out) |out| out.* = method.base orelse argument.base orelse 0;
        if (position_out) |out| out.* = js.lexer.getToken(i).start;
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
        var duplicate = false;
        for (names[0..count]) |previous| { if (equal(previous, name)) { duplicate = true; break; } }
        if (duplicate) continue;
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
            // Helper object keys may be literal names while the dispatcher
            // indexes them through its string table. Preserve either form.
            if (find(player[value_start..end], "function(") == null) continue;
        } else {
            // typeof guard declarations are primitive literals.
            if (player[end] == '-' or player[end] == '+') end += 1;
            if (end >= player.len or player[end] < '0' or player[end] > '9') continue;
            while (end < player.len and ((player[end] >= '0' and player[end] <= '9') or player[end] == '.')) : (end += 1) {}
            if (end == value_start) continue;
        }
        return append("var ") and append(name) and append("=") and append(player[value_start..end]) and append(";\n");
    }
    return false;
}
fn extractCallArguments(player: []const u8, name: []const u8, arg0: *u32, arg1: *u32, xor_base: ?u32) bool {
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
        if (xor_base) |base| { if ((a ^ b) != base) continue; }
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
    // A function's parameter defaults can contain object literals/functions.
    // Its body starts only after the outer parameter list has closed.
    var parameters_done = nt == 0 or js.lexer.getToken(0).tt != .kw_function;
    var parentheses: usize = 0;
    for (0..nt) |i| {
        const t = js.lexer.getToken(i);
        if (!parameters_done) {
            if (t.tt == .lparen) parentheses += 1;
            if (t.tt == .rparen and parentheses > 0) { parentheses -= 1; if (parentheses == 0) parameters_done = true; }
            continue;
        }
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
