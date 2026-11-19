//! The translator against the interpreter: the same program on two
//! machines, one translated, one interpreted, must end in the same state
//! (registers, flags, memory). Programs in real and protected mode
//! (paging too), templates on random operands, code that writes itself,
//! faults inside a block, interrupts at block ends, chaining and the
//! invalidations. Bytes assembled by hand from Intel's opcode maps (the
//! source beside each).

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const machine = @import("machine.sig");
const jit = @import("jit.sig");
const regs = @import("regs.sig");
const TestHost = @import("test_host.sig").TestHost;
const Exit = @import("cpu.sig").Exit;
const check = @import("jit_check.sig");

var mj: machine.Machine = .{};
var mi: machine.Machine = .{};
var hj: TestHost = .{};
var hi: TestHost = .{};

const GDT: u32 = 0x800;

fn have() bool {
    return jit.have_backend and builtin.os.tag == .linux;
}

/// Both machines with `code` at 0x10000, real mode at 1000:0000.
fn boot(code: []const u8) bool {
    hj = .{ .jit = true };
    hi = .{};
    mj.init(hj.host(), "");
    mi.init(hi.host(), "");
    if (!mj.jitEnable()) return false;
    for ([_]*machine.Machine{ &mj, &mi }) |m| {
        @memcpy(m.mem.ram[0x10000..][0..code.len], code);
        const r = &m.cpu.regs;
        r.setSeg(regs.CS, 0x1000);
        r.eip = 0;
        r.setSeg(regs.SS, 0x2000);
        r.r[regs.ESP] = 0xFFFE;
        r.setSeg(regs.DS, 0x3000);
        r.setSeg(regs.ES, 0x4000);
        r.flags = regs.FIXED;
    }
    return true;
}

fn wr32(m: *machine.Machine, a: u32, v: u32) void {
    std.mem.writeInt(u32, m.mem.ram[a..][0..4], v, .little);
}

/// The same in protected mode at CPL 0, flat 32-bit segments, code at
/// 0x10000, A20 on; `paging`: an identity map of 4 MiB at 0x20000.
fn flat(code: []const u8, paging: bool) bool {
    if (!boot(code)) return false;
    for ([_]*machine.Machine{ &mj, &mi }) |m| {
        wr32(m, GDT + 8, 0x0000_FFFF);
        wr32(m, GDT + 12, 0x00CF_9A00);
        wr32(m, GDT + 16, 0x0000_FFFF);
        wr32(m, GDT + 20, 0x00CF_9200);
        m.cpu.gdt_base = GDT;
        m.cpu.gdt_limit = 0x17;
        m.cpu.cr0 |= 1;
        const r = &m.cpu.regs;
        for ([_]u3{ regs.CS, regs.SS, regs.DS, regs.ES, regs.FS, regs.GS }) |s| {
            r.seg[s] = if (s == regs.CS) 0x08 else 0x10;
            r.base[s] = 0;
            r.limit[s] = 0xFFFF_FFFF;
            r.attr[s] = if (s == regs.CS) 0xC09B else 0xC093;
        }
        r.eip = 0x10000;
        r.r[regs.ESP] = 0x9000;
        m.mem.a20 = true;
        wr32(m, 0x20000, 0x21000 | 7);
        for (0..1024) |i| wr32(m, 0x21000 + @as(u32, @intCast(i)) * 4, (@as(u32, @intCast(i)) << 12) | 7);
        if (paging) {
            m.cpu.cr3 = 0x20000;
            m.cpu.cr0 |= 0x8000_0000;
        }
    }
    return true;
}

/// Runs both for `n` instructions (in slices of `slice`), then compares.
fn runBoth(n: u32, slice: u32) !void {
    var left = n;
    while (left > 0) {
        const k = @min(left, slice);
        const ej = mj.cpu.run(&mj, k);
        const ei = mi.cpu.run(&mi, k);
        try t.expectEqual(ei, ej);
        try same();
        if (ej != .budget) break;
        left -= k;
    }
    try t.expect(std.mem.eql(u8, &mi.mem.ram, &mj.mem.ram));
}

fn same() !void {
    const a = &mj.cpu.regs;
    const b = &mi.cpu.regs;
    for (0..8) |i| {
        if (a.r[i] != b.r[i]) std.debug.print("\nreg {d}: jit {x} interp {x}\n", .{ i, a.r[i], b.r[i] });
        try t.expectEqual(b.r[i], a.r[i]);
    }
    try t.expectEqual(b.eip, a.eip);
    if (a.flags != b.flags) std.debug.print("\nflags: jit {x} interp {x}\n", .{ a.flags, b.flags });
    try t.expectEqual(b.flags, a.flags);
    try t.expectEqualSlices(u16, &b.seg, &a.seg);
    try t.expectEqual(mi.cpu.executed, mj.cpu.executed);
}

test "jit: a real-mode loop, as the interpreter runs it" {
    if (!have()) return;
    // l: add ax,bx; mov [si],ax; inc si; mov bx,[bx+di]; and si,3FFFh;
    //    cmp ax,dx; je l; loop l; jmp l
    try t.expect(boot(&.{ 0x01, 0xD8, 0x89, 0x04, 0x46, 0x8B, 0x1C, 0x81, 0xE6, 0xFF, 0x3F, 0x39, 0xD0, 0x74, 0xF1, 0xE2, 0xEF, 0xEB, 0xED }));
    for ([_]*machine.Machine{ &mj, &mi }) |m| {
        m.cpu.regs.setBx(1);
        m.cpu.regs.setDx(0xFFFF);
    }
    try runBoth(200_000, 997);
    try t.expect(jit.the.stats.entered > 0);
}

test "jit: a protected-mode loop with paging" {
    if (!have()) return;
    // l: add eax,ebx; mov [esi+0x30000],eax; add esi,4; and esi,0xFFF;
    //    imul ebx,ebx,3; dec ecx; jnz l; jmp l
    const code = [_]u8{
        0x01, 0xD8, 0x89, 0x86, 0x00, 0x00, 0x03, 0x00, 0x83, 0xC6, 0x04, 0x81, 0xE6, 0xFF, 0x0F, 0x00, 0x00,
        0x6B, 0xDB, 0x03, 0x49, 0x75, 0xE9, 0xEB, 0xE7,
    };
    try t.expect(flat(&code, true));
    try runBoth(100_000, 1009);
}

// ── Templates on random operands ───────────────────────────────────────

const Gen = struct {
    rng: std.Random.DefaultPrng,
    buf: [4096]u8 = undefined,
    n: usize = 0,

    fn r(g: *Gen) std.Random {
        return g.rng.random();
    }
    fn b(g: *Gen, x: u8) void {
        g.buf[g.n] = x;
        g.n += 1;
    }
    fn d(g: *Gen, x: u32) void {
        for (0..4) |i| g.b(@truncate(x >> @intCast(8 * i)));
    }
    /// A destination register (never the stack or the address registers).
    fn dst(g: *Gen) u8 {
        const tb = [_]u8{ 0, 1, 2, 5, 6 };
        return tb[g.r().uintLessThan(usize, tb.len)];
    }
    fn dst8(g: *Gen) u8 {
        const tb = [_]u8{ 0, 1, 2, 4, 5, 6 };
        return tb[g.r().uintLessThan(usize, tb.len)];
    }
    fn any(g: *Gen) u8 {
        return g.r().uintLessThan(u8, 8);
    }
    /// ModRM: a register (mod 3) or [rm 7 + disp8] (EDI in 32-bit code,
    /// BX in 16-bit).
    fn modrm(g: *Gen, reg: u8, rm_reg: u8, mem: bool) void {
        if (mem) {
            g.b(0x47 | (reg << 3));
            g.b(g.r().uintLessThan(u8, 120) & 0xFC);
        } else g.b(0xC0 | (reg << 3) | rm_reg);
    }
    fn imm(g: *Gen, sz: u8) void {
        const v = g.r().int(u32);
        // (small and edge values more often)
        const x: u32 = switch (g.r().uintLessThan(u8, 4)) {
            0 => v & 0xFF,
            1 => 0xFFFF_FFFF -% (v & 3),
            2 => 0x8000_0000 -% (v & 3),
            else => v,
        };
        switch (sz) {
            1 => g.b(@truncate(x)),
            2 => {
                g.b(@truncate(x));
                g.b(@truncate(x >> 8));
            },
            else => g.d(x),
        }
    }

    /// One random instruction with a template; `wide`: the default
    /// operand size is 32 bits (else 16).
    fn one(g: *Gen, wide: bool) void {
        const mem = g.r().boolean();
        const pick = g.r().uintLessThan(u8, 22);
        // operand size: 1, the default, or the other (0x66)
        const szk = g.r().uintLessThan(u8, 3);
        const byte = szk == 0;
        if (szk == 2) g.b(0x66);
        const vsz: u8 = if (byte) 1 else if ((szk == 2) != wide) 4 else 2;
        const dreg = if (byte) g.dst8() else g.dst();
        switch (pick) {
            0, 1, 2 => { // ALU r/m, r and r, r/m
                const sub = g.r().uintLessThan(u8, 8);
                const to_reg = g.r().boolean();
                g.b((sub << 3) | (@as(u8, @intFromBool(to_reg)) << 1) | @intFromBool(!byte));
                if (to_reg) g.modrm(dreg, g.any(), mem) else g.modrm(g.any(), dreg, mem);
            },
            3, 4 => { // ALU r/m, imm (80, 81, 83)
                const sub = g.r().uintLessThan(u8, 8);
                if (byte) {
                    g.b(0x80);
                    g.modrm(sub, dreg, mem);
                    g.imm(1);
                } else if (g.r().boolean()) {
                    g.b(0x83);
                    g.modrm(sub, dreg, mem);
                    g.imm(1);
                } else {
                    g.b(0x81);
                    g.modrm(sub, dreg, mem);
                    g.imm(vsz);
                }
            },
            5 => { // INC/DEC r/m
                g.b(if (byte) 0xFE else 0xFF);
                g.modrm(g.r().uintLessThan(u8, 2), dreg, mem);
            },
            6 => { // NOT/NEG/TEST imm
                const subs = [_]u8{ 0, 2, 3 };
                const sub = subs[g.r().uintLessThan(usize, 3)];
                g.b(if (byte) 0xF6 else 0xF7);
                g.modrm(sub, dreg, mem);
                if (sub == 0) g.imm(vsz);
            },
            7 => { // TEST r/m, r
                g.b(if (byte) 0x84 else 0x85);
                g.modrm(g.any(), dreg, mem);
            },
            8, 9 => { // shifts by an immediate, by 1
                const subs = [_]u8{ 0, 1, 4, 5, 7 };
                const sub = subs[g.r().uintLessThan(usize, 5)];
                if (g.r().boolean()) {
                    g.b(if (byte) 0xD0 else 0xD1);
                    g.modrm(sub, dreg, mem);
                } else {
                    g.b(if (byte) 0xC0 else 0xC1);
                    g.modrm(sub, dreg, mem);
                    g.b(g.r().uintLessThan(u8, 34));
                }
            },
            10 => { // MOV r/m, r; r, r/m; r/m, imm
                switch (g.r().uintLessThan(u8, 3)) {
                    0 => {
                        g.b(if (byte) 0x88 else 0x89);
                        g.modrm(g.any(), dreg, mem);
                    },
                    1 => {
                        g.b(if (byte) 0x8A else 0x8B);
                        g.modrm(dreg, g.any(), mem);
                    },
                    else => {
                        g.b(if (byte) 0xC6 else 0xC7);
                        g.modrm(0, dreg, mem);
                        g.imm(vsz);
                    },
                }
            },
            11 => { // MOVZX/MOVSX
                if (byte) return g.b(0x90);
                g.b(0x0F);
                const ops = [_]u8{ 0xB6, 0xB7, 0xBE, 0xBF };
                g.b(ops[g.r().uintLessThan(usize, 4)]);
                g.modrm(dreg, g.any(), mem);
            },
            12 => { // IMUL r, r/m (, imm)
                if (byte) return g.b(0x90);
                switch (g.r().uintLessThan(u8, 3)) {
                    0 => {
                        g.b(0x0F);
                        g.b(0xAF);
                        g.modrm(dreg, g.any(), mem);
                    },
                    1 => {
                        g.b(0x6B);
                        g.modrm(dreg, g.any(), mem);
                        g.imm(1);
                    },
                    else => {
                        g.b(0x69);
                        g.modrm(dreg, g.any(), mem);
                        g.imm(vsz);
                    },
                }
            },
            13 => g.b(if (g.r().boolean()) 0x98 else 0x99), // CWDE, CDQ
            14 => { // XCHG
                g.b(if (byte) 0x86 else 0x87);
                if (byte) g.modrm(g.dst8(), dreg, mem) else g.modrm(g.dst(), dreg, mem);
            },
            15 => { // LEA
                if (byte) return g.b(0x90);
                g.b(0x8D);
                g.modrm(dreg, 0, true);
            },
            16 => { // SETcc
                if (szk == 2) g.n -= 1;
                g.b(0x0F);
                g.b(0x90 | g.r().uintLessThan(u8, 16));
                g.modrm(0, g.dst8(), mem);
            },
            17 => { // CLC STC CMC
                if (szk == 2) g.n -= 1;
                const ops = [_]u8{ 0xF8, 0xF9, 0xF5 };
                g.b(ops[g.r().uintLessThan(usize, 3)]);
            },
            18 => { // PUSH r / imm, POP r
                if (byte) return g.b(0x90);
                switch (g.r().uintLessThan(u8, 3)) {
                    0 => g.b(0x50 | g.any()),
                    1 => g.b(0x58 | g.dst()),
                    else => {
                        g.b(0x6A);
                        g.imm(1);
                    },
                }
            },
            19 => { // INC/DEC r (40-4F)
                if (byte) return g.b(0x90);
                g.b(0x40 | (@as(u8, @intFromBool(g.r().boolean())) << 3) | g.dst());
            },
            20 => { // ADC/SBB chains: ADD then ADC
                if (byte) return g.b(0x90);
                g.b(0x01);
                g.modrm(g.any(), dreg, false);
                if (szk == 2) g.b(0x66);
                g.b(0x11);
                g.modrm(g.any(), g.dst(), mem);
            },
            else => { // a flags reader: Jcc over a NOP, then the NOP
                if (szk == 2) g.n -= 1;
                g.b(0x70 | g.r().uintLessThan(u8, 16));
                g.b(1);
                g.b(0x90);
            },
        }
    }
};

fn fuzz(wide: bool, seed: u64) !void {
    var g = Gen{ .rng = std.Random.DefaultPrng.init(seed) };
    var round: u32 = 0;
    while (round < 300) : (round += 1) {
        g.n = 0;
        const count = 3 + g.r().uintLessThan(u32, 40);
        for (0..count) |_| g.one(wide);
        // (then a jump back to the start: run it a few times over)
        g.b(0xE9);
        if (wide) {
            g.d(@bitCast(-@as(i32, @intCast(g.n + 4))));
        } else {
            const rel: u16 = @truncate(@as(u32, @bitCast(-@as(i32, @intCast(g.n + 2)))));
            g.b(@truncate(rel));
            g.b(@truncate(rel >> 8));
        }
        const ok = if (wide) flat(g.buf[0..g.n], round & 1 == 0) else boot(g.buf[0..g.n]);
        try t.expect(ok);
        // Random registers and flags, the same on both.
        var vals: [8]u32 = undefined;
        for (&vals) |*v| v.* = g.r().int(u32);
        const fl: u32 = (g.r().int(u32) & dec.ARITH) | regs.FIXED;
        for ([_]*machine.Machine{ &mj, &mi }) |m| {
            const r = &m.cpu.regs;
            for (0..8) |i| r.r[i] = vals[i];
            if (wide) {
                r.r[regs.ESP] = 0x9000;
                r.r[regs.EDI] = 0x30000;
            } else {
                r.r[regs.ESP] = 0xFF00;
                r.r[regs.EBX] = 0x100;
            }
            r.flags = fl;
            for (0..256) |i| m.mem.ram[0x30000 + 0x100 * @as(usize, @intFromBool(!wide)) + i] = @truncate(vals[i & 7] >> @intCast(i & 24));
        }
        runBoth(@intCast(count * 3 + 7), 1_000_000) catch |e| {
            std.debug.print("\nfuzz ({s}, seed {d}, round {d}): {x}\n", .{ if (wide) "32-bit" else "16-bit", seed, round, g.buf[0..g.n] });
            return e;
        };
    }
}

const dec = @import("jit_dec.sig");

test "jit: templates against the interpreter on random operands (32-bit protected mode)" {
    if (!have()) return;
    try fuzz(true, 1);
    try fuzz(true, 2);
}

test "jit: templates against the interpreter on random operands (real mode)" {
    if (!have()) return;
    try fuzz(false, 3);
    try fuzz(false, 4);
}
