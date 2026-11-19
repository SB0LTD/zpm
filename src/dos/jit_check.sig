//! Lockstep checking of the translator (dosrun --jit-check): after every
//! stretch of code the translator ran on the machine, its interpreted
//! twin (machine.sig's `twin`, the same program from the same start, the
//! same devices) runs as many instructions; their CPUs must then agree,
//! register for register and flag for flag (but the flags the block left
//! stale because nothing reads them before they are written again), and
//! so must the memory the block stored to, and every so often all of
//! the RAM and the SVGA's memory. The first difference is logged, with
//! where the stretch began, and the machine stops.

const std = @import("std");
const machine = @import("machine.sig");
const jit = @import("jit.sig");
const regs = @import("regs.sig");
const Machine = machine.Machine;

var stretches: u64 = 0;
/// All of memory compared every this many stretches.
pub var full_every: u64 = 1 << 16;

fn say(m: *Machine, comptime f: []const u8, args: anytype) void {
    m.host.say("jit-check: " ++ f, args);
}

pub fn check(m: *Machine, t: *Machine, info: *const jit.CheckInfo) bool {
    stretches += 1;
    if (info.n > 0) {
        var left = info.n;
        while (left > 0) {
            const before = t.cpu.executed;
            const why = t.cpu.interpFrom(t, @intCast(@min(left, 1 << 30)), info.poll and left == info.n);
            const ran = t.cpu.executed - before;
            if (ran >= left) break;
            left -= ran;
            if (why != .budget) {
                say(m, "the interpreter stopped ({s}) {d} instructions short", .{ @tagName(why), left });
                break;
            }
        }
    }
    const a = &m.cpu;
    const b = &t.cpu;
    var ok = true;
    const ra = &a.regs;
    const rb = &b.regs;
    const names = [_][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
    for (0..8) |i| {
        if (ra.r[i] != rb.r[i]) {
            say(m, "{s} jit {x:0>8} interp {x:0>8}", .{ names[i], ra.r[i], rb.r[i] });
            ok = false;
        }
    }
    if (ra.eip != rb.eip) {
        say(m, "eip jit {x:0>8} interp {x:0>8}", .{ ra.eip, rb.eip });
        ok = false;
    }
    const fmask: u32 = ~info.dead;
    if ((ra.flags ^ rb.flags) & fmask != 0) {
        say(m, "flags jit {x:0>8} interp {x:0>8} (dead {x})", .{ ra.flags, rb.flags, info.dead });
        ok = false;
    }
    for (0..6) |i| {
        if (ra.seg[i] != rb.seg[i] or ra.base[i] != rb.base[i] or ra.limit[i] != rb.limit[i] or ra.attr[i] != rb.attr[i]) {
            say(m, "segment {d}: jit {x:0>4} base {x} lim {x} attr {x}; interp {x:0>4} base {x} lim {x} attr {x}", .{ i, ra.seg[i], ra.base[i], ra.limit[i], ra.attr[i], rb.seg[i], rb.base[i], rb.limit[i], rb.attr[i] });
            ok = false;
        }
    }
    if (a.executed != b.executed) {
        say(m, "executed jit {d} interp {d}", .{ a.executed, b.executed });
        ok = false;
    }
    if (a.cr0 != b.cr0 or a.cr2 != b.cr2 or a.cr3 != b.cr3 or a.cpl != b.cpl or a.halted != b.halted or a.shadow != b.shadow) {
        say(m, "state: cr0 {x}/{x} cr2 {x}/{x} cr3 {x}/{x} cpl {d}/{d} halted {}/{} shadow {}/{}", .{ a.cr0, b.cr0, a.cr2, b.cr2, a.cr3, b.cr3, a.cpl, b.cpl, a.halted, b.halted, a.shadow, b.shadow });
        ok = false;
    }
    if (!fpuEql(&a.fpu, &b.fpu)) {
        say(m, "the FPU differs (top {d}/{d}, sw {x}/{x})", .{ a.fpu.top, b.fpu.top, a.fpu.sw, b.fpu.sw });
        ok = false;
    }
    // The stores the block logged.
    const ram_a = @intFromPtr(&m.mem.ram);
    const vram_a = @intFromPtr(&m.vga.svga.mem);
    for (info.wlog) |w| {
        const at: usize = @intCast(w.at);
        const n: usize = @intCast(w.n);
        var pa: ?[]const u8 = null;
        var pb: ?[]const u8 = null;
        if (at >= ram_a and at + n <= ram_a + m.mem.ram.len) {
            pa = m.mem.ram[at - ram_a ..][0..n];
            pb = t.mem.ram[at - ram_a ..][0..n];
        } else if (at >= vram_a and at + n <= vram_a + m.vga.svga.mem.len) {
            pa = m.vga.svga.mem[at - vram_a ..][0..n];
            pb = t.vga.svga.mem[at - vram_a ..][0..n];
        }
        if (pa) |x| if (!std.mem.eql(u8, x, pb.?)) {
            say(m, "a store at host {x} ({d} bytes) differs", .{ at, n });
            ok = false;
        };
    }
    if (stretches % full_every == 0 or !ok) {
        if (!memEql(m, t)) ok = false;
    }
    if (!ok) {
        say(m, "after {d} instructions from {x:0>4}:{x:0>8} ({s}; {d} stretches checked)", .{ info.n, info.cs, info.eip, if (info.block) "a block" else "one interpreted step", stretches });
        var code: [16]u8 = undefined;
        for (&code, 0..) |*c, i| c.* = t.rd8(rb.base[regs.CS] +% info.eip +% @as(u32, @intCast(i)));
        say(m, "its bytes (real mode / paging off: as linear) {x}", .{code});
    }
    return ok;
}

fn fpuEql(a: anytype, b: anytype) bool {
    for (0..8) |i| {
        if (@as(u64, @bitCast(a.st[i])) != @as(u64, @bitCast(b.st[i]))) return false;
        if (a.raw[i] != b.raw[i]) return false;
    }
    return a.exact == b.exact and a.empty == b.empty and a.top == b.top and a.cw == b.cw and a.sw == b.sw;
}

/// All of the RAM and the SVGA's memory.
pub fn memEql(m: *Machine, t: *Machine) bool {
    var ok = true;
    if (!std.mem.eql(u8, &m.mem.ram, &t.mem.ram)) {
        var i: usize = 0;
        while (i < m.mem.ram.len and m.mem.ram[i] == t.mem.ram[i]) : (i += 1) {}
        say(m, "RAM differs first at {x}: jit {x:0>2} interp {x:0>2}", .{ i, m.mem.ram[i], t.mem.ram[i] });
        ok = false;
    }
    if (!std.mem.eql(u8, &m.vga.svga.mem, &t.vga.svga.mem)) {
        say(m, "the SVGA's memory differs", .{});
        ok = false;
    }
    return ok;
}
