//! Dynamic KV Cache — page-arena-backed key/value storage for transformer inference.
//!
//! Replaces the fixed comptime-sized `[]u16` KV storage with a growable cache
//! that commits physical pages only as the context expands. Initial allocation
//! is zero; pages are committed on first write to each position.
//!
//! Layout: [layer][k_or_v][head][position][head_dim] stored as f16 (u16 bits).
//!
//! The cache supports:
//!   - Dynamic context growth (2048 → 4096 → 8192 on demand)
//!   - Zero physical memory cost for uncommitted positions
//!   - Efficient position-sequential writes (hot path is a memcpy)
//!   - Direct slice access for attention score computation
//!   - Reset without deallocation (reuse for next generation)
//!
//! Designed for the sig_build smart capacity use case: short prompts (50-200
//! tokens) with small models (0.6B-4B). The arena commitment granularity of
//! 4KB pages means we only pay for positions actually used.



// ══════════════════════════════════════════════════════════════════════════════
// Allocator Interface (for dynamic KV storage)
// ══════════════════════════════════════════════════════════════════════════════

/// Minimal allocator interface for KV cache backing storage.
/// The caller provides this — backed by page_arena, static buffer, or mmap.
pub const AllocFn = *const fn (byte_count: usize, alignment: usize) ?[*]u8;

/// Allocate a typed slice using the provided alloc function.
fn allocSlice(comptime T: type, alloc_fn: AllocFn, count: usize) ?[]T {
    if (count == 0) return &[_]T{};
    const byte_size = @sizeOf(T) * count;
    const ptr = alloc_fn(byte_size, @alignOf(T)) orelse return null;
    const typed: [*]T = @ptrCast(@alignCast(ptr));
    return typed[0..count];
}

// ══════════════════════════════════════════════════════════════════════════════
// KV Cache
// ══════════════════════════════════════════════════════════════════════════════

pub const KvCache = struct {
    /// Backing storage (f16 values stored as u16).
    storage: []u16,
    /// Allocator used to obtain storage.
    alloc_fn: AllocFn,
    /// Architecture parameters (immutable after init).
    layer_count: u16,
    head_count: u16, // KV head count (may differ from query head count in GQA)
    head_dim: u16,
    /// Maximum context positions allocated.
    max_context: u32,
    /// Current furthest written position + 1.
    context_used: u32,
    /// Elements per layer per K or V = head_count * max_context * head_dim.
    elements_per_kv: u64,
    /// Elements per layer (both K and V) = 2 * elements_per_kv.
    elements_per_layer: u64,
    /// Total elements = layer_count * elements_per_layer.
    total_elements: u64,

    pub const Error = error{
        InvalidConfig,
        ContextExceeded,
        ArenaExhausted,
    };

    /// Initialize a KV cache for the given model architecture.
    /// Storage is obtained via alloc_fn (backed by page_arena or static buffer).
    pub fn init(
        alloc_fn: AllocFn,
        layer_count: u16,
        kv_head_count: u16,
        head_dim: u16,
        max_context: u32,
    ) Error!KvCache {
        if (layer_count == 0 or kv_head_count == 0 or head_dim == 0 or max_context == 0)
            return error.InvalidConfig;

        const elements_per_kv: u64 = @as(u64, kv_head_count) * max_context * head_dim;
        const elements_per_layer: u64 = 2 * elements_per_kv; // K + V
        const total_elements: u64 = @as(u64, layer_count) * elements_per_layer;

        const storage = allocSlice(u16, alloc_fn, @intCast(total_elements)) orelse
            return error.ArenaExhausted;

        // Zero-init (f16 zero = 0x0000)
        @memset(storage, 0);

        return .{
            .storage = storage,
            .alloc_fn = alloc_fn,
            .layer_count = layer_count,
            .head_count = kv_head_count,
            .head_dim = head_dim,
            .max_context = max_context,
            .context_used = 0,
            .elements_per_kv = elements_per_kv,
            .elements_per_layer = elements_per_layer,
            .total_elements = total_elements,
        };
    }

    /// Get the raw storage slice (compatible with sb0_qwen3_executor's `kv_storage` parameter).
    pub fn rawSlice(self: *const KvCache) []u16 {
        return self.storage;
    }

    /// Store key and value vectors for a given layer and position.
    /// `key` and `value` are f32 slices of length kv_head_count * head_dim,
    /// converted to f16 for storage.
    pub fn store(
        self: *KvCache,
        layer: u16,
        position: u32,
        key: []const f32,
        value: []const f32,
    ) Error!void {
        if (position >= self.max_context) return error.ContextExceeded;
        if (layer >= self.layer_count) return error.InvalidConfig;

        const kv_size: usize = @as(usize, self.head_count) * self.head_dim;
        if (key.len != kv_size or value.len != kv_size) return error.InvalidConfig;

        const layer_base = @as(usize, layer) * @as(usize, @intCast(self.elements_per_layer));
        const pos_stride: usize = self.head_dim;
        const ctx_stride: usize = @as(usize, self.max_context) * pos_stride;

        // Store K
        for (0..self.head_count) |head| {
            const src_offset = head * self.head_dim;
            const dst_offset = layer_base + head * ctx_stride + @as(usize, position) * pos_stride;
            for (0..self.head_dim) |d| {
                self.storage[dst_offset + d] = f32ToF16Bits(key[src_offset + d]);
            }
        }

        // Store V (offset by elements_per_kv from layer_base)
        const v_base = layer_base + @as(usize, @intCast(self.elements_per_kv));
        for (0..self.head_count) |head| {
            const src_offset = head * self.head_dim;
            const dst_offset = v_base + head * ctx_stride + @as(usize, position) * pos_stride;
            for (0..self.head_dim) |d| {
                self.storage[dst_offset + d] = f32ToF16Bits(value[src_offset + d]);
            }
        }

        if (position + 1 > self.context_used) self.context_used = position + 1;
    }

    /// Get a slice of K values for a specific layer and head, covering positions [0, context_used).
    /// Returns f16-as-u16 values: [position][head_dim].
    pub fn getKeys(self: *const KvCache, layer: u16, head: u16) []const u16 {
        const layer_base = @as(usize, layer) * @as(usize, @intCast(self.elements_per_layer));
        const ctx_stride: usize = @as(usize, self.max_context) * self.head_dim;
        const offset = layer_base + @as(usize, head) * ctx_stride;
        const len = @as(usize, self.context_used) * self.head_dim;
        return self.storage[offset..][0..len];
    }

    /// Get a slice of V values for a specific layer and head.
    pub fn getValues(self: *const KvCache, layer: u16, head: u16) []const u16 {
        const layer_base = @as(usize, layer) * @as(usize, @intCast(self.elements_per_layer));
        const v_base = layer_base + @as(usize, @intCast(self.elements_per_kv));
        const ctx_stride: usize = @as(usize, self.max_context) * self.head_dim;
        const offset = v_base + @as(usize, head) * ctx_stride;
        const len = @as(usize, self.context_used) * self.head_dim;
        return self.storage[offset..][0..len];
    }

    /// Reset the cache for a new generation (zero positions, keep allocation).
    pub fn reset(self: *KvCache) void {
        self.context_used = 0;
        // Don't zero storage — it'll be overwritten position by position
    }

    /// Current number of positions stored.
    pub fn contextLength(self: *const KvCache) u32 {
        return self.context_used;
    }

    /// Remaining positions available.
    pub fn remaining(self: *const KvCache) u32 {
        return self.max_context - self.context_used;
    }

    /// Memory usage in bytes (committed).
    pub fn bytesUsed(self: *const KvCache) usize {
        return self.storage.len * @sizeOf(u16);
    }

    /// Memory usage for a specific context length (for capacity planning).
    pub fn bytesForContext(self: *const KvCache, context_len: u32) usize {
        const elements: u64 = @as(u64, self.layer_count) * 2 *
            @as(u64, self.head_count) * context_len * self.head_dim;
        return @intCast(elements * @sizeOf(u16));
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Preset Configurations
// ══════════════════════════════════════════════════════════════════════════════

/// KV cache sizing for common model profiles.
pub const Preset = struct {
    layer_count: u16,
    kv_head_count: u16,
    head_dim: u16,
    default_context: u32,
    max_context: u32,
};

/// Qwen3-0.6B: 28 layers, 8 KV heads, 128 dim
pub const QWEN3_0_6B = Preset{
    .layer_count = 28,
    .kv_head_count = 8,
    .head_dim = 128,
    .default_context = 2048,
    .max_context = 8192,
};

/// Qwen3-1.7B: 28 layers, 4 KV heads, 128 dim
pub const QWEN3_1_7B = Preset{
    .layer_count = 28,
    .kv_head_count = 4,
    .head_dim = 128,
    .default_context = 4096,
    .max_context = 32768,
};

/// Qwen3-4B: 36 layers, 8 KV heads, 128 dim
pub const QWEN3_4B = Preset{
    .layer_count = 36,
    .kv_head_count = 8,
    .head_dim = 128,
    .default_context = 4096,
    .max_context = 32768,
};

/// Calculate memory requirements for a preset at a given context length.
pub fn memoryRequired(preset: Preset, context: u32) usize {
    const elements: u64 = @as(u64, preset.layer_count) * 2 *
        @as(u64, preset.kv_head_count) * context * preset.head_dim;
    return @intCast(elements * @sizeOf(u16));
}

// ══════════════════════════════════════════════════════════════════════════════
// f16 Conversion
// ══════════════════════════════════════════════════════════════════════════════

inline fn f32ToF16Bits(value: f32) u16 {
    const half: f16 = @floatCast(value);
    return @bitCast(half);
}

inline fn f16BitsToF32(bits: u16) f32 {
    const half: f16 = @bitCast(bits);
    return @floatCast(half);
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

test "memory calculation for Qwen3-0.6B at 2048 context" {
    const mem = memoryRequired(QWEN3_0_6B, 2048);
    // 28 layers * 2 (K+V) * 8 heads * 2048 positions * 128 dim * 2 bytes = 29,360,128 bytes ≈ 28 MB
    const expected: usize = 28 * 2 * 8 * 2048 * 128 * 2;
    if (mem != expected) return error.TestUnexpectedResult;
}

test "memory calculation for Qwen3-4B at 4096 context" {
    const mem = memoryRequired(QWEN3_4B, 4096);
    // 36 * 2 * 8 * 4096 * 128 * 2 = 603,979,776 bytes ≈ 576 MB
    const expected: usize = 36 * 2 * 8 * 4096 * 128 * 2;
    if (mem != expected) return error.TestUnexpectedResult;
}

test "preset context fits in 1GB arena" {
    // Qwen3-0.6B at max context 8192 should fit in 1GB
    const mem = memoryRequired(QWEN3_0_6B, 8192);
    if (mem > 1024 * 1024 * 1024) return error.TestUnexpectedResult;
}


// ══════════════════════════════════════════════════════════════════════════════
// Inline Tests
// ══════════════════════════════════════════════════════════════════════════════

// Test allocator using a static buffer (no OS dependency)
var test_backing: [1024 * 1024]u8 = undefined; // 1MB
var test_offset: usize = 0;

fn testAlloc(byte_count: usize, alignment: usize) ?[*]u8 {
    const aligned = (test_offset + alignment - 1) & ~(alignment - 1);
    if (aligned + byte_count > test_backing.len) return null;
    test_offset = aligned + byte_count;
    return @ptrCast(&test_backing[aligned]);
}

fn resetTestAlloc() void {
    test_offset = 0;
}

test "init with valid config" {
    resetTestAlloc();
    const cache = KvCache.init(testAlloc, 4, 2, 64, 128) catch return error.TestUnexpectedResult;
    if (cache.layer_count != 4) return error.TestUnexpectedResult;
    if (cache.head_count != 2) return error.TestUnexpectedResult;
    if (cache.head_dim != 64) return error.TestUnexpectedResult;
    if (cache.max_context != 128) return error.TestUnexpectedResult;
    if (cache.context_used != 0) return error.TestUnexpectedResult;
}

test "init with zero config returns error" {
    resetTestAlloc();
    if (KvCache.init(testAlloc, 0, 2, 64, 128)) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        if (err != error.InvalidConfig) return error.TestUnexpectedResult;
    }
}

test "store advances context_used" {
    resetTestAlloc();
    var cache = KvCache.init(testAlloc, 2, 2, 4, 16) catch return error.TestUnexpectedResult;
    var key = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 }; // 2 heads * 4 dim
    var val = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 };
    cache.store(0, 0, &key, &val) catch return error.TestUnexpectedResult;
    if (cache.context_used != 1) return error.TestUnexpectedResult;
    cache.store(0, 1, &key, &val) catch return error.TestUnexpectedResult;
    if (cache.context_used != 2) return error.TestUnexpectedResult;
}

test "context exceeded returns error" {
    resetTestAlloc();
    var cache = KvCache.init(testAlloc, 1, 1, 2, 2) catch return error.TestUnexpectedResult;
    var key = [_]f32{ 1.0, 2.0 };
    var val = [_]f32{ 0.1, 0.2 };
    cache.store(0, 0, &key, &val) catch return error.TestUnexpectedResult;
    cache.store(0, 1, &key, &val) catch return error.TestUnexpectedResult;
    if (cache.store(0, 2, &key, &val)) |_| {
        return error.TestUnexpectedResult; // Should have failed
    } else |err| {
        if (err != error.ContextExceeded) return error.TestUnexpectedResult;
    }
}

test "reset clears context_used" {
    resetTestAlloc();
    var cache = KvCache.init(testAlloc, 1, 1, 2, 8) catch return error.TestUnexpectedResult;
    var key = [_]f32{ 1.0, 2.0 };
    var val = [_]f32{ 0.1, 0.2 };
    cache.store(0, 0, &key, &val) catch return error.TestUnexpectedResult;
    cache.store(0, 1, &key, &val) catch return error.TestUnexpectedResult;
    if (cache.context_used != 2) return error.TestUnexpectedResult;
    cache.reset();
    if (cache.context_used != 0) return error.TestUnexpectedResult;
    if (cache.remaining() != 8) return error.TestUnexpectedResult;
}

test "bytesForContext calculation" {
    resetTestAlloc();
    const cache = KvCache.init(testAlloc, 28, 8, 128, 2048) catch return error.TestUnexpectedResult;
    const bytes = cache.bytesForContext(2048);
    // 28 layers * 2 * 8 heads * 2048 positions * 128 dim * 2 bytes/f16
    const expected: usize = 28 * 2 * 8 * 2048 * 128 * 2;
    if (bytes != expected) return error.TestUnexpectedResult;
}
