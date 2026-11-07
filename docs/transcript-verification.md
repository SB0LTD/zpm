# Finite discourse scores and semantic cross-checks

`transcript/classifier.sig` separates immutable text, structural span selection,
model proposals, source evidence and admitted labels. `decide` accepts raw
five-label logits and explicit margin/share thresholds. The softmax share is
conditional on these labels, not a calibrated probability of correctness.

An accepted label can still be wrong with a large margin. Two additional model
questions address observed conflicts without keyword-based mode rules:

* For an accepted reading or commentary label whose whole focus has independently
  aligned source support, ask whether it is source recitation, the speaker's own
  interpretation, or unclear/mixed.
* For an accepted digression, ask whether it is unrelated both to the lesson and
  to operating or organizing the class/recording, related to either, or unclear.

These checks only retain a primary label or change its admission to `unknown`.
They never promote an abstained label or substitute a different mode. Raw primary
scores and the primary proposal remain available even on disagreement.
The specialist uses the same model with a different question. Its errors can be
correlated with the primary answer; these are not independent probabilities and
their conditional shares must not be multiplied into a combined confidence.

```sig
const primary = try classifier.decide(primary_logits, span, matches, has_topic, policy);
var admitted = primary;
if (classifier.verificationKind(primary, span, matches)) |kind| {
    admitted = classifier.awaitingVerification(primary);
    // This is a separate native scoreNext request. Store raw token IDs/logits.
    // If scoring is cancelled or fails, leave `admitted` unknown and retain the
    // error. Do not silently fall back to the primary label.
    const checked = try classifier.verify(primary, kind, specialist_logits, policy);
    admitted = checked.decision;
    // Store checked.verification separately from the primary decision/scores.
}
```

Use `verificationPrompt(kind)` with the same bounded user evidence and the three
single-token `verification_labels`. `Verified.verification` retains the question
kind, selected label index, raw-score margin, conditional share and agreement,
disagreement or abstention reason. The caller owns all buffers and model KV.

Source support is not itself a reading label. Matching normalizes Hebrew points
and acronym quotation marks for comparison without rewriting raw text. The
bounded approximate matcher records character/word edits and ambiguity; context
queries retain each word's original segment/byte range. A short focus may be
supported by at least five aligned words in a longer surrounding passage.

`llm/transcript_model.sig` caches the exact common prompt-token prefix per runtime
and model. The numerical cache key includes matrix callback and effective matrix
context. Changing accelerator identity invalidates the prefix; a failed forward
invalidates it as well. Cancellation is checked at request start even when the
whole prompt and logits are cached. Changing configuration inside the same
accelerator context requires the caller to call `invalidateScoreCache()` before
the next request. Neither scores nor KV are persisted as an unkeyed disk cache.

Keep semantic checks separate from recognition accuracy and publication policy.
Text-only authored fixtures do not establish human Hebrew/Aramaic word accuracy,
speaker identity, acoustic word boundaries, or permission to remove speech.
Disagreement should remain reviewable alongside the original text and evidence.
