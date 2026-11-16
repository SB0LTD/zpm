#!/usr/bin/env python3
"""sm_120's graphics-stage instructions as nvdisasm -b SM120 prints them
from raw words: the test data src/nvidia/testdata/sm120_gfx_raw.txt.

    python3 tools/gen_sm120_gfx_vectors.py src/nvidia/testdata/sm120_gfx_raw.txt
    (in WSL; NVDISASM= picks the binary, /usr/local/cuda/bin/nvdisasm otherwise)

Dev only, as tools/gen_sm120_vectors.py is: needs CUDA's nvdisasm (13.x).
Same method and line format as that tool's --raw:
`<hi>_<lo> <control> <disassembly>`, the control field worked out from the
word's bits 105..121.
"""
import os
import re
import struct
import subprocess
import sys
import tempfile

NVDISASM = os.environ.get("NVDISASM", "/usr/local/cuda/bin/nvdisasm")
LINE = re.compile(r"^\s*/\*([0-9a-f]{4,})\*/\s+(.*?)\s*;")
M64 = (1 << 64) - 1


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


def field(word, at, n, v):
    """word = (lo, hi); returns the word with n bits at `at` set to v."""
    lo, hi = word
    x = hi << 64 | lo
    x = (x & ~(((1 << n) - 1) << at)) | ((v & ((1 << n) - 1)) << at)
    return (x & M64, x >> 64)


def fields(word, *afv):
    for at, n, v in afv:
        word = field(word, at, n, v)
    return word


def run(words, arch, base=0, extra=()):
    win = NVDISASM.lower().endswith(".exe")
    # (a Windows nvdisasm.exe run from WSL cannot read /tmp: keep the file
    # next to this script and hand it a Windows path)
    fd, path = tempfile.mkstemp(suffix=".bin", dir=os.path.dirname(os.path.abspath(__file__)) if win else None)
    with os.fdopen(fd, "wb") as f:
        for lo, hi in words:
            f.write(struct.pack("<QQ", lo, hi))
    try:
        arg = subprocess.run(["wslpath", "-w", path], capture_output=True, text=True).stdout.strip() if win else path
        return subprocess.run([NVDISASM, "-b", arch, "--base-address", hex(base), *extra, arg],
                              capture_output=True, text=True)
    finally:
        os.unlink(path)


ERRAT = re.compile(r"at address 0x([0-9a-fA-F]+)")
LAST_ERR = {}


def dis(words, arch="SM120"):
    """nvdisasm's text for each word (None where it refuses one; the reason
    it gave is then in LAST_ERR[(lo, hi)])."""
    out = [None] * len(words)
    start = 0
    while start < len(words):
        chunk = words[start:]
        r = run(chunk, arch)
        texts = []
        if r.returncode == 0 and "error" not in r.stderr.lower():
            for line in r.stdout.splitlines():
                m = LINE.match(line)
                if m:
                    texts.append(re.sub(r"\s+", " ", m.group(2)).strip())
        if len(texts) == len(chunk):
            out[start:] = texts
            break
        m = ERRAT.search(r.stderr)
        if not m:
            if len(chunk) == 1:
                LAST_ERR[chunk[0]] = r.stderr.strip()
                break
            # no address in the complaint: one word at a time
            for i, w in enumerate(chunk):
                out[start + i] = dis([w], arch)[0]
            break
        bad = int(m.group(1), 16) // 16
        LAST_ERR[chunk[bad]] = " / ".join(l.replace("nvdisasm error   : ", "") for l in r.stderr.strip().splitlines())
        if bad:
            out[start:start + bad] = dis(chunk[:bad], arch)
        start += bad + 1
    return out


def dis_par(words, arch="SM120", jobs=16):
    """dis, one nvdisasm run per word, in parallel: for sweeps where most
    words are refused (a run stops at its first refused word)."""
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(jobs) as ex:
        return list(ex.map(lambda w: dis([w], arch)[0], words))


def parse(s):
    hi, lo = s.replace("0x", "").split("_")
    return (int(lo, 16), int(hi, 16))


def fmt(word):
    lo, hi = word
    return f"{hi:016x}_{lo:016x}"


def show(words, arch="SM120", notes=None, out=sys.stdout):
    texts = dis(words, arch)
    for i, (w, t) in enumerate(zip(words, texts)):
        note = f"   # {notes[i]}" if notes and notes[i] else ""
        print(f"{fmt(w)} {control(w[1])} -> {t if t is not None else '<refused>'}{note}", file=out)
    return texts


P, F = parse, fields
S01 = "[B------:R-:W-:Y:S01]"
groups = []


def group(title):
    groups.append((title, []))


def w(word, *afv, ctl=S01):
    """A word (hi_lo text) with fields set and the control field `ctl`."""
    x = F(P(word), *afv)
    c = ctl
    wait = sum(1 << i for i in range(6) if c[2 + i] != "-")
    rd = 7 if c[10] == "-" else int(c[10])
    wr = 7 if c[13] == "-" else int(c[13])
    x = F(x, (105, 4, int(c[18:20])), (109, 1, c[15] == "Y"), (110, 3, wr), (113, 3, rd), (116, 6, wait))
    groups[-1][1].append(x)


ALD = "000fc00000000000_000080ffff057321"   # ALD R5, a[0x80]
AST = "000fc000000000ff_00008005ff007322"   # AST a[0x80], R5
IPA = "000fc000000e0020_000000ff00057326"   # IPA.PASS R5, a[0x80]
PIX = "000fc000000e0000_0000000000057925"   # PIXLD R5
KILL = "000fc00003800000_000000000000795b"
EXIT = "000fc00003800000_000000000000794d"
TEX = "000fc000081e3f0c_20ffff09070a7d61"   # TEX.B.DXY R12, R10, R7, R9, 2D
TLD = "000fc000081e0f0c_28ffff09070a7d67"   # TLD.B.LZ R12, R10, R7, R9, 2D

group("a vertex program's words")
for x in ["000fe20000000000_0002fcffff007321", "000fe20000000000_0002f8ffff017321",
          "000fe20000000c00_000080ffff047321", "000fe20000000cff_00007004ff007322",
          "000fe20000000cff_00008008ff007322", "000fe200000004ff_00008008ff007322",
          "000fe200000000ff_00007004ff007322", "000fe20003800000_000000000000794d"]:
    w(x)
group("a pixel program's words")
for x in ["000fe200000e001f_000000ff00007326", "000fe200000e0020_000000ff00017326",
          "000fe200000e0021_000000ff00027326", "000fe200000e1020_000000ff00017326",
          "000fe200000e4024_000000ff00037326", "000fe200000e001c_000000ff00057326",
          "000fe200000e40ff_000000ff00067326", "000fe20000001000_0000000000007308",
          "000fe2000040c000_0000000001017220", "000fe2000040c000_0000000002027220",
          "000fe200081e3f02_20ffff0604007d61", "000fe2000c1e3f02_20ffff0604007d61",
          "000fe200081e3f02_20ffff0200007d61", "000fe200081e0f02_28ffff0604007d61",
          "000fe200081e3f02_28ffff0604007d61", "000fe200081e33ff_20ffff0604007d61",
          "000fe200081e0f02_28ffff0604007d67", "000fe20003800000_000000000000795b",
          "000fe20003800000_000000000000095b", "000fe20003800000_000000000000895b",
          "000fe200000e4000_0000000000007925", "000fe200000e0000_0000000000007925",
          "000fe200000e8000_0000000000007925", "000fe200000ec000_0000000000007925",
          "000fe200000f0000_0000000000007925"]:
    w(x)

group("ALD: sizes, .O, .P, .PHYS, an index and a vertex register, scoreboards")
for size in (1, 2):
    w(ALD, (74, 2, size))
w(ALD, (40, 10, 0))
w(ALD, (40, 10, 0x3ff))
w(ALD, (32, 8, 9))
w(ALD, (79, 1, 1))
w("000fc00000008000_00008804ff047321")            # (the driver's ALD.O R4, a[0x88], R4)
w(ALD, (76, 1, 1))
w(ALD, (76, 1, 1), (74, 2, 1))
w(ALD, (79, 1, 1), (76, 1, 1), (74, 2, 3))
w(ALD, (76, 1, 1), (24, 8, 7), (40, 10, 0x20))
w(ALD, (76, 1, 1), (24, 8, 7), (40, 10, 0))
w(ALD, (79, 1, 1), (76, 1, 1), (24, 8, 7), (40, 10, 0x20), (74, 2, 3))
w(ALD, (77, 1, 1), (24, 8, 7), (40, 10, 0))
w(ALD, (77, 1, 1), (24, 8, 7), (40, 10, 0), (32, 8, 9))
w(ALD, (79, 1, 1), (77, 1, 1), (24, 8, 7), (40, 10, 0))
w(ALD, (16, 8, 255), (74, 2, 3))
w(ALD, ctl="[B------:R-:W0:Y:S01]")
w(ALD, (76, 1, 1), (24, 8, 7), ctl="[B0-----:R1:W2:-:S02]")
w(ALD, (12, 4, 0x9), ctl="[B012345:R-:W5:-:S15]")

group("AST: sizes, .P, .PHYS, an index and a vertex register, a read scoreboard")
w(AST, (74, 2, 2))
w(AST, (40, 10, 0x3ff))
w(AST, (32, 8, 255))
w(AST, (64, 8, 9))
w(AST, (64, 8, 0))
w(AST, (76, 1, 1))
w(AST, (76, 1, 1), (64, 8, 9))
w(AST, (76, 1, 1), (24, 8, 7), (40, 10, 0x20))
w(AST, (76, 1, 1), (24, 8, 7), (40, 10, 0), (74, 2, 3))
w(AST, (77, 1, 1), (24, 8, 7), (40, 10, 0))
w(AST, (77, 1, 1), (24, 8, 7), (40, 10, 0), (64, 8, 9))
w(AST, (74, 2, 3), (40, 10, 0x70), (32, 8, 4), ctl="[B------:R1:W-:Y:S01]")
w(AST, (74, 2, 1), ctl="[B0-2---:R5:W-:-:S02]")
w(AST, (12, 4, 0x2), ctl="[B------:R-:W-:-:S01]")

group("IPA: every frequency and place, a predicate, addresses")
for freq in range(3):
    for loc in range(3):
        w(IPA, (78, 2, freq), (76, 2, loc), *(((32, 8, 9),) if loc == 2 else ()))
w(IPA, (76, 2, 2))                                  # (.OFFSET RZ)
w(IPA, (81, 3, 0))
w(IPA, (81, 3, 6), (76, 2, 1))
w(IPA, (81, 3, 2), (76, 2, 2), (32, 8, 9))
for addr in (0x0, 0x60, 0x74, 0x2e0, 0x2fc, 0x3fc):
    w(IPA, (64, 8, addr >> 2))
w(IPA, (16, 8, 255))
w(IPA, ctl="[B------:R-:W3:Y:S01]")
w(IPA, (12, 4, 0x1), ctl="[B--2---:R-:W0:-:S04]")

group("PIXLD: a predicate")
w(PIX, (78, 3, 1), (81, 3, 0))
w(PIX, (78, 3, 4), (81, 3, 3))
w(PIX, (16, 8, 255), (78, 3, 1))
w(PIX, (78, 3, 3), ctl="[B------:R-:W1:Y:S01]")

group("KILL: its guard, its predicate, waits")
for g in (0x1, 0x6, 0x9, 0xf):
    w(KILL, (12, 4, g))
for p in (0x0, 0x1, 0x8, 0xa, 0xf):
    w(KILL, (87, 4, p))
w(KILL, (12, 4, 0x0), (87, 4, 0x1))
w(KILL, (12, 4, 0x9), (87, 4, 0xa))
w(KILL, (12, 4, 0x0), ctl="[B012345:R-:W-:Y:S01]")
w(KILL, ctl="[B0-----:R-:W-:-:S15]")
w(EXIT, ctl="[B012345:R-:W-:Y:S05]")

group("TEX: dimensions, levels of detail, derivatives, the mask")
for dim in (0, 2, 3, 4, 5, 7):
    w(TEX, (61, 3, dim))
for lod in range(11):
    w(TEX, (59, 1, lod & 1), (87, 3, lod >> 1), (76, 2, 0))
for lod in (2, 3, 5, 10):
    w(TEX, (59, 1, lod & 1), (87, 3, lod >> 1))
w(TEX, (76, 2, 1))
for mask in (0x0, 0x1, 0x7, 0x8, 0xe):
    w(TEX, (72, 4, mask))
w(TEX, (64, 8, 255))
w(TEX, (64, 8, 255), (72, 4, 0x1))
w(TEX, (16, 8, 255))
group("TEX: offsets, .SCR, .DC, halves, the fault predicate, eviction, a uniform register, .NODEP")
w(TEX, (56, 2, 1))
w(TEX, (56, 2, 2))
w(TEX, (58, 1, 1))
w(TEX, (60, 1, 1))
w(TEX, (78, 1, 1))
w(TEX, (79, 2, 1))
w(TEX, (79, 2, 2))
for p in (0, 3, 6):
    w(TEX, (81, 3, p))
for ev in (0, 2, 3, 4, 5):
    w(TEX, (84, 3, ev))
w(TEX, (48, 8, 6))
w(TEX, (48, 8, 0))
w(TEX, (90, 1, 1))
w(TEX, (90, 1, 1), (72, 4, 0x3), (64, 8, 255))
w("000fc000081e3f03_20ffff0705017d61")            # (no register alignment)
w("000fc000081e3ffc_20fffff8fafe7d61")
# eight modifiers: what an instruction's text holds
w(TEX, (59, 1, 1), (87, 3, 2), (56, 2, 1), (78, 1, 1), (84, 3, 0), (90, 1, 1))
w(TEX, (60, 1, 1), (59, 1, 1), (56, 2, 1), (78, 1, 1), (84, 3, 0), (90, 1, 1), (81, 3, 1), (48, 8, 6), (72, 4, 7))
w(TEX, (79, 2, 2), (59, 1, 1), (87, 3, 1), (56, 2, 2), (58, 1, 1), (76, 2, 1), (90, 1, 1))
w(TEX, ctl="[B------:R1:W0:Y:S01]")
w(TEX, (12, 4, 0x8), ctl="[B-1--4-:R-:W5:-:S02]")

group("TLD: levels, offsets, multisampling, dimensions")
for lod in (1, 2):
    w(TLD, (87, 2, lod))
w(TLD, (56, 2, 1))
w(TLD, (56, 2, 2))
w(TLD, (58, 1, 1))
w(TLD, (60, 1, 1))
w(TLD, (79, 2, 1))
w(TLD, (79, 2, 2))
for ev in (0, 2, 3, 4, 5):
    w(TLD, (84, 3, ev))
w(TLD, (76, 1, 1))
w(TLD, (77, 1, 1))
w(TLD, (78, 1, 1))
w(TLD, (81, 3, 1))
w(TLD, (90, 1, 1))
w(TLD, (48, 8, 6))
w(TLD, (72, 4, 3), (64, 8, 255))
for dim in (0, 2, 4, 5):
    w(TLD, (61, 3, dim))
w(TLD, (60, 1, 1), (56, 2, 1), (87, 2, 1), (84, 3, 0), (77, 1, 1), (90, 1, 1), (81, 3, 1), (48, 8, 6), (72, 4, 7))
w(TLD, ctl="[B------:R2:W1:Y:S01]")


def version():
    r = subprocess.run([NVDISASM, "--version"], capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if "Build" in line:
            return line.strip().split("Build")[-1].strip().rstrip(")").strip()
    return "?"


def main():
    out = sys.argv[1]
    words = [x for _, ws in groups for x in ws]
    texts = dis(words)
    bad = [fmt(x) for x, t in zip(words, texts) if t is None or "?" in t or "INVALID" in t]
    if bad:
        sys.exit("refused or invalid: " + " ".join(bad))
    seen = set()
    n = 0
    with open(out, "w", newline="\n") as f:
        f.write("# sm_120's graphics-stage instructions (ALD, AST, IPA, PIXLD, KILL, TEX, TLD, with the\n")
        f.write("# FMUL.RZ, MUFU.RCP and EXIT beside them), as nvdisasm -b SM120 prints them from raw\n")
        f.write(f"# words (Build {version()}). Test data only: the fields\n")
        f.write("# are NAK's (sm70_encode.rs), each word was fed to nvdisasm the way\n")
        f.write("# tools/gen_sm120_vectors.py --raw feeds its own, and the control field is the word's\n")
        f.write("# bits 105..121.\n")
        f.write("# <hi>_<lo> <control> <disassembly>\n")
        i = 0
        for title, ws in groups:
            f.write(f"# {title}\n")
            for x in ws:
                t = texts[i]
                i += 1
                if x in seen:
                    continue
                seen.add(x)
                f.write(f"{fmt(x)} {control(x[1])} {t}\n")
                n += 1
    print(f"{n} words -> {out}")


if __name__ == "__main__":
    main()
