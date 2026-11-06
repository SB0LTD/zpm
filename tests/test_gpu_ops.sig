//! Every KIR value op in the interpreter against Sig's own arithmetic:
//! integers (wrapping, signed and unsigned, shifts by 32 and more, bfe,
//! dot4), predicates, compares, f32 ops with NaN, infinity and denormals
//! with denormals kept and flushed, fmad fused and unfused, rounding,
//! the conversions in every rounding mode, and the approximate ops'
//! bounds (exact and perturbed).

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const interp = gpu.interp;
const r = kir.r;
const u = kir.u;

const GROUP = 128;
const N = 4096;

var work_mem: [4 << 20]u8 align(64) = undefined;
var insts: [256]kir.Inst = undefined;
var tys: [256]kir.Ty = undefined;
var xs: [N]u32 = undefined;
var ys: [N]u32 = undefined;
var zs: [N]u32 = undefined;
var out: [N]u32 = undefined;

fn flt(x: u32) f32 {
    return @bitCast(x);
}
fn bits(x: f32) u32 {
    return @bitCast(x);
}

const f32_specials = [_]u32{
    0x0000_0000, 0x8000_0000, 0x0000_0001, 0x8000_0001, 0x0040_0000, 0x007f_ffff,
    0x807f_ffff, 0x0080_0000, 0x8080_0000, 0x3f80_0000, 0xbf80_0000, 0x3f00_0000,
    0xbf00_0000, 0x3fc0_0000, 0xbfc0_0000, 0x4020_0000, 0xc020_0000, 0x3eff_ffff,
    0x4b00_0000, 0x4aff_ffff, 0x4b7f_ffff, 0x4f00_0000, 0xcf00_0000, 0x4f80_0000,
    0x4f7f_ffff, 0xcf00_0001, 0x7f7f_ffff, 0xff7f_ffff, 0x7f80_0000, 0xff80_0000,
    0x7fc0_0000, 0xffc0_0001, 0x7f80_0001, 0x477f_e000, 0x477f_f000, 0x477f_efff,
    0x3880_0000, 0x3380_0000, 0x3300_0000, 0x3300_0001, 0x4049_0fdb, 0xc2c8_0000,
};

const int_specials = [_]u32{
    0, 1, 2, 3, 31, 32, 33, 63, 64, 0xff, 0x100, 0xffff, 0x1_0000, 0x7fff_ffff,
    0x8000_0000, 0x8000_0001, 0xffff_fffe, 0xffff_ffff, 0x1234_5678, 0x8765_4321, 0x00ff_00ff, 0x7f7f_8080,
};

var rng = std.Random.DefaultPrng.init(0x5eed_0f0f);

/// Inputs: the specials crossed (the first ones), then random patterns
/// (half of them from the specials' neighbourhood).
fn fill(specials: []const u32) void {
    const rand = rng.random();
    var n: usize = 0;
    for (specials) |a| for (specials) |b| {
        if (n == N) break;
        xs[n] = a;
        ys[n] = b;
        zs[n] = specials[(n * 7) % specials.len];
        n += 1;
    };
    while (n < N) : (n += 1) {
        if (n & 1 == 0) {
            xs[n] = rand.int(u32);
            ys[n] = rand.int(u32);
            zs[n] = rand.int(u32);
        } else {
            xs[n] = specials[rand.uintLessThan(usize, specials.len)] +% rand.intRangeAtMost(u32, 0, 3) -% 1;
            ys[n] = specials[rand.uintLessThan(usize, specials.len)] ^ (rand.int(u32) & 0x8000_0000);
            zs[n] = rand.int(u32);
        }
    }
}

fn capsOf(flush: bool, fused_mad: bool) gpu.Caps {
    var c = gpu.interp_caps;
    c.denormals = if (flush) .flush else .preserve;
    c.mad = if (fused_mad) .fused else .unfused;
    return c;
}

/// out[i] = op(x[i], y[i], z[i]) with the operands loaded as `in_ty`
/// (preds made from them by != 0) and the result stored as bits (a pred
/// as 0/1).
fn runOp(caps: gpu.Caps, op: kir.Op, ty: kir.Ty, in_ty: [3]kir.Ty, aux: u32, nargs: u8) !void {
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, @tagName(op), .{ GROUP, 1, 1 });
    const bx = k.binding();
    const by = k.binding();
    const bz = k.binding();
    const bo = k.binding();
    const ix = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    const off = k.op2(.shl, .u32, r(ix), u(2));
    const binds = [3]u8{ bx, by, bz };
    var args = [3]kir.Arg{ kir.no, kir.no, kir.no };
    for (0..nargs) |j| {
        if (in_ty[j] == .pred) {
            const v = k.load(.u32, kir.global(binds[j], 32), r(off));
            args[j] = r(k.cmp(.u32, .ne, r(v), u(0)));
        } else {
            args[j] = r(k.load(in_ty[j], kir.global(binds[j], 32), r(off)));
        }
    }
    const d = k.opAux(op, ty, args[0], args[1], args[2], aux);
    const res_ty = k.tys[@intFromEnum(d)];
    const val = if (res_ty == .pred) k.sel(.u32, r(d), u(1), u(0)) else d;
    k.store(if (res_ty == .pred) .u32 else res_ty, kir.global(bo, 32), r(off), r(val));
    try k.finish();
    var w = gpu.Work.init(&work_mem);
    var trap: interp.Trap = .{};
    _ = try interp.runKernel(&k, caps, .{ N / GROUP, 1, 1 }, &.{
        std.mem.sliceAsBytes(&xs), std.mem.sliceAsBytes(&ys), std.mem.sliceAsBytes(&zs), std.mem.sliceAsBytes(&out),
    }, &.{}, &w, &trap);
}

fn expectAll(comptime name: []const u8, ref: anytype, ctx: anytype) !void {
    for (0..N) |ix| {
        const want: u32 = ref(ctx, xs[ix], ys[ix], zs[ix]);
        if (want != out[ix]) {
            std.debug.print("{s}: {x:0>8} {x:0>8} {x:0>8} -> want {x:0>8} got {x:0>8}\n", .{ name, xs[ix], ys[ix], zs[ix], want, out[ix] });
            return error.TestExpectedEqual;
        }
    }
}

// ── References, from Sig's arithmetic ──

fn fin(x: u32, fl: bool) f32 {
    if (fl and x & 0x7f80_0000 == 0) return flt(x & 0x8000_0000);
    return flt(x);
}
fn fout(v: f32, fl: bool) u32 {
    if (std.math.isNan(v)) return 0x7fff_ffff;
    const b = bits(v);
    if (fl and b & 0x7f80_0000 == 0) return b & 0x8000_0000;
    return b;
}

const F = struct { fl: bool, fused: bool };

fn refFadd(c: F, a: u32, b: u32, _: u32) u32 {
    return fout(fin(a, c.fl) + fin(b, c.fl), c.fl);
}
fn refFsub(c: F, a: u32, b: u32, _: u32) u32 {
    return fout(fin(a, c.fl) - fin(b, c.fl), c.fl);
}
fn refFmul(c: F, a: u32, b: u32, _: u32) u32 {
    return fout(fin(a, c.fl) * fin(b, c.fl), c.fl);
}
fn refFdiv(c: F, a: u32, b: u32, _: u32) u32 {
    return fout(fin(a, c.fl) / fin(b, c.fl), c.fl);
}
fn refFsqrt(c: F, a: u32, _: u32, _: u32) u32 {
    return fout(@sqrt(fin(a, c.fl)), c.fl);
}
fn refFfma(c: F, a: u32, b: u32, z: u32) u32 {
    // (the CPU's fused multiply-add instruction)
    return fout(@mulAdd(f32, fin(a, c.fl), fin(b, c.fl), fin(z, c.fl)), c.fl);
}
fn refFmad(c: F, a: u32, b: u32, z: u32) u32 {
    if (c.fused) return refFfma(c, a, b, z);
    const p = fout(fin(a, c.fl) * fin(b, c.fl), c.fl);
    return fout(fin(p, c.fl) + fin(z, c.fl), c.fl);
}
fn minmax(c: F, a: u32, b: u32, want_max: bool) u32 {
    const x = fin(a, c.fl);
    const y = fin(b, c.fl);
    if (std.math.isNan(x) and std.math.isNan(y)) return 0x7fff_ffff;
    if (x == 0 and y == 0) {
        const xn = std.math.signbit(x);
        const yn = std.math.signbit(y);
        if (want_max) return bits(if (xn and yn) x else if (xn) y else x);
        return bits(if (xn) x else y);
    }
    return bits(if (want_max) @max(x, y) else @min(x, y));
}
fn refFmin(c: F, a: u32, b: u32, _: u32) u32 {
    return minmax(c, a, b, false);
}
fn refFmax(c: F, a: u32, b: u32, _: u32) u32 {
    return minmax(c, a, b, true);
}
fn refFabs(_: F, a: u32, _: u32, _: u32) u32 {
    return a & 0x7fff_ffff;
}
fn refFneg(_: F, a: u32, _: u32, _: u32) u32 {
    return a ^ 0x8000_0000;
}
fn rne(x: f32) f32 {
    const t = @round(x); // (half away from zero)
    if (@abs(x - @trunc(x)) == 0.5 and @mod(t, 2.0) != 0) return std.math.copysign(t - std.math.copysign(@as(f32, 1.0), x), x);
    return t;
}
fn refFloor(c: F, a: u32, _: u32, _: u32) u32 {
    return fout(@floor(fin(a, c.fl)), c.fl);
}
fn refCeil(c: F, a: u32, _: u32, _: u32) u32 {
    return fout(@ceil(fin(a, c.fl)), c.fl);
}
fn refTrunc(c: F, a: u32, _: u32, _: u32) u32 {
    return fout(@trunc(fin(a, c.fl)), c.fl);
}
fn refRne(c: F, a: u32, _: u32, _: u32) u32 {
    return fout(rne(fin(a, c.fl)), c.fl);
}

const Fc = struct { fl: bool, cmp: kir.Cmp };
fn refFcmp(c: Fc, a: u32, b: u32, _: u32) u32 {
    const x = fin(a, c.fl);
    const y = fin(b, c.fl);
    return @intFromBool(switch (c.cmp) {
        .eq => x == y,
        .ne => x != y or std.math.isNan(x) or std.math.isNan(y),
        .lt => x < y,
        .le => x <= y,
        .gt => x > y,
        .ge => x >= y,
    });
}

const I = struct { op: kir.Op, signed: bool, aux: u32 = 0 };
fn refInt(c: I, a: u32, b: u32, z: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    const sh: u5 = @truncate(b);
    return switch (c.op) {
        .mov => a,
        .iadd => a +% b,
        .isub => a -% b,
        .imul => a *% b,
        .imulhi => if (c.signed) @truncate(@as(u64, @bitCast(@as(i64, sa) * sb)) >> 32) else @truncate(@as(u64, a) * b >> 32),
        .imad => a *% b +% z,
        .ineg => @bitCast(-%sa),
        .iabs => @bitCast(if (sa < 0) -%sa else sa),
        .imin => if (c.signed) @bitCast(@min(sa, sb)) else @min(a, b),
        .imax => if (c.signed) @bitCast(@max(sa, sb)) else @max(a, b),
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .not => ~a,
        .shl => a << sh,
        .shr => if (c.signed) @bitCast(sa >> sh) else a >> sh,
        .bfe => blk: {
            const off: u64 = b & 31;
            const w: u64 = @min(@as(u64, z), 32 - off);
            if (w == 0) break :blk 0;
            const field: u64 = (@as(u64, a) >> @intCast(off)) & ((@as(u64, 1) << @intCast(w)) - 1);
            if (c.signed and (field >> @intCast(w - 1)) & 1 == 1) {
                const ext: i64 = @as(i64, @intCast(field)) - (@as(i64, 1) << @intCast(w));
                break :blk @truncate(@as(u64, @bitCast(ext)));
            }
            break :blk @truncate(field);
        },
        .dot4 => blk: {
            var s: i64 = @as(i32, @bitCast(z));
            for (0..4) |j| {
                const ab: u8 = @truncate(a >> @intCast(8 * j));
                const bb: u8 = @truncate(b >> @intCast(8 * j));
                const mode: kir.Dot4 = @enumFromInt(c.aux);
                const av: i64 = if (mode == .u8u8) ab else @as(i8, @bitCast(ab));
                const bv: i64 = if (mode == .s8s8) @as(i8, @bitCast(bb)) else bb;
                s += av * bv;
            }
            break :blk @truncate(@as(u64, @bitCast(s)));
        },
        .icmp => @intFromBool(switch (@as(kir.Cmp, @enumFromInt(c.aux))) {
            .eq => a == b,
            .ne => a != b,
            .lt => if (c.signed) sa < sb else a < b,
            .le => if (c.signed) sa <= sb else a <= b,
            .gt => if (c.signed) sa > sb else a > b,
            .ge => if (c.signed) sa >= sb else a >= b,
        }),
        .sel => if (z != 0) a else b,
        .pand => @intFromBool(a != 0 and b != 0),
        .por => @intFromBool(a != 0 or b != 0),
        .pnot => @intFromBool(a == 0),
        else => unreachable,
    };
}

test "ops: integers and predicates" {
    fill(&int_specials);
    const caps = capsOf(false, true);
    const two = [3]kir.Ty{ .u32, .u32, .u32 };
    const twos = [3]kir.Ty{ .i32, .i32, .i32 };
    inline for (.{ .mov, .iadd, .isub, .imul, .imulhi, .imad, .ineg, .imin, .imax, .@"and", .@"or", .xor, .not, .shl, .shr, .bfe }) |op| {
        for ([_]bool{ false, true }) |sg| {
            const nargs: u8 = switch (op) {
                .mov, .ineg, .not => 1,
                .imad, .bfe => 3,
                else => 2,
            };
            if (op == .bfe) for (&zs) |*z| {
                z.* &= 63;
            };
            try runOp(caps, op, if (sg) .i32 else .u32, if (sg) twos else two, 0, nargs);
            try expectAll(@tagName(op), refInt, I{ .op = op, .signed = sg });
        }
    }
    try runOp(caps, .iabs, .i32, twos, 0, 1);
    try expectAll("iabs", refInt, I{ .op = .iabs, .signed = true });
    for (0..3) |mode| {
        fill(&int_specials);
        try runOp(caps, .dot4, .i32, twos, @intCast(mode), 3);
        try expectAll("dot4", refInt, I{ .op = .dot4, .signed = true, .aux = @intCast(mode) });
    }
    for (0..6) |cc| for ([_]bool{ false, true }) |sg| {
        try runOp(caps, .icmp, if (sg) .i32 else .u32, if (sg) twos else two, @intCast(cc), 2);
        try expectAll("icmp", refInt, I{ .op = .icmp, .signed = sg, .aux = @intCast(cc) });
    };
    try runOp(caps, .sel, .u32, .{ .u32, .u32, .pred }, 0, 3);
    try expectAll("sel", refInt, I{ .op = .sel, .signed = false });
    inline for (.{ .pand, .por, .pnot }) |op| {
        try runOp(caps, op, .pred, .{ .pred, .pred, .pred }, 0, if (op == .pnot) 1 else 2);
        try expectAll(@tagName(op), refInt, I{ .op = op, .signed = false });
    }
}

test "ops: f32 arithmetic, denormals kept and flushed, NaN and infinity" {
    const ff = [3]kir.Ty{ .f32, .f32, .f32 };
    for ([_]bool{ false, true }) |fl| for ([_]bool{ true, false }) |fused| {
        fill(&f32_specials);
        const caps = capsOf(fl, fused);
        const c = F{ .fl = fl, .fused = fused };
        try runOp(caps, .fadd, .f32, ff, 0, 2);
        try expectAll("fadd", refFadd, c);
        try runOp(caps, .fsub, .f32, ff, 0, 2);
        try expectAll("fsub", refFsub, c);
        try runOp(caps, .fmul, .f32, ff, 0, 2);
        try expectAll("fmul", refFmul, c);
        try runOp(caps, .fdiv, .f32, ff, 0, 2);
        try expectAll("fdiv", refFdiv, c);
        try runOp(caps, .fsqrt, .f32, ff, 0, 1);
        try expectAll("fsqrt", refFsqrt, c);
        try runOp(caps, .ffma, .f32, ff, 0, 3);
        try expectAll("ffma", refFfma, c);
        try runOp(caps, .fmad, .f32, ff, 0, 3);
        try expectAll("fmad", refFmad, c);
        try runOp(caps, .fmin, .f32, ff, 0, 2);
        try expectAll("fmin", refFmin, c);
        try runOp(caps, .fmax, .f32, ff, 0, 2);
        try expectAll("fmax", refFmax, c);
        try runOp(caps, .fabs, .f32, ff, 0, 1);
        try expectAll("fabs", refFabs, c);
        try runOp(caps, .fneg, .f32, ff, 0, 1);
        try expectAll("fneg", refFneg, c);
        try runOp(caps, .ffloor, .f32, ff, 0, 1);
        try expectAll("ffloor", refFloor, c);
        try runOp(caps, .fceil, .f32, ff, 0, 1);
        try expectAll("fceil", refCeil, c);
        try runOp(caps, .ftrunc, .f32, ff, 0, 1);
        try expectAll("ftrunc", refTrunc, c);
        try runOp(caps, .frne, .f32, ff, 0, 1);
        try expectAll("frne", refRne, c);
        for (0..6) |cc| {
            try runOp(caps, .fcmp, .f32, ff, @intCast(cc), 2);
            try expectAll("fcmp", refFcmp, Fc{ .fl = fl, .cmp = @enumFromInt(cc) });
        }
    };
}

test "ops: fmad's rounding follows Caps.mad" {
    // a*b+c with c = -round(a*b): fused gives the product's error, unfused 0
    const a: f32 = 1.0 + 0x1p-12;
    const b: f32 = 1.0 + 0x1p-12;
    const c: f32 = -(a * b);
    for (&xs) |*x| x.* = bits(a);
    for (&ys) |*y| y.* = bits(b);
    for (&zs) |*z| z.* = bits(c);
    const ff = [3]kir.Ty{ .f32, .f32, .f32 };
    try runOp(capsOf(false, true), .fmad, .f32, ff, 0, 3);
    try std.testing.expectEqual(bits(0x1p-24), out[0]);
    try runOp(capsOf(false, false), .fmad, .f32, ff, 0, 3);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
}

// ── Conversions ──

fn toInt(x: f32, signed: bool, mode: kir.Round) u32 {
    if (std.math.isNan(x)) return 0;
    const v: f64 = switch (mode) {
        .rne => rne(x),
        .rz => @trunc(x),
        .rd => @floor(x),
        .ru => @ceil(x),
    };
    if (signed) return @bitCast(@as(i32, @intFromFloat(std.math.clamp(v, -2147483648.0, 2147483647.0))));
    return @intFromFloat(std.math.clamp(v, 0.0, 4294967295.0));
}

fn stepToward(v: f32, toward: f32) f32 {
    return std.math.nextAfter(f32, v, toward);
}

fn fromInt(n: u32, signed: bool, mode: kir.Round) f32 {
    const exact: f64 = if (signed) @floatFromInt(@as(i32, @bitCast(n))) else @floatFromInt(n);
    const v: f32 = @floatCast(exact);
    const vd: f64 = v;
    return switch (mode) {
        .rne => v,
        .rz => if (@abs(vd) > @abs(exact)) stepToward(v, 0) else v,
        .rd => if (vd > exact) stepToward(v, -std.math.inf(f32)) else v,
        .ru => if (vd < exact) stepToward(v, std.math.inf(f32)) else v,
    };
}

fn toHalf(xb: u32, mode: kir.Round) u32 {
    const x = flt(xb);
    if (std.math.isNan(x)) return 0x7fff;
    const h: f16 = @floatCast(x); // (to nearest even)
    const hd: f64 = h;
    const xd: f64 = x;
    const g: f16 = switch (mode) {
        .rne => h,
        .rz => if (@abs(hd) > @abs(xd)) std.math.nextAfter(f16, h, 0) else h,
        .rd => if (hd > xd) std.math.nextAfter(f16, h, -std.math.inf(f16)) else h,
        .ru => if (hd < xd) std.math.nextAfter(f16, h, std.math.inf(f16)) else h,
    };
    return @as(u16, @bitCast(g));
}

const Cv = struct { cv: kir.Cvt, fl: bool };
fn refCvt(c: Cv, a: u32, _: u32, _: u32) u32 {
    const from_int = c.cv.from == .u32 or c.cv.from == .i32;
    const to_int = c.cv.to == .u32 or c.cv.to == .i32;
    if (from_int and to_int) return a;
    if (from_int) return fout(fromInt(a, c.cv.from == .i32, c.cv.round), c.fl);
    if (c.cv.from == .f16) {
        const v: f32 = @floatCast(@as(f16, @bitCast(@as(u16, @truncate(a)))));
        if (c.cv.to == .f32) return if (std.math.isNan(v)) 0x7fff_ffff else bits(v);
        return toInt(v, c.cv.to == .i32, c.cv.round);
    }
    const x = fin(a, c.fl);
    if (to_int) return toInt(x, c.cv.to == .i32, c.cv.round);
    return toHalf(bits(x), c.cv.round);
}

test "ops: cvt in every rounding mode" {
    for ([_]bool{ false, true }) |fl| {
        const caps = capsOf(fl, true);
        for (0..4) |rm| {
            const round: kir.Round = @enumFromInt(rm);
            // f32 -> u32, i32, f16
            for ([_]kir.Ty{ .u32, .i32, .f16 }) |to| {
                fill(&f32_specials);
                const cv = kir.Cvt{ .from = .f32, .to = to, .round = round };
                try runOp(caps, .cvt, to, .{ .f32, .f32, .f32 }, @bitCast(cv), 1);
                try expectAll("cvt from f32", refCvt, Cv{ .cv = cv, .fl = fl });
            }
            // u32, i32 -> f32
            for ([_]kir.Ty{ .u32, .i32 }) |from| {
                fill(&int_specials);
                const cv = kir.Cvt{ .from = from, .to = .f32, .round = round };
                try runOp(caps, .cvt, .f32, .{ from, from, from }, @bitCast(cv), 1);
                try expectAll("cvt to f32", refCvt, Cv{ .cv = cv, .fl = fl });
            }
        }
        // f16 -> f32: every half
        for (0..N) |ix| xs[ix] = @intCast(ix * 16);
        const cv = kir.Cvt{ .from = .f16, .to = .f32, .round = .rne };
        var n: u32 = 0;
        while (n < 0x10000) : (n += N) {
            for (0..N) |ix| xs[ix] = n + @as(u32, @intCast(ix));
            try runOp(caps, .cvt, .f32, .{ .f16, .f16, .f16 }, @bitCast(cv), 1);
            try expectAll("cvt f16 to f32", refCvt, Cv{ .cv = cv, .fl = fl });
        }
    }
}

// ── The approximate ops ──

test "ops: the approximate ops within their bounds, exact and perturbed" {
    const rand = rng.random();
    for (0..N) |ix| {
        // positive normals over a wide range, and |x| <= pi for sin/cos
        xs[ix] = (rand.intRangeAtMost(u32, 64, 190) << 23) | (rand.int(u32) & 0x7f_ffff);
    }
    const ops = [_]kir.Op{ .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos };
    for ([_]u32{ 0, 2 }) |jitter| for (ops) |op| {
        var src: [N]u32 = xs;
        if (op == .fexp2) for (&src) |*x| {
            x.* = bits(@mod(flt(x.*), 200.0) - 100.0);
        };
        if (op == .fsin or op == .fcos) for (&src) |*x| {
            x.* = bits(@mod(flt(x.*), 2.0 * std.math.pi) - std.math.pi);
        };
        const saved = xs;
        xs = src;
        var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "approx", .{ GROUP, 1, 1 });
        const bx = k.binding();
        const bo = k.binding();
        const ix = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
        const off = k.op2(.shl, .u32, r(ix), u(2));
        const v = k.op1(op, .f32, r(k.load(.f32, kir.global(bx, 32), r(off))));
        k.store(.f32, kir.global(bo, 32), r(off), r(v));
        try k.finish();
        var w = gpu.Work.init(&work_mem);
        var trap: interp.Trap = .{};
        var stats: interp.Stats = .{};
        try interp.run(.{
            .code = k.code(),
            .regs = k.nv,
            .group = k.group,
            .shared_bytes = 0,
            .groups = .{ N / GROUP, 1, 1 },
            .bindings = &.{ std.mem.sliceAsBytes(&xs), std.mem.sliceAsBytes(&out) },
            .params = &.{},
            .jitter_ulps = jitter,
        }, gpu.interp_caps, &w, &trap, &stats);
        for (0..N) |j| {
            const x: f64 = flt(xs[j]);
            const truth: f64 = switch (op) {
                .frcp => 1.0 / x,
                .frsq => 1.0 / @sqrt(x),
                .fexp2 => std.math.exp2(x),
                .flog2 => std.math.log2(x),
                .fsin => @sin(x),
                .fcos => @cos(x),
                else => unreachable,
            };
            const g: f64 = flt(out[j]);
            // relative bounds (absolute for log2 near 1, sin, cos)
            const err = @abs(g - truth);
            const ok = switch (op) {
                .flog2, .fsin, .fcos => err <= 0x1p-21 * @max(@abs(truth), 1.0),
                else => err <= 0x1p-21 * @abs(truth),
            };
            if (!ok) {
                std.debug.print("{s} jitter {d}: x {e} got {e} truth {e}\n", .{ @tagName(op), jitter, x, g, truth });
                return error.TestExpectedEqual;
            }
        }
        xs = saved;
    };
}
