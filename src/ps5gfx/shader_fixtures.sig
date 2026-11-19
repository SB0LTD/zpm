//! PS5 shaders (gfx10, LLVM's gfx1013) for the recompiler's tests, made by
//! tools/gen_ps5gfx_fixtures.py: written there as assembly, assembled by
//! LLVM's AMDGPU assembler (clang version 22.1.8 (https://github.com/llvm/llvm-project.git ca7933e47d3a3451d81e72ac174dcb5aa28b59d1)). Do not edit by hand.
//! Each instruction is the comment above its words.

/// Every scalar instruction the interpreter runs (a pixel shader: user data from s0). user: s0 0x12345678, s1 0x80000001, s2 0xfffffff0, s3 7, s[4:5] an address, s[8:11] a V#.
pub const scalar_ops = [_]u32{
    // s_getpc_b64 s[16:17]  ; the next instruction's address
    0xbe901f00,
    // s_mov_b32 s18, s0
    0xbe920300,
    // s_movk_i32 s19, 0x8000  ; sign-extended: 0xffff8000
    0xb0138000,
    // s_add_u32 s20, s1, s1  ; 2, carry: SCC 1
    0x80140101,
    // s_addc_u32 s21, 0, 0  ; the carry: 1
    0x82158080,
    // s_sub_u32 s22, 5, 7  ; 0xfffffffe, borrow: SCC 1
    0x80968785,
    // s_cselect_b32 s23, 1, 2  ; 1
    0x85178281,
    // s_add_i32 s24, s1, -1  ; 0x80000000, no overflow: SCC 0
    0x8118c101,
    // s_cselect_b32 s25, 1, 2  ; 2
    0x85198281,
    // s_sub_i32 s26, s1, 2  ; overflow: 0x7fffffff, SCC 1
    0x819a8201,
    // s_addc_u32 s27, s3, 0  ; 7 + 0 + 1 = 8
    0x821b8003,
    // s_mul_i32 s28, s3, -3  ; -21
    0x931cc303,
    // s_and_b32 s29, s0, 0xff00ff00  ; 0x12005600
    0x871dff00, 0xff00ff00,
    // s_or_b32 s30, s3, 0x100  ; 0x107
    0x881eff03, 0x00000100,
    // s_xor_b32 s31, s0, -1  ; 0xedcba987
    0x891fc100,
    // s_andn2_b32 s32, s0, 0xffff  ; 0x12340000
    0x8a20ff00, 0x0000ffff,
    // s_orn2_b32 s33, 0, s2  ; 0xf
    0x8b210280,
    // s_not_b32 s34, s3  ; 0xfffffff8
    0xbea20703,
    // s_lshl_b32 s35, s3, 29  ; 0xe0000000
    0x8f239d03,
    // s_lshr_b32 s36, s2, 28  ; 0xf
    0x90249c02,
    // s_ashr_i32 s37, s2, 2  ; 0xfffffffc
    0x91258202,
    // s_bfe_u32 s38, s0, 0x80008  ; 8 bits from bit 8: 0x56
    0x93a6ff00, 0x00080008,
    // s_bfe_i32 s39, s2, 0x40002  ; 4 bits from bit 2, signed: -4
    0x9427ff02, 0x00040002,
    // s_bfm_b32 s40, 4, 8  ; 0xf00
    0x92288884,
    // s_min_i32 s41, s1, s3  ; 0x80000001
    0x83290301,
    // s_min_u32 s42, s1, s3  ; 7
    0x83aa0301,
    // s_max_i32 s43, s1, s3  ; 7
    0x842b0301,
    // s_max_u32 s44, s1, s3  ; 0x80000001
    0x84ac0301,
    // s_lshl2_add_u32 s45, s3, 0x100  ; 28 + 256 = 0x11c
    0x97adff03, 0x00000100,
    // s_addk_i32 s45, 0x10  ; 0x12c
    0xb7ad0010,
    // s_mov_b64 s[46:47], s[0:1]
    0xbeae0400,
    // s_lshl_b64 s[48:49], s[2:3], 4  ; 0x7fffffff0 << 4
    0x8fb08402,
    // s_lshr_b64 s[50:51], s[2:3], 8  ; 0x7fffffff0 >> 8
    0x90b28802,
    // s_and_b64 s[52:53], s[0:1], s[2:3]
    0x87b40200,
    // s_or_b64 s[54:55], s[0:1], 1
    0x88b68100,
    // s_xor_b64 s[56:57], s[0:1], -1
    0x89b8c100,
    // s_not_b64 s[58:59], s[2:3]
    0xbeba0802,
    // s_cmp_eq_u32 s3, 7
    0xbf068703,
    // s_cselect_b32 s60, s3, 0  ; 7
    0x853c8003,
    // s_cmp_lt_i32 s1, 0
    0xbf048001,
    // s_cselect_b32 s61, 1, 0  ; 1
    0x853d8081,
    // s_cmp_gt_u32 s1, s0
    0xbf080001,
    // s_cselect_b32 s62, 1, 0  ; 1
    0x853e8081,
    // s_cmp_ge_i32 s1, s0
    0xbf030001,
    // s_cselect_b32 s63, 1, 0  ; 0
    0x853f8081,
    // s_cmpk_lt_i32 s19, 0x0
    0xb3930000,
    // s_cselect_b32 s64, 3, 4  ; 3
    0x85408483,
    // s_cmpk_eq_u32 s3, 0x8
    0xb4830008,
    // s_cselect_b32 s65, 3, 4  ; 4
    0x85418483,
    // s_cmp_lg_u64 s[0:1], s[46:47]
    0xbf132e00,
    // s_cselect_b64 s[66:67], s[0:1], s[2:3]  ; SCC 0: s[2:3]
    0x85c20200,
    // s_load_dwordx2 s[68:69], s[4:5], 0x10  ; memory words 4 and 5
    0xf4041102, 0xfa000010,
    // s_load_dword s70, s[4:5], s3  ; byte 7, rounded down: word 1
    0xf4001182, 0x06000000,
    // s_buffer_load_dwordx4 s[72:75], s[8:11], 0x10  ; through the V#: two words in range, two past it
    0xf4281204, 0xfa000010,
    // s_waitcnt lgkmcnt(0)
    0xbf8cc07f,
    // s_endpgm
    0xbf810000,
};

/// Wave64: a compare's mask in an SGPR pair, logic on it, a scalar pair beside it. (wave64)
pub const mask_pair = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5  ; a lane mask in s[4:5]
    0xd4040004, 0x0001e102,
    // s_and_b64 s[6:7], exec, s[4:5]  ; logic on masks: pred logic
    0x8786047e,
    // s_mov_b64 s[8:9], s[10:11]  ; scalars: the interpreter's
    0xbe88040a,
    // v_cndmask_b32_e64 v3, 0, 1.0, s[6:7]  ; the mask selects
    0xd5010003, 0x0019e480,
    // v_mov_b32_e32 v4, s8  ; the scalar read by a lane: a slot
    0x7e080208,
    // s_endpgm
    0xbf810000,
};

/// Wave64: a mask and a scalar in one logic instruction (refused). (wave64)
pub const mask_mixed = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    0xd4040004, 0x0001e102,
    // s_and_b64 s[6:7], s[4:5], s[10:11]
    0x87860a04,
    // s_endpgm
    0xbf810000,
};

/// Wave64: a mask read as a number (refused). (wave64)
pub const mask_as_scalar = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    0xd4040004, 0x0001e102,
    // s_add_u32 s6, s4, 1
    0x80068104,
    // s_endpgm
    0xbf810000,
};

/// A uniform branch (refused: straight-line code only).
pub const branch = [_]u32{
    // s_cmp_eq_u32 s0, 0
    0xbf068000,
    // s_cbranch_scc1 1
    0xbf850001,
    // v_mov_b32_e32 v0, 0
    0x7e000280,
    // s_endpgm
    0xbf810000,
};

/// A write to EXEC (refused).
pub const exec_write = [_]u32{
    // s_mov_b32 exec_lo, s0
    0xbefe0300,
    // s_endpgm
    0xbf810000,
};

/// An instruction this cut does not translate (refused).
pub const unknown = [_]u32{
    // v_sin_f32_e32 v0, v1
    0x7e006b01,
    // s_endpgm
    0xbf810000,
};

/// A scalar read by lane code, redefined, read again: two slots.
pub const redefine = [_]u32{
    // v_mul_f32_e32 v0, s0, v1  ; slot 0: s0 as the user gave it
    0x10000200,
    // v_mul_f32_e32 v2, s0, v3  ; the same definition: slot 0 again
    0x10040600,
    // s_mov_b32 s0, 2.0
    0xbe8003f4,
    // v_mul_f32_e32 v4, s0, v5  ; a new definition: slot 1
    0x10080a00,
    // s_endpgm
    0xbf810000,
};

/// The vertex side of the draw tests (32 lanes). User data (s8 on): s[8:9] the vertex buffer table (a V# each), s[10:11] the attribute word table, s[12:15] the constant buffer's V# (a column-major 4x4 matrix). Attribute 0 is the position (xyz), 1 the colour (xyzw), 2 a scale for the colour (x); each one's word gives its V#, its byte offset and whether the vertex or the instance index fetches it. The position's and the scale's offsets are added to their V#'s base (as compilers do), the colour's is passed as soffset.
pub const vs_fetch = [_]u32{
    // s_load_dwordx4 s[16:19], s[10:11], 0x0  ; the attribute words of semantics 0..3
    0xf4080405, 0xfa000000,
    // s_buffer_load_dwordx16 s[32:47], s[12:15], 0x0  ; the matrix
    0xf4300806, 0xfa000000,
    // s_waitcnt lgkmcnt(0)
    0xbf8cc07f,
    // s_and_b32 s20, s16, 31  ; the position's vertex buffer slot
    0x87149f10,
    // s_lshl_b32 s20, s20, 4  ; its V#'s offset in the table
    0x8f148414,
    // s_load_dwordx4 s[24:27], s[8:9], s20  ; the position's V#
    0xf4080604, 0x28000000,
    // s_bfe_u32 s21, s16, 0xc000e  ; its byte offset (bits 14-25)
    0x9395ff10, 0x000c000e,
    // s_bfe_u32 s22, s16, 0x1001a  ; its fetch index (bit 26)
    0x9396ff10, 0x0001001a,
    // s_and_b32 s48, s17, 31  ; the colour's
    0x87309f11,
    // s_lshl_b32 s48, s48, 4
    0x8f308430,
    // s_load_dwordx4 s[28:31], s[8:9], s48
    0xf4080704, 0x60000000,
    // s_bfe_u32 s49, s17, 0xc000e
    0x93b1ff11, 0x000c000e,
    // s_bfe_u32 s50, s17, 0x1001a
    0x93b2ff11, 0x0001001a,
    // s_and_b32 s51, s18, 31  ; the scale's
    0x87339f12,
    // s_lshl_b32 s51, s51, 4
    0x8f338433,
    // s_load_dwordx4 s[52:55], s[8:9], s51
    0xf4080d04, 0x66000000,
    // s_bfe_u32 s56, s18, 0xc000e
    0x93b8ff12, 0x000c000e,
    // s_bfe_u32 s57, s18, 0x1001a
    0x93b9ff12, 0x0001001a,
    // s_waitcnt lgkmcnt(0)
    0xbf8cc07f,
    // s_add_u32 s24, s24, s21  ; the position's offset into its V#'s base
    0x80181518,
    // s_addc_u32 s25, s25, 0
    0x82198019,
    // s_add_u32 s52, s52, s56  ; the scale's
    0x80343834,
    // s_addc_u32 s53, s53, 0
    0x82358035,
    // v_cmp_ne_u32_e64 s58, 0, s22  ; fetched by the instance index?
    0xd4c5003a, 0x00002c80,
    // v_cndmask_b32_e64 v9, v5, v8, s58  ; v5 the vertex index, v8 the instance index
    0xd5010009, 0x00ea1105,
    // v_cmp_ne_u32_e64 s59, 0, s50
    0xd4c5003b, 0x00006480,
    // v_cndmask_b32_e64 v10, v5, v8, s59
    0xd501000a, 0x00ee1105,
    // v_cmp_ne_u32_e64 s60, 0, s57
    0xd4c5003c, 0x00007280,
    // v_cndmask_b32_e64 v19, v5, v8, s60
    0xd5010013, 0x00f21105,
    // buffer_load_format_xyz v[11:13], v9, s[24:27], 0 idxen
    0xe0082000, 0x80060b09,
    // buffer_load_format_xyzw v[14:17], v10, s[28:31], s49 idxen
    0xe00c2000, 0x31070e0a,
    // buffer_load_format_x v18, v19, s[52:55], 0 idxen
    0xe0002000, 0x800d1213,
    // s_waitcnt vmcnt(0)
    0xbf8c3f70,
    // v_mul_f32_e32 v14, v14, v18  ; the colour scaled (not its alpha)
    0x101c250e,
    // v_mul_f32_e32 v15, v15, v18
    0x101e250f,
    // v_mul_f32_e32 v16, v16, v18
    0x10202510,
    // v_mul_f32_e32 v0, s32, v11  ; x' = m0 x + m4 y + m8 z + m12
    0x10001620,
    // v_fmac_f32_e32 v0, s36, v12
    0x56001824,
    // v_fmac_f32_e32 v0, s40, v13
    0x56001a28,
    // v_add_f32_e32 v0, s44, v0
    0x0600002c,
    // v_mul_f32_e32 v1, s33, v11  ; y'
    0x10021621,
    // v_fmac_f32_e32 v1, s37, v12
    0x56021825,
    // v_fmac_f32_e32 v1, s41, v13
    0x56021a29,
    // v_add_f32_e32 v1, s45, v1
    0x0602022d,
    // v_mul_f32_e32 v2, s34, v11  ; z'
    0x10041622,
    // v_fmac_f32_e32 v2, s38, v12
    0x56041826,
    // v_fmac_f32_e32 v2, s42, v13
    0x56041a2a,
    // v_add_f32_e32 v2, s46, v2
    0x0604042e,
    // v_mul_f32_e32 v3, s35, v11  ; w'
    0x10061623,
    // v_fmac_f32_e32 v3, s39, v12
    0x56061827,
    // v_fmac_f32_e32 v3, s43, v13
    0x56061a2b,
    // v_add_f32_e32 v3, s47, v3
    0x0606062f,
    // s_mov_b32 m0, s3  ; NGG's allocation request (counts in m0)
    0xbefc0303,
    // s_sendmsg sendmsg(MSG_GS_ALLOC_REQ)
    0xbf900009,
    // exp prim v4, off, off, off done  ; NGG's primitive export (not translated)
    0xf8000941, 0x00000004,
    // exp pos0 v0, v1, v2, v3 done
    0xf80008cf, 0x03020100,
    // exp param0 v14, v15, v16, v17  ; the colour, smooth
    0xf800020f, 0x11100f0e,
    // exp param1 v14, v15, v16, v17  ; the colour again, for a flat input
    0xf800021f, 0x11100f0e,
    // s_endpgm
    0xbf810000,
};

/// A pixel shader: input 0 interpolated, the colour out (PS_INPUT_ADDR/ENA 0x2: v0, v1 the perspective I and J; no user data, the primitive mask in s0).
pub const ps_interp = [_]u32{
    // s_mov_b32 m0, s0
    0xbefc0300,
    // v_interp_p1_f32_e32 v2, v0, attr0.x
    0xc8080000,
    // v_interp_p2_f32_e32 v2, v1, attr0.x
    0xc8090001,
    // v_interp_p1_f32_e32 v3, v0, attr0.y
    0xc80c0100,
    // v_interp_p2_f32_e32 v3, v1, attr0.y
    0xc80d0101,
    // v_interp_p1_f32_e32 v4, v0, attr0.z
    0xc8100200,
    // v_interp_p2_f32_e32 v4, v1, attr0.z
    0xc8110201,
    // v_interp_p1_f32_e32 v5, v0, attr0.w
    0xc8140300,
    // v_interp_p2_f32_e32 v5, v1, attr0.w
    0xc8150301,
    // exp mrt0 v2, v3, v4, v5 done vm
    0xf800180f, 0x05040302,
    // s_endpgm
    0xbf810000,
};

/// A pixel shader (PS_INPUT_ADDR/ENA 0x302: v0, v1 I and J, v2 the pixel's x, v3 its y; user data s[0:3] a tint, the primitive mask in s4): input 0 smooth times the tint, input 1 flat, input 2 a default, chosen by the pixel's x; out as packed halves.
pub const ps_tint = [_]u32{
    // s_mov_b32 m0, s4
    0xbefc0304,
    // v_interp_p1_f32_e32 v4, v0, attr0.x
    0xc8100000,
    // v_interp_p2_f32_e32 v4, v1, attr0.x
    0xc8110001,
    // v_interp_p1_f32_e32 v5, v0, attr0.y
    0xc8140100,
    // v_interp_p2_f32_e32 v5, v1, attr0.y
    0xc8150101,
    // v_interp_mov_f32_e32 v6, p0, attr1.x  ; flat: the provoking vertex's
    0xc81a0402,
    // v_interp_mov_f32_e32 v7, p0, attr2.w  ; no slot: the default's w
    0xc81e0b02,
    // v_mul_f32_e32 v4, s0, v4  ; the tint, a scalar in lane code
    0x10080800,
    // v_mul_f32_e32 v5, s1, v5
    0x100a0a01,
    // v_cmp_lt_f32_e32 vcc_lo, 0x41800000, v2  ; 16 < x
    0x7c0204ff, 0x41800000,
    // s_and_b32 vcc_lo, exec_lo, vcc_lo
    0x876a6a7e,
    // v_cndmask_b32_e32 v8, v6, v7, vcc_lo  ; right: the default; left: the flat value
    0x02100f06,
    // v_cvt_pkrtz_f16_f32_e32 v9, v4, v5
    0x5e120b04,
    // v_cvt_pkrtz_f16_f32_e64 v10, v8, s3  ; alpha: the tint's w
    0xd52f000a, 0x00000708,
    // exp mrt0 v9, v9, v10, v10 done compr vm
    0xf8001c0f, 0x00000a09,
    // s_endpgm
    0xbf810000,
};

/// The lane instructions, each result worked out by hand, out as params 0..15 (v20..v83). User data: s8 2.5, s9 -3, s10 0x12345678, s11 4.0.
pub const vs_alu = [_]u32{
    // v_mov_b32_e32 v84, 2.0
    0x7ea802f4,
    // v_mov_b32_e32 v20, s8  ; 2.5
    0x7e280208,
    // v_add_f32_e64 v21, s8, 1.0  ; 3.5
    0xd5030015, 0x0001e408,
    // v_sub_f32_e64 v22, 1.0, s8  ; -1.5
    0xd5040016, 0x000010f2,
    // v_subrev_f32_e64 v23, 1.0, s8  ; 1.5
    0xd5050017, 0x000010f2,
    // v_mul_f32_e64 v24, s8, s11  ; 10
    0xd5080018, 0x00001608,
    // v_mad_f32 v25, s8, s11, -1.0  ; 9
    0xd5410019, 0x03cc1608,
    // v_fma_f32 v26, -s8, s11, 0.5  ; -9.5
    0xd54b001a, 0x23c01608,
    // v_mov_b32_e32 v27, 1.0
    0x7e3602f2,
    // v_mac_f32_e32 v27, s8, v84  ; 1 + 5 = 6
    0x3e36a808,
    // v_min_f32_e64 v28, s8, -|s11|  ; -4
    0xd50f021c, 0x40001608,
    // v_max_f32_e64 v29, s8, s11 clamp  ; 4, clamped: 1
    0xd510801d, 0x00001608,
    // v_rcp_f32_e64 v30, s11  ; 0.25
    0xd5aa001e, 0x0000000b,
    // v_rsq_f32_e64 v31, s11  ; 0.5
    0xd5ae001f, 0x0000000b,
    // v_sqrt_f32_e32 v32, 0x40100000  ; sqrt(2.25) = 1.5
    0x7e4066ff, 0x40100000,
    // v_floor_f32_e64 v33, -s8  ; -3
    0xd5a40021, 0x20000008,
    // v_ceil_f32_e64 v34, s8  ; 3
    0xd5a20022, 0x00000008,
    // v_trunc_f32_e64 v35, -s8  ; -2
    0xd5a10023, 0x20000008,
    // v_rndne_f32_e64 v36, s8  ; 2 (to even)
    0xd5a30024, 0x00000008,
    // v_fract_f32_e32 v37, 0xbfa00000  ; fract(-1.25) = 0.75
    0x7e4a40ff, 0xbfa00000,
    // v_cvt_f32_i32_e64 v38, s9  ; -3.0
    0xd5850026, 0x00000009,
    // v_cvt_f32_u32_e32 v39, 0x100  ; 256.0
    0x7e4e0cff, 0x00000100,
    // v_mov_b32_e32 v40, 0.15915494  ; 1/(2 pi), inline
    0x7e5002f8,
    // v_cvt_i32_f32_e32 v41, 0xc02ccccd  ; -2.7 toward zero: -2
    0x7e5210ff, 0xc02ccccd,
    // v_cvt_u32_f32_e32 v42, -1.0  ; saturated: 0
    0x7e540ef3,
    // v_cvt_pkrtz_f16_f32_e64 v43, 1.0, -2.0  ; 0xc0003c00
    0xd52f002b, 0x0001eaf2,
    // v_mul_f32_e64 v44, s8, 2.0 mul:2  ; 10
    0xd508002c, 0x0801e808,
    // v_mul_f32_e64 v45, s8, 1.0 div:2  ; 1.25
    0xd508002d, 0x1801e408,
    // v_sub_f32_e64 v46, s8, s11 clamp  ; -1.5, clamped: 0
    0xd504802e, 0x00001608,
    // v_cvt_f32_ubyte1_e64 v47, s10  ; 0x56: 86.0
    0xd592002f, 0x0000000a,
    // v_and_b32_e64 v48, s10, 0xff00ff00  ; 0x12005600
    0xd51b0030, 0x0001fe0a, 0xff00ff00,
    // v_or_b32_e64 v49, s10, 15  ; 0x1234567f
    0xd51c0031, 0x00011e0a,
    // v_xor_b32_e64 v50, s10, -1  ; 0xedcba987
    0xd51d0032, 0x0001820a,
    // v_not_b32_e64 v51, s9  ; 2
    0xd5b70033, 0x00000009,
    // v_lshlrev_b32_e64 v52, 4, s10  ; 0x23456780
    0xd51a0034, 0x00001484,
    // v_lshrrev_b32_e64 v53, 4, s10  ; 0x01234567
    0xd5160035, 0x00001484,
    // v_ashrrev_i32_e64 v54, 1, s9  ; -2
    0xd5180036, 0x00001281,
    // v_add_nc_u32_e64 v55, s9, 10  ; 7
    0xd5250037, 0x00011409,
    // v_sub_nc_u32_e64 v56, s9, 10  ; -13
    0xd5260038, 0x00011409,
    // v_subrev_nc_u32_e64 v57, s9, 10  ; 13
    0xd5270039, 0x00011409,
    // v_mul_lo_u32 v58, s9, s10  ; 0xc962fc98
    0xd569003a, 0x00001409,
    // v_mul_hi_u32 v59, s10, 0x10000  ; 0x1234
    0xd56a003b, 0x0001fe0a, 0x00010000,
    // v_bfe_u32 v60, s10, 8, 12  ; 0x456
    0xd548003c, 0x0231100a,
    // v_bfe_i32 v61, s10, 0, 4  ; 8 as 4 signed bits: -8
    0xd549003d, 0x0211000a,
    // v_bfm_b32 v62, 4, 8  ; 0xf00
    0xd763003e, 0x00011084,
    // v_bfi_b32 v63, 0xffff, s10, 0  ; 0x5678
    0xd54a003f, 0x020014ff, 0x0000ffff,
    // v_lshl_add_u32 v64, s9, 2, 20  ; -12 + 20 = 8
    0xd7460040, 0x02510409,
    // v_lshl_or_b32 v65, 1, 4, 3  ; 0x13
    0xd76f0041, 0x020d0881,
    // v_and_or_b32 v66, s10, 0xff, 1  ; 0x79
    0xd7710042, 0x0205fe0a, 0x000000ff,
    // v_add3_u32 v67, s9, 10, 5  ; 12
    0xd76d0043, 0x02151409,
    // v_min_i32_e64 v68, s9, 1  ; -3
    0xd5110044, 0x00010209,
    // v_max_i32_e64 v69, s9, 1  ; 1
    0xd5120045, 0x00010209,
    // v_min_u32_e64 v70, s9, 1  ; 1
    0xd5130046, 0x00010209,
    // v_max_u32_e64 v71, s9, 1  ; 0xfffffffd
    0xd5140047, 0x00010209,
    // v_mul_u32_u24_e64 v72, s10, 2  ; 0x68acf0
    0xd50b0048, 0x0001040a,
    // v_mul_i32_i24_e64 v73, s9, 5  ; -15
    0xd5090049, 0x00010a09,
    // v_mad_u32_u24 v74, s10, 2, 1  ; 0x68acf1
    0xd543004a, 0x0205040a,
    // v_add_co_u32 v75, vcc_lo, s10, 0xf0000000  ; 0x02345678, carry out
    0xd70f6a4b, 0x0001fe0a, 0xf0000000,
    // v_cndmask_b32_e64 v76, 0, 1, vcc_lo  ; the carry: 1
    0xd501004c, 0x01a90280,
    // v_cmp_lt_i32_e64 s50, s9, 0
    0xd4810032, 0x00010009,
    // v_cndmask_b32_e64 v77, 0, 1, s50  ; -3 < 0: 1
    0xd501004d, 0x00c90280,
    // v_cmp_lt_u32_e64 s51, s9, 0
    0xd4c10033, 0x00010009,
    // v_cndmask_b32_e64 v78, 0, 1, s51  ; 0xfffffffd < 0: 0
    0xd501004e, 0x00cd0280,
    // v_cmp_nge_f32_e64 s52, s8, s11
    0xd4090034, 0x00001608,
    // v_cndmask_b32_e64 v79, 0, 1, s52  ; not 2.5 >= 4: 1
    0xd501004f, 0x00d10280,
    // s_andn2_b32 s53, s52, s51
    0x8a353334,
    // v_cndmask_b32_e64 v80, 0, 1, s53  ; 1 and not 0: 1
    0xd5010050, 0x00d50280,
    // v_cmp_u_f32_e64 s54, s8, s11
    0xd4080036, 0x00001608,
    // v_cndmask_b32_e64 v81, 0, 1, s54  ; unordered: 0
    0xd5010051, 0x00d90280,
    // v_mov_b32_e32 v82, v5  ; the vertex index
    0x7ea40305,
    // v_mov_b32_e32 v83, v8  ; the instance index
    0x7ea60308,
    // exp param0 v20, v21, v22, v23
    0xf800020f, 0x17161514,
    // exp param1 v24, v25, v26, v27
    0xf800021f, 0x1b1a1918,
    // exp param2 v28, v29, v30, v31
    0xf800022f, 0x1f1e1d1c,
    // exp param3 v32, v33, v34, v35
    0xf800023f, 0x23222120,
    // exp param4 v36, v37, v38, v39
    0xf800024f, 0x27262524,
    // exp param5 v40, v41, v42, v43
    0xf800025f, 0x2b2a2928,
    // exp param6 v44, v45, v46, v47
    0xf800026f, 0x2f2e2d2c,
    // exp param7 v48, v49, v50, v51
    0xf800027f, 0x33323130,
    // exp param8 v52, v53, v54, v55
    0xf800028f, 0x37363534,
    // exp param9 v56, v57, v58, v59
    0xf800029f, 0x3b3a3938,
    // exp param10 v60, v61, v62, v63
    0xf80002af, 0x3f3e3d3c,
    // exp param11 v64, v65, v66, v67
    0xf80002bf, 0x43424140,
    // exp param12 v68, v69, v70, v71
    0xf80002cf, 0x47464544,
    // exp param13 v72, v73, v74, v75
    0xf80002df, 0x4b4a4948,
    // exp param14 v76, v77, v78, v79
    0xf80002ef, 0x4f4e4d4c,
    // exp param15 v80, v81, v82, v83
    0xf80002ff, 0x53525150,
    // s_endpgm
    0xbf810000,
};

/// A pixel shader handed the pixel's position, its facing and its fixed-point position (PS_INPUT_ADDR/ENA 0x9f00: v0..v3 x, y, z, w, v4 the facing, v5 x | y << 16).
pub const ps_builtins = [_]u32{
    // exp mrt0 v0, v1, v2, v3
    0xf800000f, 0x03020100,
    // exp mrt1 v4, v5, v5, v5 done vm
    0xf800181f, 0x05050504,
    // s_endpgm
    0xbf810000,
};

/// 32 lanes: a mask in s5 copied as a 64-bit pair (refused).
pub const mask_a = [_]u32{
    // v_cmp_gt_f32_e64 s5, v2, 0.5
    0xd4040005, 0x0001e102,
    // s_mov_b64 s[6:7], s[4:5]
    0xbe860404,
    // v_mov_b32_e32 v3, s7
    0x7e060207,
    // s_endpgm
    0xbf810000,
};

/// 32 lanes: a pair holding a mask in s5 shifted as a number (refused).
pub const mask_b = [_]u32{
    // v_cmp_gt_f32_e64 s5, v2, 0.5
    0xd4040005, 0x0001e102,
    // s_lshr_b64 s[6:7], s[4:5], 1
    0x90868104,
    // v_mov_b32_e32 v3, s6
    0x7e060206,
    // s_endpgm
    0xbf810000,
};

/// 64 lanes: one half of a mask pair overwritten, the pair then used as a mask (refused). (wave64)
pub const mask_c = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    0xd4040004, 0x0001e102,
    // s_mov_b32 s5, 0
    0xbe850380,
    // v_cndmask_b32_e64 v3, 0, 1.0, s[4:5]
    0xd5010003, 0x0011e480,
    // s_endpgm
    0xbf810000,
};

/// 32 lanes: a mask in s2 moved as a pair, s1 then used as a mask (refused).
pub const mask_d = [_]u32{
    // v_cmp_gt_f32_e64 s2, v2, 0.5
    0xd4040002, 0x0001e102,
    // s_mov_b64 s[0:1], s[2:3]
    0xbe800402,
    // v_cndmask_b32_e64 v3, 0, 1.0, s1
    0xd5010003, 0x0005e480,
    // s_endpgm
    0xbf810000,
};

/// A compare into s5: a 32-lane mask, refused as a 64-lane one (an odd register).
pub const mask_odd = [_]u32{
    // v_cmp_gt_f32_e64 s5, v2, 0.5
    0xd4040005, 0x0001e102,
    // s_endpgm
    0xbf810000,
};

/// 64 lanes: 32-bit logic on half of a mask pair (refused). (wave64)
pub const mask_b32_on64 = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    0xd4040004, 0x0001e102,
    // s_and_b32 s6, s4, exec_lo
    0x87067e04,
    // s_endpgm
    0xbf810000,
};

/// 32 lanes: the register after a mask is a register of its own.
pub const mask_next32 = [_]u32{
    // v_cmp_gt_f32_e64 s4, v2, 0.5
    0xd4040004, 0x0001e102,
    // s_mov_b32 s5, 7
    0xbe850387,
    // v_mov_b32_e32 v1, s5
    0x7e020205,
    // v_cndmask_b32_e64 v3, 0, 1.0, s4
    0xd5010003, 0x0011e480,
    // s_endpgm
    0xbf810000,
};

/// 64 lanes: a uniform mask made by s_cselect_b64 from a scalar compare, alone and with a lane mask (PS_INPUT_ADDR/ENA 0x100: v0 the pixel's x; user data s0). (wave64)
pub const umask64 = [_]u32{
    // v_cmp_gt_f32_e64 s[6:7], v0, 0.5
    0xd4040006, 0x0001e100,
    // s_cmp_eq_u32 s0, 5
    0xbf068500,
    // s_cselect_b64 s[4:5], -1, 0
    0x858480c1,
    // v_cndmask_b32_e64 v1, 0, 1.0, s[4:5]
    0xd5010001, 0x0011e480,
    // s_and_b64 s[8:9], s[4:5], s[6:7]
    0x87880604,
    // v_cndmask_b32_e64 v2, 0, 1.0, s[8:9]
    0xd5010002, 0x0021e480,
    // exp mrt0 v1, v2, v1, v2 done vm
    0xf800180f, 0x02010201,
    // s_endpgm
    0xbf810000,
};

/// 64 lanes: s_cselect on SCC set by mask logic (refused). (wave64)
pub const scc_lane_cselect = [_]u32{
    // v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    0xd4040004, 0x0001e102,
    // s_and_b64 s[6:7], exec, s[4:5]
    0x8786047e,
    // s_cselect_b64 s[8:9], -1, 0
    0x858880c1,
    // s_endpgm
    0xbf810000,
};

/// 32 lanes: compares with NaN and infinity (ordered against unordered), unsigned and signed compares, logic on their masks, and uniform masks from s_cselect_b32; each mask out as 0 or 1 (v20..v46, then 7). User data: s8 NaN, s9 +inf, s10 1.0, s11 0xfffffffe, s12 5.
pub const vs_cmp = [_]u32{
    // v_cmp_lt_f32_e64 s20, s8, s10  ; NaN < 1: 0
    0xd4010014, 0x00001408,
    // v_cmp_nge_f32_e64 s21, s8, s10  ; not NaN >= 1: 1
    0xd4090015, 0x00001408,
    // v_cmp_neq_f32_e64 s22, s8, s8  ; 1
    0xd40d0016, 0x00001008,
    // v_cmp_eq_f32_e64 s23, s8, s8  ; 0
    0xd4020017, 0x00001008,
    // v_cmp_lg_f32_e64 s24, s8, s10  ; ordered and not equal: 0
    0xd4050018, 0x00001408,
    // v_cmp_nlg_f32_e64 s25, s8, s10  ; 1
    0xd40a0019, 0x00001408,
    // v_cmp_o_f32_e64 s26, s8, s10  ; 0
    0xd407001a, 0x00001408,
    // v_cmp_u_f32_e64 s27, s8, s10  ; 1
    0xd408001b, 0x00001408,
    // v_cmp_gt_f32_e64 s28, s9, s10  ; inf > 1: 1
    0xd404001c, 0x00001409,
    // v_cmp_ngt_f32_e64 s29, s9, s10  ; 0
    0xd40b001d, 0x00001409,
    // v_cmp_le_f32_e64 s30, s9, s9  ; 1
    0xd403001e, 0x00001209,
    // v_cmp_lg_f32_e64 s31, s9, s10  ; 1
    0xd405001f, 0x00001409,
    // v_cmp_nle_f32_e64 s32, s10, s9  ; 0
    0xd40c0020, 0x0000120a,
    // v_cmp_nlt_f32_e64 s33, s9, s10  ; 1
    0xd40e0021, 0x00001409,
    // v_cmp_ge_f32_e64 s34, s8, s8  ; 0
    0xd4060022, 0x00001008,
    // v_cmp_gt_u32_e64 s35, s11, 1  ; 0xfffffffe > 1 unsigned: 1
    0xd4c40023, 0x0001020b,
    // v_cmp_lt_i32_e64 s36, s11, 1  ; -2 < 1 signed: 1
    0xd4810024, 0x0001020b,
    // v_cmp_ge_u32_e64 s37, s11, s11  ; 1
    0xd4c60025, 0x0000160b,
    // v_cmp_lt_u32_e64 s38, s11, 1  ; 0
    0xd4c10026, 0x0001020b,
    // v_cmp_ne_u32_e64 s39, s11, -2  ; 0
    0xd4c50027, 0x0001840b,
    // s_xor_b32 s40, s35, s36  ; 0
    0x89282423,
    // s_orn2_b32 s41, s38, s37  ; 0
    0x8b292526,
    // s_or_b32 s42, s38, s35  ; 1
    0x882a2326,
    // s_not_b32 s43, s38  ; 1
    0xbeab0726,
    // s_cmp_eq_u32 s12, 5
    0xbf06850c,
    // s_cselect_b32 s44, -1, 0  ; uniform: every lane
    0x852c80c1,
    // s_cmp_eq_u32 s12, 6
    0xbf06860c,
    // s_cselect_b32 s45, -1, 0  ; uniform: none
    0x852d80c1,
    // s_and_b32 s46, s44, s35  ; uniform with a lane mask: 1
    0x872e232c,
    // v_cndmask_b32_e64 v20, 0, 1, s20
    0xd5010014, 0x00510280,
    // v_cndmask_b32_e64 v21, 0, 1, s21
    0xd5010015, 0x00550280,
    // v_cndmask_b32_e64 v22, 0, 1, s22
    0xd5010016, 0x00590280,
    // v_cndmask_b32_e64 v23, 0, 1, s23
    0xd5010017, 0x005d0280,
    // v_cndmask_b32_e64 v24, 0, 1, s24
    0xd5010018, 0x00610280,
    // v_cndmask_b32_e64 v25, 0, 1, s25
    0xd5010019, 0x00650280,
    // v_cndmask_b32_e64 v26, 0, 1, s26
    0xd501001a, 0x00690280,
    // v_cndmask_b32_e64 v27, 0, 1, s27
    0xd501001b, 0x006d0280,
    // v_cndmask_b32_e64 v28, 0, 1, s28
    0xd501001c, 0x00710280,
    // v_cndmask_b32_e64 v29, 0, 1, s29
    0xd501001d, 0x00750280,
    // v_cndmask_b32_e64 v30, 0, 1, s30
    0xd501001e, 0x00790280,
    // v_cndmask_b32_e64 v31, 0, 1, s31
    0xd501001f, 0x007d0280,
    // v_cndmask_b32_e64 v32, 0, 1, s32
    0xd5010020, 0x00810280,
    // v_cndmask_b32_e64 v33, 0, 1, s33
    0xd5010021, 0x00850280,
    // v_cndmask_b32_e64 v34, 0, 1, s34
    0xd5010022, 0x00890280,
    // v_cndmask_b32_e64 v35, 0, 1, s35
    0xd5010023, 0x008d0280,
    // v_cndmask_b32_e64 v36, 0, 1, s36
    0xd5010024, 0x00910280,
    // v_cndmask_b32_e64 v37, 0, 1, s37
    0xd5010025, 0x00950280,
    // v_cndmask_b32_e64 v38, 0, 1, s38
    0xd5010026, 0x00990280,
    // v_cndmask_b32_e64 v39, 0, 1, s39
    0xd5010027, 0x009d0280,
    // v_cndmask_b32_e64 v40, 0, 1, s40
    0xd5010028, 0x00a10280,
    // v_cndmask_b32_e64 v41, 0, 1, s41
    0xd5010029, 0x00a50280,
    // v_cndmask_b32_e64 v42, 0, 1, s42
    0xd501002a, 0x00a90280,
    // v_cndmask_b32_e64 v43, 0, 1, s43
    0xd501002b, 0x00ad0280,
    // v_cndmask_b32_e64 v44, 0, 1, s44
    0xd501002c, 0x00b10280,
    // v_cndmask_b32_e64 v45, 0, 1, s45
    0xd501002d, 0x00b50280,
    // v_cndmask_b32_e64 v46, 0, 1, s46
    0xd501002e, 0x00b90280,
    // v_mov_b32_e32 v47, 7
    0x7e5e0287,
    // exp param0 v20, v21, v22, v23
    0xf800020f, 0x17161514,
    // exp param1 v24, v25, v26, v27
    0xf800021f, 0x1b1a1918,
    // exp param2 v28, v29, v30, v31
    0xf800022f, 0x1f1e1d1c,
    // exp param3 v32, v33, v34, v35
    0xf800023f, 0x23222120,
    // exp param4 v36, v37, v38, v39
    0xf800024f, 0x27262524,
    // exp param5 v40, v41, v42, v43
    0xf800025f, 0x2b2a2928,
    // exp param6 v44, v45, v46, v47
    0xf800026f, 0x2f2e2d2c,
    // s_endpgm
    0xbf810000,
};

/// Lane buffer loads through V#s in user data (s8 on, 32 lanes; v5 the vertex index, 1 in the test): A s[8:11] raw, no stride, 20 bytes; B s[12:15] 4-byte records, 2 of them; C s[16:19] 16_16 snorm; D s[20:23] 16_16_16_16 float with dst_sel X, Y, one, W; E s[24:27] no records; F s[28:31] read as 8_8 unorm by tbuffer's own format; H s[32:35] 16 unorm. Out: v20..v55.
pub const vs_loads = [_]u32{
    // v_mov_b32_e32 v30, 8
    0x7e3c0288,
    // buffer_load_dwordx4 v[20:23], v30, s[8:11], 0 offen  ; bytes 8..23 of 20: three dwords in, one past
    0xe0381000, 0x8002141e,
    // buffer_load_dword v24, off, s[8:11], 0 offset:16  ; the last dword
    0xe0300010, 0x80021800,
    // buffer_load_dword v25, off, s[8:11], 0 offset:20  ; past the bytes: 0
    0xe0300014, 0x80021900,
    // buffer_load_ubyte v26, off, s[8:11], 0 offset:1
    0xe0200001, 0x80021a00,
    // buffer_load_sbyte v27, off, s[8:11], 0 offset:1
    0xe0240001, 0x80021b00,
    // buffer_load_ushort v28, off, s[8:11], 0 offset:2
    0xe0280002, 0x80021c00,
    // buffer_load_sshort v29, off, s[8:11], 0 offset:2
    0xe02c0002, 0x80021d00,
    // v_mov_b32_e32 v31, 0x40000001
    0x7e3e02ff, 0x40000001,
    // buffer_load_dword v32, v31, s[12:15], 0 idxen  ; index * 4 wraps to 4: in the bytes, past the records: 0
    0xe0302000, 0x8003201f,
    // buffer_load_dword v33, v5, s[12:15], 0 idxen  ; record 1
    0xe0302000, 0x80032105,
    // buffer_load_dword v34, v5, s[12:15], 0 idxen offset:4  ; record 1 + 4: within the records, past the bytes: 0
    0xe0302004, 0x80032205,
    // buffer_load_format_xy v[35:36], v5, s[16:19], 0 idxen  ; snorm: -1 (clamped), 16384/32767
    0xe0042000, 0x80042305,
    // buffer_load_format_xyzw v[37:40], v5, s[20:23], 0 idxen  ; halves 1.5, -2, (one), 7
    0xe00c2000, 0x80052505,
    // v_mov_b32_e32 v41, 2
    0x7e520282,
    // buffer_load_format_xyzw v[42:45], v41, s[20:23], 0 idxen  ; past the records: 0, 0, 1, 0
    0xe00c2000, 0x80052a29,
    // buffer_load_format_xyzw v[46:49], v5, s[24:27], 0 idxen  ; no window: 0, 0, 1, 1
    0xe00c2000, 0x80062e05,
    // tbuffer_load_format_xy v[50:51], v5, s[28:31], 0 format:[BUF_FMT_8_8_UNORM] idxen  ; 0.2, 0.8
    0xe8712000, 0x80073205,
    // buffer_load_dword v52, v5, s[8:11], 0 idxen offset:4  ; no stride: the index adds nothing
    0xe0302004, 0x80023405,
    // v_mov_b32_e32 v53, 0
    0x7e6a0280,
    // v_mov_b32_e32 v54, 0
    0x7e6c0280,
    // buffer_load_format_x v55, v5, s[32:35], 0 idxen  ; 16 unorm 0xffff: 1.0
    0xe0002000, 0x80083705,
    // s_waitcnt vmcnt(0)
    0xbf8c3f70,
    // exp param0 v20, v21, v22, v23
    0xf800020f, 0x17161514,
    // exp param1 v24, v25, v26, v27
    0xf800021f, 0x1b1a1918,
    // exp param2 v28, v29, v30, v31
    0xf800022f, 0x1f1e1d1c,
    // exp param3 v32, v33, v34, v35
    0xf800023f, 0x23222120,
    // exp param4 v36, v37, v38, v39
    0xf800024f, 0x27262524,
    // exp param5 v40, v41, v42, v43
    0xf800025f, 0x2b2a2928,
    // exp param6 v44, v45, v46, v47
    0xf800026f, 0x2f2e2d2c,
    // exp param7 v48, v49, v50, v51
    0xf800027f, 0x33323130,
    // exp param8 v52, v53, v54, v55
    0xf800028f, 0x37363534,
    // s_endpgm
    0xbf810000,
};

/// A raw load through a V# in s[8:11] (the test makes it no stride and 2^32 - 1 records).
pub const huge_window = [_]u32{
    // buffer_load_dword v0, off, s[8:11], 0
    0xe0300000, 0x80020000,
    // s_waitcnt vmcnt(0)
    0xbf8c3f70,
    // exp param0 v0, off, off, off
    0xf8000201, 0x00000000,
    // s_endpgm
    0xbf810000,
};

/// s_bfe_i32 and v_bfe_i32 on the same inputs (user data s8), fields past bit 31 and inside.
pub const bfe_both = [_]u32{
    // s_bfe_i32 s20, s8, 0x8001c  ; 8 bits from bit 28
    0x9414ff08, 0x0008001c,
    // v_bfe_i32 v20, s8, 28, 8
    0xd5490014, 0x02213808,
    // v_mov_b32_e32 v21, s20
    0x7e2a0214,
    // s_bfe_i32 s21, s8, 0x40018  ; 4 bits from bit 24
    0x9415ff08, 0x00040018,
    // v_bfe_i32 v22, s8, 24, 4
    0xd5490016, 0x02113008,
    // v_mov_b32_e32 v23, s21
    0x7e2e0215,
    // exp param0 v20, v21, v22, v23
    0xf800020f, 0x17161514,
    // s_endpgm
    0xbf810000,
};

/// The pixel's y over 32 as its colour (PS_INPUT_ADDR/ENA 0x200: v0 the pixel's y).
pub const ps_posy = [_]u32{
    // v_mul_f32_e32 v1, 0x3d000000, v0
    0x100200ff, 0x3d000000,
    // exp mrt0 v1, v1, v1, v1 done vm
    0xf800180f, 0x01010101,
    // s_endpgm
    0xbf810000,
};

/// Exports into 32_R, 32_GR and 32_AR targets and the depth.
pub const ps_exports = [_]u32{
    // v_mov_b32_e32 v0, 0.5
    0x7e0002f0,
    // v_mov_b32_e32 v1, 0x3e800000  ; 0.25
    0x7e0202ff, 0x3e800000,
    // v_mov_b32_e32 v2, 0x3f400000  ; 0.75
    0x7e0402ff, 0x3f400000,
    // exp mrt0 v0, v1, v2, v1
    0xf800000f, 0x01020100,
    // exp mrt1 v0, v1, v2, v1
    0xf800001f, 0x01020100,
    // exp mrt2 v0, v1, off, off
    0xf8000023, 0x00000100,
    // exp mrtz v2, off, off, off done vm
    0xf8001881, 0x00000002,
    // s_endpgm
    0xbf810000,
};

/// The user data s[0:3] as the colour.
pub const ps_user4 = [_]u32{
    // v_mov_b32_e32 v0, s0
    0x7e000200,
    // v_mov_b32_e32 v1, s1
    0x7e020201,
    // v_mov_b32_e32 v2, s2
    0x7e040202,
    // v_mov_b32_e32 v3, s3
    0x7e060203,
    // exp mrt0 v0, v1, v2, v3 done vm
    0xf800180f, 0x03020100,
    // s_endpgm
    0xbf810000,
};
