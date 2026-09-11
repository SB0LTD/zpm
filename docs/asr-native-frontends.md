# Native ASR foundations

The `safetensors` and `asr_mel` packages provide allocation-free model data and
audio feature preparation. `asr` re-exports them alongside experimental encoder,
decoder and streaming code. Native transcription is not yet admitted.

## Audio features

`asr_mel.computeBounded(audio, output, workspace)` accepts 16 kHz mono f32 PCM,
201–480,000 samples. The caller supplies an `asr_mel.Workspace` (11,208 bytes)
and at least `(audio.len / 160) * 128` output floats. The result is frame-major.
The API validates sizes, finite samples and input/output overlap before writing.
Longer sessions need explicit segmentation.

The frontend uses a 400-point mixed-radix FFT, periodic Hann window, centered
reflection, 128 Slaney filters and the model's log10/dynamic-range normalization.
It matches the pinned [Transformers 4.57.6 WhisperFeatureExtractor](https://github.com/huggingface/transformers/blob/v4.57.6/src/transformers/models/whisper/feature_extraction_whisper.py)
selected by Qwen3-ASR-0.6B. Seven independent fixtures cover silence, short DC,
boundary impulses, off-bin tones, noise, quiet input and an irregular-length ramp.
On Sig 0.5.5, 5,658 assertions pass with maximum absolute error
`0.00000011920929` against the reference (tolerance `0.00002`).

The prototype model and streaming consumers now require caller-provided feature
storage and this workspace. They no longer allocate 30 MiB stack buffers or
normalize the new frontend's output a second time. The older `compute` and
`computeFrame` functions retain their documented uncentered natural-log contract;
new consumers should use `computeBounded`.

## Model storage

`safetensors.Index.parse(file_bytes, tensor_storage)` validates a complete
immutable mapping and creates an index in caller storage. Names must be unescaped
UTF-8, rank is at most eight, and metadata is a string map with at most 128 keys.
The header limit is 8 MiB. Duplicate keys, unsupported dtypes, shape/offset
overflow, overlaps, holes and trailing data fail explicitly. Views read BF16,
F16 and F32 values directly without requiring aligned tensor addresses or
expanding the entire model to f32.

The format tests execute 14,395 assertions, including fixtures serialized and
independently read by [Safetensors 0.8.0](https://github.com/safetensors/safetensors).
The actual Qwen3-ASR-0.6B artifact at revision
`5eb144179a02acc5e5ba31e748d22b0cf3e303b0` was checked on 2026-09-11:

- Model: 1,876,091,704 bytes, 612 BF16 tensors.
- Model SHA-256: `79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea`.
- First/middle/last samples from each tensor: 1,836 f32 values.
- Native and independent sample digest: `94287146314a0b3a4010d398c493f0ca016a1570ff151b116973b1eb36152046`.

## Reproduce

Use the complete Sig 0.5.5 release and the current ZPM CLI:

```powershell
zpm build test-asr inspect-safetensors
./sig-out/bin/inspect-safetensors.exe /path/to/model.safetensors
```

The inspection tool maps the file with native OS facilities and rejects an
unmapped fallback. The pure package parser performs no file I/O. Fixture
generators record their reference versions; they are optional host test tools,
and their Python dependencies are not runtime dependencies.

## Remaining native recognition work

Model weight binding, encoder/decoder numerical parity, vocabulary decoding,
streaming rollback and native latency/word-error evidence remain unfinished.
The experimental `Model.transcribe` output is packed token IDs, not UTF-8 text.
These frontend and format checks must not be treated as recognition acceptance.
