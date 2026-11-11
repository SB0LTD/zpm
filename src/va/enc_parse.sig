//! @zpm/va enc_parse — what an app's packed HEVC parameter sets say that
//! the engine's slice headers depend on. VA's HEVC sequence and picture
//! parameters leave out the POC LSB length, output_flag_present_flag,
//! num_extra_slice_header_bits, cabac_init_present_flag, the deblocking
//! override, the slice chroma QP offsets, lists modification and the
//! SPS's short-term RPS count: when the app packs its own SPS and PPS
//! (FFmpeg's hevc_vaapi does), they are read here so the engine writes
//! slice headers that agree with them; without packed headers the
//! driver's own parameter sets (enc_hevc.sig) define them.
//!
//! Pure, allocation-free: a bit reader over the NAL unit (emulation
//! prevention bytes skipped).

const std = @import("std");

pub const Reader = struct {
    data: []const u8,
    /// the byte being read and the bit in it (0: most significant)
    pos: usize = 0,
    bit: u3 = 0,
    zeros: u8 = 0,
    bad: bool = false,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    fn byteAt(r: *Reader) ?u8 {
        // an emulation prevention byte (00 00 03) is not data
        if (r.bit == 0 and r.zeros >= 2 and r.pos < r.data.len and r.data[r.pos] == 3) {
            r.pos += 1;
            r.zeros = 0;
        }
        if (r.pos >= r.data.len) return null;
        return r.data[r.pos];
    }

    pub fn flag(r: *Reader) bool {
        return r.u(1) != 0;
    }

    pub fn u(r: *Reader, n: u6) u32 {
        var v: u32 = 0;
        var k: u6 = 0;
        while (k < n) : (k += 1) {
            const b = r.byteAt() orelse {
                r.bad = true;
                return v;
            };
            v = (v << 1) | ((b >> (7 - @as(u3, r.bit))) & 1);
            if (r.bit == 7) {
                r.bit = 0;
                r.zeros = if (b == 0) r.zeros + 1 else 0;
                r.pos += 1;
            } else r.bit += 1;
        }
        return v;
    }

    pub fn ue(r: *Reader) u32 {
        var lz: u6 = 0;
        while (!r.flag()) {
            lz += 1;
            if (lz > 31 or r.bad) {
                r.bad = true;
                return 0;
            }
        }
        if (lz == 0) return 0;
        return ((@as(u32, 1) << @intCast(lz)) - 1) + r.u(lz);
    }

    pub fn se(r: *Reader) i32 {
        const k = r.ue();
        const m: i32 = @intCast((k + 1) / 2);
        return if (k % 2 == 1) m else -m;
    }
};

/// What the slice headers depend on (the defaults: the driver's own
/// parameter sets', enc_hevc.sig).
pub const HevcParams = struct {
    have_sps: bool = false,
    have_pps: bool = false,
    log2_max_poc_lsb_minus4: u4 = 8,
    sao: bool = false,
    temporal_mvp: bool = false,
    num_short_term_ref_pic_sets: u7 = 0,
    long_term_ref_pics_present: bool = false,
    output_flag_present: bool = false,
    num_extra_slice_header_bits: u3 = 0,
    cabac_init_present: bool = false,
    deblocking_override_enabled: bool = false,
    slice_chroma_qp_offsets_present: bool = false,
    lists_modification_present: bool = false,
    dependent_slice_segments: bool = false,
    slice_header_extension: bool = false,
    /// a parameter set this driver cannot honour (scaling lists, tiles,
    /// long-term references, weighted prediction)
    unsupported: bool = false,
};

/// The SPS's fields: `nal` is one NAL unit without its start code.
pub fn parseSps(p: *HevcParams, nal: []const u8) void {
    var r = Reader.init(nal);
    _ = r.u(16); // NAL unit header
    _ = r.u(4); // sps_video_parameter_set_id
    const sub = r.u(3);
    _ = r.flag(); // temporal id nesting
    // profile_tier_level, with each sub-layer's flags kept for its payload
    _ = r.u(8);
    _ = r.u(32);
    _ = r.u(32);
    _ = r.u(16);
    _ = r.u(8);
    var prof: [8]bool = .{false} ** 8;
    var lev: [8]bool = .{false} ** 8;
    for (0..sub) |k| {
        prof[k] = r.flag();
        lev[k] = r.flag();
    }
    if (sub > 0) {
        for (sub..8) |_| _ = r.u(2);
    }
    for (0..sub) |k| {
        if (prof[k]) {
            _ = r.u(8);
            _ = r.u(32);
            _ = r.u(32);
            _ = r.u(16);
        }
        if (lev[k]) _ = r.u(8);
    }
    _ = r.ue(); // sps_seq_parameter_set_id
    const chroma = r.ue();
    if (chroma == 3) _ = r.flag();
    _ = r.ue(); // width
    _ = r.ue(); // height
    if (r.flag()) { // conformance window
        for (0..4) |_| _ = r.ue();
    }
    _ = r.ue(); // bit depths
    _ = r.ue();
    const poc = r.ue();
    if (r.bad or poc > 12) return;
    p.log2_max_poc_lsb_minus4 = @intCast(poc);
    p.have_sps = true;
    const ordering = r.flag();
    var i: u32 = if (ordering) 0 else sub;
    while (i <= sub) : (i += 1) {
        _ = r.ue();
        _ = r.ue();
        _ = r.ue();
    }
    for (0..6) |_| _ = r.ue(); // block sizes, depths
    if (r.flag()) { // scaling_list_enabled_flag
        p.unsupported = true;
        return;
    }
    _ = r.flag(); // amp
    p.sao = r.flag();
    if (r.flag()) { // pcm
        p.unsupported = true;
        return;
    }
    const sets = r.ue();
    if (sets > 64) {
        p.unsupported = true;
        return;
    }
    p.num_short_term_ref_pic_sets = @intCast(sets);
    var num_delta: [65]u32 = undefined;
    for (0..sets) |k| num_delta[k] = stRefPicSet(&r, @intCast(k), sets, &num_delta);
    p.long_term_ref_pics_present = r.flag();
    if (p.long_term_ref_pics_present) {
        p.unsupported = true;
        return;
    }
    p.temporal_mvp = r.flag();
    if (r.bad) p.unsupported = true;
}

/// st_ref_pic_set(idx) read past; its NumDeltaPocs.
fn stRefPicSet(r: *Reader, idx: u32, num_sets: u32, num_delta: *const [65]u32) u32 {
    var inter = false;
    if (idx != 0) inter = r.flag();
    if (inter) {
        var delta_idx: u32 = 1;
        if (idx == num_sets) delta_idx = r.ue() + 1;
        _ = r.flag(); // delta_rps_sign
        _ = r.ue(); // abs_delta_rps_minus1
        const ref = idx - @min(delta_idx, idx);
        var n: u32 = 0;
        for (0..num_delta[ref] + 1) |_| {
            const used = r.flag();
            var use_delta = true;
            if (!used) use_delta = r.flag();
            if (used or use_delta) n += 1;
        }
        return n;
    }
    const neg = r.ue();
    const pos = r.ue();
    for (0..neg + pos) |_| {
        _ = r.ue();
        _ = r.flag();
    }
    return neg + pos;
}

pub fn parsePps(p: *HevcParams, nal: []const u8) void {
    var r = Reader.init(nal);
    _ = r.u(16);
    _ = r.ue(); // pps id
    _ = r.ue(); // sps id
    p.dependent_slice_segments = r.flag();
    p.output_flag_present = r.flag();
    p.num_extra_slice_header_bits = @intCast(r.u(3));
    _ = r.flag(); // sign data hiding
    p.cabac_init_present = r.flag();
    _ = r.ue();
    _ = r.ue();
    _ = r.se(); // init_qp_minus26
    _ = r.flag();
    _ = r.flag();
    if (r.flag()) _ = r.ue(); // cu_qp_delta
    _ = r.se();
    _ = r.se();
    p.slice_chroma_qp_offsets_present = r.flag();
    const wp = r.flag();
    const wbp = r.flag();
    _ = r.flag(); // transquant bypass
    const tiles = r.flag();
    _ = r.flag(); // entropy coding sync
    if (tiles or wp or wbp) {
        p.unsupported = true;
        return;
    }
    _ = r.flag(); // loop filter across slices
    if (r.flag()) { // deblocking_filter_control_present_flag
        p.deblocking_override_enabled = r.flag();
        if (!r.flag()) {
            _ = r.se();
            _ = r.se();
        }
    }
    if (r.flag()) { // pps_scaling_list_data_present_flag
        p.unsupported = true;
        return;
    }
    p.lists_modification_present = r.flag();
    _ = r.ue(); // log2_parallel_merge_level_minus2
    p.slice_header_extension = r.flag();
    if (!r.bad) p.have_pps = true;
}

/// Each SPS and PPS NAL unit in a packed header (start codes, emulation
/// prevention as written).
pub fn parsePacked(p: *HevcParams, data: []const u8) void {
    var i: usize = 0;
    while (nextStart(data, i)) |s| {
        const body = s + 3;
        const end = nextStart(data, body) orelse data.len;
        // (a 4-byte start code's leading zero belongs to the next one)
        var stop = end;
        while (stop > body and data[stop - 1] == 0 and stop < data.len) stop -= 1;
        if (body + 2 <= stop) {
            const t = (data[body] >> 1) & 0x3f;
            switch (t) {
                33 => parseSps(p, data[body..stop]),
                34 => parsePps(p, data[body..stop]),
                else => {},
            }
        }
        i = end;
    }
}

fn nextStart(data: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 3 <= data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) return i;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const bits = @import("bits.sig");

test "enc_parse: the reader skips emulation prevention, reads Exp-Golomb" {
    // 00 00 03 01: the 03 is not data
    var r = Reader.init(&.{ 0x00, 0x00, 0x03, 0x01, 0b1010_0110 });
    try testing.expectEqual(@as(u32, 0), r.u(16));
    try testing.expectEqual(@as(u32, 1), r.u(8));
    try testing.expectEqual(@as(u32, 0), r.ue()); // 1
    try testing.expectEqual(@as(u32, 1), r.ue()); // 010
    try testing.expectEqual(@as(i32, -1), r.se()); // 011
    try testing.expect(!r.bad);
}

test "enc_parse: a VPS/SPS/PPS with a 16-bit POC LSB, output flags, extra bits" {
    // an SPS and a PPS written by hand with the bit writer
    var sps: [64]u8 = undefined;
    var w = bits.Writer.init(&sps);
    w.u(16, 0x4201);
    w.u(4, 0);
    w.u(3, 0);
    w.flag(true);
    w.u(8, 0x01);
    w.u(32, 0x6000_0000);
    w.u(32, 0x9000_0000);
    w.u(16, 0);
    w.u(8, 93);
    w.ue(0);
    w.ue(1);
    w.ue(64);
    w.ue(48);
    w.flag(false);
    w.ue(0);
    w.ue(0);
    w.ue(12); // log2_max_pic_order_cnt_lsb_minus4
    w.flag(false);
    w.ue(4);
    w.ue(2);
    w.ue(0);
    for (0..6) |_| w.ue(1);
    w.flag(false); // scaling
    w.flag(true); // amp
    w.flag(true); // sao
    w.flag(false); // pcm
    w.ue(2); // two short-term RPSs: one explicit, one predicted
    w.ue(1); // neg
    w.ue(0); // pos
    w.ue(0);
    w.flag(true);
    w.flag(true); // inter_ref_pic_set_prediction_flag
    w.flag(false); // sign
    w.ue(0); // abs_delta_rps_minus1
    w.flag(true); // used (j = 0)
    w.flag(false); // used (j = 1)
    w.flag(true); // use_delta
    w.flag(false); // long-term
    w.flag(true); // temporal mvp
    w.flag(true); // strong intra
    w.flag(false); // vui
    w.flag(false);
    w.trailing();
    var pps: [32]u8 = undefined;
    var v = bits.Writer.init(&pps);
    v.u(16, 0x4401);
    v.ue(0);
    v.ue(0);
    v.flag(false);
    v.flag(true); // output_flag_present
    v.u(3, 2); // extra bits
    v.flag(false);
    v.flag(true); // cabac init present
    v.ue(0);
    v.ue(0);
    v.se(4);
    v.flag(false);
    v.flag(false);
    v.flag(false);
    v.se(0);
    v.se(0);
    v.flag(false);
    v.flag(false);
    v.flag(false);
    v.flag(false);
    v.flag(false);
    v.flag(false);
    v.flag(true); // loop filter across slices
    v.flag(true); // deblocking control
    v.flag(true); // override enabled
    v.flag(false); // not disabled
    v.se(0);
    v.se(0);
    v.flag(false);
    v.flag(true); // lists modification
    v.ue(0);
    v.flag(false);
    v.flag(false);
    v.trailing();
    var packed_buf: [128]u8 = undefined;
    var n = bits.nal(&packed_buf, w.bytes(), 2).?;
    n += bits.nal(packed_buf[n..], v.bytes(), 2).?;
    var p = HevcParams{};
    parsePacked(&p, packed_buf[0..n]);
    try testing.expect(p.have_sps and p.have_pps and !p.unsupported);
    try testing.expectEqual(@as(u4, 12), p.log2_max_poc_lsb_minus4);
    try testing.expect(p.sao and p.temporal_mvp);
    try testing.expectEqual(@as(u7, 2), p.num_short_term_ref_pic_sets);
    try testing.expect(p.output_flag_present and p.cabac_init_present and p.deblocking_override_enabled and p.lists_modification_present);
    try testing.expectEqual(@as(u3, 2), p.num_extra_slice_header_bits);
}
