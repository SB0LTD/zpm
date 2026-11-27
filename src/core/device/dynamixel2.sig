//! Bounded DYNAMIXEL Protocol 2.0. No allocation, OS, or UART dependency.
const t = @import("../sig_testing.sig");
pub const capacity = 256;
pub const Error = error{ Capacity, Id, Header, Length, Crc, Stuffing, Instruction };
pub const Packet = struct {
    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Packet) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub fn crc(bytes: []const u8) u16 {
    var value: u16 = 0;
    for (bytes) |byte| {
        value ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            const top = value & 0x8000;
            value <<= 1;
            if (top != 0) value ^= 0x8005;
        }
    }
    return value;
}
pub fn put16(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
}
pub fn put32(bytes: []u8, value: u32) void {
    for (0..4) |i| bytes[i] = @truncate(value >> @as(u5, @intCast(i * 8)));
}
pub fn get16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}
pub fn get32(bytes: []const u8) u32 {
    var value: u32 = 0;
    for (0..4) |i| value |= @as(u32, bytes[i]) << @as(u5, @intCast(i * 8));
    return value;
}
pub fn encode(out: *Packet, id: u8, instruction: u8, parameters: []const u8) Error!void {
    if (id > 252 and id != 254) return error.Id;
    out.len = 0;
    out.bytes[0..7].* = .{ 255, 255, 253, 0, id, 0, 0 };
    var n: usize = 7;
    // Count the instruction as part of the stuffing domain.
    var previous: [2]u8 = .{ 0, 0 };
    for (0..parameters.len + 1) |i| {
        const byte = if (i == 0) instruction else parameters[i - 1];
        const stuff = previous[0] == 255 and previous[1] == 255 and byte == 253;
        if (n + 3 + @as(usize, @intFromBool(stuff)) > capacity) return error.Capacity;
        out.bytes[n] = byte;
        n += 1;
        if (stuff) {
            out.bytes[n] = 253;
            n += 1;
        }
        previous = .{ previous[1], byte };
    }
    put16(out.bytes[5..7], @intCast(n - 7 + 2));
    put16(out.bytes[n..][0..2], crc(out.bytes[0..n]));
    out.len = n + 2;
}
pub const Status = struct {
    id: u8 = 0,
    status_error: u8 = 0,
    data: [capacity]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Status) []const u8 {
        return self.data[0..self.len];
    }
};
pub fn decode(bytes: []const u8, out: *Status) Error!void {
    if (bytes.len < 11) return error.Length;
    if (bytes[0] != 255 or bytes[1] != 255 or bytes[2] != 253 or bytes[3] != 0) return error.Header;
    if (bytes[4] > 252) return error.Id;
    if (@as(usize, get16(bytes[5..7])) + 7 != bytes.len or bytes.len > capacity) return error.Length;
    if (crc(bytes[0 .. bytes.len - 2]) != get16(bytes[bytes.len - 2 ..])) return error.Crc;
    var body: [capacity]u8 = undefined;
    var n: usize = 0;
    var i: usize = 7;
    while (i < bytes.len - 2) : (i += 1) {
        body[n] = bytes[i];
        n += 1;
        if (n >= 3 and body[n - 3] == 255 and body[n - 2] == 255 and body[n - 1] == 253) {
            i += 1;
            if (i >= bytes.len - 2 or bytes[i] != 253) return error.Stuffing;
        }
    }
    if (n < 2 or body[0] != 0x55) return error.Instruction;
    out.id = bytes[4];
    out.status_error = body[1];
    out.len = n - 2;
    @memcpy(out.data[0..out.len], body[2..n]);
}
/// Feed UART bytes. Returns a complete candidate; decode validates CRC/status.
/// Silence timeout belongs to the transport; reset discards partial packets.
pub const Receiver = struct {
    packet: Packet = .{},
    pub fn reset(self: *Receiver) void {
        self.packet.len = 0;
    }
    pub fn feed(self: *Receiver, byte: u8) ?[]const u8 {
        const header = [_]u8{ 255, 255, 253, 0 };
        var n = self.packet.len;
        if (n < 4 and byte != header[n]) {
            // Preserve overlapping FF FF prefixes in an arbitrary noise stream.
            if (byte == 255) {
                n = if (n >= 1) 2 else 1;
                self.packet.bytes[0] = 255;
                self.packet.bytes[1] = 255;
            } else n = 0;
            self.packet.len = n;
            return null;
        }
        if (n >= capacity) {
            self.reset();
            return null;
        }
        self.packet.bytes[n] = byte;
        n += 1;
        self.packet.len = n;
        if (n >= 7) {
            const total = @as(usize, get16(self.packet.bytes[5..7])) + 7;
            if (total < 11 or total > capacity or self.packet.bytes[4] > 252) {
                self.reset();
                return null;
            }
            if (n == total) {
                self.packet.len = 0;
                return self.packet.bytes[0..n];
            }
        }
        return null;
    }
};
pub fn read(out: *Packet, id: u8, address: u16, length: u16) Error!void {
    var p: [4]u8 = undefined;
    put16(p[0..2], address);
    put16(p[2..4], length);
    try encode(out, id, 2, &p);
}
pub fn write(out: *Packet, id: u8, address: u16, bytes: []const u8) Error!void {
    var p: [capacity]u8 = undefined;
    if (bytes.len + 2 > p.len) return error.Capacity;
    put16(p[0..2], address);
    @memcpy(p[2..][0..bytes.len], bytes);
    try encode(out, id, 3, p[0 .. bytes.len + 2]);
}
pub fn syncWrite(out: *Packet, address: u16, width: u16, records: []const u8) Error!void {
    if (width == 0 or records.len == 0 or records.len % (@as(usize, width) + 1) != 0) return error.Length;
    var ids: [253]bool = @splat(false);
    var i: usize = 0;
    while (i < records.len) : (i += @as(usize, width) + 1) {
        if (records[i] > 252 or ids[records[i]]) return error.Id;
        ids[records[i]] = true;
    }
    var p: [capacity]u8 = undefined;
    if (records.len + 4 > p.len) return error.Capacity;
    put16(p[0..2], address);
    put16(p[2..4], width);
    @memcpy(p[4..][0..records.len], records);
    try encode(out, 254, 0x83, p[0 .. records.len + 4]);
}
test "published ping CRC vector" {
    var p: Packet = .{};
    try encode(&p, 1, 1, &.{});
    try t.expectEqualSlices(u8, &.{ 255, 255, 253, 0, 1, 3, 0, 1, 0x19, 0x4e }, p.slice());
}
test "stuffing roundtrip and corruption" {
    var p: Packet = .{};
    try encode(&p, 3, 0x55, &.{ 0, 255, 255, 253, 253, 1 });
    var s: Status = .{};
    try decode(p.slice(), &s);
    try t.expectEqualSlices(u8, &.{ 255, 255, 253, 253, 1 }, s.slice());
    p.bytes[9] ^= 1;
    try t.expectError(error.Crc, decode(p.slice(), &s));
}
test "stream noise overlapping header and bounded oversize" {
    var p: Packet = .{};
    try encode(&p, 2, 0x55, &.{ 0, 42 });
    var rx: Receiver = .{};
    for ([_]u8{ 1, 255, 255, 255 }) |b| _ = rx.feed(b);
    var found = false;
    for (p.slice()) |b| if (rx.feed(b)) |packet| {
        var s: Status = .{};
        try decode(packet, &s);
        try t.expect(s.id == 2 and s.data[0] == 42);
        found = true;
    };
    try t.expect(found);
    for ([_]u8{ 255, 255, 253, 0, 1, 255, 255 }) |b| _ = rx.feed(b);
    try t.expect(rx.packet.len == 0);
}
test "capacity and duplicate sync IDs" {
    var p: Packet = .{};
    var huge: [256]u8 = @splat(255);
    try t.expectError(error.Capacity, encode(&p, 1, 3, &huge));
    try t.expectError(error.Id, syncWrite(&p, 116, 1, &.{ 1, 0, 1, 0 }));
}

test "stuffing at capacity boundary reserves CRC space" {
    var p: Packet = .{};
    var data: [246]u8 = @splat(0);
    data[243..246].* = .{ 255, 255, 253 };
    try t.expectError(error.Capacity, encode(&p, 1, 3, &data));
    try t.expect(p.len == 0);
}
