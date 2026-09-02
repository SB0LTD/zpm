// png_decode — pure-Sig PNG decoder to RGBA8.
// Layer 0: Core. No allocator, no platform deps.
//
// Decodes the PNG spec's non-interlaced images across every color type and bit
// depth into a tightly packed 8-bit RGBA buffer (row-major, top-left origin):
//
//   color type 0  greyscale            (1/2/4/8/16-bit)
//   color type 2  truecolor RGB        (8/16-bit)
//   color type 3  palette (PLTE+tRNS)  (1/2/4/8-bit)
//   color type 4  greyscale + alpha    (8/16-bit)
//   color type 6  truecolor RGBA       (8/16-bit)
//
// All buffers are caller-provided. The caller sizes:
//   • scratch   — holds the concatenated zlib/IDAT stream (>= sum of IDAT bytes)
//   • raw       — holds the inflated filtered scanlines (>= (stride+1)*height)
//   • out       — holds the final RGBA8 image (>= width*height*4)
//
// Adam7 interlacing is detected and rejected (rare for UI screenshots); every
// other conforming PNG decodes.

const inflate = @import("inflate");

/// Local byte-slice equality (avoids a second module dependency; png_decode
/// only needs this one helper from the shared mem utilities).
fn eqlBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub const PngError = error{
    BadSignature,
    Truncated,
    BadChunk,
    UnsupportedColorType,
    UnsupportedBitDepth,
    InterlaceUnsupported,
    MissingPalette,
    ScratchTooSmall,
    RawTooSmall,
    OutputTooSmall,
    InflateFailed,
    BadFilter,
};

pub const Info = struct {
    width: u32,
    height: u32,
    color_type: u8,
    bit_depth: u8,
};

pub const Decoded = struct {
    /// Tightly packed RGBA8, row-major, top-left origin. Slices into `out`.
    pixels: []u8,
    width: u32,
    height: u32,
};

const SIGNATURE = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

fn be32(b: []const u8, off: usize) u32 {
    return (@as(u32, b[off]) << 24) | (@as(u32, b[off + 1]) << 16) |
        (@as(u32, b[off + 2]) << 8) | @as(u32, b[off + 3]);
}

/// Read just the IHDR fields without decoding pixels.
pub fn readInfo(data: []const u8) PngError!Info {
    if (data.len < 8 or !eqlBytes(data[0..8], &SIGNATURE)) return error.BadSignature;
    // First chunk must be IHDR at offset 8.
    if (data.len < 8 + 8 + 13 + 4) return error.Truncated;
    const len = be32(data, 8);
    if (len != 13 or !eqlBytes(data[12..16], "IHDR")) return error.BadChunk;
    return .{
        .width = be32(data, 16),
        .height = be32(data, 20),
        .bit_depth = data[24],
        .color_type = data[25],
    };
}

fn channels(color_type: u8) PngError!u8 {
    return switch (color_type) {
        0 => 1, // greyscale
        2 => 3, // RGB
        3 => 1, // palette index
        4 => 2, // greyscale + alpha
        6 => 4, // RGBA
        else => error.UnsupportedColorType,
    };
}

fn paeth(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = if (p > a) p - a else a - p;
    const pb = if (p > b) p - b else b - p;
    const pc = if (p > c) p - c else c - p;
    if (pa <= pb and pa <= pc) return @intCast(a & 0xff);
    if (pb <= pc) return @intCast(b & 0xff);
    return @intCast(c & 0xff);
}

/// Decode a PNG into RGBA8. See module header for buffer sizing.
pub fn decode(data: []const u8, scratch: []u8, raw: []u8, out: []u8) PngError!Decoded {
    const info = try readInfo(data);
    const width = info.width;
    const height = info.height;
    const bit_depth = info.bit_depth;
    const color_type = info.color_type;

    if (width == 0 or height == 0) return error.BadChunk;
    switch (bit_depth) {
        1, 2, 4, 8, 16 => {},
        else => return error.UnsupportedBitDepth,
    }
    const nchan = try channels(color_type);

    // ── Walk chunks: gather IDAT into scratch, capture PLTE/tRNS, detect IHDR interlace ──
    var palette: [256][3]u8 = undefined;
    var palette_len: usize = 0;
    var trns: [256]u8 = @splat(255);
    var trns_len: usize = 0;
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;

    var idat_len: usize = 0;
    var pos: usize = 8;
    while (pos + 8 <= data.len) {
        const clen: usize = @intCast(be32(data, pos));
        const ctype = data[pos + 4 .. pos + 8];
        const body_start = pos + 8;
        if (body_start + clen + 4 > data.len) return error.Truncated;
        const body = data[body_start .. body_start + clen];

        if (eqlBytes(ctype, "IHDR")) {
            // interlace method is byte 12 of IHDR body
            if (clen >= 13 and body[12] != 0) return error.InterlaceUnsupported;
        } else if (eqlBytes(ctype, "PLTE")) {
            palette_len = clen / 3;
            if (palette_len > 256) return error.BadChunk;
            var i: usize = 0;
            while (i < palette_len) : (i += 1) {
                palette[i] = .{ body[i * 3], body[i * 3 + 1], body[i * 3 + 2] };
            }
        } else if (eqlBytes(ctype, "tRNS")) {
            if (color_type == 3) {
                trns_len = clen;
                var i: usize = 0;
                while (i < clen and i < 256) : (i += 1) trns[i] = body[i];
            } else if (color_type == 0 and clen >= 2) {
                trns_gray = (@as(u16, body[0]) << 8) | body[1];
            } else if (color_type == 2 and clen >= 6) {
                trns_rgb = .{
                    (@as(u16, body[0]) << 8) | body[1],
                    (@as(u16, body[2]) << 8) | body[3],
                    (@as(u16, body[4]) << 8) | body[5],
                };
            }
        } else if (eqlBytes(ctype, "IDAT")) {
            if (idat_len + clen > scratch.len) return error.ScratchTooSmall;
            @memcpy(scratch[idat_len .. idat_len + clen], body);
            idat_len += clen;
        } else if (eqlBytes(ctype, "IEND")) {
            break;
        }
        pos = body_start + clen + 4; // skip body + CRC
    }
    if (color_type == 3 and palette_len == 0) return error.MissingPalette;
    if (idat_len < 2) return error.Truncated;

    // ── Inflate the zlib stream (skip 2-byte zlib header) ──
    const bits_per_pixel = @as(usize, nchan) * @as(usize, bit_depth);
    const stride = (bits_per_pixel * @as(usize, width) + 7) / 8; // bytes per scanline
    const need_raw = (stride + 1) * @as(usize, height);
    if (raw.len < need_raw) return error.RawTooSmall;

    var inf = inflate.Inflate.init();
    const res = inf.decompress(scratch[2..idat_len], raw) catch return error.InflateFailed;
    if (res.out_produced < need_raw) return error.InflateFailed;

    // ── Unfilter in place: raw holds (filter_byte + stride) per row ──
    const bpp = (bits_per_pixel + 7) / 8; // bytes/pixel for filter, min 1
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_off = y * (stride + 1);
        const filter = raw[row_off];
        const cur = raw[row_off + 1 .. row_off + 1 + stride];
        const prev_off = if (y == 0) 0 else (y - 1) * (stride + 1) + 1;
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: i32 = if (i >= bpp) cur[i - bpp] else 0;
            const b: i32 = if (y == 0) 0 else raw[prev_off + i];
            const c: i32 = if (y == 0 or i < bpp) 0 else raw[prev_off + i - bpp];
            const x: i32 = cur[i];
            cur[i] = switch (filter) {
                0 => @intCast(x & 0xff),
                1 => @intCast((x + a) & 0xff),
                2 => @intCast((x + b) & 0xff),
                3 => @intCast((x + @divTrunc(a + b, 2)) & 0xff),
                4 => paeth(a, b, c),
                else => return error.BadFilter,
            };
        }
    }

    // ── Expand each scanline to RGBA8 ──
    const need_out = @as(usize, width) * @as(usize, height) * 4;
    if (out.len < need_out) return error.OutputTooSmall;

    y = 0;
    while (y < height) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 .. y * (stride + 1) + 1 + stride];
        const out_row = out[y * @as(usize, width) * 4 ..];
        expandRow(row, out_row, width, color_type, bit_depth, nchan, &palette, palette_len, &trns, trns_len, trns_gray, trns_rgb);
    }

    return .{ .pixels = out[0..need_out], .width = width, .height = height };
}

fn sampleBits(row: []const u8, index: usize, bit_depth: u8) u16 {
    return switch (bit_depth) {
        8 => row[index],
        16 => (@as(u16, row[index * 2]) << 8) | row[index * 2 + 1],
        1, 2, 4 => blk: {
            const per_byte: usize = @intCast(8 / bit_depth);
            const byte = row[index / per_byte];
            const shift: u3 = @intCast((per_byte - 1 - (index % per_byte)) * bit_depth);
            const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
            break :blk (byte >> shift) & mask;
        },
        else => 0,
    };
}

fn scaleTo8(value: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        16 => @intCast(value >> 8),
        8 => @intCast(value),
        4 => @intCast(value * 17), // 0..15 -> 0..255
        2 => @intCast(value * 85), // 0..3  -> 0..255
        1 => if (value != 0) 255 else 0,
        else => 0,
    };
}

fn expandRow(
    row: []const u8,
    out_row: []u8,
    width: u32,
    color_type: u8,
    bit_depth: u8,
    nchan: u8,
    palette: *const [256][3]u8,
    palette_len: usize,
    trns: *const [256]u8,
    trns_len: usize,
    trns_gray: ?u16,
    trns_rgb: ?[3]u16,
) void {
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const o = x * 4;
        switch (color_type) {
            0 => { // greyscale
                const raw_v = sampleBits(row, x, bit_depth);
                const g = scaleTo8(raw_v, bit_depth);
                out_row[o] = g;
                out_row[o + 1] = g;
                out_row[o + 2] = g;
                out_row[o + 3] = if (trns_gray != null and trns_gray.? == raw_v) 0 else 255;
            },
            2 => { // RGB
                const base = x * @as(usize, nchan);
                const r = sampleBits(row, base + 0, bit_depth);
                const gg = sampleBits(row, base + 1, bit_depth);
                const bb = sampleBits(row, base + 2, bit_depth);
                out_row[o] = scaleTo8(r, bit_depth);
                out_row[o + 1] = scaleTo8(gg, bit_depth);
                out_row[o + 2] = scaleTo8(bb, bit_depth);
                var alpha: u8 = 255;
                if (trns_rgb) |t| {
                    if (t[0] == r and t[1] == gg and t[2] == bb) alpha = 0;
                }
                out_row[o + 3] = alpha;
            },
            3 => { // palette
                const idx = sampleBits(row, x, bit_depth);
                const pi: usize = @min(@as(usize, idx), if (palette_len > 0) palette_len - 1 else 0);
                out_row[o] = palette[pi][0];
                out_row[o + 1] = palette[pi][1];
                out_row[o + 2] = palette[pi][2];
                out_row[o + 3] = if (pi < trns_len) trns[pi] else 255;
            },
            4 => { // greyscale + alpha
                const base = x * @as(usize, nchan);
                const g = scaleTo8(sampleBits(row, base + 0, bit_depth), bit_depth);
                const a = scaleTo8(sampleBits(row, base + 1, bit_depth), bit_depth);
                out_row[o] = g;
                out_row[o + 1] = g;
                out_row[o + 2] = g;
                out_row[o + 3] = a;
            },
            6 => { // RGBA
                const base = x * @as(usize, nchan);
                out_row[o] = scaleTo8(sampleBits(row, base + 0, bit_depth), bit_depth);
                out_row[o + 1] = scaleTo8(sampleBits(row, base + 1, bit_depth), bit_depth);
                out_row[o + 2] = scaleTo8(sampleBits(row, base + 2, bit_depth), bit_depth);
                out_row[o + 3] = scaleTo8(sampleBits(row, base + 3, bit_depth), bit_depth);
            },
            else => {},
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

test "readInfo parses IHDR" {
    // Minimal PNG header: signature + IHDR(2x1, 8-bit RGB).
    var buf: [33]u8 = undefined;
    @memcpy(buf[0..8], &SIGNATURE);
    // IHDR length = 13
    buf[8] = 0; buf[9] = 0; buf[10] = 0; buf[11] = 13;
    @memcpy(buf[12..16], "IHDR");
    buf[16] = 0; buf[17] = 0; buf[18] = 0; buf[19] = 2; // width 2
    buf[20] = 0; buf[21] = 0; buf[22] = 0; buf[23] = 1; // height 1
    buf[24] = 8; // bit depth
    buf[25] = 2; // color type RGB
    buf[26] = 0; buf[27] = 0; buf[28] = 0; // compression/filter/interlace
    buf[29] = 0; buf[30] = 0; buf[31] = 0; buf[32] = 0; // CRC (unused by readInfo)
    const info = try readInfo(&buf);
    try std.testing.expectEqual(@as(u32, 2), info.width);
    try std.testing.expectEqual(@as(u32, 1), info.height);
    try std.testing.expectEqual(@as(u8, 8), info.bit_depth);
    try std.testing.expectEqual(@as(u8, 2), info.color_type);
}

test "bad signature rejected" {
    const junk = [_]u8{0} ** 33;
    try std.testing.expectError(error.BadSignature, readInfo(&junk));
}

test "paeth predictor picks nearest" {
    // p = a+b-c; pick the predictor (a,b,c) closest to p, ties favor a then b.
    try std.testing.expectEqual(@as(u8, 10), paeth(10, 20, 20)); // p=10: pa0 -> a
    try std.testing.expectEqual(@as(u8, 10), paeth(20, 10, 20)); // p=10: pb0 -> b
    try std.testing.expectEqual(@as(u8, 5), paeth(5, 5, 5)); // all equal -> a
}

test "scaleTo8 expands bit depths" {
    try std.testing.expectEqual(@as(u8, 255), scaleTo8(15, 4));
    try std.testing.expectEqual(@as(u8, 255), scaleTo8(1, 1));
    try std.testing.expectEqual(@as(u8, 0), scaleTo8(0, 1));
    try std.testing.expectEqual(@as(u8, 128), scaleTo8(128, 8));
}
