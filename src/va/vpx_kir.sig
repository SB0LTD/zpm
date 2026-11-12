//! @zpm/va vpx_kir — vpx_dsl's other backend: a kernel's calls emitted as
//! KIR (zpm src/gpu), for the RTX (kir_sm120) or KIR's interpreter.
//!
//! Every value is a KIR operand: an immediate where the generic code's
//! arithmetic on constants folds here (so `b.add(b.c(1), b.c(2))` costs
//! nothing), else a 32-bit register (`i32`); predicates are `pred`
//! registers or 0/1 immediates. `when` is if/endif (or nothing, or the body
//! alone, on a constant), `loop` a KIR loop with its counter, a variable a
//! register written with `set` and read through a copy (so a value read
//! before a write keeps what it read).
//!
//! Needs the `gpu` module (the shared library's build and the gpu tests);
//! va.sig's tests do not import it. Allocation-free: the kernel's storage
//! is the caller's.

const std = @import("std");
const gpu = @import("gpu");
const dsl = @import("vpx_dsl.sig");

const kir = gpu.kir;
const Arg = kir.Arg;
const r = kir.r;
const no = kir.no;

pub const Kir = struct {
    pub const V = Arg;
    pub const P = Arg;
    pub const Var = kir.V;
    pub const is_cpu = false;

    k: *kir.Kernel,
    bind: [dsl.MAX_BUFS]u8,
    idx: Arg,

    /// A backend over `k` (just made: no bindings yet): bindings 0..n-1 in
    /// order, the invocation's index computed once.
    pub fn init(k: *kir.Kernel, bindings: u8) Kir {
        var b = Kir{ .k = k, .bind = @splat(0xff), .idx = undefined };
        for (0..bindings) |i| b.bind[i] = k.binding();
        b.idx = r(k.op3(.imad, .u32, r(k.gid(0)), kir.u(dsl.GROUP), r(k.tid(0))));
        return b;
    }

    fn imm(a: Arg) ?i32 {
        return switch (a) {
            .imm => |x| @bitCast(x),
            .reg => null,
        };
    }

    pub fn c(_: *Kir, x: i32) Arg {
        return kir.i(x);
    }
    pub fn param(b: *Kir, comptime i: u16) Arg {
        return r(b.k.param(.i32, i));
    }
    pub fn index(b: *Kir) Arg {
        return b.idx;
    }

    fn op2(b: *Kir, op: kir.Op, ty: kir.Ty, x: Arg, y: Arg) Arg {
        return r(b.k.op2(op, ty, x, y));
    }

    pub fn add(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a +% d);
        if (imm(y)) |d| if (d == 0) return x;
        if (imm(x)) |a| if (a == 0) return y;
        return b.op2(.iadd, .i32, x, y);
    }
    pub fn sub(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a -% d);
        if (imm(y)) |d| if (d == 0) return x;
        return b.op2(.isub, .i32, x, y);
    }
    pub fn mul(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a *% d);
        if (imm(y)) |d| if (d == 1) return x;
        if (imm(x)) |a| if (a == 1) return y;
        return b.op2(.imul, .i32, x, y);
    }
    pub fn mad(b: *Kir, x: Arg, y: Arg, z: Arg) Arg {
        if (imm(x) != null and imm(y) != null) return b.add(b.mul(x, y), z);
        return r(b.k.op3(.imad, .i32, x, y, z));
    }
    pub fn shl(b: *Kir, x: Arg, n: Arg) Arg {
        if (imm(x)) |a| if (imm(n)) |s| return kir.i(@bitCast(@as(u32, @bitCast(a)) << @intCast(s & 31)));
        if (imm(n)) |s| if (s == 0) return x;
        return b.op2(.shl, .u32, x, n);
    }
    pub fn sar(b: *Kir, x: Arg, n: Arg) Arg {
        if (imm(x)) |a| if (imm(n)) |s| return kir.i(a >> @intCast(s & 31));
        if (imm(n)) |s| if (s == 0) return x;
        return b.op2(.shr, .i32, x, n);
    }
    pub fn shr(b: *Kir, x: Arg, n: Arg) Arg {
        if (imm(x)) |a| if (imm(n)) |s| return kir.i(@bitCast(@as(u32, @bitCast(a)) >> @intCast(s & 31)));
        if (imm(n)) |s| if (s == 0) return x;
        return b.op2(.shr, .u32, x, n);
    }
    pub fn band(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a & d);
        return b.op2(.@"and", .u32, x, y);
    }
    pub fn bor(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a | d);
        if (imm(y)) |d| if (d == 0) return x;
        if (imm(x)) |a| if (a == 0) return y;
        return b.op2(.@"or", .u32, x, y);
    }
    pub fn bxor(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(a ^ d);
        return b.op2(.xor, .u32, x, y);
    }
    pub fn min(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(@min(a, d));
        return b.op2(.imin, .i32, x, y);
    }
    pub fn max(b: *Kir, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| return kir.i(@max(a, d));
        return b.op2(.imax, .i32, x, y);
    }
    pub fn abs(b: *Kir, x: Arg) Arg {
        if (imm(x)) |a| return kir.i(if (a < 0) 0 -% a else a);
        return r(b.k.op1(.iabs, .i32, x));
    }
    pub fn neg(b: *Kir, x: Arg) Arg {
        if (imm(x)) |a| return kir.i(0 -% a);
        return r(b.k.op1(.ineg, .i32, x));
    }
    pub fn sel(b: *Kir, p: Arg, x: Arg, y: Arg) Arg {
        if (imm(p)) |q| return if (q != 0) x else y;
        return r(b.k.sel(.i32, p, x, y));
    }

    fn cmp(b: *Kir, how: kir.Cmp, x: Arg, y: Arg) Arg {
        if (imm(x)) |a| if (imm(y)) |d| {
            const t = switch (how) {
                .lt => a < d,
                .le => a <= d,
                .gt => a > d,
                .ge => a >= d,
                .eq => a == d,
                .ne => a != d,
            };
            return kir.u(@intFromBool(t));
        };
        return r(b.k.cmp(.i32, how, x, y));
    }
    pub fn lt(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.lt, x, y);
    }
    pub fn le(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.le, x, y);
    }
    pub fn gt(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.gt, x, y);
    }
    pub fn ge(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.ge, x, y);
    }
    pub fn eq(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.eq, x, y);
    }
    pub fn ne(b: *Kir, x: Arg, y: Arg) Arg {
        return b.cmp(.ne, x, y);
    }
    pub fn pand(b: *Kir, p: Arg, q: Arg) Arg {
        if (imm(p)) |a| return if (a != 0) q else kir.u(0);
        if (imm(q)) |a| return if (a != 0) p else kir.u(0);
        return b.op2(.pand, .pred, p, q);
    }
    pub fn por(b: *Kir, p: Arg, q: Arg) Arg {
        if (imm(p)) |a| return if (a != 0) kir.u(1) else q;
        if (imm(q)) |a| return if (a != 0) kir.u(1) else p;
        return b.op2(.por, .pred, p, q);
    }
    pub fn pnot(b: *Kir, p: Arg) Arg {
        if (imm(p)) |a| return kir.u(@intFromBool(a == 0));
        return r(b.k.op1(.pnot, .pred, p));
    }
    pub fn pc(_: *Kir, p: bool) Arg {
        return kir.u(@intFromBool(p));
    }

    fn mem(b: *const Kir, comptime t: dsl.Ty, comptime buf: u8) kir.Mem {
        var m = kir.global(b.bind[buf], 8 * @as(u8, @intCast(dsl.bytesOf(t))));
        m.signed = (t == .i8 or t == .i16);
        return m;
    }
    pub fn ld(b: *Kir, comptime t: dsl.Ty, comptime buf: u8, off: Arg) Arg {
        return r(b.k.load(.i32, b.mem(t, buf), off));
    }
    pub fn st(b: *Kir, comptime t: dsl.Ty, comptime buf: u8, off: Arg, x: Arg) void {
        var m = b.mem(t, buf);
        m.signed = false;
        b.k.store(.i32, m, off, x);
    }

    pub fn vr(b: *Kir, x: Arg) kir.V {
        const v = b.k.reg(.i32);
        b.k.set(v, .mov, x, no, no);
        return v;
    }
    pub fn get(b: *Kir, v: kir.V) Arg {
        return r(b.k.mov(.i32, r(v)));
    }
    pub fn put(b: *Kir, v: kir.V, x: Arg) void {
        b.k.set(v, .mov, x, no, no);
    }

    pub fn when(b: *Kir, p: Arg, ctx: anytype) void {
        if (imm(p)) |q| {
            if (q != 0) ctx.then(b);
            return;
        }
        b.k.ifp(p);
        ctx.then(b);
        b.k.endif();
    }
    pub fn whenElse(b: *Kir, p: Arg, ctx: anytype) void {
        if (imm(p)) |q| {
            if (q != 0) ctx.then(b) else ctx.otherwise(b);
            return;
        }
        b.k.ifp(p);
        ctx.then(b);
        b.k.els();
        ctx.otherwise(b);
        b.k.endif();
    }
    pub fn loop(b: *Kir, n: Arg, ctx: anytype) void {
        const i = b.k.reg(.i32);
        b.k.set(i, .mov, kir.u(0), no, no);
        b.k.loop();
        b.k.brk(r(b.k.cmp(.i32, .ge, r(i), n)));
        ctx.body(b, r(i));
        b.k.set(i, .iadd, r(i), kir.u(1), no);
        b.k.endloop();
    }
};

/// Builds `kernel` (a vpx_dsl kernel) as KIR into `k` (fresh: its storage
/// the caller's), with `bindings` buffers and `params` parameter words.
pub fn build(comptime kernel: anytype, k: *kir.Kernel, bindings: u8, params: u16) kir.Error!void {
    var b = Kir.init(k, bindings);
    // (every parameter word declared, used or not)
    if (params > 0) _ = k.param(.i32, params - 1);
    kernel(&b);
    try k.finish();
}
