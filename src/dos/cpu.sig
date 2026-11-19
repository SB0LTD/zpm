//! The CPU: an 80486DX (a 386 with the 486's few additions and its FPU)
//! as DOS games of the early 1990s use it, in real mode: 16-bit code with
//! the 0x66/0x67 prefixes for 32-bit operands and addresses (SIB, disp32),
//! every integer instruction a real-mode program can run, and the x87's
//! (cpu_x87.sig). Written from Intel's 80386/80486 Programmer's Reference
//! and the published opcode maps; no emulator's code.
//!
//! `bus` (anytype) is the machine: it provides
//!   rd8/rd16/rd32(lin: u32), wr8/wr16/wr32(lin: u32, v),
//!   in8/in16/in32(port: u16), out8/out16/out32(port: u16, v),
//!   hle(cpu: *Cpu, id: u16) bool  -- a BIOS/DOS service written in Sig:
//!       the trap `FE 38 vv` runs service vv, `FE 39 vv` service 0x100+vv
//!       (far-call entry points: XMS's); `regs` are exact around it (the
//!       core keeps no state of its own); false = it waits (int 16h for a
//!       key): the core steps back onto the trap and returns .wait,
//!   irq() bool                    -- an interrupt waits for IF.
//! Linear addresses are seg base + offset (16-bit offsets wrap at 64 KiB;
//! 32-bit ones (0x67) are not limit-checked, so "unreal" flat addressing
//! works); the bus applies the A20 gate.
//!
//! The interpreter dispatches on the opcode byte (prefixes loop back into
//! the same switch); flags are computed as each instruction runs, so
//! `regs.flags` is exact at every instruction boundary. `irq()` is asked
//! at the start of `run`, and after anything that can change the answer
//! or IF: IN/OUT/INS/OUTS, a service trap, STI/POPF/IRET (the machine
//! raises device interrupts only between `run` calls).
//!
//! What it is: CPUID says GenuineIntel family 4 model 3 (a 486DX2) with
//! an FPU; EFLAGS.AC and .ID toggle; CR0 reads ET=1. Not here: protected
//! mode (setting CR0.PE by MOV CR0 or LMSW stops with .fault), paging,
//! task switches, the segment limits of real mode (no #GP at offset
//! 0xFFFF), #MF/IRQ13 for unmasked FPU exceptions, and the Pentium's
//! RDTSC/CMPXCHG8B and later (invalid opcodes here, as on a 486).

const std = @import("std");
const regs_mod = @import("regs.sig");
const x87 = @import("cpu_x87.sig");
pub const Regs = regs_mod.Regs;
pub const Fpu = x87.Fpu;

const EAX = regs_mod.EAX;
const ECX = regs_mod.ECX;
const EDX = regs_mod.EDX;
const EBX = regs_mod.EBX;
const ESP = regs_mod.ESP;
const EBP = regs_mod.EBP;
const ESI = regs_mod.ESI;
const EDI = regs_mod.EDI;

const ES = regs_mod.ES;
const CS = regs_mod.CS;
const SS = regs_mod.SS;
const DS = regs_mod.DS;
const FS = regs_mod.FS;
const GS = regs_mod.GS;

const CF = regs_mod.CF;
const PF = regs_mod.PF;
const AF = regs_mod.AF;
const ZF = regs_mod.ZF;
const SF = regs_mod.SF;
const TF = regs_mod.TF;
const IF = regs_mod.IF;
const DF = regs_mod.DF;
const OF = regs_mod.OF;
const FIXED = regs_mod.FIXED;
const IOPL: u32 = 3 << 12;
const NT: u32 = 1 << 14;
const RF: u32 = 1 << 16;
const AC: u32 = 1 << 18;
const ID: u32 = 1 << 21;
const ARITH: u32 = CF | PF | AF | ZF | SF | OF;
/// What POPF can change in real mode (everything in the low word but the
/// fixed bits), POPFD (also AC and ID), IRETD (also RF).
const POPF16: u32 = CF | PF | AF | ZF | SF | TF | IF | DF | OF | IOPL | NT;
const POPF32: u32 = POPF16 | AC | ID;
const IRET32: u32 = POPF32 | RF;

/// CR0: PE, EM, TS, ET; a 486's at reset (CD NW ET).
const CR0_PE: u32 = 1 << 0;
const CR0_EM: u32 = 1 << 2;
const CR0_TS: u32 = 1 << 3;
const CR0_ET: u32 = 1 << 4;
const CR0_RESET: u32 = 0x6000_0010;

/// CPUID leaf 1's EAX (and EDX at reset): family 4, model 3, stepping 5.
pub const SIGNATURE: u32 = 0x0435;

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

const NOSEG: u3 = 7;

/// An instruction's prefixes.
const Pfx = struct {
    seg: u3 = NOSEG,
    o32: bool = false,
    a32: bool = false,
    /// 0 none, 1 REP/REPE (F3), 2 REPNE (F2).
    rep: u2 = 0,
};

/// A decoded ModRM operand: a register (`mem` false, number `rm`) or
/// memory at seg:off (`lin` = the segment's base + off).
const Mod = struct {
    reg: u3,
    rm: u3,
    mem: bool,
    seg: u3 = DS,
    off: u32 = 0,
    lin: u32 = 0,
};

const parity: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| t[i] = if (@popCount(@as(u8, @intCast(i))) & 1 == 0) @intCast(PF) else 0;
    break :blk t;
};

inline fn msb(comptime T: type) T {
    return @as(T, 1) << (@bitSizeOf(T) - 1);
}

/// Sign-extends T to i64.
inline fn sx(comptime T: type, v: T) i64 {
    return if (T == u8) @as(i8, @bitCast(v)) else if (T == u16) @as(i16, @bitCast(v)) else @as(i32, @bitCast(v));
}

/// A sign-extended byte as T.
inline fn sx8(comptime T: type, b: u8) T {
    const s: i32 = @as(i8, @bitCast(b));
    return @truncate(@as(u32, @bitCast(s)));
}

inline fn sx16(v: u16) u32 {
    const s: i32 = @as(i16, @bitCast(v));
    return @bitCast(s);
}

inline fn szp(comptime T: type, r: T) u32 {
    var f: u32 = parity[@as(u8, @truncate(r))];
    if (r == 0) f |= ZF;
    if (r & msb(T) != 0) f |= SF;
    return f;
}

inline fn rdM(bus: anytype, comptime T: type, a: u32) T {
    return if (T == u8) bus.rd8(a) else if (T == u16) bus.rd16(a) else bus.rd32(a);
}

inline fn wrM(bus: anytype, comptime T: type, a: u32, v: T) void {
    if (T == u8) bus.wr8(a, v) else if (T == u16) bus.wr16(a, v) else bus.wr32(a, v);
}

inline fn inP(bus: anytype, comptime T: type, port: u16) T {
    return if (T == u8) bus.in8(port) else if (T == u16) bus.in16(port) else bus.in32(port);
}

inline fn outP(bus: anytype, comptime T: type, port: u16, v: T) void {
    if (T == u8) bus.out8(port, v) else if (T == u16) bus.out16(port, v) else bus.out32(port, v);
}

const Str = enum { movs, cmps, stos, lods, scas, ins, outs };

pub const Cpu = struct {
    regs: Regs = .{},
    halted: bool = false,
    /// Instructions run since reset (a REP iteration counts as one).
    executed: u64 = 0,
    /// Why the last .fault, or the last invalid opcode delivered as int 6
    /// (the opcode bytes, and the linear address of the instruction).
    fault_op: u32 = 0,
    fault_at: u32 = 0,
    fpu: Fpu = .{},
    cr0: u32 = CR0_RESET,
    cr2: u32 = 0,
    cr3: u32 = 0,
    dr: [8]u32 = [_]u32{0} ** 8,
    gdt_base: u32 = 0,
    gdt_limit: u16 = 0xFFFF,
    /// Real mode's interrupt table is where IDTR says (0 after reset).
    idt_base: u32 = 0,
    idt_limit: u16 = 0x3FF,
    /// irq() has to be asked again before the next instruction.
    poll: bool = true,
    /// STI (with IF clear before) or MOV/POP SS: no interrupt before the
    /// next instruction.
    shadow: bool = false,
    /// The current instruction's IP (its first prefix).
    ins_ip: u32 = 0,

    pub fn reset(self: *Cpu) void {
        self.* = .{};
        self.regs.setSeg(CS, 0xF000);
        self.regs.eip = 0xFFF0;
        self.regs.r[EDX] = SIGNATURE;
    }

    /// Runs at most `budget` instructions.
    pub fn run(self: *Cpu, bus: anytype, budget: u32) Exit {
        self.poll = true;
        if (self.halted) {
            if (self.regs.flags & IF != 0 and bus.irq()) return .irq;
            return .halt;
        }
        const end = self.executed + budget;
        while (self.executed < end) {
            var trace = false;
            if (self.poll) {
                if (self.shadow) {
                    self.shadow = false;
                } else {
                    const f = self.regs.flags;
                    if (f & IF != 0 and bus.irq()) return .irq;
                    trace = f & TF != 0;
                    self.poll = trace;
                }
            }
            self.executed += 1;
            if (self.step(bus, end)) |why| return why;
            if (trace) {
                self.interrupt(bus, 1);
                self.poll = true;
            }
        }
        return .budget;
    }

    /// Delivers interrupt `vec` now, as INT does in real mode: pushes
    /// FLAGS, CS and IP, clears IF and TF, and jumps through the vector
    /// table (at 0:vec*4 unless LIDT moved it). Leaves HLT.
    pub fn interrupt(self: *Cpu, bus: anytype, vec: u8) void {
        const r = &self.regs;
        var sp = r.sp();
        const ss = r.base[SS];
        sp -%= 2;
        bus.wr16(ss +% sp, @truncate(r.flags));
        sp -%= 2;
        bus.wr16(ss +% sp, r.seg[CS]);
        sp -%= 2;
        bus.wr16(ss +% sp, @truncate(r.eip));
        r.set16(ESP, sp);
        r.flags &= ~(IF | TF);
        const v = self.idt_base +% @as(u32, vec) * 4;
        r.eip = bus.rd16(v);
        r.setSeg(CS, bus.rd16(v +% 2));
        self.halted = false;
    }

    // ── Faults ──────────────────────────────────────────────────────────

    /// An exception that restarts the instruction: IP points at it.
    fn fault(self: *Cpu, bus: anytype, vec: u8) ?Exit {
        self.regs.eip = self.ins_ip;
        self.interrupt(bus, vec);
        return null;
    }

    /// An invalid opcode: int 6, and noted in fault_op/fault_at.
    fn ud(self: *Cpu, bus: anytype, op: u32) ?Exit {
        self.fault_op = op;
        self.fault_at = self.regs.base[CS] +% self.ins_ip;
        return self.fault(bus, 6);
    }

    /// Something the core does not do: stop on the instruction.
    fn unsupported(self: *Cpu, op: u32) ?Exit {
        self.fault_op = op;
        self.regs.eip = self.ins_ip;
        self.fault_at = self.regs.base[CS] +% self.ins_ip;
        return .fault;
    }

    // ── Fetch and operands ──────────────────────────────────────────────

    inline fn fetch8(self: *Cpu, bus: anytype) u8 {
        const ip = self.regs.eip;
        self.regs.eip = (ip +% 1) & 0xFFFF;
        return bus.rd8(self.regs.base[CS] +% ip);
    }

    inline fn fetch16(self: *Cpu, bus: anytype) u16 {
        const ip = self.regs.eip;
        if (ip < 0xFFFF) {
            self.regs.eip = (ip + 2) & 0xFFFF;
            return bus.rd16(self.regs.base[CS] +% ip);
        }
        const lo = self.fetch8(bus);
        return lo | (@as(u16, self.fetch8(bus)) << 8);
    }

    inline fn fetch32(self: *Cpu, bus: anytype) u32 {
        const ip = self.regs.eip;
        if (ip < 0xFFFD) {
            self.regs.eip = (ip + 4) & 0xFFFF;
            return bus.rd32(self.regs.base[CS] +% ip);
        }
        const lo = self.fetch16(bus);
        return lo | (@as(u32, self.fetch16(bus)) << 16);
    }

    inline fn fetchT(self: *Cpu, bus: anytype, comptime T: type) T {
        return if (T == u8) self.fetch8(bus) else if (T == u16) self.fetch16(bus) else self.fetch32(bus);
    }

    inline fn getR(self: *const Cpu, comptime T: type, i: u3) T {
        return if (T == u8) self.regs.get8(i) else if (T == u16) @truncate(self.regs.r[i]) else self.regs.r[i];
    }

    inline fn setR(self: *Cpu, comptime T: type, i: u3, v: T) void {
        if (T == u8) self.regs.set8(i, v) else if (T == u16) self.regs.set16(i, v) else self.regs.r[i] = v;
    }

    inline fn modrm(self: *Cpu, bus: anytype, p: Pfx) Mod {
        return self.modrmB(bus, p, self.fetch8(bus));
    }

    fn modrmB(self: *Cpu, bus: anytype, p: Pfx, b: u8) Mod {
        var m = Mod{ .reg = @truncate(b >> 3), .rm = @truncate(b), .mem = b < 0xC0 };
        if (!m.mem) return m;
        if (p.a32) self.ea32(bus, &m, b >> 6) else self.ea16(bus, &m, b >> 6);
        if (p.seg != NOSEG) m.seg = p.seg;
        m.lin = self.regs.base[m.seg] +% m.off;
        return m;
    }

    fn ea16(self: *Cpu, bus: anytype, m: *Mod, mode: u8) void {
        const r = &self.regs.r;
        const bx: u16 = @truncate(r[EBX]);
        const bp: u16 = @truncate(r[EBP]);
        const si: u16 = @truncate(r[ESI]);
        const di: u16 = @truncate(r[EDI]);
        var off: u16 = switch (m.rm) {
            0 => bx +% si,
            1 => bx +% di,
            2 => bp +% si,
            3 => bp +% di,
            4 => si,
            5 => di,
            6 => bp,
            7 => bx,
        };
        if (m.rm == 2 or m.rm == 3 or (m.rm == 6 and mode != 0)) m.seg = SS;
        switch (mode) {
            0 => if (m.rm == 6) {
                off = self.fetch16(bus);
            },
            1 => off +%= sx8(u16, self.fetch8(bus)),
            else => off +%= self.fetch16(bus),
        }
        m.off = off;
    }

    fn ea32(self: *Cpu, bus: anytype, m: *Mod, mode: u8) void {
        const r = &self.regs.r;
        var off: u32 = 0;
        if (m.rm == 4) {
            const sib = self.fetch8(bus);
            const base: u3 = @truncate(sib);
            const idx: u3 = @truncate(sib >> 3);
            const sc: u5 = @intCast(sib >> 6);
            if (base == 5 and mode == 0) {
                off = self.fetch32(bus);
            } else {
                off = r[base];
                if (base == ESP or base == EBP) m.seg = SS;
            }
            if (idx != 4) off +%= r[idx] << sc;
        } else if (m.rm == 5 and mode == 0) {
            off = self.fetch32(bus);
        } else {
            off = r[m.rm];
            if (m.rm == EBP) m.seg = SS;
        }
        switch (mode) {
            0 => {},
            1 => off +%= sx8(u32, self.fetch8(bus)),
            else => off +%= self.fetch32(bus),
        }
        m.off = off;
    }

    inline fn rdE(self: *Cpu, bus: anytype, comptime T: type, m: Mod) T {
        return if (m.mem) rdM(bus, T, m.lin) else self.getR(T, m.rm);
    }

    inline fn wrE(self: *Cpu, bus: anytype, comptime T: type, m: Mod, v: T) void {
        if (m.mem) wrM(bus, T, m.lin, v) else self.setR(T, m.rm, v);
    }

    /// The source segment of string instructions, XLAT and moffs.
    inline fn dataSeg(p: Pfx) u3 {
        return if (p.seg != NOSEG) p.seg else DS;
    }

    // ── The stack (SS is 16-bit in real mode: SP wraps at 64 KiB) ───────

    inline fn push16(self: *Cpu, bus: anytype, v: u16) void {
        const sp: u16 = @truncate(self.regs.r[ESP] -% 2);
        self.regs.set16(ESP, sp);
        bus.wr16(self.regs.base[SS] +% sp, v);
    }
    inline fn push32(self: *Cpu, bus: anytype, v: u32) void {
        const sp: u16 = @truncate(self.regs.r[ESP] -% 4);
        self.regs.set16(ESP, sp);
        bus.wr32(self.regs.base[SS] +% sp, v);
    }
    inline fn pop16(self: *Cpu, bus: anytype) u16 {
        const sp: u16 = @truncate(self.regs.r[ESP]);
        const v = bus.rd16(self.regs.base[SS] +% sp);
        self.regs.set16(ESP, sp +% 2);
        return v;
    }
    inline fn pop32(self: *Cpu, bus: anytype) u32 {
        const sp: u16 = @truncate(self.regs.r[ESP]);
        const v = bus.rd32(self.regs.base[SS] +% sp);
        self.regs.set16(ESP, sp +% 4);
        return v;
    }
    inline fn pushT(self: *Cpu, bus: anytype, comptime T: type, v: T) void {
        if (T == u32) self.push32(bus, v) else self.push16(bus, v);
    }
    inline fn popT(self: *Cpu, bus: anytype, comptime T: type) T {
        return if (T == u32) self.pop32(bus) else self.pop16(bus);
    }
    inline fn pushV(self: *Cpu, bus: anytype, p: Pfx, v: u32) void {
        if (p.o32) self.push32(bus, v) else self.push16(bus, @truncate(v));
    }
    inline fn popV(self: *Cpu, bus: anytype, p: Pfx) u32 {
        return if (p.o32) self.pop32(bus) else self.pop16(bus);
    }
    inline fn addSp(self: *Cpu, n: u16) void {
        self.regs.set16(ESP, @as(u16, @truncate(self.regs.r[ESP])) +% n);
    }

    // ── Flags ───────────────────────────────────────────────────────────

    inline fn setArith(self: *Cpu, f: u32) void {
        self.regs.flags = (self.regs.flags & ~ARITH) | f;
    }

    inline fn cf(self: *const Cpu) u1 {
        return @truncate(self.regs.flags & CF);
    }

    inline fn add(self: *Cpu, comptime T: type, a: T, b: T, c: u1) T {
        const w: u64 = @as(u64, a) + b + c;
        const r: T = @truncate(w);
        var f = szp(T, r) | @as(u32, (a ^ b ^ r) & 0x10) | @as(u32, @truncate((w >> @bitSizeOf(T)) & 1));
        if ((a ^ r) & (b ^ r) & msb(T) != 0) f |= OF;
        self.setArith(f);
        return r;
    }

    inline fn sub(self: *Cpu, comptime T: type, a: T, b: T, c: u1) T {
        const r: T = a -% b -% c;
        var f = szp(T, r) | @as(u32, (a ^ b ^ r) & 0x10);
        if (@as(u64, a) < @as(u64, b) + c) f |= CF;
        if ((a ^ b) & (a ^ r) & msb(T) != 0) f |= OF;
        self.setArith(f);
        return r;
    }

    inline fn logic(self: *Cpu, comptime T: type, r: T) T {
        self.setArith(szp(T, r));
        return r;
    }

    inline fn alu(self: *Cpu, comptime T: type, op: u3, a: T, b: T) T {
        return switch (op) {
            0 => self.add(T, a, b, 0),
            1 => self.logic(T, a | b),
            2 => self.add(T, a, b, self.cf()),
            3 => self.sub(T, a, b, self.cf()),
            4 => self.logic(T, a & b),
            5, 7 => self.sub(T, a, b, 0),
            6 => self.logic(T, a ^ b),
        };
    }

    inline fn inc(self: *Cpu, comptime T: type, a: T) T {
        const c = self.regs.flags & CF;
        const r = self.add(T, a, 1, 0);
        self.regs.flags = (self.regs.flags & ~CF) | c;
        return r;
    }

    inline fn dec(self: *Cpu, comptime T: type, a: T) T {
        const c = self.regs.flags & CF;
        const r = self.sub(T, a, 1, 0);
        self.regs.flags = (self.regs.flags & ~CF) | c;
        return r;
    }

    inline fn cond(self: *const Cpu, cc: u4) bool {
        const f = self.regs.flags;
        const r = switch (@as(u3, @truncate(cc >> 1))) {
            0 => f & OF != 0,
            1 => f & CF != 0,
            2 => f & ZF != 0,
            3 => f & (CF | ZF) != 0,
            4 => f & SF != 0,
            5 => f & PF != 0,
            6 => (f & SF != 0) != (f & OF != 0),
            7 => (f & ZF != 0) or ((f & SF != 0) != (f & OF != 0)),
        };
        return r != (cc & 1 != 0);
    }

    inline fn jrel(self: *Cpu, rel: u32) void {
        self.regs.eip = (self.regs.eip +% rel) & 0xFFFF;
    }

    /// Group 2: ROL ROR RCL RCR SHL SHR SAL SAR by `count` (masked to 5
    /// bits, as on a 386; 0 changes nothing, flags included).
    fn shift(self: *Cpu, comptime T: type, op: u3, a: T, count: u8) T {
        const bits = @bitSizeOf(T);
        const n: u32 = count & 31;
        if (n == 0) return a;
        var f = self.regs.flags;
        var r: T = undefined;
        switch (op) {
            0 => { // ROL
                r = std.math.rotl(T, a, n % bits);
                const c = r & 1 != 0;
                f &= ~(CF | OF);
                if (c) f |= CF;
                if ((r & msb(T) != 0) != c) f |= OF;
            },
            1 => { // ROR
                r = std.math.rotr(T, a, n % bits);
                f &= ~(CF | OF);
                if (r & msb(T) != 0) f |= CF;
                if ((r ^ (r << 1)) & msb(T) != 0) f |= OF;
            },
            2, 3 => { // RCL, RCR: through CF, a (bits+1)-bit rotate
                const w: u6 = bits + 1;
                const k: u6 = @intCast(n % w);
                const mask: u64 = (@as(u64, 1) << w) - 1;
                const v: u64 = (@as(u64, f & CF) << bits) | a;
                const rv: u64 = if (op == 2)
                    ((v << k) | (v >> (w - k))) & mask
                else
                    ((v >> k) | (v << (w - k))) & mask;
                r = @truncate(rv);
                const c = (rv >> bits) & 1 != 0;
                f &= ~(CF | OF);
                if (c) f |= CF;
                if (op == 2) {
                    if ((r & msb(T) != 0) != c) f |= OF;
                } else {
                    if ((r ^ (r << 1)) & msb(T) != 0) f |= OF;
                }
            },
            4, 6 => { // SHL/SAL
                const w: u64 = @as(u64, a) << @intCast(n);
                r = @truncate(w);
                const c = (w >> bits) & 1 != 0;
                f = (f & ~ARITH) | szp(T, r);
                if (c) f |= CF;
                if ((r & msb(T) != 0) != c) f |= OF;
            },
            5 => { // SHR
                const w: u64 = a;
                r = @truncate(w >> @intCast(n));
                f = (f & ~ARITH) | szp(T, r);
                if ((w >> @intCast(n - 1)) & 1 != 0) f |= CF;
                if (a & msb(T) != 0) f |= OF;
            },
            7 => { // SAR
                const s = sx(T, a);
                r = @truncate(@as(u64, @bitCast(s >> @intCast(n))));
                f = (f & ~ARITH) | szp(T, r);
                if ((s >> @intCast(n - 1)) & 1 != 0) f |= CF;
            },
        }
        self.regs.flags = f;
        return r;
    }

    /// SHLD (left) / SHRD: `a` shifted, filled from `b`.
    fn shiftD(self: *Cpu, comptime T: type, a: T, b: T, count: u8, left: bool) T {
        const bits = @bitSizeOf(T);
        const n: u32 = count & 31;
        if (n == 0) return a;
        var r: T = undefined;
        var c: bool = undefined;
        if (left) {
            const w: u128 = (@as(u128, a) << bits) | b;
            const s = w << @intCast(n);
            r = @truncate(s >> bits);
            c = (s >> (2 * bits)) & 1 != 0;
        } else {
            const w: u128 = (@as(u128, b) << bits) | a;
            r = @truncate(w >> @intCast(n));
            c = (w >> @intCast(n - 1)) & 1 != 0;
        }
        var f = szp(T, r);
        if (c) f |= CF;
        if ((r ^ a) & msb(T) != 0) f |= OF;
        self.setArith(f);
        return r;
    }

    fn mul(self: *Cpu, comptime T: type, b: T, signed: bool) void {
        const bits = @bitSizeOf(T);
        const a = self.getR(T, EAX);
        var lo: T = undefined;
        var hi: T = undefined;
        var of = false;
        if (signed) {
            const prod: i64 = sx(T, a) * sx(T, b);
            const u: u64 = @bitCast(prod);
            lo = @truncate(u);
            hi = @truncate(u >> bits);
            of = prod != sx(T, lo);
        } else {
            const prod: u64 = @as(u64, a) * b;
            lo = @truncate(prod);
            hi = @truncate(prod >> bits);
            of = hi != 0;
        }
        if (T == u8) {
            self.regs.set16(EAX, (@as(u16, hi) << 8) | lo);
        } else {
            self.setR(T, EAX, lo);
            self.setR(T, EDX, hi);
        }
        self.setArith(szp(T, lo) | (if (of) CF | OF else 0));
    }

    /// IMUL r, r/m(, imm): the low half, CF=OF if it lost bits.
    inline fn imul2(self: *Cpu, comptime T: type, a: T, b: T) T {
        const prod: i64 = sx(T, a) * sx(T, b);
        const r: T = @truncate(@as(u64, @bitCast(prod)));
        self.setArith(szp(T, r) | (if (prod != sx(T, r)) CF | OF else 0));
        return r;
    }

    /// DIV/IDIV; a zero divisor or a quotient too big is #DE (int 0).
    fn div(self: *Cpu, bus: anytype, comptime T: type, b: T, signed: bool) ?Exit {
        if (b == 0) return self.fault(bus, 0);
        const bits = @bitSizeOf(T);
        const n: u64 = if (T == u8)
            @as(u16, @truncate(self.regs.r[EAX]))
        else
            (@as(u64, self.getR(T, EDX)) << bits) | self.getR(T, EAX);
        var q: T = undefined;
        var rem: T = undefined;
        if (signed) {
            const ns: i64 = if (T == u8)
                @as(i16, @bitCast(@as(u16, @truncate(n))))
            else if (T == u16)
                @as(i32, @bitCast(@as(u32, @truncate(n))))
            else
                @bitCast(n);
            const d = sx(T, b);
            if (d == -1 and ns == std.math.minInt(i64)) return self.fault(bus, 0);
            const qs = @divTrunc(ns, d);
            const lim: i64 = @as(i64, 1) << (bits - 1);
            if (qs < -lim or qs >= lim) return self.fault(bus, 0);
            q = @truncate(@as(u64, @bitCast(qs)));
            rem = @truncate(@as(u64, @bitCast(@rem(ns, d))));
        } else {
            const qu = n / b;
            if (qu > std.math.maxInt(T)) return self.fault(bus, 0);
            q = @truncate(qu);
            rem = @truncate(n % b);
        }
        if (T == u8) {
            self.regs.set16(EAX, (@as(u16, rem) << 8) | q);
        } else {
            self.setR(T, EAX, q);
            self.setR(T, EDX, rem);
        }
        return null;
    }

    // ── Instruction groups ──────────────────────────────────────────────

    inline fn aluEG(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, op: u3, to_reg: bool) void {
        const m = self.modrm(bus, p);
        if (to_reg) {
            const r = self.alu(T, op, self.getR(T, m.reg), self.rdE(bus, T, m));
            if (op != 7) self.setR(T, m.reg, r);
        } else {
            const r = self.alu(T, op, self.rdE(bus, T, m), self.getR(T, m.reg));
            if (op != 7) self.wrE(bus, T, m, r);
        }
    }

    inline fn aluAI(self: *Cpu, bus: anytype, comptime T: type, op: u3) void {
        const b = self.fetchT(bus, T);
        const r = self.alu(T, op, self.getR(T, EAX), b);
        if (op != 7) self.setR(T, EAX, r);
    }

    /// 80-83: ALU r/m, imm (83: a sign-extended byte).
    inline fn grp1(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, imm8: bool) void {
        const m = self.modrm(bus, p);
        const b: T = if (imm8) sx8(T, self.fetch8(bus)) else self.fetchT(bus, T);
        const r = self.alu(T, m.reg, self.rdE(bus, T, m), b);
        if (m.reg != 7) self.wrE(bus, T, m, r);
    }

    const Count = enum { one, cl, imm };

    fn grp2(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, comptime src: Count) void {
        const m = self.modrm(bus, p);
        const n: u8 = switch (src) {
            .one => 1,
            .cl => self.regs.get8(1),
            .imm => self.fetch8(bus),
        };
        const a = self.rdE(bus, T, m);
        const r = self.shift(T, m.reg, a, n);
        if (n & 31 != 0) self.wrE(bus, T, m, r);
    }

    fn grp3(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) ?Exit {
        const m = self.modrm(bus, p);
        switch (m.reg) {
            0, 1 => {
                const b = self.fetchT(bus, T);
                _ = self.logic(T, self.rdE(bus, T, m) & b);
            },
            2 => self.wrE(bus, T, m, ~self.rdE(bus, T, m)),
            3 => self.wrE(bus, T, m, self.sub(T, 0, self.rdE(bus, T, m), 0)),
            4 => self.mul(T, self.rdE(bus, T, m), false),
            5 => self.mul(T, self.rdE(bus, T, m), true),
            6 => return self.div(bus, T, self.rdE(bus, T, m), false),
            7 => return self.div(bus, T, self.rdE(bus, T, m), true),
        }
        return null;
    }

    fn grp5(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) ?Exit {
        const m = self.modrm(bus, p);
        switch (m.reg) {
            0 => self.wrE(bus, T, m, self.inc(T, self.rdE(bus, T, m))),
            1 => self.wrE(bus, T, m, self.dec(T, self.rdE(bus, T, m))),
            2 => {
                const t = self.rdE(bus, T, m);
                self.pushT(bus, T, @truncate(self.regs.eip));
                self.regs.eip = t & 0xFFFF;
            },
            3, 5 => {
                if (!m.mem) return self.ud(bus, 0xFF00 | @as(u32, m.reg) << 3);
                const off = rdM(bus, T, m.lin);
                const sel = bus.rd16(m.lin +% @sizeOf(T));
                if (m.reg == 3) {
                    self.pushT(bus, T, self.regs.seg[CS]);
                    self.pushT(bus, T, @truncate(self.regs.eip));
                }
                self.regs.setSeg(CS, sel);
                self.regs.eip = off & 0xFFFF;
            },
            4 => self.regs.eip = self.rdE(bus, T, m) & 0xFFFF,
            6 => self.pushT(bus, T, self.rdE(bus, T, m)),
            7 => return self.ud(bus, 0xFF38),
        }
        return null;
    }

    fn pusha(self: *Cpu, bus: anytype, comptime T: type) void {
        const sp = self.getR(T, ESP);
        inline for (.{ EAX, ECX, EDX, EBX }) |i| self.pushT(bus, T, self.getR(T, i));
        self.pushT(bus, T, sp);
        inline for (.{ EBP, ESI, EDI }) |i| self.pushT(bus, T, self.getR(T, i));
    }

    fn popa(self: *Cpu, bus: anytype, comptime T: type) void {
        inline for (.{ EDI, ESI, EBP }) |i| self.setR(T, i, self.popT(bus, T));
        _ = self.popT(bus, T);
        inline for (.{ EBX, EDX, ECX, EAX }) |i| self.setR(T, i, self.popT(bus, T));
    }

    fn enter(self: *Cpu, bus: anytype, comptime T: type) void {
        const size = self.fetch16(bus);
        const level = self.fetch8(bus) & 31;
        self.pushT(bus, T, self.getR(T, EBP));
        const frame: T = self.getR(T, ESP);
        if (level > 0) {
            var bp: u16 = @truncate(self.regs.r[EBP]);
            var i: u8 = 1;
            while (i < level) : (i += 1) {
                bp -%= @sizeOf(T);
                self.pushT(bus, T, rdM(bus, T, self.regs.base[SS] +% bp));
            }
            self.pushT(bus, T, frame);
        }
        self.setR(T, EBP, frame);
        self.addSp(0 -% size);
    }

    fn leave(self: *Cpu, bus: anytype, comptime T: type) void {
        self.regs.set16(ESP, @truncate(self.regs.r[EBP]));
        self.setR(T, EBP, self.popT(bus, T));
    }

    fn bound(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) ?Exit {
        const m = self.modrm(bus, p);
        if (!m.mem) return self.ud(bus, 0x62);
        const i = sx(T, self.getR(T, m.reg));
        const lo = sx(T, rdM(bus, T, m.lin));
        const hi = sx(T, rdM(bus, T, m.lin +% @sizeOf(T)));
        if (i < lo or i > hi) return self.fault(bus, 5);
        return null;
    }

    /// LES/LDS/LSS/LFS/LGS: r, m16:16 or m16:32.
    fn lseg(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, s: u3, op: u32) ?Exit {
        const m = self.modrm(bus, p);
        if (!m.mem) return self.ud(bus, op);
        const off = rdM(bus, T, m.lin);
        const sel = bus.rd16(m.lin +% @sizeOf(T));
        self.setR(T, m.reg, off);
        self.regs.setSeg(s, sel);
        return null;
    }

    fn loadSeg(self: *Cpu, s: u3, v: u16) void {
        self.regs.setSeg(s, v);
        if (s == SS) {
            self.shadow = true;
            self.poll = true;
        }
    }

    fn imul3(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, imm8: bool) void {
        const m = self.modrm(bus, p);
        const a = self.rdE(bus, T, m);
        const b: T = if (imm8) sx8(T, self.fetch8(bus)) else self.fetchT(bus, T);
        self.setR(T, m.reg, self.imul2(T, a, b));
    }

    fn xchgEG(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) void {
        const m = self.modrm(bus, p);
        const a = self.rdE(bus, T, m);
        self.wrE(bus, T, m, self.getR(T, m.reg));
        self.setR(T, m.reg, a);
    }

    fn iret(self: *Cpu, bus: anytype, p: Pfx) void {
        const f = &self.regs.flags;
        if (p.o32) {
            const ip = self.pop32(bus);
            const cs = self.pop32(bus);
            const fl = self.pop32(bus);
            self.regs.eip = ip & 0xFFFF;
            self.regs.setSeg(CS, @truncate(cs));
            f.* = (f.* & ~IRET32) | (fl & IRET32) | FIXED;
        } else {
            const ip = self.pop16(bus);
            const cs = self.pop16(bus);
            const fl = self.pop16(bus);
            self.regs.eip = ip;
            self.regs.setSeg(CS, cs);
            f.* = (f.* & ~POPF16) | (fl & POPF16) | FIXED;
        }
        self.poll = true;
    }

    fn popf(self: *Cpu, bus: anytype, p: Pfx) void {
        const f = &self.regs.flags;
        if (p.o32) {
            const v = self.pop32(bus);
            f.* = (f.* & ~POPF32) | (v & POPF32) | FIXED;
        } else {
            const v: u32 = self.pop16(bus);
            f.* = (f.* & ~POPF16) | (v & POPF16) | FIXED;
        }
        self.poll = true;
    }

    fn daa(self: *Cpu, sub_: bool) void {
        const f = self.regs.flags;
        const old = self.regs.get8(0);
        var al = old;
        var c = false;
        var a = false;
        if (al & 0xF > 9 or f & AF != 0) {
            const t: u16 = if (sub_) @as(u16, al) -% 6 else @as(u16, al) + 6;
            al = @truncate(t);
            c = f & CF != 0 or t > 0xFF;
            a = true;
        }
        if (old > 0x99 or f & CF != 0) {
            al = if (sub_) al -% 0x60 else al +% 0x60;
            c = true;
        } else {
            c = false;
        }
        self.regs.set8(0, al);
        self.setArith(szp(u8, al) | (if (c) CF else 0) | (if (a) AF else 0));
    }

    fn aaa(self: *Cpu, sub_: bool) void {
        const f = self.regs.flags;
        var ax: u16 = @truncate(self.regs.r[EAX]);
        var adj = false;
        if (ax & 0xF > 9 or f & AF != 0) {
            // (as the SDM gives them: AX+106h; AX-6 then AH-1)
            ax = if (sub_) ax -% 6 -% 0x100 else ax +% 0x106;
            adj = true;
        }
        ax &= 0xFF0F;
        self.regs.set16(EAX, ax);
        self.setArith(szp(u8, @truncate(ax)) | (if (adj) CF | AF else 0));
    }

    fn btOp(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, m: Mod, off: T, from_reg: bool, op: u2) void {
        const bits = @bitSizeOf(T);
        const b: std.math.Log2Int(T) = @truncate(off);
        const mask: T = @as(T, 1) << b;
        var lin = m.lin;
        if (m.mem and from_reg) {
            const disp: i64 = (sx(T, off) >> comptime @ctz(@as(u32, bits))) * (bits / 8);
            const o = m.off +% @as(u32, @truncate(@as(u64, @bitCast(disp))));
            lin = self.regs.base[m.seg] +% (if (p.a32) o else o & 0xFFFF);
        }
        const v: T = if (m.mem) rdM(bus, T, lin) else self.getR(T, m.rm);
        if (v & mask != 0) self.regs.flags |= CF else self.regs.flags &= ~CF;
        const nv: T = switch (op) {
            0 => return,
            1 => v | mask,
            2 => v & ~mask,
            3 => v ^ mask,
        };
        if (m.mem) wrM(bus, T, lin, nv) else self.setR(T, m.rm, nv);
    }

    fn bitScan(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, rev: bool) void {
        const m = self.modrm(bus, p);
        const v = self.rdE(bus, T, m);
        if (v == 0) {
            self.regs.flags |= ZF;
            return;
        }
        self.regs.flags &= ~ZF;
        const i: T = if (rev) @intCast(@bitSizeOf(T) - 1 - @as(u32, @clz(v))) else @intCast(@ctz(v));
        self.setR(T, m.reg, i);
    }

    fn cmpxchg(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) void {
        const m = self.modrm(bus, p);
        const d = self.rdE(bus, T, m);
        const a = self.getR(T, EAX);
        _ = self.sub(T, a, d, 0);
        if (a == d) self.wrE(bus, T, m, self.getR(T, m.reg)) else self.setR(T, EAX, d);
    }

    fn xadd(self: *Cpu, bus: anytype, comptime T: type, p: Pfx) void {
        const m = self.modrm(bus, p);
        const d = self.rdE(bus, T, m);
        const r = self.add(T, d, self.getR(T, m.reg), 0);
        self.setR(T, m.reg, d);
        self.wrE(bus, T, m, r);
    }

    fn shxd(self: *Cpu, bus: anytype, comptime T: type, p: Pfx, left: bool, imm: bool) void {
        const m = self.modrm(bus, p);
        const n: u8 = if (imm) self.fetch8(bus) else self.regs.get8(1);
        const r = self.shiftD(T, self.rdE(bus, T, m), self.getR(T, m.reg), n, left);
        if (n & 31 != 0) self.wrE(bus, T, m, r);
    }

    // ── Strings ─────────────────────────────────────────────────────────

    inline fn str(self: *Cpu, bus: anytype, comptime k: Str, comptime T: type, p: Pfx, end: u64) void {
        if (p.a32) self.strA(bus, k, T, u32, p, end) else self.strA(bus, k, T, u16, p, end);
    }

    fn strA(self: *Cpu, bus: anytype, comptime k: Str, comptime T: type, comptime A: type, p: Pfx, end: u64) void {
        const sz: A = @sizeOf(T);
        const d: A = if (self.regs.flags & DF != 0) 0 -% sz else sz;
        const sb = self.regs.base[dataSeg(p)];
        const eb = self.regs.base[ES];
        const port: u16 = @truncate(self.regs.r[EDX]);
        const acc: T = self.getR(T, EAX);
        var si: A = @truncate(self.regs.r[ESI]);
        var di: A = @truncate(self.regs.r[EDI]);
        if (k == .ins or k == .outs) self.poll = true;
        if (p.rep == 0) {
            self.strIter(bus, k, T, A, sb, eb, &si, &di, d, port, acc);
        } else {
            var cx: A = @truncate(self.regs.r[ECX]);
            var first = true;
            var restart = false;
            while (cx != 0) {
                if (!first) {
                    if (self.executed >= end) {
                        restart = true;
                        break;
                    }
                    self.executed += 1;
                }
                first = false;
                self.strIter(bus, k, T, A, sb, eb, &si, &di, d, port, acc);
                cx -%= 1;
                if (k == .cmps or k == .scas) {
                    if ((self.regs.flags & ZF != 0) != (p.rep == 1)) break;
                }
            }
            self.setA(A, ECX, cx);
            if (restart) self.regs.eip = self.ins_ip;
        }
        switch (k) {
            .movs, .cmps => {
                self.setA(A, ESI, si);
                self.setA(A, EDI, di);
            },
            .lods, .outs => self.setA(A, ESI, si),
            .stos, .scas, .ins => self.setA(A, EDI, di),
        }
    }

    inline fn setA(self: *Cpu, comptime A: type, i: u3, v: A) void {
        if (A == u16) self.regs.set16(i, v) else self.regs.r[i] = v;
    }

    inline fn strIter(self: *Cpu, bus: anytype, comptime k: Str, comptime T: type, comptime A: type, sb: u32, eb: u32, si: *A, di: *A, d: A, port: u16, acc: T) void {
        switch (k) {
            .movs => {
                wrM(bus, T, eb +% di.*, rdM(bus, T, sb +% si.*));
                si.* +%= d;
                di.* +%= d;
            },
            .cmps => {
                const a = rdM(bus, T, sb +% si.*);
                const b = rdM(bus, T, eb +% di.*);
                _ = self.sub(T, a, b, 0);
                si.* +%= d;
                di.* +%= d;
            },
            .stos => {
                wrM(bus, T, eb +% di.*, acc);
                di.* +%= d;
            },
            .lods => {
                self.setR(T, EAX, rdM(bus, T, sb +% si.*));
                si.* +%= d;
            },
            .scas => {
                _ = self.sub(T, self.getR(T, EAX), rdM(bus, T, eb +% di.*), 0);
                di.* +%= d;
            },
            .ins => {
                wrM(bus, T, eb +% di.*, inP(bus, T, port));
                di.* +%= d;
            },
            .outs => {
                outP(bus, T, port, rdM(bus, T, sb +% si.*));
                si.* +%= d;
            },
        }
    }

    inline fn strV(self: *Cpu, bus: anytype, comptime k: Str, p: Pfx, end: u64) void {
        if (p.o32) self.str(bus, k, u32, p, end) else self.str(bus, k, u16, p, end);
    }

    // ── One instruction ─────────────────────────────────────────────────

    fn step(self: *Cpu, bus: anytype, end: u64) ?Exit {
        @setEvalBranchQuota(100_000);
        self.ins_ip = self.regs.eip;
        var p: Pfx = .{};
        var npfx: u8 = 0;
        const r = &self.regs;
        sw: switch (self.fetch8(bus)) {
            // Prefixes.
            0x26, 0x2E, 0x36, 0x3E => |op| {
                p.seg = @truncate((op >> 3) & 3);
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },
            0x64, 0x65 => |op| {
                p.seg = if (op == 0x64) FS else GS;
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },
            0x66 => {
                p.o32 = true;
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },
            0x67 => {
                p.a32 = true;
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },
            0xF0 => {
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },
            0xF2, 0xF3 => |op| {
                p.rep = if (op == 0xF3) 1 else 2;
                npfx += 1;
                if (npfx > 14) return self.fault(bus, 13);
                continue :sw self.fetch8(bus);
            },

            // ALU.
            0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38 => |op| self.aluEG(bus, u8, p, @truncate(op >> 3), false),
            0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39 => |op| if (p.o32)
                self.aluEG(bus, u32, p, @truncate(op >> 3), false)
            else
                self.aluEG(bus, u16, p, @truncate(op >> 3), false),
            0x02, 0x0A, 0x12, 0x1A, 0x22, 0x2A, 0x32, 0x3A => |op| self.aluEG(bus, u8, p, @truncate(op >> 3), true),
            0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B => |op| if (p.o32)
                self.aluEG(bus, u32, p, @truncate(op >> 3), true)
            else
                self.aluEG(bus, u16, p, @truncate(op >> 3), true),
            0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C => |op| self.aluAI(bus, u8, @truncate(op >> 3)),
            0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D => |op| if (p.o32)
                self.aluAI(bus, u32, @truncate(op >> 3))
            else
                self.aluAI(bus, u16, @truncate(op >> 3)),

            // Segment pushes and pops.
            0x06, 0x0E, 0x16, 0x1E => |op| self.pushV(bus, p, r.seg[op >> 3]),
            0x07, 0x17, 0x1F => |op| self.loadSeg(@truncate(op >> 3), @truncate(self.popV(bus, p))),

            0x27 => self.daa(false),
            0x2F => self.daa(true),
            0x37 => self.aaa(false),
            0x3F => self.aaa(true),

            0x40...0x47 => |op| if (p.o32)
                self.setR(u32, @truncate(op), self.inc(u32, r.r[op & 7]))
            else
                self.setR(u16, @truncate(op), self.inc(u16, @truncate(r.r[op & 7]))),
            0x48...0x4F => |op| if (p.o32)
                self.setR(u32, @truncate(op), self.dec(u32, r.r[op & 7]))
            else
                self.setR(u16, @truncate(op), self.dec(u16, @truncate(r.r[op & 7]))),
            0x50...0x57 => |op| self.pushV(bus, p, r.r[op & 7]),
            0x58...0x5F => |op| {
                const v = self.popV(bus, p);
                if (p.o32) r.r[op & 7] = v else r.set16(@truncate(op), @truncate(v));
            },

            0x60 => if (p.o32) self.pusha(bus, u32) else self.pusha(bus, u16),
            0x61 => if (p.o32) self.popa(bus, u32) else self.popa(bus, u16),
            0x62 => return if (p.o32) self.bound(bus, u32, p) else self.bound(bus, u16, p),
            0x63 => return self.ud(bus, 0x63), // ARPL: protected mode only

            0x68 => if (p.o32) self.push32(bus, self.fetch32(bus)) else self.push16(bus, self.fetch16(bus)),
            0x6A => self.pushV(bus, p, sx8(u32, self.fetch8(bus))),
            0x69 => if (p.o32) self.imul3(bus, u32, p, false) else self.imul3(bus, u16, p, false),
            0x6B => if (p.o32) self.imul3(bus, u32, p, true) else self.imul3(bus, u16, p, true),
            0x6C => self.str(bus, .ins, u8, p, end),
            0x6D => self.strV(bus, .ins, p, end),
            0x6E => self.str(bus, .outs, u8, p, end),
            0x6F => self.strV(bus, .outs, p, end),

            0x70...0x7F => |op| {
                const d = self.fetch8(bus);
                if (self.cond(@truncate(op))) self.jrel(sx8(u32, d));
            },

            0x80, 0x82 => self.grp1(bus, u8, p, false),
            0x81 => if (p.o32) self.grp1(bus, u32, p, false) else self.grp1(bus, u16, p, false),
            0x83 => if (p.o32) self.grp1(bus, u32, p, true) else self.grp1(bus, u16, p, true),
            0x84 => {
                const m = self.modrm(bus, p);
                _ = self.logic(u8, self.rdE(bus, u8, m) & self.getR(u8, m.reg));
            },
            0x85 => {
                const m = self.modrm(bus, p);
                if (p.o32) {
                    _ = self.logic(u32, self.rdE(bus, u32, m) & self.getR(u32, m.reg));
                } else {
                    _ = self.logic(u16, self.rdE(bus, u16, m) & self.getR(u16, m.reg));
                }
            },
            0x86 => self.xchgEG(bus, u8, p),
            0x87 => if (p.o32) self.xchgEG(bus, u32, p) else self.xchgEG(bus, u16, p),
            0x88 => {
                const m = self.modrm(bus, p);
                self.wrE(bus, u8, m, self.getR(u8, m.reg));
            },
            0x89 => {
                const m = self.modrm(bus, p);
                if (p.o32) self.wrE(bus, u32, m, r.r[m.reg]) else self.wrE(bus, u16, m, @truncate(r.r[m.reg]));
            },
            0x8A => {
                const m = self.modrm(bus, p);
                self.setR(u8, m.reg, self.rdE(bus, u8, m));
            },
            0x8B => {
                const m = self.modrm(bus, p);
                if (p.o32) r.r[m.reg] = self.rdE(bus, u32, m) else r.set16(m.reg, self.rdE(bus, u16, m));
            },
            0x8C => {
                const m = self.modrm(bus, p);
                if (m.reg > 5) return self.ud(bus, 0x8C);
                const v = r.seg[m.reg];
                if (m.mem) {
                    bus.wr16(m.lin, v);
                } else if (p.o32) {
                    r.r[m.rm] = v;
                } else {
                    r.set16(m.rm, v);
                }
            },
            0x8D => {
                const m = self.modrm(bus, p);
                if (!m.mem) return self.ud(bus, 0x8D);
                if (p.o32) r.r[m.reg] = m.off else r.set16(m.reg, @truncate(m.off));
            },
            0x8E => {
                const m = self.modrm(bus, p);
                if (m.reg == CS or m.reg > 5) return self.ud(bus, 0x8E);
                self.loadSeg(m.reg, self.rdE(bus, u16, m));
            },
            0x8F => {
                // (the address is formed after the pop, as the 386 does)
                const v = self.popV(bus, p);
                const m = self.modrm(bus, p);
                if (p.o32) self.wrE(bus, u32, m, v) else self.wrE(bus, u16, m, @truncate(v));
            },

            0x90 => {}, // NOP, PAUSE
            0x91...0x97 => |op| {
                const i: u3 = @truncate(op);
                if (p.o32) {
                    std.mem.swap(u32, &r.r[EAX], &r.r[i]);
                } else {
                    const a = r.get16(EAX);
                    r.set16(EAX, r.get16(i));
                    r.set16(i, a);
                }
            },
            0x98 => if (p.o32) {
                r.r[EAX] = sx16(r.get16(EAX));
            } else {
                r.set16(EAX, sx8(u16, r.get8(0)));
            },
            0x99 => if (p.o32) {
                r.r[EDX] = if (r.r[EAX] & 0x8000_0000 != 0) 0xFFFF_FFFF else 0;
            } else {
                r.set16(EDX, if (r.r[EAX] & 0x8000 != 0) 0xFFFF else 0);
            },
            0x9A => {
                const off: u32 = if (p.o32) self.fetch32(bus) else self.fetch16(bus);
                const sel = self.fetch16(bus);
                self.pushV(bus, p, r.seg[CS]);
                self.pushV(bus, p, r.eip);
                r.setSeg(CS, sel);
                r.eip = off & 0xFFFF;
            },
            0x9B => {}, // WAIT (no #MF: see cpu_x87.sig)
            0x9C => if (p.o32) self.push32(bus, r.flags & 0x00FC_FFFF) else self.push16(bus, @truncate(r.flags)),
            0x9D => self.popf(bus, p),
            0x9E => r.flags = (r.flags & ~@as(u32, 0xD5)) | (r.get8(4) & 0xD5),
            0x9F => r.set8(4, @as(u8, @truncate(r.flags & 0xD5)) | 0x02),

            0xA0...0xA3 => |op| {
                const off: u32 = if (p.a32) self.fetch32(bus) else self.fetch16(bus);
                const a = r.base[dataSeg(p)] +% off;
                switch (op) {
                    0xA0 => r.set8(0, bus.rd8(a)),
                    0xA1 => if (p.o32) {
                        r.r[EAX] = bus.rd32(a);
                    } else {
                        r.set16(EAX, bus.rd16(a));
                    },
                    0xA2 => bus.wr8(a, r.get8(0)),
                    else => if (p.o32) bus.wr32(a, r.r[EAX]) else bus.wr16(a, r.get16(EAX)),
                }
            },
            0xA4 => self.str(bus, .movs, u8, p, end),
            0xA5 => self.strV(bus, .movs, p, end),
            0xA6 => self.str(bus, .cmps, u8, p, end),
            0xA7 => self.strV(bus, .cmps, p, end),
            0xA8 => _ = self.logic(u8, r.get8(0) & self.fetch8(bus)),
            0xA9 => if (p.o32) {
                _ = self.logic(u32, r.r[EAX] & self.fetch32(bus));
            } else {
                _ = self.logic(u16, r.get16(EAX) & self.fetch16(bus));
            },
            0xAA => self.str(bus, .stos, u8, p, end),
            0xAB => self.strV(bus, .stos, p, end),
            0xAC => self.str(bus, .lods, u8, p, end),
            0xAD => self.strV(bus, .lods, p, end),
            0xAE => self.str(bus, .scas, u8, p, end),
            0xAF => self.strV(bus, .scas, p, end),

            0xB0...0xB7 => |op| r.set8(@truncate(op), self.fetch8(bus)),
            0xB8...0xBF => |op| if (p.o32) {
                r.r[op & 7] = self.fetch32(bus);
            } else {
                r.set16(@truncate(op), self.fetch16(bus));
            },

            0xC0 => self.grp2(bus, u8, p, .imm),
            0xC1 => if (p.o32) self.grp2(bus, u32, p, .imm) else self.grp2(bus, u16, p, .imm),
            0xD0 => self.grp2(bus, u8, p, .one),
            0xD1 => if (p.o32) self.grp2(bus, u32, p, .one) else self.grp2(bus, u16, p, .one),
            0xD2 => self.grp2(bus, u8, p, .cl),
            0xD3 => if (p.o32) self.grp2(bus, u32, p, .cl) else self.grp2(bus, u16, p, .cl),

            0xC2 => {
                const n = self.fetch16(bus);
                r.eip = self.popV(bus, p) & 0xFFFF;
                self.addSp(n);
            },
            0xC3 => r.eip = self.popV(bus, p) & 0xFFFF,
            0xC4 => return if (p.o32) self.lseg(bus, u32, p, ES, 0xC4) else self.lseg(bus, u16, p, ES, 0xC4),
            0xC5 => return if (p.o32) self.lseg(bus, u32, p, DS, 0xC5) else self.lseg(bus, u16, p, DS, 0xC5),
            0xC6 => {
                const m = self.modrm(bus, p);
                self.wrE(bus, u8, m, self.fetch8(bus));
            },
            0xC7 => {
                const m = self.modrm(bus, p);
                if (p.o32) self.wrE(bus, u32, m, self.fetch32(bus)) else self.wrE(bus, u16, m, self.fetch16(bus));
            },
            0xC8 => if (p.o32) self.enter(bus, u32) else self.enter(bus, u16),
            0xC9 => if (p.o32) self.leave(bus, u32) else self.leave(bus, u16),
            0xCA, 0xCB => |op| {
                const n: u16 = if (op == 0xCA) self.fetch16(bus) else 0;
                const ip = self.popV(bus, p);
                const cs = self.popV(bus, p);
                r.eip = ip & 0xFFFF;
                r.setSeg(CS, @truncate(cs));
                self.addSp(n);
            },
            0xCC => self.interrupt(bus, 3),
            0xCD => {
                const v = self.fetch8(bus);
                self.interrupt(bus, v);
            },
            0xCE => if (r.flags & OF != 0) self.interrupt(bus, 4),
            0xCF => self.iret(bus, p),

            0xD4 => {
                const b = self.fetch8(bus);
                if (b == 0) return self.fault(bus, 0);
                const al = r.get8(0);
                r.set8(4, al / b);
                r.set8(0, al % b);
                self.setArith(szp(u8, al % b));
            },
            0xD5 => {
                const b = self.fetch8(bus);
                const al: u8 = r.get8(0) +% r.get8(4) *% b;
                r.set16(EAX, al);
                self.setArith(szp(u8, al));
            },
            0xD6 => r.set8(0, if (r.flags & CF != 0) 0xFF else 0), // SALC
            0xD7 => {
                const off: u32 = if (p.a32) r.r[EBX] +% r.get8(0) else @as(u16, @truncate(r.r[EBX])) +% r.get8(0);
                r.set8(0, bus.rd8(r.base[dataSeg(p)] +% off));
            },
            0xD8...0xDF => |op| {
                if (self.cr0 & CR0_EM != 0) return self.fault(bus, 7);
                const b = self.fetch8(bus);
                var lin: u32 = 0;
                if (b < 0xC0) lin = self.modrmB(bus, p, b).lin;
                if (!self.fpu.esc(bus, r, op, b, lin, p.o32, r.base[CS] +% self.ins_ip))
                    return self.ud(bus, (@as(u32, op) << 8) | b);
            },

            0xE0...0xE2 => |op| {
                const d = sx8(u32, self.fetch8(bus));
                var nz: bool = undefined;
                if (p.a32) {
                    r.r[ECX] -%= 1;
                    nz = r.r[ECX] != 0;
                } else {
                    const cx = r.get16(ECX) -% 1;
                    r.set16(ECX, cx);
                    nz = cx != 0;
                }
                const take = switch (op) {
                    0xE0 => nz and r.flags & ZF == 0,
                    0xE1 => nz and r.flags & ZF != 0,
                    else => nz,
                };
                if (take) self.jrel(d);
            },
            0xE3 => {
                const d = sx8(u32, self.fetch8(bus));
                const z = if (p.a32) r.r[ECX] == 0 else r.get16(ECX) == 0;
                if (z) self.jrel(d);
            },
            0xE4, 0xE5, 0xEC, 0xED => |op| {
                const port: u16 = if (op < 0xEC) self.fetch8(bus) else r.get16(EDX);
                if (op & 1 == 0) {
                    r.set8(0, bus.in8(port));
                } else if (p.o32) {
                    r.r[EAX] = bus.in32(port);
                } else {
                    r.set16(EAX, bus.in16(port));
                }
                self.poll = true;
            },
            0xE6, 0xE7, 0xEE, 0xEF => |op| {
                const port: u16 = if (op < 0xEE) self.fetch8(bus) else r.get16(EDX);
                if (op & 1 == 0) {
                    bus.out8(port, r.get8(0));
                } else if (p.o32) {
                    bus.out32(port, r.r[EAX]);
                } else {
                    bus.out16(port, r.get16(EAX));
                }
                self.poll = true;
            },
            0xE8 => if (p.o32) {
                const d = self.fetch32(bus);
                self.push32(bus, r.eip);
                self.jrel(d);
            } else {
                const d = self.fetch16(bus);
                self.push16(bus, @truncate(r.eip));
                self.jrel(d);
            },
            0xE9 => {
                const d: u32 = if (p.o32) self.fetch32(bus) else self.fetch16(bus);
                self.jrel(d);
            },
            0xEA => {
                const off: u32 = if (p.o32) self.fetch32(bus) else self.fetch16(bus);
                const sel = self.fetch16(bus);
                r.setSeg(CS, sel);
                r.eip = off & 0xFFFF;
            },
            0xEB => {
                const d = self.fetch8(bus);
                self.jrel(sx8(u32, d));
            },

            0xF1 => self.interrupt(bus, 1), // ICEBP
            0xF4 => {
                self.halted = true;
                return .halt;
            },
            0xF5 => r.flags ^= CF,
            0xF6 => return self.grp3(bus, u8, p),
            0xF7 => return if (p.o32) self.grp3(bus, u32, p) else self.grp3(bus, u16, p),
            0xF8 => r.flags &= ~CF,
            0xF9 => r.flags |= CF,
            0xFA => r.flags &= ~IF,
            0xFB => {
                if (r.flags & IF == 0) self.shadow = true;
                r.flags |= IF;
                self.poll = true;
            },
            0xFC => r.flags &= ~DF,
            0xFD => r.flags |= DF,
            0xFE => {
                const b = self.fetch8(bus);
                if (b == TRAP1 or b == TRAP1_FAR) {
                    const v = self.fetch8(bus);
                    const id: u16 = if (b == TRAP1_FAR) 0x100 + @as(u16, v) else v;
                    self.poll = true;
                    if (bus.hle(self, id)) return null;
                    self.regs.eip = self.ins_ip;
                    return .wait;
                }
                const m = self.modrmB(bus, p, b);
                switch (m.reg) {
                    0 => self.wrE(bus, u8, m, self.inc(u8, self.rdE(bus, u8, m))),
                    1 => self.wrE(bus, u8, m, self.dec(u8, self.rdE(bus, u8, m))),
                    else => return self.ud(bus, 0xFE00 | @as(u32, b)),
                }
            },
            0xFF => return if (p.o32) self.grp5(bus, u32, p) else self.grp5(bus, u16, p),

            0x0F => return self.step0F(bus, p),
        }
        return null;
    }

    /// The two-byte opcodes.
    fn step0F(self: *Cpu, bus: anytype, p: Pfx) ?Exit {
        @setEvalBranchQuota(100_000);
        const r = &self.regs;
        const op = self.fetch8(bus);
        const code: u32 = 0x0F00 | @as(u32, op);
        switch (op) {
            0x01 => return self.grp7(bus, p),
            0x06 => self.cr0 &= ~CR0_TS, // CLTS
            0x08, 0x09 => {}, // INVD, WBINVD
            0x20...0x23 => {
                // MOV r32, CRn / DRn and back (the mod bits are ignored).
                const b = self.fetch8(bus);
                const n: u3 = @truncate(b >> 3);
                const g: u3 = @truncate(b);
                switch (op) {
                    0x20 => r.r[g] = switch (n) {
                        0 => self.cr0,
                        2 => self.cr2,
                        3 => self.cr3,
                        else => return self.ud(bus, (code << 8) | b),
                    },
                    0x21 => r.r[g] = self.dr[n],
                    0x22 => switch (n) {
                        0 => {
                            const v = r.r[g];
                            if (v & CR0_PE != 0) return self.unsupported((code << 8) | b);
                            self.cr0 = v | CR0_ET;
                        },
                        2 => self.cr2 = r.r[g],
                        3 => self.cr3 = r.r[g],
                        else => return self.ud(bus, (code << 8) | b),
                    },
                    else => self.dr[n] = r.r[g],
                }
            },
            0x24, 0x26 => {
                // MOV to and from the test registers (TR3-TR7): read 0.
                const b = self.fetch8(bus);
                if (op == 0x24) r.r[b & 7] = 0;
            },
            0x80...0x8F => {
                const d: u32 = if (p.o32) self.fetch32(bus) else sx16(self.fetch16(bus));
                if (self.cond(@truncate(op))) self.jrel(d);
            },
            0x90...0x9F => {
                const m = self.modrm(bus, p);
                self.wrE(bus, u8, m, @intFromBool(self.cond(@truncate(op))));
            },
            0xA0, 0xA8 => self.pushV(bus, p, r.seg[if (op == 0xA0) FS else GS]),
            0xA1, 0xA9 => r.setSeg(if (op == 0xA1) FS else GS, @truncate(self.popV(bus, p))),
            0xA2 => self.cpuid(),
            0xA3, 0xAB, 0xB3, 0xBB => {
                const kind: u2 = switch (op) {
                    0xA3 => 0,
                    0xAB => 1,
                    0xB3 => 2,
                    else => 3,
                };
                const m = self.modrm(bus, p);
                if (p.o32) self.btOp(bus, u32, p, m, r.r[m.reg], true, kind) else self.btOp(bus, u16, p, m, r.get16(m.reg), true, kind);
            },
            0xBA => {
                const m = self.modrm(bus, p);
                const b = self.fetch8(bus);
                if (m.reg < 4) return self.ud(bus, (code << 8) | (@as(u32, m.reg) << 3));
                const kind: u2 = @truncate(m.reg);
                if (p.o32) self.btOp(bus, u32, p, m, b, false, kind) else self.btOp(bus, u16, p, m, b, false, kind);
            },
            0xA4, 0xA5, 0xAC, 0xAD => {
                const left = op < 0xA8;
                const imm = op & 1 == 0;
                if (p.o32) self.shxd(bus, u32, p, left, imm) else self.shxd(bus, u16, p, left, imm);
            },
            0xAF => {
                const m = self.modrm(bus, p);
                if (p.o32) {
                    r.r[m.reg] = self.imul2(u32, r.r[m.reg], self.rdE(bus, u32, m));
                } else {
                    r.set16(m.reg, self.imul2(u16, r.get16(m.reg), self.rdE(bus, u16, m)));
                }
            },
            0xB0 => self.cmpxchg(bus, u8, p),
            0xB1 => if (p.o32) self.cmpxchg(bus, u32, p) else self.cmpxchg(bus, u16, p),
            0xB2, 0xB4, 0xB5 => {
                const s: u3 = switch (op) {
                    0xB2 => SS,
                    0xB4 => FS,
                    else => GS,
                };
                return if (p.o32) self.lseg(bus, u32, p, s, code) else self.lseg(bus, u16, p, s, code);
            },
            0xB6, 0xB7, 0xBE, 0xBF => {
                const m = self.modrm(bus, p);
                const v: u32 = switch (op) {
                    0xB6 => self.rdE(bus, u8, m),
                    0xB7 => self.rdE(bus, u16, m),
                    0xBE => sx8(u32, self.rdE(bus, u8, m)),
                    else => sx16(self.rdE(bus, u16, m)),
                };
                if (p.o32) r.r[m.reg] = v else r.set16(m.reg, @truncate(v));
            },
            0xBC, 0xBD => if (p.o32) self.bitScan(bus, u32, p, op == 0xBD) else self.bitScan(bus, u16, p, op == 0xBD),
            0xC0 => self.xadd(bus, u8, p),
            0xC1 => if (p.o32) self.xadd(bus, u32, p) else self.xadd(bus, u16, p),
            0xC8...0xCF => r.r[op & 7] = @byteSwap(r.r[op & 7]),
            // 0F 00 (SLDT...VERW), LAR, LSL: #UD in real mode, as is all
            // that a 486 lacks (UD2, RDTSC, CMOV, MMX...).
            else => return self.ud(bus, code),
        }
        return null;
    }

    /// 0F 01: SGDT SIDT LGDT LIDT SMSW LMSW INVLPG.
    fn grp7(self: *Cpu, bus: anytype, p: Pfx) ?Exit {
        const m = self.modrm(bus, p);
        const code: u32 = 0x0F0100 | (@as(u32, m.reg) << 3);
        switch (m.reg) {
            0, 1 => {
                if (!m.mem) return self.ud(bus, code);
                const lim = if (m.reg == 0) self.gdt_limit else self.idt_limit;
                const base = if (m.reg == 0) self.gdt_base else self.idt_base;
                bus.wr16(m.lin, lim);
                bus.wr32(m.lin +% 2, if (p.o32) base else base & 0x00FF_FFFF);
            },
            2, 3 => {
                if (!m.mem) return self.ud(bus, code);
                const lim = bus.rd16(m.lin);
                var base = bus.rd32(m.lin +% 2);
                if (!p.o32) base &= 0x00FF_FFFF;
                if (m.reg == 2) {
                    self.gdt_limit = lim;
                    self.gdt_base = base;
                } else {
                    self.idt_limit = lim;
                    self.idt_base = base;
                }
            },
            4 => {
                if (m.mem) {
                    bus.wr16(m.lin, @truncate(self.cr0));
                } else if (p.o32) {
                    self.regs.r[m.rm] = self.cr0;
                } else {
                    self.regs.set16(m.rm, @truncate(self.cr0));
                }
            },
            6 => {
                const v = self.rdE(bus, u16, m);
                // (LMSW sets PE, MP, EM, TS; it cannot clear PE)
                const n = (self.cr0 & ~@as(u32, 0xE)) | (v & 0xF);
                if (n & CR0_PE != 0) return self.unsupported(code);
                self.cr0 = n;
            },
            7 => if (!m.mem) return self.ud(bus, code), // INVLPG: no TLB
            else => return self.ud(bus, code),
        }
        return null;
    }

    fn cpuid(self: *Cpu) void {
        const r = &self.regs.r;
        switch (r[EAX]) {
            0 => {
                r[EAX] = 1;
                r[EBX] = 0x756E_6547; // "Genu"
                r[EDX] = 0x4965_6E69; // "ineI"
                r[ECX] = 0x6C65_746E; // "ntel"
            },
            else => {
                r[EAX] = SIGNATURE;
                r[EBX] = 0;
                r[ECX] = 0;
                r[EDX] = 1; // FPU on chip
            },
        }
    }
};
