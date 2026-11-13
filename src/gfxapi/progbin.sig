//! @zpm/gfxapi progbin — the program binary format (glGetProgramBinary,
//! glProgramBinary; GL ES 3.0 and OES_get_program_binary): what a link
//! made, written into the caller's buffer and read back, checked whole
//! before a byte of it is trusted.
//!
//! A binary (little-endian throughout):
//!
//!   offset  size  what
//!   0       8     magic "GXPRGBIN"
//!   8       4     format version (VERSION)
//!   12      4     header bytes (HEADER_BYTES, 48)
//!   16      4     total bytes (header and sections)
//!   20      4     sections
//!   24      8     driver build id (DRIVER_BUILD)
//!   32      8     GPU id (gpuId: the engine's device, or the CPU)
//!   40      8     checksum: Wyhash (seed CHECK_SEED) of bytes 0..40 and
//!                 48..total
//!   48      ...   sections: a tag (4 ASCII bytes), its length (u32), its
//!                 bytes; in the order program.sig writes them
//!
//! What the sections hold is program.sig's (encodeBinary): the linked
//! program's interface tables, the pipeline's flags, and the two stages'
//! code as the link kept it (GLSL ES, which the engine generates the draw
//! kernels from, for its own GPU, at the pipeline's first draw). A binary
//! another driver build wrote, or one written for another GPU, is refused
//! whole (GL: the program's LINK_STATUS false, the reason in its log), as
//! is one whose checksum or length does not hold: WebRender then compiles
//! and links the shaders again and stores the new binary.
//!
//! The driver build id is the hash, taken at compile time, of the sources
//! that decide what a link makes and how the engine reads it (this file,
//! program.sig, raster.sig, texture.sig and the GLSL front end) and the
//! Sig compiler's version: any change to them is another build, whose
//! binaries the old one refuses and the reverse. (Not the CPU: the format
//! is the same on each, so the PC's and the Surface's drivers built from
//! one source are one build, with one tag.)
//!
//! GL_RENDERER ends with that build's tag, "gx-" and the id's low 32 bits
//! in hex (BUILD_TAG), on every path (a GPU, the CPU): WebRender's cache
//! names each program by GL_RENDERER and its source, so a new driver build
//! names its programs anew and never asks for the old build's binaries
//! (which it would refuse, and WebRender would never write again).
//!
//! Allocation-free: the writer counts or fills the caller's buffer; the
//! reader walks the caller's bytes.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");

/// The one binary format the driver lists (PROGRAM_BINARY_FORMATS): a
/// value outside Khronos' registered enums ("GXPB"), so no other driver's
/// binary is taken for this one.
pub const FORMAT: u32 = 0x4758_5042;
pub const MAGIC = "GXPRGBIN".*;
/// Bump when what a section holds changes shape (the driver build id
/// changes with the sources anyway).
pub const VERSION: u32 = 2; // (2: the pipeline section also says whether the pixel code reads gl_FrontFacing)
pub const HEADER_BYTES = 48;
pub const CHECK_SEED: u64 = 0x6761_6c61_7879_6762; // "galaxygb"

/// The sections' tags.
pub const LINK = tag("LINK");
pub const PIPE = tag("PIPE");
pub const VSRC = tag("VSRC");
pub const FSRC = tag("FSRC");

fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

// ── The build and the GPU ──────────────────────────────────────────────────

/// The files whose bytes make the driver build id (relative to this file).
const BUILD_FILES = [_][]const u8{
    "progbin.sig",
    "program.sig",
    "raster.sig",
    "texture.sig",
    "glsl/glsl.sig",
    "glsl/lex.sig",
    "glsl/pp.sig",
    "glsl/parse.sig",
    "glsl/sema.sig",
    "glsl/gen.sig",
};

/// A hash of `s` into eight 64-bit lanes, 64 bytes a step (cheap enough at
/// compile time: half a megabyte of sources in well under a second).
fn mixLanes(h0: @Vector(8, u64), comptime s: []const u8) @Vector(8, u64) {
    @setEvalBranchQuota(10_000_000);
    const V = @Vector(8, u64);
    const k: V = @splat(0x9E37_79B9_7F4A_7C15);
    var h = h0 ^ @as(V, @splat(@as(u64, s.len)));
    var i: usize = 0;
    while (i + 64 <= s.len) : (i += 64) {
        const w: V = @bitCast(s[i..][0..64].*);
        h = (h ^ w) *% k;
        h ^= h >> @splat(29);
    }
    var tail: [64]u8 = @splat(0);
    @memcpy(tail[0 .. s.len - i], s[i..]);
    h = (h ^ @as(V, @bitCast(tail))) *% k;
    h ^= h >> @splat(31);
    return h;
}

/// This driver build's id (see the file's head).
pub const DRIVER_BUILD: u64 = blk: {
    @setEvalBranchQuota(10_000_000);
    var h: @Vector(8, u64) = @splat(VERSION);
    for (BUILD_FILES) |f| h = mixLanes(h, @embedFile(f));
    h = mixLanes(h, builtin.zig_version_string);
    var r: u64 = 0xcbf2_9ce4_8422_2325;
    for (0..8) |j| r = (r ^ h[j]) *% 0x0000_0100_0000_01B3;
    break :blk r;
};

/// This build's tag, as GL_RENDERER ends: "gx-" and DRIVER_BUILD's low 32
/// bits, 8 hex digits.
pub const BUILD_TAG = std.fmt.comptimePrint("gx-{x:0>8}", .{@as(u32, @truncate(DRIVER_BUILD))});

/// The GPU a binary is for: the device's vendor, ISA and name, or the CPU
/// (an engine without a device). A GPU lost since stays the engine's.
pub fn gpuId(caps: ?gpu.Caps) u64 {
    var h = std.hash.Wyhash.init(CHECK_SEED);
    if (caps) |cp| {
        h.update("gpu:");
        h.update(@tagName(cp.vendor));
        h.update(":");
        h.update(@tagName(cp.target));
        h.update(":");
        h.update(cp.name);
    } else h.update("cpu");
    return h.final();
}

// ── Writing ────────────────────────────────────────────────────────────────

/// Writes a binary into `buf`, or (buf null) only counts its bytes.
pub const Writer = struct {
    buf: ?[]u8 = null,
    n: usize = 0,
    overflow: bool = false,
    sections: u32 = 0,
    open: ?usize = null,

    pub fn counter() Writer {
        return .{ .n = HEADER_BYTES };
    }

    pub fn into(buf: []u8) Writer {
        return .{ .buf = buf, .n = HEADER_BYTES, .overflow = buf.len < HEADER_BYTES };
    }

    pub fn bytes(w: *Writer, s: []const u8) void {
        if (w.buf) |b| {
            if (w.n + s.len > b.len) {
                w.overflow = true;
            } else @memcpy(b[w.n..][0..s.len], s);
        }
        w.n += s.len;
    }

    pub fn int(w: *Writer, comptime T: type, v: T) void {
        var x: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &x, v, .little);
        w.bytes(&x);
    }

    pub fn u_8(w: *Writer, v: u8) void {
        w.int(u8, v);
    }
    pub fn u_16(w: *Writer, v: u16) void {
        w.int(u16, v);
    }
    pub fn u_32(w: *Writer, v: u32) void {
        w.int(u32, v);
    }
    pub fn u_64(w: *Writer, v: u64) void {
        w.int(u64, v);
    }
    pub fn flag(w: *Writer, v: bool) void {
        w.int(u8, @intFromBool(v));
    }

    /// A section: its tag and a length end() fills in.
    pub fn begin(w: *Writer, t: u32) void {
        std.debug.assert(w.open == null);
        w.u_32(t);
        w.open = w.n;
        w.u_32(0);
    }

    pub fn end(w: *Writer) void {
        const at = w.open.?;
        w.open = null;
        w.sections += 1;
        const len: u32 = @intCast(w.n - at - 4);
        if (w.buf) |b| {
            if (at + 4 <= b.len) std.mem.writeInt(u32, b[at..][0..4], len, .little);
        }
    }

    /// The header written over the first HEADER_BYTES, the checksum last:
    /// the binary, or null (it did not fit).
    pub fn finish(w: *Writer, gpu_id: u64) ?[]u8 {
        const b = w.buf orelse return null;
        if (w.overflow or w.n > b.len or w.n > std.math.maxInt(u32)) return null;
        const out = b[0..w.n];
        @memcpy(out[0..8], &MAGIC);
        std.mem.writeInt(u32, out[8..12], VERSION, .little);
        std.mem.writeInt(u32, out[12..16], HEADER_BYTES, .little);
        std.mem.writeInt(u32, out[16..20], @intCast(w.n), .little);
        std.mem.writeInt(u32, out[20..24], w.sections, .little);
        std.mem.writeInt(u64, out[24..32], DRIVER_BUILD, .little);
        std.mem.writeInt(u64, out[32..40], gpu_id, .little);
        std.mem.writeInt(u64, out[40..48], checksum(out), .little);
        return out;
    }
};

/// The checksum of a binary (its checksum field left out).
pub fn checksum(b: []const u8) u64 {
    var h = std.hash.Wyhash.init(CHECK_SEED);
    h.update(b[0..40]);
    h.update(b[HEADER_BYTES..]);
    return h.final();
}

// ── Reading ────────────────────────────────────────────────────────────────

/// Why a binary is refused, as the program's log says it.
pub const Refusal = enum {
    short,
    magic,
    version,
    length,
    driver,
    gpu,
    checksum,
    malformed,
    too_large,

    pub fn text(r: Refusal) []const u8 {
        return switch (r) {
            .short => "the program binary is shorter than its header",
            .magic => "this is not a Galaxy program binary",
            .version => "the program binary's format version is another driver's",
            .length => "the program binary's length is not the one its header says",
            .driver => "the program binary was made by another driver build",
            .gpu => "the program binary was made for another GPU",
            .checksum => "the program binary's checksum does not hold (it is damaged)",
            .malformed => "the program binary's contents are not a program's",
            .too_large => "the program binary's program does not fit this driver",
        };
    }
};

/// The header checked (magic, version, length, driver build, GPU, checksum,
/// in that order): null when the binary may be read.
pub fn check(b: []const u8, gpu_id: u64) ?Refusal {
    if (b.len < HEADER_BYTES) return .short;
    if (!std.mem.eql(u8, b[0..8], &MAGIC)) return .magic;
    if (std.mem.readInt(u32, b[8..12], .little) != VERSION) return .version;
    if (std.mem.readInt(u32, b[12..16], .little) != HEADER_BYTES) return .version;
    if (std.mem.readInt(u32, b[16..20], .little) != b.len) return .length;
    if (std.mem.readInt(u64, b[24..32], .little) != DRIVER_BUILD) return .driver;
    if (std.mem.readInt(u64, b[32..40], .little) != gpu_id) return .gpu;
    if (std.mem.readInt(u64, b[40..48], .little) != checksum(b)) return .checksum;
    return null;
}

/// Reads a checked binary's sections, in order. Reading past a section's
/// end, or a section not where it should be, sets `bad`: the reads then
/// give zeros, and the caller refuses the binary.
pub const Reader = struct {
    b: []const u8,
    at: usize = 0,
    bad: bool = false,

    /// The sections of a binary check() passed.
    pub fn of(b: []const u8) Reader {
        return .{ .b = b[HEADER_BYTES..] };
    }

    pub fn bytes(r: *Reader, n: usize) []const u8 {
        if (r.bad or n > r.b.len - r.at) {
            r.bad = true;
            return &.{};
        }
        defer r.at += n;
        return r.b[r.at..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) T {
        const s = r.bytes(@sizeOf(T));
        if (s.len != @sizeOf(T)) return 0;
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    pub fn u_8(r: *Reader) u8 {
        return r.int(u8);
    }
    pub fn u_16(r: *Reader) u16 {
        return r.int(u16);
    }
    pub fn u_32(r: *Reader) u32 {
        return r.int(u32);
    }
    pub fn u_64(r: *Reader) u64 {
        return r.int(u64);
    }
    pub fn flag(r: *Reader) bool {
        const v = r.u_8();
        if (v > 1) r.bad = true;
        return v == 1;
    }

    /// A count of at most `max` things.
    pub fn count(r: *Reader, max: usize) usize {
        const n = r.u_32();
        if (n > max) {
            r.bad = true;
            return 0;
        }
        return n;
    }

    /// The next section, which must be `t`: a reader over its bytes.
    pub fn section(r: *Reader, t: u32) Reader {
        if (r.u_32() != t) r.bad = true;
        const len = r.u_32();
        const s = r.bytes(len);
        return .{ .b = s, .bad = r.bad };
    }

    /// All of it read, nothing left over.
    pub fn done(r: *const Reader) bool {
        return !r.bad and r.at == r.b.len;
    }
};

test "progbin: header, sections, checksum, refusals" {
    var buf: [256]u8 = undefined;
    const gid = gpuId(null);
    var cw = Writer.counter();
    var w = Writer.into(&buf);
    for ([_]*Writer{ &cw, &w }) |x| {
        x.begin(LINK);
        x.u_32(300);
        x.bytes("abc");
        x.end();
        x.begin(VSRC);
        x.u_64(7);
        x.end();
    }
    const b = w.finish(gid).?;
    try std.testing.expectEqual(cw.n, b.len);
    try std.testing.expectEqual(@as(usize, HEADER_BYTES + 8 + 7 + 8 + 8), b.len);
    try std.testing.expect(check(b, gid) == null);
    var r = Reader.of(b);
    var s = r.section(LINK);
    try std.testing.expectEqual(@as(u32, 300), s.u_32());
    try std.testing.expectEqualStrings("abc", s.bytes(3));
    try std.testing.expect(s.done());
    var v = r.section(VSRC);
    try std.testing.expectEqual(@as(u64, 7), v.u_64());
    try std.testing.expect(v.done() and r.done());
    // (a section out of order, or read past its end)
    var r2 = Reader.of(b);
    _ = r2.section(VSRC);
    try std.testing.expect(r2.bad);
    var r3 = Reader.of(b);
    var s3 = r3.section(LINK);
    _ = s3.bytes(8);
    try std.testing.expect(s3.bad);

    // every byte flipped is refused (a header field by its check, a
    // section's by the checksum); so is every shortening
    for (0..b.len) |i| {
        var bad: [256]u8 = undefined;
        @memcpy(bad[0..b.len], b);
        bad[i] ^= 0x10;
        try std.testing.expect(check(bad[0..b.len], gid) != null);
    }
    for (0..b.len) |n| try std.testing.expect(check(b[0..n], gid) != null);
    // another GPU, another driver build
    try std.testing.expectEqual(Refusal.gpu, check(b, gpuId(gpu.interp_caps)).?);
    var other: [256]u8 = undefined;
    @memcpy(other[0..b.len], b);
    std.mem.writeInt(u64, other[24..32], DRIVER_BUILD ^ 1, .little);
    std.mem.writeInt(u64, other[40..48], checksum(other[0..b.len]), .little);
    try std.testing.expectEqual(Refusal.driver, check(other[0..b.len], gid).?);
    // (a buffer too small: no binary)
    var small: [40]u8 = undefined;
    var ws = Writer.into(&small);
    ws.begin(LINK);
    ws.end();
    try std.testing.expect(ws.finish(gid) == null);
    try std.testing.expect(DRIVER_BUILD != 0);
    // (the tag: "gx-" and the id's low 32 bits)
    try std.testing.expect(std.mem.startsWith(u8, BUILD_TAG, "gx-"));
    try std.testing.expectEqual(@as(u32, @truncate(DRIVER_BUILD)), try std.fmt.parseInt(u32, BUILD_TAG[3..], 16));
}
