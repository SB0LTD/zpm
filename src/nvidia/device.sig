//! @zpm/nvidia device — what a compute user needs from an NVIDIA GPU
//! driver, and an emulated RTX that provides it.
//!
//! A Device hands out GPU buffers (a GPU virtual address and a CPU view of
//! the same memory), runs pushbuffers from them and reports when they are
//! done. Galaxy's kernel implements it over its RTX driver (nv_chan: the
//! GPFIFO, the doorbell, its own semaphore release after each pushbuffer
//! as the fence); EmuDevice implements it on the CPU. It reads a pushbuffer
//! the way the GPU's host and compute engines would: the method headers,
//! SET_OBJECT, the compute state push.sig sends, SEND_PCAS_A and
//! SEND_SIGNALING_PCAS2_B (a QMD launched), the host's semaphore releases,
//! the compute engine's reports. Each QMD is read from GPU memory and
//! decoded field by field (qmd.decode); the code at its program address is
//! decoded with sm120.decode, and the grid runs in sm120_emu with the
//! QMD's block, registers, shared and local memory and constant buffers,
//! its control fields checked. So a pushbuffer, a QMD or a kernel that is
//! wrong fails here too, not only on the Legion.
//!
//! What the emulated GPU checks that the real one would trip over:
//! a QMD's SASS version and version, local memory set up (and big enough
//! for every TPC) before a kernel with a stack runs, shared memory within
//! the QMD's SM split, code changed at an address the SMs ran without the
//! shader caches invalidated, a method to a subchannel with no object, and
//! (with `gpu_view`) every CPU write handed over with toDevice and every
//! GPU write fetched with fromDevice.
//!
//! Allocation-free: buffers come from memory the device owner provides, and
//! so does the emulator's Work.

const std = @import("std");
const sm120 = @import("sm120.sig");
const sm120_asm = @import("sm120_asm.sig");
const emu = @import("sm120_emu.sig");
const qmd = @import("qmd.sig");
const push = @import("push.sig");
const emu3d = @import("emu3d.sig");
const gr = @import("draw.sig");

pub const Error = error{
    OutOfMemory,
    SubmitFailed,
    Timeout,
    /// The GPU faulted or hung; the work did not complete.
    DeviceLost,
    BadStream,
};

pub const Buffer = struct {
    va: u64 = 0,
    cpu: []u8 = &.{},
    /// Driver's handle.
    handle: u32 = 0,

    pub fn words(b: Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, b.cpu[0 .. b.cpu.len & ~@as(usize, 3)]));
    }
};

pub const Fence = u64;

pub const Device = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    /// The GPU's timestamps' rate (its global timer counts ns).
    timestamp_hz: u64 = push.TIMESTAMP_HZ,

    pub const VTable = struct {
        alloc: *const fn (ctx: *anyopaque, size: usize) ?Buffer,
        free: *const fn (ctx: *anyopaque, b: Buffer) void,
        /// Run `dwords` of pushbuffer at the start of `pb`.
        submit: *const fn (ctx: *anyopaque, pb: Buffer, dwords: u32) Error!Fence,
        wait: *const fn (ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void,
        /// Make CPU writes to b[off..off+len] visible to the GPU.
        toDevice: *const fn (ctx: *anyopaque, b: Buffer, off: usize, len: usize) void,
        /// Make GPU writes to b[off..off+len] visible to the CPU.
        fromDevice: *const fn (ctx: *anyopaque, b: Buffer, off: usize, len: usize) void,
    };

    pub fn alloc(d: Device, size: usize) Error!Buffer {
        return d.vtable.alloc(d.ctx, size) orelse error.OutOfMemory;
    }
    pub fn free(d: Device, b: Buffer) void {
        d.vtable.free(d.ctx, b);
    }
    pub fn submit(d: Device, pb: Buffer, dwords: u32) Error!Fence {
        return d.vtable.submit(d.ctx, pb, dwords);
    }
    pub fn wait(d: Device, f: Fence, timeout_us: u64) Error!void {
        return d.vtable.wait(d.ctx, f, timeout_us);
    }
    pub fn toDevice(d: Device, b: Buffer, off: usize, len: usize) void {
        d.vtable.toDevice(d.ctx, b, off, len);
    }
    pub fn fromDevice(d: Device, b: Buffer, off: usize, len: usize) void {
        d.vtable.fromDevice(d.ctx, b, off, len);
    }
    /// Run and wait.
    pub fn run(d: Device, pb: Buffer, dwords: u32, timeout_us: u64) Error!void {
        d.toDevice(pb, 0, dwords * 4);
        const f = try d.submit(pb, dwords);
        try d.wait(f, timeout_us);
    }
};

// ── The emulated GPU ────────────────────────────────────────────────────────

/// (a GL scene makes hundreds: its images, buffers and pipelines' code)
pub const EMU_MAX_BUFFERS = 1024;
pub const EMU_MAX_PROGRAMS = 16;
const ICACHE = 16;
/// The compute engine's methods, by address / 4.
const METHODS = 0x1000;

/// Caller-owned state of an emulated RTX.
pub const EmuDevice = struct {
    /// Memory buffers come from (bump-allocated, GPU addresses from va_base).
    arena: []u8,
    used: usize = 0,
    /// (Galaxy's VRAM window in the work VA space)
    va_base: u64 = 0x10_0000_0000,
    regions: [EMU_MAX_BUFFERS]emu.Region = undefined,
    n_regions: usize = 0,
    /// The GPU's own memory (as long as `arena`), or none: the GPU then sees
    /// the CPU's bytes directly. With it the two views are apart, as VRAM
    /// behind BAR1 is: the GPU sees what toDevice copied over and the CPU
    /// what fromDevice copied back, so a missing call gives wrong results
    /// here, not only on hardware.
    gpu_view: []u8 = &.{},
    /// The emulator's working storage (the caller's: about 9 MB, static).
    work: *emu.Work,
    stats: emu.Stats = .{},
    /// The last submit's fence, and the device's own semaphore its release
    /// writes after each pushbuffer (what `wait` reads).
    fence: u64 = 0,
    fence_sem: ?Buffer = null,
    last_error: ?anyerror = null,
    /// What went wrong in the last kernel, when it was the kernel.
    trap: emu.Trap = .{},
    /// A fake clock (ns): reports and the global timer read it.
    clock_ns: u64 = 0,
    launches: u64 = 0,
    /// Run only every n-th CTA of each grid (sampled runs of huge grids).
    cta_first: u64 = 0,
    cta_stride: u64 = 1,
    /// GR's design as GSP-RM reports it, for local memory's sizes (the
    /// Legion's GB206: 48 warps an SM, 2 SMs a TPC, 3 GPCs of 8 TPCs).
    warps_per_sm: u32 = 48,
    sms_per_tpc: u32 = 2,
    tpcs: u32 = 24,
    sass: u32 = qmd.SASS_SM120,
    /// Kernels given as instructions, for words sm120.decode does not
    /// read yet: a launch whose code matches one's words runs its
    /// instructions (a test hook).
    programs: [EMU_MAX_PROGRAMS]?*const emu.Program = .{null} ** EMU_MAX_PROGRAMS,
    // The channel's state.
    subch: [8]u32 = .{0} ** 8,
    sem_addr: u64 = 0,
    sem_payload: u64 = 0,
    methods: [METHODS]u32 = .{0} ** METHODS,
    /// The SMs' instruction cache: code each address held when it last ran.
    icache: [ICACHE]struct { va: u64, sum: u64 } = undefined,
    n_icache: usize = 0,
    /// The program in the emulator now.
    loaded: ?struct { va: u64, sum: u64, n: usize } = null,
    /// The 3D engine (the caller's storage), or none: the class is then
    /// not on this device, as on a channel no BLACKWELL_B object was
    /// allocated for, and binding it is a refused stream.
    gr3d: ?*emu3d.Engine = null,

    pub fn device(e: *EmuDevice) Device {
        return .{ .ctx = e, .vtable = &vtable };
    }

    const vtable = Device.VTable{
        .alloc = emuAlloc,
        .free = emuFree,
        .submit = emuSubmit,
        .wait = emuWait,
        .toDevice = emuToDevice,
        .fromDevice = emuFromDevice,
    };

    fn self(ctx: *anyopaque) *EmuDevice {
        return @ptrCast(@alignCast(ctx));
    }

    fn emuAlloc(ctx: *anyopaque, size: usize) ?Buffer {
        const e = self(ctx);
        const at = std.mem.alignForward(usize, e.used, 4096);
        return e.mapAt(e.va_base + at, size);
    }

    /// A buffer at a GPU address of the caller's (Galaxy's system memory
    /// mapping, a kernel's fixed output), from the arena.
    pub fn allocAt(e: *EmuDevice, va: u64, size: usize) ?Buffer {
        if (va & 0xfff != 0) return null;
        for (e.regions[0..e.n_regions]) |r| {
            if (va < r.va + r.bytes.len and r.va < va + size) return null;
        }
        return e.mapAt(va, size);
    }

    fn mapAt(e: *EmuDevice, va: u64, size: usize) ?Buffer {
        const at = std.mem.alignForward(usize, e.used, 4096);
        if (at + size > e.arena.len or e.n_regions >= EMU_MAX_BUFFERS) return null;
        if (e.gpu_view.len != 0 and e.gpu_view.len < e.arena.len) return null;
        e.used = at + size;
        const bytes = e.arena[at..][0..size];
        const seen = if (e.gpu_view.len != 0) e.gpu_view[at..][0..size] else bytes;
        // (fresh memory reads as zeros from both sides, as the drivers' does)
        @memset(bytes, 0);
        @memset(seen, 0);
        // (kept in order of va: emu.Memory.find searches them by halves)
        var at_r: usize = e.n_regions;
        while (at_r > 0 and e.regions[at_r - 1].va > va) : (at_r -= 1) e.regions[at_r] = e.regions[at_r - 1];
        e.regions[at_r] = .{ .va = va, .bytes = seen };
        e.n_regions += 1;
        return .{ .va = va, .cpu = bytes, .handle = @intCast(e.n_regions) };
    }

    fn emuFree(ctx: *anyopaque, b: Buffer) void {
        _ = ctx;
        _ = b;
    }

    /// Memory of the caller's own, seen by the GPU at `va` (Galaxy's
    /// kernel twin: a render-node buffer's pages, mapped where the node put
    /// it): no arena used, nothing zeroed, the GPU reading and writing the
    /// caller's bytes (a device with a `gpu_view` takes none). False when
    /// it overlaps a region or the table is full.
    pub fn mapExternal(e: *EmuDevice, va: u64, bytes: []u8) bool {
        if (e.gpu_view.len != 0 or bytes.len == 0 or e.n_regions >= EMU_MAX_BUFFERS) return false;
        for (e.regions[0..e.n_regions]) |r| {
            if (va < r.va + r.bytes.len and r.va < va + bytes.len) return false;
        }
        var at_r: usize = e.n_regions;
        while (at_r > 0 and e.regions[at_r - 1].va > va) : (at_r -= 1) e.regions[at_r] = e.regions[at_r - 1];
        e.regions[at_r] = .{ .va = va, .bytes = bytes };
        e.n_regions += 1;
        return true;
    }

    /// The region at `va` gone: the GPU faults there from now on.
    pub fn unmapExternal(e: *EmuDevice, va: u64) void {
        var i: usize = 0;
        while (i < e.n_regions) : (i += 1) {
            if (e.regions[i].va != va) continue;
            var k = i;
            while (k + 1 < e.n_regions) : (k += 1) e.regions[k] = e.regions[k + 1];
            e.n_regions -= 1;
            return;
        }
    }

    /// A kernel the device runs from its instructions when its words are
    /// at a QMD's program address (until sm120.decode reads them).
    pub fn addProgram(e: *EmuDevice, p: *const emu.Program) Error!void {
        for (&e.programs) |*slot| {
            if (slot.* == null) {
                slot.* = p;
                return;
            }
        }
        return error.OutOfMemory;
    }

    /// The CPU's bytes at [cpu, cpu+len) (inside the arena) to the GPU's view.
    pub fn cpuToGpu(e: *EmuDevice, cpu: usize, len: usize) void {
        const at = e.viewOffset(cpu, len) orelse return;
        @memcpy(e.gpu_view[at..][0..len], e.arena[at..][0..len]);
    }

    /// The GPU's bytes back to the CPU's view of [cpu, cpu+len).
    pub fn gpuToCpu(e: *EmuDevice, cpu: usize, len: usize) void {
        const at = e.viewOffset(cpu, len) orelse return;
        @memcpy(e.arena[at..][0..len], e.gpu_view[at..][0..len]);
    }

    fn viewOffset(e: *const EmuDevice, cpu: usize, len: usize) ?usize {
        if (e.gpu_view.len == 0 or len == 0) return null;
        const base = @intFromPtr(e.arena.ptr);
        if (cpu < base or cpu - base + len > e.arena.len) return null;
        return cpu - base;
    }

    fn emuToDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
        if (off > b.cpu.len or len > b.cpu.len - off) return;
        self(ctx).cpuToGpu(@intFromPtr(b.cpu.ptr) + off, len);
    }

    fn emuFromDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
        if (off > b.cpu.len or len > b.cpu.len - off) return;
        self(ctx).gpuToCpu(@intFromPtr(b.cpu.ptr) + off, len);
    }

    fn memory(e: *const EmuDevice) emu.Memory {
        return .{ .regions = e.regions[0..e.n_regions] };
    }

    fn bytesAt(e: *const EmuDevice, va: u64, n: usize) ?[]u8 {
        const m = e.memory();
        return m.find(va, n);
    }

    /// The device's own semaphore's 32 bits (the GPU's view).
    fn semValue(e: *const EmuDevice) ?u32 {
        const s = e.fence_sem orelse return null;
        const b = e.bytesAt(s.va, 4) orelse return null;
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn emuWait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        const e = self(ctx);
        _ = timeout_us;
        const v = e.semValue() orelse return error.Timeout;
        // (the 32-bit payload, as it wraps)
        if (@as(i32, @bitCast(v -% @as(u32, @truncate(f)))) >= 0) return;
        if (e.last_error != null) return error.DeviceLost;
        return error.Timeout;
    }

    fn emuSubmit(ctx: *anyopaque, pb: Buffer, dwords: u32) Error!Fence {
        const e = self(ctx);
        if (e.fence_sem == null) {
            e.fence_sem = emuAlloc(ctx, 16) orelse return error.OutOfMemory;
        }
        e.fence += 1;
        e.last_error = null;
        e.trap = .{};
        e.execute(pb.va, dwords) catch |err| {
            e.last_error = err;
            if (e.work.trap.what != .none) e.trap = e.work.trap;
            return e.fence;
        };
        // (the device's release after the pushbuffer: the fence)
        const s = e.bytesAt(e.fence_sem.?.va, 4) orelse return error.SubmitFailed;
        std.mem.writeInt(u32, s[0..4], @truncate(e.fence), .little);
        return e.fence;
    }

    /// Run `dwords` of pushbuffer at `va` (the GPU's view of it).
    pub fn execute(e: *EmuDevice, va: u64, dwords: u32) anyerror!void {
        const raw = e.bytesAt(va, @as(usize, dwords) * 4) orelse return error.BadStream;
        var i: usize = 0;
        while (i < dwords) {
            const h = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
            const hd = push.parseHeader(h);
            i += 1;
            switch (hd.op) {
                0 => if (h != 0) return error.BadStream, // (a NOP dword)
                1, 3, 5 => {
                    if (i + hd.count > dwords) return error.BadStream;
                    for (0..hd.count) |k| {
                        const m = switch (hd.op) {
                            1 => hd.method + 4 * @as(u32, @intCast(k)),
                            3 => hd.method,
                            else => if (k == 0) hd.method else hd.method + 4,
                        };
                        try e.method(hd.subch, m, std.mem.readInt(u32, raw[(i + k) * 4 ..][0..4], .little));
                    }
                    i += hd.count;
                },
                4 => try e.method(hd.subch, hd.method, hd.count),
                7 => return, // END_PB_SEGMENT
                else => return error.BadStream,
            }
        }
    }

    fn method(e: *EmuDevice, subch: u3, m: u32, v: u32) anyerror!void {
        if (m == push.SET_OBJECT) {
            // (compute, and the 3D engine where the device has one)
            if (v != push.BLACKWELL_COMPUTE_B and !(v == gr.BLACKWELL_B and e.gr3d != null)) return error.BadStream;
            e.subch[subch] = v;
            return;
        }
        if (m < 0x100) return e.host(m, v);
        if (e.subch[subch] == gr.BLACKWELL_B) {
            const g = e.gr3d orelse return error.BadStream;
            // (a draw runs its programs in the emulator: a kernel's is
            // loaded again at its next launch)
            e.loaded = null;
            return g.method(.{ .mem = e.memory(), .work = e.work }, m, v);
        }
        if (e.subch[subch] != push.BLACKWELL_COMPUTE_B or m / 4 >= METHODS) return error.BadStream;
        e.methods[m / 4] = v;
        switch (m) {
            push.SEND_SIGNALING_PCAS2_B => switch (v & 0xf) {
                push.PCAS_SCHEDULE, push.PCAS_PREFETCH_SCHEDULE, 3, 0xa => try e.launch(@as(u64, e.methods[push.SEND_PCAS_A / 4]) << 8),
                0, 1, push.PCAS_PREFETCH => {},
                else => return error.BadStream,
            },
            push.INVALIDATE_SHADER_CACHES => if (v & 1 != 0) {
                e.n_icache = 0;
            },
            push.REPORT_SEMAPHORE_EXECUTE => try e.report(v),
            else => {},
        }
    }

    fn host(e: *EmuDevice, m: u32, v: u32) anyerror!void {
        switch (m) {
            push.SEM_ADDR_LO => e.sem_addr = (e.sem_addr & ~@as(u64, 0xffff_ffff)) | (v & 0xffff_fffc),
            push.SEM_ADDR_HI => e.sem_addr = (e.sem_addr & 0xffff_ffff) | (@as(u64, v & 0x1ff_ffff) << 32),
            push.SEM_PAYLOAD_LO => e.sem_payload = (e.sem_payload & ~@as(u64, 0xffff_ffff)) | v,
            push.SEM_PAYLOAD_HI => e.sem_payload = (e.sem_payload & 0xffff_ffff) | (@as(u64, v) << 32),
            push.SEM_EXECUTE => {
                const wide = v & push.SEM_PAYLOAD_64BIT != 0;
                const n: usize = if (wide) 8 else 4;
                const b = e.bytesAt(e.sem_addr, n) orelse return error.BadStream;
                switch (v & 7) {
                    push.SEM_OPERATION_RELEASE => {
                        // (everything before it is done: the emulator runs in order)
                        if (wide) std.mem.writeInt(u64, b[0..8], e.sem_payload, .little) else std.mem.writeInt(u32, b[0..4], @truncate(e.sem_payload), .little);
                    },
                    push.SEM_OPERATION_ACQUIRE => {
                        const have: u64 = if (wide) std.mem.readInt(u64, b[0..8], .little) else std.mem.readInt(u32, b[0..4], .little);
                        const want: u64 = if (wide) e.sem_payload else e.sem_payload & 0xffff_ffff;
                        // (nothing else runs to release it: the channel would hang)
                        if (have != want) return error.Timeout;
                    },
                    else => return error.BadStream,
                }
            },
            else => return error.BadStream,
        }
    }

    /// REPORT_SEMAPHORE_EXECUTE: a release, with the timestamp for a four-
    /// word one.
    fn report(e: *EmuDevice, v: u32) anyerror!void {
        const r = &e.methods;
        const va = @as(u64, r[0x164 / 4] & 0x1ff_ffff) << 32 | r[0x160 / 4];
        const payload = @as(u64, r[0x15c / 4]) << 32 | r[0x158 / 4];
        if (v & 3 != push.REPORT_RELEASE and v & 3 != 2) return error.BadStream;
        switch ((v >> 3) & 3) {
            0 => {
                const b = e.bytesAt(va, 16) orelse return error.BadStream;
                std.mem.writeInt(u64, b[0..8], if (v & (1 << 12) != 0) payload else payload & 0xffff_ffff, .little);
                std.mem.writeInt(u64, b[8..16], e.clock_ns, .little);
            },
            1 => {
                const b = e.bytesAt(va, 4) orelse return error.BadStream;
                std.mem.writeInt(u32, b[0..4], @truncate(payload), .little);
            },
            2 => {
                const b = e.bytesAt(va, 8) orelse return error.BadStream;
                std.mem.writeInt(u64, b[0..8], payload, .little);
            },
            else => return error.BadStream,
        }
    }

    fn checksum(words: []const u8) u64 {
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (words) |b| h = (h ^ b) *% 0x100_0000_01b3;
        return h;
    }

    /// The program at `va`: its instructions until the first all-zero one
    /// (ptxas's code never has one; Galaxy leaves 4 KiB of zeros after it),
    /// within its buffer.
    fn programAt(e: *const EmuDevice, va: u64) ?[]const u8 {
        for (e.regions[0..e.n_regions]) |r| {
            if (va < r.va or va >= r.va + r.bytes.len) continue;
            const all = r.bytes[@intCast(va - r.va)..];
            var n: usize = 0;
            while (n + 16 <= all.len and n < emu.MAX_INSTRS * 16) : (n += 16) {
                if (std.mem.allEqual(u8, all[n..][0..16], 0)) break;
            }
            return all[0..n];
        }
        return null;
    }

    /// The QMD at `qmd_va` launched: read as the compute engine reads it,
    /// its grid run in the emulator.
    fn launch(e: *EmuDevice, qmd_va: u64) anyerror!void {
        const raw = e.bytesAt(qmd_va, qmd.QMD_BYTES) orelse return error.BadStream;
        var q: [qmd.QMD_WORDS]u32 = undefined;
        for (&q, 0..) |*x, k| x.* = std.mem.readInt(u32, raw[k * 4 ..][0..4], .little);
        const d = qmd.decode(&q) catch return error.BadStream;
        if (d.sass != e.sass) return error.BadStream;
        var l = emu.Launch{
            .grid = d.grid,
            .block = d.block,
            .registers = d.registers,
            .shared_bytes = d.shared_bytes,
            .local_low = d.local_low,
            .local_high = d.local_high,
            .cta_first = e.cta_first,
            .cta_stride = e.cta_stride,
            .timer_ns = e.clock_ns,
        };
        for (d.cbufs, 0..) |cb, k| {
            if (!cb.valid) continue;
            l.cbufs[k] = e.bytesAt(cb.va, cb.bytes) orelse return error.BadStream;
        }
        // Shared memory within the SM's split for it.
        const cfg = d.sm_config;
        if (cfg.min > cfg.target or cfg.target > cfg.max or cfg.max > qmd.SM_CONFIG_MAX or d.shared_bytes > qmd.smConfigBytes(cfg.target)) return error.BadStream;
        // Local memory: set up, and enough for every TPC's warps.
        const per_thread = d.local_low + d.local_high;
        if (per_thread > 0) {
            const base = @as(u64, e.methods[push.SET_SHADER_LOCAL_MEMORY_A / 4]) << 32 | e.methods[push.SET_SHADER_LOCAL_MEMORY_B / 4];
            const per_tpc = @as(u64, e.methods[push.SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_A / 4]) << 32 | e.methods[push.SET_SHADER_LOCAL_MEMORY_NON_THROTTLED_B / 4];
            if (base == 0 or per_tpc < qmd.perTpc(per_thread, e.warps_per_sm, e.sms_per_tpc)) return error.BadStream;
            if (e.bytesAt(base, @intCast(per_tpc * e.tpcs)) == null) return error.BadStream;
        }
        // The code: what the SMs' cache holds must be what memory does.
        const code = e.programAt(d.prog_va) orelse return error.BadStream;
        const sum = checksum(code);
        var cached = false;
        for (e.icache[0..e.n_icache]) |x| {
            if (x.va != d.prog_va) continue;
            if (x.sum != sum) return error.BadStream; // (stale: INVALIDATE_SHADER_CACHES missing)
            cached = true;
        }
        if (!cached and e.n_icache < ICACHE) {
            e.icache[e.n_icache] = .{ .va = d.prog_va, .sum = sum };
            e.n_icache += 1;
        }
        if (e.loaded == null or e.loaded.?.va != d.prog_va or e.loaded.?.sum != sum) {
            e.loaded = null;
            try e.loadCode(code);
            e.loaded = .{ .va = d.prog_va, .sum = sum, .n = code.len };
        }
        var stats = emu.Stats{};
        const mem = e.memory();
        try emu.run(e.work, &mem, &l, &stats);
        e.launches += 1;
        e.stats.ctas += stats.ctas;
        e.stats.warps += stats.warps;
        e.stats.instructions += stats.instructions;
        e.stats.thread_instructions += stats.thread_instructions;
        e.stats.global_read += stats.global_read;
        e.stats.global_written += stats.global_written;
        e.stats.hazard_checks += stats.hazard_checks;
        e.stats.cycles = @max(e.stats.cycles, stats.cycles);
        // (a nominal 1 GHz: the longest warp's cycles, and a launch's cost)
        e.clock_ns += 1000 + stats.cycles;
        if (d.release) |r| {
            switch (r.structure) {
                1 => {
                    const b = e.bytesAt(r.va, 4) orelse return error.BadStream;
                    std.mem.writeInt(u32, b[0..4], @truncate(r.payload), .little);
                },
                else => {
                    const b = e.bytesAt(r.va, if (r.structure == 0) 16 else 8) orelse return error.BadStream;
                    std.mem.writeInt(u64, b[0..8], r.payload, .little);
                    if (r.structure == 0) std.mem.writeInt(u64, b[8..16], e.clock_ns, .little);
                },
            }
        }
    }

    fn loadCode(e: *EmuDevice, code: []const u8) anyerror!void {
        const words: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, code));
        for (e.programs) |slot| {
            const p = slot orelse continue;
            if (p.words.len <= words.len and std.mem.eql(u64, p.words, words[0..p.words.len])) return emu.loadProgram(e.work, p);
        }
        return emu.loadWords(e.work, words);
    }
};

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Galaxy's nv_bench: the kernels' parameters (their order and alignment:
/// galaxy's nv_ptx/m5.ptx) and what they compute.
const bench = struct {
    const FillParams = extern struct { dst: u64, n: u32, seed: u32 };
    const CopyParams = extern struct { dst: u64, src: u64, n4: u32 };
    const MatmulParams = extern struct { c: u64, a: u64, b: u64, n: u32 };
    const LocalParams = extern struct { out: u64 };

    const SEED: u32 = 0x5eed_6a1a;

    fn fillWord(i: u32, seed: u32) u32 {
        return (i *% 0x9e37_79b1) ^ seed;
    }
    fn aOf(r: u32, k: u32) f32 {
        return @floatFromInt(@as(i32, @intCast((r * 3 + k) % 7)) - 3);
    }
    fn bOf(k: u32, c: u32) f32 {
        return @floatFromInt(@as(i32, @intCast((k * 3 + c * 2) % 5)) - 2);
    }
    fn cOf(r: u32, c: u32, n: u32) f32 {
        var s: f32 = 0;
        var k: u32 = 0;
        while (k < n) : (k += 1) s += aOf(r, k) * bOf(k, c);
        return s;
    }
    fn localWord(t: u32) u32 {
        return t * 256 + 120;
    }
};

/// The probe kernel `name`'s listing from sm120_vectors.txt as an author
/// writes it: with ptxas's control fields, or (`plain`) without them and
/// without ptxas's padding, for sm120_asm to schedule.
fn listing(name: []const u8, plain: bool, out: []u8) ![]const u8 {
    const data = @embedFile("sm120_vectors.txt");
    var kernels = std.mem.splitSequence(u8, data, "# kernel ");
    _ = kernels.next();
    while (kernels.next()) |block| {
        const head_end = std.mem.indexOfScalar(u8, block, '\n') orelse return error.TestUnexpectedResult;
        const head = block[0..head_end];
        if (!std.mem.startsWith(u8, head, name) or head[name.len] != ' ') continue;
        const field = struct {
            fn get(h: []const u8, f: []const u8) !u32 {
                const at = (std.mem.indexOf(u8, h, f) orelse return error.TestUnexpectedResult) + f.len + 1;
                var end = at;
                while (end < h.len and std.ascii.isDigit(h[end])) end += 1;
                return std.fmt.parseInt(u32, h[at..end], 10);
            }
        };
        var len = (try std.fmt.bufPrint(out, ".params {d}\n.stack {d}\n", .{ try field.get(head, "params"), try field.get(head, "stack") })).len;
        var lines = std.mem.splitScalar(u8, block[head_end + 1 ..], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            var body = if (line[line.len - 1] == ':') line else line[34..];
            if (plain and body[0] == '[') {
                body = body[22..];
                if (std.mem.eql(u8, body, "NOP")) continue;
            }
            @memcpy(out[len..][0..body.len], body);
            out[len + body.len] = '\n';
            len += body.len + 1;
        }
        return out[0..len];
    }
    return error.TestUnexpectedResult;
}

const T = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var gpu_view: [24 << 20]u8 align(4096) = undefined;
    var dev: EmuDevice = undefined;
    var work: emu.Work = .{};
    var asm_work: sm120_asm.Work = .{};
    var code: [2 * sm120_asm.MAX_INSTRS]u64 = undefined;
    var text: [48 * 1024]u8 = undefined;
};

fn freshDevice(apart: bool) Device {
    T.dev = .{ .arena = &T.arena, .gpu_view = if (apart) &T.gpu_view else &.{}, .work = &T.work, .tpcs = 1 };
    return T.dev.device();
}

/// A kernel's code in a buffer of its own (256-aligned, 4 KiB of zeros
/// after it, as Galaxy's code slots are), handed to the GPU.
fn upload(d: Device, k: sm120_asm.Kernel) !Buffer {
    const b = try d.alloc(k.code.len * 8 + 4096);
    @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, b.cpu[0 .. k.code.len * 8]))), k.code);
    d.toDevice(b, 0, b.cpu.len);
    return b;
}

const Run = struct {
    grid: [3]u32 = .{ 1, 1, 1 },
    block: [3]u32 = .{ 1, 1, 1 },
    params: []const u8 = &.{},
    local: ?push.Local = null,
    local_bytes: u32 = 0,
};

/// One launch as Galaxy's runBatch makes it: the QMD and constant buffer 0
/// in a slot, a batch's pushbuffer ending in the host's release; run and
/// waited for.
fn launchOne(d: Device, code: Buffer, k: sm120_asm.Kernel, r: Run) !void {
    const slot = try d.alloc(0x800);
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
    try qmd.build(q, .{ .prog_va = code.va, .prog_bytes = k.code.len * 8, .cbuf_va = slot.va + 0x200, .registers = k.registers, .grid = r.grid, .block = r.block, .local_bytes = r.local_bytes });
    const cb: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0x200..][0..qmd.CBUF0_BYTES]));
    try qmd.cbuf0(cb, r.grid, r.block, r.params[0..@min(r.params.len, k.params)]);
    d.toDevice(slot, 0, slot.cpu.len);
    const sem = try d.alloc(16);
    const pb = try d.alloc(4096);
    const n = try push.batchPush(pb.words(), &.{slot.va}, r.local, sem.va, 0x1234);
    try d.run(pb, @intCast(n), 1_000_000);
    d.fromDevice(sem, 0, 4);
    try testing.expectEqual(@as(u32, 0x1234), sem.words()[0]);
}

fn assembleProbe(name: []const u8, plain: bool) !sm120_asm.Kernel {
    const text = try listing(name, plain, &T.text);
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    try testing.expectEqual(plain, k.scheduled);
    return k;
}

fn expectLast(e: anyerror) !void {
    try testing.expectEqual(@as(?anyerror, e), T.dev.last_error);
}

fn lost(d: Device) void {
    _ = d;
    var buf: [256]u8 = undefined;
    std.debug.print("device: {s}: {s}\n", .{ if (T.dev.last_error) |x| @errorName(x) else "-", emu.explain(T.dev.work, &buf) });
}

/// Galaxy's five probe kernels through the emulated device, as nv_bench
/// runs them on the RTX, with the results it checks.
fn probes(plain: bool) !void {
    const d = freshDevice(true);
    errdefer lost(d);
    // M4: 32 threads write 0x600d0000 | their index to 0x20_0005_0000.
    {
        const k = try assembleProbe("galaxy_m4", plain);
        const code = try upload(d, k);
        const out = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
        try launchOne(d, code, k, .{ .block = .{ 32, 1, 1 } });
        d.fromDevice(out, 0, 128);
        for (out.words()[0..32], 0..) |v, i| try testing.expectEqual(0x600d_0000 | @as(u32, @intCast(i)), v);
    }
    // local: a 64-byte stack array each (local memory, sized as Galaxy
    // sizes it): out[t] = t * 256 + 120.
    {
        const k = try assembleProbe("galaxy_local", plain);
        const code = try upload(d, k);
        const out = try d.alloc(4096);
        const s = qmd.localSize(k.stack, T.dev.warps_per_sm, T.dev.sms_per_tpc, T.dev.tpcs);
        const lm = try d.alloc(@intCast(s.total));
        const p = bench.LocalParams{ .out = out.va };
        try launchOne(d, code, k, .{ .block = .{ 32, 1, 1 }, .params = std.mem.asBytes(&p), .local = .{ .va = lm.va, .per_tpc = s.per_tpc }, .local_bytes = s.per_thread });
        d.fromDevice(out, 0, 128);
        for (out.words()[0..32], 0..) |v, t| try testing.expectEqual(bench.localWord(@intCast(t)), v);
    }
    // fill and copy: 4 MiB filled with the pattern by 1024 CTAs of 256
    // (4 words a thread), copied in 16-byte words, every word checked.
    {
        const words: u32 = 1 << 20;
        const src = try d.alloc(words * 4);
        const dst = try d.alloc(words * 4);
        const kf = try assembleProbe("galaxy_fill", plain);
        const fill_code = try upload(d, kf);
        const f = bench.FillParams{ .dst = src.va, .n = words, .seed = bench.SEED };
        try launchOne(d, fill_code, kf, .{ .grid = .{ 1024, 1, 1 }, .block = .{ 256, 1, 1 }, .params = std.mem.asBytes(&f) });
        const kc = try assembleProbe("galaxy_copy", plain);
        const copy_code = try upload(d, kc);
        const c = bench.CopyParams{ .dst = dst.va, .src = src.va, .n4 = words / 4 };
        try launchOne(d, copy_code, kc, .{ .grid = .{ 128, 1, 1 }, .block = .{ 256, 1, 1 }, .params = std.mem.asBytes(&c) });
        d.fromDevice(dst, 0, dst.cpu.len);
        for (dst.words(), 0..) |v, i| {
            if (v != bench.fillWord(@intCast(i), bench.SEED)) {
                std.debug.print("copy: word {d} is {x}\n", .{ i, v });
                return error.TestUnexpectedResult;
            }
        }
    }
    // matmul: 512 x 512 fp32 of small integers (every sum exact), every
    // 37th CTA of the 32 x 32 run (the rest stay zero), and a 37 x 37
    // whole (its loop's remainder paths).
    {
        const k = try assembleProbe("galaxy_matmul", plain);
        const code = try upload(d, k);
        for ([_]u32{ 512, 37 }) |n| {
            const bytes = n * n * 4;
            const a = try d.alloc(bytes);
            const b = try d.alloc(bytes);
            const c = try d.alloc(bytes);
            for (0..n) |r| {
                for (0..n) |kk| {
                    a.words()[r * n + kk] = @bitCast(bench.aOf(@intCast(r), @intCast(kk)));
                    b.words()[r * n + kk] = @bitCast(bench.bOf(@intCast(r), @intCast(kk)));
                }
            }
            d.toDevice(a, 0, bytes);
            d.toDevice(b, 0, bytes);
            const p = bench.MatmulParams{ .c = c.va, .a = a.va, .b = b.va, .n = n };
            const g = (n + 15) / 16;
            const stride: u64 = if (n == 512) 37 else 1;
            T.dev.cta_stride = stride;
            defer T.dev.cta_stride = 1;
            try launchOne(d, code, k, .{ .grid = .{ g, g, 1 }, .block = .{ 16, 16, 1 }, .params = std.mem.asBytes(&p) });
            d.fromDevice(c, 0, bytes);
            var checked: usize = 0;
            for (0..n) |r| {
                for (0..n) |col| {
                    const cta = (r / 16) * g + col / 16;
                    const ran = cta % stride == 0;
                    const want: f32 = if (ran) bench.cOf(@intCast(r), @intCast(col), n) else 0;
                    const got: f32 = @bitCast(c.words()[r * n + col]);
                    if (got != want) {
                        std.debug.print("matmul {d}: c[{d}][{d}] is {d}, not {d}\n", .{ n, r, col, got, want });
                        return error.TestUnexpectedResult;
                    }
                    checked += @intFromBool(ran);
                }
            }
            try testing.expect(checked >= if (n == 512) 28 * 256 else n * n);
        }
    }
}

test "Galaxy's five probe kernels, ptxas's control fields, on the emulated RTX: nv_bench's results" {
    try probes(false);
    try testing.expect(T.dev.stats.hazard_checks > 1_000_000);
    try testing.expectEqual(@as(u64, 6), T.dev.launches);
}

test "the same kernels without their control fields, scheduled by sm120_asm: hazard-free, at NAK's level too" {
    try probes(true);
    // (strict: what sm120_sched guarantees, NAK's padding and every read
    // scoreboard waited on)
    T.work.strict = true;
    defer T.work.strict = false;
    try probes(true);
    // (ptxas's own fields are a cycle short of NAK's padding)
    const d = freshDevice(false);
    _ = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
    const kp = try assembleProbe("galaxy_m4", false);
    const code_p = try upload(d, kp);
    try testing.expectError(error.DeviceLost, launchOne(d, code_p, kp, .{ .block = .{ 32, 1, 1 } }));
    try expectLast(error.Hazard);
}

/// M4 with one control field changed.
fn brokenM4(from: []const u8, to: []const u8) !void {
    const d = freshDevice(false);
    const text = try listing("galaxy_m4", false, &T.text);
    const at = std.mem.indexOf(u8, text, from) orelse return error.TestUnexpectedResult;
    @memcpy(T.text[at..][0..to.len], to);
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    const code = try upload(d, k);
    _ = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
    try testing.expectError(error.DeviceLost, launchOne(d, code, k, .{ .block = .{ 32, 1, 1 } }));
    try expectLast(error.Hazard);
}

test "a kernel with a broken control field fails with Hazard: a stall cut short, a missing wait" {
    // (LOP3's result to the store: 5 cycles; 4)
    try brokenM4("[B------:R-:W-:-:S05] LOP3.LUT", "[B------:R-:W-:-:S04] LOP3.LUT");
    try testing.expectEqual(emu.HazardKind.raw, T.dev.trap.hazard);
    try testing.expectEqual(@as(u64, 0x60), T.dev.trap.pc); // (the STG)
    try testing.expectEqual(@as(u8, 5), T.dev.trap.reg);
    try testing.expect(!T.dev.trap.scoreboard);
    // (the store does not wait on LDCU's scoreboard for its descriptor)
    try brokenM4("[B-1----:R-:W-:Y:S01] STG", "[B------:R-:W-:Y:S01] STG");
    try testing.expect(T.dev.trap.scoreboard);
    try testing.expectEqual(@as(u64, 0x60), T.dev.trap.pc);
    try testing.expectEqual(@as(u64, 0x20), T.dev.trap.other_pc); // (LDCU)
    // (IMAD.WIDE reads S2R's result without waiting)
    try brokenM4("[B0-----:R-:W-:Y:S01] IMAD.WIDE", "[B------:R-:W-:Y:S01] IMAD.WIDE");
    try testing.expectEqual(@as(u8, 5), T.dev.trap.reg);
    try testing.expectEqual(@as(u64, 0x10), T.dev.trap.other_pc); // (S2R)
}

test "the emulated RTX catches what the real one trips over" {
    var d = freshDevice(true);
    const k = try assembleProbe("galaxy_m4", false);
    _ = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
    // (the code not handed to the GPU: zeros at the program address)
    {
        const b = try d.alloc(k.code.len * 8 + 4096);
        @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, b.cpu[0 .. k.code.len * 8]))), k.code);
        try testing.expectError(error.DeviceLost, launchOne(d, b, k, .{ .block = .{ 32, 1, 1 } }));
        try expectLast(error.BadInstruction);
    }
    const code = try upload(d, k);
    try launchOne(d, code, k, .{ .block = .{ 32, 1, 1 } });
    // (new code at the same address, the shader caches not invalidated)
    {
        const kl = try assembleProbe("galaxy_fill", false);
        @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, code.cpu[0 .. kl.code.len * 8]))), kl.code);
        d.toDevice(code, 0, kl.code.len * 8);
        const slot = try d.alloc(0x800);
        const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
        try qmd.build(q, .{ .prog_va = code.va, .prog_bytes = kl.code.len * 8, .cbuf_va = slot.va + 0x200, .registers = kl.registers, .block = .{ 32, 1, 1 } });
        d.toDevice(slot, 0, slot.cpu.len);
        const pb = try d.alloc(4096);
        var p = push.Push{ .buf = pb.words() };
        p.computeSetup(.{});
        p.launch(slot.va);
        try p.check();
        try testing.expectError(error.DeviceLost, d.run(pb, @intCast(p.len), 1000));
        try expectLast(error.BadStream);
    }
    // (a kernel with a stack, and no local memory set up)
    d = freshDevice(false);
    {
        const kl = try assembleProbe("galaxy_local", false);
        const lc = try upload(d, kl);
        const out = try d.alloc(4096);
        const pr = bench.LocalParams{ .out = out.va };
        try testing.expectError(error.DeviceLost, launchOne(d, lc, kl, .{ .block = .{ 32, 1, 1 }, .params = std.mem.asBytes(&pr), .local_bytes = 0x280 }));
        try expectLast(error.BadStream);
    }
    // (methods to a subchannel with no object; a QMD for another SM)
    {
        const pb = try d.alloc(4096);
        pb.words()[0] = push.header(2, push.INVALIDATE_SHADER_CACHES, 1);
        pb.words()[1] = push.INVALIDATE_ALL;
        try testing.expectError(error.DeviceLost, d.run(pb, 2, 1000));
        try expectLast(error.BadStream);
        const kk = try assembleProbe("galaxy_m4", false);
        const c2 = try upload(d, kk);
        const slot = try d.alloc(0x800);
        const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
        try qmd.build(q, .{ .prog_va = c2.va, .prog_bytes = kk.code.len * 8, .cbuf_va = slot.va + 0x200, .registers = kk.registers, .block = .{ 32, 1, 1 }, .sass = qmd.sassOf(0x900) });
        const n = try push.batchPush(pb.words(), &.{slot.va}, null, slot.va + 0x700, 1);
        try testing.expectError(error.DeviceLost, d.run(pb, @intCast(n), 1000));
        try expectLast(error.BadStream);
    }
    // (and the fence after a good batch)
    const f = try d.submit(try d.alloc(16), 0);
    try d.wait(f, 0);
}

test "memory of the caller's own, mapped at its addresses: a launch reads and writes it there, and faults once it is gone" {
    _ = freshDevice(false);
    const k = try assembleProbe("galaxy_m4", false);
    const X = struct {
        var code: [0x4000]u8 align(4096) = undefined;
        var slot: [0x1000]u8 align(4096) = undefined;
        var out: [0x1000]u8 align(4096) = undefined;
        var pb: [0x1000]u8 align(4096) = undefined;
    };
    @memset(&X.code, 0);
    @memset(&X.slot, 0);
    @memset(&X.out, 0);
    // (where a render node's buffers are, and the probe's fixed output)
    const code_va: u64 = 0x40_0000_0000;
    const slot_va: u64 = 0x40_0020_0000;
    const pb_va: u64 = 0x40_0040_0000;
    try testing.expect(T.dev.mapExternal(code_va, &X.code));
    try testing.expect(T.dev.mapExternal(slot_va, &X.slot));
    try testing.expect(T.dev.mapExternal(pb_va, &X.pb));
    try testing.expect(T.dev.mapExternal(0x20_0005_0000, &X.out));
    // (an overlap refused)
    try testing.expect(!T.dev.mapExternal(slot_va + 0x800, &X.out));
    @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, X.code[0 .. k.code.len * 8]))), k.code);
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(X.slot[0..qmd.QMD_BYTES]));
    try qmd.build(q, .{ .prog_va = code_va, .prog_bytes = k.code.len * 8, .cbuf_va = slot_va + 0x200, .registers = k.registers, .block = .{ 32, 1, 1 } });
    try qmd.cbuf0(@ptrCast(@alignCast(X.slot[0x200..][0..qmd.CBUF0_BYTES])), .{ 1, 1, 1 }, .{ 32, 1, 1 }, &.{});
    var p = push.Push{ .buf = std.mem.bytesAsSlice(u32, &X.pb) };
    p.computeSetup(.{});
    p.invalidateShaderCaches();
    p.launch(slot_va);
    p.release(slot_va + 0x780, 77);
    try p.check();
    try T.dev.execute(pb_va, @intCast(p.len));
    // (the probe writes 0x600d0000 | its thread index to the fixed output)
    const out = std.mem.bytesAsSlice(u32, &X.out);
    for (0..32) |i| try testing.expectEqual(@as(u32, 0x600d_0000) | @as(u32, @intCast(i)), out[i]);
    try testing.expectEqual(@as(u32, 77), std.mem.readInt(u32, X.slot[0x780..][0..4], .little));
    // Unmapped, the pushbuffer is gone: the stream fails.
    T.dev.unmapExternal(pb_va);
    try testing.expectError(error.BadStream, T.dev.execute(pb_va, @intCast(p.len)));
    // (a device whose GPU has a view of its own takes none)
    _ = freshDevice(true);
    try testing.expect(!T.dev.mapExternal(code_va, &X.code));
}

test "a timestamp report, a QMD's own release" {
    const d = freshDevice(false);
    const k = try assembleProbe("galaxy_m4", false);
    const code = try upload(d, k);
    _ = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
    const slot = try d.alloc(0x800);
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
    try qmd.build(q, .{ .prog_va = code.va, .prog_bytes = k.code.len * 8, .cbuf_va = slot.va + 0x200, .registers = k.registers, .block = .{ 32, 1, 1 } });
    qmd.release(q, slot.va + 0x780, 99);
    try qmd.cbuf0(@ptrCast(@alignCast(slot.cpu[0x200..][0..qmd.CBUF0_BYTES])), .{ 1, 1, 1 }, .{ 32, 1, 1 }, &.{});
    const pb = try d.alloc(4096);
    var p = push.Push{ .buf = pb.words() };
    p.computeSetup(.{});
    p.reportTimestamp(slot.va + 0x700, 1);
    p.invalidateShaderCaches();
    p.launch(slot.va);
    p.reportTimestamp(slot.va + 0x710, 2);
    try p.check();
    try d.run(pb, @intCast(p.len), 1000);
    const w = slot.words();
    try testing.expectEqual(@as(u32, 1), w[0x700 / 4]);
    try testing.expectEqual(@as(u32, 2), w[0x710 / 4]);
    const t0 = @as(u64, w[0x70c / 4]) << 32 | w[0x708 / 4];
    const t1 = @as(u64, w[0x71c / 4]) << 32 | w[0x718 / 4];
    try testing.expect(t1 > t0);
    try testing.expectEqual(@as(u32, 99), w[0x780 / 4]);
    try testing.expectEqual(push.TIMESTAMP_HZ, d.timestamp_hz);
}

test "a kernel given as instructions (the hook for words sm120.decode does not read yet)" {
    const d = freshDevice(false);
    const k = try assembleProbe("galaxy_m4", false);
    const S = struct {
        var instrs: [64]sm120.Instr = undefined;
        var targets: [64]?u64 = undefined;
        var words: [128]u64 = undefined;
    };
    @memcpy(S.words[0..k.code.len], k.code);
    var prog = try emu.Program.fromAssembly(&T.asm_work, k, &S.instrs, &S.targets);
    prog.words = S.words[0..k.code.len];
    try T.dev.addProgram(&prog);
    const code = try upload(d, k);
    const out = T.dev.allocAt(0x20_0005_0000, 4096) orelse return error.OutOfMemory;
    try launchOne(d, code, k, .{ .block = .{ 32, 1, 1 } });
    try testing.expectEqual(@as(u32, 0x600d_0007), out.words()[7]);
    try testing.expectEqual(@as(?u64, 0x80), S.targets[8]); // (the BRA to itself)
}
