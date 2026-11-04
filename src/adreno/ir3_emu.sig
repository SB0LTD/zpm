//! @zpm/adreno ir3_emu — a functional emulator of ir3 compute kernels.
//!
//! There is no Adreno to test against on a PC, so kernels run here first:
//! the same instruction words the GPU gets are decoded and executed, fiber
//! by fiber, wave by wave, workgroup by workgroup, against the same memory
//! layout (GPU virtual addresses, the constants of the dispatch). Results
//! are compared with zpm's CPU reference.
//!
//! What it models: the vector ALU (f32/f16, integers, the 24-bit and 16-bit
//! multiplies, the bitfield ops, dp4acc), the SFU (exact math, the hardware
//! is approximate: float paths are compared with a tolerance), global and
//! local memory, shuffles, barriers, and divergent control flow (each fiber
//! has its own pc; the lowest runs first, as structured code reconverges).
//!
//! It also checks timing hazards the hardware does not interlock: a read of
//! a register an earlier load or SFU op has not delivered without (sy)/(ss),
//! or of an ALU result before its delay slots have passed. Those are errors,
//! not silent reads: on the GPU they would read stale data.
//!
//! Allocation-free: the caller owns the Work (several MB: keep it static).

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");

const Instr = ir3.Instr;
const Src = ir3.Src;

pub const MAX_FIBERS = 1024;
/// Full registers r0.x..r47.w per fiber.
pub const NREGS = 48 * 4;
pub const MAX_WAVES = MAX_FIBERS / 64;
pub const LOCAL_BYTES = 32 * 1024;
pub const MAX_STEPS: u64 = 400_000_000;

pub const Error = error{
    BadInstruction,
    Unsupported,
    Fault,
    Hazard,
    Divergence,
    Timeout,
    BadDispatch,
} || ir3.Error;

/// A region of GPU-visible memory.
pub const Region = struct { va: u64, bytes: []u8 };

pub const Memory = struct {
    regions: []const Region,

    pub fn find(m: *const Memory, va: u64, len: usize) ?[]u8 {
        for (m.regions) |r| {
            if (va >= r.va and va + len <= r.va + r.bytes.len) return r.bytes[@intCast(va - r.va)..][0..len];
        }
        return null;
    }
};

pub const Dispatch = struct {
    kernel: *const ir3_asm.Kernel,
    /// The constant file as dwords (c0.x, c0.y, ...).
    consts: []const u32,
    groups: [3]u32,
    /// Optional: only these workgroup x indices run (for sampling big grids).
    first_group: u32 = 0,
    group_stride: u32 = 1,
};

pub const Stats = struct {
    workgroups: u64 = 0,
    waves: u64 = 0,
    instructions: u64 = 0,
    /// Fiber-instructions executed (per active fiber).
    fiber_ops: u64 = 0,
    global_bytes_read: u64 = 0,
    global_bytes_written: u64 = 0,
};

const FState = enum(u8) { off, run, bar, done };

pub const Work = struct {
    code: [ir3_asm.MAX_INSTRS]Instr = undefined,
    n_code: u32 = 0,
    regs: [MAX_FIBERS][NREGS]u32 = undefined,
    pred: [MAX_FIBERS][4]bool = undefined,
    a0: [MAX_FIBERS]i32 = undefined,
    a1: [MAX_FIBERS]i32 = undefined,
    pc: [MAX_FIBERS]u32 = undefined,
    st: [MAX_FIBERS]FState = undefined,
    shared: [MAX_WAVES][32]u32 = undefined,
    local: [LOCAL_BYTES]u8 = undefined,
    // Hazard tracking, per wave.
    slot: [MAX_WAVES]u64 = undefined,
    /// Per register unit (half units 0..511, like ir3_asm): pending (ss)/(sy)
    /// and the slot an ALU / non-ALU reader may read from.
    pend_ss: [MAX_WAVES][8]u64 = undefined,
    pend_sy: [MAX_WAVES][8]u64 = undefined,
    ready_alu: [MAX_WAVES][512]u64 = undefined,
    ready_non: [MAX_WAVES][512]u64 = undefined,
    /// Where an error happened (instruction index), for messages.
    err_pc: u32 = 0,
    check_hazards: bool = true,
};

// ── Register access ─────────────────────────────────────────────────────────

const Ctx = struct {
    w: *Work,
    mem: *const Memory,
    d: *const Dispatch,
    wave: u32,
    threadsize: u32,
    stats: *Stats,
    delays: ir3_asm.Delays,
};

fn isShared(num: u16) bool {
    return num >= ir3.SHARED_BASE and num < ir3.A0_X;
}

fn readFull(c: *const Ctx, f: u32, num: u16) u32 {
    if (num < NREGS) return c.w.regs[f][num];
    if (isShared(num)) return c.w.shared[c.wave][num - ir3.SHARED_BASE];
    if (num == ir3.A0_X) return @bitCast(c.w.a0[f]);
    if (num == ir3.A1_X) return @bitCast(c.w.a1[f]);
    if (num >= ir3.P0_X and num < ir3.P0_X + 4) return @intFromBool(c.w.pred[f][num - ir3.P0_X]);
    return 0;
}

fn writeFull(c: *Ctx, f: u32, num: u16, v: u32) void {
    if (num < NREGS) {
        c.w.regs[f][num] = v;
    } else if (isShared(num)) {
        c.w.shared[c.wave][num - ir3.SHARED_BASE] = v;
    } else if (num == ir3.A0_X) {
        c.w.a0[f] = @bitCast(v);
    } else if (num == ir3.A1_X) {
        c.w.a1[f] = @bitCast(v);
    } else if (num >= ir3.P0_X and num < ir3.P0_X + 4) {
        c.w.pred[f][num - ir3.P0_X] = v != 0;
    }
}

/// Half registers share the full file: hrN.c is half (N.c & 1) of r(N.c / 2).
fn readHalf(c: *const Ctx, f: u32, num: u16) u16 {
    const full = readFull(c, f, num >> 1);
    return if (num & 1 == 0) @truncate(full) else @truncate(full >> 16);
}

fn writeHalf(c: *Ctx, f: u32, num: u16, v: u16) void {
    if (num >= ir3.P0_X and num < ir3.P0_X + 4) {
        writeFull(c, f, num, v);
        return;
    }
    const old = readFull(c, f, num >> 1);
    const nv = if (num & 1 == 0) (old & 0xffff_0000) | v else (old & 0x0000_ffff) | (@as(u32, v) << 16);
    writeFull(c, f, num >> 1, nv);
}

fn readReg(c: *const Ctx, f: u32, num: u16, half: bool) u32 {
    return if (half) readHalf(c, f, num) else readFull(c, f, num);
}

fn writeReg(c: *Ctx, f: u32, num: u16, half: bool, v: u32) void {
    if (half) writeHalf(c, f, num, @truncate(v)) else writeFull(c, f, num, v);
}

fn constAt(c: *const Ctx, num: i32) u32 {
    if (num < 0 or num >= c.d.consts.len) return 0;
    return c.d.consts[@intCast(num)];
}

/// A source operand's raw bits (before modifiers), half or full.
fn srcBits(c: *const Ctx, f: u32, s: Src, i: u32) u32 {
    const step: u16 = if (s.r) @intCast(i) else 0;
    return switch (s.kind) {
        .gpr => readReg(c, f, s.num + step, s.half),
        .cnst => blk: {
            const v = constAt(c, s.num + step);
            break :blk if (s.half) v & 0xffff else v;
        },
        .imm => s.imm,
        .flut => flutBits(s.imm, s.half),
        .rel_gpr => readReg(c, f, @intCast(@max(0, c.w.a0[f] + s.off + @as(i32, step))), s.half),
        .rel_cnst => constAt(c, c.w.a0[f] + s.off + @as(i32, step)),
        .none => 0,
    };
}

fn flutBits(idx: u32, half: bool) u32 {
    const vals = [_]f32{ 0.0, 0.5, 1.0, 2.0, std.math.e, std.math.pi, 1.0 / std.math.pi, 1.0 / std.math.log2e, std.math.log2e, 1.0 / std.math.log2(10.0), std.math.log2(10.0), 4.0 };
    const v = if (idx < vals.len) vals[idx] else 0;
    return if (half) @as(u16, @bitCast(@as(f16, @floatCast(v)))) else @bitCast(v);
}

fn f32of(b: u32) f32 {
    return @bitCast(b);
}
fn f16of(b: u32) f16 {
    return @bitCast(@as(u16, @truncate(b)));
}

/// A float source with its (abs)/(neg), widened to f32.
fn fsrc(c: *const Ctx, f: u32, s: Src, i: u32) f32 {
    const b = srcBits(c, f, s, i);
    var v: f32 = if (s.half) @floatCast(f16of(b)) else f32of(b);
    if (s.kind == .imm and !s.half) v = f32of(b);
    if (s.abs) v = @abs(v);
    if (s.neg) v = -v;
    return v;
}

/// An integer source with its modifiers: (abs)/(neg) as signed, (not) bitwise.
fn isrc(c: *const Ctx, f: u32, s: Src, i: u32) u32 {
    var b = srcBits(c, f, s, i);
    if (s.half and s.kind != .imm) b = @as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(b)))))));
    if (s.kind == .imm) b = s.imm;
    if (s.abs) b = absWrap(b);
    if (s.neg) b = 0 -% b;
    if (s.bnot) b = ~b;
    return b;
}

/// (abs) of a 32-bit integer: |INT_MIN| wraps to INT_MIN, as the ALU's
/// two's complement negation does.
fn absWrap(b: u32) u32 {
    return if (@as(i32, @bitCast(b)) < 0) 0 -% b else b;
}

fn usrc(c: *const Ctx, f: u32, s: Src, i: u32) u32 {
    var b = srcBits(c, f, s, i);
    if (s.half and s.kind != .imm) b &= 0xffff;
    if (s.abs) b = absWrap(b);
    if (s.neg) b = 0 -% b;
    if (s.bnot) b = ~b;
    return b;
}

fn putF(c: *Ctx, f: u32, dst: u16, half: bool, v: f32, sat: bool) void {
    const x = if (sat) std.math.clamp(v, 0.0, 1.0) else v;
    if (half) writeReg(c, f, dst, true, @as(u16, @bitCast(@as(f16, @floatCast(x))))) else writeReg(c, f, dst, false, @bitCast(x));
}

// ── Type conversion (cat1) ──────────────────────────────────────────────────

fn readTyped(c: *const Ctx, f: u32, in: *const Instr, i: u32) f64 {
    const s = in.src[0];
    const b = srcBits(c, f, s, i);
    return switch (in.src_type) {
        .f32 => f32of(b),
        .f16 => f16of(b),
        .u32 => @floatFromInt(b),
        .s32 => @floatFromInt(@as(i32, @bitCast(b))),
        .u16 => @floatFromInt(@as(u16, @truncate(b))),
        .s16 => @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(b))))),
        .u8 => @floatFromInt(@as(u8, @truncate(b))),
        .u8_32 => @floatFromInt(@as(i8, @bitCast(@as(u8, @truncate(b))))),
    };
}

fn isIntType(t: ir3.Type) bool {
    return t != .f16 and t != .f32;
}

fn movValue(c: *const Ctx, f: u32, in: *const Instr, i: u32) u32 {
    const st = in.src_type;
    const dt = in.dst_type;
    const raw = srcBits(c, f, in.src[0], i);
    // Same type, or integer to integer: bits (sign/zero extended or cut).
    if (st == dt) return raw;
    if (isIntType(st) and isIntType(dt)) {
        const v: i64 = switch (st) {
            .u32 => raw,
            .s32 => @as(i32, @bitCast(raw)),
            .u16 => @as(u16, @truncate(raw)),
            .s16 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
            .u8 => @as(u8, @truncate(raw)),
            .u8_32 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
            else => unreachable,
        };
        return @truncate(@as(u64, @bitCast(v)));
    }
    const x = readTyped(c, f, in, i);
    return switch (dt) {
        .f32 => @bitCast(@as(f32, @floatCast(x))),
        .f16 => blk: {
            // f32 -> f16: (even) rounds to nearest, otherwise toward zero.
            if (in.round == .even) break :blk @as(u16, @bitCast(@as(f16, @floatCast(x))));
            break :blk @as(u16, @bitCast(f16TowardZero(@floatCast(x))));
        },
        .u32 => @intFromFloat(std.math.clamp(roundI(x, in.round), 0, 4294967295.0)),
        .s32 => @bitCast(@as(i32, @intFromFloat(std.math.clamp(roundI(x, in.round), -2147483648.0, 2147483647.0)))),
        .u16 => @intFromFloat(std.math.clamp(roundI(x, in.round), 0, 65535.0)),
        .s16 => @as(u16, @bitCast(@as(i16, @intFromFloat(std.math.clamp(roundI(x, in.round), -32768.0, 32767.0))))),
        .u8 => @intFromFloat(std.math.clamp(roundI(x, in.round), 0, 255.0)),
        .u8_32 => @as(u8, @bitCast(@as(i8, @intFromFloat(std.math.clamp(roundI(x, in.round), -128.0, 127.0))))),
    };
}

fn roundI(x: f64, r: ir3.Round) f64 {
    if (std.math.isNan(x)) return 0;
    return switch (r) {
        .none => @trunc(x),
        .even => @round(x) - (if (@abs(x - @trunc(x)) == 0.5 and @mod(@trunc(x), 2.0) == 0) @round(x) - @trunc(x) else 0),
        .pos_infinity => @ceil(x),
        .neg_infinity => @floor(x),
    };
}

fn f16TowardZero(x: f32) f16 {
    const r: f16 = @floatCast(x);
    const back: f32 = r;
    if (@abs(back) > @abs(x)) {
        // step one ulp toward zero
        const bits: u16 = @bitCast(r);
        return @bitCast(bits - 1);
    }
    return r;
}

// ── Hazard tracking ─────────────────────────────────────────────────────────

fn unitRange(num: u16, half: bool, out: *[2]u16) usize {
    if (half) {
        out[0] = num;
        return 1;
    }
    out[0] = num * 2;
    out[1] = num * 2 + 1;
    return 2;
}

fn bitGet(b: *const [8]u64, u: u16) bool {
    return b[u >> 6] >> @intCast(u & 63) & 1 != 0;
}
fn bitSet(b: *[8]u64, u: u16) void {
    b[u >> 6] |= @as(u64, 1) << @intCast(u & 63);
}

fn checkRead(c: *Ctx, num: u16, half: bool, alu: bool, slot: u64) Error!void {
    if (!c.w.check_hazards) return;
    if (num >= 256 and !half) return;
    var u: [2]u16 = undefined;
    const n = unitRange(num, half, &u);
    for (u[0..n]) |x| {
        if (x >= 512) continue;
        if (bitGet(&c.w.pend_ss[c.wave], x) or bitGet(&c.w.pend_sy[c.wave], x)) return error.Hazard;
        const ready = if (alu) c.w.ready_alu[c.wave][x] else c.w.ready_non[c.wave][x];
        if (slot < ready) return error.Hazard;
    }
}

fn noteWrite(c: *Ctx, num: u16, half: bool, kind: enum { alu, mova, ss, sy, none }, slot: u64) void {
    if (num >= 256 and !half) return;
    var u: [2]u16 = undefined;
    const n = unitRange(num, half, &u);
    for (u[0..n]) |x| {
        if (x >= 512) continue;
        const w = c.wave;
        switch (kind) {
            .alu => {
                c.w.ready_alu[w][x] = slot + 1 + c.delays.alu_to_alu;
                c.w.ready_non[w][x] = slot + 1 + c.delays.non_alu;
            },
            .mova => {
                c.w.ready_alu[w][x] = slot + 1 + c.delays.non_alu;
                c.w.ready_non[w][x] = slot + 1 + c.delays.non_alu;
            },
            .ss => bitSet(&c.w.pend_ss[w], x),
            .sy => bitSet(&c.w.pend_sy[w], x),
            .none => {
                c.w.ready_alu[w][x] = 0;
                c.w.ready_non[w][x] = 0;
            },
        }
    }
}

// ── Execution ───────────────────────────────────────────────────────────────

fn isAluOp(in: *const Instr) bool {
    const k = in.op.category();
    return k >= 1 and k <= 3;
}

fn isMadOp(op: ir3.Op) bool {
    return switch (op) {
        .mad_u16, .madsh_u16, .mad_s16, .madsh_m16, .mad_u24, .mad_s24, .mad_f16, .mad_f32, .mad_f16_mul2, .mad_f32_mul2, .mad_f16_div2, .mad_f32_div2 => true,
        else => false,
    };
}

/// Check the reads of one repetition of `in`.
fn checkSources(c: *Ctx, in: *const Instr, i: u32, slot: u64) Error!void {
    const alu = isAluOp(in);
    const n: usize = switch (in.op.category()) {
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 1,
        else => 0,
    };
    for (0..n) |k| {
        const s = in.src[k];
        if (s.kind != .gpr) continue;
        const num = s.num + (if (s.r) @as(u16, @intCast(i)) else 0);
        // mad reads its third source a cycle late
        const sl = if (k == 2 and isMadOp(in.op)) slot + c.delays.cat3_src2_read else slot;
        // half/full mismatch costs three more slots on the ALU
        try checkRead(c, num, s.half, alu, sl);
    }
}

const Mask = std.bit_set.IntegerBitSet(128);

fn execute(c: *Ctx, pc: u32, fibers: []const u32) Error!void {
    const in = &c.w.code[pc];
    const w = c.w;
    const cat = in.op.category();
    const wave = c.wave;
    const slot0 = w.slot[wave];
    // Syncs settle first.
    if (in.ss) w.pend_ss[wave] = .{0} ** 8;
    if (in.sy) w.pend_sy[wave] = .{0} ** 8;
    const reps: u32 = @as(u32, in.repeat) + 1;
    c.stats.instructions += 1;
    c.stats.fiber_ops += fibers.len * reps;
    switch (cat) {
        0 => {
            switch (in.op) {
                .nop => {},
                .end => for (fibers) |f| {
                    w.st[f] = .done;
                },
                .br, .bany, .ball, .brao, .braa, .jump => {
                    if (in.op != .jump) try checkRead(c, ir3.P0_X + in.comp1, false, false, slot0);
                    var any = false;
                    var all = true;
                    for (fibers) |f| {
                        const p1 = w.pred[f][in.comp1] != in.inv1;
                        if (p1) any = true else all = false;
                    }
                    for (fibers) |f| {
                        const p1 = w.pred[f][in.comp1] != in.inv1;
                        const p2 = w.pred[f][in.comp2] != in.inv2;
                        const take = switch (in.op) {
                            .br => p1,
                            .bany => any,
                            .ball => all,
                            .brao => p1 or p2,
                            .braa => p1 and p2,
                            .jump => true,
                            else => unreachable,
                        };
                        w.pc[f] = if (take) @intCast(@as(i64, pc) + in.imm) else pc + 1;
                    }
                    w.slot[wave] = slot0 + reps;
                    return;
                },
                else => return error.Unsupported,
            }
        },
        1 => try execCat1(c, in, fibers, slot0),
        2 => try execCat2(c, in, fibers, slot0),
        3 => try execCat3(c, in, fibers, slot0),
        4 => try execCat4(c, in, fibers, slot0),
        6 => try execCat6(c, in, fibers, slot0),
        7 => {},
        else => return error.Unsupported,
    }
    for (fibers) |f| w.pc[f] = pc + 1;
    w.slot[wave] = slot0 + reps + in.nop;
}

fn execCat1(c: *Ctx, in: *const Instr, fibers: []const u32, slot0: u64) Error!void {
    switch (in.op) {
        .mov => {},
        else => return error.Unsupported,
    }
    const reps: u32 = @as(u32, in.repeat) + 1;
    for (0..reps) |ri| {
        const i: u32 = @intCast(ri);
        try checkSources(c, in, i, slot0 + i);
        for (fibers) |f| {
            const v = movValue(c, f, in, i);
            if (in.dst.rel) {
                writeReg(c, f, @intCast(@max(0, c.w.a0[f] + @as(i32, in.dst.num) + @as(i32, @intCast(i)))), in.dst.half, v);
            } else {
                writeReg(c, f, in.dst.num + @as(u16, @intCast(i)), in.dst.half, v);
            }
        }
        if (!in.dst.rel) {
            const mova = in.dst.num == ir3.A0_X or in.dst.num == ir3.A1_X;
            noteWrite(c, in.dst.num + @as(u16, @intCast(i)), in.dst.half, if (mova) .mova else .alu, slot0 + i);
        }
    }
}

fn cmp(cond: ir3.Cond, comptime T: type, a: T, b: T) bool {
    return switch (cond) {
        .lt => a < b,
        .le => a <= b,
        .gt => a > b,
        .ge => a >= b,
        .eq => a == b,
        .ne => a != b,
    };
}

fn execCat2(c: *Ctx, in: *const Instr, fibers: []const u32, slot0: u64) Error!void {
    const reps: u32 = @as(u32, in.repeat) + 1;
    const half_src = in.src[0].half;
    for (0..reps) |ri| {
        const i: u32 = @intCast(ri);
        try checkSources(c, in, i, slot0 + i);
        const dst = in.dst.num + @as(u16, @intCast(i));
        const is_p = dst >= ir3.P0_X and dst < ir3.P0_X + 4;
        // up0: a0.c as destination means the predicate.
        const dnum = if (dst >= ir3.A0_X and dst < ir3.A0_X + 4) ir3.P0_X + (dst - ir3.A0_X) else dst;
        const dhalf = in.dst.half and !is_p;
        for (fibers) |f| {
            const s0 = in.src[0];
            const s1 = in.src[1];
            var res: u32 = 0;
            var fres: ?f32 = null;
            switch (in.op) {
                .add_f => fres = fsrc(c, f, s0, i) + fsrc(c, f, s1, i),
                .mul_f => fres = fsrc(c, f, s0, i) * fsrc(c, f, s1, i),
                .min_f => fres = @min(fsrc(c, f, s0, i), fsrc(c, f, s1, i)),
                .max_f => fres = @max(fsrc(c, f, s0, i), fsrc(c, f, s1, i)),
                .sign_f => {
                    const x = fsrc(c, f, s0, i);
                    fres = if (x > 0) 1.0 else if (x < 0) -1.0 else 0.0;
                },
                .absneg_f => fres = fsrc(c, f, s0, i),
                .floor_f => fres = @floor(fsrc(c, f, s0, i)),
                .ceil_f => fres = @ceil(fsrc(c, f, s0, i)),
                .trunc_f => fres = @trunc(fsrc(c, f, s0, i)),
                .rndne_f => {
                    const x = fsrc(c, f, s0, i);
                    const r = @round(x);
                    fres = if (@abs(x - @trunc(x)) == 0.5 and @mod(r, 2.0) != 0) r - std.math.sign(x) else r;
                },
                .rndaz_f => fres = @round(fsrc(c, f, s0, i)),
                .cmps_f => res = @intFromBool(cmp(in.cond, f32, fsrc(c, f, s0, i), fsrc(c, f, s1, i))),
                .cmpv_f => res = if (cmp(in.cond, f32, fsrc(c, f, s0, i), fsrc(c, f, s1, i))) 0xffff_ffff else 0,
                .add_u, .add_s => res = isrc(c, f, s0, i) +% isrc(c, f, s1, i),
                .sub_u, .sub_s => res = isrc(c, f, s0, i) -% isrc(c, f, s1, i),
                .cmps_u => res = @intFromBool(cmp(in.cond, u32, usrc(c, f, s0, i), usrc(c, f, s1, i))),
                .cmps_s => res = @intFromBool(cmp(in.cond, i32, @bitCast(isrc(c, f, s0, i)), @bitCast(isrc(c, f, s1, i)))),
                .cmpv_u => res = if (cmp(in.cond, u32, usrc(c, f, s0, i), usrc(c, f, s1, i))) 0xffff_ffff else 0,
                .cmpv_s => res = if (cmp(in.cond, i32, @bitCast(isrc(c, f, s0, i)), @bitCast(isrc(c, f, s1, i)))) 0xffff_ffff else 0,
                .min_u => res = @min(usrc(c, f, s0, i), usrc(c, f, s1, i)),
                .max_u => res = @max(usrc(c, f, s0, i), usrc(c, f, s1, i)),
                .min_s => res = @bitCast(@min(@as(i32, @bitCast(isrc(c, f, s0, i))), @as(i32, @bitCast(isrc(c, f, s1, i))))),
                .max_s => res = @bitCast(@max(@as(i32, @bitCast(isrc(c, f, s0, i))), @as(i32, @bitCast(isrc(c, f, s1, i))))),
                .absneg_s => res = isrc(c, f, s0, i),
                .and_b => res = usrc(c, f, s0, i) & usrc(c, f, s1, i),
                .or_b => res = usrc(c, f, s0, i) | usrc(c, f, s1, i),
                .xor_b => res = usrc(c, f, s0, i) ^ usrc(c, f, s1, i),
                .not_b => res = ~usrc(c, f, s0, i),
                .shl_b => res = std.math.shl(u32, usrc(c, f, s0, i), usrc(c, f, s1, i) & 31),
                .shr_b => res = std.math.shr(u32, usrc(c, f, s0, i), usrc(c, f, s1, i) & 31),
                .ashr_b => res = @bitCast(@as(i32, @bitCast(usrc(c, f, s0, i))) >> @intCast(usrc(c, f, s1, i) & 31)),
                .mul_u24 => res = @truncate(@as(u64, usrc(c, f, s0, i) & 0xff_ffff) * (usrc(c, f, s1, i) & 0xff_ffff)),
                .mul_s24 => {
                    const a: i64 = @as(i32, @bitCast(isrc(c, f, s0, i) << 8)) >> 8;
                    const b: i64 = @as(i32, @bitCast(isrc(c, f, s1, i) << 8)) >> 8;
                    res = @truncate(@as(u64, @bitCast(a * b)));
                },
                .mull_u => res = (usrc(c, f, s0, i) & 0xffff) * (usrc(c, f, s1, i) & 0xffff),
                .bfrev_b => res = @bitReverse(usrc(c, f, s0, i)),
                .clz_b => res = @clz(usrc(c, f, s0, i)),
                .clz_s => {
                    const v: i32 = @bitCast(usrc(c, f, s0, i));
                    res = if (v < 0) @clz(~@as(u32, @bitCast(v))) else @clz(@as(u32, @bitCast(v)));
                },
                .cbits_b => res = @popCount(usrc(c, f, s0, i)),
                .getbit_b => res = (usrc(c, f, s0, i) >> @intCast(usrc(c, f, s1, i) & 31)) & 1,
                .mgen_b => {
                    const lo = usrc(c, f, s0, i) & 31;
                    const cnt = usrc(c, f, s1, i);
                    const m: u64 = if (cnt >= 32) 0xffff_ffff else (@as(u64, 1) << @intCast(cnt)) - 1;
                    res = @truncate(m << @intCast(lo));
                },
                else => return error.Unsupported,
            }
            if (fres) |x| {
                // integer immediates in float ops are not modelled
                putF(c, f, dnum, dhalf, x, in.sat);
            } else {
                if (half_src and !is_p) res &= 0xffff;
                writeReg(c, f, dnum, dhalf, res);
            }
        }
        noteWrite(c, dnum, dhalf, .alu, slot0 + i);
    }
}

fn execCat3(c: *Ctx, in: *const Instr, fibers: []const u32, slot0: u64) Error!void {
    const reps: u32 = @as(u32, in.repeat) + 1;
    for (0..reps) |ri| {
        const i: u32 = @intCast(ri);
        try checkSources(c, in, i, slot0 + i);
        const dst = in.dst.num + @as(u16, @intCast(i));
        const dhalf = in.dst.half;
        for (fibers) |f| {
            const s0 = in.src[0];
            const s1 = in.src[1];
            const s2 = in.src[2];
            switch (in.op) {
                .mad_f32, .mad_f16 => {
                    const v = fsrc(c, f, s0, i) * fsrc(c, f, s1, i) + fsrc(c, f, s2, i);
                    putF(c, f, dst, dhalf, v, in.sat);
                    continue;
                },
                .sel_f32, .sel_f16 => {
                    const cond = fsrc(c, f, s1, i);
                    putF(c, f, dst, dhalf, if (cond != 0) fsrc(c, f, s0, i) else fsrc(c, f, s2, i), false);
                    continue;
                },
                else => {},
            }
            const res: u32 = switch (in.op) {
                .mad_u24 => @as(u32, @truncate(@as(u64, usrc(c, f, s0, i) & 0xff_ffff) * (usrc(c, f, s1, i) & 0xff_ffff))) +% usrc(c, f, s2, i),
                .mad_s24 => blk: {
                    const a: i64 = @as(i32, @bitCast(isrc(c, f, s0, i) << 8)) >> 8;
                    const b: i64 = @as(i32, @bitCast(isrc(c, f, s1, i) << 8)) >> 8;
                    break :blk @as(u32, @truncate(@as(u64, @bitCast(a * b)))) +% isrc(c, f, s2, i);
                },
                .madsh_m16 => ((usrc(c, f, s0, i) & 0xffff) *% (usrc(c, f, s1, i) >> 16) << 16) +% usrc(c, f, s2, i),
                .sel_b32, .sel_s32, .sel_b16, .sel_s16 => if (usrc(c, f, s1, i) != 0) usrc(c, f, s0, i) else usrc(c, f, s2, i),
                .shrm => std.math.shr(u32, usrc(c, f, s1, i), usrc(c, f, s0, i) & 31) & usrc(c, f, s2, i),
                .shlm => std.math.shl(u32, usrc(c, f, s1, i), usrc(c, f, s0, i) & 31) & usrc(c, f, s2, i),
                .shrg => std.math.shr(u32, usrc(c, f, s1, i), usrc(c, f, s0, i) & 31) | usrc(c, f, s2, i),
                .shlg => std.math.shl(u32, usrc(c, f, s1, i), usrc(c, f, s0, i) & 31) | usrc(c, f, s2, i),
                .andg => (usrc(c, f, s1, i) & usrc(c, f, s0, i)) | usrc(c, f, s2, i),
                .dp4acc => blk: {
                    const a = usrc(c, f, s0, i);
                    const b = usrc(c, f, s1, i);
                    var acc: i32 = @bitCast(isrc(c, f, s2, i));
                    for (0..4) |k| {
                        const ab: u8 = @truncate(a >> @intCast(8 * k));
                        const bb: u8 = @truncate(b >> @intCast(8 * k));
                        const av: i32 = if (in.mixed) @as(i8, @bitCast(ab)) else ab;
                        acc +%= av * @as(i32, bb);
                    }
                    break :blk @bitCast(acc);
                },
                else => return error.Unsupported,
            };
            writeReg(c, f, dst, dhalf, if (dhalf) res & 0xffff else res);
        }
        noteWrite(c, dst, dhalf, .alu, slot0 + i);
    }
}

fn execCat4(c: *Ctx, in: *const Instr, fibers: []const u32, slot0: u64) Error!void {
    const reps: u32 = @as(u32, in.repeat) + 1;
    for (0..reps) |ri| {
        const i: u32 = @intCast(ri);
        try checkSources(c, in, i, slot0 + i);
        const dst = in.dst.num + @as(u16, @intCast(i));
        for (fibers) |f| {
            const x = fsrc(c, f, in.src[0], i);
            const v: f32 = switch (in.op) {
                .rcp => 1.0 / x,
                .rsq, .hrsq => 1.0 / @sqrt(x),
                .sqrt => @sqrt(x),
                .log2, .hlog2 => @log2(x),
                .exp2, .hexp2 => @exp2(x),
                .sin => @sin(x),
                .cos => @cos(x),
                else => return error.Unsupported,
            };
            putF(c, f, dst, in.dst.half, v, in.sat);
        }
        noteWrite(c, dst, in.dst.half, .ss, slot0 + i);
    }
}

fn typeBytes(t: ir3.Type) u32 {
    return switch (t) {
        .f32, .u32, .s32 => 4,
        .f16, .u16, .s16 => 2,
        .u8, .u8_32 => 1,
    };
}

fn loadValue(bytes: []const u8, t: ir3.Type) u32 {
    return switch (typeBytes(t)) {
        4 => std.mem.readInt(u32, bytes[0..4], .little),
        2 => std.mem.readInt(u16, bytes[0..2], .little),
        else => bytes[0],
    };
}

fn storeValue(bytes: []u8, t: ir3.Type, v: u32) void {
    switch (typeBytes(t)) {
        4 => std.mem.writeInt(u32, bytes[0..4], v, .little),
        2 => std.mem.writeInt(u16, bytes[0..2], @truncate(v), .little),
        else => bytes[0] = @truncate(v),
    }
}

fn addr64(c: *const Ctx, f: u32, s: Src) u64 {
    if (s.kind == .cnst) return @as(u64, constAt(c, s.num + 1)) << 32 | constAt(c, s.num);
    return @as(u64, readFull(c, f, s.num + 1)) << 32 | readFull(c, f, s.num);
}

fn globalAddr(c: *const Ctx, f: u32, in: *const Instr) u64 {
    const base = addr64(c, f, in.src[0]);
    return switch (in.op) {
        .ldg, .stg => base +% @as(u64, @bitCast(@as(i64, in.off))),
        .ldg_a, .stg_a => base +% readFull(c, f, in.src[1].num) +% @as(u64, @intCast(in.off)),
        else => base,
    };
}

fn execCat6(c: *Ctx, in: *const Instr, fibers: []const u32, slot0: u64) Error!void {
    const w = c.w;
    const tb = typeBytes(in.ty);
    // memory instructions read their sources like non-ALU consumers
    switch (in.op) {
        .ldg, .ldg_a, .stg, .stg_a => {
            if (in.src[0].kind == .gpr) {
                try checkRead(c, in.src[0].num, false, false, slot0);
                try checkRead(c, in.src[0].num + 1, false, false, slot0);
            }
            if (in.op == .ldg_a or in.op == .stg_a) try checkRead(c, in.src[1].num, false, false, slot0);
            if (in.op == .stg or in.op == .stg_a) {
                for (0..in.size) |k| try checkRead(c, in.src[2].num + @as(u16, @intCast(k)), in.src[2].half, false, slot0);
            }
        },
        .ldl, .stl => {
            try checkRead(c, in.src[0].num, false, false, slot0);
            if (in.op == .stl) for (0..in.size) |k| try checkRead(c, in.src[1].num + @as(u16, @intCast(k)), in.src[1].half, false, slot0);
        },
        .shfl => try checkRead(c, in.src[0].num, in.src[0].half, false, slot0),
        else => {},
    }
    switch (in.op) {
        .ldg, .ldg_a => {
            for (fibers) |f| {
                const va = globalAddr(c, f, in);
                const bytes = c.mem.find(va, tb * in.size) orelse return faultAt(c, va);
                for (0..in.size) |k| writeReg(c, f, in.dst.num + @as(u16, @intCast(k)), in.dst.half, loadValue(bytes[k * tb ..], in.ty));
            }
            c.stats.global_bytes_read += fibers.len * tb * in.size;
            for (0..in.size) |k| noteWrite(c, in.dst.num + @as(u16, @intCast(k)), in.dst.half, .sy, slot0);
        },
        .stg, .stg_a => {
            for (fibers) |f| {
                const va = globalAddr(c, f, in);
                const bytes = c.mem.find(va, tb * in.size) orelse return faultAt(c, va);
                for (0..in.size) |k| storeValue(bytes[k * tb ..], in.ty, readReg(c, f, in.src[2].num + @as(u16, @intCast(k)), in.src[2].half));
            }
            c.stats.global_bytes_written += fibers.len * tb * in.size;
        },
        .ldl => {
            for (fibers) |f| {
                const a: i64 = @as(i64, readFull(c, f, in.src[0].num)) + in.off;
                if (a < 0 or a + tb * in.size > LOCAL_BYTES) return error.Fault;
                const at: usize = @intCast(a);
                for (0..in.size) |k| writeReg(c, f, in.dst.num + @as(u16, @intCast(k)), in.dst.half, loadValue(w.local[at + k * tb ..], in.ty));
            }
            for (0..in.size) |k| noteWrite(c, in.dst.num + @as(u16, @intCast(k)), in.dst.half, .ss, slot0);
        },
        .stl => {
            for (fibers) |f| {
                const a: i64 = @as(i64, readFull(c, f, in.src[0].num)) + in.off;
                if (a < 0 or a + tb * in.size > LOCAL_BYTES) return error.Fault;
                const at: usize = @intCast(a);
                for (0..in.size) |k| storeValue(w.local[at + k * tb ..], in.ty, readReg(c, f, in.src[1].num + @as(u16, @intCast(k)), in.src[1].half));
            }
        },
        .shfl => {
            // All fibers read their source first, then write.
            var vals: [128]u32 = undefined;
            var have: [128]bool = .{false} ** 128;
            const base = c.wave * c.threadsize;
            for (fibers) |f| {
                vals[f - base] = readReg(c, f, in.src[0].num, in.src[0].half);
                have[f - base] = true;
            }
            for (fibers) |f| {
                const lane = f - base;
                const p = if (in.src[1].kind == .imm) in.src[1].imm else readFull(c, f, in.src[1].num);
                const from: i64 = switch (in.shfl) {
                    .xor => lane ^ p,
                    .up => @as(i64, lane) - p,
                    .down => @as(i64, lane) + p,
                    .rup => @mod(@as(i64, lane) - p, c.threadsize),
                    .rdown => @mod(@as(i64, lane) + p, c.threadsize),
                };
                const v = if (from >= 0 and from < c.threadsize and have[@intCast(from)]) vals[@intCast(from)] else readReg(c, f, in.src[0].num, in.src[0].half);
                writeReg(c, f, in.dst.num, in.dst.half, v);
            }
            noteWrite(c, in.dst.num, in.dst.half, .ss, slot0);
        },
        .getfiberid => {
            for (fibers) |f| writeReg(c, f, in.dst.num, false, f - c.wave * c.threadsize);
            noteWrite(c, in.dst.num, false, .sy, slot0);
        },
        else => return error.Unsupported,
    }
}

fn faultAt(c: *Ctx, va: u64) Error {
    _ = c;
    _ = va;
    return error.Fault;
}

// ── Dispatch ────────────────────────────────────────────────────────────────

pub fn load(w: *Work, k: *const ir3_asm.Kernel) Error!void {
    if (k.count > w.code.len) return error.BadDispatch;
    for (k.code[0..k.count], 0..) |word, i| w.code[i] = try ir3.decode(k.gen, word);
    w.n_code = k.count;
}

/// Run a dispatch (load() the kernel first).
pub fn run(w: *Work, mem: *const Memory, d: *const Dispatch, stats: *Stats) Error!void {
    const k = d.kernel;
    const lsz = @as(u32, k.local_size[0]) * k.local_size[1] * k.local_size[2];
    if (lsz == 0 or lsz > MAX_FIBERS) return error.BadDispatch;
    const ts: u32 = k.threadsize;
    const waves = (lsz + ts - 1) / ts;
    var gz: u32 = 0;
    while (gz < d.groups[2]) : (gz += 1) {
        var gy: u32 = 0;
        while (gy < d.groups[1]) : (gy += 1) {
            var gx: u32 = d.first_group;
            while (gx < d.groups[0]) : (gx += d.group_stride) {
                try runGroup(w, mem, d, stats, .{ gx, gy, gz }, lsz, waves);
            }
        }
    }
}

fn runGroup(w: *Work, mem: *const Memory, d: *const Dispatch, stats: *Stats, gid: [3]u32, lsz: u32, waves: u32) Error!void {
    const k = d.kernel;
    const ts: u32 = k.threadsize;
    stats.workgroups += 1;
    stats.waves += waves;
    const nf = waves * ts;
    for (0..nf) |fi| {
        const f: u32 = @intCast(fi);
        w.st[f] = if (f < lsz) .run else .off;
        w.pc[f] = 0;
        // (registers hold garbage on the hardware; a fixed pattern here)
        @memset(&w.regs[f], 0xdeadbeef);
        w.pred[f] = .{ false, false, false, false };
        w.a0[f] = 0;
        w.a1[f] = 0;
        if (k.localid_reg != ir3_asm.INVALID_REG and f < lsz) {
            const lx = k.local_size[0];
            const ly = k.local_size[1];
            w.regs[f][k.localid_reg] = f % lx;
            w.regs[f][k.localid_reg + 1] = (f / lx) % ly;
            w.regs[f][k.localid_reg + 2] = f / (@as(u32, lx) * ly);
        }
    }
    for (0..waves) |wi| {
        @memset(&w.shared[wi], 0);
        if (k.wgid_reg != ir3_asm.INVALID_REG) {
            const base = k.wgid_reg - @as(u8, @intCast(ir3.SHARED_BASE));
            w.shared[wi][base] = gid[0];
            w.shared[wi][base + 1] = gid[1];
            w.shared[wi][base + 2] = gid[2];
        }
        w.slot[wi] = 0;
        w.pend_ss[wi] = .{0} ** 8;
        w.pend_sy[wi] = .{0} ** 8;
        @memset(&w.ready_alu[wi], 0);
        @memset(&w.ready_non[wi], 0);
    }
    @memset(w.local[0..@min(LOCAL_BYTES, @max(k.shared_bytes, 1))], 0xcd);
    var steps: u64 = 0;
    const delays = ir3_asm.Delays.forGen(k.gen);
    while (true) {
        var live = false;
        for (0..waves) |wi| {
            var c = Ctx{ .w = w, .mem = mem, .d = d, .wave = @intCast(wi), .threadsize = ts, .stats = stats, .delays = delays };
            try runWave(&c, &steps);
        }
        // Everyone is at a barrier or done.
        var at_bar = false;
        for (0..nf) |fi| {
            switch (w.st[fi]) {
                .bar => at_bar = true,
                .run => live = true,
                else => {},
            }
        }
        if (live) return error.Divergence;
        if (!at_bar) break;
        for (0..nf) |fi| if (w.st[fi] == .bar) {
            w.st[fi] = .run;
            w.pc[fi] += 1;
        };
        // (a barrier waits for everything outstanding)
        for (0..waves) |wi| {
            w.pend_ss[wi] = .{0} ** 8;
            w.pend_sy[wi] = .{0} ** 8;
        }
    }
}

fn runWave(c: *Ctx, steps: *u64) Error!void {
    const w = c.w;
    const base = c.wave * c.threadsize;
    var fibers: [128]u32 = undefined;
    while (true) {
        // The lowest pc among running fibers goes next.
        var min_pc: u32 = std.math.maxInt(u32);
        for (base..base + c.threadsize) |fi| {
            if (w.st[fi] == .run and w.pc[fi] < min_pc) min_pc = w.pc[fi];
        }
        if (min_pc == std.math.maxInt(u32)) return;
        if (min_pc >= w.n_code) {
            w.err_pc = min_pc;
            return error.BadInstruction;
        }
        var n: usize = 0;
        for (base..base + c.threadsize) |fi| {
            if (w.st[fi] == .run and w.pc[fi] == min_pc) {
                fibers[n] = @intCast(fi);
                n += 1;
            }
        }
        const in = &w.code[min_pc];
        if (in.op == .bar) {
            for (fibers[0..n]) |f| w.st[f] = .bar;
            continue;
        }
        w.err_pc = min_pc;
        try execute(c, min_pc, fibers[0..n]);
        steps.* += 1;
        if (steps.* > MAX_STEPS) return error.Timeout;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

var asm_work: ir3_asm.Work = .{};
var emu_work: Work = .{};

fn runSource(src: []const u8, mem: *const Memory, consts: []const u32, groups: [3]u32) !Stats {
    var code: [512]u64 = undefined;
    const k = ir3_asm.assemble(ir3.A7XX, src, &asm_work, &code) catch |e| {
        std.debug.print("assemble: line {d}: {s}\n", .{ asm_work.err_line, @errorName(e) });
        return e;
    };
    try load(&emu_work, &k);
    var stats = Stats{};
    const d = Dispatch{ .kernel = &k, .consts = consts, .groups = groups };
    run(&emu_work, mem, &d, &stats) catch |e| {
        var buf: [160]u8 = undefined;
        const s = ir3.format(ir3.A7XX, &emu_work.code[emu_work.err_pc], &buf) catch "?";
        std.debug.print("emulate: {s} at {d}: {s}\n", .{ @errorName(e), emu_work.err_pc, s });
        return e;
    };
    return stats;
}

test "a vector add across workgroups" {
    var a: [256]f32 = undefined;
    var b: [256]f32 = undefined;
    var out = [_]f32{0} ** 256;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = 0.5 * @as(f32, @floatFromInt(i));
    }
    const regions = [_]Region{
        .{ .va = 0x1_0000_0000, .bytes = std.mem.sliceAsBytes(&a) },
        .{ .va = 0x1_0001_0000, .bytes = std.mem.sliceAsBytes(&b) },
        .{ .va = 0x1_0002_0000, .bytes = std.mem.sliceAsBytes(&out) },
    };
    const mem = Memory{ .regions = &regions };
    const consts = [_]u32{ 0x0000_0000, 1, 0x0001_0000, 1, 0x0002_0000, 1, 0, 0 };
    _ = try runSource(
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\; i = wg * 64 + lid; byte offset = i * 4
        \\shl.b r1.x, r48.x, 6
        \\add.u r1.x, r1.x, r0.x
        \\shl.b r1.y, r1.x, 2
        \\ldg.a.f32 r2.x, g[c0.x+r1.y+0], 1
        \\ldg.a.f32 r2.y, g[c0.z+r1.y+0], 1
        \\add.f r2.z, r2.x, r2.y
        \\stg.a.f32 g[c1.x+r1.y+0], r2.z, 1
        \\end
    , &mem, &consts, .{ 4, 1, 1 });
    for (out, 0..) |v, i| try std.testing.expectEqual(1.5 * @as(f32, @floatFromInt(i)), v);
}

test "dp4acc: unsigned and mixed (signed x unsigned) byte dot products" {
    var data = [_]u32{ 0x80ff_7f01, 0x0302_ff10, 0, 0 };
    const regions = [_]Region{.{ .va = 0x2000, .bytes = std.mem.sliceAsBytes(&data) }};
    const mem = Memory{ .regions = &regions };
    const consts = [_]u32{ 0x2000, 0, 0, 0 };
    _ = try runSource(
        \\@localsize 1, 1, 1
        \\@consts 1
        \\mov.u32u32 r1.x, 0
        \\ldg.a.u32 r0.x, g[c0.x+r1.x+0], 2
        \\mov.u32u32 r2.x, 10
        \\dp4acc.unsigned.low r3.x, r0.x, r0.y, r2.x
        \\dp4acc.mixed.low r3.y, r0.x, r0.y, r2.x
        \\mov.u32u32 r1.y, 8
        \\stg.a.u32 g[c0.x+r1.y+0], r3.x, 2
        \\end
    , &mem, &consts, .{ 1, 1, 1 });
    // bytes a = 01 7f ff 80, b = 10 ff 02 03
    const ua = [_]i32{ 1, 127, 255, 128 };
    const sa = [_]i32{ 1, 127, -1, -128 };
    const ub = [_]i32{ 16, 255, 2, 3 };
    var du: i32 = 10;
    var dm: i32 = 10;
    for (0..4) |i| {
        du += ua[i] * ub[i];
        dm += sa[i] * ub[i];
    }
    try std.testing.expectEqual(@as(u32, @bitCast(du)), data[2]);
    try std.testing.expectEqual(@as(u32, @bitCast(dm)), data[3]);
}

test "a wave reduction through shuffles, and a loop" {
    var out = [_]u32{0} ** 4;
    const regions = [_]Region{.{ .va = 0x9000, .bytes = std.mem.sliceAsBytes(&out) }};
    const mem = Memory{ .regions = &regions };
    const consts = [_]u32{ 0x9000, 0, 0, 0 };
    _ = try runSource(
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@consts 1
        \\mov.u32u32 r1.x, r0.x
        \\mov.u32u32 r1.y, 32
        \\loop:
        \\shfl.xor.u32 r1.z, r1.x, r1.y
        \\add.u r1.x, r1.x, r1.z
        \\shr.b r1.y, r1.y, 1
        \\cmps.u.ne p0.x, r1.y, 0
        \\br p0.x, #loop
        \\cmps.u.eq p0.y, r0.x, 0
        \\mov.u32u32 r2.x, 0
        \\br !p0.y, #skip
        \\stg.a.u32 g[c0.x+r2.x+0], r1.x, 1
        \\skip:
        \\end
    , &mem, &consts, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(u32, 63 * 64 / 2), out[0]);
}

test "the hazard checker catches a read before (sy)" {
    var w = &emu_work;
    w.check_hazards = true;
    var data = [_]u32{ 7, 0 };
    const regions = [_]Region{.{ .va = 0x100, .bytes = std.mem.sliceAsBytes(&data) }};
    const mem = Memory{ .regions = &regions };
    // Hand-built words without legalization.
    var code: [32]u64 = undefined;
    const lines = [_][]const u8{
        "mov.u32u32 r1.x, 0",
        "(rpt5)nop",
        "ldg.a.u32 r0.x, g[c0.x+r1.x+0], 1",
        "add.u r0.y, r0.x, 1",
        "end",
    };
    for (lines, 0..) |l, i| code[i] = try ir3.assembleLine(ir3.A7XX, l);
    var k = ir3_asm.Kernel{ .gen = ir3.A7XX, .code = code[0..lines.len], .count = lines.len, .instrlen = 1, .local_size = .{ 1, 1, 1 } };
    k.constlen = 4;
    try load(w, &k);
    const consts = [_]u32{ 0x100, 0, 0, 0 };
    var stats = Stats{};
    try std.testing.expectError(error.Hazard, run(w, &mem, &.{ .kernel = &k, .consts = &consts, .groups = .{ 1, 1, 1 } }, &stats));
}

test "(abs) of the most negative integer wraps to itself" {
    var out = [_]u32{ 1, 1 };
    const regions = [_]Region{.{ .va = 0x9000, .bytes = std.mem.sliceAsBytes(&out) }};
    const mem = Memory{ .regions = &regions };
    const consts = [_]u32{ 0x9000, 0, 0x80000000, 0 };
    _ = try runSource(
        \\@localsize 1, 1, 1
        \\@consts 1
        \\mov.u32u32 r0.x, c0.z
        \\absneg.s r0.y, (abs)r0.x
        \\absneg.s r0.z, (neg)r0.x
        \\mov.u32u32 r1.x, 0
        \\stg.a.u32 g[c0.x+r1.x+0], r0.y, 2
        \\end
    , &mem, &consts, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(u32, 0x80000000), out[0]);
    try std.testing.expectEqual(@as(u32, 0x80000000), out[1]);
}
