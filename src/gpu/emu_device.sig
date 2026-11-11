//! @zpm/gpu EmuDevice — the reference device: KIR run by kir_interp, in
//! memory the caller provides, under whatever Caps a test gives it.
//!
//! Memory, by caps.memory:
//! - unified: every buffer is in `mem` and has a CPU view; `import` maps
//!   the caller's own bytes. With `caps.coherent = false` and a `shadow`
//!   (as long as `mem`) the GPU sees its own copy, which only toDevice
//!   fills and only fromDevice copies back, so a missing cache maintenance
//!   call gives wrong results here, not only on hardware.
//! - discrete: `.device` buffers live in `vram` and have no CPU view;
//!   `.host` and `.upload` buffers are in `mem`, which the GPU reads
//!   directly (system memory, BAR1).
//!
//! Running: a dispatch's buffers must be live buffers of this device and
//! its accesses inside them; anything else is a trap (error.DeviceLost,
//! with `trap` saying where).

const std = @import("std");
const kir = @import("kir.sig");
const dv = @import("device.sig");
const interp = @import("kir_interp.sig");
const Caps = dv.Caps;
const Buffer = dv.Buffer;
const Kind = dv.Kind;
const Binary = dv.Binary;
const Program = dv.Program;
const Dispatch = dv.Dispatch;
const Error = dv.Error;
const Fence = dv.Fence;

pub const MAX_BUFFERS = 256;
pub const MAX_BINDINGS = 64;
const PAGE = 256;

const MEM_VA: u64 = 0x1_0000_0000;
const VRAM_VA: u64 = 0x2_0000_0000;
const IMPORT_VA: u64 = 0x4_0000_0000;

const Region = struct {
    gpu: u64,
    bytes: u64,
    /// the CPU's view (empty: none)
    cpu: []u8,
    /// the GPU's view
    seen: []u8,
    /// where it lives: 0 mem, 1 vram, 2 imported (shadow, if any, in `shadow`)
    arena: u2,
    /// the offset in its arena (mem, vram) or in `shadow` (imported)
    at: usize,
    shadow_at: ?usize = null,
    kind: Kind,
    live: bool,
};

pub const EmuDevice = struct {
    caps: Caps,
    /// host memory: buffers' CPU views (and, unified, the GPU's too)
    mem: []u8,
    /// discrete: the device's own memory, where `.device` buffers live
    vram: []u8 = &.{},
    /// unified, not coherent: the GPU's copy of `mem` (as long), and of
    /// imported memory after it; empty: the GPU sees the CPU's bytes
    shadow: []u8 = &.{},
    /// the interpreter's scratch (registers, masks, shared memory)
    work: []u8,
    regions: [MAX_BUFFERS]Region = undefined,
    n_regions: u32 = 0,
    import_va: u64 = IMPORT_VA,
    /// shadow bytes past `mem.len` used by imports
    import_shadow: usize = 0,
    fence: Fence = 0,
    trap: interp.Trap = .{},
    stats: interp.Stats = .{},
    /// totals over every run
    total: interp.Stats = .{},
    last_error: ?anyerror = null,

    /// `caps` as given, with the interpreter's target and the memory's size.
    pub fn init(caps: Caps, mem: []u8, work: []u8) EmuDevice {
        var c = caps;
        c.target = .interp;
        if (c.device_bytes == 0) c.device_bytes = mem.len;
        return .{ .caps = c, .mem = mem, .work = work };
    }

    pub fn device(e: *EmuDevice) dv.Device {
        return .{ .ctx = e, .vtable = &vtable, .caps = e.caps };
    }

    const vtable = dv.Device.VTable{
        .alloc = emuAlloc,
        .free = emuFree,
        .import = emuImport,
        .toDevice = emuToDevice,
        .fromDevice = emuFromDevice,
        .load = emuLoad,
        .unload = emuUnload,
        .run = emuRun,
        .wait = emuWait,
        .done = emuDone,
        .lastRunNs = emuLastRunNs,
    };

    fn self(ctx: *anyopaque) *EmuDevice {
        return @ptrCast(@alignCast(ctx));
    }

    fn separateView(e: *const EmuDevice) bool {
        return e.caps.memory == .unified and !e.caps.coherent and e.shadow.len >= e.mem.len;
    }

    /// First fit in arena `which` (0 mem, 1 vram) for `bytes`.
    fn fit(e: *const EmuDevice, which: u2, bytes: u64) ?usize {
        const arena = if (which == 0) e.mem else e.vram;
        const size = std.mem.alignForward(u64, @max(bytes, 1), PAGE);
        var at: u64 = 0;
        while (at + size <= arena.len) {
            var clash: ?u64 = null;
            for (e.regions[0..e.n_regions]) |rg| {
                if (!rg.live or rg.arena != which) continue;
                const end = rg.at + std.mem.alignForward(u64, @max(rg.bytes, 1), PAGE);
                if (at < end and rg.at < at + size) {
                    clash = @max(clash orelse 0, end);
                }
            }
            if (clash) |next| at = next else return @intCast(at);
        }
        return null;
    }

    fn slot(e: *EmuDevice) ?*Region {
        for (e.regions[0..e.n_regions]) |*rg| if (!rg.live) return rg;
        if (e.n_regions == MAX_BUFFERS) return null;
        e.n_regions += 1;
        return &e.regions[e.n_regions - 1];
    }

    fn emuAlloc(ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer {
        const e = self(ctx);
        const in_vram = e.caps.memory == .discrete and kind == .device;
        if (in_vram and e.vram.len == 0) return null;
        const which: u2 = if (in_vram) 1 else 0;
        const at = e.fit(which, bytes) orelse return null;
        const rg = e.slot() orelse return null;
        const n: usize = @intCast(bytes);
        const arena = if (in_vram) e.vram else e.mem;
        const cpu = if (in_vram) arena[0..0] else arena[at..][0..n];
        const seen = if (in_vram) arena[at..][0..n] else if (e.separateView()) e.shadow[at..][0..n] else cpu;
        // (fresh memory reads as zeros from both sides, as a driver's does)
        @memset(arena[at..][0..n], 0);
        @memset(seen, 0);
        const va = (if (in_vram) VRAM_VA else MEM_VA) + at;
        rg.* = .{ .gpu = va, .bytes = bytes, .cpu = cpu, .seen = seen, .arena = which, .at = at, .kind = kind, .live = true };
        return .{ .gpu = va, .cpu = cpu, .bytes = bytes, .handle = e.handleOf(rg), .kind = kind };
    }

    fn handleOf(e: *const EmuDevice, rg: *const Region) u32 {
        return @intCast((@intFromPtr(rg) - @intFromPtr(&e.regions[0])) / @sizeOf(Region) + 1);
    }

    fn region(e: *EmuDevice, gpu: u64) ?*Region {
        for (e.regions[0..e.n_regions]) |*rg| {
            if (rg.live and rg.gpu == gpu) return rg;
        }
        return null;
    }

    /// The live buffer GPU address `gpu` is in: a binding may start inside
    /// its buffer, as a GPU's binding is any address (an imported dma-buf's
    /// plane at its offset).
    fn regionHolding(e: *EmuDevice, gpu: u64) ?*Region {
        for (e.regions[0..e.n_regions]) |*rg| {
            if (rg.live and gpu >= rg.gpu and gpu - rg.gpu < @max(rg.bytes, 1)) return rg;
        }
        return null;
    }

    fn emuFree(ctx: *anyopaque, b: Buffer) void {
        const e = self(ctx);
        const rg = e.region(b.gpu) orelse return;
        rg.live = false;
    }

    fn emuImport(ctx: *anyopaque, cpu: []u8) ?Buffer {
        const e = self(ctx);
        if (!e.caps.import or e.caps.memory != .unified) return null;
        const rg = e.slot() orelse return null;
        var seen = cpu;
        var shadow_at: ?usize = null;
        if (e.separateView()) {
            const at = e.mem.len + e.import_shadow;
            if (at + cpu.len > e.shadow.len) return null;
            seen = e.shadow[at..][0..cpu.len];
            @memcpy(seen, cpu);
            shadow_at = at;
            e.import_shadow += std.mem.alignForward(usize, cpu.len, PAGE);
        }
        const va = e.import_va;
        e.import_va += std.mem.alignForward(u64, @max(cpu.len, 1), 4096);
        rg.* = .{ .gpu = va, .bytes = cpu.len, .cpu = cpu, .seen = seen, .arena = 2, .at = 0, .shadow_at = shadow_at, .kind = .host, .live = true };
        return .{ .gpu = va, .cpu = cpu, .bytes = cpu.len, .handle = e.handleOf(rg), .kind = .host };
    }

    fn span(rg: *const Region, off: u64, len: u64) ?[2]usize {
        if (off > rg.bytes or len > rg.bytes - off) return null;
        return .{ @intCast(off), @intCast(off + len) };
    }

    fn emuToDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        const e = self(ctx);
        const rg = e.region(b.gpu) orelse return;
        if (rg.cpu.len == 0 or rg.cpu.ptr == rg.seen.ptr) return;
        const s = span(rg, off, len) orelse return;
        @memcpy(rg.seen[s[0]..s[1]], rg.cpu[s[0]..s[1]]);
    }

    fn emuFromDevice(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        const e = self(ctx);
        const rg = e.region(b.gpu) orelse return;
        if (rg.cpu.len == 0 or rg.cpu.ptr == rg.seen.ptr) return;
        const s = span(rg, off, len) orelse return;
        @memcpy(rg.cpu[s[0]..s[1]], rg.seen[s[0]..s[1]]);
    }

    fn emuLoad(ctx: *anyopaque, bin: *const Binary) Error!Program {
        const e = self(ctx);
        if (bin.target != .interp) return error.BadProgram;
        if (bin.code.len != @as(usize, bin.extra[0]) * kir.INST_BYTES) return error.BadProgram;
        const buf = emuAlloc(ctx, @max(bin.code.len, 1), .device) orelse return error.OutOfMemory;
        const rg = e.region(buf.gpu).?;
        // (the driver writes the code into the GPU's view)
        @memcpy(rg.seen[0..bin.code.len], bin.code);
        if (rg.cpu.len != 0 and rg.cpu.ptr != rg.seen.ptr) @memcpy(rg.cpu[0..bin.code.len], bin.code);
        var b = bin.*;
        b.code = rg.seen[0..bin.code.len];
        return .{ .bin = b, .code = buf };
    }

    fn emuUnload(ctx: *anyopaque, p: *const Program) void {
        emuFree(ctx, p.code);
    }

    fn emuRun(ctx: *anyopaque, ds: []const Dispatch) Error!Fence {
        const e = self(ctx);
        e.fence += 1;
        e.last_error = null;
        e.trap = .{};
        e.stats = .{};
        for (ds) |d| {
            e.dispatch(d) catch |err| {
                e.last_error = err;
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.BadProgram => error.BadProgram,
                    else => error.DeviceLost,
                };
            };
        }
        return e.fence;
    }

    fn dispatch(e: *EmuDevice, d0: Dispatch) anyerror!void {
        var d = d0;
        // (the counts as the dispatches before left them)
        if (d.indirect) |ind| {
            const rg = e.regionHolding(ind.buf.gpu + ind.off) orelse return error.Trap;
            const at: usize = @intCast(ind.buf.gpu + ind.off - rg.gpu);
            if (at + 12 > rg.bytes) return error.Trap;
            const w = rg.seen[at..][0..12];
            d.groups = .{ std.mem.readInt(u32, w[0..4], .little), std.mem.readInt(u32, w[4..8], .little), std.mem.readInt(u32, w[8..12], .little) };
            if (d.groups[0] == 0 or d.groups[1] == 0 or d.groups[2] == 0) return;
        }
        const p = d.prog;
        if (p.bin.target != .interp) return error.BadProgram;
        if (d.buffers.len != p.bin.bindings or d.buffers.len > MAX_BINDINGS) return error.BadProgram;
        if (d.params.len < p.bin.param_words) return error.BadProgram;
        var views: [MAX_BINDINGS][]u8 = undefined;
        for (d.buffers, 0..) |b, ix| {
            const rg = e.regionHolding(b.gpu) orelse {
                e.trap = .{ .what = .bad_binding, .binding = @intCast(ix) };
                return error.Trap;
            };
            views[ix] = rg.seen[@intCast(b.gpu - rg.gpu)..@intCast(rg.bytes)];
        }
        // the code, as the GPU fetches it
        const crg = e.region(p.code.gpu) orelse return error.BadProgram;
        const n: usize = p.bin.extra[0];
        if (crg.bytes < n * kir.INST_BYTES) return error.BadProgram;
        var w = dv.Work.init(e.work);
        const insts = w.take(kir.Inst, n) orelse return error.OutOfMemory;
        for (insts, 0..) |*in, ix| {
            in.* = kir.decodeInst(crg.seen[ix * kir.INST_BYTES ..][0..kir.INST_BYTES]) catch return error.BadProgram;
        }
        var st: interp.Stats = .{};
        interp.run(.{
            .code = insts,
            .regs = p.bin.regs,
            .group = p.bin.group,
            .shared_bytes = p.bin.shared_bytes,
            .groups = d.groups,
            .bindings = views[0..d.buffers.len],
            .params = d.params,
        }, e.caps, &w, &e.trap, &st) catch |err| switch (err) {
            error.NoWork => return error.OutOfMemory,
            error.BadProgram => return error.BadProgram,
            error.Trap => return error.Trap,
        };
        e.stats.groups += st.groups;
        e.stats.issued += st.issued;
        e.stats.lane_ops += st.lane_ops;
        e.total.groups += st.groups;
        e.total.issued += st.issued;
        e.total.lane_ops += st.lane_ops;
        // (the clock: the instructions issued so far, a tick each)
        if (d.stamp) |s| {
            const rg = e.regionHolding(s.buf.gpu + s.off) orelse return error.Trap;
            const at: usize = @intCast(s.buf.gpu + s.off - rg.gpu);
            if (at + 16 > rg.bytes) return error.Trap;
            const word = rg.seen[at..][0..16];
            std.mem.writeInt(u64, word[0..8], 1, .little);
            std.mem.writeInt(u64, word[8..16], e.total.issued, .little);
        }
    }

    fn emuWait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        const e = self(ctx);
        _ = timeout_us;
        if (f > e.fence) return error.Timeout;
        if (f == e.fence and e.last_error != null) return error.DeviceLost;
    }

    fn emuDone(ctx: *anyopaque, f: Fence) bool {
        return f <= self(ctx).fence;
    }

    fn emuLastRunNs(ctx: *anyopaque) u64 {
        _ = ctx;
        return 0;
    }
};
