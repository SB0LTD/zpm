//! @zpm/gpu nvidia_gl — GL-shaped draws on the RTX's 3D engine (BLACKWELL_B):
//! a draw's vertex and pixel programs compiled from KIR (kir_sm120's
//! graphics stages) with their headers (nvidia/sph.sig), for the
//! nvidia_device adapter to send with the engine's state
//! (nvidia/gl3d.sig) as a run's graphics dispatch (device.Graphics).
//!
//! A program's KIR reads and writes the stage's attribute words through
//! one binding it declares and never binds (kir_sm120.Stage): the vertex
//! program loads the vertex's and the instance's index and stores the
//! clip-space position and the varyings, the pixel program loads the
//! varyings (and the pixel's position) and stores its colors. Everything
//! else (the attributes from their buffers, uniforms, textures) it loads
//! from memory as a compute kernel does, through constant buffer 0's
//! binding addresses (the same buffer for both stages).
//!
//! The header is made from what the compiled program does (after dead code
//! is dropped): the words it loads and stores, how each varying is carried
//! (flat where it is loaded .CONSTANT, else in perspective), its outputs and
//! whether it discards.
//!
//! Allocation-free: the compiler's State and the code are the caller's.

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const kir_sm120 = @import("kir_sm120.sig");
const nvidia = @import("nvidia");
const sph = nvidia.sph;

pub const Stage = kir_sm120.Stage;
pub const OUT_AT = kir_sm120.OUT_AT;
pub const KILL_AT = kir_sm120.KILL_AT;

/// Binary.extra's word saying which stage a binary is (kir_sm120.Stage).
pub const EXTRA_STAGE = 6;
/// A pixel program's: its output registers (kir_sm120.StageIO.outputs).
pub const EXTRA_OUTPUTS = 7;

/// The attribute words a stage's KIR loads and stores (bytes, as ALD, AST
/// and IPA address them).
pub const POSITION = sph.ATTR_POSITION;
pub const VERTEX_ID = sph.ATTR_VERTEX_ID;
pub const INSTANCE_ID = sph.ATTR_INSTANCE_ID;
pub fn generic(n: u32, c: u32) u32 {
    return sph.generic(n, c);
}
/// Scalar varyings a draw may carry: 32 generic vectors.
pub const MAX_VARYINGS = 4 * sph.GENERICS;

/// The stage's input or output word at `at` through binding `io`.
pub fn ioMem(io: u8, at: u32, flat: bool) kir.Mem {
    var m = kir.global(io, 32);
    m.imm = @intCast(at | if (flat) kir_sm120.FLAT else 0);
    return m;
}

/// `k` as stage `stage`'s program (`io`: the binding it reads and writes
/// its attribute words through) into `out`: the header, then the code,
/// the Binary's code being both (the 3D engine is given the header's
/// address). `st` is the compiler's State.
pub fn compileStage(k: *const kir.Kernel, caps: device.Caps, st: *kir_sm120.State, stage: Stage, io: u8, out: []u8) kir_sm120.Error!device.Binary {
    if (stage == .compute or out.len < sph.BYTES) return error.Unsupported;
    var bin = try kir_sm120.compileIn(k, caps, st, out[sph.BYTES..], .{ .stage = stage, .stage_io = io });
    const head = header(stage, &st.io);
    for (head, 0..) |w, n| std.mem.writeInt(u32, out[n * 4 ..][0..4], w, .little);
    bin.code = out[0 .. sph.BYTES + bin.code.len];
    bin.extra[EXTRA_STAGE] = @intFromEnum(stage);
    bin.extra[EXTRA_OUTPUTS] = st.io.outputs;
    return bin;
}

/// The header for what a stage's program does.
pub fn header(stage: Stage, io: *const kir_sm120.StageIO) [sph.WORDS]u32 {
    const has = kir_sm120.StageIO.has;
    switch (stage) {
        .vertex => {
            var v = sph.Vertex{ .vertex_id = has(&io.loads, VERTEX_ID), .instance_id = has(&io.loads, INSTANCE_ID) };
            for (0..sph.GENERICS) |n| for (0..4) |c| {
                if (has(&io.stores, generic(@intCast(n), @intCast(c)))) v.out_generic[n] |= @as(u4, 1) << @intCast(c);
            };
            return sph.vertex(v);
        },
        .pixel => {
            var p = sph.Pixel{ .kills = io.kills, .targets = @splat(0) };
            for (0..3) |c| {
                if (has(&io.loads, POSITION + 4 * @as(u32, @intCast(c)))) p.frag_coord |= @as(u3, 1) << @intCast(c);
            }
            for (0..sph.GENERICS) |n| for (0..4) |c| {
                const at = generic(@intCast(n), @intCast(c));
                if (!has(&io.loads, at)) continue;
                p.in_generic[n][c] = if (has(&io.flat, at)) .constant else .perspective;
            };
            for (0..8) |t| p.targets[t] = @truncate(io.outputs >> @intCast(4 * t));
            return sph.pixel(p);
        },
        .compute => unreachable,
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const r = kir.r;
const u = kir.u;
const f = kir.f;

const T = struct {
    var st: kir_sm120.State = undefined;
    var out: [64 * 1024]u8 align(16) = undefined;
    var insts: [256]kir.Inst = undefined;
    var tys: [256]kir.Ty = undefined;
};

fn rtx() device.Caps {
    var c = device.interp_caps;
    c.vendor = .nvidia;
    c.target = .sm_120;
    c.subgroup = 32;
    c.fused_fma = true;
    c.mad = .fused;
    c.denormals = .preserve;
    return c;
}

test "nvidia_gl: a vertex program loads its index and stores the position and a varying" {
    var k = kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, "vs", .{ 1, 1, 1 });
    const io = k.binding();
    const vid = k.load(.u32, ioMem(io, VERTEX_ID, false), u(0));
    const x = k.cvt(.u32, .f32, .rne, r(vid));
    for (0..4) |c| k.store(.f32, ioMem(io, POSITION + 4 * @as(u32, @intCast(c)), false), u(0), if (c == 0) r(x) else f(1));
    k.store(.f32, ioMem(io, generic(0, 1), false), u(0), r(x));
    try k.finish();
    T.st.asm_work.sched = .{};
    const bin = try compileStage(&k, rtx(), &T.st, .vertex, io, &T.out);
    const text = try kir_sm120.compileText(&k, rtx(), &T.st, .{ .stage = .vertex, .stage_io = io });
    try testing.expect(std.mem.indexOf(u8, text, "ALD R") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a[0x2fc]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "AST a[0x84]") != null);
    const head: *const [sph.WORDS]u32 = @ptrCast(@alignCast(bin.code[0..sph.BYTES]));
    try testing.expectEqual(sph.Stage.vertex, sph.stageOf(head).?);
    try testing.expect(sph.bit(head, 351) and !sph.bit(head, 350));
    // (generic 0's y alone stored)
    try testing.expect(sph.bit(head, 433) and !sph.bit(head, 432));
    try testing.expectEqual(@as(u32, @intFromEnum(Stage.vertex)), bin.extra[EXTRA_STAGE]);
}

test "nvidia_gl: a pixel program reads a varying in perspective and one flat, writes target 0, discards" {
    var k = kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, "ps", .{ 1, 1, 1 });
    const io = k.binding();
    const iw = k.load(.f32, ioMem(io, POSITION + 12, false), u(0));
    const w = k.div(f(1), r(iw));
    const a = k.op2(.fmul, .f32, r(k.load(.f32, ioMem(io, generic(0, 0), false), u(0))), r(w));
    const b = k.load(.f32, ioMem(io, generic(1, 2), true), u(0));
    k.ifp(r(k.cmp(.f32, .lt, r(a), f(0))));
    k.store(.u32, ioMem(io, KILL_AT, false), u(0), u(0));
    k.endif();
    k.store(.f32, ioMem(io, OUT_AT + 0, false), u(0), r(a));
    k.store(.f32, ioMem(io, OUT_AT + 4, false), u(0), r(b));
    k.store(.f32, ioMem(io, OUT_AT + 12, false), u(0), f(1));
    try k.finish();
    T.st.asm_work.sched = .{};
    const bin = try compileStage(&k, rtx(), &T.st, .pixel, io, &T.out);
    const text = try kir_sm120.compileText(&k, rtx(), &T.st, .{ .stage = .pixel, .stage_io = io });
    try testing.expect(std.mem.indexOf(u8, text, "IPA.PASS") != null);
    try testing.expect(std.mem.indexOf(u8, text, "IPA.CONSTANT") != null);
    try testing.expect(std.mem.indexOf(u8, text, "KILL") != null);
    const head: *const [sph.WORDS]u32 = @ptrCast(@alignCast(bin.code[0..sph.BYTES]));
    try testing.expectEqual(sph.Stage.pixel, sph.stageOf(head).?);
    try testing.expectEqual(sph.Interp.perspective, sph.interpOf(head, 0, 0));
    try testing.expectEqual(sph.Interp.constant, sph.interpOf(head, 1, 2));
    try testing.expectEqual(sph.Interp.unused, sph.interpOf(head, 1, 0));
    try testing.expect(sph.bit(head, 15));
    // (red, green, alpha: blue never stored, so not an output)
    try testing.expectEqual(@as(u32, 0b1011), bin.extra[EXTRA_OUTPUTS]);
}
