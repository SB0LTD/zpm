//! Small binary SlowWire command link over USB CDC. CRC, bounds, resynchronization.
const p = @import("dynamixel2.sig");
const t = @import("../sig_testing.sig");
pub const max_payload = 48;
pub const Op = enum(u8) { hello = 1, heartbeat = 2, stop = 3, identify = 4, configure = 5, telemetry = 6, calibrate = 7, arm = 8, jog = 9, run = 10, provision = 11, board = 12, board_io = 13, capacitive_read = 14, _ };
pub const Frame = struct { seq: u16 = 0, op: Op = .hello, payload: [max_payload]u8 = undefined, len: usize = 0 };
pub const Encoded = struct {
    bytes: [max_payload + 9]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Encoded) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub fn encode(frame: *const Frame, out: *Encoded) error{Length}!void {
    if (frame.len > max_payload) return error.Length;
    out.bytes[0..4].* = .{ 'S', 'W', 1, @intCast(frame.len) };
    p.put16(out.bytes[4..6], frame.seq);
    out.bytes[6] = @backingInt(frame.op);
    @memcpy(out.bytes[7..][0..frame.len], frame.payload[0..frame.len]);
    p.put16(out.bytes[7 + frame.len ..][0..2], p.crc(out.bytes[0 .. 7 + frame.len]));
    out.len = frame.len + 9;
}
pub const Receiver = struct {
    data: [max_payload + 9]u8 = undefined,
    len: usize = 0,
    bad: u32 = 0,
    pub fn reset(self: *Receiver) void {
        self.len = 0;
    }
    pub fn feed(self: *Receiver, byte: u8, out: *Frame) bool {
        if (self.len == 0) {
            if (byte == 'S') {
                self.data[0] = byte;
                self.len = 1;
            }
            return false;
        }
        if ((self.len == 1 and byte != 'W') or (self.len == 2 and byte != 1)) {
            self.len = if (byte == 'S') @as(usize, 1) else 0;
            self.data[0] = 'S';
            return false;
        }
        if (self.len == 3 and byte > max_payload) {
            self.bad +%= 1;
            self.reset();
            return false;
        }
        self.data[self.len] = byte;
        self.len += 1;
        if (self.len >= 4 and self.len == @as(usize, self.data[3]) + 9) {
            const n = self.len;
            self.len = 0;
            if (p.get16(self.data[n - 2 .. n]) != p.crc(self.data[0 .. n - 2])) {
                self.bad +%= 1;
                return false;
            }
            out.seq = p.get16(self.data[4..6]);
            out.op = @fromBackingInt(@intCast(self.data[6]));
            out.len = self.data[3];
            @memcpy(out.payload[0..out.len], self.data[7..][0..out.len]);
            return true;
        }
        return false;
    }
};
test "frame split at every byte and corrupt CRC" {
    var frame: Frame = .{ .seq = 65535, .op = .jog, .len = 3 };
    frame.payload[0..3].* = .{ 1, 0, 8 };
    var encoded: Encoded = .{};
    try encode(&frame, &encoded);
    var rx: Receiver = .{};
    var got: Frame = .{};
    for (encoded.slice(), 0..) |b, i| {
        try t.expect(rx.feed(b, &got) == (i + 1 == encoded.len));
    }
    try t.expect(got.seq == 65535 and got.op == .jog and got.len == 3);
    encoded.bytes[7] ^= 1;
    for (encoded.slice()) |b| try t.expect(!rx.feed(b, &got));
    try t.expect(rx.bad == 1);
}
