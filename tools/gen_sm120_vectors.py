#!/usr/bin/env python3
"""Test vectors for src/nvidia (the sm_120 SASS assembler): what NVIDIA's
ptxas makes of PTX kernels, as nvidia's disassembler prints it, with each
instruction's control bits spelled out.

Dev only. Needs CUDA's ptxas and nvdisasm (CUDA 13.x); building and testing
zpm does not. The output is test data: the assembler must turn every line's
text into exactly the words next to it.

    python tools/gen_sm120_vectors.py OUT.txt KERNELS.ptx...
    python tools/gen_sm120_vectors.py --raw src/nvidia/testdata/sm120_raw.txt
    python tools/gen_sm120_vectors.py --raw-kir src/nvidia/testdata/sm120_kir_raw.txt

(src/nvidia/sm120_vectors.txt is made from every file in
src/nvidia/testdata/, Galaxy's probe kernels first:
galaxy_m4.ptx galaxy_m5.ptx coverage.ptx lfm3_quant.ptx lfm3_layers.ptx
galaxy_draw.ptx sm120_ops.ptx sm120_cvt.ptx.)

Each kernel becomes a block:

    # kernel galaxy_m4 (galaxy_m4.ptx): registers 8, stack 0, params 0
    <hi>_<lo> [B------:R-:W-:Y:S01] LDC R1, c[0x0][0x37c]
    .L_x_0:
    ...
    # end

<hi> is the instruction's bits 127..64 and <lo> its bits 63..0, in hex.
The control field is the 23 bits above 104:
    B  the scoreboards waited on (bits 116..121): a digit per one set
    R  the scoreboard a read releases (bits 113..115), - for none (7)
    W  the scoreboard a write releases (bits 110..112), - for none (7)
    Y  bit 109 (ptxas sets it on nearly everything), - when clear
    S  the stall count, cycles (bits 105..108)
The operand reuse bits (122..125) are the `.reuse` in the text. The
kernel's line has what cuobjdump -res-usage says of it: its registers, its
stack bytes a thread, and its parameters' bytes (constant buffer 0 used
past 0x380, where sm_120 kernels' parameters start).

With --raw it writes words ptxas does not emit (field values and forms
the kernels never produce: see raw_words), as nvdisasm prints them from
raw instruction words.
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

INSTR = re.compile(r"^\s*/\*([0-9a-f]{4})\*/\s+(.*?)\s*;\s*/\*\s*0x([0-9a-f]{16})\s*\*/\s*$")
HI = re.compile(r"^\s*/\*\s*0x([0-9a-f]{16})\s*\*/\s*$")
# (a branch target, or a subroutine of the kernel's: ptxas's IEEE division
# slow path is $__internal_0_$__cuda_sm3x_div_rn_noftz_f32_slowpath)
LABEL = re.compile(r"^(\.L_x_\d+|\$[\w$]+):\s*$")
KERNEL = re.compile(r"^\.text\.(\S+):\s*$")


def tool(name):
    cuda = os.environ.get("CUDA_PATH")
    if cuda:
        for ext in ("", ".exe"):
            p = os.path.join(cuda, "bin", name + ext)
            if os.path.exists(p):
                return p
    p = shutil.which(name)
    if not p:
        sys.exit(f"{name} not found (set CUDA_PATH)")
    return p


def control(hi):
    stall = (hi >> 41) & 0xF
    yld = (hi >> 45) & 1
    wbar = (hi >> 46) & 7
    rbar = (hi >> 49) & 7
    wait = (hi >> 52) & 0x3F
    b = "".join(str(i) if wait & (1 << i) else "-" for i in range(6))
    r = "-" if rbar == 7 else str(rbar)
    w = "-" if wbar == 7 else str(wbar)
    y = "Y" if yld else "-"
    return f"[B{b}:R{r}:W{w}:{y}:S{stall:02d}]"


def usage(cubin, cuobjdump):
    """Each kernel's (registers, stack, params) from cuobjdump -res-usage."""
    text = subprocess.run([cuobjdump, "-res-usage", cubin], check=True, capture_output=True, text=True).stdout
    out = {}
    name = None
    for line in text.splitlines():
        m = re.match(r"\s*Function (\S+):", line)
        if m:
            name = m.group(1)
            continue
        m = re.search(r"REG:(\d+) STACK:(\d+) .*CONSTANT\[0\]:(\d+)", line)
        if m and name:
            out[name] = (int(m.group(1)), int(m.group(2)), max(0, int(m.group(3)) - 0x380))
            name = None
    return out


def blocks(listing, source, used):
    out = []
    lines = listing.splitlines()
    i = 0
    name = None
    while i < len(lines):
        line = lines[i]
        m = KERNEL.match(line)
        if m:
            if name:
                out.append("# end")
            name = m.group(1)
            r, st, pa = used[name]
            out.append(f"# kernel {name} ({source}): registers {r}, stack {st}, params {pa}")
            # (the kernel's own label, as nvdisasm's listing has it: RET's
            # target)
            out.append(f"{name}:")
            i += 1
            continue
        m = LABEL.match(line.strip())
        if m and name:
            out.append(m.group(1) + ":")
            i += 1
            continue
        m = INSTR.match(line)
        if m and name:
            text, lo = m.group(2), int(m.group(3), 16)
            h = HI.match(lines[i + 1])
            if not h:
                sys.exit(f"no second word after: {line}")
            hi = int(h.group(1), 16)
            text = re.sub(r"\s+", " ", text).strip()
            out.append(f"{hi:016x}_{lo:016x} {control(hi)} {text}")
            i += 2
            continue
        i += 1
    if name:
        out.append("# end")
    return out


# ── Words ptxas does not emit ──────────────────────────────────────────────
#
# nvdisasm also reads raw instruction words (-b SM120), so forms and field
# values the kernels above never produce can be checked against its text
# too. Each family below is a word from the vectors with fields set; the
# file this writes (src/nvidia/testdata/sm120_raw.txt) holds each word and
# nvdisasm's text, after the control field as in the vectors. Every one
# found by checking sm120.decode against nvdisasm on the vectors' words
# with a bit flipped is among them.

CTL = 0x000FE2 << 40  # [B------:R-:W-:Y:S01]
RZ = 255


def field(word, at, n, v):
    lo, hi = word
    x = hi << 64 | lo
    x = (x & ~(((1 << n) - 1) << at)) | (v << at)
    return (x & ((1 << 64) - 1), x >> 64)


def imad(op9, a, b, c, form, signed, imm=None, ureg=False):
    lo = op9 | form << 9 | 7 << 12 | 2 << 16 | a << 24 | (imm if imm is not None else b) << 32
    hi = c | int(signed) << 9 | 7 << 17 | 0xF << 23 | int(ureg) << 27 | CTL
    return (lo, hi)


def raw_words():
    out = []
    # IMAD's names for what it computes (MOV, IADD, SHL), signed and not;
    # its immediates printed signed; none for the WIDE and HI forms, or
    # with b in c's slot
    for op9 in (0x024, 0x025, 0x027):
        for s in (False, True):
            out += [
                imad(op9, RZ, RZ, 5, 1, s), imad(op9, 4, RZ, 5, 1, s), imad(op9, RZ, 4, 5, 1, s),
                imad(op9, 4, 0, 5, 4, s, 1), imad(op9, 4, 0, RZ, 4, s, 1), imad(op9, 4, 0, 5, 4, s, 0),
                imad(op9, 4, 0, RZ, 4, s, 8), imad(op9, 4, 0, 5, 4, s, 8), imad(op9, 4, 0, RZ, 4, s, 3),
                imad(op9, 4, 0, RZ, 4, s, 0x80000000), imad(op9, 4, 0, RZ, 4, s, 0xFFFFFFFF),
                imad(op9, 4, 4, RZ, 6, s, None, True), imad(op9, 4, 6, RZ, 1, s),
            ]
    out.append((0x0000000400057E24, 0x001FE2000F8E02FF))  # IMAD R5, R0, RZ, UR4
    # floats' specials: zeros, infinities, quiet and signalling NaNs (their
    # canonical payloads), a denormal, where %.20g gives way to %.20e
    for imm in (0, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x7F800001, 0xFF800001,
                1, 0x3DCCCCCD, 0x4E6E6B28, 0x4CBEBC20, 0x501502F9, 0x7F7FFFFF):
        out.append((imm << 32 | 0x0000000009097421, CTL))  # FADD R9, R9, imm
    for h, l in ((0, 0x8000), (0x8000, 0), (0x7E00, 0x7C01), (0xFE00, 0xFC01), (0x7C00, 0xFC00), (0x0001, 0x7BFF), (0x3555, 0xC200)):
        out.append(((h << 16 | l) << 32 | 0x00000000FF047431, 0x000FE400000001FF))  # HFMA2 R4, -RZ, RZ, h, l
    # global memory: eviction priorities, orders and scopes, the address
    # with a uniform register added in place of the descriptor
    ldg = (0x000000040E127981, 0x000F28000C1E1900)  # LDG.E R18, desc[UR4][R14.64]
    stg = (0x0000080402007986, 0x004FE8000C101B04)  # STG.E.64 desc[UR4][R2.64+0x8], R4
    for v in range(6):
        out.append(field(ldg, 84, 3, v))
    for v in range(16):
        out.append(field(ldg, 77, 4, v))
    out += [
        field(field(field(ldg, 73, 3, 6), 77, 4, 7), 84, 3, 2),
        field(field(field(ldg, 73, 3, 0), 77, 4, 4), 84, 3, 3),
        field(field(stg, 77, 4, 10), 84, 3, 0),
        field(ldg, 76, 1, 0), field(stg, 76, 1, 0), field(field(ldg, 76, 1, 0), 32, 8, RZ),
    ]
    # a store's orders and scopes (not quite a load's)
    for v in range(16):
        out.append(field(stg, 77, 4, v))
    # floats' modifiers in nvdisasm's order: FTZ, rounding, SAT
    fadd = (0x0000000D04047221, CTL)  # FADD R4, R4, R13
    ffma = (0x0000000C09041223, 0x008FCC0000000004)  # @P1 FFMA R4, R9, R12, R4
    for sat in (0, 1):
        for ftz in (0, 1):
            for rnd in range(4):
                for w in (fadd, ffma):
                    out.append(field(field(field(w, 77, 1, sat), 80, 1, ftz), 78, 2, rnd))
    # .BF16_V2's immediates are bfloat16s
    for h, l in ((0x42FE, 0), (0x3F80, 0xBF80), (0x7F80, 0x7FC0), (0x0001, 0x8000)):
        out.append(((h << 16 | l) << 32 | 0x00000000FF037431, 0x000FE200002001FF))  # HFMA2.BF16_V2 R3, -RZ, RZ, h, l
    # a uniform c (form 7), where nvdisasm has it
    form7 = [
        (0x0000000502077224, 0x000FD200078E02FF),  # IMAD R7, R2, R5, RZ
        (0x0000000405087825, 0x040FE200078E000A),  # IMAD.WIDE.U32 R8, R5, 0x4, R10 (b R5 there)
        (0x0000000C03097227, 0x000FE200078E00FF),  # IMAD.HI.U32 R9, R3, R12, RZ
        (0x0000000C09041223, 0x008FCC0000000004),  # FFMA
        (0x0000000E0B0E7219, 0x000FE200000006FF),  # SHF.L.U32 R14, R11, R14, RZ
        (0x0000000600037231, 0x002FE4000000000B),  # HFMA2 R3, R11, R6, R3 (reg form)
        (0x00000009FF097243, 0x000FE200000004FF),  # F2IP.U8.F32.NTZ R9, RZ, R9, RZ
    ]
    for w in form7:
        b = (w[0] >> 32) & 0xFF
        out.append(field(field(field(field(w, 9, 3, 7), 32, 32, 4), 64, 8, b), 91, 1, 1))
    out.append((0x00000004FF0F7E21, 0x000FE20008014100))  # FADD.FTZ R15, -RZ, UR4
    out.append((0x00000004FF0C7E30, 0x004FE20008004100))  # HADD2.F32 R12, -RZ, UR4
    # BAR.ARV takes no DEFER_BLOCKING; SYNC with ids and counts
    bar = (0x0000000000007B1D, 0x000FEC0000010000)  # BAR.SYNC.DEFER_BLOCKING 0x0
    out += [field(bar, 54, 4, 15), field(field(bar, 54, 4, 1), 42, 12, 0x3E0), field(field(field(bar, 80, 1, 0), 77, 2, 1), 42, 12, 32)]
    # VIMNMX.U32's immediate printed signed; F2F's FTZ first
    out.append((0xFFFFFF8100007848, 0x000FE20007FE0000))  # VIMNMX.U32 R0, R0, -0x7f, !PT
    out.append((0x0000000A000A7310, 0x008EA40000311000))  # F2F.FTZ.F32.F64 R10, R10
    # words read off the fuzzing: F2I's FTZ, ISETP.U32's signed immediate,
    # LDCU's uniform guard
    out += [
        (0x0000000F000F7305, 0x000E260000213000),  # F2I.FTZ.U32.NTZ R15, R15
        (0x800000030900780C, 0x000FE20000723470),  # ISETP.LE.U32.OR P1, PT, R9, -0x7ffffffd, P0
        (0x00007200FF0667AC, 0x000E6E0008000800),  # @UP6 LDCU UR6, c[0x0][0x390]
    ]
    return out


def disasm_raw(nvdisasm, words, base=0):
    """nvdisasm's text for each word (None where it calls one illegal)."""
    fd, path = tempfile.mkstemp(suffix=".bin")
    with os.fdopen(fd, "wb") as f:
        for lo, hi in words:
            f.write(struct.pack("<QQ", lo, hi))
    try:
        r = subprocess.run([nvdisasm, "-b", "SM120", "--base-address", hex(base), path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    texts = []
    if r.returncode == 0 and "error" not in r.stderr.lower():
        for line in r.stdout.splitlines():
            m = re.match(r"^\s*/\*([0-9a-f]{4,})\*/\s+(.*?)\s*;", line)
            if m:
                texts.append(re.sub(r"\s+", " ", m.group(2)).strip())
    if len(texts) == len(words):
        return texts
    if len(words) == 1:
        return [None]
    mid = len(words) // 2
    return disasm_raw(nvdisasm, words[:mid], base) + disasm_raw(nvdisasm, words[mid:], base + 16 * mid)


def raw(out_path, nvdisasm):
    version = subprocess.run([nvdisasm, "--version"], capture_output=True, text=True).stdout.strip().splitlines()[-1]
    words = raw_words()
    texts = disasm_raw(nvdisasm, words)
    out = [
        "# sm_120 words ptxas does not emit, as nvdisasm -b SM120 prints them",
        f"# ({version}). Test data only, made by tools/gen_sm120_vectors.py --raw.",
        "# <hi>_<lo> <control> <disassembly>",
    ]
    seen = set()
    for (lo, hi), t in zip(words, texts):
        if (lo, hi) in seen:
            continue
        seen.add((lo, hi))
        if t is None:
            print(f"illegal: {hi:016x}_{lo:016x}", file=sys.stderr)
            continue
        out.append(f"{hi:016x}_{lo:016x} {control(hi)} {t}")
    with open(out_path, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"{out_path}: {len(out) - 3} words")


# ── The forms KIR's sm_120 backend added ───────────────────────────────────
#
# FRND (cvt.rmi/rpi/rzi/rni.f32.f32) and the 32-bit atomics (atom.global,
# atom.shared), from ptxas's words for them (CUDA 13.4) with their fields
# set to each value nvdisasm names; written to
# src/nvidia/testdata/sm120_kir_raw.txt by --raw-kir.

def kir_words():
    out = []
    # ptxas's words, control fields and all
    out += [
        (0x0000000A00087307, 0x008FE20000205000),  # FRND.FLOOR R8, R10
        (0x0000000A00097307, 0x000E620000209000),  # FRND.CEIL R9, R10
        (0x0000000A000B7307, 0x000FE2000020D000),  # FRND.TRUNC R11, R10
        (0x0000000A000C7307, 0x000E620000201000),  # FRND R12, R10
        (0x0000000A000D7307, 0x000EA20000215000),  # FRND.FTZ.FLOOR R13, R10
        (0x80000007080B89A8, 0x01056200081EF106),  # @!P0 ATOMG.E.ADD.STRONG.GPU PT, R11, desc[UR6][R8.64], R7
        (0x80000007040879A8, 0x004EA800089EF106),  # ATOMG.E.MIN.STRONG.GPU
        (0x80000407040979A8, 0x000EA800091EF106),  # ATOMG.E.MAX.STRONG.GPU (+0x4)
        (0x80000807040A79A8, 0x000EE8000C1EF106),  # ATOMG.E.EXCH.STRONG.GPU (+0x8)
        (0x80000C07040D79A8, 0x002EE200089EF306),  # ATOMG.E.MIN.S32.STRONG.GPU (+0xc)
        (0x80001007040C79A8, 0x000F2200091EF306),  # ATOMG.E.MAX.S32.STRONG.GPU (+0x10)
        (0x00000007000F738C, 0x000E280000000000),  # ATOMS.ADD R15, [R0], R7
        (0x0000040F000F738C, 0x001E280000800000),  # ATOMS.MIN R15, [R0+0x4], R15
        (0x0000080F0011738C, 0x001E280001000200),  # ATOMS.MAX.S32 R17, [R0+0x8], R15
        (0x00000C110011738C, 0x001F220004000000),  # ATOMS.EXCH R17, [R0+0xc], R17
    ]
    atomg = (0x80000007080B79A8, 0x00000000081EF106 | CTL)
    atoms = (0x00000007000F738C, CTL)
    frnd = (0x0000000A00087307, 0x0000000000205000 | CTL)
    for v in range(9):
        out += [field(atomg, 87, 4, v), field(atoms, 87, 4, v)]
    out += [field(atomg, 73, 3, 1), field(atoms, 73, 3, 1), field(atomg, 81, 3, 0)]
    out += [field(atomg, 40, 23, 0x7FFFF0), field(atoms, 40, 24, 0xFFFFF0), field(atoms, 40, 24, 0x7FFFFC)]
    for v in range(4):
        out.append(field(frnd, 78, 2, v))
    out += [field(field(frnd, 9, 3, 4), 32, 32, 0x3FC00000), field(frnd, 80, 1, 1), field(field(frnd, 80, 1, 1), 78, 2, 3)]
    return out


def raw_kir(out_path, nvdisasm):
    version = subprocess.run([nvdisasm, "--version"], capture_output=True, text=True).stdout.strip().splitlines()[-1]
    words = kir_words()
    texts = disasm_raw(nvdisasm, words)
    out = [
        "# FRND and the 32-bit atomics: ptxas's words and fields set, as nvdisasm -b SM120",
        f"# prints them ({version}). Test data only, made by tools/gen_sm120_vectors.py --raw-kir.",
        "# <hi>_<lo> <control> <disassembly>",
    ]
    for (lo, hi), t in zip(words, texts):
        if t is None:
            print(f"illegal: {hi:016x}_{lo:016x}", file=sys.stderr)
            continue
        out.append(f"{hi:016x}_{lo:016x} {control(hi)} {t}")
    with open(out_path, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"{out_path}: {len(out) - 3} words")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    if sys.argv[1] == "--raw":
        return raw(sys.argv[2], tool("nvdisasm"))
    if sys.argv[1] == "--raw-kir":
        return raw_kir(sys.argv[2], tool("nvdisasm"))
    ptxas, nvdisasm, cuobjdump = tool("ptxas"), tool("nvdisasm"), tool("cuobjdump")
    version = subprocess.run([ptxas, "--version"], capture_output=True, text=True).stdout.strip().splitlines()[-1]
    out = [
        "# sm_120 encodings: NVIDIA's ptxas (-arch=sm_120 -O3) on the PTX kernels",
        f"# named below, printed by nvdisasm -hex ({version}). Test data only,",
        "# made by tools/gen_sm120_vectors.py (see it for the control field).",
        "# <hi>_<lo> <control> <disassembly>",
    ]
    with tempfile.TemporaryDirectory() as d:
        for ptx in sys.argv[2:]:
            cubin = os.path.join(d, os.path.basename(ptx) + ".cubin")
            subprocess.run([ptxas, "-arch=sm_120", "-O3", ptx, "-o", cubin], check=True)
            listing = subprocess.run([nvdisasm, "-hex", "-c", cubin], check=True, capture_output=True, text=True).stdout
            out += blocks(listing, os.path.basename(ptx), usage(cubin, cuobjdump))
    with open(sys.argv[1], "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print(f"{sys.argv[1]}: {sum(1 for l in out if l[:1] in '0123456789abcdef')} instructions")


if __name__ == "__main__":
    main()
