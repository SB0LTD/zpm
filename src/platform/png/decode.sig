// PNG decoder — reads PNG files into RGBA pixel buffers
// Layer 1: Platform (part of @zpm/png module)
//
// Supports: 8-bit RGB and RGBA with all filter types (None, Sub, Up, Average, Paeth).
// No interlacing (Adam7) support — covers the 95% case.
// Uses std.compress.flate for zlib decompression.
//
// Usage:
//   const png = @import("png");
//   const pixels = png.decode.decodeFile(allocator, "image.png") orelse return;
//   defer allocator.free(pixels.data);
//   // pixels.width, pixels.height, pixels.data ([]RGBA)

const std = @import("std");

pub const RGBA = packed struct { r: u8, g: u8, b: u8, a: u8 };

pub const DecodedImage = struct {
    data: []RGBA,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.data);
    }
};

const PNG_SIGNATURE = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

const ChunkHeader = struct {
    length: u32,
    chunk_type: [4]u8,
};

const IHDRData = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression: u8,
    filter: u8,
    interlace: u8,
};

pub const DecodeError = error{
    InvalidPng,
    UnsupportedBitDepth,
    UnsupportedInterlace,
    UnsupportedColorType,
    DataTooLarge,
    DecompressFailed,
    OutOfMemory,
};

/// Decode PNG from a file path into an RGBA pixel buffer.
pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) DecodeError!DecodedImage {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.InvalidPng;
    defer file.close();
    const stat = file.stat() catch return error.InvalidPng;
    const data = allocator.alloc(u8, stat.size) catch return error.OutOfMemory;
    defer allocator.free(data);
    _ = file.readAll(data) catch return error.InvalidPng;
    return decode(allocator, data);
}

/// Decode PNG from memory into an RGBA pixel buffer.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!DecodedImage {
    // Verify signature
    if (data.len < 8) return error.InvalidPng;
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) return error.InvalidPng;

    var pos: usize = 8;

    // Parse IHDR (must be first chunk)
    const ihdr_header = readChunkHeader(data, pos) orelse return error.InvalidPng;
    pos += 8;
    if (!std.mem.eql(u8, &ihdr_header.chunk_type, "IHDR")) return error.InvalidPng;

    const ihdr = parseIHDR(data[pos..]) orelse return error.InvalidPng;
    pos += ihdr_header.length + 4; // skip data + CRC

    if (ihdr.bit_depth != 8) return error.UnsupportedBitDepth;
    if (ihdr.interlace != 0) return error.UnsupportedInterlace;

    const channels: u8 = switch (ihdr.color_type) {
        2 => 3, // RGB
        6 => 4, // RGBA
        else => return error.UnsupportedColorType,
    };

    // Collect IDAT chunks (compressed pixel data)
    const max_compressed: usize = 16 * 1024 * 1024; // 16MB limit
    const idat_buf = allocator.alloc(u8, max_compressed) catch return error.OutOfMemory;
    defer allocator.free(idat_buf);
    var idat_len: usize = 0;

    while (pos + 8 <= data.len) {
        const chunk = readChunkHeader(data, pos) orelse break;
        pos += 8;

        if (std.mem.eql(u8, &chunk.chunk_type, "IDAT")) {
            const end = pos + chunk.length;
            if (end > data.len) break;
            if (idat_len + chunk.length > max_compressed) return error.DataTooLarge;
            @memcpy(idat_buf[idat_len..][0..chunk.length], data[pos..end]);
            idat_len += chunk.length;
        } else if (std.mem.eql(u8, &chunk.chunk_type, "IEND")) {
            break;
        }

        pos += chunk.length + 4; // data + CRC
    }

    // Decompress (zlib: 2-byte header + deflate stream + 4-byte adler32)
    if (idat_len < 2) return error.InvalidPng;

    const raw_size: usize = @as(usize, ihdr.height) * (@as(usize, ihdr.width) * @as(usize, channels) + 1);
    const raw = allocator.alloc(u8, raw_size) catch return error.OutOfMemory;
    defer allocator.free(raw);

    // Skip 2-byte zlib header, decompress raw deflate
    var fbs = std.io.fixedBufferStream(idat_buf[2..idat_len]);
    var decompressor = std.compress.flate.decompressor(.raw, fbs.reader());
    _ = decompressor.reader().readAll(raw) catch return error.DecompressFailed;

    // Unfilter scanlines and convert to RGBA
    const pixel_count = @as(usize, ihdr.width) * @as(usize, ihdr.height);
    const pixels = allocator.alloc(RGBA, pixel_count) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    const stride = @as(usize, ihdr.width) * @as(usize, channels);

    // We need to unfilter in-place row by row
    var row: usize = 0;
    while (row < ihdr.height) : (row += 1) {
        const row_start = row * (stride + 1);
        const filter_byte = raw[row_start];
        const row_data = raw[row_start + 1 ..][0..stride];

        // Get previous row (or null for first row)
        const prev_row: ?[]const u8 = if (row > 0)
            raw[(row - 1) * (stride + 1) + 1 ..][0..stride]
        else
            null;

        // Apply inverse filter in-place
        unfilterRow(row_data, prev_row, filter_byte, channels);

        // Convert to RGBA
        var x: u32 = 0;
        while (x < ihdr.width) : (x += 1) {
            const offset = @as(usize, x) * @as(usize, channels);
            const pixel_idx = row * @as(usize, ihdr.width) + @as(usize, x);
            pixels[pixel_idx] = if (channels == 4)
                .{ .r = row_data[offset], .g = row_data[offset + 1], .b = row_data[offset + 2], .a = row_data[offset + 3] }
            else
                .{ .r = row_data[offset], .g = row_data[offset + 1], .b = row_data[offset + 2], .a = 255 };
        }
    }

    return .{
        .data = pixels,
        .width = ihdr.width,
        .height = ihdr.height,
        .allocator = allocator,
    };
}

// ── Internal helpers ────────────────────────────────────────────────

fn readChunkHeader(data: []const u8, pos: usize) ?ChunkHeader {
    if (pos + 8 > data.len) return null;
    return .{
        .length = std.mem.readInt(u32, data[pos..][0..4], .big),
        .chunk_type = data[pos + 4 ..][0..4].*,
    };
}

fn parseIHDR(data: []const u8) ?IHDRData {
    if (data.len < 13) return null;
    return .{
        .width = std.mem.readInt(u32, data[0..4], .big),
        .height = std.mem.readInt(u32, data[4..8], .big),
        .bit_depth = data[8],
        .color_type = data[9],
        .compression = data[10],
        .filter = data[11],
        .interlace = data[12],
    };
}

fn unfilterRow(row: []u8, prev: ?[]const u8, filter_type: u8, bpp: u8) void {
    switch (filter_type) {
        0 => {}, // None
        1 => { // Sub
            var i: usize = bpp;
            while (i < row.len) : (i += 1) {
                row[i] +%= row[i - bpp];
            }
        },
        2 => { // Up
            if (prev) |p| {
                for (row, 0..) |*b, i| {
                    b.* +%= p[i];
                }
            }
        },
        3 => { // Average
            for (row, 0..) |*b, i| {
                const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                const up: u16 = if (prev) |p| p[i] else 0;
                b.* +%= @intCast((left + up) / 2);
            }
        },
        4 => { // Paeth
            for (row, 0..) |*b, i| {
                const left: i16 = if (i >= bpp) @intCast(row[i - bpp]) else 0;
                const up: i16 = if (prev) |p| @intCast(p[i]) else 0;
                const upleft: i16 = if (i >= bpp and prev != null) @intCast(prev.?[i - bpp]) else 0;
                b.* +%= paeth(left, up, upleft);
            }
        },
        else => {},
    }
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa: u16 = @intCast(if (p - a < 0) -(p - a) else p - a);
    const pb: u16 = @intCast(if (p - b < 0) -(p - b) else p - b);
    const pc: u16 = @intCast(if (p - c < 0) -(p - c) else p - c);
    if (pa <= pb and pa <= pc) return @intCast(a);
    if (pb <= pc) return @intCast(b);
    return @intCast(c);
}
