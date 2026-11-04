//! @zpm/nvidia sm120_sched — sm_120 control fields worked out.
//!
//! The hardware does not track an instruction's register hazards itself:
//! every instruction says, in its control field (see sm120.sig), how many
//! cycles to stall before the next one issues, which of six scoreboards its
//! variable-latency work releases, and which scoreboards to wait on first.
//! Given instructions in order, this works those out, as Mesa's NAK does it
//! (calc_instr_deps.rs, MIT, read as documentation):
//!
//! - Every instruction's registers get NAK's latency category for sm_120
//!   (sm120_instr_latencies.rs) in their file (general, uniform,
//!   predicate, uniform predicate): fixed-latency ("coupled")
//!   instructions' results are waited for by stalling, variable-latency
//!   ("decoupled") ones' (memory, constant loads, special registers,
//!   shuffles, MUFU, conversions, POPC, FLO, BREV, FCHK) by scoreboards.
//!   The uniform datapath's ops are NAK's `udp`; a guard is read at issue.
//! - Each hazard, a read after a write (RAW), a write after a read (WAR) or
//!   after a write (WAW), takes NVIDIA's cycles for its pair of categories
//!   (sm120_latency.sig), plus NAK's one cycle of padding on sm_120 for
//!   reads after writes, and NAK's measured adjustment for the tensor
//!   cores' general registers (HMMA's 9 cycles, IMMA's 7, for every kind
//!   of hazard). Where a pair needs a scoreboard, the first instruction
//!   releases one and the second waits on it, at least two cycles after
//!   it was set.
//! - Six scoreboards: a free one when there is one, else the one the most
//!   recent instruction holds is shared (waiting on it then waits on both).
//! - Branches (BRA, BRA.U, CALL, RET) and EXIT end a block (an EXIT
//!   too: the warp's other lanes go on after it): a branch waits on
//!   every scoreboard in flight and stalls until every fixed-latency result
//!   before it is ready to any reader, so a block starts with nothing
//!   pending whichever way it is entered (a BSYNC's join included). (NAK
//!   follows latencies across blocks; this is simpler, and costs a few
//!   cycles a loop iteration.)
//! - NAK's exec latency: BAR holds the next instruction back 6 cycles
//!   (NAK's extra NOP after it is left out: ptxas's S06 is the same);
//!   WARPSYNC 5, as ptxas's S05 after it.
//! - A stall over 15 cycles is split with NOPs after the instruction.
//!
//! `check` verifies a scheduled kernel against the same model on its own,
//! and the tests compare both with ptxas's fields for its kernels.
//!
//! Bit 109 (Y) is left clear, as NAK leaves it on sm_120; `.reuse` stays as
//! written.
//!
//! Allocation-free: the caller owns the working storage (Work).

const std = @import("std");
const sm120 = @import("sm120.sig");
const lat = @import("sm120_latency.sig");

pub const MAX_INSTRS = 4096;
pub const BARS = 6;

pub const Error = error{
    /// An instruction this module has no latency categories for.
    Unknown,
    TooManyInstructions,
};

/// NAK's padding on sm_120 for a read after a write (sm_100's tables were
/// measured on B100, not the GeForce chips).
const PAD: u8 = 1;
/// When NVIDIA's tables have no entry for a pair: assume the worst.
const WORST: u8 = 15;
/// A scoreboard's waiter issues at least this long after its setter.
const SB_SET: u32 = 2;

// ── What instructions read and write ────────────────────────────────────────

pub const File = enum(u2) { gpr, ugpr, pred, upred };

/// A register, and its latency category (an enum of sm120_latency.sig's
/// for its file, as u8).
pub const Use = struct {
    file: File,
    n: u8,
    cat: u8,

    fn same(a: Use, b: Use) bool {
        return a.file == b.file and a.n == b.n;
    }
};

const MAX_DST = 8;
const MAX_SRC = 14;

pub const Uses = struct {
    dst: [MAX_DST]Use = undefined,
    n_dst: u8 = 0,
    src: [MAX_SRC]Use = undefined,
    n_src: u8 = 0,
    /// Variable latency: its registers' hazards take scoreboards.
    decoupled: bool = false,
    branch: bool = false,
    /// An EXIT (or RET) without a predicate: nothing falls through past it,
    /// so the next instruction starts a block (reached only by branches,
    /// which drain).
    ends: bool = false,
    /// The cycles before the next instruction may issue, whatever it reads
    /// (NAK's exec_latency: BAR's 6).
    exec: u8 = 1,

    pub fn dsts(u: *const Uses) []const Use {
        return u.dst[0..u.n_dst];
    }

    pub fn srcs(u: *const Uses) []const Use {
        return u.src[0..u.n_src];
    }

    /// Reads of registers (a guard predicate is read at issue).
    fn readsRegs(u: *const Uses) bool {
        for (u.srcs()) |s| {
            if (s.file == .gpr or s.file == .ugpr) return true;
        }
        return false;
    }

    fn addDst(u: *Uses, file: File, n: u8, cat: u8) void {
        if (n == sm120.RZ or ((file == .pred or file == .upred) and n == sm120.PT)) return;
        if (u.n_dst == MAX_DST) return;
        u.dst[u.n_dst] = .{ .file = file, .n = n, .cat = cat };
        u.n_dst += 1;
    }

    fn addSrc(u: *Uses, file: File, n: u8, cat: u8) void {
        if (n == sm120.RZ or ((file == .pred or file == .upred) and n == sm120.PT)) return;
        if (u.n_src == MAX_SRC) return;
        u.src[u.n_src] = .{ .file = file, .n = n, .cat = cat };
        u.n_src += 1;
    }
};

fn r(c: lat.Reg) u8 {
    return @intFromEnum(c);
}

fn p(c: lat.Pred) u8 {
    return @intFromEnum(c);
}

fn ur(c: lat.Ureg) u8 {
    return @intFromEnum(c);
}

fn up(c: lat.Upred) u8 {
    return @intFromEnum(c);
}

/// The categories an instruction's operands of each file get.
const Cats = struct {
    gpr: u8 = 0,
    ugpr: u8 = 0,
    pred: u8 = 0,
    upred: u8 = 0,
};

/// An operand's registers: `width` consecutive general (or uniform)
/// registers from it; a predicate; an address's and a constant index's
/// registers (always read).
fn operand(u: *Uses, o: sm120.Operand, width: u8, dst: bool, c: Cats) void {
    switch (o) {
        .gpr => |g| {
            if (g.n == sm120.RZ) return;
            for (0..width) |k| {
                const n = g.n + @as(u8, @intCast(k));
                if (dst) u.addDst(.gpr, n, c.gpr) else u.addSrc(.gpr, n, c.gpr);
            }
        },
        .ugpr => |g| {
            if (g.n == sm120.RZ) return;
            for (0..width) |k| {
                const n = g.n + @as(u8, @intCast(k));
                if (dst) u.addDst(.ugpr, n, c.ugpr) else u.addSrc(.ugpr, n, c.ugpr);
            }
        },
        .pred => |q| if (dst) u.addDst(.pred, q.n, c.pred) else u.addSrc(.pred, q.n, c.pred),
        .upred => |q| if (dst) u.addDst(.upred, q.n, c.upred) else u.addSrc(.upred, q.n, c.upred),
        .addr => |a| {
            if (a.reg != sm120.RZ) {
                u.addSrc(.gpr, a.reg, c.gpr);
                if (a.wide) u.addSrc(.gpr, a.reg + 1, c.gpr);
            }
            if (a.ureg) |x| u.addSrc(.ugpr, x, c.ugpr);
            if (a.desc) |d| {
                u.addSrc(.ugpr, d, ur(.decoupled));
                u.addSrc(.ugpr, d + 1, ur(.decoupled));
            }
        },
        .cbuf => |cb| if (cb.reg != sm120.RZ) {
            if (cb.ureg) u.addSrc(.ugpr, cb.reg, c.ugpr) else u.addSrc(.gpr, cb.reg, c.gpr);
        },
        else => {},
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `in`'s operands, the first `n_dst` written and the rest read, each as
/// many registers as sm120.regsAt says.
fn regs(u: *Uses, in: *const sm120.Instr, n_dst: usize, c: Cats) void {
    for (in.operands(), 0..) |x, i| operand(u, x, sm120.regsAt(in, i), i < n_dst, c);
}

/// How many of `o`'s leading operands are written: predicates, then one
/// register, then predicates (LOP3's Pd before Rd, LEA's carry out after,
/// IADD3's two).
fn dstCount(o: []const sm120.Operand) usize {
    var n: usize = 0;
    while (n < o.len and (o[n] == .pred or o[n] == .upred)) n += 1;
    if (n < o.len and (o[n] == .gpr or o[n] == .ugpr)) n += 1;
    while (n < o.len and (o[n] == .pred or o[n] == .upred)) n += 1;
    return n;
}

/// The categories of the warp ALU ops: `cat` for general registers, a
/// coupled one for uniform registers they read, `pcat` for predicates.
fn warp(cat: lat.Reg, pcat: lat.Pred) Cats {
    return .{ .gpr = r(cat), .ugpr = ur(.coupled), .pred = p(pcat), .upred = up(.coupled) };
}

/// The uniform datapath's: everything `udp`.
const UDP = Cats{ .gpr = r(.alu), .ugpr = ur(.udp), .pred = p(.coupled), .upred = up(.udp) };

/// Variable-latency ops'.
fn decoupledCats(cat: lat.Reg) Cats {
    return .{ .gpr = r(cat), .ugpr = ur(.decoupled), .pred = p(.decoupled), .upred = up(.coupled) };
}

/// NAK's categories (sm120_instr_latencies.rs) for each register `in`
/// reads and writes. The forms NAK does not have: IADD as IADD3 (its
/// 64-bit form's results as a 64-bit dispatch), MOV.64 and I2FP's results
/// as a 64-bit dispatch's, UMOV.64 as UMOV, VIMNMX as IMNMX, FSEL and
/// FCHK as NAK's notes have them (alu, decoupled; FSEL's predicate as
/// SEL's), F2IP as F2FP, LOP3's predicate result as PLOP3's, CALL as a
/// branch, RET's registers as a branch's reads, WARPSYNC's as an ALU's.
pub fn usesOf(in: *const sm120.Instr) Error!Uses {
    var u = Uses{};
    const o = in.operands();
    const op = in.op;
    if (eql(op, "NOP") or eql(op, "BSSY") or eql(op, "BSYNC")) {
        // (convergence barriers have their own scoreboard)
        u.decoupled = !eql(op, "NOP");
        // (a BSYNC drains as a branch does: the lanes waiting there let
        // the warp's other paths run, which must not find their reads and
        // writes pending)
        u.branch = eql(op, "BSYNC");
    } else if (eql(op, "EXIT") or eql(op, "BRA") or eql(op, "CALL") or eql(op, "RET")) {
        u.decoupled = true;
        // (an EXIT drains as a branch does: the warp's lanes that did not
        // exit go on, elsewhere, and must not find this lane's reads and
        // writes still pending on the warp's scoreboards)
        u.branch = true;
        u.ends = (eql(op, "EXIT") or eql(op, "RET")) and in.guard.n == sm120.PT and !in.guard.not;
        regs(&u, in, 0, .{ .gpr = r(.branch), .pred = p(.decoupled), .upred = up(.bra_jmp) });
    } else if (eql(op, "WARPSYNC")) {
        // (its register read at issue, as an ALU's: the word cannot take
        // the scoreboard a branch's register read would; and ptxas's S05
        // after it, as BAR's exec latency)
        regs(&u, in, 0, .{ .gpr = r(.alu) });
        u.exec = 5;
    } else if (eql(op, "BAR")) {
        u.decoupled = true;
        u.exec = 6;
        regs(&u, in, 0, decoupledCats(.decoupled_agu));
    } else if (eql(op, "S2R") or eql(op, "LDG") or eql(op, "LDL") or eql(op, "LDS")) {
        u.decoupled = true;
        regs(&u, in, 1, decoupledCats(.decoupled_agu));
    } else if (eql(op, "S2UR") or eql(op, "LDCU")) {
        u.decoupled = true;
        regs(&u, in, 1, .{ .ugpr = ur(.to_ur) });
    } else if (eql(op, "LDC")) {
        u.decoupled = true;
        regs(&u, in, 1, decoupledCats(.decoupled));
    } else if (eql(op, "STG") or eql(op, "STL") or eql(op, "STS")) {
        u.decoupled = true;
        regs(&u, in, 0, decoupledCats(.decoupled_agu));
    } else if (eql(op, "ATOMG") or eql(op, "ATOMS")) {
        // (an atomic is a load and a store: NAK's Atom, decoupled_agu;
        // ATOMG writes its predicate and its old value)
        u.decoupled = true;
        regs(&u, in, if (eql(op, "ATOMG")) 2 else 1, decoupledCats(.decoupled_agu));
    } else if (eql(op, "SHFL")) {
        u.decoupled = true;
        regs(&u, in, 2, decoupledCats(.decoupled_agu));
    } else if (eql(op, "CS2R")) {
        regs(&u, in, 1, .{ .gpr = if (sm120.regsAt(in, 0) == 2) r(.disp_64) else r(.dualalu) });
    } else if (eql(op, "R2UR")) {
        operand(&u, o[0], 1, true, .{ .ugpr = ur(.r2ur) });
        operand(&u, o[1], 1, false, warp(.alu, .coupled));
    } else if (eql(op, "MOV")) {
        regs(&u, in, 1, if (in.has("64")) .{ .gpr = r(.disp_64) } else warp(.dualalu, .dualalu));
    } else if (eql(op, "UMOV")) {
        regs(&u, in, 1, .{ .ugpr = ur(.umov) });
    } else if (eql(op, "IADD")) {
        regs(&u, in, 1, warp(.alu, .coupled));
        // (the 64-bit form's results as a 64-bit dispatch's)
        if (in.has("64")) {
            for (u.dst[0..u.n_dst]) |*d| d.cat = r(.disp_64);
        }
    } else if (eql(op, "IADD3") or eql(op, "LOP3") or eql(op, "LEA") or eql(op, "PLOP3") or eql(op, "SHF") or
        eql(op, "PRMT") or eql(op, "IABS") or eql(op, "F2FP") or eql(op, "F2IP"))
    {
        regs(&u, in, if (eql(op, "PLOP3")) 2 else dstCount(o), warp(.alu, .coupled));
    } else if (eql(op, "FSEL")) {
        regs(&u, in, 1, warp(.alu, .dualalu));
    } else if (eql(op, "UIADD3") or eql(op, "ULOP3") or eql(op, "ULEA") or eql(op, "USHF") or eql(op, "UFFMA")) {
        regs(&u, in, dstCount(o), UDP);
    } else if (eql(op, "UISETP") or eql(op, "UPLOP3")) {
        regs(&u, in, 2, UDP);
    } else if (eql(op, "ISETP") or eql(op, "FSETP")) {
        regs(&u, in, 2, warp(.dualalu, .dualalu));
    } else if (eql(op, "SEL") or eql(op, "VIMNMX") or eql(op, "FMNMX")) {
        regs(&u, in, 1, warp(.dualalu, .dualalu));
    } else if (eql(op, "IMAD")) {
        if (in.has("WIDE")) {
            if (o[0] == .gpr and o[0].gpr.n != sm120.RZ) {
                u.addDst(.gpr, o[0].gpr.n, r(.imad_wide_write_dl));
                u.addDst(.gpr, o[0].gpr.n + 1, r(.imad_wide_write_dh));
            }
            operand(&u, o[1], 1, false, warp(.imad_wide_read_ab, .coupled));
            operand(&u, o[2], 1, false, warp(.imad_wide_read_ab, .coupled));
            if (o[3] == .gpr and o[3].gpr.n != sm120.RZ) {
                u.addSrc(.gpr, o[3].gpr.n, r(.imad_wide_read_cl));
                u.addSrc(.gpr, o[3].gpr.n + 1, r(.imad_wide_read_ch));
            } else operand(&u, o[3], 2, false, warp(.fma, .coupled));
        } else regs(&u, in, 1, warp(.fma, .fma));
    } else if (eql(op, "FFMA") or eql(op, "FADD") or eql(op, "FMUL") or eql(op, "IDP")) {
        regs(&u, in, 1, warp(.fma, .fma));
    } else if (eql(op, "HADD2") or eql(op, "HMUL2") or eql(op, "HFMA2")) {
        regs(&u, in, 1, warp(if (in.has("F32")) .fp16_f32 else .fp16, .fp16));
    } else if (eql(op, "HMNMX2")) {
        regs(&u, in, 1, warp(.fp16_alu, .fp16));
    } else if (eql(op, "I2FP")) {
        regs(&u, in, 1, warp(.alu, .coupled));
        for (u.dst[0..u.n_dst]) |*d| d.cat = r(.disp_64);
    } else if (eql(op, "MUFU") or eql(op, "POPC") or eql(op, "FLO") or eql(op, "BREV") or eql(op, "FCHK") or
        eql(op, "F2I") or eql(op, "I2F") or eql(op, "F2F") or eql(op, "FRND"))
    {
        u.decoupled = true;
        regs(&u, in, 1, decoupledCats(.decoupled));
    } else if (eql(op, "VOTE")) {
        // (the ballot's register is printed only when it is not RZ)
        regs(&u, in, if (o.len > 0 and o[0] == .gpr) 2 else 1, .{ .gpr = r(.dualalu), .pred = p(.disp_dual_alu) });
    } else if (eql(op, "VOTEU")) {
        regs(&u, in, 2, .{ .ugpr = ur(.voteu), .upred = up(.voteu), .pred = p(.disp_dual_alu) });
    } else if (eql(op, "HMMA")) {
        regs(&u, in, 1, .{ .gpr = r(.hmma) });
    } else if (eql(op, "IMMA")) {
        regs(&u, in, 1, .{ .gpr = r(.imma) });
    } else return error.Unknown;
    if (in.guard.n != sm120.PT) {
        if (in.uguard) u.addSrc(.upred, in.guard.n, up(.u_guard)) else u.addSrc(.pred, in.guard.n, p(.guard));
    }
    return u;
}

// ── Latencies ───────────────────────────────────────────────────────────────

pub const Kind = enum { raw, war, waw };

pub const Need = struct { cycles: u8, sb: bool };

fn entry(file: File, kind: Kind, second: u8, first: u8) u8 {
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

/// NAK's sm_120 adjustment for the tensor cores (measured on the RTX
/// chips, where sm_100's tables are short): 9 cycles more for HMMA's
/// registers, 7 for IMMA's.
fn adjust(u: Use) u8 {
    if (u.file != .gpr) return 0;
    if (u.cat == r(.hmma)) return 9;
    if (u.cat == r(.imma)) return 7;
    return 0;
}

/// What the hazard between `first` (an instruction's use of a register)
/// and `second` (a later one's) needs: NVIDIA's cycles, then for a read
/// after a write NAK's padding (at least one cycle; the tensor cores'
/// adjustment for general registers), for the others the adjustment.
pub fn need(kind: Kind, first: Use, first_decoupled: bool, second: Use) Need {
    const e = entry(first.file, kind, second.cat, first.cat);
    if (e == lat.N) return .{ .cycles = WORST, .sb = first_decoupled };
    const sb = e & lat.SB != 0;
    var c = e & ~lat.SB;
    const adj = @max(adjust(first), adjust(second));
    if (kind == .raw and !sb) c += @max(adj, PAD) else c += adj;
    return .{ .cycles = c, .sb = sb };
}

/// A fixed-latency result's longest wait to any reader (NAK's
/// worst_latency): what a branch drains.
fn worst(d: Use) u8 {
    var m: u8 = 0;
    const n: usize = switch (d.file) {
        .gpr => lat.reg_raw.len,
        .pred => lat.pred_raw.len,
        .ugpr => lat.ureg_raw.len,
        .upred => lat.upred_raw.len,
    };
    for (0..n) |row| {
        const e = entry(d.file, .raw, @intCast(row), d.cat);
        if (e == lat.N or e & lat.SB != 0) continue;
        m = @max(m, e);
    }
    return if (m == 0) WORST else m + @max(PAD, adjust(d));
}

// ── Hazards ─────────────────────────────────────────────────────────────────

pub const Which = enum(u1) { rd, wr };

pub const Hazard = struct {
    first: u32,
    kind: Kind,
    need: Need,
    /// For a scoreboard: the first instruction's reads or its writes.
    which: Which,
    /// The register's file (a drain's: the general registers).
    file: File = .gpr,
};

/// Calls `f(ctx, h)` for each hazard instruction `j` has with an earlier
/// one of its block (from `start`): its reads after their writes, its
/// writes after reads and writes; at a branch, every variable-latency
/// read and write still in flight.
fn hazards(uses: []const Uses, start: usize, j: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), Hazard) void) void {
    const u = &uses[j];
    for (u.srcs()) |s| {
        var i = j;
        while (i > start) {
            i -= 1;
            for (uses[i].dsts()) |d| {
                if (!d.same(s)) continue;
                f(ctx, .{ .first = @intCast(i), .kind = .raw, .need = need(.raw, d, uses[i].decoupled, s), .which = .wr, .file = d.file });
                break;
            } else continue;
            break;
        }
    }
    for (u.dsts()) |d| {
        var i = j;
        while (i > start) {
            i -= 1;
            var wrote = false;
            for (uses[i].srcs()) |s| {
                if (s.same(d)) f(ctx, .{ .first = @intCast(i), .kind = .war, .need = need(.war, s, uses[i].decoupled, d), .which = .rd, .file = s.file });
            }
            for (uses[i].dsts()) |e| {
                if (!e.same(d)) continue;
                f(ctx, .{ .first = @intCast(i), .kind = .waw, .need = need(.waw, e, uses[i].decoupled, d), .which = .wr, .file = e.file });
                wrote = true;
            }
            if (wrote) break;
        }
    }
    if (u.branch) {
        var i = start;
        while (i < j) : (i += 1) {
            if (!uses[i].decoupled) continue;
            const drain = Need{ .cycles = 0, .sb = true };
            if (uses[i].n_dst > 0) f(ctx, .{ .first = @intCast(i), .kind = .waw, .need = drain, .which = .wr });
            if (uses[i].readsRegs()) f(ctx, .{ .first = @intCast(i), .kind = .war, .need = drain, .which = .rd });
        }
    }
}

/// The cycle the instruction after a branch at `j` may start: every
/// fixed-latency result of its block ready to any reader.
fn drained(uses: []const Uses, cycle: []const u32, start: usize, j: usize) u32 {
    var c: u32 = cycle[j] + 1;
    for (start..j) |i| {
        if (uses[i].decoupled) continue;
        for (uses[i].dsts()) |d| c = @max(c, cycle[i] + worst(d));
    }
    return c;
}

// ── Scheduling ──────────────────────────────────────────────────────────────

pub const Work = struct {
    uses: [MAX_INSTRS]Uses = undefined,
    cycle: [MAX_INSTRS]u32 = undefined,
    need_rd: [MAX_INSTRS]bool = undefined,
    need_wr: [MAX_INSTRS]bool = undefined,
    /// The scoreboard an instruction's reads / writes hold, and its
    /// generation then (7: none).
    rd_bar: [MAX_INSTRS]u3 = undefined,
    wr_bar: [MAX_INSTRS]u3 = undefined,
    rd_gen: [MAX_INSTRS]u32 = undefined,
    wr_gen: [MAX_INSTRS]u32 = undefined,
};

/// An instruction's control field, and the NOPs that follow it (for a
/// stall over 15 cycles: each NOP has its own stall).
pub const Slot = struct { control: sm120.Control, nops: [2]u4 = .{ 0, 0 }, n_nops: u2 = 0 };

const Bars = struct {
    gen: [BARS]u32 = .{0} ** BARS,
    /// Producers on it since it was last waited.
    count: [BARS]u32 = .{0} ** BARS,
    /// The latest producer's index and cycle.
    last: [BARS]u32 = .{0} ** BARS,
    last_cycle: [BARS]u32 = .{0} ** BARS,

    fn held(b: *const Bars, bar: u3, gen: u32) bool {
        return bar != sm120.Control.NONE and b.gen[bar] == gen and b.count[bar] > 0;
    }

    fn take(b: *Bars, j: u32, cycle: u32) struct { bar: u3, gen: u32 } {
        var pick: usize = BARS;
        for (0..BARS) |k| {
            if (b.count[k] == 0) {
                pick = k;
                break;
            }
        }
        if (pick == BARS) {
            // all held: share the most recent producer's
            pick = 0;
            for (1..BARS) |k| {
                if (b.last[k] > b.last[pick]) pick = k;
            }
        }
        b.count[pick] += 1;
        b.last[pick] = j;
        b.last_cycle[pick] = cycle;
        return .{ .bar = @intCast(pick), .gen = b.gen[pick] };
    }

    fn free(b: *Bars, bar: usize) void {
        b.gen[bar] += 1;
        b.count[bar] = 0;
    }
};

const Pass1 = struct {
    w: *Work,
    fn mark(self: Pass1, h: Hazard) void {
        if (!h.need.sb) return;
        if (h.which == .rd) self.w.need_rd[h.first] = true else self.w.need_wr[h.first] = true;
    }
};

const Pass2 = struct {
    w: *Work,
    bars: *const Bars,
    wait: *u6,
    min: *u32,
    fn visit(self: Pass2, h: Hazard) void {
        const w = self.w;
        if (h.need.sb) {
            const bar = if (h.which == .rd) w.rd_bar[h.first] else w.wr_bar[h.first];
            const gen = if (h.which == .rd) w.rd_gen[h.first] else w.wr_gen[h.first];
            if (self.bars.held(bar, gen)) self.wait.* |= @as(u6, 1) << bar;
            self.min.* = @max(self.min.*, w.cycle[h.first] + @max(SB_SET, h.need.cycles));
        } else {
            self.min.* = @max(self.min.*, w.cycle[h.first] + h.need.cycles);
        }
    }
};

/// Control fields for `ins` (their own are ignored) into `out`.
pub fn schedule(ins: []const sm120.Instr, out: []Slot, w: *Work) Error!void {
    if (ins.len > MAX_INSTRS or out.len < ins.len) return error.TooManyInstructions;
    const n = ins.len;
    for (ins, 0..) |*in, i| {
        w.uses[i] = try usesOf(in);
        w.need_rd[i] = false;
        w.need_wr[i] = false;
        w.rd_bar[i] = sm120.Control.NONE;
        w.wr_bar[i] = sm120.Control.NONE;
    }
    const uses = w.uses[0..n];
    // Pass 1: which instructions' reads and writes are waited on.
    var start: usize = 0;
    for (0..n) |j| {
        hazards(uses, start, j, Pass1{ .w = w }, Pass1.mark);
        if (uses[j].branch or uses[j].ends) start = j + 1;
    }
    // Pass 2: scoreboards, waits and cycles, in order.
    var bars = Bars{};
    var floor: u32 = 0;
    start = 0;
    for (0..n) |j| {
        var wait: u6 = 0;
        // (an instruction with an exec latency holds the next one back)
        var min: u32 = if (j == 0) 0 else @max(w.cycle[j - 1] + uses[j - 1].exec, floor);
        hazards(uses, start, j, Pass2{ .w = w, .bars = &bars, .wait = &wait, .min = &min }, Pass2.visit);
        if (uses[j].branch) {
            for (0..BARS) |k| {
                if (bars.count[k] > 0) wait |= @as(u6, 1) << @intCast(k);
            }
        }
        // (a shared scoreboard: its latest setter's two cycles too)
        for (0..BARS) |k| {
            if (wait & (@as(u6, 1) << @intCast(k)) != 0) min = @max(min, bars.last_cycle[k] + SB_SET);
        }
        w.cycle[j] = min;
        for (0..BARS) |k| {
            if (wait & (@as(u6, 1) << @intCast(k)) != 0) bars.free(k);
        }
        var c = sm120.Control{ .wait = wait };
        if (w.need_rd[j]) {
            const t = bars.take(@intCast(j), min);
            w.rd_bar[j] = t.bar;
            w.rd_gen[j] = t.gen;
            c.read = t.bar;
        }
        if (w.need_wr[j]) {
            const t = bars.take(@intCast(j), min);
            w.wr_bar[j] = t.bar;
            w.wr_gen[j] = t.gen;
            c.write = t.bar;
        }
        out[j] = .{ .control = c };
        if (uses[j].branch) {
            floor = drained(uses, w.cycle[0..n], start, j);
            start = j + 1;
        } else {
            floor = 0;
            if (uses[j].ends) start = j + 1;
        }
    }
    // Pass 3: the stalls (and NOPs past 15 cycles).
    for (0..n) |j| split(if (j + 1 < n) w.cycle[j + 1] - w.cycle[j] else 1, &out[j]);
}

/// `gap` cycles to the next instruction: the stall, and NOPs for what is
/// past 15 (up to 45: NAK's latencies stay under 31).
pub fn split(gap: u32, slot: *Slot) void {
    slot.control.stall = @intCast(@min(gap, 15));
    var rest = @min(gap -| 15, 30);
    slot.n_nops = 0;
    while (rest > 0) : (slot.n_nops += 1) {
        const s: u4 = @intCast(@min(rest, 15));
        slot.nops[slot.n_nops] = s;
        rest -= s;
    }
}

// ── Checking ────────────────────────────────────────────────────────────────

pub const Report = struct {
    hazards: u32 = 0,
    /// Hazards the fields leave open: a fixed latency not waited for, a
    /// scoreboard not set, not waited on, or waited on too soon.
    open: u32 = 0,
    /// The kernel's cycles in order (its stalls and NOPs, summed).
    cycles: u32 = 0,
    waits: u32 = 0,
};

const CheckVisit = struct {
    slots: []const Slot,
    cycle: []const u32,
    j: usize,
    rep: *Report,
    fn visit(self: CheckVisit, h: Hazard) void {
        self.rep.hazards += 1;
        const i = h.first;
        if (!h.need.sb) {
            if (self.cycle[self.j] - self.cycle[i] < h.need.cycles) self.rep.open += 1;
            return;
        }
        const c = self.slots[i].control;
        const bar = if (h.which == .rd) c.read else c.write;
        if (bar == sm120.Control.NONE) {
            self.rep.open += 1;
            return;
        }
        // waited on by an instruction after it, by the second one at the
        // latest, and not before two cycles had passed
        var k: usize = i + 1;
        while (k <= self.j) : (k += 1) {
            if (self.slots[k].control.wait & (@as(u6, 1) << bar) != 0) {
                if (self.cycle[k] - self.cycle[i] < SB_SET) self.rep.open += 1;
                return;
            }
        }
        self.rep.open += 1;
    }
};

/// `slots`' fields for `ins` against the model: every hazard closed, every
/// branch drained.
pub fn check(ins: []const sm120.Instr, slots: []const Slot, w: *Work) Error!Report {
    if (ins.len > MAX_INSTRS) return error.TooManyInstructions;
    const n = ins.len;
    var c: u32 = 0;
    for (ins, 0..) |*in, i| {
        w.uses[i] = try usesOf(in);
        w.cycle[i] = c;
        c += slots[i].control.stall;
        for (slots[i].nops[0..slots[i].n_nops]) |s| c += s;
    }
    var rep = Report{ .cycles = c };
    const uses = w.uses[0..n];
    var start: usize = 0;
    for (0..n) |j| {
        if (slots[j].control.wait != 0) rep.waits += 1;
        if (j > 0 and w.cycle[j] - w.cycle[j - 1] < uses[j - 1].exec) rep.open += 1;
        hazards(uses, start, j, CheckVisit{ .slots = slots, .cycle = w.cycle[0..n], .j = j, .rep = &rep }, CheckVisit.visit);
        if (uses[j].branch) {
            if (j + 1 < n and w.cycle[j + 1] < drained(uses, w.cycle[0..n], start, j)) rep.open += 1;
            start = j + 1;
        } else if (uses[j].ends) start = j + 1;
    }
    return rep;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "latencies: NVIDIA's pairs, NAK's padding" {
    const lop3 = Use{ .file = .gpr, .n = 5, .cat = r(.alu) };
    const stg = Use{ .file = .gpr, .n = 5, .cat = r(.decoupled_agu) };
    // (an ALU result to a store: 5 cycles in the table, 6 with the padding)
    try testing.expectEqual(Need{ .cycles = 6, .sb = false }, need(.raw, lop3, false, stg));
    // (a load's result: a scoreboard)
    const ldg = Use{ .file = .gpr, .n = 9, .cat = r(.decoupled_agu) };
    const ffma = Use{ .file = .gpr, .n = 9, .cat = r(.fma) };
    try testing.expect(need(.raw, ldg, true, ffma).sb);
    // (a predicate to a guard: 13, 14)
    const isetp = Use{ .file = .pred, .n = 0, .cat = p(.dualalu) };
    const guard = Use{ .file = .pred, .n = 0, .cat = p(.guard) };
    try testing.expectEqual(Need{ .cycles = 14, .sb = false }, need(.raw, isetp, false, guard));
}

const Vectors = struct {
    var ins: [MAX_INSTRS]sm120.Instr = undefined;
    var theirs: [MAX_INSTRS]Slot = undefined;
    var mine: [MAX_INSTRS]Slot = undefined;
    var work: Work = .{};
};

/// ptxas's fields as the test's bar: where ptxas treats an instruction's
/// reads or writes as variable latency (it releases a scoreboard for
/// them), the model must too; and no hazard may be closer than both ptxas
/// has it and the model needs.
const Compare = struct {
    ins: []const sm120.Instr,
    theirs: []const Slot,
    c_theirs: []const u32,
    c_mine: []const u32,
    j: usize,
    bad: *u32,
    fn visit(self: Compare, h: Hazard) void {
        const i = h.first;
        if (h.need.sb) return;
        const c = self.theirs[i].control;
        // (a read scoreboard covers the registers a decoupled unit reads
        // later; predicates, a guard among them, are read at issue)
        const reg_read = h.file == .gpr or h.file == .ugpr;
        if ((h.which == .wr and c.write != sm120.Control.NONE) or (h.which == .rd and reg_read and c.read != sm120.Control.NONE)) {
            self.bad.* += 1;
            explain("ptxas takes a scoreboard where the model has a fixed latency", self.ins, i, self.j, h);
        }
        const mine = self.c_mine[self.j] - self.c_mine[i];
        const theirs = self.c_theirs[self.j] - self.c_theirs[i];
        if (mine < @min(theirs, h.need.cycles)) {
            self.bad.* += 1;
            explain("closer than ptxas and the model", self.ins, i, self.j, h);
        }
    }
};

fn explain(what: []const u8, ins: []const sm120.Instr, i: usize, j: usize, h: Hazard) void {
    var b1: [160]u8 = undefined;
    var b2: [160]u8 = undefined;
    const t1 = sm120.format(&ins[i], &b1) catch "?";
    const t2 = sm120.format(&ins[j], &b2) catch "?";
    std.debug.print("  {s}: {s} {d} cycles, sb {}\n    {d}: {s}\n    {d}: {s}\n", .{ what, @tagName(h.kind), h.need.cycles, h.need.sb, i, t1, j, t2 });
}

/// The test's own account of what `check` finds open (the same rules as
/// CheckVisit), printed.
const Open = struct {
    ins: []const sm120.Instr,
    slots: []const Slot,
    cycle: []const u32,
    j: usize,
    fn visit(self: Open, h: Hazard) void {
        const i = h.first;
        if (!h.need.sb) {
            if (self.cycle[self.j] - self.cycle[i] < h.need.cycles) explain("open (fixed)", self.ins, i, self.j, h);
            return;
        }
        const c = self.slots[i].control;
        const bar = if (h.which == .rd) c.read else c.write;
        if (bar == sm120.Control.NONE) return explain("open (no scoreboard)", self.ins, i, self.j, h);
        var k: usize = i + 1;
        while (k <= self.j) : (k += 1) {
            if (self.slots[k].control.wait & (@as(u6, 1) << bar) != 0) return;
        }
        explain("open (not waited on)", self.ins, i, self.j, h);
    }
};

test "ptxas's kernels without their fields: scheduled, checked, compared with ptxas's" {
    const data = @embedFile("sm120_vectors.txt");
    var kernels = std.mem.splitSequence(u8, data, "# kernel ");
    _ = kernels.next();
    var n_kernels: usize = 0;
    while (kernels.next()) |block| {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, block, '\n');
        _ = lines.next();
        var last_real: usize = 0;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len < 34 or line[0] == '#' or line[line.len - 1] == ':') continue;
            Vectors.ins[n] = try sm120.parse(line[34..]);
            Vectors.theirs[n] = .{ .control = Vectors.ins[n].control };
            if (!eql(Vectors.ins[n].op, "NOP")) last_real = n;
            n += 1;
        }
        // (the code, without ptxas's padding NOPs)
        n = last_real + 1;
        const ins = Vectors.ins[0..n];
        try schedule(ins, &Vectors.mine, &Vectors.work);
        const mine = try check(ins, Vectors.mine[0..n], &Vectors.work);
        const name = block[0 .. std.mem.indexOfScalar(u8, block, ' ') orelse 0];
        if (mine.open != 0) {
            std.debug.print("{s}: {d} open\n", .{ name, mine.open });
            var start: usize = 0;
            for (0..n) |j| {
                hazards(Vectors.work.uses[0..n], start, j, Open{ .ins = ins, .slots = Vectors.mine[0..n], .cycle = Vectors.work.cycle[0..n], .j = j }, Open.visit);
                if (Vectors.work.uses[j].branch or Vectors.work.uses[j].ends) start = j + 1;
            }
        }
        try testing.expect(mine.hazards > 0);
        try testing.expectEqual(@as(u32, 0), mine.open);
        // ptxas's own fields against the model (it relies on in-order
        // memory and needs one cycle less than NAK, so some are open in
        // the model's terms): informative, and its cycles to compare
        var c_mine: [MAX_INSTRS]u32 = undefined;
        var c_theirs: [MAX_INSTRS]u32 = undefined;
        var a: u32 = 0;
        var b: u32 = 0;
        for (0..n) |k| {
            c_mine[k] = a;
            c_theirs[k] = b;
            a += Vectors.mine[k].control.stall;
            for (Vectors.mine[k].nops[0..Vectors.mine[k].n_nops]) |s| a += s;
            b += Vectors.theirs[k].control.stall;
        }
        var bad: u32 = 0;
        var start: usize = 0;
        for (0..n) |j| {
            hazards(Vectors.work.uses[0..n], start, j, Compare{
                .ins = ins,
                .theirs = Vectors.theirs[0..n],
                .c_theirs = c_theirs[0..n],
                .c_mine = c_mine[0..n],
                .j = j,
                .bad = &bad,
            }, Compare.visit);
            if (Vectors.work.uses[j].branch or Vectors.work.uses[j].ends) start = j + 1;
        }
        if (bad != 0) std.debug.print("{s}: {d} against ptxas\n", .{ name, bad });
        try testing.expectEqual(@as(u32, 0), bad);
        n_kernels += 1;
    }
    try testing.expectEqual(@as(usize, 25), n_kernels);
}

test "stalls past 15 cycles: NOPs after the instruction" {
    var s = Slot{ .control = .{} };
    split(5, &s);
    try testing.expectEqual(@as(u4, 5), s.control.stall);
    try testing.expectEqual(@as(u2, 0), s.n_nops);
    split(20, &s);
    try testing.expectEqual(@as(u4, 15), s.control.stall);
    try testing.expectEqual(@as(u2, 1), s.n_nops);
    try testing.expectEqual(@as(u4, 5), s.nops[0]);
    split(31, &s);
    try testing.expectEqual(@as(u2, 2), s.n_nops);
    try testing.expectEqual([2]u4{ 15, 1 }, s.nops);
}

test "the tensor cores' adjustment, uniform predicates, BAR's exec latency" {
    // (an HMMA result to an FFMA: NVIDIA's 19 cycles, NAK's 9 more)
    const hmma = Use{ .file = .gpr, .n = 12, .cat = r(.hmma) };
    const ffma = Use{ .file = .gpr, .n = 12, .cat = r(.fma) };
    try testing.expectEqual(Need{ .cycles = 28, .sb = false }, need(.raw, hmma, false, ffma));
    const imma = Use{ .file = .gpr, .n = 12, .cat = r(.imma) };
    try testing.expectEqual(Need{ .cycles = 26, .sb = false }, need(.raw, imma, false, ffma)); // (19, 7 more)
    // (a uniform compare to BRA.U's predicate: 9, and the padding)
    const uisetp = Use{ .file = .upred, .n = 0, .cat = up(.udp) };
    const bra = Use{ .file = .upred, .n = 0, .cat = up(.bra_jmp) };
    try testing.expectEqual(Need{ .cycles = 10, .sb = false }, need(.raw, uisetp, false, bra));
    // the categories as usesOf gives them
    const u = try usesOf(&try sm120.parse("@!UP0 UIADD3 UR5, UPT, UPT, UR4, 0x1, URZ"));
    try testing.expectEqual(@as(usize, 1), u.dsts().len);
    try testing.expectEqual(Use{ .file = .upred, .n = 0, .cat = up(.u_guard) }, u.srcs()[1]);
    const hm = try usesOf(&try sm120.parse("HMMA.16816.F32 R12, R4, R2, R16"));
    try testing.expectEqual(@as(usize, 4), hm.dsts().len);
    try testing.expectEqual(@as(usize, 4 + 2 + 4), hm.srcs().len);
    const isu = try usesOf(&try sm120.parse("ISETP.GE.U64.AND P0, PT, R10, R4, PT"));
    try testing.expectEqual(@as(usize, 4), isu.srcs().len);
    // a barrier holds the next instruction back six cycles
    const text = [_][]const u8{
        "BAR.SYNC.DEFER_BLOCKING 0x0",
        "IADD R0, R1, 0x1",
        "EXIT",
    };
    var ins: [3]sm120.Instr = undefined;
    for (text, 0..) |x, i| ins[i] = try sm120.parse(x);
    var out: [3]Slot = undefined;
    try schedule(&ins, &out, &Vectors.work);
    try testing.expectEqual(@as(u4, 6), out[0].control.stall);
    try testing.expectEqual(@as(u32, 0), (try check(&ins, &out, &Vectors.work)).open);
    out[0].control.stall = 5;
    try testing.expectEqual(@as(u32, 1), (try check(&ins, &out, &Vectors.work)).open);
}

test "a guard after its predicate, the predicate after a special register" {
    const text = [_][]const u8{
        "S2R R0, SR_TID.X",
        "ISETP.GE.U32.AND P0, PT, R0, 0x20, PT",
        "@P0 EXIT",
        "EXIT",
    };
    var ins: [4]sm120.Instr = undefined;
    for (text, 0..) |t, i| ins[i] = try sm120.parse(t);
    var out: [4]Slot = undefined;
    try schedule(&ins, &out, &Vectors.work);
    try testing.expectEqual(@as(u3, 0), out[0].control.write); // (S2R: scoreboard 0)
    try testing.expectEqual(@as(u6, 1), out[1].control.wait); // (ISETP waits on it)
    try testing.expectEqual(@as(u4, 14), out[1].control.stall); // (the guard's 13 + 1)
    try testing.expectEqual(@as(u2, 0), out[1].n_nops);
    const rep = try check(&ins, &out, &Vectors.work);
    try testing.expectEqual(@as(u32, 0), rep.open);
    // a field that says less is caught
    out[1].control.stall = 13;
    try testing.expectEqual(@as(u32, 1), (try check(&ins, &out, &Vectors.work)).open);
}
