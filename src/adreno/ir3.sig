//! @zpm/adreno ir3 — the Adreno shader instruction set of the a6xx and a7xx
//! generations (the Surface Laptop 13's X1-45 is a7xx gen 2), as 64-bit
//! instruction words.
//!
//! Every form is a pattern of fixed bits plus fields, written down from
//! Mesa's isaspec description (src/freedreno/isa/ir3-cat*.xml, used as
//! documentation only): the same bit positions, the same display text. So
//! an instruction can be encoded, decoded back, printed the way Mesa's
//! disassembler prints it and parsed from that text, and tests compare all
//! four against Mesa's disassembler vectors (tests/data/ir3_disasm_vectors.txt).
//!
//! Allocation-free: instructions are plain values, text goes into caller
//! buffers. Of the texture (cat5) instructions only `sam` with
//! immediate sampler and texture slots is here (what fragment programs
//! use); the a8xx-only forms are not.

const std = @import("std");

pub const Error = error{
    /// No form of this instruction exists for the generation, or the
    /// operands do not fit any form.
    NoForm,
    /// A field does not fit its bits.
    OutOfRange,
    /// The 64-bit word matches no form (or more than one).
    NoMatch,
    /// Text that is not an instruction this module knows.
    Syntax,
    /// A caller buffer is too small.
    BufferTooSmall,
};

/// Generations as Mesa's isaspec numbers them.
pub const A6XX: u16 = 600;
pub const A7XX: u16 = 700;

// ── Enumerations ────────────────────────────────────────────────────────────

pub const Type = enum(u3) {
    f16 = 0,
    f32 = 1,
    u16 = 2,
    u32 = 3,
    s16 = 4,
    s32 = 5,
    u8 = 6,
    u8_32 = 7,

    /// Whether a load destination / store source of this type is a half
    /// register (Mesa's #type-half).
    pub fn half(t: Type) bool {
        return switch (t) {
            .f16, .u16, .s16, .u8 => true,
            else => false,
        };
    }

    /// cat1's notion: type 7 (an 8-bit signed source) is half too.
    pub fn halfCat1(t: Type) bool {
        return t.half() or t == .u8_32;
    }
};

pub const Cond = enum(u3) { lt = 0, le = 1, gt = 2, ge = 3, eq = 4, ne = 5 };
pub const Round = enum(u2) { none = 0, even = 1, pos_infinity = 2, neg_infinity = 3 };
pub const Mode = enum(u2) { imm = 0, uniform = 1, nonuniform = 2 };
pub const Shfl = enum(u3) { xor = 1, up = 2, down = 3, rup = 6, rdown = 7 };

/// The flut (float lookup table) immediates of cat2/cat4 sources.
pub const flut_names = [_][]const u8{ "0.0", "0.5", "1.0", "2.0", "e", "pi", "1/pi", "1/log2(e)", "log2(e)", "1/log2(10)", "log2(10)", "4.0" };

/// Register numbers are Mesa's: (index << 2) | component.
pub const A0_X: u16 = 61 << 2;
pub const A1_X: u16 = (61 << 2) | 1;
pub const P0_X: u16 = 62 << 2;
/// r48.x and above are the shared (per-wave uniform) registers.
pub const SHARED_BASE: u16 = 48 << 2;

pub fn reg(index: u16, component: u2) u16 {
    return (index << 2) | component;
}

// ── Opcodes ─────────────────────────────────────────────────────────────────

pub const Op = enum(u8) {
    // cat0
    nop,
    end,
    ret,
    emit,
    cut,
    chmask,
    chsh,
    flow_rev,
    shpe,
    predt,
    predf,
    prede,
    kill,
    jump,
    call,
    bkt,
    getone,
    shps,
    getlast,
    brac,
    brax,
    br,
    bany,
    ball,
    brao,
    braa,
    // cat1
    mov,
    movs,
    swz,
    gat,
    sct,
    movmsk,
    // cat2
    add_f,
    min_f,
    max_f,
    mul_f,
    sign_f,
    cmps_f,
    absneg_f,
    cmpv_f,
    floor_f,
    ceil_f,
    rndne_f,
    rndaz_f,
    trunc_f,
    add_u,
    add_s,
    sub_u,
    sub_s,
    cmps_u,
    cmps_s,
    min_u,
    min_s,
    max_u,
    max_s,
    absneg_s,
    and_b,
    or_b,
    not_b,
    xor_b,
    cmpv_u,
    cmpv_s,
    mul_f_mul2,
    add_f_mul2,
    mul_f_div2,
    add_f_div2,
    mul_u24,
    mul_s24,
    mull_u,
    bfrev_b,
    clz_s,
    clz_b,
    shl_b,
    shr_b,
    ashr_b,
    mgen_b,
    getbit_b,
    setrm,
    cbits_b,
    shb,
    msad,
    bary_f,
    flat_b,
    // cat3
    mad_u16,
    madsh_u16,
    mad_s16,
    madsh_m16,
    mad_u24,
    mad_s24,
    mad_f16,
    mad_f32,
    sel_b16,
    sel_b32,
    sel_s16,
    sel_s32,
    sel_f16,
    sel_f32,
    sad_s16,
    sad_s32,
    mad_f16_mul2,
    mad_f32_mul2,
    mad_f16_div2,
    mad_f32_div2,
    shrm,
    shlm,
    shrg,
    shlg,
    andg,
    dp2acc,
    dp4acc,
    wmm,
    wmm_accu,
    // cat4
    rcp,
    rsq,
    log2,
    exp2,
    sin,
    cos,
    sqrt,
    hrsq,
    hlog2,
    hexp2,
    // cat5
    sam,
    // cat6
    ldg,
    ldg_a,
    ldg_k,
    stg,
    stg_a,
    ldl,
    ldp,
    ldlw,
    ldlv,
    stl,
    stp,
    stlw,
    stc,
    stsc,
    ldc,
    ldc_k,
    getspid,
    getwid,
    getfiberid,
    resinfo_b,
    resbase,
    ldib_b,
    stib_b,
    atomic_b_add,
    atomic_b_sub,
    atomic_b_xchg,
    atomic_b_cmpxchg,
    atomic_b_min,
    atomic_b_max,
    atomic_b_and,
    atomic_b_or,
    atomic_b_xor,
    atomic_g_add,
    atomic_g_sub,
    atomic_g_xchg,
    atomic_g_inc,
    atomic_g_dec,
    atomic_g_cmpxchg,
    atomic_g_min,
    atomic_g_max,
    atomic_g_and,
    atomic_g_or,
    atomic_g_xor,
    atomic_add,
    atomic_sub,
    atomic_xchg,
    atomic_inc,
    atomic_dec,
    atomic_cmpxchg,
    atomic_min,
    atomic_max,
    atomic_and,
    atomic_or,
    atomic_xor,
    shfl,
    // cat7
    bar,
    fence,
    sleep,
    icinv,
    dccln,
    dcinv,
    dcflu,
    ccinv,
    lock,
    unlock,

    /// Mesa's spelling ("add.f", "atomic.b.add", "flow_rev").
    pub fn name(op: Op) []const u8 {
        return switch (op) {
            inline else => |o| comptime dotted(@tagName(o)),
        };
    }

    pub fn category(op: Op) u3 {
        const v = @intFromEnum(op);
        if (v <= @intFromEnum(Op.braa)) return 0;
        if (v <= @intFromEnum(Op.movmsk)) return 1;
        if (v <= @intFromEnum(Op.flat_b)) return 2;
        if (v <= @intFromEnum(Op.wmm_accu)) return 3;
        if (v <= @intFromEnum(Op.hexp2)) return 4;
        if (v <= @intFromEnum(Op.sam)) return 5;
        if (v <= @intFromEnum(Op.shfl)) return 6;
        return 7;
    }
};

fn dotted(comptime s: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        if (std.mem.eql(u8, s, "flow_rev")) return s;
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = if (c == '_') '.' else c;
        const final = out;
        return &final;
    }
}

// ── Instructions ────────────────────────────────────────────────────────────

pub const Src = struct {
    kind: Kind = .none,
    /// GPR or const register number ((index << 2) | component).
    num: u16 = 0,
    /// Offset from a0.x (relative sources).
    off: i16 = 0,
    /// Immediate bits (the raw float bits for float immediates; the table
    /// index for flut immediates).
    imm: u32 = 0,
    half: bool = false,
    neg: bool = false,
    abs: bool = false,
    bnot: bool = false,
    /// (r): the register advances with (rptN).
    r: bool = false,
    /// (last): the last read of this register (a scheduling hint, a7xx).
    last: bool = false,

    pub const Kind = enum(u8) { none, gpr, cnst, imm, flut, rel_gpr, rel_cnst };

    pub fn gpr(num: u16) Src {
        return .{ .kind = .gpr, .num = num };
    }
    pub fn hgpr(num: u16) Src {
        return .{ .kind = .gpr, .num = num, .half = true };
    }
    pub fn cnst(num: u16) Src {
        return .{ .kind = .cnst, .num = num };
    }
    pub fn immed(v: u32) Src {
        return .{ .kind = .imm, .imm = v };
    }
    pub fn immf(v: f32) Src {
        return .{ .kind = .imm, .imm = @bitCast(v) };
    }
};

pub const Dst = struct {
    /// Register number, or the offset from a0.x when `rel`.
    num: u16 = 0,
    half: bool = false,
    rel: bool = false,
    /// (ei): end of inputs (cat2).
    ei: bool = false,
};

pub const Instr = struct {
    op: Op = .nop,
    // Synchronisation and scheduling.
    sy: bool = false,
    ss: bool = false,
    jp: bool = false,
    ul: bool = false,
    eq: bool = false,
    eolm: bool = false,
    eogm: bool = false,
    eostsc: bool = false,
    sat: bool = false,
    /// (rptN): repeated on the following registers.
    repeat: u8 = 0,
    /// (nopN): N cycles of delay after a cat2/cat3 instruction.
    nop: u8 = 0,
    dst: Dst = .{},
    /// swz/sct's further destinations.
    dsts: [3]u16 = .{ 0, 0, 0 },
    src: [4]Src = .{ Src{}, Src{}, Src{}, Src{} },
    // cat0
    /// Branch target (relative, in instructions) or other immediate.
    imm: i32 = 0,
    inv1: bool = false,
    comp1: u2 = 0,
    inv2: bool = false,
    comp2: u2 = 0,
    index: u8 = 0,
    // cat1
    src_type: Type = .f32,
    dst_type: Type = .f32,
    round: Round = .none,
    /// mova/mova1's .u.
    u: bool = false,
    // cat2
    cond: Cond = .lt,
    // cat3 dp2acc/dp4acc
    mixed: bool = false,
    high: bool = false,
    // cat6
    ty: Type = .u32,
    /// Immediate offset (bytes for global access; const index for stc).
    off: i32 = 0,
    /// Components / dwords / vec4s.
    size: u32 = 0,
    /// a6xx ldg.a/stg.a's source shift.
    shift: u8 = 0,
    d: u8 = 1,
    typed: bool = false,
    type_size: u8 = 1,
    mode: Mode = .imm,
    base: u8 = 0,
    bindless: bool = false,
    rck: bool = false,
    has_offset: bool = false,
    /// const destination through a1.x (stc, ldg.k).
    a1: bool = false,
    shfl: Shfl = .xor,
    // cat7
    g: bool = false,
    l: bool = false,
    r: bool = false,
    w: bool = false,
    /// sleep.l / dccln.all.
    long: bool = false,
    // cat5
    /// The components written (x = 1 .. w = 8).
    wrmask: u4 = 0xf,
    /// Sampler and texture slots (s#N, t#N).
    samp: u4 = 0,
    tex: u7 = 0,
};

// ── Forms (pattern tables) ──────────────────────────────────────────────────

const Layout = enum(u8) {
    c0_0src,
    c0_1src,
    c0_immed,
    c0_getlast,
    c0_brac,
    c0_brax,
    c0_br1,
    c0_br2,
    c1_imm,
    c1_const,
    c1_gpr,
    c1_relgpr,
    c1_relconst,
    c1_movs_imm,
    c1_movs_a0,
    c1_swz,
    c1_gat,
    c1_sct,
    c1_movmsk,
    c2_1src,
    c2_2src,
    c2_cond,
    c2_input,
    c3,
    c3_alt,
    c3_dp,
    c3_wmm,
    c4,
    c5_tex,
    c6_ldg,
    c6_ldg_a6,
    c6_ldg_a7,
    c6_ldg_k,
    c6_stg,
    c6_stg_a6,
    c6_stg_a7,
    c6_ld,
    c6_ldlv,
    c6_st,
    c6_stc,
    c6_stsc,
    c6_ldc,
    c6_ldc_k,
    c6_getid,
    c6_ibo1src,
    c6_ibo_ls,
    c6_ibo_atomic,
    c6_atomic_g,
    c6_atomic_l,
    c6_shfl,
    c7_barrier,
    c7_data,
    c7_sleep,
    c7_plain,
};

const Form = struct {
    op: Op,
    layout: Layout,
    mask: u64,
    match: u64,
    gmin: u16 = 0,
    gmax: u16 = 0xffff,
};

const Pat = struct { lo: u6, hi: u6, s: []const u8 };

fn p(lo: u6, hi: u6, s: []const u8) Pat {
    return .{ .lo = lo, .hi = hi, .s = s };
}

fn mm(comptime pats: []const Pat) [2]u64 {
    comptime {
        @setEvalBranchQuota(100_000);
        var mask: u64 = 0;
        var match: u64 = 0;
        for (pats) |q| {
            if (q.s.len != @as(usize, q.hi) - q.lo + 1) @compileError("pattern width");
            for (q.s, 0..) |c, i| {
                const bit: u64 = @as(u64, 1) << @intCast(@as(usize, q.hi) - i);
                switch (c) {
                    '0' => mask |= bit,
                    '1' => {
                        mask |= bit;
                        match |= bit;
                    },
                    'x' => {},
                    else => @compileError("pattern char"),
                }
            }
        }
        return .{ mask, match };
    }
}

fn f(comptime op: Op, comptime layout: Layout, comptime pats: []const Pat) Form {
    const m = mm(pats);
    return .{ .op = op, .layout = layout, .mask = m[0], .match = m[1] };
}

fn fg(comptime op: Op, comptime layout: Layout, comptime pats: []const Pat, comptime gmin: u16, comptime gmax: u16) Form {
    var r = f(op, layout, pats);
    r.gmin = gmin;
    r.gmax = gmax;
    return r;
}

const C0 = [_]Pat{p(61, 63, "000")};
const C0_0 = C0 ++ [_]Pat{ p(35, 36, "00"), p(37, 39, "000"), p(45, 47, "000"), p(52, 54, "000") };
const C0_BR = C0 ++ [_]Pat{ p(49, 49, "0"), p(55, 58, "0001") };
const C1 = [_]Pat{p(61, 63, "001")};
const C1_MOV = C1 ++ [_]Pat{p(57, 58, "00")};
const C1_MULTI = C1 ++ [_]Pat{ p(43, 43, "0"), p(49, 49, "0"), p(53, 54, "00"), p(57, 58, "10") };
const C2 = [_]Pat{p(61, 63, "010")};
const C3 = [_]Pat{p(61, 63, "011")};
const C4 = [_]Pat{p(61, 63, "100")};
const C6 = [_]Pat{p(61, 63, "110")};
const C6_A6 = C6 ++ [_]Pat{ p(4, 5, "00"), p(54, 58, "00000"), p(40, 40, "0") };
const C6_IBO = C6 ++ [_]Pat{p(20, 22, "110")};
const C6_GATOM = C6 ++ [_]Pat{ p(0, 0, "1"), p(1, 8, "00000000"), p(41, 48, "00000000"), p(52, 52, "1"), p(53, 53, "0") };
const C6_LATOM = C6 ++ [_]Pat{ p(0, 0, "1"), p(1, 8, "00000000"), p(41, 48, "00000000"), p(52, 52, "0"), p(53, 53, "0") };
const C7 = [_]Pat{p(61, 63, "111")};
const C7_BAR = C7 ++ [_]Pat{p(49, 49, "1")};

fn c0x(comptime op: Op, comptime hi: []const u8, comptime opc: []const u8) Form {
    return f(op, .c0_0src, &(C0_0 ++ [_]Pat{ p(49, 49, hi), p(55, 58, opc) }));
}
fn c0i(comptime op: Op, comptime hi: []const u8, comptime opc: []const u8) Form {
    return f(op, .c0_immed, &(C0 ++ [_]Pat{ p(49, 49, hi), p(55, 58, opc) }));
}
fn c2(comptime op: Op, comptime layout: Layout, comptime opc: []const u8) Form {
    return f(op, layout, &(C2 ++ [_]Pat{p(53, 58, opc)}));
}
fn c2g(comptime op: Op, comptime layout: Layout, comptime opc: []const u8, comptime gmin: u16) Form {
    return fg(op, layout, &(C2 ++ [_]Pat{p(53, 58, opc)}), gmin, 0xffff);
}
fn c3(comptime op: Op, comptime opc: []const u8) Form {
    return f(op, .c3, &(C3 ++ [_]Pat{ p(13, 13, "0"), p(55, 58, opc) }));
}
fn c3m(comptime op: Op, comptime opc: []const u8) Form {
    return fg(op, .c3, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(55, 58, opc) }), 700, 0xffff);
}
fn c3a(comptime op: Op, comptime opc: []const u8) Form {
    return fg(op, .c3_alt, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(55, 58, opc) }), 600, 0xffff);
}
fn c4(comptime op: Op, comptime opc: []const u8) Form {
    return f(op, .c4, &(C4 ++ [_]Pat{p(53, 58, opc)}));
}
fn c6ibo(comptime op: Op, comptime opc: []const u8) Form {
    return fg(op, .c6_ibo_atomic, &(C6_IBO ++ [_]Pat{ p(23, 23, "0"), p(4, 5, "00"), p(54, 58, "00000"), p(14, 19, opc), p(52, 53, "11") }), 600, 0xffff);
}
fn c6g(comptime op: Op, comptime opc: []const u8) Form {
    return fg(op, .c6_atomic_g, &(C6_GATOM ++ [_]Pat{p(54, 58, opc)}), 600, 0xffff);
}
fn c6l(comptime op: Op, comptime opc: []const u8) Form {
    return f(op, .c6_atomic_l, &(C6_LATOM ++ [_]Pat{p(54, 58, opc)}));
}
fn c7(comptime op: Op, comptime layout: Layout, comptime pats: []const Pat) Form {
    return f(op, layout, pats);
}

const forms = [_]Form{
    // cat0
    c0x(.nop, "0", "0000"),
    c0x(.end, "0", "0110"),
    c0x(.ret, "0", "0100"),
    c0x(.emit, "0", "0111"),
    c0x(.cut, "0", "1000"),
    c0x(.chmask, "0", "1001"),
    c0x(.chsh, "0", "1010"),
    c0x(.flow_rev, "0", "1011"),
    c0x(.shpe, "1", "1000"),
    c0x(.predt, "1", "1101"),
    c0x(.predf, "1", "1110"),
    c0x(.prede, "1", "1111"),
    f(.kill, .c0_1src, &(C0 ++ [_]Pat{ p(32, 36, "00000"), p(37, 39, "000"), p(45, 47, "000"), p(49, 49, "0"), p(55, 58, "0101") })),
    c0i(.jump, "0", "0010"),
    c0i(.call, "0", "0011"),
    c0i(.bkt, "1", "0000"),
    c0i(.getone, "1", "0101"),
    c0i(.shps, "1", "0111"),
    fg(.getlast, .c0_getlast, &(C0 ++ [_]Pat{ p(49, 49, "1"), p(55, 58, "0100") }), 600, 0xffff),
    f(.brac, .c0_brac, &(C0_BR ++ [_]Pat{p(37, 39, "011")})),
    f(.brax, .c0_brax, &(C0_BR ++ [_]Pat{p(37, 39, "110")})),
    f(.br, .c0_br1, &(C0_BR ++ [_]Pat{p(37, 39, "000")})),
    f(.bany, .c0_br1, &(C0_BR ++ [_]Pat{p(37, 39, "100")})),
    f(.ball, .c0_br1, &(C0_BR ++ [_]Pat{p(37, 39, "101")})),
    f(.brao, .c0_br2, &(C0_BR ++ [_]Pat{p(37, 39, "001")})),
    f(.braa, .c0_br2, &(C0_BR ++ [_]Pat{p(37, 39, "010")})),
    // cat1
    f(.mov, .c1_imm, &(C1_MOV ++ [_]Pat{p(53, 54, "10")})),
    f(.mov, .c1_const, &(C1_MOV ++ [_]Pat{ p(11, 31, "000000000000000000000"), p(53, 54, "01") })),
    f(.mov, .c1_gpr, &(C1_MOV ++ [_]Pat{ p(8, 9, "00"), p(11, 31, "000000000000000000000"), p(53, 54, "00") })),
    f(.mov, .c1_relgpr, &(C1_MOV ++ [_]Pat{ p(10, 10, "0"), p(11, 11, "1"), p(12, 31, "00000000000000000000"), p(53, 54, "00") })),
    f(.mov, .c1_relconst, &(C1_MOV ++ [_]Pat{ p(10, 10, "1"), p(11, 11, "1"), p(12, 31, "00000000000000000000"), p(53, 54, "00") })),
    f(.movs, .c1_movs_imm, &(C1_MOV ++ [_]Pat{ p(8, 9, "00"), p(11, 22, "000000000000"), p(30, 30, "0"), p(31, 31, "1"), p(53, 54, "00") })),
    f(.movs, .c1_movs_a0, &(C1_MOV ++ [_]Pat{ p(8, 9, "00"), p(11, 22, "000000000000"), p(23, 29, "0000000"), p(30, 30, "1"), p(31, 31, "1"), p(53, 54, "00") })),
    fg(.swz, .c1_swz, &(C1_MULTI ++ [_]Pat{ p(24, 31, "00000000"), p(40, 41, "00") }), 500, 0xffff),
    fg(.gat, .c1_gat, &(C1_MULTI ++ [_]Pat{p(40, 41, "01")}), 500, 0xffff),
    fg(.sct, .c1_sct, &(C1_MULTI ++ [_]Pat{p(40, 41, "10")}), 500, 0xffff),
    f(.movmsk, .c1_movmsk, &(C1 ++ [_]Pat{ p(0, 31, "00000000000000000000000000000000"), p(43, 43, "0"), p(46, 48, "011"), p(50, 52, "011"), p(53, 54, "00"), p(57, 58, "11") })),
    // cat2
    c2(.add_f, .c2_2src, "000000"),
    c2(.min_f, .c2_2src, "000001"),
    c2(.max_f, .c2_2src, "000010"),
    c2(.mul_f, .c2_2src, "000011"),
    c2(.sign_f, .c2_1src, "000100"),
    c2(.cmps_f, .c2_cond, "000101"),
    c2(.absneg_f, .c2_1src, "000110"),
    c2(.cmpv_f, .c2_cond, "000111"),
    c2(.floor_f, .c2_1src, "001001"),
    c2(.ceil_f, .c2_1src, "001010"),
    c2(.rndne_f, .c2_1src, "001011"),
    c2(.rndaz_f, .c2_1src, "001100"),
    c2(.trunc_f, .c2_1src, "001101"),
    c2(.add_u, .c2_2src, "010000"),
    c2(.add_s, .c2_2src, "010001"),
    c2(.sub_u, .c2_2src, "010010"),
    c2(.sub_s, .c2_2src, "010011"),
    c2(.cmps_u, .c2_cond, "010100"),
    c2(.cmps_s, .c2_cond, "010101"),
    c2(.min_u, .c2_2src, "010110"),
    c2(.min_s, .c2_2src, "010111"),
    c2(.max_u, .c2_2src, "011000"),
    c2(.max_s, .c2_2src, "011001"),
    c2(.absneg_s, .c2_1src, "011010"),
    c2(.and_b, .c2_2src, "011100"),
    c2(.or_b, .c2_2src, "011101"),
    c2(.not_b, .c2_1src, "011110"),
    c2(.xor_b, .c2_2src, "011111"),
    c2(.cmpv_u, .c2_cond, "100001"),
    c2(.cmpv_s, .c2_cond, "100010"),
    c2g(.mul_f_mul2, .c2_cond, "100011", 700),
    c2g(.add_f_mul2, .c2_cond, "100100", 700),
    c2g(.mul_f_div2, .c2_cond, "100101", 700),
    c2g(.add_f_div2, .c2_cond, "100110", 700),
    c2(.mul_u24, .c2_2src, "110000"),
    c2(.mul_s24, .c2_2src, "110001"),
    c2(.mull_u, .c2_2src, "110010"),
    c2(.bfrev_b, .c2_1src, "110011"),
    c2(.clz_s, .c2_1src, "110100"),
    c2(.clz_b, .c2_1src, "110101"),
    c2(.shl_b, .c2_2src, "110110"),
    c2(.shr_b, .c2_2src, "110111"),
    c2(.ashr_b, .c2_2src, "111000"),
    c2(.mgen_b, .c2_2src, "111010"),
    c2(.getbit_b, .c2_2src, "111011"),
    c2(.setrm, .c2_1src, "111100"),
    c2(.cbits_b, .c2_1src, "111101"),
    c2(.shb, .c2_2src, "111110"),
    c2(.msad, .c2_2src, "111111"),
    f(.bary_f, .c2_input, &(C2 ++ [_]Pat{ p(50, 50, "0"), p(53, 58, "111001") })),
    fg(.flat_b, .c2_input, &(C2 ++ [_]Pat{ p(50, 50, "1"), p(53, 58, "111001") }), 600, 0xffff),
    // cat3
    c3(.mad_u16, "0000"),
    c3(.madsh_u16, "0001"),
    c3(.mad_s16, "0010"),
    c3(.madsh_m16, "0011"),
    c3(.mad_u24, "0100"),
    c3(.mad_s24, "0101"),
    c3(.mad_f16, "0110"),
    c3(.mad_f32, "0111"),
    c3(.sel_b16, "1000"),
    c3(.sel_b32, "1001"),
    c3(.sel_s16, "1010"),
    c3(.sel_s32, "1011"),
    c3(.sel_f16, "1100"),
    c3(.sel_f32, "1101"),
    c3(.sad_s16, "1110"),
    c3(.sad_s32, "1111"),
    c3m(.mad_f16_mul2, "0100"),
    c3m(.mad_f32_mul2, "0101"),
    c3m(.mad_f16_div2, "0110"),
    c3m(.mad_f32_div2, "0111"),
    c3a(.shrm, "1000"),
    c3a(.shlm, "1001"),
    c3a(.shrg, "1010"),
    c3a(.shlg, "1011"),
    c3a(.andg, "1100"),
    fg(.dp2acc, .c3_dp, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(46, 46, "0"), p(55, 58, "1101") }), 600, 799),
    fg(.dp4acc, .c3_dp, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(46, 46, "1"), p(55, 58, "1101") }), 600, 0xffff),
    fg(.wmm, .c3_wmm, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(42, 42, "0"), p(55, 58, "1110") }), 600, 0xffff),
    fg(.wmm_accu, .c3_wmm, &(C3 ++ [_]Pat{ p(13, 13, "1"), p(42, 42, "1"), p(55, 58, "1110") }), 600, 0xffff),
    // cat4
    c4(.rcp, "000000"),
    c4(.rsq, "000001"),
    c4(.log2, "000010"),
    c4(.exp2, "000011"),
    c4(.sin, "000100"),
    c4(.cos, "000101"),
    c4(.sqrt, "000110"),
    c4(.hrsq, "001001"),
    c4(.hlog2, "001010"),
    c4(.hexp2, "001011"),
    // cat5: a texture sampled at one coordinate source, sampler and
    // texture slots immediate (no .3d, .a, .o, .p, .s, .clp, no bindless)
    f(.sam, .c5_tex, &[_]Pat{ p(61, 63, "101"), p(54, 58, "00011"), p(47, 53, "0000000"), p(18, 20, "000"), p(9, 16, "00000000") }),
    // cat6: global, local, private
    f(.ldg, .c6_ldg, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(22, 22, "0"), p(23, 23, "1"), p(27, 28, "00"), p(52, 53, "00"), p(54, 58, "00000") })),
    fg(.ldg_a, .c6_ldg_a6, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(22, 22, "1"), p(23, 23, "1"), p(27, 28, "00"), p(52, 53, "00"), p(54, 58, "00000") }), 500, 699),
    fg(.ldg_a, .c6_ldg_a7, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(22, 22, "1"), p(23, 23, "1"), p(27, 28, "00"), p(52, 53, "00"), p(54, 58, "00000") }), 700, 0xffff),
    fg(.ldg_k, .c6_ldg_k, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(22, 22, "0"), p(52, 52, "1"), p(53, 53, "0"), p(54, 58, "00000") }), 600, 0xffff),
    f(.stg, .c6_stg, &(C6 ++ [_]Pat{ p(23, 23, "1"), p(27, 28, "00"), p(52, 52, "0"), p(53, 53, "0"), p(54, 58, "00011") })),
    fg(.stg_a, .c6_stg_a6, &(C6 ++ [_]Pat{ p(23, 23, "1"), p(27, 28, "00"), p(52, 52, "1"), p(53, 53, "0"), p(54, 58, "00011") }), 500, 699),
    fg(.stg_a, .c6_stg_a7, &(C6 ++ [_]Pat{ p(22, 22, "0"), p(23, 23, "1"), p(27, 28, "00"), p(52, 52, "1"), p(53, 53, "0"), p(54, 58, "00011") }), 700, 0xffff),
    f(.ldl, .c6_ld, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(23, 23, "1"), p(54, 58, "00001") })),
    f(.ldp, .c6_ld, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(23, 23, "1"), p(54, 58, "00010") })),
    f(.ldlw, .c6_ld, &(C6 ++ [_]Pat{ p(0, 0, "1"), p(23, 23, "1"), p(54, 58, "01010") })),
    f(.ldlv, .c6_ldlv, &(C6 ++ [_]Pat{ p(0, 0, "0"), p(14, 21, "00000000"), p(22, 23, "11"), p(54, 58, "11111") })),
    f(.stl, .c6_st, &(C6 ++ [_]Pat{ p(23, 23, "1"), p(40, 40, "1"), p(54, 58, "00100") })),
    f(.stp, .c6_st, &(C6 ++ [_]Pat{ p(0, 0, "0"), p(23, 23, "1"), p(40, 40, "1"), p(54, 58, "00101") })),
    f(.stlw, .c6_st, &(C6 ++ [_]Pat{ p(23, 23, "1"), p(40, 40, "1"), p(54, 58, "01011") })),
    fg(.stc, .c6_stc, &(C6 ++ [_]Pat{ p(14, 22, "000000000"), p(23, 23, "1"), p(54, 58, "11100") }), 600, 0xffff),
    fg(.stsc, .c6_stsc, &(C6 ++ [_]Pat{ p(22, 23, "11"), p(52, 53, "00"), p(54, 58, "11101") }), 700, 0xffff),
    // cat6: a6xx descriptor-based forms
    fg(.ldc, .c6_ldc, &(C6_A6 ++ [_]Pat{ p(14, 19, "011110"), p(22, 22, "1"), p(49, 50, "11"), p(52, 53, "10") }), 600, 0xffff),
    fg(.ldc_k, .c6_ldc_k, &(C6_A6 ++ [_]Pat{ p(14, 19, "011110"), p(22, 22, "1"), p(49, 50, "11"), p(52, 53, "11") }), 600, 0xffff),
    fg(.getspid, .c6_getid, &(C6_A6 ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "100100"), p(22, 22, "1"), p(53, 53, "1") }), 600, 0xffff),
    fg(.getwid, .c6_getid, &(C6_A6 ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "100101"), p(22, 22, "1"), p(53, 53, "1") }), 600, 0xffff),
    fg(.getfiberid, .c6_getid, &(C6_A6 ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "100110"), p(22, 23, "11"), p(53, 53, "1") }), 600, 0xffff),
    fg(.resinfo_b, .c6_ibo1src, &(C6_A6 ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "001111"), p(20, 23, "0110"), p(53, 53, "1") }), 600, 0xffff),
    fg(.resbase, .c6_ibo1src, &(C6_A6 ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "001100"), p(20, 23, "0110"), p(53, 53, "1") }), 600, 0xffff),
    fg(.ldib_b, .c6_ibo_ls, &(C6_IBO ++ [_]Pat{ p(14, 19, "000110"), p(52, 53, "10") }), 600, 0xffff),
    fg(.stib_b, .c6_ibo_ls, &(C6_IBO ++ [_]Pat{ p(0, 0, "0"), p(14, 19, "011101"), p(52, 53, "10") }), 600, 0xffff),
    c6ibo(.atomic_b_add, "010000"),
    c6ibo(.atomic_b_sub, "010001"),
    c6ibo(.atomic_b_xchg, "010010"),
    c6ibo(.atomic_b_cmpxchg, "010101"),
    c6ibo(.atomic_b_min, "010110"),
    c6ibo(.atomic_b_max, "010111"),
    c6ibo(.atomic_b_and, "011000"),
    c6ibo(.atomic_b_or, "011001"),
    c6ibo(.atomic_b_xor, "011010"),
    c6g(.atomic_g_add, "10000"),
    c6g(.atomic_g_sub, "10001"),
    c6g(.atomic_g_xchg, "10010"),
    c6g(.atomic_g_inc, "10011"),
    c6g(.atomic_g_dec, "10100"),
    c6g(.atomic_g_cmpxchg, "10101"),
    c6g(.atomic_g_min, "10110"),
    c6g(.atomic_g_max, "10111"),
    c6g(.atomic_g_and, "11000"),
    c6g(.atomic_g_or, "11001"),
    c6g(.atomic_g_xor, "11010"),
    c6l(.atomic_add, "10000"),
    c6l(.atomic_sub, "10001"),
    c6l(.atomic_xchg, "10010"),
    c6l(.atomic_inc, "10011"),
    c6l(.atomic_dec, "10100"),
    c6l(.atomic_cmpxchg, "10101"),
    c6l(.atomic_min, "10110"),
    c6l(.atomic_max, "10111"),
    c6l(.atomic_and, "11000"),
    c6l(.atomic_or, "11001"),
    c6l(.atomic_xor, "11010"),
    fg(.shfl, .c6_shfl, &(C6 ++ [_]Pat{ p(0, 0, "0"), p(9, 22, "00000000000000"), p(52, 53, "10"), p(54, 58, "11011") }), 600, 0xffff),
    // cat7
    c7(.bar, .c7_barrier, &(C7_BAR ++ [_]Pat{p(55, 58, "0000")})),
    c7(.fence, .c7_barrier, &(C7_BAR ++ [_]Pat{p(55, 58, "0001")})),
    c7(.sleep, .c7_sleep, &(C7 ++ [_]Pat{p(55, 58, "0010")})),
    c7(.icinv, .c7_plain, &(C7 ++ [_]Pat{p(55, 58, "0011")})),
    c7(.dccln, .c7_data, &(C7 ++ [_]Pat{ p(54, 54, "0"), p(55, 58, "0100") })),
    c7(.dcinv, .c7_data, &(C7 ++ [_]Pat{ p(54, 54, "0"), p(55, 58, "0101") })),
    c7(.dcflu, .c7_data, &(C7 ++ [_]Pat{ p(54, 54, "0"), p(55, 58, "0110") })),
    fg(.ccinv, .c7_plain, &(C7_BAR ++ [_]Pat{ p(51, 54, "1010"), p(55, 58, "0101") }), 700, 0xffff),
    fg(.lock, .c7_plain, &(C7 ++ [_]Pat{ p(45, 54, "1000010000"), p(55, 58, "0111") }), 700, 0xffff),
    fg(.unlock, .c7_plain, &(C7 ++ [_]Pat{ p(45, 54, "1001010000"), p(55, 58, "0111") }), 700, 0xffff),
};

fn genOk(fm: *const Form, gen: u16) bool {
    return gen >= fm.gmin and gen <= fm.gmax;
}

// ── Bit fields ──────────────────────────────────────────────────────────────

inline fn get(w: u64, lo: u6, width: u7) u64 {
    return (w >> lo) & ((@as(u64, 1) << @intCast(width)) -% 1);
}

inline fn getb(w: u64, bit: u6) bool {
    return (w >> bit) & 1 != 0;
}

fn sext(v: u64, width: u7) i64 {
    const shift: u6 = @intCast(64 - @as(u32, width));
    return @as(i64, @bitCast(v << shift)) >> shift;
}

fn put(w: *u64, lo: u6, width: u7, v: u64) Error!void {
    const lim = (@as(u64, 1) << @intCast(width)) -% 1;
    if (v & ~lim != 0) return error.OutOfRange;
    w.* |= v << lo;
}

fn puti(w: *u64, lo: u6, width: u7, v: i64) Error!void {
    const half: i64 = @as(i64, 1) << @intCast(width - 1);
    if (v < -half or v >= half) return error.OutOfRange;
    w.* |= (@as(u64, @bitCast(v)) & ((@as(u64, 1) << @intCast(width)) - 1)) << lo;
}

fn putb(w: *u64, bit: u6, v: bool) void {
    if (v) w.* |= @as(u64, 1) << bit;
}

// ── Encoding ────────────────────────────────────────────────────────────────

fn layoutAccepts(layout: Layout, in: *const Instr) bool {
    return switch (layout) {
        .c1_imm => in.src[0].kind == .imm,
        .c1_const => in.src[0].kind == .cnst,
        .c1_gpr => in.src[0].kind == .gpr,
        .c1_relgpr => in.src[0].kind == .rel_gpr,
        .c1_relconst => in.src[0].kind == .rel_cnst,
        .c1_movs_imm => in.src[1].kind == .imm,
        .c1_movs_a0 => in.src[1].kind != .imm,
        else => true,
    };
}

fn findForm(gen: u16, in: *const Instr) ?*const Form {
    for (&forms) |*fm| {
        if (fm.op == in.op and genOk(fm, gen) and layoutAccepts(fm.layout, in)) return fm;
    }
    return null;
}

/// True for the bitwise ops whose (neg) source modifier means (not).
fn bnotSrc(op: Op, n: usize) bool {
    return switch (op) {
        .and_b, .or_b, .xor_b => true,
        .bfrev_b, .clz_s, .clz_b, .cbits_b, .shl_b, .shr_b, .getbit_b => n == 0,
        else => false,
    };
}

/// The 16-bit cat2/cat4 source.
fn encMulti(op: Op, n: usize, s: Src) Error!u64 {
    var w: u64 = 0;
    switch (s.kind) {
        .gpr => {
            try put(&w, 0, 8, s.num);
            putb(&w, 10, s.last);
        },
        .cnst => {
            try put(&w, 0, 11, s.num);
            w |= 0b010 << 11;
        },
        .rel_gpr, .rel_cnst => {
            try puti(&w, 0, 10, s.off);
            putb(&w, 10, s.kind == .rel_cnst);
            w |= 0b001 << 11;
        },
        .imm => {
            try puti(&w, 0, 11, @as(i32, @bitCast(s.imm)));
            w |= 0b100 << 11;
        },
        .flut => {
            try put(&w, 0, 10, s.imm);
            putb(&w, 10, s.half);
            w |= 0b101 << 11;
        },
        .none => return error.NoForm,
    }
    if (bnotSrc(op, n)) {
        if (s.neg) return error.NoForm;
        putb(&w, 14, s.bnot);
    } else {
        if (s.bnot) return error.NoForm;
        putb(&w, 14, s.neg);
    }
    putb(&w, 15, s.abs);
    return w;
}

/// The 13-bit cat3 src1/src3.
fn encCat3Src(s: Src, immed_encoding: bool) Error!u64 {
    var w: u64 = 0;
    switch (s.kind) {
        .gpr => {
            try put(&w, 0, 8, s.num);
            putb(&w, 10, s.last);
        },
        .cnst => {
            if (immed_encoding) return error.NoForm;
            try put(&w, 0, 11, s.num);
            w |= 1 << 12;
        },
        .imm => {
            if (!immed_encoding) return error.NoForm;
            try put(&w, 0, 12, s.imm);
            w |= 1 << 12;
        },
        .rel_gpr, .rel_cnst => {
            try puti(&w, 0, 10, s.off);
            putb(&w, 10, s.kind == .rel_cnst);
            w |= 1 << 11;
        },
        else => return error.NoForm,
    }
    return w;
}

fn cat3Full(op: Op) bool {
    return switch (op) {
        .mad_u16, .mad_s16, .mad_f16, .sel_b16, .sel_s16, .sel_f16, .sad_s16, .mad_f16_mul2, .mad_f16_div2 => false,
        else => true,
    };
}

fn isP0(num: u16) bool {
    return num >> 2 == 62;
}

/// A source that is a register or an immediate (cat6's #cat6-src).
fn encCat6Src(s: Src) Error!u64 {
    return switch (s.kind) {
        .gpr => s.num,
        .imm => blk: {
            if (s.imm > 0xff) return error.OutOfRange;
            break :blk s.imm;
        },
        else => error.NoForm,
    };
}

fn needGpr(s: Src) Error!u64 {
    if (s.kind != .gpr) return error.NoForm;
    if (s.num > 0xff) return error.OutOfRange;
    return s.num;
}

/// Encode one instruction for generation `gen` (A6XX, A7XX).
pub fn encode(gen: u16, in: *const Instr) Error!u64 {
    const fm = findForm(gen, in) orelse return error.NoForm;
    var w: u64 = fm.match;
    const cat = in.op.category();
    switch (cat) {
        0, 1, 2, 3, 4, 7 => putb(&w, 44, in.ss),
        else => if (in.ss) return error.NoForm,
    }
    putb(&w, 59, in.jp);
    putb(&w, 60, in.sy);
    switch (fm.layout) {
        .c0_0src, .c0_1src, .c0_immed, .c0_getlast, .c0_brac, .c0_brax, .c0_br1, .c0_br2 => {
            w |= @as(u64, @as(u32, @bitCast(in.imm)));
            try put(&w, 40, 3, in.repeat);
            putb(&w, 48, in.eq);
            switch (fm.layout) {
                .c0_0src => {
                    putb(&w, 32, in.eolm);
                    putb(&w, 33, in.eogm);
                    putb(&w, 34, in.eostsc);
                },
                .c0_1src, .c0_br1 => {
                    putb(&w, 52, in.inv1);
                    try put(&w, 53, 2, in.comp1);
                },
                .c0_br2 => {
                    putb(&w, 52, in.inv1);
                    try put(&w, 53, 2, in.comp1);
                    putb(&w, 45, in.inv2);
                    try put(&w, 46, 2, in.comp2);
                },
                .c0_brac => try put(&w, 32, 5, in.index),
                .c0_getlast => try put(&w, 52, 3, 2), // .w8
                else => {},
            }
        },
        .c1_imm, .c1_const, .c1_gpr, .c1_relgpr, .c1_relconst, .c1_movs_imm, .c1_movs_a0 => {
            const s = in.src[0];
            if (in.dst.rel) {
                try put(&w, 32, 8, in.dst.num);
                w |= 1 << 49;
            } else try put(&w, 32, 8, in.dst.num);
            try put(&w, 40, 2, in.repeat);
            putb(&w, 42, in.sat);
            putb(&w, 43, s.r or in.u);
            putb(&w, 45, in.ul);
            try put(&w, 46, 3, @intFromEnum(in.dst_type));
            try put(&w, 50, 3, @intFromEnum(in.src_type));
            try put(&w, 55, 2, @intFromEnum(in.round));
            switch (fm.layout) {
                .c1_imm => w |= s.imm,
                .c1_const => try put(&w, 0, 11, s.num),
                .c1_gpr => {
                    try put(&w, 0, 8, s.num);
                    putb(&w, 10, s.last);
                },
                .c1_relgpr, .c1_relconst => try puti(&w, 0, 10, s.off),
                .c1_movs_imm, .c1_movs_a0 => {
                    try put(&w, 0, 8, try needGpr(s));
                    putb(&w, 10, s.last);
                    if (fm.layout == .c1_movs_imm) try put(&w, 23, 7, in.src[1].imm);
                },
                else => unreachable,
            }
        },
        .c1_swz, .c1_gat, .c1_sct => {
            try put(&w, 32, 8, in.dst.num);
            putb(&w, 42, in.sat);
            putb(&w, 45, in.ul);
            try put(&w, 46, 3, @intFromEnum(in.dst_type));
            try put(&w, 50, 3, @intFromEnum(in.src_type));
            try put(&w, 55, 2, @intFromEnum(in.round));
            try put(&w, 0, 8, try needGpr(in.src[0]));
            switch (fm.layout) {
                .c1_swz => {
                    try put(&w, 8, 8, try needGpr(in.src[1]));
                    try put(&w, 16, 8, in.dsts[0]);
                },
                .c1_gat => {
                    try put(&w, 8, 8, try needGpr(in.src[1]));
                    try put(&w, 16, 8, try needGpr(in.src[2]));
                    try put(&w, 24, 8, try needGpr(in.src[3]));
                },
                else => {
                    try put(&w, 8, 8, in.dsts[0]);
                    try put(&w, 16, 8, in.dsts[1]);
                    try put(&w, 24, 8, in.dsts[2]);
                },
            }
        },
        .c1_movmsk => {
            if (in.dst.rel) {
                try put(&w, 32, 8, in.dst.num);
                w |= 1 << 49;
            } else try put(&w, 32, 8, in.dst.num);
            try put(&w, 40, 2, in.repeat);
            putb(&w, 45, in.ul);
        },
        .c2_1src, .c2_2src, .c2_cond, .c2_input => {
            const two = fm.layout != .c2_1src;
            const s1 = in.src[0];
            try put(&w, 32, 8, in.dst.num);
            putb(&w, 42, in.sat);
            putb(&w, 45, in.ul);
            putb(&w, 47, in.dst.ei);
            if (fm.layout == .c2_cond) try put(&w, 48, 3, @intFromEnum(in.cond));
            const full = !s1.half;
            putb(&w, 52, full);
            putb(&w, 46, !isP0(in.dst.num) and s1.half != in.dst.half);
            if (in.nop != 0) {
                if (in.repeat != 0 or s1.r or (two and in.src[1].r)) return error.NoForm;
                putb(&w, 43, in.nop & 1 != 0);
                putb(&w, 51, in.nop & 2 != 0);
            } else {
                try put(&w, 40, 2, in.repeat);
                putb(&w, 43, s1.r);
                if (two) putb(&w, 51, in.src[1].r);
            }
            w |= try encMulti(in.op, 0, s1);
            if (two) {
                if (in.src[1].half != s1.half and in.src[1].kind != .imm and in.src[1].kind != .flut) return error.NoForm;
                w |= (try encMulti(in.op, 1, in.src[1])) << 16;
            }
        },
        .c3, .c3_alt, .c3_dp, .c3_wmm => {
            const alt = fm.layout == .c3_alt or fm.layout == .c3_wmm;
            const s1 = in.src[0];
            const s2 = in.src[1];
            const s3 = in.src[2];
            // The alternate forms (shrm/shlm/shrg/shlg/andg, wmm) have no
            // plain const sources: their bit 12 means an immediate, so a
            // const would be read as the immediate of its number.
            if (alt and (s1.kind == .cnst or s3.kind == .cnst)) return error.NoForm;
            try put(&w, 32, 8, in.dst.num);
            putb(&w, 45, in.ul);
            try put(&w, 47, 8, try needGpr(s2));
            w |= try encCat3Src(s1, false or (alt and s1.kind == .imm));
            w |= (try encCat3Src(s3, alt and s3.kind == .imm)) << 16;
            putb(&w, 14, s1.neg);
            putb(&w, 30, s2.neg);
            putb(&w, 31, s3.neg);
            putb(&w, 29, s3.r);
            if (in.nop != 0) {
                if (in.repeat != 0) return error.NoForm;
                putb(&w, 43, in.nop & 1 != 0);
                putb(&w, 15, in.nop & 2 != 0);
            } else {
                if (fm.layout != .c3_dp) try put(&w, 40, 2, in.repeat) else if (in.repeat != 0) return error.NoForm;
                putb(&w, 43, s1.r);
                putb(&w, 15, s2.r);
            }
            switch (fm.layout) {
                .c3 => {
                    putb(&w, 42, in.sat);
                    putb(&w, 46, !isP0(in.dst.num) and (!cat3Full(in.op)) != in.dst.half);
                },
                .c3_alt => {
                    if (in.sat) return error.NoForm;
                    putb(&w, 42, !s2.half);
                    putb(&w, 46, !isP0(in.dst.num) and s2.half != in.dst.half);
                },
                .c3_dp => {
                    putb(&w, 42, in.sat);
                    putb(&w, 14, in.mixed);
                    putb(&w, 30, in.high);
                    if (s1.neg or s2.neg) return error.NoForm;
                },
                .c3_wmm => {
                    putb(&w, 31, !s1.half);
                    putb(&w, 46, isP0(in.dst.num) or !in.dst.half);
                    if (s3.neg) return error.NoForm;
                },
                else => unreachable,
            }
        },
        .c5_tex => {
            const s = in.src[0];
            if (s.kind != .gpr or in.dst.half != in.ty.half()) return error.NoForm;
            putb(&w, 0, !s.half);
            try put(&w, 1, 8, s.num);
            try put(&w, 21, 4, in.samp);
            try put(&w, 25, 7, in.tex);
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 40, 4, in.wrmask);
            try put(&w, 44, 3, @intFromEnum(in.ty));
        },
        .c4 => {
            const s = in.src[0];
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 40, 2, in.repeat);
            putb(&w, 42, in.sat);
            putb(&w, 43, s.r);
            putb(&w, 45, in.ul);
            putb(&w, 46, !isP0(in.dst.num) and s.half != in.dst.half);
            putb(&w, 52, !s.half);
            w |= try encMulti(in.op, 0, s);
        },
        .c6_ldg => {
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 14, 8, try needGpr(in.src[0]));
            try puti(&w, 1, 13, in.off);
            try put(&w, 24, 3, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ldg_a6 => {
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 14, 8, try needGpr(in.src[0]));
            try put(&w, 1, 8, try needGpr(in.src[1]));
            if (in.off < 0) return error.OutOfRange;
            try put(&w, 9, 2, @intCast(in.off));
            try put(&w, 12, 2, in.shift);
            try put(&w, 24, 3, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ldg_a7 => {
            try put(&w, 32, 8, in.dst.num);
            const b = in.src[0];
            if (b.kind != .gpr and b.kind != .cnst) return error.NoForm;
            try put(&w, 14, 8, b.num);
            putb(&w, 13, b.kind == .cnst);
            try put(&w, 1, 8, try needGpr(in.src[1]));
            if (in.off < 0) return error.OutOfRange;
            try put(&w, 41, 8, @intCast(in.off));
            try put(&w, 24, 3, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ldg_k => {
            try put(&w, 32, 8, @intCast(in.dst.num));
            putb(&w, 40, in.a1);
            try put(&w, 14, 8, try needGpr(in.src[0]));
            try puti(&w, 1, 13, in.off);
            if (in.src[1].kind == .gpr) {
                try put(&w, 24, 8, in.src[1].num);
            } else {
                if (in.size < 1) return error.OutOfRange;
                w |= 1 << 23;
                try put(&w, 24, 8, in.size - 1);
            }
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_stg, .c6_stg_a6, .c6_stg_a7 => {
            const b = in.src[0];
            try put(&w, 1, 8, try needGpr(in.src[2]));
            try put(&w, 24, 3, in.size);
            w |= 1 << 40; // DST_OFF
            try put(&w, 49, 3, @intFromEnum(in.ty));
            switch (fm.layout) {
                .c6_stg => {
                    try put(&w, 41, 8, try needGpr(b));
                    if (in.off < -4096 or in.off > 4095) return error.OutOfRange;
                    const o: u64 = @as(u64, @bitCast(@as(i64, in.off))) & 0x1fff;
                    try put(&w, 32, 8, o & 0xff);
                    try put(&w, 9, 5, o >> 8);
                },
                .c6_stg_a6 => {
                    try put(&w, 41, 8, try needGpr(b));
                    try put(&w, 32, 8, try needGpr(in.src[1]));
                    if (in.off < 0) return error.OutOfRange;
                    try put(&w, 9, 2, @intCast(in.off));
                    try put(&w, 12, 2, in.shift);
                },
                else => {
                    if (b.kind != .gpr and b.kind != .cnst) return error.NoForm;
                    try put(&w, 41, 8, b.num);
                    putb(&w, 13, b.kind == .cnst);
                    try put(&w, 32, 8, try needGpr(in.src[1]));
                    if (in.off < 0) return error.OutOfRange;
                    try put(&w, 14, 8, @intCast(in.off));
                },
            }
        },
        .c6_ld => {
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 14, 8, try needGpr(in.src[0]));
            try puti(&w, 1, 13, in.off);
            try put(&w, 24, 8, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ldlv => {
            try put(&w, 32, 8, in.dst.num);
            if (in.off < 0) return error.OutOfRange;
            try put(&w, 1, 13, @intCast(in.off));
            try put(&w, 24, 8, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_st => {
            try put(&w, 41, 8, try needGpr(in.src[0]));
            try put(&w, 1, 8, try needGpr(in.src[1]));
            if (in.off < -4096 or in.off > 4095) return error.OutOfRange;
            const o: u64 = @as(u64, @bitCast(@as(i64, in.off))) & 0x1fff;
            try put(&w, 32, 8, o & 0xff);
            try put(&w, 9, 5, o >> 8);
            try put(&w, 24, 8, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_stc => {
            try put(&w, 1, 8, try needGpr(in.src[0]));
            try put(&w, 24, 3, in.size);
            if (in.off < 0) return error.OutOfRange;
            try put(&w, 32, 8, @intCast(in.off));
            putb(&w, 40, in.a1);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_stsc => {
            try put(&w, 1, 8, try encCat6Src(in.src[0]));
            if (in.off < 0) return error.OutOfRange;
            const o: u64 = @intCast(in.off);
            try put(&w, 32, 8, o & 0xff);
            try put(&w, 9, 5, o >> 8);
            try put(&w, 24, 8, in.size);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ldc, .c6_ldc_k => {
            try encA6Base(&w, in);
            try put(&w, 24, 8, try encCat6Src(in.src[0]));
            putb(&w, 23, in.src[0].kind == .imm);
            try put(&w, 41, 8, try encCat6Src(in.src[1]));
            if (in.mode == .imm and in.src[1].kind != .imm) return error.NoForm;
            if (fm.layout == .c6_ldc) {
                try put(&w, 32, 8, in.dst.num);
                if (in.off < 0) return error.OutOfRange;
                try put(&w, 9, 2, @intCast(in.off));
                putb(&w, 11, in.u);
                if (in.type_size < 1) return error.OutOfRange;
                try put(&w, 12, 2, in.type_size - 1);
            } else {
                if (in.size < 1) return error.OutOfRange;
                try put(&w, 32, 8, in.size - 1);
            }
        },
        .c6_getid => {
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_ibo1src => {
            try encA6Base(&w, in);
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 41, 8, try encCat6Src(in.src[0]));
            if (in.mode == .imm and in.src[0].kind != .imm) return error.NoForm;
            try encDTyped(&w, in);
            try put(&w, 49, 3, @intFromEnum(in.ty));
            if (in.type_size < 1) return error.OutOfRange;
            try put(&w, 12, 2, in.type_size - 1);
        },
        .c6_ibo_ls, .c6_ibo_atomic => {
            try encA6Base(&w, in);
            try encDTyped(&w, in);
            if (in.type_size < 1) return error.OutOfRange;
            try put(&w, 12, 2, in.type_size - 1);
            try put(&w, 49, 3, @intFromEnum(in.ty));
            try put(&w, 24, 8, try needGpr(in.src[0]));
            try put(&w, 41, 8, try encCat6Src(in.src[1]));
            if (in.mode == .imm and in.src[1].kind != .imm) return error.NoForm;
            if (fm.layout == .c6_ibo_ls) {
                const v = if (in.op == .ldib_b) in.dst.num else @as(u16, @intCast(try needGpr(in.src[2])));
                try put(&w, 32, 8, v);
                putb(&w, 40, in.rck);
                if (in.has_offset) {
                    w |= 1 << 23;
                    if (in.off < 0 or in.off > 127) return error.OutOfRange;
                    const o: u64 = @intCast(in.off);
                    try put(&w, 54, 5, o & 0x1f);
                    try put(&w, 4, 2, o >> 5);
                }
            } else {
                try put(&w, 32, 8, try needGpr(in.src[2]));
            }
        },
        .c6_atomic_g, .c6_atomic_l => {
            try put(&w, 32, 8, in.dst.num);
            try encDTyped(&w, in);
            if (in.type_size < 1) return error.OutOfRange;
            try put(&w, 12, 2, in.type_size - 1);
            try put(&w, 14, 8, try encCat6Src(in.src[0]));
            putb(&w, 22, in.src[0].kind == .imm);
            try put(&w, 24, 8, try encCat6Src(in.src[1]));
            putb(&w, 23, in.src[1].kind == .imm);
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c6_shfl => {
            try put(&w, 32, 8, in.dst.num);
            try put(&w, 1, 8, try needGpr(in.src[0]));
            try put(&w, 24, 8, try encCat6Src(in.src[1]));
            putb(&w, 23, in.src[1].kind == .imm);
            try put(&w, 45, 3, @intFromEnum(in.shfl));
            try put(&w, 49, 3, @intFromEnum(in.ty));
        },
        .c7_barrier => {
            putb(&w, 51, in.w);
            putb(&w, 52, in.r);
            putb(&w, 53, in.l);
            putb(&w, 54, in.g);
        },
        .c7_sleep, .c7_data => putb(&w, 51, in.long),
        .c7_plain => {},
    }
    return w;
}

fn encA6Base(w: *u64, in: *const Instr) Error!void {
    try put(w, 1, 3, in.base);
    try put(w, 6, 2, @intFromEnum(in.mode));
    putb(w, 8, in.bindless);
}

fn encDTyped(w: *u64, in: *const Instr) Error!void {
    if (in.d < 1) return error.OutOfRange;
    try put(w, 9, 2, in.d - 1);
    putb(w, 11, in.typed);
}

// ── Decoding ────────────────────────────────────────────────────────────────

fn decMulti(op: Op, n: usize, v: u64, half: bool, r: bool) Src {
    var s = Src{ .half = half, .r = r };
    switch (get(v, 11, 3)) {
        0b000 => {
            s.kind = .gpr;
            s.num = @intCast(get(v, 0, 8));
            s.last = getb(v, 10);
        },
        0b010, 0b110 => {
            s.kind = .cnst;
            s.num = @intCast(get(v, 0, 11));
        },
        0b001 => {
            s.kind = if (getb(v, 10)) .rel_cnst else .rel_gpr;
            s.off = @intCast(sext(get(v, 0, 10), 10));
        },
        0b100 => {
            s.kind = .imm;
            s.imm = @bitCast(@as(i32, @intCast(sext(get(v, 0, 11), 11))));
        },
        0b101 => {
            s.kind = .flut;
            s.imm = @intCast(get(v, 0, 10));
            s.half = getb(v, 10);
        },
        else => s.kind = .none,
    }
    if (bnotSrc(op, n)) s.bnot = getb(v, 14) else s.neg = getb(v, 14);
    s.abs = getb(v, 15);
    return s;
}

fn decCat3Src(v: u64, half: bool, immed_encoding: bool) Src {
    var s = Src{ .half = half };
    if (getb(v, 12)) {
        if (immed_encoding) {
            s.kind = .imm;
            s.imm = @intCast(get(v, 0, 12));
        } else {
            s.kind = .cnst;
            s.num = @intCast(get(v, 0, 11));
        }
    } else if (getb(v, 11)) {
        s.kind = if (getb(v, 10)) .rel_cnst else .rel_gpr;
        s.off = @intCast(sext(get(v, 0, 10), 10));
    } else {
        s.kind = .gpr;
        s.num = @intCast(get(v, 0, 8));
        s.last = getb(v, 10);
    }
    return s;
}

fn decCat6Src(v: u64, im: bool) Src {
    return if (im) Src.immed(@intCast(v)) else Src.gpr(@intCast(v));
}

fn matchForm(gen: u16, w: u64) Error!*const Form {
    var found: ?*const Form = null;
    for (&forms) |*fm| {
        if (!genOk(fm, gen)) continue;
        if (w & fm.mask != fm.match) continue;
        if (found != null) return error.NoMatch;
        found = fm;
    }
    return found orelse error.NoMatch;
}

/// Decode a 64-bit instruction word.
pub fn decode(gen: u16, w: u64) Error!Instr {
    const fm = try matchForm(gen, w);
    var in = Instr{ .op = fm.op };
    in.jp = getb(w, 59);
    in.sy = getb(w, 60);
    switch (in.op.category()) {
        0, 1, 2, 3, 4, 7 => in.ss = getb(w, 44),
        else => {},
    }
    switch (fm.layout) {
        .c0_0src, .c0_1src, .c0_immed, .c0_getlast, .c0_brac, .c0_brax, .c0_br1, .c0_br2 => {
            in.imm = @bitCast(@as(u32, @truncate(w)));
            in.repeat = @intCast(get(w, 40, 3));
            in.eq = getb(w, 48);
            in.eolm = fm.layout == .c0_0src and getb(w, 32);
            in.eogm = fm.layout == .c0_0src and getb(w, 33);
            in.eostsc = fm.layout == .c0_0src and getb(w, 34);
            in.inv1 = getb(w, 52);
            in.comp1 = @intCast(get(w, 53, 2));
            in.inv2 = getb(w, 45);
            in.comp2 = @intCast(get(w, 46, 2));
            in.index = @intCast(get(w, 32, 5));
        },
        .c1_imm, .c1_const, .c1_gpr, .c1_relgpr, .c1_relconst, .c1_movs_imm, .c1_movs_a0, .c1_movmsk => {
            in.dst.num = @intCast(get(w, 32, 8));
            in.dst.rel = getb(w, 49);
            in.repeat = @intCast(get(w, 40, 2));
            in.sat = getb(w, 42);
            in.ul = getb(w, 45);
            in.dst_type = @enumFromInt(get(w, 46, 3));
            in.src_type = @enumFromInt(get(w, 50, 3));
            in.round = @enumFromInt(get(w, 55, 2));
            in.dst.half = in.dst_type.halfCat1();
            const r = getb(w, 43);
            const half = in.src_type.halfCat1();
            var s = Src{ .half = half, .r = r };
            switch (fm.layout) {
                .c1_imm => {
                    s.kind = .imm;
                    s.imm = @truncate(w);
                },
                .c1_const => {
                    s.kind = .cnst;
                    s.num = @intCast(get(w, 0, 11));
                },
                .c1_gpr, .c1_movs_imm, .c1_movs_a0 => {
                    s.kind = .gpr;
                    s.num = @intCast(get(w, 0, 8));
                    s.last = getb(w, 10);
                },
                .c1_relgpr, .c1_relconst => {
                    s.kind = if (fm.layout == .c1_relgpr) .rel_gpr else .rel_cnst;
                    s.off = @intCast(sext(get(w, 0, 10), 10));
                },
                else => {},
            }
            if (fm.layout != .c1_movmsk) in.src[0] = s;
            if (fm.layout == .c1_movs_imm) in.src[1] = Src.immed(@intCast(get(w, 23, 7)));
            if (fm.layout == .c1_movs_a0) in.src[1] = Src.gpr(A0_X);
            // mova/mova1's .u is the same bit as (r).
            if (in.op == .mov and isMova(&in)) {
                in.u = r;
                if (s.kind == .imm) in.src[0].r = false;
            }
        },
        .c1_swz, .c1_gat, .c1_sct => {
            in.sat = getb(w, 42);
            in.ul = getb(w, 45);
            in.dst_type = @enumFromInt(get(w, 46, 3));
            in.src_type = @enumFromInt(get(w, 50, 3));
            in.round = @enumFromInt(get(w, 55, 2));
            const sh = in.src_type.halfCat1();
            in.dst.half = in.dst_type.halfCat1();
            in.dst.num = @intCast(get(w, 32, 8));
            in.src[0] = .{ .kind = .gpr, .num = @intCast(get(w, 0, 8)), .half = sh };
            switch (fm.layout) {
                .c1_swz => {
                    in.src[1] = .{ .kind = .gpr, .num = @intCast(get(w, 8, 8)), .half = sh };
                    in.dsts[0] = @intCast(get(w, 16, 8));
                },
                .c1_gat => {
                    in.src[1] = .{ .kind = .gpr, .num = @intCast(get(w, 8, 8)), .half = sh };
                    in.src[2] = .{ .kind = .gpr, .num = @intCast(get(w, 16, 8)), .half = sh };
                    in.src[3] = .{ .kind = .gpr, .num = @intCast(get(w, 24, 8)), .half = sh };
                },
                else => {
                    in.dsts[0] = @intCast(get(w, 8, 8));
                    in.dsts[1] = @intCast(get(w, 16, 8));
                    in.dsts[2] = @intCast(get(w, 24, 8));
                },
            }
        },
        .c2_1src, .c2_2src, .c2_cond, .c2_input => {
            const two = fm.layout != .c2_1src;
            in.dst.num = @intCast(get(w, 32, 8));
            in.sat = getb(w, 42);
            in.ul = getb(w, 45);
            in.dst.ei = getb(w, 47);
            if (fm.layout == .c2_cond) in.cond = @enumFromInt(get(w, 48, 3));
            const full = getb(w, 52);
            const conv = getb(w, 46);
            in.dst.half = full == conv and in.dst.num <= 0xf7;
            const r1 = getb(w, 43);
            const r2 = getb(w, 51);
            in.repeat = @intCast(get(w, 40, 2));
            const nop = (r1 or r2) and in.repeat == 0;
            if (nop) in.nop = @as(u8, @intFromBool(r1)) | (@as(u8, @intFromBool(r2)) << 1);
            in.src[0] = decMulti(in.op, 0, get(w, 0, 16), !full, r1 and !nop);
            if (two) in.src[1] = decMulti(in.op, 1, get(w, 16, 16), !full, r2 and !nop);
        },
        .c3, .c3_alt, .c3_dp, .c3_wmm => {
            in.dst.num = @intCast(get(w, 32, 8));
            in.ul = getb(w, 45);
            in.repeat = @intCast(get(w, 40, 2));
            const r1 = getb(w, 43);
            const r2 = getb(w, 15);
            const nop = (r1 or r2) and in.repeat == 0;
            if (nop) in.nop = @as(u8, @intFromBool(r1)) | (@as(u8, @intFromBool(r2)) << 1);
            const full: bool = switch (fm.layout) {
                .c3 => cat3Full(in.op),
                .c3_alt => getb(w, 42),
                .c3_dp => true,
                .c3_wmm => getb(w, 31),
                else => unreachable,
            };
            const alt = fm.layout == .c3_alt or fm.layout == .c3_wmm;
            in.src[0] = decCat3Src(get(w, 0, 13), !full, fm.layout == .c3_alt);
            in.src[1] = .{ .kind = .gpr, .num = @intCast(get(w, 47, 8)), .half = !full };
            in.src[2] = decCat3Src(get(w, 16, 13), !full, alt);
            in.src[0].r = r1 and !nop;
            in.src[1].r = r2 and !nop;
            in.src[2].r = getb(w, 29);
            in.src[0].neg = getb(w, 14);
            in.src[1].neg = getb(w, 30);
            in.src[2].neg = getb(w, 31);
            switch (fm.layout) {
                .c3 => {
                    in.sat = getb(w, 42);
                    in.dst.half = getb(w, 46) == full and in.dst.num <= 0xf7;
                },
                .c3_alt => in.dst.half = getb(w, 46) == full and in.dst.num <= 0xf7,
                .c3_dp => {
                    in.sat = getb(w, 42);
                    in.mixed = getb(w, 14);
                    in.high = getb(w, 30);
                    in.src[0].neg = false;
                    in.src[1].neg = false;
                    in.repeat = 0;
                },
                .c3_wmm => {
                    in.src[2].neg = false;
                    in.dst.half = !getb(w, 46);
                },
                else => unreachable,
            }
        },
        .c5_tex => {
            in.ty = @enumFromInt(get(w, 44, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.wrmask = @intCast(get(w, 40, 4));
            in.src[0] = .{ .kind = .gpr, .num = @intCast(get(w, 1, 8)), .half = !getb(w, 0) };
            in.samp = @intCast(get(w, 21, 4));
            in.tex = @intCast(get(w, 25, 7));
        },
        .c4 => {
            in.dst.num = @intCast(get(w, 32, 8));
            in.repeat = @intCast(get(w, 40, 2));
            in.sat = getb(w, 42);
            in.ul = getb(w, 45);
            const full = getb(w, 52);
            in.dst.half = full == getb(w, 46) and in.dst.num <= 0xf7;
            in.src[0] = decMulti(in.op, 0, get(w, 0, 16), !full, getb(w, 43));
        },
        .c6_ldg => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.src[0] = Src.gpr(@intCast(get(w, 14, 8)));
            in.off = @intCast(sext(get(w, 1, 13), 13));
            in.size = @intCast(get(w, 24, 3));
        },
        .c6_ldg_a6 => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.src[0] = Src.gpr(@intCast(get(w, 14, 8)));
            in.src[1] = Src.gpr(@intCast(get(w, 1, 8)));
            in.off = @intCast(get(w, 9, 2));
            in.shift = @intCast(get(w, 12, 2));
            in.size = @intCast(get(w, 24, 3));
        },
        .c6_ldg_a7 => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.src[0] = if (getb(w, 13)) Src.cnst(@intCast(get(w, 14, 8))) else Src.gpr(@intCast(get(w, 14, 8)));
            in.src[1] = Src.gpr(@intCast(get(w, 1, 8)));
            in.off = @intCast(get(w, 41, 8));
            in.size = @intCast(get(w, 24, 3));
        },
        .c6_ldg_k => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst.num = @intCast(get(w, 32, 8));
            in.a1 = getb(w, 40);
            in.src[0] = Src.gpr(@intCast(get(w, 14, 8)));
            in.off = @intCast(sext(get(w, 1, 13), 13));
            if (getb(w, 23)) in.size = @as(u32, @intCast(get(w, 24, 8))) + 1 else in.src[1] = Src.gpr(@intCast(get(w, 24, 8)));
        },
        .c6_stg, .c6_stg_a6, .c6_stg_a7 => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[2] = .{ .kind = .gpr, .num = @intCast(get(w, 1, 8)), .half = in.ty.half() };
            in.size = @intCast(get(w, 24, 3));
            switch (fm.layout) {
                .c6_stg => {
                    in.src[0] = Src.gpr(@intCast(get(w, 41, 8)));
                    in.off = @intCast(sext((get(w, 9, 5) << 8) | get(w, 32, 8), 13));
                },
                .c6_stg_a6 => {
                    in.src[0] = Src.gpr(@intCast(get(w, 41, 8)));
                    in.src[1] = Src.gpr(@intCast(get(w, 32, 8)));
                    in.off = @intCast(get(w, 9, 2));
                    in.shift = @intCast(get(w, 12, 2));
                },
                else => {
                    in.src[0] = if (getb(w, 13)) Src.cnst(@intCast(get(w, 41, 8))) else Src.gpr(@intCast(get(w, 41, 8)));
                    in.src[1] = Src.gpr(@intCast(get(w, 32, 8)));
                    in.off = @intCast(get(w, 14, 8));
                },
            }
        },
        .c6_ld => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.src[0] = Src.gpr(@intCast(get(w, 14, 8)));
            in.off = @intCast(sext(get(w, 1, 13), 13));
            in.size = @intCast(get(w, 24, 8));
        },
        .c6_ldlv => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.off = @intCast(get(w, 1, 13));
            in.size = @intCast(get(w, 24, 8));
        },
        .c6_st => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[0] = Src.gpr(@intCast(get(w, 41, 8)));
            in.src[1] = .{ .kind = .gpr, .num = @intCast(get(w, 1, 8)), .half = in.ty.half() };
            in.off = @intCast(sext((get(w, 9, 5) << 8) | get(w, 32, 8), 13));
            in.size = @intCast(get(w, 24, 8));
        },
        .c6_stc => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[0] = Src.gpr(@intCast(get(w, 1, 8)));
            in.size = @intCast(get(w, 24, 3));
            in.off = @intCast(get(w, 32, 8));
            in.a1 = getb(w, 40);
        },
        .c6_stsc => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[0] = Src.immed(@intCast(get(w, 1, 8)));
            in.off = @intCast((get(w, 9, 5) << 8) | get(w, 32, 8));
            in.size = @intCast(get(w, 24, 8));
        },
        .c6_ldc, .c6_ldc_k => {
            decA6Base(&in, w);
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[0] = decCat6Src(get(w, 24, 8), getb(w, 23));
            in.src[1] = decCat6Src(get(w, 41, 8), in.mode == .imm);
            if (fm.layout == .c6_ldc) {
                in.dst.num = @intCast(get(w, 32, 8));
                in.off = @intCast(get(w, 9, 2));
                in.u = getb(w, 11);
                in.type_size = @as(u8, @intCast(get(w, 12, 2))) + 1;
            } else in.size = @as(u32, @intCast(get(w, 32, 8))) + 1;
        },
        .c6_getid => {
            in.dst.num = @intCast(get(w, 32, 8));
            in.ty = @enumFromInt(get(w, 49, 3));
        },
        .c6_ibo1src => {
            decA6Base(&in, w);
            in.dst.num = @intCast(get(w, 32, 8));
            in.src[0] = decCat6Src(get(w, 41, 8), in.mode == .imm);
            in.d = @as(u8, @intCast(get(w, 9, 2))) + 1;
            in.typed = getb(w, 11);
            in.type_size = @as(u8, @intCast(get(w, 12, 2))) + 1;
            in.ty = @enumFromInt(get(w, 49, 3));
        },
        .c6_ibo_ls, .c6_ibo_atomic => {
            decA6Base(&in, w);
            in.d = @as(u8, @intCast(get(w, 9, 2))) + 1;
            in.typed = getb(w, 11);
            in.type_size = @as(u8, @intCast(get(w, 12, 2))) + 1;
            in.ty = @enumFromInt(get(w, 49, 3));
            in.src[0] = Src.gpr(@intCast(get(w, 24, 8)));
            in.src[1] = decCat6Src(get(w, 41, 8), in.mode == .imm);
            const v: u16 = @intCast(get(w, 32, 8));
            if (fm.layout == .c6_ibo_ls) {
                const h = in.ty.half();
                if (in.op == .ldib_b) in.dst = .{ .num = v, .half = h } else in.src[2] = .{ .kind = .gpr, .num = v, .half = h };
                in.rck = getb(w, 40);
                in.has_offset = getb(w, 23);
                if (in.has_offset) in.off = @intCast((get(w, 4, 2) << 5) | get(w, 54, 5));
            } else in.src[2] = Src.gpr(v);
        },
        .c6_atomic_g, .c6_atomic_l => {
            in.dst.num = @intCast(get(w, 32, 8));
            in.d = @as(u8, @intCast(get(w, 9, 2))) + 1;
            in.typed = getb(w, 11);
            in.type_size = @as(u8, @intCast(get(w, 12, 2))) + 1;
            in.src[0] = decCat6Src(get(w, 14, 8), getb(w, 22));
            in.src[1] = decCat6Src(get(w, 24, 8), getb(w, 23));
            in.ty = @enumFromInt(get(w, 49, 3));
        },
        .c6_shfl => {
            in.ty = @enumFromInt(get(w, 49, 3));
            in.dst = .{ .num = @intCast(get(w, 32, 8)), .half = in.ty.half() };
            in.src[0] = .{ .kind = .gpr, .num = @intCast(get(w, 1, 8)), .half = in.ty.half() };
            in.src[1] = decCat6Src(get(w, 24, 8), getb(w, 23));
            in.shfl = std.enums.fromInt(Shfl, get(w, 45, 3)) orelse return error.NoMatch;
        },
        .c7_barrier => {
            in.w = getb(w, 51);
            in.r = getb(w, 52);
            in.l = getb(w, 53);
            in.g = getb(w, 54);
        },
        .c7_sleep, .c7_data => in.long = getb(w, 51),
        .c7_plain => {},
    }
    return in;
}

fn decA6Base(in: *Instr, w: u64) void {
    in.base = @intCast(get(w, 1, 3));
    in.mode = std.enums.fromInt(Mode, get(w, 6, 2)) orelse .nonuniform;
    in.bindless = getb(w, 8);
}

fn isMova(in: *const Instr) bool {
    return (in.dst.num == A0_X and !in.dst.rel and in.src_type == .s16 and in.dst_type == .s16) or
        (in.dst.num == A1_X and !in.dst.rel and in.src_type == .u16 and in.dst_type == .u16);
}

fn layoutOf(gen: u16, in: *const Instr) ?Layout {
    const fm = findForm(gen, in) orelse return null;
    return fm.layout;
}

// ── Text (Mesa's disassembly syntax) ────────────────────────────────────────

pub const Text = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn s(t: *Text, str: []const u8) void {
        if (t.len + str.len > t.buf.len) {
            t.overflow = true;
            return;
        }
        @memcpy(t.buf[t.len..][0..str.len], str);
        t.len += str.len;
    }

    pub fn print(t: *Text, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(t.buf[t.len..], fmt, args) catch {
            t.overflow = true;
            return;
        };
        t.len += out.len;
    }

    pub fn text(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

const swiz = "xyzw";

fn putGpr(t: *Text, num: u16, cat2_dst: bool) void {
    const idx = num >> 2;
    const c = swiz[num & 3];
    if (idx == 61) {
        t.s(if (cat2_dst) "up0." else "a0.");
    } else if (idx == 62) {
        t.s("p0.");
    } else {
        t.print("r{d}.", .{idx});
    }
    t.s(&[_]u8{c});
}

fn putConst(t: *Text, num: u16) void {
    t.print("c{d}.{c}", .{ num >> 2, swiz[num & 3] });
}

fn putH(t: *Text, half: bool) void {
    if (half) t.s("h");
}

fn putRel(t: *Text, cnst: bool, off: i16, show_zero: bool) void {
    t.s(if (cnst) "c<a0.x" else "r<a0.x");
    if (off != 0 or show_zero) t.print(" + {d}", .{off});
    t.s(">");
}

fn putRpt(t: *Text, repeat: u8) void {
    if (repeat != 0) t.print("(rpt{d})", .{repeat});
}

/// %.9g / %.5g as C prints them (isaspec's float display).
fn putFloat(t: *Text, v: f64, prec: u8) void {
    if (std.math.isNan(v)) {
        t.s(if (std.math.signbit(v)) "-nan" else "nan");
        return;
    }
    if (std.math.isFinite(v) and v == @trunc(v)) {
        t.print("{d:.1}", .{v});
        return;
    }
    var tmp: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&tmp, "{e:.[1]}", .{ v, prec - 1 }) catch return;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e') orelse return;
    const exp = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch return;
    if (exp < -4 or exp >= prec) {
        var mant: []const u8 = sci[0..e_at];
        if (std.mem.indexOfScalar(u8, mant, '.') != null) {
            mant = std.mem.trimEnd(u8, mant, "0");
            mant = std.mem.trimEnd(u8, mant, ".");
        }
        t.s(mant);
        t.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
        return;
    }
    const decimals: usize = @intCast(@as(i32, prec) - 1 - exp);
    const dec = std.fmt.bufPrint(&tmp, "{d:.[1]}", .{ v, decimals }) catch return;
    var out: []const u8 = dec;
    if (std.mem.indexOfScalar(u8, out, '.') != null) {
        out = std.mem.trimEnd(u8, out, "0");
        out = std.mem.trimEnd(u8, out, ".");
    }
    t.s(out);
}

fn f16bits(v: u16) f64 {
    return @floatCast(@as(f16, @bitCast(v)));
}

fn putMulti(t: *Text, s: Src, show_r: bool) void {
    if (s.kind == .gpr and s.last) t.s("(last)");
    if (s.neg and s.abs) t.s("(absneg)") else if (s.neg) t.s("(neg)") else if (s.abs) t.s("(abs)");
    if (s.bnot) t.s("(not)");
    if (show_r and s.r) t.s("(r)");
    switch (s.kind) {
        .gpr => {
            putH(t, s.half);
            putGpr(t, s.num, false);
        },
        .cnst => {
            putH(t, s.half);
            putConst(t, s.num);
        },
        .rel_gpr, .rel_cnst => {
            putH(t, s.half);
            putRel(t, s.kind == .rel_cnst, s.off, false);
        },
        .imm => {
            const v: i32 = @bitCast(s.imm);
            if (s.half) t.print("h({d})", .{v}) else t.print("{d}", .{v});
        },
        .flut => {
            if (s.half) t.s("h");
            t.s("(");
            t.s(if (s.imm < flut_names.len) flut_names[s.imm] else "?");
            t.s(")");
        },
        .none => {},
    }
}

fn putCat3Src(t: *Text, s: Src, show_r: bool) void {
    if (s.neg) t.s("(neg)");
    if (show_r and s.r) t.s("(r)");
    switch (s.kind) {
        .gpr => {
            if (s.last) t.s("(last)");
            putH(t, s.half);
            putGpr(t, s.num, false);
        },
        .cnst => {
            putH(t, s.half);
            putConst(t, s.num);
        },
        .imm => t.print("{d}", .{s.imm}),
        .rel_gpr, .rel_cnst => {
            putH(t, s.half);
            putRel(t, s.kind == .rel_cnst, s.off, true);
        },
        else => {},
    }
}

fn putCat1Src(t: *Text, in: *const Instr) void {
    const s = in.src[0];
    switch (s.kind) {
        .imm => switch (in.src_type) {
            .f16 => {
                t.s("h(");
                putFloat(t, f16bits(@truncate(s.imm)), 5);
                t.s(")");
            },
            .f32 => {
                t.s("(");
                putFloat(t, @as(f32, @bitCast(s.imm)), 9);
                t.s(")");
            },
            .u32 => if (s.imm > 0x1000) t.print("0x{x}", .{s.imm}) else t.print("{d}", .{s.imm}),
            .s16 => t.print("{d}", .{@as(i16, @bitCast(@as(u16, @truncate(s.imm))))}),
            .s32 => t.print("{d}", .{@as(i32, @bitCast(s.imm))}),
            else => t.print("{d}", .{s.imm}),
        },
        .cnst => {
            if (s.r) t.s("(r)");
            putH(t, s.half);
            putConst(t, s.num);
        },
        .gpr => {
            if (s.last) t.s("(last)");
            if (s.r) t.s("(r)");
            putH(t, s.half);
            putGpr(t, s.num, false);
        },
        .rel_gpr, .rel_cnst => {
            if (s.r) t.s("(r)");
            putH(t, s.half);
            putRel(t, s.kind == .rel_cnst, s.off, false);
        },
        else => {},
    }
}

fn putCat1Dst(t: *Text, in: *const Instr) void {
    putH(t, in.dst.half);
    if (in.dst.rel) {
        t.s("r<a0.x");
        if (in.dst.num != 0) t.print(" + {d}", .{in.dst.num});
        t.s(">");
    } else putGpr(t, in.dst.num, false);
}

fn putSync(t: *Text, in: *const Instr) void {
    if (in.sy) t.s("(sy)");
    if (in.ss) t.s("(ss)");
}

fn putOffset(t: *Text, v: i64) void {
    if (v != 0) t.print("{c}{d}", .{ @as(u8, if (v < 0) '-' else '+'), @abs(v) });
}

fn putUOffset(t: *Text, v: i64) void {
    if (v != 0) t.print("+{d}", .{v});
}

fn putCat6Src(t: *Text, s: Src) void {
    if (s.kind == .imm) t.print("{d}", .{s.imm}) else putGpr(t, s.num, false);
}

fn putA6Tail(t: *Text, in: *const Instr) void {
    t.s(".");
    t.s(@tagName(in.mode));
    if (in.bindless) t.print(".base{d}", .{in.base});
}

fn typeName(op: Op, ty: Type) []const u8 {
    const atomic = switch (op) {
        .atomic_b_add, .atomic_b_sub, .atomic_b_xchg, .atomic_b_cmpxchg, .atomic_b_min, .atomic_b_max, .atomic_b_and, .atomic_b_or, .atomic_b_xor => true,
        .atomic_g_add, .atomic_g_sub, .atomic_g_xchg, .atomic_g_inc, .atomic_g_dec, .atomic_g_cmpxchg, .atomic_g_min, .atomic_g_max, .atomic_g_and, .atomic_g_or, .atomic_g_xor => true,
        else => false,
    };
    if (atomic and ty == .u8) return "u64";
    return @tagName(ty);
}

/// Print `in` the way Mesa's disassembler does. Returns the text.
pub fn format(gen: u16, in: *const Instr, buf: []u8) Error![]const u8 {
    var t = Text{ .buf = buf };
    const layout = layoutOf(gen, in) orelse return error.NoForm;
    const nm = in.op.name();
    switch (layout) {
        .c0_0src => {
            putSync(&t, in);
            if (in.eq) t.s("(eq)");
            if (in.jp) t.s("(jp)");
            if (in.eolm) t.s("(eolm)");
            if (in.eogm) t.s("(eogm)");
            if (in.eostsc) t.s("(eostsc)");
            putRpt(&t, in.repeat);
            t.s(nm);
        },
        .c0_1src => {
            putSync(&t, in);
            if (in.eq) t.s("(eq)");
            if (in.jp) t.s("(jp)");
            t.s(nm);
            t.print(" {s}p0.{c}", .{ if (in.inv1) "!" else "", swiz[in.comp1] });
        },
        .c0_immed, .c0_brax => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            t.print("{s} #{d}", .{ nm, in.imm });
        },
        .c0_getlast => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            t.print("{s}.w8 #{d}", .{ nm, in.imm });
        },
        .c0_brac, .c0_br1, .c0_br2 => {
            putSync(&t, in);
            if (in.eq) t.s("(eq)");
            if (in.jp) t.s("(jp)");
            t.s(nm);
            switch (layout) {
                .c0_brac => t.print(".{d}", .{in.index}),
                .c0_br1 => t.print(" {s}p0.{c},", .{ if (in.inv1) "!" else "", swiz[in.comp1] }),
                else => t.print(" {s}p0.{c}, {s}p0.{c},", .{ if (in.inv1) "!" else "", swiz[in.comp1], if (in.inv2) "!" else "", swiz[in.comp2] }),
            }
            t.print(" #{d}", .{in.imm});
        },
        .c1_imm, .c1_const, .c1_gpr, .c1_relgpr, .c1_relconst, .c1_movs_imm, .c1_movs_a0 => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            putRpt(&t, in.repeat);
            if (in.ul) t.s("(ul)");
            const mova = in.op == .mov and isMova(in);
            if (mova) {
                t.s(if (in.dst.num == A0_X) "mova" else "mova1");
                if (in.u) t.s(".u");
            } else {
                t.s(if (in.op == .movs) "movs" else if (in.src_type != in.dst_type) "cov" else "mov");
                t.print(".{s}{s}", .{ @tagName(in.src_type), @tagName(in.dst_type) });
            }
            t.s(" ");
            if (in.round != .none) t.print("({s})", .{@tagName(in.round)});
            if (in.sat) t.s("(sat)");
            if (mova) t.s(if (in.dst.num == A0_X) "a0.x" else "a1.x") else putCat1Dst(&t, in);
            t.s(", ");
            putCat1Src(&t, in);
            if (layout == .c1_movs_imm) t.print(", {d}", .{in.src[1].imm});
            if (layout == .c1_movs_a0) t.s(", a0.x");
        },
        .c1_swz, .c1_gat, .c1_sct => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            if (in.ul) t.s("(ul)");
            t.print("{s}.{s}{s} ", .{ nm, @tagName(in.src_type), @tagName(in.dst_type) });
            if (in.round != .none) t.print("({s})", .{@tagName(in.round)});
            if (in.sat) t.s("(sat)");
            const dh = in.dst.half;
            const sh = in.src[0].half;
            putH(&t, dh);
            putGpr(&t, in.dst.num, false);
            switch (layout) {
                .c1_swz => {
                    t.s(", ");
                    putH(&t, dh);
                    putGpr(&t, in.dsts[0], false);
                    for (in.src[0..2]) |s| {
                        t.s(", ");
                        putH(&t, sh);
                        putGpr(&t, s.num, false);
                    }
                },
                .c1_gat => for (in.src) |s| {
                    t.s(", ");
                    putH(&t, sh);
                    putGpr(&t, s.num, false);
                },
                else => {
                    for (in.dsts) |d| {
                        t.s(", ");
                        putH(&t, dh);
                        putGpr(&t, d, false);
                    }
                    t.s(", ");
                    putH(&t, sh);
                    putGpr(&t, in.src[0].num, false);
                },
            }
        },
        .c1_movmsk => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            if (in.ul) t.s("(ul)");
            t.print("movmsk.w{d} ", .{(@as(u32, in.repeat) + 1) * 32});
            putCat1Dst(&t, in);
        },
        .c2_1src, .c2_2src, .c2_cond, .c2_input => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            const sat_first = layout == .c2_cond or layout == .c2_input;
            if (sat_first and in.sat) t.s("(sat)");
            if (in.nop != 0) t.print("(nop{d}) ", .{in.nop}) else putRpt(&t, in.repeat);
            if (in.ul) t.s("(ul)");
            t.s(nm);
            if (layout == .c2_cond) t.print(".{s}", .{@tagName(in.cond)});
            t.s(" ");
            if (!sat_first and in.sat) t.s("(sat)");
            if (in.dst.ei) t.s("(ei)");
            putH(&t, in.dst.half);
            putGpr(&t, in.dst.num, true);
            t.s(", ");
            putMulti(&t, in.src[0], in.nop == 0);
            if (layout != .c2_1src) {
                t.s(", ");
                putMulti(&t, in.src[1], in.nop == 0);
            }
        },
        .c3, .c3_alt, .c3_wmm => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            if (in.nop != 0) t.print("(nop{d}) ", .{in.nop}) else putRpt(&t, in.repeat);
            if (in.ul) t.s("(ul)");
            t.print("{s} ", .{nm});
            if (in.sat) t.s("(sat)");
            putH(&t, in.dst.half);
            putGpr(&t, in.dst.num, false);
            t.s(", ");
            putCat3Src(&t, in.src[0], in.nop == 0);
            t.s(", ");
            if (in.src[1].neg) t.s("(neg)");
            if (in.nop == 0 and in.src[1].r) t.s("(r)");
            putH(&t, in.src[1].half);
            putGpr(&t, in.src[1].num, false);
            t.s(", ");
            putCat3Src(&t, in.src[2], in.nop == 0);
        },
        .c3_dp => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            if (in.nop != 0) t.print("(nop{d}) ", .{in.nop});
            if (in.ul) t.s("(ul)");
            t.print("{s}{s}{s} ", .{ nm, if (in.mixed) ".mixed" else ".unsigned", if (in.high) ".high" else ".low" });
            if (in.sat) t.s("(sat)");
            putGpr(&t, in.dst.num, false);
            t.s(", ");
            var s1 = in.src[0];
            s1.half = false;
            putCat3Src(&t, s1, in.nop == 0);
            t.s(", ");
            if (in.nop == 0 and in.src[1].r) t.s("(r)");
            putGpr(&t, in.src[1].num, false);
            t.s(", ");
            var s3 = in.src[2];
            s3.half = false;
            putCat3Src(&t, s3, true);
        },
        .c5_tex => {
            if (in.sy) t.s("(sy)");
            if (in.jp) t.s("(jp)");
            t.print("{s} ({s})(", .{ nm, @tagName(in.ty) });
            for (swiz, 0..) |c, k| {
                if (in.wrmask >> @intCast(k) & 1 != 0) t.s(&[_]u8{c});
            }
            t.s(")");
            putH(&t, in.dst.half);
            putGpr(&t, in.dst.num, false);
            t.s(", ");
            putH(&t, in.src[0].half);
            putGpr(&t, in.src[0].num, false);
            t.print(", s#{d}, t#{d}", .{ in.samp, in.tex });
        },
        .c4 => {
            putSync(&t, in);
            if (in.jp) t.s("(jp)");
            if (in.sat) t.s("(sat)");
            putRpt(&t, in.repeat);
            if (in.ul) t.s("(ul)");
            t.print("{s} ", .{nm});
            putH(&t, in.dst.half);
            putGpr(&t, in.dst.num, false);
            t.s(", ");
            putMulti(&t, in.src[0], true);
        },
        else => try formatCat67(&t, in, layout, nm),
    }
    if (t.overflow) return error.BufferTooSmall;
    return t.text();
}

fn formatCat67(t: *Text, in: *const Instr, layout: Layout, nm: []const u8) Error!void {
    if (in.op.category() == 7) putSync(t, in) else if (in.sy) t.s("(sy)");
    if (in.jp) t.s("(jp)");
    const ty = typeName(in.op, in.ty);
    switch (layout) {
        .c6_ldg, .c6_ldg_a6, .c6_ldg_a7 => {
            t.print("{s}.{s} ", .{ nm, ty });
            putH(t, in.ty.half());
            putGpr(t, in.dst.num, false);
            t.s(", g[");
            putAddr(t, in.src[0]);
            try putGlobalOffset(t, in, layout);
            t.print("], {d}", .{in.size});
        },
        .c6_ldg_k => {
            t.print("{s}.{s} c[", .{ nm, ty });
            if (in.a1) {
                t.s("a1.x");
                putUOffset(t, in.dst.num);
            } else t.print("{d}", .{in.dst.num});
            t.s("], g[");
            putGpr(t, in.src[0].num, false);
            putOffset(t, in.off);
            t.s("], ");
            if (in.src[1].kind == .gpr) putGpr(t, in.src[1].num, false) else t.print("{d}", .{in.size});
        },
        .c6_stg, .c6_stg_a6, .c6_stg_a7 => {
            t.print("{s}.{s} g[", .{ nm, ty });
            putAddr(t, in.src[0]);
            try putGlobalOffset(t, in, layout);
            t.s("], ");
            putH(t, in.ty.half());
            putGpr(t, in.src[2].num, false);
            t.print(", {d}", .{in.size});
        },
        .c6_ld => {
            t.print("{s}.{s} ", .{ nm, ty });
            putH(t, in.ty.half());
            putGpr(t, in.dst.num, false);
            t.s(if (in.op == .ldp) ", p[" else ", l[");
            putGpr(t, in.src[0].num, false);
            putOffset(t, in.off);
            t.print("], {d}", .{in.size});
        },
        .c6_ldlv => {
            t.print("{s}.{s} ", .{ nm, ty });
            putH(t, in.ty.half());
            putGpr(t, in.dst.num, false);
            t.print(", l[{d}], {d}", .{ in.off, in.size });
        },
        .c6_st => {
            t.print("{s}.{s} {s}", .{ nm, ty, if (in.op == .stp) "p[" else "l[" });
            putGpr(t, in.src[0].num, false);
            putOffset(t, in.off);
            t.s("], ");
            putH(t, in.ty.half());
            putGpr(t, in.src[1].num, false);
            t.print(", {d}", .{in.size});
        },
        .c6_stc => {
            t.print("{s}.{s} c[", .{ nm, ty });
            if (in.a1) {
                t.s("a1.x");
                putUOffset(t, in.off);
            } else t.print("{d}", .{in.off});
            t.s("], ");
            putGpr(t, in.src[0].num, false);
            t.print(", {d}", .{in.size});
        },
        .c6_stsc => t.print("{s}.{s} c[{d}], {d}, {d}", .{ nm, ty, in.off, in.src[0].imm, in.size }),
        .c6_ldc => {
            t.s("ldc");
            if (in.u) t.s(".u");
            t.print(".offset{d}.{d}", .{ in.off, in.type_size });
            putA6Tail(t, in);
            t.s(" ");
            putGpr(t, in.dst.num, false);
            t.s(", ");
            putCat6Src(t, in.src[0]);
            t.s(", ");
            putCat6Src(t, in.src[1]);
        },
        .c6_ldc_k => {
            t.print("ldc.{d}.k", .{in.size});
            putA6Tail(t, in);
            t.s(" c[a1.x], ");
            putCat6Src(t, in.src[0]);
            t.s(", ");
            putCat6Src(t, in.src[1]);
        },
        .c6_getid => {
            t.print("{s}.{s} ", .{ nm, ty });
            putGpr(t, in.dst.num, false);
        },
        .c6_ibo1src => {
            t.print("{s}.{s}.{d}d.{s}.{d}", .{ nm, if (in.typed) "typed" else "untyped", in.d, ty, in.type_size });
            putA6Tail(t, in);
            t.s(" ");
            putGpr(t, in.dst.num, false);
            t.s(", ");
            putCat6Src(t, in.src[0]);
        },
        .c6_ibo_ls => {
            t.print("{s}.{s}.{d}d.{s}{s}.{d}", .{ nm, if (in.typed) "typed" else "untyped", in.d, ty, if (in.rck) ".rck" else "", in.type_size });
            putA6Tail(t, in);
            t.s(" ");
            putH(t, in.ty.half());
            putGpr(t, if (in.op == .ldib_b) in.dst.num else in.src[2].num, false);
            t.s(", ");
            putGpr(t, in.src[0].num, false);
            if (in.has_offset) putUOffset(t, in.off);
            t.s(", ");
            putCat6Src(t, in.src[1]);
        },
        .c6_ibo_atomic => {
            t.print("{s}.{s}.{d}d.{s}.{d}", .{ nm, if (in.typed) "typed" else "untyped", in.d, ty, in.type_size });
            putA6Tail(t, in);
            t.s(" ");
            putGpr(t, in.src[2].num, false);
            t.s(", ");
            putGpr(t, in.src[0].num, false);
            t.s(", ");
            putCat6Src(t, in.src[1]);
        },
        .c6_atomic_g, .c6_atomic_l => {
            const g = layout == .c6_atomic_g;
            t.print("{s}.{s}.{d}d.{s}.{d}.{s} ", .{ nm, if (in.typed) "typed" else "untyped", in.d, ty, in.type_size, if (g) "g" else "l" });
            putGpr(t, in.dst.num, false);
            t.s(if (g) ", " else ", l[");
            putCat6Src(t, in.src[0]);
            t.s(if (g) ", " else "], ");
            putCat6Src(t, in.src[1]);
        },
        .c6_shfl => {
            t.print("shfl.{s}.{s} ", .{ @tagName(in.shfl), ty });
            putH(t, in.ty.half());
            putGpr(t, in.dst.num, false);
            t.s(", ");
            putH(t, in.ty.half());
            putGpr(t, in.src[0].num, false);
            t.s(", ");
            putCat6Src(t, in.src[1]);
        },
        .c7_barrier => {
            t.s(nm);
            if (in.g) t.s(".g");
            if (in.l) t.s(".l");
            if (in.r) t.s(".r");
            if (in.w) t.s(".w");
        },
        .c7_sleep => t.print("{s}{s}", .{ nm, if (in.long) ".l" else ".s" }),
        .c7_data => t.print("{s}{s}", .{ nm, if (in.long) ".all" else ".shr" }),
        .c7_plain => t.s(nm),
        else => return error.NoForm,
    }
}

fn putAddr(t: *Text, s: Src) void {
    if (s.kind == .cnst) putConst(t, s.num) else putGpr(t, s.num, false);
}

fn putGlobalOffset(t: *Text, in: *const Instr, layout: Layout) Error!void {
    switch (layout) {
        .c6_ldg, .c6_stg => putOffset(t, in.off),
        .c6_ldg_a7, .c6_stg_a7 => {
            t.s("+");
            putGpr(t, in.src[1].num, false);
            t.print("+{d}", .{in.off});
        },
        .c6_ldg_a6, .c6_stg_a6 => {
            // g[SRC1+(((SRC2<<SRC2_SHIFT)+OFF)<<TYPE_SHIFT)] and its shorter forms.
            const tshift: u8 = if (@intFromEnum(in.ty) >= 6) 0 else if (in.ty.half()) 1 else 2;
            t.s("+");
            if (tshift == 0) {
                putGpr(t, in.src[1].num, false);
                putUOffset(t, in.off);
            } else if (in.off == 0) {
                t.s("(");
                putGpr(t, in.src[1].num, false);
                t.print("<<{d})", .{in.shift + tshift});
            } else if (in.shift == 0) {
                t.s("((");
                putGpr(t, in.src[1].num, false);
                putUOffset(t, in.off);
                t.print(")<<{d})", .{tshift});
            } else {
                t.s("(((");
                putGpr(t, in.src[1].num, false);
                t.print("<<{d})", .{in.shift});
                putUOffset(t, in.off);
                t.print(")<<{d})", .{tshift});
            }
        },
        else => return error.NoForm,
    }
}

// ── Parsing ─────────────────────────────────────────────────────────────────

const Lex = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(l: *Lex) void {
        while (l.i < l.s.len and (l.s[l.i] == ' ' or l.s[l.i] == '\t')) l.i += 1;
    }
    fn eat(l: *Lex, lit: []const u8) bool {
        l.ws();
        if (std.mem.startsWith(u8, l.s[l.i..], lit)) {
            l.i += lit.len;
            return true;
        }
        return false;
    }
    fn expect(l: *Lex, lit: []const u8) Error!void {
        if (!l.eat(lit)) return error.Syntax;
    }
    fn peek(l: *Lex) u8 {
        l.ws();
        return if (l.i < l.s.len) l.s[l.i] else 0;
    }
    fn done(l: *Lex) bool {
        l.ws();
        return l.i >= l.s.len;
    }
    fn int(l: *Lex) Error!i64 {
        l.ws();
        const start = l.i;
        if (l.i < l.s.len and (l.s[l.i] == '-' or l.s[l.i] == '+')) l.i += 1;
        if (std.mem.startsWith(u8, l.s[l.i..], "0x") or std.mem.startsWith(u8, l.s[l.i..], "0X")) {
            l.i += 2;
            while (l.i < l.s.len and std.ascii.isHex(l.s[l.i])) l.i += 1;
        } else {
            while (l.i < l.s.len and std.ascii.isDigit(l.s[l.i])) l.i += 1;
        }
        if (l.i == start) return error.Syntax;
        return std.fmt.parseInt(i64, l.s[start..l.i], 0) catch error.Syntax;
    }
    fn word(l: *Lex) []const u8 {
        l.ws();
        const start = l.i;
        while (l.i < l.s.len and (std.ascii.isAlphanumeric(l.s[l.i]) or l.s[l.i] == '_' or l.s[l.i] == '.')) l.i += 1;
        return l.s[start..l.i];
    }
    fn wordNoDot(l: *Lex) []const u8 {
        const start = l.i;
        while (l.i < l.s.len and (std.ascii.isAlphanumeric(l.s[l.i]) or l.s[l.i] == '_')) l.i += 1;
        return l.s[start..l.i];
    }
};

/// A register: [h]rN.c / [h]cN.c / a0.x / a1.x / p0.c / up0.c / r<a0.x + N>.
const RegTok = struct { kind: Src.Kind, num: u16 = 0, off: i16 = 0, half: bool = false };

fn parseReg(l: *Lex) Error!RegTok {
    l.ws();
    var half = false;
    if (l.peek() == 'h' and l.i + 1 < l.s.len and (l.s[l.i + 1] == 'r' or l.s[l.i + 1] == 'c')) {
        half = true;
        l.i += 1;
    }
    // up0.c: a cat2 destination encoded as a0.c (the scalar ALU writes p0.c).
    if (l.eat("up0.")) return .{ .kind = .gpr, .num = A0_X + try comp(l), .half = half };
    if (l.eat("p0.")) return .{ .kind = .gpr, .num = P0_X + try comp(l), .half = half };
    if (l.eat("a0.")) return .{ .kind = .gpr, .num = A0_X + try comp(l), .half = half };
    if (l.eat("a1.x")) return .{ .kind = .gpr, .num = A1_X, .half = half };
    const c = l.peek();
    if (c != 'r' and c != 'c') return error.Syntax;
    l.i += 1;
    if (l.eat("<a0.x")) {
        var off: i64 = 0;
        if (l.eat("+")) off = try l.int();
        try l.expect(">");
        return .{ .kind = if (c == 'c') .rel_cnst else .rel_gpr, .off = @intCast(off), .half = half };
    }
    const n = try l.int();
    if (n < 0) return error.Syntax;
    try l.expect(".");
    const cmp = try comp(l);
    return .{ .kind = if (c == 'c') .cnst else .gpr, .num = @intCast((n << 2) | cmp), .half = half };
}

fn comp(l: *Lex) Error!u16 {
    if (l.i >= l.s.len) return error.Syntax;
    const idx = std.mem.indexOfScalar(u8, swiz, l.s[l.i]) orelse return error.Syntax;
    l.i += 1;
    return @intCast(idx);
}

/// A source operand with its modifiers, as cat1-4 print them.
fn parseSrc(l: *Lex) Error!Src {
    var s = Src{};
    while (true) {
        if (l.eat("(last)")) s.last = true else if (l.eat("(absneg)")) {
            s.abs = true;
            s.neg = true;
        } else if (l.eat("(neg)")) s.neg = true else if (l.eat("(abs)")) s.abs = true else if (l.eat("(not)")) s.bnot = true else if (l.eat("(r)")) s.r = true else break;
    }
    l.ws();
    // Immediates: h(...), (...), integers.
    var half = false;
    if (l.peek() == 'h' and l.i + 1 < l.s.len and l.s[l.i + 1] == '(') {
        half = true;
        l.i += 1;
    }
    if (l.peek() == '(') {
        l.i += 1;
        const start = l.i;
        var depth: usize = 1;
        while (l.i < l.s.len) : (l.i += 1) {
            if (l.s[l.i] == '(') depth += 1;
            if (l.s[l.i] == ')') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (l.i >= l.s.len) return error.Syntax;
        const body = l.s[start..l.i];
        l.i += 1;
        s.half = half;
        for (flut_names, 0..) |fname, k| {
            if (std.mem.eql(u8, body, fname)) {
                s.kind = .flut;
                s.imm = @intCast(k);
                return s;
            }
        }
        if (std.mem.startsWith(u8, body, "0x")) {
            s.kind = .imm;
            s.imm = @truncate(@as(u64, @bitCast(std.fmt.parseInt(i64, body, 0) catch return error.Syntax)));
            return s;
        }
        if (std.mem.indexOfAny(u8, body, ".en") != null) {
            const v = std.fmt.parseFloat(f32, body) catch return error.Syntax;
            s.kind = .imm;
            s.imm = if (half) @as(u16, @bitCast(@as(f16, @floatCast(v)))) else @bitCast(v);
            // (a float written where an integer goes is the half's int: h(-1))
            return s;
        }
        const v = std.fmt.parseInt(i64, body, 0) catch return error.Syntax;
        s.kind = .imm;
        s.imm = @truncate(@as(u64, @bitCast(v)));
        s.half = half;
        return s;
    }
    if (std.ascii.isDigit(l.peek()) or l.peek() == '-') {
        const v = try l.int();
        s.kind = .imm;
        s.imm = @truncate(@as(u64, @bitCast(v)));
        return s;
    }
    const r = try parseReg(l);
    s.kind = r.kind;
    s.num = r.num;
    s.off = r.off;
    s.half = r.half;
    return s;
}

fn parseType(l: *Lex) Error!Type {
    inline for (.{ "u8_32", "f16", "f32", "u16", "u32", "s16", "s32", "u8", "u64" }) |nm| {
        if (std.mem.startsWith(u8, l.s[l.i..], nm)) {
            l.i += nm.len;
            return if (comptime std.mem.eql(u8, nm, "u64")) .u8 else @field(Type, nm);
        }
    }
    return error.Syntax;
}

fn parseDst(l: *Lex, in: *Instr) Error!void {
    while (true) {
        if (l.eat("(ei)")) in.dst.ei = true else if (l.eat("(sat)")) in.sat = true else break;
    }
    const r = try parseReg(l);
    switch (r.kind) {
        .gpr => in.dst = .{ .num = r.num, .half = r.half, .ei = in.dst.ei },
        .rel_gpr => in.dst = .{ .num = @intCast(r.off), .half = r.half, .rel = true },
        else => return error.Syntax,
    }
}

fn mnemonicOp(m: []const u8) ?Op {
    var best: ?Op = null;
    var best_len: usize = 0;
    inline for (@typeInfo(Op).@"enum".field_values) |value| {
        const op: Op = @enumFromInt(value);
        const nm = op.name();
        if (nm.len > best_len and std.mem.startsWith(u8, m, nm) and (m.len == nm.len or m[nm.len] == '.')) {
            best = op;
            best_len = nm.len;
        }
    }
    return best;
}

/// Parse one instruction in Mesa's disassembly syntax.
pub fn parse(gen: u16, line: []const u8) Error!Instr {
    var l = Lex{ .s = line };
    var in = Instr{};
    // Prefix flags.
    while (true) {
        if (l.eat("(sy)")) in.sy = true else if (l.eat("(ss)")) in.ss = true else if (l.eat("(jp)")) in.jp = true else if (l.eat("(eq)")) in.eq = true else if (l.eat("(ul)")) in.ul = true else if (l.eat("(sat)")) in.sat = true else if (l.eat("(eolm)")) in.eolm = true else if (l.eat("(eogm)")) in.eogm = true else if (l.eat("(eostsc)")) in.eostsc = true else if (l.eat("(rpt")) {
            in.repeat = @intCast(try l.int());
            try l.expect(")");
        } else if (l.eat("(nop")) {
            in.nop = @intCast(try l.int());
            try l.expect(")");
        } else break;
    }
    const m = l.word();
    if (m.len == 0) return error.Syntax;
    // The cat1 spellings.
    if (std.mem.startsWith(u8, m, "mova")) {
        const one = std.mem.startsWith(u8, m, "mova1");
        in.op = .mov;
        in.u = std.mem.endsWith(u8, m, ".u");
        in.src_type = if (one) .u16 else .s16;
        in.dst_type = in.src_type;
        try parseCat1Mods(&l, &in);
        _ = try parseReg(&l);
        in.dst = .{ .num = if (one) A1_X else A0_X };
        try l.expect(",");
        in.src[0] = try parseSrc(&l);
        if (in.src[0].kind == .imm and in.u) in.src[0].r = false;
        return finish(gen, &l, &in);
    }
    if (std.mem.startsWith(u8, m, "mov.") or std.mem.startsWith(u8, m, "cov.") or std.mem.startsWith(u8, m, "movs.")) {
        in.op = if (m[3] == 's') .movs else .mov;
        var sl = Lex{ .s = m, .i = if (in.op == .movs) 5 else 4 };
        in.src_type = try parseType(&sl);
        in.dst_type = try parseType(&sl);
        if (!sl.done()) return error.Syntax;
        try parseCat1Mods(&l, &in);
        try parseDst(&l, &in);
        in.dst.half = in.dst_type.halfCat1();
        try l.expect(",");
        in.src[0] = try parseSrc(&l);
        if (in.src[0].kind == .imm or in.src[0].kind == .flut) try cat1Imm(&in);
        if (in.op == .movs) {
            try l.expect(",");
            if (l.eat("a0.x")) in.src[1] = Src.gpr(A0_X) else in.src[1] = Src.immed(@intCast(try l.int()));
        }
        return finish(gen, &l, &in);
    }
    const op = mnemonicOp(m) orelse return error.Syntax;
    in.op = op;
    var sfx = Lex{ .s = m, .i = op.name().len };
    switch (op.category()) {
        0 => try parseCat0(&l, &sfx, &in),
        1 => try parseCat1Multi(&l, &sfx, &in),
        2 => try parseCat2(&l, &sfx, &in),
        3 => try parseCat3(&l, &sfx, &in),
        4 => {
            if (!sfx.done()) return error.Syntax;
            try parseDst(&l, &in);
            try l.expect(",");
            in.src[0] = try parseSrc(&l);
        },
        5 => {
            if (!sfx.done()) return error.Syntax;
            try l.expect("(");
            in.ty = try parseType(&l);
            try l.expect(")");
            try l.expect("(");
            in.wrmask = 0;
            while (!l.eat(")")) in.wrmask |= @as(u4, 1) << @intCast(try comp(&l));
            const d = try parseReg(&l);
            if (d.kind != .gpr) return error.Syntax;
            in.dst = .{ .num = d.num, .half = d.half };
            try l.expect(",");
            const c = try parseReg(&l);
            if (c.kind != .gpr) return error.Syntax;
            in.src[0] = .{ .kind = .gpr, .num = c.num, .half = c.half };
            try l.expect(",");
            try l.expect("s#");
            in.samp = @intCast(try l.int());
            try l.expect(",");
            try l.expect("t#");
            in.tex = @intCast(try l.int());
        },
        6 => try parseCat6(&l, &sfx, &in),
        7 => try parseCat7(&sfx, &in),
    }
    return finish(gen, &l, &in);
}

fn finish(gen: u16, l: *Lex, in: *Instr) Error!Instr {
    _ = gen;
    if (!l.done()) return error.Syntax;
    return in.*;
}

fn parseCat1Mods(l: *Lex, in: *Instr) Error!void {
    while (true) {
        if (l.eat("(sat)")) in.sat = true else if (l.eat("(even)")) in.round = .even else if (l.eat("(pos_infinity)")) in.round = .pos_infinity else if (l.eat("(neg_infinity)")) in.round = .neg_infinity else break;
    }
}

/// A cat1 immediate in the source type's own notation.
fn cat1Imm(in: *Instr) Error!void {
    const s = &in.src[0];
    s.half = false;
    if (s.kind == .flut) {
        // "(0.5)" is a plain float here, not the cat2/cat4 table.
        const vals = [_]f32{ 0.0, 0.5, 1.0, 2.0, std.math.e, std.math.pi, 1.0 / std.math.pi, 1.0 / std.math.log2e, std.math.log2e, 1.0 / std.math.log2(10.0), std.math.log2(10.0), 4.0 };
        const v = vals[s.imm];
        s.kind = .imm;
        s.imm = if (in.src_type == .f16) @as(u16, @bitCast(@as(f16, @floatCast(v)))) else @bitCast(v);
        return;
    }
    if (in.src_type == .f16 or in.src_type == .s16 or in.src_type == .u16) s.imm &= 0xffff;
}

fn parseCat0(l: *Lex, sfx: *Lex, in: *Instr) Error!void {
    switch (in.op) {
        .brac => {
            try sfx.expect(".");
            in.index = @intCast(try sfx.int());
        },
        .getlast => try sfx.expect(".w8"),
        else => {},
    }
    if (!sfx.done()) return error.Syntax;
    switch (in.op) {
        .kill, .br, .bany, .ball, .brao, .braa => {
            in.inv1 = l.eat("!");
            try l.expect("p0.");
            in.comp1 = @intCast(try comp(l));
            if (in.op == .kill) return;
            try l.expect(",");
            if (in.op == .brao or in.op == .braa) {
                in.inv2 = l.eat("!");
                try l.expect("p0.");
                in.comp2 = @intCast(try comp(l));
                try l.expect(",");
            }
        },
        else => {},
    }
    switch (in.op) {
        .jump, .call, .bkt, .getone, .shps, .getlast, .brac, .brax, .br, .bany, .ball, .brao, .braa => {
            try l.expect("#");
            in.imm = @intCast(try l.int());
        },
        else => {},
    }
}

fn parseCat1Multi(l: *Lex, sfx: *Lex, in: *Instr) Error!void {
    if (in.op == .movmsk) {
        try sfx.expect(".w");
        const wbits = try sfx.int();
        if (wbits < 32 or @mod(wbits, 32) != 0) return error.Syntax;
        in.repeat = @intCast(@divExact(wbits, 32) - 1);
        in.src_type = .u32;
        in.dst_type = .u32;
        try parseDst(l, in);
        return;
    }
    try sfx.expect(".");
    in.src_type = try parseType(sfx);
    in.dst_type = try parseType(sfx);
    if (!sfx.done()) return error.Syntax;
    try parseCat1Mods(l, in);
    const ndst: usize = switch (in.op) {
        .swz => 2,
        .gat => 1,
        else => 4,
    };
    const nsrc: usize = switch (in.op) {
        .swz => 2,
        .gat => 4,
        else => 1,
    };
    for (0..ndst) |k| {
        if (k != 0) try l.expect(",");
        const r = try parseReg(l);
        if (k == 0) in.dst = .{ .num = r.num, .half = r.half } else in.dsts[k - 1] = r.num;
    }
    for (0..nsrc) |k| {
        try l.expect(",");
        const r = try parseReg(l);
        in.src[k] = .{ .kind = .gpr, .num = r.num, .half = r.half };
    }
}

fn parseCat2(l: *Lex, sfx: *Lex, in: *Instr) Error!void {
    const fm = findForm(0xffff, in) orelse findForm(600, in) orelse return error.Syntax;
    if (fm.layout == .c2_cond) {
        try sfx.expect(".");
        const c = sfx.word();
        in.cond = std.meta.stringToEnum(Cond, c) orelse return error.Syntax;
    }
    if (!sfx.done()) return error.Syntax;
    try parseDst(l, in);
    try l.expect(",");
    in.src[0] = try parseSrc(l);
    if (fm.layout != .c2_1src) {
        try l.expect(",");
        in.src[1] = try parseSrc(l);
    }
    // An immediate takes the instruction's precision.
    const h = for (in.src[0..2]) |s| {
        if (s.kind == .gpr or s.kind == .cnst or s.kind == .rel_gpr or s.kind == .rel_cnst) break s.half;
    } else in.src[0].half;
    for (in.src[0..2]) |*s| if (s.kind == .imm or s.kind == .flut) {
        s.half = h;
    };
}

fn parseCat3(l: *Lex, sfx: *Lex, in: *Instr) Error!void {
    if (in.op == .dp2acc or in.op == .dp4acc) {
        if (sfx.eat(".mixed")) in.mixed = true else try sfx.expect(".unsigned");
        if (sfx.eat(".high")) in.high = true else try sfx.expect(".low");
    }
    if (!sfx.done()) return error.Syntax;
    try parseDst(l, in);
    for (0..3) |k| {
        try l.expect(",");
        in.src[k] = try parseSrc(l);
    }
    const full = switch (in.op) {
        .dp2acc, .dp4acc => true,
        .shrm, .shlm, .shrg, .shlg, .andg, .wmm, .wmm_accu => !in.src[1].half,
        else => cat3Full(in.op),
    };
    for (&in.src) |*s| {
        if (s.kind != .none) s.half = !full;
    }
    if (in.op == .dp2acc or in.op == .dp4acc) in.dst.half = false;
}

fn parseA6Tail(sfx: *Lex, in: *Instr) Error!void {
    try sfx.expect(".");
    const md = sfx.wordNoDot();
    in.mode = std.meta.stringToEnum(Mode, md) orelse return error.Syntax;
    if (sfx.eat(".base")) {
        in.bindless = true;
        in.base = @intCast(try sfx.int());
    }
}

fn parseTypedD(sfx: *Lex, in: *Instr) Error!void {
    if (sfx.eat(".typed")) in.typed = true else try sfx.expect(".untyped");
    try sfx.expect(".");
    in.d = @intCast(try sfx.int());
    try sfx.expect("d.");
    in.ty = try parseType(sfx);
}

fn parseMem(l: *Lex, open: []const u8) Error!Src {
    try l.expect(open);
    const r = try parseReg(l);
    return switch (r.kind) {
        .gpr => Src.gpr(r.num),
        .cnst => Src.cnst(r.num),
        else => error.Syntax,
    };
}

fn parseCat6(l: *Lex, sfx: *Lex, in: *Instr) Error!void {
    switch (in.op) {
        .ldg, .ldg_a, .ldg_k, .stg, .stg_a, .ldl, .ldp, .ldlw, .ldlv, .stl, .stp, .stlw, .stc, .stsc, .getspid, .getwid, .getfiberid => {
            try sfx.expect(".");
            in.ty = try parseType(sfx);
            if (!sfx.done()) return error.Syntax;
        },
        else => {},
    }
    switch (in.op) {
        .ldg, .ldg_a => {
            try parseDst(l, in);
            try l.expect(",");
            in.src[0] = try parseMem(l, "g[");
            if (in.op == .ldg) in.off = @intCast(try optOffset(l)) else try parseGlobalA(l, in);
            try l.expect("]");
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .stg, .stg_a => {
            in.src[0] = try parseMem(l, "g[");
            if (in.op == .stg) in.off = @intCast(try optOffset(l)) else try parseGlobalA(l, in);
            try l.expect("]");
            try l.expect(",");
            in.src[2] = .{ .kind = .gpr, .num = (try parseReg(l)).num, .half = in.ty.half() };
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .ldg_k => {
            try l.expect("c[");
            if (l.eat("a1.x")) {
                in.a1 = true;
                in.dst.num = @intCast(try optOffset(l));
            } else in.dst.num = @intCast(try l.int());
            try l.expect("]");
            try l.expect(",");
            in.src[0] = try parseMem(l, "g[");
            in.off = @intCast(try optOffset(l));
            try l.expect("]");
            try l.expect(",");
            if (l.peek() == 'r') in.src[1] = Src.gpr((try parseReg(l)).num) else in.size = @intCast(try l.int());
        },
        .ldl, .ldp, .ldlw => {
            try parseDst(l, in);
            try l.expect(",");
            in.src[0] = try parseMem(l, if (in.op == .ldp) "p[" else "l[");
            in.off = @intCast(try optOffset(l));
            try l.expect("]");
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .ldlv => {
            try parseDst(l, in);
            try l.expect(",");
            try l.expect("l[");
            in.off = @intCast(try l.int());
            try l.expect("]");
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .stl, .stp, .stlw => {
            in.src[0] = try parseMem(l, if (in.op == .stp) "p[" else "l[");
            in.off = @intCast(try optOffset(l));
            try l.expect("]");
            try l.expect(",");
            in.src[1] = .{ .kind = .gpr, .num = (try parseReg(l)).num, .half = in.ty.half() };
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .stc, .stsc => {
            try l.expect("c[");
            if (l.eat("a1.x")) {
                in.a1 = true;
                in.off = @intCast(try optOffset(l));
            } else in.off = @intCast(try l.int());
            try l.expect("]");
            try l.expect(",");
            in.src[0] = if (in.op == .stsc) Src.immed(@intCast(try l.int())) else Src.gpr((try parseReg(l)).num);
            try l.expect(",");
            in.size = @intCast(try l.int());
        },
        .ldc => {
            in.op = .ldc;
            if (std.mem.indexOf(u8, sfx.s, ".k.") != null) {
                in.op = .ldc_k;
                try sfx.expect(".");
                in.size = @intCast(try sfx.int());
                try sfx.expect(".k");
                try parseA6Tail(sfx, in);
                if (!sfx.done()) return error.Syntax;
                try l.expect("c[a1.x]");
            } else {
                if (sfx.eat(".u")) in.u = true;
                try sfx.expect(".offset");
                in.off = @intCast(try sfx.int());
                try sfx.expect(".");
                in.type_size = @intCast(try sfx.int());
                try parseA6Tail(sfx, in);
                if (!sfx.done()) return error.Syntax;
                try parseDst(l, in);
            }
            try l.expect(",");
            in.src[0] = try parseCat6Src(l);
            try l.expect(",");
            in.src[1] = try parseCat6Src(l);
        },
        .getspid, .getwid, .getfiberid => try parseDst(l, in),
        .resinfo_b, .resbase => {
            try parseTypedD(sfx, in);
            try sfx.expect(".");
            in.type_size = @intCast(try sfx.int());
            try parseA6Tail(sfx, in);
            if (!sfx.done()) return error.Syntax;
            try parseDst(l, in);
            try l.expect(",");
            in.src[0] = try parseCat6Src(l);
        },
        .ldib_b, .stib_b => {
            try parseTypedD(sfx, in);
            if (sfx.eat(".rck")) in.rck = true;
            try sfx.expect(".");
            in.type_size = @intCast(try sfx.int());
            try parseA6Tail(sfx, in);
            if (!sfx.done()) return error.Syntax;
            const r = try parseReg(l);
            if (in.op == .ldib_b) in.dst = .{ .num = r.num, .half = in.ty.half() } else in.src[2] = .{ .kind = .gpr, .num = r.num, .half = in.ty.half() };
            try l.expect(",");
            in.src[0] = Src.gpr((try parseReg(l)).num);
            if (l.eat("+")) {
                in.has_offset = true;
                in.off = @intCast(try l.int());
            }
            try l.expect(",");
            in.src[1] = try parseCat6Src(l);
        },
        .shfl => {
            try sfx.expect(".");
            in.shfl = std.meta.stringToEnum(Shfl, sfx.wordNoDot()) orelse return error.Syntax;
            try sfx.expect(".");
            in.ty = try parseType(sfx);
            if (!sfx.done()) return error.Syntax;
            try parseDst(l, in);
            try l.expect(",");
            in.src[0] = .{ .kind = .gpr, .num = (try parseReg(l)).num, .half = in.ty.half() };
            try l.expect(",");
            in.src[1] = try parseCat6Src(l);
        },
        else => {
            // atomics
            try parseTypedD(sfx, in);
            try sfx.expect(".");
            in.type_size = @intCast(try sfx.int());
            const b = @intFromEnum(in.op) >= @intFromEnum(Op.atomic_b_add) and @intFromEnum(in.op) <= @intFromEnum(Op.atomic_b_xor);
            const g = @intFromEnum(in.op) >= @intFromEnum(Op.atomic_g_add) and @intFromEnum(in.op) <= @intFromEnum(Op.atomic_g_xor);
            if (b) {
                try parseA6Tail(sfx, in);
                if (!sfx.done()) return error.Syntax;
                in.src[2] = Src.gpr((try parseReg(l)).num);
                try l.expect(",");
                in.src[0] = Src.gpr((try parseReg(l)).num);
                try l.expect(",");
                in.src[1] = try parseCat6Src(l);
            } else {
                try sfx.expect(if (g) ".g" else ".l");
                if (!sfx.done()) return error.Syntax;
                try parseDst(l, in);
                try l.expect(",");
                if (!g) try l.expect("l[");
                in.src[0] = try parseCat6Src(l);
                if (!g) try l.expect("]");
                try l.expect(",");
                in.src[1] = try parseCat6Src(l);
            }
        },
    }
}

fn parseCat6Src(l: *Lex) Error!Src {
    l.ws();
    if (std.ascii.isDigit(l.peek())) return Src.immed(@intCast(try l.int()));
    return Src.gpr((try parseReg(l)).num);
}

fn optOffset(l: *Lex) Error!i64 {
    const c = l.peek();
    if (c == '+' or c == '-') return l.int();
    return 0;
}

/// The address forms of ldg.a/stg.a: a7xx g[b+r+N], a6xx the shifted forms.
fn parseGlobalA(l: *Lex, in: *Instr) Error!void {
    try l.expect("+");
    if (l.peek() == 'r') {
        in.src[1] = Src.gpr((try parseReg(l)).num);
        if (l.eat("+")) {
            in.off = @intCast(try l.int());
            // a6xx: "+N" here is an unshifted offset only for byte types.
        }
        return;
    }
    // a6xx: (r<<s), ((r+o)<<s), (((r<<s2)+o)<<s)
    var opens: usize = 0;
    while (l.eat("(")) opens += 1;
    in.src[1] = Src.gpr((try parseReg(l)).num);
    var shifts: [2]u8 = .{ 0, 0 };
    var nshift: usize = 0;
    var off: i64 = 0;
    while (opens > 0) : (opens -= 1) {
        if (l.eat("<<")) {
            shifts[nshift] = @intCast(try l.int());
            nshift += 1;
        } else if (l.eat("+")) {
            off = try l.int();
            if (l.eat("<<")) {
                // ((r+o)<<s): fallthrough handled below
                shifts[nshift] = @intCast(try l.int());
                nshift += 1;
            }
        }
        try l.expect(")");
        if (l.eat("+")) {
            off = try l.int();
        }
        if (l.eat("<<")) {
            shifts[nshift] = @intCast(try l.int());
            nshift += 1;
            try l.expect(")");
            opens -= 1;
            if (opens == 0) break;
        }
    }
    const tshift: u8 = if (@intFromEnum(in.ty) >= 6) 0 else if (in.ty.half()) 1 else 2;
    in.off = @intCast(off);
    if (off == 0) {
        // (r<<FULL_SHIFT)
        in.shift = shifts[0] -| tshift;
    } else if (nshift == 2) {
        in.shift = shifts[0];
    } else {
        in.shift = 0;
    }
}

fn parseCat7(sfx: *Lex, in: *Instr) Error!void {
    switch (in.op) {
        .bar, .fence => {
            while (!sfx.done()) {
                if (sfx.eat(".g")) in.g = true else if (sfx.eat(".l")) in.l = true else if (sfx.eat(".r")) in.r = true else if (sfx.eat(".w")) in.w = true else return error.Syntax;
            }
        },
        .sleep => {
            if (sfx.eat(".l")) in.long = true else if (!sfx.eat(".s")) {}
        },
        .dccln, .dcinv, .dcflu => {
            if (sfx.eat(".all")) in.long = true else if (!sfx.eat(".shr")) {}
        },
        else => {},
    }
    if (!sfx.done()) return error.Syntax;
}

/// Assemble a single line (encode(parse(line))).
pub fn assembleLine(gen: u16, line: []const u8) Error!u64 {
    const in = try parse(gen, line);
    return encode(gen, &in);
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn hexWord(s: []const u8) !u64 {
    // "hhhhhhhh_llllllll"
    if (s.len != 17 or s[8] != '_') return error.Syntax;
    const hi = try std.fmt.parseInt(u64, s[0..8], 16);
    const lo = try std.fmt.parseInt(u64, s[9..17], 16);
    return (hi << 32) | lo;
}

test "every form's fixed bits are disjoint within a generation" {
    for (&forms, 0..) |*a, i| {
        for (forms[i + 1 ..]) |*b| {
            const gmin = @max(a.gmin, b.gmin);
            const gmax = @min(a.gmax, b.gmax);
            if (gmin > gmax) continue;
            const common = a.mask & b.mask;
            // As in isaspec: ldib.b's bit 0 is don't-care and its offset sits
            // in the opcode bits, so a word with both could also read as
            // ldl/ldp/ldlw. Encoders write 0 there; decode reports NoMatch.
            const ibo = a.op == .ldib_b or a.op == .stib_b or b.op == .ldib_b or b.op == .stib_b;
            const other = if (a.op == .ldib_b or a.op == .stib_b) b else a;
            if (ibo and get(other.match, 54, 5) != 0) continue;
            if (a.match & common == b.match & common) {
                std.debug.print("forms overlap: {s} vs {s}\n", .{ a.op.name(), b.op.name() });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "Mesa's disassembler vectors: decode, print, parse, encode" {
    const data = @embedFile("ir3_disasm_vectors.txt");
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var failures: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        // "<gen> <hhhhhhhh_llllllll> <text>"
        var fields = std.mem.splitScalar(u8, line, ' ');
        const gen = try std.fmt.parseInt(u16, fields.next().?, 10);
        const word = try hexWord(fields.next().?);
        const text = fields.rest();
        n += 1;
        var buf: [160]u8 = undefined;
        const in = decode(gen, word) catch |e| {
            std.debug.print("decode {x:0>16} ({s}): {s}\n", .{ word, text, @errorName(e) });
            failures += 1;
            continue;
        };
        const printed = format(gen, &in, &buf) catch |e| {
            std.debug.print("format {s}: {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        if (!std.mem.eql(u8, printed, text)) {
            std.debug.print("print  {x:0>16}: got \"{s}\" want \"{s}\"\n", .{ word, printed, text });
            failures += 1;
        }
        const parsed = parse(gen, text) catch |e| {
            std.debug.print("parse  \"{s}\": {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        const enc = encode(gen, &parsed) catch |e| {
            std.debug.print("encode \"{s}\": {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        if (enc != word) {
            std.debug.print("encode \"{s}\": got {x:0>16} want {x:0>16}\n", .{ text, enc, word });
            failures += 1;
        }
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} vectors failed\n", .{ failures, n });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(n > 150);
}

test "the shift-and-mask forms refuse const sources (their bit 12 is an immediate)" {
    try std.testing.expectError(error.NoForm, assembleLine(A7XX, "shrm r0.x, c1.x, r0.y, r0.z"));
    try std.testing.expectError(error.NoForm, assembleLine(A7XX, "shlg r0.x, 8, r0.y, c1.x"));
    try std.testing.expectError(error.NoForm, assembleLine(A7XX, "andg r0.x, c0.y, r0.y, r0.z"));
    _ = try assembleLine(A7XX, "shlg r0.x, 8, r0.y, 255");
    _ = try assembleLine(A7XX, "mad.u24 r0.x, c1.x, r0.y, c2.z");
}
