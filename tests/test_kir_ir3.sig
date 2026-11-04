//! The Adreno backend against KIR's definition: every op compiled by
//! kir_ir3 and run on the emulated Adreno (adreno_device.Emu: the A7xx
//! command stream into ir3_emu, the GPU's memory apart from the CPU's)
//! gives the bits kir_interp gives under the same Caps. Then KIR rewrites
//! of lfm3_gpu_kernels' Q4_K matrix, RMSNorm and attention kernels give the
//! hand-written kernels' results, and their instruction counts are compared.

const std = @import("std");
const gpu = @import("gpu");
const adreno = @import("adreno");
const kir = gpu.kir;
const interp = gpu.interp;
const kir_ir3 = gpu.kir_ir3;
const adreno_device = gpu.adreno_device;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;

// ── The rig ─────────────────────────────────────────────────────────────────

const Rig = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var emu: adreno_device.Emu = undefined;
    var work: kir_ir3.Work = undefined;
    var out: [512 * 1024]u8 align(16) = undefined;
    var insts: [16384]kir.Inst = undefined;
    var tys: [16384]kir.Ty = undefined;
    var interp_mem: [32 << 20]u8 align(64) = undefined;
    var listing: [512 * 1024]u8 = undefined;
};

fn caps() gpu.Caps {
    return adreno_device.x1_45_caps(Rig.arena.len);
}

fn newKernel(name: []const u8, group: [3]u32) kir.Kernel {
    return kir.Kernel.init(.{ .insts = &Rig.insts, .tys = &Rig.tys }, name, group);
}

/// The kernel on the interpreter, buffers in place.
fn runInterp(k: *kir.Kernel, groups: [3]u32, bufs: []const []u8, params: []const u32) !interp.Stats {
    var w = gpu.Work.init(&Rig.interp_mem);
    var trap: interp.Trap = .{};
    return interp.runKernel(k, caps(), groups, bufs, params, &w, &trap) catch |e| {
        std.debug.print("{s}: interpreter trap {s} at pc {d} thread {d} offset {d}\n", .{ k.name, @tagName(trap.what), trap.pc, trap.thread, trap.offset });
        return e;
    };
}

var emu_ready = false;

fn emuDevice() gpu.Device {
    if (!emu_ready) {
        Rig.emu.init(&Rig.arena, &Rig.view);
        emu_ready = true;
    }
    return Rig.emu.device();
}

const EmuRun = struct { stats: kir_ir3.Stats, ir3: adreno.ir3_emu.Stats };

/// The kernel on the emulated Adreno: buffers copied in, run, copied back.
fn runEmu(k: *kir.Kernel, groups: [3]u32, bufs: []const []u8, params: []const u32) !EmuRun {
    // (a fresh device per run: buffers do not pile up)
    Rig.emu.init(&Rig.arena, &Rig.view);
    emu_ready = true;
    const d = Rig.emu.device();
    const bin = kir_ir3.compileWith(k, d.caps, &Rig.work, &Rig.out) catch |e| {
        std.debug.print("{s}: compile: {s}\n{s}\n", .{ k.name, @errorName(e), kir_ir3.source(&Rig.work) });
        return e;
    };
    const stats = Rig.work.stats;
    const p = try d.load(&bin);
    var gb: [16]gpu.Buffer = undefined;
    for (bufs, 0..) |b, i| {
        gb[i] = try d.alloc(@max(b.len, 4), .host);
        @memcpy(gb[i].cpu[0..b.len], b);
        d.toDevice(gb[i], 0, b.len);
    }
    const before = Rig.emu.stats();
    const fence = try d.run(&.{.{ .prog = &p, .groups = groups, .buffers = gb[0..bufs.len], .params = params }});
    d.wait(fence, 1_000_000) catch |e| {
        const at = Rig.emu.gpu.emu.err_pc;
        var buf: [160]u8 = undefined;
        const text = adreno.ir3.format(adreno.ir3.A7XX, &Rig.emu.gpu.emu.code[at], &buf) catch "?";
        std.debug.print("{s}: emulated Adreno: {s} at {d}: {s} (fault at 0x{x})\n{s}\n", .{ k.name, if (Rig.emu.lastError()) |x| @errorName(x) else "?", at, text, Rig.emu.fault().va, kir_ir3.listing(&Rig.work, &Rig.listing) });
        return e;
    };
    for (bufs, 0..) |b, i| {
        d.fromDevice(gb[i], 0, b.len);
        @memcpy(b, gb[i].cpu[0..b.len]);
    }
    var after = Rig.emu.stats();
    after.instructions -= before.instructions;
    after.fiber_ops -= before.fiber_ops;
    return .{ .stats = stats, .ir3 = after };
}

// ── Values ──────────────────────────────────────────────────────────────────

const ints = [_]u32{
    0,          1,          2,          3,          7,          31,         32,         33,
    255,        256,        1023,       1024,       0xfffffc00, 65535,      65536,      0x00ffffff,
    0x01000000, 0x7fffffff, 0x80000000, 0xffffffff, 0xfffffffe, 0x12345678, 0x80808080, 0xdeadbeef,
};

fn fb(x: f32) u32 {
    return @bitCast(x);
}

const floats = [_]u32{
    0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x3f000000, 0x3fc00000, 0x40200000, 0xc0200000,
    0x40600000, 0x00000001, 0x80800000, 0x007fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f7fffff,
    0x4b000001, 0x4f000000, 0xcf000001, 0x4f800000, 0x501502f9, 0xd01502f9, 0x3effffff, 0x42fe0000,
};

const N = 512;

const Inputs = struct {
    a: [N]u32,
    b: [N]u32,
    c: [N]u32,
};

fn lcg(s: *u32) u32 {
    s.* = s.* *% 1664525 +% 1013904223;
    return s.*;
}

/// Every pair of the pool in a and b (and c cycling), the rest random.
fn inputs(pool: []const u32, seed0: u32) Inputs {
    var in: Inputs = undefined;
    var seed = seed0;
    const p = pool.len;
    for (0..N) |i| {
        if (i < p * p) {
            in.a[i] = pool[i % p];
            in.b[i] = pool[(i / p) % p];
            in.c[i] = pool[(i * 7 + 3) % p];
        } else {
            in.a[i] = lcg(&seed);
            in.b[i] = lcg(&seed);
            in.c[i] = lcg(&seed);
        }
    }
    return in;
}

fn isNan(x: u32) bool {
    return x & 0x7f800000 == 0x7f800000 and x & 0x007fffff != 0;
}

/// Approximate ops: within `ulps` of the definition's value (NaNs as NaNs).
const Cmp = union(enum) { exact, nan_any, ulps: u32 };

fn same(got: u32, want: u32, how: Cmp) bool {
    if (got == want) return true;
    switch (how) {
        .exact => return false,
        .nan_any => return isNan(got) and isNan(want),
        .ulps => |n| {
            if (isNan(got) and isNan(want)) return true;
            if ((got ^ want) & 0x80000000 != 0) return false;
            const d = if (got > want) got - want else want - got;
            return d <= n;
        },
    }
}

// ── One op, both ways ───────────────────────────────────────────────────────

const Form = enum { rrr, rri, rir };

fn operand(k: *kir.Kernel, ty: kir.Ty, binding: u8, off: kir.V) kir.V {
    if (ty == .pred) {
        const x = k.load(.u32, kir.global(binding, 32), r(off));
        return k.cmp(.u32, .ne, r(x), u(0));
    }
    if (ty == .f16) return k.load(.f16, kir.global(binding, 16), r(off));
    return k.load(ty, kir.global(binding, 32), r(off));
}

fn checkOp(c: OpCaseX) !void {
    const pool: []const u32 = if (c.float_pool) &floats else &ints;
    const in = inputs(pool, 0x51ed + @as(u32, @intFromEnum(c.op)) * 977 + c.aux);
    var outs: [2][N]u32 = undefined;
    for (0..2) |way| {
        var k = newKernel(c.name, .{ 128, 1, 1 });
        const ba = k.binding();
        const bb = k.binding();
        const bc = k.binding();
        const bo = k.binding();
        const t = k.op2(.iadd, .u32, r(k.tid(0)), r(k.op2(.shl, .u32, r(k.gid(0)), u(7))));
        const off = k.op2(.shl, .u32, r(t), u(2));
        const a = operand(&k, c.ta, ba, off);
        var argb: kir.Arg = no;
        var argc: kir.Arg = no;
        if (c.nb > 0) argb = if (c.form == .rri) u(c.imm) else r(operand(&k, c.tb, bb, off));
        if (c.nc > 0) argc = r(operand(&k, c.tc, bc, off));
        var arga: kir.Arg = r(a);
        if (c.form == .rir) {
            arga = u(c.imm);
            argb = r(operand(&k, c.tb, bb, off));
        }
        const d = k.opAux(c.op, c.ty, arga, argb, argc, c.aux);
        var res = d;
        if (c.dst == .pred) res = k.sel(.u32, r(d), u(1), u(0));
        if (c.dst == .f16) {
            k.store(.f16, kir.global(bo, 16), r(off), r(res));
        } else k.store(if (c.dst == .pred) .u32 else c.dst, kir.global(bo, 32), r(off), r(res));
        try k.finish();
        @memset(&outs[way], 0);
        var ca = in.a;
        var cb = in.b;
        var cc = in.c;
        const bufs = [_][]u8{ std.mem.sliceAsBytes(&ca), std.mem.sliceAsBytes(&cb), std.mem.sliceAsBytes(&cc), std.mem.sliceAsBytes(&outs[way]) };
        if (way == 0) _ = try runInterp(&k, .{ N / 128, 1, 1 }, &bufs, &.{}) else _ = try runEmu(&k, .{ N / 128, 1, 1 }, &bufs, &.{});
    }
    var bad: usize = 0;
    for (0..N) |i| {
        const want = if (c.dst == .f16) outs[0][i] & 0xffff else outs[0][i];
        const got = if (c.dst == .f16) outs[1][i] & 0xffff else outs[1][i];
        const ok = if (c.dst == .f16) (got == want or (isNan16(got) and isNan16(want))) else same(got, want, c.how);
        if (!ok) {
            if (bad < 6) std.debug.print("{s}: a={x} b={x} c={x}: ir3 {x}, interp {x}\n", .{ c.name, in.a[i], in.b[i], in.c[i], got, want });
            bad += 1;
        }
    }
    if (bad > 0) {
        std.debug.print("{s}: {d} of {d} differ\n{s}\n", .{ c.name, bad, N, kir_ir3.source(&Rig.work) });
        return error.TestUnexpectedResult;
    }
}

fn isNan16(x: u32) bool {
    return x & 0x7c00 == 0x7c00 and x & 0x3ff != 0;
}

const OpCaseX = struct {
    name: []const u8,
    op: kir.Op,
    ty: kir.Ty,
    ta: kir.Ty,
    tb: kir.Ty = .u32,
    tc: kir.Ty = .u32,
    nb: u8 = 1,
    nc: u8 = 0,
    aux: u32 = 0,
    dst: kir.Ty,
    float_pool: bool = false,
    how: Cmp = .exact,
    imm: u32 = 0,
    form: Form = .rrr,
};

fn int2(name: []const u8, op: kir.Op, ty: kir.Ty) OpCaseX {
    return .{ .name = name, .op = op, .ty = ty, .ta = ty, .tb = ty, .dst = ty };
}

fn flt2(name: []const u8, op: kir.Op) OpCaseX {
    return .{ .name = name, .op = op, .ty = .f32, .ta = .f32, .tb = .f32, .dst = .f32, .float_pool = true, .how = .nan_any };
}

fn flt1(name: []const u8, op: kir.Op, how: Cmp) OpCaseX {
    return .{ .name = name, .op = op, .ty = .f32, .ta = .f32, .nb = 0, .dst = .f32, .float_pool = true, .how = how };
}

fn withImm(c: OpCaseX, imm: u32, form: Form) OpCaseX {
    var x = c;
    x.imm = imm;
    x.form = form;
    return x;
}

test "integer ops: ir3 equals the interpreter, register and immediate operands" {
    const two = [_]OpCaseX{
        int2("iadd", .iadd, .u32),       int2("isub", .isub, .u32),     int2("imul", .imul, .u32),
        int2("imulhi.u32", .imulhi, .u32), int2("imulhi.i32", .imulhi, .i32), int2("imin.u32", .imin, .u32),
        int2("imin.i32", .imin, .i32),   int2("imax.u32", .imax, .u32), int2("imax.i32", .imax, .i32),
        int2("and", .@"and", .u32),      int2("or", .@"or", .u32),      int2("xor", .xor, .u32),
        int2("shl", .shl, .u32),         int2("shr.u32", .shr, .u32),   int2("shr.i32", .shr, .i32),
    };
    for (two) |c| {
        try checkOp(c);
        try checkOp(withImm(c, 5, .rri));
        try checkOp(withImm(c, 0x12345, .rri));
        try checkOp(withImm(c, 0xfffffff0, .rir));
    }
    const one = [_]OpCaseX{
        .{ .name = "ineg", .op = .ineg, .ty = .i32, .ta = .i32, .nb = 0, .dst = .i32 },
        .{ .name = "iabs", .op = .iabs, .ty = .i32, .ta = .i32, .nb = 0, .dst = .i32 },
        .{ .name = "not", .op = .not, .ty = .u32, .ta = .u32, .nb = 0, .dst = .u32 },
        .{ .name = "mov", .op = .mov, .ty = .u32, .ta = .u32, .nb = 0, .dst = .u32 },
    };
    for (one) |c| try checkOp(c);
    const three = [_]OpCaseX{
        .{ .name = "imad", .op = .imad, .ty = .u32, .ta = .u32, .tb = .u32, .tc = .u32, .nc = 1, .dst = .u32 },
        .{ .name = "bfe.u32", .op = .bfe, .ty = .u32, .ta = .u32, .tb = .u32, .tc = .u32, .nc = 1, .dst = .u32 },
        .{ .name = "bfe.i32", .op = .bfe, .ty = .i32, .ta = .i32, .tb = .i32, .tc = .i32, .nc = 1, .dst = .i32 },
        .{ .name = "dot4.s8u8", .op = .dot4, .ty = .i32, .ta = .u32, .tb = .u32, .tc = .i32, .nc = 1, .aux = 0, .dst = .i32 },
        .{ .name = "dot4.s8s8", .op = .dot4, .ty = .i32, .ta = .u32, .tb = .u32, .tc = .i32, .nc = 1, .aux = 1, .dst = .i32 },
        .{ .name = "dot4.u8u8", .op = .dot4, .ty = .u32, .ta = .u32, .tb = .u32, .tc = .u32, .nc = 1, .aux = 2, .dst = .u32 },
    };
    for (three) |c| try checkOp(c);
    // bfe with immediate offset and width (shrm, shr, shl+ashr)
    for ([_][2]u32{ .{ 0, 8 }, .{ 4, 4 }, .{ 8, 8 }, .{ 24, 8 }, .{ 16, 16 }, .{ 0, 32 }, .{ 30, 5 }, .{ 7, 0 }, .{ 33, 3 } }) |bc| {
        for ([_]kir.Ty{ .u32, .i32 }) |ty| {
            var k = newKernel("bfe imm", .{ 128, 1, 1 });
            try bfeImm(&k, ty, bc[0], bc[1]);
        }
    }
    // compares, every condition, both signs
    for (0..6) |cc| {
        for ([_]kir.Ty{ .u32, .i32 }) |ty| {
            try checkOp(.{ .name = "icmp", .op = .icmp, .ty = ty, .ta = ty, .tb = ty, .aux = @intCast(cc), .dst = .pred });
            try checkOp(withImm(.{ .name = "icmp imm", .op = .icmp, .ty = ty, .ta = ty, .tb = ty, .aux = @intCast(cc), .dst = .pred }, 33, .rri));
        }
    }
}

fn bfeImm(k: *kir.Kernel, ty: kir.Ty, off: u32, width: u32) !void {
    const in = inputs(&ints, 77 + off * 31 + width);
    var outs: [2][N]u32 = undefined;
    for (0..2) |way| {
        k.* = newKernel("bfe imm", .{ 128, 1, 1 });
        const ba = k.binding();
        const bo = k.binding();
        const t = k.op2(.iadd, .u32, r(k.tid(0)), r(k.op2(.shl, .u32, r(k.gid(0)), u(7))));
        const o = k.op2(.shl, .u32, r(t), u(2));
        const a = k.load(ty, kir.global(ba, 32), r(o));
        const d = k.op3(.bfe, ty, r(a), u(off), u(width));
        k.store(ty, kir.global(bo, 32), r(o), r(d));
        try k.finish();
        var ca = in.a;
        @memset(&outs[way], 0);
        const bufs = [_][]u8{ std.mem.sliceAsBytes(&ca), std.mem.sliceAsBytes(&outs[way]) };
        if (way == 0) _ = try runInterp(k, .{ N / 128, 1, 1 }, &bufs, &.{}) else _ = try runEmu(k, .{ N / 128, 1, 1 }, &bufs, &.{});
    }
    for (0..N) |i| if (outs[0][i] != outs[1][i]) {
        std.debug.print("bfe {s} off {d} width {d}: a={x}: ir3 {x}, interp {x}\n{s}\n", .{ @tagName(ty), off, width, in.a[i], outs[1][i], outs[0][i], kir_ir3.source(&Rig.work) });
        return error.TestUnexpectedResult;
    };
}

test "float ops: ir3 equals the interpreter (NaNs as NaNs; the SFU within its bounds)" {
    const two = [_]OpCaseX{ flt2("fadd", .fadd), flt2("fsub", .fsub), flt2("fmul", .fmul), flt2("fmin", .fmin), flt2("fmax", .fmax) };
    for (two) |c| {
        try checkOp(c);
        try checkOp(withImm(c, fb(1.0), .rri));
        try checkOp(withImm(c, fb(1.5), .rri));
        try checkOp(withImm(c, fb(-2.0), .rir));
    }
    try checkOp(.{ .name = "fmad", .op = .fmad, .ty = .f32, .ta = .f32, .tb = .f32, .tc = .f32, .nc = 1, .dst = .f32, .float_pool = true, .how = .nan_any });
    const one = [_]OpCaseX{
        flt1("fabs", .fabs, .exact),     flt1("fneg", .fneg, .exact),     flt1("ffloor", .ffloor, .nan_any),
        flt1("fceil", .fceil, .nan_any), flt1("ftrunc", .ftrunc, .nan_any), flt1("frne", .frne, .nan_any),
        flt1("frcp", .frcp, .{ .ulps = 1 }), flt1("frsq", .frsq, .{ .ulps = 2 }), flt1("fexp2", .fexp2, .{ .ulps = 2 }),
        flt1("flog2", .flog2, .{ .ulps = 2 }), flt1("fsin", .fsin, .{ .ulps = 4 }), flt1("fcos", .fcos, .{ .ulps = 4 }),
    };
    for (one) |c| try checkOp(c);
    for (0..6) |cc| try checkOp(.{ .name = "fcmp", .op = .fcmp, .ty = .f32, .ta = .f32, .tb = .f32, .aux = @intCast(cc), .dst = .pred, .float_pool = true });
}

test "selects, predicates and conversions" {
    try checkOp(.{ .name = "sel.u32", .op = .sel, .ty = .u32, .ta = .u32, .tb = .u32, .tc = .pred, .nc = 1, .dst = .u32 });
    try checkOp(.{ .name = "sel.f32", .op = .sel, .ty = .f32, .ta = .f32, .tb = .f32, .tc = .pred, .nc = 1, .dst = .f32, .float_pool = true });
    try checkOp(.{ .name = "sel.f16", .op = .sel, .ty = .f16, .ta = .f16, .tb = .f16, .tc = .pred, .nc = 1, .dst = .f16, .float_pool = true });
    try checkOp(.{ .name = "pand", .op = .pand, .ty = .pred, .ta = .pred, .tb = .pred, .dst = .pred });
    try checkOp(.{ .name = "por", .op = .por, .ty = .pred, .ta = .pred, .tb = .pred, .dst = .pred });
    try checkOp(.{ .name = "pnot", .op = .pnot, .ty = .pred, .ta = .pred, .nb = 0, .dst = .pred });
    const C = kir.Cvt;
    const cvts = [_]struct { c: C, pool: bool }{
        .{ .c = .{ .from = .f32, .to = .i32, .round = .rz }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .i32, .round = .rne }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .i32, .round = .rd }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .i32, .round = .ru }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .u32, .round = .rz }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .u32, .round = .rne }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .u32, .round = .rd }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .u32, .round = .ru }, .pool = true },
        .{ .c = .{ .from = .i32, .to = .f32, .round = .rne }, .pool = false },
        .{ .c = .{ .from = .u32, .to = .f32, .round = .rne }, .pool = false },
        .{ .c = .{ .from = .f32, .to = .f16, .round = .rne }, .pool = true },
        .{ .c = .{ .from = .f32, .to = .f16, .round = .rz }, .pool = true },
        .{ .c = .{ .from = .f16, .to = .f32, .round = .rne }, .pool = false },
        .{ .c = .{ .from = .i32, .to = .u32, .round = .rne }, .pool = false },
    };
    for ([_]bool{ true, false }) |trust| {
        kir_ir3.trust_cov_saturation = trust;
        defer kir_ir3.trust_cov_saturation = true;
        for (cvts) |x| {
            try checkOp(.{ .name = "cvt", .op = .cvt, .ty = x.c.to, .ta = x.c.from, .nb = 0, .aux = @bitCast(x.c), .dst = x.c.to, .float_pool = x.pool, .how = .nan_any });
        }
    }
    // moves between f16 and 32-bit registers
    try checkOp(.{ .name = "mov f16 <- u32", .op = .mov, .ty = .f16, .ta = .u32, .nb = 0, .dst = .f16 });
    try checkOp(.{ .name = "mov f32 <- u32", .op = .mov, .ty = .f32, .ta = .u32, .nb = 0, .dst = .f32 });
}

// ── Whole kernels, both ways ────────────────────────────────────────────────

const Bufs = struct {
    var a: [6][64 * 1024]u8 align(16) = undefined;
    var b: [6][64 * 1024]u8 align(16) = undefined;
};

/// Run `k` on the interpreter and on the emulated Adreno from the same
/// initial buffers; every byte of every buffer must come out the same.
fn both(k: *kir.Kernel, groups: [3]u32, init: []const []const u8, params: []const u32) !EmuRun {
    try k.finish();
    var sa: [6][]u8 = undefined;
    var sb: [6][]u8 = undefined;
    for (init, 0..) |x, i| {
        sa[i] = Bufs.a[i][0..x.len];
        sb[i] = Bufs.b[i][0..x.len];
        @memcpy(sa[i], x);
        @memcpy(sb[i], x);
    }
    _ = try runInterp(k, groups, sa[0..init.len], params);
    const run = try runEmu(k, groups, sb[0..init.len], params);
    for (0..init.len) |i| {
        if (!sameBuffers(sa[i], sb[i])) {
            const wa: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, sa[i][0 .. sa[i].len & ~@as(usize, 3)]));
            const wb: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, sb[i][0 .. sb[i].len & ~@as(usize, 3)]));
            var shown: usize = 0;
            for (wa, wb, 0..) |x, y, j| if (x != y and !(isNan(x) and isNan(y)) and shown < 8) {
                std.debug.print("{s}: buffer {d} word {d}: ir3 {x}, interp {x}\n", .{ k.name, i, j, y, x });
                shown += 1;
            };
            std.debug.print("{s}\n", .{kir_ir3.source(&Rig.work)});
            return error.TestUnexpectedResult;
        }
    }
    return run;
}

/// Byte for byte, except that two f32 NaNs (whatever their bits) match:
/// KIR's NaN is 0x7fffffff, a GPU's any NaN.
fn sameBuffers(x: []const u8, y: []const u8) bool {
    if (std.mem.eql(u8, x, y)) return true;
    if (x.len != y.len) return false;
    var i: usize = 0;
    while (i + 4 <= x.len) : (i += 4) {
        const a = std.mem.readInt(u32, x[i..][0..4], .little);
        const b = std.mem.readInt(u32, y[i..][0..4], .little);
        if (a != b and !(isNan(a) and isNan(b))) return false;
    }
    return std.mem.eql(u8, x[i..], y[i..]);
}

fn zeros(comptime n: usize) [n]u8 {
    return [_]u8{0} ** n;
}

test "ids, sizes, lanes and parameters in 1-, 2- and 3-dimensional groups" {
    for ([_][3]u32{ .{ 64, 1, 1 }, .{ 128, 1, 1 }, .{ 8, 4, 2 }, .{ 16, 8, 1 }, .{ 30, 3, 1 } }) |g| {
        var k = newKernel("ids", g);
        const out = k.binding();
        const tx = k.tid(0);
        const ty = k.tid(1);
        const tz = k.tid(2);
        // the thread's linear index in the dispatch
        const lin = k.op3(.imad, .u32, r(k.op3(.imad, .u32, r(tz), u(g[1]), r(ty))), u(g[0]), r(tx));
        const gx = k.gid(0);
        const gy = k.gid(1);
        const gz = k.gid(2);
        const gl = k.op3(.imad, .u32, r(k.op3(.imad, .u32, r(gz), r(k.gsize(1)), r(gy))), r(k.gsize(0)), r(gx));
        const threads = g[0] * g[1] * g[2];
        const slot = k.op3(.imad, .u32, r(gl), u(threads), r(lin));
        const base = k.op2(.shl, .u32, r(slot), u(5));
        const p0 = k.param(.u32, 0);
        const p1 = k.param(.f32, 1);
        const vals = [_]kir.V{ tx, ty, tz, gx, gy, gz, k.lane(), k.subgroupWidth() };
        for (vals, 0..) |v, i| {
            _ = i;
            _ = v;
        }
        const packed_t = k.op2(.@"or", .u32, r(tx), r(k.op2(.shl, .u32, r(ty), u(10))));
        const packed_t2 = k.op2(.@"or", .u32, r(packed_t), r(k.op2(.shl, .u32, r(tz), u(20))));
        const packed_g = k.op2(.@"or", .u32, r(gx), r(k.op2(.shl, .u32, r(gy), u(10))));
        const packed_g2 = k.op2(.@"or", .u32, r(packed_g), r(k.op2(.shl, .u32, r(gz), u(20))));
        const sizes = k.op2(.@"or", .u32, r(k.gsize(0)), r(k.op2(.shl, .u32, r(k.op2(.iadd, .u32, r(k.gsize(1)), r(k.op2(.shl, .u32, r(k.gsize(2)), u(8))))), u(8))));
        const v = k.vec(.u32, 4);
        k.set(kir.Kernel.at(v, 0), .mov, r(packed_t2), no, no);
        k.set(kir.Kernel.at(v, 1), .mov, r(packed_g2), no, no);
        k.set(kir.Kernel.at(v, 2), .mov, r(sizes), no, no);
        k.set(kir.Kernel.at(v, 3), .iadd, r(k.op2(.shl, .u32, r(k.lane()), u(16))), r(k.subgroupWidth()), no);
        k.store(.u32, kir.global(out, 128), r(base), r(v));
        const w2 = k.vec(.u32, 4);
        k.set(kir.Kernel.at(w2, 0), .mov, r(p0), no, no);
        k.set(kir.Kernel.at(w2, 1), .mov, r(p1), no, no);
        k.set(kir.Kernel.at(w2, 2), .mov, r(lin), no, no);
        k.set(kir.Kernel.at(w2, 3), .mov, r(slot), no, no);
        var m = kir.global(out, 128);
        m.imm = 16;
        k.store(.u32, m, r(base), r(w2));
        const groups = [3]u32{ 3, 2, 2 };
        var buf = zeros(12 * 128 * 32);
        _ = try both(&k, groups, &.{&buf}, &.{ 0xabcdef12, fb(2.5) });
    }
}

test "loads and stores: 8, 16, 32, 64 and 128 bits, signed and unsigned, f16, large offsets, shared memory" {
    var k = newKernel("memory", .{ 64, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const t = k.tid(0);
    const t4 = k.op2(.shl, .u32, r(t), u(2));
    const t16 = k.op2(.shl, .u32, r(t), u(4));
    const t1 = t;
    const t2 = k.op2(.shl, .u32, r(t), u(1));
    var m8 = kir.global(src, 8);
    const b8 = k.load(.u32, m8, r(t1));
    m8.signed = true;
    const s8 = k.load(.i32, m8, r(t1));
    var m16 = kir.global(src, 16);
    m16.imm = 512;
    const b16 = k.load(.u32, m16, r(t2));
    m16.signed = true;
    const s16 = k.load(.i32, m16, r(t2));
    m16.signed = false;
    const h16 = k.load(.f16, m16, r(t2));
    const hf = k.cvt(.f16, .f32, .rne, r(h16));
    var m32 = kir.global(src, 32);
    m32.imm = 1024 + 4;
    const w32 = k.load(.u32, m32, r(t4));
    var m64 = kir.global(src, 64);
    m64.imm = 2048;
    const w64 = k.load(.u32, m64, r(k.op2(.shl, .u32, r(t), u(3))));
    var m128 = kir.global(src, 128);
    m128.imm = 8192;
    const w128 = k.load(.u32, m128, r(t16));
    // a large immediate offset (past the 8-bit field)
    var mbig = kir.global(src, 32);
    mbig.imm = 20000;
    const wbig = k.load(.u32, mbig, r(t4));
    // shared: each thread writes its word, the group reads its neighbour's
    const sh = k.sharedAlloc(64 * 4 + 64 * 8, 16);
    var ms = kir.shared(32);
    ms.imm = @intCast(sh);
    k.store(.u32, ms, r(t4), r(w32));
    // (narrow shared stores one per word: two threads in one word race)
    var ms16 = kir.shared(16);
    ms16.imm = @intCast(sh + 256);
    k.store(.f16, ms16, r(t4), r(h16));
    var ms8 = kir.shared(8);
    ms8.imm = @intCast(sh + 256 + 2);
    k.store(.u32, ms8, r(t4), r(b8));
    k.barrier();
    const nb = k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(t), u(1))), u(63));
    const nb4 = k.op2(.shl, .u32, r(nb), u(2));
    const s_w = k.load(.u32, ms, r(nb4));
    const s_h = k.load(.f16, ms16, r(nb4));
    const s_b = k.load(.u32, ms8, r(nb4));
    // out: 16 words per thread
    const o = k.op2(.shl, .u32, r(t), u(6));
    const vals = [_]kir.V{ b8, s8, b16, s16, w32, kir.Kernel.at(w64, 0), kir.Kernel.at(w64, 1), kir.Kernel.at(w128, 0), kir.Kernel.at(w128, 3), wbig, s_w, s_b };
    for (vals, 0..) |v, i| {
        var mo = kir.global(dst, 32);
        mo.imm = @intCast(4 * i);
        k.store(.u32, mo, r(o), r(v));
    }
    var mf = kir.global(dst, 32);
    mf.imm = 48;
    k.store(.f32, mf, r(o), r(hf));
    var mh = kir.global(dst, 16);
    mh.imm = 52;
    k.store(.f16, mh, r(o), r(s_h));
    // narrow stores of 32-bit values
    var mn8 = kir.global(dst, 8);
    mn8.imm = 56;
    k.store(.u32, mn8, r(o), r(w32));
    var mn16 = kir.global(dst, 16);
    mn16.imm = 58;
    k.store(.u32, mn16, r(o), r(w32));
    var mv = kir.global(dst, 64);
    mv.imm = 2048 + 64 * 64;
    k.store(.u32, mv, r(k.op2(.shl, .u32, r(t), u(3))), r(w64));
    var input = zeros(24 * 1024);
    var seed: u32 = 99;
    for (&input) |*x| x.* = @truncate(lcg(&seed) >> 13);
    var output = zeros(64 * 64 + 1024 + 64 * 8 + 2048);
    _ = try both(&k, .{ 1, 1, 1 }, &.{ &input, &output }, &.{});
}

test "atomics, global and shared, contended" {
    for ([_]kir.Atom{ .add, .min, .max, .xchg }) |kind| {
        for ([_]kir.Ty{ .u32, .i32 }) |ty| {
            var k = newKernel("atomics", .{ 64, 1, 1 });
            const g = k.binding();
            const o = k.binding();
            const t = k.tid(0);
            const gid = k.gid(0);
            const val = k.op2(.xor, ty, r(k.op2(.imul, ty, r(t), u(0x9e3779b9))), r(gid));
            // 4 words: threads t % 4
            const slot = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(t), u(3))), u(2));
            const old = k.atomic(ty, kind, kir.global(g, 32), r(slot), r(val));
            // shared: one word per group, started at the group id
            const sh = k.sharedAlloc(16, 4);
            var ms = kir.shared(32);
            ms.imm = @intCast(sh);
            const first = k.cmp(.u32, .eq, r(t), u(0));
            k.ifp(r(first));
            k.store(.u32, ms, u(0), r(gid));
            k.endif();
            k.barrier();
            const sold = k.atomic(ty, kind, ms, u(0), r(val));
            k.barrier();
            const final = k.load(.u32, ms, u(0));
            const gl = k.op2(.iadd, .u32, r(t), r(k.op2(.shl, .u32, r(gid), u(6))));
            const ob = k.op2(.shl, .u32, r(gl), u(4));
            const v = k.vec(.u32, 4);
            k.set(kir.Kernel.at(v, 0), .mov, r(old), no, no);
            k.set(kir.Kernel.at(v, 1), .mov, r(sold), no, no);
            k.set(kir.Kernel.at(v, 2), .mov, r(final), no, no);
            k.set(kir.Kernel.at(v, 3), .mov, r(val), no, no);
            k.store(.u32, kir.global(o, 128), r(ob), r(v));
            var words = zeros(16);
            std.mem.writeInt(u32, words[0..4], 0x80000000, .little);
            std.mem.writeInt(u32, words[4..8], 5, .little);
            var out = zeros(3 * 64 * 16);
            _ = try both(&k, .{ 3, 1, 1 }, &.{ &words, &out }, &.{});
        }
    }
}

test "shuffles: idx, xor, up, down; immediate, uniform and per-lane operands" {
    for ([_]kir.Shfl{ .idx, .xor, .up, .down }) |mode| {
        for (0..4) |form| {
            var k = newKernel("shfl", .{ 128, 1, 1 });
            const o = k.binding();
            const t = k.tid(0);
            const x = k.op2(.iadd, .u32, r(k.op2(.imul, .u32, r(t), u(1000))), u(7));
            const b: kir.Arg = switch (form) {
                0 => u(5),
                1 => u(70), // past the subgroup: masked (idx, xor) or out of range
                2 => r(k.op2(.iadd, .u32, r(k.param(.u32, 0)), u(1))), // uniform
                else => r(k.op2(.@"and", .u32, r(k.op2(.imul, .u32, r(t), u(7))), u(63))), // per lane
            };
            const y = k.shfl(.u32, mode, r(x), b);
            const fx = k.cvt(.u32, .f32, .rne, r(x));
            const fy = k.shfl(.f32, mode, r(fx), b);
            const ob = k.op2(.shl, .u32, r(t), u(3));
            k.store(.u32, kir.global(o, 32), r(ob), r(y));
            var m = kir.global(o, 32);
            m.imm = 4;
            k.store(.f32, m, r(ob), r(fy));
            var out = zeros(128 * 8);
            _ = try both(&k, .{ 1, 1, 1 }, &.{&out}, &.{3});
        }
    }
}

test "votes and divergent control flow: nested ifs, loops with brk and cont, ret" {
    var k = newKernel("flow", .{ 128, 1, 1 });
    const o = k.binding();
    const t = k.tid(0);
    const acc = k.mov(.u32, u(0));
    const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(t), u(1))), u(0));
    const any_big = k.vote(.any, r(k.cmp(.u32, .gt, r(t), u(100))));
    const all_small = k.vote(.all, r(k.cmp(.u32, .lt, r(t), u(64))));
    k.ifp(r(odd));
    {
        k.set(acc, .iadd, r(acc), u(1), no);
        const third = k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(t), u(3))), u(3));
        k.ifp(r(third));
        k.set(acc, .iadd, r(acc), u(100), no);
        k.els();
        k.set(acc, .iadd, r(acc), u(1000), no);
        // a vote under divergence: only the active lanes count
        const v = k.vote(.all, r(k.cmp(.u32, .lt, r(t), u(200))));
        k.set(acc, .iadd, r(acc), r(k.sel(.u32, r(v), u(10000), u(0))), no);
        k.endif();
    }
    k.els();
    k.set(acc, .iadd, r(acc), u(7), no);
    k.endif();
    // a loop: i from 0; cont on multiples of 3; brk when i > t % 13
    const i = k.mov(.u32, u(0));
    const lim = k.op2(.iadd, .u32, r(k.op2(.@"and", .u32, r(t), u(15))), u(1));
    k.loop();
    {
        k.set(i, .iadd, r(i), u(1), no);
        k.brk(r(k.cmp(.u32, .gt, r(i), r(lim))));
        k.cont(r(k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(i), u(3))), u(0))));
        k.set(acc, .imad, r(acc), u(3), r(i));
        // a nested loop with its own brk
        const j = k.mov(.u32, u(0));
        k.loop();
        k.set(j, .iadd, r(j), u(1), no);
        k.set(acc, .iadd, r(acc), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(j), r(k.op2(.@"and", .u32, r(i), u(1))))));
        k.endloop();
    }
    k.endloop();
    const ob = k.op2(.shl, .u32, r(t), u(4));
    const v = k.vec(.u32, 4);
    k.set(kir.Kernel.at(v, 0), .mov, r(acc), no, no);
    k.set(kir.Kernel.at(v, 1), .sel, u(1), u(0), r(any_big));
    k.set(kir.Kernel.at(v, 2), .sel, u(1), u(0), r(all_small));
    k.set(kir.Kernel.at(v, 3), .mov, r(i), no, no);
    k.store(.u32, kir.global(o, 128), r(ob), r(v));
    // ret: lanes past 100 leave before their second store
    k.ifp(r(k.cmp(.u32, .gt, r(t), u(100))));
    k.ret();
    k.endif();
    var m = kir.global(o, 32);
    m.imm = 128 * 16;
    k.store(.u32, m, r(k.op2(.shl, .u32, r(t), u(2))), r(acc));
    var out = zeros(128 * 16 + 128 * 4);
    _ = try both(&k, .{ 2, 1, 1 }, &.{&out}, &.{});
}
