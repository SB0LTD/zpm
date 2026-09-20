// ZPM's canonical zero-allocation Sig build graph.
//
// `build.zig` remains the transitional upstream-Zig graph. This file uses the
// bounded sig_build API exclusively so `sig build` never falls back to Zig's
// allocator-backed std.Build implementation.
const sig_build = @import("sig_build");
const builtin = @import("builtin");

fn noopStep(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    _ = ctx;
}

fn importEntry(name: []const u8, path: []const u8) sig_build.Import_Entry {
    var entry: sig_build.Import_Entry = .{};
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    @memcpy(entry.path[0..path.len], path);
    entry.path_len = path.len;
    return entry;
}

fn wire(ctx: *sig_build.Build_Context, module: sig_build.Module_Handle, name: []const u8, path: []const u8) !void {
    try ctx.addImport(module, name, path);
}

fn addTest(
    ctx: *sig_build.Build_Context,
    aggregate: sig_build.Step_Handle,
    name: []const u8,
    source_path: []const u8,
    imports: []const sig_build.Import_Entry,
) !sig_build.Step_Handle {
    const step = try ctx.addTestStep(.{
        .name = name,
        .source_path = source_path,
        .imports = imports,
    });
    try ctx.addDependency(aggregate, step);
    return step;
}

// These contracts have runnable mains and assertion counters. A compiler that
// discovers zero `test` declarations cannot accidentally accept this suite.
fn runContract(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    const entry = &ctx.build_ctx.steps.entries[ctx.step_handle];
    const name = entry.desc[0..entry.desc_len];
    const prefix = ctx.build_ctx.install_prefix[0..ctx.build_ctx.install_prefix_len];
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    var path: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const len = prefix.len + 5 + name.len + suffix.len;
    if (len > path.len) return error.BufferTooSmall;
    @memcpy(path[0..prefix.len], prefix);
    @memcpy(path[prefix.len..][0..5], "/bin/");
    @memcpy(path[prefix.len + 5 ..][0..name.len], name);
    @memcpy(path[prefix.len + 5 + name.len ..][0..suffix.len], suffix);
    var cmd: sig_build.Command_Buffer = .{};
    try cmd.appendArg(path[0..len]);
    const step_name = entry.name[0..entry.name_len];
    const negative = namesEqual(step_name, "prove-now-assertions");
    if (negative) try cmd.appendArg("--prove-failure");
    try cmd.setCwd(ctx.build_ctx.build_root[0..ctx.build_ctx.build_root_len]);
    var errors: [sig_build.STDERR_CAPTURE_SIZE]u8 = undefined;
    var errors_len: usize = 0;
    const status = try sig_build.runCommand(&cmd, &errors, &errors_len, ctx.io);
    if (negative) {
        if (status == 0) return error.BufferTooSmall;
        sig_build.printMsg(ctx.io, "PASS intentional assertion failure detected", .{});
    } else {
        if (errors_len != 0) sig_build.printMsg(ctx.io, "{s}", .{errors[0..errors_len]});
        if (status != 0) return error.BufferTooSmall;
    }
}

fn namesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn addContract(ctx: *sig_build.Build_Context, aggregate: sig_build.Step_Handle, comptime name: []const u8, source: []const u8, imports: []const sig_build.Import_Entry) !sig_build.Step_Handle {
    const compiled = try ctx.addCompileStep(.{
        .source_path = source,
        .output_name = name,
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = imports,
        .compiler_path = "",
    });
    const run = try ctx.addStep("run-" ++ name, name, &runContract);
    try ctx.addDependency(run, compiled);
    try ctx.addDependency(aggregate, run);
    return compiled;
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    const test_all = try ctx.addStep("test", "Run all ZPM unit and compliance tests", &noopStep);

    // Core modules.
    _ = try ctx.addModule("math", "src/core/math.sig");
    _ = try ctx.addModule("sig_math", "src/core/sig_math.sig");
    const synth_voice = try ctx.addModule("synth_voice", "src/core/synth_voice.sig");
    try wire(ctx, synth_voice, "math", "src/core/math.sig");
    try wire(ctx, synth_voice, "sig_math", "src/core/sig_math.sig");
    _ = try ctx.addModule("sig_mem", "src/core/sig_mem.sig");
    _ = try ctx.addModule("sig_testing", "src/core/sig_testing.sig");
    const sig_text = try ctx.addModule("sig_text", "src/core/sig_text.sig");
    try wire(ctx, sig_text, "sig_mem", "src/core/sig_mem.sig");
    const safetensors = try ctx.addModule("safetensors", "src/core/safetensors.sig");
    try wire(ctx, safetensors, "sig_text", "src/core/sig_text.sig");
    _ = try ctx.addModule("asr_mel", "src/asr/mel.sig");
    const asr = try ctx.addModule("asr", "src/asr/root.sig");
    try wire(ctx, asr, "safetensors", "src/core/safetensors.sig");
    try wire(ctx, asr, "asr_mel", "src/asr/mel.sig");
    const test_asr = try ctx.addStep("test-asr", "Execute native ASR format and numerical contracts", &noopStep);
    try ctx.addDependency(test_all, test_asr);
    _ = try addContract(ctx, test_asr, "contract-safetensors", "tests/test_safetensors.sig", &.{importEntry("safetensors", "src/core/safetensors.sig")});
    _ = try addContract(ctx, test_asr, "contract-asr-mel", "tests/test_asr_mel.sig", &.{importEntry("asr_mel", "src/asr/mel.sig")});
    _ = try addContract(ctx, test_asr, "contract-asr-consumers", "tests/test_asr_frontend_consumers.sig", &.{importEntry("asr", "src/asr/root.sig")});

    inline for (.{ "ephemeral_scene", "now_voice_output", "device_control", "english_phonemes" }) |name| {
        const module = try ctx.addModule(name, "src/core/" ++ name ++ ".sig");
        try wire(ctx, module, "sig_mem", "src/core/sig_mem.sig");
        try wire(ctx, module, "sig_text", "src/core/sig_text.sig");
        try wire(ctx, module, "sig_testing", "src/core/sig_testing.sig");
    }
    const test_now = try ctx.addStep("test-now", "Execute bounded scene, voice, device and speech-text contracts", &noopStep);
    try ctx.addDependency(test_all, test_now);
    const scene_contract = try addContract(ctx, test_now, "contract-ephemeral-scene", "tests/test_ephemeral_scene.sig", &.{importEntry("ephemeral_scene", "src/core/ephemeral_scene.sig")});
    const negative = try ctx.addStep("prove-now-assertions", "contract-ephemeral-scene", &runContract);
    try ctx.addDependency(negative, scene_contract);
    try ctx.addDependency(test_now, negative);
    _ = try addContract(ctx, test_now, "contract-now-voice", "tests/test_now_voice_output.sig", &.{importEntry("now_voice_output", "src/core/now_voice_output.sig")});
    _ = try addContract(ctx, test_now, "contract-device-control", "tests/test_device_control.sig", &.{importEntry("device_control", "src/core/device_control.sig")});
    _ = try addContract(ctx, test_now, "contract-speech-text", "tests/test_speech_text.sig", &.{
        importEntry("english_phonemes", "src/core/english_phonemes.sig"),
        importEntry("sig_text", "src/core/sig_text.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    const json = try ctx.addModule("json", "src/core/json.sig");
    try wire(ctx, json, "sig_mem", "src/core/sig_mem.sig");
    const sha256 = try ctx.addModule("sha256", "src/core/sha256.sig");
    try wire(ctx, sha256, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, sha256, "sig_testing", "src/core/sig_testing.sig");
    var process_path: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    const lib = ctx.sig_lib_dir[0..ctx.sig_lib_dir_len];
    const process_suffix = "/sig/process.sig";
    if (lib.len + process_suffix.len > process_path.len) return error.BufferTooSmall;
    @memcpy(process_path[0..lib.len], lib);
    @memcpy(process_path[lib.len..][0..process_suffix.len], process_suffix);
    const process_source = process_path[0 .. lib.len + process_suffix.len];
    _ = try ctx.addModule("sig_process", process_source);
    _ = try ctx.addCompileStep(.{
        .source_path = "tools/inspect_safetensors.sig",
        .output_name = "inspect-safetensors",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .compiler_path = "",
        .imports = &.{ importEntry("safetensors", "src/core/safetensors.sig"), importEntry("sha256", "src/core/sha256.sig"), importEntry("sig_process", process_source) },
    });

    const inflate = try ctx.addModule("inflate", "src/core/inflate.sig");
    try wire(ctx, inflate, "sig_mem", "src/core/sig_mem.sig");
    const opus = try ctx.addModule("opus", "src/core/opus.sig");
    try wire(ctx, opus, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, opus, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, opus, "sig_testing", "src/core/sig_testing.sig");

    // ── Image analysis + Elementor (Layer 0: pure computation) ──
    const png_decode = try ctx.addModule("png_decode", "src/image/png_decode.sig");
    try wire(ctx, png_decode, "inflate", "src/core/inflate.sig");
    _ = try addTest(ctx, test_all, "test-png-decode", "src/image/png_decode.sig", &.{
        importEntry("inflate", "src/core/inflate.sig"),
    });
    _ = try ctx.addModule("image", "src/image/image.sig");
    _ = try addTest(ctx, test_all, "test-image", "src/image/image.sig", &.{});
    const layout = try ctx.addModule("layout", "src/image/layout.sig");
    try wire(ctx, layout, "image", "src/image/image.sig");
    _ = try addTest(ctx, test_all, "test-layout", "src/image/layout.sig", &.{
        importEntry("image", "src/image/image.sig"),
    });
    const text_analyze = try ctx.addModule("text_analyze", "src/image/text_analyze.sig");
    try wire(ctx, text_analyze, "image", "src/image/image.sig");
    _ = try addTest(ctx, test_all, "test-text-analyze", "src/image/text_analyze.sig", &.{
        importEntry("image", "src/image/image.sig"),
    });
    _ = try ctx.addModule("elementor_document", "src/elementor/document.sig");
    _ = try addTest(ctx, test_all, "test-elementor-document", "src/elementor/document.sig", &.{});
    // NOTE: the web-automation stack's unit tests — websocket (RFC 6455),
    // dom_import (extractor + envelope), and cdp (target discovery, surrogate
    // decoding) — are run directly with `sig test src/net/websocket.sig`,
    // `sig test src/elementor/dom_import.sig`, and (with its deps) the stools
    // build. They are intentionally not added to this aggregate step because
    // the fixed build graph here is already at its step capacity.

    // win32 is registered here (ahead of the crypto tests) because the pure-Sig
    // TLS client and its `test-tls-client` step import it via importEntry, which
    // interns the module by name. Registering it up front keeps that early
    // reference and the later platform consumers pointing at one canonical
    // module (a second addModule would fail with a duplicate-name error).
    const win32_path = if (builtin.os.tag == .windows)
        "src/platform/win32.sig"
    else
        "src/transport/linux_platform.sig";
    _ = try ctx.addModule("win32", win32_path);

    // ── Crypto modules (Layer 0: pure computation, freestanding) ──
    const crypto_hmac = try ctx.addModule("hmac", "src/core/crypto/hmac.sig");
    try wire(ctx, crypto_hmac, "sha256", "src/core/sha256.sig");
    const crypto_hkdf = try ctx.addModule("hkdf", "src/core/crypto/hkdf.sig");
    try wire(ctx, crypto_hkdf, "hmac", "src/core/crypto/hmac.sig");
    _ = try ctx.addModule("aes", "src/core/crypto/aes.sig");
    const crypto_gcm = try ctx.addModule("gcm", "src/core/crypto/gcm.sig");
    try wire(ctx, crypto_gcm, "aes", "src/core/crypto/aes.sig");
    _ = try ctx.addModule("x25519", "src/core/crypto/x25519.sig");
    const crypto_p256 = try ctx.addModule("p256", "src/core/crypto/p256.sig");
    try wire(ctx, crypto_p256, "sha256", "src/core/sha256.sig");
    try wire(ctx, crypto_p256, "hmac", "src/core/crypto/hmac.sig");
    const crypto_tls13 = try ctx.addModule("tls13_keys", "src/core/crypto/tls13_keys.sig");
    try wire(ctx, crypto_tls13, "sha256", "src/core/sha256.sig");
    try wire(ctx, crypto_tls13, "hkdf", "src/core/crypto/hkdf.sig");
    try wire(ctx, crypto_tls13, "hmac", "src/core/crypto/hmac.sig");
    const crypto_quic_keys = try ctx.addModule("quic_keys", "src/core/crypto/quic_keys.sig");
    try wire(ctx, crypto_quic_keys, "sha256", "src/core/sha256.sig");
    try wire(ctx, crypto_quic_keys, "hkdf", "src/core/crypto/hkdf.sig");
    try wire(ctx, crypto_quic_keys, "aes", "src/core/crypto/aes.sig");
    // Pure-Sig TLS 1.3 client (ASN.1/DER, RSA, X.509, chain verify, record layer)
    // as one directory module — internal files import each other relatively.
    const tls_client = try ctx.addModule("tls_client", "src/core/crypto/tls/client.sig");
    try wire(ctx, tls_client, "sha256", "src/core/sha256.sig");
    try wire(ctx, tls_client, "p256", "src/core/crypto/p256.sig");
    try wire(ctx, tls_client, "hkdf", "src/core/crypto/hkdf.sig");
    try wire(ctx, tls_client, "gcm", "src/core/crypto/gcm.sig");
    try wire(ctx, tls_client, "x25519", "src/core/crypto/x25519.sig");
    try wire(ctx, tls_client, "tls13_keys", "src/core/crypto/tls13_keys.sig");
    // NOTE: the tls_client → win32 edge is wired further below, next to the
    // other platform consumers, using the win32_path/module registered up in
    // the crypto block. Wiring it here is unnecessary and the module already
    // exists by that point.

    // WebSocket (RFC 6455) framer + the wss:// composition over the pure-Sig
    // TLS stack. `websocket` is pure (std only); `wss` stacks websocket on a
    // tls_client Conn. These unify all app WebSocket usage onto one stack.
    _ = try ctx.addModule("websocket", "src/net/websocket.sig");
    const wss = try ctx.addModule("wss", "src/net/wss.sig");
    try wire(ctx, wss, "tls_client", "src/core/crypto/tls/client.sig");
    try wire(ctx, wss, "websocket", "src/net/websocket.sig");

    const jsonl = try ctx.addModule("jsonl", "src/core/jsonl.sig");
    try wire(ctx, jsonl, "json", "src/core/json.sig");
    try wire(ctx, jsonl, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, jsonl, "sig_testing", "src/core/sig_testing.sig");
    const ai_core = try ctx.addModule("ai_core", "src/core/ai_core.sig");
    try wire(ctx, ai_core, "sig_testing", "src/core/sig_testing.sig");
    _ = try ctx.addModule("quantized_linear", "src/core/quantized_linear.sig");
    const transformer_ops = try ctx.addModule("transformer_ops", "src/core/transformer_ops.sig");
    try wire(ctx, transformer_ops, "sig_math", "src/core/sig_math.sig");
    const audio_dsp = try ctx.addModule("audio_dsp", "src/core/audio_dsp.sig");
    try wire(ctx, audio_dsp, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, audio_dsp, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, audio_dsp, "sig_testing", "src/core/sig_testing.sig");
    const vector_memory = try ctx.addModule("vector_memory", "src/core/vector_memory.sig");
    try wire(ctx, vector_memory, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, vector_memory, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, vector_memory, "sig_testing", "src/core/sig_testing.sig");
    const moment_activation = try ctx.addModule("moment_activation", "src/core/moment_activation.sig");
    try wire(ctx, moment_activation, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, moment_activation, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, moment_activation, "sig_testing", "src/core/sig_testing.sig");
    const agent_runtime = try ctx.addModule("agent_runtime", "src/core/agent_runtime.sig");
    try wire(ctx, agent_runtime, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, agent_runtime, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, agent_runtime, "sig_testing", "src/core/sig_testing.sig");
    const model_observability = try ctx.addModule("model_observability", "src/core/model_observability.sig");
    try wire(ctx, model_observability, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, model_observability, "sig_testing", "src/core/sig_testing.sig");
    const multimodal_now = try ctx.addModule("multimodal_now", "src/core/multimodal_now.sig");
    try wire(ctx, multimodal_now, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, multimodal_now, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, multimodal_now, "sig_testing", "src/core/sig_testing.sig");

    // Platform: SB0 native image format (Layer 1, pure byte encoder).
    _ = try ctx.addModule("sb0x_format", "src/platform/sb0x/format.sig");

    const cognitive_receipt = try ctx.addModule("cognitive_receipt", "src/core/cognitive_receipt.sig");
    try wire(ctx, cognitive_receipt, "vector_memory", "src/core/vector_memory.sig");
    try wire(ctx, cognitive_receipt, "moment_activation", "src/core/moment_activation.sig");
    try wire(ctx, cognitive_receipt, "agent_runtime", "src/core/agent_runtime.sig");
    try wire(ctx, cognitive_receipt, "model_observability", "src/core/model_observability.sig");
    try wire(ctx, cognitive_receipt, "multimodal_now", "src/core/multimodal_now.sig");
    try wire(ctx, cognitive_receipt, "sig_testing", "src/core/sig_testing.sig");
    const core = try ctx.addModule("core", "src/core/root.sig");
    try wire(ctx, core, "sig_mem", "src/core/sig_mem.sig");
    inline for (.{ "sig_text", "safetensors", "ephemeral_scene", "now_voice_output", "device_control", "english_phonemes" }) |name|
        try wire(ctx, core, name, "src/core/" ++ name ++ ".sig");
    try wire(ctx, core, "math", "src/core/math.sig");
    try wire(ctx, core, "json", "src/core/json.sig");
    try wire(ctx, core, "sha256", "src/core/sha256.sig");
    try wire(ctx, core, "jsonl", "src/core/jsonl.sig");
    try wire(ctx, core, "ai_core", "src/core/ai_core.sig");
    try wire(ctx, core, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, core, "transformer_ops", "src/core/transformer_ops.sig");
    try wire(ctx, core, "audio_dsp", "src/core/audio_dsp.sig");
    try wire(ctx, core, "vector_memory", "src/core/vector_memory.sig");
    try wire(ctx, core, "moment_activation", "src/core/moment_activation.sig");
    try wire(ctx, core, "agent_runtime", "src/core/agent_runtime.sig");
    try wire(ctx, core, "cognitive_receipt", "src/core/cognitive_receipt.sig");
    try wire(ctx, core, "model_observability", "src/core/model_observability.sig");
    try wire(ctx, core, "multimodal_now", "src/core/multimodal_now.sig");

    _ = try addTest(ctx, test_all, "test-ai-core", "src/core/ai_core.sig", &.{importEntry("sig_testing", "src/core/sig_testing.sig")});
    _ = try addTest(ctx, test_all, "test-quantized-linear", "src/core/quantized_linear.sig", &.{});
    _ = try addTest(ctx, test_all, "test-transformer-ops", "src/core/transformer_ops.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    _ = try addTest(ctx, test_all, "test-audio-dsp", "src/core/audio_dsp.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"), importEntry("sig_mem", "src/core/sig_mem.sig"), importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-math", "src/core/math.sig", &.{});
    _ = try addTest(ctx, test_all, "test-sig-math", "src/core/sig_math.sig", &.{});
    _ = try addTest(ctx, test_all, "test-synth_voice", "src/core/synth_voice.sig", &.{
        importEntry("math", "src/core/math.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    // WAV (PCM16 RIFF/WAVE) container writer — pure, std-only.
    _ = try addTest(ctx, test_all, "test-wav", "src/core/wav.sig", &.{});
    // Phoneme → PCM16 narrator synthesizer (source-filter TTS voice).
    const tts_voice = try ctx.addModule("tts_voice", "src/core/tts_voice.sig");
    try wire(ctx, tts_voice, "math", "src/core/math.sig");
    try wire(ctx, tts_voice, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, tts_voice, "english_phonemes", "src/core/english_phonemes.sig");
    _ = try addTest(ctx, test_all, "test-tts-voice", "src/core/tts_voice.sig", &.{
        importEntry("math", "src/core/math.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("english_phonemes", "src/core/english_phonemes.sig"),
    });
    _ = try addTest(ctx, test_all, "test-vector-memory", "src/core/vector_memory.sig", &.{
        importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    _ = try addTest(ctx, test_all, "test-moment-activation", "src/core/moment_activation.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),       importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-agent-runtime", "src/core/agent_runtime.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),       importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-model-observability", "src/core/model_observability.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"), importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-multimodal-now", "src/core/multimodal_now.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),       importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-sb0x-format", "src/platform/sb0x/format.sig", &.{});
    _ = try addTest(ctx, test_all, "test-cognitive-receipt", "src/core/cognitive_receipt.sig", &.{
        importEntry("vector_memory", "src/core/vector_memory.sig"),
        importEntry("moment_activation", "src/core/moment_activation.sig"),
        importEntry("agent_runtime", "src/core/agent_runtime.sig"),
        importEntry("model_observability", "src/core/model_observability.sig"),
        importEntry("multimodal_now", "src/core/multimodal_now.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-sha256", "src/core/sha256.sig", &.{
        importEntry("sig_mem", "src/core/sig_mem.sig"), importEntry("sig_testing", "src/core/sig_testing.sig"),
    });
    _ = try addTest(ctx, test_all, "test-hmac", "src/core/crypto/hmac.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
    });
    _ = try addTest(ctx, test_all, "test-hkdf", "src/core/crypto/hkdf.sig", &.{
        importEntry("hmac", "src/core/crypto/hmac.sig"),
        importEntry("sha256", "src/core/sha256.sig"),
    });
    _ = try addTest(ctx, test_all, "test-aes", "src/core/crypto/aes.sig", &.{});
    _ = try addTest(ctx, test_all, "test-gcm", "src/core/crypto/gcm.sig", &.{
        importEntry("aes", "src/core/crypto/aes.sig"),
    });
    _ = try addTest(ctx, test_all, "test-x25519", "src/core/crypto/x25519.sig", &.{});
    _ = try addTest(ctx, test_all, "test-p256", "src/core/crypto/p256.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
        importEntry("hmac", "src/core/crypto/hmac.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tls13-keys", "src/core/crypto/tls13_keys.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
        importEntry("hmac", "src/core/crypto/hmac.sig"),
        importEntry("hkdf", "src/core/crypto/hkdf.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tls-client", "src/core/crypto/tls/client.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
        importEntry("p256", "src/core/crypto/p256.sig"),
        importEntry("hkdf", "src/core/crypto/hkdf.sig"),
        importEntry("gcm", "src/core/crypto/gcm.sig"),
        importEntry("x25519", "src/core/crypto/x25519.sig"),
        importEntry("tls13_keys", "src/core/crypto/tls13_keys.sig"),
        importEntry("win32", "src/platform/win32.sig"),
    });
    // WebSocket RFC 6455 framer unit tests (hermetic — MemTransport, no net).
    _ = try addTest(ctx, test_all, "test-websocket", "src/net/websocket.sig", &.{});

    // Live network harness for the pure-Sig TLS 1.3 client. NOT wired into the
    // `test` aggregate because it needs real egress to stream.binance.com:9443.
    // Run it explicitly with `sig build live-tls`. It imports tls_client (the
    // directory-module entry) plus win32 for the wall clock; tls_client pulls
    // its crypto deps in via its own registered imports.
    const live_all = try ctx.addStep("live-tls", "Live pure-Sig TLS 1.3 handshake against a real exchange endpoint", &noopStep);
    _ = try addContract(ctx, live_all, "live-tls-handshake", "tests/live_tls_handshake.sig", &.{
        importEntry("tls_client", "src/core/crypto/tls/client.sig"),
        importEntry("win32", "src/platform/win32.sig"),
    });

    // Live wss:// harness — full stack: DNS + TCP + TLS 1.3 + WebSocket upgrade
    // + a real market-data frame from Binance. Not in the `test` aggregate.
    const live_wss = try ctx.addStep("live-wss", "Live pure-Sig wss:// WebSocket against a real exchange stream", &noopStep);
    _ = try addContract(ctx, live_wss, "live-wss-stream", "tests/live_wss.sig", &.{
        importEntry("wss", "src/net/wss.sig"),
        importEntry("tls_client", "src/core/crypto/tls/client.sig"),
        importEntry("websocket", "src/net/websocket.sig"),
        importEntry("win32", "src/platform/win32.sig"),
    });
    _ = try addTest(ctx, test_all, "test-quic-keys", "src/core/crypto/quic_keys.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
        importEntry("hmac", "src/core/crypto/hmac.sig"),
        importEntry("hkdf", "src/core/crypto/hkdf.sig"),
        importEntry("aes", "src/core/crypto/aes.sig"),
    });
    _ = try addTest(ctx, test_all, "test-inflate", "src/core/inflate.sig", &.{
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    // PDF structure parser (xref, objects, page detection) — pure, std-only.
    _ = try addTest(ctx, test_all, "test-pdf-parser", "src/pdf_render/parser.sig", &.{});
    // PDF text extraction (content-stream Tj/TJ + FlateDecode). Consumes the
    // pdf parser (relative import) and the inflate module.
    _ = try addTest(ctx, test_all, "test-pdf-text", "src/pdf_render/text.sig", &.{
        importEntry("inflate", "src/core/inflate.sig"),
    });
    _ = try addTest(ctx, test_all, "test-jsonl", "src/core/jsonl.sig", &.{
        importEntry("json", "src/core/json.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("sig_testing", "src/core/sig_testing.sig"),
    });

    // ── Inference pipeline modules (Layer 0 — pure computation, zero platform deps) ──
    const gguf = try ctx.addModule("gguf", "src/core/gguf.sig");
    try wire(ctx, gguf, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, gguf, "sig_mem", "src/core/sig_mem.sig");
    _ = try ctx.addModule("gguf_file", "src/core/gguf_file.sig");
    const sampling = try ctx.addModule("sampling", "src/core/sampling.sig");
    try wire(ctx, sampling, "sig_math", "src/core/sig_math.sig");
    _ = try ctx.addModule("kv_cache", "src/core/kv_cache.sig");
    const tokenizer_index = try ctx.addModule("tokenizer_index", "src/core/tokenizer_index.sig");
    try wire(ctx, tokenizer_index, "gguf", "src/core/gguf.sig");
    try wire(ctx, tokenizer_index, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, tokenizer_index, "sig_mem", "src/core/sig_mem.sig");
    const tokenizer = try ctx.addModule("tokenizer", "src/core/tokenizer.sig");
    try wire(ctx, tokenizer, "gguf", "src/core/gguf.sig");
    try wire(ctx, tokenizer, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, tokenizer, "sig_mem", "src/core/sig_mem.sig");
    try wire(ctx, tokenizer, "tokenizer_index", "src/core/tokenizer_index.sig");
    const qwen3_decoder_plan = try ctx.addModule("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig");
    try wire(ctx, qwen3_decoder_plan, "gguf", "src/core/gguf.sig");
    try wire(ctx, qwen3_decoder_plan, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, qwen3_decoder_plan, "sig_mem", "src/core/sig_mem.sig");
    const qwen35_plan = try ctx.addModule("qwen35_plan", "src/core/qwen35_plan.sig");
    try wire(ctx, qwen35_plan, "gguf", "src/core/gguf.sig");
    try wire(ctx, qwen35_plan, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, qwen35_plan, "sig_mem", "src/core/sig_mem.sig");
    const qwen35_gdn = try ctx.addModule("qwen35_gdn", "src/core/qwen35_gdn.sig");
    try wire(ctx, qwen35_gdn, "sig_math", "src/core/sig_math.sig");
    const qwen3_executor = try ctx.addModule("qwen3_executor", "src/core/qwen3_executor.sig");
    try wire(ctx, qwen3_executor, "sig_math", "src/core/sig_math.sig");
    try wire(ctx, qwen3_executor, "gguf", "src/core/gguf.sig");
    try wire(ctx, qwen3_executor, "qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig");
    try wire(ctx, qwen3_executor, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, qwen3_executor, "transformer_ops", "src/core/transformer_ops.sig");
    const inference_session = try ctx.addModule("inference_session", "src/core/inference_session.sig");
    try wire(ctx, inference_session, "gguf", "src/core/gguf.sig");
    try wire(ctx, inference_session, "qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig");
    try wire(ctx, inference_session, "qwen3_executor", "src/core/qwen3_executor.sig");
    try wire(ctx, inference_session, "tokenizer", "src/core/tokenizer.sig");
    try wire(ctx, inference_session, "tokenizer_index", "src/core/tokenizer_index.sig");
    try wire(ctx, inference_session, "sampling", "src/core/sampling.sig");
    try wire(ctx, inference_session, "kv_cache", "src/core/kv_cache.sig");

    // Inference pipeline tests
    const test_qwen = try ctx.addStep("test-qwen", "Execute resumable decoder numerical and cancellation contracts", &noopStep);
    try ctx.addDependency(test_all, test_qwen);
    _ = try addContract(ctx, test_qwen, "contract-qwen-executor", "tests/test_qwen_executor.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
        importEntry("qwen3_executor", "src/core/qwen3_executor.sig"),
    });
    _ = try addContract(ctx, test_qwen, "contract-inference-session", "tests/test_inference_session_contract.sig", &.{
        importEntry("inference_session", "src/core/inference_session.sig"),
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("qwen3_executor", "src/core/qwen3_executor.sig"),
        importEntry("kv_cache", "src/core/kv_cache.sig"),
    });
    _ = try ctx.addCompileStep(.{
        .source_path = "tools/probe_qwen.sig",
        .output_name = "probe-qwen",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .compiler_path = "",
        .imports = &.{
            importEntry("gguf", "src/core/gguf.sig"),
            importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
            importEntry("qwen3_executor", "src/core/qwen3_executor.sig"),
            importEntry("tokenizer", "src/core/tokenizer.sig"),
            importEntry("tokenizer_index", "src/core/tokenizer_index.sig"),
            importEntry("sig_process", process_source),
            importEntry("sha256", "src/core/sha256.sig"),
        },
    });
    _ = try addTest(ctx, test_all, "test-gguf", "src/core/gguf.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"), importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-gguf-file", "src/core/gguf_file.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
    });
    _ = try addTest(ctx, test_all, "test-sampling", "src/core/sampling.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    _ = try addTest(ctx, test_all, "test-kv-cache", "src/core/kv_cache.sig", &.{});
    _ = try addTest(ctx, test_all, "test-tokenizer-index", "src/core/tokenizer_index.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tokenizer", "src/core/tokenizer.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("tokenizer_index", "src/core/tokenizer_index.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen35-plan", "src/core/qwen35_plan.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen35-gdn", "src/core/qwen35_gdn.sig", &.{
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen3-plan", "src/core/qwen3_decoder_plan.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen3-executor", "src/core/qwen3_executor.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("transformer_ops", "src/core/transformer_ops.sig"),
    });
    _ = try addTest(ctx, test_all, "test-inference-session", "src/core/inference_session.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
        importEntry("sig_mem", "src/core/sig_mem.sig"),
        importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
        importEntry("qwen3_executor", "src/core/qwen3_executor.sig"),
        importEntry("tokenizer", "src/core/tokenizer.sig"),
        importEntry("sampling", "src/core/sampling.sig"),
        importEntry("kv_cache", "src/core/kv_cache.sig"),
        importEntry("tokenizer_index", "src/core/tokenizer_index.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("transformer_ops", "src/core/transformer_ops.sig"),
    });

    // ── Qwen3-TTS-12Hz-0.6B native speech synthesis (Layer 0 — pure, fixed
    //    storage). Text -> Talker/predictor acoustic codes -> RVQ + sliding
    //    transformer -> ConvNeXt/SnakeBeta vocoder -> 24 kHz PCM. Consumes the
    //    SB0M model container plus quantized_linear + transformer_ops. ──
    _ = try ctx.addModule("tts_model_container", "src/tts/model_container.sig");
    _ = try ctx.addModule("tts_talker_plan", "src/tts/talker_plan.sig");

    // Optional cuBLAS-resident weight cache (imports ../matmul/cuda.sig by
    // relative path). Consumed by both tensor backends; degrades to a no-op
    // when there is no CUDA device.
    _ = try ctx.addModule("matmul_cuda", "src/matmul/cuda.sig");
    // qwen35 GPU dequant kernels — registered after matmul_cuda so its import
    // interns the existing module rather than pre-registering a duplicate.
    const qwen35_kernels = try ctx.addModule("qwen35_kernels", "src/core/qwen35_kernels.sig");
    try wire(ctx, qwen35_kernels, "matmul_cuda", "src/matmul/cuda.sig");
    try wire(ctx, qwen35_kernels, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, qwen35_kernels, "qwen35_gdn", "src/core/qwen35_gdn.sig");
    _ = try addTest(ctx, test_all, "test-qwen35-kernels", "src/core/qwen35_kernels.sig", &.{
        importEntry("matmul_cuda", "src/matmul/cuda.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("qwen35_gdn", "src/core/qwen35_gdn.sig"),
    });
    _ = try ctx.addCompileStep(.{
        .source_path = "tools/probe_qwen35_dequant.sig",
        .output_name = "probe-qwen35-dequant",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .compiler_path = "",
        .imports = &.{
            importEntry("gguf", "src/core/gguf.sig"),
            importEntry("qwen35_kernels", "src/core/qwen35_kernels.sig"),
            importEntry("matmul_cuda", "src/matmul/cuda.sig"),
            importEntry("qwen35_gdn", "src/core/qwen35_gdn.sig"),
            importEntry("sig_process", process_source),
        },
    });
    const tts_gpu = try ctx.addModule("tts_gpu", "src/tts/gpu.sig");
    try wire(ctx, tts_gpu, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_gpu, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, tts_gpu, "matmul_cuda", "src/matmul/cuda.sig");

    const tts_talker_native_plan = try ctx.addModule("tts_talker_native_plan", "src/tts/talker_native_plan.sig");
    try wire(ctx, tts_talker_native_plan, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_talker_native_plan, "tts_talker_plan", "src/tts/talker_plan.sig");

    const tts_talker_backend = try ctx.addModule("tts_talker_backend", "src/tts/talker_backend.sig");
    try wire(ctx, tts_talker_backend, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_talker_backend, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, tts_talker_backend, "tts_gpu", "src/tts/gpu.sig");

    const tts_talker_executor = try ctx.addModule("tts_talker_executor", "src/tts/talker_executor.sig");
    try wire(ctx, tts_talker_executor, "tts_talker_plan", "src/tts/talker_plan.sig");
    try wire(ctx, tts_talker_executor, "tts_talker_backend", "src/tts/talker_backend.sig");
    try wire(ctx, tts_talker_executor, "transformer_ops", "src/core/transformer_ops.sig");

    const tts_sampler = try ctx.addModule("tts_sampler", "src/tts/sampler.sig");
    try wire(ctx, tts_sampler, "tts_talker_plan", "src/tts/talker_plan.sig");

    const tts_synth = try ctx.addModule("tts_synth", "src/tts/synth.sig");
    try wire(ctx, tts_synth, "tts_talker_plan", "src/tts/talker_plan.sig");
    try wire(ctx, tts_synth, "tts_talker_backend", "src/tts/talker_backend.sig");
    try wire(ctx, tts_synth, "tts_talker_executor", "src/tts/talker_executor.sig");
    try wire(ctx, tts_synth, "tts_sampler", "src/tts/sampler.sig");

    const tts_codec_plan = try ctx.addModule("tts_codec_plan", "src/tts/codec_plan.sig");
    try wire(ctx, tts_codec_plan, "tts_model_container", "src/tts/model_container.sig");

    const tts_codec_backend = try ctx.addModule("tts_codec_backend", "src/tts/codec_backend.sig");
    try wire(ctx, tts_codec_backend, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_codec_backend, "quantized_linear", "src/core/quantized_linear.sig");
    try wire(ctx, tts_codec_backend, "tts_gpu", "src/tts/gpu.sig");

    const tts_codec_transformer = try ctx.addModule("tts_codec_transformer", "src/tts/codec_transformer.sig");
    try wire(ctx, tts_codec_transformer, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_codec_transformer, "tts_codec_plan", "src/tts/codec_plan.sig");
    try wire(ctx, tts_codec_transformer, "tts_codec_backend", "src/tts/codec_backend.sig");

    const tts_vocoder = try ctx.addModule("tts_vocoder", "src/tts/vocoder.sig");
    try wire(ctx, tts_vocoder, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_vocoder, "tts_codec_plan", "src/tts/codec_plan.sig");
    try wire(ctx, tts_vocoder, "tts_codec_backend", "src/tts/codec_backend.sig");

    const tts_codec = try ctx.addModule("tts_codec", "src/tts/codec.sig");
    try wire(ctx, tts_codec, "tts_model_container", "src/tts/model_container.sig");
    try wire(ctx, tts_codec, "tts_codec_plan", "src/tts/codec_plan.sig");
    try wire(ctx, tts_codec, "tts_codec_transformer", "src/tts/codec_transformer.sig");
    try wire(ctx, tts_codec, "tts_vocoder", "src/tts/vocoder.sig");

    const tts = try ctx.addModule("tts", "src/tts/root.sig");
    inline for (.{
        .{ "tts_model_container", "src/tts/model_container.sig" },
        .{ "tts_talker_plan", "src/tts/talker_plan.sig" },
        .{ "tts_talker_native_plan", "src/tts/talker_native_plan.sig" },
        .{ "tts_talker_backend", "src/tts/talker_backend.sig" },
        .{ "tts_talker_executor", "src/tts/talker_executor.sig" },
        .{ "tts_sampler", "src/tts/sampler.sig" },
        .{ "tts_synth", "src/tts/synth.sig" },
        .{ "tts_codec_plan", "src/tts/codec_plan.sig" },
        .{ "tts_codec_backend", "src/tts/codec_backend.sig" },
        .{ "tts_codec_transformer", "src/tts/codec_transformer.sig" },
        .{ "tts_vocoder", "src/tts/vocoder.sig" },
        .{ "tts_codec", "src/tts/codec.sig" },
    }) |pair| try wire(ctx, tts, pair[0], pair[1]);

    // Per-module TTS tests. Each root seeds its direct imports; the runner
    // walks each registered module's own wired imports transitively.
    _ = try addTest(ctx, test_all, "test-tts-model-container", "src/tts/model_container.sig", &.{});
    _ = try addTest(ctx, test_all, "test-tts-talker-plan", "src/tts/talker_plan.sig", &.{});
    _ = try addTest(ctx, test_all, "test-tts-talker-native-plan", "src/tts/talker_native_plan.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("tts_talker_plan", "src/tts/talker_plan.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-gpu", "src/tts/gpu.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("matmul_cuda", "src/matmul/cuda.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-talker-backend", "src/tts/talker_backend.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("tts_gpu", "src/tts/gpu.sig"),
        importEntry("matmul_cuda", "src/matmul/cuda.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-talker-executor", "src/tts/talker_executor.sig", &.{
        importEntry("tts_talker_plan", "src/tts/talker_plan.sig"),
        importEntry("tts_talker_backend", "src/tts/talker_backend.sig"),
        importEntry("transformer_ops", "src/core/transformer_ops.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-sampler", "src/tts/sampler.sig", &.{
        importEntry("tts_talker_plan", "src/tts/talker_plan.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-synth", "src/tts/synth.sig", &.{
        importEntry("tts_talker_plan", "src/tts/talker_plan.sig"),
        importEntry("tts_talker_backend", "src/tts/talker_backend.sig"),
        importEntry("tts_talker_executor", "src/tts/talker_executor.sig"),
        importEntry("tts_sampler", "src/tts/sampler.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-codec-plan", "src/tts/codec_plan.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-codec-backend", "src/tts/codec_backend.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("tts_gpu", "src/tts/gpu.sig"),
        importEntry("matmul_cuda", "src/matmul/cuda.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-codec-transformer", "src/tts/codec_transformer.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("tts_codec_plan", "src/tts/codec_plan.sig"),
        importEntry("tts_codec_backend", "src/tts/codec_backend.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-vocoder", "src/tts/vocoder.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("tts_codec_plan", "src/tts/codec_plan.sig"),
        importEntry("tts_codec_backend", "src/tts/codec_backend.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tts-codec", "src/tts/codec.sig", &.{
        importEntry("tts_model_container", "src/tts/model_container.sig"),
        importEntry("tts_codec_plan", "src/tts/codec_plan.sig"),
        importEntry("tts_codec_transformer", "src/tts/codec_transformer.sig"),
        importEntry("tts_vocoder", "src/tts/vocoder.sig"),
    });

    // ── LSP modules (Layer 0 — reusable Language Server Protocol building
    //    blocks; pure, no allocator, no runtime std I/O). Registered under the
    //    import names the modules use so the runner resolves the transitive
    //    closure; a coarse `lsp` module re-exports them all. ──
    _ = try ctx.addModule("jwrite", "src/lsp/jwrite.sig");
    _ = try ctx.addModule("document", "src/lsp/document.sig");
    _ = try ctx.addModule("position", "src/lsp/position.sig");
    _ = try ctx.addModule("symbols", "src/lsp/symbols.sig");
    const lsp_message = try ctx.addModule("message", "src/lsp/message.sig");
    try wire(ctx, lsp_message, "json", "src/core/json.sig");
    const lsp_server = try ctx.addModule("server", "src/lsp/server.sig");
    try wire(ctx, lsp_server, "json", "src/core/json.sig");
    try wire(ctx, lsp_server, "message", "src/lsp/message.sig");
    try wire(ctx, lsp_server, "jwrite", "src/lsp/jwrite.sig");
    try wire(ctx, lsp_server, "document", "src/lsp/document.sig");
    try wire(ctx, lsp_server, "position", "src/lsp/position.sig");
    try wire(ctx, lsp_server, "symbols", "src/lsp/symbols.sig");
    const lsp_loop = try ctx.addModule("loop", "src/lsp/loop.sig");
    try wire(ctx, lsp_loop, "message", "src/lsp/message.sig");
    try wire(ctx, lsp_loop, "server", "src/lsp/server.sig");
    const lsp = try ctx.addModule("lsp", "src/lsp/root.sig");
    try wire(ctx, lsp, "message", "src/lsp/message.sig");
    try wire(ctx, lsp, "jwrite", "src/lsp/jwrite.sig");
    try wire(ctx, lsp, "document", "src/lsp/document.sig");
    try wire(ctx, lsp, "position", "src/lsp/position.sig");
    try wire(ctx, lsp, "symbols", "src/lsp/symbols.sig");
    try wire(ctx, lsp, "server", "src/lsp/server.sig");
    try wire(ctx, lsp, "loop", "src/lsp/loop.sig");

    // LSP module tests. Each test root seeds its direct imports; the runner
    // walks each registered module's own wired imports transitively.
    _ = try addTest(ctx, test_all, "test-lsp-jwrite", "src/lsp/jwrite.sig", &.{});
    _ = try addTest(ctx, test_all, "test-lsp-document", "src/lsp/document.sig", &.{});
    _ = try addTest(ctx, test_all, "test-lsp-position", "src/lsp/position.sig", &.{});
    _ = try addTest(ctx, test_all, "test-lsp-symbols", "src/lsp/symbols.sig", &.{});
    _ = try addTest(ctx, test_all, "test-lsp-message", "src/lsp/message.sig", &.{
        importEntry("json", "src/core/json.sig"),
    });
    _ = try addTest(ctx, test_all, "test-lsp-server", "src/lsp/server.sig", &.{
        importEntry("json", "src/core/json.sig"),
        importEntry("message", "src/lsp/message.sig"),
        importEntry("jwrite", "src/lsp/jwrite.sig"),
        importEntry("document", "src/lsp/document.sig"),
        importEntry("position", "src/lsp/position.sig"),
        importEntry("symbols", "src/lsp/symbols.sig"),
    });

    // Platform modules used by the portable and transport layers. The native
    // build host selects the same source split as the transitional graph.
    // (win32 / win32_path are registered up in the crypto block so the TLS
    // client's early test import interns the same canonical module.)
    // tls_client needs win32 for its Winsock transport.
    try wire(ctx, tls_client, "win32", win32_path);
    _ = try ctx.addModule("gl", "src/platform/gl.sig");

    // ── Network modules (Layer 0: pure computation, freestanding) ──
    _ = try ctx.addModule("net_checksum", "src/net/checksum.sig");
    _ = try ctx.addModule("net_ethernet", "src/net/ethernet.sig");
    _ = try ctx.addModule("net_interface", "src/net/interface.sig");

    const net_ipv4 = try ctx.addModule("net_ipv4", "src/net/ipv4.sig");
    try wire(ctx, net_ipv4, "net_checksum", "src/net/checksum.sig");

    const net_arp = try ctx.addModule("net_arp", "src/net/arp.sig");
    try wire(ctx, net_arp, "net_ethernet", "src/net/ethernet.sig");
    try wire(ctx, net_arp, "net_interface", "src/net/interface.sig");

    const net_icmp = try ctx.addModule("net_icmp", "src/net/icmp.sig");
    try wire(ctx, net_icmp, "net_checksum", "src/net/checksum.sig");
    try wire(ctx, net_icmp, "net_ipv4", "src/net/ipv4.sig");

    const net_udp = try ctx.addModule("net_udp", "src/net/udp.sig");
    try wire(ctx, net_udp, "net_checksum", "src/net/checksum.sig");
    try wire(ctx, net_udp, "net_ipv4", "src/net/ipv4.sig");

    const net_tcp = try ctx.addModule("net_tcp", "src/net/tcp.sig");
    try wire(ctx, net_tcp, "net_checksum", "src/net/checksum.sig");
    try wire(ctx, net_tcp, "net_ipv4", "src/net/ipv4.sig");

    const net_dhcp = try ctx.addModule("net_dhcp", "src/net/dhcp.sig");
    try wire(ctx, net_dhcp, "net_ethernet", "src/net/ethernet.sig");
    try wire(ctx, net_dhcp, "net_ipv4", "src/net/ipv4.sig");
    try wire(ctx, net_dhcp, "net_udp", "src/net/udp.sig");
    try wire(ctx, net_dhcp, "net_checksum", "src/net/checksum.sig");

    const net_dns = try ctx.addModule("net_dns", "src/net/dns.sig");
    try wire(ctx, net_dns, "net_udp", "src/net/udp.sig");
    try wire(ctx, net_dns, "net_ipv4", "src/net/ipv4.sig");

    const net_http = try ctx.addModule("net_http", "src/net/http.sig");
    try wire(ctx, net_http, "net_tcp", "src/net/tcp.sig");

    // Net module tests — each module tested individually with its own imports resolved
    _ = try addTest(ctx, test_all, "test-net-checksum", "src/net/checksum.sig", &.{});
    _ = try addTest(ctx, test_all, "test-net-ethernet", "src/net/ethernet.sig", &.{});
    _ = try addTest(ctx, test_all, "test-net-ipv4", "src/net/ipv4.sig", &.{
        importEntry("net_checksum", "src/net/checksum.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-arp", "src/net/arp.sig", &.{
        importEntry("net_ethernet", "src/net/ethernet.sig"),
        importEntry("net_interface", "src/net/interface.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-icmp", "src/net/icmp.sig", &.{
        importEntry("net_checksum", "src/net/checksum.sig"),
        importEntry("net_ipv4", "src/net/ipv4.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-udp", "src/net/udp.sig", &.{
        importEntry("net_checksum", "src/net/checksum.sig"),
        importEntry("net_ipv4", "src/net/ipv4.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-tcp", "src/net/tcp.sig", &.{
        importEntry("net_checksum", "src/net/checksum.sig"),
        importEntry("net_ipv4", "src/net/ipv4.sig"),
    });
    const window = try ctx.addModule("window", "src/platform/window.sig");
    try wire(ctx, window, "win32", win32_path);
    try wire(ctx, window, "gl", "src/platform/gl.sig");
    const timer = try ctx.addModule("timer", "src/platform/timer.sig");
    try wire(ctx, timer, "win32", win32_path);
    const seqlock = try ctx.addModule("seqlock", "src/platform/seqlock.sig");
    try wire(ctx, seqlock, "win32", win32_path);
    const http = try ctx.addModule("http", "src/platform/http.sig");
    try wire(ctx, http, "win32", win32_path);
    const crypto = try ctx.addModule("crypto", "src/platform/crypto.sig");
    try wire(ctx, crypto, "win32", win32_path);
    const file_io = try ctx.addModule("file_io", "src/platform/file.sig");
    try wire(ctx, file_io, "win32", win32_path);
    const threading = try ctx.addModule("threading", "src/platform/thread/run.sig");
    try wire(ctx, threading, "win32", win32_path);
    const logging = try ctx.addModule("logging", "src/platform/log/run.sig");
    try wire(ctx, logging, "win32", win32_path);
    try wire(ctx, logging, "core", "src/core/root.sig");
    const input = try ctx.addModule("input", "src/platform/input/run.sig");
    try wire(ctx, input, "win32", win32_path);
    try wire(ctx, input, "gl", "src/platform/gl.sig");
    try wire(ctx, input, "logging", "src/platform/log/run.sig");
    try wire(ctx, input, "core", "src/core/root.sig");
    const png = try ctx.addModule("png", "src/platform/png/encode.sig");
    try wire(ctx, png, "win32", win32_path);
    try wire(ctx, png, "gl", "src/platform/gl.sig");
    try wire(ctx, png, "logging", "src/platform/log/run.sig");
    const screenshot = try ctx.addModule("screenshot", "src/platform/screenshot.sig");
    try wire(ctx, screenshot, "png", "src/platform/png/encode.sig");
    const mcp = try ctx.addModule("mcp", "src/platform/mcp/run.sig");
    try wire(ctx, mcp, "win32", win32_path);
    try wire(ctx, mcp, "json", "src/core/json.sig");
    try wire(ctx, mcp, "core", "src/core/root.sig");
    try wire(ctx, mcp, "seqlock", "src/platform/seqlock.sig");
    try wire(ctx, mcp, "logging", "src/platform/log/run.sig");
    try wire(ctx, mcp, "png", "src/platform/png/encode.sig");
    _ = try ctx.addModule("subprocess", "src/platform/subprocess.sig");
    _ = try addTest(ctx, test_all, "test-subprocess", "src/platform/subprocess.sig", &.{});

    // ── UI automation: pure detection engine (Layer 0) + capture/input (Layer 1) ──
    _ = try ctx.addModule("ui_detect", "src/core/ui_detect.sig");
    _ = try addTest(ctx, test_all, "test-ui-detect", "src/core/ui_detect.sig", &.{});
    const screencap = try ctx.addModule("screencap", "src/platform/screencap.sig");
    try wire(ctx, screencap, "win32", win32_path);

    // Render and aggregate modules are registered so dependency closure is
    // complete for downstream package consumers even when they are not test
    // roots in this graph.
    _ = try ctx.addModule("color", "src/render/color.sig");
    const primitives = try ctx.addModule("primitives", "src/render/primitives.sig");
    try wire(ctx, primitives, "gl", "src/platform/gl.sig");
    try wire(ctx, primitives, "color", "src/render/color.sig");
    const text = try ctx.addModule("text", "src/render/text.sig");
    try wire(ctx, text, "gl", "src/platform/gl.sig");
    try wire(ctx, text, "win32", win32_path);
    try wire(ctx, text, "color", "src/render/color.sig");
    const icon = try ctx.addModule("icon", "src/render/icon.sig");
    try wire(ctx, icon, "gl", "src/platform/gl.sig");
    try wire(ctx, icon, "win32", win32_path);
    const render = try ctx.addModule("render", "src/render/root.sig");
    try wire(ctx, render, "color", "src/render/color.sig");
    try wire(ctx, render, "primitives", "src/render/primitives.sig");
    try wire(ctx, render, "text", "src/render/text.sig");
    try wire(ctx, render, "icon", "src/render/icon.sig");

    const platform = try ctx.addModule("platform", "src/platform/root.sig");
    try wire(ctx, platform, "core", "src/core/root.sig");
    try wire(ctx, platform, "win32", win32_path);
    try wire(ctx, platform, "gl", "src/platform/gl.sig");
    try wire(ctx, platform, "window", "src/platform/window.sig");
    try wire(ctx, platform, "input", "src/platform/input/run.sig");
    try wire(ctx, platform, "timer", "src/platform/timer.sig");
    try wire(ctx, platform, "threading", "src/platform/thread/run.sig");
    try wire(ctx, platform, "http", "src/platform/http.sig");
    try wire(ctx, platform, "crypto", "src/platform/crypto.sig");
    try wire(ctx, platform, "file_io", "src/platform/file.sig");
    try wire(ctx, platform, "seqlock", "src/platform/seqlock.sig");
    try wire(ctx, platform, "screenshot", "src/platform/screenshot.sig");
    try wire(ctx, platform, "logging", "src/platform/log/run.sig");
    try wire(ctx, platform, "png", "src/platform/png/encode.sig");
    try wire(ctx, platform, "mcp", "src/platform/mcp/run.sig");
    try wire(ctx, platform, "subprocess", "src/platform/subprocess.sig");

    // QUIC transport modules.
    const udp = try ctx.addModule("udp", "src/transport/udp.sig");
    try wire(ctx, udp, "win32", win32_path);
    _ = try ctx.addModule("packet", "src/transport/packet.sig");
    const transport_crypto = try ctx.addModule("transport_crypto", "src/transport/crypto.sig");
    try wire(ctx, transport_crypto, "win32", win32_path);
    try wire(ctx, transport_crypto, "packet", "src/transport/packet.sig");
    try wire(ctx, transport_crypto, "crypto", "src/platform/crypto.sig");
    _ = try ctx.addModule("tls13", "src/transport/tls13.sig");
    const recovery = try ctx.addModule("recovery", "src/transport/recovery.sig");
    try wire(ctx, recovery, "packet", "src/transport/packet.sig");
    const streams = try ctx.addModule("streams", "src/transport/streams.sig");
    try wire(ctx, streams, "packet", "src/transport/packet.sig");
    _ = try ctx.addModule("crypto_stream", "src/transport/crypto_stream.sig");
    const datagram = try ctx.addModule("datagram", "src/transport/datagram.sig");
    try wire(ctx, datagram, "packet", "src/transport/packet.sig");
    _ = try ctx.addModule("telemetry", "src/transport/telemetry.sig");
    const conn = try ctx.addModule("conn", "src/transport/conn.sig");
    try wire(ctx, conn, "win32", win32_path);
    try wire(ctx, conn, "packet", "src/transport/packet.sig");
    try wire(ctx, conn, "transport_crypto", "src/transport/crypto.sig");
    try wire(ctx, conn, "recovery", "src/transport/recovery.sig");
    try wire(ctx, conn, "streams", "src/transport/streams.sig");
    try wire(ctx, conn, "datagram", "src/transport/datagram.sig");
    try wire(ctx, conn, "telemetry", "src/transport/telemetry.sig");
    try wire(ctx, conn, "udp", "src/transport/udp.sig");
    try wire(ctx, conn, "crypto_stream", "src/transport/crypto_stream.sig");
    const scheduler = try ctx.addModule("scheduler", "src/transport/scheduler.sig");
    try wire(ctx, scheduler, "win32", win32_path);
    try wire(ctx, scheduler, "packet", "src/transport/packet.sig");
    try wire(ctx, scheduler, "streams", "src/transport/streams.sig");
    try wire(ctx, scheduler, "datagram", "src/transport/datagram.sig");
    try wire(ctx, scheduler, "recovery", "src/transport/recovery.sig");
    try wire(ctx, scheduler, "transport_crypto", "src/transport/crypto.sig");
    try wire(ctx, scheduler, "udp", "src/transport/udp.sig");
    try wire(ctx, scheduler, "telemetry", "src/transport/telemetry.sig");
    const appmap = try ctx.addModule("appmap", "src/transport/appmap.sig");
    try wire(ctx, appmap, "streams", "src/transport/streams.sig");
    try wire(ctx, appmap, "datagram", "src/transport/datagram.sig");
    try wire(ctx, appmap, "packet", "src/transport/packet.sig");
    _ = try ctx.addModule("h3", "src/transport/h3.sig");
    const h3_server = try ctx.addModule("h3_server", "src/transport/server.sig");
    try wire(ctx, h3_server, "conn", "src/transport/conn.sig");
    try wire(ctx, h3_server, "packet", "src/transport/packet.sig");
    try wire(ctx, h3_server, "streams", "src/transport/streams.sig");
    try wire(ctx, h3_server, "udp", "src/transport/udp.sig");
    try wire(ctx, h3_server, "h3", "src/transport/h3.sig");
    try wire(ctx, h3_server, "telemetry", "src/transport/telemetry.sig");
    const transport = try ctx.addModule("transport", "src/transport/root.sig");
    try wire(ctx, transport, "udp", "src/transport/udp.sig");
    try wire(ctx, transport, "packet", "src/transport/packet.sig");
    try wire(ctx, transport, "transport_crypto", "src/transport/crypto.sig");
    try wire(ctx, transport, "crypto_stream", "src/transport/crypto_stream.sig");
    try wire(ctx, transport, "recovery", "src/transport/recovery.sig");
    try wire(ctx, transport, "streams", "src/transport/streams.sig");
    try wire(ctx, transport, "datagram", "src/transport/datagram.sig");
    try wire(ctx, transport, "scheduler", "src/transport/scheduler.sig");
    try wire(ctx, transport, "conn", "src/transport/conn.sig");
    try wire(ctx, transport, "telemetry", "src/transport/telemetry.sig");
    try wire(ctx, transport, "appmap", "src/transport/appmap.sig");
    try wire(ctx, transport, "h3", "src/transport/h3.sig");
    try wire(ctx, transport, "h3_server", "src/transport/server.sig");

    _ = try addTest(ctx, test_all, "test-udp", "src/transport/udp.sig", &.{importEntry("win32", win32_path)});
    _ = try addTest(ctx, test_all, "test-packet", "src/transport/packet.sig", &.{});
    _ = try addTest(ctx, test_all, "test-transport-crypto", "src/transport/crypto.sig", &.{
        importEntry("win32", win32_path),
        importEntry("packet", "src/transport/packet.sig"),
        importEntry("crypto", "src/platform/crypto.sig"),
    });
    _ = try addTest(ctx, test_all, "test-recovery", "src/transport/recovery.sig", &.{importEntry("packet", "src/transport/packet.sig")});
    _ = try addTest(ctx, test_all, "test-streams", "src/transport/streams.sig", &.{importEntry("packet", "src/transport/packet.sig")});
    _ = try addTest(ctx, test_all, "test-datagram", "src/transport/datagram.sig", &.{importEntry("packet", "src/transport/packet.sig")});
    _ = try addTest(ctx, test_all, "test-telemetry", "src/transport/telemetry.sig", &.{});
    _ = try addTest(ctx, test_all, "test-conn", "src/transport/conn.sig", &.{
        importEntry("win32", win32_path),                                importEntry("packet", "src/transport/packet.sig"),
        importEntry("transport_crypto", "src/transport/crypto.sig"),     importEntry("recovery", "src/transport/recovery.sig"),
        importEntry("streams", "src/transport/streams.sig"),             importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("telemetry", "src/transport/telemetry.sig"),         importEntry("udp", "src/transport/udp.sig"),
        importEntry("crypto_stream", "src/transport/crypto_stream.sig"),
    });
    _ = try addTest(ctx, test_all, "test-scheduler", "src/transport/scheduler.sig", &.{
        importEntry("win32", win32_path),                      importEntry("packet", "src/transport/packet.sig"),
        importEntry("streams", "src/transport/streams.sig"),   importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("recovery", "src/transport/recovery.sig"), importEntry("transport_crypto", "src/transport/crypto.sig"),
        importEntry("udp", "src/transport/udp.sig"),           importEntry("telemetry", "src/transport/telemetry.sig"),
    });
    _ = try addTest(ctx, test_all, "test-appmap", "src/transport/appmap.sig", &.{
        importEntry("streams", "src/transport/streams.sig"),
        importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("packet", "src/transport/packet.sig"),
    });
    _ = try addTest(ctx, test_all, "test-h3", "src/transport/h3.sig", &.{});
    _ = try addTest(ctx, test_all, "test-h3-server", "src/transport/server.sig", &.{
        importEntry("conn", "src/transport/conn.sig"),       importEntry("packet", "src/transport/packet.sig"),
        importEntry("streams", "src/transport/streams.sig"), importEntry("udp", "src/transport/udp.sig"),
        importEntry("h3", "src/transport/h3.sig"),           importEntry("telemetry", "src/transport/telemetry.sig"),
    });

    _ = try addTest(ctx, test_all, "test-no-alloc", "src/transport/no_alloc_test.sig", &.{});
    _ = try addTest(ctx, test_all, "test-comptime-sizes", "src/transport/comptime_sizes_test.sig", &.{});
    _ = try addTest(ctx, test_all, "test-layer", "src/transport/layer_test.sig", &.{});
    _ = try addTest(ctx, test_all, "test-domain-agnostic", "src/transport/domain_agnostic_test.sig", &.{});
    _ = try ctx.addModule("build_embed", "build_embed.sig");
    _ = try addTest(ctx, test_all, "test-shared-source", "src/transport/shared_source_test.sig", &.{
        importEntry("build_embed", "build_embed.sig"),
    });

    // Network integration tests remain explicit because they exercise sockets
    // rather than deterministic package units.
    _ = try ctx.addTestStep(.{
        .name = "test-integration",
        .source_path = "src/transport/integration_test.sig",
        .imports = &.{
            importEntry("conn", "src/transport/conn.sig"),         importEntry("telemetry", "src/transport/telemetry.sig"),
            importEntry("streams", "src/transport/streams.sig"),   importEntry("transport_crypto", "src/transport/crypto.sig"),
            importEntry("packet", "src/transport/packet.sig"),     importEntry("recovery", "src/transport/recovery.sig"),
            importEntry("datagram", "src/transport/datagram.sig"), importEntry("udp", "src/transport/udp.sig"),
            importEntry("win32", win32_path),                      importEntry("appmap", "src/transport/appmap.sig"),
        },
    });
    _ = try ctx.addTestStep(.{
        .name = "test-server-initial",
        .source_path = "src/transport/server_initial_test.sig",
        .imports = &.{
            importEntry("conn", "src/transport/conn.sig"),       importEntry("telemetry", "src/transport/telemetry.sig"),
            importEntry("streams", "src/transport/streams.sig"), importEntry("transport_crypto", "src/transport/crypto.sig"),
            importEntry("packet", "src/transport/packet.sig"),   importEntry("datagram", "src/transport/datagram.sig"),
            importEntry("udp", "src/transport/udp.sig"),         importEntry("win32", win32_path),
        },
    });
}
