//! Runnable contracts: base58 vectors, independent c3 cross-checks and ABI return codes.
const std = @import("std");
const le = @import("solana_le");
const base58 = @import("solana_base58");
const returns = @import("solana_program_error");
const existing = @import("c3-wallet-auth");
var assertions: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SolanaCoreContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
pub fn main(init: std.process.Init) !void {
    var bytes: [8]u8 = undefined;
    le.putLe(u8, &bytes, 0xff);
    try check(le.getLe(u8, &bytes) == 0xff);
    le.putLe(u16, &bytes, 0x1234);
    try check(bytes[0] == 0x34 and bytes[1] == 0x12 and le.getLe(u16, &bytes) == 0x1234);
    le.putLe(u32, &bytes, 0x12345678);
    try check(le.getLe(u32, &bytes) == 0x12345678);
    le.putLe(u64, &bytes, 0x123456789abcdef0);
    try check(bytes[0] == 0xf0 and bytes[7] == 0x12 and le.readU64(&bytes, 0) == 0x123456789abcdef0);
    var encoded: [512]u8 = undefined;
    var decoded: [256]u8 = undefined;
    const vectors = .{ .{ "", "" }, .{ "\x00", "1" }, .{ "\x00\x00\x01", "112" }, .{ "\x61", "2g" }, .{ "\x62\x62\x62", "a3gV" }, .{ "\x63\x63\x63", "aPEr" }, .{ "Hello World", "JxF12TrwUP45BMd" } };
    inline for (vectors) |vector| {
        const length = try base58.encode(vector[0], &encoded);
        try check(std.mem.eql(u8, encoded[0..length], vector[1]));
        const decoded_length = try base58.decode(vector[1], &decoded);
        try check(std.mem.eql(u8, decoded[0..decoded_length], vector[0]));
    }
    var source: [256]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i * 37);
    for (0..source.len + 1) |length| {
        const n = try base58.encode(source[0..length], &encoded);
        const m = try base58.decode(encoded[0..n], &decoded);
        try check(m == length and std.mem.eql(u8, source[0..length], decoded[0..m]));
    }
    var small: [1]u8 = undefined;
    try rejects(error.OutputTooSmall, base58.encode("\xff", &small));
    try rejects(error.OutputTooSmall, base58.decode("111", &small));
    for ("0OIl \n\xff") |byte| try rejects(error.InvalidChar, base58.decode(&.{byte}, &decoded));
    var key: [32]u8 = undefined;
    var key_text: [44]u8 = undefined;
    var reference_text: [44]u8 = undefined;
    var key_decoded: [32]u8 = undefined;
    for (0..256) |seed| {
        for (&key, 0..) |*byte, i| byte.* = @truncate(seed * (i + 1));
        const length = base58.encodeKey(&key, &key_text);
        const reference_length = existing.encodePublicKey(&key, &reference_text);
        try check(length == reference_length and std.mem.eql(u8, key_text[0..length], reference_text[0..reference_length]));
        try base58.decodeKey(key_text[0..length], &key_decoded);
        try check(std.mem.eql(u8, &key, &key_decoded));
        try check(existing.decodePublicKey(key_text[0..length], &key_decoded));
    }
    @memset(&key, 0);
    const zero_length = base58.encodeKey(&key, &key_text);
    try check(zero_length == 32 and std.mem.eql(u8, key_text[0..zero_length], "1" ** 32));
    try rejects(error.NonCanonical, base58.decodeKey("1" ** 31, &key_decoded));
    try rejects(error.OutputTooSmall, base58.decodeKey("1" ** 33, &key_decoded));
    try base58.decodeKey("So11111111111111111111111111111111111111112", &key_decoded);
    try check(base58.encodeKey(&key_decoded, &key_text) == 43 and std.mem.eql(u8, key_text[0..43], "So11111111111111111111111111111111111111112"));
    try check(returns.SUCCESS == 0 and returns.custom(0) == 0x100000000 and returns.custom(1) == 1 and returns.custom(0xffffffff) == 0xffffffff);
    inline for (@typeInfo(returns.ProgramError).@"enum".field_values, 0..) |value, i| {
        try check(returns.builtin(@fromBackingInt(@intCast(value))) == (@as(u64, @intCast(i)) + 2) << 32);
    }
    var report_buffer: [128]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buffer, "Solana core PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
