//! Protected mode (cpu_pm.sig) on a bus of its own: 4 MiB of flat RAM.
//! The programs were assembled with GNU as (AT&T syntax; the source is
//! in the comment above each) at the address that comment gives.
//!
//! The tables every test starts from: the GDT at 0x800 (its GDTR image
//! at 0x700), an LDT at 0x900, the IDT at 0x1000, a 386 TSS at 0x1800
//! (SS0:ESP0 = 10:9000, an I/O bitmap allowing only port 40h); ring 0's
//! stack below 0x9000, ring 3's below 0xA000; code at 0x10000, handlers
//! from 0x11000, ring 3's code at 0x12000; results from 0x3000.
//!
//!   08 code, ring 0, flat 32-bit    10 data, ring 0, flat 32-bit
//!   1B code, ring 3, flat           23 data, ring 3, flat
//!   28 a 386 TSS                    30 16-bit code, ring 0, at 0x10000
//!   38 data, ring 0, 64 KiB         40 data, ring 0, at 0x50000, limit FFh
//!   4B call gate, DPL 3 -> 08:11200, 2 dwords
//!   50 data, not present
//!   5B 16-bit expand-down data, ring 3, at 0x60000, limit 7FFFh
//!   60 the LDT (selector 04 in it: data at 0x70000)
//!   70 past the GDT's limit

const std = @import("std");
const t = std.testing;
const cpu_mod = @import("cpu.sig");
const pm = @import("cpu_pm.sig");
const regs = @import("regs.sig");
const Cpu = cpu_mod.Cpu;
const Exit = cpu_mod.Exit;

const RAM: u32 = 0x40_0000;

const EAX = regs.EAX;
const ECX = regs.ECX;
const EDX = regs.EDX;
const EBX = regs.EBX;
const ESP = regs.ESP;
const EBP = regs.EBP;
const ESI = regs.ESI;
const EDI = regs.EDI;
const ES = regs.ES;
const CS = regs.CS;
const SS = regs.SS;
const DS = regs.DS;
const FS = regs.FS;
const GS = regs.GS;

const Bus = struct {
    ram: [RAM]u8 = undefined,
    pending: bool = false,
    ports: u32 = 0,

    pub fn rd8(b: *Bus, a: u32) u8 {
        return if (a < RAM) b.ram[a] else 0xFF;
    }
    pub fn wr8(b: *Bus, a: u32, v: u8) void {
        if (a < RAM) b.ram[a] = v;
    }
    pub fn rd16(b: *Bus, a: u32) u16 {
        return @as(u16, b.rd8(a)) | (@as(u16, b.rd8(a +% 1)) << 8);
    }
    pub fn wr16(b: *Bus, a: u32, v: u16) void {
        b.wr8(a, @truncate(v));
        b.wr8(a +% 1, @truncate(v >> 8));
    }
    pub fn rd32(b: *Bus, a: u32) u32 {
        return @as(u32, b.rd16(a)) | (@as(u32, b.rd16(a +% 2)) << 16);
    }
    pub fn wr32(b: *Bus, a: u32, v: u32) void {
        b.wr16(a, @truncate(v));
        b.wr16(a +% 2, @truncate(v >> 16));
    }
    /// (a port reads as its own number)
    pub fn in8(b: *Bus, port: u16) u8 {
        b.ports += 1;
        return @truncate(port);
    }
    pub fn in16(b: *Bus, port: u16) u16 {
        b.ports += 1;
        return port;
    }
    pub fn in32(b: *Bus, port: u16) u32 {
        b.ports += 1;
        return port;
    }
    pub fn out8(b: *Bus, port: u16, v: u8) void {
        _ = port;
        _ = v;
        b.ports += 1;
    }
    pub fn out16(b: *Bus, port: u16, v: u16) void {
        _ = port;
        _ = v;
        b.ports += 1;
    }
    pub fn out32(b: *Bus, port: u16, v: u32) void {
        _ = port;
        _ = v;
        b.ports += 1;
    }
    pub fn hle(b: *Bus, c: *Cpu, id: u16) bool {
        _ = b;
        _ = c;
        _ = id;
        return true;
    }
    pub fn irq(b: *Bus) bool {
        return b.pending;
    }
};

var bus: Bus = .{};
var cpu: Cpu = .{};

const GDT: u32 = 0x800;
const LDT: u32 = 0x900;
const IDT: u32 = 0x1000;
const TSS: u32 = 0x1800;
const OUT: u32 = 0x3000;

fn put(a: u32, bytes: []const u8) void {
    @memcpy(bus.ram[a..][0..bytes.len], bytes);
}
fn rd16(a: u32) u16 {
    return std.mem.readInt(u16, bus.ram[a..][0..2], .little);
}
fn rd32(a: u32) u32 {
    return std.mem.readInt(u32, bus.ram[a..][0..4], .little);
}
fn wr32(a: u32, v: u32) void {
    std.mem.writeInt(u32, bus.ram[a..][0..4], v, .little);
}

/// A code or data descriptor at `at` (flags: G 8, D/B 4).
fn desc(at: u32, base: u32, limit: u32, access: u8, flags: u4) void {
    wr32(at, (limit & 0xFFFF) | (base << 16));
    wr32(at + 4, ((base >> 16) & 0xFF) | (@as(u32, access) << 8) | (limit & 0xF_0000) | (@as(u32, flags) << 20) | (base & 0xFF00_0000));
}

fn seg(sel: u16, base: u32, limit: u32, access: u8, flags: u4) void {
    desc(GDT + (sel & 0xFFF8), base, limit, access, flags);
}

/// A gate at `at` (access 8E: a 386 interrupt gate, 8F a trap gate, EE
/// and EF the same at DPL 3, EC a 386 call gate at DPL 3).
fn gate(at: u32, sel: u16, off: u32, access: u8, params: u5) void {
    wr32(at, (off & 0xFFFF) | (@as(u32, sel) << 16));
    wr32(at + 4, (off & 0xFFFF_0000) | (@as(u32, access) << 8) | params);
}

fn vec(v: u8, off: u32, access: u8) void {
    gate(IDT + @as(u32, v) * 8, 0x08, off, access, 0);
}

fn tables() void {
    @memset(&bus.ram, 0);
    bus.pending = false;
    bus.ports = 0;
    cpu.reset();
    seg(0x08, 0, 0xFFFFF, 0x9A, 0xC);
    seg(0x10, 0, 0xFFFFF, 0x92, 0xC);
    seg(0x18, 0, 0xFFFFF, 0xFA, 0xC);
    seg(0x20, 0, 0xFFFFF, 0xF2, 0xC);
    seg(0x28, TSS, 0x78, 0x89, 0);
    seg(0x30, 0x10000, 0xFFFF, 0x9A, 0);
    seg(0x38, 0, 0xFFFF, 0x92, 0);
    seg(0x40, 0x50000, 0xFF, 0x92, 0x4);
    gate(GDT + 0x48, 0x08, 0x11200, 0xEC, 2);
    seg(0x50, 0, 0xFFFFF, 0x12, 0xC);
    seg(0x58, 0x60000, 0x7FFF, 0xF6, 0);
    seg(0x60, LDT, 7, 0x82, 0);
    desc(LDT, 0x70000, 0xFFF, 0x92, 0x4);
    put(0x700, &.{ 0x6F, 0x00, 0x00, 0x08, 0x00, 0x00 });
    cpu.gdt_base = GDT;
    cpu.gdt_limit = 0x6F;
    // (real mode's IDTR stays until a test goes protected)
    wr32(TSS + 4, 0x9000);
    wr32(TSS + 8, 0x10);
    bus.ram[TSS + 0x66] = 0x68;
    @memset(bus.ram[TSS + 0x68 ..][0..17], 0xFF);
    bus.ram[TSS + 0x68 + 8] = 0xFE; // port 40h
    wr32(0x3F00, regs.FIXED); // the EFLAGS ring 3 starts with
    bus.ram[0x11100] = 0xF4; // (a handler that halts)
}

/// Segment register s's cache from the GDT, as a far jump or MOV would
/// load it.
fn load(s: u3, sel: u16) void {
    const at = GDT + (sel & 0xFFF8);
    const d = pm.Desc{ .lo = rd32(at), .hi = rd32(at + 4), .at = at };
    const r = &cpu.regs;
    r.seg[s] = sel;
    r.base[s] = d.base();
    r.limit[s] = d.limit();
    r.attr[s] = d.attr() | 1;
}

/// Protected mode at CPL 0 on the flat segments with the TSS loaded,
/// code at 08:10000, ESP 9000h.
fn flat() *regs.Regs {
    tables();
    cpu.cr0 |= 1;
    cpu.idt_base = IDT;
    cpu.idt_limit = 0x7FF;
    cpu.tr = 0x28;
    cpu.tr_base = TSS;
    cpu.tr_limit = 0x78;
    cpu.tr_type = 11;
    load(CS, 0x08);
    for ([_]u3{ SS, DS, ES, FS, GS }) |s| load(s, 0x10);
    const r = &cpu.regs;
    r.eip = 0x10000;
    r.r[ESP] = 0x9000;
    r.flags = regs.FIXED;
    return r;
}

fn go(budget: u32) Exit {
    return cpu.run(&bus, budget);
}

// ── The programs ────────────────────────────────────────────────────────

// at 0x10000:
//   .code16
//  start:
//   xor %ax, %ax
//   mov %ax, %ds
//   lgdt 0x700
//   mov %cr0, %eax
//   or $1, %al
//   mov %eax, %cr0
//   ljmpl $0x08, $pm32
//   .code32
//  pm32:
//   mov $0x10, %ax
//   mov %ax, %ds
//   mov %ax, %es
//   mov %ax, %ss
//   mov $0x9000, %esp
//   movl $0x12345678, 0x200000
//   mov 0x200000, %edx
//   ljmp $0x30, $(pm16 - start)
//   .code16
//  pm16:
//   mov $0x38, %ax
//   mov %ax, %es
//   mov %cr0, %eax
//   and $0xFE, %al
//   mov %eax, %cr0
//   ljmp $0x1000, $(real - start)
//  real:
//   xor %ax, %ax
//   mov %ax, %ds
//   addr32 mov 0x200000, %ebx
//   hlt
const t1 = [_]u8{
    0x31, 0xc0, 0x8e, 0xd8, 0x0f, 0x01, 0x16, 0x00, 0x07, 0x0f, 0x20, 0xc0,
    0x0c, 0x01, 0x0f, 0x22, 0xc0, 0x66, 0xea, 0x19, 0x00, 0x01, 0x00, 0x08,
    0x00, 0x66, 0xb8, 0x10, 0x00, 0x8e, 0xd8, 0x8e, 0xc0, 0x8e, 0xd0, 0xbc,
    0x00, 0x90, 0x00, 0x00, 0xc7, 0x05, 0x00, 0x00, 0x20, 0x00, 0x78, 0x56,
    0x34, 0x12, 0x8b, 0x15, 0x00, 0x00, 0x20, 0x00, 0xea, 0x3f, 0x00, 0x00,
    0x00, 0x30, 0x00, 0xb8, 0x38, 0x00, 0x8e, 0xc0, 0x0f, 0x20, 0xc0, 0x24,
    0xfe, 0x0f, 0x22, 0xc0, 0xea, 0x51, 0x00, 0x00, 0x10, 0x31, 0xc0, 0x8e,
    0xd8, 0x67, 0x66, 0x8b, 0x1d, 0x00, 0x00, 0x20, 0x00, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x11223344, %eax
//   mov $0x20000, %ebx
//   mov %eax, (%ebx)
//   movw (%ebx), %cx
//   push %eax
//   lea 4(%ebx,%eax,2), %esi
//   jmp 0x30000
const t2 = [_]u8{
    0xb8, 0x44, 0x33, 0x22, 0x11, 0xbb, 0x00, 0x00, 0x02, 0x00, 0x89, 0x03,
    0x66, 0x8b, 0x0b, 0x50, 0x8d, 0x74, 0x43, 0x04, 0xe9, 0xe7, 0xff, 0x01,
    0x00,
};

// at 0x30000:
//   .code32
//   call sub
//   movl $0xFFFF0000, %edi
//   pushw $0x1234
//   hlt
//  sub:
//   mov %esp, %ebp
//   ret
const t2b = [_]u8{
    0xe8, 0x0a, 0x00, 0x00, 0x00, 0xbf, 0x00, 0x00, 0xff, 0xff, 0x66, 0x68,
    0x34, 0x12, 0xf4, 0x89, 0xe5, 0xc3,
};

// at 0x10000:
//   .code32
//  start:
//   lcall $0x30, $(sub16 - start)
//   mov %eax, %ebx
//   ljmp $0x08, $target
//  target:
//   pushl $0x08
//   pushl $after
//   lret
//  after:
//   hlt
//   .code16
//  sub16:
//   mov $0x5555, %ax
//   mov %cs, %dx
//   lretl
const t3 = [_]u8{
    0x9a, 0x19, 0x00, 0x00, 0x00, 0x30, 0x00, 0x89, 0xc3, 0xea, 0x10, 0x00,
    0x01, 0x00, 0x08, 0x00, 0x6a, 0x08, 0x68, 0x18, 0x00, 0x01, 0x00, 0xcb,
    0xf4, 0xb8, 0x55, 0x55, 0x8c, 0xca, 0x66, 0xcb,
};

// at 0x10000:
//   .code32
//   mov $0x23, %ax
//   mov %ax, %ds
//   pushl $0x23
//   pushl $0xA000
//   pushl 0x3F00
//   pushl $0x1B
//   pushl $0x12000
//   iret
const r3 = [_]u8{
    0x66, 0xb8, 0x23, 0x00, 0x8e, 0xd8, 0x6a, 0x23, 0x68, 0x00, 0xa0, 0x00,
    0x00, 0xff, 0x35, 0x00, 0x3f, 0x00, 0x00, 0x6a, 0x1b, 0x68, 0x00, 0x20,
    0x01, 0x00, 0xcf,
};

// at 0x12000:
//   .code32
//   mov $0x23, %ax
//   mov %ax, %ds
//   mov %esp, 0x3000
//   mov $7, %eax
//   int $0x30
//   mov %eax, 0x3004
//   mov %esp, 0x3008
//   mov %cs, 0x300C
//   int $0x31
const t4 = [_]u8{
    0x66, 0xb8, 0x23, 0x00, 0x8e, 0xd8, 0x89, 0x25, 0x00, 0x30, 0x00, 0x00,
    0xb8, 0x07, 0x00, 0x00, 0x00, 0xcd, 0x30, 0xa3, 0x04, 0x30, 0x00, 0x00,
    0x89, 0x25, 0x08, 0x30, 0x00, 0x00, 0x8c, 0x0d, 0x0c, 0x30, 0x00, 0x00,
    0xcd, 0x31,
};

// at 0x11000:
//   .code32
//   mov %esp, 0x3010
//   mov 16(%esp), %ecx
//   mov %ecx, 0x3014
//   mov 12(%esp), %ecx
//   mov %ecx, 0x3018
//   mov 4(%esp), %ecx
//   mov %ecx, 0x301C
//   mov %cs, %ecx
//   mov %ecx, 0x3020
//   pushf
//   pop %ecx
//   mov %ecx, 0x3024
//   add $1, %eax
//   iret
const t4h = [_]u8{
    0x89, 0x25, 0x10, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x10, 0x89, 0x0d,
    0x14, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x0c, 0x89, 0x0d, 0x18, 0x30,
    0x00, 0x00, 0x8b, 0x4c, 0x24, 0x04, 0x89, 0x0d, 0x1c, 0x30, 0x00, 0x00,
    0x8c, 0xc9, 0x89, 0x0d, 0x20, 0x30, 0x00, 0x00, 0x9c, 0x59, 0x89, 0x0d,
    0x24, 0x30, 0x00, 0x00, 0x83, 0xc0, 0x01, 0xcf,
};

// at 0x12000:
//   .code32
//   mov $0x23, %ax
//   mov %ax, %ds
//   pushl $0x1111
//   pushl $0x2222
//   lcall $0x4B, $0
//   mov %esp, 0x3000
//   mov %eax, 0x3004
//   int $0x31
const t5 = [_]u8{
    0x66, 0xb8, 0x23, 0x00, 0x8e, 0xd8, 0x68, 0x11, 0x11, 0x00, 0x00, 0x68,
    0x22, 0x22, 0x00, 0x00, 0x9a, 0x00, 0x00, 0x00, 0x00, 0x4b, 0x00, 0x89,
    0x25, 0x00, 0x30, 0x00, 0x00, 0xa3, 0x04, 0x30, 0x00, 0x00, 0xcd, 0x31,
};

// at 0x11200:
//   .code32
//   mov %esp, 0x3010
//   mov 8(%esp), %ecx
//   mov %ecx, 0x3014
//   mov 12(%esp), %ecx
//   mov %ecx, 0x3018
//   mov 16(%esp), %ecx
//   mov %ecx, 0x301C
//   mov 20(%esp), %ecx
//   mov %ecx, 0x3020
//   mov 4(%esp), %ecx
//   mov %ecx, 0x3024
//   mov $0x99, %eax
//   lret $8
const t5h = [_]u8{
    0x89, 0x25, 0x10, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x08, 0x89, 0x0d,
    0x14, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x0c, 0x89, 0x0d, 0x18, 0x30,
    0x00, 0x00, 0x8b, 0x4c, 0x24, 0x10, 0x89, 0x0d, 0x1c, 0x30, 0x00, 0x00,
    0x8b, 0x4c, 0x24, 0x14, 0x89, 0x0d, 0x20, 0x30, 0x00, 0x00, 0x8b, 0x4c,
    0x24, 0x04, 0x89, 0x0d, 0x24, 0x30, 0x00, 0x00, 0xb8, 0x99, 0x00, 0x00,
    0x00, 0xca, 0x08, 0x00,
};

// at 0x11300:
//   .code32
//   popl 0x3000
//   mov (%esp), %ecx
//   mov %ecx, 0x3004
//   mov %esp, 0x3008
//   mov 12(%esp), %ecx
//   mov %ecx, 0x300C
//   hlt
const rec = [_]u8{
    0x8f, 0x05, 0x00, 0x30, 0x00, 0x00, 0x8b, 0x0c, 0x24, 0x89, 0x0d, 0x04,
    0x30, 0x00, 0x00, 0x89, 0x25, 0x08, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24,
    0x0c, 0x89, 0x0d, 0x0c, 0x30, 0x00, 0x00, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x5555, %esi
//   mov $0x70, %ax
//   mov %ax, %ds
//   hlt
const t6a = [_]u8{
    0xbe, 0x55, 0x55, 0x00, 0x00, 0x66, 0xb8, 0x70, 0x00, 0x8e, 0xd8, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x40, %ax
//   mov %ax, %es
//   mov %es:0xFC, %eax
//   mov %es:0xFE, %eax
//   hlt
const t6b = [_]u8{
    0x66, 0xb8, 0x40, 0x00, 0x8e, 0xc0, 0x26, 0xa1, 0xfc, 0x00, 0x00, 0x00,
    0x26, 0xa1, 0xfe, 0x00, 0x00, 0x00, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x40, %ax
//   mov %ax, %ss
//   mov $0xF0, %esp
//   popa
//   hlt
const t6c = [_]u8{
    0x66, 0xb8, 0x40, 0x00, 0x8e, 0xd0, 0xbc, 0xf0, 0x00, 0x00, 0x00, 0x61,
    0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x50, %ax
//   mov %ax, %fs
//   hlt
const t6d = [_]u8{
    0x66, 0xb8, 0x50, 0x00, 0x8e, 0xe0, 0xf4,
};

// at 0x12000:
//   .code32
//   mov $0x5B, %ax
//   mov %ax, %ss
//   mov $0x8004, %esp
//   pushw %ax
//   pushw %ax
//   pushw %ax
//   hlt
const t6e = [_]u8{
    0x66, 0xb8, 0x5b, 0x00, 0x8e, 0xd0, 0xbc, 0x04, 0x80, 0x00, 0x00, 0x66,
    0x50, 0x66, 0x50, 0x66, 0x50, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x20000, %eax
//   mov %eax, %cr3
//   mov %cr0, %eax
//   or $0x80000000, %eax
//   mov %eax, %cr0
//   mov 0x300010, %ebx
//   movl $0x302007, 0x21C00
//   mov 0x300010, %ecx
//   mov %cr3, %eax
//   mov %eax, %cr3
//   mov 0x300010, %edx
//   movl $0x303007, 0x21C00
//   invlpg 0x300000
//   mov 0x300010, %esi
//   movl $1, 0x100000
//   hlt
const t7 = [_]u8{
    0xb8, 0x00, 0x00, 0x02, 0x00, 0x0f, 0x22, 0xd8, 0x0f, 0x20, 0xc0, 0x0d,
    0x00, 0x00, 0x00, 0x80, 0x0f, 0x22, 0xc0, 0x8b, 0x1d, 0x10, 0x00, 0x30,
    0x00, 0xc7, 0x05, 0x00, 0x1c, 0x02, 0x00, 0x07, 0x20, 0x30, 0x00, 0x8b,
    0x0d, 0x10, 0x00, 0x30, 0x00, 0x0f, 0x20, 0xd8, 0x0f, 0x22, 0xd8, 0x8b,
    0x15, 0x10, 0x00, 0x30, 0x00, 0xc7, 0x05, 0x00, 0x1c, 0x02, 0x00, 0x07,
    0x30, 0x30, 0x00, 0x0f, 0x01, 0x3d, 0x00, 0x00, 0x30, 0x00, 0x8b, 0x35,
    0x10, 0x00, 0x30, 0x00, 0xc7, 0x05, 0x00, 0x00, 0x10, 0x00, 0x01, 0x00,
    0x00, 0x00, 0xf4,
};

// at 0x11400:
//   .code32
//   popl 0x3000
//   push %eax
//   mov %cr2, %eax
//   mov %eax, 0x3004
//   pop %eax
//   movl $0x301007, 0x21C00
//   iret
const t7h = [_]u8{
    0x8f, 0x05, 0x00, 0x30, 0x00, 0x00, 0x50, 0x0f, 0x20, 0xd0, 0xa3, 0x04,
    0x30, 0x00, 0x00, 0x58, 0xc7, 0x05, 0x00, 0x1c, 0x02, 0x00, 0x07, 0x10,
    0x30, 0x00, 0xcf,
};

// at 0x12000:
//   .code32
//   movl $1, 0x200000
//   hlt
const t7b = [_]u8{
    0xc7, 0x05, 0x00, 0x00, 0x20, 0x00, 0x01, 0x00, 0x00, 0x00, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x08, %eax
//   lar %eax, %ebx
//   setz %cl
//   mov $0x40, %eax
//   lsl %eax, %edx
//   setz %ch
//   mov $0x08, %eax
//   verr %ax
//   setz 0x3000
//   verw %ax
//   setz 0x3001
//   mov $0x10, %eax
//   verw %ax
//   setz 0x3002
//   mov $0x70, %eax
//   lar %eax, %esi
//   setz 0x3003
//   mov $0x48, %eax
//   lar %eax, %edi
//   setz 0x3004
//   lsl %eax, %ebp
//   setz 0x3005
//   mov $0x08, %eax
//   lsl %eax, %eax
//   setz 0x3006
//   hlt
const t8 = [_]u8{
    0xb8, 0x08, 0x00, 0x00, 0x00, 0x0f, 0x02, 0xd8, 0x0f, 0x94, 0xc1, 0xb8,
    0x40, 0x00, 0x00, 0x00, 0x0f, 0x03, 0xd0, 0x0f, 0x94, 0xc5, 0xb8, 0x08,
    0x00, 0x00, 0x00, 0x0f, 0x00, 0xe0, 0x0f, 0x94, 0x05, 0x00, 0x30, 0x00,
    0x00, 0x0f, 0x00, 0xe8, 0x0f, 0x94, 0x05, 0x01, 0x30, 0x00, 0x00, 0xb8,
    0x10, 0x00, 0x00, 0x00, 0x0f, 0x00, 0xe8, 0x0f, 0x94, 0x05, 0x02, 0x30,
    0x00, 0x00, 0xb8, 0x70, 0x00, 0x00, 0x00, 0x0f, 0x02, 0xf0, 0x0f, 0x94,
    0x05, 0x03, 0x30, 0x00, 0x00, 0xb8, 0x48, 0x00, 0x00, 0x00, 0x0f, 0x02,
    0xf8, 0x0f, 0x94, 0x05, 0x04, 0x30, 0x00, 0x00, 0x0f, 0x03, 0xe8, 0x0f,
    0x94, 0x05, 0x05, 0x30, 0x00, 0x00, 0xb8, 0x08, 0x00, 0x00, 0x00, 0x0f,
    0x03, 0xc0, 0x0f, 0x94, 0x05, 0x06, 0x30, 0x00, 0x00, 0xf4,
};

// at 0x12000:
//   .code32
//   mov $0x23, %ax
//   mov %ax, %ds
//   in $0x40, %al
//   mov %al, 0x3040
//  spin:
//   jmp spin
const t9a = [_]u8{
    0x66, 0xb8, 0x23, 0x00, 0x8e, 0xd8, 0xe4, 0x40, 0xa2, 0x40, 0x30, 0x00,
    0x00, 0xeb, 0xfe,
};

// at 0x11500:
//   .code32
//   mov %esp, 0x3010
//   mov 16(%esp), %ecx
//   mov %ecx, 0x3014
//   mov 12(%esp), %ecx
//   mov %ecx, 0x3018
//   mov (%esp), %ecx
//   mov %ecx, 0x301C
//   pushf
//   pop %ecx
//   mov %ecx, 0x3024
//   hlt
const t9h = [_]u8{
    0x89, 0x25, 0x10, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x10, 0x89, 0x0d,
    0x14, 0x30, 0x00, 0x00, 0x8b, 0x4c, 0x24, 0x0c, 0x89, 0x0d, 0x18, 0x30,
    0x00, 0x00, 0x8b, 0x0c, 0x24, 0x89, 0x0d, 0x1c, 0x30, 0x00, 0x00, 0x9c,
    0x59, 0x89, 0x0d, 0x24, 0x30, 0x00, 0x00, 0xf4,
};

// at 0x12000:
//   .code32
//   int $0x20
const t9b = [_]u8{
    0xcd, 0x20,
};

// at 0x12000:
//   .code32
//   in $0x60, %al
const t9c = [_]u8{
    0xe4, 0x60,
};

// at 0x12000:
//   .code32
//   cli
const t9d = [_]u8{
    0xfa,
};

// at 0x10000:
//   .code32
//   mov $0x70, %ax
//   mov %ax, %ds
//   hlt
const t10 = [_]u8{
    0x66, 0xb8, 0x70, 0x00, 0x8e, 0xd8, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x28, %ax
//   ltr %ax
//   str %bx
//   mov $0x60, %ax
//   lldt %ax
//   sldt %dx
//   mov $0x04, %ax
//   mov %ax, %fs
//   mov %fs:0x10, %esi
//   hlt
const t11 = [_]u8{
    0x66, 0xb8, 0x28, 0x00, 0x0f, 0x00, 0xd8, 0x66, 0x0f, 0x00, 0xcb, 0x66,
    0xb8, 0x60, 0x00, 0x0f, 0x00, 0xd0, 0x66, 0x0f, 0x00, 0xc2, 0x66, 0xb8,
    0x04, 0x00, 0x8e, 0xe0, 0x64, 0x8b, 0x35, 0x10, 0x00, 0x00, 0x00, 0xf4,
};

// at 0x10000:
//   .code32
//   mov $0x23, %ax
//   mov %ax, %ds
//   pushl $0x23
//   pushl $0xA000
//   pushl 0x3F00
//   pushl $0x1B
//   pushl $0x4000
//   iret
const r3b = [_]u8{
    0x66, 0xb8, 0x23, 0x00, 0x8e, 0xd8, 0x6a, 0x23, 0x68, 0x00, 0xa0, 0x00,
    0x00, 0xff, 0x35, 0x00, 0x3f, 0x00, 0x00, 0x6a, 0x1b, 0x68, 0x00, 0x40,
    0x00, 0x00, 0xcf,
};

// at 0x4000:
//   .code32
//   mov $0x10, %ax
//   mov $0x23, %bx
//   arpl %bx, %ax
//   setz 0x3020
//   mov %ax, 0x3022
//   arpl %bx, %ax
//   setz 0x3024
//   mov %esp, 0x3000
//   int $0x32
//   mov %esp, 0x3004
//   mov %cs, 0x3008
//   int $0x31
const t12 = [_]u8{
    0x66, 0xb8, 0x10, 0x00, 0x66, 0xbb, 0x23, 0x00, 0x63, 0xd8, 0x0f, 0x94,
    0x05, 0x20, 0x30, 0x00, 0x00, 0x66, 0xa3, 0x22, 0x30, 0x00, 0x00, 0x63,
    0xd8, 0x0f, 0x94, 0x05, 0x24, 0x30, 0x00, 0x00, 0x89, 0x25, 0x00, 0x30,
    0x00, 0x00, 0xcd, 0x32, 0x89, 0x25, 0x04, 0x30, 0x00, 0x00, 0x8c, 0x0d,
    0x08, 0x30, 0x00, 0x00, 0xcd, 0x31,
};

// at 0x11600:
//   .code16
//   mov %esp, 0x3010
//   mov %sp, %bp
//   mov 8(%bp), %ax
//   mov %ax, 0x3014
//   mov 6(%bp), %ax
//   mov %ax, 0x3018
//   mov %cs, 0x301C
//   iret
const t12h = [_]u8{
    0x66, 0x89, 0x26, 0x10, 0x30, 0x89, 0xe5, 0x8b, 0x46, 0x08, 0xa3, 0x14,
    0x30, 0x8b, 0x46, 0x06, 0xa3, 0x18, 0x30, 0x8c, 0x0e, 0x1c, 0x30, 0xcf,
};

// ── The tests ───────────────────────────────────────────────────────────

test "pm: real mode to protected mode and back; unreal mode survives" {
    tables();
    put(0x10000, &t1);
    const r = &cpu.regs;
    r.setSeg(CS, 0x1000);
    r.eip = 0;
    r.setSeg(SS, 0x2000);
    r.r[ESP] = 0xFFFE;
    try t.expectEqual(Exit.halt, go(100));
    // (in protected mode: the write above 1 MiB through DS's 4 GiB)
    try t.expectEqual(@as(u32, 0x12345678), r.r[EDX]);
    try t.expectEqual(@as(u32, 0x0800), cpu.gdt_base);
    // Back in real mode: CS is a paragraph again...
    try t.expectEqual(@as(u32, 0), cpu.cr0 & 1);
    try t.expectEqual(@as(u16, 0x1000), r.seg[CS]);
    try t.expectEqual(@as(u32, t1.len), r.eip);
    // ...and DS, loaded with 0 there, keeps its 4 GiB limit: a 32-bit
    // offset reaches the same dword (ES was given 64 KiB before).
    try t.expectEqual(@as(u32, 0x12345678), r.r[EBX]);
    try t.expectEqual(@as(u32, 0), r.base[DS]);
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), r.limit[DS]);
    try t.expectEqual(@as(u32, 0xFFFF), r.limit[ES]);
    // Loading a descriptor set its accessed bit.
    try t.expectEqual(@as(u8, 0x93), bus.ram[GDT + 0x10 + 5]);
}

test "pm: a 32-bit code segment: default sizes, 0x66 for 16 bits, EIP past 64 KiB" {
    const r = flat();
    put(0x10000, &t2);
    put(0x30000, &t2b);
    try t.expectEqual(Exit.halt, go(100));
    try t.expect(cpu.code32 and cpu.stack32);
    try t.expectEqual(@as(u32, 0x11223344), rd32(0x20000));
    try t.expectEqual(@as(u32, 0x3344), r.r[ECX]);
    try t.expectEqual(@as(u32, 0x2246_668C), r.r[ESI]);
    // CALL pushed a 32-bit EIP; PUSHW took 2 bytes off ESP.
    try t.expectEqual(@as(u32, 0x8FF8), r.r[EBP]);
    // (its low half: PUSHW wrote over the high one after the RET)
    try t.expectEqual(@as(u16, 0x0005), rd16(0x8FF8));
    try t.expectEqual(@as(u32, 0x8FFA), r.r[ESP]);
    try t.expectEqual(@as(u16, 0x1234), rd16(0x8FFA));
    try t.expectEqual(@as(u32, 0x3000F), r.eip);
}

test "pm: far CALL into a 16-bit code segment, RETF, far JMP" {
    const r = flat();
    put(0x10000, &t3);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x5555), r.r[EBX] & 0xFFFF);
    try t.expectEqual(@as(u32, 0x30), r.r[EDX] & 0xFFFF);
    try t.expectEqual(@as(u16, 0x08), r.seg[CS]);
    try t.expect(cpu.code32);
    try t.expectEqual(@as(u32, 0x9000), r.r[ESP]);
    try t.expectEqual(@as(u32, 0x10019), r.eip);
}

test "pm: ring 3 calls ring 0 through an interrupt gate on the TSS's stack; IRET returns" {
    const r = flat();
    put(0x10000, &r3);
    put(0x12000, &t4);
    put(0x11000, &t4h);
    vec(0x30, 0x11000, 0xEE);
    vec(0x31, 0x11100, 0xEF);
    try t.expectEqual(Exit.halt, go(200));
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT));
    // The handler: on SS0:ESP0 with the old SS:ESP, CS:EIP and EFLAGS.
    try t.expectEqual(@as(u32, 0x9000 - 20), rd32(OUT + 0x10));
    try t.expectEqual(@as(u32, 0x23), rd32(OUT + 0x14));
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT + 0x18));
    try t.expectEqual(@as(u32, 0x1B), rd32(OUT + 0x1C));
    try t.expectEqual(@as(u32, 0x08), rd32(OUT + 0x20));
    try t.expectEqual(@as(u32, 0), rd32(OUT + 0x24) & regs.IF);
    // Back at ring 3 after IRET: its EAX, its stack, its CS.
    try t.expectEqual(@as(u32, 8), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT + 8));
    try t.expectEqual(@as(u16, 0x1B), rd16(OUT + 0x0C));
    // ES held ring 0's data when IRET went to ring 3: null since.
    try t.expectEqual(@as(u16, 0), r.seg[ES]);
    try t.expectEqual(@as(u16, 0), r.attr[ES]);
    // int 31h: ring 0 again, halted in its handler.
    try t.expectEqual(@as(u2, 0), cpu.cpl);
    try t.expectEqual(@as(u16, 0x10), r.seg[SS]);
    try t.expectEqual(@as(u32, 0x11101), r.eip);
}

test "pm: a call gate from ring 3 to ring 0 copies its parameters; RETF 8 returns" {
    _ = flat();
    put(0x10000, &r3);
    put(0x12000, &t5);
    put(0x11200, &t5h);
    vec(0x31, 0x11100, 0xEF);
    try t.expectEqual(Exit.halt, go(200));
    try t.expectEqual(@as(u32, 0x9000 - 24), rd32(OUT + 0x10));
    try t.expectEqual(@as(u32, 0x2222), rd32(OUT + 0x14));
    try t.expectEqual(@as(u32, 0x1111), rd32(OUT + 0x18));
    try t.expectEqual(@as(u32, 0xA000 - 8), rd32(OUT + 0x1C));
    try t.expectEqual(@as(u32, 0x23), rd32(OUT + 0x20));
    try t.expectEqual(@as(u32, 0x1B), rd32(OUT + 0x24));
    // RETF 8: ring 3 again, its parameters gone from its stack.
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT));
    try t.expectEqual(@as(u32, 0x99), rd32(OUT + 4));
}

test "pm: #GP and #NP from selectors, #GP and #SS from limits, through the IDT with error codes" {
    // A selector past the GDT: #GP(70h) on the MOV; DS as it was.
    var r = flat();
    put(0x10000, &t6a);
    put(0x11300, &rec);
    vec(13, 0x11300, 0x8E);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x70), rd32(OUT));
    try t.expectEqual(@as(u32, 0x10009), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0x9000 - 12), rd32(OUT + 8));
    try t.expectEqual(@as(u16, 0x10), r.seg[DS]);

    // A dword at FCh fits ES's limit (FFh); one at FEh does not: #GP(0).
    r = flat();
    put(0x10000, &t6b);
    put(0x11300, &rec);
    vec(13, 0x11300, 0x8E);
    wr32(0x500FC, 0xCAFE_BABE);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0xCAFE_BABE), r.r[EAX]);
    try t.expectEqual(@as(u32, 0), rd32(OUT));
    try t.expectEqual(@as(u32, 0x1000C), rd32(OUT + 4));

    // POPA runs off the stack's limit part way: #SS(0), with ESP as it
    // was before the POPA (the handler's frame sits just below it).
    r = flat();
    put(0x10000, &t6c);
    put(0x11300, &rec);
    vec(12, 0x11300, 0x8E);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0), rd32(OUT));
    try t.expectEqual(@as(u32, 0x1000B), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0xF0 - 12), rd32(OUT + 8));

    // A segment that is not present: #NP(50h).
    r = flat();
    put(0x10000, &t6d);
    put(0x11300, &rec);
    vec(11, 0x11300, 0x8E);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x50), rd32(OUT));
    try t.expectEqual(@as(u32, 0x10004), rd32(OUT + 4));

    // Ring 3 on a 16-bit expand-down stack (valid above 7FFFh): the
    // third push would go below it: #SS(0), on ring 0's stack.
    r = flat();
    put(0x10000, &r3);
    put(0x12000, &t6e);
    put(0x11300, &rec);
    vec(12, 0x11300, 0x8E);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0), rd32(OUT));
    try t.expectEqual(@as(u32, 0x1200F), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0x8000), rd32(OUT + 0x0C));
    try t.expectEqual(@as(u16, 0x5B), rd16(0x60000 + 0x8002));
    try t.expectEqual(@as(u16, 0x5B), rd16(0x60000 + 0x8000));
}

/// An identity map of the first 4 MiB (user, writable).
fn identity() void {
    wr32(0x20000, 0x21000 | 7);
    for (0..1024) |i| wr32(0x21000 + @as(u32, @intCast(i)) * 4, (@as(u32, @intCast(i)) << 12) | 7);
}

test "pm: paging: an identity map, a #PF its handler fixes and the restart, the TLB and CR3, INVLPG" {
    const r = flat();
    put(0x10000, &t7);
    put(0x11400, &t7h);
    vec(14, 0x11400, 0x8E);
    identity();
    wr32(0x21000 + 0x300 * 4, 0);
    wr32(0x301010, 0xAAAA_0001);
    wr32(0x302010, 0xAAAA_0002);
    wr32(0x303010, 0xAAAA_0003);
    try t.expectEqual(Exit.halt, go(200));
    try t.expect(cpu.paging);
    // Not present, a read, the supervisor's: error code 0, CR2 the
    // address; the handler mapped page 301h and the MOV ran again.
    try t.expectEqual(@as(u32, 0), rd32(OUT));
    try t.expectEqual(@as(u32, 0x300010), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0x300010), cpu.cr2);
    try t.expectEqual(@as(u32, 0xAAAA_0001), r.r[EBX]);
    // The page table changed under the TLB: the old frame, until CR3 is
    // written; then INVLPG for one page.
    try t.expectEqual(@as(u32, 0xAAAA_0001), r.r[ECX]);
    try t.expectEqual(@as(u32, 0xAAAA_0002), r.r[EDX]);
    try t.expectEqual(@as(u32, 0xAAAA_0003), r.r[ESI]);
    // Accessed and dirty bits.
    try t.expectEqual(@as(u32, 0x60), rd32(0x21000 + 0x100 * 4) & 0x60);
    try t.expectEqual(@as(u32, 0x20), rd32(0x21000 + 0x10 * 4) & 0x60);
    try t.expectEqual(@as(u32, 0x20), rd32(0x20000) & 0x20);
    try t.expectEqual(@as(u32, 1), rd32(0x100000));

    // Ring 3 writing a read-only page: #PF with P, W and U (7).
    _ = flat();
    put(0x10000, &r3);
    put(0x12000, &t7b);
    put(0x11300, &rec);
    vec(14, 0x11300, 0x8E);
    identity();
    wr32(0x21000 + 0x200 * 4, 0x200005);
    cpu.cr3 = 0x20000;
    cpu.cr0 |= cpu_mod.CR0_PG;
    try t.expectEqual(Exit.halt, go(200));
    try t.expectEqual(@as(u32, 7), rd32(OUT));
    try t.expectEqual(@as(u32, 0x12000), rd32(OUT + 4));
    try t.expectEqual(@as(u32, 0x200000), cpu.cr2);
    try t.expectEqual(@as(u32, 0), rd32(0x200000));
}

test "pm: LAR, LSL, VERR, VERW" {
    const r = flat();
    put(0x10000, &t8);
    r.r[ESI] = 0x1234;
    try t.expectEqual(Exit.halt, go(100));
    // (bits 16-19, the limit's, are undefined in LAR's result: 0 here)
    try t.expectEqual(@as(u32, 0x00C0_9A00), r.r[EBX]);
    try t.expectEqual(@as(u32, 1), r.r[ECX] & 0xFF);
    try t.expectEqual(@as(u32, 0xFF), r.r[EDX]);
    try t.expectEqual(@as(u32, 1), (r.r[ECX] >> 8) & 0xFF);
    // code: readable, not writable; flat data: writable
    try t.expectEqual(@as(u8, 1), bus.ram[OUT]);
    try t.expectEqual(@as(u8, 0), bus.ram[OUT + 1]);
    try t.expectEqual(@as(u8, 1), bus.ram[OUT + 2]);
    // past the GDT: ZF clear, the register as it was
    try t.expectEqual(@as(u8, 0), bus.ram[OUT + 3]);
    try t.expectEqual(@as(u32, 0x1234), r.r[ESI]);
    // a call gate has access rights (LAR) but no limit (LSL)
    try t.expectEqual(@as(u8, 1), bus.ram[OUT + 4]);
    try t.expectEqual(@as(u32, 0xEC00), r.r[EDI]);
    try t.expectEqual(@as(u8, 0), bus.ram[OUT + 5]);
    // 4 GiB in pages
    try t.expectEqual(@as(u8, 1), bus.ram[OUT + 6]);
    try t.expectEqual(@as(u32, 0xFFFF_FFFF), r.r[EAX]);
}

test "pm: LTR marks the TSS busy; LLDT, SLDT, STR and an LDT selector" {
    const r = flat();
    cpu.tr = 0;
    cpu.tr_type = 0;
    put(0x10000, &t11);
    wr32(0x70010, 0x0BAD_F00D);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u8, 0x8B), bus.ram[GDT + 0x28 + 5]);
    try t.expectEqual(@as(u8, 11), cpu.tr_type);
    try t.expectEqual(@as(u32, 0x28), r.r[EBX] & 0xFFFF);
    try t.expectEqual(@as(u32, 0x60), r.r[EDX] & 0xFFFF);
    try t.expectEqual(@as(u32, 0x70000), r.base[FS]);
    try t.expectEqual(@as(u32, 0x0BAD_F00D), r.r[ESI]);
}

test "pm: a hardware interrupt at ring 3 goes through the IDT; the I/O bitmap; INT n and CLI at ring 3" {
    var r = flat();
    put(0x10000, &r3);
    put(0x12000, &t9a);
    put(0x11500, &t9h);
    vec(0x20, 0x11500, 0x8E);
    wr32(0x3F00, regs.FIXED | regs.IF);
    // Port 40h is allowed by the bitmap; then ring 3 spins with IF set.
    try t.expectEqual(Exit.budget, go(100));
    try t.expectEqual(@as(u2, 3), cpu.cpl);
    try t.expectEqual(@as(u8, 0x40), bus.ram[OUT + 0x40]);
    try t.expectEqual(@as(u32, 1), bus.ports);
    bus.pending = true;
    try t.expectEqual(Exit.irq, go(100));
    bus.pending = false;
    // (a gate of DPL 0: hardware interrupts are not INT n)
    cpu.interrupt(&bus, 0x20);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u2, 0), cpu.cpl);
    try t.expectEqual(@as(u32, 0x9000 - 20), rd32(OUT + 0x10));
    try t.expectEqual(@as(u32, 0x23), rd32(OUT + 0x14));
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT + 0x18));
    try t.expectEqual(@as(u32, 0x1200D), rd32(OUT + 0x1C));
    try t.expectEqual(@as(u32, 0), rd32(OUT + 0x24) & regs.IF);

    const Case = struct { code: []const u8, err: u32 };
    const cases = [_]Case{
        // INT 20h from ring 3 to that DPL 0 gate: #GP(20h * 8 + 2)
        .{ .code = &t9b, .err = 0x20 * 8 + 2 },
        // port 60h: its bit is set in the bitmap
        .{ .code = &t9c, .err = 0 },
        // CLI: CPL 3 > IOPL 0
        .{ .code = &t9d, .err = 0 },
    };
    for (cases) |c| {
        r = flat();
        put(0x10000, &r3);
        put(0x12000, c.code);
        put(0x11300, &rec);
        vec(0x20, 0x11500, 0x8E);
        vec(13, 0x11300, 0x8E);
        try t.expectEqual(Exit.halt, go(100));
        try t.expectEqual(c.err, rd32(OUT));
        try t.expectEqual(@as(u32, 0x12000), rd32(OUT + 4));
        try t.expectEqual(@as(u32, 0xA000), rd32(OUT + 0x0C));
        try t.expectEqual(@as(u32, 0), bus.ports);
    }
}

test "pm: a double fault, and a triple fault stops the CPU" {
    // #GP finds its gate not present: #NP, so #DF (error code 0).
    _ = flat();
    put(0x10000, &t10);
    put(0x11300, &rec);
    gate(IDT + 13 * 8, 0x08, 0x11300, 0x0E, 0);
    vec(8, 0x11300, 0x8E);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0), rd32(OUT));
    try t.expectEqual(@as(u32, 0x10004), rd32(OUT + 4));

    // No gates at all: #GP, #GP delivering it (#DF), #GP delivering that.
    _ = flat();
    put(0x10000, &t10);
    try t.expectEqual(Exit.fault, go(100));
    try t.expectEqual(cpu_mod.FAULT_TRIPLE | 0x080D, cpu.fault_op);
    try t.expectEqual(@as(u32, 0x10004), cpu.fault_at);
    try t.expectEqual(Exit.fault, go(100));
}

test "pm: a 286 interrupt gate from ring 3: the 286 TSS's SP0, 16-bit pushes, 16-bit IRET; ARPL" {
    _ = flat();
    cpu.tr_base = 0x1A00;
    cpu.tr_limit = 0x2B;
    cpu.tr_type = 3;
    wr32(0x1A00 + 2, 0x0010_8800); // SP0 8800h, SS0 10h
    put(0x10000, &r3b);
    put(0x4000, &t12);
    put(0x11600, &t12h);
    // a 286 interrupt gate (DPL 3) to the 16-bit code segment at 0x10000
    gate(IDT + 0x32 * 8, 0x30, 0x1600, 0xE6, 0);
    vec(0x31, 0x11100, 0xEF);
    try t.expectEqual(Exit.halt, go(200));
    // ARPL raised 10h's RPL to 23h's (ZF set), then had nothing to do.
    try t.expectEqual(@as(u8, 1), bus.ram[OUT + 0x20]);
    try t.expectEqual(@as(u16, 0x13), rd16(OUT + 0x22));
    try t.expectEqual(@as(u8, 0), bus.ram[OUT + 0x24]);
    // Five words on SS0:SP0, the old SS:SP among them; the 16-bit code.
    try t.expectEqual(@as(u32, 0x8800 - 10), rd32(OUT + 0x10));
    try t.expectEqual(@as(u16, 0x23), rd16(OUT + 0x14));
    try t.expectEqual(@as(u16, 0xA000), rd16(OUT + 0x18));
    try t.expectEqual(@as(u16, 0x30), rd16(OUT + 0x1C));
    // The 16-bit IRET took ring 3 back to its stack and code.
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT));
    try t.expectEqual(@as(u32, 0xA000), rd32(OUT + 4));
    try t.expectEqual(@as(u16, 0x1B), rd16(OUT + 8));
}
