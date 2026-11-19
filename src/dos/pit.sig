//! The 8253/8254 timer at 0x40-0x43 (1.193182 MHz): channel 0 drives
//! IRQ 0 (18.2 Hz from the BIOS, faster when a game reprograms it),
//! channel 2 the PC speaker (gated by port 0x61). Modes 0-5, LSB/MSB
//! access, latches (counter and read-back), the read of a running count.
//! STUB: the API; the timer comes next.

const std = @import("std");

pub const HZ: u32 = 1_193_182;

pub const Pit = struct {
    pub fn reset(self: *Pit) void {
        self.* = .{};
    }
    /// Time goes on by `clocks` of 1.193182 MHz; how many times channel
    /// 0's output rose (IRQ 0 edges) in that time.
    pub fn advance(self: *Pit, clocks: u32) u32 {
        _ = self;
        _ = clocks;
        return 0;
    }
    /// Clocks until channel 0's next rising edge (the machine sizes its
    /// CPU slices by it).
    pub fn untilIrq(self: *const Pit) u32 {
        _ = self;
        return HZ / 18;
    }
    pub fn in8(self: *Pit, port: u16) u8 {
        _ = self;
        _ = port;
        return 0;
    }
    pub fn out8(self: *Pit, port: u16, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
    /// Port 0x61: speaker data (bit 1) and channel 2's gate (bit 0) in;
    /// channel 2's output (bit 5) and the refresh toggle (bit 4) out.
    pub fn in61(self: *Pit) u8 {
        _ = self;
        return 0;
    }
    pub fn out61(self: *Pit, v: u8) void {
        _ = self;
        _ = v;
    }
    /// The PC speaker's sound, added into `out` (stereo i16 at `rate`).
    pub fn speaker(self: *Pit, out: []i16, rate: u32) void {
        _ = self;
        _ = out;
        _ = rate;
    }
};
