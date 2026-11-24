//! Hyper-V's synthetic keyboard: the only keyboard a generation 2 machine
//! has. After a one-message handshake the host sends one packet a key
//! event: a scancode set 1 make code, with flags for the E0 and E1
//! prefixes and for a release, as a PS/2 keyboard's controller would hand
//! them over.
//!
//! Zero allocation, freestanding; over an open VMBus channel (vmbus.sig).

const vmbus = @import("vmbus.sig");

/// The handshake and the event, as the host's keyboard device speaks them.
const PROTOCOL_REQUEST: u32 = 1;
const PROTOCOL_RESPONSE: u32 = 2;
const EVENT: u32 = 3;
const VERSION: u32 = 0x0001_0000;

const INFO_UNICODE: u32 = 1;
const INFO_BREAK: u32 = 2;
const INFO_E0: u32 = 4;
const INFO_E1: u32 = 8;

/// Ring sizes that hold a burst of keys (a header page and data, each way).
pub const SEND_PAGES = 2;
pub const RECEIVE_PAGES = 3;

pub const Key = struct {
    /// Scancode set 1, without the release bit.
    make: u8,
    /// The key's code came with the E0 prefix (arrows, right-hand
    /// modifiers), or E1 (Pause).
    e0: bool,
    e1: bool,
    /// Released, not pressed.
    up: bool,
};

pub fn Keyboard(comptime Host: type) type {
    return struct {
        const Self = @This();

        ch: vmbus.Channel(Host),
        /// The host accepted the protocol version: key events follow.
        accepted: bool = false,
        refused: bool = false,

        /// The handshake's request. False when the channel's ring is full.
        pub fn start(self: *Self) bool {
            var m: [8]u8 = undefined;
            put32(&m, 0, PROTOCOL_REQUEST);
            put32(&m, 4, VERSION);
            return self.ch.send(&m, true) != null;
        }

        /// The next key event, or null when the host has sent none. (The
        /// handshake's answer and anything else are taken on the way.)
        pub fn poll(self: *Self) ?Key {
            var buf: [256]u8 = undefined;
            while (self.ch.receive(&buf)) |p| {
                if (p.kind != vmbus.pkt.DATA_INBAND or p.body.len < 8) continue;
                switch (vmbus.get32(p.body, 0)) {
                    PROTOCOL_RESPONSE => {
                        self.accepted = vmbus.get32(p.body, 4) & 1 != 0;
                        self.refused = !self.accepted;
                    },
                    EVENT => {
                        if (p.body.len < 12) continue;
                        const info = vmbus.get32(p.body, 8);
                        // (a Unicode character instead of a key: not sent to
                        // a machine that did not ask for them)
                        if (info & INFO_UNICODE != 0) continue;
                        const code = vmbus.get16(p.body, 4);
                        if (code == 0 or code > 0x7F) continue;
                        return .{ .make = @intCast(code), .e0 = info & INFO_E0 != 0, .e1 = info & INFO_E1 != 0, .up = info & INFO_BREAK != 0 };
                    },
                    else => {},
                }
            }
            return null;
        }
    };
}

const put32 = vmbus.put32;

// ══════════════════════════════════════════════════════════════════════════════
// Tests: the host's end of the channel played by hand
// ══════════════════════════════════════════════════════════════════════════════

const TestHost = vmbus.testing.Host;
const testChannel = vmbus.testing.channel;
const fromHost = vmbus.testing.fromHost;

fn expect(ok: bool) !void {
    if (!ok) return error.TestUnexpectedResult;
}

fn event(make: u16, info: u32) [12]u8 {
    var m = [_]u8{0} ** 12;
    put32(&m, 0, EVENT);
    m[4] = @truncate(make);
    m[5] = @truncate(make >> 8);
    put32(&m, 8, info);
    return m;
}

test "keyboard: the handshake, then keys" {
    var host: TestHost = .{};
    var mem: [5 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var kbd: Keyboard(TestHost) = .{ .ch = testChannel(TestHost, &host, &mem, SEND_PAGES) };
    try expect(kbd.start() and host.signals == 1);
    var buf: [64]u8 = undefined;
    const n = kbd.ch.out.read(&buf) orelse return error.TestUnexpectedResult;
    try expect(n == 24 and vmbus.get32(&buf, 16) == PROTOCOL_REQUEST and vmbus.get32(&buf, 20) == VERSION);
    try expect(vmbus.get16(&buf, 6) == vmbus.pkt.FLAG_COMPLETION_REQUESTED);
    try expect(kbd.poll() == null and !kbd.accepted);

    var response: [8]u8 = undefined;
    put32(&response, 0, PROTOCOL_RESPONSE);
    put32(&response, 4, 1);
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 1, &response));
    // 'a' down and up, then the right arrow (E0 4D) down.
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 2, &event(0x1E, 0)));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 3, &event(0x1E, INFO_BREAK)));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 4, &event(0x4D, INFO_E0)));
    const a = kbd.poll() orelse return error.TestUnexpectedResult;
    try expect(kbd.accepted and a.make == 0x1E and !a.up and !a.e0);
    const up = kbd.poll().?;
    try expect(up.make == 0x1E and up.up);
    const right = kbd.poll().?;
    try expect(right.make == 0x4D and right.e0 and !right.up);
    try expect(kbd.poll() == null);
}

test "keyboard: what is not a key is passed over" {
    var host: TestHost = .{};
    var mem: [5 * vmbus.PAGE]u8 align(vmbus.PAGE) = undefined;
    var kbd: Keyboard(TestHost) = .{ .ch = testChannel(TestHost, &host, &mem, SEND_PAGES) };
    // A completion, a Unicode event, a code out of range, a short packet,
    // an unknown message; then a real key.
    try expect(fromHost(kbd.ch.in, vmbus.pkt.COMPLETION, 1, &[_]u8{0} ** 8));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 2, &event(0x263A, INFO_UNICODE)));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 3, &event(0x100, 0)));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 4, &[_]u8{ 3, 0, 0, 0 }));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 5, &[_]u8{ 9, 0, 0, 0, 0, 0, 0, 0 }));
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 6, &event(0x1C, 0)));
    const k = kbd.poll() orelse return error.TestUnexpectedResult;
    try expect(k.make == 0x1C);
    try expect(kbd.poll() == null);
    // A refusal is remembered.
    var response: [8]u8 = undefined;
    put32(&response, 0, PROTOCOL_RESPONSE);
    put32(&response, 4, 0);
    try expect(fromHost(kbd.ch.in, vmbus.pkt.DATA_INBAND, 7, &response));
    try expect(kbd.poll() == null and kbd.refused and !kbd.accepted);
}
