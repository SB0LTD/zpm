# Native Solana (sBPF) Support in zpm — Investigation Findings

READ-ONLY investigation. No files were modified. All paths are absolute.
Toolchain under test: `sig` on PATH → `C:\Just-Things\Projects\Lib\sig-latest\bin\sig.exe`
(a shim) resolving to the installed compiler
`C:\Users\Shado\AppData\Local\Programs\Sig\0.6.0` — reported by `sig env` as
`sig 0.6.0 (zig 0.17.0)`.

---

## Summary answer (read this first)

- **A real on-chain Solana sBPF program is NOT currently producible end-to-end with
  this `sig` toolchain alone.** The compiler CAN emit valid BPF ELF *object* files
  (`sig build-obj -target bpfel-freestanding -mcpu v3` produces `e_machine = 247`
  = `EM_BPF`, 64-bit little-endian — verified). But the bundled LLD linker
  **refuses to link BPF objects** (`error: ld.lld: unsupported e_machine value: 247`)
  and **dynamic linking is unavailable for the BPF target**. Solana's loader requires
  a *linked* sBPF shared object, which this toolchain cannot currently produce.
- A second, independent blocker: the Sig/Zig `compiler_rt` support library fails to
  lower for BPF (`stack arguments are not supported` for `__negxf2` f80 soft-float
  helpers) during a full `build-exe`. Building with `-fno-compiler-rt` sidesteps that
  but then hits the linker blocker above.
- **Target-variant caveat:** the arch available is upstream Zig/LLVM **`bpfel`/`bpfeb`**
  (standard eBPF, CPU models `generic/probe/v1/v2/v3/v4`). Solana's **sBPF is a custom
  eBPF variant** built from a **forked LLVM** (`solana-labs/llvm-project`, target
  `sbf-solana-solana`) with Solana-specific relocations, calling convention, and
  syscall encoding. There is **no `sbf`/`solana` arch or triple** in this `sig`.
  Whether `bpfel -mcpu v3` output is loadable by current Solana loaders is **UNKNOWN
  and unverified** (likely not, without Solana's linker/relocation handling).
- **zpm already has strong reusable primitives**: a pure, allocation-free SHA-256
  (needed for PDA derivation), base58 encode/decode for 32-byte keys, fixed-width
  little-endian serialization patterns, and Solana *client-side* wallet/auth modules.
  What is missing is the **on-chain side**: the entrypoint/ABI deserializer, syscall
  externs, a PDA finder, CPI helpers, and a working link/deploy path.

Confidence: HIGH on what the toolchain does/doesn't do (I ran it). HIGH on the ABI
facts (official Solana sources). The one UNKNOWN is explicitly flagged above.

---

## 1. Sig sBPF capability (most important)

### What I ran and what it returned

| Command | Result |
|---|---|
| `sig --help` | Zig-style driver: `build-exe`, `build-lib`, `build-obj`, `targets`, `env`, `objdump`, … |
| `sig env` | `zig_exe = …\Programs\Sig\0.6.0\bin\sig.exe`, `version = "0.17.0"`, `sig 0.6.0 (zig 0.17.0)` |
| `sig targets` | arch list includes `"bpfeb"`, `"bpfel"` (no `sbf`/`solana`/`sbpf`/`ebpf`) |
| `sig build-exe --help` | flags `-target <arch><sub>-<os>-<abi>`, `-mcpu [cpu]`, `-ofmt`, `-fno-compiler-rt` |

### (a) Is there a BPF/sBPF target available?

**Partially.** Upstream Zig/LLVM BPF is present; Solana's sBPF variant is not.

Evidence — target definition
`C:\Users\Shado\AppData\Local\Programs\Sig\0.6.0\lib\std\Target\bpf.sig`:
```
pub const Feature = enum { allows_misaligned_mem_access, alu32, dummy, dwarfris };
pub const cpu = struct {
    pub const generic / probe / v1 / v2 / v3 (alu32) / v4 (alu32) : CpuModel = …
};
```
`...\lib\std\Target.sig`:
- line 775 `pub const bpf = @import("Target/bpf.sig");`
- lines 1380-1381 arch enum members `bpfeb, bpfel`
- line 1110 `.bpfeb, .bpfel => .BPF` (ObjectFormat/machine mapping)
- line 1686 `pub inline fn isBpf(arch) bool { … .bpfel, .bpfeb => true … }`
- line 2120 default CPU for BPF arch is `&bpf.cpu.v3`

A machine-wide search of zpm + minegrind + the Sig lib for
`solana|sbpf|sbf|ebpf` found **no Solana/sBPF target, triple, relocation, or
loader support** — only the string `isBpf` in `Target.sig`.

### (b) If yes, what triple/flags select it — and does it actually emit BPF?

`-target bpfel-freestanding -mcpu v3` (little-endian eBPF, v3 CPU, no OS).

**Verified emission** — I compiled a trivial `export fn entrypoint(input: [*]u8)
callconv(.c) u64` with:
```
sig build-obj e.sig -target bpfel-freestanding -mcpu v3 -OReleaseSmall
```
→ EXIT 0, produced `e.o` (672 bytes). Inspecting the ELF header bytes:
`EI_CLASS=2` (ELFCLASS64), `EI_DATA=1` (little-endian),
`e_machine = 247` (0xF7 = **EM_BPF**). So the backend genuinely lowers to BPF
bytecode and writes a BPF ELF **object**.

### (c) What is still required (the blockers I hit)

1. **Linking a BPF program fails.** `sig build-exe … -target bpfel-freestanding
   -mcpu v3 -fno-compiler-rt -femit-bin=p.so`
   → `error: ld.lld: unsupported e_machine value: 247`.
   The bundled LLD does not accept BPF objects. Solana's real toolchain ships a
   patched LLD (`sbf-solana` target) that does the sBPF relocation/link.
2. **Dynamic linking unavailable.** `sig build-lib -dynamic -target
   bpfel-freestanding …` → `error: dynamic linking unavailable on the specified
   target`. Solana programs are shared objects, so this path is also closed.
3. **compiler_rt doesn't lower for BPF.** A plain `build-exe` without
   `-fno-compiler-rt` → `error: … in function compiler_rt.__negxf2 … stack
   arguments are not supported`. On-chain code must avoid pulling in soft-float
   compiler_rt (no `f80`/`f128`; ideally no float at all).

**Conclusion for Q1:** code generation to BPF bytecode works; the missing pieces are
(i) an sBPF-aware linker/relocation step and (ii) confirmation that LLVM-upstream
`bpfel` output is accepted by Solana loaders (the sBPF variant differs). Both are
toolchain-level, not zpm-level, and the second is **UNKNOWN** here.

### How targets are selected in practice (for comparison)

Minegrind's host builds pass `.target = null` to `ctx.addCompileStep(...)` in
`C:\Just-Things\Projects\sb0\minegrind\build.sig` (lines 63/67/71). Its **non-host**
(Android) build bypasses `build.sig` entirely and calls the compiler directly —
`C:\Just-Things\Projects\sb0\minegrind\tools\build-android.ps1`:
```
sig build-lib -dynamic -target aarch64-linux-android -O ReleaseSafe -lc … -femit-bin=…libminegrind.so
```
A Solana build would follow the same "call the compiler with an explicit `-target`"
shape — except the BPF path currently dead-ends at the linker, as shown above.
Target triples are parsed with standard Zig query syntax
(`std.sig.system.resolveTargetQuery`, `...\lib\compiler\...` / `main.sig:641`).

---

## 2. Existing zpm structure

`sig env` confirms layers are a project convention (not enforced by a manifest field);
`CONTRIBUTING.md` states the discipline: **Layer 0 (Core) never imports Layer 1
(Platform/Transport); Layer 1 never imports Layer 2 (Render).** Platform selection is
comptime via `@import("builtin").os.tag`.

### `C:\Just-Things\Projects\sb0\zpm\src\` map

| Dir | Layer | One-line purpose (modules) |
|---|---|---|
| `core/` | 0 | Pure data/compute: `sha256`, `math`, `sig_math`, `sig_mem`, `sig_testing`, `json`/`json_pull`/`jsonl`, `inflate`, `fmt`, `types`, `tokenizer`, Qwen3 LLM/TTS kernels, `wav`, `opus`, `safetensors`, `gguf`, etc. |
| `platform/` | 1 | OS bindings/IO: `win32`, `crypto` (HMAC-SHA256 via BCrypt), `file`, `gl`/`gles1`, `window`, `input`, `thread`, `timer`, `seqlock`, `subprocess`, `log`, `mcp`, `arena`, `screencap`; `platform/android/native_activity.sig` |
| `net/` | 0/1 | Native TCP/IP stack + apps: `ipv4`, `tcp`, `udp`, `arp`, `icmp`, `dhcp`, `dns`, `ethernet`, `checksum`, `http`, `websocket`/`wss`, `openrouter` |
| `transport/` | 1 | QUIC/HTTP3 stack (RFC 9000/1/2/9221): conn, streams, packet, recovery, h3, server, appmap (per README) |
| `game/` | 0 | **Deterministic, allocation-free account processor + wire formats** — `ledger_world` (rules/transitions), `action_wire` (60-byte LE action), `state_wire` (fixed-width LE account records), `action_funding` (sponsor fee reserves), `scene3d` |
| `c3/` | 0 | **Solana client-side** C³ protocol: `wallet` (ed25519 self-custody signing), `wallet_auth` (SIWS challenges + base58), `settlement`, `entity`, `allocation`, `audit`, `root` |
| `pkg/` | — | The zpm CLI/package manager itself (manifest, resolver, registry, zon, cli) |
| `render/` | 2 | Drawing: color, primitives, text, icon (per README) |
| `image/` | 0 | `image`, `png_decode`, `layout`, `text-analyze` |
| `pdf_render/` | 0 | PDF parse + rasterize + text extraction |
| `elementor/` | 0 | Structured document model |
| `lsp/` | 0 | LSP building blocks (message/document/symbols/server/loop/jwrite) |
| `asr/`,`tts/`,`llm/`,`matmul/`,`diffusion/`,`ui/`,`youtube/` | 0 | AI/inference, kernels, UI detection, misc |

Layer split in practice is confirmed by file header comments, e.g.
`game/ledger_world.sig` line 1 `//! Layer 0: deterministic, allocation-free…`,
`platform/crypto.sig` `// Layer 1: Platform`.

### Conventions (from CONTRIBUTING.md + reading modules)

- **Zero allocation** — all storage stack- or comptime-sized; in strict `.sig` mode
  allocator use is a *compile-time error*. (CONTRIBUTING "Code Style".)
- **Comptime platform dispatch** via `@import("builtin").os.tag`.
- **Vtable I/O** — I/O through function-pointer vtables (`CommandContext`,
  `HttpVtable`), keeping pure logic testable without mocks.
- **Serialization = fixed-width, explicit little-endian, never native struct layout.**
  `game/state_wire.sig` header comment: *"Fixed widths, explicit LE."*
  `game/action_wire.sig`: *"Canonical little-endian … Never serialize native struct
  layout."* Records carry a 4-byte ASCII magic + 1-byte version + reserved zero bytes,
  with explicit `NonCanonical` rejection (see `state_wire.header()`).
- **Serialization helpers** are tiny local `put`/`get` generics:
  ```
  fn put(comptime T, out, value) { inline for (0..@sizeOf(T)) |i| out[i] = @truncate(value >> (i*8)); }
  fn get(comptime T, input) T   { inline for (0..@sizeOf(T)) |i| value |= @as(T,input[i]) << (i*8); }
  ```
  (duplicated per module today — a candidate for a shared Layer-0 `bytes`/`le` module.)
- **Error handling** — explicit error sets per module (`pub const Error = error{…}`),
  composed with `||` (e.g. minegrind `program_logic.sig`
  `game.Error || actions.Error || storage.Error || error{…}`). No panics in hot paths.
- **Testing** — in-file `test "…"` blocks using `@import("sig_testing")`; NIST vectors
  for crypto (see `sha256.sig`). Also runnable "contract" executables with assertion
  counters (`sig build test-now`), so a suite with zero `test` decls can't silently pass.

### How `build.sig` wires modules; how consumers import

`C:\Just-Things\Projects\sb0\zpm\build.sig` uses the bounded `sig_build` API
(`@import("sig_build")`) exclusively (so `sig build` never falls back to Zig's
allocator-backed `std.Build`). Core helpers:
- `ctx.addModule(name, path)` registers a named module (e.g. line 100
  `addModule("ledger_world", "src/game/ledger_world.sig")`).
- `wire(ctx, module, name, path)` → `ctx.addImport(module, name, path)` wires one
  module's named import to another's source (lines 102-104 wire `action_wire`/
  `state_wire` → `ledger_world`; lines 161-163 wire `sha256` → `sig_mem`,
  `sig_testing`).
- `ctx.addTestStep{…}` / `addContract` / `addStep` / `addDependency` build the test
  graph (e.g. `test-game` step lines 110-118 lists importEntry(...) for the game
  contract).

`build_embed.sig` was referenced in the brief but **does not exist** in this tree
(only `build.sig` + the transitional `build.zig`). The embed-style, direct-compiler
module wiring instead lives in `tools/build-android.ps1` via `--dep`/`-M<name>=<path>`
flags.

**Consumer import** (minegrind):
- `C:\Just-Things\Projects\sb0\minegrind\build.sig.zon`:
  `.dependencies = .{ .zpm = .{ .path = "../zpm" } }` (sibling path dep — matches the
  development-hierarchy rule; CI fetches `SB0LTD/zpm` directly).
- `build.sig` (lines 35-62): `ctx.getDependency("zpm")`, then
  `dependency.modulePath(source, &buf)` to resolve each zpm module's absolute path,
  `ctx.addModule(name, path)`, and `ctx.addImport(module, importName, path)` to wire
  cross-module imports (e.g. `program_processor` ← `ledger_world`, `action_wire`,
  `scene3d`, `state_wire`). A consumer thus pulls **named** zpm modules, not files.

---

## 3. Existing relevant primitives (reuse vs build)

### Already in zpm (reusable for a Solana layer)

| Primitive | Location | Notes |
|---|---|---|
| **SHA-256** (pure, zero-alloc, zero platform deps, NIST-tested, streaming + one-shot) | `src/core/sha256.sig` | **Directly reusable on-chain** for PDA derivation preimages. `pub fn hash([]const u8) [32]u8`. No `std` import (uses `sig_mem`/`sig_testing`). |
| **base58** encode/decode for 32-byte keys | `src/c3/wallet_auth.sig` (`encodePublicKey`/`decodePublicKey`, canonical, leading-zero correct, test-covered) | Reusable logic, but **currently lives in a `std`-importing module**; would need extraction into a Layer-0 `base58` module to be usable in freestanding/on-chain builds. |
| **Fixed-width LE serialization pattern** + versioned/magic account records | `src/game/state_wire.sig`, `action_wire.sig` | The exact style a Solana account layer should follow. `put`/`get` generics are good candidates to promote to a shared `core/le.sig`. |
| **ed25519 sign / keypair / verify** | `src/c3/wallet.sig`, `wallet_auth.sig` (`std.crypto.sign.Ed25519`) | **Client-side only.** Uses host `std.crypto`; not for on-chain use (on-chain signature checks use the ed25519 **sysvar/precompile**, not in-program verification). |
| **SIWS challenge / Solana auth** | `src/c3/wallet_auth.sig` | Client/backend auth, header comment *"Allocator-free Solana wallet sign-in challenges."* Not on-chain. |
| **Fee/reservation arithmetic** aware of Solana fees | `src/game/action_funding.sig` | Comment: *"Settlement also applies to a failed transaction: Solana still charges its fee."* Off-chain sponsor logic. |
| **The processor to wrap** | `C:\Just-Things\Projects\sb0\minegrind\src\program_logic.sig` | `pub fn process(environment, player_account, resource, instruction)`; `Account{ address, owner, writable, data }`, `Environment{ program_id, signer, signer_verified, slot, player_pda, resource_pda }`. Header: *"shared by native contracts and a future Solana sBPF entrypoint … VM adapter must derive PDAs, authenticate account flags and obtain the Clock sysvar."* |

### Extern / syscall / FFI pattern to copy

- **`platform/win32.sig`** declares OS functions as
  `pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.c) u16;`
  and ABI structs as `extern struct { … }` with `callconv(.c)` fn pointers.
- **`platform/crypto.sig`** shows a clean extern-wrapper module (BCrypt HMAC) with
  a safe Sig surface returning `bool`/digests.

Solana syscalls would follow the same shape — `extern fn sol_log_(ptr, len) callconv(.c)
void;` etc. — but **against the Solana syscall ABI, not an OS DLL** (no library name;
resolved by the loader). No such Solana-syscall externs exist today.

### What would need to be built (not present anywhere in zpm)

- **Entrypoint + input deserializer** for the Solana loader input region (Q4 layout).
- **Solana syscall externs**: `sol_log_`, `sol_log_64_`, `sol_log_pubkey`,
  `sol_sha256`, `sol_invoke_signed_c`/`sol_invoke_signed_rust`,
  `sol_get_clock_sysvar`/`sol_get_sysvar`, `sol_memcpy_`/`sol_memset_`,
  `sol_create_program_address` / `sol_try_find_program_address`.
- **PDA finder** (`find_program_address` bump-seed loop over SHA-256(seeds ‖ bump ‖
  program_id ‖ "ProgramDerivedAddress"), rejecting on-curve results) — can reuse
  `core/sha256.sig`, but the on-curve check needs an ed25519 point-decompress that is
  **not currently a pure Layer-0 module** (only host `std.crypto`).
- **AccountInfo view** over the serialized region (pointers into the input buffer),
  plus realloc-aware data length handling.
- **CPI (`invoke`/`invoke_signed`) marshalling** structs matching the C ABI.
- **A link/deploy path** (currently blocked — see Q1).

---

## 4. Solana runtime shape (ABI the design must target)

Sources (official / widely cited; content rephrased for licensing compliance):
Solana docs [Account Runtime](https://solana.com/docs/core/accounts/account-runtime),
[CPI](https://solana.com/docs/core/cpi/cpi-execution);
SIMDs [0178 static syscalls](https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0178-static-syscalls.md),
[0219 stricter ABI](https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0219-stricter-abi-and-runtime-constraints.md),
[0267 rent_epoch constant](https://github.com/solana-foundation/solana-improvement-documents/blob/main/proposals/0267-rent-epoch-in-vm-is-a-constant.md);
[sBPFv3 upgrade](https://solana.com/upgrades/sbpfv3-programs);
input layout gist [nikkaroraa](https://gist.github.com/nikkaroraa/92e0998dc0dd6f673f7f1c1850eb71e2).

### Entrypoint input layout (all little-endian), as serialized by the loader

```
8  bytes  : number of accounts (u64)
for each account:
  1 byte  : duplicate marker — 0xFF if not a duplicate, else index of the account it duplicates
  if duplicate:     7 bytes padding (and nothing else)
  if not duplicate:
    1 byte  : is_signer (bool)
    1 byte  : is_writable (bool)
    1 byte  : is_executable (bool)
    4 bytes : padding
    32 bytes: account public key
    32 bytes: owner public key
    8  bytes: lamports (u64)
    8  bytes: data length N (u64)
    N  bytes: account data
    ~10 KiB : realloc padding (MAX_PERMITTED_DATA_INCREASE region)
    padding : align the running offset to 8 bytes
    8  bytes: rent_epoch (u64)   // per SIMD-0267 serialized as the constant u64::MAX = 0xFFFF_FFFF_FFFF_FFFF
8  bytes  : instruction data length M (u64)
M  bytes  : instruction data
32 bytes  : program id
```

The entrypoint is a single exported function receiving one pointer to this region and
returning a `u64` status (0 = success; non-zero encodes a program error). High-level
SDKs (Rust/Pinocchio) hide this; a Sig implementation must parse it directly.

### Alignment

- ABI **v0**: account input region is 1-byte aligned; ABI **v1**: 8-byte aligned
  (SIMD-0219). Some sysvar reads require 16-byte alignment.
- The historical aarch64 bug (solana-labs #21269) shows the rent_epoch alignment uses
  `align_of::<u128>()` on the *host*, which is why the serializer inserts explicit
  padding — a Sig deserializer should compute offsets from the layout above, not from
  native struct alignment.

### Syscalls a non-trivial program uses

- Logging: `sol_log_(msg,len)`, `sol_log_64_`, `sol_log_pubkey`, `sol_log_compute_units_`.
- Hashing: `sol_sha256(vals, count, out)` (can offload PDA hashing to the runtime).
- PDA: `sol_create_program_address`, `sol_try_find_program_address`.
- CPI: `sol_invoke_signed_c` / `sol_invoke_signed_rust`.
- Sysvars: `sol_get_clock_sysvar(out)` (Clock → slot/epoch/unix_timestamp), or read a
  passed-in sysvar account; `sol_get_sysvar` for the generic path.
- Memory: `sol_memcpy_`, `sol_memset_`, `sol_memmove_`, `sol_memcmp_`.
- SIMD-0178 moves these to **static syscalls** using the eBPF `call` encoding (removes
  runtime relocations) — relevant to how a future linker must emit calls.

### Clock sysvar (what `program_logic.sig` needs for `environment.slot`)

Either `sol_get_clock_sysvar` into a 40-byte Clock struct, or deserialize a Clock
account passed by the caller. The VM adapter must supply `slot` to `process(...)`.

### Return / error convention

Entrypoint returns `u64`: `0` success; non-zero is a packed error (builtin
`ProgramError` codes in the high range, or a program-defined `u32` custom code). The
runtime also fails the transaction on any syscall abort / compute-budget exhaustion.

### sBPF vs upstream eBPF (why the target variant matters)

Solana's sBPF is a **custom eBPF variant** with Solana-specific modifications; it is
not standard eBPF and is produced by a **forked LLVM** `sbf-solana-solana` target
(solana-labs #27579, #21483). Current runtimes support multiple sBPF versions and are
converging on **sBPFv3** as the standard deploy format (solana.com upgrades). The
upstream `bpfel` in this `sig` is the *generic* LLVM BPF target — related but not the
same relocation/loader contract.

---

## 5. Graphify

Commands run from `C:\Just-Things\Projects\sb0\zpm`:

- `graphify query "solana sbpf program entrypoint syscall account serialization"`
  → **"No matching nodes found."** (The knowledge graph contains **no** Solana/sBPF/
  entrypoint/syscall nodes — consistent with the file-system search: zpm has no
  on-chain Solana layer yet.)
- `graphify query "crypto sha256 base58 serialization byte encoding"`
  → returned a 3-node subgraph in the **`p256 tests`** community:
  `p256 tests` (`std/crypto/pcurves/tests/p256.zig`), `field`
  (`std/crypto/pcurves/p256/field.zig`), `scalar`
  (`std/crypto/pcurves/p256/scalar.zig`). I.e. the crypto the graph surfaces is the
  **host `std` elliptic-curve** code, not an on-chain zpm module.

`graphify-out/GRAPH_REPORT.md` overview (dated 2026-07-21): communities are dominated
by the toolchain/CLI/debug tooling and `std` crypto test suites (`p256 tests`,
`p384 tests`, `secp256k1 tests`), plus a hyperedge *"zpm Architecture Layers and
Official Packages."* No Solana community/hub exists. This corroborates: **the Solana
story in this repo is entirely client-side (`c3/`) today; there is no on-chain graph
footprint.**

---

## Design implications (facts → implications only; no design, no code)

### Is a real sBPF program possible with the current Sig toolchain?

**NO, not end-to-end today — with a nuance.**
- **Codegen: YES.** `sig build-obj -target bpfel-freestanding -mcpu v3` emits a valid
  64-bit LE **EM_BPF object** (verified `e_machine=247`).
- **Linking/deploy: NO.** The bundled LLD rejects BPF objects
  (`unsupported e_machine value: 247`) and dynamic linking is unavailable for BPF.
  `compiler_rt` also fails to lower for BPF unless disabled. A deployable sBPF `.so`
  cannot be produced by this `sig` alone.
- **Solana-loadability of `bpfel` output: UNKNOWN.** Even if linked, upstream LLVM
  `bpfel` is not Solana's forked `sbf-solana-solana` variant; relocation/version
  compatibility with current loaders (converging on sBPFv3) is unverified here.

### zpm primitives that already exist to reuse

- `src/core/sha256.sig` — pure, allocation-free, no `std` → **ready for on-chain PDA
  hashing** (or offload to `sol_sha256`).
- base58 and fixed-width-LE serialization *logic* exists (`c3/wallet_auth.sig`,
  `game/state_wire.sig`, `game/action_wire.sig`) but is either `std`-coupled or
  duplicated per module.
- The account processor to wrap is `minegrind/src/program_logic.sig` with a clear,
  VM-adapter-shaped contract (`Account`, `Environment`, `process(...)`).

### New modules that would be needed, and the layer each belongs to

- **Layer 0 (Core), pure, no `std`, no float:**
  - `core/base58.sig` — extract/generalize base58 from `c3/wallet_auth.sig`.
  - `core/le.sig` (or `core/bytes.sig`) — promote the `put`/`get` LE helpers.
  - `solana/account_layout.sig` — the Q4 input-region layout + `AccountInfo` views
    and a deserializer (pure parsing over a caller-provided buffer).
  - `solana/pda.sig` — `find_program_address` bump loop (needs SHA-256 + an on-curve
    check; the on-curve check requires a **new** pure ed25519 point module, since
    today ed25519 only exists via host `std.crypto` in `c3/`).
  - `solana/program_error.sig` — the `u64` return/error encoding.
- **Layer 1 (Platform) — a new Solana sub-platform (freestanding/BPF target):**
  - `platform/solana/syscalls.sig` — `extern … callconv(.c)` syscall declarations
    (logging, sha256, PDA, CPI, sysvars, mem) following the `win32.sig`/`crypto.sig`
    extern pattern, but bound to the Solana syscall ABI (no DLL name).
  - `platform/solana/entrypoint.sig` — the exported entrypoint that parses the input
    region and calls a consumer processor (e.g. minegrind's `process`).
  - `platform/solana/cpi.sig`, `platform/solana/clock.sig` — CPI marshalling and the
    Clock sysvar fetch supplying `Environment.slot`.
- **Build/toolchain (NOT a zpm module):** an sBPF-capable link step (patched LLD /
  Solana linker) and `build-obj → link → deploy` wiring. This is the gating item.

### Open design decisions a human must make

1. **Linker/toolchain:** adopt Solana's forked LLVM/LLD `sbf-solana` target, or extend
   the SB0LTD `sig` fork to link BPF objects and emit sBPF-compatible relocations?
   Without this, nothing deploys. (This decision dominates all others.)
2. **Target variant/version:** which sBPF version to aim at (loaders are moving to
   **sBPFv3**), and whether upstream `bpfel -mcpu v3/v4` is ever acceptable or a
   Solana-specific CPU/target is mandatory.
3. **PDA hashing & on-curve:** compute PDAs in-program (reuse `core/sha256.sig` + a new
   pure ed25519 point module) vs. offload to `sol_sha256`/`sol_try_find_program_address`
   syscalls. The on-curve check is the one real crypto gap in Layer 0.
4. **ABI version target:** v0 (1-byte align) vs v1 (8-byte align) and the SIMD-0267
   `rent_epoch = u64::MAX` constant; and static syscalls (SIMD-0178) vs legacy
   relocated syscalls — affects both the deserializer and the link step.
5. **compiler_rt / no-float policy:** enforce a float-free, `-fno-compiler-rt` on-chain
   subset (strict Sig mode already bans allocation, which aligns well).
6. **Layer placement of Solana code:** confirm a new `src/solana/` (Layer 0 parsing/PDA)
   + `src/platform/solana/` (Layer 1 syscalls/entrypoint) split, versus folding it into
   existing `c3/` (which is currently client-side only).
7. **Consumer wiring:** how minegrind selects a Solana build (a dedicated
   `build-obj`/link path like `tools/build-android.ps1`, since `build.sig`'s
   `addCompileStep` currently targets host with `.target = null`).

### What I could NOT verify

- Whether any linked/`bpfel` artifact from this `sig` is actually **accepted by a
  Solana loader** (no validator/loader was run; linking itself failed first).
- Whether the SB0LTD `sig` fork has an unreleased/undocumented sBPF path (none found in
  `targets`, the std `Target` definitions, or a repo/machine search — but I only
  inspected the installed 0.6.0 tree, not the compiler's full source).
- Exact current Clock struct byte layout and the precise per-loader input-region
  variations across sBPF versions (I cited the stable, documented layout; version-
  specific deltas were not exhaustively verified).
- `build_embed.sig` behavior — the file named in the brief does not exist in this tree.
```
