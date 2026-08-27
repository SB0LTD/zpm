# zpm/src/core/ — Core Computation Modules (Layer 0)

Zero-allocation, freestanding-compatible modules for pure computation. No OS dependencies. Usable in bare-metal kernels, build tools, and userspace applications.

## AI Inference Stack

Complete native LLM inference pipeline. Runs Qwen3 models from GGUF files with zero heap allocation.

```
inference_session.sig  ← High-level API (start here)
    ├── gguf.sig             ← GGUF v3 container parser
    ├── qwen3_decoder_plan.sig ← Architecture schema binder
    ├── qwen3_executor.sig   ← Full forward pass
    │       ├── quantized_linear.sig ← SIMD Q4_K/Q6_K/SB0-Q4 kernels
    │       └── transformer_ops.sig  ← RMSNorm, RoPE, softmax, SiLU, attention
    ├── tokenizer.sig        ← BPE encode/decode with chat template
    │       └── tokenizer_index.sig ← Vocabulary + merge hash index
    ├── sampling.sig         ← Temperature, top-k/p, repetition penalty
    └── kv_cache.sig         ← Dynamic KV cache (AllocFn interface)
```

### Usage

```sig
const session = @import("inference_session.sig");
const kv_cache = @import("kv_cache.sig");

// Initialize session from GGUF model file
var s = try session.Session.init(myAllocFn, model_source, .{ .max_context = 2048 });

// Generate text (streaming)
var iter = try s.generate("What is the capital of France?", .{});
while (iter.next()) |token| {
    writeOutput(token.bytes);
}

// Or single-shot
var buf: [4096]u8 = undefined;
const len = try session.generateComplete(&s, "Hello", .{}, &buf);
```

### Supported Models
- Qwen3-0.6B (Q4_K, Q6_K) — tested, ~2s/token on ARM64
- Qwen3-1.7B, Qwen3-4B — supported via configurable limits

### Quantization Formats
- **Q4_K** (GGML type 12): 256-element blocks, 8-wide SIMD
- **Q6_K** (GGML type 14): 256-element blocks, 8-wide SIMD
- **SB0-Q4** (custom): 32-element blocks, 32-wide SIMD
- **F32/F16**: Full precision (for embeddings and norms)

## Other Core Modules

| Module | Purpose |
|--------|---------|
| `math.sig` | Trigonometry, linear algebra primitives |
| `json.sig` | Zero-allocation JSON parser |
| `sha256.sig` | SHA-256 hash (FIPS 180-4) |
| `ai_core.sig` | Runtime infra (arena, scheduler, capacity planner) |
| `quantized_linear.sig` | SIMD matmul kernels |
| `transformer_ops.sig` | Transformer layer operations |
| `vector_memory.sig` | Embedding search |
| `agent_runtime.sig` | Agent loop framework |

## Testing

Each module has inline `test` blocks. Run via the build system:

```
sig build test-net-checksum --zig-lib-dir <lib>
```

Tests use no `std.testing` (freestanding). Error return = test failure.

## Design Principles

1. **Zero allocation** — all buffers caller-owned or comptime-sized
2. **Freestanding** — no OS imports, compiles for any target
3. **Relative imports** — `@import("file.sig")` for cross-module deps
4. **Inline tests** — each module self-tests without external test harness
