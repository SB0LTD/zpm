//! The two 8259A interrupt controllers (master at 0x20, slave at 0xA0,
//! cascaded on IRQ 2), as the BIOS leaves them: vectors 0x08-0x0F and
//! 0x70-0x77. Edge-triggered requests, the mask (IMR), in-service (ISR)
//! and request (IRR) registers, specific and non-specific EOI, OCW3's
//! reads, ICW programming (a game may move the vectors).
//!
//! From Intel's 8259A data sheet: ICW1-ICW4 (single or cascade, level or
//! edge, auto-EOI), OCW1 (the mask), OCW2 (EOI specific or not, the
//! rotations, set priority), OCW3 (read IRR or ISR, poll, special mask
//! mode). Priority is a rotating order of eight levels; the slave's INT
//! output is the master's request on IR2. A request that goes away before
//! the CPU acknowledges it is answered with IR7's vector and nothing goes
//! in service (the spurious IRQ 7 / IRQ 15).

const std = @import("std");

/// One 8259A.
pub const Chip = struct {
    irr: u8 = 0,
    isr: u8 = 0,
    imr: u8 = 0xFF,
    /// The vector of IR0 (ICW2's top five bits).
    base: u8 = 0x08,
    /// The level with the lowest priority (7 after ICW1).
    lowest: u3 = 7,
    /// ICW3: on the master the IRs with slaves, on a slave its id.
    icw3: u8 = 0x04,
    single: bool = false,
    need_icw4: bool = false,
    /// Which ICW comes next on the odd port (0: none, OCW1).
    icw_step: u2 = 0,
    auto_eoi: bool = false,
    rotate_aeoi: bool = false,
    level: bool = false,
    special_mask: bool = false,
    read_isr: bool = false,
    poll: bool = false,
    /// A request was withdrawn before its acknowledge.
    lost: bool = false,

    fn bit(l: u3) u8 {
        return @as(u8, 1) << l;
    }

    /// The level with priority `p` (0 = highest).
    fn levelAt(c: *const Chip, p: u3) u3 {
        return c.lowest +% 1 +% p;
    }

    /// The highest-priority level set in `bits`, as its priority rank.
    fn topRank(c: *const Chip, bits: u8) ?u3 {
        if (bits == 0) return null;
        var p: u4 = 0;
        while (p < 8) : (p += 1) {
            if (bits & bit(c.levelAt(@intCast(p))) != 0) return @intCast(p);
        }
        return null;
    }

    /// The level the chip would interrupt with, given its IRR (with the
    /// slave's output folded in by the caller).
    fn best(c: *const Chip, irr: u8) ?u3 {
        const req = irr & ~c.imr;
        const r = c.topRank(req) orelse return null;
        // Special mask mode: only masked in-service levels stop nothing;
        // the unmasked ones block their own level alone.
        if (c.special_mask) {
            var p: u4 = r;
            while (p < 8) : (p += 1) {
                const l = c.levelAt(@intCast(p));
                if (req & bit(l) != 0 and c.isr & bit(l) == 0) return l;
            }
            return null;
        }
        if (c.topRank(c.isr)) |s| {
            if (r >= s) return null;
        }
        return c.levelAt(r);
    }

    fn eoiTop(c: *Chip) ?u3 {
        const s = c.topRank(c.isr) orelse return null;
        const l = c.levelAt(s);
        c.isr &= ~bit(l);
        return l;
    }

    fn writeEven(c: *Chip, v: u8) void {
        if (v & 0x10 != 0) {
            // ICW1.
            c.need_icw4 = v & 0x01 != 0;
            c.single = v & 0x02 != 0;
            c.level = v & 0x08 != 0;
            c.imr = 0;
            c.isr = 0;
            c.irr = 0;
            c.lowest = 7;
            c.special_mask = false;
            c.read_isr = false;
            c.poll = false;
            c.auto_eoi = false;
            c.rotate_aeoi = false;
            c.icw_step = 1;
            return;
        }
        if (v & 0x08 == 0) {
            // OCW2: R SL EOI and the level.
            const l: u3 = @truncate(v);
            switch (v >> 5) {
                0b001 => _ = c.eoiTop(),
                0b011 => c.isr &= ~bit(l),
                0b101 => if (c.eoiTop()) |top| {
                    c.lowest = top;
                },
                0b100 => c.rotate_aeoi = true,
                0b000 => c.rotate_aeoi = false,
                0b111 => {
                    c.isr &= ~bit(l);
                    c.lowest = l;
                },
                0b110 => c.lowest = l,
                else => {},
            }
            return;
        }
        // OCW3.
        if (v & 0x40 != 0) c.special_mask = v & 0x20 != 0;
        if (v & 0x02 != 0) c.read_isr = v & 0x01 != 0;
        c.poll = v & 0x04 != 0;
    }

    fn writeOdd(c: *Chip, v: u8) void {
        switch (c.icw_step) {
            0 => c.imr = v,
            1 => {
                c.base = v & 0xF8;
                c.icw_step = if (!c.single) 2 else if (c.need_icw4) 3 else 0;
            },
            2 => {
                c.icw3 = v;
                c.icw_step = if (c.need_icw4) 3 else 0;
            },
            3 => {
                c.auto_eoi = v & 0x02 != 0;
                c.icw_step = 0;
            },
        }
    }
};

pub const Pic = struct {
    master: Chip = .{ .base = 0x08, .imr = 0xB8, .icw3 = 0x04 },
    slave: Chip = .{ .base = 0x70, .imr = 0xBD, .icw3 = 0x02 },
    /// The withdrawn request was the slave's (the master saw IR2).
    lost_slave: bool = false,

    pub fn reset(self: *Pic) void {
        self.* = .{};
    }

    /// Whether the master has a slave on IR2 (cascade mode).
    fn cascaded(self: *const Pic) bool {
        return !self.master.single and self.master.icw3 & 0x04 != 0;
    }

    /// The slave's INT output folded into the master's IRR.
    fn masterIrr(self: *const Pic) u8 {
        var irr = self.master.irr;
        if (self.cascaded()) {
            if (self.slave.best(self.slave.irr) != null) irr |= 0x04;
        }
        return irr;
    }

    /// A device's line goes up (an edge: one request). IRQ 2 on the AT's
    /// bus is the slave's IR1 (IRQ 9).
    pub fn raise(self: *Pic, irq: u4) void {
        const i: u4 = if (irq == 2) 9 else irq;
        if (i < 8) self.master.irr |= Chip.bit(@intCast(i)) else self.slave.irr |= Chip.bit(@intCast(i - 8));
    }
    /// Its line goes down (level-sensitive devices only; an edge request
    /// not yet acknowledged is withdrawn too, as on the chip).
    pub fn lower(self: *Pic, irq: u4) void {
        const i: u4 = if (irq == 2) 9 else irq;
        const c = if (i < 8) &self.master else &self.slave;
        const b = Chip.bit(@truncate(i));
        if (c.irr & b != 0 and c.imr & b == 0) {
            c.lost = true;
            if (c == &self.slave) {
                self.master.lost = true;
                self.lost_slave = true;
            }
        }
        c.irr &= ~b;
    }
    /// An unmasked request above everything in service waits.
    pub fn pending(self: *const Pic) bool {
        return self.master.best(self.masterIrr()) != null;
    }
    /// The CPU takes the interrupt: its vector, the request now in service.
    /// A request withdrawn before this gives IR7's vector (spurious) with
    /// nothing in service; with nothing asked at all, null.
    pub fn acknowledge(self: *Pic) ?u8 {
        const m = &self.master;
        const l = m.best(self.masterIrr()) orelse {
            if (m.lost) {
                m.lost = false;
                if (self.lost_slave and self.cascaded()) {
                    self.lost_slave = false;
                    self.slave.lost = false;
                    inService(m, 2);
                    return self.slave.base | 7;
                }
                return m.base | 7;
            }
            return null;
        };
        m.lost = false;
        self.lost_slave = false;
        if (l == 2 and self.cascaded()) {
            inService(m, 2);
            const s = &self.slave;
            const sl = s.best(s.irr) orelse {
                s.lost = false;
                return s.base | 7;
            };
            s.lost = false;
            s.irr &= ~Chip.bit(sl);
            inService(s, sl);
            return s.base | sl;
        }
        m.irr &= ~Chip.bit(l);
        inService(m, l);
        return m.base | l;
    }

    fn inService(c: *Chip, l: u3) void {
        if (c.auto_eoi) {
            if (c.rotate_aeoi) c.lowest = l;
        } else c.isr |= Chip.bit(l);
    }

    /// OCW3's poll: the next read of the even port acknowledges.
    fn pollRead(self: *Pic, slave: bool) u8 {
        if (slave) {
            const s = &self.slave;
            s.poll = false;
            const l = s.best(s.irr) orelse return 0;
            s.irr &= ~Chip.bit(l);
            inService(s, l);
            return 0x80 | @as(u8, l);
        }
        const m = &self.master;
        m.poll = false;
        const l = m.best(self.masterIrr()) orelse return 0;
        if (l == 2 and self.cascaded()) {
            // (the slave answers its own poll; the master just records it)
            inService(m, 2);
            return 0x82;
        }
        m.irr &= ~Chip.bit(l);
        inService(m, l);
        return 0x80 | @as(u8, l);
    }

    pub fn in8(self: *Pic, port: u16) u8 {
        const slave = port & 0x80 != 0;
        const c = if (slave) &self.slave else &self.master;
        if (port & 1 != 0) return c.imr;
        if (c.poll) return self.pollRead(slave);
        if (c.read_isr) return c.isr;
        return if (slave) c.irr else self.masterIrr();
    }
    pub fn out8(self: *Pic, port: u16, v: u8) void {
        const c = if (port & 0x80 != 0) &self.slave else &self.master;
        if (port & 1 != 0) c.writeOdd(v) else c.writeEven(v);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

/// The BIOS's programming: ICW1-4 on both, all unmasked.
fn biosInit(p: *Pic) void {
    p.out8(0x20, 0x11);
    p.out8(0x21, 0x08);
    p.out8(0x21, 0x04);
    p.out8(0x21, 0x01);
    p.out8(0xA0, 0x11);
    p.out8(0xA1, 0x70);
    p.out8(0xA1, 0x02);
    p.out8(0xA1, 0x01);
    p.out8(0x21, 0x00);
    p.out8(0xA1, 0x00);
}

test "pic: priorities, EOI and nesting" {
    var p: Pic = .{};
    biosInit(&p);
    try t.expect(!p.pending());
    p.raise(1);
    p.raise(0);
    try t.expect(p.pending());
    try t.expectEqual(@as(?u8, 0x08), p.acknowledge());
    // IRQ 1 waits behind IRQ 0 in service.
    try t.expect(!p.pending());
    p.out8(0x20, 0x0B); // OCW3: read ISR
    try t.expectEqual(@as(u8, 0x01), p.in8(0x20));
    p.out8(0x20, 0x0A); // read IRR
    try t.expectEqual(@as(u8, 0x02), p.in8(0x20));
    p.out8(0x20, 0x20); // non-specific EOI
    try t.expect(p.pending());
    try t.expectEqual(@as(?u8, 0x09), p.acknowledge());
    // A higher request nests over a lower one in service.
    p.raise(0);
    try t.expectEqual(@as(?u8, 0x08), p.acknowledge());
    p.out8(0x20, 0x60); // specific EOI, level 0
    p.out8(0x20, 0x0B);
    try t.expectEqual(@as(u8, 0x02), p.in8(0x20));
    p.out8(0x20, 0x20);
    try t.expectEqual(@as(u8, 0x00), p.in8(0x20));
    try t.expectEqual(@as(?u8, null), p.acknowledge());
}

test "pic: masks, the slave on IRQ 2, vectors moved" {
    var p: Pic = .{};
    biosInit(&p);
    p.out8(0xA1, 0xFF ^ 0x20); // only IRQ 13 open on the slave
    p.raise(12);
    try t.expect(!p.pending());
    p.raise(13);
    try t.expect(p.pending());
    p.raise(3);
    // IRQ 13 (through IR2) outranks IRQ 3.
    try t.expectEqual(@as(?u8, 0x75), p.acknowledge());
    try t.expect(!p.pending()); // IR2 in service blocks IRQ 3
    p.out8(0xA0, 0x20);
    p.out8(0x20, 0x20);
    try t.expectEqual(@as(?u8, 0x0B), p.acknowledge());
    p.out8(0x20, 0x20);
    // The master's mask on IR2 shuts the slave out.
    p.out8(0x21, 0x04);
    p.raise(13);
    try t.expect(!p.pending());
    p.out8(0x21, 0x00);
    try t.expectEqual(@as(?u8, 0x75), p.acknowledge());
    p.out8(0xA0, 0x20);
    p.out8(0x20, 0x20);
    // A game moves the master to 0x50 with auto-EOI.
    p.out8(0x20, 0x11);
    p.out8(0x21, 0x50);
    p.out8(0x21, 0x04);
    p.out8(0x21, 0x03);
    p.raise(5);
    try t.expectEqual(@as(?u8, 0x55), p.acknowledge());
    p.out8(0x20, 0x0B);
    try t.expectEqual(@as(u8, 0), p.in8(0x20)); // nothing in service
    try t.expectEqual(@as(u8, 0), p.in8(0x21)); // ICW1 cleared the mask
}

test "pic: rotation, special mask, spurious, poll" {
    var p: Pic = .{};
    biosInit(&p);
    // Rotate on non-specific EOI: the level served goes lowest.
    p.raise(0);
    try t.expectEqual(@as(?u8, 0x08), p.acknowledge());
    p.out8(0x20, 0xA0);
    p.raise(0);
    p.raise(1);
    try t.expectEqual(@as(?u8, 0x09), p.acknowledge());
    p.out8(0x20, 0xC7); // set priority: 7 lowest again
    p.out8(0x20, 0x20);
    // Special mask mode lets a lower level in while a masked one serves.
    p.raise(0);
    try t.expectEqual(@as(?u8, 0x08), p.acknowledge());
    p.raise(4);
    try t.expect(!p.pending());
    p.out8(0x21, 0x01);
    p.out8(0x20, 0x68); // OCW3: set special mask
    try t.expect(p.pending());
    try t.expectEqual(@as(?u8, 0x0C), p.acknowledge());
    p.out8(0x20, 0x64); // specific EOI 4
    p.out8(0x20, 0x60); // specific EOI 0
    p.out8(0x20, 0x48); // clear special mask
    p.out8(0x21, 0x00);
    // A request withdrawn before the acknowledge: IR7's vector, no ISR.
    p.raise(3);
    p.lower(3);
    try t.expectEqual(@as(?u8, 0x0F), p.acknowledge());
    p.out8(0x20, 0x0B);
    try t.expectEqual(@as(u8, 0), p.in8(0x20));
    // The slave's: IR2 goes in service on the master, the slave says 0x77.
    p.raise(11);
    p.lower(11);
    try t.expectEqual(@as(?u8, 0x77), p.acknowledge());
    p.out8(0x20, 0x0B);
    try t.expectEqual(@as(u8, 0x04), p.in8(0x20));
    p.out8(0x20, 0x20);
    // Poll: the read acknowledges.
    p.raise(6);
    p.out8(0x20, 0x0C);
    try t.expectEqual(@as(u8, 0x86), p.in8(0x20));
    p.out8(0x20, 0x0B);
    try t.expectEqual(@as(u8, 0x40), p.in8(0x20));
}
