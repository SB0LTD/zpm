#!/usr/bin/env python3
"""Make src/amdgpu/gcn3_vectors.txt: LLVM's gfx803 encodings of every row of
the instruction table in src/amdgpu/gcn3.sig.

For each row this writes a few instruction lines (different operands,
constants, modifiers), has LLVM's AMDGPU assembler encode them for gfx803
(Polaris; `zig clang -cc1as` carries LLVM with the AMDGPU target, as does
`llvm-mc -arch=amdgcn -mcpu=gfx803 -show-encoding`), and keeps LLVM's own
text and bytes. Lines LLVM rejects (an operand the instruction does not take,
the constant bus) are dropped and counted. LLVM is test data only: nothing
from it is needed to build or test zpm.

    python tools/gen_gcn3_vectors.py [--llvm-mc PATH] [--report]
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TABLE = os.path.join(ROOT, "src", "amdgpu", "gcn3.sig")
OUT = os.path.join(ROOT, "src", "amdgpu", "gcn3_vectors.txt")

FCONDS = ["f", "lt", "eq", "le", "gt", "lg", "ge", "o", "u", "nge", "nlg", "ngt", "nle", "neq", "nlt", "tru"]
ICONDS = ["f", "lt", "eq", "le", "gt", "ne", "ge", "t"]
DWORDS = {"none": 0, "b16": 1, "f16": 1, "b32": 1, "f32": 1, "b64": 2, "f64": 2, "b96": 3, "b128": 4, "b256": 8, "b512": 16}
ROW = re.compile(r'^\s*\.\{\s*"([a-z0-9_{}]+)",\s*\.(\w+),\s*(0x[0-9a-f]+|\d+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*\.(\w+),\s*(true|false)\s*\},')


def rows():
    out = []
    with open(TABLE, encoding="utf-8") as f:
        for line in f:
            m = ROW.match(line)
            if not m:
                continue
            name, enc, code, shape, d, s0, s1, s2, e64 = m.groups()
            fam = FCONDS if "{f}" in name else ICONDS if "{i}" in name else None
            for i, c in enumerate(fam or [None]):
                n = name.replace("{f}", c).replace("{i}", c) if c else name
                out.append(dict(name=n, enc=enc, code=int(code, 0) + i, shape=shape, d=d, s=[s0, s1, s2], e64=e64 == "true"))
    return out


def vr(n, t):
    w = max(DWORDS[t], 1)
    return f"v{n}" if w == 1 else f"v[{n}:{n + w - 1}]"


def sr(n, t):
    w = max(DWORDS[t], 1)
    if w == 1:
        return f"s{n}"
    align = 2 if w == 2 else 4
    n = (n // align) * align
    return f"s[{n}:{n + w - 1}]"


def isfloat(t):
    return t in ("f16", "f32", "f64")


def const_for(t, k):
    """A constant operand for type t: inline ints, inline floats, a literal."""
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


def lines_for(r, k):
    """Instruction lines for one row (k varies the registers)."""
    n, sh, d, s, enc = r["name"], r["shape"], r["d"], r["s"], r["enc"]
    a, b, c = 1 + k % 7, 9 + k % 11, 20 + k % 13
    out = []
    if sh == "sop2":
        out.append(f"{n} {sr(a * 2, d)}, {sr(b * 2, s[0])}, {sr(c * 2, s[1])}")
        out.append(f"{n} {sr(c, d)}, {const_for(s[0], k)}, {literal_for(s[1])}")
        sp = "exec" if DWORDS[s[0]] == 2 else "m0"
        out.append(f"{n} {sr(a, d)}, {sp}, {const_for(s[1], k + 1)}")
    elif sh == "sop1":
        out.append(f"{n} {sr(a * 2, d)}, {sr(b * 2, s[0])}")
        out.append(f"{n} {sr(c, d)}, {literal_for(s[0])}")
        sp = "vcc" if DWORDS[s[0]] == 2 else "vcc_hi"
        out.append(f"{n} {sr(a + 4, d)}, {sp}")
        out.append(f"{n} {sr(b, d)}, {const_for(s[0], k + 2)}")
    elif sh == "sop1_dst":
        out.append(f"{n} {sr(a * 2, d)}")
    elif sh == "sop1_src":
        out.append(f"{n} {sr(b * 2, s[0])}")
    elif sh == "sopc":
        out.append(f"{n} {sr(a * 2, s[0])}, {sr(b * 2, s[1])}")
        out.append(f"{n} {const_for(s[0], k)}, {literal_for(s[1])}")
    elif sh == "sopk":
        out.append(f"{n} s{a}, 0x{(0x1234 + k * 0x111) & 0xffff:x}")
        out.append(f"{n} s{c}, 0xfffe")
    elif sh == "sopk_getreg":
        out.append(f"{n} s{a}, hwreg(HW_REG_TRAPSTS)")
        out.append(f"{n} s{b}, hwreg(HW_REG_HW_ID, 8, 4)")
    elif sh == "sopk_setreg":
        out.append(f"{n} hwreg(HW_REG_MODE, 4, 8), s{a}")
    elif sh == "sopk_setreg_imm":
        out.append(f"{n} hwreg(HW_REG_MODE, 0, 4), 0x1234")
        out.append(f"{n} hwreg(HW_REG_STATUS), 5")
    elif sh == "sopp":
        out.append(n)
    elif sh == "sopp_imm":
        out.append(f"{n} {1 + k % 5}")
    elif sh == "sopp_branch":
        out.append(f"{n} {5 + k}")
        out.append(f"{n} -{3 + k}")
    elif sh == "sopp_waitcnt":
        pass  # the extras cover it
    elif sh in ("smem_load", "smem_store"):
        out.append(f"{n} {sr((a * 4) % 80, d)}, {sr(b * 2, s[0])}, 0x{0x40 + 4 * k:x}")
        out.append(f"{n} {sr((c * 4) % 80, d)}, {sr(a * 4, s[0])}, s{b} glc")
    elif sh == "smem_none":
        out.append(n)
    elif sh == "smem_time":
        out.append(f"{n} {sr(a * 2, d)}")
    elif sh == "vop_none":
        # LLVM prints the VOP3 form of v_clrexcp without a suffix too, so
        # only the 32-bit form is a vector.
        out.append(n)
    elif sh == "vop_sdst":
        srcs = ", ".join(vr(b + i, t) if i == 0 else (f"s{c}" if i == 1 else "") for i, t in enumerate(s) if t != "none")
        out.append(f"{n} s{a}, {srcs}")
        if enc == "vop3":
            out.append(f"{n} vcc_lo, v{b}, {13 + k % 40}")
    elif n == "v_writelane_b32":
        out += [f"{n} v{a}, s{b}, {k % 64}", f"{n} v{c}, s{a}, s{a}", f"{n} v{b}, 1.0, s{c}", f"{n} v{a}, 0x1234, 7"]
    elif sh == "vop":
        nsrc = sum(1 for t in s if t != "none")
        if enc in ("vop1", "vop2"):
            e = "_e32" if r["e64"] else ""
            if enc == "vop1":
                out.append(f"{n}{e} {vr(a, d)}, {vr(b, s[0])}")
                out.append(f"{n}{e} {vr(c, d)}, {sr(b, s[0])}")
                out.append(f"{n}{e} {vr(a + 1, d)}, {const_for(s[0], k)}")
                out.append(f"{n}{e} {vr(b + 1, d)}, {literal_for(s[0])}")
            else:
                out.append(f"{n}{e} {vr(a, d)}, {vr(b, s[0])}, {vr(c, s[1])}")
                out.append(f"{n}{e} {vr(c, d)}, {sr(b, s[0])}, {vr(a, s[1])}")
                out.append(f"{n}{e} {vr(a + 1, d)}, {const_for(s[0], k)}, {vr(b, s[1])}")
                out.append(f"{n}{e} {vr(b + 1, d)}, {literal_for(s[0])}, {vr(c, s[1])}")
            if r["e64"]:
                srcs = [vr(b, s[0]), sr(c, s[1]) if nsrc > 1 else None]
                out.append(f"{n}_e64 {vr(a, d)}, " + ", ".join(x for x in srcs[:nsrc] if x))
                if isfloat(s[0]) or isfloat(d):
                    m0 = f"-{vr(c, s[0])}" if isfloat(s[0]) else vr(c, s[0])
                    m1 = f"|{vr(a, s[1])}|" if nsrc > 1 and isfloat(s[1]) else (vr(a, s[1]) if nsrc > 1 else None)
                    mods = " clamp mul:2" if isfloat(d) else ""
                    out.append(f"{n}_e64 {vr(b, d)}, " + ", ".join(x for x in [m0, m1] if x) + mods)
                    m0 = f"-|{const_for(s[0], k)}|" if isfloat(s[0]) else const_for(s[0], k)
                    out.append(f"{n}_e64 {vr(c, d)}, " + ", ".join(x for x in [m0, vr(b, s[1]) if nsrc > 1 else None] if x) + (" div:2" if isfloat(d) else ""))
        else:  # VOP3 only
            regs = [vr(b, s[0]), vr(c, s[1]), vr(a + 30, s[2])][:nsrc]
            out.append(f"{n} {vr(a, d)}, " + ", ".join(regs))
            mixed = [sr(b, s[0]), vr(c, s[1]), const_for(s[2], k)][:nsrc]
            out.append(f"{n} {vr(c, d)}, " + ", ".join(mixed))
            if any(isfloat(t) for t in s):
                mods = [f"-{vr(b, s[0])}" if isfloat(s[0]) else vr(b, s[0]),
                        f"|{vr(c, s[1])}|" if isfloat(s[1]) else vr(c, s[1]),
                        f"-|{vr(a, s[2])}|" if isfloat(s[2]) else vr(a, s[2])][:nsrc]
                out.append(f"{n} {vr(b, d)}, " + ", ".join(mods) + (" clamp mul:4" if isfloat(d) else ""))
                negc = [f"neg({const_for(s[0], k + 1)})" if isfloat(s[0]) else const_for(s[0], k + 1), vr(c, s[1]), vr(a, s[2])][:nsrc]
                out.append(f"{n} {vr(a + 2, d)}, " + ", ".join(negc))
    elif sh == "vop_carry":
        out.append(f"{n}_e32 v{a}, vcc, v{b}, v{c}")
        out.append(f"{n}_e32 v{c}, vcc, s{a}, v{b}")
        out.append(f"{n}_e32 v{b}, vcc, {const_for('b32', k)}, v{a}")
        out.append(f"{n}_e32 v{a}, vcc, {literal_for('b32')}, v{c}")
        out.append(f"{n}_e64 v{a}, s[{2 * a}:{2 * a + 1}], v{b}, s{c}")
        out.append(f"{n}_e64 v{c}, vcc, {const_for('b32', k + 1)}, v{b}")
    elif sh == "vop_carry_in":
        out.append(f"{n}_e32 v{a}, vcc, v{b}, v{c}, vcc")
        out.append(f"{n}_e32 v{c}, vcc, {const_for('b32', k)}, v{b}, vcc")
        out.append(f"{n}_e64 v{a}, s[{2 * a}:{2 * a + 1}], v{b}, v{c}, s[{2 * b}:{2 * b + 1}]")
        out.append(f"{n}_e64 v{b}, vcc, 0, v{c}, vcc")
    elif sh == "vop_cndmask":
        out.append(f"{n}_e32 v{a}, v{b}, v{c}, vcc")
        out.append(f"{n}_e32 v{c}, {const_for('b32', k)}, v{b}, vcc")
        out.append(f"{n}_e32 v{b}, {literal_for('b32')}, v{a}, vcc")
        out.append(f"{n}_e64 v{a}, v{b}, s{c}, s[{2 * a}:{2 * a + 1}]")
        out.append(f"{n}_e64 v{b}, 0, -1, vcc")
    elif sh in ("vop_madmk", "vop_madak"):
        K = "0x4900" if d == "f16" else "0x41200000"
        if sh == "vop_madmk":
            out.append(f"{n} v{a}, v{b}, {K}, v{c}")
            out.append(f"{n} v{c}, {const_for(s[0], k)}, {K}, v{b}")
        else:
            out.append(f"{n} v{a}, v{b}, v{c}, {K}")
            out.append(f"{n} v{c}, s{a}, v{b}, {K}")
    elif sh == "vopc":
        out.append(f"{n}_e32 vcc, {vr(a, s[0])}, {vr(b, s[1])}")
        out.append(f"{n}_e32 vcc, {sr(c, s[0])}, {vr(a, s[1])}")
        out.append(f"{n}_e32 vcc, {const_for(s[0], k)}, {vr(c, s[1])}")
        out.append(f"{n}_e64 s[{2 * a}:{2 * a + 1}], {vr(b, s[0])}, {sr(c, s[1])}")
        if isfloat(s[0]):
            m1 = f"|{vr(a, s[1])}|" if isfloat(s[1]) else vr(a, s[1])
            out.append(f"{n}_e64 vcc, -{vr(c, s[0])}, {m1}")
    elif sh == "vop3b":
        regs = [vr(b, s[0]), vr(c, s[1]), vr(a + 30, s[2])]
        out.append(f"{n} {vr(a, d)}, vcc, " + ", ".join(regs))
        out.append(f"{n} {vr(c, d)}, s[{2 * a}:{2 * a + 1}], {sr(b, s[0])}, {vr(c, s[1])}, {const_for(s[2], k)}")
        if isfloat(s[0]):
            out.append(f"{n} {vr(b, d)}, s[{2 * c}:{2 * c + 1}], -{vr(b, s[0])}, {vr(c, s[1])}, -{vr(a, s[2])}")
    elif sh.startswith("ds_"):
        dv = vr(a, d) if d != "none" else ""
        addr = f"v{b}"
        d0 = vr(c, s[1]) if s[1] != "none" else ""
        d1 = vr(c + 4, s[2]) if s[2] != "none" else ""
        if sh == "ds_addr_data":
            out += [f"{n} {addr}, {d0}", f"{n} {addr}, {d0} offset:{4 * (k + 1)}", f"{n} {addr}, {d0} offset:65535 gds"]
        elif sh == "ds_addr_data2":
            out += [f"{n} {addr}, {d0}, {d1}", f"{n} {addr}, {d0}, {d1} offset:{8 * (k + 1)}"]
        elif sh == "ds_write2":
            out += [f"{n} {addr}, {d0}, {d1} offset0:{k % 256} offset1:{(k * 7 + 1) % 256}", f"{n} {addr}, {d0}, {d1} offset1:255 gds"]
        elif sh == "ds_read":
            out += [f"{n} {dv}, {addr}", f"{n} {dv}, {addr} offset:{16 * (k + 1)}"]
        elif sh == "ds_read2":
            out += [f"{n} {dv}, {addr} offset0:{1 + k % 255} offset1:{2 + k % 250}", f"{n} {dv}, {addr} offset1:7"]
        elif sh == "ds_rtn":
            out += [f"{n} {dv}, {addr}, {d0}", f"{n} {dv}, {addr}, {d0} offset:{4 * (k + 3)} gds"]
        elif sh == "ds_rtn2":
            out += [f"{n} {dv}, {addr}, {d0}, {d1}", f"{n} {dv}, {addr}, {d0}, {d1} offset:{12 + k}"]
        elif sh == "ds_rtn_write2":
            out += [f"{n} {dv}, {addr}, {d0}, {d1} offset0:3 offset1:{(7 + k) % 256}"]
        elif sh == "ds_swizzle":
            pass  # the extras cover it
        elif sh == "ds_vdst":
            out += [f"{n} {dv}", f"{n} {dv} offset:16 gds"]
        elif sh == "ds_none":
            out.append(n)
    elif sh in ("buf_load", "buf_store", "buf_atomic"):
        dv = vr(a, d)
        fmt = " format:[BUF_DATA_FORMAT_32,BUF_NUM_FORMAT_FLOAT]" if enc == "mtbuf" else ""
        out.append(f"{n} {dv}, off, s[8:11], s{b}{fmt}")
        out.append(f"{n} {dv}, v{c}, s[4:7], 0 offen offset:{4095 - k}")
        out.append(f"{n} {dv}, v{b}, s[12:15], s{c}{fmt} idxen offset:{4 * k} glc slc")
        out.append(f"{n} {dv}, v[{c}:{c + 1}], s[16:19], m0 idxen offen")
        wider = {1: "b64", 2: "b96", 3: "b128"}.get(DWORDS[d])
        if sh == "buf_load" and wider:
            out.append(f"{n} {vr(a, wider)}, off, s[4:7], 64 tfe")
        out.append(f"{n} {dv}, off, s[4:7], -1")
    elif sh == "buf_none":
        out.append(n)
    elif sh == "flat_load":
        out += [f"{n} {vr(a, d)}, v[{2 * b}:{2 * b + 1}]", f"{n} {vr(c, d)}, v[4:5] glc slc"]
    elif sh == "flat_store":
        out += [f"{n} v[{2 * b}:{2 * b + 1}], {vr(a, s[1])}", f"{n} v[6:7], {vr(c, s[1])} glc"]
    elif sh == "flat_atomic":
        out += [f"{n} v[{2 * b}:{2 * b + 1}], {vr(a, s[1])}", f"{n} {vr(c, d)}, v[2:3], {vr(a, s[1])} glc", f"{n} v[8:9], {vr(c, s[1])} slc"]
    else:
        raise SystemExit(f"no template for shape {sh} ({n})")
    return out


def extras():
    """Constants, special registers, hwreg, waitcnt, formats and swizzles."""
    out = []
    for x in range(-16, 65):
        out.append(f"v_mov_b32_e32 v1, {x}")
        out.append(f"s_mov_b32 s1, {x}")
    for f in ["0.5", "-0.5", "1.0", "-1.0", "2.0", "-2.0", "4.0", "-4.0", "0.15915494"]:
        out.append(f"v_mul_f32_e32 v2, {f}, v3")
        out.append(f"v_mul_f16_e32 v2, {f}, v3")
        out.append(f"s_mov_b32 s2, {f}")
        out.append(f"v_mul_f64 v[2:3], {f if f != '0.15915494' else '0.15915494309189532'}, v[4:5]")
        out.append(f"s_mov_b64 s[2:3], {f if f != '0.15915494' else '0.15915494309189532'}")
    for lit in ["0x41", "0xffffffef", "0x80000000", "0x3f800001", "0x7fffffff"]:
        out.append(f"v_mov_b32_e32 v5, {lit}")
        out.append(f"s_add_u32 s5, s6, {lit}")
    for reg in ["vcc_lo", "vcc_hi", "exec_lo", "exec_hi", "m0", "flat_scratch_lo", "flat_scratch_hi", "tba_lo", "tba_hi", "tma_lo", "tma_hi", "src_scc", "src_vccz", "src_execz"] + [f"ttmp{i}" for i in range(12)] + ["s101", "s0"]:
        out.append(f"v_mov_b32_e32 v7, {reg}")
        out.append(f"s_mov_b32 s7, {reg}")
    out.append("v_mov_b32_e32 v7, src_lds_direct")
    for reg in ["vcc", "exec", "flat_scratch", "tba", "tma", "ttmp[0:1]", "ttmp[10:11]", "s[100:101]"]:
        out.append(f"s_mov_b64 s[8:9], {reg}")
        out.append(f"s_mov_b64 {reg}, s[8:9]")
    for d in ["vcc_lo", "vcc_hi", "exec_lo", "exec_hi", "m0", "flat_scratch_lo", "flat_scratch_hi", "ttmp5", "tba_lo", "tma_hi"]:
        out.append(f"s_mov_b32 {d}, s3")
    for v in ["v255", "v[254:255]", "v128"]:
        out.append(f"v_mov_b32_e32 v0, {v}" if ":" not in v else f"v_add_f64 v[0:1], {v}, v[2:3]")
    out.append("v_mov_b32_e32 v255, v0")
    out += ["s_load_dwordx16 s[84:99], s[100:101], 0xfffff", "s_load_dwordx2 vcc, s[2:3], 0x0", "s_load_dword m0, s[2:3], 0x4", "s_load_dword s3, s[4:5], m0", "s_load_dwordx4 ttmp[4:7], ttmp[2:3], 0x10"]
    for i in range(0, 64):
        out.append(f"s_getreg_b32 s0, hwreg({i})")
    out += ["s_getreg_b32 s1, hwreg(HW_REG_MODE, 31, 1)", "s_getreg_b32 s1, hwreg(HW_REG_GPR_ALLOC, 0, 31)", "s_setreg_b32 hwreg(HW_REG_IB_STS), s2", "s_setreg_b32 hwreg(HW_REG_LDS_ALLOC, 1, 2), s2"]
    for w in ["0", "vmcnt(0)", "expcnt(0)", "lgkmcnt(0)", "vmcnt(0) lgkmcnt(0)", "vmcnt(3) expcnt(2) lgkmcnt(1)", "vmcnt(15) expcnt(7) lgkmcnt(15)", "vmcnt(14)", "expcnt(6)", "lgkmcnt(14)", "vmcnt(7) lgkmcnt(5)", "expcnt(1) lgkmcnt(0)"]:
        out.append(f"s_waitcnt {w}")
    for x in [0, 1, 7, 0x7f, 0xff, 0x100, 0x7fff, 0x8000, 0xffff]:
        out.append(f"s_nop {x & 0xf}")
        out.append(f"s_trap {x & 0xff}")
        out.append(f"s_setprio {x & 3}")
        out.append(f"s_sleep {x & 0x7f}")
    for x in [-32768, -1, 0, 1, 32767]:
        out.append(f"s_branch {x}")
        out.append(f"s_cbranch_execz {x}")
    for fmt in range(128):
        out.append(f"tbuffer_load_format_x v1, off, s[4:7], s1 format:{fmt}")
    out.append("tbuffer_store_format_xyzw v[1:4], v[2:3], s[8:11], s1 format:[BUF_NUM_FORMAT_SINT] idxen offen offset:52 slc tfe")
    for sw in ["swizzle(QUAD_PERM,0,1,2,3)", "swizzle(QUAD_PERM,3,2,1,0)", "swizzle(QUAD_PERM,1,1,1,1)", "swizzle(SWAP,1)", "swizzle(SWAP,16)", "swizzle(SWAP,4)",
               "swizzle(REVERSE,2)", "swizzle(REVERSE,32)", "swizzle(BROADCAST,2,1)", "swizzle(BROADCAST,32,31)", "swizzle(BROADCAST,4,0)",
               'swizzle(BITMASK_PERM,"pppii")', 'swizzle(BITMASK_PERM,"01pip")', 'swizzle(BITMASK_PERM,"ppppp")', 'swizzle(BITMASK_PERM,"10i01")', "0x9000", "0xffff", "0x7c1f", "0x401f"]:
        out.append(f"ds_swizzle_b32 v1, v2 offset:{sw}")
    out.append("ds_swizzle_b32 v3, v4")
    out.append("ds_swizzle_b32 v3, v4 offset:swizzle(SWAP,8) gds")
    # VOP3 forms of every kind of operand, and the modifiers together
    out += ["v_fma_f32 v0, s1, s1, v2", "v_fma_f32 v0, -|s1|, -s1, |v2| clamp div:2", "v_mad_f32 v10, neg(1.0), v2, neg(0.5)",
            "v_add_f32_e64 v0, |0.5|, -|-4.0|", "v_add_f32_e64 v0, neg(64), v2", "v_med3_i32 v0, -16, 64, s5", "v_cndmask_b32_e64 v0, s0, v1, vcc",
            "v_cmp_eq_f32_e64 s[100:101], -|v1|, |v2|", "v_cmp_gt_u32_e64 ttmp[2:3], s1, v2", "v_cmp_lt_f32_e64 exec, v1, v2", "v_cmp_ne_u64_e64 flat_scratch, v[2:3], s[4:5]",
            "v_readlane_b32 m0, v255, m0", "v_readfirstlane_b32 exec_lo, v255", "v_writelane_b32 v255, m0, 63", "v_mbcnt_hi_u32_b32 v1, exec_hi, v1", "v_mbcnt_lo_u32_b32 v1, exec_lo, 0",
            "v_div_scale_f32 v1, vcc, v2, v2, v3", "v_div_fmas_f32 v1, v2, v3, v4", "v_div_fixup_f32 v1, v2, v3, v4", "v_mad_u64_u32 v[2:3], s[0:1], v4, v5, 0",
            "v_mac_f32_e64 v3, v1, v2 mul:2", "v_mov_b32_e64 v1, src_scc", "v_mov_b32_e64 v1, vcc_hi", "v_add_u32_e64 v1, s[2:3], s4, 1.0"]
    return out


def run_llvm(llvm_mc, lines, scratch):
    src = os.path.join(scratch, "in.s")
    with open(src, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    if llvm_mc:
        cmd = [llvm_mc, "-arch=amdgcn", "-mcpu=gfx803", "-show-encoding", src]
    else:
        cmd = ["zig", "clang", "-cc1as", "-triple", "amdgcn-amd-amdhsa", "-target-cpu", "gfx803", "-show-encoding", "-filetype", "asm", src, "-o", "-"]
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
        enc.append((text.strip(), bs))
    return bad, enc


KERNELS = ["copy", "matmul", "branch"]
TESTDATA = os.path.join(ROOT, "src", "amdgpu", "testdata")
KERNELS_OUT = os.path.join(TESTDATA, "kernels_llvm.txt")


def elf_sections(data):
    """Section name -> bytes of an ELF64 little-endian object."""
    import struct
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    secs = []
    for i in range(shnum):
        name, _typ, _flags, _addr, offset, size = struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize)
        secs.append((name, offset, size))
    stroff = secs[shstrndx][1]

    def nm(n):
        end = data.index(b"\0", stroff + n)
        return data[stroff + n:end].decode()

    return {nm(n): data[o:o + s] for (n, o, s) in secs}


def kernel_vectors(llvm_mc, scratch):
    """Each test kernel through LLVM's assembler with an .amdhsa_kernel
    block: its code words and its 64-byte kernel descriptor."""
    import struct
    out = []
    for name in KERNELS:
        with open(os.path.join(TESTDATA, name + ".s"), encoding="utf-8") as f:
            text = f.read()
        directives, body = [], []
        for line in text.splitlines():
            s = line.split(";")[0].strip()
            if s.startswith(".amdhsa_"):
                directives.append("  " + s)
            elif s.startswith(".workgroup_size"):
                continue
            else:
                body.append(line)
        src = "\n".join([
            '\t.amdgcn_target "amdgcn-amd-amdhsa--gfx803"',
            "\t.text",
            f"\t.globl {name}",
            "\t.p2align 8",
            f"\t.type {name},@function",
            f"{name}:",
        ] + body + [
            "\t.rodata",
            "\t.p2align 6",
            f"\t.amdhsa_kernel {name}",
        ] + directives + ["\t.end_amdhsa_kernel", ""])
        s_path = os.path.join(scratch, name + ".s")
        o_path = os.path.join(scratch, name + ".o")
        with open(s_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(src)
        if llvm_mc:
            cmd = [llvm_mc, "-arch=amdgcn", "-mcpu=gfx803", "-filetype=obj", "-o", o_path, s_path]
        else:
            cmd = ["zig", "clang", "-cc1as", "-triple", "amdgcn-amd-amdhsa", "-target-cpu", "gfx803", "-filetype", "obj", "-o", o_path, s_path]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if p.returncode != 0:
            raise SystemExit(f"LLVM rejected kernel {name}:\n{p.stderr}")
        with open(o_path, "rb") as f:
            secs = elf_sections(f.read())
        code = secs[".text"]
        kd = secs[".rodata"][:64]
        words = struct.unpack(f"<{len(code) // 4}I", code)
        out.append(f"kernel {name}")
        out.append("code " + " ".join(f"{w:08x}" for w in words))
        out.append("descriptor " + kd.hex())
    with open(KERNELS_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# The kernels in this folder as LLVM's AMDGPU assembler builds them for gfx803\n")
        f.write("# (an .amdhsa_kernel block from the same .amdhsa_* lines), made by\n")
        f.write("# tools/gen_gcn3_vectors.py: the code words and the 64-byte kernel\n")
        f.write("# descriptor (its entry offset, bytes 16..23, is a relocation: 0 here).\n")
        f.write("\n".join(out) + "\n")
    print(f"{len(KERNELS)} kernels", file=sys.stderr)


def llvm_version(llvm_mc):
    if llvm_mc:
        out = subprocess.run([llvm_mc, "--version"], capture_output=True, text=True).stdout
    else:
        out = subprocess.run(["zig", "clang", "--version"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "version" in line:
            return line.strip()
    return "unknown"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--llvm-mc", help="llvm-mc to use (default: zig clang -cc1as)")
    ap.add_argument("--report", action="store_true", help="print the lines LLVM rejected")
    args = ap.parse_args()
    table = rows()
    lines, owner = [], []
    for k, r in enumerate(table):
        for line in lines_for(r, k):
            lines.append(line)
            owner.append(r["name"])
    for line in extras():
        lines.append(line)
        owner.append(line.split()[0].replace("_e32", "").replace("_e64", ""))
    with tempfile.TemporaryDirectory() as scratch:
        kernel_vectors(args.llvm_mc, scratch)
        bad, _ = run_llvm(args.llvm_mc, lines, scratch)
        good = [i for i in range(len(lines)) if i not in bad]
        bad2, enc = run_llvm(args.llvm_mc, [lines[i] for i in good], scratch)
        if bad2 or len(enc) != len(good):
            raise SystemExit(f"LLVM's second pass disagrees: {len(bad2)} errors, {len(enc)} of {len(good)} encodings")
    covered = {owner[i] for i in good}
    missing = [r["name"] for r in table if r["name"] not in covered]
    if args.report:
        for i in sorted(bad):
            print(f"rejected: {lines[i]}", file=sys.stderr)
    seen = set()
    out = []
    for (text, bs) in enc:
        while len(bs) % 4:
            bs.append(0)
        words = [bs[i] | bs[i + 1] << 8 | bs[i + 2] << 16 | bs[i + 3] << 24 for i in range(0, len(bs), 4)]
        key = "_".join(f"{w:08x}" for w in words)
        if (key, text) in seen:
            continue
        seen.add((key, text))
        out.append(f"{key} {text}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# GCN3/GCN4 (gfx803) encodings from LLVM's AMDGPU assembler, " + llvm_version(args.llvm_mc) + ",\n")
        f.write("# made by tools/gen_gcn3_vectors.py from the rows of gcn3.sig. Test data only.\n")
        f.write("# <dword0>[_<dword1>[_<dword2>]] <LLVM's text>\n")
        for line in out:
            f.write(line + "\n")
    print(f"{len(table)} instructions, {len(lines)} lines, {len(bad)} rejected by LLVM, {len(out)} vectors", file=sys.stderr)
    if missing:
        print(f"no vector for {len(missing)}: {' '.join(missing)}", file=sys.stderr)


if __name__ == "__main__":
    main()
