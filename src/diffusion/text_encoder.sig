// @zpm/diffusion — Prompt conditioning.
//
// Turns a prompt string into the conditioning token embeddings the denoiser
// cross-attends to. Qwen-Image conditions on a Qwen3-VL text encoder; that
// encoder is itself a transformer that the existing src/llm stack can run once
// the encoder weights are loaded. To keep this module dependency-light and
// deterministic, it exposes the conditioning *contract* (a fixed-width token
// buffer) plus a reproducible fallback embedding derived from the prompt bytes,
// so the pipeline is exercisable end-to-end before the 8B encoder is wired in.

const math = @import("sig_math");

pub const MAX_CONTEXT_TOKENS: usize = 512;

pub const Conditioning = struct {
    /// context[t*dim .. t*dim+dim] is the embedding of conditioning token t.
    context: [*]f32,
    n_tokens: usize,
    dim: usize,
};

/// Deterministic, prompt-derived conditioning used until the Qwen3-VL encoder
/// weights are wired. Fills `out` (n_tokens*dim floats) with a smooth,
/// prompt-seeded field so different prompts yield different — and reproducible
/// — generations. Replace `encode` internals with a real transformer forward
/// once the encoder weights load; the contract (this buffer) stays identical.
pub fn encodeFallback(prompt: []const u8, out: []f32, n_tokens: usize, dim: usize) Conditioning {
    var h: u64 = 1469598103934665603; // FNV-1a
    for (prompt) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    var t: usize = 0;
    while (t < n_tokens) : (t += 1) {
        var d: usize = 0;
        while (d < dim) : (d += 1) {
            const k: u64 = h ^ (@as(u64, t) *% 0x9E3779B97F4A7C15) ^ (@as(u64, d) *% 0xC2B2AE3D27D4EB4F);
            const u = @as(f32, @floatFromInt(k >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
            out[t * dim + d] = (u - 0.5) * 0.1;
        }
    }
    return .{ .context = out.ptr, .n_tokens = n_tokens, .dim = dim };
}

/// Empty/negative conditioning for classifier-free guidance (all zeros).
pub fn encodeEmpty(out: []f32, n_tokens: usize, dim: usize) Conditioning {
    for (out[0 .. n_tokens * dim]) |*v| v.* = 0;
    return .{ .context = out.ptr, .n_tokens = n_tokens, .dim = dim };
}

test "fallback conditioning is prompt-deterministic and bounded" {
    const std = @import("std");
    var a: [8 * 4]f32 = undefined;
    var b: [8 * 4]f32 = undefined;
    _ = encodeFallback("fox", &a, 8, 4);
    _ = encodeFallback("fox", &b, 8, 4);
    for (a, b) |x, y| try std.testing.expectEqual(x, y); // reproducible
    var c: [8 * 4]f32 = undefined;
    _ = encodeFallback("cat", &c, 8, 4);
    var differ = false;
    for (a, c) |x, y| if (x != y) {
        differ = true;
    };
    try std.testing.expect(differ); // different prompt → different field
    for (a) |x| try std.testing.expect(math.absF(x) <= 0.05);
}
