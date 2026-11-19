//! The translator's x86-64 code generator (jit.sig). Generated code runs
//! with rbx = the Cpu (the guest's registers stay in `Cpu.regs`), r15 =
//! the Ctx, r13 = the RAM's host address, r14 = the budget (instructions
//! left: a block's entry checks it and takes its length off); rax, rcx,
//! rdx, rsi, rdi, r8-r11 are scratch, the stack 16-byte aligned for calls
//! into the helpers (Sig functions with the C calling convention).
//! Written from Intel's Software Developer's Manual (volume 2).

const std = @import("std");
const jit = @import("jit.sig");
const dec = jit.dec;
const cpu_mod = @import("cpu.sig");
const regs_mod = @import("regs.sig");
const Cpu = cpu_mod.Cpu;
const Jit = jit.Jit;

const RAX: u4 = 0;
const RCX: u4 = 1;
const RDX: u4 = 2;
const RBX: u4 = 3;
const RSP: u4 = 4;
const RBP: u4 = 5;
const RSI: u4 = 6;
const RDI: u4 = 7;
const R8: u4 = 8;
const R9: u4 = 9;
const R10: u4 = 10;
const R11: u4 = 11;
const R12: u4 = 12;
const R13: u4 = 13;
const R14: u4 = 14;
const R15: u4 = 15;

// Offsets generated code uses.
const O_R = @offsetOf(Cpu, "regs") + @offsetOf(regs_mod.Regs, "r");
const O_EIP = @offsetOf(Cpu, "regs") + @offsetOf(regs_mod.Regs, "eip");
const O_FLAGS = @offsetOf(Cpu, "regs") + @offsetOf(regs_mod.Regs, "flags");
const C_R14 = @offsetOf(jit.Ctx, "r14");
const C_HELP = @offsetOf(jit.Ctx, "helpers");

/// The helpers' slots in Ctx.helpers.
const H_STEP = 0;

// The fixed stubs' offsets (emitStubs).
var off_exit: usize = 0;
var off_exit_next: usize = 0;

const Mem = struct { base: u4, index: ?u4 = null, scale: u2 = 0, disp: i32 = 0 };
const Rm = union(enum) { r: u4, m: Mem };

/// An assembler over the code memory's writable view at `at`.
const A = struct {
    j: *Jit,
    at: usize,
    lim: usize,
    ok: bool = true,

    fn b(a: *A, x: u8) void {
        if (a.at >= a.lim) {
            a.ok = false;
            return;
        }
        a.j.cm.rw[a.at] = x;
        a.at += 1;
    }
    fn d(a: *A, x: u32) void {
        inline for (0..4) |i| a.b(@truncate(x >> (8 * i)));
    }
    fn q(a: *A, x: u64) void {
        inline for (0..8) |i| a.b(@truncate(x >> (8 * i)));
    }
    fn bytes(a: *A, s: []const u8) void {
        for (s) |x| a.b(x);
    }

    /// A REX prefix if one is needed (w: 64-bit operand).
    fn rex(a: *A, w: bool, r: u4, x: u4, bb: u4) void {
        const v: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | (@as(u8, r >> 3) << 2) | (@as(u8, x >> 3) << 1) | (bb >> 3);
        if (v != 0x40) a.b(v);
    }

    fn modrm(a: *A, reg: u4, rm: Rm) void {
        const rg: u8 = @as(u8, reg & 7) << 3;
        switch (rm) {
            .r => |r| a.b(0xC0 | rg | (r & 7)),
            .m => |m| {
                const lo: u8 = m.base & 7;
                const md: u8 = if (m.disp == 0 and lo != 5) 0 else if (m.disp >= -128 and m.disp < 128) 1 else 2;
                if (m.index != null or lo == 4) {
                    a.b((md << 6) | rg | 4);
                    const ix: u8 = if (m.index) |i| i & 7 else 4;
                    a.b((@as(u8, m.scale) << 6) | (ix << 3) | lo);
                } else a.b((md << 6) | rg | lo);
                if (md == 1) a.b(@bitCast(@as(i8, @intCast(m.disp)))) else if (md == 2) a.d(@bitCast(m.disp));
            },
        }
    }

    /// op reg, rm with operand size sz (1, 2, 4, 8): `ops` the opcode
    /// bytes (the 8-bit form's for sz 1).
    fn op(a: *A, sz: u8, ops: []const u8, reg: u4, rm: Rm) void {
        if (sz == 2) a.b(0x66);
        const bb: u4 = switch (rm) {
            .r => |r| r,
            .m => |m| m.base,
        };
        const x: u4 = switch (rm) {
            .r => 0,
            .m => |m| m.index orelse 0,
        };
        a.rex(sz == 8, reg, x, bb);
        a.bytes(ops);
        a.modrm(reg, rm);
    }

    fn movRegMem(a: *A, sz: u8, r: u4, m: Mem) void {
        a.op(sz, if (sz == 1) &.{0x8A} else &.{0x8B}, r, .{ .m = m });
    }
    fn movMemReg(a: *A, sz: u8, m: Mem, r: u4) void {
        a.op(sz, if (sz == 1) &.{0x88} else &.{0x89}, r, .{ .m = m });
    }
    fn movRR(a: *A, sz: u8, dst: u4, src: u4) void {
        a.op(sz, if (sz == 1) &.{0x88} else &.{0x89}, src, .{ .r = dst });
    }
    /// mov r32, imm32 (zero-extended); mov r64, imm64.
    fn movImm32(a: *A, r: u4, v: u32) void {
        a.rex(false, 0, 0, r);
        a.b(0xB8 + @as(u8, r & 7));
        a.d(v);
    }
    fn movImm64(a: *A, r: u4, v: u64) void {
        a.rex(true, 0, 0, r);
        a.b(0xB8 + @as(u8, r & 7));
        a.q(v);
    }
    /// mov dword/word/byte [m], imm.
    fn movMemImm(a: *A, sz: u8, m: Mem, v: u32) void {
        a.op(sz, if (sz == 1) &.{0xC6} else &.{0xC7}, 0, .{ .m = m });
        if (sz == 1) a.b(@truncate(v)) else if (sz == 2) {
            a.b(@truncate(v));
            a.b(@truncate(v >> 8));
        } else a.d(v);
    }
    /// The ALU group (0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP) with
    /// an immediate.
    fn aluImm(a: *A, sz: u8, sub: u3, rm: Rm, v: u32) void {
        if (sz == 1) {
            a.op(1, &.{0x80}, sub, rm);
            a.b(@truncate(v));
            return;
        }
        const s: i32 = @bitCast(v);
        const small = if (sz == 2) (@as(i16, @bitCast(@as(u16, @truncate(v)))) >= -128 and @as(i16, @bitCast(@as(u16, @truncate(v)))) < 128) else (s >= -128 and s < 128);
        if (small) {
            a.op(sz, &.{0x83}, sub, rm);
            a.b(@truncate(v));
        } else {
            a.op(sz, &.{0x81}, sub, rm);
            if (sz == 2) {
                a.b(@truncate(v));
                a.b(@truncate(v >> 8));
            } else a.d(v);
        }
    }
    /// op rm, reg for the ALU group (ADD..CMP: 00+8*sub).
    fn aluRmReg(a: *A, sz: u8, sub: u3, rm: Rm, reg: u4) void {
        const base: u8 = @as(u8, sub) << 3;
        a.op(sz, &.{if (sz == 1) base else base + 1}, reg, rm);
    }
    fn aluRegRm(a: *A, sz: u8, sub: u3, reg: u4, rm: Rm) void {
        const base: u8 = (@as(u8, sub) << 3) + 2;
        a.op(sz, &.{if (sz == 1) base else base + 1}, reg, rm);
    }

    /// A jump/call rel32 to code offset `to`.
    fn jmpTo(a: *A, to: usize) void {
        a.b(0xE9);
        a.rel(to);
    }
    fn jccTo(a: *A, cc: u4, to: usize) void {
        a.b(0x0F);
        a.b(0x80 | @as(u8, cc));
        a.rel(to);
    }
    fn rel(a: *A, to: usize) void {
        const r: i64 = @as(i64, @intCast(to)) - @as(i64, @intCast(a.at + 4));
        a.d(@bitCast(@as(i32, @intCast(r))));
    }
    /// A jcc rel32 to be patched: returns where its rel32 is.
    fn jccFwd(a: *A, cc: u4) usize {
        a.b(0x0F);
        a.b(0x80 | @as(u8, cc));
        const at = a.at;
        a.d(0);
        return at;
    }
    fn jmpFwd(a: *A) usize {
        a.b(0xE9);
        const at = a.at;
        a.d(0);
        return at;
    }
    /// Points the rel32 at `at` to the current position.
    fn here(a: *A, at: usize) void {
        a.patch(at, a.at);
    }
    fn patch(a: *A, at: usize, to: usize) void {
        const r: i64 = @as(i64, @intCast(to)) - @as(i64, @intCast(at + 4));
        const v: u32 = @bitCast(@as(i32, @intCast(r)));
        inline for (0..4) |i| a.j.cm.rw[at + i] = @truncate(v >> (8 * i));
    }
};

const CC_Z: u4 = 4;
const CC_NZ: u4 = 5;
const CC_L: u4 = 12;
const CC_LE: u4 = 14;

fn cpuMem(off: usize) Mem {
    return .{ .base = RBX, .disp = @intCast(off) };
}
fn ctxMem(off: usize) Mem {
    return .{ .base = R15, .disp = @intCast(off) };
}

/// Nothing to do on x86-64: its instruction fetch sees stores.
pub fn syncCode(at: [*]u8, n: usize) void {
    _ = at;
    _ = n;
}

/// The entry and exits, at the code memory's start; returns their end.
pub fn emitStubs(j: *Jit) usize {
    var a = A{ .j = j, .at = 0, .lim = 4096 };
    // enter(ctx: rdi, code: rsi) u64
    for ([_]u4{ RBX, RBP, R12, R13, R14, R15 }) |r| {
        a.rex(false, 0, 0, r);
        a.b(0x50 + @as(u8, r & 7));
    }
    a.bytes(&.{ 0x48, 0x83, 0xEC, 0x08 }); // sub rsp, 8
    a.movRR(8, R15, RDI);
    a.movRegMem(8, RBX, ctxMem(@offsetOf(jit.Ctx, "cpu")));
    a.movRegMem(8, R13, ctxMem(@offsetOf(jit.Ctx, "ram")));
    a.movRegMem(8, R14, ctxMem(C_R14));
    a.bytes(&.{ 0xFF, 0xE6 }); // jmp rsi
    // exit_next: rax = X_NEXT (a dropped block's entry comes here).
    off_exit_next = a.at;
    a.movImm32(RAX, @intCast(jit.X_NEXT));
    // exit: rax = the code.
    off_exit = a.at;
    a.movMemReg(8, ctxMem(C_R14), R14);
    a.bytes(&.{ 0x48, 0x83, 0xC4, 0x08 }); // add rsp, 8
    for ([_]u4{ R15, R14, R13, R12, RBP, RBX }) |r| {
        a.rex(false, 0, 0, r);
        a.b(0x58 + @as(u8, r & 7));
    }
    a.b(0xC3);
    j.dirty(0, a.at);
    return (a.at + 63) & ~@as(usize, 63);
}

/// Generated code from `entry` (an executable address) until it exits.
pub fn run(j: *Jit, entry: usize) u64 {
    const f: *const fn (*jit.Ctx, usize) callconv(.c) u64 = @ptrFromInt(j.rxAddr(0));
    return f(&j.ctx, entry);
}

/// The helpers for the mode about to run (bus type B, protected mode P).
pub fn setHelpers(j: *Jit, comptime B: type, comptime P: bool) void {
    const M = jit.Mode(B, P);
    j.ctx.helpers[H_STEP] = @intFromPtr(&M.hStep);
    j.ctx.helpers[H_X87] = @intFromPtr(&M.hX87);
}

/// A dropped block's entry: EIP set to its start, then the dispatcher.
pub fn killEntry(j: *Jit, b: u32) void {
    const k = &jit.blocks[b];
    var a = A{ .j = j, .at = k.code, .lim = k.code + 16 };
    // mov dword [rbx+disp32], imm32 (10 bytes); jmp exit_next (5)
    a.b(0xC7);
    a.b(0x83);
    a.d(@intCast(O_EIP));
    a.d(k.eip);
    a.jmpTo(off_exit_next);
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

/// Calls helper slot h with rsi, rdx already set; rdi = the Ctx.
fn callHelper(a: *A, h: usize) void {
    a.movMemReg(8, ctxMem(C_R14), R14);
    a.movRR(8, RDI, R15);
    a.op(4, &.{0xFF}, 2, .{ .m = ctxMem(C_HELP + h * 8) }); // call [r15+..]
    a.movRegMem(8, R14, ctxMem(C_R14));
}

/// An exit that may be chained: block b's slot s to EIP `to`.
fn chainSlot(a: *A, b: u32, s: u1, to: u32) void {
    const k = &jit.blocks[b];
    a.b(0xE9);
    k.slot_at[s] = @intCast(a.at);
    a.d(0); // (rel 0: the next instruction, until chained)
    k.slot_eip[s] = to;
    a.movMemImm(4, cpuMem(O_EIP), to);
    a.movImm64(RAX, jit.exitCode(jit.X_NEXT, 0, b * 2 + s + 1));
    a.jmpTo(off_exit);
}


// ── Templates ──────────────────────────────────────────────────────────

const pm = @import("cpu_pm.sig");
const Regs = regs_mod.Regs;
const O_BASE = @offsetOf(Cpu, "regs") + @offsetOf(Regs, "base");
const O_SEGS = @offsetOf(Cpu, "regs") + @offsetOf(Regs, "seg");
const O_TLB = @offsetOf(Cpu, "tlb");
const O_RTAG = O_TLB + @offsetOf(pm.Tlb, "rtag");
const O_WTAG = O_TLB + @offsetOf(pm.Tlb, "wtag");
const O_HOFF = O_TLB + @offsetOf(pm.Tlb, "hoff");
const C_PAGES = @offsetOf(jit.Ctx, "pages");
const C_WLOG = @offsetOf(jit.Ctx, "wlog");
const C_WLOGN = @offsetOf(jit.Ctx, "wlog_n");
const H_X87 = 1;

const ARITH: u32 = dec.ARITH;
const CF: u32 = regs_mod.CF;
const AF: u32 = regs_mod.AF;
const OF: u32 = regs_mod.OF;
const DF: u32 = regs_mod.DF;

/// Guest register i of size sz (AH..BH: the second byte of EAX..EBX).
fn gr(i: u3, sz: u8) Mem {
    if (sz == 1 and i >= 4) return cpuMem(O_R + 4 * @as(usize, i - 4) + 1);
    return cpuMem(O_R + 4 * @as(usize, i));
}
fn grFull(i: u4) Mem {
    return cpuMem(O_R + 4 * @as(usize, i));
}
const FLAGS = Mem{ .base = RBX, .disp = @intCast(O_FLAGS) };

/// Host-exact (hm) and written (tm) flags of a producer.
const Fl = struct { hm: u32, tm: u32 };

const Stub = struct { at: usize, eip: u32, next: u32, adj: u32, popf: bool, cont: usize = 0 };

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
    pend: ?Fl = null,
    /// This instruction defers its flags to the Jcc after it.
    deferring: bool = false,

    fn flat(e: *const E, s: u3) bool {
        if (!e.P) return true;
        return e.mode & (@as(u32, 1) << (jit.M_FLAT_SHIFT + @as(u5, s))) != 0;
    }

    /// A conditional jump to a slow stub (the interpreter runs the whole
    /// instruction): `cc` the host condition.
    fn slow(e: *E, cc: u4) void {
        const at = e.a.jccFwd(cc);
        if (e.ns >= e.stubs.len) {
            e.a.ok = false;
            return;
        }
        e.stubs[e.ns] = .{ .at = at, .eip = e.eip, .next = e.next, .adj = e.adj, .popf = false };
        e.ns += 1;
    }

    // ── Addresses ──────────────────────────────────────────────────────

    /// r12d = the operand's offset (with_seg: its linear address; in real
    /// mode with the A20 gate off, its bus address).
    fn ea(e: *E, x: *const dec.Ins, comptime with_seg: bool) void {
        const a = &e.a;
        const m = x.ea;
        if (m.a16) {
            if (m.base != dec.NONE) a.op(4, &.{ 0x0F, 0xB7 }, R12, .{ .m = grFull(m.base) }) else a.movImm32(R12, 0);
            if (m.index != dec.NONE) {
                a.op(4, &.{ 0x0F, 0xB7 }, RAX, .{ .m = grFull(m.index) });
                a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .index = RAX, .disp = @bitCast(m.disp) } });
            } else if (m.disp != 0) a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .disp = @bitCast(m.disp) } });
            a.op(4, &.{ 0x0F, 0xB7 }, R12, .{ .r = R12 }); // movzx r12d, r12w
        } else {
            if (m.base != dec.NONE) {
                a.movRegMem(4, R12, grFull(m.base));
                if (m.index != dec.NONE) {
                    a.movRegMem(4, RAX, grFull(m.index));
                    a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .index = RAX, .scale = m.scale, .disp = @bitCast(m.disp) } });
                } else if (m.disp != 0) a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .disp = @bitCast(m.disp) } });
            } else {
                a.movImm32(R12, m.disp);
                if (m.index != dec.NONE) {
                    a.movRegMem(4, RAX, grFull(m.index));
                    a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .index = RAX, .scale = m.scale } });
                }
            }
        }
        if (with_seg) e.addSeg(m.seg);
    }

    fn addSeg(e: *E, s: u3) void {
        const a = &e.a;
        a.movRegMem(4, RAX, cpuMem(O_BASE + 4 * @as(usize, s)));
        a.op(4, &.{0x8D}, R12, .{ .m = .{ .base = R12, .index = RAX } });
        if (!e.P and !e.a20) a.aluImm(4, 4, .{ .r = R12 }, 0xFFEF_FFFF);
    }

    /// The host address of the n bytes at r12d (rax + r12), or the slow
    /// stub: the TLB's entry for the access's last byte (protected mode),
    /// the RAM's range (real mode).
    fn hostOf(e: *E, n: u8, comptime write: bool) Mem {
        const a = &e.a;
        if (e.P) {
            if (n == 1) a.movRR(4, RAX, R12) else a.op(4, &.{0x8D}, RAX, .{ .m = .{ .base = R12, .disp = n - 1 } });
            a.bytes(&.{ 0xC1, 0xE8, 0x0C }); // shr eax, 12
            a.bytes(&.{ 0x0F, 0xB6, 0xC0 }); // movzx eax, al
            a.movRR(4, RDX, R12);
            a.aluImm(4, 4, .{ .r = RDX }, 0xFFFF_F000);
            a.aluImm(4, 1, .{ .r = RDX }, 1);
            const u: usize = @intFromBool(e.user);
            const tags: usize = (if (write) O_WTAG else O_RTAG) + u * pm.TLB_N * 4;
            a.aluRmReg(4, 7, .{ .m = .{ .base = RBX, .index = RAX, .scale = 2, .disp = @intCast(tags) } }, RDX);
            e.slow(CC_NZ);
            a.movRegMem(8, RAX, .{ .base = RBX, .index = RAX, .scale = 3, .disp = @intCast(O_HOFF) });
            return .{ .base = RAX, .index = R12 };
        }
        // Real mode: conventional memory, or 1 MiB to the RAM's end.
        a.aluImm(4, 7, .{ .r = R12 }, 0xA0000 - @as(u32, n));
        const ok = a.jccFwd(6); // jbe
        a.op(4, &.{0x8D}, RAX, .{ .m = .{ .base = R12, .disp = -0x100000 } });
        a.aluImm(4, 7, .{ .r = RAX }, @as(u32, @intCast(@import("mem.sig").RAM - 0x100000)) - n);
        e.slow(7); // ja
        a.here(ok);
        if (write) {
            // (a page with translated code: the interpreter's write sees it)
            a.movRegMem(8, RDX, ctxMem(C_PAGES));
            a.movRR(4, RAX, R12);
            a.bytes(&.{ 0xC1, 0xE8, 0x0C }); // shr eax, 12
            a.op(1, &.{0x80}, 7, .{ .m = .{ .base = RDX, .index = RAX } });
            a.b(0);
            e.slow(CC_NZ);
            if (n > 1) {
                a.op(4, &.{0x8D}, RAX, .{ .m = .{ .base = R12, .disp = n - 1 } });
                a.bytes(&.{ 0xC1, 0xE8, 0x0C });
                a.op(1, &.{0x80}, 7, .{ .m = .{ .base = RDX, .index = RAX } });
                a.b(0);
                e.slow(CC_NZ);
            }
        }
        return .{ .base = R13, .index = R12 };
    }

    /// eax = the n bytes at r12d (zero-extended; `signed`: sign-).
    fn rd(e: *E, n: u8, signed: bool) void {
        const m = e.hostOf(n, false);
        const a = &e.a;
        switch (n) {
            1 => a.op(4, &.{ 0x0F, if (signed) 0xBE else 0xB6 }, RAX, .{ .m = m }),
            2 => a.op(4, &.{ 0x0F, if (signed) 0xBF else 0xB7 }, RAX, .{ .m = m }),
            else => a.movRegMem(4, RAX, m),
        }
    }

    /// The n bytes at r12d = cl/cx/ecx.
    fn wr(e: *E, n: u8) void {
        const m = e.hostOf(n, true);
        const a = &e.a;
        a.movMemReg(n, m, RCX);
        if (e.check) {
            // (lockstep: the store's host address into the write log)
            a.op(8, &.{0x8D}, RDX, .{ .m = m });
            a.movRegMem(4, RAX, ctxMem(C_WLOGN));
            a.aluImm(4, 7, .{ .r = RAX }, 255);
            const skip = a.jccFwd(7);
            a.op(4, &.{0xFF}, 0, .{ .m = ctxMem(C_WLOGN) }); // inc dword
            a.bytes(&.{ 0xC1, 0xE0, 0x04 }); // shl eax, 4
            a.movRegMem(8, RCX, ctxMem(C_WLOG));
            a.movMemReg(8, .{ .base = RCX, .index = RAX }, RDX);
            a.op(8, &.{0xC7}, 0, .{ .m = .{ .base = RCX, .index = RAX, .disp = 8 } });
            a.d(n);
            a.here(skip);
        }
    }

    // ── Flags ──────────────────────────────────────────────────────────

    /// The host's flags (of the last operation) into the guest's: the
    /// bits of tm, those of hm from the host, the rest 0. `from`: a
    /// register they were saved in (pushfq; pop r) instead.
    fn mat(e: *E, f: Fl, from: ?u4) void {
        const a = &e.a;
        var r: u4 = RAX;
        if (from) |x| r = x else {
            a.b(0x9C); // pushfq
            a.b(0x58); // pop rax
        }
        a.aluImm(4, 4, .{ .r = r }, f.hm);
        a.aluImm(4, 4, .{ .m = FLAGS }, ~f.tm);
        a.aluRmReg(4, 1, .{ .m = FLAGS }, r);
    }

    /// A producer's flags: needed (`need`) now, or by the Jcc after it
    /// (deferred: the host keeps them).
    fn flags(e: *E, f: Fl, need: u32) void {
        if (need & f.tm == 0) return;
        if (e.deferring) {
            e.pend = f;
            var i = e.stub0;
            while (i < e.ns) : (i += 1) e.stubs[i].popf = true;
            return;
        }
        e.mat(f, null);
    }

    /// Host CF = the guest's (ADC, SBB).
    fn loadCf(e: *E) void {
        e.a.op(4, &.{ 0x0F, 0xBA }, 4, .{ .m = FLAGS });
        e.a.b(0);
    }

    /// Condition cc from the guest's flags in memory: returns the host
    /// condition that holds when it does (after the test emitted).
    fn ccMem(e: *E, cc: u4) u4 {
        const a = &e.a;
        const neg = cc & 1 != 0;
        switch (cc >> 1) {
            0 => {
                a.op(4, &.{0xF7}, 0, .{ .m = FLAGS });
                a.d(OF);
            },
            1, 2, 3, 4, 5 => {
                const bits: u8 = switch (cc >> 1) {
                    1 => 0x01,
                    2 => 0x40,
                    3 => 0x41,
                    4 => 0x80,
                    else => 0x04,
                };
                a.op(1, &.{0xF6}, 0, .{ .m = FLAGS });
                a.b(bits);
            },
            6, 7 => {
                a.movRegMem(4, RAX, FLAGS);
                a.movRR(4, RCX, RAX);
                a.bytes(&.{ 0xC1, 0xE9, 0x04 }); // shr ecx, 4 (OF to bit 7)
                a.aluRmReg(4, 6, .{ .r = RCX }, RAX); // xor ecx, eax
                a.aluImm(4, 4, .{ .r = RCX }, 0x80);
                if (cc >> 1 == 7) {
                    a.aluImm(4, 4, .{ .r = RAX }, 0x40);
                    a.aluRmReg(4, 1, .{ .r = RCX }, RAX);
                }
            },
            else => unreachable,
        }
        return if (neg) CC_Z else CC_NZ;
    }

    // ── Stack ──────────────────────────────────────────────────────────

    /// ebp = SP less n (the stack's width), r12d = its linear address.
    fn pushAddr(e: *E, n: u8) void {
        const a = &e.a;
        const sp = grFull(regs_mod.ESP);
        if (e.s32) a.movRegMem(4, RBP, sp) else a.op(4, &.{ 0x0F, 0xB7 }, RBP, .{ .m = sp });
        a.aluImm(4, 5, .{ .r = RBP }, n);
        if (!e.s32) a.op(4, &.{ 0x0F, 0xB7 }, RBP, .{ .r = RBP });
        a.movRR(4, R12, RBP);
        e.addSeg(regs_mod.SS);
    }
    /// ebp = the stack offset in register `from` (its width), r12d = its
    /// linear address.
    fn popAddr(e: *E, from: u3) void {
        const a = &e.a;
        if (e.s32) a.movRegMem(4, RBP, grFull(from)) else a.op(4, &.{ 0x0F, 0xB7 }, RBP, .{ .m = grFull(from) });
        a.movRR(4, R12, RBP);
        e.addSeg(regs_mod.SS);
    }
    /// SP = ebp (its width).
    fn setSp(e: *E) void {
        e.a.movMemReg(if (e.s32) 4 else 2, grFull(regs_mod.ESP), RBP);
    }
    /// Push ecx (n bytes).
    fn push(e: *E, n: u8) void {
        e.pushAddr(n);
        e.wr(n);
        e.setSp();
    }
    /// eax = the n bytes popped (SP + n + extra).
    fn pop(e: *E, n: u8, extra: u32) void {
        e.popAddr(regs_mod.ESP);
        e.rd(n, false);
        e.a.aluImm(4, 0, .{ .r = RBP }, n + extra);
        e.setSp();
    }

    // ── Exits ──────────────────────────────────────────────────────────

    /// EIP = eax (16 bits unless 32-bit operands in protected mode), then
    /// the block there or the dispatcher.
    fn exitInd(e: *E, o32: bool) void {
        const a = &e.a;
        if (!(e.P and o32)) a.op(4, &.{ 0x0F, 0xB7 }, RAX, .{ .r = RAX });
        e.probe();
    }

    /// EIP = eax; the block there if the fast table has it for the code
    /// the TLB (or the RAM in real mode) has at CS:EIP now, else the
    /// dispatcher.
    fn probe(e: *E) void {
        const a = &e.a;
        a.movMemReg(4, cpuMem(O_EIP), RAX);
        if (!e.P or e.mode & jit.M_CSFLAT != 0) {
            a.movRR(4, RCX, RAX);
            a.aluRegRm(4, 0, RAX, .{ .m = cpuMem(O_BASE + 4 * @as(usize, regs_mod.CS)) }); // add eax, [cs base]
            var miss: [2]usize = .{ 0, 0 };
            var nm: usize = 0;
            if (e.P) {
                a.movRR(4, RDX, RAX);
                a.bytes(&.{ 0xC1, 0xEA, 0x0C }); // shr edx, 12
                a.bytes(&.{ 0x0F, 0xB6, 0xD2 }); // movzx edx, dl
                a.movRR(4, RSI, RAX);
                a.aluImm(4, 4, .{ .r = RSI }, 0xFFFF_F000);
                a.aluImm(4, 1, .{ .r = RSI }, 1);
                const tags: usize = O_RTAG + @as(usize, @intFromBool(e.user)) * pm.TLB_N * 4;
                a.aluRmReg(4, 7, .{ .m = .{ .base = RBX, .index = RDX, .scale = 2, .disp = @intCast(tags) } }, RSI);
                miss[nm] = a.jccFwd(CC_NZ);
                nm += 1;
                a.movRegMem(8, RDX, .{ .base = RBX, .index = RDX, .scale = 3, .disp = @intCast(O_HOFF) });
                a.aluRmReg(8, 0, .{ .r = RDX }, RAX); // add rdx, rax
            } else {
                if (!e.a20) a.aluImm(4, 4, .{ .r = RAX }, 0xFFEF_FFFF);
                a.op(8, &.{0x8D}, RDX, .{ .m = .{ .base = R13, .index = RAX } });
            }
            // rax = ((eip << 7) ^ host) & (FAST_N - 1), times 24
            a.movRR(4, RAX, RCX);
            a.bytes(&.{ 0x48, 0xC1, 0xE0, 0x07 }); // shl rax, 7
            a.aluRmReg(8, 6, .{ .r = RAX }, RDX); // xor rax, rdx
            a.aluImm(4, 4, .{ .r = RAX }, jit.FAST_N - 1);
            a.op(8, &.{0x8D}, RAX, .{ .m = .{ .base = RAX, .index = RAX, .scale = 1 } }); // lea rax, [rax+rax*2]
            a.bytes(&.{ 0x48, 0xC1, 0xE0, 0x03 }); // shl rax, 3
            a.movRegMem(8, RSI, ctxMem(@offsetOf(jit.Ctx, "fast")));
            a.aluRegRm(8, 7, RDX, .{ .m = .{ .base = RSI, .index = RAX } }); // cmp rdx, [host]
            miss[nm] = a.jccFwd(CC_NZ);
            nm += 1;
            a.bytes(&.{ 0x48, 0xC1, 0xE1, 0x20 }); // shl rcx, 32
            a.aluImm(8, 1, .{ .r = RCX }, e.mode); // or rcx, mode
            a.aluRegRm(8, 7, RCX, .{ .m = .{ .base = RSI, .index = RAX, .disp = 8 } });
            const miss2 = a.jccFwd(CC_NZ);
            a.op(4, &.{0xFF}, 4, .{ .m = .{ .base = RSI, .index = RAX, .disp = 16 } }); // jmp [..]
            for (miss[0..nm]) |m| a.here(m);
            a.here(miss2);
        }
        a.movImm32(RAX, @intCast(jit.X_NEXT));
        a.jmpTo(off_exit);
    }

    /// The exit to EIP `to` at block end: a chain slot when the target
    /// can be chained to (on this page, or anywhere while linear pages
    /// cannot move), else the fast table's lookup.
    fn exitTo(e: *E, s: u1, to: u32) void {
        const k = &jit.blocks[e.b];
        const off: i64 = @as(i64, k.lo) + (@as(i64, to) - @as(i64, k.eip));
        if (e.mode & jit.M_PAGING == 0 or (off >= 0 and off < 4096)) {
            chainSlot(&e.a, e.b, s, to);
            return;
        }
        e.a.movImm32(RAX, to);
        e.probe();
    }
};

/// eax = a register's, an immediate or memory's (r12d already the
/// address) sz bytes (for 8/16 the low part).
fn ldSrc(e: *E, x: *const dec.Ins, loc: dec.Loc, r: u3) void {
    switch (loc) {
        .reg => e.a.movRegMem(x.sz, RAX, gr(r, x.sz)),
        .mem => e.rd(x.sz, false),
        .imm => e.a.movImm32(RAX, x.imm),
        else => unreachable,
    }
}

/// The ALU group's flags.
fn aluFl(sub: u8) Fl {
    return switch (sub) {
        1, 4, 6 => .{ .hm = ARITH & ~AF, .tm = ARITH },
        else => .{ .hm = ARITH, .tm = ARITH },
    };
}

fn imm(a: *A, sz: u8, v: u32) void {
    switch (sz) {
        1 => a.b(@truncate(v)),
        2 => {
            a.b(@truncate(v));
            a.b(@truncate(v >> 8));
        },
        else => a.d(v),
    }
}

/// One instruction natively; false: no template (rewound by the caller).
fn native(e: *E, x: *const dec.Ins, need: u32) bool {
    const a = &e.a;
    const sz = x.sz;
    if (x.mem and !e.flat(x.ea.seg) and x.kind != .lea and x.kind != .x87) return false;
    switch (x.kind) {
        .alu, .test_ => {
            const is_test = x.kind == .test_;
            const sub: u3 = if (is_test) 4 else @intCast(x.sub);
            const f = aluFl(sub);
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                if (sub == 2 or sub == 3) e.loadCf();
                if (is_test) {
                    if (x.src == .imm) {
                        a.op(sz, &.{if (sz == 1) 0xF6 else 0xF7}, 0, .{ .r = RAX });
                        imm(a, sz, x.imm);
                    } else a.op(sz, &.{if (sz == 1) 0x84 else 0x85}, RAX, .{ .m = gr(x.sreg, sz) });
                    e.flags(f, need);
                    return true;
                }
                if (x.src == .imm) a.aluImm(sz, sub, .{ .r = RAX }, x.imm) else a.aluRegRm(sz, sub, RAX, .{ .m = gr(x.sreg, sz) });
                if (sub == 7) {
                    e.flags(f, need);
                    return true;
                }
                const keep = need & f.tm != 0;
                if (keep) a.bytes(&.{ 0x9C, 0x5D }); // pushfq; pop rbp
                a.movRR(4, RCX, RAX);
                e.wr(sz);
                if (keep) e.mat(f, RBP);
                return true;
            }
            // A register destination.
            const d = gr(x.dreg, sz);
            if (x.src == .imm) {
                if (sub == 2 or sub == 3) e.loadCf();
                if (is_test) {
                    a.op(sz, &.{if (sz == 1) 0xF6 else 0xF7}, 0, .{ .m = d });
                    imm(a, sz, x.imm);
                } else a.aluImm(sz, sub, .{ .m = d }, x.imm);
            } else {
                if (x.src == .mem) e.ea(x, true);
                ldSrc(e, x, x.src, x.sreg);
                if (sub == 2 or sub == 3) e.loadCf();
                if (is_test) a.op(sz, &.{if (sz == 1) 0x84 else 0x85}, RAX, .{ .m = d }) else a.aluRmReg(sz, sub, .{ .m = d }, RAX);
            }
            e.flags(f, need);
            return true;
        },
        .mov => {
            if (x.dst == .mem) {
                e.ea(x, true);
                if (x.src == .imm) a.movImm32(RCX, x.imm) else a.movRegMem(sz, RCX, gr(x.sreg, sz));
                e.wr(sz);
                return true;
            }
            const d = gr(x.dreg, sz);
            switch (x.src) {
                .imm => a.movMemImm(sz, d, x.imm),
                .reg => {
                    a.movRegMem(sz, RAX, gr(x.sreg, sz));
                    a.movMemReg(sz, d, RAX);
                },
                .mem => {
                    e.ea(x, true);
                    e.rd(sz, false);
                    a.movMemReg(sz, d, RAX);
                },
                else => return false,
            }
            return true;
        },
        .lea => {
            e.ea(x, false);
            a.movMemReg(sz, gr(x.dreg, sz), R12);
            return true;
        },
        .incdec, .not_, .neg => {
            const f: Fl = if (x.kind == .incdec) .{ .hm = ARITH & ~CF, .tm = ARITH & ~CF } else .{ .hm = ARITH, .tm = ARITH };
            const digit: u4 = switch (x.kind) {
                .incdec => @intCast(x.sub),
                .not_ => 2,
                else => 3,
            };
            const opc: u8 = if (x.kind == .incdec) (if (sz == 1) 0xFE else 0xFF) else (if (sz == 1) 0xF6 else 0xF7);
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.op(sz, &.{opc}, digit, .{ .r = RAX });
                const keep = x.kind != .not_ and need & f.tm != 0;
                if (keep) a.bytes(&.{ 0x9C, 0x5D });
                a.movRR(4, RCX, RAX);
                e.wr(sz);
                if (keep) e.mat(f, RBP);
                return true;
            }
            a.op(sz, &.{opc}, digit, .{ .m = gr(x.dreg, sz) });
            if (x.kind != .not_) e.flags(f, need);
            return true;
        },
        .shift => {
            const bits: u32 = @as(u32, sz) * 8;
            const c = x.imm;
            if (c == 0 or c >= bits) return false;
            var f: Fl = undefined;
            var zm: u32 = 0;
            switch (x.sub) {
                0, 1 => f = .{ .hm = CF | (if (c == 1) OF else 0), .tm = CF | OF },
                4, 5 => {
                    f = .{ .hm = ARITH & ~AF & ~(if (c == 1) 0 else OF), .tm = ARITH };
                    zm = AF;
                },
                7 => {
                    f = .{ .hm = ARITH & ~AF & ~(if (c == 1) 0 else OF), .tm = ARITH };
                    zm = AF | (if (c == 1) 0 else OF);
                },
                else => return false,
            }
            const nd = need & f.tm;
            if (nd & ~(f.hm | zm) != 0) return false;
            const opc: u8 = if (c == 1) (if (sz == 1) 0xD0 else 0xD1) else (if (sz == 1) 0xC0 else 0xC1);
            const digit: u4 = @intCast(x.sub);
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.op(sz, &.{opc}, digit, .{ .r = RAX });
                if (c != 1) a.b(@intCast(c));
                const keep = nd != 0;
                if (keep) a.bytes(&.{ 0x9C, 0x5D });
                a.movRR(4, RCX, RAX);
                e.wr(sz);
                if (keep) e.mat(f, RBP);
                return true;
            }
            a.op(sz, &.{opc}, digit, .{ .m = gr(x.dreg, sz) });
            if (c != 1) a.b(@intCast(c));
            e.flags(f, need);
            return true;
        },
        .movzx, .movsx => {
            const signed = x.kind == .movsx;
            if (x.src == .mem) {
                e.ea(x, true);
                e.rd(x.ssz, signed);
            } else {
                const o: u8 = (if (signed) @as(u8, 0xBE) else 0xB6) + (if (x.ssz == 2) @as(u8, 1) else 0);
                a.op(4, &.{ 0x0F, o }, RAX, .{ .m = gr(x.sreg, x.ssz) });
            }
            a.movMemReg(sz, gr(x.dreg, sz), RAX);
            return true;
        },
        .imul => {
            if (need & ARITH != 0) return false;
            if (x.src == .mem) e.ea(x, true);
            ldSrc(e, x, x.src, x.sreg);
            if (x.sub == 2) {
                a.op(sz, &.{ 0x0F, 0xAF }, RAX, .{ .m = gr(x.dreg, sz) });
            } else {
                const v: i32 = if (sz == 2) @as(i16, @bitCast(@as(u16, @truncate(x.imm)))) else @bitCast(x.imm);
                if (v >= -128 and v < 128) {
                    a.op(sz, &.{0x6B}, RAX, .{ .r = RAX });
                    a.b(@truncate(x.imm));
                } else {
                    a.op(sz, &.{0x69}, RAX, .{ .r = RAX });
                    imm(a, sz, x.imm);
                }
            }
            a.movMemReg(sz, gr(x.dreg, sz), RAX);
            return true;
        },
        .cwde => {
            if (sz == 4) {
                a.op(4, &.{ 0x0F, 0xBF }, RAX, .{ .m = gr(0, 2) });
            } else a.op(2, &.{ 0x0F, 0xBE }, RAX, .{ .m = gr(0, 1) });
            a.movMemReg(sz, gr(0, sz), RAX);
            return true;
        },
        .cdq => {
            a.movRegMem(sz, RAX, gr(0, sz));
            if (sz == 2) a.b(0x66);
            a.b(0x99);
            a.movMemReg(sz, gr(regs_mod.EDX, sz), RDX);
            return true;
        },
        .xchg => {
            if (x.dst == .mem) {
                e.ea(x, true);
                e.rd(sz, false);
                a.movRR(4, R8, RAX);
                a.movRegMem(sz, RCX, gr(x.sreg, sz));
                e.wr(sz);
                a.movMemReg(sz, gr(x.sreg, sz), R8);
                return true;
            }
            a.movRegMem(sz, RAX, gr(x.dreg, sz));
            a.movRegMem(sz, RCX, gr(x.sreg, sz));
            a.movMemReg(sz, gr(x.dreg, sz), RCX);
            a.movMemReg(sz, gr(x.sreg, sz), RAX);
            return true;
        },
        .bswap => {
            a.movRegMem(4, RAX, gr(x.dreg, 4));
            a.bytes(&.{ 0x0F, 0xC8 });
            a.movMemReg(4, gr(x.dreg, 4), RAX);
            return true;
        },
        .movsreg => {
            a.op(4, &.{ 0x0F, 0xB7 }, RAX, .{ .m = cpuMem(O_SEGS + 2 * @as(usize, x.sreg)) });
            if (x.dst == .mem) {
                a.movRR(4, R8, RAX);
                e.ea(x, true);
                a.movRR(4, RCX, R8);
                e.wr(2);
            } else a.movMemReg(sz, gr(x.dreg, sz), RAX);
            return true;
        },
        .setcc => {
            if (x.dst == .mem) e.ea(x, true);
            const hc = e.ccMem(@intCast(x.sub));
            a.op(1, &.{ 0x0F, 0x90 | @as(u8, hc) }, 0, .{ .r = RCX });
            if (x.dst == .mem) e.wr(1) else a.movMemReg(1, gr(x.dreg, 1), RCX);
            return true;
        },
        .flagop => {
            switch (x.sub) {
                0 => a.aluImm(4, 4, .{ .m = FLAGS }, ~CF),
                1 => a.aluImm(4, 1, .{ .m = FLAGS }, CF),
                2 => a.aluImm(4, 6, .{ .m = FLAGS }, CF),
                3 => a.aluImm(4, 4, .{ .m = FLAGS }, ~DF),
                else => a.aluImm(4, 1, .{ .m = FLAGS }, DF),
            }
            return true;
        },
        .nop => return true,
        .push => {
            if (!e.flat(regs_mod.SS)) return false;
            switch (x.src) {
                .reg => a.movRegMem(sz, RCX, gr(x.sreg, sz)),
                .imm => a.movImm32(RCX, x.imm),
                .mem => {
                    e.ea(x, true);
                    e.rd(sz, false);
                    a.movRR(4, RCX, RAX);
                },
                else => return false,
            }
            e.push(sz);
            return true;
        },
        .pop => {
            if (!e.flat(regs_mod.SS)) return false;
            e.pop(sz, 0);
            a.movMemReg(sz, gr(x.dreg, sz), RAX);
            return true;
        },
        .leave => {
            if (!e.flat(regs_mod.SS)) return false;
            e.popAddr(regs_mod.EBP);
            e.rd(sz, false);
            a.aluImm(4, 0, .{ .r = RBP }, sz);
            e.setSp();
            a.movMemReg(sz, gr(regs_mod.EBP, sz), RAX);
            return true;
        },
        .x87 => {
            if (e.mode & jit.M_FPU == 0) return false;
            if (x.mem) e.ea(x, true) else a.movImm32(R12, 0);
            a.movRR(4, RSI, R12);
            a.movImm64(RDX, @as(u64, x.op & 0xFF) | (@as(u64, x.modrm) << 8) | (@as(u64, @intFromBool(x.o32)) << 16) | (@as(u64, e.adj) << 24));
            a.movImm64(RCX, @as(u64, e.eip) | (@as(u64, e.next) << 32));
            callHelper(a, H_X87);
            a.bytes(&.{ 0x48, 0x85, 0xC0 });
            a.jccTo(CC_NZ, off_exit);
            return true;
        },
        else => return false,
    }
}

/// The interpreter for this instruction (a helper call).
fn helperIns(e: *E) void {
    const a = &e.a;
    a.movImm64(RSI, @as(u64, e.eip) | (@as(u64, e.next) << 32));
    a.movImm32(RDX, e.adj);
    callHelper(a, H_STEP);
    a.bytes(&.{ 0x48, 0x85, 0xC0 }); // test rax, rax
    a.jccTo(CC_NZ, off_exit);
}

/// Materializes the pending flags if any of them are live.
fn matPend(e: *E, live: u32) void {
    if (e.pend) |f| if (f.tm & live != 0) e.mat(f, null);
}

/// The block's last instruction when it is a branch with a template.
fn branch(e: *E, x: *const dec.Ins, live_out: u32) bool {
    const a = &e.a;
    switch (x.kind) {
        .jcc => {
            const cc: u4 = @intCast(x.sub);
            const reads: u32 = dec.ccReads(cc);
            if (e.pend) |f| {
                if (f.hm & reads == reads) {
                    const to_taken = a.jccFwd(cc);
                    matPend(e, live_out);
                    e.exitTo(0, e.next);
                    a.here(to_taken);
                    matPend(e, live_out);
                    e.exitTo(1, x.target);
                    return true;
                }
                e.mat(f, null);
                e.pend = null;
            }
            const hc = e.ccMem(cc);
            const to_taken = a.jccFwd(hc);
            e.exitTo(0, e.next);
            a.here(to_taken);
            e.exitTo(1, x.target);
            return true;
        },
        .jmp => {
            e.exitTo(0, x.target);
            return true;
        },
        .call => {
            if (!e.flat(regs_mod.SS)) return false;
            const n: u8 = if (x.o32) 4 else 2;
            a.movImm32(RCX, e.next);
            e.push(n);
            e.exitTo(0, x.target);
            return true;
        },
        .ret => {
            if (!e.flat(regs_mod.SS)) return false;
            const n: u8 = if (x.o32) 4 else 2;
            e.pop(n, x.imm);
            e.exitInd(x.o32);
            return true;
        },
        .jmp_ind, .call_ind => {
            const n: u8 = if (x.o32) 4 else 2;
            if (x.kind == .call_ind and !e.flat(regs_mod.SS)) return false;
            if (x.src == .mem) {
                if (!e.flat(x.ea.seg)) return false;
                e.ea(x, true);
                e.rd(n, false);
            } else a.movRegMem(n, RAX, gr(x.sreg, n));
            if (x.kind == .call_ind) {
                a.movRR(4, R8, RAX);
                a.movImm32(RCX, e.next);
                e.push(n);
                a.movRR(4, RAX, R8);
            }
            e.exitInd(x.o32);
            return true;
        },
        else => return false,
    }
}

/// Block b's code: `ins` its instructions (already decoded), `mode` the
/// mode it is made for. False if the code memory had no room.
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
    const wrap: u32 = if (P and mode32(k.mode)) 0xFFFF_FFFF else 0xFFFF;
    var after: [jit.MAX_INS]u32 = undefined;
    const live_out = jit.liveness(ins, &after, e.check);
    // Entry: the budget (all of the block, or the dispatcher steps).
    a.bytes(&.{ 0x49, 0x81, 0xFE }); // cmp r14, imm32
    a.d(n);
    const to_budget = a.jccFwd(CC_L);
    a.bytes(&.{ 0x49, 0x81, 0xEE }); // sub r14, imm32
    a.d(n);
    var eip = k.eip;
    var ended = false;
    for (ins, 0..) |*x, i| {
        e.eip = eip;
        e.next = (eip +% x.len) & wrap;
        e.adj = n - @as(u32, @intCast(i)) - 1;
        e.stub0 = e.ns;
        const last = i + 1 == ins.len;
        // (a producer right before the block's Jcc leaves its flags in the
        // host's for it, if the Jcc reads only what the host has exact)
        e.deferring = false;
        if (!last and ins[i + 1].kind == .jcc) e.deferring = true;
        if (last and x.term) {
            const save = a.at;
            const save_ns = e.ns;
            if (branch(&e, x, live_out)) {
                ended = true;
            } else {
                a.at = save;
                e.ns = save_ns;
                if (e.pend) |f| e.mat(f, null);
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
            } else if (e.pend) |f| {
                // (a deferred producer whose Jcc cannot read the host's:
                // the flags go to memory now)
                const reads = dec.ccReads(@intCast(ins[i + 1].sub));
                if (f.hm & reads != reads) {
                    e.mat(f, null);
                    e.pend = null;
                    var q = e.stub0;
                    while (q < e.ns) : (q += 1) e.stubs[q].popf = false;
                }
            }
        }
        var q = e.stub0;
        while (q < e.ns) : (q += 1) e.stubs[q].cont = a.at;
        eip = e.next;
    }
    if (!ended) e.exitTo(0, eip);
    // The slow stubs: the interpreter runs the whole instruction.
    for (e.stubs[0..e.ns]) |st| {
        a.here(st.at);
        a.movImm64(RSI, @as(u64, st.eip) | (@as(u64, st.next) << 32));
        a.movImm32(RDX, st.adj);
        callHelper(a, H_STEP);
        a.bytes(&.{ 0x48, 0x85, 0xC0 });
        a.jccTo(CC_NZ, off_exit);
        if (st.popf) {
            // (the flags the Jcc after it reads from the host's)
            a.movRegMem(4, RAX, FLAGS);
            a.aluImm(4, 4, .{ .r = RAX }, ARITH);
            a.b(0x50); // push rax
            a.b(0x9D); // popfq
        }
        a.jmpTo(st.cont);
    }
    // The budget's exit: nothing run.
    a.here(to_budget);
    a.movMemImm(4, cpuMem(O_EIP), k.eip);
    a.movImm32(RAX, @intCast(jit.X_BUDGET));
    a.jmpTo(off_exit);
    if (!a.ok) return false;
    j.dirty(start, a.at - start);
    j.used = (a.at + 15) & ~@as(usize, 15);
    return true;
}

fn mode32(mode: u32) bool {
    return mode & jit.M_CODE32 != 0;
}
