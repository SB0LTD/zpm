//! @zpm/vk format — the VkFormats Galaxy's Vulkan driver has: how each is
//! kept in memory (gfxapi's engine formats, whose texels the raster draws
//! into and texture.sig samples), and what it can be used for.
//!
//! Every image is linear in memory (optimal tiling is the same layout):
//! texels of `bytes` bytes, rows 4-byte aligned. Depth and stencil formats
//! are all kept as the engine's d24s8 (depth in the low 24 bits as unorm,
//! stencil in the top 8): the raster's depth test and stencil work on that
//! word. So D32_SFLOAT and D32_SFLOAT_S8_UINT hold 24 bits of depth, and a
//! copy of their depth aspect converts (to f32, D16's to unorm16).
//!
//! Colour attachments are what the raster writes: RGBA8, BGRA8, RG8, R8
//! (unorm; an sRGB one is not encoded on write, so the sRGB formats are
//! sampled only). The 16-bit unorm and 32-bit float and integer formats
//! are sampled and copied, not drawn into. Storage images (compute shaders):
//! RGBA8 unorm and the 32-bit float and integer formats.

const std = @import("std");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;

pub const Fmt = engine.Format;

/// What a texture's channels read as through its view, when the format
/// has fewer (a depth format: depth in R).
pub const ASPECT_COLOR: u32 = 1;
pub const ASPECT_DEPTH: u32 = 2;
pub const ASPECT_STENCIL: u32 = 4;

pub const Feature = struct {
    pub const sampled: u32 = 0x1;
    pub const storage: u32 = 0x2;
    pub const vertex_buffer: u32 = 0x40;
    pub const color_attachment: u32 = 0x80;
    pub const color_blend: u32 = 0x100;
    pub const depth_stencil: u32 = 0x200;
    pub const blit_src: u32 = 0x400;
    pub const blit_dst: u32 = 0x800;
    pub const filter_linear: u32 = 0x1000;
    pub const transfer_src: u32 = 0x4000;
    pub const transfer_dst: u32 = 0x8000;
};

/// How a depth aspect is in a buffer (vkCmdCopy*Buffer*).
pub const DepthForm = enum(u8) { none, unorm16, unorm24, float32 };

pub const Info = struct {
    vk: u32,
    fmt: Fmt,
    /// texel bytes in memory
    bytes: u32,
    aspects: u32 = ASPECT_COLOR,
    srgb: bool = false,
    /// a colour attachment the raster writes (and blends)
    render: bool = false,
    /// a storage image compute shaders read and write (spirv's storage formats)
    storage: bool = false,
    filter: bool = true,
    depth: DepthForm = .none,
    /// vertex attribute: components, bytes each, float, signed, normalized,
    /// integer (0 comps: not a vertex format)
    comps: u8 = 0,
    size: u8 = 0,
    float: bool = false,
    signed: bool = false,
    norm: bool = false,
    integer: bool = false,
};

const D = ASPECT_DEPTH;
const S = ASPECT_STENCIL;

/// Every format the driver has (images, and vertex attributes).
pub const table = [_]Info{
    // images: colour
    .{ .vk = 9, .fmt = .r8, .bytes = 1, .render = true },
    .{ .vk = 16, .fmt = .rg8, .bytes = 2, .render = true },
    .{ .vk = 37, .fmt = .rgba8, .bytes = 4, .render = true, .storage = true, .comps = 4, .size = 1, .norm = true },
    .{ .vk = 43, .fmt = .rgba8, .bytes = 4, .srgb = true },
    .{ .vk = 44, .fmt = .bgra8, .bytes = 4, .render = true },
    .{ .vk = 50, .fmt = .bgra8, .bytes = 4, .srgb = true },
    .{ .vk = 70, .fmt = .r16, .bytes = 2 },
    .{ .vk = 77, .fmt = .rg16, .bytes = 4, .comps = 2, .size = 2, .norm = true },
    .{ .vk = 98, .fmt = .r32ui, .storage = true, .bytes = 4, .filter = false, .comps = 1, .size = 4, .integer = true },
    .{ .vk = 99, .fmt = .r32i, .storage = true, .bytes = 4, .filter = false, .comps = 1, .size = 4, .integer = true, .signed = true },
    .{ .vk = 100, .fmt = .r32f, .storage = true, .bytes = 4, .filter = false, .comps = 1, .size = 4, .float = true },
    .{ .vk = 101, .fmt = .rg32ui, .storage = true, .bytes = 8, .filter = false, .comps = 2, .size = 4, .integer = true },
    .{ .vk = 102, .fmt = .rg32i, .storage = true, .bytes = 8, .filter = false, .comps = 2, .size = 4, .integer = true, .signed = true },
    .{ .vk = 103, .fmt = .rg32f, .storage = true, .bytes = 8, .filter = false, .comps = 2, .size = 4, .float = true },
    .{ .vk = 107, .fmt = .rgba32ui, .storage = true, .bytes = 16, .filter = false, .comps = 4, .size = 4, .integer = true },
    .{ .vk = 108, .fmt = .rgba32i, .storage = true, .bytes = 16, .filter = false, .comps = 4, .size = 4, .integer = true, .signed = true },
    .{ .vk = 109, .fmt = .rgba32f, .storage = true, .bytes = 16, .filter = false, .comps = 4, .size = 4, .float = true },
    // images: depth and stencil (all d24s8 in memory)
    .{ .vk = 124, .fmt = .d24s8, .bytes = 4, .aspects = D, .depth = .unorm16 },
    .{ .vk = 125, .fmt = .d24s8, .bytes = 4, .aspects = D, .depth = .unorm24 },
    .{ .vk = 126, .fmt = .d24s8, .bytes = 4, .aspects = D, .depth = .float32 },
    .{ .vk = 127, .fmt = .d24s8, .bytes = 4, .aspects = S, .filter = false },
    .{ .vk = 129, .fmt = .d24s8, .bytes = 4, .aspects = D | S, .depth = .unorm24 },
    .{ .vk = 130, .fmt = .d24s8, .bytes = 4, .aspects = D | S, .depth = .float32 },
};

/// Vertex attribute formats that are not image formats here.
pub const vertex_only = [_]Info{
    .{ .vk = 13, .fmt = .r8, .bytes = 1, .comps = 1, .size = 1, .integer = true },
    .{ .vk = 10, .fmt = .r8, .bytes = 1, .comps = 1, .size = 1, .signed = true, .norm = true },
    .{ .vk = 17, .fmt = .rg8, .bytes = 2, .comps = 2, .size = 1, .signed = true, .norm = true },
    .{ .vk = 20, .fmt = .rg8, .bytes = 2, .comps = 2, .size = 1, .integer = true },
    .{ .vk = 21, .fmt = .rg8, .bytes = 2, .comps = 2, .size = 1, .integer = true, .signed = true },
    .{ .vk = 38, .fmt = .rgba8, .bytes = 4, .comps = 4, .size = 1, .signed = true, .norm = true },
    .{ .vk = 41, .fmt = .rgba8, .bytes = 4, .comps = 4, .size = 1, .integer = true },
    .{ .vk = 42, .fmt = .rgba8, .bytes = 4, .comps = 4, .size = 1, .integer = true, .signed = true },
    .{ .vk = 78, .fmt = .rg16, .bytes = 4, .comps = 2, .size = 2, .signed = true, .norm = true },
    .{ .vk = 81, .fmt = .rg16, .bytes = 4, .comps = 2, .size = 2, .integer = true },
    .{ .vk = 82, .fmt = .rg16, .bytes = 4, .comps = 2, .size = 2, .integer = true, .signed = true },
    .{ .vk = 83, .fmt = .rg16, .bytes = 4, .comps = 2, .size = 2, .float = true },
    .{ .vk = 91, .fmt = .rgba8, .bytes = 8, .comps = 4, .size = 2, .norm = true },
    .{ .vk = 92, .fmt = .rgba8, .bytes = 8, .comps = 4, .size = 2, .signed = true, .norm = true },
    .{ .vk = 95, .fmt = .rgba8, .bytes = 8, .comps = 4, .size = 2, .integer = true },
    .{ .vk = 96, .fmt = .rgba8, .bytes = 8, .comps = 4, .size = 2, .integer = true, .signed = true },
    .{ .vk = 97, .fmt = .rgba8, .bytes = 8, .comps = 4, .size = 2, .float = true },
    .{ .vk = 104, .fmt = .rgba32ui, .bytes = 12, .comps = 3, .size = 4, .integer = true },
    .{ .vk = 105, .fmt = .rgba32i, .bytes = 12, .comps = 3, .size = 4, .integer = true, .signed = true },
    .{ .vk = 106, .fmt = .rgba32f, .bytes = 12, .comps = 3, .size = 4, .float = true },
};

/// The image format `vk` (null: none here).
pub fn image(vk: u32) ?*const Info {
    for (&table) |*x| if (x.vk == vk) return x;
    return null;
}

/// The vertex attribute format `vk` (null: none here).
pub fn vertex(vk: u32) ?*const Info {
    for (&table) |*x| if (x.vk == vk and x.comps != 0) return x;
    for (&vertex_only) |*x| if (x.vk == vk) return x;
    return null;
}

/// vkGetPhysicalDeviceFormatProperties' three masks.
pub const Props = struct { linear: u32, optimal: u32, buffer: u32 };

pub fn props(vk: u32) Props {
    var p = Props{ .linear = 0, .optimal = 0, .buffer = 0 };
    if (vertex(vk) != null) p.buffer |= Feature.vertex_buffer;
    const x = image(vk) orelse return p;
    var o: u32 = Feature.sampled | Feature.transfer_src | Feature.transfer_dst;
    if (x.filter) o |= Feature.filter_linear;
    if (x.storage) o |= Feature.storage;
    if (x.aspects & (D | S) != 0) {
        o |= Feature.depth_stencil;
    } else if (x.render) {
        o |= Feature.color_attachment | Feature.color_blend | Feature.blit_src | Feature.blit_dst;
    }
    p.optimal = o;
    // (linear images: the same layout, colour formats only)
    if (x.aspects == ASPECT_COLOR) p.linear = o;
    return p;
}

test "format: the depth formats WebGPU needs are depth-stencil attachments, sampled" {
    for ([_]u32{ 124, 125, 126, 127, 129, 130 }) |f| {
        const p = props(f);
        try std.testing.expect(p.optimal & Feature.depth_stencil != 0);
        try std.testing.expect(p.optimal & Feature.sampled != 0);
    }
    try std.testing.expect(props(37).optimal & Feature.color_attachment != 0);
    try std.testing.expect(props(43).optimal & Feature.color_attachment == 0);
    try std.testing.expectEqual(@as(u32, 0), props(97).optimal);
    try std.testing.expect(props(97).buffer & Feature.vertex_buffer != 0);
    try std.testing.expect(props(106).buffer & Feature.vertex_buffer != 0);
}
