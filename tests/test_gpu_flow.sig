//! KIR's control flow, subgroups, shared memory and barriers in the
//! interpreter: divergence, loops with brk/cont/ret, shuffles and votes,
//! barriers and the race check, atomics, the traps.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const interp = gpu.interp;
const r = kir.r;
const u = kir.u;
const f = kir.f;

var work_mem: [16 << 20]u8 align(64) = undefined;
var insts: [4096]kir.Inst = undefined;
var tys: [4096]kir.Ty = undefined;

fn newKernel(name: []const u8, group: [3]u32) kir.Kernel {
    return kir.Kernel.init(.{ .insts = &insts, .tys = &tys }, name, group);
}

fn runK(k: *kir.Kernel, caps: gpu.Caps, groups: [3]u32, bindings: []const []u8, params: []const u32) !interp.Stats {
    try k.finish();
    var w = gpu.Work.init(&work_mem);
    var trap: interp.Trap = .{};
    return interp.runKernel(k, caps, groups, bindings, params, &w, &trap) catch |e| {
        std.debug.print("trap {s} at pc {d} thread {d} offset {d}\n", .{ @tagName(trap.what), trap.pc, trap.thread, trap.offset });
        return e;
    };
}

fn runTrap(k: *kir.Kernel, caps: gpu.Caps, groups: [3]u32, bindings: []const []u8, params: []const u32) !interp.Trap.What {
    try k.finish();
    var w = gpu.Work.init(&work_mem);
    var trap: interp.Trap = .{};
    _ = interp.runKernel(k, caps, groups, bindings, params, &w, &trap) catch |e| {
        if (e == error.Trap) return trap.what;
        return e;
    };
    return .none;
}

fn words(b: []u8) []u32 {
    return @alignCast(std.mem.bytesAsSlice(u32, b));
}

/// i = gid.x * group.x + tid.x, and its byte offset.
fn index(k: *kir.Kernel) struct { i: kir.V, off: kir.V } {
    const t = k.tid(0);
    const g = k.gid(0);
    const ix = k.op3(.imad, .u32, r(g), u(k.group[0]), r(t));
    const off = k.op2(.shl, .u32, r(ix), u(2));
    return .{ .i = ix, .off = off };
}

test "flow: if/else per lane, nested" {
    var k = newKernel("ifelse", .{ 64, 1, 1 });
    const out = k.binding();
    const at = index(&k);
    const res = k.reg(.u32);
    k.set(res, .mov, u(0), kir.no, kir.no);
    const odd = k.cmp(.u32, .ne, r(k.op2(.@"and", .u32, r(at.i), u(1))), u(0));
    k.ifp(r(odd));
    {
        const big = k.cmp(.u32, .ge, r(at.i), u(32));
        k.ifp(r(big));
        k.set(res, .iadd, r(at.i), u(1000), kir.no);
        k.els();
        k.set(res, .iadd, r(at.i), u(2000), kir.no);
        k.endif();
    }
    k.els();
    k.set(res, .imul, r(at.i), u(3), kir.no);
    k.endif();
    k.store(.u32, kir.global(out, 32), r(at.off), r(res));
    var buf: [256]u8 align(4) = undefined;
    _ = try runK(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf}, &.{});
    for (words(&buf), 0..) |w, ix| {
        const i: u32 = @intCast(ix);
        const want: u32 = if (i & 1 == 1) (if (i >= 32) i + 1000 else i + 2000) else i * 3;
        try std.testing.expectEqual(want, w);
    }
}
