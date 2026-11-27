# Transcript annotation components

`src/transcript/root.sig` is a storage-neutral, allocator-free evidence model
for timestamped speech and discourse modes. It does not recognize audio or
identify speakers. Applications own artifact IO, audio/transcript provenance,
source retrieval, model choice, cancellation and publication decisions.

Modes are reading, commentary, digression, technical and unknown. A `Segment`
borrows immutable UTF-8 text and original start/end times; its speaker is
nullable. Mode labels never imply a speaker or authorize deletion of speech.

`src/transcript/classifier.sig` is the finite-answer classification API. It scores
five single-token answers, rather than asking the model to invent boundaries or
confidence percentages. Structural punctuation and source endpoints select
spans; they never determine the mode by keyword.

```sig
const t = @import("transcript/root.sig");
const c = @import("transcript/classifier.sig");
const prompt = try c.buildPromptWithSource(topic, before, focus, after,
    candidate_source, prompt_storage);
// runtime, model KV, scores and all other buffers belong to the caller.
_ = try runtime.scoreNext(c.system_prompt, prompt, &c.labels, scores, options);
for (scores, logits) |score, *destination| destination.* = score.logit;
const primary = try c.decide(logits, focus_word_range, matches, topic.len != 0, policy);
var admitted = primary;
if (c.verificationKind(primary, focus_word_range, matches)) |kind| {
    admitted = c.awaitingVerification(primary);
    _ = try runtime.scoreNext(c.verificationPrompt(kind), prompt,
        &c.verification_labels, specialist_scores, options);
    for (specialist_scores, specialist_logits) |score, *destination| destination.* = score.logit;
    const checked = try c.verify(primary, kind, specialist_logits, policy);
    admitted = checked.decision;
    // Preserve checked.verification and both sets of raw logits separately.
}
```

In an application that catches scoring errors, retain `awaitingVerification`'s
unknown admission when a required check fails or is cancelled. A specialist may
retain the primary mode or abstain, never substitute another mode. It checks
source recitation versus the speaker's own interpretation for supported reading
or commentary, and checks whether a proposed digression is unrelated both to the
lesson and to running the class/recording. See the complete contract in
[transcript-verification.md](transcript-verification.md).

Word and source offsets are half-open UTF-8 byte ranges. Proposal bounds are
half-open word indices. Original punctuation and all unsupported-script bytes
remain in raw text. Hebrew marks are ignored only while matching, and acronym
quotes normalize for comparison. Final forms and spelling are not conflated.

The sorted five-word source seed index takes O(S log S) to construct. Each seed
lookup is binary search, followed by at most 128 candidate extensions. Full
normalized characters are compared after hash matches. Repeated or truncated
candidate searches produce ambiguous evidence. `alignment.ApproxSource` adds a
separate sorted three-word anchor index and bounded dynamic-programming search
for ASR spelling variants. It retains aligned/exact word counts, character and
word edit counts, source offsets and ambiguity instead of changing text. At least
five aligned words, three exact anchor words and bounded edit cost are required.
Candidate/storage exhaustion is explicit; it is not partial source confirmation.

Build the exact and approximate indexes once per source. `alignContext` borrows
caller-owned `ContextStorage`, result matches and `Scratch`. It retains at most
16 words before, 32 focus words and 16 after. Every evidence word maps to an
unchanged original byte range, and the focus range is in combined evidence-word
coordinates. `Match.supports` can therefore support a short focus within a longer
unambiguous quotation. A standalone common phrase shorter than five words is
insufficient. Source overlap is evidence, not proof of reading aloud.

The older low-level generated-TSV protocol remains available through
`buildPrompt`, `parseProposals` and `adjudicate`; it is not the finite-answer API.
That protocol requires a complete contiguous partition of words. Invalid
format, gaps, overlap, unknown enums, noninteger/out-of-range scores and capacity
failures are errors, not partial success. `adjudicate` withholds reading without
an unambiguous >=5-word match, digression without topic context, and any mode
with model-reported score below 80. Scores are not calibrated probabilities.
Applications must evaluate quality and expose uncertainty. The finite-answer
API instead uses raw-logit margins and conditional label shares, with explicit
policy thresholds; neither these shares nor generated scores are calibrated.

`src/llm/qwen_text.sig` adapts the existing `gguf`, `tokenizer_index` and
`tokenizer` modules for the Qwen2 Hebrew/ASCII pretokenization profile. It checks
GGUF architecture and tokenizer profile, uses the model-owned byte alphabet and
merge table, separates chat controls from untrusted text, rejects unsupported
scripts and decodes tokens back to raw bytes. Storage and model bytes are
borrowed; codec objects stay pinned while their `gguf.Source` is borrowed.

`src/llm/transcript_model.sig` provides a comptime-bounded `Runtime(limits)` over
the existing reference-checked `qwen3_executor`. Initialize an existing pinned
runtime with mapped model bytes and caller-owned F16 KV storage. Each generation
uses independent positions/KV contents, computes logits only for the last
prefill token, and then greedily generates up to the requested cap (1..256).
The context reserve is checked against that cap. Errors distinguish
capacity/storage/cancellation from EOS. Partial generated token IDs and decoded
bytes remain available for audit; callers must not accept partial generations
as successful protocol responses. It does not use the older `llm/infer.sig`
tokenizer/GPU/cache path. `scoreNext` uses the same executor with finite candidate
token IDs and exact common-prefix reuse. Its cache includes accelerator callback
and effective context identity; cancellation is checked even for cached logits.
Call `invalidateScoreCache()` after changing numerical configuration inside the
same accelerator context. Applications may supply a storage-neutral matrix
callback backed by `llm/text_gpu.sig`; the executor never silently substitutes a
CPU result when that callback fails.

For alternating prompt families, `Runtime.attachPrefixCache(entries)` accepts
exclusive caller-owned `PrefixEntry` token and compact half-KV buffers. Size
each entry with `prefixKvElements(token_capacity)` after model initialization.
Snapshots compare actual token IDs and restore only a longer common prefix;
they do not cache answer logits. A restored complete prompt still recomputes
its final token. Model initialization detaches snapshots; backend changes and
`invalidateScoreCache()` invalidate all attached entries. `detachPrefixCache()`
releases the borrow without freeing caller storage. In-place model mutation is
unsupported. The synchronous cache reports `restored_prefix_tokens` separately
from `scored_prefill_tokens`. Three 384-token snapshots use 162 MiB for the
36-layer 4B model, rather than three complete 2048-token KV buffers. Standalone
storage/layout/eviction contracts live in `llm/prefix_cache.sig`.

Validation is exercised by Gotliv's `scripts/Test-TranscriptModules.ps1`, native
`text-codec-test.exe`, independent development regex/BPE oracle, and timestamped
CLI integration checks. On 2026-10-15, both local Qwen3 0.6B and 4B artifacts
matched all 17 tokenizer probe cases (including Hebrew points and chat controls).
The 0.6B model's generated discourse protocol failed; tokenizer parity did not
establish semantic capability. The later 4B native finite-answer evaluation on
the original 22-case file scored 17/22 overall, accepting 17 with 15 correct.
A separate frozen v2 reference evaluation scored 15/22 for the unchanged primary
prompt, accepting 16 with 13 correct. Adding conservative checks to those same
v2 scores yielded 14/22 overall, accepting 13 with 12 correct. Two incorrect and
one correct admission were withheld; one logistics passage remained incorrectly
accepted as commentary. The datasets and methods are distinct and the counts
must not be pooled. These small text-only judgments do not establish human ASR
accuracy or safe automatic speech removal.
