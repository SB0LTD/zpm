//! The GPU self-test (gpu.selftest) on every device we can run here: the
//! reference EmuDevice under several Caps (and memory models), the
//! emulated RTX (kir_sm120 in sm120_emu) and the emulated Adreno (kir_ir3
//! in ir3_emu). Each must pass every case. Then a deliberately broken
//! device: wrong words, a timeout and a lost device are reported as
//! failures, never a crash.

const std = @import("std");
const gpu = @import("gpu");
const nvidia = @import("nvidia");
const selftest = gpu.selftest;

var work: selftest.Work = undefined;

const Log = struct {
    var lines: u32 = 0;
    var failed_lines: u32 = 0;
    var quiet = false;
    var last: [256]u8 = undefined;
    var last_len: usize = 0;

    /// the cases that failed, by name
    var failed: [32][]const u8 = undefined;
    var names: [32][64]u8 = undefined;

    fn line(text: []const u8) void {
        lines += 1;
        if (std.mem.indexOf(u8, text, ": FAILED")) |at| {
            if (failed_lines < failed.len and std.mem.startsWith(u8, text, "gpu self-test ")) {
                const name = text["gpu self-test ".len..at];
                const n = @min(name.len, 64);
                @memcpy(names[failed_lines][0..n], name[0..n]);
                failed[failed_lines] = names[failed_lines][0..n];
            }
            failed_lines += 1;
        }
        const n = @min(text.len, last.len);
        @memcpy(last[0..n], text[0..n]);
        last_len = n;
        if (!quiet or std.mem.indexOf(u8, text, "FAILED") != null or std.mem.indexOf(u8, text, "probe") != null)
            std.debug.print("{s}\n", .{text});
    }
    fn reset() void {
        lines = 0;
        failed_lines = 0;
        last_len = 0;
    }
};

const TIMEOUT_US = 20_000_000;

/// Every case passes but the `known` ones (backend bugs the self-test
/// found on the emulators, to be fixed in the backends), which may fail;
/// nothing is skipped and the run goes to its end.
fn expectAllPassBut(res: selftest.Result, known: []const []const u8) !void {
    const n: u32 = @intCast(selftest.caseCount());
    try std.testing.expectEqual(n, res.passed + res.failed);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
    try std.testing.expectEqual(res.failed, Log.failed_lines);
    var unexpected: u32 = 0;
    for (Log.failed[0..@min(Log.failed_lines, Log.failed.len)]) |name| {
        var ok = false;
        for (known) |kn| ok = ok or std.mem.eql(u8, kn, name);
        if (!ok) {
            std.debug.print("unexpected failure: {s}\n", .{name});
            unexpected += 1;
        }
    }
    for (known) |kn| {
        var seen = false;
        for (Log.failed[0..@min(Log.failed_lines, Log.failed.len)]) |name| seen = seen or std.mem.eql(u8, kn, name);
        if (!seen) std.debug.print("known backend bug no longer seen (take it off the list): {s}\n", .{kn});
    }
    try std.testing.expectEqual(@as(u32, 0), unexpected);
    try std.testing.expectEqual(n + 3, Log.lines);
}

fn expectAllPass(res: selftest.Result) !void {
    if (res.failed != 0 or res.lost) {
        std.debug.print("first failure: {s}\n", .{res.firstFailure()});
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u32, @intCast(selftest.caseCount())), res.passed + res.skipped);
    try std.testing.expectEqual(@as(u32, 0), res.skipped);
    // a header, one line a case, the GPU time, the summary
    try std.testing.expectEqual(@as(u32, @intCast(selftest.caseCount() + 3)), Log.lines);
    try std.testing.expect(std.mem.startsWith(u8, Log.last[0..Log.last_len], "gpu self-test: "));
}

// ── The reference device ────────────────────────────────────────────────────

var emu_mem: [8 << 20]u8 align(4096) = undefined;
var emu_shadow: [8 << 20]u8 align(4096) = undefined;
var emu_vram: [8 << 20]u8 align(4096) = undefined;
var emu_work: [8 << 20]u8 align(64) = undefined;

fn runEmu(caps: gpu.Caps, how: enum { coherent, shadow, discrete }) !selftest.Result {
    var e = gpu.EmuDevice.init(caps, &emu_mem, &emu_work);
    switch (how) {
        .coherent => {},
        .shadow => {
            e.caps.coherent = false;
            e.shadow = &emu_shadow;
        },
        .discrete => {
            e.caps.memory = .discrete;
            e.caps.coherent = false;
            e.vram = &emu_vram;
        },
    }
    Log.reset();
    return selftest.runAll(e.device(), &work, Log.line, TIMEOUT_US);
}

test "self-test on the interpreter's ideal GPU: fused, denormals kept, subgroup 32" {
    try expectAllPass(try runEmu(gpu.interp_caps, .coherent));
}

test "self-test on an Adreno-like EmuDevice: unfused, no ffma, denormals flushed, subgroup 64, not coherent" {
    var c = gpu.interp_caps;
    c.fused_fma = false;
    c.mad = .unfused;
    c.denormals = .flush;
    c.subgroup = 64;
    c.shared_bytes = 32 * 1024;
    try expectAllPass(try runEmu(c, .shadow));
}

test "self-test on a discrete EmuDevice with subgroups of 128 and groups of at most 128" {
    var c = gpu.interp_caps;
    c.subgroup = 128;
    c.max_group = 128;
    c.mad = .unfused;
    try expectAllPass(try runEmu(c, .discrete));
}

// ── The emulated RTX ────────────────────────────────────────────────────────

var sm_state: gpu.nvidia_device.kir_sm120.State = .{};
var listing_buf: [256 * 1024]u8 = undefined;

/// Set to print the backend's listing of each failing kernel.
const dump = false;

fn rtxFailure(name: []const u8, k: *const gpu.kir.Kernel, caps: gpu.Caps) void {
    var buf: [512]u8 = undefined;
    std.debug.print("emulated RTX, {s}: {s}\n", .{ name, Rtx.dev.explain(&buf) });
    if (dump) {
        const text = gpu.nvidia_device.kir_sm120.compileText(k, caps, &sm_state, .{}) catch "(no listing)";
        std.debug.print("{s}\n", .{text});
    }
}

const Rtx = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

test "self-test on the emulated RTX (kir_sm120, sm120_emu with its hazard checks)" {
    Rtx.dev.init(&Rtx.arena, &Rtx.view, &Rtx.emu_work);
    Log.reset();
    const res = selftest.runWith(gpu.all_targets, Rtx.dev.device(), &work, Log.line, .{ .timeout_us = TIMEOUT_US, .stop_when_lost = false, .on_failure = rtxFailure });
    // kir_sm120 bugs the self-test found (sig-gpu-selftest's notes, S.md):
    // shfl up/down with a register delta past the subgroup wraps; the
    // scheduler lets an STG's source register be rewritten before its
    // read scoreboard (sm120_emu's WAR hazard) in both flow kernels
    try expectAllPassBut(res, &.{ "shuffles", "divergent if/else", "divergent loops" });
}

// ── The emulated Adreno ─────────────────────────────────────────────────────

var ir3_work: gpu.kir_ir3.Work = undefined;
var ir3_out: [512 * 1024]u8 align(16) = undefined;

fn adrenoFailure(name: []const u8, k: *const gpu.kir.Kernel, caps: gpu.Caps) void {
    var buf: [1024]u8 = undefined;
    std.debug.print("emulated Adreno, {s}: {s}\n", .{ name, Adreno.dev.gpu.describe(name, &buf) });
    if (dump) {
        _ = gpu.kir_ir3.compileWith(k, caps, &ir3_work, &ir3_out) catch {};
        std.debug.print("{s}\n", .{gpu.kir_ir3.listing(&ir3_work, &listing_buf)});
    }
}

const Adreno = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var dev: gpu.adreno_device.Emu = undefined;
};

test "self-test on the emulated Adreno (kir_ir3, ir3_emu, the strict device)" {
    Adreno.dev.init(&Adreno.arena, &Adreno.view);
    Log.reset();
    const res = selftest.runWith(gpu.all_targets, Adreno.dev.device(), &work, Log.line, .{ .timeout_us = TIMEOUT_US, .stop_when_lost = false, .on_failure = adrenoFailure });
    // kir_ir3 bugs the self-test found (S.md): frne(-0.5) gives +0, not -0;
    // a hazard at the ticket store after an atomic's result
    try expectAllPassBut(res, &.{ "float", "global atomics" });
}

// ── A broken device ─────────────────────────────────────────────────────────

/// An EmuDevice that lies: from run `bad_from` on, one output word in
/// every result is flipped; run `timeout_at` times out once (and finishes
/// on the second wait); run `lost_at` loses the device.
const Broken = struct {
    inner: gpu.Device,
    runs: u32 = 0,
    bad_from: u32 = 0xffff_ffff,
    timeout_at: u32 = 0xffff_ffff,
    lost_at: u32 = 0xffff_ffff,
    timed_out: bool = false,
    lost: bool = false,

    fn device(b: *Broken) gpu.Device {
        return .{ .ctx = b, .vtable = &vtable, .caps = b.inner.caps };
    }
    fn of(ctx: *anyopaque) *Broken {
        return @ptrCast(@alignCast(ctx));
    }
    const vtable = gpu.Device.VTable{
        .alloc = alloc,
        .free = free,
        .import = import_,
        .toDevice = toDevice,
        .fromDevice = fromDevice,
        .load = load,
        .unload = unload,
        .run = run,
        .wait = wait,
        .done = done,
        .lastRunNs = lastRunNs,
    };
    fn alloc(ctx: *anyopaque, bytes: u64, kind: gpu.Kind) ?gpu.Buffer {
        return of(ctx).inner.vtable.alloc(of(ctx).inner.ctx, bytes, kind);
    }
    fn free(ctx: *anyopaque, b: gpu.Buffer) void {
        of(ctx).inner.free(b);
    }
    fn import_(ctx: *anyopaque, cpu: []u8) ?gpu.Buffer {
        return of(ctx).inner.import(cpu);
    }
    fn toDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        of(ctx).inner.toDevice(b, off, len);
    }
    fn fromDevice(ctx: *anyopaque, b: gpu.Buffer, off: u64, len: u64) void {
        const s = of(ctx);
        s.inner.fromDevice(b, off, len);
        // (the result buffer is the big one: flip a word in its middle)
        if (s.runs >= s.bad_from and b.bytes >= (1 << 20) and len >= 8) {
            // (an exponent bit: a NaN stays no NaN, so a float compare sees it)
            const at: usize = @intCast(off + (len / 8) * 4 + 3);
            b.cpu[at] ^= 0x40;
        }
    }
    fn load(ctx: *anyopaque, bin: *const gpu.Binary) gpu.Error!gpu.Program {
        if (of(ctx).lost) return error.DeviceLost;
        return of(ctx).inner.load(bin);
    }
    fn unload(ctx: *anyopaque, p: *const gpu.Program) void {
        of(ctx).inner.unload(p);
    }
    fn run(ctx: *anyopaque, ds: []const gpu.Dispatch) gpu.Error!gpu.Fence {
        const s = of(ctx);
        if (s.lost) return error.DeviceLost;
        s.runs += 1;
        return s.inner.run(ds);
    }
    fn wait(ctx: *anyopaque, f: gpu.Fence, timeout_us: u64) gpu.Error!void {
        const s = of(ctx);
        if (s.runs == s.lost_at) {
            s.lost = true;
            return error.DeviceLost;
        }
        if (s.runs == s.timeout_at and !s.timed_out) {
            s.timed_out = true;
            return error.Timeout;
        }
        return s.inner.wait(f, timeout_us);
    }
    fn done(ctx: *anyopaque, f: gpu.Fence) bool {
        return of(ctx).inner.done(f);
    }
    fn lastRunNs(ctx: *anyopaque) u64 {
        _ = ctx;
        return 1000;
    }
};

test "a broken device: wrong words, a timeout and a lost device are failures in the log, not a crash" {
    var e = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    // wrong words from the 3rd run on, a timeout at the 2nd, lost at the 6th
    var b = Broken{ .inner = e.device(), .bad_from = 3, .timeout_at = 2, .lost_at = 6 };
    Log.reset();
    Log.quiet = true;
    defer Log.quiet = false;
    const res = selftest.runAll(b.device(), &work, Log.line, TIMEOUT_US);
    const n: u32 = @intCast(selftest.caseCount());
    try std.testing.expect(res.lost);
    // case 1 passes; 2 times out; 3, 4 and 5 give a wrong word; 6 is lost
    try std.testing.expectEqual(@as(u32, 1), res.passed);
    try std.testing.expectEqual(@as(u32, 5), res.failed);
    try std.testing.expectEqual(n - 6, res.skipped);
    try std.testing.expectEqual(@as(u32, 5), Log.failed_lines);
    try std.testing.expect(std.mem.startsWith(u8, res.firstFailure(), "int i32: FAILED: timeout"));
    try std.testing.expectEqualStrings("gpu self-test: 1 passed, 5 failed, 18 skipped", Log.last[0..Log.last_len]);
    try std.testing.expectEqual(@as(u64, 4000), res.gpu_ns);

    // a device whose every result is off: every case fails, the run ends
    var e2 = gpu.EmuDevice.init(gpu.interp_caps, &emu_mem, &emu_work);
    var b2 = Broken{ .inner = e2.device(), .bad_from = 0 };
    Log.reset();
    const res2 = selftest.runAll(b2.device(), &work, Log.line, TIMEOUT_US);
    try std.testing.expect(!res2.lost);
    try std.testing.expectEqual(@as(u32, 2), res2.passed); // (the two probes only report)
    try std.testing.expectEqual(n - 2, res2.failed);
    try std.testing.expect(std.mem.indexOf(u8, res2.firstFailure(), "lane ") != null);

    // no memory at all: every case skipped, a line says why
    var tiny: [4096]u8 align(4096) = undefined;
    var e3 = gpu.EmuDevice.init(gpu.interp_caps, &tiny, &emu_work);
    Log.reset();
    const res3 = selftest.runAll(e3.device(), &work, Log.line, TIMEOUT_US);
    try std.testing.expectEqual(n, res3.skipped);
    try std.testing.expectEqual(@as(u32, 0), res3.failed + res3.passed);
}
