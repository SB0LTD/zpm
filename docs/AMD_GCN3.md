# AMD GCN3/GCN4 (gfx803) in pure Sig

`src/amdgpu/` lets Galaxy make GPU kernels for AMD's GCN 4 GPUs without ROCm, LLVM or a vendor driver. The first target is the Radeon Pro 555X/560X in the owner's MacBook Pro (15-inch, 2018): Polaris 21, gfx803, PCI 1002:67ef. It plays the role `src/adreno/` plays for the Surface's Adreno and `src/nvidia/` for the RTX 5070.

GCN 4 uses GCN 3's encodings, so the instruction set is AMD's public "AMD GCN3 ISA" reference guide. Everything is allocation-free: instructions are plain values, text goes into caller buffers, and the assembler and emulator take caller-owned work storage.

## The files

| File | What it is |
|---|---|
| `gcn3.sig` | The instruction set. One table row per instruction (name, encoding, opcode, operand shape and types) drives the encoder, a strict decoder, a printer and a parser. The text is LLVM's AMDGPU syntax, as `llvm-mc -mcpu=gfx803 -show-encoding` prints it. |
| `gcn3_asm.sig` | Kernels from text: labels, comments, branches, and LLVM's own `.amdhsa_*` directive names. Out come the code words, the register counts and the dispatch configuration. |
| `dispatch.sig` | What a dispatch consumes: the 64-byte AMDHSA kernel descriptor, `COMPUTE_PGM_RSRC1`/`RSRC2`, the user and system SGPR layout, the `COMPUTE_*` registers a PM4 `SET_SH_REG` writes, and buffer resources (V#). |
| `gcn3_emu.sig` | An emulator of wave64 waves, used to test kernels on the host. |
| `gcn3_vectors.txt`, `testdata/` | LLVM's encodings and kernels, used as test data. |

## The instruction set

- **Formats:** SOP2, SOPK, SOP1, SOPC, SOPP, SMEM, VOP2, VOP1, VOPC, VOP3a/b, DS, MUBUF, MTBUF and FLAT. That is 797 instructions, the VOPC families expanded:
  - scalar ALU, branches, `s_waitcnt`, `s_barrier`, `hwreg` access;
  - the vector ALU in fp32, fp64, fp16 (as gfx8 has it), int32 and int16, with the VOP3 modifiers (neg, abs, clamp, omod);
  - SDWA: the second dword of a VOP1, VOP2 or VOPC instruction that selects a byte or word of each source (zero- or sign-extended) and of the result (the rest padded, sign-extended or kept). LLVM gives every such instruction with 32-bit operands one, except `v_movrel*`, `v_mac_f16`, and `v_mac_f32` outside `DWORD`/`UNUSED_PAD`;
  - scalar loads and stores;
  - buffer loads, stores and atomics, with offen, idxen, glc, slc, tfe and the MTBUF formats;
  - flat loads, stores and atomics;
  - LDS: reads, writes, the two-address forms, atomics, `ds_swizzle`, `ds_permute` and `ds_bpermute`.
- **Text:** the printer follows LLVM's rules:
  - the `_e32`/`_e64` suffixes, and `_sdwa` with all four selects written out (a VOPC's SDWA form has no suffix, as LLVM prints it);
  - inline constants by value, other literals in hex;
  - `neg(...)` for a negated constant;
  - `s_waitcnt` with only the counters it waits on;
  - SOPP immediates in decimal up to 64, in hex above;
  - `hwreg(...)`, `format:[...]`, and `swizzle(...)` where it is exact.

  The parser also chooses inline constants over literals as LLVM does.
- **Strict decoding:** a word with a reserved or unused field set, a literal LLVM would write inline, or a form not modelled is `NoMatch`. So every word that decodes prints, parses and encodes back to itself.
- **Not modelled:**
  - DPP, VINTRP, EXP and MIMG;
  - `s_sendmsg`, the fork/join and `gpr_idx` forms;
  - MUBUF's `lds` bit and FLAT's tfe;
  - GDS-only and `src2` DS forms.

## Where the encodings come from, and how they are tested

- **The source:** the fields and opcodes come from AMD's GCN3 guide. LLVM's assembler output is the test data.
- **The generator:** `tools/gen_gcn3_vectors.py` reads the table rows from `gcn3.sig` and writes a few lines per instruction (different registers, constants, modifiers), plus sweeps:
  - every inline constant at every width;
  - the special registers;
  - all 64 `hwreg` ids;
  - `s_waitcnt` combinations;
  - all 128 MTBUF formats;
  - every swizzle mode;
  - SDWA forms of every VOP1, VOP2 and VOPC row, every select with and without sign extension, and every destination select with every way of filling the rest.

  LLVM's gfx803 assembler encodes them. The generator keeps LLVM's own text and bytes, and drops what LLVM rejects (the constant bus, register-only operands). It uses `zig clang -cc1as`, which carries LLVM with the AMDGPU target, or `--llvm-mc PATH`. Only the generator needs LLVM: building and testing zpm don't.
- **The tests (`sig build test-amdgpu`):**
  - All 4,357 vectors (740 of them SDWA) decode, print as LLVM prints them, parse and encode back to LLVM's bytes.
  - 200,000 random words in every format, SDWA among them: whatever decodes encodes back to the same words, and so does its text.
  - The three kernels in `testdata/` (copy, matmul, branch) assemble to LLVM's exact code words and kernel descriptor (`testdata/kernels_llvm.txt`). Their declared register counts are what the code uses.
  - The emulator runs the kernels and checks them against the CPU (below).

## The kernel descriptor and the dispatch

`dispatch.Config` holds what the hardware needs to launch a wave:

- the user SGPRs, in the HSA order: private segment buffer, dispatch ptr, queue ptr, kernarg ptr, dispatch id, flat scratch init, private segment size;
- the system SGPRs after them: workgroup ids x/y/z, workgroup info, private segment wave offset;
- the workitem-id VGPRs (v0, v1, v2);
- the VGPR and SGPR counts. On gfx8, VCC and FLAT_SCRATCH are allocated at the top of the SGPRs: 2 extra SGPRs for VCC, 6 with FLAT_SCRATCH, as LLVM counts them;
- LDS, scratch, kernarg size and the float mode.

From these it makes:

- `rsrc1()` and `rsrc2()`;
- the 64-byte descriptor (`Descriptor.bytes()`, equal to LLVM's);
- `shRegs()`: the register writes of one dispatch. These are `COMPUTE_PGM_LO/HI`, `RSRC1`, `RSRC2` (with `LDS_SIZE` in 512-byte granules), `NUM_THREAD_X/Y/Z`, `START_X/Y/Z`, `TMPRING_SIZE`, `RESOURCE_LIMITS` and `USER_DATA_n`, at Mesa's `sid.h` addresses, read as documentation.

Galaxy's driver will write them with `SET_SH_REG` and launch with `DISPATCH_DIRECT` (`dispatch.DISPATCH_INITIATOR`). The packets are Galaxy's to write.

## The emulator

- **How it runs a dispatch:** it runs every workgroup of the grid. Each workgroup's waves (up to 16) take turns at `s_barrier`. Each wave starts from the hardware's launch state: the user SGPRs, the workgroup ids after them, the workitem ids in v0 to v2, and EXEC for a partial last wave.
- **What it models:** EXEC, VCC, SCC and M0; 64 KB of LDS; memory regions at GPU addresses. SMEM, MUBUF/MTBUF (buffer resources, with their range checks) and FLAT reach memory as the hardware does. SDWA selects its sources' bytes and words and writes its results' as the hardware does.
- **Strict buffers** (`Dispatch.strict_buffers`): an access past a V#'s `num_records` is a fault. The hardware returns 0 for a load and drops a store, which hides a kernel's out-of-range access; the KIR backend's tests run strict.
- **The code:** up to 65,536 dwords (LFM3's largest matrix kernel is 8,766). A dispatch the emulator can't take says why (`BadDispatch`: the code's size, the user SGPRs, the waves).
- **The hazard checks:** what the hardware doesn't interlock is reported as an error, not read stale:
  - **A missing `s_waitcnt`:** reading or overwriting a register a load hasn't delivered. SMEM returns out of order, so only `lgkmcnt(0)` waits for it. FLAT counts on both counters.
  - **gfx8's manual wait states:** a VALU-written SGPR read by VMEM (5), by `v_readlane`/`v_writelane`'s lane select (4), VCC by `v_div_fmas` (4), VCC/EXEC as `vccz`/`execz` (5), and the data VGPRs of a store wider than 64 bits (1).
  - **LDS past M0:** gfx8 clamps DS accesses to M0, so kernels set it to -1.
  - **Registers past the kernel's declared counts.**
- **Floating point:** the host's IEEE arithmetic. f32 denormals are flushed as the kernel's mode says. `v_mad`/`v_mac` round twice and `v_fma` once. The transcendentals are exact here but approximate on the GPU, so compare them with a tolerance.
- **The kernels it runs:**
  - **copy:** buffer loads and stores, and the range check stopping the last partial workgroup.
  - **matmul:** a 64x64 fp32 matrix product, with 16x16 tiles staged in LDS, four waves per workgroup and barriers. It matches the CPU's sums bit for bit.
  - **branch:** an if/else under EXEC.
  - Scalar ALU semantics, SDWA's selects (hand-worked results), the hazard checks, and LDS two-address forms, swizzle and bpermute.
- **Not emulated** (reported as `Unsupported`):
  - `v_div_scale`/`fmas`/`fixup`, `trig_preop`, `msad`/`qsad`, `movrel`, `cvt_pknorm`, `cvt_off`;
  - d16 and non-32-bit buffer formats;
  - GDS, `ds_append`/`ds_consume`, scratch.

## The KIR backend: `kir_gcn4` and the emulated Polaris

`src/gpu/kir_gcn4.sig` compiles KIR (see `docs/GPU.md`) for gfx803; `device.Target.gcn4_gfx803` selects it. `src/gpu/amd_device.sig` has `Emu`, the emulated Polaris as a `gpu.Device`: programs run in `gcn3_emu`, strict buffers on, each buffer 4 GB from the next so a stray offset faults instead of reading a neighbour.

- **Caps** (`kir_gcn4.polaris_caps`): wave64 (`subgroup` 64), groups up to 1024 threads, 64 KB of shared memory, `fused_fma` (`v_fma_f32`), `mad = .unfused`, f32 denormals flushed by default (both modes compile: `float_denorm_mode_32`), no `dot4`.
- **The launch state:** the kernarg pointer in s[0:1], the group ids the kernel reads after it, the workitem ids in v0 to v2. The kernarg segment holds a buffer resource (V#) per binding with its real `num_records`, then the parameter words, then the group counts if the kernel reads them; the prologue loads it with `s_load_dwordx16/8/4/2/1`. `Info.config()` and `Info.kernarg()` are what a driver needs to launch it.
- **Registers:**
  - uniform values written once (parameters, group ids and counts) stay in SGPRs, `tid` in v0 to v2;
  - the rest are linear-scan allocated over liveness on the structured flow: a register read in a loop lives through the whole loop only if the value comes around the back edge, that is, no write in an open region (the read's own if-arm, else-arm or loop, or one around it) comes before the read;
  - predicates are lane masks in SGPR pairs; past the pool they live in a VGPR as 0/1;
  - 64- and 128-bit accesses take consecutive VGPRs.
- **Flow:** `if` is `s_and_saveexec_b64` and `s_cbranch_execz`, `else` takes the save mask's other lanes, `endif` restores EXEC. Loops keep break and continue masks. A `brk` or `cont` takes its lanes out of EXEC only, and the `else` and `endif` of the ifs it sits in drop them. A compare's predicate (VOPC writes 0 to inactive lanes) skips the `and` with EXEC when no lane left between its write and the use.
- **Memory:** MUBUF with the binding's V#. LDS through DS with M0 set to -1. Shuffles: `ds_swizzle` for xor masks under 32, `ds_bpermute` otherwise. Atomics return through `glc`.
- **Waits:** a pass after lowering inserts `s_waitcnt` (vmcnt in order, lgkmcnt for SMEM and DS), merged across forward branches and flushed before back edges, and `s_nop` for gfx8's manual wait states.
- **Exactness, where gfx8 differs from KIR:**
  - `fmin`/`fmax`: IEEE mode off, so a NaN gives the other operand. The hardware's choice between -0 and +0 is not KIR's, so two orders of `v_min`/`v_max` combine (an `or`, or an `and` with the sign). Against a constant that is not ±0 it is one instruction; `max(x, +0)` and `min(x, -0)` take two.
  - `fmad` is `v_mad_f32` when f32 denormals flush, `v_mul` + `v_add` otherwise (`v_mad_f32` flushes regardless); `ffma` is `v_fma_f32`.
  - `fdiv` and `fsqrt` arrive as the shared exact expansions (`kir.expand`).
  - `dot4`: no dot instruction on gfx8. Each byte product is one SDWA `v_mul_i32_i24`/`v_mul_u32_u24` of the selected bytes, and three `v_add_u32` sum them: 7 instructions, 8 with an accumulator.
  - `(x >> c) & (2^n - 1)` folds into one `v_bfe_u32` before the analysis when `x` is the same at both.
- **Tests:**
  - `sig build test-gpu-gcn4` (`tests/test_kir_gcn4.sig`): every KIR op with register and immediate operands against `kir_interp`, in both denormal modes; selects, conversions, ids in 1 to 3 dimensions, 8- to 128-bit loads and stores, shared memory, contended atomics, every shuffle; divergent flow (nested ifs, `brk`/`cont`/`ret` from inside ifs, checked by mutation); a 4-wave tree sum with barriers; K's exact fdiv and fsqrt bit for bit. Buffers must match byte for byte (NaNs as NaNs).
  - LFM3 (L's KIR kernels): the synthetic model's logits over 10 steps, and past 4096 positions, equal to the CPU's (`within 0`).
  - Galaxy's frames (G's `gfx_render` tests through an `AmdTest` like `NvTest`): every op group, 3 seeds, equal to the model on every pixel.

  The LFM3 and frame runs used scratch copies (L's and G's kernels are on their own branches); see the PR.

**Counts** (instructions, then registers; sm_120 counts code bytes / 16, ir3 as its backend counts):

| Kernel | gcn4 | sm_120 | ir3 |
|---|---|---|---|
| frame tile | 3157 / 53 VGPRs | 2152 / 57 | 4139 / 100 |
| frame glass_down | 72 / 17 | 72 / 16 | 82 / 16 |
| frame glass_blur | 73 / 19 | 64 / 18 | 86 / 16 |
| frame copy_out | 17 / 15 | 24 / 14 | 18 / 8 |
| LFM3 q4k x1 / x8 | 521 / 3125 | 304 / 1360 | 134 / 648 |
| LFM3 q6k x1 / x8 | 819 / 3444 | 560 / 1616 | 218 / 723 |
| LFM3 q80 x1 / x8 | 130 / 669 | 104 / 448 | 122 / 711 |
| LFM3 norm_quant | 1223 / 46 VGPRs | 1216 / 66 | 1440 / 13 |
| LFM3 swiglu_quant | 2827 | 3008 | 3228 |
| LFM3 softmax | 552 | 512 | 565 |
| LFM3 scores 4x2 | 606 | 592 | 634 |
| LFM3 values 4x2 | 397 | 352 | 464 |
| LFM3 prepare | 648 | 664 | 785 |

The LFM3 matrix kernels are built per GPU (the Adreno's has eight threads a row, the others two), so compare them across columns with that in mind. LFM3's other kernels are within 10% of sm_120, except `values 4x2` (+13%) and `residual` (28 against 24); so are glass_down and copy_out (glass_blur is +14%). The matrix kernels and the tile pay for what gfx8 lacks:
- **No dot instruction.** sm_120 has `IDP4A`; gcn4 needs seven instructions per dot of four bytes.
- **Explicit waits.** sm_120 and ir3 encode theirs in instruction bits; the tile kernel has 227 `s_waitcnt`.
- **EXEC-mask flow.** The tile kernel's `if`s and `cont`s are about 500 scalar instructions.

## Next (the backend)

1. **The adapter over Galaxy's driver:** PM4 `SET_SH_REG` from `dispatch.shRegs(info.config())`, the kernarg from `Info.kernarg`, `DISPATCH_DIRECT`, a fence.
2. **Fewer waits:** hoist loads in straight-line code and wait once for a batch.
3. **24-bit multiplies:** `v_mad_u32_u24` where a range analysis proves both factors under 2^24 (`imad` is 2 instructions now).
4. **Occupancy:** the matrix kernels take 110 to 164 VGPRs, so a SIMD holds 2 of their waves (1 at x8).

## Next (the toolchain)

1. **Vega (gfx9) as a variant**, for the MacBook Pro 15,3's Vega 16/20 (gfx904):
   - VOP3's `op_sel`, and VOP3P packed math;
   - FLAT's global and scratch segments, with 13-bit offsets;
   - `s_waitcnt`'s high vmcnt bits;
   - no M0 for LDS;
   - the `_co_` carry renames, and the new opcodes.

   Each change gets its own vectors from LLVM at `-mcpu=gfx904`.
2. **Waits in the assembler:** insert `s_waitcnt` and the manual wait states, as `ir3_asm` does for the Adreno. The emulator's checks already say where they are missing.
3. **In Galaxy** (milestones M9 and M10 of galaxy PR #56):
   - the PM4 `SET_SH_REG` and `DISPATCH_DIRECT` packets from `dispatch.shRegs`, on the Polaris compute ring;
   - the copy and matmul kernels there, the same words that pass here.
