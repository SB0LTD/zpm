//! @zpm/hlsl ir — the generator's instructions: DXBC's own (opcode,
//! controls, operands), with temps numbered as virtual registers until the
//! allocator gives each a real one. Then the encoder writes them as Shader
//! Model 4/5 tokens (d3d11TokenizedProgramFormat).
//!
//! - **Dead code.** Instructions whose only results are temps nobody reads
//!   are dropped (repeatedly), so unused statics and helper values cost
//!   nothing.
//! - **Registers.** Each virtual temp lives from its first to its last use;
//!   a temp live across a loop's back edge (read before written in it, or
//!   live into it) lives through the whole loop. Linear scan over those
//!   intervals gives the fewest real temps it can, one temp per virtual.

const std = @import("std");

/// DXBC operand types (D3D10_SB_OPERAND_TYPE), the ones generated.
pub const Reg = enum(u8) {
    temp = 0,
    input = 1,
    output = 2,
    indexable_temp = 3,
    imm32 = 4,
    sampler = 6,
    resource = 7,
    cb = 8,
    icb = 9,
    label = 10,
    input_primitive_id = 11,
    output_depth = 12,
    null = 13,
    stream = 16,
    input_coverage_mask = 35,
    _,
};

/// Opcodes (D3D10_SB_OPCODE_TYPE / D3D11).
pub const Op = enum(u16) {
    add = 0,
    @"and" = 1,
    @"break" = 2,
    breakc = 3,
    case = 6,
    @"continue" = 7,
    continuec = 8,
    cut = 9,
    default = 10,
    deriv_rtx = 11,
    deriv_rty = 12,
    discard = 13,
    div = 14,
    dp2 = 15,
    dp3 = 16,
    dp4 = 17,
    @"else" = 18,
    emit = 19,
    endif = 21,
    endloop = 22,
    endswitch = 23,
    eq = 24,
    exp = 25,
    frc = 26,
    ftoi = 27,
    ftou = 28,
    ge = 29,
    iadd = 30,
    @"if" = 31,
    ieq = 32,
    ige = 33,
    ilt = 34,
    imad = 35,
    imax = 36,
    imin = 37,
    imul = 38,
    ine = 39,
    ineg = 40,
    ishl = 41,
    ishr = 42,
    itof = 43,
    ld = 45,
    ld_ms = 46,
    log = 47,
    loop = 48,
    lt = 49,
    mad = 50,
    min = 51,
    max = 52,
    customdata = 53,
    mov = 54,
    movc = 55,
    mul = 56,
    ne = 57,
    nop = 58,
    not = 59,
    @"or" = 60,
    resinfo = 61,
    ret = 62,
    retc = 63,
    round_ne = 64,
    round_ni = 65,
    round_pi = 66,
    round_z = 67,
    rsq = 68,
    sample = 69,
    sample_c = 70,
    sample_c_lz = 71,
    sample_l = 72,
    sample_d = 73,
    sample_b = 74,
    sqrt = 75,
    @"switch" = 76,
    sincos = 77,
    udiv = 78,
    ult = 79,
    uge = 80,
    umul = 81,
    umad = 82,
    umax = 83,
    umin = 84,
    ushr = 85,
    utof = 86,
    xor = 87,
    dcl_resource = 88,
    dcl_constant_buffer = 89,
    dcl_sampler = 90,
    dcl_index_range = 91,
    dcl_gs_output_primitive_topology = 92,
    dcl_gs_input_primitive = 93,
    dcl_max_output_vertex_count = 94,
    dcl_input = 95,
    dcl_input_sgv = 96,
    dcl_input_siv = 97,
    dcl_input_ps = 98,
    dcl_input_ps_sgv = 99,
    dcl_input_ps_siv = 100,
    dcl_output = 101,
    dcl_output_sgv = 102,
    dcl_output_siv = 103,
    dcl_temps = 104,
    dcl_indexable_temp = 105,
    dcl_global_flags = 106,
    lod = 108,
    gather4 = 109,
    sample_pos = 110,
    sample_info = 111,
    emit_stream = 117,
    cut_stream = 118,
    deriv_rtx_coarse = 122,
    deriv_rtx_fine = 123,
    deriv_rty_coarse = 124,
    deriv_rty_fine = 125,
    gather4_c = 126,
    gather4_po = 127,
    gather4_po_c = 128,
    rcp = 129,
    f32tof16 = 130,
    f16tof32 = 131,
    uaddc = 132,
    usubb = 133,
    countbits = 134,
    firstbit_hi = 135,
    firstbit_lo = 136,
    firstbit_shi = 137,
    ubfe = 138,
    ibfe = 139,
    bfi = 140,
    bfrev = 141,
    swapc = 142,
    dcl_stream = 143,
    _,
};

pub const Rel = struct {
    on: bool = false,
    reg: Reg = .temp,
    idx: u32 = 0,
    comp: u2 = 0,
};

pub const Mode = enum(u2) { mask = 0, swizzle = 1, select1 = 2 };

pub const Opnd = struct {
    reg: Reg,
    /// 0, 1 or 4 components
    comps: u8 = 4,
    mode: Mode = .swizzle,
    mask: u4 = 0xf,
    swz: [4]u2 = .{ 0, 1, 2, 3 },
    dims: u8 = 1,
    /// 0 none, 1 neg, 2 abs, 3 abs then neg
    mods: u2 = 0,
    idx: [2]u32 = .{ 0, 0 },
    /// a relative index (on dimension `rel_dim`)
    rel: Rel = .{},
    rel_dim: u8 = 0,
    imm: [4]u32 = .{ 0, 0, 0, 0 },

    pub fn isVtemp(o: Opnd) bool {
        return o.reg == .temp;
    }
};

pub const MAX_OPS = 6;

pub const Inst = struct {
    op: Op,
    /// the opcode token's bits 11-23 (saturate, test, return types, modes)
    ctl: u16 = 0,
    /// how many leading operands are destinations
    ndst: u8 = 1,
    n: u8 = 0,
    ops: [MAX_OPS]Opnd = undefined,
    /// sample controls: texel offsets (an extended opcode token)
    offset: [3]i8 = .{ 0, 0, 0 },
    has_offset: bool = false,
    /// Shader Model 5's resource dimension and return type (extended tokens)
    res_dim: u8 = 0,
    res_ret: u16 = 0,
};

pub const CTL_SAT: u16 = 1 << 2; // (bit 13 of the token)
pub const CTL_NZ: u16 = 1 << 7; // (bit 18)

pub const MAX_INSTS = 1 << 15;

pub const Program = struct {
    insts: [MAX_INSTS]Inst,
    n: u32,
    nvregs: u32,

    pub fn reset(p: *Program) void {
        p.n = 0;
        p.nvregs = 0;
    }

    pub fn vreg(p: *Program) u32 {
        const v = p.nvregs;
        p.nvregs += 1;
        return v;
    }

    pub fn add(p: *Program, i: Inst) bool {
        if (p.n >= MAX_INSTS) return false;
        p.insts[p.n] = i;
        p.n += 1;
        return true;
    }
};

// ── flow and side effects ──

fn sideEffect(op: Op) bool {
    return switch (op) {
        .@"break", .breakc, .case, .@"continue", .continuec, .cut, .default, .discard, .@"else", .emit, .endif, .endloop, .endswitch, .@"if", .loop, .ret, .retc, .@"switch", .emit_stream, .cut_stream, .nop => true,
        else => false,
    };
}

/// Drops instructions that write only temps nobody reads (until none).
pub fn deadCode(p: *Program, reads: []u32) void {
    while (true) {
        @memset(reads[0..p.nvregs], 0);
        for (p.insts[0..p.n]) |*i| {
            for (i.ops[0..i.n], 0..) |*o, k| {
                if (k >= i.ndst and o.reg == .temp) reads[o.idx[0]] += 1;
                if (o.rel.on and o.rel.reg == .temp) reads[o.rel.idx] += 1;
            }
        }
        var w: u32 = 0;
        var removed = false;
        for (p.insts[0..p.n]) |i| {
            var dead = !sideEffect(i.op) and i.ndst > 0;
            if (dead) {
                for (i.ops[0..i.ndst]) |o| {
                    if (o.reg == .null) continue;
                    if (o.reg != .temp or reads[o.idx[0]] != 0) dead = false;
                }
            }
            if (dead) {
                removed = true;
                continue;
            }
            p.insts[w] = i;
            w += 1;
        }
        p.n = w;
        if (!removed) break;
    }
}

/// Ops computed component by component: a source's component c feeds
/// the destination's component c.
pub fn componentwise(op: Op) bool {
    return switch (op) {
        .mov, .movc, .add, .mul, .div, .mad, .min, .max, .frc, .round_ne, .round_ni, .round_pi, .round_z, .exp, .log, .rsq, .sqrt, .rcp, .eq, .ne, .lt, .ge, .iadd, .imul, .umul, .imad, .umad, .imax, .imin, .umax, .umin, .ineg, .not, .@"and", .@"or", .xor, .ishl, .ishr, .ushr, .ieq, .ine, .ilt, .ige, .ult, .uge, .ftoi, .ftou, .itof, .utof, .udiv, .sincos, .deriv_rtx, .deriv_rty, .deriv_rtx_coarse, .deriv_rtx_fine, .deriv_rty_coarse, .deriv_rty_fine, .f32tof16, .f16tof32, .bfrev, .countbits, .firstbit_hi, .firstbit_lo, .firstbit_shi, .ubfe, .ibfe, .bfi => true,
        else => false,
    };
}

/// The components of source operand `k` an instruction reads (of the
/// register, after its swizzle).
pub fn readMask(i: *const Inst, k: usize) u4 {
    const o = i.ops[k];
    if (o.comps != 4) return 1;
    if (o.mode == .select1) return @as(u4, 1) << o.swz[0];
    if (o.mode == .mask) return o.mask;
    var m: u4 = 0;
    if (componentwise(i.op)) {
        var dm: u4 = 0;
        for (i.ops[0..i.ndst]) |d| {
            if (d.reg != .null and d.comps == 4) dm |= d.mask;
        }
        for (0..4) |c| {
            if (dm & (@as(u4, 1) << @intCast(c)) != 0) m |= @as(u4, 1) << o.swz[c];
        }
        return m;
    }
    // (dp2 and dp3 read their first components only)
    const n: usize = switch (i.op) {
        .dp2 => 2,
        .dp3 => 3,
        else => 4,
    };
    for (o.swz[0..n]) |sw| m |= @as(u4, 1) << sw;
    return m;
}

/// Drops the components of temps nobody reads from the instructions that
/// write them (and instructions left writing nothing), until none.
pub fn deadComponents(p: *Program, reads: []u8) void {
    while (true) {
        @memset(reads[0..p.nvregs], 0);
        for (p.insts[0..p.n]) |*i| {
            for (i.ops[0..i.n], 0..) |o, k| {
                if (k >= i.ndst and o.reg == .temp) reads[o.idx[0]] |= readMask(i, k);
                if (o.rel.on and o.rel.reg == .temp) reads[o.rel.idx] |= @as(u8, 1) << o.rel.comp;
            }
        }
        var changed = false;
        var w: u32 = 0;
        for (p.insts[0..p.n]) |ins| {
            var i = ins;
            var only_temps = !sideEffect(i.op) and i.ndst > 0;
            if (only_temps) {
                for (i.ops[0..i.ndst]) |d| {
                    if (d.reg != .temp and d.reg != .null) only_temps = false;
                }
            }
            if (only_temps) {
                var left: u4 = 0;
                for (i.ops[0..i.ndst]) |*d| {
                    if (d.reg != .temp) continue;
                    const m: u4 = d.mask & @as(u4, @truncate(reads[d.idx[0]]));
                    if (m != d.mask) {
                        d.mask = m;
                        changed = true;
                    }
                    left |= m;
                }
                if (left == 0) {
                    changed = true;
                    continue;
                }
                // (a destination left empty: null, as fxc writes it)
                for (i.ops[0..i.ndst]) |*d| {
                    if (d.reg == .temp and d.mask == 0) d.* = .{ .reg = .null, .comps = 0, .dims = 0 };
                }
            }
            p.insts[w] = i;
            w += 1;
        }
        p.n = w;
        if (!changed) break;
    }
}

pub const Interval = struct { start: u32, end: u32, first_read: bool, used: bool };

/// Gives each virtual temp a real one; the count of real temps.
pub fn allocate(p: *Program, iv: []Interval, map: []u32, loops: [][2]u32, sorted: []u32) u32 {
    const nv = p.nvregs;
    for (iv[0..nv]) |*x| x.* = .{ .start = 0, .end = 0, .first_read = false, .used = false };
    // loops' extents
    var nl: usize = 0;
    var stack: [64]u32 = undefined;
    var sp: usize = 0;
    for (p.insts[0..p.n], 0..) |i, k| {
        if (i.op == .loop and sp < stack.len) {
            stack[sp] = @intCast(k);
            sp += 1;
        } else if (i.op == .endloop and sp > 0) {
            sp -= 1;
            if (nl < loops.len) {
                loops[nl] = .{ stack[sp], @intCast(k) };
                nl += 1;
            }
        }
    }
    // intervals (reads before writes within an instruction)
    for (p.insts[0..p.n], 0..) |i, k_| {
        const k: u32 = @intCast(k_);
        for (i.ops[0..i.n], 0..) |o, j| {
            const isdst = j < i.ndst;
            if (o.rel.on and o.rel.reg == .temp) touch(iv, o.rel.idx, k, true);
            if (o.reg == .temp and !isdst) touch(iv, o.idx[0], k, true);
        }
        for (i.ops[0..i.ndst]) |o| {
            if (o.reg == .temp) touch(iv, o.idx[0], k, false);
        }
    }
    // loops: a temp live into a loop, or read before written in it, lives
    // through the whole loop
    var changed = true;
    while (changed) {
        changed = false;
        for (iv[0..nv]) |*x| {
            if (!x.used) continue;
            for (loops[0..nl]) |l| {
                const ls = l[0];
                const le = l[1];
                if (x.end < ls or x.start > le) continue;
                if (x.start < ls and x.end < le) {
                    x.end = le;
                    changed = true;
                } else if (x.start >= ls and x.first_read and x.start != ls) {
                    x.start = ls;
                    if (x.end < le) x.end = le;
                    changed = true;
                } else if (x.start >= ls and x.end > le and x.start != ls) {
                    // (written in the loop, read after it: through the loop)
                    x.start = ls;
                    changed = true;
                }
            }
        }
    }
    // linear scan, in order of start
    var nreal: u32 = 0;
    // (each real temp's current end)
    var ends: [4096]u32 = undefined;
    var ns: usize = 0;
    for (0..nv) |v| {
        if (iv[v].used and ns < sorted.len) {
            sorted[ns] = @intCast(v);
            ns += 1;
        }
    }
    std.sort.pdq(u32, sorted[0..ns], iv, struct {
        fn lt(ctx: []Interval, a: u32, b: u32) bool {
            return ctx[a].start < ctx[b].start or (ctx[a].start == ctx[b].start and a < b);
        }
    }.lt);
    for (sorted[0..ns]) |v| {
        var pick: ?u32 = null;
        for (0..nreal) |r| {
            if (ends[r] < iv[v].start) {
                pick = @intCast(r);
                break;
            }
        }
        const r = pick orelse blk: {
            if (nreal >= ends.len) break :blk nreal - 1;
            nreal += 1;
            break :blk nreal - 1;
        };
        ends[r] = iv[v].end;
        map[v] = r;
    }
    // rewrite
    for (p.insts[0..p.n]) |*i| {
        for (i.ops[0..i.n]) |*o| {
            if (o.reg == .temp) o.idx[0] = map[o.idx[0]];
            if (o.rel.on and o.rel.reg == .temp) o.rel.idx = map[o.rel.idx];
        }
    }
    return nreal;
}

fn touch(iv: []Interval, v: u32, k: u32, read: bool) void {
    const x = &iv[v];
    if (!x.used) {
        x.* = .{ .start = k, .end = k, .first_read = read, .used = true };
        return;
    }
    if (k < x.start) x.start = k;
    if (k > x.end) x.end = k;
}

// ── the encoder ──

pub const Out = struct {
    buf: []u32,
    n: usize = 0,
    over: bool = false,

    pub fn put(o: *Out, w: u32) void {
        if (o.n >= o.buf.len) {
            o.over = true;
            return;
        }
        o.buf[o.n] = w;
        o.n += 1;
    }
};

fn compsCode(c: u8) u32 {
    return switch (c) {
        0 => 0,
        1 => 1,
        else => 2,
    };
}

pub fn encodeOperand(o: *Out, x: Opnd) void {
    var t: u32 = compsCode(x.comps);
    if (x.comps == 4) {
        t |= @as(u32, @intFromEnum(x.mode)) << 2;
        switch (x.mode) {
            .mask => t |= @as(u32, x.mask) << 4,
            .swizzle => t |= (@as(u32, x.swz[0]) | @as(u32, x.swz[1]) << 2 | @as(u32, x.swz[2]) << 4 | @as(u32, x.swz[3]) << 6) << 4,
            .select1 => t |= @as(u32, x.swz[0]) << 4,
        }
    }
    t |= @as(u32, @intFromEnum(x.reg)) << 12;
    const dims: u32 = if (x.reg == .imm32) 0 else x.dims;
    t |= dims << 20;
    for (0..dims) |d| {
        // (a relative index always with its immediate part: imm32 + relative)
        const repr: u32 = if (x.rel.on and x.rel_dim == d) 3 else 0;
        t |= repr << @intCast(22 + d * 3);
    }
    if (x.mods != 0) t |= 0x8000_0000;
    o.put(t);
    if (x.mods != 0) o.put(1 | (@as(u32, x.mods) << 6));
    if (x.reg == .imm32) {
        const n: usize = if (x.comps == 1) 1 else 4;
        for (0..n) |k| o.put(x.imm[k]);
        return;
    }
    for (0..dims) |d| {
        const rl = x.rel;
        o.put(x.idx[d]);
        if (rl.on and x.rel_dim == d) {
            // the index register: one component, selected
            const r = Opnd{ .reg = rl.reg, .comps = 4, .mode = .select1, .swz = .{ rl.comp, 0, 0, 0 }, .dims = 1, .idx = .{ rl.idx, 0 } };
            encodeOperand(o, r);
        }
    }
}

pub fn encodeInst(o: *Out, i: *const Inst) void {
    const at = o.n;
    o.put(0);
    if (i.has_offset) {
        const off = i.offset;
        var e: u32 = 1;
        e |= (@as(u32, @as(u4, @bitCast(@as(i4, @truncate(off[0]))))) << 9);
        e |= (@as(u32, @as(u4, @bitCast(@as(i4, @truncate(off[1]))))) << 13);
        e |= (@as(u32, @as(u4, @bitCast(@as(i4, @truncate(off[2]))))) << 17);
        if (i.res_dim != 0) e |= 0x8000_0000;
        o.put(e);
    }
    if (i.res_dim != 0) {
        o.put(2 | (@as(u32, i.res_dim) << 6) | 0x8000_0000);
        o.put(3 | (@as(u32, i.res_ret) << 6));
    }
    for (i.ops[0..i.n]) |x| encodeOperand(o, x);
    if (o.over) return;
    const len: u32 = @intCast(o.n - at);
    var tok: u32 = @intFromEnum(i.op);
    tok |= @as(u32, i.ctl) << 11;
    tok |= len << 24;
    if (i.has_offset or i.res_dim != 0) tok |= 0x8000_0000;
    o.buf[at] = tok;
}

test "encoding: dp4 o0.x, r0.xyzw, cb0[0].xyzw (as fxc writes it)" {
    var buf: [32]u32 = undefined;
    var o = Out{ .buf = &buf };
    var i = Inst{ .op = .dp4, .n = 3 };
    i.ops[0] = .{ .reg = .output, .mode = .mask, .mask = 1 };
    i.ops[1] = .{ .reg = .temp };
    i.ops[2] = .{ .reg = .cb, .dims = 2 };
    encodeInst(&o, &i);
    const want = [_]u32{ 0x08000011, 0x00102012, 0, 0x00100e46, 0, 0x00208e46, 0, 0 };
    try std.testing.expectEqualSlices(u32, &want, buf[0..o.n]);
    // mov r0.w, l(1.0)
    o.n = 0;
    var m = Inst{ .op = .mov, .n = 2 };
    m.ops[0] = .{ .reg = .temp, .mode = .mask, .mask = 8 };
    m.ops[1] = .{ .reg = .imm32, .comps = 1, .imm = .{ 0x3f80_0000, 0, 0, 0 } };
    encodeInst(&o, &m);
    try std.testing.expectEqualSlices(u32, &.{ 0x05000036, 0x00100082, 0, 0x00004001, 0x3f80_0000 }, buf[0..o.n]);
}
