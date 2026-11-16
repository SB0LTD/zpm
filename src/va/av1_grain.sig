//! @zpm/va av1_grain — AV1 film grain for the RTX's decoder: what
//! nvdec_av1_pic_s's fgs_cfg and the film grain buffer (nvdec_drv.h's
//! AV1FilmGrainMemory) hold, made on the CPU from a frame's
//! film_grain_params (VA's VAFilmGrainStructAV1), so the decoder applies
//! the grain itself and writes the graded picture to the display buffer
//! (current_display_picture): the picture that is shown, as the stream's
//! author meant it, with no pass of its own.
//!
//! The buffer, per the AV1 specification (7.18.3.3 generate_grain, 7.18.3.4
//! scaling_lookup_init), as dav1d and libaom make the same:
//!
//! - three scaling lookup tables (Y, Cb, Cr), 256 entries each: the
//!   piecewise-linear scaling function at each 8-bit value (a chroma plane
//!   takes the luma's with chroma_scaling_from_luma);
//! - the luma grain template (82 x 73, Gaussian noise from the 16-bit
//!   LFSR seeded with grain_seed, then the auto-regressive filter), cropped
//!   to the 64 x 64 a block's grain is ever read from: rows and columns 9
//!   to 72 (the random offsets reach 9 + 2 * 15 + 33);
//! - the chroma templates (44 x 38 for 4:2:0, seeds grain_seed ^ 0xb524
//!   and ^ 0x49d8, their AR filter with the luma's contribution), cropped
//!   to 32 x 32: rows and columns 6 to 37.
//!
//! ASSUMED, for a boot to confirm: the crops' origin (above, from the
//! offsets the specification reads at), fgs_cfg's scaling_shift as
//! ScalingShift itself (grain_scaling_minus_8 + 8), and the Cb/Cr
//! multipliers and offsets as the syntax elements' raw values (VA's,
//! CUVID's). A wrong guess shows as wrong grain, never a wrong picture
//! underneath: the reference (current_frame) stays grain free.
//!
//! The Gaussian sequence is the specification's (dav1d's table).
//!
//! Allocation-free.

const std = @import("std");
const vaav1 = @import("vaapi_av1.sig");

pub const LUMA_W = 82;
pub const LUMA_H = 73;
pub const CHROMA_W = 44;
pub const CHROMA_H = 38;
/// The crops' sizes and origins.
pub const LUMA_CROP = 64;
pub const LUMA_CROP_AT = 9;
pub const CHROMA_CROP = 32;
pub const CHROMA_CROP_AT = 6;

/// AV1FilmGrainMemory (nvdec_drv.h).
pub const Memory = extern struct {
    scaling_lut_y: [256]u8,
    scaling_lut_cb: [256]u8,
    scaling_lut_cr: [256]u8,
    cropped_luma_grain_block: [LUMA_CROP * LUMA_CROP]i16,
    cropped_cb_grain_block: [CHROMA_CROP * CHROMA_CROP]i16,
    cropped_cr_grain_block: [CHROMA_CROP * CHROMA_CROP]i16,
};

comptime {
    // (sizeof(AV1FilmGrainMemory): 768 + 2 * (4096 + 1024 + 1024))
    std.debug.assert(@sizeOf(Memory) == 13056);
    std.debug.assert(@offsetOf(Memory, "cropped_luma_grain_block") == 768);
}

/// The specification's 16-bit LFSR (get_random_number).
pub const Random = struct {
    state: u16,

    pub fn next(r: *Random, bits: u4) u16 {
        const s: u32 = r.state;
        const bit = (s ^ (s >> 1) ^ (s >> 3) ^ (s >> 12)) & 1;
        r.state = @truncate((s >> 1) | (bit << 15));
        return @truncate((@as(u32, r.state) >> (16 - @as(u5, bits))) & ((@as(u32, 1) << bits) - 1));
    }
};

fn round2(x: i32, shift: u5) i32 {
    if (shift == 0) return x;
    return (x + (@as(i32, 1) << (shift - 1))) >> shift;
}

/// The grain templates, uncropped (the specification's LumaGrain,
/// CbGrain, CrGrain).
pub const Templates = struct {
    luma: [LUMA_H][LUMA_W]i32,
    cb: [CHROMA_H][CHROMA_W]i32,
    cr: [CHROMA_H][CHROMA_W]i32,
};

const Chroma = struct { seed: u16, n: u8, coeffs: *const [25]i8, out: *[CHROMA_H][CHROMA_W]i32 };

/// generate_grain for 4:2:0 at `bit_depth` (8 or 10).
pub fn generate(g: *const vaav1.FilmGrain, bit_depth: u32, t: *Templates) void {
    const f = g.film_grain_info_fields;
    const shift: u5 = @intCast(12 - bit_depth + f.grain_scale_shift);
    const center: i32 = @as(i32, 128) << @intCast(bit_depth - 8);
    const gmin = -center;
    const gmax = (@as(i32, 256) << @intCast(bit_depth - 8)) - 1 - center;
    const lag: i32 = f.ar_coeff_lag;
    const ar_shift: u5 = @as(u5, f.ar_coeff_shift_minus_6) + 6;

    // luma
    var rng = Random{ .state = g.grain_seed };
    for (&t.luma) |*row| {
        for (row) |*v| v.* = if (g.num_y_points > 0) round2(GAUSSIAN_SEQUENCE[rng.next(11)], shift) else 0;
    }
    if (g.num_y_points > 0) {
        for (3..LUMA_H) |y| {
            for (3..LUMA_W - 3) |x| {
                var sum: i32 = 0;
                var pos: usize = 0;
                var dy: i32 = -lag;
                outer: while (dy <= 0) : (dy += 1) {
                    var dx: i32 = -lag;
                    while (dx <= lag) : (dx += 1) {
                        if (dy == 0 and dx == 0) break :outer;
                        sum += @as(i32, g.ar_coeffs_y[pos]) * t.luma[@intCast(@as(i32, @intCast(y)) + dy)][@intCast(@as(i32, @intCast(x)) + dx)];
                        pos += 1;
                    }
                }
                t.luma[y][x] = std.math.clamp(t.luma[y][x] + round2(sum, ar_shift), gmin, gmax);
            }
        }
    }

    // chroma: Cb, then Cr
    const planes = [2]Chroma{
        .{ .seed = g.grain_seed ^ 0xb524, .n = g.num_cb_points, .coeffs = &g.ar_coeffs_cb, .out = &t.cb },
        .{ .seed = g.grain_seed ^ 0x49d8, .n = g.num_cr_points, .coeffs = &g.ar_coeffs_cr, .out = &t.cr },
    };
    for (planes) |p| {
        const on = p.n > 0 or f.chroma_scaling_from_luma != 0;
        rng = .{ .state = p.seed };
        for (p.out) |*row| {
            for (row) |*v| v.* = if (on) round2(GAUSSIAN_SEQUENCE[rng.next(11)], shift) else 0;
        }
        if (!on) continue;
        for (3..CHROMA_H) |y| {
            for (3..CHROMA_W - 3) |x| {
                var sum: i32 = 0;
                var pos: usize = 0;
                var dy: i32 = -lag;
                outer: while (dy <= 0) : (dy += 1) {
                    var dx: i32 = -lag;
                    while (dx <= lag) : (dx += 1) {
                        if (dy == 0 and dx == 0) {
                            // (the luma grain's 2 x 2 average beside it)
                            if (g.num_y_points > 0) {
                                const ly = ((y - 3) << 1) + 3;
                                const lx = ((x - 3) << 1) + 3;
                                const luma = round2(t.luma[ly][lx] + t.luma[ly][lx + 1] + t.luma[ly + 1][lx] + t.luma[ly + 1][lx + 1], 2);
                                sum += luma * @as(i32, p.coeffs[pos]);
                            }
                            break :outer;
                        }
                        sum += @as(i32, p.coeffs[pos]) * p.out[@intCast(@as(i32, @intCast(y)) + dy)][@intCast(@as(i32, @intCast(x)) + dx)];
                        pos += 1;
                    }
                }
                p.out[y][x] = std.math.clamp(p.out[y][x] + round2(sum, ar_shift), gmin, gmax);
            }
        }
    }
}

/// scaling_lookup_init at 8-bit indices: `n` points (value, scaling).
pub fn scalingLut(values: []const u8, scalings: []const u8, n: u8, out: *[256]u8) void {
    if (n == 0) {
        @memset(out, 0);
        return;
    }
    @memset(out[0..values[0]], scalings[0]);
    for (0..n - 1) |i| {
        const bx: i32 = values[i];
        const by: i32 = scalings[i];
        const dx: i32 = @as(i32, values[i + 1]) - bx;
        const dy: i32 = @as(i32, scalings[i + 1]) - by;
        if (dx <= 0) continue;
        const delta = dy * @divTrunc(0x10000 + (dx >> 1), dx);
        var d: i32 = 0x8000;
        var x: i32 = 0;
        while (x < dx) : (x += 1) {
            out[@intCast(bx + x)] = @intCast(by + (d >> 16));
            d += delta;
        }
    }
    const last = values[n - 1];
    @memset(out[last..], scalings[n - 1]);
}

/// The film grain buffer for a frame's grain parameters (`t`: the
/// caller's room for the templates).
pub fn memory(g: *const vaav1.FilmGrain, bit_depth: u32, t: *Templates, out: *Memory) void {
    generate(g, bit_depth, t);
    const f = g.film_grain_info_fields;
    scalingLut(&g.point_y_value, &g.point_y_scaling, g.num_y_points, &out.scaling_lut_y);
    if (f.chroma_scaling_from_luma != 0) {
        out.scaling_lut_cb = out.scaling_lut_y;
        out.scaling_lut_cr = out.scaling_lut_y;
    } else {
        scalingLut(&g.point_cb_value, &g.point_cb_scaling, g.num_cb_points, &out.scaling_lut_cb);
        scalingLut(&g.point_cr_value, &g.point_cr_scaling, g.num_cr_points, &out.scaling_lut_cr);
    }
    for (0..LUMA_CROP) |y| {
        for (0..LUMA_CROP) |x| out.cropped_luma_grain_block[y * LUMA_CROP + x] = @intCast(t.luma[LUMA_CROP_AT + y][LUMA_CROP_AT + x]);
    }
    for (0..CHROMA_CROP) |y| {
        for (0..CHROMA_CROP) |x| {
            out.cropped_cb_grain_block[y * CHROMA_CROP + x] = @intCast(t.cb[CHROMA_CROP_AT + y][CHROMA_CROP_AT + x]);
            out.cropped_cr_grain_block[y * CHROMA_CROP + x] = @intCast(t.cr[CHROMA_CROP_AT + y][CHROMA_CROP_AT + x]);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
var test_t: Templates = undefined;
var test_m: Memory = undefined;

test "av1_grain: the LFSR, the Gaussian table's ends, round2" {
    // (seed 1: the bit shifted in is 1 ^ 0 ^ 0 ^ 0)
    var r = Random{ .state = 1 };
    _ = r.next(11);
    try testing.expectEqual(@as(u16, 0x8000), r.state);
    try testing.expectEqual(@as(i16, 56), GAUSSIAN_SEQUENCE[0]);
    try testing.expectEqual(@as(i16, -484), GAUSSIAN_SEQUENCE[2047]);
    try testing.expectEqual(@as(i32, 3), round2(5, 1));
    try testing.expectEqual(@as(i32, -2), round2(-5, 1));
}

test "av1_grain: a template without AR is the table, scaled; the LUT interpolates; the buffer's crops" {
    var g = vaav1.FilmGrain{};
    g.grain_seed = 0x1234;
    g.num_y_points = 2;
    g.point_y_value[0] = 16;
    g.point_y_scaling[0] = 32;
    g.point_y_value[1] = 128;
    g.point_y_scaling[1] = 96;
    g.film_grain_info_fields.ar_coeff_lag = 0;
    g.film_grain_info_fields.ar_coeff_shift_minus_6 = 1;
    memory(&g, 8, &test_t, &test_m);
    // lag 0: no filtering, each value the table's at the LFSR's 11 bits,
    // shifted by 12 - 8
    var r = Random{ .state = 0x1234 };
    for (0..LUMA_H) |y| {
        for (0..LUMA_W) |x| try testing.expectEqual(round2(GAUSSIAN_SEQUENCE[r.next(11)], 4), test_t.luma[y][x]);
    }
    // no chroma points: no chroma grain
    try testing.expectEqual(@as(i32, 0), test_t.cb[10][10]);
    // the LUT: 32 up to 16, 96 from 128, between them on the line
    try testing.expectEqual(@as(u8, 32), test_m.scaling_lut_y[0]);
    try testing.expectEqual(@as(u8, 32), test_m.scaling_lut_y[16]);
    try testing.expectEqual(@as(u8, 64), test_m.scaling_lut_y[72]);
    try testing.expectEqual(@as(u8, 96), test_m.scaling_lut_y[255]);
    try testing.expectEqual(@as(u8, 0), test_m.scaling_lut_cb[100]);
    // the crops
    try testing.expectEqual(@as(i16, @intCast(test_t.luma[9][9])), test_m.cropped_luma_grain_block[0]);
    try testing.expectEqual(@as(i16, @intCast(test_t.luma[72][72])), test_m.cropped_luma_grain_block[4095]);
    // chroma from luma: the luma's LUT, chroma grain made, with the AR's
    // luma term
    g.film_grain_info_fields.chroma_scaling_from_luma = 1;
    g.film_grain_info_fields.ar_coeff_lag = 1;
    g.ar_coeffs_cb[4] = 64; // (lag 1: four neighbours, then the luma's)
    memory(&g, 10, &test_t, &test_m);
    try testing.expectEqual(test_m.scaling_lut_y, test_m.scaling_lut_cb);
    try testing.expect(test_t.cb[20][20] != 0);
    try testing.expectEqual(@as(i16, @intCast(test_t.cb[6][6])), test_m.cropped_cb_grain_block[0]);
    // (10-bit: within the grain's range)
    for (test_t.luma) |row| {
        for (row) |v| try testing.expect(v >= -512 and v <= 511);
    }
}

pub const GAUSSIAN_SEQUENCE = [2048]i16{
    56, 568, -180, 172, 124, -84, 172, -64, -900, 24, 820, 224, 1248, 996, 272, -8,
    -916, -388, -732, -104, -188, 800, 112, -652, -320, -376, 140, -252, 492, -168, 44, -788,
    588, -584, 500, -228, 12, 680, 272, -476, 972, -100, 652, 368, 432, -196, -720, -192,
    1000, -332, 652, -136, -552, -604, -4, 192, -220, -136, 1000, -52, 372, -96, -624, 124,
    -24, 396, 540, -12, -104, 640, 464, 244, -208, -84, 368, -528, -740, 248, -968, -848,
    608, 376, -60, -292, -40, -156, 252, -292, 248, 224, -280, 400, -244, 244, -60, 76,
    -80, 212, 532, 340, 128, -36, 824, -352, -60, -264, -96, -612, 416, -704, 220, -204,
    640, -160, 1220, -408, 900, 336, 20, -336, -96, -792, 304, 48, -28, -1232, -1172, -448,
    104, -292, -520, 244, 60, -948, 0, -708, 268, 108, 356, -548, 488, -344, -136, 488,
    -196, -224, 656, -236, -1128, 60, 4, 140, 276, -676, -376, 168, -108, 464, 8, 564,
    64, 240, 308, -300, -400, -456, -136, 56, 120, -408, -116, 436, 504, -232, 328, 844,
    -164, -84, 784, -168, 232, -224, 348, -376, 128, 568, 96, -1244, -288, 276, 848, 832,
    -360, 656, 464, -384, -332, -356, 728, -388, 160, -192, 468, 296, 224, 140, -776, -100,
    280, 4, 196, 44, -36, -648, 932, 16, 1428, 28, 528, 808, 772, 20, 268, 88,
    -332, -284, 124, -384, -448, 208, -228, -1044, -328, 660, 380, -148, -300, 588, 240, 540,
    28, 136, -88, -436, 256, 296, -1000, 1400, 0, -48, 1056, -136, 264, -528, -1108, 632,
    -484, -592, -344, 796, 124, -668, -768, 388, 1296, -232, -188, -200, -288, -4, 308, 100,
    -168, 256, -500, 204, -508, 648, -136, 372, -272, -120, -1004, -552, -548, -384, 548, -296,
    428, -108, -8, -912, -324, -224, -88, -112, -220, -100, 996, -796, 548, 360, -216, 180,
    428, -200, -212, 148, 96, 148, 284, 216, -412, -320, 120, -300, -384, -604, -572, -332,
    -8, -180, -176, 696, 116, -88, 628, 76, 44, -516, 240, -208, -40, 100, -592, 344,
    -308, -452, -228, 20, 916, -1752, -136, -340, -804, 140, 40, 512, 340, 248, 184, -492,
    896, -156, 932, -628, 328, -688, -448, -616, -752, -100, 560, -1020, 180, -800, -64, 76,
    576, 1068, 396, 660, 552, -108, -28, 320, -628, 312, -92, -92, -472, 268, 16, 560,
    516, -672, -52, 492, -100, 260, 384, 284, 292, 304, -148, 88, -152, 1012, 1064, -228,
    164, -376, -684, 592, -392, 156, 196, -524, -64, -884, 160, -176, 636, 648, 404, -396,
    -436, 864, 424, -728, 988, -604, 904, -592, 296, -224, 536, -176, -920, 436, -48, 1176,
    -884, 416, -776, -824, -884, 524, -548, -564, -68, -164, -96, 692, 364, -692, -1012, -68,
    260, -480, 876, -1116, 452, -332, -352, 892, -1088, 1220, -676, 12, -292, 244, 496, 372,
    -32, 280, 200, 112, -440, -96, 24, -644, -184, 56, -432, 224, -980, 272, -260, 144,
    -436, 420, 356, 364, -528, 76, 172, -744, -368, 404, -752, -416, 684, -688, 72, 540,
    416, 92, 444, 480, -72, -1416, 164, -1172, -68, 24, 424, 264, 1040, 128, -912, -524,
    -356, 64, 876, -12, 4, -88, 532, 272, -524, 320, 276, -508, 940, 24, -400, -120,
    756, 60, 236, -412, 100, 376, -484, 400, -100, -740, -108, -260, 328, -268, 224, -200,
    -416, 184, -604, -564, -20, 296, 60, 892, -888, 60, 164, 68, -760, 216, -296, 904,
    -336, -28, 404, -356, -568, -208, -1480, -512, 296, 328, -360, -164, -1560, -776, 1156, -428,
    164, -504, -112, 120, -216, -148, -264, 308, 32, 64, -72, 72, 116, 176, -64, -272,
    460, -536, -784, -280, 348, 108, -752, -132, 524, -540, -776, 116, -296, -1196, -288, -560,
    1040, -472, 116, -848, -1116, 116, 636, 696, 284, -176, 1016, 204, -864, -648, -248, 356,
    972, -584, -204, 264, 880, 528, -24, -184, 116, 448, -144, 828, 524, 212, -212, 52,
    12, 200, 268, -488, -404, -880, 824, -672, -40, 908, -248, 500, 716, -576, 492, -576,
    16, 720, -108, 384, 124, 344, 280, 576, -500, 252, 104, -308, 196, -188, -8, 1268,
    296, 1032, -1196, 436, 316, 372, -432, -200, -660, 704, -224, 596, -132, 268, 32, -452,
    884, 104, -1008, 424, -1348, -280, 4, -1168, 368, 476, 696, 300, -8, 24, 180, -592,
    -196, 388, 304, 500, 724, -160, 244, -84, 272, -256, -420, 320, 208, -144, -156, 156,
    364, 452, 28, 540, 316, 220, -644, -248, 464, 72, 360, 32, -388, 496, -680, -48,
    208, -116, -408, 60, -604, -392, 548, -840, 784, -460, 656, -544, -388, -264, 908, -800,
    -628, -612, -568, 572, -220, 164, 288, -16, -308, 308, -112, -636, -760, 280, -668, 432,
    364, 240, -196, 604, 340, 384, 196, 592, -44, -500, 432, -580, -132, 636, -76, 392,
    4, -412, 540, 508, 328, -356, -36, 16, -220, -64, -248, -60, 24, -192, 368, 1040,
    92, -24, -1044, -32, 40, 104, 148, 192, -136, -520, 56, -816, -224, 732, 392, 356,
    212, -80, -424, -1008, -324, 588, -1496, 576, 460, -816, -848, 56, -580, -92, -1372, -112,
    -496, 200, 364, 52, -140, 48, -48, -60, 84, 72, 40, 132, -356, -268, -104, -284,
    -404, 732, -520, 164, -304, -540, 120, 328, -76, -460, 756, 388, 588, 236, -436, -72,
    -176, -404, -316, -148, 716, -604, 404, -72, -88, -888, -68, 944, 88, -220, -344, 960,
    472, 460, -232, 704, 120, 832, -228, 692, -508, 132, -476, 844, -748, -364, -44, 1116,
    -1104, -1056, 76, 428, 552, -692, 60, 356, 96, -384, -188, -612, -576, 736, 508, 892,
    352, -1132, 504, -24, -352, 324, 332, -600, -312, 292, 508, -144, -8, 484, 48, 284,
    -260, -240, 256, -100, -292, -204, -44, 472, -204, 908, -188, -1000, -256, 92, 1164, -392,
    564, 356, 652, -28, -884, 256, 484, -192, 760, -176, 376, -524, -452, -436, 860, -736,
    212, 124, 504, -476, 468, 76, -472, 552, -692, -944, -620, 740, -240, 400, 132, 20,
    192, -196, 264, -668, -1012, -60, 296, -316, -828, 76, -156, 284, -768, -448, -832, 148,
    248, 652, 616, 1236, 288, -328, -400, -124, 588, 220, 520, -696, 1032, 768, -740, -92,
    -272, 296, 448, -464, 412, -200, 392, 440, -200, 264, -152, -260, 320, 1032, 216, 320,
    -8, -64, 156, -1016, 1084, 1172, 536, 484, -432, 132, 372, -52, -256, 84, 116, -352,
    48, 116, 304, -384, 412, 924, -300, 528, 628, 180, 648, 44, -980, -220, 1320, 48,
    332, 748, 524, -268, -720, 540, -276, 564, -344, -208, -196, 436, 896, 88, -392, 132,
    80, -964, -288, 568, 56, -48, -456, 888, 8, 552, -156, -292, 948, 288, 128, -716,
    -292, 1192, -152, 876, 352, -600, -260, -812, -468, -28, -120, -32, -44, 1284, 496, 192,
    464, 312, -76, -516, -380, -456, -1012, -48, 308, -156, 36, 492, -156, -808, 188, 1652,
    68, -120, -116, 316, 160, -140, 352, 808, -416, 592, 316, -480, 56, 528, -204, -568,
    372, -232, 752, -344, 744, -4, 324, -416, -600, 768, 268, -248, -88, -132, -420, -432,
    80, -288, 404, -316, -1216, -588, 520, -108, 92, -320, 368, -480, -216, -92, 1688, -300,
    180, 1020, -176, 820, -68, -228, -260, 436, -904, 20, 40, -508, 440, -736, 312, 332,
    204, 760, -372, 728, 96, -20, -632, -520, -560, 336, 1076, -64, -532, 776, 584, 192,
    396, -728, -520, 276, -188, 80, -52, -612, -252, -48, 648, 212, -688, 228, -52, -260,
    428, -412, -272, -404, 180, 816, -796, 48, 152, 484, -88, -216, 988, 696, 188, -528,
    648, -116, -180, 316, 476, 12, -564, 96, 476, -252, -364, -376, -392, 556, -256, -576,
    260, -352, 120, -16, -136, -260, -492, 72, 556, 660, 580, 616, 772, 436, 424, -32,
    -324, -1268, 416, -324, -80, 920, 160, 228, 724, 32, -516, 64, 384, 68, -128, 136,
    240, 248, -204, -68, 252, -932, -120, -480, -628, -84, 192, 852, -404, -288, -132, 204,
    100, 168, -68, -196, -868, 460, 1080, 380, -80, 244, 0, 484, -888, 64, 184, 352,
    600, 460, 164, 604, -196, 320, -64, 588, -184, 228, 12, 372, 48, -848, -344, 224,
    208, -200, 484, 128, -20, 272, -468, -840, 384, 256, -720, -520, -464, -580, 112, -120,
    644, -356, -208, -608, -528, 704, 560, -424, 392, 828, 40, 84, 200, -152, 0, -144,
    584, 280, -120, 80, -556, -972, -196, -472, 724, 80, 168, -32, 88, 160, -688, 0,
    160, 356, 372, -776, 740, -128, 676, -248, -480, 4, -364, 96, 544, 232, -1032, 956,
    236, 356, 20, -40, 300, 24, -676, -596, 132, 1120, -104, 532, -1096, 568, 648, 444,
    508, 380, 188, -376, -604, 1488, 424, 24, 756, -220, -192, 716, 120, 920, 688, 168,
    44, -460, 568, 284, 1144, 1160, 600, 424, 888, 656, -356, -320, 220, 316, -176, -724,
    -188, -816, -628, -348, -228, -380, 1012, -452, -660, 736, 928, 404, -696, -72, -268, -892,
    128, 184, -344, -780, 360, 336, 400, 344, 428, 548, -112, 136, -228, -216, -820, -516,
    340, 92, -136, 116, -300, 376, -244, 100, -316, -520, -284, -12, 824, 164, -548, -180,
    -128, 116, -924, -828, 268, -368, -580, 620, 192, 160, 0, -1676, 1068, 424, -56, -360,
    468, -156, 720, 288, -528, 556, -364, 548, -148, 504, 316, 152, -648, -620, -684, -24,
    -376, -384, -108, -920, -1032, 768, 180, -264, -508, -1268, -260, -60, 300, -240, 988, 724,
    -376, -576, -212, -736, 556, 192, 1092, -620, -880, 376, -56, -4, -216, -32, 836, 268,
    396, 1332, 864, -600, 100, 56, -412, -92, 356, 180, 884, -468, -436, 292, -388, -804,
    -704, -840, 368, -348, 140, -724, 1536, 940, 372, 112, -372, 436, -480, 1136, 296, -32,
    -228, 132, -48, -220, 868, -1016, -60, -1044, -464, 328, 916, 244, 12, -736, -296, 360,
    468, -376, -108, -92, 788, 368, -56, 544, 400, -672, -420, 728, 16, 320, 44, -284,
    -380, -796, 488, 132, 204, -596, -372, 88, -152, -908, -636, -572, -624, -116, -692, -200,
    -56, 276, -88, 484, -324, 948, 864, 1000, -456, -184, -276, 292, -296, 156, 676, 320,
    160, 908, -84, -1236, -288, -116, 260, -372, -644, 732, -756, -96, 84, 344, -520, 348,
    -688, 240, -84, 216, -1044, -136, -676, -396, -1500, 960, -40, 176, 168, 1516, 420, -504,
    -344, -364, -360, 1216, -940, -380, -212, 252, -660, -708, 484, -444, -152, 928, -120, 1112,
    476, -260, 560, -148, -344, 108, -196, 228, -288, 504, 560, -328, -88, 288, -1008, 460,
    -228, 468, -836, -196, 76, 388, 232, 412, -1168, -716, -644, 756, -172, -356, -504, 116,
    432, 528, 48, 476, -168, -608, 448, 160, -532, -272, 28, -676, -12, 828, 980, 456,
    520, 104, -104, 256, -344, -4, -28, -368, -52, -524, -572, -556, -200, 768, 1124, -208,
    -512, 176, 232, 248, -148, -888, 604, -600, -304, 804, -156, -212, 488, -192, -804, -256,
    368, -360, -916, -328, 228, -240, -448, -472, 856, -556, -364, 572, -12, -156, -368, -340,
    432, 252, -752, -152, 288, 268, -580, -848, -592, 108, -76, 244, 312, -716, 592, -80,
    436, 360, 4, -248, 160, 516, 584, 732, 44, -468, -280, -292, -156, -588, 28, 308,
    912, 24, 124, 156, 180, -252, 944, -924, -772, -520, -428, -624, 300, -212, -1144, 32,
    -724, 800, -1128, -212, -1288, -848, 180, -416, 440, 192, -576, -792, -76, -1080, 80, -532,
    -352, -132, 380, -820, 148, 1112, 128, 164, 456, 700, -924, 144, -668, -384, 648, -832,
    508, 552, -52, -100, -656, 208, -568, 748, -88, 680, 232, 300, 192, -408, -1012, -152,
    -252, -268, 272, -876, -664, -648, -332, -136, 16, 12, 1152, -28, 332, -536, 320, -672,
    -460, -316, 532, -260, 228, -40, 1052, -816, 180, 88, -496, -556, -672, -368, 428, 92,
    356, 404, -408, 252, 196, -176, -556, 792, 268, 32, 372, 40, 96, -332, 328, 120,
    372, -900, -40, 472, -264, -592, 952, 128, 656, 112, 664, -232, 420, 4, -344, -464,
    556, 244, -416, -32, 252, 0, -412, 188, -696, 508, -476, 324, -1096, 656, -312, 560,
    264, -136, 304, 160, -64, -580, 248, 336, -720, 560, -348, -288, -276, -196, -500, 852,
    -544, -236, -1128, -992, -776, 116, 56, 52, 860, 884, 212, -12, 168, 1020, 512, -552,
    924, -148, 716, 188, 164, -340, -520, -184, 880, -152, -680, -208, -1156, -300, -528, -472,
    364, 100, -744, -1056, -32, 540, 280, 144, -676, -32, -232, -280, -224, 96, 568, -76,
    172, 148, 148, 104, 32, -296, -32, 788, -80, 32, -16, 280, 288, 944, 428, -484,
};
