//! The translator's AArch64 code generator (jit.sig): the same blocks, the
//! same exits, chaining and fast lookups as jit_x64.sig, the same templates
//! but the x87's (an x87 instruction calls the FPU's own code). Generated
//! code runs with x19 = the Cpu, x25 = its registers (`Cpu.regs`), x20 =
//! the Ctx, x21 = the RAM's host address, x22 = the budget, x26/x27/x28 =
//! the TLB's read tags, write tags and host offsets; x23 (an operand's
//! linear address) and x24 (a new stack pointer) survive helper calls;
//! x0-x15 are scratch. AArch64 has no parity or auxiliary carry, and its
//! carry is the inverse of x86's after a subtraction: flags anything reads
//! are computed by jit.hFlags (the interpreter's formulas), except that a
//! Jcc right after its compare branches on the host's own NZCV. Written
//! from Arm's Architecture Reference Manual (A64).

const std = @import("std");
const jit = @import("jit.sig");
const dec = jit.dec;
const cpu_mod = @import("cpu.sig");
const regs_mod = @import("regs.sig");
const pm = @import("cpu_pm.sig");
const Cpu = cpu_mod.Cpu;
const Jit = jit.Jit;
const Regs = regs_mod.Regs;

// Registers.
const XCPU: u5 = 19;
const XCTX: u5 = 20;
const XRAM: u5 = 21;
const XBUD: u5 = 22;
const XLIN: u5 = 23;
const XSP: u5 = 24;
const XREG: u5 = 25;
const XRT: u5 = 26;
const XWT: u5 = 27;
const XHO: u5 = 28;
const ZR: u5 = 31;

// Offsets.
const R_R = @offsetOf(Regs, "r");
const R_EIP = @offsetOf(Regs, "eip");
const R_FLAGS = @offsetOf(Regs, "flags");
const R_BASE = @offsetOf(Regs, "base");
const R_SEG = @offsetOf(Regs, "seg");
const C_R14 = @offsetOf(jit.Ctx, "r14");
const C_HELP = @offsetOf(jit.Ctx, "helpers");
const C_PAGES = @offsetOf(jit.Ctx, "pages");
const C_FAST = @offsetOf(jit.Ctx, "fast");
const C_WLOG = @offsetOf(jit.Ctx, "wlog");
const C_WLOGN = @offsetOf(jit.Ctx, "wlog_n");
const O_SEGLO = @offsetOf(Cpu, "seg_lo");
const O_SEGRHI = @offsetOf(Cpu, "seg_rhi");
const O_SEGWHI = @offsetOf(Cpu, "seg_whi");
const O_FETCHHI = @offsetOf(Cpu, "fetch_hi");

const H_STEP = 0;
const H_X87 = 1;
const H_FLAGS = 2;

const ARITH: u32 = dec.ARITH;
const CF: u32 = regs_mod.CF;
const DF: u32 = regs_mod.DF;

// Conditions.
const EQ: u4 = 0;
const NE: u4 = 1;
const HS: u4 = 2;
const LO: u4 = 3;
const MI: u4 = 4;
const PL: u4 = 5;
const VS: u4 = 6;
const VC: u4 = 7;
const HI: u4 = 8;
const LS: u4 = 9;
const GE: u4 = 10;
const LT: u4 = 11;
const GT: u4 = 12;
const LE: u4 = 13;

var off_exit: usize = 0;
var off_exit_next: usize = 0;

/// An assembler over the code memory's writable view.
const A = struct {
    j: *Jit,
    at: usize,
    lim: usize,
    ok: bool = true,

    fn i(a: *A, w: u32) void {
        if (a.at + 4 > a.lim) {
            a.ok = false;
            return;
        }
        std.mem.writeInt(u32, a.j.cm.rw[a.at..][0..4], w, .little);
        a.at += 4;
    }
    fn put(a: *A, at: usize, w: u32) void {
        std.mem.writeInt(u32, a.j.cm.rw[at..][0..4], w, .little);
    }
    fn get(a: *A, at: usize) u32 {
        return std.mem.readInt(u32, a.j.cm.rw[at..][0..4], .little);
    }

    // ── Moves ──────────────────────────────────────────────────────────

    /// wd/xd = v (MOVZ/MOVK, the 16-bit pieces that are not 0).
    fn movw(a: *A, d: u5, v: u32) void {
        a.i(0x52800000 | (@as(u32, v & 0xFFFF) << 5) | d);
        if (v >> 16 != 0) a.i(0x72A00000 | (@as(u32, v >> 16) << 5) | d);
    }
    fn movx(a: *A, d: u5, v: u64) void {
        a.i(0xD2800000 | (@as(u32, @truncate(v & 0xFFFF)) << 5) | d);
        var s: u5 = 1;
        while (s < 4) : (s += 1) {
            const piece: u32 = @truncate((v >> (@as(u6, s) * 16)) & 0xFFFF);
            if (piece != 0) a.i(0xF2800000 | (@as(u32, s) << 21) | (piece << 5) | d);
        }
    }
    fn mov(a: *A, x64: bool, d: u5, s: u5) void {
        a.i((if (x64) @as(u32, 0xAA0003E0) else 0x2A0003E0) | (@as(u32, s) << 16) | d);
    }

    // ── Arithmetic ─────────────────────────────────────────────────────

    /// d = n + imm (0 <= imm < 4096; sub: n - imm; s: set flags).
    fn addi(a: *A, x64: bool, minus: bool, s: bool, d: u5, n: u5, imm: u32) void {
        var op: u32 = 0x11000000;
        if (x64) op |= 0x80000000;
        if (minus) op |= 0x40000000;
        if (s) op |= 0x20000000;
        a.i(op | ((imm & 0xFFF) << 10) | (@as(u32, n) << 5) | d);
    }
    /// d = n + v for any v (through x16).
    fn addk(a: *A, x64: bool, d: u5, n: u5, v: u32) void {
        if (v < 4096) return a.addi(x64, false, false, d, n, v);
        if (v & 0xFFF == 0 and v < (1 << 24)) {
            a.i((if (x64) @as(u32, 0x91400000) else 0x11400000) | ((v >> 12) << 10) | (@as(u32, n) << 5) | d);
            return;
        }
        a.movw(16, v);
        a.rrr(x64, 0x0B000000, d, n, 16, 0);
    }
    /// A three-register op (base opcode for 32 bits), Rm shifted left by
    /// `sh` (for the shifted-register forms).
    fn rrr(a: *A, x64: bool, op: u32, d: u5, n: u5, m: u5, sh: u6) void {
        a.i(op | (if (x64) @as(u32, 0x80000000) else 0) | (@as(u32, m) << 16) | (@as(u32, sh) << 10) | (@as(u32, n) << 5) | d);
    }
    fn add(a: *A, d: u5, n: u5, m: u5) void {
        a.rrr(false, 0x0B000000, d, n, m, 0);
    }
    fn sub(a: *A, d: u5, n: u5, m: u5) void {
        a.rrr(false, 0x4B000000, d, n, m, 0);
    }
    fn and_(a: *A, d: u5, n: u5, m: u5) void {
        a.rrr(false, 0x0A000000, d, n, m, 0);
    }
    fn orr(a: *A, d: u5, n: u5, m: u5) void {
        a.rrr(false, 0x2A000000, d, n, m, 0);
    }
    fn eor(a: *A, d: u5, n: u5, m: u5) void {
        a.rrr(false, 0x4A000000, d, n, m, 0);
    }
    /// cmp wn, wm (shifted left by sh).
    fn cmp(a: *A, x64: bool, n: u5, m: u5) void {
        a.rrr(x64, 0x6B000000, ZR, n, m, 0);
    }
    fn cmpi(a: *A, x64: bool, n: u5, imm: u32) void {
        a.addi(x64, true, true, ZR, n, imm);
    }
    /// Unsigned bitfield move (32): UBFM d, n, immr, imms.
    fn ubfm(a: *A, d: u5, n: u5, immr: u5, imms: u5) void {
        a.i(0x53000000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, n) << 5) | d);
    }
    fn sbfm(a: *A, d: u5, n: u5, immr: u5, imms: u5) void {
        a.i(0x13000000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, n) << 5) | d);
    }
    fn lsr(a: *A, d: u5, n: u5, s: u5) void {
        a.ubfm(d, n, s, 31);
    }
    fn lsl(a: *A, d: u5, n: u5, s: u5) void {
        a.ubfm(d, n, @truncate((32 - @as(u32, s)) & 31), @intCast(31 - @as(u32, s)));
    }
    fn asr(a: *A, d: u5, n: u5, s: u5) void {
        a.sbfm(d, n, s, 31);
    }
    /// d = (n >> lsb) & ((1 << width) - 1).
    fn ubfx(a: *A, d: u5, n: u5, lsb: u5, width: u6) void {
        a.ubfm(d, n, lsb, @intCast(@as(u32, lsb) + width - 1));
    }
    /// Zero/sign extension of the low sz bytes (sz 1, 2); 4: a copy.
    fn ext(a: *A, d: u5, n: u5, sz: u8, signed: bool) void {
        switch (sz) {
            1 => if (signed) a.sbfm(d, n, 0, 7) else a.ubfm(d, n, 0, 7),
            2 => if (signed) a.sbfm(d, n, 0, 15) else a.ubfm(d, n, 0, 15),
            else => if (d != n) a.mov(false, d, n),
        }
    }
    fn sbfm64(a: *A, d: u5, n: u5, immr: u6, imms: u6) void {
        a.i(0x93400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, n) << 5) | d);
    }
    /// The 64-bit ubfm (N=1).
    fn ubfm64(a: *A, d: u5, n: u5, immr: u6, imms: u6) void {
        a.i(0xD3400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, n) << 5) | d);
    }
    fn cset(a: *A, d: u5, cond: u4) void {
        a.i(0x1A9F07E0 | (@as(u32, cond ^ 1) << 12) | d);
    }

    // ── Memory ─────────────────────────────────────────────────────────

    /// ldr/str of sz bytes (1, 2, 4, 8) at [n + off] (off sz-aligned);
    /// `signed`: the sign-extending loads (1, 2).
    fn ldst(a: *A, load: bool, sz: u8, signed: bool, t: u5, n: u5, off: usize) void {
        const scale: u6 = switch (sz) {
            1 => 0,
            2 => 1,
            4 => 2,
            else => 3,
        };
        var base: u32 = switch (sz) {
            1 => 0x39000000,
            2 => 0x79000000,
            4 => 0xB9000000,
            else => 0xF9000000,
        };
        if (load) base |= if (signed) 0x00C00000 else 0x00400000;
        if (off % sz == 0 and off / sz < 4096) {
            a.i(base | (@as(u32, @intCast(off >> scale)) << 10) | (@as(u32, n) << 5) | t);
            return;
        }
        a.addk(true, 16, n, @intCast(off));
        a.i(base | (@as(u32, 16) << 5) | t);
    }
    fn ld(a: *A, sz: u8, t: u5, n: u5, off: usize) void {
        a.ldst(true, sz, false, t, n, off);
    }
    fn st(a: *A, sz: u8, t: u5, n: u5, off: usize) void {
        a.ldst(false, sz, false, t, n, off);
    }
    /// ldr/str of sz bytes at [n + m] (m a 64-bit register), unscaled.
    fn ldstr(a: *A, load: bool, sz: u8, signed: bool, t: u5, n: u5, m: u5) void {
        var base: u32 = switch (sz) {
            1 => 0x38206800,
            2 => 0x78206800,
            4 => 0xB8206800,
            else => 0xF8206800,
        };
        if (load) base |= if (signed) 0x00C00000 else 0x00400000;
        a.i(base | (@as(u32, m) << 16) | (@as(u32, n) << 5) | t);
    }
    /// ldr w/x t, [n, m, lsl #scale] (scale 2: words, 3: dwords).
    fn ldsc(a: *A, sz: u8, t: u5, n: u5, m: u5) void {
        const base: u32 = if (sz == 4) 0xB8607800 else 0xF8607800;
        a.i(base | (@as(u32, m) << 16) | (@as(u32, n) << 5) | t);
    }
    fn guest(a: *A, load: bool, sz: u8, t: u5, g: u3) void {
        const off: usize = if (sz == 1 and g >= 4) R_R + 4 * @as(usize, g - 4) + 1 else R_R + 4 * @as(usize, g);
        a.ldst(load, sz, false, t, XREG, off);
    }

    // ── Branches ───────────────────────────────────────────────────────

    fn b(a: *A, to: usize) void {
        const d: i64 = @divExact(@as(i64, @intCast(to)) - @as(i64, @intCast(a.at)), 4);
        a.i(0x14000000 | (@as(u32, @bitCast(@as(i32, @intCast(d)))) & 0x03FF_FFFF));
    }
    fn bcond(a: *A, cond: u4, to: usize) void {
        const d: i64 = @divExact(@as(i64, @intCast(to)) - @as(i64, @intCast(a.at)), 4);
        a.i(0x54000000 | ((@as(u32, @bitCast(@as(i32, @intCast(d)))) & 0x7FFFF) << 5) | cond);
    }
    /// A forward branch to patch (`here`): b.cond (cond 14: b).
    fn fwd(a: *A, cond: u4) usize {
        const at = a.at;
        a.i(if (cond == 14) @as(u32, 0x14000000) else @as(u32, 0x54000000) | cond);
        return at;
    }
    fn cbz(a: *A, nz: bool, x64: bool, t: u5) usize {
        const at = a.at;
        a.i((if (x64) @as(u32, 0xB4000000) else 0x34000000) | (if (nz) @as(u32, 0x01000000) else 0) | t);
        return at;
    }
    fn tbz(a: *A, nz: bool, t: u5, bit: u5) usize {
        const at = a.at;
        a.i(0x36000000 | (if (nz) @as(u32, 0x01000000) else 0) | (@as(u32, bit) << 19) | t);
        return at;
    }
    /// Points the branch at `at` to `to`.
    fn patch(a: *A, at: usize, to: usize) void {
        const w = a.get(at);
        const d: i64 = @divExact(@as(i64, @intCast(to)) - @as(i64, @intCast(at)), 4);
        const v: u32 = @bitCast(@as(i32, @intCast(d)));
        const nw: u32 = if (w & 0x7C000000 == 0x14000000)
            (w & 0xFC000000) | (v & 0x03FF_FFFF)
        else if (w & 0x7E000000 == 0x36000000)
            (w & 0xFFF8001F) | ((v & 0x3FFF) << 5)
        else
            (w & 0xFF00001F) | ((v & 0x7FFFF) << 5);
        a.put(at, nw);
    }
    fn here(a: *A, at: usize) void {
        a.patch(at, a.at);
    }
};

/// Instruction fetch made to see `n` bytes written at `at`: each cache
/// line cleaned to the point of unification, its instructions invalidated
/// (Galaxy and Linux let EL0 do both: SCTLR_EL1.UCI).
pub fn syncCode(at: [*]u8, n: usize) void {
    var ctr: u64 = undefined;
    asm volatile ("mrs %[c], ctr_el0"
        : [c] "=r" (ctr),
    );
    const dline: usize = @as(usize, 4) << @intCast((ctr >> 16) & 0xF);
    const iline: usize = @as(usize, 4) << @intCast(ctr & 0xF);
    const start = @intFromPtr(at);
    var p = start & ~(dline - 1);
    while (p < start + n) : (p += dline) asm volatile ("dc cvau, %[p]"
        :
        : [p] "r" (p),
        : .{ .memory = true });
    asm volatile ("dsb ish" ::: .{ .memory = true });
    p = start & ~(iline - 1);
    while (p < start + n) : (p += iline) asm volatile ("ic ivau, %[p]"
        :
        : [p] "r" (p),
        : .{ .memory = true });
    asm volatile ("dsb ish\nisb" ::: .{ .memory = true });
}

pub fn emitStubs(j: *Jit) usize {
    var a = A{ .j = j, .at = 0, .lim = 4096 };
    // enter(ctx: x0, code: x1) u64
    a.i(0xA9BA7BFD); // stp x29, x30, [sp, #-96]!
    a.i(0xA90153F3); // stp x19, x20, [sp, #16]
    a.i(0xA9025BF5); // stp x21, x22, [sp, #32]
    a.i(0xA90363F7); // stp x23, x24, [sp, #48]
    a.i(0xA9046BF9); // stp x25, x26, [sp, #64]
    a.i(0xA90573FB); // stp x27, x28, [sp, #80]
    a.mov(true, XCTX, 0);
    a.ld(8, XCPU, XCTX, @offsetOf(jit.Ctx, "cpu"));
    a.ld(8, XRAM, XCTX, @offsetOf(jit.Ctx, "ram"));
    a.ld(8, XBUD, XCTX, C_R14);
    a.ld(8, XREG, XCTX, @offsetOf(jit.Ctx, "regs"));
    a.ld(8, XRT, XCTX, @offsetOf(jit.Ctx, "rtag"));
    a.ld(8, XWT, XCTX, @offsetOf(jit.Ctx, "wtag"));
    a.ld(8, XHO, XCTX, @offsetOf(jit.Ctx, "hoff"));
    a.i(0xD61F0000 | (1 << 5)); // br x1
    off_exit_next = a.at;
    a.movw(0, @intCast(jit.X_NEXT));
    off_exit = a.at;
    a.st(8, XBUD, XCTX, C_R14);
    a.i(0xA94573FB); // ldp x27, x28, [sp, #80]
    a.i(0xA9446BF9);
    a.i(0xA94363F7);
    a.i(0xA9425BF5);
    a.i(0xA94153F3);
    a.i(0xA8C67BFD); // ldp x29, x30, [sp], #96
    a.i(0xD65F03C0); // ret
    j.dirty(0, a.at);
    return (a.at + 63) & ~@as(usize, 63);
}

pub fn run(j: *Jit, entry: usize) u64 {
    const f: *const fn (*jit.Ctx, usize) callconv(.c) u64 = @ptrFromInt(j.rxAddr(0));
    return f(&j.ctx, entry);
}

pub fn setHelpers(j: *Jit, comptime B: type, comptime P: bool) void {
    const M = jit.Mode(B, P);
    j.ctx.helpers[H_STEP] = @intFromPtr(&M.hStep);
    j.ctx.helpers[H_X87] = @intFromPtr(&M.hX87);
    j.ctx.helpers[H_FLAGS] = @intFromPtr(&jit.hFlags);
}

/// A dropped block's entry: EIP set to its start, then the dispatcher
/// (16 bytes: the entry's budget check is that long).
pub fn killEntry(j: *Jit, b: u32) void {
    const k = &jit.blocks[b];
    var a = A{ .j = j, .at = k.code, .lim = k.code + 16 };
    a.i(0x52800000 | (@as(u32, k.eip & 0xFFFF) << 5) | 9);
    a.i(0x72A00000 | (@as(u32, k.eip >> 16) << 5) | 9);
    a.i(0xB9000000 | (@as(u32, R_EIP / 4) << 10) | (@as(u32, XREG) << 5) | 9);
    a.b(off_exit_next);
    j.dirty(k.code, 16);
}

pub fn chainTo(j: *Jit, b: u32, s: u1, t: u32) void {
    const k = &jit.blocks[b];
    var a = A{ .j = j, .at = 0, .lim = j.cm.len };
    a.patch(k.slot_at[s], jit.blocks[t].code);
    j.dirty(k.slot_at[s], 4);
}

pub fn unchain(j: *Jit, b: u32, s: u1) void {
    const k = &jit.blocks[b];
    var a = A{ .j = j, .at = 0, .lim = j.cm.len };
    a.patch(k.slot_at[s], k.slot_at[s] + 4);
    j.dirty(k.slot_at[s], 4);
}

/// Calls helper slot h (x1-x3 already set; x0 = the Ctx).
fn callHelper(a: *A, h: usize) void {
    a.st(8, XBUD, XCTX, C_R14);
    a.mov(true, 0, XCTX);
    a.ld(8, 16, XCTX, C_HELP + h * 8);
    a.i(0xD63F0000 | (16 << 5)); // blr x16
    a.ld(8, XBUD, XCTX, C_R14);
}
/// ... and leave if it says so (its result in x0).
fn callExit(a: *A, h: usize) void {
    callHelper(a, h);
    const go = a.cbz(false, true, 0);
    a.b(off_exit);
    a.here(go);
}

fn chainSlot(a: *A, b: u32, s: u1, to: u32) void {
    const k = &jit.blocks[b];
    k.slot_at[s] = @intCast(a.at);
    a.i(0x14000001); // b .+4 (until chained)
    k.slot_eip[s] = to;
    a.movw(9, to);
    a.st(4, 9, XREG, R_EIP);
    a.movx(0, jit.exitCode(jit.X_NEXT, 0, b * 2 + s + 1));
    a.b(off_exit);
}

// ── Templates ──────────────────────────────────────────────────────────

const Stub = struct { at: usize, eip: u32, next: u32, adj: u32, cont: usize = 0 };

/// The pending flags producer before a Jcc: its class, size, operands in
/// w1 (a) and w2 (b), result in w0.
const Pend = struct { cls: u8, sz: u8 };

const E = struct {
    a: A,
    j: *Jit,
    b: u32,
    mode: u32,
    P: bool,
    a20: bool,
    user: bool,
    s32: bool,
    check: bool,
    eip: u32 = 0,
    next: u32 = 0,
    adj: u32 = 0,
    stubs: [3 * jit.MAX_INS]Stub = undefined,
    ns: usize = 0,
    stub0: usize = 0,
    pend: ?Pend = null,
    deferring: bool = false,

    fn flat(e: *const E, s: u3) bool {
        if (!e.P) return true;
        return e.mode & (@as(u32, 1) << (jit.M_FLAT_SHIFT + @as(u5, s))) != 0;
    }

    fn slowAt(e: *E, at: usize) void {
        if (e.ns >= e.stubs.len) {
            e.a.ok = false;
            return;
        }
        e.stubs[e.ns] = .{ .at = at, .eip = e.eip, .next = e.next, .adj = e.adj };
        e.ns += 1;
    }
    fn slow(e: *E, cond: u4) void {
        e.slowAt(e.a.fwd(cond));
    }

    // ── Addresses ──────────────────────────────────────────────────────

    /// w23 = the operand's offset (with_seg: its linear address).
    fn ea(e: *E, x: *const dec.Ins, comptime with_seg: bool) void {
        const a = &e.a;
        const m = x.ea;
        if (m.base != dec.NONE) a.guest(true, if (m.a16) 2 else 4, XLIN, @intCast(m.base)) else a.movw(XLIN, 0);
        if (m.index != dec.NONE) {
            a.guest(true, if (m.a16) 2 else 4, 9, @intCast(m.index));
            a.rrr(false, 0x0B000000, XLIN, XLIN, 9, @as(u6, m.scale)); // add w23, w23, w9, lsl #scale
        }
        if (m.disp != 0) {
            a.movw(9, m.disp);
            a.add(XLIN, XLIN, 9);
        }
        if (m.a16) a.ext(XLIN, XLIN, 2, false);
        if (with_seg) {
            if (e.P and !e.flat(m.seg) and x.kind != .x87) {
                const acc = accessOf(x);
                e.limit(m.seg, acc.n, acc.w);
            }
            e.addSeg(m.seg);
        }
    }
    fn addSeg(e: *E, s: u3) void {
        const a = &e.a;
        a.ld(4, 9, XREG, R_BASE + 4 * @as(usize, s));
        a.add(XLIN, XLIN, 9);
        if (!e.P and !e.a20) {
            a.movw(9, 0xFFEF_FFFF);
            a.and_(XLIN, XLIN, 9);
        }
    }
    fn limit(e: *E, s: u3, n: u8, write: bool) void {
        const a = &e.a;
        a.mov(false, 9, XLIN); // (zero-extends)
        a.addi(true, false, false, 9, 9, n - 1);
        a.ld(8, 10, XCPU, @as(usize, if (write) O_SEGWHI else O_SEGRHI) + 8 * @as(usize, s));
        a.cmp(true, 9, 10);
        e.slow(GT);
        a.ld(4, 10, XCPU, O_SEGLO + 4 * @as(usize, s));
        a.cmp(false, XLIN, 10);
        e.slow(LO);
    }

    /// x12 = the host address of the n bytes at w23, or the slow stub.
    fn hostOf(e: *E, n: u8, comptime write: bool) void {
        const a = &e.a;
        if (e.P) {
            a.addi(false, false, false, 9, XLIN, n - 1);
            a.ubfx(9, 9, 12, 8); // the TLB index of the last byte
            a.lsr(10, XLIN, 12);
            a.lsl(10, 10, 12);
            a.addi(false, false, false, 10, 10, 1); // the tag: page | 1
            if (e.user) a.addi(false, false, false, 11, 9, 256) else a.mov(false, 11, 9);
            a.ldsc(4, 11, if (write) XWT else XRT, 11);
            a.cmp(false, 11, 10);
            e.slow(NE);
            a.ldsc(8, 12, XHO, 9);
            a.i(0x8B204000 | (@as(u32, XLIN) << 16) | (12 << 5) | 12); // add x12, x12, w23, uxtw
            return;
        }
        // Real mode: conventional memory, or 1 MiB to the RAM's end.
        a.movw(9, 0xA0000 - @as(u32, n));
        a.cmp(false, XLIN, 9);
        const ok = a.fwd(LS);
        a.movw(9, 0x100000);
        a.sub(10, XLIN, 9);
        a.movw(9, @as(u32, @intCast(@import("mem.sig").RAM - 0x100000)) - n);
        a.cmp(false, 10, 9);
        e.slow(HI);
        a.here(ok);
        if (write) {
            // (a page with translated code: the interpreter's write sees it)
            a.ld(8, 13, XCTX, C_PAGES);
            a.lsr(9, XLIN, 12);
            a.ldstr(true, 1, false, 14, 13, 9);
            const z = a.cbz(true, false, 14);
            e.slowAt(z);
            if (n > 1) {
                a.addi(false, false, false, 9, XLIN, n - 1);
                a.lsr(9, 9, 12);
                a.ldstr(true, 1, false, 14, 13, 9);
                e.slowAt(a.cbz(true, false, 14));
            }
        }
        a.i(0x8B204000 | (@as(u32, XLIN) << 16) | (@as(u32, XRAM) << 5) | 12); // add x12, x21, w23, uxtw
    }
    /// w0 = the n bytes at w23 (zero- or sign-extended); n 8: x0.
    fn rd(e: *E, n: u8, signed: bool) void {
        e.hostOf(n, false);
        e.a.ldstr(true, n, signed, 0, 12, ZR);
    }
    /// The n bytes at w23 = w3.
    fn wr(e: *E, n: u8) void {
        e.hostOf(n, true);
        const a = &e.a;
        a.ldstr(false, n, false, 3, 12, ZR);
        if (e.check) {
            a.ld(4, 9, XCTX, C_WLOGN);
            a.cmpi(false, 9, 255);
            const skip = a.fwd(HI);
            a.addi(false, false, false, 10, 9, 1);
            a.st(4, 10, XCTX, C_WLOGN);
            a.ld(8, 10, XCTX, C_WLOG);
            a.ubfm64(9, 9, 60, 59); // x9 <<= 4
            a.rrr(true, 0x0B000000, 10, 10, 9, 0);
            a.st(8, 12, 10, 0);
            a.movw(9, n);
            a.st(8, 9, 10, 8);
            a.here(skip);
        }
    }

    // ── Flags ──────────────────────────────────────────────────────────

    /// The guest's flags of class cls on operands w1, w2 (jit.hFlags).
    fn mat(e: *E, cls: u8, sz: u8) void {
        const a = &e.a;
        // (w1, w2: the operands; the result was stored already)
        a.movw(3, cls | (@as(u32, sz) << 8));
        callHelper(a, H_FLAGS);
    }
    fn flags(e: *E, cls: u8, sz: u8, tm: u32, need: u32) void {
        if (need & tm == 0) return;
        // (deferred only without a slow path: the interpreter's run of
        // it would leave w1/w2 behind)
        if (e.deferring and fusable(cls) and e.ns == e.stub0) {
            e.pend = .{ .cls = cls, .sz = sz };
            return;
        }
        e.mat(cls, sz);
    }

    /// w9 = the guest's CF (ADC, SBB).
    fn cf(e: *E) void {
        e.a.ld(4, 9, XREG, R_FLAGS);
        e.a.ubfx(9, 9, 0, 1);
    }

    /// A branch to a label (patched later) taken when guest condition cc
    /// holds, from the flags in memory.
    fn ccMem(e: *E, cc: u4) usize {
        const a = &e.a;
        const neg = cc & 1 != 0;
        a.ld(4, 9, XREG, R_FLAGS);
        const bit: u5 = switch (cc >> 1) {
            0 => 11,
            1 => 0,
            2 => 6,
            4 => 7,
            5 => 2,
            3 => blk: {
                a.lsr(10, 9, 6);
                a.orr(9, 9, 10); // bit 0: CF | ZF
                break :blk 0;
            },
            6 => blk: {
                a.rrr(false, 0x4A400000, 9, 9, 9, 4); // eor w9, w9, w9, lsr #4: bit 7 = SF ^ OF
                break :blk 7;
            },
            else => blk: {
                a.rrr(false, 0x4A400000, 10, 9, 9, 4);
                a.rrr(false, 0x2A000000, 9, 10, 9, 1); // orr w9, w10, w9, lsl #1: ZF to bit 7
                break :blk 7;
            },
        };
        return a.tbz(!neg, 9, bit);
    }

    // ── Stack ──────────────────────────────────────────────────────────

    fn pushAddr(e: *E, n: u8) void {
        const a = &e.a;
        a.guest(true, if (e.s32) 4 else 2, XSP, regs_mod.ESP);
        a.addi(false, true, false, XSP, XSP, n);
        if (!e.s32) a.ext(XSP, XSP, 2, false);
        a.mov(false, XLIN, XSP);
        if (e.P and !e.flat(regs_mod.SS)) e.limit(regs_mod.SS, n, true);
        e.addSeg(regs_mod.SS);
    }
    fn popAddr(e: *E, from: u3, n: u8) void {
        const a = &e.a;
        a.guest(true, if (e.s32) 4 else 2, XSP, from);
        a.mov(false, XLIN, XSP);
        if (e.P and !e.flat(regs_mod.SS)) e.limit(regs_mod.SS, n, false);
        e.addSeg(regs_mod.SS);
    }
    fn setSp(e: *E) void {
        e.a.guest(false, if (e.s32) 4 else 2, XSP, regs_mod.ESP);
    }
    /// Push w3 (n bytes).
    fn push(e: *E, n: u8) void {
        e.pushAddr(n);
        e.wr(n);
        e.setSp();
    }
    /// w0 = the n bytes popped (SP + n + extra).
    fn pop(e: *E, n: u8, extra: u32) void {
        e.popAddr(regs_mod.ESP, n);
        e.rd(n, false);
        e.a.addi(false, false, false, XSP, XSP, n + extra);
        e.setSp();
    }

    // ── Exits ──────────────────────────────────────────────────────────

    fn exitInd(e: *E, o32: bool) void {
        if (!(e.P and o32)) e.a.ext(0, 0, 2, false);
        e.probe();
    }

    /// EIP = w0; the block there from the fast table, else the dispatcher.
    fn probe(e: *E) void {
        const a = &e.a;
        a.st(4, 0, XREG, R_EIP);
        a.ld(4, 9, XREG, R_BASE + 4 * @as(usize, regs_mod.CS));
        a.add(9, 0, 9); // w9 = lin
        var miss: [4]usize = undefined;
        var nm: usize = 0;
        if (e.P) {
            a.ubfx(10, 9, 12, 8);
            a.lsr(11, 9, 12);
            a.lsl(11, 11, 12);
            a.addi(false, false, false, 11, 11, 1);
            if (e.user) a.addi(false, false, false, 13, 10, 256) else a.mov(false, 13, 10);
            a.ldsc(4, 13, XRT, 13);
            a.cmp(false, 13, 11);
            miss[nm] = a.fwd(NE);
            nm += 1;
            a.ldsc(8, 12, XHO, 10);
            a.i(0x8B204000 | (9 << 16) | (12 << 5) | 12); // add x12, x12, w9, uxtw
        } else {
            if (!e.a20) {
                a.movw(10, 0xFFEF_FFFF);
                a.and_(9, 9, 10);
            }
            a.i(0x8B204000 | (9 << 16) | (@as(u32, XRAM) << 5) | 12); // add x12, x21, w9, uxtw
        }
        // x10 = (((eip << 7) ^ host) & (FAST_N - 1)) * 32
        a.mov(false, 10, 0);
        a.ubfm64(10, 10, 57, 56); // lsl x10, x10, #7
        a.rrr(true, 0x4A000000, 10, 10, 12, 0); // eor
        a.ubfm64(10, 10, 0, @intCast(std.math.log2_int(u32, jit.FAST_N) - 1)); // & (FAST_N - 1)
        a.ubfm64(10, 10, 59, 58); // lsl #5
        a.ld(8, 11, XCTX, C_FAST);
        a.rrr(true, 0x0B000000, 11, 11, 10, 0); // x11 = the entry
        a.ld(8, 13, 11, 0);
        a.cmp(true, 13, 12);
        miss[nm] = a.fwd(NE);
        nm += 1;
        a.movw(13, e.mode);
        a.rrr(true, 0x2A000000, 13, 13, 0, 32); // orr x13, x13, x0, lsl #32: the key
        a.ld(8, 14, 11, 8);
        a.cmp(true, 14, 13);
        miss[nm] = a.fwd(NE);
        nm += 1;
        if (e.P) {
            a.ld(4, 13, XCPU, O_FETCHHI);
            a.ld(8, 14, 11, 24);
            a.cmp(true, 13, 14);
            miss[nm] = a.fwd(LO);
            nm += 1;
        }
        a.ld(8, 13, 11, 16);
        a.i(0xD61F0000 | (13 << 5)); // br x13
        for (miss[0..nm]) |m| a.here(m);
        a.movw(0, @intCast(jit.X_NEXT));
        a.b(off_exit);
    }

    fn exitTo(e: *E, s: u1, to: u32) void {
        const k = &jit.blocks[e.b];
        const off: i64 = @as(i64, k.lo) + (@as(i64, to) - @as(i64, k.eip));
        if (e.mode & jit.M_PAGING == 0 or (off >= 0 and off < 4096)) {
            chainSlot(&e.a, e.b, s, to);
            return;
        }
        e.a.movw(0, to);
        e.probe();
    }
};

const Acc = struct { n: u8, w: bool };

fn accessOf(x: *const dec.Ins) Acc {
    return switch (x.kind) {
        .mov => .{ .n = x.sz, .w = x.dst == .mem },
        .alu => .{ .n = x.sz, .w = x.dst == .mem and x.sub != 7 },
        .test_, .imul, .push, .muldiv => .{ .n = x.sz, .w = false },
        .incdec, .not_, .neg, .shift, .xchg => .{ .n = x.sz, .w = true },
        .movzx, .movsx => .{ .n = x.ssz, .w = false },
        .movsreg => .{ .n = 2, .w = true },
        .setcc => .{ .n = 1, .w = true },
        .jmp_ind, .call_ind => .{ .n = if (x.o32) 4 else 2, .w = false },
        else => .{ .n = x.sz, .w = true },
    };
}

/// The classes whose condition a Jcc can take from the host's NZCV.
fn fusable(cls: u8) bool {
    return switch (cls) {
        jit.F_ADD, jit.F_SUB, jit.F_CMP, jit.F_AND, jit.F_OR, jit.F_XOR, jit.F_INC, jit.F_DEC => true,
        else => false,
    };
}

/// The host condition for guest cc after `fuseCmp` of class cls, or null.
fn fuseCond(cls: u8, cc: u4) ?u4 {
    const n = cc >> 1;
    const neg = cc & 1 != 0;
    const arith = cls == jit.F_SUB or cls == jit.F_CMP or cls == jit.F_DEC or cls == jit.F_ADD or cls == jit.F_INC;
    const subtr = cls == jit.F_SUB or cls == jit.F_CMP;
    const logic = cls == jit.F_AND or cls == jit.F_OR or cls == jit.F_XOR;
    const c: ?u4 = switch (n) {
        0 => if (arith) VS else null,
        1 => if (subtr) LO else if (cls == jit.F_ADD) HS else null,
        2 => EQ,
        3 => if (subtr) LS else null,
        4 => MI,
        5 => null,
        6 => if (arith or logic) LT else null,
        else => if (arith or logic) LE else null,
    };
    const x = c orelse return null;
    return if (neg) x ^ 1 else x;
}

/// NZCV for the pending producer (operands w1, w2, result w0) at its
/// width: the narrow ones shifted to the top.
fn fuseCmp(e: *E, p: Pend) void {
    const a = &e.a;
    const sh: u5 = @intCast(32 - @as(u32, p.sz) * 8);
    switch (p.cls) {
        jit.F_AND, jit.F_OR, jit.F_XOR => {
            if (sh != 0) a.lsl(9, 0, sh) else a.mov(false, 9, 0);
            a.rrr(false, 0x6A000000, ZR, 9, 9, 0); // tst w9, w9
        },
        jit.F_INC, jit.F_DEC => {
            a.movw(10, @as(u32, 1) << sh);
            if (sh != 0) a.lsl(9, 1, sh) else a.mov(false, 9, 1);
            a.rrr(false, if (p.cls == jit.F_INC) 0x2B000000 else 0x6B000000, ZR, 9, 10, 0);
        },
        else => {
            if (sh != 0) {
                a.lsl(9, 1, sh);
                a.lsl(10, 2, sh);
            } else {
                a.mov(false, 9, 1);
                a.mov(false, 10, 2);
            }
            a.rrr(false, if (p.cls == jit.F_ADD) 0x2B000000 else 0x6B000000, ZR, 9, 10, 0);
        },
    }
}

/// w2 = the source operand (register, immediate, memory at w23).
fn ldSrc(e: *E, x: *const dec.Ins) void {
    switch (x.src) {
        .reg => e.a.guest(true, x.sz, 2, x.sreg),
        .imm => e.a.movw(2, x.imm),
        .mem => {
            e.rd(x.sz, false);
            e.a.mov(false, 2, 0);
        },
        else => unreachable,
    }
}

const alu_cls = [8]u8{ jit.F_ADD, jit.F_OR, jit.F_ADC, jit.F_SBB, jit.F_AND, jit.F_SUB, jit.F_XOR, jit.F_CMP };

fn native(e: *E, x: *const dec.Ins, need: u32) bool {
    const a = &e.a;
    const sz = x.sz;
    switch (x.kind) {
        .alu, .test_ => {
            const sub: u3 = if (x.kind == .test_) 4 else @intCast(x.sub);
            const cls = alu_cls[sub];
            // a = w1 (the destination), b = w2
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.mov(false, 1, 0);
            } else a.guest(true, sz, 1, x.dreg);
            if (x.src == .mem) e.ea(x, true);
            ldSrc(e, x);
            switch (sub) {
                0 => a.add(0, 1, 2),
                1 => a.orr(0, 1, 2),
                2 => {
                    e.cf();
                    a.add(0, 1, 2);
                    a.add(0, 0, 9);
                },
                3 => {
                    e.cf();
                    a.sub(0, 1, 2);
                    a.sub(0, 0, 9);
                },
                4 => a.and_(0, 1, 2),
                5, 7 => a.sub(0, 1, 2),
                6 => a.eor(0, 1, 2),
            }
            const writes = x.kind == .alu and sub != 7;
            if (writes) {
                if (x.dst == .mem) {
                    a.mov(false, 3, 0);
                    e.wr(sz);
                } else a.guest(false, sz, 0, x.dreg);
            }
            e.flags(if (x.kind == .test_) jit.F_AND else cls, sz, ARITH, need);
            return true;
        },
        .mov => {
            if (x.dst == .mem) {
                e.ea(x, true);
                if (x.src == .imm) a.movw(3, x.imm) else a.guest(true, sz, 3, x.sreg);
                e.wr(sz);
                return true;
            }
            switch (x.src) {
                .imm => a.movw(0, x.imm),
                .reg => a.guest(true, sz, 0, x.sreg),
                .mem => {
                    e.ea(x, true);
                    e.rd(sz, false);
                },
                else => return false,
            }
            a.guest(false, sz, 0, x.dreg);
            return true;
        },
        .lea => {
            e.ea(x, false);
            a.guest(false, sz, XLIN, x.dreg);
            return true;
        },
        .incdec, .not_, .neg => {
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.mov(false, 1, 0);
            } else a.guest(true, sz, 1, x.dreg);
            var cls: u8 = 0;
            var tm: u32 = ARITH;
            switch (x.kind) {
                .incdec => {
                    a.addi(false, x.sub == 1, false, 0, 1, 1);
                    cls = if (x.sub == 1) jit.F_DEC else jit.F_INC;
                    tm = ARITH & ~CF;
                },
                .not_ => a.rrr(false, 0x2A200000, 0, ZR, 1, 0), // mvn
                else => {
                    a.sub(0, ZR, 1);
                    cls = jit.F_NEG;
                },
            }
            if (x.dst == .mem) {
                a.mov(false, 3, 0);
                e.wr(sz);
            } else a.guest(false, sz, 0, x.dreg);
            if (x.kind != .not_) e.flags(cls, sz, tm, need);
            return true;
        },
        .shift => {
            const bits: u32 = @as(u32, sz) * 8;
            const c: u32 = x.imm;
            if (c == 0 or c >= bits) return false;
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.mov(false, 1, 0);
            } else a.guest(true, sz, 1, x.dreg);
            const cls: u8 = switch (x.sub) {
                0 => jit.F_ROL,
                1 => jit.F_ROR,
                4 => jit.F_SHL,
                5 => jit.F_SHR,
                else => jit.F_SAR,
            };
            const c5: u5 = @intCast(c);
            switch (x.sub) {
                4 => a.lsl(0, 1, c5),
                5 => a.lsr(0, 1, c5),
                7 => {
                    a.ext(0, 1, sz, true);
                    a.asr(0, 0, c5);
                },
                else => {
                    // a rotate at the operand's width: (a << k) | (a >> (bits - k))
                    const k: u32 = if (x.sub == 0) c else bits - c;
                    a.lsl(9, 1, @intCast(k));
                    a.lsr(10, 1, @intCast(bits - k));
                    a.orr(0, 9, 10);
                },
            }
            if (x.dst == .mem) {
                a.mov(false, 3, 0);
                e.wr(sz);
            } else a.guest(false, sz, 0, x.dreg);
            if (need & (if (x.sub <= 1) CF | regs_mod.OF else ARITH) != 0) {
                a.movw(2, c);
                e.mat(cls, sz);
            }
            return true;
        },
        .movzx, .movsx => {
            const signed = x.kind == .movsx;
            if (x.src == .mem) {
                e.ea(x, true);
                e.rd(x.ssz, signed);
            } else {
                a.guest(true, x.ssz, 0, x.sreg);
                a.ext(0, 0, x.ssz, signed);
            }
            a.guest(false, sz, 0, x.dreg);
            return true;
        },
        .imul => {
            if (need & ARITH != 0) return false;
            if (x.src == .mem) e.ea(x, true);
            ldSrc(e, x);
            if (x.sub == 2) a.guest(true, sz, 1, x.dreg) else a.movw(1, x.imm);
            a.rrr(false, 0x1B000000, 0, 1, 2, 31); // mul w0, w1, w2 (madd, ra = wzr)
            a.guest(false, sz, 0, x.dreg);
            return true;
        },
        .cwde => {
            a.guest(true, if (sz == 4) 2 else 1, 0, 0);
            a.ext(0, 0, if (sz == 4) 2 else 1, true);
            a.guest(false, sz, 0, 0);
            return true;
        },
        .cdq => {
            a.guest(true, sz, 0, 0);
            if (sz == 2) a.ext(0, 0, 2, true);
            a.asr(0, 0, 31);
            a.guest(false, sz, 0, regs_mod.EDX);
            return true;
        },
        .xchg => {
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.mov(false, 4, 0);
                a.guest(true, sz, 3, x.sreg);
                e.wr(sz);
                a.guest(false, sz, 4, x.sreg);
                return true;
            }
            a.guest(true, sz, 0, x.dreg);
            a.guest(true, sz, 1, x.sreg);
            a.guest(false, sz, 1, x.dreg);
            a.guest(false, sz, 0, x.sreg);
            return true;
        },
        .bswap => {
            a.guest(true, 4, 0, x.dreg);
            a.i(0x5AC00800); // rev w0, w0
            a.guest(false, 4, 0, x.dreg);
            return true;
        },
        .movsreg => {
            a.ld(2, 4, XREG, R_SEG + 2 * @as(usize, x.sreg));
            if (x.dst == .mem) {
                e.ea(x, true);
                a.mov(false, 3, 4);
                e.wr(2);
            } else a.guest(false, sz, 4, x.dreg);
            return true;
        },
        .setcc => {
            if (x.dst == .mem) e.ea(x, true);
            const tk = e.ccMem(@intCast(x.sub));
            a.movw(3, 0);
            const done = a.fwd(14);
            a.here(tk);
            a.movw(3, 1);
            a.here(done);
            if (x.dst == .mem) e.wr(1) else a.guest(false, 1, 3, x.dreg);
            return true;
        },
        .flagop => {
            a.ld(4, 9, XREG, R_FLAGS);
            switch (x.sub) {
                0, 1, 2 => {
                    a.movw(10, CF);
                    a.rrr(false, if (x.sub == 0) 0x0A200000 else if (x.sub == 1) 0x2A000000 else 0x4A000000, 9, 9, 10, 0);
                },
                else => {
                    a.movw(10, DF);
                    a.rrr(false, if (x.sub == 3) 0x0A200000 else 0x2A000000, 9, 9, 10, 0);
                },
            }
            a.st(4, 9, XREG, R_FLAGS);
            return true;
        },
        .nop => return true,
        .pushf => {
            a.ld(4, 3, XREG, R_FLAGS);
            if (sz == 4) {
                a.movw(9, 0x00FC_FFFF);
                a.and_(3, 3, 9);
            }
            e.push(sz);
            return true;
        },
        .push => {
            switch (x.src) {
                .reg => a.guest(true, sz, 3, x.sreg),
                .imm => a.movw(3, x.imm),
                .mem => {
                    e.ea(x, true);
                    e.rd(sz, false);
                    a.mov(false, 3, 0);
                },
                else => return false,
            }
            e.push(sz);
            return true;
        },
        .pop => {
            e.pop(sz, 0);
            a.guest(false, sz, 0, x.dreg);
            return true;
        },
        .leave => {
            e.popAddr(regs_mod.EBP, sz);
            e.rd(sz, false);
            a.addi(false, false, false, XSP, XSP, sz);
            e.setSp();
            a.guest(false, sz, 0, regs_mod.EBP);
            return true;
        },
        .muldiv => {
            if (sz == 1) return false;
            if (x.sub < 6 and need & ARITH != 0) return false;
            if (x.src == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.mov(false, 2, 0);
            } else a.guest(true, sz, 2, x.sreg);
            a.guest(true, sz, 0, regs_mod.EAX);
            a.guest(true, sz, 1, regs_mod.EDX);
            const signed = x.sub == 5 or x.sub == 7;
            switch (x.sub) {
                4, 5 => {
                    if (sz == 2) {
                        a.ext(0, 0, 2, signed);
                        a.ext(2, 2, 2, signed);
                    }
                    if (sz == 4) {
                        a.i((if (signed) @as(u32, 0x9B200000) else 0x9BA00000) | (2 << 16) | (31 << 10) | (0 << 5) | 0); // [su]mull x0, w0, w2
                        a.ubfm64(1, 0, 32, 63); // x1 = x0 >> 32
                    } else {
                        a.rrr(false, 0x1B000000, 0, 0, 2, 31); // mul
                        a.lsr(1, 0, 16);
                    }
                },
                else => {
                    // x0 = DX:AX / EDX:EAX as 64 bits, x2 the divisor
                    if (sz == 4) {
                        a.rrr(true, 0x2A000000, 0, 0, 1, 32); // orr x0, x0, x1, lsl #32 (x0's top was 0)
                        if (signed) a.sbfm64(2, 2, 0, 31);
                    } else {
                        a.rrr(false, 0x2A000000, 0, 0, 1, 16); // (dx << 16) | ax, zero-extended
                        if (signed) {
                            a.sbfm64(0, 0, 0, 31);
                            a.sbfm64(2, 2, 0, 15);
                        }
                    }
                    // a zero divisor (and -1 for IDIV): the interpreter's
                    const z = a.cbz(false, true, 2);
                    e.slowAt(z);
                    if (signed) {
                        a.addi(true, false, true, ZR, 2, 1); // cmn x2, #1
                        e.slow(EQ);
                    }
                    a.rrr(true, if (signed) 0x1AC00C00 else 0x1AC00800, 3, 0, 2, 0); // [su]div x3, x0, x2
                    a.i(0x9B008000 | (2 << 16) | (0 << 10) | (3 << 5) | 1); // msub x1, x3, x2, x0 (the remainder)
                    // the quotient must fit
                    if (signed) {
                        if (sz == 4) a.sbfm64(4, 3, 0, 31) else a.sbfm64(4, 3, 0, 15);
                    } else {
                        if (sz == 4) a.ubfm64(4, 3, 0, 31) else a.ubfm64(4, 3, 0, 15);
                    }
                    a.cmp(true, 4, 3);
                    e.slow(NE);
                    a.mov(true, 0, 3);
                },
            }
            a.guest(false, sz, 0, regs_mod.EAX);
            a.guest(false, sz, 1, regs_mod.EDX);
            return true;
        },
        .x87 => {
            if (e.mode & jit.M_FPU == 0) return false;
            if (x.mem) e.ea(x, true) else a.movw(XLIN, 0);
            a.mov(false, 1, XLIN);
            a.movx(2, @as(u64, x.op & 0xFF) | (@as(u64, x.modrm) << 8) | (@as(u64, @intFromBool(x.o32)) << 16) | (@as(u64, e.adj) << 24));
            a.movx(3, @as(u64, e.eip) | (@as(u64, e.next) << 32));
            callExit(a, H_X87);
            return true;
        },
        else => return false,
    }
}

fn helperIns(e: *E) void {
    const a = &e.a;
    a.movx(1, @as(u64, e.eip) | (@as(u64, e.next) << 32));
    a.movw(2, e.adj);
    callExit(a, H_STEP);
}

/// The pending flags into memory (on a path that needs them).
fn matPend(e: *E, live: u32) void {
    if (e.pend) |p| if (live & ARITH != 0) e.mat(p.cls, p.sz);
}

fn branch(e: *E, x: *const dec.Ins, live_out: u32) bool {
    const a = &e.a;
    switch (x.kind) {
        .jcc => {
            const cc: u4 = @intCast(x.sub);
            if (e.pend) |p| {
                if (fuseCond(p.cls, cc)) |hc| {
                    fuseCmp(e, p);
                    const taken = a.fwd(hc);
                    matPend(e, live_out);
                    e.exitTo(0, e.next);
                    a.here(taken);
                    matPend(e, live_out);
                    e.exitTo(1, x.target);
                    return true;
                }
                e.mat(p.cls, p.sz);
                e.pend = null;
            }
            const taken = e.ccMem(cc);
            e.exitTo(0, e.next);
            a.here(taken);
            e.exitTo(1, x.target);
            return true;
        },
        .jmp => {
            e.exitTo(0, x.target);
            return true;
        },
        .call => {
            const n: u8 = if (x.o32) 4 else 2;
            a.movw(3, e.next);
            e.push(n);
            e.exitTo(0, x.target);
            return true;
        },
        .ret => {
            const n: u8 = if (x.o32) 4 else 2;
            e.pop(n, x.imm);
            e.exitInd(x.o32);
            return true;
        },
        .jmp_ind, .call_ind => {
            const n: u8 = if (x.o32) 4 else 2;
            if (x.src == .mem) {
                e.ea(x, true);
                e.rd(n, false);
            } else a.guest(true, n, 0, x.sreg);
            if (x.kind == .call_ind) {
                a.mov(false, 5, 0);
                a.movw(3, e.next);
                e.push(n);
                a.mov(false, 0, 5);
            }
            e.exitInd(x.o32);
            return true;
        },
        else => return false,
    }
}

pub fn emitBlock(j: *Jit, b: u32, ins: []const dec.Ins, mode: u32, comptime B: type, comptime P: bool) bool {
    _ = B;
    const k = &jit.blocks[b];
    const start = j.used;
    var e = E{
        .a = A{ .j = j, .at = start, .lim = @min(j.cm.len, start + jit.MAX_CODE) },
        .j = j,
        .b = b,
        .mode = mode,
        .P = P,
        .a20 = mode & jit.M_A20 != 0,
        .user = mode & jit.M_USER != 0,
        .s32 = P and mode & jit.M_STACK32 != 0,
        .check = mode & jit.M_CHECK != 0,
    };
    const a = &e.a;
    k.code = @intCast(start);
    const n: u32 = @intCast(ins.len);
    const wrap: u32 = if (P and mode & jit.M_CODE32 != 0) 0xFFFF_FFFF else 0xFFFF;
    var after: [jit.MAX_INS]u32 = undefined;
    const live_out = jit.liveness(ins, &after, e.check, j.live_out);
    // Entry: the budget (16 bytes: killEntry's room).
    a.cmpi(true, XBUD, n);
    const to_budget = a.fwd(LT);
    a.addi(true, true, false, XBUD, XBUD, n);
    a.i(0xD503201F); // nop
    var eip = k.eip;
    var ended = false;
    for (ins, 0..) |*x, i| {
        e.eip = eip;
        e.next = (eip +% x.len) & wrap;
        e.adj = n - @as(u32, @intCast(i)) - 1;
        e.stub0 = e.ns;
        const last = i + 1 == ins.len;
        e.deferring = !last and ins[i + 1].kind == .jcc;
        if (last and x.term) {
            const save = a.at;
            const save_ns = e.ns;
            if (branch(&e, x, live_out)) {
                ended = true;
            } else {
                a.at = save;
                e.ns = save_ns;
                if (e.pend) |p| e.mat(p.cls, p.sz);
                e.pend = null;
                helperIns(&e);
            }
        } else {
            const save = a.at;
            const save_ns = e.ns;
            if (!native(&e, x, after[i])) {
                a.at = save;
                e.ns = save_ns;
                e.pend = null;
                helperIns(&e);
            } else if (e.pend) |p| {
                if (fuseCond(p.cls, @intCast(ins[i + 1].sub)) == null) {
                    e.mat(p.cls, p.sz);
                    e.pend = null;
                }
            }
        }
        var q = e.stub0;
        while (q < e.ns) : (q += 1) e.stubs[q].cont = a.at;
        eip = e.next;
    }
    if (!ended) e.exitTo(0, eip) else {
        var q = e.stub0;
        while (q < e.ns) : (q += 1) e.stubs[q].cont = a.at;
        a.movw(9, eip);
        a.st(4, 9, XREG, R_EIP);
        a.movw(0, @intCast(jit.X_NEXT));
        a.b(off_exit);
    }
    // The slow stubs: the interpreter runs the whole instruction (a
    // deferred producer's flags: in memory then, and the Jcc after it
    // takes them from there: the stub goes to the memory test).
    for (e.stubs[0..e.ns]) |st| {
        a.here(st.at);
        a.movx(1, @as(u64, st.eip) | (@as(u64, st.next) << 32));
        a.movw(2, st.adj);
        callExit(a, H_STEP);
        a.b(st.cont);
    }
    a.here(to_budget);
    a.movw(9, k.eip);
    a.st(4, 9, XREG, R_EIP);
    a.movw(0, @intCast(jit.X_BUDGET));
    a.b(off_exit);
    if (!a.ok) return false;
    j.dirty(start, a.at - start);
    j.used = (a.at + 15) & ~@as(usize, 15);
    return true;
}
