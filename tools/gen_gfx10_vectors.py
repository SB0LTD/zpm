#!/usr/bin/env python3
"""Make src/amdgpu/gfx10_rows.sig and src/amdgpu/gfx10_vectors.txt: the
gfx10 dialect of src/amdgpu/gfx10.sig, from LLVM's AMDGPU assembler.

The PS5's GPU is LLVM's gfx1013 (gfx10.1 with ray tracing). This tool has a
list of candidate instructions (every gfx8 row of gcn3.sig, renamed where
gfx10 renamed it, and the instructions new in gfx10) with their operand
shapes and types. It writes several lines per candidate (registers,
constants, literals, special registers, modifiers), has LLVM encode them for
gfx1013, and keeps what LLVM accepts:

- the opcodes: each row's encoding and opcode (and the VOP3 opcode of a
  VOP1/VOP2/VOPC row) are read from LLVM's bytes, never typed in;
- the modifiers each VOP3 row takes (clamp, omod, neg/abs, op_sel), from
  which modifier lines LLVM accepts;
- the names LLVM prints for hwreg ids and the MTBUF formats;
- the vectors: LLVM's text (runs of spaces made one) and words.

A mnemonic LLVM refuses for gfx1013 is not in the dialect. The candidates
are also tried on gfx1030, and the differences are printed (--report).
The wave64 lines (masks in SGPR pairs) come from the same assembler with
+wavefrontsize64, after a "# wave64" line.

    python tools/gen_gfx10_vectors.py [--report]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GCN3 = os.path.join(ROOT, "src", "amdgpu", "gcn3.sig")
ROWS_OUT = os.path.join(ROOT, "src", "amdgpu", "gfx10_rows.sig")
VEC_OUT = os.path.join(ROOT, "src", "amdgpu", "gfx10_vectors.txt")
CPU = "gfx1013"
OTHER_CPU = "gfx1030"

FCONDS = ["f", "lt", "eq", "le", "gt", "lg", "ge", "o", "u", "nge", "nlg", "ngt", "nle", "neq", "nlt", "tru"]
ICONDS = ["f", "lt", "eq", "le", "gt", "ne", "ge", "t"]
DWORDS = {"none": 0, "b16": 1, "f16": 1, "b32": 1, "f32": 1, "b64": 2, "f64": 2, "b96": 3, "b128": 4, "b256": 8, "b512": 16}
ROW = re.compile(r'^\s*\.\{\s*"([a-z0-9_{}]+)",\s*\.(\w+),\s*(0x[0-9a-f]+|\d+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*(true|false)\s*\},')

# Row flags (the last column of a row)
F_CLAMP, F_OMOD, F_NEG, F_OPSEL, F_SUFFIX, F_HEX, F_DEC = 1, 2, 4, 8, 16, 32, 64

# ── Candidates ──────────────────────────────────────────────────────────────

# gfx8 names gfx10 renamed (and the shape the new one has)
RENAME = {
    "v_add_u32": ("v_add_co_u32", "vop_carry"),
    "v_sub_u32": ("v_sub_co_u32", "vop_carry"),
    "v_subrev_u32": ("v_subrev_co_u32", "vop_carry"),
    "v_addc_u32": ("v_add_co_ci_u32", "vop_carry_in"),
    "v_subb_u32": ("v_sub_co_ci_u32", "vop_carry_in"),
    "v_subbrev_u32": ("v_subrev_co_ci_u32", "vop_carry_in"),
    "v_add_u16": ("v_add_nc_u16", "vop"),
    "v_sub_u16": ("v_sub_nc_u16", "vop"),
}

# Instructions new in gfx10 (or new since gfx8): name shape d s0 s1 s2
NEW = """
s_mul_hi_u32 sop2 b32 b32 b32 -
s_mul_hi_i32 sop2 b32 b32 b32 -
s_lshl1_add_u32 sop2 b32 b32 b32 -
s_lshl2_add_u32 sop2 b32 b32 b32 -
s_lshl3_add_u32 sop2 b32 b32 b32 -
s_lshl4_add_u32 sop2 b32 b32 b32 -
s_pack_ll_b32_b16 sop2 b32 b32 b32 -
s_pack_lh_b32_b16 sop2 b32 b32 b32 -
s_pack_hh_b32_b16 sop2 b32 b32 b32 -
s_version sopk_imm - - - -
s_call_b64 sopk_branch b64 - - -
s_subvector_loop_begin sopk_branch b32 - - -
s_subvector_loop_end sopk_branch b32 - - -
s_waitcnt_vscnt sopk b32 - - -
s_waitcnt_vmcnt sopk b32 - - -
s_waitcnt_expcnt sopk b32 - - -
s_waitcnt_lgkmcnt sopk b32 - - -
s_and_saveexec_b32 sop1 b32 b32 - -
s_or_saveexec_b32 sop1 b32 b32 - -
s_xor_saveexec_b32 sop1 b32 b32 - -
s_andn2_saveexec_b32 sop1 b32 b32 - -
s_orn2_saveexec_b32 sop1 b32 b32 - -
s_nand_saveexec_b32 sop1 b32 b32 - -
s_nor_saveexec_b32 sop1 b32 b32 - -
s_xnor_saveexec_b32 sop1 b32 b32 - -
s_andn1_saveexec_b32 sop1 b32 b32 - -
s_andn1_saveexec_b64 sop1 b64 b64 - -
s_orn1_saveexec_b32 sop1 b32 b32 - -
s_orn1_saveexec_b64 sop1 b64 b64 - -
s_andn1_wrexec_b32 sop1 b32 b32 - -
s_andn1_wrexec_b64 sop1 b64 b64 - -
s_andn2_wrexec_b32 sop1 b32 b32 - -
s_andn2_wrexec_b64 sop1 b64 b64 - -
s_bitreplicate_b64_b32 sop1 b64 b32 - -
s_movrelsd_2_b32 sop1 b32 b32 - -
s_sendmsg sopp_sendmsg - - - -
s_sendmsghalt sopp_sendmsg - - - -
s_endpgm_ordered_ps_done sopp - - - -
s_code_end sopp - - - -
s_inst_prefetch sopp_imm - - - -
s_clause sopp_imm - - - -
s_waitcnt_depctr sopp_imm - - - -
s_round_mode sopp_imm - - - -
s_denorm_mode sopp_imm - - - -
s_ttracedata_imm sopp_imm - - - -
s_buffer_load_dword smem_load b32 b128 - -
s_buffer_load_dwordx2 smem_load b64 b128 - -
s_buffer_load_dwordx4 smem_load b128 b128 - -
s_buffer_load_dwordx8 smem_load b256 b128 - -
s_buffer_load_dwordx16 smem_load b512 b128 - -
s_gl1_inv smem_none - - - -
s_get_waveid_in_workgroup smem_time b32 - - -
v_xnor_b32 vop b32 b32 b32 -
v_add_nc_u32 vop b32 b32 b32 -
v_sub_nc_u32 vop b32 b32 b32 -
v_subrev_nc_u32 vop b32 b32 b32 -
v_fmac_f32 vop f32 f32 f32 -
v_fmamk_f32 vop_madmk f32 f32 f32 -
v_fmaak_f32 vop_madak f32 f32 f32 -
v_fmac_f16 vop f16 f16 f16 -
v_fmamk_f16 vop_madmk f16 f16 f16 -
v_fmaak_f16 vop_madak f16 f16 f16 -
v_pk_fmac_f16 vop b32 b32 b32 -
v_mac_legacy_f32 vop f32 f32 f32 -
v_dot2c_f32_f16 vop f32 b32 b32 -
v_dot4c_i32_i8 vop b32 b32 b32 -
v_add_nc_i16 vop b16 b16 b16 -
v_sub_nc_i16 vop b16 b16 b16 -
v_add_nc_i32 vop b32 b32 b32 -
v_sub_nc_i32 vop b32 b32 b32 -
v_lshl_add_u32 vop b32 b32 b32 b32
v_add_lshl_u32 vop b32 b32 b32 b32
v_add3_u32 vop b32 b32 b32 b32
v_lshl_or_b32 vop b32 b32 b32 b32
v_and_or_b32 vop b32 b32 b32 b32
v_or3_b32 vop b32 b32 b32 b32
v_xor3_b32 vop b32 b32 b32 b32
v_xad_u32 vop b32 b32 b32 b32
v_mad_u32_u16 vop b32 b16 b16 b32
v_mad_i32_i16 vop b32 b16 b16 b32
v_pack_b32_f16 vop b32 f16 f16 -
v_cvt_pknorm_i16_f16 vop b32 f16 f16 -
v_cvt_pknorm_u16_f16 vop b32 f16 f16 -
v_permlane16_b32 vop b32 b32 b32 b32
v_permlanex16_b32 vop b32 b32 b32 b32
v_min3_f16 vop f16 f16 f16 f16
v_min3_i16 vop b16 b16 b16 b16
v_min3_u16 vop b16 b16 b16 b16
v_max3_f16 vop f16 f16 f16 f16
v_max3_i16 vop b16 b16 b16 b16
v_max3_u16 vop b16 b16 b16 b16
v_med3_f16 vop f16 f16 f16 f16
v_med3_i16 vop b16 b16 b16 b16
v_med3_u16 vop b16 b16 b16 b16
v_fma_legacy_f32 vop f32 f32 f32 f32
v_fma_legacy_f16 vop f16 f16 f16 f16
v_mad_legacy_f16 vop f16 f16 f16 f16
v_pipeflush vop_none - - - -
v_movrelsd_2_b32 vop b32 b32 - -
v_swap_b32 vop_swap b32 b32 - -
v_swaprel_b32 vop_swap b32 b32 - -
v_sat_pk_u8_i16 vop b32 b32 - -
v_cvt_norm_i16_f16 vop b16 f16 - -
v_cvt_norm_u16_f16 vop b16 f16 - -
v_interp_p1_f32 vintrp f32 f32 - -
v_interp_p2_f32 vintrp f32 f32 - -
v_interp_mov_f32 vintrp_mov f32 - - -
exp exp - - - -
buffer_load_ubyte_d16 buf_load b32 - - -
buffer_load_ubyte_d16_hi buf_load b32 - - -
buffer_load_sbyte_d16 buf_load b32 - - -
buffer_load_sbyte_d16_hi buf_load b32 - - -
buffer_load_short_d16 buf_load b32 - - -
buffer_load_short_d16_hi buf_load b32 - - -
buffer_load_format_d16_hi_x buf_load b32 - - -
buffer_store_byte_d16_hi buf_store b32 - - -
buffer_store_short_d16_hi buf_store b32 - - -
buffer_store_format_d16_hi_x buf_store b32 - - -
buffer_atomic_fcmpswap buf_atomic b64 - - -
buffer_atomic_fmin buf_atomic b32 - - -
buffer_atomic_fmax buf_atomic b32 - - -
buffer_atomic_fcmpswap_x2 buf_atomic b128 - - -
buffer_atomic_fmin_x2 buf_atomic b64 - - -
buffer_atomic_fmax_x2 buf_atomic b64 - - -
buffer_atomic_csub buf_atomic b32 - - -
buffer_gl0_inv buf_none - - - -
buffer_gl1_inv buf_none - - - -
"""

# packed d16 in gfx10: two halves per dword
D16 = {"x": "b32", "xy": "b32", "xyz": "b64", "xyzw": "b64"}

# gfx8 rows that are not part of this dialect's formats (DS and FLAT are not
# modelled), or whose meaning gfx10 changed
SKIP_PREFIX = ("ds_", "flat_")


def gcn3_rows():
    out = []
    with open(GCN3, encoding="utf-8") as f:
        for line in f:
            m = ROW.match(line)
            if not m:
                continue
            name, enc, _code, shape, d, s0, s1, s2, _e64 = m.groups()
            fam = FCONDS if "{f}" in name else ICONDS if "{i}" in name else None
            for c in fam or [None]:
                n = name.replace("{f}", c).replace("{i}", c) if c else name
                out.append(dict(name=n, enc=enc, shape=shape, d=d, s=[s0, s1, s2]))
    return out


def candidates():
    seen = set()
    out = []

    def add(c):
        if c["name"] in seen:
            return
        seen.add(c["name"])
        out.append(c)

    for r in gcn3_rows():
        n = r["name"]
        if n.startswith(SKIP_PREFIX):
            continue
        sh = r["shape"]
        if n in RENAME:
            n, sh = RENAME[n]
        if sh == "vopc" and n.startswith("v_cmpx"):
            sh = "vopcx"
        d, s = r["d"], list(r["s"])
        m = re.match(r"t?buffer_(load|store)_format_d16_(x|xy|xyz|xyzw)$", n)
        if m:
            d = D16[m.group(2)]
        if n == "v_cndmask_b32":
            s = ["f32", "f32", "none"]
        add(dict(name=n, shape=sh, d=d, s=s))
    for line in NEW.strip().splitlines():
        n, sh, d, s0, s1, s2 = line.split()
        fix = lambda t: "none" if t == "-" else t
        add(dict(name=n, shape=sh, d=fix(d), s=[fix(s0), fix(s1), fix(s2)]))
    for m in mimg_ops():
        add(m)
    return out


# ── MIMG ────────────────────────────────────────────────────────────────────

DIMS = ["1D", "2D", "3D", "CUBE", "1D_ARRAY", "2D_ARRAY", "2D_MSAA", "2D_MSAA_ARRAY"]
COORDS = [1, 2, 3, 3, 2, 3, 3, 4]
GRADS = [2, 4, 6, 4, 2, 4, 4, 4]
ATOMICS = ["swap", "cmpswap", "add", "sub", "smin", "umin", "smax", "umax", "and", "or", "xor", "inc", "dec", "fcmpswap", "fmin", "fmax"]


def sample_suffixes():
    out = []
    for c in ("", "_c"):
        for mid in ("", "_cl", "_d", "_d_cl", "_l", "_b", "_b_cl", "_lz", "_cd", "_cd_cl"):
            for o in ("", "_o"):
                out.append(c + mid + o)
    return out


def mimg_ops():
    out = []
    for n in ["image_load", "image_load_mip", "image_load_pck", "image_load_pck_sgn", "image_load_mip_pck", "image_load_mip_pck_sgn"]:
        out.append(dict(name=n, shape="mimg_load", d="none", s=["none"] * 3))
    for n in ["image_store", "image_store_mip", "image_store_pck", "image_store_mip_pck"]:
        out.append(dict(name=n, shape="mimg_store", d="none", s=["none"] * 3))
    out.append(dict(name="image_get_resinfo", shape="mimg_resinfo", d="none", s=["none"] * 3))
    for a in ATOMICS:
        out.append(dict(name="image_atomic_" + a, shape="mimg_atomic", d="none", s=["none"] * 3))
    for sfx in sample_suffixes():
        out.append(dict(name="image_sample" + sfx, shape="mimg_sample", d="none", s=["none"] * 3))
    for sfx in sample_suffixes():
        if "_d" in sfx or "_cd" in sfx:
            continue
        out.append(dict(name="image_gather4" + sfx, shape="mimg_gather", d="none", s=["none"] * 3))
    out.append(dict(name="image_gather4h", shape="mimg_gather", d="none", s=["none"] * 3))
    out.append(dict(name="image_get_lod", shape="mimg_sample", d="none", s=["none"] * 3))
    out.append(dict(name="image_msaa_load", shape="mimg_gather", d="none", s=["none"] * 3))
    out.append(dict(name="image_bvh_intersect_ray", shape="mimg_bvh", d="none", s=["none"] * 3))
    out.append(dict(name="image_bvh64_intersect_ray", shape="mimg_bvh", d="none", s=["none"] * 3))
    return out


def mimg_parts(name):
    """(extra args, coordinates?, gradients?, lod/clamp/mip?, sampler?)"""
    if name.startswith("image_bvh"):
        return None
    if name == "image_get_resinfo":
        return (0, False, False, True, False)
    if name == "image_msaa_load":
        return (0, True, False, False, False)
    if name.startswith(("image_load", "image_store", "image_atomic")):
        return (0, True, False, "_mip" in name, False)
    if name == "image_get_lod":
        return (0, True, False, False, True)
    base = "image_sample" if name.startswith("image_sample") else "image_gather4"
    toks = name[len(base):].split("_")[1:]
    extra = sum(1 for t in toks if t in ("c", "o", "b"))
    grads = "d" in toks or "cd" in toks
    lod = "l" in toks or "cl" in toks
    return (extra, True, grads, lod, True)


def mimg_addrs(name, dim, a16):
    extra, coords, grads, lod, _ = mimg_parts(name)
    comps = (COORDS[dim] if coords else 0) + (1 if lod else 0)
    n = extra + ((comps + 1) // 2 if a16 else comps)
    if grads:
        # gfx1013 has no 16-bit gradients: a16 packs only the coordinates
        n += GRADS[dim]
    return n


def vrange(first, n):
    return f"v{first}" if n == 1 else f"v[{first}:{first + n - 1}]"


def mimg_lines(c, k):
    n, sh = c["name"], c["shape"]
    out = []
    if sh == "mimg_bvh":
        na = 11 if n == "image_bvh_intersect_ray" else 12
        out.append(f"{n} v[4:7], {vrange(9, na)}, s[4:7]")
        out.append(f"{n} v[4:7], [" + ", ".join(f"v{9 + 2 * i}" for i in range(na)) + "], s[4:7]")
        out.append(f"{n} v[4:7], {vrange(20, na - 3)}, s[8:11] a16")
        out.append(f"{n} v[4:7], [" + ", ".join(f"v{30 - i}" for i in range(na - 3)) + "], s[8:11] a16")
        return out
    sampler = mimg_parts(n)[4]
    samp = ", s[96:99]" if sampler else ""
    dims = list(range(8))
    if sh == "mimg_gather":
        dims = [1, 3, 5] if n != "image_msaa_load" else [6, 7]
    elif sh in ("mimg_sample",):
        dims = [0, 1, 2, 3, 4, 5]
    elif "mip" in n:
        dims = [0, 1, 2, 3, 4, 5]
    for j, dim in enumerate(dims):
        na = mimg_addrs(n, dim, False)
        if na > 12:
            na_r = 16
        else:
            na_r = na
        dmask = [0xf, 0x1, 0x3, 0x5, 0x8, 0xe, 0x7, 0xb][(k + j) % 8]
        if sh == "mimg_atomic":
            dmask = 0x3 if "cmpswap" in n else 0x1
        if sh == "mimg_gather":
            dmask = [1, 2, 4, 8][(k + j) % 4]
        nd = 4 if sh == "mimg_gather" else bin(dmask).count("1")
        d0 = (k * 3 + j * 5) % 200
        a0 = (k + j * 7) % 230 + 1
        r0 = 4 * ((k + j) % 20)
        flags = ["", " unorm", " glc", " slc", " dlc", " glc slc dlc", " r128", " unorm glc"][(k + j) % 8]
        if sh == "mimg_atomic" and "glc" not in flags:
            flags = " glc" if j % 2 == 0 else flags
        dm = f" dmask:0x{dmask:x}"
        dimt = f" dim:SQ_RSRC_IMG_{DIMS[dim]}"
        out.append(f"{n} {vrange(d0, nd)}, {vrange(a0, na_r)}, s[{r0}:{r0 + 7}]{samp}{dm}{dimt}{flags}")
        if na > 1:
            regs = [f"v{(a0 + 3 * i + j) % 256}" for i in range(na)]
            out.append(f"{n} {vrange(d0, nd)}, [{', '.join(regs)}], s[{r0}:{r0 + 7}]{samp}{dm}{dimt}")
        # tfe/lwe add a dword; d16 halves the data
        if sh in ("mimg_load", "mimg_sample", "mimg_gather") and j < 2:
            out.append(f"{n} {vrange(d0, nd + 1)}, {vrange(a0, na_r)}, s[8:15]{samp}{dm}{dimt} tfe")
            out.append(f"{n} {vrange(d0, nd + 1)}, {vrange(a0, na_r)}, s[8:15]{samp}{dm}{dimt} lwe")
            out.append(f"{n} {vrange(d0, (nd + 1) // 2)}, {vrange(a0, na_r)}, s[8:15]{samp}{dm}{dimt} d16")
            out.append(f"{n} {vrange(d0, (nd + 1) // 2 + 1)}, {vrange(a0, na_r)}, s[8:15]{samp}{dm}{dimt} d16 tfe")
        if sh == "mimg_store" and j < 2:
            out.append(f"{n} {vrange(d0, (nd + 1) // 2)}, {vrange(a0, na_r)}, s[8:15]{dm}{dimt} d16")
        if j < 3:
            na16 = mimg_addrs(n, dim, True)
            na16_r = 16 if na16 > 12 else na16
            out.append(f"{n} {vrange(d0, nd)}, {vrange(a0, na16_r)}, s[16:23]{samp}{dm}{dimt} a16")
            if na16 > 1:
                regs = [f"v{(a0 + 2 * i) % 256}" for i in range(na16)]
                out.append(f"{n} {vrange(d0, nd)}, [{', '.join(regs)}], s[16:23]{samp}{dm}{dimt} a16")
    if sh == "mimg_store":
        pass
    return out


# ── Lines per candidate ─────────────────────────────────────────────────────


def vr(n, t):
    w = max(DWORDS[t], 1)
    return f"v{n}" if w == 1 else f"v[{n}:{n + w - 1}]"


def sr(n, t):
    w = max(DWORDS[t], 1)
    if w == 1:
        return f"s{n}"
    align = 2 if w == 2 else 4
    n = (n // align) * align
    if n + w > 106:
        n = 0
    return f"s[{n}:{n + w - 1}]"


def isfloat(t):
    return t in ("f16", "f32", "f64")


def const_for(t, k):
    if t in ("f64", "b64"):
        return ["-3", "0.5", "-4.0", "64"][k % 4]
    if t == "f16":
        return ["-16", "1.0", "0.15915494", "-2.0"][k % 4]
    if t == "b16":
        return ["17", "-1", "0.5", "4.0"][k % 4]
    return ["7", "-0.5", "2.0", "0.15915494"][k % 4]


def literal_for(t):
    if t in ("f16", "b16"):
        return "0x1234"
    return "0x12345678"


def lines_for(c, k):
    """(kind, line) pairs for one candidate; k varies the registers."""
    n, sh, d, s = c["name"], c["shape"], c["d"], c["s"]
    a, b, cc = 1 + k % 7, 9 + k % 11, 20 + k % 13
    nsrc = sum(1 for t in s if t != "none")
    out = []
    B = lambda x: out.append(("base", x))
    if sh == "sop2":
        B(f"{n} {sr(a * 2, d)}, {sr(b * 2, s[0])}, {sr(cc * 2, s[1])}")
        B(f"{n} {sr(cc, d)}, {const_for(s[0], k)}, {literal_for(s[1])}")
        sp = "exec" if DWORDS[s[0]] == 2 else "m0"
        B(f"{n} {sr(a, d)}, {sp}, {const_for(s[1], k + 1)}")
        if DWORDS[d] == 1:
            B(f"{n} null, {sr(b, s[0])}, {sr(104, s[1])}")
        else:
            B(f"{n} vcc, {sr(b * 2, s[0])}, {sr(100, s[1])}")
    elif sh == "sop1":
        B(f"{n} {sr(a * 2, d)}, {sr(b * 2, s[0])}")
        B(f"{n} {sr(cc, d)}, {literal_for(s[0])}")
        sp = "vcc" if DWORDS[s[0]] == 2 else "vcc_hi"
        B(f"{n} {sr(a + 4, d)}, {sp}")
        B(f"{n} {sr(b, d)}, {const_for(s[0], k + 2)}")
        B(f"{n} {'exec' if DWORDS[d] == 2 else 'exec_lo'}, {sr(104, s[0])}")
    elif sh == "sop1_dst":
        B(f"{n} {sr(a * 2, d)}")
    elif sh == "sop1_src":
        B(f"{n} {sr(b * 2, s[0])}")
    elif sh == "sopc":
        B(f"{n} {sr(a * 2, s[0])}, {sr(b * 2, s[1])}")
        B(f"{n} {const_for(s[0], k)}, {literal_for(s[1])}")
        B(f"{n} {'exec' if DWORDS[s[0]] == 2 else 'm0'}, {sr(104, s[1])}")
    elif sh == "sopk":
        B(f"{n} s{a}, 0x{(0x1234 + k * 0x111) & 0xffff:x}")
        B(f"{n} s{cc}, 0xfffe")
        B(f"{n} null, 0x0")
    elif sh == "sopk_imm":
        B(f"{n} 0x{(0x1234 + k * 0x111) & 0xffff:x}")
        B(f"{n} 0x0")
    elif sh == "sopk_branch":
        B(f"{n} {sr(a * 2, d)}, {5 + k}")
        B(f"{n} {sr(b * 2, d)}, -{3 + k}")
    elif sh == "sopk_getreg":
        B(f"{n} s{a}, hwreg(HW_REG_TRAPSTS)")
        B(f"{n} s{b}, hwreg(HW_REG_HW_ID, 8, 4)")
    elif sh == "sopk_setreg":
        B(f"{n} hwreg(HW_REG_MODE, 4, 8), s{a}")
    elif sh == "sopk_setreg_imm":
        B(f"{n} hwreg(HW_REG_MODE, 0, 4), 0x1234")
        B(f"{n} hwreg(HW_REG_STATUS), 5")
    elif sh == "sopp":
        B(n)
    elif sh == "sopp_imm":
        for x in (0, 1, 3, 15, 64, 65, 0x80, 0xff, 0x1234, 0xffff):
            B(f"{n} 0x{x:x}")
    elif sh == "sopp_branch":
        B(f"{n} {5 + k}")
        B(f"{n} -{3 + k}")
    elif sh in ("sopp_waitcnt", "sopp_sendmsg"):
        pass  # the extras cover them
    elif sh in ("smem_load", "smem_store"):
        B(f"{n} {sr((a * 4) % 80, d)}, {sr(b * 2, s[0])}, 0x{0x40 + 4 * k:x}")
        B(f"{n} {sr((cc * 4) % 80, d)}, {sr(a * 4, s[0])}, s{b} glc")
        B(f"{n} {sr((b * 4) % 80, d)}, {sr(cc * 4, s[0])}, s{a} offset:0x{0x10 + k:x} dlc")
        B(f"{n} {sr((a * 4) % 80, d)}, {sr(b * 4, s[0])}, -0x{0x8 + k:x} glc dlc")
        B(f"{n} {sr((a * 4) % 80, d)}, {sr(b * 4, s[0])}, m0")
    elif sh == "smem_none":
        B(n)
    elif sh == "smem_time":
        B(f"{n} {sr(a * 2, d)}")
    elif sh == "vop_none":
        B(n)
    elif sh == "vop_swap":
        B(f"{n} v{a}, v{b}")
    elif sh == "vop_sdst":
        if nsrc == 1:
            B(f"{n} s{a}, v{b}")
            B(f"{n} vcc_lo, v{cc}")
        else:
            B(f"{n} s{a}, v{b}, s{cc}")
            B(f"{n} m0, v{b}, {13 + k % 40}")
            B(f"{n} s{a}, v{b}, m0")
    elif n == "v_writelane_b32":
        out += [("base", f"{n} v{a}, s{b}, {k % 32}"), ("base", f"{n} v{cc}, s{a}, s{a}"), ("base", f"{n} v{b}, 1.0, s{cc}"), ("base", f"{n} v{a}, 0x1234, 7")]
    elif n in ("v_permlane16_b32", "v_permlanex16_b32"):
        out += [("base", f"{n} v{a}, v{b}, s{cc}, s{a}"), ("base", f"{n} v{cc}, v{a}, 1, 0x1234"), ("base", f"{n} v{a}, v{b}, s{cc}, s{a} op_sel:[1,0]"), ("base", f"{n} v{a}, v{b}, s{cc}, s{a} op_sel:[0,1]")]
    elif sh == "vop":
        out += vop_lines(c, k)
    elif sh == "vop_carry":
        B(f"{n} v{a}, s{b}, v{b}, v{cc}")
        B(f"{n} v{cc}, vcc_lo, s{a}, v{b}")
        B(f"{n} v{b}, s{a}, {const_for('b32', k)}, s{cc}")
        B(f"{n} v{a}, null, {literal_for('b32')}, v{cc}")
        out.append(("clamp", f"{n} v{a}, s{b}, v{b}, v{cc} clamp"))
        out.append(("w64", f"{n} v{a}, s[{2 * a}:{2 * a + 1}], v{b}, v{cc}"))
        out.append(("w64", f"{n} v{a}, vcc, s{b}, {const_for('b32', k)}"))
    elif sh == "vop_carry_in":
        B(f"{n}_e32 v{a}, vcc_lo, v{b}, v{cc}, vcc_lo")
        B(f"{n}_e32 v{cc}, vcc_lo, {const_for('b32', k)}, v{b}, vcc_lo")
        B(f"{n}_e32 v{cc}, vcc_lo, {literal_for('b32')}, v{b}, vcc_lo")
        out.append(("e64", f"{n}_e64 v{a}, s{a}, v{b}, v{cc}, s{b}"))
        out.append(("e64", f"{n}_e64 v{b}, vcc_lo, 0, s{cc}, vcc_lo"))
        out.append(("e64", f"{n}_e64 v{b}, vcc_lo, 0x1234, v{cc}, null"))
        out.append(("clamp", f"{n}_e64 v{b}, s{cc}, v{a}, v{cc}, s{a} clamp"))
        out.append(("w64", f"{n}_e32 v{a}, vcc, v{b}, v{cc}, vcc"))
        out.append(("w64", f"{n}_e64 v{a}, s[{2 * a}:{2 * a + 1}], v{b}, v{cc}, s[{2 * b}:{2 * b + 1}]"))
    elif sh == "vop_cndmask":
        B(f"{n}_e32 v{a}, v{b}, v{cc}, vcc_lo")
        B(f"{n}_e32 v{cc}, {const_for('b32', k)}, v{b}, vcc_lo")
        B(f"{n}_e32 v{b}, {literal_for('b32')}, v{a}, vcc_lo")
        out.append(("e64", f"{n}_e64 v{a}, v{b}, s{cc}, s{a}"))
        out.append(("e64", f"{n}_e64 v{b}, 0, -1, vcc_lo"))
        out.append(("e64", f"{n}_e64 v{b}, 0x1234, v{a}, s{cc}"))
        out.append(("neg", f"{n}_e64 v{b}, -v{a}, |v{cc}|, s{b}"))
        out.append(("w64", f"{n}_e32 v{a}, v{b}, v{cc}, vcc"))
        out.append(("w64", f"{n}_e64 v{a}, v{b}, s{cc}, s[{2 * a}:{2 * a + 1}]"))
    elif sh in ("vop_madmk", "vop_madak"):
        K = "0x4900" if d == "f16" else "0x41200000"
        if sh == "vop_madmk":
            B(f"{n} v{a}, v{b}, {K}, v{cc}")
            B(f"{n} v{cc}, {const_for(s[0], k)}, {K}, v{b}")
            B(f"{n} v{cc}, s{a}, {K}, v{b}")
        else:
            B(f"{n} v{a}, v{b}, v{cc}, {K}")
            B(f"{n} v{cc}, s{a}, v{b}, {K}")
            B(f"{n} v{cc}, {const_for(s[0], k)}, v{b}, {K}")
    elif sh in ("vopc", "vopcx"):
        dst = "vcc_lo, " if sh == "vopc" else ""
        B(f"{n}_e32 {dst}{vr(a, s[0])}, {vr(b, s[1])}")
        B(f"{n}_e32 {dst}{sr(cc * 2, s[0])}, {vr(a, s[1])}")
        B(f"{n}_e32 {dst}{const_for(s[0], k)}, {vr(cc, s[1])}")
        B(f"{n}_e32 {dst}{literal_for(s[0])}, {vr(cc, s[1])}")
        d64 = f"s{a}, " if sh == "vopc" else ""
        out.append(("e64", f"{n}_e64 {d64}{vr(b, s[0])}, {sr(cc * 2, s[1])}"))
        out.append(("e64", f"{n}_e64 {d64}{const_for(s[0], k + 1)}, {literal_for(s[1])}"))
        if sh == "vopc":
            out.append(("e64", f"{n}_e64 null, {vr(b, s[0])}, {vr(a, s[1])}"))
        if isfloat(s[0]):
            m1 = f"|{vr(a, s[1])}|" if isfloat(s[1]) else vr(a, s[1])
            out.append(("neg", f"{n}_e64 {d64}-{vr(cc, s[0])}, {m1}"))
            out.append(("clamp", f"{n}_e64 {d64}{vr(cc, s[0])}, {vr(a, s[1])} clamp"))
        if sh == "vopc":
            out.append(("w64", f"{n}_e32 vcc, {vr(a, s[0])}, {vr(b, s[1])}"))
            out.append(("w64", f"{n}_e64 s[{2 * a}:{2 * a + 1}], {vr(b, s[0])}, {sr(cc * 2, s[1])}"))
    elif sh == "vop3b":
        regs = [vr(b, s[0]), vr(cc, s[1]), vr(a + 30, s[2])]
        B(f"{n} {vr(a, d)}, vcc_lo, " + ", ".join(regs))
        B(f"{n} {vr(cc, d)}, s{a}, {sr(b * 2, s[0])}, {vr(cc, s[1])}, {const_for(s[2], k)}")
        B(f"{n} {vr(cc, d)}, s{a}, {vr(b, s[0])}, {literal_for(s[1])}, {vr(a, s[2])}")
        if isfloat(s[0]):
            out.append(("neg", f"{n} {vr(b, d)}, s{cc}, -{vr(b, s[0])}, {vr(cc, s[1])}, -{vr(a, s[2])}"))
        out.append(("clamp", f"{n} {vr(b, d)}, s{cc}, {vr(b, s[0])}, {vr(cc, s[1])}, {vr(a, s[2])} clamp"))
        out.append(("omod", f"{n} {vr(b, d)}, s{cc}, {vr(b, s[0])}, {vr(cc, s[1])}, {vr(a, s[2])} mul:2"))
        out.append(("w64", f"{n} {vr(a, d)}, s[{2 * a}:{2 * a + 1}], " + ", ".join(regs)))
    elif sh == "vintrp":
        for i in range(4):
            ch = "xyzw"[(k + i) % 4]
            B(f"{n} v{(a * 37 + i * 61) % 256}, v{(b + 7 * i) % 256}, attr{(k + 5 * i) % 33}.{ch}")
        B(f"{n} v255, v255, attr63.w")
        B(f"{n} v0, v0, attr0.x")
    elif sh == "vintrp_mov":
        for i, p in enumerate(["p10", "p20", "p0"]):
            B(f"{n} v{(a * 37 + i * 61) % 256}, {p}, attr{(k + 11 * i) % 33}.{'xyzw'[(k + i) % 4]}")
        B(f"{n} v255, p0, attr63.w")
    elif sh == "exp":
        pass  # the extras cover it
    elif sh in ("buf_load", "buf_store", "buf_atomic"):
        dv = vr(a, d)
        mt = n.startswith("tbuffer")
        fmt = " format:[BUF_FMT_32_FLOAT]" if mt else ""
        fmt2 = " format:[BUF_FMT_8_8_8_8_UNORM]" if mt else ""
        B(f"{n} {dv}, off, s[8:11], s{b}{fmt}")
        B(f"{n} {dv}, v{cc}, s[4:7], 0 offen offset:{4095 - k}")
        B(f"{n} {dv}, v{b}, s[12:15], s{cc}{fmt2} idxen offset:{4 * k} glc slc")
        # (LLVM takes dlc on an atomic but does not encode it)
        dlc = "" if sh == "buf_atomic" else " dlc"
        B(f"{n} {dv}, v[{cc}:{cc + 1}], s[16:19], m0 idxen offen{dlc}")
        B(f"{n} {dv}, off, s[100:103], null offset:16 glc slc{dlc}")
        wider = {1: "b64", 2: "b96", 3: "b128"}.get(DWORDS[d])
        if sh == "buf_load" and wider:
            B(f"{n} {vr(a, wider)}, off, s[4:7], 64 tfe")
            B(f"{n} {vr(a, wider)}, v{b}, s[4:7], s1 idxen glc slc dlc tfe")
        B(f"{n} {dv}, off, s[4:7], -1")
        B(f"{n} {dv}, off, s[4:7], 0.5")
    elif sh == "buf_none":
        B(n)
    elif sh.startswith("mimg"):
        out += [("base", x) for x in mimg_lines(c, k)]
    else:
        raise SystemExit(f"no template for shape {sh} ({n})")
    return out


def vop_lines(c, k):
    """A VOP1/VOP2/VOP3 operation with plain sources: the bare name (LLVM picks
    the short form), the _e64 form, and each modifier on its own."""
    n, d, s = c["name"], c["d"], c["s"]
    a, b, cc = 1 + k % 7, 9 + k % 11, 20 + k % 13
    nsrc = sum(1 for t in s if t != "none")
    out = []
    regs = [vr(b, s[0]), vr(cc, s[1]), vr(a + 30, s[2])][:nsrc]
    out.append(("base", f"{n} {vr(a, d)}, " + ", ".join(regs)))
    mixed = [sr(b * 2, s[0]), vr(cc, s[1]), vr(a + 40, s[2])][:nsrc]
    out.append(("base", f"{n} {vr(cc, d)}, " + ", ".join(mixed)))
    consts = [const_for(s[0], k), vr(b, s[1]), vr(cc, s[2])][:nsrc]
    out.append(("base", f"{n} {vr(a + 1, d)}, " + ", ".join(consts)))
    lits = [literal_for(s[0]), vr(cc, s[1]), vr(b, s[2])][:nsrc]
    out.append(("base", f"{n} {vr(b + 1, d)}, " + ", ".join(lits)))
    if nsrc == 1:
        out.append(("base", f"{n} {vr(a + 2, d)}, {'vcc_hi' if DWORDS[s[0]] == 1 else 'vcc'}"))
    # the VOP3 form (rejected for VOP3-only rows, which the base lines cover)
    e = n + "_e64"
    srcs = [vr(b, s[0]), sr(cc * 2, s[1]), const_for(s[2], k)][:nsrc]
    out.append(("e64", f"{e} {vr(a, d)}, " + ", ".join(srcs)))
    if nsrc >= 2:
        srcs = [sr(cc * 2, s[0]), literal_for(s[1]), vr(a, s[2])][:nsrc]
        out.append(("e64", f"{e} {vr(cc, d)}, " + ", ".join(srcs)))
        out.append(("base", f"{n} {vr(cc, d)}, " + ", ".join(srcs)))
    else:
        out.append(("e64", f"{e} {vr(cc, d)}, {sr(b * 2, s[0])}"))
    plain = [vr(b, s[0]), vr(cc, s[1]), vr(a, s[2])][:nsrc]
    for name in (n, e):
        out.append(("clamp", f"{name} {vr(a, d)}, " + ", ".join(plain) + " clamp"))
        out.append(("omod", f"{name} {vr(a, d)}, " + ", ".join(plain) + " mul:2"))
        out.append(("omod", f"{name} {vr(a, d)}, " + ", ".join(plain) + " div:2"))
        fl = [i for i in range(nsrc) if isfloat(s[i])]
        if fl:
            m = list(plain)
            for i in fl:
                m[i] = [f"-{plain[i]}", f"|{plain[i]}|", f"-|{plain[i]}|"][(i + k) % 3]
            out.append(("neg", f"{name} {vr(cc, d)}, " + ", ".join(m)))
            m = list(plain)
            m[fl[0]] = f"neg({const_for(s[fl[0]], k + 1)})"
            out.append(("neg", f"{name} {vr(b, d)}, " + ", ".join(m)))
        sel = ",".join(["1" if i == (k % (nsrc + 1)) else "0" for i in range(nsrc + 1)])
        out.append(("opsel", f"{name} {vr(a, d)}, " + ", ".join(plain) + f" op_sel:[{sel}]"))
    return out


# ── Lines that sweep one field ──────────────────────────────────────────────

EXP_TARGETS = [f"mrt{i}" for i in range(8)] + ["mrtz", "null"] + [f"pos{i}" for i in range(5)] + ["prim"] + [f"param{i}" for i in range(32)]


def extras():
    out = []
    for x in range(-16, 65):
        out.append(f"v_mov_b32 v1, {x}")
        out.append(f"s_mov_b32 s1, {x}")
    for f in ["0.5", "-0.5", "1.0", "-1.0", "2.0", "-2.0", "4.0", "-4.0", "0.15915494"]:
        out.append(f"v_mul_f32 v2, {f}, v3")
        out.append(f"v_mul_f16 v2, {f}, v3")
        out.append(f"s_mov_b32 s2, {f}")
        f64 = f if f != "0.15915494" else "0.15915494309189532"
        out.append(f"v_mul_f64 v[2:3], {f64}, v[4:5]")
        out.append(f"s_mov_b64 s[2:3], {f64}")
    for lit in ["0x41", "0xffffffef", "0x80000000", "0x3f800001", "0x7fffffff"]:
        out.append(f"v_mov_b32 v5, {lit}")
        out.append(f"s_add_u32 s5, s6, {lit}")
        out.append(f"v_fma_f32 v1, {lit}, v2, {lit}")
        out.append(f"v_add_f32_e64 v1, -|{lit}|, v2")
    specials = ["vcc_lo", "vcc_hi", "exec_lo", "exec_hi", "m0", "null", "src_scc", "src_vccz", "src_execz",
                "src_shared_base", "src_shared_limit", "src_private_base", "src_private_limit", "src_pops_exiting_wave_id"] + [f"ttmp{i}" for i in range(16)] + ["s105", "s0"]
    for reg in specials:
        out.append(f"v_mov_b32 v7, {reg}")
        out.append(f"s_mov_b32 s7, {reg}")
        out.append(f"v_add_f32_e64 v7, {reg}, v1")
    out.append("v_mov_b32 v7, src_lds_direct")
    for reg in ["vcc", "exec", "ttmp[0:1]", "ttmp[14:15]", "s[104:105]", "null", "src_shared_base", "src_private_limit"]:
        out.append(f"s_mov_b64 s[8:9], {reg}")
        out.append(f"v_add_f64 v[0:1], {reg}, v[2:3]")
        if reg not in ("src_shared_base", "src_private_limit"):
            out.append(f"s_mov_b64 {reg}, s[8:9]")
    for dst in ["vcc_lo", "vcc_hi", "exec_lo", "exec_hi", "m0", "null", "ttmp5", "ttmp15"]:
        out.append(f"s_mov_b32 {dst}, s3")
    out += ["v_mov_b32 v0, v255", "v_mov_b32 v255, v0", "v_add_f64 v[0:1], v[254:255], v[2:3]"]
    out += ["s_load_dwordx16 s[88:103], s[100:101], 0xfffff", "s_load_dwordx2 vcc, s[2:3], 0x0", "s_load_dword m0, s[2:3], 0x4",
            "s_load_dword s3, s[4:5], m0", "s_load_dwordx4 ttmp[4:7], ttmp[2:3], 0x10", "s_load_dword s3, s[4:5], -0x100000",
            "s_load_dword s3, s[4:5], 0xfffff", "s_load_dword null, s[4:5], 0x0",
            "s_buffer_load_dwordx4 s[4:7], s[8:11], s3 offset:0x40 glc dlc"]
    for i in range(64):
        out.append(f"s_getreg_b32 s0, hwreg({i})")
    out += ["s_getreg_b32 s1, hwreg(HW_REG_MODE, 31, 1)", "s_getreg_b32 s1, hwreg(HW_REG_GPR_ALLOC, 0, 31)",
            "s_setreg_b32 hwreg(HW_REG_IB_STS), s2", "s_setreg_b32 hwreg(HW_REG_LDS_ALLOC, 1, 2), s2",
            "s_setreg_imm32_b32 hwreg(HW_REG_MODE, 0, 4), 0x1234"]
    for w in ["0", "vmcnt(0)", "expcnt(0)", "lgkmcnt(0)", "vmcnt(0) lgkmcnt(0)", "vmcnt(3) expcnt(2) lgkmcnt(1)",
              "vmcnt(63) expcnt(7) lgkmcnt(63)", "vmcnt(62)", "expcnt(6)", "lgkmcnt(62)", "vmcnt(16) lgkmcnt(5)",
              "vmcnt(40) lgkmcnt(50)", "expcnt(1) lgkmcnt(0)", "vmcnt(15)", "lgkmcnt(15)"]:
        out.append(f"s_waitcnt {w}")
    for x in [0, 1, 7, 0x7f, 0xff, 0x100, 0x7fff, 0x8000, 0xffff]:
        out.append(f"s_nop {x & 0xf}")
        out.append(f"s_trap {x & 0xff}")
        out.append(f"s_setprio {x & 3}")
        out.append(f"s_sleep {x & 0x7f}")
    for x in [-32768, -1, 0, 1, 32767]:
        out.append(f"s_branch {x}")
        out.append(f"s_cbranch_execz {x}")
    for x in range(0, 1024):
        out.append(f"s_sendmsg {x}")
    for x in [0x1000, 0x8000, 0xffff, 0x403]:
        out.append(f"s_sendmsg {x}")
        out.append(f"s_sendmsghalt {x}")
    for x in range(0, 64, 3):
        out.append(f"s_sendmsghalt {x}")
    for fmt in range(128):
        out.append(f"tbuffer_load_format_x v1, off, s[4:7], s1 format:{fmt}")
    # EXP: every target, enable masks, done, vm, compr
    for i, t in enumerate(EXP_TARGETS):
        en = [0xf, 0x1, 0x3, 0x5, 0x8, 0xe, 0x0, 0x7][i % 8]
        regs = [f"v{(i * 7 + j * 3) % 256}" if en >> j & 1 else "off" for j in range(4)]
        flags = ["", " done", " vm", " done vm"][i % 4]
        out.append(f"exp {t} {', '.join(regs)}{flags}")
        out.append(f"exp {t} v{i}, v{i + 1}, v{i + 2}, v{i + 3} done")
    for t in ["mrt0", "mrtz", "mrt7", "pos0", "param3"]:
        out.append(f"exp {t} v1, v2, off, off compr")
        out.append(f"exp {t} off, off, v3, v4 compr done vm")
        out.append(f"exp {t} v5, v6, v7, v8 compr")
        out.append(f"exp {t} v5, off, v7, off compr")
    out.append("exp mrt0 off, off, off, off")
    out.append("exp mrt0 v255, v254, v253, v252 done vm")
    # VOP3: literals, modifiers, special operands
    out += ["v_fma_f32 v0, s1, s1, v2", "v_fma_f32 v0, -|s1|, -s1, |v2| clamp div:2", "v_mad_f32 v10, neg(1.0), v2, neg(0.5)",
            "v_add_f32_e64 v0, |0.5|, -|-4.0|", "v_add_f32_e64 v0, neg(64), v2", "v_med3_i32 v0, -16, 64, s5",
            "v_cmp_eq_f32_e64 s100, -|v1|, |v2|", "v_cmp_gt_u32_e64 ttmp2, s1, v2", "v_cmp_lt_f32_e64 exec_lo, v1, v2",
            "v_readlane_b32 m0, v255, m0", "v_readfirstlane_b32 exec_lo, v255", "v_writelane_b32 v255, m0, 31",
            "v_mbcnt_hi_u32_b32 v1, exec_hi, v1", "v_mbcnt_lo_u32_b32 v1, exec_lo, 0",
            "v_div_scale_f32 v1, vcc_lo, v2, v2, v3", "v_div_fmas_f32 v1, v2, v3, v4", "v_div_fixup_f32 v1, v2, v3, v4",
            "v_mad_u64_u32 v[2:3], s0, v4, v5, 0", "v_mov_b32_e64 v1, src_scc", "v_mov_b32_e64 v1, vcc_hi",
            "v_add_co_u32 v1, s2, s4, 1.0", "v_fma_f32 v1, v2, 0x12345678, 0x12345678", "v_fma_f32 v1, 0x40490fdb, s2, 0x40490fdb",
            "v_fma_f64 v[1:2], 0x40490000, v[2:3], v[4:5]", "v_add_f16_e64 v1, 0x1234, v2", "v_lshlrev_b64 v[2:3], 0x40, v[4:5]",
            "v_add_nc_u16 v1, v2, v3 op_sel:[0,0,1]", "v_mad_u16 v1, v2, v3, v4 op_sel:[1,1,1,1]", "v_fma_f16 v1, v2, v3, v4 op_sel:[0,1,0,0]",
            "v_cvt_f32_f16_e64 v1, |v2|", "v_cvt_f16_f32_e64 v1, -v2 clamp", "v_cndmask_b32_e64 v1, 1.0, -2.0, s3",
            "v_add_f32_e64 v1, src_shared_base, v2", "v_mov_b32_e64 v1, null", "v_add_nc_u32_e64 v1, v2, v3 clamp",
            "v_mad_u16 v1, v2, v3, v4 op_sel:[1,0,0,0] clamp", "v_fma_f16 v1, -v2, |v3|, v4 op_sel:[1,0,1,1] clamp",
            "v_fma_f16 v1, v2, v3, v4 op_sel:[0,0,0,1] mul:2", "v_add_f32_e64 v1, -v2, 0.5 clamp mul:4",
            "exp mrt0 v1, v1, v2, v2 compr done vm", "exp mrt1 v1, v1, off, off compr done", "exp pos1 off, off, v2, v2 compr vm",
            "image_sample v[0:4], v1, s[8:15], s[12:15] dmask:0xf dim:SQ_RSRC_IMG_2D unorm glc slc dlc r128 a16 tfe", "exp mrt1 v1, v1, off, off done compr vm",
            "image_sample v[0:2], v[1:2], s[8:15], s[12:15] dmask:0xf dim:SQ_RSRC_IMG_2D unorm glc slc dlc r128 lwe d16",
            "image_load v[0:2], [v1, v2, v3], s[8:15] dmask:0xf dim:SQ_RSRC_IMG_3D unorm glc slc dlc r128 tfe d16",
            "buffer_load_dword v[1:2], v[2:3], s[4:7], s1 idxen offen offset:4095 glc slc dlc tfe",
            "tbuffer_load_format_xyzw v[1:5], v[2:3], s[4:7], s1 format:[BUF_FMT_32_32_32_32_FLOAT] idxen offen offset:4095 glc slc dlc tfe",
            "s_load_dword s1, s[2:3], s4 offset:-0x10", "s_load_dword s1, s[2:3], s4 offset:0xfffff glc dlc",
            "v_fmamk_f32 v1, v2, 0x3f800000, v3", "v_fmaak_f32 v1, 1.0, v3, 0x1", "v_madmk_f32 v1, 0x41200000, 0x41200000, v3"]
    # wave64: the mask operands in SGPR pairs
    w64 = ["v_cmp_eq_f32_e64 s[100:101], -|v1|, |v2|", "v_cmp_lt_f32_e64 exec, v1, v2", "v_cmp_gt_u32_e64 ttmp[2:3], s1, v2",
           "v_div_scale_f64 v[1:2], s[4:5], v[2:3], v[2:3], v[4:5]", "v_mad_u64_u32 v[2:3], s[0:1], v4, v5, 0",
           "v_cndmask_b32_e64 v1, 0, 1, s[4:5]", "v_add_co_ci_u32_e64 v1, s[2:3], v2, v3, vcc", "v_cmp_class_f32_e64 null, v1, v2"]
    return out, w64


# ── LLVM ────────────────────────────────────────────────────────────────────


def run_llvm(lines, scratch, cpu=CPU, wave64=False):
    src = os.path.join(scratch, "in.s")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    cmd = ["zig", "clang", "-cc1as", "-triple", "amdgcn-amd-amdhsa", "-target-cpu", cpu]
    if wave64:
        cmd += ["-target-feature", "+wavefrontsize64", "-target-feature", "-wavefrontsize32"]
    cmd += ["-show-encoding", "-filetype", "asm", src, "-o", "-"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    bad = set()
    for m in re.finditer(r"in\.s:(\d+):\d+: error", p.stderr):
        bad.add(int(m.group(1)) - 1)
    enc = []
    for line in p.stdout.splitlines():
        if "; encoding:" not in line:
            continue
        text, bs = line.split("; encoding:")
        bs = [int(x, 16) for x in bs.strip().strip("[]").split(",")]
        while len(bs) % 4:
            bs.append(0)
        words = [bs[i] | bs[i + 1] << 8 | bs[i + 2] << 16 | bs[i + 3] << 24 for i in range(0, len(bs), 4)]
        enc.append((" ".join(text.split()), words))
    return bad, enc


def assemble(lines, scratch, cpu=CPU, wave64=False):
    """Accepted line indexes and their (text, words)."""
    bad, _ = run_llvm(lines, scratch, cpu, wave64)
    good = [i for i in range(len(lines)) if i not in bad]
    bad2, enc = run_llvm([lines[i] for i in good], scratch, cpu, wave64)
    if bad2 or len(enc) != len(good):
        raise SystemExit(f"LLVM's second pass disagrees: {len(bad2)} errors, {len(enc)} of {len(good)} encodings")
    return good, enc


def sdwa_or_dpp(w):
    """A VOP1/VOP2/VOPC word whose src0 says SDWA or DPP follows."""
    return w[0] >> 31 == 0 and (w[0] & 0x1ff) in (0xf9, 0xfa, 0xe9, 0xea)


def classify(w):
    """(encoding, opcode) of an instruction's first words."""
    w0 = w[0]
    if w0 >> 31 == 0:
        hi7 = w0 >> 25
        if hi7 == 0x3f:
            return "vop1", (w0 >> 9) & 0xff
        if hi7 == 0x3e:
            return "vopc", (w0 >> 17) & 0xff
        return "vop2", hi7
    if w0 >> 23 == 0x17d:
        return "sop1", (w0 >> 8) & 0xff
    if w0 >> 23 == 0x17e:
        return "sopc", (w0 >> 16) & 0x7f
    if w0 >> 23 == 0x17f:
        return "sopp", (w0 >> 16) & 0x7f
    if w0 >> 28 == 0xb:
        return "sopk", (w0 >> 23) & 0x1f
    if w0 >> 30 == 0b10:
        return "sop2", (w0 >> 23) & 0x7f
    top6 = w0 >> 26
    if top6 == 0x3d:
        return "smem", (w0 >> 18) & 0xff
    if top6 == 0x35:
        return "vop3", (w0 >> 16) & 0x3ff
    if top6 == 0x32:
        return "vintrp", (w0 >> 16) & 3
    if top6 == 0x3e:
        return "exp", 0
    if top6 == 0x38:
        return "mubuf", ((w0 >> 18) & 0x7f) | ((w0 >> 25) & 1) << 7
    if top6 == 0x3a:
        return "mtbuf", ((w0 >> 16) & 7) | ((w[1] >> 21) & 1) << 3
    if top6 == 0x3c:
        return "mimg", ((w0 >> 18) & 0x7f) | (w0 & 1) << 7
    return f"other{top6:x}", 0


def mnemonic_of(text):
    return text.split(" ", 1)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="print rejected lines and the gfx1013/gfx1030 differences")
    args = ap.parse_args()
    cands = candidates()
    lines, owner, kinds = [], [], []
    for k, c in enumerate(cands):
        for kind, line in lines_for(c, k):
            lines.append(line)
            owner.append(c["name"])
            kinds.append(kind)
    ex, w64x = extras()
    n_cand_lines = len(lines)
    names = {c["name"] for c in cands}
    for line in ex:
        m = line.split()[0].replace("_e32", "").replace("_e64", "")
        lines.append(line)
        owner.append(m if m in names else None)
        kinds.append("extra")
    w64_idx = [i for i in range(len(lines)) if kinds[i] == "w64"]
    with tempfile.TemporaryDirectory() as scratch:
        main_idx = [i for i in range(len(lines)) if kinds[i] != "w64"]
        good_rel, enc = assemble([lines[i] for i in main_idx], scratch)
        good = [main_idx[i] for i in good_rel]
        w_lines = [lines[i] for i in w64_idx] + w64x
        wgood, wenc = assemble(w_lines, scratch, wave64=True)
        # the other CPU, for the report
        cand_main = [i for i in main_idx if owner[i] is not None]
        bad_other, _ = run_llvm([lines[i] for i in cand_main], scratch, cpu=OTHER_CPU)
    # SDWA and DPP are not part of this dialect: drop what LLVM encoded so
    dropped = [i for i, (t, w) in zip(good, enc) if sdwa_or_dpp(w)]
    keep = [k for k, i in enumerate(good) if i not in set(dropped)]
    good = [good[k] for k in keep]
    enc = [enc[k] for k in keep]
    by_line = dict(zip(good, enc))

    # rows: encoding and opcode from the base lines, the VOP3 opcode from
    # the _e64 lines, the modifiers from the modifier lines
    rows = {}
    order = []
    problems = []
    for i in good:
        n = owner[i]
        if n is None:
            continue
        text, words = by_line[i]
        e, code = classify(words)
        r = rows.get(n)
        if r is None:
            c = next(x for x in cands if x["name"] == n)
            r = dict(c, enc=None, code=None, vop3=None, flags=0, seen=[])
            rows[n] = r
            order.append(n)
        r["seen"].append((kinds[i], e, code, text))
    for n in order:
        r = rows[n]
        short = [(e, code, t) for (kind, e, code, t) in r["seen"] if e != "vop3"]
        long_ = [(e, code, t) for (kind, e, code, t) in r["seen"] if e == "vop3"]
        if short:
            encs = {(e, code) for (e, code, t) in short}
            if len(encs) != 1:
                problems.append(f"{n}: several encodings {encs}")
            r["enc"], r["code"] = sorted(encs)[0]
            if long_:
                codes = {code for (e, code, t) in long_}
                if len(codes) != 1:
                    problems.append(f"{n}: several VOP3 opcodes {codes}")
                r["vop3"] = sorted(codes)[0]
        else:
            codes = {code for (e, code, t) in long_}
            if len(codes) != 1:
                problems.append(f"{n}: several VOP3 opcodes {codes}")
            r["enc"], r["code"] = "vop3", sorted(codes)[0]
        f = 0
        for (kind, e, code, t) in r["seen"]:
            if e != "vop3" and kind in ("clamp", "omod", "neg", "opsel"):
                pass
            elif kind == "clamp":
                f |= F_CLAMP
            elif kind == "omod":
                f |= F_OMOD
            elif kind == "neg":
                f |= F_NEG
            elif kind == "opsel":
                f |= F_OPSEL
            if e != "vop3" and mnemonic_of(t).endswith("_e32"):
                f |= F_SUFFIX
        if r["shape"] == "sopp_imm":
            for (kind, e, code, t) in r["seen"]:
                parts = t.split()
                if len(parts) == 2 and parts[1] == "0x3":
                    f |= F_HEX
                if len(parts) == 2 and parts[1] == "128":
                    f |= F_DEC
        r["flags"] = f
    # the shapes the decoder models (exp has one row, made by hand above)
    for n in order:
        r = rows[n]
        if r["shape"] == "mimg_bvh" or r["enc"] is None:
            continue
    # opcode collisions
    seen_codes = {}
    for n in order:
        r = rows[n]
        key = (r["enc"], r["code"])
        if key in seen_codes:
            problems.append(f"{n} and {seen_codes[key]} share {key}")
        seen_codes[key] = n
        if r["vop3"] is not None:
            key = ("vop3", r["vop3"])
            if key in seen_codes:
                problems.append(f"{n} (VOP3) and {seen_codes[key]} share {key}")
            seen_codes[key] = n

    # hwreg names and MTBUF format names, as LLVM prints them
    hwreg = ["" for _ in range(64)]
    fmts = ["" for _ in range(128)]
    for i, (text, words) in zip(good, enc):
        m = re.match(r"s_getreg_b32 s0, hwreg\((\w+)\)$", text)
        if m and lines[i].startswith("s_getreg_b32 s0, hwreg("):
            idx = int(re.match(r"s_getreg_b32 s0, hwreg\((\d+)\)", lines[i]).group(1))
            if not m.group(1).isdigit():
                hwreg[idx] = m.group(1)
        m = re.match(r"tbuffer_load_format_x v1, off, s\[4:7\], s1 format:(\d+)$", lines[i])
        if m:
            fm = re.search(r"format:\[(\w+)\]", text)
            fmts[int(m.group(1))] = fm.group(1) if fm else ""

    write_rows(order, rows, hwreg, fmts)

    # vectors
    out, keys = [], set()
    for i, (text, words) in zip(good, enc):
        key = "_".join(f"{w:08x}" for w in words)
        if (key, text) in keys:
            continue
        keys.add((key, text))
        out.append(f"{key} {text}")
    out64 = []
    for j, (text, words) in zip(wgood, wenc):
        key = "_".join(f"{w:08x}" for w in words)
        out64.append(f"{key} {text}")
    with open(VEC_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"# gfx10 ({CPU}) encodings from LLVM's AMDGPU assembler, {llvm_version()},\n")
        f.write("# made by tools/gen_gfx10_vectors.py. Test data only. LLVM's text, runs of\n")
        f.write("# spaces made one; wave32 (LLVM's default for gfx10) until the wave64 line.\n")
        f.write("# <dword0>[_<dword1>...] <LLVM's text>\n")
        for line in out:
            f.write(line + "\n")
        f.write("# wave64\n")
        for line in out64:
            f.write(line + "\n")

    covered = set(order)
    missing = [c["name"] for c in cands if c["name"] not in covered]
    print(f"{len(cands)} candidates, {len(order)} rows, {len(lines)} lines, {len(lines) - len(good) - len(w64_idx)} rejected, "
          f"{len(out)} + {len(out64)} wave64 vectors, {len(dropped)} SDWA/DPP encodings dropped", file=sys.stderr)
    by_enc = {}
    for n in order:
        by_enc.setdefault(rows[n]["enc"], []).append(n)
    for e in sorted(by_enc):
        print(f"  {e}: {len(by_enc[e])}", file=sys.stderr)
    for p in problems:
        print("PROBLEM " + p, file=sys.stderr)
    if missing:
        print(f"not in {CPU}: {' '.join(missing)}", file=sys.stderr)
    # gfx1030 differences (by instruction)
    other_ok = {owner[i] for k2, i in enumerate(cand_main) if k2 not in bad_other}
    only1013 = sorted(n for n in covered if n not in other_ok)
    only1030 = sorted({owner[i] for k2, i in enumerate(cand_main) if k2 not in bad_other} - covered)
    print(f"only {CPU}: {' '.join(only1013)}", file=sys.stderr)
    print(f"only {OTHER_CPU}: {' '.join(only1030)}", file=sys.stderr)
    if args.report:
        bad = sorted(set(range(len(lines))) - set(good) - set(w64_idx))
        for i in bad:
            print(f"rejected: {lines[i]}", file=sys.stderr)


def llvm_version():
    out = subprocess.run(["zig", "clang", "--version"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "version" in line:
            return line.strip()
    return "unknown"


def write_rows(order, rows, hwreg, fmts):
    with open(ROWS_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("//! gfx10 (gfx1013) instruction rows for gfx10.sig, made by\n")
        f.write("//! tools/gen_gfx10_vectors.py: the encodings and opcodes are read from\n")
        f.write("//! LLVM's assembler output, not typed in. Do not edit by hand.\n")
        f.write("//!   name, encoding, opcode, VOP3 opcode (0xffff: none), shape, dst type,\n")
        f.write("//!   src0..2 types, flags (1 clamp, 2 omod, 4 neg/abs, 8 op_sel,\n")
        f.write("//!   16 prints _e32/_e64, 32 immediate in hex, 64 immediate in decimal)\n\n")
        f.write('const g = @import("gfx10.sig");\n\n')
        f.write("pub const rows = [_]g.Row{\n")
        for n in order:
            r = rows[n]
            v3 = r["vop3"] if r["vop3"] is not None else 0xffff
            s = r["s"]
            f.write(f'    .{{ "{n}", .{r["enc"]}, {r["code"]}, 0x{v3:x}, .{r["shape"]}, .{r["d"]}, .{s[0]}, .{s[1]}, .{s[2]}, {r["flags"]} }},\n')
        f.write("};\n\n")
        f.write("/// hwreg ids LLVM names (empty: printed as a number).\n")
        f.write("pub const hwreg_names = [64][]const u8{\n")
        for i in range(0, 64, 4):
            f.write("    " + " ".join(f'"{x}",' for x in hwreg[i:i + 4]) + "\n")
        f.write("};\n\n")
        f.write("/// MTBUF formats LLVM names (empty: printed as a number).\n")
        f.write("pub const format_names = [128][]const u8{\n")
        for i in range(0, 128, 4):
            f.write("    " + " ".join(f'"{x}",' for x in fmts[i:i + 4]) + "\n")
        f.write("};\n")


if __name__ == "__main__":
    main()
