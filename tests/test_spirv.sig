//! The SPIR-V front end (src/spirv) on naga's output: WGSL compute shaders
//! (tests/data/vk/*.wgsl, compiled by naga 30 with
//! `--index-bounds-check-policy Restrict`, as *.spv) translated to KIR and
//! run on KIR's interpreter (EmuDevice) and on the emulated RTX (kir_sm120's
//! code in sm120_emu), their results checked against the same computation
//! on the CPU.

const std = @import("std");
const gpu = @import("gpu");
const spirv = @import("spirv");
const nvidia = @import("nvidia");
const kir = gpu.kir;
const testing = std.testing;

const Shaders = struct {
    const axpy align(4) = @embedFile("data/vk/axpy.spv").*;
    const ops align(4) = @embedFile("data/vk/ops.spv").*;
    const flow align(4) = @embedFile("data/vk/flow.spv").*;
    const reduce align(4) = @embedFile("data/vk/reduce.spv").*;
    const subgroup align(4) = @embedFile("data/vk/subgroup.spv").*;
    const half align(4) = @embedFile("data/vk/half.spv").*;
};

fn spv(comptime name: []const u8) []const u32 {
    const bytes = &@field(Shaders, name);
    return std.mem.bytesAsSlice(u32, bytes[0 .. bytes.len & ~@as(usize, 3)]);
}

const S = struct {
    var scratch: spirv.Scratch = undefined;
    var insts: [1 << 16]kir.Inst = undefined;
    var tys: [1 << 16]kir.Ty = undefined;
    var k: kir.Kernel = undefined;
    var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
    var code: [1 << 21]u8 align(16) = undefined;
    var emu_mem: [16 << 20]u8 align(4096) = undefined;
    var emu_work: [16 << 20]u8 align(64) = undefined;
    var emu: gpu.EmuDevice = undefined;
    var arena: [48 << 20]u8 align(4096) = undefined;
    var view: [48 << 20]u8 align(4096) = undefined;
    var rtx_work: nvidia.sm120_emu.Work = undefined;
    var rtx: gpu.nvidia_device.Emu = undefined;
};

const Dev = enum { interp, rtx };

fn device(which: Dev) gpu.Device {
    switch (which) {
        .interp => {
            S.emu = gpu.EmuDevice.init(gpu.interp_caps, &S.emu_mem, &S.emu_work);
            return S.emu.device();
        },
        .rtx => {
            S.rtx.init(&S.arena, &S.view, &S.rtx_work);
            return S.rtx.device();
        },
    }
}

/// Compiles `name`'s main, runs it once over `bufs` (binding i is bufs[i])
/// with `push` as its push constants, and copies the results back.
fn run(which: Dev, comptime name: []const u8, groups: [3]u32, bufs: []const []u8, push: []const u32) !spirv.Info {
    const dev = device(which);
    var g = spirv.init(spv(name), &S.scratch, .{});
    const info = g.compile("main", .{ .insts = &S.insts, .tys = &S.tys }, &S.k) catch |e| {
        std.debug.print("{s}: {s}\n", .{ name, g.diag() });
        return e;
    };
    var work = gpu.Work.init(&S.work);
    const bin = try gpu.compile(&S.k, dev.caps, &work, &S.code);
    const prog = try dev.load(&bin);
    defer dev.unload(&prog);
    var gb: [spirv.MAX_BINDINGS]gpu.Buffer = undefined;
    var params: [2 * spirv.MAX_BINDINGS + 32]u32 = undefined;
    const nb = info.n_bindings;
    for (0..nb) |i| {
        const host = bufs[info.bindings[i].binding];
        gb[i] = try dev.alloc(host.len, .host);
        @memcpy(gb[i].cpu[0..host.len], host);
        dev.toDevice(gb[i], 0, host.len);
        params[2 * i] = 0;
        params[2 * i + 1] = @intCast(host.len);
    }
    @memcpy(params[2 * nb ..][0..push.len], push);
    const np = 2 * nb + push.len;
    dev.runWait(&.{.{ .prog = &prog, .groups = groups, .buffers = gb[0..nb], .params = params[0..@max(np, bin.param_words)] }}, 10_000_000) catch |e| {
        if (which == .rtx) {
            var buf: [512]u8 = undefined;
            std.debug.print("{s} on the emulated RTX: {s}\n", .{ name, S.rtx.explain(&buf) });
        } else std.debug.print("{s} on the interpreter: trap {any}\n", .{ name, S.emu.trap });
        return e;
    };
    for (0..nb) |i| {
        const host = bufs[info.bindings[i].binding];
        dev.fromDevice(gb[i], 0, host.len);
        @memcpy(@constCast(host), gb[i].cpu[0..host.len]);
        dev.free(gb[i]);
    }
    return info;
}

fn asBytes(comptime T: type, xs: []T) []u8 {
    return std.mem.sliceAsBytes(xs);
}

// ── axpy ──

fn axpyCase(which: Dev) !void {
    var src: [90]f32 = undefined;
    for (&src, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i)) * 0.5 - 7.25;
    var dst = [_]f32{-1} ** 100;
    var params = [_]u32{ 90, @bitCast(@as(f32, 1.5)) } ++ [_]u32{0} ** 2;
    const info = try run(which, "axpy", .{ 2, 1, 1 }, &.{ asBytes(f32, &src), asBytes(f32, &dst), asBytes(u32, &params) }, &.{});
    try testing.expectEqual(@as(u8, 3), info.n_bindings);
    try testing.expectEqual(spirv.BindKind.uniform, info.bindings[2].kind);
    try testing.expectEqual([3]u32{ 64, 1, 1 }, info.group);
    for (0..2) |grp| {
        var s: f32 = 0;
        for (0..64) |l| {
            const i = grp * 64 + l;
            s += if (i < 90) src[i] else 0;
        }
        for (0..64) |l| {
            const i = grp * 64 + l;
            if (i >= 100) continue;
            const v: f32 = if (i < 90) src[i] else 0;
            const want = (v * 2.0) * 1.5 + s + @as(f32, @floatFromInt(i % 7));
            testing.expectEqual(want, dst[i]) catch |e| {
                std.debug.print("axpy: dst[{d}] = {d}, want {d}\n", .{ i, dst[i], want });
                return e;
            };
        }
    }
}

test "spirv: naga's axpy (uniform block, workgroup memory, barrier, loop, call, arrayLength) on the interpreter" {
    try axpyCase(.interp);
}
test "spirv: naga's axpy on the emulated RTX (sm_120)" {
    try axpyCase(.rtx);
}

// ── ops ──

const ops_a = [32]u32{ 0, 1, 2, 7, 100, 12345, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 255, 256, 1000, 3, 5, 0x1234_5678, 0xdead_beef, 42, 9, 17, 0xffff_fff0, 64, 63, 1 << 20, 99, 31, 8, 0x0f0f_0f0f, 77, 4096, 0xfffe_0000, 13, 6 };
const ops_b = [32]u32{ 1, 1, 3, 2, 7, 10, 2, 0xffff_ffff, 0xffff_ffff, 0, 16, 33, 3, 0xffff_fffb, 0x10, 77, 5, 0, 4, 9, 64, 32, 31, 98, 4, 0xffff_fff8, 3, 77, 13, 5, 0xfff0_0000, 1 };

fn f32bits(x: f32) u32 {
    return @bitCast(x);
}

fn opsWant(x: u32, y: u32) [32]u32 {
    const sx: i32 = @bitCast(x);
    const sy: i32 = @bitCast(y);
    const fx = @as(f32, @floatFromInt(sx)) * 0.25;
    const fy = @as(f32, @floatFromInt(sy)) * 0.5 + 0.75;
    const sh: u5 = @truncate(y);
    var w: [32]u32 = undefined;
    w[0] = x +% y;
    w[1] = x -% y;
    w[2] = x *% y;
    w[3] = if (y == 0) x else x / y;
    w[4] = if (y == 0) 0 else x % y;
    const sdz = sy == 0 or (sy == -1 and sx == std.math.minInt(i32));
    w[5] = @bitCast(if (sdz) sx else @divTrunc(sx, sy));
    w[6] = @bitCast(if (sdz) @as(i32, 0) else @rem(sx, sy));
    w[7] = x & y;
    w[8] = x | y;
    w[9] = x ^ y;
    w[10] = ~x;
    w[11] = x << sh;
    w[12] = x >> sh;
    w[13] = @bitCast(sx >> sh);
    w[14] = @as(u32, @intFromBool(x < y)) | @as(u32, @intFromBool(sx < sy)) << 1 | @as(u32, @intFromBool(x == y)) << 2 | @as(u32, @intFromBool(fx <= fy)) << 3;
    w[15] = f32bits(fx + fy);
    w[16] = f32bits(fx - fy);
    w[17] = f32bits(fx * fy);
    w[18] = f32bits(fx / fy);
    w[19] = f32bits(@floor(fx / 3.0));
    w[20] = f32bits(@min(fx, fy));
    w[21] = f32bits(@max(fx, fy));
    w[22] = f32bits(@abs(fx));
    w[23] = f32bits(std.math.clamp(fx, -1.0, 1.0));
    const v = @abs(fy) * 3.0;
    w[24] = @intFromFloat(@min(@max(v, 0), 4294967040.0));
    w[25] = @bitCast(@as(i32, @intFromFloat(fx)));
    w[26] = @popCount(x);
    w[27] = @bitReverse(x);
    w[28] = if (x == 0) 0xffff_ffff else 31 - @as(u32, @clz(x));
    w[29] = if (x == 0) 0xffff_ffff else @as(u32, @ctz(x));
    w[30] = (x >> 3) & 0x7f;
    const mask: u32 = 0x1ff << 5;
    w[31] = (x & ~mask) | ((y << 5) & mask);
    return w;
}

fn opsCase(which: Dev) !void {
    var a = ops_a;
    var b = ops_b;
    var o = [_]u32{0xcccc_cccc} ** (32 * 32);
    var counters = [4]u32{ 0, 0, 0xffff_ffff, 1000 };
    var scounters = [2]i32{ std.math.maxInt(i32), std.math.minInt(i32) };
    _ = try run(which, "ops", .{ 1, 1, 1 }, &.{ asBytes(u32, &a), asBytes(u32, &b), asBytes(u32, &o), asBytes(u32, &counters), asBytes(i32, &scounters) }, &.{});
    var sum: u32 = 0;
    var mx: u32 = 0;
    var mn: u32 = 0xffff_ffff;
    var smn: i32 = std.math.maxInt(i32);
    var smx: i32 = std.math.minInt(i32);
    for (0..32) |i| {
        const want = opsWant(ops_a[i], ops_b[i]);
        for (0..32) |j| {
            testing.expectEqual(want[j], o[i * 32 + j]) catch |e| {
                std.debug.print("ops: thread {d} (x {x}, y {x}) result {d}: {x}, want {x}\n", .{ i, ops_a[i], ops_b[i], j, o[i * 32 + j], want[j] });
                return e;
            };
        }
        sum +%= ops_a[i] & 0xff;
        mx = @max(mx, ops_a[i]);
        mn = @min(mn, ops_a[i]);
        smn = @min(smn, @as(i32, @bitCast(ops_a[i])));
        smx = @max(smx, @as(i32, @bitCast(ops_a[i])));
    }
    try testing.expectEqual([4]u32{ sum, mx, mn, 1000 - 32 }, counters);
    try testing.expectEqual([2]i32{ smn, smx }, scounters);
}

test "spirv: naga's integer, float, bit and atomic operations on the interpreter" {
    try opsCase(.interp);
}
test "spirv: naga's integer, float, bit and atomic operations on the emulated RTX" {
    try opsCase(.rtx);
}

// ── flow ──

fn collatz(n0: u32) [2]u32 {
    var n = n0;
    var steps: u32 = 0;
    while (n != 1) {
        if (steps >= 1000) return .{ 0xffff_ffff, steps };
        n = if (n & 1 == 0) n / 2 else 3 * n + 1;
        steps += 1;
    }
    return .{ steps, steps };
}

fn flowCase(which: Dev) !void {
    const groups: u32 = 2;
    var o = [_]u32{0xcccc_cccc} ** (16 * groups * 8);
    _ = try run(which, "flow", .{ groups, 1, 1 }, &.{asBytes(u32, &o)}, &.{});
    for (0..16 * groups) |ii| {
        const i: u32 = @intCast(ii);
        const c = collatz(i + 1);
        const x = i * 7;
        const cls: u32 = switch (x % 5) {
            0 => 10,
            1, 2 => 20,
            else => if (x > 100) 30 else 40,
        };
        var sum: u32 = 0;
        for (0..10) |jj| {
            const j: u32 = @intCast(jj);
            if (j == 3 or j == 5) continue;
            sum += if (j == 7) 100 + i else j;
        }
        var arr = [8]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
        arr[i % 8] = i;
        var t: u32 = 0;
        for (0..8) |jj| {
            const j: u32 = @intCast(jj);
            t += arr[(j + i) % 8] * (j + 1);
        }
        var w: u32 = 0;
        while (w < i) w += 3;
        const want = [8]u32{ c[0], c[1], cls, sum, t, w, groups, 6 * i + 4 };
        testing.expectEqualSlices(u32, &want, o[ii * 8 ..][0..8]) catch |e| {
            std.debug.print("flow: thread {d}\n", .{i});
            return e;
        };
    }
}

test "spirv: naga's loops, switches, early returns, private and local arrays on the interpreter" {
    try flowCase(.interp);
}
test "spirv: naga's loops, switches, early returns, private and local arrays on the emulated RTX" {
    try flowCase(.rtx);
}

// ── reduce ──

fn reduceCase(which: Dev) !void {
    const n: u32 = 150;
    var input: [192]f32 = undefined;
    for (&input, 0..) |*x, i| x.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 17)) - 8)) + 0.5;
    var output = [_]f32{0} ** 3;
    const scale: f32 = 0.25;
    const info = try run(which, "reduce", .{ 3, 1, 1 }, &.{ asBytes(f32, &input), asBytes(f32, &output) }, &.{ n, @bitCast(scale) });
    try testing.expectEqual(@as(u32, 8), info.push_bytes);
    for (0..3) |grp| {
        var sh: [64]f32 = undefined;
        for (&sh, 0..) |*x, l| {
            const i = grp * 64 + l;
            x.* = if (i < n) input[i] else 0;
        }
        var s: usize = 32;
        while (s > 0) : (s >>= 1) {
            for (0..s) |l| sh[l] += sh[l + s];
        }
        try testing.expectEqual(sh[0] * scale, output[grp]);
    }
}

test "spirv: naga's workgroup reduction with push constants on the interpreter" {
    try reduceCase(.interp);
}
test "spirv: naga's workgroup reduction with push constants on the emulated RTX" {
    try reduceCase(.rtx);
}

// ── subgroups and the atomics past add/min/max/exchange ──

fn subgroupInput() [64]u32 {
    var a: [64]u32 = undefined;
    var s: u32 = 0x1234_5679;
    for (&a, 0..) |*x, i| {
        s = s *% 1664525 +% 1013904223;
        x.* = if (i % 9 == 4) @as(u32, @intCast(i)) else s >> 3;
    }
    a[7] = 7; // (subgroup 0 has a 7; subgroup 1 a 0)
    a[40] = 0;
    return a;
}

fn subgroupCase(which: Dev) !void {
    const a = subgroupInput();
    var ain = a;
    var o = [_]u32{0xcccc_cccc} ** (64 * 24 + 128);
    var c = [_]u32{0} ** 68;
    c[0] = 0xffff_ffff;
    for (0..64) |i| c[4 + i] = a[i];
    _ = try run(which, "subgroup", .{ 1, 1, 1 }, &.{ asBytes(u32, &ain), asBytes(u32, &o), asBytes(u32, &c) }, &.{});
    var and_all: u32 = 0xffff_ffff;
    var or_all: u32 = 0;
    var xor_all: u32 = 0;
    for (a) |x| {
        and_all &= x | 0x0f0f_0f0f;
        or_all |= x;
        xor_all ^= x;
    }
    try testing.expectEqual([4]u32{ and_all, or_all, xor_all, 64 }, c[0..4].*);
    for (0..64) |li| {
        const sg = li / 32;
        const sl: u32 = @intCast(li % 32);
        const g = a[sg * 32 ..][0..32];
        const x = a[li];
        var want: [24]u32 = undefined;
        var sum: u32 = 0;
        var excl: u32 = 0;
        var fsum: f32 = 0;
        var mn: u32 = 0xffff_ffff;
        var mx: u32 = 0;
        var an: u32 = 0xffff_ffff;
        var orr: u32 = 0;
        var xo: u32 = 0;
        var prod: u32 = 1;
        var ballot: u32 = 0;
        var all = true;
        var any = false;
        var fprod: f32 = 1;
        var dsum: u32 = 0;
        var dexcl: u32 = 0;
        var dmask: u32 = 0;
        for (g, 0..) |y, j| {
            sum +%= y;
            if (j < sl) excl +%= y;
            fsum += @as(f32, @floatFromInt(y & 0xff)) * 0.5;
            mn = @min(mn, y);
            mx = @max(mx, y);
            an &= y;
            orr |= y;
            xo ^= y;
            prod *%= (y & 3) | 1;
            if (y & 1 != 0) ballot |= @as(u32, 1) << @intCast(j);
            all = all and y != 0;
            any = any or y == 7;
            if (j < sl) fprod *= @floatFromInt((y & 1) + 1);
            if (y % 3 != 0) {
                dsum +%= y;
                if (j < sl) dexcl +%= y;
                dmask |= @as(u32, 1) << @intCast(j);
            }
        }
        want[0] = sum;
        want[1] = excl;
        want[2] = excl +% x;
        want[3] = @bitCast(fsum);
        want[4] = mn;
        want[5] = mx;
        want[6] = an;
        want[7] = orr;
        want[8] = xo;
        want[9] = prod;
        want[10] = ballot;
        want[11] = g[5];
        want[12] = g[0];
        want[13] = g[(sl * 7) & 31];
        want[14] = g[sl ^ 3];
        want[15] = if (sl >= 2) g[sl - 2] else x;
        want[16] = if (sl + 3 < 32) g[sl + 3] else x;
        want[17] = @as(u32, @intFromBool(all)) | @as(u32, @intFromBool(any)) << 1 | 32 << 8;
        want[18] = g[(sl & ~@as(u32, 3)) | 2];
        want[19] = g[sl ^ 1];
        want[20] = @bitCast(fprod);
        if (x % 3 != 0) {
            want[21] = dsum;
            want[22] = dexcl;
            want[23] = dmask;
        } else {
            want[21] = 0xcccc_cccc;
            want[22] = 0xcccc_cccc;
            want[23] = 0xcccc_cccc;
        }
        for (want, 0..) |w, j| {
            testing.expectEqual(w, o[li * 24 + j]) catch |e| {
                std.debug.print("subgroup: lane {d} result {d}: {x}, want {x}\n", .{ li, j, o[li * 24 + j], w });
                return e;
            };
        }
        // compare-exchange on its own word: odd lanes guess right
        const odd = li & 1 == 1;
        try testing.expectEqual(x, o[64 * 24 + 2 * li]);
        try testing.expectEqual(@as(u32, @intFromBool(odd)), o[64 * 24 + 2 * li + 1]);
        try testing.expectEqual(if (odd) @as(u32, @intCast(li)) else x, c[4 + li]);
    }
}

test "spirv: naga's subgroup ops (reductions, scans, ballots, shuffles, quads; divergent) and and/or/xor/compare-exchange atomics on the interpreter" {
    try subgroupCase(.interp);
}
test "spirv: naga's subgroup ops and atomics on the emulated RTX" {
    try subgroupCase(.rtx);
}

// ── f16 ──

const half_in = [32]f16{ 1.0, -2.5, 0.1, 3.140625, 100.0, -0.0, 3e-5, 0.5, 7.75, -13.0, 0.333, 2.0, 1.0e-3, -0.75, 15.5, 1.5, 6.0e-5, -1.0, 9.0, 0.125, 42.0, -3.0, 0.2, 5.5, -7.0, 11.0, 0.01, 4.0, -0.5, 31.0, 0.0625, 2.75 };

fn halfCase(which: Dev) !void {
    var h = half_in;
    var h2: [64]f16 = undefined;
    for (0..32) |i| {
        h2[2 * i] = half_in[(i * 5) % 32] * 0.5;
        h2[2 * i + 1] = half_in[(i * 3 + 1) % 32] + 1.0;
    }
    var oh = [_]f16{0} ** 256;
    var ow = [_]u32{0} ** 128;
    _ = try run(which, "half", .{ 1, 1, 1 }, &.{ asBytes(f16, &h), asBytes(f16, &h2), asBytes(f16, &oh), asBytes(u32, &ow) }, &.{});
    for (0..32) |i| {
        const x = half_in[i];
        const y = half_in[(i + 7) % 32];
        const vx = h2[2 * i];
        const vy = h2[2 * i + 1];
        const x32: f32 = x;
        const y32: f32 = y;
        var want: [8]f16 = undefined;
        want[0] = x + y;
        want[1] = x * y;
        want[2] = x / (y + 1.5);
        want[3] = @floatCast(x32 * y32 + @as(f32, @as(f16, 0.333)));
        want[4] = @floatCast(@sqrt(@abs(x32)));
        want[5] = @floatCast(x32 * @as(f32, 1.0001));
        want[6] = vx - vy;
        want[7] = @floatCast(@as(f32, vx) * x32 + @as(f32, vy) * y32);
        for (want, 0..) |w, j| {
            const got: u16 = @bitCast(oh[8 * i + j]);
            testing.expectEqual(@as(u16, @bitCast(w)), got) catch |e| {
                std.debug.print("half: lane {d} result {d}: {x}, want {x}\n", .{ i, j, got, @as(u16, @bitCast(w)) });
                return e;
            };
        }
        const xy = x * y;
        try testing.expectEqual(@as(u32, @bitCast(@as(f32, vx * vy + x))), ow[4 * i]);
        try testing.expectEqual(@as(u32, @bitCast(@as(f32, xy))), ow[4 * i + 1]);
        try testing.expectEqual(@as(u32, @bitCast(@as(i32, @intFromFloat(@as(f32, x * 4.0))) + 1000)), ow[4 * i + 2]);
        try testing.expectEqual(@as(u32, @intFromBool(x < y)) | @as(u32, @intFromBool(x == y)) << 1, ow[4 * i + 3]);
    }
}

test "spirv: naga's f16 (storage, arithmetic rounded to half, conversions) on the interpreter" {
    try halfCase(.interp);
}
test "spirv: naga's f16 on the emulated RTX" {
    try halfCase(.rtx);
}

test "spirv: a missing entry point and a bad module are errors, with a message" {
    var g = spirv.init(spv("axpy"), &S.scratch, .{});
    try testing.expectError(error.NoEntryPoint, g.compile("nope", .{ .insts = &S.insts, .tys = &S.tys }, &S.k));
    try testing.expect(std.mem.indexOf(u8, g.diag(), "nope") != null);
    const junk = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var g2 = spirv.init(&junk, &S.scratch, .{});
    try testing.expectError(error.BadSpirv, g2.compile("main", .{ .insts = &S.insts, .tys = &S.tys }, &S.k));
}
