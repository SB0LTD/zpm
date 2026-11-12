//! @zpm/va driver — Galaxy's VA-API driver for the RTX's video decoder
//! (NVDEC, NVCFB0 on GB206): the state behind each of libva's entry
//! points, over Galaxy's render node (node.sig). libgalaxy_va.sig puts it
//! behind libva's C table. H.264 is the driver's own (nvdec.sig); HEVC,
//! VP9 and AV1 are codec modules (codec.sig says what they are given).
//!
//! What a decode is here:
//!
//! - **Surfaces** (MAX_SURFACES) are NV12 or P010 pictures (8- or 10-bit
//!   streams), the decode target in VRAM, block linear as NVDEC writes it
//!   (tiling.Nv12). That is what the app gets: vaExportSurfaceHandle
//!   hands out that buffer's dma-buf as it is, each plane with NVIDIA's
//!   block-linear modifier (tiling.modifierOf), and the GL driver samples
//!   the GOBs where they are (zero copy: no detile, no copy, the CPU never
//!   touches a frame on its way to the screen). A pitch-linear copy in
//!   system memory (tiling.Linear) is made only for a CPU reader or
//!   writer (vaGetImage, a derived image, vaPutImage, an encode's input),
//!   converted on the GPU (convert.sig, gpu_convert.sig) when one asks,
//!   and only when the other copy has changed since.
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
//!   fence (G_VWAIT) and reads the decoder's status (errors counted; said
//!   on stderr with GALAXY_VA_DEBUG). Nothing is copied.
//!
//! VA buffers live in a fixed pool reserved at init: SMALL_BUFFERS of 64
//! KiB (parameters) and LARGE_BUFFERS of 16 MiB (slice data, images).
//!
//! What an encode is here (the RTX's NVENC, encode.sig and nvenc.sig):
//!
//! - **Configs** of the EncSlice entrypoint (H.264 Constrained Baseline,
//!   Main, High; HEVC Main), with a rate control mode (CQP, CBR, VBR) and
//!   the packed headers the app will send (sequence, misc, raw).
//! - **Contexts** have a work buffer of FRAMES frame slots (a pushbuffer,
//!   the picture setup) and the engine's scratch (history, co-located
//!   motion, rate control state), and the codec's encode.State.
//! - **Coded buffers** (VAEncCodedBufferType) are the kernel's buffers
//!   (MAX_CODED of them): the segment vaMapBuffer returns, the engine's
//!   status, then the stream (encode.sig's layout); mapping one waits for
//!   its encode (G_EWAIT) and fills the segment.
//! - **BeginPicture** takes the input surface and the next frame slot;
//!   **RenderPicture** hands each buffer to encode.take; **EndPicture**
//!   has the engine read the input's block-linear planes where they are
//!   (a decode into it waited for; an app's CPU write into its linear copy
//!   converted back by the converter; an imported block-linear dma-buf
//!   read in place, a linear or RGB one converted on the GPU first:
//!   enc_import.sig, enc_rgb.sig), writes the headers, the setup and
//!   the pushbuffer, and submits it on the encoder channel (G_ESUBMIT).
//!   The reconstructed and reference pictures live in their surfaces'
//!   block-linear buffers, in the engine's own layout.
//! - **SyncSurface** on the input, or **SyncBuffer** on the coded buffer,
//!   waits for the encode.
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
const vp9 = @import("vp9.sig");
const vp8 = @import("vp8.sig");
const ve = @import("vaapi_enc.sig");
const encode = @import("encode.sig");
const nvenc = @import("nvenc.sig");
const convert = @import("convert.sig");
const enc_import = @import("enc_import.sig");
const enc_vpx = @import("enc_vpx.sig");
const enc_vp8 = @import("enc_vp8.sig");
const enc_vp9 = @import("enc_vp9.sig");

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

pub const VENDOR = "Galaxy VA-API driver for the RTX's NVDEC (H.264, HEVC, VP8, VP9, AV1), NVENC (H.264, HEVC, AV1) and its own VP8 and VP9 encoders on the GPU, zpm";

/// Coded buffers at once (the kernel's buffers).
pub const MAX_CODED = 16;
/// An encode frame slot: the pushbuffer, then the picture setup.
pub const ENC_FRAME_BYTES: usize = 0x2000;
pub const ENC_PUSH_OFF: usize = 0;
pub const ENC_SETUP_OFF: usize = 0x800;

// Each kind of object's ids: base + index.
pub const CONFIG_BASE: u32 = 0x100;
pub const CONTEXT_BASE: u32 = 0x200;
pub const SURFACE_BASE: u32 = 0x400;
pub const BUFFER_BASE: u32 = 0x1000;
pub const IMAGE_BASE: u32 = 0x2000;
const NONE: u16 = 0xffff;

/// The decode profiles (Firefox's probe, vaapitest, finds each by name:
/// HEVCMain10 and VP9Profile2 are what let it hand 10-bit streams here;
/// AV1Profile0 is Main, 8 and 10 bits).
pub const PROFILES = [_]va.Profile{ va.PROFILE_H264_CONSTRAINED_BASELINE, va.PROFILE_H264_MAIN, va.PROFILE_H264_HIGH, hevc.PROFILE, va.PROFILE_HEVC_MAIN10, vp8.PROFILE, vp9.PROFILE, va.PROFILE_VP9_PROFILE_2, av1.PROFILE };

pub fn supported(profile: va.Profile) bool {
    return std.mem.indexOfScalar(va.Profile, &PROFILES, profile) != null;
}

pub const Codec = enum { h264, hevc, vp8, vp9, av1 };

pub fn codecOf(profile: va.Profile) Codec {
    return switch (profile) {
        hevc.PROFILE, va.PROFILE_HEVC_MAIN10 => .hevc,
        vp8.PROFILE => .vp8,
        vp9.PROFILE, va.PROFILE_VP9_PROFILE_2 => .vp9,
        av1.PROFILE => .av1,
        else => .h264,
    };
}

/// The render-target formats a decode profile gives: 8-bit 4:2:0 (NV12)
/// and, for the 10-bit profiles, 10-bit 4:2:0 (P010). HEVC Main10 and VP9
/// profile 2 streams may be 8-bit too (their decoders take either).
pub fn rtFormats(profile: va.Profile) u32 {
    return switch (profile) {
        va.PROFILE_HEVC_MAIN10, va.PROFILE_VP9_PROFILE_2, av1.PROFILE => va.RT_FORMAT_YUV420 | va.RT_FORMAT_YUV420_10,
        else => va.RT_FORMAT_YUV420,
    };
}

/// A render-target format's bytes a sample (null: not one had here).
pub fn sampleBytesOf(rt_format: u32) ?u8 {
    return switch (rt_format) {
        va.RT_FORMAT_YUV420 => 1,
        va.RT_FORMAT_YUV420_10 => 2,
        else => null,
    };
}

pub fn fourccOf(sample_bytes: u8) u32 {
    return if (sample_bytes == 2) va.FOURCC_P010 else va.FOURCC_NV12;
}

pub const Options = struct {
    /// which GPU generation's GOB layouts the decoder writes (tiling.sig)
    gob: tiling.Gob = .blackwell,
    /// GALAXY_VA_DEBUG: decode errors and the driver's doings on stderr
    debug: bool = false,
    /// a do-nothing submission at init, so a GPU without a decoder fails
    /// vaInitialize (and Firefox's probe) instead of the first frame
    probe: bool = true,
    /// Blackwell's additions to HEVC, VP9 and AV1 (codec.Blackwell; the
    /// modules' State.blackwell): GALAXY_VA_BLACKWELL for all three,
    /// GALAXY_VA_{HEVC,VP9,AV1}_BLACKWELL for one
    hevc_blackwell: codec.Blackwell = .full,
    vp9_blackwell: codec.Blackwell = .full,
    av1_blackwell: codec.Blackwell = .full,
    /// GALAXY_VA_CONTROL: HEVC's, VP9's and AV1's SET_CONTROL_PARAMS word
    /// (codec.Control; H.264's stays NVK's)
    control: codec.Control = .nvk,
    /// GALAXY_VA_VP9_INTRA_TOP=0: VP9 without the intra-top buffer
    vp9_intra_top: bool = true,
    /// GALAXY_VA_VP9_STREAM_LEN: what VP9's stream_len counts (vp9.StreamLen)
    vp9_stream_len: vp9.StreamLen = .frame,
    /// GALAXY_VA_ENCODE=0: no encode entrypoints
    encode: bool = true,
    /// GALAXY_VA_NVENC_MAGIC: the encoder setup's magic word (nvenc.MAGIC)
    nvenc_magic: ?u32 = null,
    /// GALAXY_VA_NVENC_RC=firmware: the encoder firmware's own rate
    /// control for CBR and VBR (enc_rc.sig), not the driver's
    nvenc_rc_firmware: bool = false,
    /// GALAXY_VA_VPX_ENCODE=0: no VP8 or VP9 encode entrypoints
    vpx_encode: bool = true,
    /// GALAXY_VA_VPX_GPU=0: VP8 and VP9 encode on the CPU, not the RTX
    vpx_gpu: bool = true,
};

const Config = struct {
    used: bool = false,
    profile: va.Profile = 0,
    entrypoint: va.Entrypoint = va.ENTRYPOINT_VLD,
    /// encode: the rate control mode and the app's packed headers
    rc_mode: u32 = ve.RC_CQP,
    packed_headers: u32 = 0,
};

/// A coded buffer: the kernel's buffer, and the encode writing it.
const Coded = struct {
    used: bool = false,
    buf: Buf = .{},
    /// an encode into it not yet seen done
    pending: bool = false,
    fence: u32 = 0,
    ctx: u8 = 0,
    header_bytes: u32 = 0,
    /// what the picture was (encode.finish's rate control and filler)
    done: encode.Done = .{},
};

const Surface = struct {
    used: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    layout: tiling.Nv12 = undefined,
    linear_layout: tiling.Linear = undefined,
    /// the decode target (block linear, VRAM), and its pitch-linear copy
    /// (system memory: made the first time a CPU reader or writer asks)
    tiled: Buf = .{},
    linear: Buf = .{},
    /// the decode target's dma-buf (made at the first export or GPU
    /// conversion), and the linear copy's (a GPU conversion's)
    dmabuf: i32 = -1,
    linear_fd: i32 = -1,
    /// the linear copy is older than the picture (a decode since); the
    /// picture is older than the linear copy (a CPU write since)
    linear_stale: bool = true,
    tiled_stale: bool = false,
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
    /// an encode reading its block-linear copy, not yet seen done
    enc_pending: bool = false,
    enc_fence: u32 = 0,
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
    vp8: vp8.State = undefined,
    vp9: vp9.State = undefined,
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
    // ── encode contexts ──
    encoding: bool = false,
    enc: encode.State = undefined,
    enc_scratch: encode.ScratchSizes = undefined,
    /// VP8 and VP9 (enc_vpx.sig): the state, the packer's scratch, the
    /// CPU engine's memory (made when the CPU encodes), which engine has
    /// the frame store
    vpx_on: bool = false,
    vpx: enc_vpx.State = undefined,
    vpx_work: Buf = .{},
    vpx_cpu: Buf = .{},
    vpx_engine: enum { none, gpu, cpu } = .none,

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
    /// a coded buffer's: its entry in the coded table, not the pool
    coded: u8 = NO_CODED,
    mapped: bool = false,
};

const NO_CODED: u8 = 0xff;

const ImageEntry = struct {
    used: bool = false,
    image: va.Image = undefined,
    /// derived from this surface (NONE: its own buffer)
    surface: u16 = NONE,
    buffer: u16 = NONE,
};

/// The driver over `Sys`'s node, CPU readers' pictures converted on the
/// CPU (tests; convert.Cpu).
pub fn Driver(comptime Sys: type) type {
    return DriverWith(Sys, convert.Cpu);
}

/// The driver, CPU readers' pictures converted by `Conv` (convert.sig: the
/// shared library's runs on the GPU).
pub fn DriverWith(comptime Sys: type, comptime Conv: type) type {
    return struct {
        const Self = @This();

        node: node.Node(Sys),
        own_fd: bool = false,
        opts: Options = .{},
        conv: Conv = .{},
        /// conversions made, by where (the tests and GALAXY_VA_DEBUG read them)
        conversions: [3]u32 = .{ 0, 0, 0 },
        /// vaExportSurfaceHandle calls answered
        exports: u32 = 0,
        pool: ?[*]u8 = null,
        configs: [MAX_CONFIGS]Config = [_]Config{.{}} ** MAX_CONFIGS,
        surfaces: [MAX_SURFACES]Surface = [_]Surface{.{}} ** MAX_SURFACES,
        contexts: [MAX_CONTEXTS]Context = [_]Context{.{}} ** MAX_CONTEXTS,
        buffers: [MAX_BUFFERS]Buffer = [_]Buffer{.{}} ** MAX_BUFFERS,
        images: [MAX_IMAGES]ImageEntry = [_]ImageEntry{.{}} ** MAX_IMAGES,
        coded: [MAX_CODED]Coded = [_]Coded{.{}} ** MAX_CODED,
        /// the encoder answered the init's probe (or no probe was made)
        has_encoder: bool = true,
        /// surfaces made over an app's dma-bufs (enc_import.sig), by index
        imports: [MAX_SURFACES]enc_import.Imported = [_]enc_import.Imported{.{}} ** MAX_SURFACES,
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
            d.has_encoder = d.opts.encode;
            if (d.opts.probe) {
                const st = d.probe();
                if (st != va.SUCCESS) return st;
                if (d.opts.encode) d.has_encoder = d.probeEncoder();
            }
            return va.SUCCESS;
        }

        /// SET_OBJECT of the encoder's class and a NOP on the encoder
        /// channel, waited for: whether encode entrypoints are offered.
        fn probeEncoder(d: *Self) bool {
            var b = d.node.alloc(node.UNIT, 0) orelse return false;
            defer d.node.free(&b);
            const w = words(b.cpu, 0, 4);
            w[0] = nvenc.header(0, nvenc.SET_OBJECT, 1);
            w[1] = nvenc.CLASS | nvenc.SET_OBJECT_ENGINE_SW;
            w[2] = nvenc.header(0, nvenc.NOP, 1);
            w[3] = 0;
            const f = d.node.esubmit(b, 0, 4) catch |e| {
                d.say("the RTX's video encoder is not there ({s}): decode only", .{@errorName(e)});
                return false;
            };
            switch (d.node.ewait(f, d.node.sys.nowNs() + SYNC_NS)) {
                .done => {
                    d.debug("the video encoder answered (fence {d})", .{f});
                    return true;
                },
                .timeout => d.say("the video encoder did not answer a NOP: decode only", .{}),
                .lost => d.say("the GPU was lost answering the video encoder's NOP", .{}),
            }
            return false;
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
            d.conv.deinit();
            for (&d.coded) |*c| {
                if (c.used) d.node.free(&c.buf);
                c.* = .{};
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

        /// Whether `profile` encodes here (and the encoder is there).
        pub fn encodes(d: *const Self, profile: va.Profile) bool {
            // (VP8 and VP9: the kernels' encoder, not NVENC's)
            if (enc_vpx.supported(profile) != null) return d.opts.encode and d.opts.vpx_encode;
            return d.has_encoder and encode.supported(profile) != null;
        }

        pub fn queryConfigEntrypoints(d: *Self, profile: va.Profile, list: [*]va.Entrypoint, n: *i32) va.Status {
            if (!supported(profile)) {
                n.* = 0;
                return va.ERROR_UNSUPPORTED_PROFILE;
            }
            list[0] = va.ENTRYPOINT_VLD;
            n.* = 1;
            if (d.encodes(profile)) {
                list[1] = ve.ENTRYPOINT_ENC_SLICE;
                n.* = 2;
            }
            return va.SUCCESS;
        }

        pub fn getConfigAttributes(d: *Self, profile: va.Profile, ep: va.Entrypoint, attribs: []va.ConfigAttrib) va.Status {
            if (!supported(profile)) return va.ERROR_UNSUPPORTED_PROFILE;
            if (ep == ve.ENTRYPOINT_ENC_SLICE and d.encodes(profile)) {
                for (attribs) |*a| a.value = encodeAttribute(profile, a.type);
                return va.SUCCESS;
            }
            if (ep != va.ENTRYPOINT_VLD) return va.ERROR_UNSUPPORTED_ENTRYPOINT;
            for (attribs) |*a| {
                a.value = switch (a.type) {
                    va.ATTRIB_RT_FORMAT => rtFormats(profile),
                    va.ATTRIB_DEC_SLICE_MODE => va.DEC_SLICE_MODE_NORMAL,
                    va.ATTRIB_MAX_PICTURE_WIDTH, va.ATTRIB_MAX_PICTURE_HEIGHT => MAX_SIZE,
                    else => va.ATTRIB_NOT_SUPPORTED,
                };
            }
            return va.SUCCESS;
        }

        pub fn createConfig(d: *Self, profile: va.Profile, ep: va.Entrypoint, attribs: []const va.ConfigAttrib, out: *u32) va.Status {
            if (!supported(profile)) return va.ERROR_UNSUPPORTED_PROFILE;
            const enc = ep == ve.ENTRYPOINT_ENC_SLICE and d.encodes(profile);
            if (ep != va.ENTRYPOINT_VLD and !enc) return va.ERROR_UNSUPPORTED_ENTRYPOINT;
            var rc_mode: u32 = ve.RC_CQP;
            var packed_headers: u32 = 0;
            const formats = if (enc) va.RT_FORMAT_YUV420 else rtFormats(profile);
            for (attribs) |a| {
                if (a.type == va.ATTRIB_RT_FORMAT and a.value & formats == 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
                if (!enc) continue;
                switch (a.type) {
                    ve.ATTRIB_RATE_CONTROL => {
                        // (one mode, one this driver has)
                        if (a.value & encode.RC_MODES == 0 or @popCount(a.value) != 1) return va.ERROR_INVALID_CONFIG;
                        rc_mode = a.value;
                    },
                    ve.ATTRIB_ENC_PACKED_HEADERS => {
                        const allowed = if (enc_vpx.supported(profile) != null) enc_vpx.PACKED_HEADERS else encode.packedHeaders(encode.supported(profile) orelse return va.ERROR_UNSUPPORTED_PROFILE);
                        if (a.value & ~allowed != 0) return va.ERROR_INVALID_CONFIG;
                        packed_headers = a.value;
                    },
                    else => {},
                }
            }
            for (&d.configs, 0..) |*c, i| {
                if (c.used) continue;
                c.* = .{ .used = true, .profile = profile, .entrypoint = ep, .rc_mode = rc_mode, .packed_headers = packed_headers };
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
            ep.* = c.entrypoint;
            n.* = 1;
            if (attribs) |a| a[0] = .{ .type = va.ATTRIB_RT_FORMAT, .value = if (c.entrypoint == ve.ENTRYPOINT_ENC_SLICE) va.RT_FORMAT_YUV420 else rtFormats(c.profile) };
            if (c.entrypoint == ve.ENTRYPOINT_ENC_SLICE) {
                if (attribs) |a| {
                    a[1] = .{ .type = ve.ATTRIB_RATE_CONTROL, .value = c.rc_mode };
                    a[2] = .{ .type = ve.ATTRIB_ENC_PACKED_HEADERS, .value = c.packed_headers };
                }
                n.* = 3;
            }
            return va.SUCCESS;
        }

        fn configOf(d: *Self, id: u32) ?*Config {
            if (id < CONFIG_BASE or id - CONFIG_BASE >= MAX_CONFIGS) return null;
            const c = &d.configs[id - CONFIG_BASE];
            return if (c.used) c else null;
        }

        // ── Surfaces ────────────────────────────────────────────────────

        const SURFACE_ATTRIBS_MAX = 7;

        /// What a config's surfaces may be: the pixel formats its profile
        /// decodes to (FFmpeg picks the one its stream's software format
        /// matches: P010 for a 10-bit one), sizes, memory types.
        pub fn querySurfaceAttributes(d: *Self, config: u32, list: ?[*]va.SurfaceAttrib, n: *u32) va.Status {
            const c = d.configOf(config) orelse return va.ERROR_INVALID_CONFIG;
            const both = va.SURFACE_ATTRIB_GETTABLE | va.SURFACE_ATTRIB_SETTABLE;
            var all: [SURFACE_ATTRIBS_MAX]va.SurfaceAttrib = undefined;
            var k: u32 = 0;
            const formats = if (c.entrypoint == ve.ENTRYPOINT_ENC_SLICE) va.RT_FORMAT_YUV420 else rtFormats(c.profile);
            if (formats & va.RT_FORMAT_YUV420 != 0) {
                all[k] = intAttrib(va.SURFACE_ATTRIB_PIXEL_FORMAT, both, va.FOURCC_NV12);
                k += 1;
            }
            if (formats & va.RT_FORMAT_YUV420_10 != 0) {
                all[k] = intAttrib(va.SURFACE_ATTRIB_PIXEL_FORMAT, both, va.FOURCC_P010);
                k += 1;
            }
            for ([_]va.SurfaceAttrib{
                intAttrib(va.SURFACE_ATTRIB_MIN_WIDTH, va.SURFACE_ATTRIB_GETTABLE, MIN_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MAX_WIDTH, va.SURFACE_ATTRIB_GETTABLE, MAX_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MIN_HEIGHT, va.SURFACE_ATTRIB_GETTABLE, MIN_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MAX_HEIGHT, va.SURFACE_ATTRIB_GETTABLE, MAX_SIZE),
                intAttrib(va.SURFACE_ATTRIB_MEMORY_TYPE, both, va.MEM_TYPE_VA | va.MEM_TYPE_DRM_PRIME_2),
            }) |a| {
                all[k] = a;
                k += 1;
            }
            const out = list orelse {
                n.* = k;
                return va.SUCCESS;
            };
            if (n.* < k) {
                n.* = k;
                return va.ERROR_MAX_NUM_EXCEEDED;
            }
            for (all[0..k], 0..) |a, i| out[i] = a;
            n.* = k;
            return va.SUCCESS;
        }

        pub fn createSurfaces(d: *Self, format: u32, width: u32, height: u32, out: []u32, attribs: []const va.SurfaceAttrib) va.Status {
            const sample_bytes = sampleBytesOf(format) orelse return va.ERROR_UNSUPPORTED_RT_FORMAT;
            if (width == 0 or height == 0) return va.ERROR_INVALID_PARAMETER;
            if (width > MAX_SIZE or height > MAX_SIZE) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            var mem_type: u32 = 0;
            var external: ?*anyopaque = null;
            for (attribs) |a| {
                switch (a.type) {
                    // (the pixel format is the render-target format's)
                    va.SURFACE_ATTRIB_PIXEL_FORMAT => if (@as(u32, @bitCast(a.value.value.i)) != fourccOf(sample_bytes)) return va.ERROR_UNSUPPORTED_RT_FORMAT,
                    va.SURFACE_ATTRIB_MEMORY_TYPE => {
                        const t: u32 = @bitCast(a.value.value.i);
                        if (t != 0 and t != va.MEM_TYPE_VA and t != va.MEM_TYPE_DRM_PRIME and t != va.MEM_TYPE_DRM_PRIME_2) return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
                        mem_type = t;
                    },
                    // (an app's dma-bufs: importSurfaces)
                    va.SURFACE_ATTRIB_EXTERNAL_BUFFER_DESCRIPTOR => external = a.value.value.p,
                    else => {},
                }
            }
            if (external) |p| {
                if (sample_bytes != 1) return va.ERROR_UNSUPPORTED_RT_FORMAT;
                return d.importSurfaces(mem_type, p, width, height, out);
            }
            for (out, 0..) |*id, k| {
                const i = d.makeSurface(width, height, sample_bytes) orelse {
                    for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                    return va.ERROR_ALLOCATION_FAILED;
                };
                id.* = SURFACE_BASE + i;
            }
            d.debug("{d} {s} surfaces of {d}x{d} in VRAM", .{ out.len, if (sample_bytes == 2) "P010" else "NV12", width, height });
            return va.SUCCESS;
        }

        /// A surface: its decode target in VRAM (black until decoded: Y
        /// 16, UV 128, at the top of P010's two bytes; every byte of a
        /// plane the same pattern, whatever the swizzle). Its linear copy
        /// waits for a CPU reader.
        fn makeSurface(d: *Self, width: u32, height: u32, sample_bytes: u8) ?u16 {
            const i = for (d.surfaces, 0..) |s, i| {
                if (!s.used) break i;
            } else return null;
            const layout = tiling.Nv12.ofDepth(width, std.mem.alignForward(u32, height, SURFACE_ROW_ALIGN), sample_bytes);
            const lin = tiling.Linear.ofDepth(width, height, sample_bytes);
            const tiled = d.node.alloc(@intCast(layout.bytes), node.G_VRAM) orelse return null;
            const at: usize = @intCast(layout.chroma_offset);
            const b = tiled.bytes();
            if (sample_bytes == 1) {
                @memset(b[0..at], 16);
                @memset(b[at..@intCast(layout.bytes)], 128);
            } else {
                const y: []align(2) u8 = @alignCast(b[0..at]);
                const uv: []align(2) u8 = @alignCast(b[at..@intCast(layout.bytes)]);
                @memset(std.mem.bytesAsSlice(u16, y), 16 << 8);
                @memset(std.mem.bytesAsSlice(u16, uv), 128 << 8);
            }
            d.surfaces[i] = .{ .used = true, .width = width, .height = height, .layout = layout, .linear_layout = lin, .tiled = tiled };
            return @intCast(i);
        }

        // ── A surface's two copies ──────────────────────────────────────

        /// The surface's pitch-linear copy, made if it has none (stale:
        /// the next sync converts into it).
        fn ensureLinear(d: *Self, s: *Surface) bool {
            if (s.linear.handle != 0) return true;
            s.linear = d.node.alloc(s.linear_layout.bytes, 0) orelse return false;
            s.linear_stale = true;
            return true;
        }

        /// The surface's linear copy up to date (made and converted from
        /// the picture if a decode came since), for a CPU reader. The
        /// decode is waited for first.
        fn syncLinear(d: *Self, si: u16) va.Status {
            const st = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            const s = &d.surfaces[si];
            if (!d.ensureLinear(s)) return va.ERROR_ALLOCATION_FAILED;
            if (!s.linear_stale) return st;
            if (!d.convertSurface(s, .to_linear)) return va.ERROR_OPERATION_FAILED;
            s.linear_stale = false;
            return st;
        }

        /// The surface's block-linear picture up to date (a CPU write into
        /// its linear copy since: converted back), for the decoder, an
        /// export or the encoder.
        fn syncTiled(d: *Self, si: u16) va.Status {
            const s = &d.surfaces[si];
            if (!s.tiled_stale) return va.SUCCESS;
            if (!d.convertSurface(s, .to_tiled)) return va.ERROR_OPERATION_FAILED;
            s.tiled_stale = false;
            return va.SUCCESS;
        }

        fn convertSurface(d: *Self, s: *Surface, dir: convert.Direction) bool {
            var job = convert.Job{
                .tiled = s.tiled,
                .layout = s.layout,
                .linear = s.linear,
                .lin = s.linear_layout,
                .width = s.width,
                .height = s.height,
                .gob = d.opts.gob,
                .dir = dir,
            };
            if (Conv.wants_fds) {
                job.tiled_fd = d.surfaceFd(s) orelse return false;
                if (s.linear_fd < 0) {
                    const fd = d.node.exportFd(s.linear);
                    if (fd < 0) return false;
                    s.linear_fd = @intCast(fd);
                }
                job.linear_fd = s.linear_fd;
            }
            const done = d.conv.run(job, .{ .ctx = d, .f = sayLine });
            d.conversions[@intFromEnum(done)] += 1;
            if (done == .failed) return false;
            d.debug("{s} {d}x{d} converted {s} on the {s}", .{ if (s.layout.sample_bytes == 2) "P010" else "NV12", s.width, s.height, @tagName(dir), @tagName(done) });
            return true;
        }

        fn sayLine(ctx: *anyopaque, line: []const u8) void {
            const d: *Self = @ptrCast(@alignCast(ctx));
            d.node.sys.say(line);
        }

        /// The decode target's dma-buf (made once; the surface holds it).
        fn surfaceFd(d: *Self, s: *Surface) ?i32 {
            if (s.dmabuf < 0) {
                const fd = d.node.exportFd(s.tiled);
                if (fd < 0) {
                    d.say("the surface's dma-buf was refused ({d})", .{fd});
                    return null;
                }
                s.dmabuf = @intCast(fd);
            }
            return s.dmabuf;
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
            if (s.linear_fd >= 0) d.node.sys.close(s.linear_fd);
            // (the kernel keeps the pages until the decoder is done)
            d.node.free(&s.tiled);
            d.node.free(&s.linear);
            s.* = .{};
            d.node.free(&d.imports[i].second);
            if (d.imports[i].rgb) |*pic| {
                d.node.sys.close(pic.fd);
                d.node.free(&pic.buf);
            }
            d.imports[i] = .{};
        }

        // ── Surfaces over an app's dma-bufs (enc_import.sig) ────────────

        /// vaCreateSurfaces with VASurfaceAttribExternalBuffers (DRM PRIME
        /// fds: one surface per buffer) or a DRM_PRIME_2 descriptor (one
        /// surface): each imported, block linear read where it is, linear
        /// converted into the surface's own block-linear planes before
        /// each encode.
        fn importSurfaces(d: *Self, mem_type: u32, p: *anyopaque, width: u32, height: u32, out: []u32) va.Status {
            for (out, 0..) |*id, k| {
                // (an RGB picture: a screen capture's, converted on the GPU)
                const rgb = if (mem_type == va.MEM_TYPE_DRM_PRIME_2)
                    (if (k == 0) enc_import.rgbOfPrime2(@ptrCast(@alignCast(p))) else null)
                else
                    enc_import.rgbOfExternal(@ptrCast(@alignCast(p)), k);
                if (rgb) |pic| {
                    if (!@hasDecl(Conv, "rgb")) {
                        d.debug("an RGB dma-buf refused: no GPU converter (the CPU never converts what the encoder reads)", .{});
                        for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                        return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
                    }
                    const i = d.importRgbSurface(pic.fd, pic.offset, pic.pitch, pic.order, width, height) orelse {
                        for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                        return va.ERROR_ALLOCATION_FAILED;
                    };
                    id.* = SURFACE_BASE + i;
                    continue;
                }
                const plan = (if (mem_type == va.MEM_TYPE_DRM_PRIME_2)
                    (if (k == 0) enc_import.fromPrime2(@ptrCast(@alignCast(p)), d.opts.gob) else error.BadDescriptor)
                else
                    enc_import.fromExternal(@ptrCast(@alignCast(p)), k)) catch |e| {
                    d.debug("a surface over an app's dma-buf refused: {s}", .{@errorName(e)});
                    for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                    return if (e == error.Unsupported) va.ERROR_UNSUPPORTED_MEMORY_TYPE else va.ERROR_INVALID_PARAMETER;
                };
                const i = d.importSurface(plan, width, height) orelse {
                    for (out[0..k]) |made| d.dropSurface(@intCast(made - SURFACE_BASE));
                    return va.ERROR_ALLOCATION_FAILED;
                };
                id.* = SURFACE_BASE + i;
            }
            d.debug("{d} surfaces of {d}x{d} over the app's dma-bufs", .{ out.len, width, height });
            return va.SUCCESS;
        }

        /// An RGB picture's surface: the app's buffer imported (and our own
        /// dma-buf of it, the app's fd being the app's), the surface's own
        /// NV12 block-linear planes the GPU fills before each encode.
        fn importRgbSurface(d: *Self, fd: i32, offset: u32, pitch: u32, order: enc_import.RgbOrder, width: u32, height: u32) ?u16 {
            const i = for (d.surfaces, 0..) |s, i| {
                if (!s.used) break i;
            } else return null;
            var buf = enc_import.importFd(&d.node, fd, @as(u64, offset) + @as(u64, pitch) * height) orelse return null;
            const own = d.node.exportFd(buf);
            if (own < 0) {
                d.node.free(&buf);
                return null;
            }
            const layout = tiling.Nv12.of(width, std.mem.alignForward(u32, height, SURFACE_ROW_ALIGN));
            const tiled = d.node.alloc(@intCast(layout.bytes), node.G_VRAM) orelse {
                d.node.free(&buf);
                d.node.sys.close(@intCast(own));
                return null;
            };
            d.surfaces[i] = .{ .used = true, .width = width, .height = height, .layout = layout, .linear_layout = tiling.Linear.of(width, height), .tiled = tiled, .linear_stale = true };
            d.imports[i] = .{ .used = true, .layout = .block_linear, .rgb = .{ .buf = buf, .fd = @intCast(own), .offset = offset, .pitch = pitch, .order = order } };
            return @intCast(i);
        }

        /// An RGB surface's picture into its NV12 planes, on the GPU (the
        /// converter's `rgb`), before the encode reads them.
        fn convertRgb(d: *Self, si: u16) va.Status {
            if (!@hasDecl(Conv, "rgb")) return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
            const s = &d.surfaces[si];
            const pic = d.imports[si].rgb.?;
            var job = enc_import.RgbJob{ .dst = s.tiled.bytes(), .layout = s.layout, .gob = d.opts.gob, .src = pic.buf.bytes(), .src_offset = pic.offset, .src_pitch = pic.pitch, .order = pic.order, .width = s.width, .height = s.height };
            if (Conv.wants_fds) {
                job.dst_fd = d.surfaceFd(s) orelse return va.ERROR_OPERATION_FAILED;
                job.src_fd = pic.fd;
            }
            if (d.conv.rgb(job, .{ .ctx = d, .f = sayLine }) == .failed) {
                d.say("an RGB picture could not be converted on the GPU: not encoded", .{});
                return va.ERROR_OPERATION_FAILED;
            }
            s.tiled_stale = false;
            s.linear_stale = true;
            return va.SUCCESS;
        }

        fn importSurface(d: *Self, plan: enc_import.Plan, width: u32, height: u32) ?u16 {
            const i = for (d.surfaces, 0..) |s, i| {
                if (!s.used) break i;
            } else return null;
            const w = @min(width, plan.width);
            const h = @min(height, plan.height);
            var im = enc_import.Imported{ .used = true, .layout = plan.layout, .pitch = plan.pitch, .gobs_log2 = plan.gobs_log2 };
            var buf = enc_import.importFd(&d.node, plan.fd[0], plan.offset[0] + enc_import.planeBytes(plan, 0)) orelse return null;
            const same = plan.fd[1] == plan.fd[0];
            var chroma_buf = buf;
            if (!same) {
                chroma_buf = enc_import.importFd(&d.node, plan.fd[1], plan.offset[1] + enc_import.planeBytes(plan, 1)) orelse {
                    d.node.free(&buf);
                    return null;
                };
                // (the same kernel buffer under another fd: one buffer)
                if (chroma_buf.handle == buf.handle) {
                    chroma_buf = buf;
                } else im.second = chroma_buf;
            } else if (plan.offset[1] + enc_import.planeBytes(plan, 1) > buf.len) {
                d.node.free(&buf);
                return null;
            }
            im.luma = buf.va + plan.offset[0];
            im.chroma = chroma_buf.va + plan.offset[1];
            im.rows = @intCast(enc_import.planeBytes(plan, 0) / plan.pitch[0]);
            var s = Surface{ .used = true, .width = w, .height = h, .layout = tiling.Nv12.of(w, std.mem.alignForward(u32, h, SURFACE_ROW_ALIGN)), .linear_layout = tiling.Linear.of(w, h) };
            switch (plan.layout) {
                .block_linear => {
                    // (the picture is the app's: the driver's CPU paths see it
                    // as a GOB_2 surface with the app's pitch and planes)
                    s.tiled = buf;
                    s.layout.luma.pitch = plan.pitch[0];
                    s.layout.chroma.pitch = plan.pitch[1];
                    s.layout.chroma_offset = plan.offset[1];
                    s.linear_stale = true;
                },
                .linear => {
                    // the app's linear picture, and the surface's own block-
                    // linear planes the converter fills for the engine
                    s.linear = buf;
                    s.linear_layout = .{ .pitch = plan.pitch[0], .uv_offset = plan.offset[1], .bytes = @intCast(@min(buf.len, std.math.maxInt(u32))) };
                    s.tiled = d.node.alloc(@intCast(s.layout.bytes), node.G_VRAM) orelse {
                        d.node.free(&buf);
                        d.node.free(&im.second);
                        return null;
                    };
                    s.linear_stale = false;
                    s.tiled_stale = true;
                },
            }
            d.surfaces[i] = s;
            d.imports[i] = im;
            return @intCast(i);
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
            if (cfg.entrypoint == ve.ENTRYPOINT_ENC_SLICE) return d.createEncodeContext(@intCast(i), config, cfg, width, height, out);
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
                .vp8 => vp8.scratchBytes(width, height),
                .vp9 => vp9.scratchBytes(width, height),
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
            const o = d.opts;
            switch (kind) {
                .hevc => {
                    d.contexts[i].hevc = hevc.State.init(width, height);
                    d.contexts[i].hevc.blackwell = o.hevc_blackwell;
                    d.contexts[i].hevc.control = o.control;
                },
                .vp8 => d.contexts[i].vp8 = vp8.State.init(width, height),
                .vp9 => {
                    d.contexts[i].vp9 = vp9.State.init(width, height);
                    d.contexts[i].vp9.blackwell = o.vp9_blackwell;
                    d.contexts[i].vp9.control = o.control;
                    d.contexts[i].vp9.intra_top = o.vp9_intra_top;
                    d.contexts[i].vp9.stream_len_is = o.vp9_stream_len;
                },
                .av1 => {
                    d.contexts[i].av1 = av1.State.init(width, height);
                    d.contexts[i].av1.blackwell = o.av1_blackwell;
                    d.contexts[i].av1.control = o.control;
                },
                .h264 => unreachable,
            }
            out.* = CONTEXT_BASE + @as(u32, i);
            d.debug("{s} context {d}x{d}: work buffer {d} MiB", .{ @tagName(kind), width, height, work.len >> 20 });
            // (what this boot tries: the variant switches in force)
            switch (kind) {
                .hevc => d.debug("hevc variant: blackwell {s}, control {s}", .{ @tagName(o.hevc_blackwell), @tagName(o.control) }),
                .vp9 => d.debug("vp9 variant: blackwell {s}, control {s}, intra-top {s}, stream_len {s}", .{ @tagName(o.vp9_blackwell), @tagName(o.control), if (o.vp9_intra_top) "on" else "off", @tagName(o.vp9_stream_len) }),
                .av1 => d.debug("av1 variant: blackwell {s}, control {s}", .{ @tagName(o.av1_blackwell), @tagName(o.control) }),
                else => {},
            }
            return va.SUCCESS;
        }

        /// An encode context: FRAMES frame slots (pushbuffer, setup), then
        /// the engine's scratch (zeroed).
        fn createEncodeContext(d: *Self, i: u8, config: u32, cfg: *const Config, width: u32, height: u32, out: *u32) va.Status {
            if (enc_vpx.supported(cfg.profile)) |vk| return d.createVpxContext(i, config, cfg, vk, width, height, out);
            const kind = encode.supported(cfg.profile) orelse return va.ERROR_UNSUPPORTED_PROFILE;
            const sz = encode.scratchSizesFor(kind, width, height);
            const scratch_off = FRAMES * ENC_FRAME_BYTES;
            var work = d.node.alloc(scratch_off + sz.total, 0) orelse return va.ERROR_ALLOCATION_FAILED;
            if (!nvenc.addressable(work.va) or !nvenc.addressable(work.va + work.len - 256)) {
                d.node.free(&work);
                return va.ERROR_ALLOCATION_FAILED;
            }
            @memset(work.bytes()[scratch_off..][0..sz.total], 0);
            d.contexts[i] = .{
                .used = true,
                .config = @intCast(config - CONFIG_BASE),
                .encoding = true,
                .width_mbs = (width + 15) / 16,
                .height_mbs = (height + 15) / 16,
                .work = work,
                .scratch_off = scratch_off,
                .scratch_bytes = sz.total,
                .enc_scratch = sz,
            };
            d.contexts[i].enc = encode.State.init(kind, cfg.profile, width, height, cfg.rc_mode, cfg.packed_headers);
            d.contexts[i].enc.firmware_rc = d.opts.nvenc_rc_firmware;
            out.* = CONTEXT_BASE + @as(u32, i);
            d.debug("{s} encode context {d}x{d}: rate control {x}, packed headers {x}", .{ @tagName(kind), width, height, cfg.rc_mode, cfg.packed_headers });
            return va.SUCCESS;
        }

        pub fn destroyContext(d: *Self, id: u32) va.Status {
            const ci = d.contextIndex(id) orelse return va.ERROR_INVALID_CONTEXT;
            const c = &d.contexts[ci];
            if (c.vpx_on) {
                // (its pictures were encoded at EndPicture: nothing waits)
                if (@hasDecl(Conv, "vpxRelease")) d.conv.vpxRelease(ci);
                d.node.free(&c.vpx_work);
                d.node.free(&c.vpx_cpu);
                c.* = .{};
                return va.SUCCESS;
            }
            if (c.encoding) {
                // (its encodes finished, their coded buffers filled)
                for (&d.coded, 0..) |*cb, k| {
                    if (cb.used and cb.pending and cb.ctx == ci) _ = d.completeCoded(@intCast(k), d.node.sys.nowNs() + SYNC_NS);
                }
                for (&d.surfaces) |*s| {
                    if (s.used and s.enc_pending) _ = d.waitEncodeInput(s, d.node.sys.nowNs() + SYNC_NS);
                }
                d.node.free(&c.work);
                c.* = .{};
                return va.SUCCESS;
            }
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
            if (kind == ve.ENC_CODED_BUFFER) return d.createCoded(size, count, bytes, out);
            if (bytes > LARGE_BYTES) return va.ERROR_ALLOCATION_FAILED;
            const i = d.newBuffer(@intCast(bytes)) orelse return va.ERROR_ALLOCATION_FAILED;
            d.buffers[i] = .{ .used = true, .type = kind, .size = size, .count = count };
            if (data) |p| @memcpy(d.storage(i)[0..@intCast(bytes)], @as([*]const u8, @ptrCast(p))[0..@intCast(bytes)]);
            out.* = BUFFER_BASE + i;
            return va.SUCCESS;
        }

        /// A coded buffer: the kernel's (the engine writes the stream into
        /// it), `bytes` of stream after encode.sig's header.
        fn createCoded(d: *Self, size: u32, count: u32, bytes: u64, out: *u32) va.Status {
            if (bytes == 0 or bytes > 256 << 20) return va.ERROR_ALLOCATION_FAILED;
            const k = for (d.coded, 0..) |c, k| {
                if (!c.used) break k;
            } else return va.ERROR_ALLOCATION_FAILED;
            const i = d.newBuffer(0) orelse return va.ERROR_ALLOCATION_FAILED;
            const want = @max(encode.DATA_OFF + @as(usize, @intCast(bytes)), encode.DATA_OFF + encode.HEADER_BYTES + (1 << 20));
            const buf = d.node.alloc(want, 0) orelse return va.ERROR_ALLOCATION_FAILED;
            d.coded[k] = .{ .used = true, .buf = buf };
            encode.emptySegment(buf.bytes());
            d.buffers[i] = .{ .used = true, .type = ve.ENC_CODED_BUFFER, .size = size, .count = count, .coded = @intCast(k) };
            out.* = BUFFER_BASE + i;
            return va.SUCCESS;
        }

        pub fn bufferSetNumElements(d: *Self, id: u32, count: u32) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            const b = &d.buffers[i];
            if (b.coded != NO_CODED) return va.ERROR_INVALID_PARAMETER;
            if (b.surface != NONE or @as(u64, b.size) * count > d.storage(i).len) return va.ERROR_INVALID_PARAMETER;
            b.count = count;
            return va.SUCCESS;
        }

        pub fn mapBuffer(d: *Self, id: u32, out: *?*anyopaque) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            const b = &d.buffers[i];
            if (b.coded != NO_CODED) {
                // (a coded buffer: its segment, once the encode is done)
                const st = d.completeCoded(b.coded, d.node.sys.nowNs() + SYNC_NS);
                if (st != va.SUCCESS) return st;
                out.* = d.coded[b.coded].buf.cpu;
            } else if (b.surface != NONE) {
                // (a derived image: the decode's picture in the linear
                // copy, converted on the GPU if a decode came since; the
                // app may write it, so the picture is converted back
                // before the decoder, an export or the encoder reads it)
                const st = d.syncLinear(b.surface);
                if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
                const s = &d.surfaces[b.surface];
                s.tiled_stale = true;
                out.* = s.linear.cpu;
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
            if (b.coded != NO_CODED) {
                // (the kernel keeps the pages until the engine is done)
                d.node.free(&d.coded[b.coded].buf);
                d.coded[b.coded] = .{};
                d.buffers[i] = .{};
                return;
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

        /// vaSyncBuffer: the encode into coded buffer `id` done (by
        /// `timeout_ns` from now) and its segment filled.
        pub fn syncBuffer(d: *Self, id: u32, timeout_ns: i64) va.Status {
            const i = d.bufferIndex(id) orelse return va.ERROR_INVALID_BUFFER;
            const b = d.buffers[i];
            if (b.coded == NO_CODED) return va.ERROR_INVALID_BUFFER;
            const now = d.node.sys.nowNs();
            const deadline = if (timeout_ns >= std.math.maxInt(i64) - now) std.math.maxInt(i64) else now + timeout_ns;
            return d.completeCoded(b.coded, deadline);
        }

        /// The encode into coded buffer `k` done by `deadline` (0: only
        /// look), the engine's status read, the segment filled.
        fn completeCoded(d: *Self, k: u8, deadline: i64) va.Status {
            const cb = &d.coded[k];
            if (!cb.pending) return va.SUCCESS;
            switch (d.node.ewait(cb.fence, deadline)) {
                .done => {},
                .timeout => return va.ERROR_TIMEDOUT,
                .lost => {
                    cb.pending = false;
                    encode.emptySegment(cb.buf.bytes());
                    d.say("the GPU was lost during an encode", .{});
                    return va.ERROR_OPERATION_FAILED;
                },
            }
            cb.pending = false;
            const c = &d.contexts[cb.ctx];
            const est: ?*encode.State = if (c.used and c.encoding) &c.enc else null;
            const f = encode.finish(est, cb.buf.bytes(), cb.done);
            if (f.result.failed()) {
                d.errors += 1;
                d.say("an encode failed: error_status {x}, ucode error {x}{s}", .{ f.result.error_status, f.result.ucode_error, if (f.result.ucode_error == nvenc.ENC_ERROR_H264_BAD_MAGIC) " (bad magic: the setup is not the firmware's; GALAXY_VA_NVENC_MAGIC)" else "" });
            } else {
                d.debug("encode done: {d} bytes ({d} of headers), {d} slices, average QP {d}{s}", .{ f.bytes, cb.header_bytes, f.result.slices, f.result.avg_qp, if (f.overflow) ", cut: the coded buffer is too small" else "" });
            }
            return va.SUCCESS;
        }

        /// The encode reading surface `s`'s block-linear copy done.
        fn waitEncodeInput(d: *Self, s: *Surface, deadline: i64) va.Status {
            if (!s.enc_pending) return va.SUCCESS;
            switch (d.node.ewait(s.enc_fence, deadline)) {
                .done => {},
                .timeout => return va.ERROR_TIMEDOUT,
                .lost => {
                    s.enc_pending = false;
                    return va.ERROR_OPERATION_FAILED;
                },
            }
            s.enc_pending = false;
            return va.SUCCESS;
        }

        // ── Decoding ────────────────────────────────────────────────────

        pub fn beginPicture(d: *Self, ctx: u32, surface: u32) va.Status {
            const ci = d.contextIndex(ctx) orelse return va.ERROR_INVALID_CONTEXT;
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const c = &d.contexts[ci];
            c.target = NONE;
            if (c.encoding) {
                // the next frame slot, once its last encode is done
                const f = c.next_frame;
                if (c.frame_fence[f] != 0) switch (d.node.ewait(c.frame_fence[f], d.node.sys.nowNs() + SYNC_NS)) {
                    .done => {},
                    .timeout => return va.ERROR_TIMEDOUT,
                    .lost => return va.ERROR_OPERATION_FAILED,
                };
                c.target = si;
                c.target_id = surface;
                c.frame = f;
                if (c.vpx_on) enc_vpx.begin(&c.vpx) else encode.begin(&c.enc);
                c.bad = va.SUCCESS;
                return va.SUCCESS;
            }
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
                .vp8 => vp8.begin(&c.vp8),
                .vp9 => vp9.begin(&c.vp9),
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
            if (b.coded != NO_CODED) return va.ERROR_INVALID_BUFFER;
            const data = d.bufferBytes(bi);
            if (c.vpx_on) return enc_vpx.take(&c.vpx, .{ .kind = b.type, .size = b.size, .count = b.count, .data = data });
            if (c.encoding) return encode.take(&c.enc, .{ .kind = b.type, .size = b.size, .count = b.count, .data = data });
            if (c.codec != .h264) {
                const buf = codec.Buffer{ .kind = b.type, .size = b.size, .count = b.count, .data = data };
                const slot = frameSlot(c, c.frame);
                return switch (c.codec) {
                    .hevc => hevc.take(&c.hevc, buf, slot),
                    .vp8 => vp8.take(&c.vp8, buf, slot),
                    .vp9 => vp9.take(&c.vp9, buf, slot),
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
            if (c.vpx_on) return d.endVpx(ci, c);
            if (c.encoding) return d.endEncode(ci, c);
            if (c.codec != .h264) return d.endModule(ci, c);
            if (!c.have_pic or c.slices == 0) return va.ERROR_INVALID_PARAMETER;
            const pic = &c.pic;
            const wmbs = @as(u32, pic.picture_width_in_mbs_minus1) + 1;
            const hmbs = @as(u32, pic.picture_height_in_mbs_minus1) + 1;
            if (wmbs > c.width_mbs or hmbs > c.height_mbs) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            if (pic.seq_fields.chroma_format_idc != 1 or pic.bit_depth_luma_minus8 != 0 or pic.bit_depth_chroma_minus8 != 0) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            const si = c.target;
            const s = &d.surfaces[si];
            // (H.264 here is 8-bit: an NV12 target)
            if (s.layout.sample_bytes != 1) return va.ERROR_INVALID_SURFACE;
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
                // (a reference the CPU wrote since: its picture first)
                if (ref_surface[k] != NONE) _ = d.syncTiled(ref_surface[k]);
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
            s.linear_stale = true;
            s.tiled_stale = false;
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
                .vp8 => vp8.end(&c.vp8, slot, scratch, pic, lookup, &e),
                .vp9 => vp9.end(&c.vp9, slot, scratch, pic, lookup, &e),
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
            s.linear_stale = true;
            s.tiled_stale = false;
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
            // (AV1's film grain: the graded picture written into another
            // surface by the same decode, done with its fence)
            if (e.display) |id| if (d.surfaceIndex(id)) |di| {
                const ds = &d.surfaces[di];
                ds.pending = true;
                ds.linear_stale = true;
                ds.tiled_stale = false;
                ds.fence = fence;
                ds.ctx = ci;
                ds.frame = f;
                ds.serial = d.serial;
                ds.failed = false;
                ds.field_coded = false;
                ds.fields = 3;
            };
            if (e.wait) {
                const w = d.complete(si, d.node.sys.nowNs() + SYNC_NS);
                if (w != va.SUCCESS and w != va.ERROR_DECODING_ERROR) return w;
                switch (c.codec) {
                    .hevc => hevc.after(&c.hevc, scratch),
                    .vp8 => vp8.after(&c.vp8, scratch),
                    .vp9 => vp9.after(&c.vp9, scratch),
                    .av1 => av1.after(&c.av1, scratch),
                    .h264 => unreachable,
                }
            }
            return va.SUCCESS;
        }

        /// An encode's picture: the input current, the headers, setup and
        /// pushbuffer made (encode.end), submitted on the encoder channel.
        fn endEncode(d: *Self, ci: u8, c: *Context) va.Status {
            const si = c.target;
            const s = &d.surfaces[si];
            const cid = encode.codedBuffer(&c.enc) orelse return va.ERROR_INVALID_PARAMETER;
            const bi = d.bufferIndex(cid) orelse return va.ERROR_INVALID_BUFFER;
            const k = d.buffers[bi].coded;
            if (k == NO_CODED) return va.ERROR_INVALID_BUFFER;
            const cb = &d.coded[k];
            const deadline = d.node.sys.nowNs() + SYNC_NS;
            // (the coded buffer's last encode, the input's last reader, and
            // a decode into the input, all done first)
            var st = d.completeCoded(k, deadline);
            if (st != va.SUCCESS) return st;
            st = d.waitEncodeInput(s, deadline);
            if (st != va.SUCCESS) return st;
            // (the engine reads the input's block-linear picture where it
            // is: a decode into it done first; an app's CPU write into its
            // linear copy converted back by the driver's converter, the
            // GPU's in the shared library; an 8-bit picture only)
            if (s.layout.sample_bytes != 1) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            st = d.complete(si, deadline);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            // (an app's linear dma-buf changes behind the driver: converted
            // every time)
            if (d.imports[si].used and d.imports[si].layout == .linear) s.tiled_stale = true;
            st = if (d.imports[si].rgb != null) d.convertRgb(si) else d.syncTiled(si);
            if (st != va.SUCCESS) return st;
            const f = c.frame;
            const frame = c.work.bytes()[f * ENC_FRAME_BYTES ..][0..ENC_FRAME_BYTES];
            const base = c.work.va + f * ENC_FRAME_BYTES;
            const input = d.encodeInput(si);
            var out: encode.EndOut = .{};
            st = encode.end(&c.enc, .{
                .push = words(frame.ptr, ENC_PUSH_OFF, nvenc.PUSH_DWORDS_MAX),
                .setup = frame[ENC_SETUP_OFF..][0..nvenc.SETUP_BYTES],
                .setup_va = base + ENC_SETUP_OFF,
                .coded = cb.buf.bytes(),
                .coded_va = cb.buf.va,
                .input = input,
                .lookup = .{ .ctx = d, .surface_fn = lookupSurface },
                .scratch = .{
                    .base = c.work.va + c.scratch_off,
                    .cpu = c.work.bytes()[c.scratch_off..][0..c.enc_scratch.total],
                    .sizes = c.enc_scratch,
                },
                .picture_index = c.decodes,
                .magic = d.opts.nvenc_magic orelse nvenc.MAGIC,
            }, &out);
            if (st != va.SUCCESS) {
                d.debug("encode picture refused ({x})", .{st});
                return st;
            }
            const fence = d.node.esubmit(c.work, @intCast(f * ENC_FRAME_BYTES + ENC_PUSH_OFF), @intCast(out.dwords)) catch |e| {
                d.say("an encode was not submitted ({s})", .{@errorName(e)});
                return if (e == error.NoEncoder) va.ERROR_UNIMPLEMENTED else va.ERROR_OPERATION_FAILED;
            };
            const kept = cb.buf;
            cb.* = .{ .used = true, .buf = kept, .pending = true, .fence = fence, .ctx = ci, .header_bytes = out.header_bytes, .done = out.done };
            s.enc_pending = true;
            s.enc_fence = fence;
            c.frame_fence[f] = fence;
            c.frame_surface[f] = si;
            c.next_frame = (f + 1) % FRAMES;
            c.decodes +%= 1;
            d.debug("encode {d} submitted: QP {d}, {d} bytes of headers", .{ c.decodes, out.qp, out.header_bytes });
            return va.SUCCESS;
        }

        // ── VP8 and VP9 (enc_vpx.sig) ───────────────────────────────────

        /// The packer's scratch for a context of `width` x `height`: the
        /// partitions (VP8) or the headers and tiles (VP9) while they are
        /// written, each up to a frame's worth.
        fn vpxScratchBytes(width: u32, height: u32) usize {
            const w: usize = std.mem.alignForward(u32, width, 64);
            const h: usize = std.mem.alignForward(u32, height, 64);
            return 2 * (w * h * 3 / 2 + (256 << 10));
        }

        /// A VP8 or VP9 encode context: the state and the packer's scratch
        /// (system memory). The encoder itself is made at the first
        /// picture, at the stream's size (the context's may be the
        /// surfaces' aligned size: FFmpeg's VP9); the CPU engine's memory
        /// when the CPU encodes, the RTX's in the converter's GPU context.
        fn createVpxContext(d: *Self, i: u8, config: u32, cfg: *const Config, kind: enc_vpx.Codec, width: u32, height: u32, out: *u32) va.Status {
            const work = d.node.alloc(vpxScratchBytes(width, height), 0) orelse return va.ERROR_ALLOCATION_FAILED;
            d.contexts[i] = .{
                .used = true,
                .config = @intCast(config - CONFIG_BASE),
                .encoding = true,
                .width_mbs = (width + 15) / 16,
                .height_mbs = (height + 15) / 16,
                .vpx_on = true,
                .vpx = enc_vpx.State.init(kind, width, height, cfg.rc_mode),
                .vpx_work = work,
            };
            out.* = CONTEXT_BASE + @as(u32, i);
            d.debug("{s} encode context {d}x{d} (kernels on the {s}): rate control {x}", .{ @tagName(kind), width, height, if (@hasDecl(Conv, "vpxFrame") and d.opts.vpx_gpu) "RTX" else "CPU", cfg.rc_mode });
            return va.SUCCESS;
        }

        /// The stream's size: VP8's sequence, VP9's picture.
        fn vpxSize(c: *const Context) [2]u32 {
            const v = &c.vpx;
            return switch (v.codec) {
                .vp8 => if (v.have_seq and v.seq8.frame_width != 0) .{ v.seq8.frame_width, v.seq8.frame_height } else .{ v.width, v.height },
                .vp9 => if (v.have_pic and v.pic9.frame_width_dst != 0) .{ v.pic9.frame_width_dst, v.pic9.frame_height_dst } else .{ v.width, v.height },
            };
        }

        /// The encoder at the stream's size (made again when it changes:
        /// the next picture is a key frame then).
        fn vpxEnsure(d: *Self, c: *Context) va.Status {
            const sz = vpxSize(c);
            if (sz[0] == 0 or sz[1] == 0 or sz[0] > c.width_mbs * 16 or sz[1] > c.height_mbs * 16) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            const same = c.vpx_engine != .none and switch (c.vpx.codec) {
                .vp8 => c.vpx.vp8.lay.width == sz[0] and c.vpx.vp8.lay.height == sz[1],
                .vp9 => c.vpx.vp9.width == sz[0] and c.vpx.vp9.height == sz[1],
            };
            if (same) return va.SUCCESS;
            switch (c.vpx.codec) {
                .vp8 => c.vpx.vp8 = enc_vp8.Encoder.init(sz[0], sz[1]) catch return va.ERROR_RESOLUTION_NOT_SUPPORTED,
                .vp9 => c.vpx.vp9 = enc_vp9.Encoder.init(sz[0], sz[1]) catch return va.ERROR_RESOLUTION_NOT_SUPPORTED,
            }
            d.node.free(&c.vpx_cpu);
            c.vpx_engine = .none;
            return va.SUCCESS;
        }

        /// A VP8 or VP9 picture, encoded now: the input current, the plan,
        /// the kernels on the RTX (the converter's GPU context) or the CPU,
        /// the bitstream into the coded buffer, its segment filled.
        fn endVpx(d: *Self, ci: u8, c: *Context) va.Status {
            const si = c.target;
            const s = &d.surfaces[si];
            const cid = enc_vpx.codedBuffer(&c.vpx) orelse return va.ERROR_INVALID_PARAMETER;
            const bi = d.bufferIndex(cid) orelse return va.ERROR_INVALID_BUFFER;
            const k = d.buffers[bi].coded;
            if (k == NO_CODED) return va.ERROR_INVALID_BUFFER;
            const cb = &d.coded[k];
            const deadline = d.node.sys.nowNs() + SYNC_NS;
            var st = d.completeCoded(k, deadline);
            if (st != va.SUCCESS) return st;
            // (the input current: a decode into it done; an app's CPU write
            // or linear dma-buf converted back; RGB converted on the GPU)
            if (s.layout.sample_bytes != 1) return va.ERROR_UNSUPPORTED_RT_FORMAT;
            st = d.complete(si, deadline);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            if (d.imports[si].used and d.imports[si].layout == .linear) s.tiled_stale = true;
            st = if (d.imports[si].rgb != null) d.convertRgb(si) else d.syncTiled(si);
            if (st != va.SUCCESS) return st;
            st = d.vpxEnsure(c);
            if (st != va.SUCCESS) return st;
            var pl: enc_vpx.Plan = undefined;
            st = enc_vpx.plan(&c.vpx, &pl);
            if (st != va.SUCCESS) return st;

            // the input as the load kernel reads it: the surface's buffer,
            // its planes' offsets, pitches, swizzles and block height
            const im = d.imports[si];
            var luma_at: u64 = 0;
            var chroma_at: u64 = s.layout.chroma_offset;
            var gobs: u32 = tiling.BLOCK_GOBS_LOG2;
            if (im.used and im.layout == .block_linear and im.rgb == null) {
                // (an app's planes in two buffers: not read here)
                if (im.second.handle != 0) return va.ERROR_UNSUPPORTED_MEMORY_TYPE;
                luma_at = im.luma - s.tiled.va;
                chroma_at = im.chroma - s.tiled.va;
                gobs = im.gobs_log2;
            }
            const sw = s.layout.swizzles(d.opts.gob);
            const surf = enc_vp8.Surface{
                .luma = @intCast(luma_at),
                .chroma = @intCast(chroma_at),
                .pitch_luma = s.layout.luma.pitch,
                .pitch_chroma = s.layout.chroma.pitch,
                .swz_luma = @intFromEnum(sw[0]),
                .swz_chroma = @intFromEnum(sw[1]),
                .gobs = gobs,
            };
            const coded = cb.buf.bytes();
            const out = coded[encode.DATA_OFF..];
            const scratch = c.vpx_work.bytes();
            var bytes: usize = 0;
            var full = false;
            var on: @TypeOf(c.vpx_engine) = .none;
            // the RTX: the converter's GPU context runs the kernels
            if (@hasDecl(Conv, "vpxFrame") and d.opts.vpx_gpu and c.vpx_engine != .cpu) gpu: {
                const fd = d.surfaceFd(s) orelse break :gpu;
                const r = d.conv.vpxFrame(ci, .{
                    .state = &c.vpx,
                    .plan = pl,
                    .surface = surf,
                    .surface_fd = fd,
                    .surface_bytes = s.tiled.len,
                    .out = out,
                    .scratch = scratch,
                    .fresh = c.vpx_engine == .none,
                }, .{ .ctx = d, .f = sayLine });
                switch (r) {
                    .done => |n| {
                        bytes = n;
                        on = .gpu;
                    },
                    .full => {
                        full = true;
                        on = .gpu;
                    },
                    .unavailable => {},
                    .failed => {
                        d.say("a {s} picture failed on the GPU: the CPU encodes, from a key frame", .{@tagName(c.vpx.codec)});
                        c.vpx_engine = .none;
                    },
                }
            }
            if (on == .none) {
                if (c.vpx_engine == .gpu) {
                    // (the frame store was the GPU's: start again)
                    c.vpx_engine = .none;
                    st = d.vpxEnsure(c);
                    if (st != va.SUCCESS) return st;
                }
                const need = switch (c.vpx.codec) {
                    .vp8 => c.vpx.vp8.lay.mem_bytes + c.vpx.vp8.lay.info_bytes,
                    .vp9 => enc_vp9.cpuBytes(&c.vpx.vp9),
                };
                if (c.vpx_cpu.handle == 0) {
                    c.vpx_cpu = d.node.alloc(need, 0) orelse return va.ERROR_ALLOCATION_FAILED;
                    @memset(c.vpx_cpu.bytes()[0..need], 0);
                }
                if (c.vpx_engine == .none) switch (c.vpx.codec) {
                    // (a new frame store: a key frame first)
                    .vp8 => c.vpx.vp8.have_last = false,
                    .vp9 => enc_vp9.restart(&c.vpx.vp9),
                };
                const mem = c.vpx_cpu.bytes()[0..need];
                switch (c.vpx.codec) {
                    .vp8 => {
                        const lay = c.vpx.vp8.lay;
                        var eng = enc_vp8.CpuEngine{ .mem = mem[0..lay.mem_bytes], .info = mem[lay.mem_bytes..][0..lay.info_bytes], .surf = s.tiled.bytes() };
                        if (enc_vp8.encodeFrame(&c.vpx.vp8, &eng, surf, pl.vp8, out, scratch)) |r| {
                            bytes = r.bytes;
                        } else |e| {
                            if (e != error.NoSpace) return va.ERROR_ENCODING_ERROR;
                            full = true;
                        }
                    },
                    .vp9 => {
                        if (enc_vp9.encodeCpu(&c.vpx.vp9, mem, s.tiled.bytes(), surf, pl.vp9, out, scratch)) |r| {
                            bytes = r;
                        } else |e| {
                            if (e != error.NoSpace) return va.ERROR_ENCODING_ERROR;
                            full = true;
                        }
                    },
                }
                on = .cpu;
            }
            c.vpx_engine = on;
            enc_vpx.segment(coded, encode.DATA_OFF, @intCast(bytes), full);
            cb.pending = false;
            enc_vpx.done(&c.vpx, pl, bytes);
            c.decodes +%= 1;
            d.debug("{s} picture {d} on the {s}: {s}, q {d}, {d} bytes{s}", .{ @tagName(c.vpx.codec), c.decodes, @tagName(on), if (pl.key) "key" else "inter", pl.q, bytes, if (full) " (the coded buffer is too small)" else "" });
            return va.SUCCESS;
        }

        /// The encode's input as the engine reads it: the surface's block-
        /// linear planes, as they lie (no pass of the driver's).
        fn encodeInput(d: *Self, si: u16) encode.Input {
            const s = &d.surfaces[si];
            const im = d.imports[si];
            // (an app's block-linear dma-buf: its own planes, block height)
            if (im.used and im.layout == .block_linear and im.rgb == null) return .{
                .luma = im.luma,
                .chroma = im.chroma,
                .pitch_luma = im.pitch[0],
                .pitch_chroma = im.pitch[1],
                .block_height = im.gobs_log2,
                .rows = im.rows,
                .width = s.width,
                .height = s.height,
            };
            return .{
                .luma = s.tiled.va,
                .chroma = s.tiled.va + s.layout.chroma_offset,
                .pitch_luma = s.layout.luma.pitch,
                .pitch_chroma = s.layout.chroma.pitch,
                .rows = s.layout.luma.rows,
                .width = s.width,
                .height = s.height,
            };
        }

        fn lookupSurface(ctx: *anyopaque, id: u32) ?codec.SurfaceRef {
            const d: *Self = @ptrCast(@alignCast(ctx));
            const i = d.surfaceIndex(id) orelse return null;
            // (a reference the CPU wrote since: its picture first)
            _ = d.syncTiled(i);
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
                .sample_bytes = s.layout.sample_bytes,
                .bytes = @intCast(s.layout.bytes),
            };
        }

        /// The decode into surface `si` done by `deadline` (0: only look),
        /// its status read. (Nothing copied: the picture stays where the
        /// decoder wrote it.)
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
            return if (s.failed) va.ERROR_DECODING_ERROR else va.SUCCESS;
        }

        pub fn syncSurface(d: *Self, surface: u32, timeout_ns: i64) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const now = d.node.sys.nowNs();
            const deadline = if (timeout_ns >= std.math.maxInt(i64) - now) std.math.maxInt(i64) else now + timeout_ns;
            // (an encode reading it: its coded buffer filled too)
            if (d.surfaces[si].enc_pending) {
                const fence = d.surfaces[si].enc_fence;
                const st = d.waitEncodeInput(&d.surfaces[si], deadline);
                if (st != va.SUCCESS) return st;
                for (&d.coded, 0..) |*cb, k| {
                    if (cb.used and cb.pending and cb.fence == fence) _ = d.completeCoded(@intCast(k), deadline);
                }
            }
            return d.complete(si, deadline);
        }

        pub fn querySurfaceStatus(d: *Self, surface: u32, status: *u32) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (d.surfaces[si].enc_pending) {
                if (d.waitEncodeInput(&d.surfaces[si], 0) == va.ERROR_TIMEDOUT) {
                    status.* = va.SURFACE_RENDERING;
                    return va.SUCCESS;
                }
            }
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
            if (d.syncTiled(si) != va.SUCCESS) return va.ERROR_OPERATION_FAILED;
            const s = &d.surfaces[si];
            const held = d.surfaceFd(s) orelse return va.ERROR_OPERATION_FAILED;
            // The decode target as it is: one dma-buf (VRAM), each plane
            // block linear with its modifier. NV12's Y (8 bpp) and UV (16
            // bpp) have different sector layouts on Blackwell, and a
            // descriptor gives a modifier per object, so the planes are
            // two objects of the one dma-buf (an fd each: Firefox closes
            // every layer's object fd); with one modifier for both
            // (GALAXY_VA_GOB=turing), one object.
            const sw = s.layout.swizzles(d.opts.gob);
            const mods = [2]u64{ tiling.modifierOf(sw[0]), tiling.modifierOf(sw[1]) };
            const objects: u32 = if (mods[0] == mods[1]) 1 else 2;
            desc.* = std.mem.zeroes(va.DrmPrimeDescriptor);
            for (0..objects) |o| {
                const fd = d.node.sys.dup(held);
                if (fd < 0) {
                    for (0..o) |k| d.node.sys.close(desc.objects[k].fd);
                    return va.ERROR_OPERATION_FAILED;
                }
                desc.objects[o] = .{ .fd = @intCast(fd), .size = @intCast(s.tiled.len), .drm_format_modifier = mods[o] };
            }
            const p010 = s.layout.sample_bytes == 2;
            const chroma_object: u32 = objects - 1;
            const chroma_at: u32 = @intCast(s.layout.chroma_offset);
            desc.fourcc = fourccOf(s.layout.sample_bytes);
            desc.width = s.width;
            desc.height = s.height;
            desc.num_objects = objects;
            if (flags & va.EXPORT_SURFACE_COMPOSED_LAYERS != 0) {
                desc.num_layers = 1;
                desc.layers[0].drm_format = if (p010) va.DRM_FORMAT_P010 else va.DRM_FORMAT_NV12;
                desc.layers[0].num_planes = 2;
                desc.layers[0].object_index = .{ 0, chroma_object, 0, 0 };
                desc.layers[0].offset = .{ 0, chroma_at, 0, 0 };
                desc.layers[0].pitch = .{ s.layout.luma.pitch, s.layout.chroma.pitch, 0, 0 };
            } else {
                desc.num_layers = 2;
                desc.layers[0].drm_format = if (p010) va.DRM_FORMAT_R16 else va.DRM_FORMAT_R8;
                desc.layers[0].num_planes = 1;
                desc.layers[0].pitch[0] = s.layout.luma.pitch;
                desc.layers[1].drm_format = if (p010) va.DRM_FORMAT_GR1616 else va.DRM_FORMAT_GR88;
                desc.layers[1].num_planes = 1;
                desc.layers[1].object_index[0] = chroma_object;
                desc.layers[1].offset[0] = chroma_at;
                desc.layers[1].pitch[0] = s.layout.chroma.pitch;
            }
            d.exports += 1;
            return va.SUCCESS;
        }

        // ── Images ──────────────────────────────────────────────────────

        pub fn queryImageFormats(_: *Self, list: [*]va.ImageFormat, n: *i32) va.Status {
            list[0] = va.NV12_FORMAT;
            list[1] = va.P010_FORMAT;
            n.* = 2;
            return va.SUCCESS;
        }

        fn newImage(d: *Self) ?u16 {
            for (d.images, 0..) |im, i| {
                if (!im.used) return @intCast(i);
            }
            return null;
        }

        /// An image format's bytes a sample (null: not had here).
        fn imageSampleBytes(fourcc: u32) ?u8 {
            return switch (fourcc) {
                va.FOURCC_NV12 => 1,
                va.FOURCC_P010 => 2,
                else => null,
            };
        }

        fn describe(id: u32, buf: u32, width: u32, height: u32, lin: tiling.Linear) va.Image {
            var im = std.mem.zeroes(va.Image);
            im.image_id = id;
            im.format = if (lin.sample_bytes == 2) va.P010_FORMAT else va.NV12_FORMAT;
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
            const sb = imageSampleBytes(format.fourcc) orelse return va.ERROR_INVALID_IMAGE_FORMAT;
            if (width == 0 or height == 0 or width > MAX_SIZE or height > MAX_SIZE) return va.ERROR_RESOLUTION_NOT_SUPPORTED;
            const ii = d.newImage() orelse return va.ERROR_ALLOCATION_FAILED;
            const lin = tiling.Linear.ofDepth(width, height, sb);
            var bid: u32 = 0;
            const st = d.createBuffer(va.IMAGE_BUFFER, lin.bytes, 1, null, &bid);
            if (st != va.SUCCESS) return st;
            const id = IMAGE_BASE + @as(u32, ii);
            d.images[ii] = .{ .used = true, .image = describe(id, bid, width, height, lin), .buffer = @intCast(bid - BUFFER_BASE) };
            out.* = d.images[ii].image;
            return va.SUCCESS;
        }

        /// vaDeriveImage: the surface's linear copy as an image (made now
        /// if it has none; converted from the picture when the image's
        /// buffer is mapped).
        pub fn deriveImage(d: *Self, surface: u32, out: *va.Image) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            const ii = d.newImage() orelse return va.ERROR_ALLOCATION_FAILED;
            const bi = for (d.buffers, 0..) |b, i| {
                if (!b.used) break i;
            } else return va.ERROR_ALLOCATION_FAILED;
            const s = &d.surfaces[si];
            if (!d.ensureLinear(s)) return va.ERROR_ALLOCATION_FAILED;
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

        /// An image's bytes for a copy: its own buffer, or (derived) its
        /// surface's linear copy brought up to date.
        fn imageBytes(d: *Self, im: ImageEntry) ?[]u8 {
            if (im.surface == NONE) return d.storage(im.buffer);
            const st = d.syncLinear(im.surface);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return null;
            return d.surfaces[im.surface].linear.bytes();
        }

        /// vaPutImage: the rectangle (src_x, src_y, width, height) of the
        /// image into the surface's picture at (dst_x, dst_y), no scaling:
        /// how an app fills a surface to encode. Into the linear copy (up
        /// to date first), the picture converted back when next needed.
        pub fn putImage(d: *Self, surface: u32, image: u32, src_x: i32, src_y: i32, src_w: u32, src_h: u32, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (image < IMAGE_BASE or image - IMAGE_BASE >= MAX_IMAGES or !d.images[image - IMAGE_BASE].used) return va.ERROR_INVALID_IMAGE;
            if (src_w != dst_w or src_h != dst_h) return va.ERROR_UNIMPLEMENTED;
            if (src_x < 0 or src_y < 0 or dst_x < 0 or dst_y < 0) return va.ERROR_INVALID_PARAMETER;
            const im = d.images[image - IMAGE_BASE];
            if (im.surface == si) return va.SUCCESS;
            const s = &d.surfaces[si];
            const sb = s.layout.sample_bytes;
            if (imageSampleBytes(im.image.format.fourcc) != sb) return va.ERROR_INVALID_IMAGE_FORMAT;
            const sx: u32 = @intCast(src_x);
            const sy: u32 = @intCast(src_y);
            const dx: u32 = @intCast(dst_x);
            const dy: u32 = @intCast(dst_y);
            const w = src_w;
            const h = src_h;
            if (sx + w > im.image.width or sy + h > im.image.height or dx + w > s.width or dy + h > s.height) return va.ERROR_INVALID_PARAMETER;
            // (a decode into it lands first, or it would land over this;
            // the rest of the picture kept)
            const st = d.syncLinear(si);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            const src = d.imageBytes(im) orelse return va.ERROR_OPERATION_FAILED;
            const dst = s.linear.bytes();
            const lin = s.linear_layout;
            const ip = im.image.pitches;
            const io = im.image.offsets;
            for (0..h) |r| {
                @memcpy(dst[(dy + r) * lin.pitch + dx * sb ..][0 .. w * sb], src[io[0] + (sy + r) * ip[0] + sx * sb ..][0 .. w * sb]);
            }
            // chroma: whole UV pairs, rows of the 4:2:0 plane
            const csx = sx & ~@as(u32, 1);
            const cdx = dx & ~@as(u32, 1);
            const cw = @min(2 * ((w + 1) / 2), 2 * ((s.width + 1) / 2) - cdx);
            for (0..(h + 1) / 2) |r| {
                const srow = sy / 2 + r;
                const drow = dy / 2 + r;
                if (drow >= (s.height + 1) / 2 or srow >= (@as(u32, im.image.height) + 1) / 2) break;
                @memcpy(dst[lin.uv_offset + drow * lin.pitch + cdx * sb ..][0 .. cw * sb], src[io[1] + srow * ip[1] + csx * sb ..][0 .. cw * sb]);
            }
            s.tiled_stale = true;
            return va.SUCCESS;
        }

        /// The rectangle (x, y, width, height) of surface's picture into
        /// image (at its origin): from its linear copy, converted on the
        /// GPU first if a decode came since.
        pub fn getImage(d: *Self, surface: u32, x: i32, y: i32, width: u32, height: u32, image: u32) va.Status {
            const si = d.surfaceIndex(surface) orelse return va.ERROR_INVALID_SURFACE;
            if (image < IMAGE_BASE or image - IMAGE_BASE >= MAX_IMAGES or !d.images[image - IMAGE_BASE].used) return va.ERROR_INVALID_IMAGE;
            const im = d.images[image - IMAGE_BASE];
            const st = d.syncLinear(si);
            if (st != va.SUCCESS and st != va.ERROR_DECODING_ERROR) return st;
            if (im.surface == si) return va.SUCCESS;
            const s = &d.surfaces[si];
            const sb = s.layout.sample_bytes;
            if (imageSampleBytes(im.image.format.fourcc) != sb) return va.ERROR_INVALID_IMAGE_FORMAT;
            if (x < 0 or y < 0) return va.ERROR_INVALID_PARAMETER;
            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            if (ux + width > s.width or uy + height > s.height or width > im.image.width or height > im.image.height) return va.ERROR_INVALID_PARAMETER;
            const dst = d.imageBytes(im) orelse return va.ERROR_OPERATION_FAILED;
            const src = s.linear.bytes();
            const lin = s.linear_layout;
            const ip = im.image.pitches;
            const io = im.image.offsets;
            for (0..height) |r| {
                @memcpy(dst[io[0] + r * ip[0] ..][0 .. width * sb], src[(uy + r) * lin.pitch + ux * sb ..][0 .. width * sb]);
            }
            const cx = ux & ~@as(u32, 1);
            const cw = 2 * ((width + 1) / 2);
            for (0..(height + 1) / 2) |r| {
                const sy = uy / 2 + r;
                if (sy >= (s.height + 1) / 2) break;
                const n = @min(cw, 2 * ((s.width + 1) / 2) - cx);
                @memcpy(dst[io[1] + r * ip[1] ..][0 .. n * sb], src[lin.uv_offset + sy * lin.pitch + cx * sb ..][0 .. n * sb]);
            }
            if (im.surface != NONE) d.surfaces[im.surface].tiled_stale = true;
            return va.SUCCESS;
        }
    };
}

pub fn intAttrib(kind: u32, flags: u32, v: u32) va.SurfaceAttrib {
    return .{ .type = kind, .flags = flags, .value = .{ .type = va.GENERIC_INTEGER, .value = .{ .i = @bitCast(v) } } };
}

/// An EncSlice config attribute's value (what FFmpeg's vaapi_encode asks).
pub fn encodeAttribute(profile: va.Profile, kind: u32) u32 {
    if (enc_vpx.supported(profile) != null) return switch (kind) {
        va.ATTRIB_RT_FORMAT => va.RT_FORMAT_YUV420,
        ve.ATTRIB_RATE_CONTROL => enc_vpx.RC_MODES,
        ve.ATTRIB_ENC_PACKED_HEADERS => enc_vpx.PACKED_HEADERS,
        ve.ATTRIB_ENC_MAX_REF_FRAMES => enc_vpx.MAX_REFS,
        va.ATTRIB_MAX_PICTURE_WIDTH, va.ATTRIB_MAX_PICTURE_HEIGHT => MAX_SIZE,
        else => va.ATTRIB_NOT_SUPPORTED,
    };
    const hevc_profile = profile == va.PROFILE_HEVC_MAIN;
    const av1_profile = encode.supported(profile) == .av1;
    const enc_av1 = @import("enc_av1.sig");
    if (av1_profile) switch (kind) {
        ve.ATTRIB_ENC_AV1 => return enc_av1.ATTRIB,
        ve.ATTRIB_ENC_AV1_EXT1 => return enc_av1.ATTRIB_EXT1,
        ve.ATTRIB_ENC_AV1_EXT2 => return enc_av1.ATTRIB_EXT2,
        ve.ATTRIB_ENC_MAX_REF_FRAMES => return encode.MAX_REFS_AV1,
        ve.ATTRIB_ENC_PACKED_HEADERS => return enc_av1.PACKED_HEADERS,
        ve.ATTRIB_ENC_MAX_SLICES, ve.ATTRIB_ENC_MAX_TILE_ROWS, ve.ATTRIB_ENC_MAX_TILE_COLS => return 1,
        ve.ATTRIB_ENC_SLICE_STRUCTURE => return va.ATTRIB_NOT_SUPPORTED,
        else => {},
    };
    return switch (kind) {
        va.ATTRIB_RT_FORMAT => va.RT_FORMAT_YUV420,
        ve.ATTRIB_RATE_CONTROL => encode.RC_MODES,
        ve.ATTRIB_ENC_PACKED_HEADERS => encode.PACKED_HEADERS,
        ve.ATTRIB_ENC_INTERLACED => ve.ENC_INTERLACED_NONE,
        ve.ATTRIB_ENC_MAX_REF_FRAMES => encode.MAX_REFS,
        ve.ATTRIB_ENC_MAX_SLICES => nvenc.MAX_SLICES,
        ve.ATTRIB_ENC_SLICE_STRUCTURE => ve.SLICE_STRUCTURE_POWER_OF_TWO_ROWS | ve.SLICE_STRUCTURE_ARBITRARY_MACROBLOCKS | ve.SLICE_STRUCTURE_EQUAL_ROWS | ve.SLICE_STRUCTURE_ARBITRARY_ROWS,
        va.ATTRIB_MAX_PICTURE_WIDTH, va.ATTRIB_MAX_PICTURE_HEIGHT => MAX_SIZE,
        ve.ATTRIB_ENC_HEVC_FEATURES => if (hevc_profile) @import("enc_hevc.sig").FEATURES else va.ATTRIB_NOT_SUPPORTED,
        ve.ATTRIB_ENC_HEVC_BLOCK_SIZES => if (hevc_profile) @import("enc_hevc.sig").BLOCK_SIZES else va.ATTRIB_NOT_SUPPORTED,
        else => va.ATTRIB_NOT_SUPPORTED,
    };
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
    std.debug.assert(vp8.MAX_PIC_BYTES <= codec.PIC_BYTES and vp8.MAX_AUX_BYTES <= codec.AUX_BYTES and vp8.PUSH_DWORDS <= PUSH_DWORDS_MAX);
    std.debug.assert(vp9.MAX_PIC_BYTES <= codec.PIC_BYTES and vp9.MAX_AUX_BYTES <= codec.AUX_BYTES and vp9.PUSH_DWORDS <= PUSH_DWORDS_MAX);
    std.debug.assert(nvdec.PUSH_DWORDS <= PUSH_DWORDS_MAX and hevc.PUSH_DWORDS <= PUSH_DWORDS_MAX and av1.PUSH_DWORDS <= PUSH_DWORDS_MAX);
    std.debug.assert(ENC_PUSH_OFF + nvenc.PUSH_DWORDS_MAX * 4 <= ENC_SETUP_OFF and ENC_SETUP_OFF % 256 == 0);
    std.debug.assert(ENC_SETUP_OFF + nvenc.SETUP_BYTES <= ENC_FRAME_BYTES and ENC_FRAME_BYTES % 256 == 0);
}

/// `n` dwords at byte `off` of mapped GPU memory.
fn words(base: [*]u8, off: usize, n: usize) []u32 {
    const p: [*]u32 = @ptrCast(@alignCast(base + off));
    return p[0..n];
}
