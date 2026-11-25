//! Hyper-V's synthetic mouse: the pointer of a generation 2 machine. It is
//! a HID device carried over VMBus: after a handshake the host sends the
//! device's HID descriptors once, the guest acknowledges them, and input
//! reports follow. The pointer is absolute (the host's cursor position over
//! the machine's screen, 0 to 32767 each way), with five buttons and a
//! wheel.
//!
//! Zero allocation, freestanding; over an open VMBus channel (vmbus.sig).
//! Every message sits in a "pipe" header (a type and a size), as Linux's
//! hid-hyperv documents (documentation only).

const vmbus = @import("vmbus.sig");
const put32 = vmbus.put32;
const get32 = vmbus.get32;

/// The pipe header's type for data, then the messages inside it.
const PIPE_DATA: u32 = 1;
const PROTOCOL_REQUEST: u32 = 0;
const PROTOCOL_RESPONSE: u32 = 1;
const DEVICE_INFO: u32 = 2;
const DEVICE_INFO_ACK: u32 = 3;
const INPUT_REPORT: u32 = 4;
const VERSION: u32 = 0x0002_0000;

pub const SEND_PAGES = 2;
pub const RECEIVE_PAGES = 3;

/// The pointer as one report gives it.
pub const Report = struct {
    /// Bit 0: left, 1: right, 2: middle, 3 and 4: the side buttons.
    buttons: u8,
    /// 0 to 32767 across the screen, and down it.
    x: u16,
    y: u16,
    /// Notches turned since the last report (up is positive).
    wheel: i8,
};

pub fn Mouse(comptime Host: type) type {
    return struct {
        const Self = @This();

        ch: vmbus.Channel(Host),
        accepted: bool = false,
        refused: bool = false,
        /// The device's descriptors arrived and were acknowledged: reports
        /// follow. The report descriptor's length, for the log.
        described: bool = false,
        report_descriptor_bytes: u16 = 0,
        /// The last report as it came (its first 8 bytes, and its length).
        raw: [8]u8 = [_]u8{0} ** 8,
        raw_len: u32 = 0,

        /// The handshake's request. False when the channel's ring is full.
        pub fn start(self: *Self) bool {
            var m: [20]u8 = undefined;
            put32(&m, 0, PIPE_DATA);
            put32(&m, 4, 12);
            put32(&m, 8, PROTOCOL_REQUEST);
            put32(&m, 12, 4);
            put32(&m, 16, VERSION);
            return self.ch.send(&m, true) != null;
        }

        fn acknowledge(self: *Self) void {
            var m = [_]u8{0} ** 17;
            put32(&m, 0, PIPE_DATA);
            put32(&m, 4, 9);
            put32(&m, 8, DEVICE_INFO_ACK);
            put32(&m, 12, 1);
            _ = self.ch.send(&m, true);
        }

        /// The next pointer report, or null when the host has sent none.
        /// (The handshake's answer and the descriptors are taken on the way.)
        pub fn poll(self: *Self) ?Report {
            var buf: [512]u8 = undefined;
            while (self.ch.receive(&buf)) |p| {
                if (p.kind != vmbus.pkt.DATA_INBAND or p.body.len < 16) continue;
                if (get32(p.body, 0) != PIPE_DATA) continue;
                const m = p.body[8..];
                const size: usize = get32(m, 4);
                switch (get32(m, 0)) {
                    PROTOCOL_RESPONSE => {
                        if (m.len < 13) continue;
                        self.accepted = m[12] != 0;
                        self.refused = !self.accepted;
                    },
                    DEVICE_INFO => {
                        // (the device's ids, its HID descriptor, then its
                        // report descriptor, whose length the HID
                        // descriptor's last two bytes give)
                        if (m.len >= 8 + 32 + 9) self.report_descriptor_bytes = vmbus.get16(m, 8 + 32 + 7);
                        self.described = true;
                        self.acknowledge();
                    },
                    INPUT_REPORT => {
                        const r = m[8..];
                        self.raw_len = @intCast(@min(size, r.len));
                        @memset(&self.raw, 0);
                        @memcpy(self.raw[0..@min(r.len, 8)], r[0..@min(r.len, 8)]);
                        if (size < 5 or r.len < 5) continue;
                        return .{
                            .buttons = r[0] & 0x1F,
                            .x = @min(vmbus.get16(r, 1), 32767),
                            .y = @min(vmbus.get16(r, 3), 32767),
                            .wheel = if (size >= 6 and r.len >= 6) @bitCast(r[5]) else 0,
                        };
                    },
                    else => {},
                }
            }
            return null;
        }
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Tests
// ══════════════════════════════════════════════════════════════════════════════

const TestHost = vmbus.testing.Host;
const fromHost = vmbus.testing.fromHost;

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

/// A message in its pipe header.
fn piped(comptime n: usize, kind: u32, body: [n]u8) [16 + n]u8 {
    var m: [16 + n]u8 = undefined;
    put32(&m, 0, PIPE_DATA);
    put32(&m, 4, 8 + n);
    put32(&m, 8, kind);
    put32(&m, 12, n);
    @memcpy(m[16..], &body);
    return m;
}

test "mouse: the handshake, the descriptors, then reports" {
    var host: TestHost = .{};
    var mem: [5 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var mouse: Mouse(TestHost) = .{ .ch = vmbus.testing.channel(TestHost, &host, &mem, SEND_PAGES) };
    try expect(mouse.start());
    var buf: [128]u8 = undefined;
    var n = mouse.ch.out.read(&buf) orelse return error.TestUnexpectedResult;
    try expect(n == 16 + 24 and get32(&buf, 16) == PIPE_DATA and get32(&buf, 20) == 12);
    try expect(get32(&buf, 24) == PROTOCOL_REQUEST and get32(&buf, 28) == 4 and get32(&buf, 32) == VERSION);

    // Accepted; then the device's information: 32 bytes of ids, a 9-byte
    // HID descriptor naming a 67-byte report descriptor.
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 1, &piped(5, PROTOCOL_RESPONSE, .{ 0, 0, 2, 0, 1 })));
    var info = [_]u8{0} ** (32 + 9 + 67);
    info[32 + 7] = 67;
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 2, &piped(info.len, DEVICE_INFO, info)));
    try expect(mouse.poll() == null);
    try expect(mouse.accepted and mouse.described and mouse.report_descriptor_bytes == 67);
    // The acknowledgement went back: a 9-byte message of type 3.
    n = mouse.ch.out.read(&buf) orelse return error.TestUnexpectedResult;
    try expect(n == 16 + 24 and get32(&buf, 20) == 9 and get32(&buf, 24) == DEVICE_INFO_ACK and get32(&buf, 28) == 1);

    // The pointer in the middle with the left button down, then a notch
    // of the wheel down at the far corner.
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 3, &piped(6, INPUT_REPORT, .{ 0x01, 0x00, 0x40, 0x00, 0x40, 0x00 })));
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 4, &piped(6, INPUT_REPORT, .{ 0x00, 0xFF, 0x7F, 0xFF, 0x7F, 0xFF })));
    const a = mouse.poll() orelse return error.TestUnexpectedResult;
    try expect(a.buttons == 1 and a.x == 0x4000 and a.y == 0x4000 and a.wheel == 0);
    const b = mouse.poll().?;
    try expect(b.buttons == 0 and b.x == 32767 and b.y == 32767 and b.wheel == -1);
    try expect(mouse.poll() == null);
}

test "mouse: a refusal, and what is not a report" {
    var host: TestHost = .{};
    var mem: [5 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var mouse: Mouse(TestHost) = .{ .ch = vmbus.testing.channel(TestHost, &host, &mem, SEND_PAGES) };
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 1, &piped(5, PROTOCOL_RESPONSE, .{ 0, 0, 2, 0, 0 })));
    try expect(fromHost(mouse.ch.in, vmbus.pkt.COMPLETION, 2, &[_]u8{0} ** 8));
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 3, &piped(2, INPUT_REPORT, .{ 1, 2 }))); // (too short)
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 4, &piped(4, 99, .{ 0, 0, 0, 0 })));
    try expect(mouse.poll() == null);
    try expect(mouse.refused and !mouse.accepted and !mouse.described);
    // A five-byte report (no wheel) still moves the pointer.
    try expect(fromHost(mouse.ch.in, vmbus.pkt.DATA_INBAND, 5, &piped(5, INPUT_REPORT, .{ 0x02, 0x10, 0x00, 0x20, 0x00 })));
    const r = mouse.poll() orelse return error.TestUnexpectedResult;
    try expect(r.buttons == 2 and r.x == 16 and r.y == 32 and r.wheel == 0);
}
