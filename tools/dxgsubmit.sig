//! dxgsubmit: does the RTX run a pushbuffer zpm built, put into a channel
//! NVIDIA's WSL driver made? (The GPU-forwarding spike: which step hands
//! work to the GPU on /dev/dxg.)
//!
//! NVIDIA's libcuda makes the device, contexts and hardware queues (and
//! runs one fill so they are warm); dxgtrace (LD_PRELOAD) says where each
//! queue's GPFIFO ring and progress page are. Then a host semaphore
//! release (zpm's push.hostRelease) goes into the first queue's ring
//! (push.gpEntry) and the program watches for the payload, trying in turn:
//!   A  the ring entry alone (the GPU or the host polling the ring),
//!   B  also the queue's progress page set to the new write index (what
//!      NVIDIA's own submissions change besides the ring).
//!
//!   sig build-exe -target x86_64-linux-gnu -lc -OReleaseSafe --dep push
//!     -Mroot=tools/dxgsubmit.sig -Mpush=src/nvidia/push.sig --name dxgsubmit
//!   LD_PRELOAD=./libdxgtrace.so DXGTRACE_OUT=/dev/null ./dxgsubmit

const std = @import("std");
const push = @import("push");

extern "c" fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn fflush(f: ?*anyopaque) c_int;
extern "c" fn usleep(us: c_uint) c_int;

const Queue = extern struct {
    context: u32 = 0,
    handle: u32 = 0,
    progress_cpu: u64 = 0,
    progress_gpu: u64 = 0,
    gpfifo_va: u64 = 0,
    gpfifo_bytes: u64 = 0,
};

fn need(p: ?*anyopaque, name: [*:0]const u8) *anyopaque {
    return p orelse {
        _ = printf("dxgsubmit: no %s\n", name);
        std.process.exit(2);
    };
}

fn ok(name: [*:0]const u8, rc: c_int) void {
    if (rc == 0) return;
    _ = printf("dxgsubmit: %s -> %d\n", name, rc);
    std.process.exit(1);
}

/// Polls `sem` for `want` up to `ms` milliseconds; the time it took, or
/// null.
fn watch(sem: *volatile u32, want: u32, ms: u32) ?u32 {
    var t: u32 = 0;
    while (t < ms * 10) : (t += 1) {
        if (sem.* == want) return t * 100;
        _ = usleep(100);
    }
    return null;
}

pub fn main() void {
    const lib = need(dlopen("libcuda.so.1", 2) orelse dlopen("/usr/lib/wsl/lib/libcuda.so.1", 2), "libcuda");
    const cuInit: *const fn (c_uint) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuInit"), "cuInit"));
    const cuDeviceGet: *const fn (*c_int, c_int) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuDeviceGet"), "cuDeviceGet"));
    const cuCtxCreate: *const fn (*usize, c_uint, c_int) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuCtxCreate_v2"), "cuCtxCreate_v2"));
    const cuMemAlloc: *const fn (*u64, usize) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuMemAlloc_v2"), "cuMemAlloc_v2"));
    const cuMemsetD32: *const fn (u64, c_uint, usize) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuMemsetD32_v2"), "cuMemsetD32_v2"));
    const cuCtxSynchronize: *const fn () callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuCtxSynchronize"), "cuCtxSynchronize"));
    const queue: *const fn (u32, *Queue) callconv(.c) bool = @ptrCast(need(dlsym(null, "dxgtrace_queue"), "dxgtrace_queue (run under LD_PRELOAD=libdxgtrace.so)"));
    const cpuOf: *const fn (u64) callconv(.c) u64 = @ptrCast(need(dlsym(null, "dxgtrace_cpu"), "dxgtrace_cpu"));

    ok("cuInit", cuInit(0));
    var dev: c_int = 0;
    ok("cuDeviceGet", cuDeviceGet(&dev, 0));
    var ctx: usize = 0;
    ok("cuCtxCreate", cuCtxCreate(&ctx, 0, dev));
    var mem: u64 = 0;
    ok("cuMemAlloc", cuMemAlloc(&mem, 4096));
    ok("cuMemsetD32", cuMemsetD32(mem, 1, 1024));
    ok("cuCtxSynchronize", cuCtxSynchronize());

    var i: u32 = 0;
    var q: Queue = .{};
    while (queue(i, &q)) : (i += 1) {
        _ = printf("queue %u: context %x handle %x gpfifo 0x%llx (%llu bytes, cpu 0x%llx) progress cpu 0x%llx = %u, gpu 0x%llx\n", i, q.context, q.handle, q.gpfifo_va, q.gpfifo_bytes, cpuOf(q.gpfifo_va), q.progress_cpu, if (q.progress_cpu != 0) @as(*volatile u32, @ptrFromInt(q.progress_cpu)).* else 0, q.progress_gpu);
    }
    if (!queue(0, &q) or q.gpfifo_va == 0) {
        _ = printf("dxgsubmit: no queue with a ring\n");
        std.process.exit(2);
    }
    const ring_cpu = cpuOf(q.gpfifo_va);
    if (ring_cpu == 0) {
        _ = printf("dxgsubmit: the ring is not in CPU-visible memory\n");
        std.process.exit(2);
    }
    const n: usize = @intCast(q.gpfifo_bytes / 8);
    const ring: [*]volatile u64 = @ptrFromInt(ring_cpu);
    var put: usize = 0;
    for (0..n) |k| {
        if (ring[k] != 0) put = k + 1;
    }
    const progress: *volatile u32 = @ptrFromInt(q.progress_cpu);
    _ = printf("ring: %zu entries, next %zu, progress %u\n", n, put, progress.*);
    if (put == 0 or put >= n) std.process.exit(2);
    const last = push.parseGpEntry(ring[put - 1]);
    _ = printf("last entry: 0x%llx (va 0x%llx, %u dwords)\n", ring[put - 1], last.va, last.dwords);

    // The ring's allocation is 2 MiB and the ring 8 KiB: the pushbuffer
    // and the semaphore go in its far half, GPU-mapped and CPU-visible.
    const pb_va = q.gpfifo_va + 0x10_0000;
    const sem_va = q.gpfifo_va + 0x18_0000;
    if (cpuOf(pb_va) == 0 or cpuOf(sem_va) == 0) {
        _ = printf("dxgsubmit: the ring's allocation is smaller than 2 MiB\n");
        std.process.exit(2);
    }
    const pb: [*]u32 = @ptrFromInt(cpuOf(pb_va));
    const sem: *volatile u32 = @ptrFromInt(cpuOf(sem_va));
    sem.* = 0;

    const count: *const fn () callconv(.c) u32 = @ptrCast(need(dlsym(null, "dxgtrace_count"), "dxgtrace_count"));

    // NVIDIA after 2 s idle: still no ioctl?
    _ = usleep(2_000_000);
    const c0 = count();
    ok("cuMemsetD32", cuMemsetD32(mem, 2, 1024));
    ok("cuCtxSynchronize", cuCtxSynchronize());
    _ = printf("idle 2 s, then NVIDIA's fill + sync: %u ioctls, progress %u\n", count() - c0, progress.*);
    for (0..n) |k| {
        if (ring[k] != 0) put = k + 1;
    }
    const put_idle = put - 1;

    // HOT: NVIDIA's fill and, straight behind it in the ring, ours
    const want_h: u32 = 0xC0FF_EE0B;
    const len_h = push.hostRelease(pb[0..64], sem_va, want_h) catch unreachable;
    const c1 = count();
    ok("cuMemsetD32", cuMemsetD32(mem, 3, 1024));
    var nv: usize = put;
    for (put..n) |k| {
        if (ring[k] != 0) nv = k + 1;
    }
    barrier();
    ring[nv] = push.gpEntry(pb_va, @intCast(len_h)) | (@as(u64, ring[nv - 1]) & (1 << 41));
    barrier();
    if (watch(sem, want_h, 500)) |us| {
        _ = printf("HOT: RAN behind NVIDIA's entry %zu (%u us), %u ioctls\n", nv - 1, us, count() - c1);
    } else {
        _ = printf("HOT: not run in 500 ms behind NVIDIA's entry %zu (semaphore %x, progress %u)\n", nv - 1, sem.*, progress.*);
    }
    ok("cuCtxSynchronize after HOT", cuCtxSynchronize());
    put = nv + 1;

    // COPY: NVIDIA's own idle fill (value 2, entry put_idle) again, as a
    // new entry: does the GPU take any entry the CPU writes?
    const cuMemcpyDtoH: *const fn (*anyopaque, u64, usize) callconv(.c) c_int = @ptrCast(need(dlsym(lib, "cuMemcpyDtoH_v2"), "cuMemcpyDtoH_v2"));
    var word: u32 = 0;
    ok("cuMemcpyDtoH", cuMemcpyDtoH(&word, mem, 4));
    _ = printf("COPY: memory now %u (3 from the hot fill)\n", word);
    const idle_entry = ring[put_idle];
    barrier();
    ring[put] = idle_entry;
    barrier();
    _ = usleep(300_000);
    ok("cuMemcpyDtoH", cuMemcpyDtoH(&word, mem, 4));
    _ = printf("COPY: entry %zu = NVIDIA's entry %zu (0x%llx): memory %u after 300 ms (2 = it ran), progress %u\n", put, put_idle, idle_entry, word, progress.*);
    put += 1;

    // A: the entry alone
    const want_a: u32 = 0xC0FF_EE0A;
    const len_a = push.hostRelease(pb[0..64], sem_va, want_a) catch unreachable;
    const entry = push.gpEntry(pb_va, @intCast(len_a)) | (@as(u64, ring[put - 1]) & (1 << 41));
    barrier();
    ring[put] = entry;
    barrier();
    if (watch(sem, want_a, 500)) |us| {
        _ = printf("A: RAN with the ring entry alone (%u us), progress %u\n", us, progress.*);
        std.process.exit(0);
    }
    _ = printf("A: not run in 500 ms (semaphore %x, progress %u)\n", sem.*, progress.*);

    // C: NVIDIA's doorbell, made here: submit_to_hw_queue with the new
    // write index as the progress fence id, no command buffer (0xdeadbeef,
    // 1 byte) and NVIDIA's 536-byte header. The entries before ours that
    // nobody rang for (HOT, COPY) are in the ring too: they run first.
    const dxg = dxgFd() orelse {
        _ = printf("dxgsubmit: no /dev/dxg fd\n");
        std.process.exit(2);
    };
    var priv: [536]u8 = [_]u8{0} ** 536;
    std.mem.writeInt(u32, priv[0..4], 0x4e56_4441, .little); // "ADVN": NVDA
    std.mem.writeInt(u32, priv[4..8], 0x0001_0000, .little);
    std.mem.writeInt(u32, priv[12..16], 0x118, .little);
    std.mem.writeInt(u32, priv[16..20], 0x20, .little);
    std.mem.writeInt(u32, priv[20..24], 1, .little);
    std.mem.writeInt(u64, priv[120..128], put + 1, .little);
    std.mem.writeInt(u32, priv[272..276], 0x10, .little);
    var arg: [56]u8 = [_]u8{0} ** 56;
    std.mem.writeInt(u32, arg[0..4], q.handle, .little);
    std.mem.writeInt(u64, arg[8..16], put + 1, .little);
    std.mem.writeInt(u64, arg[16..24], 0xdeadbeef, .little);
    std.mem.writeInt(u32, arg[24..28], 1, .little);
    std.mem.writeInt(u32, arg[28..32], priv.len, .little);
    std.mem.writeInt(u64, arg[32..40], @intFromPtr(&priv), .little);
    const rc = ioctl(dxg, 0xc038_4734, @intFromPtr(&arg));
    if (watch(sem, want_a, 1000)) |us| {
        ok("cuMemcpyDtoH", cuMemcpyDtoH(&word, mem, 4));
        _ = printf("C: RAN after submit_to_hw_queue (rc %d, %u us): semaphore %x, progress %u, memory %u (2: COPY ran too)\n", rc, us, sem.*, progress.*, word);
        std.process.exit(0);
    }
    _ = printf("C: not run in 1 s (rc %d, semaphore %x, progress %u)\n", rc, sem.*, progress.*);
    std.process.exit(3);
}

extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;

/// The process's /dev/dxg file descriptor (NVIDIA's libdxcore opened it).
fn dxgFd() ?c_int {
    var fd: c_int = 0;
    while (fd < 256) : (fd += 1) {
        var path: [32]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&path, "/proc/self/fd/{d}", .{fd}, 0) catch return null;
        var target: [64]u8 = undefined;
        const n: isize = @bitCast(std.os.linux.readlink(p.ptr, &target, target.len));
        if (n > 0 and std.mem.eql(u8, target[0..@intCast(n)], "/dev/dxg")) return fd;
    }
    return null;
}

var fence_word: u32 = 0;
/// A full barrier (the stores before it are visible before the ones after).
fn barrier() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}
