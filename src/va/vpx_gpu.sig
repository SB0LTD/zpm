//! @zpm/va vpx_gpu — the VP8 and VP9 encoders' kernels on a GPU (the RTX
//! in the shared library; KIR's interpreter and the emulated RTX in the
//! tests): each kernel built once as KIR (vpx_kir), compiled for the
//! device, and an engine that runs a frame's dispatches there (the same
//! dispatches enc_vp8 hands the CPU's engine).
//!
//! The engine's buffers are the device's: the kernels' memory (frames and
//! source), the macroblock records (host memory: the packer reads them),
//! and the input picture (the surface's own buffer, imported from its
//! dma-buf by the shared library's converter; any buffer in the tests).
//! A frame's dispatches go in runs of at most the device's `max_run`, each
//! waited for (wavefronts are ordered dispatches: the next sees the last's
//! stores).
//!
//! Needs the `gpu` module (with `nvidia` and `adreno` for its backends):
//! the shared library's build and the `test-gfxapi-va-vpx` step; va.sig's
//! tests do not import it. Allocation-free: the kernels' storage, the
//! compiler's work and the binaries are fixed arrays here.

const std = @import("std");
const gpu = @import("gpu");
const dsl = @import("vpx_dsl.sig");
const vk = @import("vpx_kir.sig");
const k8 = @import("vp8_kernels.sig");
const enc_vp8 = @import("enc_vp8.sig");
const k9 = @import("vp9_kernels.sig");
const enc_vp9 = @import("enc_vp9.sig");
const enc_vpx = @import("enc_vpx.sig");

const kir = gpu.kir;

/// The kernels' sizes: instructions (and registers) a kernel may have.
pub const INSTS = 24576;
pub const CODE_BYTES = 1536 << 10;
/// How long a run of dispatches may take.
pub const TIMEOUT_US: u64 = 4_000_000;

/// Building and compiling: the KIR, a binary, and (the caller's size) the
/// compiler's work.
pub const Scratch = struct {
    insts: [INSTS]kir.Inst = undefined,
    tys: [INSTS]kir.Ty = undefined,
    code: [CODE_BYTES]u8 align(64) = undefined,
};

pub const Vp8Kernel = enc_vp8.Kernel;
pub const VP8_KERNELS = std.enums.values(Vp8Kernel).len;

/// The KIR of VP8 kernel `which`, into `s` (finished: verified).
pub fn vp8Kir(s: *Scratch, which: Vp8Kernel) kir.Error!kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &s.insts, .tys = &s.tys }, @tagName(which), .{ dsl.GROUP, 1, 1 });
    switch (which) {
        .load => try vk.build(k8.load, &k, 3, k8.ENC_PARAMS),
        .motion => try vk.build(k8.motion, &k, 3, k8.ENC_PARAMS),
        .encode => try vk.build(k8.encode, &k, 3, k8.ENC_PARAMS),
        .filter => try vk.build(k8.filter, &k, 3, k8.ENC_PARAMS),
    }
    return k;
}

/// VP8's kernels compiled (`compile`: gpu.compile, or a build's narrower
/// one) and loaded on `dev`.
pub fn loadVp8(dev: gpu.Device, s: *Scratch, work: []u8, compile: anytype, out: *[VP8_KERNELS]gpu.Program) !void {
    var made: usize = 0;
    errdefer for (out[0..made]) |*p| dev.unload(p);
    for (std.enums.values(Vp8Kernel), 0..) |which, i| {
        const k = try vp8Kir(s, which);
        var w = gpu.Work.init(work);
        const bin = try compile(&k, dev.caps, &w, &s.code);
        out[i] = try dev.load(&bin);
        made += 1;
    }
}

pub const Vp9Kernel = enc_vp9.Kernel;
pub const VP9_KERNELS = std.enums.values(Vp9Kernel).len;

/// The KIR of VP9 kernel `which`, into `s` (finished: verified).
pub fn vp9Kir(s: *Scratch, which: Vp9Kernel) kir.Error!kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &s.insts, .tys = &s.tys }, @tagName(which), .{ dsl.GROUP, 1, 1 });
    switch (which) {
        .load => try vk.build(k8.load, &k, 3, k9.PARAMS),
        .motion => try vk.build(k9.motion, &k, 3, k9.PARAMS),
        .luma16 => try vk.build(k9.luma16, &k, 3, k9.PARAMS),
        .luma8 => try vk.build(k9.luma8, &k, 3, k9.PARAMS),
        .chroma16 => try vk.build(k9.chroma16, &k, 3, k9.PARAMS),
        .chroma8 => try vk.build(k9.chroma8, &k, 3, k9.PARAMS),
        .lfv => try vk.build(k9.lfv, &k, 3, k9.PARAMS),
        .lfh => try vk.build(k9.lfh, &k, 3, k9.PARAMS),
    }
    return k;
}

/// VP9's kernels compiled and loaded on `dev` (as loadVp8).
pub fn loadVp9(dev: gpu.Device, s: *Scratch, work: []u8, compile: anytype, out: *[VP9_KERNELS]gpu.Program) !void {
    var made: usize = 0;
    errdefer for (out[0..made]) |*p| dev.unload(p);
    for (std.enums.values(Vp9Kernel), 0..) |which, i| {
        const k = try vp9Kir(s, which);
        var w = gpu.Work.init(work);
        const bin = try compile(&k, dev.caps, &w, &s.code);
        out[i] = try dev.load(&bin);
        made += 1;
    }
}

/// The engine of one context: its buffers on the device, a run's
/// dispatches gathered (`n_params` of each dispatch's parameters).
pub fn Engine(comptime K: type, comptime n_kernels: usize, comptime n_params: usize) type {
    return struct {
        const Self = @This();
        pub const MAX_BATCH = 256;

        dev: gpu.Device,
        progs: *const [n_kernels]gpu.Program,
        /// the kernels' bindings: memory, records, the input picture
        bufs: [3]gpu.Buffer,
        n: usize = 0,
        params: [MAX_BATCH][dsl.MAX_PARAMS]u32 = undefined,
        ds: [MAX_BATCH]gpu.Dispatch = undefined,
        dispatches: u64 = 0,

        pub fn dispatch(e: *Self, comptime k: K, threads: u32, params: *const [dsl.MAX_PARAMS]u32) !void {
            const cap = @min(MAX_BATCH, e.dev.caps.max_run);
            if (e.n == cap) try e.flush();
            e.params[e.n] = params.*;
            e.ds[e.n] = .{
                .prog = &e.progs[@intFromEnum(k)],
                .groups = .{ @max(1, (threads + dsl.GROUP - 1) / dsl.GROUP), 1, 1 },
                .buffers = &e.bufs,
                .params = e.params[e.n][0..n_params],
            };
            e.n += 1;
            e.dispatches += 1;
        }

        fn flush(e: *Self) !void {
            if (e.n == 0) return;
            try e.dev.runWait(e.ds[0..e.n], TIMEOUT_US);
            e.n = 0;
        }

        pub fn finish(e: *Self) !void {
            try e.flush();
            e.dev.fromDevice(e.bufs[1], 0, e.bufs[1].bytes);
        }

        pub fn records(e: *Self) []const u8 {
            return e.bufs[1].cpu;
        }
    };
}

pub const Vp8Engine = Engine(Vp8Kernel, VP8_KERNELS, k8.ENC_PARAMS);
pub const Vp9Engine = Engine(Vp9Kernel, VP9_KERNELS, k9.PARAMS);

// ── The shared library's converter, with the encoders' engine ──────────────

/// Contexts the driver may have (driver.MAX_CONTEXTS).
pub const MAX_CONTEXTS = 4;

/// The shared library's converter (`Inner`: the decode side's and RGB's)
/// with VP8 and VP9 encoding added: its own GPU context on the render node
/// (`Node`: gfxapi node.Gpu, opened at the first VP8 or VP9 picture), the
/// kernels compiled once, each context's memory and records on the GPU,
/// the input picture imported from its dma-buf for each frame.
pub fn WithVpx(comptime Inner: type, comptime Node: type, comptime Say: type) type {
    return struct {
        const Self = @This();
        pub const wants_fds = Inner.wants_fds;

        inner: Inner = .{},
        node: Node = undefined,
        state: enum { closed, open, failed } = .closed,
        dev: gpu.Device = undefined,
        /// each codec's kernels: built at its first picture
        built: [2]enum { no, yes, failed } = .{ .no, .no },
        vp8: [VP8_KERNELS]gpu.Program = undefined,
        vp9: [VP9_KERNELS]gpu.Program = undefined,
        scratch: Scratch = .{},
        work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined,
        // (set when the GPU opens: a default with pointers in it would put
        // the whole converter in the library's read-only data)
        ctx: [MAX_CONTEXTS]Ctx = undefined,
        engine8: Vp8Engine = undefined,
        engine9: Vp9Engine = undefined,

        /// A context's buffers on the GPU.
        const Ctx = struct {
            mem: gpu.Buffer = .{},
            info: gpu.Buffer = .{},
            have: bool = false,
        };

        pub fn run(c: *Self, j: anytype, say: Say) @TypeOf(c.inner.run(j, say)) {
            return c.inner.run(j, say);
        }

        pub fn rgb(c: *Self, j: anytype, say: Say) @TypeOf(c.inner.rgb(j, say)) {
            return c.inner.rgb(j, say);
        }

        fn open(c: *Self, say: Say) bool {
            switch (c.state) {
                .open => return true,
                .failed => return false,
                .closed => {},
            }
            c.node = .{ .node = .{ .sys = .{} } };
            c.dev = c.node.open() catch |e| {
                say.line("no GPU for VP8 and VP9 encoding ({s}): the CPU encodes", .{@errorName(e)});
                c.state = .failed;
                return false;
            };
            for (&c.ctx) |*x| x.* = .{};
            c.built = .{ .no, .no };
            c.state = .open;
            return true;
        }

        /// The codec's kernels, built (once) on the open GPU.
        fn kernels(c: *Self, codec: enc_vpx.Codec, say: Say) bool {
            const b = &c.built[@intFromEnum(codec)];
            switch (b.*) {
                .yes => return true,
                .failed => return false,
                .no => {},
            }
            const r = switch (codec) {
                .vp8 => loadVp8(c.dev, &c.scratch, &c.work, Node.compile, &c.vp8),
                .vp9 => loadVp9(c.dev, &c.scratch, &c.work, Node.compile, &c.vp9),
            };
            r catch |e| {
                say.line("the {s} kernels failed to build ({s}): the CPU encodes", .{ @tagName(codec), @errorName(e) });
                b.* = .failed;
                return false;
            };
            b.* = .yes;
            return true;
        }

        fn release(c: *Self, x: *Ctx) void {
            if (x.have) {
                c.dev.free(x.mem);
                c.dev.free(x.info);
            }
            x.* = .{};
        }

        /// Context `slot`'s buffers, `mem` and `info` bytes at least.
        fn buffers(c: *Self, slot: u8, mem: usize, info: usize) ?*Ctx {
            const x = &c.ctx[slot];
            if (x.have and x.mem.bytes >= mem and x.info.bytes >= info) return x;
            c.release(x);
            x.mem = c.dev.alloc(mem, .device) catch return null;
            x.info = c.dev.alloc(info, .host) catch {
                c.dev.free(x.mem);
                return null;
            };
            x.have = true;
            return x;
        }

        pub fn vpxRelease(c: *Self, slot: u8) void {
            if (c.state == .open and slot < MAX_CONTEXTS) c.release(&c.ctx[slot]);
        }

        /// One VP8 or VP9 picture on the GPU (enc_vpx.GpuJob).
        pub fn vpxFrame(c: *Self, slot: u8, job: enc_vpx.GpuJob, say: Say) enc_vpx.GpuDone {
            if (slot >= MAX_CONTEXTS or job.surface_fd < 0 or !c.open(say)) return .unavailable;
            const st = job.state;
            if (!c.kernels(st.codec, say)) return .unavailable;
            switch (st.codec) {
                .vp8 => {
                    const lay = st.vp8.lay;
                    const fresh = !c.ctx[slot].have or c.ctx[slot].mem.bytes < lay.mem_bytes;
                    const x = c.buffers(slot, lay.mem_bytes, lay.info_bytes) orelse return .unavailable;
                    if (job.fresh or fresh) st.vp8.have_last = false;
                    const surf = c.node.importFd(job.surface_fd) orelse return .unavailable;
                    defer c.dev.free(surf);
                    c.engine8 = .{ .dev = c.dev, .progs = &c.vp8, .bufs = .{ x.mem, x.info, surf } };
                    const r = enc_vp8.encodeFrame(&st.vp8, &c.engine8, job.surface, job.plan.vp8, job.out, job.scratch) catch |e| return c.failed(e, say);
                    return .{ .done = r.bytes };
                },
                .vp9 => {
                    const lay = st.vp9.lay;
                    const fresh = !c.ctx[slot].have or c.ctx[slot].mem.bytes < lay.mem_bytes;
                    const x = c.buffers(slot, lay.mem_bytes, lay.info_bytes) orelse return .unavailable;
                    if (job.fresh or fresh) enc_vp9.restart(&st.vp9);
                    const surf = c.node.importFd(job.surface_fd) orelse return .unavailable;
                    defer c.dev.free(surf);
                    c.engine9 = .{ .dev = c.dev, .progs = &c.vp9, .bufs = .{ x.mem, x.info, surf } };
                    const r = enc_vp9.encodeFrame(&st.vp9, &c.engine9, job.surface, job.plan.vp9, job.out, job.scratch) catch |e| return c.failed(e, say);
                    return .{ .done = r.bytes };
                },
            }
        }

        fn failed(c: *Self, e: anyerror, say: Say) enc_vpx.GpuDone {
            if (e == error.NoSpace) return .full;
            say.line("a VP8/VP9 picture failed on the GPU ({s})", .{@errorName(e)});
            if (e == error.DeviceLost) {
                for (&c.ctx) |*x| x.* = .{};
                c.node.close();
                c.state = .failed;
            }
            return .failed;
        }

        pub fn deinit(c: *Self) void {
            if (c.state == .open) {
                for (&c.ctx) |*x| c.release(x);
                if (c.built[0] == .yes) for (&c.vp8) |*p| c.dev.unload(p);
                if (c.built[1] == .yes) for (&c.vp9) |*p| c.dev.unload(p);
                c.node.close();
            }
            c.state = .closed;
            c.inner.deinit();
        }
    };
}

// ── Tests: every kernel on the GPU against the CPU's, byte for byte ─────────

const testing = std.testing;
const tiling = @import("tiling.sig");

/// A test picture: smooth shapes and some texture, moved by (dx, dy).
fn picture(yuv: []u8, w: u32, h: u32, dx: i32, dy: i32) void {
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (0..h) |y| for (0..w) |x| {
        const xx: i32 = @as(i32, @intCast(x)) - dx;
        const yy: i32 = @as(i32, @intCast(y)) - dy;
        var v: i32 = 60 + @divTrunc(xx * 3 + yy * 2, 2);
        if (@mod(@divFloor(xx, 8) + @divFloor(yy, 8), 2) == 0) v += 40;
        v += @mod(xx * 7 + yy * 13, 9);
        yuv[y * w + x] = @intCast(std.math.clamp(v, 0, 255));
    };
    for (0..ch) |y| for (0..cw) |x| {
        yuv[w * h + y * cw + x] = @intCast(100 + (x * 5 + y * 3) % 50);
        yuv[w * h + cw * ch + y * cw + x] = @intCast(140 - (x * 3 + y * 7) % 40);
    };
}

fn toSurface(yuv: []const u8, nv12: []u8, surf: []u8, layout: tiling.Nv12, lin: tiling.Linear, w: u32, h: u32) void {
    @memset(nv12, 0);
    for (0..h) |y| @memcpy(nv12[y * lin.pitch ..][0..w], yuv[y * w ..][0..w]);
    const cw = (w + 1) / 2;
    const ch = (h + 1) / 2;
    for (0..ch) |y| for (0..cw) |x| {
        nv12[lin.uv_offset + y * lin.pitch + 2 * x] = yuv[w * h + y * cw + x];
        nv12[lin.uv_offset + y * lin.pitch + 2 * x + 1] = yuv[w * h + cw * ch + y * cw + x];
    };
    tiling.convertPicture(layout, lin, .blackwell, surf, nv12, w, h, false);
}

var t_yuv: [64 << 10]u8 = undefined;
var t_nv12: [64 << 10]u8 = undefined;
var t_surf: [256 << 10]u8 align(64) = undefined;
var t_mem: [256 << 10]u8 align(64) = undefined;
var t_info: [64 << 10]u8 align(64) = undefined;
var t_out_cpu: [64 << 10]u8 = undefined;
var t_out_gpu: [64 << 10]u8 = undefined;
var t_scratch: [256 << 10]u8 = undefined;
var t_build: Scratch = .{};

/// Encodes `frames` frames of a w x h picture on the CPU and on `dev`,
/// and checks the streams and the reconstructions are the same.
fn vp8Both(dev: gpu.Device, work: []u8, compile: anytype, w: u32, h: u32, frames: u32) !void {
    var progs: [VP8_KERNELS]gpu.Program = undefined;
    try loadVp8(dev, &t_build, work, compile, &progs);
    defer for (&progs) |*p| dev.unload(p);

    const layout = tiling.Nv12.of(w, std.mem.alignForward(u32, h, 128));
    const lin = tiling.Linear.of(w, h);
    const sw = layout.swizzles(.blackwell);
    const surf = enc_vp8.Surface{ .luma = 0, .chroma = @intCast(layout.chroma_offset), .pitch_luma = layout.luma.pitch, .pitch_chroma = layout.chroma.pitch, .swz_luma = @intFromEnum(sw[0]), .swz_chroma = @intFromEnum(sw[1]), .gobs = tiling.BLOCK_GOBS_LOG2 };
    var cpu_enc = try enc_vp8.Encoder.init(w, h);
    var gpu_enc = try enc_vp8.Encoder.init(w, h);
    const L = cpu_enc.lay;
    var cpu = enc_vp8.CpuEngine{ .mem = t_mem[0..L.mem_bytes], .info = t_info[0..L.info_bytes], .surf = t_surf[0..@intCast(layout.bytes)] };
    @memset(cpu.mem, 0);
    @memset(cpu.info, 0);
    const mem = try dev.alloc(L.mem_bytes, .host);
    defer dev.free(mem);
    const info = try dev.alloc(L.info_bytes, .host);
    defer dev.free(info);
    const sbuf = try dev.alloc(layout.bytes, .host);
    defer dev.free(sbuf);
    @memset(mem.cpu, 0);
    @memset(info.cpu, 0);
    dev.toDevice(mem, 0, mem.bytes);
    dev.toDevice(info, 0, info.bytes);
    var g = Vp8Engine{ .dev = dev, .progs = &progs, .bufs = .{ mem, info, sbuf } };
    for (0..frames) |f| {
        picture(&t_yuv, w, h, @intCast(f * 3), @intCast(f));
        toSurface(&t_yuv, &t_nv12, &t_surf, layout, lin, w, h);
        @memcpy(sbuf.cpu[0..@intCast(layout.bytes)], t_surf[0..@intCast(layout.bytes)]);
        dev.toDevice(sbuf, 0, sbuf.bytes);
        const pic = enc_vp8.Picture{ .key = f == 0, .q = 30, .search_range = 4 };
        const a = try enc_vp8.encodeFrame(&cpu_enc, &cpu, surf, pic, &t_out_cpu, &t_scratch);
        const b = try enc_vp8.encodeFrame(&gpu_enc, &g, surf, pic, &t_out_gpu, &t_scratch);
        dev.fromDevice(mem, 0, mem.bytes);
        if (!std.mem.eql(u8, cpu.mem, mem.cpu[0..L.mem_bytes])) {
            for (cpu.mem, 0..) |x, i| if (x != mem.cpu[i]) {
                std.debug.print("frame {d}: memory differs first at {d} (cpu {d}, gpu {d})\n", .{ f, i, x, mem.cpu[i] });
                break;
            };
            return error.Differs;
        }
        try testing.expectEqualSlices(u8, cpu.info, info.cpu[0..L.info_bytes]);
        try testing.expectEqualSlices(u8, t_out_cpu[0..a.bytes], t_out_gpu[0..b.bytes]);
        if (f > 0) try testing.expect(!a.key);
    }
}

/// As vp8Both, for VP9 (`q`: its quantizer index).
fn vp9Both(dev: gpu.Device, work: []u8, compile: anytype, w: u32, h: u32, frames: u32, q: u8) !void {
    var progs: [VP9_KERNELS]gpu.Program = undefined;
    try loadVp9(dev, &t_build, work, compile, &progs);
    defer for (&progs) |*p| dev.unload(p);

    const layout = tiling.Nv12.of(w, std.mem.alignForward(u32, h, 128));
    const lin = tiling.Linear.of(w, h);
    const sw = layout.swizzles(.blackwell);
    const surf = enc_vp9.Surface{ .luma = 0, .chroma = @intCast(layout.chroma_offset), .pitch_luma = layout.luma.pitch, .pitch_chroma = layout.chroma.pitch, .swz_luma = @intFromEnum(sw[0]), .swz_chroma = @intFromEnum(sw[1]), .gobs = tiling.BLOCK_GOBS_LOG2 };
    var cpu_enc = try enc_vp9.Encoder.init(w, h);
    var gpu_enc = try enc_vp9.Encoder.init(w, h);
    const L = cpu_enc.lay;
    var cpu = enc_vp9.CpuEngine{ .mem = t_mem[0..L.mem_bytes], .info = t_info[0..L.info_bytes], .surf = t_surf[0..@intCast(layout.bytes)] };
    @memset(cpu.mem, 0);
    @memset(cpu.info, 0);
    const mem = try dev.alloc(L.mem_bytes, .host);
    defer dev.free(mem);
    const info = try dev.alloc(L.info_bytes, .host);
    defer dev.free(info);
    const sbuf = try dev.alloc(layout.bytes, .host);
    defer dev.free(sbuf);
    @memset(mem.cpu, 0);
    @memset(info.cpu, 0);
    dev.toDevice(mem, 0, mem.bytes);
    dev.toDevice(info, 0, info.bytes);
    var g = Vp9Engine{ .dev = dev, .progs = &progs, .bufs = .{ mem, info, sbuf } };
    for (0..frames) |f| {
        picture(&t_yuv, w, h, @intCast(f * 3), @intCast(f));
        toSurface(&t_yuv, &t_nv12, &t_surf, layout, lin, w, h);
        @memcpy(sbuf.cpu[0..@intCast(layout.bytes)], t_surf[0..@intCast(layout.bytes)]);
        dev.toDevice(sbuf, 0, sbuf.bytes);
        const pic = enc_vp9.Picture{ .key = f == 0, .q = q, .search_range = 6 };
        const a = try enc_vp9.encodeFrame(&cpu_enc, &cpu, surf, pic, &t_out_cpu, &t_scratch);
        const b = try enc_vp9.encodeFrame(&gpu_enc, &g, surf, pic, &t_out_gpu, &t_scratch);
        dev.fromDevice(mem, 0, mem.bytes);
        if (!std.mem.eql(u8, cpu.mem, mem.cpu[0..L.mem_bytes])) {
            for (cpu.mem, 0..) |x, i| if (x != mem.cpu[i]) {
                std.debug.print("vp9 frame {d}: memory differs first at {d} (cpu {d}, gpu {d})\n", .{ f, i, x, mem.cpu[i] });
                break;
            };
            return error.Differs;
        }
        try testing.expectEqualSlices(u8, cpu.info, info.cpu[0..L.info_bytes]);
        try testing.expectEqualSlices(u8, t_out_cpu[0..a.bytes], t_out_gpu[0..b.bytes]);
        if (f > 0) try testing.expect(!a.key and a.inter_blocks > 0);
    }
}

var emu_mem: [24 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;

test "vpx_gpu: VP8's kernels on KIR's interpreter (EmuDevice) encode as the CPU does, byte for byte" {
    var e = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    try vp8Both(e.device(), &compile_work, gpu.compile, 48, 32, 2);
}

const Rtx = struct {
    const nvidia = @import("nvidia");
    var arena: [48 << 20]u8 align(4096) = undefined;
    var view: [48 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

test "vpx_gpu: VP8's kernels compiled to sm_120 on the emulated RTX encode as the CPU does, byte for byte" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    const dev = Rtx.dev.device();
    try testing.expectEqual(gpu.Target.sm_120, dev.caps.target);
    vp8Both(dev, &compile_work, gpu.compile, 48, 32, 2) catch |err| {
        if (Rtx.dev.lastError()) |le| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(le), Rtx.dev.explain(&buf) });
        }
        return err;
    };
}

test "vpx_gpu: VP9's kernels on KIR's interpreter (EmuDevice) encode as the CPU does, byte for byte" {
    var e = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    try vp9Both(e.device(), &compile_work, gpu.compile, 72, 40, 3, 90);
}

test "vpx_gpu: VP9's kernels compiled to sm_120 on the emulated RTX encode as the CPU does, byte for byte" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    const dev = Rtx.dev.device();
    vp9Both(dev, &compile_work, gpu.compile, 72, 40, 3, 90) catch |err| {
        if (Rtx.dev.lastError()) |le| {
            var buf: [512]u8 = undefined;
            std.debug.print("sm120_emu: {s}: {s}\n", .{ @errorName(le), Rtx.dev.explain(&buf) });
        }
        return err;
    };
}

test "vpx_gpu: the kernels' sizes" {
    for (std.enums.values(Vp8Kernel)) |which| {
        const k = try vp8Kir(&t_build, which);
        std.debug.print("vp8 {s}: {d} KIR instructions, {d} registers\n", .{ @tagName(which), k.n, k.nv });
    }
    for (std.enums.values(Vp9Kernel)) |which| {
        const k = try vp9Kir(&t_build, which);
        std.debug.print("vp9 {s}: {d} KIR instructions, {d} registers\n", .{ @tagName(which), k.n, k.nv });
    }
}
