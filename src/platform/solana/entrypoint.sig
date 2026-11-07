//! Layer 1: trusted loader-pointer boundary and caller-sized descriptor storage.
//! A bare pointer carries no allocation length. Only the Solana loader may call
//! this boundary; use the Layer 0 bounded parser for untrusted host buffers.
const input = @import("solana_entrypoint_input");
const le = @import("solana_le");
const errors = @import("solana_program_error");
const clock = @import("solana_clock");
pub const Processor = *const fn (*const input.Input, u64) u64;
pub const Error = error{ TooManyAccounts, MalformedInput, Capacity };
pub const MAX_ACCOUNT_DATA = 10 * 1024 * 1024;
pub const MAX_INSTRUCTION_DATA = 10240;
fn advance(position: *usize, amount: usize) Error!void {
    if (amount > ~@as(usize, 0) - position.*) return error.Capacity;
    position.* += amount;
}
/// Trusted ABI scan only: it cannot detect a truncated allocation from a pointer.
/// Runtime memory protection provides that final boundary. Length/capacity checks
/// prevent forged sizes from constructing arbitrarily large downstream slices.
pub inline fn measureTrusted(region: [*]const u8, capacity: usize) Error!usize {
    const count = le.getLe(u64, region[0..8]);
    if (count > input.MAX_ACCOUNTS or count > capacity) return error.TooManyAccounts;
    var position: usize = 8;
    for (0..@as(usize, @intCast(count))) |i| {
        const marker = region[position];
        if (marker != 255) {
            if (marker >= i) return error.MalformedInput;
            try advance(&position, 8);
        } else {
            const length = le.getLe(u64, region[position + 80 ..][0..8]);
            if (length > MAX_ACCOUNT_DATA) return error.Capacity;
            try advance(&position, 88 + @as(usize, @intCast(length)) + input.MAX_PERMITTED_DATA_INCREASE);
            try advance(&position, (8 - position % 8) % 8);
            try advance(&position, 8);
        }
    }
    const instruction_length = le.getLe(u64, region[position..][0..8]);
    if (instruction_length > MAX_INSTRUCTION_DATA) return error.Capacity;
    try advance(&position, 8 + @as(usize, @intCast(instruction_length)) + 32);
    return position;
}
pub inline fn runWithClock(comptime capacity: usize, comptime processor: Processor, comptime Clock: type, region: [*]u8) u64 {
    comptime {
        if (capacity > input.MAX_ACCOUNTS) @compileError("too many account descriptors");
    }
    const length = measureTrusted(region, capacity) catch |err| return switch (err) {
        error.TooManyAccounts, error.Capacity => errors.builtin(.invalid_argument),
        error.MalformedInput => errors.builtin(.invalid_account_data),
    };
    var accounts: [capacity]input.AccountInfo = undefined;
    const parsed = input.parseInto(region[0..length], &accounts) catch |err| return switch (err) {
        error.TooManyAccounts => errors.builtin(.invalid_argument),
        error.NonCanonical => errors.builtin(.invalid_account_data),
        error.Truncated, error.MalformedInput => errors.builtin(.invalid_instruction_data),
    };
    const slot = Clock.currentSlot() catch return errors.builtin(.unsupported_sysvar);
    return processor(&parsed, slot);
}
pub inline fn run(comptime capacity: usize, comptime processor: Processor, region: [*]u8) u64 {
    return runWithClock(capacity, processor, clock.Runtime, region);
}
