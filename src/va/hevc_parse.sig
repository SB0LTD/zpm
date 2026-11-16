//! @zpm/va hevc_parse — an HEVC elementary stream (Annex B, or 4-byte
//! lengths) read as a VA-API client reads it, for video.Decoder: SPS
//! (profile, sizes, the short-term RPS sets, long-term candidates, the
//! scaling lists), PPS (tiles as CTB widths), each slice segment header up
//! to its reference picture set, the picture order count (8.3.1), the RPS
//! and the DPB's marking (8.3.2), CRA/BLA/IDR random access (RASL pictures
//! skipped after a stream's first CRA), output in display order (C.5.2:
//! sps_max_num_reorder_pics, sps_max_dec_pic_buffering), and VA's picture
//! parameters, IQ matrix (raster order, as FFmpeg's vaapi_hevc gives it) and
//! one slice parameter buffer per slice segment. The decoder (hevc.sig on
//! NVDEC) reads each slice header past the RPS itself and builds its lists
//! from ReferenceFrames' RPS flags.
//!
//! What is left for later: Main 4:2:2/4:4:4 and the range extensions,
//! multi-layer streams (nuh_layer_id > 0 skipped), field/frame SEI.
//!
//! Pure and allocation-free: fixed tables (16 SPS, 64 PPS, a 16-picture
//! DPB), the caller's slices.

const std = @import("std");
const va = @import("vaapi.sig");
const Reader = @import("enc_parse.sig").Reader;
const h264 = @import("h264_parse.sig");

pub const MAX_SPS = 16;
pub const MAX_PPS = 64;
pub const MAX_DPB = 16;
pub const MAX_SLICES = 128;
pub const MAX_ST_RPS = 65;

pub const Error = error{ Truncated, Bad, Unsupported, NoParameterSet };

pub const NalIter = h264.NalIter;

pub const RASL_N: u8 = 8;
pub const RASL_R: u8 = 9;
pub const BLA_W_LP: u8 = 16;
pub const IDR_W_RADL: u8 = 19;
pub const IDR_N_LP: u8 = 20;
pub const CRA: u8 = 21;
pub const VPS: u8 = 32;
pub const SPS_NUT: u8 = 33;
pub const PPS_NUT: u8 = 34;
pub const EOS: u8 = 36;
pub const EOB: u8 = 37;

fn ceilLog2(n: u32) u6 {
    if (n <= 1) return 0;
    return @intCast(32 - @clz(n - 1));
}

// ── Scaling lists ───────────────────────────────────────────────────────────

/// The diagonal up-right scans (6.5.3): position k of a list -> raster.
fn diagScan(comptime n: usize) [n * n]u8 {
    var out: [n * n]u8 = undefined;
    var i: usize = 0;
    var x: isize = 0;
    var y: isize = 0;
    var stop = false;
    while (!stop) {
        while (y >= 0) {
            if (x < n and y < n) {
                out[i] = @intCast(@as(usize, @intCast(y)) * n + @as(usize, @intCast(x)));
                i += 1;
            }
            y -= 1;
            x += 1;
        }
        y = x;
        x = 0;
        if (i >= n * n) stop = true;
    }
    return out;
}
const DIAG4 = diagScan(4);
const DIAG8 = diagScan(8);

/// Table 7-6's defaults for 8x8 (and up), in the scan's order.
const DEFAULT_INTRA = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18, 17, 18, 18, 17, 18, 21, 19, 20,
    21, 20, 19, 21, 24, 22, 22, 24, 24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31,
    29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115,
};
const DEFAULT_INTER = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18, 18, 18, 18, 18, 18, 20, 20, 20,
    20, 20, 20, 20, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28,
    28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91,
};

/// The lists as VA carries them: raster order.
pub const Scaling = struct {
    l4: [6][16]u8 = [_][16]u8{[_]u8{16} ** 16} ** 6,
    l8: [6][64]u8 = undefined,
    l16: [6][64]u8 = undefined,
    l32: [6][64]u8 = undefined,
    dc16: [6]u8 = [_]u8{16} ** 6,
    dc32: [6]u8 = [_]u8{16} ** 6,

    pub fn defaults() Scaling {
        var s = Scaling{};
        for (0..6) |m| {
            const d = if (m < 3) &DEFAULT_INTRA else &DEFAULT_INTER;
            for (0..64) |k| {
                s.l8[m][DIAG8[k]] = d[k];
                s.l16[m][DIAG8[k]] = d[k];
                s.l32[m][DIAG8[k]] = d[k];
            }
        }
        return s;
    }
};

/// scaling_list_data() (7.3.4).
fn readScaling(r: *Reader, out: *Scaling) void {
    var s = Scaling.defaults();
    for (0..4) |size_id| {
        var m: usize = 0;
        while (m < 6) : (m += if (size_id == 3) 3 else 1) {
            const pred_mode = r.flag();
            if (!pred_mode) {
                const delta = r.ue() * (if (size_id == 3) @as(u32, 3) else 1);
                if (delta > m) return;
                if (delta != 0) {
                    const ref = m - delta;
                    switch (size_id) {
                        0 => s.l4[m] = s.l4[ref],
                        1 => s.l8[m] = s.l8[ref],
                        2 => {
                            s.l16[m] = s.l16[ref];
                            s.dc16[m] = s.dc16[ref];
                        },
                        else => {
                            s.l32[m] = s.l32[ref];
                            s.dc32[m] = s.dc32[ref];
                        },
                    }
                } else {
                    // the default list
                    const d = if (m < 3) &DEFAULT_INTRA else &DEFAULT_INTER;
                    switch (size_id) {
                        0 => s.l4[m] = [_]u8{16} ** 16,
                        1 => for (0..64) |k| {
                            s.l8[m][DIAG8[k]] = d[k];
                        },
                        2 => {
                            for (0..64) |k| s.l16[m][DIAG8[k]] = d[k];
                            s.dc16[m] = 16;
                        },
                        else => {
                            for (0..64) |k| s.l32[m][DIAG8[k]] = d[k];
                            s.dc32[m] = 16;
                        },
                    }
                }
            } else {
                var next: i32 = 8;
                const coefs: usize = @min(64, @as(usize, 1) << @intCast(4 + (size_id << 1)));
                if (size_id > 1) {
                    next = r.se() + 8;
                    if (size_id == 2) s.dc16[m] = @intCast(std.math.clamp(next, 1, 255)) else s.dc32[m] = @intCast(std.math.clamp(next, 1, 255));
                }
                for (0..coefs) |k| {
                    next = @mod(next + r.se() + 256, 256);
                    const v: u8 = @intCast(next);
                    switch (size_id) {
                        0 => s.l4[m][DIAG4[k]] = v,
                        1 => s.l8[m][DIAG8[k]] = v,
                        2 => s.l16[m][DIAG8[k]] = v,
                        else => s.l32[m][DIAG8[k]] = v,
                    }
                }
            }
        }
    }
    // (4:2:0: the 32x32 chroma lists are their 16x16 ones; VA keeps two)
    out.* = s;
}

// ── Reference picture sets ──────────────────────────────────────────────────

pub const StRps = struct {
    num_negative: u8 = 0,
    num_positive: u8 = 0,
    delta_s0: [16]i32 = [_]i32{0} ** 16,
    used_s0: [16]bool = [_]bool{false} ** 16,
    delta_s1: [16]i32 = [_]i32{0} ** 16,
    used_s1: [16]bool = [_]bool{false} ** 16,

    fn count(r: *const StRps) u32 {
        return @as(u32, r.num_negative) + r.num_positive;
    }
};

/// st_ref_pic_set(idx) (7.3.7, 7.4.8): `sets` the SPS's (those before idx).
fn readStRps(r: *Reader, idx: usize, num_sets: usize, sets: []const StRps, out: *StRps) Error!void {
    var inter = false;
    if (idx != 0) inter = r.flag();
    var rps = StRps{};
    if (inter) {
        var delta_idx: usize = 1;
        if (idx == num_sets) delta_idx = r.ue() + 1;
        if (delta_idx > idx) return error.Bad;
        const ref = &sets[idx - delta_idx];
        const sign = r.flag();
        const abs = r.ue() + 1;
        const delta_rps: i32 = if (sign) -@as(i32, @intCast(abs)) else @intCast(abs);
        var used: [33]bool = undefined;
        var use_delta: [33]bool = undefined;
        const n = ref.count();
        for (0..n + 1) |j| {
            used[j] = r.flag();
            use_delta[j] = if (!used[j]) r.flag() else true;
        }
        // (7-61, 7-62)
        var i: usize = 0;
        var j: isize = @as(isize, ref.num_positive) - 1;
        while (j >= 0) : (j -= 1) {
            const ju: usize = @intCast(j);
            const dpoc = ref.delta_s1[ju] + delta_rps;
            if (dpoc < 0 and use_delta[ref.num_negative + ju]) {
                if (i >= 16) return error.Bad;
                rps.delta_s0[i] = dpoc;
                rps.used_s0[i] = used[ref.num_negative + ju];
                i += 1;
            }
        }
        if (delta_rps < 0 and use_delta[n]) {
            if (i >= 16) return error.Bad;
            rps.delta_s0[i] = delta_rps;
            rps.used_s0[i] = used[n];
            i += 1;
        }
        for (0..ref.num_negative) |jj| {
            const dpoc = ref.delta_s0[jj] + delta_rps;
            if (dpoc < 0 and use_delta[jj]) {
                if (i >= 16) return error.Bad;
                rps.delta_s0[i] = dpoc;
                rps.used_s0[i] = used[jj];
                i += 1;
            }
        }
        rps.num_negative = @intCast(i);
        i = 0;
        j = @as(isize, ref.num_negative) - 1;
        while (j >= 0) : (j -= 1) {
            const ju: usize = @intCast(j);
            const dpoc = ref.delta_s0[ju] + delta_rps;
            if (dpoc > 0 and use_delta[ju]) {
                if (i >= 16) return error.Bad;
                rps.delta_s1[i] = dpoc;
                rps.used_s1[i] = used[ju];
                i += 1;
            }
        }
        if (delta_rps > 0 and use_delta[n]) {
            if (i >= 16) return error.Bad;
            rps.delta_s1[i] = delta_rps;
            rps.used_s1[i] = used[n];
            i += 1;
        }
        for (0..ref.num_positive) |jj| {
            const dpoc = ref.delta_s1[jj] + delta_rps;
            if (dpoc > 0 and use_delta[ref.num_negative + jj]) {
                if (i >= 16) return error.Bad;
                rps.delta_s1[i] = dpoc;
                rps.used_s1[i] = used[ref.num_negative + jj];
                i += 1;
            }
        }
        rps.num_positive = @intCast(i);
    } else {
        const neg = r.ue();
        const pos = r.ue();
        if (neg > 16 or pos > 16 or neg + pos > 16) return error.Bad;
        rps.num_negative = @intCast(neg);
        rps.num_positive = @intCast(pos);
        var prev: i32 = 0;
        for (0..neg) |i| {
            prev -= @intCast(r.ue() + 1);
            rps.delta_s0[i] = prev;
            rps.used_s0[i] = r.flag();
        }
        prev = 0;
        for (0..pos) |i| {
            prev += @intCast(r.ue() + 1);
            rps.delta_s1[i] = prev;
            rps.used_s1[i] = r.flag();
        }
    }
    if (r.bad) return error.Truncated;
    out.* = rps;
}

// ── Parameter sets ──────────────────────────────────────────────────────────

pub const Sps = struct {
    valid: bool = false,
    id: u8 = 0,
    profile_idc: u8 = 0,
    max_sub_layers: u8 = 1,
    chroma_format_idc: u2 = 1,
    separate_colour_plane: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    conf: [4]u32 = .{ 0, 0, 0, 0 },
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    log2_max_poc_lsb: u5 = 4,
    max_dec_pic_buffering: u8 = 1,
    max_num_reorder: u8 = 0,
    max_latency_increase_plus1: u32 = 0,
    log2_min_cb: u8 = 3,
    log2_diff_cb: u8 = 0,
    log2_min_tb: u8 = 2,
    log2_diff_tb: u8 = 0,
    max_th_depth_inter: u8 = 0,
    max_th_depth_intra: u8 = 0,
    scaling_enabled: bool = false,
    scaling_present: bool = false,
    scaling: Scaling = .{},
    amp: bool = false,
    sao: bool = false,
    pcm: bool = false,
    pcm_bits_luma: u8 = 0,
    pcm_bits_chroma: u8 = 0,
    log2_min_pcm_cb: u8 = 0,
    log2_diff_pcm_cb: u8 = 0,
    pcm_loop_filter_disabled: bool = false,
    num_st_rps: u8 = 0,
    st_rps: [MAX_ST_RPS]StRps = undefined,
    long_term_present: bool = false,
    num_lt_sps: u8 = 0,
    lt_poc_lsb: [32]u32 = [_]u32{0} ** 32,
    lt_used: [32]bool = [_]bool{false} ** 32,
    temporal_mvp: bool = false,
    strong_intra_smoothing: bool = false,

    pub fn ctbSize(s: *const Sps) u32 {
        return @as(u32, 1) << @intCast(s.log2_min_cb + s.log2_diff_cb);
    }
    pub fn widthCtbs(s: *const Sps) u32 {
        return (s.width + s.ctbSize() - 1) / s.ctbSize();
    }
    pub fn heightCtbs(s: *const Sps) u32 {
        return (s.height + s.ctbSize() - 1) / s.ctbSize();
    }
    /// The visible rectangle (the conformance window), in samples.
    pub fn visible(s: *const Sps) [4]u32 {
        const sx: u32 = if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 2 else 1;
        const sy: u32 = if (s.chroma_format_idc == 1) 2 else 1;
        const l = s.conf[0] * sx;
        const r = s.conf[1] * sx;
        const t = s.conf[2] * sy;
        const b = s.conf[3] * sy;
        if (l + r >= s.width or t + b >= s.height) return .{ 0, 0, s.width, s.height };
        return .{ l, t, s.width - l - r, s.height - t - b };
    }
};

fn skipProfileTierLevel(r: *Reader, max_sub_layers_minus1: u32, profile_idc: *u8) void {
    _ = r.u(2); // general_profile_space
    _ = r.u(1); // general_tier_flag
    profile_idc.* = @intCast(r.u(5));
    _ = r.u(32); // compatibility flags
    _ = r.u(4); // progressive, interlaced, non-packed, frame-only
    _ = r.u(32);
    _ = r.u(11); // (43 reserved bits)
    _ = r.u(1);
    _ = r.u(8); // general_level_idc
    var sub_profile: [8]bool = undefined;
    var sub_level: [8]bool = undefined;
    for (0..max_sub_layers_minus1) |i| {
        sub_profile[i] = r.flag();
        sub_level[i] = r.flag();
    }
    if (max_sub_layers_minus1 > 0) {
        var i = max_sub_layers_minus1;
        while (i < 8) : (i += 1) _ = r.u(2);
    }
    for (0..max_sub_layers_minus1) |i| {
        if (sub_profile[i]) {
            _ = r.u(32);
            _ = r.u(32);
            _ = r.u(24);
        }
        if (sub_level[i]) _ = r.u(8);
    }
}

/// seq_parameter_set_rbsp() (7.3.2.2) of NAL unit `nal` (its 2-byte header first).
pub fn parseSps(nal: []const u8, out: *Sps) Error!void {
    if (nal.len < 4) return error.Truncated;
    var r = Reader.init(nal[2..]);
    var s = Sps{};
    _ = r.u(4); // sps_video_parameter_set_id
    const msl = r.u(3);
    s.max_sub_layers = @intCast(msl + 1);
    _ = r.flag();
    skipProfileTierLevel(&r, msl, &s.profile_idc);
    const id = r.ue();
    if (id >= MAX_SPS) return error.Bad;
    s.id = @intCast(id);
    const cf = r.ue();
    if (cf > 3) return error.Bad;
    s.chroma_format_idc = @intCast(cf);
    if (cf == 3) s.separate_colour_plane = r.flag();
    s.width = r.ue();
    s.height = r.ue();
    if (s.width == 0 or s.height == 0 or s.width > 16384 or s.height > 16384) return error.Bad;
    if (r.flag()) {
        for (&s.conf) |*v| v.* = r.ue();
    }
    const bl = r.ue();
    const bc = r.ue();
    if (bl > 8 or bc > 8) return error.Bad;
    s.bit_depth_luma = @intCast(bl + 8);
    s.bit_depth_chroma = @intCast(bc + 8);
    const lp = r.ue();
    if (lp > 12) return error.Bad;
    s.log2_max_poc_lsb = @intCast(lp + 4);
    const ordering_all = r.flag();
    var i: u32 = if (ordering_all) 0 else msl;
    while (i <= msl) : (i += 1) {
        // (the highest sub-layer's values are the ones kept)
        s.max_dec_pic_buffering = @intCast(@min(r.ue() + 1, MAX_DPB));
        s.max_num_reorder = @intCast(@min(r.ue(), MAX_DPB));
        s.max_latency_increase_plus1 = r.ue();
    }
    s.log2_min_cb = @intCast(r.ue() + 3);
    s.log2_diff_cb = @intCast(r.ue());
    s.log2_min_tb = @intCast(r.ue() + 2);
    s.log2_diff_tb = @intCast(r.ue());
    s.max_th_depth_inter = @intCast(r.ue());
    s.max_th_depth_intra = @intCast(r.ue());
    s.scaling_enabled = r.flag();
    s.scaling = Scaling.defaults();
    if (s.scaling_enabled) {
        s.scaling_present = r.flag();
        if (s.scaling_present) readScaling(&r, &s.scaling);
    }
    s.amp = r.flag();
    s.sao = r.flag();
    s.pcm = r.flag();
    if (s.pcm) {
        s.pcm_bits_luma = @intCast(r.u(4) + 1);
        s.pcm_bits_chroma = @intCast(r.u(4) + 1);
        s.log2_min_pcm_cb = @intCast(r.ue() + 3);
        s.log2_diff_pcm_cb = @intCast(r.ue());
        s.pcm_loop_filter_disabled = r.flag();
    }
    const nst = r.ue();
    if (nst > 64) return error.Bad;
    s.num_st_rps = @intCast(nst);
    for (0..nst) |k| try readStRps(&r, k, nst, s.st_rps[0..k], &s.st_rps[k]);
    s.long_term_present = r.flag();
    if (s.long_term_present) {
        const n = r.ue();
        if (n > 32) return error.Bad;
        s.num_lt_sps = @intCast(n);
        for (0..n) |k| {
            s.lt_poc_lsb[k] = r.u(s.log2_max_poc_lsb);
            s.lt_used[k] = r.flag();
        }
    }
    s.temporal_mvp = r.flag();
    s.strong_intra_smoothing = r.flag();
    // (the VUI and the extensions are not needed)
    if (r.bad) return error.Truncated;
    s.valid = true;
    out.* = s;
}

pub const Pps = struct {
    valid: bool = false,
    id: u8 = 0,
    sps_id: u8 = 0,
    dependent_slices: bool = false,
    output_flag_present: bool = false,
    extra_bits: u8 = 0,
    sign_data_hiding: bool = false,
    cabac_init_present: bool = false,
    num_ref_idx_l0: u8 = 1,
    num_ref_idx_l1: u8 = 1,
    init_qp_minus26: i8 = 0,
    constrained_intra_pred: bool = false,
    transform_skip: bool = false,
    cu_qp_delta: bool = false,
    diff_cu_qp_delta_depth: u8 = 0,
    cb_qp_offset: i8 = 0,
    cr_qp_offset: i8 = 0,
    slice_chroma_qp_offsets_present: bool = false,
    weighted_pred: bool = false,
    weighted_bipred: bool = false,
    transquant_bypass: bool = false,
    tiles: bool = false,
    entropy_sync: bool = false,
    tile_cols: u8 = 1,
    tile_rows: u8 = 1,
    uniform: bool = true,
    col_width: [20]u16 = [_]u16{0} ** 20,
    row_height: [22]u16 = [_]u16{0} ** 22,
    loop_filter_across_tiles: bool = true,
    loop_filter_across_slices: bool = false,
    deblocking_override: bool = false,
    deblocking_disabled: bool = false,
    beta_offset_div2: i8 = 0,
    tc_offset_div2: i8 = 0,
    scaling_present: bool = false,
    scaling: Scaling = .{},
    lists_modification: bool = false,
    log2_parallel_merge_level: u8 = 2,
    slice_header_extension: bool = false,
};

/// pic_parameter_set_rbsp() (7.3.2.3).
pub fn parsePps(nal: []const u8, spss: *const [MAX_SPS]Sps, out: *Pps) Error!void {
    if (nal.len < 3) return error.Truncated;
    var r = Reader.init(nal[2..]);
    var p = Pps{};
    const id = r.ue();
    const sid = r.ue();
    if (id >= MAX_PPS or sid >= MAX_SPS) return error.Bad;
    p.id = @intCast(id);
    p.sps_id = @intCast(sid);
    const sps = &spss[sid];
    if (!sps.valid) return error.NoParameterSet;
    p.dependent_slices = r.flag();
    p.output_flag_present = r.flag();
    p.extra_bits = @intCast(r.u(3));
    p.sign_data_hiding = r.flag();
    p.cabac_init_present = r.flag();
    p.num_ref_idx_l0 = @intCast(@min(r.ue() + 1, 15));
    p.num_ref_idx_l1 = @intCast(@min(r.ue() + 1, 15));
    p.init_qp_minus26 = @intCast(std.math.clamp(r.se(), -64, 25));
    p.constrained_intra_pred = r.flag();
    p.transform_skip = r.flag();
    p.cu_qp_delta = r.flag();
    if (p.cu_qp_delta) p.diff_cu_qp_delta_depth = @intCast(@min(r.ue(), 7));
    p.cb_qp_offset = @intCast(std.math.clamp(r.se(), -12, 12));
    p.cr_qp_offset = @intCast(std.math.clamp(r.se(), -12, 12));
    p.slice_chroma_qp_offsets_present = r.flag();
    p.weighted_pred = r.flag();
    p.weighted_bipred = r.flag();
    p.transquant_bypass = r.flag();
    p.tiles = r.flag();
    p.entropy_sync = r.flag();
    const wc = sps.widthCtbs();
    const hc = sps.heightCtbs();
    if (p.tiles) {
        const cols = r.ue() + 1;
        const rows = r.ue() + 1;
        if (cols > 20 or rows > 22 or cols > wc or rows > hc) return error.Bad;
        p.tile_cols = @intCast(cols);
        p.tile_rows = @intCast(rows);
        p.uniform = r.flag();
        if (!p.uniform) {
            var used: u32 = 0;
            for (0..cols - 1) |k| {
                p.col_width[k] = @intCast(r.ue() + 1);
                used += p.col_width[k];
            }
            if (used >= wc) return error.Bad;
            p.col_width[cols - 1] = @intCast(wc - used);
            used = 0;
            for (0..rows - 1) |k| {
                p.row_height[k] = @intCast(r.ue() + 1);
                used += p.row_height[k];
            }
            if (used >= hc) return error.Bad;
            p.row_height[rows - 1] = @intCast(hc - used);
        } else {
            for (0..cols) |k| p.col_width[k] = @intCast(((k + 1) * wc) / cols - (k * wc) / cols);
            for (0..rows) |k| p.row_height[k] = @intCast(((k + 1) * hc) / rows - (k * hc) / rows);
        }
        p.loop_filter_across_tiles = r.flag();
    } else {
        p.col_width[0] = @intCast(wc);
        p.row_height[0] = @intCast(hc);
    }
    p.loop_filter_across_slices = r.flag();
    if (r.flag()) { // deblocking_filter_control_present_flag
        p.deblocking_override = r.flag();
        p.deblocking_disabled = r.flag();
        if (!p.deblocking_disabled) {
            p.beta_offset_div2 = @intCast(std.math.clamp(r.se(), -6, 6));
            p.tc_offset_div2 = @intCast(std.math.clamp(r.se(), -6, 6));
        }
    }
    p.scaling = sps.scaling;
    p.scaling_present = r.flag();
    if (p.scaling_present) readScaling(&r, &p.scaling);
    p.lists_modification = r.flag();
    p.log2_parallel_merge_level = @intCast(r.ue() + 2);
    p.slice_header_extension = r.flag();
    if (r.bad) return error.Truncated;
    p.valid = true;
    out.* = p;
}

// ── Slice segment headers ───────────────────────────────────────────────────

pub const SliceHeader = struct {
    nal_type: u8,
    temporal_id: u8,
    first: bool,
    no_output_of_prior_pics: bool = false,
    pps_id: u8 = 0,
    dependent: bool = false,
    address: u32 = 0,
    slice_type: u8 = 2,
    pic_output: bool = true,
    poc_lsb: u32 = 0,
    rps: StRps = .{},
    /// bits of the slice's own st_ref_pic_set() (0: the SPS's one by index)
    st_rps_bits: u32 = 0,
    num_lt: u8 = 0,
    /// each long-term entry's POC LSB, whether it is current, whether the
    /// MSB is given and DeltaPocMsbCycleLt (7-52)
    lt_lsb: [32]u32 = [_]u32{0} ** 32,
    lt_used: [32]bool = [_]bool{false} ** 32,
    lt_msb: [32]bool = [_]bool{false} ** 32,
    lt_cycle: [32]u32 = [_]u32{0} ** 32,

    pub fn isIrap(h: *const SliceHeader) bool {
        return h.nal_type >= 16 and h.nal_type <= 23;
    }
    pub fn isIdr(h: *const SliceHeader) bool {
        return h.nal_type == IDR_W_RADL or h.nal_type == IDR_N_LP;
    }
    pub fn isRasl(h: *const SliceHeader) bool {
        return h.nal_type == RASL_N or h.nal_type == RASL_R;
    }
};

/// slice_segment_header() (7.3.6.1) up to the reference picture set.
pub fn parseSlice(nal: []const u8, spss: *const [MAX_SPS]Sps, ppss: *const [MAX_PPS]Pps, out: *SliceHeader) Error!void {
    if (nal.len < 3) return error.Truncated;
    var h = SliceHeader{ .nal_type = (nal[0] >> 1) & 0x3f, .temporal_id = (nal[1] & 7) -| 1, .first = false };
    var r = Reader.init(nal[2..]);
    h.first = r.flag();
    if (h.isIrap()) h.no_output_of_prior_pics = r.flag();
    const pid = r.ue();
    if (pid >= MAX_PPS) return error.Bad;
    h.pps_id = @intCast(pid);
    const pps = &ppss[pid];
    if (!pps.valid) return error.NoParameterSet;
    const sps = &spss[pps.sps_id];
    if (!sps.valid) return error.NoParameterSet;
    if (!h.first) {
        if (pps.dependent_slices) h.dependent = r.flag();
        h.address = r.u(ceilLog2(sps.widthCtbs() * sps.heightCtbs()));
    }
    if (h.dependent) {
        out.* = h;
        return;
    }
    for (0..pps.extra_bits) |_| _ = r.flag();
    const st = r.ue();
    if (st > 2) return error.Bad;
    h.slice_type = @intCast(st);
    if (pps.output_flag_present) h.pic_output = r.flag();
    if (sps.separate_colour_plane) _ = r.u(2);
    if (!h.isIdr()) {
        h.poc_lsb = r.u(sps.log2_max_poc_lsb);
        const from_sps = r.flag();
        if (!from_sps) {
            // (the RBSP's bits: emulation prevention bytes not counted)
            const before = r.pos * 8 + r.bit - 8 * r.epb;
            try readStRps(&r, sps.num_st_rps, sps.num_st_rps, sps.st_rps[0..sps.num_st_rps], &h.rps);
            h.st_rps_bits = @intCast(r.pos * 8 + r.bit - 8 * r.epb - before);
        } else {
            var idx: u32 = 0;
            if (sps.num_st_rps > 1) idx = r.u(ceilLog2(sps.num_st_rps));
            if (idx >= sps.num_st_rps) return error.Bad;
            h.rps = sps.st_rps[idx];
        }
        if (sps.long_term_present) {
            var num_lt_sps: u32 = 0;
            if (sps.num_lt_sps > 0) num_lt_sps = r.ue();
            const num_lt_pics = r.ue();
            if (num_lt_sps + num_lt_pics > 32) return error.Bad;
            h.num_lt = @intCast(num_lt_sps + num_lt_pics);
            for (0..h.num_lt) |k| {
                if (k < num_lt_sps) {
                    var lt_idx: u32 = 0;
                    if (sps.num_lt_sps > 1) lt_idx = r.u(ceilLog2(sps.num_lt_sps));
                    if (lt_idx >= sps.num_lt_sps) return error.Bad;
                    h.lt_lsb[k] = sps.lt_poc_lsb[lt_idx];
                    h.lt_used[k] = sps.lt_used[lt_idx];
                } else {
                    h.lt_lsb[k] = r.u(sps.log2_max_poc_lsb);
                    h.lt_used[k] = r.flag();
                }
                h.lt_msb[k] = r.flag();
                const delta: u32 = if (h.lt_msb[k]) r.ue() else 0;
                h.lt_cycle[k] = if (k == 0 or k == num_lt_sps) delta else delta + h.lt_cycle[k - 1];
            }
        }
    }
    if (r.bad) return error.Truncated;
    out.* = h;
}

// ── The decoded picture buffer ──────────────────────────────────────────────

pub const Pic = struct {
    used: bool = false,
    surface: u32 = 0,
    poc: i32 = 0,
    short_ref: bool = false,
    long_ref: bool = false,
    needed_for_output: bool = false,
    pts: i64 = 0,
    duration: i64 = 0,
    serial: u64 = 0,

    pub fn isRef(p: *const Pic) bool {
        return p.short_ref or p.long_ref;
    }
};

/// What `take` asks of its caller (as h264_parse's, a picture leaving
/// the DPB given by its surface and timestamps).
pub const Callbacks = struct {
    ctx: *anyopaque,
    surface: *const fn (ctx: *anyopaque) ?u32,
    output: *const fn (ctx: *anyopaque, surface: u32, pts: i64, duration: i64) void,
    released: *const fn (ctx: *anyopaque, surface: u32) void,
};

/// One picture's VA buffers.
pub const Picture = struct {
    pic: va.PictureParameterBufferHEVC = std.mem.zeroes(va.PictureParameterBufferHEVC),
    iq: va.IQMatrixBufferHEVC = std.mem.zeroes(va.IQMatrixBufferHEVC),
    slices: [MAX_SLICES]va.SliceParameterBufferHEVC = undefined,
    data: [MAX_SLICES][]const u8 = undefined,
    count: u32 = 0,
    surface: u32 = 0,
    visible: [4]u32 = .{ 0, 0, 0, 0 },
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 8,
    first: SliceHeader = undefined,
};

pub const State = struct {
    sps: [MAX_SPS]Sps = [_]Sps{.{}} ** MAX_SPS,
    pps: [MAX_PPS]Pps = [_]Pps{.{}} ** MAX_PPS,
    dpb: [MAX_DPB + 1]Pic = [_]Pic{.{}} ** (MAX_DPB + 1),
    cur: ?usize = null,
    active_sps: ?u8 = null,
    prev_tid0_poc: i32 = 0,
    /// the next IRAP starts a coded video sequence (stream start, EOS)
    first_irap: bool = true,
    /// RASL pictures are skipped (after a CRA that starts the stream)
    skip_rasl: bool = false,
    serial: u64 = 0,

    pub fn activeSps(st: *const State) ?*const Sps {
        const id = st.active_sps orelse return null;
        return &st.sps[id];
    }
};

/// Feeds one access unit. Returns true when `out` holds a picture to
/// decode; the caller decodes it, then calls `finish`.
pub fn take(st: *State, au: []const u8, pts: i64, duration: i64, cb: Callbacks, out: *Picture) Error!bool {
    var it = NalIter.init(au);
    out.count = 0;
    var have = false;
    while (it.next()) |nal| {
        if (nal.len < 2 or nal[0] & 0x80 != 0) continue;
        if (nal[0] & 1 != 0 or nal[1] >> 3 != 0) continue; // (nuh_layer_id > 0)
        const t = (nal[0] >> 1) & 0x3f;
        switch (t) {
            SPS_NUT => {
                var s: Sps = .{};
                parseSps(nal, &s) catch |e| {
                    if (e == error.Truncated or e == error.Bad) continue;
                    return e;
                };
                st.sps[s.id] = s;
            },
            PPS_NUT => {
                var p: Pps = .{};
                parsePps(nal, &st.sps, &p) catch |e| {
                    if (e == error.Truncated or e == error.Bad or e == error.NoParameterSet) continue;
                    return e;
                };
                st.pps[p.id] = p;
            },
            EOS, EOB => st.first_irap = true,
            0...9, 16...21 => {
                var h: SliceHeader = undefined;
                try parseSlice(nal, &st.sps, &st.pps, &h);
                if (h.first) {
                    if (have) break; // (one picture a call)
                    if (!try beginPicture(st, &h, pts, duration, cb, out)) return false;
                    have = true;
                } else if (!have) continue;
                if (out.count >= MAX_SLICES) return error.Unsupported;
                var s = std.mem.zeroes(va.SliceParameterBufferHEVC);
                s.slice_data_size = @intCast(nal.len);
                s.slice_data_offset = 0;
                s.slice_data_flag = 0;
                s.slice_segment_address = h.address;
                s.slice_qp_delta = 0;
                for (&s.RefPicList) |*l| @memset(l, 0xff);
                out.slices[out.count] = s;
                out.data[out.count] = nal;
                out.count += 1;
            },
            else => {},
        }
    }
    return have and out.count > 0;
}

fn findPoc(st: *State, poc: i32, mask: ?i32) ?usize {
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or (st.cur != null and i == st.cur.?)) continue;
        const v = if (mask) |m| p.poc & m else p.poc;
        if (v == poc and p.isRef()) return i;
    }
    return null;
}

/// The picture of first slice `h`: POC, RPS marking, bumping, VA's
/// parameters. False: the picture is skipped (a RASL picture after the
/// stream's first CRA, or no random access point yet).
fn beginPicture(st: *State, h: *const SliceHeader, pts: i64, duration: i64, cb: Callbacks, out: *Picture) Error!bool {
    const pps = &st.pps[h.pps_id];
    const sps = &st.sps[pps.sps_id];
    if (sps.chroma_format_idc != 1) return error.Unsupported;
    if (sps.bit_depth_luma != sps.bit_depth_chroma or (sps.bit_depth_luma != 8 and sps.bit_depth_luma != 10)) return error.Unsupported;
    if (sps.profile_idc != 1 and sps.profile_idc != 2) {
        // (Main Still Picture and others with Main's tools: taken)
        if (sps.profile_idc != 3) return error.Unsupported;
    }
    st.active_sps = pps.sps_id;
    var no_rasl_output = false;
    if (h.isIrap()) {
        no_rasl_output = h.isIdr() or (h.nal_type >= BLA_W_LP and h.nal_type <= 18) or st.first_irap;
        if (h.nal_type == CRA) st.skip_rasl = no_rasl_output;
        st.first_irap = false;
    } else if (st.first_irap) {
        return false; // (no random access point yet)
    }
    if (h.isRasl() and st.skip_rasl) return false;

    // the POC (8.3.1)
    const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
    var msb: i32 = 0;
    if (!(h.isIrap() and no_rasl_output)) {
        const prev_lsb = @mod(st.prev_tid0_poc, max_lsb);
        const prev_msb = st.prev_tid0_poc - prev_lsb;
        const lsb: i32 = @intCast(h.poc_lsb);
        if (lsb < prev_lsb and prev_lsb - lsb >= @divTrunc(max_lsb, 2)) msb = prev_msb + max_lsb else if (lsb > prev_lsb and lsb - prev_lsb > @divTrunc(max_lsb, 2)) msb = prev_msb - max_lsb else msb = prev_msb;
    }
    const poc = msb + @as(i32, @intCast(h.poc_lsb));
    const sub_layer_non_ref = h.nal_type <= 14 and h.nal_type % 2 == 0;
    if (h.temporal_id == 0 and !(h.nal_type >= 6 and h.nal_type <= 9) and !sub_layer_non_ref) st.prev_tid0_poc = poc;

    // an IRAP starting a sequence: the DPB emptied (output first unless told not to)
    if (h.isIrap() and no_rasl_output) {
        if (!h.no_output_of_prior_pics) {
            while (bump(st, cb)) {}
        }
        for (&st.dpb) |*p| {
            if (!p.used) continue;
            cb.released(cb.ctx, p.surface);
            p.* = .{};
        }
    }

    // the RPS (8.3.2): every picture not in it is no reference any more
    var keep = [_]u8{0} ** (MAX_DPB + 1); // 1 short, 2 long
    var flags: [MAX_DPB + 1]u32 = [_]u32{0} ** (MAX_DPB + 1);
    if (!h.isIdr()) {
        for (0..h.rps.num_negative) |k| {
            if (findPoc(st, poc + h.rps.delta_s0[k], null)) |i| {
                keep[i] = 1;
                if (h.rps.used_s0[k]) flags[i] = va.PICTURE_HEVC_RPS_ST_CURR_BEFORE;
            }
        }
        for (0..h.rps.num_positive) |k| {
            if (findPoc(st, poc + h.rps.delta_s1[k], null)) |i| {
                keep[i] = 1;
                if (h.rps.used_s1[k]) flags[i] = va.PICTURE_HEVC_RPS_ST_CURR_AFTER;
            }
        }
        for (0..h.num_lt) |k| {
            const lsb: i32 = @intCast(h.lt_lsb[k]);
            const i = if (h.lt_msb[k])
                findPoc(st, poc - @as(i32, @intCast(h.lt_cycle[k])) * max_lsb - @mod(poc, max_lsb) + lsb, null)
            else
                findPoc(st, lsb, max_lsb - 1);
            if (i) |x| {
                keep[x] = 2;
                flags[x] = (if (h.lt_used[k]) va.PICTURE_HEVC_RPS_LT_CURR else 0) | va.PICTURE_HEVC_LONG_TERM_REFERENCE;
            }
        }
    }
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used) continue;
        if (keep[i] == 0) {
            p.short_ref = false;
            p.long_ref = false;
        } else if (keep[i] == 2) {
            p.short_ref = false;
            p.long_ref = true;
        }
        if (!p.isRef() and !p.needed_for_output) {
            cb.released(cb.ctx, p.surface);
            p.* = .{};
        }
    }
    // C.5.2.2: bump while too many wait or the DPB is full
    while (true) {
        var waiting: u32 = 0;
        var used: u32 = 0;
        for (&st.dpb) |*p| {
            if (!p.used) continue;
            used += 1;
            if (p.needed_for_output) waiting += 1;
        }
        if (waiting > sps.max_num_reorder or used >= sps.max_dec_pic_buffering) {
            if (!bump(st, cb)) break;
        } else break;
    }
    var slot: ?usize = null;
    for (&st.dpb, 0..) |*p, i| if (!p.used) {
        slot = i;
        break;
    };
    const si = slot orelse return error.Bad;
    const surface = cb.surface(cb.ctx) orelse return error.Bad;
    st.dpb[si] = .{ .used = true, .surface = surface, .poc = poc, .pts = pts, .duration = duration, .needed_for_output = h.pic_output and !(h.isRasl() and st.skip_rasl) };
    st.cur = si;

    // VA's picture parameters (FFmpeg's vaapi_hevc)
    const pp = &out.pic;
    pp.* = std.mem.zeroes(va.PictureParameterBufferHEVC);
    pp.CurrPic = .{ .picture_id = surface, .pic_order_cnt = poc, .flags = 0 };
    var k: usize = 0;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or i == si or !p.isRef()) continue;
        if (k < 15) pp.ReferenceFrames[k] = .{ .picture_id = p.surface, .pic_order_cnt = p.poc, .flags = flags[i] | (if (p.long_ref) va.PICTURE_HEVC_LONG_TERM_REFERENCE else 0) };
        k += 1;
    }
    while (k < 15) : (k += 1) pp.ReferenceFrames[k] = .{ .picture_id = 0xffffffff, .pic_order_cnt = 0, .flags = va.PICTURE_HEVC_INVALID };
    pp.pic_width_in_luma_samples = @intCast(sps.width);
    pp.pic_height_in_luma_samples = @intCast(sps.height);
    pp.pic_fields = .{
        .chroma_format_idc = sps.chroma_format_idc,
        .separate_colour_plane_flag = @intFromBool(sps.separate_colour_plane),
        .pcm_enabled_flag = @intFromBool(sps.pcm),
        .scaling_list_enabled_flag = @intFromBool(sps.scaling_enabled),
        .transform_skip_enabled_flag = @intFromBool(pps.transform_skip),
        .amp_enabled_flag = @intFromBool(sps.amp),
        .strong_intra_smoothing_enabled_flag = @intFromBool(sps.strong_intra_smoothing),
        .sign_data_hiding_enabled_flag = @intFromBool(pps.sign_data_hiding),
        .constrained_intra_pred_flag = @intFromBool(pps.constrained_intra_pred),
        .cu_qp_delta_enabled_flag = @intFromBool(pps.cu_qp_delta),
        .weighted_pred_flag = @intFromBool(pps.weighted_pred),
        .weighted_bipred_flag = @intFromBool(pps.weighted_bipred),
        .transquant_bypass_enabled_flag = @intFromBool(pps.transquant_bypass),
        .tiles_enabled_flag = @intFromBool(pps.tiles),
        .entropy_coding_sync_enabled_flag = @intFromBool(pps.entropy_sync),
        .pps_loop_filter_across_slices_enabled_flag = @intFromBool(pps.loop_filter_across_slices),
        .loop_filter_across_tiles_enabled_flag = @intFromBool(pps.loop_filter_across_tiles),
        .pcm_loop_filter_disabled_flag = @intFromBool(sps.pcm_loop_filter_disabled),
        .NoPicReorderingFlag = @intFromBool(sps.max_num_reorder == 0),
        .NoBiPredFlag = 0,
    };
    pp.sps_max_dec_pic_buffering_minus1 = sps.max_dec_pic_buffering - 1;
    pp.bit_depth_luma_minus8 = sps.bit_depth_luma - 8;
    pp.bit_depth_chroma_minus8 = sps.bit_depth_chroma - 8;
    pp.pcm_sample_bit_depth_luma_minus1 = if (sps.pcm) sps.pcm_bits_luma - 1 else 0;
    pp.pcm_sample_bit_depth_chroma_minus1 = if (sps.pcm) sps.pcm_bits_chroma - 1 else 0;
    pp.log2_min_luma_coding_block_size_minus3 = sps.log2_min_cb - 3;
    pp.log2_diff_max_min_luma_coding_block_size = sps.log2_diff_cb;
    pp.log2_min_transform_block_size_minus2 = sps.log2_min_tb - 2;
    pp.log2_diff_max_min_transform_block_size = sps.log2_diff_tb;
    pp.log2_min_pcm_luma_coding_block_size_minus3 = if (sps.pcm) sps.log2_min_pcm_cb - 3 else 0;
    pp.log2_diff_max_min_pcm_luma_coding_block_size = sps.log2_diff_pcm_cb;
    pp.max_transform_hierarchy_depth_intra = sps.max_th_depth_intra;
    pp.max_transform_hierarchy_depth_inter = sps.max_th_depth_inter;
    pp.init_qp_minus26 = pps.init_qp_minus26;
    pp.diff_cu_qp_delta_depth = pps.diff_cu_qp_delta_depth;
    pp.pps_cb_qp_offset = pps.cb_qp_offset;
    pp.pps_cr_qp_offset = pps.cr_qp_offset;
    pp.log2_parallel_merge_level_minus2 = pps.log2_parallel_merge_level - 2;
    pp.num_tile_columns_minus1 = pps.tile_cols - 1;
    pp.num_tile_rows_minus1 = pps.tile_rows - 1;
    for (0..pps.tile_cols) |c| pp.column_width_minus1[c] = pps.col_width[c] -| 1;
    for (0..pps.tile_rows) |c| pp.row_height_minus1[c] = pps.row_height[c] -| 1;
    pp.slice_parsing_fields = .{
        .lists_modification_present_flag = @intFromBool(pps.lists_modification),
        .long_term_ref_pics_present_flag = @intFromBool(sps.long_term_present),
        .sps_temporal_mvp_enabled_flag = @intFromBool(sps.temporal_mvp),
        .cabac_init_present_flag = @intFromBool(pps.cabac_init_present),
        .output_flag_present_flag = @intFromBool(pps.output_flag_present),
        .dependent_slice_segments_enabled_flag = @intFromBool(pps.dependent_slices),
        .pps_slice_chroma_qp_offsets_present_flag = @intFromBool(pps.slice_chroma_qp_offsets_present),
        .sample_adaptive_offset_enabled_flag = @intFromBool(sps.sao),
        .deblocking_filter_override_enabled_flag = @intFromBool(pps.deblocking_override),
        .pps_disable_deblocking_filter_flag = @intFromBool(pps.deblocking_disabled),
        .slice_segment_header_extension_present_flag = @intFromBool(pps.slice_header_extension),
        .RapPicFlag = @intFromBool(h.isIrap()),
        .IdrPicFlag = @intFromBool(h.isIdr()),
        .IntraPicFlag = @intFromBool(h.isIrap()),
    };
    pp.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_poc_lsb - 4;
    pp.num_short_term_ref_pic_sets = sps.num_st_rps;
    pp.num_long_term_ref_pic_sps = sps.num_lt_sps;
    pp.num_ref_idx_l0_default_active_minus1 = pps.num_ref_idx_l0 - 1;
    pp.num_ref_idx_l1_default_active_minus1 = pps.num_ref_idx_l1 - 1;
    pp.pps_beta_offset_div2 = pps.beta_offset_div2;
    pp.pps_tc_offset_div2 = pps.tc_offset_div2;
    pp.num_extra_slice_header_bits = pps.extra_bits;
    pp.st_rps_bits = h.st_rps_bits;
    // the scaling lists, raster order (FFmpeg's), the PPS's over the SPS's
    const sl = if (pps.scaling_present) &pps.scaling else &sps.scaling;
    const iq = &out.iq;
    iq.* = std.mem.zeroes(va.IQMatrixBufferHEVC);
    iq.ScalingList4x4 = sl.l4;
    iq.ScalingList8x8 = sl.l8;
    iq.ScalingList16x16 = sl.l16;
    iq.ScalingList32x32 = .{ sl.l32[0], sl.l32[3] };
    iq.ScalingListDC16x16 = sl.dc16;
    iq.ScalingListDC32x32 = .{ sl.dc32[0], sl.dc32[3] };
    out.surface = surface;
    out.visible = sps.visible();
    out.width = sps.width;
    out.height = sps.height;
    out.bit_depth = sps.bit_depth_luma;
    out.first = h.*;
    return true;
}

/// Outputs the waiting picture of the lowest POC; frees it when no reference.
fn bump(st: *State, cb: Callbacks) bool {
    var best: ?usize = null;
    for (&st.dpb, 0..) |*p, i| {
        if (!p.used or !p.needed_for_output) continue;
        if (st.cur != null and i == st.cur.?) continue;
        if (best == null or p.poc < st.dpb[best.?].poc) best = i;
    }
    const b = best orelse return false;
    const p = &st.dpb[b];
    p.needed_for_output = false;
    cb.output(cb.ctx, p.surface, p.pts, p.duration);
    if (!p.isRef()) {
        cb.released(cb.ctx, p.surface);
        p.* = .{};
    }
    return true;
}

/// The picture `take` returned has been submitted: marked a short-term
/// reference, and the bumping C.5.2.3 asks for.
pub fn finish(st: *State, pic: *const Picture, cb: Callbacks) void {
    _ = pic;
    const si = st.cur orelse return;
    st.cur = null;
    st.dpb[si].short_ref = true;
    st.serial += 1;
    st.dpb[si].serial = st.serial;
    const sps = st.activeSps() orelse return;
    while (true) {
        var waiting: u32 = 0;
        for (&st.dpb) |*p| {
            if (p.used and p.needed_for_output) waiting += 1;
        }
        if (waiting > sps.max_num_reorder) {
            if (!bump(st, cb)) break;
        } else break;
    }
}

pub fn abandon(st: *State, cb: Callbacks) void {
    const si = st.cur orelse return;
    cb.released(cb.ctx, st.dpb[si].surface);
    st.dpb[si] = .{};
    st.cur = null;
}

pub fn drain(st: *State, cb: Callbacks) void {
    while (bump(st, cb)) {}
}

pub fn reset(st: *State, cb: Callbacks) void {
    for (&st.dpb) |*p| {
        if (!p.used) continue;
        cb.released(cb.ctx, p.surface);
        p.* = .{};
    }
    st.cur = null;
    st.first_irap = true;
    st.prev_tid0_poc = 0;
}
