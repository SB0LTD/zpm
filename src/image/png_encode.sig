// png_encode — pure-Sig RGBA8 → PNG encoder.
// Layer 0: Core. No allocator, no platform deps, no compression codec.
//
// Writes a conforming 8-bit truecolor-with-alpha (color type 6) PNG. The pixel
// data is emitted as a zlib stream of *stored* (uncompressed) DEFLATE blocks,
// which every PNG reader accepts. This trades file size for zero dependencies
// and fully deterministic output — ideal for saving generated images without
// pulling in a DEFLATE compressor.
//
// All buffers are caller-provided:
//   • rgba — width*height*4 input bytes (row-major, top-left origin)
//   • out  — receives the PNG file bytes; must be large enough (see maxSize).
//
// Returns the number of bytes written, or an error if `out` is too small.

pub const PngEncodeError = error{
    OutputTooSmall,
    ImageTooLarge,
};

/// Upper bound on the encoded size for a width×height RGBA image, so callers
/// can size their `out` buffer. Accounts for the signature, IHDR, IEND, and a
/// zlib stream of stored DEFLATE blocks (max 65535 bytes each) over the
/// filtered scanlines (one filter byte per row).
pub fn maxSize(width: usize, height: usize) usize {
    const raw = height * (1 + width * 4); // filtered scanlines
    const blocks = (raw / 65535) + 1;
    const zlib = 2 + raw + blocks * 5 + 4; // cmf/flg + block headers + adler32
    return 8 + (12 + 13) + (12 + zlib) + 12; // sig + IHDR + IDAT + IEND
}

const SIGNATURE = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// Encode an RGBA8 image into `out` as a PNG. Returns bytes written.
pub fn encodeRGBA(rgba: []const u8, width: usize, height: usize, out: []u8) PngEncodeError!usize {
    if (width == 0 or height == 0 or width > 0x7FFF_FFFF or height > 0x7FFF_FFFF)
        return PngEncodeError.ImageTooLarge;
    if (rgba.len < width * height * 4) return PngEncodeError.ImageTooLarge;
    if (out.len < maxSize(width, height)) return PngEncodeError.OutputTooSmall;

    var w = Writer{ .buf = out, .pos = 0 };

    // 1. Signature.
    w.bytes(&SIGNATURE);

    // 2. IHDR: width, height, bit depth 8, color type 6, no compression/filter/interlace.
    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], @intCast(width));
    writeU32(ihdr[4..8], @intCast(height));
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: truecolor + alpha
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter: adaptive (we use filter 0 per row)
    ihdr[12] = 0; // interlace: none
    w.chunk("IHDR", &ihdr);

    // 3. IDAT: zlib(stored deflate blocks over filtered scanlines).
    // We stream the filtered rows directly into stored blocks so no full-size
    // intermediate is needed beyond `out`. Build the zlib stream in place after
    // the IDAT length+type placeholder, then patch length + CRC.
    const idat_type_pos = w.pos; // where "IDAT" will go (after 4-byte length)
    w.pos += 4; // reserve length
    const idat_data_start = w.pos + 4; // after the 4-char type
    w.bytes("IDAT");

    const zlib_len = writeZlibStored(rgba, width, height, out, idat_data_start);
    w.pos = idat_data_start + zlib_len;

    // Patch IDAT length and CRC (over type+data).
    writeU32(out[idat_type_pos .. idat_type_pos + 4], @intCast(zlib_len));
    const crc = crc32(out[idat_type_pos + 4 .. idat_data_start + zlib_len]);
    writeU32(out[idat_data_start + zlib_len .. idat_data_start + zlib_len + 4], crc);
    w.pos += 4; // CRC

    // 4. IEND.
    w.chunk("IEND", &.{});

    return w.pos;
}

/// Write the zlib stream (stored deflate) of the filtered scanlines directly
/// into `out` starting at `start`. Returns the byte length written.
fn writeZlibStored(rgba: []const u8, width: usize, height: usize, out: []u8, start: usize) usize {
    var p = start;
    // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (no dict, check bits).
    out[p] = 0x78;
    out[p + 1] = 0x01;
    p += 2;

    const stride = width * 4;
    const raw_len = height * (1 + stride);

    // Emit stored DEFLATE blocks over a virtual stream of filtered scanlines.
    // Each block: 1 header byte (BFINAL/BTYPE=00) + LEN(2) + NLEN(2) + data.
    var adler = Adler32{};
    var produced: usize = 0; // filtered bytes produced so far
    var row: usize = 0;
    var col_in_row: usize = 0; // 0 = filter byte, then pixel bytes
    while (produced < raw_len) {
        const remaining = raw_len - produced;
        const block_len: usize = @min(remaining, 65535);
        const is_final = (produced + block_len) >= raw_len;
        out[p] = if (is_final) 1 else 0; // BFINAL, BTYPE=00
        p += 1;
        writeU16LE(out[p .. p + 2], @intCast(block_len));
        writeU16LE(out[p + 2 .. p + 4], @intCast(~@as(u16, @intCast(block_len))));
        p += 4;
        // Fill the block by walking the filtered scanline stream.
        var k: usize = 0;
        while (k < block_len) : (k += 1) {
            var b: u8 = undefined;
            if (col_in_row == 0) {
                b = 0; // filter type 0 (None) for this row
            } else {
                const idx = row * stride + (col_in_row - 1);
                b = rgba[idx];
            }
            out[p] = b;
            adler.update(b);
            p += 1;
            col_in_row += 1;
            if (col_in_row == 1 + stride) {
                col_in_row = 0;
                row += 1;
            }
        }
        produced += block_len;
    }

    // Adler-32 checksum of the *uncompressed* data, big-endian.
    writeU32(out[p .. p + 4], adler.final());
    p += 4;
    return p - start;
}

// ── Small in-place writer for the fixed chunks ──
const Writer = struct {
    buf: []u8,
    pos: usize,

    fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.pos .. self.pos + b.len], b);
        self.pos += b.len;
    }

    /// Write a full chunk: length(4) + type(4) + data + crc(4).
    fn chunk(self: *Writer, type_tag: []const u8, data: []const u8) void {
        writeU32(self.buf[self.pos .. self.pos + 4], @intCast(data.len));
        self.pos += 4;
        const crc_start = self.pos;
        self.bytes(type_tag);
        self.bytes(data);
        const crc = crc32(self.buf[crc_start..self.pos]);
        writeU32(self.buf[self.pos .. self.pos + 4], crc);
        self.pos += 4;
    }
};

fn writeU32(dst: []u8, v: u32) void {
    dst[0] = @intCast((v >> 24) & 0xFF);
    dst[1] = @intCast((v >> 16) & 0xFF);
    dst[2] = @intCast((v >> 8) & 0xFF);
    dst[3] = @intCast(v & 0xFF);
}

fn writeU16LE(dst: []u8, v: u16) void {
    dst[0] = @intCast(v & 0xFF);
    dst[1] = @intCast((v >> 8) & 0xFF);
}

// ── CRC-32 (IEEE 802.3, as PNG requires) ──
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        crc ^= b;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = @as(u32, 0) -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return crc ^ 0xFFFF_FFFF;
}

// ── Adler-32 (as zlib requires) ──
const Adler32 = struct {
    a: u32 = 1,
    b: u32 = 0,

    fn update(self: *Adler32, byte: u8) void {
        self.a = (self.a + byte) % 65521;
        self.b = (self.b + self.a) % 65521;
    }
    fn final(self: *const Adler32) u32 {
        return (self.b << 16) | self.a;
    }
};

// ── Tests ──
test "crc32 matches the PNG IEND constant" {
    const std = @import("std");
    // CRC of the "IEND" chunk type over empty data is a well-known value.
    try std.testing.expectEqual(@as(u32, 0xAE42_6082), crc32("IEND"));
}

test "adler32 of 'abc' is known" {
    const std = @import("std");
    var a = Adler32{};
    a.update('a');
    a.update('b');
    a.update('c');
    try std.testing.expectEqual(@as(u32, 0x024D0127), a.final());
}

test "encode a 2x2 image round-trips through the decoder" {
    const std = @import("std");
    const decode = @import("png_decode.sig");
    const rgba = [_]u8{
        255, 0,   0,   255, 0,   255, 0,   255,
        0,   0,   255, 255, 255, 255, 0,   255,
    };
    var out: [512]u8 = undefined;
    const n = try encodeRGBA(&rgba, 2, 2, &out);
    try std.testing.expect(n > 0);
    // Signature check.
    try std.testing.expectEqualSlices(u8, &SIGNATURE, out[0..8]);

    // Decode it back.
    var scratch: [1024]u8 = undefined;
    var raw: [1024]u8 = undefined;
    var dec: [2 * 2 * 4]u8 = undefined;
    const img = try decode.decode(out[0..n], &scratch, &raw, &dec);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    for (rgba, 0..) |v, i| try std.testing.expectEqual(v, dec[i]);
}

test "maxSize is a safe upper bound" {
    const std = @import("std");
    const rgba = [_]u8{0} ** (4 * 4 * 4);
    var out: [4096]u8 = undefined;
    const n = try encodeRGBA(&rgba, 4, 4, &out);
    try std.testing.expect(n <= maxSize(4, 4));
}
