//! @zpm/gpu nvidia_device — an NVIDIA GPU (zpm's nvidia.gpu.Device:
//! Galaxy's GSP-RM driver, or the emulated RTX) as a gpu.Device, running
//! kir_sm120's binaries.
//!
//! `over(adapter, vram, host, caps)` wraps the raw devices Galaxy's driver
//! already gives (nv_dev's VRAM device and its system-memory one), so the
//! driver needs no change. Each `run` is one pushbuffer, as lfm3_nv.sig and
//! Galaxy's gfx_gpu.sig make them: the compute class bound and its windows
//! set (push.computeSetup), the shader caches invalidated (the code, the
//! QMDs and their constant buffers the CPU wrote since the SMs last ran),
//! a timestamp, then each dispatch's QMD (QMD v05_00, qmd.build: the
//! binary's registers and shared bytes, the dispatch's grid, the kernel's
//! group as the block) launched from a slot of its own with constant
//! buffer 0 beside it (qmd.cbuf0: the bindings' 64-bit addresses, then the
//! parameter words, from 0x380), a dispatch after the first preceded by
//! WAIT_FOR_IDLE and INVALIDATE_SHADER_CACHES (each sees the one before's
//! writes), a timestamp, WAIT_FOR_IDLE. The driver's own semaphore release
//! after the pushbuffer is the fence.
//!
//! # Memory (discrete)
//!
//! - `.device`: VRAM (the main device). The CPU view the driver gives is
//!   kept (BAR1, write-combined: slow to read).
//! - `.host`: system memory the GPU maps (the host device; VRAM when there
//!   is none). What the CPU reads after a run goes here.
//! - `.upload`: VRAM written by the CPU through BAR1 (write-combined).
//! - `import`: none (the GPU does not map arbitrary CPU memory here).
//! - `toDevice`/`fromDevice`: the owning raw device's, which make CPU writes
//!   visible to the GPU and GPU writes to the CPU (on the emulated RTX they
//!   copy between its two views, so a missing call gives wrong results in
//!   tests too).
//!
//! `Emu` is the same adapter over nvidia.device.EmuDevice: the pushbuffer,
//! the QMDs and the code decoded and run by sm120_emu, its hazard checks at
//! NAK's level (strict).
//!
//! Allocation-free: the adapter's state is the caller's (Adapter, Emu).

const std = @import("std");
const gpu = @import("device.sig");
/// The backend whose binaries the adapter runs.
pub const kir_sm120 = @import("kir_sm120.sig");
const nvidia = @import("nvidia");
const nv = nvidia.device;
const qmd = nvidia.qmd;
const push = nvidia.push;
const emu = nvidia.sm120_emu;

/// Buffers an adapter tracks (allocated and not freed).
pub const MAX_BUFFERS = 512;
/// Dispatches one run takes.
pub const MAX_DISPATCHES = 256;
/// A dispatch's slot: its QMD at 0 (256-aligned), constant buffer 0 at
/// 0x200 (64-aligned).
pub const SLOT_BYTES = 0x600;
const CBUF_AT = 0x200;
/// Pushbuffer dwords: the set-up, then a dispatch's wait, invalidation and
/// launch, then the end.
const SETUP_DWORDS = 64;
const DWORDS_PER_DISPATCH = 8;
const PB_DWORDS = SETUP_DWORDS + DWORDS_PER_DISPATCH * MAX_DISPATCHES;
/// Zeros after a program (the SMs' prefetch reads past its end; the
/// emulated RTX reads to its first all-zero instruction).
const CODE_GAP = 256;
/// clcec0.h's WAIT_FOR_IDLE.
const WAIT_FOR_IDLE: u32 = 0x0110;
/// Run slots in flight: a run reuses a set only after its fence.
const SETS = 2;

/// The RTX 5070 Laptop's (GB206) caps, `vram` bytes of VRAM.
pub fn rtx5070(vram: u64) gpu.Caps {
    return .{
        .vendor = .nvidia,
        .target = .sm_120,
        .name = "RTX 5070 Laptop (GB206, sm_120)",
        .memory = .discrete,
        .coherent = false,
        .device_bytes = vram,
        .subgroup = 32,
        .max_group = 1024,
        // (the SM's largest split less the reserved 1 KiB)
        .shared_bytes = qmd.MAX_SHARED - qmd.RESERVED_SHARED,
        .fused_fma = true,
        .mad = .fused,
        .denormals = .preserve,
        .dot4 = true,
        .import = false,
        .timestamp_hz = push.TIMESTAMP_HZ,
    };
}

const Slot = struct {
    raw: nv.Buffer = .{},
    /// From the host device (else VRAM).
    on_host: bool = false,
    used: bool = false,
};

const Set = struct {
    slots: nv.Buffer = .{},
    pb: nv.Buffer = .{},
    /// Two timestamp reports (four words each).
    stamps: nv.Buffer = .{},
    fence: ?nv.Fence = null,
    dispatches: u32 = 0,
};

pub const Adapter = struct {
    vram: nv.Device = undefined,
    host: ?nv.Device = null,
    caps: gpu.Caps = undefined,
    bufs: [MAX_BUFFERS]Slot = [_]Slot{.{}} ** MAX_BUFFERS,
    sets: [SETS]Set = [_]Set{.{}} ** SETS,
    next_set: usize = 0,
    last_set: ?usize = null,
    /// Runs submitted, and the ones whose dispatches failed on the GPU.
    runs: u64 = 0,
    /// The waits for idle the last run took between its dispatches.
    barriers: u32 = 0,
    lost: u64 = 0,
    last_error: ?anyerror = null,

    pub fn device(a: *Adapter) gpu.Device {
        return .{ .ctx = a, .vtable = &vtable, .caps = a.caps };
    }

    const vtable = gpu.Device.VTable{
        .alloc = alloc,
        .free = free,
        .import = import_,
        .toDevice = toDevice,
        .fromDevice = fromDevice,
        .load = load,
        .unload = unload,
        .run = run,
        .wait = wait,
        .done = done,
        .lastRunNs = lastRunNs,
    };

    fn self(ctx: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn rawOf(a: *Adapter, on_host: bool) nv.Device {
        return if (on_host) (a.host orelse a.vram) else a.vram;
    }

    fn alloc(ctx: *anyopaque, bytes: u64, kind: gpu.Kind) ?gpu.Buffer {
        const a = self(ctx);
        if (bytes == 0 or bytes > std.math.maxInt(usize)) return null;
        const on_host = kind == .host and a.host != null;
        for (&a.bufs, 0..) |*s, i| {
            if (s.used) continue;
            const raw = a.rawOf(on_host).alloc(@intCast(bytes)) catch return null;
            s.* = .{ .raw = raw, .on_host = on_host, .used = true };
            return .{ .gpu = raw.va, .cpu = raw.cpu, .bytes = bytes, .handle = @intCast(i + 1), .kind = kind };
        }
        return null;
    }

    fn slotOf(a: *Adapter, b: gpu.Buffer) ?*Slot {
        if (b.handle == 0 or b.handle > MAX_BUFFERS) return null;
        const s = &a.bufs[b.handle - 1];
        return if (s.used) s else null;
    }

    fn free(ctx: *anyopaque, b: gpu.Buffer) void {
        const a = self(ctx);
        const s = a.slotOf(b) orelse return;
        a.rawOf(s.on_host).free(s.raw);
        s.* = .{};
    }

    fn import_(ctx: *anyopaque, cpu: []u8) ?gpu.Buffer {
        _ = ctx;
        _ = cpu;
        return null;
    }

    fn toDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        const a = self(ctx);
        const s = a.slotOf(b) orelse return;
        a.rawOf(s.on_host).toDevice(s.raw, @intCast(off), @intCast(len));
    }

    fn fromDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        const a = self(ctx);
        const s = a.slotOf(b) orelse return;
        a.rawOf(s.on_host).fromDevice(s.raw, @intCast(off), @intCast(len));
    }

    fn load(ctx: *anyopaque, bin: *const gpu.Binary) gpu.Error!gpu.Program {
        const a = self(ctx);
        if (bin.target != .sm_120 or bin.code.len == 0 or bin.code.len % 16 != 0) return error.BadProgram;
        if (bin.regs == 0 or bin.regs > 255) return error.BadProgram;
        if (bin.extra[kir_sm120.EXTRA_STACK] != 0) return error.Unsupported;
        if (8 * @as(u32, bin.bindings) + 4 * @as(u32, bin.param_words) > qmd.MAX_PARAMS) return error.BadProgram;
        const code = alloc(ctx, bin.code.len + CODE_GAP, .upload) orelse return error.OutOfMemory;
        @memcpy(code.cpu[0..bin.code.len], bin.code);
        @memset(code.cpu[bin.code.len..][0..CODE_GAP], 0);
        toDevice(ctx, code, 0, code.bytes);
        if (code.gpu & 0xff != 0) {
            free(ctx, code);
            return error.BadProgram;
        }
        _ = a;
        return .{ .bin = bin.*, .code = code };
    }

    fn unload(ctx: *anyopaque, p: *const gpu.Program) void {
        free(ctx, p.code);
    }

    fn setUp(a: *Adapter, s: *Set) gpu.Error!void {
        if (s.pb.cpu.len != 0) return;
        s.slots = a.vram.alloc(SLOT_BYTES * MAX_DISPATCHES) catch return error.OutOfMemory;
        s.pb = a.vram.alloc(PB_DWORDS * 4) catch return error.OutOfMemory;
        s.stamps = a.rawOf(true).alloc(64) catch return error.OutOfMemory;
    }

    fn run(ctx: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        const a = self(ctx);
        if (ds.len == 0 or ds.len > MAX_DISPATCHES) return error.Unsupported;
        const si = a.next_set;
        const s = &a.sets[si];
        // (a set still in flight is waited for first)
        if (s.fence) |f| {
            a.vram.wait(f, std.math.maxInt(u64)) catch {};
            s.fence = null;
        }
        try a.setUp(s);
        var p = push.Push{ .buf = s.pb.words() };
        p.computeSetup(.{});
        p.invalidateShaderCaches();
        p.reportTimestamp(s.stamps.va, 1);
        var hz = gpu.Hazards{};
        a.barriers = 0;
        for (ds, 0..) |d, i| {
            const bin = &d.prog.bin;
            if (d.buffers.len != bin.bindings or d.params.len != bin.param_words) return error.BadProgram;
            const at = i * SLOT_BYTES;
            const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(s.slots.cpu[at..][0..qmd.QMD_BYTES]));
            qmd.build(q, .{
                .prog_va = d.prog.code.gpu,
                .prog_bytes = bin.code.len,
                .cbuf_va = s.slots.va + at + CBUF_AT,
                .registers = bin.regs,
                .grid = d.groups,
                .block = bin.group,
                .shared_bytes = bin.shared_bytes,
            }) catch return error.BadProgram;
            var params: [qmd.MAX_PARAMS]u8 = undefined;
            var n: usize = 0;
            for (d.buffers) |b| {
                std.mem.writeInt(u64, params[n..][0..8], b.gpu, .little);
                n += 8;
            }
            for (d.params) |w| {
                std.mem.writeInt(u32, params[n..][0..4], w, .little);
                n += 4;
            }
            const cb: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(s.slots.cpu[at + CBUF_AT ..][0..qmd.CBUF0_BYTES]));
            qmd.cbuf0(cb, d.groups, bin.group, params[0..n]) catch return error.BadProgram;
            // (each dispatch sees the writes of those before it that it
            // meets; the others run with it)
            if (hz.barrierBefore(&d) and i > 0) {
                p.method(push.SUBCH_COMPUTE, WAIT_FOR_IDLE, &.{0});
                p.invalidateShaderCaches();
                a.barriers += 1;
            }
            p.launch(s.slots.va + at);
        }
        p.method(push.SUBCH_COMPUTE, WAIT_FOR_IDLE, &.{0});
        p.reportTimestamp(s.stamps.va + 16, 2);
        p.check() catch return error.Unsupported;
        a.vram.toDevice(s.slots, 0, ds.len * SLOT_BYTES);
        a.vram.toDevice(s.pb, 0, p.len * 4);
        const f = a.vram.submit(s.pb, @intCast(p.len)) catch |e| return mapError(e);
        s.fence = f;
        s.dispatches = @intCast(ds.len);
        a.last_set = si;
        a.next_set = (si + 1) % SETS;
        a.runs += 1;
        return f;
    }

    fn mapError(e: nv.Error) gpu.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Timeout => error.Timeout,
            error.DeviceLost => error.DeviceLost,
            else => error.SubmitFailed,
        };
    }

    fn wait(ctx: *anyopaque, f: gpu.Fence, timeout_us: u64) gpu.Error!void {
        const a = self(ctx);
        a.vram.wait(f, timeout_us) catch |e| {
            if (e == error.DeviceLost) a.lost += 1;
            a.last_error = e;
            return mapError(e);
        };
        for (&a.sets) |*s| {
            if (s.fence == f) s.fence = null;
        }
    }

    fn done(ctx: *anyopaque, f: gpu.Fence) bool {
        const a = self(ctx);
        a.vram.wait(f, 0) catch return false;
        return true;
    }

    fn lastRunNs(ctx: *anyopaque) u64 {
        const a = self(ctx);
        const si = a.last_set orelse return 0;
        const s = &a.sets[si];
        const host = a.rawOf(true);
        host.fromDevice(s.stamps, 0, 32);
        const w = s.stamps.cpu;
        const t0 = std.mem.readInt(u64, w[8..16], .little);
        const t1 = std.mem.readInt(u64, w[24..32], .little);
        return if (t1 > t0) (t1 - t0) * 1_000_000_000 / a.vram.timestamp_hz else 0;
    }
};

/// A gpu.Device over Galaxy's raw NVIDIA devices: `vram` (the GPU's own
/// memory, which also submits) and `host` (system memory the GPU maps, or
/// none). `a` holds the adapter's state and must outlive the Device.
pub fn over(a: *Adapter, vram: nv.Device, host: ?nv.Device, caps: gpu.Caps) gpu.Device {
    a.* = .{ .vram = vram, .host = host, .caps = caps };
    return a.device();
}

// ── The emulated RTX ────────────────────────────────────────────────────────

/// The adapter over an emulated RTX (nvidia.device.EmuDevice), with the
/// hazard checks at NAK's level: what kir_sm120 emits runs here as it
/// would on the Legion, checked. The caller gives the memory: `arena` the
/// CPU's view, `gpu_view` the GPU's (as long, apart, as VRAM behind BAR1),
/// `work` the emulator's (about 9 MB).
pub const Emu = struct {
    raw: nv.EmuDevice,
    adapter: Adapter = .{},

    /// `work` may be undefined memory (a static `= undefined`): its
    /// control fields are set here (the step budget, the hazard checks at
    /// NAK's level, no trap); its big arrays are the emulator's to fill.
    pub fn init(e: *Emu, arena: []u8, gpu_view: []u8, work: *emu.Work) void {
        // (not `gen`: the emulator's per-CTA tracking keys on it, and a
        // fresh value only has to differ from what its arrays hold)
        work.n_ops = 0;
        work.top = null;
        work.trap = .{};
        work.check_hazards = true;
        work.strict = true;
        work.max_steps = emu.DEFAULT_MAX_STEPS;
        e.* = .{ .raw = .{ .arena = arena, .gpu_view = gpu_view, .work = work, .tpcs = 1 } };
    }

    pub fn device(e: *Emu) gpu.Device {
        e.raw.work.strict = true;
        return over(&e.adapter, e.raw.device(), null, emuCaps());
    }

    /// What went wrong in the last run's kernel, as a sentence.
    pub fn explain(e: *Emu, buf: []u8) []const u8 {
        return emu.explain(e.raw.work, buf);
    }

    /// The emulated RTX's own error for the last run (Timeout, Fault,
    /// Hazard ...: the kernel's, with `explain`), or null.
    pub fn lastError(e: *const Emu) ?anyerror {
        return e.raw.last_error;
    }
};

/// The emulated RTX's caps: the RTX 5070's, a 64 MiB emulated VRAM.
pub fn emuCaps() gpu.Caps {
    var c = rtx5070(64 << 20);
    c.name = "emulated RTX (sm120_emu)";
    return c;
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Kernels built in KIR, compiled by kir_sm120 and run on the emulated RTX
// (Emu: the pushbuffer, the QMDs, the code decoded and run with the hazard
// checks at NAK's level), against the interpreter (the same caps, the same
// bits) and against the hand-written sm_120 kernels they rewrite.

const testing = std.testing;
const kir = @import("kir.sig");
const r = kir.r;
const u = kir.u;
const kf = kir.f;
const no = kir.no;

const T = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var work: emu.Work = .{};
    var dev: Emu = undefined;
    var st: kir_sm120.State = .{};
    var code: [256 * 1024]u8 align(16) = undefined;
    var insts: [4096]kir.Inst = undefined;
    var tys: [8192]kir.Ty = undefined;
    var asm_work: nvidia.sm120_asm.Work = .{};
    var words: [2 * nvidia.sm120_asm.MAX_INSTRS]u64 = undefined;
};

fn freshEmu() gpu.Device {
    T.dev.init(&T.arena, &T.view, &T.work);
    return T.dev.device();
}

test "Emu over an emulator Work left undefined (a static `= undefined`): its controls are set by init" {
    @memset(std.mem.asBytes(&T.work.max_steps), 0);
    T.work.check_hazards = false;
    T.work.trap = .{ .what = .timeout };
    const d = freshEmu();
    try testing.expectEqual(emu.DEFAULT_MAX_STEPS, T.work.max_steps);
    try testing.expect(T.work.check_hazards and T.work.strict);
    var k = newKernel("one", .{ 32, 1, 1 });
    const o = k.binding();
    const t = k.tid(0);
    k.store(.u32, kir.global(o, 32), r(k.op2(.shl, .u32, r(t), u(2))), r(t));
    try k.finish();
    const bin = try kir_sm120.compileIn(&k, d.caps, &T.st, &T.code, .{});
    const prog = try d.load(&bin);
    const b = try d.alloc(128, .host);
    try runWait(d, &.{.{ .prog = &prog, .groups = .{ 1, 1, 1 }, .buffers = &.{b}, .params = &.{} }});
    d.fromDevice(b, 0, 128);
    for (words32(b), 0..) |x, i| try testing.expectEqual(@as(u32, @intCast(i)), x);
    try testing.expect(T.dev.lastError() == null);
}

fn newKernel(name: []const u8, group: [3]u32) kir.Kernel {
    return kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, name, group);
}

/// A run and its wait, the emulator's sentence printed when it fails.
fn runWait(d: gpu.Device, ds: []const gpu.Dispatch) !void {
    const fence = try d.run(ds);
    d.wait(fence, 10_000_000) catch |e| {
        var buf: [256]u8 = undefined;
        std.debug.print("emulated RTX: {s}: {s}\n", .{ @errorName(e), T.dev.explain(&buf) });
        return e;
    };
}

/// One dispatch run alone: the emulated RTX's warp instructions issued and
/// its longest warp's cycles.
fn runCounted(d: gpu.Device, ds: gpu.Dispatch) !emu.Stats {
    T.dev.raw.stats = .{};
    try runWait(d, &.{ds});
    return T.dev.raw.stats;
}

fn words32(b: gpu.Buffer) []u32 {
    return @alignCast(std.mem.bytesAsSlice(u32, b.cpu[0 .. b.cpu.len & ~@as(usize, 3)]));
}

test "a first kernel: out[i] = b[i] * 2.5 + a[i] + n through the adapter, QMDs and pushbuffer on the emulated RTX" {
    const d = freshEmu();
    var k = newKernel("axpy", .{ 64, 1, 1 });
    const A = k.binding();
    const Bb = k.binding();
    const O = k.binding();
    const t = k.tid(0);
    const g = k.gid(0);
    const i = k.op3(.imad, .u32, r(g), u(64), r(t));
    const off = k.op2(.shl, .u32, r(i), u(2));
    const x = k.load(.f32, kir.global(A, 32), r(off));
    const y = k.load(.f32, kir.global(Bb, 32), r(off));
    const n = k.param(.u32, 0);
    const nf = k.cvt(.u32, .f32, .rne, r(n));
    const z = k.op3(.ffma, .f32, r(y), kf(2.5), r(x));
    const z2 = k.op2(.fadd, .f32, r(z), r(nf));
    k.store(.f32, kir.global(O, 32), r(off), r(z2));
    try k.finish();
    var wmem: [kir_sm120.WORK_BYTES]u8 align(64) = undefined;
    var work = gpu.Work.init(&wmem);
    const bin = try gpu.compile(&k, d.caps, &work, &T.code);
    try testing.expectEqual(gpu.Target.sm_120, bin.target);
    const prog = try d.load(&bin);
    const ba = try d.alloc(512, .upload);
    const bb = try d.alloc(512, .upload);
    const bo = try d.alloc(512, .host);
    const fa: []f32 = @alignCast(std.mem.bytesAsSlice(f32, ba.cpu[0..512]));
    const fb: []f32 = @alignCast(std.mem.bytesAsSlice(f32, bb.cpu[0..512]));
    for (0..128) |j| {
        fa[j] = @floatFromInt(j);
        fb[j] = @as(f32, @floatFromInt(j)) * 0.5;
    }
    d.toDevice(ba, 0, 512);
    d.toDevice(bb, 0, 512);
    try runWait(d, &.{.{ .prog = &prog, .groups = .{ 2, 1, 1 }, .buffers = &.{ ba, bb, bo }, .params = &.{7} }});
    d.fromDevice(bo, 0, 512);
    const fo: []f32 = @alignCast(std.mem.bytesAsSlice(f32, bo.cpu[0..512]));
    for (0..128) |j| {
        const want = @mulAdd(f32, fb[j], 2.5, fa[j]) + 7;
        try testing.expectEqual(want, fo[j]);
    }
    try testing.expect(d.lastRunNs() > 0);
}

// ── LFM3's Q4_K matrix, rewritten in KIR ────────────────────────────────────
//
// lfm3_nv_matrix's q4kMatrix(1), op for op: 64 threads a CTA, two a row
// (h = tid & 1 has the CPU's lanes 4h..4h+3), the activations staged in
// shared memory a tile of 2048 columns at a time, the block's integer dots
// by IDP.4A, the float epilogue in the CPU's order, the row's lanes added
// across the pair by a shuffle. Bindings and parameters are MatrixParams'.

const matrix = @import("lfm3_nv_matrix");

fn q4kKir(k: *kir.Kernel) void {
    const W = k.binding();
    const AQ = k.binding();
    const AD = k.binding();
    const AS = k.binding();
    const OUT = k.binding();
    const tid = k.tid(0);
    const cta = k.gid(0);
    const rb = k.param(.u32, 0);
    const nblk = k.param(.u32, 1);
    const rows = k.param(.u32, 2);
    _ = k.param(.u32, 3); // (out_stride: one token)
    const h = k.op2(.@"and", .u32, r(tid), u(1));
    const p2 = k.cmp(.u32, .ne, r(h), u(0));
    const half = k.op2(.shr, .u32, r(tid), u(1));
    const row = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(cta), u(5))), r(half));
    const last = k.op2(.isub, .u32, r(rows), u(1));
    const rrow = k.op2(.imin, .u32, r(row), r(last));
    const wp = k.op2(.imul, .u32, r(rrow), r(rb));
    const h16 = k.op2(.shl, .u32, r(h), u(4));
    const wh = k.op2(.iadd, .u32, r(wp), r(h16));
    const tid16 = k.op2(.shl, .u32, r(tid), u(4));
    const tid4 = k.op2(.shl, .u32, r(tid), u(2));
    const tb = k.mov(.u32, u(0));
    var sum: [4]kir.V = undefined;
    for (&sum) |*s| s.* = k.mov(.f32, kf(0));
    const TILE: u32 = matrix.TILE_COLUMNS;
    const BS: u32 = TILE; // the sums' shared offset (one token)
    const ADS: u32 = TILE + 256; // the scales'
    k.loop();
    {
        // the tile's activations to shared memory
        const nb0 = k.op2(.isub, .u32, r(nblk), r(tb));
        const nb = k.op2(.imin, .u32, r(nb0), u(TILE / 256));
        const qlen = k.op2(.shl, .u32, r(nb), u(8));
        const p3 = k.cmp(.u32, .lt, r(tid16), r(qlen));
        const t2 = k.op2(.iadd, .u32, r(tid16), u(0x400));
        const p4 = k.cmp(.u32, .lt, r(t2), r(qlen));
        const slen = k.op2(.shl, .u32, r(nb), u(5));
        const p5 = k.cmp(.u32, .lt, r(tid16), r(slen));
        const p6 = k.cmp(.u32, .lt, r(tid), r(nb));
        const qo = k.op3(.imad, .u32, r(tb), u(256), r(tid16));
        var m_hi = kir.global(AQ, 128);
        m_hi.imm = 0x400;
        const v0 = k.vec(.u32, 4);
        const v1 = k.vec(.u32, 4);
        const v2 = k.vec(.u32, 4);
        const v3 = k.reg(.u32);
        k.ifp(r(p3));
        k.setAux(v0, .ld, r(qo), no, no, @bitCast(kir.global(AQ, 128)));
        k.endif();
        k.ifp(r(p4));
        k.setAux(v1, .ld, r(qo), no, no, @bitCast(m_hi));
        k.endif();
        const so = k.op3(.imad, .u32, r(tb), u(32), r(tid16));
        k.ifp(r(p5));
        k.setAux(v2, .ld, r(so), no, no, @bitCast(kir.global(AS, 128)));
        k.endif();
        const dof = k.op2(.iadd, .u32, r(tb), r(tid));
        const do4 = k.op2(.shl, .u32, r(dof), u(2));
        k.ifp(r(p6));
        k.setAux(v3, .ld, r(do4), no, no, @bitCast(kir.global(AD, 32)));
        k.endif();
        var sm = kir.shared(128);
        k.ifp(r(p3));
        k.store(.u32, sm, r(tid16), r(v0));
        k.endif();
        sm.imm = 0x400;
        k.ifp(r(p4));
        k.store(.u32, sm, r(tid16), r(v1));
        k.endif();
        sm.imm = BS;
        k.ifp(r(p5));
        k.store(.u32, sm, r(tid16), r(v2));
        k.endif();
        var sd32 = kir.shared(32);
        sd32.imm = ADS;
        k.ifp(r(p6));
        k.store(.u32, sd32, r(tid4), r(v3));
        k.endif();
        k.barrier();
        // this thread's first block in the tile
        const sa = k.mov(.u32, r(h16));
        const sb = k.op2(.iadd, .u32, r(h16), u(BS));
        const sd = k.mov(.u32, u(ADS));
        const bi = k.mov(.u32, u(0));
        k.loop();
        q4kBlock(k, W, wp, wh, sa, sb, sd, p2, &sum);
        k.set(wp, .iadd, r(wp), u(matrix.Q4_K_BLOCK), no);
        k.set(wh, .iadd, r(wh), u(matrix.Q4_K_BLOCK), no);
        k.set(sa, .iadd, r(sa), u(256), no);
        k.set(sb, .iadd, r(sb), u(32), no);
        k.set(sd, .iadd, r(sd), u(4), no);
        k.set(bi, .iadd, r(bi), u(1), no);
        const more = k.cmp(.u32, .lt, r(bi), r(nb));
        k.brk(r(k.op1(.pnot, .pred, r(more))));
        k.endloop();
        k.barrier();
        k.set(tb, .iadd, r(tb), u(TILE / 256), no);
        const again = k.cmp(.u32, .lt, r(tb), r(nblk));
        k.brk(r(k.op1(.pnot, .pred, r(again))));
    }
    k.endloop();
    // the row's lanes, as the CPU adds them, stored by h = 0
    const p1 = k.op2(.pand, .pred, r(k.cmp(.u32, .lt, r(row), r(rows))), r(k.cmp(.u32, .eq, r(h), u(0))));
    const oo = k.op2(.shl, .u32, r(row), u(2));
    var g: [4]kir.V = undefined;
    for (0..4) |j| g[j] = k.shfl(.f32, .xor, r(sum[j]), u(1));
    var fsum = k.op2(.fadd, .f32, r(sum[0]), r(sum[1]));
    fsum = k.op2(.fadd, .f32, r(fsum), r(sum[2]));
    fsum = k.op2(.fadd, .f32, r(fsum), r(sum[3]));
    for (0..4) |j| fsum = k.op2(.fadd, .f32, r(fsum), r(g[j]));
    k.ifp(r(p1));
    k.store(.f32, kir.global(OUT, 32), r(oo), r(fsum));
    k.endif();
}

fn q4kBlock(k: *kir.Kernel, W: u8, wp: kir.V, wh: kir.V, sa: kir.V, sb: kir.V, sd: kir.V, p2: kir.V, sum: *[4]kir.V) void {
    const hd = k.load(.u32, kir.global(W, 128), r(wp));
    var qw: [16]kir.V = undefined;
    for (0..4) |p| {
        var m = kir.global(W, 128);
        m.imm = @intCast(0x10 + 0x20 * p);
        const v = k.load(.u32, m, r(wh));
        for (0..4) |j| qw[4 * p + j] = kir.Kernel.at(v, @intCast(j));
    }
    const s0 = kir.Kernel.at(hd, 1);
    const s1 = kir.Kernel.at(hd, 2);
    const s2 = kir.Kernel.at(hd, 3);
    // the 6-bit scales and minimums (GGML's masks)
    const t0 = k.op2(.@"and", .u32, r(s0), u(0x3f3f3f3f));
    const t1a = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(s0), u(2))), u(0x30303030));
    const t1 = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(s2), u(0x0f0f0f0f))), r(t1a));
    var sc: [8]kir.V = undefined;
    for (0..4) |j| sc[j] = k.op3(.bfe, .u32, r(t0), u(@intCast(8 * j)), u(8));
    for (0..4) |j| sc[4 + j] = k.op3(.bfe, .u32, r(t1), u(@intCast(8 * j)), u(8));
    const m0 = k.op2(.@"and", .u32, r(s1), u(0x3f3f3f3f));
    const m1a = k.op2(.shr, .u32, r(s2), u(4));
    const m1b = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(s1), u(2))), u(0x30303030));
    const m1 = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(m1a), u(0x0f0f0f0f))), r(m1b));
    const mm = k.sel(.u32, r(p2), r(m1), r(m0));
    var mn: [4]kir.V = undefined;
    for (0..4) |j| mn[j] = k.op3(.bfe, .u32, r(mm), u(@intCast(8 * j)), u(8));
    const dd = k.cvt(.f16, .f32, .rne, r(k.mov(.f16, r(hd))));
    const dm = k.cvt(.f16, .f32, .rne, r(k.mov(.f16, r(k.op2(.shr, .u32, r(hd), u(16))))));
    // nibbles: low and high
    var lo: [16]kir.V = undefined;
    var hi: [16]kir.V = undefined;
    for (0..16) |j| {
        lo[j] = k.op2(.@"and", .u32, r(qw[j]), u(0x0f0f0f0f));
        hi[j] = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(qw[j]), u(4))), u(0x0f0f0f0f));
    }
    // the token's activations
    var a: [8]kir.V = undefined;
    for (0..4) |p| {
        var m = kir.shared(128);
        m.imm = @intCast(64 * p);
        a[2 * p] = k.load(.u32, m, r(sa));
        m.imm = @intCast(64 * p + 32);
        a[2 * p + 1] = k.load(.u32, m, r(sa));
    }
    const bs = k.load(.u32, kir.shared(128), r(sb));
    const adv = k.load(.f32, kir.shared(32), r(sd));
    var ia: [4]kir.V = undefined;
    for (0..4) |p| {
        for (0..4) |j| {
            // (s8u8: the activations signed, the nibbles unsigned)
            const dt = k.opAux(.dot4, .i32, r(kir.Kernel.at(a[2 * p], @intCast(j))), r(lo[4 * p + j]), u(0), @intFromEnum(kir.Dot4.s8u8));
            if (p == 0) {
                ia[j] = k.op2(.imul, .i32, r(dt), r(sc[2 * p]));
            } else k.set(ia[j], .imad, r(dt), r(sc[2 * p]), r(ia[j]));
            const dt2 = k.opAux(.dot4, .i32, r(kir.Kernel.at(a[2 * p + 1], @intCast(j))), r(hi[4 * p + j]), u(0), @intFromEnum(kir.Dot4.s8u8));
            k.set(ia[j], .imad, r(dt2), r(sc[2 * p + 1]), r(ia[j]));
        }
    }
    const xv = k.op2(.fmul, .f32, r(dd), r(adv));
    const yv = k.op2(.fmul, .f32, r(dm), r(adv));
    for (0..4) |j| {
        const bsj = kir.Kernel.at(bs, @intCast(j));
        const mt0 = k.op3(.imad, .i32, r(bsj), u(0x10000), r(bsj));
        const mt1 = k.op2(.shr, .i32, r(mt0), u(16));
        const mt = k.op2(.imul, .i32, r(mt1), r(mn[j]));
        const ft = k.op2(.fmul, .f32, r(xv), r(k.cvt(.i32, .f32, .rne, r(ia[j]))));
        const mf = k.op2(.fmul, .f32, r(yv), r(k.cvt(.i32, .f32, .rne, r(mt))));
        const df = k.op2(.fsub, .f32, r(ft), r(mf));
        k.set(sum[j], .fadd, r(sum[j]), r(df), no);
    }
}

/// Random Q4_K rows with sane f16 scales, random Q8_K activations.
fn fillQ4K(w: []u8, aq: []u8, ad: []f32, sums: []i16, rows: u32, blocks: u32, seed0: u32) void {
    var seed = seed0;
    for (w) |*b| b.* = @truncate(lcg(&seed) >> 13);
    for (0..rows * blocks) |blk| {
        const b = w[blk * matrix.Q4_K_BLOCK ..][0..matrix.Q4_K_BLOCK];
        std.mem.writeInt(u16, b[0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
        std.mem.writeInt(u16, b[2..4], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
        if (blk % 7 == 3) @memset(b, 0);
    }
    for (aq) |*q| q.* = @truncate(lcg(&seed) >> 11);
    for (ad) |*x| x.* = @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 * 0.02;
    for (sums) |*x| x.* = @bitCast(@as(u16, @truncate(lcg(&seed) >> 9)));
}

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

/// An assembled hand-written kernel as a Binary.
fn handBinary(text: []const u8, group: [3]u32, shared: u32, bindings: u8, param_words: u16) !gpu.Binary {
    const ak = try nvidia.sm120_asm.assemble(text, &T.words, &T.asm_work);
    return .{
        .target = .sm_120,
        .code = std.mem.sliceAsBytes(ak.code),
        .regs = ak.registers,
        .shared_bytes = shared,
        .group = group,
        .bindings = bindings,
        .param_words = param_words,
        .extra = blk: {
            var e = [_]u32{0} ** 16;
            e[kir_sm120.EXTRA_INSTRUCTIONS] = ak.count;
            break :blk e;
        },
    };
}

test "Q4_K x Q8_K in KIR: the hand kernel's bits (33 rows, 9 blocks: two tiles, a last CTA of one), within 10% of its instructions" {
    const d = freshEmu();
    var k = newKernel("q4k_kir", .{ matrix.MATRIX_THREADS, 1, 1 });
    q4kKir(&k);
    k.shared_bytes = matrix.Q8K_TILE_BYTES;
    try k.finish();
    const text = try kir_sm120.compileText(&k, d.caps, &T.st, .{});
    const bin = kir_sm120.compileIn(&k, d.caps, &T.st, &T.code, .{}) catch |e| {
        std.debug.print("{s}\n", .{text});
        return e;
    };
    const kir_count = bin.extra[kir_sm120.EXTRA_INSTRUCTIONS];
    const kir_regs = bin.regs;
    const prog = try d.load(&bin);
    const hbin = try handBinary(matrix.q4kMatrix(1), .{ matrix.MATRIX_THREADS, 1, 1 }, matrix.Q8K_TILE_BYTES, 5, 4);
    const hand = try d.load(&hbin);
    const rows: u32 = 33;
    const blocks: u32 = 9;
    const row_bytes = blocks * matrix.Q4_K_BLOCK;
    const kc = blocks * 256;
    const w = try d.alloc(rows * row_bytes + 16, .device);
    const aq = try d.alloc(kc, .upload);
    const ad = try d.alloc(blocks * 4, .upload);
    const as = try d.alloc(blocks * 32, .upload);
    const out1 = try d.alloc(rows * 4, .host);
    const out2 = try d.alloc(rows * 4, .host);
    fillQ4K(w.cpu[0 .. rows * row_bytes], aq.cpu, @alignCast(std.mem.bytesAsSlice(f32, ad.cpu)), @alignCast(std.mem.bytesAsSlice(i16, as.cpu)), rows, blocks, 0x5eed);
    for ([_]gpu.Buffer{ w, aq, ad, as }) |b| d.toDevice(b, 0, b.bytes);
    const shape = try matrix.matrixLaunch(.q4_k, 1, rows, blocks);
    const params = [_]u32{ row_bytes, blocks, rows, rows * 4 };
    const hs = try runCounted(d, .{ .prog = &hand, .groups = shape.grid, .buffers = &.{ w, aq, ad, as, out1 }, .params = &params });
    const ksx = try runCounted(d, .{ .prog = &prog, .groups = shape.grid, .buffers = &.{ w, aq, ad, as, out2 }, .params = &params });
    std.debug.print("Q4_K emulated: KIR {d} warp instructions, {d} cycles; hand {d}, {d}\n", .{ ksx.instructions, ksx.cycles, hs.instructions, hs.cycles });
    d.fromDevice(out1, 0, out1.bytes);
    d.fromDevice(out2, 0, out2.bytes);
    try testing.expectEqualSlices(u32, words32(out1), words32(out2));
    // (and not all zeros)
    var nonzero: usize = 0;
    for (words32(out1)) |x| nonzero += @intFromBool(x != 0);
    try testing.expect(nonzero > rows / 2);
    const hand_count = hbin.extra[kir_sm120.EXTRA_INSTRUCTIONS];
    std.debug.print("Q4_K, one token: KIR {d} instructions, {d} registers; hand {d} instructions, {d} registers\n", .{ kir_count, kir_regs, hand_count, hbin.regs });
    try testing.expect(kir_count * 10 <= hand_count * 11);
}

// ── Every KIR op against the interpreter ────────────────────────────────────
//
// Each case is a kernel of 128 threads (two groups of 64): thread t reads
// a[t], b[t], c[t] (registers, or immediates in their place), computes one
// op and stores it; the same kernel runs in the interpreter with the same
// caps, and every word must be the same (NaNs as NaNs: the interpreter's
// NaN is 0x7fffffff, the GPU's may be any). The approximate ops are
// compared within their documented bounds instead.

const interp = @import("kir_interp.sig");

const NT = 128;

const X = struct {
    var in: [3][NT]u32 = undefined;
    var ref: [16 * NT]u32 = undefined;
    var iwork: [8 << 20]u8 align(64) = undefined;
    var cases: usize = 0;
};

const Src = union(enum) { reg, imm: u32, pred };

fn caseCaps(flush: bool) gpu.Caps {
    var c = emuCaps();
    if (flush) c.denormals = .flush;
    return c;
}

/// The float inputs: specials first (zeros, infinities, NaNs, denormals,
/// the sqrt and division paths' edges), then random bits.
fn fillFloats(seed: u32) void {
    const specials = [_]u32{
        0x0000_0000, 0x8000_0000, 0x3f80_0000, 0xbf80_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xffc0_0001,
        0x0000_0001, 0x8000_0001, 0x007f_ffff, 0x807f_ffff, 0x0080_0000, 0x7f7f_ffff, 0xff7f_ffff, 0x0d00_0000,
        0x0cff_ffff, 0x3fc0_0000, 0x4049_0fdb, 0xc049_0fdb, 0x3eaa_aaab, 0x4b00_0000, 0xcb00_0001, 0x4f00_0000,
        0xcf00_0000, 0x4f80_0000, 0x3f00_0000, 0xbf00_0000, 0x3fc0_0001, 0x4040_0000, 0x2780_0000, 0x5880_0000,
    };
    var s = seed;
    for (0..3) |j| {
        for (0..NT) |i| {
            X.in[j][i] = if (i < specials.len) specials[(i + 7 * j) % specials.len] else lcg(&s);
            // (some sane magnitudes too)
            if (i >= 96) X.in[j][i] = @bitCast(@as(f32, @floatFromInt(@as(i32, @bitCast(lcg(&s))) >> 12)) / 1024.0);
        }
    }
}

fn fillInts(seed: u32) void {
    const specials = [_]u32{ 0, 1, 2, 31, 32, 33, 63, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 0xffff, 0x10000, 0x80, 0xff, 0x7f, 0xfffe, 5, 7, 8, 16, 24, 0xdead_beef, 0x0102_0304, 0x8081_7f7e };
    var s = seed;
    for (0..3) |j| {
        for (0..NT) |i| {
            X.in[j][i] = if (i < specials.len) specials[(i + 5 * j) % specials.len] else lcg(&s);
            if (i >= 100) X.in[j][i] = lcg(&s) % 40; // (small: shift amounts, widths)
        }
    }
}

const OpCase = struct {
    op: kir.Op,
    ty: kir.Ty,
    aux: u32 = 0,
    a: Src = .reg,
    b: Src = .{ .imm = 0 },
    c: Src = .{ .imm = 0 },
    /// the inputs' register types (the op's ty when null)
    in_ty: ?kir.Ty = null,
    /// compare within this relative error (approximate ops)
    tol: ?f64 = null,
};

fn unused(op: kir.Op, which: u2) bool {
    return switch (op) {
        .mov, .ineg, .iabs, .not, .pnot, .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne, .fsqrt, .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos, .cvt => which >= 1,
        .sel, .imad, .bfe, .dot4, .ffma, .fmad => false,
        else => which >= 2,
    };
}

/// The case's kernel into `k`.
fn buildCase(k: *kir.Kernel, cs: OpCase) void {
    const A = k.binding();
    const Bb = k.binding();
    const C = k.binding();
    const O = k.binding();
    const t = k.op3(.imad, .u32, r(k.gid(0)), u(64), r(k.tid(0)));
    const off = k.op2(.shl, .u32, r(t), u(2));
    const bins = [3]u8{ A, Bb, C };
    const srcs = [3]Src{ cs.a, cs.b, cs.c };
    var args: [3]kir.Arg = .{ no, no, no };
    const in_ty = cs.in_ty orelse cs.ty;
    for (0..3) |j| {
        if (unused(cs.op, @intCast(j))) continue;
        args[j] = switch (srcs[j]) {
            .imm => |x| u(x),
            .pred => r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(k.load(.u32, kir.global(bins[j], 32), r(off))), u(1))), u(0))),
            .reg => blk: {
                const want: kir.Ty = if (cs.op == .sel and j == 2) .pred else if (j == 2 and cs.op == .dot4) .u32 else in_ty;
                if (want == .pred) break :blk r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(k.load(.u32, kir.global(bins[j], 32), r(off))), u(1))), u(0)));
                if (want == .f16) break :blk r(k.mov(.f16, r(k.load(.u32, kir.global(bins[j], 32), r(off)))));
                break :blk r(k.load(want, kir.global(bins[j], 32), r(off)));
            },
        };
    }
    // (sel's predicate is c; a pred op's operands are preds)
    var res = k.opAux(cs.op, cs.ty, args[0], args[1], args[2], cs.aux);
    const out_ty = k.tys[@intFromEnum(res)];
    if (out_ty == .pred) res = k.sel(.u32, r(res), u(1), u(0));
    const st_ty: kir.Ty = if (out_ty == .pred) .u32 else out_ty;
    if (st_ty == .f16) {
        k.store(.f16, kir.global(O, 16), r(k.op2(.shl, .u32, r(t), u(1))), r(res));
    } else k.store(st_ty, kir.global(O, 32), r(off), r(res));
}

/// The interpreter's and the emulated RTX's outputs of `k` on X.in.
fn runBoth(caps: gpu.Caps, k: *kir.Kernel, groups: [3]u32, params: []const u32, out_bytes: usize, emu_out: []u8, opts: kir_sm120.Options) !void {
    try k.finish();
    // the interpreter
    var iw = gpu.Work.init(&X.iwork);
    var trap: interp.Trap = .{};
    var ina: [3][NT]u32 = X.in;
    @memset(std.mem.sliceAsBytes(&X.ref), 0);
    const bindings = [_][]u8{ std.mem.sliceAsBytes(&ina[0]), std.mem.sliceAsBytes(&ina[1]), std.mem.sliceAsBytes(&ina[2]), std.mem.sliceAsBytes(&X.ref)[0..out_bytes] };
    _ = interp.runKernel(k, caps, groups, bindings[0..k.bindings], params, &iw, &trap) catch |e| {
        std.debug.print("interp: {s} at {d} ({s})\n", .{ @errorName(e), trap.pc, @tagName(trap.what) });
        return e;
    };
    // the emulated RTX
    const d = freshEmu();
    const bin = kir_sm120.compileIn(k, caps, &T.st, &T.code, opts) catch |e| {
        std.debug.print("compile {s}: {s}\n", .{ k.name, @errorName(e) });
        return e;
    };
    const prog = try d.load(&bin);
    var bufs: [4]gpu.Buffer = undefined;
    for (0..3) |j| {
        bufs[j] = try d.alloc(NT * 4, .upload);
        @memcpy(bufs[j].cpu[0 .. NT * 4], std.mem.sliceAsBytes(&X.in[j]));
        d.toDevice(bufs[j], 0, NT * 4);
    }
    bufs[3] = try d.alloc(@max(out_bytes, 16), .host);
    @memset(bufs[3].cpu, 0);
    d.toDevice(bufs[3], 0, bufs[3].bytes);
    const used: []const gpu.Buffer = if (k.bindings == 4) &bufs else bufs[0..k.bindings];
    runWait(d, &.{.{ .prog = &prog, .groups = groups, .buffers = used, .params = params }}) catch |e| {
        var buf: [96 * 1024]u8 = undefined;
        std.debug.print("{s}\n", .{kir_sm120.compileText(k, caps, &T.st, opts) catch &buf});
        return e;
    };
    d.fromDevice(bufs[3], 0, out_bytes);
    @memcpy(emu_out[0..out_bytes], bufs[3].cpu[0..out_bytes]);
    X.cases += 1;
}

fn isNan32(x: u32) bool {
    return x & 0x7fff_ffff > 0x7f80_0000;
}

fn runCase(caps: gpu.Caps, cs: OpCase) !void {
    var k = newKernel(@tagName(cs.op), .{ 64, 1, 1 });
    buildCase(&k, cs);
    var got: [NT * 4]u8 align(4) = undefined;
    const half = k.tys[@intFromEnum(k.code()[k.n - 1].b.reg)] == .f16;
    const bytes: usize = if (half) NT * 2 else NT * 4;
    try runBoth(caps, &k, .{ 2, 1, 1 }, &.{}, bytes, &got, .{});
    var bad: usize = 0;
    const words: usize = if (half) NT / 2 else NT;
    const g32: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, got[0 .. words * 4]));
    for (0..words) |i| {
        const want = X.ref[i];
        const have = g32[i];
        if (want == have) continue;
        const float_out = !half and cs.ty == .f32 and cs.op != .cvt or (cs.op == .cvt and @as(kir.Cvt, @bitCast(cs.aux)).to == .f32);
        if (float_out and isNan32(want) and isNan32(have)) continue;
        if (half) {
            // (two halves a word: NaNs as NaNs)
            var ok = true;
            for (0..2) |h| {
                const wv: u16 = @truncate(want >> @intCast(16 * h));
                const hv: u16 = @truncate(have >> @intCast(16 * h));
                if (wv != hv and !(wv & 0x7fff > 0x7c00 and hv & 0x7fff > 0x7c00)) ok = false;
            }
            if (ok) continue;
        }
        if (cs.tol) |tol| {
            const wf: f64 = @as(f32, @bitCast(want));
            const hf: f64 = @as(f32, @bitCast(have));
            if (std.math.isInf(wf) and wf == hf) continue;
            const absolute = cs.op == .fsin or cs.op == .fcos;
            if (@abs(wf - hf) <= tol * (if (absolute) 1.0 else @max(@abs(wf), 1e-30))) continue;
            // (the SFU flushes denormals, in and out; the interpreter's
            // approximations do not)
            if (@abs(wf) < 1.2e-38 and @abs(hf) < 1.2e-38) continue;
            const ax = X.in[0][i] & 0x7fff_ffff;
            if (ax != 0 and ax < 0x0080_0000) continue;
        }
        if (bad < 4) std.debug.print("{s} ({s}, aux {x}) lane {d}: a {x} b {x} c {x}: interp {x}, RTX {x}\n", .{ @tagName(cs.op), @tagName(cs.ty), cs.aux, i, X.in[0][i], X.in[1][i], X.in[2][i], want, have });
        bad += 1;
    }
    if (bad != 0) {
        std.debug.print("{s}\n", .{try kir_sm120.compileText(&k, caps, &T.st, .{})});
        return error.TestUnexpectedResult;
    }
}

fn cvtAux(from: kir.Ty, to: kir.Ty, round: kir.Round) u32 {
    return @bitCast(kir.Cvt{ .from = from, .to = to, .round = round });
}

test "every integer op equals the interpreter (registers and immediates in each slot)" {
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        fillInts(0x1234);
        const int_ops = [_]kir.Op{ .iadd, .isub, .imul, .imulhi, .imin, .imax, .@"and", .@"or", .xor, .shl, .shr };
        for ([_]kir.Ty{ .u32, .i32 }) |ty| {
            for (int_ops) |op| {
                try runCase(caps, .{ .op = op, .ty = ty });
                try runCase(caps, .{ .op = op, .ty = ty, .b = .reg });
                try runCase(caps, .{ .op = op, .ty = ty, .b = .{ .imm = 0xffff_fff3 } });
                try runCase(caps, .{ .op = op, .ty = ty, .b = .{ .imm = 37 } });
                try runCase(caps, .{ .op = op, .ty = ty, .a = .{ .imm = 0x8000_0005 }, .b = .reg });
            }
            try runCase(caps, .{ .op = .imad, .ty = ty, .b = .reg, .c = .reg });
            try runCase(caps, .{ .op = .imad, .ty = ty, .b = .{ .imm = 0x10000 }, .c = .reg });
            try runCase(caps, .{ .op = .imad, .ty = ty, .b = .reg, .c = .{ .imm = 0x7fff_fff0 } });
            try runCase(caps, .{ .op = .imad, .ty = ty, .b = .{ .imm = 3 }, .c = .{ .imm = 5 } });
            try runCase(caps, .{ .op = .ineg, .ty = ty });
            try runCase(caps, .{ .op = .not, .ty = ty });
            try runCase(caps, .{ .op = .mov, .ty = ty });
            for ([_]u32{ 0, 1, 8, 13, 16, 24, 31, 32 }) |off| {
                for ([_]u32{ 0, 1, 5, 8, 16, 31, 32, 40 }) |len| try runCase(caps, .{ .op = .bfe, .ty = ty, .b = .{ .imm = off }, .c = .{ .imm = len } });
            }
            try runCase(caps, .{ .op = .bfe, .ty = ty, .b = .reg, .c = .reg });
            try runCase(caps, .{ .op = .bfe, .ty = ty, .b = .reg, .c = .{ .imm = 7 } });
            try runCase(caps, .{ .op = .sel, .ty = ty, .b = .reg, .c = .reg });
            try runCase(caps, .{ .op = .sel, .ty = ty, .a = .{ .imm = 77 }, .b = .reg, .c = .reg });
            try runCase(caps, .{ .op = .sel, .ty = ty, .a = .reg, .b = .{ .imm = 99 }, .c = .reg });
            try runCase(caps, .{ .op = .sel, .ty = ty, .a = .{ .imm = 1 }, .b = .{ .imm = 2 }, .c = .reg });
            for (0..6) |cmp| {
                try runCase(caps, .{ .op = .icmp, .ty = ty, .aux = @intCast(cmp), .b = .reg });
                try runCase(caps, .{ .op = .icmp, .ty = ty, .aux = @intCast(cmp), .b = .{ .imm = 0x8000_0000 } });
                try runCase(caps, .{ .op = .icmp, .ty = ty, .aux = @intCast(cmp), .a = .{ .imm = 31 }, .b = .reg });
            }
            for (0..3) |m| {
                try runCase(caps, .{ .op = .dot4, .ty = ty, .aux = @intCast(m), .b = .reg, .c = .reg });
                try runCase(caps, .{ .op = .dot4, .ty = ty, .aux = @intCast(m), .b = .{ .imm = 0x80ff_7f01 }, .c = .{ .imm = 0x1234_5678 } });
            }
        }
        try runCase(caps, .{ .op = .iabs, .ty = .i32 });
        // predicates
        for ([_]kir.Op{ .pand, .por }) |op| {
            try runCase(caps, .{ .op = op, .ty = .pred, .a = .pred, .b = .pred });
            try runCase(caps, .{ .op = op, .ty = .pred, .a = .pred, .b = .{ .imm = 1 } });
            try runCase(caps, .{ .op = op, .ty = .pred, .a = .pred, .b = .{ .imm = 0 } });
        }
        try runCase(caps, .{ .op = .pnot, .ty = .pred, .a = .pred });
        try runCase(caps, .{ .op = .mov, .ty = .pred, .a = .pred });
        try runCase(caps, .{ .op = .sel, .ty = .pred, .a = .pred, .b = .pred, .c = .reg });
    }
    std.debug.print("integer ops: {d} kernels\n", .{X.cases});
}

test "every float op equals the interpreter, denormals kept and flushed" {
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        fillFloats(0x51ce);
        for ([_]kir.Op{ .fadd, .fsub, .fmul, .fmin, .fmax }) |op| {
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .reg });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .{ .imm = 0x3fc0_0000 } });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .{ .imm = 0x8000_0000 } });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .{ .imm = 0x0000_0003 } });
            try runCase(caps, .{ .op = op, .ty = .f32, .a = .{ .imm = 0xc0a0_0000 }, .b = .reg });
        }
        for ([_]kir.Op{ .ffma, .fmad }) |op| {
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .reg, .c = .reg });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .{ .imm = 0xbf80_0000 }, .c = .reg });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .reg, .c = .{ .imm = 0x3400_0000 } });
            try runCase(caps, .{ .op = op, .ty = .f32, .b = .{ .imm = 0x4000_0000 }, .c = .{ .imm = 0x0000_0001 } });
        }
        for ([_]kir.Op{ .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne, .mov }) |op| try runCase(caps, .{ .op = op, .ty = .f32 });
        try runCase(caps, .{ .op = .sel, .ty = .f32, .b = .reg, .c = .reg });
        for (0..6) |cmp| {
            try runCase(caps, .{ .op = .fcmp, .ty = .f32, .aux = @intCast(cmp), .b = .reg });
            try runCase(caps, .{ .op = .fcmp, .ty = .f32, .aux = @intCast(cmp), .b = .{ .imm = 0x0000_0001 } });
            try runCase(caps, .{ .op = .fcmp, .ty = .f32, .aux = @intCast(cmp), .a = .{ .imm = 0x7fc0_0000 }, .b = .reg });
        }
        // the approximate ops: within 2^-21 relative (the emulator's SFU is
        // exact to f64; the hardware's bounds are docs/GPU.md's)
        for ([_]kir.Op{ .frcp, .frsq, .fexp2, .flog2 }) |op| try runCase(caps, .{ .op = op, .ty = .f32, .tol = 1.0 / 2097152.0 });
    }
    std.debug.print("float ops: {d} kernels so far\n", .{X.cases});
}

test "fsin and fcos within their bounds" {
    const caps = caseCaps(false);
    var s: u32 = 9;
    for (0..3) |j| {
        for (0..NT) |i| X.in[j][i] = @bitCast((@as(f32, @floatFromInt(lcg(&s) >> 8)) / 16777216.0 - 0.5) * 20.0);
    }
    for ([_]kir.Op{ .fsin, .fcos }) |op| try runCase(caps, .{ .op = op, .ty = .f32, .tol = 1.0 / 65536.0 });
}

test "every conversion equals the interpreter, in each rounding" {
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        const tys = [_]kir.Ty{ .u32, .i32, .f32, .f16 };
        for (tys) |from| {
            for (tys) |to| {
                const c0 = kir.Cvt{ .from = from, .to = to, .round = .rne };
                // (the pairs the verifier takes)
                if (from == to) continue;
                if ((from == .u32 or from == .i32) and to == .f16) continue;
                if (from == .f16 and (to == .u32 or to == .i32)) continue;
                _ = c0;
                for ([_]kir.Round{ .rne, .rz, .rd, .ru }) |rd| {
                    if (from == .f32 or from == .f16) fillFloats(0x77 + @intFromEnum(rd)) else fillInts(0x99 + @intFromEnum(rd));
                    if (from == .f32 and (to == .u32 or to == .i32)) {
                        // (and the values around the integers' limits)
                        for ([_]u32{ 0x4f00_0000, 0x4eff_ffff, 0xcf00_0000, 0xcf00_0001, 0x4f80_0000, 0x4f7f_ffff, 0xbf00_0000, 0x3f00_0000, 0xbfc0_0000, 0x3fc0_0000 }, 0..) |v, i| X.in[0][60 + i] = v;
                    }
                    try runCase(caps, .{ .op = .cvt, .ty = to, .aux = cvtAux(from, to, rd), .in_ty = from });
                }
            }
        }
    }
}

test "fdiv and fsqrt bit-exact: kir.expandDiv's fused path, sqrt native and expanded, denormals kept and flushed" {
    var s: u32 = 0xd1;
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        for (0..12) |round| {
            fillFloats(0x2000 + @as(u32, @intCast(round)));
            // (random magnitudes over the whole range in later rounds)
            if (round >= 4) {
                for (0..3) |j| {
                    for (32..NT) |i| X.in[j][i] = lcg(&s) & if (round % 2 == 0) @as(u32, 0x7fff_ffff) else 0xffff_ffff;
                }
            }
            try runCase(caps, .{ .op = .fdiv, .ty = .f32, .b = .reg });
            try runCase(caps, .{ .op = .fsqrt, .ty = .f32 });
            var k = newKernel("fsqrt-expanded", .{ 64, 1, 1 });
            buildCase(&k, .{ .op = .fsqrt, .ty = .f32 });
            var got: [NT * 4]u8 align(4) = undefined;
            try runBoth(caps, &k, .{ 2, 1, 1 }, &.{}, NT * 4, &got, .{ .native_sqrt = false });
            const g32: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, &got));
            for (0..NT) |i| {
                if (X.ref[i] != g32[i] and !(isNan32(X.ref[i]) and isNan32(g32[i]))) {
                    std.debug.print("expanded fsqrt({x}): interp {x}, RTX {x}\n", .{ X.in[0][i], X.ref[i], g32[i] });
                    return error.TestUnexpectedResult;
                }
            }
        }
        try runCase(caps, .{ .op = .fdiv, .ty = .f32, .b = .{ .imm = 0x4040_0000 } });
        try runCase(caps, .{ .op = .fdiv, .ty = .f32, .a = .{ .imm = 0x3f80_0000 }, .b = .reg });
    }
}

/// `k` on both, every output word the same (or only those `pick` says).
fn same(caps: gpu.Caps, k: *kir.Kernel, groups: [3]u32, params: []const u32, out_words: usize, pick: ?[]const usize) !void {
    var got: [16 * NT * 4]u8 align(4) = undefined;
    try runBoth(caps, k, groups, params, out_words * 4, &got, .{});
    const g32: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, got[0 .. out_words * 4]));
    var bad: usize = 0;
    if (pick) |idx| {
        for (idx) |i| {
            if (X.ref[i] != g32[i]) {
                if (bad < 6) std.debug.print("{s} word {d}: interp {x}, RTX {x}\n", .{ k.name, i, X.ref[i], g32[i] });
                bad += 1;
            }
        }
    } else for (0..out_words) |i| {
        if (X.ref[i] != g32[i]) {
            if (bad < 6) std.debug.print("{s} word {d}: interp {x}, RTX {x}\n", .{ k.name, i, X.ref[i], g32[i] });
            bad += 1;
        }
    }
    if (bad != 0) {
        std.debug.print("{s}\n", .{try kir_sm120.compileText(k, caps, &T.st, .{})});
        return error.TestUnexpectedResult;
    }
}

fn lin(k: *kir.Kernel) kir.V {
    return k.op3(.imad, .u32, r(k.gid(0)), u(64), r(k.tid(0)));
}

test "memory: 8- to 128-bit loads and stores, signed, global and shared, immediate and register addresses" {
    const caps = caseCaps(false);
    fillInts(0x3e3);
    var k = newKernel("memory", .{ 64, 1, 1 });
    const A = k.binding();
    const Bb = k.binding();
    _ = k.binding();
    const O = k.binding();
    const t = lin(&k);
    const tid = k.tid(0);
    var m8 = kir.global(A, 8);
    const b8 = k.load(.u32, m8, r(k.op2(.iadd, .u32, r(t), u(3))));
    m8.signed = true;
    const s8 = k.load(.i32, m8, r(k.op2(.@"and", .u32, r(k.op2(.imul, .u32, r(t), u(5))), u(511))));
    var m16 = kir.global(A, 16);
    const h16 = k.load(.u32, m16, r(k.op2(.shl, .u32, r(t), u(1))));
    m16.signed = true;
    m16.imm = 6;
    const s16 = k.load(.i32, m16, r(k.op2(.shl, .u32, r(t), u(1))));
    const v2 = k.load(.u32, kir.global(Bb, 64), r(k.op2(.@"and", .u32, r(k.op2(.shl, .u32, r(t), u(3))), u(0x1f8))));
    const v4 = k.load(.u32, kir.global(Bb, 128), r(k.op2(.@"and", .u32, r(k.op2(.shl, .u32, r(t), u(4))), u(0x1f0))));
    const f16v = k.load(.f16, kir.global(A, 16), u(10));
    const ob = k.op2(.shl, .u32, r(t), u(5));
    k.store(.i32, kir.global(O, 32), r(ob), r(s8));
    var m = kir.global(O, 16);
    m.imm = 4;
    k.store(.u32, m, r(ob), r(h16));
    m = kir.global(O, 8);
    m.imm = 6;
    k.store(.u32, m, r(ob), r(b8));
    m = kir.global(O, 8);
    m.imm = 7;
    k.store(.u32, m, r(ob), r(s16));
    m = kir.global(O, 64);
    m.imm = 8;
    k.store(.u32, m, r(ob), r(v2));
    m = kir.global(O, 128);
    m.imm = 16;
    k.store(.u32, m, r(ob), r(v4));
    // shared: each thread's quad at 16 tid, the neighbour's read back, its
    // bytes and halves too
    k.shared_bytes = 64 * 16 + 16;
    const st16 = k.op2(.shl, .u32, r(tid), u(4));
    k.store(.u32, kir.shared(128), r(st16), r(v4));
    var sm = kir.shared(16);
    sm.imm = 64 * 16;
    k.ifp(r(k.cmp(.u32, .eq, r(tid), u(0))));
    k.store(.f16, sm, u(0), r(f16v));
    k.endif();
    k.barrier();
    const nb = k.op2(.shl, .u32, r(k.op2(.xor, .u32, r(tid), u(1))), u(4));
    const w4 = k.load(.u32, kir.shared(128), r(nb));
    var sb = kir.shared(8);
    sb.signed = true;
    sb.imm = 5;
    const sbyte = k.load(.i32, sb, r(nb));
    var sh = kir.shared(16);
    sh.imm = 10;
    const shalf = k.load(.u32, sh, r(nb));
    var shf = kir.shared(16);
    shf.imm = 64 * 16;
    const f16b = k.load(.f16, shf, u(0));
    const f32b = k.cvt(.f16, .f32, .rne, r(f16b));
    // O's second and third regions: the neighbour's quad; the signed
    // byte, the half and the f16 as f32
    const ob2 = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(t), u(4))), u(32 * NT));
    k.store(.u32, kir.global(O, 128), r(ob2), r(w4));
    const ob3 = k.op2(.iadd, .u32, r(ob2), u(16 * NT));
    k.store(.i32, kir.global(O, 32), r(ob3), r(sbyte));
    m = kir.global(O, 32);
    m.imm = 4;
    k.store(.u32, m, r(ob3), r(shalf));
    m.imm = 8;
    k.store(.f32, m, r(ob3), r(f32b));
    try same(caps, &k, .{ 2, 1, 1 }, &.{}, 16 * NT, null);
}

test "atomics, barriers, shuffles, votes" {
    const caps = caseCaps(false);
    fillInts(0xa70);
    {
        // global and shared atomics: the final words (the old values depend on
        // the order lanes run in, and are not compared)
        var k = newKernel("atomics", .{ 64, 1, 1 });
        const A = k.binding();
        _ = k.binding();
        _ = k.binding();
        const O = k.binding();
        k.shared_bytes = 16;
        const t = lin(&k);
        const tid = k.tid(0);
        const x = k.load(.u32, kir.global(A, 32), r(k.op2(.shl, .u32, r(t), u(2))));
        const g = kir.global(O, 32);
        _ = k.atomic(.u32, .add, g, u(0), r(x));
        var g4 = g;
        g4.imm = 4;
        _ = k.atomic(.u32, .min, g4, u(0), r(x));
        _ = k.atomic(.i32, .max, g, u(8), r(x));
        _ = k.atomic(.i32, .min, g, u(12), r(x));
        _ = k.atomic(.u32, .xchg, g, u(16), r(x));
        // (thread 0 sets the shared words)
        const first = k.cmp(.u32, .eq, r(tid), u(0));
        k.ifp(r(first));
        k.store(.u32, kir.shared(32), u(0), u(0));
        k.store(.u32, kir.shared(32), u(4), u(0xffff_ffff));
        k.store(.u32, kir.shared(32), u(8), u(0x8000_0000));
        k.endif();
        k.barrier();
        _ = k.atomic(.u32, .add, kir.shared(32), u(0), r(x));
        _ = k.atomic(.u32, .min, kir.shared(32), u(4), r(x));
        _ = k.atomic(.i32, .max, kir.shared(32), u(8), r(x));
        _ = k.atomic(.u32, .xchg, kir.shared(32), u(12), r(tid));
        k.barrier();
        k.ifp(r(first));
        const ob = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(k.gid(0)), u(4))), u(32));
        const s0 = k.load(.u32, kir.shared(128), u(0));
        k.store(.u32, kir.global(O, 128), r(ob), r(s0));
        k.endif();
        // (O starts zeroed: min's starting 0 stays; give it a start)
        try same(caps, &k, .{ 2, 1, 1 }, &.{}, 16, &.{ 0, 1, 2, 3, 8, 9, 10, 12, 13, 14 });
    }
    {
        // shuffles in each mode, lanes as immediates and registers; votes
        var k = newKernel("warp", .{ 64, 1, 1 });
        const A = k.binding();
        const Bb = k.binding();
        _ = k.binding();
        const O = k.binding();
        const t = lin(&k);
        const off = k.op2(.shl, .u32, r(t), u(2));
        const x = k.load(.u32, kir.global(A, 32), r(off));
        const y = k.load(.u32, kir.global(Bb, 32), r(off));
        const ob = k.op2(.shl, .u32, r(t), u(5));
        var vals: [8]kir.V = undefined;
        vals[0] = k.shfl(.u32, .idx, r(x), r(y));
        vals[1] = k.shfl(.u32, .idx, r(x), u(5));
        vals[2] = k.shfl(.u32, .xor, r(x), u(1));
        vals[3] = k.shfl(.u32, .xor, r(x), r(k.op2(.@"and", .u32, r(y), u(31))));
        vals[4] = k.shfl(.u32, .up, r(x), u(3));
        vals[5] = k.shfl(.u32, .down, r(x), u(7));
        vals[6] = k.shfl(.f32, .down, r(k.load(.f32, kir.global(A, 32), r(off))), r(k.op2(.@"and", .u32, r(y), u(15))));
        const p = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(x), u(1))), u(0));
        const q = k.cmp(.u32, .lt, r(k.lane()), u(31));
        const any = k.vote(.any, r(p));
        const all = k.vote(.all, r(q));
        vals[7] = k.op2(.iadd, .u32, r(k.sel(.u32, r(any), u(1), u(0))), r(k.sel(.u32, r(all), u(2), u(0))));
        for (vals, 0..) |v, j| {
            var m = kir.global(O, 32);
            m.imm = @intCast(4 * j);
            k.store(if (j == 6) .f32 else .u32, m, r(ob), r(v));
        }
        try same(caps, &k, .{ 2, 1, 1 }, &.{}, 8 * NT, null);
    }
}

test "control flow: divergent ifs, loops with brk and cont, nesting, an early ret" {
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        fillInts(0xc0f);
        var k = newKernel("flow", .{ 64, 1, 1 });
        const A = k.binding();
        const Bb = k.binding();
        _ = k.binding();
        const O = k.binding();
        const t = lin(&k);
        const off = k.op2(.shl, .u32, r(t), u(2));
        const x = k.load(.u32, kir.global(A, 32), r(off));
        const y = k.load(.u32, kir.global(Bb, 32), r(off));
        const acc = k.mov(.u32, u(0));
        const i = k.mov(.u32, u(0));
        const n = k.op2(.@"and", .u32, r(x), u(15));
        // a loop whose trip count differs by lane, an if/else in it, a cont
        k.loop();
        {
            k.brk(r(k.cmp(.u32, .ge, r(i), r(n))));
            k.set(i, .iadd, r(i), u(1), no);
            const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(i), u(1))), u(0));
            k.ifp(r(odd));
            k.set(acc, .imad, r(i), u(3), r(acc));
            k.els();
            k.set(acc, .xor, r(acc), r(k.op2(.shl, .u32, r(i), u(4))), no);
            // (a nested if with a long body: branched)
            const big = k.cmp(.u32, .gt, r(y), u(0x8000_0000));
            k.ifp(r(big));
            var z = k.op2(.imul, .u32, r(acc), r(y));
            for (0..8) |j| z = k.op2(.iadd, .u32, r(z), r(k.op2(.shr, .u32, r(z), u(@intCast(j + 1)))));
            k.set(acc, .mov, r(z), no, no);
            k.endif();
            k.endif();
            const skip = k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(i), u(3))), u(2));
            k.cont(r(skip));
            k.set(acc, .iadd, r(acc), u(100), no);
        }
        k.endloop();
        // nested loops, the inner one's trip count by lane
        const s = k.mov(.u32, u(0));
        const a = k.mov(.u32, u(0));
        k.loop();
        {
            const b = k.mov(.u32, u(0));
            k.loop();
            {
                k.set(s, .iadd, r(s), r(k.op2(.imul, .u32, r(a), r(b))), no);
                k.set(b, .iadd, r(b), u(1), no);
                k.brk(r(k.cmp(.u32, .gt, r(b), r(k.op2(.@"and", .u32, r(y), u(7))))));
            }
            k.endloop();
            k.set(a, .iadd, r(a), u(1), no);
            k.brk(r(k.cmp(.u32, .ge, r(a), u(4))));
        }
        k.endloop();
        const ob = k.op2(.shl, .u32, r(t), u(3));
        k.store(.u32, kir.global(O, 32), r(ob), r(acc));
        var m = kir.global(O, 32);
        m.imm = 4;
        k.store(.u32, m, r(ob), r(s));
        // an early return for some lanes after their first store
        const early = k.cmp(.u32, .lt, r(k.op2(.@"and", .u32, r(x), u(0xff))), u(0x40));
        k.ifp(r(early));
        k.ret();
        k.endif();
        // (a float tail: some ifs on float compares)
        const f = k.cvt(.u32, .f32, .rne, r(acc));
        const g = k.op2(.fmul, .f32, r(f), kir.f(0.5));
        const fp = k.cmp(.f32, .lt, r(g), kir.f(1000.0));
        const h = k.sel(.f32, r(fp), r(g), r(k.op1(.fneg, .f32, r(g))));
        m.imm = 4;
        k.store(.f32, m, r(ob), r(h));
        try same(caps, &k, .{ 2, 1, 1 }, &.{}, 2 * NT, null);
    }
}

test "ids, parameters and predicates past the six registers" {
    const caps = caseCaps(false);
    fillInts(0x1d5);
    {
        var k = newKernel("ids", .{ 8, 4, 2 });
        _ = k.binding();
        _ = k.binding();
        _ = k.binding();
        const O = k.binding();
        const tx = k.tid(0);
        const ty = k.tid(1);
        const tz = k.tid(2);
        const lin3 = k.op3(.imad, .u32, r(tz), u(32), r(k.op3(.imad, .u32, r(ty), u(8), r(tx))));
        const g = k.op3(.imad, .u32, r(k.gid(1)), u(2), r(k.gid(0)));
        const t = k.op3(.imad, .u32, r(g), u(64), r(lin3));
        const ob = k.op2(.shl, .u32, r(t), u(5));
        const vals = [_]kir.V{ tx, ty, tz, k.gid(0), k.gid(1), k.op3(.imad, .u32, r(k.gsize(1)), u(16), r(k.gsize(0))), k.op2(.iadd, .u32, r(k.lane()), r(k.op2(.shl, .u32, r(k.subgroupWidth()), u(8)))), k.op2(.xor, .u32, r(k.param(.u32, 0)), r(k.param(.u32, 1))) };
        for (vals, 0..) |v, j| {
            var m = kir.global(O, 32);
            m.imm = @intCast(4 * j);
            k.store(.u32, m, r(ob), r(v));
        }
        // (2 x 2 groups of 64: 256 threads, 8 words each)
        try same(caps, &k, .{ 2, 2, 1 }, &.{ 0x1234, 0xff00 }, 16 * NT, null);
    }
    {
        // ten predicates live at once: four of them in registers
        var k = newKernel("preds", .{ 64, 1, 1 });
        const A = k.binding();
        _ = k.binding();
        _ = k.binding();
        const O = k.binding();
        const t = lin(&k);
        const off = k.op2(.shl, .u32, r(t), u(2));
        const x = k.load(.u32, kir.global(A, 32), r(off));
        var p: [10]kir.V = undefined;
        for (&p, 0..) |*q, j| q.* = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(x), u(@as(u32, 1) << @intCast(j)))), u(0));
        var acc = k.mov(.u32, u(0));
        for (p, 0..) |q, j| acc = k.sel(.u32, r(q), r(k.op2(.iadd, .u32, r(acc), u(@intCast(j * j + 1)))), r(acc));
        var pp = p[0];
        for (p[1..]) |q| pp = k.op2(if (@intFromEnum(q) % 2 == 0) .pand else .por, .pred, r(pp), r(q));
        acc = k.op2(.iadd, .u32, r(acc), r(k.sel(.u32, r(pp), u(0x1000), u(0))));
        // (and the predicates read again, in reverse, after all are made)
        for (0..10) |j| acc = k.op2(.xor, .u32, r(acc), r(k.sel(.u32, r(p[9 - j]), u(@as(u32, 1) << @intCast(16 + j)), u(0))));
        k.store(.u32, kir.global(O, 32), r(off), r(acc));
        try same(caps, &k, .{ 2, 1, 1 }, &.{}, NT, null);
        try testing.expect(T.st.stats.spills > 0);
    }
}

test "fneg and fabs: source modifiers where the op takes them (FADD, FMNMX, FSETP, F2I), instructions where not (FMUL, FFMA)" {
    for ([_]bool{ false, true }) |flush| {
        const caps = caseCaps(flush);
        fillFloats(0xab5);
        var k = newKernel("modifiers", .{ 64, 1, 1 });
        const A = k.binding();
        const Bb = k.binding();
        const C = k.binding();
        const O = k.binding();
        const t = lin(&k);
        const off = k.op2(.shl, .u32, r(t), u(2));
        const x = k.load(.f32, kir.global(A, 32), r(off));
        const y = k.load(.f32, kir.global(Bb, 32), r(off));
        const z = k.load(.f32, kir.global(C, 32), r(off));
        const ax = k.op1(.fabs, .f32, r(x));
        const ny = k.op1(.fneg, .f32, r(y));
        const az = k.op1(.fabs, .f32, r(z));
        const nax = k.op1(.fneg, .f32, r(ax));
        const vals = [_]kir.V{
            k.op2(.fmul, .f32, r(ax), r(ny)),
            k.op3(.ffma, .f32, r(ax), r(ny), r(az)),
            k.op3(.fmad, .f32, r(ny), kir.f(1.25), r(az)),
            k.op2(.fadd, .f32, r(ax), r(ny)),
            k.op2(.fsub, .f32, r(nax), r(az)),
            k.op2(.fmax, .f32, r(ax), r(ny)),
            k.sel(.f32, r(k.cmp(.f32, .lt, r(ax), r(ny))), r(az), r(nax)),
            k.cvt(.f32, .i32, .rz, r(nax)),
        };
        const ob = k.op2(.shl, .u32, r(t), u(5));
        for (vals, 0..) |v, j| {
            var m = kir.global(O, 32);
            m.imm = @intCast(4 * j);
            k.store(if (j == 7) .i32 else .f32, m, r(ob), r(v));
        }
        var got: [16 * NT * 4]u8 align(4) = undefined;
        try runBoth(caps, &k, .{ 2, 1, 1 }, &.{}, 8 * NT * 4, &got, .{});
        const g32: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, got[0 .. 8 * NT * 4]));
        for (0..8 * NT) |i| {
            if (X.ref[i] != g32[i] and !(isNan32(X.ref[i]) and isNan32(g32[i]) and i % 8 != 7)) {
                std.debug.print("modifiers word {d}: interp {x}, RTX {x}\n", .{ i, X.ref[i], g32[i] });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ── A frame-kernel piece, rewritten in KIR ──────────────────────────────────
//
// Galaxy's sdRoundRect then blendOver (galaxy/ui/gfx_kernels.sig's sdRR and
// blendOver: the sm_120 text its emitter makes for them, between the
// piece's comments below), in a harness: thread t reads px, py (f32), p, c,
// al (u32) from in[8t..], the rounded rect's record (gfx_kernels.Sd: cx,
// cy, kx, ky, rad) from rec, and writes the blended pixel to out[t] and the
// distance to out[64 + t]. The KIR version does the same maths op for op,
// with KIR's fsqrt (sm_120's sqrt.rn, the hand text's root) and an if/else
// for blendOver.

/// The hand text: the harness (16 instructions: S2R, LDCU, MOV of mul255's
/// rounding, 3 LDC.64, 2 IMAD.WIDE, 5 LDG, 2 STG, EXIT) around the piece.
const HAND_PIECE =
    \\.params 24
    \\S2R R0, SR_TID.X
    \\LDCU.64 UR4, c[0x0][0x358]
    \\MOV R1, 0x800080
    \\LDC.64 R2, c[0x0][0x380]
    \\LDC.64 R4, c[0x0][0x388]
    \\LDC.64 R6, c[0x0][0x390]
    \\IMAD.WIDE.U32 R2, R0, 0x20, R2
    \\IMAD.WIDE.U32 R6, R0, 0x4, R6
    \\LDG.E R8, desc[UR4][R2.64]
    \\LDG.E R9, desc[UR4][R2.64+0x4]
    \\LDG.E R10, desc[UR4][R2.64+0x8]
    \\LDG.E R11, desc[UR4][R2.64+0xc]
    \\LDG.E R12, desc[UR4][R2.64+0x10]
    \\// piece
    \\LDG.E.CONSTANT R16, desc[UR4][R4.64]
    \\FADD R14, R8, -R16
    \\LDG.E.CONSTANT R16, desc[UR4][R4.64+0x8]
    \\FADD R14, |R14|, -R16
    \\LDG.E.CONSTANT R16, desc[UR4][R4.64+0x4]
    \\FADD R15, R9, -R16
    \\LDG.E.CONSTANT R16, desc[UR4][R4.64+0xc]
    \\FADD R15, |R15|, -R16
    \\FMNMX R17, R14, RZ, !PT
    \\FMNMX R18, R15, RZ, !PT
    \\FMUL R17, R17, R17
    \\FMUL R18, R18, R18
    \\FADD R17, R17, R18
    \\IADD R19, R17, -0xd000000
    \\ISETP.GT.U32.AND P0, PT, R19, 0x727fffff, PT
    \\@P0 BRA `(L2)
    \\MUFU.RSQ R19, R17
    \\FMUL R20, R17, R19
    \\FMUL R19, R19, 0.5
    \\FFMA R18, -R20, R20, R17
    \\FFMA R18, R18, R19, R20
    \\BRA `(L1)
    \\L2:
    \\ISETP.GE.U32.AND P0, PT, R17, 0xd000000, PT
    \\@P0 BRA `(L3)
    \\ISETP.EQ.U32.AND P0, PT, R17, RZ, PT
    \\@P0 MOV R18, RZ
    \\@P0 BRA `(L1)
    \\FMUL R21, R17, 18446744073709552000
    \\MUFU.RSQ R19, R21
    \\FMUL R20, R21, R19
    \\FMUL R19, R19, 0.5
    \\FFMA R18, -R20, R20, R21
    \\FFMA R18, R18, R19, R20
    \\FMUL R18, R18, 0.00000000023283064365386963
    \\BRA `(L1)
    \\L3:
    \\MUFU.SQRT R18, R17
    \\L1:
    \\FMNMX R14, R14, R15, !PT
    \\FMNMX R14, R14, RZ, PT
    \\FADD R18, R18, R14
    \\LDG.E.CONSTANT R16, desc[UR4][R4.64+0x10]
    \\FADD R13, R18, -R16
    \\ISETP.GE.U32.AND P0, PT, R12, 0xff, PT
    \\@P0 LOP3.LUT R10, R11, 0xff000000, RZ, 0xfc, !PT
    \\@P0 BRA `(L4)
    \\IADD R14, -R12, 0xff
    \\LOP3.LUT R15, R11, 0xff00ff, RZ, 0xc0, !PT
    \\IMAD R18, R15, R12, R1
    \\SHF.R.U32.HI R19, RZ, 0x8, R18
    \\LOP3.LUT R19, R19, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R18, R18, R19
    \\SHF.R.U32.HI R15, RZ, 0x8, R18
    \\LOP3.LUT R15, R15, 0xff00ff, RZ, 0xc0, !PT
    \\LOP3.LUT R16, R10, 0xff00ff, RZ, 0xc0, !PT
    \\IMAD R18, R16, R14, R1
    \\SHF.R.U32.HI R19, RZ, 0x8, R18
    \\LOP3.LUT R19, R19, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R18, R18, R19
    \\SHF.R.U32.HI R16, RZ, 0x8, R18
    \\LOP3.LUT R16, R16, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R17, R15, R16
    \\SHF.R.U32.HI R15, RZ, 0x8, R11
    \\LOP3.LUT R15, R15, 0xff00ff, RZ, 0xc0, !PT
    \\IMAD R18, R15, R12, R1
    \\SHF.R.U32.HI R19, RZ, 0x8, R18
    \\LOP3.LUT R19, R19, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R18, R18, R19
    \\SHF.R.U32.HI R15, RZ, 0x8, R18
    \\LOP3.LUT R15, R15, 0xff00ff, RZ, 0xc0, !PT
    \\SHF.R.U32.HI R16, RZ, 0x8, R10
    \\LOP3.LUT R16, R16, 0xff00ff, RZ, 0xc0, !PT
    \\IMAD R18, R16, R14, R1
    \\SHF.R.U32.HI R19, RZ, 0x8, R18
    \\LOP3.LUT R19, R19, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R18, R18, R19
    \\SHF.R.U32.HI R16, RZ, 0x8, R18
    \\LOP3.LUT R16, R16, 0xff00ff, RZ, 0xc0, !PT
    \\IADD R15, R15, R16
    \\LOP3.LUT R15, R15, 0xff, RZ, 0xc0, !PT
    \\SHF.L.U32 R15, R15, 0x8, RZ
    \\LOP3.LUT R10, R17, 0xff000000, R15, 0xfe, !PT
    \\L4:
    \\// end
    \\STG.E desc[UR4][R6.64], R10
    \\STG.E desc[UR4][R6.64+0x100], R13
    \\EXIT
;
const HAND_HARNESS = 16;
/// The KIR harness's: S2R, LDCU, 3 LDC.64, 2 IMAD.WIDE, 5 LDG, 2 STG, EXIT.
const KIR_HARNESS = 15;

fn mulLanes(k: *kir.Kernel, x: kir.V, y: kir.V) kir.V {
    const t = k.op3(.imad, .u32, r(x), r(y), u(0x0080_0080));
    const s = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(t), u(8))), u(0x00ff_00ff));
    const t2 = k.op2(.iadd, .u32, r(t), r(s));
    return k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(t2), u(8))), u(0x00ff_00ff));
}

fn recField(k: *kir.Kernel, rec: u8, off: u32) kir.V {
    var m = kir.global(rec, 32);
    m.imm = @intCast(off);
    return k.load(.f32, m, u(0));
}

fn pieceKir(k: *kir.Kernel) void {
    const IN = k.binding();
    const REC = k.binding();
    const OUT = k.binding();
    const t = k.tid(0);
    const io = k.op2(.shl, .u32, r(t), u(5));
    var m = kir.global(IN, 32);
    const px = k.load(.f32, m, r(io));
    m.imm = 4;
    const py = k.load(.f32, m, r(io));
    m.imm = 8;
    const p = k.load(.u32, m, r(io));
    m.imm = 12;
    const c = k.load(.u32, m, r(io));
    m.imm = 16;
    const al = k.load(.u32, m, r(io));
    // sdRoundRect: sqrt(max(qx,0)^2 + max(qy,0)^2) + min(max(qx,qy),0) - rad
    const qx = k.op2(.fsub, .f32, r(k.op1(.fabs, .f32, r(k.op2(.fsub, .f32, r(px), r(recField(k, REC, 0)))))), r(recField(k, REC, 8)));
    const qy = k.op2(.fsub, .f32, r(k.op1(.fabs, .f32, r(k.op2(.fsub, .f32, r(py), r(recField(k, REC, 4)))))), r(recField(k, REC, 12)));
    const ox = k.op2(.fmax, .f32, r(qx), kir.f(0));
    const oy = k.op2(.fmax, .f32, r(qy), kir.f(0));
    const ss = k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(ox), r(ox))), r(k.op2(.fmul, .f32, r(oy), r(oy))));
    const root = k.sqrt(r(ss));
    const mn = k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, r(qx), r(qy))), kir.f(0));
    const d = k.op2(.fsub, .f32, r(k.op2(.fadd, .f32, r(root), r(mn))), r(recField(k, REC, 16)));
    // blendOver(p, c, al)
    k.ifp(r(k.cmp(.u32, .ge, r(al), u(0xff))));
    k.set(p, .@"or", r(c), u(0xff00_0000), no);
    k.els();
    {
        const inv = k.op2(.isub, .u32, u(0xff), r(al));
        const x = mulLanes(k, k.op2(.@"and", .u32, r(c), u(0x00ff_00ff)), al);
        const y = mulLanes(k, k.op2(.@"and", .u32, r(p), u(0x00ff_00ff)), inv);
        const rb = k.op2(.iadd, .u32, r(x), r(y));
        const x2 = mulLanes(k, k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(c), u(8))), u(0x00ff_00ff)), al);
        const y2 = mulLanes(k, k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(p), u(8))), u(0x00ff_00ff)), inv);
        const g = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(x2), r(y2))), u(0xff))), u(8));
        k.set(p, .@"or", r(k.op2(.@"or", .u32, r(rb), u(0xff00_0000))), r(g), no);
    }
    k.endif();
    const oo = k.op2(.shl, .u32, r(t), u(2));
    k.store(.u32, kir.global(OUT, 32), r(oo), r(p));
    var mo = kir.global(OUT, 32);
    mo.imm = 0x100;
    k.store(.f32, mo, r(oo), r(d));
}

test "sdRoundRect + blendOver in KIR: the hand text's bits, within 10% of its instructions" {
    const d = freshEmu();
    var k = newKernel("sd_blend", .{ 64, 1, 1 });
    pieceKir(&k);
    try k.finish();
    const bin = try kir_sm120.compileIn(&k, d.caps, &T.st, &T.code, .{});
    const kir_count = bin.extra[kir_sm120.EXTRA_INSTRUCTIONS];
    const kir_regs = bin.regs;
    const prog = try d.load(&bin);
    const hbin = try handBinary(HAND_PIECE, .{ 64, 1, 1 }, 0, 3, 0);
    const hand = try d.load(&hbin);
    const in = try d.alloc(64 * 32, .upload);
    const rec = try d.alloc(64, .upload);
    const out1 = try d.alloc(128 * 4, .host);
    const out2 = try d.alloc(128 * 4, .host);
    var s: u32 = 0x5d;
    const w = words32(in);
    for (0..64) |t| {
        // (pixels around and inside a 30 x 20 rect at (10, 12), radius 6;
        // alphas across 0..300: some opaque)
        w[8 * t + 0] = @bitCast(@as(f32, @floatFromInt(lcg(&s) % 640)) / 10.0 + 0.5);
        w[8 * t + 1] = @bitCast(@as(f32, @floatFromInt(lcg(&s) % 520)) / 10.0 + 0.5);
        w[8 * t + 2] = lcg(&s);
        w[8 * t + 3] = lcg(&s);
        w[8 * t + 4] = if (t % 9 == 0) 255 else lcg(&s) % 300;
    }
    // (gfx_kernels.sdOf for the rect: cx, cy, kx, ky, rad)
    const recf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, rec.cpu[0..20]));
    recf[0] = 10 + 15;
    recf[1] = 12 + 10;
    recf[2] = 15 - 6;
    recf[3] = 10 - 6;
    recf[4] = 6;
    d.toDevice(in, 0, in.bytes);
    d.toDevice(rec, 0, rec.bytes);
    const hs = try runCounted(d, .{ .prog = &hand, .groups = .{ 1, 1, 1 }, .buffers = &.{ in, rec, out1 }, .params = &.{} });
    const ksx = try runCounted(d, .{ .prog = &prog, .groups = .{ 1, 1, 1 }, .buffers = &.{ in, rec, out2 }, .params = &.{} });
    std.debug.print("sdRoundRect + blendOver emulated: KIR {d} warp instructions, {d} cycles; hand {d}, {d}\n", .{ ksx.instructions, ksx.cycles, hs.instructions, hs.cycles });
    d.fromDevice(out1, 0, out1.bytes);
    d.fromDevice(out2, 0, out2.bytes);
    try testing.expectEqualSlices(u32, words32(out1), words32(out2));
    const hand_count = hbin.extra[kir_sm120.EXTRA_INSTRUCTIONS];
    const hp = hand_count - HAND_HARNESS;
    const kp = kir_count - KIR_HARNESS;
    std.debug.print("sdRoundRect + blendOver: KIR {d} instructions ({d} the piece), {d} registers; hand {d} ({d} the piece), {d} registers\n", .{ kir_count, kp, kir_regs, hand_count, hp, hbin.regs });
    try testing.expect(kp * 10 <= hp * 11);
}
