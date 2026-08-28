// @zpm/llm — GGUF Weight Loader
// Maps GGUF tensor names to decoder weight structures for Qwen3-VL.
// Uses memory-mapped I/O (Win32 CreateFileMapping) for zero-copy access.
//
// Tensor naming convention (Qwen3-VL-2B GGUF):
//   token_embd.weight           — [vocab, hidden]
//   blk.{L}.attn_norm.weight    — [hidden]
//   blk.{L}.attn_q.weight       — [n_heads * head_dim, hidden]
//   blk.{L}.attn_k.weight       — [n_kv_heads * head_dim, hidden]
//   blk.{L}.attn_v.weight       — [n_kv_heads * head_dim, hidden]
//   blk.{L}.attn_output.weight  — [hidden, n_heads * head_dim]
//   blk.{L}.attn_q_norm.weight  — [head_dim] (Qwen3 per-head Q norm)
//   blk.{L}.attn_k_norm.weight  — [head_dim] (Qwen3 per-head K norm)
//   blk.{L}.ffn_norm.weight     — [hidden]
//   blk.{L}.ffn_gate.weight     — [intermediate, hidden]
//   blk.{L}.ffn_up.weight       — [intermediate, hidden]
//   blk.{L}.ffn_down.weight     — [hidden, intermediate]
//   output_norm.weight           — [hidden]
//   output.weight                — [vocab, hidden] (or tied to token_embd)
//
// Vision encoder tensors (mmproj GGUF):
//   v.patch_embd.weight         — [hidden, patch_size*patch_size*3]
//   v.position_embd.weight      — [n_patches+1, hidden]
//   v.blk.{L}.attn_norm.weight  — [hidden]
//   v.blk.{L}.attn_qkv.weight   — [3*hidden, hidden]
//   v.blk.{L}.attn_out.weight   — [hidden, hidden]
//   v.blk.{L}.ffn_norm.weight   — [hidden]
//   v.blk.{L}.ffn_up.weight     — [ff, hidden]
//   v.blk.{L}.ffn_down.weight   — [hidden, ff]
//   v.proj.weight               — [llm_hidden, vision_hidden]

const std = @import("std");

// ── Win32 memory-mapped file API ──
extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) ?*anyopaque;
extern "kernel32" fn CreateFileMappingA(
    hFile: *anyopaque,
    lpAttributes: ?*anyopaque,
    flProtect: u32,
    dwMaxSizeHigh: u32,
    dwMaxSizeLow: u32,
    lpName: ?[*:0]const u8,
) ?*anyopaque;
extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: *anyopaque,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) ?[*]u8;
extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: [*]const u8) c_int;
extern "kernel32" fn CloseHandle(hObject: *anyopaque) c_int;
extern "kernel32" fn GetFileSize(hFile: *anyopaque, lpFileSizeHigh: ?*u32) u32;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const PAGE_READONLY: u32 = 0x02;
const FILE_MAP_READ: u32 = 0x0004;
const INVALID_HANDLE: ?*anyopaque = @ptrFromInt(0xFFFFFFFFFFFFFFFF);

// ── GGUF constants (inline — no cross-package import needed) ──
const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" LE
const MAX_TENSORS: usize = 4096;
const NAME_LEN: usize = 128;

pub const GGMLType = enum(u32) {
    f32 = 0, f16 = 1, q4_0 = 2, q4_1 = 3,
    q5_0 = 6, q5_1 = 7, q8_0 = 8, q8_1 = 9,
    q2_k = 10, q3_k = 11, q4_k = 12, q5_k = 13,
    q6_k = 14, q8_k = 15, _,

    pub fn blockElems(self: GGMLType) u32 {
        return switch (self) {
            .f32, .f16 => 1,
            .q8_0 => 32,
            .q4_0, .q4_1 => 32,
            .q4_k, .q5_k, .q6_k, .q3_k, .q2_k, .q8_k => 256,
            else => 32,
        };
    }

    pub fn blockBytes(self: GGMLType) u32 {
        return switch (self) {
            .f32 => 4, .f16 => 2, .q8_0 => 34,
            .q4_0 => 18, .q4_1 => 20, .q4_k => 144,
            .q3_k => 110, .q5_k => 176, .q6_k => 210,
            .q2_k => 84, .q8_k => 292,
            else => 18,
        };
    }
};

pub const TensorInfo = struct {
    name: [NAME_LEN]u8,
    name_len: u8,
    ndim: u32,
    ne: [4]u64, // dimensions
    ggml_type: GGMLType,
    offset: u64, // offset from data section start

    pub fn nameSlice(self: *const TensorInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn numElements(self: *const TensorInfo) usize {
        var n: usize = 1;
        for (0..self.ndim) |i| n *|= @intCast(self.ne[i]);
        return n;
    }

    pub fn dataSize(self: *const TensorInfo) usize {
        const elems = self.numElements();
        const be = self.ggml_type.blockElems();
        const bb = self.ggml_type.blockBytes();
        if (be == 0 or bb == 0) return 0;
        return ((elems + be - 1) / be) * bb;
    }
};

// ── Model metadata extracted from GGUF header ──
pub const ModelMeta = struct {
    arch: [64]u8 = undefined,
    arch_len: u8 = 0,
    n_layers: u32 = 28,
    n_heads: u32 = 16,
    n_kv_heads: u32 = 8,
    n_embd: u32 = 2048,
    n_ff: u32 = 6144,
    n_vocab: u32 = 151936,
    context_len: u32 = 8192,
    rope_theta: f32 = 1000000.0,
    head_dim: u32 = 128,
    rms_eps: f32 = 1e-6,
};

// ── Per-layer weight pointers (raw byte pointers into mmap'd file) ──
pub const MAX_LAYERS: usize = 64;

pub const LayerWeights = struct {
    attn_norm: ?[*]const u8 = null, // input_layernorm
    q_proj: ?[*]const u8 = null,
    k_proj: ?[*]const u8 = null,
    v_proj: ?[*]const u8 = null,
    o_proj: ?[*]const u8 = null,
    q_norm: ?[*]const u8 = null, // per-head Q norm (Qwen3)
    k_norm: ?[*]const u8 = null, // per-head K norm (Qwen3)
    post_norm: ?[*]const u8 = null, // post_attention_layernorm
    gate_proj: ?[*]const u8 = null, // SwiGLU gate
    up_proj: ?[*]const u8 = null, // SwiGLU up
    down_proj: ?[*]const u8 = null, // SwiGLU down
    // Quantization types for each weight
    q_proj_type: GGMLType = .f32,
    k_proj_type: GGMLType = .f32,
    v_proj_type: GGMLType = .f32,
    o_proj_type: GGMLType = .f32,
    gate_proj_type: GGMLType = .f32,
    up_proj_type: GGMLType = .f32,
    down_proj_type: GGMLType = .f32,
};

pub const ModelWeights = struct {
    // Embedding
    token_embd: ?[*]const u8 = null,
    token_embd_type: GGMLType = .f32,
    // Output head
    output_norm: ?[*]const u8 = null,
    output_w: ?[*]const u8 = null,
    output_w_type: GGMLType = .f32,
    // Per-layer
    layers: [MAX_LAYERS]LayerWeights = @splat(LayerWeights{}),
    n_layers: usize = 0,
};

// ── Tokenizer data extracted from GGUF metadata ──
pub const MAX_VOCAB_ENTRIES: usize = 256000;
pub const MAX_TOKEN_LEN: usize = 128;

pub const TokenEntry = struct {
    text: [MAX_TOKEN_LEN]u8 = undefined,
    len: u8 = 0,
    score: f32 = 0.0,
    token_type: u8 = 0, // 1=normal, 2=control, 3=byte, etc.
};

pub const MAX_MERGE_STR_LEN: usize = 256;

pub const MergeEntry = struct {
    text: [MAX_MERGE_STR_LEN]u8 = undefined,
    len: u8 = 0,
};

pub const TokenizerData = struct {
    entries: [MAX_VOCAB_ENTRIES]TokenEntry = @splat(TokenEntry{}),
    vocab_size: usize = 0,
    bos_id: u32 = 1,
    eos_id: u32 = 2,
    pad_id: u32 = 0,
    // Merge data for BPE — raw "token_a token_b" strings from GGUF
    merge_strs: [MAX_VOCAB_ENTRIES]MergeEntry = @splat(MergeEntry{}),
    n_merges: usize = 0,
};

// ── The loaded model: mmap handle + parsed tensors + mapped weights ──
pub const LoadedModel = struct {
    // File handles (Win32)
    file_handle: ?*anyopaque = null,
    mapping_handle: ?*anyopaque = null,
    mapped_base: ?[*]u8 = null,
    file_size: usize = 0,

    // Parsed GGUF data
    tensors: [MAX_TENSORS]TensorInfo = undefined,
    n_tensors: usize = 0,
    data_offset: usize = 0, // byte offset where tensor data begins

    // Extracted structures
    meta: ModelMeta = .{},
    weights: ModelWeights = .{},
    tokenizer: TokenizerData = .{},

    pub fn deinit(self: *LoadedModel) void {
        if (self.mapped_base) |base| _ = UnmapViewOfFile(base);
        if (self.mapping_handle) |h| _ = CloseHandle(h);
        if (self.file_handle) |h| _ = CloseHandle(h);
        self.* = .{};
    }
};

pub const LoadError = error{
    FileNotFound,
    MmapFailed,
    InvalidGGUF,
    UnsupportedVersion,
    ParseError,
};

/// Load a GGUF model file via memory-mapped I/O.
/// Populates the provided LoadedModel struct in-place (avoids 34MB stack copy).
pub fn load(path: [*:0]const u8, model: *LoadedModel) LoadError!void {
    model.* = .{};

    // Open file
    const hFile = CreateFileA(
        path, GENERIC_READ, FILE_SHARE_READ,
        null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null,
    );
    if (hFile == null or hFile == INVALID_HANDLE)
        return LoadError.FileNotFound;
    model.file_handle = hFile;

    // Get file size
    var size_high: u32 = 0;
    const size_low = GetFileSize(hFile.?, &size_high);
    model.file_size = (@as(usize, size_high) << 32) | @as(usize, size_low);

    // Create file mapping
    const hMapping = CreateFileMappingA(
        hFile.?, null, PAGE_READONLY, 0, 0, null,
    );
    if (hMapping == null) return LoadError.MmapFailed;
    model.mapping_handle = hMapping;

    // Map view
    const base = MapViewOfFile(hMapping.?, FILE_MAP_READ, 0, 0, 0);
    if (base == null) return LoadError.MmapFailed;
    model.mapped_base = base;

    // Parse GGUF header
    const data = base.?[0..model.file_size];
    try parseGGUF(data, model);

    // Map tensor names to weight structure
    mapWeights(model);
}

/// Get a raw pointer to a tensor's data in the mmap'd file.
pub fn tensorPtr(model: *const LoadedModel, ti: *const TensorInfo) [*]const u8 {
    const base = model.mapped_base.?;
    const off = model.data_offset + @as(usize, @intCast(ti.offset));
    return base + off;
}

// ── GGUF parsing (inlined from metalforge/gguf.sig patterns) ──

fn parseGGUF(data: []const u8, model: *LoadedModel) LoadError!void {
    if (data.len < 24) return LoadError.InvalidGGUF;
    var pos: usize = 0;

    const magic = rd32(data, &pos);
    if (magic != GGUF_MAGIC) return LoadError.InvalidGGUF;

    const version = rd32(data, &pos);
    if (version < 2 or version > 3) return LoadError.UnsupportedVersion;

    const n_tensors = rd64(data, &pos);
    const n_kv = rd64(data, &pos);
    model.n_tensors = @min(@as(usize, @intCast(n_tensors)), MAX_TENSORS);

    // Parse metadata key-value pairs
    var kv_i: usize = 0;
    while (kv_i < @as(usize, @intCast(n_kv))) : (kv_i += 1) {
        pos = parseMetaKV(data, pos, &model.meta, &model.tokenizer) catch
            return LoadError.ParseError;
    }

    // Parse tensor info entries
    for (0..model.n_tensors) |i| {
        var ti = TensorInfo{
            .name = undefined, .name_len = 0,
            .ndim = 0, .ne = .{ 1, 1, 1, 1 },
            .ggml_type = .f32, .offset = 0,
        };

        const nlen: usize = @intCast(rd64(data, &pos));
        const nl = @min(nlen, NAME_LEN - 1);
        @memcpy(ti.name[0..nl], data[pos .. pos + nl]);
        ti.name_len = @intCast(nl);
        pos += nlen;

        ti.ndim = rd32(data, &pos);
        for (0..@intCast(ti.ndim)) |d| ti.ne[d] = rd64(data, &pos);
        ti.ggml_type = @enumFromInt(rd32(data, &pos));
        ti.offset = rd64(data, &pos);

        model.tensors[i] = ti;
    }

    // Align data section to 32 bytes
    pos = (pos + 31) & ~@as(usize, 31);
    model.data_offset = pos;
}

fn mapWeights(model: *LoadedModel) void {
    const base = model.mapped_base orelse return;
    model.weights.n_layers = model.meta.n_layers;

    for (0..model.n_tensors) |i| {
        const ti = &model.tensors[i];
        const name = ti.nameSlice();
        const ptr = base + model.data_offset + @as(usize, @intCast(ti.offset));

        // Global tensors
        if (eql(name, "token_embd.weight")) {
            model.weights.token_embd = ptr;
            model.weights.token_embd_type = ti.ggml_type;
        } else if (eql(name, "output_norm.weight")) {
            model.weights.output_norm = ptr;
        } else if (eql(name, "output.weight")) {
            model.weights.output_w = ptr;
            model.weights.output_w_type = ti.ggml_type;
        } else if (startsWith(name, "blk.")) {
            // Parse layer index: "blk.{N}.rest"
            const layer_idx = parseLayerIdx(name[4..]) orelse continue;
            if (layer_idx >= MAX_LAYERS) continue;
            const rest = skipToAfterDot(name[4..]);
            mapLayerWeight(&model.weights.layers[layer_idx], rest, ptr, ti.ggml_type);
        }
    }

    // If output.weight is missing, tie to token_embd (weight tying)
    if (model.weights.output_w == null) {
        model.weights.output_w = model.weights.token_embd;
        model.weights.output_w_type = model.weights.token_embd_type;
    }
}

fn mapLayerWeight(lw: *LayerWeights, suffix: []const u8, ptr: [*]const u8, qt: GGMLType) void {
    if (eql(suffix, "attn_norm.weight")) {
        lw.attn_norm = ptr;
    } else if (eql(suffix, "attn_q.weight")) {
        lw.q_proj = ptr; lw.q_proj_type = qt;
    } else if (eql(suffix, "attn_k.weight")) {
        lw.k_proj = ptr; lw.k_proj_type = qt;
    } else if (eql(suffix, "attn_v.weight")) {
        lw.v_proj = ptr; lw.v_proj_type = qt;
    } else if (eql(suffix, "attn_output.weight")) {
        lw.o_proj = ptr; lw.o_proj_type = qt;
    } else if (eql(suffix, "attn_q_norm.weight")) {
        lw.q_norm = ptr;
    } else if (eql(suffix, "attn_k_norm.weight")) {
        lw.k_norm = ptr;
    } else if (eql(suffix, "ffn_norm.weight")) {
        lw.post_norm = ptr;
    } else if (eql(suffix, "ffn_gate.weight")) {
        lw.gate_proj = ptr; lw.gate_proj_type = qt;
    } else if (eql(suffix, "ffn_up.weight")) {
        lw.up_proj = ptr; lw.up_proj_type = qt;
    } else if (eql(suffix, "ffn_down.weight")) {
        lw.down_proj = ptr; lw.down_proj_type = qt;
    }
}

// ── Metadata KV parsing ──

fn parseMetaKV(
    data: []const u8,
    start: usize,
    meta: *ModelMeta,
    tok: *TokenizerData,
) error{OutOfBounds}!usize {
    var pos = start;
    if (pos + 8 > data.len) return error.OutOfBounds;
    const key = rdStr(data, &pos);
    if (pos + 4 > data.len) return error.OutOfBounds;
    const vtype = rd32(data, &pos);

    // String values
    if (vtype == 8) {
        const val = rdStr(data, &pos);
        if (endsWith(key, "general.architecture")) {
            const n = @min(val.len, 63);
            @memcpy(meta.arch[0..n], val[0..n]);
            meta.arch_len = @intCast(n);
        }
        return pos;
    }

    // Array values (tokenizer vocab, scores, merges)
    if (vtype == 9) {
        if (pos + 12 > data.len) return error.OutOfBounds;
        const elem_type = rd32(data, &pos);
        const count = rd64(data, &pos);
        const cnt: usize = @intCast(count);

        if (endsWith(key, "tokenizer.ggml.tokens")) {
            // String array: vocab tokens
            for (0..@min(cnt, MAX_VOCAB_ENTRIES)) |ti| {
                const s = rdStr(data, &pos);
                const slen = @min(s.len, MAX_TOKEN_LEN - 1);
                @memcpy(tok.entries[ti].text[0..slen], s[0..slen]);
                tok.entries[ti].len = @intCast(slen);
            }
            // Skip remaining if more than MAX_VOCAB_ENTRIES
            for (@min(cnt, MAX_VOCAB_ENTRIES)..cnt) |_|
                _ = rdStr(data, &pos);
            tok.vocab_size = @min(cnt, MAX_VOCAB_ENTRIES);
            return pos;
        } else if (endsWith(key, "tokenizer.ggml.scores")) {
            // Float array: token scores
            for (0..@min(cnt, MAX_VOCAB_ENTRIES)) |ti| {
                if (pos + 4 > data.len) return error.OutOfBounds;
                tok.entries[ti].score = @bitCast(rd32(data, &pos));
            }
            for (@min(cnt, MAX_VOCAB_ENTRIES)..cnt) |_| pos += 4;
            return pos;
        } else if (endsWith(key, "tokenizer.ggml.token_type")) {
            // Int array: token types
            for (0..@min(cnt, MAX_VOCAB_ENTRIES)) |ti| {
                if (pos + 4 > data.len) return error.OutOfBounds;
                tok.entries[ti].token_type = @intCast(rd32(data, &pos));
            }
            for (@min(cnt, MAX_VOCAB_ENTRIES)..cnt) |_| pos += 4;
            return pos;
        } else if (endsWith(key, "tokenizer.ggml.merges")) {
            // String array: BPE merges ("token_a token_b")
            // Store raw strings — tokenizer.sig resolves to IDs after vocab is loaded
            for (0..@min(cnt, MAX_VOCAB_ENTRIES)) |mi| {
                const merge_str = rdStr(data, &pos);
                const slen = @min(merge_str.len, MAX_MERGE_STR_LEN - 1);
                @memcpy(tok.merge_strs[mi].text[0..slen], merge_str[0..slen]);
                tok.merge_strs[mi].len = @intCast(slen);
            }
            for (@min(cnt, MAX_VOCAB_ENTRIES)..cnt) |_|
                _ = rdStr(data, &pos);
            tok.n_merges = @min(cnt, MAX_VOCAB_ENTRIES);
            return pos;
        }

        // Generic array skip
        for (0..cnt) |_| pos = try skipValue(data, pos, elem_type);
        return pos;
    }

    // Scalar values
    pos = try skipValue(data, pos, vtype);

    // Extract known integer/float metadata
    if (vtype == 4 or vtype == 5) { // u32 / i32
        const v = rdU32At(data, pos - 4);
        if (endsWith(key, "block_count")) meta.n_layers = v;
        if (endsWith(key, "head_count")) meta.n_heads = v;
        if (endsWith(key, "head_count_kv")) meta.n_kv_heads = v;
        if (endsWith(key, "embedding_length")) meta.n_embd = v;
        if (endsWith(key, "feed_forward_length")) meta.n_ff = v;
        if (endsWith(key, "context_length")) meta.context_len = v;
        if (endsWith(key, "vocab_size")) meta.n_vocab = v;
    } else if (vtype == 6) { // f32
        const v: f32 = @bitCast(rdU32At(data, pos - 4));
        if (endsWith(key, "rope.freq_base")) meta.rope_theta = v;
        if (endsWith(key, "layer_norm_rms_epsilon")) meta.rms_eps = v;
    }

    // Special token IDs
    if (vtype == 4 or vtype == 5) {
        const v = rdU32At(data, pos - 4);
        if (endsWith(key, "tokenizer.ggml.bos_token_id")) tok.bos_id = v;
        if (endsWith(key, "tokenizer.ggml.eos_token_id")) tok.eos_id = v;
        if (endsWith(key, "tokenizer.ggml.padding_token_id")) tok.pad_id = v;
    }

    return pos;
}

// ── Utility functions ──

fn skipValue(data: []const u8, start: usize, vtype: u32) error{OutOfBounds}!usize {
    var pos = start;
    switch (vtype) {
        0, 1, 7 => { if (pos + 1 > data.len) return error.OutOfBounds; pos += 1; },
        2, 3 => { if (pos + 2 > data.len) return error.OutOfBounds; pos += 2; },
        4, 5, 6 => { if (pos + 4 > data.len) return error.OutOfBounds; pos += 4; },
        8 => { _ = rdStr(data, &pos); },
        9 => {
            if (pos + 12 > data.len) return error.OutOfBounds;
            const et = rd32(data, &pos);
            const cnt: usize = @intCast(rd64(data, &pos));
            for (0..cnt) |_| pos = try skipValue(data, pos, et);
        },
        10, 11, 12 => { if (pos + 8 > data.len) return error.OutOfBounds; pos += 8; },
        else => return error.OutOfBounds,
    }
    return pos;
}

fn rd32(data: []const u8, pos: *usize) u32 {
    const v = @as(u32, data[pos.*]) | (@as(u32, data[pos.* + 1]) << 8) |
        (@as(u32, data[pos.* + 2]) << 16) | (@as(u32, data[pos.* + 3]) << 24);
    pos.* += 4;
    return v;
}

fn rd64(data: []const u8, pos: *usize) u64 {
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, data[pos.* + i]) << @intCast(i * 8);
    pos.* += 8;
    return v;
}

fn rdStr(data: []const u8, pos: *usize) []const u8 {
    const len: usize = @intCast(rd64(data, pos));
    const s = data[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

fn rdU32At(data: []const u8, off: usize) u32 {
    return @as(u32, data[off]) | (@as(u32, data[off + 1]) << 8) |
        (@as(u32, data[off + 2]) << 16) | (@as(u32, data[off + 3]) << 24);
}

fn parseLayerIdx(s: []const u8) ?usize {
    // Parse digits until '.'
    var idx: usize = 0;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        idx = idx * 10 + @as(usize, s[i] - '0');
    }
    if (i == 0) return null;
    return idx;
}

fn skipToAfterDot(s: []const u8) []const u8 {
    // Skip "N." (digits then dot) to get the suffix
    var i: usize = 0;
    while (i < s.len and s[i] != '.') : (i += 1) {}
    if (i < s.len) i += 1; // skip the dot
    return s[i..];
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| if (a[i] != b[i]) return false;
    return true;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eql(haystack[0..prefix.len], prefix);
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return eql(haystack[haystack.len - suffix.len ..], suffix);
}

/// Find a tensor by name. Returns null if not found.
pub fn findTensor(model: *const LoadedModel, name: []const u8) ?*const TensorInfo {
    for (0..model.n_tensors) |i| {
        if (eql(model.tensors[i].nameSlice(), name))
            return &model.tensors[i];
    }
    return null;
}
