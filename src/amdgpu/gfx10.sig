//! @zpm/amdgpu gfx10 — AMD's gfx10 instruction encodings (RDNA 1), as the
//! PS5's GPU runs them: LLVM calls it gfx1013 (gfx10.1 with ray tracing).
//! A PS5 shader is gfx10 machine code; this decodes it into one instruction
//! structure, and prints and encodes it back.
//!
//! The formats a vertex or pixel shader is made of: SOP1, SOP2, SOPC, SOPK,
//! SOPP, SMEM, VOP1, VOP2, VOPC, VOP3 (a and b), VINTRP, EXP, MUBUF, MTBUF
//! and MIMG (with gfx10's NSA form, the address registers in extra dwords).
//! Not modelled (NoMatch): SDWA (gone in gfx10), DPP, VOP3P, the VOP3 forms
//! of the interpolation instructions, DS, FLAT/GLOBAL/SCRATCH.
//!
//! The same design as gcn3.sig: one row per instruction drives decoding,
//! printing and encoding. The rows (gfx10_rows.sig) are made by
//! tools/gen_gfx10_vectors.py, which reads every opcode from LLVM's encodings
//! for gfx1013; the test vectors (gfx10_vectors.txt) are LLVM's text and
//! words. One op is one operation whatever its encoding: a VOP1, VOP2 or
//! VOPC op in the VOP3 encoding is the same op with `e64` set. Operands use
//! gcn3's numbering (the 9-bit source codes, VGPR n is 256 + n), with gfx10's
//! names: s0..s105, vcc, ttmp0..15, m0, null, exec, src_shared_base...
//!
//! Decoding is strict: an unknown opcode, a reserved or unused field set, a
//! literal LLVM would write inline, or a form not modelled is NoMatch. Every
//! word that decodes encodes back to itself.
//!
//! Allocation-free: instructions are plain values, text goes into caller
//! buffers.

const std = @import("std");
const gcn3 = @import("gcn3.sig");
const tables = @import("gfx10_rows.sig");

pub const Error = gcn3.Error;
pub const Ty = gcn3.Ty;
pub const Text = gcn3.Text;

// ── Operands ────────────────────────────────────────────────────────────────

/// Operand codes: the 9-bit source field, as in gcn3. 0..255 is the scalar
/// space, 256 + n is VGPR n.
pub const SGPRS: u16 = 106; // s0..s105
pub const VCC_LO: u16 = 106;
pub const VCC_HI: u16 = 107;
pub const TTMP0: u16 = 108; // ttmp0..15
pub const M0: u16 = 124;
pub const NULL: u16 = 125;
pub const EXEC_LO: u16 = 126;
pub const EXEC_HI: u16 = 127;
pub const SHARED_BASE: u16 = 235; // ..239: shared/private base and limit, pops
pub const VCCZ: u16 = 251;
pub const EXECZ: u16 = 252;
pub const SCC: u16 = 253;
pub const LDS_DIRECT: u16 = 254;
pub const LITERAL: u16 = 255;
pub const VGPR0: u16 = 256;

pub const vgpr = gcn3.vgpr;
pub const inlineInt = gcn3.inlineInt;
pub const constValue = gcn3.constValue;

/// The wave size the text is printed for: it sets how wide the lane masks
/// (VOPC's destination, the carries, v_cndmask's mask) are. LLVM's default
/// for gfx10 is wave32; the words are the same in both.
pub const Wave = enum { wave32, wave64 };

// ── Encodings, shapes and the table ─────────────────────────────────────────

pub const Enc = enum(u8) { sop2, sopk, sop1, sopc, sopp, smem, vop2, vop1, vopc, vop3, vintrp, exp, mubuf, mtbuf, mimg };

/// The operands an instruction takes, and in what order its text names them.
pub const Shape = enum(u8) {
    // SALU
    sop2, // sdst, ssrc0, ssrc1
    sop1, // sdst, ssrc0
    sop1_dst, // sdst
    sop1_src, // ssrc0
    sopc, // ssrc0, ssrc1
    sopk, // sdst, simm16
    sopk_imm, // simm16 (s_version)
    sopk_branch, // sdst, a target (s_call_b64, s_subvector_loop_*)
    sopk_getreg, // sdst, hwreg(...)
    sopk_setreg, // hwreg(...), sdst (read)
    sopk_setreg_imm, // hwreg(...), imm32
    sopp, // no operand
    sopp_imm, // simm16
    sopp_branch, // a target relative to the next instruction, in dwords
    sopp_waitcnt, // vmcnt(n) expcnt(n) lgkmcnt(n)
    sopp_sendmsg, // sendmsg(...)
    // SMEM
    smem_load, // sdata, sbase, offset / soffset
    smem_store,
    smem_none, // s_dcache_inv, s_gl1_inv
    smem_time, // sdata (s_memtime)
    // VALU
    vop, // vdst, src0[, src1[, src2]]
    vop_none, // v_nop
    vop_swap, // vdst, vsrc0 (both written)
    vop_sdst, // an SGPR destination: v_readfirstlane_b32, v_readlane_b32
    vop_carry, // vdst, sdst, src0, src1 (VOP3b only in gfx10)
    vop_carry_in, // vdst, sdst, src0, src1, ssrc2 (vcc_lo in _e32)
    vop_cndmask, // vdst, src0, src1, ssrc2 (vcc_lo in _e32)
    vop_madmk, // vdst, src0, K, vsrc1
    vop_madak, // vdst, src0, vsrc1, K
    vopc, // sdst (vcc_lo in _e32), src0, src1
    vopcx, // src0, src1 (writes EXEC only)
    vop3b, // vdst, sdst, src0, src1, src2
    // VINTRP
    vintrp, // vdst, vsrc, attrN.c
    vintrp_mov, // vdst, p10|p20|p0, attrN.c
    // EXP
    exp,
    // MUBUF, MTBUF
    buf_load, // vdata, vaddr|off, srsrc, soffset
    buf_store,
    buf_atomic, // vdata is the data, and the result with glc
    buf_none, // buffer_gl0_inv
    // MIMG
    mimg_load, // vdata, vaddr, srsrc
    mimg_store,
    mimg_atomic,
    mimg_resinfo,
    mimg_sample, // vdata, vaddr, srsrc, ssamp (image_sample*, image_get_lod)
    mimg_gather, // image_gather4*: four channels of one component
    mimg_bvh, // vdata, vaddr, srsrc (image_bvh*_intersect_ray)
};

/// Row flags, read from LLVM by the generator.
pub const flag_clamp: u8 = 1;
pub const flag_omod: u8 = 2;
/// neg and abs on the float sources
pub const flag_neg: u8 = 4;
pub const flag_opsel: u8 = 8;
/// prints _e32 and _e64
pub const flag_suffix: u8 = 16;
/// a SOPP immediate always in hex
pub const flag_hex: u8 = 32;

pub const Row = struct { []const u8, Enc, u16, u16, Shape, Ty, Ty, Ty, Ty, u8 };

/// What an image instruction's address holds (from its name, as LLVM's
/// tables have it).
pub const Img = struct {
    /// offset, bias, compare
    extra: u8 = 0,
    coords: bool = false,
    /// derivatives (_d, _cd)
    grads: bool = false,
    /// lod, clamp or mip level
    lod: bool = false,
    sampler: bool = false,
};

pub const Def = struct {
    name: []const u8,
    enc: Enc,
    code: u16,
    /// The VOP3 opcode of a VOP1/VOP2/VOPC op (NONE: no VOP3 form).
    vop3: u16,
    shape: Shape,
    /// The destination's type (for memory: the data's).
    d: Ty,
    /// The sources' types (SMEM: sbase).
    s: [3]Ty,
    flags: u8,
    img: Img,

    pub fn nsrc(d: *const Def) u8 {
        var n: u8 = 0;
        for (d.s) |t| {
            if (t != .none) n += 1;
        }
        return n;
    }
    pub fn hasE64(d: *const Def) bool {
        return d.vop3 != NONE and d.enc != .vop3 and d.enc != .vintrp;
    }
};

const NONE: u16 = 0xffff;
const rows = tables.rows;

fn imgInfo(comptime name: []const u8, comptime shape: Shape) Img {
    const m = std.mem;
    switch (shape) {
        .mimg_load, .mimg_store, .mimg_atomic => return .{ .coords = true, .lod = m.indexOf(u8, name, "_mip") != null },
        .mimg_resinfo => return .{ .lod = true },
        .mimg_sample, .mimg_gather => {},
        else => return .{},
    }
    if (m.eql(u8, name, "image_get_lod")) return .{ .coords = true, .sampler = true };
    const base = if (m.startsWith(u8, name, "image_sample")) "image_sample" else "image_gather4";
    var r = Img{ .coords = true, .sampler = true };
    var it = m.splitScalar(u8, name[base.len..], '_');
    while (it.next()) |t| {
        if (m.eql(u8, t, "c") or m.eql(u8, t, "o") or m.eql(u8, t, "b")) r.extra += 1;
        if (m.eql(u8, t, "d") or m.eql(u8, t, "cd")) r.grads = true;
        if (m.eql(u8, t, "l") or m.eql(u8, t, "cl")) r.lod = true;
    }
    return r;
}

/// Every instruction. An Op is an index into it.
pub const defs: [rows.len]Def = blk: {
    @setEvalBranchQuota(10_000_000);
    var list: [rows.len]Def = undefined;
    for (rows, 0..) |r, i| {
        list[i] = .{ .name = r[0], .enc = r[1], .code = r[2], .vop3 = r[3], .shape = r[4], .d = r[5], .s = .{ r[6], r[7], r[8] }, .flags = r[9], .img = imgInfo(r[0], r[4]) };
    }
    break :blk list;
};

pub const Op = u16;

/// The op named `name`, at compile time (for switches over ops).
pub fn op(comptime name: []const u8) Op {
    return comptime opIndex(name);
}

fn opIndex(comptime name: []const u8) Op {
    @setEvalBranchQuota(10_000_000);
    for (defs, 0..) |df, i| {
        if (std.mem.eql(u8, df.name, name)) return @intCast(i);
    }
    @compileError("gfx10: no instruction " ++ name);
}

/// The op named `name` (without an _e32/_e64 suffix), or null.
pub fn lookup(name: []const u8) ?Op {
    for (defs, 0..) |d, i| {
        if (std.mem.eql(u8, d.name, name)) return @intCast(i);
    }
    return null;
}

pub fn def(o: Op) *const Def {
    return &defs[o];
}

const n_enc = @typeInfo(Enc).@"enum".field_names.len;

/// (encoding, opcode) to op; the VOP3 table also holds the VOP1, VOP2 and
/// VOPC ops' VOP3 opcodes.
const by_code: [n_enc][1024]u16 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [n_enc][1024]u16 = undefined;
    for (&t) |*row| @memset(row, NONE);
    for (defs, 0..) |df, i| {
        t[@intFromEnum(df.enc)][df.code] = @intCast(i);
        if (df.hasE64()) t[@intFromEnum(Enc.vop3)][df.vop3] = @intCast(i);
    }
    break :blk t;
};

// ── Instructions ────────────────────────────────────────────────────────────

/// One instruction. The fields mean, by encoding (as in gcn3.Instr where the
/// meaning is the same):
///   SALU:  dst = sdst, src[0..1] = ssrc0/1, lit = the literal, imm = simm16.
///   VALU:  dst = vdst (v(n), or a scalar code for an SGPR destination),
///          sdst = VOP3b's carry-out / VOPC's mask (vcc_lo in _e32), src[0..2]
///          (src[2] = the carry-in or v_cndmask's mask), lit = the literal or
///          v_madmk/v_madak's K; neg/abs/clamp/omod/op_sel.
///   SMEM:  dst = sdata, src[0] = sbase, src[1] = soffset (NULL: none),
///          imm = the 21-bit signed offset.
///   VINTRP: dst = vdst, src[0] = vsrc (v(n); for v_interp_mov_f32 the
///          parameter: 0 p10, 1 p20, 2 p0), attr, chan.
///   EXP:   target, en, vsrc[0..3] (VGPR numbers), done, vm, compr.
///   MUBUF, MTBUF: dst = vdata, src[0] = vaddr, src[1] = srsrc,
///          src[2] = soffset, imm = offset, fmt = the format (MTBUF).
///   MIMG:  dst = vdata, src[1] = srsrc, src[2] = ssamp; the address is
///          addr[0..naddr] (VGPR numbers; one range unless nsa).
pub const Instr = struct {
    op: Op = 0,
    /// A VOP1, VOP2 or VOPC instruction in the VOP3 encoding (_e64).
    e64: bool = false,
    dst: u16 = 0,
    sdst: u16 = 0,
    src: [3]u16 = .{ 0, 0, 0 },
    lit: u32 = 0,
    neg: u3 = 0,
    abs: u3 = 0,
    clamp: bool = false,
    omod: u2 = 0,
    /// VOP3 op_sel: a bit per source, the destination's last (bit 3 for
    /// three sources, bit 2 for two). v_permlane*: fi and bound_ctrl.
    op_sel: u4 = 0,
    imm: u32 = 0,
    glc: bool = false,
    slc: bool = false,
    dlc: bool = false,
    tfe: bool = false,
    lwe: bool = false,
    offen: bool = false,
    idxen: bool = false,
    /// MTBUF: gfx10's unified buffer format (1 is the default).
    fmt: u8 = 1,
    // VINTRP
    attr: u8 = 0,
    chan: u2 = 0,
    // EXP
    target: u8 = 0,
    en: u4 = 0,
    vsrc: [4]u8 = .{ 0, 0, 0, 0 },
    done: bool = false,
    vm: bool = false,
    compr: bool = false,
    // MIMG
    dmask: u4 = 0,
    /// 0 1D, 1 2D, 2 3D, 3 CUBE, 4 1D_ARRAY, 5 2D_ARRAY, 6 2D_MSAA,
    /// 7 2D_MSAA_ARRAY
    dim: u3 = 0,
    unorm: bool = false,
    r128: bool = false,
    a16: bool = false,
    d16: bool = false,
    /// The address registers are listed one by one (extra dwords).
    nsa: bool = false,
    naddr: u8 = 0,
    addr: [13]u8 = .{0} ** 13,

    pub fn d(in: *const Instr) *const Def {
        return &defs[in.op];
    }
    /// The encoding this instruction is in (VOP3 for _e64).
    pub fn enc(in: *const Instr) Enc {
        const df = in.d();
        return if (in.e64) .vop3 else df.enc;
    }
    /// Sources read through the 8/9-bit source fields (the literal's users).
    fn litSrcs(in: *const Instr) usize {
        const df = in.d();
        return switch (in.enc()) {
            .sop2, .sopc => 2,
            .sop1 => if (df.shape == .sop1_dst) 0 else 1,
            .vop1, .vop2, .vopc => if (df.shape == .vop_none) 0 else 1,
            .vop3 => vop3Srcs(df),
            else => 0,
        };
    }
    pub fn hasLiteral(in: *const Instr) bool {
        const df = in.d();
        if (df.shape == .vop_madmk or df.shape == .vop_madak or df.shape == .sopk_setreg_imm) return true;
        for (in.src[0..in.litSrcs()]) |c| {
            if (c == LITERAL) return true;
        }
        return false;
    }
    /// Dwords the instruction takes.
    pub fn dwords(in: *const Instr) u8 {
        const base: u8 = switch (in.enc()) {
            .smem, .vop3, .exp, .mubuf, .mtbuf => 2,
            .mimg => 2 + if (in.nsa) nsaWords(in.naddr) else 0,
            else => 1,
        };
        return base + @intFromBool(in.hasLiteral());
    }
};

/// The sources a VOP3-encoded op reads through src0..2.
fn vop3Srcs(df: *const Def) usize {
    return switch (df.shape) {
        .vop_none => 0,
        .vop_carry_in, .vop_cndmask => 3,
        else => df.nsrc(),
    };
}

fn nsaWords(naddr: u8) u8 {
    return if (naddr <= 1) 0 else @intCast((naddr - 1 + 3) / 4);
}

// ── Images ──────────────────────────────────────────────────────────────────

pub const dim_names = [8][]const u8{ "1D", "2D", "3D", "CUBE", "1D_ARRAY", "2D_ARRAY", "2D_MSAA", "2D_MSAA_ARRAY" };
const dim_coords = [8]u8{ 1, 2, 3, 3, 2, 3, 3, 4 };
const dim_grads = [8]u8{ 2, 4, 6, 4, 2, 4, 4, 4 };

/// The address dwords an image instruction reads, for its dim and a16
/// (LLVM's count: a16 packs the coordinates and the lod two to a dword;
/// gfx1013 has no 16-bit derivatives).
pub fn imageAddrs(df: *const Def, dim: u3, a16: bool) u8 {
    if (df.shape == .mimg_bvh) {
        const base: u8 = if (std.mem.eql(u8, df.name, "image_bvh_intersect_ray")) 11 else 12;
        return if (a16) base - 3 else base;
    }
    const im = df.img;
    const comps: u8 = (if (im.coords) dim_coords[dim] else 0) + @intFromBool(im.lod);
    var n: u8 = im.extra + if (a16) (comps + 1) / 2 else comps;
    if (im.grads) n += dim_grads[dim];
    return n;
}

/// The data registers: a dword per dmask channel (four for gather4), half
/// as many with d16, one more with tfe or lwe.
pub fn imageData(in: *const Instr) u8 {
    const df = in.d();
    var n: u8 = switch (df.shape) {
        .mimg_gather, .mimg_bvh => 4,
        else => @popCount(in.dmask),
    };
    if (in.d16) n = (n + 1) / 2;
    if (in.tfe or in.lwe) n += 1;
    return n;
}

// ── Encoding ────────────────────────────────────────────────────────────────

fn isV(code: u16) bool {
    return code >= VGPR0 and code < VGPR0 + 256;
}
fn vIdx(code: u16) Error!u32 {
    if (!isV(code)) return error.NoForm;
    return code - VGPR0;
}
/// A scalar register (not a constant).
fn sReg(code: u16) Error!u32 {
    if (code >= 128) return error.NoForm;
    return code;
}
fn ssrc(code: u16) Error!u32 {
    if (code >= 256) return error.NoForm;
    return code;
}
fn src9(code: u16) Error!u32 {
    if (code >= 512) return error.NoForm;
    return code;
}
fn fits(x: u32, nbits: u5) Error!u32 {
    if (x >> nbits != 0) return error.OutOfRange;
    return x;
}
fn b(x: bool) u32 {
    return @intFromBool(x);
}

/// Encode into `out`; returns the number of dwords.
pub fn encode(in: *const Instr, out: []u32) Error!usize {
    // (an instruction built by hand, not decoded: checked before any of
    // its fields is used as an index)
    try sane(in);
    const df = in.d();
    const n = in.dwords();
    if (out.len < n) return error.BufferTooSmall;
    var w: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
    var nw: usize = 1;
    switch (in.enc()) {
        .sop2 => w[0] = 0b10 << 30 | @as(u32, df.code) << 23 | try sReg(in.dst) << 16 | try ssrc(in.src[1]) << 8 | try ssrc(in.src[0]),
        .sop1 => {
            const dst = if (df.shape == .sop1_src) 0 else try sReg(in.dst);
            const s0 = if (df.shape == .sop1_dst) 0 else try ssrc(in.src[0]);
            w[0] = 0b101111101 << 23 | dst << 16 | @as(u32, df.code) << 8 | s0;
        },
        .sopc => w[0] = 0b101111110 << 23 | @as(u32, df.code) << 16 | try ssrc(in.src[1]) << 8 | try ssrc(in.src[0]),
        .sopk => {
            const dst = if (df.shape == .sopk_setreg_imm or df.shape == .sopk_imm) 0 else try sReg(in.dst);
            w[0] = 0b1011 << 28 | @as(u32, df.code) << 23 | dst << 16 | try fits(in.imm, 16);
        },
        .sopp => {
            const imm: u32 = if (df.shape == .sopp) 0 else try fits(in.imm, 16);
            w[0] = 0b101111111 << 23 | @as(u32, df.code) << 16 | imm;
        },
        .smem => {
            nw = 2;
            var sdata: u32 = 0;
            var sbase: u32 = 0;
            switch (df.shape) {
                .smem_load, .smem_store => {
                    sdata = try sReg(in.dst);
                    sbase = try sReg(in.src[0]);
                    if (sbase & 1 != 0) return error.NoForm;
                    w[1] = try sReg(in.src[1]) << 25 | try fits(in.imm, 21);
                },
                .smem_time => sdata = try sReg(in.dst),
                else => {},
            }
            w[0] = 0b111101 << 26 | @as(u32, df.code) << 18 | b(in.glc) << 16 | b(in.dlc) << 14 | sdata << 6 | sbase >> 1;
        },
        .vop2 => {
            switch (df.shape) {
                .vop_carry_in => if (in.sdst != VCC_LO or in.src[2] != VCC_LO) return error.NoForm,
                .vop_cndmask => if (in.src[2] != VCC_LO) return error.NoForm,
                else => {},
            }
            if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0 or in.op_sel != 0) return error.NoForm;
            w[0] = @as(u32, df.code) << 25 | try vIdx(in.dst) << 17 | try vIdx(in.src[1]) << 9 | try src9(in.src[0]);
        },
        .vop1 => {
            if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0 or in.op_sel != 0) return error.NoForm;
            var dst: u32 = 0;
            var s0: u32 = 0;
            switch (df.shape) {
                .vop_none => {},
                .vop_sdst => {
                    dst = try sReg(in.dst);
                    s0 = try src9(in.src[0]);
                },
                else => {
                    dst = try vIdx(in.dst);
                    s0 = try src9(in.src[0]);
                },
            }
            w[0] = 0b0111111 << 25 | dst << 17 | @as(u32, df.code) << 9 | s0;
        },
        .vopc => {
            if (df.shape == .vopc and in.sdst != VCC_LO) return error.NoForm;
            if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0 or in.op_sel != 0) return error.NoForm;
            w[0] = 0b0111110 << 25 | @as(u32, df.code) << 17 | try vIdx(in.src[1]) << 9 | try src9(in.src[0]);
        },
        .vop3 => {
            nw = 2;
            const code: u32 = if (df.enc == .vop3) df.code else df.vop3;
            if (code == NONE) return error.NoForm;
            var dst: u32 = 0;
            var mid: u32 = 0; // bits 14:8 of VOP3b: sdst
            switch (df.shape) {
                .vop_none => {},
                .vopc => dst = try sReg(in.sdst),
                .vopcx => dst = EXEC_LO,
                .vop_sdst => dst = try sReg(in.dst),
                .vop_carry, .vop_carry_in, .vop3b => {
                    dst = try vIdx(in.dst);
                    mid = try sReg(in.sdst);
                },
                .vop, .vop_cndmask, .vop_swap => dst = try vIdx(in.dst),
                else => return error.NoForm,
            }
            const vop3b = df.shape == .vop_carry or df.shape == .vop_carry_in or df.shape == .vop3b;
            if (vop3b) {
                if (in.abs != 0 or in.op_sel != 0) return error.NoForm;
            } else mid = @as(u32, in.op_sel) << 3 | in.abs;
            const ns = vop3Srcs(df);
            var srcs: [3]u32 = .{ 0, 0, 0 };
            for (0..ns) |i| srcs[i] = try src9(in.src[i]);
            w[0] = 0b110101 << 26 | code << 16 | b(in.clamp) << 15 | mid << 8 | dst;
            w[1] = @as(u32, in.neg) << 29 | @as(u32, in.omod) << 27 | srcs[2] << 18 | srcs[1] << 9 | srcs[0];
        },
        .vintrp => {
            const vs: u32 = if (df.shape == .vintrp_mov) try fits(in.src[0], 8) else try vIdx(in.src[0]);
            w[0] = 0b110010 << 26 | try vIdx(in.dst) << 18 | @as(u32, df.code) << 16 | try fits(in.attr, 6) << 10 | @as(u32, in.chan) << 8 | vs;
        },
        .exp => {
            nw = 2;
            w[0] = 0b111110 << 26 | b(in.vm) << 12 | b(in.done) << 11 | b(in.compr) << 10 | try fits(in.target, 6) << 4 | in.en;
            w[1] = @as(u32, in.vsrc[3]) << 24 | @as(u32, in.vsrc[2]) << 16 | @as(u32, in.vsrc[1]) << 8 | in.vsrc[0];
        },
        .mubuf, .mtbuf => {
            nw = 2;
            var vdata: u32 = 0;
            var vaddr: u32 = 0;
            var srsrc: u32 = 0;
            var soff: u32 = 0;
            if (df.shape != .buf_none) {
                vdata = try vIdx(in.dst);
                if (in.offen or in.idxen) vaddr = try vIdx(in.src[0]);
                srsrc = try sReg(in.src[1]);
                if (srsrc & 3 != 0) return error.NoForm;
                if (in.src[2] == LITERAL) return error.NoForm;
                soff = try ssrc(in.src[2]);
            }
            const flags = b(in.dlc) << 15 | b(in.glc) << 14 | b(in.idxen) << 13 | b(in.offen) << 12 | try fits(in.imm, 12);
            const w1 = soff << 24 | b(in.tfe) << 23 | b(in.slc) << 22 | srsrc >> 2 << 16 | vdata << 8 | vaddr;
            if (df.enc == .mubuf) {
                w[0] = 0b111000 << 26 | @as(u32, df.code >> 7) << 25 | @as(u32, df.code & 0x7f) << 18 | flags;
                w[1] = w1;
            } else {
                w[0] = 0b111010 << 26 | try fits(in.fmt, 7) << 19 | @as(u32, df.code & 7) << 16 | flags;
                w[1] = w1 | @as(u32, df.code >> 3) << 21;
            }
        },
        .mimg => {
            nw = 2;
            const nsa: u32 = if (in.nsa) nsaWords(in.naddr) else 0;
            const code: u32 = df.code;
            w[0] = 0b111100 << 26 | b(in.slc) << 25 | (code & 0x7f) << 18 | b(in.lwe) << 17 | b(in.tfe) << 16 | b(in.r128) << 15 | b(in.glc) << 13 | b(in.unorm) << 12 | @as(u32, in.dmask) << 8 | b(in.dlc) << 7 | @as(u32, in.dim) << 3 | nsa << 1 | code >> 7;
            const ssamp: u32 = if (df.img.sampler) try sReg(in.src[2]) else 0;
            const srsrc = try sReg(in.src[1]);
            if (srsrc & 3 != 0 or ssamp & 3 != 0) return error.NoForm;
            w[1] = b(in.d16) << 31 | b(in.a16) << 30 | ssamp >> 2 << 21 | srsrc >> 2 << 16 | try vIdx(in.dst) << 8 | in.addr[0];
            if (in.nsa) {
                if (in.naddr < 2) return error.NoForm;
                for (1..in.naddr) |i| {
                    const k = i - 1;
                    w[2 + k / 4] |= @as(u32, in.addr[i]) << @intCast(8 * (k % 4));
                }
                nw += nsa;
            }
        },
    }
    if (in.hasLiteral()) {
        w[nw] = in.lit;
        nw += 1;
    }
    std.debug.assert(nw == n);
    @memcpy(out[0..nw], w[0..nw]);
    return nw;
}

// ── Decoding ────────────────────────────────────────────────────────────────

fn bits(w: u32, lo: u5, n: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << n) - 1);
}

fn lookupCode(e: Enc, code: u32) Error!Op {
    if (code >= 1024) return error.NoMatch;
    const o = by_code[@intFromEnum(e)][code];
    if (o == NONE) return error.NoMatch;
    return o;
}

/// A source code valid in a scalar (8-bit) source field.
fn validSSrc(code: u32) bool {
    return switch (code) {
        0...127, 128...208, 235...248, 251...253, 255 => true,
        else => false,
    };
}
/// A source code valid in a 9-bit VALU source field.
fn validVSrc(code: u32) bool {
    return validSSrc(code) or code == LDS_DIRECT or (code >= VGPR0 and code < 512);
}
fn validSReg(code: u32) bool {
    return code < 128;
}

/// A register operand of `n` dwords that LLVM can name: ranges inside
/// their file, SGPR and TTMP ranges aligned (pairs even, wider by four),
/// the special registers at their own widths.
fn regOk(code: u16, n_in: u8) bool {
    const n = @max(n_in, 1);
    if (code >= VGPR0) return code - VGPR0 + n <= 256;
    const al: u16 = if (n == 1) 1 else if (n == 2) 2 else 4;
    if (code < SGPRS) return code + n <= SGPRS and code % al == 0;
    if (code >= TTMP0 and code < TTMP0 + 16) return code - TTMP0 + n <= 16 and (code - TTMP0) % al == 0;
    return switch (code) {
        VCC_LO, EXEC_LO => n <= 2,
        VCC_HI, EXEC_HI, M0, LDS_DIRECT, VCCZ, EXECZ, SCC => n == 1,
        NULL, SHARED_BASE...SHARED_BASE + 4 => n <= 2,
        else => true, // constants
    };
}

/// Decode the instruction at the start of `words`. Returns the number of
/// dwords it takes. Wave-independent: the lane-mask operands are SGPR codes.
/// Whether an instruction's fields are ones this file can encode or
/// print without reading outside its own tables: decoded ones always are.
fn sane(in: *const Instr) Error!void {
    if (in.op >= defs.len) return error.NoMatch;
    if (in.naddr > in.addr.len) return error.NoMatch;
    try checkOperands(in);
}

pub fn decode(words: []const u32, in: *Instr) Error!usize {
    const n = try decodeFields(words, in);
    try checkOperands(in);
    try checkLiteral(in);
    // strict: the fields must encode back to the same words
    var back: [8]u32 = undefined;
    const m = encode(in, &back) catch return error.NoMatch;
    if (m != n or !std.mem.eql(u32, back[0..m], words[0..n])) return error.NoMatch;
    return n;
}

fn decodeFields(words: []const u32, in: *Instr) Error!usize {
    if (words.len == 0) return error.NoMatch;
    const w0 = words[0];
    in.* = .{};
    if (w0 >> 31 == 0) {
        try decodeVop(w0, in);
    } else if (w0 >> 23 == 0x17d) {
        in.op = try lookupCode(.sop1, bits(w0, 8, 8));
        const df = in.d();
        if (df.shape != .sop1_src) in.dst = @intCast(bits(w0, 16, 7));
        if (df.shape != .sop1_dst) in.src[0] = @intCast(bits(w0, 0, 8));
    } else if (w0 >> 23 == 0x17e) {
        in.op = try lookupCode(.sopc, bits(w0, 16, 7));
        in.src[0] = @intCast(bits(w0, 0, 8));
        in.src[1] = @intCast(bits(w0, 8, 8));
    } else if (w0 >> 23 == 0x17f) {
        in.op = try lookupCode(.sopp, bits(w0, 16, 7));
        in.imm = bits(w0, 0, 16);
    } else if (w0 >> 28 == 0xb) {
        in.op = try lookupCode(.sopk, bits(w0, 23, 5));
        const df = in.d();
        in.imm = bits(w0, 0, 16);
        if (df.shape != .sopk_setreg_imm and df.shape != .sopk_imm) in.dst = @intCast(bits(w0, 16, 7));
    } else if (w0 >> 30 == 0b10) {
        in.op = try lookupCode(.sop2, bits(w0, 23, 7));
        in.dst = @intCast(bits(w0, 16, 7));
        in.src[0] = @intCast(bits(w0, 0, 8));
        in.src[1] = @intCast(bits(w0, 8, 8));
    } else {
        switch (w0 >> 26) {
            0b110010 => {
                in.op = try lookupCode(.vintrp, bits(w0, 16, 2));
                const df = in.d();
                in.dst = @intCast(VGPR0 + bits(w0, 18, 8));
                in.attr = @intCast(bits(w0, 10, 6));
                in.chan = @intCast(bits(w0, 8, 2));
                const vs = bits(w0, 0, 8);
                if (df.shape == .vintrp_mov) {
                    if (vs > 2) return error.NoMatch;
                    in.src[0] = @intCast(vs);
                } else in.src[0] = @intCast(VGPR0 + vs);
            },
            else => {
                if (words.len < 2) return error.NoMatch;
                const w1 = words[1];
                switch (w0 >> 26) {
                    0b111101 => try decodeSmem(w0, w1, in),
                    0b110101 => try decodeVop3(w0, w1, in),
                    0b111110 => try decodeExp(w0, w1, in),
                    0b111000, 0b111010 => try decodeBuf(w0, w1, in),
                    0b111100 => try decodeMimg(words, in),
                    else => return error.NoMatch,
                }
            },
        }
    }
    const n: usize = in.dwords();
    if (words.len < n) return error.NoMatch;
    if (in.hasLiteral()) in.lit = words[n - 1];
    return n;
}

fn decodeVop(w0: u32, in: *Instr) Error!void {
    const hi7 = w0 >> 25;
    const s0 = bits(w0, 0, 9);
    if (hi7 == 0x3f) {
        in.op = try lookupCode(.vop1, bits(w0, 9, 8));
        const df = in.d();
        const dst = bits(w0, 17, 8);
        switch (df.shape) {
            .vop_none => {},
            .vop_sdst => {
                in.dst = @intCast(dst);
                in.src[0] = @intCast(s0);
            },
            else => {
                in.dst = @intCast(VGPR0 + dst);
                in.src[0] = @intCast(s0);
            },
        }
    } else if (hi7 == 0x3e) {
        in.op = try lookupCode(.vopc, bits(w0, 17, 8));
        if (in.d().shape == .vopc) in.sdst = VCC_LO;
        in.src[0] = @intCast(s0);
        in.src[1] = @intCast(VGPR0 + bits(w0, 9, 8));
    } else {
        in.op = try lookupCode(.vop2, hi7);
        const df = in.d();
        in.dst = @intCast(VGPR0 + bits(w0, 17, 8));
        in.src[0] = @intCast(s0);
        in.src[1] = @intCast(VGPR0 + bits(w0, 9, 8));
        switch (df.shape) {
            .vop_carry_in => {
                in.sdst = VCC_LO;
                in.src[2] = VCC_LO;
            },
            .vop_cndmask => in.src[2] = VCC_LO,
            else => {},
        }
    }
}

fn decodeSmem(w0: u32, w1: u32, in: *Instr) Error!void {
    in.op = try lookupCode(.smem, bits(w0, 18, 8));
    const df = in.d();
    in.glc = bits(w0, 16, 1) != 0;
    in.dlc = bits(w0, 14, 1) != 0;
    switch (df.shape) {
        .smem_load, .smem_store => {
            in.dst = @intCast(bits(w0, 6, 7));
            in.src[0] = @intCast(bits(w0, 0, 6) << 1);
            in.src[1] = @intCast(bits(w1, 25, 7));
            in.imm = bits(w1, 0, 21);
        },
        .smem_time => in.dst = @intCast(bits(w0, 6, 7)),
        else => {},
    }
}

fn decodeVop3(w0: u32, w1: u32, in: *Instr) Error!void {
    in.op = try lookupCode(.vop3, bits(w0, 16, 10));
    const df = in.d();
    in.e64 = df.enc != .vop3;
    const dst = bits(w0, 0, 8);
    const mid = bits(w0, 8, 7);
    in.clamp = bits(w0, 15, 1) != 0;
    in.omod = @intCast(bits(w1, 27, 2));
    in.neg = @intCast(bits(w1, 29, 3));
    const vop3b = df.shape == .vop_carry or df.shape == .vop_carry_in or df.shape == .vop3b;
    if (vop3b) {
        in.sdst = @intCast(mid);
    } else {
        in.abs = @intCast(mid & 7);
        in.op_sel = @intCast(mid >> 3);
    }
    switch (df.shape) {
        .vopc => in.sdst = @intCast(dst),
        .vop_sdst => in.dst = @intCast(dst),
        .vopcx, .vop_none => if (df.shape == .vopcx and dst != EXEC_LO) return error.NoMatch,
        else => in.dst = @intCast(VGPR0 + dst),
    }
    const raw = [3]u32{ bits(w1, 0, 9), bits(w1, 9, 9), bits(w1, 18, 9) };
    for (0..vop3Srcs(df)) |i| in.src[i] = @intCast(raw[i]);
}

fn decodeExp(w0: u32, w1: u32, in: *Instr) Error!void {
    in.op = try lookupCode(.exp, 0);
    in.en = @intCast(bits(w0, 0, 4));
    in.target = @intCast(bits(w0, 4, 6));
    in.compr = bits(w0, 10, 1) != 0;
    in.done = bits(w0, 11, 1) != 0;
    in.vm = bits(w0, 12, 1) != 0;
    for (0..4) |i| in.vsrc[i] = @intCast(bits(w1, @intCast(8 * i), 8));
}

fn decodeBuf(w0: u32, w1: u32, in: *Instr) Error!void {
    if (w0 >> 26 == 0b111010) {
        in.op = try lookupCode(.mtbuf, bits(w0, 16, 3) | bits(w1, 21, 1) << 3);
        in.fmt = @intCast(bits(w0, 19, 7));
    } else {
        in.op = try lookupCode(.mubuf, bits(w0, 18, 7) | bits(w0, 25, 1) << 7);
    }
    const df = in.d();
    in.imm = bits(w0, 0, 12);
    in.offen = bits(w0, 12, 1) != 0;
    in.idxen = bits(w0, 13, 1) != 0;
    in.glc = bits(w0, 14, 1) != 0;
    in.dlc = bits(w0, 15, 1) != 0;
    in.slc = bits(w1, 22, 1) != 0;
    in.tfe = bits(w1, 23, 1) != 0;
    if (df.shape == .buf_none) return;
    in.dst = @intCast(VGPR0 + bits(w1, 8, 8));
    if (in.offen or in.idxen) in.src[0] = @intCast(VGPR0 + bits(w1, 0, 8));
    in.src[1] = @intCast(bits(w1, 16, 5) << 2);
    in.src[2] = @intCast(bits(w1, 24, 8));
}

fn decodeMimg(words: []const u32, in: *Instr) Error!void {
    const w0 = words[0];
    const w1 = words[1];
    in.op = try lookupCode(.mimg, bits(w0, 18, 7) | (w0 & 1) << 7);
    const df = in.d();
    const nsa_words = bits(w0, 1, 2);
    in.dim = @intCast(bits(w0, 3, 3));
    in.dlc = bits(w0, 7, 1) != 0;
    in.dmask = @intCast(bits(w0, 8, 4));
    in.unorm = bits(w0, 12, 1) != 0;
    in.glc = bits(w0, 13, 1) != 0;
    in.r128 = bits(w0, 15, 1) != 0;
    in.tfe = bits(w0, 16, 1) != 0;
    in.lwe = bits(w0, 17, 1) != 0;
    in.slc = bits(w0, 25, 1) != 0;
    in.a16 = bits(w1, 30, 1) != 0;
    in.d16 = bits(w1, 31, 1) != 0;
    in.dst = @intCast(VGPR0 + bits(w1, 8, 8));
    in.src[1] = @intCast(bits(w1, 16, 5) << 2);
    if (df.img.sampler) in.src[2] = @intCast(bits(w1, 21, 5) << 2);
    in.naddr = imageAddrs(df, in.dim, in.a16);
    in.addr[0] = @intCast(bits(w1, 0, 8));
    if (nsa_words != 0) {
        in.nsa = true;
        if (nsaWords(in.naddr) != nsa_words) return error.NoMatch;
        if (words.len < 2 + nsa_words) return error.NoMatch;
        for (1..in.naddr) |i| {
            const k = i - 1;
            in.addr[i] = @intCast(bits(words[2 + k / 4], @intCast(8 * (k % 4)), 8));
        }
    }
}

/// Every operand must be one LLVM's text can name in its slot.
fn checkOperands(in: *const Instr) Error!void {
    const df = in.d();
    const e = in.enc();
    const ns: usize = switch (e) {
        .vop3 => vop3Srcs(df),
        .vop1 => if (df.shape == .vop_none) 0 else 1,
        .vop2 => if (df.shape == .vop_carry_in or df.shape == .vop_cndmask) 3 else 2,
        .vopc => 2,
        else => 0,
    };
    switch (e) {
        .sop2, .sop1, .sopc => {
            const nsrc: usize = switch (df.shape) {
                .sop2, .sopc => 2,
                .sop1, .sop1_src => 1,
                else => 0,
            };
            for (0..nsrc) |i| {
                if (!validSSrc(in.src[i]) or !regOk(in.src[i], df.s[i].dwords())) return error.NoMatch;
            }
            if (df.shape == .sop2 or df.shape == .sop1 or df.shape == .sop1_dst) {
                if (!validSReg(in.dst) or !regOk(in.dst, df.d.dwords())) return error.NoMatch;
            }
        },
        .sopk => switch (df.shape) {
            .sopk, .sopk_branch, .sopk_getreg, .sopk_setreg => if (!validSReg(in.dst) or !regOk(in.dst, df.d.dwords())) return error.NoMatch,
            else => {},
        },
        .sopp => try checkSopp(in),
        .smem => switch (df.shape) {
            .smem_load, .smem_store => {
                if (!regOk(in.dst, df.d.dwords()) or !regOk(in.src[0], df.s[0].dwords())) return error.NoMatch;
                if (in.src[0] == NULL or in.src[0] == M0) return error.NoMatch;
                if (df.shape == .smem_store and in.dst == NULL) return error.NoMatch;
                if (in.dst == M0 and df.d.dwords() == 1 and df.shape == .smem_load) return error.NoMatch;
            },
            // (these take no cache bits: LLVM refuses them, and the printer
            // has no text for them)
            .smem_time => if (in.glc or in.dlc or !regOk(in.dst, df.d.dwords()) or in.dst == NULL) return error.NoMatch,
            else => if (in.glc or in.dlc) return error.NoMatch,
        },
        .vop1, .vop2, .vopc, .vop3 => try checkValu(in, ns),
        // (attr0 to attr32 are all there are; a constant's parameter is
        // one of three)
        .vintrp => {
            if (in.attr > 32) return error.NoMatch;
            if (df.shape == .vintrp_mov and in.src[0] > 2) return error.NoMatch;
        },
        .exp => try checkExp(in),
        .mubuf, .mtbuf => {
            // (an invalidate takes no operand and no flag: LLVM refuses
            // them, and the printer has no text for them)
            if (df.shape == .buf_none) {
                if (in.imm != 0 or in.offen or in.idxen or in.glc or in.dlc or in.slc or in.tfe) return error.NoMatch;
                return;
            }
            const dn = df.d.dwords() + @intFromBool(in.tfe);
            if (!regOk(in.dst, dn)) return error.NoMatch;
            const an: u8 = if (in.offen and in.idxen) 2 else 1;
            if ((in.offen or in.idxen) and !regOk(in.src[0], an)) return error.NoMatch;
            if (!regOk(in.src[1], 4)) return error.NoMatch;
            if (in.src[1] >= SGPRS and !(in.src[1] >= TTMP0 and in.src[1] < TTMP0 + 16)) return error.NoMatch;
            const so = in.src[2];
            if (!(so < 128 or (so >= 128 and so <= 208) or (so >= 240 and so <= 248))) return error.NoMatch;
            if (df.enc == .mtbuf and df.shape == .buf_atomic) return error.NoMatch;
        },
        .mimg => try checkMimg(in),
    }
}

fn checkSopp(in: *const Instr) Error!void {
    const df = in.d();
    switch (df.shape) {
        .sopp_waitcnt => if (in.imm & 0x80 != 0) return error.NoMatch,
        else => {},
    }
}

fn isFloatSrc(df: *const Def, i: usize) bool {
    if (df.shape == .vop_cndmask) return i < 2;
    return df.s[i].isFloat();
}

/// The source must be a VGPR (v_readlane's and v_permlane's lane source...).
fn vgprSrc0(df: *const Def) bool {
    const m = std.mem;
    return m.startsWith(u8, df.name, "v_movrels") or m.eql(u8, df.name, "v_movrelsd_2_b32") or m.eql(u8, df.name, "v_readlane_b32") or
        m.eql(u8, df.name, "v_readfirstlane_b32") or m.startsWith(u8, df.name, "v_permlane") or df.shape == .vop_swap;
}

fn isPermlane(df: *const Def) bool {
    return std.mem.startsWith(u8, df.name, "v_permlane");
}

fn checkValu(in: *const Instr, ns: usize) Error!void {
    const df = in.d();
    const e = in.enc();
    // destinations
    switch (df.shape) {
        .vop_sdst => if (!validSReg(in.dst) or in.dst == NULL) return error.NoMatch,
        .vop_none, .vopc, .vopcx => {},
        else => if (!regOk(in.dst, df.d.dwords())) return error.NoMatch,
    }
    if (df.shape == .vop_sdst and !regOk(in.dst, 1)) return error.NoMatch;
    // the lane masks: any scalar register (its width is the wave's)
    switch (df.shape) {
        .vopc, .vop_carry, .vop_carry_in, .vop3b => if (!validSReg(in.sdst) or in.sdst == M0 or in.sdst == EXEC_HI or in.sdst == VCC_HI) return error.NoMatch,
        else => {},
    }
    // sources
    for (0..ns) |i| {
        const c = in.src[i];
        const mask = (df.shape == .vop_carry_in or df.shape == .vop_cndmask) and i == 2;
        if (mask) {
            if (!validSReg(c) or c == M0 or c == EXEC_HI or c == VCC_HI) return error.NoMatch;
            continue;
        }
        if (!validVSrc(c)) return error.NoMatch;
        if (c == LDS_DIRECT and (e == .vop3 or i != 0)) return error.NoMatch;
        if (!regOk(c, df.s[i].dwords())) return error.NoMatch;
        if (c >= 128 and c < VGPR0 and c != LITERAL and df.s[i].dwords() > 2) return error.NoMatch;
    }
    if (ns > 0 and vgprSrc0(df) and !isV(in.src[0])) return error.NoMatch;
    if (isPermlane(df)) {
        for (1..3) |i| if (isV(in.src[i])) return error.NoMatch;
    }
    if (df.shape == .vop_madmk or df.shape == .vop_madak) {
        // K is the literal; src0 may share it
        if (!isV(in.src[1])) return error.NoMatch;
    }
    if (e != .vop3) return;
    // VOP3 modifiers the row takes
    if (in.clamp and df.flags & flag_clamp == 0) return error.NoMatch;
    if (in.omod != 0 and df.flags & flag_omod == 0) return error.NoMatch;
    for (0..3) |i| {
        const m = (in.neg | in.abs) >> @intCast(i) & 1 != 0;
        if (!m) continue;
        if (i >= ns or df.flags & flag_neg == 0 or !isFloatSrc(df, i)) return error.NoMatch;
    }
    if (in.op_sel != 0) {
        if (isPermlane(df)) {
            if (in.op_sel >> 2 != 0) return error.NoMatch;
        } else {
            if (df.flags & flag_opsel == 0) return error.NoMatch;
            // a bit per source and the destination's at bit 3
            const used: u4 = @intCast((@as(u5, 1) << @intCast(ns)) - 1);
            if (in.op_sel & 7 & ~@as(u4, used) != 0) return error.NoMatch;
        }
    }
}

fn expTargetName(t: u8, buf: *[16]u8) ?[]const u8 {
    return switch (t) {
        0...7 => std.fmt.bufPrint(buf, "mrt{d}", .{t}) catch unreachable,
        8 => "mrtz",
        9 => "null",
        12...16 => std.fmt.bufPrint(buf, "pos{d}", .{t - 12}) catch unreachable,
        20 => "prim",
        32...63 => std.fmt.bufPrint(buf, "param{d}", .{t - 32}) catch unreachable,
        else => null,
    };
}

fn checkExp(in: *const Instr) Error!void {
    var nb: [16]u8 = undefined;
    if (expTargetName(in.target, &nb) == null) return error.NoMatch;
    if (in.compr) {
        // two packed sources, each enabled for a pair of channels
        if (in.en != 0 and in.en != 3 and in.en != 0xc and in.en != 0xf) return error.NoMatch;
        if (in.vsrc[2] != 0 or in.vsrc[3] != 0) return error.NoMatch;
        if (in.en & 3 == 0 and in.vsrc[0] != 0) return error.NoMatch;
        if (in.en & 0xc == 0 and in.vsrc[1] != 0) return error.NoMatch;
    } else {
        for (0..4) |i| {
            if (in.en >> @intCast(i) & 1 == 0 and in.vsrc[i] != 0) return error.NoMatch;
        }
    }
}

fn checkMimg(in: *const Instr) Error!void {
    const df = in.d();
    const sh = df.shape;
    if (sh == .mimg_bvh) {
        if (in.dmask != 0xf or !in.unorm or !in.r128 or in.dim != 0) return error.NoMatch;
        if (in.glc or in.slc or in.dlc or in.tfe or in.lwe or in.d16) return error.NoMatch;
    } else {
        if (in.dmask == 0) return error.NoMatch;
        if (sh == .mimg_gather and @popCount(in.dmask) != 1) return error.NoMatch;
        if (sh == .mimg_atomic) {
            const want: u4 = if (std.mem.indexOf(u8, df.name, "cmpswap") != null) 3 else 1;
            if (in.dmask != want) return error.NoMatch;
        }
        const msaa = in.dim >= 6;
        if (msaa and (sh == .mimg_sample or sh == .mimg_gather or (df.img.lod and sh != .mimg_resinfo))) return error.NoMatch;
        if ((in.tfe or in.lwe) and (sh == .mimg_store or sh == .mimg_atomic)) return error.NoMatch;
        if (in.d16 and (sh == .mimg_atomic or sh == .mimg_resinfo)) return error.NoMatch;
        if (std.mem.eql(u8, df.name, "image_get_lod") and in.d16) return error.NoMatch;
    }
    if (!regOk(in.dst, imageData(in))) return error.NoMatch;
    if (in.src[1] >= SGPRS) return error.NoMatch;
    const rn: u8 = if (sh == .mimg_bvh) 4 else 8;
    if (!regOk(in.src[1], rn)) return error.NoMatch;
    if (df.img.sampler and (in.src[2] >= SGPRS or !regOk(in.src[2], 4))) return error.NoMatch;
    if (in.nsa) {
        if (in.naddr < 2) return error.NoMatch;
    } else {
        if (in.addr[0] + @as(u32, printedAddrs(in)) > 256) return error.NoMatch;
    }
}

/// The registers a non-NSA address range is printed with (LLVM rounds 13
/// and more up to 16).
fn printedAddrs(in: *const Instr) u8 {
    return if (in.naddr > 12) 16 else in.naddr;
}

/// A literal LLVM would write as an inline constant is not canonical.
fn checkLiteral(in: *const Instr) Error!void {
    const df = in.d();
    if (!in.hasLiteral()) return;
    switch (df.shape) {
        .vop_madmk, .vop_madak, .sopk_setreg_imm => return,
        else => {},
    }
    for (0..in.litSrcs()) |i| {
        if (in.src[i] != LITERAL) continue;
        if (inlinable(in.lit, df.s[i])) return error.NoMatch;
    }
}

/// Whether LLVM writes the 32-bit value `x` of an operand of type `t` as an
/// inline constant (gcn3's rules).
fn inlinable(x: u32, t: Ty) bool {
    if (x <= 64) return true;
    switch (t) {
        .b32, .f32 => {
            for (gcn3.float32) |f| if (f == x) return true;
            const si: i32 = @bitCast(x);
            return si >= -16 and si <= 64;
        },
        .f16 => {
            if (x > 0xffff) return false;
            for (gcn3.float16) |f| if (f == x) return true;
            const si: i16 = @bitCast(@as(u16, @intCast(x)));
            return si >= -16 and si <= 64;
        },
        .f64 => {
            const hi = @as(u64, x) << 32;
            for (gcn3.float64) |f| if (f == hi) return true;
            return false;
        },
        else => return false,
    }
}

// ── Text (LLVM's AMDGPU syntax for gfx10) ───────────────────────────────────

const Special = struct { code: u16, w1: []const u8, w2: []const u8 };
const specials = [_]Special{
    .{ .code = VCC_LO, .w1 = "vcc_lo", .w2 = "vcc" },
    .{ .code = VCC_HI, .w1 = "vcc_hi", .w2 = "" },
    .{ .code = M0, .w1 = "m0", .w2 = "" },
    .{ .code = NULL, .w1 = "null", .w2 = "null" },
    .{ .code = EXEC_LO, .w1 = "exec_lo", .w2 = "exec" },
    .{ .code = EXEC_HI, .w1 = "exec_hi", .w2 = "" },
    .{ .code = 235, .w1 = "src_shared_base", .w2 = "src_shared_base" },
    .{ .code = 236, .w1 = "src_shared_limit", .w2 = "src_shared_limit" },
    .{ .code = 237, .w1 = "src_private_base", .w2 = "src_private_base" },
    .{ .code = 238, .w1 = "src_private_limit", .w2 = "src_private_limit" },
    .{ .code = 239, .w1 = "src_pops_exiting_wave_id", .w2 = "src_pops_exiting_wave_id" },
    .{ .code = VCCZ, .w1 = "src_vccz", .w2 = "" },
    .{ .code = EXECZ, .w1 = "src_execz", .w2 = "" },
    .{ .code = SCC, .w1 = "src_scc", .w2 = "" },
    .{ .code = LDS_DIRECT, .w1 = "src_lds_direct", .w2 = "" },
};

const float_names = [9][]const u8{ "0.5", "-0.5", "1.0", "-1.0", "2.0", "-2.0", "4.0", "-4.0", "0.15915494" };
const inv2pi64_name = "0.15915494309189532";

fn putRange(t: *Text, prefix: []const u8, first: u32, n: u8) void {
    if (n <= 1) t.print("{s}{d}", .{ prefix, first }) else t.print("{s}[{d}:{d}]", .{ prefix, first, first + n - 1 });
}

/// An operand code as text, `n` dwords wide (`lit` for 255; `is64` picks
/// 1/(2*pi)'s 64-bit spelling).
fn putReg(t: *Text, code: u16, n: u8, is64: bool, lit: u32) void {
    if (code >= VGPR0) return putRange(t, "v", code - VGPR0, n);
    if (code < SGPRS) return putRange(t, "s", code, n);
    if (code >= TTMP0 and code < TTMP0 + 16) return putRange(t, "ttmp", code - TTMP0, n);
    for (specials) |sp| {
        if (sp.code == code) {
            if (n == 2 and sp.w2.len != 0) return t.str(sp.w2);
            return t.str(sp.w1);
        }
    }
    if (code >= 128 and code <= 192) return t.print("{d}", .{code - 128});
    if (code >= 193 and code <= 208) return t.print("-{d}", .{code - 192});
    if (code >= 240 and code <= 248) {
        if (code == 248 and is64) return t.str(inv2pi64_name);
        return t.str(float_names[code - 240]);
    }
    if (code == LITERAL) return t.print("0x{x}", .{lit});
    t.print("<{d}>", .{code});
}

pub fn putOperand(t: *Text, code: u16, ty: Ty, lit: u32) void {
    putReg(t, code, @max(ty.dwords(), 1), ty.is64(), lit);
}

fn putSrc(t: *Text, in: *const Instr, i: usize, ty: Ty) void {
    const neg = in.neg >> @intCast(i) & 1 != 0;
    const abs = in.abs >> @intCast(i) & 1 != 0;
    const c = in.src[i];
    // LLVM writes a negated constant neg(...): -1.0 is a constant of its own.
    const neg_call = neg and !abs and c >= 128 and c < VGPR0 and c != LDS_DIRECT and (c < VCCZ or c > SCC) and (c < SHARED_BASE or c > SHARED_BASE + 4);
    if (neg_call) t.str("neg(") else if (neg) t.str("-");
    if (abs) t.str("|");
    putOperand(t, c, ty, in.lit);
    if (abs) t.str("|");
    if (neg_call) t.str(")");
}

fn putMask(t: *Text, code: u16, wave: Wave) void {
    putReg(t, code, if (wave == .wave64) 2 else 1, false, 0);
}

fn putHwreg(t: *Text, imm: u32) void {
    const id = imm & 63;
    const off = imm >> 6 & 31;
    const size = (imm >> 11 & 31) + 1;
    t.str("hwreg(");
    if (tables.hwreg_names[id].len != 0) t.str(tables.hwreg_names[id]) else t.print("{d}", .{id});
    if (off != 0 or size != 32) t.print(", {d}, {d}", .{ off, size });
    t.str(")");
}

fn putWaitcnt(t: *Text, imm: u32) void {
    const vm = (imm & 15) | (imm >> 14 & 3) << 4;
    const exp = imm >> 4 & 7;
    const lgkm = imm >> 8 & 63;
    const all = vm == 63 and exp == 7 and lgkm == 63;
    var first = true;
    if (vm != 63 or all) {
        t.print("vmcnt({d})", .{vm});
        first = false;
    }
    if (exp != 7 or all) {
        t.print("{s}expcnt({d})", .{ if (first) "" else " ", exp });
        first = false;
    }
    if (lgkm != 63 or all) t.print("{s}lgkmcnt({d})", .{ if (first) "" else " ", lgkm });
}

const msg_names = [16][]const u8{ "", "MSG_INTERRUPT", "MSG_GS", "MSG_GS_DONE", "MSG_SAVEWAVE", "MSG_STALL_WAVE_GEN", "MSG_HALT_WAVES", "MSG_ORDERED_PS_DONE", "MSG_EARLY_PRIM_DEALLOC", "MSG_GS_ALLOC_REQ", "MSG_GET_DOORBELL", "MSG_GET_DDID", "", "", "", "MSG_SYSMSG" };
const gs_ops = [4][]const u8{ "GS_OP_NOP", "GS_OP_CUT", "GS_OP_EMIT", "GS_OP_EMIT_CUT" };
const sys_ops = [5][]const u8{ "", "SYSMSG_OP_ECC_ERR_INTERRUPT", "SYSMSG_OP_REG_RD", "", "SYSMSG_OP_TTRACE_PC" };

/// s_sendmsg's operand: a message, its operation and stream (LLVM's names
/// where they are valid, numbers where they only encode, else the value).
/// As LLVM's printer does, a valid message is named even when bits outside
/// its fields are set.
fn putSendmsg(t: *Text, imm: u32) void {
    const msg = imm & 15;
    const opn = imm >> 4 & 7;
    const stream = imm >> 8 & 3;
    const exact = msg | opn << 4 | stream << 8 == imm;
    const gs = msg == 2 or msg == 3;
    var valid = msg_names[msg].len != 0;
    if (valid) {
        if (gs) {
            valid = opn < 4 and (opn != 0 or msg == 3) and (opn != 0 or stream == 0);
        } else if (msg == 15) {
            valid = opn < sys_ops.len and sys_ops[opn].len != 0 and stream == 0;
        } else valid = opn == 0 and stream == 0;
    }
    if (!valid) {
        if (exact) return t.print("sendmsg({d}, {d}, {d})", .{ msg, opn, stream });
        return t.print("{d}", .{imm});
    }
    t.print("sendmsg({s}", .{msg_names[msg]});
    if (gs) {
        t.print(", {s}", .{gs_ops[opn]});
        if (opn != 0) t.print(", {d}", .{stream});
    } else if (msg == 15) t.print(", {s}", .{sys_ops[opn]});
    t.str(")");
}

const DepField = struct { name: []const u8, lo: u5, n: u5 };
const dep_fields = [_]DepField{
    .{ .name = "depctr_sa_sdst", .lo = 0, .n = 1 },
    .{ .name = "depctr_va_vdst", .lo = 12, .n = 4 },
    .{ .name = "depctr_va_sdst", .lo = 9, .n = 3 },
    .{ .name = "depctr_va_ssrc", .lo = 8, .n = 1 },
    .{ .name = "depctr_va_vcc", .lo = 1, .n = 1 },
    .{ .name = "depctr_vm_vsrc", .lo = 2, .n = 3 },
};

/// s_waitcnt_depctr's operand: the counters that are not at their maximum
/// (all of them if none is), or hex with an unused bit set.
fn putDepctr(t: *Text, imm: u32) void {
    if (imm & 0xe0 != 0) return t.print("0x{x}", .{imm});
    var any = false;
    for (dep_fields) |f| {
        if (bits(imm, f.lo, f.n) != (@as(u32, 1) << f.n) - 1) any = true;
    }
    var first = true;
    for (dep_fields) |f| {
        const v = bits(imm, f.lo, f.n);
        if (any and v == (@as(u32, 1) << f.n) - 1) continue;
        t.print("{s}{s}({d})", .{ if (first) "" else " ", f.name, v });
        first = false;
    }
}

/// A 32-bit immediate as LLVM prints one: inline constants by value, others
/// in hex.
fn putImm32(t: *Text, x: u32) void {
    const si: i32 = @bitCast(x);
    if (si >= -16 and si <= 64) return t.print("{d}", .{si});
    for (gcn3.float32, 0..) |f, i| {
        if (f == x) return t.str(float_names[i]);
    }
    t.print("0x{x}", .{x});
}

fn mnemonic(t: *Text, in: *const Instr) void {
    const df = in.d();
    t.str(df.name);
    if (df.flags & flag_suffix != 0) t.str(if (in.e64) "_e64" else "_e32");
}

/// Print the instruction as LLVM's assembler prints it for wave32.
pub fn format(in: *const Instr, buf: []u8) Error![]const u8 {
    return formatWave(in, .wave32, buf);
}

/// Print the instruction as LLVM prints it for a wave size. A lane mask
/// that is not an aligned SGPR pair has no wave64 text (NoForm).
pub fn formatWave(in: *const Instr, wave: Wave, buf: []u8) Error![]const u8 {
    var t = Text{ .buf = buf };
    try formatInto(&t, in, wave);
    if (t.overflow) return error.BufferTooSmall;
    return t.text();
}

fn maskOk(code: u16, wave: Wave) bool {
    return wave == .wave32 or regOk(code, 2);
}

pub fn formatInto(t: *Text, in: *const Instr, wave: Wave) Error!void {
    try sane(in);
    const df = in.d();
    mnemonic(t, in);
    const sp = " ";
    switch (df.shape) {
        .sop2 => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], in.lit);
            t.str(", ");
            putOperand(t, in.src[1], df.s[1], in.lit);
        },
        .sop1 => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], in.lit);
        },
        .sop1_dst => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
        },
        .sop1_src => {
            t.str(sp);
            putOperand(t, in.src[0], df.s[0], in.lit);
        },
        .sopc => {
            t.str(sp);
            putOperand(t, in.src[0], df.s[0], in.lit);
            t.str(", ");
            putOperand(t, in.src[1], df.s[1], in.lit);
        },
        .sopk => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.print(", 0x{x}", .{in.imm});
        },
        .sopk_imm => t.print(" 0x{x}", .{in.imm}),
        .sopk_branch => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.print(", {d}", .{@as(i16, @bitCast(@as(u16, @intCast(in.imm))))});
        },
        .sopk_getreg => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putHwreg(t, in.imm);
        },
        .sopk_setreg => {
            t.str(sp);
            putHwreg(t, in.imm);
            t.str(", ");
            putOperand(t, in.dst, df.d, 0);
        },
        .sopk_setreg_imm => {
            t.str(sp);
            putHwreg(t, in.imm);
            t.str(", ");
            putImm32(t, in.lit);
        },
        .sopp => {},
        .sopp_imm => {
            if (std.mem.eql(u8, df.name, "s_waitcnt_depctr")) {
                t.str(sp);
                putDepctr(t, in.imm);
            } else if (df.flags & flag_hex != 0 or in.imm > 64) t.print(" 0x{x}", .{in.imm}) else t.print(" {d}", .{in.imm});
        },
        .sopp_branch => t.print(" {d}", .{@as(i16, @bitCast(@as(u16, @intCast(in.imm))))}),
        .sopp_waitcnt => {
            t.str(sp);
            putWaitcnt(t, in.imm);
        },
        .sopp_sendmsg => {
            t.str(sp);
            putSendmsg(t, in.imm);
        },
        .smem_load, .smem_store => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], 0);
            t.str(", ");
            const off: i32 = @as(i32, @bitCast(in.imm << 11)) >> 11;
            if (in.src[1] == NULL) {
                putHex(t, off);
            } else {
                putOperand(t, in.src[1], .b32, 0);
                if (off != 0) {
                    t.str(" offset:");
                    putHex(t, off);
                }
            }
            if (in.glc) t.str(" glc");
            if (in.dlc) t.str(" dlc");
        },
        .smem_none => {},
        .smem_time => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
        },
        .vop_none => {},
        .vop, .vop_swap => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            for (0..df.nsrc()) |i| {
                t.str(", ");
                putSrc(t, in, i, df.s[i]);
            }
            putVop3Mods(t, in, df.nsrc());
        },
        .vop_sdst => {
            t.str(sp);
            putOperand(t, in.dst, .b32, 0);
            for (0..df.nsrc()) |i| {
                t.str(", ");
                putSrc(t, in, i, df.s[i]);
            }
        },
        .vop_carry, .vop3b => {
            if (!maskOk(in.sdst, wave)) return error.NoForm;
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putMask(t, in.sdst, wave);
            for (0..df.nsrc()) |i| {
                t.str(", ");
                putSrc(t, in, i, df.s[i]);
            }
            putVop3Mods(t, in, df.nsrc());
        },
        .vop_carry_in => {
            if (!maskOk(in.sdst, wave) or !maskOk(in.src[2], wave)) return error.NoForm;
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putMask(t, in.sdst, wave);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            t.str(", ");
            putMask(t, in.src[2], wave);
            putVop3Mods(t, in, 2);
        },
        .vop_cndmask => {
            if (!maskOk(in.src[2], wave)) return error.NoForm;
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            t.str(", ");
            putMask(t, in.src[2], wave);
            putVop3Mods(t, in, 2);
        },
        .vop_madmk => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], in.lit);
            t.print(", 0x{x}, ", .{in.lit});
            putOperand(t, in.src[1], df.s[1], 0);
        },
        .vop_madak => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], in.lit);
            t.str(", ");
            putOperand(t, in.src[1], df.s[1], 0);
            t.print(", 0x{x}", .{in.lit});
        },
        .vopc => {
            if (!maskOk(in.sdst, wave)) return error.NoForm;
            t.str(sp);
            putMask(t, in.sdst, wave);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            putVop3Mods(t, in, 2);
        },
        .vopcx => {
            t.str(sp);
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            putVop3Mods(t, in, 2);
        },
        .vintrp, .vintrp_mov => {
            t.str(sp);
            putOperand(t, in.dst, .b32, 0);
            t.str(", ");
            if (df.shape == .vintrp_mov) {
                const params = [3][]const u8{ "p10", "p20", "p0" };
                t.str(params[in.src[0]]);
            } else putOperand(t, in.src[0], .b32, 0);
            t.print(", attr{d}.{c}", .{ in.attr, "xyzw"[in.chan] });
        },
        .exp => formatExp(t, in),
        .buf_load, .buf_store, .buf_atomic, .buf_none => formatBuf(t, in),
        .mimg_load, .mimg_store, .mimg_atomic, .mimg_resinfo, .mimg_sample, .mimg_gather, .mimg_bvh => formatMimg(t, in),
    }
}

fn putHex(t: *Text, x: i32) void {
    if (x < 0) t.print("-0x{x}", .{@as(u32, @intCast(-x))}) else t.print("0x{x}", .{@as(u32, @intCast(x))});
}

fn putVop3Mods(t: *Text, in: *const Instr, ns: usize) void {
    const df = in.d();
    if (in.op_sel != 0) {
        if (isPermlane(df)) {
            t.print(" op_sel:[{d},{d}]", .{ in.op_sel & 1, in.op_sel >> 1 & 1 });
        } else {
            t.str(" op_sel:[");
            for (0..ns) |i| t.print("{d},", .{in.op_sel >> @intCast(i) & 1});
            t.print("{d}]", .{in.op_sel >> 3});
        }
    }
    if (in.clamp) t.str(" clamp");
    switch (in.omod) {
        1 => t.str(" mul:2"),
        2 => t.str(" mul:4"),
        3 => t.str(" div:2"),
        else => {},
    }
}

fn formatExp(t: *Text, in: *const Instr) void {
    var nb: [16]u8 = undefined;
    t.print(" {s}", .{expTargetName(in.target, &nb) orelse "?"});
    for (0..4) |i| {
        t.str(if (i == 0) " " else ", ");
        if (in.en >> @intCast(i) & 1 == 0) {
            t.str("off");
            continue;
        }
        const v = if (in.compr) in.vsrc[i / 2] else in.vsrc[i];
        t.print("v{d}", .{v});
    }
    if (in.done) t.str(" done");
    if (in.compr) t.str(" compr");
    if (in.vm) t.str(" vm");
}

fn formatBuf(t: *Text, in: *const Instr) void {
    const df = in.d();
    if (df.shape == .buf_none) return;
    t.str(" ");
    // tfe adds a dword to the data
    putRange(t, "v", in.dst - VGPR0, df.d.dwords() + @intFromBool(in.tfe));
    t.str(", ");
    if (in.offen or in.idxen) {
        const n: u8 = if (in.offen and in.idxen) 2 else 1;
        putRange(t, "v", in.src[0] - VGPR0, n);
    } else t.str("off");
    t.str(", ");
    putOperand(t, in.src[1], .b128, 0);
    t.str(", ");
    putOperand(t, in.src[2], .b32, 0);
    if (df.enc == .mtbuf and in.fmt != 1) {
        const name = tables.format_names[in.fmt];
        if (name.len != 0) t.print(" format:[{s}]", .{name}) else t.print(" format:{d}", .{in.fmt});
    }
    if (in.idxen) t.str(" idxen");
    if (in.offen) t.str(" offen");
    if (in.imm != 0) t.print(" offset:{d}", .{in.imm});
    if (in.glc) t.str(" glc");
    if (in.slc) t.str(" slc");
    if (in.dlc) t.str(" dlc");
    if (in.tfe) t.str(" tfe");
}

fn formatMimg(t: *Text, in: *const Instr) void {
    const df = in.d();
    t.str(" ");
    putRange(t, "v", in.dst - VGPR0, imageData(in));
    t.str(", ");
    if (in.nsa) {
        t.str("[");
        for (0..in.naddr) |i| t.print("{s}v{d}", .{ if (i == 0) "" else ", ", in.addr[i] });
        t.str("]");
    } else putRange(t, "v", in.addr[0], printedAddrs(in));
    t.str(", ");
    putReg(t, in.src[1], if (df.shape == .mimg_bvh) 4 else 8, false, 0);
    if (df.img.sampler) {
        t.str(", ");
        putReg(t, in.src[2], 4, false, 0);
    }
    if (df.shape == .mimg_bvh) {
        if (in.a16) t.str(" a16");
        return;
    }
    t.print(" dmask:0x{x} dim:SQ_RSRC_IMG_{s}", .{ in.dmask, dim_names[in.dim] });
    if (in.unorm) t.str(" unorm");
    if (in.glc) t.str(" glc");
    if (in.slc) t.str(" slc");
    if (in.dlc) t.str(" dlc");
    if (in.r128) t.str(" r128");
    if (in.a16) t.str(" a16");
    if (in.tfe) t.str(" tfe");
    if (in.lwe) t.str(" lwe");
    if (in.d16) t.str(" d16");
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn parseWords(field: []const u8, out: []u32) !usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, field, '_');
    while (it.next()) |h| {
        if (n == out.len) return error.Syntax;
        out[n] = try std.fmt.parseInt(u32, h, 16);
        n += 1;
    }
    return n;
}

test "the table: names are unique, and (encoding, opcode) pairs too" {
    for (&defs, 0..) |*a, i| {
        for (defs[i + 1 ..]) |*c| {
            if (std.mem.eql(u8, a.name, c.name)) {
                std.debug.print("duplicate name {s}\n", .{a.name});
                return error.TestUnexpectedResult;
            }
            if (a.enc == c.enc and a.code == c.code) {
                std.debug.print("duplicate opcode {s} / {s}\n", .{ a.name, c.name });
                return error.TestUnexpectedResult;
            }
            if (a.hasE64() and c.hasE64() and a.vop3 == c.vop3) {
                std.debug.print("duplicate VOP3 opcode {s} / {s}\n", .{ a.name, c.name });
                return error.TestUnexpectedResult;
            }
        }
        if (a.enc == .vop3) {
            for (&defs) |*c| {
                if (c.hasE64() and c.vop3 == a.code) {
                    std.debug.print("VOP3 opcode {x} taken by {s} and {s}\n", .{ a.code, a.name, c.name });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "LLVM's gfx1013 vectors: decode, print, encode" {
    const data = @embedFile("gfx10_vectors.txt");
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var failures: usize = 0;
    var wave: Wave = .wave32;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "# wave64")) wave = .wave64;
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Syntax;
        var words: [8]u32 = undefined;
        const nw = try parseWords(line[0..sp], &words);
        const text = line[sp + 1 ..];
        n += 1;
        var in: Instr = undefined;
        const used = decode(words[0..nw], &in) catch |e| {
            if (failures < 400) std.debug.print("decode {s}: {s}\n", .{ line, @errorName(e) });
            failures += 1;
            continue;
        };
        if (used != nw) {
            if (failures < 400) std.debug.print("decode {s}: {d} dwords\n", .{ line, used });
            failures += 1;
        }
        var buf: [300]u8 = undefined;
        const printed = formatWave(&in, wave, &buf) catch |e| {
            if (failures < 400) std.debug.print("format {s}: {s}\n", .{ line, @errorName(e) });
            failures += 1;
            continue;
        };
        if (!std.mem.eql(u8, printed, text)) {
            if (failures < 400) std.debug.print("print  {s}: got \"{s}\"\n", .{ line, printed });
            failures += 1;
        }
        var enc: [8]u32 = undefined;
        const ne = encode(&in, &enc) catch |e| {
            if (failures < 400) std.debug.print("encode \"{s}\": {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        if (ne != nw or !std.mem.eql(u32, enc[0..ne], words[0..nw])) {
            if (failures < 400) std.debug.print("encode \"{s}\": differs\n", .{text});
            failures += 1;
        }
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} vectors failed\n", .{ failures, n });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(n > 8000);
}

test "random words: decode never crashes, and what decodes prints and encodes back" {
    var rng = std.Random.DefaultPrng.init(0x67667831);
    const r = rng.random();
    // Prefixes that select each encoding, so most words are near-valid.
    const prefixes = [_]struct { u32, u5 }{
        .{ 0b10, 30 }, .{ 0b1011, 28 }, .{ 0b101111101, 23 }, .{ 0b101111110, 23 }, .{ 0b101111111, 23 },
        .{ 0b111101, 26 }, .{ 0b0, 31 }, .{ 0b0111111, 25 }, .{ 0b0111110, 25 }, .{ 0b110101, 26 },
        .{ 0b110010, 26 }, .{ 0b111110, 26 }, .{ 0b111000, 26 }, .{ 0b111010, 26 }, .{ 0b111100, 26 },
    };
    var decoded: usize = 0;
    for (0..300_000) |k| {
        const pf = prefixes[k % prefixes.len];
        var words: [6]u32 = undefined;
        for (&words) |*w| w.* = r.int(u32);
        const keep: u32 = (@as(u32, 1) << pf[1]) - 1;
        words[0] = (words[0] & keep) | (pf[0] << pf[1]);
        // sparse fields decode more often
        if (r.boolean()) words[0] &= 0xfe3f_ffff | ~keep;
        if (r.boolean()) words[1] &= 0x00ff_01ff;
        if (k % 3 == 0) words[1] &= 0x3fff_ffff;
        var in: Instr = undefined;
        const n = decode(&words, &in) catch continue;
        decoded += 1;
        var buf: [300]u8 = undefined;
        _ = try format(&in, &buf);
        var out: [8]u32 = undefined;
        const m = try encode(&in, &out);
        if (m != n or !std.mem.eql(u32, out[0..m], words[0..n])) return error.TestUnexpectedResult;
    }
    try std.testing.expect(decoded > 20_000);

    // LLVM's vectors with bits flipped: words near valid ones, in every
    // format (EXP, MIMG and VOP3 words are rare among random ones).
    const data = @embedFile("gfx10_vectors.txt");
    var it = std.mem.splitScalar(u8, data, '\n');
    var near: usize = 0;
    var per_enc: [n_enc]usize = .{0} ** n_enc;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Syntax;
        var base: [8]u32 = .{0} ** 8;
        const nw = try parseWords(line[0..sp], &base);
        for (0..24) |_| {
            var words = base;
            const flips = 1 + r.uintLessThan(u32, 3);
            for (0..flips) |_| {
                const wi = r.uintLessThan(usize, nw);
                words[wi] ^= @as(u32, 1) << r.int(u5);
            }
            var in: Instr = undefined;
            const n = decode(words[0..nw], &in) catch continue;
            near += 1;
            per_enc[@intFromEnum(in.enc())] += 1;
            var buf: [300]u8 = undefined;
            _ = try format(&in, &buf);
            var out: [8]u32 = undefined;
            const m = try encode(&in, &out);
            if (m != n or !std.mem.eql(u32, out[0..m], words[0..n])) return error.TestUnexpectedResult;
        }
    }
    // every format decodes some of them
    for (per_enc) |c| try std.testing.expect(c > 0);
    try std.testing.expect(near > 50_000);
}

fn expectText(words: []const u32, want: []const u8) !Instr {
    var in: Instr = undefined;
    try std.testing.expectEqual(words.len, try decode(words, &in));
    var buf: [300]u8 = undefined;
    try std.testing.expectEqualStrings(want, try format(&in, &buf));
    return in;
}

test "hand-checked decodes of graphics instructions" {
    // exp pos0 v4, v5, v6, v7 done
    {
        const in = try expectText(&.{ 0xf80008cf, 0x07060504 }, "exp pos0 v4, v5, v6, v7 done");
        try std.testing.expectEqual(op("exp"), in.op);
        try std.testing.expectEqual(@as(u8, 12), in.target);
        try std.testing.expectEqual(@as(u4, 0xf), in.en);
        try std.testing.expectEqual([4]u8{ 4, 5, 6, 7 }, in.vsrc);
        try std.testing.expect(in.done and !in.vm and !in.compr);
    }
    // v_interp_p2_f32 v1, v0, attr3.w
    {
        const in = try expectText(&.{0xc8050f00}, "v_interp_p2_f32_e32 v1, v0, attr3.w");
        try std.testing.expectEqual(op("v_interp_p2_f32"), in.op);
        try std.testing.expectEqual(vgpr(1), in.dst);
        try std.testing.expectEqual(vgpr(0), in.src[0]);
        try std.testing.expectEqual(@as(u8, 3), in.attr);
        try std.testing.expectEqual(@as(u2, 3), in.chan);
    }
    // image_sample v[0:3], [v4, v9], s[8:15], s[16:19] dmask:0xf dim:SQ_RSRC_IMG_2D
    {
        const in = try expectText(&.{ 0xf0800f0a, 0x00820004, 0x00000009 }, "image_sample v[0:3], [v4, v9], s[8:15], s[16:19] dmask:0xf dim:SQ_RSRC_IMG_2D");
        try std.testing.expectEqual(op("image_sample"), in.op);
        try std.testing.expectEqual(vgpr(0), in.dst);
        try std.testing.expect(in.nsa);
        try std.testing.expectEqual(@as(u8, 2), in.naddr);
        try std.testing.expectEqual(@as(u8, 4), in.addr[0]);
        try std.testing.expectEqual(@as(u8, 9), in.addr[1]);
        try std.testing.expectEqual(@as(u16, 8), in.src[1]);
        try std.testing.expectEqual(@as(u16, 16), in.src[2]);
        try std.testing.expectEqual(@as(u4, 0xf), in.dmask);
        try std.testing.expectEqual(@as(u3, 1), in.dim);
        try std.testing.expect(!in.unorm and !in.glc and !in.slc and !in.dlc and !in.r128 and !in.a16 and !in.d16 and !in.tfe and !in.lwe);
        try std.testing.expectEqual(@as(u8, 3), in.dwords());
    }
    // s_load_dwordx4 s[4:7], s[2:3], 0x10
    {
        const in = try expectText(&.{ 0xf4080101, 0xfa000010 }, "s_load_dwordx4 s[4:7], s[2:3], 0x10");
        try std.testing.expectEqual(op("s_load_dwordx4"), in.op);
        try std.testing.expectEqual(@as(u16, 4), in.dst);
        try std.testing.expectEqual(@as(u16, 2), in.src[0]);
        try std.testing.expectEqual(NULL, in.src[1]);
        try std.testing.expectEqual(@as(u32, 0x10), in.imm);
        try std.testing.expect(!in.glc and !in.dlc);
    }
    // buffer_load_format_xyzw v[4:7], v0, s[4:7], 0 idxen
    {
        const in = try expectText(&.{ 0xe00c2000, 0x80010400 }, "buffer_load_format_xyzw v[4:7], v0, s[4:7], 0 idxen");
        try std.testing.expectEqual(op("buffer_load_format_xyzw"), in.op);
        try std.testing.expectEqual(vgpr(4), in.dst);
        try std.testing.expectEqual(vgpr(0), in.src[0]);
        try std.testing.expectEqual(@as(u16, 4), in.src[1]);
        try std.testing.expectEqual(inlineInt(0), in.src[2]);
        try std.testing.expect(in.idxen and !in.offen and !in.glc and !in.slc and !in.dlc and !in.tfe);
        try std.testing.expectEqual(@as(u32, 0), in.imm);
    }
    // one op whatever the encoding: v_add_f32 in VOP2 and in VOP3
    {
        const a = try expectText(&.{0x06020702}, "v_add_f32_e32 v1, v2, v3");
        const c = try expectText(&.{ 0xd5030001, 0x00020702 }, "v_add_f32_e64 v1, v2, v3");
        try std.testing.expectEqual(a.op, c.op);
        try std.testing.expect(!a.e64 and c.e64);
    }
    // refused: SDWA, DPP, a reserved EXP target
    var in: Instr = undefined;
    try std.testing.expectError(error.NoMatch, decode(&.{ 0x7e0202f9, 0x00060606 }, &in));
    try std.testing.expectError(error.NoMatch, decode(&.{ 0x7e0202fa, 0xff00e402 }, &in));
    try std.testing.expectError(error.NoMatch, decode(&.{ 0xf80000af, 0x07060504 }, &in));
}

test "gfx10: what LLVM refuses is refused; an instruction built by hand cannot index past the tables" {
    var in: Instr = .{};
    // v_interp_p1_f32 v1, v0, attr0.x is c8040000; attribute 33 is none.
    try std.testing.expectEqual(@as(usize, 1), try decode(&.{0xc804_0000}, &in));
    try std.testing.expectEqual(@as(u8, 0), in.attr);
    try std.testing.expectError(error.NoMatch, decode(&.{0xc804_0000 | 33 << 10}, &in));
    try std.testing.expectEqual(@as(usize, 1), try decode(&.{0xc804_0000 | 32 << 10}, &in));
    try std.testing.expectEqual(@as(u8, 32), in.attr);

    // Decoded instructions print and encode; the same ones with a field
    // set out of range answer an error, not a read outside a table.
    var words = [_]u32{0} ** 8;
    var buf: [128]u8 = undefined;
    _ = try decode(&.{0xc804_0000}, &in);
    var bad = in;
    bad.op = @intCast(defs.len);
    try std.testing.expectError(error.NoMatch, encode(&bad, &words));
    try std.testing.expectError(error.NoMatch, format(&bad, &buf));
    bad = in;
    bad.naddr = 14;
    try std.testing.expectError(error.NoMatch, encode(&bad, &words));
    bad = in;
    bad.attr = 40;
    try std.testing.expectError(error.NoMatch, format(&bad, &buf));
}
