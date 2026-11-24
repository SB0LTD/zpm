//! @zpm/aac: an AAC-LC encoder (MPEG-4 Audio, ISO/IEC 14496-3) for live
//! streams. Twitch's ingest takes H.264 video with AAC-LC audio.
//!
//! Layer 0: pure computation, allocation-free, no platform deps. `encode`
//! turns 1024 PCM16 samples a channel (interleaved) into one raw AAC frame,
//! a raw_data_block: what FLV and MP4 carry. `adts` writes the 7-byte ADTS
//! header that goes ahead of a frame in a .aac file, and
//! `audioSpecificConfig` the 2 bytes a container's decoder setup holds.
//!
//! The coding is plain. Long blocks only: the sine window and no block
//! switching, so a sharp attack pre-echoes a little. No TNS, no M/S or
//! intensity stereo, no noise substitution. Each coded band takes the
//! cheapest of the eleven spectrum codebooks that holds its values, and a
//! band that quantizes to nothing the zero book. A band's quantizer step
//! follows half its energy's slope in dB, so a louder band is quantized
//! coarser. One offset for the whole frame is then searched so the frame
//! fits the bit rate, spending what a reservoir kept from earlier frames.
//! Lines above a cutoff the bit rate sets (11 to 19 kHz) are not sent.
//! 44.1 or 48 kHz, mono or stereo. About 85 times real time for 48 kHz
//! stereo on a desktop core.
//!
//! Measured through ffmpeg's decoder (below 15 kHz): a two-tone mix comes
//! back at 39 dB SNR (128 kb/s) and 42 dB (192 kb/s), a tone in pink noise
//! at 17 and 21 dB (ffmpeg's own encoder: 21 dB at 128 kb/s).
//!
//! The decoder's output lags the input by one frame (1024 samples): the
//! first frame decodes to the priming.
//!
//! Tables: the standard's scalefactor Huffman code and eleven spectrum
//! codebooks (ISO/IEC 14496-3, 4.A.1), each a complete prefix code (a test
//! checks), and the 1024-line scalefactor bands of 44.1 and 48 kHz.

const std = @import("std");

/// Samples a channel in one frame.
pub const FRAME: usize = 1024;
/// The MDCT's input: the previous frame and this one.
const SPAN: usize = 2 * FRAME;
/// The complex FFT's size inside the MDCT.
const HALF: usize = FRAME / 2;
const BANDS: usize = 49;
const SF_OFFSET: f32 = 100;
const ESC_FLAG: u32 = 16;
const MAX_Q: f32 = 8191;
const ROUNDING: f32 = 0.4054;
const ZERO_BOOK: u4 = 0;
const ESC_BOOK: u4 = 11;
/// The standard's limit: 6144 bits a channel in one frame.
const CHANNEL_BITS: u32 = 6144;
/// The longest frame `encode` writes (stereo at the standard's limit).
pub const MAX_FRAME_BYTES: usize = 2 * CHANNEL_BITS / 8;
pub const ADTS_BYTES: usize = 7;

/// The 1024-line scalefactor bands of 44.1 and 48 kHz (swb_offset_long).
const SWB = [BANDS + 1]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,  72,  80,  88,
    96,  108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448,
    480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024,
};

pub const Error = error{
    /// channels must be 1 or 2.
    InvalidChannels,
    /// sample_rate must be 44100 or 48000.
    InvalidSampleRate,
    /// bit_rate must be 16..320 kb/s a channel.
    InvalidBitRate,
    /// `encode` takes FRAME samples a channel.
    ShortInput,
    /// The output cannot hold MAX_FRAME_BYTES (or ADTS_BYTES more for adts).
    OutputTooSmall,
};

pub const Config = struct {
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
    /// Bits a second, all channels together.
    bit_rate: u32 = 128_000,
};

const Channel = struct {
    /// The last frame's samples: the MDCT's first half next time.
    prev: [FRAME]f32 = [_]f32{0} ** FRAME,
    spec: [FRAME]f32 = [_]f32{0} ** FRAME,
    /// |spec|^(3/4): what the quantizer scales.
    mag: [FRAME]f32 = [_]f32{0} ** FRAME,
    quant: [FRAME]u16 = [_]u16{0} ** FRAME,
    /// A band's step from its energy (log2 of its mean power).
    tilt: [BANDS]i32 = [_]i32{0} ** BANDS,
    /// The lowest scalefactor whose values stay within the escape's 8191.
    least: [BANDS]i32 = [_]i32{0} ** BANDS,
    sf: [BANDS]i32 = [_]i32{0} ** BANDS,
    book: [BANDS]u4 = [_]u4{0} ** BANDS,
    /// Bands sent: the last coded band + 1.
    max_sfb: usize = 0,
};

pub const Encoder = struct {
    channels: usize = 2,
    rate_index: u4 = 3,
    /// The bit rate's share of one frame.
    frame_bits: u32 = 0,
    /// Bits earlier frames left unspent (at most one frame's share).
    reservoir: u32 = 0,
    /// Bands under the low-pass cutoff (the rest are not sent).
    bands: usize = BANDS,
    chans: [2]Channel = .{ .{}, .{} },
    sine: [SPAN]f32 = undefined,
    /// e^(-i pi (j + 1/8) / FRAME): the DCT-IV's twiddles, before and after.
    twiddle: [HALF][2]f32 = undefined,
    /// e^(-2 pi i k / HALF): the FFT's roots.
    roots: [HALF / 2][2]f32 = undefined,

    pub fn init(e: *Encoder, cfg: Config) Error!void {
        if (cfg.channels != 1 and cfg.channels != 2) return error.InvalidChannels;
        const index: u4 = switch (cfg.sample_rate) {
            48_000 => 3,
            44_100 => 4,
            else => return error.InvalidSampleRate,
        };
        const per_channel = cfg.bit_rate / cfg.channels;
        if (per_channel < 16_000 or per_channel > 320_000) return error.InvalidBitRate;
        e.* = .{};
        e.channels = cfg.channels;
        e.rate_index = index;
        e.frame_bits = @intCast(@as(u64, cfg.bit_rate) * FRAME / cfg.sample_rate);
        // (the low-pass: what the bits can carry)
        const cutoff_hz: u64 = if (per_channel >= 96_000) 19_000 else if (per_channel >= 64_000) 16_000 else if (per_channel >= 48_000) 14_000 else 11_000;
        const line = cutoff_hz * SPAN / cfg.sample_rate;
        var bands: usize = 1;
        while (bands < BANDS and SWB[bands + 1] <= line) bands += 1;
        e.bands = bands;
        for (0..SPAN) |n| {
            const x = std.math.pi / @as(f64, SPAN) * (@as(f64, @floatFromInt(n)) + 0.5);
            e.sine[n] = @floatCast(@sin(x));
        }
        for (0..HALF) |j| {
            const a = std.math.pi * (@as(f64, @floatFromInt(j)) + 0.125) / @as(f64, FRAME);
            e.twiddle[j] = .{ @floatCast(@cos(a)), @floatCast(-@sin(a)) };
        }
        for (0..HALF / 2) |k| {
            const a = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, HALF);
            e.roots[k] = .{ @floatCast(@cos(a)), @floatCast(-@sin(a)) };
        }
    }

    /// The 2 bytes of an AudioSpecificConfig: AAC-LC, the rate, the
    /// channels, a 1024-sample frame (FLV's AAC sequence header, MP4's esds).
    pub fn audioSpecificConfig(e: *const Encoder) [2]u8 {
        const v: u16 = (2 << 11) | (@as(u16, e.rate_index) << 7) | (@as(u16, @intCast(e.channels)) << 3);
        return .{ @intCast(v >> 8), @intCast(v & 0xff) };
    }

    /// The 7-byte ADTS header for a frame of `frame_len` bytes (no CRC).
    pub fn adts(e: *const Encoder, frame_len: usize, out: []u8) Error!void {
        if (out.len < ADTS_BYTES) return error.OutputTooSmall;
        const total: u32 = @intCast(frame_len + ADTS_BYTES);
        const ch: u8 = @intCast(e.channels);
        out[0] = 0xff;
        out[1] = 0xf1; // MPEG-4, layer 0, no CRC
        out[2] = (1 << 6) | (@as(u8, e.rate_index) << 2) | (ch >> 2); // profile LC (1)
        out[3] = ((ch & 3) << 6) | @as(u8, @intCast(total >> 11));
        out[4] = @intCast((total >> 3) & 0xff);
        out[5] = @as(u8, @intCast((total & 7) << 5)) | 0x1f; // buffer fullness 0x7ff: VBR
        out[6] = 0xfc; // one raw data block
    }

    /// One frame: `pcm` holds FRAME samples a channel, interleaved (L, R,
    /// L, R... for stereo). Writes the raw_data_block into `out` (at least
    /// MAX_FRAME_BYTES) and returns it.
    pub fn encode(e: *Encoder, pcm: []const i16, out: []u8) Error![]u8 {
        if (pcm.len < FRAME * e.channels) return error.ShortInput;
        if (out.len < MAX_FRAME_BYTES) return error.OutputTooSmall;
        for (0..e.channels) |c| e.analyse(c, pcm);
        // element header (+ common_window for a pair) and the end element
        const framing: u32 = (if (e.channels == 2) @as(u32, 8) else 7) + 3 + 7;
        const ceiling = @min(e.frame_bits + e.reservoir, CHANNEL_BITS * @as(u32, @intCast(e.channels)));
        const limit = ceiling -| framing;
        // the finest offset whose frame fits (bits fall as the offset rises)
        var lo: i32 = -160;
        var hi: i32 = 255;
        while (lo < hi) {
            const mid = lo + @divFloor(hi - lo, 2);
            if (e.bitsAt(mid) <= limit) hi = mid else lo = mid + 1;
        }
        const body = e.bitsAt(lo);
        @memset(out[0..MAX_FRAME_BYTES], 0);
        var w = Writer{ .buf = out[0..MAX_FRAME_BYTES] };
        if (e.channels == 2) {
            w.put(1, 3); // ID_CPE
            w.put(0, 4); // element_instance_tag
            w.put(0, 1); // common_window: each channel its own
        } else {
            w.put(0, 3); // ID_SCE
            w.put(0, 4);
        }
        for (0..e.channels) |c| e.writeChannel(c, &w);
        w.put(7, 3); // ID_END
        std.debug.assert(w.at == body + framing - 7);
        const bytes = (w.at + 7) / 8;
        const used: u32 = @intCast(bytes * 8);
        e.reservoir = @min(e.reservoir + e.frame_bits -| used, e.frame_bits);
        if (used > e.frame_bits + e.reservoir) e.reservoir = 0;
        return out[0..bytes];
    }

    fn analyse(e: *Encoder, c: usize, pcm: []const i16) void {
        const ch = &e.chans[c];
        var z: [SPAN]f32 = undefined;
        for (0..FRAME) |n| {
            const s: f32 = @floatFromInt(pcm[n * e.channels + c]);
            z[n] = ch.prev[n] * e.sine[n];
            z[FRAME + n] = s * e.sine[FRAME + n];
            ch.prev[n] = s;
        }
        e.mdct(&z, &ch.spec);
        for (SWB[e.bands]..FRAME) |k| ch.spec[k] = 0;
        for (0..e.bands) |b| {
            var power: f64 = 0;
            var peak: f32 = 0;
            for (SWB[b]..SWB[b + 1]) |k| {
                const x = @abs(ch.spec[k]);
                const m = @sqrt(x * @sqrt(x)); // x^(3/4)
                ch.mag[k] = m;
                peak = @max(peak, m);
                power += @as(f64, x) * x;
            }
            power /= @floatFromInt(SWB[b + 1] - SWB[b]);
            ch.tilt[b] = @intFromFloat(@round(@log2(power + 1)));
            // q = floor(m 2^(-3/16 (sf - 100)) + 0.4054) <= 8191
            ch.least[b] = if (peak > 0) @as(i32, @intFromFloat(@floor(SF_OFFSET + 16.0 / 3.0 * @log2(peak / MAX_Q)))) + 1 else 0;
            ch.least[b] = std.math.clamp(ch.least[b], 0, 255);
        }
    }

    /// The bits both channels' streams take at offset `g` (their
    /// scalefactors, values and books are left set for writeChannel).
    fn bitsAt(e: *Encoder, g: i32) u32 {
        var total: u32 = 0;
        for (0..e.channels) |c| total += e.prepare(c, g);
        return total;
    }

    fn prepare(e: *Encoder, c: usize, g: i32) u32 {
        const ch = &e.chans[c];
        ch.max_sfb = 0;
        var top: [BANDS]u16 = undefined;
        for (0..e.bands) |b| {
            ch.sf[b] = std.math.clamp(@max(g + ch.tilt[b], ch.least[b]), 0, 255);
            top[b] = quantize(ch, b);
            if (top[b] != 0) ch.max_sfb = b + 1;
        }
        // neighbouring coded bands' scalefactors within 60: raise the lower
        // one (coarser, never past the escape's range); a band raised to
        // nothing stays coded so the chain holds
        var last: ?usize = null;
        for (0..ch.max_sfb) |b| {
            if (top[b] == 0) continue;
            if (last) |p| if (ch.sf[b] < ch.sf[p] - 60) {
                ch.sf[b] = ch.sf[p] - 60;
                top[b] = @max(quantize(ch, b), 1);
            };
            last = b;
        }
        last = null;
        var b = ch.max_sfb;
        while (b > 0) {
            b -= 1;
            if (top[b] == 0) continue;
            if (last) |n| if (ch.sf[b] < ch.sf[n] - 60) {
                ch.sf[b] = ch.sf[n] - 60;
                top[b] = @max(quantize(ch, b), 1);
            };
            last = b;
        }
        var bits: u32 = 8 + 11 + 3; // global_gain, ics_info, the three flags
        for (0..ch.max_sfb) |s| {
            if (top[s] == 0) {
                ch.book[s] = ZERO_BOOK;
                continue;
            }
            // the cheapest book that holds the band's largest value
            var best: u32 = std.math.maxInt(u32);
            for (1..12) |book| {
                if (BOOKS[book].lav < top[s]) continue;
                const cost = bandBits(ch, s, @intCast(book));
                if (cost < best) {
                    best = cost;
                    ch.book[s] = @intCast(book);
                }
            }
            bits += best;
        }
        return bits + sideBits(ch);
    }

    fn writeChannel(e: *const Encoder, c: usize, w: *Writer) void {
        const ch = &e.chans[c];
        const gain = firstScalefactor(ch);
        const start = w.at;
        defer std.debug.assert(w.at - start == channelBits(ch));
        w.put(@intCast(gain), 8); // global_gain
        w.put(0, 1); // ics_reserved_bit
        w.put(0, 2); // ONLY_LONG_SEQUENCE
        w.put(0, 1); // the sine window
        w.put(@intCast(ch.max_sfb), 6);
        w.put(0, 1); // predictor_data_present
        var b: usize = 0;
        while (b < ch.max_sfb) {
            const book = ch.book[b];
            var end = b;
            while (end < ch.max_sfb and ch.book[end] == book) end += 1;
            w.put(book, 4);
            var len = end - b;
            while (len >= 31) : (len -= 31) w.put(31, 5);
            w.put(@intCast(len), 5);
            b = end;
        }
        var prev = gain;
        for (0..ch.max_sfb) |s| {
            if (ch.book[s] == ZERO_BOOK) continue;
            const d: usize = @intCast(ch.sf[s] - prev + 60);
            w.put(SF_CODES[d], @intCast(SF_BITS[d]));
            prev = ch.sf[s];
        }
        w.put(0, 1); // pulse_data_present
        w.put(0, 1); // tns_data_present
        w.put(0, 1); // gain_control_data_present
        for (0..ch.max_sfb) |s| {
            const book = ch.book[s];
            if (book == ZERO_BOOK) continue;
            const bk = BOOKS[book];
            var k: usize = SWB[s];
            while (k < SWB[s + 1]) : (k += bk.dim) {
                const index = tupleIndex(ch, k, book);
                w.put(bk.codes[index], @intCast(bk.bits[index]));
                if (bk.signed) continue;
                for (k..k + bk.dim) |i| if (ch.quant[i] != 0) w.put(@intFromBool(ch.spec[i] < 0), 1);
                if (book == ESC_BOOK) for (k..k + 2) |i| if (ch.quant[i] >= ESC_FLAG) putEscape(w, ch.quant[i]);
            }
        }
    }

    /// The MDCT of the windowed span (ISO/IEC 14496-3's, with its factor
    /// 2): folded into a DCT-IV of FRAME lines, done as a complex FFT of
    /// HALF points between two twiddles.
    fn mdct(e: *const Encoder, z: *const [SPAN]f32, out: *[FRAME]f32) void {
        var re: [HALF]f32 = undefined;
        var im: [HALF]f32 = undefined;
        for (0..HALF) |m| {
            const a = fold(z, 2 * m);
            const b = fold(z, FRAME - 1 - 2 * m);
            const t = e.twiddle[m];
            re[m] = a * t[0] - b * t[1];
            im[m] = a * t[1] + b * t[0];
        }
        e.fft(&re, &im);
        for (0..HALF) |k| {
            const t = e.twiddle[k];
            const yr = re[k] * t[0] - im[k] * t[1];
            const yi = re[k] * t[1] + im[k] * t[0];
            out[2 * k] = 2 * yr;
            out[FRAME - 1 - 2 * k] = -2 * yi;
        }
    }

    /// In-place radix-2 FFT of HALF points (e^(-2 pi i nk / HALF)).
    fn fft(e: *const Encoder, re: *[HALF]f32, im: *[HALF]f32) void {
        var j: usize = 0;
        for (1..HALF) |i| {
            var bit: usize = HALF >> 1;
            while (j & bit != 0) : (bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) {
                std.mem.swap(f32, &re[i], &re[j]);
                std.mem.swap(f32, &im[i], &im[j]);
            }
        }
        var size: usize = 2;
        while (size <= HALF) : (size *= 2) {
            const step = HALF / size;
            var start: usize = 0;
            while (start < HALF) : (start += size) {
                for (0..size / 2) |k| {
                    const r = e.roots[k * step];
                    const a = start + k;
                    const b = a + size / 2;
                    const tr = re[b] * r[0] - im[b] * r[1];
                    const ti = re[b] * r[1] + im[b] * r[0];
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
        }
    }
};

/// MDCT(a, b, c, d) = DCT-IV(-c' - d, a - b'), ' reversed (quarters of the span).
fn fold(z: *const [SPAN]f32, n: usize) f32 {
    const q = FRAME / 2;
    return if (n < q) -z[3 * q - 1 - n] - z[3 * q + n] else z[n - q] - z[3 * q - 1 - n];
}

/// Quantizes band `b` at its scalefactor; returns its largest value.
fn quantize(ch: *Channel, b: usize) u16 {
    const scale = std.math.exp2(-3.0 / 16.0 * (@as(f32, @floatFromInt(ch.sf[b])) - SF_OFFSET));
    var top: u16 = 0;
    for (SWB[b]..SWB[b + 1]) |k| {
        const q: u16 = @intFromFloat(@min(@floor(ch.mag[k] * scale + ROUNDING), MAX_Q));
        ch.quant[k] = q;
        top = @max(top, q);
    }
    return top;
}

/// A spectrum codebook: `dim` values a codeword, each in -lav..lav
/// (signed: the sign is in the codeword) or 0..lav (unsigned: a sign bit
/// follows for each value not 0); book 11 escapes 16 and over.
const Book = struct {
    dim: usize,
    signed: bool,
    lav: u16,
    codes: []const u16,
    bits: []const u8,
};

const BOOKS = [12]Book{
    .{ .dim = 2, .signed = false, .lav = 0, .codes = &.{}, .bits = &.{} }, // ZERO_HCB
    .{ .dim = 4, .signed = true, .lav = 1, .codes = &CODES1, .bits = &BITS1 },
    .{ .dim = 4, .signed = true, .lav = 1, .codes = &CODES2, .bits = &BITS2 },
    .{ .dim = 4, .signed = false, .lav = 2, .codes = &CODES3, .bits = &BITS3 },
    .{ .dim = 4, .signed = false, .lav = 2, .codes = &CODES4, .bits = &BITS4 },
    .{ .dim = 2, .signed = true, .lav = 4, .codes = &CODES5, .bits = &BITS5 },
    .{ .dim = 2, .signed = true, .lav = 4, .codes = &CODES6, .bits = &BITS6 },
    .{ .dim = 2, .signed = false, .lav = 7, .codes = &CODES7, .bits = &BITS7 },
    .{ .dim = 2, .signed = false, .lav = 7, .codes = &CODES8, .bits = &BITS8 },
    .{ .dim = 2, .signed = false, .lav = 12, .codes = &CODES9, .bits = &BITS9 },
    .{ .dim = 2, .signed = false, .lav = 12, .codes = &CODES10, .bits = &BITS10 },
    .{ .dim = 2, .signed = false, .lav = 8191, .codes = &CODES11, .bits = &BITS11 },
};

/// The codeword index of the tuple at line `k` in `book`: base-(2 lav + 1)
/// digits of value + lav (signed), base-(lav + 1) digits of |value|
/// (unsigned; book 11's base is 17, its 16 the escape flag).
fn tupleIndex(ch: *const Channel, k: usize, book: u4) u32 {
    const bk = BOOKS[book];
    var index: u32 = 0;
    for (k..k + bk.dim) |i| {
        const q: u32 = ch.quant[i];
        if (bk.signed) {
            const v: u32 = if (ch.spec[i] < 0) bk.lav - q else bk.lav + q;
            index = index * (2 * @as(u32, bk.lav) + 1) + v;
        } else if (book == ESC_BOOK) {
            index = index * 17 + @min(q, ESC_FLAG);
        } else {
            index = index * (@as(u32, bk.lav) + 1) + q;
        }
    }
    return index;
}

/// Band `s`'s values in `book`: codewords, sign bits, escapes.
fn bandBits(ch: *const Channel, s: usize, book: u4) u32 {
    const bk = BOOKS[book];
    var bits: u32 = 0;
    var k: usize = SWB[s];
    while (k < SWB[s + 1]) : (k += bk.dim) {
        bits += bk.bits[tupleIndex(ch, k, book)];
        if (bk.signed) continue;
        for (k..k + bk.dim) |i| bits += @as(u32, @intFromBool(ch.quant[i] != 0)) + escapeBits(ch.quant[i]);
    }
    return bits;
}

fn firstScalefactor(ch: *const Channel) i32 {
    for (0..ch.max_sfb) |b| if (ch.book[b] != ZERO_BOOK) return ch.sf[b];
    return @intFromFloat(SF_OFFSET);
}

/// The section data and the scalefactors, counted.
fn sideBits(ch: *const Channel) u32 {
    var bits: u32 = 0;
    var b: usize = 0;
    while (b < ch.max_sfb) {
        var end = b;
        while (end < ch.max_sfb and ch.book[end] == ch.book[b]) end += 1;
        bits += 4 + 5 * @as(u32, @intCast((end - b) / 31 + 1));
        b = end;
    }
    var prev = firstScalefactor(ch);
    for (0..ch.max_sfb) |s| {
        if (ch.book[s] == ZERO_BOOK) continue;
        bits += SF_BITS[@intCast(ch.sf[s] - prev + 60)];
        prev = ch.sf[s];
    }
    return bits;
}

/// What writeChannel writes for this channel, counted.
fn channelBits(ch: *const Channel) u32 {
    var bits: u32 = 8 + 11 + 3 + sideBits(ch);
    for (0..ch.max_sfb) |s| if (ch.book[s] != ZERO_BOOK) {
        bits += bandBits(ch, s, ch.book[s]);
    };
    return bits;
}

/// An escape: N - 4 ones, a zero, then the value - 2^N in N bits
/// (N = floor(log2 v), v in 16..8191).
fn putEscape(w: *Writer, v: u32) void {
    const n: u5 = @intCast(31 - @clz(v));
    var i: u5 = 4;
    while (i < n) : (i += 1) w.put(1, 1);
    w.put(0, 1);
    w.put(v - (@as(u32, 1) << n), n);
}

fn escapeBits(v: u32) u32 {
    if (v < ESC_FLAG) return 0;
    const n: u32 = 31 - @clz(v);
    return 2 * n - 3;
}

/// MSB-first bit writer into a zeroed buffer.
const Writer = struct {
    buf: []u8,
    at: usize = 0,

    fn put(w: *Writer, value: u32, n: u6) void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            if ((value >> @intCast(i)) & 1 != 0) w.buf[w.at >> 3] |= @as(u8, 0x80) >> @intCast(w.at & 7);
            w.at += 1;
        }
    }
};

// ISO/IEC 14496-3 4.A.1: the scalefactor code (index: difference + 60) and the
// eleven spectrum codebooks (index: tupleIndex).
const SF_BITS = [_]u8{
    18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 18,
    19, 18, 17, 17, 16, 17, 16, 16, 16, 16, 15, 15, 14, 14, 14, 14, 14, 14, 13, 13,
    12, 12, 12, 11, 12, 11, 10, 10, 10, 9, 9, 8, 8, 8, 7, 6, 6, 5, 4, 3,
    1, 4, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 11, 11, 11, 11, 12,
    12, 13, 13, 13, 14, 14, 16, 15, 16, 15, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19,
};
const SF_CODES = [_]u32{
    0x3ffe8, 0x3ffe6, 0x3ffe7, 0x3ffe5, 0x7fff5, 0x7fff1, 0x7ffed, 0x7fff6, 0x7ffee, 0x7ffef,
    0x7fff0, 0x7fffc, 0x7fffd, 0x7ffff, 0x7fffe, 0x7fff7, 0x7fff8, 0x7fffb, 0x7fff9, 0x3ffe4,
    0x7fffa, 0x3ffe3, 0x1ffef, 0x1fff0, 0xfff5, 0x1ffee, 0xfff2, 0xfff3, 0xfff4, 0xfff1,
    0x7ff6, 0x7ff7, 0x3ff9, 0x3ff5, 0x3ff7, 0x3ff3, 0x3ff6, 0x3ff2, 0x1ff7, 0x1ff5,
    0xff9, 0xff7, 0xff6, 0x7f9, 0xff4, 0x7f8, 0x3f9, 0x3f7, 0x3f5, 0x1f8,
    0x1f7, 0xfa, 0xf8, 0xf6, 0x79, 0x3a, 0x38, 0x1a, 0xb, 0x4,
    0x0, 0xa, 0xc, 0x1b, 0x39, 0x3b, 0x78, 0x7a, 0xf7, 0xf9,
    0x1f6, 0x1f9, 0x3f4, 0x3f6, 0x3f8, 0x7f5, 0x7f4, 0x7f6, 0x7f7, 0xff5,
    0xff8, 0x1ff4, 0x1ff6, 0x1ff8, 0x3ff8, 0x3ff4, 0xfff0, 0x7ff4, 0xfff6, 0x7ff5,
    0x3ffe2, 0x7ffd9, 0x7ffda, 0x7ffdb, 0x7ffdc, 0x7ffdd, 0x7ffde, 0x7ffd8, 0x7ffd2, 0x7ffd3,
    0x7ffd4, 0x7ffd5, 0x7ffd6, 0x7fff2, 0x7ffdf, 0x7ffe7, 0x7ffe8, 0x7ffe9, 0x7ffea, 0x7ffeb,
    0x7ffe6, 0x7ffe0, 0x7ffe1, 0x7ffe2, 0x7ffe3, 0x7ffe4, 0x7ffe5, 0x7ffd7, 0x7ffec, 0x7fff4,
    0x7fff3,
};
const BITS1 = [_]u8{
    11, 9, 11, 10, 7, 10, 11, 9, 11,
    10, 7, 10, 7, 5, 7, 9, 7, 10,
    11, 9, 11, 9, 7, 9, 11, 9, 11,
    9, 7, 9, 7, 5, 7, 9, 7, 9,
    7, 5, 7, 5, 1, 5, 7, 5, 7,
    9, 7, 9, 7, 5, 7, 9, 7, 9,
    11, 9, 11, 9, 7, 9, 11, 9, 11,
    10, 7, 9, 7, 5, 7, 9, 7, 10,
    11, 9, 11, 10, 7, 9, 11, 9, 11,
};
const CODES1 = [_]u16{
    0x7f8, 0x1f1, 0x7fd, 0x3f5, 0x68, 0x3f0, 0x7f7, 0x1ec, 0x7f5,
    0x3f1, 0x72, 0x3f4, 0x74, 0x11, 0x76, 0x1eb, 0x6c, 0x3f6,
    0x7fc, 0x1e1, 0x7f1, 0x1f0, 0x61, 0x1f6, 0x7f2, 0x1ea, 0x7fb,
    0x1f2, 0x69, 0x1ed, 0x77, 0x17, 0x6f, 0x1e6, 0x64, 0x1e5,
    0x67, 0x15, 0x62, 0x12, 0x0, 0x14, 0x65, 0x16, 0x6d,
    0x1e9, 0x63, 0x1e4, 0x6b, 0x13, 0x71, 0x1e3, 0x70, 0x1f3,
    0x7fe, 0x1e7, 0x7f3, 0x1ef, 0x60, 0x1ee, 0x7f0, 0x1e2, 0x7fa,
    0x3f3, 0x6a, 0x1e8, 0x75, 0x10, 0x73, 0x1f4, 0x6e, 0x3f7,
    0x7f6, 0x1e0, 0x7f9, 0x3f2, 0x66, 0x1f5, 0x7ff, 0x1f7, 0x7f4,
};
const BITS2 = [_]u8{
    9, 7, 9, 8, 6, 8, 9, 8, 9,
    8, 6, 7, 6, 5, 6, 7, 6, 8,
    9, 7, 8, 8, 6, 8, 9, 7, 9,
    8, 6, 7, 6, 5, 6, 7, 6, 8,
    6, 5, 6, 5, 3, 5, 6, 5, 6,
    8, 6, 7, 6, 5, 6, 8, 6, 8,
    9, 7, 9, 8, 6, 8, 8, 7, 9,
    8, 6, 7, 6, 4, 6, 8, 6, 7,
    9, 7, 9, 7, 6, 8, 9, 7, 9,
};
const CODES2 = [_]u16{
    0x1f3, 0x6f, 0x1fd, 0xeb, 0x23, 0xea, 0x1f7, 0xe8, 0x1fa,
    0xf2, 0x2d, 0x70, 0x20, 0x6, 0x2b, 0x6e, 0x28, 0xe9,
    0x1f9, 0x66, 0xf8, 0xe7, 0x1b, 0xf1, 0x1f4, 0x6b, 0x1f5,
    0xec, 0x2a, 0x6c, 0x2c, 0xa, 0x27, 0x67, 0x1a, 0xf5,
    0x24, 0x8, 0x1f, 0x9, 0x0, 0x7, 0x1d, 0xb, 0x30,
    0xef, 0x1c, 0x64, 0x1e, 0xc, 0x29, 0xf3, 0x2f, 0xf0,
    0x1fc, 0x71, 0x1f2, 0xf4, 0x21, 0xe6, 0xf7, 0x68, 0x1f8,
    0xee, 0x22, 0x65, 0x31, 0x2, 0x26, 0xed, 0x25, 0x6a,
    0x1fb, 0x72, 0x1fe, 0x69, 0x2e, 0xf6, 0x1ff, 0x6d, 0x1f6,
};
const BITS3 = [_]u8{
    1, 4, 8, 4, 5, 8, 9, 9, 10,
    4, 6, 9, 6, 6, 9, 9, 9, 10,
    9, 10, 13, 9, 9, 11, 11, 10, 12,
    4, 6, 10, 6, 7, 10, 10, 10, 12,
    5, 7, 11, 6, 7, 10, 9, 9, 11,
    9, 10, 13, 8, 9, 12, 10, 11, 12,
    8, 10, 15, 9, 11, 15, 13, 14, 16,
    8, 10, 14, 9, 10, 14, 12, 12, 15,
    11, 12, 16, 10, 11, 15, 12, 12, 15,
};
const CODES3 = [_]u16{
    0x0, 0x9, 0xef, 0xb, 0x19, 0xf0, 0x1eb, 0x1e6, 0x3f2,
    0xa, 0x35, 0x1ef, 0x34, 0x37, 0x1e9, 0x1ed, 0x1e7, 0x3f3,
    0x1ee, 0x3ed, 0x1ffa, 0x1ec, 0x1f2, 0x7f9, 0x7f8, 0x3f8, 0xff8,
    0x8, 0x38, 0x3f6, 0x36, 0x75, 0x3f1, 0x3eb, 0x3ec, 0xff4,
    0x18, 0x76, 0x7f4, 0x39, 0x74, 0x3ef, 0x1f3, 0x1f4, 0x7f6,
    0x1e8, 0x3ea, 0x1ffc, 0xf2, 0x1f1, 0xffb, 0x3f5, 0x7f3, 0xffc,
    0xee, 0x3f7, 0x7ffe, 0x1f0, 0x7f5, 0x7ffd, 0x1ffb, 0x3ffa, 0xffff,
    0xf1, 0x3f0, 0x3ffc, 0x1ea, 0x3ee, 0x3ffb, 0xff6, 0xffa, 0x7ffc,
    0x7f2, 0xff5, 0xfffe, 0x3f4, 0x7f7, 0x7ffb, 0xff7, 0xff9, 0x7ffa,
};
const BITS4 = [_]u8{
    4, 5, 8, 5, 4, 8, 9, 8, 11,
    5, 5, 8, 5, 4, 8, 8, 7, 10,
    9, 8, 11, 8, 8, 10, 11, 10, 11,
    4, 5, 8, 4, 4, 8, 8, 8, 10,
    4, 4, 8, 4, 4, 7, 8, 7, 9,
    8, 8, 10, 7, 7, 9, 10, 9, 10,
    8, 8, 11, 8, 7, 10, 11, 10, 12,
    8, 7, 10, 7, 7, 9, 10, 9, 11,
    11, 10, 12, 10, 9, 11, 11, 10, 11,
};
const CODES4 = [_]u16{
    0x7, 0x16, 0xf6, 0x18, 0x8, 0xef, 0x1ef, 0xf3, 0x7f8,
    0x19, 0x17, 0xed, 0x15, 0x1, 0xe2, 0xf0, 0x70, 0x3f0,
    0x1ee, 0xf1, 0x7fa, 0xee, 0xe4, 0x3f2, 0x7f6, 0x3ef, 0x7fd,
    0x5, 0x14, 0xf2, 0x9, 0x4, 0xe5, 0xf4, 0xe8, 0x3f4,
    0x6, 0x2, 0xe7, 0x3, 0x0, 0x6b, 0xe3, 0x69, 0x1f3,
    0xeb, 0xe6, 0x3f6, 0x6e, 0x6a, 0x1f4, 0x3ec, 0x1f0, 0x3f9,
    0xf5, 0xec, 0x7fb, 0xea, 0x6f, 0x3f7, 0x7f9, 0x3f3, 0xfff,
    0xe9, 0x6d, 0x3f8, 0x6c, 0x68, 0x1f5, 0x3ee, 0x1f2, 0x7f4,
    0x7f7, 0x3f1, 0xffe, 0x3ed, 0x1f1, 0x7f5, 0x7fe, 0x3f5, 0x7fc,
};
const BITS5 = [_]u8{
    13, 12, 11, 11, 10, 11, 11, 12, 13,
    12, 11, 10, 9, 8, 9, 10, 11, 12,
    12, 10, 9, 8, 7, 8, 9, 10, 11,
    11, 9, 8, 5, 4, 5, 8, 9, 11,
    10, 8, 7, 4, 1, 4, 7, 8, 11,
    11, 9, 8, 5, 4, 5, 8, 9, 11,
    11, 10, 9, 8, 7, 8, 9, 10, 11,
    12, 11, 10, 9, 8, 9, 10, 11, 12,
    13, 12, 12, 11, 10, 10, 11, 12, 13,
};
const CODES5 = [_]u16{
    0x1fff, 0xff7, 0x7f4, 0x7e8, 0x3f1, 0x7ee, 0x7f9, 0xff8, 0x1ffd,
    0xffd, 0x7f1, 0x3e8, 0x1e8, 0xf0, 0x1ec, 0x3ee, 0x7f2, 0xffa,
    0xff4, 0x3ef, 0x1f2, 0xe8, 0x70, 0xec, 0x1f0, 0x3ea, 0x7f3,
    0x7eb, 0x1eb, 0xea, 0x1a, 0x8, 0x19, 0xee, 0x1ef, 0x7ed,
    0x3f0, 0xf2, 0x73, 0xb, 0x0, 0xa, 0x71, 0xf3, 0x7e9,
    0x7ef, 0x1ee, 0xef, 0x18, 0x9, 0x1b, 0xeb, 0x1e9, 0x7ec,
    0x7f6, 0x3eb, 0x1f3, 0xed, 0x72, 0xe9, 0x1f1, 0x3ed, 0x7f7,
    0xff6, 0x7f0, 0x3e9, 0x1ed, 0xf1, 0x1ea, 0x3ec, 0x7f8, 0xff9,
    0x1ffc, 0xffc, 0xff5, 0x7ea, 0x3f3, 0x3f2, 0x7f5, 0xffb, 0x1ffe,
};
const BITS6 = [_]u8{
    11, 10, 9, 9, 9, 9, 9, 10, 11,
    10, 9, 8, 7, 7, 7, 8, 9, 10,
    9, 8, 6, 6, 6, 6, 6, 8, 9,
    9, 7, 6, 4, 4, 4, 6, 7, 9,
    9, 7, 6, 4, 4, 4, 6, 7, 9,
    9, 7, 6, 4, 4, 4, 6, 7, 9,
    9, 8, 6, 6, 6, 6, 6, 8, 9,
    10, 9, 8, 7, 7, 7, 7, 8, 10,
    11, 10, 9, 9, 9, 9, 9, 10, 11,
};
const CODES6 = [_]u16{
    0x7fe, 0x3fd, 0x1f1, 0x1eb, 0x1f4, 0x1ea, 0x1f0, 0x3fc, 0x7fd,
    0x3f6, 0x1e5, 0xea, 0x6c, 0x71, 0x68, 0xf0, 0x1e6, 0x3f7,
    0x1f3, 0xef, 0x32, 0x27, 0x28, 0x26, 0x31, 0xeb, 0x1f7,
    0x1e8, 0x6f, 0x2e, 0x8, 0x4, 0x6, 0x29, 0x6b, 0x1ee,
    0x1ef, 0x72, 0x2d, 0x2, 0x0, 0x3, 0x2f, 0x73, 0x1fa,
    0x1e7, 0x6e, 0x2b, 0x7, 0x1, 0x5, 0x2c, 0x6d, 0x1ec,
    0x1f9, 0xee, 0x30, 0x24, 0x2a, 0x25, 0x33, 0xec, 0x1f2,
    0x3f8, 0x1e4, 0xed, 0x6a, 0x70, 0x69, 0x74, 0xf1, 0x3fa,
    0x7ff, 0x3f9, 0x1f6, 0x1ed, 0x1f8, 0x1e9, 0x1f5, 0x3fb, 0x7fc,
};
const BITS7 = [_]u8{
    1, 3, 6, 7, 8, 9, 10, 11,
    3, 4, 6, 7, 8, 8, 9, 9,
    6, 6, 7, 8, 8, 9, 9, 10,
    7, 7, 8, 8, 9, 9, 10, 10,
    8, 8, 9, 9, 10, 10, 10, 11,
    9, 8, 9, 9, 10, 10, 11, 11,
    10, 9, 9, 10, 10, 11, 12, 12,
    11, 10, 10, 10, 11, 11, 12, 12,
};
const CODES7 = [_]u16{
    0x0, 0x5, 0x37, 0x74, 0xf2, 0x1eb, 0x3ed, 0x7f7,
    0x4, 0xc, 0x35, 0x71, 0xec, 0xee, 0x1ee, 0x1f5,
    0x36, 0x34, 0x72, 0xea, 0xf1, 0x1e9, 0x1f3, 0x3f5,
    0x73, 0x70, 0xeb, 0xf0, 0x1f1, 0x1f0, 0x3ec, 0x3fa,
    0xf3, 0xed, 0x1e8, 0x1ef, 0x3ef, 0x3f1, 0x3f9, 0x7fb,
    0x1ed, 0xef, 0x1ea, 0x1f2, 0x3f3, 0x3f8, 0x7f9, 0x7fc,
    0x3ee, 0x1ec, 0x1f4, 0x3f4, 0x3f7, 0x7f8, 0xffd, 0xffe,
    0x7f6, 0x3f0, 0x3f2, 0x3f6, 0x7fa, 0x7fd, 0xffc, 0xfff,
};
const BITS8 = [_]u8{
    5, 4, 5, 6, 7, 8, 9, 10,
    4, 3, 4, 5, 6, 7, 7, 8,
    5, 4, 4, 5, 6, 7, 7, 8,
    6, 5, 5, 6, 6, 7, 8, 8,
    7, 6, 6, 6, 7, 7, 8, 9,
    8, 7, 6, 7, 7, 8, 8, 10,
    9, 7, 7, 8, 8, 8, 9, 9,
    10, 8, 8, 8, 9, 9, 9, 10,
};
const CODES8 = [_]u16{
    0xe, 0x5, 0x10, 0x30, 0x6f, 0xf1, 0x1fa, 0x3fe,
    0x3, 0x0, 0x4, 0x12, 0x2c, 0x6a, 0x75, 0xf8,
    0xf, 0x2, 0x6, 0x14, 0x2e, 0x69, 0x72, 0xf5,
    0x2f, 0x11, 0x13, 0x2a, 0x32, 0x6c, 0xec, 0xfa,
    0x71, 0x2b, 0x2d, 0x31, 0x6d, 0x70, 0xf2, 0x1f9,
    0xef, 0x68, 0x33, 0x6b, 0x6e, 0xee, 0xf9, 0x3fc,
    0x1f8, 0x74, 0x73, 0xed, 0xf0, 0xf6, 0x1f6, 0x1fd,
    0x3fd, 0xf3, 0xf4, 0xf7, 0x1f7, 0x1fb, 0x1fc, 0x3ff,
};
const BITS9 = [_]u8{
    1, 3, 6, 8, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    3, 4, 6, 7, 8, 8, 9, 10, 10, 10, 11, 12, 12,
    6, 6, 7, 8, 8, 9, 10, 10, 10, 11, 12, 12, 12,
    8, 7, 8, 9, 9, 10, 10, 11, 11, 11, 12, 12, 13,
    9, 8, 9, 9, 10, 10, 11, 11, 11, 12, 12, 12, 13,
    10, 9, 9, 10, 11, 11, 11, 12, 11, 12, 12, 13, 13,
    11, 9, 10, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13,
    11, 10, 10, 11, 11, 12, 12, 13, 13, 13, 13, 13, 13,
    11, 10, 10, 11, 11, 11, 12, 12, 13, 13, 14, 13, 14,
    11, 10, 11, 11, 12, 12, 12, 12, 13, 13, 14, 14, 14,
    12, 11, 11, 12, 12, 12, 13, 13, 13, 14, 14, 14, 15,
    12, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 15, 15,
    13, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15,
};
const CODES9 = [_]u16{
    0x0, 0x5, 0x37, 0xe7, 0x1de, 0x3ce, 0x3d9, 0x7c8, 0x7cd, 0xfc8, 0xfdd, 0x1fe4, 0x1fec,
    0x4, 0xc, 0x35, 0x72, 0xea, 0xed, 0x1e2, 0x3d1, 0x3d3, 0x3e0, 0x7d8, 0xfcf, 0xfd5,
    0x36, 0x34, 0x71, 0xe8, 0xec, 0x1e1, 0x3cf, 0x3dd, 0x3db, 0x7d0, 0xfc7, 0xfd4, 0xfe4,
    0xe6, 0x70, 0xe9, 0x1dd, 0x1e3, 0x3d2, 0x3dc, 0x7cc, 0x7ca, 0x7de, 0xfd8, 0xfea, 0x1fdb,
    0x1df, 0xeb, 0x1dc, 0x1e6, 0x3d5, 0x3de, 0x7cb, 0x7dd, 0x7dc, 0xfcd, 0xfe2, 0xfe7, 0x1fe1,
    0x3d0, 0x1e0, 0x1e4, 0x3d6, 0x7c5, 0x7d1, 0x7db, 0xfd2, 0x7e0, 0xfd9, 0xfeb, 0x1fe3, 0x1fe9,
    0x7c4, 0x1e5, 0x3d7, 0x7c6, 0x7cf, 0x7da, 0xfcb, 0xfda, 0xfe3, 0xfe9, 0x1fe6, 0x1ff3, 0x1ff7,
    0x7d3, 0x3d8, 0x3e1, 0x7d4, 0x7d9, 0xfd3, 0xfde, 0x1fdd, 0x1fd9, 0x1fe2, 0x1fea, 0x1ff1, 0x1ff6,
    0x7d2, 0x3d4, 0x3da, 0x7c7, 0x7d7, 0x7e2, 0xfce, 0xfdb, 0x1fd8, 0x1fee, 0x3ff0, 0x1ff4, 0x3ff2,
    0x7e1, 0x3df, 0x7c9, 0x7d6, 0xfca, 0xfd0, 0xfe5, 0xfe6, 0x1feb, 0x1fef, 0x3ff3, 0x3ff4, 0x3ff5,
    0xfe0, 0x7ce, 0x7d5, 0xfc6, 0xfd1, 0xfe1, 0x1fe0, 0x1fe8, 0x1ff0, 0x3ff1, 0x3ff8, 0x3ff6, 0x7ffc,
    0xfe8, 0x7df, 0xfc9, 0xfd7, 0xfdc, 0x1fdc, 0x1fdf, 0x1fed, 0x1ff5, 0x3ff9, 0x3ffb, 0x7ffd, 0x7ffe,
    0x1fe7, 0xfcc, 0xfd6, 0xfdf, 0x1fde, 0x1fda, 0x1fe5, 0x1ff2, 0x3ffa, 0x3ff7, 0x3ffc, 0x3ffd, 0x7fff,
};
const BITS10 = [_]u8{
    6, 5, 6, 6, 7, 8, 9, 10, 10, 10, 11, 11, 12,
    5, 4, 4, 5, 6, 7, 7, 8, 8, 9, 10, 10, 11,
    6, 4, 5, 5, 6, 6, 7, 8, 8, 9, 9, 10, 10,
    6, 5, 5, 5, 6, 7, 7, 8, 8, 9, 9, 10, 10,
    7, 6, 6, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
    8, 7, 6, 7, 7, 7, 8, 8, 8, 9, 10, 10, 11,
    9, 7, 7, 7, 7, 8, 8, 9, 9, 9, 10, 10, 11,
    9, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 11, 11,
    9, 8, 8, 8, 8, 8, 9, 9, 10, 10, 10, 11, 11,
    10, 9, 9, 9, 9, 9, 9, 10, 10, 10, 11, 11, 12,
    10, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 12,
    11, 10, 9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 12,
    11, 10, 10, 10, 10, 10, 10, 11, 11, 12, 12, 12, 12,
};
const CODES10 = [_]u16{
    0x22, 0x8, 0x1d, 0x26, 0x5f, 0xd3, 0x1cf, 0x3d0, 0x3d7, 0x3ed, 0x7f0, 0x7f6, 0xffd,
    0x7, 0x0, 0x1, 0x9, 0x20, 0x54, 0x60, 0xd5, 0xdc, 0x1d4, 0x3cd, 0x3de, 0x7e7,
    0x1c, 0x2, 0x6, 0xc, 0x1e, 0x28, 0x5b, 0xcd, 0xd9, 0x1ce, 0x1dc, 0x3d9, 0x3f1,
    0x25, 0xb, 0xa, 0xd, 0x24, 0x57, 0x61, 0xcc, 0xdd, 0x1cc, 0x1de, 0x3d3, 0x3e7,
    0x5d, 0x21, 0x1f, 0x23, 0x27, 0x59, 0x64, 0xd8, 0xdf, 0x1d2, 0x1e2, 0x3dd, 0x3ee,
    0xd1, 0x55, 0x29, 0x56, 0x58, 0x62, 0xce, 0xe0, 0xe2, 0x1da, 0x3d4, 0x3e3, 0x7eb,
    0x1c9, 0x5e, 0x5a, 0x5c, 0x63, 0xca, 0xda, 0x1c7, 0x1ca, 0x1e0, 0x3db, 0x3e8, 0x7ec,
    0x1e3, 0xd2, 0xcb, 0xd0, 0xd7, 0xdb, 0x1c6, 0x1d5, 0x1d8, 0x3ca, 0x3da, 0x7ea, 0x7f1,
    0x1e1, 0xd4, 0xcf, 0xd6, 0xde, 0xe1, 0x1d0, 0x1d6, 0x3d1, 0x3d5, 0x3f2, 0x7ee, 0x7fb,
    0x3e9, 0x1cd, 0x1c8, 0x1cb, 0x1d1, 0x1d7, 0x1df, 0x3cf, 0x3e0, 0x3ef, 0x7e6, 0x7f8, 0xffa,
    0x3eb, 0x1dd, 0x1d3, 0x1d9, 0x1db, 0x3d2, 0x3cc, 0x3dc, 0x3ea, 0x7ed, 0x7f3, 0x7f9, 0xff9,
    0x7f2, 0x3ce, 0x1e4, 0x3cb, 0x3d8, 0x3d6, 0x3e2, 0x3e5, 0x7e8, 0x7f4, 0x7f5, 0x7f7, 0xffb,
    0x7fa, 0x3ec, 0x3df, 0x3e1, 0x3e4, 0x3e6, 0x3f0, 0x7e9, 0x7ef, 0xff8, 0xffe, 0xffc, 0xfff,
};
const BITS11 = [_]u8{
    4, 5, 6, 7, 8, 8, 9, 10, 10, 10, 11, 11, 12, 11, 12, 12, 10,
    5, 4, 5, 6, 7, 7, 8, 8, 9, 9, 9, 10, 10, 10, 10, 11, 8,
    6, 5, 5, 6, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 8,
    7, 6, 6, 6, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 8,
    8, 7, 7, 7, 7, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 8,
    8, 7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 8,
    9, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 10, 8,
    9, 8, 8, 8, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 10, 10, 8,
    10, 9, 8, 8, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 11, 8,
    10, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 10, 11, 11, 8,
    11, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 10, 11, 10, 11, 11, 8,
    11, 10, 9, 9, 10, 9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 8,
    11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 9,
    11, 10, 9, 9, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9,
    11, 10, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 9,
    12, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12, 9,
    9, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 9, 5,
};
const CODES11 = [_]u16{
    0x0, 0x6, 0x19, 0x3d, 0x9c, 0xc6, 0x1a7, 0x390, 0x3c2, 0x3df, 0x7e6, 0x7f3, 0xffb, 0x7ec, 0xffa, 0xffe, 0x38e,
    0x5, 0x1, 0x8, 0x14, 0x37, 0x42, 0x92, 0xaf, 0x191, 0x1a5, 0x1b5, 0x39e, 0x3c0, 0x3a2, 0x3cd, 0x7d6, 0xae,
    0x17, 0x7, 0x9, 0x18, 0x39, 0x40, 0x8e, 0xa3, 0xb8, 0x199, 0x1ac, 0x1c1, 0x3b1, 0x396, 0x3be, 0x3ca, 0x9d,
    0x3c, 0x15, 0x16, 0x1a, 0x3b, 0x44, 0x91, 0xa5, 0xbe, 0x196, 0x1ae, 0x1b9, 0x3a1, 0x391, 0x3a5, 0x3d5, 0x94,
    0x9a, 0x36, 0x38, 0x3a, 0x41, 0x8c, 0x9b, 0xb0, 0xc3, 0x19e, 0x1ab, 0x1bc, 0x39f, 0x38f, 0x3a9, 0x3cf, 0x93,
    0xbf, 0x3e, 0x3f, 0x43, 0x45, 0x9e, 0xa7, 0xb9, 0x194, 0x1a2, 0x1ba, 0x1c3, 0x3a6, 0x3a7, 0x3bb, 0x3d4, 0x9f,
    0x1a0, 0x8f, 0x8d, 0x90, 0x98, 0xa6, 0xb6, 0xc4, 0x19f, 0x1af, 0x1bf, 0x399, 0x3bf, 0x3b4, 0x3c9, 0x3e7, 0xa8,
    0x1b6, 0xab, 0xa4, 0xaa, 0xb2, 0xc2, 0xc5, 0x198, 0x1a4, 0x1b8, 0x38c, 0x3a4, 0x3c4, 0x3c6, 0x3dd, 0x3e8, 0xad,
    0x3af, 0x192, 0xbd, 0xbc, 0x18e, 0x197, 0x19a, 0x1a3, 0x1b1, 0x38d, 0x398, 0x3b7, 0x3d3, 0x3d1, 0x3db, 0x7dd, 0xb4,
    0x3de, 0x1a9, 0x19b, 0x19c, 0x1a1, 0x1aa, 0x1ad, 0x1b3, 0x38b, 0x3b2, 0x3b8, 0x3ce, 0x3e1, 0x3e0, 0x7d2, 0x7e5, 0xb7,
    0x7e3, 0x1bb, 0x1a8, 0x1a6, 0x1b0, 0x1b2, 0x1b7, 0x39b, 0x39a, 0x3ba, 0x3b5, 0x3d6, 0x7d7, 0x3e4, 0x7d8, 0x7ea, 0xba,
    0x7e8, 0x3a0, 0x1bd, 0x1b4, 0x38a, 0x1c4, 0x392, 0x3aa, 0x3b0, 0x3bc, 0x3d7, 0x7d4, 0x7dc, 0x7db, 0x7d5, 0x7f0, 0xc1,
    0x7fb, 0x3c8, 0x3a3, 0x395, 0x39d, 0x3ac, 0x3ae, 0x3c5, 0x3d8, 0x3e2, 0x3e6, 0x7e4, 0x7e7, 0x7e0, 0x7e9, 0x7f7, 0x190,
    0x7f2, 0x393, 0x1be, 0x1c0, 0x394, 0x397, 0x3ad, 0x3c3, 0x3c1, 0x3d2, 0x7da, 0x7d9, 0x7df, 0x7eb, 0x7f4, 0x7fa, 0x195,
    0x7f8, 0x3bd, 0x39c, 0x3ab, 0x3a8, 0x3b3, 0x3b9, 0x3d0, 0x3e3, 0x3e5, 0x7e2, 0x7de, 0x7ed, 0x7f1, 0x7f9, 0x7fc, 0x193,
    0xffd, 0x3dc, 0x3b6, 0x3c7, 0x3cc, 0x3cb, 0x3d9, 0x3da, 0x7d3, 0x7e1, 0x7ee, 0x7ef, 0x7f5, 0x7f6, 0xffc, 0xfff, 0x19d,
    0x1c2, 0xb5, 0xa1, 0x96, 0x97, 0x95, 0x99, 0xa0, 0xa2, 0xac, 0xa9, 0xb1, 0xb3, 0xbb, 0xc0, 0x18f, 0x4,
};

// ---- tests: the tables, the MDCT, and frames read back by a small
// decoder (long blocks, the eleven books: what this encoder writes) ----

const testing = std.testing;

test "every codebook is a complete prefix code" {
    try expectCode(u32, &SF_CODES, &SF_BITS);
    inline for (1..12) |book| try expectCode(u16, BOOKS[book].codes, BOOKS[book].bits);
}

fn expectCode(comptime T: type, codes: []const T, lens: []const u8) !void {
    try testing.expectEqual(codes.len, lens.len);
    var kraft: u64 = 0;
    for (lens) |l| kraft += @as(u64, 1) << @intCast(32 - l);
    try testing.expectEqual(@as(u64, 1) << 32, kraft);
    for (codes, lens, 0..) |a, la, i| {
        try testing.expect(a < (@as(u64, 1) << @intCast(la)));
        for (codes[i + 1 ..], lens[i + 1 ..]) |b, lb| {
            // neither is the other's prefix
            if (la <= lb) try testing.expect((b >> @intCast(lb - la)) != a) else try testing.expect((a >> @intCast(la - lb)) != b);
        }
    }
}

var test_enc: Encoder = .{};

test "the MDCT equals the standard's sum" {
    try test_enc.init(.{});
    var z: [SPAN]f32 = undefined;
    var seed: u32 = 1;
    for (&z) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = @as(f32, @floatFromInt(@as(i32, @bitCast(seed)) >> 16));
    }
    var fast: [FRAME]f32 = undefined;
    test_enc.mdct(&z, &fast);
    var worst: f64 = 0;
    var peak: f64 = 0;
    for (0..FRAME) |k| {
        var sum: f64 = 0;
        for (0..SPAN) |n| {
            const a = 2 * std.math.pi / @as(f64, SPAN) * (@as(f64, @floatFromInt(n)) + 512.5) * (@as(f64, @floatFromInt(k)) + 0.5);
            sum += @as(f64, z[n]) * @cos(a);
        }
        sum *= 2;
        worst = @max(worst, @abs(sum - fast[k]));
        peak = @max(peak, @abs(sum));
    }
    try testing.expect(worst < peak * 1e-4);
}

test "the header bytes: AudioSpecificConfig and ADTS" {
    try test_enc.init(.{ .sample_rate = 48_000, .channels = 2 });
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x90 }, &test_enc.audioSpecificConfig());
    var h: [ADTS_BYTES]u8 = undefined;
    try test_enc.adts(371, &h);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xf1, 0x4c, 0x80, 0x2f, 0x5f, 0xfc }, &h);
    try test_enc.init(.{ .sample_rate = 44_100, .channels = 1, .bit_rate = 64_000 });
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x08 }, &test_enc.audioSpecificConfig());
    try testing.expectError(error.InvalidSampleRate, test_enc.init(.{ .sample_rate = 32_000 }));
    try testing.expectError(error.InvalidChannels, test_enc.init(.{ .channels = 6 }));
}

test "frames read back: two tones, both channels, at the bit rate" {
    try test_enc.init(.{ .sample_rate = 48_000, .channels = 2, .bit_rate = 128_000 });
    var dec = TestDecoder{};
    const frames = 24;
    var pcm: [FRAME * 2]i16 = undefined;
    var prev_in: [FRAME * 2]i16 = undefined;
    var out: [MAX_FRAME_BYTES]u8 = undefined;
    var signal: f64 = 0;
    var noise: f64 = 0;
    var bytes: usize = 0;
    for (0..frames) |f| {
        for (0..FRAME) |n| {
            const t = @as(f64, @floatFromInt(f * FRAME + n)) / 48_000.0;
            pcm[2 * n] = @intFromFloat(9000 * @sin(2 * std.math.pi * 1000 * t) + 4000 * @sin(2 * std.math.pi * 330 * t));
            pcm[2 * n + 1] = @intFromFloat(7000 * @sin(2 * std.math.pi * 550 * t));
        }
        const frame = try test_enc.encode(&pcm, &out);
        bytes += frame.len;
        var got: [FRAME * 2]f64 = undefined;
        try dec.frame(frame, 2, &got);
        // (one frame late; the first two are the priming and the ramp)
        if (f >= 2) for (0..FRAME * 2) |i| {
            const want: f64 = @floatFromInt(prev_in[i]);
            signal += want * want;
            noise += (got[i] - want) * (got[i] - want);
        };
        prev_in = pcm;
    }
    const snr = 10 * std.math.log10(signal / noise);
    try testing.expect(snr > 30);
    const rate = bytes * 8 * 48_000 / (frames * FRAME);
    try testing.expect(rate > 60_000 and rate < 140_000);
}

test "noise holds its bit rate, and silence takes almost nothing" {
    try test_enc.init(.{ .sample_rate = 44_100, .channels = 1, .bit_rate = 96_000 });
    var dec = TestDecoder{};
    var pcm: [FRAME]i16 = undefined;
    var out: [MAX_FRAME_BYTES]u8 = undefined;
    var seed: u32 = 7;
    var bytes: usize = 0;
    const frames = 43; // a second
    for (0..frames) |_| {
        for (&pcm) |*v| {
            seed = seed *% 1103515245 +% 12345;
            v.* = @truncate(@as(i32, @bitCast(seed)) >> 18);
        }
        const frame = try test_enc.encode(&pcm, &out);
        bytes += frame.len;
        var got: [FRAME]f64 = undefined;
        try dec.frame(frame, 1, &got);
    }
    const rate = bytes * 8 * 44_100 / (frames * FRAME);
    try testing.expect(rate > 80_000 and rate <= 100_000);
    @memset(&pcm, 0);
    for (0..3) |_| _ = try test_enc.encode(&pcm, &out);
    const quiet = try test_enc.encode(&pcm, &out);
    try testing.expect(quiet.len < 8);
}

/// What the tests read frames back with: the parts of an AAC-LC decoder
/// this encoder's frames use (long blocks, sine window, no tools).
const TestDecoder = struct {
    overlap: [2][FRAME]f64 = [_][FRAME]f64{[_]f64{0} ** FRAME} ** 2,

    fn frame(d: *TestDecoder, raw: []const u8, channels: usize, pcm: []f64) !void {
        var r = BitReader{ .buf = raw };
        try testing.expectEqual(@as(u32, if (channels == 2) 1 else 0), r.bits(3));
        _ = r.bits(4);
        if (channels == 2) try testing.expectEqual(@as(u32, 0), r.bits(1));
        var spec: [2][FRAME]f64 = undefined;
        for (0..channels) |c| try readIcs(&r, &spec[c]);
        try testing.expectEqual(@as(u32, 7), r.bits(3));
        try testing.expect((r.at + 7) / 8 == raw.len);
        for (0..channels) |c| {
            var time: [SPAN]f64 = undefined;
            imdct(&spec[c], &time);
            for (0..FRAME) |n| {
                pcm[n * channels + c] = time[n] * sine(n) + d.overlap[c][n];
                d.overlap[c][n] = time[FRAME + n] * sine(FRAME + n);
            }
        }
    }

    fn readIcs(r: *BitReader, spec: *[FRAME]f64) !void {
        const gain: i32 = @intCast(r.bits(8));
        try testing.expectEqual(@as(u32, 0), r.bits(4)); // reserved, long only, sine
        const max_sfb = r.bits(6);
        try testing.expectEqual(@as(u32, 0), r.bits(1));
        var books: [BANDS]u4 = [_]u4{0} ** BANDS;
        var b: usize = 0;
        while (b < max_sfb) {
            const book: u4 = @intCast(r.bits(4));
            var len: usize = 0;
            while (true) {
                const inc = r.bits(5);
                len += inc;
                if (inc != 31) break;
            }
            for (b..b + len) |i| books[i] = book;
            b += len;
        }
        try testing.expectEqual(@as(usize, max_sfb), b);
        var sf: [BANDS]i32 = undefined;
        var offset = gain;
        for (0..max_sfb) |s| if (books[s] != ZERO_BOOK) {
            offset += @as(i32, @intCast(try r.huff(u32, &SF_CODES, &SF_BITS))) - 60;
            sf[s] = offset;
        };
        try testing.expectEqual(@as(u32, 0), r.bits(3)); // no pulse, TNS, gain control
        @memset(spec, 0);
        for (0..max_sfb) |s| {
            const book = books[s];
            if (book == ZERO_BOOK) continue;
            const bk = BOOKS[book];
            const scale = std.math.pow(f64, 2, 0.25 * (@as(f64, @floatFromInt(sf[s])) - 100));
            var k: usize = SWB[s];
            while (k < SWB[s + 1]) : (k += bk.dim) {
                var index = try r.huff(u16, bk.codes, bk.bits);
                var v: [4]i32 = undefined;
                var i = bk.dim;
                while (i > 0) {
                    i -= 1;
                    if (bk.signed) {
                        const base = 2 * @as(usize, bk.lav) + 1;
                        v[i] = @as(i32, @intCast(index % base)) - bk.lav;
                        index /= base;
                    } else {
                        const base: usize = if (book == ESC_BOOK) 17 else @as(usize, bk.lav) + 1;
                        v[i] = @intCast(index % base);
                        index /= base;
                    }
                }
                if (!bk.signed) {
                    for (v[0..bk.dim]) |*x| if (x.* != 0 and r.bits(1) == 1) {
                        x.* = -x.*;
                    };
                    if (book == ESC_BOOK) for (v[0..bk.dim]) |*x| if (@abs(x.*) == 16) {
                        var n: u5 = 4;
                        while (r.bits(1) == 1) n += 1;
                        const mag: i32 = @intCast((@as(u32, 1) << n) + r.bits(n));
                        x.* = if (x.* < 0) -mag else mag;
                    };
                }
                for (v[0..bk.dim], 0..) |x, j| {
                    const m = std.math.pow(f64, @floatFromInt(@abs(x)), 4.0 / 3.0) * scale;
                    spec[k + j] = if (x < 0) -m else m;
                }
            }
        }
    }

    /// The standard's IMDCT: x[n] = 2/N sum X[k] cos(2 pi / N (n + n0)(k + 1/2)),
    /// each line's cosine walked by rotation.
    fn imdct(spec: *const [FRAME]f64, time: *[SPAN]f64) void {
        @memset(time, 0);
        for (0..FRAME) |k| {
            if (spec[k] == 0) continue;
            const w = 2 * std.math.pi / @as(f64, SPAN) * (@as(f64, @floatFromInt(k)) + 0.5);
            var re = @cos(w * 512.5);
            var im = @sin(w * 512.5);
            const cr = @cos(w);
            const ci = @sin(w);
            const amp = spec[k] * 2 / @as(f64, SPAN);
            for (0..SPAN) |n| {
                time[n] += amp * re;
                const t = re * cr - im * ci;
                im = re * ci + im * cr;
                re = t;
            }
        }
    }

    fn sine(n: usize) f64 {
        return @sin(std.math.pi / @as(f64, SPAN) * (@as(f64, @floatFromInt(n)) + 0.5));
    }
};

const BitReader = struct {
    buf: []const u8,
    at: usize = 0,

    fn bits(r: *BitReader, n: u6) u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            const bit = if (r.at / 8 < r.buf.len) (r.buf[r.at / 8] >> @intCast(7 - r.at % 8)) & 1 else 0;
            v = (v << 1) | bit;
            r.at += 1;
        }
        return v;
    }

    /// One codeword of a code (a linear search: tests only).
    fn huff(r: *BitReader, comptime T: type, codes: []const T, lens: []const u8) !usize {
        var v: u32 = 0;
        var n: u8 = 0;
        while (n < 20) {
            v = (v << 1) | r.bits(1);
            n += 1;
            for (codes, lens, 0..) |c, l, i| if (l == n and c == v) return i;
        }
        return error.NoSuchCodeword;
    }
};
