//! @zpm/adreno selftest — the compute bring-up tests, for any Device.
//!
//! Each test runs one small kernel and checks every result on the CPU, so
//! a first boot on new hardware says exactly what works: dispatch and the
//! ids, global loads and stores, both dp4acc modes (the integer dot product
//! the quantized kernels rest on), shuffles, local memory and barriers, the
//! SFU's accuracy. Then two measurements: memory bandwidth and ALU rate,
//! from the GPU's own timestamps.
//!
//! The same code runs on the emulated device (tests below) and on the
//! Surface through Galaxy's driver (its KLOG gets the lines).

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");
const a7xx = @import("a7xx.sig");
const device = @import("device.sig");

const Device = device.Device;
const Buffer = device.Buffer;

pub const Log = *const fn (line: []const u8) void;

pub const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// mad.f32 rounds once (fused, as the CPU's @mulAdd), twice, or neither
    /// matched every case.
    mad: enum { unknown, fused, unfused, mixed } = .unknown,
    /// Measured: GB/s reading memory, fp32 GFLOP/s (mad = 2 flops).
    read_gbps: f64 = 0,
    gflops: f64 = 0,
};

/// Working storage (static: holds the assembler's work list).
pub const Work = struct {
    asm_work: ir3_asm.Work = .{},
    line: [256]u8 = undefined,
};

const Ctx = struct {
    dev: Device,
    log: Log,
    w: *Work,
    code: Buffer,
    ib: Buffer,
    data: Buffer,
    data2: Buffer,
    out: Buffer,
    ts: Buffer,
    res: *Result,
    timeout_us: u64,

    fn say(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&c.w.line, fmt, args) catch return;
        c.log(s);
    }

    fn pass(c: *Ctx, name: []const u8, n: usize) void {
        c.res.passed += 1;
        c.say("compute {s}: ok ({d} checked)", .{ name, n });
    }

    fn fail(c: *Ctx, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        c.res.failed += 1;
        var tmp: [160]u8 = undefined;
        const why = std.fmt.bufPrint(&tmp, fmt, args) catch "?";
        c.say("compute {s}: FAILED: {s}", .{ name, why });
    }

    /// Assemble, build the stream (setup, program, constants, dispatch, a
    /// timestamp before and after), run it and wait.
    fn launch(c: *Ctx, name: []const u8, src: []const u8, consts: []const u32, groups: [3]u32) bool {
        const code: []u64 = @alignCast(std.mem.bytesAsSlice(u64, c.code.cpu));
        const k = ir3_asm.assemble(ir3.A7XX, src, &c.w.asm_work, code) catch |e| {
            c.fail(name, "assembly: {s} at line {d}", .{ @errorName(e), c.w.asm_work.err_line });
            return false;
        };
        c.dev.toDevice(c.code, 0, k.code.len * 8);
        var s = a7xx.Stream{ .buf = c.ib.words() };
        s.computeSetup();
        s.program(&k, c.code.va) catch {
            c.fail(name, "program", .{});
            return false;
        };
        s.constants(0, consts);
        s.timestamp(c.ts.va);
        s.dispatch(&k, groups);
        s.timestamp(c.ts.va + 8);
        s.cleanCaches();
        s.waitForIdle();
        s.check() catch {
            c.fail(name, "stream too long", .{});
            return false;
        };
        c.dev.run(c.ib, @intCast(s.len), c.timeout_us) catch |e| {
            c.fail(name, "GPU: {s}", .{@errorName(e)});
            return false;
        };
        c.dev.fromDevice(c.out, 0, c.out.cpu.len);
        c.dev.fromDevice(c.ts, 0, 16);
        return true;
    }

    /// GPU time of the last launch, in seconds.
    fn seconds(c: *Ctx) f64 {
        const t: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, c.ts.cpu[0..16]));
        const ticks = t[1] -% t[0];
        return @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(c.dev.timestamp_hz));
    }

    fn outU32(c: *Ctx) []const u32 {
        return @alignCast(std.mem.bytesAsSlice(u32, c.out.cpu));
    }
};

fn addr(b: Buffer) [2]u32 {
    return .{ @truncate(b.va), @truncate(b.va >> 32) };
}

fn lcg(state: *u32) u32 {
    state.* = state.* *% 1664525 +% 1013904223;
    return state.*;
}

/// Run every test. Buffers come from `dev`: 4 MB, and for the bandwidth
/// test (`bandwidth`) 64 MB more, or 16 MB when that is not to be had.
pub fn runAll(dev: Device, w: *Work, log: Log, bandwidth: bool) Result {
    var res = Result{};
    var c = Ctx{
        .dev = dev,
        .log = log,
        .w = w,
        .code = dev.alloc(64 * 1024) catch return failAlloc(log, &res),
        .ib = dev.alloc(64 * 1024) catch return failAlloc(log, &res),
        .data = dev.alloc(1 << 20) catch return failAlloc(log, &res),
        .data2 = dev.alloc(1 << 20) catch return failAlloc(log, &res),
        .out = dev.alloc(1 << 20) catch return failAlloc(log, &res),
        .ts = dev.alloc(4096) catch return failAlloc(log, &res),
        .res = &res,
        .timeout_us = 2_000_000,
    };
    testIds(&c, 64);
    testIds(&c, 128);
    testAdd(&c);
    testDp4(&c);
    testShfl(&c);
    testLocal(&c);
    testSfu(&c);
    testFloat(&c);
    testUnaligned(&c);
    if (bandwidth) testBandwidth(&c);
    testAlu(&c);
    c.say("compute self-test: {d} passed, {d} failed", .{ res.passed, res.failed });
    return res;
}

fn failAlloc(log: Log, res: *Result) Result {
    log("compute self-test: no GPU memory for its buffers");
    res.failed += 1;
    return res.*;
}

fn testIds(c: *Ctx, comptime threads: u32) void {
    const name = if (threads == 64) "ids (64-fiber waves)" else "ids (128-fiber waves)";
    const src = std.fmt.comptimePrint(
        \\@localsize 32, 4, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@threadsize {d}
        \\@consts 1
        \\; i = ((wg.y * 7 + wg.x) * 128) + lid.y * 32 + lid.x
        \\mul.u24 r1.x, r48.y, 7
        \\add.u r1.x, r1.x, r48.x
        \\shl.b r1.x, r1.x, 7
        \\shl.b r1.y, r0.y, 5
        \\add.u r1.x, r1.x, r1.y
        \\add.u r1.x, r1.x, r0.x
        \\shl.b r1.z, r1.x, 2
        \\; value: wg.x | wg.y << 8 | lid.x << 16 | lid.y << 24
        \\shl.b r2.x, r48.y, 8
        \\or.b r2.x, r2.x, r48.x
        \\shl.b r2.y, r0.x, 16
        \\or.b r2.x, r2.x, r2.y
        \\shl.b r2.y, r0.y, 24
        \\or.b r2.x, r2.x, r2.y
        \\stg.a.u32 g[c0.x+r1.z+0], r2.x, 1
        \\end
    , .{threads});
    const o = addr(c.out);
    @memset(c.out.cpu, 0);
    c.dev.toDevice(c.out, 0, c.out.cpu.len);
    if (!c.launch(name, src, &.{ o[0], o[1], 0, 0 }, .{ 7, 3, 1 })) return;
    const got = c.outU32();
    var n: usize = 0;
    for (0..3) |gy| for (0..7) |gx| for (0..4) |ly| for (0..32) |lx| {
        const i = ((gy * 7 + gx) * 128) + ly * 32 + lx;
        const want: u32 = @intCast(gx | gy << 8 | lx << 16 | ly << 24);
        if (got[i] != want) return c.fail(name, "word {d}: {x} want {x}", .{ i, got[i], want });
        n += 1;
    };
    c.pass(name, n);
}

fn testAdd(c: *Ctx) void {
    const name = "global loads and stores (f32 add)";
    const n = 64 * 1024;
    const a: []f32 = @alignCast(std.mem.bytesAsSlice(f32, c.data.cpu[0 .. n * 4]));
    const b: []f32 = @alignCast(std.mem.bytesAsSlice(f32, c.data2.cpu[0 .. n * 4]));
    for (a, b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = @as(f32, @floatFromInt(i % 977)) * 0.25 - 100.0;
    }
    c.dev.toDevice(c.data, 0, n * 4);
    c.dev.toDevice(c.data2, 0, n * 4);
    const da = addr(c.data);
    const db = addr(c.data2);
    const o = addr(c.out);
    if (!c.launch(name,
        \\@localsize 128, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\shl.b r1.x, r48.x, 7
        \\add.u r1.x, r1.x, r0.x
        \\shl.b r1.y, r1.x, 2
        \\ldg.a.f32 r2.x, g[c0.x+r1.y+0], 1
        \\ldg.a.f32 r2.y, g[c0.z+r1.y+0], 1
        \\add.f r2.z, r2.x, r2.y
        \\stg.a.f32 g[c1.x+r1.y+0], r2.z, 1
        \\end
    , &.{ da[0], da[1], db[0], db[1], o[0], o[1], 0, 0 }, .{ n / 128, 1, 1 })) return;
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, c.out.cpu[0 .. n * 4]));
    for (got, a, b, 0..) |g, x, y, i| {
        if (g != x + y) return c.fail(name, "element {d}: {d} want {d}", .{ i, g, x + y });
    }
    c.pass(name, n);
}

fn testDp4(c: *Ctx) void {
    const name = "dp4acc (unsigned and mixed)";
    const n = 4096;
    const in: []u32 = @alignCast(std.mem.bytesAsSlice(u32, c.data.cpu[0 .. n * 12]));
    var seed: u32 = 12345;
    for (in) |*v| v.* = lcg(&seed);
    c.dev.toDevice(c.data, 0, n * 12);
    const d = addr(c.data);
    const o = addr(c.out);
    // per fiber: a = in[3i], b = in[3i+1], acc = in[3i+2]
    if (!c.launch(name,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\shl.b r1.x, r48.x, 6
        \\add.u r1.x, r1.x, r0.x
        \\mul.u24 r1.y, r1.x, 12
        \\ldg.a.u32 r2.x, g[c0.x+r1.y+0], 3
        \\dp4acc.unsigned.low r3.x, r2.x, r2.y, r2.z
        \\dp4acc.mixed.low r3.y, r2.x, r2.y, r2.z
        \\shl.b r1.z, r1.x, 3
        \\stg.a.u32 g[c1.x+r1.z+0], r3.x, 2
        \\end
    , &.{ d[0], d[1], 0, 0, o[0], o[1], 0, 0 }, .{ n / 64, 1, 1 })) return;
    const got = c.outU32();
    for (0..n) |i| {
        const a = in[3 * i];
        const b = in[3 * i + 1];
        var du: i32 = @bitCast(in[3 * i + 2]);
        var dm: i32 = du;
        for (0..4) |k| {
            const ab: u8 = @truncate(a >> @intCast(8 * k));
            const bb: u8 = @truncate(b >> @intCast(8 * k));
            du +%= @as(i32, ab) * bb;
            dm +%= @as(i32, @as(i8, @bitCast(ab))) * bb;
        }
        if (got[2 * i] != @as(u32, @bitCast(du))) return c.fail(name, "unsigned, fiber {d}: {x} want {x}", .{ i, got[2 * i], @as(u32, @bitCast(du)) });
        if (got[2 * i + 1] != @as(u32, @bitCast(dm))) return c.fail(name, "mixed, fiber {d}: {x} want {x}", .{ i, got[2 * i + 1], @as(u32, @bitCast(dm)) });
    }
    c.pass(name, 2 * n);
}

fn testShfl(c: *Ctx) void {
    const name = "shuffles (wave sum)";
    const o = addr(c.out);
    if (!c.launch(name,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\; v = lid * 3 + wg
        \\mul.u24 r1.x, r0.x, 3
        \\add.u r1.x, r1.x, r48.x
        \\mov.u32u32 r1.y, 32
        \\loop:
        \\shfl.xor.u32 r1.z, r1.x, r1.y
        \\add.u r1.x, r1.x, r1.z
        \\shr.b r1.y, r1.y, 1
        \\cmps.u.ne p0.x, r1.y, 0
        \\br p0.x, #loop
        \\shl.b r2.x, r48.x, 6
        \\add.u r2.x, r2.x, r0.x
        \\shl.b r2.x, r2.x, 2
        \\stg.a.u32 g[c0.x+r2.x+0], r1.x, 1
        \\end
    , &.{ o[0], o[1], 0, 0 }, .{ 8, 1, 1 })) return;
    const got = c.outU32();
    for (0..8) |g| {
        const want: u32 = @intCast(3 * 63 * 64 / 2 + 64 * g);
        for (0..64) |l| if (got[g * 64 + l] != want) return c.fail(name, "group {d} fiber {d}: {d} want {d}", .{ g, l, got[g * 64 + l], want });
    }
    c.pass(name, 8 * 64);
}

fn testLocal(c: *Ctx) void {
    const name = "local memory and barrier";
    const o = addr(c.out);
    // 256 fibers write lid*5 to local[lid], barrier, read local[255-lid].
    if (!c.launch(name,
        \\@localsize 256, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@shared 1024
        \\@consts 1
        \\mul.u24 r1.x, r0.x, 5
        \\add.u r1.x, r1.x, r48.x
        \\shl.b r1.y, r0.x, 2
        \\stl.u32 l[r1.y], r1.x, 1
        \\bar
        \\fence.l.r.w
        \\sub.u r1.z, 255, r0.x
        \\shl.b r1.z, r1.z, 2
        \\ldl.u32 r2.x, l[r1.z], 1
        \\shl.b r2.y, r48.x, 8
        \\add.u r2.y, r2.y, r0.x
        \\shl.b r2.y, r2.y, 2
        \\stg.a.u32 g[c0.x+r2.y+0], r2.x, 1
        \\end
    , &.{ o[0], o[1], 0, 0 }, .{ 4, 1, 1 })) return;
    const got = c.outU32();
    for (0..4) |g| for (0..256) |l| {
        const want: u32 = @intCast((255 - l) * 5 + g);
        if (got[g * 256 + l] != want) return c.fail(name, "group {d} fiber {d}: {d} want {d}", .{ g, l, got[g * 256 + l], want });
    };
    c.pass(name, 4 * 256);
}

fn testSfu(c: *Ctx) void {
    const name = "SFU accuracy";
    const n = 1024;
    const x: []f32 = @alignCast(std.mem.bytesAsSlice(f32, c.data.cpu[0 .. n * 4]));
    for (x, 0..) |*v, i| v.* = 0.01 + @as(f32, @floatFromInt(i)) * (8.0 / @as(f32, n));
    c.dev.toDevice(c.data, 0, n * 4);
    const d = addr(c.data);
    const o = addr(c.out);
    if (!c.launch(name,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\shl.b r1.x, r48.x, 6
        \\add.u r1.x, r1.x, r0.x
        \\shl.b r1.y, r1.x, 2
        \\ldg.a.f32 r2.x, g[c0.x+r1.y+0], 1
        \\rcp r3.x, r2.x
        \\rsq r3.y, r2.x
        \\exp2 r3.z, r2.x
        \\log2 r3.w, r2.x
        \\sin r4.x, r2.x
        \\cos r4.y, r2.x
        \\sqrt r4.z, r2.x
        \\mov.f32f32 r4.w, r2.x
        \\shl.b r1.z, r1.x, 5
        \\stg.a.f32 g[c1.x+r1.z+0], r3.x, 4
        \\add.u r1.w, r1.z, 16
        \\stg.a.f32 g[c1.x+r1.w+0], r4.x, 4
        \\end
    , &.{ d[0], d[1], 0, 0, o[0], o[1], 0, 0 }, .{ n / 64, 1, 1 })) return;
    const got: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, c.out.cpu[0 .. n * 32]));
    var worst = [_]f64{0} ** 7;
    for (x, 0..) |v, i| {
        const r = [_]f64{ 1.0 / v, 1.0 / @sqrt(v), @exp2(v), @log2(v), @sin(v), @cos(v), @sqrt(v) };
        for (r, 0..) |want, k| {
            const g: f64 = got[i * 8 + k];
            // relative error, absolute near zero
            const err = @abs(g - want) / @max(@abs(want), 1e-2);
            worst[k] = @max(worst[k], err);
        }
        if (got[i * 8 + 7] != v) return c.fail(name, "passthrough {d}", .{i});
    }
    c.say("compute SFU worst relative error: rcp {e:.2} rsq {e:.2} exp2 {e:.2} log2 {e:.2} sin {e:.2} cos {e:.2} sqrt {e:.2}", .{ worst[0], worst[1], worst[2], worst[3], worst[4], worst[5], worst[6] });
    for (worst) |e| if (e > 1e-3) return c.fail(name, "error above 1e-3", .{});
    c.pass(name, n * 7);
}

/// What the float units round like: the quantized kernels match the CPU
/// bit for bit only where mul.f and add.f round to nearest even, rndne.f
/// and cov.f32f16 (even) do what the CPU's nearestInt and f16 cast do, and
/// mad.f32 rounds as the CPU's @mulAdd does (once) or as a*b+c does (twice).
fn testFloat(c: *Ctx) void {
    const name = "float rounding (mul, add, mad, rndne, f32->f16)";
    const n = 2048;
    const in: []u32 = @alignCast(std.mem.bytesAsSlice(u32, c.data.cpu[0 .. n * 12]));
    var seed: u32 = 777;
    for (0..n) |i| {
        // a, b with full mantissas; c near -a*b so a fused mad differs
        const a: f32 = @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 * 8.0 - 4.0;
        const b: f32 = @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0 * 8.0 - 4.0;
        const jitter: f32 = @as(f32, @floatFromInt(lcg(&seed) >> 20)) * 1e-7;
        const cc: f32 = if (i % 2 == 0) -(a * b) + jitter else @as(f32, @floatFromInt(lcg(&seed) >> 8)) / 16777216.0;
        in[3 * i] = @bitCast(a);
        in[3 * i + 1] = @bitCast(b);
        in[3 * i + 2] = @bitCast(cc);
    }
    c.dev.toDevice(c.data, 0, n * 12);
    const d = addr(c.data);
    const o = addr(c.out);
    if (!c.launch(name,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\shl.b r1.x, r48.x, 6
        \\add.u r1.x, r1.x, r0.x
        \\mul.u24 r1.y, r1.x, 12
        \\ldg.a.f32 r2.x, g[c0.x+r1.y+0], 3
        \\mul.f r3.x, r2.x, r2.y
        \\add.f r3.y, r2.x, r2.y
        \\mad.f32 r3.z, r2.x, r2.y, r2.z
        \\mul.f r4.x, r2.x, (4.0)
        \\mul.f r4.x, r4.x, (4.0)
        \\mul.f r4.x, r4.x, (4.0)
        \\rndne.f r4.y, r4.x
        \\cov.f32s32 r3.w, r4.y
        \\cov.f32f16 (even)hr10.x, r2.x
        \\cov.f32f16 hr10.y, r2.x
        \\cov.u16u32 r4.z, hr10.x
        \\cov.u16u32 r4.w, hr10.y
        \\shl.b r1.z, r1.x, 5
        \\stg.a.u32 g[c1.x+r1.z+0], r3.x, 4
        \\add.u r1.w, r1.z, 16
        \\stg.a.u32 g[c1.x+r1.w+0], r4.x, 4
        \\end
    , &.{ d[0], d[1], 0, 0, o[0], o[1], 0, 0 }, .{ n / 64, 1, 1 })) return;
    const got = c.outU32();
    var mul_ok: u32 = 0;
    var add_ok: u32 = 0;
    var fused: u32 = 0;
    var unfused: u32 = 0;
    var round_ok: u32 = 0;
    var f16_even: u32 = 0;
    var f16_default_even: u32 = 0;
    var f16_default_rtz: u32 = 0;
    for (0..n) |i| {
        const a: f32 = @bitCast(in[3 * i]);
        const b: f32 = @bitCast(in[3 * i + 1]);
        const cc: f32 = @bitCast(in[3 * i + 2]);
        const g = got[i * 8 ..][0..8];
        if (g[0] == @as(u32, @bitCast(a * b))) mul_ok += 1;
        if (g[1] == @as(u32, @bitCast(a + b))) add_ok += 1;
        if (g[2] == @as(u32, @bitCast(@mulAdd(f32, a, b, cc)))) fused += 1;
        if (g[2] == @as(u32, @bitCast(a * b + cc))) unfused += 1;
        const scaled = a * 4.0 * 4.0 * 4.0;
        const near: i32 = @intFromFloat(@round(scaled) - (if (@abs(scaled - @trunc(scaled)) == 0.5 and @mod(@round(scaled), 2.0) != 0) std.math.sign(scaled) else 0));
        if (@as(i32, @bitCast(g[3])) == near) round_ok += 1;
        const even: u16 = @bitCast(@as(f16, @floatCast(a)));
        if (g[6] == even) f16_even += 1;
        if (g[7] == even) f16_default_even += 1;
        const rtz: u16 = blk: {
            const r: f16 = @floatCast(a);
            if (@abs(@as(f32, r)) > @abs(a)) break :blk @as(u16, @bitCast(r)) - 1;
            break :blk @bitCast(r);
        };
        if (g[7] == rtz) f16_default_rtz += 1;
    }
    c.res.mad = if (fused == n) .fused else if (unfused == n) .unfused else .mixed;
    c.say("compute float: mul {d}/{d} add {d}/{d} exact; mad.f32 like @mulAdd {d}, like a*b+c {d}; rndne {d}; f16 (even) {d}, f16 default: even {d} toward-zero {d}", .{ mul_ok, n, add_ok, n, fused, unfused, round_ok, f16_even, f16_default_even, f16_default_rtz });
    if (mul_ok != n or add_ok != n or round_ok != n or f16_even != n) return c.fail(name, "not IEEE round-to-nearest-even", .{});
    c.pass(name, n);
}

/// Q6_K (210-byte) and Q8_0 (34-byte) blocks put every other block two
/// bytes off a 4-byte boundary: do u32 loads from such addresses read the
/// bytes there (and u16 loads, into half registers)?
fn testUnaligned(c: *Ctx) void {
    const name = "unaligned global loads";
    const bytes = c.data.cpu[0..4096];
    for (bytes, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    c.dev.toDevice(c.data, 0, 4096);
    const d = addr(c.data);
    const o = addr(c.out);
    // fiber f: offset f (0..63) bytes + 64: a u32, a u32 x 4, two u16
    if (!c.launch(name,
        \\@localsize 64, 1, 1
        \\@invocationid(r0.x)
        \\@consts 2
        \\add.u r1.x, r0.x, 64
        \\ldg.a.u32 r2.x, g[c0.x+r1.x+0], 1
        \\ldg.a.u32 r3.x, g[c0.x+r1.x+0], 4
        \\ldg.a.u16 hr8.x, g[c0.x+r1.x+0], 2
        \\cov.u16u32 r2.y, hr8.x
        \\cov.u16u32 r2.z, hr8.y
        \\mov.u32u32 r2.w, 0
        \\shl.b r1.y, r0.x, 5
        \\stg.a.u32 g[c1.x+r1.y+0], r2.x, 4
        \\add.u r1.z, r1.y, 16
        \\stg.a.u32 g[c1.x+r1.z+0], r3.x, 4
        \\end
    , &.{ d[0], d[1], 0, 0, o[0], o[1], 0, 0 }, .{ 1, 1, 1 })) return;
    const got = c.outU32();
    var ok32 = [_]u32{0} ** 4;
    var ok128 = [_]u32{0} ** 4;
    var ok16 = [_]u32{0} ** 2;
    for (0..64) |f| {
        const at = 64 + f;
        const g = got[f * 8 ..][0..8];
        const w = std.mem.readInt(u32, bytes[at..][0..4], .little);
        if (g[0] == w) ok32[f % 4] += 1;
        var all = true;
        for (0..4) |k| if (g[4 + k] != std.mem.readInt(u32, bytes[at + 4 * k ..][0..4], .little)) {
            all = false;
        };
        if (all) ok128[f % 4] += 1;
        if (f % 2 == 0) {
            if (g[1] == std.mem.readInt(u16, bytes[at..][0..2], .little) and g[2] == std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little)) ok16[0] += 1;
        } else if (g[1] == std.mem.readInt(u16, bytes[at..][0..2], .little)) ok16[1] += 1;
    }
    c.say("compute unaligned: u32 at +0/+1/+2/+3: {d}/{d}/{d}/{d} of 16; u32x4: {d}/{d}/{d}/{d}; u16x2 even {d}/32 odd {d}/32", .{ ok32[0], ok32[1], ok32[2], ok32[3], ok128[0], ok128[1], ok128[2], ok128[3], ok16[0], ok16[1] });
    if (ok32[0] != 16 or ok128[0] != 16) return c.fail(name, "aligned loads are wrong", .{});
    c.pass(name, 64);
}

fn testBandwidth(c: *Ctx) void {
    const name = "memory read bandwidth";
    const buf = c.dev.alloc(64 << 20) catch c.dev.alloc(16 << 20) catch return c.fail(name, "no memory for it", .{});
    defer c.dev.free(buf);
    const bytes = buf.cpu.len;
    const vec4s = bytes / 16;
    const groups = vec4s / (128 * 16);
    const d = addr(buf);
    const o = addr(c.out);
    // Each fiber sums 16 vec4s strided by the grid (coalesced per wave).
    if (!c.launch(name,
        \\@localsize 128, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 2
        \\shl.b r1.x, r48.x, 11
        \\shl.b r1.y, r0.x, 4
        \\shl.b r1.x, r1.x, 4
        \\add.u r1.x, r1.x, r1.y
        \\mov.u32u32 r2.x, 0
        \\mov.u32u32 r1.z, 16
        \\mov.u32u32 r1.w, 2048
        \\loop:
        \\ldg.a.u32 r3.x, g[c0.x+r1.x+0], 4
        \\add.u r2.x, r2.x, r3.x
        \\add.u r2.x, r2.x, r3.w
        \\add.u r1.x, r1.x, r1.w
        \\sub.u r1.z, r1.z, 1
        \\cmps.u.ne p0.x, r1.z, 0
        \\br p0.x, #loop
        \\shl.b r4.x, r48.x, 7
        \\add.u r4.x, r4.x, r0.x
        \\shl.b r4.x, r4.x, 2
        \\stg.a.u32 g[c1.x+r4.x+0], r2.x, 1
        \\end
    , &.{ d[0], d[1], 0, 0, o[0], o[1], 0, 0 }, .{ @intCast(groups), 1, 1 })) return;
    const t = c.seconds();
    if (t <= 0) return c.fail(name, "no time measured", .{});
    c.res.read_gbps = @as(f64, @floatFromInt(bytes)) / t / 1e9;
    c.say("compute read bandwidth: {d:.1} GB/s ({d} MB in {d:.3} ms)", .{ c.res.read_gbps, bytes >> 20, t * 1e3 });
    c.res.passed += 1;
}

fn testAlu(c: *Ctx) void {
    const name = "ALU rate";
    const o = addr(c.out);
    // 64 x 4 independent mad.f32 chains per loop pass, 256 passes.
    if (!c.launch(name,
        \\@localsize 128, 1, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 1
        \\cov.u32f32 r1.x, r0.x
        \\mov.f32f32 r1.y, (0.5)
        \\mov.f32f32 r2.x, r1.x
        \\mov.f32f32 r2.y, r1.x
        \\mov.f32f32 r2.z, r1.x
        \\mov.f32f32 r2.w, r1.x
        \\mov.u32u32 r1.z, 256
        \\loop:
        \\mad.f32 r2.x, r2.x, r1.y, r1.y
        \\mad.f32 r2.y, r2.y, r1.y, r1.y
        \\mad.f32 r2.z, r2.z, r1.y, r1.y
        \\mad.f32 r2.w, r2.w, r1.y, r1.y
        \\mad.f32 r2.x, r2.x, r1.y, r1.y
        \\mad.f32 r2.y, r2.y, r1.y, r1.y
        \\mad.f32 r2.z, r2.z, r1.y, r1.y
        \\mad.f32 r2.w, r2.w, r1.y, r1.y
        \\mad.f32 r2.x, r2.x, r1.y, r1.y
        \\mad.f32 r2.y, r2.y, r1.y, r1.y
        \\mad.f32 r2.z, r2.z, r1.y, r1.y
        \\mad.f32 r2.w, r2.w, r1.y, r1.y
        \\mad.f32 r2.x, r2.x, r1.y, r1.y
        \\mad.f32 r2.y, r2.y, r1.y, r1.y
        \\mad.f32 r2.z, r2.z, r1.y, r1.y
        \\mad.f32 r2.w, r2.w, r1.y, r1.y
        \\sub.u r1.z, r1.z, 1
        \\cmps.u.ne p0.x, r1.z, 0
        \\br p0.x, #loop
        \\add.f r2.x, r2.x, r2.y
        \\add.f r2.z, r2.z, r2.w
        \\add.f r2.x, r2.x, r2.z
        \\shl.b r4.x, r48.x, 7
        \\add.u r4.x, r4.x, r0.x
        \\shl.b r4.x, r4.x, 2
        \\stg.a.f32 g[c0.x+r4.x+0], r2.x, 1
        \\end
    , &.{ o[0], o[1], 0, 0 }, .{ 256, 1, 1 })) return;
    const t = c.seconds();
    const flops: f64 = 256.0 * 128.0 * 256.0 * 16.0 * 2.0;
    if (t <= 0) return c.fail(name, "no time measured", .{});
    c.res.gflops = flops / t / 1e9;
    c.say("compute ALU rate: {d:.1} GFLOP/s fp32 mad ({d:.3} ms)", .{ c.res.gflops, t * 1e3 });
    c.res.passed += 1;
}

test "the bring-up tests pass on the emulated device" {
    const S = struct {
        var arena: [24 << 20]u8 align(4096) = undefined;
        var dev: device.EmuDevice = undefined;
        var work: Work = .{};
        var lines: usize = 0;
        fn log(line: []const u8) void {
            lines += 1;
            if (std.mem.indexOf(u8, line, "FAILED") != null) std.debug.print("{s}\n", .{line});
        }
    };
    S.dev = .{ .arena = &S.arena };
    const r = runAll(S.dev.device(), &S.work, S.log, true);
    try std.testing.expectEqual(@as(u32, 0), r.failed);
    try std.testing.expect(r.passed >= 9);
}
