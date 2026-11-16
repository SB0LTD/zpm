//! @zpm/gfxapi texfmt — GL ES's texture formats as the engine stores
//! them. Each upload GL ES 3.0 allows (an internal format, a format and a
//! type; ES 2.0's unsized ones; OES_texture_float's and _half_float's;
//! EXT_texture_format_BGRA8888's) is an engine format, a conversion of
//! the client's texels, and a swizzle:
//!
//! - unorm8 RGBA (RGBA8, SRGB8_ALPHA8, RGB8 widened, the packed 16-bit
//!   ones unpacked) and BGRA (as is);
//! - R8 and RG8 (and LUMINANCE, ALPHA, LUMINANCE_ALPHA: swizzled);
//! - f32 x 1, 2, 4 (the half floats widened, RGB with alpha 1; and
//!   EXT_texture_norm16's R16 to RGBA16 and their SNORMs, normalised:
//!   sampled as GL says, never drawn into);
//! - i32 and u32 x 1, 2, 4 (the 8- and 16-bit ones widened).
//!
//! Not yet: RGB10_A2, R11F_G11F_B10F, RGB9_E5, the RGB integer formats,
//! depth32f, compressed formats.

const std = @import("std");
const engine = @import("engine.sig");
const g = @import("glenum.sig");
const texture = @import("texture.sig");
const Format = engine.Format;

pub const Conv = enum {
    /// the client's bytes as they are
    raw,
    /// RGB bytes, alpha 255
    rgb8,
    /// the packed 16-bit pixels to RGBA bytes
    rgb565,
    rgba4,
    rgb5a1,
    /// RGB f32, alpha 1
    rgbf32,
    /// halves to f32 (the store's channels each)
    half,
    /// RGB halves to f32, alpha 1
    half_rgb,
    /// unorm16s to f32 (v / 65535), and RGB ones with alpha 1
    unorm16,
    unorm16_rgb,
    /// snorm16s to f32 (max(v / 32767, -1)), and RGB ones with alpha 1
    snorm16,
    snorm16_rgb,
    /// 8- and 16-bit ints widened
    int8,
    uint8,
    int16,
    uint16,
    depth16,
    depth32,
    depth24_stencil8,
};

const Z = texture.SWZ_ZERO;
const O = texture.SWZ_ONE;

pub const Upload = struct {
    store: Format,
    conv: Conv = .raw,
    /// bytes a client texel takes
    client_bytes: u32 = 4,
    /// the texel's channels as GL's R, G, B, A (LUMINANCE ...)
    swizzle: [4]u3 = .{ 0, 1, 2, 3 },
    srgb: bool = false,
};

const E = struct { internal: u32, format: u32, ty: u32, up: Upload };

const L1 = [4]u3{ 0, 0, 0, O };
const A1 = [4]u3{ Z, Z, Z, 0 };
const LA = [4]u3{ 0, 0, 0, 1 };

fn e(internal: u32, format: u32, ty: u32, store: Format, conv: Conv, cb: u32) E {
    return .{ .internal = internal, .format = format, .ty = ty, .up = .{ .store = store, .conv = conv, .client_bytes = cb } };
}

fn sw(x: E, s: [4]u3) E {
    var y = x;
    y.up.swizzle = s;
    return y;
}

fn srgb(x: E) E {
    var y = x;
    y.up.srgb = true;
    return y;
}

const RG_INTEGER: u32 = 0x8228;
const RED_INTEGER: u32 = 0x8D94;
const HALF_OES: u32 = 0x8D61;

const table = [_]E{
    e(g.DEPTH_COMPONENT16, g.DEPTH_COMPONENT, g.UNSIGNED_SHORT, .d24s8, .depth16, 2),
    e(g.DEPTH_COMPONENT16, g.DEPTH_COMPONENT, g.UNSIGNED_INT, .d24s8, .depth32, 4),
    e(g.DEPTH_COMPONENT24, g.DEPTH_COMPONENT, g.UNSIGNED_INT, .d24s8, .depth32, 4),
    e(g.DEPTH_COMPONENT, g.DEPTH_COMPONENT, g.UNSIGNED_SHORT, .d24s8, .depth16, 2),
    e(g.DEPTH_COMPONENT, g.DEPTH_COMPONENT, g.UNSIGNED_INT, .d24s8, .depth32, 4),
    e(g.DEPTH24_STENCIL8, g.DEPTH_STENCIL, 0x84FA, .d24s8, .depth24_stencil8, 4),
    // ES 2.0's unsized formats (the internal format is the format)
    e(g.RGBA, g.RGBA, g.UNSIGNED_BYTE, .rgba8, .raw, 4),
    e(g.RGBA, g.RGBA, g.UNSIGNED_SHORT_4_4_4_4, .rgba8, .rgba4, 2),
    e(g.RGBA, g.RGBA, g.UNSIGNED_SHORT_5_5_5_1, .rgba8, .rgb5a1, 2),
    e(g.RGBA, g.RGBA, g.FLOAT, .rgba32f, .raw, 16),
    e(g.RGBA, g.RGBA, HALF_OES, .rgba32f, .half, 8),
    e(g.RGBA, g.RGBA, g.HALF_FLOAT, .rgba32f, .half, 8),
    e(g.RGB, g.RGB, g.UNSIGNED_BYTE, .rgba8, .rgb8, 3),
    e(g.RGB, g.RGB, g.UNSIGNED_SHORT_5_6_5, .rgba8, .rgb565, 2),
    e(g.RGB, g.RGB, g.FLOAT, .rgba32f, .rgbf32, 12),
    e(g.RGB, g.RGB, HALF_OES, .rgba32f, .half_rgb, 6),
    e(g.RGB, g.RGB, g.HALF_FLOAT, .rgba32f, .half_rgb, 6),
    sw(e(g.LUMINANCE, g.LUMINANCE, g.UNSIGNED_BYTE, .r8, .raw, 1), L1),
    sw(e(g.ALPHA, g.ALPHA, g.UNSIGNED_BYTE, .r8, .raw, 1), A1),
    sw(e(g.LUMINANCE_ALPHA, g.LUMINANCE_ALPHA, g.UNSIGNED_BYTE, .rg8, .raw, 2), LA),
    sw(e(g.LUMINANCE, g.LUMINANCE, g.FLOAT, .r32f, .raw, 4), L1),
    sw(e(g.ALPHA, g.ALPHA, g.FLOAT, .r32f, .raw, 4), A1),
    sw(e(g.LUMINANCE_ALPHA, g.LUMINANCE_ALPHA, g.FLOAT, .rg32f, .raw, 8), LA),
    sw(e(g.LUMINANCE, g.LUMINANCE, HALF_OES, .r32f, .half, 2), L1),
    sw(e(g.ALPHA, g.ALPHA, HALF_OES, .r32f, .half, 2), A1),
    sw(e(g.LUMINANCE_ALPHA, g.LUMINANCE_ALPHA, HALF_OES, .rg32f, .half, 4), LA),
    e(g.BGRA_EXT, g.BGRA_EXT, g.UNSIGNED_BYTE, .bgra8, .raw, 4),
    e(g.RED, g.RED, g.UNSIGNED_BYTE, .r8, .raw, 1),
    e(g.RG, g.RG, g.UNSIGNED_BYTE, .rg8, .raw, 2),
    // ES 3.0's sized formats
    e(g.RGBA8, g.RGBA, g.UNSIGNED_BYTE, .rgba8, .raw, 4),
    srgb(e(g.SRGB8_ALPHA8, g.RGBA, g.UNSIGNED_BYTE, .rgba8, .raw, 4)),
    e(g.RGB8, g.RGB, g.UNSIGNED_BYTE, .rgba8, .rgb8, 3),
    srgb(e(g.SRGB8, g.RGB, g.UNSIGNED_BYTE, .rgba8, .rgb8, 3)),
    e(g.RGB565, g.RGB, g.UNSIGNED_BYTE, .rgba8, .rgb8, 3),
    e(g.RGB565, g.RGB, g.UNSIGNED_SHORT_5_6_5, .rgba8, .rgb565, 2),
    e(g.RGBA4, g.RGBA, g.UNSIGNED_BYTE, .rgba8, .raw, 4),
    e(g.RGBA4, g.RGBA, g.UNSIGNED_SHORT_4_4_4_4, .rgba8, .rgba4, 2),
    e(g.RGB5_A1, g.RGBA, g.UNSIGNED_BYTE, .rgba8, .raw, 4),
    e(g.RGB5_A1, g.RGBA, g.UNSIGNED_SHORT_5_5_5_1, .rgba8, .rgb5a1, 2),
    e(g.BGRA8_EXT, g.BGRA_EXT, g.UNSIGNED_BYTE, .bgra8, .raw, 4),
    e(g.R8, g.RED, g.UNSIGNED_BYTE, .r8, .raw, 1),
    e(g.RG8, g.RG, g.UNSIGNED_BYTE, .rg8, .raw, 2),
    e(g.R16F, g.RED, g.HALF_FLOAT, .r32f, .half, 2),
    e(g.R16F, g.RED, g.FLOAT, .r32f, .raw, 4),
    e(g.R32F, g.RED, g.FLOAT, .r32f, .raw, 4),
    e(g.RG16F, g.RG, g.HALF_FLOAT, .rg32f, .half, 4),
    e(g.RG16F, g.RG, g.FLOAT, .rg32f, .raw, 8),
    e(g.RG32F, g.RG, g.FLOAT, .rg32f, .raw, 8),
    e(g.RGB16F, g.RGB, g.HALF_FLOAT, .rgba32f, .half_rgb, 6),
    e(g.RGB16F, g.RGB, g.FLOAT, .rgba32f, .rgbf32, 12),
    e(g.RGB32F, g.RGB, g.FLOAT, .rgba32f, .rgbf32, 12),
    e(g.RGBA16F, g.RGBA, g.HALF_FLOAT, .rgba32f, .half, 8),
    e(g.RGBA16F, g.RGBA, g.FLOAT, .rgba32f, .raw, 16),
    e(g.RGBA32F, g.RGBA, g.FLOAT, .rgba32f, .raw, 16),
    // EXT_texture_norm16 (video's 10- to 16-bit planes): stored as floats
    e(g.R16_EXT, g.RED, g.UNSIGNED_SHORT, .r32f, .unorm16, 2),
    e(g.RG16_EXT, g.RG, g.UNSIGNED_SHORT, .rg32f, .unorm16, 4),
    e(g.RGB16_EXT, g.RGB, g.UNSIGNED_SHORT, .rgba32f, .unorm16_rgb, 6),
    e(g.RGBA16_EXT, g.RGBA, g.UNSIGNED_SHORT, .rgba32f, .unorm16, 8),
    e(g.R16_SNORM_EXT, g.RED, g.SHORT, .r32f, .snorm16, 2),
    e(g.RG16_SNORM_EXT, g.RG, g.SHORT, .rg32f, .snorm16, 4),
    e(g.RGB16_SNORM_EXT, g.RGB, g.SHORT, .rgba32f, .snorm16_rgb, 6),
    e(g.RGBA16_SNORM_EXT, g.RGBA, g.SHORT, .rgba32f, .snorm16, 8),
    e(g.R8I, RED_INTEGER, g.BYTE, .r32i, .int8, 1),
    e(g.R8UI, RED_INTEGER, g.UNSIGNED_BYTE, .r32ui, .uint8, 1),
    e(g.R16I, RED_INTEGER, g.SHORT, .r32i, .int16, 2),
    e(g.R16UI, RED_INTEGER, g.UNSIGNED_SHORT, .r32ui, .uint16, 2),
    e(g.R32I, RED_INTEGER, g.INT, .r32i, .raw, 4),
    e(g.R32UI, RED_INTEGER, g.UNSIGNED_INT, .r32ui, .raw, 4),
    e(g.RG8I, RG_INTEGER, g.BYTE, .rg32i, .int8, 2),
    e(g.RG8UI, RG_INTEGER, g.UNSIGNED_BYTE, .rg32ui, .uint8, 2),
    e(g.RG16I, RG_INTEGER, g.SHORT, .rg32i, .int16, 4),
    e(g.RG16UI, RG_INTEGER, g.UNSIGNED_SHORT, .rg32ui, .uint16, 4),
    e(g.RG32I, RG_INTEGER, g.INT, .rg32i, .raw, 8),
    e(g.RG32UI, RG_INTEGER, g.UNSIGNED_INT, .rg32ui, .raw, 8),
    e(g.RGBA8I, g.RGBA_INTEGER, g.BYTE, .rgba32i, .int8, 4),
    e(g.RGBA8UI, g.RGBA_INTEGER, g.UNSIGNED_BYTE, .rgba32ui, .uint8, 4),
    e(g.RGBA16I, g.RGBA_INTEGER, g.SHORT, .rgba32i, .int16, 8),
    e(g.RGBA16UI, g.RGBA_INTEGER, g.UNSIGNED_SHORT, .rgba32ui, .uint16, 8),
    e(g.RGBA32I, g.RGBA_INTEGER, g.INT, .rgba32i, .raw, 16),
    e(g.RGBA32UI, g.RGBA_INTEGER, g.UNSIGNED_INT, .rgba32ui, .raw, 16),
};

/// What an upload of (internal, format, type) stores, or GL's error.
pub fn upload(internal: u32, format: u32, ty: u32) union(enum) { ok: Upload, err: u32 } {
    for (table) |x| {
        if (x.internal == internal and x.format == format and x.ty == ty) return .{ .ok = x.up };
    }
    // a known internal format with a format and type it does not take
    for (table) |x| {
        if (x.internal == internal) return .{ .err = g.INVALID_OPERATION };
    }
    return .{ .err = if (internal == g.DEPTH_COMPONENT16 or internal == g.DEPTH_COMPONENT24 or internal == g.DEPTH24_STENCIL8 or internal == g.DEPTH_COMPONENT) g.INVALID_OPERATION else g.INVALID_VALUE };
}

/// What a sized internal format stores (glTexStorage2D), or null.
pub fn storage(internal: u32) ?Upload {
    for (table) |x| {
        // (the sized ones: not one of ES 2.0's unsized names)
        if (x.internal == internal and x.internal != x.format) return x.up;
    }
    return null;
}

/// What a texture stored as `store` takes from (format, type) for a
/// glTexSubImage2D: an upload that stores the same, if any.
pub fn subUpload(store: Format, format: u32, ty: u32) ?Upload {
    for (table) |x| {
        if (x.format == format and x.ty == ty and x.up.store == store) return x.up;
    }
    return null;
}

/// Whether (format, type) is a pair some upload takes.
pub fn known(format: u32, ty: u32) bool {
    for (table) |x| {
        if (x.format == format and x.ty == ty) return true;
    }
    return false;
}

/// One row: n client texels from `src` into the stored texels at `dst`.
pub fn convert(up: Upload, src: []const u8, dst: []u8, n: u32) void {
    const ch = up.store.channels();
    const sb = up.store.bytes();
    switch (up.conv) {
        .raw => @memcpy(dst[0 .. n * sb], src[0 .. n * sb]),
        .depth16 => for (0..n) |i| {
            const value: u32 = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
            std.mem.writeInt(u32, dst[i * 4 ..][0..4], value << 8 | value >> 8, .little);
        },
        .depth32, .depth24_stencil8 => for (0..n) |i| {
            const value = std.mem.readInt(u32, src[i * 4 ..][0..4], .little);
            const stencil = if (up.conv == .depth24_stencil8) value << 24 else 0;
            std.mem.writeInt(u32, dst[i * 4 ..][0..4], value >> 8 | stencil, .little);
        },
        .rgb8 => for (0..n) |i| {
            dst[i * 4 ..][0..3].* = src[i * 3 ..][0..3].*;
            dst[i * 4 + 3] = 255;
        },
        .rgb565, .rgba4, .rgb5a1 => for (0..n) |i| {
            const v = std.mem.readInt(u16, src[i * 2 ..][0..2], .little);
            const px: [4]u8 = switch (up.conv) {
                .rgb565 => .{ widen(v >> 11, 5), widen(v >> 5, 6), widen(v, 5), 255 },
                .rgba4 => .{ widen(v >> 12, 4), widen(v >> 8, 4), widen(v >> 4, 4), widen(v, 4) },
                else => .{ widen(v >> 11, 5), widen(v >> 6, 5), widen(v >> 1, 5), widen(v, 1) },
            };
            dst[i * 4 ..][0..4].* = px;
        },
        .rgbf32 => for (0..n) |i| {
            @memcpy(dst[i * 16 ..][0..12], src[i * 12 ..][0..12]);
            std.mem.writeInt(u32, dst[i * 16 + 12 ..][0..4], @bitCast(@as(f32, 1)), .little);
        },
        .half, .half_rgb, .unorm16, .unorm16_rgb, .snorm16, .snorm16_rgb => {
            const sc: u32 = switch (up.conv) {
                .half_rgb, .unorm16_rgb, .snorm16_rgb => 3,
                else => ch,
            };
            for (0..n) |i| {
                for (0..ch) |c| {
                    const v: f32 = if (c < sc) short(up.conv, std.mem.readInt(u16, src[(i * sc + c) * 2 ..][0..2], .little)) else 1;
                    std.mem.writeInt(u32, dst[(i * ch + c) * 4 ..][0..4], @bitCast(v), .little);
                }
            }
        },
        .int8, .uint8, .int16, .uint16 => for (0..n * ch) |j| {
            const v: u32 = switch (up.conv) {
                .int8 => @bitCast(@as(i32, @as(i8, @bitCast(src[j])))),
                .uint8 => src[j],
                .int16 => @bitCast(@as(i32, std.mem.readInt(i16, src[j * 2 ..][0..2], .little))),
                else => std.mem.readInt(u16, src[j * 2 ..][0..2], .little),
            };
            std.mem.writeInt(u32, dst[j * 4 ..][0..4], v, .little);
        },
    }
}

/// A client's 16-bit channel as the float stored: a half widened, or a
/// unorm16 or snorm16 normalised (as GL ES 3.0 converts signed
/// normalised values: -32768 is -1 too).
fn short(conv: Conv, bits: u16) f32 {
    return switch (conv) {
        .half, .half_rgb => @floatCast(@as(f16, @bitCast(bits))),
        .unorm16, .unorm16_rgb => @as(f32, @floatFromInt(bits)) / 65535.0,
        else => @max(@as(f32, @floatFromInt(@as(i16, @bitCast(bits)))) / 32767.0, -1),
    };
}

/// A `bits`-bit unorm channel (the low bits of v) as a byte, rounded.
fn widen(v: u16, bits: u4) u8 {
    const max: u32 = (@as(u32, 1) << bits) - 1;
    const x: u32 = v & max;
    return @intCast((x * 255 * 2 + max) / (2 * max));
}

test "texfmt: uploads and their conversions" {
    const up = upload(g.RGB, g.RGB, g.UNSIGNED_SHORT_5_6_5).ok;
    try std.testing.expectEqual(Format.rgba8, up.store);
    var dst: [8]u8 = undefined;
    // pure red, then white
    convert(up, &.{ 0x00, 0xf8, 0xff, 0xff }, &dst, 2);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 255, 255, 255, 255 }, &dst);
    const lum = upload(g.LUMINANCE, g.LUMINANCE, g.UNSIGNED_BYTE).ok;
    try std.testing.expectEqual(Format.r8, lum.store);
    try std.testing.expectEqual(@as(u3, texture.SWZ_ONE), lum.swizzle[3]);
    const h = upload(g.RGBA16F, g.RGBA, g.HALF_FLOAT).ok;
    var hf: [16]u8 = undefined;
    // 1.0, -2.0, 0.5, 0 as halves
    convert(h, &.{ 0x00, 0x3c, 0x00, 0xc0, 0x00, 0x38, 0x00, 0x00 }, &hf, 1);
    try std.testing.expectEqual(@as(f32, -2), @as(f32, @bitCast(std.mem.readInt(u32, hf[4..8], .little))));
    const i8u = upload(g.RGBA8I, g.RGBA_INTEGER, g.BYTE).ok;
    var iv: [16]u8 = undefined;
    convert(i8u, &.{ 0xff, 1, 0x80, 0 }, &iv, 1);
    try std.testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, iv[0..4], .little));
    try std.testing.expectEqual(@as(i32, -128), std.mem.readInt(i32, iv[8..12], .little));
    try std.testing.expectEqual(g.INVALID_OPERATION, upload(g.RGBA8, g.RGB, g.UNSIGNED_BYTE).err);
    try std.testing.expect(storage(g.RGBA) == null);
    try std.testing.expectEqual(Format.rg32f, storage(g.RG16F).?.store);
}

fn f32At(b: []const u8, i: usize) f32 {
    return @bitCast(std.mem.readInt(u32, b[i * 4 ..][0..4], .little));
}

test "texfmt: EXT_texture_norm16's uploads, normalised to floats" {
    const T = std.testing;
    // R16: 0, 32768, 65535
    const r = upload(g.R16_EXT, g.RED, g.UNSIGNED_SHORT).ok;
    try T.expectEqual(Format.r32f, r.store);
    try T.expectEqual(@as(u32, 2), r.client_bytes);
    var rv: [12]u8 = undefined;
    convert(r, &.{ 0, 0, 0x00, 0x80, 0xff, 0xff }, &rv, 3);
    try T.expectEqual(@as(f32, 0), f32At(&rv, 0));
    try T.expectApproxEqAbs(@as(f32, 0.5), f32At(&rv, 1), 1e-4);
    try T.expectEqual(@as(f32, 1), f32At(&rv, 2));
    // RG16 and RGBA16 stored per channel; RGB16 with alpha 1
    try T.expectEqual(Format.rg32f, upload(g.RG16_EXT, g.RG, g.UNSIGNED_SHORT).ok.store);
    const rgba = upload(g.RGBA16_EXT, g.RGBA, g.UNSIGNED_SHORT).ok;
    try T.expectEqual(Format.rgba32f, rgba.store);
    const rgb = upload(g.RGB16_EXT, g.RGB, g.UNSIGNED_SHORT).ok;
    try T.expectEqual(@as(u32, 6), rgb.client_bytes);
    var cv: [16]u8 = undefined;
    convert(rgb, &.{ 0xff, 0xff, 0, 0, 0x00, 0x40 }, &cv, 1);
    try T.expectEqual(@as(f32, 1), f32At(&cv, 0));
    try T.expectEqual(@as(f32, 0), f32At(&cv, 1));
    try T.expectApproxEqAbs(@as(f32, 0.25), f32At(&cv, 2), 1e-4);
    try T.expectEqual(@as(f32, 1), f32At(&cv, 3));
    // SNORM: 32767, -32767 and -32768 (both -1), 0
    const s = upload(g.RGBA16_SNORM_EXT, g.RGBA, g.SHORT).ok;
    convert(s, &.{ 0xff, 0x7f, 0x01, 0x80, 0x00, 0x80, 0, 0 }, &cv, 1);
    try T.expectEqual(@as(f32, 1), f32At(&cv, 0));
    try T.expectEqual(@as(f32, -1), f32At(&cv, 1));
    try T.expectEqual(@as(f32, -1), f32At(&cv, 2));
    try T.expectEqual(@as(f32, 0), f32At(&cv, 3));
    // glTexStorage2D and glTexSubImage2D take them
    try T.expectEqual(Format.r32f, storage(g.R16_EXT).?.store);
    try T.expectEqual(Format.rgba32f, storage(g.RGBA16_EXT).?.store);
    try T.expectEqual(Conv.unorm16, subUpload(.rg32f, g.RG, g.UNSIGNED_SHORT).?.conv);
    // a format and type R16 does not take
    try T.expectEqual(g.INVALID_OPERATION, upload(g.R16_EXT, g.RED, g.FLOAT).err);
}
