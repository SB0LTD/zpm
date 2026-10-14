const std = @import("std");
const cpi = @import("solana_cpi");
const rent = @import("solana_rent");
const system = @import("solana_system_account");
const input = @import("solana_entrypoint_input");
const le = @import("solana_le");
const errors = @import("solana_program_error");
var assertions: usize = 0;
var calls: usize = 0;
var fail_at: usize = 0;
var ops: [4]u32 = @splat(0);
var target_length: u64 = 0;
var rent_fail = false;
fn check(value: bool) !void {
    assertions += 1;
    if (!value) return error.CpiContractFailed;
}
fn rejects(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.InvalidAccepted else |actual| try check(actual == expected);
}
const Mock = struct {
    pub fn sol_invoke_signed_c(instruction: *const cpi.Instruction, accounts: [*]cpi.Account, count: u64, signers: [*]const cpi.SignerSeeds, signer_count: u64) u64 {
        const op = le.getLe(u32, instruction.data[0..4]);
        ops[calls] = op;
        calls += 1;
        if (count != 3 or signer_count != 1 or signers[0].len != 1 or instruction.accounts[0].key.*[0] == 0) return errors.builtin(.invalid_argument);
        if (calls == fail_at) return errors.custom(91);
        switch (op) {
            0 => {
                target_length = le.getLe(u64, instruction.data[12..20]);
                @memcpy(@constCast(accounts[1].owner), instruction.data[20..52]);
                accounts[1].lamports.* = le.getLe(u64, instruction.data[4..12]);
            },
            2 => {
                const amount = le.getLe(u64, instruction.data[4..12]);
                accounts[0].lamports.* -= amount;
                accounts[1].lamports.* += amount;
            },
            8 => {
                target_length = le.getLe(u64, instruction.data[4..12]);
            },
            1 => {
                @memcpy(@constCast(accounts[1].owner), instruction.data[4..36]);
            },
            else => return errors.builtin(.invalid_instruction_data),
        }
        return 0;
    }
    pub fn sol_get_sysvar(key: *const [32]u8, out: [*]u8, offset: u64, length: u64) u64 {
        if (rent_fail or !std.mem.eql(u8, key, &rent.RENT_ID) or offset != 0 or length != 17) return 1;
        @memset(out[0..17], 0);
        le.putLe(u64, out[0..8], 6960);
        le.putLe(u64, out[8..16], 0x3ff0000000000000);
        return 0;
    }
};
pub fn main(init: std.process.Init) !void {
    var raw: [17]u8 = @splat(0);
    le.putLe(u64, raw[0..8], 6960);
    le.putLe(u64, raw[8..16], 0x3ff0000000000000);
    try check(try rent.minimumFromBytes(&raw, 80) == 1447680);
    le.putLe(u64, raw[0..8], 3480);
    le.putLe(u64, raw[8..16], 0x4000000000000000);
    try check(try rent.minimumFromBytes(&raw, 80) == 1447680);
    try rejects(error.Capacity, rent.minimumFromBytes(&raw, 10 * 1024 * 1024 + 1));
    le.putLe(u64, raw[0..8], ~@as(u64, 0));
    try rejects(error.Capacity, rent.minimumFromBytes(&raw, 80));
    le.putLe(u64, raw[8..16], 0);
    try rejects(error.UnsupportedThreshold, rent.minimumFromBytes(&raw, 80));
    var minimum: u64 = 77;
    try rent.API(Mock).minimumBalance(80, &minimum);
    try check(minimum == 1447680);
    rent_fail = true;
    try rejects(error.Unavailable, rent.API(Mock).minimumBalance(80, &minimum));
    try check(minimum == 1447680);
    rent_fail = false;
    const owner: [32]u8 = @splat(9);
    const payer_key: [32]u8 = @splat(1);
    const target_key: [32]u8 = @splat(2);
    var target_owner: [32]u8 = @splat(0);
    var balance: u64 = 5000;
    var target_balance: u64 = 0;
    var bytes: [128]u8 = @splat(0);
    const payer: input.AccountInfo = .{ .key = &payer_key, .owner = &system.SYSTEM_ID, .lamports = &balance, .data = bytes[0..0], .is_signer = true, .is_writable = true, .is_executable = false };
    var target: input.AccountInfo = .{ .key = &target_key, .owner = &target_owner, .lamports = &target_balance, .data = bytes[0..0], .data_length = &target_length, .is_signer = false, .is_writable = true, .is_executable = false };
    const system_info: input.AccountInfo = .{ .key = &system.SYSTEM_ID, .owner = &owner, .lamports = &balance, .data = bytes[0..0], .is_signer = false, .is_writable = false, .is_executable = true };
    const seed = [_]@import("solana_syscalls").SolBytes{.{ .ptr = "x", .len = 1 }};
    const request: system.Request = .{ .payer = &payer, .target = &target, .system = &system_info, .owner = &owner, .size = 80, .minimum = 1000, .signer = .{ .seeds = &seed, .len = 1 } };
    const System = system.API(cpi.API(Mock));
    try check(System.create(&request) == 0);
    try check(calls == 1 and ops[0] == 0);
    try check(target_length == 80 and target_balance == 1000 and target_owner[0] == 9);
    try check(System.create(&request) == errors.builtin(.account_already_initialized));
    try check(calls == 1);
    target_owner = @splat(0);
    target_length = 0;
    target_balance = 600;
    calls = 0;
    try check(System.create(&request) == 0);
    try check(calls == 3 and ops[0] == 2 and ops[1] == 8 and ops[2] == 1);
    try check(target_balance == 1000 and target_length == 80 and target_owner[0] == 9);
    target_owner = @splat(0);
    target_length = 0;
    target_balance = 1100;
    calls = 0;
    try check(System.create(&request) == 0);
    try check(calls == 2 and ops[0] == 8 and ops[1] == 1);
    try check(target_balance == 1100);
    target_owner = @splat(0);
    target_length = 0;
    target_balance = 600;
    calls = 0;
    fail_at = 2;
    try check(System.create(&request) == 91);
    try check(calls == 2 and target_owner[0] == 0);
    fail_at = 0;
    target.is_writable = false;
    calls = 0;
    try check(System.create(&request) == errors.builtin(.invalid_argument));
    try check(calls == 0);
    var metas: [1]cpi.Meta = .{.{ .key = &target_key, .writable = true, .signer = true }};
    var infos: [1]cpi.Account = .{cpi.account(&target)};
    var instruction: cpi.Instruction = .{ .program = &system.SYSTEM_ID, .accounts = &metas, .accounts_len = 65, .data = &bytes, .data_len = 0 };
    try rejects(error.Capacity, cpi.API(Mock).invoke(&instruction, &infos, &.{}));
    try check(calls == 0);
    instruction.accounts_len = 1;
    const long_seed = [_]@import("solana_syscalls").SolBytes{.{ .ptr = "x" ** 33, .len = 33 }};
    try rejects(error.SeedTooLong, cpi.API(Mock).invoke(&instruction, &infos, &.{.{ .seeds = &long_seed, .len = 1 }}));
    try check(calls == 0);
    var out: [96]u8 = undefined;
    const message = try std.fmt.bufPrint(&out, "Solana CPI/Rent PASS: {d} assertions\n", .{assertions});
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}
