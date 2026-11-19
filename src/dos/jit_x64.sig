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

/// Block b's code: `ins` its instructions (already decoded), `mode` the
/// mode it is made for. False if the code memory had no room.
pub fn emitBlock(j: *Jit, b: u32, ins: []const dec.Ins, mode: u32, comptime B: type, comptime P: bool) bool {
    _ = mode;
    _ = B;
    const k = &jit.blocks[b];
    const start = j.used;
    var a = A{ .j = j, .at = start, .lim = @min(j.cm.len, start + jit.MAX_CODE) };
    k.code = @intCast(start);
    const n: u32 = @intCast(ins.len);
    const wrap: u32 = if (P and mode32(k.mode)) 0xFFFF_FFFF else 0xFFFF;
    // Entry: the budget (all of the block, or the dispatcher steps).
    a.bytes(&.{ 0x49, 0x81, 0xFE }); // cmp r14, imm32
    a.d(n);
    const to_budget = a.jccFwd(CC_L);
    a.bytes(&.{ 0x49, 0x81, 0xEE }); // sub r14, imm32
    a.d(n);
    var eip = k.eip;
    for (ins, 0..) |x, i| {
        const next = (eip +% x.len) & wrap;
        const adj: u32 = n - @as(u32, @intCast(i)) - 1;
        // (everything through the interpreter, for now)
        a.movImm64(RSI, @as(u64, eip) | (@as(u64, next) << 32));
        a.movImm32(RDX, adj);
        callHelper(&a, H_STEP);
        a.bytes(&.{ 0x48, 0x85, 0xC0 }); // test rax, rax
        a.jccTo(CC_NZ, off_exit);
        eip = next;
    }
    // (the last instruction fell through)
    chainSlot(&a, b, 0, eip);
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
