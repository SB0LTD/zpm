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

test "flow: loops with per-lane trips, brk, cont, and ret" {
    var k = newKernel("loops", .{ 64, 1, 1 });
    const out = k.binding();
    const at = index(&k);
    // lanes i % 8 == 7 return at once
    const gone = k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(at.i), u(7))), u(7));
    k.ifp(r(gone));
    k.ret();
    k.endif();
    // the sum of j in 0..i, skipping multiples of 3, stopping once it
    // passes 100
    const sum = k.reg(.u32);
    const j = k.reg(.u32);
    k.set(sum, .mov, u(0), kir.no, kir.no);
    k.set(j, .mov, u(0), kir.no, kir.no);
    k.loop();
    {
        k.brk(r(k.cmp(.u32, .ge, r(j), r(at.i))));
        const jj = k.mov(.u32, r(j));
        k.set(j, .iadd, r(j), u(1), kir.no);
        // jj % 3 == 0: jj - 3*(jj/3), jj/3 = hi(jj * 0xaaaaaaab) >> 1
        const q = k.op2(.shr, .u32, r(k.op2(.imulhi, .u32, r(jj), u(0xaaaa_aaab))), u(1));
        const rem = k.op2(.isub, .u32, r(jj), r(k.op2(.imul, .u32, r(q), u(3))));
        k.cont(r(k.cmp(.u32, .eq, r(rem), u(0))));
        k.set(sum, .iadd, r(sum), r(jj), kir.no);
        k.brk(r(k.cmp(.u32, .gt, r(sum), u(100))));
    }
    k.endloop();
    k.store(.u32, kir.global(out, 32), r(at.off), r(sum));
    var buf: [256]u8 align(4) = undefined;
    @memset(&buf, 0xee);
    _ = try runK(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf}, &.{});
    for (words(&buf), 0..) |w, ix| {
        if (ix & 7 == 7) {
            try std.testing.expectEqual(@as(u32, 0xeeee_eeee), w);
            continue;
        }
        var s: u32 = 0;
        var jv: u32 = 0;
        while (jv < ix) : (jv += 1) {
            if (jv % 3 == 0) continue;
            s += jv;
            if (s > 100) break;
        }
        try std.testing.expectEqual(s, w);
    }
}

test "flow: shuffles idx, xor, up, down at subgroups of 32, 64, 128" {
    for ([_]u32{ 32, 64, 128 }) |sg| {
        var caps = gpu.interp_caps;
        caps.subgroup = sg;
        var k = newKernel("shfl", .{ 256, 1, 1 });
        const out = k.binding();
        const at = index(&k);
        const v = k.op2(.imul, .u32, r(at.i), u(10));
        const bcast = k.shfl(.u32, .idx, r(v), u(3));
        // a butterfly sum over the subgroup
        const s = k.reg(.u32);
        k.set(s, .mov, r(v), kir.no, kir.no);
        var m: u32 = 1;
        while (m < sg) : (m <<= 1) {
            const o = k.shfl(.u32, .xor, r(s), u(m));
            k.set(s, .iadd, r(s), r(o), kir.no);
        }
        const upv = k.shfl(.u32, .up, r(v), u(1));
        const dnv = k.shfl(.u32, .down, r(v), u(2));
        const base = k.op2(.shl, .u32, r(at.i), u(4));
        k.store(.u32, kir.global(out, 32), r(base), r(bcast));
        k.store(.u32, kir.global(out, 32), r(k.op2(.iadd, .u32, r(base), u(4))), r(s));
        k.store(.u32, kir.global(out, 32), r(k.op2(.iadd, .u32, r(base), u(8))), r(upv));
        k.store(.u32, kir.global(out, 32), r(k.op2(.iadd, .u32, r(base), u(12))), r(dnv));
        var buf: [256 * 16]u8 align(4) = undefined;
        _ = try runK(&k, caps, .{ 1, 1, 1 }, &.{&buf}, &.{});
        const w = words(&buf);
        for (0..256) |ix| {
            const lane = ix % sg;
            const first = ix - lane;
            var total: u32 = 0;
            for (first..first + sg) |t| total += @intCast(t * 10);
            try std.testing.expectEqual(@as(u32, @intCast((first + 3) * 10)), w[ix * 4]);
            try std.testing.expectEqual(total, w[ix * 4 + 1]);
            try std.testing.expectEqual(@as(u32, @intCast(if (lane >= 1) (ix - 1) * 10 else ix * 10)), w[ix * 4 + 2]);
            try std.testing.expectEqual(@as(u32, @intCast(if (lane + 2 < sg) (ix + 2) * 10 else ix * 10)), w[ix * 4 + 3]);
        }
    }
}

test "flow: a shuffle from an inactive lane traps" {
    var k = newKernel("shfl inactive", .{ 32, 1, 1 });
    const out = k.binding();
    const at = index(&k);
    k.ifp(r(k.cmp(.u32, .lt, r(at.i), u(16))));
    const v = k.shfl(.u32, .xor, r(at.i), u(16));
    k.store(.u32, kir.global(out, 32), r(at.off), r(v));
    k.endif();
    var buf: [128]u8 align(4) = undefined;
    try std.testing.expectEqual(interp.Trap.What.inactive_lane, try runTrap(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf}, &.{}));
    // and a group of 48 has a partial second subgroup
    var k2 = newKernel("partial", .{ 48, 1, 1 });
    const out2 = k2.binding();
    const at2 = index(&k2);
    const v2 = k2.shfl(.u32, .xor, r(at2.i), u(16));
    k2.store(.u32, kir.global(out2, 32), r(at2.off), r(v2));
    var buf2: [192]u8 align(4) = undefined;
    try std.testing.expectEqual(interp.Trap.What.inactive_lane, try runTrap(&k2, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf2}, &.{}));
}

test "flow: votes over the active lanes" {
    var k = newKernel("vote", .{ 64, 1, 1 });
    const out = k.binding();
    const at = index(&k);
    const res = k.reg(.u32);
    k.set(res, .mov, u(9), kir.no, kir.no);
    // the even lanes only: in the first subgroup all are < 40 and one is
    // 10; in the second, neither
    k.ifp(r(k.cmp(.u32, .eq, r(k.op2(.@"and", .u32, r(at.i), u(1))), u(0))));
    {
        const small = k.cmp(.u32, .lt, r(at.i), u(40));
        const all = k.vote(.all, r(small));
        const any = k.vote(.any, r(k.cmp(.u32, .eq, r(at.i), u(10))));
        const a1 = k.sel(.u32, r(all), u(1), u(0));
        const a2 = k.sel(.u32, r(any), u(2), u(0));
        k.set(res, .@"or", r(a1), r(a2), kir.no);
    }
    k.endif();
    k.store(.u32, kir.global(out, 32), r(at.off), r(res));
    var buf: [256]u8 align(4) = undefined;
    _ = try runK(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf}, &.{});
    for (words(&buf), 0..) |w, ix| {
        const want: u32 = if (ix & 1 == 1) 9 else if (ix < 32) 1 | 2 else 0;
        try std.testing.expectEqual(want, w);
    }
}

/// A tree sum over the group in shared memory; `with_barriers` false
/// leaves them out (a race).
fn reduceKernel(with_barriers: bool) kir.Kernel {
    var k = newKernel("reduce", .{ 256, 1, 1 });
    const inb = k.binding();
    const out = k.binding();
    const sh = k.sharedAlloc(256 * 4, 4);
    const at = index(&k);
    const t = k.tid(0);
    const toff = k.op2(.shl, .u32, r(t), u(2));
    const v = k.load(.u32, kir.global(inb, 32), r(at.off));
    var m = kir.shared(32);
    m.imm = @intCast(sh);
    k.store(.u32, m, r(toff), r(v));
    var stride: u32 = 128;
    while (stride >= 1) : (stride /= 2) {
        if (with_barriers) k.barrier();
        k.ifp(r(k.cmp(.u32, .lt, r(t), u(stride))));
        const other = k.load(.u32, m, r(k.op2(.iadd, .u32, r(toff), u(stride * 4))));
        const mine = k.load(.u32, m, r(toff));
        k.store(.u32, m, r(toff), r(k.op2(.iadd, .u32, r(mine), r(other))));
        k.endif();
        if (stride == 1) break;
    }
    if (with_barriers) k.barrier();
    k.ifp(r(k.cmp(.u32, .eq, r(t), u(0))));
    const total = k.load(.u32, m, u(0));
    k.store(.u32, kir.global(out, 32), r(k.op2(.shl, .u32, r(k.gid(0)), u(2))), r(total));
    k.endif();
    return k;
}

test "flow: barriers and shared memory; the race check" {
    var inb: [4 * 256 * 4]u8 align(4) = undefined;
    for (words(&inb), 0..) |*w, ix| w.* = @intCast(ix * 3 + 1);
    var outb: [16]u8 align(4) = undefined;
    var k = reduceKernel(true);
    _ = try runK(&k, gpu.interp_caps, .{ 4, 1, 1 }, &.{ &inb, &outb }, &.{});
    for (words(&outb), 0..) |w, g| {
        var s: u32 = 0;
        for (g * 256..g * 256 + 256) |ix| s += @intCast(ix * 3 + 1);
        try std.testing.expectEqual(s, w);
    }
    var k2 = reduceKernel(false);
    try std.testing.expectEqual(interp.Trap.What.shared_race, try runTrap(&k2, gpu.interp_caps, .{ 4, 1, 1 }, &.{ &inb, &outb }, &.{}));
}

test "flow: a barrier under divergence traps" {
    var k = newKernel("divergent barrier", .{ 64, 1, 1 });
    _ = k.binding();
    const at = index(&k);
    k.ifp(r(k.cmp(.u32, .lt, r(at.i), u(32))));
    k.barrier();
    k.endif();
    var buf: [4]u8 align(4) = undefined;
    try std.testing.expectEqual(interp.Trap.What.divergent_barrier, try runTrap(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{&buf}, &.{}));
}

test "flow: atomics, global and shared" {
    var k = newKernel("atomics", .{ 128, 1, 1 });
    const ctr = k.binding();
    const olds = k.binding();
    const sh = k.sharedAlloc(4, 4);
    const at = index(&k);
    const t = k.tid(0);
    var m = kir.shared(32);
    m.imm = @intCast(sh);
    k.ifp(r(k.cmp(.u32, .eq, r(t), u(0))));
    k.store(.i32, m, u(0), kir.i(-1000));
    k.endif();
    k.barrier();
    const old = k.atomic(.u32, .add, kir.global(ctr, 32), u(0), u(1));
    k.store(.u32, kir.global(olds, 32), r(at.off), r(old));
    // a signed max of (i - 300) in shared memory, an unsigned min in global
    const sv = k.op2(.isub, .i32, r(k.mov(.i32, r(at.i))), u(300));
    _ = k.atomic(.i32, .max, m, u(0), r(sv));
    _ = k.atomic(.u32, .min, kir.global(ctr, 32), u(4), r(at.i));
    k.barrier();
    k.ifp(r(k.cmp(.u32, .eq, r(t), u(0))));
    const mx = k.load(.i32, m, u(0));
    k.store(.i32, kir.global(ctr, 32), r(k.op2(.iadd, .u32, r(k.op2(.shl, .u32, r(k.gid(0)), u(2))), u(8))), r(mx));
    k.endif();
    var cb: [8 + 16]u8 align(4) = undefined;
    @memset(&cb, 0);
    words(&cb)[1] = 0xffff_ffff;
    var ob: [4 * 128 * 4]u8 align(4) = undefined;
    _ = try runK(&k, gpu.interp_caps, .{ 4, 1, 1 }, &.{ &cb, &ob }, &.{});
    const cw = words(&cb);
    try std.testing.expectEqual(@as(u32, 512), cw[0]);
    try std.testing.expectEqual(@as(u32, 0), cw[1]);
    for (0..4) |g| try std.testing.expectEqual(@as(i32, @intCast(g * 128 + 127)) - 300, @as(i32, @bitCast(cw[2 + g])));
    // the old values: each of 0..511 once
    var seen = [_]bool{false} ** 512;
    for (words(&ob)) |w| {
        try std.testing.expect(!seen[w]);
        seen[w] = true;
    }
}

test "flow: loads and stores of 8 to 128 bits; bounds and alignment trap" {
    var k = newKernel("widths", .{ 4, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const t = k.tid(0);
    var s8 = kir.global(src, 8);
    s8.signed = true;
    const b_s = k.load(.i32, s8, r(t));
    const b_u = k.load(.u32, kir.global(src, 8), r(t));
    var s16 = kir.global(src, 16);
    s16.signed = true;
    const h_s = k.load(.i32, s16, r(k.op2(.shl, .u32, r(t), u(1))));
    const v4 = k.load(.u32, kir.global(src, 128), r(k.op2(.shl, .u32, r(t), u(4))));
    const v2 = k.load(.u32, kir.global(src, 64), r(k.op2(.shl, .u32, r(t), u(3))));
    const o = k.op2(.imul, .u32, r(t), u(32));
    k.store(.u32, kir.global(dst, 32), r(o), r(b_s));
    var m4 = kir.global(dst, 32);
    m4.imm = 4;
    k.store(.u32, m4, r(o), r(b_u));
    m4.imm = 8;
    k.store(.u32, m4, r(o), r(h_s));
    var m128 = kir.global(dst, 128);
    m128.imm = 16;
    k.store(.u32, m128, r(o), r(v4));
    var m8 = kir.global(dst, 8);
    m8.imm = 12;
    k.store(.u32, m8, r(o), r(kir.Kernel.at(v2, 1)));
    var sb: [64]u8 align(16) = undefined;
    for (&sb, 0..) |*b, ix| b.* = @intCast((0x80 + ix * 5) % 256);
    var db: [128]u8 align(16) = undefined;
    @memset(&db, 0);
    _ = try runK(&k, gpu.interp_caps, .{ 1, 1, 1 }, &.{ &sb, &db }, &.{});
    const dw = words(&db);
    for (0..4) |ti| {
        try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, @as(i8, @bitCast(sb[ti]))))), dw[ti * 8]);
        try std.testing.expectEqual(@as(u32, sb[ti]), dw[ti * 8 + 1]);
        const h = std.mem.readInt(u16, sb[ti * 2 ..][0..2], .little);
        try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, @as(i16, @bitCast(h))))), dw[ti * 8 + 2]);
        try std.testing.expectEqual(@as(u32, sb[ti * 8 + 4]), dw[ti * 8 + 3]);
        for (0..4) |jx| try std.testing.expectEqual(std.mem.readInt(u32, sb[ti * 16 + jx * 4 ..][0..4], .little), dw[ti * 8 + 4 + jx]);
    }
    // out of bounds, misaligned
    var k2 = newKernel("oob", .{ 4, 1, 1 });
    const b2 = k2.binding();
    _ = k2.load(.u32, kir.global(b2, 32), r(k2.op2(.shl, .u32, r(k2.tid(0)), u(4))));
    try std.testing.expectEqual(interp.Trap.What.out_of_bounds, try runTrap(&k2, gpu.interp_caps, .{ 1, 1, 1 }, &.{sb[0..32]}, &.{}));
    var k3 = newKernel("misaligned", .{ 4, 1, 1 });
    const b3 = k3.binding();
    _ = k3.load(.u32, kir.global(b3, 32), r(k3.op2(.shl, .u32, r(k3.tid(0)), u(1))));
    try std.testing.expectEqual(interp.Trap.What.misaligned, try runTrap(&k3, gpu.interp_caps, .{ 1, 1, 1 }, &.{&sb}, &.{}));
}

test "flow: ids in 3 dimensions, lanes, params, poison" {
    var caps = gpu.interp_caps;
    caps.subgroup = 8;
    var k = newKernel("ids", .{ 4, 2, 2 });
    const out = k.binding();
    const p0 = k.param(.u32, 0);
    const p1 = k.param(.u32, 1);
    const lin = k.op3(.imad, .u32, r(k.tid(2)), u(8), r(k.op3(.imad, .u32, r(k.tid(1)), u(4), r(k.tid(0)))));
    const g = k.op3(.imad, .u32, r(k.gid(2)), u(6), r(k.op3(.imad, .u32, r(k.gid(1)), u(2), r(k.gid(0)))));
    const slot = k.op3(.imad, .u32, r(g), u(16), r(lin));
    const base = k.op2(.shl, .u32, r(slot), u(4));
    const gs = k.op3(.imad, .u32, r(k.gsize(2)), u(100), r(k.op3(.imad, .u32, r(k.gsize(1)), u(10), r(k.gsize(0)))));
    k.store(.u32, kir.global(out, 32), r(base), r(k.op3(.imad, .u32, r(k.lane()), u(1000), r(k.subgroupWidth()))));
    var m = kir.global(out, 32);
    m.imm = 4;
    k.store(.u32, m, r(base), r(gs));
    m.imm = 8;
    k.store(.u32, m, r(base), r(k.op2(.iadd, .u32, r(p0), r(p1))));
    const never = k.reg(.u32);
    m.imm = 12;
    k.store(.u32, m, r(base), r(never));
    var buf: [12 * 16 * 16]u8 align(4) = undefined;
    _ = try runK(&k, caps, .{ 2, 3, 2 }, &.{&buf}, &.{ 40, 2 });
    const w = words(&buf);
    for (0..12 * 16) |s| {
        const lin_v = s % 16;
        try std.testing.expectEqual(@as(u32, @intCast((lin_v % 8) * 1000 + 8)), w[s * 4]);
        try std.testing.expectEqual(@as(u32, 232), w[s * 4 + 1]);
        try std.testing.expectEqual(@as(u32, 42), w[s * 4 + 2]);
        try std.testing.expectEqual(interp.POISON, w[s * 4 + 3]);
    }
}
