//! The two 8237 DMA controllers: 8-bit channels 0-3 (0x00-0x0F) and 16-bit
//! channels 4-7 (0xC0-0xDF), their page registers (0x80-0x8F), masks,
//! modes (single, auto-initialize, read/write, increment/decrement),
//! terminal count, flip-flop. Only the Sound Blaster uses it here.
//! STUB: the API; the controller comes next.

const std = @import("std");
const Memory = @import("mem.sig").Memory;

pub const Dma = struct {
    pub fn reset(self: *Dma) void {
        self.* = .{};
    }
    /// The device reads up to `out.len` bytes from memory on channel `ch`
    /// (a 16-bit channel moves words: `out.len` is even); returns how many
    /// and whether the channel reached its terminal count.
    pub fn read(self: *Dma, mem: *const Memory, ch: u3, out: []u8) struct { n: usize, tc: bool } {
        _ = self;
        _ = mem;
        _ = ch;
        _ = out;
        return .{ .n = 0, .tc = false };
    }
    /// The device writes into memory (a recording).
    pub fn write(self: *Dma, mem: *Memory, ch: u3, in: []const u8) struct { n: usize, tc: bool } {
        _ = self;
        _ = mem;
        _ = ch;
        _ = in;
        return .{ .n = 0, .tc = false };
    }
    /// Channel `ch` is unmasked and has a transfer programmed.
    pub fn ready(self: *const Dma, ch: u3) bool {
        _ = self;
        _ = ch;
        return false;
    }
    pub fn in8(self: *Dma, port: u16) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out8(self: *Dma, port: u16, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
};
