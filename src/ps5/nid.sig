//! @zpm/ps5 nid — the names a PlayStation program's linker knows symbols by.
//!
//! A program built for the PS4 or PS5 does not import `sceKernelUsleep`: it
//! imports `1jfXLRVzisc#A#B`. The first eleven characters are the NID, a
//! 64-bit hash of the name; the two fields after it say which library and
//! which module the symbol comes from, as indexes into the importing file's
//! own tables (see elf.sig).
//!
//! The hash is SHA-1 over the name followed by a fixed 16-byte salt; the
//! first eight bytes of the digest, read little-endian, are the NID. Its
//! text is those 64 bits most significant first in base64 with `+` and `-`
//! as the last two digits, eleven characters, no padding. The salt is the
//! public constant every open tool for these files carries; the test
//! vectors below are names whose NIDs are widely published.
//!
//! Everything here also runs at comptime, so a library written in Sig names
//! its exports in plain text and ships a table of 64-bit keys:
//! `nid.of("sceKernelUsleep")`.
//!
//! Allocation-free: plain values.

const std = @import("std");

/// A NID as a number (the form tables are keyed and compared by).
pub const Nid = u64;

/// The characters of a NID's text.
pub const TEXT_LEN = 11;

const salt = [16]u8{ 0x51, 0x8D, 0x64, 0xA6, 0x35, 0xDE, 0xD8, 0xC1, 0xE6, 0xB0, 0x39, 0xB1, 0xC3, 0xE5, 0x52, 0x30 };

const digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-";

/// digit character -> its value, 0xff for anything else.
const values: [256]u8 = blk: {
    var t = [_]u8{0xff} ** 256;
    for (digits, 0..) |c, i| t[c] = @intCast(i);
    break :blk t;
};

/// The NID of a symbol name.
pub fn of(name: []const u8) Nid {
    @setEvalBranchQuota(200_000); // (comptime callers: SHA-1 of a long name)
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(name);
    h.update(&salt);
    var d: [20]u8 = undefined;
    h.final(&d);
    return std.mem.readInt(u64, d[0..8], .little);
}

/// A NID's eleven characters.
pub fn text(n: Nid) [TEXT_LEN]u8 {
    var out: [TEXT_LEN]u8 = undefined;
    // Ten whole digits (60 bits), then the last four bits as a digit's high
    // bits, as base64 writes a 64-bit value.
    inline for (0..10) |i| out[i] = digits[@as(usize, @truncate(n >> (58 - 6 * i))) & 63];
    out[10] = digits[@as(usize, @truncate(n & 0xf)) << 2];
    return out;
}

/// The NID eleven characters spell, or null when they are not a NID's text.
pub fn parse(s: []const u8) ?Nid {
    if (s.len != TEXT_LEN) return null;
    var n: u64 = 0;
    inline for (0..10) |i| {
        const v = values[s[i]];
        if (v == 0xff) return null;
        n = n << 6 | v;
    }
    const last = values[s[10]];
    if (last == 0xff or last & 3 != 0) return null;
    return n << 4 | last >> 2;
}

/// A library or module index after a `#`: digits of the same alphabet, most
/// significant first (`A` is 0, `B` 1, `BA` 64). Null when not such a number
/// (or longer than any real table: four digits).
pub fn parseIndex(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 4) return null;
    var n: u32 = 0;
    for (s) |c| {
        const v = values[c];
        if (v == 0xff) return null;
        n = n << 6 | v;
    }
    return n;
}

/// An index's digits, written into `buf`; the slice used. (Four digits
/// hold 24 bits: more is a caller's mistake, as parseIndex reads no more.)
pub fn indexText(i: u32, buf: *[4]u8) []const u8 {
    std.debug.assert(i < 1 << 24);
    var n: usize = 1;
    while (n < 4 and (i >> @intCast(6 * n)) != 0) n += 1;
    for (0..n) |k| buf[k] = digits[(i >> @intCast(6 * (n - 1 - k))) & 63];
    return buf[0..n];
}

/// An imported or exported symbol's name taken apart: `NID#library#module`.
pub const Symbol = struct {
    nid: Nid,
    /// Index into the file's library table (import or export libraries).
    library: u32,
    /// Index into the file's module table.
    module: u32,

    /// Null for a name of any other shape (a plain C name in a symbol table
    /// is not an error: such symbols are simply not linked by NID).
    pub fn parse(name: []const u8) ?Symbol {
        if (name.len < TEXT_LEN + 4 or name[TEXT_LEN] != '#') return null;
        const n = @This().parseNid(name) orelse return null;
        const rest = name[TEXT_LEN + 1 ..];
        const sep = std.mem.indexOfScalar(u8, rest, '#') orelse return null;
        return .{
            .nid = n,
            .library = parseIndex(rest[0..sep]) orelse return null,
            .module = parseIndex(rest[sep + 1 ..]) orelse return null,
        };
    }

    fn parseNid(name: []const u8) ?Nid {
        return nidParse(name[0..TEXT_LEN]);
    }
};

const nidParse = parse;

// ── A table of exports, built at comptime ───────────────────────────────────

/// A sorted table from NID to a value (a function's address, an index):
/// what a library written in Sig looks its exports up in. Built at comptime
/// from names; a lookup is a binary search over 64-bit keys laid out apart
/// from the values, so a miss touches only keys.
pub fn Table(comptime V: type, comptime entries: []const struct { []const u8, V }) type {
    return struct {
        pub const len = entries.len;
        pub const keys: [entries.len]Nid = sorted.keys;
        pub const vals: [entries.len]V = sorted.vals;

        const sorted = blk: {
            @setEvalBranchQuota(entries.len * 60_000 + 10_000);
            var k: [entries.len]Nid = undefined;
            var v: [entries.len]V = undefined;
            var names: [entries.len][]const u8 = undefined;
            for (entries, 0..) |e, i| {
                k[i] = of(e[0]);
                v[i] = e[1];
                names[i] = e[0];
            }
            // Insertion sort (comptime, a few hundred entries a library).
            // (A table of none or one is sorted as it is.)
            if (entries.len > 1) {
                for (1..entries.len) |i| {
                    const kk = k[i];
                    const vv = v[i];
                    const nn = names[i];
                    var j = i;
                    while (j > 0 and k[j - 1] > kk) : (j -= 1) {
                        k[j] = k[j - 1];
                        v[j] = v[j - 1];
                        names[j] = names[j - 1];
                    }
                    k[j] = kk;
                    v[j] = vv;
                    names[j] = nn;
                }
                for (1..entries.len) |i| {
                    if (k[i] == k[i - 1]) @compileError("two exports share a NID: " ++ names[i - 1] ++ " and " ++ names[i]);
                }
            }
            break :blk .{ .keys = k, .vals = v };
        };

        pub fn find(n: Nid) ?V {
            if (len == 0) return null;
            return if (index(n)) |i| vals[i] else null;
        }

        pub fn index(n: Nid) ?usize {
            return search(&keys, n);
        }
    };
}

/// Where `n` is in sorted `keys`.
pub fn search(keys: []const Nid, n: Nid) ?usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const k = keys[mid];
        if (k == n) return mid;
        if (k < n) lo = mid + 1 else hi = mid;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const vectors = [_]struct { []const u8, []const u8 }{
    .{ "sceKernelUsleep", "1jfXLRVzisc" },
    .{ "scePthreadCreate", "6UgtwV+0zb4" },
    .{ "printf", "hcuQgD53UxM" },
    .{ "malloc", "gQX+4GDQjpM" },
    .{ "memcpy", "Q3VBxCXhUHs" },
    .{ "exit", "uMei1W9uyNo" },
    .{ "_init_env", "bzQExy189ZI" },
    .{ "atexit", "8G2LB+A3rzg" },
    .{ "sceVideoOutOpen", "Up36PTk687E" },
    .{ "scePadInit", "hv1luiJrqQM" },
    .{ "sceKernelAllocateDirectMemory", "rTXw65xmLIA" },
    .{ "sceKernelMapDirectMemory", "L-Q3LEjIbgA" },
    .{ "__stack_chk_guard", "f7uOxY9mM1U" },
    .{ "__stack_chk_fail", "Ou3iL1abvng" },
    .{ "module_start", "BaOKcng8g88" },
    .{ "__tls_get_addr", "vNe1w4diLCs" },
    .{ "sceKernelGettimeofday", "ejekcaNQNq0" },
    .{ "scePthreadMutexLock", "9UK1vLZQft4" },
    .{ "sceUserServiceGetInitialUser", "CdWp0oHWGr0" },
    .{ "sceAudioOutInit", "JfEPXVxhFqA" },
};

test "published names hash to their NIDs, and the text parses back" {
    for (vectors) |v| {
        const n = of(v[0]);
        try std.testing.expectEqualStrings(v[1], &text(n));
        try std.testing.expectEqual(n, parse(v[1]).?);
    }
}

test "a NID is a comptime value" {
    const n = comptime of("sceKernelUsleep");
    try std.testing.expectEqualStrings("1jfXLRVzisc", &text(n));
}

test "text that is not a NID is refused" {
    try std.testing.expectEqual(@as(?Nid, null), parse("1jfXLRVzis")); // short
    try std.testing.expectEqual(@as(?Nid, null), parse("1jfXLRVzis!")); // not a digit
    try std.testing.expectEqual(@as(?Nid, null), parse("1jfXLRVzisd")); // low bits set: no 64-bit value
}

test "library and module indexes" {
    try std.testing.expectEqual(@as(?u32, 0), parseIndex("A"));
    try std.testing.expectEqual(@as(?u32, 1), parseIndex("B"));
    try std.testing.expectEqual(@as(?u32, 64), parseIndex("BA"));
    try std.testing.expectEqual(@as(?u32, null), parseIndex(""));
    try std.testing.expectEqual(@as(?u32, null), parseIndex("#"));
    var b: [4]u8 = undefined;
    for ([_]u32{ 0, 1, 63, 64, 65, 4095, 4096, 262143 }) |i| {
        try std.testing.expectEqual(@as(?u32, i), parseIndex(indexText(i, &b)));
    }
}

test "a symbol name comes apart" {
    const s = Symbol.parse("1jfXLRVzisc#B#C").?;
    try std.testing.expectEqual(of("sceKernelUsleep"), s.nid);
    try std.testing.expectEqual(@as(u32, 1), s.library);
    try std.testing.expectEqual(@as(u32, 2), s.module);
    try std.testing.expectEqual(@as(?Symbol, null), Symbol.parse("sceKernelUsleep"));
    try std.testing.expectEqual(@as(?Symbol, null), Symbol.parse("1jfXLRVzisc#B"));
}

test "an export table finds every name and nothing else" {
    const T = Table(u8, &.{
        .{ "sceKernelUsleep", 1 },
        .{ "malloc", 2 },
        .{ "exit", 3 },
        .{ "memcpy", 4 },
    });
    try std.testing.expectEqual(@as(?u8, 1), T.find(of("sceKernelUsleep")));
    try std.testing.expectEqual(@as(?u8, 2), T.find(of("malloc")));
    try std.testing.expectEqual(@as(?u8, 3), T.find(of("exit")));
    try std.testing.expectEqual(@as(?u8, 4), T.find(of("memcpy")));
    try std.testing.expectEqual(@as(?u8, null), T.find(of("free")));
    for (1..T.len) |i| try std.testing.expect(T.keys[i - 1] < T.keys[i]);
    // A library with nothing to export, or one thing, is a table too.
    const None = Table(u8, &.{});
    try std.testing.expectEqual(@as(?u8, null), None.find(of("exit")));
    const One = Table(u8, &.{.{ "exit", 9 }});
    try std.testing.expectEqual(@as(?u8, 9), One.find(of("exit")));
}
