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

pub fn build(ctx: *sig_build.Build_Context) !void {
    const test_all = try ctx.addStep("test", "Run all ZPM unit and compliance tests", &noopStep);

    // Core modules.
    _ = try ctx.addModule("math", "src/core/math.sig");
    _ = try ctx.addModule("sig_math", "src/core/sig_math.sig");
    const synth_voice = try ctx.addModule("synth_voice", "src/core/synth_voice.sig");
    try wire(ctx, synth_voice, "math", "src/core/math.sig");
    try wire(ctx, synth_voice, "sig_math", "src/core/sig_math.sig");
    _ = try ctx.addModule("json", "src/core/json.sig");
    _ = try ctx.addModule("sha256", "src/core/sha256.sig");
    _ = try ctx.addModule("inflate", "src/core/inflate.sig");

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
    const jsonl = try ctx.addModule("jsonl", "src/core/jsonl.sig");
    try wire(ctx, jsonl, "json", "src/core/json.sig");
    _ = try ctx.addModule("ai_core", "src/core/ai_core.sig");
    _ = try ctx.addModule("quantized_linear", "src/core/quantized_linear.sig");
    _ = try ctx.addModule("transformer_ops", "src/core/transformer_ops.sig");
    _ = try ctx.addModule("audio_dsp", "src/core/audio_dsp.sig");
    _ = try ctx.addModule("vector_memory", "src/core/vector_memory.sig");
    _ = try ctx.addModule("moment_activation", "src/core/moment_activation.sig");
    _ = try ctx.addModule("agent_runtime", "src/core/agent_runtime.sig");
    _ = try ctx.addModule("model_observability", "src/core/model_observability.sig");
    _ = try ctx.addModule("multimodal_now", "src/core/multimodal_now.sig");
    const cognitive_receipt = try ctx.addModule("cognitive_receipt", "src/core/cognitive_receipt.sig");
    try wire(ctx, cognitive_receipt, "vector_memory", "src/core/vector_memory.sig");
    try wire(ctx, cognitive_receipt, "moment_activation", "src/core/moment_activation.sig");
    try wire(ctx, cognitive_receipt, "agent_runtime", "src/core/agent_runtime.sig");
    try wire(ctx, cognitive_receipt, "model_observability", "src/core/model_observability.sig");
    try wire(ctx, cognitive_receipt, "multimodal_now", "src/core/multimodal_now.sig");
    const core = try ctx.addModule("core", "src/core/root.sig");
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

    _ = try addTest(ctx, test_all, "test-ai-core", "src/core/ai_core.sig", &.{});
    _ = try addTest(ctx, test_all, "test-quantized-linear", "src/core/quantized_linear.sig", &.{});
    _ = try addTest(ctx, test_all, "test-transformer-ops", "src/core/transformer_ops.sig", &.{});
    _ = try addTest(ctx, test_all, "test-audio-dsp", "src/core/audio_dsp.sig", &.{});
    _ = try addTest(ctx, test_all, "test-math", "src/core/math.sig", &.{});
    _ = try addTest(ctx, test_all, "test-sig-math", "src/core/sig_math.sig", &.{});
    _ = try addTest(ctx, test_all, "test-synth_voice", "src/core/synth_voice.sig", &.{
        importEntry("math", "src/core/math.sig"),
        importEntry("sig_math", "src/core/sig_math.sig"),
    });
    _ = try addTest(ctx, test_all, "test-vector-memory", "src/core/vector_memory.sig", &.{});
    _ = try addTest(ctx, test_all, "test-moment-activation", "src/core/moment_activation.sig", &.{});
    _ = try addTest(ctx, test_all, "test-agent-runtime", "src/core/agent_runtime.sig", &.{});
    _ = try addTest(ctx, test_all, "test-model-observability", "src/core/model_observability.sig", &.{});
    _ = try addTest(ctx, test_all, "test-multimodal-now", "src/core/multimodal_now.sig", &.{});
    _ = try addTest(ctx, test_all, "test-cognitive-receipt", "src/core/cognitive_receipt.sig", &.{
        importEntry("vector_memory", "src/core/vector_memory.sig"),
        importEntry("moment_activation", "src/core/moment_activation.sig"),
        importEntry("agent_runtime", "src/core/agent_runtime.sig"),
        importEntry("model_observability", "src/core/model_observability.sig"),
        importEntry("multimodal_now", "src/core/multimodal_now.sig"),
    });
    _ = try addTest(ctx, test_all, "test-sha256", "src/core/sha256.sig", &.{});
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
    _ = try addTest(ctx, test_all, "test-quic-keys", "src/core/crypto/quic_keys.sig", &.{
        importEntry("sha256", "src/core/sha256.sig"),
        importEntry("hmac", "src/core/crypto/hmac.sig"),
        importEntry("hkdf", "src/core/crypto/hkdf.sig"),
        importEntry("aes", "src/core/crypto/aes.sig"),
    });
    _ = try addTest(ctx, test_all, "test-inflate", "src/core/inflate.sig", &.{
        importEntry("sig_mem", "src/core/sig_mem.sig"),
    });
    _ = try addTest(ctx, test_all, "test-jsonl", "src/core/jsonl.sig", &.{
        importEntry("json", "src/core/json.sig"),
    });

    // ── Inference pipeline modules (Layer 0 — pure computation, zero platform deps) ──
    _ = try ctx.addModule("gguf", "src/core/gguf.sig");
    _ = try ctx.addModule("gguf_file", "src/core/gguf_file.sig");
    _ = try ctx.addModule("sampling", "src/core/sampling.sig");
    _ = try ctx.addModule("kv_cache", "src/core/kv_cache.sig");
    _ = try ctx.addModule("tokenizer_index", "src/core/tokenizer_index.sig");
    _ = try ctx.addModule("tokenizer", "src/core/tokenizer.sig");
    _ = try ctx.addModule("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig");
    _ = try ctx.addModule("qwen3_executor", "src/core/qwen3_executor.sig");
    _ = try ctx.addModule("inference_session", "src/core/inference_session.sig");

    // Inference pipeline tests
    _ = try addTest(ctx, test_all, "test-gguf", "src/core/gguf.sig", &.{});
    _ = try addTest(ctx, test_all, "test-gguf-file", "src/core/gguf_file.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
    });
    _ = try addTest(ctx, test_all, "test-sampling", "src/core/sampling.sig", &.{});
    _ = try addTest(ctx, test_all, "test-kv-cache", "src/core/kv_cache.sig", &.{});
    _ = try addTest(ctx, test_all, "test-tokenizer-index", "src/core/tokenizer_index.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
    });
    _ = try addTest(ctx, test_all, "test-tokenizer", "src/core/tokenizer.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("tokenizer_index", "src/core/tokenizer_index.sig"),
        importEntry("sb0_gguf_tokenizer_index", "src/core/tokenizer_index.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen3-plan", "src/core/qwen3_decoder_plan.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
    });
    _ = try addTest(ctx, test_all, "test-qwen3-executor", "src/core/qwen3_executor.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("transformer_ops", "src/core/transformer_ops.sig"),
    });
    _ = try addTest(ctx, test_all, "test-inference-session", "src/core/inference_session.sig", &.{
        importEntry("gguf", "src/core/gguf.sig"),
        importEntry("qwen3_decoder_plan", "src/core/qwen3_decoder_plan.sig"),
        importEntry("qwen3_executor", "src/core/qwen3_executor.sig"),
        importEntry("tokenizer", "src/core/tokenizer.sig"),
        importEntry("tokenizer_index", "src/core/tokenizer_index.sig"),
        importEntry("sampling", "src/core/sampling.sig"),
        importEntry("kv_cache", "src/core/kv_cache.sig"),
        importEntry("sb0_gguf_tokenizer_index", "src/core/tokenizer_index.sig"),
        importEntry("quantized_linear", "src/core/quantized_linear.sig"),
        importEntry("transformer_ops", "src/core/transformer_ops.sig"),
    });

    // Platform modules used by the portable and transport layers. The native
    // build host selects the same source split as the transitional graph.
    const win32_path = if (builtin.os.tag == .windows)
        "src/platform/win32.sig"
    else
        "src/transport/linux_platform.sig";
    _ = try ctx.addModule("win32", win32_path);
    _ = try ctx.addModule("gl", "src/platform/gl.sig");

    // ── Network modules (Layer 0: pure computation, freestanding) ──
    _ = try ctx.addModule("net_checksum", "src/net/checksum.sig");
    _ = try ctx.addModule("net_ethernet", "src/net/ethernet.sig");
    _ = try ctx.addModule("net_interface", "src/net/interface.sig");

    const net_ipv4 = try ctx.addModule("net_ipv4", "src/net/ipv4.sig");
    try wire(ctx, net_ipv4, "checksum", "src/net/checksum.sig");

    const net_arp = try ctx.addModule("net_arp", "src/net/arp.sig");
    try wire(ctx, net_arp, "ethernet", "src/net/ethernet.sig");
    try wire(ctx, net_arp, "interface", "src/net/interface.sig");

    const net_icmp = try ctx.addModule("net_icmp", "src/net/icmp.sig");
    try wire(ctx, net_icmp, "checksum", "src/net/checksum.sig");
    try wire(ctx, net_icmp, "ipv4", "src/net/ipv4.sig");

    const net_udp = try ctx.addModule("net_udp", "src/net/udp.sig");
    try wire(ctx, net_udp, "checksum", "src/net/checksum.sig");
    try wire(ctx, net_udp, "ipv4", "src/net/ipv4.sig");

    const net_tcp = try ctx.addModule("net_tcp", "src/net/tcp.sig");
    try wire(ctx, net_tcp, "checksum", "src/net/checksum.sig");
    try wire(ctx, net_tcp, "ipv4", "src/net/ipv4.sig");

    const net_dhcp = try ctx.addModule("net_dhcp", "src/net/dhcp.sig");
    try wire(ctx, net_dhcp, "ethernet", "src/net/ethernet.sig");
    try wire(ctx, net_dhcp, "ipv4", "src/net/ipv4.sig");
    try wire(ctx, net_dhcp, "net_udp", "src/net/udp.sig");
    try wire(ctx, net_dhcp, "checksum", "src/net/checksum.sig");

    const net_dns = try ctx.addModule("net_dns", "src/net/dns.sig");
    try wire(ctx, net_dns, "net_udp", "src/net/udp.sig");
    try wire(ctx, net_dns, "ipv4", "src/net/ipv4.sig");

    const net_http = try ctx.addModule("net_http", "src/net/http.sig");
    try wire(ctx, net_http, "net_tcp", "src/net/tcp.sig");

    // Net module tests — each module tested individually with its own imports resolved
    _ = try addTest(ctx, test_all, "test-net-checksum", "src/net/checksum.sig", &.{});
    _ = try addTest(ctx, test_all, "test-net-ethernet", "src/net/ethernet.sig", &.{});
    _ = try addTest(ctx, test_all, "test-net-ipv4", "src/net/ipv4.sig", &.{
        importEntry("checksum", "src/net/checksum.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-arp", "src/net/arp.sig", &.{
        importEntry("ethernet", "src/net/ethernet.sig"),
        importEntry("interface", "src/net/interface.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-icmp", "src/net/icmp.sig", &.{
        importEntry("checksum", "src/net/checksum.sig"),
        importEntry("ipv4", "src/net/ipv4.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-udp", "src/net/udp.sig", &.{
        importEntry("checksum", "src/net/checksum.sig"),
        importEntry("ipv4", "src/net/ipv4.sig"),
    });
    _ = try addTest(ctx, test_all, "test-net-tcp", "src/net/tcp.sig", &.{
        importEntry("checksum", "src/net/checksum.sig"),
        importEntry("ipv4", "src/net/ipv4.sig"),
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
        importEntry("win32", win32_path), importEntry("packet", "src/transport/packet.sig"),
        importEntry("transport_crypto", "src/transport/crypto.sig"), importEntry("recovery", "src/transport/recovery.sig"),
        importEntry("streams", "src/transport/streams.sig"), importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("telemetry", "src/transport/telemetry.sig"), importEntry("udp", "src/transport/udp.sig"),
        importEntry("crypto_stream", "src/transport/crypto_stream.sig"),
    });
    _ = try addTest(ctx, test_all, "test-scheduler", "src/transport/scheduler.sig", &.{
        importEntry("win32", win32_path), importEntry("packet", "src/transport/packet.sig"),
        importEntry("streams", "src/transport/streams.sig"), importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("recovery", "src/transport/recovery.sig"), importEntry("transport_crypto", "src/transport/crypto.sig"),
        importEntry("udp", "src/transport/udp.sig"), importEntry("telemetry", "src/transport/telemetry.sig"),
    });
    _ = try addTest(ctx, test_all, "test-appmap", "src/transport/appmap.sig", &.{
        importEntry("streams", "src/transport/streams.sig"),
        importEntry("datagram", "src/transport/datagram.sig"),
        importEntry("packet", "src/transport/packet.sig"),
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
            importEntry("conn", "src/transport/conn.sig"), importEntry("telemetry", "src/transport/telemetry.sig"),
            importEntry("streams", "src/transport/streams.sig"), importEntry("transport_crypto", "src/transport/crypto.sig"),
            importEntry("packet", "src/transport/packet.sig"), importEntry("recovery", "src/transport/recovery.sig"),
            importEntry("datagram", "src/transport/datagram.sig"), importEntry("udp", "src/transport/udp.sig"),
            importEntry("win32", win32_path), importEntry("appmap", "src/transport/appmap.sig"),
        },
    });
    _ = try ctx.addTestStep(.{
        .name = "test-server-initial",
        .source_path = "src/transport/server_initial_test.sig",
        .imports = &.{
            importEntry("conn", "src/transport/conn.sig"), importEntry("telemetry", "src/transport/telemetry.sig"),
            importEntry("streams", "src/transport/streams.sig"), importEntry("transport_crypto", "src/transport/crypto.sig"),
            importEntry("packet", "src/transport/packet.sig"), importEntry("datagram", "src/transport/datagram.sig"),
            importEntry("udp", "src/transport/udp.sig"), importEntry("win32", win32_path),
        },
    });

}
