//! OTG-FS host primitives for one directly connected FS/LS device. No hubs/classes/DMA.
//! Mutually exclusive with CDC device mode. Requires verified external USB VBUS wiring.
const hw = @import("board.sig");
const device = @import("usb_device.sig");
const t = @import("../../core/sig_testing.sig");
const base = 0x50000000;
pub const Endpoint = struct { address: u7, number: u4, input: bool, max_packet: u7, kind: enum(u2) { control = 0, isochronous = 1, bulk = 2, interrupt = 3 } };
pub fn validate(ep: Endpoint, low_speed: bool) hw.Error!void {
    if (ep.max_packet == 0 or ep.max_packet > 64 or ep.kind == .isochronous) return error.Range;
    if (low_speed and (ep.max_packet > 8 or ep.kind == .bulk)) return error.Unsupported;
}
fn port(set: u32, clear: u32) void {
    hw.write(base + 0x440, (hw.read(base + 0x440) & ~@as(u32, 0x2e) & ~clear) | set);
}
pub const Host = struct {
    poll: hw.Poll,
    address: u7 = 0,
    packet: u7 = 8,
    low_speed: bool = false,
    pub fn init(poll: hw.Poll) hw.Error!Host {
        try device.coreInit(true);
        hw.write(base + 0x24, 128);
        hw.write(base + 0x28, (128 << 16) | 128);
        hw.write(base + 0x100, (64 << 16) | 256);
        hw.write(base + 0x400, 1);
        hw.write(base + 0x404, 48000);
        hw.write(base + 0x500, 0);
        hw.write(base + 0x508, 0xffffffff);
        port(1 << 12, 0);
        return .{ .poll = poll };
    }
    pub fn resetPort(self: *Host) hw.Error!void {
        try hw.wait(base + 0x440, 1, 1, hw.millis(), 3000, self.poll);
        if (hw.read(base + 0x440) & 16 != 0) return error.Transport;
        port(1 << 8, 0);
        hw.delay(50, self.poll);
        port(0, 1 << 8);
        hw.delay(20, self.poll);
        if (hw.read(base + 0x440) & 4 == 0) return error.Transport;
        const speed = (hw.read(base + 0x440) >> 17) & 3;
        if (speed != 1 and speed != 2) return error.Unsupported;
        self.low_speed = speed == 2;
        hw.write(base + 0x400, if (self.low_speed) 2 else 1);
        hw.write(base + 0x404, if (self.low_speed) 6000 else 48000);
        self.address = 0;
        self.packet = 8;
    }
    /// One packet. pid: 0=DATA0, 2=DATA1, 3=SETUP. NAKs retried to deadline.
    pub fn packetTransfer(self: *Host, ep: Endpoint, pid: u2, tx: []const u8, rx: []u8, timeout_ms: u32) hw.Error!usize {
        try validate(ep, self.low_speed);
        if (timeout_ms == 0 or tx.len > ep.max_packet or rx.len > ep.max_packet or (ep.input and tx.len != 0) or (!ep.input and rx.len != 0)) return error.Range;
        const start = hw.millis();
        while (hw.millis() -% start < timeout_ms) {
            if (hw.read(base + 0x440) & 1 == 0 or hw.read(base + 0x440) & 16 != 0) return error.Transport;
            hw.write(base + 0x508, 0x7ff);
            hw.write(base + 0x50c, 0x7ff);
            hw.write(base + 0x510, (1 << 19) | (@as(u32, pid) << 29) | if (ep.input) @as(u32, ep.max_packet) else @as(u32, @intCast(tx.len)));
            hw.write(base + 0x500, @as(u32, ep.max_packet) | (@as(u32, ep.number) << 11) | (if (ep.input) @as(u32, 1 << 15) else 0) | (if (self.low_speed) @as(u32, 1 << 17) else 0) | (@as(u32, @backingInt(ep.kind)) << 18) | (@as(u32, ep.address) << 22) | (((hw.read(base + 0x408) + 1) & 1) << 29) | (1 << 31));
            if (!ep.input) {
                var i: usize = 0;
                while (i < tx.len) : (i += 4) {
                    var word: u32 = 0;
                    for (0..@min(4, tx.len - i)) |j| word |= @as(u32, tx[i + j]) << @as(u5, @intCast(j * 8));
                    hw.write(base + 0x1000, word);
                }
            }
            var received: usize = 0;
            var oversized = false;
            while (true) {
                while (hw.read(base + 0x14) & 16 != 0) {
                    const status = hw.read(base + 0x20);
                    const n = (status >> 4) & 2047;
                    const kind = (status >> 17) & 15;
                    var i: usize = 0;
                    while (i < n) : (i += 4) {
                        const word = hw.read(base + 0x1000);
                        for (0..@min(4, n - i)) |j| if (kind == 2) {
                            if (received < rx.len) rx[received] = @truncate(word >> @as(u5, @intCast(j * 8))) else oversized = true;
                            received += 1;
                        };
                    }
                }
                const flags = hw.read(base + 0x508);
                if (flags & 8 != 0) return error.Nack; // endpoint STALL
                if (flags & 0x784 != 0) return error.Transport;
                if (flags & 1 != 0) {
                    if (oversized) return error.Overflow;
                    return if (ep.input) received else tx.len;
                }
                if (flags & 16 != 0) {
                    if (flags & 2 == 0) {
                        hw.bits(base + 0x500, 0, (1 << 30) | (1 << 31));
                        try hw.wait(base + 0x508, 2, 2, hw.millis(), 10, self.poll);
                    }
                    break;
                }
                self.poll();
                if (hw.millis() -% start >= timeout_ms) {
                    hw.bits(base + 0x500, 0, (1 << 30) | (1 << 31));
                    hw.wait(base + 0x508, 2, 2, hw.millis(), 10, hw.idle) catch {};
                    return error.Timeout;
                }
            }
            if (!ep.input) {
                hw.write(base + 0x10, 1 << 5);
                try hw.wait(base + 0x10, 1 << 5, 0, hw.millis(), 10, self.poll);
            }
            hw.delay(1, self.poll);
        }
        return error.Timeout;
    }
    pub fn control(self: *Host, setup: *const [8]u8, tx: []const u8, rx: []u8) hw.Error!usize {
        const input_direction = setup[0] & 128 != 0;
        const length = @as(u16, setup[6]) | (@as(u16, setup[7]) << 8);
        if (length > 256 or (input_direction and (tx.len != 0 or rx.len != length)) or (!input_direction and (rx.len != 0 or tx.len != length))) return error.Range;
        var ep: Endpoint = .{ .address = self.address, .number = 0, .input = false, .max_packet = self.packet, .kind = .control };
        _ = try self.packetTransfer(ep, 3, setup, &.{}, 500);
        var offset: usize = 0;
        var pid: u2 = 2;
        while (offset < length) {
            const n = @min(self.packet, length - offset);
            ep.input = input_direction;
            const got = try self.packetTransfer(ep, pid, if (input_direction) &.{} else tx[offset..][0..n], if (input_direction) rx[offset..][0..n] else &.{}, 500);
            offset += got;
            pid = if (pid == 2) 0 else 2;
            if (got < n) break;
        }
        ep.input = !input_direction;
        _ = try self.packetTransfer(ep, 2, &.{}, &.{}, 500);
        return offset;
    }
    pub fn enumerate(self: *Host, descriptor: *[18]u8) hw.Error!void {
        try self.resetPort();
        var first: [8]u8 = undefined;
        if (try self.control(&.{ 128, 6, 0, 1, 0, 0, 8, 0 }, &.{}, &first) != 8) return error.Transport;
        const max_packet = first[7];
        if (max_packet != 8 and max_packet != 16 and max_packet != 32 and max_packet != 64) return error.Range;
        self.packet = @intCast(max_packet);
        if (try self.control(&.{ 128, 6, 0, 1, 0, 0, 18, 0 }, &.{}, descriptor) != 18) return error.Transport;
        _ = try self.control(&.{ 0, 5, 1, 0, 0, 0, 0, 0 }, &.{}, &.{});
        self.address = 1;
        hw.delay(2, self.poll);
    }
};
test "USB host endpoints reject impossible packet sizes and low-speed bulk" {
    try validate(.{ .address = 1, .number = 0, .input = true, .max_packet = 8, .kind = .control }, true);
    try t.expectError(error.Unsupported, validate(.{ .address = 1, .number = 1, .input = true, .max_packet = 8, .kind = .bulk }, true));
    try t.expectError(error.Range, validate(.{ .address = 1, .number = 1, .input = true, .max_packet = 0, .kind = .interrupt }, false));
}
