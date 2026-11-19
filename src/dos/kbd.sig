//! The 8042 keyboard controller at 0x60/0x64: scan codes (set 1, as the
//! controller translates them) queued from the host's key events, IRQ 1
//! per byte, the status register, controller commands (self-test, the
//! output port with the A20 gate, LED and typematic commands to the
//! keyboard answered with ACK).
//!
//! From the IBM AT's technical reference and the 8042's published command
//! set. Bytes reach the output buffer one at a time: the controller's own
//! answers first, then the keyboard's (its answers, then the keys queued
//! behind them). A byte enters when the buffer is empty: when time goes
//! on (wantIrq, once a slice) or at once when a program polls the status
//! port. Each byte that enters asks for IRQ 1 when the command byte's bit
//! 0 allows it. The host's keys are set 1 already: with translation on
//! (the BIOS's setting) they pass as they are.

const std = @import("std");

pub const ST_OBF: u8 = 0x01;
pub const ST_IBF: u8 = 0x02;
pub const ST_SYS: u8 = 0x04;
pub const ST_CMD: u8 = 0x08;
pub const ST_UNLOCKED: u8 = 0x10;

/// A byte queue (fixed, no allocation).
fn Queue(comptime N: u8) type {
    return struct {
        const Self = @This();
        b: [N]u8 = undefined,
        head: u8 = 0,
        len: u8 = 0,
        fn put(q: *Self, v: u8) void {
            if (q.len == N) return; // (the keyboard's buffer overflows: lost)
            q.b[(q.head + q.len) % N] = v;
            q.len += 1;
        }
        fn take(q: *Self) ?u8 {
            if (q.len == 0) return null;
            const v = q.b[q.head];
            q.head = (q.head + 1) % N;
            q.len -= 1;
            return v;
        }
        fn clear(q: *Self) void {
            q.len = 0;
        }
    };
}

pub const Keyboard = struct {
    out: u8 = 0,
    obf: bool = false,
    /// The byte in the buffer still has to raise IRQ 1.
    irq_due: bool = false,
    /// The last write was to 0x64 (status bit 3).
    last_cmd: bool = false,
    /// The command byte: IRQ enable (0), system flag (2), keyboard off
    /// (4), translation (6).
    cmd_byte: u8 = 0x45,
    sys: bool = true,
    /// The output port: reset line (0), A20 (1).
    out_port: u8 = 0xDF,
    /// The controller waits for the data byte of this command.
    pending_ctrl: u8 = 0,
    /// The keyboard waits for the argument of this command.
    pending_kbd: u8 = 0,
    kbd_enabled: bool = true,
    leds: u8 = 0,
    typematic: u8 = 0x2B,
    last_sent: u8 = 0,
    /// A program asked for a reset (command FEh or output port bit 0).
    reset_asked: bool = false,
    ctrl_q: Queue(8) = .{},
    resp_q: Queue(8) = .{},
    keys: Queue(32) = .{},

    pub fn reset(self: *Keyboard) void {
        self.* = .{};
    }
    /// The host's key: a set-1 scan code (bit 7 = released; 0xE0 first
    /// for the extended keys).
    pub fn push(self: *Keyboard, code: u8) void {
        if (!self.kbd_enabled) return;
        self.keys.put(code);
    }

    /// The next byte into the empty output buffer.
    fn fill(self: *Keyboard) void {
        if (self.obf) return;
        const v = self.ctrl_q.take() orelse blk: {
            if (self.cmd_byte & 0x10 != 0) return; // interface off
            break :blk self.resp_q.take() orelse self.keys.take() orelse return;
        };
        self.out = v;
        self.obf = true;
        self.irq_due = true;
    }

    /// A byte waits in the output buffer and IRQ 1 should be raised.
    pub fn wantIrq(self: *Keyboard) bool {
        self.fill();
        if (!self.irq_due) return false;
        self.irq_due = false;
        return self.cmd_byte & 0x01 != 0;
    }

    pub fn in8(self: *Keyboard, port: u16) u8 {
        if (port == 0x60) {
            // (read before its IRQ: the line drops, no interrupt)
            self.obf = false;
            self.irq_due = false;
            return self.out;
        }
        self.fill();
        var s: u8 = ST_UNLOCKED;
        if (self.obf) s |= ST_OBF;
        if (self.sys) s |= ST_SYS;
        if (self.last_cmd) s |= ST_CMD;
        return s;
    }

    fn answer(self: *Keyboard, v: u8) void {
        self.ctrl_q.put(v);
        self.fill();
    }
    fn kbdAnswer(self: *Keyboard, v: u8) void {
        self.last_sent = v;
        self.resp_q.put(v);
        self.fill();
    }

    fn a20(self: *const Keyboard) bool {
        return self.out_port & 0x02 != 0;
    }

    /// Returns the A20 gate's new state when a command changed it.
    pub fn out8(self: *Keyboard, port: u16, v: u8) ?bool {
        if (port == 0x64) {
            self.last_cmd = true;
            self.pending_ctrl = 0;
            return self.command(v);
        }
        self.last_cmd = false;
        if (self.pending_ctrl != 0) {
            const c = self.pending_ctrl;
            self.pending_ctrl = 0;
            switch (c) {
                0x60 => {
                    self.cmd_byte = v;
                    self.sys = v & 0x04 != 0;
                },
                0xD1 => {
                    // (bit 0 low would reset the CPU: noted, not done)
                    if (v & 0x01 == 0) self.reset_asked = true;
                    self.out_port = v | 0x01;
                    return self.a20();
                },
                0xD2 => self.answer(v),
                else => {},
            }
            return null;
        }
        self.keyboardCommand(v);
        return null;
    }

    fn command(self: *Keyboard, v: u8) ?bool {
        switch (v) {
            0x20 => self.answer(self.cmd_byte),
            0x60, 0xD1, 0xD2, 0xD3, 0xD4 => self.pending_ctrl = v,
            0xA4 => self.answer(0xF1), // no password
            0xA7 => self.cmd_byte |= 0x20,
            0xA8 => self.cmd_byte &= ~@as(u8, 0x20),
            0xA9 => self.answer(0x00),
            0xAA => {
                self.sys = true;
                self.cmd_byte |= 0x04;
                self.answer(0x55);
            },
            0xAB => self.answer(0x00),
            0xAD => self.cmd_byte |= 0x10,
            0xAE => {
                self.cmd_byte &= ~@as(u8, 0x10);
                self.fill();
            },
            0xC0 => self.answer(0xB0),
            0xD0 => self.answer(self.out_port | (@as(u8, @intFromBool(self.obf)) << 4)),
            0xDD => {
                self.out_port &= ~@as(u8, 0x02);
                return false;
            },
            0xDF => {
                self.out_port |= 0x02;
                return true;
            },
            0xE0 => self.answer(0x00),
            0xF0...0xFF => {
                // Pulse output port bits (low bits clear = pulse): bit 0
                // is the CPU's reset.
                if (v & 0x01 == 0) self.reset_asked = true;
            },
            else => {},
        }
        return null;
    }

    fn keyboardCommand(self: *Keyboard, v: u8) void {
        if (self.pending_kbd != 0) {
            const c = self.pending_kbd;
            self.pending_kbd = 0;
            switch (c) {
                0xED => self.leds = v & 7,
                0xF3 => self.typematic = v & 0x7F,
                0xF0 => if (v == 0) {
                    self.kbdAnswer(0xFA);
                    self.kbdAnswer(if (self.cmd_byte & 0x40 != 0) 0x41 else 0x02);
                    return;
                },
                else => {},
            }
            self.kbdAnswer(0xFA);
            return;
        }
        switch (v) {
            0xED, 0xF3, 0xF0 => {
                self.pending_kbd = v;
                self.kbdAnswer(0xFA);
            },
            0xEE => self.kbdAnswer(0xEE),
            0xF2 => {
                self.kbdAnswer(0xFA);
                self.kbdAnswer(0xAB);
                self.kbdAnswer(if (self.cmd_byte & 0x40 != 0) 0x41 else 0x83);
            },
            0xF4 => {
                self.kbd_enabled = true;
                self.kbdAnswer(0xFA);
            },
            0xF5 => {
                self.kbd_enabled = false;
                self.keys.clear();
                self.kbdAnswer(0xFA);
            },
            0xF6 => {
                self.typematic = 0x2B;
                self.kbdAnswer(0xFA);
            },
            0xF7...0xFD => self.kbdAnswer(0xFA),
            0xFE => self.kbdAnswer(self.last_sent),
            0xFF => {
                self.keys.clear();
                self.kbd_enabled = true;
                self.leds = 0;
                self.kbdAnswer(0xFA);
                self.kbdAnswer(0xAA);
            },
            else => self.kbdAnswer(0xFE),
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "kbd: one IRQ per byte, the status register, the queue" {
    var k: Keyboard = .{};
    try t.expect(!k.wantIrq());
    try t.expectEqual(@as(u8, ST_UNLOCKED | ST_SYS), k.in8(0x64));
    var i: u8 = 0;
    while (i < 20) : (i += 1) k.push(0x10 + i);
    var got: u8 = 0;
    var irqs: u32 = 0;
    var slices: u32 = 0;
    while (slices < 100) : (slices += 1) {
        if (k.wantIrq()) {
            irqs += 1;
            // No second IRQ for the same byte.
            try t.expect(!k.wantIrq());
            try t.expect(k.in8(0x64) & ST_OBF != 0);
            try t.expectEqual(@as(u8, 0x10 + got), k.in8(0x60));
            got += 1;
            try t.expect(k.in8(0x64) & ST_OBF != 0 or got == 20);
        }
    }
    try t.expectEqual(@as(u32, 20), irqs);
    try t.expectEqual(@as(u8, 20), got);
    // Reading 0x60 again gives the last byte.
    try t.expectEqual(@as(u8, 0x23), k.in8(0x60));
}

test "kbd: command byte, self-test, interface test, A20" {
    var k: Keyboard = .{};
    _ = k.out8(0x64, 0x20);
    try t.expect(k.wantIrq());
    try t.expect(k.in8(0x64) & ST_OBF != 0);
    try t.expect(k.in8(0x64) & ST_CMD != 0);
    try t.expectEqual(@as(u8, 0x45), k.in8(0x60));
    // IRQ off in the command byte: bytes come, IRQs do not.
    _ = k.out8(0x64, 0x60);
    _ = k.out8(0x60, 0x44);
    _ = k.out8(0x64, 0x20);
    try t.expect(!k.wantIrq());
    try t.expectEqual(@as(u8, 0x44), k.in8(0x60));
    _ = k.out8(0x64, 0x60);
    _ = k.out8(0x60, 0x45);
    _ = k.out8(0x64, 0xAA);
    try t.expectEqual(@as(u8, 0x55), k.in8(0x60));
    _ = k.out8(0x64, 0xAB);
    try t.expectEqual(@as(u8, 0x00), k.in8(0x60));
    // A20 through the output port, and the fast commands.
    _ = k.out8(0x64, 0xD1);
    try t.expectEqual(@as(?bool, false), k.out8(0x60, 0xDD));
    _ = k.out8(0x64, 0xD0);
    try t.expectEqual(@as(u8, 0), k.in8(0x60) & 0x02);
    _ = k.out8(0x64, 0xD1);
    try t.expectEqual(@as(?bool, true), k.out8(0x60, 0xDF));
    try t.expectEqual(@as(?bool, false), k.out8(0x64, 0xDD));
    try t.expectEqual(@as(?bool, true), k.out8(0x64, 0xDF));
    try t.expect(!k.reset_asked);
    _ = k.out8(0x64, 0xFE);
    try t.expect(k.reset_asked);
    // Disabled interface: keys wait; enabled again, they come.
    _ = k.out8(0x64, 0xAD);
    k.push(0x1E);
    try t.expect(!k.wantIrq());
    _ = k.out8(0x64, 0xAE);
    try t.expect(k.wantIrq());
    try t.expectEqual(@as(u8, 0x1E), k.in8(0x60));
}

test "kbd: keyboard commands answer with ACK" {
    var k: Keyboard = .{};
    k.push(0x1C);
    _ = k.wantIrq();
    try t.expectEqual(@as(u8, 0x1C), k.in8(0x60));
    _ = k.out8(0x60, 0xED);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.out8(0x60, 0x07);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    try t.expectEqual(@as(u8, 7), k.leds);
    _ = k.out8(0x60, 0xF2);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xAB), k.in8(0x60));
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0x41), k.in8(0x60));
    _ = k.out8(0x60, 0xF3);
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.out8(0x60, 0x00);
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.out8(0x60, 0xF4);
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.out8(0x60, 0xFF);
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xAA), k.in8(0x60));
    // F5 stops the keys.
    _ = k.out8(0x60, 0xF5);
    _ = k.in8(0x64);
    try t.expectEqual(@as(u8, 0xFA), k.in8(0x60));
    k.push(0x01);
    try t.expect(k.in8(0x64) & ST_OBF == 0);
}
