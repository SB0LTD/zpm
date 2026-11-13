//! @zpm/va vpx_bool — the boolean (arithmetic) coder VP8 and VP9 write
//! their compressed data with (RFC 6386 section 7; libvpx's vp8 boolhuff
//! and vpx_dsp bitwriter, the same coder), trees of binary decisions over
//! it (libvpx's vp8_treed_write), and what a decision costs in bits (for
//! the encoders' probability updates and mode decisions).
//!
//! Into caller storage; a write past the end sets `overflow` (checked once
//! at the end). Allocation-free.

const std = @import("std");

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,
    low: u32 = 0,
    range: u32 = 255,
    count: i32 = -24,
    overflow: bool = false,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// One decision: `bit` with probability `p`/256 of a 0.
    pub fn write(w: *Writer, one: bool, p: u8) void {
        const split: u32 = 1 + (((w.range - 1) * @as(u32, p)) >> 8);
        var range: u32 = if (one) w.range - split else split;
        var low = w.low;
        if (one) low += split;
        var shift: i32 = @clz(@as(u8, @intCast(range)));
        range <<= @intCast(shift);
        w.count += shift;
        if (w.count >= 0) {
            const offset: i32 = shift - w.count;
            if (((low << @intCast(offset - 1)) & 0x8000_0000) != 0) w.carry();
            w.put(@truncate(low >> @intCast(24 - offset)));
            low <<= @intCast(offset);
            shift = w.count;
            low &= 0xff_ffff;
            w.count -= 8;
        }
        low <<= @intCast(shift);
        w.low = low;
        w.range = range;
    }

    fn carry(w: *Writer) void {
        var x = w.pos;
        while (x > 0 and w.buf[x - 1] == 0xff) : (x -= 1) w.buf[x - 1] = 0;
        if (x > 0) w.buf[x - 1] +%= 1;
    }

    fn put(w: *Writer, byte: u8) void {
        if (w.pos >= w.buf.len) {
            w.overflow = true;
            return;
        }
        w.buf[w.pos] = byte;
        w.pos += 1;
    }

    /// An even decision (probability 128).
    pub fn bit(w: *Writer, b: bool) void {
        w.write(b, 128);
    }

    /// `n` bits of `v`, most significant first, each at probability 128.
    pub fn literal(w: *Writer, n: u5, v: u32) void {
        var k: u5 = n;
        while (k > 0) {
            k -= 1;
            w.bit((v >> k) & 1 != 0);
        }
    }

    /// VP8's end: 32 zero decisions flush the coder's state.
    pub fn finish(w: *Writer) usize {
        for (0..32) |_| w.write(false, 128);
        return w.pos;
    }

    /// VP9's end (vpx_stop_encode): the flush, then a zero byte if the
    /// last looks like a superframe index's marker.
    pub fn finishVp9(w: *Writer) usize {
        for (0..32) |_| w.write(false, 128);
        if (w.pos > 0 and (w.buf[w.pos - 1] & 0xe0) == 0xc0) w.put(0);
        return w.pos;
    }
};

// ── Trees ───────────────────────────────────────────────────────────────────

/// A tree as libvpx writes them: pairs of entries, an entry > 0 the index
/// of the next pair, <= 0 a leaf (the negated symbol). Node i's decision
/// has probability probs[i >> 1].
pub const Tree = []const i8;

/// A symbol's path: its decisions, first first.
pub const Code = struct { bits: u32 = 0, len: u5 = 0 };

/// Every symbol's code (symbols 0 .. n-1).
pub fn codes(comptime tree: Tree, comptime n: usize) [n]Code {
    @setEvalBranchQuota(100_000);
    var out: [n]Code = @splat(.{});
    const Walk = struct {
        fn go(o: *[n]Code, node: usize, bits: u32, len: u5) void {
            for (0..2) |k| {
                const e = tree[node + k];
                const b = (bits << 1) | @as(u32, @intCast(k));
                if (e <= 0) {
                    o[@intCast(-e)] = .{ .bits = b, .len = len + 1 };
                } else go(o, @intCast(e), b, len + 1);
            }
        }
    };
    Walk.go(&out, 0, 0, 0);
    return out;
}

/// Writes `code` through `tree`'s decisions with `probs`.
pub fn writeCode(w: *Writer, tree: Tree, probs: []const u8, code: Code) void {
    var node: usize = 0;
    var k: u5 = code.len;
    while (k > 0) {
        k -= 1;
        const b = (code.bits >> k) & 1;
        w.write(b != 0, probs[node >> 1]);
        const next = tree[node + b];
        if (next > 0) node = @intCast(next);
    }
}

/// The cost of `code` (1/256 bits).
pub fn codeCost(tree: Tree, probs: []const u8, code: Code) u32 {
    var node: usize = 0;
    var k: u5 = code.len;
    var c: u32 = 0;
    while (k > 0) {
        k -= 1;
        const b = (code.bits >> k) & 1;
        c += cost(b != 0, probs[node >> 1]);
        const next = tree[node + b];
        if (next > 0) node = @intCast(next);
    }
    return c;
}

// ── Costs ───────────────────────────────────────────────────────────────────

/// -log2(p / 256) in 1/256 bits, p = 1..255 (0 stands for 1).
pub const COST0: [256]u16 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u16 = undefined;
    for (0..256) |p| {
        const q: f64 = @floatFromInt(@max(p, 1));
        t[p] = @intFromFloat(@round(-std.math.log2(q / 256.0) * 256.0));
    }
    break :blk t;
};

/// What coding `bit` at probability `p` costs, 1/256 bits.
pub inline fn cost(bit: bool, p: u8) u32 {
    return if (bit) COST0[256 - @as(u16, p)] else COST0[p];
}

/// The cost of `c0` zeros and `c1` ones at probability `p` (1/256 bits).
pub fn branchCost(c0: u32, c1: u32, p: u8) u64 {
    return @as(u64, c0) * cost(false, p) + @as(u64, c1) * cost(true, p);
}

/// The probability (1..255) of a 0 that codes `c0` zeros and `c1` ones
/// best (libvpx's get_binary_prob).
pub fn bestProb(c0: u32, c1: u32) u8 {
    const n = @as(u64, c0) + c1;
    if (n == 0) return 128;
    const p = (@as(u64, c0) * 256 + (n >> 1)) / n;
    return @intCast(std.math.clamp(p, 1, 255));
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// libvpx's boolean decoder (vp8 dboolhuff / vpx_dsp bitreader), for the tests.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    value: u64 = 0,
    count: i32 = -8,
    range: u32 = 255,

    pub fn init(data: []const u8) Reader {
        var r = Reader{ .data = data };
        r.fill();
        return r;
    }

    fn fill(r: *Reader) void {
        var shift: i32 = 48 - r.count;
        while (shift >= 0) {
            const byte: u64 = if (r.pos < r.data.len) r.data[r.pos] else 0;
            r.pos += 1;
            r.count += 8;
            r.value |= byte << @intCast(shift);
            shift -= 8;
        }
    }

    pub fn read(r: *Reader, p: u8) bool {
        const split: u32 = 1 + (((r.range - 1) * @as(u32, p)) >> 8);
        if (r.count < 0) r.fill();
        const big: u64 = @as(u64, split) << 56;
        var b = false;
        if (r.value >= big) {
            r.range -= split;
            r.value -= big;
            b = true;
        } else r.range = split;
        const shift: u5 = @intCast(@clz(@as(u8, @intCast(r.range))));
        r.range <<= shift;
        r.value <<= shift;
        r.count -= shift;
        return b;
    }

    pub fn literal(r: *Reader, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | @intFromBool(r.read(128));
        return v;
    }

    pub fn readTree(r: *Reader, tree: Tree, probs: []const u8) u32 {
        var node: i32 = 0;
        while (true) {
            node = tree[@as(usize, @intCast(node)) + @intFromBool(r.read(probs[@as(usize, @intCast(node)) >> 1]))];
            if (node <= 0) return @intCast(-node);
        }
    }
};

test "vpx_bool: what the writer writes, the reader reads" {
    var buf: [4096]u8 = undefined;
    var w = Writer.init(&buf);
    var s: u32 = 12345;
    for (0..3000) |i| {
        s = s *% 1103515245 +% 12345;
        const p: u8 = @intCast(1 + (s >> 16) % 255);
        w.write((s >> 7) & 3 == 0 or i % 13 == 0, p);
    }
    w.literal(7, 99);
    const n = w.finish();
    try std.testing.expect(!w.overflow);
    var r = Reader.init(buf[0..n]);
    s = 12345;
    for (0..3000) |i| {
        s = s *% 1103515245 +% 12345;
        const p: u8 = @intCast(1 + (s >> 16) % 255);
        try std.testing.expectEqual((s >> 7) & 3 == 0 or i % 13 == 0, r.read(p));
    }
    try std.testing.expectEqual(@as(u32, 99), r.literal(7));
}

test "vpx_bool: tree codes and costs" {
    const tree = [_]i8{ 0, 2, -1, 4, -2, -3 };
    const cs = codes(&tree, 4);
    try std.testing.expectEqual(Code{ .bits = 0, .len = 1 }, cs[0]);
    try std.testing.expectEqual(Code{ .bits = 0b10, .len = 2 }, cs[1]);
    try std.testing.expectEqual(Code{ .bits = 0b111, .len = 3 }, cs[3]);
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    const probs = [_]u8{ 30, 200, 128 };
    for (0..4) |v| writeCode(&w, &tree, &probs, cs[v]);
    const n = w.finish();
    var r = Reader.init(buf[0..n]);
    for (0..4) |v| try std.testing.expectEqual(@as(u32, @intCast(v)), r.readTree(&tree, &probs));
    try std.testing.expectEqual(@as(u16, 256), COST0[128]);
    try std.testing.expectEqual(@as(u16, 2048), COST0[1]);
    try std.testing.expectEqual(@as(u8, 128), bestProb(5, 5));
}
