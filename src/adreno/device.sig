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

/// Why the last submission failed on the emulated GPU (EmuDevice.fault;
/// EmuDevice.describe puts it into words).
pub const Fault = struct {
    pub const Kind = enum { none, read, write, local, illegal, other };
    kind: Kind = .none,
    /// The emulator's error (error.Fault for an access outside every buffer).
    err: ?anyerror = null,
    /// Dispatches the submission ran before this one (0: its first).
    dispatch: u32 = 0,
    /// The kernel (its code's GPU address, SP_CS_BASE) and the instruction.
    code_va: u64 = 0,
    pc: u32 = 0,
    text_buf: [160]u8 = undefined,
    text_len: u8 = 0,
    /// read, write, local: the access's address and size, the fiber (its
    /// index in the workgroup) and the workgroup; `base` is the address the
    /// instruction starts from (its buffer: the one it meant to reach).
    va: u64 = 0,
    bytes: u32 = 0,
    fiber: u32 = 0,
    group: [3]u32 = .{ 0, 0, 0 },
    base: u64 = 0,
    /// illegal: the rule the instruction breaks, and the register involved.
    rule: []const u8 = "",
    reg: u16 = 0,

    pub fn text(f: *const Fault) []const u8 {
        return f.text_buf[0..f.text_len];
    }
};

/// An instruction the emulator would run but the hardware does not run as
/// written: ir3's operand rules (Mesa's ir3_valid_flags, read as
/// documentation) and the kernel's own declared limits.
pub const Illegal = struct {
    pc: u32,
    rule: []const u8,
    /// The register (or const) number the rule is about, when one is.
    reg: u16 = 0,
};

fn sharedNum(num: u16) bool {
    return num >= ir3.SHARED_BASE and num < ir3.A0_X;
}
fn isShared(s: ir3.Src) bool {
    return s.kind == .gpr and !s.half and sharedNum(s.num);
}
/// A source read through the uniform path: a const (plain or relative) or a
/// shared register.
fn isUniform(s: ir3.Src) bool {
    return s.kind == .cnst or s.kind == .rel_cnst or isShared(s);
}
fn isImm(s: ir3.Src) bool {
    return s.kind == .imm or s.kind == .flut;
}
/// An ordinary per-fiber register (full r0..r47, half hr0..hr47).
fn isPlain(s: ir3.Src) bool {
    return s.kind == .gpr and s.num < ir3.SHARED_BASE;
}
fn dstShared(in: *const ir3.Instr) bool {
    return !in.dst.half and !in.dst.rel and sharedNum(in.dst.num);
}

/// Check one decoded instruction against ir3's operand rules, the kernel's
/// constants (`constlen` vec4s) and its register footprint (`full_regs`
/// vec4s). The rules are those where the hardware is known to read
/// something other than what the instruction says, which the emulator would
/// run as written (and so hide).
pub fn checkInstr(gen: u16, in: *const ir3.Instr, pc: u32, constlen: u32, full_regs: u32) ?Illegal {
    const bad = struct {
        fn f(p: u32, rule: []const u8, reg: u16) ?Illegal {
            return .{ .pc = p, .rule = rule, .reg = reg };
        }
    }.f;
    const cat = in.op.category();
    const s0 = in.src[0];
    const s1 = in.src[1];
    const s2 = in.src[2];
    switch (cat) {
        2 => {
            // One read port for consts and shared registers: an instruction
            // with two such sources reads one of them in place of the other.
            if (!dstShared(in) and isUniform(s0) and isUniform(s1)) return bad(pc, "a cat2 instruction reads two sources from the const/shared file (the hardware hands one source's value to both)", s1.num);
            if (isImm(s0) and isImm(s1)) return bad(pc, "a cat2 instruction with two immediates", 0);
            if (dstShared(in) and (isPlain(s0) or isPlain(s1))) return bad(pc, "a shared destination computed from a per-fiber register", in.dst.num);
        },
        3 => {
            const alt = switch (in.op) {
                .shrm, .shlm, .shrg, .shlg, .andg => true,
                else => false,
            };
            const dot = switch (in.op) {
                .dp2acc, .dp4acc, .wmm, .wmm_accu => true,
                else => false,
            };
            if (!dstShared(in) and (s1.kind != .gpr or isShared(s1))) {
                if (s1.kind != .none) return bad(pc, "a cat3 instruction's second source must be a per-fiber register", s1.num);
            }
            for ([_]ir3.Src{ s0, s1, s2 }, 0..) |s, n| {
                if (s.kind == .cnst and (alt or dot)) return bad(pc, "shrm/shlm/shrg/shlg/andg and the dot products take no plain const", s.num);
                if (isImm(s) and (!alt or n == 1)) return bad(pc, "an immediate where this cat3 instruction has none", 0);
            }
            if (alt and !dstShared(in) and isShared(s0) and isShared(s1)) return bad(pc, "two shared registers among a cat3 instruction's first two sources", s1.num);
            if (dstShared(in)) for ([_]ir3.Src{ s0, s1, s2 }) |s| {
                if (isPlain(s)) return bad(pc, "a shared destination computed from a per-fiber register", in.dst.num);
            };
        },
        4 => {
            if (s0.kind == .cnst or s0.kind == .rel_cnst or isImm(s0)) return bad(pc, "an SFU (cat4) instruction reads no const or immediate", s0.num);
            if (isShared(s0) != dstShared(in)) return bad(pc, "an SFU (cat4) instruction's source and destination differ in being shared", s0.num);
        },
        6 => switch (in.op) {
            .ldg, .stg, .ldg_a, .stg_a => {
                const const_base = gen >= ir3.A7XX and (in.op == .ldg_a or in.op == .stg_a) and s0.kind == .cnst;
                if (!const_base and !isPlain(s0)) return bad(pc, "a global access's base must be a register pair (or, for ldg.a/stg.a on a7xx, a const pair)", s0.num);
                if ((in.op == .ldg_a or in.op == .stg_a) and !isPlain(s1)) return bad(pc, "ldg.a/stg.a's offset must be a per-fiber register", s1.num);
                if ((in.op == .stg or in.op == .stg_a) and !isPlain(s2)) return bad(pc, "a global store's value must be a per-fiber register", s2.num);
            },
            .ldl, .stl, .ldlw, .stlw => {
                if (!isPlain(s0)) return bad(pc, "a local access's address must be a per-fiber register", s0.num);
                if ((in.op == .stl or in.op == .stlw) and !isPlain(s1)) return bad(pc, "a local store's value must be a per-fiber register", s1.num);
            },
            .shfl => {
                if (!isPlain(s0)) return bad(pc, "shfl's value must be a per-fiber register", s0.num);
                if (s1.kind == .cnst or s1.kind == .rel_cnst) return bad(pc, "shfl's lane takes no const", s1.num);
            },
            else => {},
        },
        else => {},
    }
    // Constants past what the kernel declares are not loaded: garbage.
    const reps: u16 = if (cat >= 1 and cat <= 4) in.repeat else 0;
    for (in.src, 0..) |s, n| {
        if (s.kind != .cnst) continue;
        var last: u32 = s.num + (if (s.r) reps else 0);
        if (n == 0 and (in.op == .ldg_a or in.op == .stg_a)) last += 1; // (a 64-bit address)
        if (last >= constlen * 4) return bad(pc, "reads a const past the constants the kernel declares (its constlen)", @intCast(last));
    }
    // Registers past the footprint (SP_CS_CNTL_0) are not the fiber's own.
    if (footprintPast(in, full_regs)) |r| return bad(pc, "uses a register past the kernel's register footprint", r);
    return null;
}

/// The first plain register `in` touches at or past `full_regs` vec4s, or
/// a half register past hr47.w (merged registers: the halves alias
/// r0..r23 only; hr48 and up are not the fiber's).
fn footprintPast(in: *const ir3.Instr, full_regs: u32) ?u16 {
    const limit: u32 = full_regs * 4;
    const cat = in.op.category();
    const reps: u32 = if (cat >= 1 and cat <= 4) in.repeat else 0;
    const width: u32 = @max(in.size, 1);
    const Check = struct {
        fn reg(num: u16, half: bool, extra: u32, lim: u32) ?u16 {
            if (half) {
                if (num >= ir3.SHARED_BASE) return num;
                const last = num + extra;
                if (last >= ir3.SHARED_BASE) return num;
                if ((last >> 1) >= lim) return num;
                return null;
            }
            if (num >= ir3.SHARED_BASE) return null; // shared, a0, p0: not in the footprint
            if (num + extra >= lim) return num;
            return null;
        }
    };
    // destinations
    if (cat >= 1 and cat <= 4 and !in.dst.rel) {
        if (Check.reg(in.dst.num, in.dst.half, reps, limit)) |r| return r;
    }
    if (cat == 6) switch (in.op) {
        .ldg, .ldg_a, .ldl, .ldlw, .ldp, .ldc, .ldib_b, .shfl, .getfiberid, .getspid, .getwid => {
            const n = if (in.op == .shfl or in.op == .getfiberid or in.op == .getspid or in.op == .getwid) 0 else width - 1;
            if (Check.reg(in.dst.num, in.dst.half, n, limit)) |r| return r;
        },
        else => {},
    };
    // sources
    for (in.src, 0..) |s, n| {
        if (s.kind != .gpr) continue;
        var extra: u32 = if (s.r) reps else 0;
        if (cat == 6) {
            const pair = n == 0 and (in.op == .ldg or in.op == .ldg_a or in.op == .stg or in.op == .stg_a);
            if (pair) extra = 1;
            const value = (n == 2 and (in.op == .stg or in.op == .stg_a)) or (n == 1 and (in.op == .stl or in.op == .stlw));
            if (value) extra = width - 1;
        }
        if (Check.reg(s.num, s.half, extra, limit)) |r| return r;
    }
    return null;
}

/// Check an assembled kernel's instructions (decoded one at a time: no
/// storage) against its own constlen and footprint.
pub fn checkKernel(k: *const ir3_asm.Kernel) ?Illegal {
    return checkWords(k.gen, k.code[0..k.count], k.constlen, k.full_regs);
}

pub fn checkWords(gen: u16, code: []const u64, constlen: u32, full_regs: u32) ?Illegal {
    for (code, 0..) |w, pc| {
        const in = ir3.decode(gen, w) catch return .{ .pc = @intCast(pc), .rule = "an instruction word that does not decode" };
        if (checkInstr(gen, &in, @intCast(pc), constlen, full_regs)) |bad| return bad;
    }
    return null;
}

/// Caller-owned state of an emulated GPU (static: it holds the emulator).
///
/// Strict, so that what the hardware would fault on fails here too:
/// - every buffer sits alone in GPU address space (`guard` bytes of nothing
///   after it, more than a 32-bit offset reaches), so an access from a
///   buffer's address that leaves it reaches no other buffer: it faults,
///   and `fault` names the kernel, the instruction, the fiber and the
///   address (`describe`);
/// - each dispatch's code is checked first (`check_operands`) against ir3's
///   operand rules, its constlen and its register footprint (checkInstr):
///   what the emulator would run as written but the GPU would not.
pub const EmuDevice = struct {
    /// Memory buffers come from (bump-allocated; GPU addresses from
    /// va_base, each buffer followed by `guard` bytes of unmapped space).
    arena: []u8,
    used: usize = 0,
    va_base: u64 = 0x1_0000_0000,
    /// Unmapped GPU address space after each buffer: 8 GiB, past what a
    /// base address plus a 32-bit offset reaches. (4096 is Galaxy's
    /// driver's layout; 0 packs buffers together.)
    guard: u64 = 1 << 33,
    next_va: u64 = 0,
    regions: [EMU_MAX_BUFFERS]ir3_emu.Region = undefined,
    n_regions: usize = 0,
    /// Check each dispatch's code before running it (checkInstr).
    check_operands: bool = true,
    /// Why the last submission failed (kind .none when it did not).
    fault: Fault = .{},
    /// Dispatches the current submission has run.
    dispatches: u32 = 0,
    /// With group_stride > 1, also run the last workgroup in x (where a
    /// grid's bounds are): a sampled run then still checks every edge.
    sample_last: bool = false,
    /// Called with describe()'s text when a submission fails.
    log: ?*const fn (line: []const u8) void = null,
    /// Run a cat2 instruction with a const and a shared-register source
    /// the way the Surface's Adreno evidently does (the adreno1 boot's
    /// fault): the const's value for both. Off by default, and moot with
    /// check_operands on (such code is refused first): for reproducing
    /// what the hardware did with code that breaks the rule.
    uniform_port_quirk: bool = false,
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
        const va = if (e.n_regions == 0 or e.next_va == 0) e.va_base + at else e.next_va;
        e.next_va = std.mem.alignForward(u64, va + size, 4096) + e.guard;
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
        e.fault = .{};
        e.dispatches = 0;
        e.execute(ib.va, dwords, 0) catch |err| {
            e.last_error = err;
            if (e.fault.kind == .none) {
                e.fault.kind = .other;
                e.fault.err = err;
            }
            if (e.log) |log| {
                var buf: [512]u8 = undefined;
                log(e.describe(null, &buf));
            }
        };
        return e.fence;
    }

    /// The last failure in words: what was accessed (or broken), where, by
    /// which kernel and instruction. `name` names the kernel (a caller that
    /// knows its kernels' code addresses); null gives its code address.
    pub fn describe(e: *const EmuDevice, name: ?[]const u8, buf: []u8) []const u8 {
        const f = &e.fault;
        var t = ir3.Text{ .buf = buf };
        const kernel = struct {
            fn put(tx: *ir3.Text, n: ?[]const u8, va: u64) void {
                if (n) |s| tx.print("kernel {s}", .{s}) else tx.print("the kernel at 0x{x}", .{va});
            }
        }.put;
        switch (f.kind) {
            .none => t.s("no failure"),
            .read, .write, .local => {
                const what = switch (f.kind) {
                    .read => "read",
                    .write => "write",
                    else => "local memory access",
                };
                t.print("{s} of {d} bytes at 0x{x}", .{ what, f.bytes, f.va });
                if (f.kind != .local) {
                    t.s(" outside every buffer");
                    if (e.regionAt(f.base)) |r| {
                        const end = r.va + r.bytes.len;
                        if (f.va >= end) {
                            t.print(" ({d} bytes past the end of the {d}-byte buffer at 0x{x} that its base 0x{x} is in)", .{ f.va + f.bytes - end, r.bytes.len, r.va, f.base });
                        } else t.print(" ({d} bytes before the {d}-byte buffer at 0x{x} that its base 0x{x} is in)", .{ r.va - f.va, r.bytes.len, r.va, f.base });
                    } else t.print(" (its base 0x{x} is in no buffer)", .{f.base});
                }
                t.s(" by ");
                kernel(&t, name, f.code_va);
                t.print(" (dispatch {d} of its submission), instruction {d}: {s}; fiber {d} of workgroup ({d}, {d}, {d})", .{ f.dispatch, f.pc, f.text(), f.fiber, f.group[0], f.group[1], f.group[2] });
            },
            .illegal => {
                kernel(&t, name, f.code_va);
                t.print(" (dispatch {d} of its submission), instruction {d}: {s}: {s} (register/const {d})", .{ f.dispatch, f.pc, f.text(), f.rule, f.reg });
            },
            .other => {
                t.s(if (f.err) |x| @errorName(x) else "?");
                if (f.code_va != 0) {
                    t.s(" in ");
                    kernel(&t, name, f.code_va);
                    t.print(" (dispatch {d} of its submission), instruction {d}: {s}", .{ f.dispatch, f.pc, f.text() });
                }
            },
        }
        return t.buf[0..t.len];
    }

    fn regionAt(e: *const EmuDevice, va: u64) ?ir3_emu.Region {
        for (e.regions[0..e.n_regions]) |r| {
            if (va >= r.va and va < r.va + @max(r.bytes.len, 1)) return r;
        }
        return null;
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
        e.fault.dispatch = e.dispatches;
        e.fault.code_va = code_va;
        // What the GPU would not run as the emulator does: refused first.
        if (e.check_operands) {
            if (checkWords(k.gen, code, k.constlen, k.full_regs)) |bad| {
                e.fault.kind = .illegal;
                e.fault.err = error.IllegalInstruction;
                e.fault.pc = bad.pc;
                e.fault.rule = bad.rule;
                e.fault.reg = bad.reg;
                if (ir3.decode(k.gen, code[bad.pc])) |in| e.setText(&in) else |_| e.setText(null);
                return error.IllegalInstruction;
            }
        }
        // (the padding after `end` decodes to nops and never runs)
        try ir3_emu.load(&e.emu, &k);
        if (e.uniform_port_quirk) for (e.emu.code[0..e.emu.n_code]) |*in| {
            if (in.op.category() != 2) continue;
            const a = in.src[0];
            const b = in.src[1];
            if (a.kind == .cnst and isShared(b)) {
                in.src[1].kind = .cnst;
                in.src[1].num = a.num;
            } else if (b.kind == .cnst and isShared(a)) {
                in.src[0].kind = .cnst;
                in.src[0].num = b.num;
            }
        };
        const d = ir3_emu.Dispatch{ .kernel = &k, .consts = &e.consts, .groups = groups, .group_stride = e.group_stride };
        ir3_emu.run(&e.emu, &m, &d, &e.stats) catch |err| return e.failedRun(&k, &m, err);
        if (e.sample_last and e.group_stride > 1 and groups[0] > 1 and (groups[0] - 1) % e.group_stride != 0) {
            const last = ir3_emu.Dispatch{ .kernel = &k, .consts = &e.consts, .groups = groups, .first_group = groups[0] - 1, .group_stride = 1 };
            ir3_emu.run(&e.emu, &m, &last, &e.stats) catch |err| return e.failedRun(&k, &m, err);
        }
        e.fault.code_va = 0;
        e.dispatches += 1;
    }

    fn setText(e: *EmuDevice, in: ?*const ir3.Instr) void {
        const f = &e.fault;
        const s: []const u8 = if (in) |i| (ir3.format(ir3.A7XX, i, &f.text_buf) catch "?") else "?";
        if (s.ptr != &f.text_buf) @memcpy(f.text_buf[0..s.len], s);
        f.text_len = @intCast(@min(s.len, f.text_buf.len));
    }

    /// A dispatch the emulator stopped: which instruction, and for an
    /// access outside every buffer, which fiber went where.
    fn failedRun(e: *EmuDevice, k: *const ir3_asm.Kernel, m: *const ir3_emu.Memory, err: anyerror) anyerror {
        const w = &e.emu;
        const f = &e.fault;
        f.err = err;
        f.kind = .other;
        f.pc = w.err_pc;
        if (w.err_pc >= w.n_code) return err;
        const in = &w.code[w.err_pc];
        e.setText(in);
        if (err == error.Fault) e.findAccess(k, m, in);
        return err;
    }

    fn findAccess(e: *EmuDevice, k: *const ir3_asm.Kernel, m: *const ir3_emu.Memory, in: *const ir3.Instr) void {
        const w = &e.emu;
        const f = &e.fault;
        const lsz: u32 = @as(u32, k.local_size[0]) * k.local_size[1] * k.local_size[2];
        const ts: u32 = k.threadsize;
        const nf = @min(((lsz + ts - 1) / ts) * ts, ir3_emu.MAX_FIBERS);
        const tb: u32 = switch (in.ty) {
            .f32, .u32, .s32 => 4,
            .f16, .u16, .s16 => 2,
            else => 1,
        };
        const n = tb * @max(in.size, 1);
        const local = in.op == .ldl or in.op == .stl;
        const store = in.op == .stg or in.op == .stg_a or in.op == .stl;
        for (0..nf) |fi| {
            if (w.st[fi] != .run or w.pc[fi] != f.pc) continue;
            const wave: u32 = @intCast(fi / ts);
            const reg = struct {
                fn get(ww: *const ir3_emu.Work, fiber: usize, wv: u32, num: u16) u32 {
                    if (num < ir3_emu.NREGS) return ww.regs[fiber][num];
                    if (sharedNum(num)) return ww.shared[wv][num - ir3.SHARED_BASE];
                    return 0;
                }
            }.get;
            var va: u64 = 0;
            var outside = false;
            if (local) {
                const a: i64 = @as(i64, reg(w, fi, wave, in.src[0].num)) + in.off;
                outside = a < 0 or a + n > ir3_emu.LOCAL_BYTES;
                va = @bitCast(a);
            } else {
                const s0 = in.src[0];
                const base: u64 = if (s0.kind == .cnst)
                    (if (s0.num + 1 < e.consts.len) @as(u64, e.consts[s0.num + 1]) << 32 | e.consts[s0.num] else 0)
                else
                    @as(u64, reg(w, fi, wave, s0.num + 1)) << 32 | reg(w, fi, wave, s0.num);
                va = switch (in.op) {
                    .ldg_a, .stg_a => base +% reg(w, fi, wave, in.src[1].num) +% @as(u64, @intCast(@max(in.off, 0))),
                    else => base +% @as(u64, @bitCast(@as(i64, in.off))),
                };
                f.base = base;
                outside = m.find(va, n) == null;
            }
            if (!outside) continue;
            f.kind = if (local) .local else if (store) .write else .read;
            f.va = va;
            f.bytes = n;
            f.fiber = @intCast(fi);
            if (k.wgid_reg != ir3_asm.INVALID_REG and k.wgid_reg >= ir3.SHARED_BASE) {
                const g = k.wgid_reg - ir3.SHARED_BASE;
                f.group = .{ w.shared[wave][g], w.shared[wave][g + 1], w.shared[wave][g + 2] };
            }
            return;
        }
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

test "an access past a buffer's end faults, naming the kernel, the instruction, the fiber and the address" {
    const S = struct {
        var arena: [1 << 20]u8 align(4096) = undefined;
        var dev: EmuDevice = undefined;
        var asm_work: ir3_asm.Work = .{};
    };
    S.dev = .{ .arena = &S.arena };
    const d = S.dev.device();
    const code_buf = try d.alloc(4096);
    const out = try d.alloc(4096);
    // (packed, the next buffer would start where `out` ends: the store past
    // it would land there unseen)
    const ib = try d.alloc(4096);
    try std.testing.expect(ib.va >= out.va + 4096 + (1 << 32));
    const code: []u64 = @alignCast(std.mem.bytesAsSlice(u64, code_buf.cpu));
    const k = try ir3_asm.assemble(ir3.A7XX,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\shl.b r1.y, r0.x, 7
        \\stg.a.u32 g[c0.x+r1.y+0], r0.x, 1
        \\end
    , &S.asm_work, code);
    var s = a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code_buf.va);
    s.constants(0, &.{ @truncate(out.va), @truncate(out.va >> 32), 0, 0 });
    s.dispatch(&k, .{ 2, 1, 1 });
    s.waitForIdle();
    try s.check();
    try std.testing.expectError(error.DeviceLost, d.run(ib, @intCast(s.len), 1_000_000));
    const f = &S.dev.fault;
    try std.testing.expectEqual(Fault.Kind.write, f.kind);
    try std.testing.expectEqual(out.va + 4096, f.va);
    try std.testing.expectEqual(@as(u32, 32), f.fiber);
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, f.group);
    try std.testing.expectEqual(code_buf.va, f.code_va);
    try std.testing.expectEqual(out.va, f.base);
    var buf: [512]u8 = undefined;
    const line = S.dev.describe("store", &buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "write of 4 bytes at") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "kernel store") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "stg.a.u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "4 bytes past the end of the 4096-byte buffer") != null);
}

test "an operand the hardware reads differently is refused before the kernel runs" {
    const S = struct {
        var arena: [1 << 20]u8 align(4096) = undefined;
        var dev: EmuDevice = undefined;
        var asm_work: ir3_asm.Work = .{};
    };
    S.dev = .{ .arena = &S.arena };
    const d = S.dev.device();
    const code_buf = try d.alloc(4096);
    const out = try d.alloc(4096);
    const ib = try d.alloc(4096);
    const code: []u64 = @alignCast(std.mem.bytesAsSlice(u64, code_buf.cpu));
    // r48.y (shared: the workgroup's y) times c0.z (a const): one read port
    const k = try ir3_asm.assemble(ir3.A7XX,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\shl.b r1.y, r0.x, 2
        \\mul.u24 r1.x, r48.y, c0.z
        \\stg.a.u32 g[c0.x+r1.y+0], r1.x, 1
        \\end
    , &S.asm_work, code);
    const bad = checkKernel(&k) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, bad.rule, "const/shared") != null);
    var s = a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code_buf.va);
    s.constants(0, &.{ @truncate(out.va), @truncate(out.va >> 32), 3, 0 });
    s.dispatch(&k, .{ 1, 2, 1 });
    s.waitForIdle();
    try s.check();
    try std.testing.expectError(error.DeviceLost, d.run(ib, @intCast(s.len), 1_000_000));
    try std.testing.expectEqual(Fault.Kind.illegal, S.dev.fault.kind);
    try std.testing.expectEqual(bad.pc, S.dev.fault.pc);
    var buf: [512]u8 = undefined;
    const line = S.dev.describe(null, &buf);
    try std.testing.expect(std.mem.indexOf(u8, line, "mul.u24") != null);
    // The same through a register first: what the hardware runs as written.
    const k2 = try ir3_asm.assemble(ir3.A7XX,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\shl.b r1.y, r0.x, 2
        \\mov.u32u32 r1.x, r48.y
        \\mul.u24 r1.x, r1.x, c0.z
        \\stg.a.u32 g[c0.x+r1.y+0], r1.x, 1
        \\end
    , &S.asm_work, code);
    try std.testing.expectEqual(@as(?Illegal, null), checkKernel(&k2));
    d.toDevice(code_buf, 0, k2.code.len * 8);
    s = a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k2, code_buf.va);
    s.constants(0, &.{ @truncate(out.va), @truncate(out.va >> 32), 3, 0 });
    s.dispatch(&k2, .{ 1, 1, 1 });
    s.waitForIdle();
    try s.check();
    try d.run(ib, @intCast(s.len), 1_000_000);
}

test "ir3's operand rules: what the hardware reads as written, and what it does not" {
    const legal = [_][]const u8{
        "mul.u24 r1.x, r48.y, 7",
        "mul.u24 r1.x, c3.x, 5",
        "add.u r1.x, r48.x, r0.x",
        "add.u r1.x, c4.w, r0.y",
        "cmps.u.ne r1.x, c5.w, 0",
        "mov.u32u32 r1.x, r48.y",
        "mov.u32u32 r1.x, c2.z",
        "shrm r1.x, 6, r0.x, 255",
        "mad.f32 r1.x, r0.x, r0.y, r0.z",
        "rcp r1.x, r0.x",
        "shfl.xor.u32 r1.x, r0.x, 4",
        "ldg.a.f32 r1.x, g[c0.x+r0.y+16], 1",
    };
    for (legal) |l| {
        const in = try ir3.decode(ir3.A7XX, try ir3.assembleLine(ir3.A7XX, l));
        if (checkInstr(ir3.A7XX, &in, 0, 8, 4)) |bad| {
            std.debug.print("{s}: refused: {s}\n", .{ l, bad.rule });
            return error.TestUnexpectedResult;
        }
    }
    const illegal = [_][]const u8{
        "mul.u24 r1.x, r48.y, c3.x",
        "mul.u24 r1.x, c3.x, r48.y",
        "add.u r1.x, c3.z, c3.w",
        "add.u r1.x, r48.x, r48.y",
        "rcp r1.x, c0.x",
        "add.u r1.x, r0.x, c9.x", // past constlen 8
        "add.u r5.x, r0.x, r0.y", // past a footprint of 4
        "ldg.a.f32 r3.x, g[c0.x+r0.y+0], 4", // r3.x..r3.w: inside; then r4: below
    };
    for (illegal[0..7]) |l| {
        const in = try ir3.decode(ir3.A7XX, try ir3.assembleLine(ir3.A7XX, l));
        if (checkInstr(ir3.A7XX, &in, 0, 8, 4) == null) {
            std.debug.print("{s}: let through\n", .{l});
            return error.TestUnexpectedResult;
        }
    }
    const wide = try ir3.decode(ir3.A7XX, try ir3.assembleLine(ir3.A7XX, illegal[7]));
    try std.testing.expectEqual(@as(?Illegal, null), checkInstr(ir3.A7XX, &wide, 0, 8, 4));
    try std.testing.expect(checkInstr(ir3.A7XX, &wide, 0, 8, 3) != null);
}
