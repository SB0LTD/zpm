// PNG encoder — GL framebuffer to in-memory PNG
// Layer 1: Platform (entry point for png/ module)
//
// Orchestrates PNG encoding: signature, IHDR, IDAT (deflate-compressed
// filtered scanlines), IEND. Reads GL framebuffer row by row.
// Output goes to a static memory buffer — no file I/O.
//
// All large buffers are file-scope statics to avoid stack overflow.
// Only one screenshot can be in progress at a time, so this is safe.

const w32 = @import("win32");
const gl = @import("gl");
const log = @import("logging");

const deflate = @import("deflate.zig");
const filter = @import("filter.zig");

const BitWriter = deflate.BitWriter;
const LzToken = deflate.LzToken;

// ── CRC32 (PNG chunks) ──────────────────────────────────────────────

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

fn crc32update(crc: u32, data: []const u8) u32 {
    var c = crc;
    for (data) |b| {
        c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c;
}

// ── Adler-32 (zlib checksum) ────────────────────────────────────────

const ADLER_BASE: u32 = 65521;

fn adler32update(adler: u32, data: []const u8) u32 {
    var s1: u32 = adler & 0xFFFF;
    var s2: u32 = (adler >> 16) & 0xFFFF;
    for (data) |b| {
        s1 = (s1 + b) % ADLER_BASE;
        s2 = (s2 + s1) % ADLER_BASE;
    }
    return (s2 << 16) | s1;
}

// ── Memory buffer writer ────────────────────────────────────────────

fn writeU32BE(buf: *[4]u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

/// Append bytes to the output buffer, advancing the position.
fn bufWrite(pos: *usize, data: []const u8) void {
    const end = pos.* + data.len;
    if (end > PNG_BUF_SIZE) return;
    @memcpy(s_png_buf[pos.*..end], data);
    pos.* = end;
}

/// Write a PNG chunk (length + type + data + CRC) to the output buffer.
fn writeChunk(pos: *usize, chunk_type: *const [4]u8, data: []const u8) void {
    var len_buf: [4]u8 = undefined;
    writeU32BE(&len_buf, @intCast(data.len));
    bufWrite(pos, &len_buf);
    bufWrite(pos, chunk_type);
    if (data.len > 0) {
        bufWrite(pos, data);
    }
    var crc = crc32update(0xFFFFFFFF, chunk_type);
    crc = crc32update(crc, data);
    crc ^= 0xFFFFFFFF;
    var crc_buf: [4]u8 = undefined;
    writeU32BE(&crc_buf, crc);
    bufWrite(pos, &crc_buf);
}

// ── Constants ───────────────────────────────────────────────────────

const png_signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const DEFLATE_BUF_SIZE = 1024 * 1024;
const BLOCK_ROWS = 32;
const MAX_ROW_BYTES = 3840 * 3;
const BLOCK_BUF_SIZE = (MAX_ROW_BYTES + 1) * BLOCK_ROWS;
const MAX_TOKENS = BLOCK_BUF_SIZE + 16;

/// Output buffer — 1.5MB accommodates fixed Huffman output for up to 1920x1080.
pub const PNG_BUF_SIZE: usize = 1536 * 1024;

// ── File-scope static buffers (avoids stack overflow) ───────────────

var s_cur_row: [MAX_ROW_BYTES]u8 = undefined;
var s_prev_row: [MAX_ROW_BYTES]u8 = [_]u8{0} ** MAX_ROW_BYTES;
var s_filtered: [MAX_ROW_BYTES]u8 = undefined;
var s_block_buf: [BLOCK_BUF_SIZE]u8 = undefined;
var s_deflate_buf: [DEFLATE_BUF_SIZE]u8 = undefined;
var s_tokens: [MAX_TOKENS]LzToken = undefined;

/// Output PNG buffer — written by capture(), read by MCP screenshot handler.
pub var s_png_buf: [PNG_BUF_SIZE]u8 = undefined;
/// Length of valid PNG data in s_png_buf. Atomic for cross-thread reads.
pub var s_png_len: u32 = 0;

// ── Public API ──────────────────────────────────────────────────────

/// Capture the current GL framebuffer and encode as PNG into the static buffer.
/// Must be called after rendering, before swap (main thread only).
/// The result is available via s_png_buf[0..s_png_len].
pub fn capture(width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    var pos: usize = 0;

    // PNG signature
    bufWrite(&pos, &png_signature);

    // IHDR
    var ihdr: [13]u8 = undefined;
    writeU32BE(ihdr[0..4], w);
    writeU32BE(ihdr[4..8], h);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: RGB
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter: adaptive
    ihdr[12] = 0; // interlace: none
    writeChunk(&pos, "IHDR", &ihdr);

    encodeImageData(&pos, width, height, w, h);

    writeChunk(&pos, "IEND", &[_]u8{});

    // Publish atomically so the MCP thread sees a consistent length
    @atomicStore(u32, &s_png_len, @intCast(pos), .release);

    log.info(.{ "png: captured ", @as(i64, @intCast(pos)), " bytes" });
}

/// Encode all image rows into IDAT chunks written to the output buffer.
///
/// Uses a single BitWriter for the entire deflate stream so that
/// multi-block encoding produces a continuous bit stream (no spurious
/// byte-alignment padding between deflate blocks). The raw compressed
/// bytes are flushed to IDAT chunks periodically to bound memory.
fn encodeImageData(pos: *usize, width: i32, height: i32, w: u32, h: u32) void {
    const row_bytes: usize = w * 3;
    const bpp: usize = 3;
    const filtered_row_size = row_bytes + 1;

    @memset(s_prev_row[0..row_bytes], 0);

    var block_pos: usize = 0;
    var lz = deflate.LzState.getStatic();
    lz.reset(); // Reset once at start — window persists across blocks
    var adler: u32 = 1;

    gl.glPixelStorei(gl.PACK_ALIGNMENT, 1);

    // Zlib header
    s_deflate_buf[0] = 0x78;
    s_deflate_buf[1] = 0xDA; // max compression
    // Single BitWriter for the entire deflate stream — never re-initialized
    var bw = BitWriter.init(s_deflate_buf[2..]);

    var rows_in_block: usize = 0;
    var y: usize = 0;

    while (y < h) : (y += 1) {
        const gl_y: i32 = height - 1 - @as(i32, @intCast(y));
        gl.glReadPixels(0, gl_y, width, 1, gl.RGB, gl.UNSIGNED_BYTE, &s_cur_row);

        const prev_ptr: ?[]const u8 = if (y > 0) s_prev_row[0..row_bytes] else null;
        const ftype = filter.selectFilter(s_cur_row[0..row_bytes], prev_ptr, bpp, s_filtered[0..row_bytes]);

        s_block_buf[block_pos] = @intFromEnum(ftype);
        block_pos += 1;
        @memcpy(s_block_buf[block_pos .. block_pos + row_bytes], s_filtered[0..row_bytes]);
        block_pos += row_bytes;

        adler = adler32update(adler, s_block_buf[block_pos - filtered_row_size .. block_pos]);
        @memcpy(s_prev_row[0..row_bytes], s_cur_row[0..row_bytes]);

        rows_in_block += 1;

        const is_last_row = (y == h - 1);
        if (rows_in_block >= BLOCK_ROWS or is_last_row) {
            const token_count = lz.compress(s_block_buf[0..block_pos], &s_tokens);
            deflate.writeFixedBlock(&bw, &s_tokens, token_count, is_last_row);

            block_pos = 0;
            rows_in_block = 0;
        }
    }

    // Finalize: flush remaining bits, append adler-32 checksum
    bw.flushByte();
    const compressed_len = bw.bytesWritten();
    const data_end = 2 + compressed_len;

    var adler_buf: [4]u8 = undefined;
    writeU32BE(&adler_buf, adler);
    @memcpy(s_deflate_buf[data_end .. data_end + 4], &adler_buf);

    // Write as a single IDAT chunk
    writeChunk(pos, "IDAT", s_deflate_buf[0 .. data_end + 4]);
}
