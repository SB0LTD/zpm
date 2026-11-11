//! @zpm/gpu kir_sm120 — KIR kernels compiled for NVIDIA's sm_120 (Blackwell
//! GeForce: the RTX 50 series, the Legion 5's RTX 5070 Laptop GPU).
//!
//! `compile` takes a finished kir.Kernel and gives a device.Binary: the
//! code words a QMD points at (zpm's src/nvidia/sm120_asm: the control
//! fields worked out by NAK's latency model, sm120_sched), the registers a
//! thread needs and what a launch needs. It is the twin of kir_ir3; the
//! device side is nvidia_device.sig.
//!
//! # How a kernel is compiled
//!
//! 1. **Expansion.** fdiv and fsqrt become kir.expandDiv's and expandSqrt's
//!    KIR (Markstein's corrections: sm_120's FFMA is fused), into the
//!    Work's own copy of the kernel.
//! 2. **Analysis**, over the structured KIR:
//!    - each register's reads and writes;
//!    - which values are warp-uniform: params, group ids, immediates, and
//!      what is computed from them outside divergent control flow. An `if`
//!      on a uniform predicate, or a loop whose every exit is uniform,
//!      needs no convergence barrier;
//!    - folds: and/or/xor/not trees of up to three leaves (one of them an
//!      immediate) become one LOP3; a shift left added to a value becomes
//!      LEA; and of an icmp/fcmp result with a predicate becomes the
//!      compare's own accumulator; fneg and fabs become source modifiers
//!      of the float ops that read them; a half's cvt reads the half where
//!      it is (.H1_H1 for a shift right by 16).
//! 3. **Selection** into machine instructions over virtual registers
//!    (`MI`): one or a few sm_120 instructions a KIR op, the binding bases
//!    loaded once (LDC.64 from the parameter block in constant buffer 0 at
//!    0x380, as CUDA has it), global addresses made once per straight-line
//!    run (IMAD.WIDE.U32 base + offset, the offset's scale folded in), the
//!    memory descriptor in UR4 (LDCU.64 c[0x0][0x358]).
//! 4. **Control flow.** if/else/endif and loop/endloop become branches.
//!    A divergent region gets BSSY.RECONVERGENT/BSYNC.RECONVERGENT on a
//!    convergence barrier of its nesting depth (B0..B15), except one that
//!    a brk or cont leaves (its lanes would never reach the BSYNC). A small
//!    `if` (a few ALU or memory ops, no control flow or collectives) is
//!    predicated instead of branched (@P on each instruction, as ptxas
//!    does); a short then-branch before a long else is predicated and the
//!    else branched around. A loop whose last op is `brk` branches back on
//!    the negated predicate (one branch an iteration).
//! 5. **Register allocation:** linear scan over live intervals in program
//!    order, extended over a whole loop for a value live across its back
//!    edge. Vectors (64- and 128-bit loads and stores) get aligned runs of
//!    2 or 4 registers, addresses aligned pairs. Predicates get P0..P5;
//!    when more are live, the rest live in general registers (0 or 1) and
//!    are moved through scratch predicates (P6 down) where an instruction
//!    reads or writes one: P5 and P6 at first, and as many more (P3..P6
//!    at most) as the instruction reading the most of them needs (a
//!    PLOP3's three and a guard), taken from the allocation.
//! 6. **Dead code** (results nothing reads, after the folds) is dropped,
//!    and the text goes to sm120_asm.
//!
//! # Exactness
//!
//! fadd, fsub, fmul, ffma (FFMA: fused) and fmad (fused too: Caps.mad is
//! .fused on sm_120) are IEEE binary32, round to nearest even; with
//! Caps.denormals == .flush every float op carries .FTZ. fmin/fmax are
//! FMNMX (IEEE minNum/maxNum, -0 below +0). ffloor .. frne are FRND.
//! cvt to an integer is F2I...NTZ (saturating, NaN to 0), from one I2FP or I2F
//! with the rounding; f32 to f16 F2FP (nearest even) or F2F (directed),
//! f16 to f32 HADD2.F32 (exact). The approximate ops are MUFU (sin and cos
//! of the angle times 1/2pi, as ptxas does).
//!
//! # Other SM generations
//!
//! Selection reads `Gen`, what a generation has; the lowering above it is
//! the same for every SM from Volta on (one 128-bit format, the control
//! fields in 105..125, BSSY/BSYNC, SHFL, IDP.4A, the uniform datapath from
//! sm_75). Only sm_120 has an encoder in zpm (src/nvidia/sm120.sig). A
//! generation joins as: its encoder (NAK's sm70_encode.rs documents each
//! field by `e.sm`), its latency tables for sm120_sched, a Gen, and its
//! constant buffer 0 (QMD and cbuf0 in nvidia_device). What differs:
//!
//! (read off ptxas 13.4's output for sm_75, 80, 89, 90 and 120, and NAK)
//!
//! - sm_100/120: two-source IADD and IADD.64 (sm_90: VIADD; before:
//!   IADD3 a, b, RZ), LDCU (else ULDC.64), a branch's offset split over
//!   16..23 and 34..81, the atomics' 64-bit address bit at 63; sm_120 sets
//!   no yield or reuse bits.
//! - sm_90 and later: desc[UR][R.64] addresses, VIMNMX (VIADDMNMX; before:
//!   IMNMX), the CGA shared window with its reserved 1 KiB
//!   (Gen.shared_base 0 before).
//! - sm_89 and later: I2FP (else I2F).
//! - sm_75 to sm_89: ALU ops read c[bank][offset] directly (sm_120 loads
//!   constants with LDC/LDCU), addresses are plain [R.64] (sm_80/89 load
//!   the implicit descriptor, ULDC.64 c[0x0][0x118]), sm_75 has
//!   BAR.SYNC without DEFER_BLOCKING and LDG.E.SYS.
//! - Constant buffer 0: parameters from 0x160 (sm_75..89), 0x210 (sm_90),
//!   0x380 (sm_100/120); the stack top at 0x28 (to sm_90), 0x37c; the
//!   descriptor at 0x118, 0x208, 0x358. QMD v02_02 (Volta, Turing),
//!   v03_00 (Ampere, Ada), v04_00 (Hopper), v05_00 (Blackwell).
//!
//! Allocation-free: the State comes from the caller's device.Work
//! (WORK_BYTES: 13.6 MiB, inside the 16 MiB Galaxy's gfx_render gives: kernels
//! of up to 16384 KIR instructions after the expansions, as WebRender's
//! largest need about 8800), the code goes to the caller's bytes.

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const nvidia = @import("nvidia");
const sm120_asm = nvidia.sm120_asm;

/// KIR instructions after expansion, and virtual registers (KIR's and the
/// backend's own).
pub const MAX_INSTS = 16384;
pub const MAX_VREGS = 16384;
/// Machine instructions and labels before the text.
pub const MAX_MI = 20480;
pub const MAX_LOOPS = 256;
pub const MAX_DEPTH = 32;
pub const TEXT_BYTES = 1536 * 1024;
/// The highest general register handed out: sm120_asm counts the highest
/// plus 3, and a QMD takes up to 255.
pub const MAX_GPR: u8 = 252;
/// Predicates allocated (P6 is the scratch for those in registers).
const PREDS: u8 = 6;
const SCRATCH_P: u8 = 6;
/// Predicates allocated at least when some live in registers: P3..P6 are
/// then scratch, enough for a PLOP3's three and a guard.
const MIN_PREDS: u8 = 3;

pub const Error = kir.Error || sm120_asm.Error || error{
    /// A KIR form this backend does not compile (see the op's lowering).
    Unsupported,
    /// Too many machine instructions, labels, loops or nesting levels.
    TooBig,
    /// The output buffer is too small for the code.
    BufferTooSmall,
};

// ── Generations ─────────────────────────────────────────────────────────────

/// What an SM generation's instruction set has, as selection uses it.
pub const Gen = struct {
    sm: u32,
    /// IADD with two sources (else IADD3 a, b, RZ).
    iadd2: bool,
    /// VIMNMX (else IMNMX).
    vimnmx: bool,
    /// I2FP.F32.S32/U32 (else I2F).
    i2fp: bool,
    /// The memory descriptor through LDCU.64 (else ULDC.64).
    ldcu: bool,
    /// Warp size.
    warp: u32 = 32,
    /// Shared memory reserved before a kernel's own (sm_90 and later: 1 KiB).
    shared_base: u32,
};

pub const SM120 = Gen{ .sm = 120, .iadd2 = true, .vimnmx = true, .i2fp = true, .ldcu = true, .shared_base = 0x400 };

/// The generations the backend could select for. Only sm_120 assembles.
pub fn genOf(t: device.Target) ?Gen {
    return switch (t) {
        .sm_120 => SM120,
        else => null,
    };
}

// ── Machine instructions ────────────────────────────────────────────────────

const NOV: u16 = 0xffff;

const Cls = enum(u8) { none, r, p };

/// A machine operand.
const Opd = union(enum) {
    none,
    /// A general register (a virtual one): its sign bits, its half (.H0_H0
    /// 1, .H1_H1 2).
    reg: struct { v: u16, neg: bool = false, abs: bool = false, half: u2 = 0 },
    rz,
    /// A predicate read or written.
    pred: struct { v: u16, not: bool = false },
    /// PT (true) or !PT.
    pt: bool,
    imm: u32,
    cbuf: u32,
    sreg: []const u8,
    /// [base(.64)+off], desc[UR4][base.64+off]; base NOV is RZ.
    mem: struct { base: u16 = NOV, wide: bool = false, desc: bool = false, off: i32 = 0 },
    label: u16,
    bar: u8,
    ur4,
};

const Kind = enum(u8) { inst, label, dead };

/// What an instruction does besides writing its results (it may not be
/// dropped as dead code).
const Effect = enum(u8) { none, effect };

const MI = struct {
    kind: Kind = .inst,
    op: []const u8 = "",
    guard: Opd = .none,
    /// Leading operands written.
    nd: u8 = 0,
    n: u8 = 0,
    effect: Effect = .none,
    o: [7]Opd = undefined,
};

// ── The work area ───────────────────────────────────────────────────────────

const IfMode = enum(u8) { branch, predicate, partial };

const Region = struct {
    /// Convergence barrier (B0..), or none.
    bssy: ?u8 = null,
    mode: IfMode = .branch,
    l_else: u16 = 0,
    l_end: u16 = 0,
    l_top: u16 = 0,
    l_cont: u16 = 0,
    has_else: bool = false,
    cond: Opd = .none,
    /// Loop: the MI index of its top, and the KIR index of its endloop.
    top_at: u32 = 0,
    loop: bool = false,
    has_cont: bool = false,
    /// The region diverges (counted in Ctx.div_depth while open).
    div: bool = false,
    /// A loop that desyncs (counted in Ctx.nobar while open).
    desync: bool = false,
    rotated: bool = false,
    single_pass: bool = false,
    /// The address-reuse depth outside the region.
    rdepth: u8 = 0,
};

pub const State = struct {
    // the expanded kernel
    insts: [MAX_INSTS]kir.Inst = undefined,
    tys: [MAX_VREGS]kir.Ty = undefined,
    // analysis of KIR registers
    reads: [MAX_VREGS]u16 = undefined,
    writes: [MAX_VREGS]u16 = undefined,
    def_at: [MAX_VREGS]u32 = undefined,
    uniform: [MAX_VREGS]bool = undefined,
    /// A KIR instruction not lowered (none now: an op folded into a later
    /// one is lowered too, and dropped as dead code when nothing else
    /// reads it, so a fold can never leave a value undefined).
    folded: [MAX_INSTS]bool = undefined,
    /// For if and loop: whether the region diverges; whether a brk or cont
    /// leaves it; the matching else/endif/endloop.
    diverge: [MAX_INSTS]bool = undefined,
    exits: [MAX_INSTS]bool = undefined,
    has_cont: [MAX_INSTS]bool = undefined,
    /// A loop whose lanes can fall out of step (a cont, or a brk or cont
    /// inside an if): no convergence barrier inside it (see openLoop).
    desync: [MAX_INSTS]bool = undefined,
    match: [MAX_INSTS]u32 = undefined,
    // machine instructions over virtual registers
    mi: [MAX_MI]MI = undefined,
    n_mi: usize = 0,
    /// KIR instructions after the expansions.
    n_kir: u32 = 0,
    nv: u32 = 0,
    cls: [MAX_VREGS]Cls = undefined,
    /// A register's unit (an aligned run it is allocated in) and place.
    lead: [MAX_VREGS]u16 = undefined,
    off: [MAX_VREGS]u8 = undefined,
    size: [MAX_VREGS]u8 = undefined,
    first: [MAX_VREGS]u32 = undefined,
    last: [MAX_VREGS]u32 = undefined,
    uses: [MAX_VREGS]u16 = undefined,
    phys: [MAX_VREGS]u8 = undefined,
    /// A predicate kept in a general register (its `home`).
    spilled: [MAX_VREGS]bool = undefined,
    /// Predicates allocated (P0 up); the rest to P6 are scratch.
    npreds: u8 = PREDS,
    /// liveness's scratch: a unit's definitions in a loop so far, and
    /// whether the loop carries it (Ctx.carriedIn).
    defs: [MAX_VREGS]u16 = undefined,
    carry: [MAX_VREGS]bool = undefined,
    label_at: [1 << 16]u16 = undefined,
    order: [MAX_VREGS]u16 = undefined,
    loops: [MAX_LOOPS][2]u32 = undefined,
    n_loops: usize = 0,
    text: [TEXT_BYTES]u8 = undefined,
    words: [2 * sm120_asm.MAX_INSTRS]u64 = undefined,
    asm_work: sm120_asm.Work = .{},
    /// What the last compile made (for tests and reports).
    stats: Stats = .{},
};

/// The bytes of a device.Work that `compile` takes (its State, aligned).
pub const WORK_BYTES = @sizeOf(State) + 64;

pub const Stats = struct {
    /// sm120_asm's instruction count (scheduler NOPs included, padding not).
    instructions: u32 = 0,
    registers: u32 = 0,
    /// Predicates that lived in general registers.
    spills: u32 = 0,
    bssy: u32 = 0,
    predicated: u32 = 0,
    /// SHFL/VOTE in divergent code, and those in a loop out of step.
    div_collectives: u32 = 0,
    nobar_collectives: u32 = 0,
};

/// How `compile` compiles.
pub const Options = struct {
    /// fsqrt as ptxas's sqrt.rn (MUFU.RSQ and one FFMA correction on
    /// [2^-101, 2^128), the small, zero and special inputs on their own
    /// paths: Galaxy's frame kernels' square root), else kir.expandSqrt's
    /// (exact for any frsq within its bound, about twice as long).
    native_sqrt: bool = true,
};

/// Binary.extra's words for sm_120.
pub const EXTRA_INSTRUCTIONS = 0;
pub const EXTRA_STACK = 1;
pub const EXTRA_BARRIERS = 2;
pub const EXTRA_PARAM_BYTES = 3;
/// The kernel's size inside the backend, for its limits: KIR instructions
/// after the expansions (MAX_INSTS), and machine instructions and labels
/// before the text (MAX_MI) << 16 | virtual registers / 2 (MAX_VREGS).
pub const EXTRA_KIR = 4;
pub const EXTRA_MI_VREGS = 5;

// ── Compiling ───────────────────────────────────────────────────────────────

/// `k` for sm_120 into `out` (code words, as bytes): device.compile's
/// backend for .sm_120. The Binary's code is a slice of `out`; the State
/// is taken from `work` and given back.
pub fn compile(k: *const kir.Kernel, caps: device.Caps, work: *device.Work, out: []u8) Error!device.Binary {
    const mark = work.mark();
    defer work.release(mark);
    const st = &(work.take(State, 1) orelse return error.TooBig)[0];
    st.asm_work.sched = .{};
    return compileIn(k, caps, st, out, .{});
}

/// The same with a State of the caller's (tests, and callers that keep one).
pub fn compileIn(k: *const kir.Kernel, caps: device.Caps, st: *State, out: []u8, opts: Options) Error!device.Binary {
    const text = try compileText(k, caps, st, opts);
    const ak = try sm120_asm.assemble(text, &st.words, &st.asm_work);
    const bytes = ak.code.len * 8;
    if (out.len < bytes) return error.BufferTooSmall;
    @memcpy(out[0..bytes], std.mem.sliceAsBytes(ak.code));
    st.stats.instructions = ak.count;
    st.stats.registers = ak.registers;
    var bin = device.Binary{
        .target = .sm_120,
        .code = out[0..bytes],
        .regs = ak.registers,
        .shared_bytes = k.shared_bytes,
        .group = k.group,
        .bindings = k.bindings,
        .param_words = k.param_words,
    };
    bin.extra[EXTRA_INSTRUCTIONS] = ak.count;
    bin.extra[EXTRA_STACK] = ak.stack;
    bin.extra[EXTRA_BARRIERS] = 1;
    bin.extra[EXTRA_PARAM_BYTES] = ak.params;
    bin.extra[EXTRA_KIR] = st.n_kir;
    bin.extra[EXTRA_MI_VREGS] = @as(u32, @intCast(st.n_mi)) << 16 | (st.nv >> 1);
    return bin;
}

/// The assembly text `compile` assembles (for reading and tests); it
/// lives in `st`.
pub fn compileText(k: *const kir.Kernel, caps: device.Caps, st: *State, opts: Options) Error![]const u8 {
    const gen = genOf(caps.target) orelse SM120;
    var c = Ctx{ .w = st, .caps = caps, .gen = gen, .k = k, .opts = opts };
    try c.expand();
    try c.analyze();
    try c.lower();
    c.dce();
    try c.liveness();
    try c.allocate();
    return c.emitText();
}

const Ctx = struct {
    w: *State,
    caps: device.Caps,
    gen: Gen,
    /// The kernel as given, then its expansion (in the Work).
    k: *const kir.Kernel,
    opts: Options = .{},
    n: usize = 0,
    nv_kir: u32 = 0,
    labels: u16 = 0,
    guard: Opd = .none,
    /// The binding bases (pairs), loaded in the prologue.
    base: [256]u16 = [_]u16{NOV} ** 256,
    global: bool = false,
    /// Straight-line address reuse: (binding, offset register, scale) to
    /// the address pair.
    addrs: [32]struct { b: u8, a: u16, scale: u32, pair: u16, depth: u8 } = undefined,
    n_addrs: usize = 0,
    /// Convergence barriers open, and branched regions open (an address
    /// made inside one is not reused after it).
    depth: u8 = 0,
    rdepth: u8 = 0,
    /// Divergent regions open (a collective in one drains first).
    div_depth: u8 = 0,
    /// Loops open whose lanes can fall out of step: nothing inside them
    /// gets a convergence barrier.
    nobar: u8 = 0,

    fn insts(c: *const Ctx) []const kir.Inst {
        return c.w.insts[0..c.n];
    }

    fn ftz(c: *const Ctx) bool {
        return c.caps.denormals == .flush;
    }

    // ── 1. Expansion ────────────────────────────────────────────────────

    /// fdiv as kir.expandDiv's KIR; fsqrt too unless `native_sqrt`
    /// (then it is lowered here, as ptxas's sqrt.rn).
    fn expand(c: *Ctx) Error!void {
        const k = c.k;
        if (k.err) |e| return e;
        if (k.n > MAX_INSTS or k.nv > MAX_VREGS) return error.TooBig;
        var x = kir.Kernel.init(.{ .insts = &c.w.insts, .tys = &c.w.tys }, k.name, k.group);
        x.shared_bytes = k.shared_bytes;
        x.bindings = k.bindings;
        x.param_words = k.param_words;
        @memcpy(c.w.tys[0..k.nv], k.tys[0..k.nv]);
        x.nv = k.nv;
        for (k.insts[0..k.n]) |in| {
            switch (in.op) {
                .fdiv => kir.expandDiv(&x, c.caps, in.dst, in.a, in.b),
                .fsqrt => if (c.opts.native_sqrt) x.emit(in) else kir.expandSqrt(&x, c.caps, in.dst, in.a),
                else => x.emit(in),
            }
        }
        if (x.err) |e| return e;
        c.n = x.n;
        c.nv_kir = x.nv;
        c.w.n_kir = @intCast(x.n);
    }

    // ── 2. Analysis ─────────────────────────────────────────────────────

    fn analyze(c: *Ctx) Error!void {
        const w = c.w;
        const nv = c.nv_kir;
        @memset(w.reads[0..nv], 0);
        @memset(w.writes[0..nv], 0);
        @memset(w.def_at[0..nv], std.math.maxInt(u32));
        @memset(w.folded[0..c.n], false);
        @memset(w.diverge[0..c.n], false);
        @memset(w.exits[0..c.n], false);
        // reads, writes, and the structure
        var stack: [MAX_DEPTH * 2]u32 = undefined;
        var else_at: [MAX_DEPTH * 2]?u32 = undefined;
        var sp: usize = 0;
        @memset(w.has_cont[0..c.n], false);
        @memset(w.desync[0..c.n], false);
        for (c.insts(), 0..) |in, idx| {
            for (readsOf(in)) |a| {
                if (a) |v| w.reads[v] += 1;
            }
            if (writesDst(in)) {
                const d = @intFromEnum(in.dst);
                w.writes[d] += 1;
                w.def_at[d] = @intCast(idx);
                if (vecWidth(in)) |n| {
                    for (1..n) |j| {
                        w.writes[d + j] += 1;
                        w.def_at[d + j] = @intCast(idx);
                    }
                }
            }
            switch (in.op) {
                .@"if", .loop => {
                    if (sp == stack.len) return error.TooBig;
                    stack[sp] = @intCast(idx);
                    else_at[sp] = null;
                    sp += 1;
                },
                .@"else" => {
                    if (sp == 0 or w.insts[stack[sp - 1]].op != .@"if" or else_at[sp - 1] != null) return error.Unbalanced;
                    w.match[stack[sp - 1]] = @intCast(idx);
                    else_at[sp - 1] = @intCast(idx);
                },
                .endif, .endloop => {
                    if (sp == 0) return error.Unbalanced;
                    sp -= 1;
                    const open = stack[sp];
                    if (in.op == .endif) {
                        if (w.insts[open].op != .@"if") return error.Unbalanced;
                        // (an if's match is its else, the else's its endif)
                        if (else_at[sp]) |e| w.match[e] = @intCast(idx) else w.match[open] = @intCast(idx);
                    } else {
                        if (w.insts[open].op != .loop) return error.Unbalanced;
                        w.match[open] = @intCast(idx);
                    }
                },
                .brk, .cont => {
                    // every if between here and the loop is left
                    var s = sp;
                    var found = false;
                    var in_if = false;
                    while (s > 0) {
                        s -= 1;
                        if (w.insts[stack[s]].op == .loop) {
                            found = true;
                            if (in.op == .cont) w.has_cont[stack[s]] = true;
                            // (lanes out of step: a cont, or a way out of an if)
                            if (in.op == .cont or in_if) w.desync[stack[s]] = true;
                            break;
                        }
                        w.exits[stack[s]] = true;
                        in_if = true;
                    }
                    if (!found) return error.Unbalanced;
                },
                else => {},
            }
        }
        if (sp != 0) return error.Unbalanced;
        try c.uniformity();
    }

    /// Warp-uniform registers, and the divergent regions, to a fixpoint.
    /// An if diverges when its predicate is not uniform; a loop when one
    /// of its exits is not, or sits in an if of the loop that diverges.
    /// What is written inside a divergent region (some lanes skip it) is
    /// not uniform.
    fn uniformity(c: *Ctx) Error!void {
        const w = c.w;
        @memset(w.uniform[0..c.nv_kir], true);
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < 64) : (rounds += 1) {
            changed = false;
            // per open region: whether code in it may run on part of the
            // warp (values), and whether it diverged since the innermost
            // open loop began (exits); the open loops
            var div: [MAX_DEPTH * 2]bool = undefined;
            var rel: [MAX_DEPTH * 2]bool = undefined;
            var loops: [MAX_DEPTH * 2]u32 = undefined;
            var dsp: usize = 0;
            var lsp: usize = 0;
            var in_div = false;
            var in_rel = false;
            for (c.insts(), 0..) |in, idx| {
                switch (in.op) {
                    .@"if" => {
                        const d = !c.uniformArg(in.a);
                        if (d != w.diverge[idx]) {
                            w.diverge[idx] = d;
                            changed = true;
                        }
                        div[dsp] = in_div;
                        rel[dsp] = in_rel;
                        dsp += 1;
                        in_div = in_div or d;
                        in_rel = in_rel or d;
                        continue;
                    },
                    .@"else" => continue,
                    .endif, .endloop => {
                        dsp -= 1;
                        in_div = div[dsp];
                        in_rel = rel[dsp];
                        if (in.op == .endloop) lsp -= 1;
                        continue;
                    },
                    .loop => {
                        div[dsp] = in_div;
                        rel[dsp] = in_rel;
                        dsp += 1;
                        in_div = in_div or w.diverge[idx];
                        in_rel = false;
                        loops[lsp] = @intCast(idx);
                        lsp += 1;
                        continue;
                    },
                    .brk, .cont => {
                        if (lsp > 0 and (in_rel or !c.uniformArg(in.a))) {
                            const l = loops[lsp - 1];
                            if (!w.diverge[l]) {
                                w.diverge[l] = true;
                                changed = true;
                            }
                        }
                        continue;
                    },
                    else => {},
                }
                if (!writesDst(in)) continue;
                const u = !in_div and c.uniformOp(in);
                const d = @intFromEnum(in.dst);
                const n = vecWidth(in) orelse 1;
                for (0..n) |j| {
                    if (!u and w.uniform[d + j]) {
                        w.uniform[d + j] = false;
                        changed = true;
                    }
                }
            }
        }
    }

    fn uniformArg(c: *const Ctx, a: kir.Arg) bool {
        return switch (a) {
            .imm => true,
            .reg => |v| v == .none or c.w.uniform[@intFromEnum(v)],
        };
    }

    fn uniformOp(c: *const Ctx, in: kir.Inst) bool {
        switch (in.op) {
            .tid, .lane, .atom => return false,
            .gid, .gsize, .subgroup, .param => return true,
            .vote => return true,
            .shfl => return @as(kir.Shfl, @enumFromInt(in.aux)) == .idx and c.uniformArg(in.b),
            else => {},
        }
        for (readsOf(in)) |a| {
            if (a) |v| {
                if (!c.w.uniform[v]) return false;
            }
        }
        return true;
    }

    /// A value `v` defined once, read once, at instruction `def` before
    /// `use` with nothing in between that its sources could be changed by.
    fn foldable(c: *const Ctx, v: u16, use: usize) ?usize {
        const w = c.w;
        if (v >= c.nv_kir) return null;
        if (w.writes[v] != 1 or w.reads[v] != 1) return null;
        const d = w.def_at[v];
        if (d >= use) return null;
        // straight line from d to use, no source redefined
        const din = w.insts[d];
        var j = d + 1;
        while (j < use) : (j += 1) {
            const o = w.insts[j];
            switch (o.op) {
                .@"if", .@"else", .endif, .loop, .endloop, .brk, .cont, .ret, .barrier => return null,
                else => {},
            }
            if (writesDst(o)) {
                for (readsOf(din)) |a| {
                    if (a) |s| {
                        if (s == @intFromEnum(o.dst)) return null;
                    }
                }
            }
        }
        return d;
    }

    // ── LOP3 trees ──────────────────────────────────────────────────────

    const Lop = struct {
        /// Up to three leaves (a register or one immediate), and the truth
        /// table over them (leaf i is 0xf0, 0xcc, 0xaa).
        leaf: [3]kir.Arg = undefined,
        n: u8 = 0,
        lut: u8 = 0,
        folded: [4]u32 = undefined,
        n_folded: u8 = 0,
    };

    const LEAF_LUT = [3]u8{ 0xf0, 0xcc, 0xaa };

    fn leafOf(t: *Lop, a: kir.Arg) ?u8 {
        for (t.leaf[0..t.n], 0..) |x, i| {
            if (argEql(x, a)) return LEAF_LUT[i];
        }
        if (t.n == 3) return null;
        if (a == .imm) {
            for (t.leaf[0..t.n]) |x| {
                if (x == .imm) return null;
            }
        }
        t.leaf[t.n] = a;
        t.n += 1;
        return LEAF_LUT[t.n - 1];
    }

    /// The tree of bitwise ops rooted at instruction `idx`, its
    /// single-use bitwise sources folded in while the leaves fit (else
    /// none folded), in `t`; null for constants only (two immediates).
    fn lopTop(c: *const Ctx, t: *Lop, idx: usize, in: kir.Inst) ?u8 {
        var x = Lop{};
        if (c.lopOf(&x, idx, in, true)) |l| {
            t.* = x;
            return l;
        }
        x = Lop{};
        if (c.lopOf(&x, idx, in, false)) |l| {
            t.* = x;
            return l;
        }
        return null;
    }

    fn lopTree(c: *const Ctx, t: *Lop, idx: usize, top: bool) bool {
        _ = top;
        const l = c.lopTop(t, idx, c.w.insts[idx]) orelse return false;
        t.lut = l;
        return t.n_folded > 0;
    }

    fn lopOf(c: *const Ctx, t: *Lop, idx: usize, in: kir.Inst, fold: bool) ?u8 {
        const a = c.lopArg(t, idx, in.a, fold) orelse return null;
        if (in.op == .not) return ~a;
        const b = c.lopArg(t, idx, in.b, fold) orelse return null;
        return switch (in.op) {
            .@"and" => a & b,
            .@"or" => a | b,
            else => a ^ b,
        };
    }

    /// An operand of a bitwise op: a folded source op's table, or a leaf.
    fn lopArg(c: *const Ctx, t: *Lop, idx: usize, a: kir.Arg, fold: bool) ?u8 {
        if (fold and a == .reg and a.reg != .none) {
            const v = @intFromEnum(a.reg);
            if (c.foldable(v, idx)) |d| {
                const din = c.w.insts[d];
                const is_bit = switch (din.op) {
                    .@"and", .@"or", .xor, .not => true,
                    else => false,
                };
                if (is_bit and t.n_folded < t.folded.len) {
                    const save = t.*;
                    t.folded[t.n_folded] = @intCast(d);
                    t.n_folded += 1;
                    if (c.lopOf(t, d, din, true)) |x| return x;
                    t.* = save;
                }
            }
        }
        return leafOf(t, a);
    }

    // ── 3. Selection ────────────────────────────────────────────────────

    fn newV(c: *Ctx, cls: Cls) Error!u16 {
        const w = c.w;
        if (w.nv >= MAX_VREGS) return error.TooManyRegs;
        const v: u16 = @intCast(w.nv);
        w.nv += 1;
        w.cls[v] = cls;
        w.lead[v] = v;
        w.off[v] = 0;
        w.size[v] = 1;
        return v;
    }

    /// A new aligned run of `n` registers, its first.
    fn newRun(c: *Ctx, n: u8) Error!u16 {
        const v = try c.newV(.r);
        for (1..n) |j| {
            const x = try c.newV(.r);
            c.w.lead[x] = v;
            c.w.off[x] = @intCast(j);
        }
        c.w.size[v] = n;
        return v;
    }

    fn label(c: *Ctx) u16 {
        c.labels += 1;
        return c.labels;
    }

    fn put(c: *Ctx, m: MI) Error!void {
        return c.putG(m, true);
    }

    fn putG(c: *Ctx, m: MI, guarded: bool) Error!void {
        const w = c.w;
        if (w.n_mi >= MAX_MI) return error.TooBig;
        var x = m;
        if (guarded and x.kind == .inst and c.guard != .none and x.guard == .none) x.guard = c.guard;
        w.mi[w.n_mi] = x;
        w.n_mi += 1;
    }

    fn ins(c: *Ctx, name: []const u8, nd: u8, ops: []const Opd) Error!void {
        var m = MI{ .op = name, .nd = nd, .n = @intCast(ops.len) };
        for (ops, 0..) |o, i| m.o[i] = o;
        try c.put(m);
    }

    fn eff(c: *Ctx, name: []const u8, nd: u8, ops: []const Opd) Error!void {
        var m = MI{ .op = name, .nd = nd, .n = @intCast(ops.len), .effect = .effect };
        for (ops, 0..) |o, i| m.o[i] = o;
        try c.put(m);
    }

    fn at(c: *Ctx, l: u16) Error!void {
        var m = MI{ .kind = .label, .n = 1, .effect = .effect };
        m.o[0] = .{ .label = l };
        try c.put(m);
    }

    fn bra(c: *Ctx, g: Opd, l: u16) Error!void {
        var m = MI{ .op = "BRA", .n = 1, .effect = .effect, .guard = g };
        m.o[0] = .{ .label = l };
        const save = c.guard;
        c.guard = .none;
        defer c.guard = save;
        try c.put(m);
    }

    fn R(v: u16) Opd {
        return .{ .reg = .{ .v = v } };
    }

    fn vOf(a: kir.Arg) u16 {
        return @intFromEnum(a.reg);
    }

    fn isReg(a: kir.Arg) bool {
        return a == .reg and a.reg != .none;
    }

    /// An operand as a register or an immediate.
    fn src(c: *Ctx, a: kir.Arg) Opd {
        _ = c;
        return switch (a) {
            .reg => |v| if (v == .none) .rz else R(@intFromEnum(v)),
            .imm => |x| if (x == 0) .rz else .{ .imm = x },
        };
    }

    /// An operand that must be a register: an immediate moved into one.
    fn reg(c: *Ctx, a: kir.Arg) Error!Opd {
        switch (a) {
            .reg => |v| return if (v == .none) .rz else R(@intFromEnum(v)),
            .imm => |x| {
                if (x == 0) return .rz;
                const t = try c.newV(.r);
                try c.ins("MOV", 1, &.{ R(t), .{ .imm = x } });
                return R(t);
            },
        }
    }

    /// A float operand, fneg/fabs folded in as sign bits: FADD, FMNMX,
    /// FSETP and F2I take both, FMUL and FFMA only the negation (a fabs
    /// then stays an instruction of its own).
    fn fsrc(c: *Ctx, a: kir.Arg) Opd {
        return c.fsrcM(a, true);
    }

    fn fsrcNeg(c: *Ctx, a: kir.Arg) Opd {
        return c.fsrcM(a, false);
    }

    fn fsrcM(c: *Ctx, a: kir.Arg, abs_ok: bool) Opd {
        var o = c.src(a);
        if (o == .reg) o = c.fmods(o, abs_ok);
        return o;
    }

    fn fmods(c: *Ctx, o: Opd, abs_ok: bool) Opd {
        var x = o;
        var guard: usize = 0;
        while (x.reg.v < c.nv_kir and guard < 8) : (guard += 1) {
            const d = c.w.def_at[x.reg.v];
            if (d == std.math.maxInt(u32) or c.w.writes[x.reg.v] != 1) break;
            const din = c.w.insts[d];
            if (din.op != .fneg and din.op != .fabs) break;
            if (!isReg(din.a) or c.w.writes[vOf(din.a)] != 1) break;
            // (outermost first: a sign inside an |..| does not matter, an
            // |..| inside a sign keeps it: -|x|)
            if (din.op == .fneg) {
                if (!x.reg.abs) x.reg.neg = !x.reg.neg;
            } else {
                if (!abs_ok) break;
                x.reg.abs = true;
            }
            x.reg.v = vOf(din.a);
        }
        return x;
    }

    fn pred(c: *Ctx, a: kir.Arg) Error!Opd {
        switch (a) {
            .reg => |v| {
                if (v == .none) return .{ .pt = true };
                return c.pnots(.{ .pred = .{ .v = @intFromEnum(v) } });
            },
            .imm => |x| return .{ .pt = x != 0 },
        }
    }

    /// pnot of a predicate read as !P.
    fn pnots(c: *Ctx, o: Opd) Opd {
        var x = o;
        var guard: usize = 0;
        while (x.pred.v < c.nv_kir and guard < 8) : (guard += 1) {
            const d = c.w.def_at[x.pred.v];
            if (d == std.math.maxInt(u32) or c.w.writes[x.pred.v] != 1) break;
            const din = c.w.insts[d];
            if (din.op != .pnot or !isReg(din.a) or c.w.writes[vOf(din.a)] != 1) break;
            x.pred.not = !x.pred.not;
            x.pred.v = vOf(din.a);
        }
        return x;
    }

    fn dst(c: *const Ctx, in: kir.Inst) Opd {
        _ = c;
        return R(@intFromEnum(in.dst));
    }

    fn pdst(in: kir.Inst) Opd {
        return .{ .pred = .{ .v = @intFromEnum(in.dst) } };
    }

    fn lower(c: *Ctx) Error!void {
        const w = c.w;
        w.n_mi = 0;
        w.n_loops = 0;
        w.nv = c.nv_kir;
        w.stats = .{};
        for (0..c.nv_kir) |v| {
            w.cls[v] = if (w.tys[v] == .pred) .p else .r;
            w.lead[v] = @intCast(v);
            w.off[v] = 0;
            w.size[v] = 1;
        }
        try c.groups();
        try c.prologue();
        var regions: [MAX_DEPTH * 2]Region = undefined;
        var sp: usize = 0;
        var idx: usize = 0;
        while (idx < c.n) : (idx += 1) {
            const in = w.insts[idx];
            if (w.folded[idx]) continue;
            switch (in.op) {
                .@"if" => {
                    if (sp == regions.len) return error.TooBig;
                    regions[sp] = try c.openIf(idx, in);
                    sp += 1;
                },
                .@"else" => {
                    const r = &regions[sp - 1];
                    try c.elseIf(r);
                },
                .endif => {
                    sp -= 1;
                    try c.closeIf(&regions[sp]);
                },
                .loop => {
                    if (sp == regions.len) return error.TooBig;
                    regions[sp] = try c.openLoop(idx);
                    sp += 1;
                },
                .endloop => {
                    sp -= 1;
                    try c.closeLoop(&regions[sp]);
                },
                .brk, .cont => {
                    // the innermost loop
                    var s = sp;
                    while (s > 0) {
                        s -= 1;
                        if (regions[s].loop) break;
                    }
                    if (!regions[s].loop) return error.Unbalanced;
                    const r = &regions[s];
                    const p = try c.pred(in.a);
                    // (a brk right before its endloop: the back edge on !p)
                    if (in.op == .brk and idx + 1 < c.n and w.insts[idx + 1].op == .endloop and s + 1 == sp and !r.has_cont) {
                        r.rotated = true;
                        if (p == .pt) {
                            if (p.pt) r.single_pass = true else try c.bra(.none, r.l_top);
                        } else try c.bra(negate(p), r.l_top);
                        continue;
                    }
                    const l = if (in.op == .brk) r.l_end else r.l_cont;
                    if (p == .pt) {
                        if (p.pt) try c.bra(.none, l);
                    } else try c.bra(p, l);
                },
                .ret => try c.eff("EXIT", 0, &.{}),
                else => try c.op(idx, in),
            }
        }
        if (sp != 0) return error.Unbalanced;
        try c.eff("EXIT", 0, &.{});
    }

    fn negate(p: Opd) Opd {
        return switch (p) {
            .pred => |x| .{ .pred = .{ .v = x.v, .not = !x.not } },
            .pt => |b| .{ .pt = !b },
            else => p,
        };
    }

    /// The vectors of 64- and 128-bit memory ops: aligned runs.
    fn groups(c: *Ctx) Error!void {
        const w = c.w;
        for (c.insts()) |in| {
            const n = vecWidth(in) orelse continue;
            const v: u16 = switch (in.op) {
                .ld => @intFromEnum(in.dst),
                .st => if (isReg(in.b)) vOf(in.b) else return error.BadOperand,
                else => continue,
            };
            if (@as(usize, v) + n > c.nv_kir) return error.BadOperand;
            const l = w.lead[v];
            if (l != v or w.size[v] != 1) {
                // already in a run: it must be this one, or one inside it
                const base = l;
                const o = w.off[v];
                if (o % n != 0 or o + n > w.size[base]) return error.Unsupported;
                continue;
            }
            for (1..n) |j| {
                const x = v + @as(u16, @intCast(j));
                if (w.lead[x] != x or w.size[x] != 1) return error.Unsupported;
            }
            w.size[v] = @intCast(n);
            for (1..n) |j| {
                const x = v + @as(u16, @intCast(j));
                w.lead[x] = v;
                w.off[x] = @intCast(j);
            }
        }
    }

    fn prologue(c: *Ctx) Error!void {
        const w = c.w;
        var used = [_]bool{false} ** 256;
        for (c.insts()) |in| {
            switch (in.op) {
                .ld, .st, .atom => {
                    const m: kir.Mem = @bitCast(in.aux);
                    if (m.space == .global) {
                        used[m.binding] = true;
                        c.global = true;
                    }
                },
                else => {},
            }
        }
        if (c.global) try c.ins(if (c.gen.ldcu) "LDCU.64" else "ULDC.64", 1, &.{ .ur4, .{ .cbuf = 0x358 } });
        for (0..256) |b| {
            if (!used[b]) continue;
            if (b >= c.k.bindings) return error.BadBinding;
            const p = try c.newRun(2);
            c.base[b] = p;
            try c.ins("LDC.64", 1, &.{ R(p), .{ .cbuf = 0x380 + 8 * @as(u32, @intCast(b)) } });
        }
        _ = w;
    }

    // ── Control flow ────────────────────────────────────────────────────

    /// Whether the region from `from` to `to` (KIR, exclusive) is small and
    /// simple enough to predicate: ALU and memory ops only, no control
    /// flow, collectives or barriers.
    fn predicable(c: *const Ctx, from: usize, to: usize, limit: usize) bool {
        if (to <= from) return true;
        if (to - from > limit) return false;
        for (c.w.insts[from..to]) |in| {
            switch (in.op) {
                .@"if", .@"else", .endif, .loop, .endloop, .brk, .cont, .ret, .barrier, .shfl, .vote, .fdiv, .fsqrt => return false,
                .sel, .pand, .por, .pnot, .icmp, .fcmp => return false,
                else => {},
            }
            // (a few ops lower to several instructions with predicates of
            // their own)
            if (in.op == .bfe and !(in.b == .imm and in.c == .imm)) return false;
            if (in.op == .atom) return false;
        }
        return true;
    }

    const SMALL = 6;

    /// Addresses made in regions deeper than `d` dropped.
    fn dropAddrs(c: *Ctx, d: u8) void {
        var i: usize = 0;
        while (i < c.n_addrs) {
            if (c.addrs[i].depth > d) {
                c.addrs[i] = c.addrs[c.n_addrs - 1];
                c.n_addrs -= 1;
            } else i += 1;
        }
    }

    fn openIf(c: *Ctx, idx: usize, in: kir.Inst) Error!Region {
        const w = c.w;
        var r = Region{ .rdepth = c.rdepth, .div = w.diverge[idx] };
        if (r.div) c.div_depth += 1;
        const m = w.match[idx];
        r.has_else = w.insts[m].op == .@"else";
        const end = if (r.has_else) w.match[m] else m;
        r.cond = try c.pred(in.a);
        if (c.guard != .none) return error.Unsupported;
        const small_then = c.predicable(idx + 1, m, SMALL);
        const small_else = !r.has_else or c.predicable(m + 1, end, SMALL);
        if (r.cond == .pt) {
            // (a constant condition: the branch not taken is still lowered,
            // under a false guard)
        }
        if (small_then and small_else and r.cond != .pt) {
            r.mode = .predicate;
            c.guard = r.cond;
            c.w.stats.predicated += 1;
            return r;
        }
        r.l_end = c.label();
        r.l_else = if (r.has_else) c.label() else r.l_end;
        if (w.diverge[idx] and !w.exits[idx] and c.nobar == 0) {
            if (c.depth >= MAX_DEPTH) return error.TooBig;
            r.bssy = c.depth;
            c.depth += 1;
            w.stats.bssy += 1;
            try c.eff("BSSY.RECONVERGENT", 0, &.{ .{ .bar = r.bssy.? }, .{ .label = r.l_end } });
        }
        if (r.has_else and small_then and r.cond != .pt) {
            // the then-branch predicated, the else branched around
            r.mode = .partial;
            c.guard = r.cond;
            return r;
        }
        if (r.cond == .pt) {
            if (!r.cond.pt) try c.bra(.none, r.l_else);
        } else try c.bra(negate(r.cond), r.l_else);
        c.rdepth += 1;
        return r;
    }

    fn elseIf(c: *Ctx, r: *Region) Error!void {
        c.dropAddrs(r.rdepth);
        switch (r.mode) {
            .predicate => c.guard = negate(r.cond),
            .partial => {
                c.guard = .none;
                try c.bra(r.cond, r.l_end);
                c.rdepth = r.rdepth + 1;
            },
            .branch => {
                try c.bra(.none, r.l_end);
                try c.at(r.l_else);
            },
        }
    }

    fn closeIf(c: *Ctx, r: *Region) Error!void {
        c.dropAddrs(r.rdepth);
        c.rdepth = r.rdepth;
        if (r.div) c.div_depth -= 1;
        if (r.mode == .predicate) {
            c.guard = .none;
            return;
        }
        c.guard = .none;
        try c.at(r.l_end);
        if (r.bssy) |b| {
            try c.eff("BSYNC.RECONVERGENT", 0, &.{.{ .bar = b }});
            c.depth -= 1;
        }
    }

    fn openLoop(c: *Ctx, idx: usize) Error!Region {
        const w = c.w;
        // (an address from before the loop may be stale on its next
        // iteration, one from inside it after the loop)
        c.n_addrs = 0;
        if (c.guard != .none) return error.Unsupported;
        var r = Region{ .loop = true, .has_cont = w.has_cont[idx], .div = w.diverge[idx], .desync = w.desync[idx] };
        if (r.div) c.div_depth += 1;
        r.l_top = c.label();
        r.l_cont = c.label();
        r.l_end = c.label();
        if (w.diverge[idx] and c.nobar == 0) {
            if (c.depth >= MAX_DEPTH) return error.TooBig;
            r.bssy = c.depth;
            c.depth += 1;
            w.stats.bssy += 1;
            try c.eff("BSSY.RECONVERGENT", 0, &.{ .{ .bar = r.bssy.? }, .{ .label = r.l_end } });
        }
        // (lanes out of step inside this loop may run two regions that
        // share a barrier register at once: one's BSSY would overwrite the
        // other's lanes, and its BSYNC wait for ever. None inside, then;
        // the loop's own, at its exit, every lane reaches)
        if (r.desync) c.nobar += 1;
        try c.at(r.l_top);
        r.top_at = @intCast(w.n_mi - 1);
        return r;
    }

    fn closeLoop(c: *Ctx, r: *Region) Error!void {
        const w = c.w;
        c.n_addrs = 0;
        if (r.div) c.div_depth -= 1;
        if (r.desync) c.nobar -= 1;
        try c.at(r.l_cont);
        if (!r.rotated) try c.bra(.none, r.l_top);
        // Switches and inlined returns use a loop with an unconditional
        // exit. With no back edge their temporaries are not loop-carried.
        if (!r.single_pass) {
            if (w.n_loops == MAX_LOOPS) return error.TooBig;
            w.loops[w.n_loops] = .{ r.top_at, @intCast(w.n_mi - 1) };
            w.n_loops += 1;
        }
        try c.at(r.l_end);
        if (r.bssy) |b| {
            try c.eff("BSYNC.RECONVERGENT", 0, &.{.{ .bar = b }});
            c.depth -= 1;
        }
    }

    // ── Ops ─────────────────────────────────────────────────────────────

    fn opTy(c: *const Ctx, in: kir.Inst) kir.Ty {
        if (in.ty != .pred) return in.ty;
        if (isReg(in.a)) return c.w.tys[vOf(in.a)];
        if (isReg(in.b)) return c.w.tys[vOf(in.b)];
        return .u32;
    }

    fn signed(c: *const Ctx, in: kir.Inst) bool {
        return c.opTy(in) == .i32;
    }

    fn op(c: *Ctx, idx: usize, in: kir.Inst) Error!void {
        const w = c.w;
        // a write ends the straight-line reuse of addresses made from it
        if (writesDst(in)) c.forget(@intFromEnum(in.dst));
        switch (in.op) {
            .mov => {
                if (in.ty == .pred) {
                    const p = try c.pred(in.a);
                    try c.plop(pdst(in), p, .{ .pt = true }, .{ .pt = true }, 0xf0);
                } else try c.ins("MOV", 1, &.{ c.dst(in), c.src(in.a) });
            },
            .sel => {
                const p = try c.pred(in.c);
                if (in.ty == .pred) {
                    try c.plop(pdst(in), try c.pred(in.a), try c.pred(in.b), p, 0xe4);
                } else if (p == .pt) {
                    try c.ins("MOV", 1, &.{ c.dst(in), c.src(if (p.pt) in.a else in.b) });
                } else if (isReg(in.a)) {
                    try c.ins("SEL", 1, &.{ c.dst(in), c.src(in.a), c.src(in.b), p });
                } else if (isReg(in.b)) {
                    try c.ins("SEL", 1, &.{ c.dst(in), c.src(in.b), c.src(in.a), negate(p) });
                } else {
                    try c.ins("SEL", 1, &.{ c.dst(in), try c.reg(in.a), c.src(in.b), p });
                }
            },
            .iadd => try c.iadd(c.dst(in), in.a, in.b, idx),
            .isub => {
                if (in.b == .imm) {
                    try c.iadd(c.dst(in), in.a, .{ .imm = 0 -% in.b.imm }, idx);
                } else if (in.a == .imm) {
                    try c.ins("IADD", 1, &.{ c.dst(in), negR(c.src(in.b)), c.src(in.a) });
                } else try c.ins("IADD", 1, &.{ c.dst(in), c.src(in.a), negR(c.src(in.b)) });
            },
            .ineg => try c.ins("IADD", 1, &.{ c.dst(in), .rz, negR(try c.reg(in.a)) }),
            .imul => {
                var a = in.a;
                var b = in.b;
                if (!isReg(a)) std.mem.swap(kir.Arg, &a, &b);
                if (!isReg(a)) return c.ins("MOV", 1, &.{ c.dst(in), c.src(.{ .imm = in.a.imm *% in.b.imm }) });
                try c.ins(imadName(b, false), 1, &.{ c.dst(in), c.src(a), c.src(b), .rz });
            },
            .imulhi => {
                var a = in.a;
                var b = in.b;
                if (!isReg(a)) std.mem.swap(kir.Arg, &a, &b);
                const ra = try c.reg(a);
                try c.ins(if (c.signed(in)) "IMAD.HI" else "IMAD.HI.U32", 1, &.{ c.dst(in), ra, c.src(b), .rz });
            },
            .imad => {
                var a = in.a;
                var b = in.b;
                if (!isReg(a)) std.mem.swap(kir.Arg, &a, &b);
                const ra = try c.reg(a);
                var cc = c.src(in.c);
                if (b == .imm and in.c == .imm and cc != .rz) cc = try c.reg(in.c);
                try c.ins("IMAD", 1, &.{ c.dst(in), ra, c.src(b), cc });
            },
            .iabs => {
                if (c.signed(in)) try c.ins("IABS", 1, &.{ c.dst(in), try c.reg(in.a) }) else try c.ins("MOV", 1, &.{ c.dst(in), c.src(in.a) });
            },
            .imin, .imax => {
                var a = in.a;
                var b = in.b;
                if (!isReg(a)) std.mem.swap(kir.Arg, &a, &b);
                const ra = try c.reg(a);
                try c.ins(if (c.signed(in)) "VIMNMX.S32" else "VIMNMX.U32", 1, &.{ c.dst(in), ra, c.src(b), .{ .pt = in.op == .imin } });
            },
            .@"and", .@"or", .xor, .not => {
                var t = Lop{};
                if (c.lopTop(&t, idx, in)) |lut| return c.lop3(c.dst(in), &t, lut);
                // (two immediates)
                const x = if (in.a == .imm) in.a.imm else return error.BadOperand;
                const y = if (in.b == .imm) in.b.imm else 0;
                const v: u32 = switch (in.op) {
                    .@"and" => x & y,
                    .@"or" => x | y,
                    .xor => x ^ y,
                    else => ~x,
                };
                try c.ins("MOV", 1, &.{ c.dst(in), c.src(.{ .imm = v }) });
            },
            .shl => {
                // (the amount & 31: SHF.W wraps a register's, an immediate's is masked)
                if (!isReg(in.a) and in.b == .imm) return c.ins("MOV", 1, &.{ c.dst(in), c.src(.{ .imm = in.a.imm << @intCast(in.b.imm & 31) }) });
                try c.ins(if (in.b == .imm) "SHF.L.U32" else "SHF.L.W.U32", 1, &.{ c.dst(in), try c.reg(in.a), c.shamt(in.b), .rz });
            },
            .shr => {
                const name = if (in.b == .imm)
                    (if (c.signed(in)) "SHF.R.S32.HI" else "SHF.R.U32.HI")
                else if (c.signed(in)) "SHF.R.W.S32.HI" else "SHF.R.W.U32.HI";
                try c.ins(name, 1, &.{ c.dst(in), .rz, c.shamt(in.b), try c.reg(in.a) });
            },
            .bfe => try c.bfe(in),
            .dot4 => {
                const kind: kir.Dot4 = @enumFromInt(in.aux);
                const name = switch (kind) {
                    .s8u8 => "IDP.4A.S8.U8",
                    .s8s8 => "IDP.4A.S8.S8",
                    .u8u8 => "IDP.4A.U8.U8",
                };
                // (IDP.4A reads registers only: GB206 takes no immediate)
                try c.ins(name, 1, &.{ c.dst(in), try c.reg(in.a), try c.reg(in.b), try c.reg(in.c) });
            },
            .icmp => try c.cmp(in, .{ .pt = true }, true),
            .fcmp => try c.cmp(in, .{ .pt = true }, true),
            .pand, .por => {
                // a compare's result read once, right here: its accumulator
                const a = try c.pred(in.a);
                const b = try c.pred(in.b);
                if (try c.cmpAcc(idx, in, a, b)) return;
                try c.plop(pdst(in), a, b, .{ .pt = true }, if (in.op == .pand) 0xc0 else 0xfc);
            },
            .pnot => try c.plop(pdst(in), try c.pred(in.a), .{ .pt = true }, .{ .pt = true }, 0x0f),
            .fadd, .fsub, .fmul => {
                const abs_ok = in.op != .fmul;
                var a = c.fsrcM(in.a, abs_ok);
                var b = c.fsrcM(in.b, abs_ok);
                if (in.op == .fsub) b = fnegO(b);
                if (a != .reg) std.mem.swap(Opd, &a, &b);
                if (a != .reg) a = try c.reg(in.a);
                const name = switch (in.op) {
                    .fmul => if (c.ftz()) "FMUL.FTZ" else "FMUL",
                    else => if (c.ftz()) "FADD.FTZ" else "FADD",
                };
                try c.ins(name, 1, &.{ c.dst(in), a, b });
            },
            .ffma, .fmad => {
                var a = c.fsrcNeg(in.a);
                var b = c.fsrcNeg(in.b);
                if (a != .reg) std.mem.swap(Opd, &a, &b);
                if (a != .reg) a = try c.reg(in.a);
                var cc = c.fsrcNeg(in.c);
                if (b != .reg and cc != .reg) cc = try c.reg(in.c);
                try c.ins(if (c.ftz()) "FFMA.FTZ" else "FFMA", 1, &.{ c.dst(in), a, b, cc });
            },
            .fmin, .fmax => {
                var a = c.fsrc(in.a);
                var b = c.fsrc(in.b);
                if (a != .reg) std.mem.swap(Opd, &a, &b);
                if (a != .reg) a = try c.reg(in.a);
                try c.ins(if (c.ftz()) "FMNMX.FTZ" else "FMNMX", 1, &.{ c.dst(in), a, b, .{ .pt = in.op == .fmin } });
            },
            .fabs => try c.ins("LOP3.LUT", 1, &.{ c.dst(in), try c.reg(in.a), .{ .imm = 0x7fffffff }, .rz, .{ .imm = 0xc0 }, .{ .pt = false } }),
            .fneg => try c.ins("LOP3.LUT", 1, &.{ c.dst(in), try c.reg(in.a), .{ .imm = 0x80000000 }, .rz, .{ .imm = 0x3c }, .{ .pt = false } }),
            .ffloor, .fceil, .ftrunc, .frne => {
                const name: []const u8 = switch (in.op) {
                    .ffloor => if (c.ftz()) "FRND.FTZ.FLOOR" else "FRND.FLOOR",
                    .fceil => if (c.ftz()) "FRND.FTZ.CEIL" else "FRND.CEIL",
                    .ftrunc => if (c.ftz()) "FRND.FTZ.TRUNC" else "FRND.TRUNC",
                    else => if (c.ftz()) "FRND.FTZ" else "FRND",
                };
                try c.ins(name, 1, &.{ c.dst(in), c.src(in.a) });
            },
            .frcp, .frsq, .fexp2, .flog2 => {
                const name: []const u8 = switch (in.op) {
                    .frcp => "MUFU.RCP",
                    .frsq => "MUFU.RSQ",
                    .fexp2 => "MUFU.EX2",
                    else => "MUFU.LG2",
                };
                try c.ins(name, 1, &.{ c.dst(in), try c.reg(in.a) });
            },
            .fsin, .fcos => {
                const t = try c.newV(.r);
                try c.ins("FMUL.RZ", 1, &.{ R(t), try c.reg(in.a), .{ .imm = @bitCast(@as(f32, 0.15915493667125701904)) } });
                try c.ins(if (in.op == .fsin) "MUFU.SIN" else "MUFU.COS", 1, &.{ c.dst(in), R(t) });
            },
            .cvt => try c.cvt(idx, in),
            .tid, .gid => {
                const names = if (in.op == .tid) [3][]const u8{ "SR_TID.X", "SR_TID.Y", "SR_TID.Z" } else [3][]const u8{ "SR_CTAID.X", "SR_CTAID.Y", "SR_CTAID.Z" };
                if (in.aux > 2) return error.BadOperand;
                try c.ins("S2R", 1, &.{ c.dst(in), .{ .sreg = names[in.aux] } });
            },
            .gsize => {
                if (in.aux > 2) return error.BadOperand;
                try c.ins("LDC", 1, &.{ c.dst(in), .{ .cbuf = nvidia.qmd.CB_GRID + 4 * in.aux } });
            },
            .lane => try c.ins("S2R", 1, &.{ c.dst(in), .{ .sreg = "SR_LANEID" } }),
            .subgroup => try c.ins("MOV", 1, &.{ c.dst(in), .{ .imm = c.gen.warp } }),
            .param => {
                if (in.aux >= c.k.param_words) return error.BadOperand;
                try c.ins("LDC", 1, &.{ c.dst(in), .{ .cbuf = paramAt(c.k.bindings, in.aux) } });
            },
            .ld => try c.load(in),
            .st => try c.store(in),
            .atom => try c.atom(in),
            .barrier => try c.eff("BAR.SYNC.DEFER_BLOCKING", 0, &.{.{ .imm = 0 }}),
            .shfl => {
                const mode: kir.Shfl = @enumFromInt(in.aux);
                const name = switch (mode) {
                    .idx => "SHFL.IDX",
                    .xor => "SHFL.BFLY",
                    .up => "SHFL.UP",
                    .down => "SHFL.DOWN",
                };
                const clamp: Opd = if (mode == .up) .rz else .{ .imm = 0x1f };
                // (up and down by 32 or more give the lane its own value;
                // SHFL reads the delta's low 5 bits: a register is clamped
                // to 32, which SHFL reads as 0, an immediate decided here)
                if ((mode == .up or mode == .down) and in.b == .imm and in.b.imm >= 32)
                    return c.ins("MOV", 1, &.{ c.dst(in), c.src(in.a) });
                var lane = c.src(in.b);
                if (lane == .rz) lane = .{ .imm = 0 };
                if ((mode == .up or mode == .down) and lane == .reg) {
                    const t = try c.newV(.r);
                    try c.ins("VIMNMX.U32", 1, &.{ R(t), lane, .{ .imm = 32 }, .{ .pt = true } });
                    lane = R(t);
                }
                const value = try c.reg(in.a);
                try c.drainIfDivergent();
                try c.eff(name, 2, &.{ .{ .pt = true }, c.dst(in), value, lane, clamp });
            },
            .vote => {
                const name = if (@as(kir.Vote, @enumFromInt(in.aux)) == .any) "VOTE.ANY" else "VOTE.ALL";
                const p = try c.pred(in.a);
                try c.drainIfDivergent();
                try c.eff(name, 1, &.{ pdst(in), p });
            },
            .fsqrt => try c.sqrtNative(in),
            .fdiv => return error.Unsupported,
            .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => unreachable,
        }
        _ = w;
    }

    /// d = sqrt(x), correctly rounded: ptxas's sqrt.rn. x in [2^-101,
    /// 2^128): MUFU.RSQ and one FFMA correction (Markstein's, with the
    /// fused FFMA); a small x scaled by 2^64 first (exactly) and the root
    /// back by 2^-32; +0 itself; the rest (negative, infinite, NaN) MUFU's
    /// SQRT, a negative denormal (which MUFU flushes to -0) NaN. Under
    /// flushing the input is flushed first. A divergent one between
    /// BSSY/BSYNC.
    fn sqrtNative(c: *Ctx, in: kir.Inst) Error!void {
        const d = c.dst(in);
        var x = try c.reg(in.a);
        if (c.ftz()) {
            const t = try c.newV(.r);
            try c.ins("FADD.FTZ", 1, &.{ R(t), x, .{ .reg = .{ .v = NOV, .neg = true } } });
            x = R(t);
        }
        const done = c.label();
        const slow = c.label();
        const special = c.label();
        var bar: ?u8 = null;
        if (c.guard != .none) return error.Unsupported;
        if (!c.uniformArg(in.a) and c.nobar == 0) {
            if (c.depth >= MAX_DEPTH) return error.TooBig;
            bar = c.depth;
            c.depth += 1;
            c.w.stats.bssy += 1;
            try c.eff("BSSY.RECONVERGENT", 0, &.{ .{ .bar = bar.? }, .{ .label = done } });
        }
        const off = try c.newV(.r);
        const p = try c.newV(.p);
        const P = Opd{ .pred = .{ .v = p } };
        try c.ins("IADD", 1, &.{ R(off), x, .{ .imm = 0xf300_0000 } });
        try c.ins("ISETP.GT.U32.AND", 2, &.{ P, .{ .pt = true }, R(off), .{ .imm = 0x727f_ffff }, .{ .pt = true } });
        try c.bra(P, slow);
        try c.rsqStep(d, x);
        try c.bra(.none, done);
        try c.at(slow);
        const q = try c.newV(.p);
        const Q = Opd{ .pred = .{ .v = q } };
        try c.ins("ISETP.GE.U32.AND", 2, &.{ Q, .{ .pt = true }, x, .{ .imm = 0x0d00_0000 }, .{ .pt = true } });
        try c.bra(Q, special);
        const z = try c.newV(.p);
        const Z = Opd{ .pred = .{ .v = z } };
        try c.ins("ISETP.EQ.U32.AND", 2, &.{ Z, .{ .pt = true }, x, .rz, .{ .pt = true } });
        var m = MI{ .op = "MOV", .nd = 1, .n = 2, .guard = Z };
        m.o[0] = d;
        m.o[1] = .rz;
        try c.put(m);
        try c.bra(Z, done);
        const t = try c.newV(.r);
        try c.ins("FMUL", 1, &.{ R(t), x, .{ .imm = 0x5f80_0000 } }); // 2^64
        try c.rsqStep(d, R(t));
        try c.ins("FMUL", 1, &.{ d, d, .{ .imm = 0x2f80_0000 } }); // 2^-32
        try c.bra(.none, done);
        try c.at(special);
        // (x read before d is written: d may be x)
        if (c.ftz()) {
            try c.ins("MUFU.SQRT", 1, &.{ d, x });
        } else {
            const n = try c.newV(.p);
            const N = Opd{ .pred = .{ .v = n } };
            try c.ins("ISETP.GT.U32.AND", 2, &.{ N, .{ .pt = true }, x, .{ .imm = 0x8000_0000 }, .{ .pt = true } });
            try c.ins("MUFU.SQRT", 1, &.{ d, x });
            var nan = MI{ .op = "MOV", .nd = 1, .n = 2, .guard = N };
            nan.o[0] = d;
            nan.o[1] = .{ .imm = 0x7fff_ffff };
            try c.put(nan);
        }
        try c.at(done);
        if (bar) |b| {
            try c.eff("BSYNC.RECONVERGENT", 0, &.{.{ .bar = b }});
            c.depth -= 1;
        }
    }

    /// d = x * rsq(x), corrected once: s = x*r, h = r/2, d = fma(fma(-s,
    /// s, x), h, s).
    fn rsqStep(c: *Ctx, d: Opd, x: Opd) Error!void {
        const r0 = try c.newV(.r);
        const s0 = try c.newV(.r);
        const h = try c.newV(.r);
        const e = try c.newV(.r);
        try c.ins("MUFU.RSQ", 1, &.{ R(r0), x });
        try c.ins("FMUL", 1, &.{ R(s0), x, R(r0) });
        try c.ins("FMUL", 1, &.{ R(h), R(r0), .{ .imm = 0x3f00_0000 } });
        try c.ins("FFMA", 1, &.{ R(e), .{ .reg = .{ .v = s0, .neg = true } }, R(s0), x });
        try c.ins("FFMA", 1, &.{ d, R(e), R(h), R(s0) });
    }

    /// A SHFL or VOTE not in uniform control flow, made safe on the
    /// hardware as ptxas makes __shfl_sync(__activemask(), ..): the lanes
    /// here are the active mask (VOTE.ANY R, PT, PT), and WARPSYNC on it
    /// has them converged before the collective. A branch to the next
    /// instruction first drains (as sm120_sched drains at every branch):
    /// the collective's lanes may wait while the warp's other path runs
    /// (sm120_emu runs it so), and nothing of theirs may be pending then.
    fn drainIfDivergent(c: *Ctx) Error!void {
        if (c.nobar > 0) c.w.stats.nobar_collectives += 1;
        if (c.div_depth == 0) return;
        c.w.stats.div_collectives += 1;
        const next = c.label();
        try c.bra(.none, next);
        try c.at(next);
        const mask = try c.newV(.r);
        try c.eff("VOTE.ANY", 2, &.{ R(mask), .{ .pt = true }, .{ .pt = true } });
        try c.eff("WARPSYNC", 0, &.{R(mask)});
    }

    fn iadd(c: *Ctx, d: Opd, a0: kir.Arg, b0: kir.Arg, idx: usize) Error!void {
        var a = a0;
        var b = b0;
        if (!isReg(a)) std.mem.swap(kir.Arg, &a, &b);
        if (!isReg(a)) return c.ins("MOV", 1, &.{ d, c.src(.{ .imm = a.imm +% b.imm }) });
        // shl(x, k) + y, the shift read only here: LEA
        for ([_]struct { s: kir.Arg, o: kir.Arg }{ .{ .s = a, .o = b }, .{ .s = b, .o = a } }) |p| {
            if (!isReg(p.s)) continue;
            const dv = c.foldable(vOf(p.s), idx) orelse continue;
            const din = c.w.insts[dv];
            if (din.op != .shl or din.b != .imm or din.b.imm == 0 or din.b.imm > 31 or !isReg(din.a)) continue;
            if (!isReg(p.o) and p.o != .imm) continue;
            try c.ins("LEA", 1, &.{ d, R(vOf(din.a)), try c.reg(p.o), .{ .imm = din.b.imm } });
            return;
        }
        try c.ins("IADD", 1, &.{ d, c.src(a), c.src(b) });
    }

    fn shamt(c: *Ctx, b: kir.Arg) Opd {
        return switch (b) {
            .imm => |x| if (x & 31 == 0) .rz else .{ .imm = x & 31 },
            .reg => c.src(b),
        };
    }

    /// One LOP3 for a tree's leaves: leaf i in slot i (a, b, c), the
    /// immediate moved to b (the only slot that takes one), a constant
    /// tree a MOV.
    fn lop3(c: *Ctx, d: Opd, t: *const Lop, lut0: u8) Error!void {
        var leaf = [3]kir.Arg{ .{ .imm = 0 }, .{ .imm = 0 }, .{ .imm = 0 } };
        for (t.leaf[0..t.n], 0..) |x, i| leaf[i] = x;
        var lut = lut0;
        var all_imm = true;
        for (leaf[0..t.n]) |x| {
            if (x != .imm) all_imm = false;
        }
        if (all_imm) {
            // (evaluate the table over the constants, bit by bit)
            var v: u32 = 0;
            for (0..32) |bit| {
                var k: u8 = 0;
                for (0..3) |i| {
                    if ((leaf[i].imm >> @intCast(bit)) & 1 != 0) k |= @as(u8, 4) >> @intCast(i);
                }
                if ((lut >> @intCast(k)) & 1 != 0) v |= @as(u32, 1) << @intCast(bit);
            }
            return c.ins("MOV", 1, &.{ d, c.src(.{ .imm = v }) });
        }
        // the immediate (at most one, not zero) to slot 1
        for (0..3) |i| {
            if (i != 1 and leaf[i] == .imm and leaf[i].imm != 0) {
                std.mem.swap(kir.Arg, &leaf[i], &leaf[1]);
                lut = permuteLut(lut, @intCast(i), 1);
                break;
            }
        }
        const sa = c.src(leaf[0]);
        const sb = c.src(leaf[1]);
        const sc = c.src(leaf[2]);
        try c.ins("LOP3.LUT", 1, &.{ d, sa, sb, sc, .{ .imm = lut }, .{ .pt = false } });
    }

    fn plop(c: *Ctx, d: Opd, a: Opd, b: Opd, cc: Opd, lut: u8) Error!void {
        try c.ins("PLOP3.LUT", 2, &.{ d, .{ .pt = true }, a, b, cc, .{ .imm = lut }, .{ .imm = 0 } });
    }

    fn bfe(c: *Ctx, in: kir.Inst) Error!void {
        const sgn = c.signed(in);
        const d = c.dst(in);
        if (in.b == .imm and in.c == .imm) {
            const off = in.b.imm & 31;
            const len = in.c.imm;
            if (len == 0) return c.ins("MOV", 1, &.{ d, .rz });
            const a = try c.reg(in.a);
            if (len >= 32 or off + len >= 32) {
                // to the top: a shift
                if (off == 0 and len >= 32) return c.ins("MOV", 1, &.{ d, a });
                return c.ins(if (sgn) "SHF.R.S32.HI" else "SHF.R.U32.HI", 1, &.{ d, .rz, .{ .imm = off }, a });
            }
            // bytes and halves: PRMT
            if (off % 8 == 0 and (len == 8 or (len == 16 and off % 16 == 0))) {
                const k = off / 8;
                const sext8 = [4]u32{ 0x8880, 0x9991, 0xaaa2, 0xbbb3 };
                const sel: u32 = if (len == 8)
                    (if (sgn) sext8[k] else 0x4440 | k)
                else if (sgn)
                    (if (k == 0) @as(u32, 0x9910) else 0xbb32)
                else
                    (if (k == 0) @as(u32, 0x4410) else 0x4432);
                return c.ins("PRMT", 1, &.{ d, a, .{ .imm = sel }, .rz });
            }
            if (!sgn) {
                if (off == 0) return c.ins("LOP3.LUT", 1, &.{ d, a, .{ .imm = (@as(u32, 1) << @intCast(len)) - 1 }, .rz, .{ .imm = 0xc0 }, .{ .pt = false } });
                const t = try c.newV(.r);
                try c.ins("SHF.R.U32.HI", 1, &.{ R(t), .rz, .{ .imm = off }, a });
                return c.ins("LOP3.LUT", 1, &.{ d, R(t), .{ .imm = (@as(u32, 1) << @intCast(len)) - 1 }, .rz, .{ .imm = 0xc0 }, .{ .pt = false } });
            }
            const t = try c.newV(.r);
            try c.ins("SHF.L.U32", 1, &.{ R(t), a, .{ .imm = 32 - off - len }, .rz });
            return c.ins("SHF.R.S32.HI", 1, &.{ d, .rz, .{ .imm = 32 - len }, R(t) });
        }
        // registers: off = b & 31, w = min(c, 32 - off); the field shifted
        // to the top and back (arithmetically for i32), 0 when w is 0
        const a = try c.reg(in.a);
        const off = try c.newV(.r);
        if (in.b == .imm) {
            try c.ins("MOV", 1, &.{ R(off), c.src(.{ .imm = in.b.imm & 31 }) });
        } else try c.ins("LOP3.LUT", 1, &.{ R(off), c.src(in.b), .{ .imm = 31 }, .rz, .{ .imm = 0xc0 }, .{ .pt = false } });
        const x = try c.newV(.r);
        try c.ins("SHF.R.U32.HI", 1, &.{ R(x), .rz, R(off), a });
        const room = try c.newV(.r);
        try c.ins("IADD", 1, &.{ R(room), negR(R(off)), .{ .imm = 32 } });
        const wv = try c.newV(.r);
        try c.ins("VIMNMX.U32", 1, &.{ R(wv), R(room), c.src(in.c), .{ .pt = true } });
        const s = try c.newV(.r);
        try c.ins("IADD", 1, &.{ R(s), negR(R(wv)), .{ .imm = 32 } });
        const y = try c.newV(.r);
        try c.ins("SHF.L.U32", 1, &.{ R(y), R(x), R(s), .rz });
        const z = try c.newV(.r);
        try c.ins(if (sgn) "SHF.R.S32.HI" else "SHF.R.U32.HI", 1, &.{ R(z), .rz, R(s), R(y) });
        const p = try c.newV(.p);
        try c.ins("ISETP.EQ.U32.AND", 2, &.{ .{ .pred = .{ .v = p } }, .{ .pt = true }, R(wv), .rz, .{ .pt = true } });
        try c.ins("SEL", 1, &.{ d, .rz, R(z), .{ .pred = .{ .v = p } } });
    }

    fn cmpName(cc: kir.Cmp, float: bool, sgn: bool, fz: bool, acc_or: bool) []const u8 {
        const T = struct {
            fn n(comptime pre: []const u8, comptime suf: []const u8) [6][]const u8 {
                return .{ pre ++ ".EQ" ++ suf, pre ++ ".NE" ++ suf, pre ++ ".LT" ++ suf, pre ++ ".LE" ++ suf, pre ++ ".GT" ++ suf, pre ++ ".GE" ++ suf };
            }
        };
        const i = @intFromEnum(cc);
        if (float) {
            // (ne is unordered: true for NaN)
            const F = if (acc_or) (if (fz) [6][]const u8{ "FSETP.EQ.FTZ.OR", "FSETP.NEU.FTZ.OR", "FSETP.LT.FTZ.OR", "FSETP.LE.FTZ.OR", "FSETP.GT.FTZ.OR", "FSETP.GE.FTZ.OR" } else [6][]const u8{ "FSETP.EQ.OR", "FSETP.NEU.OR", "FSETP.LT.OR", "FSETP.LE.OR", "FSETP.GT.OR", "FSETP.GE.OR" }) else (if (fz) [6][]const u8{ "FSETP.EQ.FTZ.AND", "FSETP.NEU.FTZ.AND", "FSETP.LT.FTZ.AND", "FSETP.LE.FTZ.AND", "FSETP.GT.FTZ.AND", "FSETP.GE.FTZ.AND" } else [6][]const u8{ "FSETP.EQ.AND", "FSETP.NEU.AND", "FSETP.LT.AND", "FSETP.LE.AND", "FSETP.GT.AND", "FSETP.GE.AND" });
            return F[i];
        }
        const I = if (acc_or) (if (sgn) T.n("ISETP", ".OR") else T.n("ISETP", ".U32.OR")) else (if (sgn) T.n("ISETP", ".AND") else T.n("ISETP", ".U32.AND"));
        return I[i];
    }

    fn mirror(cc: kir.Cmp) kir.Cmp {
        return switch (cc) {
            .lt => .gt,
            .le => .ge,
            .gt => .lt,
            .ge => .le,
            else => cc,
        };
    }

    /// d = a cmp b (and-ed or or-ed with `acc`).
    fn cmpInto(c: *Ctx, in: kir.Inst, d: Opd, acc: Opd, and_: bool) Error!void {
        const float = in.op == .fcmp;
        var how: kir.Cmp = @enumFromInt(in.aux);
        var a = if (float) c.fsrc(in.a) else c.src(in.a);
        var b = if (float) c.fsrc(in.b) else c.src(in.b);
        if (a != .reg and b == .reg) {
            std.mem.swap(Opd, &a, &b);
            how = mirror(how);
        }
        if (a != .reg) a = try c.reg(if (in.a == .imm) in.a else in.b);
        const name = cmpName(how, float, c.signed(in), c.ftz(), !and_);
        try c.ins(name, 2, &.{ d, .{ .pt = true }, a, b, acc });
    }

    fn cmp(c: *Ctx, in: kir.Inst, acc: Opd, and_: bool) Error!void {
        try c.cmpInto(in, pdst(in), acc, and_);
    }

    /// pand/por of a compare's single-use result: the compare with it as
    /// accumulator. True when done.
    fn cmpAcc(c: *Ctx, idx: usize, in: kir.Inst, a: Opd, b: Opd) Error!bool {
        const pairs = [_]struct { x: kir.Arg, other: Opd, xo: Opd }{ .{ .x = in.b, .other = a, .xo = b }, .{ .x = in.a, .other = b, .xo = a } };
        for (pairs) |p| {
            if (!isReg(p.x) or p.xo != .pred or p.xo.pred.not) continue;
            const dv = c.foldable(vOf(p.x), idx) orelse continue;
            const din = c.w.insts[dv];
            if (din.op != .icmp and din.op != .fcmp) continue;
            // (it must be the instruction just lowered: the last one)
            const w = c.w;
            if (w.n_mi == 0) continue;
            const last = &w.mi[w.n_mi - 1];
            if (last.kind != .inst or last.nd != 2 or last.o[0] != .pred or last.o[0].pred.v != vOf(p.x)) continue;
            if (last.o[4] != .pt or !last.o[4].pt) continue;
            if (last.guard != .none or c.guard != .none) continue;
            if (p.other == .pred and p.other.pred.v == vOf(p.x)) continue;
            // the compare again, writing the and/or into this result
            w.n_mi -= 1;
            try c.cmpInto(din, pdst(in), p.other, in.op == .pand);
            return true;
        }
        return false;
    }

    fn cvt(c: *Ctx, idx: usize, in: kir.Inst) Error!void {
        const cv: kir.Cvt = @bitCast(in.aux);
        const d = c.dst(in);
        const from = cv.from;
        const to = cv.to;
        const intTy = struct {
            fn is(t: kir.Ty) bool {
                return t == .u32 or t == .i32;
            }
        };
        if (from == .f32 and intTy.is(to)) {
            const u = to == .u32;
            const fz = c.ftz();
            // (.NTZ: NaN to 0, as ptxas has every cvt to an integer;
            // without it the RTX gives NaN as 0x80000000, signed or not)
            const name: []const u8 = switch (cv.round) {
                .rz => if (u) (if (fz) "F2I.FTZ.U32.TRUNC.NTZ" else "F2I.U32.TRUNC.NTZ") else (if (fz) "F2I.FTZ.TRUNC.NTZ" else "F2I.TRUNC.NTZ"),
                .rd => if (u) (if (fz) "F2I.FTZ.U32.FLOOR.NTZ" else "F2I.U32.FLOOR.NTZ") else (if (fz) "F2I.FTZ.FLOOR.NTZ" else "F2I.FLOOR.NTZ"),
                .ru => if (u) (if (fz) "F2I.FTZ.U32.CEIL.NTZ" else "F2I.U32.CEIL.NTZ") else (if (fz) "F2I.FTZ.CEIL.NTZ" else "F2I.CEIL.NTZ"),
                .rne => if (u) (if (fz) "F2I.FTZ.U32.NTZ" else "F2I.U32.NTZ") else (if (fz) "F2I.FTZ.NTZ" else "F2I.NTZ"),
            };
            return c.ins(name, 1, &.{ d, c.fsrc(in.a) });
        }
        if (intTy.is(from) and to == .f32) {
            const u = from == .u32;
            if (cv.round == .rne and c.gen.i2fp) return c.ins(if (u) "I2FP.F32.U32" else "I2FP.F32.S32", 1, &.{ d, try c.reg(in.a) });
            const name: []const u8 = switch (cv.round) {
                .rz => if (u) "I2F.U32.RZ" else "I2F.RZ",
                .rd => if (u) "I2F.U32.RM" else "I2F.RM",
                .ru => if (u) "I2F.U32.RP" else "I2F.RP",
                .rne => if (u) "I2F.U32" else "I2F",
            };
            return c.ins(name, 1, &.{ d, try c.reg(in.a) });
        }
        if (from == .f32 and to == .f16) {
            if (cv.round == .rne) return c.ins("F2FP.F16.F32.PACK_AB", 1, &.{ d, .rz, try c.reg(in.a) });
            const fz = c.ftz();
            const name: []const u8 = switch (cv.round) {
                .rz => if (fz) "F2F.FTZ.F16.F32.RZ" else "F2F.F16.F32.RZ",
                .rd => if (fz) "F2F.FTZ.F16.F32.RM" else "F2F.F16.F32.RM",
                else => if (fz) "F2F.FTZ.F16.F32.RP" else "F2F.F16.F32.RP",
            };
            return c.ins(name, 1, &.{ d, try c.reg(in.a) });
        }
        if (from == .f16 and to == .f32) {
            // the half where it is: shr(w, 16) read here reads w's high half
            var o = try c.reg(in.a);
            var half: u2 = 1;
            // (through a mov to f16, and a shift right by 16: the high half)
            var at_ix = idx;
            var cur = in.a;
            var hops: usize = 0;
            while (isReg(cur) and hops < 4) : (hops += 1) {
                const dv = c.foldable(vOf(cur), at_ix) orelse break;
                const din = c.w.insts[dv];
                if (din.op == .mov and isReg(din.a) and c.w.tys[vOf(din.a)] != .pred) {
                    o = R(vOf(din.a));
                    cur = din.a;
                    at_ix = dv;
                    continue;
                }
                if (half == 1 and din.op == .shr and din.b == .imm and din.b.imm == 16 and isReg(din.a) and c.opTy(din) == .u32) {
                    o = R(vOf(din.a));
                    half = 2;
                    cur = din.a;
                    at_ix = dv;
                    continue;
                }
                break;
            }
            if (o == .reg) o.reg.half = half;
            // (an f16 is never flushed: its denormals are normal f32s)
            return c.ins("HADD2.F32", 1, &.{ d, .{ .reg = .{ .v = NOV, .neg = true } }, o });
        }
        if (intTy.is(from) and intTy.is(to)) return c.ins("MOV", 1, &.{ d, c.src(in.a) });
        if (from == .f32 and to == .f32) {
            const name: []const u8 = switch (cv.round) {
                .rne => "FRND",
                .rz => "FRND.TRUNC",
                .rd => "FRND.FLOOR",
                .ru => "FRND.CEIL",
            };
            return c.ins(name, 1, &.{ d, c.src(in.a) });
        }
        return error.Unsupported;
    }

    // ── Memory ──────────────────────────────────────────────────────────

    fn forget(c: *Ctx, v: u16) void {
        var i: usize = 0;
        while (i < c.n_addrs) {
            if (c.addrs[i].a == v) {
                c.addrs[i] = c.addrs[c.n_addrs - 1];
                c.n_addrs -= 1;
            } else i += 1;
        }
    }

    /// A global address: desc[UR4][pair.64+off].
    fn gaddr(c: *Ctx, m: kir.Mem, a: kir.Arg) Error!Opd {
        const b = m.binding;
        const base = c.base[b];
        if (base == NOV) return error.BadBinding;
        const imm: i64 = m.imm;
        if (a == .imm) {
            const off = imm + a.imm;
            if (off < (1 << 23)) return .{ .mem = .{ .base = base, .wide = true, .desc = true, .off = @intCast(off) } };
            const t = try c.newV(.r);
            try c.ins("MOV", 1, &.{ R(t), .{ .imm = a.imm } });
            const p = try c.newRun(2);
            try c.ins("IMAD.WIDE.U32", 1, &.{ R(p), R(t), .{ .imm = 1 }, R(base) });
            return .{ .mem = .{ .base = p, .wide = true, .desc = true, .off = @intCast(imm) } };
        }
        var x = vOf(a);
        var scale: u32 = 1;
        // a = x * k or x << k, x and a written once: the scale in the IMAD
        if (x < c.nv_kir and c.w.writes[x] == 1) {
            const d = c.w.def_at[x];
            const din = c.w.insts[d];
            if ((din.op == .imul or din.op == .shl) and isReg(din.a) and din.b == .imm and c.w.writes[vOf(din.a)] == 1) {
                const k = if (din.op == .imul) din.b.imm else if (din.b.imm < 32) @as(u32, 1) << @intCast(din.b.imm) else 0;
                if (k != 0) {
                    x = vOf(din.a);
                    scale = k;
                }
            }
        }
        for (c.addrs[0..c.n_addrs]) |e| {
            if (e.b == b and e.a == x and e.scale == scale) return .{ .mem = .{ .base = e.pair, .wide = true, .desc = true, .off = @intCast(imm) } };
        }
        // (pure arithmetic: made unguarded in a predicated region, so the
        // address serves after it too)
        const p = try c.newRun(2);
        var mw = MI{ .op = "IMAD.WIDE.U32", .nd = 1, .n = 4 };
        mw.o[0] = R(p);
        mw.o[1] = R(x);
        mw.o[2] = .{ .imm = scale };
        mw.o[3] = R(base);
        try c.putG(mw, false);
        if (c.n_addrs < c.addrs.len) {
            c.addrs[c.n_addrs] = .{ .b = b, .a = x, .scale = scale, .pair = p, .depth = c.rdepth };
            c.n_addrs += 1;
        }
        return .{ .mem = .{ .base = p, .wide = true, .desc = true, .off = @intCast(imm) } };
    }

    fn saddr(c: *Ctx, m: kir.Mem, a: kir.Arg) Error!Opd {
        const off: i64 = @as(i64, m.imm) + c.gen.shared_base;
        if (a == .imm) return .{ .mem = .{ .off = @intCast(off + a.imm) } };
        return .{ .mem = .{ .base = vOf(a), .off = @intCast(off) } };
    }

    fn sizeName(comptime pre: []const u8, m: kir.Mem) []const u8 {
        return switch (m.width_log2) {
            3 => if (m.signed) pre ++ ".S8" else pre ++ ".U8",
            4 => if (m.signed) pre ++ ".S16" else pre ++ ".U16",
            6 => pre ++ ".64",
            7 => pre ++ ".128",
            else => pre,
        };
    }

    fn load(c: *Ctx, in: kir.Inst) Error!void {
        const m: kir.Mem = @bitCast(in.aux);
        if (m.width_log2 < 3) return error.BadOperand;
        if (m.space == .global) {
            const ad = try c.gaddr(m, in.a);
            try c.ins(sizeName("LDG.E", m), 1, &.{ c.dst(in), ad });
        } else {
            const ad = try c.saddr(m, in.a);
            try c.ins(sizeName("LDS", m), 1, &.{ c.dst(in), ad });
        }
    }

    fn store(c: *Ctx, in: kir.Inst) Error!void {
        var m: kir.Mem = @bitCast(in.aux);
        m.signed = false;
        if (m.width_log2 < 3) return error.BadOperand;
        const v: Opd = if (m.width_log2 >= 6) R(vOf(in.b)) else try c.reg(in.b);
        if (m.space == .global) {
            const ad = try c.gaddr(m, in.a);
            try c.eff(sizeName("STG.E", m), 0, &.{ ad, v });
        } else {
            const ad = try c.saddr(m, in.a);
            try c.eff(sizeName("STS", m), 0, &.{ ad, v });
        }
    }

    fn atom(c: *Ctx, in: kir.Inst) Error!void {
        const m: kir.Mem = @bitCast(in.aux);
        const kind = atomKind(in);
        const sgn = c.signed(in);
        const v = try c.reg(in.b);
        if (m.space == .global) {
            const ad = try c.gaddr(m, in.a);
            const name: []const u8 = switch (kind) {
                .add => "ATOMG.E.ADD.STRONG.GPU",
                .min => if (sgn) "ATOMG.E.MIN.S32.STRONG.GPU" else "ATOMG.E.MIN.STRONG.GPU",
                .max => if (sgn) "ATOMG.E.MAX.S32.STRONG.GPU" else "ATOMG.E.MAX.STRONG.GPU",
                .xchg => "ATOMG.E.EXCH.STRONG.GPU",
            };
            try c.eff(name, 2, &.{ .{ .pt = true }, c.dst(in), ad, v });
        } else {
            const ad = try c.saddr(m, in.a);
            const name: []const u8 = switch (kind) {
                .add => "ATOMS.ADD",
                .min => if (sgn) "ATOMS.MIN.S32" else "ATOMS.MIN",
                .max => if (sgn) "ATOMS.MAX.S32" else "ATOMS.MAX",
                .xchg => "ATOMS.EXCH",
            };
            try c.eff(name, 1, &.{ c.dst(in), ad, v });
        }
    }

    // ── 6. Dead code ────────────────────────────────────────────────────

    fn dce(c: *Ctx) void {
        const w = c.w;
        const mis = w.mi[0..w.n_mi];
        @memset(w.uses[0..w.nv], 0);
        for (mis) |*m| visitReads(m, w, 1);
        var changed = true;
        while (changed) {
            changed = false;
            for (mis) |*m| {
                if (m.kind != .inst or m.effect == .effect or m.nd == 0) continue;
                var live = false;
                for (m.o[0..m.nd]) |o| {
                    switch (o) {
                        .reg => |r| {
                            if (r.v != NOV and w.uses[w.lead[r.v]] > 0) live = true;
                            // (a run: any member read keeps it)
                            if (r.v != NOV) {
                                const l = w.lead[r.v];
                                for (0..w.size[l]) |j| {
                                    if (w.uses[l + j] > 0) live = true;
                                }
                            }
                        },
                        .pred => |p| if (w.uses[p.v] > 0) {
                            live = true;
                        },
                        .ur4 => live = true,
                        else => {},
                    }
                }
                if (live) continue;
                visitReads(m, w, -1);
                m.kind = .dead;
                changed = true;
            }
        }
    }

    // ── 5. Liveness and allocation ──────────────────────────────────────

    fn liveness(c: *Ctx) Error!void {
        const w = c.w;
        const nv = w.nv;
        @memset(w.first[0..nv], std.math.maxInt(u32));
        @memset(w.last[0..nv], 0);
        for (w.mi[0..w.n_mi], 0..) |*m, i| {
            if (m.kind == .label) w.label_at[m.o[0].label] = @intCast(i);
            if (m.kind != .inst) continue;
            const pos: u32 = @intCast(i);
            const S = struct {
                fn mark(wk: *State, v: u16, p: u32) void {
                    if (v == NOV) return;
                    const l = wk.lead[v];
                    wk.first[l] = @min(wk.first[l], p);
                    wk.last[l] = @max(wk.last[l], p);
                }
            };
            for (m.o[0..m.n]) |o| {
                switch (o) {
                    .reg => |r| S.mark(w, r.v, pos),
                    .pred => |p| S.mark(w, p.v, pos),
                    .mem => |x| S.mark(w, x.base, pos),
                    else => {},
                }
            }
            switch (m.guard) {
                .pred => |p| S.mark(w, p.v, pos),
                else => {},
            }
        }
        // a value live across a loop's edges lives through the whole loop
        var changed = true;
        while (changed) {
            changed = false;
            for (w.loops[0..w.n_loops]) |lp| {
                const s = lp[0];
                const e = lp[1];
                c.carriedIn(s, e);
                // (tests: the one-unit form agrees, where it is cheap)
                const check = @import("builtin").is_test and @as(u64, nv) * (e - s + 1) < 1_000_000;
                for (0..nv) |vi| {
                    if (w.lead[vi] != vi) continue;
                    const f = w.first[vi];
                    const l = w.last[vi];
                    if (f == std.math.maxInt(u32)) continue;
                    // referenced inside, and live before or after it
                    if (l < s or f > e) continue;
                    if (check and w.carry[vi] != c.carried(@intCast(vi), s, e)) @panic("kir_sm120: carriedIn and carried disagree");
                    if (f >= s and l <= e and w.carry[vi] and c.blockTemporary(@intCast(vi), f, l)) continue;
                    if (f < s or l > e or w.carry[vi]) {
                        if (f > s or l < e) {
                            w.first[vi] = @min(f, s);
                            w.last[vi] = @max(l, e);
                            changed = true;
                        }
                    }
                }
            }
        }
    }

    /// A scalar whose first access defines it cannot read an earlier
    /// iteration's value unless a branch enters after that definition.
    fn blockTemporary(c: *const Ctx, v: u16, first: u32, last: u32) bool {
        const w = c.w;
        if (w.size[v] != 1 or w.mi[first].guard != .none or !c.writtenAt(v, first) or c.readAt(v, first)) return false;
        for (w.mi[0..w.n_mi], 0..) |m, pos| {
            if (m.kind != .inst or (pos >= first and pos <= last)) continue;
            for (m.o[0..m.n]) |operand| {
                if (operand != .label) continue;
                const target = w.label_at[operand.label];
                if (target > first and target <= last) return false;
            }
        }
        return true;
    }

    /// `carried` for every unit at once (w.carry), in one pass over the
    /// loop [s, e]: each operand in the order `carried` looks at them, a
    /// count of each unit's definitions so far. (WebRender's tile loops
    /// hold most of their kernel: `carried` a unit at a time took seconds.)
    fn carriedIn(c: *const Ctx, s: u32, e: u32) void {
        const w = c.w;
        const nv = w.nv;
        @memset(w.defs[0..nv], 0);
        @memset(w.carry[0..nv], false);
        var i = s;
        while (i <= e) : (i += 1) {
            const m = &w.mi[i];
            if (m.kind != .inst) continue;
            for (m.o[0..m.n], 0..) |o, k| {
                const v: u16 = switch (o) {
                    .reg => |r| if (r.v != NOV) w.lead[r.v] else NOV,
                    .pred => |p| p.v,
                    .mem => |x| if (x.base != NOV) w.lead[x.base] else NOV,
                    else => NOV,
                };
                if (v == NOV) continue;
                if (k < m.nd and o != .mem) {
                    w.defs[v] +|= 1;
                    if (m.guard != .none) w.carry[v] = true;
                } else if (w.defs[v] == 0) w.carry[v] = true;
            }
            switch (m.guard) {
                .pred => |p| if (p.v != NOV and w.defs[p.v] == 0) {
                    w.carry[p.v] = true;
                },
                else => {},
            }
        }
        for (w.defs[0..nv], w.carry[0..nv]) |d, *cy| {
            if (d > 1) cy.* = true;
        }
    }

    /// A value read in the loop [s, e] before it is written there (in
    /// order), or written more than once: carried around the back edge.
    /// (One unit; carriedIn does them all, the same way: tests compare.)
    fn carried(c: *const Ctx, v: u16, s: u32, e: u32) bool {
        const w = c.w;
        var defs: usize = 0;
        var i = s;
        while (i <= e) : (i += 1) {
            const m = &w.mi[i];
            if (m.kind != .inst) continue;
            for (m.o[0..m.n], 0..) |o, k| {
                const hit = switch (o) {
                    .reg => |r| r.v != NOV and w.lead[r.v] == v,
                    .pred => |p| p.v == v,
                    .mem => |x| x.base != NOV and w.lead[x.base] == v,
                    else => false,
                };
                if (!hit) continue;
                if (k < m.nd and o != .mem) {
                    defs += 1;
                    if (m.guard != .none) return true;
                } else if (defs == 0) return true;
            }
            switch (m.guard) {
                .pred => |p| if (p.v == v and defs == 0) return true,
                else => {},
            }
        }
        return defs > 1;
    }

    fn allocate(c: *Ctx) Error!void {
        const w = c.w;
        const nv = w.nv;
        // units in order of their first position
        var n: usize = 0;
        for (0..nv) |vi| {
            if (w.lead[vi] != vi or w.first[vi] == std.math.maxInt(u32)) continue;
            w.order[n] = @intCast(vi);
            n += 1;
        }
        const units = w.order[0..n];
        std.sort.pdq(u16, units, w, struct {
            fn lt(wk: *State, a: u16, b: u16) bool {
                if (wk.first[a] != wk.first[b]) return wk.first[a] < wk.first[b];
                return a < b;
            }
        }.lt);
        @memset(w.spilled[0..nv], false);
        // predicates
        var preds = PREDS;
        while (true) {
            var spills: u32 = 0;
            var active: [8]u16 = undefined;
            var n_active: usize = 0;
            for (units) |u| {
                if (w.cls[u] != .p) continue;
                w.spilled[u] = false;
                // expire
                var i: usize = 0;
                while (i < n_active) {
                    if (w.last[active[i]] < w.first[u] or (w.last[active[i]] == w.first[u] and c.readAt(active[i], w.first[u]))) {
                        active[i] = active[n_active - 1];
                        n_active -= 1;
                    } else i += 1;
                }
                var free: u8 = (@as(u8, 1) << @intCast(preds)) - 1;
                for (active[0..n_active]) |a| free &= ~(@as(u8, 1) << @intCast(w.phys[a]));
                if (free != 0) {
                    w.phys[u] = @ctz(free);
                    active[n_active] = u;
                    n_active += 1;
                    continue;
                }
                // the one ending last goes to a register
                var far: usize = n_active;
                var far_end = w.last[u];
                for (active[0..n_active], 0..) |a, k| {
                    if (w.last[a] > far_end) {
                        far = k;
                        far_end = w.last[a];
                    }
                }
                spills += 1;
                if (far == n_active) {
                    w.spilled[u] = true;
                } else {
                    const a = active[far];
                    w.spilled[a] = true;
                    w.phys[u] = w.phys[a];
                    active[far] = u;
                }
            }
            if (spills > 0 and preds == PREDS) {
                // (two scratch predicates once any is spilled: an op may read two)
                preds = PREDS - 1;
                continue;
            }
            // An instruction reads its spilled predicates through scratch
            // ones (P6 down), its guard too: one reading more than the
            // scratch left (a PLOP3 of three, a compare's accumulator and
            // a guard) takes another predicate from the allocation.
            if (spills > 0 and c.scratchNeed() > SCRATCH_P + 1 - preds and preds > MIN_PREDS) {
                preds -= 1;
                continue;
            }
            w.stats.spills = spills;
            break;
        }
        w.npreds = preds;
        // general registers: spilled predicates are homed in them
        var active: [MAX_GPR + 1]u16 = undefined;
        var n_active: usize = 0;
        var used = [_]u64{ 0, 0, 0, 0 };
        for (units) |u| {
            if (w.cls[u] == .p and !w.spilled[u]) continue;
            var i: usize = 0;
            while (i < n_active) {
                const a = active[i];
                if (w.last[a] < w.first[u] or (w.last[a] == w.first[u] and c.readAt(a, w.first[u]) and !c.writtenAt(a, w.first[u]))) {
                    const sz = if (w.cls[a] == .p) 1 else w.size[a];
                    for (0..sz) |j| clearBit(&used, w.phys[a] + @as(u8, @intCast(j)));
                    active[i] = active[n_active - 1];
                    n_active -= 1;
                } else i += 1;
            }
            const sz: u8 = if (w.cls[u] == .p) 1 else w.size[u];
            const r = findRun(&used, sz) orelse return error.TooManyRegs;
            w.phys[u] = r;
            for (0..sz) |j| setBit(&used, r + @as(u8, @intCast(j)));
            if (n_active == active.len) return error.TooManyRegs;
            active[n_active] = u;
            n_active += 1;
        }
    }

    /// The most scratch predicates an instruction needs: its distinct
    /// spilled predicates read, its guard's among them.
    fn scratchNeed(c: *const Ctx) u8 {
        const w = c.w;
        var most: u8 = 0;
        for (w.mi[0..w.n_mi]) |*m| {
            if (m.kind != .inst) continue;
            var seen: [8]u16 = undefined;
            var n: u8 = 0;
            const reads = m.o[m.nd..m.n];
            for (reads) |o| {
                if (o != .pred or o.pred.v == NOV or !w.spilled[o.pred.v]) continue;
                if (std.mem.indexOfScalar(u16, seen[0..n], o.pred.v) == null and n < seen.len) {
                    seen[n] = o.pred.v;
                    n += 1;
                }
            }
            if (m.guard == .pred and w.spilled[m.guard.pred.v]) {
                if (std.mem.indexOfScalar(u16, seen[0..n], m.guard.pred.v) == null) n += 1;
            }
            most = @max(most, n);
        }
        return most;
    }

    /// Whether unit `u` is read by the instruction at `pos` (so a value
    /// written there may take its register).
    fn readAt(c: *const Ctx, u: u16, pos: u32) bool {
        const w = c.w;
        const m = &w.mi[pos];
        for (m.o[m.nd..m.n]) |o| {
            switch (o) {
                .reg => |r| if (r.v != NOV and w.lead[r.v] == u) return true,
                .pred => |p| if (p.v == u) return true,
                .mem => |x| if (x.base != NOV and w.lead[x.base] == u) return true,
                else => {},
            }
        }
        switch (m.guard) {
            .pred => |p| if (p.v == u) return true,
            else => {},
        }
        return false;
    }

    fn writtenAt(c: *const Ctx, u: u16, pos: u32) bool {
        const w = c.w;
        const m = &w.mi[pos];
        for (m.o[0..m.nd]) |o| {
            switch (o) {
                .reg => |r| if (r.v != NOV and w.lead[r.v] == u) return true,
                .pred => |p| if (p.v == u) return true,
                else => {},
            }
        }
        return false;
    }

    // ── The text ────────────────────────────────────────────────────────

    const Scratch = struct { v: u16, p: u8 };

    /// The assembly text, written by hand (no formatting library: Galaxy
    /// builds kernels freestanding through this path).
    const Text = struct {
        buf: []u8,
        len: usize = 0,
        full: bool = false,

        fn str(t: *Text, x: []const u8) void {
            if (t.full) return;
            if (t.buf.len - t.len < x.len) {
                t.full = true;
                return;
            }
            @memcpy(t.buf[t.len..][0..x.len], x);
            t.len += x.len;
        }

        fn digits(t: *Text, v: u32, base: u32) void {
            var tmp: [10]u8 = undefined;
            var n: usize = 0;
            var x = v;
            while (true) {
                const dgt: u8 = @intCast(x % base);
                tmp[n] = if (dgt < 10) '0' + dgt else 'a' + dgt - 10;
                n += 1;
                x /= base;
                if (x == 0) break;
            }
            var out: [10]u8 = undefined;
            for (0..n) |i| out[i] = tmp[n - 1 - i];
            t.str(out[0..n]);
        }

        fn dec(t: *Text, v: u32) void {
            t.digits(v, 10);
        }

        /// 0x and the hex digits.
        fn hex(t: *Text, v: u32) void {
            t.str("0x");
            t.digits(v, 16);
        }

        /// A letter and a register number (R5, P0, B1, L12).
        fn reg(t: *Text, prefix: []const u8, v: u32) void {
            t.str(prefix);
            t.dec(v);
        }
    };

    fn physOf(c: *const Ctx, v: u16) u8 {
        const w = c.w;
        const l = w.lead[v];
        return w.phys[l] + w.off[v];
    }

    fn emitText(c: *Ctx) Error![]const u8 {
        const w = c.w;
        var t = Text{ .buf = &w.text };
        t.str(".params ");
        t.dec(8 * @as(u32, c.k.bindings) + 4 * @as(u32, c.k.param_words));
        t.str("\n");
        for (w.mi[0..w.n_mi]) |*m| {
            switch (m.kind) {
                .dead => continue,
                .label => {
                    t.reg("L", m.o[0].label);
                    t.str(":\n");
                    continue;
                },
                .inst => {},
            }
            // predicates in registers: read through P6 (and P5), written
            // through P6
            var scratch: u8 = SCRATCH_P;
            var map: [8]Scratch = undefined;
            var n_map: usize = 0;
            const reads = m.o[m.nd..m.n];
            for (reads) |o| {
                if (o == .pred and o.pred.v != NOV and w.spilled[o.pred.v]) {
                    try c.spillRead(&t, o.pred.v, scratch, &map, &n_map);
                    scratch -= 1;
                }
            }
            if (m.guard == .pred and w.spilled[m.guard.pred.v]) {
                var have = false;
                for (map[0..n_map]) |x| {
                    if (x.v == m.guard.pred.v) have = true;
                }
                if (!have) {
                    if (scratch < w.npreds) return error.TooManyRegs;
                    try c.spillRead(&t, m.guard.pred.v, scratch, &map, &n_map);
                    scratch -= 1;
                }
            }
            if (scratch + 1 < w.npreds) return error.TooManyRegs;
            var spilled_dst: ?u16 = null;
            if (m.guard != .none) {
                t.str("@");
                c.printOpd(&t, m.guard, map[0..n_map], null);
                t.str(" ");
            }
            t.str(m.op);
            for (m.o[0..m.n], 0..) |o, i| {
                t.str(if (i == 0) " " else ", ");
                if (i < m.nd and o == .pred and o.pred.v != NOV and w.spilled[o.pred.v]) {
                    spilled_dst = o.pred.v;
                    t.reg("P", SCRATCH_P);
                    continue;
                }
                c.printOpd(&t, o, map[0..n_map], m);
            }
            t.str("\n");
            if (spilled_dst) |v| {
                // (a guarded write keeps the old value when the guard is off)
                if (m.guard != .none) {
                    t.str("@");
                    c.printOpd(&t, m.guard, map[0..n_map], null);
                    t.str(" ");
                }
                t.reg("SEL R", c.physOf(v));
                t.reg(", RZ, 0x1, !P", SCRATCH_P);
                t.str("\n");
            }
        }
        if (t.full) return error.TooBig;
        return w.text[0..t.len];
    }

    fn spillRead(c: *Ctx, t: *Text, v: u16, p: u8, map: *[8]Scratch, n_map: *usize) Error!void {
        for (map[0..n_map.*]) |x| {
            if (x.v == v) return;
        }
        if (n_map.* == map.len) return error.TooManyRegs;
        t.reg("ISETP.NE.U32.AND P", p);
        t.reg(", PT, R", c.physOf(v));
        t.str(", RZ, PT\n");
        map[n_map.*] = .{ .v = v, .p = p };
        n_map.* += 1;
    }

    fn printOpd(c: *const Ctx, t: *Text, o: Opd, map: []const Scratch, m: ?*const MI) void {
        _ = m;
        switch (o) {
            .none => {},
            .reg => |r| {
                if (r.neg) t.str("-");
                if (r.abs) t.str("|");
                if (r.v == NOV) t.str("RZ") else t.reg("R", c.physOf(r.v));
                if (r.abs) t.str("|");
                switch (r.half) {
                    1 => t.str(".H0_H0"),
                    2 => t.str(".H1_H1"),
                    else => {},
                }
            },
            .rz => t.str("RZ"),
            .pred => |p| {
                if (p.not) t.str("!");
                var n: u8 = c.physOf(p.v);
                if (c.w.spilled[p.v]) {
                    for (map) |x| {
                        if (x.v == p.v) n = x.p;
                    }
                }
                t.reg("P", n);
            },
            .pt => |b| t.str(if (b) "PT" else "!PT"),
            .imm => |x| t.hex(x),
            .cbuf => |x| {
                t.str("c[0x0][");
                t.hex(x);
                t.str("]");
            },
            .sreg => |x| t.str(x),
            .mem => |x| {
                if (x.desc) t.str("desc[UR4]");
                t.str("[");
                if (x.base == NOV) t.str("RZ") else t.reg("R", c.physOf(x.base));
                if (x.wide) t.str(".64");
                if (x.off > 0) {
                    t.str("+");
                    t.hex(@intCast(x.off));
                } else if (x.off < 0) {
                    t.str("+-");
                    t.hex(@intCast(-x.off));
                }
                t.str("]");
            },
            .label => |l| {
                t.reg("`(L", l);
                t.str(")");
            },
            .bar => |b| t.reg("B", b),
            .ur4 => t.str("UR4"),
        }
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────────

fn argEql(a: kir.Arg, b: kir.Arg) bool {
    return switch (a) {
        .reg => |x| b == .reg and b.reg == x,
        .imm => |x| b == .imm and b.imm == x,
    };
}

fn negR(o: Opd) Opd {
    return switch (o) {
        .reg => |r| .{ .reg = .{ .v = r.v, .neg = !r.neg, .abs = r.abs, .half = r.half } },
        .imm => |x| .{ .imm = 0 -% x },
        else => o,
    };
}

fn fnegO(o: Opd) Opd {
    return switch (o) {
        .reg => |r| .{ .reg = .{ .v = r.v, .neg = !r.neg, .abs = r.abs, .half = r.half } },
        .imm => |x| .{ .imm = x ^ 0x8000_0000 },
        .rz => .{ .reg = .{ .v = NOV, .neg = true } },
        else => o,
    };
}

fn imadName(b: kir.Arg, wide: bool) []const u8 {
    _ = b;
    return if (wide) "IMAD.WIDE.U32" else "IMAD";
}

/// A truth table with leaves i and j swapped.
fn permuteLut(lut: u8, i: u8, j: u8) u8 {
    var out: u8 = 0;
    for (0..8) |bit| {
        // bit = (a << 2 | b << 1 | c) of the inputs (a = 0xf0's bit 2)
        var x: [3]u1 = .{ @intCast((bit >> 2) & 1), @intCast((bit >> 1) & 1), @intCast(bit & 1) };
        const tmp = x[i];
        x[i] = x[j];
        x[j] = tmp;
        const src_bit = @as(u8, x[0]) << 2 | @as(u8, x[1]) << 1 | x[2];
        if ((lut >> @intCast(src_bit)) & 1 != 0) out |= @as(u8, 1) << @intCast(bit);
    }
    return out;
}

fn setBit(u: *[4]u64, r: u8) void {
    u[r >> 6] |= @as(u64, 1) << @intCast(r & 63);
}

fn clearBit(u: *[4]u64, r: u8) void {
    u[r >> 6] &= ~(@as(u64, 1) << @intCast(r & 63));
}

fn bitSet(u: *const [4]u64, r: u8) bool {
    return u[r >> 6] & (@as(u64, 1) << @intCast(r & 63)) != 0;
}

/// The lowest free run of `n` registers aligned to `n`.
fn findRun(u: *const [4]u64, n: u8) ?u8 {
    var r: u16 = 0;
    while (r + n - 1 <= MAX_GPR) : (r += n) {
        var ok = true;
        for (0..n) |j| {
            if (bitSet(u, @intCast(r + j))) ok = false;
        }
        if (ok) return @intCast(r);
    }
    return null;
}

fn paramAt(bindings: u8, word: u32) u32 {
    return 0x380 + 8 * @as(u32, bindings) + 4 * word;
}

/// The registers an instruction reads (KIR's).
fn readsOf(in: kir.Inst) [4]?u16 {
    var out = [4]?u16{ null, null, null, null };
    const S = struct {
        fn of(a: kir.Arg) ?u16 {
            return if (a == .reg and a.reg != .none) @intFromEnum(a.reg) else null;
        }
    };
    switch (in.op) {
        .tid, .gid, .gsize, .lane, .subgroup, .param, .barrier, .loop, .endloop, .@"else", .endif, .ret => {},
        .@"if", .brk, .cont => out[0] = S.of(in.a),
        .st => {
            out[0] = S.of(in.a);
            out[1] = S.of(in.b);
        },
        else => {
            out[0] = S.of(in.a);
            out[1] = S.of(in.b);
            out[2] = S.of(in.c);
        },
    }
    return out;
}

fn writesDst(in: kir.Inst) bool {
    return switch (in.op) {
        .st, .barrier, .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => false,
        else => in.dst != .none,
    };
}

/// A 64- or 128-bit load's or store's registers.
fn vecWidth(in: kir.Inst) ?usize {
    if (in.op != .ld and in.op != .st) return null;
    const m: kir.Mem = @bitCast(in.aux);
    return switch (m.width_log2) {
        6 => 2,
        7 => 4,
        else => null,
    };
}

fn atomKind(in: kir.Inst) kir.Atom {
    return switch (in.c) {
        .imm => |x| @enumFromInt(@as(u8, @truncate(x))),
        .reg => .add,
    };
}

/// The reads of a machine instruction counted into `w.uses` (by `d`).
fn visitReads(m: *const MI, w: *State, d: i32) void {
    if (m.kind != .inst) return;
    const S = struct {
        fn add(wk: *State, v: u16, by: i32) void {
            if (v == NOV) return;
            const x: i32 = wk.uses[v];
            wk.uses[v] = @intCast(@max(0, x + by));
        }
    };
    for (m.o[m.nd..m.n]) |o| {
        switch (o) {
            .reg => |r| {
                if (r.v == NOV) continue;
                // (a run read through its first register: all of it)
                const l = w.lead[r.v];
                if (w.size[l] > 1 and r.v == l) {
                    for (0..w.size[l]) |j| S.add(w, l + @as(u16, @intCast(j)), d);
                } else S.add(w, r.v, d);
            },
            .pred => |p| S.add(w, p.v, d),
            .mem => |x| if (x.base != NOV) {
                S.add(w, x.base, d);
                S.add(w, x.base + 1, d);
            },
            else => {},
        }
    }
    // (an address pair or a run written as a whole: its other registers
    // are read by whatever reads the first)
    switch (m.guard) {
        .pred => |p| S.add(w, p.v, d),
        else => {},
    }
}
