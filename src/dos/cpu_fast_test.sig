//! The CPU's fast paths on the real machine (machine.sig's page() and
//! mapKey()): the TLB's host pointers and the fetch window must never
//! show stale bytes or stale mappings. Code that writes itself, in real
//! and protected mode; a code page remapped under INVLPG and CR3; writes
//! to the SVGA's frame buffer, direct and through a page table; the A20
//! gate moved in protected mode. The programs were assembled with GNU as
//! (AT&T syntax, the source above each) at 0x10000.

const std = @import("std");
const t = std.testing;
const machine = @import("machine.sig");
const vesa = @import("vesa.sig");
const pm = @import("cpu_pm.sig");
const TestHost = @import("test_host.sig").TestHost;
const regs = @import("regs.sig");
const Exit = @import("cpu.sig").Exit;

var m: machine.Machine = .{};
var th: TestHost = .{};

const GDT: u32 = 0x800;

fn wr32(a: u32, v: u32) void {
    std.mem.writeInt(u32, m.mem.ram[a..][0..4], v, .little);
}
fn rd32(a: u32) u32 {
    return std.mem.readInt(u32, m.mem.ram[a..][0..4], .little);
}

/// The machine with `code` at 0x10000, in real mode at 1000:0000.
fn boot(code: []const u8) *regs.Regs {
    th = .{};
    m.init(th.host(), "");
    @memcpy(m.mem.ram[0x10000..][0..code.len], code);
    const r = &m.cpu.regs;
    r.setSeg(regs.CS, 0x1000);
    r.eip = 0;
    r.setSeg(regs.SS, 0x2000);
    r.r[regs.ESP] = 0xFFFE;
    r.setSeg(regs.DS, 0x3000);
    r.flags = regs.FIXED;
    return r;
}

/// The same in protected mode at CPL 0 on flat 32-bit segments (08 code,
/// 10 data), code at 08:10000, A20 on; and an identity map of the first 4 MiB at
/// 0x20000 (PD) and 0x21000 (PT) for the programs that turn paging on.
fn flat(code: []const u8) *regs.Regs {
    const r = boot(code);
    wr32(GDT + 8, 0x0000_FFFF);
    wr32(GDT + 12, 0x00CF_9A00);
    wr32(GDT + 16, 0x0000_FFFF);
    wr32(GDT + 20, 0x00CF_9200);
    m.cpu.gdt_base = GDT;
    m.cpu.gdt_limit = 0x17;
    m.cpu.cr0 |= 1;
    for ([_]u3{ regs.CS, regs.SS, regs.DS, regs.ES, regs.FS, regs.GS }) |s| {
        const sel: u16 = if (s == regs.CS) 0x08 else 0x10;
        r.seg[s] = sel;
        r.base[s] = 0;
        r.limit[s] = 0xFFFF_FFFF;
        r.attr[s] = if (s == regs.CS) 0xC09B else 0xC093;
    }
    r.eip = 0x10000;
    r.r[regs.ESP] = 0x9000;
    // (the A20 gate on, as an extender sets it)
    m.mem.a20 = true;
    wr32(0x20000, 0x21000 | 7);
    for (0..1024) |i| wr32(0x21000 + @as(u32, @intCast(i)) * 4, (@as(u32, @intCast(i)) << 12) | 7);
    return r;
}

fn go() Exit {
    return m.cpu.run(&m, 1000);
}

// ── The programs ────────────────────────────────────────────────────────

// f1:
//   .code32
//   movb $0x40, patch+1
//  patch:
//   mov $0x00, %al
//   movl $0x77, p2+1
//  p2:
//   mov $1, %ebx
//   hlt
const f1 = [_]u8{
    0xc6, 0x05, 0x08, 0x00, 0x01, 0x00, 0x40, 0xb0, 0x00, 0xc7, 0x05, 0x14,
    0x00, 0x01, 0x00, 0x77, 0x00, 0x00, 0x00, 0xbb, 0x01, 0x00, 0x00, 0x00,
    0xf4,
};

// f2:
//   .code16
//  start:
//   movb $0x40, %cs:(patch - start + 1)
//  patch:
//   mov $0x00, %al
//   movw $0x77, %cs:(p2 - start + 1)
//  p2:
//   mov $1, %bx
//   hlt
const f2 = [_]u8{
    0x2e, 0xc6, 0x06, 0x07, 0x00, 0x40, 0xb0, 0x00, 0x2e, 0xc7, 0x06, 0x10,
    0x00, 0x77, 0x00, 0xbb, 0x01, 0x00, 0xf4,
};

// f3:
//   .code32
//   mov $0x20000, %eax
//   mov %eax, %cr3
//   mov %cr0, %eax
//   or $0x80000000, %eax
//   mov %eax, %cr0
//   call 0x300000
//   mov %eax, %ebx
//   movl $0x302007, 0x21C00
//   invlpg 0x300000
//   call 0x300000
//   mov %eax, %ecx
//   movl $0x303007, 0x21C00
//   call 0x300000
//   mov %eax, %edx
//   mov %cr3, %eax
//   mov %eax, %cr3
//   call 0x300000
//   mov %eax, %esi
//   hlt
const f3 = [_]u8{
    0xb8, 0x00, 0x00, 0x02, 0x00, 0x0f, 0x22, 0xd8, 0x0f, 0x20, 0xc0, 0x0d,
    0x00, 0x00, 0x00, 0x80, 0x0f, 0x22, 0xc0, 0xe8, 0xe8, 0xff, 0x2e, 0x00,
    0x89, 0xc3, 0xc7, 0x05, 0x00, 0x1c, 0x02, 0x00, 0x07, 0x20, 0x30, 0x00,
    0x0f, 0x01, 0x3d, 0x00, 0x00, 0x30, 0x00, 0xe8, 0xd0, 0xff, 0x2e, 0x00,
    0x89, 0xc1, 0xc7, 0x05, 0x00, 0x1c, 0x02, 0x00, 0x07, 0x30, 0x30, 0x00,
    0xe8, 0xbf, 0xff, 0x2e, 0x00, 0x89, 0xc2, 0x0f, 0x20, 0xd8, 0x0f, 0x22,
    0xd8, 0xe8, 0xb2, 0xff, 0x2e, 0x00, 0x89, 0xc6, 0xf4,
};

// f4:
//   .code32
//   movl $0x11223344, 0xE0000000
//   mov $0xE0000100, %edi
//   mov $0xAABBCCDD, %eax
//   mov $4, %ecx
//   rep stosl
//   mov 0xE0000000, %ebx
//   mov $0x20000, %eax
//   mov %eax, %cr3
//   mov %cr0, %eax
//   or $0x80000000, %eax
//   mov %eax, %cr0
//   movl $0x55667788, 0x800010
//   mov 0x800010, %ecx
//   hlt
const f4 = [_]u8{
    0xc7, 0x05, 0x00, 0x00, 0x00, 0xe0, 0x44, 0x33, 0x22, 0x11, 0xbf, 0x00,
    0x01, 0x00, 0xe0, 0xb8, 0xdd, 0xcc, 0xbb, 0xaa, 0xb9, 0x04, 0x00, 0x00,
    0x00, 0xf3, 0xab, 0x8b, 0x1d, 0x00, 0x00, 0x00, 0xe0, 0xb8, 0x00, 0x00,
    0x02, 0x00, 0x0f, 0x22, 0xd8, 0x0f, 0x20, 0xc0, 0x0d, 0x00, 0x00, 0x00,
    0x80, 0x0f, 0x22, 0xc0, 0xc7, 0x05, 0x10, 0x00, 0x80, 0x00, 0x88, 0x77,
    0x66, 0x55, 0x8b, 0x0d, 0x10, 0x00, 0x80, 0x00, 0xf4,
};

// f5:
//   .code32
//   movl $0xA1, 0x100000
//   in $0x92, %al
//   or $2, %al
//   out %al, $0x92
//   movl $0xA2, 0x100004
//   mov 0x100000, %ebx
//   hlt
const f5 = [_]u8{
    0xc7, 0x05, 0x00, 0x00, 0x10, 0x00, 0xa1, 0x00, 0x00, 0x00, 0xe4, 0x92,
    0x0c, 0x02, 0xe6, 0x92, 0xc7, 0x05, 0x04, 0x00, 0x10, 0x00, 0xa2, 0x00,
    0x00, 0x00, 0x8b, 0x1d, 0x00, 0x00, 0x10, 0x00, 0xf4,
};

// ── The tests ───────────────────────────────────────────────────────────

test "fast paths: code that writes the instructions ahead of it, in protected and real mode" {
    // (the bytes are read where they are: the patched forms run)
    var r = flat(&f1);
    try t.expectEqual(Exit.halt, go());
    try t.expectEqual(@as(u32, 0x40), r.r[regs.EAX] & 0xFF);
    try t.expectEqual(@as(u32, 0x77), r.r[regs.EBX]);
    r = boot(&f2);
    try t.expectEqual(Exit.halt, go());
    try t.expectEqual(@as(u32, 0x40), r.r[regs.EAX] & 0xFF);
    try t.expectEqual(@as(u32, 0x77), r.r[regs.EBX] & 0xFFFF);
}

test "fast paths: a code page remapped runs its new code after INVLPG or a CR3 write, not before" {
    const r = flat(&f3);
    // (three frames for linear 0x300000: mov eax,1/2/3; ret)
    for ([_]u32{ 1, 2, 3 }, 0..) |v, k| {
        const at: u32 = 0x301000 + @as(u32, @intCast(k)) * 0x1000;
        m.mem.ram[at] = 0xB8;
        wr32(at + 1, v);
        m.mem.ram[at + 5] = 0xC3;
    }
    wr32(0x21000 + 0x300 * 4, 0x301007);
    try t.expectEqual(Exit.halt, go());
    try t.expectEqual(@as(u32, 1), r.r[regs.EBX]);
    try t.expectEqual(@as(u32, 2), r.r[regs.ECX]); // after INVLPG
    try t.expectEqual(@as(u32, 2), r.r[regs.EDX]); // remapped, no flush: the TLB's
    try t.expectEqual(@as(u32, 3), r.r[regs.ESI]); // after the CR3 write
}

test "fast paths: writes to the SVGA's frame buffer, direct and through a page table" {
    const r = flat(&f4);
    // linear 0x800000 (PD entry 2) -> a page table at 0x22000 -> the LFB
    wr32(0x20000 + 2 * 4, 0x22000 | 7);
    wr32(0x22000, vesa.LFB_BASE | 7);
    try t.expectEqual(Exit.halt, go());
    const fb = &m.vga.svga.mem;
    try t.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, fb[0..4], .little));
    for (0..4) |i| try t.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, fb[0x100 + i * 4 ..][0..4], .little));
    try t.expectEqual(@as(u32, 0x11223344), r.r[regs.EBX]);
    try t.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, fb[0x10..][0..4], .little));
    try t.expectEqual(@as(u32, 0x55667788), r.r[regs.ECX]);
    // the TLB keeps the frame buffer's bytes themselves
    const i = (0x800010 >> 12) & (pm.TLB_N - 1);
    try t.expect(m.cpu.tlb.perm[i] & pm.D_W != 0);
}

test "fast paths: the A20 gate moved by OUT 92h in protected mode remaps 1 MiB at once" {
    const r = flat(&f5);
    m.mem.a20 = false;
    try t.expectEqual(Exit.halt, go());
    // A20 off: 0x100000 was 0; on: it is 1 MiB, and the TLB knew at once.
    try t.expect(m.mem.a20);
    try t.expectEqual(@as(u32, 0xA1), rd32(0));
    try t.expectEqual(@as(u32, 0xA2), rd32(0x100004));
    try t.expectEqual(@as(u32, 0), r.r[regs.EBX]);
}
