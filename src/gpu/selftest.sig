//! @zpm/gpu self-test — KIR on a real Device, every result checked against
//! the interpreter (KIR's definition) under the same Caps.
//!
//! Each case builds a small kernel, compiles it for `dev.caps.target`,
//! runs it on `dev`, runs the same kernel on the CPU in kir_interp, and
//! compares the output words: bit for bit, NaNs as NaNs where an op may
//! give any NaN, the approximate ops within docs/GPU.md's bounds. One log
//! line per case:
//!
//!   gpu self-test <case>: ok (N checked)
//!   gpu self-test <case>: FAILED: lane L, word W: got X want Y (inputs ...) [op]; B of N wrong
//!
//! A wrong result, a timeout or a device error fails the case and the run
//! goes on; a lost device ends it (the cases left are skipped). Nothing
//! here panics. The last line is "gpu self-test: P passed, F failed, S
//! skipped".
//!
//! The cases: integer and float arithmetic (every op, registers and
//! immediates, edge values), dot4 in its three signednesses, cvt in every
//! rounding, the exact fdiv and fsqrt on hard cases, the approximate ops,
//! global loads and stores of 8 to 128 bits, shared memory with barriers,
//! shuffles in every mode, votes, global and shared atomics, divergent
//! if/else and loops (shuffles and votes inside divergent code, a
//! loop-carried predicate, reconvergence after the flow), a 3-D grid, and
//! two probes that only report: fused or unfused mad, and denormals.
//!
//! Allocator-free: the caller owns the Work (WORK_BYTES, keep it static).
//! Freestanding-clean: no std.debug, std.Io or std.fmt; numbers are
//! formatted here. GPU memory: four buffers, 1.2 MiB in all.

const std = @import("std");
const kir = @import("kir.sig");
const dv = @import("device.sig");
const interp = @import("kir_interp.sig");
const kir_ir3 = @import("kir_ir3.sig");
const kir_sm120 = @import("kir_sm120.sig");

const Caps = dv.Caps;
const Device = dv.Device;
const Buffer = dv.Buffer;
const V = kir.V;
const Arg = kir.Arg;
const Op = kir.Op;
const Ty = kir.Ty;
const r = kir.r;
const u = kir.u;
const no = kir.no;

/// The most lanes (input triples) a case has.
pub const LANES = 4096;
/// u32 words in each of the three input buffers.
pub const IN_WORDS = 16384;
/// u32 words in the output buffer.
pub const OUT_WORDS = 1 << 18;
/// Instructions and registers a case's kernel may have.
pub const MAX_INSTS = 4096;
/// Ops one table case holds.
pub const MAX_ITEMS = 96;
const CODE_BYTES = 256 * 1024;
const INTERP_BYTES = 4 << 20;
/// What any backend's compile takes from a device.Work.
const COMPILE_BYTES = @max(kir_ir3.WORK_BYTES, kir_sm120.WORK_BYTES) + 4096;
const LINE_BYTES = 256;

/// The self-test's storage: compile and interpreter scratch, the kernel,
/// its code, the inputs and three copies of the output. Caller-owned
/// (static: `var w: selftest.Work = undefined;`), 19.5 MB, most of it
/// the largest backend's compile Work (kir_ir3's, 11.5 MB).
pub const Work = struct {
    compile: [COMPILE_BYTES]u8 align(64) = undefined,
    interp: [INTERP_BYTES]u8 align(64) = undefined,
    insts: [MAX_INSTS]kir.Inst = undefined,
    tys: [MAX_INSTS]Ty = undefined,
    code: [CODE_BYTES]u8 align(256) = undefined,
    in: [3][IN_WORDS]u32 align(64) = undefined,
    /// the output's first contents, then the interpreter's result
    want: [OUT_WORDS]u32 align(64) = undefined,
    /// the interpreter's result under the case's other caps (mad, denormals)
    alt: [OUT_WORDS]u32 align(64) = undefined,
    /// the device's result
    got: [OUT_WORDS]u32 align(64) = undefined,
    items: [MAX_ITEMS]Item = undefined,
};
pub const WORK_BYTES = @sizeOf(Work);

pub const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    first_failure: [96]u8 = [_]u8{0} ** 96,
    first_failure_len: usize = 0,
    /// GPU time of every case's run (ns), 0 when the device does not know
    gpu_ns: u64 = 0,
    /// the device was lost (the cases after it were skipped)
    lost: bool = false,

    pub fn firstFailure(res: *const Result) []const u8 {
        return res.first_failure[0..res.first_failure_len];
    }
};

/// Every case on `dev`, logged line by line, each run waited for at most
/// `timeout_us`. Links every backend (compile); an image for one GPU uses
/// runAllFor.
pub fn runAll(dev: Device, work: *Work, log: *const fn ([]const u8) void, timeout_us: u64) Result {
    return runWith(dv.all_targets, dev, work, log, .{ .timeout_us = timeout_us });
}

/// runAll, compiling with only `targets`' backends (device.compileFor).
pub fn runAllFor(comptime targets: []const dv.Target, dev: Device, work: *Work, log: *const fn ([]const u8) void, timeout_us: u64) Result {
    return runWith(targets, dev, work, log, .{ .timeout_us = timeout_us });
}

pub const Options = struct {
    timeout_us: u64 = 2_000_000,
    /// End the run at a lost device (the rule on hardware). An emulated
    /// device reports a kernel's fault or hazard as DeviceLost and is
    /// still usable: tests may go on.
    stop_when_lost: bool = true,
    /// Called with each failing case's kernel, after its line is logged
    /// (to dump a backend's listing, say).
    on_failure: ?*const fn (name: []const u8, k: *const kir.Kernel, caps: Caps) void = null,
};

/// runAllFor with every option.
pub fn runWith(comptime targets: []const dv.Target, dev: Device, work: *Work, log: *const fn ([]const u8) void, opts: Options) Result {
    const C = struct {
        fn compile(k: *const kir.Kernel, caps: Caps, w: *dv.Work, out: []u8) anyerror!dv.Binary {
            return dv.compileFor(targets, k, caps, w, out);
        }
    };
    var s = Suite{ .dev = dev, .caps = dev.caps, .w = work, .log = log, .timeout_us = opts.timeout_us, .compile_fn = &C.compile, .opts = opts };
    s.run();
    return s.res;
}

/// The names of the cases, in order (for tools and docs).
pub fn caseCount() usize {
    return cases.len;
}

// ── The cases ───────────────────────────────────────────────────────────────

const Case = struct { name: []const u8, run: *const fn (s: *Suite, name: []const u8) void };

const cases = [_]Case{
    .{ .name = "int u32", .run = caseIntU32 },
    .{ .name = "int i32", .run = caseIntI32 },
    .{ .name = "int immediates", .run = caseIntImm },
    .{ .name = "dot4", .run = caseDot4 },
    .{ .name = "float", .run = caseFloat },
    .{ .name = "float immediates", .run = caseFloatImm },
    .{ .name = "approximate ops", .run = caseApprox },
    .{ .name = "exact fdiv and fsqrt", .run = caseExact },
    .{ .name = "cvt rne", .run = caseCvtRne },
    .{ .name = "cvt rz", .run = caseCvtRz },
    .{ .name = "cvt rd", .run = caseCvtRd },
    .{ .name = "cvt ru", .run = caseCvtRu },
    .{ .name = "global loads 8-128", .run = caseLoads },
    .{ .name = "global stores 8-128", .run = caseStores },
    .{ .name = "shared memory and barriers", .run = caseShared },
    .{ .name = "shuffles", .run = caseShuffles },
    .{ .name = "votes", .run = caseVotes },
    .{ .name = "grid ids and params", .run = caseGrid },
    .{ .name = "mad probe", .run = probeMad },
    .{ .name = "denormals probe", .run = probeDenormals },
    // (last: the cases whose kernels a backend bug could make fault, which
    // loses the device and ends the run)
    .{ .name = "global atomics", .run = caseAtomics },
    .{ .name = "shared atomics", .run = caseSharedAtomics },
    .{ .name = "compare-and-swap and ballots", .run = caseCas },
    .{ .name = "divergent if/else", .run = caseDivergentIf },
    .{ .name = "divergent loops", .run = caseLoops },
};

// ── Table cases: one op per output row, one lane per input triple ──────────

pub const Src = union(enum) {
    /// the u32 word of input `n` at the lane
    reg: u2,
    imm: u32,
    /// bit 0 of input `n` as a predicate
    pred: u2,
};

pub const Item = struct {
    op: Op,
    ty: Ty,
    aux: u32 = 0,
    a: Src = .{ .reg = 0 },
    b: Src = .{ .reg = 1 },
    c: Src = .{ .reg = 2 },
    /// dropped: the backend cannot compile it
    off: bool = false,
};

const Kind = enum { exact, float, half, approx, mad };

fn arity(op: Op) u2 {
    return switch (op) {
        .mov, .ineg, .iabs, .not, .pnot, .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne, .fsqrt, .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos, .cvt => 1,
        .sel, .imad, .bfe, .dot4, .ffma, .fmad => 3,
        else => 2,
    };
}

fn slotTy(it: Item, j: usize) Ty {
    return switch (it.op) {
        .sel => if (j == 2) .pred else it.ty,
        .pand, .por, .pnot => .pred,
        .cvt => @as(kir.Cvt, @bitCast(it.aux)).from,
        .shl, .shr, .bfe, .dot4, .imad => if (it.ty == .i32) .i32 else .u32,
        else => it.ty,
    };
}

fn srcOf(it: Item, j: usize) Src {
    return switch (j) {
        0 => it.a,
        1 => it.b,
        else => it.c,
    };
}

fn isApprox(op: Op) bool {
    return switch (op) {
        .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos => true,
        else => false,
    };
}

fn kindOf(it: Item) Kind {
    return switch (it.op) {
        .frcp, .frsq, .fexp2, .flog2, .fsin, .fcos => .approx,
        .fmad => .mad,
        // (moves and sign-bit ops keep every bit, NaN payloads too)
        .mov, .sel, .fabs, .fneg, .icmp, .fcmp => .exact,
        .cvt => switch (@as(kir.Cvt, @bitCast(it.aux)).to) {
            .f16 => .half,
            .f32 => .float,
            else => .exact,
        },
        else => if (it.ty == .f32) .float else .exact,
    };
}

/// The register holding input `n` at the lane as type `ty` (loaded once).
const Inputs = struct {
    off: V,
    word: [3]?V = .{ null, null, null },
    typed: [3][5]?V = .{ [_]?V{null} ** 5, [_]?V{null} ** 5, [_]?V{null} ** 5 },

    fn get(in: *Inputs, k: *kir.Kernel, n: u2, ty: Ty) V {
        const w = in.word[n] orelse blk: {
            const x = k.load(.u32, kir.global(n, 32), r(in.off));
            in.word[n] = x;
            break :blk x;
        };
        if (ty == .u32) return w;
        const t = @intFromEnum(ty);
        if (in.typed[n][t]) |v| return v;
        const v = switch (ty) {
            .pred => k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(w), u(1))), u(0)),
            else => k.mov(ty, r(w)),
        };
        in.typed[n][t] = v;
        return v;
    }
};

fn tyOf(k: *const kir.Kernel, v: V) Ty {
    const ix = @intFromEnum(v);
    return if (ix < k.nv) k.tys[ix] else .u32;
}

/// The table's kernel: each active item's result in its own row of
/// `lanes` words. Returns the rows.
fn buildItems(s: *Suite, k: *kir.Kernel, items: []const Item, lanes: u32) u32 {
    const lane = s.linear(k);
    var in = Inputs{ .off = k.op2(.shl, .u32, r(lane), u(2)) };
    var row: u32 = 0;
    for (items) |it| {
        if (it.off) continue;
        var args = [3]Arg{ no, no, no };
        for (0..arity(it.op)) |j| {
            args[j] = switch (srcOf(it, j)) {
                .imm => |x| u(x),
                .reg => |n| r(in.get(k, n, slotTy(it, j))),
                .pred => |n| r(in.get(k, n, .pred)),
            };
        }
        var res = k.opAux(it.op, it.ty, args[0], args[1], args[2], it.aux);
        if (res == .none) return row;
        const rt = tyOf(k, res);
        if (rt == .pred) res = k.sel(.u32, r(res), u(1), u(0));
        const o = if (row == 0) in.off else k.op2(.iadd, .u32, r(in.off), u(row * lanes * 4));
        switch (rt) {
            .f16 => k.store(.f16, kir.global(OUT, 16), r(o), r(res)),
            .pred => k.store(.u32, kir.global(OUT, 32), r(o), r(res)),
            else => k.store(rt, kir.global(OUT, 32), r(o), r(res)),
        }
        row += 1;
    }
    return row;
}

const Table = struct {
    lanes: u32 = LANES,
    /// the interpreter again under these caps, for `.mad` rows (and probes)
    alt: ?Caps = null,
    probe: enum { none, mad, denormals } = .none,
};

// ── The suite ───────────────────────────────────────────────────────────────

const IN0: u8 = 0;
const IN1: u8 = 1;
const IN2: u8 = 2;
const OUT: u8 = 3;

/// How a case's output words are compared and named.
const Layout = struct {
    /// words per row (the lanes); 0: a flat layout, words named by index
    lanes: u32,
    /// the words compared
    words: usize,
    kind: Kind = .exact,
    /// input words shown with a failure (0..3)
    show: u2 = 0,
};

const Suite = struct {
    dev: Device,
    caps: Caps,
    w: *Work,
    log: *const fn ([]const u8) void,
    timeout_us: u64,
    opts: Options = .{},
    /// the case's kernel, once built (for on_failure)
    cur: ?*const kir.Kernel = null,
    cur_name: []const u8 = "",
    compile_fn: *const fn (k: *const kir.Kernel, caps: Caps, w: *dv.Work, out: []u8) anyerror!dv.Binary,
    res: Result = .{},
    bufs: [4]Buffer = undefined,
    lost: bool = false,
    /// threads per group of most cases
    group: u32 = 256,
    n_items: usize = 0,
    rng: Rng = .{ .s = 0x5eed_1234_abcd_ef01 },

    fn run(s: *Suite) void {
        var g: u32 = 256;
        while (g > s.caps.max_group and g > 1) g /= 2;
        if (g < s.caps.subgroup and s.caps.subgroup <= s.caps.max_group and s.caps.subgroup <= 1024) g = s.caps.subgroup;
        s.group = g;
        var l = Line{};
        l.s("gpu self-test on ");
        l.s(if (s.caps.name.len != 0) s.caps.name else @tagName(s.caps.target));
        l.s(" (");
        l.s(@tagName(s.caps.target));
        l.s(", subgroup ");
        l.dec(s.caps.subgroup);
        l.s(", mad ");
        l.s(@tagName(s.caps.mad));
        l.s(if (s.caps.fused_fma) ", ffma" else ", no ffma");
        l.s(", denormals ");
        l.s(@tagName(s.caps.denormals));
        l.s("): ");
        l.dec(cases.len);
        l.s(" cases");
        s.log(l.text());
        if (!s.allocBuffers()) {
            s.res.skipped = cases.len;
        } else {
            for (cases, 0..) |c, ix| {
                if (s.lost) {
                    const left: u32 = @intCast(cases.len - ix);
                    s.res.skipped += left;
                    var m = Line{};
                    m.s("gpu self-test: the device is lost: ");
                    m.dec(left);
                    m.s(" cases not run");
                    s.log(m.text());
                    break;
                }
                s.cur = null;
                s.cur_name = c.name;
                c.run(s, c.name);
            }
            if (!s.lost) for (s.bufs) |b| s.dev.free(b);
        }
        var t = Line{};
        t.s("gpu self-test: GPU time ");
        t.dec(s.res.gpu_ns / 1000);
        t.s(" us");
        s.log(t.text());
        var e = Line{};
        e.s("gpu self-test: ");
        e.dec(s.res.passed);
        e.s(" passed, ");
        e.dec(s.res.failed);
        e.s(" failed, ");
        e.dec(s.res.skipped);
        e.s(" skipped");
        s.log(e.text());
    }

    fn allocBuffers(s: *Suite) bool {
        var n: usize = 0;
        while (n < 4) : (n += 1) {
            const bytes: u64 = if (n < 3) IN_WORDS * 4 else OUT_WORDS * 4;
            const want_kind: dv.Kind = if (n < 3) .upload else .host;
            var b = s.dev.alloc(bytes, want_kind) catch Buffer{};
            if (b.cpu.len < bytes and want_kind != .host) {
                if (b.bytes != 0) s.dev.free(b);
                b = s.dev.alloc(bytes, .host) catch Buffer{};
            }
            if (b.cpu.len < bytes) {
                if (b.bytes != 0) s.dev.free(b);
                for (s.bufs[0..n]) |x| s.dev.free(x);
                var l = Line{};
                l.s("gpu self-test: no buffers: ");
                l.s(if (b.bytes == 0) "out of device memory" else "a buffer without a CPU view");
                s.log(l.text());
                return false;
            }
            s.bufs[n] = b;
        }
        return true;
    }

    // ── kernels ──

    fn begin(s: *Suite, name: []const u8, group: [3]u32) kir.Kernel {
        var k = kir.Kernel.init(.{ .insts = &s.w.insts, .tys = &s.w.tys }, name, group);
        _ = k.binding();
        _ = k.binding();
        _ = k.binding();
        _ = k.binding();
        return k;
    }

    /// gid.x * group + tid.x
    fn linear(s: *Suite, k: *kir.Kernel) V {
        return k.op3(.imad, .u32, r(k.gid(0)), u(s.group), r(k.tid(0)));
    }

    /// out[row * lanes + lane] = v (off = lane * 4)
    fn put(k: *kir.Kernel, off: V, row: u32, lanes: u32, ty: Ty, v: V) void {
        const o = if (row == 0) off else k.op2(.iadd, .u32, r(off), u(row * lanes * 4));
        k.store(ty, kir.global(OUT, 32), r(o), r(v));
    }

    fn compile(s: *Suite, k: *const kir.Kernel) anyerror!dv.Binary {
        var cw = dv.Work.init(&s.w.compile);
        return s.compile_fn(k, s.caps, &cw, &s.w.code);
    }

    // ── outcomes ──

    fn pass(s: *Suite, name: []const u8, checked: u64, note: []const u8) void {
        s.res.passed += 1;
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(": ok (");
        l.dec(checked);
        l.s(" checked");
        l.s(note);
        l.s(")");
        s.log(l.text());
    }

    fn skip(s: *Suite, name: []const u8, why: []const u8) void {
        s.res.skipped += 1;
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(": skipped (");
        l.s(why);
        l.s(")");
        s.log(l.text());
    }

    fn failLine(s: *Suite, l: *const Line) void {
        s.res.failed += 1;
        s.log(l.text());
        if (s.opts.on_failure) |hook| if (s.cur) |k| hook(s.cur_name, k, s.caps);
        if (s.res.first_failure_len == 0) {
            // (without the "gpu self-test " prefix)
            const t = l.text();
            const from: usize = if (t.len > 14) 14 else 0;
            const n = @min(t.len - from, s.res.first_failure.len);
            @memcpy(s.res.first_failure[0..n], t[from..][0..n]);
            s.res.first_failure_len = n;
        }
    }

    fn fail(s: *Suite, name: []const u8, what: []const u8, err: ?anyerror) void {
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(": FAILED: ");
        l.s(what);
        if (err) |e| {
            l.s(": ");
            l.s(@errorName(e));
        }
        s.failLine(&l);
    }

    // ── running ──

    /// The kernel compiled, run on the device (output starting as `want`
    /// holds it) and on the interpreter. False: the case is over (logged).
    fn execute(s: *Suite, name: []const u8, k: *kir.Kernel, groups: [3]u32, params: []const u32, words: usize, alt: ?Caps) bool {
        s.cur = k;
        k.finish() catch |e| {
            s.fail(name, "the self-test's kernel does not verify", e);
            return false;
        };
        const bin = s.compile(k) catch |e| {
            if (e == error.Unsupported) {
                s.skip(name, "the backend cannot compile it");
            } else s.fail(name, "compile", e);
            return false;
        };
        if (alt != null) @memcpy(s.w.alt[0..words], s.w.want[0..words]);
        if (!s.runDevice(name, &bin, groups, params, words)) return false;
        if (!s.runInterp(name, k, groups, params, s.caps, &s.w.want)) return false;
        if (alt) |ac| if (!s.runInterp(name, k, groups, params, ac, &s.w.alt)) return false;
        return true;
    }

    fn runDevice(s: *Suite, name: []const u8, bin: *const dv.Binary, groups: [3]u32, params: []const u32, words: usize) bool {
        const d = s.dev;
        const prog = d.load(bin) catch |e| {
            s.fail(name, "load", e);
            if (e == error.DeviceLost) s.lose();
            return false;
        };
        defer d.unload(&prog);
        for (0..3) |n| {
            @memcpy(s.bufs[n].cpu[0 .. IN_WORDS * 4], std.mem.sliceAsBytes(&s.w.in[n]));
            d.toDevice(s.bufs[n], 0, IN_WORDS * 4);
        }
        const out = s.bufs[3];
        @memcpy(out.cpu[0 .. words * 4], std.mem.sliceAsBytes(s.w.want[0..words]));
        d.toDevice(out, 0, words * 4);
        const fence = d.run(&.{.{ .prog = &prog, .groups = groups, .buffers = &s.bufs, .params = params }}) catch |e| {
            s.fail(name, "run", e);
            if (e == error.DeviceLost) s.lose();
            return false;
        };
        d.wait(fence, s.timeout_us) catch |e| {
            if (e == error.Timeout) {
                // (wait once more: still running means a hung GPU)
                d.wait(fence, s.timeout_us) catch {
                    s.fail(name, "timeout, still running after twice the timeout: the GPU is taken as lost", null);
                    s.lose();
                    return false;
                };
                s.fail(name, "timeout (it finished within twice the timeout)", null);
                return false;
            }
            s.fail(name, "wait", e);
            if (e == error.DeviceLost) s.lose();
            return false;
        };
        s.res.gpu_ns +%= d.lastRunNs();
        d.fromDevice(out, 0, words * 4);
        @memcpy(std.mem.sliceAsBytes(s.w.got[0..words]), out.cpu[0 .. words * 4]);
        return true;
    }

    fn lose(s: *Suite) void {
        s.res.lost = true;
        if (s.opts.stop_when_lost) s.lost = true;
    }

    fn runInterp(s: *Suite, name: []const u8, k: *const kir.Kernel, groups: [3]u32, params: []const u32, caps: Caps, out: *[OUT_WORDS]u32) bool {
        var iw = dv.Work.init(&s.w.interp);
        var trap: interp.Trap = .{};
        var stats: interp.Stats = .{};
        const bindings = [4][]u8{
            std.mem.sliceAsBytes(&s.w.in[0]),
            std.mem.sliceAsBytes(&s.w.in[1]),
            std.mem.sliceAsBytes(&s.w.in[2]),
            std.mem.sliceAsBytes(out),
        };
        interp.run(.{
            .code = k.code(),
            .regs = k.nv,
            .group = k.group,
            .shared_bytes = k.shared_bytes,
            .groups = groups,
            .bindings = &bindings,
            .params = params,
        }, caps, &iw, &trap, &stats) catch |e| {
            var l = Line{};
            l.s("gpu self-test ");
            l.s(name);
            l.s(": FAILED: the interpreter: ");
            l.s(@errorName(e));
            l.s(" (");
            l.s(@tagName(trap.what));
            l.s(" at instruction ");
            l.dec(trap.pc);
            l.s(", thread ");
            l.dec(trap.thread);
            l.s(")");
            s.failLine(&l);
            return false;
        };
        return true;
    }

    /// Compares got with want; logs the case's line.
    fn compare(s: *Suite, name: []const u8, lay: Layout, items: []const Item, note: []const u8) void {
        var checked: u64 = 0;
        var bad: u64 = 0;
        var first: usize = 0;
        var first_item: ?Item = null;
        var row_item: usize = 0;
        var row: usize = 0;
        var ix: usize = 0;
        while (ix < lay.words) : (ix += 1) {
            var kind = lay.kind;
            var op: Op = .mov;
            var x: u32 = 0;
            var it: ?Item = null;
            if (items.len != 0 and lay.lanes != 0) {
                const rw = ix / lay.lanes;
                if (rw != row or ix == 0) {
                    row = rw;
                    // (the row's item: the rw-th active one)
                    row_item = activeIndex(items, rw) orelse items.len;
                }
                if (row_item < items.len) {
                    const cur = items[row_item];
                    it = cur;
                    kind = kindOf(cur);
                    op = cur.op;
                    const lane = ix % lay.lanes;
                    switch (cur.a) {
                        .reg => |n| x = s.w.in[n][lane],
                        else => {},
                    }
                }
            }
            const ok = wordOk(kind, op, x, s.w.want[ix], s.w.got[ix], s.w.alt[ix]) orelse continue;
            checked += 1;
            if (!ok) {
                if (bad == 0) {
                    first = ix;
                    first_item = it;
                }
                bad += 1;
            }
        }
        if (bad == 0) return s.pass(name, checked, note);
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(": FAILED: ");
        if (lay.lanes != 0) {
            l.s("lane ");
            l.dec(first % lay.lanes);
            l.s(", word ");
            l.dec(first / lay.lanes);
        } else {
            l.s("word ");
            l.dec(first);
        }
        l.s(": got ");
        l.hex(s.w.got[first]);
        l.s(" want ");
        l.hex(s.w.want[first]);
        if (first_item) |it| if (kindOf(it) == .mad and s.w.alt[first] != s.w.want[first]) {
            l.s(" or ");
            l.hex(s.w.alt[first]);
        };
        if (lay.lanes != 0) {
            const lane = first % lay.lanes;
            if (first_item) |it| {
                l.s(" (inputs");
                for (0..arity(it.op)) |j| {
                    l.s(if (j == 0) " " else ", ");
                    switch (srcOf(it, j)) {
                        .reg => |n| l.hex(s.w.in[n][lane]),
                        .pred => |n| {
                            l.s("p");
                            l.dec(s.w.in[n][lane] & 1);
                        },
                        .imm => |v| {
                            l.s("#");
                            l.hex(v);
                        },
                    }
                }
                l.s(") [");
                label(&l, it);
                l.s("]");
            } else if (lay.show != 0 and lane < IN_WORDS) {
                l.s(" (inputs");
                for (0..lay.show) |j| {
                    l.s(if (j == 0) " " else ", ");
                    l.hex(s.w.in[j][lane]);
                }
                l.s(")");
            }
        }
        l.s("; ");
        l.dec(bad);
        l.s(" of ");
        l.dec(checked);
        l.s(" wrong");
        s.failLine(&l);
    }

    // ── table cases ──

    fn beginItems(s: *Suite) void {
        s.n_items = 0;
    }

    fn add(s: *Suite, it: Item) void {
        if (s.n_items == MAX_ITEMS) return;
        s.w.items[s.n_items] = it;
        s.n_items += 1;
    }

    /// Builds, compiles (dropping the items the backend cannot compile),
    /// runs and compares the items added since beginItems.
    fn runItems(s: *Suite, name: []const u8, t: Table) void {
        const items = s.w.items[0..s.n_items];
        const groups = [3]u32{ t.lanes / s.group, 1, 1 };
        var k = s.begin(name, .{ s.group, 1, 1 });
        var rows = buildItems(s, &k, items, t.lanes);
        k.finish() catch |e| return s.fail(name, "the self-test's kernel does not verify", e);
        var dropped: u32 = 0;
        if (s.compile(&k)) |_| {} else |e| {
            if (e != error.Unsupported) return s.fail(name, "compile", e);
            // which items cannot be compiled: each alone
            for (items) |*it| {
                var one = s.begin(name, .{ s.group, 1, 1 });
                _ = buildItems(s, &one, it[0..1], t.lanes);
                one.finish() catch {};
                if (s.compile(&one)) |_| {} else |e2| {
                    if (e2 == error.Unsupported) {
                        it.off = true;
                        dropped += 1;
                    }
                }
            }
            if (dropped == items.len) return s.skip(name, "the backend cannot compile any of its ops");
            k = s.begin(name, .{ s.group, 1, 1 });
            rows = buildItems(s, &k, items, t.lanes);
        }
        const words: usize = @as(usize, rows) * t.lanes;
        if (words > OUT_WORDS) return s.fail(name, "the self-test's table is too long", null);
        fillPattern(s.w.want[0..words]);
        if (!s.execute(name, &k, groups, &.{}, words, t.alt)) return;
        switch (t.probe) {
            .none => {
                var note = Line{};
                if (dropped != 0) {
                    note.s("; ");
                    note.dec(dropped);
                    note.s(" ops the backend cannot compile:");
                    var shown: u32 = 0;
                    for (items) |it| if (it.off and shown < 3) {
                        note.s(" ");
                        label(&note, it);
                        shown += 1;
                    };
                    if (dropped > 3) note.s(" ...");
                }
                s.compare(name, .{ .lanes = t.lanes, .words = words }, items, note.text());
            },
            .mad => s.reportMad(name, words),
            .denormals => s.reportDenormals(name, items, t.lanes),
        }
    }

    // ── probes ──

    fn reportMad(s: *Suite, name: []const u8, words: usize) void {
        // want: under the device's caps; alt: the other rounding
        var same: u64 = 0;
        var other: u64 = 0;
        var neither: u64 = 0;
        for (0..words) |ix| {
            const a = s.w.want[ix];
            const b = s.w.alt[ix];
            if (a == b) continue;
            const g = s.w.got[ix];
            if (g == a) same += 1 else if (g == b) other += 1 else neither += 1;
        }
        const caps_fused = s.caps.mad == .fused;
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(": ");
        const told = same + other + neither;
        if (told == 0) {
            l.s("no lane tells fused from unfused");
        } else if (other == 0 and neither == 0) {
            l.s(if (caps_fused) "fused" else "unfused");
        } else if (same == 0 and neither == 0) {
            l.s(if (caps_fused) "unfused" else "fused");
        } else {
            l.s("mixed: ");
            l.dec(if (caps_fused) same else other);
            l.s(" fused, ");
            l.dec(if (caps_fused) other else same);
            l.s(" unfused, ");
            l.dec(neither);
            l.s(" neither");
        }
        l.s(" (");
        l.dec(told);
        l.s(" lanes tell; caps say ");
        l.s(@tagName(s.caps.mad));
        if (other != 0 or neither != 0) l.s(": they are wrong") else l.s(": they agree");
        l.s(")");
        s.res.passed += 1;
        s.log(l.text());
    }

    fn reportDenormals(s: *Suite, name: []const u8, items: []const Item, lanes: u32) void {
        // want: under the device's caps; alt: the other mode
        const caps_flush = s.caps.denormals == .flush;
        var l = Line{};
        l.s("gpu self-test ");
        l.s(name);
        l.s(":");
        var agree = true;
        var row: usize = 0;
        for (items) |it| {
            if (it.off) continue;
            var same: u64 = 0;
            var other: u64 = 0;
            var neither: u64 = 0;
            for (0..lanes) |ln| {
                const ix = row * lanes + ln;
                const a = s.w.want[ix];
                const b = s.w.alt[ix];
                if (a == b) continue;
                const g = s.w.got[ix];
                if (g == a) same += 1 else if (g == b) other += 1 else neither += 1;
            }
            l.s(if (row == 0) " " else ", ");
            label(&l, it);
            l.s(" ");
            if (same + other + neither == 0) {
                l.s("n/a");
            } else if (other == 0 and neither == 0) {
                l.s(if (caps_flush) "flush" else "preserve");
            } else if (same == 0 and neither == 0) {
                l.s(if (caps_flush) "preserve" else "flush");
                agree = false;
            } else {
                l.s("mixed");
                agree = false;
            }
            row += 1;
        }
        l.s(" (caps say ");
        l.s(@tagName(s.caps.denormals));
        l.s(if (agree) ": they agree)" else ": they are wrong)");
        s.res.passed += 1;
        s.log(l.text());
    }
};

fn activeIndex(items: []const Item, rw: usize) ?usize {
    var n: usize = 0;
    for (items, 0..) |it, ix| {
        if (it.off) continue;
        if (n == rw) return ix;
        n += 1;
    }
    return null;
}

fn label(l: *Line, it: Item) void {
    l.s(@tagName(it.op));
    if (it.op == .cvt) {
        const c: kir.Cvt = @bitCast(it.aux);
        l.s(".");
        l.s(@tagName(c.from));
        l.s(">");
        l.s(@tagName(c.to));
        l.s(".");
        l.s(@tagName(c.round));
        return;
    }
    l.s(".");
    l.s(@tagName(it.ty));
    switch (it.op) {
        .icmp, .fcmp => {
            l.s(".");
            l.s(@tagName(@as(kir.Cmp, @enumFromInt(it.aux))));
        },
        .dot4 => {
            l.s(".");
            l.s(@tagName(@as(kir.Dot4, @enumFromInt(it.aux))));
        },
        else => {},
    }
    for (0..arity(it.op)) |j| {
        l.s(if (j == 0) " " else ",");
        switch (srcOf(it, j)) {
            .reg => |n| {
                l.s("x");
                l.dec(n);
            },
            .pred => |n| {
                l.s("p");
                l.dec(n);
            },
            .imm => |v| {
                l.s("#");
                l.hexShort(v);
            },
        }
    }
}

// ── Comparing ───────────────────────────────────────────────────────────────

fn isNan(x: u32) bool {
    return x & 0x7fff_ffff > 0x7f80_0000;
}
fn isInf(x: u32) bool {
    return x & 0x7fff_ffff == 0x7f80_0000;
}
fn isSub(x: u32) bool {
    return x & 0x7f80_0000 == 0 and x & 0x007f_ffff != 0;
}
fn isZero(x: u32) bool {
    return x & 0x7fff_ffff == 0;
}
fn flt(x: u32) f32 {
    return @bitCast(x);
}
fn bits(x: f32) u32 {
    return @bitCast(x);
}

/// Whether `got` is right (null: not checked).
fn wordOk(kind: Kind, op: Op, x: u32, want: u32, got: u32, alt: u32) ?bool {
    return switch (kind) {
        .exact => want == got,
        .float => want == got or (isNan(want) and isNan(got)),
        .half => blk: {
            if (want == got) break :blk true;
            if (want >> 16 != got >> 16) break :blk false;
            const wh = want & 0x7fff;
            const gh = got & 0x7fff;
            break :blk wh > 0x7c00 and gh > 0x7c00;
        },
        .mad => want == got or alt == got or (isNan(want) and isNan(got)),
        .approx => approxOk(op, x, want, got),
    };
}

/// docs/GPU.md's bounds against the interpreter's (correctly rounded or
/// f64) value, plus that value's own half ulp; null outside the domain.
fn approxOk(op: Op, x: u32, want: u32, got: u32) ?bool {
    if (want == got) return true;
    const sincos = op == .fsin or op == .fcos;
    // (sin and cos: |x| <= pi only)
    if (sincos and (x & 0x7fff_ffff) > 0x4049_0fdb) return null;
    // (an SFU may flush denormal inputs and results)
    if (isSub(x)) return null;
    if (isNan(want) or isNan(got)) return isNan(want) and isNan(got);
    if (isSub(want) or isSub(got)) return null;
    if (isZero(want) or isZero(got)) {
        // exp2 deep in underflow, rcp of huge values: gradual underflow
        // an SFU may not do
        if (op == .fexp2 or op == .frcp) {
            if (isZero(want) and (isSub(got) or isZero(got))) return null;
            if (isZero(got) and (isSub(want) or isZero(want))) return null;
            const tiny = (want & 0x7fff_ffff) < 0x0100_0000 and (got & 0x7fff_ffff) < 0x0100_0000;
            if (tiny) return null;
        }
        if (!sincos and op != .flog2) return false;
    }
    if (isInf(want) or isInf(got)) return false;
    const w: f64 = flt(want);
    const g: f64 = flt(got);
    const diff = @abs(g - w);
    const ulp_ref: f64 = 1.0 / 16777216.0; // the reference's own half ulp, relative 2^-24
    switch (op) {
        .fsin, .fcos => return diff <= 1.0 / 1048576.0 + ulp_ref,
        .flog2 => {
            const xf: f64 = flt(x);
            if (xf >= 0.5 and xf <= 2.0) return diff <= 1.0 / 2097152.0 + ulp_ref;
            return diff <= (1.0 / 2097152.0 + ulp_ref) * @abs(w);
        },
        else => return diff <= (1.0 / 2097152.0 + 2.0 * ulp_ref) * @abs(w),
    }
}

// ── Inputs ──────────────────────────────────────────────────────────────────

const Rng = struct {
    s: u64,
    fn next(g: *Rng) u32 {
        g.s = g.s *% 6364136223846793005 +% 1442695040888963407;
        const x = g.s;
        return @truncate((x ^ (x >> 29)) >> 16);
    }
    fn below(g: *Rng, n: u32) u32 {
        return if (n == 0) 0 else g.next() % n;
    }
};

const float_edges = [_]u32{
    0x0000_0000, 0x8000_0000, 0x3f80_0000, 0xbf80_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xffc0_0001,
    0x7f80_0001, 0x0000_0001, 0x8000_0001, 0x007f_ffff, 0x807f_ffff, 0x0040_0000, 0x0080_0000, 0x8080_0000,
    0x0080_0001, 0x7f7f_ffff, 0xff7f_ffff, 0x7f00_0000, 0x3f00_0000, 0xbf00_0000, 0x3fc0_0000, 0xbfc0_0000,
    0x4000_0000, 0x4040_0000, 0x3f7f_ffff, 0x3f80_0001, 0x3eff_ffff, 0x4b00_0000, 0x4b00_0001, 0x4b80_0000,
    0xcb00_0001, 0x4b7f_ffff, 0x4049_0fdb, 0xc049_0fdb, 0x3eaa_aaab, 0x3dcc_cccd, 0x4f00_0000, 0xcf00_0000,
    0x4f80_0000, 0x4f7f_ffff, 0x5f80_0000, 0x2f80_0000, 0x0c00_0000, 0x3fa0_0000, 0xc020_0000, 0x4010_0000,
};

const int_edges = [_]u32{
    0,           1,           2,           3,           5,           7,           8,           15,
    16,          31,          32,          33,          63,          64,          0x7f,        0x80,
    0xff,        0x100,       0x7fff,      0x8000,      0xffff,      0x10000,     0x00ff_ffff, 0x0100_0000,
    0x0100_0001, 0x7fff_ffff, 0x8000_0000, 0x8000_0001, 0xffff_fffe, 0xffff_ffff, 0xdead_beef, 0x0102_0304,
    0x8081_7f7e, 0xff7f_8001, 0x1234_5678, 0x8765_4321, 0x5555_5555, 0xaaaa_aaaa, 0xffff_fe00, 0x0000_01ff,
};

/// The output's first contents: a pattern no kernel writes by chance.
fn fillPattern(out: []u32) void {
    for (out, 0..) |*x, ix| x.* = 0x5a00_0000 ^ (@as(u32, @truncate(ix)) *% 0x9e37_79b9);
}

/// Edge pairs crossed in the first lanes, then random patterns and small
/// values (shift amounts, widths).
fn fillInts(s: *Suite) void {
    const E = int_edges.len;
    const in = &s.w.in;
    for (0..IN_WORDS) |l| {
        if (l < E * E) {
            in[0][l] = int_edges[l / E];
            in[1][l] = int_edges[l % E];
            in[2][l] = int_edges[(l * 7 + 3) % E];
        } else {
            in[0][l] = s.rng.next();
            in[1][l] = if (l & 1 == 0) s.rng.below(40) else s.rng.next();
            in[2][l] = if (l & 2 == 0) s.rng.below(40) else s.rng.next();
        }
    }
}

/// Edge pairs crossed, then random bits, then ordinary magnitudes and
/// near-cancelling pairs.
fn fillFloats(s: *Suite) void {
    const E = float_edges.len;
    const in = &s.w.in;
    for (0..IN_WORDS) |l| {
        if (l < E * E) {
            in[0][l] = float_edges[l / E];
            in[1][l] = float_edges[l % E];
            in[2][l] = float_edges[(l * 7 + 3) % E];
        } else if (l & 3 == 0) {
            in[0][l] = s.rng.next();
            in[1][l] = s.rng.next();
            in[2][l] = s.rng.next();
        } else {
            for (0..3) |j| in[j][l] = saneFloat(&s.rng);
            // (a - b nearly cancelling, a*b+c too)
            if (l & 3 == 1) in[1][l] = in[0][l] +% (s.rng.below(5)) -% 2;
            if (l & 3 == 2) in[2][l] = bits(-(flt(in[0][l]) * flt(in[1][l])));
        }
    }
}

fn saneFloat(g: *Rng) u32 {
    const e: u32 = 100 + g.below(56);
    return (g.next() & 0x8000_0000) | (e << 23) | (g.next() & 0x007f_ffff);
}

// ── The arithmetic cases ────────────────────────────────────────────────────

fn caseIntU32(s: *Suite, name: []const u8) void {
    s.beginItems();
    for ([_]Op{ .iadd, .isub, .imul, .imulhi, .imad, .ineg, .imin, .imax, .@"and", .@"or", .xor, .not, .shl, .shr, .bfe }) |op|
        s.add(.{ .op = op, .ty = .u32 });
    for (0..6) |c| s.add(.{ .op = .icmp, .ty = .u32, .aux = @intCast(c) });
    s.add(.{ .op = .sel, .ty = .u32, .c = .{ .pred = 2 } });
    s.add(.{ .op = .pand, .ty = .pred, .a = .{ .pred = 0 }, .b = .{ .pred = 1 } });
    s.add(.{ .op = .por, .ty = .pred, .a = .{ .pred = 0 }, .b = .{ .pred = 1 } });
    s.add(.{ .op = .pnot, .ty = .pred, .a = .{ .pred = 0 } });
    s.add(.{ .op = .mov, .ty = .u32 });
    fillInts(s);
    s.runItems(name, .{});
}

fn caseIntI32(s: *Suite, name: []const u8) void {
    s.beginItems();
    for ([_]Op{ .iadd, .isub, .imul, .imulhi, .imad, .ineg, .iabs, .imin, .imax, .shl, .shr, .bfe }) |op|
        s.add(.{ .op = op, .ty = .i32 });
    for (0..6) |c| s.add(.{ .op = .icmp, .ty = .i32, .aux = @intCast(c) });
    s.add(.{ .op = .sel, .ty = .i32, .c = .{ .pred = 2 } });
    s.add(.{ .op = .mov, .ty = .i32 });
    fillInts(s);
    s.runItems(name, .{});
}

const int_imms = [_]u32{ 5, 511, 512, 0xffff_fe00, 0xffff_fffd, 0x1234_5678, 0x8000_0000, 31, 33, 0x00ff_ffff, 0x0100_0000, 1, 0, 0xffff_ffff };

fn caseIntImm(s: *Suite, name: []const u8) void {
    s.beginItems();
    const n = int_imms.len;
    for ([_]Ty{ .u32, .i32 }, 0..) |ty, ti| {
        for ([_]Op{ .iadd, .isub, .imul, .imulhi, .imin, .imax, .@"and", .@"or", .xor, .shl, .shr }, 0..) |op, oi| {
            s.add(.{ .op = op, .ty = ty, .b = .{ .imm = int_imms[(oi * 2) % n] } });
            s.add(.{ .op = op, .ty = ty, .a = .{ .imm = int_imms[(oi * 2 + 1 + ti * 3) % n] } });
        }
        s.add(.{ .op = .imad, .ty = ty, .b = .{ .imm = int_imms[(ti + 5) % n] } });
        s.add(.{ .op = .imad, .ty = ty, .c = .{ .imm = int_imms[(ti + 2) % n] } });
        s.add(.{ .op = .imad, .ty = ty, .a = .{ .imm = 3 }, .c = .{ .imm = 0x7fff_fff0 } });
        for ([_][2]u32{ .{ 0, 8 }, .{ 8, 8 }, .{ 4, 12 }, .{ 16, 16 }, .{ 24, 8 }, .{ 31, 1 }, .{ 0, 32 }, .{ 5, 0 } }) |ow|
            s.add(.{ .op = .bfe, .ty = ty, .b = .{ .imm = ow[0] }, .c = .{ .imm = ow[1] } });
        s.add(.{ .op = .icmp, .ty = ty, .aux = @intFromEnum(kir.Cmp.lt), .b = .{ .imm = 100 } });
        s.add(.{ .op = .icmp, .ty = ty, .aux = @intFromEnum(kir.Cmp.ge), .a = .{ .imm = 0xffff_ffff } });
        s.add(.{ .op = .sel, .ty = ty, .a = .{ .imm = 0x1234_5678 }, .c = .{ .pred = 2 } });
        s.add(.{ .op = .ineg, .ty = ty, .a = .{ .imm = 7 } });
    }
    s.add(.{ .op = .mov, .ty = .u32, .a = .{ .imm = 0xdead_beef } });
    fillInts(s);
    s.runItems(name, .{ .lanes = 1024 });
}

fn caseDot4(s: *Suite, name: []const u8) void {
    s.beginItems();
    for (0..3) |m| {
        const aux: u32 = @intCast(m);
        s.add(.{ .op = .dot4, .ty = .u32, .aux = aux });
        s.add(.{ .op = .dot4, .ty = .i32, .aux = aux });
        s.add(.{ .op = .dot4, .ty = .u32, .aux = aux, .b = .{ .imm = 0x80ff_017f } });
        s.add(.{ .op = .dot4, .ty = .u32, .aux = aux, .c = .{ .imm = 0x7fff_ffff } });
        s.add(.{ .op = .dot4, .ty = .u32, .aux = aux, .a = .{ .imm = 0x0102_80ff }, .c = .{ .imm = 0 } });
    }
    fillInts(s);
    // (random bytes everywhere past the edges)
    for (int_edges.len * int_edges.len..IN_WORDS) |l| s.w.in[1][l] = s.rng.next();
    s.runItems(name, .{});
}

fn otherMad(c: Caps) Caps {
    var x = c;
    x.mad = if (c.mad == .fused) .unfused else .fused;
    return x;
}

fn caseFloat(s: *Suite, name: []const u8) void {
    s.beginItems();
    for ([_]Op{ .fadd, .fsub, .fmul, .fmad, .fmin, .fmax, .fabs, .fneg, .ffloor, .fceil, .ftrunc, .frne }) |op|
        s.add(.{ .op = op, .ty = .f32 });
    if (s.caps.fused_fma) s.add(.{ .op = .ffma, .ty = .f32 });
    for (0..6) |c| s.add(.{ .op = .fcmp, .ty = .f32, .aux = @intCast(c) });
    s.add(.{ .op = .sel, .ty = .f32, .c = .{ .pred = 2 } });
    s.add(.{ .op = .mov, .ty = .f32 });
    fillFloats(s);
    s.runItems(name, .{ .alt = otherMad(s.caps) });
}

fn caseFloatImm(s: *Suite, name: []const u8) void {
    s.beginItems();
    const F = struct {
        fn b(x: f32) Src {
            return .{ .imm = @bitCast(x) };
        }
    };
    s.add(.{ .op = .fadd, .ty = .f32, .b = F.b(1.5) });
    s.add(.{ .op = .fadd, .ty = .f32, .a = F.b(0.1) });
    s.add(.{ .op = .fsub, .ty = .f32, .b = .{ .imm = 0x7f80_0000 } });
    s.add(.{ .op = .fsub, .ty = .f32, .a = F.b(1.0) });
    s.add(.{ .op = .fmul, .ty = .f32, .b = F.b(3.0) });
    s.add(.{ .op = .fmul, .ty = .f32, .a = .{ .imm = 0x8000_0000 } });
    s.add(.{ .op = .fmul, .ty = .f32, .b = .{ .imm = 0x0000_0001 } });
    s.add(.{ .op = .fmin, .ty = .f32, .b = .{ .imm = 0x8000_0000 } });
    s.add(.{ .op = .fmax, .ty = .f32, .a = .{ .imm = 0x7fc0_0000 } });
    s.add(.{ .op = .fmax, .ty = .f32, .b = .{ .imm = 0x0080_0000 } });
    s.add(.{ .op = .fmad, .ty = .f32, .b = F.b(0.5), .c = F.b(1.0) });
    if (s.caps.fused_fma) s.add(.{ .op = .ffma, .ty = .f32, .b = F.b(-1.0 / 3.0) });
    s.add(.{ .op = .fcmp, .ty = .f32, .aux = @intFromEnum(kir.Cmp.lt), .b = F.b(1.0) });
    s.add(.{ .op = .fcmp, .ty = .f32, .aux = @intFromEnum(kir.Cmp.ge), .a = F.b(0.0) });
    s.add(.{ .op = .fcmp, .ty = .f32, .aux = @intFromEnum(kir.Cmp.ne), .b = .{ .imm = 0x7fc0_0000 } });
    s.add(.{ .op = .sel, .ty = .f32, .a = F.b(1.25), .c = .{ .pred = 2 } });
    s.add(.{ .op = .fabs, .ty = .f32, .a = .{ .imm = 0xffc0_0001 } });
    fillFloats(s);
    s.runItems(name, .{ .lanes = 1024, .alt = otherMad(s.caps) });
}

fn caseApprox(s: *Suite, name: []const u8) void {
    s.beginItems();
    s.add(.{ .op = .frcp, .ty = .f32, .a = .{ .reg = 0 } });
    s.add(.{ .op = .frsq, .ty = .f32, .a = .{ .reg = 1 } });
    s.add(.{ .op = .flog2, .ty = .f32, .a = .{ .reg = 1 } });
    s.add(.{ .op = .fexp2, .ty = .f32, .a = .{ .reg = 2 } });
    s.add(.{ .op = .fsin, .ty = .f32, .a = .{ .reg = 2 } });
    s.add(.{ .op = .fcos, .ty = .f32, .a = .{ .reg = 2 } });
    const in = &s.w.in;
    const sp0 = [_]u32{ 0, 0x8000_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0x3f80_0000, 0xbf80_0000, 0x7f7f_ffff, 0x0080_0000, 0x4000_0000, 0x3f00_0000, 0x4040_0000 };
    const sp1 = [_]u32{ 0, 0x8000_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xbf80_0000, 0x3f80_0000, 0x4000_0000, 0x3f00_0000, 0x4080_0000, 0x7f7f_ffff, 0x0080_0000, 0x3f7f_ffff, 0x3f80_0001 };
    const sp2 = [_]u32{ 0, 0x8000_0000, 0x3f80_0000, 0xbf80_0000, 0x4049_0fdb, 0xc049_0fdb, 0x3fc9_0fdb, 0x7fc0_0000, 0x42fe_0000, 0xc2fa_0000 };
    for (0..IN_WORDS) |l| {
        const g = &s.rng;
        // rcp: normals of both signs over every exponent
        in[0][l] = if (l < sp0.len) sp0[l] else (g.next() & 0x8000_0000) | ((1 + g.below(254)) << 23) | (g.next() & 0x007f_ffff);
        // rsq, log2: positive, half of them in [0.5, 2]
        in[1][l] = if (l < sp1.len) sp1[l] else if (l & 1 == 0) ((126 + g.below(2)) << 23) | (g.next() & 0x007f_ffff) else ((1 + g.below(254)) << 23) | (g.next() & 0x007f_ffff);
        // sin, cos: [-pi, pi]; exp2: [-120, 120] in the upper half
        const unit: f32 = @as(f32, @floatFromInt(g.next() >> 8)) / 16777216.0 * 2.0 - 1.0;
        in[2][l] = if (l < sp2.len) sp2[l] else if (l < LANES / 2) bits(unit * 3.14159274) else bits(unit * 120.0);
    }
    s.runItems(name, .{});
}

/// x such that x * 2^k / m is nearest a rounding midpoint (inverse mod m)
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

fn caseExact(s: *Suite, name: []const u8) void {
    s.beginItems();
    s.add(.{ .op = .fdiv, .ty = .f32 });
    s.add(.{ .op = .fsqrt, .ty = .f32, .a = .{ .reg = 2 } });
    s.add(.{ .op = .fdiv, .ty = .f32, .b = .{ .imm = 0x4040_0000 } });
    s.add(.{ .op = .fdiv, .ty = .f32, .a = .{ .imm = 0x3f80_0000 } });
    const in = &s.w.in;
    const g = &s.rng;
    const sp = [_]u32{
        0x0000_0000, 0x8000_0000, 0x0000_0001, 0x8000_0001, 0x0040_0000, 0x007f_ffff, 0x0080_0000, 0x0080_0001,
        0x3f80_0000, 0xbf80_0000, 0x3f80_0001, 0x3fff_ffff, 0x4000_0000, 0x3f7f_ffff, 0x4040_0000, 0x4049_0fdb,
        0x3dcc_cccd, 0x7f7f_ffff, 0xff7f_ffff, 0x7f00_0000, 0x0100_0000, 0x2780_0000, 0x5800_0000, 0x7f80_0000,
        0xff80_0000, 0x7fc0_0000, 0x4b80_0000, 0x3380_0000, 0x0d80_0000, 0x7180_0000, 0x57ff_ffff, 0x277f_ffff,
    };
    var l: usize = 0;
    // every special against every special
    for (sp) |a| for (sp) |b| {
        in[0][l] = a;
        in[1][l] = b;
        l += 1;
    };
    // quotients nearest a rounding midpoint
    var mb: i64 = (1 << 23) + 1 + 2 * @as(i64, g.below(64));
    while (l + 12 <= 2560 and mb < (1 << 24)) : (mb += 2 * 2741) {
        const inv24 = modinv(1 << 24, mb);
        const inv25 = modinv(1 << 25, mb);
        for ([_]i64{ 1, -1, 2, -2, 3, -3 }) |dd| for ([_]i64{ inv24, inv25 }) |inv| {
            var ma = @mod(dd * inv, mb);
            while (ma < (1 << 23)) ma += mb;
            if (ma >= (1 << 24)) continue;
            const ea: u32 = 64 + g.below(128);
            const eb: u32 = 64 + g.below(128);
            in[0][l] = (g.next() & 0x8000_0000) | (ea << 23) | @as(u32, @intCast(ma - (1 << 23)));
            in[1][l] = (eb << 23) | @as(u32, @intCast(mb - (1 << 23)));
            l += 1;
        };
    }
    // the slow path: gradual underflow, overflow, denormal operands
    while (l < 3584) : (l += 1) {
        const ma = g.next() & 0x007f_ffff;
        const mb2 = g.next() & 0x007f_ffff;
        switch (l & 3) {
            0 => {
                in[0][l] = (g.below(31) << 23) | ma;
                in[1][l] = ((100 + g.below(61)) << 23) | mb2;
            },
            1 => {
                in[0][l] = ((200 + g.below(55)) << 23) | ma;
                in[1][l] = (g.below(81) << 23) | mb2;
            },
            2 => {
                in[0][l] = ma;
                in[1][l] = ((1 + g.below(254)) << 23) | mb2;
            },
            else => {
                in[0][l] = ((1 + g.below(254)) << 23) | ma;
                in[1][l] = mb2;
            },
        }
        in[0][l] |= g.next() & 0x8000_0000;
        in[1][l] |= g.next() & 0x8000_0000;
    }
    // random bit patterns
    while (l < IN_WORDS) : (l += 1) {
        in[0][l] = g.next();
        in[1][l] = g.next();
    }
    // square roots: specials, roots nearest a midpoint, a stride through
    // [1, 4) at even scalings, denormals, random bits
    for (0..IN_WORDS) |q| {
        in[2][q] = if (q < sp.len) sp[q] else switch (q % 4) {
            0 => blk: {
                // (2k+1)^2 / 2^25 is nearest a midpoint's square
                const odd: u64 = (@as(u64, 1) << 24) | (@as(u64, g.next() & 0x7f_ffff) << 1) | 1;
                const sq = (odd * odd) >> 25;
                const m: u32 = @truncate(sq + g.below(3));
                // m in [2^23, 2^25): an exponent of 0 or 1 over [1, 4)
                const e: u32 = if (m >= (1 << 24)) 128 else 127;
                const mant: u32 = if (m >= (1 << 24)) (m >> 1) & 0x7f_ffff else m & 0x7f_ffff;
                const k2: u32 = 2 * g.below(40);
                break :blk ((e + k2 - 40) << 23) | mant;
            },
            1 => 0x3f80_0000 +% @as(u32, @intCast(q)) *% 4099,
            2 => g.next() & 0x007f_ffff,
            else => g.next(),
        };
    }
    s.runItems(name, .{});
}

fn cvtAux(from: Ty, to: Ty, round: kir.Round) u32 {
    return @bitCast(kir.Cvt{ .from = from, .to = to, .round = round });
}

fn fillCvt(s: *Suite) void {
    const in = &s.w.in;
    const g = &s.rng;
    const fsp = [_]u32{
        0, 0x8000_0000, 0x3f00_0000, 0xbf00_0000, 0x3fc0_0000, 0xbfc0_0000, 0x4020_0000, 0xc020_0000,
        0x3eff_ffff, 0x3f80_0000, 0xbf80_0000, 0x4f00_0000, 0xcf00_0000, 0x4f80_0000, 0x4f7f_ffff, 0xcf00_0001,
        0xd015_02f9, 0x5015_02f9, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0xffc0_0001, 0x0000_0001, 0x807f_ffff,
        0x477f_e000, 0x477f_efff, 0x477f_f000, 0x4780_0000, 0x3880_0000, 0x3380_0000, 0x3300_0000, 0x3300_0001,
        0x3280_0000, 0x3f80_1000, 0x3f80_3000, 0x3f80_0fff, 0xc77f_f000, 0x387f_c000, 0x4b00_0001, 0xcb7f_ffff,
    };
    const isp = [_]u32{ 0, 1, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 0x0100_0001, 0x0100_0003, 0x0100_0002, 0xff00_0001, 0x7fff_ffc0, 0x7fff_ff80, 0xffff_ff7f, 0x8000_0001, 0x00ff_ffff, 0xfeff_ffff };
    const hsp = [_]u32{ 0, 0x8000, 0x0001, 0x8001, 0x03ff, 0x0400, 0x7bff, 0xfbff, 0x7c00, 0xfc00, 0x7e00, 0x7c01, 0xfe01, 0x3c00, 0x3555 };
    for (0..IN_WORDS) |l| {
        in[0][l] = if (l < fsp.len) fsp[l] else switch (l % 4) {
            // integers and halves, both signs, to 2^20
            0 => bits(@as(f32, @floatFromInt(@as(i32, @bitCast(g.next())) >> 11)) + @as(f32, @floatFromInt(g.below(4))) * 0.25),
            // f16's range, its subnormals and its overflow
            1 => (g.next() & 0x8000_0000) | ((98 + g.below(46)) << 23) | (g.next() & 0x007f_ffff),
            // near 2^31 and 2^32
            2 => ((157 + g.below(3)) << 23) | (g.next() & 0x007f_ffff) | (g.next() & 0x8000_0000),
            else => g.next(),
        };
        in[1][l] = if (l < isp.len) isp[l] else switch (l % 3) {
            0 => g.next(),
            1 => g.next() >> @as(u5, @intCast(g.below(32))),
            else => (g.next() >> 7) | 1,
        };
        // f16 patterns through the whole space, garbage above half the time
        const h: u32 = if (l < hsp.len) hsp[l] else @as(u32, @intCast(l)) *% 16 +% @as(u32, @intCast(l % 16)) & 0xffff;
        in[2][l] = h | (if (l & 1 == 1) g.next() & 0xffff_0000 else 0);
    }
}

fn caseCvt(s: *Suite, name: []const u8, round: kir.Round) void {
    s.beginItems();
    s.add(.{ .op = .cvt, .ty = .u32, .aux = cvtAux(.f32, .u32, round) });
    s.add(.{ .op = .cvt, .ty = .i32, .aux = cvtAux(.f32, .i32, round) });
    s.add(.{ .op = .cvt, .ty = .f32, .aux = cvtAux(.u32, .f32, round), .a = .{ .reg = 1 } });
    s.add(.{ .op = .cvt, .ty = .f32, .aux = cvtAux(.i32, .f32, round), .a = .{ .reg = 1 } });
    s.add(.{ .op = .cvt, .ty = .f16, .aux = cvtAux(.f32, .f16, round) });
    if (round == .rne) {
        s.add(.{ .op = .cvt, .ty = .f32, .aux = cvtAux(.f16, .f32, .rne), .a = .{ .reg = 2 } });
        s.add(.{ .op = .cvt, .ty = .i32, .aux = cvtAux(.u32, .i32, .rne), .a = .{ .reg = 1 } });
        s.add(.{ .op = .cvt, .ty = .u32, .aux = cvtAux(.i32, .u32, .rne), .a = .{ .reg = 1 } });
    }
    fillCvt(s);
    s.runItems(name, .{});
}

fn caseCvtRne(s: *Suite, name: []const u8) void {
    caseCvt(s, name, .rne);
}
fn caseCvtRz(s: *Suite, name: []const u8) void {
    caseCvt(s, name, .rz);
}
fn caseCvtRd(s: *Suite, name: []const u8) void {
    caseCvt(s, name, .rd);
}
fn caseCvtRu(s: *Suite, name: []const u8) void {
    caseCvt(s, name, .ru);
}

// ── Memory ──────────────────────────────────────────────────────────────────

fn fillRandom(s: *Suite) void {
    for (0..3) |j| for (0..IN_WORDS) |l| {
        s.w.in[j][l] = s.rng.next();
    };
}

fn memAt(bind: u8, bits_: u8, signed: bool, imm: u32) kir.Mem {
    var m = kir.global(bind, bits_);
    m.signed = signed;
    m.imm = @intCast(imm);
    return m;
}

fn caseLoads(s: *Suite, name: []const u8) void {
    const L = 4 * s.group;
    var k = s.begin(name, .{ s.group, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const o2 = k.op2(.shl, .u32, r(lane), u(1));
    const o8 = k.op2(.shl, .u32, r(lane), u(3));
    const o16 = k.op2(.shl, .u32, r(lane), u(4));
    var row: u32 = 0;
    const one = struct {
        fn st(kk: *kir.Kernel, o: V, rw: *u32, lanes: u32, ty: Ty, v: V) void {
            Suite.put(kk, o, rw.*, lanes, ty, v);
            rw.* += 1;
        }
    };
    one.st(&k, off, &row, L, .u32, k.load(.u32, memAt(IN0, 8, false, 3), r(lane)));
    one.st(&k, off, &row, L, .i32, k.load(.i32, memAt(IN0, 8, true, 3), r(lane)));
    one.st(&k, off, &row, L, .u32, k.load(.u32, memAt(IN0, 16, false, 2), r(o2)));
    one.st(&k, off, &row, L, .i32, k.load(.i32, memAt(IN0, 16, true, 2), r(o2)));
    one.st(&k, off, &row, L, .u32, k.load(.u32, memAt(IN0, 32, false, 4), r(off)));
    const v2 = k.load(.u32, memAt(IN1, 64, false, 8), r(o8));
    one.st(&k, off, &row, L, .u32, v2);
    one.st(&k, off, &row, L, .u32, kir.Kernel.at(v2, 1));
    const v4 = k.load(.u32, memAt(IN2, 128, false, 16), r(o16));
    for (0..4) |e| one.st(&k, off, &row, L, .u32, kir.Kernel.at(v4, @intCast(e)));
    one.st(&k, off, &row, L, .u32, k.load(.u32, memAt(IN1, 32, false, 0x8000), r(off)));
    one.st(&k, off, &row, L, .u32, k.load(.u32, memAt(IN2, 16, false, 0x6002), r(o2)));
    // (an f32 load and an address from a register sum)
    const f32v = k.load(.f32, memAt(IN0, 32, false, 0), r(k.op2(.iadd, .u32, r(off), u(64))));
    one.st(&k, off, &row, L, .f32, f32v);
    fillRandom(s);
    const words: usize = @as(usize, row) * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ L / s.group, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words }, &.{}, "");
}

fn caseStores(s: *Suite, name: []const u8) void {
    const L = 4 * s.group;
    var k = s.begin(name, .{ s.group, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const a = k.load(.u32, kir.global(IN0, 32), r(off));
    const b = k.load(.u32, kir.global(IN1, 32), r(off));
    const c = k.load(.u32, kir.global(IN2, 32), r(off));
    // bytes: [0, L) 8-bit, [L, 3L) 16-bit, [3L, 7L) 32, [7L, 15L) 64, [15L, 31L) 128
    k.store(.u32, kir.global(OUT, 8), r(lane), r(a));
    const o2 = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(lane), u(1))), u(L));
    k.store(.u32, kir.global(OUT, 16), r(o2), r(b));
    k.store(.u32, memAt(OUT, 32, false, 3 * L), r(off), r(c));
    const p2 = k.vec(.u32, 2);
    k.set(p2, .mov, r(a), no, no);
    k.set(kir.Kernel.at(p2, 1), .xor, r(b), u(0x0f0f_0f0f), no);
    k.store(.u32, memAt(OUT, 64, false, 7 * L), r(k.op2(.shl, .u32, r(lane), u(3))), r(p2));
    const p4 = k.vec(.u32, 4);
    k.set(p4, .mov, r(c), no, no);
    k.set(kir.Kernel.at(p4, 1), .mov, r(lane), no, no);
    k.set(kir.Kernel.at(p4, 2), .not, r(a), no, no);
    k.set(kir.Kernel.at(p4, 3), .iadd, r(b), r(c), no);
    const o16 = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(lane), u(4))), u(15 * L));
    k.store(.u32, kir.global(OUT, 128), r(o16), r(p4));
    // (an f32 store and a 16-bit store through an immediate offset)
    k.store(.f32, memAt(OUT, 32, false, 31 * L), r(off), r(k.mov(.f32, r(b))));
    k.store(.u32, memAt(OUT, 16, false, 35 * L + 2), r(k.op2(.shl, .u32, r(lane), u(2))), r(c));
    fillRandom(s);
    const words: usize = 36 * L / 4 + L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ L / s.group, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = 0, .words = words }, &.{}, "");
}

fn caseShared(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L = 4 * G;
    if (31 * G > s.caps.shared_bytes) return s.skip(name, "not enough shared memory");
    var k = s.begin(name, .{ G, 1, 1 });
    const sh32 = k.sharedAlloc(4 * G, 16);
    const sh8 = k.sharedAlloc(4 * G, 4);
    const sh16 = k.sharedAlloc(4 * G, 4);
    const sh64 = k.sharedAlloc(8 * G, 8);
    const sh128 = k.sharedAlloc(16 * G, 16);
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const t = k.tid(0);
    const t4 = k.op2(.shl, .u32, r(t), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const w1 = k.load(.u32, kir.global(IN1, 32), r(off));
    const w2 = k.load(.u32, kir.global(IN2, 32), r(off));
    const shAt = struct {
        fn m(bits_: u8, signed: bool, base: u32) kir.Mem {
            var x = kir.shared(bits_);
            x.signed = signed;
            x.imm = @intCast(base);
            return x;
        }
    }.m;
    k.store(.u32, shAt(32, false, sh32), r(t4), r(v));
    // each thread's sub-word stores stay in its own word (the race rule)
    const b8 = k.op2(.iadd, .u32, r(t4), r(k.op2(.@"and", .u32, r(t), u(3))));
    k.store(.u32, shAt(8, false, sh8), r(b8), r(k.op2(.xor, .u32, r(v), u(0x5a))));
    const b16 = k.op2(.iadd, .u32, r(t4), r(k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(t), u(1))), u(1))));
    k.store(.u32, shAt(16, false, sh16), r(b16), r(w1));
    const p2 = k.vec(.u32, 2);
    k.set(p2, .mov, r(v), no, no);
    k.set(kir.Kernel.at(p2, 1), .mov, r(w1), no, no);
    k.store(.u32, shAt(64, false, sh64), r(k.op2(.shl, .u32, r(t), u(3))), r(p2));
    const p4 = k.vec(.u32, 4);
    k.set(p4, .mov, r(v), no, no);
    k.set(kir.Kernel.at(p4, 1), .mov, r(w1), no, no);
    k.set(kir.Kernel.at(p4, 2), .mov, r(w2), no, no);
    k.set(kir.Kernel.at(p4, 3), .mov, r(t), no, no);
    k.store(.u32, shAt(128, false, sh128), r(k.op2(.shl, .u32, r(t), u(4))), r(p4));
    k.barrier();
    // a tree sum, a barrier each step, in a uniform loop
    const st = k.reg(.u32);
    k.set(st, .mov, u(G / 2), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .eq, r(st), u(0))));
    k.ifp(r(k.cmp(.u32, .lt, r(t), r(st))));
    const mine = k.load(.u32, shAt(32, false, sh32), r(t4));
    const theirs = k.load(.u32, shAt(32, false, sh32), r(k.op2(.shl, .u32, r(k.op2(.iadd, .u32, r(t), r(st))), u(2))));
    k.store(.u32, shAt(32, false, sh32), r(t4), r(k.op2(.iadd, .u32, r(mine), r(theirs))));
    k.endif();
    k.barrier();
    k.set(st, .shr, r(st), u(1), no);
    k.endloop();
    var row: u32 = 0;
    const put = struct {
        fn f(kk: *kir.Kernel, o: V, rw: *u32, lanes: u32, v_: V) void {
            Suite.put(kk, o, rw.*, lanes, tyOf(kk, v_), v_);
            rw.* += 1;
        }
    }.f;
    put(&k, off, &row, L, k.load(.u32, shAt(32, false, sh32), u(0)));
    const peek = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(k.op3(.imad, .u32, r(t), u(37), u(5))), u(G - 1))), u(2));
    put(&k, off, &row, L, k.load(.u32, shAt(32, false, sh32), r(peek)));
    const n1 = k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(t), u(1))), u(G - 1));
    const a8 = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(n1), u(2))), r(k.op2(.@"and", .u32, r(n1), u(3))));
    put(&k, off, &row, L, k.load(.u32, shAt(8, false, sh8), r(a8)));
    put(&k, off, &row, L, k.load(.i32, shAt(8, true, sh8), r(a8)));
    const n5 = k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(t), u(5))), u(G - 1));
    const a16 = k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(n5), u(2))), r(k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(n5), u(1))), u(1))));
    put(&k, off, &row, L, k.load(.u32, shAt(16, false, sh16), r(a16)));
    put(&k, off, &row, L, k.load(.i32, shAt(16, true, sh16), r(a16)));
    const d2 = k.load(.u32, shAt(64, false, sh64), r(k.op2(.shl, .u32, r(k.op2(.isub, .u32, u(G - 1), r(t))), u(3))));
    put(&k, off, &row, L, d2);
    put(&k, off, &row, L, kir.Kernel.at(d2, 1));
    const d4 = k.load(.u32, shAt(128, false, sh128), r(k.op2(.shl, .u32, r(k.op2(.xor, .u32, r(t), u(1))), u(4))));
    for (0..4) |e| put(&k, off, &row, L, kir.Kernel.at(d4, @intCast(e)));
    fillRandom(s);
    const words: usize = @as(usize, row) * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words, .show = 3 }, &.{}, "");
}

// ── Subgroups ───────────────────────────────────────────────────────────────

fn caseShuffles(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L = 4 * G;
    const sub = s.caps.subgroup;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const w1 = k.load(.u32, kir.global(IN1, 32), r(off));
    const w2 = k.load(.u32, kir.global(IN2, 32), r(off));
    const ln = k.lane();
    var row: u32 = 0;
    const P = struct {
        fn f(kk: *kir.Kernel, o: V, rw: *u32, lanes: u32, ty: Ty, v_: V) void {
            Suite.put(kk, o, rw.*, lanes, ty, v_);
            rw.* += 1;
        }
    };
    // idx: per-lane, uniform, and an unmasked register
    const src = k.op2(.@"and", .u32, r(k.op3(.imad, .u32, r(ln), u(5), u(3))), u(sub - 1));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .idx, r(v), r(src)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .idx, r(v), u(7 % sub)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .idx, r(v), r(w1)));
    // xor: every immediate mask, and a register
    var m: u32 = 1;
    while (m < sub) : (m <<= 1) P.f(&k, off, &row, L, .u32, k.shfl(.u32, .xor, r(v), u(m)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .xor, r(v), r(w1)));
    // up and down, immediates and registers, past the subgroup's edges
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .up, r(v), u(1)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .up, r(v), u(5)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .down, r(v), u(1)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .down, r(v), u(3)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .down, r(v), u(sub / 2)));
    const d = k.op2(.@"and", .u32, r(w2), u(2 * sub - 1));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .up, r(v), r(d)));
    P.f(&k, off, &row, L, .u32, k.shfl(.u32, .down, r(v), r(d)));
    // f32 (every bit moves, NaN payloads too)
    const fv = k.mov(.f32, r(v));
    P.f(&k, off, &row, L, .f32, k.shfl(.f32, .xor, r(fv), u(1)));
    P.f(&k, off, &row, L, .f32, k.shfl(.f32, .idx, r(fv), r(src)));
    // a butterfly sum over the whole subgroup
    const acc = k.reg(.u32);
    k.set(acc, .mov, r(v), no, no);
    m = 1;
    while (m < sub) : (m <<= 1) k.set(acc, .iadd, r(acc), r(k.shfl(.u32, .xor, r(acc), u(m))), no);
    P.f(&k, off, &row, L, .u32, acc);
    fillRandom(s);
    const words: usize = @as(usize, row) * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words, .show = 3 }, &.{}, "");
}

fn voteRow(k: *kir.Kernel, off: V, row: *u32, lanes: u32, mode: kir.Vote, p: V) void {
    Suite.put(k, off, row.*, lanes, .u32, k.sel(.u32, r(k.vote(mode, r(p))), u(1), u(0)));
    row.* += 1;
}

fn caseVotes(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L = 4 * G;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const ln = k.lane();
    const t = k.tid(0);
    var row: u32 = 0;
    const preds = [_]V{
        k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(v), u(1))), u(0)),
        k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(v), u(0x3ff))), u(0)),
        k.cmp(.u32, .ne, r(v), u(0x1234_5678)),
        k.cmp(.u32, .lt, r(ln), u(5)),
        k.cmp(.u32, .lt, r(t), u(100)),
        k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(k.gid(0)), u(1))), u(0)),
    };
    for (preds) |p| {
        voteRow(&k, off, &row, L, .any, p);
        voteRow(&k, off, &row, L, .all, p);
    }
    fillRandom(s);
    // (a few subgroups whose bit 0 is all ones or all zeros)
    for (0..s.caps.subgroup) |l| {
        if (l < IN_WORDS) s.w.in[0][l] |= 1;
        if (s.caps.subgroup + l < IN_WORDS) s.w.in[0][s.caps.subgroup + l] &= ~@as(u32, 1);
    }
    const words: usize = @as(usize, row) * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words, .show = 1 }, &.{}, "");
}

// ── Atomics ─────────────────────────────────────────────────────────────────

const atom_ops = [_]struct { kind: kir.Atom, ty: Ty }{
    .{ .kind = .add, .ty = .u32 }, .{ .kind = .min, .ty = .u32 }, .{ .kind = .max, .ty = .u32 }, .{ .kind = .xchg, .ty = .u32 },
    .{ .kind = .add, .ty = .i32 }, .{ .kind = .min, .ty = .i32 }, .{ .kind = .max, .ty = .i32 }, .{ .kind = .xchg, .ty = .i32 },
    .{ .kind = .@"and", .ty = .u32 }, .{ .kind = .@"or", .ty = .u32 }, .{ .kind = .xor, .ty = .u32 },
};
const contended = [_]struct { kind: kir.Atom, ty: Ty, init: u32 }{
    .{ .kind = .add, .ty = .u32, .init = 0 },
    .{ .kind = .min, .ty = .u32, .init = 0xffff_ffff },
    .{ .kind = .max, .ty = .u32, .init = 0 },
    .{ .kind = .min, .ty = .i32, .init = 0x7fff_ffff },
    .{ .kind = .max, .ty = .i32, .init = 0x8000_0000 },
};

fn caseAtomics(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L: u32 = 4 * G;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const CNT = 2 * @as(u32, atom_ops.len) * L;
    const TICK = CNT + 128;
    const SLOTS = TICK + 1;
    // each lane its own word: the old values are the first contents
    for (atom_ops, 0..) |a, q| {
        const val = k.op2(.xor, .u32, r(v), u(@as(u32, @intCast(q)) *% 0x1111_1111));
        const o = k.op2(.iadd, .u32, r(off), u(@as(u32, @intCast(q)) * L * 4));
        const old = k.atomic(a.ty, a.kind, kir.global(OUT, 32), r(o), r(val));
        Suite.put(&k, off, @intCast(atom_ops.len + q), L, .u32, old);
    }
    // the whole grid on 16 words of each kind: only the end is defined
    const slot4 = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(lane), u(15))), u(2));
    for (contended, 0..) |c, j| {
        const o = k.op2(.iadd, .u32, r(slot4), u((CNT + @as(u32, @intCast(j)) * 16) * 4));
        _ = k.atomic(c.ty, c.kind, kir.global(OUT, 32), r(o), r(if (c.kind == .add) k.op2(.@"and", .u32, r(v), u(0xffff)) else v));
    }
    // tickets: every old value of one counter, each exactly once
    const ticket = k.atomic(.u32, .add, kir.global(OUT, 32), u(TICK * 4), u(1));
    k.ifp(r(k.cmp(.u32, .lt, r(ticket), u(L))));
    k.store(.u32, kir.global(OUT, 32), r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(ticket), u(2))), u(SLOTS * 4))), u(1));
    k.endif();
    fillRandom(s);
    const words: usize = SLOTS + L;
    fillPattern(s.w.want[0..words]);
    for (contended, 0..) |c, j| for (0..16) |e| {
        s.w.want[CNT + j * 16 + e] = c.init;
    };
    s.w.want[TICK] = 0;
    @memset(s.w.want[SLOTS..][0..L], 0);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = 0, .words = words }, &.{}, "");
}

/// Compare-and-swap (each lane's own word: swapped where its guess is
/// right, kept where not; a counter the whole grid increments by CAS
/// loops) and ballots (the whole subgroup, the second word, divergent).
fn caseCas(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L: u32 = 4 * G;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const w1 = k.load(.u32, kir.global(IN1, 32), r(off));
    const cur = k.load(.u32, kir.global(OUT, 32), r(off));
    const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(lane), u(1))), u(0));
    const guess = k.sel(.u32, r(odd), r(cur), r(k.op2(.xor, .u32, r(cur), u(1))));
    const old = k.cas(.u32, kir.global(OUT, 32), r(off), r(guess), r(w1));
    Suite.put(&k, off, 1, L, .u32, old);
    const p = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(v), u(1))), u(0));
    Suite.put(&k, off, 2, L, .u32, k.ballot(r(p), 0));
    Suite.put(&k, off, 3, L, .u32, k.ballot(r(p), 1));
    k.ifp(r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(w1), u(2))), u(0))));
    Suite.put(&k, off, 4, L, .u32, k.ballot(r(p), 0));
    k.endif();
    const CNT = 5 * L;
    const exp = k.mov(.u32, u(0));
    k.loop();
    const got = k.cas(.u32, kir.global(OUT, 32), u(CNT * 4), r(exp), r(k.op2(.iadd, .u32, r(exp), u(1))));
    k.brk(r(k.cmp(.u32, .eq, r(got), r(exp))));
    k.set(exp, .mov, r(got), no, no);
    k.endloop();
    fillRandom(s);
    const words: usize = CNT + 1;
    fillPattern(s.w.want[0..words]);
    s.w.want[CNT] = 0;
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = 0, .words = words }, &.{}, "");
}

fn caseSharedAtomics(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L: u32 = 4 * G;
    var k = s.begin(name, .{ G, 1, 1 });
    const sh = k.sharedAlloc(64 + 4 * G, 16);
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const t = k.tid(0);
    const t4 = k.op2(.shl, .u32, r(t), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const w1 = k.load(.u32, kir.global(IN1, 32), r(off));
    var S = kir.shared(32);
    S.imm = @intCast(sh);
    var P = kir.shared(32);
    P.imm = @intCast(sh + 64);
    // counters: 4 add, 4 max u32, 4 min i32, 1 ticket
    k.ifp(r(k.cmp(.u32, .lt, r(t), u(13))));
    const first = k.sel(.u32, r(k.cmp(.u32, .lt, r(t), u(8))), u(0), u(0x7fff_ffff));
    k.store(.u32, S, r(t4), r(k.sel(.u32, r(k.cmp(.u32, .eq, r(t), u(12))), u(0), r(first))));
    k.endif();
    k.store(.u32, P, r(t4), r(v));
    k.barrier();
    const q4 = k.op2(.shl, .u32, r(k.op2(.@"and", .u32, r(t), u(3))), u(2));
    _ = k.atomic(.u32, .add, S, r(q4), r(k.op2(.@"and", .u32, r(v), u(0xfff))));
    _ = k.atomic(.u32, .max, S, r(k.op2(.iadd, .u32, r(q4), u(16))), r(v));
    _ = k.atomic(.i32, .min, S, r(k.op2(.iadd, .u32, r(q4), u(32))), r(w1));
    const ticket = k.atomic(.u32, .add, S, u(48), u(1));
    // (this group's tickets: each slot once)
    k.ifp(r(k.cmp(.u32, .lt, r(ticket), u(G))));
    const slot = k.op3(.imad, .u32, r(k.gid(0)), u(G), r(ticket));
    k.store(.u32, kir.global(OUT, 32), r(k.op2(.shl, .u32, r(k.op2(.iadd, .u32, r(slot), u(64))), u(2))), u(1));
    k.endif();
    // its own word: the old value is defined
    const old = k.atomic(.u32, .xchg, P, r(t4), r(w1));
    Suite.put(&k, k.op2(.iadd, .u32, r(off), u(64 * 4)), 1, L, .u32, old);
    Suite.put(&k, k.op2(.iadd, .u32, r(off), u(64 * 4)), 2, L, .u32, k.load(.u32, P, r(t4)));
    k.barrier();
    k.ifp(r(k.cmp(.u32, .lt, r(t), u(13))));
    k.store(.u32, kir.global(OUT, 32), r(k.op2(.shl, .u32, r(k.op3(.imad, .u32, r(k.gid(0)), u(16), r(t))), u(2))), r(k.load(.u32, S, r(t4))));
    k.endif();
    fillRandom(s);
    const words: usize = 64 + 3 * L;
    fillPattern(s.w.want[0..words]);
    @memset(s.w.want[64..][0..L], 0);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = 0, .words = words }, &.{}, "");
}

// ── Control flow ────────────────────────────────────────────────────────────

fn caseDivergentIf(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L = 4 * G;
    const sub = s.caps.subgroup;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const c = k.load(.u32, kir.global(IN1, 32), r(off));
    const ln = k.lane();
    const bit = struct {
        fn f(kk: *kir.Kernel, x: V, m: u32) V {
            return kk.cmp(.u32, .ne, r(kk.op2(.@"and", .u32, r(x), u(m))), u(0));
        }
    }.f;
    // 1. data-dependent nesting
    const acc = k.reg(.u32);
    k.set(acc, .mov, u(0), no, no);
    k.ifp(r(bit(&k, c, 1)));
    k.set(acc, .iadd, r(v), u(1), no);
    k.ifp(r(bit(&k, c, 2)));
    k.set(acc, .imul, r(acc), u(3), no);
    k.els();
    k.set(acc, .xor, r(acc), u(0x55), no);
    k.endif();
    k.ifp(r(bit(&k, c, 4)));
    k.set(acc, .shl, r(acc), u(1), no);
    k.endif();
    k.els();
    k.set(acc, .isub, r(v), u(7), no);
    k.ifp(r(bit(&k, c, 8)));
    k.set(acc, .not, r(acc), no, no);
    k.endif();
    k.endif();
    Suite.put(&k, off, 0, L, .u32, acc);
    // 2. shuffles and votes in both branches of a lane-parity if
    const sx = k.reg(.u32);
    const va = k.reg(.u32);
    const si = k.reg(.u32);
    k.ifp(r(k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(ln), u(1))), u(0))));
    k.emit(.{ .op = .shfl, .ty = .u32, .dst = sx, .a = r(v), .b = u(2), .c = no, .aux = @intFromEnum(kir.Shfl.xor) });
    k.set(va, .sel, u(1), u(0), r(k.vote(.any, r(bit(&k, v, 3)))));
    k.emit(.{ .op = .shfl, .ty = .u32, .dst = si, .a = r(v), .b = r(k.op2(.@"and", .u32, r(ln), u(0xffff_fffc))), .c = no, .aux = @intFromEnum(kir.Shfl.idx) });
    k.els();
    k.emit(.{ .op = .shfl, .ty = .u32, .dst = sx, .a = r(v), .b = u(6), .c = no, .aux = @intFromEnum(kir.Shfl.xor) });
    k.set(va, .sel, u(1), u(0), r(k.vote(.all, r(bit(&k, v, 3)))));
    k.emit(.{ .op = .shfl, .ty = .u32, .dst = si, .a = r(v), .b = r(k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(ln), u(0xffff_fffc))), u(1))), .c = no, .aux = @intFromEnum(kir.Shfl.idx) });
    k.endif();
    Suite.put(&k, off, 1, L, .u32, sx);
    Suite.put(&k, off, 2, L, .u32, va);
    Suite.put(&k, off, 3, L, .u32, si);
    // 3. after the endif the whole subgroup again (reconvergence)
    const post = k.shfl(.u32, .xor, r(k.op2(.iadd, .u32, r(sx), r(si))), u(1));
    Suite.put(&k, off, 4, L, .u32, post);
    Suite.put(&k, off, 5, L, .u32, k.sel(.u32, r(k.vote(.all, r(bit(&k, post, 0xff)))), u(1), u(0)));
    // 4. a block of the first 16 lanes: shuffles within it, a vote
    const q = k.reg(.u32);
    k.set(q, .mov, u(0), no, no);
    if (sub >= 16) {
        k.ifp(r(k.cmp(.u32, .lt, r(ln), u(16))));
        const t1 = k.shfl(.u32, .xor, r(v), u(8));
        const t2 = k.shfl(.u32, .up, r(t1), u(1));
        const any = k.vote(.any, r(k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(t2), u(7))), u(0))));
        k.set(q, .iadd, r(t1), r(t2), no);
        k.set(q, .xor, r(q), r(k.sel(.u32, r(any), u(0x8000_0000), u(0))), no);
        k.endif();
    }
    Suite.put(&k, off, 6, L, .u32, q);
    // 5. an early ret
    k.ifp(r(bit(&k, c, 0x10)));
    Suite.put(&k, off, 7, L, .u32, k.mov(.u32, u(0x1234)));
    k.ret();
    k.endif();
    Suite.put(&k, off, 7, L, .u32, k.op2(.iadd, .u32, r(post), u(1)));
    fillRandom(s);
    const words: usize = 8 * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words, .show = 2 }, &.{}, "");
}

fn caseLoops(s: *Suite, name: []const u8) void {
    const G = s.group;
    const L = 4 * G;
    var k = s.begin(name, .{ G, 1, 1 });
    const lane = s.linear(&k);
    const off = k.op2(.shl, .u32, r(lane), u(2));
    const v = k.load(.u32, kir.global(IN0, 32), r(off));
    const c = k.load(.u32, kir.global(IN1, 32), r(off));
    const ln = k.lane();
    // 1. per-lane trip counts, brk and cont, a vote among the lanes still
    //    in the loop, a predicate carried from one turn to the next
    const n = k.op2(.@"and", .u32, r(c), u(31));
    const i = k.reg(.u32);
    const acc = k.reg(.u32);
    const p = k.reg(.pred);
    const votes = k.reg(.u32);
    k.set(i, .mov, u(0), no, no);
    k.set(acc, .mov, r(v), no, no);
    k.set(p, .mov, u(0), no, no);
    k.set(votes, .mov, u(0), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .ge, r(i), r(n))));
    k.ifp(r(p));
    k.set(acc, .iadd, r(acc), r(i), no);
    k.els();
    k.set(acc, .xor, r(acc), r(k.op2(.imul, .u32, r(i), u(3))), no);
    k.endif();
    k.setAux(p, .icmp, r(k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(i), r(v))), u(3))), u(0), no, @intFromEnum(kir.Cmp.eq));
    k.set(i, .iadd, r(i), u(1), no);
    k.cont(r(k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(i), u(7))), u(3))));
    k.set(acc, .imad, r(acc), u(5), u(1));
    const any = k.vote(.any, r(k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(acc), u(1))), u(0))));
    k.set(votes, .iadd, r(votes), r(k.sel(.u32, r(any), u(1), u(0))), no);
    k.endloop();
    Suite.put(&k, off, 0, L, .u32, acc);
    Suite.put(&k, off, 1, L, .u32, votes);
    Suite.put(&k, off, 2, L, .u32, k.sel(.u32, r(p), u(1), u(0)));
    Suite.put(&k, off, 3, L, .u32, i);
    // 2. trip counts by quad: shuffles inside the divergent loop
    const m = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(ln), u(2))), u(7));
    const j = k.reg(.u32);
    const qs = k.reg(.u32);
    k.set(j, .mov, u(0), no, no);
    k.set(qs, .mov, r(v), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .ge, r(j), r(m))));
    const x1 = k.shfl(.u32, .xor, r(qs), u(1));
    const x2 = k.shfl(.u32, .xor, r(qs), u(2));
    k.set(qs, .iadd, r(k.op2(.xor, .u32, r(x1), r(j))), r(x2), no);
    k.set(j, .iadd, r(j), u(1), no);
    k.endloop();
    Suite.put(&k, off, 4, L, .u32, qs);
    // 3. nested loops: a uniform outer one, a per-lane inner one left
    //    from inside an if
    const o = k.reg(.u32);
    const tot = k.reg(.u32);
    const t = k.reg(.u32);
    k.set(o, .mov, u(0), no, no);
    k.set(tot, .mov, u(0), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .ge, r(o), u(3))));
    k.set(t, .mov, u(0), no, no);
    const bound = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(c), r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(o), u(2))), u(8))))), u(15));
    k.loop();
    const e = k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(k.op2(.xor, .u32, r(t), r(v))), u(7))), u(5));
    k.ifp(r(e));
    k.set(tot, .iadd, r(tot), u(100), no);
    k.brk(r(e));
    k.endif();
    k.brk(r(k.cmp(.u32, .ge, r(t), r(bound))));
    k.set(tot, .iadd, r(tot), r(k.op2(.imul, .u32, r(t), r(k.op2(.iadd, .u32, r(o), u(1))))), no);
    k.set(t, .iadd, r(t), u(1), no);
    k.endloop();
    k.set(o, .iadd, r(o), u(1), no);
    k.endloop();
    Suite.put(&k, off, 5, L, .u32, tot);
    // 4. a predicate carried round a loop with another loop inside
    const pp = k.reg(.pred);
    const cnt = k.reg(.u32);
    const jj = k.reg(.u32);
    const kk = k.reg(.u32);
    k.setAux(pp, .icmp, r(k.op2(.@"and", .u32, r(v), u(1))), u(0), no, @intFromEnum(kir.Cmp.ne));
    k.set(cnt, .mov, u(0), no, no);
    k.set(jj, .mov, u(0), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .ge, r(jj), u(4))));
    k.ifp(r(pp));
    k.set(cnt, .iadd, r(cnt), r(k.op2(.shl, .u32, u(1), r(jj))), no);
    k.endif();
    k.set(kk, .mov, u(0), no, no);
    k.loop();
    k.brk(r(k.cmp(.u32, .ge, r(kk), r(k.op2(.@"and", .u32, r(k.op2(.iadd, .u32, r(jj), r(c))), u(3))))));
    k.set(cnt, .iadd, r(cnt), u(0x100), no);
    k.set(kk, .iadd, r(kk), u(1), no);
    k.endloop();
    k.set(pp, .pnot, r(pp), no, no);
    k.set(jj, .iadd, r(jj), u(1), no);
    k.endloop();
    Suite.put(&k, off, 6, L, .u32, cnt);
    fillRandom(s);
    const words: usize = 7 * L;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, .{ 4, 1, 1 }, &.{}, words, null)) return;
    s.compare(name, .{ .lanes = L, .words = words, .show = 2 }, &.{}, "");
}

// ── The grid ────────────────────────────────────────────────────────────────

fn caseGrid(s: *Suite, name: []const u8) void {
    const grp = [3]u32{ 8, 4, 2 };
    const grid = [3]u32{ 3, 2, 2 };
    const T: u32 = 8 * 4 * 2;
    const N: u32 = T * 12;
    if (T > s.caps.max_group) return s.skip(name, "groups of 64 threads are too big");
    var k = s.begin(name, grp);
    const tx = k.tid(0);
    const ty = k.tid(1);
    const tz = k.tid(2);
    const gx = k.gid(0);
    const gy = k.gid(1);
    const gz = k.gid(2);
    const sx = k.gsize(0);
    const sy = k.gsize(1);
    const sz = k.gsize(2);
    const tl = k.op3(.imad, .u32, r(k.op3(.imad, .u32, r(tz), u(4), r(ty))), u(8), r(tx));
    const gl = k.op3(.imad, .u32, r(k.op3(.imad, .u32, r(gz), r(sy), r(gy))), r(sx), r(gx));
    const lin = k.op3(.imad, .u32, r(gl), u(T), r(tl));
    const p0 = k.param(.u32, 0);
    const p1 = k.param(.u32, 1);
    k.ifp(r(k.cmp(.u32, .lt, r(lin), u(N))));
    const off = k.op2(.shl, .u32, r(lin), u(2));
    const vals = [_]V{ tx, ty, tz, gx, gy, gz, sx, sy, sz, k.lane(), k.subgroupWidth(), k.op2(.iadd, .u32, r(p0), r(lin)), k.op2(.xor, .u32, r(p1), r(lin)) };
    for (vals, 0..) |x, row| Suite.put(&k, off, @intCast(row), N, .u32, x);
    k.endif();
    const words: usize = vals.len * N;
    fillPattern(s.w.want[0..words]);
    if (!s.execute(name, &k, grid, &.{ 0xc0ff_ee00, 0x1357_2468 }, words, null)) return;
    s.compare(name, .{ .lanes = N, .words = words }, &.{}, "");
}

// ── The probes (logged, never failing) ──────────────────────────────────────

fn probeMad(s: *Suite, name: []const u8) void {
    s.beginItems();
    s.add(.{ .op = .fmad, .ty = .f32 });
    const in = &s.w.in;
    for (0..IN_WORDS) |l| {
        const a = (126 << 23) | (s.rng.next() & 0x007f_ffff);
        const b = (127 << 23) | (s.rng.next() & 0x007f_ffff);
        in[0][l] = a;
        in[1][l] = b;
        // c = -(a*b) rounded: fused leaves the product's error, unfused 0
        in[2][l] = if (l & 1 == 0) bits(-(flt(a) * flt(b))) else saneFloat(&s.rng);
    }
    s.runItems(name, .{ .lanes = 1024, .alt = otherMad(s.caps), .probe = .mad });
}

fn probeDenormals(s: *Suite, name: []const u8) void {
    s.beginItems();
    s.add(.{ .op = .fadd, .ty = .f32, .b = .{ .imm = 0 } });
    s.add(.{ .op = .fmul, .ty = .f32, .b = .{ .imm = 0x3f80_0000 } });
    s.add(.{ .op = .fmul, .ty = .f32, .a = .{ .reg = 1 }, .b = .{ .reg = 2 } });
    s.add(.{ .op = .fmad, .ty = .f32, .b = .{ .imm = 0x3f80_0000 }, .c = .{ .imm = 0 } });
    const in = &s.w.in;
    for (0..IN_WORDS) |l| {
        in[0][l] = (s.rng.next() & 0x8000_0000) | (1 + s.rng.below(0x007f_ffff));
        // 2^-100 x 2^-30: products in gradual underflow
        in[1][l] = ((27 + s.rng.below(4)) << 23) | (s.rng.next() & 0x007f_ffff);
        in[2][l] = ((97 + s.rng.below(4)) << 23) | (s.rng.next() & 0x007f_ffff);
    }
    var other = s.caps;
    other.denormals = if (s.caps.denormals == .flush) .preserve else .flush;
    s.runItems(name, .{ .lanes = 1024, .alt = other, .probe = .denormals });
}

// ── Lines ───────────────────────────────────────────────────────────────────

const Line = struct {
    buf: [LINE_BYTES]u8 = undefined,
    n: usize = 0,

    fn s(l: *Line, x: []const u8) void {
        const k = @min(x.len, l.buf.len - l.n);
        @memcpy(l.buf[l.n..][0..k], x[0..k]);
        l.n += k;
    }
    fn ch(l: *Line, c: u8) void {
        if (l.n < l.buf.len) {
            l.buf[l.n] = c;
            l.n += 1;
        }
    }
    fn dec(l: *Line, x: u64) void {
        var tmp: [20]u8 = undefined;
        var n: usize = 0;
        var v = x;
        while (true) {
            tmp[n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (n > 0) {
            n -= 1;
            l.ch(tmp[n]);
        }
    }
    /// 0x and eight digits
    fn hex(l: *Line, x: u32) void {
        l.s("0x");
        var sh: u5 = 28;
        while (true) {
            l.ch("0123456789abcdef"[(x >> sh) & 15]);
            if (sh == 0) break;
            sh -= 4;
        }
    }
    /// 0x and no leading zeros
    fn hexShort(l: *Line, x: u32) void {
        l.s("0x");
        var started = false;
        var sh: u5 = 28;
        while (true) {
            const d = (x >> sh) & 15;
            if (d != 0 or started or sh == 0) {
                l.ch("0123456789abcdef"[d]);
                started = true;
            }
            if (sh == 0) break;
            sh -= 4;
        }
    }
    fn text(l: *const Line) []const u8 {
        return l.buf[0..l.n];
    }
};
