//! CDC ACM control endpoint policy, independent of the USB controller.
const t = @import("../sig_testing.sig");
pub const device = [_]u8{ 18, 1, 0, 2, 2, 0, 0, 64, 0xfe, 0xca, 1, 0x40, 0, 1, 1, 2, 3, 1 };
// Lab-only VID/PID cafe:4001. Obtain an assigned identity before distribution.
pub const configuration = [_]u8{
    9, 2,    67,   0,    2,    1, 0,    0x80, 50,
    9, 4,    0,    0,    1,    2, 2,    1,    0,
    5, 0x24, 0,    0x10, 1,    5, 0x24, 1,    0,
    1, 4,    0x24, 2,    2,    5, 0x24, 6,    0,
    1, 7,    5,    0x81, 3,    8, 0,    16,   9,
    4, 1,    0,    2,    0x0a, 0, 0,    0,    7,
    5, 0x02, 2,    64,   0,    0, 7,    5,    0x83,
    2, 64,   0,    0,
};
pub const Setup = struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
    pub fn from(bytes: []const u8) Setup {
        return .{ .request_type = bytes[0], .request = bytes[1], .value = le(bytes[2..4]), .index = le(bytes[4..6]), .length = le(bytes[6..8]) };
    }
};
fn le(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}
pub const Action = enum { stall, data, ack, line_out };
pub const Control = struct {
    response: [128]u8 = undefined,
    len: usize = 0,
    requested: u16 = 0,
    address: u7 = 0,
    configured: bool = false,
    dtr: bool = false,
    halted: [3]bool = @splat(false),
    pending_endpoint: ?u8 = null,
    pending_halt: bool = false,
    pending_address: ?u7 = null,
    pending_config: ?bool = null,
    pending_dtr: ?bool = null,
    line: [7]u8 = .{ 0, 0xc2, 1, 0, 0, 0, 8 },
    product: []const u8 = "SlowWire RP2040",
    serial: [32]u8 = @splat(0),
    serial_len: usize = 0,
    pub fn serialWords(self: *Control, words: []const u32) void {
        if (words.len == 0 or words.len > 4) return;
        const digits = "0123456789ABCDEF";
        for (words, 0..) |word, i| for (0..8) |j| {
            self.serial[i * 8 + j] = digits[(word >> @as(u5, @intCast(28 - j * 4))) & 15];
        };
        self.serial_len = words.len * 8;
    }
    pub fn reset(self: *Control) void {
        const product = self.product;
        const serial = self.serial;
        const serial_len = self.serial_len;
        self.* = .{};
        self.product = product;
        self.serial = serial;
        self.serial_len = serial_len;
    }
    fn data(self: *Control, bytes: []const u8, length: u16) Action {
        self.len = @min(bytes.len, length);
        @memcpy(self.response[0..self.len], bytes[0..self.len]);
        return .data;
    }
    pub fn setup(self: *Control, s: Setup) Action {
        self.pending_endpoint = null;
        self.pending_address = null;
        self.pending_config = null;
        self.pending_dtr = null;
        self.len = 0;
        self.requested = s.length;
        switch (s.request_type) {
            0x80 => switch (s.request) {
                6 => {
                    if (s.value >> 8 == 1 and s.value & 255 == 0 and s.index == 0) return self.data(&device, s.length);
                    if (s.value >> 8 == 2 and s.value & 255 == 0 and s.index == 0) return self.data(&configuration, s.length);
                    if (s.value >> 8 == 3) {
                        const index = s.value & 255;
                        if (index == 0 and s.index == 0) return self.data(&.{ 4, 3, 9, 4 }, s.length);
                        if (s.index != 0x409) return .stall;
                        const text: []const u8 = switch (index) {
                            1 => "SB0 lab",
                            2 => self.product,
                            3 => if (self.serial_len != 0) self.serial[0..self.serial_len] else "SW-PROTO-001",
                            else => return .stall,
                        };
                        self.response[0] = @intCast(2 + text.len * 2);
                        self.response[1] = 3;
                        for (text, 0..) |b, i| {
                            self.response[2 + i * 2] = b;
                            self.response[3 + i * 2] = 0;
                        }
                        self.len = @min(2 + text.len * 2, s.length);
                        return .data;
                    }
                    return .stall;
                },
                8 => {
                    if (s.value != 0 or s.index != 0 or s.length != 1) return .stall;
                    return self.data(&.{@intFromBool(self.configured)}, 1);
                },
                0 => {
                    if (s.value != 0 or s.index != 0 or s.length != 2) return .stall;
                    return self.data(&.{ 0, 0 }, 2);
                },
                else => return .stall,
            },
            0 => switch (s.request) {
                5 => {
                    if (s.value > 127 or s.index != 0 or s.length != 0 or self.configured) return .stall;
                    self.pending_address = @intCast(s.value);
                    return .ack;
                },
                9 => {
                    if (s.value > 1 or s.index != 0 or s.length != 0 or self.address == 0) return .stall;
                    self.pending_config = s.value == 1;
                    return .ack;
                },
                else => return .stall,
            },
            0x81 => {
                if (!self.configured or s.index > 1 or s.value != 0) return .stall;
                if (s.request == 0 and s.length == 2) return self.data(&.{ 0, 0 }, 2);
                if (s.request == 10 and s.length == 1) return self.data(&.{0}, 1);
                return .stall;
            },
            1 => {
                if (self.configured and s.request == 11 and s.index <= 1 and s.value == 0 and s.length == 0) return .ack;
                return .stall;
            },
            0x82 => {
                if (s.request != 0 or s.value != 0 or s.length != 2) return .stall;
                if (s.index == 0 or s.index == 0x80) return self.data(&.{ 0, 0 }, 2);
                if (!self.configured) return .stall;
                const ep = endpointIndex(s.index) orelse return .stall;
                return self.data(&.{ @intFromBool(self.halted[ep]), 0 }, 2);
            },
            2 => {
                if (!self.configured or (s.request != 1 and s.request != 3) or s.value != 0 or s.length != 0) return .stall;
                self.pending_endpoint = endpointIndex(s.index) orelse return .stall;
                self.pending_halt = s.request == 3;
                return .ack;
            },
            0xa1 => {
                if (!self.configured or s.request != 0x21 or s.value != 0 or s.index != 0 or s.length != 7) return .stall;
                return self.data(&self.line, 7);
            },
            0x21 => {
                if (!self.configured or s.index != 0) return .stall;
                if (s.request == 0x20 and s.value == 0 and s.length == 7) return .line_out;
                if (s.request == 0x22 and s.value <= 3 and s.length == 0) {
                    self.pending_dtr = s.value & 1 != 0;
                    return .ack;
                }
                if (s.request == 0x23 and s.length == 0) return .ack;
                return .stall;
            },
            else => return .stall,
        }
    }
    /// USB address/configuration take effect AFTER the status packet completes.
    pub fn acknowledged(self: *Control) void {
        if (self.pending_endpoint) |ep| self.halted[ep] = self.pending_halt;
        if (self.pending_address) |a| self.address = a;
        if (self.pending_config) |c| {
            self.configured = c;
            self.dtr = false;
            self.halted = @splat(false);
        }
        if (self.pending_dtr) |d| self.dtr = d;
        self.pending_endpoint = null;
        self.pending_address = null;
        self.pending_config = null;
        self.pending_dtr = null;
    }
};

test "board product and silicon serial persist across USB reset and short reads" {
    var c: Control = .{};
    c.product = "SlowWire OpenCR";
    c.serialWords(&.{ 0x1234abcd, 0x00000001, 0xdeadbeef });
    c.reset();
    try t.expect(c.product.len == 15 and c.serial_len == 24);
    try t.expect(c.setup(.{ .request_type = 128, .request = 6, .value = 0x303, .index = 0x409, .length = 2 }) == .data);
    try t.expect(c.len == 2 and c.response[0] == 50);
    _ = c.setup(.{ .request_type = 128, .request = 6, .value = 0x303, .index = 0x409, .length = 128 });
    try t.expect(c.len == 50 and c.response[2] == '1' and c.response[16] == 'D');
}
test "USB descriptors total lengths endpoint directions and delayed address" {
    try t.expect(configuration.len == le(configuration[2..4]));
    var c: Control = .{};
    try t.expect(c.setup(.{ .request_type = 0, .request = 5, .value = 4, .index = 0, .length = 0 }) == .ack);
    try t.expect(c.address == 0);
    c.acknowledged();
    try t.expect(c.address == 4);
    try t.expect(c.setup(.{ .request_type = 0, .request = 9, .value = 1, .index = 0, .length = 0 }) == .ack);
    try t.expect(!c.configured);
    c.acknowledged();
    try t.expect(c.configured);
}
test "USB short descriptor request invalid class and line coding bounds" {
    var c: Control = .{};
    try t.expect(c.setup(.{ .request_type = 0x80, .request = 6, .value = 0x200, .index = 0, .length = 9 }) == .data);
    try t.expect(c.len == 9);
    try t.expect(c.setup(.{ .request_type = 0x21, .request = 0x20, .value = 0, .index = 0, .length = 7 }) == .stall);
    c.configured = true;
    try t.expect(c.setup(.{ .request_type = 0x21, .request = 0x20, .value = 0, .index = 0, .length = 8 }) == .stall);
    try t.expect(c.setup(.{ .request_type = 0x21, .request = 0x20, .value = 0, .index = 0, .length = 7 }) == .line_out);
}

pub fn endpointIndex(address: u16) ?u8 {
    return switch (address) {
        0x81 => 0,
        0x02 => 1,
        0x83 => 2,
        else => null,
    };
}
test "endpoint halt and clear are acknowledged and invalid endpoints stall" {
    var c: Control = .{};
    c.configured = true;
    try t.expect(c.setup(.{ .request_type = 2, .request = 3, .value = 0, .index = 0x83, .length = 0 }) == .ack);
    try t.expect(!c.halted[2]);
    c.acknowledged();
    try t.expect(c.halted[2]);
    try t.expect(c.setup(.{ .request_type = 0x82, .request = 0, .value = 0, .index = 0x83, .length = 2 }) == .data and c.response[0] == 1);
    try t.expect(c.setup(.{ .request_type = 2, .request = 1, .value = 0, .index = 0x83, .length = 0 }) == .ack);
    c.acknowledged();
    try t.expect(!c.halted[2]);
    try t.expect(c.setup(.{ .request_type = 2, .request = 1, .value = 0, .index = 0x84, .length = 0 }) == .stall);
}
