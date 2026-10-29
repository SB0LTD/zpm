//! Layer 1: Solana static syscalls plus bounded, injectable marshalling wrappers.
//! The native declarations are loader-resolved, with no host library dependency.
pub const SolBytes = extern struct { ptr: [*]const u8, len: u64 };
pub const MAX_HASH_CHUNKS = 16;
pub const MAX_SEEDS = 16;
pub const MAX_SEED_LEN = 32;
pub const MAX_RETURN_DATA = 1024;
pub const Error = error{ Capacity, SeedTooLong, Failed };
pub const Native = struct {
    pub extern fn sol_log_(message: [*]const u8, length: u64) callconv(.c) void;
    pub extern fn sol_log_64_(a: u64, b: u64, c: u64, d: u64, e: u64) callconv(.c) void;
    pub extern fn sol_log_pubkey(key: *const [32]u8) callconv(.c) void;
    pub extern fn sol_log_compute_units_() callconv(.c) void;
    pub extern fn sol_sha256(chunks: [*]const SolBytes, count: u64, output: *[32]u8) callconv(.c) u64;
    pub extern fn sol_create_program_address(seeds: [*]const SolBytes, count: u64, program: *const [32]u8, output: *[32]u8) callconv(.c) u64;
    pub extern fn sol_try_find_program_address(seeds: [*]const SolBytes, count: u64, program: *const [32]u8, output: *[32]u8, bump: *u8) callconv(.c) u64;
    pub extern fn sol_get_sysvar(key: *const [32]u8, output: [*]u8, offset: u64, length: u64) callconv(.c) u64;
    pub extern fn sol_set_return_data(data: [*]const u8, length: u64) callconv(.c) void;
};
/// Backends are comptime namespaces, not runtime vtables or stored function pointers.
/// Outputs commit only on success; wrappers reject capacity violations before calling.
pub fn API(comptime Backend: type) type {
    return struct {
        pub fn log(message: []const u8) void {
            Backend.sol_log_(message.ptr, message.len);
        }
        pub fn log64(a: u64, b: u64, c: u64, d: u64, e: u64) void {
            Backend.sol_log_64_(a, b, c, d, e);
        }
        pub fn logPubkey(key: *const [32]u8) void {
            Backend.sol_log_pubkey(key);
        }
        pub fn logComputeUnits() void {
            Backend.sol_log_compute_units_();
        }
        pub fn sha256(chunks: []const []const u8, scratch: []SolBytes, output: *[32]u8) Error!void {
            if (chunks.len > MAX_HASH_CHUNKS or chunks.len > scratch.len) return error.Capacity;
            for (chunks, 0..) |chunk, i| scratch[i] = .{ .ptr = chunk.ptr, .len = chunk.len };
            var digest: [32]u8 = undefined;
            if (Backend.sol_sha256(scratch.ptr, chunks.len, &digest) != 0) return error.Failed;
            output.* = digest;
        }
        pub inline fn tryFindProgramAddress(seeds: []const []const u8, scratch: []SolBytes, program: *const [32]u8, output: *[32]u8) Error!u8 {
            if (seeds.len >= MAX_SEEDS or seeds.len > scratch.len) return error.Capacity;
            for (seeds, 0..) |seed, i| {
                if (seed.len > MAX_SEED_LEN) return error.SeedTooLong;
                scratch[i] = .{ .ptr = seed.ptr, .len = seed.len };
            }
            var address: [32]u8 = undefined;
            var bump: u8 = undefined;
            if (Backend.sol_try_find_program_address(scratch.ptr, seeds.len, program, &address, &bump) != 0) return error.Failed;
            output.* = address;
            return bump;
        }
        pub fn setReturnData(data: []const u8) Error!void {
            if (data.len > MAX_RETURN_DATA) return error.Capacity;
            Backend.sol_set_return_data(data.ptr, data.len);
        }
    };
}
pub const Runtime = API(Native);
