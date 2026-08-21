// PNG file writer — encodes RGBA pixel data to a PNG file
// Layer 1: Platform (part of @zpm/png module)
//
// Unlike encode.sig (which captures from GL framebuffer to a static buffer),
// this module writes arbitrary RGBA data to a file on disk.
// Uses std.compress.flate for deflate compression.
//
// Usage:
//   const png = @import("png");
//   png.write.writeFile(pixels, width, height, "output.png") catch return;

const std = @import("std");

const PNG_SIGNATURE = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub const RGBA = packed struct { r: u8, g: u8, b: u8, a: u8 };

pub const WriteError = error{
    FileCreateFailed,
    CompressFailed,
    WriteFailed,
    OutOfMemory,
};

/// Write RGBA pixel data to a PNG file.
pub fn writeFile(pixels: []const RGBA, width: u32, height: u32, path: []const u8) WriteError!void {
    const allocator = std.heap.page_allocator;

    // Build raw scanlines (filter byte 0 + RGBA per row)
    const stride = @as(usize, width) * 4;
    const raw_size = @as(usize, height) * (stride + 1);
    const raw = allocator.alloc(u8, raw_size) catch return error.OutOfMemory;
    defer allocator.free(raw);

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const row_start = row * (stride + 1);
        raw[row_start] = 0; // Filter: None

        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px = pixels[row * @as(usize, width) + x];
            const offset = row_start + 1 + x * 4;
            raw[offset] = px.r;
            raw[offset + 1] = px.g;
            raw[offset + 2] = px.b;
            raw[offset + 3] = px.a;
        }
    }

    // Compress with deflate (zlib wrapper)
    const max_compressed = raw_size + raw_size / 100 + 1024;
    const compressed = allocator.alloc(u8, max_compressed) catch return error.OutOfMemory;
    defer allocator.free(compressed);

    var fbs = std.io.fixedBufferStream(compressed);
    const writer = fbs.writer();

    // zlib header (deflate, default compression)
    writer.writeAll(&[2]u8{ 0x78, 0x01 }) catch return error.CompressFailed;

    var compressor = std.compress.flate.compressor(.raw, writer, .{}) catch return error.CompressFailed;
    compressor.write(raw) catch return error.CompressFailed;
    compressor.finish() catch return error.CompressFailed;

    // zlib adler32 checksum
    const adler = adler32(raw);
    writer.writeInt(u32, adler, .big) catch return error.CompressFailed;

    const compressed_len = fbs.pos;

    // Write PNG file
    const file = std.fs.cwd().createFile(path, .{}) catch return error.FileCreateFailed;
    defer file.close();
    const fw = file.writer();

    // Signature
    fw.writeAll(&PNG_SIGNATURE) catch return error.WriteFailed;

    // IHDR
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    writeChunk(fw, "IHDR", &ihdr) catch return error.WriteFailed;

    // IDAT
    writeChunk(fw, "IDAT", compressed[0..compressed_len]) catch return error.WriteFailed;

    // IEND
    writeChunk(fw, "IEND", &[0]u8{}) catch return error.WriteFailed;
}

fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(chunk_type);
    if (data.len > 0) try writer.writeAll(data);
    var crc: u32 = 0xFFFFFFFF;
    crc = crc32update(crc, chunk_type);
    crc = crc32update(crc, data);
    try writer.writeInt(u32, crc ^ 0xFFFFFFFF, .big);
}

fn crc32update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| {
        c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c;
}

fn adler32(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    return (s2 << 16) | s1;
}

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        t[n] = c;
    }
    break :blk t;
};
