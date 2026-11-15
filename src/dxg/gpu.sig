//! @zpm/dxg gpu — an NVIDIA GPU through WSL's /dev/dxg, driven the way
//! NVIDIA's own WSL driver drives it, with no NVIDIA library.
//!
//! A `Gpu` is the device: the adapter (found by its PCI vendor), a dxgkrnl
//! device, its paging queue and its GPU address space, and the memory mapped
//! into it (the process's own, or the GPU's). A `Channel` runs work: a
//! context on an engine, a GPFIFO ring and the hardware queue that reads
//! it. A Gpu's channels share its address space: memory mapped once is seen
//! by all of them.
//!
//! # Running work
//!
//! A submission writes GPFIFO entries into the ring (the caller's
//! pushbuffers, then the channel's own: a host semaphore release of the
//! submission's fence to the queue's progress fence, and to the channel's
//! `notify` address when it has one, then an interrupt), clears the entry
//! after them, and calls submit_to_hw_queue: the doorbell, after which the
//! GPU runs every entry the ring has gained. `wait` polls the progress
//! fence.
//!
//! # Memory
//!
//! System memory is the caller's (page-aligned, a multiple of 64 KiB, shared
//! or private): dxgkrnl pins it and the GPU maps it, so the CPU and the GPU
//! see the same bytes. Video memory is the GPU's; the CPU has no view of it
//! here. GPU addresses come from ranges reserved on the Gpu: VA_BASE's at
//! `open` (handed out in order by mapSystem and allocVideo, not reused),
//! and any the caller reserves for addresses of its own choosing
//! (`reserve`, then mapSystemAt).
//!
//! Allocation-free: the state is the caller's, and so is each ring's memory
//! (RING_BYTES).

const std = @import("std");
const linux = std.os.linux;
const kmt = @import("kmt.sig");
const nv = @import("nv.sig");
const push = @import("nvidia").push;

pub const Error = kmt.Error || error{
    /// No adapter from NVIDIA (PCI vendor 0x10de).
    NoNvidiaAdapter,
    /// /dev/dxg cannot be opened (not WSL, or no GPU paravirtualization).
    NoDxg,
    /// The GPU address range reserved at open is used up.
    OutOfAddresses,
    /// Memory not page-aligned or not a multiple of 64 KiB.
    BadMemory,
    /// The work did not complete in time.
    Timeout,
    /// The host moved the progress fence past everything submitted: the
    /// channel faulted (the GPU's error, as the host marks it).
    DeviceLost,
};

pub const NVIDIA: u32 = 0x10de;

/// A channel's ring memory: 2 MiB (NVIDIA's allocation unit for it). The
/// GPFIFO is its first 8 KiB (1024 entries), the channel's fence
/// pushbuffers sit from 1 MiB.
pub const RING_BYTES = 2 << 20;
pub const GPFIFO_ENTRIES = 1024;
const GPFIFO_BYTES = GPFIFO_ENTRIES * 8;
const FENCE_PB_OFFSET = 1 << 20;
/// Each entry's own fence pushbuffer: 16 dwords.
const FENCE_PB_BYTES = 64;
/// The host's NON_STALL_INTERRUPT (clc96f.h).
const NON_STALL_INTERRUPT: u32 = 0x0020;

/// The GPU addresses handed out in order (NVIDIA's driver reserves the same
/// range for its process-memory allocations).
pub const VA_BASE: u64 = 0x2_0000_0000;
pub const VA_BYTES: u64 = 0x5_0000_0000;
/// The granularity of GPU addresses (a large page).
const VA_ALIGN: u64 = 2 << 20;

/// The engines (a context's node): NVIDIA's driver puts compute and
/// graphics on node 0 and its copies on node 3.
pub const Engine = enum(u32) { graphics_compute = 0, copy = 3 };

pub const Options = struct {
    /// The name NVIDIA's host driver sees for this process.
    name: []const u8 = "zpm",
    /// Which NVIDIA adapter (when there are several).
    index: u32 = 0,
};

pub const ChannelOptions = struct {
    name: []const u8 = "zpm",
    engine: Engine = .graphics_compute,
    /// The kind of client the host makes the context for (D3DKMT's client
    /// hint: 1 OpenGL, 4 Vulkan, 5 CUDA, 10 Direct3D 10+): NVIDIA's CUDA
    /// driver says CUDA.
    client: u32 = 5,
    /// The engines the queue's channel gets objects for (nv.queue's
    /// field): Direct3D 12's direct queue's, the 3D engine and compute.
    engines: u32 = nv.ENGINES_DIRECT,
    /// A GPU address the channel also writes each finished submission's
    /// fence to (its low 32 bits, after the work): for a reader that cannot
    /// see the progress fence (a guest, through mapped memory). 0: none.
    notify: u64 = 0,
};

/// Memory the GPU maps: its GPU address, the CPU's view (empty for video
/// memory), dxgkrnl's handle.
pub const Region = struct {
    va: u64 = 0,
    cpu: []u8 = &.{},
    bytes: u64 = 0,
    handle: kmt.Handle = 0,
};

pub const Gpu = struct {
    fd: i32 = -1,
    adapter: kmt.Handle = 0,
    ids: kmt.PciIds = .{},
    device: kmt.Handle = 0,
    paging_queue: kmt.Handle = 0,
    paging_fence: *volatile u64 = undefined,
    va_next: u64 = VA_BASE,
    alloc_data: [nv.ALLOCATION_BYTES]u8 = undefined,

    /// Opens the NVIDIA GPU: adapter, device, paging queue, VA_BASE's range.
    pub fn open(g: *Gpu, opts: Options) Error!void {
        g.* = .{};
        const fd: isize = @bitCast(linux.open("/dev/dxg", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
        if (fd < 0) return error.NoDxg;
        g.fd = @intCast(fd);
        errdefer g.close();
        try g.findAdapter(opts.index);

        var dev = kmt.CreateDevice{ .adapter = g.adapter };
        _ = try kmt.call(g.fd, .create_device, &dev);
        g.device = dev.device;

        var pq = kmt.CreatePagingQueue{ .device = g.device };
        _ = try kmt.call(g.fd, .create_paging_queue, &pq);
        g.paging_queue = pq.paging_queue;
        g.paging_fence = @ptrFromInt(pq.fence_cpu);
        try g.reserve(VA_BASE, VA_BYTES);
    }

    /// GPU addresses [base, base + bytes) kept for this Gpu's mappings.
    pub fn reserve(g: *Gpu, base: u64, bytes: u64) Error!void {
        var rv = kmt.ReserveGpuVa{ .adapter = g.adapter, .base = base, .size = bytes };
        _ = try kmt.call(g.fd, .reserve_gpu_va, &rv);
    }

    /// The adapters dxgkrnl offers; the `index`-th NVIDIA one is kept, the
    /// others closed.
    fn findAdapter(g: *Gpu, index: u32) Error!void {
        var list: [8]kmt.AdapterInfo = undefined;
        var e = kmt.EnumAdapters3{ .count = list.len, .adapters = @intFromPtr(&list) };
        _ = try kmt.call(g.fd, .enum_adapters3, &e);
        var seen: u32 = 0;
        for (list[0..@min(e.count, list.len)]) |a| {
            var ids: kmt.PciIds = .{};
            var q = kmt.QueryAdapterInfo{ .adapter = a.adapter, .type = kmt.QUERY_PCI_IDS, .data = @intFromPtr(&ids), .size = @sizeOf(kmt.PciIds) };
            const ok = if (kmt.call(g.fd, .query_adapter_info, &q)) |_| true else |_| false;
            if (g.adapter == 0 and ok and ids.vendor == NVIDIA) {
                if (seen == index) {
                    g.adapter = a.adapter;
                    g.ids = ids;
                    continue;
                }
                seen += 1;
            }
            var c = kmt.CloseAdapter{ .adapter = a.adapter };
            _ = kmt.call(g.fd, .close_adapter, &c) catch {};
        }
        if (g.adapter == 0) return error.NoNvidiaAdapter;
    }

    /// The paging queue's work up to `value` done (maps, residency): a
    /// first touch of a big piece of memory (a guest's RAM, pinned page by
    /// page) takes milliseconds. Gives up after 5 s (the GPU would then
    /// fault on the memory, and the channel says so).
    fn pagingDone(g: *Gpu, value: u64) void {
        var spins: u32 = 0;
        var slept_us: u64 = 0;
        while (g.paging_fence.* < value) {
            if (spins < 20_000) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            if (slept_us >= 5_000_000) return;
            const ts: linux.timespec = .{ .sec = 0, .nsec = 50_000 };
            _ = linux.nanosleep(&ts, null);
            slept_us += 50;
        }
    }

    fn nextVa(g: *Gpu, bytes: u64) Error!u64 {
        const va = std.mem.alignForward(u64, g.va_next, VA_ALIGN);
        if (va + bytes > VA_BASE + VA_BYTES) return error.OutOfAddresses;
        g.va_next = va + bytes;
        return va;
    }

    /// An allocation, resident and mapped at `at` (null: the next of
    /// VA_BASE's range).
    fn create(g: *Gpu, memory: nv.Memory, sysmem: ?[]u8, bytes: u64, at: ?u64) Error!Region {
        if (bytes == 0 or bytes % nv.ALLOCATION_UNIT != 0) return error.BadMemory;
        nv.allocation(&g.alloc_data, memory, bytes);
        var info = kmt.AllocationInfo2{
            .sysmem = if (sysmem) |m| @intFromPtr(m.ptr) else 0,
            .priv = @intFromPtr(&g.alloc_data),
            .priv_size = nv.ALLOCATION_BYTES,
        };
        var ca = kmt.CreateAllocation{ .device = g.device, .info = @intFromPtr(&info) };
        _ = try kmt.call(g.fd, .create_allocation, &ca);
        var r = Region{ .handle = info.allocation, .bytes = bytes, .cpu = sysmem orelse &.{} };
        errdefer g.release(r);

        var handle = info.allocation;
        var mr = kmt.MakeResident{ .paging_queue = g.paging_queue, .allocations = @intFromPtr(&handle) };
        _ = try kmt.call(g.fd, .make_resident, &mr);
        const va = at orelse try g.nextVa(bytes);
        var mp = kmt.MapGpuVa{
            .paging_queue = g.paging_queue,
            .base = va,
            // (the bounds NVIDIA's driver gives with a base of its own)
            .minimum = 0x500_0000,
            .maximum = 0xffff_ffff_ffff_0000,
            .allocation = info.allocation,
            .size_pages = bytes / 4096,
        };
        _ = try kmt.call(g.fd, .map_gpu_va, &mp);
        g.pagingDone(@max(mr.paging_fence, mp.paging_fence));
        r.va = mp.va;
        return r;
    }

    fn map(g: *Gpu, cpu: []align(4096) u8, memory: nv.Memory, at: ?u64) Error!Region {
        if (cpu.len % nv.ALLOCATION_UNIT != 0) return error.BadMemory;
        return g.create(memory, cpu, cpu.len, at);
    }

    /// The caller's memory (page-aligned, a multiple of 64 KiB) mapped for
    /// the GPU; the CPU keeps its view.
    pub fn mapSystem(g: *Gpu, cpu: []align(4096) u8) Error!Region {
        return g.map(cpu, .system, null);
    }

    /// The same at GPU address `va` (in a range `reserve` kept, 64 KiB
    /// aligned).
    pub fn mapSystemAt(g: *Gpu, cpu: []align(4096) u8, va: u64) Error!Region {
        if (va % nv.ALLOCATION_UNIT != 0) return error.BadMemory;
        return g.map(cpu, .system, va);
    }

    /// `bytes` (a multiple of 64 KiB) of the GPU's own memory.
    pub fn allocVideo(g: *Gpu, bytes: u64) Error!Region {
        return g.create(.video, null, bytes, null);
    }

    /// The allocation destroyed (its GPU address unmapped with it).
    pub fn release(g: *Gpu, r: Region) void {
        if (r.handle == 0) return;
        var h = r.handle;
        var d = kmt.DestroyAllocation2{ .device = g.device, .allocations = @intFromPtr(&h), .count = 1 };
        _ = kmt.call(g.fd, .destroy_allocation2, &d) catch {};
    }

    /// Closes the device (its channels first: Channel.close).
    pub fn close(g: *Gpu) void {
        if (g.fd < 0) return;
        if (g.paging_queue != 0) {
            var d = kmt.DestroyPagingQueue{ .paging_queue = g.paging_queue };
            _ = kmt.call(g.fd, .destroy_paging_queue, &d) catch {};
        }
        if (g.device != 0) {
            var d = kmt.DestroyDevice{ .device = g.device };
            _ = kmt.call(g.fd, .destroy_device, &d) catch {};
        }
        if (g.adapter != 0) {
            var d = kmt.CloseAdapter{ .adapter = g.adapter };
            _ = kmt.call(g.fd, .close_adapter, &d) catch {};
        }
        _ = linux.close(g.fd);
        g.fd = -1;
    }
};

pub const Channel = struct {
    gpu: *Gpu = undefined,
    context: kmt.Handle = 0,
    queue: kmt.Handle = 0,
    progress: *volatile u64 = undefined,
    progress_gpu: u64 = 0,
    notify: u64 = 0,
    ring: Region = .{},
    /// GPFIFO entries written so far (the next one's index, mod the ring).
    put: u64 = 0,
    /// The last submission's fence.
    fence: u64 = 0,
    ctx_data: [nv.CONTEXT_BYTES]u8 = undefined,
    queue_data: [nv.QUEUE_BYTES]u8 = undefined,
    submit_data: [nv.SUBMIT_BYTES]u8 = undefined,

    /// A channel on `g`: a context on `opts.engine`, the ring in
    /// `ring_memory` (RING_BYTES, page-aligned) and its hardware queue.
    pub fn open(c: *Channel, g: *Gpu, ring_memory: []align(4096) u8, opts: ChannelOptions) Error!void {
        c.* = .{ .gpu = g, .notify = opts.notify };
        errdefer c.close();
        nv.context(&c.ctx_data, opts.name, opts.client);
        var cc = kmt.CreateContextVirtual{
            .device = g.device,
            .node_ordinal = @intFromEnum(opts.engine),
            .flags = kmt.CONTEXT_DISABLE_GPU_TIMEOUT | kmt.CONTEXT_HW_QUEUE_SUPPORTED,
            .priv = @intFromPtr(&c.ctx_data),
            .priv_size = nv.CONTEXT_BYTES,
            .client_hint = opts.client,
        };
        _ = try kmt.call(g.fd, .create_context_virtual, &cc);
        c.context = cc.context;

        c.ring = try g.map(ring_memory[0..RING_BYTES], .ring, null);
        @memset(c.ring.cpu[0..GPFIFO_BYTES], 0);
        nv.queue(&c.queue_data, opts.engines, c.ring.va, GPFIFO_BYTES, c.ring.handle);
        var hq = kmt.CreateHwQueue{
            .context = c.context,
            .flags = 1,
            .priv_size = nv.QUEUE_BYTES,
            .priv = @intFromPtr(&c.queue_data),
        };
        _ = try kmt.call(g.fd, .create_hw_queue, &hq);
        c.queue = hq.queue;
        c.progress = @ptrFromInt(hq.progress_cpu);
        c.progress_gpu = hq.progress_gpu;
        c.fence = c.progress.*;
    }

    fn entry(c: *Channel, e: u64) void {
        const ring: [*]volatile u64 = @ptrCast(@alignCast(c.ring.cpu.ptr));
        ring[@intCast(c.put % GPFIFO_ENTRIES)] = e;
        c.put += 1;
    }

    /// Runs `dwords` of pushbuffer at GPU address `va`; its fence.
    pub fn submit(c: *Channel, va: u64, dwords: u32) Error!u64 {
        return c.submitMany(&.{.{ .va = va, .dwords = dwords }});
    }

    pub const Push = struct { va: u64, dwords: u32 };

    /// Runs the pushbuffers in order, as one submission; its fence.
    pub fn submitMany(c: *Channel, pbs: []const Push) Error!u64 {
        // (the fence is the ring's write count after this submission, as
        // NVIDIA's driver numbers it)
        const f = c.put + pbs.len + 1;
        c.fence = f;
        for (pbs) |p| c.entry(push.gpEntry(p.va, p.dwords) | nv.ENTRY_SUBROUTINE);
        const slot = c.put % GPFIFO_ENTRIES;
        const off = FENCE_PB_OFFSET + slot * FENCE_PB_BYTES;
        const pb: [*]volatile u32 = @ptrCast(@alignCast(c.ring.cpu.ptr + off));
        var n: u32 = 0;
        // the fence: a release of `f` (64-bit) to the progress fence ...
        pb[0] = push.header(0, push.SEM_ADDR_LO, 5);
        pb[1] = @truncate(c.progress_gpu);
        pb[2] = @truncate(c.progress_gpu >> 32);
        pb[3] = @truncate(f);
        pb[4] = @truncate(f >> 32);
        pb[5] = push.SEM_OPERATION_RELEASE | push.SEM_RELEASE_WFI | push.SEM_PAYLOAD_64BIT;
        n = 6;
        // ... and its low half to the reader's address
        if (c.notify != 0) {
            pb[n] = push.header(0, push.SEM_ADDR_LO, 5);
            pb[n + 1] = @truncate(c.notify);
            pb[n + 2] = @truncate(c.notify >> 32);
            pb[n + 3] = @truncate(f);
            pb[n + 4] = 0;
            pb[n + 5] = push.SEM_OPERATION_RELEASE;
            n += 6;
        }
        // then an interrupt, so the host sees the fence move (without it
        // the host stops taking work after ten submissions it never saw
        // finish; NVIDIA's driver traps from the compute engine)
        pb[n] = push.header(0, NON_STALL_INTERRUPT, 1);
        pb[n + 1] = 0;
        n += 2;
        c.entry(push.gpEntry(c.ring.va + off, n) | nv.ENTRY_SUBROUTINE);
        // the entry after them empty: where the GPU stops
        const ring: [*]volatile u64 = @ptrCast(@alignCast(c.ring.cpu.ptr));
        ring[@intCast(c.put % GPFIFO_ENTRIES)] = 0;
        fullFence();
        try c.ringAgain();
        return f;
    }

    /// The doorbell for everything written so far (again).
    pub fn ringAgain(c: *Channel) Error!void {
        nv.submit(&c.submit_data, c.put % GPFIFO_ENTRIES);
        var s = kmt.SubmitToHwQueue{
            .queue = c.queue,
            .progress_fence = c.fence,
            .command_buffer = nv.SUBMIT_COMMAND_BUFFER,
            .command_length = 1,
            .priv_size = nv.SUBMIT_BYTES,
            .priv = @intFromPtr(&c.submit_data),
        };
        _ = try kmt.call(c.gpu.fd, .submit_to_hw_queue, &s);
    }

    /// The last fence the GPU finished.
    pub fn completed(c: *const Channel) u64 {
        return c.progress.*;
    }

    /// Whether the channel faulted (the host moved its progress fence past
    /// everything submitted).
    pub fn lost(c: *const Channel) bool {
        return c.progress.* > c.fence;
    }

    /// Waits for fence `f` (polling, `timeout_us` at most).
    pub fn wait(c: *Channel, f: u64, timeout_us: u64) Error!void {
        var spins: u32 = 0;
        var slept_us: u64 = 0;
        while (true) {
            const p = c.progress.*;
            if (p > c.fence) return error.DeviceLost;
            if (p >= f) return;
            if (spins < 20_000) {
                spins += 1;
                std.atomic.spinLoopHint();
                continue;
            }
            if (slept_us >= timeout_us) return error.Timeout;
            const ts: linux.timespec = .{ .sec = 0, .nsec = 50_000 };
            _ = linux.nanosleep(&ts, null);
            slept_us += 50;
        }
    }

    pub fn close(c: *Channel) void {
        const g = c.gpu;
        if (g.fd < 0) return;
        if (c.queue != 0) {
            var d = kmt.DestroyHwQueue{ .queue = c.queue };
            _ = kmt.call(g.fd, .destroy_hw_queue, &d) catch {};
            c.queue = 0;
        }
        g.release(c.ring);
        c.ring = .{};
        if (c.context != 0) {
            var d = kmt.DestroyContext{ .context = c.context };
            _ = kmt.call(g.fd, .destroy_context, &d) catch {};
            c.context = 0;
        }
    }
};

var fence_word: u32 = 0;
/// A full barrier: the ring's entries are in memory before the doorbell.
fn fullFence() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}
