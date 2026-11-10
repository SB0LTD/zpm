//! gfxapi on GPUs: one GL scenario (clears with a scissor and a color
//! mask, a window's top-down BGRA buffer, a texture upload, a framebuffer
//! object, a copy, depth and stencil, reads back) run on the CPU, on
//! EmuDevice (KIR's interpreter; memory not coherent, so a missing cache
//! call fails here), and on the emulated Adreno through Galaxy's calls
//! (node.Fake: KIR compiled to ir3, PM4 streams, ir3_emu). Every run must
//! give the same bytes. Then: batching, frees after the GPU, and a GPU
//! lost mid-batch (the batch done again on the CPU, a reset reported).

const std = @import("std");
const gpu = @import("gpu");
const adreno = @import("adreno");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const g = gfxapi.glenum;
const node = gfxapi.node;

const W = 64;
const H = 32;
const T = 16;

/// What the scenario reads back.
const Out = struct {
    win: [W * H * 4]u8 = undefined,
    tex: [T * T * 4]u8 = undefined,
    copy: [W * H * 4]u8 = undefined,
    depth: [W * H]u32 = undefined,
    errors: u32 = 0,
};

var pool_mem: [4 << 20]u8 align(64) = undefined;
var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;

fn pattern(i: usize) u8 {
    return @truncate(i * 7 + 3);
}

fn noError(c: *gles.Context, out: *Out) void {
    if (c.getError() != g.NO_ERROR) out.errors += 1;
}

/// The scenario, on `eng`.
fn scenario(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();
    // the window: top-down BGRA (a wl_buffer's), and its depth-stencil
    var win = eng.newImage(W, H, .bgra8) orelse return error.OutOfMemory;
    win.top_down = true;
    defer eng.freeImage(&win);
    var depth = eng.newImage(W, H, .d24s8) orelse return error.OutOfMemory;
    defer eng.freeImage(&depth);
    c.setSurface(&win, &win, &depth);

    c.clearColor(0.25, 0.5, 0.75, 1);
    c.clearDepth(0.5);
    c.clearStencil(0x1ff);
    c.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT);
    // a scissored clear writing red, blue and alpha only
    c.enable(g.SCISSOR_TEST, true);
    c.scissorSet(8, 4, 16, 8);
    c.colorMask(true, false, true, true);
    c.clearColor(1, 1, 1, 0.5);
    c.clear(g.COLOR_BUFFER_BIT);
    // stencil only, under a write mask, in a scissor reaching past the window
    c.scissorSet(60, 30, 100, 100);
    c.stencilMaskSeparate(0x0408, 0x0f);
    c.clearStencil(0xa5);
    c.clear(g.STENCIL_BUFFER_BIT);
    c.enable(g.SCISSOR_TEST, false);
    c.colorMask(true, true, true, true);
    noError(c, out);

    // a texture from the CPU, into a framebuffer object, partly cleared
    var src: [T * T * 4]u8 = undefined;
    for (&src, 0..) |*p, i| p.* = pattern(i);
    var tex: [2]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texImage2D(g.TEXTURE_2D, 0, g.RGBA, T, T, 0, g.RGBA, g.UNSIGNED_BYTE, &src);
    // a row of it again, from an unpack layout with a skip
    c.pixelStore(g.UNPACK_SKIP_PIXELS, 2);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, T - 1, 4, 1, g.RGBA, g.UNSIGNED_BYTE, &src);
    c.pixelStore(g.UNPACK_SKIP_PIXELS, 0);
    var fb: [2]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.clearColor(0, 1, 0, 1);
    c.enable(g.SCISSOR_TEST, true);
    c.scissorSet(4, 4, 4, 4);
    c.clear(g.COLOR_BUFFER_BIT);
    c.enable(g.SCISSOR_TEST, false);
    c.readPixels(0, 0, T, T, g.RGBA, g.UNSIGNED_BYTE, &out.tex);
    noError(c, out);

    // the window copied into an immutable texture (a flip and a swap on
    // the way), read back through a second framebuffer object
    c.bindFramebuffer(g.FRAMEBUFFER, 0);
    c.bindTexture(g.TEXTURE_2D, tex[1]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, W, H);
    c.copyTexSubImage2D(g.TEXTURE_2D, 0, 0, 0, 0, 0, W, H);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[1]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[1], 0);
    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, &out.copy);
    // the window itself, through a pack buffer
    c.bindFramebuffer(g.FRAMEBUFFER, 0);
    var pbo: [1]u32 = undefined;
    c.genBuffers(&pbo);
    c.bindBuffer(g.PIXEL_PACK_BUFFER, pbo[0]);
    c.bufferData(g.PIXEL_PACK_BUFFER, W * H * 4 + 16, null, g.STREAM_READ);
    c.readPixels(0, 0, W, H, g.RGBA, g.UNSIGNED_BYTE, @ptrFromInt(16));
    const b = &objs.bufs[pbo[0] - 1];
    @memcpy(&out.win, eng.hostView(&b.store, 16, W * H * 4));
    c.bindBuffer(g.PIXEL_PACK_BUFFER, 0);
    noError(c, out);
    c.finish();
    // depth and stencil as stored (GL has no read of them)
    const d = eng.hostView(&depth, 0, W * H * 4);
    for (&out.depth, 0..) |*x, i| x.* = std.mem.readInt(u32, d[i * 4 ..][0..4], .little);
    c.deleteTextures(&tex);
    c.deleteFramebuffers(&fb);
    c.deleteBuffers(&pbo);
}

fn rgba(o: []const u8, w: usize, x: usize, y: usize) [4]u8 {
    return o[(y * w + x) * 4 ..][0..4].*;
}

/// What the scenario must give, whatever ran it.
fn check(o: *const Out) !void {
    try std.testing.expectEqual(@as(u32, 0), o.errors);
    // the window: the clear (0.25, 0.5, 0.75, 1) -> 64, 128, 191, 255;
    // inside the scissor red, blue and alpha written (255, 255, 128)
    try std.testing.expectEqual([4]u8{ 64, 128, 191, 255 }, rgba(&o.win, W, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 128, 255, 128 }, rgba(&o.win, W, 8, 4));
    try std.testing.expectEqual([4]u8{ 255, 128, 255, 128 }, rgba(&o.win, W, 23, 11));
    try std.testing.expectEqual([4]u8{ 64, 128, 191, 255 }, rgba(&o.win, W, 24, 11));
    try std.testing.expectEqual([4]u8{ 64, 128, 191, 255 }, rgba(&o.win, W, 8, 12));
    // the copy of the window is the window
    try std.testing.expectEqualSlices(u8, &o.win, &o.copy);
    // the texture: the pattern; its top row's first 4 pixels from 2 on;
    // green in the scissor
    try std.testing.expectEqual([4]u8{ pattern(0), pattern(1), pattern(2), pattern(3) }, rgba(&o.tex, T, 0, 0));
    try std.testing.expectEqual([4]u8{ pattern(8), pattern(9), pattern(10), pattern(11) }, rgba(&o.tex, T, 0, T - 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgba(&o.tex, T, 5, 6));
    try std.testing.expectEqual([4]u8{ pattern(4 * 4 * T + 8 * 4), pattern(4 * 4 * T + 8 * 4 + 1), pattern(4 * 4 * T + 8 * 4 + 2), pattern(4 * 4 * T + 8 * 4 + 3) }, rgba(&o.tex, T, 8, 4));
    // depth 0.5 (0x800000: 0.5 * 0xffffff rounded to even), stencil 0xff
    // (0x1ff's low 8 bits); then in the top right 4 x 2 corner (GL rows
    // 30 and 31; the depth image is GL's way up) stencil 0xa5 under the
    // write mask 0x0f: 0xf5
    try std.testing.expectEqual(@as(u32, 0xff80_0000), o.depth[0]);
    try std.testing.expectEqual(@as(u32, 0xf580_0000), o.depth[31 * W + 63]);
    try std.testing.expectEqual(@as(u32, 0xf580_0000), o.depth[30 * W + 60]);
    try std.testing.expectEqual(@as(u32, 0xff80_0000), o.depth[29 * W + 60]);
}

// ── The CPU ────────────────────────────────────────────────────────────────

var eng_cpu: engine.Engine = undefined;
var out_cpu: Out = .{};
var cpu_done = false;

/// The CPU's run (once): what every GPU's must equal.
fn cpuOut() !*const Out {
    if (!cpu_done) {
        eng_cpu.init(.{ .pool = &pool_mem });
        try scenario(&eng_cpu, &out_cpu);
        cpu_done = true;
    }
    return &out_cpu;
}

test "gfxapi: the scenario on the CPU" {
    try check(try cpuOut());
    try std.testing.expectEqual(@as(usize, 0), eng_cpu.pool.n);
    try std.testing.expectEqual(@as(u64, 0), eng_cpu.stats.dispatches);
}

// ── KIR's interpreter (EmuDevice: not coherent) ────────────────────────────

var emu_mem: [4 << 20]u8 align(4096) = undefined;
var emu_shadow: [8 << 20]u8 align(4096) = undefined;
var emu_work: [4 << 20]u8 align(64) = undefined;
var compile_mem: [64 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

fn emuCaps() gpu.Caps {
    var c = gpu.interp_caps;
    c.coherent = false;
    return c;
}

test "gfxapi: the scenario on EmuDevice gives the CPU's bytes, in few batches" {
    const want = try cpuOut();
    emu = gpu.EmuDevice.init(emuCaps(), &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem });
    try std.testing.expect(eng_emu.onGpu());
    try scenario(&eng_emu, &out_emu);
    try check(&out_emu);
    try std.testing.expectEqualSlices(u8, &want.win, &out_emu.win);
    try std.testing.expectEqualSlices(u8, &want.tex, &out_emu.tex);
    try std.testing.expectEqualSlices(u32, &want.depth, &out_emu.depth);
    // every clear and copy ran on the GPU (2 + 1 + 1 window clears, one
    // into the texture, one copy), in batches cut only where the CPU read
    // pixels (twice)
    try std.testing.expectEqual(@as(u64, 6), eng_emu.stats.dispatches);
    try std.testing.expectEqual(@as(u64, 2), eng_emu.stats.batches);
    try std.testing.expectEqual(@as(usize, 0), eng_emu.n_doomed);
    eng_emu.deinit();
}

// ── The emulated Adreno, through Galaxy's calls ───────────────────────────

var a_arena: [16 << 20]u8 align(4096) = undefined;
var a_view: [16 << 20]u8 align(4096) = undefined;
var a_emu: adreno.device.EmuDevice = undefined;
var a_fake: node.Fake = undefined;
const AGpu = node.Gpu(*node.Fake, &.{.ir3_a7xx});
var a_gpu: AGpu = undefined;
var ir3_work: [gpu.kir_ir3.WORK_BYTES]u8 align(64) = undefined;
var eng_a: engine.Engine = undefined;
var out_a: Out = .{};

test "gfxapi: the scenario on the emulated Adreno (ir3, PM4) gives the CPU's bytes" {
    const want = try cpuOut();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    const d = try a_gpu.open();
    try std.testing.expectEqual(gpu.Target.ir3_a7xx, d.caps.target);
    eng_a.init(.{ .dev = d, .compiler = AGpu.compile, .work = &ir3_work });
    if (eng_a.why) |e| std.debug.print("adreno: {s}\n", .{@errorName(e)});
    try std.testing.expect(eng_a.onGpu());
    try scenario(&eng_a, &out_a);
    if (a_emu.last_error) |e| std.debug.print("ir3_emu: {s}: {s}\n", .{ @errorName(e), a_emu.fault.text() });
    try check(&out_a);
    try std.testing.expect(!eng_a.lost);
    try std.testing.expectEqualSlices(u8, &want.win, &out_a.win);
    try std.testing.expectEqualSlices(u8, &want.tex, &out_a.tex);
    try std.testing.expectEqualSlices(u32, &want.depth, &out_a.depth);
    try std.testing.expectEqual(@as(u64, 6), eng_a.stats.dispatches);
    // a window's buffer goes to the compositor as a dma-buf
    const img = eng_a.newImage(W, H, .bgra8).?;
    try std.testing.expect(a_gpu.exportFd(img.buf) >= 100);
    eng_a.deinit();
    a_gpu.close();
}

// ── Frees after the GPU; a GPU lost mid-batch ─────────────────────────────

/// EmuDevice, with runs that fail once `fail` is set (a hang).
const Flaky = struct {
    var inner: gpu.Device = undefined;
    var fail = false;
    /// waits fail (a batch in flight when the GPU is lost)
    var fail_wait = false;
    var runs: u32 = 0;
    var frees: u32 = 0;

    fn device(d: gpu.Device) gpu.Device {
        inner = d;
        return .{ .ctx = d.ctx, .vtable = &vt, .caps = d.caps };
    }
    const vt = gpu.Device.VTable{ .alloc = alloc, .free = free, .import = import, .toDevice = toDev, .fromDevice = fromDev, .load = load, .unload = unload, .run = run, .wait = wait, .done = done, .lastRunNs = ns };
    fn alloc(c: *anyopaque, n: u64, k: gpu.Kind) ?gpu.Buffer {
        return inner.vtable.alloc(c, n, k);
    }
    fn free(c: *anyopaque, b: gpu.Buffer) void {
        frees += 1;
        inner.vtable.free(c, b);
    }
    fn import(c: *anyopaque, cpu: []u8) ?gpu.Buffer {
        return inner.vtable.import(c, cpu);
    }
    fn toDev(c: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        inner.vtable.toDevice(c, b, off, len);
    }
    fn fromDev(c: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        inner.vtable.fromDevice(c, b, off, len);
    }
    fn load(c: *anyopaque, bin: *const gpu.Binary) gpu.Error!gpu.Program {
        return inner.vtable.load(c, bin);
    }
    fn unload(c: *anyopaque, p: *const gpu.Program) void {
        inner.vtable.unload(c, p);
    }
    fn run(c: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        runs += 1;
        if (fail) return error.DeviceLost;
        return inner.vtable.run(c, ds);
    }
    fn wait(c: *anyopaque, f: gpu.Fence, t: u64) gpu.Error!void {
        if (fail_wait) return error.DeviceLost;
        return inner.vtable.wait(c, f, t);
    }
    fn done(c: *anyopaque, f: gpu.Fence) bool {
        if (fail_wait) return false;
        return inner.vtable.done(c, f);
    }
    fn ns(c: *anyopaque) u64 {
        return inner.vtable.lastRunNs(c);
    }
};

var eng_f: engine.Engine = undefined;

test "gfxapi: a buffer a batch still uses is freed after it; a lost GPU's batch is done on the CPU" {
    emu = gpu.EmuDevice.init(emuCaps(), &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    Flaky.fail = false;
    eng_f.init(.{ .dev = Flaky.device(emu.device()), .work = &compile_mem, .pool = &pool_mem });
    try std.testing.expect(eng_f.onGpu());
    var a = eng_f.newImage(16, 4, .rgba8).?;
    var b = eng_f.newImage(16, 4, .rgba8).?;
    // recorded, not run: freeing a waits for the batch, not the CPU
    eng_f.fill(&a, a.bounds(), 0x1111_1111, 0);
    const frees = Flaky.frees;
    eng_f.freeImage(&a);
    try std.testing.expectEqual(frees, Flaky.frees);
    try std.testing.expectEqual(@as(usize, 1), eng_f.n_doomed);
    eng_f.finish();
    try std.testing.expectEqual(frees + 1, Flaky.frees);
    try std.testing.expectEqual(@as(usize, 0), eng_f.n_doomed);
    // the GPU hangs: the batch is done again on the CPU, and the engine stays there
    objs.init();
    ctx.init(&eng_f, &objs);
    defer ctx.deinit();
    // (EGL's LOSE_CONTEXT_ON_RESET: a reset is told)
    ctx.lose_on_reset = true;
    ctx.setSurface(&b, &b, null);
    Flaky.fail = true;
    ctx.clearColor(0, 0, 1, 1);
    ctx.clear(g.COLOR_BUFFER_BIT);
    var px: [4]u8 = undefined;
    ctx.readPixels(15, 3, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, &px);
    try std.testing.expect(eng_f.lost);
    try std.testing.expectEqual(g.UNKNOWN_CONTEXT_RESET, ctx.getGraphicsResetStatus());
    try std.testing.expectEqual(g.NO_ERROR, ctx.getGraphicsResetStatus());
    const runs = Flaky.runs;
    ctx.clearColor(1, 0, 0, 1);
    ctx.clear(g.COLOR_BUFFER_BIT);
    ctx.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, &px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &px);
    try std.testing.expectEqual(runs, Flaky.runs);
    try std.testing.expectEqualStrings("Galaxy (CPU)", std.mem.span(ctx.getString(g.RENDERER).?));
    eng_f.freeImage(&b);
}

var said: [2048]u8 = undefined;
var said_len: usize = 0;

fn sayInto(line: []const u8) void {
    const n = @min(line.len, said.len - said_len);
    @memcpy(said[said_len..][0..n], line[0..n]);
    said_len += n;
}

test "gfxapi: a GPU lost with batches in flight says their kernels: names, code addresses, sizes, grids" {
    const old = gfxapi.report.sink;
    defer gfxapi.report.sink = old;
    gfxapi.report.sink = &sayInto;
    said_len = 0;
    emu = gpu.EmuDevice.init(emuCaps(), &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    Flaky.fail = false;
    Flaky.fail_wait = false;
    defer Flaky.fail_wait = false;
    var eng_l: engine.Engine = undefined;
    eng_l.init(.{ .dev = Flaky.device(emu.device()), .work = &compile_mem, .pool = &pool_mem });
    defer eng_l.deinit();
    try std.testing.expect(eng_l.onGpu());
    var a = eng_l.newImage(64, 8, .rgba8).?;
    var b = eng_l.newImage(64, 8, .rgba8).?;
    // two batches run, neither waited for; then the GPU is lost
    eng_l.fill(&a, a.bounds(), 0x1111_1111, 0);
    eng_l.fill(&b, b.bounds(), 0x2222_2222, 0);
    eng_l.flush();
    eng_l.fill(&a, a.bounds(), 0x3333_3333, 0);
    eng_l.flush();
    Flaky.fail_wait = true;
    eng_l.finish();
    try std.testing.expect(eng_l.lost);
    const out = said[0..said_len];
    const at = std.mem.indexOf(u8, out, "on the GPU then (") orelse {
        std.debug.print("said: {s}\n", .{out});
        return error.NotSaid;
    };
    _ = std.mem.indexOf(u8, out[at..], " not known done): gfx_fill x") orelse {
        std.debug.print("said: {s}\n", .{out});
        return error.NotSaid;
    };
    const line = out[at..][0 .. std.mem.indexOfScalar(u8, out[at..], '\n') orelse out.len - at];
    try std.testing.expect(std.mem.indexOf(u8, line, " regs, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "B shared, up to ") != null);
    // the label is the kernel's, the address its code's
    var hex: [24]u8 = undefined;
    const want = try std.fmt.bufPrint(&hex, "at 0x{x} ", .{eng_l.progs[0].code.gpu});
    try std.testing.expect(std.mem.indexOf(u8, line, want) != null);
    eng_l.freeImage(&a);
    eng_l.freeImage(&b);
}
