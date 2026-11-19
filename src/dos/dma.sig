//! The two 8237 DMA controllers: 8-bit channels 0-3 (0x00-0x0F) and 16-bit
//! channels 4-7 (0xC0-0xDF), their page registers (0x80-0x8F), masks,
//! modes (single, auto-initialize, read/write, increment/decrement),
//! terminal count, flip-flop. Only the Sound Blaster uses it here.
//!
//! From Intel's 8237A data sheet and the AT's wiring: the second
//! controller sits on even ports (0xC0 + 2 * register; the odd ones mirror
//! them), moves words, and its address counts words: a 16-bit channel's
//! byte address is page bits 7-1, then the word address shifted left one
//! (page bit 0 ignored), so a transfer stays inside its 128 KiB. Channel
//! 4 is the cascade (the BIOS leaves it unmasked). The page registers not
//! used by a channel keep what is written (0x80 is the POST code port).
//! DMA addresses reach RAM directly (the A20 gate is the CPU's).

const std = @import("std");
const mem_mod = @import("mem.sig");
const Memory = mem_mod.Memory;

pub const Channel = struct {
    base_addr: u16 = 0,
    base_count: u16 = 0,
    addr: u16 = 0,
    count: u16 = 0,
    /// The mode register: transfer (bits 3-2), auto-init (4), decrement
    /// (5), mode (7-6).
    mode: u8 = 0,
    page: u8 = 0,
    masked: bool = true,
    /// Reached terminal count (status bits 0-3), until the status is read.
    tc: bool = false,
    request: bool = false,

    fn autoInit(c: *const Channel) bool {
        return c.mode & 0x10 != 0;
    }
    fn down(c: *const Channel) bool {
        return c.mode & 0x20 != 0;
    }
};

pub const Controller = struct {
    ch: [4]Channel = .{ .{}, .{}, .{}, .{} },
    flip: bool = false,
    command: u8 = 0,
    temp: u8 = 0,

    fn masterClear(c: *Controller) void {
        for (&c.ch) |*x| {
            x.masked = true;
            x.tc = false;
            x.request = false;
        }
        c.flip = false;
        c.command = 0;
        c.temp = 0;
    }

    fn read(c: *Controller, reg: u4) u8 {
        switch (reg) {
            0, 2, 4, 6 => return c.half(c.ch[reg >> 1].addr),
            1, 3, 5, 7 => return c.half(c.ch[reg >> 1].count),
            8 => {
                var s: u8 = 0;
                for (&c.ch, 0..) |*x, i| {
                    if (x.tc) s |= @as(u8, 1) << @intCast(i);
                    if (x.request) s |= @as(u8, 0x10) << @intCast(i);
                    x.tc = false;
                }
                return s;
            },
            0xD => return c.temp,
            0xF => {
                var m: u8 = 0xF0;
                for (&c.ch, 0..) |*x, i| {
                    if (x.masked) m |= @as(u8, 1) << @intCast(i);
                }
                return m;
            },
            else => return 0xFF,
        }
    }
    fn half(c: *Controller, v: u16) u8 {
        const hi = c.flip;
        c.flip = !c.flip;
        return if (hi) @truncate(v >> 8) else @truncate(v);
    }

    fn write(c: *Controller, reg: u4, v: u8) void {
        switch (reg) {
            0, 2, 4, 6 => {
                const x = &c.ch[reg >> 1];
                x.base_addr = c.setHalf(x.base_addr, v);
                x.addr = x.base_addr;
            },
            1, 3, 5, 7 => {
                const x = &c.ch[reg >> 1];
                x.base_count = c.setHalf(x.base_count, v);
                x.count = x.base_count;
            },
            8 => c.command = v,
            9 => c.ch[v & 3].request = v & 4 != 0,
            0xA => c.ch[v & 3].masked = v & 4 != 0,
            0xB => c.ch[v & 3].mode = v,
            0xC => c.flip = false,
            0xD => c.masterClear(),
            0xE => for (&c.ch) |*x| {
                x.masked = false;
            },
            0xF => for (&c.ch, 0..) |*x, i| {
                x.masked = (v >> @intCast(i)) & 1 != 0;
            },
        }
    }
    fn setHalf(c: *Controller, old: u16, v: u8) u16 {
        const hi = c.flip;
        c.flip = !c.flip;
        return if (hi) (old & 0x00FF) | (@as(u16, v) << 8) else (old & 0xFF00) | v;
    }
};

/// Which channel a page register at 0x80 + i serves (0xFF: none).
const PAGE_CH = [16]u8{ 0xFF, 2, 3, 1, 0xFF, 0xFF, 0xFF, 0, 0xFF, 6, 7, 5, 0xFF, 0xFF, 0xFF, 4 };

pub const Dma = struct {
    c8: Controller = .{},
    c16: Controller = .{},
    /// The page registers as written (0x80-0x8F).
    pages: [16]u8 = [_]u8{0} ** 16,

    pub fn reset(self: *Dma) void {
        self.* = .{};
        // The BIOS: channel 4 is the cascade, unmasked.
        self.c16.ch[0].mode = 0xC0;
        self.c16.ch[0].masked = false;
    }

    fn chan(self: *Dma, ch: u3) *Channel {
        return if (ch < 4) &self.c8.ch[ch] else &self.c16.ch[ch - 4];
    }
    fn chanC(self: *const Dma, ch: u3) *const Channel {
        return if (ch < 4) &self.c8.ch[ch] else &self.c16.ch[ch - 4];
    }
    fn controllerOf(self: *const Dma, ch: u3) *const Controller {
        return if (ch < 4) &self.c8 else &self.c16;
    }

    /// The channel's next transfer's byte address.
    fn physical(c: *const Channel, ch: u3) u32 {
        if (ch < 4) return (@as(u32, c.page) << 16) | c.addr;
        return (@as(u32, c.page & 0xFE) << 16) | (@as(u32, c.addr) << 1);
    }

    /// One transfer done: the address and count move; true at terminal
    /// count (the count rolled from 0 to FFFFh).
    fn stepOne(c: *Channel) bool {
        c.addr = if (c.down()) c.addr -% 1 else c.addr +% 1;
        const was = c.count;
        c.count -%= 1;
        if (was != 0) return false;
        c.tc = true;
        if (c.autoInit()) {
            c.addr = c.base_addr;
            c.count = c.base_count;
        } else c.masked = true;
        return true;
    }

    /// Moves up to `buf.len` bytes between memory and the device on `ch`;
    /// stops at terminal count.
    fn move(self: *Dma, ram: []u8, ch: u3, buf: []u8, to_mem: bool) struct { n: usize, tc: bool } {
        if (!self.ready(ch)) return .{ .n = 0, .tc = false };
        const c = self.chan(ch);
        const wide = ch >= 4;
        const unit: usize = if (wide) 2 else 1;
        const verify = (c.mode >> 2) & 3 == 0;
        var n: usize = 0;
        while (n + unit <= buf.len) {
            const a = physical(c, ch) & (mem_mod.RAM - 1);
            if (!verify) {
                var k: usize = 0;
                while (k < unit) : (k += 1) {
                    const at = (a + @as(u32, @intCast(k))) & (mem_mod.RAM - 1);
                    if (to_mem) ram[at] = buf[n + k] else buf[n + k] = ram[at];
                }
            } else if (!to_mem) {
                @memset(buf[n..][0..unit], 0);
            }
            n += unit;
            if (stepOne(c)) return .{ .n = n, .tc = true };
        }
        return .{ .n = n, .tc = false };
    }

    /// The device reads up to `out.len` bytes from memory on channel `ch`
    /// (a 16-bit channel moves words: `out.len` is even); returns how many
    /// and whether the channel reached its terminal count (an
    /// auto-initialize channel has then reloaded: `ready` stays true; a
    /// single-cycle one masked itself).
    pub fn read(self: *Dma, mem: *const Memory, ch: u3, out: []u8) struct { n: usize, tc: bool } {
        const ram: []u8 = @constCast(&mem.ram);
        const r = self.move(ram, ch, out, false);
        return .{ .n = r.n, .tc = r.tc };
    }
    /// The device writes into memory (a recording).
    pub fn write(self: *Dma, mem: *Memory, ch: u3, in: []const u8) struct { n: usize, tc: bool } {
        const r = self.move(&mem.ram, ch, @constCast(in), true);
        return .{ .n = r.n, .tc = r.tc };
    }
    /// Channel `ch` is unmasked and has a transfer programmed (and its
    /// controller is enabled).
    pub fn ready(self: *const Dma, ch: u3) bool {
        const ctl = self.controllerOf(ch);
        if (ctl.command & 0x04 != 0) return false;
        return !self.chanC(ch).masked;
    }
    /// Whether channel `ch` reloads at terminal count.
    pub fn autoInit(self: *const Dma, ch: u3) bool {
        return self.chanC(ch).autoInit();
    }
    /// Transfers left before terminal count (bytes or words).
    pub fn remaining(self: *const Dma, ch: u3) u32 {
        return @as(u32, self.chanC(ch).count) + 1;
    }

    pub fn in8(self: *Dma, port: u16) u8 {
        switch (port) {
            0x00...0x0F => return self.c8.read(@intCast(port)),
            0x80...0x8F => {
                const i = port - 0x80;
                const ch = PAGE_CH[i];
                if (ch != 0xFF) return self.chan(@intCast(ch)).page;
                return self.pages[i];
            },
            0xC0...0xDF => return self.c16.read(@intCast((port - 0xC0) >> 1)),
            else => return 0xFF,
        }
    }
    pub fn out8(self: *Dma, port: u16, v: u8) void {
        switch (port) {
            0x00...0x0F => self.c8.write(@intCast(port), v),
            0x80...0x8F => {
                const i = port - 0x80;
                self.pages[i] = v;
                const ch = PAGE_CH[i];
                if (ch != 0xFF) self.chan(@intCast(ch)).page = v;
            },
            0xC0...0xDF => self.c16.write(@intCast((port - 0xC0) >> 1), v),
            else => {},
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

var test_mem: Memory = .{};

test "dma: an 8-bit single-cycle transfer, TC, the mask" {
    const m = &test_mem;
    var d: Dma = .{};
    d.reset();
    var i: u32 = 0;
    while (i < 256) : (i += 1) m.ram[0x23400 + i] = @truncate(i);
    // Channel 1: mask, mode (single, read, increment), address, count, page.
    d.out8(0x0A, 0x05);
    d.out8(0x0B, 0x49);
    d.out8(0x0C, 0);
    d.out8(0x02, 0x00);
    d.out8(0x02, 0x34);
    d.out8(0x03, 99);
    d.out8(0x03, 0);
    d.out8(0x83, 0x02);
    try t.expect(!d.ready(1));
    d.out8(0x0A, 0x01);
    try t.expect(d.ready(1));
    var buf: [64]u8 = undefined;
    var r = d.read(m, 1, &buf);
    try t.expectEqual(@as(usize, 64), r.n);
    try t.expect(!r.tc);
    try t.expectEqual(@as(u8, 63), buf[63]);
    r = d.read(m, 1, &buf);
    try t.expectEqual(@as(usize, 36), r.n);
    try t.expect(r.tc);
    try t.expectEqual(@as(u8, 99), buf[35]);
    try t.expect(!d.ready(1)); // masked itself
    // The status shows TC on channel 1, once.
    try t.expectEqual(@as(u8, 0x02), d.in8(0x08) & 0x0F);
    try t.expectEqual(@as(u8, 0x00), d.in8(0x08) & 0x0F);
    // The current count reads FFFFh, address past the end.
    d.out8(0x0C, 0);
    try t.expectEqual(@as(u8, 0x64), d.in8(0x02));
    try t.expectEqual(@as(u8, 0x34), d.in8(0x02));
    try t.expectEqual(@as(u8, 0xFF), d.in8(0x03));
    try t.expectEqual(@as(u8, 0xFF), d.in8(0x03));
}

test "dma: 8-bit auto-init and decrement, write to memory" {
    const m = &test_mem;
    var d: Dma = .{};
    d.reset();
    // Channel 1 auto-init read, 10 bytes at 0x10000.
    d.out8(0x0B, 0x59);
    d.out8(0x0C, 0);
    d.out8(0x02, 0);
    d.out8(0x02, 0);
    d.out8(0x03, 9);
    d.out8(0x03, 0);
    d.out8(0x83, 0x01);
    d.out8(0x0A, 0x01);
    var k: u32 = 0;
    while (k < 10) : (k += 1) m.ram[0x10000 + k] = @intCast(k + 1);
    var buf: [25]u8 = undefined;
    var got: usize = 0;
    var tcs: u32 = 0;
    while (got < 25) {
        const r = d.read(m, 1, buf[got..]);
        got += r.n;
        if (r.tc) tcs += 1;
    }
    try t.expectEqual(@as(u32, 2), tcs);
    try t.expectEqual(@as(u8, 1), buf[10]);
    try t.expectEqual(@as(u8, 5), buf[24]);
    try t.expect(d.ready(1));
    // Channel 3: decrement, write (device to memory), 4 bytes down from 0x5003.
    d.out8(0x0B, 0x67);
    d.out8(0x0C, 0);
    d.out8(0x06, 0x03);
    d.out8(0x06, 0x50);
    d.out8(0x07, 3);
    d.out8(0x07, 0);
    d.out8(0x82, 0x00);
    d.out8(0x0A, 0x03);
    const w = d.write(m, 3, "abcd");
    try t.expect(w.tc);
    try t.expectEqualSlices(u8, "dcba", m.ram[0x5000..0x5004]);
    // Master clear masks everything.
    d.out8(0x0D, 0);
    try t.expect(!d.ready(1));
    try t.expectEqual(@as(u8, 0xFF), d.in8(0x0F));
}

test "dma: a 16-bit channel moves words inside its 128 KiB" {
    const m = &test_mem;
    var d: Dma = .{};
    d.reset();
    // Channel 5 at byte 0x3FFFC: page 0x03 (bit 0 ignored -> 0x02), word
    // address 0xFFFE; 4 words: the last two wrap to 0x20000.
    m.ram[0x3FFFC] = 0x11;
    m.ram[0x3FFFD] = 0x22;
    m.ram[0x3FFFE] = 0x33;
    m.ram[0x3FFFF] = 0x44;
    m.ram[0x20000] = 0x55;
    m.ram[0x20001] = 0x66;
    m.ram[0x20002] = 0x77;
    m.ram[0x20003] = 0x88;
    d.out8(0xD4, 0x05); // mask 5
    d.out8(0xD6, 0x59); // auto-init read, channel 5
    d.out8(0xD8, 0);
    d.out8(0xC4, 0xFE);
    d.out8(0xC4, 0xFF);
    d.out8(0xC6, 3);
    d.out8(0xC6, 0);
    d.out8(0x8B, 0x03);
    d.out8(0xD4, 0x01);
    try t.expect(d.ready(5));
    var buf: [10]u8 = undefined;
    const r = d.read(m, 5, &buf);
    try t.expectEqual(@as(usize, 8), r.n);
    try t.expect(r.tc);
    try t.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 }, buf[0..8]);
    try t.expect(d.ready(5)); // auto-init: reloaded
    try t.expectEqual(@as(u32, 4), d.remaining(5));
    try t.expectEqual(@as(u8, 0x02), d.in8(0xD0) & 0x0F); // TC on channel 5
    try t.expectEqual(@as(u8, 0x03), d.in8(0x8B));
}
