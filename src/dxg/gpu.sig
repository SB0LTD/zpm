//! @zpm/dxg gpu — an NVIDIA GPU through WSL's /dev/dxg, driven the way
//! NVIDIA's own WSL driver drives it, with no NVIDIA library: the adapter
//! (found by its PCI vendor), a device, a paging queue, a context on an
//! engine, a GPFIFO ring and the hardware queue that runs it; memory the
//! GPU maps (the process's own, or the GPU's); pushbuffers run and waited
//! for.
//!
//! # Running work
//!
//! A submission writes GPFIFO entries into the ring (the caller's
//! pushbuffer, then the driver's own: a host semaphore release of the
//! submission's number to the queue's progress fence, once all before it
//! is done), clears the entry after them, and calls submit_to_hw_queue
//! with that number: the doorbell, after which the GPU runs every entry
//! the ring has gained. `wait` polls the progress fence.
//!
//! # Memory
//!
//! System memory is the caller's (page-aligned, a multiple of 64 KiB, shared
//! or private): dxgkrnl pins it and the GPU maps it, so the CPU and the GPU
//! see the same bytes. Video memory is the GPU's; the CPU has no view of it
//! here. GPU addresses come from a range reserved at `open` (VA_BASE,
//! VA_BYTES), handed out in order and not reused.
//!
//! Allocation-free: the Gpu's state is the caller's, and so is the ring's
//! memory (RING_BYTES).

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

/// The ring's memory: 2 MiB (NVIDIA's allocation unit for it). The GPFIFO
/// is its first 8 KiB (1024 entries), the driver's fence pushbuffers sit
/// from 1 MiB.
pub const RING_BYTES = 2 << 20;
pub const GPFIFO_ENTRIES = 1024;
const GPFIFO_BYTES = GPFIFO_ENTRIES * 8;
const FENCE_PB_OFFSET = 1 << 20;
/// Each entry's own fence pushbuffer: 8 dwords.
const FENCE_PB_BYTES = 32;
/// The host's NON_STALL_INTERRUPT (clc96f.h).
const NON_STALL_INTERRUPT: u32 = 0x0020;

/// The GPU addresses handed out (NVIDIA's driver reserves the same range
/// for its process-memory allocations).
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
    engine: Engine = .graphics_compute,
    /// Which NVIDIA adapter (when there are several).
    index: u32 = 0,
    /// The kind of client the host makes the context for (D3DKMT's client
    /// hint: 1 OpenGL, 4 Vulkan, 5 CUDA, 10 Direct3D 10+): NVIDIA's CUDA
    /// driver says CUDA.
    client: u32 = 5,
    /// The engines the queue's channel gets objects for (nv.queue's
    /// field): Direct3D 12's direct queue's, the 3D engine and compute.
    engines: u32 = nv.ENGINES_DIRECT,
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
    context: kmt.Handle = 0,
    queue: kmt.Handle = 0,
    progress: *volatile u64 = undefined,
    progress_gpu: u64 = 0,
    ring: Region = .{},
    va_next: u64 = VA_BASE,
    /// GPFIFO entries written so far (the next one's index, mod the ring).
    put: u64 = 0,
    /// Submissions so far (the last one's number).
    fence: u64 = 0,

    // the private data blocks (kept here, not on the stack)
    ctx_data: [nv.CONTEXT_BYTES]u8 = undefined,
    alloc_data: [nv.ALLOCATION_BYTES]u8 = undefined,
    queue_data: [nv.QUEUE_BYTES]u8 = undefined,
    submit_data: [nv.SUBMIT_BYTES]u8 = undefined,

    /// Opens the NVIDIA GPU: adapter, device, paging queue, a context on
    /// `opts.engine`, the ring in `ring_memory` (RING_BYTES, page-aligned)
    /// and its hardware queue.
    pub fn open(g: *Gpu, ring_memory: []align(4096) u8, opts: Options) Error!void {
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

        var rv = kmt.ReserveGpuVa{ .adapter = g.adapter, .base = VA_BASE, .size = VA_BYTES };
        _ = try kmt.call(g.fd, .reserve_gpu_va, &rv);

        nv.context(&g.ctx_data, opts.name, opts.client);
        var cc = kmt.CreateContextVirtual{
            .device = g.device,
            .node_ordinal = @intFromEnum(opts.engine),
            .flags = kmt.CONTEXT_DISABLE_GPU_TIMEOUT | kmt.CONTEXT_HW_QUEUE_SUPPORTED,
            .priv = @intFromPtr(&g.ctx_data),
            .priv_size = nv.CONTEXT_BYTES,
            .client_hint = opts.client,
        };
        _ = try kmt.call(g.fd, .create_context_virtual, &cc);
        g.context = cc.context;

        g.ring = try g.map(ring_memory[0..RING_BYTES], .ring);
        @memset(g.ring.cpu[0..GPFIFO_BYTES], 0);
        nv.queue(&g.queue_data, opts.engines, g.ring.va, GPFIFO_BYTES, g.ring.handle);
        var hq = kmt.CreateHwQueue{
            .context = g.context,
            .flags = 1,
            .priv_size = nv.QUEUE_BYTES,
            .priv = @intFromPtr(&g.queue_data),
        };
        _ = try kmt.call(g.fd, .create_hw_queue, &hq);
        g.queue = hq.queue;
        g.progress = @ptrFromInt(hq.progress_cpu);
        g.progress_gpu = hq.progress_gpu;
        g.fence = g.progress.*;
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

    /// The paging queue's work up to `value` done (maps, residency).
    fn pagingDone(g: *Gpu, value: u64) void {
        var spins: u32 = 0;
        while (g.paging_fence.* < value and spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
    }

    fn nextVa(g: *Gpu, bytes: u64) Error!u64 {
        const va = std.mem.alignForward(u64, g.va_next, VA_ALIGN);
        if (va + bytes > VA_BASE + VA_BYTES) return error.OutOfAddresses;
        g.va_next = va + bytes;
        return va;
    }

    /// An allocation, resident and mapped at a GPU address of its own.
    fn create(g: *Gpu, memory: nv.Memory, sysmem: ?[]u8, bytes: u64) Error!Region {
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
        const va = try g.nextVa(bytes);
        var mp = kmt.MapGpuVa{
            .paging_queue = g.paging_queue,
            .base = va,
            .minimum = VA_BASE,
            .maximum = VA_BASE + VA_BYTES,
            .allocation = info.allocation,
            .size_pages = bytes / 4096,
        };
        _ = try kmt.call(g.fd, .map_gpu_va, &mp);
        g.pagingDone(@max(mr.paging_fence, mp.paging_fence));
        r.va = mp.va;
        return r;
    }

    fn map(g: *Gpu, cpu: []align(4096) u8, memory: nv.Memory) Error!Region {
        if (cpu.len % nv.ALLOCATION_UNIT != 0) return error.BadMemory;
        return g.create(memory, cpu, cpu.len);
    }

    /// The caller's memory (page-aligned, a multiple of 64 KiB) mapped for
    /// the GPU; the CPU keeps its view.
    pub fn mapSystem(g: *Gpu, cpu: []align(4096) u8) Error!Region {
        return g.map(cpu, .system);
    }

    /// `bytes` (a multiple of 64 KiB) of the GPU's own memory.
    pub fn allocVideo(g: *Gpu, bytes: u64) Error!Region {
        return g.create(.video, null, bytes);
    }

    /// The allocation destroyed (its GPU address is not handed out again).
    pub fn release(g: *Gpu, r: Region) void {
        if (r.handle == 0) return;
        var h = r.handle;
        var d = kmt.DestroyAllocation2{ .device = g.device, .allocations = @intFromPtr(&h), .count = 1 };
        _ = kmt.call(g.fd, .destroy_allocation2, &d) catch {};
    }

    fn entry(g: *Gpu, e: u64) void {
        const ring: [*]volatile u64 = @ptrCast(@alignCast(g.ring.cpu.ptr));
        ring[@intCast(g.put % GPFIFO_ENTRIES)] = e;
        g.put += 1;
    }

    /// Runs `dwords` of pushbuffer at GPU address `va`; the submission's
    /// number (its fence).
    pub fn submit(g: *Gpu, va: u64, dwords: u32) Error!u64 {
        return g.submitMany(&.{.{ .va = va, .dwords = dwords }});
    }

    pub const Push = struct { va: u64, dwords: u32 };

    /// Runs the pushbuffers in order, as one submission.
    pub fn submitMany(g: *Gpu, pbs: []const Push) Error!u64 {
        // (the fence is the ring's write count after this submission, as
        // NVIDIA's driver numbers it: the doorbell's fence is how far the
        // GPU reads the ring)
        const f = g.put + pbs.len + 1;
        g.fence = f;
        for (pbs) |p| g.entry(push.gpEntry(p.va, p.dwords) | nv.ENTRY_SUBROUTINE);
        // the fence: a release of `f` (64-bit) to the progress fence
        const slot = g.put % GPFIFO_ENTRIES;
        const off = FENCE_PB_OFFSET + slot * FENCE_PB_BYTES;
        const pb: [*]volatile u32 = @ptrCast(@alignCast(g.ring.cpu.ptr + off));
        pb[0] = push.header(0, push.SEM_ADDR_LO, 5);
        pb[1] = @truncate(g.progress_gpu);
        pb[2] = @truncate(g.progress_gpu >> 32);
        pb[3] = @truncate(f);
        pb[4] = @truncate(f >> 32);
        pb[5] = push.SEM_OPERATION_RELEASE | push.SEM_RELEASE_WFI | push.SEM_PAYLOAD_64BIT;
        // and an interrupt, so the host sees the fence move (without it
        // the host stops taking work after ten submissions it never saw
        // finish; NVIDIA's driver traps from the compute engine)
        pb[6] = push.header(0, NON_STALL_INTERRUPT, 1);
        pb[7] = 0;
        g.entry(push.gpEntry(g.ring.va + off, 8) | nv.ENTRY_SUBROUTINE);
        // the entry after them empty: where the GPU stops
        const ring: [*]volatile u64 = @ptrCast(@alignCast(g.ring.cpu.ptr));
        ring[@intCast(g.put % GPFIFO_ENTRIES)] = 0;
        fullFence();

        try g.ring_again();
        return f;
    }

    /// The doorbell for everything written so far (again).
    pub fn ring_again(g: *Gpu) Error!void {
        const f = g.fence;
        nv.submit(&g.submit_data, g.put % GPFIFO_ENTRIES);
        var s = kmt.SubmitToHwQueue{
            .queue = g.queue,
            .progress_fence = f,
            .command_buffer = nv.SUBMIT_COMMAND_BUFFER,
            .command_length = 1,
            .priv_size = nv.SUBMIT_BYTES,
            .priv = @intFromPtr(&g.submit_data),
        };
        _ = try kmt.call(g.fd, .submit_to_hw_queue, &s);

    }

    /// The last submission the GPU finished.
    pub fn completed(g: *const Gpu) u64 {
        return g.progress.*;
    }

    /// Waits for submission `f` (polling, `timeout_us` at most).
    pub fn wait(g: *Gpu, f: u64, timeout_us: u64) Error!void {
        var spins: u32 = 0;
        var slept_us: u64 = 0;
        while (true) {
            const p = g.progress.*;
            if (p > g.fence) return error.DeviceLost;
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

    pub fn close(g: *Gpu) void {
        if (g.fd < 0) return;
        if (g.queue != 0) {
            var d = kmt.DestroyHwQueue{ .queue = g.queue };
            _ = kmt.call(g.fd, .destroy_hw_queue, &d) catch {};
        }
        g.release(g.ring);
        if (g.context != 0) {
            var d = kmt.DestroyContext{ .context = g.context };
            _ = kmt.call(g.fd, .destroy_context, &d) catch {};
        }
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

var fence_word: u32 = 0;
/// A full barrier: the ring's entries are in memory before the doorbell.
fn fullFence() void {
    _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst);
}
