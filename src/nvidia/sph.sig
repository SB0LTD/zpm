//! @zpm/nvidia sph — a graphics program's Shader Program Header (SPH
//! version 4, BLACKWELL_B's 3D engine: clc797sph.h's fields, the same on
//! clcb97).
//!
//! A vertex or a pixel program is not launched by a QMD as a compute
//! kernel is: 128 bytes go in front of its code, and the engine reads from
//! them what the program is (its type and stage), which attribute words it
//! reads and which it writes, and for a pixel program how each word it
//! reads is carried across the triangle and which render targets' channels
//! it writes. The 3D engine is given the header's address
//! (SET_PIPELINE_PROGRAM_ADDRESS); the code follows at +0x80.
//!
//! The attribute words are addressed in bytes, as the instructions that
//! load and store them address them (ALD, AST, IPA): the position at
//! 0x70..0x7c, generic vector n's component c at 0x80 + 16n + 4c, the
//! instance's index at 0x2f8 and the vertex's at 0x2fc.
//!
//! These are the fields Mesa's NAK writes (compiler/nak/sph.rs, MIT, read
//! as documentation); NVK is conformant on this GPU with them. Nothing
//! here has run on the Legion's RTX yet.
//!
//! Allocation-free: a header is 32 words returned by value.

const std = @import("std");

pub const WORDS = 32;
pub const BYTES = WORDS * 4;
/// Where a program's code starts, from its header's start.
pub const CODE_AT = BYTES;

// ── The attribute words ─────────────────────────────────────────────────────

/// The clip-space position a vertex program stores: x, then y, z, w.
pub const ATTR_POSITION: u32 = 0x70;
/// Generic vector 0's x: vector n's component c is 16n + 4c on.
pub const ATTR_GENERIC: u32 = 0x80;
pub const ATTR_INSTANCE_ID: u32 = 0x2f8;
pub const ATTR_VERTEX_ID: u32 = 0x2fc;
pub const GENERICS = 32;

/// A generic component's address.
pub fn generic(n: u32, c: u32) u32 {
    return ATTR_GENERIC + 16 * n + 4 * c;
}

// ── The fields ──────────────────────────────────────────────────────────────

const TYPE_VTG = 1;
const TYPE_PS = 2;
const VERSION = 4;
const STAGE_VERTEX = 1;
const STAGE_PIXEL = 5;

fn set(words: *[WORDS]u32, at: u32, n: u32, value: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const b = at + i;
        const one = @as(u32, 1) << @intCast(b % 32);
        if ((value >> @intCast(i)) & 1 != 0) words[b / 32] |= one else words[b / 32] &= ~one;
    }
}

fn common(words: *[WORDS]u32, sph_type: u32, stage: u32) void {
    set(words, 0, 5, sph_type);
    set(words, 5, 5, VERSION);
    set(words, 10, 4, stage);
    // SASS_VERSION
    set(words, 17, 4, 1);
}

// ── A vertex program ────────────────────────────────────────────────────────

/// What a vertex program reads and writes. It always stores the position.
pub const Vertex = struct {
    /// It reads the vertex's index (ALD a[0x2fc]), the instance's (0x2f8).
    vertex_id: bool = false,
    instance_id: bool = false,
    /// The components of each generic vector it loads from a vertex buffer
    /// (bit c: component c).
    in_generic: [GENERICS]u4 = @splat(0),
    /// The components of each generic vector it stores for the next stage.
    out_generic: [GENERICS]u4 = @splat(0),
    /// No load comes after a store (the program reads all its inputs
    /// first): the engine may then keep both in one space.
    loads_before_stores: bool = true,
};

pub fn vertex(v: Vertex) [WORDS]u32 {
    var w: [WORDS]u32 = @splat(0);
    common(&w, TYPE_VTG, STAGE_VERTEX);
    if (v.loads_before_stores) set(&w, 25, 1, 1);
    // What it loads: the generic vectors (a bit a word), the two indices.
    for (v.in_generic, 0..) |comps, n| set(&w, 192 + 4 * @as(u32, @intCast(n)), 4, comps);
    if (v.instance_id) set(&w, 350, 1, 1);
    if (v.vertex_id) set(&w, 351, 1, 1);
    // What it stores: the position's four words, the generic vectors; and
    // the range of words between the first and the last stored.
    set(&w, 428, 4, 0xf);
    var first: u32 = ATTR_POSITION / 4;
    var last: u32 = (ATTR_POSITION + 12) / 4;
    for (v.out_generic, 0..) |comps, ni| {
        const n: u32 = @intCast(ni);
        set(&w, 432 + 4 * n, 4, comps);
        var c: u32 = 0;
        while (c < 4) : (c += 1) if ((comps >> @intCast(c)) & 1 != 0) {
            first = @min(first, generic(n, c) / 4);
            last = @max(last, generic(n, c) / 4);
        };
    }
    set(&w, 140, 8, first);
    set(&w, 152, 8, last);
    return w;
}

// ── A pixel program ─────────────────────────────────────────────────────────

/// How a word a pixel program reads is carried across the triangle.
pub const Interp = enum(u2) {
    unused = 0,
    /// The provoking vertex's value.
    constant = 1,
    /// Linear in the scene (divided by w): what a texture coordinate wants.
    perspective = 2,
    /// Linear on the screen.
    linear = 3,
};

pub const Pixel = struct {
    /// Each generic vector's components as it reads them (IPA).
    in_generic: [GENERICS][4]Interp = @splat(@splat(.unused)),
    /// It reads the pixel's own x, y, z (bit 0, 1, 2).
    frag_coord: u3 = 0,
    /// It may discard the pixel (KILL).
    kills: bool = false,
    /// The channels of each render target it writes (bit 0: red, then
    /// green, blue, alpha): target 0's leave in R0..R3.
    targets: [8]u4 = .{ 0xf, 0, 0, 0, 0, 0, 0, 0 },
    writes_depth: bool = false,
    writes_sample_mask: bool = false,
};

pub fn pixel(p: Pixel) [WORDS]u32 {
    var w: [WORDS]u32 = @splat(0);
    common(&w, TYPE_PS, STAGE_PIXEL);
    // MRT_ENABLE: each target has its own output, none is color 0's copy.
    set(&w, 14, 1, 1);
    if (p.kills) set(&w, 15, 1, 1);
    // The position's w, always: without it the program traps.
    set(&w, 191, 1, 1);
    set(&w, 188, 3, p.frag_coord);
    for (p.in_generic, 0..) |vec, n| for (vec, 0..) |interp, c| {
        set(&w, 192 + 8 * @as(u32, @intCast(n)) + 2 * @as(u32, @intCast(c)), 2, @intFromEnum(interp));
    };
    for (p.targets, 0..) |chans, t| set(&w, 576 + 4 * @as(u32, @intCast(t)), 4, chans);
    if (p.writes_sample_mask) set(&w, 608, 1, 1);
    if (p.writes_depth) set(&w, 609, 1, 1);
    return w;
}

/// What a header says its program is, read back: the emulated 3D engine
/// refuses a program whose header is not one of these two.
pub const Stage = enum { vertex, pixel };

pub fn stageOf(w: *const [WORDS]u32) ?Stage {
    if ((w[0] >> 5) & 0x1f != VERSION) return null;
    const sph_type = w[0] & 0x1f;
    const stage = (w[0] >> 10) & 0xf;
    if (sph_type == TYPE_VTG and stage == STAGE_VERTEX) return .vertex;
    if (sph_type == TYPE_PS and stage == STAGE_PIXEL) return .pixel;
    return null;
}

/// A bit of a header: whether attribute word, target channel or flag
/// `at` is set.
pub fn bit(w: *const [WORDS]u32, at: u32) bool {
    return (w[at / 32] >> @intCast(at % 32)) & 1 != 0;
}

/// How a pixel program's header says it reads generic vector n's
/// component c.
pub fn interpOf(w: *const [WORDS]u32, n: u32, c: u32) Interp {
    const at = 192 + 8 * n + 2 * c;
    return @enumFromInt((w[at / 32] >> @intCast(at % 32)) & 3);
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectWords(got: [WORDS]u32, want: []const struct { u32, u32 }) !void {
    var all: [WORDS]u32 = @splat(0);
    for (want) |pair| all[pair[0]] = pair[1];
    for (got, all, 0..) |g, a, i| {
        if (g != a) {
            std.debug.print("word {d}: {x:0>8}, not {x:0>8}\n", .{ i, g, a });
            return error.TestUnexpectedResult;
        }
    }
}

test "sph: a vertex program that reads its index and stores a position and one vector" {
    var v = Vertex{ .vertex_id = true };
    v.out_generic[0] = 0xf;
    // (type 1, version 4, stage vertex, SASS version 1, one space; the
    // stores run from word 0x1c to 0x23; the index read; the position and
    // generic 0 written)
    try expectWords(vertex(v), &.{ .{ 0, 0x02020481 }, .{ 4, 0x2301c000 }, .{ 10, 0x80000000 }, .{ 13, 0x000ff000 } });
    // with the instance's index, and only two components stored
    v.instance_id = true;
    v.out_generic[0] = 0x3;
    try expectWords(vertex(v), &.{ .{ 0, 0x02020481 }, .{ 4, 0x2101c000 }, .{ 10, 0xc0000000 }, .{ 13, 0x0003f000 } });
    // a load after a store: not one space
    v.loads_before_stores = false;
    try testing.expectEqual(@as(u32, 0x00020481), vertex(v)[0]);
    // an attribute from a vertex buffer: generic 1's x and y
    var b = Vertex{};
    b.in_generic[1] = 0x3;
    try testing.expectEqual(@as(u32, 0x00000030), vertex(b)[6]);
    try testing.expectEqual(Stage.vertex, stageOf(&vertex(b)).?);
}

test "sph: a pixel program that reads one vector across the triangle and writes one target" {
    var p = Pixel{};
    p.in_generic[0] = @splat(.perspective);
    // (type 2, version 4, stage pixel, its targets its own, SASS version
    // 1; the position's w; generic 0 in perspective; target 0's four
    // channels)
    try expectWords(pixel(p), &.{ .{ 0, 0x00025482 }, .{ 5, 0x80000000 }, .{ 6, 0x000000aa }, .{ 18, 0x0000000f } });
    p.in_generic[0] = @splat(.linear);
    p.kills = true;
    try expectWords(pixel(p), &.{ .{ 0, 0x0002d482 }, .{ 5, 0x80000000 }, .{ 6, 0x000000ff }, .{ 18, 0x0000000f } });
    // the pixel's own x and y, a second vector's first two components flat
    p.frag_coord = 0x3;
    p.in_generic[1] = .{ .constant, .constant, .unused, .unused };
    const w = pixel(p);
    try testing.expectEqual(@as(u32, 0xb0000000), w[5]);
    try testing.expectEqual(@as(u32, 0x000005ff), w[6]);
    try testing.expectEqual(Stage.pixel, stageOf(&w).?);
    try testing.expectEqual(Interp.linear, interpOf(&w, 0, 3));
    try testing.expectEqual(Interp.constant, interpOf(&w, 1, 1));
    try testing.expectEqual(Interp.unused, interpOf(&w, 1, 2));
    try testing.expect(bit(&w, 576) and bit(&w, 579) and !bit(&w, 580));
}

test "sph: what is not a version 4 vertex or pixel header is neither" {
    var w: [WORDS]u32 = @splat(0);
    try testing.expectEqual(@as(?Stage, null), stageOf(&w));
    w = vertex(.{});
    w[0] ^= 1 << 10 | 1 << 11; // (stage 2: tessellation's first)
    try testing.expectEqual(@as(?Stage, null), stageOf(&w));
    try testing.expectEqual(@as(u32, 0x80), generic(0, 0));
    try testing.expectEqual(@as(u32, 0x9c), generic(1, 3));
}
