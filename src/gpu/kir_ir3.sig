//! @zpm/gpu kir_ir3 — KIR kernels compiled for the Adreno's ir3 ISA (a7xx:
//! the Surface Laptop 13's X1-45).
//!
//! The kernel goes through these steps, all in the caller's Work:
//!   1. fdiv and fsqrt are replaced by kir's exact expansions (given Caps);
//!   2. analysis: definitions and uses per register, value bounds (so a
//!      multiply of small values is mul.u24/mul.s24, not the three-step
//!      32-bit product), uniformity (a shuffle's mask or delta must be the
//!      same on every fiber), and the patterns ir3 has single instructions
//!      for (shift-and-mask shrm/shlm, shift-or shrg/shlg, and-or andg, a
//!      compare feeding a branch straight into p0.x);
//!   3. lowering to machine instructions over virtual registers: the
//!      parameter block, the constants that do not fit an immediate, and the
//!      group sizes live in the constant file; ids come from where the
//!      hardware puts them (r0.x local ids, r48.x group ids); structured
//!      control flow becomes br/jump with (jp) where fibers reconverge;
//!   4. list scheduling inside each block, so independent work fills the
//!      delay slots (a7xx: 2 between ALU results, 5 before memory reads them);
//!   5. register allocation: linear scan over full and half registers (the
//!      merged file: hrN.c is half of r(N.c / 2)), live ranges stretched over
//!      every loop they cross, vectors in consecutive registers;
//!   6. ir3 assembly text, which ir3_asm legalizes ((ss)/(sy), nops, (jp))
//!      and encodes.
//!
//! The output is the instruction words, then the constant pool the dispatch
//! loads (see Config: Binary.extra says where everything is).
//!
//! Exactness: fadd/fsub/fmul are add.f/mul.f (IEEE on the Adreno; the
//! bring-up self-test checks), fmad is mad.f32 (rounded as the GPU's mad,
//! Caps.mad), ffma only where Caps.fused_fma; float to integer conversions
//! saturate and send NaN to 0 explicitly, whatever the GPU's own cov does.
//!
//! Allocation-free: Work is several MB (keep it static); the output goes to
//! the caller's buffer.

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const adreno = @import("adreno");
const ir3 = adreno.ir3;
const ir3_asm = adreno.ir3_asm;

pub const MAX_KIR = 16384;
pub const MAX_VREGS = 16384;
pub const MAX_MI = ir3_asm.MAX_INSTRS;
pub const MAX_PROLOGUE = 256;
pub const MAX_LOOPS = 256;
pub const MAX_POOL = 512;
pub const MAX_CACHED = 128;
pub const TEXT_BYTES = 768 * 1024;
/// Units of the register file: half registers (full rN.c = units 2(4N+c), +1).
const UNITS = 384;
/// Half registers live in the first 192 units (hr0.x..hr47.w): in the
/// merged file they alias r0..r23 only, and hr48 and up are not the fiber's
/// (adreno.device.checkInstr's footprint rule).
const HALF_UNITS = 192;

pub const Error = kir.Error || ir3_asm.Error || error{ Unsupported, TooComplex, OutOfMemory };

/// Float-to-integer cvt as one cov (after the rounding op), trusting the
/// GPU's cov to saturate and send NaN to 0 as KIR defines: the emulator
/// does, and the bring-up self-test's "edges" case checks the Adreno (the
/// hand-written kernels rely on cov the same way). False: an explicit
/// clamp and NaN check (six more instructions per conversion).
pub var trust_cov_saturation: bool = true;

const NONE: u16 = 0xffff;
/// A "virtual register" with this bit set is the physical register number
/// in its low bits (r0.x local ids, r48.x group ids, p0.x).
const PHYS: u16 = 0x8000;
const NOWHERE: u32 = std.math.maxInt(u32);

fn isPhys(v: u16) bool {
    return v != NONE and v & PHYS != 0;
}

// ── What the dispatch needs (Binary.extra) ──────────────────────────────────

/// The ir3 kernel's configuration, kept in Binary.extra.
pub const Config = struct {
    gen: u16 = ir3.A7XX,
    /// Instruction words (padded to instrlen * 16) at the start of the code.
    instrlen: u32 = 0,
    count: u32 = 0,
    localid_reg: u8 = ir3_asm.INVALID_REG,
    wgid_reg: u8 = ir3_asm.INVALID_REG,
    full_regs: u8 = 0,
    half_regs: u8 = 0,
    /// vec4 constants the kernel reads.
    constlen: u16 = 0,
    branchstack: u8 = 0,
    threadsize: u8 = 64,
    /// Constant layout (dwords): binding addresses from 0, then the
    /// parameter words; the group counts at `drv` (when `uses_drv`); the
    /// pool at `pool` (vec4-aligned), `pool_words` long, stored in the code
    /// buffer at byte `pool_offset`.
    params: u16 = 0,
    drv: u16 = 0,
    uses_drv: bool = false,
    pool: u16 = 0,
    pool_words: u16 = 0,
    pool_offset: u32 = 0,
    /// Bytes of instruction words.
    code_bytes: u32 = 0,
    /// Shared memory: the kernel's, plus the shuffle exchange area.
    shared_bytes: u32 = 0,

    pub fn toExtra(c: Config) [16]u32 {
        var e = [_]u32{0} ** 16;
        e[0] = c.gen;
        e[1] = c.instrlen;
        e[2] = c.count;
        e[3] = @as(u32, c.localid_reg) | @as(u32, c.wgid_reg) << 8 | @as(u32, c.full_regs) << 16 | @as(u32, c.half_regs) << 24;
        e[4] = @as(u32, c.constlen) | @as(u32, c.branchstack) << 16 | @as(u32, c.threadsize) << 24;
        e[5] = @as(u32, c.params) | @as(u32, c.drv) << 16;
        e[6] = @as(u32, c.pool) | @as(u32, c.pool_words) << 16;
        e[7] = c.pool_offset;
        e[8] = c.code_bytes;
        e[9] = @intFromBool(c.uses_drv);
        e[10] = c.shared_bytes;
        e[15] = 0x1a3c0de; // a mark: this is an ir3 binary
        return e;
    }

    pub fn fromExtra(e: [16]u32) ?Config {
        if (e[15] != 0x1a3c0de) return null;
        return .{
            .gen = @intCast(e[0]),
            .instrlen = e[1],
            .count = e[2],
            .localid_reg = @truncate(e[3]),
            .wgid_reg = @truncate(e[3] >> 8),
            .full_regs = @truncate(e[3] >> 16),
            .half_regs = @truncate(e[3] >> 24),
            .constlen = @truncate(e[4]),
            .branchstack = @truncate(e[4] >> 16),
            .threadsize = @truncate(e[4] >> 24),
            .params = @truncate(e[5]),
            .drv = @truncate(e[5] >> 16),
            .pool = @truncate(e[6]),
            .pool_words = @truncate(e[6] >> 16),
            .pool_offset = e[7],
            .code_bytes = e[8],
            .uses_drv = e[9] & 1 != 0,
            .shared_bytes = e[10],
        };
    }

    /// The assembler's view (what a7xx.Stream.program and ir3_emu take).
    pub fn kernel(c: Config, bin: *const device.Binary, code: []const u64) ir3_asm.Kernel {
        return .{
            .gen = c.gen,
            .code = code,
            .count = c.count,
            .instrlen = c.instrlen,
            .local_size = .{ @intCast(bin.group[0]), @intCast(bin.group[1]), @intCast(bin.group[2]) },
            .localid_reg = c.localid_reg,
            .wgid_reg = c.wgid_reg,
            .full_regs = c.full_regs,
            .half_regs = c.half_regs,
            .constlen = c.constlen,
            .branchstack = c.branchstack,
            .shared_bytes = c.shared_bytes,
            .threadsize = c.threadsize,
        };
    }

    /// The constant words before the pool: binding addresses, parameters,
    /// group counts. `out` must hold `c.pool` words (or `c.drv + 4`).
    pub fn constants(c: Config, buffers: []const u64, params: []const u32, groups: [3]u32, out: []u32) []u32 {
        const n: usize = if (c.pool_words > 0) c.pool else if (c.uses_drv) @as(usize, c.drv) + 4 else std.mem.alignForward(usize, @as(usize, c.params) + params.len, 4);
        const w = out[0..@max(n, 4)];
        @memset(w, 0);
        for (buffers, 0..) |b, i| {
            w[2 * i] = @truncate(b);
            w[2 * i + 1] = @truncate(b >> 32);
        }
        for (params, 0..) |p, i| w[c.params + i] = p;
        if (c.uses_drv) for (0..3) |i| {
            w[c.drv + i] = groups[i];
        };
        return w;
    }
};

// ── Machine instructions over virtual registers ─────────────────────────────

const OK = enum(u8) { none, vreg, imm, cnst, flut };

/// An operand: a (virtual or physical) register, an immediate, a constant
/// register or a float-table entry, with its modifiers.
const Opnd = struct {
    k: OK = .none,
    v: u16 = NONE,
    x: u32 = 0,
    half: bool = false,
    neg: bool = false,
    abs: bool = false,
    bnot: bool = false,
    /// A full register read as a half: 1 its low half, 2 its high half.
    view: u2 = 0,

    fn reg(v: u16, half: bool) Opnd {
        return .{ .k = .vreg, .v = v, .half = half };
    }
    fn imm(x: u32) Opnd {
        return .{ .k = .imm, .x = x };
    }
    fn cnst(num: u16) Opnd {
        return .{ .k = .cnst, .x = num };
    }
};

const MKind = enum(u8) { op, copy, label, branch };

const MI = struct {
    in: ir3.Instr = .{},
    kind: MKind = .op,
    /// Registers written: dst .. dst + dn - 1.
    dst: u16 = NONE,
    dn: u8 = 1,
    /// The register behind in.src[i] (kind gpr), and how many consecutive.
    src: [4]u16 = .{ NONE, NONE, NONE, NONE },
    sn: [4]u8 = .{ 1, 1, 1, 1 },
    /// Label id (label) or branch target (branch).
    label: u16 = NONE,
    /// Sources stay live past the write (memory results).
    early: bool = false,
    /// Per source: a half view of a full register (Opnd.view).
    view: [4]u2 = .{ 0, 0, 0, 0 },
};

const Class = enum(u2) { full, half };

const VInfo = struct {
    cls: Class = .full,
    ty: kir.Ty = .u32,
    // KIR facts
    defs: u16 = 0,
    uses: u16 = 0,
    def_at: u32 = NOWHERE,
    /// Bounds of an integer value with one definition (as the integer its
    /// bits mean in `ty`), else the type's range.
    lo: i64 = 0,
    hi: i64 = 0,
    known: bool = false,
    uniform: bool = true,
    /// Stands for this operand (ids, parameters, the subgroup size): no
    /// instruction defines it.
    alias: Opnd = .{},
    // Machine level
    first: u32 = NOWHERE,
    last: u32 = 0,
    unit: u16 = NONE,
    /// Vector ranges: the range's first register and length (on the first).
    head: u16 = NONE,
    len: u16 = 1,
    hint: u16 = NONE,
    /// Read as a half register somewhere: lives in r0..r31 (hr0..hr63).
    low: bool = false,
    /// The first position that writes it (machine level).
    fdef: u32 = NOWHERE,
};

const Loop = struct { head: u32, end: u32, depth: u16 };

const Ctl = struct {
    kind: enum { if_, loop },
    l1: u16 = NONE, // if: else-or-end; loop: head
    l2: u16 = NONE, // if: end (after else); loop: latch
    l3: u16 = NONE, // loop: exit
    has_else: bool = false,
    used_latch: bool = false,
    loop_index: u16 = 0,
    head_mi: u32 = 0,
};

const Fuse = enum(u8) { none, skip, shrm, shlm, shrg, shlg, andg, branch, imad, half_lo, half_hi };

const Cached = struct { key: Opnd, v: u16 };

/// Caller-owned working storage (several MB: keep it static).
pub const Work = struct {
    insts: [MAX_KIR]kir.Inst = undefined,
    tys: [MAX_VREGS]kir.Ty = undefined,
    n_insts: u32 = 0,
    nv: u32 = 0,
    vi: [MAX_VREGS]VInfo = undefined,
    fuse: [MAX_KIR]Fuse = undefined,
    /// For fused ops: the KIR instruction folded in.
    fuse_with: [MAX_KIR]u32 = undefined,
    in_loop: [MAX_KIR]u16 = undefined,
    mi: [MAX_MI]MI = undefined,
    n_mi: u32 = 0,
    pro: [MAX_PROLOGUE]MI = undefined,
    n_pro: u32 = 0,
    tmp_mi: [SCHED_WINDOW]MI = undefined,
    loops: [MAX_LOOPS]Loop = undefined,
    n_loops: u32 = 0,
    n_labels: u32 = 0,
    ctl: [64]Ctl = undefined,
    n_ctl: u32 = 0,
    max_depth: u32 = 0,
    pool: [MAX_POOL]u32 = undefined,
    n_pool: u32 = 0,
    cached: [MAX_CACHED]Cached = undefined,
    n_cached: u32 = 0,
    // scheduling
    sched_order: [SCHED_WINDOW]u16 = undefined,
    sched_prio: [SCHED_WINDOW]u32 = undefined,
    sched_npred: [SCHED_WINDOW]u16 = undefined,
    sched_ready: [SCHED_WINDOW]u32 = undefined,
    sched_done: [SCHED_WINDOW]bool = undefined,
    sched_succ: [SCHED_WINDOW][DEP_WORDS]u64 = undefined,
    /// Reads of each register: all of them still to come, and in the window.
    use_total: [MAX_VREGS]u16 = undefined,
    use_win: [MAX_VREGS]u16 = undefined,
    // allocation
    by_start: [MAX_VREGS]u16 = undefined,
    active: [MAX_VREGS]u16 = undefined,
    // output
    text: [TEXT_BYTES]u8 = undefined,
    text_len: usize = 0,
    asm_work: ir3_asm.Work = .{},
    code: [ir3_asm.MAX_INSTRS + 64]u64 = undefined,
    // the kernel being compiled
    caps: device.Caps = undefined,
    group: [3]u32 = .{ 1, 1, 1 },
    bindings: u32 = 0,
    param_words: u32 = 0,
    shared_bytes: u32 = 0,
    exchange_at: u32 = 0,
    linear_tid: u16 = NONE,
    uses_exchange: bool = false,
    uses_tid: bool = false,
    uses_gid: bool = false,
    uses_drv: bool = false,
    params_at: u32 = 0,
    drv_at: u32 = 0,
    pool_at: u32 = 0,
    ret_label: u16 = NONE,
    uses_ret: bool = false,
    threadsize: u32 = 64,
    gen: u16 = ir3.A7XX,
    /// Instruction counts of the last compile (for tests and logs).
    stats: Stats = .{},
    diag: [256]u8 = undefined,
    diag_len: usize = 0,
    /// The live registers past which the scheduler favours freeing them.
    sched_pressure: i32 = SCHED_PRESSURE,
};

pub const Stats = struct {
    /// Machine instructions before legalization (no nops), and after.
    instructions: u32 = 0,
    legalized: u32 = 0,
    full_regs: u32 = 0,
    half_regs: u32 = 0,
    constants: u32 = 0,
};

// ── Entry point ─────────────────────────────────────────────────────────────

/// The bytes of device.Work compile needs.
pub const WORK_BYTES = @sizeOf(Work) + @alignOf(Work);

/// Compile `k` for the Adreno (caps.target ir3_a7xx), its Work taken from
/// `work` (WORK_BYTES) and given back. The Binary's code is a slice of
/// `out`: instruction words, then the constant pool.
pub fn compile(k: *const kir.Kernel, caps: device.Caps, work: *device.Work, out: []u8) Error!device.Binary {
    const m = work.mark();
    defer work.release(m);
    const w = work.take(Work, 1) orelse return error.OutOfMemory;
    return compileWith(k, caps, &w[0], out);
}

/// compile, with a Work of the caller's (static).
pub fn compileWith(k: *const kir.Kernel, caps: device.Caps, w: *Work, out: []u8) Error!device.Binary {
    w.diag_len = 0;
    if (k.err) |e| return e;
    w.caps = caps;
    w.gen = ir3.A7XX;
    w.threadsize = caps.subgroup;
    if (w.threadsize != 64 and w.threadsize != 128) return error.Unsupported;
    w.group = k.group;
    if (k.group[0] == 0 or k.group[1] == 0 or k.group[2] == 0) return error.BadOperand;
    if (k.group[0] > 1024 or k.group[1] > 1024 or k.group[2] > 64) return error.Unsupported;
    if (k.group[0] * k.group[1] * k.group[2] > 1024) return error.Unsupported;
    w.bindings = k.bindings;
    w.param_words = k.param_words;
    w.shared_bytes = k.shared_bytes;
    // All of a group's waves must be resident at once: a footprint that
    // keeps fewer cannot launch (ir3_emu.maxWaves, Mesa's a7xx formula).
    // Tighter scheduling first; then the group is too big for the kernel.
    const threads = k.group[0] * k.group[1] * k.group[2];
    var last: device.Binary = undefined;
    for ([_]i32{ SCHED_PRESSURE, 16, 0 }) |pressure| {
        w.sched_pressure = pressure;
        try expand(w, k);
        try analyze(w);
        try lower(w);
        schedule(w);
        try allocate(w);
        try emitText(w);
        last = try assembleOut(w, k, out);
        const cfg = Config.fromExtra(last.extra).?;
        if (adreno.ir3_emu.groupFits(w.gen, cfg.full_regs, w.threadsize, threads)) return last;
    }
    const cfg = Config.fromExtra(last.extra).?;
    note(w, "a group of {d} threads needs {d} waves of {d} resident; {d} vec4 registers keep {d} (a7xx): use smaller groups", .{ threads, (threads + w.threadsize - 1) / w.threadsize, w.threadsize, cfg.full_regs, adreno.ir3_emu.maxWaves(w.gen, cfg.full_regs, w.threadsize) });
    return error.TooManyRegs;
}

/// Why the last compile failed, when the backend knows more than the
/// error (the instruction it could not print or assemble); empty otherwise.
pub fn diagnostic(w: *const Work) []const u8 {
    return w.diag[0..w.diag_len];
}

fn note(w: *Work, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&w.diag, fmt, args) catch w.diag[0..];
    w.diag_len = s.len;
}

/// The last compile's assembly (legalized, as the GPU gets it).
pub fn listing(w: *const Work, buf: []u8) []const u8 {
    return ir3_asm.listing(&w.asm_work, w.gen, buf);
}

/// The text given to the assembler (before legalization).
pub fn source(w: *const Work) []const u8 {
    return w.text[0..w.text_len];
}

// ── 1. Expansion (fdiv, fsqrt) ──────────────────────────────────────────────

fn expand(w: *Work, k: *const kir.Kernel) Error!void {
    if (k.n > MAX_KIR) return error.TooManyInsts;
    if (k.nv > MAX_VREGS) return error.TooManyRegs;
    var has = false;
    for (k.insts[0..k.n]) |in| {
        if (in.op == .fdiv or in.op == .fsqrt) has = true;
    }
    if (!has) {
        @memcpy(w.insts[0..k.n], k.insts[0..k.n]);
        @memcpy(w.tys[0..k.nv], k.tys[0..k.nv]);
        w.n_insts = @intCast(k.n);
        w.nv = k.nv;
        return;
    }
    // kir's exact expansions, into the work's storage
    const nk = try kir.expand(k, w.caps, .{ .insts = w.insts[0..], .tys = w.tys[0..] });
    w.n_insts = @intCast(nk.n);
    w.nv = nk.nv;
}

// ── 2. Analysis ─────────────────────────────────────────────────────────────

fn vid(v: kir.V) ?u16 {
    if (v == .none) return null;
    return @intFromEnum(v);
}

fn argReg(a: kir.Arg) ?u16 {
    return switch (a) {
        .reg => |v| vid(v),
        .imm => null,
    };
}

/// How many consecutive registers an instruction's operand covers.
fn memCount(m: kir.Mem) u8 {
    return kir.memRegs(m);
}

/// The registers an instruction reads (at most 3 operands, the stored
/// vector's members).
fn forUses(in: kir.Inst, ctx: anytype, comptime f: fn (@TypeOf(ctx), u16) void) void {
    switch (in.op) {
        .tid, .gid, .gsize, .lane, .subgroup, .param, .barrier, .@"else", .endif, .loop, .endloop, .ret => return,
        .st => {
            if (argReg(in.a)) |v| f(ctx, v);
            const m: kir.Mem = @bitCast(in.aux);
            if (argReg(in.b)) |v| {
                for (0..memCount(m)) |i| f(ctx, v + @as(u16, @intCast(i)));
            }
            return;
        },
        else => {},
    }
    if (argReg(in.a)) |v| f(ctx, v);
    if (argReg(in.b)) |v| f(ctx, v);
    if (argReg(in.c)) |v| f(ctx, v);
}

fn defCount(in: kir.Inst) u8 {
    return switch (in.op) {
        .ld => memCount(@bitCast(in.aux)),
        .st, .barrier, .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => 0,
        else => if (in.dst == .none) 0 else 1,
    };
}

fn isControl(op: kir.Op) bool {
    return switch (op) {
        .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => true,
        else => false,
    };
}

fn typeRange(ty: kir.Ty) [2]i64 {
    return switch (ty) {
        .i32 => .{ std.math.minInt(i32), std.math.maxInt(i32) },
        .pred => .{ 0, 1 },
        else => .{ 0, std.math.maxInt(u32) },
    };
}

const UseCtx = struct { w: *Work };
fn countUse(c: UseCtx, v: u16) void {
    if (v < c.w.nv) c.w.vi[v].uses +|= 1;
}

fn analyze(w: *Work) Error!void {
    const n = w.n_insts;
    for (0..w.nv) |v| {
        w.vi[v] = .{ .ty = w.tys[v], .cls = if (w.tys[v] == .f16) .half else .full };
    }
    // Definitions, uses, loop nesting.
    var depth: u16 = 0;
    var ifs: u32 = 0;
    for (w.insts[0..n], 0..) |in, i| {
        w.fuse[i] = .none;
        w.fuse_with[i] = NOWHERE;
        switch (in.op) {
            .loop => depth += 1,
            .endloop => {
                if (depth == 0) return error.Unbalanced;
                depth -= 1;
            },
            .@"if" => ifs += 1,
            .endif => {
                if (ifs == 0) return error.Unbalanced;
                ifs -= 1;
            },
            else => {},
        }
        w.in_loop[i] = depth;
        forUses(in, UseCtx{ .w = w }, countUse);
        const nd = defCount(in);
        if (nd > 0) {
            const d = vid(in.dst) orelse return error.BadOperand;
            for (0..nd) |k| {
                const v = d + @as(u16, @intCast(k));
                if (v >= w.nv) return error.BadOperand;
                w.vi[v].defs +|= 1;
                w.vi[v].def_at = @intCast(i);
            }
        }
    }
    if (depth != 0 or ifs != 0) return error.Unbalanced;
    for (0..w.nv) |v| {
        if (w.vi[v].defs != 1) w.vi[v].def_at = NOWHERE;
        const r = typeRange(w.vi[v].ty);
        w.vi[v].lo = r[0];
        w.vi[v].hi = r[1];
    }
    // Bounds, in program order (one definition each; others keep the type's).
    for (w.insts[0..n], 0..) |in, i| bounds(w, in, @intCast(i));
    uniformity(w);
    patterns(w);
}

fn single(w: *const Work, v: u16, i: u32) bool {
    return v < w.nv and w.vi[v].def_at == i;
}

fn argBounds(w: *const Work, a: kir.Arg, ty: kir.Ty) ?[2]i64 {
    switch (a) {
        .imm => |x| return switch (ty) {
            .i32 => .{ @as(i32, @bitCast(x)), @as(i32, @bitCast(x)) },
            else => .{ x, x },
        },
        .reg => |rv| {
            const v = vid(rv) orelse return null;
            if (v >= w.nv) return null;
            const info = w.vi[v];
            if (!info.known) return null;
            // reinterpretation between u32 and i32
            if (info.lo >= 0 and info.hi <= std.math.maxInt(i32)) return .{ info.lo, info.hi };
            if (ty == info.ty or (ty != .i32 and info.ty != .i32)) return .{ info.lo, info.hi };
            return null;
        },
    }
}

fn setBounds(w: *Work, v: u16, ty: kir.Ty, lo: i64, hi: i64) void {
    const r = typeRange(ty);
    if (lo < r[0] or hi > r[1] or lo > hi) return;
    w.vi[v].lo = lo;
    w.vi[v].hi = hi;
    w.vi[v].known = true;
}

fn bounds(w: *Work, in: kir.Inst, i: u32) void {
    const d = vid(in.dst) orelse return;
    if (!single(w, d, i)) return;
    const ty = in.ty;
    const a = argBounds(w, in.a, ty);
    const b = argBounds(w, in.b, ty);
    const c = argBounds(w, in.c, ty);
    switch (in.op) {
        .tid => setBounds(w, d, ty, 0, @as(i64, w.group[@min(in.aux, 2)]) - 1),
        .gid => setBounds(w, d, ty, 0, 65534),
        .gsize => setBounds(w, d, ty, 1, 65535),
        .lane => setBounds(w, d, ty, 0, @as(i64, w.threadsize) - 1),
        .subgroup => setBounds(w, d, ty, w.threadsize, w.threadsize),
        .icmp, .fcmp, .pand, .por, .pnot, .vote => setBounds(w, d, .pred, 0, 1),
        .mov, .shfl => if (a) |x| setBounds(w, d, ty, x[0], x[1]),
        .sel => if (a != null and b != null) setBounds(w, d, ty, @min(a.?[0], b.?[0]), @max(a.?[1], b.?[1])),
        .iadd => if (a != null and b != null) setBounds(w, d, ty, a.?[0] + b.?[0], a.?[1] + b.?[1]),
        .isub => if (a != null and b != null) setBounds(w, d, ty, a.?[0] - b.?[1], a.?[1] - b.?[0]),
        .imul, .imad => if (a != null and b != null) {
            const p = [4]i64{ a.?[0] * b.?[0], a.?[0] * b.?[1], a.?[1] * b.?[0], a.?[1] * b.?[1] };
            var lo = @min(@min(p[0], p[1]), @min(p[2], p[3]));
            var hi = @max(@max(p[0], p[1]), @max(p[2], p[3]));
            if (in.op == .imad) {
                const cc = c orelse return;
                lo += cc[0];
                hi += cc[1];
            }
            setBounds(w, d, ty, lo, hi);
        },
        .imin => if (a != null and b != null) setBounds(w, d, ty, @min(a.?[0], b.?[0]), @min(a.?[1], b.?[1])),
        .imax => if (a != null and b != null) setBounds(w, d, ty, @max(a.?[0], b.?[0]), @max(a.?[1], b.?[1])),
        .@"and" => {
            var hi: i64 = std.math.maxInt(i64);
            if (a) |x| if (x[0] >= 0) {
                hi = @min(hi, x[1]);
            };
            if (b) |x| if (x[0] >= 0) {
                hi = @min(hi, x[1]);
            };
            if (hi != std.math.maxInt(i64)) setBounds(w, d, ty, 0, hi);
        },
        .@"or", .xor => if (a != null and b != null and a.?[0] >= 0 and b.?[0] >= 0) {
            const m = @max(a.?[1], b.?[1]);
            const bits: u7 = if (m == 0) 0 else @intCast(64 - @clz(@as(u64, @intCast(m))));
            setBounds(w, d, ty, 0, (@as(i64, 1) << @intCast(bits)) - 1);
        },
        .shl => if (a != null and b != null and b.?[0] == b.?[1] and a.?[0] >= 0 and b.?[0] < 32) {
            const s: u6 = @intCast(b.?[0]);
            setBounds(w, d, ty, a.?[0] << s, a.?[1] << s);
        },
        .shr => if (a != null and b != null and b.?[0] == b.?[1] and b.?[0] < 32) {
            const s: u6 = @intCast(b.?[0]);
            if (a.?[0] >= 0 or ty == .i32) setBounds(w, d, ty, a.?[0] >> s, a.?[1] >> s);
        },
        .bfe => if (c != null and c.?[0] == c.?[1] and c.?[0] > 0 and c.?[0] < 32) {
            const bits: u6 = @intCast(c.?[0]);
            if (ty == .i32) setBounds(w, d, ty, -(@as(i64, 1) << (bits - 1)), (@as(i64, 1) << (bits - 1)) - 1) else setBounds(w, d, ty, 0, (@as(i64, 1) << bits) - 1);
        },
        .dot4 => if (c) |cc| {
            const mode: kir.Dot4 = @enumFromInt(@as(u8, @truncate(in.aux)));
            const r: [2]i64 = switch (mode) {
                .s8u8 => .{ -128 * 255 * 4, 127 * 255 * 4 },
                .s8s8 => .{ -128 * 127 * 4, 128 * 128 * 4 },
                .u8u8 => .{ 0, 255 * 255 * 4 },
            };
            setBounds(w, d, ty, r[0] + cc[0], r[1] + cc[1]);
        },
        .ld => {
            const m: kir.Mem = @bitCast(in.aux);
            if (m.width_log2 == 3) {
                if (m.signed) setBounds(w, d, ty, -128, 127) else setBounds(w, d, ty, 0, 255);
            } else if (m.width_log2 == 4 and ty != .f16) {
                if (m.signed) setBounds(w, d, ty, -32768, 32767) else setBounds(w, d, ty, 0, 65535);
            }
        },
        else => {},
    }
}

/// Which values are the same on every fiber of a wave (optimistic, then
/// refined to a fixed point): a shuffle's mask or delta must be.
fn uniformity(w: *Work) void {
    const n = w.n_insts;
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 64) : (rounds += 1) {
        changed = false;
        // divergent constructs: ifs, and loops with a divergent brk/cont
        var div_stack: [64]bool = undefined;
        var sp: usize = 0;
        var divergent: u32 = 0;
        // loops' divergence is known only after their body; take the
        // previous round's answer (a loop is divergent when any brk/cont in it is)
        for (w.insts[0..n], 0..) |in, i| {
            switch (in.op) {
                .@"if" => {
                    const dv = !argUniform(w, in.a);
                    if (sp < div_stack.len) {
                        div_stack[sp] = dv;
                        sp += 1;
                    }
                    if (dv) divergent += 1;
                    continue;
                },
                .loop => {
                    const dv = loopDivergent(w, @intCast(i));
                    if (sp < div_stack.len) {
                        div_stack[sp] = dv;
                        sp += 1;
                    }
                    if (dv) divergent += 1;
                    continue;
                },
                .endif, .endloop => {
                    if (sp > 0) {
                        sp -= 1;
                        if (div_stack[sp]) divergent -= 1;
                    }
                    continue;
                },
                else => {},
            }
            const d = vid(in.dst) orelse continue;
            if (defCount(in) == 0 or d >= w.nv) continue;
            var u = switch (in.op) {
                .tid, .lane, .ld, .atom, .shfl => false,
                .gid, .gsize, .subgroup, .param, .vote => true,
                else => argUniform(w, in.a) and argUniform(w, in.b) and argUniform(w, in.c),
            };
            if (w.vi[d].defs > 1 and divergent > 0) u = false;
            const nd = defCount(in);
            for (0..nd) |k| {
                const v = d + @as(u16, @intCast(k));
                if (!u and w.vi[v].uniform) {
                    w.vi[v].uniform = false;
                    changed = true;
                }
            }
        }
    }
}

fn loopDivergent(w: *const Work, at: u32) bool {
    var depth: u32 = 0;
    var i = at;
    while (i < w.n_insts) : (i += 1) {
        const in = w.insts[i];
        switch (in.op) {
            .loop => depth += 1,
            .endloop => {
                depth -= 1;
                if (depth == 0) return false;
            },
            .brk, .cont, .ret => if (!argUniform(w, in.a)) return true,
            else => {},
        }
    }
    return false;
}

fn argUniform(w: *const Work, a: kir.Arg) bool {
    const v = argReg(a) orelse return true;
    if (v >= w.nv) return true;
    return w.vi[v].uniform;
}

fn argImm(a: kir.Arg) ?u32 {
    return switch (a) {
        .imm => |x| x,
        .reg => null,
    };
}

/// The instruction that defines `a` (one definition, used once here), if
/// it is `op`.
fn singleUseDef(w: *const Work, a: kir.Arg, op: kir.Op, at: u32) ?u32 {
    const v = argReg(a) orelse return null;
    if (v >= w.nv) return null;
    const info = w.vi[v];
    if (info.defs != 1 or info.uses != 1 or info.def_at == NOWHERE) return null;
    // (a register read before its only definition is a loop-carried value:
    // the read sees the previous turn's, so nothing is folded)
    if (info.def_at >= at) return null;
    if (w.fuse[info.def_at] != .none) return null;
    const def = w.insts[info.def_at];
    if (def.op != op) return null;
    return info.def_at;
}

/// An operand that keeps its value from `from` to `to` (an immediate, or a
/// register with one definition before `from`).
fn stable(w: *const Work, a: kir.Arg, from: u32) bool {
    const v = argReg(a) orelse return true;
    if (v >= w.nv) return false;
    const info = w.vi[v];
    return info.defs == 1 and info.def_at != NOWHERE and info.def_at < from;
}

fn patterns(w: *Work) void {
    const n = w.n_insts;
    for (w.insts[0..n], 0..) |in, ii| {
        const i: u32 = @intCast(ii);
        switch (in.op) {
            .@"and" => {
                if (in.ty == .pred) continue;
                // (x >> s) & m, (x << s) & m: shrm / shlm
                inline for (.{ .{ in.a, in.b }, .{ in.b, in.a } }) |pair| {
                    if (w.fuse[i] == .none) {
                        const m = pair[1];
                        if (argImm(m) != null or aliasConst(w, m)) {
                            if (singleUseDef(w, pair[0], .shr, i)) |j| {
                                const s = w.insts[j];
                                if (argImm(s.b)) |sh| if (sh < 32 and stable(w, s.a, j) and (s.ty != .i32 or maskFits(argImm(m), sh))) {
                                    w.fuse[i] = .shrm;
                                    w.fuse_with[i] = j;
                                    w.fuse[j] = .skip;
                                };
                            } else if (singleUseDef(w, pair[0], .shl, i)) |j| {
                                const s = w.insts[j];
                                if (argImm(s.b)) |sh| if (sh < 32 and stable(w, s.a, j)) {
                                    w.fuse[i] = .shlm;
                                    w.fuse_with[i] = j;
                                    w.fuse[j] = .skip;
                                };
                            }
                        }
                    }
                }
            },
            .@"or" => {
                if (in.ty == .pred) continue;
                inline for (.{ .{ in.a, in.b }, .{ in.b, in.a } }) |pair| {
                    if (w.fuse[i] == .none) {
                        if (singleUseDef(w, pair[0], .shl, i)) |j| {
                            const s = w.insts[j];
                            if (argImm(s.b)) |sh| if (sh < 32 and stable(w, s.a, j)) {
                                w.fuse[i] = .shlg;
                                w.fuse_with[i] = j;
                                w.fuse[j] = .skip;
                            };
                        } else if (singleUseDef(w, pair[0], .shr, i)) |j| {
                            const s = w.insts[j];
                            if (s.ty != .i32) if (argImm(s.b)) |sh| if (sh < 32 and stable(w, s.a, j)) {
                                w.fuse[i] = .shrg;
                                w.fuse_with[i] = j;
                                w.fuse[j] = .skip;
                            };
                        } else if (singleUseDef(w, pair[0], .@"and", i)) |j| {
                            const s = w.insts[j];
                            if (w.fuse[j] == .none and s.ty != .pred and stable(w, s.a, j) and stable(w, s.b, j)) {
                                w.fuse[i] = .andg;
                                w.fuse_with[i] = j;
                                w.fuse[j] = .skip;
                            }
                        }
                    }
                }
            },
            .iadd => {
                // a * b + c in one mad.u24 / mad.s24 when the factors are small
                inline for (.{ .{ in.a, in.b }, .{ in.b, in.a } }) |pair| {
                    if (w.fuse[i] == .none) if (singleUseDef(w, pair[0], .imul, i)) |j| {
                        const m = w.insts[j];
                        if (stable(w, m.a, j) and stable(w, m.b, j) and mul24(w, m.a, m.b, m.ty) != null) {
                            w.fuse[i] = .imad;
                            w.fuse_with[i] = j;
                            w.fuse[j] = .skip;
                        }
                    };
                }
            },
            .cvt => {
                // cvt(f16 -> f32) of mov(f16 <- x) or mov(f16 <- x >> 16):
                // read x's low or high half directly
                const cv: kir.Cvt = @bitCast(in.aux);
                if (cv.from != .f16) continue;
                const j = singleUseDef(w, in.a, .mov, i) orelse continue;
                const mv = w.insts[j];
                if (mv.ty != .f16 or !stable(w, mv.a, j)) continue;
                const x = argReg(mv.a) orelse continue;
                if (x >= w.nv or w.vi[x].cls != .full) continue;
                w.fuse[i] = .half_lo;
                w.fuse_with[i] = j;
                w.fuse[j] = .skip;
                if (singleUseDef(w, mv.a, .shr, j)) |js| {
                    const sh = w.insts[js];
                    if (argImm(sh.b)) |n16| if (n16 == 16 and stable(w, sh.a, js)) if (argReg(sh.a)) |y| if (y < w.nv and w.vi[y].cls == .full) {
                        w.fuse[i] = .half_hi;
                        w.fuse_with[i] = js;
                        w.fuse[js] = .skip;
                    };
                }
            },
            .@"if", .brk, .cont => {
                // A compare used only by this branch goes straight into p0.x.
                if (singleUseDef(w, in.a, .icmp, i) orelse singleUseDef(w, in.a, .fcmp, i)) |j| {
                    const c = w.insts[j];
                    if (stable(w, c.a, j) and stable(w, c.b, j) or j + 1 == i) {
                        w.fuse[i] = .branch;
                        w.fuse_with[i] = j;
                        w.fuse[j] = .skip;
                    }
                }
            },
            else => {},
        }
    }
}

fn maskFits(m: ?u32, sh: u32) bool {
    const x = m orelse return false;
    if (sh == 0) return true;
    return x >> @intCast(32 - sh) == 0;
}

fn aliasConst(w: *const Work, a: kir.Arg) bool {
    const v = argReg(a) orelse return false;
    if (v >= w.nv) return false;
    const def = w.vi[v].def_at;
    if (def == NOWHERE) return false;
    return w.insts[def].op == .param;
}

/// mul.u24 or mul.s24 gives the 32-bit product of these factors.
fn mul24(w: *const Work, a: kir.Arg, b: kir.Arg, ty: kir.Ty) ?ir3.Op {
    const ra = argBounds(w, a, ty) orelse return null;
    const rb = argBounds(w, b, ty) orelse return null;
    if (ra[0] >= 0 and rb[0] >= 0 and ra[1] < (1 << 24) and rb[1] < (1 << 24)) return .mul_u24;
    const lim: i64 = 1 << 23;
    if (ra[0] >= -lim and ra[1] < lim and rb[0] >= -lim and rb[1] < lim) return .mul_s24;
    return null;
}

// ── 3. Lowering ─────────────────────────────────────────────────────────────

fn newVreg(w: *Work, cls: Class) Error!u16 {
    if (w.nv >= MAX_VREGS or w.nv >= PHYS) return error.TooManyRegs;
    const v: u16 = @intCast(w.nv);
    w.vi[v] = .{ .cls = cls, .ty = if (cls == .half) .f16 else .u32, .defs = 1, .uses = 1 };
    w.nv += 1;
    return v;
}

/// n consecutive fresh registers (a vector).
fn newVec(w: *Work, cls: Class, n: u16) Error!u16 {
    const first = try newVreg(w, cls);
    for (1..n) |_| _ = try newVreg(w, cls);
    return first;
}

fn put(w: *Work, m: MI) Error!void {
    if (w.n_mi >= MAX_MI) return error.TooManyInsts;
    w.mi[w.n_mi] = m;
    w.n_mi += 1;
}

fn putPro(w: *Work, m: MI) Error!void {
    if (w.n_pro >= MAX_PROLOGUE) return error.TooManyInsts;
    w.pro[w.n_pro] = m;
    w.n_pro += 1;
}

fn newLabel(w: *Work) u16 {
    const l: u16 = @intCast(w.n_labels);
    w.n_labels += 1;
    return l;
}

fn putLabel(w: *Work, l: u16) Error!void {
    try put(w, .{ .kind = .label, .label = l });
}

fn putBranch(w: *Work, op: ir3.Op, inv: bool, l: u16) Error!void {
    var m = MI{ .kind = .branch, .label = l };
    m.in.op = op;
    m.in.inv1 = inv;
    if (op != .jump) m.src[0] = PHYS | ir3.P0_X;
    try put(w, m);
}

/// The constant register holding word `x` of the pool.
fn poolConst(w: *Work, x: u32) ?u16 {
    for (w.pool[0..w.n_pool], 0..) |p, i| if (p == x) return @intCast(w.pool_at + i);
    if (w.n_pool >= MAX_POOL) return null;
    if (w.pool_at + w.n_pool >= 1020) return null;
    w.pool[w.n_pool] = x;
    w.n_pool += 1;
    return @intCast(w.pool_at + w.n_pool - 1);
}

const Slot = enum {
    /// cat1: register, any immediate, constant
    any,
    /// cat2/cat4 integer: register (shared too), 11-bit immediate, constant
    c2,
    /// cat2/cat4 float: register, float table, constant
    c2f,
    /// cat3 first/third: register, constant
    c3,
    /// cat3 second: register only
    c3mid,
    /// shrm/shlm/shrg/shlg/andg first/third: register or 12-bit immediate
    c3alt,
    /// memory operands: register only
    c6,
    /// shfl's lane operand: register or 8-bit immediate
    c6imm,
};

/// An immediate a cat2/cat4 source takes: Mesa's ir3_valid_immediate allows
/// 10 bits sign-extended (the field is 11 wide, but not all of it is the
/// value), so -511..511.
fn fitsImm11(x: u32) bool {
    const v: i32 = @bitCast(x);
    return v >= -511 and v <= 511;
}

/// The float table entries the hardware's table certainly holds exactly.
fn flutIndex(x: u32, half: bool) ?u32 {
    if (half) {
        return switch (@as(u16, @truncate(x))) {
            0x0000 => 0,
            0x3800 => 1,
            0x3c00 => 2,
            0x4000 => 3,
            0x4400 => 11,
            else => null,
        };
    }
    return switch (x) {
        0x00000000 => 0,
        0x3f000000 => 1,
        0x3f800000 => 2,
        0x40000000 => 3,
        0x40800000 => 11,
        else => null,
    };
}

/// A register copy of an operand that cannot go where it is used (hoisted
/// to the start when inside a loop, reused).
fn materialize(w: *Work, o: Opnd, in_loop: bool) Error!Opnd {
    var key = o;
    key.neg = false;
    key.abs = false;
    key.bnot = false;
    for (w.cached[0..w.n_cached]) |c| {
        if (c.key.k == key.k and c.key.v == key.v and c.key.x == key.x and c.key.half == key.half) {
            var r = Opnd.reg(c.v, key.half);
            r.neg = o.neg;
            r.abs = o.abs;
            r.bnot = o.bnot;
            return r;
        }
    }
    const t = try newVreg(w, if (key.half) .half else .full);
    var m = MI{ .dst = t };
    m.in.op = .mov;
    m.in.src_type = if (key.half) .u16 else .u32;
    m.in.dst_type = m.in.src_type;
    m.in.dst.half = key.half;
    setSrc(&m, 0, key);
    // (hoisted to the start, which dominates every use, and reused)
    _ = in_loop;
    try putPro(w, m);
    if (w.n_cached < MAX_CACHED) {
        w.cached[w.n_cached] = .{ .key = key, .v = t };
        w.n_cached += 1;
    }
    var r = Opnd.reg(t, key.half);
    r.neg = o.neg;
    r.abs = o.abs;
    r.bnot = o.bnot;
    return r;
}

fn isShared(o: Opnd) bool {
    return o.k == .vreg and isPhys(o.v) and (o.v & ~PHYS) >= ir3.SHARED_BASE and (o.v & ~PHYS) < ir3.A0_X;
}

/// Make `o` fit `slot`.
fn fit(w: *Work, o: Opnd, slot: Slot, float: bool, in_loop: bool) Error!Opnd {
    switch (o.k) {
        .vreg => {
            if (isShared(o) and (slot != .any and slot != .c2 and slot != .c2f)) return materialize(w, o, in_loop);
            return o;
        },
        .cnst => return switch (slot) {
            .any, .c2, .c2f, .c3 => o,
            // (the shift-and-mask forms take no const sources)
            else => materialize(w, o, in_loop),
        },
        .flut => return o,
        .imm => {
            switch (slot) {
                .any => return o,
                .c2 => if (!float) {
                    if (fitsImm11(o.x)) return o;
                } else if (flutIndex(o.x, o.half)) |fi| {
                    return .{ .k = .flut, .x = fi, .half = o.half, .neg = o.neg, .abs = o.abs };
                },
                .c2f => if (flutIndex(o.x, o.half)) |fi| {
                    return .{ .k = .flut, .x = fi, .half = o.half, .neg = o.neg, .abs = o.abs };
                },
                .c3alt => if (o.x <= 4095 and !o.neg) return o,
                .c6imm => if (o.x <= 255) return o,
                else => {},
            }
            switch (slot) {
                .c2, .c2f, .c3 => if (poolConst(w, o.x)) |c| {
                    var r = Opnd.cnst(c);
                    r.half = o.half;
                    r.neg = o.neg;
                    r.abs = o.abs;
                    return r;
                },
                else => {},
            }
            return materialize(w, o, in_loop);
        },
        .none => return error.BadOperand,
    }
}

fn setSrc(m: *MI, i: usize, o: Opnd) void {
    var s = ir3.Src{ .half = o.half, .neg = o.neg, .abs = o.abs, .bnot = o.bnot };
    switch (o.k) {
        .vreg => {
            s.kind = .gpr;
            m.src[i] = o.v;
            m.view[i] = o.view;
            if (o.view != 0) s.half = true;
            if (isPhys(o.v)) s.num = o.v & ~PHYS;
        },
        .imm => {
            s.kind = .imm;
            s.imm = o.x;
        },
        .cnst => {
            s.kind = .cnst;
            s.num = @intCast(o.x);
        },
        .flut => {
            s.kind = .flut;
            s.imm = o.x;
        },
        .none => {},
    }
    m.in.src[i] = s;
}

const Lw = struct {
    w: *Work,
    i: u32,
    in: kir.Inst,
    loop: bool,

    fn half(l: *const Lw) bool {
        return l.in.ty == .f16;
    }

    /// A KIR operand as an Opnd (aliases resolved), then fitted.
    fn arg(l: *Lw, a: kir.Arg, slot: Slot, float: bool, half_: bool) Error!Opnd {
        const o = l.raw(a, half_);
        return fit(l.w, o, slot, float, l.loop);
    }

    fn raw(l: *Lw, a: kir.Arg, half_: bool) Opnd {
        switch (a) {
            .imm => |x| {
                var o = Opnd.imm(if (half_) x & 0xffff else x);
                o.half = half_;
                return o;
            },
            .reg => |rv| {
                const v = vid(rv) orelse return .{};
                if (v < l.w.nv and l.w.vi[v].alias.k != .none) {
                    var o = l.w.vi[v].alias;
                    o.half = half_;
                    return o;
                }
                return Opnd.reg(v, half_);
            },
        }
    }

    fn dst(l: *const Lw) u16 {
        return vid(l.in.dst) orelse NONE;
    }
};

fn alu1(w: *Work, op: ir3.Op, d: u16, dh: bool, a: Opnd) Error!void {
    var m = MI{ .dst = d };
    m.in.op = op;
    m.in.dst.half = dh;
    setSrc(&m, 0, a);
    try put(w, m);
}

fn alu2(w: *Work, op: ir3.Op, d: u16, dh: bool, a: Opnd, b: Opnd) Error!void {
    var m = MI{ .dst = d };
    m.in.op = op;
    m.in.dst.half = dh;
    setSrc(&m, 0, a);
    setSrc(&m, 1, b);
    try put(w, m);
}

fn cmp2(w: *Work, op: ir3.Op, cc: ir3.Cond, d: u16, a: Opnd, b: Opnd) Error!void {
    var m = MI{ .dst = d };
    m.in.op = op;
    m.in.cond = cc;
    m.in.dst.half = false;
    setSrc(&m, 0, a);
    setSrc(&m, 1, b);
    try put(w, m);
}

fn alu3(w: *Work, op: ir3.Op, d: u16, dh: bool, a: Opnd, b: Opnd, c: Opnd) Error!void {
    var m = MI{ .dst = d };
    m.in.op = op;
    m.in.dst.half = dh;
    setSrc(&m, 0, a);
    setSrc(&m, 1, b);
    setSrc(&m, 2, c);
    try put(w, m);
}

fn mov(w: *Work, d: u16, dh: bool, a: Opnd, ty: ir3.Type) Error!void {
    var m = MI{ .dst = d };
    m.in.op = .mov;
    m.in.src_type = ty;
    m.in.dst_type = ty;
    m.in.dst.half = dh;
    setSrc(&m, 0, a);
    if (a.k == .vreg and !a.neg and !a.abs and !isPhys(a.v)) m.kind = .copy;
    try put(w, m);
}

fn cov(w: *Work, d: u16, dh: bool, a: Opnd, from: ir3.Type, to: ir3.Type, round: ir3.Round) Error!void {
    var m = MI{ .dst = d };
    m.in.op = .mov;
    m.in.src_type = from;
    m.in.dst_type = to;
    m.in.round = round;
    m.in.dst.half = dh;
    setSrc(&m, 0, a);
    try put(w, m);
}

fn lower(w: *Work) Error!void {
    w.n_mi = 0;
    w.n_pro = 0;
    w.n_loops = 0;
    w.n_labels = 0;
    w.n_ctl = 0;
    w.n_pool = 0;
    w.n_cached = 0;
    w.max_depth = 0;
    w.uses_tid = false;
    w.uses_gid = false;
    w.uses_drv = false;
    w.uses_exchange = false;
    w.uses_ret = false;
    w.linear_tid = NONE;
    // Constant layout.
    w.params_at = 2 * w.bindings;
    w.drv_at = std.mem.alignForward(u32, w.params_at + w.param_words, 4);
    var drv = false;
    for (w.insts[0..w.n_insts]) |in| {
        if (in.op == .gsize) drv = true;
    }
    w.uses_drv = drv;
    w.pool_at = w.drv_at + (if (drv) @as(u32, 4) else 0);
    if (w.pool_at > 1000) return error.Unsupported;
    // The shuffle exchange area sits after the kernel's shared memory.
    w.exchange_at = std.mem.alignForward(u32, w.shared_bytes, 16);
    w.ret_label = newLabel(w);
    // Aliases: ids and constants that need no instruction.
    for (w.insts[0..w.n_insts], 0..) |in, ii| {
        const i: u32 = @intCast(ii);
        const d = vid(in.dst) orelse continue;
        if (d >= w.nv or !single(w, d, i)) continue;
        const ax: u16 = @intCast(@min(in.aux, 2));
        switch (in.op) {
            .tid => {
                w.vi[d].alias = Opnd.reg(PHYS | ax, false);
                w.uses_tid = true;
            },
            .gid => {
                w.vi[d].alias = Opnd.reg(PHYS | (ir3.SHARED_BASE + ax), false);
                w.uses_gid = true;
            },
            .gsize => w.vi[d].alias = Opnd.cnst(@intCast(w.drv_at + ax)),
            .param => {
                if (in.aux >= w.param_words) return error.BadOperand;
                w.vi[d].alias = Opnd.cnst(@intCast(w.params_at + in.aux));
            },
            .subgroup => w.vi[d].alias = Opnd.imm(w.threadsize),
            .lane => if (w.group[1] == 1 and w.group[2] == 1 and w.group[0] <= w.threadsize) {
                w.vi[d].alias = Opnd.reg(PHYS | 0, false);
                w.uses_tid = true;
            },
            else => {},
        }
    }
    var i: u32 = 0;
    while (i < w.n_insts) : (i += 1) {
        try lowerOne(w, i);
    }
    if (w.n_ctl != 0) return error.Unbalanced;
    // ir3's operand rules (what adreno.device.checkInstr checks).
    try legalizeOperands(w);
    // The end: every ret comes here.
    try putLabel(w, w.ret_label);
    var e = MI{};
    e.in.op = .end;
    try put(w, e);
    // The prologue first.
    if (w.n_pro > 0) {
        if (w.n_mi + w.n_pro > MAX_MI) return error.TooManyInsts;
        std.mem.copyBackwards(MI, w.mi[w.n_pro .. w.n_mi + w.n_pro], w.mi[0..w.n_mi]);
        @memcpy(w.mi[0..w.n_pro], w.pro[0..w.n_pro]);
        for (w.loops[0..w.n_loops]) |*lp| {
            lp.head += w.n_pro;
            lp.end += w.n_pro;
        }
        w.n_mi += w.n_pro;
    }
}

fn lowerOne(w: *Work, i: u32) Error!void {
    const in = w.insts[i];
    if (w.fuse[i] == .skip) return;
    var l = Lw{ .w = w, .i = i, .in = in, .loop = w.in_loop[i] > 0 };
    const d = l.dst();
    if (d != NONE and d < w.nv and w.vi[d].alias.k != .none) return;
    const h = l.half();
    const isF = in.ty == .f32 or in.ty == .f16;
    switch (in.op) {
        .mov => {
            // (f16 sits in the low half of a KIR register: a half register
            // here; moves between the two sizes cut or zero-extend)
            const src_half = if (argReg(in.a)) |v| (v < w.nv and w.vi[v].cls == .half) else false;
            if (h and !src_half and argReg(in.a) != null) return cov(w, d, true, try l.arg(in.a, .c6, false, false), .u32, .u16, .none);
            if (!h and src_half) return cov(w, d, false, try l.arg(in.a, .c6, false, true), .u16, .u32, .none);
            if (h) try mov(w, d, true, try l.arg(in.a, .any, true, true), .u16) else try mov(w, d, false, try l.arg(in.a, .any, false, false), .u32);
        },
        .sel => try lowerSel(&l),
        .iadd => {
            if (w.fuse[i] == .imad) return lowerFusedImad(&l);
            try alu2(w, .add_u, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false));
        },
        .isub => try alu2(w, .sub_u, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false)),
        .imul => try lowerMul(&l, d, in.a, in.b, null),
        .imad => try lowerMul(&l, d, in.a, in.b, in.c),
        .imulhi => try lowerMulHi(&l),
        .ineg => {
            var a = try l.arg(in.a, .c2, false, false);
            if (a.k == .imm) return mov(w, d, false, Opnd.imm(0 -% a.x), .u32);
            a.neg = !a.neg;
            try alu1(w, .absneg_s, d, false, a);
        },
        .iabs => {
            var a = try l.arg(in.a, .c2, false, false);
            if (a.k == .imm) {
                const v: i32 = @bitCast(a.x);
                return mov(w, d, false, Opnd.imm(@bitCast(if (v < 0) 0 -% v else v)), .u32);
            }
            a.abs = true;
            try alu1(w, .absneg_s, d, false, a);
        },
        .imin => try alu2(w, if (in.ty == .i32) .min_s else .min_u, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false)),
        .imax => try alu2(w, if (in.ty == .i32) .max_s else .max_u, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false)),
        .@"and", .@"or", .xor => try lowerBits(&l),
        .not => {
            if (in.ty == .pred) return alu2(w, .xor_b, d, false, try l.arg(in.a, .c2, false, false), Opnd.imm(1));
            try alu1(w, .not_b, d, false, try l.arg(in.a, .c2, false, false));
        },
        .shl => try alu2(w, .shl_b, d, false, try l.arg(in.a, .c2, false, false), try shiftArg(&l, in.b)),
        .shr => try alu2(w, if (in.ty == .i32) .ashr_b else .shr_b, d, false, try l.arg(in.a, .c2, false, false), try shiftArg(&l, in.b)),
        .bfe => try lowerBfe(&l),
        .dot4 => try lowerDot4(&l),
        .icmp, .fcmp => {
            const c: kir.Cmp = @enumFromInt(@as(u8, @truncate(in.aux)));
            const ch = operandHalf(w, in);
            const op: ir3.Op = if (in.op == .fcmp) .cmps_f else if (operandTy(w, in) == .i32) .cmps_s else .cmps_u;
            const sl: Slot = if (in.op == .fcmp) .c2f else .c2;
            try cmp2(w, op, cond(c), d, try l.arg(in.a, sl, in.op == .fcmp, ch), try l.arg(in.b, sl, in.op == .fcmp, ch));
        },
        .pand => try alu2(w, .and_b, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false)),
        .por => try alu2(w, .or_b, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false)),
        .pnot => try alu2(w, .xor_b, d, false, try l.arg(in.a, .c2, false, false), Opnd.imm(1)),
        .fadd => try alu2(w, .add_f, d, h, try l.arg(in.a, .c2f, true, h), try l.arg(in.b, .c2f, true, h)),
        .fsub => {
            var b = l.raw(in.b, h);
            b.neg = !b.neg;
            try alu2(w, .add_f, d, h, try l.arg(in.a, .c2f, true, h), try fit(w, b, .c2f, true, l.loop));
        },
        .fmul => try alu2(w, .mul_f, d, h, try l.arg(in.a, .c2f, true, h), try l.arg(in.b, .c2f, true, h)),
        .fmad, .ffma => {
            if (in.op == .ffma and !w.caps.fused_fma) return error.NeedsFusedFma;
            try lowerMad(&l, if (h) .mad_f16 else .mad_f32);
        },
        .fmin => try alu2(w, .min_f, d, h, try l.arg(in.a, .c2f, true, h), try l.arg(in.b, .c2f, true, h)),
        .fmax => try alu2(w, .max_f, d, h, try l.arg(in.a, .c2f, true, h), try l.arg(in.b, .c2f, true, h)),
        .fabs => {
            var a = try l.arg(in.a, .c2f, true, h);
            a.abs = true;
            a.neg = false;
            try alu1(w, .absneg_f, d, h, a);
        },
        .fneg => {
            var a = try l.arg(in.a, .c2f, true, h);
            a.neg = !a.neg;
            try alu1(w, .absneg_f, d, h, a);
        },
        .ffloor => try alu1(w, .floor_f, d, h, try l.arg(in.a, .c2f, true, h)),
        .fceil => try alu1(w, .ceil_f, d, h, try l.arg(in.a, .c2f, true, h)),
        .ftrunc => try alu1(w, .trunc_f, d, h, try l.arg(in.a, .c2f, true, h)),
        .frne => try alu1(w, .rndne_f, d, h, try l.arg(in.a, .c2f, true, h)),
        .frcp => try alu1(w, .rcp, d, h, try l.arg(in.a, .c2f, true, h)),
        .frsq => try alu1(w, .rsq, d, h, try l.arg(in.a, .c2f, true, h)),
        .fexp2 => try alu1(w, .exp2, d, h, try l.arg(in.a, .c2f, true, h)),
        .flog2 => try alu1(w, .log2, d, h, try l.arg(in.a, .c2f, true, h)),
        .fsin => try alu1(w, .sin, d, h, try l.arg(in.a, .c2f, true, h)),
        .fcos => try alu1(w, .cos, d, h, try l.arg(in.a, .c2f, true, h)),
        .fdiv, .fsqrt => return error.Unsupported,
        .cvt => try lowerCvt(&l),
        .tid => try mov(w, d, false, Opnd.reg(PHYS | @as(u16, @intCast(@min(in.aux, 2))), false), .u32),
        .gid => try mov(w, d, false, Opnd.reg(PHYS | (ir3.SHARED_BASE + @as(u16, @intCast(@min(in.aux, 2)))), false), .u32),
        .gsize => try mov(w, d, false, Opnd.cnst(@intCast(w.drv_at + @min(in.aux, 2))), .u32),
        .param => {
            if (in.aux >= w.param_words) return error.BadOperand;
            try mov(w, d, false, Opnd.cnst(@intCast(w.params_at + in.aux)), .u32);
        },
        .subgroup => try mov(w, d, false, Opnd.imm(w.threadsize), .u32),
        .lane => try lowerLane(&l),
        .ld => try lowerLoad(&l),
        .st => try lowerStore(&l),
        .atom => try lowerAtom(&l),
        .barrier => {
            var f = MI{};
            f.in.op = .fence;
            f.in.g = true;
            f.in.r = true;
            f.in.w = true;
            try put(w, f);
            var b = MI{};
            b.in.op = .bar;
            try put(w, b);
        },
        .shfl => try lowerShfl(&l),
        .vote => try lowerVote(&l),
        .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => try lowerControl(&l),
    }
    _ = isF;
}

fn cond(c: kir.Cmp) ir3.Cond {
    return switch (c) {
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
    };
}

/// The type a compare compares (KIR: the instruction's ty).
fn operandTy(w: *const Work, in: kir.Inst) kir.Ty {
    _ = w;
    return in.ty;
}

fn operandHalf(w: *const Work, in: kir.Inst) bool {
    _ = w;
    _ = in;
    return false;
}

fn shiftArg(l: *Lw, b: kir.Arg) Error!Opnd {
    if (argImm(b)) |x| return fit(l.w, Opnd.imm(x & 31), .c2, false, l.loop);
    return l.arg(b, .c2, false, false);
}

fn lowerSel(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    if (l.half()) {
        // sel.b16 takes a half condition
        const c = try l.arg(in.c, .c3mid, false, false);
        const hc = try newVreg(w, .half);
        try cov(w, hc, true, c, .u32, .u16, .none);
        try alu3(w, .sel_b16, d, true, try l.arg(in.a, .c3, false, true), Opnd.reg(hc, true), try l.arg(in.b, .c3, false, true));
        return;
    }
    // A constant condition picks a side.
    if (argImm(in.c)) |x| return mov(w, d, false, try l.arg(if (x != 0) in.a else in.b, .any, false, false), .u32);
    try alu3(w, .sel_b32, d, false, try l.arg(in.a, .c3, false, false), try l.arg(in.c, .c3mid, false, false), try l.arg(in.b, .c3, false, false));
}

fn lowerBits(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const op: ir3.Op = switch (in.op) {
        .@"and" => .and_b,
        .@"or" => .or_b,
        else => .xor_b,
    };
    switch (w.fuse[l.i]) {
        .shrm, .shlm => {
            const j = w.fuse_with[l.i];
            const s = w.insts[j];
            // the mask is the other operand
            const other = if (argReg(in.a) == vid(s.dst)) in.b else in.a;
            const sh = argImm(s.b).? & 31;
            try alu3(w, if (w.fuse[l.i] == .shrm) .shrm else .shlm, d, false, Opnd.imm(sh), try l.arg(s.a, .c3mid, false, false), try l.arg(other, .c3alt, false, false));
            return;
        },
        .shrg, .shlg => {
            const j = w.fuse_with[l.i];
            const s = w.insts[j];
            const other = if (argReg(in.a) == vid(s.dst)) in.b else in.a;
            const sh = argImm(s.b).? & 31;
            try alu3(w, if (w.fuse[l.i] == .shrg) .shrg else .shlg, d, false, Opnd.imm(sh), try l.arg(s.a, .c3mid, false, false), try l.arg(other, .c3alt, false, false));
            return;
        },
        .andg => {
            const j = w.fuse_with[l.i];
            const s = w.insts[j];
            const other = if (argReg(in.a) == vid(s.dst)) in.b else in.a;
            // andg dst = (src1 & src0) | src2; src1 must be a register
            var x = s.a;
            var m = s.b;
            if (argReg(x) == null or isAliasNonGpr(w, x)) {
                const t = x;
                x = m;
                m = t;
            }
            try alu3(w, .andg, d, false, try l.arg(m, .c3alt, false, false), try l.arg(x, .c3mid, false, false), try l.arg(other, .c3alt, false, false));
            return;
        },
        else => {},
    }
    try alu2(w, op, d, false, try l.arg(in.a, .c2, false, false), try l.arg(in.b, .c2, false, false));
}

fn isAliasNonGpr(w: *const Work, a: kir.Arg) bool {
    const v = argReg(a) orelse return true;
    if (v >= w.nv) return false;
    const al = w.vi[v].alias;
    return al.k == .cnst or al.k == .imm or isShared(al);
}

/// Put the operand that is a plain register second (cat3's src1 must be).
fn regSecond(w: *const Work, a: kir.Arg, b: kir.Arg) bool {
    // true: swap
    const a_reg = argReg(a) != null and !isAliasNonGpr(w, a);
    const b_reg = argReg(b) != null and !isAliasNonGpr(w, b);
    return !b_reg and a_reg;
}

fn lowerMad(l: *Lw, op: ir3.Op) Error!void {
    const w = l.w;
    const in = l.in;
    const h = l.half();
    var a = in.a;
    var b = in.b;
    if (regSecond(w, a, b)) {
        const t = a;
        a = b;
        b = t;
    }
    try alu3(w, op, l.dst(), h, try l.arg(a, .c3, true, h), try l.arg(b, .c3mid, true, h), try l.arg(in.c, .c3, true, h));
}

fn isPow2Imm(a: kir.Arg) ?u5 {
    const x = argImm(a) orelse return null;
    if (x == 0 or x & (x - 1) != 0) return null;
    return @intCast(@ctz(x));
}

/// d = a * b (+ c): low 32 bits.
fn lowerMul(l: *Lw, d: u16, a0: kir.Arg, b0: kir.Arg, c: ?kir.Arg) Error!void {
    const w = l.w;
    var a = a0;
    var b = b0;
    if (argImm(a) != null and argImm(b) == null) {
        const t = a;
        a = b;
        b = t;
    }
    if (argImm(a)) |x| if (argImm(b)) |y| {
        const p = x *% y;
        if (c) |cc| {
            return alu2(w, .add_u, d, false, try l.arg(cc, .c2, false, false), try fit(w, Opnd.imm(p), .c2, false, l.loop));
        }
        return mov(w, d, false, Opnd.imm(p), .u32);
    };
    if (c == null) if (isPow2Imm(b)) |s| {
        return alu2(w, .shl_b, d, false, try l.arg(a, .c2, false, false), Opnd.imm(s));
    };
    if (mul24(w, a, b, l.in.ty)) |op| {
        if (c) |cc| {
            if (regSecond(w, a, b)) {
                const t = a;
                a = b;
                b = t;
            }
            return alu3(w, if (op == .mul_u24) .mad_u24 else .mad_s24, d, false, try l.arg(a, .c3, false, false), try l.arg(b, .c3mid, false, false), try l.arg(cc, .c3, false, false));
        }
        return alu2(w, op, d, false, try l.arg(a, .c2, false, false), try l.arg(b, .c2, false, false));
    }
    const prod = if (c != null) try newVreg(w, .full) else d;
    if (argImm(b)) |y| if (y < 65536) {
        // a.lo * y + (y * a.hi) << 16
        const t = try newVreg(w, .full);
        try alu2(w, .mull_u, t, false, try l.arg(a, .c2, false, false), try fit(w, Opnd.imm(y), .c2, false, l.loop));
        try alu3(w, .madsh_m16, prod, false, try fit(w, Opnd.imm(y), .c3, false, l.loop), try l.arg(a, .c3mid, false, false), Opnd.reg(t, false));
        if (c) |cc| try alu2(w, .add_u, d, false, Opnd.reg(prod, false), try l.arg(cc, .c2, false, false));
        return;
    };
    // a.lo*b.lo + (a.lo*b.hi + b.lo*a.hi) << 16
    const t1 = try newVreg(w, .full);
    const t2 = try newVreg(w, .full);
    const ra = try l.arg(a, .c3mid, false, false);
    const rb = try l.arg(b, .c3mid, false, false);
    try alu2(w, .mull_u, t1, false, ra, rb);
    try alu3(w, .madsh_m16, t2, false, ra, rb, Opnd.reg(t1, false));
    try alu3(w, .madsh_m16, prod, false, rb, ra, Opnd.reg(t2, false));
    if (c) |cc| try alu2(w, .add_u, d, false, Opnd.reg(prod, false), try l.arg(cc, .c2, false, false));
}

fn lowerFusedImad(l: *Lw) Error!void {
    const w = l.w;
    const j = w.fuse_with[l.i];
    const m = w.insts[j];
    const other = if (argReg(l.in.a) == vid(m.dst)) l.in.b else l.in.a;
    try lowerMul(l, l.dst(), m.a, m.b, other);
}

/// The high 32 bits of the 64-bit product, from 16-bit pieces.
fn lowerMulHi(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const a = try l.arg(in.a, .c2, false, false);
    const b = try l.arg(in.b, .c2, false, false);
    const v = struct {
        fn t(ww: *Work) Error!u16 {
            return newVreg(ww, .full);
        }
    };
    const ah = try v.t(w);
    const bh = try v.t(w);
    try alu2(w, .shr_b, ah, false, a, Opnd.imm(16));
    try alu2(w, .shr_b, bh, false, b, Opnd.imm(16));
    const p0 = try v.t(w);
    const p1 = try v.t(w);
    const p2 = try v.t(w);
    const p3 = try v.t(w);
    try alu2(w, .mull_u, p0, false, a, b);
    try alu2(w, .mull_u, p1, false, a, Opnd.reg(bh, false));
    try alu2(w, .mull_u, p2, false, Opnd.reg(ah, false), b);
    try alu2(w, .mull_u, p3, false, Opnd.reg(ah, false), Opnd.reg(bh, false));
    const lo16 = try fit(w, Opnd.imm(0xffff), .c2, false, l.loop);
    const m0 = try v.t(w);
    const m1 = try v.t(w);
    const m2 = try v.t(w);
    const m3 = try v.t(w);
    const m4 = try v.t(w);
    try alu2(w, .shr_b, m0, false, Opnd.reg(p0, false), Opnd.imm(16));
    try alu2(w, .and_b, m1, false, Opnd.reg(p1, false), lo16);
    try alu2(w, .add_u, m2, false, Opnd.reg(m0, false), Opnd.reg(m1, false));
    try alu2(w, .and_b, m3, false, Opnd.reg(p2, false), lo16);
    try alu2(w, .add_u, m4, false, Opnd.reg(m2, false), Opnd.reg(m3, false));
    const carry = try v.t(w);
    try alu2(w, .shr_b, carry, false, Opnd.reg(m4, false), Opnd.imm(16));
    const h1 = try v.t(w);
    const h2 = try v.t(w);
    const r1 = try v.t(w);
    const r2 = try v.t(w);
    try alu2(w, .shr_b, h1, false, Opnd.reg(p1, false), Opnd.imm(16));
    try alu2(w, .shr_b, h2, false, Opnd.reg(p2, false), Opnd.imm(16));
    try alu2(w, .add_u, r1, false, Opnd.reg(p3, false), Opnd.reg(h1, false));
    try alu2(w, .add_u, r2, false, Opnd.reg(r1, false), Opnd.reg(h2, false));
    if (in.ty != .i32) return alu2(w, .add_u, d, false, Opnd.reg(r2, false), Opnd.reg(carry, false));
    // signed: minus (a < 0 ? b : 0) + (b < 0 ? a : 0)
    const r3 = try v.t(w);
    try alu2(w, .add_u, r3, false, Opnd.reg(r2, false), Opnd.reg(carry, false));
    const sa = try v.t(w);
    const sb = try v.t(w);
    const ta = try v.t(w);
    const tb = try v.t(w);
    const r4 = try v.t(w);
    try alu2(w, .ashr_b, sa, false, a, Opnd.imm(31));
    try alu2(w, .ashr_b, sb, false, b, Opnd.imm(31));
    try alu2(w, .and_b, ta, false, Opnd.reg(sa, false), b);
    try alu2(w, .and_b, tb, false, Opnd.reg(sb, false), a);
    try alu2(w, .sub_u, r4, false, Opnd.reg(r3, false), Opnd.reg(ta, false));
    try alu2(w, .sub_u, d, false, Opnd.reg(r4, false), Opnd.reg(tb, false));
}

fn lowerBfe(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const signed = in.ty == .i32;
    if (argImm(in.b)) |b0| if (argImm(in.c)) |c0| {
        const b = b0 & 31;
        const c = @min(c0, 32 - b);
        if (c == 0) return mov(w, d, false, Opnd.imm(0), .u32);
        const a = try l.arg(in.a, .c2, false, false);
        if (b + c >= 32) {
            if (b == 0) return mov(w, d, false, try l.arg(in.a, .any, false, false), .u32);
            return alu2(w, if (signed) .ashr_b else .shr_b, d, false, a, Opnd.imm(b));
        }
        if (!signed) {
            const mask: u32 = (@as(u32, 1) << @intCast(c)) - 1;
            if (b == 0) return alu2(w, .and_b, d, false, a, try fit(w, Opnd.imm(mask), .c2, false, l.loop));
            return alu3(w, .shrm, d, false, Opnd.imm(b), try l.arg(in.a, .c3mid, false, false), try fit(w, Opnd.imm(mask), .c3alt, false, l.loop));
        }
        const t = try newVreg(w, .full);
        try alu2(w, .shl_b, t, false, a, Opnd.imm(32 - b - c));
        return alu2(w, .ashr_b, d, false, Opnd.reg(t, false), Opnd.imm(32 - c));
    };
    // A register offset whose bounds keep the field inside the word, and an
    // immediate width: one shrm (u32), or shl + ashr (i32).
    if (argImm(in.c)) |c0| if (argBounds(w, in.b, .u32)) |rb| if (rb[0] >= 0 and c0 > 0 and c0 < 32 and rb[1] + c0 <= 32) {
        const x = try l.arg(in.a, .c3mid, false, false);
        const off = try l.arg(in.b, .c3alt, false, false);
        if (!signed) {
            const mask: u32 = (@as(u32, 1) << @intCast(c0)) - 1;
            return alu3(w, .shrm, d, false, off, x, try fit(w, Opnd.imm(mask), .c3alt, false, l.loop));
        }
        const s1 = try newVreg(w, .full);
        const y = try newVreg(w, .full);
        try alu2(w, .sub_u, s1, false, Opnd.imm(32 - c0), try l.arg(in.b, .c2, false, false));
        try alu2(w, .shl_b, y, false, try l.arg(in.a, .c2, false, false), Opnd.reg(s1, false));
        return alu2(w, .ashr_b, d, false, Opnd.reg(y, false), Opnd.imm(32 - c0));
    };
    // General, with registers: offset & 31, width clamped to 32 - offset.
    const a = try l.arg(in.a, .c2, false, false);
    const b = try l.arg(in.b, .c2, false, false);
    const c = try l.arg(in.c, .c2, false, false);
    const t = struct {
        fn f(ww: *Work) Error!u16 {
            return newVreg(ww, .full);
        }
    };
    const b31 = try t.f(w);
    const room = try t.f(w);
    const width = try t.f(w);
    try alu2(w, .and_b, b31, false, b, Opnd.imm(31));
    try alu2(w, .sub_u, room, false, Opnd.imm(32), Opnd.reg(b31, false));
    try alu2(w, .min_u, width, false, c, Opnd.reg(room, false));
    if (!signed) {
        const mask = try t.f(w);
        try alu2(w, .mgen_b, mask, false, Opnd.imm(0), Opnd.reg(width, false));
        return alu3(w, .shrm, d, false, Opnd.reg(b31, false), try l.arg(in.a, .c3mid, false, false), Opnd.reg(mask, false));
    }
    // signed: (a << (32 - b - c)) >> (32 - c), arithmetic; width 0 gives 0
    const s1 = try t.f(w);
    const s2 = try t.f(w);
    const y = try t.f(w);
    const z = try t.f(w);
    const r0 = try t.f(w);
    try alu2(w, .sub_u, s1, false, Opnd.reg(room, false), Opnd.reg(width, false));
    try alu2(w, .sub_u, s2, false, Opnd.imm(32), Opnd.reg(width, false));
    try alu2(w, .shl_b, y, false, a, Opnd.reg(s1, false));
    try alu2(w, .ashr_b, r0, false, Opnd.reg(y, false), Opnd.reg(s2, false));
    try cmp2(w, .cmps_u, .eq, z, Opnd.reg(width, false), Opnd.imm(0));
    try alu3(w, .sel_b32, d, false, try fit(w, Opnd.imm(0), .c3, false, l.loop), Opnd.reg(z, false), Opnd.reg(r0, false));
}

// ── ir3's operand rules ─────────────────────────────────────────────────────
//
// Mesa's ir3_valid_flags (read as documentation), as adreno.device's
// checker enforces them:
// - cat2: at most one source from the const/shared ("uniform") file (the
//   hardware hands one's value to both: the Surface's 16 MiB fault), and
//   not two immediates;
// - cat3: the second source a per-fiber register; immediates only in the
//   shift-and-mask forms' first and third; no plain const in those forms or
//   the dot products;
// - cat4 (SFU): a per-fiber register source (no const, immediate, shared);
// - cat6: addresses, offsets, stored values and shuffled values in
//   per-fiber registers, a shuffle's lane not a const.
// What breaks one goes through a register, copied once at the start (every
// such operand is a constant, an immediate or a shared register: the same
// for the whole kernel).

fn srcUniform(m: *const MI, i: usize) bool {
    const s = m.in.src[i];
    if (s.kind == .cnst or s.kind == .rel_cnst) return true;
    return s.kind == .gpr and !s.half and m.src[i] != NONE and isPhys(m.src[i]) and
        (m.src[i] & ~PHYS) >= ir3.SHARED_BASE and (m.src[i] & ~PHYS) < ir3.A0_X;
}

fn srcImm(m: *const MI, i: usize) bool {
    return m.in.src[i].kind == .imm or m.in.src[i].kind == .flut;
}

/// An ordinary per-fiber register (not shared, not a const or immediate).
fn srcPlain(m: *const MI, i: usize) bool {
    const s = m.in.src[i];
    if (s.kind != .gpr) return false;
    if (m.src[i] == NONE) return false;
    if (!isPhys(m.src[i])) return true;
    return (m.src[i] & ~PHYS) < ir3.SHARED_BASE;
}

/// The value of float-table entry `idx` as bits (the entries flutIndex uses).
fn flutBits(idx: u32, half: bool) u32 {
    const f32s = [_]u32{ 0x00000000, 0x3f000000, 0x3f800000, 0x40000000, 0, 0, 0, 0, 0, 0, 0, 0x40800000 };
    const f16s = [_]u32{ 0x0000, 0x3800, 0x3c00, 0x4000, 0, 0, 0, 0, 0, 0, 0, 0x4400 };
    if (idx >= f32s.len) return 0;
    return if (half) f16s[idx] else f32s[idx];
}

/// Put source `i` of `m` in a register (a copy made at the start).
fn srcToReg(w: *Work, m: *MI, i: usize) Error!void {
    const s = m.in.src[i];
    var o = Opnd{ .half = s.half, .neg = s.neg, .abs = s.abs, .bnot = s.bnot };
    switch (s.kind) {
        .gpr => {
            o.k = .vreg;
            o.v = m.src[i];
        },
        .cnst => {
            o.k = .cnst;
            o.x = s.num;
        },
        .imm => {
            o.k = .imm;
            o.x = s.imm;
        },
        .flut => {
            o.k = .imm;
            o.x = flutBits(s.imm, s.half);
        },
        else => return error.BadOperand,
    }
    const reg = try materialize(w, o, true);
    setSrc(m, i, reg);
    m.in.src[i].half = s.half;
}

fn legalizeOperands(w: *Work) Error!void {
    for (w.mi[0..w.n_mi]) |*m| {
        if (m.kind != .op and m.kind != .copy) continue;
        switch (m.in.op.category()) {
            2 => {
                // (an integer immediate past -511..511 is not encodable)
                for ([_]usize{ 0, 1 }) |i| {
                    if (m.in.src[i].kind == .imm and !fitsImm11(m.in.src[i].imm)) try srcToReg(w, m, i);
                }
                if (m.in.src[1].kind == .none) continue;
                if ((srcUniform(m, 0) and srcUniform(m, 1)) or (srcImm(m, 0) and srcImm(m, 1))) try srcToReg(w, m, 1);
            },
            3 => {
                const alt = switch (m.in.op) {
                    .shrm, .shlm, .shrg, .shlg, .andg => true,
                    else => false,
                };
                const dot = m.in.op == .dp4acc or m.in.op == .dp2acc;
                if (!srcPlain(m, 1)) try srcToReg(w, m, 1);
                for ([_]usize{ 0, 2 }) |i| {
                    const s = m.in.src[i];
                    if (s.kind == .none) continue;
                    if (s.kind == .cnst and (alt or dot)) try srcToReg(w, m, i) else if (srcImm(m, i) and !alt) try srcToReg(w, m, i);
                }
            },
            4 => if (!srcPlain(m, 0)) try srcToReg(w, m, 0),
            // (the shift-and-mask forms' immediates are 12 bits, unsigned:
            // fit keeps them so; the others take none, handled above)
            6 => switch (m.in.op) {
                .ldg_a, .stg_a => {
                    if (!srcPlain(m, 1)) try srcToReg(w, m, 1);
                    if (m.in.op == .stg_a and !srcPlain(m, 2)) try srcToReg(w, m, 2);
                },
                .ldl, .stl => {
                    if (!srcPlain(m, 0)) try srcToReg(w, m, 0);
                    if (m.in.op == .stl and !srcPlain(m, 1)) try srcToReg(w, m, 1);
                },
                .shfl => {
                    if (!srcPlain(m, 0)) try srcToReg(w, m, 0);
                    if (m.in.src[1].kind == .cnst or m.in.src[1].kind == .rel_cnst) try srcToReg(w, m, 1);
                },
                else => {},
            },
            else => {},
        }
    }
}

fn lowerDot4(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const mode: kir.Dot4 = @enumFromInt(@as(u8, @truncate(in.aux)));
    if (!w.caps.dot4) return error.Unsupported;
    switch (mode) {
        .s8u8, .u8u8 => {
            var m = MI{ .dst = d };
            m.in.op = .dp4acc;
            m.in.mixed = mode == .s8u8;
            setSrc(&m, 0, try l.arg(in.a, .c3, false, false));
            setSrc(&m, 1, try l.arg(in.b, .c3mid, false, false));
            setSrc(&m, 2, try l.arg(in.c, .c3, false, false));
            try put(w, m);
        },
        .s8s8 => {
            // a . b = mixed(a, b ^ 0x80808080, c) - 128 * mixed(a, 0x01010101, 0)
            const u = try newVreg(w, .full);
            try alu2(w, .xor_b, u, false, try l.arg(in.b, .c2, false, false), try fit(w, Opnd.imm(0x80808080), .c2, false, l.loop));
            const p = try newVreg(w, .full);
            const s = try newVreg(w, .full);
            const s7 = try newVreg(w, .full);
            const a = try l.arg(in.a, .c3, false, false);
            var m = MI{ .dst = p };
            m.in.op = .dp4acc;
            m.in.mixed = true;
            setSrc(&m, 0, a);
            setSrc(&m, 1, Opnd.reg(u, false));
            setSrc(&m, 2, try l.arg(in.c, .c3, false, false));
            try put(w, m);
            var m2 = MI{ .dst = s };
            m2.in.op = .dp4acc;
            m2.in.mixed = true;
            setSrc(&m2, 0, a);
            setSrc(&m2, 1, try fit(w, Opnd.imm(0x01010101), .c3mid, false, l.loop));
            setSrc(&m2, 2, try fit(w, Opnd.imm(0), .c3, false, l.loop));
            try put(w, m2);
            try alu2(w, .shl_b, s7, false, Opnd.reg(s, false), Opnd.imm(7));
            try alu2(w, .sub_u, d, false, Opnd.reg(p, false), Opnd.reg(s7, false));
        },
    }
}

fn irType(ty: kir.Ty) ir3.Type {
    return switch (ty) {
        .f32 => .f32,
        .f16 => .f16,
        .i32 => .s32,
        else => .u32,
    };
}

fn lowerCvt(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const cv: kir.Cvt = @bitCast(in.aux);
    const from = cv.from;
    const to = cv.to;
    const fh = from == .f16;
    if (from == to) return mov(w, d, to == .f16, try l.arg(in.a, .any, false, fh), if (fh) .u16 else .u32);
    const isInt = struct {
        fn f(t: kir.Ty) bool {
            return t == .u32 or t == .i32 or t == .pred;
        }
    }.f;
    if (isInt(from) and isInt(to)) {
        if (to == .pred) return cmp2(w, .cmps_u, .ne, d, try l.arg(in.a, .c2, false, false), Opnd.imm(0));
        return mov(w, d, false, try l.arg(in.a, .any, false, false), .u32);
    }
    if (from == .f32 and to == .f16) {
        const r: ir3.Round = switch (cv.round) {
            .rne => .even,
            .rz => .none,
            else => return error.Unsupported,
        };
        return cov(w, d, true, try l.arg(in.a, .c6, false, false), .f32, .f16, r);
    }
    if (from == .f16 and to == .f32) {
        if (w.fuse[l.i] == .half_lo or w.fuse[l.i] == .half_hi) {
            // the f16 is a half of a full register
            const j = w.fuse_with[l.i];
            const x = argReg(w.insts[j].a).?;
            var o = Opnd.reg(x, true);
            o.view = if (w.fuse[l.i] == .half_hi) 2 else 1;
            w.vi[unitHeadOf(w, x)].low = true;
            return cov(w, d, false, o, .f16, .f32, .none);
        }
        return cov(w, d, false, try l.arg(in.a, .c6, false, true), .f16, .f32, .none);
    }
    if (isInt(from) and (to == .f32 or to == .f16)) {
        if (cv.round != .rne) return error.Unsupported;
        const src = try l.arg(in.a, .c6, false, false);
        const st: ir3.Type = if (from == .i32) .s32 else .u32;
        if (to == .f32) return cov(w, d, false, src, st, .f32, .none);
        const t = try newVreg(w, .full);
        try cov(w, t, false, src, st, .f32, .none);
        return cov(w, d, true, Opnd.reg(t, false), .f32, .f16, .even);
    }
    if ((from == .f32 or from == .f16) and isInt(to)) {
        // round to an integral value, then convert with saturation and NaN -> 0
        var x = try l.arg(in.a, .c2f, true, fh);
        if (fh) {
            const t = try newVreg(w, .full);
            try cov(w, t, false, try fit(w, x, .c6, false, l.loop), .f16, .f32, .none);
            x = Opnd.reg(t, false);
        }
        const rop: ir3.Op = switch (cv.round) {
            .rne => .rndne_f,
            .rz => .trunc_f,
            .rd => .floor_f,
            .ru => .ceil_f,
        };
        if (trust_cov_saturation) {
            // cov rounds toward zero, saturates and sends NaN to 0 itself
            var src = try fit(w, x, .c6, false, l.loop);
            if (cv.round != .rz) {
                const y = try newVreg(w, .full);
                try alu1(w, rop, y, false, x);
                src = Opnd.reg(y, false);
            }
            return cov(w, d, false, src, .f32, if (to == .i32) .s32 else .u32, .none);
        }
        const y = try newVreg(w, .full);
        try alu1(w, rop, y, false, x);
        const yo = Opnd.reg(y, false);
        const r = try newVreg(w, .full);
        if (to == .i32) {
            try cov(w, r, false, yo, .f32, .s32, .none);
            const hi = try newVreg(w, .full);
            const lo = try newVreg(w, .full);
            const nan = try newVreg(w, .full);
            const r1 = try newVreg(w, .full);
            const r2 = try newVreg(w, .full);
            try cmp2(w, .cmps_f, .ge, hi, yo, try fit(w, Opnd.imm(0x4f000000), .c2f, true, l.loop));
            try alu3(w, .sel_b32, r1, false, try fit(w, Opnd.imm(0x7fffffff), .c3, false, l.loop), Opnd.reg(hi, false), Opnd.reg(r, false));
            try cmp2(w, .cmps_f, .lt, lo, yo, try fit(w, Opnd.imm(0xcf000000), .c2f, true, l.loop));
            try alu3(w, .sel_b32, r2, false, try fit(w, Opnd.imm(0x80000000), .c3, false, l.loop), Opnd.reg(lo, false), Opnd.reg(r1, false));
            try cmp2(w, .cmps_f, .ne, nan, yo, yo);
            try alu3(w, .sel_b32, d, false, try fit(w, Opnd.imm(0), .c3, false, l.loop), Opnd.reg(nan, false), Opnd.reg(r2, false));
        } else {
            try cov(w, r, false, yo, .f32, .u32, .none);
            const hi = try newVreg(w, .full);
            const ok = try newVreg(w, .full);
            const r1 = try newVreg(w, .full);
            try cmp2(w, .cmps_f, .ge, hi, yo, try fit(w, Opnd.imm(0x4f800000), .c2f, true, l.loop));
            try alu3(w, .sel_b32, r1, false, try fit(w, Opnd.imm(0xffffffff), .c3, false, l.loop), Opnd.reg(hi, false), Opnd.reg(r, false));
            // (false for NaN and negatives)
            try cmp2(w, .cmps_f, .ge, ok, yo, .{ .k = .flut, .x = 0 });
            try alu3(w, .sel_b32, d, false, Opnd.reg(r1, false), Opnd.reg(ok, false), try fit(w, Opnd.imm(0), .c3, false, l.loop));
        }
        return;
    }
    return error.BadType;
}

fn lowerLane(l: *Lw) Error!void {
    const w = l.w;
    const d = l.dst();
    // Fibers fill waves in linear order (SP_CS_WIE_CNTL_1's raster order is
    // linear), x fastest, as KIR's subgroups are.
    try alu2(w, .and_b, d, false, try linearTid(w), Opnd.imm(w.threadsize - 1));
}

/// The thread's linear index in its group (x fastest), computed once at
/// the start.
fn linearTid(w: *Work) Error!Opnd {
    w.uses_tid = true;
    if (w.group[1] == 1 and w.group[2] == 1) return Opnd.reg(PHYS | 0, false);
    if (w.linear_tid != NONE) return Opnd.reg(w.linear_tid, false);
    var yz: Opnd = Opnd.reg(PHYS | 1, false);
    if (w.group[2] > 1) {
        const t = try newVreg(w, .full);
        var m = MI{ .dst = t };
        m.in.op = .mad_u24;
        // t = z * gy + y (gy in a register: cat3's second source)
        setSrc(&m, 0, Opnd.reg(PHYS | 2, false));
        setSrc(&m, 1, try materialize(w, Opnd.imm(w.group[1]), true));
        setSrc(&m, 2, Opnd.reg(PHYS | 1, false));
        try putPro(w, m);
        yz = Opnd.reg(t, false);
    }
    const lin = try newVreg(w, .full);
    var m2 = MI{ .dst = lin };
    m2.in.op = .mad_u24;
    setSrc(&m2, 0, yz);
    setSrc(&m2, 1, try materialize(w, Opnd.imm(w.group[0]), true));
    setSrc(&m2, 2, Opnd.reg(PHYS | 0, false));
    try putPro(w, m2);
    w.linear_tid = lin;
    return Opnd.reg(lin, false);
}

/// The address register and immediate of a memory access: base + a + imm.
const Addr = struct { reg: Opnd, off: u32 };

fn address(l: *Lw, a: kir.Arg, imm: u32, max_off: u32) Error!Addr {
    const w = l.w;
    if (argImm(a)) |x| {
        const total = x +% imm;
        if (total <= max_off) return .{ .reg = try fit(w, Opnd.imm(0), .c6, false, l.loop), .off = total };
        const hi = total & ~max_off;
        return .{ .reg = try fit(w, Opnd.imm(hi), .c6, false, l.loop), .off = total & max_off };
    }
    const r = try l.arg(a, .c6, false, false);
    if (imm <= max_off) return .{ .reg = r, .off = imm };
    const t = try newVreg(w, .full);
    try alu2(w, .add_u, t, false, r, try fit(w, Opnd.imm(imm & ~max_off), .c2, false, l.loop));
    return .{ .reg = Opnd.reg(t, false), .off = imm & max_off };
}

fn bindingConst(w: *const Work, b: u8) Error!u16 {
    if (b >= w.bindings) return error.BadBinding;
    return @intCast(2 * @as(u32, b));
}

fn lowerLoad(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const m: kir.Mem = @bitCast(in.aux);
    const n = memCount(m);
    const shared = m.space == .shared;
    const ad = try address(l, in.a, m.imm, if (shared) 4095 else 255);
    var mi = MI{ .early = n > 1 };
    mi.in.op = if (shared) .ldl else .ldg_a;
    if (shared) {
        setSrc(&mi, 0, ad.reg);
        mi.in.off = @intCast(ad.off);
    } else {
        setSrc(&mi, 0, Opnd.cnst(try bindingConst(w, m.binding)));
        setSrc(&mi, 1, ad.reg);
        mi.in.off = @intCast(ad.off);
    }
    mi.in.size = n;
    switch (m.width_log2) {
        5, 6, 7 => {
            if (in.ty == .f16) return error.BadType;
            mi.in.ty = if (in.ty == .f32) .f32 else .u32;
            mi.dst = d;
            mi.dn = n;
            try put(w, mi);
            if (n > 1) try vecRange(w, d, n);
        },
        4 => {
            if (in.ty == .f16) {
                mi.in.ty = .f16;
                mi.in.dst.half = true;
                mi.dst = d;
                try put(w, mi);
                return;
            }
            const t = try newVreg(w, .half);
            mi.in.ty = if (m.signed) .s16 else .u16;
            mi.in.dst.half = true;
            mi.dst = t;
            try put(w, mi);
            try cov(w, d, false, Opnd.reg(t, true), if (m.signed) .s16 else .u16, if (m.signed) .s32 else .u32, .none);
        },
        3 => {
            if (in.ty == .f16 or in.ty == .f32) return error.BadType;
            const t = try newVreg(w, .half);
            mi.in.ty = .u8;
            mi.in.dst.half = true;
            mi.dst = t;
            try put(w, mi);
            try cov(w, d, false, Opnd.reg(t, true), if (m.signed) .u8_32 else .u16, if (m.signed) .s32 else .u32, .none);
        },
        else => return error.BadOperand,
    }
}

fn lowerStore(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const m: kir.Mem = @bitCast(in.aux);
    const n = memCount(m);
    const shared = m.space == .shared;
    const ad = try address(l, in.a, m.imm, if (shared) 4095 else 255);
    // the value's type: the register's
    const vty: kir.Ty = if (argReg(in.b)) |v| (if (v < w.nv) w.vi[v].ty else in.ty) else in.ty;
    var mi = MI{};
    mi.in.op = if (shared) .stl else .stg_a;
    const vslot: usize = if (shared) 1 else 2;
    if (shared) {
        setSrc(&mi, 0, ad.reg);
    } else {
        setSrc(&mi, 0, Opnd.cnst(try bindingConst(w, m.binding)));
        setSrc(&mi, 1, ad.reg);
    }
    mi.in.off = @intCast(ad.off);
    mi.in.size = n;
    switch (m.width_log2) {
        5, 6, 7 => {
            if (vty == .f16) return error.BadType;
            mi.in.ty = if (vty == .f32) .f32 else .u32;
            const v = try l.arg(in.b, .c6, false, false);
            setSrc(&mi, vslot, v);
            mi.sn[vslot] = n;
            if (n > 1) {
                const r = argReg(in.b) orelse return error.BadOperand;
                try vecRange(w, r, n);
            }
            try put(w, mi);
        },
        4, 3 => {
            var hv: Opnd = undefined;
            if (vty == .f16 and m.width_log2 == 4) {
                hv = try l.arg(in.b, .c6, false, true);
                mi.in.ty = .f16;
            } else {
                if (vty == .f16) return error.BadType;
                const v = try l.arg(in.b, .c6, false, false);
                const t = try newVreg(w, .half);
                try cov(w, t, true, v, .u32, .u16, .none);
                hv = Opnd.reg(t, true);
                mi.in.ty = if (m.width_log2 == 4) .u16 else .u8;
            }
            setSrc(&mi, vslot, hv);
            mi.in.src[vslot].half = true;
            try put(w, mi);
        },
        else => return error.BadOperand,
    }
}

fn lowerAtom(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const mem = memOf(in.aux);
    const kx = argImm(in.c) orelse return error.BadOperand;
    if (kx > @intFromEnum(kir.Atom.xchg)) return error.BadOperand;
    const kind: kir.Atom = @enumFromInt(@as(u8, @intCast(kx)));
    const shared = mem.space == .shared;
    const op: ir3.Op = switch (kind) {
        .add => if (shared) .atomic_add else .atomic_g_add,
        .min => if (shared) .atomic_min else .atomic_g_min,
        .max => if (shared) .atomic_max else .atomic_g_max,
        .xchg => if (shared) .atomic_xchg else .atomic_g_xchg,
    };
    const val = try l.arg(in.b, .c6, false, false);
    var mi = MI{ .dst = d, .early = true };
    mi.in.op = op;
    mi.in.typed = false;
    mi.in.d = 1;
    mi.in.type_size = 1;
    mi.in.ty = if (in.ty == .i32) .s32 else .u32;
    if (shared) {
        const ad = try address(l, in.a, mem.imm, 0);
        setSrc(&mi, 0, ad.reg);
    } else {
        // the 64-bit address in a register pair
        const base = try bindingConst(w, mem.binding);
        var off: Opnd = undefined;
        if (argImm(in.a)) |x| {
            off = try fit(w, Opnd.imm(x +% mem.imm), .c2, false, l.loop);
        } else if (mem.imm != 0) {
            const t = try newVreg(w, .full);
            try alu2(w, .add_u, t, false, try l.arg(in.a, .c2, false, false), try fit(w, Opnd.imm(mem.imm), .c2, false, l.loop));
            off = Opnd.reg(t, false);
        } else off = try l.arg(in.a, .c2, false, false);
        const pair = try newVec(w, .full, 2);
        const carry = try newVreg(w, .full);
        try alu2(w, .add_u, pair, false, Opnd.cnst(base), off);
        // carry when the low word wrapped: lo < off
        const offr = if (off.k == .vreg) off else try fit(w, off, .c6, false, l.loop);
        try cmp2(w, .cmps_u, .lt, carry, Opnd.reg(pair, false), offr);
        try alu2(w, .add_u, pair + 1, false, Opnd.cnst(base + 1), Opnd.reg(carry, false));
        try vecRange(w, pair, 2);
        setSrc(&mi, 0, Opnd.reg(pair, false));
        mi.sn[0] = 2;
    }
    setSrc(&mi, 1, val);
    try put(w, mi);
}

/// KIR's atom: the Mem in aux's low bits (binding, space, width, signed,
/// imm), the Atom kind where K's kir says.
fn memOf(aux: u32) kir.Mem {
    return @bitCast(aux);
}

fn vecRange(w: *Work, first: u16, n: u8) Error!void {
    for (0..n) |k| {
        const v = first + @as(u16, @intCast(k));
        if (v >= w.nv) return error.BadOperand;
        if (w.vi[v].cls != w.vi[first].cls) return error.BadType;
    }
    // merge into an existing range when they overlap
    const r = rangeOf(w, first);
    var lo = first;
    var hi = first + n;
    if (r) |rr| {
        lo = @min(lo, rr[0]);
        hi = @max(hi, rr[1]);
    }
    const r2 = rangeOf(w, first + n - 1);
    if (r2) |rr| {
        lo = @min(lo, rr[0]);
        hi = @max(hi, rr[1]);
    }
    var v = lo;
    while (v < hi) : (v += 1) w.vi[v].head = lo;
    w.vi[lo].len = hi - lo;
}

fn unitHeadOf(w: *const Work, v: u16) u16 {
    const h = w.vi[v].head;
    return if (h == NONE) v else h;
}

fn rangeOf(w: *const Work, v: u16) ?[2]u16 {
    const h = w.vi[v].head;
    if (h == NONE) return null;
    return .{ h, h + w.vi[h].len };
}

fn lowerShfl(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const mode: kir.Shfl = @enumFromInt(@as(u8, @truncate(in.aux)));
    const h = l.half();
    const ty: ir3.Type = if (h) .u16 else .u32;
    if (mode != .idx) {
        const direct = argImm(in.b) != null or argUniform(w, in.b);
        if (direct) {
            var m = MI{ .dst = d, .early = true };
            m.in.op = .shfl;
            m.in.shfl = switch (mode) {
                .xor => .xor,
                .up => .up,
                .down => .down,
                .idx => unreachable,
            };
            m.in.ty = ty;
            m.in.dst.half = h;
            setSrc(&m, 0, try l.arg(in.a, .c6, false, h));
            m.in.src[0].half = h;
            // KIR's xor mask is taken modulo the subgroup
            var b = try l.arg(in.b, .c6imm, false, false);
            if (mode == .xor) {
                if (argImm(in.b)) |x| {
                    b = Opnd.imm(x & (w.threadsize - 1));
                } else {
                    const bb = argBounds(w, in.b, .u32);
                    if (bb == null or bb.?[0] < 0 or bb.?[1] >= w.threadsize) {
                        const t = try newVreg(w, .full);
                        try alu2(w, .and_b, t, false, try l.arg(in.b, .c2, false, false), Opnd.imm(w.threadsize - 1));
                        b = Opnd.reg(t, false);
                    }
                }
            }
            setSrc(&m, 1, b);
            try put(w, m);
            return;
        }
    }
    // Through shared memory: every fiber writes its value at its slot of
    // the wave's area, then reads the source lane's.
    if (h) return error.Unsupported;
    w.uses_exchange = true;
    const ws = w.threadsize;
    const tidx = try linearTid(w);
    // slot = exchange + tid * 4; lane = tid & (ws - 1); wave base = slot - lane * 4
    const slot = try newVreg(w, .full);
    try alu2(w, .shl_b, slot, false, tidx, Opnd.imm(2));
    var st = MI{};
    st.in.op = .stl;
    st.in.ty = .u32;
    st.in.size = 1;
    setSrc(&st, 0, Opnd.reg(slot, false));
    setSrc(&st, 1, try l.arg(in.a, .c6, false, false));
    st.in.off = @intCast(w.exchange_at);
    try put(w, st);
    const lane = try newVreg(w, .full);
    try alu2(w, .and_b, lane, false, tidx, Opnd.imm(ws - 1));
    // source lane
    const b = try l.arg(in.b, .c2, false, false);
    // the source lane, as KIR defines it: idx and xor modulo the subgroup;
    // up and down past the ends read the lane's own value
    const src2 = try newVreg(w, .full);
    switch (mode) {
        .idx => try alu2(w, .and_b, src2, false, b, Opnd.imm(ws - 1)),
        .xor => {
            const m = try newVreg(w, .full);
            try alu2(w, .and_b, m, false, b, Opnd.imm(ws - 1));
            try alu2(w, .xor_b, src2, false, Opnd.reg(lane, false), Opnd.reg(m, false));
        },
        .up, .down => {
            const src = try newVreg(w, .full);
            const ok = try newVreg(w, .full);
            if (mode == .up) {
                try alu2(w, .sub_u, src, false, Opnd.reg(lane, false), b);
                try cmp2(w, .cmps_u, .le, ok, b, Opnd.reg(lane, false));
            } else {
                const room = try newVreg(w, .full);
                try alu2(w, .add_u, src, false, Opnd.reg(lane, false), b);
                try alu2(w, .sub_u, room, false, Opnd.imm(ws), Opnd.reg(lane, false));
                try cmp2(w, .cmps_u, .lt, ok, b, Opnd.reg(room, false));
            }
            try alu3(w, .sel_b32, src2, false, Opnd.reg(src, false), Opnd.reg(ok, false), Opnd.reg(lane, false));
        },
    }
    const base = try newVreg(w, .full);
    try alu2(w, .sub_u, base, false, tidx, Opnd.reg(lane, false));
    const at = try newVreg(w, .full);
    try alu2(w, .add_u, at, false, Opnd.reg(base, false), Opnd.reg(src2, false));
    const at4 = try newVreg(w, .full);
    try alu2(w, .shl_b, at4, false, Opnd.reg(at, false), Opnd.imm(2));
    var ld = MI{ .dst = d, .early = true };
    ld.in.op = .ldl;
    ld.in.ty = .u32;
    ld.in.size = 1;
    setSrc(&ld, 0, Opnd.reg(at4, false));
    ld.in.off = @intCast(w.exchange_at);
    try put(w, ld);
}

fn lowerVote(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    const d = l.dst();
    const all = (in.aux & 0xff) != 0;
    try toP0(l, in.a, false);
    // d = 1; any/all taken: skip; d = 0
    try mov(w, d, false, Opnd.imm(1), .u32);
    const skip = newLabel(w);
    try putBranch(w, if (all) .ball else .bany, false, skip);
    try mov(w, d, false, Opnd.imm(0), .u32);
    try putLabel(w, skip);
    w.vi[d].defs = 2;
}

/// The predicate `a` into p0.x (inverted when `inv`). A compare fused into
/// this branch is emitted here.
fn toP0(l: *Lw, a: kir.Arg, inv: bool) Error!void {
    const w = l.w;
    if (w.fuse[l.i] == .branch) {
        const j = w.fuse_with[l.i];
        const c = w.insts[j];
        var cc: kir.Cmp = @enumFromInt(@as(u8, @truncate(c.aux)));
        const ch = operandHalf(w, c);
        const fl = c.op == .fcmp;
        const op: ir3.Op = if (fl) .cmps_f else if (operandTy(w, c) == .i32) .cmps_s else .cmps_u;
        if (inv and !fl) cc = switch (cc) {
            .eq => .ne,
            .ne => .eq,
            .lt => .ge,
            .ge => .lt,
            .gt => .le,
            .le => .gt,
        };
        // (inverting a float compare is not its negation with NaNs: the
        // branch inverts instead)
        var lc = Lw{ .w = w, .i = j, .in = c, .loop = l.loop };
        const sl: Slot = if (fl) .c2f else .c2;
        try cmp2(w, op, cond(cc), PHYS | ir3.P0_X, try lc.arg(c.a, sl, fl, ch), try lc.arg(c.b, sl, fl, ch));
        return;
    }
    try cmp2(w, .cmps_u, if (inv) .eq else .ne, PHYS | ir3.P0_X, try l.arg(a, .c2, false, false), Opnd.imm(0));
}

/// Whether toP0 left p0.x inverted already.
fn p0Inverted(l: *const Lw, inv: bool) bool {
    if (!inv) return false;
    const w = l.w;
    if (w.fuse[l.i] == .branch) {
        const c = w.insts[w.fuse_with[l.i]];
        return c.op != .fcmp;
    }
    return true;
}

fn lowerControl(l: *Lw) Error!void {
    const w = l.w;
    const in = l.in;
    switch (in.op) {
        .@"if" => {
            if (w.n_ctl >= w.ctl.len) return error.TooComplex;
            const l1 = newLabel(w);
            w.ctl[w.n_ctl] = .{ .kind = .if_, .l1 = l1 };
            w.n_ctl += 1;
            w.max_depth = @max(w.max_depth, w.n_ctl);
            if (argImm(in.a)) |x| {
                if (x == 0) try putBranch(w, .jump, false, l1);
                return;
            }
            // skip the then-part when the condition is false
            try toP0(l, in.a, true);
            const done_inv = p0Inverted(l, true);
            try putBranch(w, .br, !done_inv, l1);
        },
        .@"else" => {
            if (w.n_ctl == 0 or w.ctl[w.n_ctl - 1].kind != .if_) return error.Unbalanced;
            const c = &w.ctl[w.n_ctl - 1];
            if (c.has_else) return error.Unbalanced;
            const l2 = newLabel(w);
            try putBranch(w, .jump, false, l2);
            try putLabel(w, c.l1);
            c.l2 = l2;
            c.has_else = true;
        },
        .endif => {
            if (w.n_ctl == 0 or w.ctl[w.n_ctl - 1].kind != .if_) return error.Unbalanced;
            const c = w.ctl[w.n_ctl - 1];
            try putLabel(w, if (c.has_else) c.l2 else c.l1);
            w.n_ctl -= 1;
        },
        .loop => {
            if (w.n_ctl >= w.ctl.len or w.n_loops >= MAX_LOOPS) return error.TooComplex;
            const head = newLabel(w);
            const latch = newLabel(w);
            const exit = newLabel(w);
            try putLabel(w, head);
            w.ctl[w.n_ctl] = .{ .kind = .loop, .l1 = head, .l2 = latch, .l3 = exit, .loop_index = @intCast(w.n_loops), .head_mi = w.n_mi - 1 };
            w.loops[w.n_loops] = .{ .head = w.n_mi - 1, .end = 0, .depth = @intCast(w.n_ctl) };
            w.n_loops += 1;
            w.n_ctl += 1;
            w.max_depth = @max(w.max_depth, w.n_ctl);
        },
        .brk, .cont => {
            const c = innerLoop(w) orelse return error.Unbalanced;
            const target = if (in.op == .brk) c.l3 else c.l2;
            if (in.op == .cont) c.used_latch = true;
            if (argImm(in.a)) |x| {
                if (x != 0) try putBranch(w, .jump, false, target);
                return;
            }
            try toP0(l, in.a, false);
            try putBranch(w, .br, false, target);
        },
        .endloop => {
            if (w.n_ctl == 0 or w.ctl[w.n_ctl - 1].kind != .loop) return error.Unbalanced;
            const c = w.ctl[w.n_ctl - 1];
            if (c.used_latch) try putLabel(w, c.l2);
            // A brk right before endloop: one branch back while the
            // condition is false (a do-while), not a branch out and a jump.
            const last = &w.mi[w.n_mi - 1];
            if (!c.used_latch and last.kind == .branch and last.in.op == .br and last.label == c.l3 and w.n_mi - 1 > c.head_mi) {
                last.label = c.l1;
                last.in.inv1 = !last.in.inv1;
            } else try putBranch(w, .jump, false, c.l1);
            w.loops[c.loop_index].end = w.n_mi - 1;
            try putLabel(w, c.l3);
            w.n_ctl -= 1;
        },
        .ret => {
            w.uses_ret = true;
            if (argImm(in.a)) |x| {
                if (x == 0) return;
            } else if (in.a == .reg and in.a.reg != .none) {
                try toP0(l, in.a, false);
                return putBranch(w, .br, false, w.ret_label);
            }
            try putBranch(w, .jump, false, w.ret_label);
        },
        else => unreachable,
    }
}

fn innerLoop(w: *Work) ?*Ctl {
    var k = w.n_ctl;
    while (k > 0) {
        k -= 1;
        if (w.ctl[k].kind == .loop) return &w.ctl[k];
    }
    return null;
}

// ── 4. Scheduling ───────────────────────────────────────────────────────────

fn isMem(op: ir3.Op) bool {
    return op.category() == 6;
}

fn isBlockEnd(m: *const MI) bool {
    return switch (m.kind) {
        .label, .branch => true,
        else => m.in.op == .bar or m.in.op == .fence or m.in.op == .end,
    };
}

/// Cycles from issuing `p` until a reader may go without waiting.
fn latency(p: *const MI, reader: *const MI) u32 {
    const c = p.in.op.category();
    if (c == 4) return 12; // SFU, through (ss)
    if (c == 6) {
        return switch (p.in.op) {
            .ldl, .shfl, .atomic_add, .atomic_min, .atomic_max, .atomic_xchg => 10,
            .ldg_a, .ldg, .atomic_g_add, .atomic_g_min, .atomic_g_max, .atomic_g_xchg => 24,
            else => 1,
        };
    }
    const rc = reader.in.op.category();
    if (rc >= 1 and rc <= 3) return 3;
    return 6;
}

fn writes(m: *const MI, v: u16) bool {
    if (m.dst == NONE) return false;
    if (v == m.dst) return true;
    return v > m.dst and v < m.dst + m.dn;
}

fn reads(m: *const MI, v: u16) bool {
    for (m.src, m.sn) |s, n| {
        if (s == NONE) continue;
        if (v == s or (v > s and v < s + n)) return true;
    }
    return false;
}

fn memSpace(op: ir3.Op) u8 {
    return switch (op) {
        .ldg, .ldg_a, .stg, .stg_a, .atomic_g_add, .atomic_g_min, .atomic_g_max, .atomic_g_xchg => 1,
        .ldl, .stl, .atomic_add, .atomic_min, .atomic_max, .atomic_xchg => 2,
        else => 0,
    };
}

fn isStoreOrAtomic(op: ir3.Op) bool {
    return switch (op) {
        .stg, .stg_a, .stl => true,
        else => isAtomic(op),
    };
}

fn isAtomic(op: ir3.Op) bool {
    return switch (op) {
        .atomic_add, .atomic_min, .atomic_max, .atomic_xchg, .atomic_g_add, .atomic_g_min, .atomic_g_max, .atomic_g_xchg => true,
        else => false,
    };
}

/// Must `b` stay after `a`?
fn dependsOn(a: *const MI, b: *const MI) bool {
    // registers: read after write, write after read, write after write
    if (a.dst != NONE) {
        for (0..a.dn) |k| {
            const v = a.dst + @as(u16, @intCast(k));
            if (reads(b, v) or writes(b, v)) return true;
        }
    }
    if (b.dst != NONE) {
        for (0..b.dn) |k| {
            const v = b.dst + @as(u16, @intCast(k));
            if (reads(a, v)) return true;
        }
    }
    // memory: stores and atomics stay in order with the same space's accesses
    const sa = memSpace(a.in.op);
    const sb = memSpace(b.in.op);
    if (sa != 0 and sa == sb and (isStoreOrAtomic(a.in.op) or isStoreOrAtomic(b.in.op))) return true;
    // the shuffle exchange: its local memory stays in order with everything
    // (an exchange's stl/ldl are local space: covered above)
    return false;
}

/// Registers (32-bit) live in a window past which the scheduler prefers
/// instructions that free registers to ones that start new values.
pub const SCHED_PRESSURE = 40;

fn countUses(w: *Work, m: *const MI, counts: []u16, delta: i32) void {
    for (m.src, m.sn) |s, n| {
        if (s == NONE or isPhys(s)) continue;
        for (0..n) |k| {
            const v = s + @as(u16, @intCast(k));
            if (v >= w.nv) continue;
            counts[v] = @intCast(@as(i32, counts[v]) + delta);
        }
    }
}

fn schedule(w: *Work) void {
    @memset(w.use_total[0..w.nv], 0);
    @memset(w.use_win[0..w.nv], 0);
    for (w.mi[0..w.n_mi]) |*m| countUses(w, m, &w.use_total, 1);
    var start: u32 = 0;
    while (start < w.n_mi) {
        // a block: [start, end) of ordinary instructions
        if (isBlockEnd(&w.mi[start])) {
            start += 1;
            continue;
        }
        var end = start;
        while (end < w.n_mi and !isBlockEnd(&w.mi[end])) end += 1;
        // long blocks in windows (the work is quadratic in their length)
        var at = start;
        while (at < end) {
            const stop = @min(end, at + SCHED_WINDOW);
            if (stop - at > 2) scheduleBlock(w, at, stop);
            at = stop;
        }
        start = end;
    }
}

/// Instructions scheduled together at most.
pub const SCHED_WINDOW = 256;
const DEP_WORDS = SCHED_WINDOW / 64;

/// Registers instruction `m` frees (sources at their last use, all uses
/// in this window) minus those it starts.
fn pressureDelta(w: *const Work, m: *const MI) i32 {
    var d: i32 = 0;
    if (m.dst != NONE and !isPhys(m.dst)) d += m.dn;
    for (m.src, m.sn, 0..) |s, n, si| {
        if (s == NONE or isPhys(s)) continue;
        // (a register read twice by m counts once)
        var dup = false;
        for (m.src[0..si]) |o| if (o == s) {
            dup = true;
        };
        if (dup) continue;
        for (0..n) |k| {
            const v = s + @as(u16, @intCast(k));
            if (v >= w.nv) continue;
            const mine: u16 = usesBy(m, v);
            if (w.use_total[v] == w.use_win[v] and w.use_win[v] == mine and w.vi[v].defs <= 1) d -= 1;
        }
    }
    return d;
}

fn usesBy(m: *const MI, v: u16) u16 {
    var c: u16 = 0;
    for (m.src, m.sn) |s, n| {
        if (s == NONE or isPhys(s)) continue;
        if (v >= s and v < s + n) c += 1;
    }
    return c;
}

fn scheduleBlock(w: *Work, start: u32, end: u32) void {
    const n = end - start;
    const blk = w.mi[start..end];
    for (blk) |*m| countUses(w, m, &w.use_win, 1);
    defer for (blk) |*m| countUses(w, m, &w.use_win, -1);
    var pressure: i32 = 0;
    // successors as bit sets, predecessors as counts
    for (0..n) |i| {
        w.sched_succ[i] = [_]u64{0} ** DEP_WORDS;
        w.sched_npred[i] = 0;
        w.sched_done[i] = false;
        w.sched_ready[i] = 0;
    }
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (dependsOn(&blk[i], &blk[j])) {
                w.sched_succ[i][j >> 6] |= @as(u64, 1) << @intCast(j & 63);
                w.sched_npred[j] += 1;
            }
        }
    }
    // priorities: the longest latency path to the block's end
    var i: u32 = n;
    while (i > 0) {
        i -= 1;
        var best: u32 = 0;
        var it = SuccIter{ .bits = &w.sched_succ[i], .n = n };
        while (it.next()) |j| best = @max(best, latency(&blk[i], &blk[j]) + w.sched_prio[j]);
        w.sched_prio[i] = best + 1;
    }
    // list scheduling by cycle: the earliest ready, then the most urgent
    var cycle: u32 = 0;
    var placed: u32 = 0;
    while (placed < n) {
        var pick: ?u32 = null;
        var pick_ready: u32 = std.math.maxInt(u32);
        var pick_delta: i32 = 0;
        const tight = pressure >= w.sched_pressure;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            if (w.sched_done[k] or w.sched_npred[k] != 0) continue;
            const rdy = @max(w.sched_ready[k], cycle);
            const dl = pressureDelta(w, &blk[k]);
            // Under pressure: what can issue now, then what starts the fewest
            // registers, then the source's order (it uses what it loads
            // soon); otherwise the earliest ready, then the longest path.
            const better = if (pick == null) true else if (tight and dl != pick_delta)
                dl < pick_delta
            else
                rdy < pick_ready or (rdy == pick_ready and w.sched_prio[k] > w.sched_prio[pick.?]);
            if (better) {
                pick = k;
                pick_ready = rdy;
                pick_delta = dl;
            }
        }
        const sel = pick.?;
        pressure += pick_delta;
        // its reads are done: later picks see the counts without them
        countUses(w, &blk[sel], &w.use_win, -1);
        countUses(w, &blk[sel], &w.use_total, -1);
        w.sched_done[sel] = true;
        w.sched_order[placed] = @intCast(sel);
        var it = SuccIter{ .bits = &w.sched_succ[sel], .n = n };
        while (it.next()) |j| {
            w.sched_npred[j] -= 1;
            w.sched_ready[j] = @max(w.sched_ready[j], pick_ready + latency(&blk[sel], &blk[j]));
        }
        cycle = pick_ready + 1;
        placed += 1;
    }
    for (0..n) |kk| w.tmp_mi[kk] = blk[w.sched_order[kk]];
    @memcpy(blk, w.tmp_mi[0..n]);
    // (the window's reads were taken off use_total as they were placed and
    // off use_win too; put use_win back for the deferred decrement)
    for (blk) |*m| countUses(w, m, &w.use_win, 1);
}

const SuccIter = struct {
    bits: *const [DEP_WORDS]u64,
    n: u32,
    word: u32 = 0,
    cur: u64 = 0,
    started: bool = false,

    fn next(it: *SuccIter) ?u32 {
        if (!it.started) {
            it.started = true;
            it.cur = it.bits[0];
        }
        while (true) {
            if (it.cur != 0) {
                const b: u32 = @ctz(it.cur);
                it.cur &= it.cur - 1;
                const j = it.word * 64 + b;
                if (j < it.n) return j;
                return null;
            }
            it.word += 1;
            if (it.word >= DEP_WORDS) return null;
            it.cur = it.bits[it.word];
        }
    }
};

// ── 5. Register allocation ──────────────────────────────────────────────────

fn unitHead(w: *const Work, v: u16) u16 {
    const h = w.vi[v].head;
    return if (h == NONE) v else h;
}

fn touch(w: *Work, v: u16, pos: u32) void {
    if (v == NONE or isPhys(v)) return;
    const h = unitHead(w, v);
    const info = &w.vi[h];
    if (info.first == NOWHERE or pos < info.first) info.first = pos;
    if (pos > info.last) info.last = pos;
}

fn touchDef(w: *Work, v: u16, pos: u32) void {
    if (v == NONE or isPhys(v)) return;
    touch(w, v, pos);
    const info = &w.vi[unitHead(w, v)];
    if (info.fdef == NOWHERE or pos < info.fdef) info.fdef = pos;
}

fn allocate(w: *Work) Error!void {
    for (0..w.nv) |v| {
        w.vi[v].first = NOWHERE;
        w.vi[v].last = 0;
        w.vi[v].unit = NONE;
        w.vi[v].hint = NONE;
        w.vi[v].fdef = NOWHERE;
    }
    // Input registers: r0.x.. live until their last read.
    var tid_last = [3]u32{ 0, 0, 0 };
    var tid_used = [3]bool{ false, false, false };
    for (w.mi[0..w.n_mi], 0..) |*m, ii| {
        const i: u32 = @intCast(ii);
        for (m.src, m.sn) |s, n| {
            if (s == NONE) continue;
            if (isPhys(s)) {
                const num = s & ~PHYS;
                if (num < 3) {
                    tid_used[num] = true;
                    tid_last[num] = 2 * i;
                }
                continue;
            }
            for (0..n) |k| touch(w, s + @as(u16, @intCast(k)), 2 * i + @intFromBool(m.early));
        }
        if (m.dst != NONE and !isPhys(m.dst)) {
            for (0..m.dn) |k| touchDef(w, m.dst + @as(u16, @intCast(k)), 2 * i + 1);
        }
        if (m.kind == .copy and m.src[0] != NONE and !isPhys(m.src[0]) and m.dst != NONE and w.vi[m.dst].head == NONE and w.vi[m.src[0]].head == NONE) {
            w.vi[m.dst].hint = m.src[0];
        }
    }
    // Loops: what is live into, out of or around a loop lives through all of it.
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 16) : (rounds += 1) {
        changed = false;
        for (w.loops[0..w.n_loops]) |lp| {
            const h = 2 * lp.head;
            const e = 2 * lp.end + 1;
            for (0..w.nv) |vv| {
                const info = &w.vi[vv];
                if (info.first == NOWHERE) continue;
                if (info.last < h or info.first > e) continue;
                // live into, out of, or round the loop (several definitions,
                // or a read before the first: the last turn's value)
                const crosses = info.first < h or info.last > e or w.vi[vv].defs > 1 or info.fdef == NOWHERE or info.fdef > info.first;
                if (!crosses) continue;
                if (info.first > h) {
                    info.first = h;
                    changed = true;
                }
                if (info.last < e) {
                    info.last = e;
                    changed = true;
                }
            }
        }
    }
    // The input registers arrive before every loop: read in one, they live
    // to its end (the next turn reads them again), outer loops included.
    for (0..3) |a| if (tid_used[a]) {
        var grew = true;
        while (grew) {
            grew = false;
            for (w.loops[0..w.n_loops]) |lp| {
                const e = 2 * lp.end + 1;
                if (tid_last[a] >= 2 * lp.head and tid_last[a] < e) {
                    tid_last[a] = e;
                    grew = true;
                }
            }
        }
    };
    // Multiple machine definitions (vote, set) inside straight code are
    // covered by first..last already.
    // Order the allocation units by start.
    var n_units: u32 = 0;
    for (0..w.nv) |vv| {
        const v: u16 = @intCast(vv);
        if (w.vi[v].first == NOWHERE) continue;
        if (w.vi[v].head != NONE and w.vi[v].head != v) continue;
        w.by_start[n_units] = v;
        n_units += 1;
    }
    std.sort.pdq(u16, w.by_start[0..n_units], w, struct {
        fn lt(ww: *Work, a: u16, b: u16) bool {
            return ww.vi[a].first < ww.vi[b].first;
        }
    }.lt);
    var busy = [_]bool{false} ** UNITS;
    // the inputs
    var fixed_end = [3]u32{ 0, 0, 0 };
    for (0..3) |a| if (tid_used[a]) {
        busy[2 * a] = true;
        busy[2 * a + 1] = true;
        fixed_end[a] = tid_last[a];
    };
    var n_active: u32 = 0;
    var max_unit: u32 = 0;
    for (w.by_start[0..n_units]) |v| {
        const info = &w.vi[v];
        // free what ended
        var k: u32 = 0;
        while (k < n_active) {
            const a = w.active[k];
            if (w.vi[a].last < info.first) {
                freeUnits(&busy, w, a);
                w.active[k] = w.active[n_active - 1];
                n_active -= 1;
            } else k += 1;
        }
        for (0..3) |a| if (tid_used[a] and fixed_end[a] < info.first and busy[2 * a]) {
            busy[2 * a] = false;
            busy[2 * a + 1] = false;
            tid_used[a] = false;
        };
        const len: u32 = info.len;
        const width: u32 = if (info.cls == .half) 1 else 2;
        const limit: u32 = if (info.cls == .half or info.low) HALF_UNITS else UNITS;
        var chosen: ?u32 = null;
        if (info.hint != NONE) {
            const hu = w.vi[unitHead(w, info.hint)].unit;
            if (hu != NONE and w.vi[info.hint].cls == info.cls and rangeFree(&busy, hu, len * width)) chosen = hu;
        }
        if (chosen == null) {
            var u: u32 = 0;
            while (u + len * width <= limit) : (u += width) {
                if (rangeFree(&busy, u, len * width)) {
                    chosen = u;
                    break;
                }
            }
        }
        const u = chosen orelse return error.TooManyRegs;
        for (u..u + len * width) |x| busy[x] = true;
        info.unit = @intCast(u);
        max_unit = @max(max_unit, u + len * width);
        w.active[n_active] = v;
        n_active += 1;
    }
    w.stats.full_regs = (max_unit + 7) / 8;
}

fn rangeFree(busy: *const [UNITS]bool, u: u32, n: u32) bool {
    if (u + n > UNITS) return false;
    for (busy[u .. u + n]) |b| if (b) return false;
    return true;
}

fn freeUnits(busy: *[UNITS]bool, w: *const Work, v: u16) void {
    const info = w.vi[v];
    const width: u32 = if (info.cls == .half) 1 else 2;
    for (info.unit..info.unit + info.len * width) |x| busy[x] = false;
}

/// The register number of virtual register `v`.
fn regNum(w: *const Work, v: u16) u16 {
    if (isPhys(v)) return v & ~PHYS;
    const h = unitHead(w, v);
    const info = w.vi[h];
    const off: u16 = v - h;
    if (info.cls == .half) return info.unit + off;
    return info.unit / 2 + off;
}

// ── 6. Text and assembly ────────────────────────────────────────────────────

fn emitText(w: *Work) Error!void {
    var t = ir3.Text{ .buf = &w.text };
    t.print("@localsize {d}, {d}, {d}\n", .{ w.group[0], w.group[1], w.group[2] });
    if (w.uses_tid) t.s("@invocationid(r0.x)\n");
    if (w.uses_gid) t.s("@wgid(r48.x)\n");
    const words = w.pool_at + w.n_pool;
    t.print("@consts {d}\n", .{(@max(words, 1) + 3) / 4});
    const shared = sharedTotal(w);
    if (shared > 0) t.print("@shared {d}\n", .{shared});
    t.print("@threadsize {d}\n", .{w.threadsize});
    if (w.max_depth > 0) t.print("@branchstack {d}\n", .{@max(w.max_depth + 1, 4)});
    var line: [192]u8 = undefined;
    var count: u32 = 0;
    for (w.mi[0..w.n_mi]) |*m| {
        switch (m.kind) {
            .label => {
                t.print("L{d}:\n", .{m.label});
                continue;
            },
            .branch => {
                count += 1;
                switch (m.in.op) {
                    .jump => t.print("jump #L{d}\n", .{m.label}),
                    else => t.print("{s} {s}p0.x, #L{d}\n", .{ m.in.op.name(), if (m.in.inv1) "!" else "", m.label }),
                }
                continue;
            },
            else => {},
        }
        var in = m.in;
        if (m.dst != NONE) in.dst.num = regNum(w, m.dst);
        for (0..4) |k| {
            if (m.src[k] != NONE and in.src[k].kind == .gpr) {
                in.src[k].num = regNum(w, m.src[k]);
                if (m.view[k] != 0) in.src[k].num = in.src[k].num * 2 + (m.view[k] - 1);
            }
        }
        if (m.kind == .copy and in.dst.num == in.src[0].num and in.dst.half == in.src[0].half) continue;
        const s = ir3.format(w.gen, &in, &line) catch |e| {
            note(w, "cannot print {s}: {s}", .{ @tagName(in.op), @errorName(e) });
            return e;
        };
        t.s(s);
        t.s("\n");
        count += 1;
    }
    if (t.overflow) return error.TooManyInsts;
    w.text_len = t.len;
    w.stats.instructions = count;
}

fn sharedTotal(w: *const Work) u32 {
    var s = w.shared_bytes;
    if (w.uses_exchange) {
        const lanes = w.group[0] * w.group[1] * w.group[2];
        const waves = (lanes + w.threadsize - 1) / w.threadsize;
        s = w.exchange_at + waves * w.threadsize * 4;
    }
    return s;
}

fn assembleOut(w: *Work, k: *const kir.Kernel, out: []u8) Error!device.Binary {
    const ak = ir3_asm.assemble(w.gen, w.text[0..w.text_len], &w.asm_work, &w.code) catch |e| {
        const at = w.asm_work.err_line;
        var it = std.mem.splitScalar(u8, w.text[0..w.text_len], '\n');
        var ln: u32 = 0;
        while (it.next()) |s| {
            ln += 1;
            if (ln == at) note(w, "assembler: {s} at line {d}: {s}", .{ @errorName(e), at, s });
        }
        return e;
    };
    const code_bytes = ak.code.len * 8;
    const pool_off = std.mem.alignForward(usize, code_bytes, 16);
    const total = pool_off + w.n_pool * 4;
    if (out.len < total) return error.BufferTooSmall;
    @memcpy(out[0..code_bytes], std.mem.sliceAsBytes(ak.code));
    @memset(out[code_bytes..pool_off], 0);
    for (w.pool[0..w.n_pool], 0..) |p, i| std.mem.writeInt(u32, out[pool_off + 4 * i ..][0..4], p, .little);
    const cfg = Config{
        .gen = w.gen,
        .instrlen = ak.instrlen,
        .count = ak.count,
        .localid_reg = ak.localid_reg,
        .wgid_reg = ak.wgid_reg,
        .full_regs = ak.full_regs,
        .half_regs = ak.half_regs,
        .constlen = ak.constlen,
        .branchstack = ak.branchstack,
        .threadsize = ak.threadsize,
        .params = @intCast(w.params_at),
        .drv = @intCast(w.drv_at),
        .uses_drv = w.uses_drv,
        .pool = @intCast(w.pool_at),
        .pool_words = @intCast(w.n_pool),
        .pool_offset = @intCast(pool_off),
        .code_bytes = @intCast(code_bytes),
        .shared_bytes = ak.shared_bytes,
    };
    w.stats.legalized = ak.count;
    w.stats.full_regs = ak.full_regs;
    w.stats.half_regs = ak.half_regs;
    w.stats.constants = ak.constlen;
    return .{
        .target = w.caps.target,
        .code = out[0..total],
        .regs = @as(u32, ak.full_regs) * 4,
        .shared_bytes = ak.shared_bytes,
        .group = k.group,
        .bindings = k.bindings,
        .param_words = k.param_words,
        .extra = cfg.toExtra(),
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const ir3_emu = adreno.ir3_emu;

pub const test_caps = device.Caps{
    .vendor = .qualcomm,
    .target = .ir3_a7xx,
    .name = "ir3_emu",
    .memory = .unified,
    .coherent = false,
    .device_bytes = 1 << 30,
    .subgroup = 64,
    .max_group = 1024,
    .shared_bytes = 32 * 1024,
    .fused_fma = false,
    .mad = .unfused,
    .denormals = .preserve,
    .dot4 = true,
    .import = false,
    .timestamp_hz = 19_200_000,
};

const T = struct {
    var insts: [8192]kir.Inst = undefined;
    var tys: [8192]kir.Ty = undefined;
    var work: Work = .{};
    var emu: ir3_emu.Work = .{};
    var out: [128 * 1024]u8 align(16) = undefined;
    var consts: [1024]u32 = undefined;
    var listing_buf: [256 * 1024]u8 = undefined;
};

fn testKernel(name: []const u8, group: [3]u32) kir.Kernel {
    return kir.Kernel.init(.{ .insts = &T.insts, .tys = &T.tys }, name, group);
}

/// Compile `k`, run it on ir3_emu over `regions` (buffers at their va).
fn runOnEmu(k: *kir.Kernel, caps: device.Caps, regions: []const ir3_emu.Region, buffers: []const u64, params: []const u32, groups: [3]u32) !ir3_emu.Stats {
    try k.finish();
    const bin = compileWith(k, caps, &T.work, &T.out) catch |e| {
        std.debug.print("compile failed: {s}\n{s}\n", .{ @errorName(e), source(&T.work) });
        return e;
    };
    const cfg = Config.fromExtra(bin.extra).?;
    const code: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, bin.code[0..cfg.code_bytes]));
    const ak = cfg.kernel(&bin, code);
    const cw = cfg.constants(buffers, params, groups, &T.consts);
    var n = cw.len;
    if (cfg.pool_words > 0) {
        for (0..cfg.pool_words) |i| T.consts[cfg.pool + i] = std.mem.readInt(u32, bin.code[cfg.pool_offset + 4 * i ..][0..4], .little);
        n = cfg.pool + cfg.pool_words;
    }
    try ir3_emu.load(&T.emu, &ak);
    var stats = ir3_emu.Stats{};
    const mem = ir3_emu.Memory{ .regions = regions };
    ir3_emu.run(&T.emu, &mem, &.{ .kernel = &ak, .consts = T.consts[0..std.mem.alignForward(usize, n, 4)], .groups = groups }, &stats) catch |e| {
        var buf: [160]u8 = undefined;
        const s = ir3.format(ir3.A7XX, &T.emu.code[T.emu.err_pc], &buf) catch "?";
        std.debug.print("emulate: {s} at {d}: {s}\n{s}\n", .{ @errorName(e), T.emu.err_pc, s, listing(&T.work, &T.listing_buf) });
        return e;
    };
    return stats;
}

fn kr(v: kir.V) kir.Arg {
    return .{ .reg = v };
}
fn ku(x: u32) kir.Arg {
    return .{ .imm = x };
}
const none: kir.Arg = .{ .reg = .none };

fn kop(k: *kir.Kernel, o: kir.Op, ty: kir.Ty, a: kir.Arg, b: kir.Arg, c: kir.Arg, aux: u32) kir.V {
    const d = k.reg(if (o == .icmp or o == .fcmp) .pred else ty);
    k.emit(.{ .op = o, .ty = ty, .dst = d, .a = a, .b = b, .c = c, .aux = aux });
    return d;
}

fn memAux(binding: u8, width_log2: u3, imm: u18) u32 {
    return @bitCast(kir.Mem{ .binding = binding, .space = .global, .width_log2 = width_log2, .signed = false, .imm = imm });
}

test "ids, integer arithmetic and a store, through the emulator" {
    var k = testKernel("ids", .{ 64, 1, 1 });
    const out = k.binding();
    const t = kop(&k, .tid, .u32, none, none, none, 0);
    const g = kop(&k, .gid, .u32, none, none, none, 0);
    const base = kop(&k, .shl, .u32, kr(g), ku(6), none, 0);
    const i = kop(&k, .iadd, .u32, kr(base), kr(t), none, 0);
    const v0 = kop(&k, .imul, .u32, kr(t), ku(3), none, 0);
    const v = kop(&k, .iadd, .u32, kr(v0), kr(g), none, 0);
    const off = kop(&k, .shl, .u32, kr(i), ku(2), none, 0);
    k.emit(.{ .op = .st, .ty = .u32, .dst = .none, .a = kr(off), .b = kr(v), .c = none, .aux = memAux(out, 5, 0) });
    var data = [_]u32{0} ** 256;
    const regions = [_]ir3_emu.Region{.{ .va = 0x1_0000_0000, .bytes = std.mem.sliceAsBytes(&data) }};
    _ = try runOnEmu(&k, test_caps, &regions, &.{0x1_0000_0000}, &.{}, .{ 4, 1, 1 });
    for (data, 0..) |x, n| try std.testing.expectEqual(@as(u32, @intCast((n % 64) * 3 + n / 64)), x);
}
