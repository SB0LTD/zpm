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

const nv = nvidia.draw;

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

// ── Tests: the emulated RTX through the interface ───────────────────────────

const testing = std.testing;

const T = struct {
    var arena: [8 << 20]u8 align(4096) = undefined;
    var gpu_view: [8 << 20]u8 align(4096) = undefined;
    var work: nvidia.sm120_emu.Work = .{};
    var engine: nvidia.emu3d.Engine = .{};
    var dev: nvidia.device.EmuDevice = undefined;
    var asm_work: nvidia.sm120_asm.Work = .{};
    var over: Over = undefined;
    var mem: [64 * 1024]u8 = undefined;
    var model: draw.Reference = .{ .mem = &mem };

    fn fresh() Device {
        engine = .{};
        dev = .{ .arena = &arena, .gpu_view = &gpu_view, .work = &work, .gr3d = &engine };
        return dev.device();
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
