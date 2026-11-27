//! RP2040 UF2 and boot ROM CRC, no allocation or platform dependency.
const p = @import("dynamixel2.sig");
const t = @import("../sig_testing.sig");
pub fn bootCrc(bytes: []const u8) u32 {
    var value: u32 = 0;
    for (bytes) |b| {
        value ^= @as(u32, b) << 24;
        for (0..8) |_| {
            const top = value & 0x80000000;
            value <<= 1;
            if (top != 0) value ^= 0x04c11db7;
        }
    }
    return value;
}
pub fn block(out: *[512]u8, payload: []const u8, index: u32, total: u32) error{Range}!void {
    if (payload.len > 256 or total == 0 or index >= total or total > 8192) return error.Range;
    out.* = @splat(0);
    p.put32(out[0..4], 0x0a324655);
    p.put32(out[4..8], 0x9e5d5157);
    p.put32(out[8..12], 0x2000);
    p.put32(out[12..16], 0x10000000 + index * 256);
    p.put32(out[16..20], 256);
    p.put32(out[20..24], index);
    p.put32(out[24..28], total);
    p.put32(out[28..32], 0xe48bff56);
    @memcpy(out[32..][0..payload.len], payload);
    p.put32(out[508..512], 0x0ab16f30);
}
test "boot CRC seed-zero check and UF2 metadata" {
    try t.expect(bootCrc("123456789") == 0x89a1897f);
    var b: [512]u8 = undefined;
    try block(&b, &.{ 1, 2, 3 }, 2, 4);
    try t.expect(p.get32(b[12..16]) == 0x10000200 and b[32] == 1 and b[35] == 0);
    try t.expectError(error.Range, block(&b, &.{}, 4, 4));
}
