//! Polled RP2040 USB full-speed device, CDC ACM, single buffered endpoints.
const hw = @import("board.sig");
const cdc = @import("../../core/device/usb_cdc.sig");
const base = 0x50110000;
const ram = 0x50100000;
pub const Usb = struct {
    control: cdc.Control = .{},
    phase: enum { idle, data_in, status_out, ack_in, line_out } = .idle,
    offset: usize = 0,
    zlp: bool = false,
    ep0_pid: bool = true,
    out_pid: bool = false,
    in_pid: bool = false,
    rx: [256]u8 = undefined,
    head: u16 = 0,
    tail: u16 = 0,
    rx_overflow: bool = false,
    in_busy: bool = false,
    epoch: u32 = 0,
    fn writeBytes(offset: usize, bytes: []const u8) void {
        const dest: [*]volatile u8 = @ptrFromInt(ram + offset);
        for (bytes, 0..) |b, i| dest[i] = b;
    }
    fn readBytes(offset: usize, bytes: []u8) void {
        const src: [*]volatile u8 = @ptrFromInt(ram + offset);
        for (bytes, 0..) |*b, i| b.* = src[i];
    }
    fn buffer(ep: usize, input: bool) usize {
        return ram + 0x80 + ep * 8 + if (input) @as(usize, 0) else 4;
    }
    fn arm(ep: usize, input: bool, pid: bool, len: usize) void {
        const ctrl = buffer(ep, input);
        const value = @as(u32, @intCast(len)) | (if (pid) @as(u32, 1 << 13) else 0) | (if (input) @as(u32, 1 << 15) else 0);
        hw.write(ctrl, value);
        hw.cycles();
        hw.write(ctrl, value | (1 << 10));
    }
    pub fn init(self: *Usb) void {
        // B2 required: E5 enumeration is fixed in silicon; older revisions need a GPIO15 workaround.
        if (hw.read(0x40000000) >> 28 < 2) {
            hw.gpioSet(25, false);
            while (true) hw.cycles();
        }
        self.* = .{};
        hw.clear(0x4000c000, 1 << 24);
        var i: usize = 0;
        while (i < 4096) : (i += 4) hw.write(ram + i, 0);
        hw.write(base + 0x74, 9);
        hw.write(base + 0x78, 12);
        hw.write(base + 0x40, 1);
        hw.write(base + 0x4c, (1 << 29));
        hw.write(base + 0x90, (1 << 16) | (1 << 12) | (1 << 4));
        hw.set(base + 0x4c, 1 << 16);
    }
    fn endpoints(self: *Usb) void {
        self.in_busy = false;
        self.in_pid = false;
        self.out_pid = false;
        self.head = 0;
        self.tail = 0;
        self.rx_overflow = false;
        hw.write(ram + 8, (1 << 31) | (1 << 29) | (3 << 26) | 0x180);
        hw.write(ram + 20, (1 << 31) | (1 << 29) | (2 << 26) | 0x1c0);
        hw.write(ram + 24, (1 << 31) | (1 << 29) | (2 << 26) | 0x200);
        hw.write(buffer(3, true), 0);
        arm(2, false, false, 64);
    }
    fn sendControl(self: *Usb) void {
        const n = @min(64, self.control.len - self.offset);
        writeBytes(0x100, self.control.response[self.offset..][0..n]);
        arm(0, true, self.ep0_pid, n);
        self.ep0_pid = !self.ep0_pid;
        self.offset += n;
    }
    fn stall(self: *Usb) void {
        self.phase = .idle;
        hw.write(base + 0x68, 3);
        hw.write(buffer(0, true), 1 << 11);
        hw.write(buffer(0, false), 1 << 11);
    }
    fn setup(self: *Usb) void {
        var bytes: [8]u8 = undefined;
        readBytes(0, &bytes);
        // New SETUP aborts the previous transfer and always restarts DATA1.
        hw.write(buffer(0, true), 0);
        hw.write(buffer(0, false), 0);
        hw.write(base + 0x68, 0);
        hw.write(base + 0x58, 3);
        self.ep0_pid = true;
        self.offset = 0;
        switch (self.control.setup(cdc.Setup.from(&bytes))) {
            .stall => self.stall(),
            .ack => {
                self.phase = .ack_in;
                arm(0, true, true, 0);
            },
            .line_out => {
                self.phase = .line_out;
                arm(0, false, true, 7);
            },
            .data => {
                self.phase = .data_in;
                self.zlp = self.control.len < self.control.requested and self.control.len % 64 == 0;
                self.sendControl();
            },
        }
    }
    pub fn poll(self: *Usb) void {
        const ints = hw.read(base + 0x98);
        if (ints & (1 << 12) != 0) {
            hw.write(base + 0x50, 1 << 19);
            hw.write(base, 0);
            self.control.reset();
            self.phase = .idle;
            self.epoch +%= 1;
            self.in_busy = false;
            self.head = 0;
            self.tail = 0;
            var i: usize = 8;
            while (i <= 28) : (i += 4) hw.write(ram + i, 0);
            i = 0x80;
            while (i <= 0x9c) : (i += 4) hw.write(ram + i, 0);
            hw.write(base + 0x58, 0xffffffff);
            return;
        }
        if (ints & (1 << 16) != 0) {
            hw.write(base + 0x50, 1 << 17);
            self.setup();
        }
        const done = hw.read(base + 0x58);
        if (done & 1 != 0) {
            hw.write(base + 0x58, 1);
            switch (self.phase) {
                .ack_in => {
                    const endpoint = self.control.pending_endpoint;
                    const halted = self.control.pending_halt;
                    const reconfigure = self.control.pending_config != null;
                    self.control.acknowledged();
                    hw.write(base, self.control.address);
                    if (reconfigure) {
                        self.epoch +%= 1;
                        if (self.control.configured) self.endpoints() else {
                            hw.write(ram + 8, 0);
                            hw.write(ram + 20, 0);
                            hw.write(ram + 24, 0);
                        }
                    }
                    if (endpoint) |ep| self.endpointHalt(ep, halted);
                    self.phase = .idle;
                },
                .data_in => {
                    if (self.offset < self.control.len) self.sendControl() else if (self.zlp) {
                        self.zlp = false;
                        arm(0, true, self.ep0_pid, 0);
                    } else {
                        self.phase = .status_out;
                        arm(0, false, true, 0);
                    }
                },
                else => {},
            }
        }
        if (done & 2 != 0) {
            hw.write(base + 0x58, 2);
            const n = hw.read(buffer(0, false)) & 0x3ff;
            if (self.phase == .line_out) {
                if (n != 7) {
                    self.stall();
                } else {
                    readBytes(0x100, &self.control.line);
                    self.phase = .ack_in;
                    arm(0, true, true, 0);
                }
            } else self.phase = .idle;
        }
        if (done & (1 << 5) != 0) {
            hw.write(base + 0x58, 1 << 5);
            const n = hw.read(buffer(2, false)) & 0x3ff;
            if (n > 64) {
                self.rx_overflow = true;
            } else {
                var bytes: [64]u8 = undefined;
                readBytes(0x1c0, bytes[0..n]);
                for (bytes[0..n]) |b| {
                    if (self.head -% self.tail >= 256) {
                        self.rx_overflow = true;
                        break;
                    }
                    self.rx[self.head & 255] = b;
                    self.head +%= 1;
                }
            }
            self.out_pid = !self.out_pid;
            if (self.control.configured) arm(2, false, self.out_pid, 64);
        }
        if (done & (1 << 6) != 0) {
            hw.write(base + 0x58, 1 << 6);
            self.in_busy = false;
        }
    }
    fn endpointHalt(self: *Usb, index: u8, halted: bool) void {
        const ep: usize = switch (index) {
            0 => 1,
            1 => 2,
            else => 3,
        };
        const input = index != 1;
        const bit = @as(u32, 1) << @as(u5, @intCast(ep * 2 + if (input) @as(usize, 0) else 1));
        hw.set(base + 0x60, bit);
        const start = hw.micros();
        while (hw.read(base + 0x64) & bit == 0) {
            if (hw.micros() -% start > 1000) {
                self.control.configured = false;
                self.epoch +%= 1;
                break;
            }
        }
        hw.write(buffer(ep, input), if (halted) @as(u32, 1 << 11) else 0);
        hw.clear(base + 0x60, bit);
        hw.write(base + 0x64, bit);
        hw.write(base + 0x58, bit);
        if (index == 2) {
            self.in_busy = false;
            self.in_pid = false;
        }
        if (index == 1) {
            self.out_pid = false;
            if (!halted and self.control.configured) arm(2, false, false, 64);
        }
    }
    pub fn receive(self: *Usb) ?u8 {
        if (self.head == self.tail) return null;
        const byte = self.rx[self.tail & 255];
        self.tail +%= 1;
        return byte;
    }
    // RP2040-E15: keep this prototype bulk-IN packet below the affected size.
    pub fn send(self: *Usb, bytes: []const u8) bool {
        if (!self.control.configured or self.control.halted[2] or self.in_busy or bytes.len > 48) return false;
        writeBytes(0x200, bytes);
        arm(3, true, self.in_pid, bytes.len);
        self.in_pid = !self.in_pid;
        self.in_busy = true;
        return true;
    }
};
