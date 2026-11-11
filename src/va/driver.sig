//! @zpm/va driver — Galaxy's VA-API driver for the RTX's video decoder
//! (NVDEC, NVCFB0 on GB206): the state behind each of libva's entry
//! points, over Galaxy's render node (node.sig). libgalaxy_va.sig puts it
//! behind libva's C table. H.264 is the driver's own (nvdec.sig); HEVC,
//! VP9 and AV1 are codec modules (codec.sig says what they are given).
//!
//! What a decode is here:
//!
//! - **Surfaces** (MAX_SURFACES) are NV12 pictures, each two buffers in
//!   system memory: the decode target, block linear as NVDEC writes it
//!   (tiling.Nv12), and a pitch-linear copy (tiling.Linear) that is what
//!   the app sees: exported as one dma-buf (made once, a new fd per
//!   vaExportSurfaceHandle), derived as a VAImage, read by vaGetImage.
//! - **Contexts** (MAX_CONTEXTS) each have one work buffer: FRAMES frame
//!   slots (a pushbuffer, the picture setup, the slice table, the status,
//!   the codec's side buffers, then the bitstream, each a frame's own so
//!   the CPU fills the next while the decoder reads the last), then the
//!   decoder's scratch (H.264: co-located motion for every picture slot,
//!   macroblock history, history; a module's: what scratchBytes says).
//! - **BeginPicture** takes the next frame slot (waiting for its last
//!   decode); **RenderPicture** keeps the picture parameters and scaling
//!   lists and writes each slice into the slot's bitstream with a start
//!   code in front (VA hands slices without one), its offset in the slice
//!   table; **EndPicture** gives the target and each reference a picture
//!   slot (a reference keeps its slot while it is one: its co-located data
//!   is there), writes the setup (nvdec.h264Setup) and the pushbuffer
//!   (nvdec.h264Push) and submits it on the video channel (G_VSUBMIT).
//! - **SyncSurface** (and anything that reads a surface: export, derive,
//!   GetImage, a status query that finds it done) waits for the decode's
//!   fence (G_VWAIT), reads the decoder's status (errors counted; said on
//!   stderr with GALAXY_VA_DEBUG) and copies the target to the linear
//!   picture on the CPU (tiling.detile). A GPU copy is the later step.
//!
//! VA buffers live in a fixed pool reserved at init: SMALL_BUFFERS of 64
//! KiB (parameters) and LARGE_BUFFERS of 16 MiB (slice data, images).
//!
//! Allocation-free: fixed tables, the kernel's buffers, the reserved pool.
//! Not thread-safe by itself: libgalaxy_va holds a lock around each call.

const std = @import("std");
const va = @import("vaapi.sig");
const nvdec = @import("nvdec.sig");
const tiling = @import("tiling.sig");
const node = @import("node.sig");
const codec = @import("codec.sig");
const hevc = @import("hevc.sig");
const av1 = @import("av1.sig");

const Buf = node.Buf;

pub const MAX_CONFIGS = 16;
pub const MAX_SURFACES = 64;
pub const MAX_CONTEXTS = 4;
pub const MAX_IMAGES = 16;
pub const SMALL_BUFFERS = 96;
pub const SMALL_BYTES: usize = 64 << 10;
pub const LARGE_BUFFERS = 16;
pub const LARGE_BYTES: usize = 16 << 20;
pub const MAX_BUFFERS = SMALL_BUFFERS + LARGE_BUFFERS;
const POOL_BYTES = SMALL_BUFFERS * SMALL_BYTES + LARGE_BUFFERS * LARGE_BYTES;

/// Frame slots per context, and each one's bytes.
pub const FRAMES = 4;
pub const FRAME_BYTES: usize = 8 << 20;
pub const PUSH_OFF: usize = 0;
pub const PUSH_DWORDS_MAX: usize = 0x800 / 4;
pub const PIC_OFF: usize = 0x800;
pub const SLICES_OFF: usize = PIC_OFF + codec.PIC_BYTES;
pub const STATUS_OFF: usize = SLICES_OFF + 0x400;
pub const AUX_OFF: usize = 0x2000;
pub const STREAM_OFF: usize = AUX_OFF + codec.AUX_BYTES;
/// The bitstream's room in a frame slot (the end of stream after it).
pub const STREAM_ROOM: usize = FRAME_BYTES - STREAM_OFF - nvdec.EOS.len - 256;

/// NVDEC's H.264 limit (and this driver's for every codec).
pub const MAX_SIZE = 4096;
/// Surfaces' rows are padded to this: the decoder writes whole coding
/// blocks (HEVC's 64-row CTUs, VP9's 64-row and AV1's 128-row superblocks).
pub const SURFACE_ROW_ALIGN = 128;
pub const MIN_SIZE = 16;
/// How long a sync waits for a decode (NVK's watchdog ends a wedged one
/// far sooner).
pub const SYNC_NS: i64 = 2_000_000_000;

pub const VENDOR = "Galaxy VA-API driver for the RTX's NVDEC (H.264, HEVC, AV1), zpm";

// Each kind of object's ids: base + index.
pub const CONFIG_BASE: u32 = 0x100;
pub const CONTEXT_BASE: u32 = 0x200;
pub const SURFACE_BASE: u32 = 0x400;
pub const BUFFER_BASE: u32 = 0x1000;
pub const IMAGE_BASE: u32 = 0x2000;
const NONE: u16 = 0xffff;

pub const PROFILES = [_]va.Profile{ va.PROFILE_H264_CONSTRAINED_BASELINE, va.PROFILE_H264_MAIN, va.PROFILE_H264_HIGH, hevc.PROFILE, av1.PROFILE };

pub fn supported(profile: va.Profile) bool {
    return std.mem.indexOfScalar(va.Profile, &PROFILES, profile) != null;
}

pub const Codec = enum { h264, hevc, av1 };

pub fn codecOf(profile: va.Profile) Codec {
    return switch (profile) {
        hevc.PROFILE => .hevc,
        av1.PROFILE => .av1,
        else => .h264,
    };
}

pub const Options = struct {
    /// which GPU generation's GOB layouts the decoder writes (tiling.sig)
    gob: tiling.Gob = .blackwell,
    /// GALAXY_VA_DEBUG: decode errors and the driver's doings on stderr
    debug: bool = false,
    /// a do-nothing submission at init, so a GPU without a decoder fails
    /// vaInitialize (and Firefox's probe) instead of the first frame
    probe: bool = true,
    /// GALAXY_VA_AV1_BLACKWELL: AV1's Blackwell extras (av1.State.blackwell)
    av1_blackwell: bool = false,
};

const Config = struct {
    used: bool = false,
    profile: va.Profile = 0,
};

const Surface = struct {
    used: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    layout: tiling.Nv12 = undefined,
    linear_layout: tiling.Linear = undefined,
    /// the decode target (block linear), its linear copy
    tiled: Buf = .{},
    linear: Buf = .{},
    /// the linear copy's dma-buf (made at the first export)
    dmabuf: i32 = -1,
    /// a decode into it not yet seen done
    pending: bool = false,
    fence: u32 = 0,
    /// that decode's context, frame slot and number
    ctx: u8 = 0,
    frame: u8 = 0,
    serial: u32 = 0,
    /// fields decoded into it (1 top, 2 bottom) for the picture
    /// `field_frame_num`, and whether its last decode was a field
    fields: u2 = 0,
    field_frame_num: u16 = 0,
    field_coded: bool = false,
    /// its last decode's status said nothing came out right
    failed: bool = false,
};

const Context = struct {
    used: bool = false,
    config: u16 = 0,
    codec: Codec = .h264,
    /// a module's buffers in the work buffer (after the frame slots)
    scratch_off: usize = 0,
    scratch_bytes: usize = 0,
    /// each module's state (only the context's codec's is used)
    hevc: hevc.State = undefined,
    av1: av1.State = undefined,
    /// the target's VA id (a module's Picture)
    target_id: u32 = 0,
    width_mbs: u32 = 0,
    height_mbs: u32 = 0,
    work: Buf = .{},
    sizes: nvdec.Sizes = undefined,
    coloc_off: usize = 0,
    mbhist_off: usize = 0,
    history_off: usize = 0,
    /// each frame slot's last decode: fence, surface, number
    frame_fence: [FRAMES]u32 = [_]u32{0} ** FRAMES,
    frame_surface: [FRAMES]u16 = [_]u16{NONE} ** FRAMES,
    frame_serial: [FRAMES]u32 = [_]u32{0} ** FRAMES,
    next_frame: u8 = 0,
    /// decodes so far (SET_PICTURE_INDEX)
    decodes: u32 = 0,
    /// each picture slot's surface
    slot_surface: [nvdec.SLOTS]u16 = [_]u16{NONE} ** nvdec.SLOTS,
    // ── the picture being made (BeginPicture .. EndPicture) ──
    target: u16 = NONE,
    frame: u8 = 0,
    pic: va.PictureParameterBufferH264 = undefined,
    have_pic: bool = false,
    iq: va.IQMatrixBufferH264 = undefined,
    have_iq: bool = false,
    slices: u32 = 0,
    stream: u32 = 0,
    l0: u8 = 0,
    l1: u8 = 0,
    /// the slice parameter buffer whose data comes next
    last_param: u16 = NONE,
    /// what went wrong while rendering (EndPicture reports it)
    bad: va.Status = va.SUCCESS,

    fn frameBytes(c: *const Context, f: usize) []u8 {
        return c.work.bytes()[f * FRAME_BYTES ..][0..FRAME_BYTES];
    }
};

const Buffer = struct {
    used: bool = false,
    type: u32 = 0,
    size: u32 = 0,
    count: u32 = 0,
    /// a derived image's: the surface's linear picture, not the pool
    surface: u16 = NONE,
    mapped: bool = false,
};

const ImageEntry = struct {
    used: bool = false,
    image: va.Image = undefined,
    /// derived from this surface (NONE: its own buffer)
    surface: u16 = NONE,
    buffer: u16 = NONE,
};

pub fn Driver(comptime Sys: type) type {
    return struct {
        const Self = @This();

        node: node.Node(Sys),
        own_fd: bool = false,
        opts: Options = .{},
        pool: ?[*]u8 = null,
        configs: [MAX_CONFIGS]Config = [_]Config{.{}} ** MAX_CONFIGS,
        surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES,
        contexts: [MAX_CONTEXTS]Context = [_]Context{.{}} ** MAX_CONTEXTS,
        buffers: [MAX_BUFFERS]Buffer = [_]Buffer{.{}} ** MAX_BUFFERS,
        images: [MAX_IMAGES]ImageEntry = [_]ImageEntry{.{}} ** MAX_IMAGES,
        /// decodes submitted (each one's number), and those the decoder
        /// said went wrong
        serial: u32 = 0,
        errors: u32 = 0,

        // ── Saying things ───────────────────────────────────────────────

        fn say(d: *Self, comptime fmt: []const u8, args: anytype) void {
            var buf: [320]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "galaxy-va: " ++ fmt ++ "\n", args) catch return;
            d.node.sys.say(line);
        }

        fn debug(d: *Self, comptime fmt: []const u8, args: anytype) void {
            if (d.opts.debug) d.say(fmt, args);
        }

        // ── Init and terminate ──────────────────────────────────────────

        /// The driver on render node `fd` (libva's; -1: this opens one),
        /// if it is the RTX and has a video decoder.
        pub fn init(d: *Self, fd: i32, opts: Options) va.Status {
            d.opts = opts;
            if (fd >= 0) {
                d.node.fd = fd;
            } else {
                const f = d.node.sys.open(node.NODE);
                if (f < 0) {
                    d.say("no render node ({d}): no VA-API", .{f});
                    return va.ERROR_UNIMPLEMENTED;
                }
                d.node.fd = @intCast(f);
                d.own_fd = true;
            }
            const st = d.start();
            if (st != va.SUCCESS) d.terminate();
            return st;
        }

        fn start(d: *Self) va.Status {
            const i = d.node.info() orelse {
                d.say("the render node does not answer G_INFO: no VA-API", .{});
                return va.ERROR_UNIMPLEMENTED;
            };
            if (i.version != node.G_VERSION or i.chip != node.CHIP_GB206) {
                d.say("GPU {x} (node version {d}) has no decoder this driver knows: no VA-API", .{ i.chip, i.version });
                return va.ERROR_UNIMPLEMENTED;
            }
            if (i.lost) {
                d.say("the GPU is lost: no VA-API", .{});
                return va.ERROR_OPERATION_FAILED;
            }
            const at = d.node.sys.reserve(POOL_BYTES);
            if (at < 0) return va.ERROR_ALLOCATION_FAILED;
            d.pool = @ptrFromInt(@as(usize, @intCast(at)));
            if (d.opts.probe) return d.probe();
            return va.SUCCESS;
        }

        /// SET_OBJECT and a NOP on the video channel, waited for.
        fn probe(d: *Self) va.Status {
            var b = d.node.alloc(node.UNIT, 0) orelse return va.ERROR_ALLOCATION_FAILED;
            defer d.node.free(&b);
            const w = words(b.cpu, 0, 4);
            w[0] = nvdec.header(0, nvdec.SET_OBJECT, 1);
            w[1] = nvdec.CLASS | nvdec.SET_OBJECT_ENGINE_SW;
            w[2] = nvdec.header(0, nvdec.NOP, 1);
            w[3] = 0;
            const f = d.node.vsubmit(b, 0, 4) catch |e| {
                d.say("the RTX's video decoder is not there ({s}): no VA-API", .{@errorName(e)});
                return if (e == error.NoDecoder) va.ERROR_UNIMPLEMENTED else va.ERROR_OPERATION_FAILED;
            };
            switch (d.node.vwait(f, d.node.sys.nowNs() + SYNC_NS)) {
                .done => {
                    d.debug("the video decoder answered (fence {d}); GOBs as on {s}", .{ f, @tagName(d.opts.gob) });
                    return va.SUCCESS;
                },
                .timeout => d.say("the video decoder did not answer a NOP: no VA-API", .{}),
                .lost => d.say("the GPU was lost answering the video decoder's NOP: no VA-API", .{}),
            }
            return va.ERROR_OPERATION_FAILED;
        }

        /// Everything freed, the node closed if this opened it.
        pub fn terminate(d: *Self) void {
            for (0..MAX_CONTEXTS) |i| {
                if (d.contexts[i].used) _ = d.destroyContext(CONTEXT_BASE + @as(u32, @intCast(i)));
            }
            for (0..MAX_IMAGES) |i| {
                if (d.images[i].used) _ = d.destroyImage(IMAGE_BASE + @as(u32, @intCast(i)));
            }
            for (0..MAX_SURFACES) |i| {
                if (d.surfaces[i].used) d.dropSurface(@intCast(i));
            }
            for (&d.buffers) |*b| b.* = .{};
            if (d.pool) |p| d.node.sys.unmap(@intFromPtr(p), POOL_BYTES);
            d.pool = null;
            if (d.own_fd and d.node.fd >= 0) d.node.sys.close(d.node.fd);
            d.node.fd = -1;
            d.own_fd = false;
        }

        // ── Configs ─────────────────────────────────────────────────────

        pub fn queryConfigProfiles(_: *Self, list: [*]va.Profile, n: *i32) va.Status {
            for (PROFILES, 0..) |p, i| list[i] = p;
            n.* = PROFILES.len;
            return va.SUCCESS;
        }

        pub fn queryConfigEntrypoints(_: *Self, profile: va.Profile, list: [*]va.Entrypoint, n: *i32) va.Status {
            if (!supported(profile)) {
                n.* = 0;
                return va.ERROR_UNSUPPORTED_PROFILE;
            }
            list[0] = va.ENTRYPOINT_VLD;
            n.* = 1;
            return va.SUCCESS;
        }

        pub fn getConfigAttributes(_: *Self, profile: va.Profile, ep: va.Entrypoint, attribs: []va.ConfigAttrib) va.Status {
            if (!supported(profile)) return va.ERROR_UNSUPPORTED_PROFILE;
            if (ep != va.ENTRYPOINT_VLD) return va.ERROR_UNSUPPORTED_ENTRYPOINT;
            for (attribs) |*a| {
                a.value = switch (a.type) {
                    va.ATTRIB_RT_FORMAT => va.RT_FORMAT_YUV420,
                    va.ATTRIB_DEC_SLICE_MODE => va.DEC_SLICE_MODE_NORMAL,
                    va.ATTRIB_MAX_PICTURE_WIDTH, va.ATTRIB_MAX_PICTURE_HEIGHT => MAX_SIZE,
                    else => va.ATTRIB_NOT_SUPPORTED,
                };
            }
            return va.SUCCESS;
        }

        pub fn createConfig(d: *Self, profile: va.Profile, ep: va.Entrypoint, attribs: []const va.ConfigAttrib, out: *u32) va.Status {
            if (!supported(profile)) return va.ERROR_UNSUPPORTED_PROFILE;
            if (ep != va.ENTRYPOINT_VLD) return va.ERROR_UNSUPPORTED_ENTRYPOINT;
            for (attribs) |a| {
                if (a.type == va.ATTRIB_RT_FORMAT and a.value & va.RT_FORMAT_YUV420 == 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            }
            for (&d.configs, 0..) |*c, i| {
                if (c.used) continue;
                c.* = .{ .used = true, .profile = profile };
                out.* = CONFIG_BASE + @as(u32, @intCast(i));
                return va.SUCCESS;
            }
            return va.ERROR_ALLOCATION_FAILED;
        }

        pub fn destroyConfig(d: *Self, id: u32) va.Status {
            const c = d.configOf(id) orelse return va.ERROR_INVALID_CONFIG;
            c.* = .{};
            return va.SUCCESS;
        }

        pub fn queryConfigAttributes(d: *Self, id: u32, profile: *va.Profile, ep: *va.Entrypoint, attribs: ?[*]va.ConfigAttrib, n: *i32) va.Status {
            const c = d.configOf(id) orelse return va.ERROR_INVALID_CONFIG;
            profile.* = c.profile;
            ep.* = va.ENTRYPOINT_VLD;
            if (attribs) |a| a[0] = .{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420 };
            n.* = 1;
            return va.SUCCESS;
        }

        fn configOf(d: *Self, id: u32) ?*Config {
            if (id < CONFIG_BASE or id - CONFIG_BASE >= MAX_CONFIGS) return null;
            const c = &d.configs[id - CONFIG_BASE];
            return if (c.used) c else null;
        }

        // ── Surfaces ────────────────────────────────────────────────────

        const SURFACE_ATTRIBS = 6;

        pub fn querySurfaceAttributes(d: *Self, config: u32, list: ?[*]va.SurfaceAttrib, n: *u32) va.Status {
            if (d.configOf(config) == null) return va.ERROR_INVALID_CONFIG;
            const both = va.SURFACE_ATTRIB_GETTABLE | va.SURFACE_ATTRIB_SETTABLE;
            const all = [SURFACE_ATTRIBS]va.SurfaceAttrib{
                intAttrib(va.SURFACE_ATTRIB_PIXEL_FORMAT, both, va.FOURCC_NV12),
                intAttrib(va.SURFACE_ATTRIB_MIN_WIDTH, va.SURFACE_ATTRIB_GETTABLE, MIN_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MAX_WIDTH, va.SURFACE_ATTRIB_GETTABLE, MAX_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MIN_HEIGHT, va.SURFACE_ATTRIB_GETTABLE, MIN_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MAX_HEIGHT, va.SURFACE_ATTRIB_GETTABLE, MAX_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MEMORY_TYPE, both, va.MEM_TYPE_VA | va.MEM_TYPE_DRM_PRIME_2),
            };
            const out = list orelse {
                n.* = SURFACE_ATTRIBS;
                return va.SUCCESS;
            };
            if (n.* < SURFACE_ATTRIBS) {
                n.* = SURFACE_ATTRIBS;
                return va.ERROR_MAX_NUM_EXCEEDED;
            }
            for (all, 0..) |a, i| out[i] = a;
            n.* = SURFACE_ATTRIBS;
            return va.SUCCESS;
        }

        pub fn createSurfaces(d: *Self, format: u32, width: u32, height: u32, out: []u32, attribs: []const va.SurfaceAttrib) va.Status {
            if (format != va.RT_FORMAT_YUV420) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            if (width == 0 or height == 0) return va.ERROR_INVALID_PARAMETER;
            if (width > MAX_SIZE or height > MAX_SIZE) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            for (attribs) |a| {
                switch (a.type) {
                    va.SURFACE_ATTRIB_PIXEL_FORMAT => if (@as(u32, @bitCast(a.value.value.i)) != va.FOURCC_NV12) return va.ERROR_UNSUPPORTED_RT_FORMAT,
                    va.SURFACE_ATTRIB_MEMORY_TYPE => {
                        const t: u32 = @bitCast(a.value.value.i);
                        if (t != 0 and t != va.MEM_TYPE_VA and t != va.MEM_TYPE_DRM_PRIME_2) return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
                    },
                    // (importing an app's buffers: not done)
                    va.SURFACE_ATTRIB_EXTERNAL_BUFFER_DESCRIPTOR => if (a.value.value.p != null) return va.ERROR_UNSUPPORTED_MEMORY_TYPE,
                    else => {},
                }
            }
            for (out, 0..) |*id, k| {
                const i = d.makeSurface(width, height) orelse {
                    for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                    return va.ERROR_ALLOCATION_FAILED;
                };
                id.* = SURFACE_BASE + i;
            }
            d.debug("{d} surfaces of {d}x{d}", .{ out.len, width, height });
            return va.SUCCESS;
        }

        fn makeSurface(d: *Self, width: u32, height: u32) ?u16 {
            const i = for (d.surfaces, 0..) |s, i| {
                if (!s.used) break i;
            } else return null;
            const layout = tiling.Nv12.of(width, std.mem.alignForward(u32, height, SURFACE_ROW_ALIGN));
            const lin = tiling.Linear.of(width, height);
            var tiled = d.node.alloc(@intCast(layout.bytes), 0) orelse return null;
            const linear = d.node.alloc(lin.bytes, 0) orelse {
                d.node.free(&tiled);
                return null;
            };
            // (black until decoded: Y 16, UV 128)
            @memset(linear.bytes()[0..lin.uv_offset], 16);
            @memset(linear.bytes()[lin.uv_offset..lin.bytes], 128);
            d.surfaces[i] = .{ .used = true, .width = width, .height = height, .layout = layout, .linear_layout = lin, .tiled = tiled, .linear = linear };
            return @intCast(i);
        }

        fn dropSurface(d: *Self, i: u16) void {
            const s = &d.surfaces[i];
            for (&d.contexts) |*c| {
                if (!c.used) continue;
                for (&c.slot_surface) |*o| {
                    if (o.* == i) o.* = NONE;
                }
                for (&c.frame_surface) |*o| {
                    if (o.* == i) o.* = NONE;
                }
                if (c.target == i) c.target = NONE;
            }
            if (s.dmabuf >= 0) d.node.sys.close(s.dmabuf);
            // (the kernel keeps the pages until the decoder is done)
            d.node.free(&s.tiled);
            d.node.free(&s.linear);
            s.* = .{};
        }

        pub fn destroySurfaces(d: *Self, ids: []const u32) va.Status {
            for (ids) |id| {
                const i = d.surfaceIndex(id) orelse return va.ERROR_INVALID_SURFACE;
                d.dropSurface(i);
            }
            return va.SUCCESS;
        }

        fn surfaceIndex(d: *Self, id: u32) ?u16 {
            if (id < SURFACE_BASE or id - SURFACE_BASE >= MAX_SURFACES) return null;
            return if (d.surfaces[id - SURFACE_BASE].used) @intCast(id - SURFACE_BASE) else null;
        }

        // ── Contexts ────────────────────────────────────────────────────

        pub fn createContext(d: *Self, config: u32, width: u32, height: u32, out: *u32) va.Status {
            const cfg = d.configOf(config) orelse return va.ERROR_INVALID_CONFIG;
            if (width == 0 or height == 0 or width > MAX_SIZE or height > MAX_SIZE) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            const i = for (d.contexts, 0..) |c, i| {
                if (!c.used) break i;
            } else return va.ERROR_ALLOCATION_FAILED;
            const kind = codecOf(cfg.profile);
            if (kind != .h264) return d.createModuleContext(@intCast(i), config, kind, width, height, out);
            const wmbs = (width + 15) / 16;
            const hmbs = (height + 15) / 16;
            // (the frame's height in macroblocks: map units are at most it)
            const sz = nvdec.sizes(wmbs, hmbs);
            const coloc_off = FRAMES * FRAME_BYTES;
            const mbhist_off = std.mem.alignForward(usize, coloc_off + sz.coloc, 4096);
            const history_off = std.mem.alignForward(usize, mbhist_off + sz.mbhist, 4096);
            const total = history_off + sz.history;
            const work = d.node.alloc(total, 0) orelse return va.ERROR_ALLOCATION_FAILED;
            if (!nvdec.addressable(work.va) or !nvdec.addressable(work.va + work.len - 256)) {
                var w = work;
                d.node.free(&w);
                return va.ERROR_ALLOCATION_FAILED;
            }
            d.contexts[i] = .{
                .used = true,
                .config = @intCast(config - CONFIG_BASE),
                .width_mbs = wmbs,
                .height_mbs = hmbs,
                .work = work,
                .sizes = sz,
                .coloc_off = coloc_off,
                .mbhist_off = mbhist_off,
                .history_off = history_off,
            };
            out.* = CONTEXT_BASE + @as(u32, @intCast(i));
            d.debug("context {d}x{d}: work buffer {d} MiB", .{ width, height, work.len >> 20 });
            return va.SUCCESS;
        }

        /// A context for a codec module: the frame slots, then the module's
        /// buffers (zeroed).
        fn createModuleContext(d: *Self, i: u8, config: u32, kind: Codec, width: u32, height: u32, out: *u32) va.Status {
            const scratch_bytes = switch (kind) {
                .hevc => hevc.scratchBytes(width, height),
                .av1 => av1.scratchBytes(width, height),
                .h264 => unreachable,
            };
            const scratch_off = FRAMES * FRAME_BYTES;
            const total = scratch_off + scratch_bytes;
            var work = d.node.alloc(total, 0) orelse return va.ERROR_ALLOCATION_FAILED;
            if (!nvdec.addressable(work.va) or !nvdec.addressable(work.va + work.len - 256)) {
                d.node.free(&work);
                return va.ERROR_ALLOCATION_FAILED;
            }
            @memset(work.bytes()[scratch_off..total], 0);
            d.contexts[i] = .{
                .used = true,
                .config = @intCast(config - CONFIG_BASE),
                .codec = kind,
                .width_mbs = (width + 15) / 16,
                .height_mbs = (height + 15) / 16,
                .work = work,
                .scratch_off = scratch_off,
                .scratch_bytes = scratch_bytes,
            };
            switch (kind) {
                .hevc => d.contexts[i].hevc = hevc.State.init(width, height),
                .av1 => {
                    d.contexts[i].av1 = av1.State.init(width, height);
                    d.contexts[i].av1.blackwell = d.opts.av1_blackwell;
                },
                .h264 => unreachable,
            }
            out.* = CONTEXT_BASE + @as(u32, i);
            d.debug("{s} context {d}x{d}: work buffer {d} MiB", .{ @tagName(kind), width, height, work.len >> 20 });
            return va.SUCCESS;
        }

        pub fn destroyContext(d: *Self, id: u32) va.Status {
            const ci = d.contextIndex(id) orelse return va.ERROR_INVALID_CONTEXT;
            const c = &d.contexts[ci];
            // (its decodes finished, their status read, before it goes)
            for (0..FRAMES) |f| {
                const si = c.frame_surface[f];
                if (si != NONE and d.surfaces[si].pending and d.surfaces[si].serial == c.frame_serial[f]) {
                    _ = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
                }
            }
            d.node.free(&c.work);
            c.* = .{};
            return va.SUCCESS;
        }

        fn contextIndex(d: *Self, id: u32) ?u8 {
            if (id < CONTEXT_BASE or id - CONTEXT_BASE >= MAX_CONTEXTS) return null;
            return if (d.contexts[id - CONTEXT_BASE].used) @intCast(id - CONTEXT_BASE) else null;
        }

        // ── Buffers ─────────────────────────────────────────────────────

        fn storage(d: *Self, i: usize) []u8 {
            const p = d.pool.?;
            if (i < SMALL_BUFFERS) return p[i * SMALL_BYTES ..][0..SMALL_BYTES];
            return p[SMALL_BUFFERS * SMALL_BYTES + (i - SMALL_BUFFERS) * LARGE_BYTES ..][0..LARGE_BYTES];
        }

        fn newBuffer(d: *Self, bytes: usize) ?u16 {
            if (d.pool == null) return null;
            if (bytes <= SMALL_BYTES) {
                for (d.buffers[0..SMALL_BUFFERS], 0..) |b, i| {
                    if (!b.used) return @intCast(i);
                }
            }
            if (bytes <= LARGE_BYTES) {
                for (d.buffers[SMALL_BUFFERS..], SMALL_BUFFERS..) |b, i| {
                    if (!b.used) return @intCast(i);
                }
            }
            return null;
        }

        pub fn createBuffer(d: *Self, kind: u32, size: u32, count: u32, data: ?*const anyopaque, out: *u32) va.Status {
            const bytes = @as(u64, size) * count;
            if (bytes > LARGE_BYTES) return va.ERROR_ALLOCATION_FAILED;
            const i = d.newBuffer(@intCast(bytes)) orelse return va.ERROR_ALLOCATION_FAILED;
            d.buffers[i] = .{ .used = true, .type = kind, .size = size, .count = count };
            if (data) |p| @memcpy(d.storage(i)[0..@intCast(bytes)], @as([*]const u8, @ptrCast(p))[0..@intCast(bytes)]);
            out.* = BUFFER_BASE + i;
            return va.SUCCESS;
        }

        pub fn bufferSetNumElements(d: *Self, id: u32, count: u32) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            const b = &d.buffers[i];
            if (b.surface != NONE or @as(u64, b.size) * count > d.storage(i).len) return va.ERROR_INVALID_PARAMETER;
            b.count = count;
            return va.SUCCESS;
        }

        pub fn mapBuffer(d: *Self, id: u32, out: *?*anyopaque) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            const b = &d.buffers[i];
            if (b.surface != NONE) {
                // (a derived image: the decode's picture, once it is there)
                const st = d.complete(b.surface, d.node.sys.nowNs() + SYNC_NS);
                if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
                out.* = d.surfaces[b.surface].linear.cpu;
            } else out.* = d.storage(i).ptr;
            b.mapped = true;
            return va.SUCCESS;
        }

        pub fn unmapBuffer(d: *Self, id: u32) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            d.buffers[i].mapped = false;
            return va.SUCCESS;
        }

        pub fn destroyBuffer(d: *Self, id: u32) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            d.dropBuffer(i);
            return va.SUCCESS;
        }

        fn dropBuffer(d: *Self, i: u16) void {
            const b = d.buffers[i];
            for (&d.contexts) |*c| {
                if (c.last_param == i) c.last_param = NONE;
            }
            // (a large buffer's pages go back: the next may be small)
            const bytes = @as(usize, b.size) * b.count;
            if (b.surface == NONE and i >= SMALL_BUFFERS and bytes > SMALL_BYTES) {
                const s = d.storage(i);
                d.node.sys.discard(@intFromPtr(s.ptr), std.mem.alignForward(usize, bytes, 4096));
            }
            d.buffers[i] = .{};
        }

        pub fn bufferInfo(d: *Self, id: u32, kind: *u32, size: *u32, count: *u32) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            kind.* = d.buffers[i].type;
            size.* = d.buffers[i].size;
            count.* = d.buffers[i].count;
            return va.SUCCESS;
        }

        fn bufferIndex(d: *Self, id: u32) ?u16 {
            if (id < BUFFER_BASE or id - BUFFER_BASE >= MAX_BUFFERS) return null;
            return if (d.buffers[id - BUFFER_BASE].used) @intCast(id - BUFFER_BASE) else null;
        }

        fn bufferBytes(d: *Self, i: u16) []u8 {
            const b = d.buffers[i];
            return d.storage(i)[0 .. @as(usize, b.size) * b.count];
        }

        // ── Decoding ────────────────────────────────────────────────────

        pub fn beginPicture(d: *Self, ctx: u32, surface: u32) va.Status {
            const ci = d.contextIndex(ctx) orelse return va.ERROR_INVALID_CONTEXT;
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const c = &d.contexts[ci];
            c.target = NONE;
            // The next frame slot, once its last decode is done (that
            // surface's picture copied out now if nobody synced it).
            const f = c.next_frame;
            if (c.frame_fence[f] != 0) {
                const old = c.frame_surface[f];
                const deadline = d.node.sys.nowNs() + SYNC_NS;
                if (old != NONE and d.surfaces[old].pending and d.surfaces[old].serial == c.frame_serial[f]) {
                    const st = d.complete(old, deadline);
                    if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
                } else switch (d.node.vwait(c.frame_fence[f], deadline)) {
                    .done => {},
                    .timeout => return va.ERROR_TIMEDOUT,
                    .lost => return va.ERROR_OPERATION_FAILED,
                }
            }
            c.target = si;
            c.target_id = surface;
            c.frame = f;
            switch (c.codec) {
                .hevc => hevc.begin(&c.hevc),
                .av1 => av1.begin(&c.av1),
                .h264 => {},
            }
            c.have_pic = false;
            c.have_iq = false;
            c.slices = 0;
            c.stream = 0;
            c.last_param = NONE;
            c.bad = va.SUCCESS;
            return va.SUCCESS;
        }

        pub fn renderPicture(d: *Self, ctx: u32, ids: []const u32) va.Status {
            const ci = d.contextIndex(ctx) orelse return va.ERROR_INVALID_CONTEXT;
            const c = &d.contexts[ci];
            if (c.target == NONE) return va.ERROR_OPERATION_FAILED;
            for (ids) |id| {
                const bi = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
                const st = d.take(c, bi);
                if (st != va.SUCCESS) {
                    if (c.bad == va.SUCCESS) c.bad = st;
                    return st;
                }
            }
            return va.SUCCESS;
        }

        /// One buffer of the picture.
        fn take(d: *Self, c: *Context, bi: u16) va.Status {
            const b = d.buffers[bi];
            const data = d.bufferBytes(bi);
            if (c.codec != .h264) {
                const buf = codec.Buffer{ .kind = b.type, .size = b.size, .count = b.count, .data = data };
                const slot = frameSlot(c, c.frame);
                return switch (c.codec) {
                    .hevc => hevc.take(&c.hevc, buf, slot),
                    .av1 => av1.take(&c.av1, buf, slot),
                    .h264 => unreachable,
                };
            }
            switch (b.type) {
                va.PICTURE_PARAMETER_BUFFER => {
                    if (data.len < @sizeOf(va.PictureParameterBufferH264)) return va.ERROR_INVALID_BUFFER;
                    c.pic = std.mem.bytesToValue(va.PictureParameterBufferH264, data[0..@sizeOf(va.PictureParameterBufferH264)]);
                    c.have_pic = true;
                },
                va.IQ_MATRIX_BUFFER => {
                    if (data.len < @sizeOf(va.IQMatrixBufferH264)) return va.ERROR_INVALID_BUFFER;
                    c.iq = std.mem.bytesToValue(va.IQMatrixBufferH264, data[0..@sizeOf(va.IQMatrixBufferH264)]);
                    c.have_iq = true;
                },
                va.SLICE_PARAMETER_BUFFER => {
                    if (b.size < @sizeOf(va.SliceParameterBufferH264) or b.count == 0) return va.ERROR_INVALID_BUFFER;
                    if (c.slices == 0) {
                        // (the picture's active reference counts: its first
                        // slice's, as the decoder parses each slice's own)
                        const s = sliceParam(data, b.size, 0);
                        c.l0 = s.num_ref_idx_l0_active_minus1;
                        c.l1 = s.num_ref_idx_l1_active_minus1;
                    }
                    c.last_param = bi;
                },
                va.SLICE_DATA_BUFFER => {
                    if (c.last_param == NONE) return va.ERROR_INVALID_BUFFER;
                    const pb = d.buffers[c.last_param];
                    const params = d.bufferBytes(c.last_param);
                    const frame = c.frameBytes(c.frame);
                    const table = words(frame.ptr, SLICES_OFF, nvdec.MAX_SLICES + 1);
                    for (0..pb.count) |k| {
                        const s = sliceParam(params, pb.size, k);
                        if (@as(u64, s.slice_data_offset) + s.slice_data_size > data.len) return va.ERROR_INVALID_BUFFER;
                        if (c.slices >= nvdec.MAX_SLICES) return va.ERROR_MAX_NUM_EXCEEDED;
                        if (c.stream + 3 + @as(u64, s.slice_data_size) > STREAM_ROOM) return va.ERROR_NOT_ENOUGH_BUFFER;
                        // a start code, then the NAL unit (header first)
                        table[c.slices] = c.stream;
                        const at = frame[STREAM_OFF + c.stream ..];
                        at[0] = 0;
                        at[1] = 0;
                        at[2] = 1;
                        @memcpy(at[3..][0..s.slice_data_size], data[s.slice_data_offset..][0..s.slice_data_size]);
                        c.stream += 3 + s.slice_data_size;
                        c.slices += 1;
                    }
                    c.last_param = NONE;
                },
                else => return va.ERROR_UNSUPPORTED_BUFFERTYPE,
            }
            return va.SUCCESS;
        }

        pub fn endPicture(d: *Self, ctx: u32) va.Status {
            const ci = d.contextIndex(ctx) orelse return va.ERROR_INVALID_CONTEXT;
            const c = &d.contexts[ci];
            defer c.target = NONE;
            if (c.target == NONE) return va.ERROR_OPERATION_FAILED;
            if (c.bad != va.SUCCESS) return c.bad;
            if (c.codec != .h264) return d.endModule(ci, c);
            if (!c.have_pic or c.slices == 0) return va.ERROR_INVALID_PARAMETER;
            const pic = &c.pic;
            const wmbs = @as(u32, pic.picture_width_in_mbs_minus1) + 1;
            const hmbs = @as(u32, pic.picture_height_in_mbs_minus1) + 1;
            if (wmbs > c.width_mbs or hmbs > c.height_mbs) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            if (pic.seq_fields.chroma_format_idc != 1 or pic.bit_depth_luma_minus8 != 0 or pic.bit_depth_chroma_minus8 != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            const si = c.target;
            const s = &d.surfaces[si];
            if (wmbs * 16 > s.layout.luma.pitch or hmbs * 16 > s.layout.luma.rows) return va.ERROR_INVALID_SURFACE;

            // Fields: the second of a pair goes into the surface holding
            // the first.
            const field = pic.pic_fields.field_pic_flag != 0;
            const this: u2 = if (pic.CurrPic.flags & va.PICTURE_H264_BOTTOM_FIELD != 0) 2 else 1;
            const second = field and s.fields == (3 ^ this) and s.field_frame_num == pic.frame_num;

            // The references' surfaces, then everyone's picture slot.
            var ref_surface = [_]u16{NONE} ** 16;
            for (pic.ReferenceFrames, 0..) |rf, k| {
                if (rf.flags & va.PICTURE_H264_INVALID != 0) continue;
                ref_surface[k] = d.surfaceIndex(rf.picture_id) orelse NONE;
            }
            const slot = assignSlots(c, si, &ref_surface) orelse return va.ERROR_MAX_NUM_EXCEEDED;
            var refs = [_]?nvdec.Ref{null} ** 16;
            for (ref_surface, 0..) |r, k| {
                if (r == NONE) continue;
                const rs = slotOf(c, r) orelse continue;
                refs[k] = .{ .slot = rs, .is_field = d.surfaces[r].field_coded };
            }

            const setup = nvdec.h264Setup(.{
                .pic = pic,
                .iq = if (c.have_iq) &c.iq else null,
                .num_ref_idx_l0_active_minus1 = c.l0,
                .num_ref_idx_l1_active_minus1 = c.l1,
                .slice_count = c.slices,
                .stream_len = c.stream,
                .target = .{ .pitch_luma = s.layout.luma.pitch, .pitch_chroma = s.layout.chroma.pitch, .gob_height = tiling.GOB_HEIGHT_FIELD },
                .slot = slot,
                .second_field = second,
                .refs = refs,
                .sizes = c.sizes,
            });

            // The frame slot: setup, the slice table's end, the end of
            // stream, a clean status, the pushbuffer.
            const f = c.frame;
            const frame = c.frameBytes(f);
            @memcpy(frame[PIC_OFF..][0..@sizeOf(nvdec.H264Pic)], std.mem.asBytes(&setup));
            words(frame.ptr, SLICES_OFF, nvdec.MAX_SLICES + 1)[c.slices] = c.stream;
            @memcpy(frame[STREAM_OFF + c.stream ..][0..nvdec.EOS.len], &nvdec.EOS);
            @memset(frame[STATUS_OFF..][0..@sizeOf(nvdec.Status)], 0);
            const base = c.work.va + f * FRAME_BYTES;
            var a = nvdec.FrameAddrs{
                .pic_setup = base + PIC_OFF,
                .bitstream = base + STREAM_OFF,
                .slice_offsets = base + SLICES_OFF,
                .coloc = c.work.va + c.coloc_off,
                .history = c.work.va + c.history_off,
                .status = base + STATUS_OFF,
                .mbhist = c.work.va + c.mbhist_off,
                .luma = undefined,
                .chroma = undefined,
                .picture_index = c.decodes,
                .error_frm_idx = if (pic.num_ref_frames != 0) c.decodes % pic.num_ref_frames else 0,
            };
            for (c.slot_surface, 0..) |o, k| {
                // (a slot nobody holds names the target: never address 0)
                const ps = &d.surfaces[if (o == NONE) si else o];
                a.luma[k] = ps.tiled.va;
                a.chroma[k] = ps.tiled.va + ps.layout.chroma_offset;
                if (!nvdec.addressable(a.luma[k]) or !nvdec.addressable(a.chroma[k])) return va.ERROR_INVALID_SURFACE;
            }
            const n = nvdec.h264Push(words(frame.ptr, PUSH_OFF, nvdec.PUSH_DWORDS), a);
            const fence = d.node.vsubmit(c.work, @intCast(f * FRAME_BYTES + PUSH_OFF), @intCast(n)) catch |e| {
                d.say("a decode was not submitted ({s})", .{@errorName(e)});
                return if (e == error.NoDecoder) va.ERROR_UNIMPLEMENTED else va.ERROR_OPERATION_FAILED;
            };

            d.serial +%= 1;
            s.pending = true;
            s.fence = fence;
            s.ctx = ci;
            s.frame = f;
            s.serial = d.serial;
            s.failed = false;
            s.field_coded = field;
            s.fields = if (!field or second) 3 else this;
            s.field_frame_num = pic.frame_num;
            c.frame_fence[f] = fence;
            c.frame_surface[f] = si;
            c.frame_serial[f] = d.serial;
            c.next_frame = (f + 1) % FRAMES;
            c.decodes +%= 1;
            return va.SUCCESS;
        }

        /// A codec module's picture: its setup, side buffers and pushbuffer,
        /// submitted; waited for and handed back when it asks.
        fn endModule(d: *Self, ci: u8, c: *Context) va.Status {
            const si = c.target;
            const s = &d.surfaces[si];
            const f = c.frame;
            const slot = frameSlot(c, f);
            @memset(c.frameBytes(f)[STATUS_OFF..][0..@sizeOf(nvdec.Status)], 0);
            const scratch = codec.Scratch{ .cpu = c.work.bytes()[c.scratch_off..][0..c.scratch_bytes], .va = c.work.va + c.scratch_off };
            const pic = codec.Picture{ .target_id = c.target_id, .target = surfaceRef(s), .gob_height = tiling.GOB_HEIGHT_FIELD, .picture_index = c.decodes };
            if (!nvdec.addressable(pic.target.luma) or !nvdec.addressable(pic.target.chroma)) return va.ERROR_INVALID_SURFACE;
            const lookup = codec.Lookup{ .ctx = d, .surface_fn = lookupSurface };
            var e: codec.End = undefined;
            const st = switch (c.codec) {
                .hevc => hevc.end(&c.hevc, slot, scratch, pic, lookup, &e),
                .av1 => av1.end(&c.av1, slot, scratch, pic, lookup, &e),
                .h264 => unreachable,
            };
            if (st != va.SUCCESS) {
                d.debug("{s} picture refused ({x})", .{ @tagName(c.codec), st });
                return st;
            }
            std.debug.assert(e.dwords <= PUSH_DWORDS_MAX);
            const fence = d.node.vsubmit(c.work, @intCast(f * FRAME_BYTES + PUSH_OFF), @intCast(e.dwords)) catch |err| {
                d.say("a decode was not submitted ({s})", .{@errorName(err)});
                return if (err == error.NoDecoder) va.ERROR_UNIMPLEMENTED else va.ERROR_OPERATION_FAILED;
            };
            d.serial +%= 1;
            s.pending = true;
            s.fence = fence;
            s.ctx = ci;
            s.frame = f;
            s.serial = d.serial;
            s.failed = false;
            s.field_coded = false;
            s.fields = 3;
            c.frame_fence[f] = fence;
            c.frame_surface[f] = si;
            c.frame_serial[f] = d.serial;
            c.next_frame = (f + 1) % FRAMES;
            c.decodes +%= 1;
            if (e.wait) {
                const w = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
                if (w != va.SUCCESS and w != va.ERROR_DECODING_ERROR) return w;
                switch (c.codec) {
                    .hevc => hevc.after(&c.hevc, scratch),
                    .av1 => av1.after(&c.av1, scratch),
                    .h264 => unreachable,
                }
            }
            return va.SUCCESS;
        }

        fn lookupSurface(ctx: *anyopaque, id: u32) ?codec.SurfaceRef {
            const d: *Self = @ptrCast(@alignCast(ctx));
            const i = d.surfaceIndex(id) orelse return null;
            return surfaceRef(&d.surfaces[i]);
        }

        fn surfaceRef(s: *const Surface) codec.SurfaceRef {
            return .{
                .luma = s.tiled.va,
                .chroma = s.tiled.va + s.layout.chroma_offset,
                .width = s.width,
                .height = s.height,
                .pitch_luma = s.layout.luma.pitch,
                .pitch_chroma = s.layout.chroma.pitch,
            };
        }

        /// The decode into surface `si` done by `deadline` (0: only look),
        /// its status read and its picture copied out linear.
        fn complete(d: *Self, si: u16, deadline: i64) va.Status {
            const s = &d.surfaces[si];
            if (!s.pending) return if (s.failed) va.ERROR_DECODING_ERROR else va.SUCCESS;
            switch (d.node.vwait(s.fence, deadline)) {
                .done => {},
                .timeout => return va.ERROR_TIMEDOUT,
                .lost => {
                    s.pending = false;
                    d.say("the GPU was lost during a decode", .{});
                    return va.ERROR_OPERATION_FAILED;
                },
            }
            s.pending = false;
            const c = &d.contexts[s.ctx];
            if (c.used and c.frame_serial[s.frame] == s.serial) {
                const at = c.frameBytes(s.frame)[STATUS_OFF..][0..@sizeOf(nvdec.Status)];
                const st = std.mem.bytesToValue(nvdec.Status, at);
                if (st.failed()) {
                    d.errors += 1;
                    // (nothing decoded at all: the caller is told; a few
                    // bad macroblocks are concealed, and only counted)
                    s.failed = st.mbs_correctly_decoded == 0;
                    d.debug("decode {d} (surface {d}): error_status {x}, macroblocks {d} in error / {d} right, slice header error {x}; {d} errors so far", .{ s.serial, si, st.error_status, st.mbs_in_error, st.mbs_correctly_decoded, st.slice_header_error_code, d.errors });
                }
            }
            d.detileSurface(s);
            return if (s.failed) va.ERROR_DECODING_ERROR else va.SUCCESS;
        }

        fn detileSurface(d: *Self, s: *Surface) void {
            const lin = s.linear_layout;
            const out = s.linear.bytes();
            const src = s.tiled.bytes();
            tiling.detile(out, lin.pitch, src, s.layout.luma, d.opts.gob.luma(), s.width, s.height);
            const cw = 2 * ((s.width + 1) / 2);
            const ch = (s.height + 1) / 2;
            tiling.detile(out[lin.uv_offset..], lin.pitch, src[@intCast(s.layout.chroma_offset)..], s.layout.chroma, d.opts.gob.chroma(), cw, ch);
        }

        pub fn syncSurface(d: *Self, surface: u32, timeout_ns: i64) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const now = d.node.sys.nowNs();
            const deadline = if (timeout_ns >= std.math.maxInt(i64) - now) std.math.maxInt(i64) else now + timeout_ns;
            return d.complete(si, deadline);
        }

        pub fn querySurfaceStatus(d: *Self, surface: u32, status: *u32) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (d.surfaces[si].pending) {
                const st = d.complete(si, 0);
                if (st == va.ERROR_TIMEDOUT) {
                    status.* = va.SURFACE_RENDERING;
                    return va.SUCCESS;
                }
            }
            status.* = va.SURFACE_READY;
            return va.SUCCESS;
        }

        /// Picture slots: those of surfaces no longer the target or a
        /// reference are let go; the target and each reference keep theirs
        /// or take the lowest free one. The target's slot, or null.
        fn assignSlots(c: *Context, target: u16, refs: *[16]u16) ?u5 {
            for (&c.slot_surface) |*o| {
                if (o.* == NONE) continue;
                if (o.* == target or std.mem.indexOfScalar(u16, refs, o.*) != null) continue;
                o.* = NONE;
            }
            const t = slotOf(c, target) orelse takeSlot(c, target) orelse return null;
            for (refs) |*r| {
                if (r.* == NONE) continue;
                // (no slot left: that reference is left out)
                if (slotOf(c, r.*) == null and takeSlot(c, r.*) == null) r.* = NONE;
            }
            return t;
        }

        fn slotOf(c: *const Context, si: u16) ?u5 {
            const k = std.mem.indexOfScalar(u16, &c.slot_surface, si) orelse return null;
            return @intCast(k);
        }

        fn takeSlot(c: *Context, si: u16) ?u5 {
            const k = std.mem.indexOfScalar(u16, &c.slot_surface, NONE) orelse return null;
            c.slot_surface[k] = si;
            return @intCast(k);
        }

        // ── Export ──────────────────────────────────────────────────────

        pub fn exportSurfaceHandle(d: *Self, surface: u32, mem_type: u32, flags: u32, desc: *va.DrmPrimeDescriptor) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (mem_type != va.MEM_TYPE_DRM_PRIME_2) return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
            const st = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            const s = &d.surfaces[si];
            if (s.dmabuf < 0) {
                const fd = d.node.exportFd(s.linear);
                if (fd < 0) {
                    d.say("the surface's dma-buf was refused ({d})", .{fd});
                    return va.ERROR_OPERATION_FAILED;
                }
                s.dmabuf = @intCast(fd);
            }
            const fd = d.node.sys.dup(s.dmabuf);
            if (fd < 0) return va.ERROR_OPERATION_FAILED;
            const lin = s.linear_layout;
            desc.* = std.mem.zeroes(va.DrmPrimeDescriptor);
            desc.fourcc = va.FOURCC_NV12;
            desc.width = s.width;
            desc.height = s.height;
            desc.num_objects = 1;
            desc.objects[0] = .{ .fd = @intCast(fd), .size = @intCast(s.linear.len), .drm_format_modifier = va.DRM_FORMAT_MOD_LINEAR };
            if (flags & va.EXPORT_SURFACE_COMPOSED_LAYERS != 0) {
                desc.num_layers = 1;
                desc.layers[0].drm_format = va.DRM_FORMAT_NV12;
                desc.layers[0].num_planes = 2;
                desc.layers[0].offset = .{ 0, lin.uv_offset, 0, 0 };
                desc.layers[0].pitch = .{ lin.pitch, lin.pitch, 0, 0 };
            } else {
                desc.num_layers = 2;
                desc.layers[0].drm_format = va.DRM_FORMAT_R8;
                desc.layers[0].num_planes = 1;
                desc.layers[0].pitch[0] = lin.pitch;
                desc.layers[1].drm_format = va.DRM_FORMAT_GR88;
                desc.layers[1].num_planes = 1;
                desc.layers[1].offset[0] = lin.uv_offset;
                desc.layers[1].pitch[0] = lin.pitch;
            }
            return va.SUCCESS;
        }

        // ── Images ──────────────────────────────────────────────────────

        pub fn queryImageFormats(_: *Self, list: [*]va.ImageFormat, n: *i32) va.Status {
            list[0] = va.NV12_FORMAT;
            n.* = 1;
            return va.SUCCESS;
        }

        fn newImage(d: *Self) ?u16 {
            for (d.images, 0..) |im, i| {
                if (!im.used) return @intCast(i);
            }
            return null;
        }

        fn describe(id: u32, buf: u32, width: u32, height: u32, lin: tiling.Linear) va.Image {
            var im = std.mem.zeroes(va.Image);
            im.image_id = id;
            im.format = va.NV12_FORMAT;
            im.buf = buf;
            im.width = @intCast(width);
            im.height = @intCast(height);
            im.data_size = lin.bytes;
            im.num_planes = 2;
            im.pitches = .{ lin.pitch, lin.pitch, 0 };
            im.offsets = .{ 0, lin.uv_offset, 0 };
            return im;
        }

        pub fn createImage(d: *Self, format: *const va.ImageFormat, width: u32, height: u32, out: *va.Image) va.Status {
            if (format.fourcc != va.FOURCC_NV12) return va.ERROR_INVALID_IMAGE_FORMAT;
            if (width == 0 or height == 0 or width > MAX_SIZE or height > MAX_SIZE) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            const ii = d.newImage() orelse return va.ERROR_ALLOCATION_FAILED;
            const lin = tiling.Linear.of(width, height);
            var bid: u32 = 0;
            const st = d.createBuffer(va.IMAGE_BUFFER, lin.bytes, 1, null, &bid);
            if (st != va.SUCCESS) return st;
            const id = IMAGE_BASE + @as(u32, ii);
            d.images[ii] = .{ .used = true, .image = describe(id, bid, width, height, lin), .buffer = @intCast(bid - BUFFER_BASE) };
            out.* = d.images[ii].image;
            return va.SUCCESS;
        }

        pub fn deriveImage(d: *Self, surface: u32, out: *va.Image) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const ii = d.newImage() orelse return va.ERROR_ALLOCATION_FAILED;
            const bi = for (d.buffers, 0..) |b, i| {
                if (!b.used) break i;
            } else return va.ERROR_ALLOCATION_FAILED;
            const s = &d.surfaces[si];
            d.buffers[bi] = .{ .used = true, .type = va.IMAGE_BUFFER, .size = s.linear_layout.bytes, .count = 1, .surface = si };
            const id = IMAGE_BASE + @as(u32, ii);
            const bid = BUFFER_BASE + @as(u32, @intCast(bi));
            d.images[ii] = .{ .used = true, .image = describe(id, bid, s.width, s.height, s.linear_layout), .surface = si, .buffer = @intCast(bi) };
            out.* = d.images[ii].image;
            return va.SUCCESS;
        }

        pub fn destroyImage(d: *Self, id: u32) va.Status {
            if (id < IMAGE_BASE or id - IMAGE_BASE >= MAX_IMAGES or !d.images[id - IMAGE_BASE].used) return va.ERROR_INVALID_IMAGE;
            const im = &d.images[id - IMAGE_BASE];
            if (im.buffer != NONE and d.buffers[im.buffer].used) d.dropBuffer(im.buffer);
            im.* = .{};
            return va.SUCCESS;
        }

        /// The rectangle (x, y, width, height) of surface's picture into
        /// image (at its origin).
        pub fn getImage(d: *Self, surface: u32, x: i32, y: i32, width: u32, height: u32, image: u32) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (image < IMAGE_BASE or image - IMAGE_BASE >= MAX_IMAGES or !d.images[image - IMAGE_BASE].used) return va.ERROR_INVALID_IMAGE;
            const im = d.images[image - IMAGE_BASE];
            const st = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            if (im.surface == si) return va.SUCCESS;
            const s = &d.surfaces[si];
            if (x < 0 or y < 0) return va.ERROR_INVALID_PARAMETER;
            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            if (ux + width > s.width or uy + height > s.height or width > im.image.width or height > im.image.height) return va.ERROR_INVALID_PARAMETER;
            const dst = if (im.surface != NONE) d.surfaces[im.surface].linear.bytes() else d.storage(im.buffer);
            const src = s.linear.bytes();
            const lin = s.linear_layout;
            const ip = im.image.pitches;
            const io = im.image.offsets;
            for (0..height) |r| {
                @memcpy(dst[io[0] + r * ip[0] ..][0..width], src[(uy + r) * lin.pitch + ux ..][0..width]);
            }
            const cx = ux & ~@as(u32, 1);
            const cw = 2 * ((width + 1) / 2);
            for (0..(height + 1) / 2) |r| {
                const sy = uy / 2 + r;
                if (sy >= (s.height + 1) / 2) break;
                const n = @min(cw, 2 * ((s.width + 1) / 2) - cx);
                @memcpy(dst[io[1] + r * ip[1] ..][0..n], src[lin.uv_offset + sy * lin.pitch + cx ..][0..n]);
            }
            return va.SUCCESS;
        }
    };
}

pub fn intAttrib(kind: u32, flags: u32, v: u32) va.SurfaceAttrib {
    return .{ .type = kind, .flags = flags, .value = .{ .type = va.GENERIC_INTEGER, .value = .{ .i = @bitCast(v) } } };
}

fn sliceParam(params: []const u8, size: u32, k: usize) va.SliceParameterBufferH264 {
    return std.mem.bytesToValue(va.SliceParameterBufferH264, params[k * size ..][0..@sizeOf(va.SliceParameterBufferH264)]);
}

/// Frame slot `f` of a context's work buffer, as a codec module sees it.
fn frameSlot(c: *Context, f: usize) codec.Slot {
    const frame = c.frameBytes(f);
    const base = c.work.va + f * FRAME_BYTES;
    return .{
        .push = words(frame.ptr, PUSH_OFF, PUSH_DWORDS_MAX),
        .pic = frame[PIC_OFF..][0..codec.PIC_BYTES],
        .pic_va = base + PIC_OFF,
        .aux = frame[AUX_OFF..][0..codec.AUX_BYTES],
        .aux_va = base + AUX_OFF,
        .status_va = base + STATUS_OFF,
        .stream = frame[STREAM_OFF..],
        .stream_va = base + STREAM_OFF,
    };
}

comptime {
    std.debug.assert(PIC_OFF + codec.PIC_BYTES <= SLICES_OFF);
    std.debug.assert(STATUS_OFF + 0x100 <= AUX_OFF);
    std.debug.assert(@sizeOf(nvdec.H264Pic) <= codec.PIC_BYTES);
    std.debug.assert(hevc.MAX_PIC_BYTES <= codec.PIC_BYTES and hevc.MAX_AUX_BYTES <= codec.AUX_BYTES);
    std.debug.assert(av1.MAX_PIC_BYTES <= codec.PIC_BYTES and av1.MAX_AUX_BYTES <= codec.AUX_BYTES);
    std.debug.assert(nvdec.PUSH_DWORDS <= PUSH_DWORDS_MAX and hevc.PUSH_DWORDS <= PUSH_DWORDS_MAX and av1.PUSH_DWORDS <= PUSH_DWORDS_MAX);
}

/// `n` dwords at byte `off` of mapped GPU memory.
fn words(base: [*]u8, off: usize, n: usize) []u32 {
    const p: [*]u32 = @ptrCast(@alignCast(base + off));
    return p[0..n];
}
