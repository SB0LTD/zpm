#!/usr/bin/env python3
"""Test vectors for src/nvidia (the sm_120 SASS assembler): what NVIDIA's
ptxas makes of PTX kernels, as nvidia's disassembler prints it, with each
instruction's control bits spelled out.

Dev only. Needs CUDA's ptxas and nvdisasm (CUDA 13.x); building and testing
zpm does not. The output is test data: the assembler must turn every line's
text into exactly the words next to it.

    python tools/gen_sm120_vectors.py OUT.txt KERNELS.ptx...

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
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

INSTR = re.compile(r"^\s*/\*([0-9a-f]{4})\*/\s+(.*?)\s*;\s*/\*\s*0x([0-9a-f]{16})\s*\*/\s*$")
HI = re.compile(r"^\s*/\*\s*0x([0-9a-f]{16})\s*\*/\s*$")
LABEL = re.compile(r"^(\.L_x_\d+):\s*$")
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


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
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
