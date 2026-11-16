//! @zpm/va gpu_convert — a surface's picture between its block-linear
//! planes and its pitch-linear copy, on the RTX: a KIR compute kernel
//! (zpm src/gpu, compiled to sm_120) run on a GR channel of Galaxy's
//! render node (G_SUBMIT), only when a CPU reader or writer asks
//! (convert.sig says when). The CPU then reads system memory at memory
//! speed instead of VRAM through BAR1, uncached.
//!
//! The kernel: one thread a 4-byte word of a plane's row. Every GOB
//! swizzle keeps runs of 8 or 16 bytes whole and aligned (gfxapi
//! blocklinear.sig), so a linear word is one block-linear word: a load
//! and a store each, the block-linear address computed by blocklinear's
//! `address` (the same code the GL driver samples video planes with). A
//! dispatch a plane (Y, UV), both in one run; the direction a parameter
//! (a branch every lane takes the same way).
//!
//! `Gpu(Sys)` is the shared library's converter (libgalaxy_va.sig): its own
//! GPU context on the render node (gfxapi node.Gpu, opened at the first
//! conversion: a process that never reads a picture on the CPU never opens
//! it), the surface's two buffers imported there from their dma-bufs (the
//! same memory at the same GPU addresses: PRIME), the kernel compiled once.
//! A GPU that cannot be opened, or is lost, leaves the CPU's conversion
//! (convert.onCpu), said once on stderr.
//!
//! This file needs the `gpu` and `gfxapi` modules (with `nvidia`, `adreno`):
//! the shared library's build wires them (galaxy's build-va.sh), and the
//! `test-va-gpu` step tests it on EmuDevice and the emulated RTX. va.sig's
//! tests do not import it.
//!
//! Allocation-free: the kernel's storage, the compiler's work and the
//! binary are fixed arrays here.

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const tiling = @import("tiling.sig");
const convert = @import("convert.sig");

const kir = gpu.kir;
const bl = gfxapi.blocklinear;
const V = kir.V;
const r = kir.r;
const u = kir.u;

/// Threads a group (along a row's words).
pub const GROUP = 64;

// The parameter words (after the two bindings: 0 the block-linear
// buffer, 1 the linear one).
const P_TILED_AT = 0; // the plane's first byte in the block-linear buffer
const P_LINEAR_AT = 1; // ... in the linear one
const P_TILED_PITCH = 2; // bytes across (whole GOBs)
const P_LINEAR_PITCH = 3;
const P_WORDS = 4; // words a row (the plane's bytes across, rounded up)
const P_ROWS = 5;
const P_SWIZZLE = 6; // blocklinear.Swizzle
const P_GOBS_LOG2 = 7;
const P_TO_LINEAR = 8; // 1: block linear to linear; 0: back
pub const PARAMS = 9;

const INSTS = 512;

/// The kernel's KIR, its compiled binary and the compiler's work: kept
/// with the converter (no allocation).
pub const Scratch = struct {
    insts: [INSTS]kir.Inst = undefined,
    tys: [INSTS]kir.Ty = undefined,
    code: [64 << 10]u8 align(64) = undefined,
    work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined,
};

/// The conversion kernel in KIR (finished: verified).
pub fn kernel(s: *Scratch) !kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &s.insts, .tys = &s.tys }, "va_bl_convert", .{ GROUP, 1, 1 });
    const tiled = k.binding();
    const linear = k.binding();
    const xw = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    const y = k.gid(1);
    const inside = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(xw), r(k.param(.u32, P_WORDS)))), r(k.cmp(.u32, .lt, r(y), r(k.param(.u32, P_ROWS)))));
    k.ifp(r(inside));
    {
        const xb = k.op2(.shl, .u32, r(xw), u(2));
        const at = bl.address(&k, r(k.param(.u32, P_TILED_PITCH)), r(k.param(.u32, P_GOBS_LOG2)), r(k.param(.u32, P_SWIZZLE)), r(xb), r(y));
        const t_off = k.op2(.iadd, .u32, r(k.param(.u32, P_TILED_AT)), r(at));
        const l_off = k.op2(.iadd, .u32, r(k.param(.u32, P_LINEAR_AT)), r(k.op3(.imad, .u32, r(y), r(k.param(.u32, P_LINEAR_PITCH)), r(xb))));
        const to_linear = k.cmp(.u32, .ne, r(k.param(.u32, P_TO_LINEAR)), u(0));
        k.ifp(r(to_linear));
        {
            const w = k.load(.u32, kir.global(tiled, 32), r(t_off));
            k.store(.u32, kir.global(linear, 32), r(l_off), r(w));
        }
        k.endif();
        k.ifp(r(k.op1(.pnot, .pred, r(to_linear))));
        {
            const w = k.load(.u32, kir.global(linear, 32), r(l_off));
            k.store(.u32, kir.global(tiled, 32), r(t_off), r(w));
        }
        k.endif();
    }
    k.endif();
    try k.finish();
    return k;
}

/// A plane's parameters and grid.
pub const PlaneJob = struct {
    params: [PARAMS]u32,
    groups: [3]u32,
};

/// The two planes of `j`'s picture as dispatches' parameters (the buffers
/// bound whole: offsets are parameters).
pub fn planes(j: convert.Job) [2]PlaneJob {
    const ext = tiling.planeExtents(j.width, j.height, j.layout.sample_bytes);
    const sw = j.layout.swizzles(j.gob);
    const p = [2]tiling.Plane{ j.layout.luma, j.layout.chroma };
    const t_at = [2]u32{ 0, @intCast(j.layout.chroma_offset) };
    const l_at = [2]u32{ 0, j.lin.uv_offset };
    var out: [2]PlaneJob = undefined;
    for (0..2) |i| {
        const words = (ext[i][0] + 3) / 4;
        out[i] = .{
            .params = .{ t_at[i], l_at[i], p[i].pitch, j.lin.pitch, words, ext[i][1], @intFromEnum(sw[i]), tiling.BLOCK_GOBS_LOG2, @intFromBool(j.dir == .to_linear) },
            .groups = .{ (words + GROUP - 1) / GROUP, ext[i][1], 1 },
        };
    }
    return out;
}

/// The conversion on `dev`: `tiled` and `linear` the job's buffers there,
/// `prog` the loaded kernel. Waited for.
pub fn runOn(dev: gpu.Device, prog: *const gpu.Program, tiled: gpu.Buffer, linear: gpu.Buffer, j: convert.Job, timeout_us: u64) gpu.Error!void {
    const pj = planes(j);
    const bufs = [2]gpu.Buffer{ tiled, linear };
    const ds = [2]gpu.Dispatch{
        .{ .prog = prog, .groups = pj[0].groups, .buffers = &bufs, .params = &pj[0].params },
        .{ .prog = prog, .groups = pj[1].groups, .buffers = &bufs, .params = &pj[1].params },
    };
    try dev.runWait(&ds, timeout_us);
}

// (blocklinear's Swizzle and tiling's in the same order: one code)
comptime {
    std.debug.assert(@intFromEnum(bl.Swizzle.turing2d) == @intFromEnum(tiling.Swizzle.turing2d));
    std.debug.assert(@intFromEnum(bl.Swizzle.blackwell8) == @intFromEnum(tiling.Swizzle.blackwell8));
    std.debug.assert(@intFromEnum(bl.Swizzle.blackwell16) == @intFromEnum(tiling.Swizzle.blackwell16));
}

// ── The shared library's converter ──────────────────────────────────────────

/// How long a conversion may take on the GPU.
pub const TIMEOUT_US: u64 = 2_000_000;

/// The RTX's converter over `Sys`'s render node (gfxapi node.Linux in the
/// shared library).
pub fn Gpu(comptime Sys: type) type {
    const NodeGpu = gfxapi.node.Gpu(Sys, &.{.sm_120});
    return struct {
        const Self = @This();
        pub const wants_fds = true;

        node: NodeGpu = undefined,
        state: enum { closed, open, failed } = .closed,
        dev: gpu.Device = undefined,
        prog: gpu.Program = undefined,
        scratch: Scratch = .{},

        fn open(c: *Self, say: convert.Say) bool {
            switch (c.state) {
                .open => return true,
                .failed => return false,
                .closed => {},
            }
            c.node = .{ .node = .{ .sys = .{} } };
            c.dev = c.node.open() catch |e| {
                say.line("no GPU for converting pictures for the CPU ({s}): the CPU converts", .{@errorName(e)});
                c.state = .failed;
                return false;
            };
            const k = kernel(&c.scratch) catch |e| return c.giveUp(say, "the conversion kernel", e);
            var w = gpu.Work.init(&c.scratch.work);
            const bin = NodeGpu.compile(&k, c.dev.caps, &w, &c.scratch.code) catch |e| return c.giveUp(say, "compiling the conversion kernel", e);
            c.prog = c.dev.load(&bin) catch |e| return c.giveUp(say, "loading the conversion kernel", e);
            c.state = .open;
            return true;
        }

        fn giveUp(c: *Self, say: convert.Say, what: []const u8, e: anyerror) bool {
            say.line("{s} failed ({s}): the CPU converts", .{ what, @errorName(e) });
            c.node.close();
            c.state = .failed;
            return false;
        }

        pub fn run(c: *Self, j: convert.Job, say: convert.Say) convert.Done {
            if (j.tiled_fd >= 0 and j.linear_fd >= 0 and c.open(say)) {
                if (c.onGpu(j, say)) return .gpu;
            }
            convert.onCpu(j);
            return .cpu;
        }

        fn onGpu(c: *Self, j: convert.Job, say: convert.Say) bool {
            const t = c.node.importFd(j.tiled_fd) orelse return false;
            defer c.dev.free(t);
            const l = c.node.importFd(j.linear_fd) orelse return false;
            defer c.dev.free(l);
            runOn(c.dev, &c.prog, t, l, j, TIMEOUT_US) catch |e| {
                say.line("a picture's conversion on the GPU failed ({s})", .{@errorName(e)});
                if (e == error.DeviceLost) {
                    c.state = .failed;
                    c.node.close();
                }
                return false;
            };
            // (the GPU's writes seen by the CPU: system memory, snooped)
            if (j.dir == .to_linear) c.dev.fromDevice(l, 0, l.bytes);
            return true;
        }

        pub fn deinit(c: *Self) void {
            if (c.state == .open) {
                c.dev.unload(&c.prog);
                c.node.close();
            }
            c.state = .closed;
        }
    };
}

// ── Tests: the kernel against tiling.sig's CPU conversion ───────────────────

const testing = std.testing;

/// Converts every shape and swizzle both ways on `dev`, each against
/// tiling.convertPicture.
fn checkOn(dev: gpu.Device, scratch: *Scratch, compile: anytype) !void {
    const k = try kernel(scratch);
    var w = gpu.Work.init(&scratch.work);
    const bin = try compile(&k, dev.caps, &w, &scratch.code);
    const prog = try dev.load(&bin);
    defer dev.unload(&prog);
    const shapes = [_][3]u32{ .{ 37, 21, 1 }, .{ 64, 16, 1 }, .{ 130, 33, 1 }, .{ 37, 21, 2 }, .{ 70, 40, 2 } };
    for (shapes) |sh| {
        for ([_]tiling.Gob{ .blackwell, .turing, .b8, .b16, .swapped }) |gob| {
            const layout = tiling.Nv12.ofDepth(sh[0], sh[1], @intCast(sh[2]));
            const lin = tiling.Linear.ofDepth(sh[0], sh[1], @intCast(sh[2]));
            const t = try dev.alloc(layout.bytes, .host);
            defer dev.free(t);
            const l = try dev.alloc(lin.bytes, .host);
            defer dev.free(l);
            // a picture in the block-linear buffer (every byte distinct-ish)
            for (t.cpu[0..@intCast(layout.bytes)], 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 13);
            @memset(l.cpu[0..lin.bytes], 0xee);
            dev.toDevice(t, 0, t.bytes);
            dev.toDevice(l, 0, l.bytes);
            var j = convert.Job{
                .tiled = .{ .cpu = t.cpu.ptr, .len = t.cpu.len, .handle = 1 },
                .layout = layout,
                .linear = .{ .cpu = l.cpu.ptr, .len = l.cpu.len, .handle = 2 },
                .lin = lin,
                .width = sh[0],
                .height = sh[1],
                .gob = gob,
                .dir = .to_linear,
            };
            try runOn(dev, &prog, t, l, j, 10_000_000);
            dev.fromDevice(l, 0, l.bytes);
            // the CPU's, from the same picture
            var want: [32 << 10]u8 = undefined;
            @memset(want[0..lin.bytes], 0xee);
            tiling.convertPicture(layout, lin, gob, t.cpu, &want, sh[0], sh[1], true);
            const ext = tiling.planeExtents(sh[0], sh[1], @intCast(sh[2]));
            for (0..2) |p| {
                const at: usize = if (p == 0) 0 else lin.uv_offset;
                for (0..ext[p][1]) |y| {
                    const row = at + y * lin.pitch;
                    if (!std.mem.eql(u8, want[row..][0..ext[p][0]], l.cpu[row..][0..ext[p][0]])) {
                        std.debug.print("{d}x{d} ({d} bytes a sample, {s}) plane {d} row {d} differs\n", .{ sh[0], sh[1], sh[2], @tagName(gob), p, y });
                        return error.Differs;
                    }
                }
            }
            // and back: the linear picture into a cleared block-linear one
            @memset(t.cpu[0..@intCast(layout.bytes)], 0);
            dev.toDevice(t, 0, t.bytes);
            j.dir = .to_tiled;
            try runOn(dev, &prog, t, l, j, 10_000_000);
            dev.fromDevice(t, 0, t.bytes);
            var back: [32 << 10]u8 = undefined;
            @memset(back[0..lin.bytes], 0);
            tiling.convertPicture(layout, lin, gob, t.cpu, &back, sh[0], sh[1], true);
            for (0..2) |p| {
                const at: usize = if (p == 0) 0 else lin.uv_offset;
                for (0..ext[p][1]) |y| {
                    const row = at + y * lin.pitch;
                    try testing.expectEqualSlices(u8, want[row..][0..ext[p][0]], back[row..][0..ext[p][0]]);
                }
            }
        }
    }
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_work: [4 << 20]u8 align(64) = undefined;
var test_scratch: Scratch = .{};

test "gpu_convert: the KIR kernel on the interpreter (EmuDevice) against tiling.sig, both ways" {
    var e = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    try checkOn(e.device(), &test_scratch, gpu.compile);
}

const Rtx = struct {
    const nvidia = @import("nvidia");
    var arena: [32 << 20]u8 align(4096) = undefined;
    var view: [32 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

test "gpu_convert: the KIR kernel compiled to sm_120 on the emulated RTX against tiling.sig, both ways" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    const dev = Rtx.dev.device();
    try testing.expectEqual(gpu.Target.sm_120, dev.caps.target);
    checkOn(dev, &test_scratch, gpu.compile) catch |e| {
        if (Rtx.dev.lastError()) |le| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(le), Rtx.dev.explain(&buf) });
        }
        return e;
    };
}

test "gpu_convert: the planes' parameters" {
    const j = convert.Job{
        .tiled = .{},
        .layout = tiling.Nv12.p010(1920, 1080),
        .linear = .{},
        .lin = tiling.Linear.ofDepth(1920, 1080, 2),
        .width = 1920,
        .height = 1080,
        .gob = .blackwell,
        .dir = .to_linear,
    };
    const p = planes(j);
    // Y: 3840 bytes a row (960 words, 15 groups), 1080 rows, Blackwell16;
    // UV: 3840 bytes, 540 rows, Turing's (32-bit texels), at 3840 * 1088
    try testing.expectEqual([3]u32{ 15, 1080, 1 }, p[0].groups);
    try testing.expectEqual(@as(u32, 960), p[0].params[P_WORDS]);
    try testing.expectEqual(@as(u32, @intFromEnum(tiling.Swizzle.blackwell16)), p[0].params[P_SWIZZLE]);
    try testing.expectEqual(@as(u32, 3840 * 1088), p[1].params[P_TILED_AT]);
    try testing.expectEqual(@as(u32, 540), p[1].params[P_ROWS]);
    try testing.expectEqual(@as(u32, @intFromEnum(tiling.Swizzle.turing2d)), p[1].params[P_SWIZZLE]);
    try testing.expectEqual(@as(u32, 1), p[1].params[P_TO_LINEAR]);
}

test "gpu_convert: the shared library's converter compiles over the render node" {
    const G = Gpu(gfxapi.node.Linux);
    try testing.expect(G.wants_fds);
    _ = &G.run;
    _ = &G.deinit;
}
