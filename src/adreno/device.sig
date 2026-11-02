//! @zpm/adreno device — what a compute user needs from a GPU driver, and an
//! emulated GPU that provides it.
//!
//! A Device hands out GPU buffers (a GPU address and a CPU view of the same
//! memory), runs command streams from them and reports when they are done.
//! Galaxy's kernel implements it over its Adreno driver; EmuDevice
//! implements it on the CPU: it reads the PM4 stream the way the command
//! processor would (register writes, CP_LOAD_STATE6, CP_EXEC_CS, timestamps)
//! and runs each dispatch in ir3_emu. So a stream that is wrong in what it
//! programs fails here too, not only on the Surface.
//!
//! Allocation-free: buffers come from memory the device owner provides.

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");
const ir3_emu = @import("ir3_emu.sig");
const a7xx = @import("a7xx.sig");

pub const Error = error{
    OutOfMemory,
    SubmitFailed,
    Timeout,
    /// The GPU hung or faulted; the work did not complete.
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
    /// The GPU timestamp counter's rate (CP_ALWAYS_ON_COUNTER).
    timestamp_hz: u64 = 19_200_000,

    pub const VTable = struct {
        alloc: *const fn (ctx: *anyopaque, size: usize) ?Buffer,
        free: *const fn (ctx: *anyopaque, b: Buffer) void,
        /// Run `dwords` of commands at the start of `ib` (an indirect buffer).
        submit: *const fn (ctx: *anyopaque, ib: Buffer, dwords: u32) Error!Fence,
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
    pub fn submit(d: Device, ib: Buffer, dwords: u32) Error!Fence {
        return d.vtable.submit(d.ctx, ib, dwords);
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
    pub fn run(d: Device, ib: Buffer, dwords: u32, timeout_us: u64) Error!void {
        d.toDevice(ib, 0, dwords * 4);
        const f = try d.submit(ib, dwords);
        try d.wait(f, timeout_us);
    }
};

// ── The emulated GPU ────────────────────────────────────────────────────────

pub const EMU_MAX_BUFFERS = 64;

/// Caller-owned state of an emulated GPU (static: it holds the emulator).
pub const EmuDevice = struct {
    /// Memory buffers come from (bump-allocated, GPU addresses from va_base).
    arena: []u8,
    used: usize = 0,
    va_base: u64 = 0x1_0000_0000,
    regions: [EMU_MAX_BUFFERS]ir3_emu.Region = undefined,
    n_regions: usize = 0,
    regs: [0x10000]u32 = [_]u32{0} ** 0x10000,
    consts: [512 * 4]u32 = [_]u32{0} ** (512 * 4),
    emu: ir3_emu.Work = .{},
    stats: ir3_emu.Stats = .{},
    fence: u64 = 0,
    /// A fake clock for CP_REG_TO_MEM of the always-on counter.
    clock: u64 = 0,
    last_error: ?anyerror = null,
    /// Run only every n-th workgroup in x (sampled runs of huge grids).
    group_stride: u32 = 1,
    /// The GPU's own memory (as long as `arena`), or none: the GPU then sees
    /// the CPU's bytes directly. With it, the two views are apart, as on an
    /// Adreno that does not snoop the CPU's caches: the GPU sees what
    /// toDevice copied over and the CPU what fromDevice copied back, so a
    /// missing call gives wrong results here, not only on hardware.
    gpu_view: []u8 = &.{},

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

    fn emuAlloc(ctx: *anyopaque, size: usize) ?Buffer {
        const e: *EmuDevice = @ptrCast(@alignCast(ctx));
        const at = std.mem.alignForward(usize, e.used, 4096);
        if (at + size > e.arena.len or e.n_regions >= EMU_MAX_BUFFERS) return null;
        if (e.gpu_view.len != 0 and e.gpu_view.len < e.arena.len) return null;
        e.used = at + size;
        const va = e.va_base + at;
        const bytes = e.arena[at..][0..size];
        const seen = if (e.gpu_view.len != 0) e.gpu_view[at..][0..size] else bytes;
        // (fresh memory reads as zeros from both sides, as the drivers' does)
        @memset(bytes, 0);
        @memset(seen, 0);
        e.regions[e.n_regions] = .{ .va = va, .bytes = seen };
        e.n_regions += 1;
        return .{ .va = va, .cpu = bytes, .handle = @intCast(e.n_regions) };
    }

    fn emuFree(ctx: *anyopaque, b: Buffer) void {
        _ = ctx;
        _ = b;
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
        std.debug.assert(cpu >= base and cpu - base + len <= e.arena.len);
        return cpu - base;
    }

    fn emuToDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
        const e: *EmuDevice = @ptrCast(@alignCast(ctx));
        std.debug.assert(off + len <= b.cpu.len);
        e.cpuToGpu(@intFromPtr(b.cpu.ptr) + off, len);
    }

    fn emuFromDevice(ctx: *anyopaque, b: Buffer, off: usize, len: usize) void {
        const e: *EmuDevice = @ptrCast(@alignCast(ctx));
        std.debug.assert(off + len <= b.cpu.len);
        e.gpuToCpu(@intFromPtr(b.cpu.ptr) + off, len);
    }

    fn emuWait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        const e: *EmuDevice = @ptrCast(@alignCast(ctx));
        _ = timeout_us;
        if (f > e.fence) return error.Timeout;
        if (e.last_error != null) return error.DeviceLost;
    }

    fn emuSubmit(ctx: *anyopaque, ib: Buffer, dwords: u32) Error!Fence {
        const e: *EmuDevice = @ptrCast(@alignCast(ctx));
        e.fence += 1;
        e.last_error = null;
        e.execute(ib.va, dwords, 0) catch |err| {
            e.last_error = err;
        };
        return e.fence;
    }

    fn memory(e: *EmuDevice) ir3_emu.Memory {
        return .{ .regions = e.regions[0..e.n_regions] };
    }

    fn words(e: *EmuDevice, va: u64, n: usize) ?[]const u32 {
        const m = e.memory();
        const bytes = m.find(va, n * 4) orelse return null;
        return @alignCast(std.mem.bytesAsSlice(u32, bytes));
    }

    fn execute(e: *EmuDevice, va: u64, dwords: u32, depth: u32) anyerror!void {
        if (depth > 2) return error.BadStream;
        const w = e.words(va, dwords) orelse return error.BadStream;
        var i: usize = 0;
        while (i < w.len) {
            const h = w[i];
            switch (h >> 28) {
                4 => {
                    const reg = (h >> 8) & 0x3ffff;
                    const cnt = h & 0x7f;
                    if (i + 1 + cnt > w.len or reg + cnt > e.regs.len) return error.BadStream;
                    for (0..cnt) |k| e.regs[reg + k] = w[i + 1 + k];
                    i += 1 + cnt;
                },
                7 => {
                    const op = (h >> 16) & 0x7f;
                    const cnt = h & 0x3fff;
                    if (i + 1 + cnt > w.len) return error.BadStream;
                    try e.packet(op, w[i + 1 ..][0..cnt], depth);
                    i += 1 + cnt;
                },
                else => return error.BadStream,
            }
        }
    }

    fn packet(e: *EmuDevice, op: u32, p: []const u32, depth: u32) anyerror!void {
        switch (op) {
            a7xx.CP_LOAD_STATE6_FRAG => {
                const st = (p[0] >> 14) & 3;
                const src = (p[0] >> 16) & 3;
                const off = p[0] & 0x3fff;
                const units = p[0] >> 22;
                if (st == a7xx.ST6_CONSTANTS) {
                    if (off * 4 + units * 4 > e.consts.len) return error.BadStream;
                    const dst = e.consts[off * 4 ..][0 .. units * 4];
                    if (src == a7xx.SS6_DIRECT) {
                        if (p.len < 3 + units * 4) return error.BadStream;
                        @memcpy(dst, p[3..][0 .. units * 4]);
                    } else {
                        const from = e.words(@as(u64, p[2]) << 32 | p[1], units * 4) orelse return error.BadStream;
                        @memcpy(dst, from);
                    }
                }
            },
            a7xx.CP_EXEC_CS => try e.dispatch(.{ p[1], p[2], p[3] }),
            a7xx.CP_REG_TO_MEM => {
                const va = @as(u64, p[2]) << 32 | p[1];
                const m = e.memory();
                const reg = p[0] & 0x3ffff;
                const cnt = @max((p[0] >> 18) & 0xfff, 1);
                const out = m.find(va, cnt * 4) orelse return error.BadStream;
                e.clock += 1000;
                for (0..cnt) |k| {
                    const v: u32 = if (reg == a7xx.CP_ALWAYS_ON_COUNTER) @truncate(if (k == 0) e.clock else e.clock >> 32) else e.regs[reg + k];
                    std.mem.writeInt(u32, out[k * 4 ..][0..4], v, .little);
                }
            },
            a7xx.CP_MEM_WRITE => {
                const va = @as(u64, p[1]) << 32 | p[0];
                const m = e.memory();
                const out = m.find(va, (p.len - 2) * 4) orelse return error.BadStream;
                for (p[2..], 0..) |v, k| std.mem.writeInt(u32, out[k * 4 ..][0..4], v, .little);
            },
            a7xx.CP_EVENT_WRITE7 => {
                if (p.len >= 4 and p[0] & (1 << 27) != 0) {
                    const va = @as(u64, p[2]) << 32 | p[1];
                    const m = e.memory();
                    const out = m.find(va, 4) orelse return error.BadStream;
                    std.mem.writeInt(u32, out[0..4], p[3], .little);
                }
            },
            a7xx.CP_INDIRECT_BUFFER => try e.execute(@as(u64, p[1]) << 32 | p[0], p[2] & 0xfffff, depth + 1),
            else => {},
        }
    }

    fn dispatch(e: *EmuDevice, groups: [3]u32) anyerror!void {
        const r = &e.regs;
        const code_va = @as(u64, r[a7xx.SP_CS_BASE + 1]) << 32 | r[a7xx.SP_CS_BASE];
        const instrlen = r[a7xx.SP_CS_INSTR_SIZE];
        const cntl0 = r[a7xx.SP_CS_CNTL_0];
        const nd = r[a7xx.SP_CS_NDRANGE_0];
        const wie = r[a7xx.SP_CS_WIE_CNTL_0];
        const n = instrlen * 16;
        const m = e.memory();
        const bytes = m.find(code_va, n * 8) orelse return error.BadStream;
        const code: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, bytes));
        const k = ir3_asm.Kernel{
            .gen = ir3.A7XX,
            .code = code,
            .count = n,
            .instrlen = instrlen,
            .local_size = .{ @intCast(((nd >> 2) & 0x3ff) + 1), @intCast(((nd >> 12) & 0x3ff) + 1), @intCast(((nd >> 22) & 0x3ff) + 1) },
            .wgid_reg = @truncate(wie),
            .localid_reg = @truncate(wie >> 24),
            .full_regs = @truncate((cntl0 >> 7) & 0x3f),
            .half_regs = @truncate((cntl0 >> 1) & 0x3f),
            .constlen = @intCast((r[a7xx.SP_CS_CONST_CONFIG] & 0xff) << 2),
            .branchstack = @truncate((cntl0 >> 13) & 0x7f),
            .shared_bytes = ir3_emu.LOCAL_BYTES,
            .threadsize = if (cntl0 & (1 << 20) != 0) 128 else 64,
        };
        // (the padding after `end` decodes to nops and never runs)
        try ir3_emu.load(&e.emu, &k);
        const d = ir3_emu.Dispatch{ .kernel = &k, .consts = &e.consts, .groups = groups, .group_stride = e.group_stride };
        try ir3_emu.run(&e.emu, &m, &d, &e.stats);
    }
};

test "an emulated device runs a stream built by a7xx.Stream (the GPU's memory apart)" {
    const S = struct {
        var arena: [1 << 20]u8 align(4096) = undefined;
        var gpu_view: [1 << 20]u8 align(4096) = undefined;
        var dev: EmuDevice = undefined;
        var asm_work: ir3_asm.Work = .{};
    };
    S.dev = .{ .arena = &S.arena, .gpu_view = &S.gpu_view };
    const d = S.dev.device();
    const code_buf = try d.alloc(4096);
    const out = try d.alloc(4096);
    const ib = try d.alloc(4096);
    const code: []u64 = @alignCast(std.mem.bytesAsSlice(u64, code_buf.cpu));
    const k = try ir3_asm.assemble(ir3.A7XX,
        \\@localsize 32, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\shl.b r1.x, r48.x, 5
        \\add.u r1.x, r1.x, r0.x
        \\shl.b r1.y, r1.x, 2
        \\mul.u24 r1.z, r1.x, 3
        \\stg.a.u32 g[c0.x+r1.y+0], r1.z, 1
        \\end
    , &S.asm_work, code);
    var s = a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code_buf.va);
    s.constants(0, &.{ @truncate(out.va), @truncate(out.va >> 32), 0, 0 });
    s.dispatch(&k, .{ 4, 1, 1 });
    s.waitForIdle();
    try s.check();
    // (the kernel's code not handed over: the GPU sees zeros, no program)
    try std.testing.expectError(error.DeviceLost, d.run(ib, @intCast(s.len), 1_000_000));
    d.toDevice(code_buf, 0, k.code.len * 8);
    try d.run(ib, @intCast(s.len), 1_000_000);
    const got: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, out.cpu[0 .. 128 * 4]));
    // (and what it wrote, not seen until it is fetched)
    try std.testing.expectEqual(@as(u32, 0), got[1]);
    d.fromDevice(out, 0, 128 * 4);
    for (got, 0..) |v, i| try std.testing.expectEqual(@as(u32, @intCast(3 * i)), v);
}
