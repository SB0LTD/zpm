// @zpm/diffusion — GGUF diffusion-transformer loader.
//
// Reuses src/llm/gguf_loader.sig for the actual mmap + tensor mapping, then
// classifies the file as a diffusion transformer by inspecting GGUF metadata
// and tensor-name conventions. It NEVER hard-codes a product name: the arch is
// derived from the "general.architecture" key and the shape of the tensor set,
// so any MMDiT/DiT-class GGUF (Flux, SD3, Qwen-Image, …) maps onto the same
// DiffusionModel view.

// Reach the GGUF loader through the fused-matmul module's re-export, so the
// whole src/llm subtree belongs to a single module (no double ownership).
const gguf_loader = @import("fused_matmul").gguf_loader;

pub const GGMLType = gguf_loader.GGMLType;
pub const TensorInfo = gguf_loader.TensorInfo;

/// Coarse family of diffusion transformer. The denoiser dispatches on this to
/// pick block wiring; the loader fills it from metadata + tensor names.
pub const DiffusionArch = enum {
    unknown,
    /// Multi-modal Diffusion Transformer with joint text+image attention
    /// (Qwen-Image / SD3 / Flux class). Double-stream then single-stream blocks.
    mmdit,
    /// Plain U-Net (SD1.x/SD2.x/SDXL class), retained for completeness.
    unet,

    pub fn label(self: DiffusionArch) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .mmdit => "mmdit",
            .unet => "unet",
        };
    }
};

pub const LoadError = error{
    FileNotFound,
    MmapFailed,
    InvalidGGUF,
    UnsupportedVersion,
    NotADiffusionModel,
    ParseError,
};

/// Structural description of a loaded diffusion transformer. All heavy tensor
/// data stays in the mmap owned by `inner`; this struct only holds shape/offset
/// metadata plus resolved weight pointers for the denoiser's hot path.
pub const DiffusionModel = struct {
    inner: gguf_loader.LoadedModel = .{},
    arch: DiffusionArch = .unknown,

    // Derived MMDiT geometry (filled from metadata, with sane fallbacks).
    n_double_blocks: u32 = 0, // joint text+image attention blocks
    n_single_blocks: u32 = 0, // image-only refinement blocks
    hidden_size: u32 = 3072,
    n_heads: u32 = 24,
    patch_size: u32 = 2, // latent patch edge (pixel-unshuffle factor)
    in_channels: u32 = 16, // latent channels (VAE latent depth)
    context_dim: u32 = 3584, // text-encoder embedding width feeding cross-attn

    pub fn deinit(self: *DiffusionModel) void {
        self.inner.deinit();
        self.* = .{};
    }

    /// Number of tensors parsed from the GGUF container.
    pub fn tensorCount(self: *const DiffusionModel) usize {
        return self.inner.n_tensors;
    }

    /// Name of the i-th tensor (for inspection/diagnostics).
    pub fn tensorName(self: *const DiffusionModel, i: usize) []const u8 {
        if (i >= self.inner.n_tensors) return "";
        return self.inner.tensors[i].nameSlice();
    }

    /// The detected "general.architecture" metadata string, if any.
    pub fn archName(self: *const DiffusionModel) []const u8 {
        return self.inner.meta.arch[0..self.inner.meta.arch_len];
    }

    /// Look up a tensor and report its dims (ne[0..ndim]) into `dims_out`.
    /// Returns the ndim, or 0 if not found. Used by the denoiser to size GEMMs.
    pub fn tensorDims(self: *const DiffusionModel, name: []const u8, dims_out: *[4]u64) u32 {
        const ti = self.tensor(name) orelse return 0;
        var d: u32 = 0;
        while (d < ti.ndim and d < 4) : (d += 1) dims_out[d] = ti.ne[d];
        return ti.ndim;
    }

    /// GGML type of a named tensor (for the dequant path). Returns null if absent.
    pub fn tensorType(self: *const DiffusionModel, name: []const u8) ?GGMLType {
        const ti = self.tensor(name) orelse return null;
        return ti.ggml_type;
    }

    /// Look up a diffusion tensor by GGUF name (e.g. "model.diffusion_model.…").
    pub fn tensor(self: *const DiffusionModel, name: []const u8) ?*const TensorInfo {
        for (0..self.inner.n_tensors) |i| {
            const ti = &self.inner.tensors[i];
            if (eql(ti.nameSlice(), name)) return ti;
        }
        return null;
    }

    /// Raw pointer to a tensor's (possibly quantized) bytes in the mmap.
    pub fn tensorPtr(self: *const DiffusionModel, ti: *const TensorInfo) [*]const u8 {
        return gguf_loader.tensorPtr(&self.inner, ti);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Substring test used to classify tensor sets without allocation.
fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (eql(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Load a diffusion transformer from a GGUF file and classify its architecture.
pub fn load(path: [*:0]const u8, model: *DiffusionModel) LoadError!void {
    model.* = .{};
    gguf_loader.load(path, &model.inner) catch |e| return switch (e) {
        error.FileNotFound => LoadError.FileNotFound,
        error.MmapFailed => LoadError.MmapFailed,
        error.UnsupportedVersion => LoadError.UnsupportedVersion,
        else => LoadError.InvalidGGUF,
    };

    model.arch = classify(&model.inner);
    if (model.arch == .unknown) return LoadError.NotADiffusionModel;

    deriveGeometry(model);
}

/// Like `load`, but does NOT reject an unrecognized architecture. Used by
/// diagnostics (`sbai inspect`) so the tensor names can be printed even when
/// the classifier didn't match — the first step in supporting a new naming
/// convention. Still runs geometry derivation on a best-effort basis.
pub fn loadRaw(path: [*:0]const u8, model: *DiffusionModel) LoadError!void {
    model.* = .{};
    gguf_loader.load(path, &model.inner) catch |e| return switch (e) {
        error.FileNotFound => LoadError.FileNotFound,
        error.MmapFailed => LoadError.MmapFailed,
        error.UnsupportedVersion => LoadError.UnsupportedVersion,
        else => LoadError.InvalidGGUF,
    };
    model.arch = classify(&model.inner);
    deriveGeometry(model);
}

/// Classify by the block families present in the tensor names. Two MMDiT naming
/// conventions are recognized:
///   - stable-diffusion.cpp / ComfyUI: "double_blocks" + "single_blocks",
///     "img_attn"/"txt_attn".
///   - diffusers (Qwen-Image, SD3): "transformer_blocks.N" joint blocks with
///     "attn.to_q/to_k/to_v", plus "img_in"/"time_text_embed" entry tensors.
/// U-Nets expose "input_blocks"/"output_blocks"/"middle_block".
fn classify(inner: *const gguf_loader.LoadedModel) DiffusionArch {
    // Metadata architecture is the strongest signal when present.
    const arch = inner.meta.arch[0..inner.meta.arch_len];
    if (contains(arch, "qwen_image") or contains(arch, "flux") or contains(arch, "sd3") or contains(arch, "mmdit"))
        return .mmdit;

    var has_double = false;
    var has_single = false;
    var has_transformer_blocks = false;
    var has_img_in = false;
    var has_unet = false;
    for (0..inner.n_tensors) |i| {
        const n = inner.tensors[i].nameSlice();
        if (contains(n, "double_blocks") or contains(n, "txt_attn") or contains(n, "img_attn")) has_double = true;
        if (contains(n, "single_blocks")) has_single = true;
        if (contains(n, "transformer_blocks")) has_transformer_blocks = true;
        if (contains(n, "img_in") or contains(n, "time_text_embed")) has_img_in = true;
        if (contains(n, "input_blocks") or contains(n, "output_blocks") or contains(n, "middle_block")) has_unet = true;
    }
    if (has_double or has_single) return .mmdit;
    if (has_transformer_blocks and has_img_in) return .mmdit;
    if (has_unet) return .unet;
    return .unknown;
}

/// Fill geometry from the highest block indices seen and any metadata the base
/// loader captured. Uses Qwen-Image-class defaults when a field is absent.
fn deriveGeometry(model: *DiffusionModel) void {
    var max_double: i64 = -1;
    var max_single: i64 = -1;
    var max_joint: i64 = -1; // diffusers "transformer_blocks.N"
    for (0..model.inner.n_tensors) |i| {
        const n = model.inner.tensors[i].nameSlice();
        if (contains(n, "double_blocks")) {
            const idx = blockIndex(n, "double_blocks");
            if (idx > max_double) max_double = idx;
        } else if (contains(n, "single_blocks")) {
            const idx = blockIndex(n, "single_blocks");
            if (idx > max_single) max_single = idx;
        } else if (contains(n, "transformer_blocks")) {
            const idx = blockIndex(n, "transformer_blocks");
            if (idx > max_joint) max_joint = idx;
        }
    }
    if (max_double >= 0) model.n_double_blocks = @intCast(max_double + 1);
    if (max_single >= 0) model.n_single_blocks = @intCast(max_single + 1);
    // Diffusers-style models expose a single stack of joint blocks; count them
    // as double (joint text+image) blocks so the denoiser sees the depth.
    if (max_joint >= 0 and model.n_double_blocks == 0) model.n_double_blocks = @intCast(max_joint + 1);

    // The base loader parses n_embd/n_heads into meta for transformer files;
    // reuse them when non-default, else keep the MMDiT defaults above.
    if (model.inner.meta.n_embd != 2048) model.hidden_size = model.inner.meta.n_embd;
    if (model.inner.meta.n_heads != 16) model.n_heads = model.inner.meta.n_heads;
}

/// Parse the integer block index directly after "<prefix>." in a tensor name,
/// e.g. "…double_blocks.12.img_attn.qkv.weight" → 12. Returns -1 on miss.
fn blockIndex(name: []const u8, prefix: []const u8) i64 {
    // Find prefix, then skip the following '.'
    var i: usize = 0;
    while (i + prefix.len <= name.len) : (i += 1) {
        if (eql(name[i .. i + prefix.len], prefix)) {
            var j = i + prefix.len;
            if (j < name.len and name[j] == '.') j += 1;
            var val: i64 = 0;
            var seen = false;
            while (j < name.len and name[j] >= '0' and name[j] <= '9') : (j += 1) {
                val = val * 10 + @as(i64, name[j] - '0');
                seen = true;
            }
            if (seen) return val;
            return -1;
        }
    }
    return -1;
}

test "blockIndex parses double_blocks index" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i64, 12), blockIndex("model.double_blocks.12.img_attn.qkv.weight", "double_blocks"));
    try std.testing.expectEqual(@as(i64, 0), blockIndex("single_blocks.0.linear1.weight", "single_blocks"));
    try std.testing.expectEqual(@as(i64, -1), blockIndex("time_embed.weight", "double_blocks"));
}

test "contains matches substrings" {
    const std = @import("std");
    try std.testing.expect(contains("model.double_blocks.3", "double_blocks"));
    try std.testing.expect(!contains("abc", "abcd"));
}

test "arch label round-trips" {
    const std = @import("std");
    try std.testing.expectEqualStrings("mmdit", DiffusionArch.mmdit.label());
    try std.testing.expectEqualStrings("unknown", DiffusionArch.unknown.label());
}
