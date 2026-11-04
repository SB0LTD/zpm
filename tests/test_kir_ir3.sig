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

/// Kernels checked against ir3's operand rules (adreno.device.checkWords).
var checked_kernels: u32 = 0;

/// What kir_ir3 made must obey every operand rule the strict emulated
/// Adreno enforces (const/shared sources per category, immediates, the
/// constants and registers the kernel declares).
fn checkBinary(name: []const u8, bin: *const gpu.Binary) !void {
    const cfg = kir_ir3.Config.fromExtra(bin.extra) orelse return error.TestUnexpectedResult;
    const code: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, bin.code[0..cfg.code_bytes]));
    if (adreno.device.checkWords(cfg.gen, code[0..cfg.count], cfg.constlen, cfg.full_regs)) |bad| {
        var buf: [160]u8 = undefined;
        const in = adreno.ir3.decode(cfg.gen, code[bad.pc]) catch adreno.ir3.Instr{};
        const text = adreno.ir3.format(cfg.gen, &in, &buf) catch "?";
        std.debug.print("{s}: instruction {d} ({s}) breaks an operand rule: {s}\n{s}\n", .{ name, bad.pc, text, bad.rule, kir_ir3.listing(&Rig.work, &Rig.listing) });
        return error.TestUnexpectedResult;
    }
    checked_kernels += 1;
}

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
    try checkBinary(k.name, &bin);
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
        std.debug.print("{s}: emulated Adreno: {s} at {d}: {s} (fault at 0x{x}; {s})\n{s}\n", .{ k.name, if (Rig.emu.lastError()) |x| @errorName(x) else "?", at, text, Rig.emu.fault().va, Rig.emu.gpu.fault.rule, kir_ir3.listing(&Rig.work, &Rig.listing) });
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
        // (past cat2's -511..511, inside the 11-bit field)
        try checkOp(withImm(c, 700, .rri));
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

test "exact fdiv and fsqrt (kir's mul/add-only expansions) equal the interpreter" {
    try checkOp(flt2("fdiv", .fdiv));
    try checkOp(withImm(flt2("fdiv imm", .fdiv), fb(3.0), .rri));
    try checkOp(withImm(flt2("fdiv imm", .fdiv), fb(-0.75), .rir));
    try checkOp(flt1("fsqrt", .fsqrt, .nan_any));
    // random operands, many more of them
    var seed: u32 = 1234;
    for (0..8) |round| {
        var k = newKernel("fdiv random", .{ 128, 1, 1 });
        const ba = k.binding();
        const bb = k.binding();
        const bo = k.binding();
        const t = k.op2(.iadd, .u32, r(k.tid(0)), r(k.op2(.shl, .u32, r(k.gid(0)), u(7))));
        const off = k.op2(.shl, .u32, r(t), u(3));
        const a = k.load(.f32, kir.global(ba, 32), r(off));
        const b = k.load(.f32, kir.global(bb, 32), r(off));
        const q = k.div(r(a), r(b));
        const s = k.sqrt(r(a));
        k.store(.f32, kir.global(bo, 32), r(off), r(q));
        var m = kir.global(bo, 32);
        m.imm = 4;
        k.store(.f32, m, r(off), r(s));
        var av = zeros(4096 * 8);
        var bv = zeros(4096 * 8);
        for (0..4096 * 2) |i| {
            // magnitudes over the whole range, denormals included
            const ea = (lcg(&seed) >> 24) & 0xff;
            const eb = if (round % 2 == 0) (lcg(&seed) >> 24) & 0xff else 100 + ((lcg(&seed) >> 24) & 63);
            std.mem.writeInt(u32, av[i * 4 ..][0..4], (lcg(&seed) & 0x807fffff) | (ea << 23), .little);
            std.mem.writeInt(u32, bv[i * 4 ..][0..4], (lcg(&seed) & 0x807fffff) | (eb << 23), .little);
        }
        var out = zeros(4096 * 8);
        _ = try both(&k, .{ 32, 1, 1 }, &.{ &av, &bv, &out }, &.{});
    }
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

test "loop-carried registers with one definition, read at the top of the next turn" {
    // (gfx_kir's tile loop kept its clip predicate this way: written once
    // per turn, read by the next turn before that write; a register with
    // one definition is not SSA when a read comes first)
    var k = newKernel("carried", .{ 64, 1, 1 });
    const o = k.binding();
    const t = k.tid(0);
    const acc = k.mov(.u32, u(0));
    const prev_p = k.reg(.pred);
    const prev_v = k.reg(.u32);
    const i = k.mov(.u32, u(0));
    k.loop();
    {
        // the tail of the previous turn (garbage-free: i > 0 guards it)
        const later = k.cmp(.u32, .ne, r(i), u(0));
        k.ifp(r(later));
        k.set(acc, .iadd, r(acc), r(k.sel(.u32, r(prev_p), r(prev_v), u(1000))), no);
        k.endif();
        // much in between, so the registers would be reused
        var x = k.op2(.imul, .u32, r(t), r(i));
        for (0..12) |n| x = k.op2(.xor, .u32, r(k.op2(.iadd, .u32, r(x), u(@intCast(n * 7 + 1)))), r(k.op2(.shl, .u32, r(x), u(3))));
        // this turn's, for the next
        k.setAux(prev_p, .icmp, r(k.op2(.@"and", .u32, r(x), u(1))), u(0), no, @intFromEnum(kir.Cmp.eq));
        k.set(prev_v, .mov, r(x), no, no);
        // fresh values after the writes, which a short live range would let
        // take their registers
        var y = k.op2(.imul, .u32, r(t), u(77));
        for (0..8) |n| y = k.op2(.iadd, .u32, r(k.op2(.xor, .u32, r(y), r(i))), u(@intCast(n + 3)));
        k.set(acc, .iadd, r(acc), r(k.op2(.@"and", .u32, r(y), u(15))), no);
        k.set(i, .iadd, r(i), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(i), u(9))));
    }
    k.endloop();
    k.store(.u32, kir.global(o, 32), r(k.op2(.shl, .u32, r(t), u(2))), r(acc));
    var out = zeros(64 * 4);
    _ = try both(&k, .{ 2, 1, 1 }, &.{&out}, &.{});
}

test "a predicate live across a loop's back edge, made before the loop and in it" {
    // (G: the fill's edge coverage came out 0)
    for (0..2) |variant| {
        var k = newKernel("pred round the loop", .{ 64, 1, 1 });
        const o = k.binding();
        const t = k.tid(0);
        // made before the loop (variant 0) or only in it (variant 1)
        const p = if (variant == 0) k.cmp(.u32, .lt, r(t), u(24)) else k.reg(.pred);
        const acc = k.mov(.u32, u(0));
        const i = k.mov(.u32, u(0));
        k.loop();
        {
            if (variant == 1) {
                // the first turn reads what the last write left: guard it
                k.ifp(r(k.cmp(.u32, .ne, r(i), u(0))));
            }
            k.set(acc, .iadd, r(acc), r(k.sel(.u32, r(p), u(1), u(100))), no);
            if (variant == 1) k.endif();
            var x = k.op2(.imul, .u32, r(t), r(k.op2(.iadd, .u32, r(i), u(3))));
            for (0..10) |n| x = k.op2(.xor, .u32, r(k.op2(.iadd, .u32, r(x), u(@intCast(n * 13 + 5)))), r(k.op2(.shr, .u32, r(x), u(2))));
            k.setAux(p, .icmp, r(k.op2(.@"and", .u32, r(x), u(3))), u(1), no, @intFromEnum(kir.Cmp.lt));
            var y = k.op2(.imul, .u32, r(x), u(5));
            for (0..6) |n| y = k.op2(.iadd, .u32, r(k.op2(.xor, .u32, r(y), r(t))), u(@intCast(n + 1)));
            k.set(acc, .iadd, r(acc), r(k.op2(.@"and", .u32, r(y), u(7))), no);
            k.set(i, .iadd, r(i), u(1), no);
            k.brk(r(k.cmp(.u32, .ge, r(i), u(6))));
        }
        k.endloop();
        k.store(.u32, kir.global(o, 32), r(k.op2(.shl, .u32, r(t), u(2))), r(acc));
        var out = zeros(128 * 4);
        _ = try both(&k, .{ 2, 1, 1 }, &.{&out}, &.{});
    }
}

test "a loop counter written twice in the body and read at the top: every turn of the outer loop runs" {
    // (G: a thread's second turn of an outer loop round the command loop
    // never ran)
    var k = newKernel("counter written twice", .{ 64, 1, 1 });
    const o = k.binding();
    const t = k.tid(0);
    const c = k.mov(.u32, u(0));
    const turns = k.mov(.u32, u(0));
    const acc = k.mov(.u32, u(0));
    const lim = k.op2(.iadd, .u32, r(k.op2(.@"and", .u32, r(t), u(3))), u(2));
    k.loop();
    {
        // read at the top
        const x = k.op2(.imul, .u32, r(c), u(3));
        k.set(turns, .iadd, r(turns), u(1), no);
        // an inner loop
        const j = k.mov(.u32, u(0));
        k.loop();
        k.set(acc, .iadd, r(acc), r(k.op2(.iadd, .u32, r(x), r(j))), no);
        k.set(j, .iadd, r(j), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(j), u(3))));
        k.endloop();
        // the counter, written twice
        k.set(c, .iadd, r(c), u(1), no);
        var y = k.op2(.imul, .u32, r(t), r(c));
        for (0..6) |n| y = k.op2(.xor, .u32, r(k.op2(.iadd, .u32, r(y), u(@intCast(n + 7)))), r(acc));
        k.set(acc, .iadd, r(acc), r(k.op2(.@"and", .u32, r(y), u(1))), no);
        k.set(c, .iadd, r(c), r(k.op2(.@"and", .u32, r(t), u(1))), no);
        k.brk(r(k.cmp(.u32, .ge, r(c), r(lim))));
    }
    k.endloop();
    const ob = k.op2(.shl, .u32, r(t), u(4));
    const v = k.vec(.u32, 4);
    k.set(kir.Kernel.at(v, 0), .mov, r(c), no, no);
    k.set(kir.Kernel.at(v, 1), .mov, r(turns), no, no);
    k.set(kir.Kernel.at(v, 2), .mov, r(acc), no, no);
    k.set(kir.Kernel.at(v, 3), .mov, r(lim), no, no);
    k.store(.u32, kir.global(o, 128), r(ob), r(v));
    var out = zeros(64 * 16);
    _ = try both(&k, .{ 1, 1, 1 }, &.{&out}, &.{});
}

test "a loop counter that is an element of a loaded vector, written twice in the body" {
    // (a vector's registers are allocated together: its first element's
    // single load must not hide another element's loop-carried writes)
    var k = newKernel("vector counter", .{ 64, 1, 1 });
    const src = k.binding();
    const o = k.binding();
    const t = k.tid(0);
    const v = k.load(.u32, kir.global(src, 128), r(k.op2(.shl, .u32, r(t), u(4))));
    const c = kir.Kernel.at(v, 2);
    const acc = k.mov(.u32, u(0));
    k.loop();
    {
        const x = k.op2(.imul, .u32, r(c), u(3));
        var y = k.op2(.iadd, .u32, r(x), r(kir.Kernel.at(v, 0)));
        for (0..8) |n| y = k.op2(.xor, .u32, r(k.op2(.iadd, .u32, r(y), u(@intCast(n + 1)))), r(t));
        k.set(acc, .iadd, r(acc), r(y), no);
        k.set(c, .iadd, r(c), u(1), no);
        var z = k.op2(.imul, .u32, r(acc), u(7));
        for (0..6) |n| z = k.op2(.iadd, .u32, r(k.op2(.shr, .u32, r(z), u(1))), u(@intCast(n)));
        k.set(acc, .xor, r(acc), r(z), no);
        k.set(c, .iadd, r(c), r(k.op2(.@"and", .u32, r(t), u(1))), no);
        k.brk(r(k.cmp(.u32, .ge, r(c), r(kir.Kernel.at(v, 1)))));
    }
    k.endloop();
    const ob = k.op2(.shl, .u32, r(t), u(3));
    k.store(.u32, kir.global(o, 32), r(ob), r(acc));
    var m = kir.global(o, 32);
    m.imm = 4;
    k.store(.u32, m, r(ob), r(c));
    var input = zeros(64 * 16);
    for (0..64) |i| {
        std.mem.writeInt(u32, input[i * 16 ..][0..4], @intCast(i * 5), .little);
        std.mem.writeInt(u32, input[i * 16 + 4 ..][0..4], @intCast(4 + i % 5), .little);
        std.mem.writeInt(u32, input[i * 16 + 8 ..][0..4], @intCast(i % 3), .little);
    }
    var out = zeros(64 * 8);
    _ = try both(&k, .{ 1, 1, 1 }, &.{ &input, &out }, &.{});
}

test "a butterfly over 256 threads, past one wave through shared memory: addresses made before a barrier wait their slots" {
    // (L: norm+quant and the residual with a norm reduce over more than a
    // wave; an exchange's ldl read an address shl'd before stl; fence; bar)
    var k = newKernel("wide butterfly", .{ 256, 1, 1 });
    const src = k.binding();
    const o = k.binding();
    const t = k.tid(0);
    const t4 = k.op2(.shl, .u32, r(t), u(2));
    var acc = k.load(.f32, kir.global(src, 32), r(t4));
    var iacc = k.load(.u32, kir.global(src, 32), r(t4));
    const sh = k.sharedAlloc(256 * 4, 16);
    var ms = kir.shared(32);
    ms.imm = @intCast(sh);
    var m: u32 = 1;
    while (m < 256) : (m *= 2) {
        if (m < 64) {
            acc = k.op2(.fadd, .f32, r(acc), r(k.shfl(.f32, .xor, r(acc), u(m))));
            iacc = k.op2(.iadd, .u32, r(iacc), r(k.shfl(.u32, .xor, r(iacc), u(m))));
            continue;
        }
        // lfm3_kir's xorPartner: the partner's address before the exchange
        for (0..2) |which| {
            const mine = k.op2(.shl, .u32, r(t), u(2));
            const theirs = k.op2(.shl, .u32, r(k.op2(.xor, .u32, r(t), u(m))), u(2));
            const ty: kir.Ty = if (which == 0) .f32 else .u32;
            k.store(ty, ms, r(mine), r(if (which == 0) acc else iacc));
            k.barrier();
            const x = k.load(ty, ms, r(theirs));
            k.barrier();
            if (which == 0) acc = k.op2(.fadd, .f32, r(acc), r(x)) else iacc = k.op2(.iadd, .u32, r(iacc), r(x));
        }
    }
    k.store(.f32, kir.global(o, 32), r(k.op2(.shl, .u32, r(t), u(3))), r(acc));
    var mo = kir.global(o, 32);
    mo.imm = 4;
    k.store(.u32, mo, r(k.op2(.shl, .u32, r(t), u(3))), r(iacc));
    var input = zeros(512 * 4);
    var seed: u32 = 99;
    for (0..512) |i| {
        const x = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 8.0;
        std.mem.writeInt(u32, input[i * 4 ..][0..4], @bitCast(x), .little);
    }
    var out = zeros(512 * 8);
    _ = try both(&k, .{ 2, 1, 1 }, &.{ &input, &out }, &.{});
}

// ── The hand-written kernels, rewritten in KIR ──────────────────────────────

const hand = @import("lfm3_gpu_kernels");
const ir3 = adreno.ir3;
const ir3_asm = adreno.ir3_asm;
const a7xx = adreno.a7xx;

/// Print the KIR attention kernel's listing (debugging).
const show_listing = false;

const Hand = struct {
    var asm_work: ir3_asm.Work = undefined;
};

/// Counts of a kernel: static (machine instructions, after legalization)
/// and dynamic (instructions the emulator issued, per wave, and registers).
const Counts = struct {
    static: u32,
    legalized: u32,
    issued: u64,
    full_regs: u32,
};

/// A hand-written kernel's source through the raw emulated GPU: buffers
/// (already on the GPU), its constants, a grid. Returns its counts.
fn runHand(src: []const u8, consts: []const u32, extra: ?struct { first: u32, words: []const u32 }, groups: [3]u32) !Counts {
    const raw = Rig.emu.gpu.device();
    const code = try raw.alloc(256 * 1024);
    const ib = try raw.alloc(64 * 1024);
    const k = ir3_asm.assemble(ir3.A7XX, src, &Hand.asm_work, @alignCast(std.mem.bytesAsSlice(u64, code.cpu))) catch |e| {
        std.debug.print("hand kernel: line {d}: {s}\n", .{ Hand.asm_work.err_line, @errorName(e) });
        return e;
    };
    raw.toDevice(code, 0, k.code.len * 8);
    var nops: u32 = 0;
    for (Hand.asm_work.out[0..Hand.asm_work.n_out]) |it| if (it.in.op == .nop) {
        nops += 1;
    };
    var s = a7xx.Stream{ .buf = ib.words() };
    s.computeSetup();
    try s.program(&k, code.va);
    s.constants(0, consts);
    if (extra) |x| s.constants(x.first, x.words);
    s.dispatch(&k, groups);
    s.waitForIdle();
    try s.check();
    const before = Rig.emu.gpu.stats.instructions;
    try raw.run(ib, @intCast(s.len), 1_000_000);
    return .{ .static = k.count - nops, .legalized = k.count, .issued = Rig.emu.gpu.stats.instructions - before, .full_regs = k.full_regs };
}

/// A KIR kernel on the same emulated GPU (its buffers already there).
fn runKir(k: *kir.Kernel, groups: [3]u32, bufs: []const gpu.Buffer, params: []const u32) !Counts {
    try k.finish();
    const d = Rig.emu.device();
    const bin = kir_ir3.compileWith(k, d.caps, &Rig.work, &Rig.out) catch |e| {
        std.debug.print("{s}: compile: {s} {s}\n{s}\n", .{ k.name, @errorName(e), kir_ir3.diagnostic(&Rig.work), kir_ir3.source(&Rig.work) });
        return e;
    };
    const st = Rig.work.stats;
    try checkBinary(k.name, &bin);
    const p = try d.load(&bin);
    const before = Rig.emu.gpu.stats.instructions;
    const fence = try d.run(&.{.{ .prog = &p, .groups = groups, .buffers = bufs, .params = params }});
    d.wait(fence, 1_000_000) catch |e| {
        const at = Rig.emu.gpu.emu.err_pc;
        var buf: [160]u8 = undefined;
        const text = ir3.format(ir3.A7XX, &Rig.emu.gpu.emu.code[at], &buf) catch "?";
        std.debug.print("{s}: emulated Adreno: {s} at {d}: {s}\n{s}\n", .{ k.name, if (Rig.emu.lastError()) |x| @errorName(x) else "?", at, text, kir_ir3.listing(&Rig.work, &Rig.listing) });
        return e;
    };
    return .{ .static = st.instructions, .legalized = st.legalized, .issued = Rig.emu.gpu.stats.instructions - before, .full_regs = st.full_regs };
}

fn report(name: []const u8, h: Counts, q: Counts) void {
    const pct = struct {
        fn f(a: u64, b: u64) f64 {
            return 100.0 * (@as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b))) / @as(f64, @floatFromInt(b));
        }
    }.f;
    std.debug.print("{s}: hand {d} instructions ({d} legalized), {d} issued, {d} vec4 regs | KIR {d} ({d}), {d} issued, {d} regs | static {d:.1}%, legalized {d:.1}%, issued {d:.1}%\n", .{ name, h.static, h.legalized, h.issued, h.full_regs, q.static, q.legalized, q.issued, q.full_regs, pct(q.static, h.static), pct(q.legalized, h.legalized), pct(q.issued, h.issued) });
}

/// The Q4_K x Q8_K matrix kernel in KIR, as lfm3_gpu_kernels.q4kMatrixSource:
/// 8 fibers per row, 8 rows per group, the same integer sums and the same
/// float epilogue in the same order (so the same bits).
fn q4kKernel(k: *kir.Kernel, tokens: u32) void {
    const W = k.binding();
    const AQ = k.binding();
    const AD = k.binding();
    const AS = k.binding();
    const OUT = k.binding();
    const row_bytes = k.param(.u32, 0);
    const blocks = k.param(.u32, 1);
    const kcols = k.param(.u32, 2);
    const blocks4 = k.param(.u32, 3);
    const blocks32 = k.param(.u32, 4);
    const rows4 = k.param(.u32, 5);
    const t = k.tid(0);
    const lane = k.op2(.@"and", .u32, r(t), u(7));
    const row = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(k.gid(0)), u(3))), r(k.op2(.shr, .u32, r(t), u(3))));
    const lane4 = k.op2(.shl, .u32, r(lane), u(2));
    // (loop-invariant: the lane's min byte shift and word)
    const min_shift = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(lane), u(3))), u(3));
    const high_lanes = k.cmp(.u32, .ge, r(lane), u(4));
    var ta: [8]kir.V = undefined;
    var td: [8]kir.V = undefined;
    var tsb: [8]kir.V = undefined;
    var sum: [8]kir.V = undefined;
    for (0..tokens) |ti| {
        const tt: u32 = @intCast(ti);
        if (tt == 0) {
            ta[ti] = lane4;
            td[ti] = k.mov(.u32, u(0));
            tsb[ti] = lane4;
        } else {
            ta[ti] = k.op3(.imad, .u32, r(kcols), u(tt), r(lane4));
            td[ti] = k.op2(.imul, .u32, r(blocks4), u(tt));
            tsb[ti] = k.op3(.imad, .u32, r(blocks32), u(tt), r(lane4));
        }
        sum[ti] = k.mov(.f32, f(0));
    }
    const blk = k.op2(.imul, .u32, r(row), r(row_bytes));
    const b256 = k.mov(.u32, u(0));
    const b4 = k.mov(.u32, u(0));
    const b32 = k.mov(.u32, u(0));
    const cnt = k.mov(.u32, u(0));
    k.loop();
    {
        const hdr = k.load(.u32, kir.global(W, 128), r(blk));
        const q = k.op2(.iadd, .u32, r(blk), r(lane4));
        var qs: [4]kir.V = undefined;
        for (0..4) |p| {
            var m = kir.global(W, 32);
            m.imm = @intCast(16 + 32 * p);
            qs[p] = k.load(.u32, m, r(q));
        }
        var acts: [8][8]kir.V = undefined;
        var ad: [8]kir.V = undefined;
        var bs: [8]kir.V = undefined;
        for (0..tokens) |ti| {
            const ao = k.op2(.iadd, .u32, r(ta[ti]), r(b256));
            for (0..8) |j| {
                var m = kir.global(AQ, 32);
                m.imm = @intCast(32 * j);
                acts[ti][j] = k.load(.u32, m, r(ao));
            }
            ad[ti] = k.load(.f32, kir.global(AD, 32), r(k.op2(.iadd, .u32, r(td[ti]), r(b4))));
            bs[ti] = k.load(.u32, kir.global(AS, 32), r(k.op2(.iadd, .u32, r(tsb[ti]), r(b32))));
        }
        const h1 = kir.Kernel.at(hdr, 1);
        const h2 = kir.Kernel.at(hdr, 2);
        const h3 = kir.Kernel.at(hdr, 3);
        // the 6-bit scales and minimums (GGML's mask sequence)
        const sc_lo = k.op2(.@"and", .u32, r(h1), u(0x3f3f3f3f));
        const hi1 = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(h1), u(6))), u(0x03030303))), u(4));
        const sc_hi = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(h3), u(0x0f0f0f0f))), r(hi1));
        const mn_lo = k.op2(.@"and", .u32, r(h2), u(0x3f3f3f3f));
        const hi2 = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(h2), u(6))), u(0x03030303))), u(4));
        const mn_hi = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(h3), u(4))), u(0x0f0f0f0f))), r(hi2));
        var sc: [8]kir.V = undefined;
        for (0..8) |j| sc[j] = k.op3(.bfe, .u32, r(if (j < 4) sc_lo else sc_hi), u(@intCast(8 * (j % 4))), u(8));
        const mins = k.sel(.u32, r(high_lanes), r(mn_hi), r(mn_lo));
        const min_lane = k.op3(.bfe, .u32, r(mins), r(min_shift), u(8));
        const h0 = kir.Kernel.at(hdr, 0);
        const dd = k.cvt(.f16, .f32, .rne, r(k.mov(.f16, r(h0))));
        const dmin = k.cvt(.f16, .f32, .rne, r(k.mov(.f16, r(k.op2(.shr, .u32, r(h0), u(16))))));
        var wq: [8]kir.V = undefined;
        for (0..4) |p| {
            wq[2 * p] = k.op2(.@"and", .u32, r(qs[p]), u(0x0f0f0f0f));
            wq[2 * p + 1] = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(qs[p]), u(4))), u(0x0f0f0f0f));
        }
        for (0..tokens) |ti| {
            var acc: kir.V = undefined;
            for (0..8) |j| {
                const m = k.opAux(.dot4, .i32, r(acts[ti][j]), r(wq[j]), kir.i(0), @intFromEnum(kir.Dot4.s8u8));
                acc = if (j == 0) k.op2(.imul, .i32, r(m), r(sc[j])) else k.op3(.imad, .i32, r(m), r(sc[j]), r(acc));
            }
            const bsum = k.op2(.iadd, .i32, r(k.op3(.bfe, .i32, r(bs[ti]), u(0), u(16))), r(k.op3(.bfe, .i32, r(bs[ti]), u(16), u(16))));
            const mm = k.op2(.imul, .i32, r(bsum), r(min_lane));
            const fi = k.cvt(.i32, .f32, .rne, r(acc));
            const fm = k.cvt(.i32, .f32, .rne, r(mm));
            const x0 = k.op2(.fmul, .f32, r(dd), r(ad[ti]));
            const y0 = k.op2(.fmul, .f32, r(dmin), r(ad[ti]));
            const x1 = k.op2(.fmul, .f32, r(x0), r(fi));
            const y1 = k.op2(.fmul, .f32, r(y0), r(fm));
            k.set(sum[ti], .fadd, r(sum[ti]), r(k.op2(.fsub, .f32, r(x1), r(y1))), no);
        }
        k.set(blk, .iadd, r(blk), u(144), no);
        k.set(b256, .iadd, r(b256), u(256), no);
        k.set(b4, .iadd, r(b4), u(4), no);
        k.set(b32, .iadd, r(b32), u(32), no);
        k.set(cnt, .iadd, r(cnt), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(cnt), r(blocks))));
    }
    k.endloop();
    // the lanes' sums in order: s0 + s1 + ... + s7
    var tot: [8]kir.V = undefined;
    for (0..tokens) |ti| {
        tot[ti] = sum[ti];
        for (1..8) |kk| tot[ti] = k.op2(.fadd, .f32, r(tot[ti]), r(k.shfl(.f32, .down, r(sum[ti]), u(@intCast(kk)))));
    }
    k.ifp(r(k.cmp(.u32, .eq, r(lane), u(0))));
    const ro = k.op2(.shl, .u32, r(row), u(2));
    for (0..tokens) |ti| {
        const o = if (ti == 0) ro else k.op3(.imad, .u32, r(rows4), u(@intCast(ti)), r(ro));
        k.store(.f32, kir.global(OUT, 32), r(o), r(tot[ti]));
    }
    k.endif();
}

fn q4kCase(comptime tokens: comptime_int, rows: u32, blocks: u32) !void {
    Rig.emu.init(&Rig.arena, &Rig.view);
    emu_ready = true;
    const d = Rig.emu.device();
    const row_bytes = blocks * hand.Q4_K_BLOCK;
    const kc = blocks * hand.QK_K;
    const w = try d.alloc(rows * row_bytes, .host);
    const aq = try d.alloc(tokens * kc, .host);
    const ad = try d.alloc(tokens * blocks * 4, .host);
    const abs = try d.alloc(tokens * blocks * 32, .host);
    const out_hand = try d.alloc(tokens * rows * 4, .host);
    const out_kir = try d.alloc(tokens * rows * 4, .host);
    var seed: u32 = 4242;
    for (w.cpu, 0..) |*b, i| b.* = @truncate(lcg(&seed) >> 13 ^ i);
    for (0..rows * blocks) |bi| {
        const at = bi * hand.Q4_K_BLOCK;
        std.mem.writeInt(u16, w.cpu[at..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
        std.mem.writeInt(u16, w.cpu[at + 2 ..][0..2], @intCast(0x1400 + (lcg(&seed) >> 22)), .little);
    }
    for (aq.cpu) |*b| b.* = @truncate(lcg(&seed) >> 11);
    const adf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, ad.cpu));
    for (adf) |*x| x.* = @as(f32, @floatFromInt(lcg(&seed) >> 16)) / 65536.0 * 0.01;
    for (abs.cpu) |*b| b.* = @truncate(lcg(&seed) >> 9);
    for ([_]gpu.Buffer{ w, aq, ad, abs }) |b| d.toDevice(b, 0, b.bytes);
    const mc = hand.MatrixConsts{ .weights = w.gpu, .act_q = aq.gpu, .act_d = ad.gpu, .act_sums = abs.gpu, .out = out_hand.gpu, .row_bytes = row_bytes, .blocks = blocks, .rows = rows };
    const groups = [3]u32{ rows / hand.MATRIX_ROWS_PER_GROUP, 1, 1 };
    const hc = try runHand(comptime hand.q4kMatrixSource(tokens), &mc.dwords(), null, groups);
    var k = newKernel("q4k", .{ 64, 1, 1 });
    q4kKernel(&k, tokens);
    const params = [_]u32{ row_bytes, blocks, kc, blocks * 4, blocks * 32, rows * 4 };
    const qc = try runKir(&k, groups, &.{ w, aq, ad, abs, out_kir }, &params);
    d.fromDevice(out_hand, 0, out_hand.bytes);
    d.fromDevice(out_kir, 0, out_kir.bytes);
    // the interpreter too (KIR's definition), on the CPU's copies
    var interp_out = zeros(8 * 64 * 4);
    _ = try runInterp(&k, groups, &.{ w.cpu, aq.cpu, ad.cpu, abs.cpu, interp_out[0..out_kir.cpu.len] }, &params);
    try std.testing.expectEqualSlices(u8, out_hand.cpu, out_kir.cpu);
    try std.testing.expect(sameBuffers(out_kir.cpu, interp_out[0..out_kir.cpu.len]));
    var name_buf: [64]u8 = undefined;
    report(std.fmt.bufPrint(&name_buf, "Q4_K x Q8_K, {d} token(s), {d} blocks", .{ tokens, blocks }) catch "q4k", hc, qc);
    if (tokens == 1) {
        try std.testing.expect(qc.legalized * 10 <= hc.legalized * 11);
        try std.testing.expect(qc.issued * 10 <= hc.issued * 11);
    }
}

test "Q4_K matrix: KIR equals the hand-written kernel to the bit, within 10% of its instructions" {
    try q4kCase(1, 32, 8);
    try q4kCase(4, 16, 6);
    try q4kCase(8, 16, 3);
}

/// hidden[t] += rmsnorm(x[t]) * weight, as lfm3_gpu_kernels.residualSource
/// (postnorm): one wave per 256-element block, four elements per fiber;
/// squares summed with mad (the GPU's), the waves' sums through shared
/// memory, 1/sqrt by the SFU.
fn rmsKernel(k: *kir.Kernel, waves: u32) void {
    const X = k.binding();
    const NW = k.binding();
    const HID = k.binding();
    const kk = k.param(.u32, 0);
    const eps = k.param(.f32, 1);
    const inv_k = k.param(.f32, 2);
    const t = k.tid(0);
    const wave = k.op2(.shr, .u32, r(t), u(6));
    const lane = k.op2(.@"and", .u32, r(t), u(63));
    const tok = k.gid(1);
    const e = k.op3(.imad, .u32, r(tok), r(kk), r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(wave), u(8))), r(k.op2(.shl, .u32, r(lane), u(2))))));
    const off = k.op2(.shl, .u32, r(e), u(2));
    const x = k.load(.f32, kir.global(X, 128), r(off));
    var s = k.op2(.fmul, .f32, r(x), r(x));
    for (1..4) |i| s = k.op3(.fmad, .f32, r(kir.Kernel.at(x, @intCast(i))), r(kir.Kernel.at(x, @intCast(i))), r(s));
    for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| s = k.op2(.fadd, .f32, r(s), r(k.shfl(.f32, .xor, r(s), u(m))));
    const sh = k.sharedAlloc(64, 4);
    var ms = kir.shared(32);
    ms.imm = @intCast(sh);
    k.ifp(r(k.cmp(.u32, .eq, r(lane), u(0))));
    k.store(.f32, ms, r(k.op2(.shl, .u32, r(wave), u(2))), r(s));
    k.endif();
    k.barrier();
    var tot = k.load(.f32, ms, u(0));
    for (1..waves) |wv| tot = k.op2(.fadd, .f32, r(tot), r(k.load(.f32, ms, u(@intCast(4 * wv)))));
    const inv = k.op1(.frsq, .f32, r(k.op2(.fadd, .f32, r(k.op2(.fmul, .f32, r(tot), r(inv_k))), r(eps))));
    const wo = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(wave), u(10))), r(k.op2(.shl, .u32, r(lane), u(4))));
    const wt = k.load(.f32, kir.global(NW, 128), r(wo));
    const h = k.load(.f32, kir.global(HID, 128), r(off));
    const res = k.vec(.f32, 4);
    for (0..4) |i| {
        const ix: u16 = @intCast(i);
        const y = k.op2(.fmul, .f32, r(k.op2(.fmul, .f32, r(kir.Kernel.at(x, ix)), r(inv))), r(kir.Kernel.at(wt, ix)));
        k.set(kir.Kernel.at(res, ix), .fadd, r(kir.Kernel.at(h, ix)), r(y), no);
    }
    k.store(.f32, kir.global(HID, 128), r(off), r(res));
}

fn rmsCase(comptime waves: comptime_int, tokens: u32) !void {
    Rig.emu.init(&Rig.arena, &Rig.view);
    emu_ready = true;
    const d = Rig.emu.device();
    const kc: u32 = waves * 256;
    const x = try d.alloc(tokens * kc * 4, .host);
    const nw = try d.alloc(kc * 4, .host);
    const hid_hand = try d.alloc(tokens * kc * 4, .host);
    const hid_kir = try d.alloc(tokens * kc * 4, .host);
    var seed: u32 = 31337;
    const xf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, x.cpu));
    for (xf) |*v| v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 4.0;
    const wf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, nw.cpu));
    for (wf) |*v| v.* = @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 + 0.5;
    const hf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, hid_hand.cpu));
    for (hf) |*v| v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 2.0;
    @memcpy(hid_kir.cpu, hid_hand.cpu);
    for ([_]gpu.Buffer{ x, nw, hid_hand, hid_kir }) |b| d.toDevice(b, 0, b.bytes);
    const eps: f32 = 1e-5;
    const qc = hand.QuantConsts{ .x = x.gpu, .norm_weight = nw.gpu, .normalized = hid_hand.gpu, .act_q = 0, .act_d = 0, .act_sums = 0, .k = kc, .epsilon = eps };
    const groups = [3]u32{ 1, tokens, 1 };
    const hc = try runHand(comptime hand.residualSource(true, waves), &qc.dwords(), null, groups);
    var k = newKernel("rmsnorm", .{ 64 * waves, 1, 1 });
    rmsKernel(&k, waves);
    const inv_k: f32 = 1.0 / @as(f32, @floatFromInt(kc));
    const kq = try runKir(&k, groups, &.{ x, nw, hid_kir }, &.{ kc, fb(eps), fb(inv_k) });
    d.fromDevice(hid_hand, 0, hid_hand.bytes);
    d.fromDevice(hid_kir, 0, hid_kir.bytes);
    try std.testing.expectEqualSlices(u8, hid_hand.cpu, hid_kir.cpu);
    var name_buf: [64]u8 = undefined;
    report(std.fmt.bufPrint(&name_buf, "RMSNorm + residual, {d} waves, {d} tokens", .{ waves, tokens }) catch "rms", hc, kq);
    try std.testing.expect(kq.legalized * 10 <= hc.legalized * 11);
    try std.testing.expect(kq.issued * 10 <= hc.issued * 11);
}

test "RMSNorm: KIR equals the hand-written kernel to the bit, within 10% of its instructions" {
    try rmsCase(8, 3);
    try rmsCase(2, 1);
}

/// One (query head, token) per group of 64, as lfm3_gpu_kernels'
/// attentionSource: the query in shared memory; scores q . k over the
/// visible keys (f16 keys, eight lane sums in order), times the scale;
/// the maximum, exp2((s - max) * log2 e) and their sum; weights through
/// f16 times the f16 values in position order; the head's sigmoid gate.
fn attnKernel(k: *kir.Kernel, span: u32) void {
    const Q = k.binding();
    const KV = k.binding();
    const GATE = k.binding();
    const OUT = k.binding();
    const heads = k.param(.u32, 0);
    const block_bytes = k.param(.u32, 1);
    const slot = k.param(.u32, 2);
    const max_kv = k.param(.u32, 3);
    const first_pos = k.param(.u32, 4);
    const scale = k.param(.f32, 5);
    const window = k.param(.u32, 6);
    const log2group = k.param(.u32, 7);
    const qbase = k.sharedAlloc(512, 16);
    const sbase = k.sharedAlloc((span + 64) * 4, 16);
    const h = k.gid(0);
    const t = k.gid(1);
    const j = k.tid(0);
    const pos = k.op2(.iadd, .u32, r(first_pos), r(t));
    // the first visible position (a sliding window) and how many
    const in_win = k.op2(.pand, .pred, r(k.cmp(.u32, .ge, r(pos), r(window))), r(k.cmp(.u32, .ne, r(window), u(0))));
    const visible = k.sel(.u32, r(in_win), r(k.op2(.iadd, .u32, r(k.op2(.isub, .u32, r(pos), r(window))), u(1))), u(0));
    const L = k.op2(.isub, .u32, r(k.op2(.iadd, .u32, r(pos), u(1))), r(visible));
    const kvh = k.op2(.shr, .u32, r(h), r(log2group));
    const kblock_ix = k.op2(.iadd, .u32, r(k.op2(.imul, .u32, r(k.op2(.shl, .u32, r(slot), u(1))), r(max_kv))), r(kvh));
    const kblock = k.op2(.imul, .u32, r(kblock_ix), r(block_bytes));
    const vblock = k.op2(.imul, .u32, r(k.op2(.iadd, .u32, r(kblock_ix), r(max_kv))), r(block_bytes));
    // the query into shared memory
    const qrow = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(t), r(heads), r(h))), u(9));
    const j4 = k.op2(.shl, .u32, r(j), u(2));
    const qo = k.op2(.iadd, .u32, r(qrow), r(j4));
    const qo2 = k.op2(.iadd, .u32, r(qo), u(256));
    var mq = kir.shared(32);
    mq.imm = @intCast(qbase);
    k.store(.f32, mq, r(j4), r(k.load(.f32, kir.global(Q, 32), r(qo))));
    var mq2 = mq;
    mq2.imm = @intCast(qbase + 256);
    k.store(.f32, mq2, r(j4), r(k.load(.f32, kir.global(Q, 32), r(qo2))));
    k.barrier();
    const passes = k.op2(.shr, .u32, r(k.op2(.iadd, .u32, r(L), u(63))), u(6));
    var ms = kir.shared(32);
    ms.imm = @intCast(sbase);
    // scores
    const pass = k.mov(.u32, u(0));
    k.loop();
    {
        const p_rel = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(pass), u(6))), r(j));
        const valid = k.cmp(.u32, .lt, r(p_rel), r(L));
        const krow = k.sel(.u32, r(valid), r(k.op2(.iadd, .u32, r(visible), r(p_rel))), r(visible));
        const ko = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(krow), u(8))), r(kblock));
        var acc: [8]kir.V = undefined;
        for (0..16) |i| {
            var m1 = kir.shared(128);
            m1.imm = @intCast(qbase + 32 * i);
            const q1 = k.load(.f32, m1, u(0));
            m1.imm = @intCast(qbase + 32 * i + 16);
            const q2 = k.load(.f32, m1, u(0));
            var mk = kir.global(KV, 128);
            mk.imm = @intCast(16 * i);
            const kw = k.load(.u32, mk, r(ko));
            for (0..8) |l| {
                const word = kir.Kernel.at(kw, @intCast(l / 2));
                const half = if (l % 2 == 0) k.mov(.f16, r(word)) else k.mov(.f16, r(k.op2(.shr, .u32, r(word), u(16))));
                const kf = k.cvt(.f16, .f32, .rne, r(half));
                const qf = kir.Kernel.at(if (l < 4) q1 else q2, @intCast(l % 4));
                const p = k.op2(.fmul, .f32, r(qf), r(kf));
                acc[l] = if (i == 0) p else k.op2(.fadd, .f32, r(acc[l]), r(p));
            }
        }
        var sc = acc[0];
        for (1..8) |l| sc = k.op2(.fadd, .f32, r(sc), r(acc[l]));
        sc = k.op2(.fmul, .f32, r(sc), r(scale));
        const at = k.sel(.u32, r(valid), r(p_rel), r(k.op2(.iadd, .u32, r(L), r(j))));
        k.store(.f32, ms, r(k.op2(.shl, .u32, r(at), u(2))), r(sc));
        k.set(pass, .iadd, r(pass), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(pass), r(passes))));
    }
    k.endloop();
    k.barrier();
    // the maximum
    const mx = k.mov(.f32, f(-std.math.inf(f32)));
    k.set(pass, .mov, u(0), no, no);
    k.loop();
    {
        const p_rel = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(pass), u(6))), r(j));
        const valid = k.cmp(.u32, .lt, r(p_rel), r(L));
        const s = k.load(.f32, ms, r(k.op2(.shl, .u32, r(p_rel), u(2))));
        k.set(mx, .sel, r(k.op2(.fmax, .f32, r(mx), r(s))), r(mx), r(valid));
        k.set(pass, .iadd, r(pass), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(pass), r(passes))));
    }
    k.endloop();
    var mxr = mx;
    for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| mxr = k.op2(.fmax, .f32, r(mxr), r(k.shfl(.f32, .xor, r(mxr), u(m))));
    // e = exp2((s - max) * log2 e) in place, and their sum
    const total = k.mov(.f32, f(0));
    k.set(pass, .mov, u(0), no, no);
    k.loop();
    {
        const p_rel = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(pass), u(6))), r(j));
        const valid = k.cmp(.u32, .lt, r(p_rel), r(L));
        const a = k.op2(.shl, .u32, r(p_rel), u(2));
        const s = k.load(.f32, ms, r(a));
        const e = k.op1(.fexp2, .f32, r(k.op2(.fmul, .f32, r(k.op2(.fsub, .f32, r(s), r(mxr))), f(1.44269504))));
        k.store(.f32, ms, r(a), r(e));
        k.set(total, .fadd, r(total), r(k.sel(.f32, r(valid), r(e), f(0))), no);
        k.set(pass, .iadd, r(pass), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(pass), r(passes))));
    }
    k.endloop();
    var tot = total;
    for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |m| tot = k.op2(.fadd, .f32, r(tot), r(k.shfl(.f32, .xor, r(tot), u(m))));
    const inv = k.op1(.frcp, .f32, r(tot));
    k.barrier();
    // out = sum over positions of f16(e * inv) * f16 value
    const o1 = k.mov(.f32, f(0));
    const o2 = k.mov(.f32, f(0));
    const vo = k.op2(.iadd, .u32, r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(visible), u(8))), r(vblock))), r(k.op2(.shl, .u32, r(j), u(1))));
    const n = k.mov(.u32, u(0));
    const so = k.mov(.u32, u(0));
    k.loop();
    {
        const e = k.load(.f32, ms, r(so));
        const wgt = k.cvt(.f16, .f32, .rne, r(k.cvt(.f32, .f16, .rne, r(k.op2(.fmul, .f32, r(e), r(inv))))));
        const v1 = k.cvt(.f16, .f32, .rne, r(k.load(.f16, kir.global(KV, 16), r(vo))));
        var mv = kir.global(KV, 16);
        mv.imm = 128;
        const v2 = k.cvt(.f16, .f32, .rne, r(k.load(.f16, mv, r(vo))));
        k.set(o1, .fadd, r(o1), r(k.op2(.fmul, .f32, r(wgt), r(v1))), no);
        k.set(o2, .fadd, r(o2), r(k.op2(.fmul, .f32, r(wgt), r(v2))), no);
        k.set(vo, .iadd, r(vo), u(256), no);
        k.set(so, .iadd, r(so), u(4), no);
        k.set(n, .iadd, r(n), u(1), no);
        k.brk(r(k.cmp(.u32, .ge, r(n), r(L))));
    }
    k.endloop();
    // the gate: 1 / (1 + exp2(-logit * log2 e))
    const go = k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(t), r(heads), r(h))), u(2));
    const g = k.load(.f32, kir.global(GATE, 32), r(go));
    const gate = k.op1(.frcp, .f32, r(k.op2(.fadd, .f32, r(k.op1(.fexp2, .f32, r(k.op2(.fmul, .f32, r(g), f(-1.44269504))))), f(1.0))));
    k.store(.f32, kir.global(OUT, 32), r(qo), r(k.op2(.fmul, .f32, r(o1), r(gate))));
    k.store(.f32, kir.global(OUT, 32), r(qo2), r(k.op2(.fmul, .f32, r(o2), r(gate))));
}

fn attnCase(heads: u32, kv_heads: u32, tokens: u32, first_pos: u32, window: u32) !void {
    Rig.emu.init(&Rig.arena, &Rig.view);
    emu_ready = true;
    const d = Rig.emu.device();
    const hs = 128;
    const context: u32 = 512;
    const span: u32 = 512;
    const max_kv = kv_heads;
    const slot: u32 = 1;
    const q = try d.alloc(tokens * heads * hs * 4, .host);
    const kvb = try d.alloc((slot + 1) * 2 * max_kv * context * hs * 2, .host);
    const gate = try d.alloc(tokens * heads * 4, .host);
    const out_hand = try d.alloc(tokens * heads * hs * 4, .host);
    const out_kir = try d.alloc(tokens * heads * hs * 4, .host);
    var seed: u32 = 2718;
    const qf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, q.cpu));
    for (qf) |*v| v.* = @floatCast(@as(f16, @floatCast((@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 2.0)));
    const kvh: []u16 = @alignCast(std.mem.bytesAsSlice(u16, kvb.cpu));
    for (kvh) |*v| v.* = @bitCast(@as(f16, @floatCast((@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 2.0)));
    const gf: []f32 = @alignCast(std.mem.bytesAsSlice(f32, gate.cpu));
    for (gf) |*v| v.* = (@as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 - 0.5) * 6.0;
    for ([_]gpu.Buffer{ q, kvb, gate }) |b| d.toDevice(b, 0, b.bytes);
    const ac = hand.AttnConsts{ .query = q.gpu, .gate = gate.gpu, .out = out_hand.gpu, .kv = kvb.gpu, .heads = heads, .kv_heads = kv_heads, .head_size = hs, .context = context, .slot = slot, .max_kv_heads = max_kv, .first_position = first_pos, .window = window };
    const groups = [3]u32{ heads, tokens, 1 };
    const hc = try runHand(comptime hand.attentionSource(), &ac.dwords(), .{ .first = 6, .words = &ac.outDwords() }, groups);
    var k = newKernel("attention", .{ 64, 1, 1 });
    attnKernel(&k, span);
    const scale: f32 = 1.0 / @sqrt(@as(f32, hs));
    const params = [_]u32{ heads, context * hs * 2, slot, max_kv, first_pos, fb(scale), window, std.math.log2_int(u32, heads / kv_heads) };
    const kc = try runKir(&k, groups, &.{ q, kvb, gate, out_kir }, &params);
    if (show_listing) std.debug.print("{s}\n", .{kir_ir3.listing(&Rig.work, &Rig.listing)});
    d.fromDevice(out_hand, 0, out_hand.bytes);
    d.fromDevice(out_kir, 0, out_kir.bytes);
    try std.testing.expectEqualSlices(u8, out_hand.cpu, out_kir.cpu);
    var name_buf: [80]u8 = undefined;
    report(std.fmt.bufPrint(&name_buf, "attention, {d} heads, {d} tokens from {d}, window {d}", .{ heads, tokens, first_pos, window }) catch "attention", hc, kc);
    try std.testing.expect(kc.legalized * 10 <= hc.legalized * 11);
    try std.testing.expect(kc.issued * 10 <= hc.issued * 11);
}

test "attention: KIR equals the hand-written kernel to the bit, within 10% of its instructions" {
    try attnCase(4, 2, 3, 37, 0);
    try attnCase(2, 1, 2, 300, 256);
    try attnCase(2, 2, 1, 130, 0);
}
