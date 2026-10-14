# Solana runtime bindings

Layer 1 uses loader-resolved static syscalls; it imports no SDK or host library.
`syscalls.sig` exposes logging, SHA-256, PDA bump search and return data through
an injectable comptime backend. `SolBytes` is the 16-byte pointer/length ABI.
Hash and seed descriptors use caller-owned scratch; output bytes commit only
after a successful syscall. Bump search accepts at most 15 user seeds, each at
most 32 bytes. Return data is limited to 1,024 bytes.

`clock.sig` reads the 40-byte Clock through `sol_get_sysvar`. Lookup failure is
an error, never slot zero. `entrypoint.sig` sizes descriptor storage at comptime
and passes authenticated loader metadata and Clock to a processor. Its raw
pointer boundary is exclusively for the trusted loader: pointers carry no
allocation length. Host input must use Layer 0's bounded `parseInto` API.

`sig build test-solana` includes 26 runtime assertions using an injected backend.
The sibling MineGrind repository contains `tools/build-solana-runtime.ps1` and
`tools/test-solana-runtime.mjs` for real local-validator execution. On Agave
4.3.0, the fixture logged, hashed, derived a PDA, read Clock, returned data,
rejected an oversized payload and finalized successfully. The fixture does not
mutate game accounts. MineGrind separately uses `cpi.sig`, `rent.sig` and
`system_account.sig` to initialize canonical accounts through the System Program.

The C CPI structs are 16-byte Meta, 40-byte Instruction, 56-byte AccountInfo and
16-byte signer-seed group. Views retain the loader's key, owner, lamports and
data pointers. The parser exposes the canonical data-length word so each CPI
can refresh a grown view, without guessing a pointer before a host buffer.
`system_account` requires a genuine aligned-loader descriptor with its growth
padding, verifies an empty System-owned target and propagates native errors.
The outer program must reject on failure to roll back earlier CPI effects.
Rent calculations use integer multiplication after explicit overflow checks;
only native 1.0/legacy 2.0 threshold byte patterns are supported.

`test-solana` includes 27 CPI/Rent assertions for layout/marshalling, capacity
guards, errors, prefunded allocation, preserved surplus and rent arithmetic.
The optional initializer operations are separately validator-tested by MineGrind.

Runtime signatures were checked against the pinned
[Agave v4.3.0 syscall implementation](https://github.com/anza-xyz/agave/blob/v4.3.0/syscalls/src/lib.rs).
The validated binary reported feature set 3383571666. This verification applies
to that runtime; future ABI/version changes need another validator check.
The CPI layouts were checked against the pinned
[Agave v4.3.0 C CPI translator](https://github.com/anza-xyz/agave/blob/v4.3.0/program-runtime/src/cpi.rs).
Rent threshold handling follows the integer paths documented in the
[SDK Rent implementation](https://github.com/anza-xyz/solana-sdk/blob/master/rent/src/lib.rs);
actual balances were compared with Agave 4.3.0 RPC in the MineGrind harness.

Sig 0.6.3 exhibited a separate direct string-pointer defect in a marshalled seed
array. MineGrind retains the failing regression fixture and uses caller-owned
seed bytes in the passing runtime probe. This is an open toolchain limitation,
not evidence that arbitrary on-chain programs are already reliable.
