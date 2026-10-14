# Native Solana On-Chain Support Layer — Technical Design (zpm, Pure Sig)

Status: DESIGN (revision 3, post-review). Design-only; no implementation files were
written. This revision resolves all findings (1 MEDIUM + 4 NIT) from the second design
review at
`C:\Just-Things\Projects\sb0\minegrind\.agents\tasks\solana-onchain-layer-design-review.md`
(see §11 for the point-by-point responses).
Author: design subagent. Scope: a comprehensive, robust, maintainable **native Solana
on-chain support layer written in PURE SIG**, living in the zpm package library. Every
runtime artifact is Sig and lives in zpm. The Agave/Solana toolchain is **REFERENCE
ONLY** (reference disassembler + test validator): never a build dependency, never
linked, no Rust, no Solana SDK import. Client-side `src/c3/` stays separate from the new
on-chain code.

Convention used throughout: **[VERIFIED]** = confirmed by reading a real file or running
a real command during this design pass (path/line or command cited). **[RECOMMENDATION]**
= a design choice this document makes. **[UNVERIFIED]** = asserted but not confirmed here.

Absolute paths are used everywhere (the authoring cwd is the minegrind workspace, not
zpm).

---

## 0. Correction to the prior investigation (read first)

The task brief asserted that "a direct grep found NO base58 anywhere in zpm/src/" and
instructed me to treat the prior investigation's base58 claim as wrong. **That assertion
is itself incorrect, and the prior investigation was RIGHT.** Base58 encode/decode does
exist, exactly where the investigation said:

- **[VERIFIED]** `C:\Just-Things\Projects\sb0\zpm\src\c3\wallet_auth.sig`
  - line 17: `const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";`
  - `pub fn encodePublicKey` at **line 148** (`encodePublicKey(public_key: *const [PUBLIC_KEY_SIZE]u8, output: *[44]u8) usize`) — Bitcoin/Solana base58 big-integer `*256`/`%58` encode, leading-zero handling.
  - `pub fn decodePublicKey` at **line 177** (`decodePublicKey(encoded: []const u8, output: *[PUBLIC_KEY_SIZE]u8) bool`) — canonical decode with a round-trip re-encode equality check (the closing `std.mem.eql` round-trip is at **line 203**).

  (Cited by symbol name first, with the re-verified line numbers this pass via `Select-String`, to stay drift-proof.)

Why the brief's grep "found nothing": the agent-facing `grep_search` tool returns **"No
matches found"** for these `.sig` files (confirmed during this pass — a tool indexing
limitation, not a fact about the repo). A direct `Select-String` over the same file
returns all the lines above. **Lesson baked into this design: verify `.sig` content with
a shell `Select-String`/`findstr`, not only the indexed grep tool.**

**The nuance that actually matters for the design** (and that the investigation also got
right): this base58 is **not reusable as-is on-chain** because:
1. It lives in a module that does `const std = @import("std");` and
   `const Ed25519 = std.crypto.sign.Ed25519;` (**[VERIFIED]** wallet_auth.sig lines 5-6).
   A freestanding sBPF build must not pull in host `std`/`std.crypto`.
2. `decodePublicKey` calls `std.mem.indexOfScalar` and `std.mem.eql` (**[VERIFIED]**
   wallet_auth.sig: `std.mem.indexOfScalar` at line 181, round-trip `std.mem.eql` at
   line 203) — std-coupled.
3. It is hard-wired to 32-byte input and a 44-byte output buffer; it is a *pubkey* codec,
   not a general base58 codec.

So the design still calls for a **new pure Layer-0 `base58` module** — but as an
**extraction/generalization of the proven algorithm in wallet_auth.sig**, not a
from-scratch build. That is a smaller, lower-risk task and the test vectors can be
cross-checked against the existing implementation.

---

## 1. Verified ground truth (facts this design rests on)

### 1.1 Toolchain
- **[VERIFIED]** `sig version` → `sig 0.6.2 (zig 0.17.0)`; `sig env` reports
  `.version = "0.17.0"`. (Matches the brief's stated 0.6.2.)
- **[VERIFIED] Build recipe produces a Solana sBPF shared object.** Ran, this pass:
  ```
  sig build-lib e.sig -dynamic -target bpfel-solana -mcpu sbpfv3 -O ReleaseSmall -fno-compiler-rt -femit-bin=e.so
  ```
  on a trivial `export fn entrypoint(input: [*]u8) callconv(.c) u64 { _ = input; return 0; }`.
  Result EXIT 0, 192-byte `e.so` with ELF header bytes: **e_machine=247 (EM_BPF)**,
  **e_type=3 (ET_DYN)**, **e_flags=3 (sbpfv3)**.
- **[VERIFIED] CORRECTION to the brief's recipe:** the optimize flag must be written
  **`-O ReleaseSmall` (space-separated)**, not `-OReleaseSmall`. With `-OReleaseSmall`
  the driver mis-parses and fails with `error: .so: file not found` (reproduced this
  pass). `sig build-lib --help` confirms the spelling is `-O [mode]` and
  `-femit-bin[=path]`.
- **[VERIFIED] The objdump gap is real.** The emitted `.so` has **e_shnum=0** and
  **e_shoff=0** (no section headers). `sig objdump -d e.so` prints only
  `e.so: ELF 64 shared object` / `Disassembly (sbpfv3):` and **no instructions**. This is
  the known gap; the workaround is Agave's forked `llvm-objdump` (section-independent BPF
  disassembly).
- **[VERIFIED] `solana-test-validator` is installed locally** at
  `C:\Users\Shado\.local\share\solana\install\releases\stable-47f9a3f06bd0c60ccff5a0e3935dd2ca7a46651d\solana-release\bin\solana-test-validator.exe`.
- **[UNVERIFIED] `llvm-objdump` (Agave fork) was NOT found on disk this pass.** Searched
  `C:\Users\Shado\.local\share\solana` and `C:\Users\Shado\.cache` for `llvm-objdump*`
  → no hits. The Agave *platform-tools* SDK (which ships the forked llvm-objdump) is a
  separate download fetched by `cargo-build-sbf`/`agave-install`. Treat installing it as
  a **verification-harness prerequisite** (§7), not an assumed present tool. This is the
  only toolchain claim in the brief I could not confirm firsthand.
- **[VERIFIED] implication of `-fno-compiler-rt`:** on-chain code must be **float-free
  and allocation-free** (soft-float compiler_rt fails to lower for BPF; strict `.sig`
  mode already bans the allocator — CONTRIBUTING.md "Code Style").

### 1.2 zpm structure, conventions, reusable primitives
- **[VERIFIED] SHA-256 is pure, zero-alloc, Layer 0, no `std`.**
  `C:\Just-Things\Projects\sb0\zpm\src\core\sha256.sig`:
  - line 6-7: imports only `sig_mem` and `sig_testing` (no `std`).
  - `pub fn hash(data: []const u8) [DIGEST_LEN]u8` (DIGEST_LEN=32), plus streaming
    `Sha256` struct `init`/`update`/`final`. Big-endian digest output, NIST-vector tested
    in-file. **Directly reusable on-chain for PDA hashing.**
- **[VERIFIED] Fixed-width LE wire style with magic+version+reserved-zero and explicit
  `NonCanonical` rejection, and locally-duplicated `put`/`get` generics:**
  - `C:\Just-Things\Projects\sb0\zpm\src\game\state_wire.sig` — header comment
    "Fixed widths, explicit LE." (line 1); `fn put` (line 10) / `fn get` (line 13);
    `fn header` (line 18) checks 4-byte magic, `input[4] != 1 → InvalidHeader`,
    `input[5] != 0 → NonCanonical`; `Error = error{ InvalidLength, InvalidHeader,
    NonCanonical }` (line 3). (Cited by symbol name to stay drift-proof.)
  - `C:\Just-Things\Projects\sb0\zpm\src\game\action_wire.sig` — header "Canonical
    little-endian … Never serialize native struct layout." (line 1); identical
    `fn put` (line 5) / `fn get` (line 8) duplicated; `decode` rejects reserved non-zero
    bytes with `NonCanonical` (`Error` line 4). **This duplication is the thing to
    promote into a shared Layer-0 LE module.**
- **[VERIFIED] extern-FFI pattern.** `C:\Just-Things\Projects\sb0\zpm\src\platform\gl.sig`
  lines 35-46: `pub extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.c)
  void;` — i.e. `extern "<lib>" fn … callconv(.c) …`. `platform\win32.sig` wraps
  `std.os.windows` rather than declaring raw externs, and `platform\crypto.sig`
  (Layer 1, BCrypt HMAC) shows the "thin safe Sig surface over an extern layer" shape.
  **Design note:** Solana syscalls have **no DLL/library name** (the loader resolves
  them), so the Solana externs will differ from the gl.sig form — see §4.3 for the exact
  resolution-strategy decision.
- **[VERIFIED] Layer discipline is a convention, enforced by review, not a manifest
  field.** CONTRIBUTING.md "Code Style": "Layer 0 (Core) never imports from Layer 1
  (Platform/Transport) or Layer 2 (Render)." Plus zero-allocation, comptime
  `@import("builtin").os.tag` dispatch, static buffers.
- **[VERIFIED] zpm build wiring API.** `C:\Just-Things\Projects\sb0\zpm\build.sig` uses
  `@import("sig_build")` exclusively. Primitives: `ctx.addModule(name, path)` (e.g.
  sha256 wired at the `const sha256 = try ctx.addModule("sha256", "src/core/sha256.sig")`
  line), `wire(ctx, module, name, path)` → `ctx.addImport(...)` (sha256 wires `sig_mem`
  and `sig_testing`), `ctx.addStep`, `addContract`, `ctx.addDependency`,
  `ctx.addCompileStep{ .source_path, .output_name, .cache_dir, .optimize, .target,
  .imports, .compiler_path }`. There is **no `build_embed.sig`** in the tree.
- **[VERIFIED] c3 is client-side and separate.** `C:\Just-Things\Projects\sb0\zpm\src\c3\`
  contains `allocation.sig, audit.sig, entity.sig, root.sig, settlement.sig,
  wallet_auth.sig, wallet.sig`. `wallet.sig`/`wallet_auth.sig` use `std.crypto.sign.Ed25519`
  (host signing/verification) — **off-chain only**. The new on-chain layer must not live
  in or import `c3/`.

### 1.3 The processor this layer must drive
- **[VERIFIED]** `C:\Just-Things\Projects\sb0\minegrind\src\program_logic.sig`:
  - header comment lines 1-2: "Account processor shared by native contracts and a future
    Solana sBPF entrypoint. Environment is supplied by the VM adapter, never decoded from
    an instruction."
  - `pub const Account = struct { address: game.Key, owner: game.Key, writable: bool,
    data: []u8 };`
  - `pub const Environment = struct { program_id: game.Key, signer: game.Key,
    signer_verified: bool, slot: u64, player_pda: game.Key, resource_pda: ?game.Key =
    null };`
  - `pub const Error = game.Error || actions.Error || storage.Error || error{
    WrongAccount, ReadOnly, UnexpectedResource };`
  - `pub fn process(environment: Environment, player_account: Account, resource: ?Account,
    instruction: []const u8) Error!void` — validates `signer_verified`, PDA ownership and
    writability, decodes the action and account records, applies game rules, memcpys
    results back into `account.data`.
  - comment lines 19-20: "VM adapter must derive PDAs, authenticate account flags and
    obtain the Clock sysvar." **This is the exact contract the entrypoint adapter in §5
    satisfies.**
- **[VERIFIED]** `game.Key = [32]u8` and `pub fn sameKey(a: Key, b: Key) bool`
  (`C:\Just-Things\Projects\sb0\zpm\src\game\ledger_world.sig` lines 3, 24). So a Solana
  32-byte pubkey maps directly onto `game.Key` with no conversion.

### 1.4 Consumer build wiring
- **[VERIFIED] host build** (`C:\Just-Things\Projects\sb0\minegrind\build.sig`): wires zpm
  modules via `ctx.getDependency("zpm")` → `dependency.modulePath(source, &buf)` →
  `ctx.addModule` + `ctx.addImport`, then `ctx.addCompileStep(.{ … .target = null … })`
  (host). `program_processor` module = `src/program_logic.sig`, wired with
  `ledger_world`, `action_wire`, `scene3d`, `state_wire`, `minegrind_world`.
- **[VERIFIED] non-host build** (`C:\Just-Things\Projects\sb0\minegrind\tools\build-android.ps1`):
  bypasses `build.sig` and calls the compiler directly:
  `sig build-lib -dynamic -target aarch64-linux-android -O ReleaseSafe … -Mroot=…src/android.sig`
  with per-module `--dep <name>` then `-M<name>=<abs path>` flags. **This is the template
  for the Solana build-lib path** (§5): `addCompileStep` targets host only, so a non-host
  target needs the direct-compiler `--dep`/`-M` style.
- **[VERIFIED]** `C:\Just-Things\Projects\sb0\minegrind\build.sig.zon` (per prior
  investigation; consistent with hierarchy rules): `.dependencies = .{ .zpm = .{ .path =
  "../zpm" } }` — sibling path dep to `SB0LTD/zpm`. No `Lib/zpm` mirror.

---

## 2. Overview

The layer is split along the hard development-hierarchy boundary:

- **Layer 0 (Core)** — pure, `std`-free, float-free, allocation-free computation that is
  identical on-chain and off-chain: byte (LE) helpers, base58, the entrypoint input-region
  **parser** (operating over a caller-supplied `[]u8`/`[*]u8`), `AccountInfo` views, the
  PDA bump-loop algorithm, and the `u64` program-error encoding. **Layer 0 never imports
  Layer 1** — so every byte of parsing/crypto/encoding is unit-testable on the host under
  `sig build test` with hand-built buffers.
- **Layer 1 (Platform)** — the Solana *runtime binding*: `extern` syscall declarations,
  the exported `entrypoint` symbol that reads the loader's input region (using Layer-0
  parsing) and dispatches to a consumer `process`-style function, CPI marshalling, and the
  Clock sysvar fetch. This layer only compiles meaningfully for the `bpfel-solana` target;
  on the host it is replaced by a **pure simulator** (see §9 open decision 5 /
  §5.4) so host tests can exercise the full entrypoint path.

The design deliberately mirrors the existing `game/*_wire.sig` style (fixed-width LE,
explicit canonical rejection, per-module `Error` sets, in-file tests) so it reads as a
natural extension of zpm, not a foreign subsystem.

Chosen defaults, stated up front and locked unless a §9 decision overrides them:
- **ABI v1 (8-byte aligned), sBPFv3** target. [VERIFIED the toolchain emits sbpfv3.]
- **SIMD-0267**: `rent_epoch` parsed as the constant `u64::MAX` (parser does not trust it;
  §4.1).
- **SIMD-0178** static syscalls assumed (no runtime syscall relocations); the externs are
  declared so the compiler emits direct `call` encodings.
- **PDA default = syscall** (`sol_try_find_program_address`) on-chain; **pure Layer-0 PDA
  = off-chain/testing only**, with the ed25519 on-curve check **deferred** (§3).

---

## 3. PDA strategy decision

**Problem.** `find_program_address(seeds, program_id)` iterates a bump byte from 255 down,
computing `sha256(seeds ‖ bump ‖ program_id ‖ "ProgramDerivedAddress")` and **rejecting
any result that is a valid ed25519 curve point** (on-curve), returning the first
off-curve address + its bump. The SHA-256 half is trivial to reuse ([VERIFIED]
`core/sha256.sig`). The **on-curve check is the one genuinely hard new Layer-0 crypto
primitive**: it needs ed25519 point decompression + curve-equation validation over the
field `2^255 - 19`, which today exists only via host `std.crypto` in `c3/` ([VERIFIED]
wallet_auth.sig line 6) and therefore cannot be used on-chain.

**Decision.**
- **[RECOMMENDATION] On-chain default: offload to the `sol_try_find_program_address`
  syscall.** The runtime computes both the hash and the on-curve check; this is
  compute-cheaper than an in-program implementation, is the canonical reference behavior,
  and sidesteps building ed25519 field math in Sig. The entrypoint adapter uses this to
  derive `Environment.player_pda` / `resource_pda`.
- **[RECOMMENDATION] Off-chain/testing path: a pure Layer-0 `pda.sig`** that computes the
  SHA-256 preimage and bump loop, with the on-curve check **initially DEFERRED** via an
  injected predicate (see API §4.5). Rationale: the deserializer, error encoding, and PDA
  *preimage/bump* logic are all independently valuable and testable now; building a
  correct, constant-time-enough, test-vector-backed ed25519 field/point module is a large
  separate effort that should not block the first deployable program.
- **[RECOMMENDATION] On-curve: BUILD it later as its own Layer-0 module
  (`core/ed25519_point.sig`), not now.** Reasoning: deferring is safe because (a) on-chain
  uses the syscall anyway, and (b) off-chain PDA derivation can, in the interim, confirm a
  candidate by calling the host `std.crypto` on-curve check **inside test code only** (not
  in the Layer-0 module), or by cross-checking against addresses the validator produced.
  The explicit gap: until `ed25519_point.sig` exists, the pure `pda.sig` cannot *reject
  on-curve* on a freestanding host-free target by itself — it depends on an injected
  predicate, which for real derivation must be the real check. This is called out as open
  decision §9.2.

---

## 4. Module breakdown, exact paths, layer assignment, and public API

Layer placement **[RECOMMENDATION]**: new Layer-0 code under `src/solana/` (pure) and new
Layer-1 code under `src/platform/solana/` (runtime binding). This keeps the hard boundary
visible in the path and leaves `c3/` untouched. (Alternative — folding into `c3/` — is
rejected: `c3/` is std-coupled client code; §9.3.)

### 4.1 `src/solana/le.sig` — Layer 0 — shared little-endian byte helpers
Promotes the duplicated `put`/`get` generics from `state_wire.sig`/`action_wire.sig` into
one module. Pure, no `std`.

```sig
pub fn putLe(comptime T: type, out: []u8, value: T) void;      // writes @sizeOf(T) LE bytes
pub fn getLe(comptime T: type, input: []const u8) T;           // reads  @sizeOf(T) LE bytes
pub fn readU64(input: []const u8, offset: usize) u64;          // bounds-free convenience (caller guarantees len)
```
Behavior is byte-identical to the existing generics (so `state_wire`/`action_wire` can
later adopt it without wire changes — a non-goal for this layer but a stated compatibility
property). No error set: these are infallible given a correctly-sized slice; the *callers*
(deserializer) own bounds checking. Unit-tested against the existing `put`/`get` outputs.

### 4.2 `src/solana/base58.sig` — Layer 0 — general base58 codec
Extraction + generalization of `wallet_auth.sig`'s proven algorithm, with **no `std`**.

```sig
pub const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
pub const Error = error{ InvalidChar, OutputTooSmall, NonCanonical };

/// Encode `input` bytes into `out`; returns the number of chars written.
pub fn encode(input: []const u8, out: []u8) Error!usize;
/// Decode `encoded` into `out`; returns number of bytes written. Rejects
/// non-alphabet chars and (optionally) non-canonical leading-zero mismatch.
pub fn decode(encoded: []const u8, out: []u8) Error!usize;

/// Pubkey-sized conveniences (match the c3 surface for easy cross-checking).
pub fn encodeKey(key: *const [32]u8, out: *[44]u8) usize;
pub fn decodeKey(encoded: []const u8, out: *[32]u8) Error!void;
```
Replaces the std calls: `std.mem.indexOfScalar` → a local alphabet lookup; `std.mem.eql`
→ a local byte compare. **Validation:** required chars must be in `ALPHABET`
(`InvalidChar`); decode output buffer must fit (`OutputTooSmall`); canonical check
(leading-'1' count must equal decoded leading-zero count, and a round-trip re-encode must
match) → `NonCanonical`. **Tests:** cross-check `encodeKey`/`decodeKey` against the exact
outputs of `c3/wallet_auth.sig` for several keys (including all-zero and leading-zero
keys), plus known Solana address vectors.

### 4.3 `src/solana/entrypoint_input.sig` — Layer 0 — input-region parser + AccountInfo views
Pure parser over a caller-supplied buffer (`[]u8` on host sim; `[*]u8` cast to a bounded
slice on-chain). **No pointer arithmetic beyond offset bookkeeping; every field read is
bounds-checked against the buffer length.**

#### 4.3.1 The EXACT byte layout parsed (ABI v1, 8-byte aligned, sBPFv3)
All multi-byte integers little-endian. Offsets below are the running cursor; `align8(x)`
rounds up to the next multiple of 8.

```
offset 0:            u64   num_accounts
for each account i:
  +0:   u8    dup_marker       // 0xFF = not a duplicate; else = index j (< i) this duplicates
  if dup_marker != 0xFF:
    +1:   u8[7]            padding (ignored; MUST be present)
    (account i aliases account j: same key/owner/lamports/data; cursor advances 8 total)
  else:
    +1:   u8    is_signer      (0/1)
    +2:   u8    is_writable    (0/1)
    +3:   u8    is_executable  (0/1)
    +4:   u32               original_data_len — NOT consumed by this parser (no realloc
          //                support in Phase 4); skipped as reserved. Confirm the width
          //                (u32) and semantics against the reference-only Agave serializer
          //                in Phase 1.
    +8:   u8[32]            key      (pubkey)
    +40:  u8[32]            owner    (pubkey)
    +72:  u64               lamports
    +80:  u64               data_len (N)
    +88:  u8[N]             data
    +88+N: u8[MAX_PERMITTED_DATA_INCREASE] realloc padding  // 10 * 1024 = 10240
    then: pad cursor to align8()
    then: u64               rent_epoch   // SIMD-0267: serialized as constant u64::MAX
after all accounts:
  u64   instruction_data_len (M)
  u8[M] instruction_data
  u8[32] program_id
```
Constants: `MAX_PERMITTED_DATA_INCREASE = 10240` (**[UNVERIFIED]** — not independently
confirmed this pass; the authoritative reference-only source to confirm in Phase 1 is
Agave `solana_program::entrypoint::MAX_PERMITTED_DATA_INCREASE` (reference-only, never
linked). Flagged in §9.6 and §10). `DUP_MARKER_NONE = 0xFF`.

**Reserved/canonical handling (mirrors state_wire's NonCanonical discipline):**
- `rent_epoch` is **not trusted**; parser records it but callers must not branch on it
  (SIMD-0267 makes it constant). The parser MAY assert it equals `0xFFFF_FFFF_FFFF_FFFF`
  under a debug flag; by default it is accepted and ignored.
- `is_signer`/`is_writable`/`is_executable` bytes **must be 0 or 1**; any other value →
  `error.NonCanonical`.
- A `dup_marker` other than `0xFF` must be `< i` → else `error.MalformedInput`.
- Every field access validates `cursor + width <= buf.len` → else `error.Truncated`.

#### 4.3.2 Types and API
```sig
pub const Error = error{ Truncated, MalformedInput, NonCanonical, TooManyAccounts };
pub const MAX_ACCOUNTS = 64;              // [RECOMMENDATION] static cap (zero-alloc); see §9
pub const Pubkey = [32]u8;

pub const AccountInfo = struct {
    key: *align(1) const Pubkey,          // view into the input buffer (no copy)
    owner: *align(1) const Pubkey,
    lamports: *align(1) u64,              // writable in place (on-chain mutation)
    data: []u8,                           // length = data_len; realloc region not exposed
    is_signer: bool,
    is_writable: bool,
    is_executable: bool,
    is_duplicate: bool,
    dup_index: u8,                        // valid iff is_duplicate
    // rent_epoch intentionally omitted from the ergonomic surface (constant per SIMD-0267)
};

pub const Input = struct {
    accounts: [MAX_ACCOUNTS]AccountInfo,
    num_accounts: usize,
    instruction_data: []const u8,
    program_id: *align(1) const Pubkey,
};

/// Parse the loader input region. `buf` is the whole serialized region.
pub fn parse(buf: []u8) Error!Input;
```
`parse` is the single hard-to-misuse entry: it returns typed views, never raw offsets.
Duplicate accounts are resolved to point at the original's fields (so a consumer that
indexes `accounts[i]` always sees correct key/owner/data). `align(1)` pointers acknowledge
the region's packing; reads go through `le.getLe`/`@memcpy` to avoid unaligned-load UB.

### 4.4 `src/solana/program_error.sig` — Layer 0 — u64 return/error encoding
```sig
pub const SUCCESS: u64 = 0;

// Builtin ProgramError variants. Discriminant VALUES are intentionally omitted here:
// the real builtin encoding is a fixed enum defined by the Solana ABI, NOT a sequential
// 0x1000000NN scheme. DO NOT assign literals until they are fixed in Phase 1 against the
// authoritative reference-only source. The variant NAMES are the stable design surface.
pub const ProgramError = enum(u64) {
    invalid_argument,
    invalid_instruction_data,
    invalid_account_data,
    account_data_too_small,
    missing_required_signature,
    account_already_initialized,
    // … full set enumerated against the authoritative encoding during Phase 1
    // (values fixed in Phase 1; do not implement discriminants until confirmed).
};

/// Encode a program-defined custom error (u32) into the u64 return space.
/// The concrete packing base (the "custom error" base the runtime ORs the u32 into) is
/// left unspecified here and MUST be set in Phase 1 against the authoritative source.
pub fn custom(code: u32) u64;
/// Encode a builtin ProgramError variant into its ABI u64 return code.
pub fn builtin(e: ProgramError) u64;
```

**Error-mapping ownership (resolves review Finding 1).** zpm Layer-0 `program_error.sig`
exposes **only the ABI-level encoders** — `SUCCESS`, `custom(code: u32)`, and
`builtin(e: ProgramError)`. It deliberately provides **no generic
`fromError(anyerror) u64`**. A parameterless generic over `anyerror` cannot emit stable,
program-specific custom codes and would silently lose compile-time exhaustiveness over a
consumer's concrete error set. Instead, **the consumer owns an exhaustive mapping** from
its own error set to a `u64`, built out of these encoders. For minegrind this lives in the
project layer (`minegrind/src/solana_program.sig`), as an exhaustive `switch` over
`program_logic.Error` so a newly added error variant is a compile error until it is
mapped:

```sig
// minegrind/src/solana_program.sig (project layer — NOT zpm):
fn mapError(err: program_logic.Error) u64 {   // exhaustive over the known set
    return switch (err) {
        error.Unauthorized        => program_error.builtin(.missing_required_signature),
        error.WrongAccount        => program_error.custom(1),
        error.ReadOnly            => program_error.custom(2),
        error.UnexpectedResource  => program_error.custom(3),
        // … one arm per program_logic.Error variant; the game.Error/actions.Error/
        //    storage.Error members folded in are mapped here too …
    };
}
```

(If a reusable helper is ever wanted in zpm, it must take the table explicitly —
`fromError(err: anyerror, table: []const ErrEntry) u64` — never a bare `anyerror`
overload; the design does not include one because the consumer switch is simpler and
exhaustiveness-checked.)
**[UNVERIFIED] — IMPLEMENTER RULE: do not hard-code any `ProgramError` discriminant or the
`custom()` base until they are confirmed in Phase 1.** The numeric encoding of builtin
`ProgramError` is a fixed enum defined by the Solana ABI (reference-only source: Agave
`solana_program::program_error::ProgramError` and its `From`/`to_u64` mapping, plus the
`CUSTOM_ZERO`/custom-error base used by `ProgramError::Custom(u32)`); it is NOT the
sequential `0x1000000NN` scheme a naive design might invent. Only the *shape* is
[VERIFIED] from the brief and standard Solana documentation: a `u64` return, `0` = success,
builtin errors occupy a reserved high range, and a program-defined custom error carries a
`u32` ORed into a custom base. Variant names above are the stable part of the design;
discriminants are a Phase-1 deliverable.

### 4.5 `src/solana/pda.sig` — Layer 0 — pure find_program_address (off-chain/testing)
```sig
pub const Error = error{ NoViableBump, TooManySeeds, SeedTooLong };
pub const PDA_MARKER = "ProgramDerivedAddress";
pub const MAX_SEEDS = 16;
pub const MAX_SEED_LEN = 32;

/// Compute the SHA-256 preimage digest for a given bump (does NOT check on-curve).
pub fn deriveWithBump(seeds: []const []const u8, bump: u8, program_id: *const [32]u8) [32]u8;

/// Find the canonical PDA + bump. `on_curve` is an injected predicate so this module
/// stays Layer-0 and std-free; pass the real ed25519 check (future `ed25519_point.sig`)
/// for correct derivation, or a test stub for buffer tests.
pub fn findProgramAddress(
    seeds: []const []const u8,
    program_id: *const [32]u8,
    on_curve: *const fn (*const [32]u8) bool,
    out_pubkey: *[32]u8,
) Error!u8;  // returns the bump
```
Rationale for the injected `on_curve`: keeps Layer 0 free of ed25519 field math while the
on-curve module is deferred (§3). The on-chain path never calls this — it uses the
syscall (§4.7).

### 4.6 `src/platform/solana/syscalls.sig` — Layer 1 — syscall externs + safe wrappers
Follows the `platform/crypto.sig` "thin safe Sig surface over an extern layer" shape, but
the externs have **no library name** (loader-resolved). **[RECOMMENDATION / to confirm in
Phase 3]:** declare them as `extern fn name(...) callconv(.c) <ret>;` (no `"lib"`), which
under SIMD-0178 static syscalls the backend lowers to the fixed syscall `call` encoding.
If 0.6.2 requires a non-empty library string for `extern`, the fallback is a tiny `.sig`
with `comptime` `@extern`/inline-asm shims; this is a Phase-3 verification gate, not a
design unknown that blocks earlier phases. (Contrast [VERIFIED] gl.sig which uses
`extern "opengl32"` because an OS DLL *does* name-resolve those.)

Declared syscalls (names per Solana ABI):
```sig
// logging
extern fn sol_log_(msg: [*]const u8, len: u64) callconv(.c) void;
extern fn sol_log_64_(a: u64, b: u64, c: u64, d: u64, e: u64) callconv(.c) void;
extern fn sol_log_pubkey(pubkey: *const [32]u8) callconv(.c) void;
extern fn sol_log_compute_units_() callconv(.c) void;
// hashing
extern fn sol_sha256(vals: [*]const SolBytes, count: u64, out: *[32]u8) callconv(.c) u64;
// PDA
extern fn sol_create_program_address(seeds: [*]const SolBytes, seeds_len: u64, program_id: *const [32]u8, out: *[32]u8) callconv(.c) u64;
extern fn sol_try_find_program_address(seeds: [*]const SolBytes, seeds_len: u64, program_id: *const [32]u8, out_addr: *[32]u8, out_bump: *u8) callconv(.c) u64;
// CPI
extern fn sol_invoke_signed_c(instruction: *const SolInstructionC, account_infos: [*]const SolAccountInfoC, account_infos_len: u64, signers_seeds: [*]const SolSignerSeedsC, signers_len: u64) callconv(.c) u64;
// sysvars
extern fn sol_get_clock_sysvar(out: *ClockRaw) callconv(.c) u64;
extern fn sol_get_sysvar(sysvar_id: *const [32]u8, out: [*]u8, offset: u64, len: u64) callconv(.c) u64;
// memory (runtime-provided; avoids pulling libc)
extern fn sol_memcpy_(dst: [*]u8, src: [*]const u8, n: u64) callconv(.c) void;
extern fn sol_memset_(dst: [*]u8, c: u8, n: u64) callconv(.c) void;
extern fn sol_memmove_(dst: [*]u8, src: [*]const u8, n: u64) callconv(.c) void;
extern fn sol_memcmp_(a: [*]const u8, b: [*]const u8, n: u64, out: *i32) callconv(.c) void;
```
Safe wrappers return Sig `Error`/`bool`:
```sig
pub fn log(msg: []const u8) void;
pub fn logPubkey(key: *const [32]u8) void;
pub const SyscallError = error{ Failed };
pub fn sha256(chunks: []const []const u8, out: *[32]u8) SyscallError!void;
pub fn tryFindProgramAddress(seeds: []const []const u8, program_id: *const [32]u8, out_addr: *[32]u8) SyscallError!u8;
```
`SolBytes` is the `{ ptr: [*]const u8, len: u64 }` C view the hashing/PDA syscalls expect.

### 4.7 `src/platform/solana/clock.sig` — Layer 1 — Clock sysvar → Environment.slot
```sig
pub const ClockRaw = extern struct {
    slot: u64, epoch_start_timestamp: i64, epoch: u64,
    leader_schedule_epoch: u64, unix_timestamp: i64,
};  // 40 bytes
pub const Error = error{ Unavailable };
pub fn getClock() Error!ClockRaw;         // wraps sol_get_clock_sysvar
pub fn currentSlot() Error!u64;           // convenience → feeds Environment.slot
```

### 4.8 `src/platform/solana/cpi.sig` — Layer 1 — CPI marshalling
```sig
pub const SolAccountMeta = extern struct { pubkey: *const [32]u8, is_writable: bool, is_signer: bool };
pub const SolInstructionC = extern struct {
    program_id: *const [32]u8,
    accounts: [*]const SolAccountMeta, accounts_len: u64,
    data: [*]const u8, data_len: u64,
};
pub const SolAccountInfoC = extern struct { /* matches the loader's AccountInfo C ABI */ };
pub const SolSignerSeedsC = extern struct { addr: [*]const SolBytes, len: u64 };
pub const Error = error{ InvokeFailed };

pub const InstructionBuilder = struct { /* bounded, zero-alloc; caps on metas/data */
    pub fn init(program_id: *const [32]u8) InstructionBuilder;
    pub fn account(self: *InstructionBuilder, key: *const [32]u8, writable: bool, signer: bool) Error!void;
    pub fn data(self: *InstructionBuilder, bytes: []const u8) Error!void;
    pub fn invoke(self: *const InstructionBuilder, infos: []const SolAccountInfoC) Error!void;
    pub fn invokeSigned(self: *const InstructionBuilder, infos: []const SolAccountInfoC, seeds: []const []const []const u8) Error!void;
};
```
CPI is **Phase 5** and is specified here only to lock the type shapes; minegrind's current
`process()` performs "No CPI or fee debit" ([VERIFIED] program_logic.sig comment line 18),
so the first deployable minegrind program does **not** need CPI.

### 4.9 `src/platform/solana/entrypoint.sig` — Layer 1 — exported entrypoint + adapter
The single exported symbol the loader calls. Generic over a consumer processor so zpm owns
the ABI and the consumer owns the business logic.

**Public API surface (design-only — signatures and type shapes, no function bodies):**
```sig
// Imports this module depends on (Layer-0 parser/error + Layer-1 syscalls/clock):
//   solana_entrypoint_input (L0), solana_program_error (L0),
//   solana_syscalls (L1), solana_clock (L1).

/// A consumer supplies this: given parsed accounts + instruction data + slot,
/// do the work and return a u64 status (0 = success).
pub const Processor = *const fn (in: *const input.Input, slot: u64) u64;

/// Declare the exported entrypoint in the consumer root module. Call once at
/// comptime in the consumer root:  comptime { entrypoint.declare(myProcessor); }
/// Emits the loader-visible `entrypoint` symbol bound to `processor`.
///
/// `processor` MUST be a comptime-known, top-level function (not a runtime-stored
/// pointer). `declare` emits a DIRECT call to it inside the exported `entrypoint`, so the
/// backend can devirtualize/inline it. This matters on the sBPF target: with SIMD-0178
/// static syscalls and `-fno-compiler-rt`, an indirect call through a data-section
/// pointer is undesirable (extra relocation surface, no inlining). The `*const fn` type
/// is only the comptime-parameter shape; it is never materialized as a stored,
/// runtime-dispatched pointer. A runtime processor pointer is explicitly NOT supported.
pub fn declare(comptime processor: Processor) void;

// The symbol `declare` emits has this exact loader-facing signature:
//   export fn entrypoint(region: [*]u8) callconv(.c) u64
```

**Behavior spec (prose — the implementer builds this; it is NOT shown as code to keep the
design implementation-free):**
1. The exported `entrypoint(region: [*]u8) callconv(.c) u64` receives the loader's input
   region as a raw pointer. Its length is implied by the ABI, not passed.
2. It derives a correctly-bounded slice **incrementally**, not with a flat cap: read the
   leading `u64 num_accounts`, then walk each account advancing the cursor by that
   account's own serialized size (duplicate marker vs full record, `data_len`, the
   `MAX_PERMITTED_DATA_INCREASE` realloc region, the align-8 pad, and `rent_epoch`), then
   the instruction-data length+bytes and the trailing 32-byte `program_id`. Every field
   read is bounds-checked (`§4.3.1`), so a truncated or malformed region yields a typed
   `Error` rather than an out-of-bounds read. There is **no `MAX_REGION` flat cap** — the
   bound is the sum of parsed field sizes. (`MAX_ACCOUNTS` from `§4.3.2` still caps the
   static `AccountInfo` array; it does not bound the raw region length.)
3. On a parse `Error` (which is an `entrypoint_input.Error`, owned entirely by zpm, not a
   consumer error), the entrypoint maps it to an ABI code via `program_error.builtin` and
   returns that non-zero `u64` so the transaction fails cleanly — e.g. `Truncated`/
   `MalformedInput` → `.invalid_instruction_data`, `NonCanonical` → `.invalid_account_data`,
   `TooManyAccounts` → `.invalid_argument` (exact arms fixed in Phase 1 alongside the
   discriminants). This stays inside zpm because the parse-error set is zpm's own; the
   consumer-owned `mapError` (§4.4/§5.3) is only for the *processor's* `program_logic.Error`
   return. On success it holds the parsed `Input`.
4. It obtains the Clock slot via `clock.currentSlot()`; if the sysvar is unavailable it
   falls back to `0` (the consumer processor decides whether slot `0` is acceptable).
5. It calls `processor(&parsed, slot)` and returns that `u64` unchanged.

This is the only place the raw loader pointer is touched; everything downstream operates
on typed `AccountInfo` views, which is the "hard to misuse" property §4 aims for.

---

## 5. Consumer (minegrind) build + wiring

### 5.1 Why a dedicated build path
[VERIFIED] `build.sig`'s `addCompileStep` passes `.target = null` (host). A Solana `.so`
needs an explicit `-target bpfel-solana -mcpu sbpfv3`, which `addCompileStep` does not
express. Therefore, exactly like Android, the Solana build **bypasses build.sig** and
calls the compiler directly.

### 5.2 `tools/build-solana.ps1` (minegrind) — [RECOMMENDATION] new file (NOT written here)
Pattern copied from `tools/build-android.ps1`: compute `$mgRoot`/`$mgZpm`, then
```
sig build-lib <root>.sig -dynamic -target bpfel-solana -mcpu sbpfv3 -O ReleaseSmall -fno-compiler-rt -femit-bin=<out>/minegrind_program.so
  --dep ledger_world --dep action_wire --dep state_wire --dep minegrind_world
  --dep solana_entrypoint_input --dep solana_program_error --dep solana_syscalls --dep solana_clock
  -Mroot=<mgRoot>/src/solana_program.sig
  -Mledger_world=<zpm>/src/game/ledger_world.sig
  -Maction_wire=<zpm>/src/game/action_wire.sig
  -Mstate_wire=<zpm>/src/game/state_wire.sig
  -Mminegrind_world=<mgRoot>/src/world.sig
  -Msolana_entrypoint_input=<zpm>/src/solana/entrypoint_input.sig
  -Msolana_program_error=<zpm>/src/solana/program_error.sig
  -Msolana_syscalls=<zpm>/src/platform/solana/syscalls.sig
  -Msolana_clock=<zpm>/src/platform/solana/clock.sig
  -Msolana_entrypoint=<zpm>/src/platform/solana/entrypoint.sig
  -Msha256=<zpm>/src/core/sha256.sig
  -Msolana_le=<zpm>/src/solana/le.sig
  -Msolana_base58=<zpm>/src/solana/base58.sig
```
Use the exact `-O ReleaseSmall` (space) spelling — the [VERIFIED] correction from §1.1.
Note `-O ReleaseSafe` as used by Android is also acceptable; `ReleaseSmall` is preferred
on-chain to minimize program size and compute.

### 5.3 `minegrind/src/solana_program.sig` — [RECOMMENDATION] new consumer root (NOT written here)
Thin shell (Layer: project). It:
1. imports `program_processor` (`src/program_logic.sig`), `solana_entrypoint`,
   `solana_syscalls`, `solana_clock`, `state_wire`.
2. defines the `Processor` that **adapts the parsed Solana input to
   `program_logic.process`**, satisfying the contract from program_logic.sig (header lines
   18-19; `process` body line 20 onward — [VERIFIED] this pass).

   **Fixed account order ([RECOMMENDATION], locked for the minegrind program).** The
   client builds every instruction with this account vector, so the adapter is fully
   deterministic:
   - `accounts[0]` = **signer / fee payer** (the player's wallet; `is_signer == true`).
   - `accounts[1]` = **player PDA account** (program-owned, writable; maps to
     `player_account`).
   - `accounts[2]` = **resource PDA account** (program-owned, writable; OPTIONAL — present
     only for `mine`/`attack`; maps to `resource`). Absent → `resource = null`.

   Rationale: this matches exactly what `program_logic.process` expects — it validates
   `player_account` against `environment.player_pda` and (for `mine`/`attack`) `resource`
   against `environment.resource_pda`, and rejects when `resource` is missing for those
   actions or present for others ([VERIFIED] program_logic.sig: `validate` line 13; the
   `mine`/`attack` branch requires `resource orelse error.WrongAccount` and the
   `else if (resource != null) return error.UnexpectedResource`). The signer is NOT a
   program-owned account and is kept at index 0 so it never collides with a PDA.

   Concrete adapter rules:
   - **authenticate account flags (signer rule, now fully specified):**
     - `signer = accounts[0]`.
     - `Environment.signer = accounts[0].key.*` (`game.Key = [32]u8` ≡ `Pubkey` — [VERIFIED]
       ledger_world.sig line 3).
     - `Environment.signer_verified = accounts[0].is_signer`.
     - `Environment.program_id = input.program_id.*` (the trailing 32-byte `program_id`
       from the parsed region, §4.3.1 — this is the executing program's own id).
     - If `accounts[0].is_signer == false`, the adapter returns
       `missing_required_signature` immediately (it does not call `process`, which would
       otherwise reject with `error.Unauthorized` at program_logic.sig line 20). Returning
       the specific `missing_required_signature` code is clearer to the client than the
       generic unauthorized mapping.
   - **map accounts → `program_logic.Account`:** for `accounts[1]` (and `accounts[2]` when
     present) build `program_logic.Account{ address = key.*, owner = owner.*,
     writable = is_writable, data = data }`. `player_account` = account[1];
     `resource` = `if (num_accounts >= 3) account[2] else null`.
   - **derive PDAs**: `player_pda` / `resource_pda` via
     `sys.tryFindProgramAddress(seeds, program_id)` (syscall default, §3). Seeds come from
     the consumer's address scheme (§9.7, e.g. `["player", signer_key]` for the player PDA
     and `["node"|"monster", id_le]` for the resource PDA). `process` then re-validates
     that `accounts[1].address == player_pda` etc., so a client that passes the wrong
     account is rejected by `error.WrongAccount`, not silently trusted.
   - **obtain the Clock slot**: `slot = clock.currentSlot() catch 0`.
   - build `Environment{ program_id, signer, signer_verified, slot, player_pda,
     resource_pda }` and call `program_logic.process(env, player_account, resource,
     instruction_data)`.
   - map the returned `program_logic.Error` → `u64` via the **consumer-owned, exhaustive**
     `mapError(program_logic.Error) u64` defined in this same file (built from zpm's
     `program_error.builtin`/`custom`/`SUCCESS` encoders — see §4.4, Finding 1). There is
     no zpm `fromError`; the switch is exhaustive so a new error variant fails to compile
     until mapped. Success returns `program_error.SUCCESS`.
3. `comptime { solana_entrypoint.declare(processor); }`.

**No change to `program_logic.sig` is required** — it was authored for exactly this
adapter (header comment). That is the key payoff of this split.

### 5.4 Host simulator for the entrypoint — [RECOMMENDATION]
For host CI, a Layer-0 companion `src/solana/sim.sig` builds a byte-exact input region
from a struct of accounts/instruction/program_id, then calls the same Layer-0 `parse` +
the consumer `Processor` with a **stubbed** syscall module (pure-Sig fakes for
`currentSlot`, `tryFindProgramAddress` using the pure `pda.sig` + a host-only on-curve
stub, and `log`). This lets `sig build test` exercise the whole dispatch path without a
validator. (See §9.5.)

**Write-back coverage (resolves review Finding 5).** On-chain, `AccountInfo.lamports` and
`AccountInfo.data` are writable views directly into the loader region (§4.3.2), so the
runtime observes mutations in place. The simulator MUST build its input region in writable
memory and, after running `process`, assert that in-place writes through
`AccountInfo.lamports` and `AccountInfo.data` are visible in the backing buffer — not just
that the returned `state_wire` record decodes correctly. This mirrors on-chain mutation
semantics so a parser that accidentally handed out a copy (instead of an aliasing view)
would be caught on the host.

---

## 6. zpm `build.sig` wiring for the new modules

Add to `C:\Just-Things\Projects\sb0\zpm\build.sig`, mirroring the existing
`addModule`/`wire`/`addStep`/`addContract` pattern ([VERIFIED] the sha256/state_wire
examples):

```sig
// Layer 0 Solana core
const solana_le = try ctx.addModule("solana_le", "src/solana/le.sig");
const solana_base58 = try ctx.addModule("solana_base58", "src/solana/base58.sig");
const solana_input = try ctx.addModule("solana_entrypoint_input", "src/solana/entrypoint_input.sig");
try wire(ctx, solana_input, "solana_le", "src/solana/le.sig");
const solana_perr = try ctx.addModule("solana_program_error", "src/solana/program_error.sig");
const solana_pda = try ctx.addModule("solana_pda", "src/solana/pda.sig");
try wire(ctx, solana_pda, "sha256", "src/core/sha256.sig");
try wire(ctx, solana_pda, "solana_le", "src/solana/le.sig");

// Layer 1 Solana platform (host-compilable as declarations; real target built via build-solana.ps1)
const solana_sys = try ctx.addModule("solana_syscalls", "src/platform/solana/syscalls.sig");
const solana_clock = try ctx.addModule("solana_clock", "src/platform/solana/clock.sig");
try wire(ctx, solana_clock, "solana_syscalls", "src/platform/solana/syscalls.sig");
const solana_cpi = try ctx.addModule("solana_cpi", "src/platform/solana/cpi.sig");
try wire(ctx, solana_cpi, "solana_syscalls", "src/platform/solana/syscalls.sig");
const solana_ep = try ctx.addModule("solana_entrypoint", "src/platform/solana/entrypoint.sig");
try wire(ctx, solana_ep, "solana_entrypoint_input", "src/solana/entrypoint_input.sig");
try wire(ctx, solana_ep, "solana_program_error", "src/solana/program_error.sig");
try wire(ctx, solana_ep, "solana_syscalls", "src/platform/solana/syscalls.sig");
try wire(ctx, solana_ep, "solana_clock", "src/platform/solana/clock.sig");

// Tests (host, pure Layer-0 buffers — see §7)
const test_solana = try ctx.addStep("test-solana", "Solana on-chain core: LE, base58, deserializer, PDA, error encoding", &noopStep);
try ctx.addDependency(test_all, test_solana);
_ = try addContract(ctx, test_solana, "contract-solana-le",      "tests/test_solana_le.sig",      &.{ importEntry("solana_le", "src/solana/le.sig") });
_ = try addContract(ctx, test_solana, "contract-solana-base58",  "tests/test_solana_base58.sig",  &.{ importEntry("solana_base58", "src/solana/base58.sig") });
_ = try addContract(ctx, test_solana, "contract-solana-input",   "tests/test_solana_input.sig",   &.{ importEntry("solana_entrypoint_input", "src/solana/entrypoint_input.sig"), importEntry("solana_le", "src/solana/le.sig") });
_ = try addContract(ctx, test_solana, "contract-solana-pda",     "tests/test_solana_pda.sig",     &.{ importEntry("solana_pda", "src/solana/pda.sig"), importEntry("sha256", "src/core/sha256.sig"), importEntry("solana_le", "src/solana/le.sig") });
_ = try addContract(ctx, test_solana, "contract-solana-error",   "tests/test_solana_error.sig",   &.{ importEntry("solana_program_error", "src/solana/program_error.sig") });
```

**Layer-import discipline [RECOMMENDATION], enforced by review (there is no manifest
enforcement — [VERIFIED] CONTRIBUTING.md):**
- `src/solana/*` (Layer 0) may import only other Layer-0 modules (`sha256`, `solana_le`).
  It MUST NOT import `src/platform/solana/*`. CI check: a grep over `src/solana/*.sig`
  for `@import("solana_syscalls" | "solana_clock" | "solana_cpi" | "solana_entrypoint")`
  must return nothing.
- `src/platform/solana/*` (Layer 1) imports Layer-0 Solana modules freely; it must not be
  imported *by* any Layer-0 module.

---

## 7. Verification plan

Two independent tiers. Tier A needs no validator and runs in normal CI; Tier B is the
Agave reference harness.

### Tier A — pure host unit tests (gate for every phase, no Solana tools)
- Run with `sig build test --summary all` / `sig build test-now` (the existing
  [VERIFIED] contract-executable mechanism with assertion counters, so a suite with zero
  `test` decls cannot silently pass).
- **le**: round-trip `putLe`/`getLe` for u8/u16/u32/u64; byte-for-byte match vs the
  existing `state_wire`/`action_wire` outputs.
- **base58**: `encodeKey`/`decodeKey` cross-checked against `c3/wallet_auth.sig` outputs
  for all-zero, leading-zero, and random 32-byte keys; `NonCanonical` and `InvalidChar`
  negative cases; general `encode`/`decode` over arbitrary lengths.
- **entrypoint_input**: hand-build byte buffers for: 0 accounts; 1 account; a duplicate
  account (`dup_marker < i`); max accounts; truncated buffer (`Truncated`); bad flag byte
  (`NonCanonical`); verify `AccountInfo` views point at the right offsets and `data.len`
  equals the serialized `data_len`; verify 8-byte alignment of the `rent_epoch` slot.
- **pda**: `deriveWithBump` against SHA-256 of a known preimage; `findProgramAddress` with
  a stub `on_curve` that rejects a chosen bump, asserting the loop steps down correctly.
- **program_error**: `custom(code)` packing; `SUCCESS == 0`; `builtin(e)` encoding for
  each variant; plus the consumer-side exhaustive `mapError(program_logic.Error)` covering
  every variant (compile-time exhaustiveness is itself the primary check).
- **sim** (§5.4): drive a fake instruction through the consumer `Processor` with stubbed
  syscalls and assert `state_wire` records mutate exactly as the host `program_logic`
  path does; additionally assert that in-place writes through `AccountInfo.lamports` and
  `AccountInfo.data` are visible in the backing byte buffer after `process` (write-back),
  matching on-chain mutation semantics (Finding 5).

### Tier B — Agave reference harness (loadability + runtime correctness)
Prerequisite: install Agave platform-tools to get the forked `llvm-objdump`
(**[UNVERIFIED] not currently on disk** — §1.1; install via `agave-install` /
`cargo-build-sbf --help` which fetches `platform-tools`). `solana-test-validator` is
[VERIFIED] present.
1. **Build** the `.so` with the [VERIFIED] recipe (via `tools/build-solana.ps1`):
   `sig build-lib root.sig -dynamic -target bpfel-solana -mcpu sbpfv3 -O ReleaseSmall
   -fno-compiler-rt -femit-bin=out.so`. Assert ELF header: `e_machine=247`, `e_type=3`,
   `e_flags=3` (a tiny PS/Sig check reading bytes 16-19 and 48-51 — exactly the check run
   this pass).
2. **Disassemble** with the forked `llvm-objdump -d out.so` (works despite sig's
   `e_shnum=0`, which [VERIFIED] makes `sig objdump -d` emit no instructions). Eyeball the
   entrypoint prologue and the syscall `call` encodings.
3. **Minimal log program first** (`sol_log_` only): deploy to `solana-test-validator`,
   send a transaction, assert the log line appears and the tx succeeds (return 0). This
   validates loadability + the entrypoint ABI end-to-end with the least surface.
4. **Account-mutating program next**: deploy the minegrind program, create a
   program-owned player PDA account, send a `mine`/`attack` instruction, and assert the
   on-chain account bytes equal the host simulator's output for the same input (byte-exact
   `state_wire` record). This is the real correctness gate.
5. Record pass/fail per phase as the phase's gate.

---

## 8. Ordered implementation plan (smallest-verifiable-first)

Each phase ends at a **gate** that must pass before the next starts.

- **Phase 0 — scaffolding.** Create `src/solana/` and `src/platform/solana/` dirs; add the
  module/test wiring from §6 with empty stubs. *Gate:* `sig build` configures; `test-solana`
  step exists and runs (even if empty, the contract mechanism must register).
- **Phase 1 — Layer-0 core: `le`, `base58`, `program_error`.** Implement + Tier-A tests;
  fix the authoritative `ProgramError` constants here (§4.4 [UNVERIFIED]). *Gate:* Tier-A
  le/base58/error contracts green; base58 cross-checks `c3/wallet_auth.sig`.
- **Phase 2 — Layer-0 deserializer `entrypoint_input` + `pda` (pure, injected on-curve).**
  Implement + Tier-A buffer tests. *Gate:* all deserializer edge cases (dup, truncated,
  non-canonical, alignment) and PDA bump-loop tests green.
- **Phase 3 — Layer-1 syscalls + minimal log entrypoint, verified on validator.**
  Implement `syscalls.sig` (resolve the no-library `extern` question — §4.6), `clock.sig`,
  `entrypoint.sig`; build a trivial `log` program `.so`. *Gate:* Tier-B steps 1-3 pass
  (ELF header correct; llvm-objdump shows instructions; log tx succeeds on
  solana-test-validator).
- **Phase 4 — Full minegrind on-chain program (no CPI).** Add
  `minegrind/src/solana_program.sig`, `tools/build-solana.ps1`, the PDA-syscall adapter,
  and the host simulator. *Gate:* Tier-B step 4 (on-chain account bytes == host simulator
  bytes for `mine`/`attack`); Tier-A sim contract green.
- **Phase 5 — PDA pure on-curve (`ed25519_point.sig`) + CPI (`cpi.sig`).** Build the
  deferred ed25519 point module (replaces the injected `on_curve` stub for off-chain
  derivation) and CPI marshalling. *Gate:* pure `findProgramAddress` matches the syscall's
  result for a corpus of seed sets; a CPI invoke succeeds on the validator.

Phases 0-4 deliver a real, deployable, account-mutating minegrind program; Phase 5 closes
the remaining crypto/CPI gaps.

---

## 9. Open design decisions requiring a human (each with a recommendation)

1. **ABI version / sBPF version.** *[RECOMMENDATION] ABI v1 (8-byte aligned) + sBPFv3*,
   already [VERIFIED] emittable by the toolchain. Decide only if a specific validator
   mandates a different version.
2. **PDA on-curve: build vs defer.** *[RECOMMENDATION] DEFER* `ed25519_point.sig` to
   Phase 5; use the `sol_try_find_program_address` syscall on-chain and an injected
   predicate off-chain until then (§3). Explicit gap: pure off-chain *rejection of
   on-curve* is incomplete until Phase 5.
3. **Layer placement / naming.** *[RECOMMENDATION] `src/solana/` (Layer 0) +
   `src/platform/solana/` (Layer 1)*; do **not** fold into `c3/` (std-coupled client
   code). Module names prefixed `solana_*` to avoid collisions in the flat module
   namespace (e.g. `solana_le` not `le`). Confirm the prefix convention.
4. **`extern` without a library name for syscalls.** *[RECOMMENDATION] plain `extern fn …
   callconv(.c)`* (no `"lib"`), relying on SIMD-0178 static-syscall lowering; fall back to
   `@extern`/asm shims if 0.6.2 rejects it. Resolve at Phase 3 (it is a verification gate,
   not a blocker for Phases 0-2).
5. **Expose a pure off-chain simulator of the entrypoint for host testing?**
   *[RECOMMENDATION] YES* (`src/solana/sim.sig`, §5.4) — it is the only way to get
   validator-free regression coverage of the full dispatch path and keeps CI fast.
6. **Static caps `MAX_ACCOUNTS` / `MAX_SEEDS` / `MAX_REGION` / `MAX_PERMITTED_DATA_INCREASE`.**
   *[RECOMMENDATION] `MAX_ACCOUNTS = 64`, `MAX_SEEDS = 16`, `MAX_SEED_LEN = 32`,
   `MAX_PERMITTED_DATA_INCREASE = 10240`* (zero-alloc requires compile-time caps —
   [VERIFIED] zero-alloc rule). **[UNVERIFIED]** confirm `MAX_PERMITTED_DATA_INCREASE`
   (reference-only source: Agave `solana_program::entrypoint::MAX_PERMITTED_DATA_INCREASE`)
   and the exact builtin `ProgramError` discriminants + the `custom()` base (reference-only
   source: Agave `solana_program::program_error`) against the authoritative Solana ABI in
   Phase 1 (short-quote web re-verify permitted). No numeric literals are committed in this
   design — see §4.4.
7. **Signer/PDA seed scheme for minegrind.** The adapter needs the concrete seeds for
   `player_pda`/`resource_pda` (e.g. `["player", owner_pubkey]`). *[RECOMMENDATION]* define
   these in `minegrind/src/solana_program.sig` (project layer, not zpm) since they are
   app-specific; zpm only provides the derivation primitive.

---

## 10. Summary of what was verified vs. recommended

- **VERIFIED firsthand this pass:** sig 0.6.2; the `-O ReleaseSmall` (space) build recipe
  producing e_machine=247 / e_type=3 / e_flags=3; `e_shnum=0`/`sig objdump` instruction
  gap; `solana-test-validator` present; base58 exists in `c3/wallet_auth.sig`
  (`BASE58_ALPHABET` line 17, `encodePublicKey` line 148, `decodePublicKey` line 177,
  `indexOfScalar` line 181, round-trip `std.mem.eql` line 203) but is std-coupled and
  pubkey-specific; `sha256.sig` is pure Layer-0;
  `state_wire`/`action_wire` LE style and duplicated `put`/`get`; `gl.sig` extern pattern;
  `program_logic.sig` `Account`/`Environment`/`process` contract and `game.Key=[32]u8`;
  minegrind host + Android build wiring; zpm `build.sig` module/wire/contract API; c3
  module list; CONTRIBUTING conventions.
- **Could NOT verify (flagged):** Agave `llvm-objdump` on disk (platform-tools not
  installed); exact `ProgramError` numeric constants and `MAX_PERMITTED_DATA_INCREASE`;
  whether 0.6.2 accepts a library-less `extern` for syscalls (Phase-3 gate).
- **The brief's one factual error, corrected:** base58 *does* exist in zpm/src (the brief's
  "grep found nothing" was a tool-indexing artifact, reproduced here); the design still
  builds a new pure Layer-0 base58, but as an extraction of proven code, not greenfield.

---

## 11. Responses to the design review

### Revision 3 (latest) — responses to the second review

Review: `C:\Just-Things\Projects\sb0\minegrind\.agents\tasks\solana-onchain-layer-design-review.md`
(verdict CHANGES_REQUESTED — 1 MEDIUM, 4 NIT; no HIGH). All five findings are **addressed**.

- **Finding 1 (MEDIUM) — `program_error.fromError` ownership self-contradictory (§4.4 vs
  §5.3).** ADDRESSED. The generic zpm `fromError(anyerror) u64` is **removed**. §4.4 now
  specifies that zpm Layer-0 `program_error.sig` exposes only ABI encoders — `SUCCESS`,
  `custom(code: u32)`, `builtin(e: ProgramError)` — and the **consumer owns an exhaustive
  `mapError(program_logic.Error) u64`** (shown in §4.4, placed in the project-layer
  `minegrind/src/solana_program.sig`). §5.3 now references that consumer-owned `mapError`
  instead of a zpm `fromError`. The entrypoint's own parse-error mapping (§4.9) uses
  `program_error.builtin` over zpm's own `entrypoint_input.Error`, keeping the Layer-0 /
  consumer split clean. §7 updated to test both `builtin` and the exhaustive `mapError`.

- **Finding 2 (NIT) — §4.3.1 "see note" with no note.** ADDRESSED. The account field at
  `+4` is now spelled out inline as `u32 original_data_len` — not consumed (no realloc
  support in Phase 4), skipped as reserved, width/semantics to confirm against the
  reference-only Agave serializer in Phase 1. No dangling "see note".

- **Finding 3 (NIT) — off-by-one line citations for `wallet_auth.sig`.** ADDRESSED and
  re-verified this pass via `Select-String`: `encodePublicKey` line 148, `decodePublicKey`
  line 177, `indexOfScalar` line 181, round-trip `std.mem.eql` line 203 (and
  `BASE58_ALPHABET` line 17). Updated in §0 and §10, citing by symbol name first.

- **Finding 4 (NIT) — §4.9 `Processor`/`declare` comptime ambiguity.** ADDRESSED. §4.9 now
  states explicitly that `processor` must be a comptime-known top-level function and
  `declare` emits a **direct** (devirtualized/inlinable) call, never an indirect call
  through a stored runtime pointer — with the SIMD-0178 / `-fno-compiler-rt` rationale for
  the BPF backend. A runtime pointer is explicitly unsupported.

- **Finding 5 (NIT) — host simulator write-back coverage.** ADDRESSED. §5.4 and §7 Tier-A
  now require the simulator to assert that in-place writes through `AccountInfo.lamports`
  and `AccountInfo.data` are visible in the backing buffer after `process`, matching
  on-chain mutation semantics (not only the `state_wire` record decode).

### Revision 2 — responses to the first review

Review: `C:\Just-Things\Projects\sb0\minegrind\.agents\tasks\solana-onchain-layer-design-review.md`
(verdict CHANGES_REQUESTED — 4 MEDIUM, 2 NIT; no HIGH). All six findings are **addressed**.

- **Finding 1 (MEDIUM) — `MAX_PERMITTED_DATA_INCREASE` double-tagged VERIFIED+UNVERIFIED.**
  ADDRESSED. §4.3.1 now marks the constant **[UNVERIFIED] only** and names the
  reference-only source to confirm in Phase 1 (Agave
  `solana_program::entrypoint::MAX_PERMITTED_DATA_INCREASE`). The "[VERIFIED against the
  brief]" clause is removed, so §4.3.1, §9.6, and §10 now agree.

- **Finding 2 (MEDIUM) — signer-account selection rule unspecified (`signer_index`
  undefined).** ADDRESSED. §5.3 now specifies the concrete rule: `signer = accounts[0]`;
  `Environment.signer = accounts[0].key.*`; `signer_verified = accounts[0].is_signer`;
  `Environment.program_id = input.program_id.*`; and on `!accounts[0].is_signer` the
  adapter returns `missing_required_signature` without calling `process`. Verified against
  program_logic.sig line 20 (`!signer_verified → error.Unauthorized`) this pass.

- **Finding 3 (MEDIUM) — §4.9 shipped an executable entrypoint body + MAX_REGION
  contradiction.** ADDRESSED. §4.9 now presents **signatures and type shapes only**
  (`Processor`, `declare`, and the exported symbol's signature) plus a prose behavior spec.
  The flat `MAX_REGION` cap is removed; the parse-bound strategy is described as
  incremental (sum of parsed field sizes), eliminating the contradiction.

- **Finding 4 (MEDIUM) — `ProgramError` placeholder numeric constants are knowingly
  wrong.** ADDRESSED. §4.4 removes all invented `0x1000000NN` literals; variants are now
  valueless with an explicit implementer rule ("do not hard-code discriminants or the
  `custom()` base until confirmed in Phase 1") and the reference-only Agave sources named.
  Only the u64-return *shape* remains [VERIFIED].

- **Finding 5 (NIT) — line-number drift in §1.2.** ADDRESSED. `state_wire.sig` now cites
  `put`=10, `get`=13, `header`=18, `Error`=3; `action_wire.sig` cites `put`=5, `get`=8,
  `Error`=4; both now also cite by symbol name to stay drift-proof (re-verified this pass).

- **Finding 6 (NIT) — account→role mapping implicit.** ADDRESSED. §5.3 now enumerates the
  locked account order: `[0]`=signer/payer, `[1]`=player PDA (→ `player_account`),
  `[2]`=resource PDA (optional, → `resource`), with the mapping to `program_logic.Account`
  and the `num_accounts >= 3 ? account[2] : null` resource rule stated explicitly. This
  matches the `mine`/`attack` resource-required vs `else`-`UnexpectedResource` logic
  verified in program_logic.sig this pass.
