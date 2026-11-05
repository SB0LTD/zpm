//! SQL/JSON path language (Layer 0, B11 json-agg lane), after PostgreSQL's
//! jsonpath_scan.l / jsonpath_gram.y (parsing), jsonpath.c (canonical
//! output) and jsonpath_exec.c (evaluation over JSONB).
//!
//! A jsonpath value is kept as its canonical text (jsonpath_out of the
//! parsed path) in a text cell; evaluation parses it again into a bounded
//! node pool (Config.jsonpath_nodes; more is StatementTooComplex, 54001).
//! Input errors are 42601 (Syntax), as PostgreSQL's jsonpath_in reports.
//!
//! Language: lax (default) and strict modes; `$`, `@` (filters only),
//! `$name` variables, `last` (array subscripts only), string / numeric /
//! true / false / null literals; accessors `.key`, `."key"`, `.*`, `[*]`,
//! `[i, j to k]`, `.**{m to n}`, `?(predicate)` and the item methods
//! type(), size(), double(), ceiling(), floor(), abs(), number(),
//! string(), boolean(), integer(), bigint() and decimal(p, s); arithmetic
//! + - * / % and unary +/-; predicates == != <> < <= > >=, && || !,
//! exists(), (...) is unknown and starts with. keyvalue(), the datetime
//! methods and like_regex parse and print but evaluate to 0A000.
//!
//! Evaluation streams items depth-first into a sink, as jsonpath_exec.c
//! does with its found lists: lax mode unwraps arrays for member
//! accessors, filters, methods and operands, wraps scalars for array
//! accessors and ignores structural errors; strict mode raises them
//! (22039, 2203A, 2203C, 22033). Predicate operands and computed values
//! use a bounded item stack (Config.jsonpath_items, ProgramLimitExceeded
//! 54000) and one scratch JSONB buffer (text_bytes, TextCapacity 54000),
//! both released in stack order. Recursion follows the parsed path and the
//! document's nesting (both bounded) and polls the execution control at
//! every step.
const types = @import("types.sig");
const numeric = @import("numeric.sig");
const jsonb = @import("jsonb.sig");
const value_module = @import("value.sig");
const float_text = @import("float_text.sig");
const expr_module = @import("expr.sig");
const Error = types.Error;

pub const none: u16 = 0xffff;
/// `last` as an .** bound.
pub const last_level: u32 = 0xffffffff;
/// Parser nesting limit (parentheses, operators); deeper is 54001.
pub const max_depth: usize = 64;

pub const Kind = enum(u8) { root, current, last, variable, null_value, true_value, false_value, number, string,
    key, any_key, any_array, index_array, subscript, any, filter, method,
    add, sub, mul, div, mod, plus, minus,
    eq, ne, lt, le, gt, ge, and_op, or_op, not_op, is_unknown, exists, starts_with, like_regex };

pub const Method = enum(u8) { type, size, double, ceiling, floor, abs, keyvalue, bigint, boolean, date, decimal, integer, number, string, time, time_tz, timestamp, timestamp_tz, datetime };

const method_names = [_][]const u8{ "type", "size", "double", "ceiling", "floor", "abs", "keyvalue", "bigint", "boolean", "date", "decimal", "integer", "number", "string", "time", "time_tz", "timestamp", "timestamp_tz", "datetime" };

/// One parsed path item. `next` chains accessors; `a`/`b` are operands
/// (subscript: from/to; method: decimal/time arguments); `sibling` links
/// subscripts; `data`/`len` locate literal bytes (decoded strings, keys,
/// variable names, number text, regex pattern) in Path.data.
pub const Node = struct {
    kind: Kind = .root,
    method: Method = .type,
    next: u16 = none,
    a: u16 = none,
    b: u16 = none,
    sibling: u16 = none,
    data: u32 = 0,
    len: u32 = 0,
    /// like_regex flags (bits i s m x q); .** bounds.
    flags: u8 = 0,
    first: u32 = 0,
    last: u32 = 0,
};

fn predicateKind(kind: Kind) bool {
    return switch (kind) {
        .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op, .not_op, .is_unknown, .exists, .starts_with, .like_regex => true,
        else => false,
    };
}

/// jsonpath.c operationPriority.
fn priority(kind: Kind) u8 {
    return switch (kind) {
        .or_op => 0,
        .and_op => 1,
        .eq, .ne, .lt, .gt, .le, .ge, .starts_with => 2,
        .add, .sub => 3,
        .mul, .div, .mod => 4,
        .plus, .minus => 5,
        else => 6,
    };
}

fn operatorName(kind: Kind) []const u8 {
    return switch (kind) {
        .and_op => "&&",
        .or_op => "||",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .gt => ">",
        .le => "<=",
        .ge => ">=",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .starts_with => "starts with",
        else => "",
    };
}

// ---- lexer ------------------------------------------------------------------

const Tok = enum { end, dollar, variable, at, dot, star, any, lbracket, rbracket, lparen, rparen, lbrace, rbrace, comma, question, plus, minus, slash, percent, eq, ne, lt, le, gt, ge, and_op, or_op, not_op, string, number, ident };

const Token = struct { tok: Tok = .end, start: usize = 0, end: usize = 0 };

fn special(c: u8) bool {
    return switch (c) {
        '?', '%', '$', '.', '[', ']', '{', '}', '(', ')', '|', '&', '!', '=', '<', '>', '@', '#', ',', '*', ':', '-', '+', '/', '\\', '"', ' ', '\t', '\n', '\r', 0x0c => true,
        else => false,
    };
}

fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn hexValue(c: u8) ?u21 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Case-insensitive keyword match (true/false/null must be lower case).
fn keyword(text: []const u8, word: []const u8) bool {
    if (text.len != word.len) return false;
    for (text, word) |a, b| if (lower(a) != b) return false;
    return true;
}

pub fn Path(comptime node_capacity: usize, comptime data_capacity: usize) type {
    if (node_capacity == 0 or node_capacity >= none) @compileError("jsonpath_nodes must be 1..65534");
    return struct {
        const Self = @This();
        nodes: [node_capacity]Node = undefined,
        len: usize = 0,
        data: [data_capacity]u8 = undefined,
        data_len: usize = 0,
        root: u16 = none,
        lax: bool = true,

        pub fn bytes(self: *const Self, node: *const Node) []const u8 {
            return self.data[node.data..][0..node.len];
        }

        fn add(self: *Self, node: Node) Error!u16 {
            if (self.len == node_capacity) return error.StatementTooComplex;
            self.nodes[self.len] = node;
            self.len += 1;
            return @intCast(self.len - 1);
        }

        fn store(self: *Self, value: []const u8) Error!u32 {
            if (value.len > data_capacity - self.data_len) return error.TextCapacity;
            @memcpy(self.data[self.data_len..][0..value.len], value);
            self.data_len += value.len;
            return @intCast(self.data_len - value.len);
        }

        fn storeByte(self: *Self, value: u8) Error!void {
            if (self.data_len == data_capacity) return error.TextCapacity;
            self.data[self.data_len] = value;
            self.data_len += 1;
        }

        fn storeCode(self: *Self, code: u21) Error!void {
            if (code == 0) return error.UntranslatableCharacter;
            if (code < 0x80) return self.storeByte(@intCast(code));
            if (code < 0x800) {
                try self.storeByte(@intCast(0xc0 | (code >> 6)));
                return self.storeByte(@intCast(0x80 | (code & 0x3f)));
            }
            if (code < 0x10000) {
                try self.storeByte(@intCast(0xe0 | (code >> 12)));
                try self.storeByte(@intCast(0x80 | ((code >> 6) & 0x3f)));
                return self.storeByte(@intCast(0x80 | (code & 0x3f)));
            }
            try self.storeByte(@intCast(0xf0 | (code >> 18)));
            try self.storeByte(@intCast(0x80 | ((code >> 12) & 0x3f)));
            try self.storeByte(@intCast(0x80 | ((code >> 6) & 0x3f)));
            return self.storeByte(@intCast(0x80 | (code & 0x3f)));
        }

        // ---- parsing --------------------------------------------------------

        const Parser = struct {
            path: *Self,
            text: []const u8,
            at: usize = 0,
            current: Token = .{},
            depth: usize = 0,
            filters: usize = 0,
            subscripts: usize = 0,
            control: ?*types.ExecutionControl = null,

            fn skip(self: *Parser) void {
                while (self.at < self.text.len) {
                    const c = self.text[self.at];
                    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                        self.at += 1;
                        continue;
                    }
                    // /* comments */
                    if (c == '/' and self.at + 1 < self.text.len and self.text[self.at + 1] == '*') {
                        var end = self.at + 2;
                        while (end + 1 < self.text.len and !(self.text[end] == '*' and self.text[end + 1] == '/')) end += 1;
                        self.at = if (end + 1 < self.text.len) end + 2 else self.text.len;
                        continue;
                    }
                    break;
                }
            }

            fn next(self: *Parser) Error!void {
                if (self.control) |control| try control.checkpoint();
                self.skip();
                const start = self.at;
                if (start >= self.text.len) {
                    self.current = .{ .tok = .end, .start = start, .end = start };
                    return;
                }
                const c = self.text[start];
                const following: u8 = if (start + 1 < self.text.len) self.text[start + 1] else 0;
                var width: usize = 1;
                const tok: Tok = switch (c) {
                    '$' => blk: {
                        if (following == '"' or (following != 0 and !special(following))) break :blk .variable;
                        break :blk .dollar;
                    },
                    '@' => .at,
                    '.' => if (digit(following)) .number else .dot,
                    '*' => if (following == '*') blk: {
                        width = 2;
                        break :blk .any;
                    } else .star,
                    '[' => .lbracket,
                    ']' => .rbracket,
                    '(' => .lparen,
                    ')' => .rparen,
                    '{' => .lbrace,
                    '}' => .rbrace,
                    ',' => .comma,
                    '?' => .question,
                    '+' => .plus,
                    '-' => .minus,
                    '/' => .slash,
                    '%' => .percent,
                    '=' => if (following == '=') blk: {
                        width = 2;
                        break :blk .eq;
                    } else return error.Syntax,
                    '!' => if (following == '=') blk: {
                        width = 2;
                        break :blk .ne;
                    } else .not_op,
                    '<' => if (following == '=') blk: {
                        width = 2;
                        break :blk .le;
                    } else if (following == '>') blk: {
                        width = 2;
                        break :blk .ne;
                    } else .lt,
                    '>' => if (following == '=') blk: {
                        width = 2;
                        break :blk .ge;
                    } else .gt,
                    '&' => if (following == '&') blk: {
                        width = 2;
                        break :blk .and_op;
                    } else return error.Syntax,
                    '|' => if (following == '|') blk: {
                        width = 2;
                        break :blk .or_op;
                    } else return error.Syntax,
                    '"' => .string,
                    '0'...'9' => .number,
                    else => if (special(c)) return error.Syntax else .ident,
                };
                switch (tok) {
                    .variable => {
                        self.at = start + 1;
                        if (self.text[self.at] == '"') {
                            try self.skipString();
                        } else {
                            while (self.at < self.text.len and !special(self.text[self.at])) self.at += 1;
                        }
                    },
                    .string => {
                        self.at = start;
                        try self.skipString();
                    },
                    .number => {
                        self.at = start;
                        try self.scanNumber();
                    },
                    .ident => {
                        self.at = start;
                        while (self.at < self.text.len and !special(self.text[self.at])) self.at += 1;
                    },
                    else => self.at = start + width,
                }
                self.current = .{ .tok = tok, .start = start, .end = self.at };
            }

            fn skipString(self: *Parser) Error!void {
                // At the opening quote.
                self.at += 1;
                while (true) {
                    if (self.at >= self.text.len) return error.Syntax;
                    const c = self.text[self.at];
                    self.at += 1;
                    if (c == '"') return;
                    if (c == '\\') {
                        if (self.at >= self.text.len) return error.Syntax;
                        self.at += 1;
                    }
                }
            }

            fn scanNumber(self: *Parser) Error!void {
                const text = self.text;
                var at = self.at;
                // Radix integers (0x 0o 0b) with single underscores.
                if (text[at] == '0' and at + 1 < text.len and (lower(text[at + 1]) == 'x' or lower(text[at + 1]) == 'o' or lower(text[at + 1]) == 'b')) {
                    at += 2;
                    var digits: usize = 0;
                    while (at < text.len and (hexValue(text[at]) != null or text[at] == '_')) : (at += 1) digits += 1;
                    if (digits == 0) return error.Syntax;
                } else {
                    while (at < text.len and (digit(text[at]) or text[at] == '_')) at += 1;
                    if (at < text.len and text[at] == '.' and !(at + 1 < text.len and text[at + 1] == '.')) {
                        // A point followed by a letter is an accessor (`1.type()`).
                        if (!(at + 1 < text.len and !special(text[at + 1]) and !digit(text[at + 1]))) {
                            at += 1;
                            while (at < text.len and (digit(text[at]) or text[at] == '_')) at += 1;
                        }
                    }
                    if (at < text.len and lower(text[at]) == 'e') {
                        var exponent = at + 1;
                        if (exponent < text.len and (text[exponent] == '+' or text[exponent] == '-')) exponent += 1;
                        if (exponent < text.len and digit(text[exponent])) {
                            at = exponent;
                            while (at < text.len and digit(text[at])) at += 1;
                        }
                    }
                }
                // Trailing junk after a numeric literal.
                if (at < text.len and !special(text[at])) return error.Syntax;
                self.at = at;
            }

            fn raw(self: *const Parser) []const u8 {
                return self.text[self.current.start..self.current.end];
            }

            fn isWord(self: *const Parser, word: []const u8) bool {
                return self.current.tok == .ident and keyword(self.raw(), word);
            }

            fn isExact(self: *const Parser, word: []const u8) bool {
                return self.current.tok == .ident and types.same(self.raw(), word);
            }

            fn expect(self: *Parser, tok: Tok) Error!void {
                if (self.current.tok != tok) return error.Syntax;
                try self.next();
            }

            fn enter(self: *Parser) Error!void {
                self.depth += 1;
                if (self.depth > max_depth) return error.StatementTooComplex;
            }

            fn leave(self: *Parser) void {
                self.depth -= 1;
            }

            /// Decodes the string token at `start` (opening quote) into data.
            fn decodeString(self: *Parser, start: usize, end: usize) Error!Node {
                const path = self.path;
                const at = path.data_len;
                var index = start + 1;
                const close = end - 1;
                while (index < close) {
                    const c = self.text[index];
                    index += 1;
                    if (c != '\\') {
                        try path.storeByte(c);
                        continue;
                    }
                    const e = self.text[index];
                    index += 1;
                    switch (e) {
                        'b' => try path.storeByte(0x08),
                        'f' => try path.storeByte(0x0c),
                        'n' => try path.storeByte('\n'),
                        'r' => try path.storeByte('\r'),
                        't' => try path.storeByte('\t'),
                        'v' => try path.storeByte(0x0b),
                        'x' => {
                            if (index + 2 > close) return error.Syntax;
                            const high = hexValue(self.text[index]) orelse return error.Syntax;
                            const low = hexValue(self.text[index + 1]) orelse return error.Syntax;
                            index += 2;
                            try path.storeCode(high * 16 + low);
                        },
                        'u' => {
                            var code: u21 = 0;
                            if (index < close and self.text[index] == '{') {
                                index += 1;
                                var count: usize = 0;
                                while (index < close and self.text[index] != '}') : (index += 1) {
                                    const value = hexValue(self.text[index]) orelse return error.Syntax;
                                    count += 1;
                                    if (count > 6) return error.Syntax;
                                    code = code * 16 + value;
                                }
                                if (index >= close or count == 0) return error.Syntax;
                                index += 1;
                            } else {
                                code = try self.hex4(&index, close);
                                if (code >= 0xd800 and code <= 0xdbff) {
                                    if (index + 6 > close or self.text[index] != '\\' or self.text[index + 1] != 'u') return error.Syntax;
                                    index += 2;
                                    const low = try self.hex4(&index, close);
                                    if (low < 0xdc00 or low > 0xdfff) return error.Syntax;
                                    code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                                } else if (code >= 0xdc00 and code <= 0xdfff) return error.Syntax;
                            }
                            if (code > 0x10ffff) return error.Syntax;
                            try path.storeCode(code);
                        },
                        else => try path.storeByte(e),
                    }
                }
                return .{ .kind = .string, .data = @intCast(at), .len = @intCast(path.data_len - at) };
            }

            fn hex4(self: *Parser, index: *usize, close: usize) Error!u21 {
                if (index.* + 4 > close) return error.Syntax;
                var code: u21 = 0;
                for (self.text[index.*..][0..4]) |c| code = code * 16 + (hexValue(c) orelse return error.Syntax);
                index.* += 4;
                return code;
            }

            /// Number token text (underscores dropped, radix values as
            /// decimal) into data.
            fn numberNode(self: *Parser) Error!u16 {
                const text = self.raw();
                const path = self.path;
                const at = path.data_len;
                if (text.len > 2 and text[0] == '0' and (lower(text[1]) == 'x' or lower(text[1]) == 'o' or lower(text[1]) == 'b')) {
                    const base: u64 = if (lower(text[1]) == 'x') 16 else if (lower(text[1]) == 'o') 8 else 2;
                    var value: u64 = 0;
                    var previous_underscore = true;
                    for (text[2..]) |c| {
                        if (c == '_') {
                            if (previous_underscore) return error.Syntax;
                            previous_underscore = true;
                            continue;
                        }
                        const d = hexValue(c) orelse return error.Syntax;
                        if (d >= base) return error.Syntax;
                        previous_underscore = false;
                        const product = @mulWithOverflow(value, base);
                        if (product[1] != 0) return error.NumericValueOutOfRange;
                        const sum = @addWithOverflow(product[0], d);
                        if (sum[1] != 0) return error.NumericValueOutOfRange;
                        value = sum[0];
                    }
                    if (previous_underscore) return error.Syntax;
                    var digits: [24]u8 = undefined;
                    var index: usize = digits.len;
                    while (true) {
                        index -= 1;
                        digits[index] = @intCast('0' + value % 10);
                        value /= 10;
                        if (value == 0) break;
                    }
                    _ = try path.store(digits[index..]);
                } else {
                    var previous: u8 = 0;
                    for (text) |c| {
                        if (c == '_') {
                            if (!digit(previous)) return error.Syntax;
                        } else {
                            if (previous == '_' and !digit(c)) return error.Syntax;
                            try path.storeByte(c);
                        }
                        previous = c;
                    }
                    if (previous == '_') return error.Syntax;
                }
                const node = try path.add(.{ .kind = .number, .data = @intCast(at), .len = @intCast(path.data_len - at) });
                try self.next();
                return node;
            }

            // expr_or_predicate := or
            fn orExpr(self: *Parser) Error!u16 {
                try self.enter();
                defer self.leave();
                var left = try self.andExpr();
                while (self.current.tok == .or_op) {
                    try self.next();
                    const right = try self.andExpr();
                    try self.requirePredicate(left);
                    try self.requirePredicate(right);
                    left = try self.path.add(.{ .kind = .or_op, .a = left, .b = right });
                }
                return left;
            }

            fn andExpr(self: *Parser) Error!u16 {
                var left = try self.notExpr();
                while (self.current.tok == .and_op) {
                    try self.next();
                    const right = try self.notExpr();
                    try self.requirePredicate(left);
                    try self.requirePredicate(right);
                    left = try self.path.add(.{ .kind = .and_op, .a = left, .b = right });
                }
                return left;
            }

            fn notExpr(self: *Parser) Error!u16 {
                if (self.current.tok != .not_op) return self.comparison();
                try self.next();
                // NOT applies to a delimited predicate: ( predicate ) or exists ( ... ).
                if (self.current.tok == .lparen) {
                    try self.next();
                    const inner = try self.orExpr();
                    try self.requirePredicate(inner);
                    try self.expect(.rparen);
                    return self.path.add(.{ .kind = .not_op, .a = inner });
                }
                if (self.isWord("exists")) return self.path.add(.{ .kind = .not_op, .a = try self.existsExpr() });
                return error.Syntax;
            }

            fn existsExpr(self: *Parser) Error!u16 {
                try self.next();
                if (self.current.tok != .lparen) return error.Syntax;
                try self.next();
                const inner = try self.orExpr();
                try self.requireValue(inner);
                try self.expect(.rparen);
                return self.path.add(.{ .kind = .exists, .a = inner });
            }

            fn requirePredicate(self: *Parser, id: u16) Error!void {
                if (!predicateKind(self.path.nodes[id].kind)) return error.Syntax;
            }

            fn requireValue(self: *Parser, id: u16) Error!void {
                const node = &self.path.nodes[id];
                // A parenthesized predicate with accessors is a value.
                if (predicateKind(node.kind) and node.next == none) return error.Syntax;
            }

            fn comparison(self: *Parser) Error!u16 {
                if (self.isWord("exists")) {
                    const save = self.*;
                    try self.next();
                    if (self.current.tok == .lparen) {
                        self.* = save;
                        return self.existsExpr();
                    }
                    self.* = save;
                }
                const left = try self.additive();
                const kind: ?Kind = switch (self.current.tok) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    else => null,
                };
                if (kind) |op| {
                    try self.next();
                    const right = try self.additive();
                    try self.requireValue(left);
                    try self.requireValue(right);
                    return self.path.add(.{ .kind = op, .a = left, .b = right });
                }
                if (self.isWord("starts")) {
                    try self.next();
                    if (!self.isWord("with")) return error.Syntax;
                    try self.next();
                    try self.requireValue(left);
                    var right: u16 = none;
                    if (self.current.tok == .string) {
                        right = try self.path.add(try self.decodeString(self.current.start, self.current.end));
                        try self.next();
                    } else if (self.current.tok == .variable) {
                        right = try self.variableNode();
                    } else return error.Syntax;
                    return self.path.add(.{ .kind = .starts_with, .a = left, .b = right });
                }
                if (self.isWord("like_regex")) {
                    try self.next();
                    try self.requireValue(left);
                    if (self.current.tok != .string) return error.Syntax;
                    const pattern = try self.decodeString(self.current.start, self.current.end);
                    try self.next();
                    var flags: u8 = 0;
                    if (self.isWord("flag")) {
                        try self.next();
                        if (self.current.tok != .string) return error.Syntax;
                        for (self.raw()[1 .. self.raw().len - 1]) |c| flags |= switch (c) {
                            'i' => @as(u8, 1),
                            's' => 2,
                            'm' => 4,
                            'x' => 8,
                            'q' => 16,
                            else => return error.InvalidParameterValue,
                        };
                        try self.next();
                    }
                    return self.path.add(.{ .kind = .like_regex, .a = left, .data = pattern.data, .len = pattern.len, .flags = flags });
                }
                return left;
            }

            fn additive(self: *Parser) Error!u16 {
                var left = try self.multiplicative();
                while (self.current.tok == .plus or self.current.tok == .minus) {
                    const kind: Kind = if (self.current.tok == .plus) .add else .sub;
                    try self.next();
                    const right = try self.multiplicative();
                    try self.requireValue(left);
                    try self.requireValue(right);
                    left = try self.path.add(.{ .kind = kind, .a = left, .b = right });
                }
                return left;
            }

            fn multiplicative(self: *Parser) Error!u16 {
                var left = try self.unary();
                while (self.current.tok == .star or self.current.tok == .slash or self.current.tok == .percent) {
                    const kind: Kind = if (self.current.tok == .star) .mul else if (self.current.tok == .slash) .div else .mod;
                    try self.next();
                    const right = try self.unary();
                    try self.requireValue(left);
                    try self.requireValue(right);
                    left = try self.path.add(.{ .kind = kind, .a = left, .b = right });
                }
                return left;
            }

            fn unary(self: *Parser) Error!u16 {
                if (self.current.tok != .plus and self.current.tok != .minus) return self.accessorExpr();
                const minus = self.current.tok == .minus;
                try self.enter();
                defer self.leave();
                try self.next();
                const operand = try self.unary();
                try self.requireValue(operand);
                const node = &self.path.nodes[operand];
                // makeItemUnary folds a signed numeric constant.
                if (node.kind == .number and node.next == none) {
                    if (!minus) return operand;
                    const at = self.path.data_len;
                    const text = self.path.bytes(node);
                    if (text.len > 0 and text[0] == '-') {
                        _ = try self.path.store(text[1..]);
                    } else {
                        try self.path.storeByte('-');
                        _ = try self.path.store(text);
                    }
                    node.data = @intCast(at);
                    node.len = @intCast(self.path.data_len - at);
                    return operand;
                }
                return self.path.add(.{ .kind = if (minus) .minus else .plus, .a = operand });
            }

            fn variableNode(self: *Parser) Error!u16 {
                const text = self.raw();
                var node: Node = .{ .kind = .variable };
                if (text.len > 1 and text[1] == '"') {
                    const decoded = try self.decodeString(self.current.start + 1, self.current.end);
                    node.data = decoded.data;
                    node.len = decoded.len;
                } else {
                    node.data = try self.path.store(text[1..]);
                    node.len = @intCast(text.len - 1);
                }
                try self.next();
                return self.path.add(node);
            }

            /// path_primary accessor_op*
            fn accessorExpr(self: *Parser) Error!u16 {
                var head: u16 = none;
                switch (self.current.tok) {
                    .dollar => {
                        head = try self.path.add(.{ .kind = .root });
                        try self.next();
                    },
                    .at => {
                        if (self.filters == 0) return error.Syntax;
                        head = try self.path.add(.{ .kind = .current });
                        try self.next();
                    },
                    .variable => head = try self.variableNode(),
                    .string => {
                        head = try self.path.add(try self.decodeString(self.current.start, self.current.end));
                        try self.next();
                    },
                    .number => head = try self.numberNode(),
                    .lparen => {
                        try self.enter();
                        defer self.leave();
                        try self.next();
                        head = try self.orExpr();
                        try self.expect(.rparen);
                        // ( predicate ) is unknown
                        if (predicateKind(self.path.nodes[head].kind) and self.isWord("is")) {
                            try self.next();
                            if (!self.isWord("unknown")) return error.Syntax;
                            try self.next();
                            return self.path.add(.{ .kind = .is_unknown, .a = head });
                        }
                        // `( expr ) accessor...` appends the accessors to the
                        // end of the expression's own chain (makeItemList).
                        if (!self.accessorFollows()) return head;
                    },
                    .ident => {
                        if (self.isExact("true")) {
                            head = try self.path.add(.{ .kind = .true_value });
                        } else if (self.isExact("false")) {
                            head = try self.path.add(.{ .kind = .false_value });
                        } else if (self.isExact("null")) {
                            head = try self.path.add(.{ .kind = .null_value });
                        } else if (self.isWord("last")) {
                            if (self.subscripts == 0) return error.Syntax;
                            head = try self.path.add(.{ .kind = .last });
                        } else return error.Syntax;
                        try self.next();
                    },
                    else => return error.Syntax,
                }
                var tail = head;
                while (self.path.nodes[tail].next != none) tail = self.path.nodes[tail].next;
                while (self.accessorFollows()) {
                    const step = try self.accessor();
                    self.path.nodes[tail].next = step;
                    tail = step;
                }
                return head;
            }

            fn accessorFollows(self: *const Parser) bool {
                return self.current.tok == .dot or self.current.tok == .lbracket or self.current.tok == .question;
            }

            fn accessor(self: *Parser) Error!u16 {
                switch (self.current.tok) {
                    .question => {
                        try self.next();
                        if (self.current.tok != .lparen) return error.Syntax;
                        try self.next();
                        self.filters += 1;
                        const predicate = try self.orExpr();
                        self.filters -= 1;
                        try self.requirePredicate(predicate);
                        try self.expect(.rparen);
                        return self.path.add(.{ .kind = .filter, .a = predicate });
                    },
                    .lbracket => {
                        try self.next();
                        if (self.current.tok == .star) {
                            try self.next();
                            try self.expect(.rbracket);
                            return self.path.add(.{ .kind = .any_array });
                        }
                        const array = try self.path.add(.{ .kind = .index_array });
                        var tail: u16 = none;
                        self.subscripts += 1;
                        while (true) {
                            const from = try self.orExpr();
                            try self.requireValue(from);
                            var to: u16 = none;
                            if (self.isWord("to")) {
                                try self.next();
                                to = try self.orExpr();
                                try self.requireValue(to);
                            }
                            const subscript = try self.path.add(.{ .kind = .subscript, .a = from, .b = to });
                            if (tail == none) self.path.nodes[array].a = subscript else self.path.nodes[tail].sibling = subscript;
                            tail = subscript;
                            if (self.current.tok != .comma) break;
                            try self.next();
                        }
                        self.subscripts -= 1;
                        try self.expect(.rbracket);
                        return array;
                    },
                    .dot => {
                        try self.next();
                        switch (self.current.tok) {
                            .star => {
                                try self.next();
                                return self.path.add(.{ .kind = .any_key });
                            },
                            .any => {
                                try self.next();
                                var node: Node = .{ .kind = .any, .first = 0, .last = last_level };
                                if (self.current.tok == .lbrace) {
                                    try self.next();
                                    node.first = try self.level();
                                    node.last = node.first;
                                    if (self.isWord("to")) {
                                        try self.next();
                                        node.last = try self.level();
                                    }
                                    try self.expect(.rbrace);
                                }
                                return self.path.add(node);
                            },
                            .string => {
                                var node = try self.decodeString(self.current.start, self.current.end);
                                node.kind = .key;
                                try self.next();
                                return self.path.add(node);
                            },
                            .ident => {
                                const name = self.raw();
                                try self.next();
                                if (self.current.tok == .lparen) return self.methodCall(name);
                                const data = try self.path.store(name);
                                return self.path.add(.{ .kind = .key, .data = data, .len = @intCast(name.len) });
                            },
                            .variable, .dollar => return error.Syntax,
                            else => return error.Syntax,
                        }
                    },
                    else => return error.Syntax,
                }
            }

            fn level(self: *Parser) Error!u32 {
                if (self.isWord("last")) {
                    try self.next();
                    return last_level;
                }
                if (self.current.tok != .number) return error.Syntax;
                var value: u64 = 0;
                for (self.raw()) |c| {
                    if (!digit(c)) return error.Syntax;
                    value = value * 10 + (c - '0');
                    if (value >= last_level) return error.Syntax;
                }
                try self.next();
                return @intCast(value);
            }

            /// `.name(` seen; the current token is `(`.
            fn methodCall(self: *Parser, name: []const u8) Error!u16 {
                var method: ?Method = null;
                for (method_names, 0..) |candidate, index| if (keyword(name, candidate)) {
                    method = @enumFromInt(index);
                };
                const kind = method orelse return error.Syntax;
                try self.next();
                var node: Node = .{ .kind = .method, .method = kind };
                switch (kind) {
                    .datetime => if (self.current.tok == .string) {
                        node.a = try self.path.add(try self.decodeString(self.current.start, self.current.end));
                        try self.next();
                    },
                    .decimal => if (self.current.tok != .rparen) {
                        node.a = try self.signedInteger();
                        if (self.current.tok == .comma) {
                            try self.next();
                            node.b = try self.signedInteger();
                        }
                    },
                    .time, .time_tz, .timestamp, .timestamp_tz => if (self.current.tok != .rparen) {
                        node.a = try self.signedInteger();
                    },
                    else => {},
                }
                try self.expect(.rparen);
                return self.path.add(node);
            }

            fn signedInteger(self: *Parser) Error!u16 {
                var negative = false;
                if (self.current.tok == .minus or self.current.tok == .plus) {
                    negative = self.current.tok == .minus;
                    try self.next();
                }
                if (self.current.tok != .number) return error.Syntax;
                for (self.raw()) |c| if (!digit(c)) return error.Syntax;
                const at = self.path.data_len;
                if (negative) try self.path.storeByte('-');
                _ = try self.path.store(self.raw());
                try self.next();
                return self.path.add(.{ .kind = .number, .data = @intCast(at), .len = @intCast(self.path.data_len - at) });
            }
        };

        /// jsonpath_in: parses `text` (lax/strict mode, then one
        /// expression or predicate).
        pub fn parse(self: *Self, text: []const u8, control: ?*types.ExecutionControl) Error!void {
            self.* = .{};
            var parser: Parser = .{ .path = self, .text = text, .control = control };
            try parser.next();
            if (parser.isWord("strict") or parser.isWord("lax")) {
                const save = parser;
                const strict = parser.isWord("strict");
                try parser.next();
                // `lax` / `strict` alone are keys of nothing: a mode needs a path.
                if (parser.current.tok == .end) {
                    parser = save;
                } else self.lax = !strict;
            }
            if (parser.current.tok == .end) return error.Syntax;
            self.root = try parser.orExpr();
            if (parser.current.tok != .end) return error.Syntax;
        }

        // ---- canonical output ------------------------------------------------

        pub const Out = struct {
            bytes: []u8,
            len: usize = 0,

            fn append(self: *Out, value: []const u8) Error!void {
                if (value.len > self.bytes.len - self.len) return error.TextCapacity;
                @memcpy(self.bytes[self.len..][0..value.len], value);
                self.len += value.len;
            }

            fn byte(self: *Out, value: u8) Error!void {
                return self.append(&.{value});
            }

            fn escaped(self: *Out, value: []const u8) Error!void {
                try self.byte('"');
                for (value) |c| switch (c) {
                    '"' => try self.append("\\\""),
                    '\\' => try self.append("\\\\"),
                    0x08 => try self.append("\\b"),
                    0x0c => try self.append("\\f"),
                    '\n' => try self.append("\\n"),
                    '\r' => try self.append("\\r"),
                    '\t' => try self.append("\\t"),
                    else => if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        try self.append(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                    } else try self.byte(c),
                };
                try self.byte('"');
            }

            fn unsigned(self: *Out, value: u32) Error!void {
                var digits: [10]u8 = undefined;
                var index: usize = digits.len;
                var rest = value;
                while (true) {
                    index -= 1;
                    digits[index] = @intCast('0' + rest % 10);
                    rest /= 10;
                    if (rest == 0) break;
                }
                try self.append(digits[index..]);
            }
        };

        /// jsonpath_out: the canonical text of the parsed path.
        pub fn print(self: *const Self, out: *Out, comptime digits: usize) Error!void {
            if (!self.lax) try out.append("strict ");
            try self.printItem(out, self.root, false, true, digits, 0);
        }

        fn printItem(self: *const Self, out: *Out, start: u16, in_key_first: bool, brackets_first: bool, comptime digits: usize, depth: usize) Error!void {
            if (depth > max_depth + 2) return error.StatementTooComplex;
            var id = start;
            var in_key = in_key_first;
            var brackets = brackets_first;
            while (id != none) {
                const v = &self.nodes[id];
                switch (v.kind) {
                    .and_op, .or_op, .eq, .ne, .lt, .gt, .le, .ge, .add, .sub, .mul, .div, .mod, .starts_with => {
                        if (brackets) try out.byte('(');
                        const left = &self.nodes[v.a];
                        try self.printItem(out, v.a, false, priority(left.kind) <= priority(v.kind), digits, depth + 1);
                        try out.byte(' ');
                        try out.append(operatorName(v.kind));
                        try out.byte(' ');
                        const right = &self.nodes[v.b];
                        try self.printItem(out, v.b, false, priority(right.kind) <= priority(v.kind), digits, depth + 1);
                        if (brackets) try out.byte(')');
                    },
                    .like_regex => {
                        if (brackets) try out.byte('(');
                        const left = &self.nodes[v.a];
                        try self.printItem(out, v.a, false, priority(left.kind) <= priority(v.kind), digits, depth + 1);
                        try out.append(" like_regex ");
                        try out.escaped(self.bytes(v));
                        if (v.flags != 0) {
                            try out.append(" flag \"");
                            if (v.flags & 1 != 0) try out.byte('i');
                            if (v.flags & 2 != 0) try out.byte('s');
                            if (v.flags & 4 != 0) try out.byte('m');
                            if (v.flags & 8 != 0) try out.byte('x');
                            if (v.flags & 16 != 0) try out.byte('q');
                            try out.byte('"');
                        }
                        if (brackets) try out.byte(')');
                    },
                    .plus, .minus => {
                        if (brackets) try out.byte('(');
                        try out.byte(if (v.kind == .plus) '+' else '-');
                        const operand = &self.nodes[v.a];
                        try self.printItem(out, v.a, false, priority(operand.kind) <= priority(v.kind), digits, depth + 1);
                        if (brackets) try out.byte(')');
                    },
                    .not_op => {
                        try out.append("!(");
                        try self.printItem(out, v.a, false, false, digits, depth + 1);
                        try out.byte(')');
                    },
                    .is_unknown => {
                        try out.byte('(');
                        try self.printItem(out, v.a, false, false, digits, depth + 1);
                        try out.append(") is unknown");
                    },
                    .exists => {
                        try out.append("exists (");
                        try self.printItem(out, v.a, false, false, digits, depth + 1);
                        try out.byte(')');
                    },
                    .filter => {
                        try out.append("?(");
                        try self.printItem(out, v.a, false, false, digits, depth + 1);
                        try out.byte(')');
                    },
                    .root => try out.byte('$'),
                    .current => try out.byte('@'),
                    .last => try out.append("last"),
                    .variable => {
                        try out.byte('$');
                        try out.escaped(self.bytes(v));
                    },
                    .null_value => try out.append("null"),
                    .true_value => try out.append("true"),
                    .false_value => try out.append("false"),
                    .string => try out.escaped(self.bytes(v)),
                    .number => {
                        const N = numeric.Ops(digits);
                        const value = try N.parse(self.bytes(v));
                        var buffer: [numeric.format_bytes]u8 = undefined;
                        if (v.next != none) try out.byte('(');
                        try out.append(N.format(&value, &buffer));
                        if (v.next != none) try out.byte(')');
                    },
                    .key => {
                        if (in_key) try out.byte('.');
                        try out.escaped(self.bytes(v));
                    },
                    .any_key => {
                        if (in_key) try out.byte('.');
                        try out.byte('*');
                    },
                    .any_array => try out.append("[*]"),
                    .index_array => {
                        try out.byte('[');
                        var subscript = v.a;
                        var first = true;
                        while (subscript != none) : (subscript = self.nodes[subscript].sibling) {
                            if (!first) try out.byte(',');
                            first = false;
                            const s = &self.nodes[subscript];
                            try self.printItem(out, s.a, false, false, digits, depth + 1);
                            if (s.b != none) {
                                try out.append(" to ");
                                try self.printItem(out, s.b, false, false, digits, depth + 1);
                            }
                        }
                        try out.byte(']');
                    },
                    .any => {
                        if (in_key) try out.byte('.');
                        if (v.first == 0 and v.last == last_level) {
                            try out.append("**");
                        } else if (v.first == v.last) {
                            if (v.first == last_level) try out.append("**{last}") else {
                                try out.append("**{");
                                try out.unsigned(v.first);
                                try out.byte('}');
                            }
                        } else if (v.first == last_level) {
                            try out.append("**{last to ");
                            try out.unsigned(v.last);
                            try out.byte('}');
                        } else if (v.last == last_level) {
                            try out.append("**{");
                            try out.unsigned(v.first);
                            try out.append(" to last}");
                        } else {
                            try out.append("**{");
                            try out.unsigned(v.first);
                            try out.append(" to ");
                            try out.unsigned(v.last);
                            try out.byte('}');
                        }
                    },
                    .method => {
                        try out.byte('.');
                        try out.append(method_names[@intFromEnum(v.method)]);
                        try out.byte('(');
                        if (v.a != none) try self.printItem(out, v.a, false, false, digits, depth + 1);
                        if (v.b != none) {
                            try out.byte(',');
                            try self.printItem(out, v.b, false, false, digits, depth + 1);
                        }
                        try out.byte(')');
                    },
                    .subscript => return error.Syntax,
                }
                id = v.next;
                in_key = true;
                brackets = true;
            }
        }
    };
}

/// Errors that a silent evaluation (the `silent` argument, @? and @@)
/// turns into "no result" and a predicate turns into unknown: those
/// jsonpath_exec.c raises through RETURN_ERROR. Engine capacity limits,
/// cancellation, a missing variable and unsupported features never are.
pub fn suppressible(err: Error) bool {
    return switch (err) {
        error.SqlJsonArrayNotFound, error.SqlJsonMemberNotFound, error.SqlJsonObjectNotFound, error.InvalidSqlJsonSubscript,
        error.SingletonSqlJsonItemRequired, error.NonNumericSqlJsonItem, error.SqlJsonNumberNotFound, error.SqlJsonScalarRequired,
        error.SqlJsonItemCannotBeCast, error.DivisionByZero, error.NumericValueOutOfRange => true,
        else => false,
    };
}

pub fn Engine(comptime config: types.Config) type {
    const J = jsonb.Jsonb(config.text_bytes, config.json_depth, config.numeric_digits);
    const N = numeric.Ops(config.numeric_digits);
    const Io = value_module.Io(config);
    const Tag = jsonb.Tag;
    return struct {
        pub const P = Path(config.jsonpath_nodes, config.text_bytes);
        pub const Documents = J;

        /// One SQL/JSON item: an encoded JSONB value at `at` of `bytes`
        /// (the document, the vars object or the scratch buffer).
        pub const Item = struct { bytes: []const u8, at: usize };

        pub const Sink = struct {
            context: ?*anyopaque = null,
            /// Receives one result item; true stops the evaluation.
            emit: *const fn (?*anyopaque, Item) Error!bool,
        };

        pub const Tri = enum { false_value, true_value, unknown };

        pub const Context = struct {
            path: *const P,
            root: Item,
            current: Item,
            vars: ?[]const u8 = null,
            lax: bool = true,
            ignore_structural: bool = true,
            array_size: i64 = -1,
            /// Computed values (literals, arithmetic, item methods) while a
            /// frame emits them; released by that frame.
            scratch: J.Buffer = .{},
            /// Copies of computed values a collector keeps on the item
            /// stack; released with it.
            kept: J.Buffer = .{},
            items: [config.jsonpath_items]Item = undefined,
            item_len: usize = 0,
            depth: usize = 0,
            stopped: bool = false,
            control: ?*types.ExecutionControl = null,
            session: *const value_module.Session,
        };

        /// Parses and prints `text` (jsonpath_in + jsonpath_out).
        pub fn canonical(text: []const u8, out: []u8, control: ?*types.ExecutionControl) Error![]const u8 {
            var path: P = undefined;
            try path.parse(text, control);
            var printed: P.Out = .{ .bytes = out };
            try path.print(&printed, config.numeric_digits);
            return out[0..printed.len];
        }

        /// A stored jsonpath value is its own canonical text.
        pub fn validStored(text: []const u8) bool {
            var buffer: [config.text_bytes]u8 = undefined;
            const printed = canonical(text, &buffer, null) catch return false;
            return types.same(printed, text);
        }

        /// Starts an evaluation of `path` over `document` (the jsonb
        /// bytes); `vars` must be a JSONB object (22023).
        pub fn init(ctx: *Context, path: *const P, document: []const u8, vars: ?[]const u8, control: ?*types.ExecutionControl, session: *const value_module.Session) Error!void {
            return initItem(ctx, path, .{ .bytes = document, .at = 0 }, vars, control, session);
        }

        /// As init, with an item of another evaluation as `$` (JSON_TABLE
        /// column paths over a row item).
        pub fn initItem(ctx: *Context, path: *const P, root: Item, vars: ?[]const u8, control: ?*types.ExecutionControl, session: *const value_module.Session) Error!void {
            if (vars) |object| if (object[0] != @intFromEnum(Tag.object)) return error.InvalidParameterValue;
            ctx.* = .{ .path = path, .root = root, .current = root, .vars = vars, .lax = path.lax, .ignore_structural = path.lax, .control = control, .session = session };
        }

        /// Runs the whole path; every result item goes to `sink`.
        pub fn run(ctx: *Context, sink: *const Sink) Error!bool {
            ctx.stopped = false;
            return execute(ctx, ctx.path.root, ctx.root, sink);
        }

        pub fn tagOf(item: Item) Tag {
            return @enumFromInt(item.bytes[item.at]);
        }

        fn container(item: Item) bool {
            const tag = tagOf(item);
            return tag == .array or tag == .object;
        }

        fn enter(ctx: *Context) Error!void {
            if (ctx.control) |control| try control.checkpoint();
            ctx.depth += 1;
            if (ctx.depth > config.jsonpath_nodes + config.json_depth + 8) return error.StatementTooComplex;
        }

        const Mark = struct { items: usize, scratch: usize, kept: usize };

        /// Item stack discipline: a consumer marks, collects operands,
        /// computes and releases before it emits anything; a producer
        /// releases only the scratch bytes of what it emitted (a collector
        /// downstream copied them into `kept`).
        fn mark(ctx: *const Context) Mark {
            return .{ .items = ctx.item_len, .scratch = ctx.scratch.len, .kept = ctx.kept.len };
        }

        fn release(ctx: *Context, at: Mark) void {
            ctx.item_len = at.items;
            ctx.scratch.len = at.scratch;
            ctx.kept.len = at.kept;
        }

        fn scratchItem(ctx: *Context, start: usize) Item {
            return .{ .bytes = ctx.scratch.bytes[0..], .at = start };
        }

        fn numberItem(ctx: *Context, value: *const numeric.Numeric) Error!Item {
            const start = ctx.scratch.len;
            try J.writeNumber(&ctx.scratch, value);
            return scratchItem(ctx, start);
        }

        fn stringItem(ctx: *Context, value: []const u8) Error!Item {
            const start = ctx.scratch.len;
            try J.writeString(&ctx.scratch, value);
            return scratchItem(ctx, start);
        }

        fn tagItem(ctx: *Context, tag: Tag) Error!Item {
            const start = ctx.scratch.len;
            try ctx.scratch.byte(@intFromEnum(tag));
            return scratchItem(ctx, start);
        }

        pub fn numberOf(item: Item) numeric.Numeric {
            return jsonb.numberAt(item.bytes, item.at);
        }

        pub fn stringOf(item: Item) []const u8 {
            return jsonb.stringAt(item.bytes, item.at);
        }

        /// The chained accessor after `node`, or the sink.
        fn next(ctx: *Context, node: *const Node, item: Item, sink: *const Sink) Error!bool {
            if (node.next != none) return execute(ctx, node.next, item, sink);
            if (ctx.stopped) return true;
            if (try sink.emit(sink.context, item)) ctx.stopped = true;
            return true;
        }

        fn execute(ctx: *Context, id: u16, item: Item, sink: *const Sink) Error!bool {
            try enter(ctx);
            defer ctx.depth -= 1;
            const node = &ctx.path.nodes[id];
            switch (node.kind) {
                .root => return next(ctx, node, ctx.root, sink),
                .current => return next(ctx, node, ctx.current, sink),
                .variable => return next(ctx, node, try variable(ctx, node), sink),
                .null_value, .true_value, .false_value, .number, .string, .last => {
                    const at = ctx.scratch.len;
                    defer ctx.scratch.len = at;
                    return next(ctx, node, try literal(ctx, node), sink);
                },
                .key => return keyAccessor(ctx, node, item, sink, ctx.lax),
                .any_key => return anyKey(ctx, node, item, sink, ctx.lax),
                .any_array => {
                    if (tagOf(item) == .array) {
                        var found = false;
                        var members = jsonb.Members.init(item.bytes, item.at);
                        while (members.next()) |member| {
                            if (ctx.stopped) break;
                            found = try next(ctx, node, .{ .bytes = item.bytes, .at = member.value }, sink) or found;
                        }
                        return found;
                    }
                    if (ctx.lax) return next(ctx, node, item, sink);
                    if (!ctx.ignore_structural) return error.SqlJsonArrayNotFound;
                    return false;
                },
                .index_array => return indexArray(ctx, node, item, sink),
                .any => return anyLevels(ctx, node, item, sink),
                .filter => return filter(ctx, node, item, sink, ctx.lax),
                .method => return method(ctx, node, item, sink, ctx.lax),
                .add, .sub, .mul, .div, .mod => return arithmetic(ctx, node, item, sink),
                .plus, .minus => return unaryArithmetic(ctx, node, item, sink),
                .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op, .not_op, .is_unknown, .exists, .starts_with, .like_regex => {
                    // A predicate used as a value: true, false or null.
                    const state = try boolean(ctx, id, item);
                    const at = ctx.scratch.len;
                    defer ctx.scratch.len = at;
                    const result = try tagItem(ctx, switch (state) {
                        .true_value => .true_value,
                        .false_value => .false_value,
                        .unknown => .null_value,
                    });
                    return next(ctx, node, result, sink);
                },
                .subscript => return error.Syntax,
            }
        }

        fn variable(ctx: *Context, node: *const Node) Error!Item {
            const name = ctx.path.bytes(node);
            const object = ctx.vars orelse return error.UndefinedObject;
            var members = jsonb.Members.init(object, 0);
            while (members.next()) |member| if (types.same(member.key, name)) return .{ .bytes = object, .at = member.value };
            return error.UndefinedObject;
        }

        fn literal(ctx: *Context, node: *const Node) Error!Item {
            return switch (node.kind) {
                .null_value => tagItem(ctx, .null_value),
                .true_value => tagItem(ctx, .true_value),
                .false_value => tagItem(ctx, .false_value),
                .string => stringItem(ctx, ctx.path.bytes(node)),
                .number => blk: {
                    const value = try N.parse(ctx.path.bytes(node));
                    break :blk numberItem(ctx, &value);
                },
                else => blk: {
                    // `last`: the innermost array subscript's last index.
                    if (ctx.array_size < 0) return error.Syntax;
                    const value = N.fromInt(ctx.array_size - 1);
                    break :blk numberItem(ctx, &value);
                },
            };
        }

        fn keyAccessor(ctx: *Context, node: *const Node, item: Item, sink: *const Sink, unwrap: bool) Error!bool {
            switch (tagOf(item)) {
                .object => {
                    const key = ctx.path.bytes(node);
                    var members = jsonb.Members.init(item.bytes, item.at);
                    while (members.next()) |member| {
                        if (types.same(member.key, key)) return next(ctx, node, .{ .bytes = item.bytes, .at = member.value }, sink);
                    }
                    if (!ctx.ignore_structural) return error.SqlJsonMemberNotFound;
                    return false;
                },
                .array => if (unwrap) {
                    var found = false;
                    var members = jsonb.Members.init(item.bytes, item.at);
                    while (members.next()) |member| {
                        if (ctx.stopped) break;
                        found = try keyAccessor(ctx, node, .{ .bytes = item.bytes, .at = member.value }, sink, false) or found;
                    }
                    return found;
                },
                else => {},
            }
            if (!ctx.ignore_structural) return error.SqlJsonMemberNotFound;
            return false;
        }

        fn anyKey(ctx: *Context, node: *const Node, item: Item, sink: *const Sink, unwrap: bool) Error!bool {
            const tag = tagOf(item);
            if (tag == .object or (tag == .array and unwrap)) {
                var found = false;
                var members = jsonb.Members.init(item.bytes, item.at);
                while (members.next()) |member| {
                    if (ctx.stopped) break;
                    const value: Item = .{ .bytes = item.bytes, .at = member.value };
                    found = (if (tag == .object) try next(ctx, node, value, sink) else try anyKey(ctx, node, value, sink, false)) or found;
                }
                return found;
            }
            if (!ctx.ignore_structural) return error.SqlJsonObjectNotFound;
            return false;
        }

        fn elementAt(item: Item, index: i64) Item {
            var members = jsonb.Members.init(item.bytes, item.at);
            var position: i64 = 0;
            while (members.next()) |member| : (position += 1) if (position == index) return .{ .bytes = item.bytes, .at = member.value };
            return item;
        }

        /// A subscript: exactly one numeric item, truncated, in int4 (22033).
        fn arrayIndex(ctx: *Context, id: u16, item: Item) Error!i64 {
            const at = mark(ctx);
            defer release(ctx, at);
            const range = try collect(ctx, id, item, false);
            if (range.end - range.start != 1 or tagOf(ctx.items[range.start]) != .number) return error.InvalidSqlJsonSubscript;
            const value = numberOf(ctx.items[range.start]);
            const whole = try N.trunc(&value, 0);
            return N.toInt(&whole, -2147483648, 2147483647) catch error.InvalidSqlJsonSubscript;
        }

        fn indexArray(ctx: *Context, node: *const Node, item: Item, sink: *const Sink) Error!bool {
            const array = tagOf(item) == .array;
            var size: i64 = 1;
            if (array) {
                size = @intCast(jsonb.countAt(item.bytes, item.at));
            } else if (!ctx.lax) {
                if (!ctx.ignore_structural) return error.SqlJsonArrayNotFound;
                return false;
            }
            const saved = ctx.array_size;
            ctx.array_size = size;
            defer ctx.array_size = saved;
            var found = false;
            var subscript = node.a;
            while (subscript != none and !ctx.stopped) : (subscript = ctx.path.nodes[subscript].sibling) {
                const s = &ctx.path.nodes[subscript];
                var from = try arrayIndex(ctx, s.a, item);
                var to = if (s.b != none) try arrayIndex(ctx, s.b, item) else from;
                if (!ctx.ignore_structural and (from < 0 or from > to or to >= size)) return error.InvalidSqlJsonSubscript;
                if (from < 0) from = 0;
                if (to >= size) to = size - 1;
                var index = from;
                while (index <= to and !ctx.stopped) : (index += 1) {
                    if (ctx.control) |control| try control.checkpoint();
                    found = try next(ctx, node, if (array) elementAt(item, index) else item, sink) or found;
                }
            }
            return found;
        }

        fn anyLevels(ctx: *Context, node: *const Node, item: Item, sink: *const Sink) Error!bool {
            var found = false;
            if (node.first == 0) {
                const saved = ctx.ignore_structural;
                ctx.ignore_structural = true;
                defer ctx.ignore_structural = saved;
                found = try next(ctx, node, item, sink);
                if (ctx.stopped) return found;
            }
            if (container(item)) found = try anyRecurse(ctx, node, item, 1, sink) or found;
            return found;
        }

        /// executeAnyItem: pre-order over the members at `level` and below.
        fn anyRecurse(ctx: *Context, node: *const Node, item: Item, level: u32, sink: *const Sink) Error!bool {
            try enter(ctx);
            defer ctx.depth -= 1;
            if (level > node.last) return false;
            var found = false;
            var members = jsonb.Members.init(item.bytes, item.at);
            while (members.next()) |member| {
                if (ctx.stopped) break;
                const value: Item = .{ .bytes = item.bytes, .at = member.value };
                const leaves_only = node.first == last_level and node.last == last_level;
                if (level >= node.first or (leaves_only and !container(value))) {
                    const saved = ctx.ignore_structural;
                    ctx.ignore_structural = true;
                    defer ctx.ignore_structural = saved;
                    found = try next(ctx, node, value, sink) or found;
                    if (ctx.stopped) break;
                }
                if (level < node.last and container(value)) found = try anyRecurse(ctx, node, value, level + 1, sink) or found;
            }
            return found;
        }

        fn filter(ctx: *Context, node: *const Node, item: Item, sink: *const Sink, unwrap: bool) Error!bool {
            if (unwrap and tagOf(item) == .array) {
                var found = false;
                var members = jsonb.Members.init(item.bytes, item.at);
                while (members.next()) |member| {
                    if (ctx.stopped) break;
                    found = try filter(ctx, node, .{ .bytes = item.bytes, .at = member.value }, sink, false) or found;
                }
                return found;
            }
            const saved = ctx.current;
            ctx.current = item;
            const state = boolean(ctx, node.a, item);
            ctx.current = saved;
            if ((try state) != .true_value) return false;
            return next(ctx, node, item, sink);
        }

        const Range = struct { start: usize, end: usize };

        const Collector = struct { ctx: *Context, unwrap: bool };

        fn push(ctx: *Context, item: Item) Error!void {
            if (ctx.item_len == ctx.items.len) return error.ProgramLimitExceeded;
            ctx.items[ctx.item_len] = item;
            ctx.item_len += 1;
        }

        fn collectEmit(raw: ?*anyopaque, emitted: Item) Error!bool {
            const collector: *Collector = @ptrCast(@alignCast(raw.?));
            const ctx = collector.ctx;
            var item = emitted;
            if (item.bytes.ptr == &ctx.scratch.bytes) {
                const start = ctx.kept.len;
                try ctx.kept.append(item.bytes[item.at..][0..jsonb.sizeAt(item.bytes, item.at)]);
                item = .{ .bytes = ctx.kept.bytes[0..], .at = start };
            }
            if (collector.unwrap and tagOf(item) == .array) {
                var members = jsonb.Members.init(item.bytes, item.at);
                while (members.next()) |member| try push(collector.ctx, .{ .bytes = item.bytes, .at = member.value });
            } else try push(collector.ctx, item);
            return false;
        }

        /// The items of `id` over `item` on the item stack (arrays unwrapped
        /// one level in lax mode when `unwrap`); the caller releases them.
        fn collect(ctx: *Context, id: u16, item: Item, unwrap: bool) Error!Range {
            const start = ctx.item_len;
            var collector: Collector = .{ .ctx = ctx, .unwrap = unwrap and ctx.lax };
            const sink: Sink = .{ .context = &collector, .emit = collectEmit };
            const saved = ctx.stopped;
            ctx.stopped = false;
            defer ctx.stopped = saved;
            _ = try execute(ctx, id, item, &sink);
            return .{ .start = start, .end = ctx.item_len };
        }

        fn stopEmit(_: ?*anyopaque, _: Item) Error!bool {
            return true;
        }

        fn arithmetic(ctx: *Context, node: *const Node, item: Item, sink: *const Sink) Error!bool {
            const at = mark(ctx);
            errdefer release(ctx, at);
            const left = try collect(ctx, node.a, item, true);
            const right = try collect(ctx, node.b, item, true);
            if (left.end - left.start != 1 or tagOf(ctx.items[left.start]) != .number) return error.SingletonSqlJsonItemRequired;
            if (right.end - right.start != 1 or tagOf(ctx.items[right.start]) != .number) return error.SingletonSqlJsonItemRequired;
            const a = numberOf(ctx.items[left.start]);
            const b = numberOf(ctx.items[right.start]);
            const value = switch (node.kind) {
                .add => try N.add(&a, &b),
                .sub => try N.sub(&a, &b),
                .mul => try N.mul(&a, &b),
                .div => try N.div(&a, &b),
                else => try N.mod(&a, &b),
            };
            release(ctx, at);
            const top = ctx.scratch.len;
            defer ctx.scratch.len = top;
            return next(ctx, node, try numberItem(ctx, &value), sink);
        }

        const Unary = struct { ctx: *Context, node: *const Node, sink: *const Sink, found: bool = false };

        fn unaryApply(unary: *Unary, operand: Item) Error!void {
            const ctx = unary.ctx;
            if (tagOf(operand) != .number) return error.SqlJsonNumberNotFound;
            if (unary.node.kind == .plus) {
                unary.found = try next(ctx, unary.node, operand, unary.sink) or unary.found;
                return;
            }
            const value = N.negate(numberOf(operand));
            const top = ctx.scratch.len;
            defer ctx.scratch.len = top;
            unary.found = try next(ctx, unary.node, try numberItem(ctx, &value), unary.sink) or unary.found;
        }

        fn unaryEmit(raw: ?*anyopaque, item: Item) Error!bool {
            const unary: *Unary = @ptrCast(@alignCast(raw.?));
            if (unary.ctx.lax and tagOf(item) == .array) {
                var members = jsonb.Members.init(item.bytes, item.at);
                while (members.next()) |member| {
                    if (unary.ctx.stopped) break;
                    try unaryApply(unary, .{ .bytes = item.bytes, .at = member.value });
                }
            } else try unaryApply(unary, item);
            return unary.ctx.stopped;
        }

        /// Unary + / -: every (lax-unwrapped) operand item must be numeric
        /// (2203B); results stream to the next accessor.
        fn unaryArithmetic(ctx: *Context, node: *const Node, item: Item, sink: *const Sink) Error!bool {
            var unary: Unary = .{ .ctx = ctx, .node = node, .sink = sink };
            const inner: Sink = .{ .context = &unary, .emit = unaryEmit };
            _ = try execute(ctx, node.a, item, &inner);
            return unary.found;
        }

        fn method(ctx: *Context, node: *const Node, item: Item, sink: *const Sink, unwrap: bool) Error!bool {
            const tag = tagOf(item);
            switch (node.method) {
                .type => {
                    const at = ctx.scratch.len;
                    defer ctx.scratch.len = at;
                    const name: []const u8 = switch (tag) {
                        .null_value => "null",
                        .false_value, .true_value => "boolean",
                        .number => "number",
                        .string => "string",
                        .array => "array",
                        .object => "object",
                    };
                    return next(ctx, node, try stringItem(ctx, name), sink);
                },
                .size => {
                    var size: i64 = 1;
                    if (tag == .array) {
                        size = @intCast(jsonb.countAt(item.bytes, item.at));
                    } else if (!ctx.lax) {
                        if (!ctx.ignore_structural) return error.SqlJsonArrayNotFound;
                        return false;
                    }
                    const at = ctx.scratch.len;
                    defer ctx.scratch.len = at;
                    const value = N.fromInt(size);
                    return next(ctx, node, try numberItem(ctx, &value), sink);
                },
                .keyvalue, .datetime, .date, .time, .time_tz, .timestamp, .timestamp_tz => return error.UnsupportedStatement,
                else => {},
            }
            if (unwrap and tag == .array) {
                var found = false;
                var members = jsonb.Members.init(item.bytes, item.at);
                while (members.next()) |member| {
                    if (ctx.stopped) break;
                    found = try method(ctx, node, .{ .bytes = item.bytes, .at = member.value }, sink, false) or found;
                }
                return found;
            }
            const at = ctx.scratch.len;
            defer ctx.scratch.len = at;
            var result = item;
            switch (node.method) {
                .abs, .floor, .ceiling => {
                    if (tag != .number) return error.NonNumericSqlJsonItem;
                    const value = numberOf(item);
                    const computed = switch (node.method) {
                        .abs => N.absolute(&value),
                        .floor => try N.directedInteger(&value, false),
                        else => try N.directedInteger(&value, true),
                    };
                    result = try numberItem(ctx, &computed);
                },
                .double => {
                    var buffer: [numeric.format_bytes]u8 = undefined;
                    const text = switch (tag) {
                        .number => blk: {
                            const value = numberOf(item);
                            break :blk N.format(&value, &buffer);
                        },
                        .string => stringOf(item),
                        else => return error.NonNumericSqlJsonItem,
                    };
                    const double = float_text.parse(f64, text) catch return error.NonNumericSqlJsonItem;
                    if (double != double or float_text.isInf(double)) return error.NonNumericSqlJsonItem;
                    if (tag == .string) {
                        const converted = try Io.cast(.{ .float8 = double }, .float8, .numeric, -1, ctx.session);
                        result = try numberItem(ctx, &converted.numeric);
                    }
                },
                .number, .decimal => {
                    var value: numeric.Numeric = undefined;
                    switch (tag) {
                        .number => value = numberOf(item),
                        .string => {
                            value = N.parse(stringOf(item)) catch return error.NonNumericSqlJsonItem;
                            if (value.special != .finite) return error.NonNumericSqlJsonItem;
                        },
                        else => return error.NonNumericSqlJsonItem,
                    }
                    if (node.method == .decimal and node.a != none) {
                        const precision = N.parse(ctx.path.bytes(&ctx.path.nodes[node.a])) catch return error.InvalidParameterValue;
                        const scale_value: numeric.Numeric = if (node.b != none) (N.parse(ctx.path.bytes(&ctx.path.nodes[node.b])) catch return error.InvalidParameterValue) else .{};
                        const p = N.toInt(&precision, 1, 1000) catch return error.InvalidParameterValue;
                        const s = N.toInt(&scale_value, -1000, 1000) catch return error.InvalidParameterValue;
                        const typmod = N.encodeTypmod(@intCast(p), @intCast(s)) catch return error.InvalidParameterValue;
                        value = N.applyTypmod(&value, typmod) catch return error.NonNumericSqlJsonItem;
                    }
                    result = try numberItem(ctx, &value);
                },
                .integer, .bigint => {
                    const low: i64 = if (node.method == .integer) -2147483648 else -9223372036854775808;
                    const high: i64 = if (node.method == .integer) 2147483647 else 9223372036854775807;
                    const whole: i64 = switch (tag) {
                        .number => blk: {
                            const value = numberOf(item);
                            break :blk N.toInt(&value, low, high) catch return error.NonNumericSqlJsonItem;
                        },
                        .string => expr_module.parseInteger(stringOf(item), if (node.method == .integer) .int4 else .int8) catch return error.NonNumericSqlJsonItem,
                        else => return error.NonNumericSqlJsonItem,
                    };
                    const value = N.fromInt(whole);
                    result = try numberItem(ctx, &value);
                },
                .string => {
                    var buffer: [numeric.format_bytes]u8 = undefined;
                    const text: []const u8 = switch (tag) {
                        .number => blk: {
                            const value = numberOf(item);
                            break :blk N.format(&value, &buffer);
                        },
                        .string => stringOf(item),
                        .true_value => "true",
                        .false_value => "false",
                        else => return error.NonNumericSqlJsonItem,
                    };
                    result = try stringItem(ctx, text);
                },
                .boolean => {
                    const truth: bool = switch (tag) {
                        .true_value => true,
                        .false_value => false,
                        .number => blk: {
                            const value = numberOf(item);
                            const whole = N.trunc(&value, 0) catch return error.NonNumericSqlJsonItem;
                            if (numeric.compareValues(&whole, &value) != 0) return error.NonNumericSqlJsonItem;
                            break :blk !value.isZero();
                        },
                        .string => expr_module.parseBoolean(stringOf(item)) catch return error.NonNumericSqlJsonItem,
                        else => return error.NonNumericSqlJsonItem,
                    };
                    result = try tagItem(ctx, if (truth) .true_value else .false_value);
                },
                else => return error.UnsupportedStatement,
            }
            return next(ctx, node, result, sink);
        }

        // ---- predicates -----------------------------------------------------

        fn boolean(ctx: *Context, id: u16, item: Item) Error!Tri {
            try enter(ctx);
            defer ctx.depth -= 1;
            const node = &ctx.path.nodes[id];
            switch (node.kind) {
                .and_op => {
                    const left = try boolean(ctx, node.a, item);
                    if (left == .false_value) return .false_value;
                    const right = try boolean(ctx, node.b, item);
                    return if (right == .true_value) left else right;
                },
                .or_op => {
                    const left = try boolean(ctx, node.a, item);
                    if (left == .true_value) return .true_value;
                    const right = try boolean(ctx, node.b, item);
                    return if (right == .false_value) left else right;
                },
                .not_op => return switch (try boolean(ctx, node.a, item)) {
                    .true_value => .false_value,
                    .false_value => .true_value,
                    .unknown => .unknown,
                },
                .is_unknown => return if ((try boolean(ctx, node.a, item)) == .unknown) .true_value else .false_value,
                .eq, .ne, .lt, .le, .gt, .ge, .starts_with => return predicate(ctx, node, item),
                .like_regex => return error.UnsupportedStatement,
                .exists => {
                    const at = mark(ctx);
                    defer release(ctx, at);
                    if (!ctx.lax) {
                        // Strict: the complete sequence, so errors surface.
                        const range = collect(ctx, node.a, item, false) catch |err| return if (suppressible(err)) .unknown else err;
                        return if (range.end == range.start) .false_value else .true_value;
                    }
                    const sink: Sink = .{ .emit = stopEmit };
                    const saved = ctx.stopped;
                    ctx.stopped = false;
                    defer ctx.stopped = saved;
                    const found = execute(ctx, node.a, item, &sink) catch |err| return if (suppressible(err)) .unknown else err;
                    return if (found) .true_value else .false_value;
                },
                else => return error.Syntax,
            }
        }

        /// executePredicate: every (left, right) pair; lax stops at the
        /// first true, strict needs every pair free of errors.
        fn predicate(ctx: *Context, node: *const Node, item: Item) Error!Tri {
            const at = mark(ctx);
            defer release(ctx, at);
            const left = collect(ctx, node.a, item, true) catch |err| return if (suppressible(err)) .unknown else err;
            const right = collect(ctx, node.b, item, node.kind != .starts_with) catch |err| return if (suppressible(err)) .unknown else err;
            var found = false;
            var failed = false;
            for (left.start..left.end) |l| {
                for (right.start..right.end) |r| {
                    if (ctx.control) |control| try control.checkpoint();
                    const result = if (node.kind == .starts_with) startsWith(ctx.items[l], ctx.items[r]) else compareItems(node.kind, ctx.items[l], ctx.items[r]);
                    switch (result) {
                        .unknown => {
                            if (!ctx.lax) return .unknown;
                            failed = true;
                        },
                        .true_value => {
                            if (ctx.lax) return .true_value;
                            found = true;
                        },
                        .false_value => {},
                    }
                }
            }
            if (found) return .true_value;
            if (failed) return .unknown;
            return .false_value;
        }

        fn startsWith(whole: Item, initial: Item) Tri {
            if (tagOf(whole) != .string or tagOf(initial) != .string) return .unknown;
            const text = stringOf(whole);
            const prefix = stringOf(initial);
            return if (text.len >= prefix.len and types.same(text[0..prefix.len], prefix)) .true_value else .false_value;
        }

        const Class = enum { null_value, boolean, number, string, container };

        fn classOf(item: Item) Class {
            return switch (tagOf(item)) {
                .null_value => .null_value,
                .false_value, .true_value => .boolean,
                .number => .number,
                .string => .string,
                .array, .object => .container,
            };
        }

        /// compareItems: NULL against a non-NULL is false (true for !=),
        /// other mixed or container operands are unknown; strings compare
        /// bytewise (UTF-8 code point order).
        fn compareItems(op: Kind, a: Item, b: Item) Tri {
            const x = classOf(a);
            const y = classOf(b);
            if (x != y) {
                if (x == .null_value or y == .null_value) return if (op == .ne) .true_value else .false_value;
                return .unknown;
            }
            const order: i8 = switch (x) {
                .null_value => 0,
                .boolean => blk: {
                    const p = tagOf(a) == .true_value;
                    const q = tagOf(b) == .true_value;
                    break :blk if (p == q) 0 else if (p) 1 else -1;
                },
                .number => blk: {
                    const p = numberOf(a);
                    const q = numberOf(b);
                    break :blk numeric.compareValues(&p, &q);
                },
                .string => types.bytesOrder(stringOf(a), stringOf(b)),
                .container => return .unknown,
            };
            const result = switch (op) {
                .eq => order == 0,
                .ne => order != 0,
                .lt => order < 0,
                .gt => order > 0,
                .le => order <= 0,
                else => order >= 0,
            };
            return if (result) .true_value else .false_value;
        }
    };
}
