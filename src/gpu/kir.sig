//! @zpm/gpu KIR — the kernel IR every GPU backend compiles from.
//!
//! A kernel is a linear list of instructions over typed virtual registers,
//! with structured control flow (if/else/endif, loop/brk/cont/endloop),
//! built at run time by Sig code into storage the caller owns. Backends do
//! register allocation, scheduling and the target's legalization; the
//! interpreter (kir_interp.sig) is the definition of every op.
//!
//! Operand conventions (what each op reads; `-` means unused, which the
//! helpers fill with `no`):
//!
//!   op            dst      a         b          c        aux
//!   mov           ty       x (bits)  -          -        -
//!   sel           ty       x         y          p        -         dst = p ? x : y
//!   iadd..imax    int      x         y          -        -         (imad: + c)
//!   ineg iabs not int      x         -          -        -
//!   shl shr       int      x         n          -        -         n & 31
//!   bfe           int      x         offset     width    -         offset & 31, width clamped to 32-offset
//!   dot4          int      x         y          acc      Dot4
//!   icmp fcmp     pred     x         y          -        Cmp       ty = the operands' type
//!   pand por      pred     p         q          -        -
//!   pnot          pred     p         -          -        -
//!   f* (2 ops)    f32      x         y          -        -
//!   ffma fmad     f32      x         y          z        -         x*y+z
//!   f* (1 op)     f32      x         -          -        -
//!   cvt           to       x (from)  -          -        Cvt       ty = Cvt.to
//!   tid gid gsize int      -         -          -        axis      gsize: groups in the dispatch
//!   lane subgroup int      -         -          -        -
//!   param         ty       -         -          -        word      the u32 at word aux after the bindings
//!   ld            ty       offset    -          -        Mem
//!   st            -        offset    value      -        Mem       ty = value's type
//!   atom          int      offset    value      Atom     Mem       c = u(@intFromEnum(Atom)); dst = old
//!   cas           int      offset    compare    value    Mem       dst = old; value stored where old == compare
//!   barrier       -        -         -          -        -
//!   shfl          ty       x         lane/mask  -        Shfl
//!   vote          pred     p         -          -        Vote
//!   ballot        u32      p         -          -        word      bit i: lane 32*word+i active with p
//!   if            -        p         -          -        -
//!   brk cont      -        p         -          -        -
//!   else endif loop endloop ret: no operands.
//!
//! `int` is u32 or i32 (the same 32-bit registers; ty says how the op
//! reads them). Registers hold 32 bits: f16 values sit in the low half,
//! preds are 0 or 1. `mov` with a 32-bit ty reinterprets any 32-bit
//! register (the bit cast between f32 and the integers).
//!
//! Memory: the address is binding aux.binding's base + a (a u32 byte
//! offset) + aux.imm, aligned to the access's width. Shared memory has one
//! base (binding 0). 64- and 128-bit accesses move 2 or 4 consecutive
//! registers (Kernel.vec), the lowest address in the first.
//!
//! Exactness: see docs/GPU.md. fadd, fsub, fmul, fdiv and fsqrt are
//! correctly rounded binary32; fdiv and fsqrt are expanded by backends with
//! expandDiv and expandSqrt below, bit-exact on every target.

const std = @import("std");
const device = @import("device.sig");
const Caps = device.Caps;

pub const Ty = enum(u8) { u32, i32, f32, f16, pred };
/// A virtual register.
pub const V = enum(u16) { none = 0xffff, _ };
/// imm: the 32-bit pattern (f32 as its bits).
pub const Arg = union(enum) { reg: V, imm: u32 };

pub const Op = enum(u8) {
    // moves and selection
    mov,
    sel, // sel: dst = c(pred) ? a : b
    // integers (u32: unsigned, i32: signed; wrap mod 2^32)
    iadd,
    isub,
    imul,
    imulhi,
    imad,
    ineg,
    iabs,
    imin,
    imax,
    @"and",
    @"or",
    xor,
    not,
    shl,
    shr, // shr: logical for u32, arithmetic for i32
    bfe, // dst = (a >> b) & ((1 << c) - 1), sign-extended for i32
    dot4, // dst = c + sum_i a.byte[i] * b.byte[i]; aux: Dot4 (s8u8, s8s8, u8u8)
    icmp,
    fcmp, // dst (pred) = a <aux:Cmp> b; fcmp ordered (NaN: false, ne: true)
    pand,
    por,
    pnot,
    // f32, IEEE binary32, round to nearest even, unless the op says otherwise
    fadd,
    fsub,
    fmul,
    ffma, // fused, one rounding: only where Caps.fused_fma (verifier)
    fmad, // a*b+c, rounded once or twice as the GPU's mad is (fast; not exact code)
    fmin,
    fmax,
    fabs,
    fneg,
    ffloor,
    fceil,
    ftrunc,
    frne,
    fdiv,
    fsqrt, // exact IEEE (correctly rounded); the backend expands them
    frcp,
    frsq,
    fexp2,
    flog2,
    fsin,
    fcos, // approximate (see docs/GPU.md for the error bounds)
    cvt, // aux: Cvt (from, to, rounding)
    // ids and parameters
    tid,
    gid,
    gsize, // aux: axis 0..2
    lane,
    subgroup, // lane index, subgroup width (Caps.subgroup)
    param, // dst = the parameter block's u32 at word aux (counted after the bindings)
    // memory: address = binding aux.binding's base + a (u32 byte offset) + aux.imm
    ld,
    st, // aux: Mem (space global|shared, width 8|16|32|64|128 bits, signed)
    // 64/128: dst/src is the first of 2/4 consecutive vregs (Kernel.vec)
    atom, // aux: Mem; c: Atom (add, min, max, xchg, and, or, xor; u32/i32); dst = old value
    barrier, // the whole group, with shared and global memory ordered
    shfl, // aux: Shfl (idx, xor, up, down); dst = a from lane (b)
    vote, // aux: Vote (any|all); dst (pred) over the subgroup's active lanes
    // structured control flow
    @"if",
    @"else",
    endif, // if: a (pred)
    loop,
    brk,
    cont,
    endloop, // brk/cont: when a (pred) is true
    ret,
    // (later ops: after ret, so the earlier ones keep their numbers)
    cas, // aux: Mem (32 bits); dst = old; c stored where old == b; u32/i32
    ballot, // aux: word 0..3; dst (u32) = the active lanes 32*aux.. where a (pred) holds
};

/// The last op (the binary form's bound).
pub const LAST_OP = Op.ballot;

/// (Not `extern`: Arg is a tagged union, which an extern struct cannot
/// hold. A Binary for the interpreter carries instructions in the fixed
/// 24-byte form of encodeInst instead.)
pub const Inst = struct { op: Op, ty: Ty, dst: V, a: Arg, b: Arg, c: Arg, aux: u32 };

pub const Cmp = enum(u8) { eq, ne, lt, le, gt, ge };
pub const Dot4 = enum(u8) { s8u8, s8s8, u8u8 };
pub const Round = enum(u8) { rne, rz, rd, ru };
pub const Cvt = packed struct(u32) { from: Ty, to: Ty, round: Round, _: u8 = 0 };
pub const Space = enum(u2) { global, shared };
pub const Mem = packed struct(u32) {
    binding: u8,
    space: Space,
    width_log2: u3, // 3=8 bit .. 7=128
    signed: bool,
    imm: u18,
};
pub const Shfl = enum(u8) { idx, xor, up, down };
pub const Atom = enum(u8) { add, min, max, xchg, @"and", @"or", xor };
pub const Vote = enum(u8) { any, all };

pub const Error = error{
    TooManyInsts,
    TooManyRegs,
    BadType,
    Unbalanced,
    NeedsFusedFma,
    BadBinding,
    BadOperand,
    /// The group or its shared memory is over the device's limits.
    Limits,
};

/// Caller-owned.
pub const Storage = struct { insts: []Inst, tys: []Ty };

/// An unused operand.
pub const no: Arg = .{ .reg = .none };

pub fn r(v: V) Arg {
    return .{ .reg = v };
}
pub fn u(x: u32) Arg {
    return .{ .imm = x };
}
pub fn f(x: f32) Arg {
    return .{ .imm = @bitCast(x) };
}
pub fn i(x: i32) Arg {
    return .{ .imm = @bitCast(x) };
}

/// A global access through binding `bind`, `bits` wide (8..128).
pub fn global(bind: u8, bits: u8) Mem {
    return .{ .binding = bind, .space = .global, .width_log2 = widthLog2(bits), .signed = false, .imm = 0 };
}
/// A shared-memory access, `bits` wide (8..128).
pub fn shared(bits: u8) Mem {
    return .{ .binding = 0, .space = .shared, .width_log2 = widthLog2(bits), .signed = false, .imm = 0 };
}
fn widthLog2(bits: u8) u3 {
    return switch (bits) {
        8 => 3,
        16 => 4,
        32 => 5,
        64 => 6,
        128 => 7,
        else => 0, // (rejected by the verifier)
    };
}
/// The number of 32-bit registers an access of `m` moves (1, 2 or 4).
pub fn memRegs(m: Mem) u8 {
    return switch (m.width_log2) {
        6 => 2,
        7 => 4,
        else => 1,
    };
}
/// The bindings `k` stores to or does atomics on, bit i for binding i (all
/// bits for a binding of 32 or more): what a run's barriers are decided by
/// (device.Hazards). Loads only read.
pub fn writtenBindings(k: *const Kernel) u32 {
    var mask: u32 = 0;
    for (k.insts[0..k.n]) |in| switch (in.op) {
        .st, .atom, .cas => {
            const m: Mem = @bitCast(in.aux);
            if (m.space != .global) continue;
            mask |= if (m.binding < 32) @as(u32, 1) << @intCast(m.binding) else 0xffff_ffff;
        },
        else => {},
    };
    return mask;
}

test "kir: the bindings a kernel writes" {
    var insts: [16]Inst = undefined;
    var tys: [16]Ty = undefined;
    var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "w", .{ 32, 1, 1 });
    const a = k.binding();
    const b = k.binding();
    const c = k.binding();
    const t = k.tid(0);
    const off = k.op2(.shl, .u32, r(t), u(2));
    const x = k.load(.u32, global(a, 32), r(off));
    k.store(.u32, global(c, 32), r(off), r(x));
    _ = k.atomic(.u32, .add, global(b, 32), r(off), r(x));
    try k.finish();
    try std.testing.expectEqual(@as(u32, 0b110), writtenBindings(&k));
}

/// The bytes an access of `m` moves.
pub fn memBytes(m: Mem) u32 {
    return @as(u32, 1) << (@as(u5, m.width_log2) - 3);
}

pub const Kernel = struct {
    name: []const u8,
    group: [3]u32, // threads per group, fixed when built
    shared_bytes: u32 = 0,
    bindings: u8 = 0, // buffers (u64 addresses) at the start of the parameter block
    param_words: u16 = 0, // u32 words after the bindings
    insts: []Inst,
    n: usize = 0,
    tys: []Ty,
    nv: u16 = 0,
    err: ?Error = null, // sticks; reported by finish()

    pub fn init(s: Storage, name: []const u8, group: [3]u32) Kernel {
        return .{ .name = name, .group = group, .insts = s.insts, .tys = s.tys };
    }

    fn fail(k: *Kernel, e: Error) void {
        if (k.err == null) k.err = e;
    }

    pub fn reg(k: *Kernel, ty: Ty) V {
        if (k.nv >= k.tys.len or k.nv >= 0xffff) {
            k.fail(error.TooManyRegs);
            return .none;
        }
        k.tys[k.nv] = ty;
        k.nv += 1;
        return @enumFromInt(k.nv - 1);
    }

    /// n consecutive registers, the first returned.
    pub fn vec(k: *Kernel, ty: Ty, n: u8) V {
        if (n == 0 or @as(usize, k.nv) + n > k.tys.len or @as(usize, k.nv) + n > 0xffff) {
            k.fail(error.TooManyRegs);
            return .none;
        }
        const first = k.nv;
        for (0..n) |ix| k.tys[first + ix] = ty;
        k.nv += n;
        return @enumFromInt(first);
    }

    /// The register `ix` places after `v` (an element of a vec).
    pub fn at(v: V, ix: u16) V {
        if (v == .none) return .none;
        return @enumFromInt(@intFromEnum(v) + ix);
    }

    /// The next buffer binding.
    pub fn binding(k: *Kernel) u8 {
        if (k.bindings == 0xff) {
            k.fail(error.BadBinding);
            return 0xff;
        }
        k.bindings += 1;
        return k.bindings - 1;
    }

    /// `bytes` of shared memory (aligned to `alignment`, a power of two);
    /// returns their offset.
    pub fn sharedAlloc(k: *Kernel, bytes: u32, alignment: u32) u32 {
        const a = std.mem.alignForward(u32, k.shared_bytes, @max(alignment, 1));
        k.shared_bytes = a + bytes;
        return a;
    }

    pub fn emit(k: *Kernel, inst: Inst) void {
        if (k.n >= k.insts.len) {
            k.fail(error.TooManyInsts);
            return;
        }
        k.insts[k.n] = inst;
        k.n += 1;
    }

    /// The instructions built so far.
    pub fn code(k: *const Kernel) []const Inst {
        return k.insts[0..k.n];
    }

    /// Verifies (types, balance, operands); the first error sticks.
    pub fn finish(k: *Kernel) Error!void {
        if (k.err) |e| return e;
        verifyKernel(k, null) catch |e| {
            k.err = e;
            return e;
        };
    }

    // ── Value helpers: a fresh dst each (SSA style); `set` writes an
    //    existing register (loop-carried values). ──

    fn dstTy(op: Op, ty: Ty) Ty {
        return switch (op) {
            .icmp, .fcmp, .vote => .pred,
            else => ty,
        };
    }

    pub fn op1(k: *Kernel, op: Op, ty: Ty, a: Arg) V {
        return k.op3(op, ty, a, no, no);
    }
    pub fn op2(k: *Kernel, op: Op, ty: Ty, a: Arg, b: Arg) V {
        return k.op3(op, ty, a, b, no);
    }
    pub fn op3(k: *Kernel, op: Op, ty: Ty, a: Arg, b: Arg, c: Arg) V {
        return k.opAux(op, ty, a, b, c, 0);
    }
    pub fn opAux(k: *Kernel, op: Op, ty: Ty, a: Arg, b: Arg, c: Arg, aux: u32) V {
        const d = k.reg(dstTy(op, ty));
        k.emit(.{ .op = op, .ty = ty, .dst = d, .a = a, .b = b, .c = c, .aux = aux });
        return d;
    }
    /// dst = op(a, b, c), dst an existing register (its type is the op's).
    pub fn set(k: *Kernel, dst: V, op: Op, a: Arg, b: Arg, c: Arg) void {
        k.setAux(dst, op, a, b, c, 0);
    }
    pub fn setAux(k: *Kernel, dst: V, op: Op, a: Arg, b: Arg, c: Arg, aux: u32) void {
        const ty: Ty = if (@intFromEnum(dst) < k.nv) k.tys[@intFromEnum(dst)] else .u32;
        // (compares and votes write a pred; their ty is the operands')
        const op_ty: Ty = switch (op) {
            .icmp, .fcmp => argTy(k, a) orelse argTy(k, b) orelse .u32,
            .vote => .pred,
            else => ty,
        };
        k.emit(.{ .op = op, .ty = op_ty, .dst = dst, .a = a, .b = b, .c = c, .aux = aux });
    }

    fn argTy(k: *const Kernel, a: Arg) ?Ty {
        return switch (a) {
            .reg => |v| if (@intFromEnum(v) < k.nv) k.tys[@intFromEnum(v)] else null,
            .imm => null,
        };
    }

    // ── Named shorthands ──

    pub fn mov(k: *Kernel, ty: Ty, a: Arg) V {
        return k.op1(.mov, ty, a);
    }
    /// dst = p ? a : b
    pub fn sel(k: *Kernel, ty: Ty, p: Arg, a: Arg, b: Arg) V {
        return k.op3(.sel, ty, a, b, p);
    }
    /// iadd or fadd by ty.
    pub fn add(k: *Kernel, ty: Ty, a: Arg, b: Arg) V {
        return k.op2(if (ty == .f32) .fadd else .iadd, ty, a, b);
    }
    pub fn sub(k: *Kernel, ty: Ty, a: Arg, b: Arg) V {
        return k.op2(if (ty == .f32) .fsub else .isub, ty, a, b);
    }
    pub fn mul(k: *Kernel, ty: Ty, a: Arg, b: Arg) V {
        return k.op2(if (ty == .f32) .fmul else .imul, ty, a, b);
    }
    /// imad, or fmad (the fast, not exact, multiply-add) for f32.
    pub fn mad(k: *Kernel, ty: Ty, a: Arg, b: Arg, c: Arg) V {
        return k.op3(if (ty == .f32) .fmad else .imad, ty, a, b, c);
    }
    pub fn min(k: *Kernel, ty: Ty, a: Arg, b: Arg) V {
        return k.op2(if (ty == .f32) .fmin else .imin, ty, a, b);
    }
    pub fn max(k: *Kernel, ty: Ty, a: Arg, b: Arg) V {
        return k.op2(if (ty == .f32) .fmax else .imax, ty, a, b);
    }
    /// icmp or fcmp by ty; a pred.
    pub fn cmp(k: *Kernel, ty: Ty, c: Cmp, a: Arg, b: Arg) V {
        return k.opAux(if (ty == .f32) .fcmp else .icmp, ty, a, b, no, @intFromEnum(c));
    }
    pub fn cvt(k: *Kernel, from: Ty, to: Ty, round: Round, a: Arg) V {
        const c = Cvt{ .from = from, .to = to, .round = round };
        return k.opAux(.cvt, to, a, no, no, @bitCast(c));
    }
    pub fn tid(k: *Kernel, axis: u2) V {
        return k.opAux(.tid, .u32, no, no, no, axis);
    }
    pub fn gid(k: *Kernel, axis: u2) V {
        return k.opAux(.gid, .u32, no, no, no, axis);
    }
    pub fn gsize(k: *Kernel, axis: u2) V {
        return k.opAux(.gsize, .u32, no, no, no, axis);
    }
    pub fn lane(k: *Kernel) V {
        return k.op1(.lane, .u32, no);
    }
    pub fn subgroupWidth(k: *Kernel) V {
        return k.op1(.subgroup, .u32, no);
    }
    /// The parameter word `word` (after the bindings); grows param_words.
    pub fn param(k: *Kernel, ty: Ty, word: u16) V {
        if (word >= k.param_words) k.param_words = word + 1;
        return k.opAux(.param, ty, no, no, no, word);
    }
    /// A load (1 register, or a vec of 2/4 for 64/128 bits).
    pub fn load(k: *Kernel, ty: Ty, m: Mem, off: Arg) V {
        const n = memRegs(m);
        const d = if (n == 1) k.reg(ty) else k.vec(ty, n);
        k.emit(.{ .op = .ld, .ty = ty, .dst = d, .a = off, .b = no, .c = no, .aux = @bitCast(m) });
        return d;
    }
    /// A store of `val` (a register, or the first of a vec for 64/128 bits).
    pub fn store(k: *Kernel, ty: Ty, m: Mem, off: Arg, val: Arg) void {
        k.emit(.{ .op = .st, .ty = ty, .dst = .none, .a = off, .b = val, .c = no, .aux = @bitCast(m) });
    }
    /// An atomic on the 32 bits at `off`; returns the old value.
    pub fn atomic(k: *Kernel, ty: Ty, kind: Atom, m: Mem, off: Arg, val: Arg) V {
        return k.opAux(.atom, ty, off, val, u(@intFromEnum(kind)), @bitCast(m));
    }
    /// A compare-and-swap on the 32 bits at `off`: `val` stored where the
    /// old value equals `expect`; returns the old value.
    pub fn cas(k: *Kernel, ty: Ty, m: Mem, off: Arg, expect: Arg, val: Arg) V {
        return k.opAux(.cas, ty, off, expect, val, @bitCast(m));
    }
    /// The subgroup's active lanes 32*word .. 32*word+31 where `p` holds,
    /// bit i for lane 32*word+i.
    pub fn ballot(k: *Kernel, p: Arg, word: u2) V {
        return k.opAux(.ballot, .u32, p, no, no, word);
    }
    pub fn barrier(k: *Kernel) void {
        k.emit(.{ .op = .barrier, .ty = .u32, .dst = .none, .a = no, .b = no, .c = no, .aux = 0 });
    }
    pub fn shfl(k: *Kernel, ty: Ty, mode: Shfl, a: Arg, b: Arg) V {
        return k.opAux(.shfl, ty, a, b, no, @intFromEnum(mode));
    }
    pub fn vote(k: *Kernel, mode: Vote, p: Arg) V {
        return k.opAux(.vote, .pred, p, no, no, @intFromEnum(mode));
    }
    fn flow(k: *Kernel, op: Op, p: Arg) void {
        k.emit(.{ .op = op, .ty = .pred, .dst = .none, .a = p, .b = no, .c = no, .aux = 0 });
    }
    pub fn ifp(k: *Kernel, p: Arg) void {
        k.flow(.@"if", p);
    }
    pub fn els(k: *Kernel) void {
        k.flow(.@"else", no);
    }
    pub fn endif(k: *Kernel) void {
        k.flow(.endif, no);
    }
    pub fn loop(k: *Kernel) void {
        k.flow(.loop, no);
    }
    /// Lanes where p is true leave the innermost loop.
    pub fn brk(k: *Kernel, p: Arg) void {
        k.flow(.brk, p);
    }
    /// Lanes where p is true go on to the innermost loop's next iteration.
    pub fn cont(k: *Kernel, p: Arg) void {
        k.flow(.cont, p);
    }
    pub fn endloop(k: *Kernel) void {
        k.flow(.endloop, no);
    }
    pub fn ret(k: *Kernel) void {
        k.flow(.ret, no);
    }

    /// dst = a / b, correctly rounded (the fdiv op; backends expand it).
    pub fn div(k: *Kernel, a: Arg, b: Arg) V {
        return k.op2(.fdiv, .f32, a, b);
    }
    pub fn sqrt(k: *Kernel, a: Arg) V {
        return k.op1(.fsqrt, .f32, a);
    }
};

// ── The verifier ────────────────────────────────────────────────────────────

/// Checks `k` (as Kernel.finish does) and, with caps, what the device
/// allows: ffma only where fused_fma, the group and shared memory within
/// the device's limits.
pub fn verify(k: *const Kernel, caps: Caps) Error!void {
    if (k.err) |e| return e;
    return verifyKernel(k, caps);
}

const MAX_DEPTH = 64;

const Want = enum { none, any32, int, f32, pred, ty, from };

const Shape = struct { dst: Want, a: Want = .none, b: Want = .none, c: Want = .none };

fn shape(op: Op) Shape {
    return switch (op) {
        .mov => .{ .dst = .ty, .a = .any32 },
        .sel => .{ .dst = .ty, .a = .ty, .b = .ty, .c = .pred },
        .iadd, .isub, .imul, .imulhi, .imin, .imax, .@"and", .@"or", .xor, .shl, .shr => .{ .dst = .int, .a = .int, .b = .int },
        .imad, .bfe, .dot4 => .{ .dst = .int, .a = .int, .b = .int, .c = .int },
        .ineg, .iabs, .not => .{ .dst = .int, .a = .int },
        .icmp => .{ .dst = .pred, .a = .int, .b = .int },
        .fcmp => .{ .dst = .pred, .a = .f32, .b = .f32 },
        .pand, .por => .{ .dst = .pred, .a = .pred, .b = .pred },
        .pnot => .{ .dst = .pred, .a = .pred },
        .fadd, .fsub, .fmul, .fmin, .fmax, .fdiv => .{ .dst = .f32, .a = .f32, .b = .f32 },
        .ffma, .fmad => .{ .dst = .f32, .a = .f32, .b = .f32, .c = .f32 },
        .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne, .fsqrt, .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos => .{ .dst = .f32, .a = .f32 },
        .cvt => .{ .dst = .ty, .a = .from },
        .tid, .gid, .gsize, .lane, .subgroup => .{ .dst = .int },
        .param => .{ .dst = .ty },
        .ld => .{ .dst = .ty, .a = .int },
        .st => .{ .dst = .none, .a = .int, .b = .ty },
        .atom, .cas => .{ .dst = .int, .a = .int, .b = .int, .c = .int },
        .ballot => .{ .dst = .int, .a = .pred },
        .barrier => .{ .dst = .none },
        .shfl => .{ .dst = .ty, .a = .ty, .b = .int },
        .vote => .{ .dst = .pred, .a = .pred },
        .@"if", .brk, .cont => .{ .dst = .none, .a = .pred },
        .@"else", .endif, .loop, .endloop, .ret => .{ .dst = .none },
    };
}

fn isInt(t: Ty) bool {
    return t == .u32 or t == .i32;
}

/// Whether a register of type `have` may stand where `want` is asked
/// (op type `ty`, cvt's source `from`).
fn fits(want: Want, have: Ty, ty: Ty, from: Ty) bool {
    return switch (want) {
        .none => true,
        .any32 => if (ty == .pred) have == .pred else have != .pred,
        .int => isInt(have),
        .f32 => have == .f32,
        .pred => have == .pred,
        .ty => if (isInt(ty)) isInt(have) else have == ty,
        .from => if (isInt(from)) isInt(have) else have == from,
    };
}

fn checkArg(k: *const Kernel, want: Want, a: Arg, ty: Ty, from: Ty) Error!void {
    if (want == .none) return;
    switch (a) {
        .reg => |v| {
            if (v == .none or @intFromEnum(v) >= k.nv) return error.BadOperand;
            if (!fits(want, k.tys[@intFromEnum(v)], ty, from)) return error.BadType;
        },
        .imm => |x| {
            const is_pred = want == .pred or (want == .ty and ty == .pred);
            if (is_pred and x > 1) return error.BadOperand;
        },
    }
}

fn regOk(k: *const Kernel, v: V) bool {
    return v != .none and @intFromEnum(v) < k.nv;
}

fn validCvt(c: Cvt) bool {
    if (c._ != 0) return false;
    const from_ok = c.from != .pred;
    const to_ok = c.to != .pred;
    if (!from_ok or !to_ok) return false;
    // int <-> f16 goes through f32 (two cvts); every other pair is direct
    if (isInt(c.from) and c.to == .f16) return false;
    if (c.from == .f16 and isInt(c.to)) return false;
    if (c.from == c.to) return false;
    return true;
}

fn verifyKernel(k: *const Kernel, caps: ?Caps) Error!void {
    if (k.n > k.insts.len) return error.TooManyInsts;
    if (k.nv > k.tys.len) return error.TooManyRegs;
    const threads = @as(u64, k.group[0]) * k.group[1] * k.group[2];
    if (threads == 0) return error.BadOperand;
    if (caps) |cp| {
        if (threads > cp.max_group) return error.Limits;
        if (k.shared_bytes > cp.shared_bytes) return error.Limits;
    }
    // (if: 0, else: 1, loop: 2)
    var stack: [MAX_DEPTH]u8 = undefined;
    var depth: usize = 0;
    var loops: usize = 0;
    for (k.insts[0..k.n]) |in| {
        const s = shape(in.op);
        var from: Ty = in.ty;
        switch (in.op) {
            .cvt => {
                const c: Cvt = @bitCast(in.aux);
                if (!validCvt(c)) return error.BadType;
                if (in.ty != c.to) return error.BadType;
                from = c.from;
            },
            .icmp => {
                if (!isInt(in.ty)) return error.BadType;
                if (in.aux > @intFromEnum(Cmp.ge)) return error.BadOperand;
            },
            .fcmp => {
                if (in.ty != .f32) return error.BadType;
                if (in.aux > @intFromEnum(Cmp.ge)) return error.BadOperand;
            },
            .dot4 => if (in.aux > @intFromEnum(Dot4.u8u8)) return error.BadOperand,
            .tid, .gid, .gsize => if (in.aux > 2) return error.BadOperand,
            .param => {
                if (in.aux >= k.param_words) return error.BadOperand;
                if (in.ty == .pred) return error.BadType;
            },
            .shfl => {
                if (in.aux > @intFromEnum(Shfl.down)) return error.BadOperand;
                if (in.ty == .pred) return error.BadType;
            },
            .vote => if (in.aux > @intFromEnum(Vote.all)) return error.BadOperand,
            .ballot => {
                if (in.aux > 3) return error.BadOperand;
                if (in.ty != .u32) return error.BadType;
            },
            .ffma => if (caps) |cp| if (!cp.fused_fma) return error.NeedsFusedFma,
            .ld, .st, .atom, .cas => try checkMem(k, in),
            .@"if" => {
                if (depth == MAX_DEPTH) return error.Unbalanced;
                stack[depth] = 0;
                depth += 1;
            },
            .@"else" => {
                if (depth == 0 or stack[depth - 1] != 0) return error.Unbalanced;
                stack[depth - 1] = 1;
            },
            .endif => {
                if (depth == 0 or stack[depth - 1] == 2) return error.Unbalanced;
                depth -= 1;
            },
            .loop => {
                if (depth == MAX_DEPTH) return error.Unbalanced;
                stack[depth] = 2;
                depth += 1;
                loops += 1;
            },
            .endloop => {
                if (depth == 0 or stack[depth - 1] != 2) return error.Unbalanced;
                depth -= 1;
                loops -= 1;
            },
            .brk, .cont => if (loops == 0) return error.Unbalanced,
            else => {},
        }
        // the op's type
        switch (s.dst) {
            .int => if (!isInt(in.ty) and in.op != .icmp) return error.BadType,
            .f32 => if (in.ty != .f32) return error.BadType,
            .pred => if (in.op != .icmp and in.op != .fcmp and in.ty != .pred) return error.BadType,
            else => {},
        }
        if (s.dst == .int and (in.op == .tid or in.op == .gid or in.op == .gsize or in.op == .lane or in.op == .subgroup)) {
            if (!isInt(in.ty)) return error.BadType;
        }
        if ((in.op == .iabs) and in.ty != .i32) return error.BadType;
        if ((in.op == .atom or in.op == .cas) and !isInt(in.ty)) return error.BadType;
        if (in.op == .ld or in.op == .st) if (in.ty == .pred) return error.BadType;
        // the destination
        if (s.dst != .none) {
            if (!regOk(k, in.dst)) return error.BadOperand;
            const n = if (in.op == .ld) memRegs(@bitCast(in.aux)) else 1;
            if (@as(usize, @intFromEnum(in.dst)) + n > k.nv) return error.BadOperand;
            const want: Want = switch (s.dst) {
                .pred => .pred,
                .ty => .ty,
                else => s.dst,
            };
            for (0..n) |ix| {
                const have = k.tys[@intFromEnum(in.dst) + ix];
                const dty: Ty = if (in.op == .cvt) @as(Cvt, @bitCast(in.aux)).to else in.ty;
                if (!fits(want, have, dty, from)) return error.BadType;
            }
        } else if (in.dst != .none) return error.BadOperand;
        try checkArg(k, s.a, in.a, in.ty, from);
        try checkArg(k, s.b, in.b, in.ty, from);
        try checkArg(k, s.c, in.c, in.ty, from);
        if (in.op == .st and memRegs(@bitCast(in.aux)) > 1) {
            const v = switch (in.b) {
                .reg => |v| v,
                .imm => return error.BadOperand,
            };
            const n = memRegs(@bitCast(in.aux));
            if (@as(usize, @intFromEnum(v)) + n > k.nv) return error.BadOperand;
            for (0..n) |ix| if (!fits(.ty, k.tys[@intFromEnum(v) + ix], in.ty, in.ty)) return error.BadType;
        }
        if (in.op == .atom) {
            switch (in.c) {
                .imm => |x| if (x > @intFromEnum(Atom.xor)) return error.BadOperand,
                .reg => return error.BadOperand,
            }
        }
    }
    if (depth != 0) return error.Unbalanced;
}

fn checkMem(k: *const Kernel, in: Inst) Error!void {
    // (the space's two bits: 2 and 3 are no space)
    if ((in.aux >> 8) & 3 > 1) return error.BadOperand;
    const m: Mem = @bitCast(in.aux);
    if (m.width_log2 < 3) return error.BadOperand;
    if ((in.op == .atom or in.op == .cas) and m.width_log2 != 5) return error.BadOperand;
    switch (m.space) {
        .global => if (m.binding >= k.bindings) return error.BadBinding,
        .shared => {
            if (m.binding != 0) return error.BadBinding;
            // an immediate address is checked here; a register one at run time
            if (in.a == .imm) {
                const end = @as(u64, in.a.imm) + m.imm + memBytes(m);
                if (end > k.shared_bytes) return error.BadOperand;
            }
        },
    }
    // width against the register type
    const bits = @as(u32, 8) * memBytes(m);
    switch (bits) {
        8 => if (!isInt(in.ty)) return error.BadType,
        16 => if (!isInt(in.ty) and in.ty != .f16) return error.BadType,
        else => if (in.ty == .f16 and bits != 32) return error.BadType,
    }
    if (m.signed and bits > 16) return error.BadOperand;
    if ((m.imm & (memBytes(m) - 1)) != 0) return error.BadOperand;
}

// ── The interpreter's binary form ───────────────────────────────────────────

/// Bytes per instruction in a Binary for the interpreter.
pub const INST_BYTES = 24;

/// One instruction as 24 bytes: op, ty, dst (le16), the operands' kinds
/// (bit n: operand n is an immediate), 3 pad, a, b, c (le32 each: the
/// register's number or the immediate), aux (le32).
pub fn encodeInst(in: Inst, out: *[INST_BYTES]u8) void {
    out.* = [_]u8{0} ** INST_BYTES;
    out[0] = @intFromEnum(in.op);
    out[1] = @intFromEnum(in.ty);
    std.mem.writeInt(u16, out[2..4], @intFromEnum(in.dst), .little);
    var kinds: u8 = 0;
    const args = [3]Arg{ in.a, in.b, in.c };
    for (args, 0..) |a, ix| {
        const word: u32 = switch (a) {
            .reg => |v| @intFromEnum(v),
            .imm => |x| blk: {
                kinds |= @as(u8, 1) << @intCast(ix);
                break :blk x;
            },
        };
        std.mem.writeInt(u32, out[8 + 4 * ix ..][0..4], word, .little);
    }
    out[4] = kinds;
    std.mem.writeInt(u32, out[20..24], in.aux, .little);
}

pub fn decodeInst(b: *const [INST_BYTES]u8) error{BadOperand}!Inst {
    if (b[0] > @intFromEnum(LAST_OP) or b[1] > @intFromEnum(Ty.pred)) return error.BadOperand;
    var args: [3]Arg = undefined;
    for (0..3) |ix| {
        const word = std.mem.readInt(u32, b[8 + 4 * ix ..][0..4], .little);
        args[ix] = if (b[4] & (@as(u8, 1) << @intCast(ix)) != 0)
            .{ .imm = word }
        else if (word > 0xffff)
            return error.BadOperand
        else
            .{ .reg = @enumFromInt(@as(u16, @intCast(word))) };
    }
    return .{
        .op = @enumFromInt(b[0]),
        .ty = @enumFromInt(b[1]),
        .dst = @enumFromInt(std.mem.readInt(u16, b[2..4], .little)),
        .a = args[0],
        .b = args[1],
        .c = args[2],
        .aux = std.mem.readInt(u32, b[20..24], .little),
    };
}

/// The kernel's instructions in their binary form, into `out`.
pub fn encode(k: *const Kernel, out: []u8) error{NoSpaceLeft}![]u8 {
    const need = k.n * INST_BYTES;
    if (out.len < need) return error.NoSpaceLeft;
    for (k.insts[0..k.n], 0..) |in, ix| encodeInst(in, out[ix * INST_BYTES ..][0..INST_BYTES]);
    return out[0..need];
}

// ── Exact division and square root, for backends ───────────────────────────

/// dst = a / b correctly rounded (as fdiv), from ops the target has: the
/// fused-FMA expansion where caps.fused_fma, else the one from correctly
/// rounded mul and add only. Bit-exact to fdiv under caps' denormal mode.
pub fn expandDiv(k: *Kernel, caps: Caps, dst: V, a: Arg, b: Arg) void {
    exactDiv(k, caps, dst, a, b);
}

/// dst = sqrt(a) correctly rounded (as fsqrt); as expandDiv.
pub fn expandSqrt(k: *Kernel, caps: Caps, dst: V, a: Arg) void {
    exactSqrt(k, caps, dst, a);
}

/// A copy of `src` into `s` with every fdiv and fsqrt replaced by its
/// expansion for `caps` (src's registers keep their numbers; the
/// expansions' temporaries come after them). What a backend compiles.
pub fn expand(src: *const Kernel, caps: Caps, s: Storage) Error!Kernel {
    if (src.err) |e| return e;
    if (s.tys.len < src.nv) return error.TooManyRegs;
    var k = Kernel.init(s, src.name, src.group);
    k.shared_bytes = src.shared_bytes;
    k.bindings = src.bindings;
    k.param_words = src.param_words;
    @memcpy(k.tys[0..src.nv], src.tys[0..src.nv]);
    k.nv = src.nv;
    for (src.insts[0..src.n]) |in| {
        switch (in.op) {
            .fdiv => expandDiv(&k, caps, in.dst, in.a, in.b),
            .fsqrt => expandSqrt(&k, caps, in.dst, in.a),
            .ballot => expandBallot(&k, in.dst, in.a, @intCast(in.aux & 3)),
            else => k.emit(in),
        }
    }
    if (k.err) |e| return e;
    return k;
}

/// dst = ballot(p) over lanes 32*word.. from votes alone, for targets
/// without a native ballot (kir.expand's): bit i is a vote among the
/// active lanes of whether lane 32*word+i is one where p holds. Every
/// register written once.
pub fn expandBallot(k: *Kernel, dst: V, p: Arg, word: u2) void {
    const ln = k.lane();
    var acc: Arg = u(0);
    for (0..32) |bit| {
        const at = @as(u32, word) * 32 + @as(u32, @intCast(bit));
        const me = k.cmp(.u32, .eq, r(ln), u(at));
        const both = k.op2(.pand, .pred, r(me), p);
        const v = k.vote(.any, r(both));
        const m = k.sel(.u32, r(v), u(@as(u32, 1) << @intCast(bit)), u(0));
        acc = r(k.op2(.@"or", .u32, acc, r(m)));
    }
    k.emit(.{ .op = .mov, .ty = .u32, .dst = dst, .a = acc, .b = no, .c = no, .aux = 0 });
}

// How the expansions work (docs/GPU.md has the proofs' outline):
//
// Fast path, for operands whose exponents are well inside the normal range
// (|e| <= 48 for fdiv, -60..100 for fsqrt, positive: every remainder and
// every product of Dekker's stays normal): the core works on the
// magnitudes directly. Otherwise (one if-block before the core, one after,
// both skipped when every lane is fast) the operands are reduced to
// mantissas in [1,2) (fsqrt: [1,4), keeping the exponent's parity), the
// core runs on those, and the result is put back together with integer
// ops: the exponent, gradual underflow (rounded from the truncated quotient
// and a sticky bit), overflow, the special values, then flushing if caps
// say so.
//
// Every register is written once: what an if-block computes is picked by a
// select after it (a lane that skipped the block reads whatever its
// registers hold, and the select drops it). A register written twice lives
// through every loop around it in a backend's allocation (ir3's): an
// expansion in a loop would hold its registers for the whole loop.
//
// The core: a seed from frcp (frsq), one Newton step, a quotient (root),
// one correction with its remainder: a faithful result (within an ulp).
// Then the exact decision: with the remainder of the faithful candidate
// (exact: the remainder of a faithful quotient is representable), take the
// truncation c of the true value and add one ulp iff the value lies above
// c's midpoint. Remainders come from ffma where fused, or from Dekker's
// two-product with Veltkamp's splitting (4097 = 2^12 + 1) where not. The
// result does not depend on the seed's accuracy (proven by tests with
// frcp/frsq off by up to 600 ulps, about 2^-14).

const Ex = struct {
    k: *Kernel,

    fn iu(x: Ex, op: Op, a: Arg, b: Arg) V {
        return x.k.op2(op, .u32, a, b);
    }
    fn s2(x: Ex, op: Op, a: Arg, b: Arg) V {
        return x.k.op2(op, .i32, a, b);
    }
    fn f2(x: Ex, op: Op, a: Arg, b: Arg) V {
        return x.k.op2(op, .f32, a, b);
    }
    fn f3(x: Ex, op: Op, a: Arg, b: Arg, c: Arg) V {
        return x.k.op3(op, .f32, a, b, c);
    }
    fn f1(x: Ex, op: Op, a: Arg) V {
        return x.k.op1(op, .f32, a);
    }
    fn ucmp(x: Ex, c: Cmp, a: Arg, b: Arg) V {
        return x.k.cmp(.u32, c, a, b);
    }
    fn scmp(x: Ex, c: Cmp, a: Arg, b: Arg) V {
        return x.k.cmp(.i32, c, a, b);
    }
    fn fcmp(x: Ex, c: Cmp, a: Arg, b: Arg) V {
        return x.k.cmp(.f32, c, a, b);
    }
    fn sel(x: Ex, p: V, a: Arg, b: Arg) V {
        return x.k.sel(.u32, r(p), a, b);
    }
    fn p2(x: Ex, op: Op, a: V, b: V) V {
        return x.k.op2(op, .pred, r(a), r(b));
    }
    /// The bits of an f32 (a reinterpreting mov).
    fn bitsOf(x: Ex, a: Arg) V {
        return x.k.mov(.u32, a);
    }
    fn asF(x: Ex, v: V) V {
        return x.k.mov(.f32, r(v));
    }
    /// 1 where p, else 0.
    fn one(x: Ex, p: V) V {
        return x.sel(p, u(1), u(0));
    }

    /// x = hi + lo, hi with the top 12 bits (Veltkamp).
    fn split(x: Ex, a: V) [2]V {
        const c = x.f2(.fmul, r(a), f(4097.0));
        const hi = x.f2(.fsub, r(c), r(x.f2(.fsub, r(c), r(a))));
        const lo = x.f2(.fsub, r(a), r(hi));
        return .{ hi, lo };
    }

    /// a - b*q: exact when it is representable, else correctly rounded,
    /// from correctly rounded mul and add only (Dekker's product).
    fn remainder(x: Ex, a: V, b: V, bs: [2]V, q: V) V {
        const qs = x.split(q);
        const p = x.f2(.fmul, r(b), r(q));
        var e = x.f2(.fsub, r(x.f2(.fmul, r(bs[0]), r(qs[0]))), r(p));
        e = x.f2(.fadd, r(e), r(x.f2(.fmul, r(bs[0]), r(qs[1]))));
        e = x.f2(.fadd, r(e), r(x.f2(.fmul, r(bs[1]), r(qs[0]))));
        e = x.f2(.fadd, r(e), r(x.f2(.fmul, r(bs[1]), r(qs[1]))));
        return x.f2(.fsub, r(x.f2(.fsub, r(a), r(p))), r(e));
    }

    /// a - s*s, as remainder.
    fn sqRemainder(x: Ex, a: V, s: V) V {
        const ss = x.split(s);
        const p = x.f2(.fmul, r(s), r(s));
        const hl = x.f2(.fmul, r(ss[0]), r(ss[1]));
        var e = x.f2(.fsub, r(x.f2(.fmul, r(ss[0]), r(ss[0]))), r(p));
        e = x.f2(.fadd, r(e), r(x.f2(.fadd, r(hl), r(hl))));
        e = x.f2(.fadd, r(e), r(x.f2(.fmul, r(ss[1]), r(ss[1]))));
        return x.f2(.fsub, r(x.f2(.fsub, r(a), r(p))), r(e));
    }
};

/// The core's answer: c, the truncation of the true quotient or root at
/// c's precision; up, whether the result is c's successor; rc, c's
/// remainder (0 iff c is exact).
const Core = struct { cb: V, up: V, rc: V };

/// a/b for positive normal a, b with the quotient and its remainders in
/// the normal range.
fn divCore(x: Ex, fused: bool, a: V, b: V) Core {
    const y0 = x.f1(.frcp, r(b));
    if (fused) {
        const nb = x.f1(.fneg, r(b));
        const e = x.f3(.ffma, r(nb), r(y0), f(1.0));
        const y1 = x.f3(.ffma, r(e), r(y0), r(y0));
        const q0 = x.f2(.fmul, r(a), r(y1));
        const r0 = x.f3(.ffma, r(nb), r(q0), r(a));
        const q1 = x.f3(.ffma, r(r0), r(y1), r(q0)); // faithful
        const r1 = x.f3(.ffma, r(nb), r(q1), r(a)); // exact (an exact 0 is +0)
        // c: q1, or its predecessor when r1 < 0 (r1's sign bit)
        const cb = x.iu(.isub, r(x.bitsOf(r(q1))), r(x.iu(.shr, r(x.bitsOf(r(r1))), u(31))));
        const c = x.asF(cb);
        const hu = x.iu(.isub, r(x.iu(.@"and", r(cb), u(0x7f80_0000))), u(24 << 23));
        const hc = x.f2(.fmul, r(b), r(x.asF(hu))); // b * ulp(c) / 2, exact
        const rc = x.f3(.ffma, r(nb), r(c), r(a)); // exact: c is faithful
        const up = x.fcmp(.gt, r(rc), r(hc));
        return .{ .cb = cb, .up = up, .rc = rc };
    }
    const t = x.f2(.fmul, r(b), r(y0));
    const e = x.f2(.fsub, f(1.0), r(t));
    const y1 = x.f2(.fadd, r(y0), r(x.f2(.fmul, r(y0), r(e))));
    const q0 = x.f2(.fmul, r(a), r(y1));
    const bs = x.split(b);
    const r0 = x.remainder(a, b, bs, q0);
    const q1 = x.f2(.fadd, r(q0), r(x.f2(.fmul, r(r0), r(y1)))); // faithful
    const r1 = x.remainder(a, b, bs, q1); // exact
    const neg = x.fcmp(.lt, r(r1), f(0));
    const cb = x.iu(.isub, r(x.bitsOf(r(q1))), r(x.one(neg)));
    const hu = x.iu(.isub, r(x.iu(.@"and", r(cb), u(0x7f80_0000))), u(24 << 23));
    const hc = x.f2(.fmul, r(b), r(x.asF(hu)));
    // c's remainder: r1, or r1 + b*ulp(c) when c is q1's predecessor (exact)
    const rp = x.f2(.fadd, r(r1), r(x.f2(.fadd, r(hc), r(hc))));
    const rc = x.k.sel(.f32, r(neg), r(rp), r(r1));
    const up = x.fcmp(.gt, r(rc), r(hc));
    return .{ .cb = cb, .up = up, .rc = rc };
}

/// sqrt(a) for a positive normal a with the root and its remainders in
/// the normal range. (rc is unused: a root is never in gradual underflow.)
fn sqrtCore(x: Ex, fused: bool, a: V) Core {
    const y = x.f1(.frsq, r(a));
    const s0 = x.f2(.fmul, r(a), r(y));
    const h = x.f2(.fmul, r(y), f(0.5));
    if (fused) {
        const r0 = x.f3(.ffma, r(x.f1(.fneg, r(s0))), r(s0), r(a));
        const s1 = x.f3(.ffma, r(r0), r(h), r(s0)); // faithful
        const r1 = x.f3(.ffma, r(x.f1(.fneg, r(s1))), r(s1), r(a));
        const cb = x.iu(.isub, r(x.bitsOf(r(s1))), r(x.iu(.shr, r(x.bitsOf(r(r1))), u(31))));
        const c = x.asF(cb);
        const rc = x.f3(.ffma, r(x.f1(.fneg, r(c))), r(c), r(a));
        const ub = x.iu(.isub, r(x.iu(.@"and", r(cb), u(0x7f80_0000))), u(23 << 23));
        const cu = x.f2(.fmul, r(c), r(x.asF(ub))); // c * ulp(c), exact
        const up = x.fcmp(.gt, r(rc), r(cu));
        return .{ .cb = cb, .up = up, .rc = rc };
    }
    const r0 = x.sqRemainder(a, s0);
    const s1 = x.f2(.fadd, r(s0), r(x.f2(.fmul, r(r0), r(h)))); // faithful
    const r1 = x.sqRemainder(a, s1);
    // up iff r1 > s1*ulp(s1); down iff r1 <= -s1*ulp(the predecessor)
    const sb = x.bitsOf(r(s1));
    const ub = x.iu(.isub, r(x.iu(.@"and", r(sb), u(0x7f80_0000))), u(23 << 23));
    const db = x.iu(.isub, r(x.iu(.@"and", r(x.iu(.isub, r(sb), u(1))), u(0x7f80_0000))), u(23 << 23));
    const su = x.f2(.fmul, r(s1), r(x.asF(ub)));
    const sd = x.f2(.fmul, r(s1), r(x.asF(db)));
    const up = x.fcmp(.gt, r(r1), r(su));
    const dn = x.fcmp(.le, r(r1), r(x.f1(.fneg, r(sd))));
    // (as a Core: c = s1 - dn, up as found)
    const cb = x.iu(.isub, r(sb), r(x.one(dn)));
    return .{ .cb = cb, .up = up, .rc = r1 };
}

const INF: u32 = 0x7f80_0000;

/// One operand of fdiv's slow path: its magnitude's mantissa in [1,2) (as
/// f32 bits) and biased exponent (denormals normalized; flushed ones are
/// zeros, which the specials handle).
fn unpack(x: Ex, flush: bool, mag: V) [2]V {
    var m = mag;
    var e: V = undefined;
    if (flush) {
        e = x.iu(.shr, r(mag), u(23));
    } else {
        const den = x.ucmp(.lt, r(mag), u(0x0080_0000));
        const scaled = x.bitsOf(r(x.f2(.fmul, r(x.asF(mag)), f(16777216.0))));
        m = x.sel(den, r(scaled), r(mag));
        e = x.iu(.isub, r(x.iu(.shr, r(m), u(23))), r(x.sel(den, u(24), u(0))));
    }
    const mant = x.iu(.@"or", r(x.iu(.@"and", r(m), u(0x007f_ffff))), u(0x3f80_0000));
    return .{ mant, e };
}

fn exactDiv(k: *Kernel, caps: Caps, dst: V, a: Arg, b: Arg) void {
    const x = Ex{ .k = k };
    const fused = caps.fused_fma;
    const flush = caps.denormals == .flush;
    const ab = x.bitsOf(a);
    const bb = x.bitsOf(b);
    const sign = x.iu(.@"and", r(x.iu(.xor, r(ab), r(bb))), u(0x8000_0000));
    const ax = x.iu(.@"and", r(ab), u(0x7fff_ffff));
    const bx = x.iu(.@"and", r(bb), u(0x7fff_ffff));
    // fast: both exponents in [-48, 48] (each magnitude's offset from
    // 2^-48, unsigned, within the range)
    const da = x.iu(.isub, r(ax), u(0x2780_0000));
    const db = x.iu(.isub, r(bx), u(0x2780_0000));
    const slow = x.ucmp(.gt, r(x.iu(.imax, r(da), r(db))), u(0x307f_ffff));
    // (the slow path's mantissas and the exponents' difference, written
    // once in the block; selected after it)
    var ua: [2]V = undefined;
    var ub: [2]V = undefined;
    var de: V = undefined;
    k.ifp(r(slow));
    {
        ua = unpack(x, flush, ax);
        ub = unpack(x, flush, bx);
        de = x.iu(.isub, r(ua[1]), r(ub[1]));
    }
    k.endif();
    const am = x.asF(x.sel(slow, r(ua[0]), r(ax)));
    const bm = x.asF(x.sel(slow, r(ub[0]), r(bx)));
    const core = divCore(x, fused, am, bm);
    const res = x.iu(.iadd, r(core.cb), r(x.one(core.up)));
    const fast = x.iu(.@"or", r(res), r(sign));
    var w: V = undefined;
    k.ifp(r(slow));
    {
        // the result's biased exponent, from c and from the rounded value
        const fc = x.iu(.iadd, r(x.iu(.shr, r(core.cb), u(23))), r(de));
        const ff = x.iu(.iadd, r(x.iu(.shr, r(res), u(23))), r(de));
        const normal = x.iu(.iadd, r(res), r(x.iu(.shl, r(de), u(23))));
        const ovf = x.scmp(.ge, r(ff), u(255));
        const sub = x.scmp(.le, r(fc), u(0));
        // gradual underflow: c's significand shifted right by 1 - fc,
        // rounded to nearest even with c's sticky bit
        const sh = x.s2(.imin, r(x.iu(.isub, u(1), r(fc))), u(25));
        const sig = x.iu(.@"or", r(x.iu(.@"and", r(core.cb), u(0x007f_ffff))), u(0x0080_0000));
        const qt = x.iu(.shr, r(sig), r(sh));
        const rem = x.iu(.@"and", r(sig), r(x.iu(.isub, r(x.iu(.shl, u(1), r(sh))), u(1))));
        const half = x.iu(.shl, u(1), r(x.iu(.isub, r(sh), u(1))));
        const sticky = x.fcmp(.ne, r(core.rc), f(0));
        const odd = x.ucmp(.ne, r(x.iu(.@"and", r(qt), u(1))), u(0));
        const above = x.ucmp(.gt, r(rem), r(half));
        const tie = x.ucmp(.eq, r(rem), r(half));
        const rup = x.p2(.por, above, x.p2(.pand, tie, x.p2(.por, sticky, odd)));
        var mant = x.iu(.iadd, r(qt), r(x.one(rup)));
        if (flush) mant = x.sel(x.ucmp(.lt, r(mant), u(0x0080_0000)), u(0), r(mant));
        const v = x.sel(sub, r(mant), r(x.sel(ovf, u(INF), r(normal))));
        const vs = x.iu(.@"or", r(v), r(sign));
        // the special values
        const zmax: u32 = if (flush) 0x0080_0000 else 1;
        const a_nan = x.ucmp(.gt, r(ax), u(INF));
        const b_nan = x.ucmp(.gt, r(bx), u(INF));
        const a_inf = x.ucmp(.eq, r(ax), u(INF));
        const b_inf = x.ucmp(.eq, r(bx), u(INF));
        const a_zero = x.ucmp(.lt, r(ax), u(zmax));
        const b_zero = x.ucmp(.lt, r(bx), u(zmax));
        const nan = x.p2(.por, x.p2(.por, a_nan, b_nan), x.p2(.por, x.p2(.pand, a_inf, b_inf), x.p2(.pand, a_zero, b_zero)));
        const to_inf = x.p2(.por, a_inf, b_zero);
        const to_zero = x.p2(.por, a_zero, b_inf);
        const sinf = x.iu(.@"or", r(sign), u(INF));
        w = x.sel(nan, u(0x7fff_ffff), r(x.sel(to_inf, r(sinf), r(x.sel(to_zero, r(sign), r(vs))))));
    }
    k.endif();
    k.set(dst, .mov, r(x.sel(slow, r(w), r(fast))), no, no);
}

fn exactSqrt(k: *Kernel, caps: Caps, dst: V, a: Arg) void {
    const x = Ex{ .k = k };
    const fused = caps.fused_fma;
    const flush = caps.denormals == .flush;
    const ab = x.bitsOf(a);
    // fast: positive, exponent in [-60, 100] (Dekker's smallest product,
    // about a * 2^-46, stays normal)
    const slow = x.ucmp(.gt, r(x.iu(.isub, r(ab), u(67 << 23))), u((227 << 23 | 0x007f_ffff) - (67 << 23)));
    // (the slow path's mantissa and half its exponent, written once in the
    // block; selected after it)
    var mant: V = undefined;
    var eh: V = undefined;
    k.ifp(r(slow));
    {
        const ax = x.iu(.@"and", r(ab), u(0x7fff_ffff));
        var m = ax;
        var be: V = undefined;
        if (flush) {
            be = x.iu(.shr, r(ax), u(23));
        } else {
            const den = x.ucmp(.lt, r(ax), u(0x0080_0000));
            const scaled = x.bitsOf(r(x.f2(.fmul, r(x.asF(ax)), f(16777216.0))));
            m = x.sel(den, r(scaled), r(ax));
            be = x.iu(.isub, r(x.iu(.shr, r(m), u(23))), r(x.sel(den, u(24), u(0))));
        }
        // a = mant * 2^e, e even: mant in [1,4)
        const e = x.iu(.isub, r(be), u(127));
        const odd = x.ucmp(.ne, r(x.iu(.@"and", r(e), u(1))), u(0));
        const top = x.sel(odd, u(0x4000_0000), u(0x3f80_0000));
        mant = x.iu(.@"or", r(x.iu(.@"and", r(m), u(0x007f_ffff))), r(top));
        // (an arithmetic shift: e may be below zero)
        eh = x.s2(.shr, r(x.iu(.isub, r(e), r(x.one(odd)))), u(1));
    }
    k.endif();
    const am = x.asF(x.sel(slow, r(mant), r(ab)));
    const core = sqrtCore(x, fused, am);
    const res = x.iu(.iadd, r(core.cb), r(x.one(core.up)));
    var w: V = undefined;
    k.ifp(r(slow));
    {
        const v = x.iu(.iadd, r(res), r(x.iu(.shl, r(eh), u(23))));
        const ax = x.iu(.@"and", r(ab), u(0x7fff_ffff));
        const zmax: u32 = if (flush) 0x0080_0000 else 1;
        const zero = x.ucmp(.lt, r(ax), u(zmax));
        const nan = x.ucmp(.gt, r(ab), u(INF)); // NaN, or below zero
        const pinf = x.ucmp(.eq, r(ab), u(INF));
        const sign = x.iu(.@"and", r(ab), u(0x8000_0000));
        w = x.sel(zero, r(sign), r(x.sel(nan, u(0x7fff_ffff), r(x.sel(pinf, u(INF), r(v))))));
    }
    k.endif();
    k.set(dst, .mov, r(x.sel(slow, r(w), r(res))), no, no);
}

test "kir: build, verify, encode" {
    var insts: [64]Inst = undefined;
    var tys: [64]Ty = undefined;
    var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "add", .{ 64, 1, 1 });
    const out = k.binding();
    const t = k.tid(0);
    const off = k.op2(.shl, .u32, r(t), u(2));
    const x = k.load(.f32, global(out, 32), r(off));
    const y = k.add(.f32, r(x), f(1.5));
    k.store(.f32, global(out, 32), r(off), r(y));
    try k.finish();
    var bytes: [64 * INST_BYTES]u8 = undefined;
    const code_bytes = try encode(&k, &bytes);
    for (k.code(), 0..) |in, ix| {
        const back = try decodeInst(code_bytes[ix * INST_BYTES ..][0..INST_BYTES]);
        try std.testing.expectEqual(in.op, back.op);
        try std.testing.expectEqual(in.dst, back.dst);
        try std.testing.expectEqual(in.aux, back.aux);
        try std.testing.expect(std.meta.eql(in.a, back.a));
        try std.testing.expect(std.meta.eql(in.b, back.b));
    }
}

test "kir: the verifier rejects" {
    var insts: [64]Inst = undefined;
    var tys: [64]Ty = undefined;
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "unbalanced", .{ 1, 1, 1 });
        const p = k.cmp(.u32, .eq, r(k.tid(0)), u(0));
        k.ifp(r(p));
        try std.testing.expectError(error.Unbalanced, k.finish());
    }
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "type", .{ 1, 1, 1 });
        const t = k.tid(0);
        _ = k.op2(.fadd, .f32, r(t), f(1));
        try std.testing.expectError(error.BadType, k.finish());
    }
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "binding", .{ 1, 1, 1 });
        _ = k.load(.u32, global(0, 32), u(0));
        try std.testing.expectError(error.BadBinding, k.finish());
    }
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "brk outside", .{ 1, 1, 1 });
        k.brk(u(1));
        try std.testing.expectError(error.Unbalanced, k.finish());
    }
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "ffma", .{ 1, 1, 1 });
        _ = k.op3(.ffma, .f32, f(1), f(2), f(3));
        try k.finish();
        var caps = device.interp_caps;
        caps.fused_fma = false;
        try std.testing.expectError(error.NeedsFusedFma, verify(&k, caps));
        caps.fused_fma = true;
        try verify(&k, caps);
    }
    {
        var k = Kernel.init(.{ .insts = &insts, .tys = &tys }, "full", .{ 1, 1, 1 });
        for (0..65) |_| k.barrier();
        try std.testing.expectError(error.TooManyInsts, k.finish());
    }
}
