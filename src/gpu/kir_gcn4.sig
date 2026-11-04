//! @zpm/gpu kir_gcn4 — KIR to AMD GCN 4 (gfx803: Polaris, the MacBook Pro
//! 15" 2018's Radeon Pro 555X/560X), as gcn3 instruction words.
//!
//! How KIR maps onto a wave64:
//! - **Values** live in VGPRs, one lane per KIR thread. Uniform values that
//!   never change (parameters, group ids and counts, the subgroup width)
//!   stay where the hardware or the prologue put them: SGPRs and inline
//!   constants, used directly as operands.
//! - **Predicates** are 64-bit lane masks in SGPR pairs (as v_cmp writes
//!   them). A predicate written more than once is merged under EXEC, so
//!   lanes that do not run the write keep their value, as KIR says.
//! - **Control flow** is EXEC masking with a save mask per if and break and
//!   continue masks per loop, the interpreter's frames in SGPRs:
//!   s_and_saveexec for if, the save mask's other lanes for else, a back
//!   edge while any lane is left (s_cbranch_execnz), and s_cbranch_execz
//!   over code no lane runs.
//! - **Memory:** the parameter block is the kernarg segment, loaded into
//!   SGPRs by the prologue: a raw buffer resource (V#) per binding (the
//!   buffer's address and its size as num_records, so the hardware's range
//!   check bounds every access), the parameter words, then the group counts.
//!   Global accesses are MUBUF with the KIR offset as a VGPR offset (offen),
//!   the immediate in the instruction or soffset. Shared memory is
//!   LDS (m0 = -1, as gfx8 needs); shuffles are ds_bpermute_b32, or
//!   ds_swizzle_b32 for xor within 32 lanes.
//! - **Floating point:** IEEE mode off (min/max take the non-NaN operand, as
//!   KIR's do), f32 denormals flushed or kept as Caps say. fmad is v_mad_f32
//!   when flushing (gfx8's mad never keeps denormals) and mul+add when
//!   keeping them; ffma is v_fma_f32. fmin/fmax use the hardware's min/max
//!   twice with swapped operands and combine the two, so signed zeros come
//!   out as KIR's (-0 < +0) whatever the hardware does with equal operands.
//!   fsin/fcos scale by 1/2π (v_sin_f32 takes revolutions).
//! - **Waits:** after selection a pass inserts s_waitcnt where a register a
//!   load (SMEM, MUBUF, DS, the LDS-free DS permutes) has not delivered is
//!   read or overwritten, keeping the counters' in-order and out-of-order
//!   rules, and the manual wait states gfx8 needs. gcn3_emu checks both.
//!
//! The Binary is the code words; `Info` (in Binary.extra) has what a
//! dispatch needs: the register counts, the system SGPRs and workitem ids,
//! the kernarg layout and the float mode. `Info.config()` gives the
//! amdgpu.dispatch.Config for the descriptor and the COMPUTE_* registers.
//!
//! Allocation-free: the Work is the caller's (about 6 MB: keep it static or
//! take it from a device.Work).

const std = @import("std");
const kir = @import("kir.sig");
const device = @import("device.sig");
const amdgpu = @import("amdgpu");
const gcn3 = amdgpu.gcn3;
const dispatch = amdgpu.dispatch;

const Inst = kir.Inst;
const Op = kir.Op;
const Ty = kir.Ty;
const V = kir.V;
const Arg = kir.Arg;
const G = gcn3.Instr;
const op = gcn3.op;

pub const MAX_KIR = 16384;
pub const MAX_VREGS = 16384;
pub const MAX_MI = 32768;
pub const MAX_WORDS = 65536;
pub const MAX_LABELS = 4096;
pub const MAX_LOOPS = 512;
/// Nesting of if/loop frames (each frame's masks are SGPR pairs).
pub const MAX_DEPTH = 16;
pub const MAX_PENDING = 15;

pub const Error = kir.Error || error{ Unsupported, TooComplex, OutOfMemory, NoSpaceLeft };

// ── What a dispatch needs (Binary.extra) ────────────────────────────────────

pub const Info = struct {
    vgprs: u16 = 0,
    sgprs: u16 = 0,
    /// group ids x, y, z as system SGPRs
    group_id: [3]bool = .{ false, false, false },
    /// workitem ids delivered: 0 = x, 1 = x y, 2 = x y z
    workitem: u2 = 0,
    flush: bool = true,
    /// the kernarg segment, in dwords: a V# per binding (4 each), the
    /// parameter words, then the group counts (3) when the kernel reads them
    kernarg_dwords: u16 = 0,
    gsize_at: u16 = 0xffff,
    instructions: u32 = 0,
    shared_bytes: u32 = 0,
    /// predicates that lived in VGPRs (more were live than the SGPRs hold)
    spilled_preds: u32 = 0,

    pub fn toExtra(i: Info) [16]u32 {
        var e = [_]u32{0} ** 16;
        e[0] = i.instructions;
        e[1] = i.vgprs;
        e[2] = i.sgprs;
        e[3] = @as(u32, @intFromBool(i.group_id[0])) | @as(u32, @intFromBool(i.group_id[1])) << 1 | @as(u32, @intFromBool(i.group_id[2])) << 2 | @as(u32, i.workitem) << 3 | @as(u32, @intFromBool(i.flush)) << 5;
        e[4] = i.kernarg_dwords;
        e[5] = i.gsize_at;
        e[6] = i.shared_bytes;
        e[7] = i.spilled_preds;
        e[15] = MAGIC;
        return e;
    }

    pub fn fromExtra(e: [16]u32) ?Info {
        if (e[15] != MAGIC) return null;
        return .{
            .instructions = e[0],
            .vgprs = @intCast(e[1]),
            .sgprs = @intCast(e[2]),
            .group_id = .{ e[3] & 1 != 0, e[3] & 2 != 0, e[3] & 4 != 0 },
            .workitem = @intCast(e[3] >> 3 & 3),
            .flush = e[3] & 32 != 0,
            .kernarg_dwords = @intCast(e[4]),
            .gsize_at = @intCast(e[5]),
            .shared_bytes = e[6],
            .spilled_preds = e[7],
        };
    }

    /// The kernel's dispatch configuration (descriptor, RSRC1/RSRC2).
    pub fn config(i: Info) dispatch.Config {
        return .{
            .user_sgprs = 1 << @intFromEnum(dispatch.UserSgpr.kernarg_segment_ptr),
            .workgroup_id = i.group_id,
            .workitem_id = i.workitem,
            .next_free_vgpr = i.vgprs,
            .next_free_sgpr = i.sgprs,
            .reserve_vcc = true,
            .reserve_flat_scratch = false,
            .group_segment_bytes = i.shared_bytes,
            .kernarg_bytes = 4 * @as(u32, i.kernarg_dwords),
            .float_denorm_mode_32 = if (i.flush) 0 else 3,
            .float_denorm_mode_16_64 = 3,
            .ieee_mode = false,
            .dx10_clamp = true,
        };
    }

    /// The kernarg segment of one dispatch into `out`: each binding's V#
    /// (its GPU address, its size as the records), the parameter words,
    /// the group counts.
    pub fn kernarg(i: Info, buffers: []const device.Buffer, params: []const u32, groups: [3]u32, out: []u32) error{NoSpaceLeft}![]u32 {
        if (out.len < i.kernarg_dwords) return error.NoSpaceLeft;
        @memset(out[0..i.kernarg_dwords], 0);
        var at: usize = 0;
        for (buffers) |b| {
            if (at + 4 > i.kernarg_dwords) return error.NoSpaceLeft;
            const v = dispatch.BufferResource{ .base = b.gpu, .num_records = @intCast(@min(b.bytes, 0xffff_ffff)) };
            @memcpy(out[at..][0..4], &v.words());
            at += 4;
        }
        for (params) |p| {
            if (at >= i.kernarg_dwords) break;
            out[at] = p;
            at += 1;
        }
        if (i.gsize_at != 0xffff) {
            for (0..3) |ax| out[i.gsize_at + ax] = groups[ax];
        }
        return out[0..i.kernarg_dwords];
    }
};

const MAGIC: u32 = 0x6763_6e34; // "gcn4"

// ── Working storage ─────────────────────────────────────────────────────────

const LocKind = enum(u8) { none, vgpr, sgpr, konst, mask, pvgpr };
/// Where a KIR register lives: a VGPR (index), an SGPR (operand code), an
/// inline or literal constant (its bits), a lane mask (an SGPR pair's
/// first code), or a lane mask spilled to a VGPR (0 or 1 per lane: when
/// more predicates are live than the SGPRs hold).
const Loc = struct { kind: LocKind = .none, x: u32 = 0 };

const FrameKind = enum(u8) { if_then, if_else, loop };
const Frame = struct {
    kind: FrameKind,
    /// if: the save mask; loop: the break mask (and cont = brk + 2)
    pair: u16,
    l_else: u16 = 0,
    l_end: u16 = 0,
    l_top: u16 = 0,
    l_latch: u16 = 0,
    has_else: bool = false,
    has_cont: bool = false,
    /// if: lanes leave the innermost loop from inside (bit 0 cont, bit 1
    /// brk), in the then-part and in either part; the else and the endif
    /// take them out of the save mask then (the brk and cont themselves
    /// leave the save mask alone)
    then_drops: u2 = 0,
    drops: u2 = 0,
    /// the innermost loop's break pair (cont = + 2), when it drops lanes
    loop_pair: u16 = 0,
};

/// A machine instruction, and the label it branches to (0xffff: none).
const MI = struct { in: G, target: u16 = 0xffff };

const Pend = struct { code: u16, n: u8, younger: u8, smem: bool = false };
const WState = struct {
    vm: [MAX_PENDING]Pend = undefined,
    nvm: u8 = 0,
    lg: [MAX_PENDING]Pend = undefined,
    nlg: u8 = 0,
    smem: bool = false,
    valid: bool = false,
};

pub const Stats = struct {
    instructions: u32 = 0,
    words: u32 = 0,
    vgprs: u32 = 0,
    sgprs: u32 = 0,
    waits: u32 = 0,
    nops: u32 = 0,
};

pub const Work = struct {
    caps: device.Caps = device.interp_caps,
    k: kir.Kernel = undefined,
    insts: [MAX_KIR]Inst = undefined,
    tys: [MAX_VREGS]Ty = undefined,
    // analysis
    loc: [MAX_VREGS]Loc = undefined,
    first: [MAX_VREGS]u32 = undefined,
    last: [MAX_VREGS]u32 = undefined,
    ndef: [MAX_VREGS]u16 = undefined,
    def_op: [MAX_VREGS]Op = undefined,
    def_at: [MAX_VREGS]u32 = undefined,
    /// the first register of the vector a register belongs to, and its length
    vbase: [MAX_VREGS]u16 = undefined,
    vlen: [MAX_VREGS]u8 = undefined,
    depth: [MAX_KIR]u8 = undefined,
    match: [MAX_KIR]u32 = undefined,
    /// extendLoops: the region (if arm, else arm, inner loop) of a
    /// register's def in this iteration, and which regions are open
    dom: [MAX_VREGS]u16 = undefined,
    region_open: [MAX_KIR]bool = undefined,
    loops_s: [MAX_LOOPS]u32 = undefined,
    loops_e: [MAX_LOOPS]u32 = undefined,
    nloops: usize = 0,
    start_head: [MAX_KIR + 1]u16 = undefined,
    start_next: [MAX_VREGS]u16 = undefined,
    max_depth: u8 = 0,
    // the machine
    mi: [MAX_MI]MI = undefined,
    nmi: usize = 0,
    mo: [MAX_MI]MI = undefined,
    nmo: usize = 0,
    labels: [MAX_LABELS]u32 = undefined,
    nlabels: usize = 0,
    lstate: [MAX_LABELS]WState = undefined,
    words: [MAX_WORDS]u32 = undefined,
    pcs: [MAX_MI + 1]u32 = undefined,
    lhead: [MAX_MI + 1]u16 = undefined,
    lnext: [MAX_LABELS]u16 = undefined,
    new_pos: [MAX_LABELS]u32 = undefined,
    nwords: usize = 0,
    // layout
    workitem: u2 = 0,
    group_id: [3]bool = .{ false, false, false },
    wg_code: [3]u16 = .{ 0, 0, 0 },
    ka: u16 = 0,
    nka: u16 = 0,
    gsize_at: u16 = 0xffff,
    vsharp: u16 = 0,
    frames_at: u16 = 0,
    stmp_at: u16 = 0,
    pred_at: u16 = 0,
    sgpr_end: u16 = 0,
    vtmp_at: u16 = 0,
    vbase0: u16 = 0,
    vgpr_end: u16 = 0,
    /// Predicates that did not fit the SGPRs and live in VGPRs.
    spilled_preds: u32 = 0,
    /// Machine instructions each KIR op lowered to (waits not counted).
    mi_by_op: [256]u32 = undefined,
    uses_lds: bool = false,
    // lowering
    frames: [MAX_DEPTH]Frame = undefined,
    cur: u32 = 0,
    nframes: usize = 0,
    ntv: u16 = 0,
    nts: u16 = 0,
    stats: Stats = .{},
    diag_buf: [256]u8 = undefined,
    diag_len: usize = 0,

    fn fail(w: *Work, e: Error, comptime fmt: []const u8, args: anytype) Error {
        const s = std.fmt.bufPrint(&w.diag_buf, fmt, args) catch w.diag_buf[0..0];
        w.diag_len = s.len;
        @memcpy(last_diag_buf[0..s.len], s);
        last_diag_len = s.len;
        return e;
    }
};

pub const WORK_BYTES = @sizeOf(Work) + @alignOf(Work);

var last_diag_buf: [256]u8 = undefined;
var last_diag_len: usize = 0;

/// The last failed compile's diagnostic, whichever Work it ran in (for
/// callers that compile through device.compile and never see the Work).
pub fn lastDiagnostic() []const u8 {
    return last_diag_buf[0..last_diag_len];
}

/// Why the last compile failed, when the backend knows more than the error.
pub fn diagnostic(w: *const Work) []const u8 {
    return w.diag_buf[0..w.diag_len];
}

// ── Compile ─────────────────────────────────────────────────────────────────

pub fn compile(k: *const kir.Kernel, caps: device.Caps, work: *device.Work, out: []u8) Error!device.Binary {
    const m = work.mark();
    defer work.release(m);
    const w = work.take(Work, 1) orelse return error.OutOfMemory;
    return compileWith(k, caps, &w[0], out);
}

/// compile, with a Work of the caller's (static).
pub fn compileWith(k: *const kir.Kernel, caps: device.Caps, w: *Work, out: []u8) Error!device.Binary {
    w.diag_len = 0;
    w.stats = .{};
    if (k.err) |e| return e;
    if (caps.subgroup != 64) return w.fail(error.Unsupported, "gcn4 waves are 64 lanes (caps.subgroup {d})", .{caps.subgroup});
    const threads = @as(u64, k.group[0]) * k.group[1] * k.group[2];
    if (threads == 0 or threads > 1024) return error.Unsupported;
    if (k.shared_bytes > 65536) return error.Limits;
    w.caps = caps;
    if (k.n > MAX_KIR or k.nv > MAX_VREGS) return error.TooManyInsts;
    w.k = try kir.expand(k, caps, .{ .insts = &w.insts, .tys = &w.tys });
    try analyze(w);
    try layout(w);
    try allocate(w);
    w.nmi = 0;
    w.nlabels = 0;
    try lower(w);
    try waits(w);
    try encode(w);
    return binary(w, out);
}

// ── Analysis ────────────────────────────────────────────────────────────────

fn argReg(a: Arg) ?V {
    return switch (a) {
        .reg => |v| if (v == .none) null else v,
        .imm => null,
    };
}

/// The registers instruction `in` reads (up to 3 operands, vectors whole)
/// and writes, through `f`.
fn eachReg(in: Inst, ctx: anytype, comptime f: fn (@TypeOf(ctx), V, bool) void) void {
    const m: kir.Mem = @bitCast(in.aux);
    const args = [3]Arg{ in.a, in.b, in.c };
    for (args, 0..) |a, ix| {
        if (argReg(a)) |v| {
            var n: u16 = 1;
            if (in.op == .st and ix == 1) n = kir.memRegs(m);
            for (0..n) |j| f(ctx, @enumFromInt(@as(u16, @intCast(@intFromEnum(v) + j))), false);
        }
    }
    if (in.dst != .none) {
        const n: u16 = if (in.op == .ld) kir.memRegs(m) else 1;
        for (0..n) |j| f(ctx, @enumFromInt(@as(u16, @intCast(@intFromEnum(in.dst) + j))), true);
    }
}

const Scan = struct {
    w: *Work,
    i: u32,
    fn ref(s: Scan, v: V, write: bool) void {
        const x = @intFromEnum(v);
        if (s.w.first[x] == 0xffff_ffff) s.w.first[x] = s.i;
        s.w.last[x] = s.i;
        if (write) {
            if (s.w.ndef[x] < 0xffff) s.w.ndef[x] += 1;
            s.w.def_op[x] = s.w.k.insts[s.i].op;
            s.w.def_at[x] = s.i;
        }
    }
};

fn analyze(w: *Work) Error!void {
    const k = &w.k;
    const n = k.n;
    const nv = k.nv;
    @memset(w.first[0..nv], 0xffff_ffff);
    @memset(w.last[0..nv], 0);
    @memset(w.ndef[0..nv], 0);
    for (0..nv) |x| {
        w.vbase[x] = @intCast(x);
        w.vlen[x] = 1;
    }
    w.nloops = 0;
    w.max_depth = 0;
    w.uses_lds = false;
    w.workitem = 0;
    w.group_id = .{ false, false, false };
    var uses_gsize = false;
    var stack: [64]u32 = undefined;
    var sd: usize = 0;
    for (k.insts[0..n], 0..) |in, ix| {
        const i: u32 = @intCast(ix);
        eachReg(in, Scan{ .w = w, .i = i }, Scan.ref);
        w.depth[i] = @intCast(sd);
        switch (in.op) {
            .@"if", .loop => {
                if (sd == stack.len) return error.TooComplex;
                stack[sd] = i;
                sd += 1;
                if (sd > w.max_depth) w.max_depth = @intCast(sd);
                if (in.op == .loop) {
                    if (w.nloops == MAX_LOOPS) return w.fail(error.TooComplex, "more than {d} loops", .{MAX_LOOPS});
                    w.loops_s[w.nloops] = i;
                    w.nloops += 1;
                }
                w.match[i] = 0xffff_ffff;
            },
            .@"else" => {
                const o = stack[sd - 1];
                w.match[o] = i;
                w.depth[i] = @intCast(sd - 1);
            },
            .endif, .endloop => {
                sd -= 1;
                const o = stack[sd];
                if (w.match[o] == 0xffff_ffff) w.match[o] = i else w.match[w.match[o]] = i;
                w.match[i] = o;
                w.depth[i] = @intCast(sd);
                if (in.op == .endloop) {
                    for (0..w.nloops) |l| {
                        if (w.loops_s[l] == o) w.loops_e[l] = i;
                    }
                }
            },
            .tid => w.workitem = @max(w.workitem, @as(u2, @intCast(@min(in.aux, 2)))),
            .gid => w.group_id[@min(in.aux, 2)] = true,
            .gsize => uses_gsize = true,
            .shfl => w.uses_lds = true,
            .ld, .st, .atom => {
                const m: kir.Mem = @bitCast(in.aux);
                if (m.space == .shared) w.uses_lds = true;
            },
            else => {},
        }
        // vectors: a 64/128-bit access's registers are one allocation
        if (in.op == .ld or in.op == .st) {
            const m: kir.Mem = @bitCast(in.aux);
            const nr = kir.memRegs(m);
            if (nr > 1) {
                const base: ?V = if (in.op == .ld) in.dst else argReg(in.b);
                if (base) |b| try vecGroup(w, b, nr);
            }
        }
    }
    if (w.max_depth > MAX_DEPTH) return w.fail(error.TooComplex, "flow nested {d} deep (at most {d})", .{ w.max_depth, MAX_DEPTH });
    w.gsize_at = if (uses_gsize) @intCast(4 * @as(u32, k.bindings) + k.param_words) else 0xffff;
    // where the registers live: uniform values that never change stay put
    for (0..nv) |x| {
        w.loc[x] = .{};
        if (w.first[x] == 0xffff_ffff) continue;
        if (w.tys[x] == .pred) {
            w.loc[x].kind = .mask;
            continue;
        }
        w.loc[x].kind = .vgpr;
        if (w.ndef[x] == 1 and w.vlen[w.vbase[x]] == 1) {
            switch (w.def_op[x]) {
                .param, .gid, .gsize, .subgroup, .tid => w.loc[x].kind = .none, // (placed by lower)
                else => {},
            }
        }
    }
    try extendLoops(w);
}

fn vecGroup(w: *Work, b: V, nr: u8) Error!void {
    const base = @intFromEnum(b);
    for (0..nr) |j| {
        const x = base + j;
        if (w.vbase[x] != x or w.vlen[x] != 1) {
            if (w.vbase[x] == base and w.vlen[base] == nr) continue;
            return w.fail(error.Unsupported, "register %{d} in two vectors", .{x});
        }
    }
    for (0..nr) |j| w.vbase[base + j] = @intCast(base);
    w.vlen[base] = nr;
}

/// A register used in a loop and outside it, or read in the loop before a
/// write that dominates the read, lives through the whole loop.
fn extendLoops(w: *Work) Error!void {
    // innermost first: by size
    var order: [MAX_LOOPS]u16 = undefined;
    for (0..w.nloops) |l| order[l] = @intCast(l);
    std.mem.sort(u16, order[0..w.nloops], w, struct {
        fn lt(ww: *Work, a: u16, b: u16) bool {
            return ww.loops_e[a] - ww.loops_s[a] < ww.loops_e[b] - ww.loops_s[b];
        }
    }.lt);
    const nv = w.k.nv;
    for (order[0..w.nloops]) |l| {
        const s = w.loops_s[l];
        const e = w.loops_e[l];
        // A read is this iteration's value when a def before it, in a
        // region still open (the read's own region or one around it), wrote
        // it: every lane reaching the read ran that def. Otherwise the value
        // comes around the back edge (or from before the loop), and the
        // register lives through the whole loop.
        @memset(w.dom[0..nv], 0);
        var stack: [MAX_DEPTH + 2]u16 = undefined;
        var sp: usize = 1;
        var next_region: u16 = 1;
        stack[0] = next_region;
        w.region_open[next_region] = true;
        const Ctx = struct {
            w: *Work,
            s: u32,
            e: u32,
            region: u16,
            fn ref(c: @This(), v: V, write: bool) void {
                const x = @intFromEnum(v);
                const ww = c.w;
                const covered = ww.dom[x] != 0 and ww.region_open[ww.dom[x]];
                var extend = ww.first[x] < c.s or ww.last[x] > c.e;
                if (!write and !covered) extend = true;
                if (write and !covered) ww.dom[x] = c.region;
                if (extend) {
                    ww.first[x] = @min(ww.first[x], c.s);
                    ww.last[x] = @max(ww.last[x], c.e);
                }
            }
        };
        var i = s + 1;
        while (i < e) : (i += 1) {
            const in = w.k.insts[i];
            switch (in.op) {
                .@"else", .endif, .endloop => {
                    if (sp <= 1) return w.fail(error.Unbalanced, "unbalanced flow at instruction {d}", .{i});
                    sp -= 1;
                    w.region_open[stack[sp]] = false;
                },
                else => {},
            }
            // reads first, then the write (an instruction reading its own
            // destination reads the old value)
            const c = Ctx{ .w = w, .s = s, .e = e, .region = stack[sp - 1] };
            const RO = struct {
                fn reads(cc: Ctx, v: V, write: bool) void {
                    if (!write) cc.ref(v, false);
                }
                fn writes(cc: Ctx, v: V, write: bool) void {
                    if (write) cc.ref(v, true);
                }
            };
            eachReg(in, c, RO.reads);
            eachReg(in, c, RO.writes);
            switch (in.op) {
                .@"if", .@"else", .loop => {
                    if (sp == stack.len or next_region + 1 >= MAX_KIR) return w.fail(error.TooComplex, "flow nested too deep at instruction {d}", .{i});
                    next_region += 1;
                    stack[sp] = next_region;
                    sp += 1;
                    w.region_open[next_region] = true;
                },
                else => {},
            }
        }
        w.region_open[stack[0]] = false;
    }
    // a vector lives as long as any of its registers
    for (0..nv) |x| {
        const b = w.vbase[x];
        if (b == x or w.first[x] == 0xffff_ffff) continue;
        w.first[b] = @min(w.first[b], w.first[x]);
        w.last[b] = @max(w.last[b], w.last[x]);
    }
    for (0..nv) |x| {
        const b = w.vbase[x];
        if (b == x) continue;
        w.first[x] = w.first[b];
        w.last[x] = w.last[b];
    }
}

// ── Register layout ─────────────────────────────────────────────────────────
//
// SGPRs: s[0:1] the kernarg pointer; the group ids the kernel reads; the
// kernarg segment (aligned to 4: the V#s first); the frames' masks (two
// pairs per nesting level); scratch (4 pairs); the predicate pool.
// VGPRs: v0..v2 the workitem ids; 8 scratch; the allocated registers.

const SCRATCH_V = 8;
const SCRATCH_PAIRS = 4;

fn alignUp(x: u16, a: u16) u16 {
    return (x + a - 1) / a * a;
}

fn layout(w: *Work) Error!void {
    const k = &w.k;
    var s: u16 = 2;
    for (0..3) |a| {
        if (w.group_id[a]) {
            w.wg_code[a] = s;
            s += 1;
        }
    }
    w.ka = alignUp(s, 4);
    w.nka = @intCast(4 * @as(u32, k.bindings) + k.param_words + (if (w.gsize_at != 0xffff) @as(u32, 3) else 0));
    if (w.nka > 64) return w.fail(error.TooComplex, "a parameter block of {d} dwords (at most 64 in SGPRs)", .{w.nka});
    w.vsharp = w.ka;
    w.frames_at = alignUp(w.ka + w.nka, 2);
    w.stmp_at = w.frames_at + 4 * @as(u16, w.max_depth);
    w.pred_at = w.stmp_at + 2 * SCRATCH_PAIRS + 2;
    if (w.pred_at > gcn3.SGPRS) return w.fail(error.TooComplex, "the SGPR layout needs {d} SGPRs", .{w.pred_at});
    w.vtmp_at = @as(u16, w.workitem) + 1;
    w.vbase0 = w.vtmp_at + SCRATCH_V;
}

fn allocate(w: *Work) Error!void {
    const k = &w.k;
    const n = k.n;
    const nv = k.nv;
    // vregs by first use
    @memset(w.start_head[0 .. n + 1], 0xffff);
    var x: usize = nv;
    while (x > 0) {
        x -= 1;
        const l = w.loc[x].kind;
        if ((l != .vgpr and l != .mask) or w.vbase[x] != x) continue;
        const f = w.first[x];
        w.start_next[x] = w.start_head[f];
        w.start_head[f] = @intCast(x);
    }
    var vbusy = [_]u32{0} ** 256; // the last instruction using the register
    var vfree = [_]bool{true} ** 256;
    var pfree = [_]bool{true} ** 64;
    var pbusy = [_]u32{0} ** 64;
    const npairs: usize = (gcn3.SGPRS - w.pred_at) / 2;
    w.spilled_preds = 0;
    var vmax: u16 = w.vbase0;
    var smax: u16 = w.pred_at;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // registers whose last use is before i are free (a register last
        // used at i is free for i's destination: the lowering writes it last)
        for (0..256) |r| {
            if (!vfree[r] and vbusy[r] < i) vfree[r] = true;
        }
        for (0..npairs) |p| {
            if (!pfree[p] and pbusy[p] < i) pfree[p] = true;
        }
        var v = w.start_head[i];
        while (v != 0xffff) : (v = w.start_next[v]) {
            const last = w.last[v];
            if (w.loc[v].kind == .mask) {
                const p = for (0..npairs) |pp| {
                    if (pfree[pp]) break pp;
                } else null;
                if (p) |pp| {
                    pfree[pp] = false;
                    pbusy[pp] = last;
                    const code: u16 = w.pred_at + 2 * @as(u16, @intCast(pp));
                    w.loc[v].x = code;
                    smax = @max(smax, code + 2);
                    continue;
                }
                // the pool is full: this one lives in a VGPR as 0/1
                w.loc[v].kind = .pvgpr;
                w.spilled_preds += 1;
            }
            const kind = w.loc[v].kind;
            const len = w.vlen[v];
            var r: u16 = w.vbase0;
            const found = while (r + len <= 256) : (r += 1) {
                var ok = true;
                for (0..len) |j| {
                    if (!vfree[r + j]) {
                        ok = false;
                        break;
                    }
                }
                if (ok) break true;
            } else false;
            if (!found) return w.fail(error.TooManyRegs, "more than 256 VGPRs at instruction {d}", .{i});
            for (0..len) |j| {
                vfree[r + j] = false;
                vbusy[r + j] = last;
                w.loc[v + j] = .{ .kind = kind, .x = r + @as(u16, @intCast(j)) };
            }
            vmax = @max(vmax, r + len);
        }
    }
    w.vgpr_end = vmax;
    w.sgpr_end = smax;
}

// ── Lowering helpers ────────────────────────────────────────────────────────

const VCC = gcn3.VCC_LO;
const EXEC = gcn3.EXEC_LO;
const ZERO = gcn3.ZERO;
const MINUS_ONE: u16 = 193;
const LIT = gcn3.LITERAL;

fn vg(p: anytype) u16 {
    return gcn3.VGPR0 + @as(u16, @intCast(p));
}

/// A 32-bit source operand: an operand code (and the literal for 255).
const Src = struct {
    code: u16,
    lit: u32 = 0,

    fn isV(s: Src) bool {
        return s.code >= gcn3.VGPR0;
    }
    /// counts on the constant bus (an SGPR or the literal)
    fn bus(s: Src) bool {
        return s.code < 128 or s.code == LIT;
    }
};

/// One operand an immediate (its bits) and the other, for a commutative op.
fn constOperand(in: Inst) ?struct { bits: u32, other: Arg } {
    if (in.b == .imm and in.a != .imm) return .{ .bits = in.b.imm, .other = in.a };
    if (in.a == .imm and in.b != .imm) return .{ .bits = in.a.imm, .other = in.b };
    return null;
}

fn immSrc(x: u32) Src {
    const si: i32 = @bitCast(x);
    if (si >= -16 and si <= 64) return .{ .code = gcn3.inlineInt(si) };
    for (gcn3.float32, 0..) |c, ix| {
        if (c == x) return .{ .code = @intCast(240 + ix) };
    }
    return .{ .code = LIT, .lit = x };
}

fn emit(w: *Work, in: G) Error!void {
    if (w.nmi == MAX_MI) return w.fail(error.TooManyInsts, "more than {d} machine instructions", .{MAX_MI});
    w.mi[w.nmi] = .{ .in = in };
    w.nmi += 1;
}

fn emitBranch(w: *Work, o: gcn3.Op, label: u16) Error!void {
    try emit(w, .{ .op = o });
    w.mi[w.nmi - 1].target = label;
}

fn newLabel(w: *Work) Error!u16 {
    if (w.nlabels == MAX_LABELS) return w.fail(error.TooComplex, "more than {d} labels", .{MAX_LABELS});
    w.labels[w.nlabels] = 0xffff_ffff;
    w.nlabels += 1;
    return @intCast(w.nlabels - 1);
}

fn place(w: *Work, l: u16) void {
    w.labels[l] = @intCast(w.nmi);
}

fn tmpV(w: *Work) Error!u16 {
    if (w.ntv == SCRATCH_V) return w.fail(error.TooComplex, "scratch VGPRs exhausted", .{});
    w.ntv += 1;
    return vg(w.vtmp_at + w.ntv - 1);
}

fn tmpPair(w: *Work) Error!u16 {
    if (w.nts == SCRATCH_PAIRS) return w.fail(error.TooComplex, "scratch SGPR pairs exhausted", .{});
    w.nts += 1;
    return w.stmp_at + 2 * (w.nts - 1);
}

/// The single scratch SGPR (soffsets, literals for VOP3).
fn tmpS(w: *Work) u16 {
    return w.stmp_at + 2 * SCRATCH_PAIRS;
}

fn locOf(w: *const Work, v: V) Loc {
    return w.loc[@intFromEnum(v)];
}

/// A KIR operand as a 32-bit source.
fn src(w: *Work, a: Arg) Error!Src {
    switch (a) {
        .imm => |x| return immSrc(x),
        .reg => |v| {
            if (v == .none) return .{ .code = ZERO };
            const l = locOf(w, v);
            return switch (l.kind) {
                .vgpr => .{ .code = vg(l.x) },
                .sgpr => .{ .code = @intCast(l.x) },
                .konst => immSrc(l.x),
                else => w.fail(error.BadOperand, "%{d} has no place at instruction {d}", .{ @intFromEnum(v), w.cur }),
            };
        },
    }
}

/// A predicate operand as a 64-bit scalar source (an SGPR pair, 0 or -1).
fn psrc(w: *Work, a: Arg) Error!u16 {
    switch (a) {
        .imm => |x| return if (x != 0) MINUS_ONE else ZERO,
        .reg => |v| {
            const l = locOf(w, v);
            if (l.kind == .pvgpr) {
                // back to a mask: lanes holding 1 (inactive lanes read 0,
                // and every use is under EXEC)
                const t = try tmpPair(w);
                try emit(w, .{ .op = op("v_cmp_ne_u32"), .e64 = true, .sdst = t, .src = .{ 128, vg(@as(u16, @intCast(l.x))), 0 } });
                return t;
            }
            if (l.kind != .mask) return w.fail(error.BadOperand, "%{d} is not a predicate", .{@intFromEnum(v)});
            return @intCast(l.x);
        },
    }
}

/// A scratch pair (one `psrc` may have just made) that may be overwritten.
fn isScratchPair(w: *const Work, p: u16) bool {
    return p >= w.stmp_at and p < w.stmp_at + 2 * SCRATCH_PAIRS;
}

fn dstV(w: *Work, v: V) Error!u16 {
    const l = locOf(w, v);
    if (l.kind != .vgpr) return w.fail(error.BadOperand, "%{d} is not in a VGPR at instruction {d}", .{ @intFromEnum(v), w.cur });
    return vg(l.x);
}

/// v_mov_b32 into a scratch VGPR.
fn toV(w: *Work, s: Src) Error!Src {
    if (s.isV()) return s;
    const t = try tmpV(w);
    try emit(w, .{ .op = op("v_mov_b32"), .dst = t, .src = .{ s.code, 0, 0 }, .lit = s.lit });
    return .{ .code = t };
}

const VOpts = struct {
    comm: bool = false,
    rev: ?gcn3.Op = null,
    sdst: u16 = VCC,
    neg: u3 = 0,
};

/// A VALU instruction with its operands legalized: the 32-bit form where
/// it fits (src1 a VGPR, literal and SGPR only in src0), else VOP3 (no
/// literal), and at most one SGPR or literal (the constant bus).
fn valu(w: *Work, o_in: gcn3.Op, dst: u16, srcs_in: []const Src, opts: VOpts) Error!void {
    var o = o_in;
    var s: [3]Src = .{ .{ .code = 0 }, .{ .code = 0 }, .{ .code = 0 } };
    for (srcs_in, 0..) |x, ix| s[ix] = x;
    const n = srcs_in.len;
    var df = gcn3.def(o);
    const implicit_vcc = df.shape == .vop_carry_in or df.shape == .vop_cndmask;
    // the 32-bit form
    if ((df.enc == .vop2 or df.enc == .vop1) and opts.neg == 0) {
        if (df.enc == .vop2 and !s[1].isV()) {
            if (s[0].isV() and opts.comm) {
                const t = s[0];
                s[0] = s[1];
                s[1] = t;
            } else if (s[0].isV() and opts.rev != null) {
                const t = s[0];
                s[0] = s[1];
                s[1] = t;
                o = opts.rev.?;
                df = gcn3.def(o);
            }
        }
        const fits = (df.enc == .vop1 or s[1].isV()) and (!implicit_vcc or !s[0].bus()) and (df.shape != .vop_carry or opts.sdst == VCC);
        if (fits) {
            var in = G{ .op = o, .dst = dst, .src = .{ s[0].code, s[1].code, VCC }, .lit = s[0].lit, .sdst = VCC };
            if (df.enc == .vop1) in.src[1] = 0;
            if (!implicit_vcc) in.src[2] = 0;
            if (df.shape != .vop_carry and df.shape != .vop_carry_in) in.sdst = 0;
            return emit(w, in);
        }
        if (!df.e64) return w.fail(error.Unsupported, "{s}: no form for its operands", .{df.name});
    }
    // VOP3: no literal; one SGPR at most
    var sgpr: ?u16 = null;
    for (s[0..n], 0..) |x, ix| {
        if (x.code == LIT) {
            if (sgpr == null) {
                const t = tmpS(w);
                try emit(w, .{ .op = op("s_mov_b32"), .dst = t, .src = .{ LIT, 0, 0 }, .lit = x.lit });
                s[ix] = .{ .code = t };
                sgpr = t;
            } else s[ix] = try toV(w, x);
        } else if (x.code < 128) {
            if (sgpr == null or sgpr.? == x.code) {
                sgpr = x.code;
            } else s[ix] = try toV(w, x);
        }
    }
    var in = G{ .op = o, .e64 = df.enc != .vop3, .dst = dst, .neg = opts.neg };
    for (s[0..n], 0..) |x, ix| in.src[ix] = x.code;
    switch (df.shape) {
        .vop_carry, .vop_carry_in, .vop3b => in.sdst = opts.sdst,
        .vopc => in.sdst = opts.sdst,
        else => {},
    }
    return emit(w, in);
}

fn sop2(w: *Work, o: gcn3.Op, dst: u16, a: u16, b: u16) Error!void {
    return emit(w, .{ .op = o, .dst = dst, .src = .{ a, b, 0 } });
}
fn sop1(w: *Work, o: gcn3.Op, dst: u16, a: u16) Error!void {
    return emit(w, .{ .op = o, .dst = dst, .src = .{ a, 0, 0 } });
}

/// Where a predicate's new value goes: its pair, or (for a predicate with
/// more than one write) a scratch pair merged in under EXEC by `predDone`.
fn predDst(w: *Work, v: V) Error!u16 {
    const l = locOf(w, v);
    if (l.kind == .pvgpr) return tmpPair(w);
    if (l.kind != .mask) return w.fail(error.BadOperand, "%{d} is not a predicate", .{@intFromEnum(v)});
    if (w.ndef[@intFromEnum(v)] > 1) return tmpPair(w);
    return @intCast(l.x);
}

fn predDone(w: *Work, v: V, t: u16) Error!void {
    const l = locOf(w, v);
    if (l.kind == .pvgpr) {
        // 0/1 into the active lanes (the others keep theirs: the merge)
        return emit(w, .{ .op = op("v_cndmask_b32"), .e64 = true, .dst = vg(@as(u16, @intCast(l.x))), .src = .{ 128, 129, t } });
    }
    const p: u16 = @intCast(l.x);
    if (t == p) return;
    try sop2(w, op("s_and_b64"), t, t, EXEC);
    try sop2(w, op("s_andn2_b64"), p, p, EXEC);
    try sop2(w, op("s_or_b64"), p, p, t);
}

// ── Lowering ────────────────────────────────────────────────────────────────

fn lower(w: *Work) Error!void {
    const k = &w.k;
    w.nframes = 0;
    @memset(&w.mi_by_op, 0);
    w.cur = 0;
    // the kernarg segment
    var off: u16 = 0;
    while (off < w.nka) {
        const left = w.nka - off;
        const n: u16 = if (left >= 16) 16 else if (left >= 8) 8 else if (left >= 4) 4 else if (left >= 2) 2 else 1;
        const o = switch (n) {
            16 => op("s_load_dwordx16"),
            8 => op("s_load_dwordx8"),
            4 => op("s_load_dwordx4"),
            2 => op("s_load_dwordx2"),
            else => op("s_load_dword"),
        };
        try emit(w, .{ .op = o, .dst = w.ka + off, .src = .{ 0, 0, 0 }, .imm = 4 * @as(u32, off), .soff_imm = true });
        off += n;
    }
    if (w.uses_lds) try sop1(w, op("s_mov_b32"), gcn3.M0, MINUS_ONE);
    // uniform registers that stay where they are
    for (0..k.nv) |x| {
        if (w.loc[x].kind != .none or w.first[x] == 0xffff_ffff) continue;
        // the defining instruction (its only one)
        const in = k.insts[w.def_at[x]];
        w.loc[x] = switch (in.op) {
            .param => .{ .kind = .sgpr, .x = w.ka + 4 * @as(u32, k.bindings) + in.aux },
            .gid => .{ .kind = .sgpr, .x = w.wg_code[@min(in.aux, 2)] },
            .gsize => .{ .kind = .sgpr, .x = w.ka + w.gsize_at + @min(in.aux, 2) },
            .subgroup => .{ .kind = .konst, .x = 64 },
            .tid => .{ .kind = .vgpr, .x = @min(in.aux, 2) },
            else => unreachable,
        };
    }
    for (k.insts[0..k.n], 0..) |in, i| {
        w.cur = @intCast(i);
        w.ntv = 0;
        w.nts = 0;
        const before = w.nmi;
        try lowerInst(w, in);
        w.mi_by_op[@intFromEnum(in.op)] += @intCast(w.nmi - before);
    }
    if (w.nframes != 0) return error.Unbalanced;
    try emit(w, .{ .op = op("s_endpgm") });
}

fn cmpOp(c: kir.Cmp, ty: Ty) gcn3.Op {
    const u = [6]gcn3.Op{ op("v_cmp_eq_u32"), op("v_cmp_ne_u32"), op("v_cmp_lt_u32"), op("v_cmp_le_u32"), op("v_cmp_gt_u32"), op("v_cmp_ge_u32") };
    const s = [6]gcn3.Op{ op("v_cmp_eq_i32"), op("v_cmp_ne_i32"), op("v_cmp_lt_i32"), op("v_cmp_le_i32"), op("v_cmp_gt_i32"), op("v_cmp_ge_i32") };
    const fl = [6]gcn3.Op{ op("v_cmp_eq_f32"), op("v_cmp_neq_f32"), op("v_cmp_lt_f32"), op("v_cmp_le_f32"), op("v_cmp_gt_f32"), op("v_cmp_ge_f32") };
    const ix = @intFromEnum(c);
    return switch (ty) {
        .i32 => s[ix],
        .f32 => fl[ix],
        else => u[ix],
    };
}

fn isPow2Imm(a: Arg) ?u32 {
    return switch (a) {
        .imm => |x| if (x != 0 and x & (x - 1) == 0) @ctz(x) else null,
        .reg => null,
    };
}

fn lowerInst(w: *Work, in: Inst) Error!void {
    switch (in.op) {
        .mov => {
            if (in.ty == .pred) {
                const d = try predDst(w, in.dst);
                try sop1(w, op("s_mov_b64"), d, try psrc(w, in.a));
                return predDone(w, in.dst, d);
            }
            try valu(w, op("v_mov_b32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{});
        },
        .sel => {
            if (in.ty == .pred) {
                const d = try predDst(w, in.dst);
                const c = try psrc(w, in.c);
                const a = try psrc(w, in.a);
                const t1 = if (isScratchPair(w, a)) a else try tmpPair(w);
                try sop2(w, op("s_and_b64"), t1, c, a);
                const b = try psrc(w, in.b);
                const t2 = if (isScratchPair(w, b)) b else try tmpPair(w);
                try sop2(w, op("s_andn2_b64"), t2, b, c);
                try sop2(w, op("s_or_b64"), d, t1, t2);
                return predDone(w, in.dst, d);
            }
            const d = try dstV(w, in.dst);
            if (in.c == .imm) {
                return valu(w, op("v_mov_b32"), d, &.{try src(w, if (in.c.imm != 0) in.a else in.b)}, .{});
            }
            const mask = try psrc(w, in.c);
            var a = try src(w, in.a);
            var b = try src(w, in.b);
            if (a.bus()) a = try toV(w, a);
            if (b.bus()) b = try toV(w, b);
            try emit(w, .{ .op = op("v_cndmask_b32"), .e64 = true, .dst = d, .src = .{ b.code, a.code, mask } });
        },
        .iadd => try valu(w, op("v_add_u32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true }),
        .isub => try valu(w, op("v_sub_u32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .rev = op("v_subrev_u32") }),
        .imul => {
            const d = try dstV(w, in.dst);
            if (isPow2Imm(in.b)) |sh| return valu(w, op("v_lshlrev_b32"), d, &.{ immSrc(sh), try src(w, in.a) }, .{});
            if (isPow2Imm(in.a)) |sh| return valu(w, op("v_lshlrev_b32"), d, &.{ immSrc(sh), try src(w, in.b) }, .{});
            try valu(w, op("v_mul_lo_u32"), d, &.{ try src(w, in.a), try src(w, in.b) }, .{});
        },
        .imulhi => try valu(w, if (in.ty == .i32) op("v_mul_hi_i32") else op("v_mul_hi_u32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{}),
        .imad => {
            const d = try dstV(w, in.dst);
            const t = try tmpV(w);
            if (isPow2Imm(in.b)) |sh| {
                try valu(w, op("v_lshlrev_b32"), t, &.{ immSrc(sh), try src(w, in.a) }, .{});
            } else if (isPow2Imm(in.a)) |sh| {
                try valu(w, op("v_lshlrev_b32"), t, &.{ immSrc(sh), try src(w, in.b) }, .{});
            } else try valu(w, op("v_mul_lo_u32"), t, &.{ try src(w, in.a), try src(w, in.b) }, .{});
            try valu(w, op("v_add_u32"), d, &.{ try src(w, in.c), .{ .code = t } }, .{ .comm = true });
        },
        .ineg => try valu(w, op("v_sub_u32"), try dstV(w, in.dst), &.{ .{ .code = ZERO }, try src(w, in.a) }, .{ .rev = op("v_subrev_u32") }),
        .iabs => {
            const d = try dstV(w, in.dst);
            const a = try toV(w, try src(w, in.a));
            const t = try tmpV(w);
            try valu(w, op("v_sub_u32"), t, &.{ .{ .code = ZERO }, a }, .{});
            try valu(w, op("v_max_i32"), d, &.{ a, .{ .code = t } }, .{ .comm = true });
        },
        .imin, .imax => {
            const s = in.ty == .i32;
            const o = if (in.op == .imin) (if (s) op("v_min_i32") else op("v_min_u32")) else (if (s) op("v_max_i32") else op("v_max_u32"));
            try valu(w, o, try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true });
        },
        .@"and", .@"or", .xor => {
            const o = switch (in.op) {
                .@"and" => op("v_and_b32"),
                .@"or" => op("v_or_b32"),
                else => op("v_xor_b32"),
            };
            try valu(w, o, try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true });
        },
        .not => try valu(w, op("v_not_b32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .shl, .shr => {
            const o = if (in.op == .shl) op("v_lshlrev_b32") else if (in.ty == .i32) op("v_ashrrev_i32") else op("v_lshrrev_b32");
            try valu(w, o, try dstV(w, in.dst), &.{ try src(w, in.b), try src(w, in.a) }, .{});
        },
        .bfe => try lowerBfe(w, in),
        .dot4 => try lowerDot4(w, in),
        .icmp, .fcmp => {
            const d = try predDst(w, in.dst);
            const c: kir.Cmp = @enumFromInt(in.aux);
            try valu(w, cmpOp(c, in.ty), 0, &.{ try src(w, in.a), try src(w, in.b) }, .{ .sdst = d });
            try predDone(w, in.dst, d);
        },
        .pand, .por => {
            const d = try predDst(w, in.dst);
            try sop2(w, if (in.op == .pand) op("s_and_b64") else op("s_or_b64"), d, try psrc(w, in.a), try psrc(w, in.b));
            try predDone(w, in.dst, d);
        },
        .pnot => {
            const d = try predDst(w, in.dst);
            try sop1(w, op("s_not_b64"), d, try psrc(w, in.a));
            try predDone(w, in.dst, d);
        },
        .fadd => try valu(w, op("v_add_f32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true }),
        .fsub => try valu(w, op("v_sub_f32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .rev = op("v_subrev_f32") }),
        .fmul => try valu(w, op("v_mul_f32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true }),
        .ffma => try valu(w, op("v_fma_f32"), try dstV(w, in.dst), &.{ try src(w, in.a), try src(w, in.b), try src(w, in.c) }, .{}),
        .fmad => {
            const d = try dstV(w, in.dst);
            if (w.caps.mad == .fused) {
                try valu(w, op("v_fma_f32"), d, &.{ try src(w, in.a), try src(w, in.b), try src(w, in.c) }, .{});
            } else if (w.caps.denormals == .flush) {
                try valu(w, op("v_mad_f32"), d, &.{ try src(w, in.a), try src(w, in.b), try src(w, in.c) }, .{});
            } else {
                const t = try tmpV(w);
                try valu(w, op("v_mul_f32"), t, &.{ try src(w, in.a), try src(w, in.b) }, .{ .comm = true });
                try valu(w, op("v_add_f32"), d, &.{ try src(w, in.c), .{ .code = t } }, .{ .comm = true });
            }
        },
        .fmin, .fmax => {
            // the hardware's choice between equal operands is the second
            // one: min(a, b) and min(b, a) differ only for -0 and +0, and
            // their or (and) is KIR's -0 (+0)
            const d = try dstV(w, in.dst);
            const o = if (in.op == .fmin) op("v_min_f32") else op("v_max_f32");
            // against a constant there is no tie to break, but at +-0
            if (constOperand(in)) |kc| {
                const c = kc.bits;
                const x = try src(w, kc.other);
                const normal = c & 0x7f80_0000 != 0 and c & 0x7f80_0000 != 0x7f80_0000;
                if (normal or (c & 0x7fff_ffff == 0x7f80_0000)) {
                    // (a normal number or an infinity: equal means the same bits)
                    return valu(w, o, d, &.{ immSrc(c), x }, .{ .comm = true });
                }
                if (in.op == .fmax and c == 0) {
                    // max(a, +0): +0 for a <= 0 and NaN, so -0 becomes +0
                    try valu(w, o, d, &.{ immSrc(0), x }, .{ .comm = true });
                    return valu(w, op("v_max_i32"), d, &.{ immSrc(0), .{ .code = d } }, .{ .comm = true });
                }
                if (in.op == .fmin and c == 0x8000_0000) {
                    // min(a, -0): -0 for a >= -0 and NaN, so +0 becomes -0
                    try valu(w, o, d, &.{ immSrc(0x8000_0000), x }, .{ .comm = true });
                    return valu(w, op("v_or_b32"), d, &.{ immSrc(0x8000_0000), .{ .code = d } }, .{ .comm = true });
                }
            }
            const a = try src(w, in.a);
            const b = try src(w, in.b);
            const t0 = try tmpV(w);
            const t1 = try tmpV(w);
            try valu(w, o, t0, &.{ a, b }, .{});
            try valu(w, o, t1, &.{ b, a }, .{});
            if (in.op == .fmin) {
                try valu(w, op("v_or_b32"), d, &.{ .{ .code = t0 }, .{ .code = t1 } }, .{});
            } else {
                try valu(w, op("v_or_b32"), t1, &.{ immSrc(0x7fff_ffff), .{ .code = t1 } }, .{});
                try valu(w, op("v_and_b32"), d, &.{ .{ .code = t0 }, .{ .code = t1 } }, .{});
            }
        },
        .fabs => try valu(w, op("v_and_b32"), try dstV(w, in.dst), &.{ immSrc(0x7fff_ffff), try src(w, in.a) }, .{}),
        .fneg => try valu(w, op("v_xor_b32"), try dstV(w, in.dst), &.{ immSrc(0x8000_0000), try src(w, in.a) }, .{}),
        .ffloor => try valu(w, op("v_floor_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .fceil => try valu(w, op("v_ceil_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .ftrunc => try valu(w, op("v_trunc_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .frne => try valu(w, op("v_rndne_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .frcp => try valu(w, op("v_rcp_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .frsq => try valu(w, op("v_rsq_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .fexp2 => try valu(w, op("v_exp_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .flog2 => try valu(w, op("v_log_f32"), try dstV(w, in.dst), &.{try src(w, in.a)}, .{}),
        .fsin, .fcos => {
            // v_sin_f32 and v_cos_f32 take revolutions: x * 1/(2π) (inline)
            const t = try tmpV(w);
            try valu(w, op("v_mul_f32"), t, &.{ .{ .code = 248 }, try src(w, in.a) }, .{});
            try valu(w, if (in.op == .fsin) op("v_sin_f32") else op("v_cos_f32"), try dstV(w, in.dst), &.{.{ .code = t }}, .{});
        },
        .fdiv, .fsqrt => return w.fail(error.Unsupported, "fdiv/fsqrt not expanded", .{}),
        .cvt => try lowerCvt(w, in),
        .tid, .gid, .gsize, .subgroup, .param => {
            // (a register with more than this one write is a VGPR)
            const l = locOf(w, in.dst);
            if (l.kind != .vgpr or (in.op == .tid and l.x == @min(in.aux, 2) and w.ndef[@intFromEnum(in.dst)] == 1)) return;
            const s: Src = switch (in.op) {
                .tid => .{ .code = vg(@min(in.aux, 2)) },
                .gid => .{ .code = w.wg_code[@min(in.aux, 2)] },
                .gsize => .{ .code = w.ka + w.gsize_at + @min(in.aux, 2) },
                .subgroup => immSrc(64),
                else => .{ .code = w.ka + 4 * @as(u16, w.k.bindings) + @as(u16, @intCast(in.aux)) },
            };
            try valu(w, op("v_mov_b32"), vg(l.x), &.{s}, .{});
        },
        .lane => {
            const t = try tmpV(w);
            try valu(w, op("v_mbcnt_lo_u32_b32"), t, &.{ .{ .code = MINUS_ONE }, .{ .code = ZERO } }, .{});
            try valu(w, op("v_mbcnt_hi_u32_b32"), try dstV(w, in.dst), &.{ .{ .code = MINUS_ONE }, .{ .code = t } }, .{});
        },
        .ld, .st, .atom => {
            const m: kir.Mem = @bitCast(in.aux);
            if (m.space == .shared) try lowerLds(w, in, m) else try lowerBuf(w, in, m);
        },
        .barrier => {
            try emit(w, .{ .op = op("s_waitcnt"), .imm = 0x0070 }); // vmcnt(0) lgkmcnt(0)
            try emit(w, .{ .op = op("s_barrier") });
        },
        .shfl => try lowerShfl(w, in),
        .vote => {
            const d = try predDst(w, in.dst);
            const p = try psrc(w, in.a);
            var t = p;
            if (!predClean(w, in.a, w.cur)) {
                t = try tmpPair(w);
                try sop2(w, op("s_and_b64"), t, p, EXEC);
            }
            if (in.aux == @intFromEnum(kir.Vote.any)) {
                try emit(w, .{ .op = op("s_cmp_lg_u64"), .src = .{ t, ZERO, 0 } });
            } else {
                try emit(w, .{ .op = op("s_cmp_eq_u64"), .src = .{ t, EXEC, 0 } });
            }
            try sop2(w, op("s_cselect_b64"), d, MINUS_ONE, ZERO);
            try predDone(w, in.dst, d);
        },
        .@"if", .@"else", .endif, .loop, .brk, .cont, .endloop, .ret => try lowerFlow(w, in),
    }
}

fn lowerBfe(w: *Work, in: Inst) Error!void {
    const d = try dstV(w, in.dst);
    const signed = in.ty == .i32;
    const shift = if (signed) op("v_ashrrev_i32") else op("v_lshrrev_b32");
    const bfe_op = if (signed) op("v_bfe_i32") else op("v_bfe_u32");
    if (in.b == .imm and in.c == .imm) {
        const off = in.b.imm & 31;
        const wd = @min(in.c.imm, 32 - off);
        if (wd == 0) return valu(w, op("v_mov_b32"), d, &.{.{ .code = ZERO }}, .{});
        if (wd == 32 - off) {
            if (off == 0) return valu(w, op("v_mov_b32"), d, &.{try src(w, in.a)}, .{});
            return valu(w, shift, d, &.{ immSrc(off), try src(w, in.a) }, .{});
        }
        return valu(w, bfe_op, d, &.{ try src(w, in.a), immSrc(off), immSrc(wd) }, .{});
    }
    // off = b & 31; room = 32 - off; width = min(c, room); x = a >> off;
    // width == room ? x : bfe(x, 0, width)
    const t_off = try tmpV(w);
    const t_room = try tmpV(w);
    const t_w = try tmpV(w);
    const t_x = try tmpV(w);
    const t_f = try tmpV(w);
    try valu(w, op("v_and_b32"), t_off, &.{ immSrc(31), try src(w, in.b) }, .{});
    try valu(w, op("v_sub_u32"), t_room, &.{ immSrc(32), .{ .code = t_off } }, .{});
    try valu(w, op("v_min_u32"), t_w, &.{ try src(w, in.c), .{ .code = t_room } }, .{ .comm = true });
    try valu(w, shift, t_x, &.{ .{ .code = t_off }, try src(w, in.a) }, .{});
    try valu(w, bfe_op, t_f, &.{ .{ .code = t_x }, .{ .code = ZERO }, .{ .code = t_w } }, .{});
    const p = try tmpPair(w);
    try valu(w, op("v_cmp_eq_u32"), 0, &.{ .{ .code = t_w }, .{ .code = t_room } }, .{ .sdst = p });
    try emit(w, .{ .op = op("v_cndmask_b32"), .e64 = true, .dst = d, .src = .{ t_f, t_x, p } });
}

fn lowerDot4(w: *Work, in: Inst) Error!void {
    // no 4x8-bit dot on gfx8: four 24-bit multiply-adds of the bytes
    const d = try dstV(w, in.dst);
    const mode: kir.Dot4 = @enumFromInt(in.aux);
    const a_signed = mode != .u8u8;
    const b_signed = mode == .s8s8;
    const mad = if (mode == .u8u8) op("v_mad_u32_u24") else op("v_mad_i32_i24");
    const a = try toV(w, try src(w, in.a));
    const b = try toV(w, try src(w, in.b));
    const acc = try tmpV(w);
    const ta = try tmpV(w);
    const tb = try tmpV(w);
    try valu(w, op("v_mov_b32"), acc, &.{try src(w, in.c)}, .{});
    for (0..4) |byte| {
        const off = immSrc(@intCast(8 * byte));
        try valu(w, if (a_signed) op("v_bfe_i32") else op("v_bfe_u32"), ta, &.{ a, off, immSrc(8) }, .{});
        try valu(w, if (b_signed) op("v_bfe_i32") else op("v_bfe_u32"), tb, &.{ b, off, immSrc(8) }, .{});
        try valu(w, mad, if (byte == 3) d else acc, &.{ .{ .code = ta }, .{ .code = tb }, .{ .code = acc } }, .{});
    }
}

fn lowerCvt(w: *Work, in: Inst) Error!void {
    const c: kir.Cvt = @bitCast(in.aux);
    const d = try dstV(w, in.dst);
    const a = try src(w, in.a);
    const from_int = c.from == .u32 or c.from == .i32;
    const to_int = c.to == .u32 or c.to == .i32;
    if (from_int and to_int) return valu(w, op("v_mov_b32"), d, &.{a}, .{});
    if (from_int) {
        if (c.round != .rne) return w.fail(error.Unsupported, "cvt from an integer rounding {s}", .{@tagName(c.round)});
        return valu(w, if (c.from == .i32) op("v_cvt_f32_i32") else op("v_cvt_f32_u32"), d, &.{a}, .{});
    }
    if (c.from == .f16) {
        // (to f32: exact)
        return valu(w, op("v_cvt_f32_f16"), d, &.{a}, .{});
    }
    // from f32
    if (to_int) {
        var x = a;
        const ro: ?gcn3.Op = switch (c.round) {
            .rz => null,
            .rne => op("v_rndne_f32"),
            .rd => op("v_floor_f32"),
            .ru => op("v_ceil_f32"),
        };
        if (ro) |o| {
            const t = try tmpV(w);
            try valu(w, o, t, &.{a}, .{});
            x = .{ .code = t };
        }
        return valu(w, if (c.to == .i32) op("v_cvt_i32_f32") else op("v_cvt_u32_f32"), d, &.{x}, .{});
    }
    // to f16
    return switch (c.round) {
        .rne => valu(w, op("v_cvt_f16_f32"), d, &.{a}, .{}),
        .rz => valu(w, op("v_cvt_pkrtz_f16_f32"), d, &.{ a, .{ .code = ZERO } }, .{}),
        else => w.fail(error.Unsupported, "cvt f32 to f16 rounding {s}", .{@tagName(c.round)}),
    };
}

/// A MUBUF access through binding m.binding's V#: the offset in a VGPR
/// (offen), an SGPR (soffset) or a constant, the immediate in the
/// instruction (up to 4095) or soffset.
fn lowerBuf(w: *Work, in: Inst, m: kir.Mem) Error!void {
    const vs = w.vsharp + 4 * @as(u16, m.binding);
    var g = G{ .op = 0, .src = .{ gcn3.VGPR0, vs, ZERO } };
    const a = try src(w, in.a);
    const imm: u32 = m.imm;
    if (a.isV()) {
        g.offen = true;
        g.src[0] = a.code;
        if (imm <= 4095) g.imm = imm else {
            const t = tmpS(w);
            try emit(w, .{ .op = op("s_mov_b32"), .dst = t, .src = .{ LIT, 0, 0 }, .lit = imm });
            g.src[2] = t;
        }
    } else if (a.code < 128) {
        if (imm <= 4095) {
            g.src[2] = a.code;
            g.imm = imm;
        } else {
            const t = tmpS(w);
            try emit(w, .{ .op = op("s_add_u32"), .dst = t, .src = .{ a.code, LIT, 0 }, .lit = imm });
            g.src[2] = t;
        }
    } else {
        const base: u32 = @truncate(gcn3.constValue(a.code, a.lit, .b32) orelse 0);
        const total = base +% imm;
        if (total <= 4095) g.imm = total else {
            const t = tmpS(w);
            try emit(w, .{ .op = op("s_mov_b32"), .dst = t, .src = .{ LIT, 0, 0 }, .lit = total });
            g.src[2] = t;
        }
    }
    const bytes = kir.memBytes(m);
    switch (in.op) {
        .ld => {
            g.op = switch (bytes) {
                1 => if (m.signed) op("buffer_load_sbyte") else op("buffer_load_ubyte"),
                2 => if (m.signed) op("buffer_load_sshort") else op("buffer_load_ushort"),
                4 => op("buffer_load_dword"),
                8 => op("buffer_load_dwordx2"),
                else => op("buffer_load_dwordx4"),
            };
            g.dst = try dstV(w, in.dst);
            try emit(w, g);
        },
        .st => {
            g.op = switch (bytes) {
                1 => op("buffer_store_byte"),
                2 => op("buffer_store_short"),
                4 => op("buffer_store_dword"),
                8 => op("buffer_store_dwordx2"),
                else => op("buffer_store_dwordx4"),
            };
            const v = try src(w, in.b);
            g.dst = (try toV(w, v)).code;
            try emit(w, g);
        },
        else => {
            const kind: kir.Atom = @enumFromInt(in.c.imm);
            const signed = in.ty == .i32;
            g.op = switch (kind) {
                .add => op("buffer_atomic_add"),
                .xchg => op("buffer_atomic_swap"),
                .min => if (signed) op("buffer_atomic_smin") else op("buffer_atomic_umin"),
                .max => if (signed) op("buffer_atomic_smax") else op("buffer_atomic_umax"),
            };
            g.glc = true;
            // the data register comes back as the old value: a copy
            const t = try tmpV(w);
            try valu(w, op("v_mov_b32"), t, &.{try src(w, in.b)}, .{});
            g.dst = t;
            try emit(w, g);
            try valu(w, op("v_mov_b32"), try dstV(w, in.dst), &.{.{ .code = t }}, .{});
        },
    }
}

fn lowerLds(w: *Work, in: Inst, m: kir.Mem) Error!void {
    var addr = try src(w, in.a);
    var off: u32 = m.imm;
    if (!addr.isV()) {
        if (!addr.bus()) {
            const base: u32 = @truncate(gcn3.constValue(addr.code, addr.lit, .b32) orelse 0);
            addr = immSrc(base +% off);
            off = 0;
        }
        addr = try toV(w, addr);
    }
    if (off > 65535) {
        const t = try tmpV(w);
        try valu(w, op("v_add_u32"), t, &.{ immSrc(off), addr }, .{ .comm = true });
        addr = .{ .code = t };
        off = 0;
    }
    const bytes = kir.memBytes(m);
    switch (in.op) {
        .ld => {
            const o = switch (bytes) {
                1 => if (m.signed) op("ds_read_i8") else op("ds_read_u8"),
                2 => if (m.signed) op("ds_read_i16") else op("ds_read_u16"),
                4 => op("ds_read_b32"),
                8 => op("ds_read_b64"),
                else => op("ds_read_b128"),
            };
            try emit(w, .{ .op = o, .dst = try dstV(w, in.dst), .src = .{ addr.code, 0, 0 }, .imm = off });
        },
        .st => {
            const o = switch (bytes) {
                1 => op("ds_write_b8"),
                2 => op("ds_write_b16"),
                4 => op("ds_write_b32"),
                8 => op("ds_write_b64"),
                else => op("ds_write_b128"),
            };
            const v = try toV(w, try src(w, in.b));
            try emit(w, .{ .op = o, .src = .{ addr.code, v.code, 0 }, .imm = off });
        },
        else => {
            const kind: kir.Atom = @enumFromInt(in.c.imm);
            const signed = in.ty == .i32;
            const o = switch (kind) {
                .add => op("ds_add_rtn_u32"),
                .xchg => op("ds_wrxchg_rtn_b32"),
                .min => if (signed) op("ds_min_rtn_i32") else op("ds_min_rtn_u32"),
                .max => if (signed) op("ds_max_rtn_i32") else op("ds_max_rtn_u32"),
            };
            const v = try toV(w, try src(w, in.b));
            try emit(w, .{ .op = o, .dst = try dstV(w, in.dst), .src = .{ addr.code, v.code, 0 }, .imm = off });
        },
    }
}

fn laneId(w: *Work) Error!u16 {
    const t = try tmpV(w);
    try valu(w, op("v_mbcnt_lo_u32_b32"), t, &.{ .{ .code = MINUS_ONE }, .{ .code = ZERO } }, .{});
    try valu(w, op("v_mbcnt_hi_u32_b32"), t, &.{ .{ .code = MINUS_ONE }, .{ .code = t } }, .{});
    return t;
}

fn lowerShfl(w: *Work, in: Inst) Error!void {
    const d = try dstV(w, in.dst);
    const a = try toV(w, try src(w, in.a));
    const b = try src(w, in.b);
    const mode: kir.Shfl = @enumFromInt(in.aux);
    if (mode == .xor and in.b == .imm) {
        const x = in.b.imm & 63;
        if (x == 0) return valu(w, op("v_mov_b32"), d, &.{a}, .{});
        if (x < 32) {
            // within 32 lanes: a swizzle (and 0x1f, xor x), no address
            return emit(w, .{ .op = op("ds_swizzle_b32"), .dst = d, .src = .{ a.code, 0, 0 }, .imm = 0x1f | x << 10 });
        }
    }
    const addr = try tmpV(w);
    switch (mode) {
        .idx => try valu(w, op("v_lshlrev_b32"), addr, &.{ immSrc(2), b }, .{}),
        .xor => {
            const ln = try laneId(w);
            try valu(w, op("v_xor_b32"), addr, &.{ b, .{ .code = ln } }, .{ .comm = true });
            try valu(w, op("v_lshlrev_b32"), addr, &.{ immSrc(2), .{ .code = addr } }, .{});
        },
        .up => {
            // ln - k, or the lane itself when k > ln
            const ln = try laneId(w);
            try valu(w, op("v_sub_u32"), addr, &.{ .{ .code = ln }, b }, .{ .rev = op("v_subrev_u32") });
            try emit(w, .{ .op = op("v_cndmask_b32"), .dst = addr, .src = .{ addr, ln, VCC } });
            try valu(w, op("v_lshlrev_b32"), addr, &.{ immSrc(2), .{ .code = addr } }, .{});
        },
        .down => {
            // ln + k when k < 64 - ln, else the lane itself
            const ln = try laneId(w);
            const room = try tmpV(w);
            try valu(w, op("v_sub_u32"), room, &.{ immSrc(64), .{ .code = ln } }, .{});
            const p = try tmpPair(w);
            try valu(w, op("v_cmp_lt_u32"), 0, &.{ b, .{ .code = room } }, .{ .sdst = p });
            try valu(w, op("v_add_u32"), room, &.{ b, .{ .code = ln } }, .{ .comm = true });
            try emit(w, .{ .op = op("v_cndmask_b32"), .e64 = true, .dst = addr, .src = .{ ln, room, p } });
            try valu(w, op("v_lshlrev_b32"), addr, &.{ immSrc(2), .{ .code = addr } }, .{});
        },
    }
    try emit(w, .{ .op = op("ds_bpermute_b32"), .dst = d, .src = .{ addr, a.code, 0 } });
}

// ── Structured flow over EXEC ───────────────────────────────────────────────

fn framePair(w: *const Work, depth: usize, slot: u16) u16 {
    return w.frames_at + 4 * @as(u16, @intCast(depth)) + 2 * slot;
}

fn innermostJoin(w: *const Work) ?u16 {
    if (w.nframes == 0) return null;
    const f = &w.frames[w.nframes - 1];
    return switch (f.kind) {
        .if_then => if (f.has_else) f.l_else else f.l_end,
        .if_else => f.l_end,
        .loop => f.l_latch,
    };
}

fn innermostLoop(w: *Work) ?*Frame {
    var ix = w.nframes;
    while (ix > 0) {
        ix -= 1;
        if (w.frames[ix].kind == .loop) return &w.frames[ix];
    }
    return null;
}

/// exec = from & ~(the lanes that left the loop the way `which` says).
fn dropLeft(w: *Work, f: *const Frame, which: u2, from: u16) Error!void {
    var src_ = from;
    if (which & 1 != 0) {
        try sop2(w, op("s_andn2_b64"), EXEC, src_, f.loop_pair + 2);
        src_ = EXEC;
    }
    if (which & 2 != 0) {
        try sop2(w, op("s_andn2_b64"), EXEC, src_, f.loop_pair);
        src_ = EXEC;
    }
    if (src_ != EXEC) try sop1(w, op("s_mov_b64"), EXEC, src_);
}

/// The brk and cont an if holds for its innermost loop (bit 0 cont, bit 1
/// brk): in its then-part, and in either part.
const Drops = struct { then: u2 = 0, all: u2 = 0 };

fn ifDrops(w: *const Work, at: u32) Drops {
    var r: Drops = .{};
    var ifs: u32 = 0;
    var loops: u32 = 0;
    var in_else = false;
    var i = at + 1;
    while (i < w.k.n) : (i += 1) {
        const in = w.k.insts[i];
        switch (in.op) {
            .@"if" => ifs += 1,
            .@"else" => if (ifs == 0) {
                in_else = true;
            },
            .endif => {
                if (ifs == 0) break;
                ifs -= 1;
            },
            .loop => loops += 1,
            .endloop => loops -= 1,
            .brk, .cont => if (loops == 0 and !(in.a == .imm and in.a.imm == 0)) {
                const bit: u2 = if (in.op == .cont) 1 else 2;
                r.all |= bit;
                if (!in_else) r.then |= bit;
            },
            else => {},
        }
    }
    return r;
}

/// A predicate whose inactive lanes are 0 at instruction `at` (so `p &
/// exec` is `p`): written once by a compare (VOPC writes 0 for the lanes
/// EXEC leaves out), or an and/or of such, with no lane gone from EXEC
/// between the write and `at`; or one in a VGPR (read back by a compare).
fn predClean(w: *const Work, a: Arg, at: u32) bool {
    return predCleanDepth(w, a, at, 0);
}

fn predCleanDepth(w: *const Work, a: Arg, at: u32, depth: u32) bool {
    if (a != .reg or depth > 4) return false;
    const x = @intFromEnum(a.reg);
    if (w.loc[x].kind == .pvgpr) return true;
    if (w.ndef[x] != 1) return false;
    const def = w.def_at[x];
    if (def >= at) return false;
    const in = w.k.insts[def];
    switch (in.op) {
        .icmp, .fcmp => {},
        .pand, .por => if (!predCleanDepth(w, in.a, at, depth + 1) or !predCleanDepth(w, in.b, at, depth + 1)) return false,
        else => return false,
    }
    // EXEC between the write and `at`: no lane may leave, and `at` may
    // not be in an if the write is outside of
    var d: i32 = 0;
    var lo: i32 = 0;
    var i = def + 1;
    while (i < at) : (i += 1) {
        switch (w.k.insts[i].op) {
            .@"if" => d += 1,
            .@"else" => if (d <= lo) return false,
            .endif => {
                d -= 1;
                lo = @min(lo, d);
            },
            .brk, .cont, .ret, .loop, .endloop => return false,
            else => {},
        }
    }
    return d == lo;
}

/// Lanes `m` (an SGPR pair) leave every frame up to the innermost loop
/// (brk, cont) or all frames (ret).
fn leave(w: *Work, m: u16, to_loop: bool) Error!?*Frame {
    var ix = w.nframes;
    while (ix > 0) {
        ix -= 1;
        const f = &w.frames[ix];
        if (f.kind == .loop) {
            if (to_loop) return f;
            try sop2(w, op("s_andn2_b64"), f.pair, f.pair, m);
            if (f.has_cont) try sop2(w, op("s_andn2_b64"), f.pair + 2, f.pair + 2, m);
        } else try sop2(w, op("s_andn2_b64"), f.pair, f.pair, m);
    }
    return null;
}

fn hasCont(w: *const Work, loop_at: u32) bool {
    const e = w.match[loop_at];
    var depth: u32 = 0;
    var i = loop_at + 1;
    while (i < e) : (i += 1) {
        switch (w.k.insts[i].op) {
            .loop => depth += 1,
            .endloop => depth -= 1,
            .cont => if (depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn lowerFlow(w: *Work, in: Inst) Error!void {
    const i = w.cur;
    switch (in.op) {
        .@"if" => {
            if (w.nframes == MAX_DEPTH) return error.TooComplex;
            const has_else = w.k.insts[w.match[i]].op == .@"else";
            var f = Frame{ .kind = .if_then, .pair = framePair(w, w.nframes, 0), .has_else = has_else };
            const dr = ifDrops(w, i);
            f.then_drops = dr.then;
            f.drops = dr.all;
            if (f.drops != 0) f.loop_pair = (innermostLoop(w) orelse return error.Unbalanced).pair;
            f.l_end = try newLabel(w);
            if (has_else) f.l_else = try newLabel(w);
            try sop1(w, op("s_and_saveexec_b64"), f.pair, try psrc(w, in.a));
            w.frames[w.nframes] = f;
            w.nframes += 1;
            try emitBranch(w, op("s_cbranch_execz"), if (has_else) f.l_else else f.l_end);
        },
        .@"else" => {
            const f = &w.frames[w.nframes - 1];
            f.kind = .if_else;
            place(w, f.l_else);
            // the lanes still here, of those the if had, that were not in
            // the then-part (nor left the loop from it)
            try sop2(w, op("s_andn2_b64"), EXEC, f.pair, EXEC);
            try dropLeft(w, f, f.then_drops, EXEC);
            try emitBranch(w, op("s_cbranch_execz"), f.l_end);
        },
        .endif => {
            w.nframes -= 1;
            const f = w.frames[w.nframes];
            place(w, f.l_end);
            if (f.drops == 0) {
                try sop1(w, op("s_mov_b64"), EXEC, f.pair);
            } else try dropLeft(w, &f, f.drops, f.pair);
        },
        .loop => {
            if (w.nframes == MAX_DEPTH) return error.TooComplex;
            var f = Frame{ .kind = .loop, .pair = framePair(w, w.nframes, 0), .has_cont = hasCont(w, i) };
            f.l_top = try newLabel(w);
            f.l_latch = try newLabel(w);
            try sop1(w, op("s_mov_b64"), f.pair, ZERO);
            if (f.has_cont) try sop1(w, op("s_mov_b64"), f.pair + 2, ZERO);
            w.frames[w.nframes] = f;
            w.nframes += 1;
            place(w, f.l_top);
        },
        .brk, .cont => {
            if (in.a == .imm and in.a.imm == 0) return;
            const lp = innermostLoop(w) orelse return error.Unbalanced;
            const m = if (in.op == .brk) lp.pair else lp.pair + 2;
            if (in.a == .imm) {
                // every lane here
                try sop2(w, op("s_or_b64"), m, m, EXEC);
                try sop1(w, op("s_mov_b64"), EXEC, ZERO);
                return emitBranch(w, op("s_branch"), innermostJoin(w).?);
            }
            const p = try psrc(w, in.a);
            var t = p;
            if (!predClean(w, in.a, w.cur)) {
                t = try tmpPair(w);
                try sop2(w, op("s_and_b64"), t, EXEC, p);
            }
            try sop2(w, op("s_or_b64"), m, m, t);
            try sop2(w, op("s_andn2_b64"), EXEC, EXEC, t);
            try emitBranch(w, op("s_cbranch_execz"), innermostJoin(w).?);
        },
        .endloop => {
            w.nframes -= 1;
            const f = w.frames[w.nframes];
            place(w, f.l_latch);
            if (f.has_cont) {
                try sop2(w, op("s_or_b64"), EXEC, EXEC, f.pair + 2);
                try sop1(w, op("s_mov_b64"), f.pair + 2, ZERO);
            }
            try emitBranch(w, op("s_cbranch_execnz"), f.l_top);
            // out: the lanes that broke out
            try sop1(w, op("s_mov_b64"), EXEC, f.pair);
        },
        .ret => {
            if (w.nframes == 0) return emit(w, .{ .op = op("s_endpgm") });
            _ = try leave(w, EXEC, false);
            try sop1(w, op("s_mov_b64"), EXEC, ZERO);
            try emitBranch(w, op("s_branch"), innermostJoin(w).?);
        },
        else => unreachable,
    }
}

// ── Waits: s_waitcnt and gfx8's manual wait states ──────────────────────────

fn overlaps(a: u16, an: u8, b: u16, bn: u8) bool {
    return a < b + bn and b < a + an;
}

fn isVmem(e: gcn3.Enc) bool {
    return e == .mubuf or e == .mtbuf or e == .flat;
}

fn isValu(e: gcn3.Enc) bool {
    return e == .vop1 or e == .vop2 or e == .vopc or e == .vop3;
}

fn mergeInto(dst: *WState, s: *const WState) void {
    if (!dst.valid) {
        dst.* = s.*;
        dst.valid = true;
        return;
    }
    dst.smem = dst.smem or s.smem;
    mergeList(&dst.vm, &dst.nvm, s.vm[0..s.nvm]);
    mergeList(&dst.lg, &dst.nlg, s.lg[0..s.nlg]);
}

fn mergeList(list: *[MAX_PENDING]Pend, n: *u8, add: []const Pend) void {
    for (add) |p| {
        var found = false;
        for (list[0..n.*]) |*q| {
            if (q.code == p.code and q.n == p.n) {
                q.younger = @min(q.younger, p.younger);
                q.smem = q.smem or p.smem;
                found = true;
            }
        }
        if (!found) {
            if (n.* < MAX_PENDING) {
                list[n.*] = p;
                n.* += 1;
            } else {
                // full: the youngest count possible (wait for all)
                for (list[0..n.*]) |*q| q.younger = 0;
            }
        }
    }
}

fn retire(list: *[MAX_PENDING]Pend, n: *u8, cnt: u8) void {
    var j: u8 = 0;
    for (list[0..n.*]) |p| {
        if (p.younger < cnt) {
            list[j] = p;
            j += 1;
        }
    }
    n.* = j;
}

const Track = struct {
    st: WState = .{ .valid = true },
    /// wait states: after each SGPR's last VALU write, and the wide store
    ws: u64 = 0,
    valu_s: [128]u64 = [_]u64{0} ** 128,
    store_lo: u16 = 0,
    store_n: u8 = 0,
    store_ws: u64 = 0,
};

fn emitOut(w: *Work, x: MI) Error!void {
    if (w.nmo == MAX_MI) return w.fail(error.TooManyInsts, "more than {d} machine instructions", .{MAX_MI});
    w.mo[w.nmo] = x;
    w.nmo += 1;
}

fn waits(w: *Work) Error!void {
    // label positions: old index -> label ids
    for (0..w.nlabels) |l| w.lstate[l] = .{};
    var t = Track{};
    w.nmo = 0;
    const new_pos = &w.new_pos;
    @memset(w.lhead[0 .. w.nmi + 1], 0xffff);
    for (0..w.nlabels) |l| {
        new_pos[l] = 0xffff_ffff;
        const at = @min(w.labels[l], @as(u32, @intCast(w.nmi)));
        w.lnext[l] = w.lhead[at];
        w.lhead[at] = @intCast(l);
    }
    var fall = true;
    for (w.mi[0..w.nmi], 0..) |x, i| {
        // labels here: the states of the branches to them join the fall-through
        var any_label = false;
        var ll = w.lhead[i];
        while (ll != 0xffff) : (ll = w.lnext[ll]) {
            const l = ll;
            any_label = true;
            new_pos[l] = @intCast(w.nmo);
            if (w.lstate[l].valid) {
                if (fall) mergeInto(&w.lstate[l], &t.st);
                t.st = w.lstate[l];
            }
        }
        if (any_label) {
            // (a label reached by a backward branch carries nothing: loads
            // are waited for before it)
            t.st.valid = true;
        }
        const in = x.in;
        const e = in.enc();
        const rl = gcn3.regs(&in);
        // s_waitcnt the instruction needs
        var need_vm: u8 = 0xff;
        var need_lg: u8 = 0xff;
        const backward = x.target != 0xffff and w.labels[x.target] <= i;
        for ([_][]const gcn3.RegRef{ rl.readSlice(), rl.writeSlice() }) |refs| {
            for (refs) |r| {
                for (t.st.vm[0..t.st.nvm]) |p| {
                    if (p.n != 0 and overlaps(r.code, r.n, p.code, p.n)) need_vm = @min(need_vm, p.younger);
                }
                for (t.st.lg[0..t.st.nlg]) |p| {
                    if (p.n != 0 and overlaps(r.code, r.n, p.code, p.n)) need_lg = @min(need_lg, if (t.st.smem) 0 else p.younger);
                }
            }
        }
        if (backward or in.op == op("s_endpgm")) {
            for (t.st.vm[0..t.st.nvm]) |p| {
                if (p.n != 0) need_vm = @min(need_vm, p.younger);
            }
            for (t.st.lg[0..t.st.nlg]) |p| {
                if (p.n != 0) need_lg = @min(need_lg, if (t.st.smem) 0 else p.younger);
            }
            if (in.op == op("s_endpgm")) {
                need_vm = 0xff;
                need_lg = 0xff;
            }
        }
        // the counters are 4 bits: never more than 15 outstanding
        if (isVmem(e) and t.st.nvm >= MAX_PENDING) need_vm = @min(need_vm, MAX_PENDING - 1);
        if ((e == .smem or e == .ds or e == .flat) and t.st.nlg >= MAX_PENDING) need_lg = @min(need_lg, @as(u8, if (t.st.smem) 0 else MAX_PENDING - 1));
        if (in.op == op("s_waitcnt")) {
            // an explicit wait (the barrier's): merge with what is needed
            const vm: u8 = @intCast(in.imm & 15);
            const lg: u8 = @intCast(in.imm >> 8 & 15);
            need_vm = @min(need_vm, vm);
            need_lg = @min(need_lg, lg);
            try waitFor(w, &t, need_vm, need_lg, true);
            continue;
        }
        if (need_vm != 0xff or need_lg != 0xff) try waitFor(w, &t, need_vm, need_lg, false);
        // wait states
        if (isValu(e)) {
            if (t.store_n != 0 and t.ws - t.store_ws < 1) {
                for (rl.writeSlice()) |r| {
                    if (r.code >= gcn3.VGPR0 and overlaps(r.code - gcn3.VGPR0, r.n, t.store_lo, t.store_n)) {
                        try nop(w, &t, 0);
                        break;
                    }
                }
            }
        }
        if (e == .mubuf or e == .mtbuf) {
            var need: u64 = 0;
            for (rl.readSlice()) |r| {
                if (r.code >= 128) continue;
                for (0..r.n) |j| {
                    const at = t.valu_s[r.code + j];
                    if (at != 0 and t.ws - at < 5) need = @max(need, 5 - (t.ws - at));
                }
            }
            if (need > 0) try nop(w, &t, @intCast(need - 1));
        }
        // the instruction
        try emitOut(w, x);
        const ws_before = t.ws;
        t.ws += if (in.op == op("s_nop")) in.imm + 1 else 1;
        if (isValu(e)) {
            for (rl.writeSlice()) |r| {
                if (r.code < 128) {
                    for (0..r.n) |j| t.valu_s[r.code + j] = ws_before + 1;
                }
            }
        }
        // what it leaves outstanding
        if (isVmem(e)) {
            for (t.st.vm[0..t.st.nvm]) |*p| p.younger +|= 1;
            const wr = rl.writeSlice();
            const p = Pend{ .code = if (wr.len > 0) wr[0].code else 0, .n = if (wr.len > 0) wr[0].n else 0, .younger = 0 };
            t.st.vm[t.st.nvm] = p;
            t.st.nvm += 1;
            if (e == .flat) {
                for (t.st.lg[0..t.st.nlg]) |*q| q.younger +|= 1;
                t.st.lg[t.st.nlg] = p;
                t.st.nlg += 1;
            }
            const df = in.d();
            const data_n: u8 = if (df.shape == .buf_store) df.d.dwords() else if (df.shape == .flat_store) df.s[1].dwords() else 0;
            if (data_n > 2) {
                t.store_lo = (if (df.shape == .flat_store) in.src[1] else in.dst) - gcn3.VGPR0;
                t.store_n = data_n;
                t.store_ws = ws_before + 1;
            }
        } else if (e == .smem or e == .ds) {
            for (t.st.lg[0..t.st.nlg]) |*p| p.younger +|= 1;
            const wr = rl.writeSlice();
            // (DS reads M0 and its address; only its destination is pending)
            var p = Pend{ .code = 0, .n = 0, .younger = 0, .smem = e == .smem };
            for (wr) |r| {
                p.code = r.code;
                p.n = r.n;
            }
            t.st.lg[t.st.nlg] = p;
            t.st.nlg += 1;
            if (e == .smem) t.st.smem = true;
        }
        // branches carry the state forward
        if (x.target != 0xffff and !backward) {
            mergeInto(&w.lstate[x.target], &t.st);
        }
        fall = !(in.op == op("s_branch") or in.op == op("s_endpgm"));
    }
    // labels at the very end
    for (0..w.nlabels) |l| {
        if (w.labels[l] >= w.nmi) new_pos[l] = @intCast(w.nmo);
    }
    @memcpy(w.mi[0..w.nmo], w.mo[0..w.nmo]);
    w.nmi = w.nmo;
    for (0..w.nlabels) |l| w.labels[l] = new_pos[l];
}

fn nop(w: *Work, t: *Track, n: u4) Error!void {
    try emitOut(w, .{ .in = .{ .op = op("s_nop"), .imm = n } });
    t.ws += @as(u64, n) + 1;
    w.stats.nops += 1;
}

fn waitFor(w: *Work, t: *Track, vm: u8, lg: u8, always: bool) Error!void {
    const v: u8 = @min(vm, 15);
    const l: u8 = @min(lg, 15);
    if (!always and v == 15 and l == 15) return;
    try emitOut(w, .{ .in = .{ .op = op("s_waitcnt"), .imm = @as(u32, v) | 7 << 4 | @as(u32, l) << 8 } });
    t.ws += 1;
    w.stats.waits += 1;
    retire(&t.st.vm, &t.st.nvm, v);
    if (l == 0) {
        t.st.nlg = 0;
        t.st.smem = false;
    } else if (!t.st.smem) retire(&t.st.lg, &t.st.nlg, l);
}

// ── Encoding ────────────────────────────────────────────────────────────────

fn encode(w: *Work) Error!void {
    // dword addresses
    const pcs = &w.pcs;
    var pc: u32 = 0;
    for (w.mi[0..w.nmi], 0..) |x, i| {
        pcs[i] = pc;
        pc += x.in.dwords();
    }
    pcs[w.nmi] = pc;
    if (pc > MAX_WORDS) return w.fail(error.TooManyInsts, "{d} dwords of code", .{pc});
    for (w.mi[0..w.nmi], 0..) |*x, i| {
        if (x.target != 0xffff) {
            const to = w.labels[x.target];
            if (to == 0xffff_ffff) return w.fail(error.BadOperand, "a branch to an unplaced label", .{});
            const rel = @as(i64, pcs[to]) - (@as(i64, pcs[i]) + 1);
            if (rel < -32768 or rel > 32767) return w.fail(error.TooComplex, "a branch over {d} dwords", .{rel});
            x.in.imm = @as(u16, @bitCast(@as(i16, @intCast(rel))));
        }
        _ = gcn3.encode(&x.in, w.words[pcs[i]..]) catch |e| {
            return w.fail(error.Unsupported, "{s}: {s} at machine instruction {d}", .{ gcn3.def(x.in.op).name, @errorName(e), i });
        };
    }
    w.nwords = pc;
    w.stats.instructions = @intCast(w.nmi);
    w.stats.words = pc;
}

fn binary(w: *Work, out: []u8) Error!device.Binary {
    const bytes = 4 * w.nwords;
    if (out.len < bytes) return error.NoSpaceLeft;
    for (w.words[0..w.nwords], 0..) |x, i| std.mem.writeInt(u32, out[4 * i ..][0..4], x, .little);
    const info = Info{
        .vgprs = w.vgpr_end,
        .sgprs = w.sgpr_end,
        .group_id = w.group_id,
        .workitem = w.workitem,
        .flush = w.caps.denormals == .flush,
        .kernarg_dwords = w.nka,
        .gsize_at = w.gsize_at,
        .instructions = @intCast(w.nmi),
        .shared_bytes = w.k.shared_bytes,
        .spilled_preds = w.spilled_preds,
    };
    w.stats.vgprs = w.vgpr_end;
    w.stats.sgprs = w.sgpr_end;
    return .{
        .target = .gcn4_gfx803,
        .code = out[0..bytes],
        .regs = w.vgpr_end,
        .shared_bytes = w.k.shared_bytes,
        .group = w.k.group,
        .bindings = w.k.bindings,
        .param_words = w.k.param_words,
        .extra = info.toExtra(),
    };
}

/// The compiled code as text, one instruction a line with its dword offset.
pub fn listing(w: *const Work, buf: []u8) []const u8 {
    var t = gcn3.Text{ .buf = buf };
    var pc: u32 = 0;
    for (w.mi[0..w.nmi], 0..) |x, i| {
        for (0..w.nlabels) |l| {
            if (w.labels[l] == i) t.print("L{d}:\n", .{l});
        }
        t.print("{x:0>4}: ", .{pc * 4});
        gcn3.formatInto(&t, &x.in) catch {};
        t.str("\n");
        pc += x.in.dwords();
    }
    return t.text();
}

/// The caps of the MacBook Pro 15" 2018's Radeon Pro 560X (555X alike):
/// Polaris 21, gfx803, discrete, 4 GB of VRAM; v_fma_f32 is fused,
/// v_mad_f32 is not (and flushes f32 denormals), so the fast path flushes.
pub fn polaris_caps(device_bytes: u64) device.Caps {
    return .{
        .vendor = .amd,
        .target = .gcn4_gfx803,
        .name = "Radeon Pro 560X (Polaris 21, gfx803)",
        .memory = .discrete,
        .coherent = false,
        .device_bytes = device_bytes,
        .subgroup = 64,
        .max_group = 1024,
        .shared_bytes = 64 * 1024,
        .fused_fma = true,
        .mad = .unfused,
        .denormals = .flush,
        .dot4 = false,
        .import = false,
        .timestamp_hz = 100_000_000,
    };
}
