//! Polled SAMD21 USB device with fixed SRAM endpoint banks and CDC ACM.
const hw = @import("board.sig");
const cdc = @import("../../core/device/usb_cdc.sig");
const base = 0x41005000;
var descriptors: [256]u8 align(4) = @splat(0);
var buffers: [8][2][64]u8 align(4) = undefined;
fn endpoint(ep: usize) usize {
    return base + 0x100 + ep * 32;
}
fn descriptor(ep: usize, input: bool) usize {
    return @intFromPtr(&descriptors) + ep * 32 + if (input) @as(usize, 16) else 0;
}
fn copyIn(ep: usize, bytes: []const u8) void {
    const p: [*]volatile u8 = @ptrCast(&buffers[ep][1]);
    for (bytes, 0..) |byte, i| p[i] = byte;
}
fn copyOut(ep: usize, bytes: []u8) void {
    const p: [*]volatile u8 = @ptrCast(&buffers[ep][0]);
    for (bytes, 0..) |*byte, i| byte.* = p[i];
}
fn outReady(ep: usize) void {
    hw.write(descriptor(ep, false) + 4, (3 << 28) | (64 << 14));
    hw.write8(endpoint(ep) + 4, 64);
}
fn sendBank(ep: usize, bytes: []const u8) void {
    copyIn(ep, bytes);
    hw.write(descriptor(ep, true) + 4, (3 << 28) | @as(u32, @intCast(bytes.len)));
    asm volatile ("dmb" ::: .{ .memory = true });
    hw.write8(endpoint(ep) + 5, 128);
}
fn banks(ep: usize, config: u8) void {
    hw.write8(endpoint(ep), 0);
    hw.write8(endpoint(ep) + 4, 0xf7);
    hw.write8(endpoint(ep) + 7, 0x7f);
    for (0..2) |bank| {
        const a = @intFromPtr(&descriptors) + ep * 32 + bank * 16;
        hw.write(a, @intCast(@intFromPtr(&buffers[ep][bank])));
        hw.write(a + 4, 3 << 28);
        hw.write(a + 8, 0);
        hw.write(a + 12, 0);
    }
    hw.write8(endpoint(ep), config);
    if (config & 15 != 0) outReady(ep);
}
pub const Usb = struct {
    control: cdc.Control = .{},
    phase: enum { idle, data_in, status_out, ack_in, line_out } = .idle,
    offset: usize = 0,
    zlp: bool = false,
    rx: [256]u8 = undefined,
    head: u16 = 0,
    tail: u16 = 0,
    rx_overflow: bool = false,
    in_busy: bool = false,
    epoch: u32 = 0,
    pub fn init(self: *Usb) void {
        self.* = .{};
        hw.write(0x40000414, hw.read(0x40000414) | 64);
        hw.write(0x4000041c, hw.read(0x4000041c) | 32);
        hw.peripheralClock(6);
        hw.mux(24, 6, false);
        hw.mux(25, 6, false);
        hw.write8(base, 1);
        while (hw.read8(base + 2) & 1 != 0) hw.cycles();
        const fuse = hw.read(0x806024);
        var transn = (fuse >> 13) & 31;
        var transp = (fuse >> 18) & 31;
        var trim = (fuse >> 23) & 7;
        if (transn == 31) transn = 5;
        if (transp == 31) transp = 29;
        if (trim == 7) trim = 3;
        hw.write16(base + 0x28, @intCast(transp | (transn << 6) | (trim << 12)));
        hw.write(base + 0x24, @intCast(@intFromPtr(&descriptors)));
        hw.write16(base + 8, 1);
        hw.write8(base, 2);
        while (hw.read8(base + 2) & 2 != 0) hw.cycles();
        self.reset();
        self.control.product = "SlowWire OpenRB";
        self.control.serialWords(&.{ hw.read(0x0080a00c), hw.read(0x0080a040), hw.read(0x0080a044), hw.read(0x0080a048) });
        hw.write16(base + 8, 0);
    }
    fn reset(self: *Usb) void {
        self.control.reset();
        self.phase = .idle;
        self.in_busy = false;
        self.head = 0;
        self.tail = 0;
        self.rx_overflow = false;
        self.epoch +%= 1;
        hw.write8(base + 0xa, 128);
        banks(0, 0x11);
        for (1..4) |ep| banks(ep, 0);
    }
    fn endpoints(self: *Usb) void {
        self.in_busy = false;
        self.head = 0;
        self.tail = 0;
        banks(1, if (self.control.configured) 0x40 else 0);
        banks(2, if (self.control.configured) 3 else 0);
        banks(3, if (self.control.configured) 0x30 else 0);
    }
    fn stall(self: *Usb) void {
        self.phase = .idle;
        hw.write8(endpoint(0) + 5, 0x30);
        outReady(0);
    }
    fn sendControl(self: *Usb) void {
        const n = @min(64, self.control.len - self.offset);
        sendBank(0, self.control.response[self.offset..][0..n]);
        self.offset += n;
    }
    fn setup(self: *Usb) void {
        var bytes: [8]u8 = undefined;
        copyOut(0, &bytes);
        hw.write8(endpoint(0) + 4, 0xb3);
        hw.write8(endpoint(0) + 5, 3);
        hw.write8(endpoint(0) + 7, 0x7f);
        self.offset = 0;
        outReady(0);
        switch (self.control.setup(cdc.Setup.from(&bytes))) {
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
    }
    fn halt(self: *Usb, index: u8, halted: bool) void {
        const ep: usize = index + 1;
        const input = index != 1;
        const mask: u8 = if (input) 32 else 16;
        hw.write8(endpoint(ep) + 4, if (input) 128 else 64);
        hw.write8(endpoint(ep) + 7, 0x7f);
        if (halted) hw.write8(endpoint(ep) + 5, mask) else {
            hw.write8(endpoint(ep) + 4, mask | if (input) @as(u8, 2) else 1);
            if (!input and self.control.configured) outReady(ep);
        }
        if (input and ep == 3) self.in_busy = false;
    }
    pub fn poll(self: *Usb) void {
        const ints = hw.read16(base + 0x1c);
        if (ints & 8 != 0) {
            hw.write16(base + 0x1c, 8);
            self.reset();
            return;
        }
        // A suspended/disconnected host must disarm even without incoming frames.
        if (ints & 1 != 0) {
            hw.write16(base + 0x1c, 1);
            self.control.dtr = false;
            self.epoch +%= 1;
        }
        if (hw.read8(endpoint(0) + 7) & 16 != 0) {
            self.setup();
            return;
        }
        const done = hw.read8(endpoint(0) + 7);
        if (done & 2 != 0) {
            hw.write8(endpoint(0) + 7, 2);
            switch (self.phase) {
                .ack_in => {
                    const target = self.control.pending_endpoint;
                    const halted = self.control.pending_halt;
                    const config = self.control.pending_config != null;
                    self.control.acknowledged();
                    hw.write8(base + 0xa, @as(u8, self.control.address) | 128);
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
        if (done & 1 != 0) {
            hw.write8(endpoint(0) + 7, 1);
            const n = hw.read(descriptor(0, false) + 4) & 0x3fff;
            if (self.phase == .line_out) {
                if (n != 7) self.stall() else {
                    copyOut(0, &self.control.line);
                    self.phase = .ack_in;
                    sendBank(0, &.{});
                }
            } else self.phase = .idle;
            outReady(0);
        }
        if (hw.read8(endpoint(2) + 7) & 1 != 0) {
            hw.write8(endpoint(2) + 7, 1);
            const n = hw.read(descriptor(2, false) + 4) & 0x3fff;
            if (n > 64) self.rx_overflow = true else {
                var bytes: [64]u8 = undefined;
                copyOut(2, bytes[0..n]);
                for (bytes[0..n]) |byte| {
                    if (self.head -% self.tail >= 256) {
                        self.rx_overflow = true;
                        break;
                    }
                    self.rx[self.head & 255] = byte;
                    self.head +%= 1;
                }
            }
            if (self.control.configured and !self.control.halted[1]) outReady(2);
        }
        if (hw.read8(endpoint(3) + 7) & 2 != 0) {
            hw.write8(endpoint(3) + 7, 2);
            self.in_busy = false;
        }
    }
    pub fn receive(self: *Usb) ?u8 {
        if (self.head == self.tail) return null;
        const byte = self.rx[self.tail & 255];
        self.tail +%= 1;
        return byte;
    }
    pub fn send(self: *Usb, bytes: []const u8) bool {
        if (!self.control.configured or self.control.halted[2] or self.in_busy or bytes.len > 64) return false;
        sendBank(3, bytes);
        self.in_busy = true;
        return true;
    }
};
