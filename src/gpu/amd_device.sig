//! @zpm/gpu amd_device — an AMD GCN 4 GPU (gfx803) as a gpu.Device.
//!
//! `Emu` is the emulated Polaris: programs from kir_gcn4 run in
//! amdgpu.gcn3_emu, wave64 by wave64, with the kernarg segment and the
//! launch state the hardware gives (the kernarg pointer in s[0:1], the group
//! ids after it, the workitem ids in v0-v2, the dispatch's MODE). Buffers
//! are the caller's memory; each sits 4 GB from the next in the GPU's
//! address space, so an access that runs past its buffer (a u32 offset can
//! reach 4 GB) lands nowhere and is a fault (DeviceLost), never another
//! buffer's bytes. Buffer resources are checked strictly: an access past
//! a V#'s records is a fault too, not the hardware's zero.
//!
//! The adapter over Galaxy's driver (the PM4 stream: SET_SH_REG from
//! amdgpu.dispatch.shRegs, DISPATCH_DIRECT, a fence per run) is Galaxy's
//! next step; `Info.config()` and `Info.kernarg()` are what it consumes.
//!
//! Allocation-free: the memory and the emulator's Work are the caller's.

const std = @import("std");
const dv = @import("device.sig");
const kir_gcn4 = @import("kir_gcn4.sig");
const amdgpu = @import("amdgpu");
const gcn3_emu = amdgpu.gcn3_emu;
const gcn3_asm = amdgpu.gcn3_asm;

const Caps = dv.Caps;
const Buffer = dv.Buffer;
const Kind = dv.Kind;
const Binary = dv.Binary;
const Program = dv.Program;
const Dispatch = dv.Dispatch;
const Error = dv.Error;
const Fence = dv.Fence;

pub const MAX_BUFFERS = 96;
/// Between buffers in the emulated GPU's address space.
pub const SPACING: u64 = 1 << 32;
/// Kernarg dwords one dispatch may have.
pub const MAX_KERNARG = 64;

/// The emulated Polaris's caps: the Radeon Pro 560X's, in host memory
/// (unified and coherent: it is the CPU's memory).
pub fn emuCaps(device_bytes: u64) Caps {
    var c = kir_gcn4.polaris_caps(device_bytes);
    c.name = "emulated Polaris (gcn3_emu)";
    c.memory = .unified;
    c.coherent = true;
    return c;
}

const Slot = struct { va: u64 = 0, bytes: []u8 = &.{}, live: bool = false };

pub const Emu = struct {
    arena: []u8 = &.{},
    used: usize = 0,
    slots: [MAX_BUFFERS]Slot = [_]Slot{.{}} ** MAX_BUFFERS,
    nslots: usize = 0,
    regions: [MAX_BUFFERS]gcn3_emu.Region = undefined,
    work: *gcn3_emu.Work = undefined,
    caps: Caps = undefined,
    /// Buffer resources checked strictly (an access past a V#'s records faults).
    strict: bool = true,
    fences: u64 = 0,
    last_error: ?anyerror = null,
    last: gcn3_emu.Stats = .{},
    total: gcn3_emu.Stats = .{},
    kernarg_buf: Buffer = .{},

    /// Memory from `arena`, the emulator's (large) Work from `work`.
    pub fn init(e: *Emu, arena: []u8, work: *gcn3_emu.Work) void {
        e.* = .{ .arena = arena, .work = work, .caps = emuCaps(arena.len) };
        e.kernarg_buf = e.allocIn(4 * MAX_KERNARG, .host) orelse .{};
    }

    pub fn device(e: *Emu) dv.Device {
        return .{ .ctx = e, .vtable = &vtable, .caps = e.caps };
    }

    /// The emulator's last error message (after a run's DeviceLost).
    pub fn explain(e: *const Emu) []const u8 {
        return e.work.message();
    }

    /// The instruction the last error happened at, as text.
    pub fn errorInstr(e: *const Emu, buf: []u8) []const u8 {
        return e.work.errorInstr(buf);
    }

    fn allocIn(e: *Emu, bytes: u64, kind: Kind) ?Buffer {
        if (e.nslots == MAX_BUFFERS) return null;
        const at = std.mem.alignForward(usize, e.used, 256);
        const n: usize = @intCast(@max(bytes, 4));
        if (at + n > e.arena.len) return null;
        e.used = at + n;
        const ix = e.nslots;
        e.nslots += 1;
        const va = SPACING * (@as(u64, ix) + 1);
        e.slots[ix] = .{ .va = va, .bytes = e.arena[at..][0..n], .live = true };
        return .{ .gpu = va, .cpu = e.arena[at..][0..n], .bytes = bytes, .handle = @intCast(ix), .kind = kind };
    }

    const vtable = dv.Device.VTable{
        .alloc = alloc,
        .free = free,
        .import = import,
        .toDevice = sync,
        .fromDevice = sync,
        .load = load,
        .unload = unload,
        .run = run,
        .wait = wait,
        .done = done,
        .lastRunNs = lastRunNs,
    };

    fn self(ctx: *anyopaque) *Emu {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, bytes: u64, kind: Kind) ?Buffer {
        return self(ctx).allocIn(bytes, kind);
    }

    fn free(ctx: *anyopaque, b: Buffer) void {
        const e = self(ctx);
        if (b.handle < e.nslots) e.slots[b.handle].live = false;
        // the arena goes back when everything after the kernarg is free
        var any = false;
        for (e.slots[1..e.nslots]) |s| any = any or s.live;
        if (!any) {
            e.nslots = 1;
            e.used = e.slots[0].bytes.len + (@intFromPtr(e.slots[0].bytes.ptr) - @intFromPtr(e.arena.ptr));
        }
    }

    fn import(ctx: *anyopaque, cpu: []u8) ?Buffer {
        _ = ctx;
        _ = cpu;
        return null;
    }

    fn sync(ctx: *anyopaque, b: Buffer, off: u64, len: u64) void {
        _ = ctx;
        _ = b;
        _ = off;
        _ = len;
    }

    fn load(ctx: *anyopaque, bin: *const Binary) Error!Program {
        const e = self(ctx);
        if (bin.target != .gcn4_gfx803) return error.BadProgram;
        if (kir_gcn4.Info.fromExtra(bin.extra) == null) return error.BadProgram;
        if (bin.code.len % 4 != 0) return error.BadProgram;
        const code = e.allocIn(bin.code.len, .device) orelse return error.OutOfMemory;
        @memcpy(code.cpu[0..bin.code.len], bin.code);
        var b = bin.*;
        b.code = code.cpu[0..bin.code.len];
        return .{ .bin = b, .code = code };
    }

    fn unload(ctx: *anyopaque, p: *const Program) void {
        free(ctx, p.code);
    }

    fn run(ctx: *anyopaque, ds: []const Dispatch) Error!Fence {
        const e = self(ctx);
        e.last = .{};
        for (ds) |d| try e.dispatchOne(d);
        e.fences += 1;
        return e.fences;
    }

    fn dispatchOne(e: *Emu, d: Dispatch) Error!void {
        const bin = &d.prog.bin;
        const info = kir_gcn4.Info.fromExtra(bin.extra) orelse return error.BadProgram;
        if (d.buffers.len != bin.bindings or d.params.len < bin.param_words) return error.BadProgram;
        for (d.groups) |g| {
            if (g == 0) return error.BadProgram;
        }
        // the kernarg segment
        const kw = e.kernarg_buf.words();
        _ = info.kernarg(d.buffers, d.params[0..bin.param_words], d.groups, kw) catch return error.BadProgram;
        // the memory the GPU sees: every live buffer
        var n: usize = 0;
        for (e.slots[0..e.nslots]) |s| {
            if (!s.live) continue;
            e.regions[n] = .{ .va = s.va, .bytes = s.bytes };
            n += 1;
        }
        const mem = gcn3_emu.Memory{ .regions = e.regions[0..n] };
        const words: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, d.prog.code.cpu[0..bin.code.len]));
        const kernel = gcn3_asm.Kernel{
            .code = words,
            .config = info.config(),
            .workgroup_size = .{ @intCast(bin.group[0]), @intCast(bin.group[1]), @intCast(bin.group[2]) },
            .instructions = info.instructions,
        };
        const kva = e.kernarg_buf.gpu;
        const user = [2]u32{ @truncate(kva), @truncate(kva >> 32) };
        const gd = gcn3_emu.Dispatch{ .kernel = &kernel, .user_sgprs = &user, .groups = d.groups, .strict_buffers = e.strict };
        var stats = gcn3_emu.Stats{};
        gcn3_emu.run(e.work, &mem, &gd, &stats) catch |err| {
            e.last_error = err;
            return error.DeviceLost;
        };
        e.last.instructions += stats.instructions;
        e.last.lane_ops += stats.lane_ops;
        e.last.waves += stats.waves;
        e.last.workgroups += stats.workgroups;
        e.total.instructions += stats.instructions;
        e.total.lane_ops += stats.lane_ops;
    }

    fn wait(ctx: *anyopaque, f: Fence, timeout_us: u64) Error!void {
        _ = timeout_us;
        if (f > self(ctx).fences) return error.Timeout;
    }

    fn done(ctx: *anyopaque, f: Fence) bool {
        return f <= self(ctx).fences;
    }

    fn lastRunNs(ctx: *anyopaque) u64 {
        _ = ctx;
        return 0;
    }
};

test "amd_device: the emulated Polaris runs a compiled kernel" {
    const kir = @import("kir.sig");
    const S = struct {
        var arena: [1 << 20]u8 align(4096) = undefined;
        var emu_work: gcn3_emu.Work = .{};
        var work: kir_gcn4.Work = .{};
        var out: [64 * 1024]u8 align(4) = undefined;
        var insts: [64]kir.Inst = undefined;
        var tys: [64]kir.Ty = undefined;
    };
    var e: Emu = .{};
    e.init(&S.arena, &S.emu_work);
    const d = e.device();
    // out[i] = 3 * i + p
    var k = kir.Kernel.init(.{ .insts = &S.insts, .tys = &S.tys }, "affine", .{ 128, 1, 1 });
    const b = k.binding();
    const p = k.param(.u32, 0);
    const t = k.op2(.iadd, .u32, kir.r(k.tid(0)), kir.r(k.op2(.shl, .u32, kir.r(k.gid(0)), kir.u(7))));
    const y = k.op3(.imad, .u32, kir.r(t), kir.u(3), kir.r(p));
    k.store(.u32, kir.global(b, 32), kir.r(k.op2(.shl, .u32, kir.r(t), kir.u(2))), kir.r(y));
    try k.finish();
    const bin = try kir_gcn4.compileWith(&k, d.caps, &S.work, &S.out);
    const prog = try d.load(&bin);
    const buf = try d.alloc(4 * 256, .host);
    try d.runWait(&.{.{ .prog = &prog, .groups = .{ 2, 1, 1 }, .buffers = &.{buf}, .params = &.{7} }}, 1_000_000);
    for (buf.words()[0..256], 0..) |x, i| try std.testing.expectEqual(@as(u32, @intCast(3 * i + 7)), x);
    // an access past the buffer faults
    var k2 = kir.Kernel.init(.{ .insts = &S.insts, .tys = &S.tys }, "past", .{ 64, 1, 1 });
    const b2 = k2.binding();
    k2.store(.u32, kir.global(b2, 32), kir.u(4096), kir.u(1));
    try k2.finish();
    const bin2 = try kir_gcn4.compileWith(&k2, d.caps, &S.work, &S.out);
    const prog2 = try d.load(&bin2);
    const small = try d.alloc(64, .host);
    try std.testing.expectError(error.DeviceLost, d.runWait(&.{.{ .prog = &prog2, .groups = .{ 1, 1, 1 }, .buffers = &.{small}, .params = &.{} }}, 1_000_000));
}
