//! A Microsoft mouse driver, int 33h: reset and status, show/hide the
//! cursor (drawn by the driver in text and graphics modes it knows),
//! position and buttons, presses and releases, ranges, the mickey ratio,
//! the user's event handler (function 0Ch/14h: called on the next
//! interrupt with the event mask in AX).
//! STUB: the API; the driver comes next.

const std = @import("std");
const Regs = @import("regs.sig").Regs;
const Memory = @import("mem.sig").Memory;

pub const State = struct {
    pub fn reset(self: *State) void {
        self.* = .{};
    }
    /// The host's pointer moved by (dx, dy) in its own pixels.
    pub fn move(self: *State, dx: i32, dy: i32) void {
        _ = self;
        _ = dx;
        _ = dy;
    }
    /// The host's buttons (bit 0 left, 1 right, 2 middle).
    pub fn buttons(self: *State, b: u3) void {
        _ = self;
        _ = b;
    }
    /// A user handler waits to be called: its far address and the event
    /// mask (the machine calls it as int 33h's driver would).
    pub fn userCall(self: *State) ?struct { seg: u16, off: u16, mask: u16 } {
        _ = self;
        return null;
    }
};

/// int 33h.
pub fn int33(st: *State, r: *Regs, mem: *Memory) void {
    _ = st;
    _ = mem;
    r.setAx(0);
}
