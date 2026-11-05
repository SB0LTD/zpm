# zpm GPU: one kernel, any GPU

`src/gpu/` is zpm's GPU-neutral compute layer. A kernel is written once, in
KIR, and runs on whatever GPU the machine has: Qualcomm's Adreno, NVIDIA's
RTX, and later Apple, Intel and AMD. It is pure Sig and allocation-free:
storage always comes from the caller. No C, Mesa, CUDA, Vulkan or vendor user
space is involved at build or run time.

The module is `gpu` in zpm's build. Galaxy imports it as `zpm_gpu`, because
Galaxy's kernel already has a module named `gpu`.

| File | What it is |
|---|---|
| `gpu.sig` | The module root. It re-exports the types below. |
| `kir.sig` | The kernel IR: types, ops, the `Kernel` builder, the verifier, the interpreter's binary form, and the exact `fdiv`/`fsqrt` expansions (`expandDiv`, `expandSqrt`, `expand`). |
| `device.sig` | `Caps`, buffers by `Kind`, `Binary`, `Program`, `Dispatch`, the `Device` vtable, `Work`, and `compile`, which dispatches to the backends. |
| `kir_interp.sig` | The interpreter: the definition of every op. |
| `emu_device.sig` | `EmuDevice`, the reference device, which runs on the interpreter. |
| `kir_ir3.sig`, `adreno_device.sig` | The Adreno backend and its device adapter (agent Q's branch). |
| `kir_sm120.sig`, `nvidia_device.sig` | The NVIDIA backend and its device adapter (agent N's branch). |

Comments in `src/gpu/*.sig` name files in prose only. Galaxy's module resolver
scans source text, comments included, so a commented-out import of a file
that doesn't exist yet breaks Galaxy's builds.

## The memory model

A `Device` reports `caps.memory` as either `.unified` or `.discrete`. Code
that places data asks for one of three buffer kinds. A kind names what the
data is used for; each device decides where to put it.

| Kind | Unified (Adreno, Apple, Intel iGPU) | Discrete (RTX) |
|---|---|---|
| `.device` | Ordinary memory. The CPU can see it. | VRAM. `cpu` may be empty. |
| `.host` | Ordinary memory. | System memory the GPU reaches over PCIe. The CPU reads results here. |
| `.upload` | Ordinary memory. | CPU-written, GPU-read: BAR1 VRAM, write-combined. |

The buffer calls:

- **`toDevice(b, off, len)`** makes the CPU's writes to that range visible to
  the GPU. **`fromDevice`** does the opposite. On a unified GPU with
  `caps.coherent`, both are no-ops. On a non-coherent unified GPU they are
  cache maintenance (clean, invalidate). On discrete memory they order
  write-combined writes and the GPU's writes to host memory. Call them
  everywhere: code that skips them works on one machine and fails on the
  next.
- **`import(cpu)`** maps memory the caller already owns into the GPU's
  address space without copying it. It works on unified memory when
  `caps.import`; otherwise it returns null, and the caller copies into a
  buffer of its own. Galaxy uses it for the mmapped model file and for pixel
  buffers. An imported buffer obeys the same coherence rules as any other.
- **Placement.** On unified memory, import the weights (or copy them once),
  and use one `.host` buffer for a frame's output. On discrete memory, put
  the weights and the frame in `.device`, put the results the CPU reads
  (logits, the out buffer) in `.host`, and stage CPU data through `.upload`.
  Data reaches a `.device` buffer that has no CPU view only through a
  kernel's copy.

A dispatch's parameter block holds the bindings' 64-bit GPU addresses
(binding `i` at byte `8*i`), followed by the parameter words (word `w` at
byte `8*bindings + 4*w`). KIR's `param` op reads word `w`, counted after the
bindings.

`EmuDevice` emulates each memory model, so placement mistakes show up in
tests:

- **Unified, coherent:** buffers live in the caller's `mem`. The GPU sees
  the CPU's bytes.
- **Unified, not coherent, with a `shadow` as long as `mem`:** the GPU has
  its own copy. Only `toDevice` fills it, and only `fromDevice` copies
  results back, so a missing call gives wrong results, as it would on
  hardware. Imports get their shadow after `mem`'s.
- **Discrete, with `vram`:** `.device` buffers live in `vram` and have no
  CPU view. `.host` and `.upload` buffers live in `mem`, and the GPU reads
  them directly.

A dispatch may only name live buffers of the same device. Any access
outside a buffer traps, and the run returns `error.DeviceLost` with
`EmuDevice.trap` saying where it happened.

## KIR in brief

Registers are typed `u32`, `i32`, `f32`, `f16` or `pred`. Every register
holds 32 bits: an f16 sits in the low half, and a pred is 0 or 1. `mov`
reinterprets one 32-bit register as another type, which is the bit cast
between `f32` and the integers. `kir.sig`'s header table gives each op's
operands. The helpers fill unused operands with `kir.no`.

Control flow is structured: `if`/`else`/`endif` and
`loop`/`brk`/`cont`/`endloop`, nested up to 64 deep, with divergence
allowed. `brk p` and `cont p` act on the lanes where `p` is true. `ret` ends
the active lanes. Each backend emits the convergence its target needs:
BSSY/BSYNC on sm_120, and ir3's branch and `(jp)` rules on the Adreno.

Rules the interpreter enforces with traps:

- A `barrier` must be reached by every thread of the group. That means no
  divergence, and no thread may have returned earlier. Guard work with `if`
  rather than an early `ret`.
- Shared memory between two barriers: a word written by one thread may not
  be read or written by another, and a word read by one thread may not be
  written by another. Atomics are exempt. This check catches kernels that
  only work in lockstep.
- A `shfl` may only read an active lane in its subgroup. `up` and `down`
  past the subgroup's edge return the lane's own value.
- Accesses must be aligned to their width and stay inside their binding or
  the group's `shared_bytes`.
- Registers start as `0xffffffff` and shared memory as `0xa5` bytes, so a
  read before a write is visible.

Subgroups are `caps.subgroup` consecutive threads, in linear order with x
fastest. The interpreter runs any power of two from 1 to 1024 (groups have
at most 1024 threads). Real GPUs use 32 (NVIDIA) or 64/128 (Adreno). Kernels
take the width from `Caps` or from the `subgroup` op.

Integer rules:

- Arithmetic wraps mod 2^32.
- Shift amounts are taken mod 32.
- `bfe` takes `offset & 31` and clamps its width to `32 - offset`.
- `dot4` accumulates with wrapping.
- `imulhi` returns the high half of the 64-bit product: signed for `i32`,
  unsigned for `u32`.
- There is no integer division. Multiply by a reciprocal, or by a magic
  number with `imulhi`.

## Exactness

The same kernel with the same inputs and the same `Caps` gives the same bits
on every target, with one exception: NaN payloads (see below). The
interpreter is the definition; every backend is tested against it.

- **`fadd`, `fsub`, `fmul`, `fdiv`, `fsqrt`** are correctly rounded IEEE
  binary32 (round to nearest even).
- **Denormals.** With `caps.denormals == .preserve`, denormals are kept
  (gradual underflow). With `.flush`, every float op's inputs and its result
  flush to signed zero. The result flushes after rounding: if the gradually
  underflowed result is subnormal, it becomes ±0, so a result that rounds
  up to 2^-126 stays 2^-126. Comparisons and conversions read flushed
  inputs. `fabs` and `fneg` are sign-bit operations: they neither flush nor
  change a NaN's other bits, and backends implement them that way, or as
  source modifiers on ops that flush anyway.
- **`ffma`** rounds once. It is legal only where `caps.fused_fma`; the
  verifier rejects it elsewhere.
- **`fmad`** is the fast multiply-add, for code that need not be exact
  (LFM3). It rounds as `caps.mad` says:
  - `.fused`: once.
  - `.unfused`: the product is rounded (and flushed, in flush mode), then
    the sum.

  The interpreter's fused rounding is a software fma: the product is exact
  in f64, and the sum is rounded to odd. The host's `fmaf` may round twice,
  so it isn't used.
- **NaN.** Every NaN the interpreter produces is `0x7fffffff`, and so is
  every NaN the fdiv and fsqrt expansions produce. Hardware may produce other
  NaN bits for the other ops, so tests compare NaNs as NaNs.
- **`fmin`/`fmax`.** A NaN operand gives the other operand; two NaNs give
  NaN. −0 counts as less than +0.
- **Rounding ops.** `ffloor`, `fceil`, `ftrunc` and `frne` (ties to even)
  are exact, and keep the sign of zero.
- **`cvt`:**
  - float to integer rounds as `Cvt.round` says, saturates, and maps NaN to
    0, as PTX's `cvt.rzi.sat` does;
  - integer to f32 rounds in any of the four modes;
  - f32 to f16 rounds in any mode; f16 subnormals are kept; overflow goes
    to infinity or to the largest finite value (65504), as the mode says;
    NaN becomes `0x7fff`;
  - f16 to f32 is exact;
  - u32 to i32 and back is a bit cast;
  - integer to f16 has no direct form: go through f32, with two `cvt`s.
- **The approximate ops** (below) have bounds. Exact code never relies on
  their exact values.

### The exact fdiv and fsqrt

`kir.expandDiv(k, caps, dst, a, b)` and `kir.expandSqrt(k, caps, dst, a)`
emit the correctly rounded result using only ops the target has. They give
the same bits on every path, and the same bits as the interpreter's own
`fdiv`/`fsqrt`, under either denormal mode. `kir.expand(src, caps, storage)`
copies a kernel with every `fdiv` and `fsqrt` replaced by its expansion; a
backend compiles that copy.

The core runs in four steps:

1. A seed from `frcp` (or `frsq`), then one Newton step.
2. A quotient (or root) and one correction with its remainder. The result
   is now faithful: within one ulp of the true value.
3. The faithful candidate's remainder. This is exact, because the remainder
   of a faithful quotient is representable.
4. The exact decision. Let c be the truncation of the true value: the
   candidate itself, or its predecessor if the remainder is negative. c's
   remainder is exact too. The result is c, plus one ulp if the true value
   lies above c's midpoint. A quotient is never exactly a midpoint, and the
   integer form of the root comparison excludes ties.

The remainders come from different ops depending on the target:

- **Fused** (`caps.fused_fma`): a single `ffma`, as in Markstein's method.
- **Mul/add only** (no fused FMA, or fusion unknown, as on the Surface's
  Adreno): Dekker's two-product with Veltkamp's splitting (factor 4097,
  splitting off the top 12 bits), then `(a - p) - e`.

Markstein's last step, `q + r*y` with `y ≈ 1/b`, is not used. Its
correctness depends on how accurate the seed is: in a scalar study of 55
million hard and random cases it was wrong 1 to 4 times once the seed was
off by 1 to 3 ulps, and 3,900 times at 600 ulps. The decision above has no
such dependency. It is exact with seeds off by up to ±600 ulps (about
2^-14), so exact kernels do not depend on a GPU's SFU precision. The
Adreno's SFU precision has not been measured.

The fast path covers operands well inside the normal range:

- fdiv: both exponents within [−48, 48];
- fsqrt: positive, with an exponent within [−60, 100].

In that range every remainder, and every product in Dekker's method, stays
normal. All other operands go through one if-block before the core and one
after; both are skipped when every lane takes the fast path. The block before
reduces the operands to mantissas in [1,2) (fsqrt keeps the exponent's
parity, giving [1,4)) and normalizes denormals by multiplying by 2^24. The
block after rebuilds the result with integer ops: the exponent, gradual
underflow (rounded to nearest even from c's significand and its sticky bit,
c's remainder ≠ 0), overflow, the special values, then flushing if the caps
ask for it.

Every register is written once. A block's values are picked by a select
after it, and a lane that skipped the block reads whatever its registers
hold, which the select drops. A register written twice would live through
every loop around it in a backend's allocation (ir3's), so an expansion in a
loop would hold its registers for the whole loop. A GLSL fragment shader runs
inside the raster's triangle loop, where 48 divisions once took all of the
Adreno's registers.

Run on the fast path, in KIR instructions (about 16 of each are bit-cast
`mov`s, the selects after the blocks, and if/endif pairs that all lanes
skip; backends coalesce the movs and branch over the blocks):

| Expansion | fused | mul/add |
|---|---|---|
| fdiv | 42 | 77 |
| fsqrt | 33 | 61 |

The whole expansion, both paths, is 111 or 146 instructions for fdiv and
61 or 89 for fsqrt. For comparison, NVIDIA's own fast path (MUFU.RCP plus 7
FFMA, behind FCHK) is about 10 instructions; it relies on MUFU.RCP's known
accuracy. A target whose reciprocal is proven tight enough for Markstein's
last step could add that variant as an option; it would then be tested
against these.

`tests/test_gpu_exact.sig` checks the expansions in 8 configurations:
fused or mul/add, denormals kept or flushed, seeds exact or perturbed by up
to 600 ulps (`Launch.jitter_ulps`). Each result is compared bit for bit
with the interpreter's `fdiv`/`fsqrt`, which are Sig's f32 `/` and `@sqrt`
under the caps. In total that is 3.16 million divisions and 2.09 million
square roots. The divisions include:

- all special pairs;
- quotients built to lie nearest a rounding midpoint: for every 61st odd
  divisor mantissa, numerators with remainders of ±1, ±2 and ±3 at both
  quotient binades;
- gradual underflow, overflow and denormal operands;
- random bit patterns.

The square roots include a stride through every input in [1,4), at random
even scalings.

## The approximate ops' bounds

Every backend must meet these bounds. If a GPU's hardware falls short, its
backend adds a refinement step, such as one Newton step for `frcp` or
`frsq`. Exact code never uses these ops except as seeds, and the exact
expansions tolerate seeds about 2^-14 off.

| Op | Bound | Domain | NVIDIA sm_120 (PTX's documented) | Adreno |
|---|---|---|---|---|
| `frcp` | relative 2^-21 | all normals; 0 → ±inf, inf → ±0 | 1 ulp | not measured: the bring-up self-test measures it |
| `frsq` | relative 2^-21 | positive normals; 0 → ±inf, < 0 → NaN | 2^-22.9 | not measured |
| `fexp2` | relative 2^-21 | results normal | 2^-22.5 | not measured |
| `flog2` | absolute 2^-21 on [0.5, 2], relative 2^-21 elsewhere | positive normals; 0 → −inf | absolute 2^-22.6 | not measured |
| `fsin`, `fcos` | absolute 2^-20 | \|x\| ≤ π (further out, accuracy degrades with argument reduction: reduce first) | absolute 2^-20.9 | not measured |

The interpreter gives the correctly rounded `1/x` for `frcp`, and f64's
value rounded to f32 for the others. With `Launch.jitter_ulps = n`, it
perturbs each result by a fixed amount of up to n ulps, chosen from a hash
of the input, as hardware's error is: the same input always gets the same
perturbation. This proves that exact code does not depend on these ops'
precision. In flush mode their inputs and results flush too.

## Adding a GPU

A new GPU is a KIR backend plus a device adapter. Nothing else changes.

1. **The target.** Add a value to `device.Target`, for example `sm_89`,
   `ir3_a6xx`, `rdna3`, `xe` or `agx`.
2. **The backend: `src/gpu/kir_<target>.sig`.** It provides
   `pub fn compile(k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary`,
   and it must:
   - start from `kir.expand(k, caps, storage)`, so that `fdiv` and `fsqrt`
     arrive as the shared exact expansions;
   - expand `dot4` itself when `!caps.dot4`;
   - allocate registers using liveness over the structured flow;
   - legalize: `ffma` only with a native fused FMA; `fmad` as the hardware's
     mad; `fneg`/`fabs` as sign-bit ops or as modifiers on ops that flush
     anyway;
   - honor every rule in "Exactness" and "KIR in brief", including shifts
     mod 32, `fmin`/`fmax` signed zeros, and `cvt` saturation;
   - lay out the parameter block (binding addresses, then words) where its
     target reads parameters (sm_120: cbuf0 at 0x380; ir3: constants);
   - emit the target's convergence for divergent flow;
   - fill `Binary.extra` with what a dispatch needs (register counts,
     barriers, the shader config).

   Work and output memory come from the caller, through `Work.take`.
3. **Register the backend.** In `device.sig`'s backend table, add a line
   importing the backend file, and add a prong to `compileOne`'s switch.
   Each target is one line, so branches merge cleanly. Because `compileFor`
   switches on a comptime target, an image that doesn't list the new target
   doesn't link it.
4. **The adapter: `src/gpu/<vendor>_device.sig`.** It provides `over(raw
   driver device, caps) gpu.Device`. Its jobs:
   - allocation by kind;
   - import, where the driver can map CPU pages;
   - cache maintenance or write ordering for toDevice/fromDevice;
   - load: placing the code, plus any instruction-cache invalidation;
   - run: the dispatches in order (a PM4 or pushbuffer stream with each
     dispatch's state, and barriers between dispatches so each sees the one
     before's writes), with one fence for the whole run;
   - wait and done;
   - timestamps for `lastRunNs`.
5. **An emulated device** that compiles through the backend and runs on that
   target's emulator (as Q's `adreno_device.Emu` on `ir3_emu` and N's
   `nvidia_device.Emu` on `sm120_emu` do). The backend's tests run every op
   and the exact expansions there, and compare the bits with `kir_interp`
   under the same Caps.
6. **Caps.** Measure them at bring-up: whether mad is fused, how denormals
   are handled, SFU precision, the subgroup width, shared memory. Until a
   value is measured, report the conservative one: `fused_fma = false`,
   `mad = .unfused`, and `denormals = .flush` if flushing is possible. The
   exact paths are correct under any caps; only `fmad` users see the
   difference.

## The self-test

`selftest.sig` (`gpu.selftest`) checks a real `Device` against KIR's
definition. Each case builds a small kernel, compiles it for
`dev.caps.target`, runs it on the device, runs the same kernel on the CPU in
`kir_interp` under the same Caps, and compares every output word. The
emulators check the backends' code, but not everything the hardware does:
the emulated RTX ignores BSSY/BSYNC, so divergence and reconvergence there
are right only by construction. The first boot on a GPU names any op the
hardware gets wrong.

```zig
var w: gpu.selftest.Work = undefined; // WORK_BYTES, 19.5 MB (kir_ir3's compile Work is 11.5 of it): keep it static
const res = gpu.selftest.runAll(dev, &w, logLine, 2_000_000);
// or, linking one backend: gpu.selftest.runAllFor(&.{.sm_120}, dev, &w, logLine, t)
```

`runAll(dev, work, log, timeout_us) Result`. `Result` has `passed`,
`failed`, `skipped`, `first_failure[0..first_failure_len]` (also
`firstFailure()`), `gpu_ns` (the sum of `lastRunNs`) and `lost`.

**The log.** A header line names the device and its caps. Then one line a
case:

```
gpu self-test int u32: ok (106496 checked)
gpu self-test shuffles: FAILED: lane 37, word 9: got 0x0000002a want 0x00000025 (inputs ...); 64 of 19456 wrong
```

`lane` is the thread, `word` the output row (for a table case, the op,
named in brackets with its operands: `x0..x2` the inputs, `#..` an
immediate, `p0..p2` an input's bit 0 as a predicate). Flat layouts
(stores, atomics) name the word only. Then `gpu self-test: GPU time N us`
and the summary, `gpu self-test: P passed, F failed, S skipped`.

**Comparison.** Bit for bit. NaNs count as NaNs where an op may give any
NaN (float arithmetic, cvt to f32 and f16), but moves, `sel`, `fabs`,
`fneg` and shuffles must keep every bit. `fmad` may round either way (the
mad probe says which). The approximate ops are held to the bounds above
against the interpreter's value plus its own half ulp, inside their domains
only, and denormal inputs and results are not checked (an SFU may flush
them).

**Failures.** A wrong word, a compile or load error, or a timeout fails
the case, and the run goes on. A timeout waits once more; if the GPU is
still running then, it is taken as lost. A lost device (`DeviceLost` from
load, run or wait) ends the run: the cases left are skipped. An op the
backend cannot compile (`Unsupported`, such as some of ir3's cvt roundings)
is dropped from its case, which says so; a case with nothing left is
skipped. Nothing panics.

**The cases** (24; group sizes up to 256 and the subgroup width come from
the Caps):

| Case | What |
|---|---|
| int u32, int i32 | every integer op on 40 edge values crossed (and random words, small shift amounts and widths): add to bfe, imulhi, compares, sel, the predicate ops |
| int immediates | every binary op with an immediate in either slot (small, 10-bit edges, 2^24, sign bits), imad, bfe offsets and widths |
| dot4 | s8u8, s8s8 and u8u8, registers and immediates, wrapping sums |
| float, float immediates | every f32 op on 48 edge values crossed (zeros, infinities, NaNs, denormals, 2^23/2^24, near-cancelling pairs): add, sub, mul, ffma (when fused), fmad, min/max, abs/neg, the roundings, compares |
| approximate ops | rcp, rsq, log2, exp2, sin, cos against the bounds |
| exact fdiv and fsqrt | 4096 divisions (specials crossed, 1536 quotients nearest a rounding midpoint, gradual underflow and overflow, denormals, random) and 4096 roots (roots nearest a midpoint, a stride through [1,4), denormals), plus divisions by and of immediates |
| cvt rne, rz, rd, ru | f32 to u32/i32 (saturation, NaN), u32/i32 to f32, f32 to f16 (subnormals, overflow); rne also f16 to f32 (with garbage in the upper half) and the bit casts |
| global loads 8-128 | unsigned and signed 8 and 16 bit, 32, 64, 128, immediate offsets up to 0x8000 |
| global stores 8-128 | each width into a pattern, so a store that touches its neighbours shows |
| shared memory and barriers | a tree sum with a barrier per step in a uniform loop; 8 to 128-bit shared accesses read back by other threads |
| shuffles | idx (per lane, uniform, unmasked), xor (every mask), up and down past the edges, f32 payloads, a butterfly sum |
| votes | any and all over dense, sparse, uniform and lane-shaped predicates |
| global atomics, shared atomics | add/min/max/xchg u32 and i32 on own words (the old values), contended counters (the ends), tickets (every old value exactly once) |
| divergent if/else | data-dependent nesting; shuffles and votes in both branches of a lane-parity if; a shuffle and a vote after the endif (reconvergence); a 16-lane block; an early ret |
| divergent loops | per-lane trip counts with brk and cont, a vote among the lanes still looping, a predicate carried from turn to turn (and round an inner loop), shuffles in a loop whose trip count is per quad, nested loops left from inside an if |
| grid ids and params | a (3, 2, 2) grid of (8, 4, 2) groups: tid, gid, gsize, lane, subgroup, param words |
| mad probe | fused or unfused against `caps.mad` (logged, never failing) |
| denormals probe | add, mul, an underflowing product and mad: preserve or flush against `caps.denormals` (logged, never failing) |

**Cost.** One dispatch a case, 24 in all, of 1024 to 4096 threads: well
under a second of GPU time. GPU memory: three 64 KiB input buffers and a
1 MiB output buffer, allocated once. The CPU side compiles 24 kernels and
interprets each once (twice for the probes and fmad's cases).

**Where it runs.** It is allocator-free and freestanding-clean (no
std.debug, std.Io or std.fmt outside the tests), so it runs in Galaxy's
kernel and hosted, in galaxy-think. `tests/test_gpu_selftest.sig`
(`sig build test-gpu-selftest`) runs it on EmuDevice (an ideal GPU; an
Adreno-like one, unfused, flushing, subgroup 64, not coherent; a discrete
one with subgroups of 128), on the emulated RTX and on the emulated
Adreno, where every case must pass, and on a deliberately broken device,
whose wrong words, timeout and loss must be reported as failures.

## Using it

The usual sequence:

1. Build a kernel into your own storage:
   `kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, name, group)`.
2. Allocate bindings with `k.binding()` and read parameters with
   `k.param(ty, w)`.
3. Emit the body with the helpers, then call `try k.finish()`.
4. Compile: `gpu.compile(&k, dev.caps, &work, &out)`. `compile` links every
   backend, which suits tests and tools. An image for one machine uses
   `gpu.compileFor(&.{ .ir3_a7xx }, &k, dev.caps, &work, &out)` instead:
   only the listed targets' backends are referenced, and so linked. Any
   other target returns `error.Unsupported` at run time. On a freestanding
   AArch64 object (ReleaseSmall), compileFor with only the interpreter is
   6.6 KB; with only ir3_a7xx, 276 KB; with only sm_120, 230 KB; compile
   with all of them, 453 KB. `kir_interp` is linked only by code that runs
   kernels on the interpreter (EmuDevice, the backends' tests), never by
   compile.
5. Load: `dev.load(&bin)`.
6. Run: `dev.run(&.{ .{ .prog = &p, .groups = ..., .buffers = ..., .params = ... } })`.
7. Wait: `dev.wait(fence, timeout_us)`.

For the reference device:

```zig
var e = gpu.EmuDevice.init(caps, &mem, &work);
const dev = e.device();
```

Set `e.vram` for discrete memory and `e.shadow` for non-coherent unified
memory. For a launch with `regs` registers, `T` threads per group and `S`
bytes of shared memory, the interpreter's work needs about
`regs*T*4 + 18*T + 4*S + 32 KiB` bytes, plus about 32 bytes per instruction
when the program runs on EmuDevice (it decodes the program into the same
work); `kir_interp.workBytes` computes the interpreter's exact figure.

To test, run `sig build test-gpu`: the module's own tests plus
`tests/test_gpu_{ops,flow,exact,emu}.sig`.
