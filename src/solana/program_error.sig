//! Solana return-code ABI, verified against anza-xyz/solana-sdk program-error.
//! Builtins occupy the upper 32 bits. Nonzero custom codes are plain u32 values.
//! Custom zero uses the dedicated 1 << 32 marker, never SUCCESS.
pub const SUCCESS: u64 = 0;
pub const ProgramError = enum(u64) {
    invalid_argument = 2 << 32,
    invalid_instruction_data = 3 << 32,
    invalid_account_data = 4 << 32,
    account_data_too_small = 5 << 32,
    insufficient_funds = 6 << 32,
    incorrect_program_id = 7 << 32,
    missing_required_signature = 8 << 32,
    account_already_initialized = 9 << 32,
    uninitialized_account = 10 << 32,
    not_enough_account_keys = 11 << 32,
    account_borrow_failed = 12 << 32,
    max_seed_length_exceeded = 13 << 32,
    invalid_seeds = 14 << 32,
    borsh_io_error = 15 << 32,
    account_not_rent_exempt = 16 << 32,
    unsupported_sysvar = 17 << 32,
    illegal_owner = 18 << 32,
    max_accounts_data_allocations_exceeded = 19 << 32,
    invalid_realloc = 20 << 32,
    max_instruction_trace_length_exceeded = 21 << 32,
    builtin_programs_must_consume_compute_units = 22 << 32,
    invalid_account_owner = 23 << 32,
    arithmetic_overflow = 24 << 32,
    immutable = 25 << 32,
    incorrect_authority = 26 << 32,
};
pub fn custom(code: u32) u64 {
    return if (code == 0) 1 << 32 else code;
}
pub fn builtin(value: ProgramError) u64 {
    return @backingInt(value);
}
