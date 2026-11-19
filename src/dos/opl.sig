//! FM music: a YMF262 (OPL3), which is also an OPL2 (YM3812) until a
//! program sets its NEW bit, at 0x388-0x38B (AdLib) and the Sound
//! Blaster's 0x220-0x223 / 0x228-0x229: 18 two-operator channels (or 6
//! four-operator ones), the rhythm mode, the envelope generator, the
//! waveforms, vibrato and tremolo, the two timers and the status register
//! programs detect the chip with. Clean room, from Yamaha's data sheets.
//!
//! How it is built (from the YM3812 and YMF262 application manuals and
//! the chips' published behaviour, no emulator's code):
//!
//!  - An operator's phase is a 20-bit fraction of a cycle stepping by
//!    (F-number << block) * MULT / 2 each sample (MULT 0.5, 1-10, 12, 15);
//!    the top 10 bits index the waveform. f = F-num * 49716 * 2^(block-20).
//!  - The waveform is read as a logarithm: a quarter-wave table of
//!    -log2(sin) in 1/256ths, plus the attenuation (0.1875 dB steps = 8 of
//!    those), turned back into a level by a 2^-x table and a shift, as the
//!    chip's log-sin and exponent ROMs do. Output is 13 bits with sign.
//!  - The envelope is a 9-bit attenuation: attack moves exponentially
//!    toward 0 (each step takes off an eighth or more of what is left),
//!    decay, sustain (held when EG-TYP is 1, else it goes on at the
//!    release rate) and release add linearly. Rate = 4 * R + the key
//!    scale offset (block and F-num's top bit, all of it with KSR or a
//!    quarter without), 0-63; each rate step of 4 doubles the speed, the
//!    two low bits add 0, 1/4, 1/2 or 3/4 more. The attack is at once
//!    from 60 up. The sustain level is 3 dB a step (15 = 93 dB).
//!  - Key scale level: the data sheet's table (0-21 dB at 3 dB/octave
//!    across the top block's F-numbers, 3 dB less an octave down), at 0,
//!    1.5, 3 or 6 dB an octave. Total level 0.75 dB a step.
//!  - Tremolo 3.7 Hz, 1 dB or 4.8 dB deep; vibrato 6.1 Hz, 7 or 14 cents
//!    (the F-number's top three bits scaled).
//!  - Feedback: the first operator hears the mean of its last two outputs
//!    scaled from pi/16 (1) to 4 pi (7). FM puts the modulator's output
//!    on the carrier's phase; AM adds them. Four-operator pairs (0-3,
//!    1-4, 2-5 on each bank) chain by the two channels' CNT bits.
//!  - Rhythm: channel 6 is the bass drum, 7 the hi-hat and snare, 8 the
//!    tom-tom and cymbal; the hi-hat, snare and cymbal take their phases
//!    from bits of the hi-hat's and cymbal's phases and a noise bit (a
//!    23-bit shift register). Each rhythm voice counts twice.
//!  - Timers: 1 counts 80 us steps, 2 320 us steps, from their preset to
//!    256; an overflow sets its flag (unless masked) and the IRQ bit.
//!    Reads of the status port count as bus time (a microsecond each), so
//!    a program that waits for the timer by reading the port sees it.
//!
//! The chip runs at its own 49716 Hz as emulated time goes on, into a
//! ring the host's audio resamples (sb_ring.sig).

const std = @import("std");
const ring = @import("sb_ring.sig");

/// The chip's own sample rate (14.31818 MHz / 288).
pub const RATE: u32 = 49716;

// ── The chip's tables ────────────────────────────────────────────────────

/// -log2(sin) over a quarter wave, in 1/256ths.
const LOGSIN = blk: {
    @setEvalBranchQuota(100000);
    var tab: [256]u16 = undefined;
    for (&tab, 0..) |*x, i| {
        const a: f64 = (@as(f64, @floatFromInt(i)) + 0.5) * std.math.pi / 512.0;
        x.* = @intFromFloat(@round(-@log2(@sin(a)) * 256.0));
    }
    break :blk tab;
};

/// 2^-(x+1)/256, times 2048.
const EXP = blk: {
    @setEvalBranchQuota(100000);
    var tab: [256]u16 = undefined;
    for (&tab, 0..) |*x, i| {
        x.* = @intFromFloat(@round(2048.0 * @exp2(-(@as(f64, @floatFromInt(i)) + 1.0) / 256.0)));
    }
    break :blk tab;
};

/// MULT times two.
const MULT2 = [16]u32{ 1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30 };

/// The key scale level at 3 dB/octave for block 7, by F-num's top four
/// bits, in 0.375 dB steps (the data sheet's table).
const KSL_TOP = [16]i32{ 0, 24, 32, 37, 40, 43, 45, 47, 48, 50, 51, 52, 53, 54, 55, 56 };

/// The envelope's step patterns over eight counts for a rate's two low
/// bits (4, 5, 6, 7 steps of 8).
const EG_PAT = [4][8]u8{
    .{ 0, 1, 0, 1, 0, 1, 0, 1 },
    .{ 0, 1, 0, 1, 1, 1, 0, 1 },
    .{ 0, 1, 1, 1, 0, 1, 1, 1 },
    .{ 0, 1, 1, 1, 1, 1, 1, 1 },
};

/// Vibrato's eight positions, in halves of its depth.
const VIB = [8]i32{ 0, 1, 2, 1, 0, -1, -2, -1 };

const ATTACK: u8 = 0;
const DECAY: u8 = 1;
const SUSTAIN: u8 = 2;
const RELEASE: u8 = 3;
const OFF: u8 = 4;

/// An attenuation past this is silent whatever the wave.
const SILENT: i32 = 416;

const Op = struct {
    phase: u32 = 0,
    inc: u32 = 0,
    env: i32 = 511,
    state: u8 = OFF,
    /// The effective rates for attack, decay, sustain and release.
    rates: [4]u8 = .{ 0, 0, 0, 0 },
    sl: i32 = 0,
    /// Total level and key scale level, in envelope steps.
    level: i32 = 0,
    am: bool = false,
    vib: bool = false,
    egt: bool = false,
    ksr: bool = false,
    mult: u4 = 0,
    ksl: u2 = 0,
    tl: u6 = 0,
    ar: u4 = 0,
    dr: u4 = 0,
    slr: u4 = 0,
    rr: u4 = 0,
    wave: u3 = 0,
    /// The waveform in use (OPL2 mode: 0-3 and only with WSE).
    wave_eff: u3 = 0,
    /// Key on from the channel (bit 0) and the rhythm register (bit 1).
    key: u2 = 0,
    fnum: u32 = 0,
    block: u5 = 0,
};

const Chan = struct {
    fnum: u32 = 0,
    block: u5 = 0,
    key: bool = false,
    fb: u4 = 0,
    cnt: u1 = 0,
    left: bool = true,
    right: bool = true,
    hist: [2]i32 = .{ 0, 0 },
};

pub const Opl = struct {
    ops: [36]Op = [_]Op{.{}} ** 36,
    ch: [18]Chan = [_]Chan{.{}} ** 18,
    regs: [512]u8 = [_]u8{0} ** 512,
    addr: u9 = 0,
    new: bool = false,
    wse: bool = false,
    nts: bool = false,
    rhythm: u8 = 0,
    conn: u8 = 0,
    // Timers.
    preset: [2]u8 = .{ 0, 0 },
    cnt: [2]u32 = .{ 0, 0 },
    on: [2]bool = .{ false, false },
    mask: [2]bool = .{ false, false },
    flag: [2]bool = .{ false, false },
    t_us: u32 = 0,
    t2_sub: u32 = 0,
    /// Bus time already spent by status reads, not yet by `advance`.
    ahead: u32 = 0,
    // Time and the generators' counters.
    acc: u64 = 0,
    eg_cnt: u32 = 0,
    am_cnt: u32 = 0,
    am_pos: u32 = 0,
    trem: i32 = 0,
    vib_cnt: u32 = 0,
    noise: u32 = 1,
    /// The FM volume the card's mixer sets (Q12).
    gain: [2]i32 = .{ ring.UNITY, ring.UNITY },
    snd: ring.Ring(8192) = .{},

    pub fn reset(self: *Opl) void {
        self.* = .{};
    }

    // ── Ports ────────────────────────────────────────────────────────────

    fn status(self: *const Opl) u8 {
        var s: u8 = 0;
        if (self.flag[0]) s |= 0x40;
        if (self.flag[1]) s |= 0x20;
        if (s != 0) s |= 0x80;
        return s;
    }

    /// `port` is the offset: 0 = address (bank 0), 1 = data, 2 = address
    /// (bank 1), 3 = data.
    pub fn in8(self: *Opl, port: u2) u8 {
        if (port & 1 != 0) return 0xFF;
        // A read takes about a microsecond of the bus.
        if (self.ahead < 4000) {
            self.ahead += 1;
            self.timers(1);
        }
        return self.status();
    }
    pub fn out8(self: *Opl, port: u2, v: u8) void {
        switch (port) {
            0 => self.addr = v,
            2 => self.addr = 0x100 | @as(u9, v),
            else => self.write(self.addr, v),
        }
    }

    // ── Registers ────────────────────────────────────────────────────────

    /// The channel and operator an operator register's offset names.
    fn slot(bank: u9, off: u8) ?u8 {
        if (off >= 0x16 or off & 7 >= 6) return null;
        const group = off >> 3;
        const w = off & 7;
        const c = group * 3 + w % 3 + @as(u8, if (bank != 0) 9 else 0);
        return c * 2 + w / 3;
    }

    /// 4-op pair p (0-5): its first channel.
    fn pairFirst(p: u3) u8 {
        return switch (p) {
            0, 1, 2 => p,
            else => @as(u8, p) + 6,
        };
    }
    /// Whether channel c is the first (1) or second (2) of an enabled
    /// four-operator pair, or neither (0).
    fn fourOp(self: *const Opl, c: u8) u2 {
        if (!self.new) return 0;
        var p: u3 = 0;
        while (p < 6) : (p += 1) {
            if (self.conn & (@as(u8, 1) << p) == 0) continue;
            const f = pairFirst(p);
            if (c == f) return 1;
            if (c == f + 3) return 2;
        }
        return 0;
    }

    fn write(self: *Opl, a: u9, v: u8) void {
        self.regs[a] = v;
        const bank: u9 = a & 0x100;
        const r: u8 = @truncate(a);
        if (bank != 0 and r == 0x05) {
            self.new = v & 1 != 0;
            self.refreshAll();
            return;
        }
        if (bank != 0 and r == 0x04) {
            self.conn = v & 0x3F;
            self.refreshAll();
            return;
        }
        if (bank == 0) {
            switch (r) {
                0x01 => {
                    self.wse = v & 0x20 != 0;
                    self.refreshAll();
                    return;
                },
                0x02 => {
                    self.preset[0] = v;
                    return;
                },
                0x03 => {
                    self.preset[1] = v;
                    return;
                },
                0x04 => return self.timerControl(v),
                0x08 => {
                    self.nts = v & 0x40 != 0;
                    self.refreshAll();
                    return;
                },
                0xBD => return self.setRhythm(v),
                else => {},
            }
        }
        switch (r) {
            0x20...0x35, 0x40...0x55, 0x60...0x75, 0x80...0x95, 0xE0...0xF5 => {
                const s = slot(bank, r & 0x1F) orelse return;
                const op = &self.ops[s];
                switch (r & 0xE0) {
                    0x20 => {
                        op.am = v & 0x80 != 0;
                        op.vib = v & 0x40 != 0;
                        op.egt = v & 0x20 != 0;
                        op.ksr = v & 0x10 != 0;
                        op.mult = @truncate(v);
                    },
                    0x40 => {
                        op.ksl = @truncate(v >> 6);
                        op.tl = @truncate(v);
                    },
                    0x60 => {
                        op.ar = @truncate(v >> 4);
                        op.dr = @truncate(v);
                    },
                    0x80 => {
                        op.slr = @truncate(v >> 4);
                        op.rr = @truncate(v);
                    },
                    else => op.wave = @truncate(v),
                }
                self.refreshOp(s);
            },
            0xA0...0xA8 => {
                const c = r - 0xA0 + @as(u8, if (bank != 0) 9 else 0);
                const ch = &self.ch[c];
                ch.fnum = (ch.fnum & 0x300) | v;
                self.refreshChan(c);
            },
            0xB0...0xB8 => {
                const c = r - 0xB0 + @as(u8, if (bank != 0) 9 else 0);
                const ch = &self.ch[c];
                ch.fnum = (ch.fnum & 0xFF) | (@as(u32, v & 3) << 8);
                ch.block = @truncate((v >> 2) & 7);
                ch.key = v & 0x20 != 0;
                self.refreshChan(c);
                self.keyChan(c);
            },
            0xC0...0xC8 => {
                const c = r - 0xC0 + @as(u8, if (bank != 0) 9 else 0);
                const ch = &self.ch[c];
                ch.fb = @truncate((v >> 1) & 7);
                ch.cnt = @truncate(v);
                ch.left = v & 0x10 != 0;
                ch.right = v & 0x20 != 0;
            },
            else => {},
        }
    }

    /// The channel whose frequency and key an operator of channel c uses
    /// (a four-operator pair's second channel follows the first).
    fn freqChan(self: *const Opl, c: u8) u8 {
        return if (self.fourOp(c) == 2) c - 3 else c;
    }

    fn refreshAll(self: *Opl) void {
        var s: u8 = 0;
        while (s < 36) : (s += 1) self.refreshOp(s);
    }
    fn refreshChan(self: *Opl, c: u8) void {
        self.refreshOp(c * 2);
        self.refreshOp(c * 2 + 1);
        if (self.fourOp(c) == 1) {
            self.refreshOp((c + 3) * 2);
            self.refreshOp((c + 3) * 2 + 1);
        }
    }

    fn refreshOp(self: *Opl, s: u8) void {
        const op = &self.ops[s];
        const fc = &self.ch[self.freqChan(s / 2)];
        op.fnum = fc.fnum;
        op.block = fc.block;
        op.inc = ((fc.fnum << fc.block) * MULT2[op.mult]) >> 1;
        // Key scale rate.
        const kc: u32 = (@as(u32, fc.block) << 1) | ((fc.fnum >> @as(u5, if (self.nts) 8 else 9)) & 1);
        const ko: u32 = if (op.ksr) kc else kc >> 2;
        op.rates = .{ eff(op.ar, ko), eff(op.dr, ko), if (op.egt) 0 else eff(op.rr, ko), eff(op.rr, ko) };
        const slv: i32 = if (op.slr == 15) 31 else op.slr;
        op.sl = slv << 4;
        // Key scale level.
        var k: i32 = KSL_TOP[fc.fnum >> 6] - 8 * (7 - @as(i32, fc.block));
        if (k < 0) k = 0;
        const ksl: i32 = switch (op.ksl) {
            0 => 0,
            1 => k << 1,
            2 => k,
            3 => k << 2,
        };
        op.level = (@as(i32, op.tl) << 2) + ksl;
        op.wave_eff = if (self.new) op.wave else if (self.wse) op.wave & 3 else 0;
    }

    fn eff(r: u4, ko: u32) u8 {
        if (r == 0) return 0;
        return @intCast(@min(63, @as(u32, r) * 4 + ko));
    }

    fn keyOp(self: *Opl, s: u8, bit: u2, on: bool) void {
        const op = &self.ops[s];
        const was = op.key != 0;
        if (on) op.key |= bit else op.key &= ~bit;
        const now = op.key != 0;
        if (now and !was) {
            op.phase = 0;
            op.state = ATTACK;
            if (op.rates[ATTACK] >= 60) {
                op.env = 0;
                op.state = DECAY;
            }
        } else if (!now and was and op.state != OFF) {
            op.state = RELEASE;
        }
    }

    fn keyChan(self: *Opl, c: u8) void {
        const role = self.fourOp(c);
        if (role == 2) return; // (the first channel keys the pair)
        const on = self.ch[c].key;
        self.keyOp(c * 2, 1, on);
        self.keyOp(c * 2 + 1, 1, on);
        if (role == 1) {
            self.keyOp((c + 3) * 2, 1, on);
            self.keyOp((c + 3) * 2 + 1, 1, on);
        }
    }

    fn setRhythm(self: *Opl, v: u8) void {
        self.rhythm = v;
        const on = v & 0x20 != 0;
        // BD: channel 6's two; HH 7a, SD 7b, TOM 8a, CY 8b.
        self.keyOp(12, 2, on and v & 0x10 != 0);
        self.keyOp(13, 2, on and v & 0x10 != 0);
        self.keyOp(14, 2, on and v & 0x01 != 0);
        self.keyOp(15, 2, on and v & 0x08 != 0);
        self.keyOp(16, 2, on and v & 0x04 != 0);
        self.keyOp(17, 2, on and v & 0x02 != 0);
    }

    // ── Timers ───────────────────────────────────────────────────────────

    fn timerControl(self: *Opl, v: u8) void {
        if (v & 0x80 != 0) {
            self.flag = .{ false, false };
            return;
        }
        self.mask[0] = v & 0x40 != 0;
        self.mask[1] = v & 0x20 != 0;
        const st = [2]bool{ v & 0x01 != 0, v & 0x02 != 0 };
        for (0..2) |i| {
            if (st[i] and !self.on[i]) {
                self.cnt[i] = self.preset[i];
                if (i == 0) self.t_us = 0 else self.t2_sub = 0;
            }
            self.on[i] = st[i];
        }
    }

    fn tick(self: *Opl, i: usize) void {
        if (!self.on[i]) return;
        self.cnt[i] += 1;
        if (self.cnt[i] < 256) return;
        self.cnt[i] = self.preset[i];
        if (!self.mask[i]) self.flag[i] = true;
    }

    /// `us` of timer time: 80 us steps for timer 1, 320 for timer 2.
    fn timers(self: *Opl, us: u32) void {
        if (!self.on[0] and !self.on[1]) {
            self.t_us = (self.t_us + us) % 80;
            return;
        }
        self.t_us += us;
        while (self.t_us >= 80) {
            self.t_us -= 80;
            self.tick(0);
            self.t2_sub += 1;
            if (self.t2_sub == 4) {
                self.t2_sub = 0;
                self.tick(1);
            }
        }
    }

    /// Emulated time goes on by `us` microseconds (the timers run, the
    /// chip makes its samples).
    pub fn advance(self: *Opl, us: u32) void {
        const spent = @min(self.ahead, us);
        self.ahead -= spent;
        self.timers(us - spent);
        self.acc += @as(u64, us) * RATE;
        const n: u32 = @intCast(self.acc / 1_000_000);
        self.acc %= 1_000_000;
        self.render(n);
    }

    /// The chip's sound, added into `out` (interleaved stereo i16 at
    /// `rate`, resampled from the chip's own rate).
    pub fn mix(self: *Opl, out: []i16, rate: u32) void {
        self.snd.mixInto(out, rate, RATE, self.gain[0], self.gain[1]);
    }

    // ── The sound ────────────────────────────────────────────────────────

    fn render(self: *Opl, n: u32) void {
        var any = false;
        for (&self.ops) |*op| {
            if (op.state != OFF) {
                any = true;
                break;
            }
        }
        var i: u32 = 0;
        if (!any) {
            // Silence: the counters run, nothing is computed.
            while (i < n) : (i += 1) {
                self.lfo();
                self.snd.push(0, 0);
            }
            return;
        }
        while (i < n) : (i += 1) {
            self.lfo();
            const s = self.sample();
            self.snd.push(ring.sat16(s[0]), ring.sat16(s[1]));
        }
    }

    fn lfo(self: *Opl) void {
        self.eg_cnt +%= 1;
        self.vib_cnt +%= 1;
        self.am_cnt += 1;
        if (self.am_cnt == 64) {
            self.am_cnt = 0;
            self.am_pos += 1;
            if (self.am_pos == 210) self.am_pos = 0;
            const tri: i32 = @intCast(if (self.am_pos < 105) self.am_pos else 209 - self.am_pos);
            self.trem = if (self.regs[0xBD] & 0x80 != 0) tri >> 2 else tri >> 4;
        }
        const b = ((self.noise >> 22) ^ (self.noise >> 8)) & 1;
        self.noise = ((self.noise << 1) | b) & 0x7FFFFF;
    }

    /// One step of operator `op`'s envelope.
    inline fn envelope(self: *const Opl, op: *Op) void {
        const rate = op.rates[op.state];
        if (rate == 0) return;
        const hi: u32 = rate >> 2;
        const lo = rate & 3;
        var inc: i32 = 0;
        if (hi < 12) {
            const sh: u5 = @intCast(12 - hi);
            if (self.eg_cnt & ((@as(u32, 1) << sh) - 1) != 0) return;
            inc = EG_PAT[lo][(self.eg_cnt >> sh) & 7];
        } else {
            inc = @as(i32, EG_PAT[lo][self.eg_cnt & 7]) << @intCast(hi - 12);
        }
        if (inc == 0) return;
        switch (op.state) {
            ATTACK => {
                if (rate >= 60) op.env = 0 else op.env += (~op.env * inc) >> 3;
                if (op.env <= 0) {
                    op.env = 0;
                    op.state = if (op.sl == 0) SUSTAIN else DECAY;
                }
            },
            DECAY => {
                op.env += inc;
                if (op.env >= op.sl) op.state = SUSTAIN;
                if (op.env >= 511) op.env = 511;
            },
            else => {
                op.env += inc;
                if (op.env >= 511) {
                    op.env = 511;
                    op.state = OFF;
                }
            },
        }
    }

    /// The operator's phase step this sample (with vibrato).
    inline fn step(self: *const Opl, op: *const Op) u32 {
        if (!op.vib) return op.inc;
        const range: i32 = @intCast((op.fnum >> 7) & 7);
        const sh: u5 = if (self.regs[0xBD] & 0x40 != 0) 1 else 2;
        const d = (range * VIB[(self.vib_cnt >> 10) & 7]) >> sh;
        const f: u32 = @intCast(@as(i32, @intCast(op.fnum)) + d);
        return ((f << op.block) * MULT2[op.mult]) >> 1;
    }

    /// The waveform at phase `p` (10 bits) and attenuation `att` (envelope
    /// steps).
    inline fn wave(w: u3, p: u32, att: i32) i32 {
        var neg = false;
        var lg: u32 = 0;
        switch (w) {
            0 => {
                neg = p & 0x200 != 0;
                lg = LOGSIN[quarter(p)];
            },
            1 => {
                if (p & 0x200 != 0) return 0;
                lg = LOGSIN[quarter(p)];
            },
            2 => lg = LOGSIN[quarter(p)],
            3 => {
                if (p & 0x100 != 0) return 0;
                lg = LOGSIN[p & 0xFF];
            },
            4 => {
                if (p & 0x200 != 0) return 0;
                neg = p & 0x100 != 0;
                lg = LOGSIN[quarter(p << 1)];
            },
            5 => {
                if (p & 0x200 != 0) return 0;
                lg = LOGSIN[quarter(p << 1)];
            },
            6 => neg = p & 0x200 != 0,
            7 => {
                neg = p & 0x200 != 0;
                const x = if (neg) (~p) & 0x1FF else p & 0x1FF;
                lg = x << 3;
            },
        }
        const level = lg + (@as(u32, @intCast(att)) << 3);
        const sh = level >> 8;
        if (sh >= 13) return 0;
        const mag: i32 = @intCast((@as(u32, EXP[level & 0xFF]) << 1) >> @intCast(sh));
        return if (neg) -mag else mag;
    }
    inline fn quarter(p: u32) u32 {
        return if (p & 0x100 != 0) (~p) & 0xFF else p & 0xFF;
    }

    /// Operator s's output with `mod` on its phase.
    inline fn calc(self: *Opl, s: usize, mod: i32) i32 {
        const op = &self.ops[s];
        const p = (op.phase >> 10) +% @as(u32, @bitCast(mod));
        op.phase +%= self.step(op);
        if (op.state == OFF) return 0;
        self.envelope(op);
        var att = op.env + op.level;
        if (op.am) att += self.trem;
        if (att >= SILENT) return 0;
        return wave(op.wave_eff, p & 0x3FF, att);
    }
    /// The same at a phase given whole (the rhythm voices).
    inline fn calcAt(self: *Opl, s: usize, p: u32) i32 {
        const op = &self.ops[s];
        op.phase +%= self.step(op);
        if (op.state == OFF) return 0;
        self.envelope(op);
        var att = op.env + op.level;
        if (op.am) att += self.trem;
        if (att >= SILENT) return 0;
        return wave(op.wave_eff, p & 0x3FF, att);
    }

    /// The first operator with the channel's feedback.
    inline fn first(self: *Opl, c: usize) i32 {
        const ch = &self.ch[c];
        const fbm: i32 = if (ch.fb == 0) 0 else (ch.hist[0] + ch.hist[1]) >> @intCast(9 - @as(u32, ch.fb));
        const o = self.calc(c * 2, fbm);
        ch.hist[1] = ch.hist[0];
        ch.hist[0] = o;
        return o;
    }

    fn twoOp(self: *Opl, c: usize) i32 {
        const a = self.first(c);
        if (self.ch[c].cnt == 0) return self.calc(c * 2 + 1, a);
        return a + self.calc(c * 2 + 1, 0);
    }

    fn fourOpOut(self: *Opl, c: usize) i32 {
        const a = self.first(c);
        const c2 = c + 3;
        const alg = (@as(u2, self.ch[c].cnt) << 1) | self.ch[c2].cnt;
        switch (alg) {
            0 => {
                const b = self.calc(c * 2 + 1, a);
                const d = self.calc(c2 * 2, b);
                return self.calc(c2 * 2 + 1, d);
            },
            1 => {
                const b = self.calc(c * 2 + 1, a);
                return b + self.calc(c2 * 2 + 1, self.calc(c2 * 2, 0));
            },
            2 => {
                const b = self.calc(c * 2 + 1, 0);
                const d = self.calc(c2 * 2, b);
                return a + self.calc(c2 * 2 + 1, d);
            },
            3 => {
                const b = self.calc(c * 2 + 1, 0);
                const d = self.calc(c2 * 2, b);
                return a + d + self.calc(c2 * 2 + 1, 0);
            },
        }
    }

    /// Channels 6-8 in rhythm mode: their outputs into `o`.
    fn rhythmOut(self: *Opl, o: *[3]i32) void {
        // Bass drum: channel 6 (CNT 1: the second operator alone).
        const a = self.first(6);
        const bd = if (self.ch[6].cnt == 0) self.calc(13, a) else self.calc(13, 0);
        o[0] = bd * 2;
        const p13 = (self.ops[14].phase >> 10) & 0x3FF;
        const p17 = (self.ops[17].phase >> 10) & 0x3FF;
        const nz = self.noise & 1;
        const bit = ((((p13 >> 2) ^ (p13 >> 7)) | (p13 >> 3)) | ((p17 >> 5) ^ (p17 >> 3))) & 1;
        const hh_p = (bit << 9) | @as(u32, if (bit ^ nz != 0) 0xD0 else 0x34);
        const sd_p = (((p13 >> 8) & 1) << 9) | ((((p13 >> 8) ^ nz) & 1) << 8);
        const cy_p = (bit << 9) | 0x100;
        const hh = self.calcAt(14, hh_p);
        const sd = self.calcAt(15, sd_p);
        const tom = self.calc(16, 0);
        const cy = self.calcAt(17, cy_p);
        o[1] = (hh + sd) * 2;
        o[2] = (tom + cy) * 2;
    }

    fn sample(self: *Opl) [2]i32 {
        var l: i32 = 0;
        var r: i32 = 0;
        const n: usize = if (self.new) 18 else 9;
        const rhy = self.rhythm & 0x20 != 0;
        var c: usize = 0;
        while (c < n) : (c += 1) {
            if (rhy and c >= 6 and c <= 8) {
                if (c == 6) {
                    var o: [3]i32 = undefined;
                    self.rhythmOut(&o);
                    for (0..3) |k| self.route(6 + k, o[k], &l, &r);
                }
                continue;
            }
            const role = self.fourOp(@intCast(c));
            if (role == 2) continue;
            const v = if (role == 1) self.fourOpOut(c) else self.twoOp(c);
            self.route(c, v, &l, &r);
        }
        return .{ l, r };
    }

    inline fn route(self: *const Opl, c: usize, v: i32, l: *i32, r: *i32) void {
        if (!self.new) {
            l.* += v;
            r.* += v;
            return;
        }
        if (self.ch[c].left) l.* += v;
        if (self.ch[c].right) r.* += v;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

var test_opl: Opl = .{};

fn reg(o: *Opl, a: u9, v: u8) void {
    if (a >= 0x100) o.out8(2, @truncate(a)) else o.out8(0, @truncate(a));
    o.out8(1, v);
}

test "opl: the timer 1 detection sequence" {
    const o = &test_opl;
    o.reset();
    reg(o, 4, 0x60);
    reg(o, 4, 0x80);
    try t.expectEqual(@as(u8, 0), o.in8(0) & 0xE0);
    reg(o, 2, 0xFF);
    reg(o, 4, 0x21);
    o.advance(80);
    try t.expectEqual(@as(u8, 0xC0), o.in8(0) & 0xE0);
    reg(o, 4, 0x60);
    reg(o, 4, 0x80);
    try t.expectEqual(@as(u8, 0), o.in8(0) & 0xE0);
    // The same with a busy-wait on the status port (no time from the
    // machine at all): about 80 reads.
    reg(o, 2, 0xFF);
    reg(o, 4, 0x21);
    var reads: u32 = 0;
    while (o.in8(0) & 0x40 == 0) : (reads += 1) {
        if (reads > 1000) return error.TimerNeverFired;
    }
    try t.expect(reads >= 70 and reads <= 90);
    // OPL3: the status's low bits are clear.
    try t.expectEqual(@as(u8, 0), o.in8(0) & 0x06);
    // Timer 2 at 320 us steps, preset 0xFE: two steps.
    reg(o, 4, 0x80);
    reg(o, 4, 0x00);
    reg(o, 3, 0xFE);
    reg(o, 4, 0x42);
    o.advance(o.ahead + 600);
    try t.expectEqual(@as(u8, 0), o.in8(0) & 0x20);
    o.advance(100);
    try t.expectEqual(@as(u8, 0xA0), o.in8(0) & 0xE0);
}

/// Channel 0 as a plain sine at 440 Hz (block 4, F-num 580).
fn sine440(o: *Opl, rr: u4) void {
    reg(o, 0x20, 0x01);
    reg(o, 0x23, 0x21); // sustained
    reg(o, 0x40, 0x3F); // the modulator silent
    reg(o, 0x43, 0x00);
    reg(o, 0x60, 0xF0);
    reg(o, 0x63, 0xF0);
    reg(o, 0x80, 0x0F);
    reg(o, 0x83, 0x00 | @as(u8, rr));
    reg(o, 0xC0, 0x30);
    reg(o, 0xA0, 580 & 0xFF);
    reg(o, 0xB0, 0x20 | (4 << 2) | (580 >> 8));
}

fn ringAt(o: *const Opl, i: u32) i16 {
    return o.snd.buf[i & 8191][0];
}

test "opl: a note sounds at its pitch and decays after key off" {
    const o = &test_opl;
    o.reset();
    sine440(o, 6);
    o.advance(100_000);
    const n = o.snd.count();
    try t.expectEqual(@as(u32, 4971), n);
    // Rising zero crossings over the last 4000 samples: 440 Hz is one
    // every 113 samples.
    var first: u32 = 0;
    var last: u32 = 0;
    var cross: u32 = 0;
    var peak: i32 = 0;
    var i: u32 = n - 4000;
    while (i < n) : (i += 1) {
        const a = ringAt(o, i - 1);
        const b = ringAt(o, i);
        peak = @max(peak, b);
        if (a < 0 and b >= 0) {
            if (cross == 0) first = i;
            last = i;
            cross += 1;
        }
    }
    try t.expect(cross >= 34);
    const period = @as(f64, @floatFromInt(last - first)) / @as(f64, @floatFromInt(cross - 1));
    try t.expect(@abs(period - 49716.0 / 440.0) < 0.5);
    // Full level at TL 0: close to the chip's 4084.
    try t.expect(peak > 4000 and peak <= 4084);
    // Key off: the release runs it down.
    reg(o, 0xB0, (4 << 2) | (580 >> 8));
    o.snd.clear();
    o.advance(20_000);
    var early: u32 = 0;
    i = 0;
    while (i < o.snd.count()) : (i += 1) early = @max(early, @abs(@as(i32, o.snd.buf[i][0])));
    o.advance(400_000);
    var late: u32 = 0;
    i = 0;
    while (i < 2000) : (i += 1) late = @max(late, @abs(@as(i32, ringAt(o, o.snd.wr -% 2000 +% i))));
    try t.expect(early > 1000);
    try t.expect(late < early / 8);
    // Rate 15: gone at once, and then the chip idles.
    o.reset();
    sine440(o, 15);
    o.advance(20_000);
    reg(o, 0xB0, (4 << 2) | (580 >> 8));
    o.advance(20_000);
    try t.expect(@abs(@as(i32, ringAt(o, o.snd.wr -% 1))) < 8);
    try t.expectEqual(@as(u8, OFF), o.ops[1].state);
}

test "opl: OPL3 stereo, a four-operator voice, rhythm, waveforms" {
    const o = &test_opl;
    o.reset();
    reg(o, 0x105, 0x01);
    sine440(o, 6);
    reg(o, 0xC0, 0x10); // left only
    o.advance(20_000);
    var l: i32 = 0;
    var r: i32 = 0;
    var i: u32 = 0;
    while (i < o.snd.count()) : (i += 1) {
        l = @max(l, o.snd.buf[i][0]);
        r = @max(r, o.snd.buf[i][1]);
    }
    try t.expect(l > 3000);
    try t.expectEqual(@as(i32, 0), r);
    // Waveform 6 (square) on OPL3: the level holds at the top for half
    // a period.
    reg(o, 0xE3, 0x06);
    o.snd.clear();
    o.advance(10_000);
    var flat: u32 = 0;
    i = 1;
    while (i < o.snd.count()) : (i += 1) {
        if (o.snd.buf[i][0] == o.snd.buf[i - 1][0] and o.snd.buf[i][0] > 3000) flat += 1;
    }
    try t.expect(flat > 200);
    // A four-operator voice on channels 0 and 3 (all in series).
    o.reset();
    reg(o, 0x105, 0x01);
    reg(o, 0x104, 0x01);
    for ([_]u8{ 0x00, 0x03, 0x08, 0x0B }) |off| {
        reg(o, 0x20 + @as(u9, off), 0x21);
        reg(o, 0x40 + @as(u9, off), 0x10);
        reg(o, 0x60 + @as(u9, off), 0xF0);
        reg(o, 0x80 + @as(u9, off), 0x05);
    }
    reg(o, 0xC0, 0x30);
    reg(o, 0xC3, 0x30);
    reg(o, 0xA0, 0x44);
    reg(o, 0xB0, 0x20 | (4 << 2) | 1);
    o.advance(20_000);
    try t.expect(o.ops[6].state != OFF); // channel 3's operators keyed by 0
    var e: u64 = 0;
    i = 0;
    while (i < o.snd.count()) : (i += 1) e += @abs(@as(i64, o.snd.buf[i][0]));
    try t.expect(e > 100_000);
    // Rhythm: the bass drum and hi-hat sound.
    o.reset();
    reg(o, 0x30, 0x01);
    reg(o, 0x33, 0x01);
    reg(o, 0x50, 0x3F);
    reg(o, 0x53, 0x00);
    reg(o, 0x70, 0xF6);
    reg(o, 0x73, 0xF6);
    reg(o, 0x31, 0x01);
    reg(o, 0x51, 0x00);
    reg(o, 0x71, 0xF6);
    reg(o, 0xA6, 0x80);
    reg(o, 0xB6, 0x09);
    reg(o, 0xA7, 0x80);
    reg(o, 0xB7, 0x0D);
    reg(o, 0xBD, 0x31);
    o.advance(20_000);
    e = 0;
    i = 0;
    while (i < o.snd.count()) : (i += 1) e += @abs(@as(i64, o.snd.buf[i][0]));
    try t.expect(e > 100_000);
    try t.expect(o.ops[14].state != OFF and o.ops[12].state != OFF);
    // Mixed out at the host's rate.
    var out: [2 * 480]i16 = [_]i16{0} ** 960;
    o.mix(&out, 48000);
    var any: bool = false;
    for (out) |v| any = any or v != 0;
    try t.expect(any);
}

fn monoNs() u64 {
    if (@import("builtin").os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "opl: the cost of 18 voices for a second" {
    const o = &test_opl;
    o.reset();
    reg(o, 0x105, 0x01);
    var c: u32 = 0;
    while (c < 18) : (c += 1) {
        const bank: u9 = if (c >= 9) 0x100 else 0;
        const cc: u9 = @intCast(c % 9);
        const off: u9 = (cc / 3) * 8 + cc % 3;
        reg(o, bank + 0x20 + off, 0xE1); // tremolo, vibrato, sustained
        reg(o, bank + 0x23 + off, 0xE2);
        reg(o, bank + 0x40 + off, 0x18);
        reg(o, bank + 0x43 + off, 0x00);
        reg(o, bank + 0x60 + off, 0xF2);
        reg(o, bank + 0x63 + off, 0xF2);
        reg(o, bank + 0x80 + off, 0x24);
        reg(o, bank + 0x83 + off, 0x24);
        reg(o, bank + 0xE0 + off, 0x01);
        reg(o, bank + 0xC0 + cc, 0x3E);
        reg(o, bank + 0xA0 + cc, @truncate(400 + c * 20));
        reg(o, bank + 0xB0 + cc, 0x20 | (4 << 2) | @as(u8, @truncate((400 + c * 20) >> 8)));
    }
    const t0 = monoNs();
    var k: u32 = 0;
    while (k < 4000) : (k += 1) o.advance(250);
    const ns = monoNs() - t0;
    std.debug.print("\nopl: 18 voices, 1 s of sound in {d} us ({d}.{d:0>2}% of a core)\n", .{ ns / 1000, ns / 10_000_000, (ns / 100_000) % 100 });
}
