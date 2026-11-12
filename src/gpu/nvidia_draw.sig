//! @zpm/gpu nvidia_draw — the RTX's 3D engine (nvidia/draw.sig) as a
//! gpu.draw.Renderer: the adapter beside draw.sig, as adreno_draw.sig is
//! the Adreno's.
//!
//! The RTX's renderer has the same calls and types under its own names
//! (zpm's `gpu` module is above `nvidia`, so the RTX's cannot name gpu's):
//! each call here hands its arguments over field for field. The device's
//! memory is the nvidia Device's.
//!
//! Allocation-free: `Over` holds the RTX's renderer and is at a fixed
//! address once init has run (the Renderer points at it).

const std = @import("std");
const nvidia = @import("nvidia");
const draw = @import("draw.sig");
const gpu = @import("device.sig");
const kir = @import("kir.sig");
const kir_sm120 = @import("kir_sm120.sig");
const nvidia_gl = @import("nvidia_gl.sig");

const nv = nvidia.draw;
const model3d = nvidia.emu3d;

pub const Device = nvidia.device.Device;
pub const Options = nv.Options;

pub const Over = struct {
    r: nv.Renderer,
    dev: Device,

    /// Assemble the RTX's programs and take its buffers. `work` is the
    /// assembler's scratch.
    pub fn init(o: *Over, dev: Device, work: *nvidia.sm120_asm.Work, opts: Options) draw.Error!void {
        o.dev = dev;
        o.r.init(dev, work, opts) catch |e| return errOf(e);
    }

    pub fn deinit(o: *Over) void {
        o.r.deinit();
    }

    pub fn renderer(o: *Over) draw.Renderer {
        return .{ .ctx = o, .vtable = &vtable };
    }

    const vtable = draw.Renderer.VTable{
        .begin = &vBegin,
        .scissor = &vScissor,
        .fill = &vFill,
        .image = &vImage,
        .mask = &vMask,
        .rrect = &vRrect,
        .ring = &vRing,
        .imageRR = &vImageRR,
        .maskGradient = &vMaskGradient,
        .glow = &vGlow,
        .shadow = &vShadow,
        .submit = &vSubmit,
        .resubmit = &vResubmit,
        .wait = &vWait,
        .stats = &vStats,
        .alloc = &vAlloc,
        .free = &vFree,
        .toDevice = &vToDevice,
        .fromDevice = &vFromDevice,
    };

    fn of(ctx: *anyopaque) *Over {
        return @ptrCast(@alignCast(ctx));
    }

    fn vBegin(ctx: *anyopaque, t: draw.Target) void {
        of(ctx).r.begin(.{ .va = t.va, .width = t.width, .height = t.height, .pitch = t.pitch, .format = formatOf(t.format) });
    }

    fn vScissor(ctx: *anyopaque, x0: u32, y0: u32, x1: u32, y1: u32) void {
        of(ctx).r.scissor(x0, y0, x1, y1);
    }

    fn vFill(ctx: *anyopaque, rc: draw.Rect, color: draw.Color, b: draw.Blend) void {
        of(ctx).r.fill(rc, color, blendOf(b));
    }

    fn vImage(ctx: *anyopaque, rc: draw.Rect, t: draw.Texture, uv: [4]f32, tint: draw.Color, b: draw.Blend) void {
        of(ctx).r.image(rc, textureOf(t), uv, tint, blendOf(b));
    }

    fn vMask(ctx: *anyopaque, rc: draw.Rect, t: draw.Texture, uv: [4]f32, color: draw.Color, b: draw.Blend) void {
        of(ctx).r.mask(rc, textureOf(t), uv, color, blendOf(b));
    }

    fn vRrect(ctx: *anyopaque, rc: draw.Rect, s: draw.Shape, color: draw.Color, b: draw.Blend) void {
        of(ctx).r.rrect(rc, shapeOf(s), color, blendOf(b));
    }

    fn vRing(ctx: *anyopaque, rc: draw.Rect, outer: draw.Shape, inner: ?draw.Shape, color: draw.Color, b: draw.Blend) void {
        of(ctx).r.ring(rc, shapeOf(outer), if (inner) |s| shapeOf(s) else null, color, blendOf(b));
    }

    fn vImageRR(ctx: *anyopaque, rc: draw.Rect, t: draw.Texture, uv: [4]f32, tint: draw.Color, s: draw.Shape, b: draw.Blend) void {
        of(ctx).r.imageRR(rc, textureOf(t), uv, tint, shapeOf(s), blendOf(b));
    }

    fn vMaskGradient(ctx: *anyopaque, rc: draw.Rect, t: draw.Texture, uv: [4]f32, g: draw.Gradient, opacity: f32, b: draw.Blend) void {
        of(ctx).r.maskGradient(rc, textureOf(t), uv, .{ .q1 = g.q1, .q2 = g.q2, .along = g.along, .around = g.around, .a = g.a, .b = g.b, .c = g.c, .mid = g.mid }, opacity, blendOf(b));
    }

    fn vGlow(ctx: *anyopaque, rc: draw.Rect, cx: f32, cy: f32, inner: f32, outer: f32, color: draw.Color, b: draw.Blend) void {
        of(ctx).r.glow(rc, cx, cy, inner, outer, color, blendOf(b));
    }

    fn vShadow(ctx: *anyopaque, rc: draw.Rect, s: draw.Shape, sigma: f32, color: draw.Color, deep: draw.Deep, b: draw.Blend) void {
        of(ctx).r.shadow(rc, shapeOf(s), sigma, color, .{ .from_x = deep.from_x, .above = deep.above, .below = deep.below, .left = deep.left, .right = deep.right, .step = deep.step, .run_from = deep.run_from, .run_end = deep.run_end }, blendOf(b));
    }

    fn vSubmit(ctx: *anyopaque) draw.Error!draw.Fence {
        return of(ctx).r.submit() catch |e| errOf(e);
    }

    fn vResubmit(ctx: *anyopaque) draw.Error!draw.Fence {
        return of(ctx).r.resubmit() catch |e| errOf(e);
    }

    fn vWait(ctx: *anyopaque, f: draw.Fence, timeout_us: u64) draw.Error!void {
        of(ctx).dev.wait(f, timeout_us) catch |e| return errOf(e);
    }

    fn vStats(ctx: *anyopaque) draw.Stats {
        const s = of(ctx).r.stats;
        return .{ .rects = s.rects, .programs = s.programs, .bindings = s.bindings, .stream_dwords = s.stream_dwords };
    }

    fn vAlloc(ctx: *anyopaque, size: usize) ?draw.Buffer {
        const b = of(ctx).dev.alloc(size) catch return null;
        return .{ .va = b.va, .cpu = b.cpu, .handle = b.handle };
    }

    fn vFree(ctx: *anyopaque, b: draw.Buffer) void {
        of(ctx).dev.free(.{ .va = b.va, .cpu = b.cpu, .handle = b.handle });
    }

    fn vToDevice(ctx: *anyopaque, b: draw.Buffer, offset: usize, len: usize) void {
        of(ctx).dev.toDevice(.{ .va = b.va, .cpu = b.cpu, .handle = b.handle }, offset, len);
    }

    fn vFromDevice(ctx: *anyopaque, b: draw.Buffer, offset: usize, len: usize) void {
        of(ctx).dev.fromDevice(.{ .va = b.va, .cpu = b.cpu, .handle = b.handle }, offset, len);
    }
};

fn formatOf(f: draw.Format) nv.Format {
    return switch (f) {
        .rgba8 => .rgba8,
        .bgra8 => .bgra8,
        .r8 => .r8,
    };
}

fn blendOf(b: draw.Blend) nv.Blend {
    return switch (b) {
        .replace => .replace,
        .over => .over,
    };
}

fn textureOf(t: draw.Texture) nv.Texture {
    return .{
        .va = t.va,
        .width = t.width,
        .height = t.height,
        .pitch = t.pitch,
        .format = formatOf(t.format),
        .filter = if (t.filter == .linear) .linear else .nearest,
        .no_alpha = t.no_alpha,
    };
}

fn shapeOf(s: draw.Shape) nv.Shape {
    return .{ .cx = s.cx, .cy = s.cy, .kx = s.kx, .ky = s.ky, .rad = s.rad };
}

/// The RTX renderer's errors as the interface's (the assembler's own,
/// which only init can give, are a kernel that is not right).
fn errOf(e: anyerror) draw.Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.SubmitFailed => error.SubmitFailed,
        error.Timeout => error.Timeout,
        error.DeviceLost => error.DeviceLost,
        error.BadStream => error.BadStream,
        error.StreamFull => error.StreamFull,
        error.StateFull => error.StateFull,
        error.NoPass => error.NoPass,
        else => error.BadKernel,
    };
}

/// The interface's self-test on the RTX: the renderer started on `dev`
/// (in `o`, the caller's storage), draw.selfTest's cases, then its
/// buffers given back.
pub fn selfTest(dev: Device, o: *Over, work: *nvidia.sm120_asm.Work, log: draw.Log, now_us: ?*const fn () u64) draw.SelfTest {
    o.init(dev, work, .{ .stream_bytes = 64 * 1024, .rects = 256, .textures = 31 }) catch |e| {
        var buf: [120]u8 = undefined;
        log(std.fmt.bufPrint(&buf, "draw self-test: the renderer did not start ({s})", .{@errorName(e)}) catch "draw self-test: the renderer did not start");
        return .{ .failed = 1 };
    };
    defer o.deinit();
    return draw.selfTest(o.renderer(), log, now_us);
}

// ── On the hardware: the 3D engine step by step, each pass the CPU's too ────
// What Galaxy runs on the Legion's RTX (NV.TXT `drawtest`), on a channel of
// its own: first the 3D engine's object alone, then its whole state with no
// draw, then each of the interface's cases in a pass of its own, its whole
// target compared with the CPU reference's (draw.Reference) pixel for
// pixel, then the fill rate. A step that does not finish ends the test
// (its channel is gone); each line names what it was, so the kernel log
// alone says how far the engine got and what it drew differently.

/// What hardwareTest found.
pub const Hardware = struct {
    /// The renderer started (its programs assembled, its buffers taken).
    started: bool = false,
    /// SET_OBJECT BLACKWELL_B alone ran to its fence.
    object: bool = false,
    /// The whole state and the target, no draw, ran to its fence.
    state: bool = false,
    passed: u32 = 0,
    failed: u32 = 0,
    /// A pass did not finish (a timeout, the channel lost): nothing after
    /// it ran.
    lost: bool = false,
    /// The fill rate (megapixels a second; 0: not measured).
    mpx_per_s: u32 = 0,
    /// The slowest case's pass, submit to fence (us).
    slowest_us: u64 = 0,
    /// Step 4 (edges): the scenes drawn, and over them the pixels the 3D
    /// engine covered otherwise than the compute path's rule, the pixels
    /// both covered whose depth words differ, and the pixels whose depth
    /// EQUAL test against the compute path's depths went otherwise.
    edge_scenes: u32 = 0,
    edge_cover_apart: u32 = 0,
    edge_depth_apart: u32 = 0,
    edge_equal_apart: u32 = 0,
    /// Step 4 did not get to draw (a program did not compile, no memory).
    edge_skipped: bool = false,
};

pub const Clock = *const fn () u64;

/// A pass may take this long before the test calls it lost (a pass is a
/// few rectangles: microseconds on the RTX).
pub const STEP_US: u64 = 2_000_000;
/// A case passes when no byte of its target is further than this from the
/// CPU's (of 255): the texture unit's filter weights have 8 bits.
pub const TOL: u8 = 3;
/// What the target holds before each case: a pixel no case leaves, so one
/// the engine did not write shows.
pub const POISON: u8 = 0xcd;

fn hsay(log: draw.Log, comptime fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    log(std.fmt.bufPrint(&buf, "draw: " ++ fmt, args) catch "draw: (a line too long)");
}

/// Pixels of two targets (`bytes` each, 4 a pixel) further apart than
/// `tol` in a byte: how many, the first, the largest difference.
pub const Diff = struct { count: u32 = 0, first: ?usize = null, largest: u8 = 0 };

pub fn compare(a: []const u8, b: []const u8, tol: u8) Diff {
    var d: Diff = .{};
    var i: usize = 0;
    while (i + 4 <= a.len and i + 4 <= b.len) : (i += 4) {
        var worst: u8 = 0;
        for (0..4) |k| {
            const x = a[i + k];
            const y = b[i + k];
            worst = @max(worst, if (x > y) x - y else y - x);
        }
        d.largest = @max(d.largest, worst);
        if (worst > tol) {
            if (d.first == null) d.first = i / 4;
            d.count += 1;
        }
    }
    return d;
}

fn word(b: []const u8, px: usize) u32 {
    return std.mem.readInt(u32, b[px * 4 ..][0..4], .little);
}

/// The test on `dev` (a channel the 3D engine's object is on), in `o` (the
/// caller's storage); `model` is the CPU's reference, with 64 KiB of
/// memory or more.
/// `kst`: kir_sm120's scratch (WORK_BYTES), the renderer's assembler's
/// too (kst.asm_work). `gd`: gpu/nvidia_device's adapter over the same
/// channel with graphics dispatches (Caps.graphics), for step 4 (edges):
/// it draws as galaxy-gl's GL draws go (gl3d's state, nvidia_gl's
/// programs); null, step 4 is not run.
pub fn hardwareTest(dev: Device, gd: ?gpu.Device, o: *Over, kst: *kir_sm120.State, model: *draw.Reference, log: draw.Log, now_us: Clock) Hardware {
    var res: Hardware = .{};
    const work = &kst.asm_work;
    o.init(dev, work, .{ .stream_bytes = 64 * 1024, .rects = 256, .textures = 31 }) catch |e| {
        hsay(log, "the renderer did not start ({s}): nothing sent", .{@errorName(e)});
        return res;
    };
    defer o.deinit();
    res.started = true;
    const rtx = o.renderer();
    hsay(log, "the renderer is up: {d} programs (2 vertex, {d} pixel) at 0x{x}, records at 0x{x}, pushbuffer at 0x{x}", .{ nv.KINDS + 2, nv.KINDS, o.r.code.va, o.r.records.va, o.r.pb.va });

    // 1. The 3D engine's object bound to its subchannel, nothing else.
    {
        var p = nvidia.push.Push{ .buf = o.r.pb.words() };
        p.setObject(nv.SUBCH, nv.BLACKWELL_B);
        const t0 = now_us();
        dev.run(o.r.pb, @intCast(p.len), STEP_US) catch |e| {
            hsay(log, "step 1, SET_OBJECT BLACKWELL_B (0x{x}) on subchannel {d}: FAILED ({s} after {d} us): the channel did not take the 3D engine's object", .{ nv.BLACKWELL_B, nv.SUBCH, @errorName(e), now_us() - t0 });
            res.lost = true;
            return res;
        };
        res.object = true;
        hsay(log, "step 1, SET_OBJECT BLACKWELL_B (0x{x}) on subchannel {d}: done in {d} us", .{ nv.BLACKWELL_B, nv.SUBCH, now_us() - t0 });
    }

    const bytes = draw.CASE_W * draw.CASE_H * 4;
    const pixels = rtx.alloc(bytes) orelse {
        hsay(log, "no memory for the target", .{});
        res.failed = 1;
        return res;
    };
    defer rtx.free(pixels);
    const tex_buf = rtx.alloc(draw.CaseTextures.BYTES) orelse {
        hsay(log, "no memory for the textures", .{});
        res.failed = 1;
        return res;
    };
    defer rtx.free(tex_buf);
    const tex = draw.CaseTextures.fill(tex_buf);
    rtx.toDevice(tex_buf, 0, draw.CaseTextures.BYTES);
    const t = draw.Target{ .va = pixels.va, .width = draw.CASE_W, .height = draw.CASE_H, .pitch = draw.CASE_W * 4, .format = .bgra8 };

    // 2. The engine's whole state and the target, no draw: the target
    // must come back as it went.
    {
        @memset(pixels.cpu[0..bytes], POISON);
        rtx.toDevice(pixels, 0, bytes);
        rtx.begin(t);
        const t0 = now_us();
        rtx.run(STEP_US) catch |e| {
            hsay(log, "step 2, the engine's state ({d} dwords: the pools, the stages off, the target at 0x{x}), no draw: FAILED ({s} after {d} us)", .{ o.r.stats.stream_dwords, t.va, @errorName(e), now_us() - t0 });
            res.lost = true;
            return res;
        };
        res.state = true;
        rtx.fromDevice(pixels, 0, bytes);
        const p0 = word(pixels.cpu, 0);
        hsay(log, "step 2, the engine's state ({d} dwords), no draw: done in {d} us; the target {s} (first pixel {x:0>8})", .{ o.r.stats.stream_dwords, now_us() - t0, if (p0 == 0xcdcdcdcd) "untouched, as it should be" else "CHANGED, though nothing was drawn", p0 });
    }

    // 3. The cases, each against the CPU's.
    for (draw.cases, 1..) |c, n| {
        @memset(pixels.cpu[0..bytes], POISON);
        rtx.toDevice(pixels, 0, bytes);
        draw.record(rtx, t, tex, c);
        const t0 = now_us();
        rtx.run(STEP_US) catch |e| {
            const st = rtx.stats();
            hsay(log, "case {d} '{s}': FAILED: the pass did not finish ({s} after {d} us; {d} rectangles, {d} dwords): the cases after it are not run", .{ n, c.name, @errorName(e), now_us() - t0, st.rects, st.stream_dwords });
            res.failed += 1;
            res.lost = true;
            break;
        };
        const us = now_us() - t0;
        res.slowest_us = @max(res.slowest_us, us);
        rtx.fromDevice(pixels, 0, bytes);
        // (the same pass on the CPU)
        model.reset();
        const m = model.renderer();
        const mp = m.alloc(bytes) orelse {
            hsay(log, "the reference has no memory: not compared", .{});
            res.failed += 1;
            continue;
        };
        const mt = m.alloc(draw.CaseTextures.BYTES) orelse {
            hsay(log, "the reference has no memory: not compared", .{});
            res.failed += 1;
            continue;
        };
        const mtex = draw.CaseTextures.fill(mt);
        draw.record(m, .{ .va = mp.va, .width = t.width, .height = t.height, .pitch = t.pitch, .format = t.format }, mtex, c);
        m.run(STEP_US) catch {};
        const st = rtx.stats();
        const d = compare(pixels.cpu[0..bytes], mp.cpu[0..bytes], TOL);
        if (d.first) |at| {
            res.failed += 1;
            const row = at - at % draw.CASE_W;
            hsay(log, "case {d} '{s}': FAILED in {d} us: {d} of {d} pixels differ from the CPU's by more than {d} of 255 (most {d}); the first at ({d}, {d}): the RTX {x:0>8}, the CPU {x:0>8}; that row's first pixels: the RTX {x:0>8} {x:0>8} {x:0>8} {x:0>8}, the CPU {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{
                n,                     c.name,                    us,                        d.count,                   draw.CASE_W * draw.CASE_H, TOL, d.largest, at % draw.CASE_W, at / draw.CASE_W, word(pixels.cpu, at), word(mp.cpu, at),
                word(pixels.cpu, row), word(pixels.cpu, row + 1), word(pixels.cpu, row + 2), word(pixels.cpu, row + 3), word(mp.cpu, row),         word(mp.cpu, row + 1), word(mp.cpu, row + 2), word(mp.cpu, row + 3),
            });
        } else {
            res.passed += 1;
            hsay(log, "case {d} '{s}': PASS in {d} us ({d} rectangles, {d} dwords; at most {d} of 255 from the CPU's)", .{ n, c.name, us, st.rects, st.stream_dwords, d.largest });
        }
    }

    // 4. The rasterizers side by side (edges), before the fill rate's big
    // buffers.
    if (!res.lost) {
        if (gd) |d| edges(d, kst, log, now_us, &res) else res.edge_skipped = true;
    }

    // 5. How fast it fills: a 1024 x 1024 target, an image the same size
    // over it once and a half-transparent color 31 times (32 megapixels
    // blended), as draw.selfTest measures it.
    if (!res.lost and res.failed == 0) speed: {
        const N = 1024;
        const big = rtx.alloc(N * N * 4) orelse {
            hsay(log, "the fill rate: no memory for it, not measured", .{});
            break :speed;
        };
        defer rtx.free(big);
        const src = rtx.alloc(N * N * 4) orelse {
            hsay(log, "the fill rate: no memory for it, not measured", .{});
            break :speed;
        };
        defer rtx.free(src);
        for (0..N * N) |i| std.mem.writeInt(u32, src.cpu[i * 4 ..][0..4], 0xff000000 | @as(u32, @truncate(i *% 2654435761)), .little);
        rtx.toDevice(src, 0, N * N * 4);
        rtx.begin(.{ .va = big.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8 });
        rtx.image(.{ 0, 0, N, N }, .{ .va = src.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8, .filter = .linear }, .{ 0, 0, N, N }, .{ 1, 1, 1, 1 }, .replace);
        for (0..31) |_| rtx.fill(.{ 0, 0, N, N }, .{ 0.01, 0.01, 0.01, 0.02 }, .over);
        const t0 = now_us();
        rtx.run(5 * STEP_US) catch |e| {
            hsay(log, "the fill rate: the pass did not finish ({s})", .{@errorName(e)});
            res.lost = true;
            break :speed;
        };
        const us = @max(now_us() - t0, 1);
        res.mpx_per_s = @intCast(@min(@as(u64, 32) * N * N / us, std.math.maxInt(u32)));
        rtx.fromDevice(big, 0, 16);
        hsay(log, "the fill rate: 32 megapixels blended in {d} us, {d} megapixels a second (first pixel {x:0>8})", .{ us, res.mpx_per_s, word(big.cpu, 0) });
    }
    hsay(log, "{d} of {d} cases passed, {d} failed{s}", .{ res.passed, draw.cases.len, res.failed, if (res.lost) "; a pass did not finish" else "" });
    if (res.edge_scenes != 0) hsay(log, "edges: {d} scenes; against the compute path's rule: {d} pixels covered otherwise, {d} depths apart, {d} depth EQUAL tests otherwise: {s}", .{ res.edge_scenes, res.edge_cover_apart, res.edge_depth_apart, res.edge_equal_apart, if (res.edge_cover_apart + res.edge_depth_apart + res.edge_equal_apart == 0) "the 3D engine IS the model (1/256 grid, top-left rule, depth plane): draws may be split between it and the compute kernels" else "the 3D engine is NOT the model: the lines above say where" });
    return res;
}

// ── 4. The 3D engine's edges and depth against the compute path's ──────────
// A frame can mix draws on the 3D engine and on gfxapi's compute raster
// (draws the engine does not take fall back), so the two must cover each
// edge's pixels alike and give them the same depth bits. gfxapi's raster
// and emu3d share one model of the engine (emu3d.windowOf, planeOf,
// edge/inside, depthWord: the 1/256 grid rounded to nearest even, the
// top-left rule in the engine's rows, depth as an f32 plane over the
// pixel centres): tests/test_gfxapi_draw.sig holds the compute kernels to
// it bit for bit. Here the real engine draws the same scenes as that
// test: two triangles sharing an edge (through pixel centres, and off any
// grid coarser than 1/256), corners at different depths, rows up and
// flipped, added ONE + ONE with depth LESS (written); its target and its
// depth (S8Z24, block linear) come back and are put beside the model's
// pixel for pixel, exactly. Then the model's depths go into the depth
// target and the engine draws the scene again with depth EQUAL (not
// written): it draws exactly the pixels whose depth it makes the same as
// the compute path does.

const EW = 64;
const EH = 32;
/// The depth target's blocks: 4 GOBs (32 rows), its pitch 256 bytes.
const E_GOBS: u3 = 2;
const E_PITCH = EW * 4;
const E_DEPTH_BYTES = (E_PITCH / 64) * ((EH + 31) / 32) * (512 << E_GOBS);
/// The quads, in pixels (x right, y the target's rows), and their
/// corners' clip z.
const edge_scenes = [_]struct { name: []const u8, pts: [4][2]f32 }{
    .{ .name = "a 45-degree edge through pixel centres", .pts = .{ .{ 8, 4 }, .{ 32, 4 }, .{ 32, 28 }, .{ 8, 28 } } },
    .{ .name = "off-grid corners", .pts = .{ .{ 5.37, 3.11 }, .{ 58.93, 6.71 }, .{ 52.18, 29.42 }, .{ 9.66, 26.05 } } },
    .{ .name = "steep, sub-pixel corners", .pts = .{ .{ 40.5, 2.25 }, .{ 61.0078125, 30.0039 }, .{ 12.25, 30.5 }, .{ 3.1, 1.9 } } },
};
const edge_z = [4]f32{ -0.3, 0.2117, 0.7, 0.0931 };

/// What the model gives a scene: each pixel's hits (0, 1; 2 would be a
/// pixel drawn twice) and depth word (0xffffff: none).
const EdgeModel = struct { hits: [EW * EH]u8 = undefined, z: [EW * EH]u32 = undefined };

const E = struct {
    var insts: [256]kir.Inst = undefined;
    var tys: [512]kir.Ty = undefined;
    var vcode: [16 * 1024]u8 align(16) = undefined;
    var pcode: [16 * 1024]u8 align(16) = undefined;
    var m: EdgeModel = .{};
    var verts: [6][4]f32 = undefined;
};

/// The scene's six vertices (clip space: the triangles (0, 1, 2) and
/// (0, 2, 3) of the quad).
fn edgeVerts(pts: [4][2]f32) [6][4]f32 {
    var v: [6][4]f32 = undefined;
    const tris = [2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } };
    for (tris, 0..) |t, n| {
        for (t, 0..) |c, j| v[n * 3 + j] = .{ 2 * pts[c][0] / EW - 1, 2 * pts[c][1] / EH - 1, edge_z[c], 1 };
    }
    return v;
}

/// The model's picture of a scene drawn with depth LESS (written) over a
/// depth of 1, viewport `vp` (scale x, y, offset x, y), depth scale and
/// offset 0.5 (GL's -1 .. 1 to 0 .. 1).
fn edgeModel(verts: *const [6][4]f32, vp: [4]f32, m: *EdgeModel) void {
    @memset(&m.hits, 0);
    @memset(&m.z, 0xff_ffff);
    const zs: f32 = 0.5;
    const zo: f32 = 0.5;
    for (0..2) |t| {
        var win: [3][2]i64 = undefined;
        var zc: [3]f32 = undefined;
        var w: [3]f32 = undefined;
        for (0..3) |k| {
            const v = verts[3 * t + k];
            win[k] = model3d.windowOf(v[0], v[1], v[3], vp);
            zc[k] = v[2];
            w[k] = v[3];
        }
        var area = model3d.edge(win[0], win[1], win[2]);
        if (area == 0) continue;
        if (area < 0) {
            std.mem.swap([2]i64, &win[1], &win[2]);
            std.mem.swap(f32, &zc[1], &zc[2]);
            std.mem.swap(f32, &w[1], &w[2]);
            area = -area;
        }
        const plane = model3d.planeOf(zc, w, win, zs, zo, area);
        const a = win[0];
        const b = win[1];
        const c = win[2];
        for (0..EH) |py| for (0..EW) |px| {
            const p = [2]i64{ @as(i64, @intCast(px)) * 256 + 128, @as(i64, @intCast(py)) * 256 + 128 };
            if (!model3d.inside(model3d.edge(b, c, p), b, c) or !model3d.inside(model3d.edge(c, a, p), c, a) or !model3d.inside(model3d.edge(a, b, p), a, b)) continue;
            const z = plane.at(@intCast(px), @intCast(py));
            if (!model3d.depthInRange(z, -1, 1, zs, zo)) continue;
            const q = model3d.depthWord(z);
            const i = py * EW + px;
            if (q >= m.z[i]) continue;
            m.z[i] = q;
            m.hits[i] += 1;
        };
    }
}

/// A pixel's red (0.25 added once a hit) as hits: 0, 1, 2, else 3.
fn hitsOf(red: u8) u8 {
    if (red == 0) return 0;
    if (red >= 62 and red <= 66) return 1;
    if (red >= 126 and red <= 130) return 2;
    return 3;
}

fn edgeVertex(k: *kir.Kernel) void {
    const io = k.binding();
    const vb = k.binding();
    const vid = k.load(.u32, nvidia_gl.ioMem(io, nvidia_gl.VERTEX_ID, false), kir.u(0));
    const base = k.op2(.imul, .u32, kir.r(vid), kir.u(16));
    for (0..4) |c| {
        var m = kir.global(vb, 32);
        m.imm = @intCast(4 * c);
        const x = k.load(.f32, m, kir.r(base));
        k.store(.f32, nvidia_gl.ioMem(io, nvidia_gl.POSITION + 4 * @as(u32, @intCast(c)), false), kir.u(0), kir.r(x));
    }
}

fn edgePixel(k: *kir.Kernel) void {
    const io = k.binding();
    _ = k.binding();
    const color = [4]f32{ 0.25, 0, 0, 0 };
    for (color, 0..) |x, c| k.store(.f32, nvidia_gl.ioMem(io, nvidia_gl.OUT_AT + 4 * @as(u32, @intCast(c)), false), kir.u(0), kir.f(x));
}

fn edges(d: gpu.Device, st: *kir_sm120.State, log: draw.Log, now_us: Clock, res: *Hardware) void {
    if (!d.caps.graphics) {
        hsay(log, "step 4, edges: the device offers no graphics dispatches: not run", .{});
        res.edge_skipped = true;
        return;
    }
    var vk = kir.Kernel.init(.{ .insts = &E.insts, .tys = &E.tys }, "edges_vs", .{ 1, 1, 1 });
    edgeVertex(&vk);
    var pk = kir.Kernel.init(.{ .insts = &E.insts, .tys = &E.tys }, "edges_ps", .{ 1, 1, 1 });
    const vbin = blk: {
        vk.finish() catch |e| break :blk e;
        st.asm_work.sched = .{};
        break :blk nvidia_gl.compileStage(&vk, d.caps, st, .vertex, 0, &E.vcode);
    } catch |e| {
        hsay(log, "step 4, edges: the vertex program did not compile ({s}): not run", .{@errorName(e)});
        res.edge_skipped = true;
        return;
    };
    // (the vertex program's KIR is spent: its storage is the pixel's now)
    pk = kir.Kernel.init(.{ .insts = &E.insts, .tys = &E.tys }, "edges_ps", .{ 1, 1, 1 });
    edgePixel(&pk);
    const pbin = blk: {
        pk.finish() catch |e| break :blk e;
        st.asm_work.sched = .{};
        break :blk nvidia_gl.compileStage(&pk, d.caps, st, .pixel, 0, &E.pcode);
    } catch |e| {
        hsay(log, "step 4, edges: the pixel program did not compile ({s}): not run", .{@errorName(e)});
        res.edge_skipped = true;
        return;
    };
    const vp = d.load(&vbin) catch |e| {
        hsay(log, "step 4, edges: the vertex program did not load ({s}): not run", .{@errorName(e)});
        res.edge_skipped = true;
        return;
    };
    defer d.unload(&vp);
    const pp = d.load(&pbin) catch |e| {
        hsay(log, "step 4, edges: the pixel program did not load ({s}): not run", .{@errorName(e)});
        res.edge_skipped = true;
        return;
    };
    defer d.unload(&pp);
    const vb = d.alloc(6 * 16, .host) catch return noMemory(log, res);
    defer d.free(vb);
    const target = d.alloc(EW * EH * 4, .host) catch return noMemory(log, res);
    defer d.free(target);
    const depth = d.alloc(E_DEPTH_BYTES, .host) catch return noMemory(log, res);
    defer d.free(depth);
    const add = gpu.GraphicsBlend{ .src_rgb = .one, .dst_rgb = .one, .src_a = .one, .dst_a = .one };
    for ([_]bool{ false, true }) |flipped| {
        for (edge_scenes) |sc| {
            const vpw = [4]f32{ EW / 2, if (flipped) -@as(f32, EH / 2) else EH / 2, EW / 2, if (flipped) @as(f32, EH) - EH / 2 else EH / 2 };
            E.verts = edgeVerts(sc.pts);
            @memcpy(vb.cpu[0 .. 6 * 16], std.mem.sliceAsBytes(&E.verts));
            d.toDevice(vb, 0, 6 * 16);
            edgeModel(&E.verts, vpw, &E.m);
            var cover_apart: u32 = 0;
            var depth_apart: u32 = 0;
            var equal_apart: u32 = 0;
            var want: u32 = 0;
            var drawn: u32 = 0;
            var listed: u32 = 0;
            for (0..2) |pass| {
                // the target cleared; the depth 1 (pass 0) or the model's
                @memset(target.cpu[0 .. EW * EH * 4], 0);
                d.toDevice(target, 0, EW * EH * 4);
                for (0..EH) |y| for (0..EW) |x| {
                    const at = model3d.blAddress(E_PITCH, E_GOBS, @intCast(x * 4), @intCast(y));
                    std.mem.writeInt(u32, depth.cpu[at..][0..4], if (pass == 0) 0xff_ffff else E.m.z[y * EW + x], .little);
                };
                d.toDevice(depth, 0, E_DEPTH_BYTES);
                const g = gpu.Graphics{
                    .vertex = &vp,
                    .va = target.gpu,
                    .width = EW,
                    .height = EH,
                    .stride = EW * 4,
                    .format = .rgba8,
                    .blend = add,
                    .scale = .{ vpw[0], vpw[1], 0.5 },
                    .offset = .{ vpw[2], vpw[3], 0.5 },
                    .scissor = .{ 0, 0, EW, EH },
                    .count = 6,
                    .depth = .{ .va = depth.gpu, .width = EW, .height = EH, .gobs_log2 = E_GOBS, .tested = true, .write = pass == 0, .func = if (pass == 0) 1 else 2 },
                };
                const t0 = now_us();
                const fence = d.run(&.{.{ .prog = &pp, .groups = .{ 1, 1, 1 }, .buffers = &.{ vb, vb }, .params = &.{}, .graphics = &g }}) catch |e| {
                    hsay(log, "step 4, edges, '{s}'{s}: the draw was not sent ({s}): not run", .{ sc.name, if (flipped) " (flipped)" else "", @errorName(e) });
                    if (e == error.DeviceLost) res.lost = true else res.edge_skipped = true;
                    return;
                };
                d.wait(fence, STEP_US) catch |e| {
                    hsay(log, "step 4, edges, '{s}'{s}: FAILED: the draw did not finish ({s} after {d} us): nothing after it runs", .{ sc.name, if (flipped) " (flipped)" else "", @errorName(e), now_us() - t0 });
                    res.lost = true;
                    return;
                };
                d.fromDevice(target, 0, EW * EH * 4);
                d.fromDevice(depth, 0, E_DEPTH_BYTES);
                for (0..EH) |y| for (0..EW) |x| {
                    const i = y * EW + x;
                    const h = hitsOf(target.cpu[i * 4]);
                    const at = model3d.blAddress(E_PITCH, E_GOBS, @intCast(x * 4), @intCast(y));
                    const z = std.mem.readInt(u32, depth.cpu[at..][0..4], .little) & 0xff_ffff;
                    const mh = E.m.hits[i];
                    if (pass == 0) {
                        want += @intFromBool(mh != 0);
                        drawn += @intFromBool(h != 0);
                        const cov = h != mh;
                        const dep = !cov and mh != 0 and z != E.m.z[i];
                        cover_apart += @intFromBool(cov);
                        depth_apart += @intFromBool(dep);
                        if ((cov or dep) and listed < 3) {
                            listed += 1;
                            hsay(log, "step 4, edges, '{s}'{s}: ({d}, {d}): the 3D engine {d} hit(s) depth {x:0>6}, the compute path's {d} depth {x:0>6}", .{ sc.name, if (flipped) " (flipped)" else "", x, y, h, z, mh, E.m.z[i] });
                        }
                    } else {
                        const eq = (h != 0) != (mh != 0);
                        equal_apart += @intFromBool(eq);
                        if (eq and listed < 6) {
                            listed += 1;
                            hsay(log, "step 4, edges, '{s}'{s}, depth EQUAL against the compute path's depth {x:0>6}: ({d}, {d}) {s}", .{ sc.name, if (flipped) " (flipped)" else "", E.m.z[i], x, y, if (h != 0) "drawn, the compute path's rule has no pixel there" else "NOT drawn: the engine's depth there is not the compute path's" });
                        }
                    }
                };
            }
            res.edge_scenes += 1;
            res.edge_cover_apart += cover_apart;
            res.edge_depth_apart += depth_apart;
            res.edge_equal_apart += equal_apart;
            hsay(log, "step 4, edges, '{s}'{s}: the 3D engine covered {d} pixels, the compute path's rule {d}: {d} covered otherwise, {d} depths apart; depth EQUAL against the compute path's depths: {d} pixels otherwise: {s}", .{ sc.name, if (flipped) " (flipped)" else "", drawn, want, cover_apart, depth_apart, equal_apart, if (cover_apart + depth_apart + equal_apart == 0) "EXACT" else "APART" });
        }
    }
}

fn noMemory(log: draw.Log, res: *Hardware) void {
    hsay(log, "step 4, edges: no memory for its buffers: not run", .{});
    res.edge_skipped = true;
}

// ── Tests: the emulated RTX through the interface ───────────────────────────

const testing = std.testing;

const T = struct {
    var arena: [8 << 20]u8 align(4096) = undefined;
    var gpu_view: [8 << 20]u8 align(4096) = undefined;
    var work: nvidia.sm120_emu.Work = .{};
    var engine: nvidia.emu3d.Engine = .{};
    var dev: nvidia.device.EmuDevice = undefined;
    var asm_work: nvidia.sm120_asm.Work = .{};
    var st: kir_sm120.State = .{};
    var over: Over = undefined;
    var mem: [64 * 1024]u8 = undefined;
    var model: draw.Reference = .{ .mem = &mem };

    fn fresh() Device {
        engine = .{};
        dev = .{ .arena = &arena, .gpu_view = &gpu_view, .work = &work, .gr3d = &engine };
        return dev.device();
    }

    var ticks: u64 = 0;
    fn clock() u64 {
        ticks += 7;
        return ticks;
    }

    fn silent(_: []const u8) void {}

    fn loud(line: []const u8) void {
        if (std.mem.indexOf(u8, line, "FAILED") != null or std.mem.indexOf(u8, line, "CHANGED") != null) {
            var buf: [400]u8 = undefined;
            std.debug.print("{s}\n  {s} {s}\n", .{ line, engine.why, nvidia.sm120_emu.explain(&work, &buf) });
        }
    }

    fn quiet(line: []const u8) void {
        if (std.mem.indexOf(u8, line, " is ") != null or std.mem.indexOf(u8, line, "did not") != null) {
            var buf: [400]u8 = undefined;
            std.debug.print("{s}\n  {s} {s}\n", .{ line, engine.why, nvidia.sm120_emu.explain(&work, &buf) });
        }
    }
};

test "nvidia_draw: the interface's self-test passes on the emulated RTX" {
    const res = selfTest(T.fresh(), &T.over, &T.asm_work, &T.quiet, null);
    try testing.expectEqual(@as(u32, draw.cases.len), res.passed);
    try testing.expectEqual(@as(u32, 0), res.failed);
    try testing.expect(!res.lost);
}

test "nvidia_draw: every case's whole target is the reference's, within 2 of 255" {
    try T.over.init(T.fresh(), &T.asm_work, .{ .stream_bytes = 64 * 1024, .rects = 256, .textures = 31 });
    defer T.over.deinit();
    const bytes = draw.CASE_W * draw.CASE_H * 4;
    for (draw.cases) |c| {
        var pixels: [2]draw.Buffer = undefined;
        // the same pass on the RTX and on the reference
        T.model.reset();
        for ([_]draw.Renderer{ T.over.renderer(), T.model.renderer() }, 0..) |r, k| {
            pixels[k] = r.alloc(bytes) orelse return error.OutOfMemory;
            const tex_buf = r.alloc(draw.CaseTextures.BYTES) orelse return error.OutOfMemory;
            const tex = draw.CaseTextures.fill(tex_buf);
            r.toDevice(tex_buf, 0, draw.CaseTextures.BYTES);
            const t = draw.Target{ .va = pixels[k].va, .width = draw.CASE_W, .height = draw.CASE_H, .pitch = draw.CASE_W * 4, .format = .bgra8 };
            draw.record(r, t, tex, c);
            r.run(1_000_000) catch |e| {
                var buf: [400]u8 = undefined;
                std.debug.print("{s}: the pass did not finish ({s}): {s} {s}\n", .{ c.name, @errorName(e), T.engine.why, nvidia.sm120_emu.explain(&T.work, &buf) });
                return e;
            };
            r.fromDevice(pixels[k], 0, bytes);
        }
        if (draw.firstDifference(pixels[0].cpu[0..bytes], pixels[1].cpu[0..bytes], 2)) |at| {
            const a: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, pixels[0].cpu[0..bytes]));
            const b: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, pixels[1].cpu[0..bytes]));
            std.debug.print("{s}: pixel ({d}, {d}): the RTX {x:0>8}, the reference {x:0>8}\n", .{ c.name, at % draw.CASE_W, at / draw.CASE_W, a[at], b[at] });
            return error.TestUnexpectedResult;
        }
        T.over.renderer().free(pixels[0]);
    }
}

test "nvidia_draw: the hardware test, step by step, on the emulated RTX: every case the CPU's" {
    const res = hardwareTest(T.fresh(), null, &T.over, &T.st, &T.model, &T.loud, &T.clock);
    try testing.expect(res.started and res.object and res.state);
    try testing.expectEqual(@as(u32, draw.cases.len), res.passed);
    try testing.expectEqual(@as(u32, 0), res.failed);
    try testing.expect(!res.lost);
    // (step 4 needs the adapter: tests/test_gfxapi_draw.sig runs it)
    try testing.expect(res.edge_skipped);
    // (the fill rate's 8 MiB are more than the emulated RTX's arena holds)
    try testing.expectEqual(@as(u32, 0), res.mpx_per_s);
}

test "nvidia_draw: the hardware test stops at step 1 when the channel has no 3D engine" {
    T.engine = .{};
    T.dev = .{ .arena = &T.arena, .gpu_view = &T.gpu_view, .work = &T.work };
    const res = hardwareTest(T.dev.device(), null, &T.over, &T.st, &T.model, &T.silent, &T.clock);
    try testing.expect(res.started and !res.object and !res.state and res.lost);
    try testing.expectEqual(@as(u32, 0), res.passed);
}

test "nvidia_draw: compare counts the pixels further apart than the tolerance" {
    const a = [_]u8{ 10, 10, 10, 255, 0, 0, 0, 255, 9, 9, 9, 9 };
    const b = [_]u8{ 12, 10, 10, 255, 0, 9, 0, 255, 9, 9, 9, 9 };
    const d = compare(&a, &b, 3);
    try testing.expectEqual(@as(u32, 1), d.count);
    try testing.expectEqual(@as(?usize, 1), d.first);
    try testing.expectEqual(@as(u8, 9), d.largest);
    try testing.expectEqual(@as(?usize, null), compare(&a, &a, 0).first);
}
