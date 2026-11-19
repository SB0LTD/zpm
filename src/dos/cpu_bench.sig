//! The core's speed on the real bus (`Machine`): the same loop of simple
//! instructions as cpu_test.sig, in conventional memory, and a REP MOVSD
//! into video memory. Run with `-O fast` for numbers worth quoting.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const machine = @import("machine.sig");
const TestHost = @import("test_host.sig").TestHost;
const regs = @import("regs.sig");

var m: machine.Machine = .{};
var th: TestHost = .{};

fn nowNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn load(code: []const u8) *regs.Regs {
    m.init(th.host(), "");
    m.mem.copyIn(0x10000, code);
    const r = &m.cpu.regs;
    r.setSeg(regs.CS, 0x1000);
    r.eip = 0;
    r.setSeg(regs.SS, 0x2000);
    r.r[regs.ESP] = 0xFFFE;
    r.setSeg(regs.DS, 0x3000);
    r.setSeg(regs.ES, 0xA000);
    r.flags = regs.FIXED; // (no interrupts: the CPU alone)
    return r;
}

test "cpu bench: simple instructions and REP MOVSD on the machine's bus" {
    th = .{};
    var r = load(&.{ 0x01, 0xD8, 0x89, 0x04, 0x46, 0x8B, 0x1C, 0x81, 0xE6, 0xFF, 0x3F, 0x39, 0xD0, 0x74, 0xF1, 0xE2, 0xEF, 0xEB, 0xED });
    r.setBx(1);
    r.setDx(0xFFFF);
    const n: u32 = if (builtin.mode == .debug) 2_000_000 else 200_000_000;
    const t0 = nowNs();
    try t.expectEqual(@import("cpu.sig").Exit.budget, m.cpu.run(&m, n));
    const ns = nowNs() - t0;
    if (ns > 0) std.debug.print("\ncpu on Machine: {d} M instructions/s ({s})\n", .{ @as(u64, n) * 1000 / ns, @tagName(builtin.mode) });

    // xor si,si; xor di,di; mov cx,16000; rep movsd; jmp 0 (to A000:0)
    r = load(&.{ 0x31, 0xF6, 0x31, 0xFF, 0xB9, 0x80, 0x3E, 0xF3, 0x66, 0xA5, 0xEB, 0xF4 });
    const k: u32 = if (builtin.mode == .debug) 200_000 else 20_000_000;
    const t1 = nowNs();
    try t.expectEqual(@import("cpu.sig").Exit.budget, m.cpu.run(&m, k));
    const ns1 = nowNs() - t1;
    if (ns1 > 0) std.debug.print("cpu on Machine: rep movsd to A000: {d} M dwords/s\n", .{@as(u64, k) * 1000 / ns1});
}

test "cpu bench: the same loop under the translator (jit.sig)" {
    th = .{ .jit = true };
    var r = load(&.{ 0x01, 0xD8, 0x89, 0x04, 0x46, 0x8B, 0x1C, 0x81, 0xE6, 0xFF, 0x3F, 0x39, 0xD0, 0x74, 0xF1, 0xE2, 0xEF, 0xEB, 0xED });
    if (m.cpu.jit == null) return; // (no code memory here)
    r.setBx(1);
    r.setDx(0xFFFF);
    const n: u32 = if (builtin.mode == .debug) 2_000_000 else 1_000_000_000;
    const t0 = nowNs();
    try t.expectEqual(@import("cpu.sig").Exit.budget, m.cpu.run(&m, n));
    const ns = nowNs() - t0;
    if (ns > 0) std.debug.print("\ncpu on Machine, translated: {d} M instructions/s ({s})\n", .{ @as(u64, n) * 1000 / ns, @tagName(builtin.mode) });
    th = .{};
}
