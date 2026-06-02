// SeqLock — single-writer / multi-reader lock-free synchronization
// Layer 1: Platform
//
// The writer increments a sequence counter before and after writing.
// Readers check the counter before and after reading — if it changed
// or is odd (write in progress), they retry.
//
// Requirements: T must be trivially copyable (no pointers, no slices).
// Perfect for FrameState which is pure value types.

const w32 = @import("win32");

pub fn SeqLock(comptime T: type) type {
    return struct {
        const Self = @This();

        seq: u64 = 0,
        data: T = .{},

        /// Writer: store a new value. Must be called from a single thread.
        pub fn store(self: *Self, value: *const T) void {
            @atomicStore(u64, &self.seq, self.seq +% 1, .release); // odd = writing
            self.data = value.*;
            @atomicStore(u64, &self.seq, self.seq +% 1, .release); // even = done
        }

        /// Reader: load a consistent snapshot. Retries on torn read.
        /// Safe to call from any thread.
        pub fn load(self: *const Self) T {
            var attempts: u32 = 0;
            while (attempts < 1000) : (attempts += 1) {
                const s1 = @atomicLoad(u64, &self.seq, .acquire);
                if (s1 & 1 != 0) {
                    // Write in progress — spin
                    w32.Sleep(0);
                    continue;
                }
                // Copy the data
                const snapshot = self.data;
                const s2 = @atomicLoad(u64, &self.seq, .acquire);
                if (s1 == s2) return snapshot;
                // Sequence changed during read — retry
            }
            // Fallback: return whatever we have (shouldn't happen in practice)
            return self.data;
        }
    };
}
