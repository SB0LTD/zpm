# NVIDIA sm_120 SASS in pure Sig

`src/nvidia/` holds Galaxy's way to make GPU kernels for NVIDIA's Blackwell GeForce GPUs (sm_120: the RTX 50 series, which includes the Legion 5's RTX 5070 Laptop GPU) without CUDA. It plays the role for NVIDIA that `src/adreno/` (ir3) plays for the Surface's Adreno:

- `sm120.sig`: the instruction set. One line of nvdisasm syntax, after its control field, becomes the instruction's 128 bits.
- `sm120_asm.sig`: kernels. Labels, comments, `.params` and `.stack` headers and branches go in. Out come the code words, padded to 128-byte lines as ptxas pads, plus the register, stack and parameter counts a launch needs.

Nothing from NVIDIA is needed to build or test it. Galaxy launches its kernels on its own driver (galaxy `src/kernel/nv_chan.sig`).

## Where the encodings come from

- **Mesa's NAK compiler** (`src/nouveau/compiler/nak/sm70_encode.rs`, MIT) was read as documentation. It gave the ALU forms (bits 9..11), the operand slots, the predicates, the memory and constant-load fields, the branch offset and the control bits, and NAK covers sm_100 and sm_120. None of it is copied.
- **ptxas's own output** is the test data. `tools/gen_sm120_vectors.py` runs ptxas (`-arch=sm_120 -O3`), nvdisasm and cuobjdump from CUDA 13.4 on the PTX in `src/nvidia/testdata/`. It writes `sm120_vectors.txt`, with each instruction's words, its control field spelled out and its disassembly, plus each kernel's register, stack and parameter counts. The forms NAK doesn't emit were read off these vectors, and so were the constant bits ptxas sets:
  - the two-source `IADD` and `IADD.64`;
  - `MOV.64` and `UMOV.64` (a 64-bit immediate in bits 24..87);
  - `STL`'s 0x387 form;
  - `I2FP`.

## What is covered

- **The tests (`sig build test-nvidia`):**
  - All 328 vectors encode to ptxas's 128 bits.
  - The six kernels (Galaxy's five probe kernels, M4 and M5's fill, copy, matmul and local, plus a coverage kernel) assemble from their listings to ptxas's exact words, registers, stack and parameter bytes. These are the words Galaxy runs on the RTX today (galaxy `nv_kernels.sig`).
- **The forms:**
  - Moves and integer arithmetic: `MOV`, `MOV.64`, `UMOV.64`, `IADD`, `IADD.64`, `IADD3`, `IMAD`, `IMAD.WIDE`, `ISETP`, `LOP3.LUT`, `PLOP3.LUT`.
  - Floating point and conversion: `FFMA`, `FADD`, `HFMA2`, `I2FP`.
  - Special and uniform registers: `S2R`, `S2UR`, `R2UR`.
  - Constant, global and local memory: `LDC`, `LDCU`, `LDG`, `STG`, `LDL`, `STL`.
  - Control flow: `BRA`, `EXIT`, `NOP`.
- **Written from NAK, with no vector yet:** `FMUL`.

## Next

1. **Working out the control fields.** Every instruction carries its scheduling above bit 104: a stall count, the scoreboards to set and the scoreboards to wait on. The hardware doesn't track these hazards. Today the author writes them, which is exact for ptxas listings but hard for new code. The assembler should compute them, as `ir3_asm` computes Adreno's delay slots:
   - fixed ALU latencies become stalls;
   - loads, `S2R` and `LDC` get a scoreboard that their readers wait on;
   - stores' reads get one that later writers wait on.
2. **The forms the LFM3 brain's kernels need:**
   - shared memory (`LDS`, `STS`) and `BAR.SYNC`;
   - warp shuffles (`SHFL`);
   - `MUFU` (exp2, rcp, rsqrt);
   - shifts and selects (`SHF`, `LEA`, `SEL`, `IMAD.HI`);
   - half packing (`F2FP`);
   - the tensor-core MMAs.

   Each gets a PTX kernel in `testdata/` and its vectors.
3. **On the hardware.** Galaxy's `bench` runs with these kernels in place of ptxas's. They are the same words, so the result should match legion14's. Then the first kernels written here, not copied from a listing, run there too.
