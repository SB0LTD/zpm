//! Host contracts inject raw syscall backends; native externs are never linked here.
const std = @import("std");
const syscalls = @import("solana_syscalls");
const clock = @import("solana_clock");
const entry = @import("solana_entrypoint");
const input = @import("solana_entrypoint_input");
const returns = @import("solana_program_error");
const le = @import("solana_le");
var assertions: usize = 0;
var calls: usize = 0;
var fail = false;
var marshalled = false;
var processor_calls: usize = 0;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.SolanaRuntimeContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
const Mock = struct {
    pub fn sol_sha256(values: [*]const syscalls.SolBytes, count: u64, out: *[32]u8) u64 {
        calls += 1;
        marshalled = count == 2 and std.mem.eql(u8, values[0].ptr[0..@intCast(values[0].len)], "one") and std.mem.eql(u8, values[1].ptr[0..@intCast(values[1].len)], "two");
        out.* = @splat(9);
        return @intFromBool(fail);
    }
    pub fn sol_try_find_program_address(values: [*]const syscalls.SolBytes, count: u64, program: *const [32]u8, out: *[32]u8, bump: *u8) u64 {
        calls += 1;
        marshalled = count == 1 and program[0] == 7 and std.mem.eql(u8, values[0].ptr[0..@intCast(values[0].len)], "player");
        out.* = @splat(8);
        bump.* = 254;
        return @intFromBool(fail);
    }
    pub fn sol_get_sysvar(id: *const [32]u8, out: [*]u8, offset: u64, length: u64) u64 {
        calls += 1;
        marshalled = std.mem.eql(u8, id, &clock.CLOCK_ID) and offset == 0 and length == 40;
        const value: clock.ClockRaw = .{ .slot = 71, .epoch_start_timestamp = -99, .epoch = 3, .leader_schedule_epoch = 4, .unix_timestamp = 1234 };
        @memcpy(out[0..40], std.mem.asBytes(&value));
        return @intFromBool(fail);
    }
    pub fn sol_set_return_data(bytes: [*]const u8, length: u64) void {
        calls += 1;
        marshalled = length == 3 and std.mem.eql(u8, bytes[0..3], "yes");
    }
};
const Runtime = syscalls.API(Mock);
const Clock = clock.API(Mock);
fn process(value: *const input.Input, slot: u64) u64 {
    processor_calls += 1;
    if (slot != 71 or value.accounts.len != 1 or !value.accounts[0].is_writable or !std.mem.eql(u8, value.instruction_data, "hi")) return returns.custom(2);
    value.accounts[0].data[0] = 'X';
    return returns.custom(42);
}
fn fixture(buffer: []u8) usize {
    @memset(buffer, 0);
    le.putLe(u64, buffer, 1);
    buffer[8] = 255;
    buffer[9] = 1;
    buffer[10] = 1;
    @memset(buffer[16..48], 7);
    @memset(buffer[48..80], 9);
    le.putLe(u64, buffer[88..96], 1);
    buffer[96] = 'a';
    const rent_offset = 10344;
    le.putLe(u64, buffer[rent_offset..], 0xffffffffffffffff);
    le.putLe(u64, buffer[10352..], 2);
    @memcpy(buffer[10360..10362], "hi");
    @memset(buffer[10362..10394], 11);
    return 10394;
}
pub fn main(init: std.process.Init) !void {
    try check(@sizeOf(syscalls.SolBytes) == 16 and @offsetOf(syscalls.SolBytes, "len") == 8);
    try check(@sizeOf(clock.ClockRaw) == 40 and @offsetOf(clock.ClockRaw, "unix_timestamp") == 32);
    var scratch: [2]syscalls.SolBytes = undefined;
    var output: [32]u8 = @splat(1);
    try Runtime.sha256(&.{ "one", "two" }, &scratch, &output);
    try check(calls == 1 and marshalled and output[0] == 9);
    fail = true;
    output = @splat(1);
    try rejects(error.Failed, Runtime.sha256(&.{ "one", "two" }, &scratch, &output));
    try check(output[0] == 1);
    const before = calls;
    try rejects(error.Capacity, Runtime.sha256(&.{ "one", "two" }, scratch[0..1], &output));
    try check(calls == before);
    fail = false;
    const program: [32]u8 = @splat(7);
    try check(try Runtime.tryFindProgramAddress(&.{"player"}, &scratch, &program, &output) == 254 and marshalled and output[0] == 8);
    fail = true;
    output = @splat(1);
    try rejects(error.Failed, Runtime.tryFindProgramAddress(&.{"player"}, &scratch, &program, &output));
    try check(output[0] == 1);
    const seed_calls = calls;
    try rejects(error.SeedTooLong, Runtime.tryFindProgramAddress(&.{"x" ** 33}, &scratch, &program, &output));
    try rejects(error.Capacity, Runtime.tryFindProgramAddress(&([_][]const u8{"a"} ** 16), &scratch, &program, &output));
    try check(calls == seed_calls);
    fail = false;
    const time = try Clock.getClock();
    try check(marshalled and time.slot == 71 and time.epoch_start_timestamp == -99 and time.unix_timestamp == 1234);
    fail = true;
    try rejects(error.Unavailable, Clock.currentSlot());
    fail = false;
    try Runtime.setReturnData("yes");
    try check(marshalled);
    const return_calls = calls;
    try rejects(error.Capacity, Runtime.setReturnData("a" ** 1025));
    try check(calls == return_calls);
    var buffer: [11000]u8 = undefined;
    const length = fixture(&buffer);
    try check(try entry.measureTrusted(&buffer, 1) == length);
    try check(entry.runWithClock(1, process, Clock, &buffer) == 42 and buffer[96] == 'X' and processor_calls == 1);
    fail = true;
    buffer[96] = 'a';
    try check(entry.runWithClock(1, process, Clock, &buffer) == returns.builtin(.unsupported_sysvar) and processor_calls == 1 and buffer[96] == 'a');
    fail = false;
    buffer[9] = 2;
    try check(entry.runWithClock(1, process, Clock, &buffer) == returns.builtin(.invalid_account_data) and processor_calls == 1);
    _ = fixture(&buffer);
    buffer[8] = 0;
    try check(entry.runWithClock(1, process, Clock, &buffer) == returns.builtin(.invalid_account_data));
    _ = fixture(&buffer);
    le.putLe(u64, buffer[88..96], 0xffffffffffffffff);
    try rejects(error.Capacity, entry.measureTrusted(&buffer, 1));
    _ = fixture(&buffer);
    try rejects(error.TooManyAccounts, entry.measureTrusted(&buffer, 0));
    le.putLe(u64, buffer[10352..], 10241);
    try rejects(error.Capacity, entry.measureTrusted(&buffer, 1));
    var report_buffer: [128]u8 = undefined;
    const report = try std.fmt.bufPrint(&report_buffer, "Solana runtime PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
