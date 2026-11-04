//! @zpm/amdgpu gcn3 — AMD's GCN 3 instruction set as GCN 4 runs it (gfx8:
//! Polaris 21, the Radeon Pro 555X/560X of the MacBook Pro 15" 2018, is
//! gfx803), as 32-bit instruction words.
//!
//! Every instruction is one row of a table: its name, its encoding (SOP2,
//! SOPK, SOP1, SOPC, SOPP, SMEM, VOP2, VOP1, VOPC, VOP3a/b, DS, MUBUF, MTBUF,
//! FLAT), its opcode, the shape of its operands and their types. Encoding,
//! decoding, printing and parsing all read the same row. The fields and the
//! opcodes are AMD's public "AMD GCN3 ISA" reference guide (GCN 4 shares its
//! encodings); the text is LLVM's AMDGPU assembler syntax, so a line prints
//! the way `llvm-mc -mcpu=gfx803 -show-encoding` prints it and parses back.
//! The test vectors (gcn3_vectors.txt) are LLVM's own encodings of every row
//! (tools/gen_gcn3_vectors.py); LLVM was used as test data only.
//!
//! VOP1, VOP2 and VOPC instructions have their SDWA form too (a second
//! dword selecting a byte or word of each source and of the result), for
//! the instructions LLVM gives one.
//!
//! Decoding is strict: a word with a reserved or unused field set, or a form
//! this module does not model (DPP, VINTRP, EXP, MIMG), is NoMatch. So every
//! word that decodes prints, parses and encodes back to itself.
//!
//! Allocation-free: instructions are plain values, text goes into caller
//! buffers.

const std = @import("std");

pub const Error = error{
    /// The operands do not fit any form of the instruction.
    NoForm,
    /// A field does not fit its bits.
    OutOfRange,
    /// The words match no instruction this module knows.
    NoMatch,
    /// Text that is not an instruction this module knows.
    Syntax,
    /// A caller buffer is too small.
    BufferTooSmall,
};

// ── Operands ────────────────────────────────────────────────────────────────

/// Operand codes: the 9-bit source field. 0..255 is the scalar space (the
/// 8-bit SSRC fields), 256 + n is VGPR n.
pub const VCC_LO: u16 = 106;
pub const VCC_HI: u16 = 107;
pub const FLAT_SCRATCH_LO: u16 = 102;
pub const TBA_LO: u16 = 108;
pub const TMA_LO: u16 = 110;
pub const TTMP0: u16 = 112;
pub const M0: u16 = 124;
pub const EXEC_LO: u16 = 126;
pub const EXEC_HI: u16 = 127;
pub const ZERO: u16 = 128;
pub const VCCZ: u16 = 251;
pub const EXECZ: u16 = 252;
pub const SCC: u16 = 253;
pub const LDS_DIRECT: u16 = 254;
pub const LITERAL: u16 = 255;
/// src0 of a VOP1, VOP2 or VOPC instruction whose SDWA dword follows.
pub const SDWA: u16 = 249;
pub const VGPR0: u16 = 256;
/// s0..s101 exist on gfx8.
pub const SGPRS: u16 = 102;

pub fn vgpr(n: u16) u16 {
    return VGPR0 + n;
}
/// The code of an inline integer constant (-16..64).
pub fn inlineInt(x: i32) u16 {
    return if (x >= 0) @intCast(128 + x) else @intCast(192 - x);
}

/// The value types of operands; they give the width and how constants read.
pub const Ty = enum(u8) {
    none,
    b16,
    f16,
    b32,
    f32,
    b64,
    f64,
    b96,
    b128,
    b256,
    b512,

    pub fn dwords(t: Ty) u8 {
        return switch (t) {
            .none => 0,
            .b16, .f16, .b32, .f32 => 1,
            .b64, .f64 => 2,
            .b96 => 3,
            .b128 => 4,
            .b256 => 8,
            .b512 => 16,
        };
    }
    pub fn isFloat(t: Ty) bool {
        return t == .f16 or t == .f32 or t == .f64;
    }
    pub fn is16(t: Ty) bool {
        return t == .b16 or t == .f16;
    }
    pub fn is64(t: Ty) bool {
        return t == .b64 or t == .f64;
    }
};

/// The inline float constants, codes 240..248, as each width reads them.
pub const float32 = [9]u32{ 0x3f000000, 0xbf000000, 0x3f800000, 0xbf800000, 0x40000000, 0xc0000000, 0x40800000, 0xc0800000, 0x3e22f983 };
pub const float16 = [9]u16{ 0x3800, 0xb800, 0x3c00, 0xbc00, 0x4000, 0xc000, 0x4400, 0xc400, 0x3118 };
pub const float64 = [9]u64{ 0x3fe0000000000000, 0xbfe0000000000000, 0x3ff0000000000000, 0xbff0000000000000, 0x4000000000000000, 0xc000000000000000, 0x4010000000000000, 0xc010000000000000, 0x3fc45f306dc9c882 };
const float_names = [9][]const u8{ "0.5", "-0.5", "1.0", "-1.0", "2.0", "-2.0", "4.0", "-4.0", "0.15915494" };
const inv2pi64_name = "0.15915494309189532";

/// What a constant operand code reads as, for an operand of type `t`
/// (a 64-bit value; 16- and 32-bit operands use its low bits). Literals: a
/// 64-bit float takes the literal as its high dword, a 64-bit integer
/// sign-extends it (as LLVM's code generator assumes).
pub fn constValue(code: u16, lit: u32, t: Ty) ?u64 {
    if (code >= 128 and code <= 192) return code - 128;
    if (code >= 193 and code <= 208) return @bitCast(@as(i64, 192) - @as(i64, code));
    if (code >= 240 and code <= 248) {
        const i = code - 240;
        return switch (t) {
            .b16, .f16 => float16[i],
            .b64, .f64 => float64[i],
            else => float32[i],
        };
    }
    if (code == LITERAL) {
        return switch (t) {
            .f64 => @as(u64, lit) << 32,
            .b64 => @bitCast(@as(i64, @as(i32, @bitCast(lit)))),
            .b16, .f16 => lit & 0xffff,
            else => lit,
        };
    }
    return null;
}

// ── Encodings, shapes and the table ─────────────────────────────────────────

pub const Enc = enum(u8) { sop2, sopk, sop1, sopc, sopp, smem, vop2, vop1, vopc, vop3, ds, mubuf, mtbuf, flat };

/// The operands an instruction takes, and in what order its text names them.
pub const Shape = enum(u8) {
    // SALU
    sop2, // sdst, ssrc0, ssrc1
    sop1, // sdst, ssrc0
    sop1_dst, // sdst (s_getpc_b64)
    sop1_src, // ssrc0 (s_setpc_b64, s_rfe_b64, s_cbranch_join)
    sopc, // ssrc0, ssrc1
    sopk, // sdst, simm16 (s_cmpk_* read the register)
    sopk_getreg, // sdst, hwreg(...)
    sopk_setreg, // hwreg(...), sdst (read)
    sopk_setreg_imm, // hwreg(...), imm32
    sopp, // no operand
    sopp_imm, // simm16
    sopp_branch, // a target relative to the next instruction, in dwords
    sopp_waitcnt, // vmcnt(n) expcnt(n) lgkmcnt(n)
    // SMEM
    smem_load, // sdata, sbase, offset (an immediate or an SGPR)
    smem_store, // sdata, sbase, offset
    smem_none, // s_dcache_inv
    smem_time, // sdata (s_memtime)
    // VALU
    vop, // vdst, src0[, src1[, src2]]
    vop_none, // v_nop
    vop_sdst, // an SGPR destination: v_readfirstlane_b32, v_readlane_b32
    vop_carry, // vdst, vcc|sdst, src0, src1 (v_add_u32)
    vop_carry_in, // vdst, vcc|sdst, src0, src1, vcc|ssrc2 (v_addc_u32)
    vop_cndmask, // vdst, src0, src1, vcc|ssrc2
    vop_madmk, // vdst, src0, K, vsrc1
    vop_madak, // vdst, src0, vsrc1, K
    vopc, // vcc|sdst, src0, src1
    vop3b, // vdst, sdst, src0, src1, src2 (v_div_scale_f32, v_mad_u64_u32)
    // DS
    ds_addr_data, // addr, data0
    ds_addr_data2, // addr, data0, data1
    ds_write2, // addr, data0, data1 offset0 offset1
    ds_read, // vdst, addr
    ds_read2, // vdst, addr offset0 offset1
    ds_rtn, // vdst, addr, data0
    ds_rtn2, // vdst, addr, data0, data1
    ds_rtn_write2, // vdst, addr, data0, data1 offset0 offset1
    ds_swizzle, // vdst, addr offset:swizzle(...)
    ds_vdst, // vdst (ds_append)
    ds_none, // ds_nop
    // MUBUF, MTBUF
    buf_load, // vdata, vaddr|off, srsrc, soffset
    buf_store,
    buf_atomic, // vdata is the data, and the result with glc
    buf_none, // buffer_wbinvl1
    // FLAT
    flat_load, // vdst, vaddr
    flat_store, // vaddr, vdata
    flat_atomic, // [vdst,] vaddr, vdata (the result with glc)
};

pub const Def = struct {
    name: []const u8,
    enc: Enc,
    code: u16,
    shape: Shape,
    /// The destination's type (for memory: the data's).
    d: Ty,
    /// The sources' types (SMEM: sbase; DS: addr, data0, data1; FLAT: addr,
    /// data).
    s: [3]Ty,
    /// VOP1, VOP2 and VOPC: also has the VOP3 form (printed _e32 and _e64).
    e64: bool,

    pub fn nsrc(d: *const Def) u8 {
        var n: u8 = 0;
        for (d.s) |t| {
            if (t != .none) n += 1;
        }
        return n;
    }
};

const Row = struct { []const u8, Enc, u16, Shape, Ty, Ty, Ty, Ty, bool };

/// Float comparisons (code + 0..15) and integer comparisons (code + 0..7):
/// a row whose name holds {f} or {i} stands for its family.
pub const fconds = [16][]const u8{ "f", "lt", "eq", "le", "gt", "lg", "ge", "o", "u", "nge", "nlg", "ngt", "nle", "neq", "nlt", "tru" };
pub const iconds = [8][]const u8{ "f", "lt", "eq", "le", "gt", "ne", "ge", "t" };

// The rows. One per line, the same fields for every encoding:
//   name, encoding, opcode, shape, dst type, src0..2 types, has _e64
// (tools/gen_gcn3_vectors.py reads these lines).
const rows = [_]Row{
    // SOP2
    .{ "s_add_u32", .sop2, 0, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_sub_u32", .sop2, 1, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_add_i32", .sop2, 2, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_sub_i32", .sop2, 3, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_addc_u32", .sop2, 4, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_subb_u32", .sop2, 5, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_min_i32", .sop2, 6, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_min_u32", .sop2, 7, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_max_i32", .sop2, 8, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_max_u32", .sop2, 9, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_cselect_b32", .sop2, 10, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_cselect_b64", .sop2, 11, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_and_b32", .sop2, 12, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_and_b64", .sop2, 13, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_or_b32", .sop2, 14, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_or_b64", .sop2, 15, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_xor_b32", .sop2, 16, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_xor_b64", .sop2, 17, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_andn2_b32", .sop2, 18, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_andn2_b64", .sop2, 19, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_orn2_b32", .sop2, 20, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_orn2_b64", .sop2, 21, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_nand_b32", .sop2, 22, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_nand_b64", .sop2, 23, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_nor_b32", .sop2, 24, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_nor_b64", .sop2, 25, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_xnor_b32", .sop2, 26, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_xnor_b64", .sop2, 27, .sop2, .b64, .b64, .b64, .none, false },
    .{ "s_lshl_b32", .sop2, 28, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_lshl_b64", .sop2, 29, .sop2, .b64, .b64, .b32, .none, false },
    .{ "s_lshr_b32", .sop2, 30, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_lshr_b64", .sop2, 31, .sop2, .b64, .b64, .b32, .none, false },
    .{ "s_ashr_i32", .sop2, 32, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_ashr_i64", .sop2, 33, .sop2, .b64, .b64, .b32, .none, false },
    .{ "s_bfm_b32", .sop2, 34, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_bfm_b64", .sop2, 35, .sop2, .b64, .b32, .b32, .none, false },
    .{ "s_mul_i32", .sop2, 36, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_bfe_u32", .sop2, 37, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_bfe_i32", .sop2, 38, .sop2, .b32, .b32, .b32, .none, false },
    .{ "s_bfe_u64", .sop2, 39, .sop2, .b64, .b64, .b32, .none, false },
    .{ "s_bfe_i64", .sop2, 40, .sop2, .b64, .b64, .b32, .none, false },
    .{ "s_absdiff_i32", .sop2, 42, .sop2, .b32, .b32, .b32, .none, false },
    // SOPK
    .{ "s_movk_i32", .sopk, 0, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmovk_i32", .sopk, 1, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_eq_i32", .sopk, 2, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_lg_i32", .sopk, 3, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_gt_i32", .sopk, 4, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_ge_i32", .sopk, 5, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_lt_i32", .sopk, 6, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_le_i32", .sopk, 7, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_eq_u32", .sopk, 8, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_lg_u32", .sopk, 9, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_gt_u32", .sopk, 10, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_ge_u32", .sopk, 11, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_lt_u32", .sopk, 12, .sopk, .b32, .none, .none, .none, false },
    .{ "s_cmpk_le_u32", .sopk, 13, .sopk, .b32, .none, .none, .none, false },
    .{ "s_addk_i32", .sopk, 14, .sopk, .b32, .none, .none, .none, false },
    .{ "s_mulk_i32", .sopk, 15, .sopk, .b32, .none, .none, .none, false },
    .{ "s_getreg_b32", .sopk, 17, .sopk_getreg, .b32, .none, .none, .none, false },
    .{ "s_setreg_b32", .sopk, 18, .sopk_setreg, .b32, .none, .none, .none, false },
    .{ "s_setreg_imm32_b32", .sopk, 20, .sopk_setreg_imm, .none, .none, .none, .none, false },
    // SOP1
    .{ "s_mov_b32", .sop1, 0, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_mov_b64", .sop1, 1, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_cmov_b32", .sop1, 2, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_cmov_b64", .sop1, 3, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_not_b32", .sop1, 4, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_not_b64", .sop1, 5, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_wqm_b32", .sop1, 6, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_wqm_b64", .sop1, 7, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_brev_b32", .sop1, 8, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_brev_b64", .sop1, 9, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_bcnt0_i32_b32", .sop1, 10, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_bcnt0_i32_b64", .sop1, 11, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_bcnt1_i32_b32", .sop1, 12, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_bcnt1_i32_b64", .sop1, 13, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_ff0_i32_b32", .sop1, 14, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_ff0_i32_b64", .sop1, 15, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_ff1_i32_b32", .sop1, 16, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_ff1_i32_b64", .sop1, 17, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_flbit_i32_b32", .sop1, 18, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_flbit_i32_b64", .sop1, 19, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_flbit_i32", .sop1, 20, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_flbit_i32_i64", .sop1, 21, .sop1, .b32, .b64, .none, .none, false },
    .{ "s_sext_i32_i8", .sop1, 22, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_sext_i32_i16", .sop1, 23, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_bitset0_b32", .sop1, 24, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_bitset0_b64", .sop1, 25, .sop1, .b64, .b32, .none, .none, false },
    .{ "s_bitset1_b32", .sop1, 26, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_bitset1_b64", .sop1, 27, .sop1, .b64, .b32, .none, .none, false },
    .{ "s_getpc_b64", .sop1, 28, .sop1_dst, .b64, .none, .none, .none, false },
    .{ "s_setpc_b64", .sop1, 29, .sop1_src, .none, .b64, .none, .none, false },
    .{ "s_swappc_b64", .sop1, 30, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_rfe_b64", .sop1, 31, .sop1_src, .none, .b64, .none, .none, false },
    .{ "s_and_saveexec_b64", .sop1, 32, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_or_saveexec_b64", .sop1, 33, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_xor_saveexec_b64", .sop1, 34, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_andn2_saveexec_b64", .sop1, 35, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_orn2_saveexec_b64", .sop1, 36, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_nand_saveexec_b64", .sop1, 37, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_nor_saveexec_b64", .sop1, 38, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_xnor_saveexec_b64", .sop1, 39, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_quadmask_b32", .sop1, 40, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_quadmask_b64", .sop1, 41, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_movrels_b32", .sop1, 42, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_movrels_b64", .sop1, 43, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_movreld_b32", .sop1, 44, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_movreld_b64", .sop1, 45, .sop1, .b64, .b64, .none, .none, false },
    .{ "s_cbranch_join", .sop1, 46, .sop1_src, .none, .b32, .none, .none, false },
    .{ "s_abs_i32", .sop1, 48, .sop1, .b32, .b32, .none, .none, false },
    .{ "s_set_gpr_idx_idx", .sop1, 50, .sop1_src, .none, .b32, .none, .none, false },
    // SOPC
    .{ "s_cmp_eq_i32", .sopc, 0, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_lg_i32", .sopc, 1, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_gt_i32", .sopc, 2, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_ge_i32", .sopc, 3, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_lt_i32", .sopc, 4, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_le_i32", .sopc, 5, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_eq_u32", .sopc, 6, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_lg_u32", .sopc, 7, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_gt_u32", .sopc, 8, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_ge_u32", .sopc, 9, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_lt_u32", .sopc, 10, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_le_u32", .sopc, 11, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_bitcmp0_b32", .sopc, 12, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_bitcmp1_b32", .sopc, 13, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_bitcmp0_b64", .sopc, 14, .sopc, .none, .b64, .b32, .none, false },
    .{ "s_bitcmp1_b64", .sopc, 15, .sopc, .none, .b64, .b32, .none, false },
    .{ "s_setvskip", .sopc, 16, .sopc, .none, .b32, .b32, .none, false },
    .{ "s_cmp_eq_u64", .sopc, 18, .sopc, .none, .b64, .b64, .none, false },
    .{ "s_cmp_lg_u64", .sopc, 19, .sopc, .none, .b64, .b64, .none, false },
    // SOPP
    .{ "s_nop", .sopp, 0, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_endpgm", .sopp, 1, .sopp, .none, .none, .none, .none, false },
    .{ "s_branch", .sopp, 2, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_wakeup", .sopp, 3, .sopp, .none, .none, .none, .none, false },
    .{ "s_cbranch_scc0", .sopp, 4, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_scc1", .sopp, 5, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_vccz", .sopp, 6, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_vccnz", .sopp, 7, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_execz", .sopp, 8, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_execnz", .sopp, 9, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_barrier", .sopp, 10, .sopp, .none, .none, .none, .none, false },
    .{ "s_setkill", .sopp, 11, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_waitcnt", .sopp, 12, .sopp_waitcnt, .none, .none, .none, .none, false },
    .{ "s_sethalt", .sopp, 13, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_sleep", .sopp, 14, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_setprio", .sopp, 15, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_trap", .sopp, 18, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_icache_inv", .sopp, 19, .sopp, .none, .none, .none, .none, false },
    .{ "s_incperflevel", .sopp, 20, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_decperflevel", .sopp, 21, .sopp_imm, .none, .none, .none, .none, false },
    .{ "s_ttracedata", .sopp, 22, .sopp, .none, .none, .none, .none, false },
    .{ "s_cbranch_cdbgsys", .sopp, 23, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_cdbguser", .sopp, 24, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_cdbgsys_or_user", .sopp, 25, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_cbranch_cdbgsys_and_user", .sopp, 26, .sopp_branch, .none, .none, .none, .none, false },
    .{ "s_endpgm_saved", .sopp, 27, .sopp, .none, .none, .none, .none, false },
    .{ "s_set_gpr_idx_off", .sopp, 28, .sopp, .none, .none, .none, .none, false },
    // SMEM
    .{ "s_load_dword", .smem, 0, .smem_load, .b32, .b64, .none, .none, false },
    .{ "s_load_dwordx2", .smem, 1, .smem_load, .b64, .b64, .none, .none, false },
    .{ "s_load_dwordx4", .smem, 2, .smem_load, .b128, .b64, .none, .none, false },
    .{ "s_load_dwordx8", .smem, 3, .smem_load, .b256, .b64, .none, .none, false },
    .{ "s_load_dwordx16", .smem, 4, .smem_load, .b512, .b64, .none, .none, false },
    .{ "s_buffer_load_dword", .smem, 8, .smem_load, .b32, .b128, .none, .none, false },
    .{ "s_buffer_load_dwordx2", .smem, 9, .smem_load, .b64, .b128, .none, .none, false },
    .{ "s_buffer_load_dwordx4", .smem, 10, .smem_load, .b128, .b128, .none, .none, false },
    .{ "s_buffer_load_dwordx8", .smem, 11, .smem_load, .b256, .b128, .none, .none, false },
    .{ "s_buffer_load_dwordx16", .smem, 12, .smem_load, .b512, .b128, .none, .none, false },
    .{ "s_store_dword", .smem, 16, .smem_store, .b32, .b64, .none, .none, false },
    .{ "s_store_dwordx2", .smem, 17, .smem_store, .b64, .b64, .none, .none, false },
    .{ "s_store_dwordx4", .smem, 18, .smem_store, .b128, .b64, .none, .none, false },
    .{ "s_buffer_store_dword", .smem, 24, .smem_store, .b32, .b128, .none, .none, false },
    .{ "s_buffer_store_dwordx2", .smem, 25, .smem_store, .b64, .b128, .none, .none, false },
    .{ "s_buffer_store_dwordx4", .smem, 26, .smem_store, .b128, .b128, .none, .none, false },
    .{ "s_dcache_inv", .smem, 32, .smem_none, .none, .none, .none, .none, false },
    .{ "s_dcache_wb", .smem, 33, .smem_none, .none, .none, .none, .none, false },
    .{ "s_dcache_inv_vol", .smem, 34, .smem_none, .none, .none, .none, .none, false },
    .{ "s_dcache_wb_vol", .smem, 35, .smem_none, .none, .none, .none, .none, false },
    .{ "s_memtime", .smem, 36, .smem_time, .b64, .none, .none, .none, false },
    .{ "s_memrealtime", .smem, 37, .smem_time, .b64, .none, .none, .none, false },
    // VOP2
    .{ "v_cndmask_b32", .vop2, 0, .vop_cndmask, .b32, .b32, .b32, .b64, true },
    .{ "v_add_f32", .vop2, 1, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_sub_f32", .vop2, 2, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_subrev_f32", .vop2, 3, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_mul_legacy_f32", .vop2, 4, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_mul_f32", .vop2, 5, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_mul_i32_i24", .vop2, 6, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_mul_hi_i32_i24", .vop2, 7, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_mul_u32_u24", .vop2, 8, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_mul_hi_u32_u24", .vop2, 9, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_min_f32", .vop2, 10, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_max_f32", .vop2, 11, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_min_i32", .vop2, 12, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_max_i32", .vop2, 13, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_min_u32", .vop2, 14, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_max_u32", .vop2, 15, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_lshrrev_b32", .vop2, 16, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_ashrrev_i32", .vop2, 17, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_lshlrev_b32", .vop2, 18, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_and_b32", .vop2, 19, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_or_b32", .vop2, 20, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_xor_b32", .vop2, 21, .vop, .b32, .b32, .b32, .none, true },
    .{ "v_mac_f32", .vop2, 22, .vop, .f32, .f32, .f32, .none, true },
    .{ "v_madmk_f32", .vop2, 23, .vop_madmk, .f32, .f32, .f32, .none, false },
    .{ "v_madak_f32", .vop2, 24, .vop_madak, .f32, .f32, .f32, .none, false },
    .{ "v_add_u32", .vop2, 25, .vop_carry, .b32, .b32, .b32, .none, true },
    .{ "v_sub_u32", .vop2, 26, .vop_carry, .b32, .b32, .b32, .none, true },
    .{ "v_subrev_u32", .vop2, 27, .vop_carry, .b32, .b32, .b32, .none, true },
    .{ "v_addc_u32", .vop2, 28, .vop_carry_in, .b32, .b32, .b32, .b64, true },
    .{ "v_subb_u32", .vop2, 29, .vop_carry_in, .b32, .b32, .b32, .b64, true },
    .{ "v_subbrev_u32", .vop2, 30, .vop_carry_in, .b32, .b32, .b32, .b64, true },
    .{ "v_add_f16", .vop2, 31, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_sub_f16", .vop2, 32, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_subrev_f16", .vop2, 33, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_mul_f16", .vop2, 34, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_mac_f16", .vop2, 35, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_madmk_f16", .vop2, 36, .vop_madmk, .f16, .f16, .f16, .none, false },
    .{ "v_madak_f16", .vop2, 37, .vop_madak, .f16, .f16, .f16, .none, false },
    .{ "v_add_u16", .vop2, 38, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_sub_u16", .vop2, 39, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_subrev_u16", .vop2, 40, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_mul_lo_u16", .vop2, 41, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_lshlrev_b16", .vop2, 42, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_lshrrev_b16", .vop2, 43, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_ashrrev_i16", .vop2, 44, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_max_f16", .vop2, 45, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_min_f16", .vop2, 46, .vop, .f16, .f16, .f16, .none, true },
    .{ "v_max_u16", .vop2, 47, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_max_i16", .vop2, 48, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_min_u16", .vop2, 49, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_min_i16", .vop2, 50, .vop, .b16, .b16, .b16, .none, true },
    .{ "v_ldexp_f16", .vop2, 51, .vop, .f16, .f16, .b16, .none, true },
    // VOP1
    .{ "v_nop", .vop1, 0, .vop_none, .none, .none, .none, .none, false },
    .{ "v_mov_b32", .vop1, 1, .vop, .b32, .b32, .none, .none, true },
    .{ "v_readfirstlane_b32", .vop1, 2, .vop_sdst, .b32, .b32, .none, .none, false },
    .{ "v_cvt_i32_f64", .vop1, 3, .vop, .b32, .f64, .none, .none, true },
    .{ "v_cvt_f64_i32", .vop1, 4, .vop, .f64, .b32, .none, .none, true },
    .{ "v_cvt_f32_i32", .vop1, 5, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_f32_u32", .vop1, 6, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_u32_f32", .vop1, 7, .vop, .b32, .f32, .none, .none, true },
    .{ "v_cvt_i32_f32", .vop1, 8, .vop, .b32, .f32, .none, .none, true },
    .{ "v_cvt_f16_f32", .vop1, 10, .vop, .f16, .f32, .none, .none, true },
    .{ "v_cvt_f32_f16", .vop1, 11, .vop, .f32, .f16, .none, .none, true },
    .{ "v_cvt_rpi_i32_f32", .vop1, 12, .vop, .b32, .f32, .none, .none, true },
    .{ "v_cvt_flr_i32_f32", .vop1, 13, .vop, .b32, .f32, .none, .none, true },
    .{ "v_cvt_off_f32_i4", .vop1, 14, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_f32_f64", .vop1, 15, .vop, .f32, .f64, .none, .none, true },
    .{ "v_cvt_f64_f32", .vop1, 16, .vop, .f64, .f32, .none, .none, true },
    .{ "v_cvt_f32_ubyte0", .vop1, 17, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_f32_ubyte1", .vop1, 18, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_f32_ubyte2", .vop1, 19, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_f32_ubyte3", .vop1, 20, .vop, .f32, .b32, .none, .none, true },
    .{ "v_cvt_u32_f64", .vop1, 21, .vop, .b32, .f64, .none, .none, true },
    .{ "v_cvt_f64_u32", .vop1, 22, .vop, .f64, .b32, .none, .none, true },
    .{ "v_trunc_f64", .vop1, 23, .vop, .f64, .f64, .none, .none, true },
    .{ "v_ceil_f64", .vop1, 24, .vop, .f64, .f64, .none, .none, true },
    .{ "v_rndne_f64", .vop1, 25, .vop, .f64, .f64, .none, .none, true },
    .{ "v_floor_f64", .vop1, 26, .vop, .f64, .f64, .none, .none, true },
    .{ "v_fract_f32", .vop1, 27, .vop, .f32, .f32, .none, .none, true },
    .{ "v_trunc_f32", .vop1, 28, .vop, .f32, .f32, .none, .none, true },
    .{ "v_ceil_f32", .vop1, 29, .vop, .f32, .f32, .none, .none, true },
    .{ "v_rndne_f32", .vop1, 30, .vop, .f32, .f32, .none, .none, true },
    .{ "v_floor_f32", .vop1, 31, .vop, .f32, .f32, .none, .none, true },
    .{ "v_exp_f32", .vop1, 32, .vop, .f32, .f32, .none, .none, true },
    .{ "v_log_f32", .vop1, 33, .vop, .f32, .f32, .none, .none, true },
    .{ "v_rcp_f32", .vop1, 34, .vop, .f32, .f32, .none, .none, true },
    .{ "v_rcp_iflag_f32", .vop1, 35, .vop, .f32, .f32, .none, .none, true },
    .{ "v_rsq_f32", .vop1, 36, .vop, .f32, .f32, .none, .none, true },
    .{ "v_rcp_f64", .vop1, 37, .vop, .f64, .f64, .none, .none, true },
    .{ "v_rsq_f64", .vop1, 38, .vop, .f64, .f64, .none, .none, true },
    .{ "v_sqrt_f32", .vop1, 39, .vop, .f32, .f32, .none, .none, true },
    .{ "v_sqrt_f64", .vop1, 40, .vop, .f64, .f64, .none, .none, true },
    .{ "v_sin_f32", .vop1, 41, .vop, .f32, .f32, .none, .none, true },
    .{ "v_cos_f32", .vop1, 42, .vop, .f32, .f32, .none, .none, true },
    .{ "v_not_b32", .vop1, 43, .vop, .b32, .b32, .none, .none, true },
    .{ "v_bfrev_b32", .vop1, 44, .vop, .b32, .b32, .none, .none, true },
    .{ "v_ffbh_u32", .vop1, 45, .vop, .b32, .b32, .none, .none, true },
    .{ "v_ffbl_b32", .vop1, 46, .vop, .b32, .b32, .none, .none, true },
    .{ "v_ffbh_i32", .vop1, 47, .vop, .b32, .b32, .none, .none, true },
    .{ "v_frexp_exp_i32_f64", .vop1, 48, .vop, .b32, .f64, .none, .none, true },
    .{ "v_frexp_mant_f64", .vop1, 49, .vop, .f64, .f64, .none, .none, true },
    .{ "v_fract_f64", .vop1, 50, .vop, .f64, .f64, .none, .none, true },
    .{ "v_frexp_exp_i32_f32", .vop1, 51, .vop, .b32, .f32, .none, .none, true },
    .{ "v_frexp_mant_f32", .vop1, 52, .vop, .f32, .f32, .none, .none, true },
    .{ "v_clrexcp", .vop1, 53, .vop_none, .none, .none, .none, .none, true },
    .{ "v_movreld_b32", .vop1, 54, .vop, .b32, .b32, .none, .none, true },
    .{ "v_movrels_b32", .vop1, 55, .vop, .b32, .b32, .none, .none, true },
    .{ "v_movrelsd_b32", .vop1, 56, .vop, .b32, .b32, .none, .none, true },
    .{ "v_cvt_f16_u16", .vop1, 57, .vop, .f16, .b16, .none, .none, true },
    .{ "v_cvt_f16_i16", .vop1, 58, .vop, .f16, .b16, .none, .none, true },
    .{ "v_cvt_u16_f16", .vop1, 59, .vop, .b16, .f16, .none, .none, true },
    .{ "v_cvt_i16_f16", .vop1, 60, .vop, .b16, .f16, .none, .none, true },
    .{ "v_rcp_f16", .vop1, 61, .vop, .f16, .f16, .none, .none, true },
    .{ "v_sqrt_f16", .vop1, 62, .vop, .f16, .f16, .none, .none, true },
    .{ "v_rsq_f16", .vop1, 63, .vop, .f16, .f16, .none, .none, true },
    .{ "v_log_f16", .vop1, 64, .vop, .f16, .f16, .none, .none, true },
    .{ "v_exp_f16", .vop1, 65, .vop, .f16, .f16, .none, .none, true },
    .{ "v_frexp_mant_f16", .vop1, 66, .vop, .f16, .f16, .none, .none, true },
    .{ "v_frexp_exp_i16_f16", .vop1, 67, .vop, .b16, .f16, .none, .none, true },
    .{ "v_floor_f16", .vop1, 68, .vop, .f16, .f16, .none, .none, true },
    .{ "v_ceil_f16", .vop1, 69, .vop, .f16, .f16, .none, .none, true },
    .{ "v_trunc_f16", .vop1, 70, .vop, .f16, .f16, .none, .none, true },
    .{ "v_rndne_f16", .vop1, 71, .vop, .f16, .f16, .none, .none, true },
    .{ "v_fract_f16", .vop1, 72, .vop, .f16, .f16, .none, .none, true },
    .{ "v_sin_f16", .vop1, 73, .vop, .f16, .f16, .none, .none, true },
    .{ "v_cos_f16", .vop1, 74, .vop, .f16, .f16, .none, .none, true },
    .{ "v_exp_legacy_f32", .vop1, 75, .vop, .f32, .f32, .none, .none, true },
    .{ "v_log_legacy_f32", .vop1, 76, .vop, .f32, .f32, .none, .none, true },
    // VOPC
    .{ "v_cmp_class_f32", .vopc, 0x10, .vopc, .none, .f32, .b32, .none, true },
    .{ "v_cmpx_class_f32", .vopc, 0x11, .vopc, .none, .f32, .b32, .none, true },
    .{ "v_cmp_class_f64", .vopc, 0x12, .vopc, .none, .f64, .b32, .none, true },
    .{ "v_cmpx_class_f64", .vopc, 0x13, .vopc, .none, .f64, .b32, .none, true },
    .{ "v_cmp_class_f16", .vopc, 0x14, .vopc, .none, .f16, .b16, .none, true },
    .{ "v_cmpx_class_f16", .vopc, 0x15, .vopc, .none, .f16, .b16, .none, true },
    .{ "v_cmp_{f}_f16", .vopc, 0x20, .vopc, .none, .f16, .f16, .none, true },
    .{ "v_cmpx_{f}_f16", .vopc, 0x30, .vopc, .none, .f16, .f16, .none, true },
    .{ "v_cmp_{f}_f32", .vopc, 0x40, .vopc, .none, .f32, .f32, .none, true },
    .{ "v_cmpx_{f}_f32", .vopc, 0x50, .vopc, .none, .f32, .f32, .none, true },
    .{ "v_cmp_{f}_f64", .vopc, 0x60, .vopc, .none, .f64, .f64, .none, true },
    .{ "v_cmpx_{f}_f64", .vopc, 0x70, .vopc, .none, .f64, .f64, .none, true },
    .{ "v_cmp_{i}_i16", .vopc, 0xa0, .vopc, .none, .b16, .b16, .none, true },
    .{ "v_cmp_{i}_u16", .vopc, 0xa8, .vopc, .none, .b16, .b16, .none, true },
    .{ "v_cmpx_{i}_i16", .vopc, 0xb0, .vopc, .none, .b16, .b16, .none, true },
    .{ "v_cmpx_{i}_u16", .vopc, 0xb8, .vopc, .none, .b16, .b16, .none, true },
    .{ "v_cmp_{i}_i32", .vopc, 0xc0, .vopc, .none, .b32, .b32, .none, true },
    .{ "v_cmp_{i}_u32", .vopc, 0xc8, .vopc, .none, .b32, .b32, .none, true },
    .{ "v_cmpx_{i}_i32", .vopc, 0xd0, .vopc, .none, .b32, .b32, .none, true },
    .{ "v_cmpx_{i}_u32", .vopc, 0xd8, .vopc, .none, .b32, .b32, .none, true },
    .{ "v_cmp_{i}_i64", .vopc, 0xe0, .vopc, .none, .b64, .b64, .none, true },
    .{ "v_cmp_{i}_u64", .vopc, 0xe8, .vopc, .none, .b64, .b64, .none, true },
    .{ "v_cmpx_{i}_i64", .vopc, 0xf0, .vopc, .none, .b64, .b64, .none, true },
    .{ "v_cmpx_{i}_u64", .vopc, 0xf8, .vopc, .none, .b64, .b64, .none, true },
    // VOP3 only
    .{ "v_mad_legacy_f32", .vop3, 0x1c0, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_mad_f32", .vop3, 0x1c1, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_mad_i32_i24", .vop3, 0x1c2, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_mad_u32_u24", .vop3, 0x1c3, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_cubeid_f32", .vop3, 0x1c4, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_cubesc_f32", .vop3, 0x1c5, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_cubetc_f32", .vop3, 0x1c6, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_cubema_f32", .vop3, 0x1c7, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_bfe_u32", .vop3, 0x1c8, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_bfe_i32", .vop3, 0x1c9, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_bfi_b32", .vop3, 0x1ca, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_fma_f32", .vop3, 0x1cb, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_fma_f64", .vop3, 0x1cc, .vop, .f64, .f64, .f64, .f64, false },
    .{ "v_lerp_u8", .vop3, 0x1cd, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_alignbit_b32", .vop3, 0x1ce, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_alignbyte_b32", .vop3, 0x1cf, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_min3_f32", .vop3, 0x1d0, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_min3_i32", .vop3, 0x1d1, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_min3_u32", .vop3, 0x1d2, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_max3_f32", .vop3, 0x1d3, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_max3_i32", .vop3, 0x1d4, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_max3_u32", .vop3, 0x1d5, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_med3_f32", .vop3, 0x1d6, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_med3_i32", .vop3, 0x1d7, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_med3_u32", .vop3, 0x1d8, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_sad_u8", .vop3, 0x1d9, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_sad_hi_u8", .vop3, 0x1da, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_sad_u16", .vop3, 0x1db, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_sad_u32", .vop3, 0x1dc, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_cvt_pk_u8_f32", .vop3, 0x1dd, .vop, .b32, .f32, .b32, .b32, false },
    .{ "v_div_fixup_f32", .vop3, 0x1de, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_div_fixup_f64", .vop3, 0x1df, .vop, .f64, .f64, .f64, .f64, false },
    .{ "v_div_scale_f32", .vop3, 0x1e0, .vop3b, .f32, .f32, .f32, .f32, false },
    .{ "v_div_scale_f64", .vop3, 0x1e1, .vop3b, .f64, .f64, .f64, .f64, false },
    .{ "v_div_fmas_f32", .vop3, 0x1e2, .vop, .f32, .f32, .f32, .f32, false },
    .{ "v_div_fmas_f64", .vop3, 0x1e3, .vop, .f64, .f64, .f64, .f64, false },
    .{ "v_msad_u8", .vop3, 0x1e4, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_qsad_pk_u16_u8", .vop3, 0x1e5, .vop, .b64, .b64, .b32, .b64, false },
    .{ "v_mqsad_pk_u16_u8", .vop3, 0x1e6, .vop, .b64, .b64, .b32, .b64, false },
    .{ "v_mqsad_u32_u8", .vop3, 0x1e7, .vop, .b128, .b64, .b32, .b128, false },
    .{ "v_mad_u64_u32", .vop3, 0x1e8, .vop3b, .b64, .b32, .b32, .b64, false },
    .{ "v_mad_i64_i32", .vop3, 0x1e9, .vop3b, .b64, .b32, .b32, .b64, false },
    .{ "v_mad_f16", .vop3, 0x1ea, .vop, .f16, .f16, .f16, .f16, false },
    .{ "v_mad_u16", .vop3, 0x1eb, .vop, .b16, .b16, .b16, .b16, false },
    .{ "v_mad_i16", .vop3, 0x1ec, .vop, .b16, .b16, .b16, .b16, false },
    .{ "v_perm_b32", .vop3, 0x1ed, .vop, .b32, .b32, .b32, .b32, false },
    .{ "v_fma_f16", .vop3, 0x1ee, .vop, .f16, .f16, .f16, .f16, false },
    .{ "v_div_fixup_f16", .vop3, 0x1ef, .vop, .f16, .f16, .f16, .f16, false },
    .{ "v_cvt_pkaccum_u8_f32", .vop3, 0x1f0, .vop, .b32, .f32, .b32, .none, false },
    .{ "v_add_f64", .vop3, 0x280, .vop, .f64, .f64, .f64, .none, false },
    .{ "v_mul_f64", .vop3, 0x281, .vop, .f64, .f64, .f64, .none, false },
    .{ "v_min_f64", .vop3, 0x282, .vop, .f64, .f64, .f64, .none, false },
    .{ "v_max_f64", .vop3, 0x283, .vop, .f64, .f64, .f64, .none, false },
    .{ "v_ldexp_f64", .vop3, 0x284, .vop, .f64, .f64, .b32, .none, false },
    .{ "v_mul_lo_u32", .vop3, 0x285, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_mul_hi_u32", .vop3, 0x286, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_mul_hi_i32", .vop3, 0x287, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_ldexp_f32", .vop3, 0x288, .vop, .f32, .f32, .b32, .none, false },
    .{ "v_readlane_b32", .vop3, 0x289, .vop_sdst, .b32, .b32, .b32, .none, false },
    .{ "v_writelane_b32", .vop3, 0x28a, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_bcnt_u32_b32", .vop3, 0x28b, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_mbcnt_lo_u32_b32", .vop3, 0x28c, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_mbcnt_hi_u32_b32", .vop3, 0x28d, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_lshlrev_b64", .vop3, 0x28f, .vop, .b64, .b32, .b64, .none, false },
    .{ "v_lshrrev_b64", .vop3, 0x290, .vop, .b64, .b32, .b64, .none, false },
    .{ "v_ashrrev_i64", .vop3, 0x291, .vop, .b64, .b32, .b64, .none, false },
    .{ "v_trig_preop_f64", .vop3, 0x292, .vop, .f64, .f64, .b32, .none, false },
    .{ "v_bfm_b32", .vop3, 0x293, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_cvt_pknorm_i16_f32", .vop3, 0x294, .vop, .b32, .f32, .f32, .none, false },
    .{ "v_cvt_pknorm_u16_f32", .vop3, 0x295, .vop, .b32, .f32, .f32, .none, false },
    .{ "v_cvt_pkrtz_f16_f32", .vop3, 0x296, .vop, .b32, .f32, .f32, .none, false },
    .{ "v_cvt_pk_u16_u32", .vop3, 0x297, .vop, .b32, .b32, .b32, .none, false },
    .{ "v_cvt_pk_i16_i32", .vop3, 0x298, .vop, .b32, .b32, .b32, .none, false },
    // DS
    .{ "ds_add_u32", .ds, 0, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_sub_u32", .ds, 1, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_rsub_u32", .ds, 2, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_inc_u32", .ds, 3, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_dec_u32", .ds, 4, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_min_i32", .ds, 5, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_max_i32", .ds, 6, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_min_u32", .ds, 7, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_max_u32", .ds, 8, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_and_b32", .ds, 9, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_or_b32", .ds, 10, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_xor_b32", .ds, 11, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_mskor_b32", .ds, 12, .ds_addr_data2, .none, .b32, .b32, .b32, false },
    .{ "ds_write_b32", .ds, 13, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_write2_b32", .ds, 14, .ds_write2, .none, .b32, .b32, .b32, false },
    .{ "ds_write2st64_b32", .ds, 15, .ds_write2, .none, .b32, .b32, .b32, false },
    .{ "ds_cmpst_b32", .ds, 16, .ds_addr_data2, .none, .b32, .b32, .b32, false },
    .{ "ds_cmpst_f32", .ds, 17, .ds_addr_data2, .none, .b32, .b32, .b32, false },
    .{ "ds_min_f32", .ds, 18, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_max_f32", .ds, 19, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_nop", .ds, 20, .ds_none, .none, .none, .none, .none, false },
    .{ "ds_add_f32", .ds, 21, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_write_b8", .ds, 30, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_write_b16", .ds, 31, .ds_addr_data, .none, .b32, .b32, .none, false },
    .{ "ds_add_rtn_u32", .ds, 32, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_sub_rtn_u32", .ds, 33, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_rsub_rtn_u32", .ds, 34, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_inc_rtn_u32", .ds, 35, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_dec_rtn_u32", .ds, 36, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_min_rtn_i32", .ds, 37, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_max_rtn_i32", .ds, 38, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_min_rtn_u32", .ds, 39, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_max_rtn_u32", .ds, 40, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_and_rtn_b32", .ds, 41, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_or_rtn_b32", .ds, 42, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_xor_rtn_b32", .ds, 43, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_mskor_rtn_b32", .ds, 44, .ds_rtn2, .b32, .b32, .b32, .b32, false },
    .{ "ds_wrxchg_rtn_b32", .ds, 45, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_wrxchg2_rtn_b32", .ds, 46, .ds_rtn_write2, .b64, .b32, .b32, .b32, false },
    .{ "ds_wrxchg2st64_rtn_b32", .ds, 47, .ds_rtn_write2, .b64, .b32, .b32, .b32, false },
    .{ "ds_cmpst_rtn_b32", .ds, 48, .ds_rtn2, .b32, .b32, .b32, .b32, false },
    .{ "ds_cmpst_rtn_f32", .ds, 49, .ds_rtn2, .b32, .b32, .b32, .b32, false },
    .{ "ds_min_rtn_f32", .ds, 50, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_max_rtn_f32", .ds, 51, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_wrap_rtn_b32", .ds, 52, .ds_rtn2, .b32, .b32, .b32, .b32, false },
    .{ "ds_add_rtn_f32", .ds, 53, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_read_b32", .ds, 54, .ds_read, .b32, .b32, .none, .none, false },
    .{ "ds_read2_b32", .ds, 55, .ds_read2, .b64, .b32, .none, .none, false },
    .{ "ds_read2st64_b32", .ds, 56, .ds_read2, .b64, .b32, .none, .none, false },
    .{ "ds_read_i8", .ds, 57, .ds_read, .b32, .b32, .none, .none, false },
    .{ "ds_read_u8", .ds, 58, .ds_read, .b32, .b32, .none, .none, false },
    .{ "ds_read_i16", .ds, 59, .ds_read, .b32, .b32, .none, .none, false },
    .{ "ds_read_u16", .ds, 60, .ds_read, .b32, .b32, .none, .none, false },
    .{ "ds_swizzle_b32", .ds, 61, .ds_swizzle, .b32, .b32, .none, .none, false },
    .{ "ds_permute_b32", .ds, 62, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_bpermute_b32", .ds, 63, .ds_rtn, .b32, .b32, .b32, .none, false },
    .{ "ds_add_u64", .ds, 64, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_sub_u64", .ds, 65, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_rsub_u64", .ds, 66, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_inc_u64", .ds, 67, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_dec_u64", .ds, 68, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_min_i64", .ds, 69, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_max_i64", .ds, 70, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_min_u64", .ds, 71, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_max_u64", .ds, 72, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_and_b64", .ds, 73, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_or_b64", .ds, 74, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_xor_b64", .ds, 75, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_mskor_b64", .ds, 76, .ds_addr_data2, .none, .b32, .b64, .b64, false },
    .{ "ds_write_b64", .ds, 77, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_write2_b64", .ds, 78, .ds_write2, .none, .b32, .b64, .b64, false },
    .{ "ds_write2st64_b64", .ds, 79, .ds_write2, .none, .b32, .b64, .b64, false },
    .{ "ds_cmpst_b64", .ds, 80, .ds_addr_data2, .none, .b32, .b64, .b64, false },
    .{ "ds_cmpst_f64", .ds, 81, .ds_addr_data2, .none, .b32, .b64, .b64, false },
    .{ "ds_min_f64", .ds, 82, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_max_f64", .ds, 83, .ds_addr_data, .none, .b32, .b64, .none, false },
    .{ "ds_add_rtn_u64", .ds, 96, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_sub_rtn_u64", .ds, 97, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_rsub_rtn_u64", .ds, 98, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_inc_rtn_u64", .ds, 99, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_dec_rtn_u64", .ds, 100, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_min_rtn_i64", .ds, 101, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_max_rtn_i64", .ds, 102, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_min_rtn_u64", .ds, 103, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_max_rtn_u64", .ds, 104, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_and_rtn_b64", .ds, 105, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_or_rtn_b64", .ds, 106, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_xor_rtn_b64", .ds, 107, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_mskor_rtn_b64", .ds, 108, .ds_rtn2, .b64, .b32, .b64, .b64, false },
    .{ "ds_wrxchg_rtn_b64", .ds, 109, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_wrxchg2_rtn_b64", .ds, 110, .ds_rtn_write2, .b128, .b32, .b64, .b64, false },
    .{ "ds_wrxchg2st64_rtn_b64", .ds, 111, .ds_rtn_write2, .b128, .b32, .b64, .b64, false },
    .{ "ds_cmpst_rtn_b64", .ds, 112, .ds_rtn2, .b64, .b32, .b64, .b64, false },
    .{ "ds_cmpst_rtn_f64", .ds, 113, .ds_rtn2, .b64, .b32, .b64, .b64, false },
    .{ "ds_min_rtn_f64", .ds, 114, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_max_rtn_f64", .ds, 115, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_read_b64", .ds, 118, .ds_read, .b64, .b32, .none, .none, false },
    .{ "ds_read2_b64", .ds, 119, .ds_read2, .b128, .b32, .none, .none, false },
    .{ "ds_read2st64_b64", .ds, 120, .ds_read2, .b128, .b32, .none, .none, false },
    .{ "ds_condxchg32_rtn_b64", .ds, 126, .ds_rtn, .b64, .b32, .b64, .none, false },
    .{ "ds_consume", .ds, 189, .ds_vdst, .b32, .none, .none, .none, false },
    .{ "ds_append", .ds, 190, .ds_vdst, .b32, .none, .none, .none, false },
    .{ "ds_write_b96", .ds, 222, .ds_addr_data, .none, .b32, .b96, .none, false },
    .{ "ds_write_b128", .ds, 223, .ds_addr_data, .none, .b32, .b128, .none, false },
    .{ "ds_read_b96", .ds, 254, .ds_read, .b96, .b32, .none, .none, false },
    .{ "ds_read_b128", .ds, 255, .ds_read, .b128, .b32, .none, .none, false },
    // MUBUF
    .{ "buffer_load_format_x", .mubuf, 0, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_format_xy", .mubuf, 1, .buf_load, .b64, .none, .none, .none, false },
    .{ "buffer_load_format_xyz", .mubuf, 2, .buf_load, .b96, .none, .none, .none, false },
    .{ "buffer_load_format_xyzw", .mubuf, 3, .buf_load, .b128, .none, .none, .none, false },
    .{ "buffer_store_format_x", .mubuf, 4, .buf_store, .b32, .none, .none, .none, false },
    .{ "buffer_store_format_xy", .mubuf, 5, .buf_store, .b64, .none, .none, .none, false },
    .{ "buffer_store_format_xyz", .mubuf, 6, .buf_store, .b96, .none, .none, .none, false },
    .{ "buffer_store_format_xyzw", .mubuf, 7, .buf_store, .b128, .none, .none, .none, false },
    .{ "buffer_load_format_d16_x", .mubuf, 8, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_format_d16_xy", .mubuf, 9, .buf_load, .b64, .none, .none, .none, false },
    .{ "buffer_load_format_d16_xyz", .mubuf, 10, .buf_load, .b96, .none, .none, .none, false },
    .{ "buffer_load_format_d16_xyzw", .mubuf, 11, .buf_load, .b128, .none, .none, .none, false },
    .{ "buffer_store_format_d16_x", .mubuf, 12, .buf_store, .b32, .none, .none, .none, false },
    .{ "buffer_store_format_d16_xy", .mubuf, 13, .buf_store, .b64, .none, .none, .none, false },
    .{ "buffer_store_format_d16_xyz", .mubuf, 14, .buf_store, .b96, .none, .none, .none, false },
    .{ "buffer_store_format_d16_xyzw", .mubuf, 15, .buf_store, .b128, .none, .none, .none, false },
    .{ "buffer_load_ubyte", .mubuf, 16, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_sbyte", .mubuf, 17, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_ushort", .mubuf, 18, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_sshort", .mubuf, 19, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_dword", .mubuf, 20, .buf_load, .b32, .none, .none, .none, false },
    .{ "buffer_load_dwordx2", .mubuf, 21, .buf_load, .b64, .none, .none, .none, false },
    .{ "buffer_load_dwordx3", .mubuf, 22, .buf_load, .b96, .none, .none, .none, false },
    .{ "buffer_load_dwordx4", .mubuf, 23, .buf_load, .b128, .none, .none, .none, false },
    .{ "buffer_store_byte", .mubuf, 24, .buf_store, .b32, .none, .none, .none, false },
    .{ "buffer_store_short", .mubuf, 26, .buf_store, .b32, .none, .none, .none, false },
    .{ "buffer_store_dword", .mubuf, 28, .buf_store, .b32, .none, .none, .none, false },
    .{ "buffer_store_dwordx2", .mubuf, 29, .buf_store, .b64, .none, .none, .none, false },
    .{ "buffer_store_dwordx3", .mubuf, 30, .buf_store, .b96, .none, .none, .none, false },
    .{ "buffer_store_dwordx4", .mubuf, 31, .buf_store, .b128, .none, .none, .none, false },
    .{ "buffer_wbinvl1", .mubuf, 62, .buf_none, .none, .none, .none, .none, false },
    .{ "buffer_wbinvl1_vol", .mubuf, 63, .buf_none, .none, .none, .none, .none, false },
    .{ "buffer_atomic_swap", .mubuf, 64, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_cmpswap", .mubuf, 65, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_add", .mubuf, 66, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_sub", .mubuf, 67, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_smin", .mubuf, 68, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_umin", .mubuf, 69, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_smax", .mubuf, 70, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_umax", .mubuf, 71, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_and", .mubuf, 72, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_or", .mubuf, 73, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_xor", .mubuf, 74, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_inc", .mubuf, 75, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_dec", .mubuf, 76, .buf_atomic, .b32, .none, .none, .none, false },
    .{ "buffer_atomic_swap_x2", .mubuf, 96, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_cmpswap_x2", .mubuf, 97, .buf_atomic, .b128, .none, .none, .none, false },
    .{ "buffer_atomic_add_x2", .mubuf, 98, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_sub_x2", .mubuf, 99, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_smin_x2", .mubuf, 100, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_umin_x2", .mubuf, 101, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_smax_x2", .mubuf, 102, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_umax_x2", .mubuf, 103, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_and_x2", .mubuf, 104, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_or_x2", .mubuf, 105, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_xor_x2", .mubuf, 106, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_inc_x2", .mubuf, 107, .buf_atomic, .b64, .none, .none, .none, false },
    .{ "buffer_atomic_dec_x2", .mubuf, 108, .buf_atomic, .b64, .none, .none, .none, false },
    // MTBUF
    .{ "tbuffer_load_format_x", .mtbuf, 0, .buf_load, .b32, .none, .none, .none, false },
    .{ "tbuffer_load_format_xy", .mtbuf, 1, .buf_load, .b64, .none, .none, .none, false },
    .{ "tbuffer_load_format_xyz", .mtbuf, 2, .buf_load, .b96, .none, .none, .none, false },
    .{ "tbuffer_load_format_xyzw", .mtbuf, 3, .buf_load, .b128, .none, .none, .none, false },
    .{ "tbuffer_store_format_x", .mtbuf, 4, .buf_store, .b32, .none, .none, .none, false },
    .{ "tbuffer_store_format_xy", .mtbuf, 5, .buf_store, .b64, .none, .none, .none, false },
    .{ "tbuffer_store_format_xyz", .mtbuf, 6, .buf_store, .b96, .none, .none, .none, false },
    .{ "tbuffer_store_format_xyzw", .mtbuf, 7, .buf_store, .b128, .none, .none, .none, false },
    .{ "tbuffer_load_format_d16_x", .mtbuf, 8, .buf_load, .b32, .none, .none, .none, false },
    .{ "tbuffer_load_format_d16_xy", .mtbuf, 9, .buf_load, .b64, .none, .none, .none, false },
    .{ "tbuffer_load_format_d16_xyz", .mtbuf, 10, .buf_load, .b96, .none, .none, .none, false },
    .{ "tbuffer_load_format_d16_xyzw", .mtbuf, 11, .buf_load, .b128, .none, .none, .none, false },
    .{ "tbuffer_store_format_d16_x", .mtbuf, 12, .buf_store, .b32, .none, .none, .none, false },
    .{ "tbuffer_store_format_d16_xy", .mtbuf, 13, .buf_store, .b64, .none, .none, .none, false },
    .{ "tbuffer_store_format_d16_xyz", .mtbuf, 14, .buf_store, .b96, .none, .none, .none, false },
    .{ "tbuffer_store_format_d16_xyzw", .mtbuf, 15, .buf_store, .b128, .none, .none, .none, false },
    // FLAT
    .{ "flat_load_ubyte", .flat, 16, .flat_load, .b32, .b64, .none, .none, false },
    .{ "flat_load_sbyte", .flat, 17, .flat_load, .b32, .b64, .none, .none, false },
    .{ "flat_load_ushort", .flat, 18, .flat_load, .b32, .b64, .none, .none, false },
    .{ "flat_load_sshort", .flat, 19, .flat_load, .b32, .b64, .none, .none, false },
    .{ "flat_load_dword", .flat, 20, .flat_load, .b32, .b64, .none, .none, false },
    .{ "flat_load_dwordx2", .flat, 21, .flat_load, .b64, .b64, .none, .none, false },
    .{ "flat_load_dwordx3", .flat, 22, .flat_load, .b96, .b64, .none, .none, false },
    .{ "flat_load_dwordx4", .flat, 23, .flat_load, .b128, .b64, .none, .none, false },
    .{ "flat_store_byte", .flat, 24, .flat_store, .none, .b64, .b32, .none, false },
    .{ "flat_store_short", .flat, 26, .flat_store, .none, .b64, .b32, .none, false },
    .{ "flat_store_dword", .flat, 28, .flat_store, .none, .b64, .b32, .none, false },
    .{ "flat_store_dwordx2", .flat, 29, .flat_store, .none, .b64, .b64, .none, false },
    .{ "flat_store_dwordx3", .flat, 30, .flat_store, .none, .b64, .b96, .none, false },
    .{ "flat_store_dwordx4", .flat, 31, .flat_store, .none, .b64, .b128, .none, false },
    .{ "flat_atomic_swap", .flat, 64, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_cmpswap", .flat, 65, .flat_atomic, .b32, .b64, .b64, .none, false },
    .{ "flat_atomic_add", .flat, 66, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_sub", .flat, 67, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_smin", .flat, 68, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_umin", .flat, 69, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_smax", .flat, 70, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_umax", .flat, 71, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_and", .flat, 72, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_or", .flat, 73, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_xor", .flat, 74, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_inc", .flat, 75, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_dec", .flat, 76, .flat_atomic, .b32, .b64, .b32, .none, false },
    .{ "flat_atomic_swap_x2", .flat, 96, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_cmpswap_x2", .flat, 97, .flat_atomic, .b64, .b64, .b128, .none, false },
    .{ "flat_atomic_add_x2", .flat, 98, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_sub_x2", .flat, 99, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_smin_x2", .flat, 100, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_umin_x2", .flat, 101, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_smax_x2", .flat, 102, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_umax_x2", .flat, 103, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_and_x2", .flat, 104, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_or_x2", .flat, 105, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_xor_x2", .flat, 106, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_inc_x2", .flat, 107, .flat_atomic, .b64, .b64, .b64, .none, false },
    .{ "flat_atomic_dec_x2", .flat, 108, .flat_atomic, .b64, .b64, .b64, .none, false },
};

fn familySize(name: []const u8) usize {
    if (std.mem.indexOf(u8, name, "{f}") != null) return fconds.len;
    if (std.mem.indexOf(u8, name, "{i}") != null) return iconds.len;
    return 1;
}

const n_defs = blk: {
    @setEvalBranchQuota(1_000_000);
    var n: usize = 0;
    for (rows) |r| n += familySize(r[0]);
    break :blk n;
};

/// Every instruction, families expanded. An Op is an index into it.
pub const defs: [n_defs]Def = blk: {
    @setEvalBranchQuota(1_000_000);
    var list: [n_defs]Def = undefined;
    var n: usize = 0;
    for (rows) |r| {
        const k = familySize(r[0]);
        var i: usize = 0;
        while (i < k) : (i += 1) {
            var name: []const u8 = r[0];
            if (k > 1) {
                const at = std.mem.indexOf(u8, name, "{").?;
                const cond = if (k == fconds.len) fconds[i] else iconds[i];
                name = name[0..at] ++ cond ++ name[at + 3 ..];
            }
            list[n] = .{ .name = name, .enc = r[1], .code = r[2] + @as(u16, @intCast(i)), .shape = r[3], .d = r[4], .s = .{ r[5], r[6], r[7] }, .e64 = r[8] };
            n += 1;
        }
    }
    break :blk list;
};

pub const Op = u16;
const NONE: u16 = 0xffff;

/// The op named `name`, at compile time (for switches over ops).
pub fn op(comptime name: []const u8) Op {
    return comptime opIndex(name);
}

fn opIndex(comptime name: []const u8) Op {
    @setEvalBranchQuota(10_000_000);
    for (defs, 0..) |df, i| {
        if (std.mem.eql(u8, df.name, name)) return @intCast(i);
    }
    @compileError("gcn3: no instruction " ++ name);
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

fn encSize(e: Enc) usize {
    return switch (e) {
        .sop2, .sopc => 128,
        .vopc => 256,
        .sopk, .mtbuf => 32,
        .sop1, .vop1, .smem, .ds => 256,
        .sopp, .mubuf, .flat => 128,
        .vop2 => 64,
        .vop3 => 1024,
    };
}

/// (encoding, opcode) to op; the VOP3 table also holds the VOP1, VOP2 and
/// VOPC ops' VOP3 opcodes (VOPC + 0, VOP2 + 0x100, VOP1 + 0x140).
const by_code: [14][1024]u16 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [14][1024]u16 = undefined;
    for (&t) |*row| @memset(row, NONE);
    for (defs, 0..) |df, i| {
        t[@intFromEnum(df.enc)][df.code] = @intCast(i);
        if (df.e64) t[@intFromEnum(Enc.vop3)][vop3Code(&df)] = @intCast(i);
    }
    break :blk t;
};

fn vop3Code(d: *const Def) u16 {
    return switch (d.enc) {
        .vopc => d.code,
        .vop2 => 0x100 + d.code,
        .vop1 => 0x140 + d.code,
        else => d.code,
    };
}

// ── Instructions ────────────────────────────────────────────────────────────

/// One instruction. The fields mean, by encoding:
///   SALU:  dst = sdst, src[0..1] = ssrc0/1, lit = the literal, imm = simm16.
///   VALU:  dst = vdst (v(n), or a scalar code for an SGPR destination),
///          sdst = VOP3b's carry-out / VOPC's mask (vcc in _e32), src[0..2],
///          lit = the literal or v_madmk/v_madak's K; neg/abs/clamp/omod.
///   SMEM:  dst = sdata, src[0] = sbase, imm = offset (soff_imm) or
///          src[1] = soffset.
///   DS:    dst = vdst, src[0] = addr, src[1..2] = data0/1, imm = offset
///          (offset0 | offset1 << 8 for the two-address forms).
///   MUBUF, MTBUF: dst = vdata, src[0] = vaddr, src[1] = srsrc,
///          src[2] = soffset, imm = offset, fmt = dfmt | nfmt << 4.
///   FLAT:  dst = vdst, src[0] = vaddr, src[1] = vdata.
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
    imm: u32 = 0,
    glc: bool = false,
    slc: bool = false,
    tfe: bool = false,
    gds: bool = false,
    offen: bool = false,
    idxen: bool = false,
    soff_imm: bool = true,
    fmt: u8 = 1,
    /// SDWA (a VOP1, VOP2 or VOPC instruction with a second dword): the
    /// byte or word each source is (sel: 0-3 BYTE_n, 4-5 WORD_n, 6 DWORD),
    /// sign-extended (sext, a bit per source), and where the result goes
    /// (dst_sel; dst_unused: 0 zeros, 1 sign-extended, 2 the register's
    /// own bits).
    sdwa: bool = false,
    sel: [2]u3 = .{ 6, 6 },
    sext: u2 = 0,
    dst_sel: u3 = 6,
    dst_unused: u2 = 0,

    pub fn d(in: *const Instr) *const Def {
        return &defs[in.op];
    }
    /// The encoding this instruction is in (VOP3 for _e64).
    pub fn enc(in: *const Instr) Enc {
        const df = in.d();
        return if (in.e64) .vop3 else df.enc;
    }
    pub fn hasLiteral(in: *const Instr) bool {
        const df = in.d();
        if (in.sdwa) return false;
        if (df.shape == .vop_madmk or df.shape == .vop_madak or df.shape == .sopk_setreg_imm) return true;
        switch (df.enc) {
            .sop2, .sop1, .sopc, .vop1, .vop2, .vopc => {
                if (in.e64) return false;
                const n: usize = if (df.enc == .sop2 or df.enc == .sopc) 2 else 1;
                for (in.src[0..n]) |c| {
                    if (c == LITERAL) return true;
                }
                return false;
            },
            else => return false,
        }
    }
    /// Dwords the instruction takes (1 or 2; 3 is never needed on gfx8).
    pub fn dwords(in: *const Instr) u8 {
        if (in.sdwa) return 2;
        const base: u8 = switch (in.enc()) {
            .smem, .vop3, .ds, .mubuf, .mtbuf, .flat => 2,
            else => 1,
        };
        return base + @intFromBool(in.hasLiteral());
    }
};

// ── Encoding ────────────────────────────────────────────────────────────────

fn isV(code: u16) bool {
    return code >= VGPR0 and code < VGPR0 + 256;
}
fn isS(code: u16) bool {
    return code < 256;
}
/// A scalar register (not a constant).
fn isSReg(code: u16) bool {
    return code < 128;
}
fn vIdx(code: u16) Error!u32 {
    if (!isV(code)) return error.NoForm;
    return code - VGPR0;
}
fn sReg(code: u16) Error!u32 {
    if (!isSReg(code)) return error.NoForm;
    return code;
}
fn ssrc(code: u16) Error!u32 {
    if (!isS(code)) return error.NoForm;
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

/// Encode into `out` (at least 2 dwords for 64-bit forms, 3 never needed);
/// returns the number of dwords.
/// Whether the instruction has an SDWA form: a VOP1, VOP2 or VOPC one whose
/// operands are 32 bits or less (not v_movrel*, v_mac_f16, v_readfirstlane,
/// v_nop, the madmk/madak forms), as LLVM's gfx803 assembler has them.
pub fn sdwaOk(df: *const Def) bool {
    switch (df.enc) {
        .vop1, .vop2, .vopc => {},
        else => return false,
    }
    switch (df.shape) {
        .vop, .vop_carry, .vop_carry_in, .vop_cndmask, .vopc => {},
        else => return false,
    }
    if (df.shape != .vopc and df.d.dwords() > 1) return false;
    for (df.s) |t| {
        if (t.dwords() > 1) return false;
    }
    if (std.mem.startsWith(u8, df.name, "v_movrel") or std.mem.eql(u8, df.name, "v_mac_f16")) return false;
    return true;
}

fn sdwaSrcs(df: *const Def) usize {
    return if (df.enc == .vop1) 1 else 2;
}

/// The SDWA dword (and the checks LLVM makes: VGPR sources; neg and abs on
/// float sources, sext on integer ones; v_mac_f32 writes the whole dword).
fn sdwaWord(in: *const Instr) Error!u32 {
    const df = in.d();
    if (!sdwaOk(df) or in.e64 or in.omod != 0) return error.NoForm;
    if (in.sel[0] > 6 or in.sel[1] > 6 or in.dst_sel > 6 or in.dst_unused > 2) return error.OutOfRange;
    const ns = sdwaSrcs(df);
    if (in.neg >> 2 != 0 or in.abs >> 2 != 0) return error.NoForm;
    for (0..2) |i| {
        const neg = in.neg >> @intCast(i) & 1 != 0;
        const abs = in.abs >> @intCast(i) & 1 != 0;
        const sx = in.sext >> @intCast(i) & 1 != 0;
        if (i >= ns) {
            if (neg or abs or sx or in.sel[i] != 6) return error.NoForm;
            continue;
        }
        const fl = df.s[i].isFloat();
        if ((neg or abs) and !fl) return error.NoForm;
        if (sx and fl) return error.NoForm;
    }
    if (df.shape == .vopc and (in.dst_sel != 6 or in.dst_unused != 0)) return error.NoForm;
    if (std.mem.eql(u8, df.name, "v_mac_f32") and (in.dst_sel != 6 or in.dst_unused != 0)) return error.NoForm;
    var w = try vIdx(in.src[0]) | @as(u32, @intFromBool(in.clamp)) << 13 | @as(u32, in.sel[0]) << 16 | @as(u32, in.sext & 1) << 19 | @as(u32, in.neg & 1) << 20 | @as(u32, in.abs & 1) << 21;
    if (df.shape != .vopc) w |= @as(u32, in.dst_sel) << 8 | @as(u32, in.dst_unused) << 11;
    if (ns == 2) w |= @as(u32, in.sel[1]) << 24 | @as(u32, in.sext >> 1) << 27 | @as(u32, in.neg >> 1 & 1) << 28 | @as(u32, in.abs >> 1 & 1) << 29;
    return w;
}

fn vop1Word(in: *const Instr, df: *const Def) Error!u32 {
    if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0) return error.NoForm;
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
    return 0b0111111 << 25 | dst << 17 | @as(u32, df.code) << 9 | s0;
}

pub fn encode(in: *const Instr, out: []u32) Error!usize {
    const df = in.d();
    if (in.sdwa and (in.e64 or !sdwaOk(df))) return error.NoForm;
    const n = in.dwords();
    if (out.len < n) return error.BufferTooSmall;
    var w0: u32 = 0;
    var w1: u32 = 0;
    switch (in.enc()) {
        .sop2 => w0 = 0b10 << 30 | @as(u32, df.code) << 23 | try sReg(in.dst) << 16 | try ssrc(in.src[1]) << 8 | try ssrc(in.src[0]),
        .sop1 => {
            const dst = if (df.shape == .sop1_src) 0 else try sReg(in.dst);
            const s0 = if (df.shape == .sop1_dst) 0 else try ssrc(in.src[0]);
            w0 = 0b101111101 << 23 | dst << 16 | @as(u32, df.code) << 8 | s0;
        },
        .sopc => w0 = 0b101111110 << 23 | @as(u32, df.code) << 16 | try ssrc(in.src[1]) << 8 | try ssrc(in.src[0]),
        .sopk => {
            const dst = if (df.shape == .sopk_setreg_imm) 0 else try sReg(in.dst);
            w0 = 0b1011 << 28 | @as(u32, df.code) << 23 | dst << 16 | try fits(in.imm, 16);
        },
        .sopp => {
            const imm: u32 = if (df.shape == .sopp) 0 else try fits(in.imm, 16);
            w0 = 0b101111111 << 23 | @as(u32, df.code) << 16 | imm;
        },
        .smem => {
            var sdata: u32 = 0;
            var sbase: u32 = 0;
            var imm = false;
            switch (df.shape) {
                .smem_load, .smem_store => {
                    sdata = try sReg(in.dst);
                    sbase = try sReg(in.src[0]);
                    if (sbase & 1 != 0) return error.NoForm;
                    imm = in.soff_imm;
                    w1 = if (imm) try fits(in.imm, 20) else try sReg(in.src[1]);
                },
                .smem_time => sdata = try sReg(in.dst),
                else => {},
            }
            w0 = 0b110000 << 26 | @as(u32, df.code) << 18 | @as(u32, @intFromBool(imm)) << 17 | @as(u32, @intFromBool(in.glc)) << 16 | try fits(sdata, 7) << 6 | sbase >> 1;
        },
        .vop2 => {
            switch (df.shape) {
                .vop_carry => if (in.sdst != VCC_LO) return error.NoForm,
                .vop_carry_in => if (in.sdst != VCC_LO or in.src[2] != VCC_LO) return error.NoForm,
                .vop_cndmask => if (in.src[2] != VCC_LO) return error.NoForm,
                .vop_madmk, .vop_madak => if (in.src[0] == LITERAL) return error.NoForm,
                else => {},
            }
            if (in.sdwa) {
                w0 = @as(u32, df.code) << 25 | try vIdx(in.dst) << 17 | try vIdx(in.src[1]) << 9 | SDWA;
                w1 = try sdwaWord(in);
            } else {
                if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0) return error.NoForm;
                w0 = @as(u32, df.code) << 25 | try vIdx(in.dst) << 17 | try vIdx(in.src[1]) << 9 | try src9(in.src[0]);
            }
        },
        .vop1 => {
            if (in.sdwa) {
                w0 = 0b0111111 << 25 | try vIdx(in.dst) << 17 | @as(u32, df.code) << 9 | SDWA;
                w1 = try sdwaWord(in);
            } else w0 = try vop1Word(in, df);
        },
        .vopc => {
            if (in.sdst != VCC_LO) return error.NoForm;
            if (in.sdwa) {
                w0 = 0b0111110 << 25 | @as(u32, df.code) << 17 | try vIdx(in.src[1]) << 9 | SDWA;
                w1 = try sdwaWord(in);
            } else {
                if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0) return error.NoForm;
                w0 = 0b0111110 << 25 | @as(u32, df.code) << 17 | try vIdx(in.src[1]) << 9 | try src9(in.src[0]);
            }
        },
        .vop3 => {
            const code = vop3Code(df);
            var dst: u32 = 0;
            var mid: u32 = 0; // bits 14:8: abs (VOP3a) or sdst (VOP3b)
            const ns = df.nsrc();
            var srcs: [3]u32 = .{ 0, 0, 0 };
            var nsrc: usize = ns;
            switch (df.shape) {
                .vop_none => nsrc = 0,
                .vopc => dst = try sReg(in.sdst),
                .vop_sdst => dst = try sReg(in.dst),
                .vop_carry, .vop3b => {
                    dst = try vIdx(in.dst);
                    mid = try sReg(in.sdst);
                },
                .vop_carry_in => {
                    dst = try vIdx(in.dst);
                    mid = try sReg(in.sdst);
                    nsrc = 3;
                },
                .vop_cndmask => {
                    dst = try vIdx(in.dst);
                    nsrc = 3;
                },
                .vop, .vop_madmk, .vop_madak => dst = try vIdx(in.dst),
                else => return error.NoForm,
            }
            const vop3b = df.shape == .vop_carry or df.shape == .vop_carry_in or df.shape == .vop3b;
            if (vop3b) {
                if (in.abs != 0) return error.NoForm;
            } else mid = in.abs;
            for (0..nsrc) |i| {
                if (in.src[i] == LITERAL) return error.NoForm;
                srcs[i] = try src9(in.src[i]);
            }
            const used: u3 = @intCast((@as(u4, 1) << @intCast(nsrc)) - 1);
            if (in.neg & ~used != 0 or in.abs & ~used != 0) return error.NoForm;
            w0 = 0b110100 << 26 | @as(u32, code) << 16 | @as(u32, @intFromBool(in.clamp)) << 15 | mid << 8 | dst;
            w1 = @as(u32, in.neg) << 29 | @as(u32, in.omod) << 27 | srcs[2] << 18 | srcs[1] << 9 | srcs[0];
        },
        .ds => {
            var addr: u32 = 0;
            var d0: u32 = 0;
            var d1: u32 = 0;
            var vdst: u32 = 0;
            const sh = df.shape;
            if (sh != .ds_vdst and sh != .ds_none) addr = try vIdx(in.src[0]);
            switch (sh) {
                .ds_addr_data, .ds_rtn => d0 = try vIdx(in.src[1]),
                .ds_addr_data2, .ds_write2, .ds_rtn2, .ds_rtn_write2 => {
                    d0 = try vIdx(in.src[1]);
                    d1 = try vIdx(in.src[2]);
                },
                else => {},
            }
            switch (sh) {
                .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst => vdst = try vIdx(in.dst),
                else => {},
            }
            w0 = 0b110110 << 26 | @as(u32, df.code) << 17 | @as(u32, @intFromBool(in.gds)) << 16 | try fits(in.imm, 16);
            w1 = vdst << 24 | d1 << 16 | d0 << 8 | addr;
        },
        .mubuf, .mtbuf => {
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
            const flags = @as(u32, @intFromBool(in.glc)) << 14 | @as(u32, @intFromBool(in.idxen)) << 13 | @as(u32, @intFromBool(in.offen)) << 12 | try fits(in.imm, 12);
            if (df.enc == .mubuf) {
                w0 = 0b111000 << 26 | @as(u32, df.code) << 18 | @as(u32, @intFromBool(in.slc)) << 17 | flags;
                w1 = soff << 24 | @as(u32, @intFromBool(in.tfe)) << 23 | srsrc >> 2 << 16 | vdata << 8 | vaddr;
            } else {
                w0 = 0b111010 << 26 | @as(u32, in.fmt >> 4 & 7) << 23 | @as(u32, in.fmt & 15) << 19 | @as(u32, df.code) << 15 | flags;
                if (in.fmt >> 7 != 0) return error.OutOfRange;
                w1 = soff << 24 | @as(u32, @intFromBool(in.tfe)) << 23 | @as(u32, @intFromBool(in.slc)) << 22 | srsrc >> 2 << 16 | vdata << 8 | vaddr;
            }
        },
        .flat => {
            var vdst: u32 = 0;
            var data: u32 = 0;
            const addr = try vIdx(in.src[0]);
            switch (df.shape) {
                .flat_load => vdst = try vIdx(in.dst),
                .flat_store => data = try vIdx(in.src[1]),
                else => {
                    data = try vIdx(in.src[1]);
                    if (in.glc) vdst = try vIdx(in.dst);
                },
            }
            w0 = 0b110111 << 26 | @as(u32, df.code) << 18 | @as(u32, @intFromBool(in.slc)) << 17 | @as(u32, @intFromBool(in.glc)) << 16;
            w1 = vdst << 24 | data << 8 | addr;
        },
    }
    out[0] = w0;
    const base: usize = if (n == 1 or (n == 2 and in.hasLiteral())) 1 else 2;
    if (base == 2) out[1] = w1;
    if (in.hasLiteral()) out[base] = in.lit;
    return n;
}

// ── Decoding ────────────────────────────────────────────────────────────────

fn bits(w: u32, lo: u5, n: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << n) - 1);
}

fn lookupCode(e: Enc, code: u32) Error!Op {
    if (code >= encSize(e)) return error.NoMatch;
    const o = by_code[@intFromEnum(e)][code];
    if (o == NONE) return error.NoMatch;
    return o;
}

/// A source operand code valid in a 9-bit / 8-bit source field on gfx803.
fn validSrc(code: u32) bool {
    if (code < SGPRS) return true;
    return switch (code) {
        102, 103, 106...124, 126...208, 240...248, 251...255 => true,
        else => code >= VGPR0 and code < 512,
    };
}
fn validSReg(code: u32) bool {
    return code < SGPRS or code == 102 or code == 103 or (code >= 106 and code <= 124) or code == 126 or code == 127;
}

/// Decode the instruction at the start of `words`. Returns the number of
/// dwords it takes.
pub fn decode(words: []const u32, in: *Instr) Error!usize {
    const n = try decodeFields(words, in);
    try checkRanges(in);
    try checkLiteral(in);
    return n;
}

fn rangeOk(code: u16, n_in: u8) bool {
    const n = @max(n_in, 1);
    if (code >= VGPR0) return code - VGPR0 + n <= 256;
    if (code < SGPRS) return code + n <= SGPRS;
    if (code >= TTMP0 and code < TTMP0 + 12) return code - TTMP0 + n <= 12;
    return true;
}

/// Register ranges that run off the end of their file do not print.
fn checkRanges(in: *const Instr) Error!void {
    const df = in.d();
    const buf = df.enc == .mubuf or df.enc == .mtbuf;
    const dn = df.d.dwords() + @intFromBool(buf and in.tfe);
    if (!rangeOk(in.dst, dn) or !rangeOk(in.sdst, 2)) return error.NoMatch;
    if (buf) {
        const an: u8 = if (in.offen and in.idxen) 2 else 1;
        if (!rangeOk(in.src[0], an) or !rangeOk(in.src[1], 4)) return error.NoMatch;
        return;
    }
    for (0..3) |i| {
        if (!rangeOk(in.src[i], df.s[i].dwords())) return error.NoMatch;
    }
}

/// A literal LLVM would write as an inline constant is not canonical.
fn checkLiteral(in: *const Instr) Error!void {
    const df = in.d();
    switch (df.shape) {
        .vop_madmk, .vop_madak, .sopk_setreg_imm => return,
        else => {},
    }
    if (!in.hasLiteral()) return;
    for (0..3) |i| {
        if (in.src[i] != LITERAL) continue;
        var lit: u32 = 0;
        var has = false;
        const o = Opnd{ .kind = .int, .int = in.lit, .hex = true };
        const code = constCode(o, df.s[i], &lit, &has) catch return error.NoMatch;
        if (code != LITERAL or lit != in.lit) return error.NoMatch;
    }
}

fn decodeFields(words: []const u32, in: *Instr) Error!usize {
    if (words.len == 0) return error.NoMatch;
    const w0 = words[0];
    in.* = .{};
    var n: usize = 1;
    if (w0 >> 31 == 0) {
        // VOP2, VOP1, VOPC
        const hi7 = w0 >> 25;
        if (hi7 == 0x3f) {
            in.op = try lookupCode(.vop1, bits(w0, 9, 8));
            const df = in.d();
            const dst = bits(w0, 17, 8);
            const s0 = bits(w0, 0, 9);
            switch (df.shape) {
                .vop_none => if (dst != 0 or s0 != 0) return error.NoMatch,
                .vop_sdst => {
                    if (!validSReg(dst)) return error.NoMatch;
                    in.dst = @intCast(dst);
                    in.src[0] = @intCast(s0);
                },
                else => {
                    in.dst = @intCast(VGPR0 + dst);
                    in.src[0] = @intCast(s0);
                },
            }
            if (df.shape != .vop_none and !validSrc(s0) and s0 != SDWA) return error.NoMatch;
        } else if (hi7 == 0x3e) {
            in.op = try lookupCode(.vopc, bits(w0, 17, 8));
            in.sdst = VCC_LO;
            in.src[0] = @intCast(bits(w0, 0, 9));
            in.src[1] = @intCast(VGPR0 + bits(w0, 9, 8));
            if (!validSrc(in.src[0]) and in.src[0] != SDWA) return error.NoMatch;
        } else {
            in.op = try lookupCode(.vop2, hi7);
            const df = in.d();
            in.dst = @intCast(VGPR0 + bits(w0, 17, 8));
            in.src[0] = @intCast(bits(w0, 0, 9));
            in.src[1] = @intCast(VGPR0 + bits(w0, 9, 8));
            if (!validSrc(in.src[0]) and in.src[0] != SDWA) return error.NoMatch;
            if ((df.shape == .vop_madmk or df.shape == .vop_madak) and in.src[0] == LITERAL) return error.NoMatch;
            switch (df.shape) {
                .vop_carry => in.sdst = VCC_LO,
                .vop_carry_in => {
                    in.sdst = VCC_LO;
                    in.src[2] = VCC_LO;
                },
                .vop_cndmask => in.src[2] = VCC_LO,
                else => {},
            }
        }
        if (in.src[0] == SDWA and in.d().shape != .vop_none) {
            if (words.len < 2) return error.NoMatch;
            try decodeSdwa(words[1], in);
            return 2;
        }
        if (in.hasLiteral()) {
            if (words.len < 2) return error.NoMatch;
            in.lit = words[1];
            n = 2;
        }
        return n;
    }
    const top9 = w0 >> 23;
    if (top9 == 0x17d) {
        in.op = try lookupCode(.sop1, bits(w0, 8, 8));
        const df = in.d();
        const dst = bits(w0, 16, 7);
        const s0 = bits(w0, 0, 8);
        if (df.shape == .sop1_src) {
            if (dst != 0) return error.NoMatch;
        } else {
            if (!validSReg(dst)) return error.NoMatch;
            in.dst = @intCast(dst);
        }
        if (df.shape == .sop1_dst) {
            if (s0 != 0) return error.NoMatch;
        } else {
            if (!validSrc(s0)) return error.NoMatch;
            in.src[0] = @intCast(s0);
        }
    } else if (top9 == 0x17e) {
        in.op = try lookupCode(.sopc, bits(w0, 16, 7));
        in.src[0] = @intCast(bits(w0, 0, 8));
        in.src[1] = @intCast(bits(w0, 8, 8));
        if (!validSrc(in.src[0]) or !validSrc(in.src[1])) return error.NoMatch;
    } else if (top9 == 0x17f) {
        in.op = try lookupCode(.sopp, bits(w0, 16, 7));
        const df = in.d();
        in.imm = bits(w0, 0, 16);
        if (df.shape == .sopp and in.imm != 0) return error.NoMatch;
        if (df.shape == .sopp_waitcnt and in.imm & ~@as(u32, 0x0f7f) != 0) return error.NoMatch;
    } else if (w0 >> 28 == 0xb) {
        in.op = try lookupCode(.sopk, bits(w0, 23, 5));
        const df = in.d();
        const dst = bits(w0, 16, 7);
        in.imm = bits(w0, 0, 16);
        if (df.shape == .sopk_setreg_imm) {
            if (dst != 0) return error.NoMatch;
        } else {
            if (!validSReg(dst)) return error.NoMatch;
            in.dst = @intCast(dst);
        }
    } else if (w0 >> 30 == 0b10) {
        in.op = try lookupCode(.sop2, bits(w0, 23, 7));
        const dst = bits(w0, 16, 7);
        if (!validSReg(dst)) return error.NoMatch;
        in.dst = @intCast(dst);
        in.src[0] = @intCast(bits(w0, 0, 8));
        in.src[1] = @intCast(bits(w0, 8, 8));
        if (!validSrc(in.src[0]) or !validSrc(in.src[1])) return error.NoMatch;
    } else {
        // 64-bit encodings
        if (words.len < 2) return error.NoMatch;
        const w1 = words[1];
        n = 2;
        switch (w0 >> 26) {
            0b110000 => try decodeSmem(w0, w1, in),
            0b110100 => try decodeVop3(w0, w1, in),
            0b110110 => try decodeDs(w0, w1, in),
            0b110111 => try decodeFlat(w0, w1, in),
            0b111000, 0b111010 => try decodeBuf(w0, w1, in),
            else => return error.NoMatch,
        }
        return n;
    }
    if (in.hasLiteral()) {
        if (words.len < 2) return error.NoMatch;
        in.lit = words[1];
        n = 2;
    }
    return n;
}

/// The SDWA dword after a VOP1, VOP2 or VOPC word (strict: only what
/// encodes back to the same dword).
fn decodeSdwa(w: u32, in: *Instr) Error!void {
    const df = in.d();
    if (!sdwaOk(df)) return error.NoMatch;
    if (w & 0xc0c0_c000 != 0) return error.NoMatch;
    in.sdwa = true;
    in.src[0] = @intCast(VGPR0 + bits(w, 0, 8));
    in.clamp = bits(w, 13, 1) != 0;
    in.sel[0] = @intCast(bits(w, 16, 3));
    in.sext = @intCast(bits(w, 19, 1));
    in.neg = @intCast(bits(w, 20, 1));
    in.abs = @intCast(bits(w, 21, 1));
    if (df.shape == .vopc) {
        in.dst_sel = 6;
        in.dst_unused = 0;
    } else {
        in.dst_sel = @intCast(bits(w, 8, 3));
        in.dst_unused = @intCast(bits(w, 11, 2));
    }
    if (sdwaSrcs(df) == 2) {
        in.sel[1] = @intCast(bits(w, 24, 3));
        in.sext |= @intCast(bits(w, 27, 1) << 1);
        in.neg |= @intCast(bits(w, 28, 1) << 1);
        in.abs |= @intCast(bits(w, 29, 1) << 1);
    } else in.sel[1] = 6;
    if (in.dst_unused > 2) return error.NoMatch;
    const back = sdwaWord(in) catch return error.NoMatch;
    if (back != w) return error.NoMatch;
}

fn decodeSmem(w0: u32, w1: u32, in: *Instr) Error!void {
    in.op = try lookupCode(.smem, bits(w0, 18, 8));
    const df = in.d();
    if (bits(w0, 13, 3) != 0) return error.NoMatch;
    const sbase = bits(w0, 0, 6) << 1;
    const sdata = bits(w0, 6, 7);
    const imm = bits(w0, 17, 1) != 0;
    in.glc = bits(w0, 16, 1) != 0;
    switch (df.shape) {
        .smem_load, .smem_store => {
            if (!validSReg(sdata) or !validSReg(sbase)) return error.NoMatch;
            in.dst = @intCast(sdata);
            in.src[0] = @intCast(sbase);
            in.soff_imm = imm;
            if (imm) {
                if (w1 >> 20 != 0) return error.NoMatch;
                in.imm = w1;
            } else {
                if (w1 >> 8 != 0 or !validSReg(w1)) return error.NoMatch;
                in.src[1] = @intCast(w1);
            }
        },
        .smem_time => {
            if (imm or in.glc or sbase != 0 or w1 != 0 or !validSReg(sdata)) return error.NoMatch;
            in.dst = @intCast(sdata);
        },
        else => if (imm or in.glc or sbase != 0 or sdata != 0 or w1 != 0) return error.NoMatch,
    }
    if (df.shape == .smem_time or df.shape == .smem_none) in.soff_imm = false;
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
    const raw = [3]u32{ bits(w1, 0, 9), bits(w1, 9, 9), bits(w1, 18, 9) };
    var nsrc: usize = df.nsrc();
    const vop3b = df.shape == .vop_carry or df.shape == .vop_carry_in or df.shape == .vop3b;
    if (vop3b) {
        if (!validSReg(mid)) return error.NoMatch;
        in.sdst = @intCast(mid);
    } else {
        if (mid >> 3 != 0) return error.NoMatch;
        in.abs = @intCast(mid);
    }
    switch (df.shape) {
        .vop_none => nsrc = 0,
        .vopc => {
            if (!validSReg(dst)) return error.NoMatch;
            in.sdst = @intCast(dst);
        },
        .vop_sdst => {
            if (!validSReg(dst)) return error.NoMatch;
            in.dst = @intCast(dst);
        },
        .vop_carry_in, .vop_cndmask => {
            in.dst = @intCast(VGPR0 + dst);
            nsrc = 3;
        },
        else => in.dst = @intCast(VGPR0 + dst),
    }
    if (df.shape == .vop_none and dst != 0) return error.NoMatch;
    for (0..3) |i| {
        if (i < nsrc) {
            if (!validSrc(raw[i]) or raw[i] == LITERAL or raw[i] == LDS_DIRECT) return error.NoMatch;
            in.src[i] = @intCast(raw[i]);
        } else if (raw[i] != 0) return error.NoMatch;
    }
    const used: u3 = @intCast((@as(u4, 1) << @intCast(nsrc)) - 1);
    if (in.neg & ~used != 0 or in.abs & ~used != 0) return error.NoMatch;
}

fn decodeDs(w0: u32, w1: u32, in: *Instr) Error!void {
    if (bits(w0, 25, 1) != 0) return error.NoMatch;
    in.op = try lookupCode(.ds, bits(w0, 17, 8));
    const df = in.d();
    in.gds = bits(w0, 16, 1) != 0;
    in.imm = bits(w0, 0, 16);
    const addr = bits(w1, 0, 8);
    const d0 = bits(w1, 8, 8);
    const d1 = bits(w1, 16, 8);
    const vdst = bits(w1, 24, 8);
    var has_addr = true;
    var nd: u8 = 0;
    var has_vdst = false;
    switch (df.shape) {
        .ds_addr_data => nd = 1,
        .ds_addr_data2, .ds_write2 => nd = 2,
        .ds_read, .ds_read2, .ds_swizzle => has_vdst = true,
        .ds_rtn => {
            nd = 1;
            has_vdst = true;
        },
        .ds_rtn2, .ds_rtn_write2 => {
            nd = 2;
            has_vdst = true;
        },
        .ds_vdst => {
            has_addr = false;
            has_vdst = true;
        },
        else => has_addr = false,
    }
    if (!has_addr and addr != 0) return error.NoMatch;
    if (nd < 1 and d0 != 0) return error.NoMatch;
    if (nd < 2 and d1 != 0) return error.NoMatch;
    if (!has_vdst and vdst != 0) return error.NoMatch;
    if (df.shape == .ds_none and (in.imm != 0 or in.gds)) return error.NoMatch;
    if (has_addr) in.src[0] = @intCast(VGPR0 + addr);
    if (nd >= 1) in.src[1] = @intCast(VGPR0 + d0);
    if (nd >= 2) in.src[2] = @intCast(VGPR0 + d1);
    if (has_vdst) in.dst = @intCast(VGPR0 + vdst);
}

fn decodeBuf(w0: u32, w1: u32, in: *Instr) Error!void {
    const mt = w0 >> 26 == 0b111010;
    if (mt) {
        in.op = try lookupCode(.mtbuf, bits(w0, 15, 4));
        in.fmt = @intCast(bits(w0, 19, 4) | bits(w0, 23, 3) << 4);
        in.slc = bits(w1, 22, 1) != 0;
        if (bits(w1, 21, 1) != 0) return error.NoMatch;
    } else {
        // bit 15 reserved, bit 16 (lds) is not modelled, bit 25 reserved
        if (bits(w0, 15, 2) != 0 or bits(w0, 25, 1) != 0) return error.NoMatch;
        in.op = try lookupCode(.mubuf, bits(w0, 18, 7));
        in.slc = bits(w0, 17, 1) != 0;
        if (bits(w1, 21, 2) != 0) return error.NoMatch;
    }
    const df = in.d();
    in.imm = bits(w0, 0, 12);
    in.offen = bits(w0, 12, 1) != 0;
    in.idxen = bits(w0, 13, 1) != 0;
    in.glc = bits(w0, 14, 1) != 0;
    in.tfe = bits(w1, 23, 1) != 0;
    const vaddr = bits(w1, 0, 8);
    const vdata = bits(w1, 8, 8);
    const srsrc = bits(w1, 16, 5) << 2;
    const soff = bits(w1, 24, 8);
    if (df.shape == .buf_none) {
        if (w1 != 0 or (w0 & 0xffff) != 0 or in.slc) return error.NoMatch;
        return;
    }
    if (!in.offen and !in.idxen and vaddr != 0) return error.NoMatch;
    if (!validSReg(srsrc) or !validSrc(soff) or soff == LITERAL or soff >= 240) return error.NoMatch;
    in.dst = @intCast(VGPR0 + vdata);
    in.src[0] = @intCast(VGPR0 + vaddr);
    in.src[1] = @intCast(srsrc);
    in.src[2] = @intCast(soff);
}

fn decodeFlat(w0: u32, w1: u32, in: *Instr) Error!void {
    if (bits(w0, 0, 16) != 0 or bits(w0, 25, 1) != 0) return error.NoMatch;
    if (bits(w1, 16, 8) != 0) return error.NoMatch; // reserved, tfe
    in.op = try lookupCode(.flat, bits(w0, 18, 7));
    const df = in.d();
    in.glc = bits(w0, 16, 1) != 0;
    in.slc = bits(w0, 17, 1) != 0;
    const addr = bits(w1, 0, 8);
    const data = bits(w1, 8, 8);
    const vdst = bits(w1, 24, 8);
    in.src[0] = @intCast(VGPR0 + addr);
    switch (df.shape) {
        .flat_load => {
            if (data != 0) return error.NoMatch;
            in.dst = @intCast(VGPR0 + vdst);
        },
        .flat_store => {
            if (vdst != 0) return error.NoMatch;
            in.src[1] = @intCast(VGPR0 + data);
        },
        else => {
            in.src[1] = @intCast(VGPR0 + data);
            if (in.glc) in.dst = @intCast(VGPR0 + vdst) else if (vdst != 0) return error.NoMatch;
        },
    }
}

// ── Text (LLVM's AMDGPU syntax) ─────────────────────────────────────────────

pub const Text = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn str(t: *Text, x: []const u8) void {
        if (t.len + x.len > t.buf.len) {
            t.overflow = true;
            return;
        }
        @memcpy(t.buf[t.len..][0..x.len], x);
        t.len += x.len;
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

const Special = struct { code: u16, w1: []const u8, w2: []const u8 };
const specials = [_]Special{
    .{ .code = 102, .w1 = "flat_scratch_lo", .w2 = "flat_scratch" },
    .{ .code = 103, .w1 = "flat_scratch_hi", .w2 = "" },
    .{ .code = 106, .w1 = "vcc_lo", .w2 = "vcc" },
    .{ .code = 107, .w1 = "vcc_hi", .w2 = "" },
    .{ .code = 108, .w1 = "tba_lo", .w2 = "tba" },
    .{ .code = 109, .w1 = "tba_hi", .w2 = "" },
    .{ .code = 110, .w1 = "tma_lo", .w2 = "tma" },
    .{ .code = 111, .w1 = "tma_hi", .w2 = "" },
    .{ .code = 124, .w1 = "m0", .w2 = "" },
    .{ .code = 126, .w1 = "exec_lo", .w2 = "exec" },
    .{ .code = 127, .w1 = "exec_hi", .w2 = "" },
    .{ .code = 251, .w1 = "src_vccz", .w2 = "" },
    .{ .code = 252, .w1 = "src_execz", .w2 = "" },
    .{ .code = 253, .w1 = "src_scc", .w2 = "" },
    .{ .code = 254, .w1 = "src_lds_direct", .w2 = "" },
};

fn putRange(t: *Text, prefix: []const u8, first: u32, n: u8) void {
    if (n <= 1) t.print("{s}{d}", .{ prefix, first }) else t.print("{s}[{d}:{d}]", .{ prefix, first, first + n - 1 });
}

/// An operand code as text, for an operand of type `ty` (`lit` for 255).
pub fn putOperand(t: *Text, code: u16, ty: Ty, lit: u32) void {
    const n = @max(ty.dwords(), 1);
    if (code >= VGPR0) return putRange(t, "v", code - VGPR0, n);
    if (code < SGPRS) return putRange(t, "s", code, n);
    if (code >= TTMP0 and code < TTMP0 + 12) return putRange(t, "ttmp", code - TTMP0, n);
    for (specials) |sp| {
        if (sp.code == code) {
            if (n == 2 and sp.w2.len != 0) return t.str(sp.w2);
            return t.str(sp.w1);
        }
    }
    if (code >= 128 and code <= 192) return t.print("{d}", .{code - 128});
    if (code >= 193 and code <= 208) return t.print("-{d}", .{code - 192});
    if (code >= 240 and code <= 248) {
        if (code == 248 and ty.is64()) return t.str(inv2pi64_name);
        return t.str(float_names[code - 240]);
    }
    if (code == LITERAL) return t.print("0x{x}", .{lit});
    t.print("<{d}>", .{code});
}

fn putSrc(t: *Text, in: *const Instr, i: usize, ty: Ty) void {
    const sx = in.sdwa and i < 2 and in.sext >> @intCast(i) & 1 != 0;
    if (sx) t.str("sext(");
    defer if (sx) t.str(")");
    const neg = in.neg >> @intCast(i) & 1 != 0;
    const abs = in.abs >> @intCast(i) & 1 != 0;
    // LLVM writes a negated constant neg(...): -1.0 is a constant of its own.
    const neg_call = neg and !abs and in.src[i] >= 128 and in.src[i] < VGPR0 and in.src[i] != LDS_DIRECT and (in.src[i] < VCCZ or in.src[i] > SCC);
    if (neg_call) t.str("neg(") else if (neg) t.str("-");
    if (abs) t.str("|");
    putOperand(t, in.src[i], ty, in.lit);
    if (abs) t.str("|");
    if (neg_call) t.str(")");
}

const hwreg_names = [_][]const u8{ "", "HW_REG_MODE", "HW_REG_STATUS", "HW_REG_TRAPSTS", "HW_REG_HW_ID", "HW_REG_GPR_ALLOC", "HW_REG_LDS_ALLOC", "HW_REG_IB_STS" };

fn putHwreg(t: *Text, imm: u32) void {
    const id = imm & 63;
    const off = imm >> 6 & 31;
    const size = (imm >> 11 & 31) + 1;
    t.str("hwreg(");
    if (id < hwreg_names.len and id != 0) t.str(hwreg_names[id]) else t.print("{d}", .{id});
    if (off != 0 or size != 32) t.print(", {d}, {d}", .{ off, size });
    t.str(")");
}

pub const dfmt_names = [16][]const u8{ "BUF_DATA_FORMAT_INVALID", "BUF_DATA_FORMAT_8", "BUF_DATA_FORMAT_16", "BUF_DATA_FORMAT_8_8", "BUF_DATA_FORMAT_32", "BUF_DATA_FORMAT_16_16", "BUF_DATA_FORMAT_10_11_11", "BUF_DATA_FORMAT_11_11_10", "BUF_DATA_FORMAT_10_10_10_2", "BUF_DATA_FORMAT_2_10_10_10", "BUF_DATA_FORMAT_8_8_8_8", "BUF_DATA_FORMAT_32_32", "BUF_DATA_FORMAT_16_16_16_16", "BUF_DATA_FORMAT_32_32_32", "BUF_DATA_FORMAT_32_32_32_32", "BUF_DATA_FORMAT_RESERVED_15" };
pub const nfmt_names = [8][]const u8{ "BUF_NUM_FORMAT_UNORM", "BUF_NUM_FORMAT_SNORM", "BUF_NUM_FORMAT_USCALED", "BUF_NUM_FORMAT_SSCALED", "BUF_NUM_FORMAT_UINT", "BUF_NUM_FORMAT_SINT", "BUF_NUM_FORMAT_RESERVED_6", "BUF_NUM_FORMAT_FLOAT" };

fn putWaitcnt(t: *Text, imm: u32) void {
    const vm = imm & 15;
    const exp = imm >> 4 & 7;
    const lgkm = imm >> 8 & 15;
    const all = vm == 15 and exp == 7 and lgkm == 15;
    var first = true;
    if (vm != 15 or all) {
        t.print("vmcnt({d})", .{vm});
        first = false;
    }
    if (exp != 7 or all) {
        t.print("{s}expcnt({d})", .{ if (first) "" else " ", exp });
        first = false;
    }
    if (lgkm != 15 or all) t.print("{s}lgkmcnt({d})", .{ if (first) "" else " ", lgkm });
}

fn putSwizzle(t: *Text, off: u32) void {
    if (off & 0xff00 == 0x8000) {
        t.print(" offset:swizzle(QUAD_PERM,{d},{d},{d},{d})", .{ off & 3, off >> 2 & 3, off >> 4 & 3, off >> 6 & 3 });
        return;
    }
    if (off & 0x8000 == 0) {
        const and_m = off & 31;
        const or_m = off >> 5 & 31;
        const xor_m = off >> 10 & 31;
        if (and_m == 31 and or_m == 0 and @popCount(xor_m) == 1) {
            t.print(" offset:swizzle(SWAP,{d})", .{xor_m});
            return;
        }
        if (and_m == 31 and or_m == 0 and xor_m > 0 and std.math.isPowerOfTwo(xor_m + 1)) {
            t.print(" offset:swizzle(REVERSE,{d})", .{xor_m + 1});
            return;
        }
        const group = 32 - and_m;
        if (group > 1 and std.math.isPowerOfTwo(group) and or_m < group and xor_m == 0) {
            t.print(" offset:swizzle(BROADCAST,{d},{d})", .{ group, or_m });
            return;
        }
        // LLVM prints what lane bit each of the five becomes for an input
        // bit of 0 and of 1: 0, 1, p (kept) or i (inverted). Several masks
        // print alike; only the one that parses back is printed so.
        const probe0 = (0 & and_m | or_m) ^ xor_m;
        const probe1 = (31 & and_m | or_m) ^ xor_m;
        var mask: [5]u8 = undefined;
        var re_and: u32 = 0;
        var re_or: u32 = 0;
        var re_xor: u32 = 0;
        for (0..5) |k| {
            const b = @as(u32, 1) << @intCast(4 - k);
            const p0 = probe0 & b != 0;
            const p1 = probe1 & b != 0;
            if (p0 == p1) {
                mask[k] = if (p0) '1' else '0';
                if (p0) re_or |= b;
            } else {
                mask[k] = if (p0) 'i' else 'p';
                re_and |= b;
                if (p0) re_xor |= b;
            }
        }
        if (re_and == and_m and re_or == or_m and re_xor == xor_m) {
            t.print(" offset:swizzle(BITMASK_PERM,\"{s}\")", .{&mask});
            return;
        }
    }
    t.print(" offset:{d}", .{off});
}

/// A 32-bit immediate as LLVM prints one: inline constants by value, others
/// in hex.
fn putImm32(t: *Text, x: u32) void {
    const si: i32 = @bitCast(x);
    if (si >= -16 and si <= 64) return t.print("{d}", .{si});
    for (float32, 0..) |f, i| {
        if (f == x) return t.str(float_names[i]);
    }
    t.print("0x{x}", .{x});
}

fn mnemonic(t: *Text, in: *const Instr) void {
    const df = in.d();
    t.str(df.name);
    // (LLVM prints a VOPC's SDWA form without the suffix)
    if (in.sdwa) {
        if (df.enc != .vopc) t.str("_sdwa");
        return;
    }
    switch (df.enc) {
        .vop1, .vop2, .vopc => if (in.e64) t.str("_e64") else if (df.e64 and df.shape != .vop_none) t.str("_e32"),
        else => {},
    }
}

/// Print the instruction as LLVM's assembler prints it.
pub fn format(in: *const Instr, buf: []u8) Error![]const u8 {
    var t = Text{ .buf = buf };
    try formatInto(&t, in);
    if (t.overflow) return error.BufferTooSmall;
    return t.text();
}

pub fn formatInto(t: *Text, in: *const Instr) Error!void {
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
        .sopp_imm => if (in.imm <= 64) t.print(" {d}", .{in.imm}) else t.print(" 0x{x}", .{in.imm}),
        .sopp_branch => t.print(" {d}", .{@as(i16, @bitCast(@as(u16, @intCast(in.imm))))}),
        .sopp_waitcnt => {
            t.str(sp);
            putWaitcnt(t, in.imm);
        },
        .smem_load, .smem_store => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], df.s[0], 0);
            t.str(", ");
            if (in.soff_imm) t.print("0x{x}", .{in.imm}) else putOperand(t, in.src[1], .b32, 0);
            if (in.glc) t.str(" glc");
        },
        .smem_none => {},
        .smem_time => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
        },
        .vop_none => {},
        .vop, .vop_sdst => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            for (0..df.nsrc()) |i| {
                t.str(", ");
                putSrc(t, in, i, df.s[i]);
            }
            putVop3Mods(t, in);
        },
        .vop_carry => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.sdst, .b64, 0);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            putVop3Mods(t, in);
        },
        .vop_carry_in => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.sdst, .b64, 0);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            t.str(", ");
            putSrc(t, in, 2, .b64);
            putVop3Mods(t, in);
        },
        .vop_cndmask => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            t.str(", ");
            putSrc(t, in, 2, .b64);
            putVop3Mods(t, in);
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
            t.str(sp);
            putOperand(t, in.sdst, .b64, 0);
            t.str(", ");
            putSrc(t, in, 0, df.s[0]);
            t.str(", ");
            putSrc(t, in, 1, df.s[1]);
            putVop3Mods(t, in);
        },
        .vop3b => {
            t.str(sp);
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.sdst, .b64, 0);
            for (0..3) |i| {
                t.str(", ");
                putSrc(t, in, i, df.s[i]);
            }
            putVop3Mods(t, in);
        },
        .ds_addr_data, .ds_addr_data2, .ds_write2, .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst, .ds_none => formatDs(t, in),
        .buf_load, .buf_store, .buf_atomic, .buf_none => formatBuf(t, in),
        .flat_load, .flat_store, .flat_atomic => formatFlat(t, in),
    }
    if (in.sdwa) putSdwa(t, in);
}

const sel_names = [_][]const u8{ "BYTE_0", "BYTE_1", "BYTE_2", "BYTE_3", "WORD_0", "WORD_1", "DWORD", "?" };
const unused_names = [_][]const u8{ "UNUSED_PAD", "UNUSED_SEXT", "UNUSED_PRESERVE", "?" };

fn putSdwa(t: *Text, in: *const Instr) void {
    const df = in.d();
    if (df.shape != .vopc) t.print(" dst_sel:{s} dst_unused:{s}", .{ sel_names[in.dst_sel], unused_names[in.dst_unused] });
    t.print(" src0_sel:{s}", .{sel_names[in.sel[0]]});
    if (sdwaSrcs(df) == 2) t.print(" src1_sel:{s}", .{sel_names[in.sel[1]]});
}

fn putVop3Mods(t: *Text, in: *const Instr) void {
    if (in.clamp) t.str(" clamp");
    switch (in.omod) {
        1 => t.str(" mul:2"),
        2 => t.str(" mul:4"),
        3 => t.str(" div:2"),
        else => {},
    }
}

fn formatDs(t: *Text, in: *const Instr) void {
    const df = in.d();
    const sh = df.shape;
    var first = true;
    const sep = struct {
        fn f(tt: *Text, fst: *bool) void {
            tt.str(if (fst.*) " " else ", ");
            fst.* = false;
        }
    }.f;
    switch (sh) {
        .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst => {
            sep(t, &first);
            putOperand(t, in.dst, df.d, 0);
        },
        else => {},
    }
    if (sh != .ds_vdst and sh != .ds_none) {
        sep(t, &first);
        putOperand(t, in.src[0], .b32, 0);
    }
    switch (sh) {
        .ds_addr_data, .ds_rtn => {
            sep(t, &first);
            putOperand(t, in.src[1], df.s[1], 0);
        },
        .ds_addr_data2, .ds_write2, .ds_rtn2, .ds_rtn_write2 => {
            sep(t, &first);
            putOperand(t, in.src[1], df.s[1], 0);
            sep(t, &first);
            putOperand(t, in.src[2], df.s[2], 0);
        },
        else => {},
    }
    switch (sh) {
        .ds_write2, .ds_read2, .ds_rtn_write2 => {
            if (in.imm & 0xff != 0) t.print(" offset0:{d}", .{in.imm & 0xff});
            if (in.imm >> 8 != 0) t.print(" offset1:{d}", .{in.imm >> 8});
        },
        .ds_swizzle => if (in.imm != 0) putSwizzle(t, in.imm),
        .ds_none => {},
        else => if (in.imm != 0) t.print(" offset:{d}", .{in.imm}),
    }
    if (in.gds) t.str(" gds");
}

fn formatBuf(t: *Text, in: *const Instr) void {
    const df = in.d();
    if (df.shape == .buf_none) return;
    t.str(" ");
    // tfe adds a dword to the data: v[1:2] for one dword
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
        const dfmt = in.fmt & 15;
        const nfmt = in.fmt >> 4 & 7;
        t.str(" format:[");
        if (dfmt != 1) t.str(dfmt_names[dfmt]);
        if (dfmt != 1 and nfmt != 0) t.str(",");
        if (nfmt != 0) t.str(nfmt_names[nfmt]);
        t.str("]");
    }
    if (in.idxen) t.str(" idxen");
    if (in.offen) t.str(" offen");
    if (in.imm != 0) t.print(" offset:{d}", .{in.imm});
    if (in.glc) t.str(" glc");
    if (in.slc) t.str(" slc");
    if (in.tfe) t.str(" tfe");
}

fn formatFlat(t: *Text, in: *const Instr) void {
    const df = in.d();
    t.str(" ");
    switch (df.shape) {
        .flat_load => {
            putOperand(t, in.dst, df.d, 0);
            t.str(", ");
            putOperand(t, in.src[0], .b64, 0);
        },
        .flat_store => {
            putOperand(t, in.src[0], .b64, 0);
            t.str(", ");
            putOperand(t, in.src[1], df.s[1], 0);
        },
        else => {
            if (in.glc) {
                putOperand(t, in.dst, df.d, 0);
                t.str(", ");
            }
            putOperand(t, in.src[0], .b64, 0);
            t.str(", ");
            putOperand(t, in.src[1], df.s[1], 0);
        },
    }
    if (in.glc) t.str(" glc");
    if (in.slc) t.str(" slc");
}

// ── Parsing ─────────────────────────────────────────────────────────────────

/// A parsed operand: a register (code and dwords), a constant (an inline
/// code, or a literal value), or a modifier wrapper.
const Opnd = struct {
    kind: enum { reg, int, float, off } = .reg,
    code: u16 = 0,
    n: u8 = 1,
    /// the register's width is fixed by its name (vcc, exec_lo, m0...)
    named: bool = false,
    int: i64 = 0,
    hex: bool = false,
    float: f64 = 0,
    neg: bool = false,
    abs: bool = false,
    /// sext(...): an SDWA source sign-extended
    sext: bool = false,
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseRange(tok: []const u8, prefix: []const u8, first: *u32, n: *u8) bool {
    if (!std.mem.startsWith(u8, tok, prefix)) return false;
    const r = tok[prefix.len..];
    if (r.len == 0) return false;
    if (r[0] == '[') {
        if (r[r.len - 1] != ']') return false;
        const inner = r[1 .. r.len - 1];
        const colon = std.mem.indexOfScalar(u8, inner, ':') orelse {
            const a = std.fmt.parseInt(u32, inner, 10) catch return false;
            first.* = a;
            n.* = 1;
            return true;
        };
        const a = std.fmt.parseInt(u32, inner[0..colon], 10) catch return false;
        const b = std.fmt.parseInt(u32, inner[colon + 1 ..], 10) catch return false;
        if (b < a or b - a >= 16) return false;
        first.* = a;
        n.* = @intCast(b - a + 1);
        return true;
    }
    for (r) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    first.* = std.fmt.parseInt(u32, r, 10) catch return false;
    n.* = 1;
    return true;
}

fn parseOpnd(tok_in: []const u8) Error!Opnd {
    var tok = std.mem.trim(u8, tok_in, " \t");
    var o = Opnd{};
    if (std.mem.startsWith(u8, tok, "sext(") and tok[tok.len - 1] == ')') {
        o.sext = true;
        tok = std.mem.trim(u8, tok[5 .. tok.len - 1], " \t");
    }
    if (std.mem.startsWith(u8, tok, "neg(") and tok[tok.len - 1] == ')') {
        o.neg = true;
        tok = tok[4 .. tok.len - 1];
    }
    if (std.mem.startsWith(u8, tok, "abs(") and tok[tok.len - 1] == ')') {
        o.abs = true;
        tok = tok[4 .. tok.len - 1];
    }
    if (!o.neg and tok.len > 1 and tok[0] == '-' and (tok[1] == '|' or tok[1] == 'v' or tok[1] == 's' or std.ascii.isAlphabetic(tok[1]))) {
        o.neg = true;
        tok = tok[1..];
    }
    if (tok.len > 2 and tok[0] == '|' and tok[tok.len - 1] == '|') {
        o.abs = true;
        tok = tok[1 .. tok.len - 1];
    }
    if (tok.len == 0) return error.Syntax;
    var first: u32 = 0;
    var n: u8 = 1;
    if (parseRange(tok, "v", &first, &n)) {
        if (first + n > 256) return error.OutOfRange;
        o.code = @intCast(VGPR0 + first);
        o.n = n;
        return o;
    }
    if (parseRange(tok, "ttmp", &first, &n)) {
        if (first + n > 12) return error.OutOfRange;
        o.code = @intCast(TTMP0 + first);
        o.n = n;
        return o;
    }
    if (parseRange(tok, "s", &first, &n)) {
        if (first + n > SGPRS) return error.OutOfRange;
        o.code = @intCast(first);
        o.n = n;
        return o;
    }
    if (eqlIgnoreCase(tok, "off")) {
        o.kind = .off;
        return o;
    }
    for (specials) |sp| {
        if (eqlIgnoreCase(tok, sp.w1)) {
            o.code = sp.code;
            o.named = true;
            return o;
        }
        if (sp.w2.len != 0 and eqlIgnoreCase(tok, sp.w2)) {
            o.code = sp.code;
            o.n = 2;
            o.named = true;
            return o;
        }
    }
    const aliases = [_]struct { []const u8, u16 }{ .{ "scc", SCC }, .{ "vccz", VCCZ }, .{ "execz", EXECZ }, .{ "lds_direct", LDS_DIRECT } };
    for (aliases) |a| {
        if (eqlIgnoreCase(tok, a[0])) {
            o.code = a[1];
            o.named = true;
            return o;
        }
    }
    // numbers
    var neg = false;
    var num = tok;
    if (num[0] == '-') {
        neg = true;
        num = num[1..];
    }
    if (num.len == 0) return error.Syntax;
    if (std.mem.indexOfAny(u8, num, ".eE") != null and !std.mem.startsWith(u8, num, "0x")) {
        const f = std.fmt.parseFloat(f64, num) catch return error.Syntax;
        o.kind = .float;
        o.float = if (neg) -f else f;
        return o;
    }
    const hex = std.mem.startsWith(u8, num, "0x") or std.mem.startsWith(u8, num, "0X");
    const val = std.fmt.parseInt(i64, num, 0) catch return error.Syntax;
    o.kind = .int;
    o.hex = hex;
    o.int = if (neg) -val else val;
    return o;
}

/// The operand code (and literal) of a constant for an operand of type `ty`,
/// as LLVM's assembler chooses it.
fn constCode(o: Opnd, ty: Ty, lit: *u32, has_lit: *bool) Error!u16 {
    if (o.kind == .int) {
        const x = o.int;
        if (x >= -16 and x <= 64) return inlineInt(@intCast(x));
        switch (ty) {
            .b32, .f32 => {
                if (x < std.math.minInt(i32) or x > std.math.maxInt(u32)) return error.OutOfRange;
                const b: u32 = @truncate(@as(u64, @bitCast(x)));
                for (float32, 0..) |f, i| {
                    if (f == b) return @intCast(240 + i);
                }
                const si: i32 = @bitCast(b);
                if (si >= -16 and si <= 64) return inlineInt(si);
                return setLit(lit, has_lit, b);
            },
            .f16 => {
                if (x >= 0 and x <= 0xffff) {
                    const h: u16 = @intCast(x);
                    for (float16, 0..) |f, i| {
                        if (f == h) return @intCast(240 + i);
                    }
                    const si: i16 = @bitCast(h);
                    if (si >= -16 and si <= 64) return inlineInt(si);
                }
                if (x < std.math.minInt(i32) or x > std.math.maxInt(u32)) return error.OutOfRange;
                return setLit(lit, has_lit, @truncate(@as(u64, @bitCast(x))));
            },
            .b16 => {
                if (x < std.math.minInt(i32) or x > std.math.maxInt(u32)) return error.OutOfRange;
                return setLit(lit, has_lit, @truncate(@as(u64, @bitCast(x))));
            },
            .f64 => {
                if (x < 0 or x > std.math.maxInt(u32)) return error.OutOfRange;
                const hi = @as(u64, @intCast(x)) << 32;
                for (float64, 0..) |f, i| {
                    if (f == hi) return @intCast(240 + i);
                }
                return setLit(lit, has_lit, @intCast(x));
            },
            else => {
                if (x < std.math.minInt(i32) or x > std.math.maxInt(u32)) return error.OutOfRange;
                return setLit(lit, has_lit, @truncate(@as(u64, @bitCast(x))));
            },
        }
    }
    if (o.kind == .float) {
        const f = o.float;
        switch (ty) {
            .f64, .b64 => {
                const b: u64 = @bitCast(f);
                for (float64, 0..) |c, i| {
                    if (c == b) return @intCast(240 + i);
                }
                if (b & 0xffffffff != 0) return error.OutOfRange;
                return setLit(lit, has_lit, @intCast(b >> 32));
            },
            .f16, .b16 => {
                const h: u16 = @bitCast(@as(f16, @floatCast(f)));
                for (float16, 0..) |c, i| {
                    if (c == h) return @intCast(240 + i);
                }
                return setLit(lit, has_lit, h);
            },
            else => {
                const b: u32 = @bitCast(@as(f32, @floatCast(f)));
                for (float32, 0..) |c, i| {
                    if (c == b) return @intCast(240 + i);
                }
                return setLit(lit, has_lit, b);
            },
        }
    }
    return error.Syntax;
}

fn setLit(lit: *u32, has_lit: *bool, x: u32) Error!u16 {
    if (has_lit.* and lit.* != x) return error.NoForm;
    lit.* = x;
    has_lit.* = true;
    return LITERAL;
}

const Parser = struct {
    in: Instr,
    has_lit: bool = false,
    /// MUBUF/MTBUF: the data and address widths as written (checked once
    /// tfe, offen and idxen are known); FLAT atomics: a result was named.
    data_n: u8 = 0,
    addr_n: u8 = 0,
    rtn: bool = false,
    /// SDWA: dst_unused was written (LLVM's default is UNUSED_PRESERVE)
    dst_unused_set: bool = false,

    /// A source operand of type `ty`: a register of its width, or a constant.
    fn src(p: *Parser, tok: []const u8, i: usize, ty: Ty) Error!void {
        const o = try parseOpnd(tok);
        if (o.sext) {
            if (i > 1) return error.Syntax;
            p.in.sext |= @as(u2, 1) << @intCast(i);
        }
        if (o.neg) p.in.neg |= @as(u3, 1) << @intCast(i);
        if (o.abs) p.in.abs |= @as(u3, 1) << @intCast(i);
        p.in.src[i] = try p.value(o, ty);
    }

    fn value(p: *Parser, o: Opnd, ty: Ty) Error!u16 {
        switch (o.kind) {
            .reg => {
                if (!o.named and o.n != @max(ty.dwords(), 1)) return error.NoForm;
                return o.code;
            },
            .int, .float => return constCode(o, ty, &p.in.lit, &p.has_lit),
            .off => return error.NoForm,
        }
    }

    /// A register operand (no constants) of `n` dwords.
    fn reg(_: *Parser, tok: []const u8, ty: Ty) Error!u16 {
        const o = try parseOpnd(tok);
        if (o.kind != .reg or o.neg or o.abs or o.sext) return error.NoForm;
        if (!o.named and o.n != @max(ty.dwords(), 1)) return error.NoForm;
        return o.code;
    }

    fn vreg(_: *Parser, tok: []const u8, n: u8) Error!u16 {
        const o = try parseOpnd(tok);
        if (o.kind != .reg or o.code < VGPR0 or o.n != n or o.neg or o.abs or o.sext) return error.NoForm;
        return o.code;
    }
};

/// Split `s` at top-level commas (not inside () [] "").
fn splitOperands(str: []const u8, out: [][]const u8) Error!usize {
    var n: usize = 0;
    var depth: i32 = 0;
    var quote = false;
    var start: usize = 0;
    for (str, 0..) |c, i| {
        if (c == '"') quote = !quote;
        if (quote) continue;
        switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ',' => if (depth == 0) {
                if (n == out.len) return error.Syntax;
                out[n] = std.mem.trim(u8, str[start..i], " \t");
                n += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, str[start..], " \t");
    if (last.len != 0 or n != 0) {
        if (n == out.len) return error.Syntax;
        out[n] = last;
        n += 1;
    }
    return n;
}

/// Split the last operand into the operand and its trailing modifiers
/// (space-separated words at depth 0).
fn splitWords(str: []const u8, out: [][]const u8) Error!usize {
    var n: usize = 0;
    var depth: i32 = 0;
    var quote = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= str.len) : (i += 1) {
        const c: u8 = if (i < str.len) str[i] else ' ';
        if (c == '"') quote = !quote;
        if (!quote) switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            else => {},
        };
        if ((c == ' ' or c == '\t') and depth == 0 and !quote) {
            if (i > start) {
                if (n == out.len) return error.Syntax;
                out[n] = str[start..i];
                n += 1;
            }
            start = i + 1;
        }
    }
    return n;
}

fn parseU(str: []const u8) Error!u32 {
    const x = std.fmt.parseInt(i64, std.mem.trim(u8, str, " \t"), 0) catch return error.Syntax;
    if (x < 0 or x > std.math.maxInt(u32)) return error.OutOfRange;
    return @intCast(x);
}

fn parseHwreg(tok: []const u8) Error!u32 {
    if (!std.mem.startsWith(u8, tok, "hwreg(") or tok[tok.len - 1] != ')') return error.Syntax;
    var parts: [3][]const u8 = undefined;
    const np = try splitOperands(tok[6 .. tok.len - 1], &parts);
    if (np != 1 and np != 3) return error.Syntax;
    var id: u32 = 0;
    var found = false;
    for (hwreg_names, 0..) |nm, i| {
        if (i != 0 and std.mem.eql(u8, parts[0], nm)) {
            id = @intCast(i);
            found = true;
        }
    }
    if (!found) id = try parseU(parts[0]);
    var off: u32 = 0;
    var size: u32 = 32;
    if (np == 3) {
        off = try parseU(parts[1]);
        size = try parseU(parts[2]);
    }
    if (id > 63 or off > 31 or size < 1 or size > 32) return error.OutOfRange;
    return id | off << 6 | (size - 1) << 11;
}

fn parseWaitcnt(words: []const []const u8) Error!u32 {
    var vm: u32 = 15;
    var exp: u32 = 7;
    var lgkm: u32 = 15;
    if (words.len == 1 and words[0].len > 0 and std.ascii.isDigit(words[0][0])) return parseU(words[0]);
    for (words) |w0| {
        var w = w0;
        while (w.len != 0) {
            if (w[0] == '&' or w[0] == ',') {
                w = w[1..];
                continue;
            }
            const lp = std.mem.indexOfScalar(u8, w, '(') orelse return error.Syntax;
            const rp = std.mem.indexOfScalar(u8, w, ')') orelse return error.Syntax;
            const name = w[0..lp];
            const val = try parseU(w[lp + 1 .. rp]);
            if (std.mem.eql(u8, name, "vmcnt")) vm = val else if (std.mem.eql(u8, name, "expcnt")) exp = val else if (std.mem.eql(u8, name, "lgkmcnt")) lgkm = val else return error.Syntax;
            w = w[rp + 1 ..];
        }
    }
    if (vm > 15 or exp > 7 or lgkm > 15) return error.OutOfRange;
    return vm | exp << 4 | lgkm << 8;
}

fn parseSwizzle(arg: []const u8) Error!u32 {
    // swizzle(MODE,...)
    if (!std.mem.startsWith(u8, arg, "swizzle(") or arg[arg.len - 1] != ')') return parseU(arg);
    var parts: [5][]const u8 = undefined;
    const np = try splitOperands(arg[8 .. arg.len - 1], &parts);
    if (np < 1) return error.Syntax;
    const mode = parts[0];
    if (std.mem.eql(u8, mode, "QUAD_PERM")) {
        if (np != 5) return error.Syntax;
        var x: u32 = 0x8000;
        for (0..4) |i| {
            const l = try parseU(parts[i + 1]);
            if (l > 3) return error.OutOfRange;
            x |= l << @intCast(2 * i);
        }
        return x;
    }
    if (std.mem.eql(u8, mode, "SWAP")) {
        if (np != 2) return error.Syntax;
        return 31 | (try parseU(parts[1])) << 10;
    }
    if (std.mem.eql(u8, mode, "REVERSE")) {
        if (np != 2) return error.Syntax;
        return 31 | (try parseU(parts[1]) - 1) << 10;
    }
    if (std.mem.eql(u8, mode, "BROADCAST")) {
        if (np != 3) return error.Syntax;
        const g = try parseU(parts[1]);
        const l = try parseU(parts[2]);
        if (g < 2 or g > 32 or !std.math.isPowerOfTwo(g) or l >= g) return error.OutOfRange;
        return (32 - g) | l << 5;
    }
    if (std.mem.eql(u8, mode, "BITMASK_PERM")) {
        if (np != 2) return error.Syntax;
        const m = parts[1];
        if (m.len != 7 or m[0] != '"' or m[6] != '"') return error.Syntax;
        var and_m: u32 = 0;
        var or_m: u32 = 0;
        var xor_m: u32 = 0;
        for (0..5) |k| {
            const b = @as(u32, 1) << @intCast(4 - k);
            switch (m[1 + k]) {
                'p' => and_m |= b,
                'i' => {
                    and_m |= b;
                    xor_m |= b;
                },
                '1' => or_m |= b,
                '0' => {},
                else => return error.Syntax,
            }
        }
        return and_m | or_m << 5 | xor_m << 10;
    }
    return error.Syntax;
}

fn parseFormat(arg: []const u8) Error!u8 {
    if (arg.len > 0 and arg[0] != '[') {
        const x = try parseU(arg);
        if (x > 127) return error.OutOfRange;
        return @intCast(x);
    }
    if (arg.len < 2 or arg[arg.len - 1] != ']') return error.Syntax;
    var parts: [2][]const u8 = undefined;
    const np = try splitOperands(arg[1 .. arg.len - 1], &parts);
    var dfmt: u8 = 1;
    var nfmt: u8 = 0;
    for (parts[0..np]) |p| {
        var hit = false;
        for (dfmt_names, 0..) |nm, i| {
            if (std.mem.eql(u8, p, nm)) {
                dfmt = @intCast(i);
                hit = true;
            }
        }
        for (nfmt_names, 0..) |nm, i| {
            if (std.mem.eql(u8, p, nm)) {
                nfmt = @intCast(i);
                hit = true;
            }
        }
        if (!hit) return error.Syntax;
    }
    return dfmt | nfmt << 4;
}

/// Parse one line of LLVM AMDGPU syntax. A branch target that is a label is
/// returned in `label` (the immediate is left 0) when `label` is given.
pub fn parseLabel(line_in: []const u8, label: ?*?[]const u8) Error!Instr {
    const line = std.mem.trim(u8, line_in, " \t\r");
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    var name = line[0..sp];
    const rest = std.mem.trim(u8, line[sp..], " \t");
    var suffix: enum { none, e32, e64, sdwa } = .none;
    if (std.mem.endsWith(u8, name, "_sdwa")) {
        suffix = .sdwa;
        name = name[0 .. name.len - 5];
    } else if (std.mem.endsWith(u8, name, "_e32")) {
        suffix = .e32;
        name = name[0 .. name.len - 4];
    } else if (std.mem.endsWith(u8, name, "_e64")) {
        suffix = .e64;
        name = name[0 .. name.len - 4];
    }
    const o = lookup(name) orelse return error.Syntax;
    const df = &defs[o];
    if (suffix == .sdwa) {
        if (!sdwaOk(df)) return error.NoForm;
    } else if (suffix != .none) switch (df.enc) {
        .vop1, .vop2, .vopc => if (!df.e64) return error.Syntax,
        else => return error.Syntax,
    };
    var p = Parser{ .in = .{ .op = o, .e64 = suffix == .e64, .sdwa = suffix == .sdwa } };
    if (df.enc == .mtbuf or df.enc == .mubuf) p.in.fmt = 1;
    var ops_buf: [8][]const u8 = undefined;
    var nops = try splitOperands(rest, &ops_buf);
    var mods_buf: [12][]const u8 = undefined;
    var mods: []const []const u8 = &.{};
    if (nops > 0) {
        var words: [13][]const u8 = undefined;
        const nw = try splitWords(ops_buf[nops - 1], &words);
        if (nw == 0) return error.Syntax;
        if (df.shape == .sopp_waitcnt) {
            p.in.imm = try parseWaitcnt(words[0..nw]);
            if (nops != 1) return error.Syntax;
            return p.in;
        }
        ops_buf[nops - 1] = words[0];
        // A modifier-only "operand" (ds_read2 v[1:2], v3 offset0:4): the
        // operand list ends at the first modifier word.
        for (words[1..nw], 0..) |w, i| mods_buf[i] = w;
        mods = mods_buf[0 .. nw - 1];
        if (nops == 1 and isModifier(ops_buf[0])) {
            // no operands at all (ds_nop offset?), only modifiers
            mods_buf[nw - 1] = ops_buf[0];
            mods = mods_buf[0..nw];
            nops = 0;
        }
    }
    const ops = ops_buf[0..nops];
    try parseOperands(&p, df, ops, label);
    try parseMods(&p, df, mods);
    if (p.in.sdwa) {
        // (selects make a VOPC instruction SDWA without the suffix)
        if (suffix == .e32 or suffix == .e64 or !sdwaOk(df)) return error.Syntax;
        if (!p.dst_unused_set and df.shape != .vopc) p.in.dst_unused = 2;
        return p.in;
    }
    if (p.in.sext != 0) return error.Syntax;
    // An unsuffixed VOP1/VOP2/VOPC that only fits VOP3 becomes _e64.
    if (suffix == .none and df.e64 and !fitsE32(&p.in)) p.in.e64 = true;
    return p.in;
}

pub fn parse(line: []const u8) Error!Instr {
    return parseLabel(line, null);
}

fn parseSel(name: []const u8) Error!u3 {
    for (sel_names[0..7], 0..) |nm, ix| {
        if (std.mem.eql(u8, name, nm)) return @intCast(ix);
    }
    return error.Syntax;
}

fn isModifier(w: []const u8) bool {
    const names = [_][]const u8{ "glc", "slc", "tfe", "gds", "offen", "idxen", "clamp", "lds" };
    for (names) |n| {
        if (std.mem.eql(u8, w, n)) return true;
    }
    const prefixes = [_][]const u8{ "offset:", "offset0:", "offset1:", "mul:", "div:", "format:", "dst_sel:", "dst_unused:", "src0_sel:", "src1_sel:" };
    for (prefixes) |pf| {
        if (std.mem.startsWith(u8, w, pf)) return true;
    }
    return false;
}

fn fitsE32(in: *const Instr) bool {
    const df = in.d();
    if (in.neg != 0 or in.abs != 0 or in.clamp or in.omod != 0) return false;
    switch (df.enc) {
        .vop2 => {
            if (!isV(in.src[1])) return false;
            switch (df.shape) {
                .vop_carry => return in.sdst == VCC_LO,
                .vop_carry_in => return in.sdst == VCC_LO and in.src[2] == VCC_LO,
                .vop_cndmask => return in.src[2] == VCC_LO,
                else => return true,
            }
        },
        .vopc => return isV(in.src[1]) and in.sdst == VCC_LO,
        .vop1 => return true,
        else => return true,
    }
}

fn need(ops: []const []const u8, n: usize) Error!void {
    if (ops.len != n) return error.Syntax;
}

fn parseOperands(p: *Parser, df: *const Def, ops: []const []const u8, label: ?*?[]const u8) Error!void {
    const in = &p.in;
    switch (df.shape) {
        .sop2 => {
            try need(ops, 3);
            in.dst = try p.reg(ops[0], df.d);
            try p.src(ops[1], 0, df.s[0]);
            try p.src(ops[2], 1, df.s[1]);
        },
        .sop1 => {
            try need(ops, 2);
            in.dst = try p.reg(ops[0], df.d);
            try p.src(ops[1], 0, df.s[0]);
        },
        .sop1_dst => {
            try need(ops, 1);
            in.dst = try p.reg(ops[0], df.d);
        },
        .sop1_src => {
            try need(ops, 1);
            try p.src(ops[0], 0, df.s[0]);
        },
        .sopc => {
            try need(ops, 2);
            try p.src(ops[0], 0, df.s[0]);
            try p.src(ops[1], 1, df.s[1]);
        },
        .sopk => {
            try need(ops, 2);
            in.dst = try p.reg(ops[0], df.d);
            const x = std.fmt.parseInt(i64, ops[1], 0) catch return error.Syntax;
            if (x < -32768 or x > 0xffff) return error.OutOfRange;
            in.imm = @as(u16, @truncate(@as(u64, @bitCast(x))));
        },
        .sopk_getreg => {
            try need(ops, 2);
            in.dst = try p.reg(ops[0], df.d);
            in.imm = try parseHwreg(ops[1]);
        },
        .sopk_setreg => {
            try need(ops, 2);
            in.imm = try parseHwreg(ops[0]);
            in.dst = try p.reg(ops[1], df.d);
        },
        .sopk_setreg_imm => {
            try need(ops, 2);
            in.imm = try parseHwreg(ops[0]);
            const o = try parseOpnd(ops[1]);
            switch (o.kind) {
                .int => {
                    if (o.int < std.math.minInt(i32) or o.int > std.math.maxInt(u32)) return error.OutOfRange;
                    in.lit = @truncate(@as(u64, @bitCast(o.int)));
                },
                .float => in.lit = @bitCast(@as(f32, @floatCast(o.float))),
                else => return error.Syntax,
            }
        },
        .sopp, .smem_none, .vop_none, .ds_none, .buf_none => try need(ops, 0),
        .sopp_imm => {
            try need(ops, 1);
            const x = std.fmt.parseInt(i64, ops[0], 0) catch return error.Syntax;
            if (x < -32768 or x > 0xffff) return error.OutOfRange;
            in.imm = @as(u16, @truncate(@as(u64, @bitCast(x))));
        },
        .sopp_branch => {
            try need(ops, 1);
            const x = std.fmt.parseInt(i64, ops[0], 0) catch {
                if (label) |l| {
                    l.* = ops[0];
                    return;
                }
                return error.Syntax;
            };
            if (x < -32768 or x > 32767) return error.OutOfRange;
            in.imm = @as(u16, @bitCast(@as(i16, @intCast(x))));
        },
        .sopp_waitcnt => return error.Syntax,
        .smem_load, .smem_store => {
            try need(ops, 3);
            in.dst = try p.reg(ops[0], df.d);
            in.src[0] = try p.reg(ops[1], df.s[0]);
            const o = try parseOpnd(ops[2]);
            if (o.kind == .int) {
                if (o.int < 0 or o.int >= 1 << 20) return error.OutOfRange;
                in.imm = @intCast(o.int);
                in.soff_imm = true;
            } else if (o.kind == .reg and o.code < 128 and o.n == 1) {
                in.src[1] = o.code;
                in.soff_imm = false;
            } else return error.NoForm;
        },
        .smem_time => {
            try need(ops, 1);
            in.dst = try p.reg(ops[0], df.d);
            in.soff_imm = false;
        },
        .vop, .vop_sdst => {
            const ns = df.nsrc();
            try need(ops, 1 + ns);
            in.dst = try p.reg(ops[0], df.d);
            for (0..ns) |i| try p.src(ops[1 + i], i, df.s[i]);
        },
        .vop_carry => {
            try need(ops, 4);
            in.dst = try p.reg(ops[0], df.d);
            in.sdst = try p.reg(ops[1], .b64);
            try p.src(ops[2], 0, df.s[0]);
            try p.src(ops[3], 1, df.s[1]);
        },
        .vop_carry_in => {
            try need(ops, 5);
            in.dst = try p.reg(ops[0], df.d);
            in.sdst = try p.reg(ops[1], .b64);
            try p.src(ops[2], 0, df.s[0]);
            try p.src(ops[3], 1, df.s[1]);
            try p.src(ops[4], 2, .b64);
        },
        .vop_cndmask => {
            try need(ops, 4);
            in.dst = try p.reg(ops[0], df.d);
            try p.src(ops[1], 0, df.s[0]);
            try p.src(ops[2], 1, df.s[1]);
            try p.src(ops[3], 2, .b64);
        },
        .vop_madmk, .vop_madak => {
            try need(ops, 4);
            in.dst = try p.reg(ops[0], df.d);
            try p.src(ops[1], 0, df.s[0]);
            const k = if (df.shape == .vop_madmk) ops[2] else ops[3];
            const s1 = if (df.shape == .vop_madmk) ops[3] else ops[2];
            in.src[1] = try p.vreg(s1, 1);
            const ko = try parseOpnd(k);
            var kv: u32 = 0;
            if (ko.kind == .int) {
                if (ko.int < std.math.minInt(i32) or ko.int > std.math.maxInt(u32)) return error.OutOfRange;
                kv = @truncate(@as(u64, @bitCast(ko.int)));
            } else if (ko.kind == .float) {
                kv = if (df.d == .f16) @as(u16, @bitCast(@as(f16, @floatCast(ko.float)))) else @bitCast(@as(f32, @floatCast(ko.float)));
            } else return error.NoForm;
            if (p.has_lit and in.lit != kv) return error.NoForm;
            in.lit = kv;
            p.has_lit = true;
        },
        .vopc => {
            try need(ops, 3);
            in.sdst = try p.reg(ops[0], .b64);
            try p.src(ops[1], 0, df.s[0]);
            try p.src(ops[2], 1, df.s[1]);
        },
        .vop3b => {
            try need(ops, 5);
            in.dst = try p.reg(ops[0], df.d);
            in.sdst = try p.reg(ops[1], .b64);
            for (0..3) |i| try p.src(ops[2 + i], i, df.s[i]);
        },
        .ds_addr_data, .ds_addr_data2, .ds_write2, .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst => {
            var k: usize = 0;
            const sh = df.shape;
            const has_vdst = switch (sh) {
                .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst => true,
                else => false,
            };
            const nd: usize = switch (sh) {
                .ds_addr_data, .ds_rtn => 1,
                .ds_addr_data2, .ds_write2, .ds_rtn2, .ds_rtn_write2 => 2,
                else => 0,
            };
            const has_addr = sh != .ds_vdst;
            try need(ops, @as(usize, @intFromBool(has_vdst)) + @intFromBool(has_addr) + nd);
            if (has_vdst) {
                in.dst = try p.vreg(ops[k], df.d.dwords());
                k += 1;
            }
            if (has_addr) {
                in.src[0] = try p.vreg(ops[k], 1);
                k += 1;
            }
            for (0..nd) |i| {
                in.src[1 + i] = try p.vreg(ops[k], df.s[1 + i].dwords());
                k += 1;
            }
        },
        .buf_load, .buf_store, .buf_atomic => {
            try need(ops, 4);
            const vd = try parseOpnd(ops[0]);
            if (vd.kind != .reg or vd.code < VGPR0 or vd.neg or vd.abs) return error.NoForm;
            in.dst = vd.code;
            p.data_n = vd.n;
            const va = try parseOpnd(ops[1]);
            if (va.kind == .off) {
                in.src[0] = VGPR0;
            } else if (va.kind == .reg and va.code >= VGPR0) {
                in.src[0] = va.code;
                p.addr_n = va.n;
            } else return error.NoForm;
            in.src[1] = try p.reg(ops[2], .b128);
            const so = try parseOpnd(ops[3]);
            switch (so.kind) {
                .reg => {
                    if (so.code >= 128 or so.n != 1) return error.NoForm;
                    in.src[2] = so.code;
                },
                .int => {
                    if (so.int < -16 or so.int > 64) return error.NoForm;
                    in.src[2] = inlineInt(@intCast(so.int));
                },
                else => return error.NoForm,
            }
        },
        .flat_load => {
            try need(ops, 2);
            in.dst = try p.vreg(ops[0], df.d.dwords());
            in.src[0] = try p.vreg(ops[1], 2);
        },
        .flat_store => {
            try need(ops, 2);
            in.src[0] = try p.vreg(ops[0], 2);
            in.src[1] = try p.vreg(ops[1], df.s[1].dwords());
        },
        .flat_atomic => {
            if (ops.len == 3) {
                in.dst = try p.vreg(ops[0], df.d.dwords());
                in.src[0] = try p.vreg(ops[1], 2);
                in.src[1] = try p.vreg(ops[2], df.s[1].dwords());
                p.rtn = true;
            } else {
                try need(ops, 2);
                in.src[0] = try p.vreg(ops[0], 2);
                in.src[1] = try p.vreg(ops[1], df.s[1].dwords());
            }
        },
    }
}

fn parseMods(p: *Parser, df: *const Def, mods: []const []const u8) Error!void {
    const in = &p.in;
    const is_buf = df.enc == .mubuf or df.enc == .mtbuf;
    for (mods) |m| {
        if (std.mem.eql(u8, m, "glc")) in.glc = true else if (std.mem.eql(u8, m, "slc")) in.slc = true else if (std.mem.eql(u8, m, "tfe")) in.tfe = true else if (std.mem.eql(u8, m, "gds")) in.gds = true else if (std.mem.eql(u8, m, "offen")) in.offen = true else if (std.mem.eql(u8, m, "idxen")) in.idxen = true else if (std.mem.eql(u8, m, "clamp")) in.clamp = true else if (std.mem.eql(u8, m, "mul:2")) in.omod = 1 else if (std.mem.eql(u8, m, "mul:4")) in.omod = 2 else if (std.mem.eql(u8, m, "div:2")) in.omod = 3 else if (std.mem.startsWith(u8, m, "offset0:")) {
            const x = try parseU(m[8..]);
            if (x > 255) return error.OutOfRange;
            in.imm = (in.imm & 0xff00) | x;
        } else if (std.mem.startsWith(u8, m, "offset1:")) {
            const x = try parseU(m[8..]);
            if (x > 255) return error.OutOfRange;
            in.imm = (in.imm & 0xff) | x << 8;
        } else if (std.mem.startsWith(u8, m, "offset:")) {
            in.imm = if (df.shape == .ds_swizzle) try parseSwizzle(m[7..]) else try parseU(m[7..]);
        } else if (std.mem.startsWith(u8, m, "format:")) {
            if (df.enc != .mtbuf) return error.Syntax;
            in.fmt = try parseFormat(m[7..]);
        } else if (std.mem.startsWith(u8, m, "dst_sel:")) {
            in.dst_sel = try parseSel(m[8..]);
            in.sdwa = true;
        } else if (std.mem.startsWith(u8, m, "dst_unused:")) {
            const names = [_][]const u8{ "UNUSED_PAD", "UNUSED_SEXT", "UNUSED_PRESERVE" };
            in.dst_unused = for (names, 0..) |nm, ix| {
                if (std.mem.eql(u8, m[11..], nm)) break @intCast(ix);
            } else return error.Syntax;
            p.dst_unused_set = true;
            in.sdwa = true;
        } else if (std.mem.startsWith(u8, m, "src0_sel:")) {
            in.sel[0] = try parseSel(m[9..]);
            in.sdwa = true;
        } else if (std.mem.startsWith(u8, m, "src1_sel:")) {
            in.sel[1] = try parseSel(m[9..]);
            in.sdwa = true;
        } else return error.Syntax;
    }
    // Which modifiers each encoding has.
    const enc = df.enc;
    const vop = enc == .vop1 or enc == .vop2 or enc == .vopc or enc == .vop3;
    if (!vop and (in.clamp or in.omod != 0)) return error.Syntax;
    if (!is_buf and (in.offen or in.idxen or in.tfe)) return error.Syntax;
    if (enc != .ds and in.gds) return error.Syntax;
    if (enc != .smem and enc != .flat and !is_buf and (in.glc or in.slc)) return error.Syntax;
    if (enc == .smem and in.slc) return error.Syntax;
    if (df.shape == .flat_atomic and p.rtn != in.glc) return error.NoForm;
    if (is_buf and df.shape != .buf_none) {
        if (p.data_n != df.d.dwords() + @intFromBool(in.tfe)) return error.NoForm;
        const want: u8 = if (in.offen and in.idxen) 2 else if (in.offen or in.idxen) 1 else 0;
        if (want != p.addr_n) return error.NoForm;
    }
}

/// Assemble a single line into `out`; returns the dwords.
pub fn assembleLine(line: []const u8, out: []u32) Error!usize {
    const in = try parse(line);
    return encode(&in, out);
}

// ── Registers an instruction reads and writes ───────────────────────────────

/// A run of `n` registers from `code` (a scalar code below 128, or a VGPR).
pub const RegRef = struct { code: u16, n: u8 };

pub const RegList = struct {
    reads: [10]RegRef = undefined,
    nr: u8 = 0,
    writes: [4]RegRef = undefined,
    nw: u8 = 0,

    fn add(list: []RegRef, n: *u8, code: u16, cnt: u8) void {
        if (code >= 128 and code < VGPR0) return; // constants
        list[n.*] = .{ .code = code, .n = @max(cnt, 1) };
        n.* += 1;
    }
    fn r(l: *RegList, code: u16, t: Ty) void {
        add(&l.reads, &l.nr, code, t.dwords());
    }
    fn rn(l: *RegList, code: u16, n: u8) void {
        add(&l.reads, &l.nr, code, n);
    }
    fn w(l: *RegList, code: u16, t: Ty) void {
        add(&l.writes, &l.nw, code, t.dwords());
    }
    fn wn(l: *RegList, code: u16, n: u8) void {
        add(&l.writes, &l.nw, code, n);
    }
    pub fn readSlice(l: *const RegList) []const RegRef {
        return l.reads[0..l.nr];
    }
    pub fn writeSlice(l: *const RegList) []const RegRef {
        return l.writes[0..l.nw];
    }
};

/// The registers `in` names, and the implicit ones that matter for
/// counting and hazards (VCC, EXEC, M0). SCC is not a register here.
pub fn regs(in: *const Instr) RegList {
    var l = RegList{};
    const df = in.d();
    const sh = df.shape;
    const name = df.name;
    switch (sh) {
        .sop2 => {
            l.r(in.src[0], df.s[0]);
            l.r(in.src[1], df.s[1]);
            l.w(in.dst, df.d);
        },
        .sop1 => {
            l.r(in.src[0], df.s[0]);
            if (std.mem.startsWith(u8, name, "s_bitset") or std.mem.startsWith(u8, name, "s_cmov")) l.r(in.dst, df.d);
            if (std.mem.endsWith(u8, name, "_saveexec_b64")) {
                l.rn(EXEC_LO, 2);
                l.wn(EXEC_LO, 2);
            }
            if (std.mem.startsWith(u8, name, "s_movrel")) l.rn(M0, 1);
            l.w(in.dst, df.d);
        },
        .sop1_dst => l.w(in.dst, df.d),
        .sop1_src => l.r(in.src[0], df.s[0]),
        .sopc => {
            l.r(in.src[0], df.s[0]);
            l.r(in.src[1], df.s[1]);
        },
        .sopk => {
            const writes = !std.mem.startsWith(u8, name, "s_cmpk");
            const reads = !std.mem.eql(u8, name, "s_movk_i32");
            if (reads) l.r(in.dst, .b32);
            if (writes) l.w(in.dst, .b32);
        },
        .sopk_getreg => l.w(in.dst, .b32),
        .sopk_setreg => l.r(in.dst, .b32),
        .sopk_setreg_imm, .sopp, .sopp_imm, .sopp_waitcnt, .smem_none, .vop_none, .ds_none, .buf_none => {},
        .sopp_branch => {
            if (std.mem.startsWith(u8, name, "s_cbranch_vcc")) l.rn(VCC_LO, 2);
            if (std.mem.startsWith(u8, name, "s_cbranch_exec")) l.rn(EXEC_LO, 2);
        },
        .smem_load, .smem_store => {
            l.r(in.src[0], df.s[0]);
            if (!in.soff_imm) l.r(in.src[1], .b32);
            if (sh == .smem_load) l.w(in.dst, df.d) else l.r(in.dst, df.d);
        },
        .smem_time => l.w(in.dst, df.d),
        .vop, .vop_sdst, .vop_madmk, .vop_madak => {
            for (0..3) |i| {
                if (df.s[i] != .none) l.r(in.src[i], df.s[i]);
            }
            if (std.mem.startsWith(u8, name, "v_mac_") or std.mem.eql(u8, name, "v_writelane_b32") or std.mem.eql(u8, name, "v_cvt_pkaccum_u8_f32")) l.r(in.dst, df.d);
            if (std.mem.startsWith(u8, name, "v_div_fmas")) l.rn(VCC_LO, 2);
            if (std.mem.startsWith(u8, name, "v_movrel")) l.rn(M0, 1);
            l.w(in.dst, df.d);
        },
        .vop_carry, .vop_carry_in, .vop_cndmask, .vop3b => {
            for (0..3) |i| {
                if (df.s[i] != .none) l.r(in.src[i], df.s[i]);
            }
            if (sh != .vop_cndmask) l.wn(in.sdst, 2);
            l.w(in.dst, df.d);
        },
        .vopc => {
            l.r(in.src[0], df.s[0]);
            l.r(in.src[1], df.s[1]);
            l.wn(in.sdst, 2);
            if (std.mem.startsWith(u8, name, "v_cmpx")) l.wn(EXEC_LO, 2);
        },
        .ds_addr_data, .ds_addr_data2, .ds_write2, .ds_read, .ds_read2, .ds_rtn, .ds_rtn2, .ds_rtn_write2, .ds_swizzle, .ds_vdst => {
            if (sh != .ds_vdst) l.r(in.src[0], .b32);
            if (df.s[1] != .none) l.r(in.src[1], df.s[1]);
            if (df.s[2] != .none) l.r(in.src[2], df.s[2]);
            l.rn(M0, 1);
            if (df.d != .none) l.w(in.dst, df.d);
        },
        .buf_load, .buf_store, .buf_atomic => {
            if (in.offen or in.idxen) l.rn(in.src[0], if (in.offen and in.idxen) 2 else 1);
            l.rn(in.src[1], 4);
            l.r(in.src[2], .b32);
            const n = df.d.dwords() + @intFromBool(in.tfe);
            switch (sh) {
                .buf_load => l.wn(in.dst, n),
                .buf_store => l.rn(in.dst, df.d.dwords()),
                else => {
                    l.rn(in.dst, df.d.dwords());
                    if (in.glc) l.wn(in.dst, n);
                },
            }
        },
        .flat_load => {
            l.r(in.src[0], .b64);
            l.w(in.dst, df.d);
        },
        .flat_store => {
            l.r(in.src[0], .b64);
            l.r(in.src[1], df.s[1]);
        },
        .flat_atomic => {
            l.r(in.src[0], .b64);
            l.r(in.src[1], df.s[1]);
            if (in.glc) l.w(in.dst, df.d);
        },
    }
    // an SDWA result that keeps the register's other bits reads it
    if (in.sdwa and sh != .vopc and in.dst_sel != 6 and in.dst_unused == 2) l.r(in.dst, .b32);
    return l;
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
        for (defs[i + 1 ..]) |*b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                std.debug.print("duplicate name {s}\n", .{a.name});
                return error.TestUnexpectedResult;
            }
            if (a.enc == b.enc and a.code == b.code) {
                std.debug.print("duplicate opcode {s} / {s}\n", .{ a.name, b.name });
                return error.TestUnexpectedResult;
            }
            if (a.e64 and b.e64 and vop3Code(a) == vop3Code(b)) {
                std.debug.print("duplicate VOP3 opcode {s} / {s}\n", .{ a.name, b.name });
                return error.TestUnexpectedResult;
            }
        }
        if (a.enc == .vop3) {
            for (&defs) |*b| {
                if (b.e64 and vop3Code(b) == a.code) {
                    std.debug.print("VOP3 opcode {x} taken by {s} and {s}\n", .{ a.code, a.name, b.name });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "LLVM's gfx803 vectors: decode, print, parse, encode" {
    const data = @embedFile("gcn3_vectors.txt");
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    var failures: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.Syntax;
        var words: [3]u32 = undefined;
        const nw = try parseWords(line[0..sp], &words);
        const text = line[sp + 1 ..];
        n += 1;
        var in: Instr = undefined;
        const used = decode(words[0..nw], &in) catch |e| {
            std.debug.print("decode {s}: {s}\n", .{ line, @errorName(e) });
            failures += 1;
            continue;
        };
        if (used != nw) {
            std.debug.print("decode {s}: {d} dwords\n", .{ line, used });
            failures += 1;
        }
        var buf: [200]u8 = undefined;
        const printed = format(&in, &buf) catch |e| {
            std.debug.print("format {s}: {s}\n", .{ line, @errorName(e) });
            failures += 1;
            continue;
        };
        if (!std.mem.eql(u8, printed, text)) {
            std.debug.print("print  {s}: got \"{s}\"\n", .{ line, printed });
            failures += 1;
        }
        const parsed = parse(text) catch |e| {
            std.debug.print("parse  \"{s}\": {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        var enc: [3]u32 = undefined;
        const ne = encode(&parsed, &enc) catch |e| {
            std.debug.print("encode \"{s}\": {s}\n", .{ text, @errorName(e) });
            failures += 1;
            continue;
        };
        if (ne != nw or !std.mem.eql(u32, enc[0..ne], words[0..nw])) {
            std.debug.print("encode \"{s}\": got {x:0>8}", .{ text, enc[0] });
            for (enc[1..ne]) |x| std.debug.print("_{x:0>8}", .{x});
            std.debug.print(" want {s}\n", .{line[0..sp]});
            failures += 1;
        }
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} vectors failed\n", .{ failures, n });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(n > 600);
}

test "random words: whatever decodes prints, parses and encodes back to itself" {
    var rng = std.Random.DefaultPrng.init(0x6c6c766d);
    const r = rng.random();
    // Prefixes that select each encoding, so most words are near-valid.
    const prefixes = [_]struct { u32, u5 }{
        .{ 0b10, 30 }, .{ 0b1011, 28 }, .{ 0b101111101, 23 }, .{ 0b101111110, 23 }, .{ 0b101111111, 23 },
        .{ 0b110000, 26 }, .{ 0b0, 31 }, .{ 0b0111111, 25 }, .{ 0b0111110, 25 }, .{ 0b110100, 26 },
        .{ 0b110110, 26 }, .{ 0b111000, 26 }, .{ 0b111010, 26 }, .{ 0b110111, 26 },
    };
    var decoded: usize = 0;
    for (0..200_000) |k| {
        const pf = prefixes[k % prefixes.len];
        var words = [3]u32{ r.int(u32), r.int(u32), r.int(u32) };
        const keep: u32 = (@as(u32, 1) << pf[1]) - 1;
        words[0] = (words[0] & keep) | (pf[0] << pf[1]);
        // sparse fields decode more often
        if (r.boolean()) words[1] &= 0x00ff_01ff;
        // SDWA: a VOP1, VOP2 or VOPC word with its dword (reserved bits
        // mostly clear)
        if (k % 5 == 0 and words[0] >> 31 == 0) {
            words[0] = (words[0] & ~@as(u32, 0x1ff)) | SDWA;
            words[1] = r.int(u32);
            if (k % 3 != 0) words[1] &= 0x3f3f_3fff;
        }
        var in: Instr = undefined;
        const n = decode(&words, &in) catch continue;
        decoded += 1;
        var buf: [200]u8 = undefined;
        const text = try format(&in, &buf);
        var out: [3]u32 = undefined;
        const m = encode(&in, &out) catch |e| {
            std.debug.print("encode(decode) {x:0>8} {s}: {s}\n", .{ words[0], text, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        if (m != n or !std.mem.eql(u32, out[0..m], words[0..n])) {
            std.debug.print("encode(decode) {x:0>8}_{x:0>8} {s}: got {x:0>8}_{x:0>8}\n", .{ words[0], words[1], text, out[0], out[1] });
            return error.TestUnexpectedResult;
        }
        const back = parse(text) catch |e| {
            std.debug.print("parse(print) {x:0>8}_{x:0>8} \"{s}\": {s}\n", .{ words[0], words[1], text, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        const m2 = encode(&back, &out) catch |e| {
            std.debug.print("encode(parse(print)) \"{s}\": {s}\n", .{ text, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        if (m2 != n or !std.mem.eql(u32, out[0..m2], words[0..n])) {
            std.debug.print("encode(parse(print)) {x:0>8}_{x:0>8} \"{s}\": got {x:0>8}_{x:0>8}\n", .{ words[0], words[1], text, out[0], out[1] });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(decoded > 20_000);
}
