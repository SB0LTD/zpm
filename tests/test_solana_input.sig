const std = @import("std");
const le = @import("solana_le");
const input = @import("solana_entrypoint_input");
const pda = @import("solana_pda");
var assertions: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SolanaInputContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
fn fixture(buffer: []u8, count: usize) usize {
    @memset(buffer, 0);
    le.putLe(u64, buffer, @intCast(count));
    var position: usize = 8;
    if (count > 0) {
        buffer[position] = 255;
        buffer[position + 1] = 1;
        buffer[position + 2] = 1;
        @memset(buffer[position + 8 ..][0..32], 7);
        @memset(buffer[position + 40 ..][0..32], 9);
        le.putLe(u64, buffer[position + 72 ..], 123);
        le.putLe(u64, buffer[position + 80 ..], 3);
        position += 88;
        @memcpy(buffer[position..][0..3], "abc");
        position += 3;
        position += input.MAX_PERMITTED_DATA_INCREASE;
        position += (8 - position % 8) % 8;
        le.putLe(u64, buffer[position..], 0xffffffffffffffff);
        position += 8;
        for (1..count) |i| {
            buffer[position] = @intCast(i - 1);
            position += 8;
        }
    }
    le.putLe(u64, buffer[position..], 2);
    position += 8;
    @memcpy(buffer[position..][0..2], "hi");
    position += 2;
    @memset(buffer[position..][0..32], 11);
    position += 32;
    return position;
}
var curve_calls: usize = 0;
fn firstOnCurve(_: *const [32]u8) bool {
    curve_calls += 1;
    return curve_calls == 1;
}
fn alwaysOnCurve(_: *const [32]u8) bool {
    curve_calls += 1;
    return true;
}
pub fn main(init: std.process.Init) !void {
    var buffer: [11000]u8 = undefined;
    var accounts: [64]input.AccountInfo = undefined;
    const empty_length = fixture(&buffer, 0);
    const empty = try input.parseInto(buffer[0..empty_length], &accounts);
    try check(empty.accounts.len == 0 and empty.consumed == empty_length and empty.program_id.*[0] == 11);
    const length = fixture(&buffer, 2);
    var parsed = try input.parseInto(buffer[0..length], &accounts);
    try check(parsed.accounts.len == 2 and parsed.consumed == length);
    try check(std.mem.eql(u8, parsed.instruction_data, "hi") and parsed.accounts[0].key.*[0] == 7 and parsed.accounts[0].owner.*[0] == 9);
    try check(parsed.accounts[0].is_signer and parsed.accounts[0].is_writable and !parsed.accounts[0].is_executable);
    try check(parsed.accounts[1].is_duplicate and parsed.accounts[1].dup_index == 0 and parsed.accounts[1].data.ptr == parsed.accounts[0].data.ptr);
    parsed.accounts[1].data[1] = 'X';
    parsed.accounts[1].lamports.* = 456;
    try check(buffer[97] == 'X' and le.getLe(u64, buffer[80..88]) == 456);
    for (0..length) |prefix| try rejects(error.Truncated, input.parseInto(buffer[0..prefix], &accounts));
    _ = fixture(&buffer, 2);
    buffer[9] = 2;
    try rejects(error.NonCanonical, input.parseInto(buffer[0..length], &accounts));
    buffer[9] = 1;
    buffer[10352] = 1;
    try rejects(error.MalformedInput, input.parseInto(buffer[0..length], &accounts));
    buffer[10352] = 0;
    le.putLe(u64, buffer[88..96], 0xffffffffffffffff);
    try rejects(error.Truncated, input.parseInto(buffer[0..length], &accounts));
    _ = fixture(&buffer, 2);
    try rejects(error.TooManyAccounts, input.parseInto(buffer[0..length], accounts[0..1]));
    le.putLe(u64, &buffer, 65);
    try rejects(error.TooManyAccounts, input.parseInto(&buffer, &accounts));
    const maximum_length = fixture(&buffer, 64);
    const maximum = try input.parseInto(buffer[0..maximum_length], &accounts);
    try check(maximum.accounts.len == 64 and maximum.accounts[63].dup_index == 62 and maximum.accounts[63].lamports == maximum.accounts[0].lamports);
    const unaligned_length = fixture(buffer[1..], 1);
    const unaligned = try input.parseInto(buffer[1..][0..unaligned_length], &accounts);
    try check(unaligned.accounts[0].lamports.* == 123 and std.mem.eql(u8, unaligned.accounts[0].data, "abc"));
    const program: [32]u8 = @splat(1);
    const seeds: []const []const u8 = &.{ "player", "owner" };
    const address = try pda.deriveWithBump(seeds, 255, &program);
    var preimage: [65]u8 = undefined;
    @memcpy(preimage[0..11], "playerowner");
    preimage[11] = 255;
    @memcpy(preimage[12..44], &program);
    @memcpy(preimage[44..65], "ProgramDerivedAddress");
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&preimage, &expected, .{});
    try check(std.mem.eql(u8, &address, &expected));
    curve_calls = 0;
    var found: [32]u8 = @splat(99);
    try check(try pda.findProgramAddress(seeds, &program, firstOnCurve, &found) == 254 and curve_calls == 2);
    const second = try pda.deriveWithBump(seeds, 254, &program);
    try check(std.mem.eql(u8, &found, &second));
    curve_calls = 0;
    try rejects(error.NoViableBump, pda.findProgramAddress(seeds, &program, alwaysOnCurve, &found));
    try check(curve_calls == 256 and std.mem.eql(u8, &found, &second));
    try rejects(error.TooManySeeds, pda.deriveWithBump(&([_][]const u8{"a"} ** 16), 255, &program));
    try rejects(error.SeedTooLong, pda.deriveWithBump(&.{"x" ** 33}, 255, &program));
    var report_buffer: [128]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buffer, "Solana input/PDA PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
