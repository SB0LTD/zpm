//! @zpm/ps5gfx recompile_emit — a shader's lane side as KIR (recompile.sig
//! says what each side is): one lane is one thread of the raster's vertex
//! or tile kernel.
//!
//! - **Registers.** A VGPR is one KIR register, written afresh by every
//!   instruction (the code is straight-line): a u32, an i32 or an f32 as
//!   the instruction that wrote it computes, reinterpreted with KIR's
//!   `mov` where a reader wants another type. A VGPR never written reads
//!   0. A lane mask (VCC, an SGPR or a pair) is one pred register, kept by
//!   the mask's first register.
//! - **Scalar values** lane code reads are uniform words (the read slots),
//!   loaded once each.
//! - **Buffer loads** compute their byte offset in the window (index *
//!   stride + the offsets) and load only where the window holds what is
//!   read (a format load's whole element; each dword of a raw load on its
//!   own) and, indexed with a stride, the index is below the record
//!   count; else they give 0, as the hardware's out-of-range loads do and
//!   because KIR traps outside a binding. A format load converts the
//!   element as its format says and routes the channels by the V#'s
//!   dst_sel (a "one" channel is 1 in range or not). Offsets are rounded down to
//!   the access's alignment (KIR's accesses are aligned; the hardware's
//!   unaligned buffer accesses are not modelled).
//! - **Floats.** VOP3's abs and neg on float sources, omod (x2, x4, /2)
//!   and clamp (0..1) on float results. v_mad_f32, v_mac_f32, v_fma_f32
//!   and v_fmac_f32 are KIR's fmad (the GPU's own multiply-add, rounded
//!   once or twice: v_fma's single rounding is not guaranteed, as KIR's
//!   ffma is not on every device the engine runs on). v_rcp_f32 and
//!   v_rsq_f32 are KIR's frcp and frsq, approximate as the hardware's are
//!   but not bit for bit the same; v_sqrt_f32 is KIR's exact fsqrt (the
//!   hardware's is approximate). Denormals are kept (KIR's rule), as the
//!   PS5's FLOAT_MODE 0xC0 keeps them. v_min/v_max_f32 with a NaN give
//!   the other operand (the non-IEEE mode). v_cvt_*_f32 to integers round
//!   toward zero and saturate, NaN to 0.
//!
//! The invariant (recompile.sig): from the Evaluation this reads only
//! what its key covers: which window a load reads, a format load's format
//! and dst_sel. Strides, record counts, window sizes and every scalar come
//! through uniform words.

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const rc = @import("recompile.sig");
const state = rc.state;
const gfx10 = rc.gfx10;
const kir = gpu.kir;
const raster = gfxapi.raster;
const Instr = gfx10.Instr;
const op = gfx10.op;

const V = kir.V;
const Ty = kir.Ty;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;

const F_ONE: u32 = 0x3f80_0000;
const F_NAN: u32 = 0x7fc0_0000;
const F_INF: u32 = 0x7f80_0000;
/// The largest float below 1 (v_fract's bound).
const F_BELOW_ONE: u32 = 0x3f7f_ffff;

fn isInt(t: Ty) bool {
    return t == .u32 or t == .i32;
}

const Emit = struct {
    p: *const rc.Program,
    ev: *const rc.Evaluation,
    lay: rc.Layout,
    k: *kir.Kernel,
    uni: u8,
    buf: u8,
    vio: ?*raster.VertexIO = null,
    fio: ?*raster.FragmentIO = null,
    vg: [256]V = [_]V{.none} ** 256,
    mk: [128]V = [_]V{.none} ** 128,
    ucache: [rc.MAX_WORDS]V = [_]V{.none} ** rc.MAX_WORDS,

    // ── values ──

    /// `v` as type `ty` (a fresh mov where the register's type differs).
    fn as(e: *Emit, v: V, ty: Ty) Arg {
        if (v == .none) return u(0);
        const have = e.k.tys[@intFromEnum(v)];
        if (have == ty or (isInt(have) and isInt(ty))) return r(v);
        return r(e.k.mov(ty, r(v)));
    }

    fn reg(e: *Emit, a: Arg, ty: Ty) V {
        return switch (a) {
            .reg => |v| v,
            .imm => e.k.mov(ty, a),
        };
    }

    /// Word `w` of this stage's uniform words (a u32 register).
    fn word(e: *Emit, w: u32) V {
        if (w < e.ucache.len and e.ucache[w] != .none) return e.ucache[w];
        const v = raster.uniform(e.k, .u32, e.uni, e.lay.uniform_base + w);
        if (w < e.ucache.len) e.ucache[w] = v;
        return v;
    }

    fn vreg(e: *Emit, n: usize, ty: Ty) Arg {
        return e.as(e.vg[n], ty);
    }

    fn setv(e: *Emit, n: usize, v: V) void {
        e.vg[n] = v;
    }

    /// Source `ix` of instruction `i` as `ty`, with abs and neg applied
    /// to a float.
    fn src(e: *Emit, i: u16, ix: u2, ty: Ty) Arg {
        const in = &e.p.insts[i];
        const c = in.src[ix];
        var a: Arg = undefined;
        if (c >= gfx10.VGPR0) {
            a = e.vreg(c - gfx10.VGPR0, ty);
        } else if (e.p.slot[i][ix] != rc.NO_SLOT) {
            a = e.as(e.word(e.p.slot[i][ix]), ty);
        } else {
            a = u(constBits(c, in.lit, ty));
        }
        if (ty != .f32) return a;
        const abs = (in.abs >> ix) & 1 != 0;
        const neg = (in.neg >> ix) & 1 != 0;
        switch (a) {
            .imm => |x| {
                var b = x;
                if (abs) b &= 0x7fff_ffff;
                if (neg) b ^= 0x8000_0000;
                return u(b);
            },
            .reg => {
                var v = a;
                if (abs) v = r(e.k.op1(.fabs, .f32, v));
                if (neg) v = r(e.k.op1(.fneg, .f32, v));
                return v;
            },
        }
    }

    /// A float result with the instruction's omod and clamp applied.
    fn fres(e: *Emit, in: *const Instr, x: V) V {
        var v = x;
        switch (in.omod) {
            1 => v = e.k.op2(.fmul, .f32, r(v), f(2)),
            2 => v = e.k.op2(.fmul, .f32, r(v), f(4)),
            3 => v = e.k.op2(.fmul, .f32, r(v), f(0.5)),
            else => {},
        }
        if (in.clamp) v = e.k.op2(.fmin, .f32, r(e.k.op2(.fmax, .f32, r(v), f(0))), f(1));
        return v;
    }

    /// Source `ix` of instruction `i` as a lane mask: a uniform mask (a
    /// slot: every lane where its word is not 0, else none), the pred a
    /// register holds, EXEC (every lane), or the constants 0 and -1.
    fn mask(e: *Emit, i: u16, ix: u2) Arg {
        const slot = e.p.slot[i][ix];
        if (slot != rc.NO_SLOT) return r(e.k.cmp(.u32, .ne, r(e.word(slot)), u(0)));
        const code = e.p.insts[i].src[ix];
        return switch (code) {
            gfx10.EXEC_LO, gfx10.EXEC_HI => u(1),
            128 => u(0),
            193 => u(1),
            else => if (code < 128 and e.mk[code] != .none) r(e.mk[code]) else u(0),
        };
    }

    fn setMask(e: *Emit, code: u16, p: V) void {
        if (code < 128 and code != gfx10.NULL) e.mk[code] = p;
    }

    // ── the instructions ──

    fn run(e: *Emit) void {
        const p = e.p;
        var i: u16 = 0;
        while (i < p.n) : (i += 1) {
            switch (p.side[i]) {
                .lane => e.lane(i),
                .mask => e.maskLogic(i),
                else => {},
            }
        }
    }

    fn lane(e: *Emit, i: u16) void {
        const in = &e.p.insts[i];
        switch (in.enc()) {
            .vintrp => e.interp(in),
            .exp => e.exportOf(in),
            .mubuf, .mtbuf => e.bufferLoad(i),
            else => e.valu(i),
        }
    }

    fn maskLogic(e: *Emit, i: u16) void {
        const in = &e.p.insts[i];
        const k = e.k;
        const a = e.mask(i, 0);
        const res: V = switch (in.op) {
            op("s_mov_b32"), op("s_mov_b64") => e.reg(a, .pred),
            op("s_not_b32"), op("s_not_b64") => k.op1(.pnot, .pred, a),
            else => blk: {
                const b = e.mask(i, 1);
                break :blk switch (in.op) {
                    op("s_and_b32"), op("s_and_b64") => k.op2(.pand, .pred, a, b),
                    op("s_or_b32"), op("s_or_b64") => k.op2(.por, .pred, a, b),
                    op("s_andn2_b32"), op("s_andn2_b64") => k.op2(.pand, .pred, a, r(k.op1(.pnot, .pred, b))),
                    op("s_orn2_b32"), op("s_orn2_b64") => k.op2(.por, .pred, a, r(k.op1(.pnot, .pred, b))),
                    // (xor: a and not b, or b and not a)
                    else => k.op2(.por, .pred, r(k.op2(.pand, .pred, a, r(k.op1(.pnot, .pred, b)))), r(k.op2(.pand, .pred, b, r(k.op1(.pnot, .pred, a))))),
                };
            },
        };
        e.setMask(in.dst, res);
    }

    fn valu(e: *Emit, i: u16) void {
        const in = &e.p.insts[i];
        const k = e.k;
        const df = in.d();
        if (df.shape == .vopc) return e.compare(i);
        const d: usize = in.dst - gfx10.VGPR0;
        switch (in.op) {
            op("v_mov_b32") => {
                const c = in.src[0];
                const v = if (c >= gfx10.VGPR0)
                    (if (e.vg[c - gfx10.VGPR0] == .none) k.mov(.u32, u(0)) else e.vg[c - gfx10.VGPR0])
                else
                    e.reg(e.src(i, 0, .u32), .u32);
                e.setv(d, v);
            },
            // floats, two operands
            op("v_add_f32") => e.fop2(i, .fadd, false),
            op("v_sub_f32") => e.fop2(i, .fsub, false),
            op("v_subrev_f32") => e.fop2(i, .fsub, true),
            op("v_mul_f32") => e.fop2(i, .fmul, false),
            op("v_min_f32") => e.fop2(i, .fmin, false),
            op("v_max_f32") => e.fop2(i, .fmax, false),
            // multiply-adds
            op("v_mad_f32"), op("v_fma_f32") => {
                const v = k.op3(.fmad, .f32, e.src(i, 0, .f32), e.src(i, 1, .f32), e.src(i, 2, .f32));
                e.setv(d, e.fres(in, v));
            },
            op("v_mac_f32"), op("v_fmac_f32") => {
                const v = k.op3(.fmad, .f32, e.src(i, 0, .f32), e.src(i, 1, .f32), e.vreg(d, .f32));
                e.setv(d, e.fres(in, v));
            },
            op("v_madmk_f32") => e.setv(d, k.op3(.fmad, .f32, e.src(i, 0, .f32), u(in.lit), e.src(i, 1, .f32))),
            op("v_madak_f32") => e.setv(d, k.op3(.fmad, .f32, e.src(i, 0, .f32), e.src(i, 1, .f32), u(in.lit))),
            // floats, one operand
            op("v_rcp_f32") => e.fop1(i, .frcp),
            op("v_rsq_f32") => e.fop1(i, .frsq),
            op("v_sqrt_f32") => e.fop1(i, .fsqrt),
            op("v_floor_f32") => e.fop1(i, .ffloor),
            op("v_ceil_f32") => e.fop1(i, .fceil),
            op("v_trunc_f32") => e.fop1(i, .ftrunc),
            op("v_rndne_f32") => e.fop1(i, .frne),
            op("v_fract_f32") => {
                // x - floor(x), below 1; NaN stays NaN, an infinity is NaN
                const x = e.reg(e.src(i, 0, .f32), .f32);
                const fr = k.op2(.fmin, .f32, r(k.op2(.fsub, .f32, r(x), r(k.op1(.ffloor, .f32, r(x))))), u(F_BELOW_ONE));
                const nan = k.cmp(.f32, .ne, r(x), r(x));
                const inf = k.cmp(.f32, .eq, r(k.op1(.fabs, .f32, r(x))), u(F_INF));
                const v = k.sel(.f32, r(inf), u(F_NAN), r(k.sel(.f32, r(nan), r(x), r(fr))));
                e.setv(d, e.fres(in, v));
            },
            // conversions
            op("v_cvt_f32_i32") => e.setv(d, e.fres(in, k.cvt(.i32, .f32, .rne, e.src(i, 0, .u32)))),
            op("v_cvt_f32_u32") => e.setv(d, e.fres(in, k.cvt(.u32, .f32, .rne, e.src(i, 0, .u32)))),
            op("v_cvt_i32_f32") => e.setv(d, k.cvt(.f32, .i32, .rz, e.src(i, 0, .f32))),
            op("v_cvt_u32_f32") => e.setv(d, k.cvt(.f32, .u32, .rz, e.src(i, 0, .f32))),
            op("v_cvt_f32_ubyte0"), op("v_cvt_f32_ubyte1"), op("v_cvt_f32_ubyte2"), op("v_cvt_f32_ubyte3") => {
                const n: u32 = switch (in.op) {
                    op("v_cvt_f32_ubyte0") => 0,
                    op("v_cvt_f32_ubyte1") => 1,
                    op("v_cvt_f32_ubyte2") => 2,
                    else => 3,
                };
                const b = k.op3(.bfe, .u32, e.src(i, 0, .u32), u(8 * n), u(8));
                e.setv(d, e.fres(in, k.cvt(.u32, .f32, .rne, r(b))));
            },
            op("v_cvt_pkrtz_f16_f32") => {
                const lo = e.half(e.src(i, 0, .f32));
                const hi = e.half(e.src(i, 1, .f32));
                e.setv(d, k.op2(.@"or", .u32, r(lo), r(k.op2(.shl, .u32, r(hi), u(16)))));
            },
            // integers
            op("v_and_b32") => e.iop2(i, .@"and", .u32, false),
            op("v_or_b32") => e.iop2(i, .@"or", .u32, false),
            op("v_xor_b32") => e.iop2(i, .xor, .u32, false),
            op("v_not_b32") => e.setv(d, k.op1(.not, .u32, e.src(i, 0, .u32))),
            op("v_lshlrev_b32") => e.iop2(i, .shl, .u32, true),
            op("v_lshrrev_b32") => e.iop2(i, .shr, .u32, true),
            op("v_ashrrev_i32") => e.iop2(i, .shr, .i32, true),
            op("v_add_nc_u32") => e.iop2(i, .iadd, .u32, false),
            op("v_sub_nc_u32") => e.iop2(i, .isub, .u32, false),
            op("v_subrev_nc_u32") => e.iop2(i, .isub, .u32, true),
            op("v_mul_lo_u32") => e.iop2(i, .imul, .u32, false),
            op("v_mul_hi_u32") => e.iop2(i, .imulhi, .u32, false),
            op("v_min_i32") => e.iop2(i, .imin, .i32, false),
            op("v_max_i32") => e.iop2(i, .imax, .i32, false),
            op("v_min_u32") => e.iop2(i, .imin, .u32, false),
            op("v_max_u32") => e.iop2(i, .imax, .u32, false),
            op("v_mul_u32_u24"), op("v_mad_u32_u24") => {
                const a = k.op2(.@"and", .u32, e.src(i, 0, .u32), u(0xff_ffff));
                const b = k.op2(.@"and", .u32, e.src(i, 1, .u32), u(0xff_ffff));
                var v = k.op2(.imul, .u32, r(a), r(b));
                if (in.op == op("v_mad_u32_u24")) v = k.op2(.iadd, .u32, r(v), e.src(i, 2, .u32));
                e.setv(d, v);
            },
            op("v_mul_i32_i24") => {
                const a = k.op3(.bfe, .i32, e.src(i, 0, .u32), u(0), u(24));
                const b = k.op3(.bfe, .i32, e.src(i, 1, .u32), u(0), u(24));
                e.setv(d, k.op2(.imul, .i32, r(a), r(b)));
            },
            op("v_bfe_u32"), op("v_bfe_i32") => {
                const ty: Ty = if (in.op == op("v_bfe_i32")) .i32 else .u32;
                // (offset and width are their low 5 bits: KIR's bfe masks
                // the offset and clamps the width)
                const wd = e.src(i, 2, .u32);
                const wm: Arg = switch (wd) {
                    .imm => |x| u(x & 31),
                    .reg => r(k.op2(.@"and", .u32, wd, u(31))),
                };
                e.setv(d, k.op3(.bfe, ty, e.src(i, 0, .u32), e.src(i, 1, .u32), wm));
            },
            op("v_bfm_b32") => {
                const ones = k.op2(.isub, .u32, r(k.op2(.shl, .u32, u(1), e.src(i, 0, .u32))), u(1));
                e.setv(d, k.op2(.shl, .u32, r(ones), e.src(i, 1, .u32)));
            },
            op("v_bfi_b32") => {
                const a = e.src(i, 0, .u32);
                const x = k.op2(.@"and", .u32, a, e.src(i, 1, .u32));
                const y = k.op2(.@"and", .u32, r(k.op1(.not, .u32, a)), e.src(i, 2, .u32));
                e.setv(d, k.op2(.@"or", .u32, r(x), r(y)));
            },
            op("v_lshl_add_u32") => e.setv(d, k.op2(.iadd, .u32, r(k.op2(.shl, .u32, e.src(i, 0, .u32), e.src(i, 1, .u32))), e.src(i, 2, .u32))),
            op("v_lshl_or_b32") => e.setv(d, k.op2(.@"or", .u32, r(k.op2(.shl, .u32, e.src(i, 0, .u32), e.src(i, 1, .u32))), e.src(i, 2, .u32))),
            op("v_and_or_b32") => e.setv(d, k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, e.src(i, 0, .u32), e.src(i, 1, .u32))), e.src(i, 2, .u32))),
            op("v_add3_u32") => e.setv(d, k.op2(.iadd, .u32, r(k.op2(.iadd, .u32, e.src(i, 0, .u32), e.src(i, 1, .u32))), e.src(i, 2, .u32))),
            // a carry out: a lane mask
            op("v_add_co_u32"), op("v_sub_co_u32"), op("v_subrev_co_u32") => {
                var a = e.src(i, 0, .u32);
                var b = e.src(i, 1, .u32);
                if (in.op == op("v_subrev_co_u32")) std.mem.swap(Arg, &a, &b);
                if (in.op == op("v_add_co_u32")) {
                    const s = k.op2(.iadd, .u32, a, b);
                    e.setMask(in.sdst, k.cmp(.u32, .lt, r(s), a));
                    e.setv(d, s);
                } else {
                    const s = k.op2(.isub, .u32, a, b);
                    e.setMask(in.sdst, k.cmp(.u32, .lt, a, b));
                    e.setv(d, s);
                }
            },
            op("v_cndmask_b32") => {
                const mods = ((in.neg | in.abs) & 3) != 0;
                const ty: Ty = if (mods) .f32 else .u32;
                e.setv(d, k.sel(ty, e.mask(i, 2), e.src(i, 1, ty), e.src(i, 0, ty)));
            },
            else => unreachable, // (analyse kept only these)
        }
    }

    fn fop2(e: *Emit, i: u16, kop: kir.Op, swap: bool) void {
        const in = &e.p.insts[i];
        var a = e.src(i, 0, .f32);
        var b = e.src(i, 1, .f32);
        if (swap) std.mem.swap(Arg, &a, &b);
        e.setv(in.dst - gfx10.VGPR0, e.fres(in, e.k.op2(kop, .f32, a, b)));
    }

    fn fop1(e: *Emit, i: u16, kop: kir.Op) void {
        const in = &e.p.insts[i];
        e.setv(in.dst - gfx10.VGPR0, e.fres(in, e.k.op1(kop, .f32, e.src(i, 0, .f32))));
    }

    fn iop2(e: *Emit, i: u16, kop: kir.Op, ty: Ty, swap: bool) void {
        const in = &e.p.insts[i];
        var a = e.src(i, 0, .u32);
        var b = e.src(i, 1, .u32);
        if (swap) std.mem.swap(Arg, &a, &b);
        e.setv(in.dst - gfx10.VGPR0, e.k.op2(kop, ty, a, b));
    }

    /// An f32 as f16 bits rounded toward zero, in a u32's low half.
    fn half(e: *Emit, x: Arg) V {
        const k = e.k;
        const h = k.cvt(.f32, .f16, .rz, x);
        return k.op2(.@"and", .u32, r(k.mov(.u32, r(h))), u(0xffff));
    }

    /// The f16 in the low half of `x` as an f32.
    fn unhalf(e: *Emit, x: Arg) V {
        const k = e.k;
        const lo = k.op2(.@"and", .u32, x, u(0xffff));
        return k.cvt(.f16, .f32, .rne, r(k.mov(.f16, r(lo))));
    }

    fn compare(e: *Emit, i: u16) void {
        const in = &e.p.insts[i];
        const k = e.k;
        const name = in.d().name; // v_cmp_<cc>_<type>
        const rest = name["v_cmp_".len..];
        const us = std.mem.lastIndexOfScalar(u8, rest, '_').?;
        const cc = rest[0..us];
        const tn = rest[us + 1 ..];
        const eq = std.mem.eql;
        var p: V = undefined;
        if (eq(u8, tn, "f32")) {
            const a = e.src(i, 0, .f32);
            const b = e.src(i, 1, .f32);
            const C = kir.Cmp;
            const one = struct {
                fn c(kk: *kir.Kernel, x: Arg, y: Arg, cmp: C) V {
                    return kk.cmp(.f32, cmp, x, y);
                }
            }.c;
            // (KIR's fcmp is ordered: a NaN makes every compare false
            // except ne, which is the unordered "not equal")
            if (eq(u8, cc, "lt")) p = one(k, a, b, .lt) else if (eq(u8, cc, "eq")) p = one(k, a, b, .eq) else if (eq(u8, cc, "le")) p = one(k, a, b, .le) else if (eq(u8, cc, "gt")) p = one(k, a, b, .gt) else if (eq(u8, cc, "ge")) p = one(k, a, b, .ge) else if (eq(u8, cc, "neq")) p = one(k, a, b, .ne) else if (eq(u8, cc, "lg")) {
                p = k.op2(.por, .pred, r(one(k, a, b, .lt)), r(one(k, a, b, .gt)));
            } else if (eq(u8, cc, "o") or eq(u8, cc, "u")) {
                const o = k.op2(.pand, .pred, r(one(k, a, a, .eq)), r(one(k, b, b, .eq)));
                p = if (eq(u8, cc, "o")) o else k.op1(.pnot, .pred, r(o));
            } else if (eq(u8, cc, "nge")) p = k.op1(.pnot, .pred, r(one(k, a, b, .ge))) else if (eq(u8, cc, "ngt")) p = k.op1(.pnot, .pred, r(one(k, a, b, .gt))) else if (eq(u8, cc, "nle")) p = k.op1(.pnot, .pred, r(one(k, a, b, .le))) else if (eq(u8, cc, "nlt")) p = k.op1(.pnot, .pred, r(one(k, a, b, .lt))) else if (eq(u8, cc, "nlg")) {
                p = k.op1(.pnot, .pred, r(k.op2(.por, .pred, r(one(k, a, b, .lt)), r(one(k, a, b, .gt)))));
            } else if (eq(u8, cc, "tru")) p = k.mov(.pred, u(1)) else p = k.mov(.pred, u(0));
        } else {
            const ty: Ty = if (eq(u8, tn, "i32")) .i32 else .u32;
            const a = e.src(i, 0, .u32);
            const b = e.src(i, 1, .u32);
            const c: ?kir.Cmp = if (eq(u8, cc, "lt")) .lt else if (eq(u8, cc, "eq")) .eq else if (eq(u8, cc, "le")) .le else if (eq(u8, cc, "gt")) .gt else if (eq(u8, cc, "ne")) .ne else if (eq(u8, cc, "ge")) .ge else null;
            p = if (c) |cv| k.cmp(ty, cv, a, b) else k.mov(.pred, u(@intFromBool(eq(u8, cc, "t"))));
        }
        e.setMask(in.sdst, p);
    }

    // ── interpolation and exports ──

    fn interp(e: *Emit, in: *const Instr) void {
        const k = e.k;
        const io = e.fio.?;
        const d: usize = in.dst - gfx10.VGPR0;
        const pin = e.lay.inputs[in.attr];
        // (p1 and p2 both give the engine's interpolated value: the raster
        // already did what the pair of them does; mov p0 gives the same
        // varying, which checkPixel made sure is flat, by Shaders.flat)
        if (pin.slot) |s| {
            const w = 4 * @as(usize, s) + in.chan;
            if (w < raster.MAX_VARYINGS and io.varying[w] != .none) {
                e.setv(d, io.varying[w]);
                return;
            }
            e.setv(d, k.mov(.f32, f(0)));
            return;
        }
        e.setv(d, k.mov(.f32, f(pin.defaultValue()[in.chan])));
    }

    fn exportOf(e: *Emit, in: *const Instr) void {
        const k = e.k;
        if (e.vio) |io| {
            if (in.target == 12) {
                for (0..4) |c| {
                    io.position[c] = if ((in.en >> @intCast(c)) & 1 != 0) e.reg(e.vreg(in.vsrc[c], .f32), .f32) else k.mov(.f32, f(if (c == 3) 1 else 0));
                }
            } else {
                const n = in.target - 32;
                for (0..4) |c| {
                    const w = 4 * @as(usize, n) + c;
                    if (w >= raster.MAX_VARYINGS) continue;
                    io.varying[w] = if ((in.en >> @intCast(c)) & 1 != 0) e.reg(e.vreg(in.vsrc[c], .f32), .f32) else k.mov(.f32, f(0));
                }
            }
            return;
        }
        const io = e.fio.?;
        if (in.target == 8) {
            if (e.lay.depth_export and (in.en & 1) != 0) io.depth = e.reg(e.vreg(in.vsrc[0], .f32), .f32);
            return;
        }
        const t = in.target;
        const cf: u4 = @truncate(e.lay.setup.color_formats >> @intCast(4 * @as(u32, t)));
        if (cf == 0) return; // (ZERO: the target takes nothing)
        var col: [4]V = undefined;
        if (in.compr) {
            // two words, two f16 each: (r, g) and (b, a)
            for (0..2) |w| {
                const on = (in.en >> @intCast(2 * w)) & 3 != 0;
                const x = e.vreg(in.vsrc[w], .u32);
                col[2 * w] = if (on) e.unhalf(x) else k.mov(.f32, f(0));
                col[2 * w + 1] = if (on) e.unhalf(r(k.op2(.shr, .u32, x, u(16)))) else k.mov(.f32, f(if (w == 1) 1 else 0));
            }
        } else {
            var x: [4]V = undefined;
            for (0..4) |c| {
                x[c] = if ((in.en >> @intCast(c)) & 1 != 0) e.reg(e.vreg(in.vsrc[c], .f32), .f32) else k.mov(.f32, f(if (c == 3) 1 else 0));
            }
            const zero = k.mov(.f32, f(0));
            const one = k.mov(.f32, f(1));
            col = switch (cf) {
                1 => .{ x[0], zero, zero, one }, // 32_R
                2 => .{ x[0], x[1], zero, one }, // 32_GR
                3 => .{ x[0], zero, zero, x[1] }, // 32_AR: alpha in the export's second word
                else => x, // 32_ABGR
            };
        }
        if (t == 0 and e.lay.srgb) {
            for (0..3) |c| col[c] = srgbEncode(k, col[c]);
        }
        if (t == 0) io.color = col else io.colors[t] = col;
    }

    // ── buffer loads ──

    fn bufferLoad(e: *Emit, i: u16) void {
        const k = e.k;
        const p = e.p;
        const in = &p.insts[i];
        const s = p.site[i];
        const st = p.sites[s];
        const d: usize = in.dst - gfx10.VGPR0;
        const win = e.ev.window_of[s];
        // what is loaded: dwords, or a format's element
        var fmt: ?rc.Format = null;
        var n: usize = 1;
        var width: u8 = 32; // a raw load's access
        var signed = false;
        switch (st.kind) {
            .raw => switch (in.op) {
                op("buffer_load_dwordx2") => n = 2,
                op("buffer_load_dwordx3") => n = 3,
                op("buffer_load_dwordx4") => n = 4,
                op("buffer_load_ubyte") => width = 8,
                op("buffer_load_sbyte") => {
                    width = 8;
                    signed = true;
                },
                op("buffer_load_ushort") => width = 16,
                op("buffer_load_sshort") => {
                    width = 16;
                    signed = true;
                },
                else => {},
            },
            .format, .tformat => {
                n = switch (in.op) {
                    op("buffer_load_format_xy"), op("tbuffer_load_format_xy") => 2,
                    op("buffer_load_format_xyz"), op("tbuffer_load_format_xyz") => 3,
                    op("buffer_load_format_xyzw"), op("tbuffer_load_format_xyzw") => 4,
                    else => 1,
                };
                fmt = rc.formatOf(e.ev.format[s]);
            },
        }
        const sel = e.ev.dst_sel[s];
        if (win == rc.NO_WINDOW or (st.kind != .raw and fmt == null)) {
            // (no memory: every load out of range; a format load's "one"
            // channel is 1 all the same)
            for (0..n) |c| {
                const one = st.kind != .raw and selOf(sel, c) == 1;
                e.setv(d + c, if (one) oneOf(k, fmt) else k.mov(.u32, u(0)));
            }
            return;
        }
        const bind = e.buf + e.lay.buffer_base + win;
        // the byte offset: index * stride + the lane's offset, the
        // instruction's and soffset
        const w = p.siteWord(s);
        const stride = e.word(w);
        const records = e.word(w + 1);
        const bytes = e.word(w + 2);
        const va: usize = if (in.src[0] >= gfx10.VGPR0) in.src[0] - gfx10.VGPR0 else 0;
        const idx: Arg = if (in.idxen) e.vreg(va, .u32) else u(0);
        const voff: Arg = if (in.offen) e.vreg(va + @intFromBool(in.idxen), .u32) else u(0);
        const soff: Arg = if (p.slot[i][2] != rc.NO_SLOT) r(e.word(p.slot[i][2])) else u(constBits(in.src[2], in.lit, .u32));
        var off = k.op3(.imad, .u32, idx, r(stride), voff);
        off = k.op2(.iadd, .u32, r(off), u(in.imm));
        off = k.op2(.iadd, .u32, r(off), soff);
        // the accesses: a format's element whole (all or nothing), a raw
        // load's dwords each on its own
        var eb: u32 = 0;
        var acc: u8 = 32;
        var nacc: usize = 0;
        if (fmt) |ft| {
            eb = @as(u32, ft.bits) / 8 * ft.comps;
            acc = if (eb >= 4) 32 else @intCast(8 * eb);
            nacc = if (eb >= 4) eb / 4 else 1;
        } else {
            acc = width;
            eb = if (width == 32) 4 * @as(u32, @intCast(n)) else width / 8;
            nacc = if (width == 32) n else 1;
        }
        const al: u32 = @as(u32, acc) / 8;
        const aoff = k.op2(.@"and", .u32, r(off), u(~(al - 1)));
        // In range: two conditions, both needed. The bytes: what is read
        // lies inside the window (bytes >= need and the offset at most
        // bytes - need: no sum that could wrap). The record: indexed with
        // a stride, the index is below the record count (index * stride
        // wraps at 2^32, so the bytes alone do not tell).
        const rec: ?V = if (in.idxen) k.op2(.por, .pred, r(k.cmp(.u32, .lt, idx, r(records))), r(k.cmp(.u32, .eq, r(stride), u(0)))) else null;
        var raw: [4]V = undefined;
        for (0..nacc) |j| {
            const need: u32 = if (fmt == null and width == 32) 4 * @as(u32, @intCast(j + 1)) else eb;
            var inb = k.op2(.pand, .pred, r(k.cmp(.u32, .ge, r(bytes), u(need))), r(k.cmp(.u32, .le, r(aoff), r(k.op2(.isub, .u32, r(bytes), u(need))))));
            if (rec) |rv| inb = k.op2(.pand, .pred, r(inb), r(rv));
            raw[j] = k.reg(.u32);
            k.set(raw[j], .mov, u(0), no, no);
            k.ifp(r(inb));
            var m = kir.global(bind, acc);
            m.imm = @intCast(4 * j);
            const x = k.load(.u32, m, r(aoff));
            k.set(raw[j], .mov, r(x), no, no);
            k.endif();
        }
        if (fmt) |ft| {
            // (out of range the element reads 0, and a "one" channel is 1:
            // the hardware's exact rule for "one" out of range is not
            // established; 1 is what it gives in range)
            for (0..n) |c| {
                const code = selOf(sel, c);
                const v: V = switch (code) {
                    1 => oneOf(k, ft),
                    4...7 => e.component(raw, ft, code - 4),
                    else => k.mov(.u32, u(0)),
                };
                e.setv(d + c, v);
            }
        } else if (width == 32) {
            for (0..n) |c| e.setv(d + c, raw[c]);
        } else {
            const ty: Ty = if (signed) .i32 else .u32;
            e.setv(d, k.op3(.bfe, ty, r(raw[0]), u(0), u(width)));
        }
    }

    /// Component `c` of an element as its format converts it (a missing
    /// component: 0, or 1 for w).
    fn component(e: *Emit, raw: [4]V, ft: rc.Format, c: u3) V {
        const k = e.k;
        if (c >= ft.comps) {
            if (c == 3) return oneOf(k, ft);
            return k.mov(.u32, u(0));
        }
        if (ft.bits == 32) return switch (ft.nfmt) {
            .float => k.mov(.f32, r(raw[c])),
            else => raw[c],
        };
        const at: u32 = @as(u32, c) * ft.bits;
        const wv = raw[at / 32];
        const sh = at % 32;
        const bits: u32 = ft.bits;
        const ux = k.op3(.bfe, .u32, r(wv), u(sh), u(bits));
        const sx = k.op3(.bfe, .i32, r(wv), u(sh), u(bits));
        const umax: f32 = @floatFromInt((@as(u32, 1) << @intCast(bits)) - 1);
        const smax: f32 = @floatFromInt((@as(u32, 1) << @intCast(bits - 1)) - 1);
        return switch (ft.nfmt) {
            .unorm => k.div(r(k.cvt(.u32, .f32, .rne, r(ux))), f(umax)),
            .snorm => k.op2(.fmax, .f32, r(k.div(r(k.cvt(.i32, .f32, .rne, r(sx))), f(smax))), f(-1)),
            .uscaled => k.cvt(.u32, .f32, .rne, r(ux)),
            .sscaled => k.cvt(.i32, .f32, .rne, r(sx)),
            .uint => ux,
            .sint => sx,
            .float => e.unhalf(r(ux)),
        };
    }
};

fn intFormat(ft: rc.Format) bool {
    return ft.nfmt == .uint or ft.nfmt == .sint;
}

/// A V#'s dst_sel code for channel `c`.
fn selOf(sel: u16, c: usize) u3 {
    return @truncate(sel >> @intCast(3 * c));
}

/// 1 in a format's kind: the integer for uint and sint, else 1.0 (and
/// 1.0 for no format).
fn oneOf(k: *kir.Kernel, ft: ?rc.Format) V {
    const int = if (ft) |x| intFormat(x) else false;
    return k.mov(if (int) .u32 else .f32, u(if (int) 1 else F_ONE));
}

/// A linear value encoded as sRGB: 12.92 x up to 0.0031308, else
/// 1.055 x^(1/2.4) - 0.055 (the power as exp2(log2(x) / 2.4)). Against
/// the exact formula in f64, over 4096 values across 0..1 in KIR's
/// interpreter, the worst error measured is 1.43e-7 (the sweep in
/// recompile_test.sig checks 1e-6): far below a unorm8 step (3.9e-3). A GPU's
/// approximate flog2 and fexp2 may add their own error (docs/GPU.md).
pub fn srgbEncode(k: *kir.Kernel, x: V) V {
    const lin = k.op2(.fmul, .f32, r(x), f(12.92));
    const p = k.op1(.fexp2, .f32, r(k.op2(.fmul, .f32, r(k.op1(.flog2, .f32, r(x))), f(1.0 / 2.4))));
    const g = k.op2(.fsub, .f32, r(k.op2(.fmul, .f32, r(p), f(1.055))), f(0.055));
    return k.sel(.f32, r(k.cmp(.f32, .le, r(x), f(0.0031308))), r(lin), r(g));
}

/// An inline constant's or the literal's bits as an operand of type `ty`.
fn constBits(code: u16, lit: u32, ty: Ty) u32 {
    const t: gfx10.Ty = if (ty == .f32) .f32 else .b32;
    const v = gfx10.constValue(code, lit, t) orelse 0;
    return @truncate(v);
}

pub fn vertex(p: *const rc.Program, ev: *const rc.Evaluation, lay: rc.Layout, k: *kir.Kernel, io: *raster.VertexIO) void {
    var e = Emit{ .p = p, .ev = ev, .lay = lay, .k = k, .uni = io.uniforms, .buf = io.buffers, .vio = io };
    // v5: the vertex index, v8: the instance index (the base vertex and
    // first instance words added)
    e.vg[5] = k.op2(.iadd, .u32, r(io.vertex_id), r(e.word(lay.base_vertex_word)));
    e.vg[8] = k.op2(.iadd, .u32, r(io.instance_id), r(e.word(lay.first_instance_word)));
    e.run();
    // (the varyings the code does not export are 0)
    for (0..4) |c| {
        if (io.position[c] == .none) io.position[c] = k.mov(.f32, f(if (c == 3) 1 else 0));
    }
    for (0..@min(lay.varyings, raster.MAX_VARYINGS)) |j| {
        if (io.varying[j] == .none) io.varying[j] = k.mov(.f32, f(0));
    }
}

pub fn fragment(p: *const rc.Program, ev: *const rc.Evaluation, lay: rc.Layout, k: *kir.Kernel, io: *raster.FragmentIO) void {
    var e = Emit{ .p = p, .ev = ev, .lay = lay, .k = k, .uni = io.uniforms, .buf = io.buffers, .fio = io };
    const B = state.BUILTIN;
    var kind: u5 = 0;
    while (kind < 16) : (kind += 1) {
        const at = state.builtinRegister(lay.setup, @intCast(kind)) orelse continue;
        const fc = io.frag_coord;
        // (the console's y counts from the top: the target's height less
        // the engine's, which counts from the bottom)
        const top_y = if (kind == B.POS_Y or kind == B.POS_FIXED) k.op2(.fsub, .f32, e.as(e.word(lay.height_word), .f32), r(fc[1])) else V.none;
        switch (kind) {
            // (the barycentric pairs: only v_interp_* read them, and they
            // take the engine's interpolated value instead)
            B.POS_X => e.vg[at] = fc[0],
            B.POS_Y => e.vg[at] = top_y,
            B.POS_Z => e.vg[at] = fc[2],
            // (the engine has 1/w; the PS5 hands w itself)
            B.POS_W => e.vg[at] = k.div(f(1), r(fc[3])),
            B.FRONT_FACE => e.vg[at] = if (io.front_facing == .none) k.mov(.f32, f(1)) else k.sel(.f32, r(io.front_facing), f(1), f(-1)),
            B.SAMPLE_COVERAGE => e.vg[at] = k.mov(.u32, u(1)),
            B.POS_FIXED => {
                const x = k.cvt(.f32, .u32, .rz, r(k.op1(.ffloor, .f32, r(fc[0]))));
                const y = k.cvt(.f32, .u32, .rz, r(k.op1(.ffloor, .f32, r(top_y))));
                e.vg[at] = k.op2(.@"or", .u32, r(x), r(k.op2(.shl, .u32, r(y), u(16))));
            },
            else => {},
        }
    }
    e.run();
    for (0..4) |c| {
        if (io.color[c] == .none) io.color[c] = k.mov(.f32, f(if (c == 3) 1 else 0));
    }
}
