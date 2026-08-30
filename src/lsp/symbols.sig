//! Sig declaration scanner for document symbols — Layer 0 (pure, no allocator).
//!
//! A small, allocator-free lexer that extracts declarations (`const`, `var`,
//! `fn`) from Sig source and classifies each by a cheap look at the
//! initializer (`fn` → Function, `= struct` → Struct, `= enum` → Enum,
//! `= union` → Interface, otherwise Constant/Variable). Byte offsets are
//! returned so callers can map them to LSP positions. Reusable by any Sig LSP
//! server; it never allocates.

const std = @import("std");

/// LSP SymbolKind numeric codes (subset).
pub const SymbolKind = enum(u8) {
    Function = 12,
    Variable = 13,
    Constant = 14,
    Struct = 23,
    Enum = 10,
    Interface = 11,
    Field = 8,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// Byte offset of the declaration keyword.
    decl_offset: usize,
    /// Byte offset of the identifier start.
    name_offset: usize,
    /// Nesting depth (0 = top level).
    depth: u16,
};

pub const MAX_SYMBOLS = 512;

pub const Scan = struct {
    items: [MAX_SYMBOLS]Symbol = undefined,
    len: usize = 0,

    pub fn slice(self: *const Scan) []const Symbol {
        return self.items[0..self.len];
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn readIdent(src: []const u8, i: usize) struct { name: []const u8, end: usize } {
    var j = i;
    while (j < src.len and isIdentChar(src[j])) : (j += 1) {}
    return .{ .name = src[i..j], .end = j };
}

fn matchKeyword(src: []const u8, i: usize, word: []const u8) bool {
    if (i + word.len > src.len) return false;
    if (!std.mem.eql(u8, src[i .. i + word.len], word)) return false;
    const after = i + word.len;
    if (after < src.len and isIdentChar(src[after])) return false;
    if (i > 0 and isIdentChar(src[i - 1])) return false;
    return true;
}

fn classifyValue(src: []const u8, after_name: usize) SymbolKind {
    var i = after_name;
    while (i < src.len and src[i] != '=' and src[i] != ';' and src[i] != '{') : (i += 1) {}
    if (i >= src.len or src[i] != '=') return .Constant;
    i += 1;
    while (i < src.len and isSpace(src[i])) : (i += 1) {}
    if (matchKeyword(src, i, "struct") or matchKeyword(src, i, "packed") or matchKeyword(src, i, "extern")) return .Struct;
    if (matchKeyword(src, i, "enum")) return .Enum;
    if (matchKeyword(src, i, "union")) return .Interface;
    return .Constant;
}

/// Scan `src` for declarations, filling `out`. Tracks brace depth so nested
/// declarations (methods, struct-level decls) are reported with depth > 0.
pub fn scan(src: []const u8, out: *Scan) void {
    out.len = 0;
    var depth: u16 = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '"') {
            i += 1;
            while (i < src.len and src[i] != '"') : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) i += 1;
            }
            i += 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }

        if (isIdentStart(c) and (i == 0 or !isIdentChar(src[i - 1]))) {
            const word = readIdent(src, i);
            const is_fn = std.mem.eql(u8, word.name, "fn");
            const is_const = std.mem.eql(u8, word.name, "const");
            const is_var = std.mem.eql(u8, word.name, "var");
            if (is_fn or is_const or is_var) {
                const decl_offset = i;
                var k = word.end;
                while (k < src.len and isSpace(src[k])) : (k += 1) {}
                if (k < src.len and isIdentStart(src[k])) {
                    const ident = readIdent(src, k);
                    const kind: SymbolKind = if (is_fn)
                        .Function
                    else if (is_var)
                        .Variable
                    else
                        classifyValue(src, ident.end);
                    if (out.len < MAX_SYMBOLS) {
                        out.items[out.len] = .{
                            .name = ident.name,
                            .kind = kind,
                            .decl_offset = decl_offset,
                            .name_offset = k,
                            .depth = depth,
                        };
                        out.len += 1;
                    }
                    i = ident.end;
                    continue;
                }
            }
            i = word.end;
            continue;
        }

        i += 1;
    }
}

test "scans top level declarations with kinds" {
    const src =
        \\const std = @import("std");
        \\pub const Point = struct {
        \\    x: i32,
        \\};
        \\pub fn main() void {}
        \\var counter: u32 = 0;
        \\const Color = enum { red, green };
    ;
    var s: Scan = .{};
    scan(src, &s);
    const items = s.slice();
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("std", items[0].name);
    try std.testing.expectEqual(SymbolKind.Constant, items[0].kind);
    try std.testing.expectEqualStrings("Point", items[1].name);
    try std.testing.expectEqual(SymbolKind.Struct, items[1].kind);
    try std.testing.expectEqualStrings("main", items[2].name);
    try std.testing.expectEqual(SymbolKind.Function, items[2].kind);
    try std.testing.expectEqualStrings("counter", items[3].name);
    try std.testing.expectEqual(SymbolKind.Variable, items[3].kind);
    try std.testing.expectEqualStrings("Color", items[4].name);
    try std.testing.expectEqual(SymbolKind.Enum, items[4].kind);
}

test "ignores keywords in comments and strings" {
    const src =
        \\// const commented = 1;
        \\const real = "const inside string fn also";
    ;
    var s: Scan = .{};
    scan(src, &s);
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("real", s.slice()[0].name);
}

test "tracks nesting depth for methods" {
    const src =
        \\pub const S = struct {
        \\    pub fn method(self: S) void {}
        \\};
    ;
    var s: Scan = .{};
    scan(src, &s);
    const items = s.slice();
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(u16, 0), items[0].depth);
    try std.testing.expectEqual(@as(u16, 1), items[1].depth);
    try std.testing.expectEqualStrings("method", items[1].name);
}
