//! OS cryptographic entropy into caller-owned buffers (Layer 1).
//! Windows uses the system-preferred BCrypt RNG. Linux uses getrandom without
//! GRND_RANDOM/GRND_NONBLOCK, waiting for initialized kernel entropy. There is
//! no deterministic seed, clock fallback, userspace PRNG or heap allocation.
const std = @import("std");
const builtin = @import("builtin");
const Win = struct {
    extern "bcrypt" fn BCryptGenRandom(?*anyopaque, [*]u8, u32, u32) callconv(.c) i32;
};
pub const Error = error{ UnsupportedPlatform, EntropyUnavailable };

/// Fill every byte or fail closed. On error all output bytes are cleared, so a
/// caller cannot accidentally use partial entropy. Empty buffers always succeed.
pub fn fill(output: []u8) Error!void {
    errdefer @memset(output, 0);
    var done: usize = 0;
    while (done < output.len) {
        if (builtin.os.tag == .windows) {
            const count: u32 = @intCast(@min(output.len - done, 0xffffffff));
            const status = Win.BCryptGenRandom(null, output[done..].ptr, count, 2); // BCRYPT_USE_SYSTEM_PREFERRED_RNG
            if (status < 0) return error.EntropyUnavailable;
            done += count;
        } else if (builtin.os.tag == .linux) {
            // Small urandom-source requests have the strongest getrandom
            // completion guarantees once initialized. Handle short reads and
            // EINTR anyway, rather than accepting uninitialized tail bytes.
            const count = @min(output.len - done, 256);
            const rc = std.os.linux.getrandom(output[done..].ptr, count, 0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0 or rc > count) return error.EntropyUnavailable;
                    done += rc;
                },
                .INTR => continue,
                else => return error.EntropyUnavailable,
            }
        } else return error.UnsupportedPlatform;
    }
}
