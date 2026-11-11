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

test "spirv: a missing entry point and a bad module are errors, with a message" {
    var g = spirv.init(spv("axpy"), &S.scratch, .{});
    try testing.expectError(error.NoEntryPoint, g.compile("nope", .{ .insts = &S.insts, .tys = &S.tys }, &S.k));
    try testing.expect(std.mem.indexOf(u8, g.diag(), "nope") != null);
    const junk = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var g2 = spirv.init(&junk, &S.scratch, .{});
    try testing.expectError(error.BadSpirv, g2.compile("main", .{ .insts = &S.insts, .tys = &S.tys }, &S.k));
}
