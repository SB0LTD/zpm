//! @zpm/va enc_rc — the encoder's rate control: the driver's own
//! controller (the default), and the firmware's (opt-in).
//!
//! **The driver's controller** (what runs unless GALAXY_VA_NVENC_RC says
//! otherwise). The engine encodes each picture at the QP chosen here
//! (RCMODE_CONSTQP), so the stream's rate is this file's doing:
//!
//! - **The HRD's leaky bucket** (H.264 Annex C, HEVC Annex C, AV1 Annex
//!   E's decoder model): the coded picture buffer of `buffer_bits` (VA's
//!   HRD misc parameter, else one second of the rate) fills at the peak
//!   rate and each picture is taken out whole at its time. A picture's
//!   size is planned to leave the buffer above a floor (never underflows:
//!   the decoder would wait), and in CBR a buffer that would overflow is
//!   padded (filler data, `Plan.pad_bits`: the bits arrive at the constant
//!   rate whatever the encoder made). VBR lets the buffer sit full.
//! - **Frame-type-aware QP**: one quantiser scale for P pictures, I at
//!   `IP_RATIO` finer and B at `PB_RATIO` coarser (x264's defaults), each
//!   type with its own size model.
//! - **The complexity estimate**, lookahead-free: a picture's bits are
//!   modelled as `alpha[type] * satd / qstep` with `satd` the engine's
//!   summed best-mode SATDs of the last picture (intra or inter by the
//!   type to come; the status the engine writes) and `alpha` learnt from
//!   each finished picture. Without SATDs (0) the model is
//!   `complexity[type] / qstep`, learnt the same way. A scene cut shows
//!   in the last picture's intra cost before the next I picture is
//!   planned.
//! - **The GOP's budget**: the average picture's bits (rate / frame rate)
//!   are shared between I, P and B by what the model expects each to cost
//!   at the current scale and how many of each a GOP has (intra and IP
//!   periods), then nudged toward the buffer's target fill.
//!
//! The QP domain is H.26x's 0..51 (qstep 2^((qp-4)/6)) or AV1's base_q_idx
//! 0..255 (qstep ~ 4 * 1.0243^q, the 8-bit AC table's span).
//!
//! **The firmware's controller** (GALAXY_VA_NVENC_RC=firmware): SET_
//! CONTROL_PARAMS' RCMODE 1 (VBR) or 2 (CBR), nvenc_drv.h's rate_control
//! struct and the persistent state (RC process buffer). nvenc_drv.h names
//! the fields and the modes but not the units of Np, Bmin, Ravg and R
//! ("23.8 fixed point ... rate"): `firmwareSetup` fills the documented
//! ones exactly (HRD type, QPs, CPB sizes and rates, frame rate, GOP) and
//! those four as bits per picture, which only the hardware can confirm.
//! The driver's controller stays the default for that reason.
//!
//! Allocation-free: fixed fields. Floating point for the model.

const std = @import("std");
const nvenc = @import("nvenc.sig");

pub const Mode = enum { cqp, cbr, vbr };
/// The firmware's QP[] order: P, B, I.
pub const Type = enum(u2) { p = 0, b = 1, i = 2 };
pub const Scale = enum { h26x, av1 };

/// I pictures' qstep this much finer than P's, B's this much coarser.
pub const IP_RATIO: f64 = 1.4;
pub const PB_RATIO: f64 = 1.3;
/// A picture's QP moves at most this much from its type's last (more when
/// the buffer would underflow).
pub const MAX_QP_STEP: i32 = 4;

pub fn qstep(scale: Scale, q: f64) f64 {
    return switch (scale) {
        .h26x => std.math.pow(f64, 2.0, (q - 4.0) / 6.0),
        .av1 => 4.0 * std.math.pow(f64, 1.0243, q),
    };
}

pub fn qOf(scale: Scale, step: f64) f64 {
    const s = @max(step, 1e-6);
    return switch (scale) {
        .h26x => 4.0 + 6.0 * std.math.log2(s),
        .av1 => @log(s / 4.0) / @log(1.0243),
    };
}

pub fn qMax(scale: Scale) i32 {
    return if (scale == .av1) 255 else 51;
}

/// What the next picture is planned as.
pub const Plan = struct {
    qp: i32,
    /// the bits the controller aims at, and the most the buffer allows
    target_bits: u64,
    max_bits: u64,
};

pub const Controller = struct {
    mode: Mode = .cqp,
    scale: Scale = .h26x,
    /// the rate (CBR) or peak rate (VBR), bits per second
    bits_per_second: u64 = 0,
    /// VBR: the average's share of the peak, percent
    target_percentage: u32 = 100,
    fps_num: u32 = 30,
    fps_den: u32 = 1,
    /// the HRD's buffer and its fill at the start (bits; 0: chosen)
    buffer_bits: u64 = 0,
    initial_fullness: u64 = 0,
    min_qp: i32 = 1,
    max_qp: i32 = 51,
    initial_qp: i32 = 0,
    /// GOP shape: an I picture every `intra_period` (0: one), anchors every
    /// `ip_period` (B pictures between)
    intra_period: u32 = 0,
    ip_period: u32 = 1,
    /// the picture's luma samples (the size models' starting guess)
    pixels: u64 = 0,

    // ── state ──
    started: bool = false,
    /// the CPB's fill (bits) just before the next picture is taken out
    fullness: f64 = 0,
    /// the P scale (qstep) the last plan used
    base_step: f64 = 0,
    /// per type: alpha (bits * qstep / satd) and complexity (bits * qstep)
    alpha: [3]f64 = .{ 0, 0, 0 },
    complexity: [3]f64 = .{ 0, 0, 0 },
    seen: [3]u32 = .{ 0, 0, 0 },
    last_qp: [3]i32 = .{ -1, -1, -1 },
    /// the last picture's SATDs
    last_intra_cost: u64 = 0,
    last_inter_cost: u64 = 0,
    /// bookkeeping (and the tests' measure)
    frames: u64 = 0,
    total_bits: u64 = 0,
    underflows: u32 = 0,
    padded_bits: u64 = 0,

    /// VA's rate control misc parameters.
    pub fn rateControl(c: *Controller, bits_per_second: u32, target_percentage: u32, initial_qp: u32, min_qp: u32, max_qp: u32) void {
        const top = qMax(c.scale);
        if (bits_per_second != 0) c.bits_per_second = bits_per_second;
        if (target_percentage != 0) c.target_percentage = @min(target_percentage, 100);
        if (initial_qp != 0) c.initial_qp = @min(@as(i32, @intCast(@min(initial_qp, 255))), top);
        if (min_qp != 0) c.min_qp = @min(@as(i32, @intCast(@min(min_qp, 255))), top);
        if (max_qp != 0) c.max_qp = @min(@as(i32, @intCast(@min(max_qp, 255))), top);
        if (c.max_qp < c.min_qp) c.max_qp = c.min_qp;
    }

    pub fn frameRate(c: *Controller, num: u32, den: u32) void {
        if (num == 0) return;
        c.fps_num = num;
        c.fps_den = if (den == 0) 1 else den;
    }

    pub fn hrd(c: *Controller, buffer_bits: u32, initial_fullness: u32) void {
        if (buffer_bits != 0) c.buffer_bits = buffer_bits;
        if (initial_fullness != 0) c.initial_fullness = initial_fullness;
    }

    pub fn active(c: *const Controller) bool {
        return c.mode != .cqp and c.bits_per_second != 0;
    }

    fn fps(c: *const Controller) f64 {
        return @as(f64, @floatFromInt(c.fps_num)) / @as(f64, @floatFromInt(@max(c.fps_den, 1)));
    }

    /// The average bits a second the stream aims at.
    pub fn averageRate(c: *const Controller) f64 {
        const peak: f64 = @floatFromInt(c.bits_per_second);
        return if (c.mode == .vbr) peak * @as(f64, @floatFromInt(c.target_percentage)) / 100.0 else peak;
    }

    /// The bits the buffer takes in per picture (the peak rate's share).
    fn inflow(c: *const Controller) f64 {
        return @as(f64, @floatFromInt(c.bits_per_second)) / c.fps();
    }

    pub fn bufferBits(c: *const Controller) f64 {
        return if (c.buffer_bits != 0) @floatFromInt(c.buffer_bits) else @floatFromInt(c.bits_per_second);
    }

    fn start(c: *Controller) void {
        c.started = true;
        const b = c.bufferBits();
        c.fullness = if (c.initial_fullness != 0) @min(@as(f64, @floatFromInt(c.initial_fullness)), b) else b * 0.75;
        // the first scale: the app's QP, else a guess from bits per pixel
        const avg = c.averageRate() / c.fps();
        const px: f64 = @floatFromInt(@max(c.pixels, 1));
        const bpp = avg / px;
        var q0: f64 = if (c.initial_qp != 0) @floatFromInt(c.initial_qp) else if (bpp < 0.03) 40 else if (bpp < 0.06) 35 else if (bpp < 0.12) 31 else if (bpp < 0.25) 27 else 23;
        if (c.scale == .av1 and c.initial_qp == 0) q0 = q0 * 255.0 / 51.0;
        c.base_step = qstep(c.scale, q0);
        // size models: a P picture of `avg` bits at that scale, an I
        // picture four of them, a B picture half
        const k = [3]f64{ 1.0, 0.5, 4.0 };
        for (0..3) |t| c.complexity[t] = avg * k[t] * c.base_step;
    }

    /// The expected bits of a picture of `t` at qstep `step`.
    fn expect(c: *const Controller, t: Type, step: f64) f64 {
        const i = @intFromEnum(t);
        const satd: f64 = @floatFromInt(if (t == .i) c.last_intra_cost else c.last_inter_cost);
        if (c.seen[i] > 0 and c.alpha[i] > 0 and satd > 0) return c.alpha[i] * satd / step;
        // (a type not seen yet: from P's, by the usual ratios)
        if (c.seen[i] == 0 and c.seen[0] > 0) {
            const p = c.complexity[0];
            const r: f64 = switch (t) {
                .i => 4.0,
                .b => 0.5,
                .p => 1.0,
            };
            return p * r / step;
        }
        return c.complexity[i] / step;
    }

    fn typeStep(t: Type, base: f64) f64 {
        return switch (t) {
            .i => base / IP_RATIO,
            .b => base * PB_RATIO,
            .p => base,
        };
    }

    /// How many I, P and B pictures a GOP has.
    fn gop(c: *const Controller) [3]f64 {
        const n: f64 = if (c.intra_period == 0) 1_000_000 else @floatFromInt(c.intra_period);
        const m: f64 = @floatFromInt(@max(c.ip_period, 1));
        const anchors = @ceil(n / m);
        const b = n - anchors;
        const i: f64 = if (c.intra_period == 0) 0 else 1;
        return .{ @max(anchors - i, 0), b, i };
    }

    /// The plan for the next picture of type `t` (`app_qp`: CQP's).
    pub fn plan(c: *Controller, t: Type, app_qp: i32) Plan {
        if (!c.active()) {
            const q = std.math.clamp(app_qp, 0, qMax(c.scale));
            return .{ .qp = q, .target_bits = 0, .max_bits = std.math.maxInt(u64) };
        }
        if (!c.started) c.start();
        const avg = c.averageRate() / c.fps();
        // the GOP's budget at the current scale, shared by type
        const n = c.gop();
        var want: f64 = 0;
        var per: [3]f64 = undefined;
        for (0..3) |k| {
            const kt: Type = @enumFromInt(k);
            per[k] = c.expect(kt, typeStep(kt, c.base_step));
            want += n[k] * per[k];
        }
        const pictures = n[0] + n[1] + n[2];
        const scale_up = if (want > 0) avg * pictures / want else 1.0;
        var target = per[@intFromEnum(t)] * scale_up;
        const b = c.bufferBits();
        if (c.mode == .cbr) {
            // toward the buffer's target fill (half: room both ways)
            target += (c.fullness - b * 0.5) * 0.25;
        } else {
            // VBR: the buffer fills at the peak rate, so it only bounds a
            // picture; the average is held by the bits spent so far
            // against the average's share (paid back over two seconds)
            const debt = @as(f64, @floatFromInt(c.total_bits)) - avg * @as(f64, @floatFromInt(c.frames));
            target -= debt / @max(c.fps() * 2.0, 1.0);
        }
        target = std.math.clamp(target, avg * 0.1, avg * 8.0);
        // the buffer's floor: take out at most what is there, less a tenth
        const most = @max(c.fullness - b * 0.1, avg * 0.05);
        if (target > most) target = most;
        // the qstep that makes the model say `target`
        const per_unit = c.expect(t, 1.0);
        var q: i32 = @intFromFloat(@round(qOf(c.scale, per_unit / @max(target, 1.0))));
        const ti = @intFromEnum(t);
        const step_limit: i32 = if (c.scale == .av1) MAX_QP_STEP * 5 else MAX_QP_STEP;
        if (c.last_qp[ti] >= 0) {
            const lo = c.last_qp[ti] - step_limit;
            // (the buffer near empty: climb as far as it takes)
            const hi = if (c.fullness < b * 0.3) qMax(c.scale) else c.last_qp[ti] + step_limit;
            q = std.math.clamp(q, lo, hi);
        }
        q = std.math.clamp(q, c.min_qp, c.max_qp);
        // the scale for the other types follows this picture's choice
        const used = qstep(c.scale, @floatFromInt(q));
        c.base_step = switch (t) {
            .i => used * IP_RATIO,
            .b => used / PB_RATIO,
            .p => used,
        };
        return .{ .qp = q, .target_bits = @intFromFloat(@max(target, 0)), .max_bits = @intFromFloat(@max(most, 0)) };
    }

    /// A picture of type `t` came out `bits` long at `qp`, the engine's
    /// SATDs as given (0: none): the models learn, the buffer moves. The
    /// bits of filler CBR needs after it (0 for VBR and CQP).
    pub fn done(c: *Controller, t: Type, bits: u64, qp: i32, intra_cost: u64, inter_cost: u64) u64 {
        c.frames += 1;
        c.total_bits += bits;
        if (!c.active()) return 0;
        if (!c.started) c.start();
        const ti = @intFromEnum(t);
        const step = qstep(c.scale, @floatFromInt(qp));
        const fb: f64 = @floatFromInt(@max(bits, 1));
        // the satd this picture's prediction used
        const satd: f64 = @floatFromInt(if (t == .i) c.last_intra_cost else c.last_inter_cost);
        const w: f64 = if (c.seen[ti] == 0) 1.0 else 0.5;
        if (satd > 0) c.alpha[ti] = (1 - w) * c.alpha[ti] + w * (fb * step / satd);
        c.complexity[ti] = (1 - w) * c.complexity[ti] + w * (fb * step);
        c.seen[ti] += 1;
        c.last_qp[ti] = qp;
        if (intra_cost != 0) c.last_intra_cost = intra_cost;
        if (inter_cost != 0) c.last_inter_cost = inter_cost;
        // the bucket: the picture out, a picture's time of inflow in
        c.fullness -= fb;
        if (c.fullness < 0) {
            c.underflows += 1;
            c.fullness = 0;
        }
        c.fullness += c.inflow();
        const b = c.bufferBits();
        var pad: u64 = 0;
        if (c.fullness > b) {
            if (c.mode == .cbr) {
                pad = @intFromFloat(@ceil(c.fullness - b));
                // (whole bytes)
                pad = (pad + 7) / 8 * 8;
                c.padded_bits += pad;
                c.total_bits += pad;
            }
            c.fullness = b;
        }
        return pad;
    }

    /// The bits a second so far (frames at the frame rate).
    pub fn measuredRate(c: *const Controller) f64 {
        if (c.frames == 0) return 0;
        return @as(f64, @floatFromInt(c.total_bits)) / @as(f64, @floatFromInt(c.frames)) * c.fps();
    }
};

/// The setup fields of one codec's rate_control struct.
pub const RcFields = struct {
    hrd_type: nvenc.F,
    qp: [3]nvenc.F,
    min_qp: [3]nvenc.F,
    max_qp: [3]nvenc.F,
    max_qpd: nvenc.F,
    base_qpd: nvenc.F,
    rhopbi: nvenc.F,
    framerate: nvenc.F,
    buffersize: nvenc.F,
    nal_cpb_size: nvenc.F,
    nal_bitrate: nvenc.F,
    vcl_cpb_size: nvenc.F,
    vcl_bitrate: nvenc.F,
    gop_length: nvenc.F,
    np: nvenc.F,
    bmin: nvenc.F,
    ravg: nvenc.F,
    r: nvenc.F,
    ab_alpha: nvenc.F,
    i_size_ratio_x: nvenc.F,
    i_size_ratio_y: nvenc.F,

    pub fn of(comptime S: type) RcFields {
        return .{
            .hrd_type = S.rc_hrd_type,
            .qp = .{ S.rc_qp_p, S.rc_qp_b, S.rc_qp_i },
            .min_qp = .{ S.rc_min_qp_p, S.rc_min_qp_b, S.rc_min_qp_i },
            .max_qp = .{ S.rc_max_qp_p, S.rc_max_qp_b, S.rc_max_qp_i },
            .max_qpd = S.rc_max_qpd,
            .base_qpd = S.rc_base_qpd,
            .rhopbi = S.rc_rhopbi,
            .framerate = S.rc_framerate,
            .buffersize = S.rc_buffersize,
            .nal_cpb_size = S.rc_nal_cpb_size,
            .nal_bitrate = S.rc_nal_bitrate,
            .vcl_cpb_size = S.rc_vcl_cpb_size,
            .vcl_bitrate = S.rc_vcl_bitrate,
            .gop_length = S.rc_gop_length,
            .np = S.rc_np,
            .bmin = S.rc_bmin,
            .ravg = S.rc_ravg,
            .r = S.rc_r,
            .ab_alpha = S.rc_ab_alpha,
            .i_size_ratio_x = S.rc_i_size_ratio_x,
            .i_size_ratio_y = S.rc_i_size_ratio_y,
        };
    }
};

/// The driver's QP into the setup (constant QP: every type's QP, minimum
/// and maximum the same).
pub fn constQp(buf: []u8, f: RcFields, qp: u32, framerate: u32, gop_length: u32) void {
    for (0..3) |k| {
        nvenc.set(buf, f.qp[k], qp);
        nvenc.set(buf, f.min_qp[k], qp);
        nvenc.set(buf, f.max_qp[k], qp);
    }
    nvenc.set(buf, f.framerate, framerate);
    nvenc.set(buf, f.gop_length, gop_length);
}

/// 23.8 fixed point.
fn fix8(v: f64) u64 {
    return @bitCast(@as(i64, @intFromFloat(@round(v * 256.0))));
}

/// The firmware's rate control into the setup: what nvenc_drv.h documents
/// set exactly; Np, Bmin, Ravg and R as bits per picture (ASSUMED: the
/// header gives only "23.8 fixed point rate"). Its RCMODE.
pub fn firmwareSetup(buf: []u8, f: RcFields, c: *const Controller, first_qp: [3]i32, b_frames: u32) u32 {
    const rate = c.bits_per_second;
    const b = c.bufferBits();
    nvenc.set(buf, f.hrd_type, 2); // NAL
    for (0..3) |k| {
        nvenc.set(buf, f.qp[k], @intCast(std.math.clamp(first_qp[k], c.min_qp, c.max_qp)));
        nvenc.set(buf, f.min_qp[k], @intCast(c.min_qp));
        nvenc.set(buf, f.max_qp[k], @intCast(c.max_qp));
    }
    nvenc.set(buf, f.max_qpd, @intCast(MAX_QP_STEP));
    nvenc.set(buf, f.base_qpd, 1);
    // P/I, B/I, I/I quantiser ratios
    const ratios = [3]f64{ IP_RATIO, IP_RATIO * PB_RATIO, 1.0 };
    for (ratios, 0..) |r, k| nvenc.set(buf, nvenc.at(f.rhopbi, @intCast(k)), fix8(r));
    const fps_i = (c.fps_num + c.fps_den / 2) / @max(c.fps_den, 1);
    nvenc.set(buf, f.framerate, fps_i);
    nvenc.set(buf, f.buffersize, @intFromFloat(b));
    nvenc.set(buf, f.nal_cpb_size, @intFromFloat(b));
    nvenc.set(buf, f.nal_bitrate, rate);
    // (H.264 Annex E: the VCL buffer and rate are 1000/1200 of the NAL's)
    nvenc.set(buf, f.vcl_cpb_size, @intFromFloat(b * 1000.0 / 1200.0));
    nvenc.set(buf, f.vcl_bitrate, rate * 1000 / 1200);
    const gop_len: u32 = if (c.intra_period == 0) 0xffff_ffff else c.intra_period;
    nvenc.set(buf, f.gop_length, gop_len);
    const np: f64 = if (c.intra_period == 0) 0 else (@as(f64, @floatFromInt(c.intra_period + b_frames)) - 1.0) / @as(f64, @floatFromInt(b_frames + 1));
    nvenc.set(buf, f.np, @bitCast(@as(i64, @intFromFloat(@round(np * 16.0)))));
    const per_picture = c.averageRate() / c.fps();
    nvenc.set(buf, f.ravg, fix8(per_picture));
    nvenc.set(buf, f.r, fix8(@as(f64, @floatFromInt(rate)) / c.fps()));
    nvenc.set(buf, f.bmin, fix8(b * 0.1));
    nvenc.set(buf, f.ab_alpha, @intCast(std.math.clamp(c.min_qp, 1, 51)));
    nvenc.set(buf, f.i_size_ratio_x, 4);
    nvenc.set(buf, f.i_size_ratio_y, 1);
    return if (c.mode == .cbr) nvenc.RCMODE_CBR else nvenc.RCMODE_VBR;
}

/// The persistent state's start (nvenc_drv.h's macros: NVENC_VBR_INIT_BAVG
/// zero, NVENC_RC_INIT_COMPLEXITY(bpp at qstep 1) = bpp * 16; the buffers'
/// fill in 28.4).
pub fn firmwareState(state: []u8, c: *const Controller) void {
    @memset(state[0..nvenc.Persistent.SIZE], 0);
    const b = c.bufferBits();
    const full = if (c.initial_fullness != 0) @as(f64, @floatFromInt(c.initial_fullness)) else b * 0.75;
    nvenc.set(state, nvenc.Persistent.nal_cpb_fullness, @bitCast(@as(i64, @intFromFloat(full * 16.0))));
    nvenc.set(state, nvenc.Persistent.vcl_cpb_fullness, @bitCast(@as(i64, @intFromFloat(full * 1000.0 / 1200.0 * 16.0))));
    // bits per pixel at qstep 1, P B I (an assumption: typical camera video)
    const bpp = [3]f64{ 2.0, 1.2, 6.0 };
    for (bpp, 0..) |v, k| {
        const w: u64 = @intFromFloat(v * 16.0);
        nvenc.set(state, nvenc.at(nvenc.Persistent.wpbi, @intCast(k)), w);
        for (0..3) |j| nvenc.set(state, nvenc.at(nvenc.Persistent.whist, @intCast(k * 3 + j)), w);
    }
    const px: f64 = @floatFromInt(@max(c.pixels, 1));
    nvenc.set(state, nvenc.Persistent.rmean, fix8(c.averageRate() / c.fps() / px));
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A synthetic encoder: a picture's bits are its content's complexity
/// over the qstep (I pictures four times P's, B half), with scene cuts and
/// a noise term, and its SATDs follow the content.
const Synthetic = struct {
    rng: std.Random.DefaultPrng,
    scene: f64 = 1.0,

    fn content(s: *Synthetic, n: usize) f64 {
        // a scene cut every 97 pictures, each scene its own complexity
        if (n % 97 == 0) s.scene = 0.4 + s.rng.random().float(f64) * 2.2;
        return s.scene;
    }

    fn bits(s: *Synthetic, scale: Scale, t: Type, qp: i32, base: f64) u64 {
        const k: f64 = switch (t) {
            .i => 4.0,
            .p => 1.0,
            .b => 0.45,
        };
        const noise = 0.85 + s.rng.random().float(f64) * 0.3;
        return @intFromFloat(base * s.scene * k * noise / qstep(scale, @floatFromInt(qp)));
    }
};

fn runSequence(mode: Mode, scale: Scale, pictures: usize, intra_period: u32, ip_period: u32) !Controller {
    var c = Controller{ .mode = mode, .scale = scale, .pixels = 1280 * 720, .intra_period = intra_period, .ip_period = ip_period, .max_qp = qMax(scale) };
    c.rateControl(2_000_000, if (mode == .vbr) 80 else 100, 0, 1, @intCast(qMax(scale)), );
    c.frameRate(30, 1);
    c.hrd(2_000_000, 1_500_000);
    var s = Synthetic{ .rng = std.Random.DefaultPrng.init(7) };
    // bits at qstep 1 for a P picture of 1280x720 camera video
    const base: f64 = if (scale == .av1) 3_000_000 else 1_200_000;
    for (0..pictures) |n| {
        const scene = s.content(n);
        const t: Type = if (intra_period != 0 and n % intra_period == 0) .i else if (ip_period > 1 and n % ip_period != 0) .b else .p;
        const p = c.plan(t, 30);
        const b = s.bits(scale, t, p.qp, base);
        // (the engine's SATDs: the content's, intra larger)
        const satd: u64 = @intFromFloat(scene * 5_000_000);
        _ = c.done(t, b, p.qp, satd * 3, satd);
    }
    return c;
}

test "enc_rc: CBR holds its rate over scene cuts, the HRD buffer never runs dry" {
    const c = try runSequence(.cbr, .h26x, 900, 60, 1);
    const rate = c.measuredRate();
    // within 3% of 2 Mb/s (filler included: CBR is constant)
    try testing.expect(@abs(rate - 2_000_000) < 60_000);
    try testing.expectEqual(@as(u32, 0), c.underflows);
    // (and the QPs it chose stayed in range)
    for (c.last_qp) |q| try testing.expect(q == -1 or (q >= 1 and q <= 51));
}

test "enc_rc: VBR holds its average, below the peak; B pictures; AV1's scale" {
    const v = try runSequence(.vbr, .h26x, 900, 120, 3);
    const rate = v.measuredRate();
    // 80% of 2 Mb/s within 5%, no filler in VBR
    try testing.expect(@abs(rate - 1_600_000) < 80_000);
    try testing.expectEqual(@as(u64, 0), v.padded_bits);
    try testing.expectEqual(@as(u32, 0), v.underflows);
    for (v.seen) |n| try testing.expect(n > 0);
    const a = try runSequence(.cbr, .av1, 600, 0, 1);
    try testing.expect(@abs(a.measuredRate() - 2_000_000) < 60_000);
    try testing.expectEqual(@as(u32, 0), a.underflows);
    for (a.last_qp) |q| try testing.expect(q <= 255);
}

test "enc_rc: CQP passes the app's QP through; the QP domains' maps invert" {
    var c = Controller{};
    try testing.expectEqual(@as(i32, 22), c.plan(.p, 22).qp);
    try testing.expectEqual(@as(i32, 51), c.plan(.p, 70).qp);
    try testing.expectEqual(@as(u64, 0), c.done(.p, 1000, 22, 0, 0));
    for ([_]f64{ 10, 26, 40 }) |q| try testing.expect(@abs(qOf(.h26x, qstep(.h26x, q)) - q) < 1e-9);
    for ([_]f64{ 1, 100, 255 }) |q| try testing.expect(@abs(qOf(.av1, qstep(.av1, q)) - q) < 1e-9);
    // qstep doubles every 6 QP
    try testing.expect(@abs(qstep(.h26x, 34) / qstep(.h26x, 28) - 2.0) < 1e-9);
}

test "enc_rc: the firmware's fields" {
    var buf = [_]u8{0} ** nvenc.H264.SIZE;
    var c = Controller{ .mode = .cbr, .bits_per_second = 3_000_000, .buffer_bits = 3_000_000, .intra_period = 30, .pixels = 640 * 480 };
    c.frameRate(30, 1);
    const f = RcFields.of(nvenc.H264);
    try testing.expectEqual(nvenc.RCMODE_CBR, firmwareSetup(&buf, f, &c, .{ 30, 32, 28 }, 0));
    try testing.expectEqual(@as(u64, 2), nvenc.get(&buf, nvenc.H264.rc_hrd_type));
    try testing.expectEqual(@as(u64, 28), nvenc.get(&buf, nvenc.H264.rc_qp_i));
    try testing.expectEqual(@as(u64, 3_000_000), nvenc.get(&buf, nvenc.H264.rc_nal_bitrate));
    try testing.expectEqual(@as(u64, 2_500_000), nvenc.get(&buf, nvenc.H264.rc_vcl_bitrate));
    try testing.expectEqual(@as(u64, 30), nvenc.get(&buf, nvenc.H264.rc_framerate));
    try testing.expectEqual(@as(u64, 30), nvenc.get(&buf, nvenc.H264.rc_gop_length));
    // Np: (30 + 0 - 1) / 1 in 27.4; I/I = 1.0 in 23.8
    try testing.expectEqual(@as(u64, 29 * 16), nvenc.get(&buf, nvenc.H264.rc_np));
    try testing.expectEqual(@as(u64, 256), nvenc.get(&buf, nvenc.at(nvenc.H264.rc_rhopbi, 2)));
    var st = [_]u8{0xaa} ** nvenc.Persistent.SIZE;
    firmwareState(&st, &c);
    try testing.expectEqual(@as(u64, 2_250_000 * 16), nvenc.get(&st, nvenc.Persistent.nal_cpb_fullness));
    try testing.expectEqual(@as(u64, 0), nvenc.get(&st, nvenc.Persistent.bavg));
}
