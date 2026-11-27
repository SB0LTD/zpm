//! Native AAC-LC raw_data_block to reconstructed spectra.
//! Implements Huffman/scalefactor decoding, inverse quantization, channel
//! pairing, M/S and intensity stereo, PNS, pulse correction and TNS. The
//! filterbank is a separate pure module. Unsupported profiles/coupling are
//! explicit failures, never interpreted as PCM or silently approximated.
const std = @import("std");
const mp4 = @import("mp4.sig");
const tables = @import("aac_tables.sig");
pub const Error = error{ UnexpectedEof, InvalidData, InvalidCodeword, UnsupportedElement, UnsupportedProfile, InvalidBand, InvalidScale, InvalidSpectrum, InvalidTns };

pub const Info = struct {
    window_sequence: u2 = 0,
    window_shape: u1 = 0,
    max_sfb: usize = 0,
    group_count: usize = 1,
    group_lengths: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    pub fn short(self: Info) bool {
        return self.window_sequence == 2;
    }
    pub fn windowCount(self: Info) usize {
        return if (self.short()) 8 else 1;
    }
};
const TnsFilter = struct { length: usize = 0, order: usize = 0, reverse: bool = false, coefficients: [20]f32 = @splat(0) };
const Tns = struct { count: [8]u8 = @splat(0), filters: [8][3]TnsFilter = @splat(@splat(.{})) };
pub const Channel = struct {
    info: Info = .{},
    spectrum: [1024]f32 = @splat(0),
    quantized: [1024]i32 = @splat(0),
    codebooks: [8][64]u8 = @splat(@splat(0)),
    scalefactors: [8][64]i32 = @splat(@splat(0)),
    tns: Tns = .{},
};

pub const Decoder = struct {
    config: mp4.Config,
    channels: [2]Channel = @splat(.{}),
    ms_used: [8][64]bool = @splat(@splat(false)),
    noise_state: u32 = 0x1f2e3d4c,
    frames: u64 = 0,
    failure_bit: usize = 0,
    stage: enum { element, info, sections, scales, pulse, tns, spectral, stereo, trailing } = .element,
    pub fn init(config: mp4.Config) Error!Decoder {
        if (config.object_type != 2 or config.frequency_index >= tables.long_bands.len or
            config.channels == 0 or config.channels > 2) return error.UnsupportedProfile;
        if (config.sample_rate != mp4.SAMPLE_RATES[config.frequency_index]) return error.UnsupportedProfile;
        return .{ .config = config };
    }

    /// On success, channels[0..config.channels].spectrum is ready for IMDCT.
    /// A failed frame is terminal for a contiguous decode; do not publish it.
    pub fn decode(self: *Decoder, packet: []const u8) Error!void {
        if (packet.len == 0 or packet.len > 8192) return error.InvalidData;
        var bits: Bits = .{ .data = packet };
        errdefer self.failure_bit = bits.position;
        var decoded: usize = 0;
        var elements: usize = 0;
        self.ms_used = @splat(@splat(false));
        while (true) {
            self.stage = .element;
            elements += 1;
            if (elements > 32) return error.InvalidData;
            const kind = try bits.read(3);
            switch (kind) {
                0 => {
                    if (decoded != 0 or self.config.channels != 1) return error.UnsupportedElement;
                    _ = try bits.read(4);
                    try self.channel(&bits, 0, false);
                    decoded = 1;
                },
                1 => {
                    if (decoded != 0 or self.config.channels != 2) return error.UnsupportedElement;
                    _ = try bits.read(4);
                    const common = try bits.read(1) != 0;
                    if (common) {
                        self.channels[0].info = try self.info(&bits);
                        self.channels[1].info = self.channels[0].info;
                        const mask = try bits.read(2);
                        if (mask == 3) return error.InvalidData;
                        for (0..self.channels[0].info.group_count) |g| {
                            for (0..self.channels[0].info.max_sfb) |band| {
                                self.ms_used[g][band] = mask == 2 or (mask == 1 and try bits.read(1) != 0);
                            }
                        }
                    }
                    try self.channel(&bits, 0, common);
                    try self.channel(&bits, 1, common);
                    if (common) try self.stereo();
                    decoded = 2;
                },
                4 => { // Ancillary data_stream_element.
                    _ = try bits.read(4);
                    const byte_aligned = try bits.read(1) != 0;
                    var count = try bits.read(8);
                    if (count == 255) count += try bits.read(8);
                    if (byte_aligned) bits.byteAlign();
                    try bits.skip(@as(usize, count) * 8);
                },
                6 => { // Fill/ancillary bytes; reject SBR rather than drop it.
                    var count = try bits.read(4);
                    if (count == 15) count = count - 1 + try bits.read(8);
                    if (count > 0) {
                        const extension = try bits.read(4);
                        if (extension == 13 or extension == 14) return error.UnsupportedProfile;
                        try bits.skip(@as(usize, count) * 8 - 4);
                    }
                },
                7 => break,
                else => return error.UnsupportedElement,
            }
        }
        self.stage = .trailing;
        if (decoded != self.config.channels or bits.remaining() > 7) return error.InvalidData;
        // byte_alignment() bits have no prescribed value in raw_data_block.
        if (bits.remaining() > 0) _ = try bits.read(@intCast(bits.remaining()));
        for (self.channels[0..decoded]) |*channel_data| try self.applyTns(channel_data);
        self.frames += 1;
    }

    fn info(self: *const Decoder, bits: *Bits) Error!Info {
        if (try bits.read(1) != 0) return error.InvalidData;
        var result: Info = .{ .window_sequence = @intCast(try bits.read(2)), .window_shape = @intCast(try bits.read(1)) };
        if (result.short()) {
            result.max_sfb = try bits.read(4);
            const grouping = try bits.read(7);
            for (1..8) |window| {
                if (grouping & (@as(u32, 1) << @as(u5, @intCast(7 - window))) != 0) {
                    result.group_lengths[result.group_count - 1] += 1;
                } else {
                    result.group_lengths[result.group_count] = 1;
                    result.group_count += 1;
                }
            }
        } else {
            result.max_sfb = try bits.read(6);
            if (try bits.read(1) != 0) return error.UnsupportedProfile;
        }
        const bands = self.bandOffsets(result);
        if (result.max_sfb >= bands.len) return error.InvalidBand;
        return result;
    }

    fn bandOffsets(self: *const Decoder, value: Info) []const u16 {
        return if (value.short()) tables.short_bands[self.config.frequency_index] else tables.long_bands[self.config.frequency_index];
    }

    fn channel(self: *Decoder, bits: *Bits, index: usize, common: bool) Error!void {
        var channel_data = &self.channels[index];
        const gain: i32 = @intCast(try bits.read(8));
        self.stage = .info;
        if (!common) channel_data.info = try self.info(bits);
        const value = channel_data.info;
        const bands = self.bandOffsets(value);
        channel_data.codebooks = @splat(@splat(0));
        channel_data.scalefactors = @splat(@splat(0));
        @memset(&channel_data.spectrum, 0);
        @memset(&channel_data.quantized, 0);
        channel_data.tns = .{};
        self.stage = .sections;
        for (0..value.group_count) |g| {
            var band: usize = 0;
            while (band < value.max_sfb) {
                const codebook: u8 = @intCast(try bits.read(4));
                if (codebook == 12 or (index == 0 and codebook >= 14)) return error.InvalidBand;
                const width: u6 = if (value.short()) 3 else 5;
                const escape = (@as(u32, 1) << @as(u5, @intCast(width))) - 1;
                var count: usize = 0;
                while (true) {
                    const increment = try bits.read(width);
                    count += increment;
                    if (count > value.max_sfb - band) return error.InvalidBand;
                    if (increment != escape) break;
                }
                if (count == 0) return error.InvalidBand;
                @memset(channel_data.codebooks[g][band..][0..count], codebook);
                band += count;
            }
        }
        var scale = gain;
        var noise = gain - 90;
        var intensity: i32 = 0;
        var first_noise = true;
        self.stage = .scales;
        for (0..value.group_count) |g| for (0..value.max_sfb) |band| {
            const codebook = channel_data.codebooks[g][band];
            var absolute: i32 = 0;
            if (codebook == 13) {
                noise += if (first_noise) @as(i32, @intCast(try bits.read(9))) - 256 else @as(i32, @intCast(try symbol(bits, 0))) - 60;
                first_noise = false;
                if (noise < -100 or noise > 155) return error.InvalidScale;
                absolute = noise;
            } else if (codebook >= 14) {
                intensity += @as(i32, @intCast(try symbol(bits, 0))) - 60;
                if (intensity < -155 or intensity > 100) return error.InvalidScale;
                absolute = intensity;
            } else if (codebook != 0) {
                scale += @as(i32, @intCast(try symbol(bits, 0))) - 60;
                if (scale < 0 or scale > 255) return error.InvalidScale;
                absolute = scale;
            }
            channel_data.scalefactors[g][band] = absolute;
        };

        var pulse_count: usize = 0;
        self.stage = .pulse;
        var pulse_positions: [4]usize = undefined;
        var pulse_amplitudes: [4]i32 = undefined;
        if (try bits.read(1) != 0) {
            if (value.short()) return error.InvalidData;
            pulse_count = try bits.read(2) + 1;
            const start = try bits.read(6);
            if (start >= bands.len - 1) return error.InvalidBand;
            var position: usize = bands[start];
            for (0..pulse_count) |pulse| {
                position += try bits.read(5);
                if (position >= 1024) return error.InvalidSpectrum;
                pulse_positions[pulse] = position;
                pulse_amplitudes[pulse] = @intCast(try bits.read(4));
            }
        }
        self.stage = .tns;
        if (try bits.read(1) != 0) try parseTns(bits, channel_data);
        if (try bits.read(1) != 0) return error.UnsupportedProfile; // SSR gain control.

        var group_window: usize = 0;
        self.stage = .spectral;
        const window_size: usize = if (value.short()) 128 else 1024;
        for (0..value.group_count) |g| {
            for (0..value.max_sfb) |band| {
                const codebook = channel_data.codebooks[g][band];
                if (codebook == 0 or codebook >= 13) continue;
                const tuple_size: usize = if (codebook <= 4) 4 else 2;
                if ((bands[band + 1] - bands[band]) % tuple_size != 0) return error.InvalidBand;
                for (0..value.group_lengths[g]) |window| {
                    var bin: usize = bands[band];
                    while (bin < bands[band + 1]) : (bin += tuple_size) {
                        const tuple = try spectralTuple(bits, codebook);
                        for (0..tuple_size) |component|
                            channel_data.quantized[(group_window + window) * window_size + bin + component] = tuple[component];
                    }
                }
            }
            group_window += value.group_lengths[g];
        }
        for (0..pulse_count) |pulse| {
            const q = &channel_data.quantized[pulse_positions[pulse]];
            q.* += if (q.* > 0) pulse_amplitudes[pulse] else -pulse_amplitudes[pulse];
        }
        group_window = 0;
        for (0..value.group_count) |g| {
            for (0..value.max_sfb) |band| {
                const codebook = channel_data.codebooks[g][band];
                const absolute = channel_data.scalefactors[g][band];
                for (0..value.group_lengths[g]) |window| {
                    const start = (group_window + window) * window_size + bands[band];
                    const end = (group_window + window) * window_size + bands[band + 1];
                    if (codebook == 13) {
                        const target = @exp2(@as(f32, @floatFromInt(absolute)) * 0.25);
                        var energy: f64 = 0;
                        for (channel_data.spectrum[start..end]) |*coefficient| {
                            self.noise_state = self.noise_state *% 1664525 +% 1013904223;
                            coefficient.* = @as(f32, @floatFromInt(@as(i32, @bitCast(self.noise_state)))) / 2147483648;
                            energy += @as(f64, coefficient.*) * coefficient.*;
                        }
                        if (energy > 0) {
                            for (channel_data.spectrum[start..end]) |*coefficient|
                                coefficient.* *= target / @as(f32, @floatCast(@sqrt(energy)));
                        }
                    } else if (codebook != 0 and codebook < 12) {
                        const multiplier = scale_factors[@intCast(absolute)];
                        for (start..end) |bin| {
                            const q = channel_data.quantized[bin];
                            const magnitude = @abs(q);
                            if (magnitude >= inverse_quant.len) return error.InvalidSpectrum;
                            channel_data.spectrum[bin] = inverse_quant[magnitude] * multiplier * (if (q < 0) @as(f32, -1) else 1);
                        }
                    }
                }
            }
            group_window += value.group_lengths[g];
        }
    }

    fn stereo(self: *Decoder) Error!void {
        var left = &self.channels[0];
        var right = &self.channels[1];
        const value = left.info;
        const bands = self.bandOffsets(value);
        const width: usize = if (value.short()) 128 else 1024;
        var group_window: usize = 0;
        for (0..value.group_count) |g| {
            for (0..value.max_sfb) |band| {
                const lcb = left.codebooks[g][band];
                const rcb = right.codebooks[g][band];
                const ms = self.ms_used[g][band];
                for (0..value.group_lengths[g]) |window| {
                    const start = (group_window + window) * width + bands[band];
                    const end = (group_window + window) * width + bands[band + 1];
                    if (rcb >= 14) {
                        const phase: f32 = (if (rcb == 15) @as(f32, 1) else -1) * (if (ms) @as(f32, -1) else 1);
                        const gain = phase * @exp2(@as(f32, @floatFromInt(-right.scalefactors[g][band])) * 0.25);
                        for (start..end) |bin| right.spectrum[bin] = left.spectrum[bin] * gain;
                    } else if (lcb == 13 and rcb == 13 and ms) {
                        const gain = @exp2(@as(f32, @floatFromInt(right.scalefactors[g][band] - left.scalefactors[g][band])) * 0.25);
                        for (start..end) |bin| right.spectrum[bin] = left.spectrum[bin] * gain;
                    } else if (ms and lcb != 13 and rcb != 13) {
                        for (start..end) |bin| {
                            const mid = left.spectrum[bin];
                            const side = right.spectrum[bin];
                            left.spectrum[bin] = mid + side;
                            right.spectrum[bin] = mid - side;
                        }
                    }
                }
            }
            group_window += value.group_lengths[g];
        }
    }

    fn applyTns(self: *const Decoder, channel_data: *Channel) Error!void {
        const value = channel_data.info;
        const bands = self.bandOffsets(value);
        const max_band = @min(value.max_sfb, if (value.short()) tables.tns_short_limit[self.config.frequency_index] else tables.tns_long_limit[self.config.frequency_index]);
        const width: usize = if (value.short()) 128 else 1024;
        for (0..value.windowCount()) |window| {
            var top = bands.len - 1;
            for (channel_data.tns.filters[window][0..channel_data.tns.count[window]]) |filter| {
                const bottom = top -| filter.length;
                const start = bands[@min(bottom, max_band)];
                const end = bands[@min(top, max_band)];
                top = bottom;
                if (filter.order == 0 or end <= start) continue;
                var lpc: [20]f32 = @splat(0);
                for (0..filter.order) |order| {
                    const reflection = -filter.coefficients[order];
                    var temporary = lpc;
                    for (0..order) |i| temporary[i] += reflection * lpc[order - 1 - i];
                    temporary[order] = reflection;
                    lpc = temporary;
                }
                var history: [20]f32 = @splat(0);
                for (0..end - start) |step| {
                    const bin = window * width + (if (filter.reverse) end - 1 - step else start + step);
                    var sample = channel_data.spectrum[bin];
                    for (0..filter.order) |order| sample -= lpc[order] * history[order];
                    if (!std.math.isFinite(sample)) return error.InvalidTns;
                    var order = filter.order - 1;
                    while (order > 0) : (order -= 1) history[order] = history[order - 1];
                    history[0] = sample;
                    channel_data.spectrum[bin] = sample;
                }
            }
        }
    }
};

fn parseTns(bits: *Bits, channel: *Channel) Error!void {
    const short = channel.info.short();
    for (0..channel.info.windowCount()) |window| {
        const count = try bits.read(if (short) 1 else 2);
        channel.tns.count[window] = @intCast(count);
        if (count == 0) continue;
        const resolution: u6 = @intCast(3 + try bits.read(1));
        for (channel.tns.filters[window][0..count]) |*filter| {
            filter.length = try bits.read(if (short) 4 else 6);
            filter.order = try bits.read(if (short) 3 else 5);
            if (filter.order > (if (short) @as(usize, 7) else 12)) return error.InvalidTns;
            if (filter.order == 0) continue;
            filter.reverse = try bits.read(1) != 0;
            const compression = try bits.read(1);
            const width: u6 = @intCast(resolution - compression);
            for (filter.coefficients[0..filter.order]) |*coefficient| {
                const signed = try bits.signed(width);
                const denominator: f32 = @as(f32, @floatFromInt(@as(u32, 1) << @as(u5, @intCast(resolution)))) - (if (signed >= 0) @as(f32, 1) else -1);
                coefficient.* = -@sin(std.math.pi * @as(f32, @floatFromInt(signed)) / denominator);
            }
        }
    }
}

pub const Bits = struct {
    data: []const u8,
    position: usize = 0,
    pub fn remaining(self: Bits) usize {
        return self.data.len * 8 - self.position;
    }
    pub fn read(self: *Bits, count: u6) Error!u32 {
        if (count > 32 or count > self.remaining()) return error.UnexpectedEof;
        if (count == 0) return 0;
        if (count == 1) {
            const value = (self.data[self.position / 8] >> @as(u3, @intCast(7 - self.position % 8))) & 1;
            self.position += 1;
            return value;
        }
        const start = self.position / 8;
        const offset = self.position % 8;
        const length = (offset + count + 7) / 8;
        var value: u64 = 0;
        for (self.data[start..][0..length]) |byte| value = (value << 8) | byte;
        value >>= @as(u6, @intCast(length * 8 - offset - count));
        self.position += count;
        return @truncate(value & ((@as(u64, 1) << count) - 1));
    }
    pub fn signed(self: *Bits, count: u6) Error!i32 {
        const value = try self.read(count);
        if (count == 0 or count > 31) return error.InvalidData;
        const shift: u5 = @intCast(32 - count);
        return @as(i32, @bitCast(value << shift)) >> shift;
    }
    pub fn skip(self: *Bits, count: usize) Error!void {
        if (count > self.remaining()) return error.UnexpectedEof;
        self.position += count;
    }
    pub fn byteAlign(self: *Bits) void {
        self.position = (self.position + 7) & ~@as(usize, 7);
    }
};

const Book = struct { codes: []const u32, bits: []const u8 };
const books = [_]Book{
    .{ .codes = &tables.scalefactor_codes, .bits = &tables.scalefactor_bits },
    .{ .codes = &tables.codes1, .bits = &tables.bits1 },
    .{ .codes = &tables.codes2, .bits = &tables.bits2 },
    .{ .codes = &tables.codes3, .bits = &tables.bits3 },
    .{ .codes = &tables.codes4, .bits = &tables.bits4 },
    .{ .codes = &tables.codes5, .bits = &tables.bits5 },
    .{ .codes = &tables.codes6, .bits = &tables.bits6 },
    .{ .codes = &tables.codes7, .bits = &tables.bits7 },
    .{ .codes = &tables.codes8, .bits = &tables.bits8 },
    .{ .codes = &tables.codes9, .bits = &tables.bits9 },
    .{ .codes = &tables.codes10, .bits = &tables.bits10 },
    .{ .codes = &tables.codes11, .bits = &tables.bits11 },
};
const Node = struct { children: [2]u16 = @splat(0xffff), value: i16 = -1 };
const Tree = struct { nodes: [600]Node = @splat(.{}), count: usize = 1 };
const trees = blk: {
    @setEvalBranchQuota(400000);
    var all: [books.len]Tree = @splat(.{});
    for (books, 0..) |book, b| for (book.codes, book.bits, 0..) |code, length, id| {
        var at: usize = 0;
        var remaining = length;
        while (remaining > 0) {
            remaining -= 1;
            const bit = (code >> @as(u5, @intCast(remaining))) & 1;
            if (all[b].nodes[at].value >= 0) @compileError("AAC codebook is not prefix-free");
            if (all[b].nodes[at].children[bit] == 0xffff) {
                all[b].nodes[at].children[bit] = @intCast(all[b].count);
                all[b].count += 1;
            }
            at = all[b].nodes[at].children[bit];
        }
        if (all[b].nodes[at].value >= 0 or all[b].nodes[at].children[0] != 0xffff or all[b].nodes[at].children[1] != 0xffff)
            @compileError("AAC codebook has duplicate or prefix codeword");
        all[b].nodes[at].value = @intCast(id);
    };
    break :blk all;
};
fn symbol(bits: *Bits, book: usize) Error!u32 {
    var at: usize = 0;
    for (0..20) |_| {
        const value = trees[book].nodes[at].value;
        if (value >= 0) return @intCast(value);
        const child = trees[book].nodes[at].children[try bits.read(1)];
        if (child == 0xffff) return error.InvalidCodeword;
        at = child;
    }
    return error.InvalidCodeword;
}

fn spectralTuple(bits: *Bits, book: u8) Error![4]i32 {
    var code = try symbol(bits, book);
    const width: usize = if (book <= 4) 4 else 2;
    const radix: u32 = if (book <= 4) 3 else if (book <= 6) 9 else if (book <= 8) 8 else if (book <= 10) 13 else 17;
    const signed = book == 1 or book == 2 or book == 5 or book == 6;
    const bias: i32 = if (book <= 2) 1 else if (book <= 6 and signed) 4 else 0;
    var values: [4]i32 = @splat(0);
    var i = width;
    while (i > 0) {
        i -= 1;
        values[i] = @as(i32, @intCast(code % radix)) - bias;
        code /= radix;
    }
    if (!signed) for (values[0..width]) |*value| if (value.* != 0 and try bits.read(1) != 0) {
        value.* = -value.*;
    };
    if (book == 11) for (values[0..width]) |*value| if (@abs(value.*) == 16) {
        var exponent: u6 = 4;
        while (try bits.read(1) != 0) {
            exponent += 1;
            if (exponent > 12) return error.InvalidSpectrum;
        }
        const magnitude = (@as(u32, 1) << @as(u5, @intCast(exponent))) + try bits.read(exponent);
        value.* = @as(i32, @intCast(magnitude)) * (if (value.* < 0) @as(i32, -1) else 1);
    };
    return values;
}

const inverse_quant = blk: {
    @setEvalBranchQuota(200000);
    // Four pulse corrections can add sixty to an escaped8191 coefficient.
    var values: [8256]f32 = undefined;
    values[0] = 0;
    for (1..values.len) |i| values[i] = @floatCast(@exp(@log(@as(f64, @floatFromInt(i))) * (4.0 / 3.0)));
    break :blk values;
};
const scale_factors = blk: {
    var values: [256]f32 = undefined;
    for (&values, 0..) |*value, i| value.* = @floatCast(@exp2((@as(f64, @floatFromInt(i)) - 100) * 0.25));
    break :blk values;
};

test "all normative Huffman codewords independently roundtrip without prefix ambiguity" {
    for (books, 0..) |book, b| for (book.codes, book.bits, 0..) |code, length, index| {
        var bytes: [4]u8 = @splat(0);
        const aligned = code << @as(u5, @intCast(32 - length));
        for (&bytes, 0..) |*byte, i| byte.* = @truncate(aligned >> @as(u5, @intCast(24 - i * 8)));
        var bits: Bits = .{ .data = &bytes };
        try std.testing.expectEqual(@as(u32, @intCast(index)), try symbol(&bits, b));
        try std.testing.expectEqual(@as(usize, length), bits.position);
    };
}

test "bitreader validates bounds and signed fields" {
    var bits: Bits = .{ .data = &.{ 0xab, 0xcd, 0xef } };
    try std.testing.expectEqual(@as(u32, 0xabc), try bits.read(12));
    try std.testing.expectEqual(@as(i32, -3), try bits.signed(4));
    try std.testing.expectEqual(@as(u32, 0xef), try bits.read(8));
    try std.testing.expectError(error.UnexpectedEof, bits.read(1));
}

const TestWriter = struct {
    bytes: [128]u8 = @splat(0),
    position: usize = 0,
    fn put(self: *TestWriter, value: u32, width: u6) void {
        var remaining = width;
        while (remaining > 0) {
            remaining -= 1;
            const bit = (value >> @as(u5, @intCast(remaining))) & 1;
            self.bytes[self.position / 8] |= @as(u8, @intCast(bit)) << @as(u3, @intCast(7 - self.position % 8));
            self.position += 1;
        }
    }
    fn zeroChannel(self: *TestWriter, common: bool) void {
        self.put(100, 8);
        if (!common) self.zeroInfo();
        self.put(0, 3); // No pulse/TNS/gain control, no bands.
    }
    fn zeroInfo(self: *TestWriter) void {
        self.put(0, 11);
    }
    fn finish(self: *TestWriter) []const u8 {
        self.put(7, 3);
        // Alignment is explicitly unspecified; nonzero padding is valid.
        while (self.position % 8 != 0) self.put(1, 1);
        return self.bytes[0 .. self.position / 8];
    }
};

test "real AAC LC syntax accepts silent mono stereo fill escape zero and arbitrary padding" {
    var writer: TestWriter = .{};
    writer.put(0, 3);
    writer.put(0, 4);
    writer.zeroChannel(false);
    const mono = writer.finish();
    var decoder = try Decoder.init(.{ .sample_rate = 44100, .channels = 1, .object_type = 2, .frequency_index = 4 });
    try decoder.decode(mono);
    for (decoder.channels[0].spectrum) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
    for (0..mono.len) |length| {
        if (decoder.decode(mono[0..length])) |_| return error.TestUnexpectedResult else |_| {}
    }
    writer = .{};
    writer.put(1, 3);
    writer.put(0, 4);
    writer.put(1, 1);
    writer.zeroInfo();
    writer.put(0, 2);
    writer.zeroChannel(true);
    writer.zeroChannel(true);
    writer.put(6, 3);
    writer.put(15, 4);
    writer.put(0, 8); //14bytes fill; escape0 must not underflow.
    for (0..14) |_| writer.put(0, 8);
    const stereo = writer.finish();
    decoder = try Decoder.init(.{ .sample_rate = 44100, .channels = 2, .object_type = 2, .frequency_index = 4 });
    try decoder.decode(stereo);
    for (decoder.channels) |channel_data| for (channel_data.spectrum) |sample|
        try std.testing.expectEqual(@as(f32, 0), sample);
}

test "AAC malformed access unit corpus terminates with bounded explicit errors" {
    var seed: u32 = 0x91e10da5;
    var packet: [64]u8 = undefined;
    var decoder = try Decoder.init(.{ .sample_rate = 44100, .channels = 2, .object_type = 2, .frequency_index = 4 });
    for (0..2048) |trial| {
        for (&packet) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @truncate(seed >> 16);
        }
        decoder = try Decoder.init(.{ .sample_rate = 44100, .channels = 2, .object_type = 2, .frequency_index = 4 });
        decoder.decode(packet[0 .. 1 + trial % packet.len]) catch {};
    }
}
