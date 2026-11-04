//! EmuDevice, the reference gpu.Device: compile, load, run, wait over its
//! memory models (unified coherent; unified not coherent, where the GPU
//! sees only what toDevice handed over; discrete, with VRAM the CPU cannot
//! see), zero-copy import, memory given back and reused, ordered
//! dispatches under one fence, traps as DeviceLost, and the verifier's
//! checks against a device's caps.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const r = kir.r;
const u = kir.u;

var work_mem: [4 << 20]u8 align(64) = undefined;
var mem: [1 << 20]u8 align(4096) = undefined;
var vram: [1 << 20]u8 align(4096) = undefined;
var shadow: [2 << 20]u8 align(4096) = undefined;
var insts: [256]kir.Inst = undefined;
var tys: [256]kir.Ty = undefined;
var code_out: [256 * kir.INST_BYTES]u8 = undefined;
var compile_mem: [4096]u8 = undefined;

const GROUP = 64;

/// dst[i] = src[i] * mul + add, for i < n (param 0 n, 1 mul, 2 add).
fn axpbKernel() !kir.Kernel {
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "axpb", .{ GROUP, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const n = k.param(.u32, 0);
    const mul = k.param(.u32, 1);
    const add = k.param(.u32, 2);
    const ix = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(ix), r(n))));
    const off = k.op2(.shl, .u32, r(ix), u(2));
    const v = k.load(.u32, kir.global(src, 32), r(off));
    k.store(.u32, kir.global(dst, 32), r(off), r(k.op3(.imad, .u32, r(v), r(mul), r(add))));
    k.endif();
    try k.finish();
    return k;
}

fn load(d: gpu.Device, k: *const kir.Kernel) !gpu.Program {
    var w = gpu.Work.init(&compile_mem);
    const bin = try gpu.compile(k, d.caps, &w, &code_out);
    return d.load(&bin);
}

fn words(b: gpu.Buffer) []u32 {
    return b.words();
}

fn caps(memory: gpu.MemoryModel, coherent: bool) gpu.Caps {
    var c = gpu.interp_caps;
    c.memory = memory;
    c.coherent = coherent;
    c.import = memory == .unified;
    return c;
}

test "emu: unified and coherent: compile, load, run, wait" {
    var e = gpu.EmuDevice.init(caps(.unified, true), &mem, &work_mem);
    const d = e.device();
    try std.testing.expectEqual(gpu.Target.interp, d.caps.target);
    var k = try axpbKernel();
    const p = try load(d, &k);
    const a = try d.alloc(400 * 4, .host);
    const b = try d.alloc(400 * 4, .host);
    try std.testing.expect(a.cpu.len == 1600 and b.gpu != a.gpu);
    for (words(a), 0..) |*w, ix| w.* = @intCast(ix);
    const f = try d.run(&.{.{ .prog = &p, .groups = .{ 7, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 400, 3, 5 } }});
    try d.wait(f, 1000);
    try std.testing.expect(d.done(f));
    for (words(b), 0..) |w, ix| try std.testing.expectEqual(@as(u32, @intCast(ix * 3 + 5)), w);
    try std.testing.expectEqual(@as(u64, 7), e.stats.groups);
}

test "emu: unified, not coherent: the GPU sees only what toDevice handed over" {
    var c = caps(.unified, false);
    c.import = true;
    var e = gpu.EmuDevice.init(c, &mem, &work_mem);
    e.shadow = &shadow;
    const d = e.device();
    var k = try axpbKernel();
    const p = try load(d, &k);
    const a = try d.alloc(64 * 4, .host);
    const b = try d.alloc(64 * 4, .host);
    for (words(a), 0..) |*w, ix| w.* = @intCast(ix + 1);
    // without toDevice the GPU reads the zeros it had
    try d.runWait(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 64, 2, 0 } }}, 1000);
    d.fromDevice(b, 0, 256);
    for (words(b)) |w| try std.testing.expectEqual(@as(u32, 0), w);
    // with it, the data; and the CPU sees the result only after fromDevice
    d.toDevice(a, 0, 256);
    @memset(b.cpu, 0x11);
    try d.runWait(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 64, 2, 0 } }}, 1000);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), words(b)[5]);
    d.fromDevice(b, 0, 128);
    for (words(b)[0..32], 0..) |w, ix| try std.testing.expectEqual(@as(u32, @intCast(2 * (ix + 1))), w);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), words(b)[40]);
    // imported memory has its own GPU copy too
    var mine: [64 * 4]u8 align(4) = undefined;
    for (std.mem.bytesAsSlice(u32, &mine), 0..) |*w, ix| w.* = @intCast(ix * 10);
    const im = d.import(&mine) orelse return error.TestUnexpectedResult;
    d.toDevice(im, 0, mine.len);
    try d.runWait(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ im, b }, .params = &.{ 64, 1, 1 } }}, 1000);
    d.fromDevice(b, 0, 256);
    for (words(b), 0..) |w, ix| try std.testing.expectEqual(@as(u32, @intCast(ix * 10 + 1)), w);
}

test "emu: unified import is zero-copy" {
    var e = gpu.EmuDevice.init(caps(.unified, true), &mem, &work_mem);
    const d = e.device();
    var k = try axpbKernel();
    const p = try load(d, &k);
    var src: [100 * 4]u8 align(4) = undefined;
    var dst: [100 * 4]u8 align(4) = undefined;
    for (std.mem.bytesAsSlice(u32, &src), 0..) |*w, ix| w.* = @intCast(ix);
    const a = d.import(&src) orelse return error.TestUnexpectedResult;
    const b = d.import(&dst) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a.cpu.ptr == &src);
    try d.runWait(&.{.{ .prog = &p, .groups = .{ 2, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 100, 7, 1 } }}, 1000);
    for (std.mem.bytesAsSlice(u32, &dst), 0..) |w, ix| try std.testing.expectEqual(@as(u32, @intCast(ix * 7 + 1)), w);
}

test "emu: discrete: VRAM without a CPU view, upload and host buffers" {
    var e = gpu.EmuDevice.init(caps(.discrete, true), &mem, &work_mem);
    e.vram = &vram;
    const d = e.device();
    try std.testing.expect(d.import(&code_out) == null);
    var k = try axpbKernel();
    const p = try load(d, &k);
    const up = try d.alloc(256 * 4, .upload);
    const dv = try d.alloc(256 * 4, .device);
    const host = try d.alloc(256 * 4, .host);
    try std.testing.expectEqual(@as(usize, 0), dv.cpu.len);
    for (words(up), 0..) |*w, ix| w.* = @intCast(ix);
    d.toDevice(up, 0, 1024);
    // upload -> VRAM (x2), VRAM -> host (+1), in one run
    const f = try d.run(&.{
        .{ .prog = &p, .groups = .{ 4, 1, 1 }, .buffers = &.{ up, dv }, .params = &.{ 256, 2, 0 } },
        .{ .prog = &p, .groups = .{ 4, 1, 1 }, .buffers = &.{ dv, host }, .params = &.{ 256, 1, 1 } },
    });
    try d.wait(f, 1000);
    d.fromDevice(host, 0, 1024);
    for (words(host), 0..) |w, ix| try std.testing.expectEqual(@as(u32, @intCast(ix * 2 + 1)), w);
    // VRAM is full after a while; freeing gives it back
    var held: [8]gpu.Buffer = undefined;
    for (&held) |*h| h.* = try d.alloc(vram.len / 8 - 4096, .device);
    try std.testing.expectError(error.OutOfMemory, d.alloc(vram.len / 8, .device));
    d.free(held[3]);
    const again = try d.alloc(vram.len / 8 - 4096, .device);
    try std.testing.expectEqual(held[3].gpu, again.gpu);
}

test "emu: traps are DeviceLost, with where" {
    var e = gpu.EmuDevice.init(caps(.unified, true), &mem, &work_mem);
    const d = e.device();
    var k = try axpbKernel();
    const p = try load(d, &k);
    const a = try d.alloc(16 * 4, .host);
    const b = try d.alloc(16 * 4, .host);
    // n past the buffers' end
    try std.testing.expectError(error.DeviceLost, d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 64, 1, 0 } }}));
    try std.testing.expectEqual(gpu.interp.Trap.What.out_of_bounds, e.trap.what);
    try std.testing.expectEqual(@as(u32, 16), e.trap.thread);
    // a buffer that is not the device's
    const fake = gpu.Buffer{ .gpu = 0xdead_0000, .bytes = 64 };
    try std.testing.expectError(error.DeviceLost, d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ fake, b }, .params = &.{ 16, 1, 0 } }}));
    try std.testing.expectEqual(gpu.interp.Trap.What.bad_binding, e.trap.what);
    // too few buffers or params
    try std.testing.expectError(error.BadProgram, d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{a}, .params = &.{ 16, 1, 0 } }}));
    try std.testing.expectError(error.BadProgram, d.run(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{16} }}));
    // a Binary for another target
    var bin = p.bin;
    bin.target = .sm_120;
    try std.testing.expectError(error.BadProgram, d.load(&bin));
    // and a good run after all that
    try d.runWait(&.{.{ .prog = &p, .groups = .{ 1, 1, 1 }, .buffers = &.{ a, b }, .params = &.{ 16, 1, 0 } }}, 1000);
    d.unload(&p);
}

test "emu: the verifier against a device's caps" {
    var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "fma", .{ 64, 1, 1 });
    _ = k.op3(.ffma, .f32, kir.f(1), kir.f(2), kir.f(3));
    try k.finish();
    var c = gpu.interp_caps;
    c.fused_fma = false;
    var w = gpu.Work.init(&compile_mem);
    try std.testing.expectError(error.NeedsFusedFma, gpu.compile(&k, c, &w, &code_out));
    c = gpu.interp_caps;
    c.max_group = 32;
    try std.testing.expectError(error.Limits, gpu.compile(&k, c, &w, &code_out));
    var k2 = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, "shared", .{ 1, 1, 1 });
    _ = k2.sharedAlloc(1 << 20, 4);
    try k2.finish();
    try std.testing.expectError(error.Limits, gpu.compile(&k2, gpu.interp_caps, &w, &code_out));
    // and the backends not on this branch say so
    c = gpu.interp_caps;
    c.target = .ir3_a7xx;
    var k3 = try axpbKernel();
    try std.testing.expectError(error.Unsupported, gpu.compile(&k3, c, &w, &code_out));
}

test "emu: the verifier's structural checks" {
    const Case = struct { name: []const u8, want: kir.Error };
    const cases = [_]Case{
        .{ .name = "else without if", .want = error.Unbalanced },
        .{ .name = "endloop closes an if", .want = error.Unbalanced },
        .{ .name = "pred operand from u32", .want = error.BadType },
        .{ .name = "vector store from an immediate", .want = error.BadOperand },
        .{ .name = "vector load past the registers", .want = error.BadOperand },
        .{ .name = "shared immediate out of range", .want = error.BadOperand },
        .{ .name = "param past param_words", .want = error.BadOperand },
        .{ .name = "cvt int to f16", .want = error.BadType },
        .{ .name = "atom kind in a register", .want = error.BadOperand },
        .{ .name = "misaligned immediate offset", .want = error.BadOperand },
        .{ .name = "register out of range", .want = error.BadOperand },
    };
    for (cases, 0..) |cs, ix| {
        var k = kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, cs.name, .{ 1, 1, 1 });
        const b = k.binding();
        const t = k.tid(0);
        switch (ix) {
            0 => k.els(),
            1 => {
                k.ifp(u(1));
                k.endloop();
            },
            2 => k.ifp(r(t)),
            3 => k.store(.u32, kir.global(b, 64), u(0), u(5)),
            4 => k.emit(.{ .op = .ld, .ty = .u32, .dst = t, .a = u(0), .b = kir.no, .c = kir.no, .aux = @bitCast(kir.global(b, 128)) }),
            5 => {
                _ = k.sharedAlloc(16, 4);
                _ = k.load(.u32, kir.shared(32), u(16));
            },
            6 => k.emit(.{ .op = .param, .ty = .u32, .dst = k.reg(.u32), .a = kir.no, .b = kir.no, .c = kir.no, .aux = 3 }),
            7 => _ = k.cvt(.u32, .f16, .rne, r(t)),
            8 => k.emit(.{ .op = .atom, .ty = .u32, .dst = k.reg(.u32), .a = u(0), .b = u(1), .c = r(t), .aux = @bitCast(kir.global(b, 32)) }),
            9 => {
                var m = kir.global(b, 32);
                m.imm = 2;
                _ = k.load(.u32, m, u(0));
            },
            else => _ = k.op2(.iadd, .u32, r(@enumFromInt(200)), u(1)),
        }
        k.finish() catch |e| {
            if (e != cs.want) {
                std.debug.print("{s}: want {s}, got {s}\n", .{ cs.name, @errorName(cs.want), @errorName(e) });
                return error.TestUnexpectedError;
            }
            continue;
        };
        std.debug.print("{s}: accepted\n", .{cs.name});
        return error.TestUnexpectedResult;
    }
}
