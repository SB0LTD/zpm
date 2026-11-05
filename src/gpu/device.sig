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
    /// The most dispatches one run takes.
    max_run: u32 = 256,
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
    /// Memory mapped for the GPU by someone else (an app's dma-buf, shared
    /// in the device's context): the caller builds the Buffer (.gpu its
    /// address there, .cpu a CPU view or empty) and frees it its own way,
    /// after the last run that reads it. free, toDevice and fromDevice
    /// leave it alone; a dispatch binds it like any buffer.
    external,
};

/// A Buffer over memory already mapped for the GPU (Kind.external).
pub fn external(gpu_va: u64, bytes: u64, cpu: []u8) Buffer {
    return .{ .gpu = gpu_va, .cpu = cpu, .bytes = bytes, .handle = 0, .kind = .external };
}

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
    /// The bindings it may write, bit i for binding i (compileFor: KIR's
    /// stores and atomics); all of them for a binary made otherwise.
    writes: u32 = ALL_WRITTEN,
};
pub const ALL_WRITTEN: u32 = 0xffff_ffff;

/// The barriers a run needs. A dispatch waits for those before it only
/// when it reads or writes memory one of them wrote, or writes memory one
/// of them read, since the last barrier: whole buffers compared (the GPU
/// address range each is bound as). Dispatches apart (a layer's gate and up
/// matrices, its query, key and value) run together.
pub const Hazards = struct {
    const MAX = 96;
    written: [MAX][2]u64 = undefined,
    nw: usize = 0,
    read: [MAX][2]u64 = undefined,
    nr: usize = 0,
    /// The sets ran out of room: the next dispatch waits.
    full: bool = false,

    fn rangeOf(b: Buffer) [2]u64 {
        return .{ b.gpu, b.gpu +| @max(b.bytes, 1) };
    }

    fn meets(set: []const [2]u64, r: [2]u64) bool {
        for (set) |x| if (r[0] < x[1] and x[0] < r[1]) return true;
        return false;
    }

    fn writes(d: *const Dispatch, i: usize) bool {
        return i >= 32 or d.prog.bin.writes & (@as(u32, 1) << @intCast(i)) != 0;
    }

    /// Whether `d` must wait for the dispatches before it; then the barrier
    /// is counted as taken. d's accesses are noted either way.
    pub fn barrierBefore(h: *Hazards, d: *const Dispatch) bool {
        var need = h.full;
        for (d.buffers, 0..) |b, i| {
            const r = rangeOf(b);
            if (meets(h.written[0..h.nw], r)) need = true;
            if (writes(d, i) and meets(h.read[0..h.nr], r)) need = true;
        }
        if (need) h.* = .{};
        for (d.buffers, 0..) |b, i| {
            const r = rangeOf(b);
            if (writes(d, i)) {
                if (h.nw == MAX) {
                    h.full = true;
                    continue;
                }
                h.written[h.nw] = r;
                h.nw += 1;
            } else {
                if (h.nr == MAX) {
                    h.full = true;
                    continue;
                }
                h.read[h.nr] = r;
                h.nr += 1;
            }
        }
        return need;
    }
};

test "device: an external buffer is the caller's: free, toDevice and fromDevice leave it alone" {
    const Count = struct {
        var calls: u32 = 0;
        fn alloc(ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer {
            _ = ctx;
            _ = bytes;
            _ = kind;
            return null;
        }
        fn free(ctx: *anyopaque, b: Buffer) void {
            _ = ctx;
            _ = b;
            calls += 1;
        }
        fn import(ctx: *anyopaque, cpu: []u8) ?Buffer {
            _ = ctx;
            _ = cpu;
            return null;
        }
        fn cache(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
            _ = ctx;
            _ = b;
            _ = off;
            _ = len;
            calls += 1;
        }
        fn load(ctx: *anyopaque, bin: *const Binary) Error!Program {
            _ = ctx;
            _ = bin;
            return error.Unsupported;
        }
        fn unload(ctx: *anyopaque, p: *const Program) void {
            _ = ctx;
            _ = p;
        }
        fn run(ctx: *anyopaque, ds: []const Dispatch) Error!Fence {
            _ = ctx;
            _ = ds;
            return error.Unsupported;
        }
        fn wait(ctx: *anyopaque, f: Fence, t: u64) Error!void {
            _ = ctx;
            _ = f;
            _ = t;
        }
        fn done(ctx: *anyopaque, f: Fence) bool {
            _ = ctx;
            _ = f;
            return true;
        }
        fn ns(ctx: *anyopaque) u64 {
            _ = ctx;
            return 0;
        }
    };
    const vt = Device.VTable{ .alloc = Count.alloc, .free = Count.free, .import = Count.import, .toDevice = Count.cache, .fromDevice = Count.cache, .load = Count.load, .unload = Count.unload, .run = Count.run, .wait = Count.wait, .done = Count.done, .lastRunNs = Count.ns };
    var dummy: u8 = 0;
    const d = Device{ .ctx = &dummy, .vtable = &vt, .caps = interp_caps };
    const x = external(0x7000_0000, 4096, &.{});
    d.free(x);
    d.toDevice(x, 0, 4096);
    d.fromDevice(x, 0, 4096);
    try std.testing.expectEqual(@as(u32, 0), Count.calls);
    d.free(.{ .gpu = 0x1000, .bytes = 16, .kind = .host });
    try std.testing.expectEqual(@as(u32, 1), Count.calls);
}

test "device: barriers only where a dispatch meets what came before" {
    const prog_rw = Program{ .bin = .{ .target = .interp, .code = &.{}, .regs = 1, .shared_bytes = 0, .group = .{ 1, 1, 1 }, .bindings = 2, .param_words = 0, .writes = 0b10 }, .code = .{} };
    const prog_all = Program{ .bin = .{ .target = .interp, .code = &.{}, .regs = 1, .shared_bytes = 0, .group = .{ 1, 1, 1 }, .bindings = 2, .param_words = 0 }, .code = .{} };
    const a = Buffer{ .gpu = 0x1000, .bytes = 0x100 };
    const b = Buffer{ .gpu = 0x2000, .bytes = 0x100 };
    const c = Buffer{ .gpu = 0x3000, .bytes = 0x100 };
    const d = Buffer{ .gpu = 0x4000, .bytes = 0x100 };
    var h = Hazards{};
    // a -> b, then a -> c: apart (both only read a)
    try std.testing.expect(!h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{} }));
    try std.testing.expect(!h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, c }, .params = &.{} }));
    // b -> d reads what the first wrote: waits
    try std.testing.expect(h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ b, d }, .params = &.{} }));
    // d -> a writes what nothing since the barrier read... but a dispatch
    // that writes b, which the one before read: waits (write after read)
    try std.testing.expect(h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ c, b }, .params = &.{} }));
    // (noted now: c read, b written) a binary that writes all it binds:
    // apart from them, it runs with them; writing c, read before, waits
    try std.testing.expect(!h.barrierBefore(&.{ .prog = &prog_all, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, d }, .params = &.{} }));
    try std.testing.expect(h.barrierBefore(&.{ .prog = &prog_all, .groups = .{ 1, 1, 1 }, .buffers = &.{ c, .{ .gpu = 0x5000, .bytes = 16 } }, .params = &.{} }));
    // a sub-range of a written buffer meets it
    h = .{};
    _ = h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{} });
    try std.testing.expect(h.barrierBefore(&.{ .prog = &prog_rw, .groups = .{ 1, 1, 1 }, .buffers = &.{ .{ .gpu = 0x2080, .bytes = 16 }, c }, .params = &.{} }));
}
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
        /// Profiling on or off for the runs after it (each dispatch's end
        /// timed); false: the device cannot (null: none can).
        profile: ?*const fn (ctx: *anyopaque, on: bool) bool = null,
        /// For the last run, profiled: each dispatch's end, ns after the
        /// run's start, into `out` (as many as it ran); 0: none.
        dispatchNs: ?*const fn (ctx: *anyopaque, out: []u64) usize = null,
    };

    /// A buffer of `bytes`, or error.OutOfMemory.
    pub fn alloc(d: Device, bytes: u64, kind: Kind) Error!Buffer {
        return d.vtable.alloc(d.ctx, bytes, kind) orelse error.OutOfMemory;
    }
    pub fn free(d: Device, b: Buffer) void {
        if (b.kind == .external) return;
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
        if (b.kind == .external) return;
        d.vtable.toDevice(d.ctx, b, off, len);
    }
    /// Make GPU writes to b[off..off+len] visible to the CPU.
    pub fn fromDevice(d: Device, b: Buffer, off: u64, len: u64) void {
        if (b.kind == .external) return;
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
    /// Each dispatch's end timed in the runs after this (false: not here).
    pub fn profile(d: Device, on: bool) bool {
        const f = d.vtable.profile orelse return false;
        return f(d.ctx, on);
    }
    /// The last profiled run's dispatch ends (ns after its start).
    pub fn dispatchNs(d: Device, out: []u64) usize {
        const f = d.vtable.dispatchNs orelse return 0;
        return f(d.ctx, out);
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

/// Every target there is: what `compile` links.
pub const all_targets: []const Target = std.enums.values(Target);

/// Compile `k` for `caps.target` (the backends: kir_ir3, kir_sm120; interp
/// keeps the KIR itself, in its 24-byte form, in `out`). Verifies `k`
/// against caps first. Links every backend: for tests and tools; a kernel
/// image uses compileFor.
pub fn compile(k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary {
    return compileFor(all_targets, k, caps, work, out);
}

/// compile, with only the backends `targets` names referenced (and so
/// linked): an image for one machine carries its GPU's backend and no
/// other. A target not in the list is error.Unsupported at run time.
pub fn compileFor(comptime targets: []const Target, k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary {
    try kir.verify(k, caps);
    inline for (targets) |t| {
        if (caps.target == t) {
            var bin = try compileOne(t, k, caps, work, out);
            bin.writes = kir.writtenBindings(k);
            return bin;
        }
    }
    return error.Unsupported;
}

/// One target's backend; the switch is on a comptime value, so only that
/// prong is analyzed.
fn compileOne(comptime t: Target, k: *const kir.Kernel, caps: Caps, work: *Work, out: []u8) !Binary {
    return switch (t) {
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

test "device: compileFor links and compiles only the targets it names" {
    var insts: [16]kir.Inst = undefined;
    var tys: [16]kir.Ty = undefined;
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "one", .{ 32, 1, 1 });
    const b = k.binding();
    const t = k.tid(0);
    k.store(.u32, kir.global(b, 32), kir.r(k.op2(.shl, .u32, kir.r(t), kir.u(2))), kir.r(t));
    try k.finish();
    var mem: [256]u8 = undefined;
    var work = Work.init(&mem);
    var out: [16 * kir.INST_BYTES]u8 = undefined;
    const interp_only = [_]Target{.interp};
    const bin = try compileFor(&interp_only, &k, interp_caps, &work, &out);
    try std.testing.expectEqual(Target.interp, bin.target);
    try std.testing.expectEqual(@as(u32, 3), bin.extra[0]);
    // the other targets are not there: Unsupported, at run time
    for ([_]Target{ .ir3_a7xx, .sm_120 }) |other| {
        var caps = interp_caps;
        caps.target = other;
        try std.testing.expectError(error.Unsupported, compileFor(&interp_only, &k, caps, &work, &out));
    }
    // an image with one GPU's backend, asked for the interpreter
    try std.testing.expectError(error.Unsupported, compileFor(&.{.ir3_a7xx}, &k, interp_caps, &work, &out));
    try std.testing.expectError(error.Unsupported, compileFor(&.{}, &k, interp_caps, &work, &out));
    // verification comes first, whatever the list
    var bad = interp_caps;
    bad.max_group = 16;
    try std.testing.expectError(error.Limits, compileFor(&interp_only, &k, bad, &work, &out));
    // compile is compileFor over every target
    try std.testing.expectEqual(@typeInfo(Target).@"enum".field_names.len, all_targets.len);
    const all = try compile(&k, interp_caps, &work, &out);
    try std.testing.expectEqualSlices(u8, bin.code, all.code);
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
