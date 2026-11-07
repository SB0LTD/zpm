//! gfxapi's transfers WebRender uses beside draws, run three ways: on the
//! CPU (KIR's interpreter), on EmuDevice (memory not coherent), and on the
//! emulated Adreno through Galaxy's calls (ir3). Every run must give the
//! same bytes, and the values GL says.
//!
//! - Mapped buffers (glMapBufferRange): a pixel unpack buffer filled
//!   through a map and uploaded to a texture; rows rewritten through an
//!   unsynchronized map and through an explicitly flushed one; a pack
//!   buffer mapped for reading after glReadPixels; the errors ES 3.0 gives
//!   (a second map, a mapped buffer used, bad access bits, length 0).
//! - glBlitFramebuffer: 1:1; flipped and scaled 2x (nearest); a 2:1
//!   bilinear downscale; under a scissor box; into a BGRA8 renderbuffer
//!   and an R8 texture; depth and stencil together and depth alone; its
//!   errors.
//! - GL sync objects: a fence waited on, its status, glWaitSync, deletion,
//!   and the errors.

const std = @import("std");
const gpu = @import("gpu");
const adreno = @import("adreno");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const g = gfxapi.glenum;
const node = gfxapi.node;

const S = 32; // the source texture's side
const D = 64; // the destination's

const Out = struct {
    dst: [D * D * 4]u8 = undefined,
    packed_px: [D * D * 4]u8 = undefined,
    r8: [S * S]u8 = undefined,
    ds: [D * D * 4]u8 = undefined,
    /// GL's answers that were not as expected
    bad: u32 = 0,
    /// which: the first wrong answer's line
    bad_line: u32 = 0,
};

var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;

fn want(c: *gles.Context, out: *Out, ok: bool, line: u32) void {
    _ = c;
    if (!ok) {
        if (out.bad == 0) out.bad_line = line;
        out.bad += 1;
    }
}

fn err(c: *gles.Context, out: *Out, code: u32, line: u32) void {
    want(c, out, c.getError() == code, line);
}

/// The source texture's texel (x, y) as uploaded: a gradient, red 255 in
/// rows 0..3 (an unsynchronized map), green 255 in rows 4..7 (a flushed one).
fn texel(x: usize, y: usize) [4]u8 {
    var t = [4]u8{ @intCast(x * 8), @intCast(y * 8), @intCast(255 - x * 4), 255 };
    if (y < 4) t[0] = 255;
    if (y >= 4 and y < 8) t[1] = 255;
    return t;
}

fn fb(c: *gles.Context) u32 {
    var n: [1]u32 = undefined;
    c.genFramebuffers(&n);
    return n[0];
}

fn rbuf(c: *gles.Context, internal: u32, w: i32, h: i32) u32 {
    var n: [1]u32 = undefined;
    c.genRenderbuffers(&n);
    c.bindRenderbuffer(g.RENDERBUFFER, n[0]);
    c.renderbufferStorage(g.RENDERBUFFER, 0, internal, w, h);
    return n[0];
}

fn tex(c: *gles.Context, internal: u32, w: i32, h: i32) u32 {
    var n: [1]u32 = undefined;
    c.genTextures(&n);
    c.bindTexture(g.TEXTURE_2D, n[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, internal, w, h);
    return n[0];
}

fn bytes(p: ?*anyopaque, n: usize) []u8 {
    return @as([*]u8, @ptrCast(p.?))[0..n];
}

fn scene(eng: *engine.Engine, out: *Out) !void {
    objs.init();
    const c = &ctx;
    c.init(eng, &objs);
    defer c.deinit();

    // ── 1. A texture uploaded through a mapped unpack buffer ──
    var pbo: [2]u32 = undefined;
    c.genBuffers(&pbo);
    c.bindBuffer(g.PIXEL_UNPACK_BUFFER, pbo[0]);
    c.bufferData(g.PIXEL_UNPACK_BUFFER, S * S * 4, null, g.STREAM_DRAW);
    const m = c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, S * S * 4, g.MAP_WRITE_BIT);
    want(c, out, m != null, @src().line);
    const px = bytes(m, S * S * 4);
    for (0..S) |y| {
        for (0..S) |x| px[(y * S + x) * 4 ..][0..4].* = .{ @intCast(x * 8), @intCast(y * 8), @intCast(255 - x * 4), 255 };
    }
    // (while mapped: a second map, an upload from it, fail; it says so)
    want(c, out, c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 4, g.MAP_WRITE_BIT) == null, @src().line);
    err(c, out, g.INVALID_OPERATION, @src().line);
    want(c, out, c.getBufferParameter(g.PIXEL_UNPACK_BUFFER, g.BUFFER_MAPPED) == 1, @src().line);
    want(c, out, c.getBufferPointer(g.PIXEL_UNPACK_BUFFER, g.BUFFER_MAP_POINTER) == m, @src().line);
    const t = tex(c, g.RGBA8, S, S);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, S, S, g.RGBA, g.UNSIGNED_BYTE, null);
    err(c, out, g.INVALID_OPERATION, @src().line);
    want(c, out, c.unmapBuffer(g.PIXEL_UNPACK_BUFFER), @src().line);
    want(c, out, !c.unmapBuffer(g.PIXEL_UNPACK_BUFFER), @src().line);
    err(c, out, g.INVALID_OPERATION, @src().line);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, S, S, g.RGBA, g.UNSIGNED_BYTE, null);
    err(c, out, g.NO_ERROR, @src().line);
    // rows 0..3 red, through an unsynchronized map
    const row = S * 4;
    const mu = c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 4 * row, g.MAP_WRITE_BIT | g.MAP_UNSYNCHRONIZED_BIT);
    const pu = bytes(mu, 4 * row);
    for (0..4 * S) |n| pu[n * 4] = 255;
    _ = c.unmapBuffer(g.PIXEL_UNPACK_BUFFER);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, 0, S, 4, g.RGBA, g.UNSIGNED_BYTE, null);
    // rows 4..7 green, through an explicitly flushed map
    const mf = c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 4 * row, 4 * row, g.MAP_WRITE_BIT | g.MAP_FLUSH_EXPLICIT_BIT);
    const pf = bytes(mf, 4 * row);
    for (0..4 * S) |n| pf[n * 4 + 1] = 255;
    c.flushMappedBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 4 * row);
    err(c, out, g.NO_ERROR, @src().line);
    c.flushMappedBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 5 * row);
    err(c, out, g.INVALID_VALUE, @src().line);
    _ = c.unmapBuffer(g.PIXEL_UNPACK_BUFFER);
    c.texSubImage2D(g.TEXTURE_2D, 0, 0, 4, S, 4, g.RGBA, g.UNSIGNED_BYTE, @ptrFromInt(4 * row));
    err(c, out, g.NO_ERROR, @src().line);
    // maps GL refuses
    want(c, out, c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 4, g.MAP_READ_BIT | g.MAP_INVALIDATE_RANGE_BIT) == null, @src().line);
    err(c, out, g.INVALID_OPERATION, @src().line);
    want(c, out, c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 0, g.MAP_WRITE_BIT) == null, @src().line);
    err(c, out, g.INVALID_OPERATION, @src().line);
    want(c, out, c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 0, 4, g.MAP_FLUSH_EXPLICIT_BIT) == null, @src().line);
    err(c, out, g.INVALID_OPERATION, @src().line);
    want(c, out, c.mapBufferRange(g.PIXEL_UNPACK_BUFFER, 8, S * S * 4, g.MAP_WRITE_BIT) == null, @src().line);
    err(c, out, g.INVALID_VALUE, @src().line);
    c.bindBuffer(g.PIXEL_UNPACK_BUFFER, 0);

    // ── 2. Blits ──
    // the source: the texture, and depth 0.25 and stencil 0x5a
    const ds1 = rbuf(c, g.DEPTH24_STENCIL8, S, S);
    const fs = fb(c);
    c.bindFramebuffer(g.FRAMEBUFFER, fs);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, t, 0);
    c.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_STENCIL_ATTACHMENT, g.RENDERBUFFER, ds1);
    want(c, out, c.checkFramebufferStatus(g.FRAMEBUFFER) == g.FRAMEBUFFER_COMPLETE, @src().line);
    c.clearDepth(0.25);
    c.clearStencil(0x5a);
    c.clear(g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT);
    // the destination: BGRA8 and depth-stencil, cleared
    const rc = rbuf(c, g.BGRA8_EXT, D, D);
    const ds2 = rbuf(c, g.DEPTH24_STENCIL8, D, D);
    const fd = fb(c);
    c.bindFramebuffer(g.FRAMEBUFFER, fd);
    c.framebufferRenderbuffer(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.RENDERBUFFER, rc);
    c.framebufferRenderbuffer(g.FRAMEBUFFER, g.DEPTH_STENCIL_ATTACHMENT, g.RENDERBUFFER, ds2);
    want(c, out, c.checkFramebufferStatus(g.FRAMEBUFFER) == g.FRAMEBUFFER_COMPLETE, @src().line);
    c.viewportSet(0, 0, D, D);
    c.clearColor(0.1, 0.2, 0.3, 1);
    c.clearDepth(1);
    c.clearStencil(0);
    c.clear(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT);
    c.bindFramebuffer(g.READ_FRAMEBUFFER, fs);
    c.bindFramebuffer(g.DRAW_FRAMEBUFFER, fd);
    // a. 1:1
    c.blitFramebuffer(0, 0, 16, 16, 0, 0, 16, 16, g.COLOR_BUFFER_BIT, g.NEAREST);
    // b. the top left quarter, flipped across and scaled 2x, at x 16..48
    c.blitFramebuffer(0, 16, 16, 32, 48, 0, 16, 32, g.COLOR_BUFFER_BIT, g.NEAREST);
    // c. the bottom right quarter halved, bilinear, at (0, 32)
    c.blitFramebuffer(16, 0, 32, 16, 0, 32, 8, 40, g.COLOR_BUFFER_BIT, g.LINEAR);
    // d. all of it 1:1 at (32, 32), under a scissor box (40, 40, 8, 8)
    c.enable(g.SCISSOR_TEST, true);
    c.scissorSet(40, 40, 8, 8);
    c.blitFramebuffer(0, 0, S, S, 32, 32, 64, 64, g.COLOR_BUFFER_BIT, g.NEAREST);
    c.enable(g.SCISSOR_TEST, false);
    // e. depth and stencil at (0, 0); depth alone at (40, 0)
    c.blitFramebuffer(0, 0, S, S, 0, 0, S, S, g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT, g.NEAREST);
    c.blitFramebuffer(0, 0, 8, 8, 40, 0, 48, 8, g.DEPTH_BUFFER_BIT, g.NEAREST);
    err(c, out, g.NO_ERROR, @src().line);
    // what GL refuses
    c.blitFramebuffer(0, 0, 8, 8, 0, 0, 8, 8, g.DEPTH_BUFFER_BIT, g.LINEAR);
    err(c, out, g.INVALID_OPERATION, @src().line);
    c.blitFramebuffer(0, 0, 8, 8, 0, 0, 8, 8, 0x1, g.NEAREST);
    err(c, out, g.INVALID_VALUE, @src().line);
    c.blitFramebuffer(0, 0, 8, 8, 0, 0, 8, 8, g.COLOR_BUFFER_BIT, g.LINEAR_MIPMAP_LINEAR);
    err(c, out, g.INVALID_ENUM, @src().line);
    c.bindFramebuffer(g.DRAW_FRAMEBUFFER, fs);
    c.blitFramebuffer(0, 0, 8, 8, 8, 8, 16, 16, g.COLOR_BUFFER_BIT, g.NEAREST);
    err(c, out, g.INVALID_OPERATION, @src().line);
    // f. into an R8 texture: its red
    const tr = tex(c, g.R8, S, S);
    const fr = fb(c);
    c.bindFramebuffer(g.DRAW_FRAMEBUFFER, fr);
    c.framebufferTexture2D(g.DRAW_FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tr, 0);
    c.blitFramebuffer(0, 0, S, S, 0, 0, S, S, g.COLOR_BUFFER_BIT, g.NEAREST);
    err(c, out, g.NO_ERROR, @src().line);

    // ── 3. Read back: client memory, a mapped pack buffer, R8, depth ──
    c.bindFramebuffer(g.READ_FRAMEBUFFER, fd);
    c.readPixels(0, 0, D, D, g.RGBA, g.UNSIGNED_BYTE, &out.dst);
    c.bindBuffer(g.PIXEL_PACK_BUFFER, pbo[1]);
    c.bufferData(g.PIXEL_PACK_BUFFER, D * D * 4, null, g.STREAM_READ);
    c.readPixels(0, 0, D, D, g.RGBA, g.UNSIGNED_BYTE, null);
    const mr = c.mapBufferRange(g.PIXEL_PACK_BUFFER, 0, D * D * 4, g.MAP_READ_BIT);
    if (mr != null) @memcpy(&out.packed_px, bytes(mr, D * D * 4));
    // (a mapped pack buffer is no target)
    c.readPixels(0, 0, 1, 1, g.RGBA, g.UNSIGNED_BYTE, null);
    err(c, out, g.INVALID_OPERATION, @src().line);
    _ = c.unmapBuffer(g.PIXEL_PACK_BUFFER);
    c.bindBuffer(g.PIXEL_PACK_BUFFER, 0);
    c.bindFramebuffer(g.READ_FRAMEBUFFER, fr);
    c.readPixels(0, 0, S, S, g.RED, g.UNSIGNED_BYTE, &out.r8);
    err(c, out, g.NO_ERROR, @src().line);
    eng.read(&objs.rbs[ds2 - 1].img, 0, 0, D, D, &out.ds, D * 4, .d24s8);

    // ── 4. Sync objects ──
    const sy = c.fenceSync(g.SYNC_GPU_COMMANDS_COMPLETE, 0);
    want(c, out, sy != null and c.isSync(sy), @src().line);
    const r = c.clientWaitSync(sy, g.SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000);
    want(c, out, r == g.ALREADY_SIGNALED or r == g.CONDITION_SATISFIED, @src().line);
    want(c, out, c.getSync(sy, g.SYNC_STATUS) == g.SIGNALED, @src().line);
    want(c, out, c.getSync(sy, g.OBJECT_TYPE) == g.SYNC_FENCE, @src().line);
    c.waitSync(sy, 0, g.TIMEOUT_IGNORED);
    err(c, out, g.NO_ERROR, @src().line);
    c.waitSync(sy, 0, 5);
    err(c, out, g.INVALID_VALUE, @src().line);
    c.deleteSync(sy);
    want(c, out, !c.isSync(sy), @src().line);
    want(c, out, c.clientWaitSync(sy, 0, 0) == g.WAIT_FAILED, @src().line);
    err(c, out, g.INVALID_VALUE, @src().line);
    want(c, out, c.fenceSync(0x1234, 0) == null, @src().line);
    err(c, out, g.INVALID_ENUM, @src().line);
    c.finish();
}

fn at(o: []const u8, w: usize, x: usize, y: usize) [4]u8 {
    return o[(y * w + x) * 4 ..][0..4].*;
}

fn near(a: [4]u8, b: [4]u8) bool {
    for (a, b) |x, y| {
        if (@abs(@as(i32, x) - y) > 1) return false;
    }
    return true;
}

fn check(o: *const Out) !void {
    const E = std.testing.expectEqual;
    if (o.bad != 0) std.debug.print("xfer: {d} wrong answers, the first at line {d}\n", .{ o.bad, o.bad_line });
    try E(@as(u32, 0), o.bad);
    const clear = [4]u8{ 26, 51, 77, 255 };
    // a. 1:1
    for (0..16) |y| {
        for (0..16) |x| try E(texel(x, y), at(&o.dst, D, x, y));
    }
    // b. flipped and scaled: x 16..47 from source x 15..0, y 0..31 from 16..31
    for (0..32) |y| {
        for (16..48) |x| try E(texel((47 - x) / 2, 16 + y / 2), at(&o.dst, D, x, y));
    }
    // c. each pixel the mean of a 2 x 2 block
    for (0..8) |y| {
        for (0..8) |x| {
            var m: [4]u8 = undefined;
            for (0..4) |ch| {
                var s: u32 = 0;
                for ([_][2]usize{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }) |d| s += texel(16 + 2 * x + d[0], 2 * y + d[1])[ch];
                m[ch] = @intCast((s + 2) / 4);
            }
            try std.testing.expect(near(m, at(&o.dst, D, x, 32 + y)));
        }
    }
    // d. the scissor box alone
    try E(texel(8, 8), at(&o.dst, D, 40, 40));
    try E(texel(15, 15), at(&o.dst, D, 47, 47));
    try E(clear, at(&o.dst, D, 39, 40));
    try E(clear, at(&o.dst, D, 48, 47));
    try E(clear, at(&o.dst, D, 60, 60));
    // the pack buffer's map: the same bytes
    try std.testing.expectEqualSlices(u8, &o.dst, &o.packed_px);
    // f. R8: red
    for (0..S) |y| {
        for (0..S) |x| try E(texel(x, y)[0], o.r8[y * S + x]);
    }
    // e. depth 0.25 (4194304) and stencil 0x5a at 0..31; depth alone at
    // 40..47 x 0..7 (stencil 0); depth 1 elsewhere
    const dsAt = struct {
        fn f(oo: *const Out, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, oo.ds[(y * D + x) * 4 ..][0..4], .little);
        }
    }.f;
    try E(@as(u32, 0x5a40_0000), dsAt(o, 0, 0));
    try E(@as(u32, 0x5a40_0000), dsAt(o, 31, 31));
    try E(@as(u32, 0x0040_0000), dsAt(o, 40, 0));
    try E(@as(u32, 0x0040_0000), dsAt(o, 47, 7));
    try E(@as(u32, 0x00ff_ffff), dsAt(o, 48, 0));
    try E(@as(u32, 0x00ff_ffff), dsAt(o, 32, 40));
}

// ── The three runs ─────────────────────────────────────────────────────────

var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [8 << 20]u8 align(64) = undefined;
var eng_cpu: engine.Engine = undefined;
var out_cpu: Out = .{};
var cpu_done = false;

fn cpuOut() !*const Out {
    if (!cpu_done) {
        eng_cpu.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
        try scene(&eng_cpu, &out_cpu);
        if (eng_cpu.why_pipe) |e| std.debug.print("cpu: {s} at pc {d}\n", .{ @errorName(e), eng_cpu.trap.pc });
        cpu_done = true;
    }
    return &out_cpu;
}

fn same(a: *const Out, b: *const Out) !void {
    try std.testing.expectEqualSlices(u8, &a.dst, &b.dst);
    try std.testing.expectEqualSlices(u8, &a.r8, &b.r8);
    try std.testing.expectEqualSlices(u8, &a.ds, &b.ds);
}

test "transfers: mapped buffers, blits and sync objects on the CPU" {
    try check(try cpuOut());
}

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [16 << 20]u8 align(4096) = undefined;
var emu_work: [16 << 20]u8 align(64) = undefined;
var compile_mem: [256 << 10]u8 align(64) = undefined;
var emu: gpu.EmuDevice = undefined;
var eng_emu: engine.Engine = undefined;
var out_emu: Out = .{};

test "transfers: on EmuDevice, the CPU's bytes" {
    const w = try cpuOut();
    var caps = gpu.interp_caps;
    caps.coherent = false;
    emu = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    emu.shadow = &emu_shadow;
    eng_emu.init(.{ .dev = emu.device(), .work = &compile_mem, .cpu_work = &cpu_work });
    try std.testing.expect(eng_emu.onGpu());
    try scene(&eng_emu, &out_emu);
    try std.testing.expect(!eng_emu.lost);
    // (the blits ran on the GPU)
    try std.testing.expect(eng_emu.stats.dispatches >= 7);
    eng_emu.deinit();
    try check(&out_emu);
    try same(w, &out_emu);
}

var a_arena: [32 << 20]u8 align(4096) = undefined;
var a_view: [32 << 20]u8 align(4096) = undefined;
var a_emu: adreno.device.EmuDevice = undefined;
var a_fake: node.Fake = undefined;
const AGpu = node.Gpu(*node.Fake, &.{.ir3_a7xx});
var a_gpu: AGpu = undefined;
var ir3_work: [gpu.kir_ir3.WORK_BYTES]u8 align(64) = undefined;
var eng_a: engine.Engine = undefined;
var out_a: Out = .{};

test "transfers: on the emulated Adreno (ir3), the CPU's bytes" {
    const w = try cpuOut();
    a_emu = .{ .arena = &a_arena, .gpu_view = &a_view, .guard = 0 };
    a_fake = .{ .emu = &a_emu };
    a_gpu = .{ .node = .{ .sys = &a_fake } };
    const d = try a_gpu.open();
    eng_a.init(.{ .dev = d, .compiler = AGpu.compile, .work = &ir3_work, .cpu_work = &cpu_work });
    try std.testing.expect(eng_a.onGpu());
    try scene(&eng_a, &out_a);
    if (a_emu.last_error) |e| std.debug.print("ir3_emu: {s}: {s}\n", .{ @errorName(e), a_emu.fault.text() });
    try std.testing.expect(!eng_a.lost);
    try std.testing.expect(eng_a.stats.dispatches >= 7);
    eng_a.deinit();
    a_gpu.close();
    try check(&out_a);
    try same(w, &out_a);
}
