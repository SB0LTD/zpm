#!/usr/bin/env python3
"""The sm_120 encoding sweep: every sm_120 program zpm makes, judged by
NVIDIA's own disassembler.

Dev only, like tools/gen_sm120_vectors.py: it needs CUDA's nvdisasm (13.x,
from $CUDA_PATH or PATH) and Sig; building and testing zpm do not, and
without nvdisasm this exits 0 having checked nothing.

    python tools/sweep_sm120.py [--keep] [--judge]

(--judge: only judge the .sm120-sweep/ a run left with --keep.)

It makes .sm120-sweep/ in the zpm root, runs tools/sm120_sweep.sig (which
writes each program's raw words, NAME.bin, and zpm's own decoding of them,
NAME.txt), then runs `nvdisasm -b SM120` on each .bin and reports:
  - every word nvdisasm calls illegal (the GPU raises Xid 13, Illegal
    Instruction Encoding, on it);
  - every instruction nvdisasm prints otherwise than sm120.format does (a
    field zpm sets that the hardware reads differently).
Exit status 1 when anything is reported.
"""

import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, ".sm120-sweep")

MODULES = [
    "--dep", "nvidia", "--dep", "gpu", "--dep", "lfm3_nv_matrix", "--dep", "lfm3_nv_ops", "--dep", "lfm3_kir", "-Mroot=tools/sm120_sweep.sig",
    "--dep", "gpu", "--dep", "quantized_linear", "-Mlfm3_kir=src/core/lfm3_kir.sig",
    "--dep", "nvidia", "--dep", "adreno", "-Mgpu=src/gpu/gpu.sig",
    "-Madreno=src/adreno/adreno.sig",
    "--dep", "nvidia", "--dep", "quantized_linear", "-Mlfm3_nv_matrix=src/core/lfm3_nv_matrix.sig",
    "--dep", "nvidia", "--dep", "lfm3_executor", "-Mlfm3_nv_ops=src/core/lfm3_nv_ops.sig",
    "--dep", "sig_math", "--dep", "gguf", "--dep", "lfm3_plan", "--dep", "quantized_linear", "--dep", "transformer_ops",
    "-Mlfm3_executor=src/core/lfm3_executor.sig",
    "--dep", "sig_math", "--dep", "sig_mem", "--dep", "gguf", "-Mlfm3_plan=src/core/lfm3_plan.sig",
    "--dep", "sig_math", "-Mquantized_linear=src/core/quantized_linear.sig",
    "--dep", "sig_math", "-Mtransformer_ops=src/core/transformer_ops.sig",
    "--dep", "sig_math", "--dep", "sig_mem", "-Mgguf=src/core/gguf.sig",
    "-Msig_math=src/core/sig_math.sig", "-Msig_mem=src/core/sig_mem.sig", "-Mnvidia=src/nvidia/nvidia.sig",
]

LINE = re.compile(r"^\s*/\*([0-9a-f]{4,})\*/\s+(.*?)\s*;")
ERR = re.compile(r"at address 0x([0-9a-f]+)")


def tool(name):
    cuda = os.environ.get("CUDA_PATH")
    if cuda:
        p = os.path.join(cuda, "bin", name + (".exe" if os.name == "nt" else ""))
        if os.path.exists(p):
            return p
    return shutil.which(name)


def norm(t):
    t = re.sub(r"\s+", " ", t).strip()
    # (a branch's target: nvdisasm prints an address, sm120.format `(0x..)
    t = re.sub(r"`\((0x[0-9a-f]+)\)", r"\1", t)
    return t


def judge(nvdisasm, name):
    path = os.path.join(OUT, name + ".bin")
    mine = {}
    for l in open(os.path.join(OUT, name + ".txt"), encoding="utf-8"):
        pc, rest = l.rstrip("\n").split(" ", 1)
        # (sm120.format's control field first)
        rest = re.sub(r"^\[[^\]]*\]\s*", "", rest)
        mine[int(pc, 16)] = rest
    r = subprocess.run([nvdisasm, "-b", "SM120", path], capture_output=True, text=True)
    problems = []
    for m in ERR.finditer(r.stderr):
        pc = int(m.group(1), 16)
        problems.append(f"{name} 0x{pc:04x}: nvdisasm calls it illegal: zpm encoded {mine.get(pc, '?')}")
    if problems:
        return problems
    theirs = {}
    for l in r.stdout.splitlines():
        m = LINE.match(l)
        if m:
            theirs[int(m.group(1), 16)] = m.group(2)
    for pc, t in sorted(mine.items()):
        if pc not in theirs:
            problems.append(f"{name} 0x{pc:04x}: nvdisasm printed nothing; zpm reads {t}")
            continue
        if t.startswith("??"):
            problems.append(f"{name} 0x{pc:04x}: zpm cannot decode its own word ({t}); nvdisasm reads {theirs[pc]}")
            continue
        if norm(t) != norm(theirs[pc]):
            problems.append(f"{name} 0x{pc:04x}: zpm reads {t}; nvdisasm reads {theirs[pc]}")
    return problems


def main():
    nvdisasm = tool("nvdisasm")
    if not nvdisasm:
        print("sweep_sm120: no nvdisasm (CUDA): nothing checked")
        return 0
    if "--judge" not in sys.argv:
        shutil.rmtree(OUT, ignore_errors=True)
        os.makedirs(OUT)
        r = subprocess.run(["sig", "test"] + MODULES, cwd=ROOT, capture_output=True, text=True)
        out = r.stdout + r.stderr
        if r.returncode != 0 or "programs written" not in out:
            print(out[-4000:])
            print("sweep_sm120: the dump did not run")
            return 1
        for l in out.splitlines():
            i = l.find("sweep: ")
            if i >= 0:
                print(l[i:])
    names = sorted(f[:-4] for f in os.listdir(OUT) if f.endswith(".bin"))
    problems = []
    for n in names:
        problems += judge(nvdisasm, n)
    for p in problems:
        print(p)
    words = sum(os.path.getsize(os.path.join(OUT, n + ".bin")) // 16 for n in names)
    print(f"sweep_sm120: {len(names)} programs, {words} words: {len(problems)} problems")
    if "--keep" not in sys.argv and "--judge" not in sys.argv:
        shutil.rmtree(OUT, ignore_errors=True)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
