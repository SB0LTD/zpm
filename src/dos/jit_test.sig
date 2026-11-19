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
