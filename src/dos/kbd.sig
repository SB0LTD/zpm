//! The 8042 keyboard controller at 0x60/0x64: scan codes (set 1, as the
//! controller translates them) queued from the host's key events, IRQ 1
//! per byte, the status register, controller commands (self-test, the
//! output port with the A20 gate, LED and typematic commands to the
//! keyboard answered with ACK).
//! STUB: the API; the controller comes next.

const std = @import("std");

pub const Keyboard = struct {
    pub fn reset(self: *Keyboard) void {
        self.* = .{};
    }
    /// The host's key: a set-1 scan code (bit 7 = released; 0xE0 first
    /// for the extended keys).
    pub fn push(self: *Keyboard, code: u8) void {
        _ = self;
        _ = code;
    }
    /// A byte waits in the output buffer and IRQ 1 should be raised.
    pub fn wantIrq(self: *Keyboard) bool {
        _ = self;
        return false;
    }
    pub fn in8(self: *Keyboard, port: u16) u8 {
        _ = self;
        _ = port;
        return 0;
    }
    /// Returns the A20 gate's new state when a command changed it.
    pub fn out8(self: *Keyboard, port: u16, v: u8) ?bool {
        _ = self;
        _ = port;
        _ = v;
        return null;
    }
};
