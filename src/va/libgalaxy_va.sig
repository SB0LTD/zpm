//! @zpm/va libgalaxy_va — the root of galaxy_drv_video.so, Galaxy's VA-API
//! driver for the RTX's hardware video decoder (NVDEC on the GB206, the
//! RTX 5070 Laptop GPU), H.264 first. libva (Alpine's 2.22) loads it as
//! /usr/lib/dri/galaxy_drv_video.so (LIBVA_DRIVER_NAME=galaxy) and calls
//! `__vaDriverInit_1_0` with the render node it opened; the driver fills
//! libva's table with the entry points below. One file, no C library, no
//! DT_NEEDED: system calls through std.os.linux, fixed tables.
//!
//! What works (host-tested, against a fake render node and decoder):
//! - the queries FFmpeg's vaapi hwaccel and Firefox's VA-API probe make:
//!   profiles (H.264 Constrained Baseline, Main, High), the VLD
//!   entrypoint, config attributes (RT format YUV 4:2:0), configs,
//!   surface attributes (NV12; memory VA and DRM PRIME 2), image formats
//!   (NV12), the vendor string;
//! - NV12 surfaces, contexts, buffers (create, map, unmap, destroy, info);
//! - Begin/Render/EndPicture to an NVDEC pushbuffer and picture setup
//!   (bitstream with start codes, slice table, end of stream, reference
//!   slots, the watchdog), submitted with G_VSUBMIT; SyncSurface and
//!   QuerySurfaceStatus through G_VWAIT, the decoder's status read and
//!   counted; nothing copied (decode targets live in VRAM, block linear);
//! - 10-bit: HEVC Main10, VP9 profile 2, AV1 10-bit into P010 surfaces;
//!   AV1's film grain applied by the decoder into current_display_picture;
//! - ExportSurfaceHandle (DRM PRIME 2: the decode target's own dma-buf,
//!   separate R8 + GR88 / R16 + GR1616 layers or composed NV12 / P010,
//!   each plane with NVIDIA's block-linear modifier: zero copy), DeriveImage,
//!   CreateImage, GetImage, PutImage, DestroyImage (the CPU's copy made on
//!   the RTX by gpu_convert's kernel, only when one of these asks);
//! - every table entry libva 2.22 checks is set (subpictures, display
//!   attributes, PutSurface answer UNIMPLEMENTED or nothing);
//! - encoding on the RTX's NVENC (encode.sig): the EncSlice entrypoint for
//!   H.264 (Constrained Baseline, Main, High), HEVC Main and AV1 Profile
//!   0, the config attributes FFmpeg's vaapi_encode asks (rate control
//!   CQP, CBR, VBR: the driver's HRD-bound controller, enc_rc.sig, or the
//!   firmware's with GALAXY_VA_NVENC_RC=firmware; packed headers; 4 L0
//!   references, and B pictures with 1 L1 reference (AV1: 3) only with
//!   GALAXY_VA_NVENC_B=1; up to 16 slices, one AV1 tile), coded buffers
//!   and their segments (CBR's filler),
//!   PutImage, surfaces over an app's dma-bufs (NV12 linear or NVIDIA
//!   block linear, RGB converted on the GPU: enc_rgb.sig), SyncBuffer;
//!   the input read where it lies, the parameter sets and OBU headers
//!   written here, the engine's setup and pushbuffer submitted with
//!   G_ESUBMIT (host-tested against a pretend encoder: enc_test.sig).
//!
//! Untested until a boot (encode): that GB206's NVCFB7 takes Ada's NVC9B7
//! methods and nvenc_drv.h's structs (its magic word, ASSUMED 0xcfb70006,
//! GALAXY_VA_NVENC_MAGIC=hex sets another; the status says BAD_MAGIC when
//! wrong), the input's block height, the codec type numbers for HEVC, the
//! ME/MD tuning, and how many bytes the engine says it wrote. On pc-1111h
//! (GB206) intra pictures encoded and every inter picture failed; the
//! inter setup is now NVIDIA's own driver's (nvenc.meControl), unbooted.
//!
//! Untested until a boot on the PC — everything that touches the real
//! decoder: that GB206's NVCFB0 takes Ada's methods and Ada's
//! nvdec_h264_pic_s (THE main risk: nvdec.sig), that NVDEC writes the
//! Blackwell GOB layouts assumed (GALAXY_VA_GOB=turing for Turing's;
//! tiling.sig), SET_OBJECT's engine field, the scratch buffers' sizes on
//! Blackwell, interlaced (field) streams, the 10-bit setups (output mode
//! 1, strides in samples) and film grain's buffer (av1_grain.sig's
//! ASSUMED fields). GALAXY_VA_DEBUG=1 says on stderr what
//! the driver does and each decode the decoder reports in error.
//!
//! pc-1111c's boot: H.264 decoded on GB206; HEVC, VP9 and AV1 faulted at
//! address 0 on their first picture. Blackwell's extra buffer (method
//! 0x4dc) and setup words, as AROS nvgfx traced NVIDIA's driver
//! (codec.sig), are now sent by default; GALAXY_VA_BLACKWELL,
//! GALAXY_VA_{HEVC,VP9,AV1}_BLACKWELL, GALAXY_VA_CONTROL,
//! GALAXY_VA_VP9_INTRA_TOP and GALAXY_VA_VP9_STREAM_LEN pick the other
//! variants, so one boot can try them all (optionsOf).
//!
//! Build (x86-64 Linux, from the zpm root):
//!   sig build-lib -dynamic -target x86_64-linux-none -OReleaseSafe -fPIC
//!     -fno-stack-protector -fno-unwind-tables -fstrip
//!     --name galaxy_drv_video
//!     --dep gpu --dep gfxapi -Mroot=src/va/libgalaxy_va.sig
//!     --dep gpu --dep adreno --dep nvidia -Mgfxapi=src/gfxapi/gfxapi.sig
//!     --dep nvidia --dep adreno --dep amdgpu -Mgpu=src/gpu/gpu.sig
//!     -Madreno=src/adreno/adreno.sig -Mnvidia=src/nvidia/nvidia.sig
//!     -Mamdgpu=src/amdgpu/amdgpu.sig
//!   (gpu and gfxapi: gpu_convert.sig, the RTX converting a picture for a
//!   CPU reader; the tests run without them, converting on the CPU)

const std = @import("std");
const builtin = @import("builtin");
const va = @import("vaapi.sig");
const driver = @import("driver.sig");
const codec = @import("codec.sig");
const vp9 = @import("vp9.sig");
const node = @import("node.sig");
const linux = std.os.linux;

/// A failed check in the driver: one line on stderr, then the program
/// ends (no stack walk, no thread-local state: nothing of the C library).
pub const panic = if (builtin.os.tag == .linux) std.debug.FullPanic(stop) else std.debug.FullPanic(std.debug.defaultPanic);

fn stop(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;
    const head = "galaxy-va: ";
    _ = linux.write(2, head, head.len);
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
    linux.exit_group(134);
}

// ── The displays ────────────────────────────────────────────────────────────

/// Pictures a CPU reader asks for are converted on the RTX (gpu_convert:
/// a KIR kernel; the build wires the `gpu` and `gfxapi` modules); this
/// file's tests convert on the CPU (convert.Cpu), without those modules.
/// RGB pictures an encode reads (screen captures) are converted on the RTX
/// too (enc_rgb: another KIR kernel, its own GPU context), and VP8 and VP9
/// are encoded there (vpx_gpu: the encoders' kernels, their own GPU
/// context; the CPU runs the same kernels when the GPU cannot).
const Conv = if (builtin.is_test) @import("convert.sig").Cpu else @import("vpx_gpu.sig").WithVpx(
    @import("enc_rgb.sig").WithRgb(
        @import("gpu_convert.sig").Gpu(@import("gfxapi").node.Linux),
        @import("gfxapi").node.Gpu(@import("gfxapi").node.Linux, &.{.sm_120}),
        @import("convert.sig").Say,
        @import("convert.sig").Done,
    ),
    @import("gfxapi").node.Gpu(@import("gfxapi").node.Linux, &.{.sm_120}),
    @import("convert.sig").Say,
);
const D = driver.DriverWith(node.Linux, Conv);

/// A spin lock that yields: each call holds its display's for its length
/// (a sync, for the decode's few milliseconds).
const Lock = struct {
    word: std.atomic.Value(u32) = .init(0),

    fn acquire(l: *Lock) void {
        var spins: u32 = 0;
        while (l.word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins < 64) std.atomic.spinLoopHint() else _ = linux.sched_yield();
        }
    }

    fn release(l: *Lock) void {
        l.word.store(0, .release);
    }
};

const Display = struct {
    lock: Lock = .{},
    d: D,
};

/// vaInitialize's (a process may open a few: Firefox's decoder and its
/// probe each have one).
const MAX_DISPLAYS = 4;
/// (undefined until taken: their tables stay out of the file, in .bss)
var displays: [MAX_DISPLAYS]Display = undefined;
var taken = [_]bool{false} ** MAX_DISPLAYS;
var table_lock: Lock = .{};

fn of(ctx: *va.DriverContext) *Display {
    return @ptrCast(@alignCast(ctx.pDriverData.?));
}

/// libva's entry: the driver for `ctx`'s display, or why not.
pub export fn __vaDriverInit_1_0(ctx: *va.DriverContext) callconv(.c) va.Status {
    table_lock.acquire();
    const i = for (taken, 0..) |t, i| {
        if (!t) break i;
    } else {
        table_lock.release();
        return va.ERROR_ALLOCATION_FAILED;
    };
    taken[i] = true;
    // (the environment read under the table's lock: one buffer for all)
    const opts = options();
    table_lock.release();
    const disp = &displays[i];
    disp.* = .{ .d = .{ .node = .{ .sys = .{} } } };
    const fd: i32 = if (ctx.drm_state) |st| (if (st.fd >= 0) st.fd else -1) else -1;
    const st = disp.d.init(fd, opts);
    const vt = ctx.vtable;
    if (st != va.SUCCESS or vt == null) {
        if (st == va.SUCCESS) disp.d.terminate();
        table_lock.acquire();
        taken[i] = false;
        table_lock.release();
        return if (st == va.SUCCESS) va.ERROR_INVALID_DISPLAY else st;
    }
    fill(vt.?);
    ctx.pDriverData = disp;
    ctx.max_profiles = driver.PROFILES.len;
    ctx.max_entrypoints = 2;
    ctx.max_attributes = 16;
    ctx.max_image_formats = 2;
    ctx.max_subpic_formats = 1;
    ctx.max_display_attributes = 1;
    ctx.str_vendor = driver.VENDOR;
    return va.SUCCESS;
}

/// libva's table, filled.
pub fn fill(vt: *va.DriverVTable) void {
    vt.vaTerminate = @ptrCast(&vaTerminate);
    vt.vaQueryConfigProfiles = @ptrCast(&vaQueryConfigProfiles);
    vt.vaQueryConfigEntrypoints = @ptrCast(&vaQueryConfigEntrypoints);
    vt.vaGetConfigAttributes = @ptrCast(&vaGetConfigAttributes);
    vt.vaCreateConfig = @ptrCast(&vaCreateConfig);
    vt.vaDestroyConfig = @ptrCast(&vaDestroyConfig);
    vt.vaQueryConfigAttributes = @ptrCast(&vaQueryConfigAttributes);
    vt.vaCreateSurfaces = @ptrCast(&vaCreateSurfaces);
    vt.vaDestroySurfaces = @ptrCast(&vaDestroySurfaces);
    vt.vaCreateContext = @ptrCast(&vaCreateContext);
    vt.vaDestroyContext = @ptrCast(&vaDestroyContext);
    vt.vaCreateBuffer = @ptrCast(&vaCreateBuffer);
    vt.vaBufferSetNumElements = @ptrCast(&vaBufferSetNumElements);
    vt.vaMapBuffer = @ptrCast(&vaMapBuffer);
    vt.vaUnmapBuffer = @ptrCast(&vaUnmapBuffer);
    vt.vaDestroyBuffer = @ptrCast(&vaDestroyBuffer);
    vt.vaBeginPicture = @ptrCast(&vaBeginPicture);
    vt.vaRenderPicture = @ptrCast(&vaRenderPicture);
    vt.vaEndPicture = @ptrCast(&vaEndPicture);
    vt.vaSyncSurface = @ptrCast(&vaSyncSurface);
    vt.vaQuerySurfaceStatus = @ptrCast(&vaQuerySurfaceStatus);
    vt.vaQuerySurfaceError = @ptrCast(&unimplemented);
    vt.vaPutSurface = @ptrCast(&unimplemented);
    vt.vaQueryImageFormats = @ptrCast(&vaQueryImageFormats);
    vt.vaCreateImage = @ptrCast(&vaCreateImage);
    vt.vaDeriveImage = @ptrCast(&vaDeriveImage);
    vt.vaDestroyImage = @ptrCast(&vaDestroyImage);
    vt.vaSetImagePalette = @ptrCast(&unimplemented);
    vt.vaGetImage = @ptrCast(&vaGetImage);
    vt.vaPutImage = @ptrCast(&vaPutImage);
    vt.vaQuerySubpictureFormats = @ptrCast(&vaQuerySubpictureFormats);
    vt.vaCreateSubpicture = @ptrCast(&unimplemented);
    vt.vaDestroySubpicture = @ptrCast(&unimplemented);
    vt.vaSetSubpictureImage = @ptrCast(&unimplemented);
    vt.vaSetSubpictureChromakey = @ptrCast(&unimplemented);
    vt.vaSetSubpictureGlobalAlpha = @ptrCast(&unimplemented);
    vt.vaAssociateSubpicture = @ptrCast(&unimplemented);
    vt.vaDeassociateSubpicture = @ptrCast(&unimplemented);
    vt.vaQueryDisplayAttributes = @ptrCast(&vaQueryDisplayAttributes);
    vt.vaGetDisplayAttributes = @ptrCast(&unimplemented);
    vt.vaSetDisplayAttributes = @ptrCast(&unimplemented);
    vt.vaBufferInfo = @ptrCast(&vaBufferInfo);
    vt.vaLockSurface = @ptrCast(&unimplemented);
    vt.vaUnlockSurface = @ptrCast(&unimplemented);
    vt.vaCreateSurfaces2 = @ptrCast(&vaCreateSurfaces2);
    vt.vaQuerySurfaceAttributes = @ptrCast(&vaQuerySurfaceAttributes);
    vt.vaExportSurfaceHandle = @ptrCast(&vaExportSurfaceHandle);
    vt.vaSyncSurface2 = @ptrCast(&vaSyncSurface2);
    vt.vaSyncBuffer = @ptrCast(&vaSyncBuffer);
    vt.vaMapBuffer2 = @ptrCast(&vaMapBuffer2);
}

// ── The options (the process's environment) ─────────────────────────────────

var env_buf: [64 * 1024]u8 = undefined;

/// The options from /proc/self/environ (no C library to ask).
fn options() driver.Options {
    if (comptime builtin.os.tag != .linux) return .{};
    const r: isize = @bitCast(linux.openat(linux.AT.FDCWD, "/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (r < 0) return .{};
    const fd: i32 = @intCast(r);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < env_buf.len) {
        const got: isize = @bitCast(linux.read(fd, env_buf[n..].ptr, env_buf.len - n));
        if (got <= 0) break;
        n += @intCast(got);
    }
    return optionsOf(env_buf[0..n]);
}

/// GALAXY_VA_DEBUG (set and not "0": say things on stderr), GALAXY_VA_GOB
/// ("turing": Turing's GOB layout instead of Blackwell's), GALAXY_VA_PROBE
/// ("0": no decoder probe at init), GALAXY_VA_BLACKWELL and
/// GALAXY_VA_{HEVC,VP9,AV1}_BLACKWELL (Blackwell's additions, codec.Blackwell:
/// "full" or "1" the default, "buffer", "fields", "off" or "0"; a codec's own
/// wins over the common one), GALAXY_VA_CONTROL (HEVC's, VP9's and AV1's
/// control word: "nvk" the default, "prod", "nvidia"), GALAXY_VA_VP9_INTRA_TOP
/// ("0": no intra-top buffer), GALAXY_VA_VP9_STREAM_LEN ("frame" the
/// default, "tiles"), GALAXY_VA_ENCODE ("0": no
/// encode entrypoints), GALAXY_VA_NVENC_MAGIC (hex: the encoder setup's
/// magic word), GALAXY_VA_NVENC_RC ("firmware": the encoder's own rate
/// control), GALAXY_VA_NVENC_B ("1": B pictures on the encoder), from an
/// environment block. Values not understood leave the
/// default.
pub fn optionsOf(block: []const u8) driver.Options {
    var o: driver.Options = .{};
    var all_bw: ?codec.Blackwell = null;
    var hevc_bw: ?codec.Blackwell = null;
    var vp9_bw: ?codec.Blackwell = null;
    var av1_bw: ?codec.Blackwell = null;
    var it = std.mem.splitScalar(u8, block, 0);
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "GALAXY_VA_DEBUG")) {
            o.debug = v.len != 0 and !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_GOB")) {
            o.gob = if (std.ascii.eqlIgnoreCase(v, "turing")) .turing else .blackwell;
        } else if (std.mem.eql(u8, k, "GALAXY_VA_PROBE")) {
            o.probe = !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_BLACKWELL")) {
            all_bw = codec.Blackwell.parse(v);
        } else if (std.mem.eql(u8, k, "GALAXY_VA_HEVC_BLACKWELL")) {
            hevc_bw = codec.Blackwell.parse(v);
        } else if (std.mem.eql(u8, k, "GALAXY_VA_VP9_BLACKWELL")) {
            vp9_bw = codec.Blackwell.parse(v);
        } else if (std.mem.eql(u8, k, "GALAXY_VA_AV1_BLACKWELL")) {
            av1_bw = codec.Blackwell.parse(v);
        } else if (std.mem.eql(u8, k, "GALAXY_VA_CONTROL")) {
            o.control = codec.Control.parse(v) orelse o.control;
        } else if (std.mem.eql(u8, k, "GALAXY_VA_VP9_INTRA_TOP")) {
            o.vp9_intra_top = !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_VP9_STREAM_LEN")) {
            o.vp9_stream_len = vp9.StreamLen.parse(v) orelse o.vp9_stream_len;
        } else if (std.mem.eql(u8, k, "GALAXY_VA_ENCODE")) {
            o.encode = !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_NVENC_MAGIC")) {
            const hex = if (std.mem.startsWith(u8, v, "0x") or std.mem.startsWith(u8, v, "0X")) v[2..] else v;
            o.nvenc_magic = std.fmt.parseInt(u32, hex, 16) catch null;
        } else if (std.mem.eql(u8, k, "GALAXY_VA_NVENC_B")) {
            // ("1": B pictures offered and taken, encode.MAX_REFS)
            o.nvenc_b_frames = std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_NVENC_RC")) {
            // ("firmware": the encoder's own CBR/VBR, enc_rc.sig)
            o.nvenc_rc_firmware = std.ascii.eqlIgnoreCase(v, "firmware");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_VPX_ENCODE")) {
            o.vpx_encode = !std.mem.eql(u8, v, "0");
        } else if (std.mem.eql(u8, k, "GALAXY_VA_VPX_GPU")) {
            o.vpx_gpu = !std.mem.eql(u8, v, "0");
        }
    }
    o.hevc_blackwell = hevc_bw orelse all_bw orelse o.hevc_blackwell;
    o.vp9_blackwell = vp9_bw orelse all_bw orelse o.vp9_blackwell;
    o.av1_blackwell = av1_bw orelse all_bw orelse o.av1_blackwell;
    return o;
}

// ── libva's entry points ────────────────────────────────────────────────────

/// (each one under its display's lock)
fn enter(ctx: *va.DriverContext) *D {
    const disp = of(ctx);
    disp.lock.acquire();
    return &disp.d;
}

fn leave(ctx: *va.DriverContext) void {
    of(ctx).lock.release();
}

fn list(comptime T: type, p: ?[*]T, n: anytype) []T {
    if (n <= 0) return &.{};
    return (p orelse return &.{})[0..@intCast(n)];
}

fn unimplemented(_: *va.DriverContext) callconv(.c) va.Status {
    return va.ERROR_UNIMPLEMENTED;
}

fn vaTerminate(ctx: *va.DriverContext) callconv(.c) va.Status {
    const disp = of(ctx);
    disp.lock.acquire();
    disp.d.terminate();
    disp.lock.release();
    const i = (@intFromPtr(disp) - @intFromPtr(&displays)) / @sizeOf(Display);
    table_lock.acquire();
    taken[i] = false;
    table_lock.release();
    ctx.pDriverData = null;
    return va.SUCCESS;
}

fn vaQueryConfigProfiles(ctx: *va.DriverContext, profiles: ?[*]va.Profile, n: ?*i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.queryConfigProfiles(profiles orelse return va.ERROR_INVALID_PARAMETER, n orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaQueryConfigEntrypoints(ctx: *va.DriverContext, profile: va.Profile, eps: ?[*]va.Entrypoint, n: ?*i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.queryConfigEntrypoints(profile, eps orelse return va.ERROR_INVALID_PARAMETER, n orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaGetConfigAttributes(ctx: *va.DriverContext, profile: va.Profile, ep: va.Entrypoint, attribs: ?[*]va.ConfigAttrib, n: i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.getConfigAttributes(profile, ep, list(va.ConfigAttrib, attribs, n));
}

fn vaCreateConfig(ctx: *va.DriverContext, profile: va.Profile, ep: va.Entrypoint, attribs: ?[*]va.ConfigAttrib, n: i32, out: ?*u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.createConfig(profile, ep, list(va.ConfigAttrib, attribs, n), out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaDestroyConfig(ctx: *va.DriverContext, id: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.destroyConfig(id);
}

fn vaQueryConfigAttributes(ctx: *va.DriverContext, id: u32, profile: ?*va.Profile, ep: ?*va.Entrypoint, attribs: ?[*]va.ConfigAttrib, n: ?*i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    var p: va.Profile = 0;
    var e: va.Entrypoint = 0;
    var count: i32 = 0;
    const st = d.queryConfigAttributes(id, &p, &e, attribs, &count);
    if (profile) |x| x.* = p;
    if (ep) |x| x.* = e;
    if (n) |x| x.* = count;
    return st;
}

fn vaCreateSurfaces(ctx: *va.DriverContext, width: i32, height: i32, format: i32, num: i32, out: ?[*]u32) callconv(.c) va.Status {
    if (width <= 0 or height <= 0) return va.ERROR_INVALID_PARAMETER;
    const d = enter(ctx);
    defer leave(ctx);
    return d.createSurfaces(@bitCast(format), @intCast(width), @intCast(height), list(u32, out, num), &.{});
}

fn vaCreateSurfaces2(ctx: *va.DriverContext, format: u32, width: u32, height: u32, out: ?[*]u32, num: u32, attribs: ?[*]va.SurfaceAttrib, na: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.createSurfaces(format, width, height, list(u32, out, num), list(va.SurfaceAttrib, attribs, na));
}

fn vaDestroySurfaces(ctx: *va.DriverContext, ids: ?[*]u32, n: i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.destroySurfaces(list(u32, ids, n));
}

fn vaQuerySurfaceAttributes(ctx: *va.DriverContext, config: u32, attribs: ?[*]va.SurfaceAttrib, n: ?*u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.querySurfaceAttributes(config, attribs, n orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaCreateContext(ctx: *va.DriverContext, config: u32, width: i32, height: i32, flag: i32, targets: ?[*]u32, n: i32, out: ?*u32) callconv(.c) va.Status {
    _ = flag;
    _ = targets;
    _ = n;
    if (width <= 0 or height <= 0) return va.ERROR_INVALID_PARAMETER;
    const d = enter(ctx);
    defer leave(ctx);
    return d.createContext(config, @intCast(width), @intCast(height), out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaDestroyContext(ctx: *va.DriverContext, id: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.destroyContext(id);
}

fn vaCreateBuffer(ctx: *va.DriverContext, context: u32, kind: u32, size: u32, num: u32, data: ?*const anyopaque, out: ?*u32) callconv(.c) va.Status {
    _ = context;
    const d = enter(ctx);
    defer leave(ctx);
    return d.createBuffer(kind, size, num, data, out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaBufferSetNumElements(ctx: *va.DriverContext, id: u32, num: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.bufferSetNumElements(id, num);
}

fn vaMapBuffer(ctx: *va.DriverContext, id: u32, out: ?*?*anyopaque) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.mapBuffer(id, out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaMapBuffer2(ctx: *va.DriverContext, id: u32, out: ?*?*anyopaque, flags: u32) callconv(.c) va.Status {
    _ = flags;
    return vaMapBuffer(ctx, id, out);
}

fn vaUnmapBuffer(ctx: *va.DriverContext, id: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.unmapBuffer(id);
}

fn vaDestroyBuffer(ctx: *va.DriverContext, id: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.destroyBuffer(id);
}

fn vaBufferInfo(ctx: *va.DriverContext, id: u32, kind: ?*u32, size: ?*u32, num: ?*u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    var k: u32 = 0;
    var s: u32 = 0;
    var c: u32 = 0;
    const st = d.bufferInfo(id, &k, &s, &c);
    if (kind) |x| x.* = k;
    if (size) |x| x.* = s;
    if (num) |x| x.* = c;
    return st;
}

fn vaBeginPicture(ctx: *va.DriverContext, context: u32, surface: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.beginPicture(context, surface);
}

fn vaRenderPicture(ctx: *va.DriverContext, context: u32, ids: ?[*]u32, n: i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.renderPicture(context, list(u32, ids, n));
}

fn vaEndPicture(ctx: *va.DriverContext, context: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.endPicture(context);
}

fn vaSyncSurface(ctx: *va.DriverContext, surface: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.syncSurface(surface, driver.SYNC_NS);
}

fn vaSyncSurface2(ctx: *va.DriverContext, surface: u32, timeout_ns: u64) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    // (VA_TIMEOUT_INFINITE is all ones)
    return d.syncSurface(surface, std.math.cast(i64, timeout_ns) orelse std.math.maxInt(i64));
}

fn vaSyncBuffer(ctx: *va.DriverContext, buf: u32, timeout_ns: u64) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.syncBuffer(buf, std.math.cast(i64, timeout_ns) orelse std.math.maxInt(i64));
}

fn vaQuerySurfaceStatus(ctx: *va.DriverContext, surface: u32, status: ?*u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.querySurfaceStatus(surface, status orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaExportSurfaceHandle(ctx: *va.DriverContext, surface: u32, mem_type: u32, flags: u32, desc: ?*anyopaque) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    const out: *va.DrmPrimeDescriptor = @ptrCast(@alignCast(desc orelse return va.ERROR_INVALID_PARAMETER));
    return d.exportSurfaceHandle(surface, mem_type, flags, out);
}

fn vaQueryImageFormats(ctx: *va.DriverContext, formats: ?[*]va.ImageFormat, n: ?*i32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.queryImageFormats(formats orelse return va.ERROR_INVALID_PARAMETER, n orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaCreateImage(ctx: *va.DriverContext, format: ?*const va.ImageFormat, width: i32, height: i32, out: ?*va.Image) callconv(.c) va.Status {
    if (width <= 0 or height <= 0) return va.ERROR_INVALID_PARAMETER;
    const d = enter(ctx);
    defer leave(ctx);
    return d.createImage(format orelse return va.ERROR_INVALID_PARAMETER, @intCast(width), @intCast(height), out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaDeriveImage(ctx: *va.DriverContext, surface: u32, out: ?*va.Image) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.deriveImage(surface, out orelse return va.ERROR_INVALID_PARAMETER);
}

fn vaDestroyImage(ctx: *va.DriverContext, id: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.destroyImage(id);
}

fn vaGetImage(ctx: *va.DriverContext, surface: u32, x: i32, y: i32, width: u32, height: u32, image: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.getImage(surface, x, y, width, height, image);
}

fn vaPutImage(ctx: *va.DriverContext, surface: u32, image: u32, src_x: i32, src_y: i32, src_w: u32, src_h: u32, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32) callconv(.c) va.Status {
    const d = enter(ctx);
    defer leave(ctx);
    return d.putImage(surface, image, src_x, src_y, src_w, src_h, dst_x, dst_y, dst_w, dst_h);
}

fn vaQuerySubpictureFormats(_: *va.DriverContext, _: ?[*]va.ImageFormat, flags: ?[*]u32, n: ?*u32) callconv(.c) va.Status {
    _ = flags;
    if (n) |x| x.* = 0;
    return va.SUCCESS;
}

fn vaQueryDisplayAttributes(_: *va.DriverContext, _: ?*anyopaque, n: ?*i32) callconv(.c) va.Status {
    if (n) |x| x.* = 0;
    return va.SUCCESS;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "libgalaxy_va: every entry libva 2.22 checks is set" {
    var vt: va.DriverVTable = .{};
    fill(&vt);
    inline for (va.REQUIRED) |name| {
        try testing.expect(@field(vt, name) != null);
    }
    // (and the ones FFmpeg and Firefox use beyond them)
    try testing.expect(vt.vaCreateSurfaces2 != null);
    try testing.expect(vt.vaQuerySurfaceAttributes != null);
    try testing.expect(vt.vaExportSurfaceHandle != null);
    try testing.expect(vt.vaSyncSurface2 != null);
    try testing.expect(vt.vaBufferInfo != null);
    // (and encoding's)
    try testing.expect(vt.vaPutImage != @as(va.Fn, @ptrCast(&unimplemented)));
    try testing.expect(vt.vaSyncBuffer != null);
}

test "libgalaxy_va: options from an environment block" {
    const none = optionsOf("HOME=/root\x00PATH=/bin\x00");
    try testing.expect(!none.debug and none.probe and none.gob == .blackwell);
    const all = optionsOf("GALAXY_VA_DEBUG=1\x00GALAXY_VA_GOB=Turing\x00GALAXY_VA_PROBE=0\x00");
    try testing.expect(all.debug and !all.probe and all.gob == .turing);
    try testing.expect(!optionsOf("GALAXY_VA_DEBUG=0").debug);
    try testing.expect(none.encode and none.nvenc_magic == null);
    const enc = optionsOf("GALAXY_VA_ENCODE=0\x00GALAXY_VA_NVENC_MAGIC=0xc9b70006\x00");
    try testing.expect(!enc.encode);
    try testing.expectEqual(@as(?u32, 0xc9b7_0006), enc.nvenc_magic);
    try testing.expectEqual(@as(?u32, 0xcfb7_0007), optionsOf("GALAXY_VA_NVENC_MAGIC=cfb70007").nvenc_magic);
    // (B pictures on the encoder: off unless GALAXY_VA_NVENC_B=1)
    try testing.expect(!none.nvenc_b_frames);
    try testing.expect(optionsOf("GALAXY_VA_NVENC_B=1").nvenc_b_frames);
    try testing.expect(!optionsOf("GALAXY_VA_NVENC_B=0").nvenc_b_frames);
    // the decode variants: defaults, the common switch, a codec's own over it
    try testing.expect(none.hevc_blackwell == .full and none.vp9_blackwell == .full and none.av1_blackwell == .full);
    try testing.expect(none.control == .nvk and none.vp9_intra_top and none.vp9_stream_len == .frame);
    const v = optionsOf("GALAXY_VA_VP9_BLACKWELL=buffer\x00GALAXY_VA_BLACKWELL=off\x00GALAXY_VA_CONTROL=nvidia\x00GALAXY_VA_VP9_INTRA_TOP=0\x00GALAXY_VA_VP9_STREAM_LEN=tiles\x00");
    try testing.expect(v.hevc_blackwell == .off and v.vp9_blackwell == .buffer and v.av1_blackwell == .off);
    try testing.expect(v.control == .nvidia and !v.vp9_intra_top and v.vp9_stream_len == .tiles);
    try testing.expectEqual(codec.Blackwell.fields, optionsOf("GALAXY_VA_AV1_BLACKWELL=fields").av1_blackwell);
    try testing.expectEqual(codec.Blackwell.off, optionsOf("GALAXY_VA_AV1_BLACKWELL=0").av1_blackwell);
    try testing.expectEqual(codec.Blackwell.full, optionsOf("GALAXY_VA_HEVC_BLACKWELL=bogus").hevc_blackwell);
    try testing.expectEqual(codec.Control.nvk, optionsOf("GALAXY_VA_CONTROL=bogus").control);
    // VP8 and VP9 encoding: on, on the RTX; each switch off by itself
    try testing.expect(none.vpx_encode and none.vpx_gpu);
    const vpx = optionsOf("GALAXY_VA_VPX_GPU=0\x00");
    try testing.expect(vpx.vpx_encode and !vpx.vpx_gpu);
    try testing.expect(!optionsOf("GALAXY_VA_VPX_ENCODE=0\x00").vpx_encode);
}

test "libgalaxy_va: init without Galaxy's RTX fails cleanly" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var vt: va.DriverVTable = .{};
    var ctx = std.mem.zeroes(va.DriverContext);
    ctx.vtable = &vt;
    // (no render node, or one that is not Galaxy's: no G_INFO)
    try testing.expect(__vaDriverInit_1_0(&ctx) != va.SUCCESS);
    try testing.expectEqual(@as(?*anyopaque, null), ctx.pDriverData);
    try testing.expect(vt.vaTerminate == null);
    for (taken) |t| try testing.expect(!t);
}
