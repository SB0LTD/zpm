//! The PC's RAM: 16 MiB, flat. The first megabyte is DOS's (conventional
//! memory below 0xA0000; the adapter area above it belongs to the devices
//! and the BIOS ROM, which the machine routes before it gets here), then
//! the high memory area and extended memory (XMS, and EMS's pages).
//! With the A20 gate off an address wraps at 1 MiB, as on an 8086.
//!
//! These accessors are RAM alone: what a BIOS or DOS service reads and
//! writes (a program's buffers live in conventional memory). The CPU goes
//! through `Machine`'s bus, which sends 0xA0000-0xFFFFF to the devices.

const std = @import("std");

pub const RAM: u32 = 16 << 20;
/// Conventional memory ends where video memory starts.
pub const CONVENTIONAL: u32 = 0xA0000;
pub const MEG: u32 = 0x100000;
/// The high memory area: FFFF:0010-FFFF:FFFF, 64 KiB less 16 bytes.
pub const HMA_END: u32 = 0x10FFF0;

pub const Memory = struct {
    ram: [RAM]u8 align(4096) = undefined,
    a20: bool = false,

    pub fn clear(self: *Memory) void {
        @memset(&self.ram, 0);
        self.a20 = false;
    }

    /// A linear address as the bus sees it (wrapped at 1 MiB without A20).
    pub inline fn wrap(self: *const Memory, a: u32) u32 {
        return if (self.a20) a & (RAM - 1) else a & (MEG - 1);
    }

    pub inline fn lin(seg: u16, off: u16) u32 {
        return (@as(u32, seg) << 4) +% off;
    }

    pub inline fn rd8(self: *const Memory, a: u32) u8 {
        return self.ram[self.wrap(a)];
    }
    pub inline fn wr8(self: *Memory, a: u32, v: u8) void {
        self.ram[self.wrap(a)] = v;
    }
    pub fn rd16(self: *const Memory, a: u32) u16 {
        return @as(u16, self.rd8(a)) | (@as(u16, self.rd8(a +% 1)) << 8);
    }
    pub fn wr16(self: *Memory, a: u32, v: u16) void {
        self.wr8(a, @truncate(v));
        self.wr8(a +% 1, @truncate(v >> 8));
    }
    pub fn rd32(self: *const Memory, a: u32) u32 {
        return @as(u32, self.rd16(a)) | (@as(u32, self.rd16(a +% 2)) << 16);
    }
    pub fn wr32(self: *Memory, a: u32, v: u32) void {
        self.wr16(a, @truncate(v));
        self.wr16(a +% 2, @truncate(v >> 16));
    }

    /// seg:off forms, as services take their pointers.
    pub fn rdW(self: *const Memory, seg: u16, off: u16) u16 {
        return self.rd16(lin(seg, off));
    }
    pub fn wrW(self: *Memory, seg: u16, off: u16, v: u16) void {
        self.wr16(lin(seg, off), v);
    }
    pub fn rdB(self: *const Memory, seg: u16, off: u16) u8 {
        return self.rd8(lin(seg, off));
    }
    pub fn wrB(self: *Memory, seg: u16, off: u16, v: u8) void {
        self.wr8(lin(seg, off), v);
    }

    /// Bytes in or out at a linear address (no wrap inside: callers keep
    /// to conventional memory or to extended memory with A20 on).
    pub fn bytes(self: *Memory, a: u32, len: u32) []u8 {
        const s = self.wrap(a);
        const n = @min(len, RAM - s);
        return self.ram[s..][0..n];
    }
    pub fn copyIn(self: *Memory, a: u32, src: []const u8) void {
        for (src, 0..) |b, i| self.wr8(a +% @as(u32, @intCast(i)), b);
    }
    pub fn copyOut(self: *const Memory, a: u32, dst: []u8) void {
        for (dst, 0..) |*b, i| b.* = self.rd8(a +% @as(u32, @intCast(i)));
    }
    /// A NUL-terminated string at `a` into `buf` (cut at its size).
    pub fn cstr(self: *const Memory, a: u32, buf: []u8) []u8 {
        var n: usize = 0;
        while (n < buf.len) : (n += 1) {
            const c = self.rd8(a +% @as(u32, @intCast(n)));
            if (c == 0) break;
            buf[n] = c;
        }
        return buf[0..n];
    }
};

test "mem: A20 wraps at 1 MiB when off" {
    const m = &test_mem;
    m.clear();
    m.wr8(0x100005, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), m.rd8(0x5));
    m.a20 = true;
    m.wr8(0x100005, 0x43);
    try std.testing.expectEqual(@as(u8, 0x42), m.rd8(0x5));
    try std.testing.expectEqual(@as(u8, 0x43), m.rd8(0x100005));
    m.wrW(0x1234, 0x10, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), m.rd16(0x12350));
}

var test_mem: Memory = .{};
