//! @zpm/gpu kir_interp — the definition of KIR: runs a kernel on the CPU,
//! exactly, under a device's Caps.
//!
//! Each group runs in lockstep: one instruction for all its threads, then
//! the next, with masks for divergence. Subgroups are Caps.subgroup
//! consecutive threads (x fastest). The floating-point ops are computed in
//! software where the host's own could differ (the fused multiply-add,
//! NaN bits), so the result is the same bits on any CPU:
//! - fadd, fsub, fmul, fdiv, fsqrt: correctly rounded binary32;
//! - ffma, and fmad when Caps.mad == .fused: one rounding; fmad unfused:
//!   the product rounded (and flushed), then the sum;
//! - Caps.denormals == .flush: every float op's inputs and its result
//!   flush to signed zero (fabs and fneg are sign-bit operations: they do
//!   not flush, and keep a NaN's bits);
//! - a NaN result is 0x7fffffff (backends may give any NaN; compare NaNs
//!   as NaNs);
//! - fmin/fmax: a NaN operand gives the other operand; -0 < +0;
//! - the approximate ops (frcp, frsq, fexp2, flog2, fsin, fcos) give the
//!   correctly rounded value of 1/x, and f64's for the others, rounded
//!   (Launch.jitter_ulps perturbs them, within their bounds, to prove
//!   exact code does not depend on them).
//!
//! What a GPU would trip over is a trap here: an access out of its
//! binding or of shared memory, misaligned, a shared-memory race between
//! barriers, a barrier under divergence, a shuffle from an inactive lane.
//! Registers start as 0xffffffff in every group (a NaN, -1).

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const Caps = device.Caps;
const Inst = kir.Inst;
const Op = kir.Op;
const Ty = kir.Ty;

/// The most threads a group can have here.
pub const MAX_THREADS = 1024;
const MASK_WORDS = MAX_THREADS / 64;
const MAX_DEPTH = 64;
/// The value registers hold before a kernel writes them.
pub const POISON: u32 = 0xffff_ffff;
/// The NaN every float op gives.
pub const NAN: u32 = 0x7fff_ffff;
/// The f16 NaN cvt gives.
pub const NAN16: u32 = 0x7fff;

/// What stopped a kernel.
pub const Trap = struct {
    what: What = .none,
    /// the instruction's index
    pc: u32 = 0,
    group: [3]u32 = .{ 0, 0, 0 },
    /// the thread's linear index in its group
    thread: u32 = 0,
    /// the binding (global) or 0xff (shared) and the byte offset
    binding: u8 = 0,
    offset: u64 = 0,

    pub const What = enum {
        none,
        /// an access outside its binding or the group's shared memory
        out_of_bounds,
        /// an access not aligned to its width
        misaligned,
        /// a binding with no buffer
        bad_binding,
        /// two threads of a group on one shared word between barriers
        /// (one of them writing), without atomics
        shared_race,
        /// a barrier some of the group's threads did not reach
        divergent_barrier,
        /// a shuffle from a lane that is not active
        inactive_lane,
        /// the program is malformed (unbalanced flow, bad operands)
        bad_program,
    };
};

pub const Error = error{
    /// The kernel trapped; `Trap` says where.
    Trap,
    /// The program or launch is malformed.
    BadProgram,
    /// The Work is too small for this launch.
    NoWork,
};

/// Counts for one run.
pub const Stats = struct {
    groups: u64 = 0,
    /// instructions issued (per group)
    issued: u64 = 0,
    /// thread-instructions executed (active lanes)
    lane_ops: u64 = 0,
};

/// A dispatch for the interpreter.
pub const Launch = struct {
    code: []const Inst,
    regs: u32,
    group: [3]u32,
    shared_bytes: u32,
    groups: [3]u32,
    /// each binding's bytes as the GPU sees them
    bindings: []const []u8,
    /// the words after the bindings
    params: []const u32,
    /// perturb the approximate ops by up to this many ulps (0: none)
    jitter_ulps: u32 = 0,
};

/// The Work a launch needs (bytes), at most.
pub fn workBytes(regs: u32, threads: u32, shared_bytes: u32, insts: usize) usize {
    const t: usize = threads;
    return @as(usize, regs) * t * 4 + 4 * t * 4 + t * 2 + insts * 4 + MAX_DEPTH * @sizeOf(Frame) +
        shared_bytes + (shared_bytes / 4 + 1) * @sizeOf(Owner) + 256;
}

// ── Masks ───────────────────────────────────────────────────────────────────

const Mask = [MASK_WORDS]u64;
const empty: Mask = [_]u64{0} ** MASK_WORDS;

fn none(m: *const Mask) bool {
    for (m) |w| if (w != 0) return false;
    return true;
}
fn has(m: *const Mask, t: usize) bool {
    return (m[t >> 6] >> @intCast(t & 63)) & 1 != 0;
}
fn put(m: *Mask, t: usize) void {
    m[t >> 6] |= @as(u64, 1) << @intCast(t & 63);
}
fn andNot(m: *Mask, x: *const Mask) void {
    for (m, x) |*a, b| a.* &= ~b;
}
fn orIn(m: *Mask, x: *const Mask) void {
    for (m, x) |*a, b| a.* |= b;
}
fn eql(a: *const Mask, b: *const Mask) bool {
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

const Frame = struct {
    kind: enum(u8) { if_then, if_else, loop },
    /// the opener's index (if, else or loop)
    opener: u32,
    /// the lanes at entry
    saved: Mask,
    /// if: the lanes for the else branch; loop: the lanes that broke
    other: Mask,
    /// loop: the lanes that continued
    cont: Mask,
};

/// A shared word's last writer and readers, for the race check.
const Owner = struct {
    w_epoch: u32 = 0,
    r_epoch: u32 = 0,
    w_tid: u16 = 0,
    /// 0xffff: more than one thread
    r_tid: u16 = 0,
};

// ── Floating point, exactly ─────────────────────────────────────────────────

fn isNan32(x: u32) bool {
    return x & 0x7fff_ffff > 0x7f80_0000;
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}
fn flt(x: u32) f32 {
    return @bitCast(x);
}

/// a*b+c with one rounding, in software (the host's fmaf may round twice):
/// the product is exact in f64, the sum rounds to odd there, and the
/// rounding to f32 is then correct (53 >= 24 + 2).
pub fn fma32(a: f32, b: f32, c: f32) f32 {
    const p = @as(f64, a) * @as(f64, b);
    const cd: f64 = c;
    if (!std.math.isFinite(p) or !std.math.isFinite(cd)) return @floatCast(p + cd);
    const s = p + cd;
    if (p == 0 or cd == 0) return @floatCast(s);
    // the sum's error (two-sum), then round to odd
    const bb = s - p;
    const err = (p - (s - bb)) + (cd - bb);
    var sb: u64 = @bitCast(s);
    if (err != 0 and sb & 1 == 0) {
        if ((err > 0) == (s > 0)) sb += 1 else sb -= 1;
    }
    return @floatCast(@as(f64, @bitCast(sb)));
}

/// Rounds to an integer, ties to even (frne).
pub fn rint(x: f32) f32 {
    if (!(@abs(x) < 8388608.0)) return x;
    const t = @trunc(x);
    const d = x - t;
    const one: f32 = if (x < 0) -1.0 else 1.0;
    if (@abs(d) > 0.5) return t + one;
    if (@abs(d) == 0.5) {
        const half = t * 0.5;
        if (half != @trunc(half)) return t + one;
    }
    return t;
}

const Fp = struct {
    flush: bool,
    fused_mad: bool,
    jitter: u32,

    fn in(fp: Fp, x: u32) u32 {
        if (fp.flush and x & 0x7f80_0000 == 0) return x & 0x8000_0000;
        return x;
    }
    fn out(fp: Fp, x: f32) u32 {
        const b = bits(x);
        if (isNan32(b)) return NAN;
        if (fp.flush and b & 0x7f80_0000 == 0) return b & 0x8000_0000;
        return b;
    }
    fn get(fp: Fp, x: u32) f32 {
        return flt(fp.in(x));
    }
    fn add(fp: Fp, a: u32, b: u32) u32 {
        return fp.out(fp.get(a) + fp.get(b));
    }
    fn sub(fp: Fp, a: u32, b: u32) u32 {
        return fp.out(fp.get(a) - fp.get(b));
    }
    fn mul(fp: Fp, a: u32, b: u32) u32 {
        return fp.out(fp.get(a) * fp.get(b));
    }
    fn fma(fp: Fp, a: u32, b: u32, c: u32) u32 {
        return fp.out(fma32(fp.get(a), fp.get(b), fp.get(c)));
    }
    fn mad(fp: Fp, a: u32, b: u32, c: u32) u32 {
        if (fp.fused_mad) return fp.fma(a, b, c);
        const p = fp.mul(a, b);
        return fp.add(p, c);
    }
    fn div(fp: Fp, a: u32, b: u32) u32 {
        return fp.out(fp.get(a) / fp.get(b));
    }
    fn sqrt(fp: Fp, a: u32) u32 {
        return fp.out(@sqrt(fp.get(a)));
    }
    fn minmax(fp: Fp, a0: u32, b0: u32, want_max: bool) u32 {
        const a = fp.in(a0);
        const b = fp.in(b0);
        if (isNan32(a)) return if (isNan32(b)) NAN else b;
        if (isNan32(b)) return a;
        const x = flt(a);
        const y = flt(b);
        if (x == y) {
            // equal: zeros of either sign (-0 < +0), or the same value
            const neg_a = a & 0x8000_0000 != 0;
            return if (want_max) (if (neg_a) b else a) else (if (neg_a) a else b);
        }
        return if ((x > y) == want_max) a else b;
    }
    fn round(fp: Fp, a: u32, op: Op) u32 {
        const x = fp.get(a);
        return fp.out(switch (op) {
            .ffloor => @floor(x),
            .fceil => @ceil(x),
            .ftrunc => @trunc(x),
            else => rint(x),
        });
    }
    fn approx(fp: Fp, a: u32, op: Op) u32 {
        const x = fp.get(a);
        const xd: f64 = x;
        const v: f32 = switch (op) {
            .frcp => 1.0 / x,
            .frsq => if (x == 0) 1.0 / x else @floatCast(1.0 / @sqrt(xd)),
            .fexp2 => @floatCast(std.math.exp2(xd)),
            .flog2 => if (x == 0) -std.math.inf(f32) else @floatCast(std.math.log2(xd)),
            .fsin => @floatCast(@sin(xd)),
            .fcos => @floatCast(@cos(xd)),
            else => unreachable,
        };
        var res = fp.out(v);
        if (fp.jitter != 0 and !isNan32(res) and res & 0x7f80_0000 != 0x7f80_0000 and res & 0x7f80_0000 != 0) {
            // a fixed perturbation per input, as hardware's is
            var h: u32 = a *% 0x9e37_79b9 ^ @as(u32, @intFromEnum(op)) *% 0x85eb_ca6b;
            h ^= h >> 15;
            h *%= 0x2c1b_3c6d;
            h ^= h >> 13;
            const span = 2 * fp.jitter + 1;
            const d: i64 = @as(i64, h % span) - @as(i64, fp.jitter);
            const mag: i64 = @as(i64, res & 0x7fff_ffff) + d;
            // (stay in the same finite, normal range)
            if (mag >= 0x0080_0000 and mag < 0x7f80_0000) res = (res & 0x8000_0000) | @as(u32, @intCast(mag));
        }
        return res;
    }
    /// Ordered compare (NaN: false; ne: true).
    fn cmp(fp: Fp, a0: u32, b0: u32, c: kir.Cmp) bool {
        const a = fp.in(a0);
        const b = fp.in(b0);
        if (isNan32(a) or isNan32(b)) return c == .ne;
        const x = flt(a);
        const y = flt(b);
        return switch (c) {
            .eq => x == y,
            .ne => x != y,
            .lt => x < y,
            .le => x <= y,
            .gt => x > y,
            .ge => x >= y,
        };
    }
};

// ── Conversions ─────────────────────────────────────────────────────────────

fn roundBy(x: f32, mode: kir.Round) f32 {
    return switch (mode) {
        .rne => rint(x),
        .rz => @trunc(x),
        .rd => @floor(x),
        .ru => @ceil(x),
    };
}

/// f32 to an integer: rounded as `mode`, saturated, NaN to 0.
pub fn f32ToInt(x: f32, signed: bool, mode: kir.Round) u32 {
    if (std.math.isNan(x)) return 0;
    const v = roundBy(x, mode);
    if (signed) {
        if (v >= 2147483648.0) return 0x7fff_ffff;
        if (v <= -2147483648.0) return 0x8000_0000;
        return @bitCast(@as(i32, @intFromFloat(v)));
    }
    if (v <= 0) return 0;
    if (v >= 4294967296.0) return 0xffff_ffff;
    return @intFromFloat(v);
}

fn nextUp(x: f32) f32 {
    const b = bits(x);
    if (x == 0) return flt(1);
    return flt(if (b & 0x8000_0000 == 0) b + 1 else b - 1);
}
fn nextDown(x: f32) f32 {
    return -nextUp(-x);
}

/// An integer to f32, rounded as `mode`.
pub fn intToF32(n: u32, signed: bool, mode: kir.Round) f32 {
    const exact: f64 = if (signed) @floatFromInt(@as(i32, @bitCast(n))) else @floatFromInt(n);
    var v: f32 = @floatCast(exact); // (round to nearest even)
    const vd: f64 = v;
    switch (mode) {
        .rne => {},
        .rz => if (@abs(vd) > @abs(exact)) {
            v = if (exact > 0) nextDown(v) else nextUp(v);
        },
        .rd => if (vd > exact) {
            v = nextDown(v);
        },
        .ru => if (vd < exact) {
            v = nextUp(v);
        },
    }
    return v;
}

/// f32 bits to f16 bits, rounded as `mode` (f16 subnormals kept; NaN:
/// NAN16; overflow to inf or the largest finite, as the mode says).
pub fn f32ToF16(xb: u32, mode: kir.Round) u32 {
    const sign: u32 = (xb >> 16) & 0x8000;
    const mag = xb & 0x7fff_ffff;
    if (mag > 0x7f80_0000) return NAN16;
    if (mag == 0x7f80_0000) return sign | 0x7c00;
    const neg = sign != 0;
    // rounding of the magnitude: away (up), toward zero, or to nearest even
    const up = (mode == .ru and !neg) or (mode == .rd and neg);
    const trunc = mode == .rz or (mode == .rd and !neg) or (mode == .ru and neg);
    if (mag == 0) return sign;
    // |x| = m * 2^e
    const ef: i32 = @intCast(mag >> 23);
    var m: u64 = mag & 0x7f_ffff;
    var e: i32 = undefined;
    if (ef == 0) {
        e = -149;
    } else {
        m |= 0x80_0000;
        e = ef - 150;
    }
    // log2 floor of |x|
    const top: i32 = 63 - @as(i32, @clz(m));
    const lg = e + top;
    // the result's quantum: 2^(lg-10), at least 2^-24 (f16 subnormals)
    const qe: i32 = @max(lg - 10, -24);
    const shift = qe - e;
    var n: u64 = undefined;
    if (shift <= 0) {
        n = m << @intCast(-shift);
    } else if (shift >= 63) {
        n = if (up) 1 else 0;
    } else {
        const sh: u6 = @intCast(shift);
        n = m >> sh;
        const rem = m & ((@as(u64, 1) << sh) - 1);
        const half = @as(u64, 1) << (sh - 1);
        if (rem != 0) {
            if (up) {
                n += 1;
            } else if (!trunc) {
                if (rem > half or (rem == half and n & 1 == 1)) n += 1;
            }
        }
    }
    // n * 2^qe; carry into the next binade
    var q = qe;
    if (n >= 2048) {
        n >>= 1;
        q += 1;
    }
    if (n == 0) return sign;
    // subnormal (q == -24, n < 1024) and normal share the encoding: n
    // with the exponent above it
    var res: u64 = undefined;
    if (q == -24 and n < 1024) {
        res = n;
    } else {
        const be = q + 25; // biased exponent for n in [1024, 2048)
        if (be >= 31) {
            return sign | (if (trunc) @as(u32, 0x7bff) else 0x7c00);
        }
        res = (@as(u64, @intCast(be)) << 10) + (n - 1024);
    }
    return sign | @as(u32, @intCast(res));
}

/// f16 bits to f32 bits (exact; NaN: NAN).
pub fn f16ToF32(hb: u32) u32 {
    const sign: u32 = (hb & 0x8000) << 16;
    const e = (hb >> 10) & 0x1f;
    const m = hb & 0x3ff;
    if (e == 31) return if (m == 0) sign | 0x7f80_0000 else NAN;
    if (e == 0) {
        if (m == 0) return sign;
        // m * 2^-24
        const v: f32 = @as(f32, @floatFromInt(m)) * (1.0 / 16777216.0);
        return sign | bits(v);
    }
    return sign | ((e + 112) << 23) | (m << 13);
}

fn convert(fp: Fp, x: u32, c: kir.Cvt) u32 {
    const from_int = c.from == .u32 or c.from == .i32;
    const to_int = c.to == .u32 or c.to == .i32;
    if (from_int and to_int) return x;
    if (from_int) return fp.out(intToF32(x, c.from == .i32, c.round)); // (to f32)
    var src: u32 = x;
    if (c.from == .f16) {
        src = f16ToF32(x & 0xffff);
        if (c.to == .f32) return src;
    } else {
        src = fp.in(x);
    }
    if (to_int) return f32ToInt(flt(src), c.to == .i32, c.round);
    if (c.to == .f16) return f32ToF16(src, c.round);
    return src;
}

// ── Integers ────────────────────────────────────────────────────────────────

fn signedTy(ty: Ty) bool {
    return ty == .i32;
}

fn bfe(x: u32, off_raw: u32, width_raw: u32, signed: bool) u32 {
    const off: u5 = @intCast(off_raw & 31);
    const room: u32 = 32 - @as(u32, off);
    const w: u32 = @min(width_raw, room);
    if (w == 0) return 0;
    const v = x >> off;
    if (w == 32) return v;
    const mask = (@as(u32, 1) << @intCast(w)) - 1;
    const field = v & mask;
    if (signed and (field >> @intCast(w - 1)) & 1 == 1) return field | ~mask;
    return field;
}

fn dot4(a: u32, b: u32, acc: u32, mode: kir.Dot4) u32 {
    var s = acc;
    for (0..4) |k| {
        const sh: u5 = @intCast(8 * k);
        const ab: u8 = @truncate(a >> sh);
        const bb: u8 = @truncate(b >> sh);
        const av: i32 = if (mode == .u8u8) ab else @as(i8, @bitCast(ab));
        const bv: i32 = if (mode == .s8s8) @as(i8, @bitCast(bb)) else bb;
        s +%= @bitCast(av * bv);
    }
    return s;
}

fn icmp(a: u32, b: u32, signed: bool, c: kir.Cmp) bool {
    if (signed) {
        const x: i32 = @bitCast(a);
        const y: i32 = @bitCast(b);
        return switch (c) {
            .eq => x == y,
            .ne => x != y,
            .lt => x < y,
            .le => x <= y,
            .gt => x > y,
            .ge => x >= y,
        };
    }
    return switch (c) {
        .eq => a == b,
        .ne => a != b,
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
    };
}

// ── The machine ─────────────────────────────────────────────────────────────

const Machine = struct {
    l: *const Launch,
    caps: Caps,
    fp: Fp,
    code: []const Inst,
    /// for if: its else or endif; else: its endif; loop: its endloop;
    /// endloop: its loop
    match: []u32,
    threads: u32,
    sub: u32,
    regs: []u32,
    sa: []u32,
    sb: []u32,
    sc: []u32,
    tmp: []u32,
    lanes: []u16,
    n_lanes: usize = 0,
    shared: []u8,
    owners: []Owner,
    epoch: u32 = 1,
    frames: []Frame,
    depth: usize = 0,
    act: Mask = empty,
    alive: Mask = empty,
    all: Mask = empty,
    group: [3]u32 = .{ 0, 0, 0 },
    trap: *Trap,
    stats: *Stats,
    pc: u32 = 0,

    fn file(m: *Machine, v: kir.V) []u32 {
        const t: usize = m.threads;
        return m.regs[@as(usize, @intFromEnum(v)) * t ..][0..t];
    }

    /// The operand's per-lane values (an immediate filled into `scratch`).
    fn src(m: *Machine, a: kir.Arg, scratch: []u32) []const u32 {
        switch (a) {
            .reg => |v| return if (v == .none) scratch else m.file(v),
            .imm => |x| {
                for (m.lanes[0..m.n_lanes]) |t| scratch[t] = x;
                return scratch;
            },
        }
    }

    fn setLanes(m: *Machine) void {
        var n: usize = 0;
        for (m.act, 0..) |w0, wi| {
            var w = w0;
            while (w != 0) {
                const b: usize = @ctz(w);
                w &= w - 1;
                m.lanes[n] = @intCast(wi * 64 + b);
                n += 1;
            }
        }
        m.n_lanes = n;
    }

    fn fail(m: *Machine, what: Trap.What, t: usize, binding: u8, offset: u64) Error {
        m.trap.* = .{ .what = what, .pc = m.pc, .group = m.group, .thread = @intCast(t), .binding = binding, .offset = offset };
        return error.Trap;
    }

    fn tidOf(m: *const Machine, t: u32, axis: u32) u32 {
        const g = m.l.group;
        return switch (axis) {
            0 => t % g[0],
            1 => (t / g[0]) % g[1],
            else => t / (g[0] * g[1]),
        };
    }

    // ── memory ──

    fn bytesOf(m: *Machine, mem: kir.Mem) ?[]u8 {
        return switch (mem.space) {
            .global => if (mem.binding < m.l.bindings.len) m.l.bindings[mem.binding] else null,
            .shared => m.shared,
        };
    }

    /// The checked byte address of an access by lane t.
    fn addr(m: *Machine, mem: kir.Mem, off: u32, t: usize) Error!usize {
        const space = m.bytesOf(mem) orelse return m.fail(.bad_binding, t, mem.binding, off);
        const n = kir.memBytes(mem);
        const at = @as(u64, off) + mem.imm;
        const tag: u8 = if (mem.space == .shared) 0xff else mem.binding;
        if (at % n != 0) return m.fail(.misaligned, t, tag, at);
        if (at + n > space.len) return m.fail(.out_of_bounds, t, tag, at);
        return @intCast(at);
    }

    /// The race check for shared bytes [at, at+n) by thread t.
    fn touch(m: *Machine, at: usize, n: usize, t: usize, write: bool) Error!void {
        const me: u16 = @intCast(t + 1);
        var wd = at / 4;
        while (wd * 4 < at + n) : (wd += 1) {
            const o = &m.owners[wd];
            if (o.w_epoch == m.epoch and o.w_tid != me) return m.fail(.shared_race, t, 0xff, wd * 4);
            if (write) {
                if (o.r_epoch == m.epoch and o.r_tid != me) return m.fail(.shared_race, t, 0xff, wd * 4);
                o.w_epoch = m.epoch;
                o.w_tid = me;
            } else {
                if (o.r_epoch != m.epoch) {
                    o.r_epoch = m.epoch;
                    o.r_tid = me;
                } else if (o.r_tid != me) o.r_tid = 0xffff;
            }
        }
    }

    fn load(m: *Machine, in: Inst) Error!void {
        const mem: kir.Mem = @bitCast(in.aux);
        const off = m.src(in.a, m.sa);
        const space = m.bytesOf(mem) orelse return m.fail(.bad_binding, 0, mem.binding, 0);
        const nb = kir.memBytes(mem);
        const nr = kir.memRegs(mem);
        const d0: usize = @intFromEnum(in.dst);
        const t_n: usize = m.threads;
        for (m.lanes[0..m.n_lanes]) |t| {
            const at = try m.addr(mem, off[t], t);
            if (mem.space == .shared) try m.touch(at, nb, t, false);
            const p = space[at..][0..nb];
            switch (nb) {
                1 => m.regs[d0 * t_n + t] = if (mem.signed) @bitCast(@as(i32, @as(i8, @bitCast(p[0])))) else p[0],
                2 => {
                    const h = std.mem.readInt(u16, p[0..2], .little);
                    m.regs[d0 * t_n + t] = if (mem.signed) @bitCast(@as(i32, @as(i16, @bitCast(h)))) else h;
                },
                else => for (0..nr) |j| {
                    m.regs[(d0 + j) * t_n + t] = std.mem.readInt(u32, p[4 * j ..][0..4], .little);
                },
            }
        }
    }

    fn store(m: *Machine, in: Inst) Error!void {
        const mem: kir.Mem = @bitCast(in.aux);
        const off = m.src(in.a, m.sa);
        const space = m.bytesOf(mem) orelse return m.fail(.bad_binding, 0, mem.binding, 0);
        const nb = kir.memBytes(mem);
        const nr = kir.memRegs(mem);
        const val = m.src(in.b, m.sb);
        const v0: usize = switch (in.b) {
            .reg => |v| @intFromEnum(v),
            .imm => 0,
        };
        const t_n: usize = m.threads;
        for (m.lanes[0..m.n_lanes]) |t| {
            const at = try m.addr(mem, off[t], t);
            if (mem.space == .shared) try m.touch(at, nb, t, true);
            const p = space[at..][0..nb];
            switch (nb) {
                1 => p[0] = @truncate(val[t]),
                2 => std.mem.writeInt(u16, p[0..2], @truncate(val[t]), .little),
                4 => std.mem.writeInt(u32, p[0..4], val[t], .little),
                else => for (0..nr) |j| {
                    std.mem.writeInt(u32, p[4 * j ..][0..4], m.regs[(v0 + j) * t_n + t], .little);
                },
            }
        }
    }

    fn atom(m: *Machine, in: Inst) Error!void {
        const mem: kir.Mem = @bitCast(in.aux);
        const off = m.src(in.a, m.sa);
        const val = m.src(in.b, m.sb);
        const space = m.bytesOf(mem) orelse return m.fail(.bad_binding, 0, mem.binding, 0);
        const kind: kir.Atom = @enumFromInt(in.c.imm);
        const signed = in.ty == .i32;
        const d = m.file(in.dst);
        // (lane order: the interpreter's, one at a time)
        for (m.lanes[0..m.n_lanes]) |t| {
            const at = try m.addr(mem, off[t], t);
            const p = space[at..][0..4];
            const old = std.mem.readInt(u32, p, .little);
            const v = val[t];
            const new: u32 = switch (kind) {
                .add => old +% v,
                .xchg => v,
                .@"and" => old & v,
                .@"or" => old | v,
                .xor => old ^ v,
                .min => if (signed) (if (@as(i32, @bitCast(v)) < @as(i32, @bitCast(old))) v else old) else @min(old, v),
                .max => if (signed) (if (@as(i32, @bitCast(v)) > @as(i32, @bitCast(old))) v else old) else @max(old, v),
            };
            std.mem.writeInt(u32, p, new, .little);
            d[t] = old;
        }
    }

    fn cas(m: *Machine, in: Inst) Error!void {
        const mem: kir.Mem = @bitCast(in.aux);
        const off = m.src(in.a, m.sa);
        const cmp = m.src(in.b, m.sb);
        const val = m.src(in.c, m.sc);
        const space = m.bytesOf(mem) orelse return m.fail(.bad_binding, 0, mem.binding, 0);
        const d = m.file(in.dst);
        for (m.lanes[0..m.n_lanes]) |t| {
            const at = try m.addr(mem, off[t], t);
            const p = space[at..][0..4];
            const old = std.mem.readInt(u32, p, .little);
            if (old == cmp[t]) std.mem.writeInt(u32, p, val[t], .little);
            d[t] = old;
        }
    }

    fn ballot(m: *Machine, in: Inst) void {
        const p = m.src(in.a, m.sa);
        const s = m.sub;
        const lo: u32 = 32 * (in.aux & 3);
        const d = m.file(in.dst);
        var start: u32 = 0;
        while (start < m.threads) : (start += s) {
            const end = @min(start + s, m.threads);
            var mask: u32 = 0;
            for (start..end) |t| {
                const ln: u32 = @as(u32, @intCast(t)) - start;
                if (!has(&m.act, t) or p[t] == 0 or ln < lo or ln >= lo + 32) continue;
                mask |= @as(u32, 1) << @intCast(ln - lo);
            }
            for (start..end) |t| {
                if (has(&m.act, t)) d[t] = mask;
            }
        }
    }

    fn shfl(m: *Machine, in: Inst) Error!void {
        const a = m.src(in.a, m.sa);
        // (a copy: the destination may be the source)
        for (m.lanes[0..m.n_lanes]) |t| m.tmp[t] = a[t];
        const b = m.src(in.b, m.sb);
        const mode: kir.Shfl = @enumFromInt(in.aux);
        const s = m.sub;
        const d = m.file(in.dst);
        for (m.lanes[0..m.n_lanes]) |t| {
            const ln: u32 = t % s;
            const base: u32 = t - ln;
            const k = b[t];
            const from: ?u32 = switch (mode) {
                .idx => k & (s - 1),
                .xor => ln ^ (k & (s - 1)),
                .up => if (k <= ln) ln - k else null,
                .down => if (k < s - ln) ln + k else null,
            };
            if (from) |fl| {
                const st = base + fl;
                if (st >= m.threads or !has(&m.act, st)) return m.fail(.inactive_lane, t, 0, st);
                d[t] = m.tmp[st];
            } else d[t] = m.tmp[t];
        }
    }

    fn vote(m: *Machine, in: Inst) void {
        const p = m.src(in.a, m.sa);
        const all = in.aux == @intFromEnum(kir.Vote.all);
        const s = m.sub;
        const d = m.file(in.dst);
        var start: u32 = 0;
        while (start < m.threads) : (start += s) {
            const end = @min(start + s, m.threads);
            var acc = all;
            var any_active = false;
            for (start..end) |t| {
                if (!has(&m.act, t)) continue;
                any_active = true;
                if (all) acc = acc and p[t] != 0 else acc = acc or p[t] != 0;
            }
            if (!any_active) continue;
            for (start..end) |t| {
                if (has(&m.act, t)) d[t] = @intFromBool(acc);
            }
        }
    }

    // ── flow ──

    fn push(m: *Machine, fr: Frame) Error!void {
        if (m.depth == m.frames.len) return error.BadProgram;
        m.frames[m.depth] = fr;
        m.depth += 1;
    }

    /// Lanes `x` leave every frame up to the innermost loop (brk, cont)
    /// or all of them (ret).
    fn leave(m: *Machine, x: *const Mask, to_loop: bool) ?*Frame {
        var ix = m.depth;
        while (ix > 0) {
            ix -= 1;
            const fr = &m.frames[ix];
            if (fr.kind == .loop and to_loop) return fr;
            andNot(&fr.saved, x);
            andNot(&fr.other, x);
            andNot(&fr.cont, x);
        }
        return null;
    }

    fn predMask(m: *Machine, a: kir.Arg) Mask {
        const p = m.src(a, m.sa);
        var x = empty;
        for (m.lanes[0..m.n_lanes]) |t| if (p[t] != 0) put(&x, t);
        return x;
    }

    /// Runs flow instruction `in`; returns the next pc.
    fn flow(m: *Machine, in: Inst, pc: u32) Error!u32 {
        switch (in.op) {
            .@"if" => {
                const p = m.predMask(in.a);
                var other = m.act;
                andNot(&other, &p);
                try m.push(.{ .kind = .if_then, .opener = pc, .saved = m.act, .other = other, .cont = empty });
                for (&m.act, p) |*a, b| a.* &= b;
            },
            .@"else" => {
                if (m.depth == 0) return error.BadProgram;
                const fr = &m.frames[m.depth - 1];
                if (fr.kind != .if_then) return error.BadProgram;
                fr.kind = .if_else;
                fr.opener = pc;
                m.act = fr.other;
            },
            .endif => {
                if (m.depth == 0) return error.BadProgram;
                const fr = &m.frames[m.depth - 1];
                if (fr.kind == .loop) return error.BadProgram;
                m.act = fr.saved;
                m.depth -= 1;
            },
            .loop => try m.push(.{ .kind = .loop, .opener = pc, .saved = m.act, .other = empty, .cont = empty }),
            .brk, .cont => {
                const x = m.predMask(in.a);
                andNot(&m.act, &x);
                const lp = m.leave(&x, true) orelse return error.BadProgram;
                if (in.op == .brk) orIn(&lp.other, &x) else orIn(&lp.cont, &x);
            },
            .endloop => {
                if (m.depth == 0) return error.BadProgram;
                const fr = &m.frames[m.depth - 1];
                if (fr.kind != .loop) return error.BadProgram;
                orIn(&m.act, &fr.cont);
                fr.cont = empty;
                if (!none(&m.act)) {
                    m.setLanes();
                    return fr.opener + 1;
                }
                m.act = fr.other;
                m.depth -= 1;
            },
            .ret => {
                const x = m.act;
                andNot(&m.alive, &x);
                _ = m.leave(&x, false);
                m.act = empty;
            },
            else => unreachable,
        }
        m.setLanes();
        return pc + 1;
    }

    fn runGroup(m: *Machine) Error!void {
        @memset(m.regs, POISON);
        for (m.owners) |*o| o.* = .{};
        m.epoch = 1;
        m.act = m.all;
        m.alive = m.all;
        m.depth = 0;
        m.setLanes();
        const n: u32 = @intCast(m.code.len);
        var pc: u32 = 0;
        while (pc < n) {
            if (m.n_lanes == 0) {
                // nothing active: on to the innermost frame's end
                if (m.depth == 0) return;
                const fr = &m.frames[m.depth - 1];
                const end = m.match[fr.opener];
                m.pc = end;
                pc = try m.flow(m.code[end], end);
                m.stats.issued += 1;
                continue;
            }
            const in = m.code[pc];
            m.pc = pc;
            m.stats.issued += 1;
            switch (in.op) {
                .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => {
                    pc = try m.flow(in, pc);
                    continue;
                },
                .barrier => {
                    if (!eql(&m.act, &m.all)) {
                        const t = firstMissing(&m.act, m.threads);
                        return m.fail(.divergent_barrier, t, 0, 0);
                    }
                    m.epoch += 1;
                },
                else => try m.exec(in),
            }
            m.stats.lane_ops += m.n_lanes;
            pc += 1;
        }
    }

    fn exec(m: *Machine, in: Inst) Error!void {
        const L = m.lanes[0..m.n_lanes];
        const fp = m.fp;
        switch (in.op) {
            .ld => return m.load(in),
            .st => return m.store(in),
            .atom => return m.atom(in),
            .cas => return m.cas(in),
            .shfl => return m.shfl(in),
            .vote => return m.vote(in),
            .ballot => return m.ballot(in),
            else => {},
        }
        const a = m.src(in.a, m.sa);
        const b = m.src(in.b, m.sb);
        const c = m.src(in.c, m.sc);
        const d = m.file(in.dst);
        const sg = signedTy(in.ty);
        switch (in.op) {
            .mov => for (L) |t| {
                d[t] = a[t];
            },
            .sel => for (L) |t| {
                d[t] = if (c[t] != 0) a[t] else b[t];
            },
            .iadd => for (L) |t| {
                d[t] = a[t] +% b[t];
            },
            .isub => for (L) |t| {
                d[t] = a[t] -% b[t];
            },
            .imul => for (L) |t| {
                d[t] = a[t] *% b[t];
            },
            .imulhi => for (L) |t| {
                d[t] = if (sg)
                    @truncate(@as(u64, @bitCast(@as(i64, @as(i32, @bitCast(a[t]))) * @as(i32, @bitCast(b[t])))) >> 32)
                else
                    @truncate((@as(u64, a[t]) * b[t]) >> 32);
            },
            .imad => for (L) |t| {
                d[t] = a[t] *% b[t] +% c[t];
            },
            .ineg => for (L) |t| {
                d[t] = 0 -% a[t];
            },
            .iabs => for (L) |t| {
                d[t] = if (a[t] & 0x8000_0000 != 0) 0 -% a[t] else a[t];
            },
            .imin => for (L) |t| {
                d[t] = if (icmp(a[t], b[t], sg, .lt)) a[t] else b[t];
            },
            .imax => for (L) |t| {
                d[t] = if (icmp(a[t], b[t], sg, .gt)) a[t] else b[t];
            },
            .@"and" => for (L) |t| {
                d[t] = a[t] & b[t];
            },
            .@"or" => for (L) |t| {
                d[t] = a[t] | b[t];
            },
            .xor => for (L) |t| {
                d[t] = a[t] ^ b[t];
            },
            .not => for (L) |t| {
                d[t] = ~a[t];
            },
            .shl => for (L) |t| {
                d[t] = a[t] << @intCast(b[t] & 31);
            },
            .shr => for (L) |t| {
                d[t] = if (sg) @bitCast(@as(i32, @bitCast(a[t])) >> @intCast(b[t] & 31)) else a[t] >> @intCast(b[t] & 31);
            },
            .bfe => for (L) |t| {
                d[t] = bfe(a[t], b[t], c[t], sg);
            },
            .dot4 => {
                const mode: kir.Dot4 = @enumFromInt(in.aux);
                for (L) |t| d[t] = dot4(a[t], b[t], c[t], mode);
            },
            .icmp => {
                const cc: kir.Cmp = @enumFromInt(in.aux);
                for (L) |t| d[t] = @intFromBool(icmp(a[t], b[t], sg, cc));
            },
            .fcmp => {
                const cc: kir.Cmp = @enumFromInt(in.aux);
                for (L) |t| d[t] = @intFromBool(fp.cmp(a[t], b[t], cc));
            },
            .pand => for (L) |t| {
                d[t] = @intFromBool(a[t] != 0 and b[t] != 0);
            },
            .por => for (L) |t| {
                d[t] = @intFromBool(a[t] != 0 or b[t] != 0);
            },
            .pnot => for (L) |t| {
                d[t] = @intFromBool(a[t] == 0);
            },
            .fadd => for (L) |t| {
                d[t] = fp.add(a[t], b[t]);
            },
            .fsub => for (L) |t| {
                d[t] = fp.sub(a[t], b[t]);
            },
            .fmul => for (L) |t| {
                d[t] = fp.mul(a[t], b[t]);
            },
            .ffma => for (L) |t| {
                d[t] = fp.fma(a[t], b[t], c[t]);
            },
            .fmad => for (L) |t| {
                d[t] = fp.mad(a[t], b[t], c[t]);
            },
            .fmin => for (L) |t| {
                d[t] = fp.minmax(a[t], b[t], false);
            },
            .fmax => for (L) |t| {
                d[t] = fp.minmax(a[t], b[t], true);
            },
            .fabs => for (L) |t| {
                d[t] = a[t] & 0x7fff_ffff;
            },
            .fneg => for (L) |t| {
                d[t] = a[t] ^ 0x8000_0000;
            },
            .ffloor, .fceil, .ftrunc, .frne => for (L) |t| {
                d[t] = fp.round(a[t], in.op);
            },
            .fdiv => for (L) |t| {
                d[t] = fp.div(a[t], b[t]);
            },
            .fsqrt => for (L) |t| {
                d[t] = fp.sqrt(a[t]);
            },
            .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos => for (L) |t| {
                d[t] = fp.approx(a[t], in.op);
            },
            .cvt => {
                const cv: kir.Cvt = @bitCast(in.aux);
                for (L) |t| d[t] = convert(fp, a[t], cv);
            },
            .tid => for (L) |t| {
                d[t] = m.tidOf(t, in.aux);
            },
            .gid => {
                const g = m.group[@min(in.aux, 2)];
                for (L) |t| d[t] = g;
            },
            .gsize => {
                const g = m.l.groups[@min(in.aux, 2)];
                for (L) |t| d[t] = g;
            },
            .lane => for (L) |t| {
                d[t] = t % m.sub;
            },
            .subgroup => for (L) |t| {
                d[t] = m.sub;
            },
            .param => {
                if (in.aux >= m.l.params.len) return error.BadProgram;
                const w = m.l.params[in.aux];
                for (L) |t| d[t] = w;
            },
            else => return error.BadProgram,
        }
    }
};

fn firstMissing(act: *const Mask, threads: u32) u32 {
    for (0..threads) |t| if (!has(act, t)) return @intCast(t);
    return 0;
}

fn regIn(v: kir.V, regs: u32, n: u32) bool {
    return v != .none and @as(u32, @intFromEnum(v)) + n <= regs;
}

fn argOk(a: kir.Arg, regs: u32) bool {
    return switch (a) {
        .reg => |v| v == .none or @intFromEnum(v) < regs,
        .imm => true,
    };
}

/// Checks what the interpreter relies on (registers in range, the flow
/// balanced) and finds each flow instruction's partner.
fn prepare(code: []const Inst, regs: u32, match: []u32) Error!void {
    var stack: [MAX_DEPTH]u32 = undefined;
    var depth: usize = 0;
    for (code, 0..) |in, pc| {
        match[pc] = 0;
        const n: u32 = switch (in.op) {
            .ld => kir.memRegs(@bitCast(in.aux)),
            else => 1,
        };
        switch (in.op) {
            .st, .barrier, .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => {},
            else => if (!regIn(in.dst, regs, n)) return error.BadProgram,
        }
        if (!argOk(in.a, regs) or !argOk(in.b, regs) or !argOk(in.c, regs)) return error.BadProgram;
        // operands the op reads must be registers or immediates, not none
        switch (in.op) {
            .st => {
                const nr = kir.memRegs(@bitCast(in.aux));
                switch (in.b) {
                    .reg => |v| if (!regIn(v, regs, nr)) return error.BadProgram,
                    .imm => if (nr != 1) return error.BadProgram,
                }
            },
            .atom => if (in.c != .imm or in.c.imm > @intFromEnum(kir.Atom.xor)) return error.BadProgram,
            .cas => if ((in.aux >> 8) & 3 > 1 or (in.aux >> 10) & 7 != 5) return error.BadProgram,
            .ballot => if (in.aux > 3) return error.BadProgram,
            .icmp, .fcmp => if (in.aux > @intFromEnum(kir.Cmp.ge)) return error.BadProgram,
            .dot4 => if (in.aux > @intFromEnum(kir.Dot4.u8u8)) return error.BadProgram,
            .shfl => if (in.aux > @intFromEnum(kir.Shfl.down)) return error.BadProgram,
            .ld => if ((in.aux >> 8) & 3 > 1 or (in.aux >> 10) & 7 < 3) return error.BadProgram,
            .cvt => {
                const c: kir.Cvt = @bitCast(in.aux);
                if (@intFromEnum(c.from) > @intFromEnum(Ty.pred) or @intFromEnum(c.to) > @intFromEnum(Ty.pred) or @intFromEnum(c.round) > 3) return error.BadProgram;
            },
            else => {},
        }
        if (in.op == .st or in.op == .atom) {
            if ((in.aux >> 8) & 3 > 1 or (in.aux >> 10) & 7 < 3) return error.BadProgram;
        }
        inline for (.{ in.a, in.b, in.c }, 0..) |arg, ix| {
            const used = switch (in.op) {
                .mov, .ineg, .iabs, .not, .pnot, .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne, .fsqrt, .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos, .cvt, .ld, .vote, .ballot, .@"if", .brk, .cont => ix == 0,
                .sel, .imad, .bfe, .dot4, .ffma, .fmad, .atom, .cas => true,
                .iadd, .isub, .imul, .imulhi, .imin, .imax, .@"and", .@"or", .xor, .shl, .shr, .icmp, .fcmp, .pand, .por, .fadd, .fsub, .fmul, .fmin, .fmax, .fdiv, .st, .shfl => ix < 2,
                else => false,
            };
            if (used and arg == .reg and arg.reg == .none) return error.BadProgram;
        }
        switch (in.op) {
            .@"if", .loop => {
                if (depth == MAX_DEPTH) return error.BadProgram;
                stack[depth] = @intCast(pc);
                depth += 1;
            },
            .@"else" => {
                if (depth == 0 or code[stack[depth - 1]].op != .@"if") return error.BadProgram;
                match[stack[depth - 1]] = @intCast(pc);
                stack[depth - 1] = @intCast(pc);
            },
            .endif => {
                if (depth == 0 or code[stack[depth - 1]].op == .loop) return error.BadProgram;
                match[stack[depth - 1]] = @intCast(pc);
                depth -= 1;
            },
            .endloop => {
                if (depth == 0 or code[stack[depth - 1]].op != .loop) return error.BadProgram;
                match[stack[depth - 1]] = @intCast(pc);
                match[pc] = stack[depth - 1];
                depth -= 1;
            },
            .brk, .cont => {
                var inside = false;
                for (stack[0..depth]) |s| if (code[s].op == .loop) {
                    inside = true;
                };
                if (!inside) return error.BadProgram;
            },
            else => {},
        }
    }
    if (depth != 0) return error.BadProgram;
}

/// Run `l` under `caps` with scratch space from `work` (given back after).
pub fn run(l: Launch, caps: Caps, work: *device.Work, trap: *Trap, stats: *Stats) Error!void {
    trap.* = .{};
    stats.* = .{};
    const threads64 = @as(u64, l.group[0]) * l.group[1] * l.group[2];
    if (threads64 == 0 or threads64 > MAX_THREADS) return error.BadProgram;
    const threads: u32 = @intCast(threads64);
    const s = caps.subgroup;
    if (s == 0 or s > 1024 or s & (s - 1) != 0) return error.BadProgram;
    if (l.regs > 0xffff) return error.BadProgram;
    if (l.groups[0] == 0 or l.groups[1] == 0 or l.groups[2] == 0) return;
    const mark = work.mark();
    defer work.release(mark);
    const match = work.take(u32, l.code.len) orelse return error.NoWork;
    prepare(l.code, l.regs, match) catch {
        trap.what = .bad_program;
        return error.BadProgram;
    };
    const t: usize = threads;
    var m = Machine{
        .l = &l,
        .caps = caps,
        .fp = .{ .flush = caps.denormals == .flush, .fused_mad = caps.mad == .fused, .jitter = l.jitter_ulps },
        .code = l.code,
        .match = match,
        .threads = threads,
        .sub = s,
        .regs = work.take(u32, @as(usize, l.regs) * t) orelse return error.NoWork,
        .sa = work.take(u32, t) orelse return error.NoWork,
        .sb = work.take(u32, t) orelse return error.NoWork,
        .sc = work.take(u32, t) orelse return error.NoWork,
        .tmp = work.take(u32, t) orelse return error.NoWork,
        .lanes = work.take(u16, t) orelse return error.NoWork,
        .shared = work.take(u8, l.shared_bytes) orelse return error.NoWork,
        .owners = work.take(Owner, (l.shared_bytes + 3) / 4) orelse return error.NoWork,
        .frames = work.take(Frame, MAX_DEPTH) orelse return error.NoWork,
        .trap = trap,
        .stats = stats,
    };
    for (0..threads) |ti| put(&m.all, ti);
    var gz: u32 = 0;
    while (gz < l.groups[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < l.groups[1]) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < l.groups[0]) : (gx += 1) {
                m.group = .{ gx, gy, gz };
                // shared memory starts undefined on a GPU; here: poison
                @memset(m.shared, 0xa5);
                try m.runGroup();
                stats.groups += 1;
            }
        }
    }
}

/// Run a kernel as built (verified first): the tests' shortcut.
pub fn runKernel(k: *const kir.Kernel, caps: Caps, groups: [3]u32, bindings: []const []u8, params: []const u32, work: *device.Work, trap: *Trap) (Error || kir.Error)!Stats {
    try kir.verify(k, caps);
    var stats: Stats = .{};
    try run(.{
        .code = k.code(),
        .regs = k.nv,
        .group = k.group,
        .shared_bytes = k.shared_bytes,
        .groups = groups,
        .bindings = bindings,
        .params = params,
    }, caps, work, trap, &stats);
    return stats;
}

test "interp: fma32 rounds once" {
    var rng = std.Random.DefaultPrng.init(7);
    const rand = rng.random();
    var n: usize = 0;
    while (n < 200_000) : (n += 1) {
        const a = flt(rand.int(u32));
        const b = flt(rand.int(u32));
        // c near -a*b, where a second rounding shows
        const c0 = flt(rand.int(u32));
        const c = if (n & 1 == 0) -(a * b) else c0;
        const want = @mulAdd(f32, a, b, c);
        const got = fma32(a, b, c);
        if (std.math.isNan(want)) {
            try std.testing.expect(std.math.isNan(got));
        } else try std.testing.expectEqual(bits(want), bits(got));
    }
}
