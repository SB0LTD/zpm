//! dxgtrace: every /dev/dxg ioctl a process makes, with the memory its
//! arguments point at (NVIDIA's private driver data included), recorded
//! from inside the process (LD_PRELOAD). For learning how NVIDIA's WSL
//! user-mode driver (/usr/lib/wsl/lib) creates its device, contexts,
//! queues and memory and how it submits work, so that zpm can drive the
//! GPU the same way (src/dxg).
//!
//!   sig build-lib -dynamic -target x86_64-linux-gnu -lc -OReleaseSafe -fPIC
//!     tools/dxgtrace.sig --name dxgtrace -femit-bin=libdxgtrace.so
//!   DXGTRACE_OUT=cuda.dxgt LD_PRELOAD=./libdxgtrace.so ./some-gpu-program
//!   python3 tools/dxgtrace_dump.py cuda.dxgt
//!
//! The ioctls are dxgkrnl's (WSL2-Linux-Kernel include/uapi/misc/d3dkmthk.h,
//! type 0x47): the layouts used here are restated from it (offsets checked
//! against the header with offsetof).
//!
//! Records (little endian): "DXGT", u32 kind, u32 ioctl number (low byte),
//! u32 sequence, u64 address, u32 length, i32 result (after the call;
//! 0 before it), then the bytes. Kinds:
//!   1 the argument before the call, 2 the argument after it,
//!   3 memory the argument points at, before, 4 the same after,
//!   5 a command buffer at submission (its GPU address translated through
//!     the allocations the process mapped and locked), 6 a note (text),
//!   9 an allocation's bytes before unlock2 (at its GPU address; the
//!     result field its handle).
//! Fixed buffers, no allocator.

const std = @import("std");
const linux = std.os.linux;

extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
const RTLD_NEXT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const IoctlFn = *const fn (c_int, c_ulong, usize) callconv(.c) c_int;
var real_ioctl: ?IoctlFn = null;

/// dlopen without RTLD_DEEPBIND (0x8): NVIDIA's video libraries are loaded
/// with it, which binds their ioctl to libc's past this library (the
/// trace then lost every call after them: 191 submissions of an encode's
/// 606 seen, its per-frame submit_command none).
const DlopenFn = *const fn (?[*:0]const u8, c_int) callconv(.c) ?*anyopaque;
var real_dlopen: ?DlopenFn = null;
const RTLD_DEEPBIND: c_int = 0x8;

export fn dlopen(file: ?[*:0]const u8, flags: c_int) callconv(.c) ?*anyopaque {
    if (real_dlopen == null) {
        const p = dlsym(RTLD_NEXT, "dlopen") orelse return null;
        real_dlopen = @ptrCast(p);
    }
    return real_dlopen.?(file, flags & ~RTLD_DEEPBIND);
}

const MAX_BLOB = 1 << 20;
const MAX_ALLOC = 4096;

var lock = std.atomic.Value(u32).init(0);
var out_fd: i32 = -2;
var seq: u32 = 0;
var fd_kind: [4096]u8 = [_]u8{0} ** 4096;

/// What the process told dxgkrnl about its allocations: a handle, the GPU
/// address it mapped it at (and how many bytes), the CPU address a lock
/// gave it.
const Alloc = struct { handle: u32 = 0, gpu: u64 = 0, bytes: u64 = 0, cpu: u64 = 0 };
var allocs: [MAX_ALLOC]Alloc = [_]Alloc{.{}} ** MAX_ALLOC;
var allocs_n: usize = 0;

// The ioctl numbers (low byte of _IOWR(0x47, nr, ...)).
const CREATE_CONTEXT_VIRTUAL = 0x04;
const CREATE_ALLOCATION = 0x06;
const QUERY_ADAPTER_INFO = 0x09;
const MAKE_RESIDENT = 0x0b;
const MAP_GPU_VA = 0x0c;
const ESCAPE = 0x0d;
const SUBMIT_COMMAND = 0x0f;
const ENUM_ADAPTERS2 = 0x14;
const CREATE_HW_QUEUE = 0x18;
const LOCK2 = 0x25;
const UNLOCK2 = 0x37;
const SUBMIT_TO_HW_QUEUE = 0x34;
const WAIT_FROM_CPU = 0x3a;
const ENUM_ADAPTERS3 = 0x3e;

/// A pointer field of an argument and how long the memory it points at
/// is: `len_off` names a u32 field holding a byte count (or an element
/// count, times `unit`); with no `len_off`, `unit` bytes.
const Follow = struct { nr: u8, ptr_off: u16, len_off: ?u16 = null, unit: u32 = 1 };
const FOLLOW = [_]Follow{
    .{ .nr = CREATE_CONTEXT_VIRTUAL, .ptr_off = 16, .len_off = 24 },
    .{ .nr = CREATE_ALLOCATION, .ptr_off = 16, .len_off = 24 },
    .{ .nr = CREATE_ALLOCATION, .ptr_off = 32, .len_off = 40 },
    .{ .nr = CREATE_ALLOCATION, .ptr_off = 48, .len_off = 44, .unit = 96 },
    .{ .nr = QUERY_ADAPTER_INFO, .ptr_off = 8, .len_off = 16 },
    .{ .nr = MAKE_RESIDENT, .ptr_off = 8, .len_off = 4, .unit = 4 },
    .{ .nr = ESCAPE, .ptr_off = 16, .len_off = 24 },
    .{ .nr = SUBMIT_COMMAND, .ptr_off = 288, .len_off = 296 },
    .{ .nr = ENUM_ADAPTERS2, .ptr_off = 8, .len_off = 0, .unit = 20 },
    .{ .nr = CREATE_HW_QUEUE, .ptr_off = 16, .len_off = 8 },
    .{ .nr = SUBMIT_TO_HW_QUEUE, .ptr_off = 32, .len_off = 28 },
    .{ .nr = WAIT_FROM_CPU, .ptr_off = 8, .len_off = 4, .unit = 4 },
    .{ .nr = WAIT_FROM_CPU, .ptr_off = 16, .len_off = 4, .unit = 8 },
    .{ .nr = ENUM_ADAPTERS3, .ptr_off = 16, .len_off = 8, .unit = 20 },
};

export fn ioctl(fd: c_int, req: c_ulong, arg: usize) callconv(.c) c_int {
    if (real_ioctl == null) {
        const p = dlsym(RTLD_NEXT, "ioctl") orelse return -1;
        real_ioctl = @ptrCast(p);
    }
    if (!isDxg(fd) or (req >> 8) & 0xff != 0x47 or arg == 0)
        return real_ioctl.?(fd, req, arg);
    while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    seq +%= 1;
    const my = seq;
    const nr: u8 = @truncate(req);
    const size: usize = @intCast((req >> 16) & 0x3fff);
    const a: [*]const u8 = @ptrFromInt(arg);
    record(1, nr, my, arg, a[0..size], 0);
    follow(3, nr, my, a[0..size], 0);
    if (nr == SUBMIT_COMMAND) submitted(nr, my, a, 0, 8);
    if (nr == UNLOCK2) unlocking(my, a);
    if (nr == SUBMIT_TO_HW_QUEUE) submitted(nr, my, a, 16, 24);
    lock.store(0, .release);
    if (nr == SUBMIT_TO_HW_QUEUE) snapSubmit();

    const rc = real_ioctl.?(fd, req, arg);

    while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer lock.store(0, .release);
    record(2, nr, my, arg, a[0..size], rc);
    follow(4, nr, my, a[0..size], rc);
    // (259: STATUS_PENDING, a map or residency the paging fence finishes)
    if (rc == 0 or rc == 259) learn(nr, a[0..size]);
    return rc;
}

/// DXGTRACE_SNAP_SUBMITS=N (with DXGTRACE_SNAP): a step at each of the
/// first N hardware-queue doorbells, so a program that marks nothing (a
/// GL demo through NVIDIA's D3D12 driver) leaves the pushbuffers it wrote
/// before each in the snapshots.
var snap_submits: u32 = 0;

fn snapSubmit() void {
    const v = getenv("DXGTRACE_SNAP_SUBMITS") orelse return;
    const most = std.fmt.parseInt(u32, std.mem.span(v), 10) catch return;
    if (snap_submits >= most) return;
    snap_submits += 1;
    var buf: [32]u8 = undefined;
    const t = std.fmt.bufPrint(buf[0 .. buf.len - 1], "submit {d}", .{snap_submits}) catch return;
    buf[t.len] = 0;
    dxgtrace_mark(@ptrCast(&buf));
}

/// A note in the trace from the traced program (cudaprobe calls it, found
/// by dlsym, before each step), so the trace can be cut at each step.
export fn dxgtrace_mark(text: [*:0]const u8) callconv(.c) void {
    while (lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer lock.store(0, .release);
    record(6, 0, seq, 0, std.mem.span(text), 0);
    // the process's memory map at each step (kind 6, number 1)
    const fd = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const f: isize = @bitCast(fd);
    if (f < 0) return;
    defer _ = linux.close(@intCast(f));
    var n: usize = 0;
    while (n < maps_buf.len) {
        const rc = linux.read(@intCast(f), maps_buf[n..].ptr, maps_buf.len - n);
        const r: isize = @bitCast(rc);
        if (r <= 0) break;
        n += @intCast(r);
    }
    record(6, 1, seq, 0, maps_buf[0..n], 0);
    if (getenv("DXGTRACE_SNAP") != null) snapshot(maps_buf[0..n]);
    if (getenv("DXGTRACE_WATCH")) |w| {
        if (guarded_n != 0) unwatch();
        if (std.mem.eql(u8, std.mem.span(w), std.mem.span(text))) watch(maps_buf[0..n]);
    }
}

// ── DXGTRACE_WATCH=STEP: every CPU write to shared memory after STEP ──────
// At the mark named STEP, every shared mapping (rw-s) becomes read-only;
// the first write to each page faults, is recorded (kind 8: the page, the
// faulting address and the instruction's address) and the page is made
// writable again. A doorbell (a register page that reads back nothing)
// shows up here even when a snapshot cannot see it.

const KSigaction = extern struct {
    handler: ?*const fn (c_int, *anyopaque, ?*anyopaque) callconv(.c) void,
    mask: [16]u64 = [_]u64{0} ** 16,
    flags: c_int,
    restorer: ?*anyopaque = null,
};
extern "c" fn sigaction(sig: c_int, act: *const KSigaction, old: ?*KSigaction) c_int;
extern "c" fn mprotect(addr: *anyopaque, len: usize, prot: c_int) c_int;
const PROT_READ = 1;
const PROT_WRITE = 2;
const SA_SIGINFO = 4;
const SIGSEGV = 11;

fn watch(maps: []const u8) void {
    const act: KSigaction = .{ .handler = onFault, .flags = SA_SIGINFO };
    _ = sigaction(SIGSEGV, &act, null);
    const trap: KSigaction = .{ .handler = onTrap, .flags = SA_SIGINFO };
    _ = sigaction(5, &trap, null); // SIGTRAP
    var it = std.mem.splitScalar(u8, maps, '\n');
    while (it.next()) |line| {
        if (line.len < 30 or std.mem.indexOf(u8, line, " rw-s ") == null) continue;
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const lo = std.fmt.parseInt(u64, line[0..dash], 16) catch continue;
        const hi = std.fmt.parseInt(u64, line[dash + 1 .. sp], 16) catch continue;
        if (hi <= lo or guarded_n == guarded.len) continue;
        if (mprotect(@ptrFromInt(lo), hi - lo, PROT_READ) == 0) {
            guarded[guarded_n] = .{ lo, hi };
            guarded_n += 1;
        }
    }
}
var guarded: [1024][2]u64 = undefined;
var guarded_n: usize = 0;
/// The page a write is being single-stepped through (0: none).
var stepping: u64 = 0;
var stepping_addr: u64 = 0;
var stepping_rip: u64 = 0;

/// The watch ends at the next step's mark.
fn unwatch() void {
    for (guarded[0..guarded_n]) |g| _ = mprotect(@ptrFromInt(g[0]), g[1] - g[0], PROT_READ | PROT_WRITE);
    guarded_n = 0;
}

/// After the single step: the value the instruction wrote (kind 8: the
/// address, the 8 bytes there now, the instruction), the page read-only
/// again.
fn onTrap(_: c_int, _: *anyopaque, uc: ?*anyopaque) callconv(.c) void {
    if (stepping == 0) return;
    if (uc) |u| {
        const c: [*]u8 = @ptrCast(u);
        const efl = std.mem.readInt(u64, c[176..184], .little);
        std.mem.writeInt(u64, c[176..184], efl & ~@as(u64, 0x100), .little);
    }
    var b: [24]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], stepping_addr, .little);
    const v: *align(1) const u64 = @ptrFromInt(stepping_addr & ~@as(u64, 7));
    std.mem.writeInt(u64, b[8..16], v.*, .little);
    std.mem.writeInt(u64, b[16..24], stepping_rip, .little);
    record(8, 0, seq, stepping, &b, 0);
    _ = mprotect(@ptrFromInt(stepping), 4096, PROT_READ);
    stepping = 0;
}

fn onFault(_: c_int, info: *anyopaque, uc: ?*anyopaque) callconv(.c) void {
    const si: [*]const u8 = @ptrCast(info);
    const addr = std.mem.readInt(u64, si[16..24], .little);
    var rip: u64 = 0;
    if (uc) |u| {
        const c: [*]const u8 = @ptrCast(u);
        rip = std.mem.readInt(u64, c[168..176], .little); // mcontext gregs[REG_RIP]
    }
    for (guarded[0..guarded_n]) |g| {
        if (addr < g[0] or addr >= g[1]) continue;
        // writable for one instruction (the trap flag), then onTrap
        stepping = addr & ~@as(u64, 4095);
        stepping_addr = addr;
        stepping_rip = rip;
        _ = mprotect(@ptrFromInt(stepping), 4096, PROT_READ | PROT_WRITE);
        if (uc) |u| {
            const c: [*]u8 = @ptrCast(u);
            const efl = std.mem.readInt(u64, c[176..184], .little);
            std.mem.writeInt(u64, c[176..184], efl | 0x100, .little);
        }
        return;
    }
    // not a page this tracer protected: the real fault, by default
    const dfl: KSigaction = .{ .handler = null, .flags = 0 };
    _ = sigaction(SIGSEGV, &dfl, null);
}

/// DXGTRACE_SNAP set: at each step, every 4 KiB page of the shared
/// mappings (rw-s, up to 256 MiB each) that is new or changed since the
/// last step (kind 7, address = the page), so the steps can be diffed:
/// what a step wrote into the command rings, their pointers and their
/// fences without a single ioctl.
fn snapshot(maps: []const u8) void {
    var it = std.mem.splitScalar(u8, maps, '\n');
    while (it.next()) |line| {
        if (line.len < 30 or std.mem.indexOf(u8, line, " rw-s ") == null) continue;
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const lo = std.fmt.parseInt(u64, line[0..dash], 16) catch continue;
        const hi = std.fmt.parseInt(u64, line[dash + 1 .. sp], 16) catch continue;
        if (hi <= lo or hi - lo > 256 << 20) continue;
        var a = lo;
        while (a < hi) : (a += 4096) {
            const m: [*]const u8 = @ptrFromInt(a);
            const h = std.hash.Wyhash.hash(0, m[0..4096]);
            const s = pageSlot(a) orelse continue;
            if (s.addr == a and s.hash == h) continue;
            s.* = .{ .addr = a, .hash = h };
            record(7, 0, seq, a, m[0..4096], 0);
        }
    }
}

const Page = struct { addr: u64 = 0, hash: u64 = 0 };
var pages: [1 << 18]Page = [_]Page{.{}} ** (1 << 18);

/// The page's place in the open-addressed table of page hashes.
fn pageSlot(a: u64) ?*Page {
    var i: usize = @intCast((a >> 12) *% 0x9e3779b97f4a7c15 >> 46);
    for (0..pages.len) |_| {
        if (pages[i].addr == a or pages[i].addr == 0) return &pages[i];
        i = (i + 1) & (pages.len - 1);
    }
    return null;
}
var maps_buf: [1 << 20]u8 = undefined;

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn follow(kind: u32, nr: u8, my: u32, arg: []const u8, rc: c_int) void {
    for (FOLLOW) |f| {
        if (f.nr != nr or arg.len < f.ptr_off + 8) continue;
        const p = rd64(arg, f.ptr_off);
        if (p == 0) continue;
        var len: u64 = f.unit;
        if (f.len_off) |lo| len = @as(u64, rd32(arg, lo)) * f.unit;
        if (len == 0 or len > MAX_BLOB) continue;
        const m: [*]const u8 = @ptrFromInt(p);
        record(kind, nr, my, p, m[0..@intCast(len)], rc);
        // each allocation's own private data
        if (nr == CREATE_ALLOCATION and f.ptr_off == 48) {
            var i: usize = 0;
            while (i < len) : (i += 96) {
                const info = m[i..][0..96];
                const pp = rd64(info, 16);
                const pl = rd32(info, 24);
                if (pp != 0 and pl != 0 and pl <= MAX_BLOB) {
                    const q: [*]const u8 = @ptrFromInt(pp);
                    record(kind, nr, my, pp, q[0..pl], rc);
                }
            }
        }
    }
}

/// The allocations' GPU and CPU addresses, from what dxgkrnl answered.
fn learn(nr: u8, arg: []const u8) void {
    switch (nr) {
        MAP_GPU_VA => {
            const a = slot(rd32(arg, 32)) orelse return;
            a.gpu = rd64(arg, 88);
            a.bytes = rd64(arg, 48) * 4096;
        },
        CREATE_HW_QUEUE => {
            if (queues_n == queues.len) return;
            const q = &queues[queues_n];
            q.* = .{
                .context = rd32(arg, 0),
                .handle = rd32(arg, 24),
                .progress_cpu = rd64(arg, 32),
                .progress_gpu = rd64(arg, 40),
            };
            // NVIDIA's private answer: the GPFIFO ring's GPU address
            // (+0x18) and its bytes (+0x20)
            const p = rd64(arg, 16);
            if (p != 0 and rd32(arg, 8) >= 0x28) {
                const m: [*]const u8 = @ptrFromInt(p);
                q.gpfifo_va = rd64(m[0..0x28], 0x18);
                q.gpfifo_bytes = rd32(m[0..0x28], 0x20);
            }
            queues_n += 1;
        },
        LOCK2 => {
            const a = slot(rd32(arg, 4)) orelse return;
            a.cpu = rd64(arg, 16);
        },
        CREATE_ALLOCATION => {
            const n = rd32(arg, 44);
            const p = rd64(arg, 48);
            if (p == 0 or n > 4096) return;
            const m: [*]const u8 = @ptrFromInt(p);
            for (0..n) |i| {
                const info = m[i * 96 ..][0..96];
                const a = slot(rd32(info, 0)) orelse continue;
                if (rd64(info, 8) != 0) a.cpu = rd64(info, 8);
                if (rd64(info, 40) != 0) a.gpu = rd64(info, 40);
            }
        },
        else => {},
    }
}

/// The hardware queues the process made: their context, handle, progress
/// fence (CPU and GPU addresses, from dxgkrnl) and GPFIFO ring (from
/// NVIDIA's private answer).
pub const Queue = extern struct {
    context: u32 = 0,
    handle: u32 = 0,
    progress_cpu: u64 = 0,
    progress_gpu: u64 = 0,
    gpfifo_va: u64 = 0,
    gpfifo_bytes: u64 = 0,
};
var queues: [64]Queue = [_]Queue{.{}} ** 64;
var queues_n: usize = 0;

/// For a program running under the tracer (tools/dxgsubmit.sig): the
/// i-th hardware queue, false past the last.
export fn dxgtrace_queue(i: u32, out: *Queue) callconv(.c) bool {
    if (i >= queues_n) return false;
    out.* = queues[i];
    return true;
}

/// For a program running under the tracer: the CPU address of a GPU
/// address, through the allocations made from the process's own memory
/// (0 when it is not one of them).
export fn dxgtrace_cpu(va: u64) callconv(.c) u64 {
    for (allocs[0..allocs_n]) |a| {
        if (a.gpu != 0 and a.cpu != 0 and va >= a.gpu and va < a.gpu + a.bytes) return a.cpu + (va - a.gpu);
    }
    return 0;
}

/// For a program running under the tracer: how many /dev/dxg ioctls so far.
export fn dxgtrace_count() callconv(.c) u32 {
    return seq;
}

/// Before unlock2 (d3dkmt_unlock2: device, allocation): what the process
/// wrote into the allocation through its lock (kind 9, at its GPU
/// address, up to 64 KiB): a legacy context's command buffer is written
/// so, then unlocked, then submitted (submit_command), so the bytes are
/// only readable here.
fn unlocking(my: u32, a: [*]const u8) void {
    const h = std.mem.readInt(u32, a[4..8], .little);
    for (allocs[0..allocs_n]) |*al| {
        if (al.handle != h or al.cpu == 0) continue;
        const n: usize = @intCast(@min(if (al.bytes != 0) al.bytes else 4096, 64 << 10));
        const p: [*]const u8 = @ptrFromInt(al.cpu);
        record(9, UNLOCK2, my, al.gpu, p[0..n], @bitCast(h));
        return;
    }
}

fn slot(handle: u32) ?*Alloc {
    if (handle == 0) return null;
    for (allocs[0..allocs_n]) |*a| if (a.handle == handle) return a;
    if (allocs_n == MAX_ALLOC) return null;
    allocs[allocs_n] = .{ .handle = handle };
    allocs_n += 1;
    return &allocs[allocs_n - 1];
}

/// The command buffer a submission names, read through the allocation
/// it lies in, when the process has both mapped and locked it.
fn submitted(nr: u8, my: u32, a: [*]const u8, va_off: usize, len_off: usize) void {
    const arg = a[0 .. len_off + 4];
    const va = rd64(arg, va_off);
    const len = rd32(arg, len_off);
    for (allocs[0..allocs_n]) |al| {
        if (al.gpu == 0 or al.cpu == 0 or va < al.gpu or va >= al.gpu + al.bytes) continue;
        const n = @min(@as(u64, len), al.gpu + al.bytes - va, MAX_BLOB);
        const p: [*]const u8 = @ptrFromInt(al.cpu + (va - al.gpu));
        record(5, nr, my, va, p[0..@intCast(n)], 0);
        return;
    }
    var b: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&b, "command buffer 0x{x} ({d} bytes) not in a locked allocation", .{ va, len }) catch return;
    record(6, nr, my, va, t, 0);
}

fn isDxg(fd: c_int) bool {
    if (fd < 0 or fd >= fd_kind.len) return false;
    const i: usize = @intCast(fd);
    if (fd_kind[i] == 0) {
        var path: [32]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "/proc/self/fd/{d}", .{fd}, 0) catch return false;
        var target: [64]u8 = undefined;
        const rc = linux.readlink(p.ptr, &target, target.len);
        const n: isize = @bitCast(rc);
        fd_kind[i] = if (n > 0 and std.mem.eql(u8, target[0..@intCast(n)], "/dev/dxg")) 1 else 2;
    }
    return fd_kind[i] == 1;
}

fn openOut() void {
    if (out_fd != -2) return;
    const name: [*:0]const u8 = getenv("DXGTRACE_OUT") orelse "dxgtrace.bin";
    const rc = linux.open(name, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    const n: isize = @bitCast(rc);
    out_fd = if (n >= 0) @intCast(n) else -1;
}

fn writeAll(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(out_fd, bytes[off..].ptr, bytes.len - off);
        const n: isize = @bitCast(rc);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn record(kind: u32, nr: u8, my: u32, addr: u64, bytes: []const u8, rc: c_int) void {
    openOut();
    if (out_fd < 0) return;
    var head: [32]u8 = undefined;
    @memcpy(head[0..4], "DXGT");
    std.mem.writeInt(u32, head[4..8], kind, .little);
    std.mem.writeInt(u32, head[8..12], nr, .little);
    std.mem.writeInt(u32, head[12..16], my, .little);
    std.mem.writeInt(u64, head[16..24], addr, .little);
    std.mem.writeInt(u32, head[24..28], @intCast(bytes.len), .little);
    std.mem.writeInt(i32, head[28..32], rc, .little);
    writeAll(&head);
    writeAll(bytes);
}
