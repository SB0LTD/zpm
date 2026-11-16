//! @zpm/va vpx_dsl — how the VP8 and VP9 encoders' kernels are written:
//! once, as Sig functions generic over a backend `b`, and run two ways.
//!
//! - `Cpu` (here) runs one invocation of a kernel at a time on the CPU:
//!   each op is the i32 arithmetic it names, a load or store indexes the
//!   kernel's buffers, `when` and `loop` are Sig's `if` and `while`. The
//!   driver's tests encode with it (va.sig has no GPU), and so does the
//!   shared library when the RTX cannot be opened.
//! - `vpx_kir.Kir` (needs the `gpu` module) emits the same calls as KIR
//!   (zpm src/gpu): one KIR instruction per op, `when` an if/endif, `loop`
//!   a loop with its counter; compiled for the RTX's sm_120 (or run on
//!   KIR's interpreter). The gpu tests run every kernel both ways and
//!   compare the buffers byte for byte.
//!
//! So the CPU's encode and the RTX's are the same code: a stream the CPU
//! encodes, the RTX encodes bit for bit alike.
//!
//! What a kernel may do (both backends agree on it):
//! - values are 32-bit integers (`V`), wrapping; predicates (`P`) come from
//!   compares and are combined with pand/por/pnot;
//! - shifts take any amount (0..31); `sar` is arithmetic, `shr` logical;
//! - loads and stores are byte offsets into the kernel's buffers (bindings
//!   0..MAX_BUFS-1), aligned to their width, 8- 16- or 32-bit, the narrow
//!   ones zero- or sign-extended (`Ty`);
//! - `vr` makes a variable (a value that changes: loop carried, or set in
//!   a `when`); `get` reads it (a copy), `put` writes it. Variables are
//!   made outside loops (each `vr` is one register in KIR, made once);
//! - `when(p, ctx)` runs `ctx.then(b)` where p holds, `whenElse` runs
//!   `ctx.then` or `ctx.otherwise`; `loop(n, ctx)` runs `ctx.body(b, i)`
//!   for i = 0 .. n-1. A value made inside a body is not seen after it
//!   (variables carry values out);
//! - no shared memory, no barriers: an invocation never waits for another.
//!   A kernel's invocations of one dispatch are independent; a later
//!   dispatch sees an earlier one's stores (wavefronts are dispatches).
//!
//! Allocation-free: an invocation's state is a fixed struct on the stack.

const std = @import("std");

pub const MAX_BUFS = 4;
pub const MAX_VARS = 256;
pub const MAX_PARAMS = 96;
/// Invocations per GPU group; a kernel's index is gid * GROUP + tid.
pub const GROUP = 64;

/// What a load reads (and a store writes: u8/i8 alike, u16/i16 alike).
pub const Ty = enum { u8, i8, u16, i16, i32 };

pub fn bytesOf(comptime t: Ty) usize {
    return switch (t) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .i32 => 4,
    };
}

/// One invocation of a kernel on the CPU.
pub const Cpu = struct {
    pub const V = i32;
    pub const P = bool;
    pub const Var = u16;
    pub const is_cpu = true;

    bufs: [MAX_BUFS][]u8,
    params: []const u32,
    /// the invocation's index in its dispatch
    thread: u32 = 0,
    vars: [MAX_VARS]i32 = undefined,
    nvars: u16 = 0,

    pub fn init(bufs: [MAX_BUFS][]u8, params: []const u32, thread: u32) Cpu {
        return .{ .bufs = bufs, .params = params, .thread = thread };
    }

    // ── values ──
    pub inline fn c(_: *Cpu, x: i32) i32 {
        return x;
    }
    pub inline fn param(b: *Cpu, comptime i: u16) i32 {
        return @bitCast(b.params[i]);
    }
    pub inline fn index(b: *Cpu) i32 {
        return @bitCast(b.thread);
    }

    // ── integer ops (i32, wrapping) ──
    pub inline fn add(_: *Cpu, x: i32, y: i32) i32 {
        return x +% y;
    }
    pub inline fn sub(_: *Cpu, x: i32, y: i32) i32 {
        return x -% y;
    }
    pub inline fn mul(_: *Cpu, x: i32, y: i32) i32 {
        return x *% y;
    }
    /// x * y + z
    pub inline fn mad(_: *Cpu, x: i32, y: i32, z: i32) i32 {
        return x *% y +% z;
    }
    pub inline fn shl(_: *Cpu, x: i32, n: i32) i32 {
        const s: u5 = @intCast(n & 31);
        return @bitCast(@as(u32, @bitCast(x)) << s);
    }
    pub inline fn sar(_: *Cpu, x: i32, n: i32) i32 {
        const s: u5 = @intCast(n & 31);
        return x >> s;
    }
    pub inline fn shr(_: *Cpu, x: i32, n: i32) i32 {
        const s: u5 = @intCast(n & 31);
        return @bitCast(@as(u32, @bitCast(x)) >> s);
    }
    pub inline fn band(_: *Cpu, x: i32, y: i32) i32 {
        return x & y;
    }
    pub inline fn bor(_: *Cpu, x: i32, y: i32) i32 {
        return x | y;
    }
    pub inline fn bxor(_: *Cpu, x: i32, y: i32) i32 {
        return x ^ y;
    }
    pub inline fn min(_: *Cpu, x: i32, y: i32) i32 {
        return @min(x, y);
    }
    pub inline fn max(_: *Cpu, x: i32, y: i32) i32 {
        return @max(x, y);
    }
    pub inline fn abs(_: *Cpu, x: i32) i32 {
        return if (x < 0) 0 -% x else x;
    }
    pub inline fn neg(_: *Cpu, x: i32) i32 {
        return 0 -% x;
    }
    pub inline fn sel(_: *Cpu, p: bool, x: i32, y: i32) i32 {
        return if (p) x else y;
    }

    // ── predicates ──
    pub inline fn lt(_: *Cpu, x: i32, y: i32) bool {
        return x < y;
    }
    pub inline fn le(_: *Cpu, x: i32, y: i32) bool {
        return x <= y;
    }
    pub inline fn gt(_: *Cpu, x: i32, y: i32) bool {
        return x > y;
    }
    pub inline fn ge(_: *Cpu, x: i32, y: i32) bool {
        return x >= y;
    }
    pub inline fn eq(_: *Cpu, x: i32, y: i32) bool {
        return x == y;
    }
    pub inline fn ne(_: *Cpu, x: i32, y: i32) bool {
        return x != y;
    }
    pub inline fn pand(_: *Cpu, p: bool, q: bool) bool {
        return p and q;
    }
    pub inline fn por(_: *Cpu, p: bool, q: bool) bool {
        return p or q;
    }
    pub inline fn pnot(_: *Cpu, p: bool) bool {
        return !p;
    }
    /// A constant predicate.
    pub inline fn pc(_: *Cpu, p: bool) bool {
        return p;
    }

    // ── memory ──
    pub inline fn ld(b: *Cpu, comptime t: Ty, comptime buf: u8, off: i32) i32 {
        const at: usize = @intCast(off);
        const m = b.bufs[buf];
        return switch (t) {
            .u8 => m[at],
            .i8 => @as(i8, @bitCast(m[at])),
            .u16 => std.mem.readInt(u16, m[at..][0..2], .little),
            .i16 => std.mem.readInt(i16, m[at..][0..2], .little),
            .i32 => std.mem.readInt(i32, m[at..][0..4], .little),
        };
    }
    pub inline fn st(b: *Cpu, comptime t: Ty, comptime buf: u8, off: i32, x: i32) void {
        const at: usize = @intCast(off);
        const m = b.bufs[buf];
        switch (t) {
            .u8, .i8 => m[at] = @truncate(@as(u32, @bitCast(x))),
            .u16, .i16 => std.mem.writeInt(u16, m[at..][0..2], @truncate(@as(u32, @bitCast(x))), .little),
            .i32 => std.mem.writeInt(i32, m[at..][0..4], x, .little),
        }
    }

    // ── variables ──
    pub inline fn vr(b: *Cpu, x: i32) u16 {
        const v = b.nvars;
        b.vars[v] = x;
        b.nvars += 1;
        return v;
    }
    pub inline fn get(b: *Cpu, v: u16) i32 {
        return b.vars[v];
    }
    pub inline fn put(b: *Cpu, v: u16, x: i32) void {
        b.vars[v] = x;
    }

    // ── control ──
    // (a body's own variables end with it: the slots go back)
    pub inline fn when(b: *Cpu, p: bool, ctx: anytype) void {
        const mark = b.nvars;
        if (p) ctx.then(b);
        b.nvars = mark;
    }
    pub inline fn whenElse(b: *Cpu, p: bool, ctx: anytype) void {
        const mark = b.nvars;
        if (p) ctx.then(b) else ctx.otherwise(b);
        b.nvars = mark;
    }
    pub inline fn loop(b: *Cpu, n: i32, ctx: anytype) void {
        const mark = b.nvars;
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            ctx.body(b, i);
            b.nvars = mark;
        }
    }
};

/// Runs `kernel` over `threads` invocations on the CPU (a dispatch).
pub fn runCpu(comptime kernel: anytype, bufs: [MAX_BUFS][]u8, params: []const u32, threads: u32) void {
    var t: u32 = 0;
    while (t < threads) : (t += 1) {
        var b = Cpu.init(bufs, params, t);
        kernel(&b);
    }
}

// ── Helpers every kernel uses (generic over the backend) ────────────────────

/// clamp(x, lo, hi)
pub inline fn clamp(b: anytype, x: anytype, lo: anytype, hi: anytype) @TypeOf(x) {
    return b.min(b.max(x, lo), hi);
}

/// A pixel: clamp to 0..255.
pub inline fn clip8(b: anytype, x: anytype) @TypeOf(x) {
    return b.min(b.max(x, b.c(0)), b.c(255));
}

/// (x + (1 << (n-1))) >> n, arithmetic.
pub inline fn roundShift(b: anytype, x: anytype, comptime n: u5) @TypeOf(x) {
    return b.sar(b.add(x, b.c(@as(i32, 1) << (n - 1))), b.c(n));
}

test "vpx_dsl: the CPU backend's ops, memory and control" {
    var mem: [64]u8 = @splat(0);
    const params = [_]u32{ 5, 0xffff_fffd };
    var b = Cpu.init(.{ &mem, &.{}, &.{}, &.{} }, &params, 3);
    try std.testing.expectEqual(@as(i32, -3), b.param(1));
    try std.testing.expectEqual(@as(i32, 3), b.index());
    try std.testing.expectEqual(@as(i32, -2), b.sar(b.c(-7), b.c(2)));
    try std.testing.expectEqual(@as(i32, 0x3fff_fffe), b.shr(b.c(-7), b.c(2)));
    try std.testing.expectEqual(@as(i32, 255), clip8(&b, b.c(300)));
    b.st(.i16, 0, b.c(2), b.c(-300));
    try std.testing.expectEqual(@as(i32, -300), b.ld(.i16, 0, b.c(2)));
    try std.testing.expectEqual(@as(i32, 0xd4), b.ld(.u8, 0, b.c(2)));
    try std.testing.expectEqual(@as(i32, -44), b.ld(.i8, 0, b.c(2)));
    const acc = b.vr(b.c(0));
    const Sum = struct {
        acc: u16,
        pub fn body(s: @This(), bb: *Cpu, i: i32) void {
            bb.put(s.acc, bb.add(bb.get(s.acc), i));
        }
    };
    b.loop(b.c(5), Sum{ .acc = acc });
    try std.testing.expectEqual(@as(i32, 10), b.get(acc));
    const Neg = struct {
        acc: u16,
        pub fn then(s: @This(), bb: *Cpu) void {
            bb.put(s.acc, bb.neg(bb.get(s.acc)));
        }
    };
    b.when(b.gt(b.get(acc), b.c(3)), Neg{ .acc = acc });
    try std.testing.expectEqual(@as(i32, -10), b.get(acc));
}
