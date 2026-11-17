//! @zpm/ps5 libkernel — the PS5's kernel library, written in Sig: what a
//! game calls for files, memory, time and its own threads, each answered by
//! a system call to a kernel that speaks the PS5's ABI (abi.sig, sys.sig).
//!
//! A game imports these by NID from the library `libkernel` (and its POSIX
//! names from `libScePosix`, the same code under another library name).
//! `find` is what a linker's host asks: a library name and a NID in, the
//! function's address out.
//!
//! Two families, as on the console:
//!   - POSIX names (`write`, `open`, `clock_gettime`): -1 and `errno`;
//!   - `sceKernel` names: 0 or a result, or an error as 0x80020000 + errno.
//!
//! This is a first set: enough for a program to print, read a file, map
//! memory, tell the time and exit. Every function here does what it says;
//! one that is missing is simply not in the table (the runtime binds a
//! stand-in that says so when called).
//!
//! No Sony code: the names and behaviour are the public SDK surface as open
//! projects document it. x86-64 only. Allocation-free.

const std = @import("std");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const nid = @import("nid.sig");

const S = abi.Sys;
const E = abi.E;

// ── A thread's own state ────────────────────────────────────────────────────

/// What libkernel keeps for each thread; the thread's control block (FS)
/// points at it from its third word.
pub const Thread = extern struct {
    errno: c_int = 0,
    _pad: c_int = 0,
    /// The kernel's id for it.
    tid: i64 = 0,
};

/// The control block FS points at: itself, the thread's storage vector,
/// its Thread (FreeBSD's layout, which a game's own code reads: `fs:0`).
pub const Tcb = extern struct {
    self: u64,
    dtv: u64 = 0,
    thread: u64,
};

var early: Thread = .{};

/// Set by the runtime once the first thread has its control block: from
/// then on every thread has one before it runs a game's code.
pub var threads_ready: bool = false;

/// The calling thread's state (before the first control block exists: one
/// shared block, for the code that runs first).
pub fn thread() *Thread {
    if (!threads_ready) return &early;
    const t = sys.fs16();
    return if (t == 0) &early else @ptrFromInt(t);
}

// ── What the runtime tells it ───────────────────────────────────────────────

/// The game's own folder, which it knows as /app0 (no trailing slash).
pub var app0: []const u8 = "";
/// When the process started, on the monotonic clock (µs).
pub var started_us: u64 = 0;
/// `__tls_get_addr`'s answer: the runtime knows where each module's
/// thread storage is.
pub var tls_address: ?*const fn (module: u64, offset: u64) callconv(.c) usize = null;

/// Two objects a program's start code reads straight from libkernel (it
/// imports the variables themselves, not functions): the program's name,
/// and its environment, which is empty here.
pub var progname: [*:0]const u8 = "eboot.bin";
var no_environment = [_]?[*:0]u8{null};
pub var environ: [*]?[*:0]u8 = &no_environment;

/// Call once, before the game runs.
pub fn init() void {
    started_us = monotonicUs();
    var seed: [8]u8 = undefined;
    var len: u64 = seed.len;
    var mib = [_]i32{ abi.CTL.KERN, abi.CTL.KERN_ARND };
    if (sys.call(S.__sysctl, @intFromPtr(&mib), 2, @intFromPtr(&seed), @intFromPtr(&len), 0, 0) == 0) {
        // (a canary never has a zero first byte: a string copy stops at it)
        seed[0] = 0;
        stack_chk_guard = std.mem.readInt(u64, &seed, .little);
    }
}

// ── Results ─────────────────────────────────────────────────────────────────

/// A call's result the POSIX way: -1 and errno for a failure.
fn posix(r: i64) i64 {
    if (r < 0) {
        thread().errno = @intCast(-r);
        return -1;
    }
    return r;
}

/// A call's result Sony's way: an error is 0x80020000 + errno, as a
/// negative 32-bit number.
fn sce(r: i64) i64 {
    if (r < 0) return sceError(@intCast(-r));
    return r;
}

pub fn sceError(e: u32) i64 {
    return @as(i32, @bitCast(abi.SCE_KERNEL_ERROR_BASE + e));
}

fn monotonicUs() u64 {
    var ts: abi.Timespec = .{};
    _ = sys.call(S.clock_gettime, abi.CLOCK.MONOTONIC, @intFromPtr(&ts), 0, 0, 0, 0);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

// ── Files ───────────────────────────────────────────────────────────────────

/// A game's path as this computer's: /app0 is the game's own folder.
/// Null when the result does not fit.
pub fn hostPath(path: [*:0]const u8, buf: *[1024]u8) ?[*:0]const u8 {
    const p = std.mem.span(path);
    const prefix = "/app0";
    if (app0.len != 0 and std.mem.startsWith(u8, p, prefix) and (p.len == prefix.len or p[prefix.len] == '/')) {
        const rest = p[prefix.len..];
        if (app0.len + rest.len + 1 > buf.len) return null;
        @memcpy(buf[0..app0.len], app0);
        @memcpy(buf[app0.len..][0..rest.len], rest);
        buf[app0.len + rest.len] = 0;
        return @ptrCast(buf);
    }
    return path;
}

fn openRaw(path: ?[*:0]const u8, flags: c_int, mode: c_int) i64 {
    const given = path orelse return -@as(i64, E.FAULT);
    var buf: [1024]u8 = undefined;
    const p = hostPath(given, &buf) orelse return -@as(i64, E.NAMETOOLONG);
    return sys.call(S.open, @intFromPtr(p), @as(u32, @bitCast(flags)), @as(u32, @bitCast(mode)), 0, 0, 0);
}

fn fd64(fd: c_int) u64 {
    return @bitCast(@as(i64, fd));
}

fn open(path: ?[*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int {
    return @intCast(posix(openRaw(path, flags, mode)));
}
fn sceKernelOpen(path: ?[*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int {
    return @intCast(sce(openRaw(path, flags, mode)));
}
fn close(fd: c_int) callconv(.c) c_int {
    return @intCast(posix(sys.call(S.close, fd64(fd), 0, 0, 0, 0, 0)));
}
fn sceKernelClose(fd: c_int) callconv(.c) c_int {
    return @intCast(sce(sys.call(S.close, fd64(fd), 0, 0, 0, 0, 0)));
}
fn read(fd: c_int, buf: ?*anyopaque, n: usize) callconv(.c) isize {
    return posix(sys.call(S.read, fd64(fd), @intFromPtr(buf), n, 0, 0, 0));
}
fn sceKernelRead(fd: c_int, buf: ?*anyopaque, n: usize) callconv(.c) isize {
    return sce(sys.call(S.read, fd64(fd), @intFromPtr(buf), n, 0, 0, 0));
}
fn write(fd: c_int, buf: ?*const anyopaque, n: usize) callconv(.c) isize {
    return posix(sys.call(S.write, fd64(fd), @intFromPtr(buf), n, 0, 0, 0));
}
fn sceKernelWrite(fd: c_int, buf: ?*const anyopaque, n: usize) callconv(.c) isize {
    return sce(sys.call(S.write, fd64(fd), @intFromPtr(buf), n, 0, 0, 0));
}
fn lseek(fd: c_int, offset: i64, whence: c_int) callconv(.c) i64 {
    return posix(sys.call(S.lseek, fd64(fd), @bitCast(offset), @as(u32, @bitCast(whence)), 0, 0, 0));
}
fn sceKernelLseek(fd: c_int, offset: i64, whence: c_int) callconv(.c) i64 {
    return sce(sys.call(S.lseek, fd64(fd), @bitCast(offset), @as(u32, @bitCast(whence)), 0, 0, 0));
}

// ── The process ─────────────────────────────────────────────────────────────

fn _exit(code: c_int) callconv(.c) noreturn {
    _ = sys.call(S.exit, @as(u32, @bitCast(code)), 0, 0, 0, 0, 0);
    while (true) {}
}

fn getpid() callconv(.c) c_int {
    return @intCast(sys.call(S.getpid, 0, 0, 0, 0, 0, 0));
}

fn __error() callconv(.c) *c_int {
    return &thread().errno;
}

/// Not a PS4 Pro ("Neo"): a game picks its base console's settings.
fn sceKernelIsNeoMode() callconv(.c) c_int {
    return 0;
}

fn sched_yield() callconv(.c) c_int {
    return @intCast(posix(sys.call(S.sched_yield, 0, 0, 0, 0, 0, 0)));
}

/// The stack protector's canary (a game's code compares against it), set
/// from the kernel's random bytes by `init`.
var stack_chk_guard: u64 = 0x595e_9fbd_94fd_a700;

fn __stack_chk_fail() callconv(.c) noreturn {
    const msg = "[ps5] a stack protector's canary was overwritten: stopping\n";
    _ = sys.call(S.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
    _exit(134);
}

const TlsIndex = extern struct { module: u64, offset: u64 };

fn __tls_get_addr(ti: *const TlsIndex) callconv(.c) usize {
    const f = tls_address orelse return 0;
    return f(ti.module, ti.offset);
}

// ── Time ────────────────────────────────────────────────────────────────────

fn sleepUs(us: u64) i64 {
    var left = abi.Timespec{ .sec = @intCast(us / 1_000_000), .nsec = @intCast((us % 1_000_000) * 1000) };
    // (a signal ends the sleep early: what is left is slept again)
    while (true) {
        var rem: abi.Timespec = .{};
        const r = sys.call(S.nanosleep, @intFromPtr(&left), @intFromPtr(&rem), 0, 0, 0, 0);
        if (r != -@as(i64, E.INTR)) return r;
        if (rem.sec == 0 and rem.nsec == 0) return 0;
        left = rem;
    }
}

fn usleep(us: c_uint) callconv(.c) c_int {
    return @intCast(posix(sleepUs(us)));
}
fn sceKernelUsleep(us: c_uint) callconv(.c) c_int {
    return @intCast(sce(sleepUs(us)));
}
fn sceKernelSleep(seconds: c_uint) callconv(.c) c_int {
    return @intCast(sce(sleepUs(@as(u64, seconds) * 1_000_000)));
}
fn nanosleep(req: ?*const abi.Timespec, rem: ?*abi.Timespec) callconv(.c) c_int {
    return @intCast(posix(sys.call(S.nanosleep, @intFromPtr(req), @intFromPtr(rem), 0, 0, 0, 0)));
}
fn sceKernelNanosleep(req: ?*const abi.Timespec, rem: ?*abi.Timespec) callconv(.c) c_int {
    return @intCast(sce(sys.call(S.nanosleep, @intFromPtr(req), @intFromPtr(rem), 0, 0, 0, 0)));
}
fn clock_gettime(id: c_int, ts: ?*abi.Timespec) callconv(.c) c_int {
    return @intCast(posix(sys.call(S.clock_gettime, @as(u32, @bitCast(id)), @intFromPtr(ts), 0, 0, 0, 0)));
}
fn sceKernelClockGettime(id: c_int, ts: ?*abi.Timespec) callconv(.c) c_int {
    return @intCast(sce(sys.call(S.clock_gettime, @as(u32, @bitCast(id)), @intFromPtr(ts), 0, 0, 0, 0)));
}
fn gettimeofday(tv: ?*anyopaque, tz: ?*anyopaque) callconv(.c) c_int {
    return @intCast(posix(sys.call(S.gettimeofday, @intFromPtr(tv), @intFromPtr(tz), 0, 0, 0, 0)));
}
fn sceKernelGettimeofday(tv: ?*anyopaque) callconv(.c) c_int {
    return @intCast(sce(sys.call(S.gettimeofday, @intFromPtr(tv), 0, 0, 0, 0, 0)));
}

/// Microseconds since the process started.
fn sceKernelGetProcessTime() callconv(.c) u64 {
    return monotonicUs() -% started_us;
}

fn sceKernelReadTsc() callconv(.c) u64 {
    return sys.rdtsc();
}

var tsc_hz: u64 = 0;

/// The time stamp counter's rate, measured once against the monotonic
/// clock over 20 ms.
fn sceKernelGetTscFrequency() callconv(.c) u64 {
    if (@atomicLoad(u64, &tsc_hz, .acquire) == 0) {
        const t0 = monotonicUs();
        const c0 = sys.rdtsc();
        _ = sleepUs(20_000);
        const dt = monotonicUs() -% t0;
        const dc = sys.rdtsc() -% c0;
        @atomicStore(u64, &tsc_hz, if (dt == 0) 1 else @intCast(@as(u128, dc) * 1_000_000 / dt), .release);
    }
    return tsc_hz;
}

// ── Memory ──────────────────────────────────────────────────────────────────

const NO_FD: u64 = ~@as(u64, 0);

fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) callconv(.c) usize {
    const r = sys.call(S.mmap, @intFromPtr(addr), len, @as(u32, @bitCast(prot)), @as(u32, @bitCast(flags)), fd64(fd), @bitCast(offset));
    if (r < 0) {
        thread().errno = @intCast(-r);
        return ~@as(usize, 0); // MAP_FAILED
    }
    return @intCast(r);
}

fn munmap(addr: ?*anyopaque, len: usize) callconv(.c) c_int {
    return @intCast(posix(sys.call(S.munmap, @intFromPtr(addr), len, 0, 0, 0, 0)));
}
fn sceKernelMunmap(addr: ?*anyopaque, len: usize) callconv(.c) c_int {
    return @intCast(sce(sys.call(S.munmap, @intFromPtr(addr), len, 0, 0, 0, 0)));
}

/// Memory from the process's own (not "direct") share: anonymous pages at
/// or near *addr, whose address comes back through it.
fn sceKernelMapFlexibleMemory(addr: ?*usize, len: usize, prot: c_int, flags: c_int) callconv(.c) c_int {
    const at = addr orelse return @intCast(sceError(E.INVAL));
    if (len == 0 or len % abi.PAGE != 0) return @intCast(sceError(E.INVAL));
    // (the flags a game may pass: fixed, no overwrite, no coalesce)
    const keep = @as(u32, @bitCast(flags)) & (abi.MAP.FIXED | abi.MAP.NO_OVERWRITE);
    const r = sys.call(S.mmap, at.*, len, @as(u32, @bitCast(prot)) & (abi.PROT.CPU_MASK | abi.PROT.GPU_READ | abi.PROT.GPU_WRITE), keep | abi.MAP.ANON | abi.MAP.PRIVATE, NO_FD, 0);
    if (r < 0) return @intCast(sce(r));
    at.* = @intCast(r);
    return 0;
}

// ── The table ───────────────────────────────────────────────────────────────

fn entry(comptime name: []const u8, comptime f: anytype) struct { []const u8, *const anyopaque } {
    return .{ name, @ptrCast(f) };
}

/// Every name this libkernel answers, by NID.
pub const exports = nid.Table(*const anyopaque, &.{
    entry("open", &open),
    entry("sceKernelOpen", &sceKernelOpen),
    entry("close", &close),
    entry("sceKernelClose", &sceKernelClose),
    entry("read", &read),
    entry("sceKernelRead", &sceKernelRead),
    entry("write", &write),
    entry("sceKernelWrite", &sceKernelWrite),
    entry("lseek", &lseek),
    entry("sceKernelLseek", &sceKernelLseek),
    entry("_exit", &_exit),
    entry("getpid", &getpid),
    entry("__error", &__error),
    entry("sceKernelIsNeoMode", &sceKernelIsNeoMode),
    entry("sched_yield", &sched_yield),
    entry("__stack_chk_guard", &stack_chk_guard),
    entry("__stack_chk_fail", &__stack_chk_fail),
    entry("__tls_get_addr", &__tls_get_addr),
    entry("__progname", &progname),
    entry("environ", &environ),
    entry("usleep", &usleep),
    entry("sceKernelUsleep", &sceKernelUsleep),
    entry("sceKernelSleep", &sceKernelSleep),
    entry("nanosleep", &nanosleep),
    entry("sceKernelNanosleep", &sceKernelNanosleep),
    entry("clock_gettime", &clock_gettime),
    entry("sceKernelClockGettime", &sceKernelClockGettime),
    entry("gettimeofday", &gettimeofday),
    entry("sceKernelGettimeofday", &sceKernelGettimeofday),
    entry("sceKernelGetProcessTime", &sceKernelGetProcessTime),
    entry("sceKernelReadTsc", &sceKernelReadTsc),
    entry("sceKernelGetTscFrequency", &sceKernelGetTscFrequency),
    entry("mmap", &mmap),
    entry("munmap", &munmap),
    entry("sceKernelMunmap", &sceKernelMunmap),
    entry("sceKernelMapFlexibleMemory", &sceKernelMapFlexibleMemory),
});

/// Whether a library name is one of libkernel's: its own, its POSIX face,
/// or one of the variants a game may name (`libkernel_unity` and the like).
pub fn provides(library: []const u8) bool {
    return std.mem.eql(u8, library, "libkernel") or std.mem.eql(u8, library, "libScePosix") or
        std.mem.startsWith(u8, library, "libkernel_");
}

/// The address of a libkernel symbol, by the library a game named and its
/// NID; null when this libkernel does not have it.
pub fn find(library: []const u8, n: nid.Nid) ?u64 {
    if (!provides(library)) return null;
    const p = exports.find(n) orelse return null;
    return @intFromPtr(p);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "names resolve by NID under each of libkernel's library names" {
    try std.testing.expect(find("libkernel", nid.of("write")) != null);
    try std.testing.expect(find("libScePosix", nid.of("write")) != null);
    try std.testing.expect(find("libkernel_unity", nid.of("sceKernelUsleep")) != null);
    try std.testing.expectEqual(find("libkernel", nid.of("write")), find("libScePosix", nid.of("write")));
    try std.testing.expect(find("libkernel", nid.of("write")) != find("libkernel", nid.of("sceKernelWrite")));
    // (not this library's, and not a name it has)
    try std.testing.expectEqual(@as(?u64, null), find("libSceVideoOut", nid.of("write")));
    try std.testing.expectEqual(@as(?u64, null), find("libkernel", nid.of("sceKernelNoSuchFunction")));
    // The published NID of `write`, to be sure the table is keyed as games ask.
    try std.testing.expect(find("libkernel", nid.parse("FN4gaPmuFV8").?) != null);
}

test "Sony's error numbers" {
    try std.testing.expectEqual(@as(i64, @as(i32, @bitCast(@as(u32, 0x8002_0002)))), sceError(E.NOENT));
    try std.testing.expect(sceError(E.NOENT) < 0);
}

test "a game's /app0 is its own folder" {
    app0 = "/games/hello";
    defer app0 = "";
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("/games/hello/data/a.bin", std.mem.span(hostPath("/app0/data/a.bin", &buf).?));
    try std.testing.expectEqualStrings("/games/hello", std.mem.span(hostPath("/app0", &buf).?));
    // (another path, and one that only begins the same way, are left alone)
    try std.testing.expectEqualStrings("/dev/null", std.mem.span(hostPath("/dev/null", &buf).?));
    try std.testing.expectEqualStrings("/app01/x", std.mem.span(hostPath("/app01/x", &buf).?));
}
