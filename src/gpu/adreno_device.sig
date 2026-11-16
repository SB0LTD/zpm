//! @zpm/gpu adreno_device — an Adreno (a7xx) as a gpu.Device.
//!
//! `over` wraps the adreno module's raw Device (Galaxy's driver, or the
//! emulated GPU) so nothing below it changes: buffers are the raw device's
//! (unified memory: every kind is the same system memory, with a CPU view);
//! a Program is a Binary from kir_ir3 copied into a code buffer; `run`
//! builds one A7xx PM4 stream for all its dispatches, as selftest.sig and
//! lfm3_gpu.sig do: the compute setup once, then per dispatch the program
//! (CP_LOAD_STATE6 of the code), the constants in one direct load from c0
//! (binding addresses, parameters and group counts, then the kernel's
//! constant pool: never loaded by the CP from memory, which the Surface's
//! Adreno got wrong), CP_EXEC_CS and a wait for idle, so each
//! dispatch sees the one before's writes; the always-on counter before and
//! after; a cache clean at the end. One submit, one fence. With `overlap`,
//! a dispatch waits only where gpu.Hazards says it reads what those since
//! the last wait write, or writes what they use (as the RTX's adapter), so
//! independent dispatches run together.
//!
//! `Emu` is the same over the adreno module's EmuDevice: the stream is read
//! as the command processor would and each dispatch runs in ir3_emu, with
//! the GPU's memory apart from the CPU's (a missing toDevice or fromDevice
//! gives wrong results here too).
//!
//! Allocation-free: the adapter's state is the caller's (Over, Emu); the
//! command stream and timestamps live in buffers of the raw device.

const std = @import("std");
const kir = @import("kir.sig");
const dv = @import("device.sig");
const kir_ir3 = @import("kir_ir3.sig");
const adreno = @import("adreno");
const a7xx = adreno.a7xx;
const raw = adreno.device;

const Caps = dv.Caps;
const Buffer = dv.Buffer;
const Kind = dv.Kind;
const Binary = dv.Binary;
const Program = dv.Program;
const Dispatch = dv.Dispatch;
const Error = dv.Error;
const Fence = dv.Fence;

/// Bytes of command stream one run may use.
pub const STREAM_BYTES = 256 * 1024;
/// Runs in flight at once (a command stream each).
pub const STREAMS = 4;
/// How long a run waits for its stream's last run (µs): longer than the
/// kernel takes to call a GPU that stopped moving hung (15 s), which ends
/// the wait sooner with DeviceLost.
pub const REUSE_WAIT_US: u64 = 20_000_000;
/// The most groups along one axis (the Adreno's limit; KIR's gid bounds).
pub const MAX_GROUPS = 65535;

/// The Surface Laptop 13's X1-45. The hardware probes measured unfused
/// multiply-add and flush-to-zero for f32 arithmetic.
pub fn x1_45_caps(device_bytes: u64) Caps {
    return .{
        .vendor = .qualcomm,
        .target = .ir3_a7xx,
        .name = "Adreno X1-45",
        .memory = .unified,
        .coherent = false,
        .device_bytes = device_bytes,
        .subgroup = 64,
        .max_group = 1024,
        .shared_bytes = 32 * 1024,
        .fused_fma = false,
        .mad = .unfused,
        .denormals = .flush,
        .dot4 = true,
        .import = false,
        .timestamp_hz = 19_200_000,
    };
}

/// The instruction emulator preserves f32 subnormals.
pub fn emuCaps(device_bytes: u64) Caps {
    var caps = x1_45_caps(device_bytes);
    caps.denormals = .preserve;
    return caps;
}

/// The raw device's buffer (what an Importer hands back).
pub const RawBuffer = raw.Buffer;

/// Memory the CPU side lends the GPU in place (zero-copy import): on the
/// Surface, Galaxy's galaxy_gpu_drm.kernelImport and kernelFree in the
/// context the raw device submits in. `import` maps `cpu` for the GPU
/// (its .va the GPU's address of cpu[0], its .handle what `release` gives
/// back); `writable` false maps it read only.
pub const Importer = struct {
    ctx: *anyopaque,
    import: *const fn (ctx: *anyopaque, cpu: []u8, writable: bool) ?raw.Buffer,
    release: *const fn (ctx: *anyopaque, handle: u32) void,
};

/// Imports one adapter keeps at once.
pub const MAX_IMPORTS = 64;

/// A gpu.Device over a raw adreno Device.
pub const Over = struct {
    raw: raw.Device,
    caps: Caps,
    /// With one, caps.import: Device.import maps CPU memory in place.
    importer: ?Importer = null,
    /// The handles of the buffers imported and not freed.
    imported: [MAX_IMPORTS]u32 = undefined,
    n_imported: usize = 0,
    /// The command streams (STREAMS: runs in flight at once), and the
    /// timestamps: two words a stream.
    ibs: [STREAMS]?raw.Buffer = .{null} ** STREAMS,
    ts: ?raw.Buffer = null,
    /// Runs submitted (the last one's Fence).
    fence: Fence = 0,
    /// Each stream's last run.
    raw_fences: [STREAMS]raw.Fence = .{0} ** STREAMS,
    /// GPU time of the last run (ns), once waited for.
    last_ns: u64 = 0,
    timed: bool = false,
    consts: [1024]u32 = undefined,
    /// Waits only where the data needs them (gpu.Hazards); false: after
    /// every dispatch.
    overlap: bool = false,
    /// The waits between dispatches in the last run.
    barriers: u32 = 0,

    pub fn init(r: raw.Device, caps: Caps) Over {
        var c = caps;
        c.memory = .unified;
        c.import = false;
        c.timestamp_hz = r.timestamp_hz;
        return .{ .raw = r, .caps = c };
    }

    /// init, with zero-copy import through `importer` (caps.import).
    pub fn initWith(r: raw.Device, caps: Caps, importer: Importer) Over {
        var o = init(r, caps);
        o.setImporter(importer);
        return o;
    }

    pub fn setImporter(o: *Over, importer: Importer) void {
        o.importer = importer;
        o.caps.import = true;
    }

    pub fn device(o: *Over) dv.Device {
        return .{ .ctx = o, .vtable = &vtable, .caps = o.caps };
    }

    const vtable = dv.Device.VTable{
        .alloc = alloc,
        .free = free,
        .import = import,
        .toDevice = toDevice,
        .fromDevice = fromDevice,
        .load = load,
        .unload = unload,
        .run = run,
        .wait = wait,
        .done = done,
        .lastRunNs = lastRunNs,
        .timestampNs = timestampNs,
    };

    fn self(ctx: *anyopaque) *Over {
        return @ptrCast(@alignCast(ctx));
    }

    fn rawOf(b: Buffer) raw.Buffer {
        return .{ .va = b.gpu, .cpu = b.cpu, .handle = b.handle };
    }

    fn alloc(ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer {
        const o = self(ctx);
        if (bytes == 0 or bytes > std.math.maxInt(usize)) return null;
        const b = o.raw.vtable.alloc(o.raw.ctx, @intCast(bytes)) orelse return null;
        return .{ .gpu = b.va, .cpu = b.cpu, .bytes = bytes, .handle = b.handle, .kind = kind };
    }

    fn free(ctx: *anyopaque, b: Buffer) void {
        const o = self(ctx);
        // (an import goes back to its importer, not the raw device)
        for (o.imported[0..o.n_imported], 0..) |h, i| {
            if (h != b.handle) continue;
            o.imported[i] = o.imported[o.n_imported - 1];
            o.n_imported -= 1;
            if (o.importer) |imp| imp.release(imp.ctx, h);
            return;
        }
        o.raw.free(rawOf(b));
    }

    /// `cpu` read by the GPU in place (read only: what the device's users
    /// import, images and model files, they only read); null without an
    /// importer, when it refuses, or with MAX_IMPORTS held.
    fn import(ctx: *anyopaque, cpu: []u8) ?Buffer {
        const o = self(ctx);
        const imp = o.importer orelse return null;
        if (cpu.len == 0 or o.n_imported == MAX_IMPORTS) return null;
        const b = imp.import(imp.ctx, cpu, false) orelse return null;
        o.imported[o.n_imported] = b.handle;
        o.n_imported += 1;
        return .{ .gpu = b.va, .cpu = cpu, .bytes = cpu.len, .handle = b.handle, .kind = .host };
    }

    fn toDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        const o = self(ctx);
        if (len == 0) return;
        o.raw.toDevice(rawOf(b), @intCast(off), @intCast(len));
    }

    fn fromDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        const o = self(ctx);
        if (len == 0) return;
        o.raw.fromDevice(rawOf(b), @intCast(off), @intCast(len));
    }

    fn load(ctx: *anyopaque, bin: *const Binary) Error!Program {
        const o = self(ctx);
        if (bin.target != .ir3_a7xx) return error.BadProgram;
        const cfg = kir_ir3.Config.fromExtra(bin.extra) orelse return error.BadProgram;
        if (cfg.code_bytes == 0 or cfg.code_bytes > bin.code.len) return error.BadProgram;
        // A group whose waves cannot all be resident with this footprint
        // does not launch (Mesa's a7xx formula): refused here, not hung.
        const threads = bin.group[0] * bin.group[1] * bin.group[2];
        if (!adreno.ir3_emu.groupFits(cfg.gen, cfg.full_regs, cfg.threadsize, threads)) return error.BadProgram;
        // (SP_CS_BASE: 128-byte aligned; the raw devices hand out pages)
        const b = o.raw.vtable.alloc(o.raw.ctx, std.mem.alignForward(usize, bin.code.len, 128)) orelse return error.OutOfMemory;
        if (b.va & 127 != 0) {
            o.raw.free(b);
            return error.OutOfMemory;
        }
        @memcpy(b.cpu[0..bin.code.len], bin.code);
        o.raw.toDevice(b, 0, bin.code.len);
        return .{ .bin = bin.*, .code = .{ .gpu = b.va, .cpu = b.cpu, .bytes = b.cpu.len, .handle = b.handle, .kind = .device } };
    }

    fn unload(ctx: *anyopaque, p: *const Program) void {
        const o = self(ctx);
        o.raw.free(rawOf(p.code));
    }

    /// Every constant of a dispatch, for one direct load from c0: binding
    /// addresses, parameters and group counts, then the kernel's pool (from
    /// the program's copy of its code, where load put it). The Surface's
    /// X1-45 (11-06, the self-test's first case): with the pool loaded by
    /// the CP from memory into c2.., the kernel's first load read its
    /// binding address from c0.z:c0.w as 0xc000_0000_ffff, the pool's
    /// third and fourth words (a fault at 0xc000_0000_ffc0), while
    /// Galaxy's hand-written kernels, their constants all direct from c0,
    /// pass. So nothing is loaded from memory into the constants.
    fn constantsWithPool(cfg: kir_ir3.Config, buffers: []const u64, params: []const u32, groups: [3]u32, code: []const u8, out: []u32) Error![]u32 {
        if (cfg.pool_words == 0) return cfg.constants(buffers, params, groups, out);
        const n = @as(usize, cfg.pool) + cfg.pool_words;
        if (n > out.len or cfg.pool_offset + 4 * @as(usize, cfg.pool_words) > code.len) return error.Unsupported;
        _ = cfg.constants(buffers, params, groups, out);
        for (0..cfg.pool_words) |i| out[cfg.pool + i] = std.mem.readInt(u32, code[cfg.pool_offset + 4 * i ..][0..4], .little);
        return out[0..n];
    }

    fn ensureBuffers(o: *Over, slot: usize) Error!void {
        if (o.ibs[slot] == null) o.ibs[slot] = o.raw.vtable.alloc(o.raw.ctx, STREAM_BYTES) orelse return error.OutOfMemory;
        if (o.ts == null) o.ts = o.raw.vtable.alloc(o.raw.ctx, 4096) orelse return error.OutOfMemory;
    }

    /// Run `f`'s stream (its timestamps at ts + 16 x the stream).
    fn slotOf(f: Fence) usize {
        return @intCast((f - 1) % STREAMS);
    }

    /// The PM4 stream of `ds` into `s`.
    fn build(o: *Over, s: *a7xx.Stream, ds: []const Dispatch, ts_va: u64) Error!void {
        s.computeSetup();
        s.timestamp(ts_va);
        var hz = dv.Hazards{};
        o.barriers = 0;
        for (ds, 0..) |*d, at| {
            // (each dispatch sees the writes of those it depends on: all
            // before it, or with `overlap` those gpu.Hazards names)
            const needs = hz.barrierBefore(d);
            if (at > 0 and (needs or !o.overlap)) {
                s.waitForIdle();
                o.barriers += 1;
            }
            const bin = &d.prog.bin;
            if (bin.target != .ir3_a7xx) return error.BadProgram;
            const cfg = kir_ir3.Config.fromExtra(bin.extra) orelse return error.BadProgram;
            if (d.buffers.len != bin.bindings or d.params.len < bin.param_words) return error.BadProgram;
            for (d.groups) |g| if (g == 0 or g > MAX_GROUPS) return error.Unsupported;
            const k = cfg.kernel(bin, &.{});
            s.program(&k, d.prog.code.gpu) catch return error.BadProgram;
            var addrs: [64]u64 = undefined;
            if (d.buffers.len > addrs.len) return error.Unsupported;
            for (d.buffers, 0..) |b, i| addrs[i] = b.gpu;
            const words = try constantsWithPool(cfg, addrs[0..d.buffers.len], d.params[0..bin.param_words], d.groups, d.prog.code.cpu, &o.consts);
            s.constants(0, words);
            s.dispatch(&k, d.groups);
        }
        s.waitForIdle();
        s.timestamp(ts_va + 8);
        s.cleanCaches();
        s.waitForIdle();
        s.check() catch return error.Unsupported;
    }

    /// A run takes the next of the STREAMS command streams. The run that had
    /// it last must be done before it is written again (the GPU runs them
    /// in order): waited for, as long as a hang takes to be called one.
    /// The Surface's 11-09 boots: with one stream, polled (a wait of 0)
    /// before each run, an app's second batch while its first still ran
    /// failed with Timeout and Galaxy's GL called the GPU lost (Firefox's
    /// first WebRender frames, 3.5 s into its life).
    fn run(ctx: *anyopaque, ds: []const Dispatch) Error!Fence {
        const o = self(ctx);
        const next = o.fence + 1;
        const slot = slotOf(next);
        if (next > STREAMS) o.raw.wait(o.raw_fences[slot], REUSE_WAIT_US) catch |e| return mapError(e);
        try o.ensureBuffers(slot);
        const ib = o.ibs[slot].?;
        const ts = o.ts.?;
        var s = a7xx.Stream{ .buf = ib.words() };
        try o.build(&s, ds, ts.va + 16 * slot);
        o.raw.toDevice(ib, 0, s.len * 4);
        o.raw_fences[slot] = o.raw.submit(ib, @intCast(s.len)) catch |e| return mapError(e);
        o.fence = next;
        o.timed = false;
        return o.fence;
    }

    fn wait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        const o = self(ctx);
        if (f > o.fence) return error.BadProgram;
        // (a run whose stream was taken again was waited for then)
        if (f == 0 or o.fence - f >= STREAMS) return;
        o.raw.wait(o.raw_fences[slotOf(f)], timeout_us) catch |e| return mapError(e);
        if (f == o.fence) o.noteTime();
    }

    fn done(ctx: *anyopaque, f: Fence) bool {
        const o = self(ctx);
        if (f > o.fence) return false;
        if (f == 0 or o.fence - f >= STREAMS) return true;
        o.raw.wait(o.raw_fences[slotOf(f)], 0) catch return false;
        if (f == o.fence) o.noteTime();
        return true;
    }

    fn noteTime(o: *Over) void {
        if (o.timed or o.fence == 0) return;
        o.timed = true;
        const ts = o.ts orelse return;
        const at = 16 * slotOf(o.fence);
        o.raw.fromDevice(ts, at, 16);
        const t: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, ts.cpu[at..][0..16]));
        const ticks = t[1] -% t[0];
        const hz = @max(o.raw.timestamp_hz, 1);
        o.last_ns = @intCast(@min(@as(u128, ticks) * 1_000_000_000 / hz, std.math.maxInt(u64)));
    }

    fn lastRunNs(ctx: *anyopaque) u64 {
        return self(ctx).last_ns;
    }

    fn timestampNs(ctx: *anyopaque, timeout_us: u64) Error!u64 {
        const o = self(ctx);
        if (o.raw.timestamp_hz == 0) return error.Unsupported;
        // (a run of its own, its stream's timestamps: run waits for the
        // stream to be free; the CP takes the sample after what runs before)
        const previous_run_ns = o.last_ns;
        defer o.last_ns = previous_run_ns;
        const f = try run(ctx, &.{});
        try wait(ctx, f, timeout_us);
        const ts = o.ts.?;
        const at = 16 * slotOf(f);
        const tick = std.mem.readInt(u64, ts.cpu[at + 8 ..][0..8], .little);
        return @intCast(@min(@as(u128, tick) * 1_000_000_000 / o.raw.timestamp_hz, std.math.maxInt(u64)));
    }

    fn mapError(e: raw.Error) Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.SubmitFailed, error.BadStream => error.SubmitFailed,
            error.Timeout => error.Timeout,
            error.DeviceLost => error.DeviceLost,
        };
    }
};

var the_over: Over = undefined;

/// The Adreno behind `r` as a gpu.Device (one per process: the adapter's
/// state is static; use Over for more).
pub fn over(r: raw.Device, caps: Caps) dv.Device {
    return overWith(r, caps, .{});
}

pub const Options = struct {
    /// Over.overlap: waits only where the data needs them.
    overlap: bool = false,
};

/// over, with options.
pub fn overWith(r: raw.Device, caps: Caps, opts: Options) dv.Device {
    the_over = Over.init(r, caps);
    the_over.overlap = opts.overlap;
    return the_over.device();
}

/// An emulated Adreno: kir_ir3's code run by ir3_emu behind the A7xx
/// command stream, in memory the caller provides. Several MB: keep static.
///
/// Stricter than the hardware's SMMU: each dispatch runs as its own stream
/// with ir3_emu's bounds set to exactly the buffers it was given, so a
/// kernel running past a binding faults even where another buffer follows
/// (error.DeviceLost; `fault()` says where), and local memory past the
/// kernel's share faults too.
pub const Emu = struct {
    gpu: raw.EmuDevice,
    adapter: Over,
    bounds: [64]adreno.ir3_emu.Bound = undefined,
    /// GPU time of the last run, all its dispatches.
    run_ns: u64 = 0,
    /// The operand rule the last refused program broke (load).
    illegal: ?raw.Illegal = null,
    fence: Fence = 0,
    failed: ?Fence = null,

    /// `arena`: buffers (CPU view); `gpu_view` (as long, or empty): the
    /// GPU's own copy, so cache maintenance is checked.
    pub fn init(e: *Emu, arena: []u8, gpu_view: []u8) void {
        e.gpu = .{ .arena = arena, .gpu_view = gpu_view };
        var c = emuCaps(arena.len);
        c.name = "ir3_emu (Adreno X1-45)";
        c.coherent = gpu_view.len == 0;
        // (the strict device: each dispatch's code checked, buffers apart)
        e.gpu.check_operands = true;
        e.adapter = Over.init(e.gpu.device(), c);
        e.illegal = null;
        e.run_ns = 0;
        e.fence = 0;
        e.failed = null;
    }

    pub fn device(e: *Emu) dv.Device {
        return .{ .ctx = e, .vtable = &emu_vtable, .caps = e.adapter.caps };
    }

    /// Where the last fault was (a GPU address, or a local memory offset).
    pub fn fault(e: *const Emu) struct { va: u64, local: bool } {
        return .{ .va = e.gpu.emu.fault_va, .local = e.gpu.emu.fault_local };
    }

    const emu_vtable = dv.Device.VTable{
        .alloc = fwdAlloc,
        .free = fwdFree,
        .import = fwdImport,
        .toDevice = fwdToDevice,
        .fromDevice = fwdFromDevice,
        .load = fwdLoad,
        .unload = fwdUnload,
        .run = emuRun,
        .wait = emuWait,
        .done = emuDone,
        .lastRunNs = emuLastRunNs,
        .timestampNs = emuTimestampNs,
    };

    fn of(ctx: *anyopaque) *Emu {
        return @ptrCast(@alignCast(ctx));
    }

    fn emuTimestampNs(ctx: *anyopaque, timeout_us: u64) Error!u64 {
        return Over.timestampNs(&of(ctx).adapter, timeout_us);
    }
    fn fwdAlloc(ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer {
        return Over.alloc(&of(ctx).adapter, bytes, kind);
    }
    fn fwdFree(ctx: *anyopaque, b: Buffer) void {
        Over.free(&of(ctx).adapter, b);
    }
    fn fwdImport(ctx: *anyopaque, cpu: []u8) ?Buffer {
        return Over.import(&of(ctx).adapter, cpu);
    }
    fn fwdToDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        Over.toDevice(&of(ctx).adapter, b, off, len);
    }
    fn fwdFromDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        Over.fromDevice(&of(ctx).adapter, b, off, len);
    }
    /// Every program's code against ir3's operand rules, its constlen and
    /// footprint (adreno.device.checkWords) before it is loaded; the strict
    /// EmuDevice checks each dispatch's code again when it runs.
    fn fwdLoad(ctx: *anyopaque, bin: *const Binary) Error!Program {
        const e = of(ctx);
        e.illegal = null;
        if (bin.target == .ir3_a7xx) if (kir_ir3.Config.fromExtra(bin.extra)) |cfg| {
            if (cfg.code_bytes > bin.code.len or cfg.code_bytes % 8 != 0) return error.BadProgram;
            const words: []align(1) const u64 = std.mem.bytesAsSlice(u64, bin.code[0..cfg.code_bytes]);
            var pc: u32 = 0;
            while (pc < cfg.count) : (pc += 1) {
                const in = adreno.ir3.decode(cfg.gen, words[pc]) catch {
                    e.illegal = .{ .pc = pc, .rule = "an instruction word that does not decode" };
                    return error.BadProgram;
                };
                if (raw.checkInstr(cfg.gen, &in, pc, cfg.constlen, cfg.full_regs)) |bad| {
                    e.illegal = bad;
                    return error.BadProgram;
                }
            }
        };
        return Over.load(&e.adapter, bin);
    }
    fn fwdUnload(ctx: *anyopaque, p: *const Program) void {
        Over.unload(&of(ctx).adapter, p);
    }

    /// Each dispatch alone, its buffers as the emulator's bounds.
    fn emuRun(ctx: *anyopaque, ds: []const Dispatch) Error!Fence {
        const e = of(ctx);
        e.fence += 1;
        e.run_ns = 0;
        e.failed = null;
        const o = &e.adapter;
        defer {
            e.gpu.emu.bounds = &.{};
            e.gpu.emu.local_limit = adreno.ir3_emu.LOCAL_BYTES;
        }
        for (ds) |*d| {
            if (d.buffers.len > e.bounds.len) return error.Unsupported;
            for (d.buffers, 0..) |b, i| e.bounds[i] = .{ .va = b.gpu, .bytes = b.bytes };
            e.gpu.emu.bounds = e.bounds[0..d.buffers.len];
            e.gpu.emu.local_limit = @max(d.prog.bin.shared_bytes, 0);
            if (kir_ir3.Config.fromExtra(d.prog.bin.extra)) |cfg| e.gpu.emu.local_limit = cfg.shared_bytes;
            const f = try Over.run(o, d[0..1]);
            Over.wait(o, f, 0) catch {
                e.failed = e.fence;
                return e.fence;
            };
            e.run_ns += o.last_ns;
        }
        return e.fence;
    }

    fn emuWait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        _ = timeout_us;
        const e = of(ctx);
        if (f > e.fence) return error.BadProgram;
        if (e.failed != null and e.failed.? == f) return error.DeviceLost;
    }

    fn emuDone(ctx: *anyopaque, f: Fence) bool {
        return f <= of(ctx).fence;
    }

    fn emuLastRunNs(ctx: *anyopaque) u64 {
        return of(ctx).run_ns;
    }

    /// The emulator's counts over every run since init.
    pub fn stats(e: *const Emu) adreno.ir3_emu.Stats {
        return e.gpu.stats;
    }

    pub fn lastError(e: *const Emu) ?anyerror {
        return e.gpu.last_error;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const Rig = struct {
    var arena: [16 << 20]u8 align(4096) = undefined;
    var view: [16 << 20]u8 align(4096) = undefined;
    var emu: Emu = undefined;
    var work: kir_ir3.Work = undefined;
    var out: [512 * 1024]u8 align(16) = undefined;
    var insts: [16384]kir.Inst = undefined;
    var tys: [16384]kir.Ty = undefined;
};

fn newKernel(name: []const u8, group: [3]u32) kir.Kernel {
    return kir.Kernel.init(.{ .insts = &Rig.insts, .tys = &Rig.tys }, name, group);
}

/// Compile and load `k` on the emulated Adreno.
fn loadKernel(d: dv.Device, k: *kir.Kernel) !Program {
    try k.finish();
    const bin = kir_ir3.compileWith(k, d.caps, &Rig.work, &Rig.out) catch |e| {
        std.debug.print("compile {s}: {s}\n{s}\n", .{ k.name, @errorName(e), kir_ir3.source(&Rig.work) });
        return e;
    };
    return d.load(&bin);
}

fn runOne(d: dv.Device, p: *const Program, groups: [3]u32, bufs: []const Buffer, params: []const u32) !void {
    const f = try d.run(&.{.{ .prog = p, .groups = groups, .buffers = bufs, .params = params }});
    d.wait(f, 1_000_000) catch |e| {
        const at = Rig.emu.gpu.emu.err_pc;
        var buf: [160]u8 = undefined;
        const text = adreno.ir3.format(adreno.ir3.A7XX, &Rig.emu.gpu.emu.code[at], &buf) catch "?";
        std.debug.print("emulated Adreno: {s} at {d}: {s}\n", .{ if (Rig.emu.lastError()) |x| @errorName(x) else "?", at, text });
        return e;
    };
}

test "runs one after another without waits: the streams taken in turn, every run's work done" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    var k = newKernel("add", .{ 64, 1, 1 });
    const out = k.binding();
    const t4 = k.op2(.shl, .u32, kir.r(k.tid(0)), kir.u(2));
    const x = k.load(.u32, kir.global(out, 32), kir.r(t4));
    k.store(.u32, kir.global(out, 32), kir.r(t4), kir.r(k.op2(.iadd, .u32, kir.r(x), kir.r(k.param(.u32, 0)))));
    const p = try loadKernel(d, &k);
    const b = try d.alloc(4 * 64, .host);
    @memset(b.cpu, 0);
    d.toDevice(b, 0, b.bytes);
    // three times round the streams, none waited for in between
    var fences: [3 * STREAMS]Fence = undefined;
    var params: [3 * STREAMS][1]u32 = undefined;
    for (&fences, &params, 0..) |*f, *pw, n| {
        pw[0] = @intCast(n + 1);
        f.* = try d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{b}, .params = pw }});
    }
    // (a fence whose stream was taken again is done)
    try std.testing.expect(d.done(fences[0]));
    try d.wait(fences[fences.len - 1], 1_000_000);
    d.fromDevice(b, 0, b.bytes);
    // 1 + 2 + ... + 12, every run's addition there once
    for (b.words()) |w| try std.testing.expectEqual(@as(u32, 78), w);
}

test "a kernel through the adapter: PM4, constants, the pool, cache maintenance" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    var k = newKernel("ids", .{ 64, 1, 1 });
    const out = k.binding();
    const t = k.tid(0);
    const g = k.gid(0);
    const scale = k.param(.u32, 0);
    const i = k.op2(.iadd, .u32, kir.r(k.op2(.shl, .u32, kir.r(g), kir.u(6))), kir.r(t));
    // a value needing the pool (0x12345 does not fit an immediate)
    const v = k.op2(.iadd, .u32, kir.r(k.op2(.imul, .u32, kir.r(i), kir.r(scale))), kir.u(0x12345));
    k.store(.u32, kir.global(out, 32), kir.r(k.op2(.shl, .u32, kir.r(i), kir.u(2))), kir.r(v));
    const p = try loadKernel(d, &k);
    const b = try d.alloc(4 * 256, .host);
    @memset(b.cpu, 0);
    d.toDevice(b, 0, b.bytes);
    const clock = d.vtable.timestampNs.?;
    const before = try clock(d.ctx, 1_000_000);
    try runOne(d, &p, .{ 4, 1, 1 }, &.{b}, &.{7});
    const elapsed = d.lastRunNs();
    const after = try clock(d.ctx, 1_000_000);
    d.fromDevice(b, 0, b.bytes);
    for (b.words(), 0..) |x, n| try std.testing.expectEqual(@as(u32, @intCast(n * 7 + 0x12345)), x);
    try std.testing.expect(elapsed > 0);
    try std.testing.expect(after > before and after - before >= elapsed);
}

test "every constant in one direct load from c0, the pool too: none loaded by the CP from memory" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    var k = newKernel("pool", .{ 64, 1, 1 });
    const out = k.binding();
    const i = k.op2(.shl, .u32, kir.r(k.tid(0)), kir.u(2));
    const v = k.op2(.iadd, .u32, kir.r(k.tid(0)), kir.u(0x12345));
    k.store(.u32, kir.global(out, 32), kir.r(i), kir.r(v));
    const p = try loadKernel(d, &k);
    const cfg = kir_ir3.Config.fromExtra(p.bin.extra).?;
    try std.testing.expect(cfg.pool_words > 0);
    const b = try d.alloc(256, .host);
    var buf: [4096]u32 = undefined;
    var s = a7xx.Stream{ .buf = &buf };
    try Rig.emu.adapter.build(&s, &.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{b}, .params = &.{} }}, 0);
    const w = s.words();
    var loads: u32 = 0;
    var at: usize = 0;
    while (at < w.len) {
        const h = w[at];
        const n: usize = switch (h >> 28) {
            4 => h & 0x7f,
            7 => h & 0x3fff,
            else => return error.TestUnexpectedResult,
        };
        if (h >> 28 == 7 and (h >> 16) & 0x7f == a7xx.CP_LOAD_STATE6_FRAG and (w[at + 1] >> 14) & 3 == a7xx.ST6_CONSTANTS) {
            loads += 1;
            const d0 = w[at + 1];
            try std.testing.expectEqual(@as(u32, a7xx.SS6_DIRECT), (d0 >> 16) & 3);
            try std.testing.expectEqual(@as(u32, 0), d0 & 0x3fff);
            const data = w[at + 4 .. at + 1 + n];
            // the binding's address at c0.x:c0.y, then the pool where the code reads it
            try std.testing.expectEqual(@as(u32, @truncate(b.gpu)), data[0]);
            try std.testing.expectEqual(@as(u32, @truncate(b.gpu >> 32)), data[1]);
            for (0..cfg.pool_words) |j|
                try std.testing.expectEqual(std.mem.readInt(u32, p.bin.code[cfg.pool_offset + 4 * j ..][0..4], .little), data[cfg.pool + j]);
        }
        at += 1 + n;
    }
    try std.testing.expectEqual(@as(u32, 1), loads);
    // and it still runs
    try runOne(d, &p, .{ 1, 1, 1 }, &.{b}, &.{});
    d.fromDevice(b, 0, b.bytes);
    for (b.words()[0..64], 0..) |x, n| try std.testing.expectEqual(@as(u32, @intCast(n + 0x12345)), x);
}

test "overlap: a wait only before a dispatch that reads what one before it wrote; without it, between every two" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    // out[i] = in[i] + 1
    var k = newKernel("inc", .{ 64, 1, 1 });
    const in = k.binding();
    const out = k.binding();
    const i = k.op2(.iadd, .u32, kir.r(k.op2(.shl, .u32, kir.r(k.gid(0)), kir.u(6))), kir.r(k.tid(0)));
    const a = k.op2(.shl, .u32, kir.r(i), kir.u(2));
    k.store(.u32, kir.global(out, 32), kir.r(a), kir.r(k.op2(.iadd, .u32, kir.r(k.load(.u32, kir.global(in, 32), kir.r(a))), kir.u(1))));
    const p = try loadKernel(d, &k);
    var bufs: [4]Buffer = undefined;
    for (&bufs) |*b| b.* = try d.alloc(4 * 64, .host);
    // 0 -> 1 and 2 -> 3 share nothing; 1 -> 2 reads what the first wrote
    // (and writes what the second read): a wait before the third only
    const ds = [_]Dispatch{
        .{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ bufs[0], bufs[1] }, .params = &.{} },
        .{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ bufs[2], bufs[3] }, .params = &.{} },
        .{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ bufs[1], bufs[2] }, .params = &.{} },
    };
    const o = &Rig.emu.adapter;
    var words: [4096]u32 = undefined;
    const wfi = a7xx.pkt7(a7xx.CP_WAIT_FOR_IDLE, 0);
    // (the stream's own waits, setup's and the timestamps', are the same in
    // both: the difference is the waits between dispatches)
    var waits: [2]u32 = undefined;
    for ([_]bool{ false, true }, 0..) |on, m| {
        o.overlap = on;
        var s = a7xx.Stream{ .buf = &words };
        try o.build(&s, &ds, 0x1000);
        var n: u32 = 0;
        for (words[0..s.len]) |w| n += @intFromBool(w == wfi);
        waits[m] = n;
        try std.testing.expectEqual(@as(u32, if (on) 1 else 2), o.barriers);
    }
    try std.testing.expectEqual(@as(u32, 1), waits[0] - waits[1]);
    o.overlap = false;
}

test "zero-copy import: the GPU reads the CPU's memory in place, and free gives it back" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    // (the importer lends one of the emulator's own buffers: its memory is
    // the "CPU's", mapped where the raw device placed it)
    const Lend = struct {
        var lent: raw.Buffer = .{};
        var released: u32 = 0;
        var asked_writable = true;
        fn import(ctx: *anyopaque, cpu: []u8, writable: bool) ?raw.Buffer {
            _ = ctx;
            asked_writable = writable;
            if (cpu.ptr != lent.cpu.ptr) return null;
            return .{ .va = lent.va, .cpu = cpu, .handle = 0x8000_0001 };
        }
        fn release(ctx: *anyopaque, handle: u32) void {
            _ = ctx;
            if (handle == 0x8000_0001) released += 1;
        }
    };
    try std.testing.expect(!Rig.emu.device().caps.import);
    var dummy: u8 = 0;
    Rig.emu.adapter.setImporter(.{ .ctx = &dummy, .import = Lend.import, .release = Lend.release });
    const d = Rig.emu.device();
    try std.testing.expect(d.caps.import);
    Lend.lent = try Rig.emu.gpu.device().alloc(4 * 256);
    for (Lend.lent.words(), 0..) |*w, n| w.* = @intCast(n * 3 + 1);
    const in = d.import(Lend.lent.cpu) orelse return error.NotImported;
    try std.testing.expect(!Lend.asked_writable);
    try std.testing.expectEqual(Lend.lent.va, in.gpu);
    d.toDevice(in, 0, in.bytes);
    // out[i] = in[i] + 5, the input read where the CPU wrote it
    var k = newKernel("copy_in_place", .{ 64, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const t = k.tid(0);
    const g = k.gid(0);
    const i = k.op2(.iadd, .u32, kir.r(k.op2(.shl, .u32, kir.r(g), kir.u(6))), kir.r(t));
    const off = k.op2(.shl, .u32, kir.r(i), kir.u(2));
    const x = k.load(.u32, kir.global(src, 32), kir.r(off));
    k.store(.u32, kir.global(dst, 32), kir.r(off), kir.r(k.op2(.iadd, .u32, kir.r(x), kir.u(5))));
    const p = try loadKernel(d, &k);
    const out = try d.alloc(4 * 256, .host);
    @memset(out.cpu, 0);
    d.toDevice(out, 0, out.bytes);
    try runOne(d, &p, .{ 4, 1, 1 }, &.{ in, out }, &.{});
    d.fromDevice(out, 0, out.bytes);
    for (out.words(), 0..) |w, n| try std.testing.expectEqual(@as(u32, @intCast(n * 3 + 6)), w);
    // free: the import back to the importer, once; a plain buffer as before
    d.free(in);
    try std.testing.expectEqual(@as(u32, 1), Lend.released);
    d.free(out);
    try std.testing.expectEqual(@as(u32, 1), Lend.released);
    // (memory it does not lend: refused)
    var other: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?Buffer, null), d.import(&other));
}

test "the emulated Adreno faults on a read past its binding, into the next buffer" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    var k = newKernel("overrun", .{ 64, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const t = k.tid(0);
    const off = k.op2(.shl, .u32, kir.r(t), kir.u(2));
    // reads words 64..127 of a 64-word buffer
    const x = k.load(.u32, .{ .binding = src, .space = .global, .width_log2 = 5, .signed = false, .imm = 256 }, kir.r(off));
    k.store(.u32, kir.global(dst, 32), kir.r(off), kir.r(x));
    const p = try loadKernel(d, &k);
    const a = try d.alloc(256, .host);
    const b = try d.alloc(4096, .host);
    // (the raw emulator's buffers sit a page apart: a's next page is b's)
    const f = try d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{} }});
    try std.testing.expectError(error.DeviceLost, d.wait(f, 1000));
    try std.testing.expectEqual(a.gpu + 256, Rig.emu.fault().va);
}

test "the emulated Adreno refuses code that breaks ir3's operand rules, at load" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    var k = newKernel("legal", .{ 64, 1, 1 });
    const out = k.binding();
    const v = k.op2(.imul, .u32, kir.r(k.gid(1)), kir.r(k.param(.u32, 0)));
    k.store(.u32, kir.global(out, 32), kir.r(k.op2(.shl, .u32, kir.r(k.tid(0)), kir.u(2))), kir.r(v));
    try k.finish();
    var bin = try kir_ir3.compileWith(&k, d.caps, &Rig.work, &Rig.out);
    _ = try d.load(&bin);
    // the shape of the Surface's fault, written over the first instruction
    const bad = try adreno.ir3.assembleLine(adreno.ir3.A7XX, "mul.u24 r1.w, r48.y, c0.x");
    const code = Rig.out[0..bin.code.len];
    std.mem.writeInt(u64, code[0..8], bad, .little);
    bin.code = code;
    try std.testing.expectError(error.BadProgram, d.load(&bin));
    try std.testing.expect(Rig.emu.illegal != null);
    try std.testing.expectEqual(@as(u32, 0), Rig.emu.illegal.?.pc);
}

test "a group whose waves its registers cannot keep resident: kir_ir3 refuses it, the adapter too" {
    Rig.emu.init(&Rig.arena, &Rig.view);
    const d = Rig.emu.device();
    // 96 values live at once: more than a 1024-thread group's 12 vec4
    const build = struct {
        fn f(k: *kir.Kernel) !void {
            const src = k.binding();
            const out = k.binding();
            const t = k.op2(.shl, .u32, kir.r(k.tid(0)), kir.u(2));
            var vals: [96]kir.V = undefined;
            for (&vals, 0..) |*x, i| {
                var m = kir.global(src, 32);
                m.imm = @intCast(4 * i);
                x.* = k.load(.u32, m, kir.r(t));
            }
            // every value used twice, the passes apart: all live at once
            var acc = k.op2(.xor, .u32, kir.r(vals[0]), kir.r(vals[1]));
            for (2..96) |i| acc = k.op2(.iadd, .u32, kir.r(acc), kir.r(vals[i]));
            for (0..96) |i| acc = k.op2(.xor, .u32, kir.r(k.op2(.shl, .u32, kir.r(acc), kir.u(1))), kir.r(vals[i]));
            k.store(.u32, kir.global(out, 32), kir.r(t), kir.r(acc));
            try k.finish();
        }
    }.f;
    var big = newKernel("1024 threads", .{ 1024, 1, 1 });
    try build(&big);
    try std.testing.expectError(error.TooManyRegs, kir_ir3.compileWith(&big, d.caps, &Rig.work, &Rig.out));
    try std.testing.expect(std.mem.indexOf(u8, kir_ir3.diagnostic(&Rig.work), "waves") != null);
    var small = newKernel("64 threads", .{ 64, 1, 1 });
    try build(&small);
    var bin = try kir_ir3.compileWith(&small, d.caps, &Rig.work, &Rig.out);
    _ = try d.load(&bin);
    // the same code claimed for 1024 threads: the adapter refuses it
    bin.group = .{ 1024, 1, 1 };
    try std.testing.expectError(error.BadProgram, d.load(&bin));
}
