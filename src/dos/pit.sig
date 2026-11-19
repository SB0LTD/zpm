//! The 8253/8254 timer at 0x40-0x43 (1.193182 MHz): channel 0 drives
//! IRQ 0 (18.2 Hz from the BIOS, faster when a game reprograms it),
//! channel 2 the PC speaker (gated by port 0x61). Modes 0-5, LSB/MSB
//! access, latches (counter and read-back), the read of a running count.
//!
//! From Intel's 8254 data sheet. Time moves in whole clocks and each
//! counter jumps straight to its next event (no clock-by-clock loop):
//! mode 0 counts to its terminal count once, 1 and 5 wait for the gate's
//! rising edge, 2 is the rate generator (low for the last clock of each
//! period), 3 the square wave (high for ceil(N/2), low for floor(N/2)), 4
//! the strobe. A count of 0 is 65536 (10000 in BCD). Writing a new count
//! during modes 2 and 3 takes effect at the next reload, as on the chip.
//!
//! The speaker is channel 2's output AND port 0x61's bit 1, sampled as it
//! changes: each output sample is the share of its 27 clocks the speaker
//! was high (a box filter at 44.2 kHz), DC-blocked, into a ring the host's
//! audio resamples (sb_ring.sig).

const std = @import("std");
const ring = @import("sb_ring.sig");

pub const HZ: u32 = 1_193_182;

/// Clocks per speaker sample (HZ / 27 = 44192 Hz).
const SPK_CLOCKS: u32 = 27;
pub const SPK_RATE: u32 = HZ / SPK_CLOCKS;
/// The speaker's swing (0 to this, before the DC block).
const SPK_LEVEL: i32 = 12000;
const NEVER: u32 = 0xFFFF_FFFF;

pub const Counter = struct {
    mode: u3 = 0,
    /// 1: LSB only, 2: MSB only, 3: LSB then MSB.
    access: u2 = 3,
    bcd: bool = false,
    /// The count register as written, and the count it means (1-65536).
    cr: u16 = 0,
    n: u32 = 65536,
    /// The counting element (modes 0, 1, 4, 5: the count down, free
    /// running after terminal; 2: 1..n; 3: half-period clocks left).
    ce: u32 = 0,
    out: bool = false,
    gate: bool = true,
    /// A count has been written since the control word.
    loaded: bool = false,
    /// Counting (the first byte of a two-byte count stops mode 0).
    running: bool = false,
    /// Modes 1, 4, 5: the strobe or one-shot still to come.
    armed: bool = false,
    null_count: bool = true,
    wr_msb: bool = false,
    wr_lsb: u8 = 0,
    rd_msb: bool = false,
    latched: bool = false,
    latch: u16 = 0,
    latch_msb: bool = false,
    status_latched: bool = false,
    status: u8 = 0,

    fn modulus(c: *const Counter) u32 {
        return if (c.bcd) 10000 else 65536;
    }
    fn effective(c: *const Counter) u32 {
        var v: u32 = c.cr;
        if (c.bcd) {
            v = (v >> 12 & 0xF) * 1000 + (v >> 8 & 0xF) * 100 + (v >> 4 & 0xF) * 10 + (v & 0xF);
            if (v > 9999) v = 9999;
        }
        return if (v == 0) c.modulus() else v;
    }
    fn hi(n: u32) u32 {
        return (n + 1) / 2;
    }
    fn lo(n: u32) u32 {
        return n / 2;
    }

    fn control(c: *Counter, v: u8) void {
        c.access = @intCast((v >> 4) & 3);
        c.mode = @intCast((v >> 1) & 7);
        if (c.mode >= 6) c.mode -= 4;
        c.bcd = v & 1 != 0;
        c.wr_msb = false;
        c.rd_msb = false;
        c.latched = false;
        c.status_latched = false;
        c.loaded = false;
        c.running = false;
        c.armed = false;
        c.null_count = true;
        c.out = c.mode != 0;
    }

    fn writeCount(c: *Counter, v: u8) void {
        switch (c.access) {
            0 => return,
            1 => c.cr = v,
            2 => c.cr = @as(u16, v) << 8,
            3 => {
                if (!c.wr_msb) {
                    c.wr_lsb = v;
                    c.wr_msb = true;
                    if (c.mode == 0) {
                        c.running = false;
                        c.out = false;
                    }
                    return;
                }
                c.wr_msb = false;
                c.cr = @as(u16, c.wr_lsb) | (@as(u16, v) << 8);
            },
        }
        c.null_count = true;
        c.newCount();
    }

    fn newCount(c: *Counter) void {
        const first = !c.loaded;
        c.loaded = true;
        switch (c.mode) {
            0 => {
                c.n = c.effective();
                c.ce = c.n;
                c.out = false;
                c.running = true;
                c.null_count = false;
            },
            1, 5 => {
                // Waits for the gate's rising edge.
                c.n = c.effective();
            },
            2 => if (first) {
                c.n = c.effective();
                c.ce = c.n;
                c.out = c.n != 1;
                c.running = true;
                c.null_count = false;
            },
            3 => if (first) {
                c.n = c.effective();
                c.ce = hi(c.n);
                c.out = true;
                c.running = true;
                c.null_count = false;
            },
            4 => {
                c.n = c.effective();
                c.ce = c.n;
                c.out = true;
                c.running = true;
                c.armed = true;
                c.null_count = false;
            },
            else => {},
        }
    }

    fn setGate(c: *Counter, g: bool) void {
        const rising = g and !c.gate;
        c.gate = g;
        if (!c.loaded) return;
        switch (c.mode) {
            1 => if (rising) {
                c.n = c.effective();
                c.ce = c.n;
                c.out = false;
                c.running = true;
                c.armed = true;
                c.null_count = false;
            },
            5 => if (rising) {
                c.n = c.effective();
                c.ce = c.n;
                c.out = true;
                c.running = true;
                c.armed = true;
                c.null_count = false;
            },
            2 => if (!g) {
                c.out = true;
            } else if (rising) {
                c.n = c.effective();
                c.ce = c.n;
                c.out = c.n != 1;
                c.null_count = false;
            },
            3 => if (!g) {
                c.out = true;
            } else if (rising) {
                c.n = c.effective();
                c.ce = hi(c.n);
                c.out = true;
                c.null_count = false;
            },
            else => {},
        }
    }

    /// Counting at all: loaded, running, and the gate lets it.
    fn counts(c: *const Counter) bool {
        if (!c.running) return false;
        return switch (c.mode) {
            1, 5 => true,
            else => c.gate,
        };
    }

    /// Clocks until the output next rises.
    fn untilRise(c: *const Counter) u32 {
        if (!c.counts()) return NEVER;
        return switch (c.mode) {
            0, 1 => if (!c.out) c.ce else NEVER,
            2 => c.ce,
            3 => if (c.out) c.ce + lo(c.effectiveNext()) else c.ce,
            4, 5 => if (!c.armed) NEVER else if (c.out) c.ce + 1 else 1,
            else => NEVER,
        };
    }
    fn effectiveNext(c: *const Counter) u32 {
        return if (c.null_count) c.effective() else c.n;
    }

    /// Clocks until the output next changes either way.
    fn untilChange(c: *const Counter) u32 {
        if (!c.counts()) return NEVER;
        return switch (c.mode) {
            0, 1 => if (!c.out) c.ce else NEVER,
            2 => if (c.ce > 1) c.ce - 1 else 1,
            3 => if (c.ce == 0) 1 else c.ce,
            4, 5 => if (!c.armed) NEVER else if (c.out) @max(c.ce, 1) else 1,
            else => NEVER,
        };
    }

    fn freeRun(c: *Counter, clocks: u32) void {
        const m = c.modulus();
        c.ce = @intCast((@as(u64, c.ce) + m - (clocks % m)) % m);
    }

    /// `clocks` go by; how many times the output rose.
    fn step(c: *Counter, clocks: u32) u32 {
        if (clocks == 0 or !c.counts()) return 0;
        switch (c.mode) {
            0, 1 => {
                if (!c.out) {
                    if (clocks < c.ce) {
                        c.ce -= clocks;
                        return 0;
                    }
                    const left = clocks - c.ce;
                    c.ce = 0;
                    c.out = true;
                    c.armed = false;
                    c.freeRun(left);
                    return 1;
                }
                c.freeRun(clocks);
                return 0;
            },
            2 => {
                if (clocks < c.ce) {
                    c.ce -= clocks;
                    c.out = c.ce != 1;
                    return 0;
                }
                const left = clocks - c.ce;
                // The reload takes the count register as it is now.
                c.n = c.effective();
                c.null_count = false;
                c.ce = c.n - left % c.n;
                c.out = c.ce != 1;
                return 1 + left / c.n;
            },
            3 => {
                var left = clocks;
                var rises: u32 = 0;
                while (true) {
                    if (left < c.ce) {
                        c.ce -= left;
                        return rises;
                    }
                    left -= c.ce;
                    c.n = c.effective();
                    c.null_count = false;
                    if (c.out) {
                        c.out = false;
                        c.ce = lo(c.n);
                        if (c.ce != 0) continue;
                    }
                    c.out = true;
                    c.ce = hi(c.n);
                    rises += 1;
                    if (left >= c.n) {
                        rises += left / c.n;
                        left %= c.n;
                    }
                }
            },
            4, 5 => {
                if (!c.armed) {
                    c.freeRun(clocks);
                    return 0;
                }
                var left = clocks;
                if (c.out) {
                    if (left < c.ce) {
                        c.ce -= left;
                        return 0;
                    }
                    left -= c.ce;
                    c.ce = 0;
                    c.out = false;
                    if (left == 0) return 0;
                }
                // The strobe's one low clock ends.
                c.out = true;
                c.armed = false;
                c.freeRun(left);
                return 1;
            },
            else => return 0,
        }
    }

    /// The counting element as a read sees it.
    fn current(c: *const Counter) u16 {
        var v: u32 = c.ce;
        if (c.mode == 3) {
            v = if (c.n & 1 == 0 or !c.out) 2 * c.ce else if (c.ce > 0) 2 * (c.ce - 1) else 0;
        }
        if (!c.loaded) v = 0;
        v %= c.modulus();
        if (c.bcd) {
            return @intCast((v / 1000) << 12 | ((v / 100) % 10) << 8 | ((v / 10) % 10) << 4 | (v % 10));
        }
        return @intCast(v);
    }

    fn latchCount(c: *Counter) void {
        if (c.latched) return;
        c.latch = c.current();
        c.latched = true;
        c.latch_msb = false;
    }
    fn latchStatus(c: *Counter) void {
        if (c.status_latched) return;
        c.status = (@as(u8, @intFromBool(c.out)) << 7) | (@as(u8, @intFromBool(c.null_count)) << 6) |
            (@as(u8, c.access) << 4) | (@as(u8, c.mode) << 1) | @intFromBool(c.bcd);
        c.status_latched = true;
    }

    fn read(c: *Counter) u8 {
        if (c.status_latched) {
            c.status_latched = false;
            return c.status;
        }
        const v = if (c.latched) c.latch else c.current();
        switch (c.access) {
            1 => {
                c.latched = false;
                return @truncate(v);
            },
            2 => {
                c.latched = false;
                return @truncate(v >> 8);
            },
            else => {
                if (c.latched) {
                    if (!c.latch_msb) {
                        c.latch_msb = true;
                        return @truncate(v);
                    }
                    c.latched = false;
                    c.latch_msb = false;
                    return @truncate(v >> 8);
                }
                c.rd_msb = !c.rd_msb;
                return if (c.rd_msb) @truncate(v) else @truncate(v >> 8);
            },
        }
    }
};

pub const Pit = struct {
    ch: [3]Counter = .{ .{}, .{}, .{} },
    /// Port 0x61's low bits as written (gate 2, speaker data, parity
    /// and I/O check enables).
    p61: u8 = 0,
    /// Clocks gone by, and reads of 0x61 (each counts as a bus cycle,
    /// so a loop waiting on the refresh bit ends).
    clock: u64 = 0,
    reads61: u32 = 0,
    /// The speaker: clocks into the current sample, high clocks in it,
    /// the DC block's state, and the samples.
    spk_pos: u32 = 0,
    spk_high: u32 = 0,
    hp_x: i32 = 0,
    hp_y: i32 = 0,
    spk: ring.Ring(4096) = .{},

    pub fn reset(self: *Pit) void {
        self.* = .{};
        // The BIOS: channel 0 mode 3 at 65536 (18.2 Hz), channel 1 the
        // refresh (mode 2, 18), channel 2 mode 3 with its gate off.
        self.out8(0x43, 0x36);
        self.out8(0x40, 0);
        self.out8(0x40, 0);
        self.out8(0x43, 0x54);
        self.out8(0x41, 18);
        self.ch[2].gate = false;
        self.out8(0x43, 0xB6);
        self.out8(0x42, 0x33);
        self.out8(0x42, 0x05);
    }

    /// Time goes on by `clocks` of 1.193182 MHz; how many times channel
    /// 0's output rose (IRQ 0 edges) in that time.
    pub fn advance(self: *Pit, clocks: u32) u32 {
        self.clock += clocks;
        const rises = self.ch[0].step(clocks);
        _ = self.ch[1].step(clocks);
        self.runSpeaker(clocks);
        return rises;
    }

    fn runSpeaker(self: *Pit, clocks: u32) void {
        const c2 = &self.ch[2];
        const data = self.p61 & 2 != 0;
        var left = clocks;
        while (left > 0) {
            var d = @min(left, SPK_CLOCKS - self.spk_pos);
            if (data) d = @min(d, c2.untilChange());
            if (data and c2.out) self.spk_high += d;
            _ = c2.step(d);
            left -= d;
            self.spk_pos += d;
            if (self.spk_pos == SPK_CLOCKS) {
                const x: i32 = @intCast(self.spk_high * @as(u32, SPK_LEVEL) / SPK_CLOCKS);
                // DC block (about 25 Hz).
                self.hp_y = x - self.hp_x + ((self.hp_y * 32580) >> 15);
                self.hp_x = x;
                const s = ring.sat16(self.hp_y);
                self.spk.push(s, s);
                self.spk_pos = 0;
                self.spk_high = 0;
            }
        }
    }

    /// Clocks until channel 0's next rising edge (the machine sizes its
    /// CPU slices by it).
    pub fn untilIrq(self: *const Pit) u32 {
        const u = self.ch[0].untilRise();
        return if (u == NEVER) HZ / 18 else u;
    }

    pub fn in8(self: *Pit, port: u16) u8 {
        const i = port & 3;
        if (i == 3) return 0xFF;
        return self.ch[i].read();
    }
    pub fn out8(self: *Pit, port: u16, v: u8) void {
        const i = port & 3;
        if (i != 3) return self.ch[i].writeCount(v);
        const sc = v >> 6;
        if (sc == 3) {
            // Read-back: bit 5 clear latches counts, bit 4 clear statuses.
            var k: u2 = 0;
            while (k < 3) : (k += 1) {
                if (v & (@as(u8, 2) << k) == 0) continue;
                if (v & 0x10 == 0) self.ch[k].latchStatus();
                if (v & 0x20 == 0) self.ch[k].latchCount();
            }
            return;
        }
        if ((v >> 4) & 3 == 0) return self.ch[sc].latchCount();
        self.ch[sc].control(v);
    }

    /// Port 0x61: speaker data (bit 1) and channel 2's gate (bit 0) in;
    /// channel 2's output (bit 5) and the refresh toggle (bit 4) out.
    pub fn in61(self: *Pit) u8 {
        self.reads61 +%= 1;
        // The refresh request toggles every 15 us (18 clocks).
        const refresh = ((self.clock + self.reads61) / 18) & 1;
        return (self.p61 & 0x0F) | (@as(u8, @intCast(refresh)) << 4) | (@as(u8, @intFromBool(self.ch[2].out)) << 5);
    }
    pub fn out61(self: *Pit, v: u8) void {
        self.p61 = v & 0x0F;
        self.ch[2].setGate(v & 1 != 0);
    }
    /// The PC speaker's sound, added into `out` (stereo i16 at `rate`).
    pub fn speaker(self: *Pit, out: []i16, rate: u32) void {
        self.spk.mixInto(out, rate, SPK_RATE, ring.UNITY, ring.UNITY);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

fn setCh0(p: *Pit, mode: u3, n: u16) void {
    p.out8(0x43, 0x30 | (@as(u8, mode) << 1));
    p.out8(0x40, @truncate(n));
    p.out8(0x40, @truncate(n >> 8));
}

test "pit: IRQ 0 edges at divisor 0 and at 1193 (1 kHz), mode 2 and 3" {
    var p: Pit = .{};
    p.reset();
    // Divisor 0: 65536 clocks per edge; one second is 18 edges and a bit.
    var total: u32 = 0;
    var k: u32 = 0;
    while (k < 4000) : (k += 1) total += p.advance(298);
    try t.expectEqual(@as(u32, 4000 * 298 / 65536), total);
    try t.expectEqual(@as(u32, 65536 - (4000 * 298) % 65536), p.untilIrq());
    // 1193 in mode 2: exactly one edge per 1193 clocks, slice by slice.
    setCh0(&p, 2, 1193);
    total = 0;
    var clocks: u32 = 0;
    k = 0;
    while (k < 4000) : (k += 1) {
        const c: u32 = 298 + (k & 1);
        clocks += c;
        total += p.advance(c);
    }
    try t.expectEqual(clocks / 1193, total);
    try t.expectEqual(1193 - clocks % 1193, p.untilIrq());
    // Mode 3 at 1193 (odd): high 597, low 596; one rise per period.
    setCh0(&p, 3, 1193);
    try t.expectEqual(@as(u32, 1193), p.untilIrq());
    try t.expectEqual(@as(u32, 0), p.advance(596));
    try t.expect(p.ch[0].out);
    try t.expectEqual(@as(u32, 0), p.advance(1));
    try t.expect(!p.ch[0].out);
    try t.expectEqual(@as(u32, 596), p.untilIrq());
    try t.expectEqual(@as(u32, 1), p.advance(596));
    try t.expect(p.ch[0].out);
    try t.expectEqual(@as(u32, 10), p.advance(1193 * 10));
    // One huge step at divisor 2.
    setCh0(&p, 3, 2);
    try t.expectEqual(@as(u32, 500_000), p.advance(1_000_000));
}

test "pit: mode 0 counts once, latches and read-back" {
    var p: Pit = .{};
    p.reset();
    setCh0(&p, 0, 1000);
    try t.expect(!p.ch[0].out);
    try t.expectEqual(@as(u32, 0), p.advance(999));
    try t.expectEqual(@as(u32, 1), p.advance(1));
    try t.expect(p.ch[0].out);
    try t.expectEqual(@as(u32, 0), p.advance(100_000));
    // Counter latch: the count holds while time goes on.
    setCh0(&p, 2, 5000);
    _ = p.advance(1000);
    p.out8(0x43, 0x00);
    _ = p.advance(500);
    try t.expectEqual(@as(u8, 0xA0), p.in8(0x40)); // 4000 = 0x0FA0
    try t.expectEqual(@as(u8, 0x0F), p.in8(0x40));
    // Live reads go LSB, MSB.
    const lsb = p.in8(0x40);
    const msb = p.in8(0x40);
    try t.expectEqual(@as(u16, 3500), @as(u16, lsb) | (@as(u16, msb) << 8));
    // Read-back of channel 0's status and count.
    p.out8(0x43, 0xC2);
    const st = p.in8(0x40);
    try t.expectEqual(@as(u8, 0x34), st & 0x3F); // LSB/MSB, mode 2, binary
    try t.expect(st & 0x80 != 0); // OUT high
    try t.expectEqual(@as(u8, 0xAC), p.in8(0x40)); // 3500 = 0x0DAC
    try t.expectEqual(@as(u8, 0x0D), p.in8(0x40));
    // Mode 3 reads count down by two.
    setCh0(&p, 3, 1000);
    _ = p.advance(100);
    p.out8(0x43, 0x00);
    const a = @as(u16, p.in8(0x40)) | (@as(u16, p.in8(0x40)) << 8);
    try t.expectEqual(@as(u16, 800), a);
    // A new count in mode 2 waits for the reload.
    setCh0(&p, 2, 100);
    _ = p.advance(10);
    p.out8(0x40, 50);
    p.out8(0x40, 0);
    try t.expectEqual(@as(u32, 90), p.untilIrq());
    _ = p.advance(90);
    try t.expectEqual(@as(u32, 50), p.untilIrq());
}

test "pit: channel 2's gate, port 0x61 and the speaker" {
    var p: Pit = .{};
    p.reset();
    // 1 kHz tone on channel 2.
    p.out8(0x43, 0xB6);
    p.out8(0x42, @truncate(1193));
    p.out8(0x42, 1193 >> 8);
    try t.expectEqual(@as(u32, 0), p.ch[2].step(5000)); // gate off: still
    p.out61(0x03);
    try t.expect(p.in61() & 0x03 == 0x03);
    var k: u32 = 0;
    while (k < 400) : (k += 1) _ = p.advance(298);
    var out: [2 * 4410]i16 = [_]i16{0} ** (2 * 4410);
    p.speaker(&out, 44100);
    // A square wave around zero: about 1000 Hz, so about 100 sign flips
    // in a tenth of a second.
    var flips: u32 = 0;
    var i: usize = 2;
    var lo: i32 = 0;
    var hi_: i32 = 0;
    while (i < 4410) : (i += 1) {
        const a = out[i * 2];
        const b = out[i * 2 - 2];
        if ((a >= 0) != (b >= 0)) flips += 1;
        lo = @min(lo, a);
        hi_ = @max(hi_, a);
    }
    try t.expect(flips > 180 and flips < 220);
    try t.expect(hi_ > 3000 and lo < -3000);
    // Gate off forces OUT high; bit 5 shows it.
    p.out61(0x02);
    try t.expect(p.in61() & 0x20 != 0);
    // Speaker off: silence (after the ring drains and the DC fades).
    p.out61(0x00);
    k = 0;
    while (k < 4000) : (k += 1) _ = p.advance(298);
    var quiet: [2 * 1000]i16 = [_]i16{0} ** 2000;
    p.speaker(&quiet, 44100);
    p.speaker(&quiet, 44100);
    @memset(&quiet, 0);
    p.speaker(&quiet, 44100);
    try t.expect(@abs(quiet[1998]) < 50);
}
