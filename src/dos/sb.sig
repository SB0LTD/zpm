//! A Sound Blaster 16 at 0x220, IRQ 5 (or 7), DMA 1 and 5, as BLASTER=
//! A220 I5 D1 H5 T6 says: the DSP (reset, version 4.05, direct output,
//! single-cycle and auto-initialize 8- and 16-bit DMA output, pause and
//! resume, the speaker, time constant and sample rate, ADPCM where
//! asked), its interrupt acknowledge ports, the CT1745 mixer's volumes.
//! Its FM part (0x220-0x223, 0x228-0x229) is the OPL3 (opl.sig).
//!
//! From Creative's Sound Blaster Series Hardware Programming Guide: the
//! reset handshake (1 then 0 to 0x226, AAh to read at 0x22A once 0x22E's
//! bit 7 says so), commands and their data through 0x22C, the DMA
//! commands (14h/1Ch/90h/91h, Bxh/Cxh with their mode byte, 48h's block
//! size, 40h-42h's rate), the pause, continue and exit commands, and the
//! acknowledges (reading 0x22E for 8-bit, 0x22F for 16-bit). The DSP pulls
//! its DMA as emulated time goes on, at its sample rate, into a ring the
//! host's audio resamples; the IRQ comes when a block's count runs out.
//! The ADPCM commands decode with a simple adaptive scheme in the
//! card's spirit (2, 2.6 and 4 bits a sample), not Creative's exact one.
//! Direct output (10h) plays the bytes at the rate a program writes them.

const std = @import("std");
const Memory = @import("mem.sig").Memory;
const Dma = @import("dma.sig").Dma;
const ring = @import("sb_ring.sig");

pub const BASE: u16 = 0x220;
pub const IRQ: u4 = 5;
pub const DMA8: u3 = 1;
pub const DMA16: u3 = 5;

const COPYRIGHT = "COPYRIGHT (C) CREATIVE TECHNOLOGY LTD, 1992.";

/// Q12 gains for 0-62 dB of attenuation in 2 dB steps (and silence past).
const GAIN = blk: {
    var g: [64]i32 = undefined;
    for (&g, 0..) |*x, i| {
        const db: f64 = @as(f64, @floatFromInt(i)) * 2.0;
        x.* = if (i == 63) 0 else @intFromFloat(@round(4096.0 * @exp2(-db / 6.0205999)));
    }
    break :blk g;
};

const Xfer = struct {
    active: bool = false,
    wide: bool = false,
    stereo: bool = false,
    signed: bool = false,
    auto: bool = false,
    input: bool = false,
    silence: bool = false,
    /// 0: PCM; 2, 3, 4: ADPCM bits a sample.
    adpcm: u3 = 0,
    adpcm_ref: bool = false,
    /// A legacy 8-bit command (14h, 1Ch, 90h, 91h): stereo from the
    /// mixer's 0Eh, the time constant's rate shared by both sides.
    legacy: bool = false,
    paused: bool = false,
    exit_auto: bool = false,
    /// The block's length and what is left of it (bytes or words).
    count: u32 = 0,
    left: u32 = 0,
};

pub const SoundBlaster = struct {
    // The DSP.
    reset_hi: bool = false,
    outq: [64]u8 = undefined,
    out_head: u8 = 0,
    out_len: u8 = 0,
    last_out: u8 = 0xAA,
    cmd: u8 = 0,
    need: u8 = 0,
    argc: u8 = 0,
    args: [3]u8 = .{ 0, 0, 0 },
    tc: u8 = 0xD2,
    /// The sample rate (frames a second; 40h's rate is both sides').
    rate: u32 = 22050,
    rate_from_tc: bool = false,
    block: u32 = 0x800,
    speaker_on: bool = false,
    test_reg: u8 = 0,
    x: Xfer = .{},
    pending8: bool = false,
    pending16: bool = false,
    edge: bool = false,
    /// Time not yet spent on samples (rate * us units).
    acc: u64 = 0,
    /// The frame being put together (stereo's left side).
    half: i16 = 0,
    have_half: bool = false,
    // ADPCM.
    ad_ref: i32 = 128,
    ad_step: u3 = 0,
    ad_acc: u32 = 0,
    // Direct output: bytes written in this slice, the rate they come at.
    dac: [512]u8 = undefined,
    dac_n: u32 = 0,
    dac_rate: u32 = 0,
    // What the host hears.
    snd: ring.Ring(8192) = .{},
    snd_rate: u32 = 22050,
    // The mixer.
    mix_index: u8 = 0,
    mixer: [256]u8 = [_]u8{0} ** 256,

    pub fn reset(self: *SoundBlaster) void {
        self.* = .{};
        self.mixerReset();
        self.mixer[0x80] = 0x02; // IRQ 5
        self.mixer[0x81] = 0x22; // DMA 1 and 5
    }

    // ── The DSP's ports ──────────────────────────────────────────────────

    fn put(self: *SoundBlaster, v: u8) void {
        if (self.out_len == self.outq.len) return;
        self.outq[(self.out_head + self.out_len) % self.outq.len] = v;
        self.out_len += 1;
    }
    fn take(self: *SoundBlaster) u8 {
        if (self.out_len == 0) return self.last_out;
        const v = self.outq[self.out_head];
        self.out_head = @intCast((self.out_head + 1) % self.outq.len);
        self.out_len -= 1;
        self.last_out = v;
        return v;
    }

    fn dspReset(self: *SoundBlaster) void {
        self.x = .{};
        self.out_len = 0;
        self.out_head = 0;
        self.need = 0;
        self.argc = 0;
        self.cmd = 0;
        self.pending8 = false;
        self.pending16 = false;
        self.speaker_on = false;
        self.have_half = false;
        self.block = 0x800;
        // The card answers within about 100 us; here at once.
        self.put(0xAA);
    }

    fn irq(self: *SoundBlaster, wide: bool) void {
        if (!self.pending8 and !self.pending16) self.edge = true;
        if (wide) self.pending16 = true else self.pending8 = true;
    }

    pub fn in8(self: *SoundBlaster, port: u16) u8 {
        return switch ((port -% BASE) & 0xF) {
            0x4 => self.mix_index,
            0x5 => self.mixerRead(self.mix_index),
            0xA => self.take(),
            0xC => 0x7F, // (never busy)
            0xE => blk: {
                self.pending8 = false;
                break :blk if (self.out_len > 0) 0xFF else 0x7F;
            },
            0xF => blk: {
                self.pending16 = false;
                break :blk if (self.out_len > 0) 0xFF else 0x7F;
            },
            else => 0xFF,
        };
    }
    pub fn out8(self: *SoundBlaster, port: u16, v: u8) void {
        switch ((port -% BASE) & 0xF) {
            0x4 => self.mix_index = v,
            0x5 => self.mixerWrite(self.mix_index, v),
            0x6 => {
                if (v & 1 != 0) {
                    self.reset_hi = true;
                } else if (self.reset_hi) {
                    self.reset_hi = false;
                    self.dspReset();
                }
            },
            0xC => self.dspWrite(v),
            else => {},
        }
    }

    fn argCount(c: u8) u8 {
        return switch (c) {
            0x0F, 0x10, 0x38, 0x40, 0xE0, 0xE2, 0xE4, 0xF9 => 1,
            0x05, 0x0E, 0x14, 0x15, 0x16, 0x17, 0x24, 0x41, 0x42, 0x48, 0x74, 0x75, 0x76, 0x77, 0x80 => 2,
            0xB0...0xCF => 3,
            else => 0,
        };
    }

    fn dspWrite(self: *SoundBlaster, v: u8) void {
        if (self.need > 0) {
            self.args[self.argc] = v;
            self.argc += 1;
            if (self.argc < self.need) return;
            self.need = 0;
            self.run(self.cmd);
            return;
        }
        self.cmd = v;
        self.argc = 0;
        self.need = argCount(v);
        if (self.need == 0) self.run(v);
    }

    fn len16(self: *const SoundBlaster, i: usize) u32 {
        return (@as(u32, self.args[i]) | (@as(u32, self.args[i + 1]) << 8)) + 1;
    }

    fn start(self: *SoundBlaster, x: Xfer) void {
        self.x = x;
        self.x.active = true;
        self.x.left = x.count;
        self.have_half = false;
        self.ad_acc = 0;
        if (x.adpcm != 0 and x.adpcm_ref) self.ad_step = 0;
    }

    fn run(self: *SoundBlaster, c: u8) void {
        const a = self.args;
        switch (c) {
            0x10 => {
                if (self.dac_n < self.dac.len) {
                    self.dac[self.dac_n] = a[0];
                    self.dac_n += 1;
                }
            },
            0x14, 0x91 => self.start(.{ .legacy = true, .count = if (c == 0x14) self.len16(0) else self.block }),
            0x1C, 0x90 => self.start(.{ .legacy = true, .auto = true, .count = self.block }),
            0x24 => self.start(.{ .legacy = true, .input = true, .count = self.len16(0) }),
            0x2C, 0x98 => self.start(.{ .legacy = true, .input = true, .auto = true, .count = self.block }),
            0x99 => self.start(.{ .legacy = true, .input = true, .count = self.block }),
            0x16, 0x17 => self.start(.{ .adpcm = 2, .adpcm_ref = c == 0x17, .count = self.len16(0) }),
            0x76, 0x77 => self.start(.{ .adpcm = 3, .adpcm_ref = c == 0x77, .count = self.len16(0) }),
            0x74, 0x75 => self.start(.{ .adpcm = 4, .adpcm_ref = c == 0x75, .count = self.len16(0) }),
            0x1F => self.start(.{ .adpcm = 2, .adpcm_ref = true, .auto = true, .count = self.block }),
            0x7F => self.start(.{ .adpcm = 3, .adpcm_ref = true, .auto = true, .count = self.block }),
            0x7D => self.start(.{ .adpcm = 4, .adpcm_ref = true, .auto = true, .count = self.block }),
            0x20 => self.put(0x80),
            0x40 => {
                self.tc = a[0];
                self.rate = 1_000_000 / (256 - @as(u32, a[0]));
                self.rate_from_tc = true;
            },
            0x41, 0x42 => {
                const r = (@as(u32, a[0]) << 8) | a[1];
                self.rate = std.math.clamp(r, 4000, 48000);
                self.rate_from_tc = false;
            },
            0x48 => self.block = self.len16(0),
            0x80 => self.start(.{ .silence = true, .count = self.len16(0) }),
            0xB0...0xCF => self.start(.{
                .wide = c < 0xC0,
                .input = c & 0x08 != 0,
                .auto = c & 0x04 != 0,
                .stereo = a[0] & 0x20 != 0,
                .signed = a[0] & 0x10 != 0,
                .count = self.len16(1),
            }),
            0xD0, 0xD5 => self.x.paused = true,
            0xD4, 0xD6 => self.x.paused = false,
            0xD1 => self.speaker_on = true,
            0xD3 => self.speaker_on = false,
            0xD8 => self.put(if (self.speaker_on) 0xFF else 0x00),
            0xD9, 0xDA => self.x.exit_auto = true,
            0xE0 => self.put(~a[0]),
            0xE1 => {
                self.put(4);
                self.put(5);
            },
            0xE3 => {
                for (COPYRIGHT) |ch| self.put(ch);
                self.put(0);
            },
            0xE4 => self.test_reg = a[0],
            0xE8 => self.put(self.test_reg),
            0xF2 => self.irq(false),
            0xF3 => self.irq(true),
            0x0F, 0xF8, 0xF9, 0xFB, 0xFC, 0xFD => self.put(0),
            else => {},
        }
    }

    // ── Time ─────────────────────────────────────────────────────────────

    /// The sample rate the transfer runs at, in frames a second.
    fn frameRate(self: *const SoundBlaster) u32 {
        if (self.x.legacy and self.rate_from_tc and self.stereoLegacy()) return @max(self.rate / 2, 1);
        return @max(self.rate, 1);
    }
    fn stereoLegacy(self: *const SoundBlaster) bool {
        return self.mixer[0x0E] & 0x02 != 0;
    }

    /// Emulated time goes on by `us` microseconds: the DSP pulls its DMA
    /// at its sample rate into its own ring; true when it wants IRQ 5
    /// (a block finished).
    pub fn advance(self: *SoundBlaster, dma: *Dma, mem: *Memory, us: u32) bool {
        self.directOut(us);
        if (self.x.active and !self.x.paused) self.pull(dma, mem, us) else self.acc = 0;
        const e = self.edge;
        self.edge = false;
        return e;
    }

    fn directOut(self: *SoundBlaster, us: u32) void {
        if (self.dac_n == 0) return;
        const r: u32 = @intCast(@as(u64, self.dac_n) * 1_000_000 / @max(us, 1));
        self.dac_rate = if (self.dac_rate == 0) r else (self.dac_rate * 7 + r) / 8;
        if (!self.x.active) {
            self.snd_rate = std.math.clamp(self.dac_rate, 1000, 48000);
            for (self.dac[0..self.dac_n]) |b| {
                const s: i16 = @as(i16, @as(i8, @bitCast(b ^ 0x80))) << 8;
                self.snd.push(s, s);
            }
        }
        self.dac_n = 0;
    }

    fn pull(self: *SoundBlaster, dma: *Dma, mem: *Memory, us: u32) void {
        const fr = self.frameRate();
        self.snd_rate = fr;
        self.acc += @as(u64, fr) * us;
        const frames: u32 = @intCast(self.acc / 1_000_000);
        self.acc %= 1_000_000;
        const x = &self.x;
        const stereo = if (x.legacy) self.stereoLegacy() else x.stereo;
        const ch: u3 = if (x.wide) DMA16 else DMA8;
        const ubytes: u32 = if (x.wide) 2 else 1;
        // Units (bytes or words) due in this time.
        var units: u32 = frames * (if (stereo and x.adpcm == 0) @as(u32, 2) else 1);
        if (x.adpcm != 0) {
            const per: u32 = if (x.adpcm == 3) 3 else 8 / @as(u32, x.adpcm);
            self.ad_acc += frames;
            units = self.ad_acc / per;
            self.ad_acc %= per;
        }
        var buf: [512]u8 = undefined;
        while (units > 0 and x.active) {
            const want = @min(units, x.left, @as(u32, buf.len) / ubytes);
            var got: u32 = 0;
            if (x.silence) {
                var k: u32 = 0;
                while (k < want) : (k += 1) self.snd.push(0, 0);
                got = want;
            } else if (x.input) {
                const fill: u8 = if (x.signed) 0x00 else 0x80;
                @memset(buf[0 .. want * ubytes], 0);
                if (!x.wide) @memset(buf[0..want], fill) else if (!x.signed) {
                    var k: u32 = 0;
                    while (k < want) : (k += 1) buf[k * 2 + 1] = 0x80;
                }
                got = @intCast(dma.write(mem, ch, buf[0 .. want * ubytes]).n / ubytes);
            } else {
                got = @intCast(dma.read(mem, ch, buf[0 .. want * ubytes]).n / ubytes);
                self.decode(buf[0 .. got * ubytes], stereo);
            }
            if (got == 0) break; // the DMA is masked: the DSP waits
            units -= got;
            x.left -= got;
            if (x.left == 0) {
                self.irq(x.wide);
                if (x.auto and !x.exit_auto) {
                    x.left = x.count;
                } else {
                    x.active = false;
                }
            }
        }
    }

    fn emit(self: *SoundBlaster, s: i16, stereo: bool) void {
        if (!stereo) return self.snd.push(s, s);
        if (!self.have_half) {
            self.half = s;
            self.have_half = true;
            return;
        }
        self.have_half = false;
        self.snd.push(self.half, s);
    }

    fn decode(self: *SoundBlaster, b: []const u8, stereo: bool) void {
        const x = &self.x;
        if (x.adpcm != 0) {
            for (b) |byte| self.adpcmByte(byte);
            return;
        }
        if (x.wide) {
            var i: usize = 0;
            while (i + 1 < b.len) : (i += 2) {
                var w = @as(u16, b[i]) | (@as(u16, b[i + 1]) << 8);
                if (!x.signed) w ^= 0x8000;
                self.emit(@bitCast(w), stereo);
            }
            return;
        }
        for (b) |byte| {
            const v: u8 = if (x.signed) byte else byte ^ 0x80;
            self.emit(@as(i16, @as(i8, @bitCast(v))) << 8, stereo);
        }
    }

    /// One ADPCM byte: the reference first if the command asked for one,
    /// then 2, 3 or 4 samples (high bits first), each a sign and a
    /// magnitude scaled by a step that grows on big changes and shrinks on
    /// small ones.
    fn adpcmByte(self: *SoundBlaster, byte: u8) void {
        if (self.x.adpcm_ref) {
            self.x.adpcm_ref = false;
            self.ad_ref = byte;
            self.ad_step = 0;
            const s: i16 = @as(i16, @as(i8, @bitCast(byte ^ 0x80))) << 8;
            self.snd.push(s, s);
            return;
        }
        const bits: u3 = self.x.adpcm;
        // (2.6 bits: two 3-bit codes, then a 2-bit one read as 3 bits)
        const n: u32 = if (bits == 3) 3 else 8 / @as(u32, bits);
        const top: u3 = if (bits == 4) 3 else if (bits == 3) 4 else 5;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const code: u8 = if (bits == 3 and k == 2)
                (byte & 3) << 1
            else
                (byte >> @intCast(8 - @as(u32, bits) * (k + 1))) & ((@as(u8, 1) << bits) - 1);
            const sign = code >> (bits - 1) != 0;
            const mag: i32 = code & ((@as(u8, 1) << (bits - 1)) - 1);
            const maxmag: i32 = (@as(i32, 1) << (bits - 1)) - 1;
            const delta = ((mag << 1) | 1) << self.ad_step >> 1;
            self.ad_ref = std.math.clamp(if (sign) self.ad_ref - delta else self.ad_ref + delta, 0, 255);
            if (mag >= maxmag and self.ad_step < top) self.ad_step += 1;
            if (mag == 0 and self.ad_step > 0) self.ad_step -= 1;
            const s: i16 = @intCast((self.ad_ref - 128) << 8);
            self.snd.push(s, s);
        }
    }

    // ── The host's side ──────────────────────────────────────────────────

    fn vol(self: *const SoundBlaster, master: u8, part: u8) i32 {
        const m = @as(u32, self.mixer[master] >> 3);
        const p = @as(u32, self.mixer[part] >> 3);
        if (m == 0 or p == 0) return 0;
        // 2 dB a step; the reset levels (24 and 24) are the card's full
        // output, so turning up past them does not clip.
        const att = 2 * (31 - m) + 2 * (31 - p);
        const steps = if (att <= 28) 0 else (att - 28) / 2;
        return GAIN[@min(steps, 63)];
    }

    /// The card's digital sound, added into `out` (interleaved stereo i16
    /// at `rate`), through the mixer's volumes.
    pub fn mix(self: *SoundBlaster, out: []i16, rate: u32) void {
        self.snd.mixInto(out, rate, self.snd_rate, self.vol(0x30, 0x32), self.vol(0x31, 0x33));
    }
    /// The mixer's FM volume (master times FM), Q12 left and right, for
    /// the OPL's output.
    pub fn fmGain(self: *const SoundBlaster) [2]i32 {
        return .{ self.vol(0x30, 0x34), self.vol(0x31, 0x35) };
    }

    // ── The CT1745 mixer ─────────────────────────────────────────────────

    fn mixerReset(self: *SoundBlaster) void {
        const keep80 = self.mixer[0x80];
        const keep81 = self.mixer[0x81];
        @memset(&self.mixer, 0);
        var r: usize = 0x30;
        while (r <= 0x35) : (r += 1) self.mixer[r] = 0xC0;
        self.mixer[0x3C] = 0x1F;
        self.mixer[0x3D] = 0x15;
        self.mixer[0x3E] = 0x0B;
        self.mixer[0x44] = 0x80;
        self.mixer[0x45] = 0x80;
        self.mixer[0x46] = 0x80;
        self.mixer[0x47] = 0x80;
        self.mixer[0x80] = keep80;
        self.mixer[0x81] = keep81;
    }

    /// The SB Pro registers are views of the CT1745's pairs: 4 bits a
    /// side, high nibble left.
    fn proPair(reg: u8) ?u8 {
        return switch (reg) {
            0x04 => 0x32,
            0x22 => 0x30,
            0x26 => 0x34,
            0x28 => 0x36,
            0x2E => 0x38,
            else => null,
        };
    }

    fn mixerRead(self: *const SoundBlaster, reg: u8) u8 {
        if (proPair(reg)) |p| return (self.mixer[p] & 0xF0) | (self.mixer[p + 1] >> 4);
        return switch (reg) {
            0x0A => (self.mixer[0x3A] >> 5) & 0x06,
            0x82 => @as(u8, @intFromBool(self.pending8)) | (@as(u8, @intFromBool(self.pending16)) << 1),
            else => self.mixer[reg],
        };
    }
    fn mixerWrite(self: *SoundBlaster, reg: u8, v: u8) void {
        if (reg == 0x00) return self.mixerReset();
        if (reg == 0x82) return;
        if (proPair(reg)) |p| {
            self.mixer[p] = (v & 0xF0) | 0x08;
            self.mixer[p + 1] = (v << 4) | 0x08;
            return;
        }
        if (reg == 0x0A) {
            self.mixer[0x3A] = (v & 0x06) << 5;
            return;
        }
        self.mixer[reg] = v;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

var test_mem: Memory = .{};
var test_sb: SoundBlaster = .{};
var test_dma: Dma = .{};

fn dsp(s: *SoundBlaster, bytes: []const u8) void {
    for (bytes) |b| {
        // (a program waits for bit 7 of 0x22C to clear)
        std.debug.assert(s.in8(0x22C) & 0x80 == 0);
        s.out8(0x22C, b);
    }
}
fn readDsp(s: *SoundBlaster) ?u8 {
    if (s.in8(0x22E) & 0x80 == 0) return null;
    return s.in8(0x22A);
}

/// Channel 1 (or 5) reads `len` units from `addr`, single or auto.
fn program(d: *Dma, ch: u3, addr: u32, len: u32, auto: bool) void {
    const wide = ch >= 4;
    const a: u32 = if (wide) (addr >> 1) & 0xFFFF else addr & 0xFFFF;
    const base: u16 = if (wide) 0xC0 else 0x00;
    const step: u16 = if (wide) 2 else 1;
    const c: u16 = ch & 3;
    d.out8(base + 0x0A * step, 0x04 | @as(u8, @intCast(c)));
    d.out8(base + 0x0B * step, @as(u8, if (auto) 0x58 else 0x48) | @as(u8, @intCast(c)));
    d.out8(base + 0x0C * step, 0);
    d.out8(base + 2 * c * step, @truncate(a));
    d.out8(base + 2 * c * step, @truncate(a >> 8));
    d.out8(base + (2 * c + 1) * step, @truncate(len - 1));
    d.out8(base + (2 * c + 1) * step, @truncate((len - 1) >> 8));
    const page_port: u16 = switch (ch) {
        1 => 0x83,
        5 => 0x8B,
        else => unreachable,
    };
    d.out8(page_port, @truncate(addr >> 16));
    d.out8(base + 0x0A * step, @intCast(c));
}

test "sb: reset handshake, version, copyright, inverse" {
    const s = &test_sb;
    s.reset();
    try t.expectEqual(@as(?u8, null), readDsp(s));
    s.out8(0x226, 1);
    s.out8(0x226, 0);
    try t.expectEqual(@as(?u8, 0xAA), readDsp(s));
    try t.expectEqual(@as(?u8, null), readDsp(s));
    dsp(s, &.{0xE1});
    try t.expectEqual(@as(?u8, 4), readDsp(s));
    try t.expectEqual(@as(?u8, 5), readDsp(s));
    dsp(s, &.{ 0xE0, 0x5A });
    try t.expectEqual(@as(?u8, 0xA5), readDsp(s));
    dsp(s, &.{0xE3});
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (readDsp(s)) |c| : (n += 1) buf[n] = c;
    try t.expectEqualStrings(COPYRIGHT ++ "\x00", buf[0..n]);
    // The mixer: IRQ and DMA setup, a volume through the SB Pro view.
    s.out8(0x224, 0x80);
    try t.expectEqual(@as(u8, 0x02), s.in8(0x225));
    s.out8(0x224, 0x81);
    try t.expectEqual(@as(u8, 0x22), s.in8(0x225));
    s.out8(0x224, 0x22);
    s.out8(0x225, 0xFF);
    s.out8(0x224, 0x30);
    try t.expectEqual(@as(u8, 0xF8), s.in8(0x225));
    s.out8(0x224, 0x22);
    try t.expectEqual(@as(u8, 0xFF), s.in8(0x225));
}

test "sb: an 8-bit single-cycle block plays and raises one IRQ" {
    const s = &test_sb;
    const m = &test_mem;
    const d = &test_dma;
    s.reset();
    d.reset();
    // 1000 bytes: a ramp, at 0x30000.
    var i: u32 = 0;
    while (i < 1000) : (i += 1) m.ram[0x30000 + i] = @truncate(i);
    program(d, DMA8, 0x30000, 1000, false);
    dsp(s, &.{ 0xD1, 0x40, 256 - 100 }); // 10 kHz
    dsp(s, &.{ 0x14, @truncate(999), 999 >> 8 });
    var irqs: u32 = 0;
    var us: u32 = 0;
    while (us < 150_000) : (us += 250) {
        if (s.advance(d, m, 250)) {
            irqs += 1;
            _ = s.in8(0x22E); // acknowledge
        }
    }
    try t.expectEqual(@as(u32, 1), irqs);
    try t.expect(!s.x.active);
    try t.expectEqual(@as(u32, 1000), s.snd.count());
    // The ramp's samples: 0 -> -128 << 8, 1 -> -127 << 8, ...
    try t.expectEqual(@as(i16, -128 << 8), s.snd.buf[0][0]);
    try t.expectEqual(@as(i16, -127 << 8), s.snd.buf[1][1]);
    // Mixed to the host: non-silent.
    var out: [2 * 441]i16 = [_]i16{0} ** (2 * 441);
    s.mix(&out, 44100);
    var energy: u64 = 0;
    for (out) |v| energy += @abs(@as(i64, v));
    try t.expect(energy > 100_000);
}

test "sb: auto-init repeats its IRQ; 16-bit stereo; exit; direct DAC" {
    const s = &test_sb;
    const m = &test_mem;
    const d = &test_dma;
    s.reset();
    d.reset();
    program(d, DMA8, 0x40000, 2000, true);
    dsp(s, &.{ 0x40, 256 - 50 }); // 20 kHz
    dsp(s, &.{ 0x48, @truncate(499), 499 >> 8, 0x1C });
    var irqs: u32 = 0;
    var us: u32 = 0;
    while (us < 100_000) : (us += 250) {
        if (s.advance(d, m, 250)) {
            irqs += 1;
            _ = s.in8(0x22E);
        }
    }
    // 2000 samples in 100 ms at 20 kHz: four blocks of 500.
    try t.expectEqual(@as(u32, 4), irqs);
    try t.expect(s.x.active);
    // Without acknowledges, the line stays up: no new edges.
    us = 0;
    var edges: u32 = 0;
    while (us < 100_000) : (us += 250) {
        if (s.advance(d, m, 250)) edges += 1;
    }
    try t.expectEqual(@as(u32, 1), edges);
    s.out8(0x224, 0x82);
    try t.expectEqual(@as(u8, 0x01), s.in8(0x225));
    _ = s.in8(0x22E);
    // DAh: the block in progress ends, then it stops.
    dsp(s, &.{0xDA});
    us = 0;
    while (us < 100_000) : (us += 250) _ = s.advance(d, m, 250);
    try t.expect(!s.x.active);
    // 16-bit stereo signed, auto-init, 44.1 kHz: words through DMA 5.
    s.reset();
    d.reset();
    var i: u32 = 0;
    while (i < 400) : (i += 2) {
        std.mem.writeInt(i16, m.ram[0x50000 + i * 2 ..][0..2], 1000, .little);
        std.mem.writeInt(i16, m.ram[0x50000 + i * 2 + 2 ..][0..2], -1000, .little);
    }
    program(d, DMA16, 0x50000, 400, true);
    dsp(s, &.{ 0x41, 0xAC, 0x44 });
    dsp(s, &.{ 0xB6, 0x30, @truncate(199), 0 });
    irqs = 0;
    us = 0;
    while (us < 20_000) : (us += 250) {
        if (s.advance(d, m, 250)) {
            irqs += 1;
            try t.expect(s.pending16);
            _ = s.in8(0x22F);
        }
    }
    // 882 frames = 1764 words in 20 ms; blocks of 200 words: 8 IRQs.
    try t.expectEqual(@as(u32, 8), irqs);
    try t.expectEqual(@as(i16, 1000), s.snd.buf[3][0]);
    try t.expectEqual(@as(i16, -1000), s.snd.buf[3][1]);
    // Pause stops the pull.
    dsp(s, &.{0xD5});
    const before = s.snd.wr;
    _ = s.advance(d, m, 5000);
    try t.expectEqual(before, s.snd.wr);
    dsp(s, &.{0xD6});
    _ = s.advance(d, m, 5000);
    try t.expect(s.snd.wr != before);
    // Direct output: 10h bytes at the rate they come.
    s.reset();
    var k: u32 = 0;
    while (k < 40) : (k += 1) {
        dsp(s, &.{ 0x10, 0xC0 });
        dsp(s, &.{ 0x10, 0xC0 });
        _ = s.advance(d, m, 250);
    }
    try t.expectEqual(@as(u32, 80), s.snd.count());
    try t.expectEqual(@as(i16, 0x40 << 8), s.snd.buf[5][0]);
    try t.expectEqual(@as(u32, 8000), s.snd_rate);
    // F2h: an IRQ on demand.
    dsp(s, &.{0xF2});
    try t.expect(s.advance(d, m, 250));
    _ = s.in8(0x22E);
    // 80h: a silent block, then its IRQ.
    s.reset();
    dsp(s, &.{ 0x40, 256 - 100, 0x80, 99, 0 });
    us = 0;
    irqs = 0;
    while (us < 20_000) : (us += 250) {
        if (s.advance(d, m, 250)) irqs += 1;
    }
    try t.expectEqual(@as(u32, 1), irqs);
}

test "sb: ADPCM 4-bit with a reference decodes" {
    const s = &test_sb;
    const m = &test_mem;
    const d = &test_dma;
    s.reset();
    d.reset();
    m.ram[0x60000] = 0x80; // the reference
    var i: u32 = 1;
    while (i < 100) : (i += 1) m.ram[0x60000 + i] = 0x77; // up, up
    program(d, DMA8, 0x60000, 100, false);
    dsp(s, &.{ 0x40, 256 - 100, 0x75, 99, 0 });
    var us: u32 = 0;
    var irqs: u32 = 0;
    while (us < 40_000) : (us += 250) {
        if (s.advance(d, m, 250)) irqs += 1;
    }
    try t.expectEqual(@as(u32, 1), irqs);
    try t.expectEqual(@as(u32, 1 + 99 * 2), s.snd.count());
    // A rising signal that saturates.
    try t.expect(s.snd.buf[10][0] > s.snd.buf[2][0]);
    try t.expectEqual(@as(i16, 127 << 8), s.snd.buf[198][0]);
}
