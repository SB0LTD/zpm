//! Layer 1: authenticated runtime Clock. A lookup error never becomes a fake slot.
const syscalls = @import("solana_syscalls");
const base58 = @import("solana_base58");
pub const ClockRaw = extern struct {
    slot: u64,
    epoch_start_timestamp: i64,
    epoch: u64,
    leader_schedule_epoch: u64,
    unix_timestamp: i64,
};
pub const Error = error{Unavailable};
pub const CLOCK_ID: [32]u8 = blk: {
    @setEvalBranchQuota(20000);
    var key: [32]u8 = undefined;
    base58.decodeKey("SysvarC1ock" ++ "1" ** 32, &key) catch @compileError("invalid Clock sysvar ID");
    break :blk key;
};
comptime {
    if (@sizeOf(ClockRaw) != 40) @compileError("Clock ABI must be 40 bytes");
}
pub fn API(comptime Backend: type) type {
    return struct {
        pub inline fn getClock() Error!ClockRaw {
            var value: ClockRaw = undefined;
            var key = CLOCK_ID;
            if (Backend.sol_get_sysvar(&key, @ptrCast(&value), 0, @sizeOf(ClockRaw)) != 0) return error.Unavailable;
            return value;
        }
        pub inline fn currentSlot() Error!u64 {
            return (try getClock()).slot;
        }
    };
}
pub const Runtime = API(syscalls.Native);
