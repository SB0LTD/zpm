# Shared native Qwen runtime

`qwen3_executor` owns the allocator-free decoder used by Nexus. Storage, clocks,
driver callbacks and readiness policy belong to its caller. The canonical
`build.sig` wires `gguf`, `qwen3_decoder_plan`, `tokenizer_index`, `tokenizer`,
`quantized_linear` and `transformer_ops` once under those names.

`beginToken` and `stepToken` use caller-owned `TokenSession`, `WorkingSet` and
F16 KV storage. Matrix work is limited by the supplied positive row budget;
attention mixing advances one query head per step. Greedy token selection is
incremental within the logits slices. Other vector operations remain separate
phases. A row budget is a work bound, not a wall-clock latency guarantee.

The progress callback receives `slice_begin` before each phase and can cancel
before numerical storage is touched. Errors invalidate the session. The caller
must restart a failed token or request; it must not resume partially written
scratch. Index, plan and source must remain immutable, and each live session
needs exclusive work/KV storage. Switching index, plan, work, KV or context in
the middle of a token is rejected. Hidden-state callbacks are optional and do
not establish admission of any downstream learned projection.

`forward`, `forwardWithKernels` and `forwardSliced` use the same state machine.
The scalar reference expands quantized rows before scalar dot products.

## Executed validation

Use the complete SB0LTD Sig 0.5.6 release, without library overlays:

```powershell
$env:SIG = 'C:/Users/Shado/AppData/Local/Programs/Sig/0.5.6/bin/sig.exe'
$env:SIG_LIB_DIR = 'C:/Users/Shado/AppData/Local/Programs/Sig/0.5.6/lib'
& $env:SIG build test-qwen -Doptimize=ReleaseSafe
& $env:SIG build probe-qwen -Doptimize=ReleaseFast
& ./sig-out/bin/probe-qwen.exe /path/to/Qwen3-0.6B-Q4_K_M.gguf --parity
& ./sig-out/bin/probe-qwen.exe /path/to/Qwen3-0.6B-Q4_K_M.gguf 'Say hello in one short sentence.' 32 32
```

The contracts are executable mains with assertion counters, not empty test
discovery results. They cover tied/untied weights, asymmetric attention widths,
sliced logits/KV parity, storage reads and mappings, cancellation, restart and
capacity failures. The high-level session contract uses a tiny deterministic
model and real tokenizer to check prompt order, generated history, stale
iterators and error propagation.

On 2026-09-11 the real-model probe used a 396,705,472-byte GGUF with SHA-256
`ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a`.
Token 0 selected token 397. Fused/scalar maximum absolute logit error was
0.000032425; the fused logit SHA-256 was
`6ad6ffaf6b00d7506aade518b06bc40527d55f7f2b7ede2418dff6ec2134c3c8`,
identical to the earlier Nexus reference.

The prompt above generated `Hello! How can I assist you today?` (nine tokens,
then EOS). A warmed Windows host run took 2.2 seconds including prefill.
The probe prints phase timing and counts of slices above two milliseconds;
host timings do not admit the bare-metal scheduler or prove microphone input.
Its static context is 256; the reusable default profile and high-level Session
remain explicitly bounded to 64 positions.

## High-level API migration

`SessionConfig.max_context` now defaults to the executor's supported 64. Larger
contexts are rejected before allocation. The vocabulary has 151,936 token slots
and 262,144 hash slots; these are distinct capacities. Prompt and generated
history share the bounded context, including repetition-penalty history.

`TokenIterator.next()` returns `Session.Error!?Output`: call it with `try`.
Cancellation, model read failures and decode failures no longer masquerade as
EOS. `generateComplete` rejects insufficient output capacity rather than
returning truncated token bytes. Resetting/generating invalidates old iterators.
The tokenizer's canonical import name is `tokenizer_index`; do not register the
same file again as `sb0_gguf_tokenizer_index`.
