//! @zpm/hlsl live — liveness of every temp's components through the
//! program's structured flow (if/else, loops with break and continue),
//! backwards: a component written and overwritten before anything reads
//! it is not written at all, and an instruction left writing nothing is
//! dropped. fxc's dead-store removal, so the signatures' used masks and
//! the reflection's used variables come out as its do.
//!
//! Each live set is a byte per temp (its live components); sets live in
//! the caller's arena, a stack. Loops iterate until their header's set
//! stops growing.

const std = @import("std");
const ir = @import("ir.sig");

const Op = ir.Op;

pub const Live = struct {
    p: *ir.Program,
    arena: []u8,
    top: usize = 0,
    n: usize,
    /// matching flow: if -> else or endif, else -> endif, loop -> endloop,
    /// and back
    match: []u32,
    dead: []bool,
    over: bool = false,
    loops: [64]LoopCtx = undefined,
    nloops: usize = 0,

    const LoopCtx = struct { exit: []u8, header: []u8 };

    fn alloc(l: *Live) ?[]u8 {
        if (l.top + l.n > l.arena.len) {
            l.over = true;
            return null;
        }
        const s = l.arena[l.top..][0..l.n];
        l.top += l.n;
        return s;
    }

    fn copy(l: *Live, src: []const u8) ?[]u8 {
        const s = l.alloc() orelse return null;
        @memcpy(s, src);
        return s;
    }

    /// Runs the analysis and applies it; false when the arena was too
    /// small or the flow is not structured (nothing changed then).
    pub fn run(l: *Live) bool {
        const p = l.p;
        // the flow's structure
        var stack: [256]u32 = undefined;
        var sp: usize = 0;
        for (p.insts[0..p.n], 0..) |i, k_| {
            const k: u32 = @intCast(k_);
            l.dead[k] = false;
            l.match[k] = 0xffff_ffff;
            switch (i.op) {
                .@"if", .loop => {
                    if (sp >= stack.len) return false;
                    stack[sp] = k;
                    sp += 1;
                },
                .@"else" => {
                    if (sp == 0) return false;
                    l.match[stack[sp - 1]] = k;
                    l.match[k] = stack[sp - 1];
                    stack[sp - 1] = k;
                },
                .endif, .endloop => {
                    if (sp == 0) return false;
                    sp -= 1;
                    const o = stack[sp];
                    // (an endif's match is its if, through any else)
                    const open = if (p.insts[o].op == .@"else") l.match[o] else o;
                    if (p.insts[o].op == .@"else") l.match[o] = k else l.match[o] = k;
                    l.match[k] = open;
                },
                .@"switch" => return false,
                else => {},
            }
        }
        if (sp != 0) return false;
        const live = l.alloc() orelse return false;
        @memset(live, 0);
        l.back(0, p.n, live, true);
        if (l.over) return false;
        // the dead instructions out
        var w: u32 = 0;
        for (p.insts[0..p.n], 0..) |i, k| {
            if (l.dead[k]) continue;
            p.insts[w] = i;
            w += 1;
        }
        p.n = w;
        return true;
    }

    fn orInto(dst: []u8, src: []const u8) void {
        for (dst, src) |*d, s| d.* |= s;
    }

    /// Instructions [start, end) backwards; `live` is the set after `end`
    /// on entry and before `start` on return.
    fn back(l: *Live, start: u32, end: u32, live: []u8, apply: bool) void {
        const p = l.p;
        var k = end;
        while (k > start and !l.over) {
            k -= 1;
            const i = &p.insts[k];
            switch (i.op) {
                .endif => {
                    const if_i = l.match[k];
                    const else_i = l.match[if_i];
                    const mark = l.top;
                    defer l.top = mark;
                    const after = l.copy(live) orelse return;
                    if (else_i != k) {
                        // the else side, then the then side, from the same set
                        l.back(else_i + 1, k, live, apply);
                        const then_live = l.copy(after) orelse return;
                        l.back(if_i + 1, else_i, then_live, apply);
                        orInto(live, then_live);
                    } else {
                        l.back(if_i + 1, k, live, apply);
                        orInto(live, after);
                    }
                    l.reads(&p.insts[if_i], live);
                    k = if_i;
                },
                .endloop => {
                    const loop_i = l.match[k];
                    const mark = l.top;
                    defer l.top = mark;
                    const exit = l.copy(live) orelse return;
                    const header = l.alloc() orelse return;
                    @memset(header, 0);
                    const body = l.alloc() orelse return;
                    if (l.nloops >= l.loops.len) {
                        l.over = true;
                        return;
                    }
                    l.loops[l.nloops] = .{ .exit = exit, .header = header };
                    l.nloops += 1;
                    defer l.nloops -= 1;
                    // the header's set: until it stops growing
                    var rounds: u32 = 0;
                    while (rounds < 64) : (rounds += 1) {
                        @memcpy(body, header);
                        l.back(loop_i + 1, k, body, false);
                        if (l.over) return;
                        var grew = false;
                        for (header, body) |*h, b| {
                            if (b & ~h.* != 0) {
                                h.* |= b;
                                grew = true;
                            }
                        }
                        if (!grew) break;
                    }
                    if (apply) {
                        @memcpy(body, header);
                        l.back(loop_i + 1, k, body, true);
                    }
                    @memcpy(live, header);
                    k = loop_i;
                },
                .@"break" => {
                    if (l.nloops == 0) return;
                    @memcpy(live, l.loops[l.nloops - 1].exit);
                },
                .breakc => {
                    if (l.nloops == 0) return;
                    orInto(live, l.loops[l.nloops - 1].exit);
                    l.reads(i, live);
                },
                .@"continue" => {
                    if (l.nloops == 0) return;
                    @memcpy(live, l.loops[l.nloops - 1].header);
                },
                .continuec => {
                    if (l.nloops == 0) return;
                    orInto(live, l.loops[l.nloops - 1].header);
                    l.reads(i, live);
                },
                .ret => @memset(live, 0),
                .@"if", .@"else", .loop => {},
                else => l.step(k, live, apply),
            }
        }
    }

    /// One instruction: its writes kill, its reads make live; a write
    /// nobody reads is dropped (with `apply`).
    fn step(l: *Live, k: usize, live: []u8, apply: bool) void {
        const p = l.p;
        var i = p.insts[k];
        if (l.dead[k]) return;
        var only_temps = sideEffectFree(i.op) and i.ndst > 0;
        for (i.ops[0..i.ndst]) |d| {
            if (d.reg != .temp and d.reg != .null) only_temps = false;
        }
        if (only_temps) {
            var left: u4 = 0;
            for (i.ops[0..i.ndst]) |*d| {
                if (d.reg != .temp) continue;
                d.mask &= @truncate(live[d.idx[0]]);
                left |= d.mask;
            }
            if (left == 0) {
                if (apply) l.dead[k] = true;
                return;
            }
            for (i.ops[0..i.ndst]) |*d| {
                if (d.reg == .temp and d.mask == 0) d.* = .{ .reg = .null, .comps = 0, .dims = 0 };
            }
        }
        // writes kill (the components written)
        for (i.ops[0..i.ndst]) |d| {
            if (d.reg == .temp) live[d.idx[0]] &= ~@as(u8, d.mask);
        }
        l.reads(&i, live);
        if (apply) p.insts[k] = i;
    }

    fn reads(_: *Live, i: *const ir.Inst, live: []u8) void {
        for (i.ops[0..i.n], 0..) |o, j| {
            if (j >= i.ndst and o.reg == .temp) live[o.idx[0]] |= ir.readMask(i, j);
            if (o.rel.on and o.rel.reg == .temp) live[o.rel.idx] |= @as(u8, 1) << o.rel.comp;
        }
    }
};

/// Instructions whose only effect is their destinations.
fn sideEffectFree(op: Op) bool {
    return switch (op) {
        .@"break", .breakc, .case, .@"continue", .continuec, .cut, .default, .discard, .@"else", .emit, .endif, .endloop, .endswitch, .@"if", .loop, .ret, .retc, .@"switch", .emit_stream, .cut_stream, .nop => false,
        else => true,
    };
}
