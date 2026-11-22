//! Direct3D's compute shaders (compute_fixtures.hlsl, compiled by
//! Microsoft's compiler) as KIR kernels (gen.compute), run on KIR's
//! interpreter with their buffers and textures, every word of what they
//! write checked against what Sig works out: typed UAVs (RGBA32F, RGBA8,
//! R32_UINT, a typed buffer), structured and raw buffers and their sizes,
//! groupshared memory across a barrier, the thread ids, atomics (a
//! counter, a maximum, a typed texel, groupshared), an early return, and
//! a texture sampled with a level.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const engine = @import("../engine.sig");
const texture = @import("../texture.sig");
const gen = @import("gen.sig");
const fx = @import("compute_fixtures.sig");

const D = texture.DESC_WORDS;

var insts: [32768]kir.Inst = undefined;
var tys: [32768]kir.Ty = undefined;
var work: [8 << 20]u8 align(64) = undefined;

/// What a test binds: constant buffer 0's words (at word 0), t# texture
/// slots (descriptors after the constant buffer, bindings from 1), and
/// u#/t# buffers (each a binding, its words where `word` says).
const Lay = struct {
    cb_vecs: u32 = 0,
    textures: u32 = 0,
    uavs: [4]?gen.Mem = .{ null, null, null, null },
    tbufs: [4]?gen.Mem = .{ null, null, null, null },

    fn layout(l: *const Lay) gen.Layout {
        return .{ .ctx = l, .varying = noVarying, .cbuffer = cbuffer, .texture = tex, .desc_base = 4 * l.cb_vecs, .uav = uav, .tbuffer = tbuf };
    }
    fn noVarying(_: ?*const anyopaque, _: []const u8, _: u32) ?u32 {
        return null;
    }
    fn cbuffer(ctx: ?*const anyopaque, slot: u32) ?gen.CBuffer {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        return if (slot == 0 and l.cb_vecs != 0) .{ .word = 0, .vecs = l.cb_vecs } else null;
    }
    fn tex(ctx: ?*const anyopaque, t: u32, _: u32) ?u32 {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        return if (t < l.textures) t else null;
    }
    fn uav(ctx: ?*const anyopaque, n: u32) ?gen.Mem {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        return if (n < 4) l.uavs[n] else null;
    }
    fn tbuf(ctx: ?*const anyopaque, n: u32) ?gen.Mem {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        return if (n < 4) l.tbufs[n] else null;
    }
};

/// The shader as a kernel (binding 0 the uniform words, textures from 1),
/// run over `groups`.
fn run(blob: []const u8, l: *const Lay, bindings: []const []u8, groups: [3]u32) !void {
    const group = gen.threadGroup(blob) orelse return error.NoThreadGroup;
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "cs", group);
    for (bindings) |_| _ = k.binding();
    var log: gen.Log = .{};
    if (!gen.compute(blob, l.layout(), &k, 0, 1, &log)) {
        std.debug.print("{s}\n", .{log.text()});
        return error.NotGenerated;
    }
    try k.finish();
    var w = gpu.Work.init(&work);
    var trap: gpu.interp.Trap = .{};
    _ = gpu.interp.runKernel(&k, gpu.interp_caps, groups, bindings, &.{}, &w, &trap) catch |e| {
        std.debug.print("trap at {d}\n", .{trap.pc});
        return e;
    };
}

fn image(mem: []u8, w: u32, h: u32, fmt: engine.Format) engine.Image {
    return .{ .buf = .{ .cpu = mem, .bytes = mem.len }, .width = w, .height = h, .stride = w * fmt.bytes(), .format = fmt };
}

fn f32At(b: []const u8, i: usize) f32 {
    return @bitCast(std.mem.readInt(u32, b[4 * i ..][0..4], .little));
}
fn u32At(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[4 * i ..][0..4], .little);
}
fn putF32(b: []u8, i: usize, v: f32) void {
    std.mem.writeInt(u32, b[4 * i ..][0..4], @bitCast(v), .little);
}
fn putU32(b: []u8, i: usize, v: u32) void {
    std.mem.writeInt(u32, b[4 * i ..][0..4], v, .little);
}

test "compute: a typed UAV (RGBA32F, then RGBA8) from a texture and the thread id" {
    var src: [16 * 16 * 16]u8 align(16) = undefined;
    var dst: [16 * 16 * 16]u8 align(16) = undefined;
    for (0..16 * 16 * 4) |i| putF32(&src, i, @floatFromInt(i % 7));
    var uni: [4 + 2 * D]u32 = undefined;
    var scale = [4]f32{ 0.5, 2, -1, 0.25 };
    for (scale, 0..) |s, c| uni[c] = @bitCast(s);
    var si = image(&src, 16, 16, .rgba32f);
    texture.descriptor(.{ .img = &si }, uni[4..][0..D]);
    // RGBA32F
    var di = image(&dst, 16, 16, .rgba32f);
    texture.descriptor(.{ .img = &di }, uni[4 + D ..][0..D]);
    var l = Lay{ .cb_vecs = 1, .textures = 1 };
    l.uavs[0] = .{ .b = 2, .word = 4 + D };
    @memset(&dst, 0);
    try run(&fx.cs_typed, &l, &.{ std.mem.sliceAsBytes(&uni), &src, &dst }, .{ 2, 2, 1 });
    for (0..16) |y| for (0..16) |x| for (0..4) |c| {
        const at = (y * 16 + x) * 4 + c;
        const add: f32 = if (c == 0) @floatFromInt(x) else if (c == 1) @floatFromInt(y) else 0;
        try std.testing.expectEqual(f32At(&src, at) * scale[c] + add, f32At(&dst, at));
    };
    // RGBA8: each channel clamped to [0, 1], times 255, rounded
    var dst8: [16 * 16 * 4]u8 align(16) = undefined;
    var d8 = image(&dst8, 16, 16, .rgba8);
    texture.descriptor(.{ .img = &d8 }, uni[4 + D ..][0..D]);
    for (&scale, 0..) |*s, c| s.* = 1.0 / 32.0 * @as(f32, @floatFromInt(c + 1));
    for (scale, 0..) |s, c| uni[c] = @bitCast(s);
    // (the thread's place added: most channels clamp to 1, the first row and column don't)
    @memset(&dst8, 0);
    try run(&fx.cs_typed, &l, &.{ std.mem.sliceAsBytes(&uni), &src, &dst8 }, .{ 2, 2, 1 });
    for (0..16) |y| for (0..16) |x| for (0..4) |c| {
        const add: f32 = if (c == 0) @floatFromInt(x) else if (c == 1) @floatFromInt(y) else 0;
        const v = f32At(&src, (y * 16 + x) * 4 + c) * scale[c] + add;
        const want: u8 = @intFromFloat(@floor(std.math.clamp(v, 0, 1) * 255 + 0.5));
        try std.testing.expectEqual(want, dst8[(y * 16 + x) * 4 + c]);
    };
}

test "compute: structured buffers, GetDimensions and an early return" {
    const N = 100;
    var in: [N * 20]u8 align(16) = undefined;
    var out: [N * 20 + 64]u8 align(16) = undefined;
    for (0..N) |i| {
        for (0..3) |c| putF32(&in, i * 5 + c, @floatFromInt(i + c));
        putF32(&in, i * 5 + 3, @floatFromInt(i % 3));
        putU32(&in, i * 5 + 4, @intCast(i * 7));
    }
    @memset(&out, 0xab);
    // (t0 at words 0, 1; u0 at 2, 3: bytes and stride)
    var uni = [4]u32{ N * 20, 20, N * 20, 20 };
    var l = Lay{};
    l.tbufs[0] = .{ .b = 1, .word = 0 };
    l.uavs[0] = .{ .b = 2, .word = 2 };
    try run(&fx.cs_structured, &l, &.{ std.mem.sliceAsBytes(&uni), &in, &out }, .{ 2, 1, 1 });
    for (0..N) |i| {
        const w = f32At(&in, i * 5 + 3);
        for (0..3) |c| try std.testing.expectEqual(f32At(&in, i * 5 + c) + w * @as(f32, @floatFromInt(c + 1)), f32At(&out, i * 5 + c));
        try std.testing.expectEqual(w, f32At(&out, i * 5 + 3));
        try std.testing.expectEqual(@as(u32, @intCast(i * 7 * 2 + 20)), u32At(&out, i * 5 + 4));
    }
    // (the threads past the elements returned: nothing past them written)
    for (out[N * 20 ..]) |b| try std.testing.expectEqual(@as(u8, 0xab), b);
}

test "compute: raw buffers, reversed words and the buffer's bytes" {
    var in: [32 * 16]u8 align(16) = undefined;
    var out: [4100]u8 align(16) = undefined;
    for (0..32 * 4) |i| putU32(&in, i, @intCast(i * 3 + 1));
    @memset(&out, 0);
    var uni = [4]u32{ in.len, 0, out.len, 0 };
    var l = Lay{};
    l.tbufs[0] = .{ .b = 1, .word = 0 };
    l.uavs[0] = .{ .b = 2, .word = 2 };
    try run(&fx.cs_raw, &l, &.{ std.mem.sliceAsBytes(&uni), &in, &out }, .{ 1, 1, 1 });
    for (0..32) |t| for (0..4) |c| {
        try std.testing.expectEqual(u32At(&in, t * 4 + (3 - c)) + @as(u32, @intCast(t)), u32At(&out, t * 4 + c));
    };
    try std.testing.expectEqual(@as(u32, in.len), u32At(&out, 1024));
}

test "compute: groupshared memory across a barrier, every thread id" {
    var out: [128 * 16]u8 align(16) = undefined;
    @memset(&out, 0);
    var uni = [2]u32{ out.len, 16 };
    var l = Lay{};
    l.uavs[0] = .{ .b = 1, .word = 0 };
    try run(&fx.cs_shared, &l, &.{ std.mem.sliceAsBytes(&uni), &out }, .{ 2, 1, 1 });
    for (0..128) |id| {
        const gi = id % 64;
        const group = id / 64;
        const other: f32 = @floatFromInt(group * 64 + 63 - gi);
        try std.testing.expectEqual(other * 0.5, f32At(&out, id * 4));
        try std.testing.expectEqual(@as(f32, @floatFromInt(group)), f32At(&out, id * 4 + 1));
        try std.testing.expectEqual(@as(f32, @floatFromInt(gi)), f32At(&out, id * 4 + 2));
        try std.testing.expectEqual(@as(f32, @floatFromInt(gi)), f32At(&out, id * 4 + 3));
    }
}

test "compute: atomics on a raw buffer, a typed texel and groupshared memory" {
    var counter: [16]u8 align(16) = [_]u8{0} ** 16;
    var old: [64 * 4]u8 align(16) = undefined;
    var grid: [4 * 4]u8 align(16) = [_]u8{0} ** 16;
    var uni: [4 + D]u32 = undefined;
    uni[0] = counter.len;
    uni[1] = 0;
    uni[2] = old.len;
    uni[3] = 4;
    var gi = image(&grid, 4, 1, .r32ui);
    texture.descriptor(.{ .img = &gi }, uni[4..][0..D]);
    var l = Lay{};
    l.uavs[0] = .{ .b = 1, .word = 0 };
    l.uavs[1] = .{ .b = 2, .word = 2 };
    l.uavs[2] = .{ .b = 3, .word = 4 };
    try run(&fx.cs_atomic, &l, &.{ std.mem.sliceAsBytes(&uni), &counter, &old, &grid }, .{ 2, 1, 1 });
    try std.testing.expectEqual(@as(u32, 64), u32At(&counter, 0));
    try std.testing.expectEqual(@as(u32, 63 * 3), u32At(&counter, 1));
    try std.testing.expectEqual(@as(u32, 31 * 32 / 2), u32At(&counter, 2));
    try std.testing.expectEqual(@as(u32, (32 + 63) * 32 / 2), u32At(&counter, 3));
    // (each thread's old count is its own: 0 .. 63 once each)
    var seen = [_]bool{false} ** 64;
    for (0..64) |i| {
        const v = u32At(&old, i);
        try std.testing.expect(v < 64 and !seen[v]);
        seen[v] = true;
    }
    for (0..4) |x| try std.testing.expectEqual(@as(u32, 16), u32At(&grid, x));
}

test "compute: a texture sampled at a level into a typed buffer" {
    var tex: [4 * 4 * 16]u8 align(16) = undefined;
    for (0..4 * 4 * 4) |i| putF32(&tex, i, @floatFromInt((i * 5) % 11));
    var out: [16 * 16]u8 align(16) = undefined;
    @memset(&out, 0);
    var uni: [2 * D]u32 = undefined;
    var ti = image(&tex, 4, 4, .rgba32f);
    texture.descriptor(.{ .img = &ti, .linear = true, .min_linear = true, .wrap_s = .clamp, .wrap_t = .clamp }, uni[0..D]);
    // (a typed buffer: a 1D texture of its 16 elements)
    var oi = image(&out, 16, 1, .rgba32f);
    texture.descriptor(.{ .img = &oi }, uni[D..][0..D]);
    var l = Lay{ .textures = 1 };
    l.uavs[0] = .{ .b = 2, .word = D };
    try run(&fx.cs_sample, &l, &.{ std.mem.sliceAsBytes(&uni), &tex, &out }, .{ 1, 1, 1 });
    for (0..4) |y| for (0..4) |x| for (0..4) |c| {
        const t = struct {
            fn at(b: []const u8, xx: usize, yy: usize, ch: usize) f32 {
                const cy: usize = @min(yy, 3);
                const cx: usize = @min(xx, 3);
                return f32At(b, (cy * 4 + cx) * 4 + ch);
            }
        }.at;
        const top = t(&tex, x, y, c) * 0.5 + t(&tex, x + 1, y, c) * 0.5;
        const bot = t(&tex, x, y + 1, c) * 0.5 + t(&tex, x + 1, y + 1, c) * 0.5;
        try std.testing.expectEqual(top * 0.5 + bot * 0.5, f32At(&out, (y * 4 + x) * 4 + c));
    };
}

test "compute: bit counts, first bits, bit reverse, halves, a bit field and a switch (cs_bits)" {
    var in: [32 * 4]u8 align(16) = undefined;
    var out: [32 * 32]u8 align(16) = undefined;
    // (words with every case of the switch, 0, -1, a sign bit; the low
    // half's exponent below 31: no half NaN or infinity)
    const some = [_]u32{ 0, 0xffff_ffff, 0x8000_0000, 1, 2, 3, 0x1234_5678, 0x8765_4321, 0x7fff_ffff, 0x3c00, 0xbc00_3555, 0x0001_0000 };
    for (0..32) |t| {
        var w: u32 = if (t < some.len) some[t] else @truncate(@as(u64, t) * 0x9e37_79b1);
        if (t >= some.len) w &= ~@as(u32, 0x4000);
        putU32(&in, t, w);
    }
    @memset(&out, 0);
    var uni = [4]u32{ in.len, 0, out.len, 0 };
    var l = Lay{};
    l.tbufs[0] = .{ .b = 1, .word = 0 };
    l.uavs[0] = .{ .b = 2, .word = 2 };
    try run(&fx.cs_bits, &l, &.{ std.mem.sliceAsBytes(&uni), &in, &out }, .{ 1, 1, 1 });
    for (0..32) |t| {
        const x = u32At(&in, t);
        const sx: i32 = @bitCast(x);
        const sw: u32 = switch (x & 3) {
            0 => 10,
            1, 2 => 20 + (x & 3),
            else => 99,
        };
        const bf = (x & ~@as(u32, 0xff0)) | ((sw << 4) & 0xff0);
        const hi: u32 = if (x == 0) 0xffff_ffff else 31 - @as(u32, @clz(x));
        const lo: u32 = if (x == 0) 0xffff_ffff else @ctz(x);
        const shi: u32 = if (sx == 0 or sx == -1) 0xffff_ffff else 31 - @as(u32, @clz(if (sx < 0) ~x else x));
        const h: f16 = @floatCast(@as(f32, @bitCast(x & 0x3fff_ffff)));
        const back: f32 = @floatCast(@as(f16, @bitCast(@as(u16, @truncate(x)))));
        const want = [8]u32{ @popCount(x), hi, lo, @bitReverse(x), @as(u16, @bitCast(h)), @bitCast(back), shi, sw + bf };
        for (want, 0..) |wv, c| {
            const got = u32At(&out, t * 8 + c);
            // (a half NaN widened: any NaN, as Direct3D allows)
            if (c == 5 and std.math.isNan(back) and std.math.isNan(@as(f32, @bitCast(got)))) continue;
            if (got != wv) {
                std.debug.print("cs_bits thread {d} (x {x}) word {d}: got {x}, want {x}\n", .{ t, x, c, got, wv });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "compute: a local array indexed at run time (an indexable temp, cs_xarr)" {
    var out: [16 * 4]u8 align(16) = undefined;
    @memset(&out, 0);
    var uni = [2]u32{ out.len, 0 };
    var l = Lay{};
    l.uavs[0] = .{ .b = 1, .word = 0 };
    try run(&fx.cs_xarr, &l, &.{ std.mem.sliceAsBytes(&uni), &out }, .{ 1, 1, 1 });
    for (0..16) |t_| {
        const t: u32 = @intCast(t_);
        var a: [8]u32 = undefined;
        for (&a, 0..) |*e, i| e.* = @as(u32, @intCast(i * i)) + t;
        a[t & 7] += 100;
        try std.testing.expectEqual(a[(t * 3) & 7] + a[t & 7], u32At(&out, t));
    }
}

test "compute: Gather (red, and green with an offset) from a 4x4 texture (cs_gather)" {
    var tex: [4 * 4 * 16]u8 align(16) = undefined;
    for (0..4 * 4 * 4) |i| putF32(&tex, i, @floatFromInt((i * 7) % 13));
    var out: [32 * 16]u8 align(16) = undefined;
    @memset(&out, 0);
    var uni: [2 * D]u32 = undefined;
    var ti = image(&tex, 4, 4, .rgba32f);
    texture.descriptor(.{ .img = &ti, .linear = true, .min_linear = true, .wrap_s = .clamp, .wrap_t = .clamp }, uni[0..D]);
    var oi = image(&out, 32, 1, .rgba32f);
    texture.descriptor(.{ .img = &oi }, uni[D..][0..D]);
    var l = Lay{ .textures = 1 };
    l.uavs[0] = .{ .b = 2, .word = D };
    try run(&fx.cs_gather, &l, &.{ std.mem.sliceAsBytes(&uni), &tex, &out }, .{ 1, 1, 1 });
    const at = struct {
        fn f_(b: []const u8, xx: i32, yy: i32, ch: usize) f32 {
            const cx: usize = @intCast(std.math.clamp(xx, 0, 3));
            const cy: usize = @intCast(std.math.clamp(yy, 0, 3));
            return f32At(b, (cy * 4 + cx) * 4 + ch);
        }
    }.f_;
    for (0..4) |y_| for (0..4) |x_| {
        const x: i32 = @intCast(x_);
        const y: i32 = @intCast(y_);
        const n = (y_ * 4 + x_) * 2;
        // (x0, y1), (x1, y1), (x1, y0), (x0, y0)
        for ([2]usize{ 0, 1 }, [2]i32{ 0, -1 }) |ch, dx| {
            const want = [4]f32{ at(&tex, x + dx, y + 1, ch), at(&tex, x + dx + 1, y + 1, ch), at(&tex, x + dx + 1, y, ch), at(&tex, x + dx, y, ch) };
            for (want, 0..) |w, c| try std.testing.expectEqual(w, f32At(&out, (n + ch) * 4 + c));
        }
    };
}
