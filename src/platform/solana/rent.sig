//! Rent minimum from native serialized sysvar; integer-only supported thresholds.
const le = @import("solana_le");
const base58 = @import("solana_base58");
const sys = @import("solana_syscalls");
pub const Error = error{ Unavailable, UnsupportedThreshold, Capacity };
noinline fn maximumRate(bytes: u64) u64 {
    return ~@as(u64, 0) / bytes;
}
pub const RENT_ID: [32]u8 = blk: {
    @setEvalBranchQuota(20000);
    var key: [32]u8 = undefined;
    base58.decodeKey("SysvarRent111111111111111111111111111111111", &key) catch @compileError("Invalid rent id");
    break :blk key;
};
pub fn minimumFromBytes(raw: *const [17]u8, data_len: usize) Error!u64 {
    if (data_len > 10 * 1024 * 1024) return error.Capacity;
    const bits = le.getLe(u64, raw[8..16]);
    const multiplier: u64 = switch (bits) {
        0x3ff0000000000000 => 1,
        0x4000000000000000 => 2,
        else => return error.UnsupportedThreshold,
    };
    const bytes = (@as(u64, @intCast(data_len)) + 128) *% multiplier;
    const rate = le.getLe(u64, raw[0..8]);
    if (rate > maximumRate(bytes)) return error.Capacity;
    // Overflow was checked above; wrapping form avoids a BPF i128 mul helper.
    return rate *% bytes;
}
pub fn API(comptime Backend: type) type {
    return struct {
        pub noinline fn minimumBalance(data_len: usize, output: *u64) Error!void {
            var raw: [17]u8 = undefined;
            var key = RENT_ID;
            if (Backend.sol_get_sysvar(&key, &raw, 0, raw.len) != 0) return error.Unavailable;
            output.* = try minimumFromBytes(&raw, data_len);
        }
    };
}
pub const Runtime = API(sys.Native);
