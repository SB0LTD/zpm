//! @zpm/va enc_import — vaCreateSurfaces over an app's dma-bufs (camera
//! and screen frames WebRTC hands an encoder): VASurfaceAttribExternal-
//! Buffers with DRM PRIME fds (pitch linear), or a VADRMPRIMESurface-
//! Descriptor (DRM_PRIME_2: linear, or NVIDIA's block linear by its
//! modifier).
//!
//! An import is the kernel's: PRIME_FD_TO_HANDLE names the dma-buf in the
//! render node's file, G_BUFFER_INFO gives its GPU address, mmap offset
//! and length (nv_drm.sig, as the GL driver's client does it); the fd
//! stays the app's. Then:
//!
//! - **block linear** (NVIDIA_BLOCK_LINEAR_2D, uncompressed, the GPU's own
//!   GOB kind): the engine reads the planes where they are, any block
//!   height (the modifier's h is nvenc's input_cfg block_height). The
//!   sector layout must be the GPU's for the planes' texels (GB20x: 2 for
//!   NV12's Y, 3 for its UV; Turing's 1 with GALAXY_VA_GOB=turing).
//! - **pitch linear**: NVENC reads no pitch-linear input (nvenc.sig), so
//!   the picture goes through the driver's converter into the surface's
//!   own block-linear planes before every encode (the app writes the
//!   buffer behind the driver's back: always stale) — the GPU's pass in
//!   the shared library (convert.sig), never encode.end.
//!
//! NV12 only (the encoder's input). Pure but for `importFd`'s calls.

const std = @import("std");
const va = @import("vaapi.sig");
const tiling = @import("tiling.sig");
const node = @import("node.sig");

/// DRM's PRIME import (struct drm_prime_handle: u32 handle, u32 flags,
/// s32 fd) and nv_drm's G_BUFFER_INFO (in: u32 handle; out: u64 GPU
/// address at 8, u64 mmap offset at 16, u64 length at 24).
pub const PRIME_FD_TO_HANDLE: u32 = 0xc00c_642e;
pub const G_BUFFER_INFO: u32 = 0xc020_4709;

/// VASurfaceAttribExternalBuffers (va.h; x86-64 LP64: 80 bytes).
pub const ExternalBuffers = extern struct {
    pixel_format: u32,
    width: u32,
    height: u32,
    data_size: u32,
    num_planes: u32,
    pitches: [4]u32,
    offsets: [4]u32,
    buffers: ?[*]usize,
    num_buffers: u32,
    flags: u32,
    private_data: ?*anyopaque,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(ExternalBuffers, "buffers") == 56);
        std.debug.assert(@offsetOf(ExternalBuffers, "num_buffers") == 64);
        std.debug.assert(@sizeOf(ExternalBuffers) == 80);
    }
}

pub const Layout = enum { linear, block_linear };

/// One surface's import, as described: each plane's fd, offset, pitch.
pub const Plan = struct {
    layout: Layout,
    fd: [2]i32,
    offset: [2]u32,
    pitch: [2]u32,
    /// the objects' sizes (0: unknown)
    size: [2]u32 = .{ 0, 0 },
    /// block linear: log2 of GOBs per block
    gobs_log2: u4 = 0,
    width: u32,
    height: u32,
};

pub const Error = error{ Unsupported, BadDescriptor };

/// A DRM_PRIME_2 descriptor's NV12 picture (one layer of two planes, or
/// two layers R8 + GR88), checked against what the encoder reads.
pub fn fromPrime2(d: *const va.DrmPrimeDescriptor, gob: tiling.Gob) Error!Plan {
    if (d.fourcc != va.FOURCC_NV12) return error.Unsupported;
    if (d.num_objects == 0 or d.num_objects > 2 or d.num_layers == 0 or d.num_layers > 2) return error.BadDescriptor;
    // the two planes: (object, offset, pitch)
    var obj: [2]u32 = undefined;
    var off: [2]u32 = undefined;
    var pitch: [2]u32 = undefined;
    if (d.num_layers == 1) {
        const l = d.layers[0];
        if (l.drm_format != va.DRM_FORMAT_NV12 or l.num_planes != 2) return error.Unsupported;
        for (0..2) |p| {
            obj[p] = l.object_index[p];
            off[p] = l.offset[p];
            pitch[p] = l.pitch[p];
        }
    } else {
        if (d.layers[0].drm_format != va.DRM_FORMAT_R8 or d.layers[1].drm_format != va.DRM_FORMAT_GR88) return error.Unsupported;
        for (0..2) |p| {
            const l = d.layers[p];
            if (l.num_planes != 1) return error.BadDescriptor;
            obj[p] = l.object_index[0];
            off[p] = l.offset[0];
            pitch[p] = l.pitch[0];
        }
    }
    for (obj) |o| {
        if (o >= d.num_objects) return error.BadDescriptor;
    }
    var plan = Plan{
        .layout = .linear,
        .fd = .{ d.objects[obj[0]].fd, d.objects[obj[1]].fd },
        .offset = off,
        .pitch = pitch,
        .size = .{ d.objects[obj[0]].size, d.objects[obj[1]].size },
        .width = d.width,
        .height = d.height,
    };
    const mods = [2]u64{ d.objects[obj[0]].drm_format_modifier, d.objects[obj[1]].drm_format_modifier };
    if (mods[0] == va.DRM_FORMAT_MOD_LINEAR and mods[1] == va.DRM_FORMAT_MOD_LINEAR) return check(plan);
    // block linear: both planes NVIDIA's, one block height, each plane's
    // swizzle the one the GPU uses for its texels
    const y = tiling.parseModifier(mods[0]) orelse return error.Unsupported;
    const uv = tiling.parseModifier(mods[1]) orelse return error.Unsupported;
    if (y.gobs_log2 != uv.gobs_log2) return error.Unsupported;
    const want = tiling.Nv12.of(16, 16).swizzles(gob);
    if (y.swizzle != want[0]) return error.Unsupported;
    // (one modifier for both planes, as a single-object export gives it:
    // the plane's own swizzle is implied)
    if (uv.swizzle != want[1] and mods[1] != mods[0]) return error.Unsupported;
    plan.layout = .block_linear;
    plan.gobs_log2 = y.gobs_log2;
    return check(plan);
}

/// VASurfaceAttribExternalBuffers with DRM PRIME fds: buffer `k`'s NV12
/// picture, pitch linear (no modifier is given this way).
pub fn fromExternal(e: *const ExternalBuffers, k: usize) Error!Plan {
    if (e.pixel_format != va.FOURCC_NV12 or e.num_planes != 2) return error.Unsupported;
    const bufs = e.buffers orelse return error.BadDescriptor;
    if (k >= e.num_buffers) return error.BadDescriptor;
    const fd: i32 = @intCast(@as(isize, @bitCast(bufs[k])));
    return check(.{
        .layout = .linear,
        .fd = .{ fd, fd },
        .offset = .{ e.offsets[0], e.offsets[1] },
        .pitch = .{ e.pitches[0], e.pitches[1] },
        .size = .{ e.data_size, e.data_size },
        .width = e.width,
        .height = e.height,
    });
}

fn check(p: Plan) Error!Plan {
    if (p.width == 0 or p.height == 0 or p.fd[0] < 0 or p.fd[1] < 0) return error.BadDescriptor;
    if (p.pitch[0] < p.width or p.pitch[1] < 2 * ((p.width + 1) / 2)) return error.BadDescriptor;
    // (the engine's planes: 256-byte aligned addresses)
    if (p.offset[0] % 256 != 0 or p.offset[1] % 256 != 0) return error.Unsupported;
    if (p.layout == .block_linear and (p.pitch[0] % tiling.GOB_WIDTH != 0 or p.pitch[1] % tiling.GOB_WIDTH != 0)) return error.BadDescriptor;
    // (the converter's linear copy: one pitch for both planes)
    if (p.layout == .linear and p.pitch[0] != p.pitch[1]) return error.Unsupported;
    return p;
}

/// The bytes a plane takes (`rows` rows; block linear: whole blocks).
pub fn planeBytes(p: Plan, plane: u1) u64 {
    const rows: u32 = if (plane == 0) p.height else (p.height + 1) / 2;
    if (p.layout == .linear) return @as(u64, p.pitch[plane]) * rows;
    const block_rows = @as(u32, tiling.GOB_ROWS) << p.gobs_log2;
    return @as(u64, p.pitch[plane]) * std.mem.alignForward(u32, rows, block_rows);
}

/// A dma-buf as one of the node's buffers (mapped), or null when the
/// kernel refuses it or it is smaller than `min_bytes`.
pub fn importFd(n: anytype, fd: i32, min_bytes: u64) ?node.Buf {
    if (n.lost or n.fd < 0) return null;
    var a = [_]u8{0} ** 12;
    node.wr32(&a, 8, @bitCast(fd));
    if (n.sys.ioctl(n.fd, PRIME_FD_TO_HANDLE, &a) != 0) return null;
    const handle = node.rd32(&a, 0);
    var info = [_]u8{0} ** 32;
    node.wr32(&info, 0, handle);
    if (n.sys.ioctl(n.fd, G_BUFFER_INFO, &info) != 0) return drop(n, handle);
    const va_ = node.rd64(&info, 8);
    const off = node.rd64(&info, 16);
    const len = std.math.cast(usize, node.rd64(&info, 24)) orelse return drop(n, handle);
    if (len < min_bytes) return drop(n, handle);
    const at = n.sys.mapBuffer(n.fd, len, off);
    if (at < 0) return drop(n, handle);
    return .{ .handle = handle, .va = va_, .cpu = @ptrFromInt(@as(usize, @intCast(at))), .len = len };
}

fn drop(n: anytype, handle: u32) ?node.Buf {
    var a = [_]u8{0} ** 4;
    node.wr32(&a, 0, handle);
    _ = n.sys.ioctl(n.fd, node.G_FREE, &a);
    return null;
}

// ── RGB (screen capture) ────────────────────────────────────────────────────

/// A 32-bit RGB picture's byte order in memory: B G R X (DRM XRGB8888 /
/// ARGB8888, VA BGRX / BGRA) or R G B X (XBGR8888 / ABGR8888, RGBX / RGBA).
pub const RgbOrder = enum(u32) { bgrx = 0, rgbx = 1 };

pub const DRM_FORMAT_XRGB8888: u32 = 0x3432_5258; // 'X','R','2','4'
pub const DRM_FORMAT_ARGB8888: u32 = 0x3432_5241; // 'A','R','2','4'
pub const DRM_FORMAT_XBGR8888: u32 = 0x3432_4258; // 'X','B','2','4'
pub const DRM_FORMAT_ABGR8888: u32 = 0x3432_4241; // 'A','B','2','4'
pub const FOURCC_BGRX: u32 = 0x5852_4742; // 'B','G','R','X'
pub const FOURCC_BGRA: u32 = 0x4152_4742;
pub const FOURCC_RGBX: u32 = 0x5842_4752;
pub const FOURCC_RGBA: u32 = 0x4142_4752;

pub fn rgbOrder(fourcc: u32) ?RgbOrder {
    return switch (fourcc) {
        DRM_FORMAT_XRGB8888, DRM_FORMAT_ARGB8888, FOURCC_BGRX, FOURCC_BGRA => .bgrx,
        DRM_FORMAT_XBGR8888, DRM_FORMAT_ABGR8888, FOURCC_RGBX, FOURCC_RGBA => .rgbx,
        else => null,
    };
}

/// One RGB picture to convert into a surface's NV12 block-linear planes
/// (the GPU's job: enc_rgb.sig; `rgbToNv12` is its reference).
pub const RgbJob = struct {
    /// the surface's planes (block linear) and the RGB picture (linear):
    /// CPU views, and dma-bufs for a GPU converter
    dst: []u8,
    dst_fd: i32 = -1,
    layout: tiling.Nv12,
    gob: tiling.Gob,
    src: []const u8,
    src_fd: i32 = -1,
    src_offset: u32,
    src_pitch: u32,
    order: RgbOrder,
    width: u32,
    height: u32,
};

/// BT.601, limited range (libyuv's ARGBToNV12, what WebRTC's software
/// path makes): Y from a pixel, U and V from a 2x2 block's average.
pub fn lumaOf(r: i32, g: i32, b: i32) u8 {
    return @intCast(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}
pub fn cbOf(r: i32, g: i32, b: i32) u8 {
    return @intCast(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
}
pub fn crOf(r: i32, g: i32, b: i32) u8 {
    return @intCast(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
}

/// Pixel (x, y) of the job's picture (clamped into it: the padding to
/// whole macroblocks repeats the last column and row): r, g, b.
pub fn pixel(j: RgbJob, x: u32, y: u32) [3]i32 {
    const at = j.src_offset + @min(y, j.height - 1) * j.src_pitch + @min(x, j.width - 1) * 4;
    const p = j.src[at..][0..4];
    return if (j.order == .bgrx) .{ p[2], p[1], p[0] } else .{ p[0], p[1], p[2] };
}

/// The conversion on the CPU: the reference the GPU kernel is tested
/// against, and the tests' converter. The whole macroblock-aligned
/// picture is written.
pub fn rgbToNv12(j: RgbJob) void {
    const sw = j.layout.swizzles(j.gob);
    const w = std.mem.alignForward(u32, j.width, 16);
    const h = std.mem.alignForward(u32, j.height, 16);
    for (0..h) |yy| {
        for (0..w) |xx| {
            const c = pixel(j, @intCast(xx), @intCast(yy));
            j.dst[j.layout.luma.offsetOf(sw[0], xx, yy)] = lumaOf(c[0], c[1], c[2]);
        }
    }
    const uv = j.dst[@intCast(j.layout.chroma_offset)..];
    for (0..h / 2) |cy| {
        for (0..w / 2) |cx| {
            var s = [3]i32{ 0, 0, 0 };
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const c = pixel(j, @intCast(2 * cx + dx), @intCast(2 * cy + dy));
                    for (&s, c) |*a, v| a.* += v;
                }
            }
            for (&s) |*a| a.* = (a.* + 2) >> 2;
            uv[j.layout.chroma.offsetOf(sw[1], 2 * cx, cy)] = cbOf(s[0], s[1], s[2]);
            uv[j.layout.chroma.offsetOf(sw[1], 2 * cx + 1, cy)] = crOf(s[0], s[1], s[2]);
        }
    }
}

/// What the driver keeps of an imported surface (beside its Surface).
pub const Imported = struct {
    used: bool = false,
    layout: Layout = .linear,
    /// block linear: the planes' GPU addresses, pitches, block height
    luma: u64 = 0,
    chroma: u64 = 0,
    pitch: [2]u32 = .{ 0, 0 },
    gobs_log2: u4 = 0,
    rows: u32 = 0,
    /// a second buffer (the chroma plane's, when it is another dma-buf)
    second: node.Buf = .{},
    /// an RGB picture (converted into the surface's NV12 planes before
    /// each encode): its buffer, dma-buf, offset, pitch, byte order
    rgb: ?struct { buf: node.Buf, fd: i32, offset: u32, pitch: u32, order: RgbOrder } = null,
};

pub const RgbPic = struct { fd: i32, offset: u32, pitch: u32, order: RgbOrder, size: u32 };

/// A DRM_PRIME_2 descriptor's or the external buffers' RGB picture (one
/// plane, pitch linear): its fd, offset, pitch, order; null when it is not
/// one.
pub fn rgbOfPrime2(d: *const va.DrmPrimeDescriptor) ?RgbPic {
    const order = rgbOrder(d.fourcc) orelse (if (d.num_layers == 1) rgbOrder(d.layers[0].drm_format) else null) orelse return null;
    if (d.num_objects != 1 or d.num_layers != 1 or d.layers[0].num_planes != 1) return null;
    if (d.objects[0].drm_format_modifier != va.DRM_FORMAT_MOD_LINEAR) return null;
    const l = d.layers[0];
    if (l.pitch[0] < d.width * 4) return null;
    return .{ .fd = d.objects[0].fd, .offset = l.offset[0], .pitch = l.pitch[0], .order = order, .size = d.objects[0].size };
}

pub fn rgbOfExternal(e: *const ExternalBuffers, k: usize) ?RgbPic {
    const order = rgbOrder(e.pixel_format) orelse return null;
    const bufs = e.buffers orelse return null;
    if (k >= e.num_buffers or e.pitches[0] < e.width * 4) return null;
    return .{ .fd = @intCast(@as(isize, @bitCast(bufs[k]))), .offset = e.offsets[0], .pitch = e.pitches[0], .order = order, .size = e.data_size };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn desc(m0: u64, m1: u64) va.DrmPrimeDescriptor {
    var d = std.mem.zeroes(va.DrmPrimeDescriptor);
    d.fourcc = va.FOURCC_NV12;
    d.width = 1280;
    d.height = 720;
    d.num_objects = 2;
    d.objects[0] = .{ .fd = 7, .size = 1 << 20, .drm_format_modifier = m0 };
    d.objects[1] = .{ .fd = 8, .size = 1 << 20, .drm_format_modifier = m1 };
    d.num_layers = 2;
    d.layers[0] = .{ .drm_format = va.DRM_FORMAT_R8, .num_planes = 1, .object_index = .{ 0, 0, 0, 0 }, .offset = .{ 0, 0, 0, 0 }, .pitch = .{ 1280, 0, 0, 0 } };
    d.layers[1] = .{ .drm_format = va.DRM_FORMAT_GR88, .num_planes = 1, .object_index = .{ 1, 0, 0, 0 }, .offset = .{ 1280 * 720, 0, 0, 0 }, .pitch = .{ 1280, 0, 0, 0 } };
    return d;
}

test "enc_import: NVIDIA's block-linear modifiers, the GPU's swizzles; linear; what is refused" {
    const y = tiling.modifierOf(.blackwell8);
    const uv = tiling.modifierOf(.blackwell16);
    const p = try fromPrime2(&desc(y, uv), .blackwell);
    try testing.expectEqual(Layout.block_linear, p.layout);
    try testing.expectEqual(@as(u4, tiling.BLOCK_GOBS_LOG2), p.gobs_log2);
    try testing.expectEqual([2]i32{ 7, 8 }, p.fd);
    // any block height (16 GOBs here) is read as it is
    const tall = tiling.nvidiaBlockLinear2d(0, 2, 2, 6, 4);
    const tall_uv = tiling.nvidiaBlockLinear2d(0, 3, 2, 6, 4);
    try testing.expectEqual(@as(u4, 4), (try fromPrime2(&desc(tall, tall_uv), .blackwell)).gobs_log2);
    try testing.expectEqual(@as(u64, 1280 * 768), planeBytes(try fromPrime2(&desc(tall, tall_uv), .blackwell), 0));
    // Turing's layout on a Blackwell picture: not what the engine reads
    try testing.expectError(error.Unsupported, fromPrime2(&desc(tiling.modifierOf(.turing2d), tiling.modifierOf(.turing2d)), .blackwell));
    try testing.expect((try fromPrime2(&desc(tiling.modifierOf(.turing2d), tiling.modifierOf(.turing2d)), .turing)).layout == .block_linear);
    // compressed: refused
    try testing.expectError(error.Unsupported, fromPrime2(&desc(tiling.nvidiaBlockLinear2d(1, 2, 2, 6, 1), uv), .blackwell));
    // linear, one layer of two planes in one object
    var l = desc(0, 0);
    l.num_layers = 1;
    l.num_objects = 1;
    l.layers[0] = .{ .drm_format = va.DRM_FORMAT_NV12, .num_planes = 2, .object_index = .{ 0, 0, 0, 0 }, .offset = .{ 0, 1280 * 720, 0, 0 }, .pitch = .{ 1280, 1280, 0, 0 } };
    const lp = try fromPrime2(&l, .blackwell);
    try testing.expectEqual(Layout.linear, lp.layout);
    try testing.expectEqual([2]i32{ 7, 7 }, lp.fd);
    // a pitch smaller than the picture, an unaligned plane
    l.layers[0].pitch[0] = 1000;
    try testing.expectError(error.BadDescriptor, fromPrime2(&l, .blackwell));
    l.layers[0].pitch[0] = 1280;
    l.layers[0].offset[1] = 1280 * 720 + 64;
    try testing.expectError(error.Unsupported, fromPrime2(&l, .blackwell));
    // VASurfaceAttribExternalBuffers: fds, linear
    var fds = [_]usize{ 11, 12 };
    var e = std.mem.zeroes(ExternalBuffers);
    e.pixel_format = va.FOURCC_NV12;
    e.width = 640;
    e.height = 480;
    e.data_size = 640 * 480 * 3 / 2;
    e.num_planes = 2;
    e.pitches = .{ 640, 640, 0, 0 };
    e.offsets = .{ 0, 640 * 480, 0, 0 };
    e.buffers = &fds;
    e.num_buffers = 2;
    const x = try fromExternal(&e, 1);
    try testing.expectEqual([2]i32{ 12, 12 }, x.fd);
    try testing.expectError(error.BadDescriptor, fromExternal(&e, 2));
}
