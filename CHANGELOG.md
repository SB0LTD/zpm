# Changelog

## 0.4.1 — 2026-10-11

### Added
- **`@zpm/youtube` live integrity-token minting in the download session.** The
  download path now mints a real content-bound + session-bound PO token on a
  fresh visitor session (no pinned relay, no cold-start). `session.establishIntegrityToken`
  uses the WAA **Create** flow (`challenge.fetchCreate` + `integrity.getToken` →
  `jnn-pa.googleapis.com` GenerateIT), the only challenge/endpoint pair whose VM
  snapshot populates getMinter AND whose response the server exchanges for a
  non-null integrity token. `GenerateIT` returns `["<token>",43200,100]` and the
  download logs `VM minted PO tokens (player=content-bound, GVS=session-bound)`.
- **SABR attestation plumbing** toward adaptive-audio delivery: SabrContextUpdate
  decode + echo (`sabr/ump.sig`, `sabr/request.sig` StreamerContext field 5,
  `sabr/stream.sig`), a bounded `STREAM_PROTECTION_STATUS==2` pending-retry, the
  session-bound GVS token in the SABR body, and SABR part-type counters for
  diagnosis. (Adaptive-audio-over-SABR for fully protected videos is still
  gated at ATTESTATION_PENDING; the muxed itag-18 path remains the working
  fallback. See the project progress notes.)

### Fixed
- **`session.parseHomepageChallenge`** now hex-unescapes the homepage BotGuard
  challenge (`\x22`/`\x7b`/`\x7d` → `"{}`), which the 2026 homepage uses; the old
  literal-quote scan silently found no challenge.

## 0.4.0 — 2026-10-11

### Added
- **`@zpm/youtube` native n-parameter + signature descrambling on the BotGuard
  jsvm (`player_transform.sig`).** Replaces the old pattern-matcher stub with a
  bounded, allocation-free extractor that lifts the player's indexed string
  table and the real `n`/signature transform functions — plus their lexical
  dependencies (the `typeof` guard constant, helper objects, referenced global
  functions) — and executes them on the shared BotGuard JavaScript VM. No
  external runtime (no Deno/Node/QuickJS). The approach keys on the player's
  string-table structure rather than brittle function-body patterns, so it
  survives minifier renames; it fails closed on the player's own
  `enhanced_except`/identity sentinels. `nsig.sig` is now a thin delegate
  (`MAX_NSIG_LEN` 64 → 256; never silently truncates). Verified against a live
  2026 `base.js` with 9 `n` vectors + the signature transform.
- **`@zpm/youtube` pure-Sig SABR/UMP/protobuf streaming client** (`sabr/`,
  `core/protobuf.sig`): a `VideoPlaybackAbrRequest` encoder (initialization +
  selected FormatIDs, buffered ranges, PO token, playback cookie), a UMP
  response parser, and the SABR delivery loop over the session cookie jar — the
  modern server-driven delivery path, implemented without yt-dlp or any external
  tool.
- **`@zpm/youtube` download client hardening.** iOS-first audio routing for
  unprotected videos (direct, transform-free URLs), with a one-shot fallback to
  the WEB/MWEB + nsig path when a protected video's iOS URL is rejected by GVS
  (the ~1 MB preview then HTTP 403). GVS-aware CDN requests: per-client stream
  User-Agent and conditional web `Origin`/`Referer` headers.
  `@zpm/youtube/mp4_verify` sniffs MP4 track/codec counts to verify downloaded
  media.
- **Session-bound GVS PO token for WEB/MWEB adaptive formats.** The CDN
  (`&pot=`) token for the web clients is now minted bound to the session's
  `visitorData` (not the video id), matching YouTube's GVS requirement for
  adaptive audio/video; the `/player` request keeps its content-bound token.
  This enables adaptive downloads wherever the live integrity-token mint
  succeeds. Where the mint is server-gated (anonymous/datacenter IPs return a
  null integrity token) the audio path now skips the guaranteed-403 adaptive
  retries and goes straight to the PO-exempt muxed itag-18 stream.
- **Custom CUDA kernels in `@zpm/matmul` (cuda backend).** The runtime dynamic
  loader now binds the driver-API module/launch entry points
  (`cuModuleLoadData`, `cuModuleGetFunction`, `cuLaunchKernel`,
  `cuDevicePrimaryCtxRetain`) and **NVRTC** (`nvrtcCompileProgram`,
  `nvrtcGetCUBIN`, …), so CUDA-C source can be compiled to **cubin** at runtime
  and launched — no build-time CUDA toolkit dependency. Targets the real SM
  (e.g. `sm_120`) so the driver never JITs PTX. `compile`, `loadModule`,
  `getFunction`, `launchKernel`, `kernelsAvailable`, `ensureContext`.
- **`@zpm/tts-kernels` — hand-written CUDA kernels + device weight residency for
  the TTS decode.** Compiles one CUDA-C translation unit to cubin once at init
  and exposes typed launch wrappers for every non-matmul op in the pipeline:
  rmsNorm / per-head rmsNorm, split-half RoPE, grouped-query & sliding-window
  attention (f32 KV), SiLU-gate, SnakeBeta, layerNorm, GELU, residual/scale add,
  and causal / transposed / depthwise conv1d. Also holds an any-rank f32 device
  weight cache (keyed by tensor offset) and device-resident cuBLAS gemm, so a
  whole decode stage runs without per-matmul host round-trips. Every kernel is
  numerically checked against its CPU reference. No-op when there is no GPU.
- **GPU-resident decode across the whole `@zpm/tts` stack.** The Talker + code
  predictor (`tts-talker-executor` `GpuForward`), the codec transformer
  (`tts-codec-transformer`), and the ConvNeXt/SnakeBeta vocoder (`tts-vocoder`)
  each gained a full device-resident forward: weights dequantized to f32 in VRAM
  once, activations kept on the device across all layers, elementwise/attention/
  conv on `tts-kernels`, matmuls on cuBLAS. Full f32 — more faithful than the
  CPU Q4×Q8 path — and it falls back to the exact CPU decoder when no GPU is
  present. Together these give a ~60x decode speedup over the CPU path.
- **`@zpm/tts-gpu` — optional cuBLAS acceleration for the TTS stack.** Lifts the
  Talker + codec matmul weights into VRAM once (dequantized to f32) and runs
  each matrix multiply through cuBLAS, keyed by tensor file offset. The tensor
  backends (`tts-talker-backend`, `tts-codec-backend`) consult it first and fall
  back to the exact CPU decoder when there is no CUDA device, so the stack stays
  buildable and correct everywhere.
- **Voice controls in `@zpm/tts-synth` (`VoiceConfig`).** The model-supported
  knobs are now configurable per utterance instead of hardcoded: the codec
  **language** (10 languages via `languageToken`), the Talker/predictor
  **sampling** (temperature, top-k, repetition penalty), and the **think**
  prefix. Defaults reproduce the pinned Base generation config.
- **`@zpm/tts` — native Qwen3-TTS-12Hz-0.6B neural speech synthesis.** A
  complete, allocation-free, pure-Sig text-to-waveform stack (Apache-2.0
  architecture): a 28-layer Talker + 5-layer code predictor emit 16-code
  acoustic frames (`tts-talker-*`, `tts-synth`, `tts-sampler`), an 8-layer
  sliding-window split-RVQ codec transformer maps codes to a latent
  (`tts-codec-transformer`), and a causal ConvNeXt + SnakeBeta vocoder expands
  each latent to 1,920 samples of 24 kHz PCM (`tts-vocoder`, `tts-codec`). Reads
  native SB0M model containers via `tts-model-container` and consumes only
  `quantized_linear` + `transformer_ops`. Extracted from the SB0 Nexus runtime
  where it was first developed; every module retains its bounded fixed-storage
  state machine and per-module tests. Exact but unaccelerated (~644x realtime).
- **`@zpm/wav`** — an allocation-free RIFF/WAVE PCM16 container writer (mono or
  stereo, 44-byte header, streaming or one-shot).
- **`@zpm/tts-voice`** — a phoneme → PCM16 source-filter narrator synthesizer
  (glottal source + formant resonators) built on the `english_phonemes`
  frontend, for instant offline narration without a model.
- **`@zpm/pdf-render` text extraction** (`pdf_render/text.sig`) — recover a
  PDF's readable text from its content streams: FlateDecode via `@zpm/inflate`
  plus the `Tj`/`TJ`/`'`/`"` text-showing operators, with string-escape and
  kerning-gap handling and `/Contents` reference resolution.

### Changed
- **`@zpm/youtube/cipher`** now tracks the player generation and grew its
  player.js buffer (2 MB → 4 MB) so the ~2.6 MB 2026 `base.js` is no longer
  truncated before the cipher/nsig functions.

### Fixed
- **`@zpm/youtube/sabr`** golden `VideoPlaybackAbrRequest` test and the
  `stream.sig` module import (`youtube_net`) so the SABR tests build and pass
  under the zpm test runner.
- **`@zpm/pdf-render` page detection** (`pdf_render/parser.sig`): `parsePages`
  matched only the spaced `/Type /Page` form followed by a newline/space/`>`,
  so it found zero pages in files that emit the tight `/Type/Page` syntax (the
  common Ghostscript/qpdf output). Replaced with a whitespace- and
  delimiter-tolerant `isPageObject` that also correctly excludes the `/Pages`
  page-tree root. Added regression tests.

## 0.3.0 — 2026-09-04

### Changed

- **Starter templates modernized to native Sig.** `zpm init` now generates
  `build.sig` files using the allocator-free `sig_build` API
  (`pub fn build(ctx: *sig_build.Build_Context) !void`) instead of the legacy
  `std.Build` API. Generated `src/main.sig` uses the current
  `main(init: std.process.Init) !void` form with `std.Io` (no allocators,
  no `std.debug.print`).
- **`build.sig.zon` schema updated.** Templates drop `minimum_zig_version` in
  favor of `.fingerprint`. Projects that depend on zpm declare it as a fetched
  GitHub tarball dependency (`.url` + `.hash`) resolved by the Sig toolchain.
- Generated projects wire zpm modules through the new
  `ctx.getDependency("zpm").modulePath(...)` bridge — no hardcoded paths and no
  vendored source tree.
- `zpm run` / `zpm build` now report and delegate to `sig build` (was
  `zig build`). README and docs updated to the Sig-native, GitHub-source model.

### Notes

- The hosted registry (`registry.zpm.dev`) is planned but not yet deployed;
  packages are distributed from `github.com/SB0LTD/zpm`. `install`/`search`/
  `publish` target the registry and require `--registry` until it is live.

## 0.2.1 — 2026-09-01

### Added

- Bounded HTTP/3 framing, static QPACK, fragmented request decoding, and a
  fixed-capacity server API.
- Versioned SB0 application SDK v1 for delegated network and storage device
  queues.
- Deterministic JSON-to-Sig contract generator with drift checking.

### Fixed

- QUIC v1 Initial secrets now follow RFC 9001's empty-context
  HKDF-Expand-Label derivation and pass the Appendix A vectors.
- P-256 modular multiplication now uses fixed-work four-limb Montgomery CIOS
  reduction instead of unbounded repeated subtraction.
- X25519 serialization and the RFC 7748 Montgomery-ladder constant.
- Zig 0.17/Sig 0.4 compatibility across crypto, inference, tokenizer, and
  transport module wiring.
- Official-package catalog assertions now match the 37-package catalog.

### Verification

- Root library/transport suite: 67 succeeded, 0 failed, 2 skipped.
- CLI suite: 13 succeeded, 0 failed, 1 skipped.
- Native CLI build reports `zpm v0.2.1`.

## 0.1.0 — 2025-06-20

Initial release — zpm transforms from a Windows-only Zig module library into a cross-platform package manager for the Zig ecosystem.

### Added

- **Package manager CLI** with 11 commands: init, install, uninstall, list, search, publish, validate, update, doctor, run, build
- **Cross-platform support** — Windows, macOS, and Linux via Platform Abstraction Layer (PAL) with comptime OS dispatch
- **Scoped package naming** — `@zpm/<package>` for official packages, `@<scope>/<name>` for third-party
- **Dependency resolver** — BFS traversal with deduplication, layer validation, and cycle detection
- **build.zig.zon manipulation** — zero-allocation ZON parser/writer for adding and removing dependencies
- **Package manifest format** — `zpm.pkg.zon` with protocol version, layer, platform, system libraries, and constraints
- **Layer validation** — enforces Layer 0 → 1 → 2 ordering in dependency graphs
- **Project scaffolding** — 9 templates: empty, cli-app, web-server, gui-app, library, package, window, gl-app, trading
- **Registry client** — HTTP-based with optional QUIC transport (`--transport quic`)
- **QUIC transport stack** — full RFC 9000/9001/9002/9221 implementation with Control, Bulk, and Hot lanes
- **Zig bootstrapper** — auto-detects and downloads Zig 0.16+ if not available
- **34 official @zpm/ packages** — existing modules (core, math, json, win32, gl, window, transport, render, etc.) as installable packages
- **Edit distance suggestions** — typo correction for unknown commands and flags
- **Offline mode** — `--offline` flag for air-gapped environments

### Architecture

- Layer 0 (Core): core, math, json — pure logic, no platform dependencies
- Layer 1 (Platform): win32, gl, window, timer, http, crypto, file-io, threading, logging, input, png, screenshot, mcp, seqlock
- Layer 1 (Transport): udp, packet, transport-crypto, recovery, streams, datagram, telemetry, scheduler, conn, appmap
- Layer 2 (Render): color, primitives, text, icon

### Targets

- Zig 0.16+ (officially supported)
- x86_64-windows, x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos
