//! @zpm/nvidia sm120_emu — a functional emulator of sm_120 compute kernels
//! (and of a vertex and a pixel program: "Graphics stages" below), with the
//! timing hazards the hardware does not check.
//!
//! Kernels for the RTX 5070 run here first, on the CPU: the same
//! instructions the SMs get (decoded from their words with sm120.decode, or
//! parsed from assembly text) execute thread by thread, warp by warp, CTA by
//! CTA, against the same memory a launch has (GPU virtual addresses through
//! the caller's regions, constant buffer 0, a CTA's shared memory, each
//! thread's local memory window). Results are compared with zpm's CPU
//! references.
//!
//! The model:
//!
//! - A launch is a grid of CTAs; a CTA is up to 1024 threads in warps of 32,
//!   in x, then y, then z order. A thread has R0..R254 (RZ reads 0), P0..P6
//!   (PT is true); a warp has UR0..UR254 (URZ) and UP0..UP6.
//! - Each thread has its own pc. A warp runs the lowest pc first, every lane
//!   at it together, so divergent paths of structured code reconverge where
//!   they meet (Volta's model, as ir3_emu's). Warp-collective instructions
//!   (SHFL, VOTE) wait until every lane still running has reached them, or
//!   finished; BAR.SYNC waits for the whole CTA. BSSY Bn records the lanes
//!   running it; a BSYNC Bn holds its lanes until every lane recorded has
//!   reached it or exited (the hardware's reconvergence), and lanes held
//!   there that nothing can release are error.Divergence.
//! - Memory: global through flat 64-bit VAs (desc[URd][Rn.64]: the
//!   descriptor is read, as the hardware reads it, but adds nothing), local
//!   through each thread's 16 MiB window (the QMD's low size from 0, its
//!   high size below 0x1000000: CUDA's stack, R1 from c[0x0][0x37c]),
//!   shared per CTA (the QMD's size, its first 1 KiB reserved), constant
//!   buffers as the QMD names them (reads past one are 0, as on the GPU).
//!   An access outside them, or misaligned, is error.Fault.
//! - Integers are exact. Floats are IEEE f32 (f16 for the packed halves),
//!   denormals kept unless .FTZ, NaNs canonical (0x7fffffff, 0x7fff) as the
//!   GPU makes them; directed roundings (.RZ, .RM, .RP) exact. MUFU is exact
//!   (std.math): the hardware's is approximate, so tests compare float paths
//!   with a tolerance.
//!
//! Timing, from the control fields (sm120.sig): an instruction issues
//! `stall` cycles after the one before it in its warp. A fixed-latency
//! result can be read once NVIDIA's cycles for the pair of latency
//! categories have passed (sm120_sched.usesOf, the tables in
//! sm120_latency.sig). A variable-latency ("decoupled") result can be read
//! only after a wait on the scoreboard its producer released, and the wait
//! no sooner than two cycles after the scoreboard was set. Writes after
//! reads (WAR) and after writes (WAW) are checked the same way. Any read or
//! write before then is error.Hazard, with the instruction, the register and
//! the instruction it conflicts with in `Work.trap` (see `explain`).
//!
//! This is the dynamic check that hand-written and scheduled kernels are
//! right: it follows the scoreboards along the paths actually taken, across
//! loop back edges. Two levels:
//!
//! - The hardware's (the default): NVIDIA's cycles as they are, and memory
//!   operations through the load/store pipe in order (a later one's result
//!   lands after an earlier one has read its registers, and waiting on a
//!   later one's scoreboard means every earlier one has read its own).
//!   ptxas relies on both; its kernels run clean here.
//! - `strict`: what sm120_sched guarantees, NAK's model (one cycle of
//!   padding on every read after a write, through sm120_sched.need, and
//!   every read scoreboard waited on). Kernels sm120_asm scheduled run clean
//!   at both levels.
//!
//! The forms a kernel can use are sm120.sig's, and the ones the LFM3
//! kernels need (LDS/STS, BAR.SYNC, SHFL, VOTE, MUFU, the conversions, the
//! packed halves, IDP.4A, the shifts and selects, the uniform datapath), as
//! nvdisasm prints them. Where sm120_sched has no latency categories for a
//! form yet, NAK's are used here (`fallbackUses`) until it does.
//!
//! Graphics stages. A vertex or a pixel program runs here too, for the
//! emulated 3D engine: `stageBegin` starts its threads and `stageRun` runs
//! them to EXIT in warps of 32, with the same timing checks. A `Stage` holds
//! what the engine gives them and takes back: each thread's attribute words
//! (what ALD loads in a vertex program, what IPA reads in a pixel program,
//! already carried across the triangle by the engine as the header says),
//! the words a vertex program stores with AST, the pixels KILL discarded,
//! the constant buffers, and the engine's own texture sampling (TEX, TLD).
//! A pixel program's colour is what R0..R3 hold at EXIT. With the program's
//! header (sph.sig) in the Stage, a program that does what its header does
//! not declare, or leaves undone what it declares, is error.HeaderMismatch.
//! What a Stage has no data for (PIXLD, IPA away from the pixel's centre,
//! local memory), the forms NAK never emits and the meanings no reference
//! settles are error.Unsupported; a stage's instruction in a compute launch,
//! a compute launch's in a stage, or one stage's in the other, is
//! error.BadInstruction. `explain` says which.
//!
//! Allocation-free: the caller owns the Work (about 9 MB: keep it static).
//! A Stage's attribute words are the caller's too.

const std = @import("std");
const sm120 = @import("sm120.sig");
const sm120_asm = @import("sm120_asm.sig");
const sched = @import("sm120_sched.sig");
const lat = @import("sm120_latency.sig");
const qmd = @import("qmd.sig");
const sph = @import("sph.sig");

const Instr = sm120.Instr;
const Operand = sm120.Operand;
const NONE = sm120.Control.NONE;
const RZ = sm120.RZ;
const PT = sm120.PT;

pub const MAX_INSTRS = sched.MAX_INSTRS;
pub const WARP = 32;
pub const MAX_THREADS = 1024;
pub const MAX_WARPS = MAX_THREADS / WARP;
/// R0..R254 and RZ, UR0..UR254 and URZ.
pub const NREGS = 256;
pub const BARS = sched.BARS;
pub const MAX_SHARED = qmd.MAX_SHARED;
/// Local memory for a CTA's threads (1024 threads of 4 KiB).
pub const LOCAL_POOL = 4 << 20;
/// The SM's register file: a CTA's threads times its registers fit in it.
pub const SM_REGISTERS = 64 * 1024;
pub const DEFAULT_MAX_STEPS: u64 = 1 << 32;

/// A scoreboard's waiter issues at least this long after its setter.
const SB_SET: u32 = 2;
/// When NVIDIA's tables have no entry for a pair: the worst case, as
/// sm120_sched assumes.
const WORST: u8 = 15;
const NO_PC: u32 = std.math.maxInt(u32);
/// Registers' contents when a CTA starts (garbage on the GPU).
const POISON: u32 = 0xdead_beef;

pub const Error = sm120.Error || error{
    /// An instruction that does not decode (or parse), a pc past the code,
    /// or an instruction that does not belong where it ran (a graphics
    /// stage's in a compute launch, a compute launch's in a stage, a vertex
    /// program's in a pixel program or the other way).
    BadInstruction,
    /// A form this emulator does not run.
    Unsupported,
    /// A memory access outside every region, or misaligned.
    Fault,
    /// A read or write before the control fields said it was safe.
    Hazard,
    /// Lanes of a CTA waiting on different barriers.
    Divergence,
    Timeout,
    /// A launch the GPU would not take (its registers, shared or local
    /// memory, its block).
    BadLaunch,
    TooManyInstructions,
    /// A stage's program and its header disagree: the program loads or
    /// stores an attribute word, or discards, and the header does not say
    /// so; or the header says it stores a word, or writes a colour, and a
    /// thread reached EXIT without doing it.
    HeaderMismatch,
};

// ── Memory ──────────────────────────────────────────────────────────────────

/// A region of GPU-visible memory.
pub const Region = struct { va: u64, bytes: []u8 };

pub const Memory = struct {
    /// Apart from each other; more than SORTED_FROM of them sorted by va
    /// (EmuDevice keeps them so: a GL scene makes hundreds of buffers).
    regions: []const Region,

    pub const SORTED_FROM = 16;

    pub fn find(m: *const Memory, va: u64, len: usize) ?[]u8 {
        if (m.regions.len <= SORTED_FROM) {
            for (m.regions) |r| {
                if (va >= r.va and va - r.va <= r.bytes.len and len <= r.bytes.len - (va - r.va)) return r.bytes[@intCast(va - r.va)..][0..len];
            }
            return null;
        }
        // (the last region at or below va)
        var lo: usize = 0;
        var hi: usize = m.regions.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (m.regions[mid].va <= va) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const r = m.regions[lo - 1];
        if (va - r.va <= r.bytes.len and len <= r.bytes.len - (va - r.va)) return r.bytes[@intCast(va - r.va)..][0..len];
        return null;
    }
};

// ── Launches ────────────────────────────────────────────────────────────────

/// What a launch gives its threads (the QMD's fields: qmd.Launch).
pub const Launch = struct {
    grid: [3]u32 = .{ 1, 1, 1 },
    block: [3]u32 = .{ 1, 1, 1 },
    /// Registers a thread (the QMD's count); a kernel touching one past
    /// them is a bad launch.
    registers: u32 = 255,
    /// A CTA's shared memory, the reserved 1 KiB included.
    shared_bytes: u32 = qmd.RESERVED_SHARED,
    /// A thread's local memory: from 0 (low) and below 0x1000000 (high).
    local_low: u32 = 0,
    local_high: u32 = 0,
    /// The constant buffers' bytes (0: constant buffer 0).
    cbufs: [qmd.CBUFS][]const u8 = .{&.{}} ** qmd.CBUFS,
    /// Only every cta_stride-th CTA (in x, y, z order) from cta_first runs:
    /// sampled runs of big grids.
    cta_first: u64 = 0,
    cta_stride: u64 = 1,
    /// The global timer (ns) when the launch starts.
    timer_ns: u64 = 0,
};

pub const Stats = struct {
    ctas: u64 = 0,
    warps: u64 = 0,
    /// Warp instructions issued, and threads' (active lanes).
    instructions: u64 = 0,
    thread_instructions: u64 = 0,
    /// The longest warp's cycles, in order (the stalls).
    cycles: u64 = 0,
    global_read: u64 = 0,
    global_written: u64 = 0,
    /// Register reads and writes checked against the control fields.
    hazard_checks: u64 = 0,
};

// ── Graphics stages ─────────────────────────────────────────────────────────

/// The attribute words a stage's instructions address (ALD, AST, IPA):
/// byte addresses 0x000..0x2fc, a word each. The position is words
/// 0x70 / 4 on, generic vector n's component c word (0x80 + 16n + 4c) / 4,
/// the instance's index word 0x2f8 / 4, the vertex's 0x2fc / 4 (sph.sig).
pub const ATTR_WORDS = 0x300 / 4;

/// What the 3D engine gives a vertex or a pixel program's threads, and
/// takes back from them. One entry of each slice a thread, thread 0 first.
pub const Stage = struct {
    /// A vertex program (ALD, AST) or a pixel program (IPA, KILL).
    kind: sph.Stage,
    /// The program's header (sph.sig). With it, a program that does what
    /// its header does not declare, or leaves undone what it declares, is
    /// error.HeaderMismatch (`Why` lists the cases), and a header of the
    /// other kind is a bad launch. Null: none of that is checked.
    header: ?*const [sph.WORDS]u32 = null,
    /// A thread's attribute words. A vertex program's: what ALD loads (the
    /// engine writes the vertex's index at word 0x2fc / 4, the instance's
    /// at 0x2f8 / 4, a vertex buffer's words where the streams put them).
    /// A pixel program's: what IPA reads at that pixel's centre, already
    /// carried across the triangle by the engine as the header says (flat,
    /// linear on the screen, or, for perspective, the word over w, with
    /// 1/w at 0x7c / 4: the program does the multiply itself).
    in: []const [ATTR_WORDS]u32 = &.{},
    /// A vertex program's stored words (AST), and which of them a thread
    /// stored: bit i % 32 of stored[thread][i / 32] for word i. stageRun
    /// clears the bits first; a word no thread stored is left as it was.
    out: [][ATTR_WORDS]u32 = &.{},
    stored: [][ATTR_WORDS / 32]u32 = &.{},
    /// A pixel program's facing, a thread each (IPA.CONSTANT a[0x3fc]: all
    /// ones for a front face, 0 for a back one). Empty: the word traps.
    front: []const bool = &.{},
    /// A pixel program's threads that executed KILL: their colour is not
    /// to be written. stageRun clears them first. (The thread itself runs
    /// on to its EXIT, as the hardware's does: see `stageLane`.)
    killed: []bool = &.{},
    /// The constant buffers' bytes, as a launch's: LDC c[0x1][0x10] reads
    /// cbufs[1] at 0x10. A stage's instruction naming one past them traps.
    cbufs: [qmd.CBUFS][]const u8 = .{&.{}} ** qmd.CBUFS,
    /// Passed to the callbacks.
    ctx: ?*anyopaque = null,
    /// TEX: the texture and sampler `handle` names (the bindless word:
    /// the texture header's index in bits 19..0, the sampler's in 31..20)
    /// sampled at (x, y): red, green, blue, alpha. Null: TEX traps.
    sample: ?*const fn (ctx: ?*anyopaque, handle: u32, x: f32, y: f32) Error![4]f32 = null,
    /// TLD: texel (x, y) of level `lod` of the texture `handle` names.
    /// Null: TLD traps.
    fetch: ?*const fn (ctx: ?*anyopaque, handle: u32, x: i32, y: i32, lod: i32) Error![4]f32 = null,
};

// ── What went wrong ─────────────────────────────────────────────────────────

pub const What = enum {
    none,
    hazard,
    fault,
    unsupported,
    bad_instruction,
    divergence,
    timeout,
    bad_launch,
    /// A stage's program and its header disagree (error.HeaderMismatch).
    header,
};

pub const HazardKind = enum {
    /// A read before the result it reads is ready.
    raw,
    /// A write before an earlier read of the register is done.
    war,
    /// A write before an earlier write to the register is done.
    waw,
    /// A wait on a scoreboard sooner than two cycles after it was set.
    wait_too_soon,
    /// A stage's EXIT with a scoreboard still out: set, and never waited
    /// on (`reg` is the scoreboard, `other_pc` the instruction that set it).
    exit_pending,
};

/// Why a graphics stage's instruction, or its run, was refused: what
/// `explain` says after `what`.
pub const Why = enum {
    none,
    /// A graphics stage's instruction (ALD, AST, IPA, PIXLD, KILL, TEX,
    /// TLD) in a compute launch.
    stage_only,
    /// A compute launch's own in a stage: a barrier, shared memory, the
    /// CTA's or the grid's special registers.
    compute_only,
    /// A vertex program's instruction (ALD, AST) in a pixel program, or a
    /// pixel program's (IPA, PIXLD, KILL) in a vertex program.
    wrong_stage,
    /// A form of the instruction this emulator does not run (each
    /// instruction's comment lists them), or a constant buffer past the
    /// Stage's.
    form,
    /// A Stage carries nothing the instruction could return: a pixel's
    /// samples (PIXLD), a word at the centroid or at an offset (IPA), local
    /// memory.
    no_data,
    /// TEX without the Stage's `sample`, TLD without its `fetch`.
    no_callback,
    /// An attribute address that is not a word's, runs past the words a
    /// Stage carries (0x2fc), or starts a vector where NAK never starts one.
    address,
    /// The Stage's header is not a version 4 header of the Stage's kind, or
    /// is a pixel program's that does not read the position's w.
    header_kind,
    /// stageRun without its stageBegin, for other threads than it began,
    /// or with the Stage's slices shorter than the threads.
    threads,
    /// An attribute word loaded (ALD, IPA) that the header does not say
    /// the program reads.
    load_undeclared,
    /// An attribute word stored (AST) that the header does not say the
    /// program stores, or outside the range of stored words it gives.
    store_undeclared,
    /// A word read flat (IPA.CONSTANT) that the header carries across the
    /// triangle, or carried (IPA.PASS) that the header keeps flat.
    interpolation,
    /// A load after a store, in a program whose header says it has none.
    load_after_store,
    /// KILL in a program whose header does not say it discards pixels.
    kill_undeclared,
    /// A thread at EXIT without a word the header says the program stores.
    store_missing,
    /// A pixel's thread at EXIT with a register the header says holds a
    /// colour (or the sample mask, or the depth) never written.
    colour_missing,
};

pub const Trap = struct {
    what: What = .none,
    /// The instruction's byte address in its kernel.
    pc: u64 = 0,
    hazard: HazardKind = .raw,
    file: sched.File = .gpr,
    reg: u8 = 0,
    /// The instruction it conflicts with.
    other_pc: u64 = 0,
    /// Cycles needed and had; or, with `scoreboard`, a scoreboard not waited
    /// on (or never released).
    need: u32 = 0,
    have: u32 = 0,
    scoreboard: bool = false,
    /// A fault's address.
    va: u64 = 0,
    cta: [3]u32 = .{ 0, 0, 0 },
    thread: u32 = 0,
    /// A stage's refusal: the reason, and the attribute word's byte address
    /// when it is about one.
    why: Why = .none,
    attr: u16 = 0,
};

/// What `w.trap` says, in a sentence, into `buf`.
pub fn explain(w: *const Work, buf: []u8) []const u8 {
    const s = explainWhat(w, buf);
    if (w.trap.why == .none) return s;
    const tail = explainWhy(w.trap, buf[s.len..]);
    return buf[0 .. s.len + tail.len];
}

/// A stage's reason, after what `explainWhat` wrote: ": " and a sentence.
fn explainWhy(t: Trap, buf: []u8) []const u8 {
    const s = switch (t.why) {
        .none => buf[0..0],
        .stage_only => std.fmt.bufPrint(buf, ": a graphics stage's instruction in a compute launch", .{}),
        .compute_only => std.fmt.bufPrint(buf, ": a compute launch's instruction (a barrier, shared memory, the CTA's or the grid's special registers) in a graphics stage", .{}),
        .wrong_stage => std.fmt.bufPrint(buf, ": the other stage's instruction (ALD and AST are a vertex program's; IPA, PIXLD and KILL a pixel program's)", .{}),
        .form => std.fmt.bufPrint(buf, ": a form of the instruction the emulator does not run", .{}),
        .no_data => std.fmt.bufPrint(buf, ": a Stage carries nothing this could return (a pixel's samples, a word away from the pixel's centre, local memory)", .{}),
        .no_callback => std.fmt.bufPrint(buf, ": the Stage has no callback for this texture instruction", .{}),
        .address => std.fmt.bufPrint(buf, ": attribute address 0x{x} is not a word's, runs past 0x2fc, or starts a vector where NAK never starts one", .{t.attr}),
        .header_kind => std.fmt.bufPrint(buf, ": the Stage's header is not a version 4 header of its kind (a pixel program's must read the position's w)", .{}),
        .threads => std.fmt.bufPrint(buf, ": stageRun without its stageBegin, or the Stage's slices are shorter than its threads", .{}),
        .load_undeclared => std.fmt.bufPrint(buf, ": thread {d} loads attribute word 0x{x}, which the header does not declare", .{ t.thread, t.attr }),
        .store_undeclared => std.fmt.bufPrint(buf, ": thread {d} stores attribute word 0x{x}, which the header does not declare", .{ t.thread, t.attr }),
        .interpolation => std.fmt.bufPrint(buf, ": thread {d} reads attribute word 0x{x} flat where the header carries it across the triangle, or the other way", .{ t.thread, t.attr }),
        .load_after_store => std.fmt.bufPrint(buf, ": thread {d} loads attribute word 0x{x} after a store, and the header says the program has no such load", .{ t.thread, t.attr }),
        .kill_undeclared => std.fmt.bufPrint(buf, ": a discard, and the header does not say the program discards pixels", .{}),
        .store_missing => std.fmt.bufPrint(buf, ": thread {d} ended without storing attribute word 0x{x}, which the header declares", .{ t.thread, t.attr }),
        .colour_missing => std.fmt.bufPrint(buf, ": thread {d} ended with R{d} never written, and the header says it holds the pixel's output", .{ t.thread, t.reg }),
    };
    return s catch buf[0..0];
}

/// What went wrong and where: for a hazard, the register and the two
/// instructions; for a fault, the address and the thread.
fn explainWhat(w: *const Work, buf: []u8) []const u8 {
    const t = w.trap;
    const name = if (t.pc / 16 < w.n_ops) w.ops[@intCast(t.pc / 16)].name() else "?";
    const other = if (t.other_pc / 16 < w.n_ops) w.ops[@intCast(t.other_pc / 16)].name() else "?";
    const file = switch (t.file) {
        .gpr => "R",
        .ugpr => "UR",
        .pred => "P",
        .upred => "UP",
    };
    const s = switch (t.what) {
        .hazard => switch (t.hazard) {
            .wait_too_soon => std.fmt.bufPrint(buf, "hazard at 0x{x:0>4} ({s}): waits on a scoreboard {d} cycle(s) after 0x{x:0>4} ({s}) set it; needs {d}", .{ t.pc, name, t.have, t.other_pc, other, t.need }),
            .exit_pending => std.fmt.bufPrint(buf, "hazard at 0x{x:0>4} ({s}): the program ends with scoreboard {d} still out: 0x{x:0>4} ({s}) set it and nothing waited on it", .{ t.pc, name, t.reg, t.other_pc, other }),
            else => if (t.scoreboard)
                std.fmt.bufPrint(buf, "hazard at 0x{x:0>4} ({s}): {s} of {s}{d} before the scoreboard of 0x{x:0>4} ({s}) was waited on", .{ t.pc, name, @tagName(t.hazard), file, t.reg, t.other_pc, other })
            else
                std.fmt.bufPrint(buf, "hazard at 0x{x:0>4} ({s}): {s} of {s}{d} {d} cycle(s) after 0x{x:0>4} ({s}); needs {d}", .{ t.pc, name, @tagName(t.hazard), file, t.reg, t.have, t.other_pc, other, t.need }),
        },
        .fault => std.fmt.bufPrint(buf, "fault at 0x{x:0>4} ({s}): address 0x{x} (CTA {d},{d},{d} thread {d})", .{ t.pc, name, t.va, t.cta[0], t.cta[1], t.cta[2], t.thread }),
        else => std.fmt.bufPrint(buf, "{s} at 0x{x:0>4} ({s})", .{ @tagName(t.what), t.pc, name }),
    };
    return s catch buf[0..0];
}

// ── Instructions, compiled ──────────────────────────────────────────────────

const Kind = enum(u8) {
    invalid,
    unsupported,
    nop,
    exit,
    bra,
    bar,
    /// Memory-ordering and other hints the model has no use for
    /// (WARPSYNC, MEMBAR, ...).
    hint,
    /// BSSY Bn: the lanes running it are barrier n's; BSYNC Bn: a lane
    /// waits there until every lane of barrier n has reached it or exited
    /// (the hardware's reconvergence: no lane runs past a BSYNC early).
    bssy,
    bsync,
    s2r,
    cs2r,
    r2ur,
    ldc,
    mov,
    mov64,
    sel,
    fsel,
    iadd,
    iadd64,
    iadd3,
    imad,
    imad_hi,
    imad_wide,
    lea,
    lea_hi,
    shf,
    lop3,
    plop3,
    prmt,
    iabs,
    imnmx,
    popc,
    flo,
    brev,
    idp,
    isetp,
    ffma,
    fadd,
    fmul,
    fmnmx,
    fsetp,
    mufu,
    hadd2,
    hmul2,
    hfma2,
    i2f,
    f2i,
    f2f,
    f2fp,
    frnd,
    ldg,
    stg,
    ldl,
    stl,
    lds,
    sts,
    /// ATOMG, ATOMS: a read, an operation and a write, a thread at a time.
    atomg,
    atoms,
    shfl,
    vote,
    /// The graphics stages' own (see `stageOp`, `texture`, `stageLane`):
    /// a vertex's attribute words loaded and stored, a pixel's input word,
    /// its samples, its discard, a texture sampled and a texel fetched.
    ald,
    ast,
    ipa,
    pixld,
    kill,
    tex,
    tld,
};

/// The instructions only a graphics stage has.
fn isStageKind(k: Kind) bool {
    return switch (k) {
        .ald, .ast, .ipa, .pixld, .kill, .tex, .tld => true,
        else => false,
    };
}

const SrcKind = enum(u3) { none, gpr, ugpr, imm, cbuf, pred, upred };

const Src = struct {
    kind: SrcKind = .none,
    n: u8 = 0,
    neg: bool = false,
    abs: bool = false,
    /// A predicate's !.
    not: bool = false,
    /// Packed halves: 0 as they are (H0_H1), 1 H0_H0, 2 H1_H1, 3 swapped.
    swz: u2 = 0,
    /// An immediate (sign-extended where it is signed); a constant's offset.
    imm: u64 = 0,
    bank: u8 = 0,
    /// A constant read's index register (LDC c[0x0][R2+0x10]).
    index: u8 = RZ,
};

const File = enum(u3) { none, gpr, ugpr, pred, upred };

const Dst = struct { file: File = .none, n: u8 = 0 };

const Round = enum(u2) { rn, rm, rp, rz };

const Ty = enum(u8) { f16, bf16, f32, f64, s8, u8, s16, u16, s32, u32, s64, u64 };

/// A memory operand: base register (32 or 64 bits), a uniform register
/// added, an offset.
const Mem = struct {
    base: Src = .{},
    wide: bool = false,
    offset: i32 = 0,
};

const Op = struct {
    kind: Kind = .invalid,
    /// Runs once a warp on the uniform datapath.
    uniform: bool = false,
    guard: sm120.Pred = .{},
    control: sm120.Control = .{},
    d: [2]Dst = .{ .{}, .{} },
    s: [4]Src = .{ .{}, .{}, .{}, .{} },
    /// A predicate operand: an accumulator, a selector, a carry in.
    p: Src = .{},
    /// What kind of the kind (a comparison, a function, a mode, a type).
    sub: u8 = 0,
    sub2: u8 = 0,
    lut: [2]u8 = .{ 0, 0 },
    unsigned: bool = false,
    ftz: bool = false,
    /// F2I's .NTZ: NaN to 0 (without it NaN is the integer indefinite).
    ntz: bool = false,
    sat: bool = false,
    rnd: Round = .rn,
    hi: bool = false,
    x: bool = false,
    left: bool = false,
    wrap: bool = false,
    f32out: bool = false,
    ty: [2]Ty = .{ .f32, .f32 },
    /// A memory access's bytes, and whether a narrow load sign-extends.
    size: u8 = 4,
    signed: bool = false,
    mem: Mem = .{},
    /// A branch's target (an instruction index).
    target: u32 = 0,
    uses: sched.Uses = .{},
    /// Decoupled through the load/store pipe (in order).
    lsu: bool = false,
    /// A graphics stage's instruction in a form that is not run: it traps
    /// as unsupported, for this reason, when a thread reaches it.
    refuse: Why = .none,
    top: ?u8 = null,

    fn name(op: *const Op) []const u8 {
        return @tagName(op.kind);
    }
};

fn isCollective(k: Kind) bool {
    return k == .shfl or k == .vote;
}

// ── The work area ───────────────────────────────────────────────────────────

const TState = enum(u8) { off, run, bar, coll, done, bsync };

/// A register's history in its warp: the last write, the last fixed-
/// latency read, the last read through each pipe of the variable-latency
/// instructions.
const Track = struct {
    gen: u32 = 0,
    w_pc: u32 = NO_PC,
    w_cycle: u32 = 0,
    w_epoch: u32 = 0,
    w_cat: u8 = 0,
    w_bar: u3 = NONE,
    w_dec: bool = false,
    w_lsu: bool = false,
    r_pc: u32 = NO_PC,
    r_cycle: u32 = 0,
    r_cat: u8 = 0,
    /// [0]: the load/store pipe's, [1]: the others'.
    d: [2]DRead = .{ .{}, .{} },
};

const DRead = struct {
    pc: u32 = NO_PC,
    cycle: u32 = 0,
    seq: u32 = 0,
    rep: u32 = 0,
    wep: u32 = 0,
    cat: u8 = 0,
    rbar: u3 = NONE,
    wbar: u3 = NONE,
};

const WarpT = struct {
    cycle: u32 = 0,
    seq: u32 = 0,
    epoch: [BARS]u32 = .{0} ** BARS,
    count: [BARS]u32 = .{0} ** BARS,
    last: [BARS]u32 = .{0} ** BARS,
    last_pc: [BARS]u32 = .{0} ** BARS,
    /// The latest load/store-pipe instruction a scoreboard was set by.
    lsu_seq: [BARS]u32 = .{0} ** BARS,
    /// Load/store-pipe instructions up to this one have read their
    /// registers.
    lsu_done: u32 = 0,
    /// Each convergence barrier's lanes (BSSY's), by lane bit.
    bmask: [16]u32 = .{0} ** 16,
};

pub const Work = struct {
    ops: [MAX_INSTRS]Op = undefined,
    n_ops: u32 = 0,
    /// The highest general register the code touches.
    top: ?u8 = null,
    /// Staging for loaders.
    src: [MAX_INSTRS]Instr = undefined,
    tgt: [MAX_INSTRS]?u64 = undefined,
    regs: [MAX_THREADS][NREGS]u32 = undefined,
    preds: [MAX_THREADS]u8 = undefined,
    pc: [MAX_THREADS]u32 = undefined,
    st: [MAX_THREADS]TState = undefined,
    uregs: [MAX_WARPS][NREGS]u32 = undefined,
    upreds: [MAX_WARPS]u8 = undefined,
    warps: [MAX_WARPS]WarpT = undefined,
    tr_gpr: [MAX_WARPS][NREGS]Track = undefined,
    tr_ugpr: [MAX_WARPS][NREGS]Track = undefined,
    tr_pred: [MAX_WARPS][8]Track = undefined,
    /// Uniform predicates: one set a warp, as the registers are.
    tr_upred: [MAX_WARPS][8]Track = undefined,
    gen: u32 = 0,
    shared: [MAX_SHARED]u8 = undefined,
    local: [LOCAL_POOL]u8 = undefined,
    trap: Trap = .{},
    /// Check the control fields (else only run).
    check_hazards: bool = true,
    /// NAK's model (sm120_sched's guarantee) instead of the hardware's.
    strict: bool = false,
    /// A CTA's warps run between barriers last first (else first first).
    /// The SMs promise no order: a kernel that reads another warp's shared
    /// memory without a barrier between can pass one order and not the
    /// other.
    reverse_warps: bool = false,
    max_steps: u64 = DEFAULT_MAX_STEPS,
    /// The threads stageBegin started and stageRun has not run yet.
    begun: u32 = 0,
};

// ── Loading ─────────────────────────────────────────────────────────────────

/// `ins[i]` is the instruction at byte 16 i of the kernel; `targets[i]`
/// its branch's absolute target, when its operand does not carry one (a
/// parsed label). Forms that do not run are kept, and fail only if reached.
pub fn load(w: *Work, ins: []const Instr, targets: []const ?u64) Error!void {
    if (ins.len > MAX_INSTRS or targets.len < ins.len) return error.TooManyInstructions;
    w.n_ops = @intCast(ins.len);
    w.top = null;
    for (ins, 0..) |*in, i| {
        w.ops[i] = compile(in, targets[i], ins.len) catch |e| bad(in, e);
        if (w.ops[i].top) |r| w.top = if (w.top) |x| @max(x, r) else r;
    }
}

fn bad(in: *const Instr, e: Error) Op {
    return .{ .kind = if (e == error.Unsupported or e == error.Unknown) .unsupported else .invalid, .control = in.control };
}

/// A kernel's words, decoded (sm120.decode): what a QMD's program address
/// points at. Words that do not decode fail only if reached.
pub fn loadWords(w: *Work, words: []const u64) Error!void {
    const n = words.len / 2;
    if (n > MAX_INSTRS) return error.TooManyInstructions;
    for (0..n) |i| {
        w.tgt[i] = null;
        w.src[i] = sm120.decode(words[2 * i], words[2 * i + 1], i * 16) catch {
            // (an invalid instruction with the word's control field)
            w.src[i] = .{ .op = "", .control = sm120.Control.of(sm120.Word.of(words[2 * i], words[2 * i + 1])) };
            continue;
        };
    }
    return load(w, w.src[0..n], w.tgt[0..n]);
}

/// A kernel's instructions as a device runs them without decoding: its
/// words, and each 16 bytes' instruction (caller's storage). Built from
/// sm120_asm's output; the words are what the GPU's memory must hold.
pub const Program = struct {
    words: []const u64,
    instrs: []const Instr,
    targets: []const ?u64,

    /// `k`, just assembled with `aw`: every slot's instruction (the
    /// schedule's NOPs and the padding included), branch targets from
    /// their words. The instructions point into the assembler's text.
    pub fn fromAssembly(aw: *const sm120_asm.Work, k: sm120_asm.Kernel, instrs: []Instr, targets: []?u64) Error!Program {
        const n = k.code.len / 2;
        if (instrs.len < n or targets.len < n) return error.TooManyInstructions;
        for (0..n) |i| {
            const word = sm120.Word.of(k.code[2 * i], k.code[2 * i + 1]);
            instrs[i] = .{ .op = "NOP", .control = sm120.Control.of(word) };
            targets[i] = null;
        }
        const end = @as(u64, k.count) * 16;
        var i: usize = 0;
        while (i < MAX_INSTRS and aw.at[i] < end) : (i += 1) {
            const slot: usize = @intCast(aw.at[i] / 16);
            instrs[slot] = aw.instrs[i];
            const word = sm120.Word.of(k.code[2 * slot], k.code[2 * slot + 1]);
            instrs[slot].control = sm120.Control.of(word);
            if (aw.instrs[i].label() != null) targets[slot] = branchTarget(word, aw.at[i]);
        }
        return .{ .words = k.code, .instrs = instrs[0..n], .targets = targets[0..n] };
    }
};

/// A BRA word's target: its signed word offset (bits 16..23, then 34..81)
/// from the next instruction.
fn branchTarget(w: sm120.Word, pc: u64) u64 {
    const raw: u64 = w.get(16, 8) | (w.get(34, 48) << 8);
    const rel: i64 = @as(i64, @bitCast(raw << 8)) >> 8;
    return @bitCast(@as(i64, @intCast(pc + 16)) + rel * 4);
}

pub fn loadProgram(w: *Work, p: *const Program) Error!void {
    return load(w, p.instrs, p.targets);
}

/// sm120_asm's kernel `k`, just assembled with `aw`.
pub fn loadAssembled(w: *Work, aw: *const sm120_asm.Work, k: sm120_asm.Kernel) Error!void {
    const p = try Program.fromAssembly(aw, k, &w.src, &w.tgt);
    return load(w, p.instrs, p.targets);
}

/// A safe control field for a line written without one: wait on every
/// scoreboard, set the first for its reads and its writes, stall 15.
const SAFE = sm120.Control{ .wait = 0x3f, .read = 0, .write = 0, .stall = 15 };

/// A kernel from text, for forms sm120 does not encode yet: nvdisasm's
/// syntax, labels, comments (# and //), `.params` / `.stack` headers
/// (ignored); a line without a control field gets SAFE. Instructions point
/// into `text`.
pub fn loadText(w: *Work, text: []const u8) Error!void {
    var labels: [sm120_asm.MAX_LABELS]struct { name: []const u8, at: u64 } = undefined;
    var n_labels: usize = 0;
    var n: usize = 0;
    var pass: u2 = 0;
    while (pass < 2) : (pass += 1) {
        n = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            var t = raw;
            if (std.mem.indexOf(u8, t, "//")) |c| t = t[0..c];
            t = std.mem.trim(u8, t, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            if (t[t.len - 1] == ':') {
                if (pass == 0) {
                    if (n_labels == labels.len) return error.Syntax;
                    labels[n_labels] = .{ .name = t[0 .. t.len - 1], .at = n * 16 };
                    n_labels += 1;
                }
                continue;
            }
            if (t[0] == '.') continue; // (.params, .stack)
            if (n == MAX_INSTRS) return error.TooManyInstructions;
            if (pass == 1) {
                w.src[n] = try sm120.parse(t);
                if (t[0] != '[') w.src[n].control = SAFE;
                w.tgt[n] = null;
                if (w.src[n].label()) |l| {
                    for (labels[0..n_labels]) |x| {
                        if (std.mem.eql(u8, x.name, l)) w.tgt[n] = x.at;
                    }
                    if (w.tgt[n] == null) return error.NoTarget;
                }
            }
            n += 1;
        }
    }
    return load(w, w.src[0..n], w.tgt[0..n]);
}

// ── Compiling one instruction ───────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Want = enum { int, f32, f16 };

fn floatText(t: []const u8) ?f64 {
    if (eql(t, "+INF") or eql(t, "INF")) return std.math.inf(f64);
    if (eql(t, "-INF")) return -std.math.inf(f64);
    if (eql(t, "+QNAN") or eql(t, "QNAN") or eql(t, "-QNAN") or eql(t, "NAN")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch null;
}

fn intText(t: []const u8) ?i64 {
    var s = t;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    const v: u64 = if (std.mem.startsWith(u8, s, "0x"))
        std.fmt.parseInt(u64, s[2..], 16) catch return null
    else
        std.fmt.parseInt(u64, s, 10) catch return null;
    const sv: i64 = @bitCast(v);
    return if (neg) -%sv else sv;
}

/// A number operand's value: parsed text, or a decoded immediate (signed
/// ones sign-extended from their 32 bits).
fn numValue(o: Operand, want: Want) Error!u64 {
    switch (o) {
        .imm => |x| {
            if (x.kind == .signed) return @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(x.bits))))));
            return x.bits;
        },
        .num => |t| switch (want) {
            .int => return @bitCast(intText(t) orelse return error.Syntax),
            .f32 => {
                if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u32, t[2..], 16) catch error.Syntax;
                const f = floatText(t) orelse return error.Syntax;
                return @as(u32, @bitCast(@as(f32, @floatCast(f))));
            },
            .f16 => {
                if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u16, t[2..], 16) catch error.Syntax;
                const f = floatText(t) orelse return error.Syntax;
                return @as(u16, @bitCast(@as(f16, @floatCast(f))));
            },
        },
        else => return error.Syntax,
    }
}

fn isNum(o: Operand) bool {
    return o == .num or o == .imm;
}

/// A register written with a halves' swizzle (R4.H0_H0), which sm120's
/// parser leaves as text.
fn swizzled(t: []const u8) ?Src {
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse return null;
    const sw: u2 = if (eql(t[dot..], ".H0_H0")) 1 else if (eql(t[dot..], ".H1_H1")) 2 else if (eql(t[dot..], ".H1_H0")) 3 else if (eql(t[dot..], ".H0_H1")) 0 else return null;
    const r = t[0..dot];
    if (eql(r, "RZ")) return .{ .kind = .gpr, .n = RZ, .swz = sw };
    if (r.len < 2 or r[0] != 'R') return null;
    const n = std.fmt.parseInt(u8, r[1..], 10) catch return null;
    if (n == RZ) return null;
    return .{ .kind = .gpr, .n = n, .swz = sw };
}

fn srcOf(o: Operand, want: Want) Error!Src {
    return switch (o) {
        // (sm120 now parses and decodes a halves' selector into the
        // register: R4.H1_H1 is .gpr with sel h1_h1, swizzle 2 here)
        .gpr => |r| .{ .kind = .gpr, .n = r.n, .neg = r.neg, .abs = r.abs, .swz = switch (r.sel) {
            .h0_h0 => 1,
            .h1_h1 => 2,
            else => 0,
        } },
        .ugpr => |r| .{ .kind = .ugpr, .n = r.n, .neg = r.neg, .abs = r.abs },
        .pred => |p| .{ .kind = .pred, .n = p.n, .not = p.not },
        .upred => |p| .{ .kind = .upred, .n = p.n, .not = p.not },
        .cbuf => |c| .{ .kind = .cbuf, .bank = c.bank, .imm = c.offset, .index = c.reg, .neg = c.neg, .abs = c.abs },
        .num => |t| if (want == .f16 and t.len > 0 and t[0] == 'R') (swizzled(t) orelse error.Syntax) else .{ .kind = .imm, .imm = try numValue(o, want) },
        .imm => .{ .kind = .imm, .imm = try numValue(o, want) },
        else => error.Syntax,
    };
}

fn predSrc(o: Operand) Error!Src {
    return switch (o) {
        .pred => |p| .{ .kind = .pred, .n = p.n, .not = p.not },
        .upred => |p| .{ .kind = .upred, .n = p.n, .not = p.not },
        else => error.Syntax,
    };
}

fn dstOf(o: Operand) Error!Dst {
    return switch (o) {
        .gpr => |r| .{ .file = .gpr, .n = r.n },
        .ugpr => |r| .{ .file = .ugpr, .n = r.n },
        .pred => |p| blk: {
            if (p.not) return error.Syntax;
            break :blk .{ .file = .pred, .n = p.n };
        },
        .upred => |p| blk: {
            if (p.not) return error.Syntax;
            break :blk .{ .file = .upred, .n = p.n };
        },
        else => error.Syntax,
    };
}

fn count(in: *const Instr, n: usize) Error!void {
    if (in.n_ops != n) return error.Syntax;
}

fn sizeOf(in: *const Instr) struct { bytes: u8, signed: bool } {
    if (in.has("U8")) return .{ .bytes = 1, .signed = false };
    if (in.has("S8")) return .{ .bytes = 1, .signed = true };
    if (in.has("U16")) return .{ .bytes = 2, .signed = false };
    if (in.has("S16")) return .{ .bytes = 2, .signed = true };
    if (in.has("64")) return .{ .bytes = 8, .signed = false };
    if (in.has("128")) return .{ .bytes = 16, .signed = false };
    return .{ .bytes = 4, .signed = false };
}

fn rndOf(in: *const Instr) Round {
    if (in.has("RM") or in.has("FLOOR")) return .rm;
    if (in.has("RP") or in.has("CEIL")) return .rp;
    if (in.has("RZ") or in.has("TRUNC")) return .rz;
    return .rn;
}

const CMP_I = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "T" };
const CMP_F = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "NUM", "NAN", "LTU", "EQU", "LEU", "GTU", "NEU", "GEU", "T" };

fn cmpOf(in: *const Instr, names: []const []const u8) Error!u8 {
    for (names, 0..) |nm, i| {
        if (in.has(nm)) return @intCast(i);
    }
    return error.Unsupported;
}

fn boolOf(in: *const Instr) Error!u8 {
    if (in.has("AND")) return 0;
    if (in.has("OR")) return 1;
    if (in.has("XOR")) return 2;
    return error.Unsupported;
}

const TYPES = [_]struct { []const u8, Ty }{
    .{ "F16", .f16 }, .{ "BF16", .bf16 }, .{ "F32", .f32 }, .{ "F64", .f64 },
    .{ "S8", .s8 },   .{ "U8", .u8 },     .{ "S16", .s16 }, .{ "U16", .u16 },
    .{ "S32", .s32 }, .{ "U32", .u32 },   .{ "S64", .s64 }, .{ "U64", .u64 },
};

/// The type modifiers, in order (at most two).
fn typesOf(in: *const Instr, out: *[2]Ty) usize {
    var n: usize = 0;
    for (in.mods[0..in.n_mods]) |m| {
        for (TYPES) |t| {
            if (eql(m, t[0]) and n < 2) {
                out[n] = t[1];
                n += 1;
            }
        }
    }
    return n;
}

fn isFloat(t: Ty) bool {
    return t == .f16 or t == .bf16 or t == .f32 or t == .f64;
}

fn tyBits(t: Ty) u8 {
    return switch (t) {
        .s8, .u8 => 8,
        .f16, .bf16, .s16, .u16 => 16,
        .f32, .s32, .u32 => 32,
        .f64, .s64, .u64 => 64,
    };
}

fn isSigned(t: Ty) bool {
    return t == .s8 or t == .s16 or t == .s32 or t == .s64;
}

/// The uniform forms: their names on the uniform datapath.
const UNIFORM = [_]struct { []const u8, []const u8 }{
    .{ "UIADD3", "IADD3" }, .{ "ULOP3", "LOP3" },   .{ "USHF", "SHF" },     .{ "UISETP", "ISETP" },
    .{ "ULEA", "LEA" },     .{ "UIMAD", "IMAD" },   .{ "UMOV", "MOV" },     .{ "USEL", "SEL" },
    .{ "UPRMT", "PRMT" },   .{ "UFLO", "FLO" },     .{ "UPOPC", "POPC" },   .{ "UBREV", "BREV" },
    .{ "UPLOP3", "PLOP3" }, .{ "UIABS", "IABS" },   .{ "UIMNMX", "IMNMX" }, .{ "UVIMNMX", "IMNMX" },
    .{ "S2UR", "S2R" },     .{ "LDCU", "LDC" },     .{ "ULDC", "LDC" },     .{ "UIADD", "IADD" },
};

const HINTS = [_][]const u8{ "WARPSYNC", "MEMBAR", "ERRBAR", "CCTL", "NANOSLEEP", "YIELD", "CGAERRBAR", "FENCE" };

fn compile(in: *const Instr, given: ?u64, n_code: usize) Error!Op {
    var op = Op{ .guard = in.guard, .control = in.control };
    var name = in.op;
    for (UNIFORM) |u| {
        if (eql(name, u[0])) {
            name = u[1];
            op.uniform = true;
        }
    }
    const o = in.operands();
    try body(&op, in, name, o, given, n_code);
    // (a graphics instruction with registers past R254 is not run, and its
    // registers are not counted: sm120.highestGpr and sm120_sched.usesOf
    // add a register's number and its count in eight bits)
    if (isStageKind(op.kind) and pastR254(in)) {
        if (op.refuse == .none) op.refuse = .form;
        return op;
    }
    op.uses = sched.usesOf(in) catch fallbackUses(&op, in);
    // (an LDC's index register is read too: NAK's category, decoupled)
    if (op.kind == .ldc and op.s[0].index != RZ and !reads(&op.uses, .gpr, op.s[0].index)) add(&op.uses, false, .gpr, op.s[0].index, @intFromEnum(lat.Reg.decoupled));
    op.top = sm120.highestGpr(in);
    if (op.kind == .ldc and op.s[0].index != RZ) op.top = @max(op.top orelse 0, op.s[0].index);
    // (a texture's registers as it really reads and writes them, not
    // sm120_sched's longest vectors, nor sm120.regsAt's)
    if ((op.kind == .tex or op.kind == .tld) and op.refuse == .none) {
        op.uses = textureUses(&op);
        op.top = topOf(&op.uses);
    }
    return op;
}

fn reads(u: *const sched.Uses, file: sched.File, n: u8) bool {
    for (u.srcs()) |x| {
        if (x.file == file and x.n == n) return true;
    }
    return false;
}

fn body(op: *Op, in: *const Instr, name: []const u8, o: []const Operand, given: ?u64, n_code: usize) Error!void {
    if (name.len == 0) return error.BadInstruction;
    if (eql(name, "NOP")) {
        op.kind = .nop;
    } else if (eql(name, "EXIT")) {
        op.kind = .exit;
    } else if (eql(name, "BRA")) {
        // BRA `(target); the forms with a predicate operand (BRA.DIV, .U)
        // are not run
        try count(in, 1);
        const t: u64 = switch (o[0]) {
            .target => |x| x,
            .label => given orelse return error.NoTarget,
            else => return error.Unsupported,
        };
        if (t % 16 != 0 or t / 16 >= n_code) return error.BadInstruction;
        op.kind = .bra;
        op.target = @intCast(t / 16);
    } else if (eql(name, "BAR")) {
        // BAR.SYNC(.DEFER_BLOCKING) id: every thread of the CTA
        if (!in.has("SYNC") or in.n_ops != 1) return error.Unsupported;
        op.kind = .bar;
        op.sub = @intCast(try numValue(o[0], .int) & 0xf);
    } else if (eql(name, "BSSY") or eql(name, "BSYNC")) {
        op.kind = if (eql(name, "BSSY")) .bssy else .bsync;
        const b = for (o) |x| {
            if (x == .barrier) break x.barrier;
        } else return error.Syntax;
        op.sub = b & 15;
    } else if (isHint(name)) {
        op.kind = .hint;
    } else if (eql(name, "S2R")) {
        try count(in, 2);
        if (o[1] != .sreg) return error.Syntax;
        op.kind = .s2r;
        op.d[0] = try dstOf(o[0]);
        op.sub = o[1].sreg;
    } else if (eql(name, "CS2R")) {
        // CS2R(.32) Rd, SRZ | SR_CLOCKLO
        try count(in, 2);
        op.kind = .cs2r;
        op.d[0] = try dstOf(o[0]);
        op.size = if (in.has("32")) 4 else 8;
        op.sub = switch (o[1]) {
            .sreg => |s| s,
            .num => |t| if (eql(t, "SRZ")) 0xff else return error.Unsupported,
            else => return error.Syntax,
        };
    } else if (eql(name, "R2UR")) {
        try count(in, 2);
        op.kind = .r2ur;
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
    } else if (eql(name, "LDC")) {
        try count(in, 2);
        if (o[1] != .cbuf) return error.Unsupported;
        op.kind = .ldc;
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
        const sz = sizeOf(in);
        op.size = sz.bytes;
        op.signed = sz.signed;
        if (op.size > 8) return error.Unsupported;
    } else if (eql(name, "MOV")) {
        if (in.has("64")) {
            try count(in, 2);
            op.kind = .mov64;
            op.d[0] = try dstOf(o[0]);
            op.s[0] = try srcOf(o[1], .int);
        } else {
            // MOV Rd, src (, lane mask)
            if (in.n_ops != 2 and in.n_ops != 3) return error.Syntax;
            op.kind = .mov;
            op.d[0] = try dstOf(o[0]);
            op.s[0] = try srcOf(o[1], .int);
        }
    } else if (eql(name, "IADD")) {
        try count(in, 3);
        op.kind = if (in.has("64")) .iadd64 else .iadd;
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
        op.s[1] = try srcOf(o[2], .int);
    } else if (eql(name, "IADD3")) {
        // IADD3 Rd, Pc0, Pc1, a, b, c: the carry outs are not modelled
        if (in.has("X")) return error.Unsupported;
        try count(in, 6);
        if (o[1] != .pred and o[1] != .upred) return error.Syntax;
        if (predNum(o[1]) != PT or predNum(o[2]) != PT) return error.Unsupported;
        op.kind = .iadd3;
        op.d[0] = try dstOf(o[0]);
        for (0..3) |k| op.s[k] = try srcOf(o[3 + k], .int);
    } else if (eql(name, "IMAD")) {
        if (in.has("X")) return error.Unsupported;
        try count(in, 4);
        op.kind = if (in.has("WIDE")) .imad_wide else if (in.has("HI")) .imad_hi else .imad;
        op.unsigned = in.has("U32");
        op.d[0] = try dstOf(o[0]);
        for (0..3) |k| op.s[k] = try srcOf(o[1 + k], .int);
    } else if (eql(name, "ISETP")) {
        if (in.has("EX")) return error.Unsupported;
        try count(in, 5);
        op.kind = .isetp;
        op.sub = try cmpOf(in, &CMP_I);
        op.sub2 = try boolOf(in);
        op.unsigned = in.has("U32");
        op.d[0] = try dstOf(o[0]);
        op.d[1] = try dstOf(o[1]);
        op.s[0] = try srcOf(o[2], .int);
        op.s[1] = try srcOf(o[3], .int);
        op.p = try predSrc(o[4]);
    } else if (eql(name, "LOP3")) {
        // LOP3.LUT (Pd,) Rd, a, b, c, lut, !PT
        if (!in.has("LUT")) return error.Unsupported;
        var k: usize = 0;
        if (in.n_ops == 7) {
            op.d[1] = try dstOf(o[0]);
            k = 1;
        } else try count(in, 6);
        op.kind = .lop3;
        op.d[0] = try dstOf(o[k]);
        for (0..3) |j| op.s[j] = try srcOf(o[k + 1 + j], .int);
        op.lut[0] = @truncate(try numValue(o[k + 4], .int));
        const ps = try predSrc(o[k + 5]);
        if (ps.n != PT or !ps.not) return error.Unsupported;
    } else if (eql(name, "PLOP3")) {
        try count(in, 7);
        op.kind = .plop3;
        op.d[0] = try dstOf(o[0]);
        op.d[1] = try dstOf(o[1]);
        for (0..3) |j| op.s[j] = try predSrc(o[2 + j]);
        op.lut[0] = @truncate(try numValue(o[5], .int));
        op.lut[1] = @truncate(try numValue(o[6], .int));
    } else if (eql(name, "FFMA") or eql(name, "FADD") or eql(name, "FMUL")) {
        for ([_][]const u8{ "D2", "D4", "D8", "M2", "M4", "M8" }) |m| if (in.has(m)) return error.Unsupported;
        const n: usize = if (eql(name, "FFMA")) 4 else 3;
        try count(in, n);
        op.kind = if (n == 4) .ffma else if (eql(name, "FADD")) .fadd else .fmul;
        floatMods(op, in);
        op.d[0] = try dstOf(o[0]);
        for (1..n) |k| op.s[k - 1] = try srcOf(o[k], .f32);
    } else if (eql(name, "FMNMX") or eql(name, "FSEL")) {
        try count(in, 4);
        op.kind = if (eql(name, "FMNMX")) .fmnmx else .fsel;
        op.ftz = in.has("FTZ");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
        op.s[1] = try srcOf(o[2], .f32);
        op.p = try predSrc(o[3]);
    } else if (eql(name, "FSETP")) {
        try count(in, 5);
        op.kind = .fsetp;
        op.sub = try cmpOf(in, &CMP_F);
        op.sub2 = try boolOf(in);
        op.ftz = in.has("FTZ");
        op.d[0] = try dstOf(o[0]);
        op.d[1] = try dstOf(o[1]);
        op.s[0] = try srcOf(o[2], .f32);
        op.s[1] = try srcOf(o[3], .f32);
        op.p = try predSrc(o[4]);
    } else if (eql(name, "MUFU")) {
        try count(in, 2);
        const fns = [_][]const u8{ "EX2", "LG2", "RCP", "RSQ", "SQRT", "SIN", "COS", "TANH" };
        op.kind = .mufu;
        op.sub = try cmpOf(in, &fns);
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
    } else if (eql(name, "HFMA2") or eql(name, "HADD2") or eql(name, "HMUL2")) {
        try halves(op, in, name, o);
    } else if (eql(name, "I2FP") or eql(name, "I2F")) {
        try count(in, 2);
        op.kind = .i2f;
        var t: [2]Ty = undefined;
        const n = typesOf(in, &t);
        op.ty = .{ .f32, .s32 };
        if (n == 2) op.ty = t else if (n == 1) {
            if (isFloat(t[0])) op.ty[0] = t[0] else op.ty[1] = t[0];
        }
        if (!isFloat(op.ty[0]) or isFloat(op.ty[1])) return error.Unsupported;
        op.rnd = rndOf(in);
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
    } else if (eql(name, "F2I")) {
        try count(in, 2);
        op.kind = .f2i;
        var t: [2]Ty = undefined;
        const n = typesOf(in, &t);
        op.ty = .{ .s32, .f32 };
        for (t[0..n]) |x| {
            if (isFloat(x)) op.ty[1] = x else op.ty[0] = x;
        }
        if (op.ty[1] == .bf16) return error.Unsupported;
        op.rnd = rndOf(in);
        op.ftz = in.has("FTZ");
        op.ntz = in.has("NTZ");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
    } else if (eql(name, "F2F")) {
        try count(in, 2);
        op.kind = .f2f;
        var t: [2]Ty = undefined;
        if (typesOf(in, &t) != 2 or !isFloat(t[0]) or !isFloat(t[1])) return error.Unsupported;
        op.ty = t;
        op.rnd = rndOf(in);
        op.ftz = in.has("FTZ");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
    } else if (eql(name, "F2FP")) {
        // F2FP(.F16|.BF16)(.F32).PACK_AB Rd, a, b: a to the high half
        if (!in.has("PACK_AB")) return error.Unsupported;
        try count(in, 3);
        op.kind = .f2fp;
        op.ty[0] = if (in.has("BF16")) .bf16 else .f16;
        op.rnd = rndOf(in);
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
        op.s[1] = try srcOf(o[2], .f32);
    } else if (eql(name, "FRND")) {
        try count(in, 2);
        op.kind = .frnd;
        op.rnd = rndOf(in);
        op.ftz = in.has("FTZ");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .f32);
    } else if (eql(name, "SEL")) {
        try count(in, 4);
        op.kind = .sel;
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
        op.s[1] = try srcOf(o[2], .int);
        op.p = try predSrc(o[3]);
    } else if (eql(name, "IMNMX") or eql(name, "VIMNMX")) {
        try count(in, 4);
        op.kind = .imnmx;
        op.unsigned = in.has("U32");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
        op.s[1] = try srcOf(o[2], .int);
        op.p = try predSrc(o[3]);
    } else if (eql(name, "IABS") or eql(name, "POPC") or eql(name, "BREV") or eql(name, "FLO")) {
        try count(in, 2);
        op.kind = if (eql(name, "IABS")) .iabs else if (eql(name, "POPC")) .popc else if (eql(name, "BREV")) .brev else .flo;
        op.unsigned = in.has("U32");
        op.hi = in.has("SH");
        op.d[0] = try dstOf(o[0]);
        op.s[0] = try srcOf(o[1], .int);
    } else if (eql(name, "LEA")) {
        try lea(op, in, o);
    } else if (eql(name, "SHF")) {
        // SHF.L|R(.W).U32|S32|U64|S64(.HI) Rd, lo, shift, hi
        try count(in, 4);
        op.kind = .shf;
        op.left = in.has("L");
        if (!op.left and !in.has("R")) return error.Syntax;
        op.wrap = in.has("W");
        op.hi = in.has("HI");
        var t: [2]Ty = undefined;
        if (typesOf(in, &t) != 1) return error.Syntax;
        op.ty[0] = t[0];
        op.d[0] = try dstOf(o[0]);
        for (0..3) |k| op.s[k] = try srcOf(o[1 + k], .int);
    } else if (eql(name, "PRMT")) {
        // PRMT Rd, a, selector, b: the default mode only
        for ([_][]const u8{ "F4E", "B4E", "RC8", "ECL", "ECR", "RC16" }) |m| if (in.has(m)) return error.Unsupported;
        try count(in, 4);
        op.kind = .prmt;
        op.d[0] = try dstOf(o[0]);
        for (0..3) |k| op.s[k] = try srcOf(o[1 + k], .int);
    } else if (eql(name, "IDP")) {
        // IDP.4A.S8|U8.S8|U8 Rd, a, b, c
        if (!in.has("4A")) return error.Unsupported;
        try count(in, 4);
        var t: [2]Ty = undefined;
        if (typesOf(in, &t) != 2) return error.Syntax;
        op.kind = .idp;
        op.ty = t;
        op.d[0] = try dstOf(o[0]);
        for (0..3) |k| op.s[k] = try srcOf(o[1 + k], .int);
    } else if (eql(name, "LDG") or eql(name, "STG") or eql(name, "LDL") or eql(name, "STL") or eql(name, "LDS") or eql(name, "STS")) {
        try memory(op, in, name, o);
    } else if (eql(name, "ATOMG") or eql(name, "ATOMS")) {
        try atomic(op, in, name, o);
    } else if (eql(name, "SHFL")) {
        // SHFL.IDX|UP|DOWN|BFLY Pd, Rd, a, lane, clamp
        try count(in, 5);
        const modes = [_][]const u8{ "IDX", "UP", "DOWN", "BFLY" };
        op.kind = .shfl;
        op.sub = try cmpOf(in, &modes);
        op.d[1] = try dstOf(o[0]);
        op.d[0] = try dstOf(o[1]);
        op.s[0] = try srcOf(o[2], .int);
        op.s[1] = try srcOf(o[3], .int);
        op.s[2] = try srcOf(o[4], .int);
        op.lsu = true;
    } else if (eql(name, "VOTE") or eql(name, "VOTEU")) {
        // VOTE.ANY|ALL|EQ (Rd,) Pd, Ps; VOTEU: a uniform ballot
        const modes = [_][]const u8{ "ANY", "ALL", "EQ" };
        op.kind = .vote;
        op.sub = try cmpOf(in, &modes);
        if (in.n_ops == 3) {
            op.d[0] = try dstOf(o[0]);
            op.d[1] = try dstOf(o[1]);
            op.p = try predSrc(o[2]);
        } else {
            try count(in, 2);
            op.d[1] = try dstOf(o[0]);
            op.p = try predSrc(o[1]);
        }
    } else if (eql(name, "ALD") or eql(name, "AST") or eql(name, "IPA") or eql(name, "PIXLD") or eql(name, "KILL")) {
        try stageOp(op, in, name, o);
    } else if (eql(name, "TEX") or eql(name, "TLD")) {
        try texture(op, in, name, o);
    } else return error.Unsupported;
    // (the uniform datapath reads no thread's registers)
    if (op.uniform) {
        for (op.s) |s| if (s.kind == .gpr and s.n != RZ) return error.Syntax;
    }
}

fn isHint(name: []const u8) bool {
    for (HINTS) |h| {
        if (eql(name, h)) return true;
    }
    return false;
}

fn predNum(o: Operand) u3 {
    return switch (o) {
        .pred => |p| if (p.not) 0 else p.n,
        .upred => |p| if (p.not) 0 else p.n,
        else => 0,
    };
}

fn floatMods(op: *Op, in: *const Instr) void {
    op.ftz = in.has("FTZ");
    op.sat = in.has("SAT");
    op.rnd = rndOf(in);
}

/// HFMA2 Rd, a, b, c; HADD2 Rd, a, b; HMUL2 Rd, a, b (an immediate as two
/// halves, high first).
fn halves(op: *Op, in: *const Instr, name: []const u8, o: []const Operand) Error!void {
    if (in.has("BF16_V2") or in.has("BF16") or in.has("RELU")) return error.Unsupported;
    const srcs: usize = if (eql(name, "HFMA2")) 3 else 2;
    op.kind = if (srcs == 3) .hfma2 else if (eql(name, "HADD2")) .hadd2 else .hmul2;
    op.ftz = in.has("FTZ");
    op.sat = in.has("SAT");
    op.f32out = in.has("F32");
    // (the last source may be an immediate pair: two operands)
    const pair = in.n_ops == srcs + 2;
    if (in.n_ops != srcs + 1 and !pair) return error.Syntax;
    op.d[0] = try dstOf(o[0]);
    for (0..srcs) |j| {
        if (pair and j == srcs - 1) {
            const h = try numValue(o[1 + j], .f16);
            const l = try numValue(o[2 + j], .f16);
            op.s[j] = .{ .kind = .imm, .imm = (h & 0xffff) << 16 | (l & 0xffff) };
        } else op.s[j] = try srcOf(o[1 + j], .f16);
    }
}

/// LEA (Pd,) a, b, shift; LEA.HI(.X)(.SX32) (Pd,) a, b, (ahi,) shift(, Pc).
fn lea(op: *Op, in: *const Instr, o: []const Operand) Error!void {
    op.hi = in.has("HI");
    op.x = in.has("X");
    const sx32 = in.has("SX32");
    op.kind = if (op.hi) .lea_hi else .lea;
    var k: usize = 0;
    op.d[0] = try dstOf(o[k]);
    k += 1;
    if (k < in.n_ops and (o[k] == .pred or o[k] == .upred)) {
        op.d[1] = try dstOf(o[k]);
        k += 1;
    }
    if (k + 3 > in.n_ops) return error.Syntax;
    op.s[0] = try srcOf(o[k], .int);
    op.s[1] = try srcOf(o[k + 1], .int);
    k += 2;
    if (op.hi and !sx32) {
        op.s[2] = try srcOf(o[k], .int);
        k += 1;
    }
    op.wrap = sx32; // (the high word of a sign-extended)
    if (k >= in.n_ops) return error.Syntax;
    op.sub = @intCast(try numValue(o[k], .int) & 31);
    k += 1;
    if (op.x) {
        if (k >= in.n_ops) return error.Syntax;
        op.p = try predSrc(o[k]);
        k += 1;
    }
    if (k != in.n_ops) return error.Syntax;
}

/// ATOMG.E.op(.S32).order Pd, Rd, desc[URd][Ra.64+offset], Rb; ATOMS.op(.S32)
/// Rd, [Ra+offset], Rb: the 32-bit atomics (ADD, MIN, MAX, INC, DEC, AND,
/// OR, XOR, EXCH), the old value to Rd.
fn atomic(op: *Op, in: *const Instr, name: []const u8, o: []const Operand) Error!void {
    const global_ = eql(name, "ATOMG");
    // (CAS: Rc stored where the old word equals Rb; ATOMG.E.CAS's address
    // is 64 bits without .64)
    const cas = in.has("CAS");
    try count(in, @as(usize, if (global_) 4 else 3) + @intFromBool(cas));
    const ops = [_][]const u8{ "ADD", "MIN", "MAX", "INC", "DEC", "AND", "OR", "XOR", "EXCH", "CAS" };
    op.kind = if (global_) .atomg else .atoms;
    op.sub = try cmpOf(in, &ops);
    op.signed = in.has("S32");
    if (in.has("64") or in.has("S64") or in.has("128")) return error.Unsupported;
    var k: usize = 0;
    if (global_) {
        op.d[1] = try dstOf(o[0]);
        k = 1;
    }
    op.d[0] = try dstOf(o[k]);
    if (o[k + 1] != .addr) return error.Syntax;
    const ad = o[k + 1].addr;
    if ((global_ and !cas) != ad.wide or (!global_ and ad.desc != null) or (cas and ad.desc != null)) return error.Unsupported;
    op.mem = .{ .base = .{ .kind = .gpr, .n = ad.reg }, .wide = global_, .offset = ad.offset };
    op.s[0] = try srcOf(o[k + 2], .int);
    if (cas) op.s[1] = try srcOf(o[k + 3], .int);
    op.size = 4;
    op.lsu = true;
}

fn memory(op: *Op, in: *const Instr, name: []const u8, o: []const Operand) Error!void {
    try count(in, 2);
    const load_ = name[0] == 'L';
    op.kind = if (eql(name, "LDG")) .ldg else if (eql(name, "STG")) .stg else if (eql(name, "LDL")) .ldl else if (eql(name, "STL")) .stl else if (eql(name, "LDS")) .lds else .sts;
    const a = if (load_) o[1] else o[0];
    if (a != .addr) return error.Syntax;
    const ad = a.addr;
    op.mem = .{ .base = .{ .kind = .gpr, .n = ad.reg }, .wide = ad.wide, .offset = ad.offset };
    if ((op.kind == .ldl or op.kind == .stl or op.kind == .lds or op.kind == .sts) and (ad.desc != null or ad.wide)) return error.Unsupported;
    const sz = sizeOf(in);
    op.size = sz.bytes;
    op.signed = sz.signed;
    if (load_) op.d[0] = try dstOf(o[0]) else op.s[0] = try srcOf(o[1], .int);
    op.lsu = true;
}

// ── The graphics stages' instructions, compiled ─────────────────────────────

/// Whether `words` attribute words from byte address `offset` are ones a
/// Stage carries: whole words below 0x300, two of them from a multiple of
/// 8 and three or four from a multiple of 16. (The last is NAK's rule for
/// what it emits, nak_nir_lower_vtg_io.c: it splits any other vector.
/// Whether the hardware needs it is not known, so a vector elsewhere is
/// not run.)
fn attrFits(offset: u32, words: u32) bool {
    if (offset % 4 != 0 or offset / 4 + words > ATTR_WORDS) return false;
    const step: u32 = if (words == 1) 4 else if (words == 2) 8 else 16;
    return offset % step == 0;
}

/// The attribute instructions and KILL, as sm120.sig parses them:
///
/// - ALD(.64 | .96 | .128) Rd, a[address]: a vertex's attribute words, one
///   to four, into registers from Rd. Not run: .O (an output read back),
///   .P and .PHYS (patch and physical addresses), a vertex register
///   (another vertex's words: the geometry and tessellation stages').
/// - AST(.64 | .96 | .128) a[address], Rs: one to four registers from Rs
///   stored as the vertex's output words. Not run: .P, .PHYS, a vertex
///   register.
/// - IPA.PASS | .CONSTANT Rd, a[address]: a pixel's input word at its
///   centre. On sm_120 nothing in the instruction multiplies it (NAK
///   leaves the old inverse-w operand's bits zero, and nvdisasm ignores
///   them): perspective is the header's and the program's own FMUL by
///   MUFU.RCP of a[0x7c]. So .PASS and .CONSTANT both read the word the
///   engine carried; with a header they must agree with how it says the
///   word is carried. Not run: .STATE (NAK never emits it; what it reads
///   is not known), .CENTROID and .OFFSET (a Stage has the centre's words
///   only), a predicate result (NAK: "what is this for?"), an address past
///   0x2fc (the barycentrics) but the facing's: IPA.CONSTANT a[0x3fc]
///   reads the Stage's `front` (all ones for a front face, 0 for a back
///   one: NAK takes it as non-zero), with no header bit for it.
/// - PIXLD: a pixel's samples. Not run in any form: a Stage says nothing
///   of a pixel's samples.
/// - KILL: the pixel discarded, where the guard says. Not run: KILL with
///   its own predicate operand (NAK never writes one; how it combines
///   with the guard is not known).
///
/// A form that is not run still compiles, with `refuse` set: it traps when
/// a thread reaches it. What nvdisasm calls illegal (an index register
/// without .P or .PHYS, .PHYS without one or of more than a word) is a bad
/// instruction.
fn stageOp(op: *Op, in: *const Instr, name: []const u8, o: []const Operand) Error!void {
    if (eql(name, "KILL")) {
        op.kind = .kill;
        if (in.n_ops > 1 or (in.n_ops == 1 and o[0] != .pred)) return error.Syntax;
        if (in.n_ops == 1) op.refuse = .form;
        return;
    }
    if (eql(name, "PIXLD")) {
        if (in.n_ops < 1 or in.n_ops > 2 or o[0] != .gpr) return error.Syntax;
        if (in.n_ops == 2 and o[1] != .pred) return error.Syntax;
        op.kind = .pixld;
        op.d[0] = try dstOf(o[0]);
        if (in.n_ops == 2) op.d[1] = try dstOf(o[1]);
        op.refuse = .no_data;
        return;
    }
    if (eql(name, "IPA")) {
        if (in.n_ops < 2 or o[0] != .gpr) return error.Syntax;
        op.kind = .ipa;
        op.d[0] = try dstOf(o[0]);
        var k: usize = 1;
        if (o[k] == .pred) {
            op.d[1] = try dstOf(o[k]);
            op.refuse = .form;
            k += 1;
        }
        if (k >= in.n_ops or o[k] != .attr) return error.Syntax;
        const a = o[k].attr;
        // (a word's address, never through a register: 64..71 hold its index)
        if (a.reg != RZ or a.offset % 4 != 0 or a.offset > 0x3fc) return error.BadInstruction;
        op.mem.offset = a.offset;
        k += 1;
        const offset = in.has("OFFSET");
        if (offset) {
            if (k >= in.n_ops or o[k] != .gpr) return error.Syntax;
            op.s[0] = try srcOf(o[k], .int);
            k += 1;
        }
        if (k != in.n_ops) return error.Syntax;
        op.sub = if (in.has("PASS")) 0 else if (in.has("CONSTANT")) 1 else if (in.has("STATE")) 2 else return error.BadInstruction;
        if (op.sub == 2) op.refuse = .form;
        if (offset or in.has("CENTROID")) op.refuse = .no_data;
        if (a.offset / 4 >= ATTR_WORDS and a.offset != sph.ATTR_FRONT_FACE) op.refuse = .address;
        return;
    }
    const load_ = eql(name, "ALD");
    if (in.n_ops < 2 or in.n_ops > 3) return error.Syntax;
    const a = if (load_) o[1] else o[0];
    const r = if (load_) o[0] else o[1];
    if (a != .attr or r != .gpr or (in.n_ops == 3 and o[2] != .gpr)) return error.Syntax;
    const words: u8 = sm120.dataWidth(in);
    const patch = in.has("P");
    const phys = in.has("PHYS");
    if (phys) {
        if (patch or a.attr.reg == RZ or words != 1) return error.BadInstruction;
    } else if (!patch and a.attr.reg != RZ) return error.BadInstruction;
    if (a.attr.offset > 0x3ff) return error.BadInstruction;
    op.kind = if (load_) .ald else .ast;
    op.size = 4 * words;
    op.mem.offset = a.attr.offset;
    if (load_) op.d[0] = .{ .file = .gpr, .n = r.gpr.n } else op.s[0] = .{ .kind = .gpr, .n = r.gpr.n };
    if (patch or phys or (load_ and in.has("O")) or in.n_ops == 3) {
        op.refuse = .form;
    } else if (!attrFits(a.attr.offset, words)) {
        op.refuse = .address;
    } else if (r.gpr.n != RZ and @as(u32, r.gpr.n) + words > RZ) {
        // (registers past R254)
        op.refuse = .form;
    }
}

/// The texture instructions, as sm120.sig parses them ((Pfault,) Rd1, Rd0,
/// Ra, Rb(, URc), dimension(, mask)):
///
/// - TEX.B(.LZ)(.NDV | .DXY)(.NODEP) Rd1, Rd0, Ra, Rb, 2D(, mask): the
///   Stage's `sample` called with the handle in Rb and the two floats in
///   Ra and the register after it.
/// - TLD.B.LZ | .LL(.NODEP) Rd1, Rd0, Ra, Rb, 2D(, mask): the Stage's
///   `fetch` called with the handle in Rb, the two integers in Ra and the
///   register after it, and level 0 (.LZ) or the level in the register
///   after Rb (.LL: NAK's order of a texel fetch's second vector).
///
/// The result's channels the mask names (all four when it is left out) go
/// to registers in order, as NAK lays them out: the first two to Rd0 and
/// the register after it, the rest to Rd1 and the one after it. So with
/// all four, red and green are in Rd0 on and blue and alpha in Rd1 on.
///
/// The level and the derivatives are the engine's: `sample` is given the
/// coordinates and nothing of the pixels beside this one, so .LZ, .NDV,
/// .DXY and .NODEP change nothing here.
///
/// Not run: another dimension than 2D; a level from a register for TEX
/// (.LB, .LL, .LC and the U ones) and TLD's .ULL; texel offsets (.AOFFI,
/// .UAOFFI); .UAI; a depth comparison (.DC); .SCR; the .F16 pair; an
/// eviction priority (what one does is not known); .MS, .UMS and .CL; a
/// fault predicate; a uniform register; registers past R254.
fn texture(op: *Op, in: *const Instr, name: []const u8, o: []const Operand) Error!void {
    const fetch = eql(name, "TLD");
    var k: usize = 0;
    var not_run = false;
    if (o.len > 0 and o[0] == .pred) {
        not_run = true;
        k = 1;
    }
    if (o.len < k + 5) return error.Syntax;
    for (o[k..][0..4]) |x| if (x != .gpr) return error.Syntax;
    op.kind = if (fetch) .tld else .tex;
    op.d[1] = .{ .file = .gpr, .n = o[k].gpr.n };
    op.d[0] = .{ .file = .gpr, .n = o[k + 1].gpr.n };
    op.s[0] = .{ .kind = .gpr, .n = o[k + 2].gpr.n };
    op.s[1] = .{ .kind = .gpr, .n = o[k + 3].gpr.n };
    // (a source is never RZ: nvdisasm prints such a word as invalid)
    if (op.s[0].n == RZ or op.s[1].n == RZ) return error.BadInstruction;
    k += 4;
    if (o[k] == .ugpr) {
        not_run = true;
        k += 1;
    }
    // (the dimension is a name, 2D, which sm120.sig leaves as text)
    if (k >= o.len or o[k] != .num) return error.Syntax;
    if (!eql(o[k].num, "2D")) not_run = true;
    k += 1;
    var mask: u64 = 0xf;
    if (k < o.len) {
        mask = try numValue(o[k], .int);
        k += 1;
    }
    if (k != o.len or mask > 0xf) return error.Syntax;
    op.lut[0] = @intCast(mask);
    // (without .B it is another opcode's form, with uniform registers)
    if (!in.has("B")) not_run = true;
    for (in.mods[0..in.n_mods]) |m| {
        const taken = eql(m, "B") or eql(m, "NODEP") or eql(m, "LZ") or
            (if (fetch) eql(m, "LL") else (eql(m, "NDV") or eql(m, "DXY")));
        if (!taken) not_run = true;
    }
    // (a fetch always names its level)
    if (fetch) {
        if (in.has("LL")) op.sub = 1 else if (!in.has("LZ") and !in.has("ULL")) return error.BadInstruction;
    }
    // Registers past R254: the coordinates' second, the level's, a result's.
    const channels: u8 = @popCount(op.lut[0]);
    if (op.s[0].n > RZ - 2 or (op.sub == 1 and op.s[1].n > RZ - 2)) not_run = true;
    if (op.d[0].n != RZ and @as(u32, op.d[0].n) + @min(channels, 2) > RZ) not_run = true;
    if (op.d[1].n != RZ and @as(u32, op.d[1].n) + (channels -| 2) > RZ) not_run = true;
    if (not_run) op.refuse = .form;
}

/// The registers a texture instruction that is run reads and writes: the
/// two coordinates, the handle (and TLD.LL's level), a result register a
/// channel of the mask; NAK's `decoupled` for each. sm120_sched counts
/// more (each source as four registers, each destination as one at least,
/// to stay on the safe side of every mode): these are among them, so what
/// it schedules passes here, and a hand-written program is not held to
/// registers its texture never touches.
fn textureUses(op: *const Op) sched.Uses {
    var u = sched.Uses{ .decoupled = true };
    const cat = @intFromEnum(lat.Reg.decoupled);
    const channels: u8 = @popCount(op.lut[0]);
    // (Rd1's first, as sm120_sched has them)
    for (0..channels -| 2) |k| add(&u, true, .gpr, op.d[1].n +| @as(u8, @intCast(k)), cat);
    for (0..@min(channels, 2)) |k| add(&u, true, .gpr, op.d[0].n +| @as(u8, @intCast(k)), cat);
    add(&u, false, .gpr, op.s[0].n, cat);
    add(&u, false, .gpr, op.s[0].n +| 1, cat);
    add(&u, false, .gpr, op.s[1].n, cat);
    if (op.kind == .tld and op.sub == 1) add(&u, false, .gpr, op.s[1].n +| 1, cat);
    if (op.guard.n != PT) add(&u, false, .pred, op.guard.n, @intFromEnum(lat.Pred.guard));
    return u;
}

/// Whether a register operand of `in`, with the registers sm120.regsAt
/// counts from it, runs past R254.
fn pastR254(in: *const Instr) bool {
    for (in.operands(), 0..) |x, i| {
        if (x == .gpr and x.gpr.n != RZ and @as(u32, x.gpr.n) + sm120.regsAt(in, i) > RZ) return true;
    }
    return false;
}

/// The highest general register among `u`'s.
fn topOf(u: *const sched.Uses) ?u8 {
    var top: ?u8 = null;
    for (u.dsts()) |x| {
        if (x.file == .gpr) top = if (top) |t| @max(t, x.n) else x.n;
    }
    for (u.srcs()) |x| {
        if (x.file == .gpr) top = if (top) |t| @max(t, x.n) else x.n;
    }
    return top;
}

// ── Latency categories where sm120_sched has none yet ───────────────────────

/// NAK's categories (sm120_instr_latencies.rs) for the forms this emulator
/// runs that sm120_sched.usesOf does not know yet. sm120_sched's take over
/// as it learns them. (It knows the graphics stages' already; they are
/// here too, with the same categories, so the two agree whichever answers:
/// the attribute instructions as memory, textures and KILL as decoupled.)
fn fallbackUses(op: *const Op, in: *const Instr) sched.Uses {
    const R = lat.Reg;
    const P = lat.Pred;
    const U = lat.Ureg;
    if ((op.kind == .tex or op.kind == .tld) and op.refuse == .none) return textureUses(op);
    var u = sched.Uses{};
    const dec = switch (op.kind) {
        .mufu, .f2f, .f2i, .frnd, .popc, .flo, .brev, .ldc, .s2r, .ldg, .stg, .ldl, .stl, .lds, .sts, .shfl, .bar, .exit, .bra => true,
        .ald, .ast, .ipa, .pixld, .kill, .tex, .tld => true,
        .i2f => !eql(in.op, "I2FP"),
        .cs2r => op.sub != 0xff,
        else => false,
    };
    u.decoupled = dec;
    u.branch = op.kind == .bra;
    u.ends = op.kind == .exit and op.guard.n == PT and !op.guard.not;
    const rcat: lat.Reg = switch (op.kind) {
        .lea, .lea_hi, .shf, .prmt, .iabs, .lop3, .iadd3, .iadd, .f2fp, .fsel, .r2ur, .cs2r => .alu,
        .sel, .imnmx, .mov, .fmnmx, .vote, .isetp, .fsetp => .dualalu,
        .imad, .imad_hi, .idp, .ffma, .fadd, .fmul => .fma,
        .imad_wide => .fma,
        .hadd2, .hmul2, .hfma2 => .fp16,
        .mov64, .iadd64 => .disp_64,
        .i2f => if (dec) .decoupled else .disp_64,
        .s2r, .ldg, .stg, .ldl, .stl, .lds, .sts, .shfl, .bar => .decoupled_agu,
        .ald, .ast, .ipa, .pixld => .decoupled_agu,
        else => .decoupled,
    };
    const pcat: lat.Pred = switch (op.kind) {
        .isetp, .fsetp, .imnmx, .fmnmx => .dualalu,
        .vote => .disp_dual_alu,
        .shfl, .ipa, .pixld => .decoupled,
        else => .coupled,
    };
    const ucat: lat.Ureg = if (op.uniform) .udp else .coupled;
    const width: u8 = switch (op.kind) {
        .mov64, .iadd64, .imad_wide => 2,
        .ldg, .stg, .ldl, .stl, .lds, .sts, .ldc, .ald, .ast => @max(1, op.size / 4),
        .cs2r => op.size / 4,
        .i2f, .f2i, .f2f => if (tyBits(op.ty[0]) == 64) 2 else 1,
        else => 1,
    };
    for (op.d, 0..) |d, k| {
        const wd: u8 = if (k == 0) width else 1;
        for (0..wd) |j| {
            const n = d.n +| @as(u8, @intCast(j));
            switch (d.file) {
                .gpr => add(&u, true, .gpr, n, @intFromEnum(rcat)),
                .ugpr => add(&u, true, .ugpr, n, @intFromEnum(switch (op.kind) {
                    .mov => U.umov,
                    .s2r, .ldc => U.to_ur,
                    .vote => U.voteu,
                    else => U.udp,
                })),
                .pred => add(&u, true, .pred, d.n, @intFromEnum(pcat)),
                else => {},
            }
        }
    }
    const swidth: u8 = if (op.kind == .stg or op.kind == .stl or op.kind == .sts or op.kind == .ast) width else if (op.kind == .iadd64 or op.kind == .f2i or op.kind == .f2f) (if (op.kind == .iadd64 or tyBits(op.ty[1]) == 64) 2 else 1) else 1;
    for (op.s) |s| {
        for (0..swidth) |j| {
            const n = s.n +| @as(u8, @intCast(j));
            switch (s.kind) {
                .gpr => add(&u, false, .gpr, n, @intFromEnum(rcat)),
                .ugpr => add(&u, false, .ugpr, n, @intFromEnum(ucat)),
                .pred => add(&u, false, .pred, s.n, @intFromEnum(P.coupled)),
                else => {},
            }
        }
        if (s.kind == .cbuf and s.index != RZ) add(&u, false, .gpr, s.index, @intFromEnum(rcat));
    }
    if (op.p.kind == .pred) add(&u, false, .pred, op.p.n, @intFromEnum(P.coupled));
    if (op.mem.base.kind == .gpr and op.mem.base.n != RZ) {
        add(&u, false, .gpr, op.mem.base.n, @intFromEnum(R.decoupled_agu));
        if (op.mem.wide) add(&u, false, .gpr, op.mem.base.n + 1, @intFromEnum(R.decoupled_agu));
    }
    for (in.operands()) |x| {
        if (x == .addr) if (x.addr.desc) |d| {
            add(&u, false, .ugpr, d, @intFromEnum(U.decoupled));
            add(&u, false, .ugpr, d + 1, @intFromEnum(U.decoupled));
        };
    }
    if (op.guard.n != PT) add(&u, false, .pred, op.guard.n, @intFromEnum(P.guard));
    return u;
}

fn add(u: *sched.Uses, dst: bool, file: sched.File, n: u8, cat: u8) void {
    if (n == RZ or (file == .pred and n >= PT)) return;
    if (dst) {
        if (u.n_dst == u.dst.len) return;
        u.dst[u.n_dst] = .{ .file = file, .n = n, .cat = cat };
        u.n_dst += 1;
    } else {
        if (u.n_src == u.src.len) return;
        u.src[u.n_src] = .{ .file = file, .n = n, .cat = cat };
        u.n_src += 1;
    }
}

// ── Running ─────────────────────────────────────────────────────────────────

const Ctx = struct {
    w: *Work,
    mem: *const Memory,
    l: *const Launch,
    stats: *Stats,
    cta: [3]u32,
    nthreads: u32,
    /// Bytes of local memory a thread.
    local_per: u32,
    steps: u64 = 0,
    /// The instruction issuing (for a fault's trap).
    pc: u32 = 0,
    /// A graphics stage's run (stageRun); null in a launch.
    stage: ?*const Stage = null,
};

/// Run a launch (load the kernel first).
pub fn run(w: *Work, mem: *const Memory, l: *const Launch, stats: *Stats) Error!void {
    w.trap = .{};
    w.begun = 0;
    const b = l.block;
    const nthreads = @as(u64, b[0]) * b[1] * b[2];
    if (nthreads == 0 or nthreads > MAX_THREADS or l.grid[0] == 0 or l.grid[1] == 0 or l.grid[2] == 0) return badLaunch(w);
    if (l.registers == 0 or l.registers > NREGS - 1) return badLaunch(w);
    if (w.top) |t| if (t >= l.registers) return badLaunch(w);
    // (registers are allocated 8 at a time; warps whole)
    const warps = (nthreads + WARP - 1) / WARP;
    if ((l.registers + 7) / 8 * 8 * warps * WARP > SM_REGISTERS) return badLaunch(w);
    if (l.shared_bytes > MAX_SHARED) return badLaunch(w);
    const local_per = @as(u64, l.local_low) + l.local_high;
    if (l.local_high > qmd.LOCAL_TOP or l.local_low > qmd.LOCAL_TOP - l.local_high or local_per * nthreads > LOCAL_POOL) return badLaunch(w);
    if (l.cta_stride == 0) return badLaunch(w);
    var c = Ctx{ .w = w, .mem = mem, .l = l, .stats = stats, .cta = undefined, .nthreads = @intCast(nthreads), .local_per = @intCast(local_per) };
    const total = @as(u64, l.grid[0]) * l.grid[1] * l.grid[2];
    var i = l.cta_first;
    while (i < total) : (i += l.cta_stride) {
        c.cta = .{ @intCast(i % l.grid[0]), @intCast((i / l.grid[0]) % l.grid[1]), @intCast(i / (@as(u64, l.grid[0]) * l.grid[1])) };
        try runCta(&c);
    }
}

fn badLaunch(w: *Work) Error {
    w.trap = .{ .what = .bad_launch };
    return error.BadLaunch;
}

/// `n` threads at the first instruction, their warps' histories empty:
/// the first `registers` registers of each garbage (POISON), predicates
/// clear, as the uniform registers and predicates of their warps.
fn startThreads(w: *Work, n: u32, registers: u32) void {
    const nw = (n + WARP - 1) / WARP;
    w.gen +%= 1;
    for (0..nw * WARP) |t| {
        w.st[t] = if (t < n) .run else .off;
        w.pc[t] = 0;
        w.preds[t] = 0;
        @memset(w.regs[t][0..registers], POISON);
        w.regs[t][RZ] = 0;
    }
    for (0..nw) |k| {
        @memset(&w.uregs[k], POISON);
        w.uregs[k][RZ] = 0;
        w.upreds[k] = 0;
        w.warps[k] = .{};
    }
}

fn runCta(c: *Ctx) Error!void {
    const w = c.w;
    const nw = (c.nthreads + WARP - 1) / WARP;
    c.stats.ctas += 1;
    c.stats.warps += nw;
    startThreads(w, c.nthreads, c.l.registers);
    @memset(w.shared[0..c.l.shared_bytes], 0xcd);
    @memset(w.local[0 .. @as(usize, c.local_per) * c.nthreads], 0xcd);
    while (true) {
        for (0..nw) |k| try runWarp(c, @intCast(if (w.reverse_warps) nw - 1 - k else k));
        // Every lane is at a barrier or done: release the barrier, the
        // warps in step.
        var at_bar = false;
        var id: ?u8 = null;
        for (0..c.nthreads) |t| {
            if (w.st[t] != .bar) continue;
            at_bar = true;
            const b = w.ops[w.pc[t]].sub;
            if (id != null and id.? != b) {
                w.trap = .{ .what = .divergence, .pc = @as(u64, w.pc[t]) * 16, .cta = c.cta, .thread = @intCast(t) };
                return error.Divergence;
            }
            id = b;
        }
        if (!at_bar) {
            // (a lane still waiting at a BSYNC whose other lanes never come)
            for (0..c.nthreads) |t| {
                if (w.st[t] == .bsync) {
                    w.trap = .{ .what = .divergence, .pc = @as(u64, w.pc[t]) * 16, .cta = c.cta, .thread = @intCast(t) };
                    return error.Divergence;
                }
            }
            break;
        }
        var latest: u32 = 0;
        for (0..nw) |k| latest = @max(latest, w.warps[k].cycle);
        for (0..nw) |k| w.warps[k].cycle = latest;
        for (0..c.nthreads) |t| {
            if (w.st[t] == .bar) {
                w.st[t] = .run;
                w.pc[t] += 1;
            }
        }
    }
    for (0..nw) |k| c.stats.cycles = @max(c.stats.cycles, w.warps[k].cycle);
}

fn runWarp(c: *Ctx, wi: u32) Error!void {
    const w = c.w;
    const base = wi * WARP;
    const end = @min(base + WARP, c.nthreads);
    var lanes: [WARP]u32 = undefined;
    while (true) {
        // The lowest pc among running lanes goes next; when none run,
        // lanes waiting at a warp-collective go (every lane that could
        // still reach it has).
        var min: u32 = NO_PC;
        for (base..end) |t| {
            if (w.st[t] == .run and w.pc[t] < min) min = w.pc[t];
        }
        var parked = false;
        if (min == NO_PC and releaseBsync(c, wi)) continue;
        if (min == NO_PC) {
            for (base..end) |t| {
                if (w.st[t] == .coll and w.pc[t] < min) min = w.pc[t];
            }
            if (min == NO_PC) return;
            parked = true;
        }
        var n: usize = 0;
        var others = false;
        for (base..end) |t| {
            if ((w.st[t] == .run or w.st[t] == .coll) and w.pc[t] == min) {
                lanes[n] = @intCast(t);
                n += 1;
            } else if (w.st[t] == .run) others = true;
        }
        if (min >= w.n_ops) {
            w.trap = .{ .what = .bad_instruction, .pc = @as(u64, min) * 16, .cta = c.cta, .thread = lanes[0] };
            return error.BadInstruction;
        }
        const op = &w.ops[min];
        if (isCollective(op.kind) and others and !parked) {
            for (lanes[0..n]) |t| w.st[t] = .coll;
            continue;
        }
        for (lanes[0..n]) |t| w.st[t] = .run;
        c.steps += 1;
        if (c.steps > w.max_steps) {
            w.trap = .{ .what = .timeout, .pc = @as(u64, min) * 16, .cta = c.cta };
            return error.Timeout;
        }
        try issue(c, wi, op, min, lanes[0..n]);
    }
}

/// The lanes waiting at a BSYNC go on when every lane of its barrier has
/// reached that BSYNC or exited (or was never running). True when some did.
fn releaseBsync(c: *Ctx, wi: u32) bool {
    const w = c.w;
    const base = wi * WARP;
    const end = @min(base + WARP, c.nthreads);
    var released = false;
    for (base..end) |t| {
        if (w.st[t] != .bsync) continue;
        const pc = w.pc[t];
        const mask = w.warps[wi].bmask[w.ops[pc].sub];
        var all = true;
        for (base..end) |u| {
            if ((mask >> @intCast(u - base)) & 1 == 0) continue;
            const ok = w.st[u] == .done or w.st[u] == .off or (w.st[u] == .bsync and w.pc[u] == pc);
            if (!ok) all = false;
        }
        if (!all) continue;
        for (base..end) |u| {
            if (w.st[u] == .bsync and w.pc[u] == pc) {
                w.st[u] = .run;
                w.pc[u] = pc + 1;
            }
        }
        released = true;
    }
    return released;
}

// ── Running a graphics stage ────────────────────────────────────────────────

/// Start `n` threads (1..MAX_THREADS) of a vertex or a pixel program (load
/// it first, as a kernel: load, loadText, loadAssembled, loadWords): each
/// at the first instruction, every register garbage (nothing is preloaded
/// in either stage: what a thread is given, it loads), predicates clear.
/// Then stageRun.
pub fn stageBegin(w: *Work, n: u32) Error!void {
    w.trap = .{};
    w.begun = 0;
    if (n == 0 or n > MAX_THREADS) return stageRefused(w, .threads);
    startThreads(w, n, NREGS - 1);
    w.begun = n;
}

/// Run the `n` threads stageBegin started to their EXIT, in warps of 32
/// (thread t is lane t % 32 of warp t / 32), as `s` describes their stage,
/// with the timing checks a launch gets (`w.check_hazards`, `w.strict`).
/// A vertex program's stored words are then in `s.out` and `s.stored`; a
/// pixel program's colour is in each thread's R0..R3 (`threadReg`), and
/// `s.killed` says whose is not to be written.
///
/// Checked beside what a launch checks, when hazards are:
///
/// - an EXIT issues with no scoreboard out (every one set was waited on
///   since: NAK makes each EXIT wait on all of them, so a store's read of
///   its registers is over before the thread is).
///
/// And with the Stage's header, at the end:
///
/// - a vertex thread stored every word the header says the program stores;
/// - a pixel thread that was not killed wrote every register the header
///   says holds an output: target t's declared channels (four registers a
///   target that has any, in order from R0), then the sample mask's and
///   the depth's. Written means not the garbage it started with, so a
///   program that computes exactly 0xdeadbeef there is refused wrongly.
///
/// Not checked: a register read before anything wrote it (it reads the
/// garbage); the register count the engine programs for the stage; whether
/// vectors start at the registers NAK aligns them to.
pub fn stageRun(w: *Work, mem: *const Memory, s: *const Stage, n: u32, stats: *Stats) Error!void {
    w.trap = .{};
    const begun = w.begun;
    w.begun = 0;
    if (n == 0 or n != begun) return stageRefused(w, .threads);
    const vertex = s.kind == .vertex;
    if (s.in.len < n) return stageRefused(w, .threads);
    if (vertex and (s.out.len < n or s.stored.len < n)) return stageRefused(w, .threads);
    if (!vertex and s.killed.len < n) return stageRefused(w, .threads);
    if (s.header) |h| {
        if (sph.stageOf(h) != s.kind) return stageRefused(w, .header_kind);
        // (NAK: without the position's w a pixel program traps)
        if (!vertex and !sph.bit(h, POSITION_W_READ)) return stageRefused(w, .header_kind);
    }
    if (vertex) {
        for (s.stored[0..n]) |*x| x.* = @splat(0);
    } else @memset(s.killed[0..n], false);
    // (constant buffers through a launch's fields; no shared or local memory)
    const l = Launch{ .block = .{ n, 1, 1 }, .shared_bytes = 0, .cbufs = s.cbufs };
    var c = Ctx{ .w = w, .mem = mem, .l = &l, .stats = stats, .cta = .{ 0, 0, 0 }, .nthreads = n, .local_per = 0, .stage = s };
    const nw = (n + WARP - 1) / WARP;
    stats.warps += nw;
    for (0..nw) |k| {
        const wi: u32 = @intCast(if (w.reverse_warps) nw - 1 - k else k);
        try runWarp(&c, wi);
        stats.cycles = @max(stats.cycles, w.warps[wi].cycle);
    }
    // (a stage has no barriers: a thread not done waits at a BSYNC for
    // lanes that never came)
    for (0..n) |t| {
        if (w.st[t] != .done) {
            w.trap = .{ .what = .divergence, .pc = @as(u64, w.pc[t]) * 16, .thread = @intCast(t) };
            return error.Divergence;
        }
    }
    if (s.header) |h| try stageEnded(&c, s, h, n);
}

/// Register `r` of thread `thread`, as the program last left it: after
/// stageRun, a pixel's red, green, blue and alpha are its R0..R3 (floats'
/// bits), a second target's R4..R7.
pub fn threadReg(w: *const Work, thread: u32, r: u8) u32 {
    return w.regs[thread][r];
}

/// A pixel header's bit for reading the position's w (sph.sig: x, y, z, w
/// are 188..191).
const POSITION_W_READ = 191;
/// A vertex header's bit for loading attribute word 0: word i is LOADS + i.
const LOADS = 160;
/// A vertex header's bit for storing attribute word 0: word i is STORES + i.
const STORES = 400;
/// A vertex header's bit that says no load follows a store.
const LOADS_BEFORE_STORES = 25;
/// A pixel header's bit that says the program discards pixels.
const KILLS_PIXELS = 15;

/// A stage's run refused before any of its instructions, for `why`.
fn stageRefused(w: *Work, why: Why) Error {
    w.trap = .{ .what = .bad_launch, .why = why };
    return error.BadLaunch;
}

/// An instruction refused where it issued, for `why`.
fn refuse(c: *Ctx, pc: u32, t: u32, what: What, why: Why, attr: u32) Error {
    c.w.trap = .{ .what = what, .why = why, .pc = @as(u64, pc) * 16, .cta = c.cta, .thread = t, .attr = @truncate(attr) };
    return switch (what) {
        .bad_instruction => error.BadInstruction,
        .header => error.HeaderMismatch,
        else => error.Unsupported,
    };
}

/// A program at odds with its header over attribute word `word`.
fn mismatch(c: *Ctx, t: u32, why: Why, word: u32) Error {
    return refuse(c, c.pc, t, .header, why, word * 4);
}

/// Whether `op` may issue where the warp is: a graphics stage's own only
/// in a stage, and in the stage they belong to (ALD and AST are a vertex
/// program's; IPA, PIXLD and KILL a pixel program's: NAK's rule, and TEX
/// and TLD either's); in a stage no barrier, no shared memory, none of
/// the CTA's or the grid's special registers; no local memory (a Stage
/// has none), no texture instruction without its callback, no constant
/// buffer past the Stage's.
fn belongs(c: *Ctx, op: *const Op, pc: u32, t: u32) Error!void {
    const s = c.stage orelse return refuse(c, pc, t, .bad_instruction, .stage_only, 0);
    switch (op.kind) {
        .bar, .lds, .sts, .atoms => return refuse(c, pc, t, .bad_instruction, .compute_only, 0),
        // (SR_TID, SR_CTAID and the CTA's place in its cluster)
        .s2r, .cs2r => if ((op.sub >= 0x20 and op.sub <= 0x27) or op.sub == 0x88) return refuse(c, pc, t, .bad_instruction, .compute_only, 0),
        .ldl, .stl => return refuse(c, pc, t, .unsupported, .no_data, 0),
        .ald, .ast => if (s.kind != .vertex) return refuse(c, pc, t, .bad_instruction, .wrong_stage, 0),
        .ipa, .pixld, .kill => if (s.kind != .pixel) return refuse(c, pc, t, .bad_instruction, .wrong_stage, 0),
        .tex => if (s.sample == null and op.refuse == .none) return refuse(c, pc, t, .unsupported, .no_callback, 0),
        .tld => if (s.fetch == null and op.refuse == .none) return refuse(c, pc, t, .unsupported, .no_callback, 0),
        else => {},
    }
    for (op.s) |x| {
        if (x.kind == .cbuf and x.bank >= qmd.CBUFS) return refuse(c, pc, t, .unsupported, .form, 0);
    }
}

/// How a pixel program's header says attribute word `i` is read.
const Reads = enum {
    /// Not at all.
    none,
    /// A system value's word, a bit each in the header: nothing there says
    /// how it is carried (the position's, the point's coordinates, the
    /// layer).
    word,
    /// The provoking vertex's value.
    flat,
    /// Carried across the triangle, in perspective or linearly.
    carried,
};

/// The header's maps are sph.sig's and NAK's: system values A and B a bit
/// a word from 160 (the position's x, y, z, w at 188..191), generic vector
/// n's component c two bits from 192 + 8n + 2c, system values C a bit a
/// word from 464. The fixed-function colours (0x280..0x2bf) count as not
/// read: NAK never reads them, and how the header's 16 bits for them map
/// to their words is not in what was read.
fn pixelReads(h: *const [sph.WORDS]u32, i: u32) Reads {
    if (i < 32) return if (sph.bit(h, 160 + i)) .word else .none;
    if (i < 160) return switch (sph.interpOf(h, (i - 32) / 4, (i - 32) % 4)) {
        .unused => .none,
        .constant => .flat,
        .perspective, .linear => .carried,
    };
    if (i < 176) return .none;
    return if (sph.bit(h, 464 + (i - 176))) .word else .none;
}

/// One thread's turn at a graphics stage's instruction (`stageOp` and
/// `texture` say what each form is; `belongs` let it issue):
///
/// - ALD: the thread's `in` words into the registers. With a header, each
///   word must be one it says the program loads, and when it says no load
///   follows a store (the bit that lets the engine keep inputs and outputs
///   in one space), none may.
/// - AST: the registers into the thread's `out` words, and their bits in
///   `stored`. With a header, each word must be one it says the program
///   stores, inside the range of stored words it gives.
/// - IPA: the thread's `in` word into the register. With a header, the
///   word must be one it says the program reads, flat for .CONSTANT and
///   carried for .PASS where the header says which.
/// - KILL: the thread's `killed` set. The thread runs on: NAK treats the
///   instruction as a demotion to a helper pixel, not an end ("execution
///   continues after KILL"), so a program that means to stop branches to
///   its EXIT. With a header, it must say the program discards pixels.
/// - TEX, TLD: the Stage's callback's four floats into the registers the
///   mask names (see `texture`). The sources are read first, so a result
///   may land on them.
fn stageLane(c: *Ctx, wi: u32, t: u32, op: *const Op) Error!void {
    const s = c.stage.?;
    const w = c.w;
    const first: u32 = @intCast(@divTrunc(op.mem.offset, 4));
    const words: u32 = op.size / 4;
    switch (op.kind) {
        .ald => {
            if (s.header) |h| {
                for (0..words) |k| {
                    const i = first + @as(u32, @intCast(k));
                    if (!sph.bit(h, LOADS + i)) return mismatch(c, t, .load_undeclared, i);
                }
                if (sph.bit(h, LOADS_BEFORE_STORES)) {
                    for (s.stored[t]) |bits| if (bits != 0) return mismatch(c, t, .load_after_store, first);
                }
            }
            for (0..words) |k| put(c, wi, t, .{ .file = .gpr, .n = op.d[0].n +| @as(u8, @intCast(k)) }, s.in[t][first + k]);
        },
        .ast => {
            if (s.header) |h| {
                // (STORE_REQ_START and END: bits 140..147 and 152..159)
                const lo = (h[4] >> 12) & 0xff;
                const hi = (h[4] >> 24) & 0xff;
                for (0..words) |k| {
                    const i = first + @as(u32, @intCast(k));
                    if (!sph.bit(h, STORES + i) or i < lo or i > hi) return mismatch(c, t, .store_undeclared, i);
                }
            }
            for (0..words) |k| {
                const i = first + k;
                const r: u8 = if (op.s[0].n == RZ) RZ else op.s[0].n + @as(u8, @intCast(k));
                s.out[t][i] = w.regs[t][r];
                s.stored[t][i / 32] |= @as(u32, 1) << @intCast(i % 32);
            }
        },
        .ipa => {
            // (the facing: flat, as NAK reads it; no header bit for it)
            if (first == sph.ATTR_FRONT_FACE / 4) {
                if (op.sub != 1) return mismatch(c, t, .interpolation, first);
                if (t >= s.front.len) return refuse(c, c.pc, t, .unsupported, .no_data, sph.ATTR_FRONT_FACE);
                put(c, wi, t, op.d[0], if (s.front[t]) 0xffff_ffff else 0);
                return;
            }
            if (s.header) |h| switch (pixelReads(h, first)) {
                .none => return mismatch(c, t, .load_undeclared, first),
                .word => {},
                .flat => if (op.sub != 1) return mismatch(c, t, .interpolation, first),
                .carried => if (op.sub != 0) return mismatch(c, t, .interpolation, first),
            };
            put(c, wi, t, op.d[0], s.in[t][first]);
        },
        .kill => {
            if (s.header) |h| {
                if (!sph.bit(h, KILLS_PIXELS)) return refuse(c, c.pc, t, .header, .kill_undeclared, 0);
            }
            s.killed[t] = true;
        },
        .tex, .tld => {
            const handle = w.regs[t][op.s[1].n];
            const x = w.regs[t][op.s[0].n];
            const y = w.regs[t][op.s[0].n + 1];
            var rgba: [4]f32 = undefined;
            if (op.kind == .tex) {
                rgba = s.sample.?(s.ctx, handle, f32of(x), f32of(y)) catch |e| return callbackFailed(c, t, e);
            } else {
                const xi: i32 = @bitCast(x);
                const yi: i32 = @bitCast(y);
                const lod: i32 = if (op.sub == 1) @bitCast(w.regs[t][op.s[1].n + 1]) else 0;
                rgba = s.fetch.?(s.ctx, handle, xi, yi, lod) catch |e| return callbackFailed(c, t, e);
            }
            var k: u8 = 0;
            for (rgba, 0..) |v, ch| {
                if ((op.lut[0] >> @intCast(ch)) & 1 == 0) continue;
                const base = if (k < 2) op.d[0].n else op.d[1].n;
                if (base != RZ) put(c, wi, t, .{ .file = .gpr, .n = base + (k & 1) }, @bitCast(v));
                k += 1;
            }
        },
        else => return error.Unsupported,
    }
}

/// The engine's callback failed: its error, with the instruction's place
/// in the trap unless the callback left one.
fn callbackFailed(c: *Ctx, t: u32, e: Error) Error {
    if (c.w.trap.what == .none) {
        c.w.trap = .{ .what = if (e == error.Fault) .fault else .unsupported, .pc = @as(u64, c.pc) * 16, .cta = c.cta, .thread = t };
    }
    return e;
}

/// What the header says a stage's threads have done by their EXIT (see
/// stageRun).
fn stageEnded(c: *Ctx, s: *const Stage, h: *const [sph.WORDS]u32, n: u32) Error!void {
    const w = c.w;
    if (s.kind == .vertex) {
        var want: [ATTR_WORDS / 32]u32 = @splat(0);
        for (0..ATTR_WORDS) |i| {
            if (sph.bit(h, STORES + @as(u32, @intCast(i)))) want[i / 32] |= @as(u32, 1) << @intCast(i % 32);
        }
        for (0..n) |t| {
            for (want, s.stored[t], 0..) |wanted, got, k| {
                const missing = wanted & ~got;
                if (missing == 0) continue;
                c.pc = w.pc[t];
                return mismatch(c, @intCast(t), .store_missing, @as(u32, @intCast(k)) * 32 + @ctz(missing));
            }
        }
        return;
    }
    // The outputs' registers, in the order NAK leaves them (the header's
    // target map is bits 576 on, four a target; then the sample mask's bit
    // and the depth's): four registers for each target that has a channel
    // written, then one for the sample mask when it or the depth is
    // written, then one for the depth.
    var outputs: [34]bool = @splat(false);
    var r: usize = 0;
    for (0..8) |target| {
        const mask = (h[18] >> @intCast(4 * target)) & 0xf;
        if (mask == 0) continue;
        for (0..4) |ch| outputs[r + ch] = (mask >> @intCast(ch)) & 1 != 0;
        r += 4;
    }
    outputs[r] = sph.bit(h, 608);
    outputs[r + 1] = sph.bit(h, 609);
    for (0..n) |t| {
        if (s.killed[t]) continue;
        for (outputs, 0..) |declared, reg| {
            if (!declared or w.regs[t][reg] != POISON) continue;
            w.trap = .{ .what = .header, .why = .colour_missing, .pc = @as(u64, w.pc[t]) * 16, .thread = @intCast(t), .reg = @intCast(reg) };
            return error.HeaderMismatch;
        }
    }
}

// ── Issuing ─────────────────────────────────────────────────────────────────

fn issue(c: *Ctx, wi: u32, op: *const Op, pc: u32, lanes: []const u32) Error!void {
    const w = c.w;
    switch (op.kind) {
        .invalid, .unsupported => {
            w.trap = .{ .what = if (op.kind == .invalid) .bad_instruction else .unsupported, .pc = @as(u64, pc) * 16, .cta = c.cta, .thread = lanes[0] };
            return if (op.kind == .invalid) error.BadInstruction else error.Unsupported;
        },
        else => {},
    }
    if (c.stage != null or isStageKind(op.kind)) {
        try belongs(c, op, pc, lanes[0]);
        if (op.refuse != .none) return refuse(c, pc, lanes[0], .unsupported, op.refuse, @intCast(op.mem.offset));
    }
    c.pc = pc;
    if (w.check_hazards) try timing(c, wi, op, pc) else w.warps[wi].cycle +%= op.control.stall;
    c.stats.instructions += 1;
    var on: [WARP]u32 = undefined;
    var m: usize = 0;
    for (lanes) |t| {
        if (guardOn(w, t, op.guard)) {
            on[m] = t;
            m += 1;
        }
    }
    c.stats.thread_instructions += m;
    switch (op.kind) {
        .exit => {
            for (lanes) |t| {
                if (guardOn(w, t, op.guard)) w.st[t] = .done else w.pc[t] = pc + 1;
            }
            return;
        },
        .bra => {
            for (lanes) |t| w.pc[t] = if (guardOn(w, t, op.guard)) op.target else pc + 1;
            return;
        },
        .bar => {
            for (lanes) |t| {
                if (guardOn(w, t, op.guard)) w.st[t] = .bar else w.pc[t] = pc + 1;
            }
            return;
        },
        .bssy => {
            var mask: u32 = 0;
            for (on[0..m]) |t| mask |= @as(u32, 1) << @intCast(t - wi * WARP);
            w.warps[wi].bmask[op.sub] = mask;
        },
        .bsync => {
            for (lanes) |t| {
                if (guardOn(w, t, op.guard)) w.st[t] = .bsync else w.pc[t] = pc + 1;
            }
            return;
        },
        .shfl => try shfl(c, wi, op, on[0..m]),
        .vote => vote(c, wi, op, on[0..m]),
        .r2ur => if (m > 0) put(c, wi, on[0], op.d[0], c.w.regs[on[0]][op.s[0].n]),
        else => {
            if (op.uniform) {
                if (m > 0) try lane(c, wi, on[0], op);
            } else for (on[0..m]) |t| try lane(c, wi, t, op);
        },
    }
    for (lanes) |t| w.pc[t] = pc + 1;
}

fn guardOn(w: *const Work, t: u32, g: sm120.Pred) bool {
    if (g.n == PT) return !g.not;
    return ((w.preds[t] >> g.n) & 1 != 0) != g.not;
}

// ── The control fields, checked ─────────────────────────────────────────────

fn track(c: *Ctx, wi: u32, file: sched.File, n: u8) *Track {
    const t = switch (file) {
        .gpr => &c.w.tr_gpr[wi][n],
        .ugpr => &c.w.tr_ugpr[wi][n],
        .pred => &c.w.tr_pred[wi][n & 7],
        .upred => &c.w.tr_upred[wi][n & 7],
    };
    if (t.gen != c.w.gen) t.* = .{ .gen = c.w.gen };
    return t;
}

fn entry(file: sched.File, kind: sched.Kind, second: u8, first: u8) u8 {
    return switch (file) {
        .gpr => switch (kind) {
            .raw => lat.reg_raw[second][first],
            .war => lat.reg_war[second][first],
            .waw => lat.reg_waw[second][first],
        },
        .pred => switch (kind) {
            .raw => lat.pred_raw[second][first],
            .war => lat.pred_war[second][first],
            .waw => lat.pred_waw[second][first],
        },
        .ugpr => switch (kind) {
            .raw => lat.ureg_raw[second][first],
            .war => lat.ureg_war[second][first],
            .waw => lat.ureg_waw[second][first],
        },
        .upred => switch (kind) {
            .raw => lat.upred_raw[second][first],
            .war => lat.upred_war[second][first],
            .waw => lat.upred_waw[second][first],
        },
    };
}

/// What a pair needs: NVIDIA's cycles as the tables have them, or (strict)
/// sm120_sched's, with NAK's padding.
fn need(w: *const Work, kind: sched.Kind, first: sched.Use, dec: bool, second: sched.Use) sched.Need {
    if (w.strict) return sched.need(kind, first, dec, second);
    const e = entry(first.file, kind, second.cat, first.cat);
    if (e == lat.N) return .{ .cycles = WORST, .sb = dec };
    return .{ .cycles = e & ~lat.SB, .sb = e & lat.SB != 0 };
}

fn hazard(c: *Ctx, kind: HazardKind, pc: u32, u: sched.Use, other: u32, nd: u32, have: u32, sb: bool) Error {
    c.w.trap = .{ .what = .hazard, .pc = @as(u64, pc) * 16, .hazard = kind, .file = u.file, .reg = u.n, .other_pc = @as(u64, other) * 16, .need = nd, .have = have, .scoreboard = sb, .cta = c.cta };
    return error.Hazard;
}

fn waited(ws: *const WarpT, bar: u3, epoch: u32) bool {
    return bar != NONE and ws.epoch[bar] != epoch;
}

/// A variable-latency instruction's read of a register: done once its own
/// scoreboard (for its reads, or its result) was waited on, or (the
/// load/store pipe runs in order) a later one's of the pipe was.
fn readDone(ws: *const WarpT, d: DRead, q: usize, strict: bool) bool {
    if (d.pc == NO_PC) return true;
    if (waited(ws, d.rbar, d.rep) or waited(ws, d.wbar, d.wep)) return true;
    return !strict and q == 0 and d.seq <= ws.lsu_done;
}

fn timing(c: *Ctx, wi: u32, op: *const Op, pc: u32) Error!void {
    const w = c.w;
    const ws = &w.warps[wi];
    const now = ws.cycle;
    const ctl = op.control;
    const dec = op.uses.decoupled;
    // The waits first.
    for (0..BARS) |k| {
        if (ctl.wait & (@as(u6, 1) << @intCast(k)) == 0 or ws.count[k] == 0) continue;
        if (now -% ws.last[k] < SB_SET) {
            w.trap = .{ .what = .hazard, .pc = @as(u64, pc) * 16, .hazard = .wait_too_soon, .other_pc = @as(u64, ws.last_pc[k]) * 16, .need = SB_SET, .have = now -% ws.last[k], .cta = c.cta };
            return error.Hazard;
        }
        ws.epoch[k] +%= 1;
        ws.count[k] = 0;
        ws.lsu_done = @max(ws.lsu_done, ws.lsu_seq[k]);
        ws.lsu_seq[k] = 0;
    }
    // A stage's program ends with nothing out (after its EXIT's own waits,
    // before the scoreboards a control field written for it may set).
    if (op.kind == .exit and c.stage != null) {
        for (0..BARS) |k| {
            if (ws.count[k] == 0) continue;
            w.trap = .{ .what = .hazard, .pc = @as(u64, pc) * 16, .hazard = .exit_pending, .reg = @intCast(k), .other_pc = @as(u64, ws.last_pc[k]) * 16, .scoreboard = true, .cta = c.cta };
            return error.Hazard;
        }
    }
    // Reads after writes.
    for (op.uses.srcs()) |u| {
        c.stats.hazard_checks += 1;
        const t = track(c, wi, u.file, u.n);
        if (t.w_pc == NO_PC) continue;
        const nd = need(w, .raw, .{ .file = u.file, .n = u.n, .cat = t.w_cat }, t.w_dec, u);
        const have = now -% t.w_cycle;
        if (nd.sb and !waited(ws, t.w_bar, t.w_epoch)) return hazard(c, .raw, pc, u, t.w_pc, nd.cycles, have, true);
        if (have < nd.cycles) return hazard(c, .raw, pc, u, t.w_pc, nd.cycles, have, false);
    }
    // Writes after reads and writes.
    for (op.uses.dsts()) |u| {
        c.stats.hazard_checks += 1;
        const t = track(c, wi, u.file, u.n);
        if (t.r_pc != NO_PC) {
            const nd = need(w, .war, .{ .file = u.file, .n = u.n, .cat = t.r_cat }, false, u);
            const have = now -% t.r_cycle;
            if (have < nd.cycles) return hazard(c, .war, pc, u, t.r_pc, nd.cycles, have, false);
        }
        for (t.d, 0..) |d, q| {
            if (d.pc == NO_PC) continue;
            // (the load/store pipe in order: a later one's result lands
            // after an earlier one read its registers)
            if (q == 0 and op.lsu and dec and !w.strict) continue;
            const nd = need(w, .war, .{ .file = u.file, .n = u.n, .cat = d.cat }, true, u);
            if (nd.sb and !readDone(ws, d, q, w.strict)) return hazard(c, .war, pc, u, d.pc, nd.cycles, now -% d.cycle, true);
            if (now -% d.cycle < nd.cycles) return hazard(c, .war, pc, u, d.pc, nd.cycles, now -% d.cycle, false);
        }
        if (t.w_pc != NO_PC) {
            const nd = need(w, .waw, .{ .file = u.file, .n = u.n, .cat = t.w_cat }, t.w_dec, u);
            const have = now -% t.w_cycle;
            if (nd.sb and !waited(ws, t.w_bar, t.w_epoch)) return hazard(c, .waw, pc, u, t.w_pc, nd.cycles, have, true);
            if (have < nd.cycles) return hazard(c, .waw, pc, u, t.w_pc, nd.cycles, have, false);
        }
    }
    // This instruction's scoreboards.
    ws.seq +%= 1;
    const seq = ws.seq;
    for ([_]u3{ ctl.read, ctl.write }) |b| {
        if (b == NONE) continue;
        ws.count[b] += 1;
        ws.last[b] = now;
        ws.last_pc[b] = pc;
        if (op.lsu) ws.lsu_seq[b] = @max(ws.lsu_seq[b], seq);
    }
    // What it read and wrote, for the instructions after it.
    for (op.uses.srcs()) |u| {
        const t = track(c, wi, u.file, u.n);
        if (dec and u.file != .pred) {
            const q: usize = if (op.lsu) 0 else 1;
            t.d[q] = .{
                .pc = pc,
                .cycle = now,
                .seq = seq,
                .cat = u.cat,
                .rbar = ctl.read,
                .rep = if (ctl.read != NONE) ws.epoch[ctl.read] else 0,
                .wbar = ctl.write,
                .wep = if (ctl.write != NONE) ws.epoch[ctl.write] else 0,
            };
        } else {
            t.r_pc = pc;
            t.r_cycle = now;
            t.r_cat = u.cat;
        }
    }
    for (op.uses.dsts()) |u| {
        const t = track(c, wi, u.file, u.n);
        t.w_pc = pc;
        t.w_cycle = now;
        t.w_cat = u.cat;
        t.w_dec = dec;
        t.w_lsu = op.lsu;
        t.w_bar = ctl.write;
        t.w_epoch = if (ctl.write != NONE) ws.epoch[ctl.write] else 0;
        t.r_pc = NO_PC;
        t.d = .{ .{}, .{} };
    }
    ws.cycle = now +% ctl.stall;
}

// ── Values ──────────────────────────────────────────────────────────────────

fn cbufRead(c: *const Ctx, bank: u8, off: u64, n: usize) u64 {
    const cb = c.l.cbufs[bank & 7];
    if (off > cb.len or n > cb.len - off) return 0;
    var v: u64 = 0;
    for (0..n) |i| v |= @as(u64, cb[@intCast(off + i)]) << @intCast(8 * i);
    return v;
}

/// A source's 32 bits, before its modifiers.
fn raw32(c: *const Ctx, wi: u32, t: u32, s: Src) u32 {
    return switch (s.kind) {
        .gpr => c.w.regs[t][s.n],
        .ugpr => c.w.uregs[wi][s.n],
        .imm => @truncate(s.imm),
        .cbuf => @truncate(cbufRead(c, s.bank, s.imm +% (if (s.index != RZ) c.w.regs[t][s.index] else 0), 4)),
        else => 0,
    };
}

fn raw64(c: *const Ctx, wi: u32, t: u32, s: Src) u64 {
    return switch (s.kind) {
        .gpr => if (s.n == RZ) 0 else @as(u64, c.w.regs[t][s.n + 1]) << 32 | c.w.regs[t][s.n],
        .ugpr => if (s.n == RZ) 0 else @as(u64, c.w.uregs[wi][s.n + 1]) << 32 | c.w.uregs[wi][s.n],
        .imm => s.imm,
        .cbuf => cbufRead(c, s.bank, s.imm, 8),
        else => 0,
    };
}

fn int(c: *const Ctx, wi: u32, t: u32, s: Src) u32 {
    const v = raw32(c, wi, t, s);
    return if (s.neg) 0 -% v else v;
}

fn int64(c: *const Ctx, wi: u32, t: u32, s: Src) u64 {
    const v = raw64(c, wi, t, s);
    return if (s.neg) 0 -% v else v;
}

/// A float source's bits with its |..| and -.
fn fbits(c: *const Ctx, wi: u32, t: u32, s: Src) u32 {
    var b = raw32(c, wi, t, s);
    if (s.abs) b &= 0x7fff_ffff;
    if (s.neg) b ^= 0x8000_0000;
    return b;
}

fn f32of(b: u32) f32 {
    return @bitCast(b);
}

fn flush(x: f32) f32 {
    const b: u32 = @bitCast(x);
    if (b & 0x7f80_0000 == 0) return @bitCast(b & 0x8000_0000);
    return x;
}

fn flt(c: *const Ctx, wi: u32, t: u32, s: Src, ftz: bool) f32 {
    const x = f32of(fbits(c, wi, t, s));
    return if (ftz) flush(x) else x;
}

fn predOn(c: *const Ctx, wi: u32, t: u32, p: Src) bool {
    const v = switch (p.kind) {
        .pred => p.n == PT or (c.w.preds[t] >> @intCast(p.n)) & 1 != 0,
        .upred => p.n == PT or (c.w.upreds[wi] >> @intCast(p.n)) & 1 != 0,
        else => true,
    };
    return v != p.not;
}

fn put(c: *Ctx, wi: u32, t: u32, d: Dst, v: u32) void {
    switch (d.file) {
        .gpr => if (d.n != RZ) {
            c.w.regs[t][d.n] = v;
        },
        .ugpr => if (d.n != RZ) {
            c.w.uregs[wi][d.n] = v;
        },
        .pred => if (d.n < PT) {
            if (v != 0) c.w.preds[t] |= @as(u8, 1) << @intCast(d.n) else c.w.preds[t] &= ~(@as(u8, 1) << @intCast(d.n));
        },
        .upred => if (d.n < PT) {
            if (v != 0) c.w.upreds[wi] |= @as(u8, 1) << @intCast(d.n) else c.w.upreds[wi] &= ~(@as(u8, 1) << @intCast(d.n));
        },
        .none => {},
    }
}

fn put64(c: *Ctx, wi: u32, t: u32, d: Dst, v: u64) void {
    if (d.n == RZ) return;
    put(c, wi, t, d, @truncate(v));
    put(c, wi, t, .{ .file = d.file, .n = d.n + 1 }, @truncate(v >> 32));
}

const NAN32: u32 = 0x7fff_ffff;
const NAN16: u16 = 0x7fff;

/// A float result as the GPU leaves it: NaN canonical, .SAT, .FTZ.
fn fresult(x: f32, op: *const Op) u32 {
    if (std.math.isNan(x)) return if (op.sat) 0 else NAN32;
    var y = x;
    if (op.sat) y = std.math.clamp(y, 0.0, 1.0);
    if (op.ftz) y = flush(y);
    return @bitCast(y);
}

// ── Rounding ────────────────────────────────────────────────────────────────

/// `hi + lo` (an exact value, lo far below hi's last bit) rounded to T.
fn roundTo(comptime T: type, hi: f64, lo: f64, r: Round) T {
    const n: T = @floatCast(hi);
    if (r == .rn or std.math.isNan(hi) or std.math.isInf(hi)) return n;
    const back: f64 = n;
    // (the sign of exact - n)
    const diff: f64 = if (std.math.isInf(back)) -back else (hi - back) + lo;
    if (diff == 0) return n;
    return switch (r) {
        .rz => if ((back > 0 and diff < 0) or (back < 0 and diff > 0)) std.math.nextAfter(T, n, 0) else n,
        .rm => if (diff < 0) std.math.nextAfter(T, n, -std.math.inf(T)) else n,
        .rp => if (diff > 0) std.math.nextAfter(T, n, std.math.inf(T)) else n,
        .rn => n,
    };
}

/// a + b exactly, as a rounded sum and its error (Knuth's TwoSum).
fn twoSum(a: f64, b: f64) [2]f64 {
    const s = a + b;
    const bb = s - a;
    return .{ s, (a - (s - bb)) + (b - bb) };
}

fn fadd(a: f32, b: f32, r: Round) f32 {
    if (r == .rn) return a + b;
    const s = twoSum(a, b);
    return roundTo(f32, s[0], s[1], r);
}

fn fmul(a: f32, b: f32, r: Round) f32 {
    if (r == .rn) return a * b;
    return roundTo(f32, @as(f64, a) * b, 0, r);
}

fn ffma(a: f32, b: f32, c: f32, r: Round) f32 {
    if (r == .rn) return @mulAdd(f32, a, b, c);
    // (a * b is exact in f64)
    const s = twoSum(@as(f64, a) * b, c);
    return roundTo(f32, s[0], s[1], r);
}

fn roundInt(x: f64, r: Round) f64 {
    return switch (r) {
        .rz => @trunc(x),
        .rm => @floor(x),
        .rp => @ceil(x),
        .rn => blk: {
            const t = @round(x);
            break :blk if (@abs(x - @trunc(x)) == 0.5) 2.0 * @round(x / 2.0) else t;
        },
    };
}

fn h2f(h: u16) f32 {
    return @floatCast(@as(f16, @bitCast(h)));
}

fn toF16(x: f64, r: Round) u16 {
    if (std.math.isNan(x)) return NAN16;
    return @bitCast(roundTo(f16, x, 0, r));
}

fn toBf16(x: f32, r: Round) u16 {
    const b: u32 = @bitCast(x);
    if (std.math.isNan(x)) return NAN16;
    const low = b & 0xffff;
    const neg = b >> 31 != 0;
    return switch (r) {
        .rn => @truncate((b +% (0x7fff + ((b >> 16) & 1))) >> 16),
        .rz => @truncate(b >> 16),
        .rm => @truncate((b >> 16) + @intFromBool(neg and low != 0)),
        .rp => @truncate((b >> 16) + @intFromBool(!neg and low != 0)),
    };
}

/// A float of type `t` from its bits (f64 from a pair).
fn floatIn(c: *const Ctx, wi: u32, t: u32, s: Src, ty: Ty, ftz: bool) f64 {
    return switch (ty) {
        .f64 => blk: {
            var b = raw64(c, wi, t, s);
            if (s.abs) b &= 0x7fff_ffff_ffff_ffff;
            if (s.neg) b ^= 0x8000_0000_0000_0000;
            break :blk @as(f64, @bitCast(b));
        },
        .f16 => blk: {
            var h: u16 = @truncate(raw32(c, wi, t, s) >> (if (s.swz == 2) 16 else 0));
            if (s.abs) h &= 0x7fff;
            if (s.neg) h ^= 0x8000;
            break :blk h2f(h);
        },
        .bf16 => blk: {
            var h: u32 = (raw32(c, wi, t, s) & 0xffff) << 16;
            if (s.abs) h &= 0x7fff_ffff;
            if (s.neg) h ^= 0x8000_0000;
            break :blk f32of(h);
        },
        else => flt(c, wi, t, s, ftz),
    };
}

// ── One lane ────────────────────────────────────────────────────────────────

fn lut3(l: u8, a: u32, b: u32, c: u32) u32 {
    var r: u32 = 0;
    inline for (0..8) |i| {
        if ((l >> i) & 1 != 0) r |= (if (i & 4 != 0) a else ~a) & (if (i & 2 != 0) b else ~b) & (if (i & 1 != 0) c else ~c);
    }
    return r;
}

fn icmp(op: u8, a: u32, b: u32, unsigned: bool) bool {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return switch (op) {
        0 => false,
        1 => if (unsigned) a < b else sa < sb,
        2 => a == b,
        3 => if (unsigned) a <= b else sa <= sb,
        4 => if (unsigned) a > b else sa > sb,
        5 => a != b,
        6 => if (unsigned) a >= b else sa >= sb,
        else => true,
    };
}

fn fcmp(op: u8, a: f32, b: f32) bool {
    const un = std.math.isNan(a) or std.math.isNan(b);
    return switch (op) {
        0 => false,
        1 => !un and a < b,
        2 => !un and a == b,
        3 => !un and a <= b,
        4 => !un and a > b,
        5 => !un and a != b,
        6 => !un and a >= b,
        7 => !un,
        8 => un,
        9 => un or a < b,
        10 => un or a == b,
        11 => un or a <= b,
        12 => un or a > b,
        13 => un or a != b,
        14 => un or a >= b,
        else => true,
    };
}

fn boolOp(op: u8, a: bool, b: bool) bool {
    return switch (op) {
        0 => a and b,
        1 => a or b,
        else => a != b,
    };
}

/// IEEE minNum / maxNum, -0 below +0.
fn fminmax(a: f32, b: f32, min: bool) f32 {
    if (std.math.isNan(a)) return if (std.math.isNan(b)) f32of(NAN32) else b;
    if (std.math.isNan(b)) return a;
    if (a == b) {
        const neg_a = @as(u32, @bitCast(a)) >> 31 != 0;
        return if (neg_a == min) a else b;
    }
    return if ((a < b) == min) a else b;
}

fn shf(op: *const Op, lo: u32, s: u32, hi: u32) u32 {
    const bits: u32 = if (tyBits(op.ty[0]) == 64) 64 else 32;
    const sh: u32 = if (op.wrap) s & (bits - 1) else @min(s, bits);
    const v: u64 = @as(u64, hi) << 32 | lo;
    const r: u64 = if (op.left)
        (if (sh >= 64) 0 else v << @intCast(sh))
    else if (isSigned(op.ty[0]))
        @bitCast(@as(i64, @bitCast(v)) >> @intCast(@min(sh, 63)))
    else
        (if (sh >= 64) 0 else v >> @intCast(sh));
    return @truncate(if (op.hi) r >> 32 else r);
}

fn prmt(a: u32, sel: u32, b: u32) u32 {
    const bytes: u64 = @as(u64, b) << 32 | a;
    var r: u32 = 0;
    for (0..4) |i| {
        const s: u32 = (sel >> @intCast(4 * i)) & 0xf;
        var x: u32 = @truncate(bytes >> @intCast(8 * (s & 7)));
        x &= 0xff;
        if (s & 8 != 0) x = if (x & 0x80 != 0) 0xff else 0;
        r |= x << @intCast(8 * i);
    }
    return r;
}

fn flo(v: u32, signed: bool, sh: bool) u32 {
    var x = v;
    if (signed and @as(i32, @bitCast(v)) < 0) x = ~v;
    if (x == 0) return 0xffff_ffff;
    const lz: u32 = @clz(x);
    return if (sh) lz else 31 - lz;
}

fn intIn(c: *const Ctx, wi: u32, t: u32, s: Src, ty: Ty) i128 {
    const v = raw64(c, wi, t, s);
    const lo: u32 = @truncate(v);
    return switch (ty) {
        .s8 => @as(i8, @bitCast(@as(u8, @truncate(lo)))),
        .u8 => @as(u8, @truncate(lo)),
        .s16 => @as(i16, @bitCast(@as(u16, @truncate(lo)))),
        .u16 => @as(u16, @truncate(lo)),
        .s32 => @as(i32, @bitCast(lo)),
        .u32 => lo,
        .s64 => @as(i64, @bitCast(v)),
        else => v,
    };
}

fn putFloat(c: *Ctx, wi: u32, t: u32, op: *const Op, ty: Ty, hi: f64, lo: f64) void {
    // (hi + lo, but -0 + 0 is -0: a conversion keeps the zero's sign)
    const v = if (lo == 0) hi else hi + lo;
    switch (ty) {
        .f64 => put64(c, wi, t, op.d[0], @bitCast(v)),
        .f16 => put(c, wi, t, op.d[0], toF16(v, op.rnd)),
        .bf16 => put(c, wi, t, op.d[0], toBf16(@floatCast(v), op.rnd)),
        else => {
            const x = roundTo(f32, hi, lo, op.rnd);
            put(c, wi, t, op.d[0], if (std.math.isNan(x)) NAN32 else @bitCast(if (op.ftz) flush(x) else x));
        },
    }
}

/// F2I's result: rounded, saturated; NaN 0 under .NTZ, else the most
/// negative signed value's bits, signed or not (the RTX 5070 gave
/// F2I.U32's NaN as 0x80000000 on legion20).
fn f2int(x: f64, ty: Ty, r: Round, ntz: bool) u64 {
    const bits = tyBits(ty);
    if (std.math.isNan(x)) return if (ntz) 0 else @as(u64, 1) << @intCast(bits - 1);
    const v = roundInt(x, r);
    if (isSigned(ty)) {
        const lim = std.math.ldexp(@as(f64, 1), @as(i32, bits) - 1);
        const max: i128 = (@as(i128, 1) << @intCast(bits - 1)) - 1;
        const min: i128 = -(@as(i128, 1) << @intCast(bits - 1));
        const iv: i128 = if (v >= lim) max else if (v < -lim) min else @intFromFloat(v);
        return @truncate(@as(u128, @bitCast(iv)));
    }
    if (!(v > 0)) return 0;
    if (v >= std.math.ldexp(@as(f64, 1), bits)) return @truncate((@as(u128, 1) << @intCast(bits)) - 1);
    return @intFromFloat(v);
}

/// Half i of a packed source, after its swizzle, |..| and -.
fn half(c: *const Ctx, wi: u32, t: u32, s: Src, i: u1) f32 {
    const v = raw32(c, wi, t, s);
    const pick: u1 = switch (s.swz) {
        0 => i,
        1 => 0,
        2 => 1,
        3 => ~i,
    };
    var h: u16 = @truncate(v >> (@as(u5, pick) * 16));
    if (s.abs) h &= 0x7fff;
    if (s.neg) h ^= 0x8000;
    return h2f(h);
}

fn flush16(x: f32) f32 {
    return if (@abs(x) < @as(f32, std.math.floatMin(f16)) and x != 0) (if (std.math.signbit(x)) -0.0 else 0.0) else x;
}

fn halfOp(op: *const Op, a: f32, b: f32, cc: f32) f64 {
    var x: f32 = a;
    var y: f32 = b;
    var z: f32 = cc;
    if (op.ftz) {
        x = flush16(x);
        y = flush16(y);
        z = flush16(z);
    }
    return switch (op.kind) {
        .hadd2 => @as(f64, x) + y,
        .hmul2 => @as(f64, x) * y,
        else => @as(f64, x) * y + z,
    };
}

fn halfResult(op: *const Op, v: f64) u16 {
    if (std.math.isNan(v)) return if (op.sat) 0 else NAN16;
    var x = v;
    if (op.sat) x = std.math.clamp(x, 0.0, 1.0);
    var h = toF16(x, .rn);
    if (op.ftz and h & 0x7c00 == 0) h &= 0x8000;
    return h;
}

fn lane(c: *Ctx, wi: u32, t: u32, op: *const Op) Error!void {
    const s = op.s;
    const d = op.d[0];
    switch (op.kind) {
        .nop, .hint => {},
        .mov => put(c, wi, t, d, raw32(c, wi, t, s[0])),
        .mov64 => put64(c, wi, t, d, raw64(c, wi, t, s[0])),
        .sel => put(c, wi, t, d, if (predOn(c, wi, t, op.p)) raw32(c, wi, t, s[0]) else raw32(c, wi, t, s[1])),
        .fsel => put(c, wi, t, d, if (predOn(c, wi, t, op.p)) fbits(c, wi, t, s[0]) else fbits(c, wi, t, s[1])),
        .iadd => put(c, wi, t, d, int(c, wi, t, s[0]) +% int(c, wi, t, s[1])),
        .iadd64 => put64(c, wi, t, d, int64(c, wi, t, s[0]) +% int64(c, wi, t, s[1])),
        .iadd3 => put(c, wi, t, d, int(c, wi, t, s[0]) +% int(c, wi, t, s[1]) +% int(c, wi, t, s[2])),
        .imad => put(c, wi, t, d, int(c, wi, t, s[0]) *% int(c, wi, t, s[1]) +% int(c, wi, t, s[2])),
        .imad_hi => {
            const a = int(c, wi, t, s[0]);
            const b = int(c, wi, t, s[1]);
            const hi: u32 = if (op.unsigned)
                @truncate((@as(u64, a) * b) >> 32)
            else
                @truncate(@as(u64, @bitCast(@as(i64, @as(i32, @bitCast(a))) * @as(i32, @bitCast(b)))) >> 32);
            put(c, wi, t, d, hi +% int(c, wi, t, s[2]));
        },
        .imad_wide => {
            const a = int(c, wi, t, s[0]);
            const b = int(c, wi, t, s[1]);
            const p: u64 = if (op.unsigned) @as(u64, a) * b else @bitCast(@as(i64, @as(i32, @bitCast(a))) * @as(i32, @bitCast(b)));
            const addend: u64 = if (s[2].kind == .imm)
                (if (op.unsigned) @as(u32, @truncate(s[2].imm)) else @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(s[2].imm)))))))
            else
                int64(c, wi, t, s[2]);
            put64(c, wi, t, d, p +% addend);
        },
        .lea => {
            const a = int(c, wi, t, s[0]);
            const shifted: u32 = std.math.shl(u32, a, op.sub);
            const sum = @as(u64, shifted) + int(c, wi, t, s[1]);
            put(c, wi, t, d, @truncate(sum));
            put(c, wi, t, op.d[1], @intFromBool(sum >> 32 != 0));
        },
        .lea_hi => {
            const a = int(c, wi, t, s[0]);
            const ahi: u32 = if (op.wrap) (if (@as(i32, @bitCast(a)) < 0) 0xffff_ffff else 0) else int(c, wi, t, s[2]);
            const a64: u64 = @as(u64, ahi) << 32 | a;
            const top: u32 = @truncate((a64 << @intCast(op.sub)) >> 32);
            const carry: u64 = if (op.x and predOn(c, wi, t, op.p)) 1 else 0;
            const sum = @as(u64, top) + int(c, wi, t, s[1]) + carry;
            put(c, wi, t, d, @truncate(sum));
            put(c, wi, t, op.d[1], @intFromBool(sum >> 32 != 0));
        },
        .shf => put(c, wi, t, d, shf(op, raw32(c, wi, t, s[0]), raw32(c, wi, t, s[1]), raw32(c, wi, t, s[2]))),
        .lop3 => {
            const v = lut3(op.lut[0], raw32(c, wi, t, s[0]), raw32(c, wi, t, s[1]), raw32(c, wi, t, s[2]));
            put(c, wi, t, d, v);
            put(c, wi, t, op.d[1], @intFromBool(v != 0));
        },
        .plop3 => {
            const a: u32 = if (predOn(c, wi, t, s[0])) 1 else 0;
            const b: u32 = if (predOn(c, wi, t, s[1])) 1 else 0;
            const cc: u32 = if (predOn(c, wi, t, s[2])) 1 else 0;
            put(c, wi, t, op.d[0], lut3(op.lut[0], a, b, cc) & 1);
            put(c, wi, t, op.d[1], lut3(op.lut[1], a, b, cc) & 1);
        },
        .prmt => put(c, wi, t, d, prmt(raw32(c, wi, t, s[0]), raw32(c, wi, t, s[1]), raw32(c, wi, t, s[2]))),
        .iabs => put(c, wi, t, d, @abs(@as(i32, @bitCast(raw32(c, wi, t, s[0]))))),
        .imnmx => {
            const a = int(c, wi, t, s[0]);
            const b = int(c, wi, t, s[1]);
            const min = predOn(c, wi, t, op.p);
            const less = if (op.unsigned) a < b else @as(i32, @bitCast(a)) < @as(i32, @bitCast(b));
            put(c, wi, t, d, if (less == min) a else b);
        },
        .popc => put(c, wi, t, d, @popCount(raw32(c, wi, t, s[0]))),
        .brev => put(c, wi, t, d, @bitReverse(raw32(c, wi, t, s[0]))),
        .flo => put(c, wi, t, d, flo(raw32(c, wi, t, s[0]), !op.unsigned, op.hi)),
        .idp => {
            const a = raw32(c, wi, t, s[0]);
            const b = raw32(c, wi, t, s[1]);
            var acc: i32 = @bitCast(raw32(c, wi, t, s[2]));
            for (0..4) |k| {
                const ab: u8 = @truncate(a >> @intCast(8 * k));
                const bb: u8 = @truncate(b >> @intCast(8 * k));
                const av: i32 = if (op.ty[0] == .s8) @as(i8, @bitCast(ab)) else ab;
                const bv: i32 = if (op.ty[1] == .s8) @as(i8, @bitCast(bb)) else bb;
                acc +%= av * bv;
            }
            put(c, wi, t, d, @bitCast(acc));
        },
        .isetp => {
            const r = icmp(op.sub, raw32(c, wi, t, s[0]), raw32(c, wi, t, s[1]), op.unsigned);
            const acc = predOn(c, wi, t, op.p);
            put(c, wi, t, op.d[0], @intFromBool(boolOp(op.sub2, r, acc)));
            put(c, wi, t, op.d[1], @intFromBool(boolOp(op.sub2, !r, acc)));
        },
        .fsetp => {
            const r = fcmp(op.sub, flt(c, wi, t, s[0], op.ftz), flt(c, wi, t, s[1], op.ftz));
            const acc = predOn(c, wi, t, op.p);
            put(c, wi, t, op.d[0], @intFromBool(boolOp(op.sub2, r, acc)));
            put(c, wi, t, op.d[1], @intFromBool(boolOp(op.sub2, !r, acc)));
        },
        .ffma => put(c, wi, t, d, fresult(ffma(flt(c, wi, t, s[0], op.ftz), flt(c, wi, t, s[1], op.ftz), flt(c, wi, t, s[2], op.ftz), op.rnd), op)),
        .fadd => put(c, wi, t, d, fresult(fadd(flt(c, wi, t, s[0], op.ftz), flt(c, wi, t, s[1], op.ftz), op.rnd), op)),
        .fmul => put(c, wi, t, d, fresult(fmul(flt(c, wi, t, s[0], op.ftz), flt(c, wi, t, s[1], op.ftz), op.rnd), op)),
        .fmnmx => put(c, wi, t, d, fresult(fminmax(flt(c, wi, t, s[0], op.ftz), flt(c, wi, t, s[1], op.ftz), predOn(c, wi, t, op.p)), op)),
        .mufu => {
            // (the special-function unit flushes denormals)
            const x: f64 = flush(flt(c, wi, t, s[0], true));
            const v: f64 = switch (op.sub) {
                0 => @exp2(x),
                1 => @log2(x),
                2 => 1.0 / x,
                3 => 1.0 / @sqrt(x),
                4 => @sqrt(x),
                5 => @sin(2.0 * std.math.pi * x),
                6 => @cos(2.0 * std.math.pi * x),
                else => std.math.tanh(x),
            };
            const r: f32 = @floatCast(v);
            put(c, wi, t, d, if (std.math.isNan(r)) NAN32 else @bitCast(flush(r)));
        },
        .hadd2, .hmul2, .hfma2 => {
            if (op.f32out) {
                const v = halfOp(op, half(c, wi, t, s[0], 0), half(c, wi, t, s[1], 0), if (op.kind == .hfma2) half(c, wi, t, s[2], 0) else 0);
                const r: f32 = @floatCast(v);
                put(c, wi, t, d, fresult(r, op));
                return;
            }
            var out: u32 = 0;
            for (0..2) |k| {
                const i: u1 = @intCast(k);
                const a = half(c, wi, t, s[0], i);
                const v = switch (op.kind) {
                    .hadd2 => halfOp(op, a, half(c, wi, t, s[1], i), 0),
                    .hmul2 => halfOp(op, a, half(c, wi, t, s[1], i), 0),
                    else => halfOp(op, a, half(c, wi, t, s[1], i), half(c, wi, t, s[2], i)),
                };
                out |= @as(u32, halfResult(op, v)) << @intCast(16 * k);
            }
            put(c, wi, t, d, out);
        },
        .i2f => {
            const v = intIn(c, wi, t, s[0], op.ty[1]);
            const hi: f64 = @floatFromInt(v);
            const lo: f64 = @floatFromInt(v - @as(i128, @intFromFloat(hi)));
            putFloat(c, wi, t, op, op.ty[0], hi, lo);
        },
        .f2i => {
            const x = floatIn(c, wi, t, s[0], op.ty[1], op.ftz);
            const v = f2int(x, op.ty[0], op.rnd, op.ntz);
            if (tyBits(op.ty[0]) == 64) put64(c, wi, t, d, v) else put(c, wi, t, d, @truncate(v & 0xffff_ffff));
        },
        .f2f => {
            const x = floatIn(c, wi, t, s[0], op.ty[1], op.ftz);
            if (op.ty[0] == .f32 and op.ty[1] == .f32) {
                put(c, wi, t, d, fresult(@floatCast(x), op));
            } else putFloat(c, wi, t, op, op.ty[0], x, 0);
        },
        .f2fp => {
            const a = flt(c, wi, t, s[0], false);
            const b = flt(c, wi, t, s[1], false);
            const pack: [2]u16 = if (op.ty[0] == .bf16) .{ toBf16(a, op.rnd), toBf16(b, op.rnd) } else .{ toF16(a, op.rnd), toF16(b, op.rnd) };
            put(c, wi, t, d, @as(u32, pack[0]) << 16 | pack[1]);
        },
        .frnd => {
            const x = flt(c, wi, t, s[0], op.ftz);
            put(c, wi, t, d, fresult(@floatCast(roundInt(x, op.rnd)), op));
        },
        .ldc => {
            const off = s[0].imm +% (if (s[0].index != RZ) c.w.regs[t][s[0].index] else 0);
            const v = cbufRead(c, s[0].bank, off, op.size);
            if (op.size == 8) put64(c, wi, t, d, v) else put(c, wi, t, d, @truncate(extend(v, op.size, op.signed)));
        },
        .s2r => put(c, wi, t, d, try sreg(c, wi, t, op.sub)),
        .cs2r => {
            const v: u64 = if (op.sub == 0xff) 0 else blk: {
                const lo = try sreg(c, wi, t, op.sub);
                break :blk if (op.size == 8) @as(u64, try sreg(c, wi, t, op.sub + 1)) << 32 | lo else lo;
            };
            if (op.size == 8) put64(c, wi, t, d, v) else put(c, wi, t, d, @truncate(v));
        },
        .ldg, .stg, .ldl, .stl, .lds, .sts => try access(c, wi, t, op),
        .atomg, .atoms => try atomicAccess(c, wi, t, op),
        .ald, .ast, .ipa, .kill, .tex, .tld => try stageLane(c, wi, t, op),
        else => return error.Unsupported,
    }
}

fn extend(v: u64, size: u8, signed: bool) u64 {
    return switch (size) {
        1 => if (signed) @bitCast(@as(i64, @as(i8, @bitCast(@as(u8, @truncate(v)))))) else v & 0xff,
        2 => if (signed) @bitCast(@as(i64, @as(i16, @bitCast(@as(u16, @truncate(v)))))) else v & 0xffff,
        else => v,
    };
}

fn sreg(c: *const Ctx, wi: u32, t: u32, n: u8) Error!u32 {
    const b = c.l.block;
    const ln = t % WARP;
    const cycle = c.w.warps[wi].cycle;
    const ns = c.l.timer_ns + cycle / 2;
    return switch (n) {
        0x00 => ln,
        0x21 => t % b[0],
        0x22 => (t / b[0]) % b[1],
        0x23 => t / (b[0] * b[1]),
        0x25 => c.cta[0],
        0x26 => c.cta[1],
        0x27 => c.cta[2],
        0x38 => @as(u32, 1) << @intCast(ln),
        0x39 => (@as(u32, 1) << @intCast(ln)) - 1,
        0x3a => @truncate((@as(u64, 2) << @intCast(ln)) - 1),
        0x3b => ~@as(u32, @truncate((@as(u64, 2) << @intCast(ln)) - 1)),
        0x3c => ~((@as(u32, 1) << @intCast(ln)) - 1),
        0x50 => cycle,
        0x51 => 0,
        0x52 => @truncate(ns),
        0x53 => @truncate(ns >> 32),
        else => error.Unsupported,
    };
}

// ── Memory accesses ─────────────────────────────────────────────────────────

fn fault(c: *Ctx, t: u32, va: u64) Error {
    c.w.trap = .{ .what = .fault, .pc = @as(u64, c.pc) * 16 };
    c.w.trap.va = va;
    c.w.trap.cta = c.cta;
    c.w.trap.thread = t;
    return error.Fault;
}

/// A thread's local memory: its window's address `a` to the pool's bytes.
fn localBytes(c: *Ctx, t: u32, a: u64, n: usize) ?[]u8 {
    const l = c.l;
    const base = @as(usize, c.local_per) * t;
    const top: u64 = qmd.LOCAL_TOP;
    if (a + n <= l.local_low) return c.w.local[base + @as(usize, @intCast(a)) ..][0..n];
    if (a >= top - l.local_high and a + n <= top) return c.w.local[base + l.local_low + @as(usize, @intCast(a - (top - l.local_high))) ..][0..n];
    return null;
}

fn access(c: *Ctx, wi: u32, t: u32, op: *const Op) Error!void {
    const n: usize = op.size;
    const b = op.mem.base;
    const base: u64 = if (op.mem.wide) raw64(c, wi, t, b) else raw32(c, wi, t, b);
    const off: u64 = @bitCast(@as(i64, op.mem.offset));
    const bytes: []u8 = switch (op.kind) {
        .ldg, .stg => blk: {
            const va = base +% off;
            if (va % n != 0) return fault(c, t, va);
            const x = c.mem.find(va, n) orelse return fault(c, t, va);
            if (op.kind == .ldg) c.stats.global_read += n else c.stats.global_written += n;
            break :blk x;
        },
        .ldl, .stl => blk: {
            const a = (base +% off) & 0xffff_ffff;
            if (a % n != 0) return fault(c, t, a);
            break :blk localBytes(c, t, a, n) orelse return fault(c, t, a);
        },
        else => blk: {
            const a = (base +% off) & 0xffff_ffff;
            if (a % n != 0 or a + n > c.l.shared_bytes) return fault(c, t, a);
            break :blk c.w.shared[@intCast(a)..][0..n];
        },
    };
    const load_ = op.kind == .ldg or op.kind == .ldl or op.kind == .lds;
    if (load_) {
        if (n <= 4) {
            var v: u64 = 0;
            for (0..n) |i| v |= @as(u64, bytes[i]) << @intCast(8 * i);
            put(c, wi, t, op.d[0], @truncate(extend(v, op.size, op.signed)));
        } else for (0..n / 4) |k| {
            put(c, wi, t, .{ .file = op.d[0].file, .n = op.d[0].n +| @as(u8, @intCast(k)) }, std.mem.readInt(u32, bytes[k * 4 ..][0..4], .little));
        }
    } else {
        const s = op.s[0];
        if (n <= 4) {
            const v = raw32(c, wi, t, s);
            for (0..n) |i| bytes[i] = @truncate(v >> @intCast(8 * i));
        } else for (0..n / 4) |k| {
            const r: u8 = if (s.n == RZ) RZ else s.n + @as(u8, @intCast(k));
            std.mem.writeInt(u32, bytes[k * 4 ..][0..4], c.w.regs[t][r], .little);
        }
    }
}

/// An atomic: the word read, the operation, the word written, the old value
/// to Rd (and true to ATOMG's predicate). Lanes run one after another, so
/// each sees the ones before it.
fn atomicAccess(c: *Ctx, wi: u32, t: u32, op: *const Op) Error!void {
    const b = op.mem.base;
    const base: u64 = if (op.mem.wide) raw64(c, wi, t, b) else raw32(c, wi, t, b);
    const off: u64 = @bitCast(@as(i64, op.mem.offset));
    const bytes: *[4]u8 = if (op.kind == .atomg) blk: {
        const va = base +% off;
        if (va % 4 != 0) return fault(c, t, va);
        const x = c.mem.find(va, 4) orelse return fault(c, t, va);
        c.stats.global_read += 4;
        c.stats.global_written += 4;
        break :blk x[0..4];
    } else blk: {
        const a = (base +% off) & 0xffff_ffff;
        if (a % 4 != 0 or a + 4 > c.l.shared_bytes) return fault(c, t, a);
        break :blk c.w.shared[@intCast(a)..][0..4];
    };
    const old = std.mem.readInt(u32, bytes, .little);
    const v = raw32(c, wi, t, op.s[0]);
    const so: i32 = @bitCast(old);
    const sv: i32 = @bitCast(v);
    const new: u32 = switch (op.sub) {
        0 => old +% v,
        1 => if (op.signed) @bitCast(@min(so, sv)) else @min(old, v),
        2 => if (op.signed) @bitCast(@max(so, sv)) else @max(old, v),
        3 => if (old >= v) 0 else old + 1,
        4 => if (old == 0 or old > v) v else old - 1,
        5 => old & v,
        6 => old | v,
        7 => old ^ v,
        9 => if (old == v) raw32(c, wi, t, op.s[1]) else old,
        else => v,
    };
    std.mem.writeInt(u32, bytes, new, .little);
    put(c, wi, t, op.d[0], old);
    if (op.kind == .atomg) put(c, wi, t, op.d[1], 1);
}

// ── Warp-collective instructions ────────────────────────────────────────────

fn shfl(c: *Ctx, wi: u32, op: *const Op, on: []const u32) Error!void {
    const base = wi * WARP;
    var vals: [WARP]u32 = undefined;
    var have: u32 = 0;
    for (on) |t| {
        vals[t - base] = raw32(c, wi, t, op.s[0]);
        have |= @as(u32, 1) << @intCast(t - base);
    }
    for (on) |t| {
        const ln: i32 = @intCast(t - base);
        const b: i32 = @intCast(raw32(c, wi, t, op.s[1]) & 0x1f);
        const cv = raw32(c, wi, t, op.s[2]);
        const seg: i32 = @intCast((cv >> 8) & 0x1f);
        const clamp: i32 = @intCast(cv & 0x1f);
        const max_lane = (ln & seg) | (clamp & ~seg);
        const min_lane = ln & seg;
        var j: i32 = 0;
        var ok = false;
        switch (op.sub) {
            0 => {
                j = min_lane | (b & ~seg);
                ok = j <= max_lane;
            },
            1 => {
                j = ln - b;
                ok = j >= max_lane;
            },
            2 => {
                j = ln + b;
                ok = j <= max_lane;
            },
            else => {
                j = ln ^ b;
                ok = j <= max_lane;
            },
        }
        if (!ok) j = ln;
        // (a source lane not taking part: its own value)
        const src: u5 = @intCast(j & 31);
        const v = if ((have >> src) & 1 != 0) vals[src] else vals[@intCast(ln)];
        put(c, wi, t, op.d[0], v);
        put(c, wi, t, op.d[1], @intFromBool(ok));
    }
}

fn vote(c: *Ctx, wi: u32, op: *const Op, on: []const u32) void {
    const base = wi * WARP;
    var ballot: u32 = 0;
    var active: u32 = 0;
    for (on) |t| {
        active |= @as(u32, 1) << @intCast(t - base);
        if (predOn(c, wi, t, op.p)) ballot |= @as(u32, 1) << @intCast(t - base);
    }
    const r = switch (op.sub) {
        0 => ballot != 0,
        1 => ballot == active,
        else => ballot == 0 or ballot == active,
    };
    if (on.len == 0) return;
    for (on) |t| {
        put(c, wi, t, op.d[0], ballot);
        put(c, wi, t, op.d[1], @intFromBool(r));
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

var test_work: Work = .{};
var test_asm: sm120_asm.Work = .{};

/// `text` run as one launch over `regions`; the error's sentence printed.
fn runText(text: []const u8, l: *const Launch, regions: []const Region) !Stats {
    try loadText(&test_work, text);
    return runLoaded(l, regions);
}

fn runLoaded(l: *const Launch, regions: []const Region) !Stats {
    const mem = Memory{ .regions = regions };
    var stats = Stats{};
    run(&test_work, &mem, l, &stats) catch |e| {
        var buf: [256]u8 = undefined;
        std.debug.print("emulate: {s}: {s}\n", .{ @errorName(e), explain(&test_work, &buf) });
        return e;
    };
    return stats;
}

/// A launch of one CTA of `block` threads, constant buffer 0 in `cb` with
/// `params`.
fn launchOf(cb: *[qmd.CBUF0_WORDS]u32, block: [3]u32, params: []const u8) !Launch {
    try qmd.cbuf0(cb, .{ 1, 1, 1 }, block, params);
    var l = Launch{ .block = block };
    l.cbufs[0] = std.mem.sliceAsBytes(cb);
    return l;
}

test "integers: IADD3, IMAD, LOP3, shifts, LEA, PRMT, selects, IDP.4A" {
    var out = [_]u32{0} ** 16;
    const regions = [_]Region{.{ .va = 0x1000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x1000};
    const l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    _ = try runText(
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\MOV R4, 0x7fffffff
        \\MOV R5, -0x3
        \\IADD3 R6, PT, PT, R4, R5, 0x10
        \\IMAD R7, R5, R5, -0x1
        \\IMAD.HI.U32 R8, R4, 0x4, RZ
        \\LOP3.LUT R9, R4, R5, RZ, 0x3c, !PT
        \\SHF.R.S32.HI R10, RZ, 0x1f, R5
        \\SHF.L.U64.HI R11, R4, 0x4, RZ
        \\LEA R12, R5, 0x100, 0x2
        \\LEA.HI R13, R5, R5, RZ, 0x1
        \\PRMT R14, R4, 0x7654, R5
        \\IDP.4A.S8.S8 R15, R5, R5, RZ
        \\ISETP.GT.AND P0, PT, R5, RZ, PT
        \\SEL R16, R4, R5, P0
        \\FLO.U32 R17, R4
        \\POPC R18, R5
        \\STG.E.128 desc[UR4][R2.64], R6
        \\STG.E.128 desc[UR4][R2.64+0x10], R10
        \\STG.E.128 desc[UR4][R2.64+0x20], R14
        \\STG.E desc[UR4][R2.64+0x30], R18
        \\EXIT
    , &l, &regions);
    try testing.expectEqual(@as(u32, 0x7fffffff -% 3 +% 0x10), out[0]);
    try testing.expectEqual(@as(u32, 8), out[1]); // 9 - 1
    try testing.expectEqual(@as(u32, 1), out[2]); // hi(0x7fffffff * 4)
    try testing.expectEqual(@as(u32, 0x7fffffff ^ 0xfffffffd), out[3]);
    try testing.expectEqual(@as(u32, 0xffffffff), out[4]); // -3 >> 31
    try testing.expectEqual(@as(u32, 0x7), out[5]); // (0:0x7fffffff << 4) >> 32
    try testing.expectEqual(@as(u32, 0xf4), out[6]); // (-3 << 2) + 0x100
    try testing.expectEqual(@as(u32, 0xfffffffd +% 1), out[7]); // -3 + (-3 >> 31 logical)
    try testing.expectEqual(@as(u32, 0xfffffffd), out[8]); // bytes 4..7: b
    try testing.expectEqual(@as(u32, 1 + 1 + 1 + 9), out[9]); // (-1)^2 * 3 + 9
    try testing.expectEqual(@as(u32, 0xfffffffd), out[10]); // P0 false: b
    try testing.expectEqual(@as(u32, 30), out[11]);
    try testing.expectEqual(@as(u32, 31), out[12]);
}

test "floats: FFMA, FADD's directed rounding, FMNMX, FSETP, FTZ, MUFU, conversions, halves" {
    var out = [_]u32{0} ** 16;
    const regions = [_]Region{.{ .va = 0x2000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x2000};
    const l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    _ = try runText(
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\MOV R4, 0x3f800000
        \\MOV R5, 0x00000001
        \\FFMA R6, R4, 2, 0.5
        \\FADD.RP R7, R4, R5
        \\FADD R8, R4, R5
        \\FADD.FTZ R9, R5, R5
        \\FMNMX R10, R4, -R4, !PT
        \\FSETP.GT.AND P0, PT, R4, R5, PT
        \\SEL R11, 0x1, 0x2, P0
        \\MUFU.EX2 R12, 3
        \\MUFU.RSQ R13, 4
        \\F2I.TRUNC.NTZ R14, -2.75
        \\I2FP.F32.S32 R15, R14
        \\F2FP.F16.F32.PACK_AB R16, R4, 0.5
        \\HFMA2 R17, R16, R16, -1, -1
        \\HADD2.F32 R18, -RZ, R16.H1_H1
        \\F2I.U32.TRUNC.NTZ R19, -2.75
        \\STG.E.128 desc[UR4][R2.64], R6
        \\STG.E.128 desc[UR4][R2.64+0x10], R10
        \\STG.E.128 desc[UR4][R2.64+0x20], R14
        \\STG.E.128 desc[UR4][R2.64+0x30], R18
        \\EXIT
    , &l, &regions);
    try testing.expectEqual(@as(f32, 2.5), f32of(out[0]));
    try testing.expectEqual(@as(u32, 0x3f800001), out[1]); // 1 + tiny, up
    try testing.expectEqual(@as(u32, 0x3f800000), out[2]); // ... to nearest
    try testing.expectEqual(@as(u32, 0), out[3]); // (denormal sum flushed)
    try testing.expectEqual(@as(f32, 1), f32of(out[4])); // max
    try testing.expectEqual(@as(u32, 1), out[5]);
    try testing.expectApproxEqRel(@as(f32, 8), f32of(out[6]), 1e-6);
    try testing.expectApproxEqRel(@as(f32, 0.5), f32of(out[7]), 1e-6);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), out[8]);
    try testing.expectEqual(@as(f32, -2), f32of(out[9]));
    try testing.expectEqual(@as(u32, 0x3c00_3800), out[10]); // (1.0, 0.5) as halves
    try testing.expectEqual(@as(u32, 0x0000_ba00), out[11]); // (1*1-1, 0.5*0.5-1)
    try testing.expectEqual(@as(f32, 1), f32of(out[12])); // the high half to f32
    try testing.expectEqual(@as(u32, 0), out[13]); // (unsigned: saturates at 0)
}

test "F2I: NaN is 0x80000000 without .NTZ, as the RTX 5070 gave it (legion20); .NTZ is not .FTZ" {
    var out = [_]u32{0} ** 8;
    const regions = [_]Region{.{ .va = 0x2000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x2000};
    const l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    _ = try runText(
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\MOV R4, 0x7fc00000
        \\MOV R5, 0x80000001
        \\F2I.U32 R6, R4
        \\F2I R7, R4
        \\F2I.U32.NTZ R8, R4
        \\F2I.U32.TRUNC.NTZ R9, R4
        \\F2I.TRUNC.NTZ R10, R4
        \\F2I.FLOOR.NTZ R11, R5
        \\F2I.FTZ.FLOOR.NTZ R12, R5
        \\F2I.U32.CEIL.NTZ R13, R5
        \\STG.E.128 desc[UR4][R2.64], R6
        \\STG.E.128 desc[UR4][R2.64+0x10], R10
        \\EXIT
    , &l, &regions);
    try testing.expectEqual(@as(u32, 0x80000000), out[0]); // unsigned, no .NTZ
    try testing.expectEqual(@as(u32, 0x80000000), out[1]); // signed, no .NTZ
    try testing.expectEqual(@as(u32, 0), out[2]);
    try testing.expectEqual(@as(u32, 0), out[3]);
    try testing.expectEqual(@as(u32, 0), out[4]);
    try testing.expectEqual(@as(u32, 0xffffffff), out[5]); // floor(-denormal): kept
    try testing.expectEqual(@as(u32, 0), out[6]); // flushed first
    try testing.expectEqual(@as(u32, 0), out[7]); // ceil(-denormal) = -0: 0
}

test "divergence reconverges; a loop; BAR.SYNC; shared memory; SHFL.BFLY; VOTE" {
    var out = [_]u32{0} ** 64;
    const regions = [_]Region{.{ .va = 0x3000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x3000};
    var l = try launchOf(&cb, .{ 64, 1, 1 }, std.mem.asBytes(&p));
    l.shared_bytes = 0x400 + 256;
    // each thread: odd ones add 100 (a branch), all store tid to shared,
    // BAR, read their neighbour's (tid ^ 1) back, reduce across the warp
    // with SHFL.BFLY, and lane 0 writes the warp's sum and ballot
    _ = try runText(
        \\S2R R0, SR_TID.X
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\MOV R4, R0
        \\LOP3.LUT R5, R0, 0x1, RZ, 0xc0, !PT
        \\ISETP.NE.AND P0, PT, R5, RZ, PT
        \\@!P0 BRA `(even)
        \\IADD R4, R4, 0x64
        \\even:
        \\IMAD.SHL.U32 R6, R0, 0x4, RZ
        \\STS [R6+0x400], R4
        \\BAR.SYNC.DEFER_BLOCKING 0x0
        \\LOP3.LUT R7, R6, 0x4, RZ, 0x3c, !PT
        \\LDS R8, [R7+0x400]
        \\MOV R9, 0x10
        \\loop:
        \\SHFL.BFLY PT, R10, R8, R9, 0x1f
        \\IADD R8, R8, R10
        \\SHF.R.U32.HI R9, RZ, 0x1, R9
        \\ISETP.NE.AND P1, PT, R9, RZ, PT
        \\@P1 BRA `(loop)
        \\VOTE.ANY R11, PT, P0
        \\S2R R12, SR_LANEID
        \\ISETP.NE.AND P2, PT, R12, RZ, PT
        \\@P2 EXIT
        \\SHF.R.U32.HI R13, RZ, 0x5, R0
        \\IMAD.WIDE.U32 R14, R13, 0x8, R2
        \\STG.E.64 desc[UR4][R14.64], R8
        \\STG.E desc[UR4][R14.64+0x20], R11
        \\EXIT
    , &l, &regions);
    // warp w's lanes hold tid + 100 for odd tid: sum of 32w..32w+31 + 16 * 100
    for (0..2) |wv| {
        var sum: u32 = 0;
        for (0..32) |k| sum += @intCast(wv * 32 + k);
        try testing.expectEqual(sum + 1600, out[wv * 2]);
        try testing.expectEqual(@as(u32, 0xaaaa_aaaa), out[8 + wv * 2]);
    }
}

test "a warp-collective waits for the lanes still running, wherever they are" {
    var out = [_]u32{0} ** 32;
    const regions = [_]Region{.{ .va = 0x6000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x6000};
    const l = try launchOf(&cb, .{ 32, 1, 1 }, std.mem.asBytes(&p));
    // (lanes 0..15 reach the SHFL first, while 16..31 still run a detour
    // further on that comes back to it: the SHFL must wait for them, so
    // every lane reads lane 31's index)
    _ = try runText(
        \\S2R R0, SR_TID.X
        \\LDC.64 R6, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\ISETP.GE.U32.AND P0, PT, R0, 0x10, PT
        \\@P0 BRA `(detour)
        \\back:
        \\SHFL.IDX PT, R3, R0, 0x1f, 0x1f
        \\VOTE.ALL R4, P1, PT
        \\IMAD.WIDE.U32 R8, R0, 0x4, R6
        \\STG.E desc[UR4][R8.64], R3
        \\EXIT
        \\detour:
        \\IADD R5, R0, 0x1
        \\BRA `(back)
    , &l, &regions);
    for (out) |v| try testing.expectEqual(@as(u32, 31), v);
}

test "the uniform datapath: once a warp, its own registers and predicates" {
    var out = [_]u32{0} ** 64;
    const regions = [_]Region{.{ .va = 0x8000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x8000};
    var l = try launchOf(&cb, .{ 32, 1, 1 }, std.mem.asBytes(&p));
    l.grid = .{ 2, 1, 1 };
    _ = try runText(
        \\S2R R0, SR_TID.X
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\S2UR UR6, SR_CTAID.X
        \\UIADD3 UR7, UPT, UPT, UR6, 0x10, URZ
        \\ULOP3.LUT UR8, UR7, 0x1f, URZ, 0xc0, !UPT
        \\USHF.L.U32 UR9, UR8, 0x2, URZ
        \\UISETP.GT.U32.AND UP0, UPT, UR9, 0x40, UPT
        \\USEL UR10, UR9, URZ, UP0
        \\UMOV UR11, 0x5
        \\VOTEU.ANY UR12, UPT, PT
        \\MOV R5, UR10
        \\IADD R5, R5, UR11
        \\IMAD R6, R0, 0x4, R5
        \\S2R R7, SR_CTAID.X
        \\IMAD R8, R7, 0x20, R0
        \\IMAD.WIDE.U32 R8, R8, 0x4, R2
        \\STG.E desc[UR4][R8.64], R6
        \\EXIT
    , &l, &regions);
    // CTA 0: UR9 = 0x40, not above 0x40: UR10 = 0; CTA 1: 0x44
    for (0..32) |t| try testing.expectEqual(@as(u32, @intCast(5 + 4 * t)), out[t]);
    for (0..32) |t| try testing.expectEqual(@as(u32, @intCast(0x44 + 5 + 4 * t)), out[32 + t]);
}

test "LDC with an index register, and its read checked" {
    var out = [_]u32{0} ** 4;
    const regions = [_]Region{.{ .va = 0x7000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{ 0x7000, 0x1111_2222_3333_4444 };
    const l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    _ = try runText(
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\MOV R4, 0x4
        \\LDC R5, c[0x0][R4+0x388]
        \\STG.E desc[UR4][R2.64], R5
        \\EXIT
    , &l, &regions);
    try testing.expectEqual(@as(u32, 0x1111_2222), out[0]);
    // (the index from S2R, read before its scoreboard is waited on)
    try testing.expectError(error.Hazard, runText("[B------:R-:W0:Y:S02] S2R R4, SR_TID.X\n[B------:R-:W1:Y:S02] LDC R5, c[0x0][R4+0x388]\n[B------:R-:W-:Y:S05] EXIT", &l, &regions));
    try testing.expectEqual(@as(u8, 4), test_work.trap.reg);
}

test "local memory: the stack window, faults outside it" {
    var out = [_]u32{0} ** 4;
    const regions = [_]Region{.{ .va = 0x4000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x4000};
    var l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    l.local_high = 0x280;
    const text =
        \\LDC R1, c[0x0][0x37c]
        \\LDC.64 R2, c[0x0][0x380]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\IADD R1, R1, -0x10
        \\MOV R4, 0x1234
        \\STL [R1+0x4], R4
        \\LDL R5, [R1+0x4]
        \\STG.E desc[UR4][R2.64], R5
        \\EXIT
    ;
    _ = try runText(text, &l, &regions);
    try testing.expectEqual(@as(u32, 0x1234), out[0]);
    l.local_high = 0x10; // (the stack's top is 0x240 below the window's)
    try testing.expectError(error.Fault, runText(text, &l, &regions));
    try testing.expectEqual(What.fault, test_work.trap.what);
    try testing.expectEqual(@as(u64, 0x50), test_work.trap.pc); // (the STL)
}

test "the hazard checker: a stall cut short, a missing wait, a write over a pending read" {
    var out = [_]u32{0} ** 4;
    const regions = [_]Region{.{ .va = 0x5000, .bytes = std.mem.sliceAsBytes(&out) }};
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{0x5000};
    const l = try launchOf(&cb, .{ 1, 1, 1 }, std.mem.asBytes(&p));
    const ok =
        \\[B------:R-:W0:Y:S01] LDC.64 R2, c[0x0][0x380]
        \\[B------:R-:W1:Y:S01] LDCU.64 UR4, c[0x0][0x358]
        \\[B------:R-:W-:-:S04] IADD R4, RZ, 0x7
        \\[B------:R-:W-:-:S05] IADD R4, R4, 0x1
        \\[B01----:R2:W-:Y:S02] STG.E desc[UR4][R2.64], R4
        \\[B--2---:R-:W-:-:S01] MOV R4, RZ
        \\[B------:R-:W-:Y:S05] EXIT
    ;
    _ = try runText(ok, &l, &regions);
    try testing.expectEqual(@as(u32, 8), out[0]);
    var buf: [256]u8 = undefined;
    // (IADD to IADD: 4 cycles, no padding at the hardware's level)
    const short = "[B------:R-:W-:-:S03] IADD R4, RZ, 0x7\n[B------:R-:W-:-:S05] IADD R4, R4, 0x1\n[B------:R-:W-:Y:S05] EXIT";
    try testing.expectError(error.Hazard, runText(short, &l, &regions));
    try testing.expectEqual(HazardKind.raw, test_work.trap.hazard);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.pc);
    try testing.expectEqual(@as(u8, 4), test_work.trap.reg);
    try testing.expectEqual(@as(u32, 4), test_work.trap.need);
    try testing.expectEqual(@as(u32, 3), test_work.trap.have);
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "R4") != null);
    // (no wait on the descriptor's scoreboard)
    var missing: [512]u8 = undefined;
    const m = std.mem.replace(u8, ok, "[B01----:R2:W-:Y:S02] STG", "[B0-----:R2:W-:Y:S02] STG", &missing);
    try testing.expectEqual(@as(usize, 1), m);
    try testing.expectError(error.Hazard, runText(missing[0..ok.len], &l, &regions));
    try testing.expect(test_work.trap.scoreboard);
    try testing.expectEqual(sched.File.ugpr, test_work.trap.file);
    // (R4 overwritten while the store may not have read it)
    var war: [512]u8 = undefined;
    _ = std.mem.replace(u8, ok, "[B--2---:R-:W-:-:S01] MOV", "[B------:R-:W-:-:S01] MOV", &war);
    try testing.expectError(error.Hazard, runText(war[0..ok.len], &l, &regions));
    try testing.expectEqual(HazardKind.war, test_work.trap.hazard);
    // (strict: NAK's padding wants 5 for IADD to IADD)
    test_work.strict = true;
    defer test_work.strict = false;
    try testing.expectError(error.Hazard, runText(ok, &l, &regions));
    try testing.expectEqual(@as(u32, 5), test_work.trap.need);
}

test "FRND's roundings and the atomics: scheduled by sm120_asm, run strict" {
    var out = [_]u32{0} ** 256;
    var counters = [_]u32{ 0, 0xffff_ffff, 0, 0xeeee_eeee, 0, 0 };
    const regions = [_]Region{
        .{ .va = 0x6000, .bytes = std.mem.sliceAsBytes(&out) },
        .{ .va = 0x7000, .bytes = std.mem.sliceAsBytes(&counters) },
    };
    var cb: [qmd.CBUF0_WORDS]u32 = undefined;
    const p = [_]u64{ 0x6000, 0x7000 };
    var l = try launchOf(&cb, .{ 64, 1, 1 }, std.mem.asBytes(&p));
    l.shared_bytes = 0x400 + 16;
    // thread t: x = (t - 32) * 0.75 floored, ceiled, truncated and rounded
    // to even into out[4t..]; a global add of 1, a min and a max of t, an
    // exchange; a shared add of t and a shared signed max of 10 - t
    // (thread 0 sets the shared words first), which thread 0 stores
    const text =
        \\S2R R0, SR_TID.X
        \\LDC.64 R2, c[0x0][0x380]
        \\LDC.64 R4, c[0x0][0x388]
        \\LDCU.64 UR4, c[0x0][0x358]
        \\ISETP.NE.AND P0, PT, R0, RZ, PT
        \\MOV R24, RZ
        \\MOV R25, 0x80000000
        \\@!P0 STS.64 [RZ+0x400], R24
        \\BAR.SYNC.DEFER_BLOCKING 0x0
        \\IADD R6, R0, -0x20
        \\I2FP.F32.S32 R6, R6
        \\FMUL R6, R6, 0.75
        \\FRND.FLOOR R8, R6
        \\FRND.CEIL R9, R6
        \\FRND.TRUNC R10, R6
        \\FRND R11, R6
        \\IMAD.WIDE.U32 R12, R0, 0x10, R2
        \\STG.E.128 desc[UR4][R12.64], R8
        \\MOV R14, 0x1
        \\ATOMG.E.ADD.STRONG.GPU PT, R15, desc[UR4][R4.64], R14
        \\ATOMG.E.MIN.STRONG.GPU PT, R16, desc[UR4][R4.64+0x4], R0
        \\ATOMG.E.MAX.STRONG.GPU PT, R17, desc[UR4][R4.64+0x8], R0
        \\ATOMG.E.EXCH.STRONG.GPU PT, R18, desc[UR4][R4.64+0xc], R0
        \\ATOMS.ADD R19, [RZ+0x400], R0
        \\IADD R20, -R0, 0xa
        \\ATOMS.MAX.S32 R21, [RZ+0x404], R20
        \\BAR.SYNC.DEFER_BLOCKING 0x0
        \\LDS.64 R22, [RZ+0x400]
        \\@P0 EXIT
        \\STG.E.64 desc[UR4][R4.64+0x10], R22
        \\EXIT
    ;
    var code: [512]u64 = undefined;
    const k = try sm120_asm.assemble(text, &code, &test_asm);
    try testing.expect(k.scheduled);
    try loadAssembled(&test_work, &test_asm, k);
    test_work.strict = true;
    defer test_work.strict = false;
    _ = try runLoaded(&l, &regions);
    for (0..64) |t| {
        const x = @as(f32, @floatFromInt(@as(i32, @intCast(t)) - 32)) * 0.75;
        const even = if (@abs(x - @trunc(x)) == 0.5) 2.0 * @round(x / 2.0) else @round(x);
        try testing.expectEqual(@floor(x), @as(f32, @bitCast(out[4 * t])));
        try testing.expectEqual(@ceil(x), @as(f32, @bitCast(out[4 * t + 1])));
        try testing.expectEqual(@trunc(x), @as(f32, @bitCast(out[4 * t + 2])));
        try testing.expectEqual(even, @as(f32, @bitCast(out[4 * t + 3])));
    }
    try testing.expectEqual(@as(u32, 64), counters[0]);
    try testing.expectEqual(@as(u32, 0), counters[1]);
    try testing.expectEqual(@as(u32, 63), counters[2]);
    try testing.expect(counters[3] < 64); // (some thread's, the last to run)
    try testing.expectEqual(@as(u32, 63 * 64 / 2), counters[4]);
    try testing.expectEqual(@as(u32, 10), counters[5]);
}

test "a launch the GPU would not take" {
    const regions = [_]Region{};
    var l = Launch{ .block = .{ 1024, 1, 1 }, .registers = 128 };
    try testing.expectError(error.BadLaunch, runText("[B------:R-:W-:-:S01] MOV R100, RZ\n[B------:R-:W-:Y:S05] EXIT", &l, &regions));
    l.registers = 64;
    try testing.expectError(error.BadLaunch, runText("[B------:R-:W-:-:S01] MOV R100, RZ\n[B------:R-:W-:Y:S05] EXIT", &l, &regions));
    l.block = .{ 1025, 1, 1 };
    try testing.expectError(error.BadLaunch, runText("[B------:R-:W-:Y:S05] EXIT", &l, &regions));
}

// ── Tests: graphics stages ──────────────────────────────────────────────────

/// sm120_asm's textured rectangle's vertex program (its test's VERTEX,
/// the first the driver draws with): a position and a texture coordinate
/// from the vertex buffers' attributes 0 and 1, stored as the position and
/// generic vector 0's x and y.
const VERTEX =
    \\ALD.128 R4, a[0x80]               // attribute 0: x, y, z, w
    \\ALD.64 R8, a[0x90]                // attribute 1: u, v
    \\AST.128 a[0x70], R4               // the position
    \\AST.64 a[0x80], R8                // generic 0
    \\EXIT
;

/// A vertex program that reads nothing but its index: a rectangle's
/// corner from the index's low two bits (u its bit 0, v the rest; the
/// position 2u - 1, 2v - 1, 0, 1).
const VERTEX_ID =
    \\ALD R0, a[0x2fc]                  // the vertex's index
    \\LOP3.LUT R1, R0, 0x1, RZ, 0xc0, !PT
    \\SHF.R.U32.HI R2, RZ, 0x1, R0
    \\I2FP.F32.S32 R8, R1               // u
    \\I2FP.F32.S32 R9, R2               // v
    \\FMUL R4, R8, 2
    \\FADD R4, R4, -1                   // x
    \\FMUL R5, R9, 2
    \\FADD R5, R5, -1                   // y
    \\MOV R6, RZ                        // z
    \\MOV R7, 0x3f800000                // w
    \\AST.128 a[0x70], R4
    \\AST.64 a[0x80], R8
    \\EXIT
;

/// sm120_asm's pixel program for the same rectangle (its test's PIXEL): u
/// and v carried in perspective, a texel through the handle in constant
/// buffer 1, pixels under half alpha discarded, the colour left in R0..R3.
const PIXEL =
    \\IPA.PASS R0, a[0x7c]              // 1/w
    \\IPA.PASS R4, a[0x80]              // u/w
    \\IPA.PASS R5, a[0x84]              // v/w
    \\MUFU.RCP R0, R0
    \\FMUL.RZ R4, R4, R0
    \\FMUL.RZ R5, R5, R0
    \\LDC R6, c[0x1][0x10]              // the texture's handle
    \\TEX.B.DXY R2, R0, R4, R6, 2D      // red, green in R0, R1; blue, alpha in R2, R3
    \\FSETP.LT.AND P0, PT, R3, 0.5, PT
    \\@P0 KILL
    \\EXIT
;

/// The tests' threads' words, the words sm120_asm assembles into, and
/// what the texture callbacks were called with.
const StageTest = struct {
    /// The most threads a test runs.
    const THREADS = 80;
    /// A Stage's slices: each thread's words in and out, the stored words'
    /// bits, the discarded pixels.
    var in: [THREADS][ATTR_WORDS]u32 = undefined;
    var out: [THREADS][ATTR_WORDS]u32 = undefined;
    var stored: [THREADS][ATTR_WORDS / 32]u32 = undefined;
    var killed: [THREADS]bool = undefined;
    /// A scheduled program's words.
    var code: [64]u64 = undefined;
    /// The callbacks' calls so far, and what each was given.
    var calls: usize = 0;
    var handles: [THREADS]u32 = undefined;
    var xs: [THREADS]f32 = undefined;
    var ys: [THREADS]f32 = undefined;
    var lods: [THREADS]i32 = undefined;

    /// A texture whose colour says what it was asked: x + 1, 2 y, the
    /// texture's index plus the sampler's, and an alpha under a half only
    /// at x = 0.75.
    fn sample(_: ?*anyopaque, handle: u32, x: f32, y: f32) Error![4]f32 {
        handles[calls] = handle;
        xs[calls] = x;
        ys[calls] = y;
        calls += 1;
        return .{ x + 1, y * 2, @floatFromInt((handle & 0xfffff) + (handle >> 20)), if (x == 0.75) 0.25 else 1 };
    }

    /// A texel that says where it was fetched: x, y, the level, the
    /// texture's index.
    fn fetch(_: ?*anyopaque, handle: u32, x: i32, y: i32, lod: i32) Error![4]f32 {
        handles[calls] = handle;
        lods[calls] = lod;
        calls += 1;
        return .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(lod), @floatFromInt(handle & 0xfffff) };
    }

    /// A vertex stage over the first `n` threads' words.
    fn vertex(header: ?*const [sph.WORDS]u32, n: usize) Stage {
        return .{ .kind = .vertex, .header = header, .in = in[0..n], .out = out[0..n], .stored = stored[0..n] };
    }

    /// A pixel stage over the first `n` threads' words, with `sample`.
    fn pixel(header: ?*const [sph.WORDS]u32, n: usize) Stage {
        return .{ .kind = .pixel, .header = header, .in = in[0..n], .killed = killed[0..n], .sample = &sample };
    }
};

/// A float's bits, as a register holds them.
fn bitsOf(x: f32) u32 {
    return @bitCast(x);
}

/// The loaded program run as `s`'s stage for `n` threads.
fn stage(s: *const Stage, n: u32) Error!Stats {
    const mem = Memory{ .regions = &.{} };
    var stats = Stats{};
    try stageBegin(&test_work, n);
    try stageRun(&test_work, &mem, s, n, &stats);
    return stats;
}

/// The same, for a run that must pass: its error's sentence printed.
fn runStage(s: *const Stage, n: u32) !Stats {
    return stage(s, n) catch |e| {
        var buf: [256]u8 = undefined;
        std.debug.print("stage: {s}: {s}\n", .{ @errorName(e), explain(&test_work, &buf) });
        return e;
    };
}

/// `text` without control fields, assembled and scheduled by sm120_asm
/// and loaded: the path a driver's programs take.
fn loadScheduled(text: []const u8) !void {
    const k = try sm120_asm.assemble(text, &StageTest.code, &test_asm);
    try testing.expect(k.scheduled);
    try loadAssembled(&test_work, &test_asm, k);
}

/// `text` as one stage's whole program refused: the error, and why.
fn expectRefused(text: []const u8, s: *const Stage, e: Error, why: Why) !void {
    try loadText(&test_work, text);
    try testing.expectError(e, stage(s, 1));
    if (test_work.trap.why != why) {
        var buf: [256]u8 = undefined;
        std.debug.print("\"{s}\": {s}\n", .{ text, explain(&test_work, &buf) });
    }
    try testing.expectEqual(why, test_work.trap.why);
}

test "a vertex stage: the assembler's rectangle program stores each vertex's position and coordinates" {
    const S = StageTest;
    const pos = [4][4]f32{ .{ -1, -1, 0, 1 }, .{ 1, -1, 0, 1 }, .{ -1, 1, 0.5, 1 }, .{ 1, 1, 0.5, 2 } };
    const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    var v = sph.Vertex{};
    v.in_generic[0] = 0xf;
    v.in_generic[1] = 0x3;
    v.out_generic[0] = 0x3;
    const header = sph.vertex(v);
    const s = S.vertex(&header, 4);
    // (as written, each line with the safe control field; then as sm120_asm
    // schedules it, at the hardware's level and at NAK's)
    for (0..3) |pass| {
        for (0..4) |t| {
            S.in[t] = @splat(0x5555_5555);
            S.in[t][0x2fc / 4] = @intCast(t);
            for (pos[t], 0..) |x, k| S.in[t][0x80 / 4 + k] = bitsOf(x);
            for (uv[t], 0..) |x, k| S.in[t][0x90 / 4 + k] = bitsOf(x);
            S.out[t] = @splat(0xaaaa_aaaa);
            S.stored[t] = @splat(0xffff_ffff);
        }
        if (pass == 0) try loadText(&test_work, VERTEX) else try loadScheduled(VERTEX);
        test_work.strict = pass == 2;
        defer test_work.strict = false;
        const stats = try runStage(&s, 4);
        try testing.expectEqual(@as(u64, 1), stats.warps);
        try testing.expectEqual(@as(u64, 5), stats.instructions);
        try testing.expectEqual(@as(u64, 20), stats.thread_instructions);
        for (0..4) |t| {
            // the position: words 0x70..0x7c; generic 0's x and y: 0x80, 0x84
            for (pos[t], 0..) |x, k| try testing.expectEqual(bitsOf(x), S.out[t][0x70 / 4 + k]);
            for (uv[t], 0..) |x, k| try testing.expectEqual(bitsOf(x), S.out[t][0x80 / 4 + k]);
            // nothing else: the words beside them as they were, and exactly
            // those six recorded (words 28..31, 32 and 33)
            try testing.expectEqual(@as(u32, 0xaaaa_aaaa), S.out[t][0x6c / 4]);
            try testing.expectEqual(@as(u32, 0xaaaa_aaaa), S.out[t][0x88 / 4]);
            try testing.expectEqual([6]u32{ 0xf000_0000, 0x3, 0, 0, 0, 0 }, S.stored[t]);
        }
        if (pass == 0) continue;
        // (scheduled, the first store waits on its load's scoreboard and
        // sets the same one again for its own reads: the wait counts first)
        const ast = test_work.ops[2].control;
        try testing.expectEqual(Kind.ast, test_work.ops[2].kind);
        try testing.expect(ast.read != NONE and ast.wait & (@as(u6, 1) << ast.read) != 0);
    }
}

test "a vertex stage: a program that reads its index, over three warps" {
    const S = StageTest;
    var v = sph.Vertex{ .vertex_id = true };
    v.out_generic[0] = 0x3;
    const header = sph.vertex(v);
    const n = 70;
    const s = S.vertex(&header, n);
    // (indices 0..3 are the rectangle's corners: u, v, then x, y)
    const corners = [4][4]f32{ .{ 0, 0, -1, -1 }, .{ 1, 0, 1, -1 }, .{ 0, 1, -1, 1 }, .{ 1, 1, 1, 1 } };
    for (0..3) |pass| {
        for (0..n) |t| {
            S.in[t] = @splat(0);
            S.in[t][0x2fc / 4] = @intCast(t);
        }
        if (pass == 0) try loadText(&test_work, VERTEX_ID) else try loadScheduled(VERTEX_ID);
        test_work.strict = pass == 2;
        defer test_work.strict = false;
        const stats = try runStage(&s, n);
        try testing.expectEqual(@as(u64, 3), stats.warps);
        for (0..n) |t| {
            // u is the index's bit 0, v the bits above it
            const u: f32 = @floatFromInt(t & 1);
            const vv: f32 = @floatFromInt(t >> 1);
            const want = if (t < 4) corners[t] else [4]f32{ u, vv, 2 * u - 1, 2 * vv - 1 };
            try testing.expectEqual(bitsOf(want[2]), S.out[t][0x70 / 4]);
            try testing.expectEqual(bitsOf(want[3]), S.out[t][0x74 / 4]);
            try testing.expectEqual(@as(u32, 0), S.out[t][0x78 / 4]);
            try testing.expectEqual(@as(u32, 0x3f80_0000), S.out[t][0x7c / 4]);
            try testing.expectEqual(bitsOf(want[0]), S.out[t][0x80 / 4]);
            try testing.expectEqual(bitsOf(want[1]), S.out[t][0x84 / 4]);
            try testing.expectEqual([6]u32{ 0xf000_0000, 0x3, 0, 0, 0, 0 }, S.stored[t]);
        }
    }
}

test "a pixel stage: the assembler's program carries, samples through the handle and discards" {
    const S = StageTest;
    // each pixel's 1/w, u/w and v/w as the engine carries them, and the u
    // and v the program must get by multiplying with w (all exact)
    const inv_w = [8]f32{ 1, 0.5, 0.25, 0.5, 2, 0.125, 4, 1 };
    const u_w = [8]f32{ 0, 0.125, 0.125, 0.375, 2, 0.015625, 1.5, 0.625 };
    const v_w = [8]f32{ 0, 0.25, 0.0625, 0.5, 1, 0.09375, 3.5, 0.125 };
    const u = [8]f32{ 0, 0.25, 0.5, 0.75, 1, 0.125, 0.375, 0.625 };
    const v = [8]f32{ 0, 0.5, 0.25, 1, 0.5, 0.75, 0.875, 0.125 };
    // the handle: sampler 3, texture 7
    var cb1 = [_]u32{0x1111_1111} ** 8;
    cb1[0x10 / 4] = 0x0030_0007;
    var p = sph.Pixel{ .kills = true };
    p.in_generic[0] = .{ .perspective, .perspective, .unused, .unused };
    const header = sph.pixel(p);
    var s = S.pixel(&header, 8);
    s.cbufs[1] = std.mem.sliceAsBytes(&cb1);
    for (0..3) |pass| {
        for (0..8) |t| {
            S.in[t] = @splat(0x5555_5555);
            S.in[t][0x7c / 4] = bitsOf(inv_w[t]);
            S.in[t][0x80 / 4] = bitsOf(u_w[t]);
            S.in[t][0x84 / 4] = bitsOf(v_w[t]);
            S.killed[t] = true;
        }
        S.calls = 0;
        if (pass == 0) try loadText(&test_work, PIXEL) else try loadScheduled(PIXEL);
        test_work.strict = pass == 2;
        defer test_work.strict = false;
        _ = try runStage(&s, 8);
        // the callback: once a pixel, in order, with the constant buffer's
        // handle and the pixel's u and v
        try testing.expectEqual(@as(usize, 8), S.calls);
        for (0..8) |t| {
            try testing.expectEqual(@as(u32, 0x0030_0007), S.handles[t]);
            try testing.expectEqual(u[t], S.xs[t]);
            try testing.expectEqual(v[t], S.ys[t]);
        }
        // the colour in R0..R3: u + 1, 2 v, 7 + 3, and the alpha, under a
        // half only for the pixel at u = 0.75, which alone is discarded
        for (0..8) |ti| {
            const t: u32 = @intCast(ti);
            try testing.expectEqual(bitsOf(u[t] + 1), threadReg(&test_work, t, 0));
            try testing.expectEqual(bitsOf(v[t] * 2), threadReg(&test_work, t, 1));
            try testing.expectEqual(bitsOf(10), threadReg(&test_work, t, 2));
            try testing.expectEqual(bitsOf(if (t == 3) 0.25 else 1), threadReg(&test_work, t, 3));
            try testing.expectEqual(t == 3, S.killed[t]);
        }
    }
}

test "textures: the channel mask, a result over its sources, a texel fetch at a level" {
    const S = StageTest;
    var s = S.pixel(null, 1);
    s.fetch = &S.fetch;
    S.in[0] = @splat(0);
    // red, green and alpha: three registers in order, the first two from
    // Rd0, the third in Rd1; the register after it is left alone
    S.calls = 0;
    try loadText(&test_work,
        \\MOV R4, 0x3f000000
        \\MOV R5, 0x3e800000
        \\MOV R6, 0x00100002
        \\TEX.B.LZ R2, R0, R4, R6, 2D, 0xb
        \\EXIT
    );
    _ = try runStage(&s, 1);
    try testing.expectEqual(@as(f32, 0.5), S.xs[0]);
    try testing.expectEqual(@as(f32, 0.25), S.ys[0]);
    try testing.expectEqual([4]u32{ bitsOf(1.5), bitsOf(0.5), bitsOf(1), POISON }, test_work.regs[0][0..4].*);
    // red and blue alone: both in Rd0's pair, and Rd1 is RZ
    try loadText(&test_work,
        \\MOV R4, 0x3f000000
        \\MOV R5, 0x3e800000
        \\MOV R6, 0x00100002
        \\TEX.B.DXY.NODEP RZ, R0, R4, R6, 2D, 0x5
        \\EXIT
    );
    _ = try runStage(&s, 1);
    try testing.expectEqual([3]u32{ bitsOf(1.5), bitsOf(3), POISON }, test_work.regs[0][0..3].*);
    // the result over the coordinates and the handle: read first
    try loadText(&test_work,
        \\MOV R0, 0x3f000000
        \\MOV R1, 0x3e800000
        \\MOV R2, 0x00100002
        \\TEX.B.NDV R2, R0, R0, R2, 2D
        \\EXIT
    );
    _ = try runStage(&s, 1);
    try testing.expectEqual([4]u32{ bitsOf(1.5), bitsOf(0.5), bitsOf(3), bitsOf(1) }, test_work.regs[0][0..4].*);
    // a texel: integer coordinates, the level after the handle (.LL) or 0
    S.calls = 0;
    try loadText(&test_work,
        \\MOV R4, 0x9
        \\MOV R5, -0x2
        \\MOV R6, 0x00100002
        \\MOV R7, 0x3
        \\TLD.B.LL R2, R0, R4, R6, 2D
        \\TLD.B.LZ R10, R8, R4, R6, 2D
        \\EXIT
    );
    _ = try runStage(&s, 1);
    try testing.expectEqual([4]u32{ bitsOf(9), bitsOf(-2), bitsOf(3), bitsOf(2) }, test_work.regs[0][0..4].*);
    try testing.expectEqual(bitsOf(0), test_work.regs[0][10]);
    try testing.expectEqual([2]i32{ 3, 0 }, S.lods[0..2].*);
    try testing.expectEqual(@as(u32, 0x0010_0002), S.handles[1]);
}

test "a stage refuses a load its header does not declare" {
    const S = StageTest;
    for (0..4) |t| S.in[t] = @splat(0);
    // attribute 1's words are loaded and not declared
    var v = sph.Vertex{};
    v.in_generic[0] = 0xf;
    v.out_generic[0] = 0x3;
    var header = sph.vertex(v);
    try loadText(&test_work, VERTEX);
    try testing.expectError(error.HeaderMismatch, stage(&S.vertex(&header, 4), 4));
    try testing.expectEqual(What.header, test_work.trap.what);
    try testing.expectEqual(Why.load_undeclared, test_work.trap.why);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.pc);
    try testing.expectEqual(@as(u16, 0x90), test_work.trap.attr);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "loads attribute word 0x90, which the header does not declare") != null);
    // without a header nothing is held against it
    _ = try runStage(&S.vertex(null, 4), 4);
    // a pixel program's v, read and not declared
    var p = sph.Pixel{ .kills = true };
    p.in_generic[0] = .{ .perspective, .unused, .unused, .unused };
    header = sph.pixel(p);
    try loadText(&test_work, PIXEL);
    try testing.expectError(error.HeaderMismatch, stage(&S.pixel(&header, 1), 1));
    try testing.expectEqual(Why.load_undeclared, test_work.trap.why);
    try testing.expectEqual(@as(u16, 0x84), test_work.trap.attr);
    // a word the header keeps flat read as a carried one, and the other way
    p.in_generic[0] = .{ .perspective, .constant, .unused, .unused };
    header = sph.pixel(p);
    try testing.expectError(error.HeaderMismatch, stage(&S.pixel(&header, 1), 1));
    try testing.expectEqual(Why.interpolation, test_work.trap.why);
    try testing.expectEqual(@as(u64, 0x20), test_work.trap.pc);
    try expectRefused("IPA.CONSTANT R0, a[0x80]\nEXIT", &S.pixel(&header, 1), error.HeaderMismatch, .interpolation);
    // (flat where the header says flat; the position's w is a word either way)
    try loadText(&test_work, "IPA.CONSTANT R0, a[0x84]\nIPA.CONSTANT R1, a[0x7c]\nIPA.PASS R2, a[0x7c]\nIPA.PASS R3, a[0x80]\nEXIT");
    _ = try runStage(&S.pixel(&header, 1), 1);
    // a vertex program that loads after a store, under a header that says
    // it has no such load
    const late = "ALD.128 R4, a[0x80]\nAST.128 a[0x70], R4\nALD.64 R8, a[0x90]\nAST.64 a[0x80], R8\nEXIT";
    v.in_generic[1] = 0x3;
    header = sph.vertex(v);
    try expectRefused(late, &S.vertex(&header, 1), error.HeaderMismatch, .load_after_store);
    try testing.expectEqual(@as(u64, 0x20), test_work.trap.pc);
    v.loads_before_stores = false;
    header = sph.vertex(v);
    try loadText(&test_work, late);
    _ = try runStage(&S.vertex(&header, 1), 1);
}

test "a pixel program's facing: IPA.CONSTANT a[0x3fc], all ones for a front face, 0 for a back one; read carried, refused" {
    const S = StageTest;
    for (0..2) |t| S.in[t] = @splat(0);
    const fronts = [_]bool{ true, false };
    var ps = S.pixel(null, 2);
    ps.front = &fronts;
    try loadText(&test_work, "IPA.CONSTANT R0, a[0x3fc]\nEXIT");
    _ = try runStage(&ps, 2);
    try testing.expectEqual(@as(u32, 0xffff_ffff), threadReg(&test_work, 0, 0));
    try testing.expectEqual(@as(u32, 0), threadReg(&test_work, 1, 0));
    // (under a header: still no bit of it needed)
    const header = sph.pixel(.{ .targets = @splat(0) });
    ps.header = &header;
    _ = try runStage(&ps, 2);
    try expectRefused("IPA.PASS R0, a[0x3fc]\nEXIT", &ps, error.HeaderMismatch, .interpolation);
}

test "a stage refuses a store its header does not declare, and an end without one it declares" {
    const S = StageTest;
    for (0..4) |t| S.in[t] = @splat(0);
    var v = sph.Vertex{};
    v.in_generic[0] = 0xf;
    v.in_generic[1] = 0x3;
    // generic 0's y is stored and not declared
    v.out_generic[0] = 0x1;
    var header = sph.vertex(v);
    try loadText(&test_work, VERTEX);
    try testing.expectError(error.HeaderMismatch, stage(&S.vertex(&header, 4), 4));
    try testing.expectEqual(Why.store_undeclared, test_work.trap.why);
    try testing.expectEqual(@as(u64, 0x30), test_work.trap.pc);
    try testing.expectEqual(@as(u16, 0x84), test_work.trap.attr);
    // its z is declared and never stored
    v.out_generic[0] = 0x7;
    header = sph.vertex(v);
    try testing.expectError(error.HeaderMismatch, stage(&S.vertex(&header, 4), 4));
    try testing.expectEqual(Why.store_missing, test_work.trap.why);
    try testing.expectEqual(@as(u16, 0x88), test_work.trap.attr);
    try testing.expectEqual(@as(u64, 0x40), test_work.trap.pc); // (its EXIT)
    // a discard the header does not declare, for the pixel that discards
    var p = sph.Pixel{};
    p.in_generic[0] = .{ .perspective, .perspective, .unused, .unused };
    header = sph.pixel(p);
    var cb1 = [_]u32{0} ** 8;
    var s = S.pixel(&header, 2);
    s.cbufs[1] = std.mem.sliceAsBytes(&cb1);
    S.in[0][0x7c / 4] = bitsOf(1);
    S.in[1][0x7c / 4] = bitsOf(1);
    S.in[1][0x80 / 4] = bitsOf(0.75);
    S.calls = 0;
    try loadText(&test_work, PIXEL);
    try testing.expectError(error.HeaderMismatch, stage(&s, 2));
    try testing.expectEqual(Why.kill_undeclared, test_work.trap.why);
    try testing.expectEqual(@as(u32, 1), test_work.trap.thread);
    // a colour's register the header declares and the program never wrote
    try expectRefused("IPA.PASS R0, a[0x7c]\nMOV R2, R0\nMOV R3, R0\nEXIT", &S.pixel(&header, 1), error.HeaderMismatch, .colour_missing);
    try testing.expectEqual(@as(u8, 1), test_work.trap.reg);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "R1 never written") != null);
}

test "a stage refuses the other stage's instructions, and a header of the other kind" {
    const S = StageTest;
    S.in[0] = @splat(0);
    const vertex = S.vertex(null, 1);
    const pixel = S.pixel(null, 1);
    // ALD in a pixel program
    try expectRefused("ALD R0, a[0x2fc]\nEXIT", &pixel, error.BadInstruction, .wrong_stage);
    try testing.expectEqual(What.bad_instruction, test_work.trap.what);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "the other stage's instruction") != null);
    try expectRefused("AST a[0x70], R0\nEXIT", &pixel, error.BadInstruction, .wrong_stage);
    // IPA, PIXLD and KILL in a vertex program
    try expectRefused("IPA.PASS R0, a[0x7c]\nEXIT", &vertex, error.BadInstruction, .wrong_stage);
    try expectRefused("PIXLD.COVMASK R0\nEXIT", &vertex, error.BadInstruction, .wrong_stage);
    try expectRefused("KILL\nEXIT", &vertex, error.BadInstruction, .wrong_stage);
    // a pixel Stage with a vertex program's header, a header that is
    // neither, and a pixel program's that does not read the position's w
    var header = sph.vertex(.{});
    try loadText(&test_work, "EXIT");
    try testing.expectError(error.BadLaunch, stage(&S.pixel(&header, 1), 1));
    try testing.expectEqual(Why.header_kind, test_work.trap.why);
    header = @splat(0);
    try testing.expectError(error.BadLaunch, stage(&S.vertex(&header, 1), 1));
    header = sph.pixel(.{ .targets = @splat(0) });
    header[5] = 0;
    try testing.expectError(error.BadLaunch, stage(&S.pixel(&header, 1), 1));
    try testing.expectEqual(Why.header_kind, test_work.trap.why);
    // stageRun without its stageBegin, or for other threads than it began
    const mem = Memory{ .regions = &.{} };
    var stats = Stats{};
    try testing.expectError(error.BadLaunch, stageRun(&test_work, &mem, &vertex, 1, &stats));
    try testing.expectEqual(Why.threads, test_work.trap.why);
    try stageBegin(&test_work, 2);
    try testing.expectError(error.BadLaunch, stageRun(&test_work, &mem, &vertex, 1, &stats));
    try testing.expectError(error.BadLaunch, stageBegin(&test_work, MAX_THREADS + 1));
    // (and with slices shorter than the threads)
    try testing.expectError(error.BadLaunch, stage(&S.vertex(null, 1), 2));
}

test "a compute launch refuses a graphics stage's instruction; a stage refuses a compute launch's" {
    const l = Launch{};
    const mem = Memory{ .regions = &.{} };
    var buf: [256]u8 = undefined;
    for ([_][]const u8{
        "ALD R0, a[0x2fc]",
        "AST a[0x70], R0",
        "IPA.PASS R0, a[0x7c]",
        "PIXLD.COVMASK R0",
        "KILL",
        "TEX.B.DXY R2, R0, R4, R6, 2D",
        "TLD.B.LZ R2, R0, R4, R6, 2D",
    }) |text| {
        var stats = Stats{};
        try loadText(&test_work, text);
        try testing.expectError(error.BadInstruction, run(&test_work, &mem, &l, &stats));
        try testing.expectEqual(What.bad_instruction, test_work.trap.what);
        try testing.expectEqual(Why.stage_only, test_work.trap.why);
        try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "a graphics stage's instruction in a compute launch") != null);
    }
    // a barrier, shared memory, the thread's and the CTA's place
    const S = StageTest;
    S.in[0] = @splat(0);
    const pixel = S.pixel(null, 1);
    for ([_][]const u8{
        "BAR.SYNC.DEFER_BLOCKING 0x0",
        "LDS R0, [RZ+0x400]",
        "STS [RZ+0x400], R0",
        "ATOMS.ADD R1, [RZ+0x400], R0",
        "S2R R0, SR_TID.X",
        "S2UR UR4, SR_CTAID.Y",
    }) |text| {
        try expectRefused(text, &pixel, error.BadInstruction, .compute_only);
        try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "a compute launch's instruction") != null);
    }
    // (a Stage has no local memory, and constant buffers 0..7 only)
    try expectRefused("LDL R0, [RZ]", &pixel, error.Unsupported, .no_data);
    try expectRefused("LDC R0, c[0x9][0x0]", &pixel, error.Unsupported, .form);
    // what belongs to neither still runs in a stage: a lane's index, a
    // branch, a constant
    try loadText(&test_work,
        \\S2R R0, SR_LANEID
        \\ISETP.NE.AND P0, PT, R0, RZ, PT
        \\@P0 BRA `(odd)
        \\MOV R0, 0x7
        \\odd:
        \\EXIT
    );
    S.in[1] = @splat(0);
    _ = try runStage(&S.pixel(null, 2), 2);
    try testing.expectEqual([2]u32{ 7, 1 }, [2]u32{ threadReg(&test_work, 0, 0), threadReg(&test_work, 1, 0) });
}

test "a texture instruction without its callback, and the forms that are not run" {
    const S = StageTest;
    S.in[0] = @splat(0);
    var pixel = S.pixel(null, 1);
    const vertex = S.vertex(null, 1);
    const regs = "MOV R4, RZ\nMOV R5, RZ\nMOV R6, RZ\nMOV R7, RZ\n";
    // TEX with no `sample`, TLD with no `fetch`
    pixel.sample = null;
    try expectRefused(regs ++ "TEX.B.DXY R2, R0, R4, R6, 2D\nEXIT", &pixel, error.Unsupported, .no_callback);
    try testing.expectEqual(What.unsupported, test_work.trap.what);
    try testing.expectEqual(@as(u64, 0x40), test_work.trap.pc);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "no callback") != null);
    try expectRefused(regs ++ "TLD.B.LZ R2, R0, R4, R6, 2D\nEXIT", &pixel, error.Unsupported, .no_callback);
    pixel.sample = &S.sample;
    pixel.fetch = &S.fetch;
    // the forms of each instruction that are not run
    for ([_]struct { []const u8, *const Stage, Why }{
        .{ "IPA.STATE R0, a[0x80]", &pixel, .form },
        .{ "IPA.PASS R0, P1, a[0x80]", &pixel, .form },
        .{ "IPA.PASS.CENTROID R0, a[0x80]", &pixel, .no_data },
        .{ "IPA.PASS.OFFSET R0, a[0x80], R9", &pixel, .no_data },
        .{ "IPA.CONSTANT R6, a[0x3fc]", &pixel, .no_data },
        .{ "IPA.CONSTANT R6, a[0x3f8]", &pixel, .address },
        .{ "PIXLD R0", &pixel, .no_data },
        .{ "PIXLD.COVMASK R0", &pixel, .no_data },
        .{ "PIXLD.MY_INDEX R0, P0", &pixel, .no_data },
        .{ "KILL P1", &pixel, .form },
        .{ "ALD.O R4, a[0x88]", &vertex, .form },
        .{ "ALD.P R5, a[R7+0x20]", &vertex, .form },
        .{ "ALD.PHYS R5, a[R7]", &vertex, .form },
        .{ "ALD R4, a[0x80], R9", &vertex, .form },
        .{ "ALD.128 R4, a[0x84]", &vertex, .address },
        .{ "ALD.64 R4, a[0x2fc]", &vertex, .address },
        .{ "ALD.64 R254, a[0x80]", &vertex, .form },
        .{ "AST.P a[0x20], R4", &vertex, .form },
        .{ "AST a[0x70], R4, R9", &vertex, .form },
        .{ "AST.64 a[0x74], R4", &vertex, .address },
        .{ "AST a[0x300], R4", &vertex, .address },
        .{ "TEX.B.LL R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.LB R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.AOFFI.DXY R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.DC.DXY R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.EF.DXY R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.SCR.B.DXY R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.DXY R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.DXY R2, R0, R4, R6, 3D", &pixel, .form },
        .{ "TEX.B.DXY R2, R0, R4, R6, CUBE", &pixel, .form },
        .{ "TEX.B.DXY P0, R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TEX.B.DXY R2, R0, R4, R6, UR3, 2D", &pixel, .form },
        .{ "TEX.B.DXY R2, R0, R254, R6, 2D", &pixel, .form },
        .{ "TLD.B.ULL R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TLD.B.LZ.MS R2, R0, R4, R6, 2D", &pixel, .form },
        .{ "TLD.B.LZ R2, R0, R4, R6, ARRAY_2D", &pixel, .form },
    }) |c| {
        var text: [96]u8 = undefined;
        try expectRefused(try std.fmt.bufPrint(&text, "{s}\nEXIT", .{c[0]}), c[1], error.Unsupported, c[2]);
    }
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "a form of the instruction the emulator does not run") != null);
    // what nvdisasm calls illegal is a bad instruction: an index register
    // without .P or .PHYS, a texture's source RZ, a fetch without a level
    for ([_][]const u8{ "ALD R5, a[R7+0x20]", "AST.PHYS a[0x70], R4", "IPA R0, a[0x7c]", "IPA.PASS R0, a[0x7e]", "TEX.B.DXY R2, R0, R4, RZ, 2D", "TLD.B R2, R0, R4, R6, 2D" }) |text| {
        try expectRefused(text, if (text[0] == 'A') &vertex else &pixel, error.BadInstruction, .none);
    }
}

test "a stage's hazards: a result consumed without waiting on its scoreboard, a stored register overwritten, an EXIT with one out" {
    const S = StageTest;
    S.in[0] = @splat(0x3f80_0000);
    var buf: [256]u8 = undefined;
    var text: [512]u8 = undefined;
    const pixel = S.pixel(null, 1);
    // an interpolated word read by a multiply that does not wait on the
    // scoreboard the interpolation set
    const carried =
        \\[B------:R-:W0:-:S02] IPA.PASS R4, a[0x80]
        \\[B0-----:R-:W-:-:S06] FMUL.RZ R0, R4, R4
        \\[B------:R-:W-:-:S01] EXIT
    ;
    try loadText(&test_work, carried);
    _ = try runStage(&pixel, 1);
    _ = std.mem.replace(u8, carried, "[B0-----:R-:W-:-:S06] FMUL", "[B------:R-:W-:-:S06] FMUL", &text);
    try loadText(&test_work, text[0..carried.len]);
    try testing.expectError(error.Hazard, stage(&pixel, 1));
    try testing.expectEqual(HazardKind.raw, test_work.trap.hazard);
    try testing.expect(test_work.trap.scoreboard);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.pc);
    try testing.expectEqual(@as(u64, 0), test_work.trap.other_pc);
    try testing.expectEqual(@as(u8, 4), test_work.trap.reg);
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "raw of R4 before the scoreboard of 0x0000 (ipa) was waited on") != null);
    // (and waited on a cycle too soon after it was set)
    _ = std.mem.replace(u8, carried, "W0:-:S02] IPA", "W0:-:S01] IPA", &text);
    try loadText(&test_work, text[0..carried.len]);
    try testing.expectError(error.Hazard, stage(&pixel, 1));
    try testing.expectEqual(HazardKind.wait_too_soon, test_work.trap.hazard);
    // a texture: its handle read before the constant's scoreboard is
    // waited on, and its colour read before its own is
    var cb1 = [_]u32{0x0010_0002} ** 8;
    var tex = S.pixel(null, 1);
    tex.cbufs[1] = std.mem.sliceAsBytes(&cb1);
    const sampled =
        \\[B------:R-:W0:-:S02] LDC R6, c[0x1][0x10]
        \\[B------:R-:W1:-:S02] IPA.PASS R4, a[0x80]
        \\[B------:R-:W2:-:S02] IPA.PASS R5, a[0x84]
        \\[B------:R-:W5:-:S02] IPA.PASS R7, a[0x88]
        \\[B012---:R3:W4:-:S02] TEX.B.DXY R2, R0, R4, R6, 2D
        \\[B---34-:R-:W-:-:S06] FMUL R0, R0, R3
        \\[B-----5:R-:W-:-:S01] EXIT
    ;
    S.calls = 0;
    try loadText(&test_work, sampled);
    // (R7's scoreboard is still out when the texture issues: sm120_sched
    // would count R7 among the coordinates' vector; the texture does not
    // read it, and is not held to it)
    try testing.expect(reads(&(try sched.usesOf(&test_work.src[4])), .gpr, 7));
    try testing.expect(!reads(&test_work.ops[4].uses, .gpr, 7));
    _ = try runStage(&tex, 1);
    try testing.expectEqual(bitsOf(2 * 1), threadReg(&test_work, 0, 0)); // (1 + 1) * alpha 1
    _ = std.mem.replace(u8, sampled, "[B012---:R3:W4:-:S02] TEX", "[B-12---:R3:W4:-:S02] TEX", &text);
    try loadText(&test_work, text[0..sampled.len]);
    try testing.expectError(error.Hazard, stage(&tex, 1));
    try testing.expectEqual(@as(u64, 0x40), test_work.trap.pc);
    try testing.expectEqual(@as(u8, 6), test_work.trap.reg);
    _ = std.mem.replace(u8, sampled, "[B---34-:R-:W-:-:S06] FMUL", "[B---3--:R-:W-:-:S06] FMUL", &text);
    try loadText(&test_work, text[0..sampled.len]);
    try testing.expectError(error.Hazard, stage(&tex, 1));
    try testing.expectEqual(@as(u64, 0x50), test_work.trap.pc);
    try testing.expectEqual(@as(u64, 0x40), test_work.trap.other_pc);
    try testing.expectEqual(@as(u8, 0), test_work.trap.reg);
    // a store waits on its load's scoreboard and sets the same one for its
    // own reads; its register may be overwritten once that is waited on
    const vertex = S.vertex(null, 1);
    const kept =
        \\[B------:R-:W0:-:S02] ALD.128 R4, a[0x80]
        \\[B0-----:R0:W-:-:S02] AST.128 a[0x70], R4
        \\[B0-----:R-:W-:-:S01] MOV R4, RZ
        \\[B------:R-:W-:-:S01] EXIT
    ;
    try loadText(&test_work, kept);
    _ = try runStage(&vertex, 1);
    try testing.expectEqual(@as(u32, 0x3f80_0000), S.out[0][0x70 / 4]);
    _ = std.mem.replace(u8, kept, "[B0-----:R-:W-:-:S01] MOV", "[B------:R-:W-:-:S01] MOV", &text);
    try loadText(&test_work, text[0..kept.len]);
    try testing.expectError(error.Hazard, stage(&vertex, 1));
    try testing.expectEqual(HazardKind.war, test_work.trap.hazard);
    try testing.expectEqual(@as(u64, 0x20), test_work.trap.pc);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.other_pc);
    // (the store without its wait reads the load's registers too soon)
    _ = std.mem.replace(u8, kept, "[B0-----:R0:W-:-:S02] AST", "[B------:R0:W-:-:S02] AST", &text);
    try loadText(&test_work, text[0..kept.len]);
    try testing.expectError(error.Hazard, stage(&vertex, 1));
    try testing.expectEqual(HazardKind.raw, test_work.trap.hazard);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.pc);
    // an EXIT with the store's scoreboard still out
    const open =
        \\[B------:R-:W0:-:S02] ALD.128 R4, a[0x80]
        \\[B0-----:R1:W-:-:S02] AST.128 a[0x70], R4
        \\[B------:R-:W-:-:S01] EXIT
    ;
    try loadText(&test_work, open);
    try testing.expectError(error.Hazard, stage(&vertex, 1));
    try testing.expectEqual(HazardKind.exit_pending, test_work.trap.hazard);
    try testing.expectEqual(@as(u64, 0x20), test_work.trap.pc);
    try testing.expectEqual(@as(u64, 0x10), test_work.trap.other_pc);
    try testing.expectEqual(@as(u8, 1), test_work.trap.reg);
    try testing.expect(std.mem.indexOf(u8, explain(&test_work, &buf), "the program ends with scoreboard 1 still out: 0x0010 (ast) set it") != null);
    // (not held against a program run without the checks)
    test_work.check_hazards = false;
    defer test_work.check_hazards = true;
    _ = try runStage(&vertex, 1);
}

/// Whether every register `a` names is one `b` names, in the same category.
fn usesWithin(a: []const sched.Use, b: []const sched.Use) bool {
    for (a) |x| {
        const found = for (b) |y| {
            if (x.file == y.file and x.n == y.n and x.cat == y.cat) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

test "the graphics stages' reads and writes: sm120_sched's, the emulator's own the same, a texture's without what it does not touch" {
    for ([_][]const u8{
        "ALD R0, a[0x2fc]",
        "ALD.128 R4, a[0x80]",
        "@P1 ALD.96 R4, a[0x80]",
        "AST.128 a[0x70], R4",
        "AST.64 a[0x80], R8",
        "IPA.PASS R0, a[0x7c]",
        "IPA.CONSTANT R6, a[0x90]",
        "IPA.PASS.OFFSET R5, P2, a[0x80], R9",
        "PIXLD.COVMASK R5, P0",
        "@P0 KILL",
        "KILL",
        "TEX.B.DXY R2, R0, R4, R6, 2D",
        "@!P2 TEX.B.LZ RZ, R0, R4, R6, 2D, 0x3",
        "TEX.B.DXY R2, R0, R4, R6, 2D, 0x7",
        "TLD.B.LL R2, R0, R4, R6, 2D",
    }) |text| {
        const in = try sm120.parse(text);
        const op = try compile(&in, null, 1);
        const theirs = try sched.usesOf(&in);
        const own = fallbackUses(&op, &in);
        errdefer std.debug.print("\"{s}\"\n", .{text});
        try testing.expect(theirs.decoupled and own.decoupled and op.uses.decoupled);
        try testing.expect(!op.lsu);
        // what the emulator checks is among what sm120_sched schedules for
        try testing.expect(usesWithin(op.uses.dsts(), theirs.dsts()) and usesWithin(op.uses.srcs(), theirs.srcs()));
        // and its own answer is the one it uses
        try testing.expect(usesWithin(own.dsts(), op.uses.dsts()) and usesWithin(op.uses.dsts(), own.dsts()));
        try testing.expect(usesWithin(own.srcs(), op.uses.srcs()) and usesWithin(op.uses.srcs(), own.srcs()));
        if (op.kind == .tex or op.kind == .tld) continue;
        try testing.expect(usesWithin(theirs.dsts(), op.uses.dsts()) and usesWithin(theirs.srcs(), op.uses.srcs()));
    }
    // a texture's registers: the channels' and no more; two coordinates,
    // the handle, a fetch's level
    const all = try compile(&try sm120.parse("TEX.B.DXY R2, R0, R4, R6, 2D"), null, 1);
    try testing.expectEqual(@as(usize, 4), all.uses.dsts().len);
    try testing.expectEqual(@as(usize, 3), all.uses.srcs().len);
    try testing.expectEqual(@as(?u8, 6), all.top);
    const two = try compile(&try sm120.parse("TEX.B.LZ RZ, R0, R4, R6, 2D, 0x3"), null, 1);
    try testing.expectEqual(@as(usize, 2), two.uses.dsts().len);
    const level = try compile(&try sm120.parse("TLD.B.LL R2, R0, R4, R6, 2D"), null, 1);
    try testing.expectEqual(@as(usize, 4), level.uses.srcs().len);
    try testing.expectEqual(@as(?u8, 7), level.top);
}
