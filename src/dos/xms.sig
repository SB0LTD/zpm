//! Memory above 1 MiB, the two ways DOS programs ask for it:
//! XMS 3.0 (HIMEM's driver: the entry point int 2Fh/4310h gives, its
//! functions 00h-12h and the 32-bit 88h-8Fh: version, the HMA, A20,
//! extended memory blocks, moves, locks) and EMS 4.0 (EMM386's int 67h,
//! "EMMXXXX0" device: status, the page frame at E000h, pages, handles,
//! mapping 40h-5Fh as games use them). Both carve their memory out of
//! the 15 MiB above the HMA; the EMS page frame is mapped through
//! `emsWindow`, which the machine's bus asks for 0xE0000-0xEFFFF.
//! STUB: the API; the services come next.

const std = @import("std");
const Regs = @import("regs.sig").Regs;
const Memory = @import("mem.sig").Memory;

/// The EMS page frame's segment.
pub const FRAME: u16 = 0xE000;

pub const State = struct {
    pub fn reset(self: *State) void {
        self.* = .{};
    }
    /// Where 0xE0000 + `off` (off < 0x10000) lives in RAM, or null if
    /// that 16 KiB window maps no page.
    pub fn emsWindow(self: *const State, off: u32) ?u32 {
        _ = self;
        _ = off;
        return null;
    }
};

/// Sets up both over RAM from `from` (the first byte above the HMA) to
/// `to`, and puts the EMS device header (for "EMMXXXX0") where int 67h's
/// vector points (`dev_seg`).
pub fn boot(st: *State, mem: *Memory, from: u32, to: u32, dev_seg: u16) void {
    _ = st;
    _ = mem;
    _ = from;
    _ = to;
    _ = dev_seg;
}

/// The XMS driver's far entry point (called with AH = function).
pub fn xms(st: *State, r: *Regs, mem: *Memory) void {
    _ = st;
    _ = mem;
    r.setAx(0);
    r.setBl(0x80);
}

/// int 67h.
pub fn int67(st: *State, r: *Regs, mem: *Memory) void {
    _ = st;
    _ = mem;
    r.setAh(0x84);
}
