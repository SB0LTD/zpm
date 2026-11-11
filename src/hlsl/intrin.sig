//! @zpm/hlsl intrin — HLSL's intrinsic functions and the methods of its
//! objects (textures' Sample, SampleLevel, SampleBias, SampleGrad,
//! SampleCmp, SampleCmpLevelZero, Load, GetDimensions, Gather; streams'
//! Append and RestartStrip), as DXBC instructions. The ones DXBC has no
//! instruction for (atan, asin, acos, pow, fmod, smoothstep, ...) are the
//! sequences fxc writes, with its approximations' constants.

const std = @import("std");
const ast = @import("ast.sig");
const ir = @import("ir.sig");
const gen = @import("gen.sig");

const Gen = gen.Gen;
const Val = gen.Val;
const Src = gen.Src;
const NONE = ast.NONE;
const imm1 = Gen.imm1;
const component = Gen.component;
const broadcast = Gen.broadcast;
const mkVal = Gen.mkVal;

fn F(f: f32) Src {
    return imm1(@bitCast(f));
}

fn neg(s: Src) Src {
    var x = s;
    if (x.reg == .imm32) {
        for (&x.imm) |*w| w.* = gen.applyMods(w.*, x.mods) ^ 0x8000_0000;
        x.mods = 0;
    } else x.mods ^= 1;
    return x;
}

fn absS(s: Src) Src {
    var x = s;
    if (x.reg == .imm32) {
        for (&x.imm) |*w| w.* = gen.applyMods(w.*, x.mods) & 0x7fff_ffff;
        x.mods = 0;
    } else x.mods = 2;
    return x;
}

const MAX_ARGS = 8;

/// An intrinsic call.
pub fn call(g: *Gen, n: u32) Val {
    const node = g.a.nodes[n];
    const name = g.tokText(node.tok);
    var argn: [MAX_ARGS]u32 = undefined;
    var argc: usize = 0;
    var e = node.a;
    while (e != NONE) : (e = g.a.nodes[e].next) {
        if (argc >= MAX_ARGS) {
            g.fail("too many arguments to {s}", .{name});
            return none(g);
        }
        argn[argc] = e;
        argc += 1;
    }
    // out arguments first need their places
    if (eq(name, "sincos")) return sincosCall(g, argn[0..argc]);
    if (eq(name, "modf")) return modfCall(g, argn[0..argc]);
    var args: [MAX_ARGS]Val = undefined;
    for (argn[0..argc], 0..) |a, k| {
        args[k] = g.expr(a);
        if (g.failed) return none(g);
    }
    return intrinsic(g, name, args[0..argc]);
}

fn none(g: *Gen) Val {
    return g.immVal(g.scalarTy(.float), 0);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The float version of a numeric type (ints and bools to float).
fn floatTy(g: *Gen, t: u32) u32 {
    return g.a.withBase(t, .float);
}

/// Each row of `v` (as type `t`) through `f`.
fn perRow(g: *Gen, t: u32, v0: Val, f: *const fn (*Gen, u8, Src) Src) Val {
    const v = g.canonRows(g.convert(v0, t));
    const first = g.newSrcs(v.n);
    for (0..v.n) |r| g.srcs[first + r] = f(g, g.rowInfo(t, @intCast(r)).n, g.srcs[v.at + r]);
    return mkVal(t, first, v.n);
}

fn perRow2(g: *Gen, t: u32, a0: Val, b0: Val, f: *const fn (*Gen, u8, Src, Src) Src) Val {
    const a = g.canonRows(g.convert(a0, t));
    const b = g.canonRows(g.convert(b0, t));
    const first = g.newSrcs(a.n);
    for (0..a.n) |r| g.srcs[first + r] = f(g, g.rowInfo(t, @intCast(r)).n, g.srcs[a.at + r], g.srcs[b.at + r]);
    return mkVal(t, first, a.n);
}

fn perRow3(g: *Gen, t: u32, a0: Val, b0: Val, c0: Val, f: *const fn (*Gen, u8, Src, Src, Src) Src) Val {
    const a = g.canonRows(g.convert(a0, t));
    const b = g.canonRows(g.convert(b0, t));
    const c = g.canonRows(g.convert(c0, t));
    const first = g.newSrcs(a.n);
    for (0..a.n) |r| g.srcs[first + r] = f(g, g.rowInfo(t, @intCast(r)).n, g.srcs[a.at + r], g.srcs[b.at + r], g.srcs[c.at + r]);
    return mkVal(t, first, a.n);
}

fn need(g: *Gen, name: []const u8, args: []const Val, n: usize) bool {
    if (args.len != n) {
        g.fail("'{s}': {d} arguments, {d} expected", .{ name, args.len, n });
        return false;
    }
    for (args) |a| if (a.kind == .object or a.kind == .none) {
        g.fail("'{s}': an argument is not a value", .{name});
        return false;
    };
    return true;
}

fn common2(g: *Gen, a: Val, b: Val) u32 {
    return g.common(a.ty, b.ty, null) orelse a.ty;
}

const one_f: u32 = 0x3f80_0000;

// the per-row bodies

fn rSqrt(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.sqrt, n, &.{s});
}
fn rRsq(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.rsq, n, &.{s});
}
fn rRcp(g: *Gen, n: u8, s: Src) Src {
    if (g.target.major >= 5) return g.alu(.rcp, n, &.{s});
    return g.alu(.div, n, &.{ F(1), s });
}
fn rExp2(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.exp, n, &.{s});
}
fn rLog2(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.log, n, &.{s});
}
fn rExp(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.exp, n, &.{g.alu(.mul, n, &.{ s, F(1.442695) })});
}
fn rLog(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.mul, n, &.{ g.alu(.log, n, &.{s}), F(0.693147) });
}
fn rLog10(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.mul, n, &.{ g.alu(.log, n, &.{s}), F(0.301030) });
}
fn rFloor(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.round_ni, n, &.{s});
}
fn rCeil(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.round_pi, n, &.{s});
}
fn rRound(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.round_ne, n, &.{s});
}
fn rTrunc(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.round_z, n, &.{s});
}
fn rFrac(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.frc, n, &.{s});
}
fn rSat(g: *Gen, n: u8, s: Src) Src {
    return g.aluSat(.mov, n, &.{s}, true);
}
fn rAbsF(g: *Gen, n: u8, s: Src) Src {
    _ = g;
    var x = absS(s);
    x.n = n;
    return x;
}
fn rAbsI(g: *Gen, n: u8, s0: Src) Src {
    const s = g.plain(s0);
    return g.alu(.imax, n, &.{ s, g.alu(.ineg, n, &.{s}) });
}
fn rSin(g: *Gen, n: u8, s: Src) Src {
    return sincos1(g, n, s, true);
}
fn rCos(g: *Gen, n: u8, s: Src) Src {
    return sincos1(g, n, s, false);
}
fn rTan(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.div, n, &.{ sincos1(g, n, s, true), sincos1(g, n, s, false) });
}
fn rDegrees(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.mul, n, &.{ s, F(57.295780) });
}
fn rRadians(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.mul, n, &.{ s, F(0.0174532924) });
}
fn rIsNan(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.ne, n, &.{ s, s });
}
fn rIsInf(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.eq, n, &.{ absS(s), imm1(0x7f80_0000) });
}
fn rIsFinite(g: *Gen, n: u8, s: Src) Src {
    const inf = g.alu(.eq, n, &.{ absS(s), imm1(0x7f80_0000) });
    const nan = g.alu(.ne, n, &.{ s, s });
    return g.alu(.not, n, &.{g.alu(.@"or", n, &.{ inf, nan })});
}
fn rSinh(g: *Gen, n: u8, s: Src) Src {
    const a = rExp(g, n, s);
    const b = rExp(g, n, neg(s));
    return g.alu(.mul, n, &.{ g.alu(.add, n, &.{ a, neg(b) }), F(0.5) });
}
fn rCosh(g: *Gen, n: u8, s: Src) Src {
    const a = rExp(g, n, s);
    const b = rExp(g, n, neg(s));
    return g.alu(.mul, n, &.{ g.alu(.add, n, &.{ a, b }), F(0.5) });
}
fn rTanh(g: *Gen, n: u8, s: Src) Src {
    // (e^2x - 1) / (e^2x + 1), clamped where e^2x overflows
    const x = g.alu(.min, n, &.{ g.alu(.max, n, &.{ s, F(-40) }), F(40) });
    const e2 = rExp(g, n, g.alu(.add, n, &.{ x, x }));
    return g.alu(.div, n, &.{ g.alu(.add, n, &.{ e2, F(-1) }), g.alu(.add, n, &.{ e2, F(1) }) });
}
fn rBfrev(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.bfrev, n, &.{g.plain(s)});
}
fn rCountbits(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.countbits, n, &.{g.plain(s)});
}
fn rFirstLo(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.firstbit_lo, n, &.{g.plain(s)});
}
fn rFirstHiU(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.firstbit_hi, n, &.{g.plain(s)});
}
fn rFirstHiI(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.firstbit_shi, n, &.{g.plain(s)});
}
fn rF32toF16(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.f32tof16, n, &.{s});
}
fn rF16toF32(g: *Gen, n: u8, s: Src) Src {
    return g.alu(.f16tof32, n, &.{g.plain(s)});
}

fn sincos1(g: *Gen, n: u8, s: Src, want_sin: bool) Src {
    if (s.reg == .imm32) {
        var r = Src{ .reg = .imm32, .n = n };
        for (0..4) |c| {
            const x: f32 = @bitCast(gen.applyMods(if (s.n == 1) s.imm[0] else s.imm[c], s.mods));
            r.imm[c] = @bitCast(if (want_sin) @sin(x) else @cos(x));
        }
        return r;
    }
    const v = g.vreg();
    var i = ir.Inst{ .op = .sincos, .n = 3, .ndst = 2 };
    const d = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, n);
    const nul = ir.Opnd{ .reg = .null, .comps = 0, .dims = 0 };
    i.ops[0] = if (want_sin) d else nul;
    i.ops[1] = if (want_sin) nul else d;
    i.ops[2] = g.opnd(s, .{ 0, 1, 2, 3 }, n);
    g.emit(i);
    return Gen.tempSrc(v, n);
}

fn rMinF(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.min, n, &.{ a, b });
}
fn rMaxF(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.max, n, &.{ a, b });
}
fn rMinI(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.imin, n, &.{ g.plain(a), g.plain(b) });
}
fn rMaxI(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.imax, n, &.{ g.plain(a), g.plain(b) });
}
fn rMinU(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.umin, n, &.{ g.plain(a), g.plain(b) });
}
fn rMaxU(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.umax, n, &.{ g.plain(a), g.plain(b) });
}
fn rPow(g: *Gen, n: u8, a: Src, b: Src) Src {
    return g.alu(.exp, n, &.{g.alu(.mul, n, &.{ g.alu(.log, n, &.{a}), b })});
}
fn rStep(g: *Gen, n: u8, a: Src, x: Src) Src {
    return g.alu(.@"and", n, &.{ g.alu(.ge, n, &.{ x, a }), imm1(one_f) });
}
fn rLdexp(g: *Gen, n: u8, a: Src, e: Src) Src {
    return g.alu(.mul, n, &.{ a, g.alu(.exp, n, &.{e}) });
}
fn rAtan2(g: *Gen, n: u8, y: Src, x: Src) Src {
    const ax = absS(x);
    const ay = absS(y);
    const t = g.alu(.div, n, &.{ g.alu(.min, n, &.{ ax, ay }), g.alu(.max, n, &.{ ax, ay }) });
    var p = atanPoly(g, n, t);
    // |y| > |x|: pi/2 - p
    const swap = g.alu(.lt, n, &.{ ax, ay });
    p = g.alu(.movc, n, &.{ swap, g.alu(.add, n, &.{ neg(p), F(1.570796) }), p });
    const xneg = g.alu(.lt, n, &.{ x, neg(x) });
    p = g.alu(.movc, n, &.{ xneg, g.alu(.add, n, &.{ neg(p), F(3.141593) }), p });
    const yneg = g.alu(.lt, n, &.{ y, neg(y) });
    return g.alu(.movc, n, &.{ yneg, neg(p), p });
}

/// fxc's atan polynomial on t in [0, 1].
fn atanPoly(g: *Gen, n: u8, t: Src) Src {
    const s = g.alu(.mul, n, &.{ t, t });
    var p = g.alu(.mad, n, &.{ s, F(0.020835), F(-0.085133) });
    p = g.alu(.mad, n, &.{ s, p, F(0.180141) });
    p = g.alu(.mad, n, &.{ s, p, F(-0.330299) });
    p = g.alu(.mad, n, &.{ s, p, F(0.999866) });
    return g.alu(.mul, n, &.{ p, t });
}

fn rAtan(g: *Gen, n: u8, x: Src) Src {
    const ax = absS(x);
    const big = g.alu(.lt, n, &.{ F(1), ax });
    const t = g.alu(.movc, n, &.{ big, g.alu(.div, n, &.{ F(1), ax }), ax });
    var p = atanPoly(g, n, t);
    p = g.alu(.movc, n, &.{ big, g.alu(.add, n, &.{ neg(p), F(1.570796) }), p });
    const xneg = g.alu(.lt, n, &.{ x, neg(x) });
    return g.alu(.movc, n, &.{ xneg, neg(p), p });
}

/// acos as fxc approximates it: sqrt(1 - |x|) * poly(|x|), mirrored for x < 0.
fn rAcos(g: *Gen, n: u8, x: Src) Src {
    const ax = absS(x);
    var p = g.alu(.mad, n, &.{ ax, F(-0.0187293), F(0.0742610) });
    p = g.alu(.mad, n, &.{ p, ax, F(-0.2121144) });
    p = g.alu(.mad, n, &.{ p, ax, F(1.5707288) });
    const r = g.alu(.sqrt, n, &.{g.alu(.add, n, &.{ neg(ax), F(1) })});
    const a = g.alu(.mul, n, &.{ r, p });
    const xneg = g.alu(.lt, n, &.{ x, neg(x) });
    return g.alu(.movc, n, &.{ xneg, g.alu(.add, n, &.{ neg(a), F(3.141593) }), a });
}

fn rAsin(g: *Gen, n: u8, x: Src) Src {
    return g.alu(.add, n, &.{ neg(rAcos(g, n, x)), F(1.570796) });
}

fn rLerp(g: *Gen, n: u8, a: Src, b: Src, t: Src) Src {
    return g.alu(.mad, n, &.{ t, g.alu(.add, n, &.{ b, neg(a) }), a });
}
fn rMad(g: *Gen, n: u8, a: Src, b: Src, c: Src) Src {
    return g.alu(.mad, n, &.{ a, b, c });
}
fn rMadI(g: *Gen, n: u8, a: Src, b: Src, c: Src) Src {
    return g.alu(.iadd, n, &.{ g.alu(.imul, n, &.{ g.plain(a), g.plain(b) }), g.plain(c) });
}
fn rClampF(g: *Gen, n: u8, x: Src, a: Src, b: Src) Src {
    return g.alu(.min, n, &.{ g.alu(.max, n, &.{ x, a }), b });
}
fn rClampI(g: *Gen, n: u8, x: Src, a: Src, b: Src) Src {
    return g.alu(.imin, n, &.{ g.alu(.imax, n, &.{ g.plain(x), g.plain(a) }), g.plain(b) });
}
fn rClampU(g: *Gen, n: u8, x: Src, a: Src, b: Src) Src {
    return g.alu(.umin, n, &.{ g.alu(.umax, n, &.{ g.plain(x), g.plain(a) }), g.plain(b) });
}
fn rSmooth(g: *Gen, n: u8, a: Src, b: Src, x: Src) Src {
    // t = saturate((x - a) / (b - a)); t * t * (3 - 2t)
    const d = g.alu(.div, n, &.{ F(1), g.alu(.add, n, &.{ b, neg(a) }) });
    const t = g.aluSat(.mul, n, &.{ g.alu(.add, n, &.{ x, neg(a) }), d }, true);
    const k = g.alu(.mad, n, &.{ t, F(-2), F(3) });
    return g.alu(.mul, n, &.{ g.alu(.mul, n, &.{ t, t }), k });
}

/// dot of two rows (n components): dp2/dp3/dp4 (floats), multiply-adds
/// (integers).
pub fn dotRow(g: *Gen, n: u8, a: Src, b: Src, int: bool) Src {
    if (int) {
        var acc = g.alu(.imul, 1, &.{ component(g.plain(a), 0), component(g.plain(b), 0) });
        for (1..n) |c| acc = g.alu(.iadd, 1, &.{ acc, g.alu(.imul, 1, &.{ component(g.plain(a), @intCast(c)), component(g.plain(b), @intCast(c)) }) });
        return acc;
    }
    return switch (n) {
        1 => g.alu(.mul, 1, &.{ a, b }),
        2 => dp(g, .dp2, 2, a, b),
        3 => dp(g, .dp3, 3, a, b),
        else => dp(g, .dp4, 4, a, b),
    };
}

fn dp(g: *Gen, op: ir.Op, n: u8, a: Src, b: Src) Src {
    if (a.reg == .imm32 and b.reg == .imm32) {
        var acc: f32 = 0;
        for (0..n) |c| {
            const x: f32 = @bitCast(gen.applyMods(if (a.n == 1) a.imm[0] else a.imm[c], a.mods));
            const y: f32 = @bitCast(gen.applyMods(if (b.n == 1) b.imm[0] else b.imm[c], b.mods));
            acc += x * y;
        }
        return imm1(@bitCast(acc));
    }
    const v = g.vreg();
    var i = ir.Inst{ .op = op, .n = 3 };
    i.ops[0] = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, 1);
    i.ops[1] = g.opnd(a, .{ 0, 1, 2, 3 }, n);
    i.ops[2] = g.opnd(b, .{ 0, 1, 2, 3 }, n);
    // (dp reads its sources' n components through their swizzles)
    for (1..3) |k| {
        var o = &i.ops[k];
        if (o.reg == .imm32) continue;
        const s = if (k == 1) a else b;
        for (0..4) |c| o.swz[c] = if (c < n) (if (s.n == 1) s.swz[0] else s.swz[c]) else o.swz[0];
    }
    for (1..3) |k| {
        if (i.ops[k].reg != .imm32) continue;
        const s = if (k == 1) a else b;
        i.ops[k].comps = 4;
        for (0..4) |c| i.ops[k].imm[c] = if (c < n) (if (s.n == 1) s.imm[0] else s.imm[c]) else 0;
    }
    g.emit(i);
    return Gen.tempSrc(v, 1);
}

fn scalarOf(g: *Gen, t: u32, s: Src) Val {
    const first = g.newSrcs(1);
    g.srcs[first] = s;
    return mkVal(t, first, 1);
}

fn intrinsic(g: *Gen, name: []const u8, args: []const Val) Val {
    const float_t = g.scalarTy(.float);
    // one argument, componentwise, float
    const F1 = struct { s: []const u8, f: *const fn (*Gen, u8, Src) Src };
    const f1 = [_]F1{
        .{ .s = "sqrt", .f = rSqrt },        .{ .s = "rsqrt", .f = rRsq },      .{ .s = "rcp", .f = rRcp },
        .{ .s = "exp2", .f = rExp2 },        .{ .s = "log2", .f = rLog2 },      .{ .s = "exp", .f = rExp },
        .{ .s = "log", .f = rLog },          .{ .s = "log10", .f = rLog10 },    .{ .s = "floor", .f = rFloor },
        .{ .s = "ceil", .f = rCeil },        .{ .s = "round", .f = rRound },    .{ .s = "trunc", .f = rTrunc },
        .{ .s = "frac", .f = rFrac },        .{ .s = "saturate", .f = rSat },   .{ .s = "sin", .f = rSin },
        .{ .s = "cos", .f = rCos },          .{ .s = "tan", .f = rTan },        .{ .s = "degrees", .f = rDegrees },
        .{ .s = "radians", .f = rRadians },  .{ .s = "sinh", .f = rSinh },      .{ .s = "cosh", .f = rCosh },
        .{ .s = "tanh", .f = rTanh },        .{ .s = "atan", .f = rAtan },      .{ .s = "asin", .f = rAsin },
        .{ .s = "acos", .f = rAcos },        .{ .s = "f32tof16", .f = rF32toF16 },
    };
    for (f1) |x| {
        if (!eq(name, x.s)) continue;
        if (!need(g, name, args, 1)) return none(g);
        if (eq(name, "f32tof16")) return perRow(g, g.a.withBase(args[0].ty, .float), args[0], x.f);
        const t = floatTy(g, args[0].ty);
        const r = perRow(g, t, args[0], x.f);
        if (eq(name, "f32tof16")) return retype(r, g.a.withBase(t, .uint));
        return r;
    }
    if (eq(name, "f16tof32")) {
        if (!need(g, name, args, 1)) return none(g);
        const r = perRow(g, g.a.withBase(args[0].ty, .uint), args[0], rF16toF32);
        return retype(r, g.a.withBase(args[0].ty, .float));
    }
    if (eq(name, "isnan") or eq(name, "isinf") or eq(name, "isfinite")) {
        if (!need(g, name, args, 1)) return none(g);
        const t = floatTy(g, args[0].ty);
        const r = perRow(g, t, args[0], if (eq(name, "isnan")) rIsNan else if (eq(name, "isinf")) rIsInf else rIsFinite);
        return retype(r, g.a.withBase(t, .bool));
    }
    if (eq(name, "abs")) {
        if (!need(g, name, args, 1)) return none(g);
        const b = g.baseOf(args[0].ty);
        if (b == .int) return perRow(g, args[0].ty, args[0], rAbsI);
        if (b == .uint or b == .bool) return args[0];
        return perRow(g, floatTy(g, args[0].ty), args[0], rAbsF);
    }
    if (eq(name, "min") or eq(name, "max")) {
        if (!need(g, name, args, 2)) return none(g);
        const t = common2(g, args[0], args[1]);
        const b = g.baseOf(t);
        const mn = eq(name, "min");
        if (b == .float) return perRow2(g, t, args[0], args[1], if (mn) rMinF else rMaxF);
        if (b == .uint) return perRow2(g, t, args[0], args[1], if (mn) rMinU else rMaxU);
        const ti = g.a.withBase(t, .int);
        return perRow2(g, ti, args[0], args[1], if (mn) rMinI else rMaxI);
    }
    if (eq(name, "clamp")) {
        if (!need(g, name, args, 3)) return none(g);
        const t = g.common(common2(g, args[0], args[1]), args[2].ty, null) orelse args[0].ty;
        const b = g.baseOf(t);
        if (b == .float) return perRow3(g, t, args[0], args[1], args[2], rClampF);
        if (b == .uint) return perRow3(g, t, args[0], args[1], args[2], rClampU);
        return perRow3(g, g.a.withBase(t, .int), args[0], args[1], args[2], rClampI);
    }
    if (eq(name, "pow") or eq(name, "step") or eq(name, "atan2") or eq(name, "ldexp") or eq(name, "fmod")) {
        if (!need(g, name, args, 2)) return none(g);
        const t = floatTy(g, common2(g, args[0], args[1]));
        if (eq(name, "fmod")) return g.fmod(t, g.canonRows(g.convert(args[0], t)), g.canonRows(g.convert(args[1], t)));
        return perRow2(g, t, args[0], args[1], if (eq(name, "pow")) rPow else if (eq(name, "step")) rStep else if (eq(name, "atan2")) rAtan2 else rLdexp);
    }
    if (eq(name, "lerp") or eq(name, "smoothstep")) {
        if (!need(g, name, args, 3)) return none(g);
        const t = floatTy(g, g.common(common2(g, args[0], args[1]), args[2].ty, null) orelse args[0].ty);
        return perRow3(g, t, args[0], args[1], args[2], if (eq(name, "lerp")) rLerp else rSmooth);
    }
    if (eq(name, "mad")) {
        if (!need(g, name, args, 3)) return none(g);
        const t = g.common(common2(g, args[0], args[1]), args[2].ty, null) orelse args[0].ty;
        if (g.baseOf(t) == .float) return perRow3(g, t, args[0], args[1], args[2], rMad);
        return perRow3(g, t, args[0], args[1], args[2], rMadI);
    }
    if (eq(name, "sign")) {
        if (!need(g, name, args, 1)) return none(g);
        const b = g.baseOf(args[0].ty);
        const t = if (b == .float) args[0].ty else g.a.withBase(args[0].ty, .int);
        const v = g.canonRows(g.convert(args[0], t));
        const it = g.a.withBase(t, .int);
        const first = g.newSrcs(v.n);
        for (0..v.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const s = g.srcs[v.at + r];
            const gt = if (b == .float) g.alu(.lt, n, &.{ imm1(0), s }) else g.alu(.ilt, n, &.{ imm1(0), g.plain(s) });
            const lt = if (b == .float) g.alu(.lt, n, &.{ s, imm1(0) }) else g.alu(.ilt, n, &.{ g.plain(s), imm1(0) });
            // true is -1: lt - gt
            g.srcs[first + r] = g.alu(.iadd, n, &.{ lt, g.alu(.ineg, n, &.{gt}) });
        }
        return mkVal(it, first, v.n);
    }
    if (eq(name, "dot")) {
        if (!need(g, name, args, 2)) return none(g);
        const t = common2(g, args[0], args[1]);
        const a = g.canonRows(g.convert(args[0], t));
        const b = g.canonRows(g.convert(args[1], t));
        const int = g.baseOf(t) != .float;
        const n = g.rowInfo(t, 0).n;
        return scalarOf(g, g.a.scalar(if (int) g.baseOf(t) else .float), dotRow(g, n, g.srcs[a.at], g.srcs[b.at], int));
    }
    if (eq(name, "length") or eq(name, "normalize") or eq(name, "distance")) {
        const want: usize = if (eq(name, "distance")) 2 else 1;
        if (!need(g, name, args, want)) return none(g);
        var t = floatTy(g, args[0].ty);
        var v = g.canonRows(g.convert(args[0], t));
        if (want == 2) {
            t = floatTy(g, common2(g, args[0], args[1]));
            v = g.canonRows(g.binaryExpr(.minus, g.convert(args[0], t), g.convert(args[1], t)));
        }
        const s = g.srcs[v.at];
        const n = g.rowInfo(t, 0).n;
        const d = dotRow(g, n, s, s, false);
        if (eq(name, "normalize")) {
            const r = g.alu(.rsq, 1, &.{d});
            return scalarOf(g, t, g.alu(.mul, n, &.{ s, broadcast(r, n) }));
        }
        return scalarOf(g, float_t, g.alu(.sqrt, 1, &.{d}));
    }
    if (eq(name, "cross")) {
        if (!need(g, name, args, 2)) return none(g);
        const t = g.a.vector(.float, 3);
        const a = g.srcs[g.canonRows(g.convert(args[0], t)).at];
        const b = g.srcs[g.canonRows(g.convert(args[1], t)).at];
        const m = g.alu(.mul, 3, &.{ swz(a, .{ 2, 0, 1 }), swz(b, .{ 1, 2, 0 }) });
        return scalarOf(g, t, g.alu(.mad, 3, &.{ swz(a, .{ 1, 2, 0 }), swz(b, .{ 2, 0, 1 }), neg(m) }));
    }
    if (eq(name, "reflect")) {
        if (!need(g, name, args, 2)) return none(g);
        const t = floatTy(g, common2(g, args[0], args[1]));
        const i = g.srcs[g.canonRows(g.convert(args[0], t)).at];
        const nn = g.srcs[g.canonRows(g.convert(args[1], t)).at];
        const n = g.rowInfo(t, 0).n;
        const d = dotRow(g, n, i, nn, false);
        const d2 = g.alu(.add, 1, &.{ d, d });
        return scalarOf(g, t, g.alu(.mad, n, &.{ neg(broadcast(d2, n)), nn, i }));
    }
    if (eq(name, "refract")) {
        if (!need(g, name, args, 3)) return none(g);
        const t = floatTy(g, common2(g, args[0], args[1]));
        const i = g.srcs[g.canonRows(g.convert(args[0], t)).at];
        const nn = g.srcs[g.canonRows(g.convert(args[1], t)).at];
        const eta = g.srcs[g.canonRows(g.convert(args[2], float_t)).at];
        const n = g.rowInfo(t, 0).n;
        // k = 1 - eta^2 (1 - dot(n,i)^2); k < 0 ? 0 : eta i - (eta dot + sqrt k) n
        const d = dotRow(g, n, nn, i, false);
        const k0 = g.alu(.mad, 1, &.{ neg(d), d, F(1) });
        const e2 = g.alu(.mul, 1, &.{ eta, eta });
        const k = g.alu(.mad, 1, &.{ neg(e2), k0, F(1) });
        const sk = g.alu(.sqrt, 1, &.{k});
        const c = g.alu(.mad, 1, &.{ eta, d, sk });
        const r = g.alu(.mad, n, &.{ broadcast(eta, n), i, neg(g.alu(.mul, n, &.{ broadcast(c, n), nn })) });
        const ok = g.alu(.ge, 1, &.{ k, F(0) });
        return scalarOf(g, t, g.alu(.@"and", n, &.{ broadcast(ok, n), r }));
    }
    if (eq(name, "faceforward")) {
        if (!need(g, name, args, 3)) return none(g);
        const t = floatTy(g, args[0].ty);
        const nn = g.srcs[g.canonRows(g.convert(args[0], t)).at];
        const i = g.srcs[g.canonRows(g.convert(args[1], t)).at];
        const ng = g.srcs[g.canonRows(g.convert(args[2], t)).at];
        const n = g.rowInfo(t, 0).n;
        const d = dotRow(g, n, ng, i, false);
        const lt = g.alu(.lt, 1, &.{ d, F(0) });
        return scalarOf(g, t, g.alu(.movc, n, &.{ broadcast(lt, n), nn, neg(nn) }));
    }
    if (eq(name, "any") or eq(name, "all")) {
        if (!need(g, name, args, 1)) return none(g);
        const bt = g.a.withBase(args[0].ty, .bool);
        const v = g.canonRows(g.convert(args[0], bt));
        const is_any = eq(name, "any");
        var acc: ?Src = null;
        for (0..v.n) |r| {
            const s = g.srcs[v.at + r];
            for (0..s.n) |c| {
                const x = component(s, @intCast(c));
                acc = if (acc) |a| g.alu(if (is_any) .@"or" else .@"and", 1, &.{ a, x }) else x;
            }
        }
        return scalarOf(g, g.scalarTy(.bool), acc orelse imm1(0));
    }
    if (eq(name, "ddx") or eq(name, "ddy") or eq(name, "ddx_coarse") or eq(name, "ddy_coarse") or eq(name, "ddx_fine") or eq(name, "ddy_fine") or eq(name, "fwidth")) {
        if (!need(g, name, args, 1)) return none(g);
        if (g.target.stage != .pixel) {
            g.fail("{s} is for pixel shaders", .{name});
            return none(g);
        }
        const t = floatTy(g, args[0].ty);
        const v = g.canonRows(g.convert(args[0], t));
        const first = g.newSrcs(v.n);
        const sm5 = g.target.major >= 5;
        for (0..v.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const s = g.srcs[v.at + r];
            if (eq(name, "fwidth")) {
                const dx = g.alu(.deriv_rtx, n, &.{s});
                const dy = g.alu(.deriv_rty, n, &.{s});
                g.srcs[first + r] = g.alu(.add, n, &.{ absS(dx), absS(dy) });
                continue;
            }
            const op: ir.Op = if (eq(name, "ddx")) .deriv_rtx else if (eq(name, "ddy")) .deriv_rty else if (!sm5) (if (name[2] == 'x') .deriv_rtx else .deriv_rty) else if (eq(name, "ddx_coarse")) .deriv_rtx_coarse else if (eq(name, "ddy_coarse")) .deriv_rty_coarse else if (eq(name, "ddx_fine")) .deriv_rtx_fine else .deriv_rty_fine;
            if (s.reg == .imm32) {
                g.srcs[first + r] = imm1(0);
                g.srcs[first + r].n = n;
            } else g.srcs[first + r] = g.alu(op, n, &.{s});
        }
        return mkVal(t, first, v.n);
    }
    if (eq(name, "clip")) {
        if (!need(g, name, args, 1)) return none(g);
        if (g.target.stage != .pixel) {
            g.fail("clip is for pixel shaders", .{});
            return none(g);
        }
        const t = floatTy(g, args[0].ty);
        const v = g.canonRows(g.convert(args[0], t));
        for (0..v.n) |r| {
            const s = g.srcs[v.at + r];
            const n = g.rowInfo(t, @intCast(r)).n;
            const lt = g.alu(.lt, n, &.{ s, F(0) });
            var any_ = component(lt, 0);
            for (1..n) |c| any_ = g.alu(.@"or", 1, &.{ any_, component(lt, @intCast(c)) });
            var i = ir.Inst{ .op = .discard, .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
            i.ops[0] = g.condOpnd(g.inTemp(any_));
            g.emit(i);
        }
        return .{ .ty = 0, .kind = .none };
    }
    if (eq(name, "asfloat") or eq(name, "asint") or eq(name, "asuint")) {
        if (!need(g, name, args, 1)) return none(g);
        const b: ast.Base = if (eq(name, "asfloat")) .float else if (eq(name, "asint")) .int else .uint;
        const v = g.canonRows(args[0]);
        const first = g.newSrcs(v.n);
        for (0..v.n) |r| g.srcs[first + r] = g.plain(g.srcs[v.at + r]);
        return mkVal(g.a.withBase(args[0].ty, b), first, v.n);
    }
    if (eq(name, "reversebits") or eq(name, "countbits") or eq(name, "firstbitlow") or eq(name, "firstbithigh")) {
        if (!need(g, name, args, 1)) return none(g);
        const b = g.baseOf(args[0].ty);
        const t = g.a.withBase(args[0].ty, if (b == .int) .int else .uint);
        const f: *const fn (*Gen, u8, Src) Src = if (eq(name, "reversebits")) rBfrev else if (eq(name, "countbits")) rCountbits else if (eq(name, "firstbitlow")) rFirstLo else if (b == .int) rFirstHiI else rFirstHiU;
        const v = g.canonRows(g.convert(args[0], t));
        const first = g.newSrcs(v.n);
        for (0..v.n) |r| g.srcs[first + r] = f(g, g.rowInfo(t, @intCast(r)).n, g.srcs[v.at + r]);
        return mkVal(g.a.withBase(t, .uint), first, v.n);
    }
    if (eq(name, "transpose")) {
        if (!need(g, name, args, 1)) return none(g);
        const x = g.ty(args[0].ty);
        if (x.class != .matrix) return args[0];
        const v = g.rows(args[0]);
        const first = g.newSrcs(v.n);
        for (0..v.n) |r| {
            var s = g.srcs[v.at + r];
            s.col = !s.col;
            g.srcs[first + r] = s;
        }
        return mkVal(g.a.matrix(x.base, x.cols, x.rows, .default), first, v.n);
    }
    if (eq(name, "determinant")) {
        if (!need(g, name, args, 1)) return none(g);
        return scalarOf(g, float_t, determinant(g, args[0]));
    }
    if (eq(name, "mul")) {
        if (!need(g, name, args, 2)) return none(g);
        return mul(g, args[0], args[1]);
    }
    if (eq(name, "noise")) {
        g.fail("noise is not supported in Shader Model 4", .{});
        return none(g);
    }
    if (eq(name, "GetRenderTargetSampleCount")) {
        const v = g.vreg();
        var i = ir.Inst{ .op = .sample_info, .n = 2, .ctl = 2 };
        i.ops[0] = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, 1);
        i.ops[1] = .{ .reg = @enumFromInt(14), .comps = 4, .dims = 0 };
        g.emit(i);
        return scalarOf(g, g.scalarTy(.uint), Gen.tempSrc(v, 1));
    }
    g.fail("unknown function '{s}'", .{name});
    return none(g);
}

fn retype(v: Val, t: u32) Val {
    var r = v;
    r.ty = t;
    return r;
}

fn swz(s: Src, s3: [3]u2) Src {
    var x = s;
    x.n = 3;
    for (0..3) |k| {
        if (s.reg == .imm32) x.imm[k] = s.imm[s3[k]] else x.swz[k] = s.swz[s3[k]];
    }
    return x;
}

fn sincosCall(g: *Gen, argn: []const u32) Val {
    if (argn.len != 3) {
        g.fail("sincos takes 3 arguments", .{});
        return none(g);
    }
    const x = g.expr(argn[0]);
    const ls = g.lvalue(argn[1]);
    const lc = g.lvalue(argn[2]);
    if (g.failed) return none(g);
    const t = floatTy(g, x.ty);
    g.store(ls, perRow(g, t, x, rSin));
    g.store(lc, perRow(g, t, x, rCos));
    return .{ .ty = 0, .kind = .none };
}

fn modfCall(g: *Gen, argn: []const u32) Val {
    if (argn.len != 2) {
        g.fail("modf takes 2 arguments", .{});
        return none(g);
    }
    const x = g.expr(argn[0]);
    const li = g.lvalue(argn[1]);
    if (g.failed) return none(g);
    const t = floatTy(g, x.ty);
    const ip = perRow(g, t, x, rTrunc);
    g.store(li, ip);
    return g.binaryExpr(.minus, g.convert(x, t), ip);
}

// ── mul ──

fn mul(g: *Gen, a: Val, b: Val) Val {
    const x = g.ty(a.ty);
    const y = g.ty(b.ty);
    const fb: ast.Base = if (ast.canon(x.base) == .float or ast.canon(y.base) == .float) .float else ast.canon(x.base);
    const int = fb != .float;
    if (x.class == .scalar or y.class == .scalar) return g.binaryExpr(.star, a, b);
    if (x.class == .vector and y.class == .vector) {
        const n = @min(x.cols, y.cols);
        const t = g.a.vector(fb, n);
        const av = g.srcs[g.canonRows(g.convert(a, t)).at];
        const bv = g.srcs[g.canonRows(g.convert(b, t)).at];
        return scalarOf(g, g.a.scalar(fb), dotRow(g, n, av, bv, int));
    }
    if (x.class == .vector and y.class == .matrix) {
        // v (1 x N) * M (N x K): K results
        const nn = @min(x.cols, y.rows);
        const mt = g.a.matrix(fb, y.rows, y.cols, .default);
        const m = g.rows(g.convert(b, mt));
        const v = g.srcs[g.canonRows(g.convert(a, g.a.vector(fb, x.cols))).at];
        return scalarOf(g, g.a.vector(fb, y.cols), vecMat(g, v, nn, m, y.rows, y.cols, int));
    }
    if (x.class == .matrix and y.class == .vector) {
        const nn = @min(x.cols, y.cols);
        const mt = g.a.matrix(fb, x.rows, x.cols, .default);
        const m = g.rows(g.convert(a, mt));
        const v = g.srcs[g.canonRows(g.convert(b, g.a.vector(fb, y.cols))).at];
        return scalarOf(g, g.a.vector(fb, x.rows), matVec(g, m, x.rows, x.cols, v, nn, int));
    }
    if (x.class == .matrix and y.class == .matrix) {
        const nn = @min(x.cols, y.rows);
        const at = g.a.matrix(fb, x.rows, x.cols, .default);
        const bt = g.a.matrix(fb, y.rows, y.cols, .default);
        const ar = g.matRows(g.convert(a, at));
        const bm = g.rows(g.convert(b, bt));
        const rt = g.a.matrix(fb, x.rows, y.cols, .default);
        const first = g.newSrcs(x.rows);
        for (0..x.rows) |r| g.srcs[first + r] = vecMat(g, g.srcs[ar.at + r], nn, bm, y.rows, y.cols, int);
        return mkVal(rt, first, x.rows);
    }
    g.fail("mul of {s} and {s}", .{ g.tyName(a.ty), g.tyName(b.ty) });
    return none(g);
}

/// v * M (M: rows x cols, as stored: rows or columns): one row of cols.
fn vecMat(g: *Gen, v: Src, nn: u8, m: Val, rows: u8, cols: u8, int: bool) Src {
    _ = rows;
    if (m.n > 0 and g.srcs[m.at].col and !int) {
        // M's columns: a dot product each
        var sc: [4]Src = undefined;
        for (0..cols) |c| sc[c] = dotRow(g, nn, v, g.srcs[m.at + c], false);
        return g.pack(sc[0..cols]);
    }
    const mr = g.matRows(m);
    // rows: v.x * row0 + v.y * row1 + ...
    var acc = g.alu(if (int) .imul else .mul, cols, &.{ broadcast(component(v, 0), cols), g.srcs[mr.at] });
    for (1..nn) |k| {
        if (int) {
            acc = g.alu(.iadd, cols, &.{ acc, g.alu(.imul, cols, &.{ broadcast(component(g.plain(v), @intCast(k)), cols), g.plain(g.srcs[mr.at + k]) }) });
        } else acc = g.alu(.mad, cols, &.{ broadcast(component(v, @intCast(k)), cols), g.srcs[mr.at + k], acc });
    }
    return acc;
}

/// M * v: one value per row of M.
fn matVec(g: *Gen, m: Val, rows: u8, cols: u8, v: Src, nn: u8, int: bool) Src {
    _ = cols;
    if (m.n > 0 and !g.srcs[m.at].col) {
        var sc: [4]Src = undefined;
        for (0..rows) |r| sc[r] = dotRow(g, nn, g.srcs[m.at + r], v, int);
        return g.pack(sc[0..rows]);
    }
    const mc = g.matCols(m);
    var acc = g.alu(if (int) .imul else .mul, rows, &.{ broadcast(component(v, 0), rows), g.srcs[mc.at] });
    for (1..nn) |k| {
        if (int) {
            acc = g.alu(.iadd, rows, &.{ acc, g.alu(.imul, rows, &.{ broadcast(component(g.plain(v), @intCast(k)), rows), g.plain(g.srcs[mc.at + k]) }) });
        } else acc = g.alu(.mad, rows, &.{ broadcast(component(v, @intCast(k)), rows), g.srcs[mc.at + k], acc });
    }
    return acc;
}

fn determinant(g: *Gen, a: Val) Src {
    const x = g.ty(a.ty);
    if (x.class != .matrix or x.rows != x.cols) {
        if (x.class == .scalar) return g.srcs[g.rows(g.convert(a, g.scalarTy(.float))).at];
        g.fail("determinant of a non-square matrix", .{});
        return imm1(0);
    }
    const n = x.rows;
    const m = g.matRows(g.convert(a, g.a.matrix(.float, n, n, .default)));
    var e: [4][4]Src = undefined;
    for (0..n) |r| for (0..n) |c| {
        e[r][c] = component(g.srcs[m.at + r], @intCast(c));
    };
    return switch (n) {
        1 => e[0][0],
        2 => g.alu(.mad, 1, &.{ e[0][0], e[1][1], neg(g.alu(.mul, 1, &.{ e[0][1], e[1][0] })) }),
        3 => det3(g, e[0][0..3].*, e[1][0..3].*, e[2][0..3].*),
        else => blk: {
            // expansion along the first row
            var acc: ?Src = null;
            for (0..4) |c| {
                var rows3: [3][3]Src = undefined;
                for (1..4) |r| {
                    var k: usize = 0;
                    for (0..4) |cc| {
                        if (cc == c) continue;
                        rows3[r - 1][k] = e[r][cc];
                        k += 1;
                    }
                }
                const minor = det3(g, rows3[0], rows3[1], rows3[2]);
                const term = g.alu(.mul, 1, &.{ e[0][c], minor });
                acc = if (acc) |s| g.alu(.add, 1, &.{ s, if (c % 2 == 1) neg(term) else term }) else term;
            }
            break :blk acc.?;
        },
    };
}

fn det3(g: *Gen, r0: [3]Src, r1: [3]Src, r2: [3]Src) Src {
    const a = g.alu(.mad, 1, &.{ r1[1], r2[2], neg(g.alu(.mul, 1, &.{ r1[2], r2[1] })) });
    const b = g.alu(.mad, 1, &.{ r1[0], r2[2], neg(g.alu(.mul, 1, &.{ r1[2], r2[0] })) });
    const c = g.alu(.mad, 1, &.{ r1[0], r2[1], neg(g.alu(.mul, 1, &.{ r1[1], r2[0] })) });
    const t = g.alu(.mad, 1, &.{ r0[0], a, neg(g.alu(.mul, 1, &.{ r0[1], b })) });
    return g.alu(.mad, 1, &.{ r0[2], c, t });
}

// ── methods ────────────────────────────────────────────────────────────────

/// The register dimension DXBC declares a texture with
/// (D3D10_SB_RESOURCE_DIMENSION).
pub fn resDim(d: ast.TexDim) u32 {
    return switch (d) {
        .buffer => 1,
        .tex1d => 2,
        .tex2d, .unknown => 3,
        .tex2dms => 4,
        .tex3d => 5,
        .cube => 6,
        .tex1darray => 7,
        .tex2darray => 8,
        .tex2dmsarray => 9,
        .cubearray => 10,
    };
}

/// Coordinates a texture is sampled with (array index included) and its
/// offsets' count.
fn coordCount(d: ast.TexDim) struct { c: u8, off: u8 } {
    return switch (d) {
        .buffer, .tex1d => .{ .c = 1, .off = 1 },
        .tex1darray => .{ .c = 2, .off = 1 },
        .tex2d, .tex2dms, .unknown => .{ .c = 2, .off = 2 },
        .tex2darray, .tex2dmsarray => .{ .c = 3, .off = 2 },
        .tex3d => .{ .c = 3, .off = 3 },
        .cube => .{ .c = 3, .off = 0 },
        .cubearray => .{ .c = 4, .off = 0 },
    };
}

pub fn method(g: *Gen, n: u32) Val {
    const node = g.a.nodes[n];
    const name = g.tokText(node.tok);
    const obj = g.expr(node.a);
    if (g.failed) return none(g);
    var argn: [MAX_ARGS]u32 = undefined;
    var argc: usize = 0;
    var e = node.b;
    while (e != NONE) : (e = g.a.nodes[e].next) {
        if (argc >= MAX_ARGS) break;
        argn[argc] = e;
        argc += 1;
    }
    const t = g.ty(obj.ty);
    if (t.class == .stream) return streamMethod(g, name, argn[0..argc]);
    if (t.class != .texture) {
        g.fail("'{s}': no such method", .{name});
        return none(g);
    }
    if (eq(name, "GetDimensions")) return getDimensions(g, obj, argn[0..argc]);
    var args: [MAX_ARGS]Val = undefined;
    for (argn[0..argc], 0..) |a, k| {
        args[k] = g.expr(a);
        if (g.failed) return none(g);
    }
    return textureOp(g, obj, name, args[0..argc]);
}

fn texReg(g: *Gen, obj: Val) u32 {
    return g.resource(obj.sym, obj.elem, 't');
}

fn samplerReg(g: *Gen, s: Val) ?u32 {
    if (s.kind != .object or g.ty(s.ty).class != .sampler) {
        g.fail("a sampler expected", .{});
        return null;
    }
    return g.resource(s.sym, s.elem, 's');
}

fn floatArg(g: *Gen, v: Val, n: u8) Src {
    const t = g.a.vector(.float, n);
    const r = g.canonRows(g.convert(v, t));
    var s = g.srcs[r.at];
    if (s.n > n) s.n = n;
    return s;
}

fn intArg(g: *Gen, v: Val, n: u8) Src {
    const t = g.a.vector(.int, n);
    const r = g.canonRows(g.convert(v, t));
    var s = g.plain(g.srcs[r.at]);
    if (s.n > n) s.n = n;
    return s;
}

fn offsetOf(g: *Gen, v: Val, n: u8, i: *ir.Inst) void {
    const s = intArg(g, v, n);
    if (s.reg != .imm32) {
        g.fail("texture offsets must be literal", .{});
        return;
    }
    i.has_offset = true;
    for (0..n) |k| i.offset[k] = @truncate(@as(i32, @bitCast(if (s.n == 1) s.imm[0] else s.imm[k])));
}

fn resOpnd(reg: u32) ir.Opnd {
    return .{ .reg = .resource, .comps = 4, .mode = .swizzle, .idx = .{ reg, 0 } };
}

fn samplerOpnd(reg: u32) ir.Opnd {
    return .{ .reg = .sampler, .comps = 0, .dims = 1, .idx = .{ reg, 0 } };
}

fn scalarOpnd(g: *Gen, s: Src) ir.Opnd {
    return g.condOpnd(s);
}

/// The texture's element type and how many components it returns.
fn texElem(g: *Gen, obj: Val) struct { ty: u32, n: u8, base: ast.Base } {
    const t = g.ty(obj.ty);
    const et = if (t.elem == 0) g.a.vector(.float, 4) else t.elem;
    const x = g.ty(et);
    return .{ .ty = et, .n = if (x.class == .vector) x.cols else 1, .base = ast.canon(x.base) };
}

fn textureOp(g: *Gen, obj: Val, name: []const u8, args: []const Val) Val {
    const t = g.ty(obj.ty);
    const dim: ast.TexDim = @enumFromInt(t.dim);
    const cc = coordCount(dim);
    const el = texElem(g, obj);
    const treg = texReg(g, obj);
    var i = ir.Inst{ .op = .sample, .n = 0 };
    const v = g.vreg();
    var outn: u8 = el.n;
    if (eq(name, "Sample") or eq(name, "SampleBias") or eq(name, "SampleLevel") or eq(name, "SampleGrad") or eq(name, "SampleCmp") or eq(name, "SampleCmpLevelZero") or eq(name, "Gather")) {
        if (args.len < 2) {
            g.fail("'{s}': too few arguments", .{name});
            return none(g);
        }
        const sreg = samplerReg(g, args[0]) orelse return none(g);
        const coord = floatArg(g, args[1], cc.c);
        var next: usize = 2;
        const cmp = eq(name, "SampleCmp") or eq(name, "SampleCmpLevelZero");
        if (eq(name, "Sample")) {
            if (g.target.stage != .pixel) {
                g.fail("Sample needs derivatives: use SampleLevel outside pixel shaders", .{});
                return none(g);
            }
            i.op = .sample;
        } else if (eq(name, "SampleBias")) i.op = .sample_b else if (eq(name, "SampleLevel")) i.op = .sample_l else if (eq(name, "SampleGrad")) i.op = .sample_d else if (eq(name, "SampleCmp")) i.op = .sample_c else if (eq(name, "SampleCmpLevelZero")) i.op = .sample_c_lz else i.op = .gather4;
        if (cmp) outn = 1;
        if (i.op == .gather4) outn = 4;
        i.ops[0] = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, outn);
        i.ops[1] = g.opnd(coord, .{ 0, 1, 2, 3 }, cc.c);
        var ro = resOpnd(treg);
        if (cmp) ro.swz = .{ 0, 0, 0, 0 };
        i.ops[2] = ro;
        i.ops[3] = samplerOpnd(sreg);
        if (i.op == .gather4) {
            i.ops[3] = .{ .reg = .sampler, .comps = 4, .mode = .select1, .swz = .{ 0, 0, 0, 0 }, .dims = 1, .idx = .{ sreg, 0 } };
        }
        i.n = 4;
        switch (i.op) {
            .sample_b, .sample_l, .sample_c, .sample_c_lz => if (i.op != .sample_c_lz or cmp) {
                if (i.op == .sample_c_lz) {
                    // the reference
                    if (args.len <= next) {
                        g.fail("'{s}': too few arguments", .{name});
                        return none(g);
                    }
                }
                if (args.len <= next) {
                    g.fail("'{s}': too few arguments", .{name});
                    return none(g);
                }
                const s = floatArg(g, args[next], 1);
                i.ops[4] = scalarOpnd(g, s);
                i.n = 5;
                next += 1;
            },
            .sample_d => {
                if (args.len < 4) {
                    g.fail("SampleGrad: too few arguments", .{});
                    return none(g);
                }
                const gn: u8 = if (dim == .tex1darray) 1 else if (dim == .tex2darray) 2 else if (dim == .cube or dim == .cubearray) 3 else cc.c;
                i.ops[4] = g.opnd(floatArg(g, args[2], gn), .{ 0, 1, 2, 3 }, gn);
                i.ops[5] = g.opnd(floatArg(g, args[3], gn), .{ 0, 1, 2, 3 }, gn);
                i.n = 6;
                next = 4;
            },
            else => {},
        }
        if (args.len > next) offsetOf(g, args[next], cc.off, &i);
        g.emit(i);
        return scalarOf(g, if (cmp) g.scalarTy(.float) else if (i.op == .gather4) g.a.vector(el.base, 4) else el.ty, Gen.tempSrc(v, outn));
    }
    if (eq(name, "Load")) {
        if (args.len < 1) {
            g.fail("Load: too few arguments", .{});
            return none(g);
        }
        const ms = dim == .tex2dms or dim == .tex2dmsarray;
        const buf = dim == .buffer;
        const want: u8 = if (ms or buf) cc.c else cc.c + 1;
        const a = intArg(g, args[0], want);
        // (x, y, slice) and the level at w
        var sc: [4]Src = undefined;
        for (0..4) |k| sc[k] = component(a, 0);
        for (0..cc.c) |k| sc[k] = component(a, @intCast(k));
        if (!ms and !buf) sc[3] = component(a, cc.c);
        const addr = g.pack(&sc);
        i.op = if (ms) .ld_ms else .ld;
        i.ops[0] = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, outn);
        i.ops[1] = g.opnd(addr, .{ 0, 1, 2, 3 }, 4);
        i.ops[2] = resOpnd(treg);
        i.n = 3;
        var next: usize = 1;
        if (ms) {
            if (args.len < 2) {
                g.fail("Load of a multisampled texture needs the sample", .{});
                return none(g);
            }
            i.ops[3] = scalarOpnd(g, intArg(g, args[1], 1));
            i.n = 4;
            next = 2;
        }
        if (args.len > next) offsetOf(g, args[next], cc.off, &i);
        g.emit(i);
        return scalarOf(g, el.ty, Gen.tempSrc(v, outn));
    }
    g.fail("'{s}': no such texture method", .{name});
    return none(g);
}

/// GetDimensions([mip,] out width[, out height][, out depth/elements], out levels).
fn getDimensions(g: *Gen, obj: Val, argn: []const u32) Val {
    const t = g.ty(obj.ty);
    const dim: ast.TexDim = @enumFromInt(t.dim);
    const treg = texReg(g, obj);
    // which outputs this dimension has (resinfo: x w, y h, z d/elements, w levels)
    const comps: []const u2 = switch (dim) {
        .buffer => &.{0},
        .tex1d => &.{ 0, 3 },
        .tex1darray => &.{ 0, 1, 3 },
        .tex2d, .cube, .unknown => &.{ 0, 1, 3 },
        .tex2darray, .tex3d, .cubearray => &.{ 0, 1, 2, 3 },
        .tex2dms => &.{ 0, 1, 3 },
        .tex2dmsarray => &.{ 0, 1, 2, 3 },
    };
    var lv: [5]gen.LVal = undefined;
    var mip: Src = imm1(0);
    var first: usize = 0;
    const no_levels = dim == .tex2dms or dim == .tex2dmsarray or dim == .buffer;
    // with a mip argument: one more than the outputs
    const nout_with_levels = comps.len;
    const nout = if (no_levels) comps.len - (if (dim == .buffer) @as(usize, 0) else 1) else comps.len;
    if (argn.len == nout_with_levels + 1 or (no_levels and argn.len == nout + 1)) {
        mip = intArg(g, g.expr(argn[0]), 1);
        first = 1;
    } else if (!(argn.len == nout or argn.len + (if (no_levels) @as(usize, 0) else 1) == nout)) {
        g.fail("GetDimensions: wrong number of arguments", .{});
        return none(g);
    }
    const outs = argn[first..];
    for (outs, 0..) |a, k| lv[k] = g.lvalue(a);
    if (g.failed) return none(g);
    // float outputs read resinfo's float, uint ones its uint
    const fl = outs.len > 0 and g.baseOf(lv[0].ty) == .float;
    const v = g.vreg();
    var i = ir.Inst{ .op = .resinfo, .n = 3, .ctl = if (fl) 0 else 2 };
    i.ops[0] = Gen.dstOpnd(v, .{ 0, 1, 2, 3 }, 4);
    i.ops[1] = scalarOpnd(g, g.inTemp(mip));
    i.ops[2] = resOpnd(treg);
    if (dim == .buffer) {
        i.op = .resinfo;
    }
    g.emit(i);
    for (outs, 0..) |_, k| {
        const c = comps[k];
        const s = component(Gen.tempSrc(v, 4), c);
        const sv = scalarOf(g, g.scalarTy(if (fl) .float else .uint), s);
        g.store(lv[k], sv);
    }
    return .{ .ty = 0, .kind = .none };
}

fn streamMethod(g: *Gen, name: []const u8, argn: []const u32) Val {
    if (eq(name, "RestartStrip")) {
        g.emit(.{ .op = .cut, .ndst = 0 });
        return .{ .ty = 0, .kind = .none };
    }
    if (eq(name, "Append")) {
        if (argn.len != 1) {
            g.fail("Append takes one vertex", .{});
            return none(g);
        }
        const v = g.expr(argn[0]);
        if (g.failed) return none(g);
        // the outputs are this vertex's elements (declared once: the same each time)
        g.nouts = 0;
        var reg: u32 = 0;
        const vt = v.ty;
        g.outputLeaves(vt, 0, 0, 0, 0, v, &reg);
        g.emit(.{ .op = .emit, .ndst = 0 });
        return .{ .ty = 0, .kind = .none };
    }
    g.fail("'{s}': no such stream method", .{name});
    return none(g);
}
