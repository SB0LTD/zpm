//! Joined OS workers with caller-owned control blocks. No language heap.
//! Windows owns native thread stacks; Linux's no-libc Thread implementation
//! maps its stack/TLS directly. libc pthread implementations are deliberately
//! excluded because their allocation contract is outside our control.
const std = @import("std");
const builtin = @import("builtin");
pub const available = builtin.os.tag == .windows or (builtin.os.tag == .linux and !builtin.link_libc);
const Win = struct {
    extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, ?*anyopaque, u32, ?*u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) c_int;
    extern "ntdll" fn RtlAcquireSRWLockExclusive(*usize) callconv(.winapi) void;
    extern "ntdll" fn RtlTryAcquireSRWLockExclusive(*usize) callconv(.winapi) u8;
    extern "ntdll" fn RtlReleaseSRWLockExclusive(*usize) callconv(.winapi) void;
    extern "ntdll" fn RtlWaitOnAddress(*const anyopaque, *const anyopaque, usize, *const i64) callconv(.winapi) i32;
    extern "ntdll" fn RtlWakeAddressAll(*const anyopaque) callconv(.winapi) void;
};
pub const Entry = *const fn (?*anyopaque) void;
pub const Error = error{ UnsupportedPlatform, AlreadyStarted, ThreadCreationFailed, ThreadJoinFailed };

/// Must remain at a stable address until join returns. The context must also
/// outlive join. No detach operation: ownership never escapes the caller.
pub const Thread = struct {
    handle: if (builtin.os.tag == .windows) ?*anyopaque else ?std.Thread = null,
    entry: Entry = undefined,
    context: ?*anyopaque = null,

    fn run(self: *Thread) void { self.entry(self.context); }
    fn windowsEntry(raw: ?*anyopaque) callconv(.winapi) u32 {
        const self: *Thread = @ptrCast(@alignCast(raw.?));
        self.run();
        return 0;
    }
    pub fn start(self: *Thread, entry: Entry, context: ?*anyopaque) Error!void {
        if (!available) return error.UnsupportedPlatform;
        if (self.handle != null) return error.AlreadyStarted;
        self.entry = entry;
        self.context = context;
        if (builtin.os.tag == .windows) {
            // STACK_SIZE_PARAM_IS_A_RESERVATION; commit grows through OS faults.
            self.handle = Win.CreateThread(null, 4 * 1024 * 1024, &windowsEntry, self, 0x10000, null) orelse return error.ThreadCreationFailed;
        } else if (builtin.os.tag == .linux and !builtin.link_libc) {
            self.handle = std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, run, .{self}) catch return error.ThreadCreationFailed;
        }
    }
    /// A failed native wait retains ownership. Never close a live thread handle.
    pub fn join(self: *Thread) Error!void {
        if (self.handle) |handle| {
            if (builtin.os.tag == .windows) {
                if (Win.WaitForSingleObject(handle, 0xffffffff) != 0) return error.ThreadJoinFailed;
                if (Win.CloseHandle(handle) == 0) return error.ThreadJoinFailed;
            } else if (builtin.os.tag == .linux and !builtin.link_libc) handle.join();
            self.handle = null;
        }
    }
};

/// Bounded relative wait; callers must re-check their predicate in a loop.
/// The compare-and-sleep operation prevents a notification before sleep from
/// being lost. Spurious wakeups, interrupts and timeouts are all permitted.
pub fn waitForChange(word: *const std.atomic.Value(u32), expected: u32, timeout_ms: u32) void {
    if (word.load(.acquire) != expected or timeout_ms == 0) return;
    if (builtin.os.tag == .windows) {
        const timeout = -@as(i64, timeout_ms) * 10000;
        _ = Win.RtlWaitOnAddress(word, &expected, @sizeOf(u32), &timeout);
    } else if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const timeout: linux.timespec = .{ .sec = @intCast(timeout_ms / 1000), .nsec = @intCast((timeout_ms % 1000) * 1000000) };
        _ = linux.futex_4arg(word, .{ .cmd = .WAIT, .private = true }, expected, &timeout);
    } else std.atomic.spinLoopHint();
}

pub fn wakeAll(word: *const std.atomic.Value(u32)) void {
    if (builtin.os.tag == .windows) Win.RtlWakeAddressAll(word)
    else if (builtin.os.tag == .linux) {
        _ = std.os.linux.futex_3arg(word, .{ .cmd = .WAKE, .private = true }, 0x7fffffff);
    }
}

/// Publication epoch. Read the epoch, check the predicate, then wait using that
/// epoch. Publish data before notify; the predicate itself still needs ownership
/// or atomic access. Counter wrap does not replace a predicate check.
pub const Signal = struct {
    epoch: std.atomic.Value(u32) = .init(0),
    pub fn notify(self: *Signal) void { _ = self.epoch.fetchAdd(1, .release); wakeAll(&self.epoch); }
    pub fn wait(self: *Signal, expected: u32, timeout_ms: u32) void { waitForChange(&self.epoch, expected, timeout_ms); }
};

/// Non-recursive mutex. Linux states: 0 free, 1 held without known waiters,
/// 2 contended. All contended acquisitions preserve state 2 until unlock.
pub const Mutex = struct {
    native: if (builtin.os.tag == .windows) usize else std.atomic.Value(u32) = if (builtin.os.tag == .windows) 0 else .init(0),
    pub fn tryLock(self: *Mutex) bool {
        if (builtin.os.tag == .windows) return Win.RtlTryAcquireSRWLockExclusive(&self.native) != 0;
        return self.native.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }
    pub fn lock(self: *Mutex) void {
        if (builtin.os.tag == .windows) { Win.RtlAcquireSRWLockExclusive(&self.native); return; }
        if (self.native.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (self.native.swap(2, .acquire) != 0) waitForChange(&self.native, 2, 1000);
    }
    pub fn unlock(self: *Mutex) void {
        if (builtin.os.tag == .windows) { Win.RtlReleaseSRWLockExclusive(&self.native); return; }
        if (self.native.swap(0, .release) == 2) wakeAll(&self.native);
    }
};
