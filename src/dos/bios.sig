//! The system BIOS, written in Sig: the data area at 0x400 (equipment,
//! memory size, keyboard buffer and flags, timer ticks, video fields set
//! by video_bios.sig), int 11h, 12h, 13h (no floppy or hard disk: "no
//! drive"), 15h (A20 functions 24xx, the extended memory size 88h, wait
//! 86h, the system configuration C0h, E801h), 16h (keyboard: read, peek,
//! shift flags, store, typematic), 1Ah (ticks since midnight, the RTC's
//! time and date), int 09h's default handler (scan code to the buffer)
//! and int 08h's (the tick count, int 1Ch).
//! STUB: the API; the services come next.

const std = @import("std");
const Regs = @import("regs.sig").Regs;
const Memory = @import("mem.sig").Memory;
const host_mod = @import("host.sig");

pub const State = struct {
    pub fn reset(self: *State) void {
        self.* = .{};
    }
};

/// The data area and the ROM's tables as at boot (`conv_kb`: conventional
/// memory in KiB, `ext_kb`: extended memory above 1 MiB in KiB).
pub fn boot(st: *State, mem: *Memory, conv_kb: u16, ext_kb: u16) void {
    _ = st;
    _ = mem;
    _ = conv_kb;
    _ = ext_kb;
}

/// int 09h's default handler: the scan code just read from port 0x60.
pub fn keyIrq(st: *State, mem: *Memory, code: u8) void {
    _ = st;
    _ = mem;
    _ = code;
}

/// int 08h's default handler's work (the tick count); the machine then
/// calls int 1Ch.
pub fn timerTick(st: *State, mem: *Memory) void {
    _ = st;
    _ = mem;
}

/// Services: false when the call must wait (int 16h/00h with an empty
/// buffer): the machine runs it again after the next interrupt.
pub fn int11(r: *Regs, mem: *Memory) void {
    r.setAx(mem.rdW(0x40, 0x10));
}
pub fn int12(r: *Regs, mem: *Memory) void {
    r.setAx(mem.rdW(0x40, 0x13));
}
pub fn int13(r: *Regs, mem: *Memory) void {
    _ = mem;
    r.setAh(0x01);
    r.fail(0x0100);
}
pub fn int15(st: *State, r: *Regs, mem: *Memory, a20: *bool) void {
    _ = st;
    _ = mem;
    _ = a20;
    r.setAh(0x86);
    r.setFlag(@import("regs.sig").CF, true);
}
pub fn int16(st: *State, r: *Regs, mem: *Memory) bool {
    _ = st;
    _ = r;
    _ = mem;
    return true;
}
pub fn int1a(st: *State, r: *Regs, mem: *Memory, host: host_mod.Host) void {
    _ = st;
    _ = r;
    _ = mem;
    _ = host;
}
