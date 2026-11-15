//! @zpm/va enc_rgb — an RGB picture (a screen capture's dma-buf) into an
//! encode surface's NV12 block-linear planes, on the RTX: a KIR compute
//! kernel (zpm src/gpu, sm_120) on a GR channel of Galaxy's render node,
//! before every encode of such a surface. NVENC reads YUV only; the CPU
//! never converts (the driver refuses an RGB import with no GPU
//! converter: enc_import.sig, driver.sig's importSurfaces).
//!
//! The kernel: a thread a 4x2 block of pixels: eight Y samples (BT.601,
//! limited range: libyuv's ARGBToNV12) as two 4-byte words, the block's
//! two 2x2 averages as one UV word (Cb Cr Cb Cr), each stored at its
//! block-linear address (every GOB swizzle keeps aligned 4-byte runs
//! whole; the address math is gfxapi blocklinear.sig's, here in KIR
//! again so this file needs only the `gpu` module). Reads past the
//! picture clamp to its last column and row: the macroblock padding the
//! engine reads repeats the edge, as enc_import.rgbToNv12 (the reference)
//! does.
//!
//! `WithRgb(Inner)` is the shared library's converter: the decode side's
//! (gpu_convert.Gpu) with `rgb` added, over its own GPU context opened at
//! the first RGB picture (`Node`: gfxapi node.Gpu over the render node).
//!
//! Needs the `gpu` module (the shared library's build and
//! `sig test --dep gpu -Mroot=src/va/enc_rgb.sig -Mgpu=src/gpu/gpu.sig`
//! test it); va.sig's tests do not import it.
//!
//! Allocation-free.

const std = @import("std");
const gpu = @import("gpu");
const tiling = @import("tiling.sig");
const enc_import = @import("enc_import.sig");

const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const i = kir.i;

pub const GROUP = 32;

const P_Y_AT = 0;
const P_UV_AT = 1;
const P_PITCH_Y = 2;
const P_PITCH_UV = 3;
const P_SRC_AT = 4;
const P_SRC_PITCH = 5;
const P_QUADS = 6; // 4-pixel columns (the macroblock-aligned width / 4)
const P_PAIRS = 7; // row pairs (the aligned height / 2)
const P_XMAX = 8; // the picture's last column, row
const P_YMAX = 9;
const P_SWZ_Y = 10;
const P_SWZ_UV = 11;
const P_GOBS = 12;
const P_R_SHIFT = 13; // where R and B are in a pixel's word
const P_B_SHIFT = 14;
pub const PARAMS = 15;

const INSTS = 1024;

/// The kernel's KIR and its compiled binary (the compiler's work is the
/// caller's: its size is the backend's).
pub const Scratch = struct {
    insts: [INSTS]kir.Inst = undefined,
    tys: [INSTS]kir.Ty = undefined,
    code: [96 << 10]u8 align(64) = undefined,
};

fn gobOffset(k: *kir.Kernel, swz: Arg, ix: V, iy: V) V {
    const x32 = k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(ix), u(5))), u(8));
    const x16 = k.op3(.bfe, .u32, r(ix), u(4), u(1));
    const xlo = k.op2(.@"and", .u32, r(ix), u(15));
    var t = k.op2(.@"or", .u32, r(x32), r(k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(iy), u(2))), u(7))));
    t = k.op2(.@"or", .u32, r(t), r(k.op2(.shl, .u32, r(x16), u(6))));
    t = k.op2(.@"or", .u32, r(t), r(k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(iy), u(3))), u(4))));
    t = k.op2(.@"or", .u32, r(t), r(xlo));
    var b16 = k.op2(.@"or", .u32, r(x32), r(k.op2(.shl, .u32, r(x16), u(7))));
    b16 = k.op2(.@"or", .u32, r(b16), r(k.op2(.shl, .u32, r(iy), u(4))));
    b16 = k.op2(.@"or", .u32, r(b16), r(xlo));
    var b8 = k.op2(.shl, .u32, r(k.op2(.shr, .u32, r(ix), u(3))), u(6));
    b8 = k.op2(.@"or", .u32, r(b8), r(k.op2(.shl, .u32, r(iy), u(3))));
    b8 = k.op2(.@"or", .u32, r(b8), r(k.op2(.@"and", .u32, r(ix), u(7))));
    const is8 = k.cmp(.u32, .eq, swz, u(@intFromEnum(tiling.Swizzle.blackwell8)));
    const is16 = k.cmp(.u32, .eq, swz, u(@intFromEnum(tiling.Swizzle.blackwell16)));
    return k.sel(.u32, r(is8), r(b8), r(k.sel(.u32, r(is16), r(b16), r(t))));
}

/// Byte `xb` of row `y` of a block-linear plane (`pitch` bytes across,
/// blocks of 2^gobs GOBs, swizzle `swz`), from the plane's first byte.
fn address(k: *kir.Kernel, pitch: Arg, gobs: Arg, swz: Arg, xb: V, y: V) V {
    const across = k.op2(.shr, .u32, pitch, u(6));
    const block_shift = k.op2(.iadd, .u32, gobs, u(3));
    const by = k.op2(.shr, .u32, r(y), r(block_shift));
    const block = k.op3(.imad, .u32, r(by), r(across), r(k.op2(.shr, .u32, r(xb), u(6))));
    const gob_mask = k.op2(.isub, .u32, r(k.op2(.shl, .u32, u(1), gobs)), u(1));
    const gob = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(y), u(3))), r(gob_mask));
    const base = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(block), r(k.op2(.iadd, .u32, gobs, u(9))))), r(k.op2(.shl, .u32, r(gob), u(9))));
    const ix = k.op2(.@"and", .u32, r(xb), u(63));
    const iy = k.op2(.@"and", .u32, r(y), u(7));
    return k.op2(.iadd, .u32, r(base), r(gobOffset(k, swz, ix, iy)));
}

/// (r, g, b) of a pixel word.
fn channels(k: *kir.Kernel, w: V) [3]V {
    const rr = k.op3(.bfe, .u32, r(w), r(k.param(.u32, P_R_SHIFT)), u(8));
    const gg = k.op3(.bfe, .u32, r(w), u(8), u(8));
    const bb = k.op3(.bfe, .u32, r(w), r(k.param(.u32, P_B_SHIFT)), u(8));
    return .{ rr, gg, bb };
}

/// (a*r + b*g + c*b + 128) >> 8, plus `add` (signed).
fn mix(k: *kir.Kernel, c: [3]V, w: [3]i32, add: i32) V {
    var s = k.op3(.imad, .i32, r(c[0]), i(w[0]), i(128));
    s = k.op3(.imad, .i32, r(c[1]), i(w[1]), r(s));
    s = k.op3(.imad, .i32, r(c[2]), i(w[2]), r(s));
    return k.op2(.iadd, .i32, r(k.op2(.shr, .i32, r(s), u(8))), i(add));
}

/// The kernel (verified).
pub fn kernel(s: *Scratch) !kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &s.insts, .tys = &s.tys }, "va_rgb_nv12", .{ GROUP, 1, 1 });
    const dst = k.binding();
    const src = k.binding();
    const qx = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    const qy = k.gid(1);
    const inside = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(qx), r(k.param(.u32, P_QUADS)))), r(k.cmp(.u32, .lt, r(qy), r(k.param(.u32, P_PAIRS)))));
    k.ifp(r(inside));
    {
        const x0 = k.op2(.shl, .u32, r(qx), u(2));
        const y0 = k.op2(.shl, .u32, r(qy), u(1));
        var sums: [2][3]V = undefined;
        for (0..2) |row| {
            const y = k.op2(.iadd, .u32, r(y0), u(@intCast(row)));
            const sy = k.op2(.imin, .u32, r(y), r(k.param(.u32, P_YMAX)));
            const line = k.op3(.imad, .u32, r(sy), r(k.param(.u32, P_SRC_PITCH)), r(k.param(.u32, P_SRC_AT)));
            var word: V = undefined;
            for (0..4) |px| {
                const x = k.op2(.iadd, .u32, r(x0), u(@intCast(px)));
                const sx = k.op2(.imin, .u32, r(x), r(k.param(.u32, P_XMAX)));
                const pw = k.load(.u32, kir.global(src, 32), r(k.op3(.imad, .u32, r(sx), u(4), r(line))));
                const c = channels(&k, pw);
                const luma = mix(&k, c, .{ 66, 129, 25 }, 16);
                word = if (px == 0) luma else k.op2(.@"or", .u32, r(word), r(k.op2(.shl, .u32, r(luma), u(@intCast(8 * px)))));
                // the 2x2 sums for the chroma pairs (px 0-1, 2-3)
                const pair = px / 2;
                for (0..3) |ch| {
                    if (row == 0 and px % 2 == 0) {
                        sums[pair][ch] = c[ch];
                    } else {
                        sums[pair][ch] = k.op2(.iadd, .u32, r(sums[pair][ch]), r(c[ch]));
                    }
                }
            }
            const at = address(&k, r(k.param(.u32, P_PITCH_Y)), r(k.param(.u32, P_GOBS)), r(k.param(.u32, P_SWZ_Y)), x0, y);
            k.store(.u32, kir.global(dst, 32), r(k.op2(.iadd, .u32, r(k.param(.u32, P_Y_AT)), r(at))), r(word));
        }
        var uv: V = undefined;
        for (0..2) |pair| {
            var avg: [3]V = undefined;
            for (0..3) |ch| avg[ch] = k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(sums[pair][ch]), u(2))), u(2));
            const cb = mix(&k, avg, .{ -38, -74, 112 }, 128);
            const cr = mix(&k, avg, .{ 112, -94, -18 }, 128);
            const two = k.op2(.@"or", .u32, r(cb), r(k.op2(.shl, .u32, r(cr), u(8))));
            uv = if (pair == 0) two else k.op2(.@"or", .u32, r(uv), r(k.op2(.shl, .u32, r(two), u(16))));
        }
        const at = address(&k, r(k.param(.u32, P_PITCH_UV)), r(k.param(.u32, P_GOBS)), r(k.param(.u32, P_SWZ_UV)), x0, qy);
        k.store(.u32, kir.global(dst, 32), r(k.op2(.iadd, .u32, r(k.param(.u32, P_UV_AT)), r(at))), r(uv));
    }
    k.endif();
    try k.finish();
    return k;
}

/// The job's parameters and grid.
pub fn params(j: enc_import.RgbJob) struct { p: [PARAMS]u32, groups: [3]u32 } {
    const sw = j.layout.swizzles(j.gob);
    const w = std.mem.alignForward(u32, j.width, 16);
    const h = std.mem.alignForward(u32, j.height, 16);
    const quads = w / 4;
    return .{
        .p = .{ 0, @intCast(j.layout.chroma_offset), j.layout.luma.pitch, j.layout.chroma.pitch, j.src_offset, j.src_pitch, quads, h / 2, j.width - 1, j.height - 1, @intFromEnum(sw[0]), @intFromEnum(sw[1]), tiling.BLOCK_GOBS_LOG2, if (j.order == .bgrx) 16 else 0, if (j.order == .bgrx) 0 else 16 },
        .groups = .{ (quads + GROUP - 1) / GROUP, h / 2, 1 },
    };
}

/// The conversion on `dev` (`dst`, `src` the job's buffers there), waited
/// for.
pub fn runOn(dev: gpu.Device, prog: *const gpu.Program, dst: gpu.Buffer, src: gpu.Buffer, j: enc_import.RgbJob, timeout_us: u64) gpu.Error!void {
    const pj = params(j);
    const bufs = [2]gpu.Buffer{ dst, src };
    const ds = [1]gpu.Dispatch{.{ .prog = prog, .groups = pj.groups, .buffers = &bufs, .params = &pj.p }};
    try dev.runWait(&ds, timeout_us);
}

/// How the driver calls a converter for RGB: `rgb(job, say) Done`.
pub const TIMEOUT_US: u64 = 2_000_000;

/// The shared library's converter: `Inner` (gpu_convert.Gpu) and RGB on
/// the GPU over `Node` (gfxapi node.Gpu over the render node): its
/// context opened at the first RGB picture, the dma-bufs imported there.
/// No GPU: the conversion fails (and the encode with it) — never the CPU.
pub fn WithRgb(comptime Inner: type, comptime Node: type, comptime Say: type, comptime Done: type) type {
    return struct {
        const Self = @This();
        pub const wants_fds = Inner.wants_fds;

        inner: Inner = .{},
        node: Node = undefined,
        state: enum { closed, open, failed } = .closed,
        dev: gpu.Device = undefined,
        prog: gpu.Program = undefined,
        scratch: Scratch = .{},
        work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined,

        pub fn run(c: *Self, j: anytype, say: Say) Done {
            return c.inner.run(j, say);
        }

        fn open(c: *Self, say: Say) bool {
            switch (c.state) {
                .open => return true,
                .failed => return false,
                .closed => {},
            }
            c.node = .{ .node = .{ .sys = .{} } };
            c.dev = c.node.open() catch |e| {
                say.line("no GPU for converting RGB pictures to encode ({s})", .{@errorName(e)});
                c.state = .failed;
                return false;
            };
            const k = kernel(&c.scratch) catch return c.giveUp(say);
            var w = gpu.Work.init(&c.work);
            const bin = Node.compile(&k, c.dev.caps, &w, &c.scratch.code) catch return c.giveUp(say);
            c.prog = c.dev.load(&bin) catch return c.giveUp(say);
            c.state = .open;
            return true;
        }

        fn giveUp(c: *Self, say: Say) bool {
            say.line("the RGB conversion kernel failed to build: RGB pictures are not encoded", .{});
            c.node.close();
            c.state = .failed;
            return false;
        }

        pub fn rgb(c: *Self, j: enc_import.RgbJob, say: Say) Done {
            if (j.dst_fd < 0 or j.src_fd < 0 or !c.open(say)) return .failed;
            const d = c.node.importFd(j.dst_fd) orelse return .failed;
            defer c.dev.free(d);
            const s = c.node.importFd(j.src_fd) orelse return .failed;
            defer c.dev.free(s);
            runOn(c.dev, &c.prog, d, s, j, TIMEOUT_US) catch |e| {
                say.line("an RGB picture's conversion on the GPU failed ({s})", .{@errorName(e)});
                if (e == error.DeviceLost) {
                    c.state = .failed;
                    c.node.close();
                }
                return .failed;
            };
            return .gpu;
        }

        pub fn deinit(c: *Self) void {
            if (c.state == .open) {
                c.dev.unload(&c.prog);
                c.node.close();
            }
            c.state = .closed;
            c.inner.deinit();
        }
    };
}

// ── Tests: the kernel on the interpreter against enc_import.rgbToNv12 ───────

const testing = std.testing;

var emu_mem: [16 << 20]u8 align(4096) = undefined;
var emu_work: [4 << 20]u8 align(64) = undefined;
var test_scratch: Scratch = .{};
var test_work: [48 << 20]u8 align(64) = undefined;
var want: [64 << 10]u8 = undefined;

test "enc_rgb: the KIR kernel on EmuDevice against the CPU's conversion, odd sizes, both orders, both GOB kinds" {
    var e = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    const dev = e.device();
    const k = try kernel(&test_scratch);
    var w = gpu.Work.init(&test_work);
    const bin = try gpu.compileFor(&.{.interp}, &k, dev.caps, &w, &test_scratch.code);
    const prog = try dev.load(&bin);
    defer dev.unload(&prog);
    const shapes = [_][2]u32{ .{ 37, 21 }, .{ 64, 16 }, .{ 130, 33 } };
    for (shapes) |sh| {
        for ([_]tiling.Gob{ .blackwell, .turing, .b8, .b16, .swapped }) |gob| {
            for ([_]enc_import.RgbOrder{ .bgrx, .rgbx }) |order| {
                const layout = tiling.Nv12.of(sh[0], sh[1]);
                const pitch = sh[0] * 4 + 12;
                const src_bytes = pitch * sh[1] + 64;
                const d = try dev.alloc(layout.bytes, .host);
                defer dev.free(d);
                const s = try dev.alloc(src_bytes, .host);
                defer dev.free(s);
                for (s.cpu[0..src_bytes], 0..) |*b, n| b.* = @truncate(n *% 2654435761 >> 11);
                @memset(d.cpu[0..@intCast(layout.bytes)], 0);
                dev.toDevice(s, 0, s.bytes);
                dev.toDevice(d, 0, d.bytes);
                const j = enc_import.RgbJob{ .dst = d.cpu, .layout = layout, .gob = gob, .src = s.cpu, .src_offset = 64, .src_pitch = pitch, .order = order, .width = sh[0], .height = sh[1] };
                try runOn(dev, &prog, d, s, j, 30_000_000);
                dev.fromDevice(d, 0, d.bytes);
                @memset(want[0..@intCast(layout.bytes)], 0);
                var jc = j;
                jc.dst = &want;
                enc_import.rgbToNv12(jc);
                try testing.expectEqualSlices(u8, want[0..@intCast(layout.bytes)], d.cpu[0..@intCast(layout.bytes)]);
            }
        }
    }
}

const Rtx = struct {
    const nvidia = @import("nvidia");
    var arena: [32 << 20]u8 align(4096) = undefined;
    var view: [32 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

test "enc_rgb: the kernel compiled to sm_120 on the emulated RTX against the CPU's conversion" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    const dev = Rtx.dev.device();
    try testing.expectEqual(gpu.Target.sm_120, dev.caps.target);
    const k = try kernel(&test_scratch);
    var w = gpu.Work.init(&test_work);
    const bin = try gpu.compileFor(&.{.sm_120}, &k, dev.caps, &w, &test_scratch.code);
    const prog = try dev.load(&bin);
    defer dev.unload(&prog);
    const layout = tiling.Nv12.of(70, 36);
    const pitch: u32 = 70 * 4;
    const d = try dev.alloc(layout.bytes, .host);
    defer dev.free(d);
    const s = try dev.alloc(pitch * 36, .host);
    defer dev.free(s);
    for (s.cpu[0 .. pitch * 36], 0..) |*b, n| b.* = @truncate(n *% 2246822519 >> 9);
    @memset(d.cpu[0..@intCast(layout.bytes)], 0);
    dev.toDevice(s, 0, s.bytes);
    dev.toDevice(d, 0, d.bytes);
    const j = enc_import.RgbJob{ .dst = d.cpu, .layout = layout, .gob = .blackwell, .src = s.cpu, .src_offset = 0, .src_pitch = pitch, .order = .bgrx, .width = 70, .height = 36 };
    runOn(dev, &prog, d, s, j, 60_000_000) catch |e| {
        if (Rtx.dev.lastError()) |le| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(le), Rtx.dev.explain(&buf) });
        }
        return e;
    };
    dev.fromDevice(d, 0, d.bytes);
    @memset(want[0..@intCast(layout.bytes)], 0);
    var jc = j;
    jc.dst = &want;
    enc_import.rgbToNv12(jc);
    try testing.expectEqualSlices(u8, want[0..@intCast(layout.bytes)], d.cpu[0..@intCast(layout.bytes)]);
}
