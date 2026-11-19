//! The two 8259A interrupt controllers (master at 0x20, slave at 0xA0,
//! cascaded on IRQ 2), as the BIOS leaves them: vectors 0x08-0x0F and
//! 0x70-0x77. Edge-triggered requests, the mask (IMR), in-service (ISR)
//! and request (IRR) registers, specific and non-specific EOI, OCW3's
//! reads, ICW programming (a game may move the vectors).
//! STUB: the API; the controller comes next.

const std = @import("std");

pub const Pic = struct {
    pub fn reset(self: *Pic) void {
        self.* = .{};
    }
    /// A device's line goes up (an edge: one request).
    pub fn raise(self: *Pic, irq: u4) void {
        _ = self;
        _ = irq;
    }
    /// Its line goes down (level-sensitive devices only).
    pub fn lower(self: *Pic, irq: u4) void {
        _ = self;
        _ = irq;
    }
    /// An unmasked request above everything in service waits.
    pub fn pending(self: *const Pic) bool {
        _ = self;
        return false;
    }
    /// The CPU takes the interrupt: its vector, the request now in service.
    pub fn acknowledge(self: *Pic) ?u8 {
        _ = self;
        return null;
    }
    pub fn in8(self: *Pic, port: u16) u8 {
        _ = self;
        _ = port;
        return 0xFF;
    }
    pub fn out8(self: *Pic, port: u16, v: u8) void {
        _ = self;
        _ = port;
        _ = v;
    }
};
