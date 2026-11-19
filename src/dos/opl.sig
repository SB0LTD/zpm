//! FM music: a YMF262 (OPL3), which is also an OPL2 (YM3812) until a
//! program sets its NEW bit, at 0x388-0x38B (AdLib) and the Sound
//! Blaster's 0x220-0x223 / 0x228-0x229: 18 two-operator channels (or 6
//! four-operator ones), the rhythm mode, the envelope generator, the
//! waveforms, vibrato and tremolo, the two timers and the status register
//! programs detect the chip with. Clean room, from Yamaha's data sheets.
//! STUB: the API; the chip comes next.

const std = @import("std");

/// The chip's own sample rate (14.31818 MHz / 288).
pub const RATE: u32 = 49716;

pub const Opl = struct {
    pub fn reset(self: *Opl) void {
        self.* = .{};
    }
    /// Emulated time goes on by `us` microseconds (the timers run).
    pub fn advance(self: *Opl, us: u32) void {
        _ = self;
        _ = us;
    }
    /// The chip's sound, added into `out` (interleaved stereo i16 at
    /// `rate`, resampled from the chip's own rate).
    pub fn mix(self: *Opl, out: []i16, rate: u32) void {
        _ = self;
        _ = out;
        _ = rate;
    }
    /// `port` is the offset: 0 = address (bank 0), 1 = data, 2 = address
    /// (bank 1), 3 = data.
    pub fn in8(self: *Opl, port: u2) u8 {
        _ = self;
        _ = port;
        return 0x06;
    }
    pub fn out8(self: *Opl, port: u2, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
};
