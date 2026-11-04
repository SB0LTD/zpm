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
const kir_sm120 = @import("kir_sm120.sig");
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
            if (i > 0) {
                p.method(push.SUBCH_COMPUTE, WAIT_FOR_IDLE, &.{0});
                p.invalidateShaderCaches();
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

    pub fn init(e: *Emu, arena: []u8, gpu_view: []u8, work: *emu.Work) void {
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
    const text = try kir_sm120.compileText(&k, d.caps, &T.st);
    const bin = kir_sm120.compileIn(&k, d.caps, &T.st, &T.code) catch |e| {
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
    try runWait(d, &.{
        .{ .prog = &hand, .groups = shape.grid, .buffers = &.{ w, aq, ad, as, out1 }, .params = &params },
        .{ .prog = &prog, .groups = shape.grid, .buffers = &.{ w, aq, ad, as, out2 }, .params = &params },
    });
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
