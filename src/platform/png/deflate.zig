// Deflate compression engine - fixed Huffman coding + bit packing
// Layer 1: Platform (internal to png/ module)
//
// Implements RFC 1951 deflate encoding with fixed Huffman codes (BTYPE=01).
// Fixed codes use the predefined tables from RFC 1951 section 3.2.6, requiring
// no tree construction or code-length transmission. Simple and correct.
//
// LZ77 matching lives in lz.zig; this file handles bit-level serialization.

const lz = @import("lz.zig");
pub const LzToken = lz.LzToken;
pub const LzState = lz.LzState;
pub const MAX_DIST = lz.MAX_DIST;

// -- Bit writer - packs bits LSB-first into output buffer

pub const BitWriter = struct {
    buf: []u8,
    pos: usize,
    bits: u32,
    nbits: u5,

    pub fn init(buf: []u8) BitWriter {
        return .{ .buf = buf, .pos = 0, .bits = 0, .nbits = 0 };
    }

    pub fn writeBits(self: *BitWriter, value: u32, count: u5) void {
        self.bits |= value << self.nbits;
        self.nbits += count;
        while (self.nbits >= 8) {
            if (self.pos < self.buf.len) {
                self.buf[self.pos] = @truncate(self.bits);
                self.pos += 1;
            }
            self.bits >>= 8;
            self.nbits -= 8;
        }
    }

    /// Write bits in reverse order (MSB first) - used for Huffman codes.
    pub fn writeBitsReversed(self: *BitWriter, code: u16, length: u5) void {
        var reversed: u32 = 0;
        var c = code;
        for (0..@as(usize, length)) |_| {
            reversed = (reversed << 1) | (c & 1);
            c >>= 1;
        }
        self.writeBits(reversed, length);
    }

    pub fn flushByte(self: *BitWriter) void {
        if (self.nbits > 0) {
            if (self.pos < self.buf.len) {
                self.buf[self.pos] = @truncate(self.bits);
                self.pos += 1;
            }
            self.bits = 0;
            self.nbits = 0;
        }
    }

    pub fn bytesWritten(self: *const BitWriter) usize {
        return self.pos;
    }
};

// -- Deflate length/distance code tables (RFC 1951 section 3.2.5)

const LenCode = struct { base: u16, extra: u4 };

const len_table: [29]LenCode = .{
    .{ .base = 3, .extra = 0 },   .{ .base = 4, .extra = 0 },   .{ .base = 5, .extra = 0 },
    .{ .base = 6, .extra = 0 },   .{ .base = 7, .extra = 0 },   .{ .base = 8, .extra = 0 },
    .{ .base = 9, .extra = 0 },   .{ .base = 10, .extra = 0 },  .{ .base = 11, .extra = 1 },
    .{ .base = 13, .extra = 1 },  .{ .base = 15, .extra = 1 },  .{ .base = 17, .extra = 1 },
    .{ .base = 19, .extra = 2 },  .{ .base = 23, .extra = 2 },  .{ .base = 27, .extra = 2 },
    .{ .base = 31, .extra = 2 },  .{ .base = 35, .extra = 3 },  .{ .base = 43, .extra = 3 },
    .{ .base = 51, .extra = 3 },  .{ .base = 59, .extra = 3 },  .{ .base = 67, .extra = 4 },
    .{ .base = 83, .extra = 4 },  .{ .base = 99, .extra = 4 },  .{ .base = 115, .extra = 4 },
    .{ .base = 131, .extra = 5 }, .{ .base = 163, .extra = 5 }, .{ .base = 195, .extra = 5 },
    .{ .base = 227, .extra = 5 }, .{ .base = 258, .extra = 0 },
};

const DistCode = struct { base: u16, extra: u4 };

const dist_table: [30]DistCode = .{
    .{ .base = 1, .extra = 0 },      .{ .base = 2, .extra = 0 },      .{ .base = 3, .extra = 0 },
    .{ .base = 4, .extra = 0 },      .{ .base = 5, .extra = 1 },      .{ .base = 7, .extra = 1 },
    .{ .base = 9, .extra = 2 },      .{ .base = 13, .extra = 2 },     .{ .base = 17, .extra = 3 },
    .{ .base = 25, .extra = 3 },     .{ .base = 33, .extra = 4 },     .{ .base = 49, .extra = 4 },
    .{ .base = 65, .extra = 5 },     .{ .base = 97, .extra = 5 },     .{ .base = 129, .extra = 6 },
    .{ .base = 193, .extra = 6 },    .{ .base = 257, .extra = 7 },    .{ .base = 385, .extra = 7 },
    .{ .base = 513, .extra = 8 },    .{ .base = 769, .extra = 8 },    .{ .base = 1025, .extra = 9 },
    .{ .base = 1537, .extra = 9 },   .{ .base = 2049, .extra = 10 },  .{ .base = 3073, .extra = 10 },
    .{ .base = 4097, .extra = 11 },  .{ .base = 6145, .extra = 11 },  .{ .base = 8193, .extra = 12 },
    .{ .base = 12289, .extra = 12 }, .{ .base = 16385, .extra = 13 }, .{ .base = 24577, .extra = 13 },
};

fn lengthToCode(length: u16) struct { code: u16, extra_bits: u4, extra_val: u16 } {
    var lo: usize = 0;
    var hi: usize = 28;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (len_table[mid].base <= length) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return .{
        .code = @as(u16, @intCast(lo)) + 257,
        .extra_bits = len_table[lo].extra,
        .extra_val = length - len_table[lo].base,
    };
}

fn distToCode(dist: u16) struct { code: u16, extra_bits: u4, extra_val: u16 } {
    var lo: usize = 0;
    var hi: usize = 29;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (dist_table[mid].base <= dist) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return .{
        .code = @intCast(lo),
        .extra_bits = dist_table[lo].extra,
        .extra_val = dist - dist_table[lo].base,
    };
}

// -- Fixed Huffman codes (RFC 1951 section 3.2.6)

const FixedCode = struct { code: u16, len: u5 };

fn fixedLitLenCode(sym: u16) FixedCode {
    if (sym <= 143) {
        return .{ .code = @as(u16, 0x30) + sym, .len = 8 };
    } else if (sym <= 255) {
        return .{ .code = @as(u16, 0x190) + (sym - 144), .len = 9 };
    } else if (sym <= 279) {
        return .{ .code = sym - 256, .len = 7 };
    } else {
        return .{ .code = @as(u16, 0xC0) + (sym - 280), .len = 8 };
    }
}

/// Write a fixed Huffman block (BTYPE=01).
pub fn writeFixedBlock(
    bw: *BitWriter,
    tokens: []const LzToken,
    token_count: usize,
    is_final: bool,
) void {
    bw.writeBits(if (is_final) @as(u32, 1) else @as(u32, 0), 1);
    bw.writeBits(1, 2);

    for (tokens[0..token_count]) |tok| {
        if (tok.dist == 0) {
            const fc = fixedLitLenCode(tok.lit_or_len);
            bw.writeBitsReversed(fc.code, fc.len);
        } else {
            const lc = lengthToCode(tok.lit_or_len);
            const fc = fixedLitLenCode(lc.code);
            bw.writeBitsReversed(fc.code, fc.len);
            if (lc.extra_bits > 0) {
                bw.writeBits(@as(u32, lc.extra_val), lc.extra_bits);
            }
            const dc = distToCode(tok.dist);
            bw.writeBitsReversed(dc.code, 5);
            if (dc.extra_bits > 0) {
                bw.writeBits(@as(u32, dc.extra_val), dc.extra_bits);
            }
        }
    }

    const eob = fixedLitLenCode(256);
    bw.writeBitsReversed(eob.code, eob.len);
}
