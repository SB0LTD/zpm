//! Bounded C CPI ABI. Views borrow authenticated loader memory; no copies of keys.
const input = @import("solana_entrypoint_input");
const sys = @import("solana_syscalls");
pub const Meta = extern struct { key: *align(1) const [32]u8, writable: bool, signer: bool };
pub const Instruction = extern struct { program: *const [32]u8, accounts: [*]const Meta, accounts_len: u64, data: [*]const u8, data_len: u64 };
pub const Account = extern struct {
    key: *align(1) const [32]u8,
    lamports: *align(1) u64,
    data_len: u64,
    data: [*]u8,
    owner: *align(1) const [32]u8,
    rent_epoch: u64,
    signer: bool,
    writable: bool,
    executable: bool,
};
pub const SignerSeeds = extern struct { seeds: [*]const sys.SolBytes, len: u64 };
pub const Error = error{ Capacity, SeedTooLong };
pub const Native = struct {
    pub extern fn sol_invoke_signed_c(instruction: *const Instruction, accounts: [*]Account, accounts_len: u64, signers: [*]const SignerSeeds, signers_len: u64) callconv(.c) u64;
};
pub inline fn account(value: *const input.AccountInfo) Account {
    return .{ .key = value.key, .lamports = value.lamports, .data_len = value.data.len, .data = value.data.ptr, .owner = value.owner, .rent_epoch = ~@as(u64, 0), .signer = value.is_signer, .writable = value.is_writable, .executable = value.is_executable };
}
pub fn API(comptime Backend: type) type {
    return struct {
        /// Native result is preserved; CPI effects roll back if the outer program fails.
        pub fn invoke(instruction: *const Instruction, accounts: []Account, signers: []const SignerSeeds) Error!u64 {
            if (instruction.accounts_len > 64 or instruction.data_len > 10240 or accounts.len > 64 or signers.len > 16) return error.Capacity;
            for (signers) |signer| {
                if (signer.len > 16) return error.Capacity;
                for (signer.seeds[0..signer.len]) |seed| if (seed.len > 32) return error.SeedTooLong;
            }
            return Backend.sol_invoke_signed_c(instruction, accounts.ptr, accounts.len, signers.ptr, signers.len);
        }
    };
}
pub const Runtime = API(Native);
comptime {
    if (@sizeOf(Meta) != 16 or @sizeOf(Instruction) != 40 or @sizeOf(Account) != 56 or @sizeOf(SignerSeeds) != 16) @compileError("C CPI ABI mismatch");
}
