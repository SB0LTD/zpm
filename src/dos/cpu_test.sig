//! The 386 core on a bus of its own: 1 MiB + 64 KiB of flat RAM, port
//! I/O recorded, service traps recorded. Hand-assembled programs (code at
//! 1000:0000, stack 2000:FFFE, DS 3000, ES 4000), each ending in HLT.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const cpu_mod = @import("cpu.sig");
const regs = @import("regs.sig");
const Cpu = cpu_mod.Cpu;
const Exit = cpu_mod.Exit;

const RAM: u32 = 0x110000;

const CF = regs.CF;
const PF = regs.PF;
const AF = regs.AF;
const ZF = regs.ZF;
const SF = regs.SF;
const TF = regs.TF;
const IF = regs.IF;
const DF = regs.DF;
const OF = regs.OF;
const ARITH = CF | PF | AF | ZF | SF | OF;

const EAX = regs.EAX;
const ECX = regs.ECX;
const EDX = regs.EDX;
const EBX = regs.EBX;
const ESP = regs.ESP;
const EBP = regs.EBP;
const ESI = regs.ESI;
const EDI = regs.EDI;

const Io = struct { port: u16, v: u32, size: u8, out: bool };

const Bus = struct {
    ram: [RAM]u8 = undefined,
    io: [64]Io = undefined,
    nio: usize = 0,
    in_val: u32 = 0,
    pending: bool = false,
    ids: [16]u16 = undefined,
    nhle: usize = 0,
    hle_ok: bool = true,
    hle_cf: bool = false,
    hle_ax: ?u16 = null,

    inline fn at(a: u32) u32 {
        return if (a < RAM) a else a & 0xFFFFF;
    }
    pub inline fn rd8(b: *Bus, a: u32) u8 {
        return b.ram[at(a)];
    }
    pub inline fn wr8(b: *Bus, a: u32, v: u8) void {
        b.ram[at(a)] = v;
    }
    pub inline fn rd16(b: *Bus, a: u32) u16 {
        if (a < RAM - 1) return std.mem.readInt(u16, b.ram[a..][0..2], .little);
        return @as(u16, b.rd8(a)) | (@as(u16, b.rd8(a +% 1)) << 8);
    }
    pub inline fn wr16(b: *Bus, a: u32, v: u16) void {
        if (a < RAM - 1) return std.mem.writeInt(u16, b.ram[a..][0..2], v, .little);
        b.wr8(a, @truncate(v));
        b.wr8(a +% 1, @truncate(v >> 8));
    }
    pub inline fn rd32(b: *Bus, a: u32) u32 {
        if (a < RAM - 3) return std.mem.readInt(u32, b.ram[a..][0..4], .little);
        return @as(u32, b.rd16(a)) | (@as(u32, b.rd16(a +% 2)) << 16);
    }
    pub inline fn wr32(b: *Bus, a: u32, v: u32) void {
        if (a < RAM - 3) return std.mem.writeInt(u32, b.ram[a..][0..4], v, .little);
        b.wr16(a, @truncate(v));
        b.wr16(a +% 2, @truncate(v >> 16));
    }
    fn log(b: *Bus, port: u16, v: u32, size: u8, out: bool) void {
        if (b.nio < b.io.len) {
            b.io[b.nio] = .{ .port = port, .v = v, .size = size, .out = out };
            b.nio += 1;
        }
    }
    pub fn in8(b: *Bus, port: u16) u8 {
        b.log(port, 0, 1, false);
        return @truncate(b.in_val);
    }
    pub fn in16(b: *Bus, port: u16) u16 {
        b.log(port, 0, 2, false);
        return @truncate(b.in_val);
    }
    pub fn in32(b: *Bus, port: u16) u32 {
        b.log(port, 0, 4, false);
        return b.in_val;
    }
    pub fn out8(b: *Bus, port: u16, v: u8) void {
        b.log(port, v, 1, true);
    }
    pub fn out16(b: *Bus, port: u16, v: u16) void {
        b.log(port, v, 2, true);
    }
    pub fn out32(b: *Bus, port: u16, v: u32) void {
        b.log(port, v, 4, true);
    }
    pub fn hle(b: *Bus, c: *Cpu, id: u16) bool {
        if (b.nhle < b.ids.len) {
            b.ids[b.nhle] = id;
            b.nhle += 1;
        }
        b.hle_cf = c.regs.flags & CF != 0;
        if (b.hle_ok) {
            if (b.hle_ax) |ax| c.regs.setAx(ax);
        }
        return b.hle_ok;
    }
    pub fn irq(b: *Bus) bool {
        return b.pending;
    }
};

var bus: Bus = .{};
var cpu: Cpu = .{};

const CODE: u32 = 0x10000;
const DATA: u32 = 0x30000;
const EXTRA: u32 = 0x40000;
const STACK: u32 = 0x20000;

fn setup(code: []const u8) *regs.Regs {
    @memset(&bus.ram, 0);
    bus.nio = 0;
    bus.in_val = 0;
    bus.pending = false;
    bus.nhle = 0;
    bus.hle_ok = true;
    bus.hle_cf = false;
    bus.hle_ax = null;
    cpu.reset();
    const r = &cpu.regs;
    r.setSeg(regs.CS, 0x1000);
    r.eip = 0;
    r.setSeg(regs.SS, 0x2000);
    r.r[ESP] = 0xFFFE;
    r.setSeg(regs.DS, 0x3000);
    r.setSeg(regs.ES, 0x4000);
    r.r[EDX] = 0;
    @memcpy(bus.ram[CODE..][0..code.len], code);
    return r;
}

/// A handler that only halts, at 1000:off, for vector `vec`.
fn vector(vec: u8, off: u16) void {
    bus.wr16(@as(u32, vec) * 4, off);
    bus.wr16(@as(u32, vec) * 4 + 2, 0x1000);
    bus.ram[CODE + off] = 0xF4;
}

fn go(budget: u32) Exit {
    return cpu.run(&bus, budget);
}

fn put(a: u32, bytes: []const u8) void {
    @memcpy(bus.ram[a..][0..bytes.len], bytes);
}

const Case = struct {
    code: []const u8,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
    fin: u32 = 0,
    ra: u32,
    rd: ?u32 = null,
    fl: u32,
    care: u32 = ARITH,
};

fn runCases(cases: []const Case) !void {
    var buf: [32]u8 = undefined;
    for (cases, 0..) |c, i| {
        @memcpy(buf[0..c.code.len], c.code);
        buf[c.code.len] = 0xF4;
        const r = setup(buf[0 .. c.code.len + 1]);
        r.r[EAX] = c.a;
        r.r[EBX] = c.b;
        r.r[ECX] = c.c;
        r.r[EDX] = c.d;
        r.flags = regs.FIXED | c.fin;
        const why = go(100);
        if (why != .halt or r.r[EAX] != c.ra or (r.flags & c.care) != (c.fl & c.care) or (c.rd != null and r.r[EDX] != c.rd.?)) {
            std.debug.print("case {d} ({x}): exit {s} eax {x} (want {x}) edx {x} flags {x} (want {x} of {x})\n", .{
                i, c.code, @tagName(why), r.r[EAX], c.ra, r.r[EDX], r.flags & c.care, c.fl & c.care, c.care,
            });
            return error.TestUnexpectedResult;
        }
    }
}

test "cpu: add/adc/sub/sbb/cmp/logic/inc/dec/neg flags at 8, 16 and 32 bits" {
    try runCases(&.{
        .{ .code = &.{ 0x00, 0xD8 }, .a = 0xFF, .b = 1, .ra = 0, .fl = CF | ZF | AF | PF },
        .{ .code = &.{ 0x00, 0xD8 }, .a = 0x7F, .b = 1, .ra = 0x80, .fl = OF | SF | AF },
        .{ .code = &.{ 0x01, 0xD8 }, .a = 0x8000, .b = 0x8000, .ra = 0, .fl = CF | OF | ZF | PF },
        .{ .code = &.{ 0x66, 0x01, 0xD8 }, .a = 0xFFFF_FFFF, .b = 1, .ra = 0, .fl = CF | ZF | AF | PF },
        .{ .code = &.{ 0x10, 0xD8 }, .fin = CF, .a = 0x7F, .b = 0, .ra = 0x80, .fl = OF | SF | AF },
        .{ .code = &.{ 0x11, 0xD8 }, .fin = CF, .a = 0xFFFF, .b = 0xFFFF, .ra = 0xFFFF, .fl = CF | AF | SF | PF },
        .{ .code = &.{ 0x28, 0xD8 }, .a = 0, .b = 1, .ra = 0xFF, .fl = CF | AF | SF | PF },
        .{ .code = &.{ 0x28, 0xD8 }, .a = 0x80, .b = 1, .ra = 0x7F, .fl = OF | AF },
        .{ .code = &.{ 0x19, 0xD8 }, .fin = CF, .a = 0, .b = 0, .ra = 0xFFFF, .fl = CF | AF | SF | PF },
        .{ .code = &.{ 0x66, 0x19, 0xD8 }, .fin = CF, .a = 0x8000_0000, .b = 0, .ra = 0x7FFF_FFFF, .fl = OF | AF | PF },
        .{ .code = &.{ 0x38, 0xD8 }, .a = 5, .b = 5, .ra = 5, .fl = ZF | PF },
        .{ .code = &.{ 0x66, 0x39, 0xD8 }, .a = 1, .b = 2, .ra = 1, .fl = CF | SF | AF | PF },
        .{ .code = &.{ 0x20, 0xD8 }, .fin = CF | OF, .a = 0xF0, .b = 0x0F, .ra = 0, .fl = ZF | PF },
        .{ .code = &.{ 0x31, 0xD8 }, .a = 0x1234, .b = 0x1234, .ra = 0, .fl = ZF | PF },
        .{ .code = &.{ 0x66, 0x09, 0xD8 }, .a = 0x8000_0000, .b = 1, .ra = 0x8000_0001, .fl = SF },
        .{ .code = &.{ 0xFE, 0xC0 }, .fin = CF, .a = 0xFF, .ra = 0, .fl = CF | ZF | AF | PF },
        .{ .code = &.{0x40}, .a = 0x7FFF, .ra = 0x8000, .fl = OF | SF | AF | PF },
        .{ .code = &.{ 0xFE, 0xC8 }, .a = 0, .ra = 0xFF, .fl = SF | AF | PF },
        .{ .code = &.{ 0x66, 0x48 }, .a = 0x8000_0000, .ra = 0x7FFF_FFFF, .fl = OF | AF | PF },
        .{ .code = &.{ 0xF6, 0xD8 }, .a = 1, .ra = 0xFF, .fl = CF | SF | AF | PF },
        .{ .code = &.{ 0xF7, 0xD8 }, .a = 0, .ra = 0, .fl = ZF | PF },
        .{ .code = &.{ 0xF6, 0xD8 }, .a = 0x80, .ra = 0x80, .fl = CF | OF | SF },
        .{ .code = &.{ 0x04, 0x01 }, .a = 0x0F, .ra = 0x10, .fl = AF },
        .{ .code = &.{ 0x2D, 0x01, 0x00 }, .a = 0, .ra = 0xFFFF, .fl = CF | AF | SF | PF },
        .{ .code = &.{ 0x80, 0xF8, 0x05 }, .a = 3, .ra = 3, .fl = CF | SF | AF },
        .{ .code = &.{ 0x66, 0x83, 0xC0, 0xFF }, .a = 1, .ra = 0, .fl = CF | ZF | AF | PF },
        .{ .code = &.{ 0x84, 0xD8 }, .a = 0x80, .b = 0x80, .ra = 0x80, .fl = SF },
        // 16-bit ops keep EAX's top half.
        .{ .code = &.{ 0x05, 0x01, 0x00 }, .a = 0xABCD_FFFF, .ra = 0xABCD_0000, .fl = CF | ZF | AF | PF },
    });
}

test "cpu: shifts and rotates by 0, 1, CL and immediate counts" {
    const noaf = ARITH & ~AF;
    try runCases(&.{
        .{ .code = &.{ 0xD0, 0xE0 }, .a = 0x81, .ra = 0x02, .fl = CF | OF, .care = noaf },
        .{ .code = &.{ 0xD2, 0xE0 }, .fin = CF, .a = 0x81, .c = 0, .ra = 0x81, .fl = CF },
        .{ .code = &.{ 0xD3, 0xE8 }, .a = 0x8001, .c = 1, .ra = 0x4000, .fl = CF | OF | PF, .care = noaf },
        .{ .code = &.{ 0xD0, 0xF8 }, .a = 0x81, .ra = 0xC0, .fl = CF | SF | PF, .care = noaf },
        .{ .code = &.{ 0xD0, 0xC0 }, .a = 0x81, .ra = 0x03, .fl = CF | OF, .care = CF | OF },
        .{ .code = &.{ 0xD0, 0xD8 }, .a = 0x01, .ra = 0x00, .fl = CF, .care = CF | OF },
        .{ .code = &.{ 0xD3, 0xD0 }, .fin = CF, .a = 0x8000, .c = 1, .ra = 0x0001, .fl = CF | OF, .care = CF | OF },
        .{ .code = &.{ 0x66, 0xD3, 0xE0 }, .a = 1, .c = 31, .ra = 0x8000_0000, .fl = SF | PF, .care = CF | ZF | SF | PF },
        .{ .code = &.{ 0xD3, 0xE0 }, .a = 1, .c = 16, .ra = 0, .fl = CF | ZF | PF, .care = CF | ZF | SF | PF },
        .{ .code = &.{ 0x0F, 0xA4, 0xD8, 0x04 }, .a = 0x1234, .b = 0xABCD, .ra = 0x234A, .fl = CF, .care = CF | ZF | SF | PF },
        .{ .code = &.{ 0x66, 0x0F, 0xAD, 0xD8 }, .a = 1, .b = 3, .c = 1, .ra = 0x8000_0000, .fl = CF | SF | PF, .care = CF | ZF | SF | PF },
        .{ .code = &.{ 0xC1, 0xC8, 0x04 }, .a = 0x1234, .ra = 0x4123, .fl = OF, .care = CF | OF },
        // RCL by 9 on a byte: the 9-bit rotate comes round to the start.
        .{ .code = &.{ 0xC0, 0xD0, 0x09 }, .fin = CF, .a = 0x55, .ra = 0x55, .fl = CF, .care = CF },
        // SAR of a negative byte by more than its width: all sign.
        .{ .code = &.{ 0xC0, 0xF8, 0x0C }, .a = 0x80, .ra = 0xFF, .fl = CF | SF | PF, .care = CF | ZF | SF | PF },
        // A count of 32 is 0 on a 386: nothing changes.
        .{ .code = &.{ 0x66, 0xC1, 0xE0, 0x20 }, .fin = OF, .a = 7, .ra = 7, .fl = OF },
    });
}

test "cpu: mul, imul, div, idiv" {
    try runCases(&.{
        .{ .code = &.{ 0xF6, 0xE3 }, .a = 0x80, .b = 2, .ra = 0x0100, .fl = CF | OF, .care = CF | OF },
        .{ .code = &.{ 0xF6, 0xEB }, .a = 0xFF, .b = 2, .ra = 0xFFFE, .fl = 0, .care = CF | OF },
        .{ .code = &.{ 0x66, 0xF7, 0xE3 }, .a = 0xFFFF_FFFF, .b = 2, .ra = 0xFFFF_FFFE, .rd = 1, .fl = CF | OF, .care = CF | OF },
        .{ .code = &.{ 0xF7, 0xEB }, .a = 0xFFFF, .b = 0xFFFF, .ra = 1, .rd = 0, .fl = 0, .care = CF | OF },
        .{ .code = &.{ 0x6B, 0xC3, 0x10 }, .b = 0x1000, .ra = 0, .fl = CF | OF, .care = CF | OF },
        .{ .code = &.{ 0x69, 0xC3, 0xFE, 0xFF }, .b = 3, .ra = 0xFFFA, .fl = 0, .care = CF | OF },
        .{ .code = &.{ 0x66, 0x0F, 0xAF, 0xC3 }, .a = 3, .b = 0xFFFF_FFFE, .ra = 0xFFFF_FFFA, .fl = 0, .care = CF | OF },
        .{ .code = &.{ 0xF6, 0xF3 }, .a = 0x0107, .b = 2, .ra = 0x0183, .fl = 0, .care = 0 },
        .{ .code = &.{ 0xF7, 0xFB }, .a = 0xFFF9, .d = 0xFFFF, .b = 2, .ra = 0xFFFD, .rd = 0xFFFF, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0xF7, 0xF3 }, .a = 0, .d = 1, .b = 0x10, .ra = 0x1000_0000, .rd = 0, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0xF7, 0xFB }, .a = 0xFFFF_FFF9, .d = 0xFFFF_FFFF, .b = 0xFFFF_FFFE, .ra = 3, .rd = 0xFFFF_FFFF, .fl = 0, .care = 0 },
        .{ .code = &.{ 0xF6, 0xFB }, .a = 0xFF80, .b = 0x01, .ra = 0x0080, .fl = 0, .care = 0 }, // -128/1
    });
}

test "cpu: divide error is int 0 with IP on the DIV" {
    const cases = [_]struct { code: []const u8, ax: u16, dx: u16, bx: u16 }{
        .{ .code = &.{ 0xF6, 0xF3, 0xF4 }, .ax = 7, .dx = 0, .bx = 0 },
        .{ .code = &.{ 0xF6, 0xF3, 0xF4 }, .ax = 0x1000, .dx = 0, .bx = 1 },
        .{ .code = &.{ 0xF7, 0xFB, 0xF4 }, .ax = 0x8000, .dx = 0xFFFF, .bx = 0xFFFF },
        .{ .code = &.{ 0xD4, 0x00, 0xF4 }, .ax = 1, .dx = 0, .bx = 0 },
    };
    for (cases) |c| {
        const r = setup(c.code);
        vector(0, 0x0100);
        r.setAx(c.ax);
        r.setDx(c.dx);
        r.setBx(c.bx);
        try t.expectEqual(Exit.halt, go(100));
        try t.expectEqual(@as(u32, 0x101), r.eip);
        try t.expectEqual(@as(u16, 0xFFF8), r.sp());
        try t.expectEqual(@as(u16, 0x0000), bus.rd16(STACK + 0xFFF8));
        try t.expectEqual(@as(u16, 0x1000), bus.rd16(STACK + 0xFFFA));
        try t.expectEqual(c.ax, r.ax());
    }
}

test "cpu: string instructions with REP, DF and budgets" {
    // rep movsb
    var r = setup(&.{ 0xF3, 0xA4, 0xF4 });
    put(DATA, "hello");
    r.setSi(0);
    r.setDi(0x10);
    r.setCx(5);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqualStrings("hello", bus.ram[EXTRA + 0x10 ..][0..5]);
    try t.expectEqual(@as(u16, 5), r.si());
    try t.expectEqual(@as(u16, 0x15), r.di());
    try t.expectEqual(@as(u16, 0), r.cx());
    try t.expectEqual(@as(u64, 6), cpu.executed);

    // std; rep movsw: backwards
    r = setup(&.{ 0xFD, 0xF3, 0xA5, 0xF4 });
    put(DATA + 4, &.{ 1, 2, 3, 4, 5, 6 });
    r.setSi(8);
    r.setDi(8);
    r.setCx(3);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 2, 3, 4, 5, 6 }, bus.ram[EXTRA..][0..10]);
    try t.expectEqual(@as(u16, 2), r.si());
    try t.expectEqual(@as(u16, 2), r.di());
    try t.expect(r.flags & DF != 0);

    // repne scasb
    r = setup(&.{ 0xF2, 0xAE, 0xF4 });
    put(EXTRA, "hello");
    r.setAl('l');
    r.setCx(5);
    r.setDi(0);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 3), r.di());
    try t.expectEqual(@as(u16, 2), r.cx());
    try t.expect(r.flags & ZF != 0);

    // repe cmpsb
    r = setup(&.{ 0xF3, 0xA6, 0xF4 });
    put(DATA, "abcX");
    put(EXTRA, "abcY");
    r.setCx(4);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 4), r.si());
    try t.expectEqual(@as(u16, 0), r.cx());
    try t.expect(r.flags & ZF == 0);
    try t.expect(r.flags & CF != 0);

    // repe cmpsw stops early at a difference
    r = setup(&.{ 0xF3, 0xA7, 0xF4 });
    put(DATA, &.{ 1, 0, 2, 0, 3, 0 });
    put(EXTRA, &.{ 1, 0, 9, 0, 3, 0 });
    r.setCx(3);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 1), r.cx());
    try t.expectEqual(@as(u16, 4), r.si());

    // rep stosd with 32-bit addressing
    r = setup(&.{ 0x66, 0x67, 0xF3, 0xAB, 0xF4 });
    r.r[EDI] = 0x10;
    r.r[ECX] = 2;
    r.r[EAX] = 0x1122_3344;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x1122_3344), bus.rd32(EXTRA + 0x10));
    try t.expectEqual(@as(u32, 0x1122_3344), bus.rd32(EXTRA + 0x14));
    try t.expectEqual(@as(u32, 0x18), r.r[EDI]);
    try t.expectEqual(@as(u32, 0), r.r[ECX]);

    // lodsb with a segment override; stosw
    r = setup(&.{ 0x26, 0xAC, 0xAB, 0xF4 });
    put(EXTRA + 7, &.{0x5A});
    r.setSi(7);
    r.setDi(0x20);
    r.r[EAX] = 0x1200;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x125A), bus.rd16(EXTRA + 0x20));
    try t.expectEqual(@as(u16, 8), r.si());

    // A REP that runs out of budget resumes on the same instruction.
    r = setup(&.{ 0xF3, 0xA4, 0xF4 });
    r.setCx(100);
    try t.expectEqual(Exit.budget, go(10));
    try t.expectEqual(@as(u16, 90), r.cx());
    try t.expectEqual(@as(u32, 0), r.eip);
    try t.expectEqual(@as(u64, 10), cpu.executed);
    try t.expectEqual(Exit.halt, go(1000));
    try t.expectEqual(@as(u16, 0), r.cx());
    try t.expectEqual(@as(u64, 101), cpu.executed);

    // A zero count does nothing (and keeps the flags).
    r = setup(&.{ 0xF3, 0xA6, 0xF4 });
    r.flags |= ZF | CF;
    try t.expectEqual(Exit.halt, go(10));
    try t.expect(r.flags & (ZF | CF) == ZF | CF);
    try t.expectEqual(@as(u16, 0), r.si());
}

test "cpu: port I/O, INS and OUTS" {
    var r = setup(&.{ 0xE4, 0x60, 0xE6, 0x43, 0xBA, 0xC9, 0x03, 0xF3, 0x6E, 0x66, 0xEF, 0xED, 0xF4 });
    bus.in_val = 0x1C;
    put(DATA, &.{ 1, 2, 3 });
    r.setCx(3);
    r.setSi(0);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(usize, 7), bus.nio);
    try t.expectEqual(Io{ .port = 0x60, .v = 0, .size = 1, .out = false }, bus.io[0]);
    try t.expectEqual(Io{ .port = 0x43, .v = 0x1C, .size = 1, .out = true }, bus.io[1]);
    try t.expectEqual(Io{ .port = 0x3C9, .v = 1, .size = 1, .out = true }, bus.io[2]);
    try t.expectEqual(Io{ .port = 0x3C9, .v = 3, .size = 1, .out = true }, bus.io[4]);
    try t.expectEqual(Io{ .port = 0x3C9, .v = 0x1C, .size = 4, .out = true }, bus.io[5]);
    try t.expectEqual(Io{ .port = 0x3C9, .v = 0, .size = 2, .out = false }, bus.io[6]);

    r = setup(&.{ 0xBA, 0xF0, 0x01, 0x6D, 0xF4 });
    bus.in_val = 0xBEEF;
    r.setDi(4);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0xBEEF), bus.rd16(EXTRA + 4));
    try t.expectEqual(@as(u16, 6), r.di());
}

test "cpu: 16-bit offsets wrap at 64 KiB; the stack wraps" {
    var r = setup(&.{ 0x8A, 0x00, 0xF4 });
    bus.ram[DATA + 1] = 0x77;
    bus.ram[DATA + 0x10001] = 0x55;
    r.setBx(0xFFFF);
    r.setSi(2);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u8, 0x77), r.al());

    r = setup(&.{ 0x50, 0xF4 });
    r.r[ESP] = 0;
    r.setAx(0xABCD);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());
    try t.expectEqual(@as(u16, 0xABCD), bus.rd16(STACK + 0xFFFE));

    // [bp+d8] defaults to SS
    r = setup(&.{ 0x8B, 0x46, 0x02, 0xF4 });
    r.r[EBP] = 0x100;
    bus.wr16(STACK + 0x102, 0x4242);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0x4242), r.ax());

    // lea ax,[bx+si-2] wraps
    r = setup(&.{ 0x8D, 0x40, 0xFE, 0xF4 });
    r.setBx(1);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0xFFFF), r.ax());
}

test "cpu: 0x66 and 0x67 forms" {
    var r = setup(&.{ 0x67, 0x8A, 0x44, 0xB3, 0x10, 0xF4 });
    bus.ram[DATA + 0x118] = 0x99;
    r.r[EBX] = 0x100;
    r.r[ESI] = 2;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u8, 0x99), r.al());

    // flat addressing past 64 KiB
    r = setup(&.{ 0x67, 0x8A, 0x03, 0xF4 });
    r.setSeg(regs.DS, 0);
    r.r[EBX] = 0x12345;
    bus.ram[0x12345] = 0x3C;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u8, 0x3C), r.al());

    // [esp] defaults to SS
    r = setup(&.{ 0x67, 0x8B, 0x04, 0x24, 0xF4 });
    r.r[ESP] = 0x10;
    bus.wr16(STACK + 0x10, 0x6789);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0x6789), r.ax());

    // disp32 alone, mov eax,imm32, lea eax,[ecx*4+0x1000]
    r = setup(&.{ 0x67, 0x8B, 0x05, 0x00, 0x01, 0x00, 0x00, 0x66, 0xBA, 0x78, 0x56, 0x34, 0x12, 0x67, 0x66, 0x8D, 0x34, 0x8D, 0x00, 0x10, 0x00, 0x00, 0xF4 });
    bus.wr16(DATA + 0x100, 0xCAFE);
    r.r[ECX] = 3;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0xCAFE), r.ax());
    try t.expectEqual(@as(u32, 0x1234_5678), r.r[EDX]);
    try t.expectEqual(@as(u32, 0x100C), r.r[ESI]);

    // [ebp+disp8] defaults to SS; sib with ebp base and mod 1
    r = setup(&.{ 0x67, 0x8B, 0x44, 0x25, 0x04, 0xF4 });
    r.r[EBP] = 0x20;
    bus.wr16(STACK + 0x24, 0x1357);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0x1357), r.ax());

    // push/pop 32-bit
    r = setup(&.{ 0x66, 0x68, 0x44, 0x33, 0x22, 0x11, 0x66, 0x5B, 0xF4 });
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x1122_3344), r.r[EBX]);
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());
}

test "cpu: the service trap syncs registers and can wait" {
    var r = setup(&.{ 0xF9, 0xFE, 0x38, 0x21, 0xFE, 0x39, 0x05, 0xF4 });
    bus.hle_ax = 0x4C00;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(usize, 2), bus.nhle);
    try t.expectEqual(@as(u16, 0x21), bus.ids[0]);
    try t.expectEqual(@as(u16, 0x105), bus.ids[1]);
    try t.expect(bus.hle_cf);
    try t.expectEqual(@as(u16, 0x4C00), r.ax());

    r = setup(&.{ 0xFE, 0x38, 0x16, 0xF4 });
    bus.hle_ok = false;
    try t.expectEqual(Exit.wait, go(100));
    try t.expectEqual(@as(u32, 0), r.eip);
    try t.expectEqual(Exit.wait, go(100));
    bus.hle_ok = true;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(usize, 3), bus.nhle);

    // FE /7 with any other ModRM is invalid: int 6.
    r = setup(&.{ 0xFE, 0x3F, 0xF4 });
    vector(6, 0x600);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x601), r.eip);
}

test "cpu: interrupts wait for IF and the STI shadow" {
    var r = setup(&.{ 0xFB, 0x90, 0x90, 0xF4 });
    bus.pending = true;
    try t.expectEqual(Exit.irq, go(100));
    try t.expectEqual(@as(u32, 2), r.eip);
    try t.expectEqual(@as(u64, 2), cpu.executed);
    // IF set: at once
    try t.expectEqual(Exit.irq, go(100));
    try t.expectEqual(@as(u64, 2), cpu.executed);
    cpu.interrupt(&bus, 8);
    try t.expect(r.flags & IF == 0);

    // HLT with IF clear stays halted; with IF set and a request, .irq.
    r = setup(&.{ 0xFA, 0xF4 });
    r.flags |= IF;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(Exit.halt, go(100));
    bus.pending = true;
    try t.expectEqual(Exit.halt, go(100));
    r.flags |= IF;
    try t.expectEqual(Exit.irq, go(100));
    vector(8, 0x800);
    cpu.interrupt(&bus, 8);
    try t.expect(!cpu.halted);
    try t.expectEqual(@as(u16, 2), bus.rd16(STACK + 0xFFF8)); // (after the HLT)

    // An OUT (an EOI) can make one wait mid-run.
    r = setup(&.{ 0xE6, 0x20, 0x90, 0xF4 });
    r.flags |= IF;
    try t.expectEqual(Exit.halt, go(100));
}

test "cpu: INT and IRET round trip, INT3, INTO, single step" {
    var r = setup(&.{ 0xF9, 0xFB, 0xCD, 0x21, 0xF4 });
    bus.wr16(0x21 * 4, 0x0200);
    bus.wr16(0x21 * 4 + 2, 0x1000);
    put(CODE + 0x200, &.{ 0x9C, 0x59, 0xB3, 0x42, 0xCF });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u8, 0x42), r.bl());
    try t.expect(r.cx() & IF == 0);
    try t.expect(r.flags & CF != 0);
    try t.expect(r.flags & IF != 0);
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());
    try t.expectEqual(@as(u32, 5), r.eip);

    r = setup(&.{ 0xCC, 0xF4 });
    vector(3, 0x300);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 1), bus.rd16(STACK + 0xFFF8));

    r = setup(&.{ 0xCE, 0xB0, 0x7F, 0x04, 0x01, 0xCE, 0xF4 });
    vector(4, 0x400);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x401), r.eip);
    try t.expectEqual(@as(u16, 6), bus.rd16(STACK + 0xFFF8));

    // pushf; pop ax; or ax,100h; push ax; popf; nop; nop: the trap after
    // the first NOP.
    r = setup(&.{ 0x9C, 0x58, 0x0D, 0x00, 0x01, 0x50, 0x9D, 0x90, 0x90, 0xF4 });
    vector(1, 0x100);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x101), r.eip);
    try t.expectEqual(@as(u16, 8), bus.rd16(STACK + 0xFFF8));
    try t.expect(bus.rd16(STACK + 0xFFFC) & TF != 0);
    try t.expect(r.flags & TF == 0);

    // iretd
    r = setup(&.{ 0x66, 0x6A, 0x00, 0x66, 0x6A, 0x00, 0x66, 0x68, 0x00, 0x07, 0x00, 0x00, 0x66, 0xCF });
    bus.ram[0x00700] = 0xF4;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x701), r.base[regs.CS] + r.eip);
}

test "cpu: flags images, LAHF/SAHF and the 486 probes" {
    var r = setup(&.{ 0x68, 0x00, 0x70, 0x9D, 0x9C, 0x58, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x7002), r.ax());

    r = setup(&.{ 0x68, 0xFF, 0xFE, 0x9D, 0x9C, 0x58, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x7ED7), r.ax());

    // AC and ID toggle: a 486 with CPUID.
    inline for (.{ 0x04, 0x20 }) |b| {
        r = setup(&.{ 0x66, 0x9C, 0x66, 0x58, 0x66, 0x89, 0xC1, 0x66, 0x35, 0x00, 0x00, b, 0x00, 0x66, 0x50, 0x66, 0x9D, 0x66, 0x9C, 0x66, 0x58, 0xF4 });
        try t.expectEqual(Exit.halt, go(100));
        try t.expectEqual(@as(u32, b) << 16, r.r[EAX] ^ r.r[ECX]);
    }

    r = setup(&.{ 0x66, 0x31, 0xC0, 0x0F, 0xA2, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x756E_6547), r.r[EBX]);
    try t.expectEqual(@as(u32, 0x4965_6E69), r.r[EDX]);
    try t.expectEqual(@as(u32, 0x6C65_746E), r.r[ECX]);
    r = setup(&.{ 0x66, 0xB8, 0x01, 0x00, 0x00, 0x00, 0x0F, 0xA2, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x0435), r.r[EAX]);
    try t.expectEqual(@as(u32, 1), r.r[EDX] & 1);

    r = setup(&.{ 0xF9, 0x9F, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u8, 0x03), r.ah());
    r = setup(&.{ 0xB4, 0xFF, 0x9E, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0xD7), r.flags & 0xFF);
}

test "cpu: BCD adjustments" {
    try runCases(&.{
        .{ .code = &.{ 0x00, 0xD8, 0x27 }, .a = 0x79, .b = 0x35, .ra = 0x14, .fl = CF, .care = CF },
        .{ .code = &.{ 0x28, 0xD8, 0x2F }, .a = 0x14, .b = 0x35, .ra = 0x79, .fl = CF, .care = CF },
        .{ .code = &.{ 0xD4, 0x0A }, .a = 0x3F, .ra = 0x0603, .fl = 0, .care = 0 },
        .{ .code = &.{ 0xD5, 0x0A }, .a = 0x0603, .ra = 0x003F, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x00, 0xD8, 0x37 }, .a = 0x09, .b = 0x08, .ra = 0x0107, .fl = CF | AF, .care = CF | AF },
        .{ .code = &.{ 0x28, 0xD8, 0x3F }, .a = 0x0102, .b = 0x05, .ra = 0x0007, .fl = CF | AF, .care = CF | AF },
        .{ .code = &.{0xD6}, .fin = CF, .a = 0, .ra = 0xFF, .fl = CF, .care = CF },
    });
}

test "cpu: stack frames, PUSHA/POPA, BOUND" {
    var r = setup(&.{ 0xC8, 0x04, 0x00, 0x00, 0xF4, 0xC9, 0xF4 });
    r.r[EBP] = 0x1234;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0xFFFC), r.bp());
    try t.expectEqual(@as(u16, 0xFFF8), r.sp());
    cpu.halted = false;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0x1234), r.bp());
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());

    r = setup(&.{ 0xC8, 0x00, 0x00, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0xFFFC), r.bp());
    try t.expectEqual(@as(u16, 0xFFFA), r.sp());
    try t.expectEqual(@as(u16, 0xFFFC), bus.rd16(STACK + 0xFFFA));

    r = setup(&.{ 0x60, 0x31, 0xC0, 0x31, 0xDB, 0x31, 0xF6, 0x61, 0x66, 0x60, 0x66, 0x31, 0xFF, 0x66, 0x61, 0xF4 });
    r.r[EAX] = 0x1111;
    r.r[EBX] = 0x2222;
    r.r[ESI] = 0x3333;
    r.r[EDI] = 0x4444_5555;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x1111), r.r[EAX]);
    try t.expectEqual(@as(u32, 0x2222), r.r[EBX]);
    try t.expectEqual(@as(u32, 0x3333), r.r[ESI]);
    try t.expectEqual(@as(u32, 0x4444_5555), r.r[EDI]);
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());
    try t.expectEqual(@as(u32, 0xFFFE), bus.rd32(STACK + 0xFFEA)); // (PUSHAD's ESP)

    r = setup(&.{ 0x62, 0x06, 0x00, 0x01, 0xF4 });
    vector(5, 0x500);
    bus.wr16(DATA + 0x100, 0);
    bus.wr16(DATA + 0x102, 10);
    r.setAx(10);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 5), r.eip);
    r = setup(&.{ 0x62, 0x06, 0x00, 0x01, 0xF4 });
    vector(5, 0x500);
    bus.wr16(DATA + 0x102, 10);
    r.setAx(11);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x501), r.eip);
}

test "cpu: jumps, calls, loops" {
    var r = setup(&.{ 0xB9, 0x05, 0x00, 0x40, 0xE2, 0xFD, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 5), r.ax());

    r = setup(&.{ 0xE3, 0x01, 0x40, 0x31, 0xC0, 0x0F, 0x84, 0x01, 0x00, 0x40, 0x75, 0x01, 0x40, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 1), r.ax());

    r = setup(&.{ 0xE8, 0x02, 0x00, 0xF4, 0xF4, 0x40, 0xC3 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 1), r.ax());
    try t.expectEqual(@as(u32, 4), r.eip);
    try t.expectEqual(@as(u16, 0xFFFE), r.sp());

    r = setup(&.{ 0x9A, 0x00, 0x04, 0x00, 0x10, 0xF4 });
    put(CODE + 0x400, &.{ 0x40, 0xCA, 0x00, 0x00 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 1), r.ax());
    try t.expectEqual(@as(u32, 6), r.eip);

    r = setup(&.{ 0xBB, 0x07, 0x00, 0xFF, 0xD3, 0xF4, 0xF4, 0x40, 0xC3 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 6), r.eip);
    try t.expectEqual(@as(u16, 1), r.ax());

    // jmp far [mem]; jmp far
    r = setup(&.{ 0xFF, 0x2E, 0x00, 0x01 });
    bus.wr16(DATA + 0x100, 0x0010);
    bus.wr16(DATA + 0x102, 0x0050);
    put(0x510, &.{ 0xEA, 0x00, 0x05, 0x00, 0x10 });
    bus.ram[CODE + 0x500] = 0xF4;
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 0x10501), r.base[regs.CS] + r.eip);

    // loopne stops on ZF
    r = setup(&.{ 0xB9, 0x0A, 0x00, 0x40, 0x3D, 0x03, 0x00, 0xE0, 0xFA, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 3), r.ax());
    try t.expectEqual(@as(u16, 7), r.cx());

    // setcc, every condition once
    r = setup(&.{ 0xF9, 0x0F, 0x92, 0xC0, 0x0F, 0x93, 0xC4, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x0001), r.ax());
}

test "cpu: bit instructions, extensions, exchange, segment loads" {
    try runCases(&.{
        .{ .code = &.{ 0x0F, 0xB6, 0xC3 }, .b = 0x80, .ra = 0x0080, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0x0F, 0xBF, 0xC3 }, .b = 0x8000, .ra = 0xFFFF_8000, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0x0F, 0xBE, 0xC3 }, .b = 0xFE, .ra = 0xFFFF_FFFE, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x0F, 0xA3, 0xD8 }, .a = 4, .b = 2, .ra = 4, .fl = CF, .care = CF },
        .{ .code = &.{ 0x0F, 0xBA, 0xF0, 0x03 }, .a = 0x0F, .ra = 0x07, .fl = CF, .care = CF },
        .{ .code = &.{ 0x0F, 0xBA, 0xE8, 0x13 }, .a = 0, .ra = 0x0008, .fl = 0, .care = CF }, // bts ax,19 -> bit 3
        .{ .code = &.{ 0x0F, 0xBC, 0xC3 }, .b = 0x0100, .ra = 8, .fl = 0, .care = ZF },
        .{ .code = &.{ 0x0F, 0xBD, 0xC3 }, .b = 0x8001, .ra = 15, .fl = 0, .care = ZF },
        .{ .code = &.{ 0x0F, 0xBC, 0xC3 }, .a = 0x55, .b = 0, .ra = 0x55, .fl = ZF, .care = ZF },
        .{ .code = &.{ 0x66, 0x0F, 0xC8 }, .a = 0x1234_5678, .ra = 0x7856_3412, .fl = 0, .care = 0 },
        .{ .code = &.{0x98}, .a = 0x80, .ra = 0xFF80, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0x98 }, .a = 0x8000, .ra = 0xFFFF_8000, .fl = 0, .care = 0 },
        .{ .code = &.{0x99}, .a = 0x8000, .ra = 0x8000, .rd = 0xFFFF, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x66, 0x99 }, .a = 0x7000_0000, .d = 5, .ra = 0x7000_0000, .rd = 0, .fl = 0, .care = 0 },
        .{ .code = &.{0x93}, .a = 1, .b = 2, .ra = 2, .fl = 0, .care = 0 },
        .{ .code = &.{ 0x0F, 0xC1, 0xD8 }, .a = 1, .b = 2, .ra = 3, .fl = PF, .care = ARITH },
        .{ .code = &.{ 0x8C, 0xD8 }, .ra = 0x3000, .fl = 0, .care = 0 },
    });

    // bts [100h],ax with ax=17: bit 1 of the word at 102h; ax=-1: bit 15 of FEh
    var r = setup(&.{ 0x0F, 0xAB, 0x06, 0x00, 0x01, 0xB8, 0xFF, 0xFF, 0x0F, 0xAB, 0x06, 0x00, 0x01, 0xF4 });
    r.setAx(17);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u8, 0x02), bus.ram[DATA + 0x102]);
    try t.expectEqual(@as(u8, 0x80), bus.ram[DATA + 0xFF]);

    // cmpxchg cx,bx: equal, then not
    r = setup(&.{ 0x0F, 0xB1, 0xD9, 0xF4 });
    r.setAx(5);
    r.setCx(5);
    r.setBx(9);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 9), r.cx());
    try t.expect(r.flags & ZF != 0);
    r = setup(&.{ 0x0F, 0xB1, 0xD9, 0xF4 });
    r.setAx(4);
    r.setCx(5);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 5), r.ax());
    try t.expect(r.flags & ZF == 0);

    // xadd ax,bx keeps both
    r = setup(&.{ 0x0F, 0xC1, 0xD8, 0xF4 });
    r.setAx(1);
    r.setBx(2);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 3), r.ax());
    try t.expectEqual(@as(u16, 1), r.bx());

    // lds, lss, lfs, xlat, moffs with an override, mov es,ax
    r = setup(&.{ 0xC5, 0x06, 0x00, 0x01, 0x0F, 0xB2, 0x26, 0x04, 0x01, 0x0F, 0xB4, 0x1E, 0x08, 0x01, 0xF4 });
    put(DATA + 0x100, &.{ 0x34, 0x12, 0x78, 0x56, 0x00, 0x80, 0x00, 0x21, 0x11, 0x11, 0x22, 0x22 });
    put(0x56780 + 0x104, &.{ 0x00, 0x80, 0x00, 0x21, 0x11, 0x11, 0x22, 0x22 });
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u16, 0x1234), r.ax());
    try t.expectEqual(@as(u16, 0x5678), r.seg[regs.DS]);
    try t.expectEqual(@as(u16, 0x8000), r.sp());
    try t.expectEqual(@as(u16, 0x2100), r.seg[regs.SS]);
    try t.expectEqual(@as(u16, 0x1111), r.bx());
    try t.expectEqual(@as(u16, 0x2222), r.seg[regs.FS]);

    r = setup(&.{ 0xD7, 0x26, 0xA0, 0x00, 0x01, 0x8E, 0xC3, 0x64, 0x8A, 0x27, 0xF4 });
    r.setBx(0x100);
    r.setAl(5);
    bus.ram[DATA + 0x105] = 0xAA;
    bus.ram[EXTRA + 0x100] = 0xBB;
    r.setSeg(regs.FS, 0x5000);
    bus.ram[0x50100] = 0xCC;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u8, 0xBB), r.al());
    try t.expectEqual(@as(u16, 0x0100), r.seg[regs.ES]);
    try t.expectEqual(@as(u8, 0xCC), r.ah());
}

test "cpu: invalid opcodes are int 6; CR0 and the system instructions" {
    var r = setup(&.{ 0x0F, 0x0B, 0xF4 });
    vector(6, 0x600);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x601), r.eip);
    try t.expectEqual(@as(u16, 0), bus.rd16(STACK + 0xFFF8));
    try t.expectEqual(@as(u32, 0x0F0B), cpu.fault_op);
    try t.expectEqual(@as(u32, CODE), cpu.fault_at);

    r = setup(&.{ 0x8E, 0xC8, 0xF4 });
    vector(6, 0x600);
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x601), r.eip);

    r = setup(&.{ 0x0F, 0x20, 0xC0, 0x0F, 0x01, 0xE3, 0x0F, 0x01, 0x06, 0x00, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x10), r.r[EAX] & 0x11);
    try t.expectEqual(@as(u16, 0x0010), r.bx());
    try t.expectEqual(@as(u16, 0xFFFF), bus.rd16(DATA + 0x100));

    // MOV CR0 with PE stops: .fault on the instruction.
    r = setup(&.{ 0x66, 0x83, 0xC8, 0x01, 0x0F, 0x22, 0xC0, 0xF4 });
    try t.expectEqual(Exit.fault, go(10));
    try t.expectEqual(@as(u32, 4), r.eip);
    try t.expectEqual(@as(u32, 0x0F22C0), cpu.fault_op);
    r = setup(&.{ 0xB8, 0x01, 0x00, 0x0F, 0x01, 0xF0, 0xF4 });
    try t.expectEqual(Exit.fault, go(10));
    // ...without PE it is fine.
    r = setup(&.{ 0x0F, 0x20, 0xC0, 0x66, 0x83, 0xC8, 0x08, 0x0F, 0x22, 0xC0, 0x0F, 0x06, 0x0F, 0x20, 0xC3, 0xF4 });
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0), r.r[EBX] & 0x8);

    // LIDT moves the real-mode vector table.
    r = setup(&.{ 0x0F, 0x01, 0x1E, 0x00, 0x01, 0xCD, 0x02, 0xF4 });
    put(DATA + 0x100, &.{ 0xFF, 0x03, 0x00, 0x05, 0x00, 0x00 });
    bus.wr16(0x508, 0x0700);
    bus.wr16(0x50A, 0x1000);
    bus.ram[CODE + 0x700] = 0xF4;
    try t.expectEqual(Exit.halt, go(10));
    try t.expectEqual(@as(u32, 0x500), cpu.idt_base);
    try t.expectEqual(@as(u32, 0x701), r.eip);
}

// ── The FPU ─────────────────────────────────────────────────────────────

fn f64at(a: u32) f64 {
    const lo: u64 = bus.rd32(a);
    const hi: u64 = bus.rd32(a + 4);
    return @bitCast(lo | hi << 32);
}

test "x87: arithmetic, stores, FSTSW" {
    // fld1; fld1; faddp; fistp word [100h]
    var r = setup(&.{ 0xD9, 0xE8, 0xD9, 0xE8, 0xDE, 0xC1, 0xDF, 0x1E, 0x00, 0x01, 0xDF, 0xE0, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 2), bus.rd16(DATA + 0x100));
    try t.expectEqual(@as(u16, 0), r.ax());

    // fld1; fldz; fcom st1; fnstsw ax: C0, TOP 6
    r = setup(&.{ 0x9B, 0xDB, 0xE3, 0xD9, 0xE8, 0xD9, 0xEE, 0xD8, 0xD1, 0xDF, 0xE0, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x3100), r.ax());

    // fild 10; fild 3; fsubp -> 7; fild 10; fild 3; fsubrp -> -7
    r = setup(&.{
        0xDF, 0x06, 0x00, 0x01, 0xDF, 0x06, 0x02, 0x01, 0xDE, 0xE9, 0xDF, 0x1E, 0x04, 0x01,
        0xDF, 0x06, 0x00, 0x01, 0xDF, 0x06, 0x02, 0x01, 0xDE, 0xE1, 0xDF, 0x1E, 0x06, 0x01,
        0xDF, 0x06, 0x00, 0x01, 0xDF, 0x06, 0x02, 0x01, 0xDE, 0xF9, 0xDD, 0x1E, 0x08, 0x01,
        0xF4,
    });
    bus.wr16(DATA + 0x100, 10);
    bus.wr16(DATA + 0x102, 3);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 7), bus.rd16(DATA + 0x104));
    try t.expectEqual(@as(u16, @bitCast(@as(i16, -7))), bus.rd16(DATA + 0x106));
    try t.expectEqual(@as(f64, 10.0 / 3.0), f64at(DATA + 0x108));

    // fild word 2; fsqrt; fstp qword
    r = setup(&.{ 0xDF, 0x06, 0x00, 0x01, 0xD9, 0xFA, 0xDD, 0x1E, 0x08, 0x01, 0xF4 });
    bus.wr16(DATA + 0x100, 2);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@sqrt(@as(f64, 2)), f64at(DATA + 0x108));

    // 1/0: ZE, +inf
    r = setup(&.{ 0xD9, 0xE8, 0xD9, 0xEE, 0xDE, 0xF9, 0xDF, 0xE0, 0xDD, 0x1E, 0x00, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expect(r.ax() & 0x4 != 0);
    try t.expect(std.math.isInf(f64at(DATA + 0x100)));

    // fldpi; fld1; fld1; faddp; fdivp -> pi/2; fsin -> 1; fstp
    r = setup(&.{ 0xD9, 0xEB, 0xD9, 0xE8, 0xD9, 0xE8, 0xDE, 0xC1, 0xDE, 0xF9, 0xD9, 0xFE, 0xDD, 0x1E, 0x00, 0x01, 0xD9, 0xE8, 0xD9, 0xE8, 0xD9, 0xF3, 0xDD, 0x1E, 0x08, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(f64, 1.0), f64at(DATA + 0x100));
    try t.expectEqual(std.math.pi / 4.0, f64at(DATA + 0x108));

    // fprem 7 mod 3 = 1, quotient 2 (C3); frndint; fscale; fxtract; fxch
    r = setup(&.{
        0xDF, 0x06, 0x02, 0x01, 0xDF, 0x06, 0x00, 0x01, 0xD9, 0xF8, 0xDF, 0xE0, 0xDF, 0x1E, 0x10, 0x01, 0xDD, 0xD8,
        0xDF, 0x06, 0x02, 0x01, 0xD9, 0xE8, 0xD9, 0xFD, 0xDF, 0x1E, 0x12, 0x01, 0xDD, 0xD8,
        0xDF, 0x06, 0x04, 0x01, 0xD9, 0xF4, 0xDD, 0x1E, 0x18, 0x01, 0xDF, 0x1E, 0x14, 0x01,
        0xD9, 0xE8, 0xD9, 0xEE, 0xD9, 0xC9, 0xDF, 0x1E, 0x16, 0x01, 0xDD, 0xD8,
        0xF4,
    });
    bus.wr16(DATA + 0x100, 7);
    bus.wr16(DATA + 0x102, 3);
    bus.wr16(DATA + 0x104, 12);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 1), bus.rd16(DATA + 0x110));
    try t.expectEqual(@as(u16, 0x4000), r.ax() & 0x4700);
    try t.expectEqual(@as(u16, 8), bus.rd16(DATA + 0x112));
    try t.expectEqual(@as(f64, 1.5), f64at(DATA + 0x118));
    try t.expectEqual(@as(u16, 3), bus.rd16(DATA + 0x114));
    try t.expectEqual(@as(u16, 1), bus.rd16(DATA + 0x116));
    try t.expectEqual(@as(u16, 0), cpu.fpu.status() & 0x3800);
}

test "x87: rounding control, FST m32, FXAM, FTST" {
    // fld 2.5; fistp -> 2 (nearest even); chop: -2.7 -> -2; down: -2.7 -> -3; up: 2.1 -> 3
    var r = setup(&.{
        0xD9, 0x06, 0x00, 0x01, 0xDB, 0x1E, 0x20, 0x01,
        0xD9, 0x2E, 0x08, 0x01, 0xD9, 0x06, 0x04, 0x01, 0xDB, 0x1E, 0x24, 0x01,
        0xD9, 0x2E, 0x0A, 0x01, 0xD9, 0x06, 0x04, 0x01, 0xDB, 0x1E, 0x28, 0x01,
        0xD9, 0x2E, 0x0C, 0x01, 0xD9, 0x06, 0x10, 0x01, 0xDB, 0x1E, 0x2C, 0x01,
        // round up: 0.1 as a float rounds above it; then FNSTCW
        0xD9, 0x06, 0x14, 0x01, 0xD9, 0x1E, 0x30, 0x01, 0xD9, 0x3E, 0x34, 0x01,
        0xF4,
    });
    bus.wr32(DATA + 0x100, @bitCast(@as(f32, 2.5)));
    bus.wr32(DATA + 0x104, @bitCast(@as(f32, -2.7)));
    bus.wr16(DATA + 0x108, 0x0F7F);
    bus.wr16(DATA + 0x10A, 0x077F);
    bus.wr16(DATA + 0x10C, 0x0B7F);
    bus.wr32(DATA + 0x110, @bitCast(@as(f32, 2.1)));
    bus.wr32(DATA + 0x114, @bitCast(@as(f32, -1.0)));
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u32, 2), bus.rd32(DATA + 0x120));
    try t.expectEqual(@as(u32, @bitCast(@as(i32, -2))), bus.rd32(DATA + 0x124));
    try t.expectEqual(@as(u32, @bitCast(@as(i32, -3))), bus.rd32(DATA + 0x128));
    try t.expectEqual(@as(u32, 3), bus.rd32(DATA + 0x12C));
    try t.expectEqual(@as(f32, -1.0), @as(f32, @bitCast(bus.rd32(DATA + 0x130))));
    try t.expectEqual(@as(u16, 0x0B7F), bus.rd16(DATA + 0x134));

    // FST m32 under each RC, of 1/3
    inline for (.{ 0x037F, 0x077F, 0x0B7F, 0x0F7F }) |cw| {
        r = setup(&.{ 0xD9, 0x2E, 0x08, 0x01, 0xDF, 0x06, 0x00, 0x01, 0xDF, 0x06, 0x02, 0x01, 0xDE, 0xF9, 0xD9, 0x1E, 0x10, 0x01, 0xF4 });
        bus.wr16(DATA + 0x100, 1);
        bus.wr16(DATA + 0x102, 3);
        bus.wr16(DATA + 0x108, cw);
        try t.expectEqual(Exit.halt, go(100));
        const v: f32 = @bitCast(bus.rd32(DATA + 0x110));
        const third: f64 = 1.0 / 3.0;
        switch (cw) {
            0x077F, 0x0F7F => try t.expect(@as(f64, v) < third),
            else => try t.expect(@as(f64, v) > third),
        }
    }

    // fldz; fxam -> C3; fchs; fxam -> C3 C1; ftst -> C3; fabs, fld1, fcomp; empty fxam
    r = setup(&.{ 0xD9, 0xEE, 0xD9, 0xE5, 0xDF, 0xE0, 0x89, 0xC3, 0xD9, 0xE0, 0xD9, 0xE5, 0xDF, 0xE0, 0x89, 0xC1, 0xDD, 0xD8, 0xD9, 0xE5, 0xDF, 0xE0, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x4000), r.bx() & 0x4700);
    try t.expectEqual(@as(u16, 0x4200), r.cx() & 0x4700);
    try t.expectEqual(@as(u16, 0x4100), r.ax() & 0x4500);
}

test "x87: 80-bit and 64-bit integer data come back bit for bit; FSAVE/FRSTOR" {
    // pi as 80 bits: fld tbyte; fstp tbyte
    var r = setup(&.{ 0xDB, 0x2E, 0x00, 0x01, 0xDB, 0x3E, 0x10, 0x01, 0xDF, 0x2E, 0x20, 0x01, 0xDF, 0x3E, 0x28, 0x01, 0xF4 });
    const pi80 = [_]u8{ 0x35, 0xC2, 0x68, 0x21, 0xA2, 0xDA, 0x0F, 0xC9, 0x00, 0x40 };
    put(DATA + 0x100, &pi80);
    put(DATA + 0x120, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqualSlices(u8, &pi80, bus.ram[DATA + 0x110 ..][0..10]);
    try t.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F }, bus.ram[DATA + 0x128 ..][0..8]);
    try t.expectEqual(@as(u16, 0), r.ax());

    // fld1; fldpi; fnsave; (init) frstor; fstp; fstp
    r = setup(&.{ 0xD9, 0xE8, 0xD9, 0xEB, 0xDD, 0x36, 0x00, 0x01, 0xDF, 0xE0, 0x89, 0xC3, 0xDD, 0x26, 0x00, 0x01, 0xDD, 0x1E, 0x80, 0x01, 0xDD, 0x1E, 0x88, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0), r.bx());
    try t.expectEqual(@as(u16, 0x037F), bus.rd16(DATA + 0x100));
    try t.expectEqual(@as(u16, 0x3000), bus.rd16(DATA + 0x102) & 0x3800);
    try t.expectEqual(@as(u16, 0x0FFF), bus.rd16(DATA + 0x104));
    try t.expectEqual(std.math.pi, f64at(DATA + 0x180));
    try t.expectEqual(@as(f64, 1.0), f64at(DATA + 0x188));

    // FBSTP and FBLD: 1234
    r = setup(&.{ 0xDF, 0x06, 0x00, 0x01, 0xDF, 0x36, 0x10, 0x01, 0xDF, 0x26, 0x10, 0x01, 0xD9, 0xE0, 0xDF, 0x1E, 0x20, 0x01, 0xF4 });
    bus.wr16(DATA + 0x100, 1234);
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqualSlices(u8, &.{ 0x34, 0x12, 0, 0, 0, 0, 0, 0, 0, 0 }, bus.ram[DATA + 0x110 ..][0..10]);
    try t.expectEqual(@as(u16, @bitCast(@as(i16, -1234))), bus.rd16(DATA + 0x120));

    // fstenv (16-bit layout): cw, sw, tw, then the last instruction's address
    r = setup(&.{ 0xD9, 0xE8, 0xD9, 0x36, 0x00, 0x01, 0xF4 });
    try t.expectEqual(Exit.halt, go(100));
    try t.expectEqual(@as(u16, 0x037F), bus.rd16(DATA + 0x100));
    try t.expectEqual(@as(u16, 0x3800), bus.rd16(DATA + 0x102) & 0x3800);
    try t.expectEqual(@as(u16, 0x3FFF), bus.rd16(DATA + 0x104));
    try t.expectEqual(@as(u16, 0x0000), bus.rd16(DATA + 0x106));
    try t.expectEqual(@as(u16, 0x1000 | 0x1E8), bus.rd16(DATA + 0x108));
    try t.expectEqual(@as(u16, 0x037F | 0x3F), cpu.fpu.cw);
}

// ── Speed ───────────────────────────────────────────────────────────────

fn nowNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "cpu: speed of simple instructions" {
    // 0: add ax,bx; 2: mov [si],ax; 4: inc si; 5: mov bx,[si];
    // 7: and si,3FFFh; B: cmp ax,dx; D: jz 0; F: loop 0; 11: jmp 0
    const r = setup(&.{ 0x01, 0xD8, 0x89, 0x04, 0x46, 0x8B, 0x1C, 0x81, 0xE6, 0xFF, 0x3F, 0x39, 0xD0, 0x74, 0xF1, 0xE2, 0xEF, 0xEB, 0xED });
    r.setBx(1);
    r.setDx(0xFFFF);
    const n: u32 = if (builtin.mode == .debug) 2_000_000 else 200_000_000;
    const t0 = nowNs();
    try t.expectEqual(Exit.budget, go(n));
    const ns = nowNs() - t0;
    try t.expectEqual(@as(u64, n), cpu.executed);
    if (ns > 0) std.debug.print("\ncpu: {d} instructions in {d} ms: {d} M/s ({s})\n", .{ n, ns / 1_000_000, @as(u64, n) * 1000 / ns, @tagName(builtin.mode) });

    // rep movsd of 64000 bytes, 100 times
    const r2 = setup(&.{ 0x31, 0xF6, 0x31, 0xFF, 0xB9, 0x80, 0x3E, 0xF3, 0x66, 0xA5, 0xEB, 0xF4 });
    _ = r2;
    const t1 = nowNs();
    const m: u32 = if (builtin.mode == .debug) 200_000 else 20_000_000;
    try t.expectEqual(Exit.budget, go(m));
    const ns2 = nowNs() - t1;
    if (ns2 > 0) std.debug.print("cpu: rep movsd: {d} M dwords/s\n", .{@as(u64, m) * 1000 / ns2});
}

test {
    _ = @import("cpu_x87.sig");
}
