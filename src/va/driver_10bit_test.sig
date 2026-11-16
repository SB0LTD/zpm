//! @zpm/va driver tests, 10-bit — P010 surfaces through the driver over
//! the fake node: made in VRAM (black: Y 16, UV 128 at the top of each
//! 2-byte sample), exported block linear as R16 + GR1616 with their
//! modifiers (Blackwell's 16-bit sector layout for Y, Turing's for the
//! 32-bit UV pairs), and a P010 image read back through the converter.

const std = @import("std");
const va = @import("vaapi.sig");
const tiling = @import("tiling.sig");
const node = @import("node.sig");
const driver = @import("driver.sig");
const convert = @import("convert.sig");

const testing = std.testing;
const Fake = node.Fake;
const TestDriver = driver.Driver(*Fake);

test "driver: P010 surfaces: VRAM, black, exported R16 + GR1616 block linear, read back as a P010 image" {
    var k = Fake{};
    var d: TestDriver = .{ .node = .{ .sys = &k } };
    try testing.expectEqual(va.SUCCESS, d.init(3, .{}));
    defer d.terminate();
    var cfg: u32 = 0;
    try testing.expectEqual(va.SUCCESS, d.createConfig(va.PROFILE_HEVC_MAIN10, va.ENTRYPOINT_VLD, &.{.{ .type = va.ATTRIB_RT_FORMAT, .value = va.RT_FORMAT_YUV420_10 }}, &cfg));
    var ids: [2]u32 = undefined;
    // (a P010 pixel format with an 8-bit render target: refused)
    const p010 = [_]va.SurfaceAttrib{driver.intAttrib(va.SURFACE_ATTRIB_PIXEL_FORMAT, va.SURFACE_ATTRIB_SETTABLE, va.FOURCC_P010)};
    try testing.expectEqual(va.ERROR_UNSUPPORTED_RT_FORMAT, d.createSurfaces(va.RT_FORMAT_YUV420, 40, 24, &ids, &p010));
    try testing.expectEqual(va.SUCCESS, d.createSurfaces(va.RT_FORMAT_YUV420_10, 40, 24, &ids, &p010));
    const s = &d.surfaces[ids[0] - driver.SURFACE_BASE];
    try testing.expectEqual(@as(u8, 2), s.layout.sample_bytes);
    try testing.expect(k.bufs[s.tiled.handle].vram);
    // 40 samples: 80 bytes, a row of two GOBs (128 bytes); rows to 128
    try testing.expectEqual(@as(u32, 128), s.layout.luma.pitch);
    try testing.expectEqual(@as(u32, 128), s.layout.chroma.pitch);
    // black: every Y sample 16 << 8, every U and V 128 << 8
    const t = s.tiled.bytes();
    const at_uv: usize = @intCast(s.layout.chroma_offset);
    try testing.expectEqual(@as(u16, 16 << 8), std.mem.readInt(u16, t[s.layout.luma.offsetOf(.blackwell16, 2 * 39, 23)..][0..2], .little));
    try testing.expectEqual(@as(u16, 128 << 8), std.mem.readInt(u16, t[at_uv + s.layout.chroma.offsetOf(.turing2d, 4 * 19 + 2, 11)..][0..2], .little));

    // the export: R16 and GR1616, two objects of the one dma-buf
    var desc: va.DrmPrimeDescriptor = undefined;
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(ids[0], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_READ_ONLY | va.EXPORT_SURFACE_SEPARATE_LAYERS, &desc));
    try testing.expectEqual(va.FOURCC_P010, desc.fourcc);
    try testing.expectEqual(@as(u32, 2), desc.num_objects);
    try testing.expectEqual(tiling.modifierOf(.blackwell16), desc.objects[0].drm_format_modifier);
    try testing.expectEqual(tiling.modifierOf(.turing2d), desc.objects[1].drm_format_modifier);
    try testing.expectEqual(va.DRM_FORMAT_R16, desc.layers[0].drm_format);
    try testing.expectEqual(va.DRM_FORMAT_GR1616, desc.layers[1].drm_format);
    try testing.expectEqual(@as(u32, 128), desc.layers[0].pitch[0]);
    try testing.expectEqual(@as(u32, @intCast(s.layout.chroma_offset)), desc.layers[1].offset[0]);
    try testing.expectEqual(@as(u32, 1), desc.layers[1].object_index[0]);
    try testing.expectEqual(va.SUCCESS, d.exportSurfaceHandle(ids[0], va.MEM_TYPE_DRM_PRIME_2, va.EXPORT_SURFACE_COMPOSED_LAYERS, &desc));
    try testing.expectEqual(va.DRM_FORMAT_P010, desc.layers[0].drm_format);
    try testing.expectEqual([3]u32{ 0, 0, 0 }, d.conversions);

    // a "decoded" picture (written where the decoder would), read back as
    // a P010 image: converted once, the samples as written
    const lin = tiling.Linear.ofDepth(40, 24, 2);
    var pic: [8192]u8 = undefined;
    for (pic[0..lin.bytes], 0..) |*b, i| b.* = @truncate(i *% 37 + 11);
    tiling.convertPicture(s.layout, lin, .blackwell, t, &pic, 40, 24, false);
    s.linear_stale = true;
    var img: va.Image = undefined;
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.P010_FORMAT, 40, 24, &img));
    try testing.expectEqual(@as(u32, 24), img.format.bits_per_pixel);
    try testing.expectEqual([3]u32{ 128, 128, 0 }, img.pitches);
    try testing.expectEqual(va.SUCCESS, d.getImage(ids[0], 0, 0, 40, 24, img.image_id));
    try testing.expectEqual(@as(u32, 1), d.conversions[@intFromEnum(convert.Done.cpu)]);
    var p: ?*anyopaque = null;
    try testing.expectEqual(va.SUCCESS, d.mapBuffer(img.buf, &p));
    const got: [*]const u8 = @ptrCast(p.?);
    for (0..24) |y| try testing.expectEqualSlices(u8, pic[y * lin.pitch ..][0..80], got[y * img.pitches[0] ..][0..80]);
    for (0..12) |y| try testing.expectEqualSlices(u8, pic[lin.uv_offset + y * lin.pitch ..][0..80], got[img.offsets[1] + y * img.pitches[1] ..][0..80]);
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
    // (an NV12 image for a P010 surface: refused)
    try testing.expectEqual(va.SUCCESS, d.createImage(&va.NV12_FORMAT, 40, 24, &img));
    try testing.expectEqual(va.ERROR_INVALID_IMAGE_FORMAT, d.getImage(ids[0], 0, 0, 40, 24, img.image_id));
    try testing.expectEqual(va.SUCCESS, d.destroyImage(img.image_id));
    try testing.expectEqual(va.SUCCESS, d.destroySurfaces(&ids));
}
