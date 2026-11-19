//! The CPU: an 80386 as DOS games of the early 1990s use it, in real mode
//! (16-bit code with the 0x66/0x67 prefixes for 32-bit operands and
//! addresses), integer instructions and the x87 FPU's common ones.
//! STUB: the API the rest of the package builds on; the core comes next.
//!
//! `bus` (anytype) is the machine: it provides
//!   rd8/rd16/rd32(lin: u32), wr8/wr16/wr32(lin: u32, v),
//!   in8/in16/in32(port: u16), out8/out16/out32(port: u16, v),
//!   hle(cpu: *Cpu, id: u16) bool  -- a BIOS/DOS service written in Sig:
//!       the trap `FE 38 vv` runs service vv, `FE 39 vv` service 0x100+vv
//!       (far-call entry points: XMS's); the core syncs `regs` (exact
//!       flags) before and reloads them after; false = it waits (int 16h
//!       for a key): the core steps back onto the trap and returns .wait,
//!   irq() bool                    -- an interrupt waits for IF.
//! Linear addresses are seg base + offset (16-bit offsets wrap at 64 KiB);
//! the bus applies the A20 gate.

const std = @import("std");
const regs_mod = @import("regs.sig");
pub const Regs = regs_mod.Regs;

pub const Exit = enum {
    /// The budget is spent.
    budget,
    /// HLT with interrupts off and none to come, or a HLT that waits.
    halt,
    /// An interrupt waits and IF is set: the machine delivers it.
    irq,
    /// A service waits for something (a key): the trap runs again later.
    wait,
    /// An instruction the core does not have, or a fault with no handler.
    fault,
};

/// The HLE trap: FE /7 with ModRM 0x38 or 0x39 (no x86 instruction),
/// then the service's number.
pub const TRAP0: u8 = 0xFE;
pub const TRAP1: u8 = 0x38;
pub const TRAP1_FAR: u8 = 0x39;

pub const Cpu = struct {
    regs: Regs = .{},
    halted: bool = false,
    /// Instructions run since reset.
    executed: u64 = 0,
    /// Why the last .fault (the opcode and where).
    fault_op: u32 = 0,
    fault_at: u32 = 0,

    pub fn reset(self: *Cpu) void {
        self.* = .{};
        self.regs.setSeg(regs_mod.CS, 0xF000);
        self.regs.eip = 0xFFF0;
    }

    /// Runs at most `budget` instructions.
    pub fn run(self: *Cpu, bus: anytype, budget: u32) Exit {
        _ = bus;
        _ = budget;
        self.fault_at = self.regs.base[regs_mod.CS] +% self.regs.eip;
        return .fault;
    }

    /// Delivers interrupt `vec` now, as INT does in real mode: pushes
    /// FLAGS, CS and IP, clears IF and TF, and jumps through the vector
    /// table at 0:vec*4. Leaves HLT.
    pub fn interrupt(self: *Cpu, bus: anytype, vec: u8) void {
        const r = &self.regs;
        var sp = r.sp();
        const ss = r.base[regs_mod.SS];
        sp -%= 2;
        bus.wr16(ss +% sp, @truncate(r.flags));
        sp -%= 2;
        bus.wr16(ss +% sp, r.seg[regs_mod.CS]);
        sp -%= 2;
        bus.wr16(ss +% sp, @truncate(r.eip));
        r.set16(regs_mod.ESP, sp);
        r.flags &= ~(regs_mod.IF | regs_mod.TF);
        const v = @as(u32, vec) * 4;
        r.eip = bus.rd16(v);
        r.setSeg(regs_mod.CS, bus.rd16(v + 2));
        self.halted = false;
    }
};
