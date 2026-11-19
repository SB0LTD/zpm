//! Protected mode for cpu.sig: descriptors and the segment loads; far
//! JMP/CALL/RETF through code segments and call gates with the
//! inter-privilege stack switch from the TSS; interrupts and exceptions
//! through the IDT, IRET, double and triple faults; LLDT, LTR, LAR, LSL,
//! VERR, VERW; the I/O permission bitmap; paging with its TLB. Written
//! from Intel's 80386/80486 Programmer's Reference; no emulator's code.
//!
//! Everything here takes the machine's own bus (`b`, physical addresses)
//! and leaves the CPU's state alone until nothing more can fault: an
//! instruction that faults part way is restarted as it began.
//!
//! Task switches (386 and 286 TSSes): far JMP/CALL to a TSS or a task
//! gate, interrupts and exceptions through task gates in the IDT, IRET
//! with NT back to the TSS the back link names. An error the new task's
//! own state causes (its LDT, segments, EIP) is an exception in the new
//! task, the switch done (`keep`: the faulting instruction's EIP, ESP and
//! EFLAGS are not put back).
//!
//! Not here (the CPU stops with .fault, and fault_op says which):
//! virtual-8086 mode (an IRET or a task switch that would set VM:
//! FAULT_V86). The TSS's debug trap bit is ignored.

const std = @import("std");
const cpu_mod = @import("cpu.sig");
const regs_mod = @import("regs.sig");
const Cpu = cpu_mod.Cpu;
const Exc = cpu_mod.Exc;
const Exit = cpu_mod.Exit;
const rdM = cpu_mod.rdM;
const wrM = cpu_mod.wrM;

const ES = regs_mod.ES;
const CS = regs_mod.CS;
const SS = regs_mod.SS;
const DS = regs_mod.DS;
const FS = regs_mod.FS;
const GS = regs_mod.GS;
const ESP = regs_mod.ESP;

const TF = regs_mod.TF;
const IF = regs_mod.IF;
const FIXED = regs_mod.FIXED;
const NT = cpu_mod.NT;
const RF = cpu_mod.RF;
const VM = cpu_mod.VM;
const IOPL = cpu_mod.IOPL;

// The attribute bits (Regs.attr: descriptor bits 40-47, 52-55).
const A_ACC: u16 = 0x01;
const A_RW: u16 = 0x02; // readable code, writable data
const A_DC: u16 = 0x04; // conforming code, expand-down data
const A_CODE: u16 = 0x08;
const A_S: u16 = 0x10; // code or data (not a system descriptor)
const A_P: u16 = 0x80;
const A_DB: u16 = 0x4000;

/// A descriptor as it is in its table.
pub const Desc = struct {
    lo: u32,
    hi: u32,
    /// Its linear address (for the accessed and busy bits).
    at: u32,

    pub fn base(d: Desc) u32 {
        return (d.lo >> 16) | ((d.hi & 0xFF) << 16) | (d.hi & 0xFF00_0000);
    }
    /// The limit in bytes (G: 4 KiB units, the low 12 bits all ones).
    pub fn limit(d: Desc) u32 {
        const l = (d.lo & 0xFFFF) | (d.hi & 0x000F_0000);
        return if (d.hi & (1 << 23) != 0) (l << 12) | 0xFFF else l;
    }
    pub fn attr(d: Desc) u16 {
        return @truncate((d.hi >> 8) & 0xF0FF);
    }
    pub fn typ(d: Desc) u4 {
        return @truncate(d.hi >> 8);
    }
    /// S: a code or data segment.
    pub fn seg(d: Desc) bool {
        return d.hi & (1 << 12) != 0;
    }
    pub fn dpl(d: Desc) u2 {
        return @truncate(d.hi >> 13);
    }
    pub fn present(d: Desc) bool {
        return d.hi & (1 << 15) != 0;
    }
    pub fn code(d: Desc) bool {
        return d.seg() and d.typ() & 8 != 0;
    }
    pub fn conforming(d: Desc) bool {
        return d.code() and d.typ() & 4 != 0;
    }
    pub fn readable(d: Desc) bool {
        return d.seg() and (d.typ() & 8 == 0 or d.typ() & 2 != 0);
    }
    pub fn writable(d: Desc) bool {
        return d.seg() and d.typ() & 0xA == 2;
    }
};

// ── Segment caches ──────────────────────────────────────────────────────

const Bounds = struct { lo: u32, rhi: i64, whi: i64 };

/// The offsets a segment's cache allows: [lo, rhi] for reads, [lo, whi]
/// for writes (-1: none). Expand-down data: above the limit, to 64 KiB
/// or 4 GiB by B. Not present (or null): nothing.
fn bounds(a: u16, lim: u32) Bounds {
    var b = Bounds{ .lo = 0, .rhi = -1, .whi = -1 };
    if (a & A_P == 0 or a & A_S == 0) return b;
    if (a & A_CODE != 0) {
        if (a & A_RW != 0) b.rhi = lim;
    } else if (a & A_DC != 0) {
        if (lim == 0xFFFF_FFFF) return b;
        b.lo = lim + 1;
        const top: i64 = if (a & A_DB != 0) 0xFFFF_FFFF else 0xFFFF;
        b.rhi = top;
        if (a & A_RW != 0) b.whi = top;
    } else {
        b.rhi = lim;
        if (a & A_RW != 0) b.whi = lim;
    }
    return b;
}

/// The core's view of segment s from its cache in `regs`.
pub fn syncSeg(c: *Cpu, s: u3) void {
    const a = c.regs.attr[s];
    const lim = c.regs.limit[s];
    const b = bounds(a, lim);
    c.seg_lo[s] = b.lo;
    c.seg_rhi[s] = b.rhi;
    c.seg_whi[s] = b.whi;
    const bit = @as(u8, 1) << s;
    if (b.lo == 0 and b.rhi == 0xFFFF_FFFF and b.whi == 0xFFFF_FFFF) c.seg_flat |= bit else c.seg_flat &= ~bit;
    if (s == CS) {
        c.code32 = a & A_DB != 0;
        c.ip_wrap = if (c.code32) 0xFFFF_FFFF else 0xFFFF;
        c.fetch_hi = lim;
        c.tlb.fw_len = 0;
    } else if (s == SS) {
        c.stack32 = a & A_DB != 0;
    }
}

/// All of it (on entering protected mode; harmless at any time).
pub fn syncAll(c: *Cpu) void {
    c.paging = c.cr0 & cpu_mod.CR0_PG != 0;
    c.tlb.fw_len = 0;
    for (0..6) |i| syncSeg(c, @intCast(i));
}

fn setCache(c: *Cpu, s: u3, sel: u16, d: Desc) void {
    c.regs.seg[s] = sel;
    c.regs.base[s] = d.base();
    c.regs.limit[s] = d.limit();
    c.regs.attr[s] = d.attr() | A_ACC;
    syncSeg(c, s);
}

/// A null selector in DS, ES, FS or GS: unusable until loaded again.
fn setNull(c: *Cpu, s: u3, sel: u16) void {
    c.regs.seg[s] = sel;
    c.regs.attr[s] = 0;
    syncSeg(c, s);
}

// ── Linear memory (system accesses are the supervisor's) ────────────────

inline fn rdLin(c: *Cpu, b: anytype, comptime T: type, a: u32, user: bool) Exc!T {
    return rdSlow(c, b, T, a, user);
}

inline fn wrLin(c: *Cpu, b: anytype, comptime T: type, a: u32, v: T, user: bool) Exc!void {
    return wrSlow(c, b, T, a, v, user);
}

// ── Descriptors ─────────────────────────────────────────────────────────

/// The descriptor `sel` names, or null if none (a null selector, an LDT
/// selector with no LDT, past the table's limit).
pub fn peek(c: *Cpu, b: anytype, sel: u16) Exc!?Desc {
    const off: u32 = sel & 0xFFF8;
    var base: u32 = c.gdt_base;
    var lim: u32 = c.gdt_limit;
    if (sel & 4 != 0) {
        if (c.ldtr & 0xFFFC == 0) return null;
        base = c.ldt_base;
        lim = c.ldt_limit;
    } else if (off == 0) {
        return null;
    }
    if (off + 7 > lim) return null;
    const at = base +% off;
    const lo = try rdLin(c, b, u32, at, false);
    const hi = try rdLin(c, b, u32, at +% 4, false);
    return Desc{ .lo = lo, .hi = hi, .at = at };
}

/// The same, #GP(sel) if there is none.
pub fn desc(c: *Cpu, b: anytype, sel: u16) Exc!Desc {
    return (try peek(c, b, sel)) orelse return c.raise(13, sel & 0xFFFC);
}

/// Sets a segment descriptor's accessed bit.
fn touch(c: *Cpu, b: anytype, d: Desc) Exc!void {
    if (d.seg() and d.hi & 0x100 == 0) try wrLin(c, b, u8, d.at +% 5, @as(u8, @truncate(d.hi >> 8)) | 1, false);
}

/// MOV/POP Sreg, LDS/LES/LFS/LGS/LSS: SS takes a writable data segment
/// at CPL (#GP(sel), #SS(sel) if not present); DS ES FS GS take data or
/// readable code that CPL and RPL may use (#GP(sel), #NP(sel)), or null.
pub fn loadSeg(c: *Cpu, b: anytype, s: u3, sel: u16) Exc!void {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) {
        if (s == SS) return c.raise(13, 0);
        setNull(c, s, sel);
        return;
    }
    const d = try desc(c, b, sel);
    const rpl: u2 = @truncate(sel);
    if (s == SS) {
        if (rpl != c.cpl or !d.writable() or d.dpl() != c.cpl) return c.raise(13, se);
        if (!d.present()) return c.raise(12, se);
    } else {
        if (!d.readable()) return c.raise(13, se);
        if (!d.conforming() and (d.dpl() < c.cpl or d.dpl() < rpl)) return c.raise(13, se);
        if (!d.present()) return c.raise(11, se);
    }
    try touch(c, b, d);
    setCache(c, s, sel, d);
}

/// After a return to an outer level: DS ES FS GS that it may not use
/// (data or non-conforming code more privileged than CPL) become null.
fn dropSegs(c: *Cpu) void {
    for ([_]u3{ ES, DS, FS, GS }) |s| {
        const a = c.regs.attr[s];
        if (a & A_P == 0 or a & A_S == 0) continue;
        const conforming = a & A_CODE != 0 and a & A_DC != 0;
        const dpl: u2 = @truncate(a >> 5);
        if (!conforming and dpl < c.cpl) setNull(c, s, 0);
    }
}

// ── Stacks ──────────────────────────────────────────────────────────────

/// A stack being pushed or popped by a far transfer: changes reach ESP
/// only by `commit`, once nothing else can fault.
const Stk = struct {
    base: u32,
    sp: u32,
    big: bool,
    lo: u32,
    rhi: i64,
    whi: i64,
    user: bool,
    /// #SS's error code (the new stack's selector; 0 for the current).
    err: u32,

    fn current(c: *Cpu) Stk {
        return .{
            .base = c.regs.base[SS],
            .sp = if (c.stack32) c.regs.r[ESP] else c.regs.r[ESP] & 0xFFFF,
            .big = c.stack32,
            .lo = c.seg_lo[SS],
            .rhi = c.seg_rhi[SS],
            .whi = c.seg_whi[SS],
            .user = c.cpl == 3,
            .err = 0,
        };
    }

    fn of(d: Desc, sp: u32, sel: u16, user: bool) Stk {
        const bd = bounds(d.attr(), d.limit());
        const b32 = d.hi & (1 << 22) != 0;
        return .{
            .base = d.base(),
            .sp = if (b32) sp else sp & 0xFFFF,
            .big = b32,
            .lo = bd.lo,
            .rhi = bd.rhi,
            .whi = bd.whi,
            .user = user,
            .err = sel & 0xFFFC,
        };
    }

    fn push(st: *Stk, c: *Cpu, b: anytype, comptime T: type, v: T) Exc!void {
        const n: u32 = @sizeOf(T);
        var sp = st.sp -% n;
        if (!st.big) sp &= 0xFFFF;
        if (@as(i64, sp) + (n - 1) > st.whi or sp < st.lo) return c.raise(12, st.err);
        try wrLin(c, b, T, st.base +% sp, v, st.user);
        st.sp = sp;
    }

    fn pop(st: *Stk, c: *Cpu, b: anytype, comptime T: type) Exc!T {
        const n: u32 = @sizeOf(T);
        const sp = st.sp;
        if (@as(i64, sp) + (n - 1) > st.rhi or sp < st.lo) return c.raise(12, st.err);
        const v = try rdLin(c, b, T, st.base +% sp, st.user);
        st.skip(n);
        return v;
    }

    fn skip(st: *Stk, n: u32) void {
        st.sp +%= n;
        if (!st.big) st.sp &= 0xFFFF;
    }

    fn commit(st: *const Stk, c: *Cpu) void {
        if (st.big) c.regs.r[ESP] = st.sp else c.regs.set16(ESP, @truncate(st.sp));
    }
};

fn pushW(st: *Stk, c: *Cpu, b: anytype, wide: bool, v: u32) Exc!void {
    if (wide) return st.push(c, b, u32, v);
    return st.push(c, b, u16, @truncate(v));
}

fn popW(st: *Stk, c: *Cpu, b: anytype, wide: bool) Exc!u32 {
    if (wide) return st.pop(c, b, u32);
    return try st.pop(c, b, u16);
}

const TssStack = struct { ss: u16, esp: u32 };

/// SSn:ESPn from the current TSS (386: at 4 + 8n; 286: SPn at 2 + 4n);
/// #TS(TR) past its limit or with no TSS.
fn tssStack(c: *Cpu, b: anytype, n: u2) Exc!TssStack {
    const terr: u32 = c.tr & 0xFFFC;
    if (c.tr_type & 8 != 0) {
        const off: u32 = 4 + @as(u32, n) * 8;
        if (off + 5 > c.tr_limit) return c.raise(10, terr);
        const esp = try rdLin(c, b, u32, c.tr_base +% off, false);
        const ss = try rdLin(c, b, u16, c.tr_base +% off +% 4, false);
        return .{ .ss = ss, .esp = esp };
    }
    if (c.tr_type == 0) return c.raise(10, terr);
    const off: u32 = 2 + @as(u32, n) * 4;
    if (off + 3 > c.tr_limit) return c.raise(10, terr);
    const sp = try rdLin(c, b, u16, c.tr_base +% off, false);
    const ss = try rdLin(c, b, u16, c.tr_base +% off +% 2, false);
    return .{ .ss = ss, .esp = sp };
}

/// The TSS's stack for level n: a writable data segment at RPL = DPL = n
/// (#TS(sel)), present (#SS(sel)).
fn newSs(c: *Cpu, b: anytype, sel: u16, n: u2, ext: u32) Exc!Desc {
    const se: u32 = (sel & 0xFFFC) | ext;
    if (sel & 0xFFFC == 0) return c.raise(10, ext);
    const d = (try peek(c, b, sel)) orelse return c.raise(10, se);
    if (@as(u2, @truncate(sel)) != n or d.dpl() != n or !d.writable()) return c.raise(10, se);
    if (!d.present()) return c.raise(12, se);
    return d;
}

// ── Far transfers ───────────────────────────────────────────────────────

fn pushRet(st: *Stk, c: *Cpu, b: anytype, wide: bool) Exc!void {
    try pushW(st, c, b, wide, c.regs.seg[CS]);
    try pushW(st, c, b, wide, c.regs.eip);
}

/// Far JMP (call false) or CALL to sel:off: a code segment at this level
/// (conforming: at or above it), or a call gate.
pub fn far(c: *Cpu, b: anytype, sel: u16, off: u32, o32: bool, call: bool) Exc!void {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) return c.raise(13, 0);
    const d = try desc(c, b, sel);
    const rpl: u2 = @truncate(sel);
    if (d.seg()) {
        if (!d.code()) return c.raise(13, se);
        if (d.conforming()) {
            if (d.dpl() > c.cpl) return c.raise(13, se);
        } else if (rpl > c.cpl or d.dpl() != c.cpl) {
            return c.raise(13, se);
        }
        if (!d.present()) return c.raise(11, se);
        if (off > d.limit()) return c.raise(13, 0);
        var st = Stk.current(c);
        if (call) try pushRet(&st, c, b, o32);
        try touch(c, b, d);
        st.commit(c);
        setCache(c, CS, @intCast(se | c.cpl), d);
        c.regs.eip = off;
        return;
    }
    switch (d.typ()) {
        4, 12 => return gate(c, b, sel, d, call),
        1, 9 => {
            if (d.dpl() < c.cpl or d.dpl() < rpl) return c.raise(13, se);
            return taskSwitch(c, b, sel, d, if (call) .call else .jmp, 0);
        },
        5 => {
            if (d.dpl() < c.cpl or d.dpl() < rpl) return c.raise(13, se);
            if (!d.present()) return c.raise(11, se);
            const tsel: u16 = @truncate(d.lo >> 16);
            const td = try taskGateTss(c, b, tsel, 0);
            return taskSwitch(c, b, tsel, td, if (call) .call else .jmp, 0);
        },
        else => return c.raise(13, se),
    }
}

/// Through a call gate: JMP to its code at this level; CALL also to a
/// more privileged non-conforming one, on the TSS's stack for it with
/// the caller's SS:ESP and the gate's count of parameters copied.
fn gate(c: *Cpu, b: anytype, sel: u16, g: Desc, call: bool) Exc!void {
    const se: u32 = sel & 0xFFFC;
    const rpl: u2 = @truncate(sel);
    if (g.dpl() < c.cpl or g.dpl() < rpl) return c.raise(13, se);
    if (!g.present()) return c.raise(11, se);
    const wide = g.typ() == 12;
    const tsel: u16 = @truncate(g.lo >> 16);
    const toff: u32 = if (wide) (g.lo & 0xFFFF) | (g.hi & 0xFFFF_0000) else g.lo & 0xFFFF;
    const tse: u32 = tsel & 0xFFFC;
    if (tse == 0) return c.raise(13, 0);
    const d = try desc(c, b, tsel);
    if (!d.code() or d.dpl() > c.cpl) return c.raise(13, tse);
    if (!d.present()) return c.raise(11, tse);
    if (toff > d.limit()) return c.raise(13, 0);
    if (call and !d.conforming() and d.dpl() < c.cpl) {
        const n = d.dpl();
        const ts = try tssStack(c, b, n);
        const ssd = try newSs(c, b, ts.ss, n, 0);
        var st = Stk.of(ssd, ts.esp, ts.ss, false);
        const old = Stk.current(c);
        const sz: u32 = if (wide) 4 else 2;
        try pushW(&st, c, b, wide, c.regs.seg[SS]);
        try pushW(&st, c, b, wide, c.regs.r[ESP]);
        var i: u32 = g.hi & 0x1F;
        while (i > 0) {
            i -= 1;
            var src = old;
            src.skip(i * sz);
            try pushW(&st, c, b, wide, try popW(&src, c, b, wide));
        }
        try pushRet(&st, c, b, wide);
        try touch(c, b, d);
        try touch(c, b, ssd);
        setCache(c, SS, (ts.ss & 0xFFFC) | n, ssd);
        st.commit(c);
        c.cpl = n;
        setCache(c, CS, @intCast(tse | n), d);
        c.regs.eip = toff;
        return;
    }
    if (!d.conforming() and d.dpl() != c.cpl) return c.raise(13, tse);
    var st = Stk.current(c);
    if (call) try pushRet(&st, c, b, wide);
    try touch(c, b, d);
    st.commit(c);
    setCache(c, CS, @intCast(tse | c.cpl), d);
    c.regs.eip = toff;
}

/// The code segment a RETF or IRET returns to: at RPL >= CPL (#GP(sel)),
/// DPL = RPL (conforming: <= RPL), present (#NP(sel)).
fn retCs(c: *Cpu, b: anytype, sel: u16) Exc!Desc {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) return c.raise(13, 0);
    const rpl: u2 = @truncate(sel);
    if (rpl < c.cpl) return c.raise(13, se);
    const d = try desc(c, b, sel);
    if (!d.code()) return c.raise(13, se);
    if (d.conforming()) {
        if (d.dpl() > rpl) return c.raise(13, se);
    } else if (d.dpl() != rpl) {
        return c.raise(13, se);
    }
    if (!d.present()) return c.raise(11, se);
    return d;
}

/// The outer level's stack a RETF or IRET returns to.
fn retSs(c: *Cpu, b: anytype, sel: u16, rpl: u2) Exc!Desc {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) return c.raise(13, 0);
    if (@as(u2, @truncate(sel)) != rpl) return c.raise(13, se);
    const d = try desc(c, b, sel);
    if (!d.writable() or d.dpl() != rpl) return c.raise(13, se);
    if (!d.present()) return c.raise(12, se);
    return d;
}

fn setEsp(c: *Cpu, v: u32) void {
    if (c.stack32) c.regs.r[ESP] = v else c.regs.set16(ESP, @truncate(v));
}

/// RETF (n: RETF imm16's bytes): to this level, or to an outer one with
/// its SS:ESP.
pub fn farRet(c: *Cpu, b: anytype, n: u16, o32: bool) Exc!void {
    var st = Stk.current(c);
    const off = try popW(&st, c, b, o32);
    const sel: u16 = @truncate(try popW(&st, c, b, o32));
    const d = try retCs(c, b, sel);
    const rpl: u2 = @truncate(sel);
    if (off > d.limit()) return c.raise(13, 0);
    st.skip(n);
    if (rpl == c.cpl) {
        try touch(c, b, d);
        st.commit(c);
        setCache(c, CS, sel, d);
        c.regs.eip = off;
        return;
    }
    const nesp = try popW(&st, c, b, o32);
    const nss: u16 = @truncate(try popW(&st, c, b, o32));
    const ssd = try retSs(c, b, nss, rpl);
    try touch(c, b, d);
    try touch(c, b, ssd);
    c.cpl = rpl;
    setCache(c, CS, sel, d);
    c.regs.eip = off;
    setCache(c, SS, nss, ssd);
    setEsp(c, nesp +% n);
    dropSegs(c);
}

/// IRET: to this level or an outer one; IOPL changes only from CPL 0,
/// IF only at CPL <= IOPL.
pub fn iret(c: *Cpu, b: anytype, o32: bool) Exc!void {
    if (c.regs.flags & NT != 0) {
        // (a nested task's return: to the TSS its back link names)
        const back = try rdLin(c, b, u16, c.tr_base, false);
        const bse: u32 = back & 0xFFFC;
        if (back & 4 != 0) return c.raise(10, bse);
        const d = (try peek(c, b, back)) orelse return c.raise(10, bse);
        if (d.seg() or (d.typ() != 3 and d.typ() != 11)) return c.raise(10, bse);
        return taskSwitch(c, b, back, d, .iret, 0);
    }
    var st = Stk.current(c);
    const off = try popW(&st, c, b, o32);
    const sel: u16 = @truncate(try popW(&st, c, b, o32));
    const fl = try popW(&st, c, b, o32);
    if (o32 and fl & VM != 0 and c.cpl == 0) return c.stop(cpu_mod.FAULT_V86);
    const d = try retCs(c, b, sel);
    const rpl: u2 = @truncate(sel);
    if (off > d.limit()) return c.raise(13, 0);
    var mask: u32 = if (o32) cpu_mod.IRET32 else cpu_mod.POPF16;
    if (c.cpl > 0) mask &= ~IOPL;
    if (c.cpl > cpu_mod.iopl(c.regs.flags)) mask &= ~IF;
    const nf = (c.regs.flags & ~mask) | (fl & mask) | FIXED;
    if (rpl == c.cpl) {
        try touch(c, b, d);
        st.commit(c);
        setCache(c, CS, sel, d);
        c.regs.eip = off;
        c.regs.flags = nf;
        return;
    }
    const nesp = try popW(&st, c, b, o32);
    const nss: u16 = @truncate(try popW(&st, c, b, o32));
    const ssd = try retSs(c, b, nss, rpl);
    try touch(c, b, d);
    try touch(c, b, ssd);
    c.cpl = rpl;
    setCache(c, CS, sel, d);
    c.regs.eip = off;
    c.regs.flags = nf;
    setCache(c, SS, nss, ssd);
    setEsp(c, nesp);
    dropSegs(c);
}

// ── Interrupts and exceptions ───────────────────────────────────────────

pub const Kind = enum {
    /// INT n, INT3, INTO: the gate's DPL must allow CPL.
    soft,
    /// From the machine (cpu.interrupt), or the trace trap.
    hw,
    /// An exception: with its error code if the vector has one.
    exc,
};

fn hasCode(vec: u8) bool {
    return vec == 8 or (vec >= 10 and vec <= 14) or vec == 17;
}

/// Delivers vector `vec` through the IDT: an interrupt gate (IF cleared)
/// or a trap gate, 286 (16-bit pushes) or 386; to a more privileged
/// non-conforming segment on the TSS's stack for its level (with the old
/// SS:ESP). EIP is what the handler returns to.
pub fn intr(c: *Cpu, b: anytype, vec: u8, kind: Kind, code: u32) Exc!void {
    const ext: u32 = @intFromBool(kind != .soft);
    const ierr: u32 = @as(u32, vec) * 8 + 2 + ext;
    if (@as(u32, vec) * 8 + 7 > c.idt_limit) return c.raise(13, ierr);
    const ga = c.idt_base +% @as(u32, vec) * 8;
    const lo = try rdLin(c, b, u32, ga, false);
    const hi = try rdLin(c, b, u32, ga +% 4, false);
    const typ: u5 = @truncate(hi >> 8);
    switch (typ) {
        0x05, 0x06, 0x07, 0x0E, 0x0F => {},
        else => return c.raise(13, ierr),
    }
    if (kind == .soft and @as(u2, @truncate(hi >> 13)) < c.cpl) return c.raise(13, ierr);
    if (hi & 0x8000 == 0) return c.raise(11, ierr);
    const sel: u16 = @truncate(lo >> 16);
    if (typ == 0x05) {
        const td = try taskGateTss(c, b, sel, ext);
        try taskSwitch(c, b, sel, td, .int, ext);
        // (an exception's error code goes on the new task's stack)
        if (kind == .exc and hasCode(vec)) {
            c.keep = true;
            var st = Stk.current(c);
            try pushW(&st, c, b, td.typ() & 8 != 0, code);
            st.commit(c);
            c.keep = false;
        }
        c.halted = false;
        c.poll = true;
        return;
    }
    const wide = typ & 8 != 0;
    const off: u32 = if (wide) (lo & 0xFFFF) | (hi & 0xFFFF_0000) else lo & 0xFFFF;
    if (sel & 0xFFFC == 0) return c.raise(13, ext);
    const se: u32 = @as(u32, sel & 0xFFFC) | ext;
    const d = (try peek(c, b, sel)) orelse return c.raise(13, se);
    if (!d.code() or d.dpl() > c.cpl) return c.raise(13, se);
    if (!d.present()) return c.raise(11, se);
    if (off > d.limit()) return c.raise(13, ext);
    const flags = c.regs.flags;
    var newcpl = c.cpl;
    var st: Stk = undefined;
    var ss_sel: u16 = 0;
    var ssd: Desc = undefined;
    const inner = !d.conforming() and d.dpl() < c.cpl;
    if (inner) {
        newcpl = d.dpl();
        const ts = try tssStack(c, b, newcpl);
        ssd = try newSs(c, b, ts.ss, newcpl, ext);
        ss_sel = ts.ss;
        st = Stk.of(ssd, ts.esp, ts.ss, false);
        try pushW(&st, c, b, wide, c.regs.seg[SS]);
        try pushW(&st, c, b, wide, c.regs.r[ESP]);
    } else {
        st = Stk.current(c);
    }
    try pushW(&st, c, b, wide, flags);
    try pushW(&st, c, b, wide, c.regs.seg[CS]);
    try pushW(&st, c, b, wide, c.regs.eip);
    if (kind == .exc and hasCode(vec)) try pushW(&st, c, b, wide, code);
    try touch(c, b, d);
    if (inner) {
        try touch(c, b, ssd);
        setCache(c, SS, (ss_sel & 0xFFFC) | newcpl, ssd);
    }
    st.commit(c);
    c.cpl = newcpl;
    setCache(c, CS, (sel & 0xFFFC) | newcpl, d);
    c.regs.eip = off;
    c.regs.flags &= ~(TF | NT | RF | VM);
    if (typ & 1 == 0) c.regs.flags &= ~IF;
    c.halted = false;
    c.poll = true;
}

/// #DE and #TS #NP #SS #GP: two of them in a row are a double fault, as
/// a page fault followed by one of them or by another page fault.
fn contributory(v: u8) bool {
    return v == 0 or (v >= 10 and v <= 13);
}

fn triple(c: *Cpu, first: u8, second: u8) ?Exit {
    c.fault_op = cpu_mod.FAULT_TRIPLE | (@as(u32, first) << 8) | second;
    c.fault_at = c.regs.base[CS] +% c.regs.eip;
    c.dead = true;
    return .fault;
}

/// Delivers the exception an instruction raised (`exc_vec`, `exc_code`;
/// the instruction's EIP/ESP/EFLAGS restored already). Null when it is
/// on its way; .fault for a triple fault or a stop.
pub fn exception(c: *Cpu, b: anytype) ?Exit {
    var vec = c.exc_vec;
    var code = c.exc_code;
    var n: u32 = 0;
    while (n < 8) : (n += 1) {
        if (intr(c, b, vec, .exc, code)) |_| {
            return null;
        } else |e| {
            if (e == error.Stop) {
                c.dead = true;
                return .fault;
            }
            const nv = c.exc_vec;
            if (c.keep) {
                // (raised in a new task, its switch done: delivered anew)
                c.keep = false;
                vec = nv;
                code = c.exc_code;
                continue;
            }
            if (vec == 8) return triple(c, vec, nv);
            if ((contributory(vec) and contributory(nv)) or (vec == 14 and (nv == 14 or contributory(nv)))) {
                vec = 8;
                code = 0;
            } else {
                vec = nv;
                code = c.exc_code;
            }
        }
    }
    return triple(c, vec, 0);
}

/// A hardware interrupt (cpu.interrupt): a fault on its way is delivered
/// instead; a triple fault stops the CPU (`dead`).
pub fn external(c: *Cpu, b: anytype, vec: u8) void {
    c.halted = false;
    intr(c, b, vec, .hw, 0) catch |e| {
        if (e == error.Stop) {
            c.dead = true;
            return;
        }
        c.keep = false;
        if (exception(c, b) != null) c.dead = true;
    };
}

// ── LLDT, LTR, LAR, LSL, VERR, VERW, I/O permission ─────────────────────

pub fn lldt(c: *Cpu, b: anytype, sel: u16) Exc!void {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) {
        c.ldtr = sel;
        c.ldt_base = 0;
        c.ldt_limit = 0;
        return;
    }
    if (sel & 4 != 0) return c.raise(13, se);
    const d = try desc(c, b, sel);
    if (d.seg() or d.typ() != 2) return c.raise(13, se);
    if (!d.present()) return c.raise(11, se);
    c.ldtr = sel;
    c.ldt_base = d.base();
    c.ldt_limit = d.limit();
}

/// LTR: an available 286 or 386 TSS in the GDT, marked busy.
pub fn ltr(c: *Cpu, b: anytype, sel: u16) Exc!void {
    const se: u32 = sel & 0xFFFC;
    if (se == 0) return c.raise(13, 0);
    if (sel & 4 != 0) return c.raise(13, se);
    const d = try desc(c, b, sel);
    if (d.seg() or (d.typ() != 1 and d.typ() != 9)) return c.raise(13, se);
    if (!d.present()) return c.raise(11, se);
    try wrLin(c, b, u8, d.at +% 5, @as(u8, @truncate(d.hi >> 8)) | 2, false);
    c.tr = sel;
    c.tr_base = d.base();
    c.tr_limit = d.limit();
    c.tr_type = @as(u8, d.typ()) | 2;
}

/// VERR (write false) / VERW: may CPL read (write) the segment?
pub fn verify(c: *Cpu, b: anytype, sel: u16, write: bool) Exc!bool {
    const d = (try peek(c, b, sel)) orelse return false;
    if (!d.seg()) return false;
    const rpl: u2 = @truncate(sel);
    const visible = d.dpl() >= c.cpl and d.dpl() >= rpl;
    if (write) return d.writable() and visible;
    return d.readable() and (d.conforming() or visible);
}

/// LAR (the access rights, bits 8-23 of the descriptor's high dword) or
/// LSL (the limit in bytes), or null (ZF clear) for a selector CPL may
/// not see or a type it does not apply to.
pub fn larLsl(c: *Cpu, b: anytype, sel: u16, lar: bool) Exc!?u32 {
    const d = (try peek(c, b, sel)) orelse return null;
    if (!d.seg()) {
        const ok = switch (d.typ()) {
            1, 2, 3, 9, 11 => true,
            4, 5, 12 => lar,
            else => false,
        };
        if (!ok) return null;
    }
    const rpl: u2 = @truncate(sel);
    if (!d.conforming() and (d.dpl() < c.cpl or d.dpl() < rpl)) return null;
    return if (lar) d.hi & 0x00F0_FF00 else d.limit();
}

/// CPL > IOPL: the 386 TSS's I/O permission bitmap must clear every bit
/// for the `n` ports at `port` (#GP(0) otherwise, or with no bitmap).
pub fn ioBitmap(c: *Cpu, b: anytype, port: u16, n: u32) Exc!void {
    if (c.tr_type & 8 != 0 and c.tr_limit >= 0x67) {
        const bm: u32 = try rdLin(c, b, u16, c.tr_base +% 0x66, false);
        const at = bm + port / 8;
        if (at + 1 <= c.tr_limit) {
            const w: u32 = try rdLin(c, b, u16, c.tr_base +% at, false);
            const mask: u32 = ((@as(u32, 1) << @intCast(n)) - 1) << @intCast(port & 7);
            if (w & mask == 0) return;
        }
    }
    return c.raise(13, 0);
}

// ── Paging and the TLB ──────────────────────────────────────────────────

pub const TLB_N = 256;

/// Direct-mapped by the page number's low bits: the linear page (| 1:
/// valid), its frame, what it allows (K_*: a write only once the dirty
/// bit is set in the page table), and where the host has its bytes.
///
/// Protected mode always goes through it, paging on or off (off: each
/// page is its own frame). When the bus can say where a page's bytes
/// are (`page`: RAM, the frame buffer), the entry keeps that (`hoff`,
/// D_R/D_W), and a hit is a load or a store; a device's page has no
/// pointer and every access to it goes to the bus.
///
/// The fetch window: the code page EIP is in, as host bytes (EIP from
/// `fw_base`, `fw_len` bytes, at `fw_host`); every flush and every CS
/// load empties it. Code is read where it is, so code that writes
/// itself needs nothing more.
pub const Tlb = struct {
    tag: [TLB_N]u32 = [_]u32{0} ** TLB_N,
    phys: [TLB_N]u32 = [_]u32{0} ** TLB_N,
    perm: [TLB_N]u8 = [_]u8{0} ** TLB_N,
    /// The host address of the page's byte 0, less its linear address.
    hoff: [TLB_N]usize = [_]usize{0} ** TLB_N,
    /// The fast paths' own tags, [0] for CPL 0-2, [1] for CPL 3: the
    /// page | 1 where its host bytes may be read (written) at that level,
    /// else 0. One compare is a hit.
    rtag: [2][TLB_N]u32 = [_][TLB_N]u32{[_]u32{0} ** TLB_N} ** 2,
    wtag: [2][TLB_N]u32 = [_][TLB_N]u32{[_]u32{0} ** TLB_N} ** 2,
    fw_base: u32 = 0,
    fw_len: u32 = 0,
    fw_host: usize = 0,
    /// The window's TLB entry.
    fw_idx: u32 = 0,
    /// The bus's map key (its A20 gate) the entries were made under.
    key: u32 = 0,

    pub fn flush(t: *Tlb) void {
        if (cpu_mod.count_ops) stats[0] += 1;
        @memset(&t.tag, 0);
        inline for (0..2) |u| {
            @memset(&t.rtag[u], 0);
            @memset(&t.wtag[u], 0);
        }
        t.fw_len = 0;
    }

    pub fn flushPage(t: *Tlb, lin: u32) void {
        const i = (lin >> 12) & (TLB_N - 1);
        if (t.tag[i] == (lin & 0xFFFF_F000) | 1) {
            t.tag[i] = 0;
            inline for (0..2) |u| {
                t.rtag[u][i] = 0;
                t.wtag[u][i] = 0;
            }
        }
        t.fw_len = 0;
    }
};

pub const K_SR: u8 = 1;
pub const K_SW: u8 = 2;
pub const K_UR: u8 = 4;
pub const K_UW: u8 = 8;
/// The host's bytes may be read (written) directly.
pub const D_R: u8 = 16;
pub const D_W: u8 = 32;

/// K_SR or K_UR (`write`: K_SW, K_UW) for an access at CPL.
pub inline fn access(cpl: u2, comptime write: bool) u8 {
    const k: u8 = if (cpl == 3) K_UR else K_SR;
    return if (write) k << 1 else k;
}

fn hasPage(comptime B: type) bool {
    const T = switch (@typeInfo(B)) {
        .pointer => |info| info.child,
        else => B,
    };
    return @hasDecl(T, "page");
}

/// The bus's map key (0 for a bus without one): entries made under
/// another key are stale.
pub inline fn mapKey(b: anytype) u32 {
    if (comptime hasPage(@TypeOf(b))) return b.mapKey();
    return 0;
}

/// Empties the TLB if the bus's map changed (the A20 gate).
pub inline fn checkKey(c: *Cpu, b: anytype) void {
    const k = mapKey(b);
    if (k != c.tlb.key) {
        c.tlb.flush();
        c.tlb.key = k;
    }
}

/// The physical address for a linear one: the TLB, else a walk of the
/// page directory and table (#PF, CR2), or the page itself with paging
/// off; a miss fills the entry.
pub inline fn translate(c: *Cpu, b: anytype, lin: u32, write: bool, user: bool) Exc!u32 {
    const i = (lin >> 12) & (TLB_N - 1);
    const k: u8 = @as(u8, if (user) K_UR else K_SR) << @intFromBool(write);
    if (c.tlb.tag[i] == (lin & 0xFFFF_F000) | 1 and c.tlb.perm[i] & k != 0) return c.tlb.phys[i] | (lin & 0xFFF);
    return walk(c, b, lin, write, user);
}

/// #PF: error code bit 0 a protection violation (else not present), bit
/// 1 a write, bit 2 from CPL 3.
fn pf(c: *Cpu, lin: u32, protection: bool, write: bool, user: bool) Exc {
    c.cr2 = lin;
    const e: u32 = @as(u32, @intFromBool(protection)) | (@as(u32, @intFromBool(write)) << 1) | (@as(u32, @intFromBool(user)) << 2);
    return c.raise(14, e);
}

fn fill(c: *Cpu, b: anytype, lin: u32, frame: u32, perm0: u8) void {
    var perm = perm0;
    const i = (lin >> 12) & (TLB_N - 1);
    const page = lin & 0xFFFF_F000;
    var hoff: usize = 0;
    if (comptime hasPage(@TypeOf(b))) {
        if (b.page(frame, false)) |p| {
            hoff = @intFromPtr(p) -% page;
            perm |= D_R;
            if (b.page(frame, true) != null) perm |= D_W;
        }
    }
    c.tlb.tag[i] = page | 1;
    c.tlb.phys[i] = frame;
    c.tlb.perm[i] = perm;
    c.tlb.hoff[i] = hoff;
    const t = page | 1;
    c.tlb.rtag[0][i] = if (perm & D_R != 0) t else 0;
    c.tlb.rtag[1][i] = if (perm & (D_R | K_UR) == D_R | K_UR) t else 0;
    c.tlb.wtag[0][i] = if (perm & (D_W | K_SW) == D_W | K_SW) t else 0;
    c.tlb.wtag[1][i] = if (perm & (D_W | K_UW) == D_W | K_UW) t else 0;
    // (the window may be on the entry this one replaces)
    if (i == c.tlb.fw_idx) c.tlb.fw_len = 0;
}

/// The profiling build's counts (cpu.count_ops): TLB flushes, misses.
pub var stats: [4]u64 = [_]u64{0} ** 4;

fn walk(c: *Cpu, b: anytype, lin: u32, write: bool, user: bool) Exc!u32 {
    if (cpu_mod.count_ops) stats[1] += 1;
    if (!c.paging) {
        fill(c, b, lin, lin & 0xFFFF_F000, K_SR | K_SW | K_UR | K_UW);
        return lin;
    }
    const pde_at = (c.cr3 & 0xFFFF_F000) +% ((lin >> 22) << 2);
    const pde = b.rd32(pde_at);
    if (pde & 1 == 0) return pf(c, lin, false, write, user);
    const pte_at = (pde & 0xFFFF_F000) +% (((lin >> 12) & 0x3FF) << 2);
    const pte = b.rd32(pte_at);
    if (pte & 1 == 0) return pf(c, lin, false, write, user);
    const u = pde & pte & 4 != 0;
    const w = pde & pte & 2 != 0;
    // (the supervisor writes anywhere unless CR0.WP: a 486's)
    const wp = c.cr0 & cpu_mod.CR0_WP != 0;
    if (user and !u) return pf(c, lin, true, write, user);
    if (write and !w and (user or wp)) return pf(c, lin, true, write, user);
    if (pde & 0x20 == 0) b.wr32(pde_at, pde | 0x20);
    const npte = pte | 0x20 | (if (write) @as(u32, 0x40) else 0);
    if (npte != pte) b.wr32(pte_at, npte);
    const dirty = npte & 0x40 != 0;
    var perm: u8 = K_SR;
    if (dirty and (w or !wp)) perm |= K_SW;
    if (u) {
        perm |= K_UR;
        if (dirty and w) perm |= K_UW;
    }
    fill(c, b, lin, npte & 0xFFFF_F000, perm);
    return (npte & 0xFFFF_F000) | (lin & 0xFFF);
}

/// T at linear `a` (what the inline hit in cpu.sig's rdL leaves): a
/// device's page, an access across a page boundary (both pages
/// translated before it reads), or a miss.
pub fn rdSlow(c: *Cpu, b: anytype, comptime T: type, a: u32, user: bool) Exc!T {
    const n = @sizeOf(T);
    if (n > 1 and (a & 0xFFF) > 0x1000 - n) {
        const p0 = try translate(c, b, a, false, user);
        const p1 = try translate(c, b, (a | 0xFFF) +% 1, false, user);
        const first: u32 = 0x1000 - (a & 0xFFF);
        var v: T = 0;
        inline for (0..n) |i| {
            const ph: u32 = if (i < first) p0 +% @as(u32, i) else p1 +% (@as(u32, i) -% first);
            v |= @as(T, b.rd8(ph)) << (8 * i);
        }
        return v;
    }
    const ph = try translate(c, b, a, false, user);
    const i = (a >> 12) & (TLB_N - 1);
    if (c.tlb.perm[i] & D_R != 0) return @as(*align(1) const T, @ptrFromInt(c.tlb.hoff[i] +% a)).*;
    return rdM(b, T, ph);
}

/// The same for writes (both pages translated before either is written).
pub fn wrSlow(c: *Cpu, b: anytype, comptime T: type, a: u32, v: T, user: bool) Exc!void {
    const n = @sizeOf(T);
    if (n > 1 and (a & 0xFFF) > 0x1000 - n) {
        const p0 = try translate(c, b, a, true, user);
        const p1 = try translate(c, b, (a | 0xFFF) +% 1, true, user);
        const first: u32 = 0x1000 - (a & 0xFFF);
        inline for (0..n) |i| {
            const ph: u32 = if (i < first) p0 +% @as(u32, i) else p1 +% (@as(u32, i) -% first);
            b.wr8(ph, @truncate(v >> (8 * i)));
        }
        return;
    }
    const ph = try translate(c, b, a, true, user);
    const i = (a >> 12) & (TLB_N - 1);
    if (c.tlb.perm[i] & D_W != 0) {
        @as(*align(1) T, @ptrFromInt(c.tlb.hoff[i] +% a)).* = v;
        return;
    }
    wrM(b, T, ph, v);
}

/// The fetch window for EIP `ip` at linear `lin`, if its page has host
/// bytes (the TLB entry made by a fetch just now): to the page's end or
/// CS's limit, whichever comes first.
pub fn window(c: *Cpu, ip: u32, lin: u32) void {
    const i = (lin >> 12) & (TLB_N - 1);
    const need = D_R | access(c.cpl, false);
    if (c.tlb.tag[i] != (lin & 0xFFFF_F000) | 1 or c.tlb.perm[i] & need != need) return;
    const off = lin & 0xFFF;
    const back = @min(off, ip);
    const start = ip - back;
    var len: u64 = 0x1000 - off + back;
    // (short of EIP's wrap: a fetch from the window never has to wrap)
    const last: u64 = @min(c.fetch_hi, c.ip_wrap - 1);
    if (ip > last) return;
    if (start + len - 1 > last) len = last - start + 1;
    c.tlb.fw_idx = i;
    c.tlb.fw_base = start;
    c.tlb.fw_len = @intCast(len);
    c.tlb.fw_host = c.tlb.hoff[i] +% (lin - back);
}

// ── Task switches ───────────────────────────────────────────────────────

pub const Switch = enum { jmp, call, iret, int };

const TSS386_MIN: u32 = 0x67;
const TSS286_MIN: u32 = 0x2B;

/// The TSS a task gate names: an available TSS in the GDT (#GP(sel)).
fn taskGateTss(c: *Cpu, b: anytype, tsel: u16, ext: u32) Exc!Desc {
    const tse: u32 = (tsel & 0xFFFC) | ext;
    if (tsel & 4 != 0 or tsel & 0xFFFC == 0) return c.raise(13, tse);
    const d = (try peek(c, b, tsel)) orelse return c.raise(13, tse);
    if (d.seg()) return c.raise(13, tse);
    switch (d.typ()) {
        1, 9 => {},
        else => return c.raise(13, tse),
    }
    return d;
}

/// Sets (on) or clears the busy bit of the TSS descriptor `sel` names.
fn setBusy(c: *Cpu, b: anytype, sel: u16, on: bool) Exc!void {
    const at = c.gdt_base +% (sel & 0xFFF8) +% 5;
    const a = try rdLin(c, b, u8, at, false);
    try wrLin(c, b, u8, at, if (on) a | 2 else a & ~@as(u8, 2), false);
}

/// Switches to the task whose TSS descriptor is `d` (selector `sel`):
/// the current state into the current TSS, the new one out of its own;
/// busy bits, NT and the back link as `how` asks; CR0.TS set. Up to the
/// new TSS taking over, a fault leaves everything as it was.
fn taskSwitch(c: *Cpu, b: anytype, sel: u16, d: Desc, how: Switch, ext: u32) Exc!void {
    const se: u32 = (sel & 0xFFFC) | ext;
    if (sel & 4 != 0) return c.raise(if (how == .iret) 10 else 13, se);
    const nbig = d.typ() & 8 != 0;
    const busy = d.typ() & 2 != 0;
    if (how == .iret) {
        if (!busy) return c.raise(10, se);
    } else if (busy) {
        return c.raise(13, se);
    }
    if (!d.present()) return c.raise(11, se);
    if (d.limit() < (if (nbig) TSS386_MIN else TSS286_MIN)) return c.raise(10, se);
    const obig = c.tr_type & 8 != 0;
    const oerr: u32 = c.tr & 0xFFFC;
    if (c.tr_type == 0 or c.tr_limit < (if (obig) TSS386_MIN else TSS286_MIN)) return c.raise(10, oerr);

    // The new state, read whole before anything changes.
    const nb = d.base();
    var ncr3: u32 = c.cr3;
    var neip: u32 = undefined;
    var nfl: u32 = undefined;
    var nr: [8]u32 = c.regs.r;
    var nseg: [6]u16 = c.regs.seg;
    var nldt: u16 = undefined;
    if (nbig) {
        ncr3 = try rdLin(c, b, u32, nb +% 0x1C, false);
        neip = try rdLin(c, b, u32, nb +% 0x20, false);
        nfl = try rdLin(c, b, u32, nb +% 0x24, false);
        for (0..8) |i| nr[i] = try rdLin(c, b, u32, nb +% 0x28 +% @as(u32, @intCast(i)) * 4, false);
        for (0..6) |i| nseg[i] = try rdLin(c, b, u16, nb +% 0x48 +% @as(u32, @intCast(i)) * 4, false);
        nldt = try rdLin(c, b, u16, nb +% 0x60, false);
    } else {
        neip = try rdLin(c, b, u16, nb +% 0x0E, false);
        nfl = try rdLin(c, b, u16, nb +% 0x10, false);
        for (0..8) |i| {
            const v = try rdLin(c, b, u16, nb +% 0x12 +% @as(u32, @intCast(i)) * 2, false);
            nr[i] = (nr[i] & 0xFFFF_0000) | v;
        }
        for (0..4) |i| nseg[i] = try rdLin(c, b, u16, nb +% 0x22 +% @as(u32, @intCast(i)) * 2, false);
        nldt = try rdLin(c, b, u16, nb +% 0x2A, false);
    }

    // The current state into the current TSS (EIP: where the task goes
    // on, after the JMP/CALL/INT, or the faulting instruction).
    const ob = c.tr_base;
    var ofl = c.regs.flags;
    if (how == .iret) ofl &= ~NT;
    if (obig) {
        try wrLin(c, b, u32, ob +% 0x20, c.regs.eip, false);
        try wrLin(c, b, u32, ob +% 0x24, ofl, false);
        for (0..8) |i| try wrLin(c, b, u32, ob +% 0x28 +% @as(u32, @intCast(i)) * 4, c.regs.r[i], false);
        for (0..6) |i| try wrLin(c, b, u16, ob +% 0x48 +% @as(u32, @intCast(i)) * 4, c.regs.seg[i], false);
    } else {
        try wrLin(c, b, u16, ob +% 0x0E, @truncate(c.regs.eip), false);
        try wrLin(c, b, u16, ob +% 0x10, @truncate(ofl), false);
        for (0..8) |i| try wrLin(c, b, u16, ob +% 0x12 +% @as(u32, @intCast(i)) * 2, @truncate(c.regs.r[i]), false);
        for (0..4) |i| try wrLin(c, b, u16, ob +% 0x22 +% @as(u32, @intCast(i)) * 2, c.regs.seg[i], false);
    }
    // JMP and IRET leave the old task; CALL and INT nest the new one.
    if (how == .jmp or how == .iret) try setBusy(c, b, c.tr, false);
    if (how == .call or how == .int) try wrLin(c, b, u16, nb, c.tr, false);
    if (how != .iret) try setBusy(c, b, sel, true);

    // The new task is current from here: what fails is its exception.
    c.tr = sel;
    c.tr_base = nb;
    c.tr_limit = d.limit();
    c.tr_type = @as(u8, d.typ()) | 2;
    c.cr0 |= cpu_mod.CR0_TS;
    if (nbig) {
        c.cr3 = ncr3;
        c.tlb.flush();
    } else {
        nfl &= 0xFFFF;
    }
    if (how == .call or how == .int) nfl |= NT;
    c.regs.flags = (nfl & ~RF) | FIXED;
    c.regs.eip = neip;
    c.regs.r = nr;
    c.ldtr = nldt;
    c.ldt_base = 0;
    c.ldt_limit = 0;
    for (0..6) |i| {
        c.regs.seg[i] = nseg[i];
        c.regs.attr[i] = 0;
        syncSeg(c, @intCast(i));
    }
    c.cpl = @truncate(nseg[CS]);
    c.keep = true;
    if (nfl & VM != 0) return c.stop(cpu_mod.FAULT_V86);

    // Its LDT, CS, SS, then DS ES FS GS: #TS(selector) for a wrong one,
    // #NP (#SS for SS) for one not present.
    if (nldt & 0xFFFC != 0) {
        const le: u32 = nldt & 0xFFFC;
        if (nldt & 4 != 0) return c.raise(10, le);
        const ld = (try peek(c, b, nldt)) orelse return c.raise(10, le);
        if (ld.seg() or ld.typ() != 2 or !ld.present()) return c.raise(10, le);
        c.ldt_base = ld.base();
        c.ldt_limit = ld.limit();
    }
    const cs = nseg[CS];
    const ce: u32 = cs & 0xFFFC;
    if (ce == 0) return c.raise(10, 0);
    const cd = (try peek(c, b, cs)) orelse return c.raise(10, ce);
    if (!cd.code()) return c.raise(10, ce);
    if (cd.conforming()) {
        if (cd.dpl() > c.cpl) return c.raise(10, ce);
    } else if (cd.dpl() != c.cpl) {
        return c.raise(10, ce);
    }
    if (!cd.present()) return c.raise(11, ce);
    try touch(c, b, cd);
    setCache(c, CS, cs, cd);
    const ss = nseg[SS];
    const sse: u32 = ss & 0xFFFC;
    if (sse == 0) return c.raise(10, 0);
    const sd = (try peek(c, b, ss)) orelse return c.raise(10, sse);
    if (!sd.writable() or sd.dpl() != c.cpl or @as(u2, @truncate(ss)) != c.cpl) return c.raise(10, sse);
    if (!sd.present()) return c.raise(12, sse);
    try touch(c, b, sd);
    setCache(c, SS, ss, sd);
    for ([_]u3{ DS, ES, FS, GS }) |s| {
        const v = nseg[s];
        const ve: u32 = v & 0xFFFC;
        if (ve == 0) {
            setNull(c, s, v);
            continue;
        }
        const vd = (try peek(c, b, v)) orelse return c.raise(10, ve);
        if (!vd.readable()) return c.raise(10, ve);
        if (!vd.conforming() and (vd.dpl() < c.cpl or vd.dpl() < @as(u2, @truncate(v)))) return c.raise(10, ve);
        if (!vd.present()) return c.raise(11, ve);
        try touch(c, b, vd);
        setCache(c, s, v, vd);
    }
    if (neip > cd.limit()) return c.raise(13, 0);
    c.keep = false;
}
