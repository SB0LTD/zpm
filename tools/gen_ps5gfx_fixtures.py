#!/usr/bin/env python3
"""Make src/ps5gfx/shader_fixtures.sig: small PS5 shaders (gfx10, LLVM's
gfx1013) for the recompiler's tests (src/ps5gfx/recompile_test.sig and
recompile_draw_test.sig), assembled by LLVM's AMDGPU assembler.

Each fixture is gfx10 assembly written here by hand: the shapes a
compiler's output has (the vertex side fetches its own attributes through
the tables its user data point at, as section 2.3 of the PS5 shader notes
describes; the pixel shader interpolates with v_interp_* and exports with
exp). The generated file has, for each fixture, every instruction as a
comment followed by its words.

The assembler is `zig clang -cc1as` (as tools/gen_gfx10_vectors.py drives
it); --zig names another binary with the same interface (Sig's own `sig`
has it). Run it where that binary runs, for example in WSL:

    python3 tools/gen_ps5gfx_fixtures.py --zig ~/.local/sig/.../bin/sig
"""

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "src", "ps5gfx", "shader_fixtures.sig")
CPU = "gfx1013"

# ── The fixtures: (name, doc, wave64, assembly) ──────────────────────────────

FIXTURES = []


def fixture(name, doc, text, wave64=False):
    FIXTURES.append((name, doc, wave64, text))


fixture("scalar_ops", "Every scalar instruction the interpreter runs (a pixel shader: user data from s0). "
        "user: s0 0x12345678, s1 0x80000001, s2 0xfffffff0, s3 7, s[4:5] an address, s[8:11] a V#.", """
    s_getpc_b64 s[16:17]                     ; the next instruction's address
    s_mov_b32 s18, s0
    s_movk_i32 s19, 0x8000                   ; sign-extended: 0xffff8000
    s_add_u32 s20, s1, s1                    ; 2, carry: SCC 1
    s_addc_u32 s21, 0, 0                     ; the carry: 1
    s_sub_u32 s22, 5, 7                      ; 0xfffffffe, borrow: SCC 1
    s_cselect_b32 s23, 1, 2                  ; 1
    s_add_i32 s24, s1, -1                    ; 0x80000000, no overflow: SCC 0
    s_cselect_b32 s25, 1, 2                  ; 2
    s_sub_i32 s26, s1, 2                     ; overflow: 0x7fffffff, SCC 1
    s_addc_u32 s27, s3, 0                    ; 7 + 0 + 1 = 8
    s_mul_i32 s28, s3, -3                    ; -21
    s_and_b32 s29, s0, 0xff00ff00            ; 0x12005600
    s_or_b32 s30, s3, 0x100                  ; 0x107
    s_xor_b32 s31, s0, -1                    ; 0xedcba987
    s_andn2_b32 s32, s0, 0xffff              ; 0x12340000
    s_orn2_b32 s33, 0, s2                    ; 0xf
    s_not_b32 s34, s3                        ; 0xfffffff8
    s_lshl_b32 s35, s3, 29                   ; 0xe0000000
    s_lshr_b32 s36, s2, 28                   ; 0xf
    s_ashr_i32 s37, s2, 2                    ; 0xfffffffc
    s_bfe_u32 s38, s0, 0x80008               ; 8 bits from bit 8: 0x56
    s_bfe_i32 s39, s2, 0x40002               ; 4 bits from bit 2, signed: -4
    s_bfm_b32 s40, 4, 8                      ; 0xf00
    s_min_i32 s41, s1, s3                    ; 0x80000001
    s_min_u32 s42, s1, s3                    ; 7
    s_max_i32 s43, s1, s3                    ; 7
    s_max_u32 s44, s1, s3                    ; 0x80000001
    s_lshl2_add_u32 s45, s3, 0x100           ; 28 + 256 = 0x11c
    s_addk_i32 s45, 0x10                     ; 0x12c
    s_mov_b64 s[46:47], s[0:1]
    s_lshl_b64 s[48:49], s[2:3], 4           ; 0x7fffffff0 << 4
    s_lshr_b64 s[50:51], s[2:3], 8           ; 0x7fffffff0 >> 8
    s_and_b64 s[52:53], s[0:1], s[2:3]
    s_or_b64 s[54:55], s[0:1], 1
    s_xor_b64 s[56:57], s[0:1], -1
    s_not_b64 s[58:59], s[2:3]
    s_cmp_eq_u32 s3, 7
    s_cselect_b32 s60, s3, 0                 ; 7
    s_cmp_lt_i32 s1, 0
    s_cselect_b32 s61, 1, 0                  ; 1
    s_cmp_gt_u32 s1, s0
    s_cselect_b32 s62, 1, 0                  ; 1
    s_cmp_ge_i32 s1, s0
    s_cselect_b32 s63, 1, 0                  ; 0
    s_cmpk_lt_i32 s19, 0x0
    s_cselect_b32 s64, 3, 4                  ; 3
    s_cmpk_eq_u32 s3, 0x8
    s_cselect_b32 s65, 3, 4                  ; 4
    s_cmp_lg_u64 s[0:1], s[46:47]
    s_cselect_b64 s[66:67], s[0:1], s[2:3]   ; SCC 0: s[2:3]
    s_load_dwordx2 s[68:69], s[4:5], 0x10    ; memory words 4 and 5
    s_load_dword s70, s[4:5], s3             ; byte 7, rounded down: word 1
    s_buffer_load_dwordx4 s[72:75], s[8:11], 0x10 ; through the V#: two words in range, two past it
    s_waitcnt lgkmcnt(0)
    s_endpgm
""")

fixture("mask_pair", "Wave64: a compare's mask in an SGPR pair, logic on it, a scalar pair beside it.", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5         ; a lane mask in s[4:5]
    s_and_b64 s[6:7], exec, s[4:5]           ; logic on masks: pred logic
    s_mov_b64 s[8:9], s[10:11]               ; scalars: the interpreter's
    v_cndmask_b32_e64 v3, 0, 1.0, s[6:7]     ; the mask selects
    v_mov_b32 v4, s8                         ; the scalar read by a lane: a slot
    s_endpgm
""", wave64=True)

fixture("mask_mixed", "Wave64: a mask and a scalar in one logic instruction (refused).", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    s_and_b64 s[6:7], s[4:5], s[10:11]
    s_endpgm
""", wave64=True)

fixture("mask_as_scalar", "Wave64: a mask read as a number (refused).", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    s_add_u32 s6, s4, 1
    s_endpgm
""", wave64=True)

fixture("branch", "A uniform branch (refused: straight-line code only).", """
    s_cmp_eq_u32 s0, 0
    s_cbranch_scc1 1
    v_mov_b32 v0, 0
    s_endpgm
""")

fixture("exec_write", "A write to EXEC (refused).", """
    s_mov_b32 exec_lo, s0
    s_endpgm
""")

fixture("unknown", "An instruction this cut does not translate (refused).", """
    v_sin_f32 v0, v1
    s_endpgm
""")

fixture("redefine", "A scalar read by lane code, redefined, read again: two slots.", """
    v_mul_f32 v0, s0, v1                     ; slot 0: s0 as the user gave it
    v_mul_f32 v2, s0, v3                     ; the same definition: slot 0 again
    s_mov_b32 s0, 2.0
    v_mul_f32 v4, s0, v5                     ; a new definition: slot 1
    s_endpgm
""")

fixture("vs_fetch", "The vertex side of the draw tests (32 lanes). User data (s8 on): s[8:9] the vertex buffer table (a V# each), "
        "s[10:11] the attribute word table, s[12:15] the constant buffer's V# (a column-major 4x4 matrix). "
        "Attribute 0 is the position (xyz), 1 the colour (xyzw), 2 a scale for the colour (x); each one's word gives "
        "its V#, its byte offset and whether the vertex or the instance index fetches it. The position's and the "
        "scale's offsets are added to their V#'s base (as compilers do), the colour's is passed as soffset.", """
    s_load_dwordx4 s[16:19], s[10:11], 0x0   ; the attribute words of semantics 0..3
    s_buffer_load_dwordx16 s[32:47], s[12:15], 0x0 ; the matrix
    s_waitcnt lgkmcnt(0)
    s_and_b32 s20, s16, 31                   ; the position's vertex buffer slot
    s_lshl_b32 s20, s20, 4                   ; its V#'s offset in the table
    s_load_dwordx4 s[24:27], s[8:9], s20     ; the position's V#
    s_bfe_u32 s21, s16, 0xc000e              ; its byte offset (bits 14-25)
    s_bfe_u32 s22, s16, 0x1001a              ; its fetch index (bit 26)
    s_and_b32 s48, s17, 31                   ; the colour's
    s_lshl_b32 s48, s48, 4
    s_load_dwordx4 s[28:31], s[8:9], s48
    s_bfe_u32 s49, s17, 0xc000e
    s_bfe_u32 s50, s17, 0x1001a
    s_and_b32 s51, s18, 31                   ; the scale's
    s_lshl_b32 s51, s51, 4
    s_load_dwordx4 s[52:55], s[8:9], s51
    s_bfe_u32 s56, s18, 0xc000e
    s_bfe_u32 s57, s18, 0x1001a
    s_waitcnt lgkmcnt(0)
    s_add_u32 s24, s24, s21                  ; the position's offset into its V#'s base
    s_addc_u32 s25, s25, 0
    s_add_u32 s52, s52, s56                  ; the scale's
    s_addc_u32 s53, s53, 0
    v_cmp_ne_u32_e64 s58, 0, s22             ; fetched by the instance index?
    v_cndmask_b32_e64 v9, v5, v8, s58        ; v5 the vertex index, v8 the instance index
    v_cmp_ne_u32_e64 s59, 0, s50
    v_cndmask_b32_e64 v10, v5, v8, s59
    v_cmp_ne_u32_e64 s60, 0, s57
    v_cndmask_b32_e64 v19, v5, v8, s60
    buffer_load_format_xyz v[11:13], v9, s[24:27], 0 idxen
    buffer_load_format_xyzw v[14:17], v10, s[28:31], s49 idxen
    buffer_load_format_x v18, v19, s[52:55], 0 idxen
    s_waitcnt vmcnt(0)
    v_mul_f32 v14, v14, v18                  ; the colour scaled (not its alpha)
    v_mul_f32 v15, v15, v18
    v_mul_f32 v16, v16, v18
    v_mul_f32 v0, s32, v11                   ; x' = m0 x + m4 y + m8 z + m12
    v_fmac_f32 v0, s36, v12
    v_fmac_f32 v0, s40, v13
    v_add_f32 v0, s44, v0
    v_mul_f32 v1, s33, v11                   ; y'
    v_fmac_f32 v1, s37, v12
    v_fmac_f32 v1, s41, v13
    v_add_f32 v1, s45, v1
    v_mul_f32 v2, s34, v11                   ; z'
    v_fmac_f32 v2, s38, v12
    v_fmac_f32 v2, s42, v13
    v_add_f32 v2, s46, v2
    v_mul_f32 v3, s35, v11                   ; w'
    v_fmac_f32 v3, s39, v12
    v_fmac_f32 v3, s43, v13
    v_add_f32 v3, s47, v3
    s_mov_b32 m0, s3                         ; NGG's allocation request (counts in m0)
    s_sendmsg sendmsg(MSG_GS_ALLOC_REQ)
    exp prim v4, off, off, off done          ; NGG's primitive export (not translated)
    exp pos0 v0, v1, v2, v3 done
    exp param0 v14, v15, v16, v17            ; the colour, smooth
    exp param1 v14, v15, v16, v17            ; the colour again, for a flat input
    s_endpgm
""")

fixture("ps_interp", "A pixel shader: input 0 interpolated, the colour out (PS_INPUT_ADDR/ENA 0x2: v0, v1 the "
        "perspective I and J; no user data, the primitive mask in s0).", """
    s_mov_b32 m0, s0
    v_interp_p1_f32 v2, v0, attr0.x
    v_interp_p2_f32 v2, v1, attr0.x
    v_interp_p1_f32 v3, v0, attr0.y
    v_interp_p2_f32 v3, v1, attr0.y
    v_interp_p1_f32 v4, v0, attr0.z
    v_interp_p2_f32 v4, v1, attr0.z
    v_interp_p1_f32 v5, v0, attr0.w
    v_interp_p2_f32 v5, v1, attr0.w
    exp mrt0 v2, v3, v4, v5 done vm
    s_endpgm
""")

fixture("ps_tint", "A pixel shader (PS_INPUT_ADDR/ENA 0x302: v0, v1 I and J, v2 the pixel's x, v3 its y; "
        "user data s[0:3] a tint, the primitive mask in s4): input 0 smooth times the tint, input 1 flat, "
        "input 2 a default, chosen by the pixel's x; out as packed halves.", """
    s_mov_b32 m0, s4
    v_interp_p1_f32 v4, v0, attr0.x
    v_interp_p2_f32 v4, v1, attr0.x
    v_interp_p1_f32 v5, v0, attr0.y
    v_interp_p2_f32 v5, v1, attr0.y
    v_interp_mov_f32 v6, p0, attr1.x         ; flat: the provoking vertex's
    v_interp_mov_f32 v7, p0, attr2.w         ; no slot: the default's w
    v_mul_f32 v4, s0, v4                     ; the tint, a scalar in lane code
    v_mul_f32 v5, s1, v5
    v_cmp_lt_f32 vcc_lo, 0x41800000, v2      ; 16 < x
    s_and_b32 vcc_lo, exec_lo, vcc_lo
    v_cndmask_b32 v8, v6, v7, vcc_lo         ; right: the default; left: the flat value
    v_cvt_pkrtz_f16_f32 v9, v4, v5
    v_cvt_pkrtz_f16_f32 v10, v8, s3          ; alpha: the tint's w
    exp mrt0 v9, v9, v10, v10 done compr vm
    s_endpgm
""")

fixture("vs_alu", "The lane instructions, each result worked out by hand, out as params 0..15 (v20..v83). "
        "User data: s8 2.5, s9 -3, s10 0x12345678, s11 4.0.", """
    v_mov_b32 v84, 2.0
    v_mov_b32 v20, s8                        ; 2.5
    v_add_f32_e64 v21, s8, 1.0               ; 3.5
    v_sub_f32_e64 v22, 1.0, s8               ; -1.5
    v_subrev_f32_e64 v23, 1.0, s8            ; 1.5
    v_mul_f32_e64 v24, s8, s11               ; 10
    v_mad_f32 v25, s8, s11, -1.0             ; 9
    v_fma_f32 v26, -s8, s11, 0.5             ; -9.5
    v_mov_b32 v27, 1.0
    v_mac_f32 v27, s8, v84                   ; 1 + 5 = 6
    v_min_f32_e64 v28, s8, -|s11|            ; -4
    v_max_f32_e64 v29, s8, s11 clamp         ; 4, clamped: 1
    v_rcp_f32_e64 v30, s11                   ; 0.25
    v_rsq_f32_e64 v31, s11                   ; 0.5
    v_sqrt_f32 v32, 0x40100000               ; sqrt(2.25) = 1.5
    v_floor_f32_e64 v33, -s8                 ; -3
    v_ceil_f32_e64 v34, s8                   ; 3
    v_trunc_f32_e64 v35, -s8                 ; -2
    v_rndne_f32_e64 v36, s8                  ; 2 (to even)
    v_fract_f32 v37, 0xbfa00000              ; fract(-1.25) = 0.75
    v_cvt_f32_i32_e64 v38, s9                ; -3.0
    v_cvt_f32_u32 v39, 0x100                 ; 256.0
    v_mov_b32 v40, 0.15915494                ; 1/(2 pi), inline
    v_cvt_i32_f32 v41, 0xc02ccccd            ; -2.7 toward zero: -2
    v_cvt_u32_f32 v42, -1.0                  ; saturated: 0
    v_cvt_pkrtz_f16_f32_e64 v43, 1.0, -2.0   ; 0xc0003c00
    v_mul_f32_e64 v44, s8, 2.0 mul:2         ; 10
    v_mul_f32_e64 v45, s8, 1.0 div:2         ; 1.25
    v_sub_f32_e64 v46, s8, s11 clamp         ; -1.5, clamped: 0
    v_cvt_f32_ubyte1_e64 v47, s10            ; 0x56: 86.0
    v_and_b32_e64 v48, s10, 0xff00ff00       ; 0x12005600
    v_or_b32_e64 v49, s10, 15                ; 0x1234567f
    v_xor_b32_e64 v50, s10, -1               ; 0xedcba987
    v_not_b32_e64 v51, s9                    ; 2
    v_lshlrev_b32_e64 v52, 4, s10            ; 0x23456780
    v_lshrrev_b32_e64 v53, 4, s10            ; 0x01234567
    v_ashrrev_i32_e64 v54, 1, s9             ; -2
    v_add_nc_u32_e64 v55, s9, 10             ; 7
    v_sub_nc_u32_e64 v56, s9, 10             ; -13
    v_subrev_nc_u32_e64 v57, s9, 10          ; 13
    v_mul_lo_u32 v58, s9, s10                ; 0xc962fc98
    v_mul_hi_u32 v59, s10, 0x10000           ; 0x1234
    v_bfe_u32 v60, s10, 8, 12                ; 0x456
    v_bfe_i32 v61, s10, 0, 4                 ; 8 as 4 signed bits: -8
    v_bfm_b32 v62, 4, 8                      ; 0xf00
    v_bfi_b32 v63, 0xffff, s10, 0            ; 0x5678
    v_lshl_add_u32 v64, s9, 2, 20            ; -12 + 20 = 8
    v_lshl_or_b32 v65, 1, 4, 3               ; 0x13
    v_and_or_b32 v66, s10, 0xff, 1           ; 0x79
    v_add3_u32 v67, s9, 10, 5                ; 12
    v_min_i32_e64 v68, s9, 1                 ; -3
    v_max_i32_e64 v69, s9, 1                 ; 1
    v_min_u32_e64 v70, s9, 1                 ; 1
    v_max_u32_e64 v71, s9, 1                 ; 0xfffffffd
    v_mul_u32_u24_e64 v72, s10, 2            ; 0x68acf0
    v_mul_i32_i24_e64 v73, s9, 5             ; -15
    v_mad_u32_u24 v74, s10, 2, 1             ; 0x68acf1
    v_add_co_u32 v75, vcc_lo, s10, 0xf0000000 ; 0x02345678, carry out
    v_cndmask_b32_e64 v76, 0, 1, vcc_lo      ; the carry: 1
    v_cmp_lt_i32_e64 s50, s9, 0
    v_cndmask_b32_e64 v77, 0, 1, s50         ; -3 < 0: 1
    v_cmp_lt_u32_e64 s51, s9, 0
    v_cndmask_b32_e64 v78, 0, 1, s51         ; 0xfffffffd < 0: 0
    v_cmp_nge_f32_e64 s52, s8, s11
    v_cndmask_b32_e64 v79, 0, 1, s52         ; not 2.5 >= 4: 1
    s_andn2_b32 s53, s52, s51
    v_cndmask_b32_e64 v80, 0, 1, s53         ; 1 and not 0: 1
    v_cmp_u_f32_e64 s54, s8, s11
    v_cndmask_b32_e64 v81, 0, 1, s54         ; unordered: 0
    v_mov_b32 v82, v5                        ; the vertex index
    v_mov_b32 v83, v8                        ; the instance index
    exp param0 v20, v21, v22, v23
    exp param1 v24, v25, v26, v27
    exp param2 v28, v29, v30, v31
    exp param3 v32, v33, v34, v35
    exp param4 v36, v37, v38, v39
    exp param5 v40, v41, v42, v43
    exp param6 v44, v45, v46, v47
    exp param7 v48, v49, v50, v51
    exp param8 v52, v53, v54, v55
    exp param9 v56, v57, v58, v59
    exp param10 v60, v61, v62, v63
    exp param11 v64, v65, v66, v67
    exp param12 v68, v69, v70, v71
    exp param13 v72, v73, v74, v75
    exp param14 v76, v77, v78, v79
    exp param15 v80, v81, v82, v83
    s_endpgm
""")

fixture("ps_builtins", "A pixel shader handed the pixel's position, its facing and its fixed-point position "
        "(PS_INPUT_ADDR/ENA 0x9f00: v0..v3 x, y, z, w, v4 the facing, v5 x | y << 16).", """
    exp mrt0 v0, v1, v2, v3
    exp mrt1 v4, v5, v5, v5 done vm
    s_endpgm
""")

fixture("mask_a", "32 lanes: a mask in s5 copied as a 64-bit pair (refused).", """
    v_cmp_gt_f32_e64 s5, v2, 0.5
    s_mov_b64 s[6:7], s[4:5]
    v_mov_b32 v3, s7
    s_endpgm
""")

fixture("mask_b", "32 lanes: a pair holding a mask in s5 shifted as a number (refused).", """
    v_cmp_gt_f32_e64 s5, v2, 0.5
    s_lshr_b64 s[6:7], s[4:5], 1
    v_mov_b32 v3, s6
    s_endpgm
""")

fixture("mask_c", "64 lanes: one half of a mask pair overwritten, the pair then used as a mask (refused).", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    s_mov_b32 s5, 0
    v_cndmask_b32_e64 v3, 0, 1.0, s[4:5]
    s_endpgm
""", wave64=True)

fixture("mask_d", "32 lanes: a mask in s2 moved as a pair, s1 then used as a mask (refused).", """
    v_cmp_gt_f32_e64 s2, v2, 0.5
    s_mov_b64 s[0:1], s[2:3]
    v_cndmask_b32_e64 v3, 0, 1.0, s1
    s_endpgm
""")

fixture("mask_odd", "A compare into s5: a 32-lane mask, refused as a 64-lane one (an odd register).", """
    v_cmp_gt_f32_e64 s5, v2, 0.5
    s_endpgm
""")

fixture("mask_b32_on64", "64 lanes: 32-bit logic on half of a mask pair (refused).", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    s_and_b32 s6, s4, exec_lo
    s_endpgm
""", wave64=True)

fixture("mask_next32", "32 lanes: the register after a mask is a register of its own.", """
    v_cmp_gt_f32_e64 s4, v2, 0.5
    s_mov_b32 s5, 7
    v_mov_b32 v1, s5
    v_cndmask_b32_e64 v3, 0, 1.0, s4
    s_endpgm
""")

fixture("umask64", "64 lanes: a uniform mask made by s_cselect_b64 from a scalar compare, alone and with a lane "
        "mask (PS_INPUT_ADDR/ENA 0x100: v0 the pixel's x; user data s0).", """
    v_cmp_gt_f32_e64 s[6:7], v0, 0.5
    s_cmp_eq_u32 s0, 5
    s_cselect_b64 s[4:5], -1, 0
    v_cndmask_b32_e64 v1, 0, 1.0, s[4:5]
    s_and_b64 s[8:9], s[4:5], s[6:7]
    v_cndmask_b32_e64 v2, 0, 1.0, s[8:9]
    exp mrt0 v1, v2, v1, v2 done vm
    s_endpgm
""", wave64=True)

fixture("scc_lane_cselect", "64 lanes: s_cselect on SCC set by mask logic (refused).", """
    v_cmp_gt_f32_e64 s[4:5], v2, 0.5
    s_and_b64 s[6:7], exec, s[4:5]
    s_cselect_b64 s[8:9], -1, 0
    s_endpgm
""", wave64=True)

fixture("vs_cmp", "32 lanes: compares with NaN and infinity (ordered against unordered), unsigned and signed "
        "compares, logic on their masks, and uniform masks from s_cselect_b32; each mask out as 0 or 1 "
        "(v20..v46, then 7). User data: s8 NaN, s9 +inf, s10 1.0, s11 0xfffffffe, s12 5.", """
    v_cmp_lt_f32_e64 s20, s8, s10            ; NaN < 1: 0
    v_cmp_nge_f32_e64 s21, s8, s10           ; not NaN >= 1: 1
    v_cmp_neq_f32_e64 s22, s8, s8            ; 1
    v_cmp_eq_f32_e64 s23, s8, s8             ; 0
    v_cmp_lg_f32_e64 s24, s8, s10            ; ordered and not equal: 0
    v_cmp_nlg_f32_e64 s25, s8, s10           ; 1
    v_cmp_o_f32_e64 s26, s8, s10             ; 0
    v_cmp_u_f32_e64 s27, s8, s10             ; 1
    v_cmp_gt_f32_e64 s28, s9, s10            ; inf > 1: 1
    v_cmp_ngt_f32_e64 s29, s9, s10           ; 0
    v_cmp_le_f32_e64 s30, s9, s9             ; 1
    v_cmp_lg_f32_e64 s31, s9, s10            ; 1
    v_cmp_nle_f32_e64 s32, s10, s9           ; 0
    v_cmp_nlt_f32_e64 s33, s9, s10           ; 1
    v_cmp_ge_f32_e64 s34, s8, s8             ; 0
    v_cmp_gt_u32_e64 s35, s11, 1             ; 0xfffffffe > 1 unsigned: 1
    v_cmp_lt_i32_e64 s36, s11, 1             ; -2 < 1 signed: 1
    v_cmp_ge_u32_e64 s37, s11, s11           ; 1
    v_cmp_lt_u32_e64 s38, s11, 1             ; 0
    v_cmp_ne_u32_e64 s39, s11, -2            ; 0
    s_xor_b32 s40, s35, s36                  ; 0
    s_orn2_b32 s41, s38, s37                 ; 0
    s_or_b32 s42, s38, s35                   ; 1
    s_not_b32 s43, s38                       ; 1
    s_cmp_eq_u32 s12, 5
    s_cselect_b32 s44, -1, 0                 ; uniform: every lane
    s_cmp_eq_u32 s12, 6
    s_cselect_b32 s45, -1, 0                 ; uniform: none
    s_and_b32 s46, s44, s35                  ; uniform with a lane mask: 1
    v_cndmask_b32_e64 v20, 0, 1, s20
    v_cndmask_b32_e64 v21, 0, 1, s21
    v_cndmask_b32_e64 v22, 0, 1, s22
    v_cndmask_b32_e64 v23, 0, 1, s23
    v_cndmask_b32_e64 v24, 0, 1, s24
    v_cndmask_b32_e64 v25, 0, 1, s25
    v_cndmask_b32_e64 v26, 0, 1, s26
    v_cndmask_b32_e64 v27, 0, 1, s27
    v_cndmask_b32_e64 v28, 0, 1, s28
    v_cndmask_b32_e64 v29, 0, 1, s29
    v_cndmask_b32_e64 v30, 0, 1, s30
    v_cndmask_b32_e64 v31, 0, 1, s31
    v_cndmask_b32_e64 v32, 0, 1, s32
    v_cndmask_b32_e64 v33, 0, 1, s33
    v_cndmask_b32_e64 v34, 0, 1, s34
    v_cndmask_b32_e64 v35, 0, 1, s35
    v_cndmask_b32_e64 v36, 0, 1, s36
    v_cndmask_b32_e64 v37, 0, 1, s37
    v_cndmask_b32_e64 v38, 0, 1, s38
    v_cndmask_b32_e64 v39, 0, 1, s39
    v_cndmask_b32_e64 v40, 0, 1, s40
    v_cndmask_b32_e64 v41, 0, 1, s41
    v_cndmask_b32_e64 v42, 0, 1, s42
    v_cndmask_b32_e64 v43, 0, 1, s43
    v_cndmask_b32_e64 v44, 0, 1, s44
    v_cndmask_b32_e64 v45, 0, 1, s45
    v_cndmask_b32_e64 v46, 0, 1, s46
    v_mov_b32 v47, 7
    exp param0 v20, v21, v22, v23
    exp param1 v24, v25, v26, v27
    exp param2 v28, v29, v30, v31
    exp param3 v32, v33, v34, v35
    exp param4 v36, v37, v38, v39
    exp param5 v40, v41, v42, v43
    exp param6 v44, v45, v46, v47
    s_endpgm
""")

fixture("vs_loads", "Lane buffer loads through V#s in user data (s8 on, 32 lanes; v5 the vertex index, 1 in the test): "
        "A s[8:11] raw, no stride, 20 bytes; B s[12:15] 4-byte records, 2 of them; C s[16:19] 16_16 snorm; "
        "D s[20:23] 16_16_16_16 float with dst_sel X, Y, one, W; E s[24:27] no records; F s[28:31] read as "
        "8_8 unorm by tbuffer's own format; H s[32:35] 16 unorm. Out: v20..v55.", """
    v_mov_b32 v30, 8
    buffer_load_dwordx4 v[20:23], v30, s[8:11], 0 offen   ; bytes 8..23 of 20: three dwords in, one past
    buffer_load_dword v24, off, s[8:11], 0 offset:16       ; the last dword
    buffer_load_dword v25, off, s[8:11], 0 offset:20       ; past the bytes: 0
    buffer_load_ubyte v26, off, s[8:11], 0 offset:1
    buffer_load_sbyte v27, off, s[8:11], 0 offset:1
    buffer_load_ushort v28, off, s[8:11], 0 offset:2
    buffer_load_sshort v29, off, s[8:11], 0 offset:2
    v_mov_b32 v31, 0x40000001
    buffer_load_dword v32, v31, s[12:15], 0 idxen          ; index * 4 wraps to 4: in the bytes, past the records: 0
    buffer_load_dword v33, v5, s[12:15], 0 idxen           ; record 1
    buffer_load_dword v34, v5, s[12:15], 0 idxen offset:4  ; record 1 + 4: within the records, past the bytes: 0
    buffer_load_format_xy v[35:36], v5, s[16:19], 0 idxen  ; snorm: -1 (clamped), 16384/32767
    buffer_load_format_xyzw v[37:40], v5, s[20:23], 0 idxen ; halves 1.5, -2, (one), 7
    v_mov_b32 v41, 2
    buffer_load_format_xyzw v[42:45], v41, s[20:23], 0 idxen ; past the records: 0, 0, 1, 0
    buffer_load_format_xyzw v[46:49], v5, s[24:27], 0 idxen ; no window: 0, 0, 1, 1
    tbuffer_load_format_xy v[50:51], v5, s[28:31], 0 format:[BUF_FMT_8_8_UNORM] idxen ; 0.2, 0.8
    buffer_load_dword v52, v5, s[8:11], 0 idxen offset:4   ; no stride: the index adds nothing
    v_mov_b32 v53, 0
    v_mov_b32 v54, 0
    buffer_load_format_x v55, v5, s[32:35], 0 idxen        ; 16 unorm 0xffff: 1.0
    s_waitcnt vmcnt(0)
    exp param0 v20, v21, v22, v23
    exp param1 v24, v25, v26, v27
    exp param2 v28, v29, v30, v31
    exp param3 v32, v33, v34, v35
    exp param4 v36, v37, v38, v39
    exp param5 v40, v41, v42, v43
    exp param6 v44, v45, v46, v47
    exp param7 v48, v49, v50, v51
    exp param8 v52, v53, v54, v55
    s_endpgm
""")

fixture("huge_window", "A raw load through a V# in s[8:11] (the test makes it no stride and 2^32 - 1 records).", """
    buffer_load_dword v0, off, s[8:11], 0
    s_waitcnt vmcnt(0)
    exp param0 v0, off, off, off
    s_endpgm
""")

fixture("bfe_both", "s_bfe_i32 and v_bfe_i32 on the same inputs (user data s8), fields past bit 31 and inside.", """
    s_bfe_i32 s20, s8, 0x8001c               ; 8 bits from bit 28
    v_bfe_i32 v20, s8, 28, 8
    v_mov_b32 v21, s20
    s_bfe_i32 s21, s8, 0x40018               ; 4 bits from bit 24
    v_bfe_i32 v22, s8, 24, 4
    v_mov_b32 v23, s21
    exp param0 v20, v21, v22, v23
    s_endpgm
""")

fixture("ps_posy", "The pixel's y over 32 as its colour (PS_INPUT_ADDR/ENA 0x200: v0 the pixel's y).", """
    v_mul_f32 v1, 0x3d000000, v0
    exp mrt0 v1, v1, v1, v1 done vm
    s_endpgm
""")

fixture("ps_exports", "Exports into 32_R, 32_GR and 32_AR targets and the depth.", """
    v_mov_b32 v0, 0.5
    v_mov_b32 v1, 0x3e800000                 ; 0.25
    v_mov_b32 v2, 0x3f400000                 ; 0.75
    exp mrt0 v0, v1, v2, v1
    exp mrt1 v0, v1, v2, v1
    exp mrt2 v0, v1, off, off
    exp mrtz v2, off, off, off done vm
    s_endpgm
""")

fixture("ps_user4", "The user data s[0:3] as the colour.", """
    v_mov_b32 v0, s0
    v_mov_b32 v1, s1
    v_mov_b32 v2, s2
    v_mov_b32 v3, s3
    exp mrt0 v0, v1, v2, v3 done vm
    s_endpgm
""")

# ── LLVM ────────────────────────────────────────────────────────────────────


def strip(line):
    return line.split(";", 1)[0].strip()


def assemble(zig, lines, scratch, wave64):
    src = os.path.join(scratch, "in.s")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    cmd = [zig, "clang", "-cc1as", "-triple", "amdgcn-amd-amdhsa", "-target-cpu", CPU]
    if wave64:
        cmd += ["-target-feature", "+wavefrontsize64", "-target-feature", "-wavefrontsize32"]
    cmd += ["-show-encoding", "-filetype", "asm", src, "-o", "-"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0 or "error" in p.stderr:
        raise SystemExit(f"LLVM refused:\n{p.stderr}")
    out = []
    for line in p.stdout.splitlines():
        if "; encoding:" not in line:
            continue
        text, bs = line.split("; encoding:")
        bs = [int(x, 16) for x in bs.strip().strip("[]").split(",")]
        if len(bs) % 4:
            raise SystemExit(f"odd encoding: {line}")
        words = [bs[i] | bs[i + 1] << 8 | bs[i + 2] << 16 | bs[i + 3] << 24 for i in range(0, len(bs), 4)]
        out.append((" ".join(text.split()), words))
    return out


def version(zig):
    p = subprocess.run([zig, "clang", "--version"], capture_output=True, text=True)
    return p.stdout.splitlines()[0].strip() if p.stdout else "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zig", default=os.environ.get("ZIG", "zig"))
    args = ap.parse_args()
    o = []
    o.append("//! PS5 shaders (gfx10, LLVM's gfx1013) for the recompiler's tests, made by")
    o.append("//! tools/gen_ps5gfx_fixtures.py: written there as assembly, assembled by")
    o.append(f"//! LLVM's AMDGPU assembler ({version(args.zig)}). Do not edit by hand.")
    o.append("//! Each instruction is the comment above its words.")
    o.append("")
    with tempfile.TemporaryDirectory() as scratch:
        for name, doc, wave64, text in FIXTURES:
            src = [ln for ln in text.strip("\n").splitlines() if strip(ln)]
            enc = assemble(args.zig, [strip(ln) for ln in src], scratch, wave64)
            if len(enc) != len(src):
                raise SystemExit(f"{name}: {len(src)} lines, {len(enc)} encodings")
            o.append(f"/// {doc}" + (" (wave64)" if wave64 else ""))
            o.append(f"pub const {name} = [_]u32{{")
            for line, (llvm, words) in zip(src, enc):
                note = line.split(";", 1)[1].strip() if ";" in line else ""
                o.append(f"    // {llvm}" + (f"  ; {note}" if note else ""))
                o.append("    " + ", ".join(f"0x{w:08x}" for w in words) + ",")
            o.append("};")
            o.append("")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(o))
    print(f"wrote {OUT}: {len(FIXTURES)} fixtures")


if __name__ == "__main__":
    sys.exit(main())
