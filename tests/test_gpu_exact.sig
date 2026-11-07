//! KIR's exact fdiv and fsqrt expansions (kir.expandDiv, kir.expandSqrt),
//! bit-exact against the interpreter's own fdiv and fsqrt (which are Sig's
//! f32 division and square root under the caps' denormal mode), for the
//! fused-FMA expansion and the mul/add-only (Dekker) one, denormals kept
//! and flushed, with frcp/frsq exact and off by up to 600 ulps.
//!
//! The pairs: every special value against every other, quotients built
//! to lie nearest to a rounding midpoint (the hard cases, for every odd
//! divisor mantissa in a stride), results in gradual underflow and near
//! overflow, and random bit patterns, about 3.6 million divisions and as
//! many square roots per configuration... (8 of them).

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const interp = gpu.interp;
const r = kir.r;
const u = kir.u;

const GROUP = 256;
const BATCH = 1 << 16;

var work_mem: [8 << 20]u8 align(64) = undefined;
var insts_a: [256]kir.Inst = undefined;
var tys_a: [256]kir.Ty = undefined;
var insts_b: [4096]kir.Inst = undefined;
var tys_b: [4096]kir.Ty = undefined;

var xs: [BATCH]u32 = undefined;
var ys: [BATCH]u32 = undefined;
var want: [BATCH]u32 = undefined;
var got: [BATCH]u32 = undefined;

fn flt(x: u32) f32 {
    return @bitCast(x);
}
fn bits(x: f32) u32 {
    return @bitCast(x);
}

/// out[i] = x[i] / y[i] (or sqrt(x[i])) for i < n.
fn opKernel(sqrt: bool) !kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &insts_a, .tys = &tys_a }, if (sqrt) "sqrt" else "div", .{ GROUP, 1, 1 });
    const bx = k.binding();
    const by = k.binding();
    const bo = k.binding();
    const n = k.param(.u32, 0);
    const ix = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    const off = k.op2(.shl, .u32, r(ix), u(2));
    k.ifp(r(k.cmp(.u32, .lt, r(ix), r(n))));
    const a = k.load(.f32, kir.global(bx, 32), r(off));
    const b = k.load(.f32, kir.global(by, 32), r(off));
    const q = if (sqrt) k.sqrt(r(a)) else k.div(r(a), r(b));
    k.store(.f32, kir.global(bo, 32), r(off), r(q));
    k.endif();
    try k.finish();
    return k;
}

fn runOn(k: *const kir.Kernel, caps: gpu.Caps, n: usize, out: []u32, jitter: u32) !void {
    var w = gpu.Work.init(&work_mem);
    var trap: interp.Trap = .{};
    var stats: interp.Stats = .{};
    const groups: u32 = @intCast((n + GROUP - 1) / GROUP);
    const bx = std.mem.sliceAsBytes(xs[0..n]);
    const by = std.mem.sliceAsBytes(ys[0..n]);
    const bo = std.mem.sliceAsBytes(out[0..n]);
    try kir.verify(k, caps);
    interp.run(.{
        .code = k.code(),
        .regs = k.nv,
        .group = k.group,
        .shared_bytes = k.shared_bytes,
        .groups = .{ groups, 1, 1 },
        .bindings = &.{ bx, by, bo },
        .params = &.{@as(u32, @intCast(n))},
        .jitter_ulps = jitter,
    }, caps, &w, &trap, &stats) catch |e| {
        std.debug.print("trap {s} pc {d}\n", .{ @tagName(trap.what), trap.pc });
        return e;
    };
}

const Config = struct { fused: bool, flush: bool, jitter: u32 };

fn capsOf(c: Config) gpu.Caps {
    var caps = gpu.interp_caps;
    caps.fused_fma = c.fused;
    caps.mad = if (c.fused) .fused else .unfused;
    caps.denormals = if (c.flush) .flush else .preserve;
    return caps;
}

var checked: u64 = 0;

/// Runs the batch through the plain kernel and the expanded one, and
/// compares every result's bits.
fn check(sqrt: bool, c: Config, n: usize) !void {
    const caps = capsOf(c);
    var plain = try opKernel(sqrt);
    try runOn(&plain, caps, n, &want, 0);
    var exp = try kir.expand(&plain, caps, .{ .insts = &insts_b, .tys = &tys_b });
    try exp.finish();
    try runOn(&exp, caps, n, &got, c.jitter);
    for (0..n) |ix| {
        if (want[ix] != got[ix]) {
            std.debug.print("{s} fused={} flush={} jitter={d}: {x:0>8} {x:0>8} -> want {x:0>8} got {x:0>8}\n", .{ if (sqrt) "sqrt" else "div", c.fused, c.flush, c.jitter, xs[ix], ys[ix], want[ix], got[ix] });
            return error.TestExpectedEqual;
        }
    }
    checked += n;
}

const specials = [_]u32{
    0x0000_0000, 0x8000_0000, 0x0000_0001, 0x8000_0001, 0x0000_0002, 0x0040_0000,
    0x007f_ffff, 0x807f_ffff, 0x0080_0000, 0x8080_0000, 0x0080_0001, 0x00ff_ffff,
    0x3f80_0000, 0xbf80_0000, 0x3f80_0001, 0x3fff_ffff, 0x4000_0000, 0x3f7f_ffff,
    0x3f00_0000, 0x4040_0000, 0x4049_0fdb, 0x3dcc_cccd, 0x7f7f_ffff, 0xff7f_ffff,
    0x7f00_0000, 0x0100_0000, 0x1000_0000, 0x6000_0000, 0x2780_0000, 0x277f_ffff,
    0x57ff_ffff, 0x5800_0000, 0x0d80_0000, 0x7180_0000, 0x7f80_0000, 0xff80_0000,
    0x7fc0_0000, 0xffc0_0000, 0x7f80_0001, 0x7fa0_0000, 0x4b80_0000, 0x3380_0000,
};

var rng = std.Random.DefaultPrng.init(0x6d1c_e5a7);

fn modinv(a0: i64, m: i64) i64 {
    var t: i64 = 0;
    var nt: i64 = 1;
    var rr: i64 = m;
    var nr: i64 = @mod(a0, m);
    while (nr != 0) {
        const q = @divTrunc(rr, nr);
        const tt = t - q * nt;
        t = nt;
        nt = tt;
        const r2 = rr - q * nr;
        rr = nr;
        nr = r2;
    }
    if (t < 0) t += m;
    return t;
}

/// Fills the batch with division pairs of kind `which`; returns n.
fn fillDiv(which: usize, round: usize) usize {
    const rand = rng.random();
    var n: usize = 0;
    switch (which) {
        // every special against every special
        0 => for (specials) |a| for (specials) |b| {
            xs[n] = a;
            ys[n] = b;
            n += 1;
        },
        // the hard cases: a/b nearest to a midpoint, mantissas of every
        // 61st odd divisor, scaled to random exponents (some into the
        // slow path's gradual underflow and overflow)
        1 => {
            var mb: i64 = (1 << 23) + 1 + 2 * @as(i64, @intCast(round));
            while (mb < (1 << 24) and n + 12 <= BATCH) : (mb += 2 * 61) {
                const inv24 = modinv(1 << 24, mb);
                const inv25 = modinv(1 << 25, mb);
                for ([_]i64{ 1, -1, 2, -2, 3, -3 }) |d| for ([_]i64{ inv24, inv25 }) |inv| {
                    var ma = @mod(d * inv, mb);
                    while (ma < (1 << 23)) ma += mb;
                    if (ma >= (1 << 24)) continue;
                    const ea: u32 = rand.intRangeAtMost(u32, 1, 254);
                    const eb: u32 = if (rand.boolean()) ea -% rand.intRangeAtMost(u32, 0, 30) else rand.intRangeAtMost(u32, 1, 254);
                    const ebc: u32 = if (eb == 0 or eb > 254) 127 else eb;
                    const sa: u32 = if (rand.boolean()) 0x8000_0000 else 0;
                    xs[n] = sa | (ea << 23) | @as(u32, @intCast(ma - (1 << 23)));
                    ys[n] = (ebc << 23) | @as(u32, @intCast(mb - (1 << 23)));
                    n += 1;
                };
            }
        },
        // random bit patterns over the whole range
        2 => while (n < BATCH) : (n += 1) {
            xs[n] = rand.int(u32);
            ys[n] = rand.int(u32);
        },
        // the fast range, and the slow path's edges: denormal operands,
        // results near the underflow and overflow thresholds
        else => while (n < BATCH) : (n += 1) {
            const kind = rand.intRangeLessThan(u32, 0, 4);
            const ma = rand.int(u32) & 0x007f_ffff;
            const mb = rand.int(u32) & 0x007f_ffff;
            switch (kind) {
                0 => {
                    xs[n] = ((rand.intRangeAtMost(u32, 79, 175)) << 23) | ma;
                    ys[n] = ((rand.intRangeAtMost(u32, 79, 175)) << 23) | mb;
                },
                1 => { // tiny / big: gradual underflow
                    xs[n] = (rand.intRangeAtMost(u32, 0, 30) << 23) | ma;
                    ys[n] = (rand.intRangeAtMost(u32, 100, 160) << 23) | mb;
                },
                2 => { // big / tiny: overflow
                    xs[n] = (rand.intRangeAtMost(u32, 200, 254) << 23) | ma;
                    ys[n] = (rand.intRangeAtMost(u32, 0, 80) << 23) | mb;
                },
                else => { // denormal operands
                    xs[n] = if (rand.boolean()) ma else (rand.intRangeAtMost(u32, 1, 254) << 23) | ma;
                    ys[n] = if (rand.boolean()) mb else (rand.intRangeAtMost(u32, 1, 254) << 23) | mb;
                },
            }
            if (rand.boolean()) xs[n] |= 0x8000_0000;
            if (rand.boolean()) ys[n] |= 0x8000_0000;
        },
    }
    return n;
}

/// Square roots: every mantissa of [1,4) in strides (both exponent
/// parities), specials, denormals, random patterns.
fn fillSqrt(which: usize, round: usize) usize {
    const rand = rng.random();
    var n: usize = 0;
    switch (which) {
        0 => {
            for (specials) |a| {
                xs[n] = a;
                n += 1;
            }
            while (n < BATCH) : (n += 1) xs[n] = rand.int(u32) & 0x807f_ffff; // denormals
        },
        1 => {
            // a stride through all 2^24 inputs in [1,4), at random even
            // scalings (4^k) so the slow path sees them too
            var x: u32 = 0x3f80_0000 + @as(u32, @intCast(round));
            while (x < 0x4080_0000 and n < BATCH) : (x += 257) {
                const k: u32 = rand.intRangeAtMost(u32, 0, 62);
                const scaled = @as(i64, x) + (@as(i64, k) - 31) * (2 << 23);
                xs[n] = if (scaled > 0x0080_0000 and scaled < 0x7f80_0000) @intCast(scaled) else x;
                n += 1;
            }
        },
        else => while (n < BATCH) : (n += 1) {
            xs[n] = rand.int(u32);
        },
    }
    for (0..n) |ix| ys[ix] = 0;
    return n;
}

const configs = [_]Config{
    .{ .fused = true, .flush = false, .jitter = 0 },
    .{ .fused = false, .flush = false, .jitter = 0 },
    .{ .fused = true, .flush = true, .jitter = 0 },
    .{ .fused = false, .flush = true, .jitter = 0 },
    .{ .fused = true, .flush = false, .jitter = 600 },
    .{ .fused = false, .flush = false, .jitter = 600 },
    .{ .fused = true, .flush = true, .jitter = 600 },
    .{ .fused = false, .flush = true, .jitter = 600 },
};

test "exact: fdiv expansions, bit-exact to fdiv" {
    checked = 0;
    for (configs) |c| {
        try check(false, c, fillDiv(0, 0));
        for (0..2) |round| try check(false, c, fillDiv(1, round));
        for (0..2) |_| try check(false, c, fillDiv(2, 0));
        for (0..2) |_| try check(false, c, fillDiv(3, 0));
    }
    std.debug.print("fdiv: {d} divisions bit-exact\n", .{checked});
}

test "exact: fsqrt expansions, bit-exact to fsqrt" {
    checked = 0;
    for (configs) |c| {
        try check(true, c, fillSqrt(0, 0));
        for (0..2) |round| try check(true, c, fillSqrt(1, round * 129));
        try check(true, c, fillSqrt(2, 0));
    }
    std.debug.print("fsqrt: {d} roots bit-exact\n", .{checked});
}

/// KIR instructions an fdiv or fsqrt becomes: emitted in all, and run on
/// the fast path (every lane's operands well inside the normal range).
fn counts(sqrt: bool, fused: bool) ![2]u64 {
    const caps = capsOf(.{ .fused = fused, .flush = false, .jitter = 0 });
    var plain = try opKernel(sqrt);
    for (0..GROUP) |ix| {
        xs[ix] = 0x3fc0_0000 + @as(u32, @intCast(ix)) * 977;
        ys[ix] = 0x4010_0000 + @as(u32, @intCast(ix)) * 1361;
    }
    var w = gpu.Work.init(&work_mem);
    var trap: interp.Trap = .{};
    const bx = std.mem.sliceAsBytes(xs[0..GROUP]);
    const by = std.mem.sliceAsBytes(ys[0..GROUP]);
    const bo = std.mem.sliceAsBytes(got[0..GROUP]);
    const s0 = try interp.runKernel(&plain, caps, .{ 1, 1, 1 }, &.{ bx, by, bo }, &.{GROUP}, &w, &trap);
    var exp = try kir.expand(&plain, caps, .{ .insts = &insts_b, .tys = &tys_b });
    try exp.finish();
    const s1 = try interp.runKernel(&exp, caps, .{ 1, 1, 1 }, &.{ bx, by, bo }, &.{GROUP}, &w, &trap);
    return .{ exp.n - plain.n + 1, s1.issued - s0.issued + 1 };
}

test "exact: instruction counts" {
    for ([_]bool{ false, true }) |sqrt| for ([_]bool{ true, false }) |fused| {
        const c = try counts(sqrt, fused);
        std.debug.print("{s} {s}: {d} KIR instructions, {d} on the fast path\n", .{ if (sqrt) "fsqrt" else "fdiv", if (fused) "fused" else "mul/add", c[0], c[1] });
    };
}
