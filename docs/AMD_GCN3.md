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
  - scalar loads and stores;
  - buffer loads, stores and atomics, with offen, idxen, glc, slc, tfe and the MTBUF formats;
  - flat loads, stores and atomics;
  - LDS: reads, writes, the two-address forms, atomics, `ds_swizzle`, `ds_permute` and `ds_bpermute`.
- **Text:** the printer follows LLVM's rules:
  - the `_e32`/`_e64` suffixes;
  - inline constants by value, other literals in hex;
  - `neg(...)` for a negated constant;
  - `s_waitcnt` with only the counters it waits on;
  - SOPP immediates in decimal up to 64, in hex above;
  - `hwreg(...)`, `format:[...]`, and `swizzle(...)` where it is exact.

  The parser also chooses inline constants over literals as LLVM does.
- **Strict decoding:** a word with a reserved or unused field set, a literal LLVM would write inline, or a form not modelled is `NoMatch`. So every word that decodes prints, parses and encodes back to itself.
- **Not modelled:**
  - SDWA, DPP, VINTRP, EXP and MIMG;
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
  - every swizzle mode.

  LLVM's gfx803 assembler encodes them. The generator keeps LLVM's own text and bytes, and drops what LLVM rejects (the constant bus, register-only operands). It uses `zig clang -cc1as`, which carries LLVM with the AMDGPU target, or `--llvm-mc PATH`. Only the generator needs LLVM: building and testing zpm don't.
- **The tests (`sig build test-amdgpu`):**
  - All 3,617 vectors decode, print as LLVM prints them, parse and encode back to LLVM's bytes.
  - 200,000 random words in every format: whatever decodes encodes back to the same words, and so does its text.
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
- **What it models:** EXEC, VCC, SCC and M0; 64 KB of LDS; memory regions at GPU addresses. SMEM, MUBUF/MTBUF (buffer resources, with their range checks) and FLAT reach memory as the hardware does.
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
  - Scalar ALU semantics, the hazard checks, and LDS two-address forms, swizzle and bpermute.
- **Not emulated** (reported as `Unsupported`):
  - `v_div_scale`/`fmas`/`fixup`, `trig_preop`, `msad`/`qsad`, `movrel`, `cvt_pknorm`, `cvt_off`;
  - d16 and non-32-bit buffer formats;
  - GDS, `ds_append`/`ds_consume`, scratch.

## Next

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
