# Solana support

Pure Sig support modules with no allocator or platform imports:

| Named module | File | Surface |
| --- | --- | --- |
| `solana_le` | `le.sig` | Explicit LE reads/writes; caller validates bounds |
| `solana_base58` | `base58.sig` | Arbitrary-length caller-buffer conversion and 32-byte key helpers |
| `solana_program_error` | `program_error.sig` | Builtin return values and custom-zero encoding |
| `solana_entrypoint_input` | `entrypoint_input.sig` | Aligned loader ABI parser, duplicate aliases, borrowed account views |
| `solana_pda` | `pda.sig` | Validated PDA preimages and bump search with injected curve predicate |

`sig build test-solana` runs core, input/PDA and runtime executable contracts. The base58 codec is
cross-checked against the existing c3 wallet codec without importing c3 into these
runtime modules. PDA preimages are cross-checked against an independent host hash.

`parseInto(buffer, account_storage)` avoids embedding a 64-account array in a
return value. Supply only the number of descriptors your processor needs; up to
64 are supported. Account data and metadata views borrow `buffer`, and the
returned account slice borrows `account_storage`. On failure, descriptors may be
partially written; the input bytes remain unchanged. `consumed` lets callers
enforce an exact envelope. Realloc padding is skipped, never exposed for mutation.

Parsing is not authentication. Only the VM adapter may supply authoritative
signer/owner flags and Clock. Processors must check writable status, address
identity and ownership before modifying data. Duplicate descriptors intentionally
share backing data and lamports. These modules implement the aligned loader ABI,
not a generic parser for arbitrary future ABI versions.

`findProgramAddress` is only production-correct with a real Ed25519 on-curve
predicate. The bump consumes one of the 16 allowed seeds, so callers may supply
at most 15 seeds of at most 32 bytes. Native runtime PDA and Clock bindings live
in `src/platform/solana/`, alongside CPI and Rent helpers.

Off-chain `client.sig` supplies caller-buffer legacy transaction construction,
Ed25519 signing and PDA search with real curve decompression through Sig's standard
crypto library. It is separate from the VM modules. `rpc_json.sig` validates bounded
JSON envelopes; `rpc.sig` provides transport-injected submission, finality,
blockheight and account snapshot calls. The client contracts include a complete
independently signed packet, known PDA vectors and ambiguous/terminal RPC cases.
Android's `loopback_http.sig` and `private_store.sig` provide fixed loopback HTTP
and app-private atomic storage. Public HTTPS and external wallet adapters remain
consumer integration work.

Reference-only sources: [loader deserialization](https://github.com/anza-xyz/solana-sdk/blob/master/program-entrypoint/src/lib.rs),
[account-info constants](https://github.com/anza-xyz/solana-sdk/blob/master/account-info/src/lib.rs),
and [return-code encoding](https://github.com/anza-xyz/solana-sdk/blob/master/program-error/src/lib.rs).
Pin a compatible reference/validator release before treating this layer as a
production contract SDK.
