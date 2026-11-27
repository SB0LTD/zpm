//! STM32F746 OTG-FS device: polled FIFO CDC ACM, fixed buffers, no DMA/RTOS.
const hw = @import("board.sig");
const cdc = @import("../../core/device/usb_cdc.sig");
const base = 0x50000000;
fn input(ep: usize) usize {
    return base + 0x900 + ep * 32;
}
fn output(ep: usize) usize {
    return base + 0xb00 + ep * 32;
}
fn waitCore(mask: u32, expected: u32) bool {
    const start = hw.millis();
    while (hw.read(base + 0x10) & mask != expected) {
        if (hw.millis() -% start > 100) return false;
    }
    return true;
}
pub fn coreInit(host: bool) hw.Error!void {
    (hw.Pin{ .port = 0, .bit = 11 }).mode(2, 0, 10, false);
    (hw.Pin{ .port = 0, .bit = 12 }).mode(2, 0, 10, false);
    hw.bits(hw.rcc + 0x34, 0, 1 << 7);
    _ = hw.read(hw.rcc + 0x34);
    hw.write(base + 0xc, 1 << 6);
    if (!waitCore(1 << 31, 1 << 31)) return error.Timeout;
    hw.write(base + 0x10, 1);
    if (!waitCore(1, 0)) return error.Timeout;
    hw.delay(3, hw.idle);
    hw.write(base + 8, 0); // slave/FIFO mode, global CPU interrupts disabled.
    hw.write(base + 0x38, 1 << 16); // PHY power; VBUS sensing disabled (PA9 is board SPI2 SCK).
    hw.write(base, if (host) 0 else (1 << 6) | (1 << 7)); // device B-session valid override.
    hw.write(base + 0xc, (1 << 6) | (6 << 10) | if (host) @as(u32, 1 << 29) else 1 << 30);
    hw.delay(50, hw.idle);
    hw.write(base + 0xe00, 0); // ungate PHY clocks
    hw.write(base + 0x10, (1 << 5) | (16 << 6));
    if (!waitCore(1 << 5, 0)) return error.Timeout;
    hw.write(base + 0x10, 1 << 4);
    if (!waitCore(1 << 4, 0)) return error.Timeout;
    hw.write(base + 0x14, 0xffffffff);
    hw.write(base + 0x18, 0);
}
fn outReady(ep: usize) void {
    hw.write(output(ep) + 0x10, (if (ep == 0) @as(u32, 3 << 29) else 0) | (1 << 19) | 64);
    hw.bits(output(ep), 0, (1 << 31) | (1 << 26));
}
fn fifoWrite(ep: usize, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        var word: u32 = 0;
        for (0..@min(4, bytes.len - i)) |j| word |= @as(u32, bytes[i + j]) << @as(u5, @intCast(j * 8));
        hw.write(base + 0x1000 + ep * 0x1000, word);
    }
}
fn sendBank(ep: usize, bytes: []const u8) void {
    hw.write(input(ep) + 0x10, (1 << 19) | @as(u32, @intCast(bytes.len)));
    hw.bits(input(ep), 0, (1 << 31) | (1 << 26));
    fifoWrite(ep, bytes);
}
pub const Usb = struct {
    control: cdc.Control = .{},
    phase: enum { idle, data_in, status_out, ack_in, line_out } = .idle,
    offset: usize = 0,
    zlp: bool = false,
    ep0: [64]u8 = undefined,
    ep0_len: usize = 0,
    setup_pending: bool = false,
    rx: [256]u8 = undefined,
    head: u16 = 0,
    tail: u16 = 0,
    rx_overflow: bool = false,
    in_busy: bool = false,
    epoch: u32 = 0,
    pub fn init(self: *Usb) void {
        self.* = .{};
        coreInit(false) catch {
            hw.power(false);
            while (true) hw.idle();
        };
        hw.write(base + 0x804, 2);
        hw.write(base + 0x800, 3);
        hw.write(base + 0x24, 128);
        hw.write(base + 0x28, (64 << 16) | 128);
        hw.write(base + 0x104, (16 << 16) | 192);
        hw.write(base + 0x108, 0);
        hw.write(base + 0x10c, (64 << 16) | 208);
        hw.write(base + 0x810, 3);
        hw.write(base + 0x814, 9);
        hw.write(base + 0x81c, 0x000f000f);
        self.reset();
        self.control.product = "SlowWire OpenCR";
        self.control.serialWords(&.{ hw.read(0x1ff0f420), hw.read(0x1ff0f424), hw.read(0x1ff0f428) });
        hw.bits(base + 0x804, 2, 0);
    }
    fn reset(self: *Usb) void {
        self.control.reset();
        self.phase = .idle;
        self.in_busy = false;
        self.head = 0;
        self.tail = 0;
        self.rx_overflow = false;
        self.setup_pending = false;
        self.epoch +%= 1;
        hw.bits(base + 0x800, 127 << 4, 0);
        for (0..4) |ep| {
            hw.write(input(ep), 0);
            hw.write(output(ep), 0);
            hw.write(input(ep) + 8, 0xffffffff);
            hw.write(output(ep) + 8, 0xffffffff);
        }
        hw.write(input(0), 1 << 15);
        hw.write(output(0), 1 << 15);
        outReady(0);
    }
    fn endpoints(self: *Usb) void {
        self.in_busy = false;
        self.head = 0;
        self.tail = 0;
        if (!self.control.configured) {
            for (1..4) |ep| {
                hw.bits(input(ep), 1 << 15, 1 << 27);
                hw.bits(output(ep), 1 << 15, 1 << 27);
            }
            return;
        }
        hw.write(input(1), 8 | (1 << 15) | (3 << 18) | (1 << 22) | (1 << 28));
        hw.write(output(2), 64 | (1 << 15) | (2 << 18) | (1 << 28));
        hw.write(input(3), 64 | (1 << 15) | (2 << 18) | (3 << 22) | (1 << 28));
        outReady(2);
    }
    fn stall(self: *Usb) void {
        self.phase = .idle;
        hw.bits(input(0), 0, 1 << 21);
        hw.bits(output(0), 0, 1 << 21);
        outReady(0);
    }
    fn sendControl(self: *Usb) void {
        const n = @min(64, self.control.len - self.offset);
        sendBank(0, self.control.response[self.offset..][0..n]);
        self.offset += n;
    }
    fn setup(self: *Usb) void {
        if (self.ep0_len != 8) {
            self.stall();
            return;
        }
        self.setup_pending = false;
        self.offset = 0;
        hw.write(input(0) + 8, 0xffffffff); // Discard completion from the aborted control transfer.
        hw.bits(input(0), 1 << 21, 0);
        hw.bits(output(0), 1 << 21, 0);
        switch (self.control.setup(cdc.Setup.from(self.ep0[0..8]))) {
            .stall => self.stall(),
            .ack => {
                self.phase = .ack_in;
                sendBank(0, &.{});
            },
            .line_out => {
                self.phase = .line_out;
                outReady(0);
            },
            .data => {
                self.phase = .data_in;
                self.zlp = self.control.len < self.control.requested and self.control.len % 64 == 0;
                self.sendControl();
            },
        }
        outReady(0);
    }
    fn halt(self: *Usb, index: u8, halted: bool) void {
        const ep: usize = index + 1;
        const is_input = index != 1;
        const a = if (is_input) input(ep) else output(ep);
        if (hw.read(a) & (1 << 31) != 0) {
            if (!is_input) {
                hw.bits(base + 0x804, 0, 1 << 9);
                hw.wait(base + 0x804, 8, 8, hw.millis(), 10, hw.idle) catch {
                    self.control.configured = false;
                    self.epoch +%= 1;
                    return;
                };
            }
            hw.bits(a, 0, (1 << 27) | (1 << 30));
            hw.wait(a + 8, 2, 2, hw.millis(), 10, hw.idle) catch {
                self.control.configured = false;
                self.epoch +%= 1;
                return;
            };
            hw.write(a + 8, 2);
            if (!is_input) hw.bits(base + 0x804, 0, 1 << 10);
        }
        hw.bits(a, 1 << 21, if (halted) @as(u32, 1 << 21) else 1 << 28);
        if (is_input) {
            hw.write(base + 0x10, (1 << 5) | (@as(u32, @intCast(ep)) << 6));
            if (!waitCore(1 << 5, 0)) {
                self.control.configured = false;
                self.epoch +%= 1;
            }
            if (ep == 3) self.in_busy = false;
        } else if (!halted and self.control.configured) outReady(ep);
    }
    fn drain(self: *Usb) void {
        while (hw.read(base + 0x14) & 16 != 0) {
            const status = hw.read(base + 0x20);
            const ep = status & 15;
            const n = (status >> 4) & 2047;
            const kind = (status >> 17) & 15;
            var bytes: [64]u8 = undefined;
            var i: usize = 0;
            while (i < n) : (i += 4) {
                const word = hw.read(base + 0x1000);
                for (0..@min(4, n - i)) |j| if (i + j < 64) {
                    bytes[i + j] = @truncate(word >> @as(u5, @intCast(j * 8)));
                };
            }
            if (n > 64) {
                self.rx_overflow = true;
                continue;
            }
            if (ep == 0 and (kind == 6 or kind == 2)) {
                @memcpy(self.ep0[0..n], bytes[0..n]);
                self.ep0_len = n;
                if (kind == 6) self.setup_pending = true;
            } else if (ep == 2 and kind == 2) for (bytes[0..n]) |byte| {
                if (self.head -% self.tail >= 256) {
                    self.rx_overflow = true;
                    break;
                }
                self.rx[self.head & 255] = byte;
                self.head +%= 1;
            };
        }
    }
    pub fn poll(self: *Usb) void {
        const flags = hw.read(base + 0x14);
        if (flags & (1 << 12) != 0) {
            hw.write(base + 0x14, 1 << 12);
            self.reset();
            return;
        }
        if (flags & (1 << 13) != 0) {
            hw.write(base + 0x14, 1 << 13);
            outReady(0);
        }
        if (flags & (1 << 11) != 0) {
            hw.write(base + 0x14, 1 << 11);
            self.control.dtr = false;
            self.epoch +%= 1;
        }
        if (flags & (1 << 31) != 0) hw.write(base + 0x14, 1 << 31);
        self.drain();
        const out = hw.read(output(0) + 8);
        if (out & 8 != 0) {
            hw.write(output(0) + 8, 9);
            if (self.setup_pending) self.setup();
            return;
        }
        if (out & 1 != 0) {
            hw.write(output(0) + 8, 1);
            if (self.phase == .line_out) {
                if (self.ep0_len != 7) self.stall() else {
                    @memcpy(&self.control.line, self.ep0[0..7]);
                    self.phase = .ack_in;
                    sendBank(0, &.{});
                }
            } else if (self.phase == .status_out) self.phase = .idle;
            outReady(0);
        }
        if (hw.read(input(0) + 8) & 1 != 0) {
            hw.write(input(0) + 8, 1);
            switch (self.phase) {
                .ack_in => {
                    const target = self.control.pending_endpoint;
                    const halted = self.control.pending_halt;
                    const config = self.control.pending_config != null;
                    self.control.acknowledged();
                    hw.bits(base + 0x800, 127 << 4, @as(u32, self.control.address) << 4);
                    if (config) {
                        self.endpoints();
                        self.epoch +%= 1;
                    }
                    if (target) |index| self.halt(index, halted);
                    self.phase = .idle;
                    outReady(0);
                },
                .data_in => {
                    if (self.offset < self.control.len) self.sendControl() else if (self.zlp) {
                        self.zlp = false;
                        sendBank(0, &.{});
                    } else {
                        self.phase = .status_out;
                        outReady(0);
                    }
                },
                else => {},
            }
        }
        if (hw.read(output(2) + 8) & 1 != 0) {
            hw.write(output(2) + 8, 1);
            if (self.control.configured and !self.control.halted[1]) outReady(2);
        }
        if (hw.read(input(3) + 8) & 1 != 0) {
            hw.write(input(3) + 8, 1);
            self.in_busy = false;
        }
    }
    pub fn receive(self: *Usb) ?u8 {
        if (self.head == self.tail) return null;
        const b = self.rx[self.tail & 255];
        self.tail +%= 1;
        return b;
    }
    pub fn send(self: *Usb, bytes: []const u8) bool {
        if (!self.control.configured or self.control.halted[2] or self.in_busy or bytes.len > 64) return false;
        sendBank(3, bytes);
        self.in_busy = true;
        return true;
    }
};
