//! @zpm/ps5gfx target — the pictures a game draws into, kept as the
//! engine's images.
//!
//! A game names a render target by where its pixels are in memory. On the
//! console the GPU writes there. Here the engine draws into an image of
//! its own for each such address (on a GPU that image is in the GPU's
//! memory; the game's bytes are not touched), and this file keeps the
//! pairs: found again by address draw after draw, made on first use,
//! made anew when a game changes what is at an address, the one unused
//! longest given up when there are too many.
//!
//! The display asks for a frame by the same address (the buffer a game
//! flips is one it drew into): `frame` reads it back the way the display
//! takes it.
//!
//! What this costs: a game that reads its own target's memory on the CPU
//! finds nothing drawn there. (Few do; a console's targets are laid out
//! in tiles a CPU does not read in passing.)
//!
//! Allocation-free: the images' memory is the engine's.

const std = @import("std");
const gfxapi = @import("gfxapi");
const state = @import("state.sig");
const convert = @import("draw.sig");

const engine = gfxapi.engine;
const Engine = engine.Engine;

/// Targets kept at once, colour and depth together.
pub const MAX = 32;

const Kind = enum { color, depth };

const Slot = struct {
    live: bool = false,
    kind: Kind = .color,
    address: u64 = 0,
    image: engine.Image = undefined,
    used: u64 = 0,
};

pub const Targets = struct {
    slots: [MAX]Slot = [_]Slot{.{}} ** MAX,
    clock: u64 = 0,
    /// Images made, and images given up for room.
    made: u64 = 0,
    dropped: u64 = 0,

    fn find(ts: *Targets, kind: Kind, address: u64) ?*Slot {
        for (&ts.slots) |*s| {
            if (s.live and s.kind == kind and s.address == address) return s;
        }
        return null;
    }

    /// A slot to fill: a free one, or the one unused longest (its image
    /// given back).
    fn room(ts: *Targets, e: *Engine) *Slot {
        var oldest: *Slot = &ts.slots[0];
        for (&ts.slots) |*s| {
            if (!s.live) return s;
            if (s.used < oldest.used) oldest = s;
        }
        e.freeImage(&oldest.image);
        oldest.live = false;
        ts.dropped += 1;
        return oldest;
    }

    fn keepSlot(ts: *Targets, s: *Slot, kind: Kind, address: u64) *engine.Image {
        ts.clock += 1;
        s.live = true;
        s.kind = kind;
        s.address = address;
        s.used = ts.clock;
        return &s.image;
    }

    /// The image a colour target's draws go into. Null: a layout the
    /// engine cannot draw into, no address, or no memory for it. A new
    /// image is black and clear (every byte 0); one whose size or layout
    /// a game changed is made anew, its old picture gone.
    pub fn color(ts: *Targets, e: *Engine, t: state.Target) ?*engine.Image {
        const f = convert.format(t) orelse return null;
        if (t.address == 0) return null;
        if (ts.find(.color, t.address)) |s| {
            if (s.image.width == t.width and s.image.height == t.height and s.image.format == f) return ts.keepSlot(s, .color, t.address);
            e.freeImage(&s.image);
            s.live = false;
        }
        const s = ts.room(e);
        s.image = e.newImage(t.width, t.height, f) orelse return null;
        e.fill(&s.image, .{ .x0 = 0, .y0 = 0, .x1 = t.width, .y1 = t.height }, 0, 0);
        ts.made += 1;
        return ts.keepSlot(s, .color, t.address);
    }

    /// The image a depth target's tests and writes go to. Null: none set,
    /// or no memory. A new one holds the farthest depth, 1 (what a
    /// console's memory holds before a game clears it is anything).
    pub fn depth(ts: *Targets, e: *Engine, d: state.Depth) ?*engine.Image {
        if (d.format == 0 or d.address == 0) return null;
        if (ts.find(.depth, d.address)) |s| {
            if (s.image.width == d.width and s.image.height == d.height) return ts.keepSlot(s, .depth, d.address);
            e.freeImage(&s.image);
            s.live = false;
        }
        const s = ts.room(e);
        s.image = e.newDepthImage(d.width, d.height) orelse return null;
        e.fillDepth(&s.image, .{ .x0 = 0, .y0 = 0, .x1 = d.width, .y1 = d.height }, 1.0, 0, 0xFF);
        ts.made += 1;
        return ts.keepSlot(s, .depth, d.address);
    }

    /// The frame at `address` for the display: `width` x `height` words,
    /// rows from the top, each 0xAARRGGBB. False: nothing was drawn into a
    /// target there. Where the target is smaller than what is asked for,
    /// the rest is black.
    pub fn frame(ts: *Targets, e: *Engine, address: u64, width: u32, height: u32, out: [*]u32) bool {
        const s = ts.find(.color, address) orelse return false;
        const img = &s.image;
        const w = @min(width, img.width);
        const h = @min(height, img.height);
        const words = out[0 .. @as(usize, width) * height];
        if (w < width or h < height) @memset(words, 0);
        const bytes = std.mem.sliceAsBytes(words);
        // (the engine's rows count from the bottom: the console's row j is
        // its row height - 1 - j)
        for (0..h) |j| {
            const row = bytes[j * @as(usize, width) * 4 ..][0 .. @as(usize, w) * 4];
            e.read(img, 0, img.height - 1 - @as(u32, @intCast(j)), w, 1, row, @as(usize, width) * 4, .bgra8);
        }
        return true;
    }

    /// Whether a colour target is kept for `address`.
    pub fn has(ts: *Targets, address: u64) bool {
        return ts.find(.color, address) != null;
    }

    /// Every image given back.
    pub fn release(ts: *Targets, e: *Engine) void {
        for (&ts.slots) |*s| {
            if (s.live) e.freeImage(&s.image);
            s.live = false;
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const Host = struct {
    var pool: [8 << 20]u8 align(64) = undefined;
    var work: [4 << 20]u8 align(64) = undefined;
    var eng: Engine = undefined;
    var ready = false;

    fn get() *Engine {
        if (!ready) {
            eng.init(.{ .pool = &pool, .cpu_work = &work });
            ready = true;
        }
        return &eng;
    }
};

fn targetAt(address: u64, width: u32, height: u32, swap: u8) state.Target {
    return .{
        .address = address,
        .width = width,
        .height = height,
        .format = state.COLOR.RGBA8,
        .number = state.NUMBER.UNORM,
        .swap = swap,
        .tiling = 27,
        .samples_log2 = 0,
        .mip = 0,
        .first_slice = 0,
        .last_slice = 0,
        .dimension = 1,
        .write = 0xF,
        .shader = 0xF,
    };
}

test "a target is made black, found again by address, and read back as the display takes it" {
    const e = Host.get();
    var ts: Targets = .{};
    defer ts.release(e);

    // Red first in memory. The console's top-left 4 x 2 pixels painted:
    // red 0x11, green 0x22, blue 0x33, alpha 0xFF.
    const t = targetAt(0x10_0000, 16, 8, state.SWAP.STANDARD);
    const img = ts.color(e, t).?;
    try testing.expectEqual(engine.Format.rgba8, img.format);
    e.fill(img, convert.rect(.{ .x0 = 0, .y0 = 0, .x1 = 4, .y1 = 2 }, 16, 8).?, 0xFF33_2211, 0);
    e.finish();

    var out: [16 * 8]u32 = undefined;
    @memset(&out, 0xDEAD_BEEF);
    try testing.expect(ts.frame(e, 0x10_0000, 16, 8, &out));
    // (rows from the top, each word alpha, red, green, blue from the top
    // byte down)
    try testing.expectEqual(@as(u32, 0xFF11_2233), out[0]);
    try testing.expectEqual(@as(u32, 0xFF11_2233), out[16 + 3]);
    try testing.expectEqual(@as(u32, 0), out[4] & 0x00FF_FFFF);
    try testing.expectEqual(@as(u32, 0), out[2 * 16] & 0x00FF_FFFF);
    try testing.expectEqual(@as(u32, 0), out[7 * 16 + 15] & 0x00FF_FFFF);

    // The same target again: the same image, its picture kept.
    try testing.expectEqual(img, ts.color(e, t).?);
    try testing.expectEqual(@as(u64, 1), ts.made);
    @memset(&out, 0);
    try testing.expect(ts.frame(e, 0x10_0000, 16, 8, &out));
    try testing.expectEqual(@as(u32, 0xFF11_2233), out[0]);

    // A display buffer larger than the target: the rest black. A smaller
    // one: the top-left part.
    var big: [20 * 10]u32 = undefined;
    @memset(&big, 0xDEAD_BEEF);
    try testing.expect(ts.frame(e, 0x10_0000, 20, 10, &big));
    try testing.expectEqual(@as(u32, 0xFF11_2233), big[0]);
    try testing.expectEqual(@as(u32, 0xFF11_2233), big[20 + 3]);
    try testing.expectEqual(@as(u32, 0), big[19]);
    try testing.expectEqual(@as(u32, 0), big[9 * 20 + 19]);
    var small: [2 * 3]u32 = undefined;
    try testing.expect(ts.frame(e, 0x10_0000, 2, 3, &small));
    try testing.expectEqual(@as(u32, 0xFF11_2233), small[0]);
    try testing.expectEqual(@as(u32, 0xFF11_2233), small[3]);
    try testing.expectEqual(@as(u32, 0), small[4] & 0x00FF_FFFF);

    // Nothing drawn at another address.
    try testing.expect(!ts.frame(e, 0x20_0000, 16, 8, &out));
    try testing.expect(ts.has(0x10_0000) and !ts.has(0x20_0000));
}

test "blue first in memory reads back the same; a changed target is made anew" {
    const e = Host.get();
    var ts: Targets = .{};
    defer ts.release(e);

    const t = targetAt(0x30_0000, 8, 8, state.SWAP.ALTERNATE);
    const img = ts.color(e, t).?;
    try testing.expectEqual(engine.Format.bgra8, img.format);
    // (bytes blue, green, red, alpha: the word is the display's own)
    e.fill(img, convert.rect(.{ .x0 = 7, .y0 = 7, .x1 = 8, .y1 = 8 }, 8, 8).?, 0xFF11_2233, 0);
    e.finish();
    var out: [64]u32 = undefined;
    try testing.expect(ts.frame(e, 0x30_0000, 8, 8, &out));
    try testing.expectEqual(@as(u32, 0xFF11_2233), out[63]);
    try testing.expectEqual(@as(u32, 0), out[0] & 0x00FF_FFFF);

    // The game puts a target of another size at the address: a new image,
    // black.
    const wider = targetAt(0x30_0000, 16, 8, state.SWAP.ALTERNATE);
    const again = ts.color(e, wider).?;
    try testing.expectEqual(@as(u32, 16), again.width);
    try testing.expectEqual(@as(u64, 2), ts.made);
    var wide: [16 * 8]u32 = undefined;
    try testing.expect(ts.frame(e, 0x30_0000, 16, 8, &wide));
    for (wide) |p| try testing.expectEqual(@as(u32, 0), p & 0x00FF_FFFF);

    // What the engine cannot draw into has no image; neither has no
    // address.
    var odd = targetAt(0x40_0000, 8, 8, state.SWAP.STANDARD);
    odd.format = state.COLOR.RGBA16;
    try testing.expect(ts.color(e, odd) == null);
    try testing.expect(ts.color(e, targetAt(0, 8, 8, state.SWAP.STANDARD)) == null);
    try testing.expect(!ts.has(0x40_0000));
}

test "a depth target by its address; too many targets and the one unused longest goes" {
    const e = Host.get();
    var ts: Targets = .{};
    defer ts.release(e);

    var d: state.Depth = .{ .address = 0x50_0000, .width = 16, .height = 8, .format = 3, .tiling = 0, .samples_log2 = 0, .test_on = true, .func = 1, .write = true, .clears = false, .clear = 0, .stencil_on = false };
    const z = ts.depth(e, d).?;
    try testing.expectEqual(@as(u32, 16), z.width);
    try testing.expectEqual(z, ts.depth(e, d).?);
    try testing.expectEqual(@as(u64, 1), ts.made);
    // (a colour target at the same address is another thing)
    try testing.expect(!ts.has(0x50_0000));
    d.format = 0;
    try testing.expect(ts.depth(e, d) == null);

    // One more colour target than there is room for, the first of them
    // used again in between: the second is the one that goes.
    const first = 0x100_0000;
    for (0..MAX - 1) |i| try testing.expect(ts.color(e, targetAt(first + 0x1000 * @as(u64, i), 4, 4, state.SWAP.STANDARD)) != null);
    try testing.expectEqual(@as(u64, 0), ts.dropped);
    _ = ts.depth(e, .{ .address = 0x50_0000, .width = 16, .height = 8, .format = 3, .tiling = 0, .samples_log2 = 0, .test_on = true, .func = 1, .write = true, .clears = false, .clear = 0, .stencil_on = false }).?;
    _ = ts.color(e, targetAt(first, 4, 4, state.SWAP.STANDARD)).?;
    try testing.expect(ts.color(e, targetAt(0x900_0000, 4, 4, state.SWAP.STANDARD)) != null);
    try testing.expectEqual(@as(u64, 1), ts.dropped);
    try testing.expect(ts.has(first));
    try testing.expect(!ts.has(first + 0x1000));
    try testing.expect(ts.has(first + 0x2000));
    try testing.expect(ts.has(0x900_0000));
}
