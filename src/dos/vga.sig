//! The VGA: 256 KiB in four planes, the sequencer, CRT controller,
//! graphics controller, attribute controller, DAC (256 colours of 18
//! bits) and the miscellaneous/status registers at 0x3B0-0x3DF; memory at
//! 0xA0000-0xBFFFF as the graphics controller maps it (read modes 0-1,
//! write modes 0-3, latches, chain-4, odd/even). It shows text modes
//! (with its own font), CGA/EGA/VGA graphics modes, mode 13h and the
//! unchained ("mode X") 256-colour modes, with the CRTC's start address,
//! line compare (split screen), pixel panning and double scanning; the
//! status register's retraces follow emulated time (70 Hz).
//! STUB: the API; the adapter comes next.

const std = @import("std");

pub const Size = struct { w: u16 = 0, h: u16 = 0 };

pub const Vga = struct {
    pub fn reset(self: *Vga) void {
        self.* = .{};
    }
    /// Emulated time goes on (retrace in the status register).
    pub fn advance(self: *Vga, us: u32) void {
        _ = self;
        _ = us;
    }
    /// True at the start of each vertical retrace since the last call
    /// (the machine's frame boundary).
    pub fn frameDone(self: *Vga) bool {
        _ = self;
        return false;
    }
    /// A read or write at 0xA0000 + `off` (off < 0x20000).
    pub fn read(self: *Vga, off: u32) u8 {
        _ = self;
        _ = off;
        return 0xFF;
    }
    pub fn write(self: *Vga, off: u32, v: u8) void {
        _ = self;
        _ = off;
        _ = v;
    }
    pub fn in8(self: *Vga, port: u16) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out8(self: *Vga, port: u16, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
    /// The picture as the monitor would show it, XRGB8888 into `out`
    /// (`stride` pixels a row, at most `max.w` x `max.h`): its size, before
    /// any aspect correction (320x200 for mode 13h, 720x400 for text).
    pub fn render(self: *Vga, out: []u32, stride: u32, max: Size) Size {
        _ = self;
        _ = out;
        _ = stride;
        _ = max;
        return .{};
    }
};
