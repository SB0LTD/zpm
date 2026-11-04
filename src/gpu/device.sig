//! @zpm/gpu devices — what any GPU gives a compute user, whatever its
//! vendor or memory: buffers by kind, programs loaded from a backend's
//! Binary, dispatches run in order under one fence.
//!
//! Memory models (docs/GPU.md):
//! - unified (Adreno, Apple, Intel iGPUs): one memory; every buffer has a
//!   CPU view. `import` maps CPU memory the caller already has (a model
//!   file, a pixel buffer) zero-copy when caps.import. toDevice/fromDevice
//!   are the cache maintenance a non-coherent GPU needs, no-ops when
//!   caps.coherent.
//! - discrete (an RTX's VRAM): `.device` buffers are VRAM and may have no
//!   CPU view; `.upload` is CPU-written, GPU-read (BAR1, write-combined);
//!   `.host` is system memory both reach. toDevice/fromDevice order the
//!   CPU's writes and the GPU's.
//!
//! Allocation-free: devices hand out memory their owner provides; compile
//! works in the caller's Work.

const std = @import("std");
const kir = @import("kir.sig");

pub const Vendor = enum { nvidia, qualcomm, amd, intel, apple, emulated };
/// grows: sm_75..sm_90, ir3_a6xx, rdna3, xe, agx ...
pub const Target = enum { interp, ir3_a7xx, sm_120 };
pub const MemoryModel = enum { unified, discrete };

pub const Caps = struct {
    vendor: Vendor,
    target: Target,
    name: []const u8 = "",
    memory: MemoryModel,
    /// unified only: the GPU snoops the CPU's caches (toDevice/fromDevice are no-ops)
    coherent: bool,
    /// discrete: VRAM; unified: what the driver lets the GPU map
    device_bytes: u64,
    /// 32 (NVIDIA), 64 or 128 (Adreno), ...
    subgroup: u32,
    max_group: u32,
    shared_bytes: u32,
    fused_fma: bool,
    mad: enum { fused, unfused } = .unfused,
    denormals: enum { preserve, flush } = .preserve,
    /// a native 4x8-bit dot product (else the backend expands dot4)
    dot4: bool,
    /// zero-copy import of CPU memory (unified)
    import: bool,
    timestamp_hz: u64,
};

/// The interpreter's default: an ideal GPU (fused, denormals kept, a
/// subgroup of 32). Tests change fields to model a real one.
pub const interp_caps = Caps{
    .vendor = .emulated,
    .target = .interp,
    .name = "kir interpreter",
    .memory = .unified,
    .coherent = true,
    .device_bytes = 0,
    .subgroup = 32,
    .max_group = 1024,
    .shared_bytes = 64 * 1024,
    .fused_fma = true,
    .mad = .fused,
    .denormals = .preserve,
    .dot4 = true,
    .import = true,
    .timestamp_hz = 1_000_000_000,
};

pub const Kind = enum {
    /// the GPU's fastest memory: VRAM (discrete) or ordinary memory (unified); cpu may be empty
    device,
    /// CPU-cached, GPU-reachable: results the CPU reads, data it writes often
    host,
    /// CPU writes (write-combined on discrete: BAR1 VRAM), GPU reads
    upload,
};

pub const Buffer = struct {
    gpu: u64 = 0,
    cpu: []u8 = &.{},
    bytes: u64 = 0,
    handle: u32 = 0,
    kind: Kind = .host,

    /// The CPU view as u32 words (empty when the buffer has no CPU view).
    pub fn words(b: Buffer) []u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, b.cpu[0 .. b.cpu.len & ~@as(usize, 3)]));
    }
};

/// A backend's output: code plus what a dispatch needs.
pub const Binary = struct {
    target: Target,
    code: []const u8,
    regs: u32,
    shared_bytes: u32,
    group: [3]u32,
    bindings: u8,
    param_words: u16,
    /// target-specific (e.g. ir3 config, sm_120 register/barrier counts;
    /// interp: [0] the instruction count)
    extra: [16]u32 = [_]u32{0} ** 16,
};
/// A Binary placed in device memory.
pub const Program = struct { bin: Binary, code: Buffer };

pub const Dispatch = struct {
    prog: *const Program,
    groups: [3]u32,
    /// bindings in order (their gpu addresses go into the parameter block)
    buffers: []const Buffer,
    /// the u32 words after them
    params: []const u32,
};

pub const Error = error{ OutOfMemory, SubmitFailed, Timeout, DeviceLost, BadProgram, Unsupported };
pub const Fence = u64;

pub const Device = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    caps: Caps,

    pub const VTable = struct {
        alloc: *const fn (ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer,
        free: *const fn (ctx: *anyopaque, b: Buffer) void,
        /// null when !caps.import
        import: *const fn (ctx: *anyopaque, cpu: []u8) ?Buffer,
        toDevice: *const fn (ctx: *anyopaque, b: Buffer, off: u64, len: u64) void,
        fromDevice: *const fn (ctx: *anyopaque, b: Buffer, off: u64, len: u64) void,
        load: *const fn (ctx: *anyopaque, bin: *const Binary) Error!Program,
        unload: *const fn (ctx: *anyopaque, p: *const Program) void,
        /// Run the dispatches in order (each sees the one before's writes); one fence for all.
        run: *const fn (ctx: *anyopaque, d: []const Dispatch) Error!Fence,
        wait: *const fn (ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void,
        done: *const fn (ctx: *anyopaque, f: Fence) bool,
        /// GPU time of the last run's dispatches (ns), 0 when unknown.
        lastRunNs: *const fn (ctx: *anyopaque) u64,
    };

    /// A buffer of `bytes`, or error.OutOfMemory.
    pub fn alloc(d: Device, bytes: u64, kind: Kind) Error!Buffer {
        return d.vtable.alloc(d.ctx, bytes, kind) orelse error.OutOfMemory;
    }
    pub fn free(d: Device, b: Buffer) void {
        d.vtable.free(d.ctx, b);
    }
    /// CPU memory mapped for the GPU without a copy; null when the device
    /// cannot (then copy into a buffer of its own).
    pub fn import(d: Device, cpu: []u8) ?Buffer {
        if (!d.caps.import) return null;
        return d.vtable.import(d.ctx, cpu);
    }
    /// Make CPU writes to b[off..off+len] visible to the GPU.
    pub fn toDevice(d: Device, b: Buffer, off: u64, len: u64) void {
        d.vtable.toDevice(d.ctx, b, off, len);
    }
    /// Make GPU writes to b[off..off+len] visible to the CPU.
    pub fn fromDevice(d: Device, b: Buffer, off: u64, len: u64) void {
        d.vtable.fromDevice(d.ctx, b, off, len);
    }
    pub fn load(d: Device, bin: *const Binary) Error!Program {
        return d.vtable.load(d.ctx, bin);
    }
    pub fn unload(d: Device, p: *const Program) void {
        d.vtable.unload(d.ctx, p);
    }
    pub fn run(d: Device, ds: []const Dispatch) Error!Fence {
        return d.vtable.run(d.ctx, ds);
    }
    pub fn wait(d: Device, fence: Fence, timeout_us: u64) Error!void {
        return d.vtable.wait(d.ctx, fence, timeout_us);
    }
    pub fn done(d: Device, fence: Fence) bool {
        return d.vtable.done(d.ctx, fence);
    }
    pub fn lastRunNs(d: Device) u64 {
        return d.vtable.lastRunNs(d.ctx);
    }
    /// Run and wait.
    pub fn runWait(d: Device, ds: []const Dispatch, timeout_us: u64) Error!void {
        const fence = try d.run(ds);
        try d.wait(fence, timeout_us);
    }
};

/// Working storage for compile (and anything else that needs scratch
/// space for one call): the caller's bytes, handed out in order and
/// given back all at once.
pub const Work = struct {
    mem: []u8,
    used: usize = 0,

    pub fn init(mem: []u8) Work {
        return .{ .mem = mem };
    }
    pub fn reset(w: *Work) void {
        w.used = 0;
    }
    /// n T's from the storage (aligned), or null when it is full.
    pub fn take(w: *Work, comptime T: type, n: usize) ?[]T {
        const base = @intFromPtr(w.mem.ptr);
        const at = std.mem.alignForward(usize, base + w.used, @alignOf(T)) - base;
        const bytes = n * @sizeOf(T);
        if (at > w.mem.len or bytes > w.mem.len - at) return null;
        w.used = at + bytes;
        const p: [*]T = @ptrCast(@alignCast(w.mem.ptr + at));
        return p[0..n];
    }
    /// A point to go back to (with `release`).
    pub fn mark(w: *const Work) usize {
        return w.used;
    }
    pub fn release(w: *Work, m: usize) void {
        if (m <= w.used) w.used = m;
    }
};

// ── The backends: one line each, its owner's. Replace `none` with an
//    import of the backend's file (Q: kir_ir3.sig, N: kir_sm120.sig); it
//    provides
//    `pub fn compile(k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary`.
//    (Comments here name files in prose only: Galaxy's module resolver
//    scans the source text, comments included.) ──

const backend_ir3_a7xx = @import("kir_ir3.sig"); // Q

//

const backend_sm_120 = @import("kir_sm120.sig"); // N

const none = struct {
    pub fn compile(k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) Error!Binary {
        _ = k;
        _ = caps;
        _ = work;
        _ = out;
        return error.Unsupported;
    }
};

/// Compile `k` for `caps.target` (the backends: kir_ir3, kir_sm120; interp
/// keeps the KIR itself, in its 24-byte form, in `out`). Verifies `k`
/// against caps first.
pub fn compile(k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary {
    try kir.verify(k, caps);
    return switch (caps.target) {
        .interp => interpBinary(k, out),
        .ir3_a7xx => backend_ir3_a7xx.compile(k, caps, work, out),
        .sm_120 => backend_sm_120.compile(k, caps, work, out),
    };
}

fn interpBinary(k: *const kir.Kernel, out: []u8) error{NoSpaceLeft}!Binary {
    const code = try kir.encode(k, out);
    var b = Binary{
        .target = .interp,
        .code = code,
        .regs = k.nv,
        .shared_bytes = k.shared_bytes,
        .group = k.group,
        .bindings = k.bindings,
        .param_words = k.param_words,
    };
    b.extra[0] = @intCast(k.n);
    return b;
}

test "device: compile for the interpreter" {
    var insts: [16]kir.Inst = undefined;
    var tys: [16]kir.Ty = undefined;
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "one", .{ 32, 1, 1 });
    const b = k.binding();
    const t = k.tid(0);
    const off = k.op2(.shl, .u32, kir.r(t), kir.u(2));
    k.store(.u32, kir.global(b, 32), kir.r(off), kir.r(t));
    try k.finish();
    var mem: [256]u8 = undefined;
    var work = Work.init(&mem);
    var out: [16 * kir.INST_BYTES]u8 = undefined;
    const bin = try compile(&k, interp_caps, &work, &out);
    try std.testing.expectEqual(Target.interp, bin.target);
    try std.testing.expectEqual(@as(u32, 3), bin.extra[0]);
    try std.testing.expectEqual(@as(usize, 3 * kir.INST_BYTES), bin.code.len);
    var caps = interp_caps;
    caps.target = .sm_120;
    // (sm_120 is kir_sm120's: a 256-byte Work is too small for its State)
    try std.testing.expectError(error.TooBig, compile(&k, caps, &work, &out));
}

test "device: work storage" {
    var mem: [64]u8 align(8) = undefined;
    var w = Work.init(&mem);
    const a = w.take(u8, 3).?;
    const b = w.take(u32, 4).?;
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expect(@intFromPtr(b.ptr) % 4 == 0);
    const m = w.mark();
    try std.testing.expect(w.take(u64, 8) == null);
    w.release(m);
    try std.testing.expect(w.take(u32, 4) != null);
}
