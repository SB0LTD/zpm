//! @zpm/dxg nv — the private data NVIDIA's WSL driver pairs with dxgkrnl's
//! calls (the host's NVIDIA kernel driver reads it), as zpm writes it.
//!
//! Learned by watching NVIDIA's own user-mode driver (tools/dxgtrace.sig on
//! the Legion's RTX 5070 Laptop GPU, Windows driver 592.15): every block
//! starts with the same 16 bytes ("NVDA", a kind, its size, "**VN"), then
//! the fields below at the offsets NVIDIA's driver writes them. A field
//! whose meaning is not known yet is named for where it is and keeps the
//! value NVIDIA's driver always wrote there.
//!
//! Allocation-free: each builder fills the caller's bytes.

const std = @import("std");
const push = @import("nvidia").push;

pub const MAGIC: u32 = 0x4e56_4441; // "ADVN" in memory: NVDA
pub const MAGIC2: u32 = 0x4e56_2a2a; // "**VN"

/// The block's kind (the second u32).
pub const KIND_OBJECT: u32 = 0x0001_0000; // a context or a hardware queue
pub const KIND_ESCAPE: u32 = 0x0001_0002;
pub const KIND_ALLOCATION: u32 = 0x0001_0004;

fn put(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn put64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

fn head(b: []u8, kind: u32) void {
    @memset(b, 0);
    put(b, 0, MAGIC);
    put(b, 4, kind);
    put(b, 8, @intCast(b.len));
    put(b, 12, MAGIC2);
}

// ── A context (create_context_virtual) ──────────────────────────────────────

pub const CONTEXT_BYTES = 3200;

/// A context's data: the client's kind (as the call's client hint: 5 for
/// CUDA, NVIDIA's), the process's name (ASCII at 0x28, UTF-16 at 0x128, up
/// to 63 characters) and NVIDIA's constant fields.
pub fn context(b: *[CONTEXT_BYTES]u8, name: []const u8, client: u32) void {
    head(b, KIND_OBJECT);
    put(b, 0x10, client);
    put(b, 0x18, 3);
    put(b, 0x1c, 0xc);
    const n = @min(name.len, 63);
    @memcpy(b[0x28..][0..n], name[0..n]);
    for (name[0..n], 0..) |c, i| b[0x128 + 2 * i] = c;
    put(b, 0xc40, 0x418);
    for (0..6) |i| put(b, 0xc48 + 4 * i, 0xffff_ffff);
    put(b, 0xc74, 1);
}

// ── A legacy context (no hardware queue) ────────────────────────────────────
//
// With Windows' hardware-accelerated GPU scheduling off, NVIDIA's WSL driver
// makes no hardware queues: each context is fed by submit_command, its
// GPFIFO entries in the call's private data, and Windows' scheduler runs
// them (traced on this PC's RTX 2080 Ti, NVIDIA's driver 576.28, WDDM 2.7
// caps 0x9: scheduling in hardware supported, not on; cudaprobe's contexts
// and submissions, tools/dxgtrace.sig).

pub const LEGACY_CONTEXT_BYTES = 3569;

/// A legacy context's data, as cudaprobe's first (node 0, flags 4: no
/// hardware queue): the client's kind, the process's name (ASCII at 0x134,
/// UTF-16 at 0x234, up to 63 characters) and NVIDIA's constant fields.
pub fn legacyContext(b: *[LEGACY_CONTEXT_BYTES]u8, name: []const u8, client: u32) void {
    head(b, KIND_ALLOCATION);
    put(b, 0x10, client);
    put(b, 0x14, 0x0400_600c);
    put(b, 0x128, 0xc);
    const n = @min(name.len, 63);
    @memcpy(b[0x134..][0..n], name[0..n]);
    for (name[0..n], 0..) |c, i| b[0x234 + 2 * i] = c;
    put(b, 0xd4c, 0x4ec);
    @memset(b[0xdc1..0xdd9], 0xff);
    put(b, 0xdec, 0x100);
}

/// A legacy submission's data: a 0x354-byte head, then the GPFIFO entries
/// (as NVIDIA's driver writes them: no subroutine level); the call's
/// command buffer is a dummy 1, its length this data's.
pub const LEGACY_SUBMIT_HEAD = 0x354;
pub const LEGACY_MAX_ENTRIES = 64;
pub const LEGACY_SUBMIT_MAX = LEGACY_SUBMIT_HEAD + 8 * LEGACY_MAX_ENTRIES;
pub const LEGACY_COMMAND_BUFFER: u64 = 1;

/// Fills `b` for `entries`; the data's length.
pub fn legacySubmit(b: *[LEGACY_SUBMIT_MAX]u8, entries: []const u64) u32 {
    const n = @min(entries.len, LEGACY_MAX_ENTRIES);
    @memset(b[0..LEGACY_SUBMIT_HEAD], 0);
    put(b, 0, MAGIC);
    put(b, 4, KIND_ALLOCATION);
    put(b, 0x0c, LEGACY_SUBMIT_HEAD);
    put(b, 0x18, 1);
    for (entries[0..n], 0..) |e, i| put64(b, LEGACY_SUBMIT_HEAD + 8 * i, e);
    return @intCast(LEGACY_SUBMIT_HEAD + 8 * @as(u32, @intCast(n)));
}

/// The field NVIDIA's driver 576 adds to every allocation's data (0xec;
/// 592's has none there).
pub fn legacyAllocation(b: *[ALLOCATION_BYTES]u8) void {
    put(b, 0xec, 0x1_0000);
}

// ── A video engine's context (NVDEC, NVENC) ─────────────────────────────────

/// NVIDIA's video engines on WSL: each a legacy context of its own (no
/// hardware queue, flags 0, client hint 1) on its node, fed by
/// submit_command (NVIDIA's own decode and encode, traced 11-16: ffmpeg's
/// h264_cuvid and h264_nvenc). The engine's object is the host's, bound on
/// subchannel 4: a pushbuffer has no SET_OBJECT.
pub const VideoEngine = enum(u32) { decoder = 0, encoder = 1 };
/// Their nodes on the RTX 5070 Laptop's host (NVIDIA's driver 592).
pub fn videoNode(e: VideoEngine) u32 {
    return switch (e) {
        .decoder => 1,
        .encoder => 5,
    };
}

/// Their nodes on a host whose GPU's work Windows schedules in software
/// (`legacy`): the RTX 2080 Ti's, NVIDIA's driver 576.28, where ffmpeg's
/// h264_nvenc made the decoder's context (engine 0) on node 8 and the
/// encoder's on node 5 (traced 2026-11-22); the same context data and
/// submissions as 592's. (The host's node metadata query, which would name
/// each node's engine, is not answered there.)
pub fn videoNodeOn(e: VideoEngine, legacy: bool) u32 {
    if (!legacy) return videoNode(e);
    return switch (e) {
        .decoder => 8,
        .encoder => 5,
    };
}
pub const VIDEO_SUBCH: u32 = 4;
pub const VIDEO_CONTEXT_BYTES = 3569;

/// A video context's data, as NVIDIA's driver gives it (only the engine's
/// word differs between the two).
pub fn videoContext(b: *[VIDEO_CONTEXT_BYTES]u8, e: VideoEngine) void {
    head(b, KIND_ALLOCATION);
    put(b, 0x10, 5);
    put(b, 0x14, 0x400f);
    put(b, 0x1c, 0x200);
    put(b, 0x20, 0x8000_0000 | @intFromEnum(e));
    @memset(b[0xdc1..0xdd9], 0xff);
}

pub const VIDEO_SUBMIT_BYTES = 868;

/// A video context's submission data: the command buffer at `va`, `dwords`
/// long, as the GPFIFO entry the host copies into the engine's ring
/// (subroutine level, as every entry NVIDIA writes).
pub fn videoSubmit(b: *[VIDEO_SUBMIT_BYTES]u8, va: u64, dwords: u32) void {
    @memset(b, 0);
    put(b, 0, MAGIC);
    put(b, 4, KIND_ALLOCATION);
    put(b, 0x0c, 0x354);
    put(b, 0x14, 1);
    put(b, 0x18, 2);
    put(b, 0x1c, 8);
    put(b, 0x358, 4);
    const e = push.gpEntry(va, dwords) | ENTRY_SUBROUTINE;
    put64(b, 0x35c, e);
}

// ── A hardware queue (create_hw_queue) ──────────────────────────────────────

pub const QUEUE_BYTES = 140;

/// The engines a hardware queue's channel gets objects for (the queue
/// data's field at 0x10): NVIDIA's CUDA driver asks 0xa00 (compute and
/// copy), its Direct3D 12 driver 0x900 for a direct queue and 0xe01 for a
/// compute one. On a CUDA context the host takes 0x900 (the 3D engine and
/// compute: zpm's draw and compute self-tests both pass on it), refuses
/// 0xb00, and gives no 3D object for 0xa00 or 0xe01.
pub const ENGINES_CUDA: u32 = 0xa00;
pub const ENGINES_DIRECT: u32 = 0x900;

/// A hardware queue's data: the engines its channel gets, its GPFIFO ring
/// (the GPU address, the bytes, the allocation holding it).
pub fn queue(b: *[QUEUE_BYTES]u8, engines: u32, gpfifo_va: u64, gpfifo_bytes: u32, ring_allocation: u32) void {
    head(b, KIND_OBJECT);
    put(b, 0x10, engines);
    put64(b, 0x18, gpfifo_va);
    put(b, 0x20, gpfifo_bytes);
    put(b, 0x24, ring_allocation);
}

// ── An allocation (create_allocation's allocation info) ─────────────────────

pub const ALLOCATION_BYTES = 586;

pub const Memory = enum {
    /// The GPU's own memory (VRAM).
    video,
    /// The process's memory, which the GPU maps.
    system,
    /// The process's memory holding a GPFIFO ring.
    ring,
};

/// The unit of an allocation's size (the field at 0xd0 counts these).
pub const ALLOCATION_UNIT: u64 = 64 << 10;

/// An allocation's data: what memory, and how big (`bytes`, a multiple of
/// ALLOCATION_UNIT).
pub fn allocation(b: *[ALLOCATION_BYTES]u8, memory: Memory, bytes: u64) void {
    head(b, KIND_ALLOCATION);
    const units: u32 = @intCast(bytes / ALLOCATION_UNIT);
    switch (memory) {
        .video => {
            put(b, 0x10, 0x800);
            put(b, 0x14, 0x4_0000);
            put(b, 0x70, 0x3_0000);
            put(b, 0x74, 0x3_0000);
            put(b, 0x78, 0x1_0000);
        },
        .system, .ring => {
            put(b, 0x10, 0x100_0000);
            put(b, 0x14, if (memory == .ring) 0x4_0100 else 0x4_0000);
            if (memory == .ring) put(b, 0x20, 0x2_0000);
            put(b, 0x70, 0x40_0000);
            put(b, 0x74, 0x40_0000);
            put(b, 0x78, 0x40_0000);
        },
    }
    put(b, 0x28, 0x42);
    put(b, 0x6c, 0x1_0000);
    put(b, 0x90, 0x1_0000);
    put(b, 0xb8, 0x2_0000);
    put(b, 0xc0, 0x200);
    put(b, 0xcc, 0x20);
    put(b, 0xd0, units);
    put(b, 0x110, 0x20);
    put(b, 0x118, units);
    put(b, 0x130, 0x1_0000);
    put(b, 0x134, 0x1_0000);
    put(b, 0x138, 0x1_0000);
    put(b, 0x1cc, 0x20);
}

// ── A submission (submit_to_hw_queue) ───────────────────────────────────────

pub const SUBMIT_BYTES = 536;

/// A submission's data: the GPFIFO ring's write index (the entry after the
/// last one written, mod the ring's entries): how far the GPU reads the
/// ring. (The call is the doorbell; its own fence argument is the value the
/// queue's progress fence reaches, counting on past the ring's wraps, and
/// its command buffer NVIDIA's 0xdeadbeef, 1 byte. NVIDIA's driver rang
/// 1023, then 0 with fence 1024.)
pub fn submit(b: *[SUBMIT_BYTES]u8, gp_put: u64) void {
    @memset(b, 0);
    put(b, 0, MAGIC);
    put(b, 4, KIND_OBJECT);
    put(b, 12, 0x118);
    put(b, 0x10, 0x20);
    put(b, 0x14, 1);
    put64(b, 0x78, gp_put);
    put(b, 0x110, 0x10);
}

pub const SUBMIT_COMMAND_BUFFER: u64 = 0xdead_beef;

// ── GPFIFO entries ──────────────────────────────────────────────────────────

/// GP_ENTRY1's LEVEL bit (subroutine), which NVIDIA's driver sets on every
/// entry it writes.
pub const ENTRY_SUBROUTINE: u64 = 1 << 41;

const testing = std.testing;

fn word(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

test "a context's data: the header, the name twice, the constants" {
    var b: [CONTEXT_BYTES]u8 = undefined;
    context(&b, "cudaprobe", 5);
    try testing.expectEqual(MAGIC, word(&b, 0));
    try testing.expectEqual(@as(u32, 0xc80), word(&b, 8));
    try testing.expectEqual(@as(u32, 0x61647563), word(&b, 0x28)); // "cuda"
    try testing.expectEqual(@as(u32, 0x750063), word(&b, 0x128)); // "cu" in UTF-16
    try testing.expectEqual(@as(u32, 0x65), word(&b, 0x138)); // "e"
    try testing.expectEqual(@as(u32, 1), word(&b, 0xc74));
}

test "a hardware queue's data is NVIDIA's (queue 0 of cudaprobe's trace)" {
    var b: [QUEUE_BYTES]u8 = undefined;
    queue(&b, ENGINES_CUDA, 0x2_0060_0000, 0x2000, 0x4000_0440);
    const want = [_]u32{ MAGIC, 0x10000, 0x8c, MAGIC2, 0xa00, 0, 0x60_0000, 2, 0x2000, 0x4000_0440 };
    for (want, 0..) |w, i| try testing.expectEqual(w, word(&b, 4 * i));
}

test "an allocation's data: memory kinds and sizes as NVIDIA's" {
    var b: [ALLOCATION_BYTES]u8 = undefined;
    allocation(&b, .ring, 2 << 20);
    try testing.expectEqual(@as(u32, 0x24a), word(&b, 8));
    try testing.expectEqual(@as(u32, 0x100_0000), word(&b, 0x10));
    try testing.expectEqual(@as(u32, 0x4_0100), word(&b, 0x14));
    try testing.expectEqual(@as(u32, 0x2_0000), word(&b, 0x20));
    try testing.expectEqual(@as(u32, 0x20), word(&b, 0xd0));
    allocation(&b, .video, 22 << 20);
    try testing.expectEqual(@as(u32, 0x800), word(&b, 0x10));
    try testing.expectEqual(@as(u32, 0x160), word(&b, 0x118));
    try testing.expectEqual(@as(u32, 0), word(&b, 0x20));
}

test "a legacy context's data is cudaprobe's on driver 576 (its node-0 context)" {
    var b: [LEGACY_CONTEXT_BYTES]u8 = undefined;
    legacyContext(&b, "cudaprobe", 5);
    const want = [_][2]u32{
        .{ 0, MAGIC },          .{ 4, 0x10004 },        .{ 8, 0xdf1 },          .{ 0xc, MAGIC2 },
        .{ 0x10, 5 },           .{ 0x14, 0x400600c },   .{ 0x128, 0xc },        .{ 0x134, 0x61647563 },
        .{ 0x138, 0x626f7270 }, .{ 0x13c, 0x65 },       .{ 0x234, 0x750063 },   .{ 0x238, 0x610064 },
        .{ 0x23c, 0x720070 },   .{ 0x240, 0x62006f },   .{ 0x244, 0x65 },       .{ 0xd4c, 0x4ec },
        .{ 0xdc0, 0xffffff00 }, .{ 0xdc4, 0xffffffff }, .{ 0xdd4, 0xffffffff }, .{ 0xdd8, 0xff },
        .{ 0xdec, 0x100 },
    };
    var nonzero: usize = 0;
    var off: usize = 0;
    while (off + 4 <= b.len) : (off += 4) nonzero += @intFromBool(word(&b, off) != 0);
    for (want) |w| try testing.expectEqual(w[1], word(&b, w[0]));
    try testing.expectEqual(@as(usize, 24), nonzero);
}

test "a legacy submission's data is cudaprobe's on driver 576 (one entry, 6 dwords)" {
    var b: [LEGACY_SUBMIT_MAX]u8 = undefined;
    const n = legacySubmit(&b, &.{push.gpEntry(0x2_0220_0000, 6)});
    try testing.expectEqual(@as(u32, 0x35c), n);
    try testing.expectEqual(@as(u32, 0x10004), word(&b, 4));
    try testing.expectEqual(@as(u32, 0), word(&b, 8));
    try testing.expectEqual(@as(u32, 0x354), word(&b, 0xc));
    try testing.expectEqual(@as(u32, 1), word(&b, 0x18));
    try testing.expectEqual(@as(u32, 0x0220_0000), word(&b, 0x354));
    try testing.expectEqual(@as(u32, 0x1802), word(&b, 0x358));
}

test "the video contexts and submissions are h264_nvenc's on driver 576 (its decoder and encoder contexts, a decoder submission)" {
    // (2026-11-22, this PC's RTX 2080 Ti: the decoder's context on node 8,
    // the encoder's on node 5; every nonzero dword of each)
    for ([_]VideoEngine{ .decoder, .encoder }) |e| {
        var b: [VIDEO_CONTEXT_BYTES]u8 = undefined;
        videoContext(&b, e);
        const want = [_][2]u32{
            .{ 0, MAGIC },          .{ 4, 0x10004 },                            .{ 8, 0xdf1 },          .{ 0xc, MAGIC2 },
            .{ 0x10, 5 },           .{ 0x14, 0x400f },                          .{ 0x1c, 0x200 },       .{ 0x20, 0x8000_0000 | @as(u32, @intFromEnum(e)) },
            .{ 0xdc0, 0xffffff00 }, .{ 0xdc4, 0xffffffff },                     .{ 0xdd4, 0xffffffff }, .{ 0xdd8, 0xff },
        };
        var nonzero: usize = 0;
        var off: usize = 0;
        while (off + 4 <= b.len) : (off += 4) nonzero += @intFromBool(word(&b, off) != 0);
        for (want) |w| try testing.expectEqual(w[1], word(&b, w[0]));
        try testing.expectEqual(@as(usize, 15), nonzero);
    }
    try testing.expectEqual(@as(u32, 8), videoNodeOn(.decoder, true));
    try testing.expectEqual(@as(u32, 5), videoNodeOn(.encoder, true));
    try testing.expectEqual(@as(u32, 1), videoNodeOn(.decoder, false));
    // the decoder's first submission: 32 dwords at 0xf_0002_8000
    var s: [VIDEO_SUBMIT_BYTES]u8 = undefined;
    videoSubmit(&s, 0xf_0002_8000, 32);
    const want = [_][2]u32{ .{ 0, MAGIC }, .{ 4, 0x10004 }, .{ 0xc, 0x354 }, .{ 0x14, 1 }, .{ 0x18, 2 }, .{ 0x1c, 8 }, .{ 0x358, 4 }, .{ 0x35c, 0x0002_8000 }, .{ 0x360, 0x820f } };
    var nonzero: usize = 0;
    var off: usize = 0;
    while (off + 4 <= s.len) : (off += 4) nonzero += @intFromBool(word(&s, off) != 0);
    for (want) |w| try testing.expectEqual(w[1], word(&s, w[0]));
    try testing.expectEqual(want.len, nonzero);
}

test "a submission's data" {
    var b: [SUBMIT_BYTES]u8 = undefined;
    submit(&b, 0x9c);
    try testing.expectEqual(@as(u32, 0x118), word(&b, 12));
    try testing.expectEqual(@as(u32, 0x9c), word(&b, 120));
    try testing.expectEqual(@as(u32, 0x10), word(&b, 272));
}
