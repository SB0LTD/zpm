//! XPath 1.0 (Layer 0, B11 wave 5 xml lane), as libxml2 2.9 compiles and
//! evaluates it for PostgreSQL 18's xpath(), xpath_exists(), XMLEXISTS and
//! XMLTABLE, over an xml_tree.sig tree. No libxml2: a recursive-descent
//! compiler (libxml2's grammar and quirks: operator names need no word
//! boundary, a number may carry an exponent, '/' continues only before an
//! ASCII letter, '_', '.', '@' or '*', a name followed by '(' is a function
//! unless it is a node type) into a bounded node array, and an evaluator of
//! node sets (in document order, without duplicates), numbers, booleans and
//! strings with XPath 1.0 conversion and comparison rules, every axis,
//! name and node-type tests, predicates with proximity positions, and the
//! core function library (libxml2's number formatting and parsing,
//! substring/round rounding, xml:id for id()).
//!
//! A syntax error or an undeclared prefix is a compile error; an unknown
//! function, a wrong argument count or type and a variable reference fail
//! only when evaluated (libxml2 registers no variables for PostgreSQL).
//! Both are InvalidArgumentForXquery (10608). Expression nodes, syntax
//! depth, node sets and strings are bounded by caller storage (54000
//! beyond). Every node visited passes a work checkpoint.
const std = @import("std");
const types = @import("types.sig");
const tree_module = @import("xml_tree.sig");
const float_text = @import("float_text.sig");
const Error = types.Error;
const Tree = tree_module.Tree;
const none = tree_module.none;

/// The tree this engine evaluates over (xml_tree.sig).
pub const xml_tree = tree_module;

pub const nil: u16 = 0xffff;

pub const Op = enum(u8) { number, literal, variable, or_op, and_op, eq, ne, lt, le, gt, ge, add, sub, mul, div, mod, neg, plus, union_op, path, step, filter, call };
pub const Axis = enum(u8) { ancestor, ancestor_or_self, attribute, child, descendant, descendant_or_self, following, following_sibling, namespace, parent, preceding, preceding_sibling, self };
pub const Test = enum(u8) { all, name, node, text, comment, pi, pi_named };

pub const Expr = struct {
    op: Op,
    axis: Axis = .child,
    node_test: Test = .node,
    absolute: bool = false,
    a: u16 = nil,
    b: u16 = nil,
    next: u16 = nil,
    /// Literal content, name-test local name, function or variable name.
    start: u32 = 0,
    len: u32 = 0,
    /// Name-test or function prefix (len 0: none).
    prefix_start: u32 = 0,
    prefix_len: u32 = 0,
    number: f64 = 0,
};

/// A namespace registration (PostgreSQL's nsarray / XMLNAMESPACES).
pub const Binding = struct { prefix: []const u8, uri: []const u8 };

pub const Compiled = struct {
    text: []const u8,
    exprs: []Expr,
    root: u16 = nil,

    fn slice(self: *const Compiled, start: u32, len: u32) []const u8 {
        return self.text[start..][0..len];
    }
};

fn fail() Error {
    return error.InvalidArgumentForXquery;
}

fn blank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn letter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c >= 0x80;
}

fn digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn ncChar(c: u8) bool {
    return letter(c) or digit(c) or c == '.' or c == '-' or c == '_';
}

fn nodeType(name: []const u8) bool {
    return types.same(name, "node") or types.same(name, "text") or types.same(name, "comment") or types.same(name, "processing-instruction");
}

fn axisNamed(name: []const u8) ?Axis {
    const table = [_]struct { name: []const u8, axis: Axis }{
        .{ .name = "ancestor", .axis = .ancestor },               .{ .name = "ancestor-or-self", .axis = .ancestor_or_self },
        .{ .name = "attribute", .axis = .attribute },             .{ .name = "child", .axis = .child },
        .{ .name = "descendant", .axis = .descendant },           .{ .name = "descendant-or-self", .axis = .descendant_or_self },
        .{ .name = "following", .axis = .following },             .{ .name = "following-sibling", .axis = .following_sibling },
        .{ .name = "namespace", .axis = .namespace },             .{ .name = "parent", .axis = .parent },
        .{ .name = "preceding", .axis = .preceding },             .{ .name = "preceding-sibling", .axis = .preceding_sibling },
        .{ .name = "self", .axis = .self },
    };
    for (table) |entry| if (types.same(entry.name, name)) return entry.axis;
    return null;
}

// ---- compiler ---------------------------------------------------------------

const Parser = struct {
    text: []const u8,
    at: usize = 0,
    exprs: []Expr,
    count: usize = 0,
    bindings: []const Binding,
    depth: usize = 0,
    depth_limit: usize,

    fn cur(self: *const Parser) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn nxt(self: *const Parser, offset: usize) u8 {
        return if (self.at + offset < self.text.len) self.text[self.at + offset] else 0;
    }

    fn skip(self: *Parser) void {
        while (self.at < self.text.len and blank(self.text[self.at])) self.at += 1;
    }

    fn add(self: *Parser, value: Expr) Error!u16 {
        if (self.count >= self.exprs.len or self.count >= nil) return error.ProgramLimitExceeded;
        self.exprs[self.count] = value;
        self.count += 1;
        return @intCast(self.count - 1);
    }

    fn enter(self: *Parser) Error!void {
        self.depth += 1;
        if (self.depth > self.depth_limit) return error.ProgramLimitExceeded;
    }

    fn leave(self: *Parser) void {
        self.depth -= 1;
    }

    fn binary(self: *Parser, op: Op, left: u16, right: u16) Error!u16 {
        return self.add(.{ .op = op, .a = left, .b = right });
    }

    /// xmlXPathParseNCName: a name without ':'.
    fn ncName(self: *Parser) ?[2]u32 {
        const c = self.cur();
        if (!(letter(c) or c == '_')) return null;
        const start = self.at;
        while (self.at < self.text.len and ncChar(self.text[self.at])) self.at += 1;
        return .{ @intCast(start), @intCast(self.at - start) };
    }

    fn bound(self: *const Parser, prefix: []const u8) bool {
        if (types.same(prefix, "xml")) return true;
        for (self.bindings) |binding| if (types.same(binding.prefix, prefix)) return true;
        return false;
    }

    fn expr(self: *Parser) Error!u16 {
        try self.enter();
        defer self.leave();
        var left = try self.andExpr();
        self.skip();
        while (self.cur() == 'o' and self.nxt(1) == 'r') {
            self.at += 2;
            self.skip();
            left = try self.binary(.or_op, left, try self.andExpr());
            self.skip();
        }
        return left;
    }

    fn andExpr(self: *Parser) Error!u16 {
        var left = try self.equality();
        self.skip();
        while (self.cur() == 'a' and self.nxt(1) == 'n' and self.nxt(2) == 'd') {
            self.at += 3;
            self.skip();
            try self.enter();
            defer self.leave();
            left = try self.binary(.and_op, left, try self.equality());
            self.skip();
        }
        return left;
    }

    fn equality(self: *Parser) Error!u16 {
        var left = try self.relational();
        self.skip();
        while (self.cur() == '=' or (self.cur() == '!' and self.nxt(1) == '=')) {
            const eq = self.cur() == '=';
            self.at += if (eq) 1 else 2;
            self.skip();
            try self.enter();
            defer self.leave();
            left = try self.binary(if (eq) .eq else .ne, left, try self.relational());
            self.skip();
        }
        return left;
    }

    fn relational(self: *Parser) Error!u16 {
        var left = try self.additive();
        self.skip();
        while (self.cur() == '<' or self.cur() == '>') {
            const less = self.cur() == '<';
            const or_equal = self.nxt(1) == '=';
            self.at += if (or_equal) 2 else 1;
            self.skip();
            try self.enter();
            defer self.leave();
            const op: Op = if (less) (if (or_equal) .le else .lt) else (if (or_equal) .ge else .gt);
            left = try self.binary(op, left, try self.additive());
            self.skip();
        }
        return left;
    }

    fn additive(self: *Parser) Error!u16 {
        var left = try self.multiplicative();
        self.skip();
        while (self.cur() == '+' or self.cur() == '-') {
            const plus = self.cur() == '+';
            self.at += 1;
            self.skip();
            try self.enter();
            defer self.leave();
            left = try self.binary(if (plus) .add else .sub, left, try self.multiplicative());
            self.skip();
        }
        return left;
    }

    fn multiplicative(self: *Parser) Error!u16 {
        var left = try self.unary();
        self.skip();
        while (self.cur() == '*' or (self.cur() == 'd' and self.nxt(1) == 'i' and self.nxt(2) == 'v') or
            (self.cur() == 'm' and self.nxt(1) == 'o' and self.nxt(2) == 'd'))
        {
            const op: Op = if (self.cur() == '*') .mul else if (self.cur() == 'd') .div else .mod;
            self.at += if (op == .mul) 1 else 3;
            self.skip();
            try self.enter();
            defer self.leave();
            left = try self.binary(op, left, try self.unary());
            self.skip();
        }
        return left;
    }

    fn unary(self: *Parser) Error!u16 {
        self.skip();
        var minus = false;
        var found = false;
        while (self.cur() == '-') {
            minus = !minus;
            found = true;
            self.at += 1;
            self.skip();
        }
        const operand = try self.unionExpr();
        if (!found) return operand;
        return self.add(.{ .op = if (minus) .neg else .plus, .a = operand });
    }

    fn unionExpr(self: *Parser) Error!u16 {
        var left = try self.pathExpr();
        self.skip();
        while (self.cur() == '|') {
            self.at += 1;
            self.skip();
            try self.enter();
            defer self.leave();
            left = try self.binary(.union_op, left, try self.pathExpr());
            self.skip();
        }
        return left;
    }

    /// xmlXPathScanName's length at the current position (0: no name).
    fn scanName(self: *const Parser) usize {
        const c = self.cur();
        if (c == ' ' or c == '>' or c == '/' or !(letter(c) or c == '_' or c == ':')) return 0;
        var index = self.at;
        while (index < self.text.len) : (index += 1) {
            const k = self.text[index];
            if (k == ' ' or k == '>' or k == '/') break;
            if (!(ncChar(k) or k == ':')) break;
        }
        return index - self.at;
    }

    fn pathExpr(self: *Parser) Error!u16 {
        self.skip();
        const c = self.cur();
        var location = true;
        if (c == '$' or c == '(' or digit(c) or c == '\'' or c == '"' or (c == '.' and digit(self.nxt(1)))) {
            location = false;
        } else if (c == '*' or c == '/' or c == '@' or c == '.') {
            location = true;
        } else {
            const length = self.scanName();
            if (length == 0) return fail();
            const name = self.text[self.at..][0..length];
            if (std.mem.indexOf(u8, name, "::") != null) {
                location = true;
            } else {
                var index = self.at + length;
                location = true;
                while (index < self.text.len) : (index += 1) {
                    const k = self.text[index];
                    if (blank(k)) continue;
                    if (k == '(') location = nodeType(name);
                    break;
                }
            }
        }
        if (location) return self.locationPath();
        var base = try self.filterExpr();
        if (self.cur() == '/') {
            const route = try self.add(.{ .op = .path, .a = base });
            base = route;
            try self.relativePath(route);
        }
        return base;
    }

    fn filterExpr(self: *Parser) Error!u16 {
        const primary = try self.primaryExpr();
        self.skip();
        if (self.cur() != '[') return primary;
        const filtered = try self.add(.{ .op = .filter, .a = primary });
        var last: u16 = nil;
        while (self.cur() == '[') {
            const condition = try self.predicate();
            if (last == nil) self.exprs[filtered].b = condition else self.exprs[last].next = condition;
            last = condition;
            self.skip();
        }
        return filtered;
    }

    fn predicate(self: *Parser) Error!u16 {
        self.at += 1;
        self.skip();
        const inner = try self.expr();
        self.skip();
        if (self.cur() != ']') return fail();
        self.at += 1;
        self.skip();
        return inner;
    }

    fn primaryExpr(self: *Parser) Error!u16 {
        self.skip();
        const c = self.cur();
        var result: u16 = nil;
        if (c == '$') {
            self.at += 1;
            const name = self.ncName() orelse return fail();
            var value: Expr = .{ .op = .variable, .start = name[0], .len = name[1] };
            if (self.cur() == ':') {
                self.at += 1;
                const local = self.ncName() orelse return fail();
                value.prefix_start = name[0];
                value.prefix_len = name[1];
                value.start = local[0];
                value.len = local[1];
            }
            result = try self.add(value);
        } else if (c == '(') {
            self.at += 1;
            self.skip();
            result = try self.expr();
            if (self.cur() != ')') return fail();
            self.at += 1;
        } else if (digit(c) or (c == '.' and digit(self.nxt(1)))) {
            result = try self.add(.{ .op = .number, .number = self.number() });
        } else if (c == '\'' or c == '"') {
            const quoted = try self.literal();
            result = try self.add(.{ .op = .literal, .start = quoted[0], .len = quoted[1] });
        } else {
            result = try self.functionCall();
        }
        self.skip();
        return result;
    }

    fn literal(self: *Parser) Error![2]u32 {
        const quote = self.cur();
        self.at += 1;
        const start = self.at;
        while (self.at < self.text.len and self.text[self.at] != quote) self.at += 1;
        if (self.at >= self.text.len) return fail();
        const span: [2]u32 = .{ @intCast(start), @intCast(self.at - start) };
        self.at += 1;
        return span;
    }

    /// xmlXPathCompNumber: digits, an optional fraction (at most 20
    /// significant fraction digits after leading zeros) and exponent.
    fn number(self: *Parser) f64 {
        var end = self.at;
        const value = parseNumber(self.text, &end, false);
        self.at = end;
        return value;
    }

    fn functionCall(self: *Parser) Error!u16 {
        const name = self.ncName() orelse return fail();
        var invocation: Expr = .{ .op = .call, .start = name[0], .len = name[1] };
        if (self.cur() == ':') {
            self.at += 1;
            const local = self.ncName() orelse return fail();
            invocation.prefix_start = name[0];
            invocation.prefix_len = name[1];
            invocation.start = local[0];
            invocation.len = local[1];
            if (!self.bound(self.text[name[0]..][0..name[1]])) return fail();
        }
        self.skip();
        if (self.cur() != '(') return fail();
        self.at += 1;
        self.skip();
        const node = try self.add(invocation);
        var last: u16 = nil;
        if (self.cur() != ')') {
            while (true) {
                const argument = try self.expr();
                if (last == nil) self.exprs[node].a = argument else self.exprs[last].next = argument;
                last = argument;
                self.skip();
                if (self.cur() == ')') break;
                if (self.cur() != ',') return fail();
                self.at += 1;
                self.skip();
            }
        }
        self.at += 1;
        return node;
    }

    fn locationPath(self: *Parser) Error!u16 {
        self.skip();
        const route = try self.add(.{ .op = .path });
        if (self.cur() != '/') {
            try self.relativePath(route);
            return route;
        }
        self.exprs[route].absolute = true;
        while (self.cur() == '/') {
            if (self.nxt(1) == '/') {
                self.at += 2;
                self.skip();
                try self.appendStep(route, try self.add(.{ .op = .step, .axis = .descendant_or_self, .node_test = .node }));
                try self.relativePath(route);
            } else {
                self.at += 1;
                self.skip();
                const c = self.cur();
                if (c != 0 and (letter(c) or c == '_' or c == '.' or c == '@' or c == '*')) try self.relativePath(route);
            }
        }
        return route;
    }

    fn appendStep(self: *Parser, route: u16, item: u16) Error!void {
        var last = self.exprs[route].b;
        if (last == nil) {
            self.exprs[route].b = item;
            return;
        }
        while (self.exprs[last].next != nil) last = self.exprs[last].next;
        self.exprs[last].next = item;
    }

    fn relativePath(self: *Parser, route: u16) Error!void {
        self.skip();
        if (self.cur() == '/' and self.nxt(1) == '/') {
            self.at += 2;
            self.skip();
            try self.appendStep(route, try self.add(.{ .op = .step, .axis = .descendant_or_self, .node_test = .node }));
        } else if (self.cur() == '/') {
            self.at += 1;
            self.skip();
        }
        try self.step(route);
        self.skip();
        while (self.cur() == '/') {
            if (self.nxt(1) == '/') {
                self.at += 2;
                self.skip();
                try self.appendStep(route, try self.add(.{ .op = .step, .axis = .descendant_or_self, .node_test = .node }));
            } else {
                self.at += 1;
                self.skip();
            }
            try self.step(route);
            self.skip();
        }
    }

    fn step(self: *Parser, route: u16) Error!void {
        self.skip();
        if (self.cur() == '.' and self.nxt(1) == '.') {
            self.at += 2;
            self.skip();
            try self.appendStep(route, try self.add(.{ .op = .step, .axis = .parent, .node_test = .node }));
            return;
        }
        if (self.cur() == '.') {
            self.at += 1;
            self.skip();
            return;
        }
        var axis: Axis = .child;
        var name: ?[2]u32 = null;
        if (self.cur() != '*') {
            name = self.ncName();
            if (name) |found| {
                if (axisNamed(self.text[found[0]..][0..found[1]])) |named| {
                    self.skip();
                    if (self.cur() == ':' and self.nxt(1) == ':') {
                        self.at += 2;
                        axis = named;
                        name = null;
                    }
                }
            } else if (self.cur() == '@') {
                self.at += 1;
                axis = .attribute;
            }
        }
        var node: Expr = .{ .op = .step, .axis = axis };
        try self.nodeTest(&node, name);
        const id = try self.add(node);
        self.skip();
        var last: u16 = nil;
        while (self.cur() == '[') {
            const condition = try self.predicate();
            if (last == nil) self.exprs[id].a = condition else self.exprs[last].next = condition;
            last = condition;
        }
        try self.appendStep(route, id);
    }

    fn nodeTest(self: *Parser, node: *Expr, preparsed: ?[2]u32) Error!void {
        self.skip();
        if (preparsed == null and self.cur() == '*') {
            self.at += 1;
            node.node_test = .all;
            return;
        }
        const name = preparsed orelse (self.ncName() orelse return fail());
        const blanks = blank(self.cur());
        self.skip();
        const text = self.text[name[0]..][0..name[1]];
        if (self.cur() == '(') {
            self.at += 1;
            node.node_test = if (types.same(text, "comment")) .comment else if (types.same(text, "node")) .node else if (types.same(text, "processing-instruction")) .pi else if (types.same(text, "text")) .text else return fail();
            self.skip();
            if (node.node_test == .pi and self.cur() != ')') {
                if (self.cur() != '\'' and self.cur() != '"') return fail();
                const quoted = try self.literal();
                node.start = quoted[0];
                node.len = quoted[1];
                node.node_test = .pi_named;
                self.skip();
            }
            if (self.cur() != ')') return fail();
            self.at += 1;
            return;
        }
        node.node_test = .name;
        node.start = name[0];
        node.len = name[1];
        if (!blanks and self.cur() == ':') {
            self.at += 1;
            if (!self.bound(text)) return fail();
            node.prefix_start = name[0];
            node.prefix_len = name[1];
            if (self.cur() == '*') {
                self.at += 1;
                node.node_test = .all;
                return;
            }
            const local = self.ncName() orelse return fail();
            node.start = local[0];
            node.len = local[1];
        }
    }
};

/// Compiles `text` (xmlXPathCtxtCompile): the whole text must be one
/// expression.
pub fn compile(text: []const u8, bindings: []const Binding, exprs: []Expr, depth_limit: usize) Error!Compiled {
    var parser: Parser = .{ .text = text, .exprs = exprs, .bindings = bindings, .depth_limit = depth_limit };
    const root = try parser.expr();
    parser.skip();
    if (parser.at != text.len) return fail();
    return .{ .text = text, .exprs = exprs[0..parser.count], .root = root };
}

// ---- numbers ----------------------------------------------------------------

/// pow(10.0, exponent), correctly rounded as glibc returns it: exact up
/// to 1e22, else the nearest double of "1e<exponent>".
fn pow10(exponent: i32) f64 {
    const magnitude: u32 = @intCast(if (exponent < 0) -exponent else exponent);
    if (magnitude <= 22) {
        var exact: f64 = 1;
        for (0..magnitude) |_| exact *= 10;
        return if (exponent < 0) 1 / exact else exact;
    }
    if (exponent > 400) return infinity;
    if (exponent < -400) return 0;
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "1e{d}", .{exponent}) catch return nan;
    return std.fmt.parseFloat(f64, text) catch nan;
}

/// The digits libxml2's number parsers accept at `at.*` (xmlXPathCompNumber
/// and the body of xmlXPathStringEvalNumber): integer digits, then '.' and
/// fraction digits (at most 20 after leading zeros count), then an
/// optional exponent. NaN when there are no digits.
fn parseNumber(text: []const u8, at: *usize, string: bool) f64 {
    _ = string;
    var index = at.*;
    var value: f64 = 0;
    var ok = false;
    while (index < text.len and digit(text[index])) : (index += 1) {
        value = value * 10 + @as(f64, @floatFromInt(text[index] - '0'));
        ok = true;
    }
    if (index < text.len and text[index] == '.') {
        index += 1;
        if ((index >= text.len or !digit(text[index])) and !ok) {
            at.* = index;
            return nan;
        }
        var frac: i32 = 0;
        var fraction: f64 = 0;
        while (index < text.len and text[index] == '0') : (index += 1) frac += 1;
        const max = frac + 20;
        while (index < text.len and digit(text[index]) and frac < max) : (index += 1) {
            fraction = fraction * 10 + @as(f64, @floatFromInt(text[index] - '0'));
            frac += 1;
        }
        fraction /= pow10(frac);
        value += fraction;
        while (index < text.len and digit(text[index])) index += 1;
    }
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        var negative = false;
        if (index < text.len and text[index] == '-') {
            negative = true;
            index += 1;
        } else if (index < text.len and text[index] == '+') index += 1;
        var exponent: i32 = 0;
        while (index < text.len and digit(text[index])) : (index += 1) {
            if (exponent < 1000000) exponent = exponent * 10 + @as(i32, text[index] - '0');
        }
        value *= pow10(if (negative) -exponent else exponent);
    }
    at.* = index;
    return value;
}

const nan: f64 = @bitCast(@as(u64, 0x7ff8000000000000));
const infinity: f64 = @bitCast(@as(u64, 0x7ff0000000000000));

fn isNan(value: f64) bool {
    return value != value;
}

fn isInf(value: f64) bool {
    return value == infinity or value == -infinity;
}

fn negativeBit(value: f64) bool {
    return @as(u64, @bitCast(value)) >> 63 != 0;
}

/// xmlXPathStringEvalNumber: the number of a string (NaN unless it is
/// optional blanks, an optional '-', a number, optional blanks).
pub fn stringNumber(text: []const u8) f64 {
    var index: usize = 0;
    while (index < text.len and blank(text[index])) index += 1;
    if (index >= text.len) return nan;
    const c = text[index];
    if (c != '.' and !digit(c) and c != '-') return nan;
    var negative = false;
    if (c == '-') {
        negative = true;
        index += 1;
    }
    var value: f64 = 0;
    if (index < text.len and text[index] == '.' and (index + 1 >= text.len or !digit(text[index + 1]))) return nan;
    value = parseNumber(text, &index, true);
    if (isNan(value)) return nan;
    while (index < text.len and blank(text[index])) index += 1;
    if (index != text.len) return nan;
    return if (negative) -value else value;
}

/// xmlXPathFormatNumber (xmlXPathCastNumberToString): integers in int
/// range plainly, other values with 15 significant digits, in fixed
/// notation between 1e-5 and 1e9 and scientific outside, trailing zeros
/// removed.
pub fn formatNumber(value: f64, out: []u8) []const u8 {
    if (isNan(value)) return copy(out, "NaN");
    if (value == infinity) return copy(out, "Infinity");
    if (value == -infinity) return copy(out, "-Infinity");
    if (value == 0) return copy(out, "0");
    if (value > -2147483648.0 and value < 2147483647.0 and value == @trunc(value)) {
        const integer: i64 = @intFromFloat(value);
        return integerText(integer, out);
    }
    const magnitude = @abs(value);
    var at: usize = 0;
    if (value < 0) {
        out[0] = '-';
        at = 1;
    }
    if (magnitude > 1e9 or magnitude < 1e-5) {
        // %.14e, then fraction zeros removed.
        var digits: [16]u8 = undefined;
        const rounded = float_text.roundedDigits(magnitude, 15, &digits);
        out[at] = digits[0];
        at += 1;
        if (rounded.len > 1) {
            out[at] = '.';
            at += 1;
            @memcpy(out[at..][0 .. rounded.len - 1], digits[1..rounded.len]);
            at += rounded.len - 1;
        }
        out[at] = 'e';
        out[at + 1] = if (rounded.exponent < 0) '-' else '+';
        at += 2;
        const e: u32 = @intCast(if (rounded.exponent < 0) -rounded.exponent else rounded.exponent);
        if (e >= 100) {
            out[at] = @intCast('0' + e / 100);
            at += 1;
        }
        out[at] = @intCast('0' + (e / 10) % 10);
        out[at + 1] = @intCast('0' + e % 10);
        return out[0 .. at + 2];
    }
    // %0.*f with DBL_DIG - integer_place (- 1) fraction digits.
    const integer_place: i32 = @intFromFloat(@trunc(std.math.log10(magnitude)));
    const places: u32 = @intCast(if (integer_place > 0) 15 - integer_place - 1 else 15 - integer_place);
    const bits: u64 = @bitCast(magnitude);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    const mantissa: u128 = (bits & 0xfffffffffffff) | (@as(u64, 1) << 52);
    const shift: u32 = @intCast(1075 - biased);
    var scaled = mantissa;
    for (0..places) |_| scaled *= 10;
    var quotient = scaled >> @intCast(shift);
    const remainder = scaled & ((@as(u128, 1) << @intCast(shift)) - 1);
    const half = @as(u128, 1) << @intCast(shift - 1);
    if (remainder > half or (remainder == half and quotient & 1 != 0)) quotient += 1;
    var digits: [48]u8 = undefined;
    var count: usize = 0;
    while (quotient != 0 or count <= places) : (quotient /= 10) {
        digits[count] = @intCast('0' + @as(u8, @intCast(quotient % 10)));
        count += 1;
    }
    // digits are reversed: the last `places` written first are the fraction.
    var index = count;
    while (index > places) {
        index -= 1;
        out[at] = digits[index];
        at += 1;
    }
    var fraction_end: usize = 0;
    while (fraction_end < places and digits[fraction_end] == '0') fraction_end += 1;
    if (fraction_end < places) {
        out[at] = '.';
        at += 1;
        var position = places;
        while (position > fraction_end) {
            position -= 1;
            out[at] = digits[position];
            at += 1;
        }
    }
    return out[0..at];
}

fn copy(out: []u8, text: []const u8) []const u8 {
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

fn integerText(value: i64, out: []u8) []const u8 {
    var buffer: [24]u8 = undefined;
    var index: usize = buffer.len;
    var rest: u64 = @abs(value);
    while (true) {
        index -= 1;
        buffer[index] = @intCast('0' + rest % 10);
        rest /= 10;
        if (rest == 0) break;
    }
    if (value < 0) {
        index -= 1;
        buffer[index] = '-';
    }
    return copy(out, buffer[index..]);
}

// ---- evaluation -------------------------------------------------------------

/// Caller-owned evaluation storage: node sets (u32 items) and strings,
/// allocated and released in stack order.
pub const Space = struct {
    bytes: []u8,
    used: usize = 0,

    pub fn mark(self: *const Space) usize {
        return self.used;
    }

    pub fn release(self: *Space, to: usize) void {
        self.used = to;
    }

    pub fn take(self: *Space, length: usize) Error![]u8 {
        if (length > self.bytes.len - self.used) return error.ProgramLimitExceeded;
        const out = self.bytes[self.used..][0..length];
        self.used += length;
        return out;
    }

    fn alignNodes(self: *Space) Error!void {
        const base = @intFromPtr(self.bytes.ptr) + self.used;
        const pad = (4 - base % 4) % 4;
        _ = try self.take(pad);
    }

    /// The u32 slots from `start` (aligned) to the current end.
    fn slots(self: *Space, start: usize, count: usize) []u32 {
        const pointer: [*]u32 = @ptrCast(@alignCast(self.bytes.ptr + start));
        return pointer[0..count];
    }

    fn push(self: *Space, start: usize, count: *usize, item: u32) Error!void {
        _ = try self.take(4);
        self.slots(start, count.* + 1)[count.*] = item;
        count.* += 1;
    }
};

pub const Value = union(enum) {
    nodes: []u32,
    number: f64,
    boolean: bool,
    string: []const u8,
};

pub const Context = struct {
    tree: *Tree,
    space: *Space,
    path: *const Compiled,
    bindings: []const Binding,
    control: ?*types.ExecutionControl = null,
    /// The tree's parsed nodes (namespace-axis nodes come after).
    parsed: u32 = 0,

    fn checkpoint(self: *const Context) Error!void {
        if (self.control) |control| try control.checkpoint();
    }

    fn expr(self: *const Context, id: u16) *const Expr {
        return &self.path.exprs[id];
    }

    fn text(self: *const Context, start: u32, len: u32) []const u8 {
        return self.path.slice(start, len);
    }

    fn uri(self: *const Context, prefix: []const u8) ?[]const u8 {
        if (types.same(prefix, "xml")) return tree_module.xml_namespace_uri;
        // A prefix registered again replaces its URI (xmlHashUpdateEntry).
        var index = self.bindings.len;
        while (index > 0) {
            index -= 1;
            if (types.same(self.bindings[index].prefix, prefix)) return self.bindings[index].uri;
        }
        return null;
    }
};

const Focus = struct { node: u32, position: usize, size: usize };

/// Evaluates the compiled expression with `node` as the context node.
pub fn evaluate(ctx: *Context, node: u32) Error!Value {
    if (ctx.parsed == 0) ctx.parsed = ctx.tree.count;
    return eval(ctx, ctx.path.root, .{ .node = node, .position = 1, .size = 1 });
}

fn eval(ctx: *Context, id: u16, focus: Focus) Error!Value {
    try ctx.checkpoint();
    const e = ctx.expr(id);
    switch (e.op) {
        .number => return .{ .number = e.number },
        .literal => return .{ .string = ctx.text(e.start, e.len) },
        .variable => return fail(),
        .or_op, .and_op => {
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            const left = try toBoolean(ctx, try eval(ctx, e.a, focus));
            if (e.op == .or_op and left) return .{ .boolean = true };
            if (e.op == .and_op and !left) return .{ .boolean = false };
            return .{ .boolean = try toBoolean(ctx, try eval(ctx, e.b, focus)) };
        },
        .eq, .ne, .lt, .le, .gt, .ge => {
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            const left = try eval(ctx, e.a, focus);
            const right = try eval(ctx, e.b, focus);
            return .{ .boolean = try compare(ctx, e.op, left, right) };
        },
        .add, .sub, .mul, .div, .mod => {
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            const left = try toNumber(ctx, try eval(ctx, e.a, focus));
            const right = try toNumber(ctx, try eval(ctx, e.b, focus));
            return .{ .number = arithmetic(e.op, left, right) };
        },
        .neg, .plus => {
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            const operand = try toNumber(ctx, try eval(ctx, e.a, focus));
            return .{ .number = if (e.op == .neg) -operand else operand };
        },
        .union_op => {
            const mark = ctx.space.mark();
            const left = try eval(ctx, e.a, focus);
            const right = try eval(ctx, e.b, focus);
            if (left != .nodes or right != .nodes) return fail();
            return .{ .nodes = try unite(ctx, mark, left.nodes, right.nodes) };
        },
        .path => return .{ .nodes = try evalPath(ctx, e, focus) },
        .filter => {
            const mark = ctx.space.mark();
            const base = try eval(ctx, e.a, focus);
            if (base != .nodes) return fail();
            const kept = try applyPredicates(ctx, base.nodes, e.b, false);
            return .{ .nodes = try compact(ctx, mark, kept) };
        },
        .step => return fail(),
        .call => return callFunction(ctx, e, focus),
    }
}

fn arithmetic(op: Op, a: f64, b: f64) f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => divide(a, b),
        else => modulo(a, b),
    };
}

fn divide(a: f64, b: f64) f64 {
    if (b == 0) {
        if (a == 0 or isNan(a)) return nan;
        return if (negativeBit(a) != negativeBit(b)) -infinity else infinity;
    }
    return a / b;
}

/// C fmod: the sign of the dividend.
fn modulo(a: f64, b: f64) f64 {
    if (isNan(a) or isNan(b) or isInf(a) or b == 0) return nan;
    if (isInf(b)) return a;
    return @rem(a, b);
}

/// Moves a node set allocated above `mark` down to it.
fn compact(ctx: *Context, mark: usize, items: []u32) Error![]u32 {
    ctx.space.release(mark);
    try ctx.space.alignNodes();
    const start = ctx.space.used;
    const out = ctx.space.slots(start, items.len);
    if (items.len != 0 and @intFromPtr(out.ptr) != @intFromPtr(items.ptr)) {
        for (0..items.len) |index| out[index] = items[index];
    }
    _ = try ctx.space.take(items.len * 4);
    return out;
}

/// The union of two document-ordered sets, placed at `mark`.
fn unite(ctx: *Context, mark: usize, left: []u32, right: []u32) Error![]u32 {
    try ctx.space.alignNodes();
    const start = ctx.space.used;
    var count: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < left.len or j < right.len) {
        try ctx.checkpoint();
        var item: u32 = undefined;
        if (j >= right.len) {
            item = left[i];
            i += 1;
        } else if (i >= left.len) {
            item = right[j];
            j += 1;
        } else {
            const order = tree_module.order(ctx.tree, left[i], right[j]);
            if (order <= 0) {
                item = left[i];
                i += 1;
                if (order == 0) j += 1;
            } else {
                item = right[j];
                j += 1;
            }
        }
        try ctx.space.push(start, &count, item);
    }
    return compact(ctx, mark, ctx.space.slots(start, count));
}

/// Sorts a node set into document order and removes duplicates in place.
fn normalize(ctx: *Context, items: []u32) Error!usize {
    if (items.len < 2) return items.len;
    var sorted = true;
    for (1..items.len) |index| {
        if (tree_module.order(ctx.tree, items[index - 1], items[index]) >= 0) sorted = false;
    }
    if (sorted) return items.len;
    // Insertion sort (no std.sort), dropping duplicates.
    var count: usize = 0;
    for (items) |item| {
        try ctx.checkpoint();
        var position = count;
        var duplicate = false;
        while (position > 0) {
            const order = tree_module.order(ctx.tree, items[position - 1], item);
            if (order == 0) {
                duplicate = true;
                break;
            }
            if (order < 0) break;
            position -= 1;
        }
        if (duplicate) continue;
        var move = count;
        while (move > position) : (move -= 1) items[move] = items[move - 1];
        items[position] = item;
        count += 1;
    }
    return count;
}

fn reverseAxis(axis: Axis) bool {
    return axis == .ancestor or axis == .ancestor_or_self or axis == .preceding or axis == .preceding_sibling;
}

fn evalPath(ctx: *Context, e: *const Expr, focus: Focus) Error![]u32 {
    const mark = ctx.space.mark();
    var current: []u32 = undefined;
    if (e.a != nil) {
        const base = try eval(ctx, e.a, focus);
        if (base != .nodes) return fail();
        current = base.nodes;
    } else {
        try ctx.space.alignNodes();
        const start = ctx.space.used;
        var count: usize = 0;
        try ctx.space.push(start, &count, if (e.absolute) 0 else focus.node);
        current = ctx.space.slots(start, 1);
    }
    var step_id = e.b;
    while (step_id != nil) : (step_id = ctx.expr(step_id).next) {
        current = try compact(ctx, mark, try stepNodes(ctx, ctx.expr(step_id), current));
    }
    return current;
}

/// One location step from every node of `input`: the axis nodes passing
/// the node test and predicates, in document order.
fn stepNodes(ctx: *Context, s: *const Expr, input: []u32) Error![]u32 {
    try ctx.space.alignNodes();
    const start = ctx.space.used;
    var count: usize = 0;
    for (input) |context_node| {
        const before = count;
        try collect(ctx, s, context_node, start, &count);
        if (s.a != nil) {
            const candidates = ctx.space.slots(start + before * 4, count - before);
            const kept = try applyPredicates(ctx, candidates, s.a, reverseAxis(s.axis));
            ctx.space.release(start + (before + kept.len) * 4);
            count = before + kept.len;
        }
        if (reverseAxis(s.axis)) {
            const run = ctx.space.slots(start + before * 4, count - before);
            var low: usize = 0;
            var high = run.len;
            while (low + 1 < high) {
                high -= 1;
                const swap = run[low];
                run[low] = run[high];
                run[high] = swap;
                low += 1;
            }
        }
    }
    const items = ctx.space.slots(start, count);
    const unique = try normalize(ctx, items);
    ctx.space.release(start + unique * 4);
    return items[0..unique];
}

/// Applies predicates in order to `items` (in place); positions follow
/// the given order (reverse document order for reverse axes, already so
/// ordered by collect). Returns the kept prefix.
fn applyPredicates(ctx: *Context, items_in: []u32, first: u16, reverse: bool) Error![]u32 {
    _ = reverse;
    var items = items_in;
    var predicate = first;
    while (predicate != nil) : (predicate = ctx.expr(predicate).next) {
        var kept: usize = 0;
        const size = items.len;
        for (0..size) |index| {
            const node = items[index];
            const mark = ctx.space.mark();
            const value = try eval(ctx, predicate, .{ .node = node, .position = index + 1, .size = size });
            const keep = switch (value) {
                .number => |number| number == @as(f64, @floatFromInt(index + 1)),
                else => try toBoolean(ctx, value),
            };
            ctx.space.release(mark);
            if (keep) {
                items[kept] = node;
                kept += 1;
            }
        }
        items = items[0..kept];
    }
    return items;
}

fn principal(axis: Axis) tree_module.Kind {
    return switch (axis) {
        .attribute => .attribute,
        .namespace => .namespace,
        else => .element,
    };
}

fn matches(ctx: *Context, s: *const Expr, node: u32) bool {
    const tree = ctx.tree;
    const n = tree.node(node);
    switch (s.node_test) {
        .node => return true,
        .text => return n.kind == .text or n.kind == .cdata,
        .comment => return n.kind == .comment,
        .pi => return n.kind == .pi,
        .pi_named => return n.kind == .pi and types.same(tree.qname(node), ctx.text(s.start, s.len)),
        .all => {
            if (n.kind != principal(s.axis)) return false;
            if (s.prefix_len == 0) return true;
            if (n.kind == .namespace) return false;
            const wanted = ctx.uri(ctx.text(s.prefix_start, s.prefix_len)) orelse return false;
            return n.ns != none and types.same(tree.namespaceUri(node), wanted);
        },
        .name => {
            if (n.kind != principal(s.axis)) return false;
            const local = ctx.text(s.start, s.len);
            if (n.kind == .namespace) return s.prefix_len == 0 and types.same(tree.bytes(n.name), local);
            if (!types.same(tree.localName(node), local)) return false;
            if (s.prefix_len == 0) return n.ns == none;
            const wanted = ctx.uri(ctx.text(s.prefix_start, s.prefix_len)) orelse return false;
            return n.ns != none and types.same(tree.namespaceUri(node), wanted);
        },
    }
}

fn add(ctx: *Context, s: *const Expr, node: u32, start: usize, count: *usize) Error!void {
    try ctx.checkpoint();
    if (matches(ctx, s, node)) try ctx.space.push(start, count, node);
}

fn hasChildren(kind: tree_module.Kind) bool {
    return kind == .element or kind == .document;
}

/// The nodes of `s.axis` from `node` that pass the node test, in axis
/// order (reverse document order for reverse axes), appended at `start`.
fn collect(ctx: *Context, s: *const Expr, node: u32, start: usize, count: *usize) Error!void {
    const tree = ctx.tree;
    const n = tree.node(node);
    const attached = n.kind == .attribute or n.kind == .namespace;
    switch (s.axis) {
        .self => try add(ctx, s, node, start, count),
        .child => if (hasChildren(n.kind)) {
            var at = n.first;
            while (at != none) : (at = tree.node(at).next) try add(ctx, s, at, start, count);
        },
        .descendant, .descendant_or_self => {
            if (s.axis == .descendant_or_self) try add(ctx, s, node, start, count);
            if (attached or !hasChildren(n.kind)) return;
            var at = n.first;
            while (at != none) {
                try add(ctx, s, at, start, count);
                if (tree.node(at).kind == .element and tree.node(at).first != none) {
                    at = tree.node(at).first;
                    continue;
                }
                at = tree.following(at, node);
            }
        },
        .parent => if (n.parent != none and n.kind != .document) try add(ctx, s, n.parent, start, count),
        .ancestor, .ancestor_or_self => {
            if (s.axis == .ancestor_or_self) try add(ctx, s, node, start, count);
            if (n.kind == .document) return;
            var at = n.parent;
            while (at != none) : (at = tree.node(at).parent) try add(ctx, s, at, start, count);
        },
        .following_sibling, .preceding_sibling => {
            if (attached or n.kind == .document) return;
            var at = if (s.axis == .following_sibling) n.next else n.prev;
            while (at != none) : (at = if (s.axis == .following_sibling) tree.node(at).next else tree.node(at).prev) try add(ctx, s, at, start, count);
        },
        .following => {
            // libxml2 2.9: from an attribute or namespace node, after its
            // element's subtree.
            const from = if (attached) n.parent else node;
            if (tree.node(from).kind == .document) return;
            var at = tree.following(from, none);
            while (at != none) {
                if (tree.node(at).kind == .document) break;
                try add(ctx, s, at, start, count);
                if (tree.node(at).kind == .element and tree.node(at).first != none) {
                    at = tree.node(at).first;
                    continue;
                }
                at = tree.following(at, none);
            }
        },
        .preceding => {
            // xmlXPathNextPrecedingInternal: reverse document order,
            // ancestors skipped, stopping at the document's first child.
            var cur = if (attached) n.parent else node;
            if (tree.node(cur).kind == .document) return;
            var ancestor = tree.node(cur).parent;
            const first_child = tree.node(0).first;
            outer: while (true) {
                while (tree.node(cur).prev == none) {
                    cur = tree.node(cur).parent;
                    if (cur == none or cur == 0 or cur == first_child) break :outer;
                    if (cur != ancestor) {
                        try add(ctx, s, cur, start, count);
                        continue :outer;
                    }
                    ancestor = tree.node(cur).parent;
                }
                cur = tree.node(cur).prev;
                while (tree.node(cur).kind == .element and tree.node(cur).last != none) cur = tree.node(cur).last;
                try add(ctx, s, cur, start, count);
            }
        },
        .attribute => if (n.kind == .element) {
            var at = n.attrs;
            while (at != none) : (at = tree.node(at).next) try add(ctx, s, at, start, count);
        },
        .namespace => if (n.kind == .element) {
            var at = try tree_module.namespaces(tree, node);
            while (at != none) : (at = tree.node(at).next) try add(ctx, s, at, start, count);
        },
    }
}

// ---- conversions ------------------------------------------------------------

/// The string-value of a node, in evaluation storage when computed.
pub fn nodeString(ctx: *Context, node: u32) Error![]const u8 {
    const n = ctx.tree.node(node);
    switch (n.kind) {
        .element, .document => {
            const start = ctx.space.used;
            var out: tree_module.Out = .{ .bytes = ctx.space.bytes[start..] };
            try ctx.tree.stringValue(node, &out);
            _ = try ctx.space.take(out.len);
            return ctx.space.bytes[start..][0..out.len];
        },
        else => return ctx.tree.bytes(n.value),
    }
}

pub fn toString(ctx: *Context, value: Value) Error![]const u8 {
    switch (value) {
        .string => |text| return text,
        .boolean => |flag| return if (flag) "true" else "false",
        .number => |number| {
            var buffer: [64]u8 = undefined;
            const text = formatNumber(number, &buffer);
            const out = try ctx.space.take(text.len);
            @memcpy(out, text);
            return out;
        },
        .nodes => |items| return if (items.len == 0) "" else nodeString(ctx, items[0]),
    }
}

pub fn toNumber(ctx: *Context, value: Value) Error!f64 {
    switch (value) {
        .number => |number| return number,
        .boolean => |flag| return if (flag) 1 else 0,
        .string => |text| return stringNumber(text),
        .nodes => {
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            return stringNumber(try toString(ctx, value));
        },
    }
}

pub fn toBoolean(ctx: *Context, value: Value) Error!bool {
    _ = ctx;
    return switch (value) {
        .boolean => |flag| flag,
        .number => |number| number != 0 and !isNan(number),
        .string => |text| text.len != 0,
        .nodes => |items| items.len != 0,
    };
}

fn relation(op: Op, a: f64, b: f64) bool {
    return switch (op) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .eq => a == b,
        else => a != b,
    };
}

fn mirror(op: Op) Op {
    return switch (op) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        else => op,
    };
}

/// XPath 1.0 comparisons (xmlXPathEqualValues / xmlXPathCompareValues).
fn compare(ctx: *Context, op: Op, left: Value, right: Value) Error!bool {
    const equality = op == .eq or op == .ne;
    if (left == .nodes or right == .nodes) {
        // The node set first.
        const swapped = left != .nodes;
        const set = if (swapped) right.nodes else left.nodes;
        const other = if (swapped) left else right;
        const relop = if (swapped) mirror(op) else op;
        if (equality and other == .boolean) {
            const flag = set.len != 0;
            return if (op == .eq) flag == other.boolean else flag != other.boolean;
        }
        if (!equality and other == .boolean) {
            const a: f64 = if (set.len != 0) 1 else 0;
            const b: f64 = if (other.boolean) 1 else 0;
            return relation(relop, a, b);
        }
        if (other == .nodes) {
            // Some pair satisfies the relation.
            for (set) |x| {
                try ctx.checkpoint();
                const mark = ctx.space.mark();
                defer ctx.space.release(mark);
                const xs = try nodeString(ctx, x);
                for (other.nodes) |y| {
                    try ctx.checkpoint();
                    const inner = ctx.space.mark();
                    defer ctx.space.release(inner);
                    const ys = try nodeString(ctx, y);
                    if (equality) {
                        if (types.same(xs, ys) == (op == .eq)) return true;
                    } else if (relation(relop, stringNumber(xs), stringNumber(ys))) return true;
                }
            }
            return false;
        }
        for (set) |x| {
            try ctx.checkpoint();
            const mark = ctx.space.mark();
            defer ctx.space.release(mark);
            const xs = try nodeString(ctx, x);
            if (equality and other == .string) {
                if (types.same(xs, other.string) == (op == .eq)) return true;
                continue;
            }
            const xn = stringNumber(xs);
            const on = try toNumber(ctx, other);
            if (equality) {
                if (isNan(xn)) {
                    if (op == .ne) return true;
                    continue;
                }
                if ((op == .eq) == (xn == on)) return true;
                continue;
            }
            if (relation(relop, xn, on)) return true;
        }
        return false;
    }
    if (equality) {
        var same: bool = undefined;
        if (left == .boolean or right == .boolean) {
            same = (try toBoolean(ctx, left)) == (try toBoolean(ctx, right));
        } else if (left == .number or right == .number) {
            same = (try toNumber(ctx, left)) == (try toNumber(ctx, right));
        } else {
            same = types.same(left.string, right.string);
        }
        return if (op == .eq) same else !same;
    }
    return relation(op, try toNumber(ctx, left), try toNumber(ctx, right));
}

// ---- functions --------------------------------------------------------------

const Function = enum { last, position, count, id, local_name, namespace_uri, name, string, concat, starts_with, contains, substring_before, substring_after, substring, string_length, normalize_space, translate, boolean, not_fn, true_fn, false_fn, lang, number, sum, floor, ceiling, round };

fn functionNamed(name: []const u8) ?Function {
    const table = [_]struct { name: []const u8, f: Function }{
        .{ .name = "last", .f = .last },                         .{ .name = "position", .f = .position },
        .{ .name = "count", .f = .count },                       .{ .name = "id", .f = .id },
        .{ .name = "local-name", .f = .local_name },             .{ .name = "namespace-uri", .f = .namespace_uri },
        .{ .name = "name", .f = .name },                         .{ .name = "string", .f = .string },
        .{ .name = "concat", .f = .concat },                     .{ .name = "starts-with", .f = .starts_with },
        .{ .name = "contains", .f = .contains },                 .{ .name = "substring-before", .f = .substring_before },
        .{ .name = "substring-after", .f = .substring_after },   .{ .name = "substring", .f = .substring },
        .{ .name = "string-length", .f = .string_length },       .{ .name = "normalize-space", .f = .normalize_space },
        .{ .name = "translate", .f = .translate },               .{ .name = "boolean", .f = .boolean },
        .{ .name = "not", .f = .not_fn },                        .{ .name = "true", .f = .true_fn },
        .{ .name = "false", .f = .false_fn },                    .{ .name = "lang", .f = .lang },
        .{ .name = "number", .f = .number },                     .{ .name = "sum", .f = .sum },
        .{ .name = "floor", .f = .floor },                       .{ .name = "ceiling", .f = .ceiling },
        .{ .name = "round", .f = .round },
    };
    for (table) |entry| if (types.same(entry.name, name)) return entry.f;
    return null;
}

/// Bytes of the UTF-8 character starting with `c`.
fn charLength(c: u8) usize {
    return if (c < 0xc0) 1 else if (c < 0xe0) 2 else if (c < 0xf0) 3 else 4;
}

fn characters(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += charLength(text[index])) count += 1;
    return count;
}

/// The byte offset of character `position` (0-based; clamped).
fn charOffset(text: []const u8, position: usize) usize {
    var index: usize = 0;
    var seen: usize = 0;
    while (index < text.len and seen < position) : (seen += 1) index += @min(charLength(text[index]), text.len - index);
    return index;
}

fn stringResult(ctx: *Context, parts: []const []const u8) Error!Value {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    const out = try ctx.space.take(total);
    var at: usize = 0;
    for (parts) |part| {
        @memcpy(out[at..][0..part.len], part);
        at += part.len;
    }
    return .{ .string = out };
}

fn callFunction(ctx: *Context, e: *const Expr, focus: Focus) Error!Value {
    // Arguments are evaluated first (libxml2), then the function resolved.
    var args: [16]Value = undefined;
    var count: usize = 0;
    var item = e.a;
    while (item != nil) : (item = ctx.expr(item).next) {
        if (count == args.len) return error.ProgramLimitExceeded;
        args[count] = try eval(ctx, item, focus);
        count += 1;
    }
    if (e.prefix_len != 0) return fail();
    const which = functionNamed(ctx.text(e.start, e.len)) orelse return fail();
    const a = args[0..count];
    switch (which) {
        .last, .position, .true_fn, .false_fn => {
            if (count != 0) return fail();
            return switch (which) {
                .last => .{ .number = @floatFromInt(focus.size) },
                .position => .{ .number = @floatFromInt(focus.position) },
                .true_fn => .{ .boolean = true },
                else => .{ .boolean = false },
            };
        },
        .count, .sum => {
            if (count != 1 or a[0] != .nodes) return fail();
            if (which == .count) return .{ .number = @floatFromInt(a[0].nodes.len) };
            var total: f64 = 0;
            for (a[0].nodes) |node| {
                const mark = ctx.space.mark();
                defer ctx.space.release(mark);
                total += stringNumber(try nodeString(ctx, node));
            }
            return .{ .number = total };
        },
        .local_name, .namespace_uri, .name => {
            if (count > 1) return fail();
            var node: u32 = focus.node;
            if (count == 1) {
                if (a[0] != .nodes) return fail();
                if (a[0].nodes.len == 0) return .{ .string = "" };
                node = a[0].nodes[0];
            }
            const n = ctx.tree.node(node);
            return switch (which) {
                .namespace_uri => .{ .string = if (n.kind == .element or n.kind == .attribute) ctx.tree.namespaceUri(node) else "" },
                .local_name => .{ .string = switch (n.kind) {
                    .element, .attribute, .pi => ctx.tree.localName(node),
                    .namespace => ctx.tree.bytes(n.name),
                    else => "",
                } },
                else => .{ .string = switch (n.kind) {
                    .element, .attribute => if (n.ns != none and ctx.tree.bytes(ctx.tree.node(n.ns).name).len != 0) ctx.tree.qname(node) else ctx.tree.localName(node),
                    .pi => ctx.tree.localName(node),
                    .namespace => ctx.tree.bytes(n.name),
                    else => "",
                } },
            };
        },
        .string, .string_length, .normalize_space, .number => {
            if (count > 1) return fail();
            const source: Value = if (count == 1) a[0] else blk: {
                try ctx.space.alignNodes();
                const at = ctx.space.used;
                var single: usize = 0;
                try ctx.space.push(at, &single, focus.node);
                break :blk .{ .nodes = ctx.space.slots(at, 1) };
            };
            if (which == .number) return .{ .number = try toNumber(ctx, source) };
            const text = try toString(ctx, source);
            return switch (which) {
                .string => .{ .string = text },
                .string_length => .{ .number = @floatFromInt(characters(text)) },
                else => .{ .string = try normalizeSpace(ctx, text) },
            };
        },
        .concat => {
            if (count < 2) return fail();
            var parts: [16][]const u8 = undefined;
            for (a, 0..) |value, index| parts[index] = try toString(ctx, value);
            return stringResult(ctx, parts[0..count]);
        },
        .starts_with, .contains, .substring_before, .substring_after => {
            if (count != 2) return fail();
            const haystack = try toString(ctx, a[0]);
            const needle = try toString(ctx, a[1]);
            const found = std.mem.indexOf(u8, haystack, needle);
            return switch (which) {
                .starts_with => .{ .boolean = haystack.len >= needle.len and types.same(haystack[0..needle.len], needle) },
                .contains => .{ .boolean = found != null },
                .substring_before => .{ .string = if (found) |at| haystack[0..at] else "" },
                else => .{ .string = if (found) |at| haystack[at + needle.len ..] else "" },
            };
        },
        .substring => {
            if (count != 2 and count != 3) return fail();
            const text = try toString(ctx, a[0]);
            const in = try toNumber(ctx, a[1]);
            var i: i64 = 1;
            var j: i64 = 2147483647;
            if (!(in < 2147483647.0)) {
                i = 2147483647;
            } else if (in >= 1.0) {
                i = @intFromFloat(@trunc(in));
                if (in - @floor(in) >= 0.5) i += 1;
            }
            if (count == 3) {
                const le = try toNumber(ctx, a[2]);
                var rin = @floor(in);
                if (in - rin >= 0.5) rin += 1.0;
                var rle = @floor(le);
                if (le - rle >= 0.5) rle += 1.0;
                const end = rin + rle;
                if (!(end >= 1.0)) {
                    j = 1;
                } else if (end < 2147483647.0) j = @intFromFloat(@trunc(end));
            }
            if (i >= j) return .{ .string = "" };
            const from = charOffset(text, @intCast(i - 1));
            const to = charOffset(text, @intCast(@min(j - 1, @as(i64, @intCast(text.len)) + 1)));
            return .{ .string = text[from..@max(from, to)] };
        },
        .translate => {
            if (count != 3) return fail();
            const text = try toString(ctx, a[0]);
            const from = try toString(ctx, a[1]);
            const to = try toString(ctx, a[2]);
            const out = try ctx.space.take(text.len);
            var written: usize = 0;
            var index: usize = 0;
            while (index < text.len) {
                const length = @min(charLength(text[index]), text.len - index);
                const char = text[index..][0..length];
                // Position of the character in `from` (characters).
                var position: ?usize = null;
                var scan: usize = 0;
                var ordinal: usize = 0;
                while (scan < from.len) : (ordinal += 1) {
                    const step_length = @min(charLength(from[scan]), from.len - scan);
                    if (types.same(from[scan..][0..step_length], char)) {
                        position = ordinal;
                        break;
                    }
                    scan += step_length;
                }
                if (position) |p| {
                    const target = charOffset(to, p);
                    if (target < to.len) {
                        const target_length = @min(charLength(to[target]), to.len - target);
                        if (written + target_length > out.len) return error.ProgramLimitExceeded;
                        @memcpy(out[written..][0..target_length], to[target..][0..target_length]);
                        written += target_length;
                    }
                } else {
                    @memcpy(out[written..][0..length], char);
                    written += length;
                }
                index += length;
            }
            return .{ .string = out[0..written] };
        },
        .boolean, .not_fn => {
            if (count != 1) return fail();
            const flag = try toBoolean(ctx, a[0]);
            return .{ .boolean = if (which == .boolean) flag else !flag };
        },
        .lang => {
            if (count != 1) return fail();
            const wanted = try toString(ctx, a[0]);
            var element = focus.node;
            while (element != none) : (element = ctx.tree.node(element).parent) {
                if (ctx.tree.node(element).kind != .element) continue;
                var attribute = ctx.tree.node(element).attrs;
                while (attribute != none) : (attribute = ctx.tree.node(attribute).next) {
                    if (!types.same(ctx.tree.qname(attribute), "xml:lang")) continue;
                    const lang = ctx.tree.bytes(ctx.tree.node(attribute).value);
                    if (lang.len < wanted.len) return .{ .boolean = false };
                    for (wanted, 0..) |c, index| if (types.lower(c) != types.lower(lang[index])) return .{ .boolean = false };
                    return .{ .boolean = lang.len == wanted.len or lang[wanted.len] == '-' };
                }
            }
            return .{ .boolean = false };
        },
        .floor, .ceiling, .round => {
            if (count != 1) return fail();
            const value = try toNumber(ctx, a[0]);
            return .{ .number = switch (which) {
                .floor => @floor(value),
                .ceiling => @ceil(value),
                else => round(value),
            } };
        },
        .id => {
            if (count != 1) return fail();
            return .{ .nodes = try ids(ctx, a[0]) };
        },
    }
}

/// xmlXPathRoundFunction.
fn round(value: f64) f64 {
    if (isNan(value) or isInf(value)) return value;
    if (value >= -0.5 and value < 0.5) return value * 0.0;
    var rounded = @floor(value);
    if (value - rounded >= 0.5) rounded += 1.0;
    return rounded;
}

fn normalizeSpace(ctx: *Context, text: []const u8) Error![]const u8 {
    const out = try ctx.space.take(text.len);
    var written: usize = 0;
    var pending = false;
    for (text) |c| {
        if (blank(c)) {
            pending = written != 0;
            continue;
        }
        if (pending) {
            out[written] = ' ';
            written += 1;
            pending = false;
        }
        out[written] = c;
        written += 1;
    }
    return out[0..written];
}

/// id(): elements whose xml:id attribute equals one of the white-space
/// separated tokens (of each node's string-value for a node set).
fn ids(ctx: *Context, argument: Value) Error![]u32 {
    const mark = ctx.space.mark();
    try ctx.space.alignNodes();
    // Result slots first (at most one per parsed node), strings after.
    const start = ctx.space.used;
    _ = try ctx.space.take(@as(usize, ctx.parsed) * 4);
    const slots = ctx.space.slots(start, ctx.parsed);
    var count: usize = 0;
    const total = if (argument == .nodes) argument.nodes.len else 1;
    for (0..total) |item| {
        const inner = ctx.space.mark();
        defer ctx.space.release(inner);
        const text = if (argument == .nodes) try nodeString(ctx, argument.nodes[item]) else try toString(ctx, argument);
        var index: usize = 0;
        while (index < text.len) {
            while (index < text.len and blank(text[index])) index += 1;
            const token_start = index;
            while (index < text.len and !blank(text[index])) index += 1;
            if (index == token_start) break;
            const token = text[token_start..index];
            var node: u32 = 0;
            while (node < ctx.parsed) : (node += 1) {
                try ctx.checkpoint();
                const n = ctx.tree.node(node);
                if (n.kind != .attribute or !types.same(ctx.tree.qname(node), "xml:id")) continue;
                if (!types.same(ctx.tree.bytes(n.value), token)) continue;
                if (count < slots.len) {
                    slots[count] = n.parent;
                    count += 1;
                }
                break;
            }
        }
    }
    const unique = try normalize(ctx, slots[0..count]);
    return compact(ctx, mark, slots[0..unique]);
}
