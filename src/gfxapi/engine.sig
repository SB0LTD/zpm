//! @zpm/gfxapi engine — the pixel work under the GL and EGL layers: images
//! in GPU memory, filled and copied by KIR kernels through any gpu.Device
//! (the Adreno through ir3, the RTX through sm_120, EmuDevice through the
//! interpreter), batched, with the same work done on the CPU when there is
//! no GPU, it is lost, or an image has no GPU address.
//!
//! - **Batched.** Fills and copies are recorded and run together, one
//!   Device.run (one submission, one fence) per batch: at a flush, a
//!   finish, a CPU access to an image the batch touches, or when the batch
//!   is full. The CPU goes on while the GPU works.
//! - **Waits only where needed.** Each image remembers the last batch that
//!   used it. A CPU read or write waits for that batch alone; an image no
//!   batch in flight uses is touched at once.
//! - **Cache upkeep.** Before the CPU reads what the GPU wrote: fromDevice
//!   of the rows read. Before the CPU writes: fromDevice of the rows it
//!   writes, when the GPU wrote the image (a partly written cache line
//!   would otherwise carry stale bytes back), then toDevice of them.
//! - **Frees after the GPU.** A buffer a batch in flight may still use is
//!   freed once that batch is done (`doomed`), never under the GPU.
//! - **The CPU fallback.** Each op has a CPU form with the same result, bit
//!   for bit. When a run fails, its batch is done again on the CPU and the
//!   engine stays on the CPU (`lost`, which GL reports as a reset).
//!
//! - **Shared memory.** An EGLImage and the GL textures made of it name one
//!   memory (`Shared`): what the GPU has pending on it is tracked once,
//!   for every name, and it is freed with the last of them.
//!
//! Images draws write are RGBA8, BGRA8, RG8 or R8 (4, 2, 1 bytes a
//! pixel); textures may be in other formats, which draws only read
//! (Format). Rectangles are in GL's
//! coordinates, y from the bottom; an image whose row 0 is its top (a
//! window's buffer) says so (`top_down`) and the engine flips rows.
//!
//! Allocation-free: the engine is the caller's, at a fixed address (its
//! dispatches point into it); images come from the device, or from `pool`,
//! caller memory handed out first fit.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const raster = @import("raster.sig");
const texture = @import("texture.sig");
const blocklinear = @import("blocklinear.sig");
const report = @import("report.sig");
const kir = gpu.kir;
const r = kir.r;
const u = kir.u;

pub const Format = enum(u8) {
    /// bytes R, G, B, A: GL's RGBA8, DRM's ABGR8888
    rgba8,
    /// bytes B, G, R, A: GL's BGRA8_EXT, DRM's ARGB8888 and XRGB8888
    bgra8,
    /// depth in the low 24 bits, stencil in the top 8: GL's
    /// DEPTH24_STENCIL8 (and its depth-only and stencil-only formats)
    d24s8,
    // textures draws read (texture.sig), not draw into:
    /// one and two bytes (unorm): R8, RG8 (and LUMINANCE, ALPHA,
    /// LUMINANCE_ALPHA, swizzled)
    r8,
    rg8,
    /// f32 x 1, 2, 4 (the half floats too, widened)
    r32f,
    rg32f,
    rgba32f,
    /// i32 and u32 x 1, 2, 4 (the 8- and 16-bit integer formats too)
    r32i,
    rg32i,
    rgba32i,
    r32ui,
    rg32ui,
    rgba32ui,
    /// two bytes a channel (unorm16): an imported dma-buf's DRM R16 and
    /// GR1616 (video's 10- to 16-bit planes, P010's), sampled as GL's
    /// R16_EXT and RG16_EXT; never drawn into, copied or mipmapped (GL's
    /// own R16 and RG16 uploads are stored as floats: texfmt.sig)
    r16,
    rg16,

    /// A color format of four bytes a pixel (RGBA8, BGRA8).
    pub fn isColor(f: Format) bool {
        return f == .rgba8 or f == .bgra8;
    }

    /// A color format draws, clears and copies write: the four-byte ones,
    /// RG8 and R8 (their channels from byte 0, as RGBA8's).
    pub fn renderable(f: Format) bool {
        return f.isColor() or f == .r8 or f == .rg8;
    }

    pub fn bytes(f: Format) u32 {
        return switch (f) {
            .r8 => 1,
            .rg8, .r16 => 2,
            .rg32f, .rg32i, .rg32ui => 8,
            .rgba32f, .rgba32i, .rgba32ui => 16,
            else => 4,
        };
    }

    pub fn channels(f: Format) u32 {
        return switch (f) {
            .r8, .r16, .r32f, .r32i, .r32ui, .d24s8 => 1,
            .rg8, .rg16, .rg32f, .rg32i, .rg32ui => 2,
            else => 4,
        };
    }

    /// (texture.sig's descriptor keeps it in three bits: unorm16's bit 2
    /// says two bytes a channel, its low two bits read as unorm8's)
    pub const Kind = enum(u3) { unorm8, float, int, uint, unorm16 };

    /// What a texel's channels are.
    pub fn kind(f: Format) Kind {
        return switch (f) {
            .r16, .rg16 => .unorm16,
            .r32f, .rg32f, .rgba32f => .float,
            .r32i, .rg32i, .rgba32i => .int,
            .r32ui, .rg32ui, .rgba32ui, .d24s8 => .uint,
            else => .unorm8,
        };
    }
};

/// A rectangle in GL's coordinates (x, y from the bottom left), x0 <= x1.
pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn empty(a: Rect) bool {
        return a.x1 <= a.x0 or a.y1 <= a.y0;
    }
    pub fn meet(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x0, b.x0);
        const y0 = @max(a.y0, b.y0);
        return .{ .x0 = x0, .y0 = y0, .x1 = @max(x0, @min(a.x1, b.x1)), .y1 = @max(y0, @min(a.y1, b.y1)) };
    }
    pub fn width(a: Rect) u32 {
        return a.x1 - a.x0;
    }
    pub fn height(a: Rect) u32 {
        return a.y1 - a.y0;
    }
};

/// Mipmap levels an image may hold (8192 pixels down to 1).
pub const MAX_LEVELS = 14;

pub const Image = struct {
    buf: gpu.Buffer = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// bytes from one row to the next (a multiple of 4)
    stride: u32 = 0,
    format: Format = .rgba8,
    /// row 0 is the top (a window's buffer), not GL's bottom
    top_down: bool = false,
    /// the engine made it (freeImage gives it back); else the caller's
    /// (a window's dma-buf)
    own: bool = false,
    /// in the engine's pool (CPU memory: no GPU address)
    pooled: bool = false,
    /// what the GPU has pending on it (a shared image's is its Shared's)
    track: Track = .{},
    /// memory other images name too (an EGLImage's), if any
    share: ?*Shared = null,
    /// a color image without alpha (an XRGB surface's): read, and copied
    /// from, as opaque whatever its top byte holds
    no_alpha: bool = false,
    /// mipmap levels held (newImageChain), each after the one before: level
    /// l is levelWidth(l) x levelHeight(l), rows levelStride(l) bytes
    /// apart, from byte level_at[l]; level 0 is the image itself
    levels: u8 = 1,
    level_at: [MAX_LEVELS]u32 = [_]u32{0} ** MAX_LEVELS,
    /// how its memory is laid out: pitch linear (the engine's own, and
    /// most imports), or block linear (a video decoder's picture imported
    /// with NVIDIA's modifier: `stride` its pitch in bytes, whole GOBs).
    /// A block-linear image is only sampled (texture.sig reads the GOBs
    /// in place): never drawn into, copied, read back or mipmapped.
    layout: blocklinear.Layout = .{},
    /// samples a pixel (multisampled: 2, 4, 8): a pixel's samples side by
    /// side in its row (sample s of pixel x at x * samples + s), so a row
    /// is width * samples pixels' bytes; `width` counts pixels
    samples: u8 = 1,

    /// Whether the engine may draw into, copy, read back or mipmap it: a
    /// renderable format, laid out pitch linear.
    pub fn drawable(img: *const Image) bool {
        return img.format.renderable() and img.layout.linear();
    }

    pub fn levelWidth(img: *const Image, l: u32) u32 {
        return @max(img.width >> @intCast(l), 1);
    }
    pub fn levelHeight(img: *const Image, l: u32) u32 {
        return @max(img.height >> @intCast(l), 1);
    }
    pub fn levelStride(img: *const Image, l: u32) u32 {
        return if (l == 0) img.stride else std.mem.alignForward(u32, img.levelWidth(l) * img.format.bytes(), 4);
    }

    pub fn bounds(img: *const Image) Rect {
        return .{ .x0 = 0, .y0 = 0, .x1 = img.width, .y1 = img.height };
    }
    /// The memory row of GL row y.
    pub fn rowOf(img: *const Image, y: u32) u32 {
        return if (img.top_down) img.height - 1 - y else y;
    }
    pub fn live(img: *const Image) bool {
        return img.width != 0 and img.buf.cpu.len != 0;
    }
    fn trk(img: *Image) *Track {
        return if (img.share) |s| &s.track else &img.track;
    }
    /// The GPU wrote it since the CPU last fetched it.
    pub fn gpuWrote(img: *const Image) bool {
        return if (img.share) |s| s.track.gpu_wrote else img.track.gpu_wrote;
    }
    /// The last batch that used it on the GPU (0: none).
    pub fn lastBatch(img: *const Image) u64 {
        return if (img.share) |s| s.track.last else img.track.last;
    }
    fn words(img: *const Image) []u32 {
        return img.buf.words();
    }
};

pub const Track = struct {
    /// the last batch that used it on the GPU (0: none)
    last: u64 = 0,
    /// the GPU wrote it since the CPU last fetched it
    gpu_wrote: bool = false,
};

/// Memory several images name (an EGLImage, the GL textures and
/// renderbuffers made of it): one track, freed with the last name.
pub const Shared = struct {
    refs: u32 = 0,
    /// the whole buffer (an image may start inside it)
    buf: gpu.Buffer = .{},
    pooled: bool = false,
    track: Track = .{},
    external: ?struct {
        context: *anyopaque,
        release: *const fn (*anyopaque) void,
    } = null,
};

/// The first name of memory to be shared (`whole`, its pixels from byte
/// `off`: an imported dma-buf's plane), with `sh` holding it.
pub fn adopt(sh: *Shared, whole: gpu.Buffer, off: usize, width: u32, height: u32, stride: u32, format: Format) Image {
    sh.* = .{ .refs = 1, .buf = whole };
    var view = whole;
    if (view.gpu != 0) view.gpu += off;
    view.cpu = whole.cpu[off..];
    view.bytes = whole.bytes - off;
    return .{ .buf = view, .width = width, .height = height, .stride = stride, .format = format, .own = true, .share = sh };
}

/// Another name for a shared image's memory.
pub fn alias(img: *const Image) Image {
    std.debug.assert(img.share != null);
    img.share.?.refs += 1;
    return img.*;
}

/// A borrowed 2D slice of a texture. The owning texture retains the
/// allocation and the slice and owner track the same GPU access.
pub fn borrowSlice(img: *Image, share: *Shared, level: u32, layer: u32) Image {
    if (img.share == null) {
        share.* = .{ .refs = 1, .buf = img.buf, .pooled = img.pooled, .track = img.track };
        img.share = share;
    }
    const height = img.levelHeight(level);
    const stride = img.levelStride(level);
    const bytes = @as(usize, height) * stride;
    const off = img.level_at[level] + @as(usize, layer) * bytes;
    var buf = img.buf;
    if (buf.gpu != 0) buf.gpu += off;
    buf.cpu = buf.cpu[off..][0..bytes];
    buf.bytes = bytes;
    var view = wrap(buf, img.levelWidth(level), height, stride, img.format, img.top_down);
    view.share = img.share;
    view.pooled = img.pooled;
    view.no_alpha = img.no_alpha;
    return view;
}

/// An image over memory someone else has (a window's buffer): `buf` with
/// a CPU view, rows `stride` bytes apart.
pub fn wrap(buf: gpu.Buffer, width: u32, height: u32, stride: u32, format: Format, top_down: bool) Image {
    return .{ .buf = buf, .width = width, .height = height, .stride = stride, .format = format, .top_down = top_down };
}

// ── The pool: CPU memory for images when the GPU gives none ───────────────

pub const MAX_SPANS = 1024;
/// (128: a 3D engine's colour target starts on 128 bytes)
const POOL_ALIGN = 128;

/// The caller's bytes, handed out first fit (64-byte aligned) and taken
/// back in any order; the spans in use kept sorted.
pub const Pool = struct {
    mem: []u8 = &.{},
    spans: [MAX_SPANS][2]usize = undefined,
    n: usize = 0,

    pub fn init(mem: []u8) Pool {
        return .{ .mem = mem };
    }

    pub fn alloc(p: *Pool, bytes: usize) ?[]u8 {
        if (bytes == 0 or p.n == MAX_SPANS) return null;
        const base = @intFromPtr(p.mem.ptr);
        const size = std.mem.alignForward(usize, bytes, POOL_ALIGN);
        var at = std.mem.alignForward(usize, base, POOL_ALIGN) - base;
        var i: usize = 0;
        while (i <= p.n) : (i += 1) {
            const end = if (i < p.n) p.spans[i][0] else p.mem.len;
            if (at <= end and end - at >= size) {
                std.mem.copyBackwards([2]usize, p.spans[i + 1 .. p.n + 1], p.spans[i..p.n]);
                p.spans[i] = .{ at, size };
                p.n += 1;
                return p.mem[at..][0..bytes];
            }
            if (i < p.n) at = p.spans[i][0] + p.spans[i][1];
        }
        return null;
    }

    pub fn free(p: *Pool, s: []u8) void {
        if (s.len == 0) return;
        const at = @intFromPtr(s.ptr) -% @intFromPtr(p.mem.ptr);
        for (p.spans[0..p.n], 0..) |sp, i| {
            if (sp[0] != at) continue;
            std.mem.copyForwards([2]usize, p.spans[i .. p.n - 1], p.spans[i + 1 .. p.n]);
            p.n -= 1;
            return;
        }
    }

    pub fn owns(p: *const Pool, s: []const u8) bool {
        const a = @intFromPtr(s.ptr);
        const b = @intFromPtr(p.mem.ptr);
        return s.len != 0 and a >= b and a < b + p.mem.len;
    }
};

// ── The kernels ────────────────────────────────────────────────────────────

/// Threads per group (a row of pixels: one thread each).
pub const GROUP = 64;

const Prog = enum(u8) { fill, fill_masked, copy, bin, blit, mip };
const N_PROGS = @typeInfo(Prog).@"enum".field_names.len;
/// A program's code as the backend emits it (ir3, sm_120 or KIR's own).
pub const CODE_BYTES = 16 * 1024;
/// A dispatch's parameter words and bindings at most (a draw's vertex
/// kernel has the most).
const MAX_PARAMS = 160;
/// a kernel's bindings at most: the capture kernel's (its buffers,
/// uniforms, element array, attributes, textures)
const MAX_BIND = raster.MAX_CAPTURE_BUFFERS + 2 + raster.MAX_ATTRS + texture.MAX_TEX + raster.MAX_BUFFERS + raster.MAX_TARGETS;
/// KIR instructions a kernel built here may have (a pipeline's, a GLSL
/// shader inlined in it).
pub const MAX_KIR = 65536;
/// Bytes of a pipeline kernel's code as the backend emits it.
pub const PIPE_CODE = 1024 * 1024;

/// A pixel of 4, 2 or 1 bytes (`bpp`) at byte `off`: loaded (zero
/// extended), or stored (its low bytes).
fn pixelLoad(k: *kir.Kernel, b: u8, bpp: kir.V, off: kir.V) kir.V {
    const v = k.reg(.u32);
    k.ifp(r(k.cmp(.u32, .eq, r(bpp), u(4))));
    k.setAux(v, .ld, r(off), kir.no, kir.no, @bitCast(kir.global(b, 32)));
    k.els();
    k.ifp(r(k.cmp(.u32, .eq, r(bpp), u(2))));
    k.setAux(v, .ld, r(off), kir.no, kir.no, @bitCast(kir.global(b, 16)));
    k.els();
    k.setAux(v, .ld, r(off), kir.no, kir.no, @bitCast(kir.global(b, 8)));
    k.endif();
    k.endif();
    return v;
}

fn pixelStore(k: *kir.Kernel, b: u8, bpp: kir.V, off: kir.V, v: kir.V) void {
    k.ifp(r(k.cmp(.u32, .eq, r(bpp), u(4))));
    k.store(.u32, kir.global(b, 32), r(off), r(v));
    k.els();
    k.ifp(r(k.cmp(.u32, .eq, r(bpp), u(2))));
    k.store(.u32, kir.global(b, 16), r(off), r(v));
    k.els();
    k.store(.u32, kir.global(b, 8), r(off), r(v));
    k.endif();
    k.endif();
}

/// fill: rows y0.. (memory rows, one group row each), pixels x0..x0+w:
///   params 0 x0, 1 y0, 2 w, 3 stride (bytes), 4 value, 5 keep (for
///   fill_masked: the bits of each pixel kept, value has none of them:
///   pixel = (pixel & keep) | value), 6 bytes a pixel (4, 2, 1).
fn fillKernel(s: kir.Storage, masked: bool) kir.Kernel {
    var k = kir.Kernel.init(s, if (masked) "gfx_fill_masked" else "gfx_fill", .{ GROUP, 1, 1 });
    const img = k.binding();
    const x0 = k.param(.u32, 0);
    const y0 = k.param(.u32, 1);
    const w = k.param(.u32, 2);
    const stride = k.param(.u32, 3);
    const value = k.param(.u32, 4);
    const bpp = k.param(.u32, 6);
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(w))));
    const row = k.op2(.iadd, .u32, r(y0), r(k.gid(1)));
    const xb = k.op2(.imul, .u32, r(k.op2(.iadd, .u32, r(x0), r(x))), r(bpp));
    // (param 7: block linear, 1 + log2 of a block's GOBs; 0 pitch linear)
    const bl = k.param(.u32, 7);
    const gobs = k.op2(.isub, .u32, r(k.op2(.imax, .u32, r(bl), u(1))), u(1));
    const off = k.sel(.u32, r(k.cmp(.u32, .ne, r(bl), u(0))), r(blocklinear.address(&k, r(stride), r(gobs), u(0), r(xb), r(row))), r(k.op2(.iadd, .u32, r(k.op2(.imul, .u32, r(row), r(stride))), r(xb))));
    var v = value;
    if (masked) {
        const keep = k.param(.u32, 5);
        const old = pixelLoad(&k, img, bpp, off);
        v = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), r(keep))), r(value));
    }
    pixelStore(&k, img, bpp, off, v);
    k.endif();
    return k;
}

/// copy: w pixels of each of h rows, row y of the rectangle from source
/// row sy0 + y * sstep (pixels sx0..) to destination row dy0 + y * dstep
/// (pixels dx0..); steps are +1 or -1 (a flip between the images' row
/// orders). Bytes 0 and 2 of each pixel swap where `keep` lacks them (R
/// and B between bgra8 and the others): pixel = (v & keep) |
/// (swapped(v) & ~keep); a destination of fewer bytes keeps the low ones
/// (R8 from RGBA8: red).
///   params 0 sx0, 1 sy0, 2 sstep (i32), 3 sstride (bytes), 4 dx0, 5 dy0,
///   6 dstep (i32), 7 dstride (bytes), 8 w, 9 keep, 10 ~keep, 11 bits set
///   in every pixel (an opaque alpha, from an image without one), 12 the
///   source's bytes a pixel, 13 the destination's.
fn copyKernel(s: kir.Storage) kir.Kernel {
    var k = kir.Kernel.init(s, "gfx_copy", .{ GROUP, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(k.param(.u32, 8)))));
    const y = k.gid(1);
    const sbpp = k.param(.u32, 12);
    const dbpp = k.param(.u32, 13);
    const srow = k.op3(.imad, .i32, r(y), r(k.param(.i32, 2)), r(k.param(.i32, 1)));
    const drow = k.op3(.imad, .i32, r(y), r(k.param(.i32, 6)), r(k.param(.i32, 5)));
    const sat = k.op3(.imad, .u32, r(srow), r(k.param(.u32, 3)), r(k.op2(.imul, .u32, r(k.op2(.iadd, .u32, r(k.param(.u32, 0)), r(x))), r(sbpp))));
    const dat = k.op3(.imad, .u32, r(drow), r(k.param(.u32, 7)), r(k.op2(.imul, .u32, r(k.op2(.iadd, .u32, r(k.param(.u32, 4)), r(x))), r(dbpp))));
    const v = pixelLoad(&k, src, sbpp, sat);
    const lo = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(v), u(16))), u(0xff));
    const hi = k.op2(.@"and", .u32, r(k.op2(.shl, .u32, r(v), u(16))), u(0xff_0000));
    const swapped = k.op2(.@"and", .u32, r(k.op2(.@"or", .u32, r(lo), r(hi))), r(k.param(.u32, 10)));
    const kept = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(v), r(k.param(.u32, 9)))), r(swapped));
    const out = k.op2(.@"or", .u32, r(kept), r(k.param(.u32, 11)));
    pixelStore(&k, dst, dbpp, dat, out);
    k.endif();
    return k;
}

// blit's parameters
const B_DX0 = 0; // the destination's first pixel (GL's x), first row (GL's y), width
const B_DY0 = 1;
const B_W = 2;
const B_DSTRIDE = 3; // bytes
const B_DBPP = 4;
const B_DROW = 5; // the first row's memory row, and the step (i32: +1, or -1 top-down)
const B_DSTEP = 6;
const B_SSTRIDE = 7;
const B_SBPP = 8;
const B_STOPDOWN = 9;
const B_SHEIGHT = 10;
const B_SWIDTH = 11;
const B_MAPX = 12; // x: the destination rectangle's x0 (i32), the source's (f32), the scale (f32)
const B_MAPY = 15; // y: the same
const B_LINEAR = 18;
const B_SSWAP = 19; // the source is BGRA8: R and B to RGBA8's places
const B_DSWAP = 20;
const B_SET = 21; // bits every source pixel gets (an opaque alpha where it has none)
const B_WMASK = 22; // the destination's bits written (depth, stencil: the rest kept)
const B_SPIX = 23; // a source pixel's bytes (its samples': bpp * samples)
const B_SSAMPLES = 24; // the source's samples, and log2 of them, averaged (colour) or sample 0 taken
const B_SSHIFT = 25;
const B_SAVG = 26;
const BLIT_PARAMS = 27;

fn swapRBk(k: *kir.Kernel, v: kir.V) kir.V {
    const lo = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(v), u(16))), u(0xff));
    const hi = k.op2(.@"and", .u32, r(k.op2(.shl, .u32, r(v), u(16))), u(0xff_0000));
    return k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(v), u(0xff00_ff00))), r(k.op2(.@"or", .u32, r(lo), r(hi))));
}

/// blit (glBlitFramebuffer): each destination pixel of a rectangle (a
/// thread each, a group row a row) takes the source at its center mapped
/// back, x = x0' + (x - x0 + 1/2) * scale: nearest (left alone where that
/// falls outside the source image), or bilinear (taps clamped to the
/// image's edge), in exact float operations. Pixels are converted as
/// copy's are (as RGBA8's bytes between; what a source lacks is 0, alpha
/// opaque). bindings: 0 source, 1 destination (written).
fn blitKernel(s: kir.Storage) kir.Kernel {
    var k = kir.Kernel.init(s, "gfx_blit", .{ GROUP, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const xi = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(xi), r(k.param(.u32, B_W)))));
    {
        const x = k.op2(.iadd, .i32, r(k.param(.i32, B_DX0)), r(xi));
        const y = k.op2(.iadd, .i32, r(k.param(.i32, B_DY0)), r(k.gid(1)));
        const sbpp = k.param(.u32, B_SBPP);
        const sw = k.param(.i32, B_SWIDTH);
        const sh = k.param(.i32, B_SHEIGHT);
        const sstride = k.param(.u32, B_SSTRIDE);
        const s_td = k.cmp(.u32, .ne, r(k.param(.u32, B_STOPDOWN)), u(0));
        const map = struct {
            fn f_(kk: *kir.Kernel, at: kir.V, w0: u16) kir.V {
                const rel = kk.cvt(.i32, .f32, .rne, r(kk.op2(.isub, .i32, r(at), r(kk.param(.i32, w0)))));
                const c = kk.op2(.fadd, .f32, r(rel), kir.f(0.5));
                return kk.op2(.fadd, .f32, r(kk.param(.f32, w0 + 1)), r(kk.op2(.fmul, .f32, r(c), r(kk.param(.f32, w0 + 2)))));
            }
        }.f_;
        const fx = map(&k, x, B_MAPX);
        const fy = map(&k, y, B_MAPY);
        // a source pixel (in the image) as RGBA8's bytes
        const texel = struct {
            fn f_(kk: *kir.Kernel, b: u8, ix: kir.V, iy: kir.V, bpp: kir.V, stride: kir.V, td: kir.V, hh: kir.V, resolve: bool) kir.V {
                const row = kk.sel(.i32, r(td), r(kk.op2(.isub, .i32, r(kk.op2(.isub, .i32, r(hh), kir.i(1))), r(iy))), r(iy));
                const off = kk.op3(.imad, .u32, r(row), r(stride), r(kk.op2(.imul, .u32, r(ix), r(kk.param(.u32, B_SPIX)))));
                var v = if (resolve) resolved(kk, b, bpp, off) else pixelLoad(kk, b, bpp, off);
                v = kk.sel(.u32, r(kk.cmp(.u32, .ne, r(kk.param(.u32, B_SSWAP)), u(0))), r(swapRBk(kk, v)), r(v));
                return kk.op2(.@"or", .u32, r(v), r(kk.param(.u32, B_SET)));
            }
        }.f_;
        const out = k.reg(.u32);
        k.set(out, .mov, u(0), kir.no, kir.no);
        const have = k.reg(.pred);
        k.set(have, .mov, u(0), kir.no, kir.no);
        k.ifp(r(k.cmp(.u32, .ne, r(k.param(.u32, B_LINEAR)), u(0))));
        {
            // bilinear: the four texels round (x - 1/2, y - 1/2), clamped
            const gx = k.op2(.fsub, .f32, r(fx), kir.f(0.5));
            const gy = k.op2(.fsub, .f32, r(fy), kir.f(0.5));
            const flx = k.op1(.ffloor, .f32, r(gx));
            const fly = k.op1(.ffloor, .f32, r(gy));
            const ax = k.op2(.fsub, .f32, r(gx), r(flx));
            const ay = k.op2(.fsub, .f32, r(gy), r(fly));
            const clampI = struct {
                fn f_(kk: *kir.Kernel, v: kir.V, hi: kir.V) kir.V {
                    return kk.op2(.imin, .i32, r(kk.op2(.imax, .i32, r(v), kir.i(0))), r(kk.op2(.isub, .i32, r(hi), kir.i(1))));
                }
            }.f_;
            const x0 = k.cvt(.f32, .i32, .rz, r(flx));
            const y0 = k.cvt(.f32, .i32, .rz, r(fly));
            const xa = clampI(&k, x0, sw);
            const xb = clampI(&k, k.op2(.iadd, .i32, r(x0), kir.i(1)), sw);
            const ya = clampI(&k, y0, sh);
            const yb = clampI(&k, k.op2(.iadd, .i32, r(y0), kir.i(1)), sh);
            const t00 = texel(&k, src, xa, ya, sbpp, sstride, s_td, sh, false);
            const t10 = texel(&k, src, xb, ya, sbpp, sstride, s_td, sh, false);
            const t01 = texel(&k, src, xa, yb, sbpp, sstride, s_td, sh, false);
            const t11 = texel(&k, src, xb, yb, sbpp, sstride, s_td, sh, false);
            const bx = k.op2(.fsub, .f32, kir.f(1), r(ax));
            const by = k.op2(.fsub, .f32, kir.f(1), r(ay));
            const w00 = k.op2(.fmul, .f32, r(bx), r(by));
            const w10 = k.op2(.fmul, .f32, r(ax), r(by));
            const w01 = k.op2(.fmul, .f32, r(bx), r(ay));
            const w11 = k.op2(.fmul, .f32, r(ax), r(ay));
            var acc = k.mov(.u32, u(0));
            for (0..4) |ch| {
                const sh8: u32 = @intCast(8 * ch);
                const byteF = struct {
                    fn f_(kk: *kir.Kernel, t: kir.V, s8: u32) kir.V {
                        return kk.cvt(.u32, .f32, .rne, r(kk.op3(.bfe, .u32, r(t), u(s8), u(8))));
                    }
                }.f_;
                var v = k.op2(.fmul, .f32, r(byteF(&k, t00, sh8)), r(w00));
                v = k.op2(.fadd, .f32, r(v), r(k.op2(.fmul, .f32, r(byteF(&k, t10, sh8)), r(w10))));
                v = k.op2(.fadd, .f32, r(v), r(k.op2(.fmul, .f32, r(byteF(&k, t01, sh8)), r(w01))));
                v = k.op2(.fadd, .f32, r(v), r(k.op2(.fmul, .f32, r(byteF(&k, t11, sh8)), r(w11))));
                const b8 = k.cvt(.f32, .u32, .rne, r(k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(v), kir.f(0))), kir.f(255))));
                acc = k.op2(.@"or", .u32, r(acc), r(k.op2(.shl, .u32, r(b8), u(sh8))));
            }
            k.set(out, .mov, r(acc), kir.no, kir.no);
            k.set(have, .mov, u(1), kir.no, kir.no);
        }
        k.els();
        {
            // nearest: the texel the center falls in, if in the image
            const ix = k.cvt(.f32, .i32, .rz, r(k.op1(.ffloor, .f32, r(fx))));
            const iy = k.cvt(.f32, .i32, .rz, r(k.op1(.ffloor, .f32, r(fy))));
            var in = k.op2(.pand, .pred, r(k.cmp(.f32, .ge, r(fx), kir.f(0))), r(k.cmp(.f32, .ge, r(fy), kir.f(0))));
            in = k.op2(.pand, .pred, r(in), r(k.cmp(.i32, .lt, r(ix), r(sw))));
            in = k.op2(.pand, .pred, r(in), r(k.cmp(.i32, .lt, r(iy), r(sh))));
            k.ifp(r(in));
            k.set(out, .mov, r(texel(&k, src, ix, iy, sbpp, sstride, s_td, sh, true)), kir.no, kir.no);
            k.set(have, .mov, u(1), kir.no, kir.no);
            k.endif();
        }
        k.endif();
        k.ifp(r(have));
        {
            const dbpp = k.param(.u32, B_DBPP);
            const drow = k.op3(.imad, .i32, r(k.gid(1)), r(k.param(.i32, B_DSTEP)), r(k.param(.i32, B_DROW)));
            const doff = k.op3(.imad, .u32, r(drow), r(k.param(.u32, B_DSTRIDE)), r(k.op2(.imul, .u32, r(x), r(dbpp))));
            var v = k.sel(.u32, r(k.cmp(.u32, .ne, r(k.param(.u32, B_DSWAP)), u(0))), r(swapRBk(&k, out)), r(out));
            const wmask = k.param(.u32, B_WMASK);
            const partial = k.cmp(.u32, .ne, r(wmask), u(0xffff_ffff));
            const merged = k.reg(.u32);
            k.set(merged, .mov, r(v), kir.no, kir.no);
            k.ifp(r(partial));
            {
                const old = pixelLoad(&k, dst, dbpp, doff);
                k.set(merged, .@"or", r(k.op2(.@"and", .u32, r(old), r(k.op1(.not, .u32, r(wmask))))), r(k.op2(.@"and", .u32, r(v), r(wmask))), kir.no);
            }
            k.endif();
            v = merged;
            pixelStore(&k, dst, dbpp, doff, v);
        }
        k.endif();
    }
    k.endif();
    return k;
}

/// A source pixel for a blit: its word, or (a multisampled colour source,
/// B_SAVG) its samples' bytes averaged, rounded half up.
fn resolved(k: *kir.Kernel, b: u8, bpp: kir.V, off: kir.V) kir.V {
    const v = k.reg(.u32);
    k.set(v, .mov, r(pixelLoad(k, b, bpp, off)), kir.no, kir.no);
    const ns = k.param(.u32, B_SSAMPLES);
    k.ifp(r(k.op2(.pand, .pred, r(k.cmp(.u32, .gt, r(ns), u(1))), r(k.cmp(.u32, .ne, r(k.param(.u32, B_SAVG)), u(0))))));
    {
        var sum: [4]kir.V = undefined;
        for (&sum, 0..) |*x, ch| {
            x.* = k.reg(.u32);
            k.set(x.*, .bfe, r(v), u(@intCast(8 * ch)), u(8));
        }
        const at = k.reg(.u32);
        k.set(at, .iadd, r(off), r(bpp), kir.no);
        const s = k.reg(.u32);
        k.set(s, .mov, u(1), kir.no, kir.no);
        k.loop();
        {
            k.brk(r(k.cmp(.u32, .ge, r(s), r(ns))));
            const w = pixelLoad(k, b, bpp, at);
            for (sum, 0..) |x, ch| k.set(x, .iadd, r(x), r(k.op3(.bfe, .u32, r(w), u(@intCast(8 * ch)), u(8))), kir.no);
            k.set(at, .iadd, r(at), r(bpp), kir.no);
            k.set(s, .iadd, r(s), u(1), kir.no);
        }
        k.endloop();
        const half = k.op2(.shr, .u32, r(ns), u(1));
        const sh = k.param(.u32, B_SSHIFT);
        var acc = k.mov(.u32, u(0));
        for (sum, 0..) |x, ch| {
            const avg = k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(x), r(half))), r(sh));
            acc = k.op2(.@"or", .u32, r(acc), r(k.op2(.shl, .u32, r(avg), u(@intCast(8 * ch)))));
        }
        k.set(v, .mov, r(acc), kir.no, kir.no);
    }
    k.endif();
    return v;
}

/// mip: a level from the one before, a thread a texel (a group row a
/// row): texels (2x, 2y), (2x + 1, 2y), (2x, 2y + 1), (2x + 1, 2y + 1)
/// (clamped to the level before: an odd edge's last one twice) averaged
/// byte by byte, rounded. params: 0 the level before's byte offset, 1 its
/// width, 2 height, 3 stride; 4..7 the same of the level made; 8 bytes a
/// texel (1, 2, 4), 9 source slices, 10 shrink depth.
fn mipKernel(s: kir.Storage) kir.Kernel {
    var k = kir.Kernel.init(s, "gfx_mip", .{ GROUP, 1, 1 });
    const img = k.binding();
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(k.param(.u32, 5)))));
    {
        const y = k.gid(1);
        const bpp = k.param(.u32, 8);
        const sw1 = k.op2(.isub, .u32, r(k.param(.u32, 1)), u(1));
        const sh1 = k.op2(.isub, .u32, r(k.param(.u32, 2)), u(1));
        const xa = k.op2(.imin, .u32, r(k.op2(.shl, .u32, r(x), u(1))), r(sw1));
        const xb = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(x), u(1))), u(1))), r(sw1));
        const ya = k.op2(.imin, .u32, r(k.op2(.shl, .u32, r(y), u(1))), r(sh1));
        const yb = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(y), u(1))), u(1))), r(sh1));
        const at = struct {
            fn f_(kk: *kir.Kernel, base: kir.V, stride: kir.V, xx: kir.V, yy: kir.V, b: kir.V) kir.V {
                return kk.op2(.iadd, .u32, r(base), r(kk.op3(.imad, .u32, r(yy), r(stride), r(kk.op2(.imul, .u32, r(xx), r(b))))));
            }
        }.f_;
        const z = k.gid(2);
        const shrink = k.cmp(.u32, .ne, r(k.param(.u32, 10)), u(0));
        const za = k.sel(.u32, r(shrink), r(k.op2(.shl, .u32, r(z), u(1))), r(z));
        const zb = k.sel(.u32, r(shrink), r(k.op2(.imin, .u32, r(k.op2(.iadd, .u32, r(za), u(1))), r(k.op2(.isub, .u32, r(k.param(.u32, 9)), u(1))))), r(za));
        const sb = k.param(.u32, 0);
        const ss = k.param(.u32, 3);
        const slice = k.op2(.imul, .u32, r(ss), r(k.param(.u32, 2)));
        var t: [8]kir.V = undefined;
        for ([_]kir.V{ za, zb }, 0..) |layer, i| {
            const base = k.op3(.imad, .u32, r(layer), r(slice), r(sb));
            t[i * 4 + 0] = pixelLoad(&k, img, bpp, at(&k, base, ss, xa, ya, bpp));
            t[i * 4 + 1] = pixelLoad(&k, img, bpp, at(&k, base, ss, xb, ya, bpp));
            t[i * 4 + 2] = pixelLoad(&k, img, bpp, at(&k, base, ss, xa, yb, bpp));
            t[i * 4 + 3] = pixelLoad(&k, img, bpp, at(&k, base, ss, xb, yb, bpp));
        }
        var v = k.mov(.u32, u(0));
        for (0..4) |ch| {
            const sh8: u32 = @intCast(8 * ch);
            var sum = k.mov(.u32, u(4));
            for (t) |tx| sum = k.op2(.iadd, .u32, r(sum), r(k.op3(.bfe, .u32, r(tx), u(sh8), u(8))));
            v = k.op2(.@"or", .u32, r(v), r(k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(sum), u(3))), u(sh8))));
        }
        const ds = k.param(.u32, 7);
        const dst_slice = k.op2(.imul, .u32, r(ds), r(k.param(.u32, 6)));
        const db = k.op3(.imad, .u32, r(z), r(dst_slice), r(k.param(.u32, 4)));
        pixelStore(&k, img, bpp, at(&k, db, ds, x, y, bpp), v);
    }
    k.endif();
    return k;
}

/// What a blit maps: the destination rectangle (GL's coordinates, inside
/// the destination; x0 > x1 for a flip is in the scale), and each axis's
/// map from destination to source.
pub const Blit = struct {
    /// the destination pixels written (clipped, x0 <= x1)
    rect: Rect,
    /// x: the destination rectangle's first edge, the source's, and the
    /// source's extent over the destination's (negative: flipped)
    dx0: i32,
    sx0: f32,
    scale_x: f32,
    dy0: i32,
    sy0: f32,
    scale_y: f32,
    linear: bool = false,
    /// the destination's bits written (all; depth's 0x00ffffff, stencil's
    /// 0xff000000)
    wmask: u32 = 0xffff_ffff,
};

/// The bits a read or copy of img sets: an opaque alpha without one.
fn setOf(img: *const Image) u32 {
    return if (img.no_alpha and img.format.isColor()) 0xff00_0000 else 0;
}

fn divUp(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn swapRB(v: u32) u32 {
    return (v & 0xff00_ff00) | ((v >> 16) & 0xff) | ((v & 0xff) << 16);
}

/// The bits `copy` keeps of each pixel from `from` to `to`: all but R and
/// B between BGRA8 and the others (RGBA8's order: R8 and RG8 too).
fn keepOf(from: Format, to: Format) u32 {
    return if (from.renderable() and to.renderable() and (from == .bgra8) != (to == .bgra8)) 0xff00_ff00 else 0xffff_ffff;
}

/// A pixel's bytes as a word (little-endian, zero extended), and back.
fn getPixel(b: []const u8, bpp: u32) u32 {
    var v: u32 = 0;
    for (0..bpp) |n| v |= @as(u32, b[n]) << @intCast(8 * n);
    return v;
}

fn putPixel(b: []u8, bpp: u32, v: u32) void {
    for (0..bpp) |n| b[n] = @truncate(v >> @intCast(8 * n));
}

// ── The engine ─────────────────────────────────────────────────────────────

pub const MAX_OPS = 256;
pub const MAX_DOOMED = 128;
const RING = 64;

/// A batch's programs as said when the GPU is lost: each one's dispatches
/// and its largest grid (groups), up to SUM_PROGS of them (`more`: the
/// others).
const SUM_PROGS = 24;
const ProgSum = struct { prog: *const gpu.Program, count: u16, groups: u32 };
const BatchSum = struct {
    n: u8 = 0,
    more: u16 = 0,
    progs: [SUM_PROGS]ProgSum = undefined,

    fn add(s: *BatchSum, prog: *const gpu.Program, groups: [3]u32, count: u16) void {
        const g: u32 = @intCast(@min(@as(u64, groups[0]) * groups[1] * groups[2], std.math.maxInt(u32)));
        for (s.progs[0..s.n]) |*p| {
            if (p.prog == prog) {
                p.count +|= count;
                p.groups = @max(p.groups, g);
                return;
            }
        }
        if (s.n == SUM_PROGS) {
            s.more +|= 1;
            return;
        }
        s.progs[s.n] = .{ .prog = prog, .count = count, .groups = g };
        s.n += 1;
    }
};
/// How long a CPU access waits for the GPU before calling it lost.
pub const TIMEOUT_US: u64 = 2_000_000;
/// How long a batch may run before the GPU is called lost (a wait past
/// TIMEOUT_US goes on to this; a GPU that hangs is lost sooner, by its
/// kernel's word).
pub const LOST_US: u64 = 20_000_000;

fn monoUs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// A backend (gpu.compile, or gpu.compileFor with the targets an image
/// links).
pub const Compiler = *const fn (k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary;

/// gpu.compile: every backend linked (tests, tools).
pub fn compileAny(k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary {
    return gpu.compile(k, caps, work, out);
}

/// What `init` needs.
/// The channels of format `f` a draw writes, from the bits it keeps
/// (Draw.keep, the pixel word's): bit 0 red .. bit 3 alpha.
fn maskOf(f: Format, keep: u32) u4 {
    // (each channel's byte in the pixel word; none: not there)
    const at: [4]?u5 = switch (f) {
        .bgra8 => .{ 16, 8, 0, 24 },
        .rg8 => .{ 0, 8, null, null },
        .r8 => .{ 0, null, null, null },
        else => .{ 0, 8, 16, 24 },
    };
    var m: u4 = 0;
    for (at, 0..) |sh, c| {
        const s = sh orelse continue;
        if ((keep >> s) & 0xff == 0) m |= @as(u4, 1) << @intCast(c);
    }
    return m;
}

/// A face's stencil state as the GPU is told it.
fn stencilOf(s: raster.Stencil) gpu.Graphics.Stencil {
    const op = struct {
        fn of(x: raster.StencilOp) gpu.Graphics.StencilOp {
            return switch (x) {
                .keep => .keep,
                .zero => .zero,
                .replace => .replace,
                .incr => .incr,
                .decr => .decr,
                .invert => .invert,
                .incr_wrap => .incr_wrap,
                .decr_wrap => .decr_wrap,
            };
        }
    };
    return .{ .func = s.func, .reference = s.reference, .value_mask = s.value_mask, .write_mask = s.write_mask, .fail = op.of(s.fail), .zfail = op.of(s.depth_fail), .zpass = op.of(s.pass) };
}

/// GL's blend as the GPU's blender is told it.
fn blendOf(b: raster.Blend) gpu.GraphicsBlend {
    const eq = struct {
        fn of(x: raster.Equation) gpu.BlendEquation {
            return switch (x) {
                .add => .add,
                .subtract => .subtract,
                .reverse_subtract => .reverse_subtract,
                .min => .min,
                .max => .max,
            };
        }
        fn factor(v: u32) gpu.BlendFactor {
            inline for (std.enums.values(gpu.BlendFactor)) |x| {
                if (@intFromEnum(x) == v) return x;
            }
            return .one;
        }
    };
    return .{
        .src_rgb = eq.factor(b.gl[0]),
        .dst_rgb = eq.factor(b.gl[1]),
        .src_a = eq.factor(b.gl[2]),
        .dst_a = eq.factor(b.gl[3]),
        .eq_rgb = eq.of(b.eq_rgb),
        .eq_a = eq.of(b.eq_a),
        .constant = b.constant,
    };
}

pub const Config = struct {
    /// The GPU; none: everything on the CPU.
    dev: ?gpu.Device = null,
    compiler: Compiler = compileAny,
    /// Scratch for compiling kernels: the engine's at init, pipelines'
    /// when they load (the backend's WORK_BYTES: kir_ir3's, kir_sm120's;
    /// little for the interpreter). Kept.
    work: []u8 = &.{},
    /// CPU memory for images when the GPU gives none (it is lost, or there
    /// is none).
    pool: []u8 = &.{},
    /// Backing storage for suballocating small GPU objects.
    slabs: []Slab = &.{},
    /// Scratch for KIR's interpreter, which draws on the CPU (no GPU, or
    /// it is lost); none: such draws are refused.
    cpu_work: []u8 = &.{},
    /// The GPU's work checked against the CPU's (off: no memory).
    check: Check = .{},
    /// Draws through the GPU's graphics pipeline (Caps.graphics: the RTX's
    /// 3D engine) where a draw is one it takes; else every draw is the
    /// compute kernels'.
    graphics: bool = false,
};

const SLAB_BYTES = 2 << 20;
const MAX_SLAB_OBJECT = 256 << 10;

pub const Slab = struct {
    buf: gpu.Buffer = .{},
    pool: Pool = .{},
};

/// GALAXY_GL_CHECK: the GPU's work checked against the CPU's, which is
/// KIR's interpreter running the same kernels. A kernel's first runs that
/// are small enough are checked: the regions the op writes are saved, the
/// op runs on the GPU and its result is set aside, the regions are put
/// back, the op runs on the CPU, and the two are compared byte by byte.
/// More than a few bytes apart past the tolerance: the GPU is called lost
/// (GL reports a reset), the CPU's result stands, and the CPU draws from
/// then on. Off without `mem`, or without the engine's cpu_work.
pub const Check = struct {
    /// the saved regions, the GPU's results, and a draw's records
    mem: []u8 = &.{},
    /// the largest op checked: the pixels it writes
    max_px: u32 = 128 * 128,
    /// how many runs of each kernel are checked
    times: u8 = 2,
    /// how far apart a byte may be (rounding: the GPU's reciprocals and
    /// roots are not the CPU's to the last bit)
    tolerance: u8 = 2,
};

pub const Stats = struct {
    /// Device.run calls, dispatches recorded, ops done on the CPU, CPU
    /// waits for the GPU.
    batches: u64 = 0,
    dispatches: u64 = 0,
    cpu_ops: u64 = 0,
    waits: u64 = 0,
    /// thread-instructions KIR's interpreter ran for draws on the CPU
    cpu_lane_ops: u64 = 0,
    /// ops checked against the CPU, and those that differed
    checks: u32 = 0,
    check_diffs: u32 = 0,
    /// microseconds inside Device.run (handing batches to the GPU) and
    /// inside Device.wait (the CPU waiting for them), by report.nowUs
    run_us: u64 = 0,
    wait_us: u64 = 0,
    /// draws done on the CPU (cpu_ops counts them too)
    cpu_draws: u64 = 0,
    /// draws through the GPU's graphics pipeline (the 3D engine), and
    /// draws the graphics pipeline was on for that the compute kernels
    /// drew (raster.stageWhyNot)
    graphics_draws: u64 = 0,
    compute_draws: u64 = 0,
};

pub const Engine = struct {
    dev: ?gpu.Device = null,
    /// A run or wait failed: the GPU is not asked again (GL reports a reset).
    lost: bool = false,
    /// Why the engine is on the CPU, when it is.
    why: ?anyerror = null,
    /// Why the last pipeline did not load, or the last CPU draw failed (and
    /// where the interpreter stopped).
    why_pipe: ?anyerror = null,
    trap: gpu.interp.Trap = .{},
    pool: Pool = .{},
    slabs: []Slab = &.{},
    progs: [N_PROGS]gpu.Program = undefined,
    code: [N_PROGS][CODE_BYTES]u8 align(16) = undefined,
    ops: [MAX_OPS]gpu.Dispatch = undefined,
    op_bufs: [MAX_OPS][MAX_BIND]gpu.Buffer = undefined,
    op_params: [MAX_OPS][MAX_PARAMS]u32 = undefined,
    /// the CPU form of each op (for a batch the GPU could not run); a
    /// draw's has none: lost with the GPU (GL reports the reset)
    op_cpu: [MAX_OPS]?CpuOp = undefined,
    /// each op's draw through the graphics pipeline (Dispatch.graphics)
    op_gfx: [MAX_OPS]gpu.Graphics = undefined,
    /// graphics dispatches in the open batch (Caps.max_graphics a run)
    n_gfx: u32 = 0,
    /// Draws go through the GPU's graphics pipeline where they may
    /// (Config.graphics and Caps.graphics), and what was said of it.
    graphics: bool = false,
    said_graphics: bool = false,
    said_compute: [8][]const u8 = @splat(""),
    compiler: Compiler = compileAny,
    work: []u8 = &.{},
    cpu_work: []u8 = &.{},
    /// a pipeline's kernel as it is built, and its code as compiled
    kir_insts: [MAX_KIR]kir.Inst = undefined,
    kir_tys: [MAX_KIR]kir.Ty = undefined,
    pcode: [PIPE_CODE]u8 align(16) = undefined,
    /// zeros, bound where a draw has no buffer (no element array, a
    /// constant attribute, no depth); made at the first draw
    zero: Image = .{},
    n_ops: usize = 0,
    /// The open batch: ops recorded and not run yet belong to it.
    batch: u64 = 1,
    /// The last batch run, and the last one known done.
    ran: u64 = 0,
    done_upto: u64 = 0,
    fences: [RING]gpu.Fence = [_]gpu.Fence{0} ** RING,
    /// Each batch in flight's programs (by batch % RING): what is said
    /// when the GPU is lost.
    sums: [RING]BatchSum = undefined,
    doomed: [MAX_DOOMED]Doomed = undefined,
    n_doomed: usize = 0,
    stats: Stats = .{},
    /// Triangles a bin's list holds at most (raster.BIN_CAP; tests lower
    /// it to make lists run over).
    bin_cap: u32 = raster.BIN_CAP,
    /// Off: no draw is binned (every tile goes through every triangle).
    binning: bool = true,
    check: Check = .{},
    /// runs of each engine kernel checked against the CPU
    prog_checked: [N_PROGS]u8 = [_]u8{0} ** N_PROGS,

    const Doomed = struct { buf: gpu.Buffer, batch: u64 };
    /// (the images as they were when the op was recorded: a batch done
    /// again on the CPU writes where the GPU would have, whatever a table
    /// holds since)
    const CpuOp = union(enum) {
        fill: struct { img: Image, rect: Rect, value: u32, keep: u32 },
        copy: struct { src: Image, sx: u32, sy: u32, dst: Image, dx: u32, dy: u32, w: u32, h: u32 },
    };

    /// The engine in place (it must stay at `e`): the kernels compiled and
    /// loaded for cfg.dev; if any fails, everything runs on the CPU.
    pub fn init(e: *Engine, cfg: Config) void {
        e.* = .{ .pool = Pool.init(cfg.pool), .slabs = cfg.slabs, .compiler = cfg.compiler, .work = cfg.work, .cpu_work = cfg.cpu_work, .check = cfg.check };
        if (cfg.dev) |d| e.graphics = cfg.graphics and d.caps.graphics and d.caps.target == .sm_120;
        for (e.slabs) |*slab| slab.* = .{};
        const d = cfg.dev orelse return;
        e.loadAll(d, cfg.compiler, cfg.work) catch |err| {
            e.why = err;
            return;
        };
        e.dev = d;
    }

    fn loadAll(e: *Engine, d: gpu.Device, compiler: Compiler, work_mem: []u8) !void {
        var loaded: usize = 0;
        errdefer for (e.progs[0..loaded]) |*p| d.unload(p);
        for (0..N_PROGS) |i| {
            var insts: [512]kir.Inst = undefined;
            var tys: [512]kir.Ty = undefined;
            const s = kir.Storage{ .insts = &insts, .tys = &tys };
            var k = switch (@as(Prog, @fromBackingInt(@intCast(i)))) {
                .fill => fillKernel(s, false),
                .fill_masked => fillKernel(s, true),
                .copy => copyKernel(s),
                .bin => raster.binKernel(s),
                .blit => blitKernel(s),
                .mip => mipKernel(s),
            };
            try k.finish();
            var w = gpu.Work.init(work_mem);
            const bin = try compiler(&k, d.caps, &w, &e.code[i]);
            e.progs[i] = try d.load(&bin);
            e.progs[i].label = k.name;
            loaded += 1;
        }
    }

    /// The kernels go and the device is let go (images are the caller's to
    /// free first).
    pub fn deinit(e: *Engine) void {
        e.finish();
        e.freeImage(&e.zero);
        e.reap(true);
        if (e.dev) |d| {
            if (!e.lost) for (&e.progs) |*p| d.unload(p);
            for (e.slabs) |*slab| {
                if (slab.buf.cpu.len != 0) d.free(slab.buf);
                slab.* = .{};
            }
        }
        e.dev = null;
    }

    /// The GPU does the work (not lost, and there is one).
    pub fn onGpu(e: *const Engine) bool {
        return e.dev != null and !e.lost;
    }

    /// The counters a context's usage line reports (report.Usage).
    pub fn usage(e: *const Engine) report.Gpu {
        return .{
            .batches = e.stats.batches,
            .kernels = e.stats.dispatches,
            .submit_us = e.stats.run_us,
            .waits = e.stats.waits,
            .wait_us = e.stats.wait_us,
            .cpu_draws = e.stats.cpu_draws,
        };
    }

    // ── Memory ─────────────────────────────────────────────────────────────

    /// Memory for an image or a GL buffer: the GPU's, else the pool's.
    /// Fresh memory reads as zeros.
    fn allocBytes(e: *Engine, bytes: usize, shareable: bool) ?struct { buf: gpu.Buffer, pooled: bool } {
        e.reap(false);
        for (0..2) |attempt| {
            if (!e.onGpu()) break;
            if (shareable and bytes <= MAX_SLAB_OBJECT) {
                if (e.allocSmall(bytes)) |b| return .{ .buf = b, .pooled = false };
            }
            if (e.dev.?.alloc(bytes, .host)) |b| {
                if (b.cpu.len >= bytes) return .{ .buf = b, .pooled = false };
                e.dev.?.free(b);
            } else |_| {}
            if (attempt != 0 or e.n_doomed == 0) break;
            e.finish();
        }
        const s = e.pool.alloc(bytes) orelse return null;
        @memset(s, 0);
        return .{ .buf = .{ .cpu = s, .bytes = bytes, .kind = .host }, .pooled = true };
    }

    fn allocSmall(e: *Engine, bytes: usize) ?gpu.Buffer {
        const d = e.dev.?;
        for (e.slabs) |*slab| {
            if (slab.buf.cpu.len == 0) {
                const b = d.alloc(SLAB_BYTES, .host) catch return null;
                if (b.cpu.len < SLAB_BYTES) {
                    d.free(b);
                    return null;
                }
                slab.buf = b;
                slab.pool = Pool.init(b.cpu[0..SLAB_BYTES]);
            }
            const cpu = slab.pool.alloc(bytes) orelse continue;
            const off = @intFromPtr(cpu.ptr) - @intFromPtr(slab.buf.cpu.ptr);
            @memset(cpu, 0);
            d.toDevice(slab.buf, off, bytes);
            return .{ .cpu = cpu, .gpu = slab.buf.gpu + off, .bytes = bytes, .handle = slab.buf.handle };
        }
        return null;
    }

    fn slabOf(e: *Engine, b: gpu.Buffer) ?*Slab {
        for (e.slabs) |*slab| {
            if (slab.buf.handle == b.handle and slab.pool.owns(b.cpu)) return slab;
        }
        return null;
    }

    fn freeGpu(e: *Engine, d: gpu.Device, b: gpu.Buffer) void {
        if (e.slabOf(b)) |slab| slab.pool.free(b.cpu) else d.free(b);
    }

    fn freeBytes(e: *Engine, b: gpu.Buffer, pooled: bool, last: u64) void {
        if (pooled) return e.pool.free(b.cpu);
        if (b.kind == .external) return;
        const d = e.dev orelse return;
        if (e.lost or last <= e.done_upto or last == 0) return e.freeGpu(d, b);
        if (e.n_doomed == MAX_DOOMED) {
            // The open batch can still reference these buffers. Waiting
            // only for e.ran leaves that batch queued with stale addresses.
            e.finish();
            return e.freeGpu(d, b);
        }
        e.doomed[e.n_doomed] = .{ .buf = b, .batch = last };
        e.n_doomed += 1;
    }

    /// Buffers whose batches are done are freed (all of them with `all`).
    fn reap(e: *Engine, all: bool) void {
        if (e.n_doomed == 0) return;
        if (!all) e.poll();
        var i: usize = 0;
        while (i < e.n_doomed) {
            const x = e.doomed[i];
            if (all or e.lost or x.batch <= e.done_upto) {
                if (e.dev) |d| e.freeGpu(d, x.buf);
                e.n_doomed -= 1;
                e.doomed[i] = e.doomed[e.n_doomed];
            } else i += 1;
        }
    }

    /// An image of width x height in `format` (rows of width texels,
    /// rounded up to 4 bytes), or null when there is no memory for it.
    pub fn newImage(e: *Engine, width: u32, height: u32, format: Format) ?Image {
        return e.allocImage(width, height, format, true);
    }

    /// A multisampled image (samples 2, 4 or 8; 1: newImage's): a pixel's
    /// samples side by side in its row.
    pub fn newImageSamples(e: *Engine, width: u32, height: u32, format: Format, samples: u8) ?Image {
        if (samples <= 1 and format == .d24s8 and e.graphics) return e.newDepthImage(width, height);
        if (samples <= 1) return e.newImage(width, height, format);
        var img = e.allocImage(width * samples, height, format, true) orelse return null;
        img.width = width;
        img.samples = samples;
        return img;
    }

    /// A depth-stencil renderbuffer where the GPU's 3D engine may draw: block
    /// linear (its depth targets have no pitch-linear form), 32-bit texels
    /// in Turing2D's swizzle, blocks of up to 16 GOBs; `stride` its pitch
    /// in bytes (whole GOBs). Both the 3D engine and the compute raster
    /// (raster.dsOffset) read and write it in place; fills of it go block
    /// linear too.
    pub fn newDepthImage(e: *Engine, width: u32, height: u32) ?Image {
        if (width == 0 or height == 0) return null;
        const pitch = std.mem.alignForward(u32, width * 4, 64);
        var gobs: u3 = 0;
        while (gobs < 4 and (@as(u32, 8) << gobs) < height) gobs += 1;
        const bytes = blocklinear.planeBytes(pitch, height, gobs);
        const m = e.allocBytes(@intCast(bytes), true) orelse return null;
        return .{ .buf = m.buf, .width = width, .height = height, .stride = pitch, .format = .d24s8, .own = true, .pooled = m.pooled, .layout = .{ .block = true, .swizzle = .turing2d, .gobs_log2 = gobs } };
    }

    /// Exported images need a whole backing buffer for the dma-buf.
    pub fn newWindowImage(e: *Engine, width: u32, height: u32, format: Format) ?Image {
        return e.allocImage(width, height, format, false);
    }

    fn allocImage(e: *Engine, width: u32, height: u32, format: Format, shareable: bool) ?Image {
        if (width == 0 or height == 0) return null;
        // (rows 128 bytes apart where the 3D engine may draw into it)
        const stride = std.mem.alignForward(u32, width * format.bytes(), if (e.graphics and format.renderable()) 128 else 4);
        const m = e.allocBytes(@as(usize, stride) * height, shareable) orelse return null;
        return .{ .buf = m.buf, .width = width, .height = height, .stride = stride, .format = format, .own = true, .pooled = m.pooled };
    }

    /// The image's memory goes back (after the GPU is done with it), if it
    /// is the engine's; the image is empty after.
    pub fn freeImage(e: *Engine, img: *Image) void {
        if (img.share) |sh| {
            sh.refs -= 1;
            if (sh.refs == 0) {
                if (sh.external != null) e.settle(img);
                e.freeBytes(sh.buf, sh.pooled, sh.track.last);
                if (sh.external) |external| {
                    sh.external = null;
                    external.release(external.context);
                }
            }
        } else if (img.own and img.buf.cpu.len != 0) e.freeBytes(img.buf, img.pooled, img.track.last);
        img.* = .{};
    }

    /// The image's memory as a GPU buffer of its own, from its byte 0,
    /// `sh` holding it and the image its first name: an EGLImage made of
    /// a GL texture (EGL_KHR_gl_texture_2D_image), whose dma-buf is the
    /// whole buffer. Memory in a slab (others' images beside it) or in the
    /// CPU pool moves first, its bytes copied. False: no GPU buffer for it.
    pub fn shareOwn(e: *Engine, img: *Image, sh: *Shared) bool {
        std.debug.assert(img.share == null and img.own);
        if (img.pooled or e.slabOf(img.buf) != null) {
            const n = img.buf.cpu.len;
            const m = e.allocBytes(n, false) orelse return false;
            if (m.pooled) {
                e.pool.free(m.buf.cpu);
                return false;
            }
            var moved = img.*;
            moved.buf = m.buf;
            moved.pooled = false;
            moved.track = .{};
            @memcpy(moved.buf.cpu[0..n], e.hostView(img, 0, n));
            e.toDevice(&moved, 0, n);
            e.freeBytes(img.buf, img.pooled, img.track.last);
            img.* = moved;
        }
        sh.* = .{ .refs = 1, .buf = img.buf, .track = img.track };
        img.share = sh;
        return true;
    }

    /// An image of `levels` mipmap levels (one buffer, level after level),
    /// or null when there is no memory for it.
    pub fn newImageChain(e: *Engine, width: u32, height: u32, format: Format, levels: u32) ?Image {
        if (width == 0 or height == 0 or levels == 0 or levels > MAX_LEVELS) return null;
        var img = Image{ .width = width, .height = height, .format = format, .levels = @intCast(levels) };
        // (level 0 rows 128 bytes apart where the 3D engine may draw into it)
        img.stride = std.mem.alignForward(u32, width * format.bytes(), if (e.graphics and format.renderable()) 128 else 4);
        var at: usize = 0;
        for (0..levels) |l| {
            img.level_at[l] = @intCast(at);
            at += @as(usize, img.levelStride(@intCast(l))) * img.levelHeight(@intCast(l));
        }
        const m = e.allocBytes(at, true) orelse return null;
        img.buf = m.buf;
        img.own = true;
        img.pooled = m.pooled;
        return img;
    }

    /// Levels base + 1 .. last of img made from the one before each (2 x 2
    /// texels averaged, rounded; an odd edge's last texel taken twice):
    /// glGenerateMipmap, for 1-, 2- and 4-byte unorm images. On the GPU, or
    /// the same kernel on the CPU.
    pub fn mipmap(e: *Engine, img: *Image, base: u32, last: u32) bool {
        return e.mipmapLayers(img, base, last, 1, false);
    }

    pub fn mipmapLayers(e: *Engine, img: *Image, base: u32, last: u32, base_layers: u32, volume: bool) bool {
        var layers = base_layers;
        var l = base;
        while (l < last) : (l += 1) {
            const dst_layers = if (volume) @max(layers / 2, 1) else layers;
            const p = [_]u32{
                img.level_at[l],     img.levelWidth(l),     img.levelHeight(l),     img.levelStride(l),
                img.level_at[l + 1], img.levelWidth(l + 1), img.levelHeight(l + 1), img.levelStride(l + 1),
                img.format.bytes(),  layers,                @intFromBool(volume),
            };
            layers = dst_layers;
            const groups = [3]u32{ divUp(img.levelWidth(l + 1), GROUP), img.levelHeight(l + 1), dst_layers };
            const regs = [_]Region{.{ .img = img, .off = img.level_at[l + 1], .len = @as(usize, img.levelStride(l + 1)) * img.levelHeight(l + 1) * dst_layers, .stride = img.levelStride(l + 1) }};
            var checking = false;
            if (e.gpuUsable(img)) checking = e.checkFirst(.mip, @as(u64, img.levelWidth(l + 1)) * img.levelHeight(l + 1), &regs);
            if (e.gpuUsable(img)) {
                const bufs = [_]*Image{img};
                e.recordProg(&e.progs[@backingInt(Prog.mip)], groups, &bufs, 1, &p, null);
                if (!checking) continue;
                checking = e.checkSwap(&regs);
            }
            const done = cpu: {
                if (e.cpu_work.len == 0) break :cpu false;
                e.fetchAll(img);
                e.stats.cpu_ops += 1;
                const views = [_][]u8{img.buf.cpu};
                if (!e.runCpu(.mip, undefined, groups, &views, &p)) break :cpu false;
                e.wrote(img, 0, img.buf.cpu.len);
                break :cpu true;
            };
            if (!checking) {
                if (!done) return false;
                continue;
            }
            if (!done) {
                e.checkGiveBack(&regs);
                continue;
            }
            e.checkCompare(&regs, "a mipmap level", "");
        }
        return true;
    }

    /// Storage for a GL buffer object of `bytes` (zeros).
    pub fn newBuffer(e: *Engine, bytes: usize) ?Image {
        const m = e.allocBytes(bytes, true) orelse return null;
        return .{ .buf = m.buf, .width = 0, .height = 0, .own = true, .pooled = m.pooled };
    }

    // ── Batches ────────────────────────────────────────────────────────────

    /// Run what is recorded (it goes on while the CPU does).
    pub fn flush(e: *Engine) void {
        if (e.n_ops == 0) return;
        const d = e.dev.?;
        const n = e.n_ops;
        e.n_ops = 0;
        e.n_gfx = 0;
        const sum = &e.sums[e.batch % RING];
        sum.* = .{};
        for (e.ops[0..n]) |op| sum.add(op.prog, op.groups, 1);
        const t0 = report.nowUs();
        const f = d.run(e.ops[0..n]) catch |err| {
            e.loseGpu(err);
            // (the batch again, on the CPU: nothing it did is lost)
            for (e.op_cpu[0..n]) |op| {
                if (op) |o| e.cpuDo(o);
            }
            return;
        };
        e.stats.run_us += report.nowUs() -| t0;
        e.fences[e.batch % RING] = f;
        e.ran = e.batch;
        e.batch += 1;
        e.stats.batches += 1;
        e.reap(false);
    }

    /// Run what is recorded and wait until the GPU is done.
    pub fn finish(e: *Engine) void {
        e.flush();
        e.waitBatch(e.ran);
        e.reap(false);
    }

    fn loseGpu(e: *Engine, err: anyerror) void {
        if (!e.lost) {
            report.say(.lost, "the GPU is lost ({s}): {s}, and GL reports a reset", .{ @errorName(err), if (e.cpu_work.len != 0) "drawing goes on on the CPU" else "nothing more is drawn" });
            e.sayInFlight();
        }
        e.lost = true;
        if (e.why == null) e.why = err;
        e.n_ops = 0;
        e.n_gfx = 0;
    }

    /// What was on the GPU when it was lost: the programs of the batches run
    /// and not known done (a fault or hang is in one of them), largest grid
    /// first, each with its dispatches, its code's GPU address and size,
    /// its registers and shared memory. The address is what a GPU fault's
    /// program counter falls in; the size and registers say which shader
    /// it is (gfxapi's WebRender test prints them for every variant).
    /// Legion 1110u: an Xid 13 on ~28 SMs in one of Firefox's launches,
    /// and nothing said which kernel it was.
    fn sayInFlight(e: *Engine) void {
        if (e.ran <= e.done_upto) return;
        const first = @max(e.done_upto + 1, e.ran -| (RING - 1));
        var all: BatchSum = .{};
        var b = first;
        while (b <= e.ran) : (b += 1) {
            const s = &e.sums[b % RING];
            for (s.progs[0..s.n]) |p| all.add(p.prog, .{ p.groups, 1, 1 }, p.count);
            all.more +|= s.more;
        }
        // largest grid first
        var order: [SUM_PROGS]u8 = undefined;
        for (0..all.n) |i| order[i] = @intCast(i);
        var i: usize = 1;
        while (i < all.n) : (i += 1) {
            var j = i;
            while (j > 0 and all.progs[order[j]].groups > all.progs[order[j - 1]].groups) : (j -= 1) {
                std.mem.swap(u8, &order[j], &order[j - 1]);
            }
        }
        var line: [520]u8 = undefined;
        var len: usize = 0;
        for (order[0..all.n], 0..) |k, n| {
            const p = all.progs[k];
            const name = if (p.prog.label.len != 0) p.prog.label else "a kernel";
            const part = std.fmt.bufPrint(line[len..], "{s}{s} x{d} at 0x{x} ({d} B, {d} regs, {d} B shared, up to {d} groups)", .{ if (n == 0) "" else "; ", name, p.count, p.prog.code.gpu, p.prog.bin.code.len, p.prog.bin.regs, p.prog.bin.shared_bytes, p.groups }) catch {
                all.more +|= @intCast(all.n - n);
                break;
            };
            len += part.len;
        }
        report.say(.in_flight, "on the GPU then ({d} batch{s} not known done): {s}{s}", .{ e.ran - first + 1, if (e.ran == first) "" else "es", line[0..len], if (all.more != 0) " (and more)" else "" });
    }

    /// done_upto moved to the last batch run, if its fence is done.
    fn poll(e: *Engine) void {
        if (!e.onGpu() or e.done_upto >= e.ran) return;
        if (e.dev.?.done(e.fences[e.ran % RING])) e.done_upto = e.ran;
    }

    /// The CPU waits until batch `b` is done (the GPU's batches finish in
    /// order: a later fence covers an earlier one).
    fn waitBatch(e: *Engine, b: u64) void {
        _ = e.waitBatchFor(b, TIMEOUT_US, true);
    }

    /// waitBatch with a timeout of the caller's: false when it ran out
    /// (the GPU called lost only with `lose_on_timeout`; a fence's client
    /// wait may simply give up).
    fn waitBatchFor(e: *Engine, b: u64, timeout_us: u64, lose_on_timeout: bool) bool {
        if (b == 0 or !e.onGpu()) return true;
        if (b >= e.batch) e.flush();
        if (!e.onGpu() or b <= e.done_upto) return true;
        const upto = if (e.ran - b >= RING) e.ran else b;
        e.stats.waits += 1;
        const began = report.nowUs();
        defer e.stats.wait_us += report.nowUs() -| began;
        const fence = e.fences[upto % RING];
        e.dev.?.wait(fence, timeout_us) catch |err| {
            if (err == error.Timeout and !lose_on_timeout) return false;
            if (err != error.Timeout or timeout_us >= LOST_US) {
                e.loseGpu(err);
                return true;
            }
            // A GPU still busy is not a lost one: the kernel says when the
            // GPU hangs (its fence not moving), and the wait ends in
            // DeviceLost then. The Surface's 11-09 boot: Firefox's first
            // WebRender frame ran past 2 s while the desktop's frames shared
            // the Adreno, and the app was sent to the CPU, where its new
            // windows could not be shown.
            report.say(.slow, "a batch of the GPU's has run {d} s: waiting for it, up to {d} s", .{ timeout_us / 1_000_000, LOST_US / 1_000_000 });
            const t0 = monoUs();
            e.dev.?.wait(fence, LOST_US - timeout_us) catch |err2| {
                e.loseGpu(err2);
                return true;
            };
            report.say(.slow, "that batch was done {d} ms later", .{(monoUs() - t0) / 1000});
        };
        e.done_upto = upto;
        return true;
    }

    // ── Fences (EGL's sync objects) ────────────────────────────────────────

    /// A point after all the work recorded so far, which is run now: what
    /// a fence waits for.
    pub fn mark(e: *Engine) u64 {
        e.flush();
        return e.ran;
    }

    /// Whether the work before mark `m` is done (without waiting).
    pub fn markDone(e: *Engine, m: u64) bool {
        if (!e.onGpu() or m <= e.done_upto) return true;
        if (m > e.ran) return false;
        // (a mark older than the ring: the newest fence stands for it)
        const upto = if (e.ran - m >= RING) e.ran else m;
        if (!e.dev.?.done(e.fences[upto % RING])) return false;
        e.done_upto = @max(e.done_upto, upto);
        return true;
    }

    /// The CPU waits for mark `m`, up to timeout_us: false when it ran out.
    pub fn waitMark(e: *Engine, m: u64, timeout_us: u64) bool {
        if (e.markDone(m)) return true;
        if (timeout_us == 0) return false;
        return e.waitBatchFor(m, timeout_us, false);
    }

    /// The CPU may touch img: no batch in flight uses it.
    fn settle(e: *Engine, img: *Image) void {
        const l = img.lastBatch();
        if (l > e.done_upto) e.waitBatch(l);
    }

    fn gpuUsable(e: *const Engine, img: *const Image) bool {
        return e.onGpu() and !img.pooled and img.buf.gpu != 0;
    }

    /// Room for one more op in the open batch.
    fn room(e: *Engine) void {
        if (e.n_ops == MAX_OPS) e.flush();
    }

    fn record(e: *Engine, prog: Prog, groups: [3]u32, bufs: []const *Image, params: []const u32, cpu: CpuOp) void {
        e.recordProg(&e.progs[@backingInt(prog)], groups, bufs, @as(u32, 1) << @intCast(bufs.len - 1), params, cpu);
    }

    /// A dispatch of `prog` in the open batch; `writes`: the bindings it
    /// writes (bit i, binding i).
    fn recordProg(e: *Engine, prog: *const gpu.Program, groups: [3]u32, bufs: []const *Image, writes: u32, params: []const u32, cpu: ?CpuOp) void {
        e.room();
        const i = e.n_ops;
        for (bufs, 0..) |img, j| {
            e.op_bufs[i][j] = img.buf;
            img.trk().last = e.batch;
            if (writes & (@as(u32, 1) << @intCast(j)) != 0) img.trk().gpu_wrote = true;
        }
        @memcpy(e.op_params[i][0..params.len], params);
        e.ops[i] = .{ .prog = prog, .groups = groups, .buffers = e.op_bufs[i][0..bufs.len], .params = e.op_params[i][0..params.len] };
        e.op_cpu[i] = cpu;
        e.n_ops += 1;
        e.stats.dispatches += 1;
    }

    // ── Checks (GALAXY_GL_CHECK) ───────────────────────────────────────────

    /// What an op writes: bytes [off, off + len) of img, rows of `stride`.
    const Region = struct { img: *Image, off: usize, len: usize, stride: u32 };

    /// The memory rows of GL rows y0 .. y1 of img (flipped in a top-down
    /// image), whole.
    fn rowsOf(img: *Image, y0: u32, y1: u32) Region {
        // (block linear: rows are not runs of bytes; the whole image)
        if (img.layout.block) return .{ .img = img, .off = 0, .len = img.buf.cpu.len, .stride = img.stride };
        const a = img.rowOf(y0);
        const b = img.rowOf(y1 - 1);
        const lo = @min(a, b);
        const hi = @max(a, b) + 1;
        return .{ .img = img, .off = @as(usize, lo) * img.stride, .len = @as(usize, hi - lo) * img.stride, .stride = img.stride };
    }

    fn regionBytes(regs: []const Region) usize {
        var n: usize = 0;
        for (regs) |rg| n += rg.len;
        return n;
    }

    /// Whether an op writing `px` pixels, by a kernel checked `n` times so
    /// far, is checked.
    fn wantCheck(e: *const Engine, n: u8, px: u64) bool {
        return e.check.mem.len != 0 and e.cpu_work.len != 0 and e.onGpu() and n < e.check.times and px <= e.check.max_px;
    }

    /// Before a checked op: the work before it done, and its regions saved
    /// (check.mem's first part). False: it is not checked (no room, or the
    /// GPU went).
    fn checkSave(e: *Engine, regs: []const Region) bool {
        const half = regionBytes(regs);
        if (2 * half > e.check.mem.len) return false;
        e.finish();
        if (!e.onGpu()) return false;
        var at: usize = 0;
        for (regs) |rg| {
            @memcpy(e.check.mem[at..][0..rg.len], e.hostView(rg.img, rg.off, rg.len));
            at += rg.len;
        }
        return true;
    }

    /// After the op ran on the GPU: its result set aside (after the saved
    /// regions), and the regions put back as they were. False: the GPU
    /// went meanwhile (the regions are put back all the same).
    fn checkSwap(e: *Engine, regs: []const Region) bool {
        e.finish();
        const kept = e.onGpu();
        const half = regionBytes(regs);
        var at: usize = 0;
        for (regs) |rg| {
            const v = e.hostView(rg.img, rg.off, rg.len);
            if (kept) @memcpy(e.check.mem[half + at ..][0..rg.len], v);
            @memcpy(v, e.check.mem[at..][0..rg.len]);
            e.wrote(rg.img, rg.off, rg.len);
            at += rg.len;
        }
        return kept;
    }

    /// The GPU's result back in the regions (the CPU could not do the op:
    /// it stands unchecked).
    fn checkGiveBack(e: *Engine, regs: []const Region) void {
        const half = regionBytes(regs);
        var at: usize = 0;
        for (regs) |rg| {
            @memcpy(e.hostView(rg.img, rg.off, rg.len), e.check.mem[half + at ..][0..rg.len]);
            e.wrote(rg.img, rg.off, rg.len);
            at += rg.len;
        }
    }

    /// After the op ran on the CPU: the GPU's result against the CPU's.
    /// Bytes apart past the tolerance, more than a few: the GPU is lost
    /// (the CPU's result stands). `what` names the op; `more`, what a draw
    /// found of its kernels.
    fn checkCompare(e: *Engine, regs: []const Region, what: []const u8, more: []const u8) void {
        const half = regionBytes(regs);
        var bad: usize = 0;
        var first_reg: usize = 0;
        var first_base: usize = 0;
        var first_at: ?usize = null;
        var base: usize = 0;
        for (regs, 0..) |rg, i| {
            const cpu = rg.img.buf.cpu[rg.off..][0..rg.len];
            const got = e.check.mem[half + base ..][0..rg.len];
            for (cpu, got, 0..) |x, y, k| {
                if (@max(x, y) - @min(x, y) <= e.check.tolerance) continue;
                bad += 1;
                if (first_at == null) {
                    first_reg = i;
                    first_base = base;
                    first_at = k;
                }
            }
            base += rg.len;
        }
        e.stats.checks += 1;
        if (bad <= 16 + half / 1024) {
            report.say(.check, "{s} checked against the CPU: {d} bytes, {s}{s}", .{ what, half, if (bad == 0) "the same" else "the same within rounding", more });
            return;
        }
        const rg = regs[first_reg];
        const bpp = rg.img.format.bytes();
        const k = first_at.?;
        const row = k / rg.stride;
        const px = row * rg.stride + (k % rg.stride) / bpp * bpp;
        const n = @min(bpp, 4);
        report.say(.check, "{s}: the GPU's result differs from the CPU's in {d} of {d} bytes; first at pixel {d} of row {d} (a {d}x{d} image, {d} bytes a pixel): GPU 0x{x:0>8}, CPU 0x{x:0>8}{s}", .{
            what,
            bad,
            half,
            (k % rg.stride) / bpp,
            (rg.off + px) / rg.stride,
            rg.img.width,
            rg.img.height,
            bpp,
            getPixel(e.check.mem[half + first_base + px ..], n),
            getPixel(rg.img.buf.cpu[rg.off + px ..], n),
            more,
        });
        e.stats.check_diffs += 1;
        e.loseGpu(error.GpuDiffersFromCpu);
    }

    /// Words of a draw's records (vertex or triangle) the GPU and the CPU
    /// do not agree on: equal, or both finite floats within 1/1000.
    fn recordsApart(a: []const u8, b: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i + 4 <= a.len) : (i += 4) {
            const x = std.mem.readInt(u32, a[i..][0..4], .little);
            const y = std.mem.readInt(u32, b[i..][0..4], .little);
            if (x == y) continue;
            const fx: f32 = @bitCast(x);
            const fy: f32 = @bitCast(y);
            if (std.math.isFinite(fx) and std.math.isFinite(fy) and @abs(fx - fy) <= 1e-3 * @max(@max(@abs(fx), @abs(fy)), 1e-3)) continue;
            n += 1;
        }
        return n;
    }

    // ── Draws ──────────────────────────────────────────────────────────────

    const Stage = enum(u3) { vertex, setup, raster, bin, blit, mip, stencil, capture };

    fn build(e: *Engine, st: Stage, p: *const raster.Pipeline) kir.Kernel {
        return e.buildFor(st, p, .{}, .triangles);
    }

    /// A kernel of p's for a variant (tiles) or primitives (setup).
    fn buildFor(e: *Engine, st: Stage, p: *const raster.Pipeline, v: raster.Variant, kind: raster.SetupKind) kir.Kernel {
        const s = kir.Storage{ .insts = &e.kir_insts, .tys = &e.kir_tys };
        return switch (st) {
            .vertex => raster.vertexKernel(s, p),
            .setup => raster.setupKernelFor(s, p, kind),
            .raster => raster.rasterKernelFor(s, p, v),
            .stencil => raster.rasterKernelFor(s, p, .{ .stencil = true, .samples = v.samples, .targets = v.targets, .lines = v.lines }),
            .capture => raster.captureKernel(s, p),
            .bin => raster.binKernel(s),
            .blit => blitKernel(s),
            .mip => mipKernel(s),
        };
    }

    /// A pipeline's kernels compiled and loaded on the GPU (nothing to do
    /// on the CPU, which builds them for each draw). False when one does
    /// not compile or load.
    pub fn loadPipeline(e: *Engine, p: *raster.Pipeline) bool {
        if (!e.onGpu() or p.owner == @as(?*anyopaque, e)) return true;
        if (p.refused_by == @as(?*anyopaque, e)) return false;
        const d = e.dev.?;
        for (0..3) |n| {
            var k = e.build(@fromBackingInt(@intCast(n)), p);
            k.finish() catch |err| return e.pipeFailed(p, n, err);
            var w = gpu.Work.init(e.work);
            const bin = e.compiler(&k, d.caps, &w, &e.pcode) catch |err| return e.pipeFailed(p, n, err);
            p.progs[n] = d.load(&bin) catch |err| return e.pipeFailed(p, n, err);
            p.progs[n].?.label = k.name;
        }
        p.owner = e;
        return true;
    }

    fn loadStencil(e: *Engine, p: *raster.Pipeline) bool {
        if (p.progs[3] != null) return true;
        if (p.stencil_refused_by == @as(?*anyopaque, e)) return false;
        var k = e.build(.stencil, p);
        const result: anyerror!gpu.Program = blk: {
            k.finish() catch |err| break :blk err;
            var w = gpu.Work.init(e.work);
            const bin = e.compiler(&k, e.dev.?.caps, &w, &e.pcode) catch |err| break :blk err;
            break :blk e.dev.?.load(&bin);
        };
        p.progs[3] = result catch |err| {
            e.why_pipe = err;
            p.stencil_refused_by = e;
            report.say(.pipeline, "a program's stencil kernel does not compile or load for the GPU ({s}): its stencil draws run on the CPU", .{@errorName(err)});
            return false;
        };
        p.progs[3].?.label = k.name;
        return true;
    }

    /// The program of p's for a setup kind or tile variant past the ones
    /// loadPipeline and loadStencil load (p.more), compiled and loaded at
    /// its first draw; null when the GPU refuses it (its draws run on the
    /// CPU).
    fn loadMore(e: *Engine, p: *raster.Pipeline, st: Stage, v: raster.Variant, kind: raster.SetupKind) ?*gpu.Program {
        if (st == .setup and kind == .triangles) return &p.progs[1].?;
        if (st == .raster and v.key() == (raster.Variant{}).key()) return &p.progs[2].?;
        if (st == .raster and v.key() == (raster.Variant{ .stencil = true }).key()) return if (e.loadStencil(p)) &p.progs[3].? else null;
        const key = if (st == .setup) raster.setupKey(kind) else raster.tileKey(v);
        for (p.more_key[0..p.n_more], 0..) |x, j| {
            if (x == key) return &p.more[j].?;
        }
        for (p.refused_key[0..p.n_refused]) |x| {
            if (x == key) return null;
        }
        var k = e.buildFor(st, p, v, kind);
        const result: anyerror!gpu.Program = blk: {
            k.finish() catch |err| break :blk err;
            var w = gpu.Work.init(e.work);
            const bin = e.compiler(&k, e.dev.?.caps, &w, &e.pcode) catch |err| break :blk err;
            break :blk e.dev.?.load(&bin);
        };
        const prog = result catch |err| {
            e.why_pipe = err;
            if (p.n_refused < raster.Pipeline.MAX_MORE) {
                p.refused_key[p.n_refused] = key;
                p.n_refused += 1;
            }
            report.say(.pipeline, "a program's {s} kernel does not compile or load for the GPU ({s}): its draws of it run on the CPU", .{ k.name, @errorName(err) });
            return null;
        };
        var slot: usize = p.n_more;
        if (slot == raster.Pipeline.MAX_MORE) {
            // (full: the oldest goes, once no batch runs it)
            e.finish();
            slot = p.evict;
            p.evict = @intCast((slot + 1) % raster.Pipeline.MAX_MORE);
            if (!e.lost) e.dev.?.unload(&p.more[slot].?);
        } else p.n_more += 1;
        p.more[slot] = prog;
        p.more[slot].?.label = k.name;
        p.more_key[slot] = key;
        return &p.more[slot].?;
    }

    fn loadCapture(e: *Engine, p: *raster.Pipeline) bool {
        if (p.progs[4] != null) return true;
        if (p.capture_refused_by == @as(?*anyopaque, e)) return false;
        var k = e.build(.capture, p);
        const result: anyerror!gpu.Program = blk: {
            k.finish() catch |err| break :blk err;
            var w = gpu.Work.init(e.work);
            const bin = e.compiler(&k, e.dev.?.caps, &w, &e.pcode) catch |err| break :blk err;
            break :blk e.dev.?.load(&bin);
        };
        p.progs[4] = result catch |err| {
            e.why_pipe = err;
            p.capture_refused_by = e;
            report.say(.pipeline, "a program's transform feedback kernel does not compile or load for the GPU ({s}): its captures run on the CPU", .{@errorName(err)});
            return false;
        };
        p.progs[4].?.label = k.name;
        return true;
    }

    /// Transform feedback: the draw's vertices (count of each instance)
    /// through its pipeline's vertex code, the outputs it captures into
    /// `outs` (buffer i from word bases[i]); on the GPU, or the same kernel
    /// on the CPU. False when it could not run.
    pub fn capture(e: *Engine, d: *const raster.Draw, outs: [raster.MAX_CAPTURE_BUFFERS]?*Image, bases: [raster.MAX_CAPTURE_BUFFERS]u32) bool {
        if (d.count == 0 or d.instances == 0) return true;
        if (e.zero.buf.cpu.len == 0) e.zero = e.newBuffer(256) orelse return false;
        const p = d.pipe;
        var uni = e.newBuffer(@max(d.uniforms.len * 4, 16)) orelse return false;
        defer e.freeImage(&uni);
        e.writeBytes(&uni, 0, std.mem.sliceAsBytes(d.uniforms));
        var cp: [MAX_PARAMS]u32 = undefined;
        const params = raster.captureParams(d, bases, &cp);
        const ntex: usize = p.shaders.textures;
        var bs: [MAX_BIND]*Image = undefined;
        var writes: u32 = 0;
        for (outs, 0..) |o, i| {
            bs[i] = o orelse &e.zero;
            if (o != null) writes |= @as(u32, 1) << @intCast(i);
        }
        const B = raster.MAX_CAPTURE_BUFFERS;
        bs[B] = &uni;
        bs[B + 1] = d.index orelse &e.zero;
        for (d.attrs, 0..) |a, j| bs[B + 2 + j] = if (a.buf != null and a.comps != 0) a.buf.? else &e.zero;
        for (0..ntex) |j| bs[B + 2 + raster.MAX_ATTRS + j] = d.textures[j] orelse &e.zero;
        const nbuf: usize = p.shaders.buffers;
        for (0..nbuf) |j| bs[B + 2 + raster.MAX_ATTRS + ntex + j] = d.buffers[j] orelse &e.zero;
        const bl = bs[0 .. B + 2 + raster.MAX_ATTRS + ntex + nbuf];
        const groups = [3]u32{ divUp(d.count, raster.VERTEX_GROUP), d.instances, 1 };
        var on_gpu = e.onGpu() and e.loadPipeline(@constCast(p)) and p.owner == @as(?*anyopaque, e) and e.loadCapture(@constCast(p));
        for (bl) |img| on_gpu = on_gpu and e.gpuUsable(img);
        if (on_gpu) {
            e.recordProg(&p.progs[4].?, groups, bl, writes, params, null);
            return true;
        }
        if (e.cpu_work.len == 0) return false;
        for (bl) |img| e.fetchAll(img);
        e.stats.cpu_ops += 1;
        var views: [MAX_BIND][]u8 = undefined;
        for (bl, 0..) |img, j| views[j] = img.buf.cpu;
        if (!e.runCpu(.capture, p, groups, views[0..bl.len], params)) return false;
        for (outs) |o| {
            if (o) |img| e.wrote(img, 0, img.buf.cpu.len);
        }
        return true;
    }

    fn pipeFailed(e: *Engine, p: *raster.Pipeline, n: usize, err: anyerror) bool {
        e.why_pipe = err;
        p.refused_by = e;
        const stage = [_][]const u8{ "vertex", "setup", "tile" };
        report.say(.pipeline, "a program's {s} kernel does not compile or load for the GPU ({s}): its draws run on the CPU", .{ stage[n], @errorName(err) });
        for (p.progs[0..n]) |*q| {
            if (q.*) |*prog| e.dev.?.unload(prog);
            q.* = null;
        }
        return false;
    }

    pub fn unloadPipeline(e: *Engine, p: *raster.Pipeline) void {
        if (p.gfx_owner == @as(?*anyopaque, e)) {
            e.finish();
            for (&p.gfx) |*q| {
                if (q.*) |*prog| {
                    if (!e.lost) e.dev.?.unload(prog);
                }
                q.* = null;
            }
            p.gfx_owner = null;
        }
        if (p.gfx_refused_by == @as(?*anyopaque, e)) p.gfx_refused_by = null;
        if (p.owner != @as(?*anyopaque, e)) return;
        e.finish();
        for (&p.progs) |*q| {
            if (q.*) |*prog| {
                if (!e.lost) e.dev.?.unload(prog);
            }
            q.* = null;
        }
        for (p.more[0..p.n_more]) |*q| {
            if (q.*) |*prog| {
                if (!e.lost) e.dev.?.unload(prog);
            }
            q.* = null;
        }
        p.n_more = 0;
        p.n_refused = 0;
        p.evict = 0;
        p.owner = null;
        p.stencil_refused_by = null;
    }

    // ── The GPU's graphics pipeline (the RTX's 3D engine) ─────────────────

    /// p's two programs for the 3D engine (raster.pixelStage, then
    /// raster.vertexStage storing what the pixel program reads), compiled
    /// and loaded at its first draw there. False when either does not
    /// compile or load (p's draws then stay on the compute kernels).
    fn loadGraphics(e: *Engine, p: *raster.Pipeline) bool {
        if (p.gfx[1] != null) return p.gfx_owner == @as(?*anyopaque, e);
        if (p.gfx_refused_by == @as(?*anyopaque, e)) return false;
        const d = e.dev.?;
        const gl = gpu.nvidia_gl;
        const s = kir.Storage{ .insts = &e.kir_insts, .tys = &e.kir_tys };
        const result: anyerror!void = blk: {
            var w = gpu.Work.init(e.work);
            const st = &(w.take(gpu.nvidia_device.kir_sm120.State, 1) orelse break :blk error.OutOfMemory)[0];
            st.asm_work.sched = .{};
            var pk = raster.pixelStage(s, p);
            pk.finish() catch |err| break :blk err;
            const pbin = gl.compileStage(&pk, d.caps, st, .pixel, 0, &e.pcode) catch |err| break :blk err;
            const reads = st.io.loads;
            const pprog = d.load(&pbin) catch |err| break :blk err;
            st.asm_work.sched = .{};
            var vk = raster.vertexStage(s, p, &reads);
            vk.finish() catch |err| {
                d.unload(&pprog);
                break :blk err;
            };
            const vbin = gl.compileStage(&vk, d.caps, st, .vertex, 0, &e.pcode) catch |err| {
                d.unload(&pprog);
                break :blk err;
            };
            const vprog = d.load(&vbin) catch |err| {
                d.unload(&pprog);
                break :blk err;
            };
            p.gfx = .{ vprog, pprog };
            p.gfx_owner = e;
            p.gfx[0].?.label = "gl_vertex_stage";
            p.gfx[1].?.label = "gl_pixel_stage";
        };
        result catch |err| {
            e.why_pipe = err;
            p.gfx_refused_by = e;
            report.say(.pipeline, "a program does not compile or load for the GPU's 3D engine ({s}): its draws stay on the compute kernels", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// The draw on the GPU's 3D engine, or null when it is not one it takes
    /// (the compute kernels draw it). Said once a reason, per engine.
    fn graphicsDraw(e: *Engine, d: *const raster.Draw) ?bool {
        if (!e.graphics or !e.onGpu()) return null;
        if (raster.stageWhyNot(d)) |why| {
            e.stats.compute_draws += 1;
            e.sayCompute(why);
            return null;
        }
        const p = @constCast(d.pipe);
        if (!e.loadGraphics(p)) {
            e.sayCompute("its program did not compile for the 3D engine");
            return null;
        }
        // the bindings: the vertex kernel's, its first the stage's words
        var bs: [MAX_BIND]*Image = undefined;
        bs[0] = &e.zero;
        var uni = e.newBuffer(@max(d.uniforms.len * 4, 16)) orelse return false;
        defer e.freeImage(&uni);
        e.writeBytes(&uni, 0, std.mem.sliceAsBytes(d.uniforms));
        bs[1] = &uni;
        bs[2] = d.index orelse &e.zero;
        for (d.attrs, 0..) |a, j| bs[3 + j] = if (a.buf != null and a.comps != 0) a.buf.? else &e.zero;
        const ntex: usize = p.shaders.textures;
        const nbuf: usize = p.shaders.buffers;
        for (0..ntex) |j| bs[3 + raster.MAX_ATTRS + j] = d.textures[j] orelse &e.zero;
        for (0..nbuf) |j| bs[3 + raster.MAX_ATTRS + ntex + j] = d.buffers[j] orelse &e.zero;
        const nb = 3 + raster.MAX_ATTRS + ntex + nbuf;
        for (bs[0..nb]) |img| {
            if (!e.gpuUsable(img)) return null;
        }
        const t = d.color;
        if (!e.gpuUsable(t)) return null;
        if (t.buf.gpu % 128 != 0 or t.stride % 128 != 0) {
            e.stats.compute_draws += 1;
            e.sayCompute("a target whose address or rows are not on 128 bytes");
            return null;
        }
        var pw: [MAX_PARAMS]u32 = undefined;
        const params = raster.stageParams(d, &pw);
        // GL's window (y up) as the target's rows: flipped for a top-down
        // image; the scissor the draw's rectangle
        const H: f32 = @floatFromInt(t.height);
        const flip = t.top_down;
        const rc = d.rect;
        if (d.depth) |z| {
            if (!e.gpuUsable(z)) return null;
        }
        const g = gpu.Graphics{
            .depth = if (d.depth) |z| .{
                .va = z.buf.gpu,
                .width = z.width,
                .height = z.height,
                .gobs_log2 = z.layout.gobs_log2,
                .tested = d.depth_test or d.stencil != null,
                .write = d.depth_test and d.depth_write,
                // (no depth test: every pixel passes it)
                .func = if (d.depth_test) d.depth_func else 7,
                .stencil = if (d.stencil != null) stencilOf(d.stencil_front) else null,
            } else null,
            .vertex = &p.gfx[0].?,
            .va = t.buf.gpu,
            .width = t.width,
            .height = t.height,
            .stride = t.stride,
            .format = switch (t.format) {
                .rgba8 => .rgba8,
                .bgra8 => .bgra8,
                .rg8 => .rg8,
                else => .r8,
            },
            .mask = maskOf(t.format, d.keep),
            .blend = if (d.blend) |b| blendOf(b) else null,
            .scale = .{ d.half[0], if (flip) -d.half[1] else d.half[1], d.depth_scale },
            .offset = .{ d.center[0], if (flip) H - d.center[1] else d.center[1], d.depth_bias },
            .scissor = if (flip) .{ rc.x0, t.height - rc.y1, rc.x1, t.height - rc.y0 } else .{ rc.x0, rc.y0, rc.x1, rc.y1 },
            .topology = switch (d.topology) {
                .strip => .strip,
                .fan => .fan,
                else => .triangles,
            },
            .count = d.count,
            .instances = d.instances,
        };
        e.recordGraphics(&p.gfx[1].?, g, bs[0..nb], params, t, d.depth);
        e.stats.graphics_draws += 1;
        if (!e.said_graphics) {
            e.said_graphics = true;
            report.say(.pipeline, "draws through the GPU's 3D engine (the RTX's BLACKWELL_B: its rasterizer and blender), the compute kernels for what it does not take yet", .{});
        }
        return true;
    }

    /// Why a draw went to the compute kernels while the 3D engine was on:
    /// said once a reason.
    fn sayCompute(e: *Engine, why: []const u8) void {
        for (&e.said_compute) |*s| {
            if (s.len != 0 and s.ptr == why.ptr) return;
            if (s.len == 0) {
                s.* = why;
                report.say(.pipeline, "a draw on the compute kernels, not the 3D engine: {s}", .{why});
                return;
            }
        }
    }

    /// A draw through the graphics pipeline in the open batch: the pixel
    /// program as its dispatch's, `g` kept beside it; its bindings read,
    /// the target written.
    fn recordGraphics(e: *Engine, pixel: *const gpu.Program, g: gpu.Graphics, bufs: []const *Image, params: []const u32, target: *Image, depth: ?*Image) void {
        if (e.n_gfx >= e.dev.?.caps.max_graphics) e.flush();
        e.room();
        const i = e.n_ops;
        for (bufs, 0..) |img, j| {
            e.op_bufs[i][j] = img.buf;
            img.trk().last = e.batch;
        }
        target.trk().last = e.batch;
        target.trk().gpu_wrote = true;
        if (depth) |z| {
            z.trk().last = e.batch;
            z.trk().gpu_wrote = true;
        }
        @memcpy(e.op_params[i][0..params.len], params);
        e.op_gfx[i] = g;
        e.ops[i] = .{ .prog = pixel, .groups = .{ 1, 1, 1 }, .buffers = e.op_bufs[i][0..bufs.len], .params = e.op_params[i][0..params.len], .graphics = &e.op_gfx[i] };
        e.op_cpu[i] = null;
        e.n_ops += 1;
        e.n_gfx += 1;
        e.stats.dispatches += 1;
    }

    /// A draw: its vertices, primitives and pixels, on the GPU (three
    /// dispatches in the open batch, four binned) or the CPU (KIR's
    /// interpreter, the same kernels). The setup kernel is the one of the
    /// draw's primitives, the tile kernel the one of its variant (stencil,
    /// samples, colour targets, lines), each built at its first draw.
    /// False when there is no memory for it, or no way to run it.
    pub fn draw(e: *Engine, d: *const raster.Draw) bool {
        const nprim = d.prims();
        const nrec = d.records();
        if (nrec == 0 or d.instances == 0 or d.rect.empty()) return true;
        // (made at the first draw: an engine that never draws has none)
        if (e.zero.buf.cpu.len == 0) e.zero = e.newBuffer(256) orelse return false;
        if (e.graphicsDraw(d)) |done| return done;
        const p = d.pipe;
        const v = d.variant();
        const kind = d.setupKind();
        // (and primitive restart's word, zeroed)
        var verts = e.newBuffer(@as(usize, d.instances) * d.count * p.vstride * 4 + 4) orelse return false;
        defer e.freeImage(&verts);
        if (raster.restartFlag(d) != raster.RESTART_NONE) e.writeBytes(&verts, d.restartWord(), &.{ 0, 0, 0, 0 });
        // (the primitive records, then the bins' lists)
        const bins: raster.Bins = if (e.binning) raster.binsOf(d, e.bin_cap) else .{};
        var tris = e.newBuffer((@as(usize, d.instances) * nrec * p.sstride + bins.words()) * 4) orelse return false;
        defer e.freeImage(&tris);
        var uni = e.newBuffer(@max(d.uniforms.len * 4, 16)) orelse return false;
        defer e.freeImage(&uni);
        e.writeBytes(&uni, 0, std.mem.sliceAsBytes(d.uniforms));
        var vp: [MAX_PARAMS]u32 = undefined;
        var sp: [MAX_PARAMS]u32 = undefined;
        var rp: [MAX_PARAMS]u32 = undefined;
        var bp: [MAX_PARAMS]u32 = undefined;
        const vparams = raster.vertexParams(d, &vp);
        const sparams = raster.setupParams(d, &sp);
        const rparams = raster.rasterParams(d, bins, &rp);
        const bparams = raster.binParams(d, bins, &bp);
        const tb = [_]*Image{&tris};
        const groups_b = [3]u32{ bins.x, bins.y, 1 };
        // the bindings: vertex (records, uniforms, element array,
        // attributes, textures), setup (triangles, vertices), raster
        // (color, depth, triangles, uniforms, textures, the query's word,
        // stencil, the other targets)
        const ntex: usize = p.shaders.textures;
        var vbs: [MAX_BIND]*Image = undefined;
        vbs[0] = &verts;
        vbs[1] = &uni;
        vbs[2] = d.index orelse &e.zero;
        for (d.attrs, 0..) |a, j| vbs[3 + j] = if (a.buf != null and a.comps != 0) a.buf.? else &e.zero;
        const depth = d.depth orelse &e.zero;
        const sb = [_]*Image{ &tris, &verts };
        var rbs: [6 + texture.MAX_TEX + raster.MAX_BUFFERS + raster.MAX_TARGETS]*Image = undefined;
        rbs[0] = if (d.color_off) &e.zero else d.color;
        rbs[1] = depth;
        rbs[2] = &tris;
        rbs[3] = &uni;
        for (0..ntex) |j| {
            const img = d.textures[j] orelse &e.zero;
            vbs[3 + raster.MAX_ATTRS + j] = img;
            rbs[4 + j] = img;
        }
        // (Vulkan's uniform and storage buffers, after the textures)
        const nbuf: usize = p.shaders.buffers;
        for (0..nbuf) |j| {
            const img = d.buffers[j] orelse &e.zero;
            vbs[3 + raster.MAX_ATTRS + ntex + j] = img;
            rbs[4 + ntex + j] = img;
        }
        // (an occlusion query's word; none on: the zeros, never written)
        rbs[4 + ntex + nbuf] = d.query orelse &e.zero;
        var nrb: usize = 5 + ntex + nbuf;
        if (d.stencil) |s| {
            rbs[nrb] = s;
            nrb += 1;
        }
        // (bit j: binding j written)
        var rw: u32 = if (d.color_off) 0 else 0b01;
        if (d.depth != null and d.depth_test and d.depth_write) rw |= 0b10;
        if (d.query != null) rw |= @as(u32, 1) << @intCast(4 + ntex + nbuf);
        if (d.stencil != null) {
            rw |= @as(u32, 1) << @intCast(5 + ntex + nbuf);
            if (d.stencil == d.depth) rw |= 0b10;
        }
        for (d.targets[1..]) |tg| {
            const x = tg orelse continue;
            rbs[nrb] = x.img;
            rw |= @as(u32, 1) << @intCast(nrb);
            nrb += 1;
        }
        const vb = vbs[0 .. 3 + raster.MAX_ATTRS + ntex + nbuf];
        const rb = rbs[0..nrb];
        const groups_v = [3]u32{ divUp(d.count, raster.VERTEX_GROUP), d.instances, 1 };
        const groups_s = [3]u32{ divUp(nprim, raster.SETUP_GROUP), d.instances, 1 };
        const groups_r = [3]u32{ divUp(d.rect.width(), raster.TILE), divUp(d.rect.height(), raster.TILE), 1 };
        var all_gpu = e.onGpu() and e.loadPipeline(@constCast(p)) and p.owner == @as(?*anyopaque, e);
        var setup_prog: ?*gpu.Program = null;
        var tile_prog: ?*gpu.Program = null;
        if (all_gpu) {
            setup_prog = e.loadMore(@constCast(p), .setup, v, kind);
            tile_prog = e.loadMore(@constCast(p), .raster, v, kind);
            all_gpu = setup_prog != null and tile_prog != null;
        }
        for (vb) |img| all_gpu = all_gpu and e.gpuUsable(img);
        for (rb) |img| all_gpu = all_gpu and e.gpuUsable(img);
        // a check: the rows the draw covers of each image it writes
        var regs: [3 + raster.MAX_TARGETS]Region = undefined;
        var nreg: usize = 0;
        var checking = all_gpu and e.wantCheck(p.checked, @as(u64, d.rect.width()) * d.rect.height());
        if (checking) {
            @constCast(p).checked += 1;
            for (rb, 0..) |img, j| {
                const written = rw & (@as(u32, 1) << @intCast(j)) != 0 or (j == 1 and d.depth != null);
                if (!written or img == d.query) continue;
                var seen = false;
                for (regs[0..nreg]) |x| seen = seen or x.img == img;
                if (seen or img.height < d.rect.y1 or img.buf.cpu.len == 0) continue;
                regs[nreg] = rowsOf(img, d.rect.y0, d.rect.y1);
                nreg += 1;
            }
            checking = e.checkSave(regs[0..nreg]);
            all_gpu = all_gpu and e.onGpu();
        }
        // (the GPU's vertex and triangle records, kept to name the kernel
        // that differs)
        var recs: usize = 0;
        if (all_gpu) {
            e.recordProg(&p.progs[0].?, groups_v, vb, 1, vparams, null);
            e.recordProg(setup_prog.?, groups_s, &sb, 1, sparams, null);
            if (bins.on) e.recordProg(&e.progs[@backingInt(Prog.bin)], groups_b, &tb, 1, bparams, null);
            e.recordProg(tile_prog.?, groups_r, rb, rw, rparams, null);
            if (!checking) return true;
            // the GPU's result aside, the rows back, the records cleared:
            // the CPU draws it next
            checking = e.checkSwap(regs[0..nreg]);
            const at = 2 * regionBytes(regs[0..nreg]);
            const vl = verts.buf.cpu.len;
            const tl = tris.buf.cpu.len;
            const vv = e.hostView(&verts, 0, vl);
            const tv = e.hostView(&tris, 0, tl);
            if (checking and at + vl + tl <= e.check.mem.len) {
                @memcpy(e.check.mem[at..][0..vl], vv);
                @memcpy(e.check.mem[at + vl ..][0..tl], tv);
                recs = vl + tl;
            }
            @memset(vv, 0);
            @memset(tv, 0);
            e.wrote(&verts, 0, vl);
            e.wrote(&tris, 0, tl);
        }
        // on the CPU: every image settled (and fetched, if the GPU wrote it)
        const done = cpu: {
            if (e.cpu_work.len == 0) break :cpu false;
            for (vb) |img| e.fetchAll(img);
            for (rb) |img| e.fetchAll(img);
            e.stats.cpu_ops += 1;
            e.stats.cpu_draws += 1;
            var views: [MAX_BIND][]u8 = undefined;
            for (vb, 0..) |img, j| views[j] = img.buf.cpu;
            if (!e.runCpu(.vertex, p, groups_v, views[0..vb.len], vparams)) break :cpu false;
            const sv = [_][]u8{ tris.buf.cpu, verts.buf.cpu };
            if (!e.runCpuFor(.setup, p, v, kind, groups_s, &sv, sparams)) break :cpu false;
            const bv = [_][]u8{tris.buf.cpu};
            if (bins.on and !e.runCpu(.bin, p, groups_b, &bv, bparams)) break :cpu false;
            var rv: [rbs.len][]u8 = undefined;
            for (rb, 0..) |img, j| rv[j] = img.buf.cpu;
            if (!e.runCpuFor(.raster, p, v, kind, groups_r, rv[0..rb.len], rparams)) break :cpu false;
            // (the color and depth bindings as before: always marked)
            for (rb, 0..) |img, j| {
                if (j < 2 or rw & (@as(u32, 1) << @intCast(j)) != 0) e.wrote(img, 0, img.buf.cpu.len);
            }
            break :cpu true;
        };
        if (!checking) return done;
        if (!done) {
            e.checkGiveBack(regs[0..nreg]);
            return true;
        }
        var more_buf: [160]u8 = undefined;
        var more: []const u8 = "";
        if (recs != 0) {
            const at = 2 * regionBytes(regs[0..nreg]);
            const vl = verts.buf.cpu.len;
            const tl = tris.buf.cpu.len;
            const va = recordsApart(e.check.mem[at..][0..vl], verts.buf.cpu);
            const ta = recordsApart(e.check.mem[at + vl ..][0..tl], tris.buf.cpu);
            more = (if (va > vl / 64) std.fmt.bufPrint(&more_buf, " (the vertex kernel's records already differ: {d} of {d} words)", .{ va, vl / 4 }) else if (ta > tl / 64) std.fmt.bufPrint(&more_buf, " (the vertex kernel agrees; the triangles' records differ, from the setup{s} kernel: {d} of {d} words)", .{ if (bins.on) " or bin" else "", ta, tl / 4 }) else std.fmt.bufPrint(&more_buf, " (the vertex{s} kernels agree)", .{if (bins.on) ", setup and bin" else " and setup"})) catch "";
        }
        e.checkCompare(regs[0..nreg], "a draw", more);
        return true;
    }

    /// img for the CPU: no batch in flight uses it, the GPU's writes fetched.
    fn fetchAll(e: *Engine, img: *Image) void {
        _ = e.hostView(img, 0, img.buf.cpu.len);
    }

    fn runCpu(e: *Engine, st: Stage, p: *const raster.Pipeline, groups: [3]u32, views: []const []u8, params: []const u32) bool {
        return e.runCpuFor(st, p, .{}, .triangles, groups, views, params);
    }

    fn runCpuFor(e: *Engine, st: Stage, p: *const raster.Pipeline, v: raster.Variant, kind: raster.SetupKind, groups: [3]u32, views: []const []u8, params: []const u32) bool {
        var k = e.buildFor(st, p, v, kind);
        k.finish() catch |err| {
            e.why_pipe = err;
            report.say(.pipeline, "a {s} kernel does not build ({s}): the draw is dropped", .{ @tagName(st), @errorName(err) });
            return false;
        };
        var w = gpu.Work.init(e.cpu_work);
        var trap: gpu.interp.Trap = .{};
        var stats: gpu.interp.Stats = .{};
        gpu.interp.run(.{
            .code = k.code(),
            .regs = k.nv,
            .group = k.group,
            .shared_bytes = k.shared_bytes,
            .groups = groups,
            .bindings = views,
            .params = params,
        }, gpu.interp_caps, &w, &trap, &stats) catch |err| {
            e.why_pipe = err;
            e.trap = trap;
            report.say(.pipeline, "a {s} kernel stopped on the CPU ({s} at {d}): the draw is dropped", .{ @tagName(st), @errorName(err), trap.pc });
            return false;
        };
        e.stats.cpu_lane_ops += stats.lane_ops;
        return true;
    }

    // ── Ops ────────────────────────────────────────────────────────────────

    /// glBlitFramebuffer's pixels from src into dst (see blitKernel): on
    /// the GPU, or the same kernel on the CPU. False when it can run
    /// nowhere (the CPU has no scratch). src and dst must be apart.
    pub fn blit(e: *Engine, src: *Image, dst: *Image, b: Blit) bool {
        const a = b.rect.meet(dst.bounds());
        if (a.empty()) return true;
        // (a block-linear depth image: not blitted yet)
        if (src.layout.block or dst.layout.block) {
            report.say(.pipeline, "a blit of a block-linear depth image (the 3D engine's): not done", .{});
            return false;
        }
        const color = src.format.renderable() and dst.format.renderable();
        const d0: i32 = @intCast(dst.rowOf(a.y0));
        var p: [BLIT_PARAMS]u32 = undefined;
        p[B_DX0] = a.x0;
        p[B_DY0] = a.y0;
        p[B_W] = a.width();
        p[B_DSTRIDE] = dst.stride;
        p[B_DBPP] = dst.format.bytes();
        p[B_DROW] = @bitCast(d0);
        p[B_DSTEP] = @bitCast(@as(i32, if (dst.top_down) -1 else 1));
        p[B_SSTRIDE] = src.stride;
        p[B_SBPP] = src.format.bytes();
        p[B_STOPDOWN] = @intFromBool(src.top_down);
        p[B_SHEIGHT] = src.height;
        p[B_SWIDTH] = src.width;
        p[B_MAPX] = @bitCast(b.dx0);
        p[B_MAPX + 1] = @bitCast(b.sx0);
        p[B_MAPX + 2] = @bitCast(b.scale_x);
        p[B_MAPY] = @bitCast(b.dy0);
        p[B_MAPY + 1] = @bitCast(b.sy0);
        p[B_MAPY + 2] = @bitCast(b.scale_y);
        p[B_LINEAR] = @intFromBool(b.linear and src.samples == 1);
        p[B_SSWAP] = @intFromBool(color and src.format == .bgra8);
        p[B_DSWAP] = @intFromBool(color and dst.format == .bgra8);
        p[B_SET] = if (color and (setOf(src) != 0 or src.format.channels() < 4)) 0xff00_0000 else 0;
        p[B_WMASK] = b.wmask;
        p[B_SPIX] = src.format.bytes() * src.samples;
        p[B_SSAMPLES] = src.samples;
        p[B_SSHIFT] = std.math.log2_int(u32, src.samples);
        p[B_SAVG] = @intFromBool(color);
        const groups = [3]u32{ divUp(a.width(), GROUP), a.height(), 1 };
        const regs = [_]Region{rowsOf(dst, a.y0, a.y1)};
        var checking = false;
        if (e.gpuUsable(src) and e.gpuUsable(dst)) checking = e.checkFirst(.blit, @as(u64, a.width()) * a.height(), &regs);
        if (e.gpuUsable(src) and e.gpuUsable(dst)) {
            const bufs = [_]*Image{ src, dst };
            e.recordProg(&e.progs[@backingInt(Prog.blit)], groups, &bufs, 0b10, &p, null);
            if (!checking) return true;
            checking = e.checkSwap(&regs);
        }
        const done = cpu: {
            if (e.cpu_work.len == 0) break :cpu false;
            e.fetchAll(src);
            e.fetchAll(dst);
            e.stats.cpu_ops += 1;
            const views = [_][]u8{ src.buf.cpu, dst.buf.cpu };
            // (a pipeline the blit kernel ignores)
            if (!e.runCpu(.blit, undefined, groups, &views, &p)) break :cpu false;
            e.wrote(dst, 0, dst.buf.cpu.len);
            break :cpu true;
        };
        if (!checking) return done;
        if (!done) {
            e.checkGiveBack(&regs);
            return true;
        }
        e.checkCompare(&regs, "a blit", "");
        return true;
    }

    /// Pixels of `rect` (GL's coordinates, inside img) become
    /// (pixel & keep) | (value & ~keep).
    /// A multisampled image's pixels in `rect` resolved into the same
    /// pixels of a single-sampled one (Vulkan's resolve attachments and
    /// vkCmdResolveImage, GL's blit of a multisampled framebuffer): colour
    /// samples averaged (each byte, rounded half up), depth and stencil
    /// sample 0's. A blit at 1:1.
    pub fn resolve(e: *Engine, src: *Image, dst: *Image, rect: Rect) bool {
        const x0: i32 = @intCast(rect.x0);
        const y0: i32 = @intCast(rect.y0);
        return e.blit(src, dst, .{ .rect = rect, .dx0 = x0, .sx0 = @floatFromInt(x0), .scale_x = 1, .dy0 = y0, .sy0 = @floatFromInt(y0), .scale_y = 1 });
    }

    pub fn fill(e: *Engine, img: *Image, rect: Rect, value: u32, keep: u32) void {
        const a0 = rect.meet(img.bounds());
        if (a0.empty() or keep == 0xffff_ffff) return;
        // (multisampled: every sample of the pixels, the row's samples side
        // by side)
        const ns = img.samples;
        const a = Rect{ .x0 = a0.x0 * ns, .y0 = a0.y0, .x1 = a0.x1 * ns, .y1 = a0.y1 };
        var flat = img.*;
        flat.width *= ns;
        flat.samples = 1;
        const op = CpuOp{ .fill = .{ .img = flat, .rect = a, .value = value & ~keep, .keep = keep } };
        if (!e.gpuUsable(img)) {
            e.settle(img);
            return e.cpuDo(op);
        }
        // (memory rows: a top-down image's GL rows are flipped)
        const y0 = if (img.top_down) img.height - a.y1 else a.y0;
        const groups = [3]u32{ std.math.divCeil(u32, a.width(), GROUP) catch unreachable, a.height(), 1 };
        const p = [_]u32{ a.x0, y0, a.width(), img.stride, value & ~keep, keep, img.format.bytes(), raster.blWord(img) };
        const prog: Prog = if (keep == 0) .fill else .fill_masked;
        const regs = [_]Region{rowsOf(img, a.y0, a.y1)};
        const checking = e.checkFirst(prog, @as(u64, a.width()) * a.height(), &regs);
        if (!e.gpuUsable(img)) return e.cpuDo(op);
        e.record(prog, groups, &.{img}, &p, op);
        if (!checking) return;
        const kept = e.checkSwap(&regs);
        e.cpuDo(op);
        if (kept) e.checkCompare(&regs, if (keep == 0) "a fill" else "a masked fill", "");
    }

    /// Whether this run of engine kernel `prog` is checked (counted, the
    /// regions saved).
    fn checkFirst(e: *Engine, prog: Prog, px: u64, regs: []const Region) bool {
        const i = @backingInt(prog);
        if (!e.wantCheck(e.prog_checked[i], px)) return false;
        e.prog_checked[i] += 1;
        return e.checkSave(regs);
    }

    /// w x h pixels from (sx, sy) in src to (dx, dy) in dst (GL's
    /// coordinates; both inside their images), converted between rgba8
    /// and bgra8, or to fewer channels (R8 and RG8 from either). src and
    /// dst may be the same image only apart.
    pub fn copy(e: *Engine, src: *Image, sx_px: u32, sy: u32, dst: *Image, dx_px: u32, dy: u32, w_px: u32, h: u32) void {
        if (w_px == 0 or h == 0) return;
        std.debug.assert(sx_px + w_px <= src.width and sy + h <= src.height and dx_px + w_px <= dst.width and dy + h <= dst.height);
        // (multisampled, both alike: each pixel's samples copied)
        std.debug.assert(src.samples == dst.samples);
        const ns = src.samples;
        const sx = sx_px * ns;
        const dx = dx_px * ns;
        const w = w_px * ns;
        var fs = src.*;
        var fd = dst.*;
        fs.width *= ns;
        fd.width *= ns;
        fs.samples = 1;
        fd.samples = 1;
        const op = CpuOp{ .copy = .{ .src = fs, .sx = sx, .sy = sy, .dst = fd, .dx = dx, .dy = dy, .w = w, .h = h } };
        if (!e.gpuUsable(src) or !e.gpuUsable(dst)) {
            e.settle(src);
            e.settle(dst);
            return e.cpuDo(op);
        }
        const keep = keepOf(src.format, dst.format);
        const s0: i32 = @intCast(src.rowOf(sy));
        const d0: i32 = @intCast(dst.rowOf(dy));
        const ss: i32 = if (src.top_down) -1 else 1;
        const ds: i32 = if (dst.top_down) -1 else 1;
        const p = [_]u32{ sx, @bitCast(s0), @bitCast(ss), src.stride, dx, @bitCast(d0), @bitCast(ds), dst.stride, w, keep, ~keep, setOf(src), src.format.bytes(), dst.format.bytes() };
        const regs = [_]Region{rowsOf(dst, dy, dy + h)};
        const checking = e.checkFirst(.copy, @as(u64, w) * h, &regs);
        if (!e.gpuUsable(src) or !e.gpuUsable(dst)) return e.cpuDo(op);
        e.record(.copy, .{ std.math.divCeil(u32, w, GROUP) catch unreachable, h, 1 }, &.{ src, dst }, &p, op);
        if (!checking) return;
        const kept = e.checkSwap(&regs);
        e.cpuDo(op);
        if (kept) e.checkCompare(&regs, "a copy", "");
    }

    /// Rows of pixels from the CPU into img's rectangle (x, y, w, h: GL's
    /// coordinates, inside img). Source row j (GL row y + j) starts at
    /// `src[j * src_stride ..]`, in `src_format` (converted to img's).
    pub fn write(e: *Engine, img: *Image, x: u32, y: u32, w: u32, h: u32, src: []const u8, src_stride: usize, src_format: Format) void {
        if (w == 0 or h == 0) return;
        e.settle(img);
        // (the same format: rows copied; rgba8 and bgra8: red and blue swapped)
        const bpp: usize = img.format.bytes();
        const raw = src_format == img.format;
        const swap = !raw and keepOf(src_format, img.format) != 0xffff_ffff;
        const dw = img.words();
        for (0..h) |j| {
            const row = img.rowOf(y + @as(u32, @intCast(j)));
            const off = @as(usize, row) * img.stride + @as(usize, x) * bpp;
            const len = @as(usize, w) * bpp;
            if (img.gpuWrote()) e.fromDevice(img, off, len);
            const s = src[j * src_stride ..][0..len];
            if (raw) {
                @memcpy(img.buf.cpu[off..][0..len], s);
            } else {
                const base = off / 4;
                for (0..w) |i| {
                    const v = std.mem.readInt(u32, s[i * 4 ..][0..4], .little);
                    dw[base + i] = if (swap) swapRB(v) else v;
                }
            }
            e.toDevice(img, off, len);
        }
        e.stats.cpu_ops += 1;
    }

    /// Rows of img's rectangle (GL's coordinates, inside img) to the CPU:
    /// GL row y + j at `dst[j * dst_stride ..]`, in `want`: RGBA8 or
    /// BGRA8 (converted: what an R8 or RG8 image lacks is 0, alpha 1), or
    /// img's own format.
    pub fn read(e: *Engine, img: *Image, x: u32, y: u32, w: u32, h: u32, dst: []u8, dst_stride: usize, want: Format) void {
        if (w == 0 or h == 0) return;
        e.settle(img);
        const swap = keepOf(img.format, want) != 0xffff_ffff;
        const sb = img.format.bytes();
        const db = want.bytes();
        // (opaque: an image without alpha, or one of fewer channels read
        // as RGBA; read as itself, its bytes alone are kept)
        const set: u32 = if (img.format.renderable() and (setOf(img) != 0 or img.format.channels() < 4)) 0xff00_0000 else 0;
        for (0..h) |j| {
            const row = img.rowOf(y + @as(u32, @intCast(j)));
            const off = @as(usize, row) * img.stride + @as(usize, x) * sb;
            if (img.gpuWrote()) e.fromDevice(img, off, @as(usize, w) * sb);
            const s = img.buf.cpu[off..][0 .. @as(usize, w) * sb];
            const d = dst[j * dst_stride ..][0 .. @as(usize, w) * db];
            if (sb == 4 and db == 4) {
                // (words, as most reads are)
                const sw = img.words()[off / 4 ..][0..w];
                for (sw, 0..) |word, i| {
                    const v = word | set;
                    std.mem.writeInt(u32, d[i * 4 ..][0..4], if (swap) swapRB(v) else v, .little);
                }
                continue;
            }
            for (0..w) |i| {
                const v = getPixel(s[i * sb ..], sb) | set;
                putPixel(d[i * db ..], db, if (swap) swapRB(v) else v);
            }
        }
        e.stats.cpu_ops += 1;
    }

    /// img's bytes [off, off + len) for the CPU, once no batch in flight
    /// uses img (fetched, if the GPU wrote it). After the CPU writes into
    /// it: `wrote`.
    pub fn hostView(e: *Engine, img: *Image, off: usize, len: usize) []u8 {
        e.settle(img);
        if (img.gpuWrote()) e.fromDevice(img, off, len);
        return img.buf.cpu[off..][0..len];
    }

    /// The same at once, whatever batches in flight use img (GL's
    /// MAP_UNSYNCHRONIZED_BIT: the caller keeps off what they use).
    pub fn hostViewNow(e: *Engine, img: *Image, off: usize, len: usize) []u8 {
        if (img.gpuWrote()) e.fromDevice(img, off, len);
        return img.buf.cpu[off..][0..len];
    }

    /// Whether a batch not known done uses img.
    pub fn busy(e: *Engine, img: *const Image) bool {
        e.poll();
        return img.lastBatch() > e.done_upto;
    }

    /// The CPU wrote img's bytes [off, off + len) (in a hostView): handed
    /// to the GPU.
    pub fn wrote(e: *Engine, img: *const Image, off: usize, len: usize) void {
        e.toDevice(img, off, len);
    }

    /// Bytes from the CPU into a GL buffer's storage at `off`.
    pub fn writeBytes(e: *Engine, b: *Image, off: usize, src: []const u8) void {
        if (src.len == 0) return;
        e.settle(b);
        if (b.gpuWrote()) e.fromDevice(b, off, src.len);
        @memcpy(b.buf.cpu[off..][0..src.len], src);
        e.toDevice(b, off, src.len);
    }

    /// A GL buffer's bytes at `off` to the CPU.
    pub fn readBytes(e: *Engine, b: *Image, off: usize, dst: []u8) void {
        if (dst.len == 0) return;
        e.settle(b);
        if (b.gpuWrote()) e.fromDevice(b, off, dst.len);
        @memcpy(dst, b.buf.cpu[off..][0..dst.len]);
    }

    fn toDevice(e: *Engine, img: *const Image, off: usize, len: usize) void {
        if (!e.gpuUsable(img)) return;
        if (e.slabOf(img.buf)) |slab| {
            const base = @intFromPtr(img.buf.cpu.ptr) - @intFromPtr(slab.buf.cpu.ptr);
            e.dev.?.toDevice(slab.buf, base + off, len);
            return;
        }
        if (img.share) |sh| {
            const base = @intFromPtr(img.buf.cpu.ptr) - @intFromPtr(sh.buf.cpu.ptr);
            e.dev.?.toDevice(sh.buf, base + off, len);
        } else e.dev.?.toDevice(img.buf, off, len);
    }

    fn fromDevice(e: *Engine, img: *const Image, off: usize, len: usize) void {
        if (!e.gpuUsable(img)) return;
        if (e.slabOf(img.buf)) |slab| {
            const base = @intFromPtr(img.buf.cpu.ptr) - @intFromPtr(slab.buf.cpu.ptr);
            e.dev.?.fromDevice(slab.buf, base + off, len);
            return;
        }
        if (img.share) |sh| {
            const base = @intFromPtr(img.buf.cpu.ptr) - @intFromPtr(sh.buf.cpu.ptr);
            e.dev.?.fromDevice(sh.buf, base + off, len);
        } else e.dev.?.fromDevice(img.buf, off, len);
    }

    // ── The CPU forms ──────────────────────────────────────────────────────

    fn cpuDo(e: *Engine, op_in: CpuOp) void {
        e.stats.cpu_ops += 1;
        var op = op_in;
        switch (op) {
            .fill => |*f| {
                const img = &f.img;
                const bpp = img.format.bytes();
                if (img.layout.block) {
                    // (a block-linear depth image: pixel by pixel; its words
                    // where the layout puts them)
                    if (img.gpuWrote()) e.fromDevice(img, 0, img.buf.cpu.len);
                    var yy = f.rect.y0;
                    while (yy < f.rect.y1) : (yy += 1) {
                        var xx = f.rect.x0;
                        while (xx < f.rect.x1) : (xx += 1) {
                            const at = blocklinear.addressCpu(img.stride, img.layout.gobs_log2, img.layout.swizzle, xx * 4, img.rowOf(yy));
                            const w = &img.words()[at / 4];
                            w.* = (w.* & f.keep) | f.value;
                        }
                    }
                    e.toDevice(img, 0, img.buf.cpu.len);
                    return;
                }
                var y = f.rect.y0;
                while (y < f.rect.y1) : (y += 1) {
                    const off = @as(usize, img.rowOf(y)) * img.stride + @as(usize, f.rect.x0) * bpp;
                    const len = @as(usize, f.rect.width()) * bpp;
                    // (the GPU's writes first, the CPU's after: a lost GPU
                    // leaves its memory as it was)
                    if (img.gpuWrote()) e.fromDevice(img, off, len);
                    if (bpp == 4) {
                        const row = img.words()[off / 4 ..][0..f.rect.width()];
                        for (row) |*p| p.* = (p.* & f.keep) | f.value;
                    } else {
                        const row = img.buf.cpu[off..][0..len];
                        for (0..f.rect.width()) |i| {
                            const px = row[i * bpp ..];
                            putPixel(px, bpp, (getPixel(px, bpp) & f.keep) | f.value);
                        }
                    }
                    e.toDevice(img, off, len);
                }
            },
            .copy => |*c| {
                const swap = keepOf(c.src.format, c.dst.format) != 0xffff_ffff;
                const set = setOf(&c.src);
                const sb = c.src.format.bytes();
                const db = c.dst.format.bytes();
                for (0..c.h) |j| {
                    const jj: u32 = @intCast(j);
                    const so = @as(usize, c.src.rowOf(c.sy + jj)) * c.src.stride + @as(usize, c.sx) * sb;
                    const do_ = @as(usize, c.dst.rowOf(c.dy + jj)) * c.dst.stride + @as(usize, c.dx) * db;
                    if (c.src.gpuWrote()) e.fromDevice(&c.src, so, @as(usize, c.w) * sb);
                    if (c.dst.gpuWrote()) e.fromDevice(&c.dst, do_, @as(usize, c.w) * db);
                    if (sb == 4 and db == 4) {
                        const sw = c.src.words();
                        const dw = c.dst.words();
                        for (0..c.w) |i| {
                            const v = sw[so / 4 + i] | set;
                            dw[do_ / 4 + i] = if (swap) swapRB(v) else v;
                        }
                    } else for (0..c.w) |i| {
                        const v = getPixel(c.src.buf.cpu[so + i * sb ..], sb) | set;
                        putPixel(c.dst.buf.cpu[do_ + i * db ..], db, if (swap) swapRB(v) else v);
                    }
                    e.toDevice(&c.dst, do_, @as(usize, c.w) * db);
                }
            },
        }
    }
};

// ── Tests (the CPU forms; the GPU's are tests/test_gfxapi.sig's) ──────────

test "engine: the pool hands out, takes back and reuses" {
    var mem: [4096]u8 align(128) = undefined;
    var p = Pool.init(&mem);
    const a = p.alloc(100).?;
    const b = p.alloc(1000).?;
    try std.testing.expect(@intFromPtr(b.ptr) >= @intFromPtr(a.ptr) + 128);
    try std.testing.expect(p.alloc(4096) == null);
    p.free(a);
    const c = p.alloc(64).?;
    try std.testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(c.ptr));
    p.free(b);
    p.free(c);
    try std.testing.expectEqual(@as(usize, 0), p.n);
    try std.testing.expect(p.alloc(4096) != null);
}

test "engine: on the CPU: fill with a mask, copy with a flip and a swap, write and read" {
    var mem: [64 * 1024]u8 align(64) = undefined;
    var e: Engine = undefined;
    e.init(.{ .pool = &mem });
    try std.testing.expect(!e.onGpu());
    var a = e.newImage(8, 4, .rgba8).?;
    var b = e.newImage(8, 4, .bgra8).?;
    b.top_down = true;
    e.fill(&a, a.bounds(), 0x4433_2211, 0);
    e.fill(&a, .{ .x0 = 2, .y0 = 1, .x1 = 4, .y1 = 2 }, 0xaabb_ccdd, 0xff00_0000);
    var px: [4]u8 = undefined;
    e.read(&a, 2, 1, 1, 1, &px, 4, .rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0x44 }, &px);
    // into the top-down bgra8 image: GL row 1 is its memory row 2
    e.copy(&a, 0, 0, &b, 0, 0, 8, 4);
    try std.testing.expectEqual(swapRB(0x44bb_ccdd), b.words()[2 * 8 + 2]);
    e.read(&b, 2, 1, 1, 1, &px, 4, .rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0x44 }, &px);
    // a row written from the CPU in rgba8 lands swapped in bgra8
    e.write(&b, 0, 3, 1, 1, &.{ 1, 2, 3, 4 }, 4, .rgba8);
    try std.testing.expectEqual(@as(u32, 0x0401_0203), b.words()[0]);
    e.freeImage(&a);
    e.freeImage(&b);
    try std.testing.expectEqual(@as(usize, 0), e.pool.n);
}
