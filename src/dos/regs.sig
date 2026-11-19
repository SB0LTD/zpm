//! The CPU's registers as everything outside the core sees them: the eight
//! general registers (x86 encoding order), the six segment registers with
//! their bases, EIP and EFLAGS. The core keeps its own fast state (lazy
//! flags) while it runs; whenever control is outside `cpu.run` (a BIOS or
//! DOS service, an interrupt being delivered, a test) these are exact.

const std = @import("std");

pub const EAX = 0;
pub const ECX = 1;
pub const EDX = 2;
pub const EBX = 3;
pub const ESP = 4;
pub const EBP = 5;
pub const ESI = 6;
pub const EDI = 7;

pub const ES = 0;
pub const CS = 1;
pub const SS = 2;
pub const DS = 3;
pub const FS = 4;
pub const GS = 5;

pub const CF: u32 = 1 << 0;
pub const PF: u32 = 1 << 2;
pub const AF: u32 = 1 << 4;
pub const ZF: u32 = 1 << 6;
pub const SF: u32 = 1 << 7;
pub const TF: u32 = 1 << 8;
pub const IF: u32 = 1 << 9;
pub const DF: u32 = 1 << 10;
pub const OF: u32 = 1 << 11;
/// (bit 1 always reads 1)
pub const FIXED: u32 = 1 << 1;

pub const Regs = struct {
    r: [8]u32 = [_]u32{0} ** 8,
    seg: [6]u16 = [_]u16{0} ** 6,
    /// Each segment's base: seg << 4 in real mode.
    base: [6]u32 = [_]u32{0} ** 6,
    eip: u32 = 0,
    flags: u32 = FIXED,

    pub fn get16(self: *const Regs, i: u3) u16 {
        return @truncate(self.r[i]);
    }
    pub fn set16(self: *Regs, i: u3, v: u16) void {
        self.r[i] = (self.r[i] & 0xFFFF_0000) | v;
    }
    /// AL CL DL BL AH CH DH BH, as the instruction encoding numbers them.
    pub fn get8(self: *const Regs, i: u3) u8 {
        return if (i < 4) @truncate(self.r[i]) else @truncate(self.r[i - 4] >> 8);
    }
    pub fn set8(self: *Regs, i: u3, v: u8) void {
        if (i < 4) {
            self.r[i] = (self.r[i] & 0xFFFF_FF00) | v;
        } else {
            self.r[i - 4] = (self.r[i - 4] & 0xFFFF_00FF) | (@as(u32, v) << 8);
        }
    }
    pub fn setSeg(self: *Regs, s: u3, v: u16) void {
        self.seg[s] = v;
        self.base[s] = @as(u32, v) << 4;
    }

    // The names BIOS and DOS services use.
    pub fn ax(self: *const Regs) u16 {
        return self.get16(EAX);
    }
    pub fn bx(self: *const Regs) u16 {
        return self.get16(EBX);
    }
    pub fn cx(self: *const Regs) u16 {
        return self.get16(ECX);
    }
    pub fn dx(self: *const Regs) u16 {
        return self.get16(EDX);
    }
    pub fn si(self: *const Regs) u16 {
        return self.get16(ESI);
    }
    pub fn di(self: *const Regs) u16 {
        return self.get16(EDI);
    }
    pub fn bp(self: *const Regs) u16 {
        return self.get16(EBP);
    }
    pub fn sp(self: *const Regs) u16 {
        return self.get16(ESP);
    }
    pub fn al(self: *const Regs) u8 {
        return self.get8(0);
    }
    pub fn cl(self: *const Regs) u8 {
        return self.get8(1);
    }
    pub fn dl(self: *const Regs) u8 {
        return self.get8(2);
    }
    pub fn bl(self: *const Regs) u8 {
        return self.get8(3);
    }
    pub fn ah(self: *const Regs) u8 {
        return self.get8(4);
    }
    pub fn ch(self: *const Regs) u8 {
        return self.get8(5);
    }
    pub fn dh(self: *const Regs) u8 {
        return self.get8(6);
    }
    pub fn bh(self: *const Regs) u8 {
        return self.get8(7);
    }
    pub fn setAx(self: *Regs, v: u16) void {
        self.set16(EAX, v);
    }
    pub fn setBx(self: *Regs, v: u16) void {
        self.set16(EBX, v);
    }
    pub fn setCx(self: *Regs, v: u16) void {
        self.set16(ECX, v);
    }
    pub fn setDx(self: *Regs, v: u16) void {
        self.set16(EDX, v);
    }
    pub fn setSi(self: *Regs, v: u16) void {
        self.set16(ESI, v);
    }
    pub fn setDi(self: *Regs, v: u16) void {
        self.set16(EDI, v);
    }
    pub fn setAl(self: *Regs, v: u8) void {
        self.set8(0, v);
    }
    pub fn setAh(self: *Regs, v: u8) void {
        self.set8(4, v);
    }
    pub fn setBl(self: *Regs, v: u8) void {
        self.set8(3, v);
    }
    pub fn setBh(self: *Regs, v: u8) void {
        self.set8(7, v);
    }
    pub fn setCl(self: *Regs, v: u8) void {
        self.set8(1, v);
    }
    pub fn setCh(self: *Regs, v: u8) void {
        self.set8(5, v);
    }
    pub fn setDl(self: *Regs, v: u8) void {
        self.set8(2, v);
    }
    pub fn setDh(self: *Regs, v: u8) void {
        self.set8(6, v);
    }

    pub fn flag(self: *const Regs, f: u32) bool {
        return self.flags & f != 0;
    }
    pub fn setFlag(self: *Regs, f: u32, on: bool) void {
        if (on) self.flags |= f else self.flags &= ~f;
    }
    /// A service's usual answer: carry clear, or carry set and AX = code.
    pub fn ok(self: *Regs) void {
        self.setFlag(CF, false);
    }
    pub fn fail(self: *Regs, code: u16) void {
        self.setFlag(CF, true);
        self.setAx(code);
    }
};

test "regs: 8-bit halves and segments" {
    var r = Regs{};
    r.r[EAX] = 0x1234_5678;
    try std.testing.expectEqual(@as(u8, 0x78), r.al());
    try std.testing.expectEqual(@as(u8, 0x56), r.ah());
    r.setAh(0xAB);
    try std.testing.expectEqual(@as(u32, 0x1234_AB78), r.r[EAX]);
    r.setSeg(DS, 0xB800);
    try std.testing.expectEqual(@as(u32, 0xB8000), r.base[DS]);
    r.fail(2);
    try std.testing.expect(r.flag(CF));
    try std.testing.expectEqual(@as(u16, 2), r.ax());
}
