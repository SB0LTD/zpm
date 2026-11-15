//! dxgtest: zpm's dxg module on the real GPU (WSL, /dev/dxg), no NVIDIA
//! library, no libc:
//!   1. a host semaphore release run and waited for (Gpu.submit, wait);
//!   2. 1100 submissions in a row: the GPFIFO ring (1024 entries) wraps;
//!   3. zpm's GPU self-test (KIR kernels compiled for sm_120, run through
//!      gpu.nvidia_device over dxg's DxgDevice, every result checked
//!      against KIR's interpreter).
//!
//!   sig build-exe -target x86_64-linux -OReleaseSafe
//!     --dep dxg --dep gpu --dep nvidia -Mroot=tools/dxgtest.sig
//!     --dep nvidia -Mdxg=src/dxg/dxg.sig
//!     --dep nvidia --dep adreno --dep amdgpu -Mgpu=src/gpu/gpu.sig
//!     -Mnvidia=src/nvidia/nvidia.sig -Madreno=src/adreno/adreno.sig
//!     -Mamdgpu=src/amdgpu/amdgpu.sig --name dxgtest
//!   ./dxgtest [selftest]

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const gpu = @import("gpu");
const nvidia = @import("nvidia");
const push = nvidia.push;

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn logLine(line: []const u8) void {
    _ = linux.write(1, line.ptr, line.len);
    _ = linux.write(1, "\n", 1);
}

fn mapMemory(bytes: usize) []align(4096) u8 {
    const m: isize = @bitCast(linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
    if (m < 0) {
        out("dxgtest: no memory ({d} bytes)\n", .{bytes});
        linux.exit(2);
    }
    const p: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..bytes];
}

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Which writes reach the queue's progress fence (host 32-bit, host
/// 64-bit, the compute engine's report as NVIDIA's driver writes it),
/// each followed by a host release to our own memory to show the GPU is
/// still running.
fn probeFence(r: dxg.gpu.Region, mem: []align(4096) u8) void {
    const pb: [*]u32 = @ptrCast(@alignCast(mem.ptr + 0x1000));
    const pb_va = r.va + 0x1000;
    const sem: *volatile u32 = @ptrCast(@alignCast(mem.ptr + 0x8_0000));
    const tries = [_][]const u8{ "host 32-bit", "host 64-bit", "compute report (NVIDIA's)" };
    for (tries, 0..) |name, k| {
        var p = push.Push{ .buf = pb[0..64] };
        const v: u32 = 100 + @as(u32, @intCast(k));
        switch (k) {
            0 => p.release(g.progress_gpu, v),
            1 => p.method(0, push.SEM_ADDR_LO, &.{ @truncate(g.progress_gpu), @truncate(g.progress_gpu >> 32), v, 0, push.SEM_OPERATION_RELEASE | push.SEM_RELEASE_WFI | push.SEM_PAYLOAD_64BIT }),
            else => {
                p.setObject(push.SUBCH_COMPUTE, push.BLACKWELL_COMPUTE_B);
                // SET_REPORT_SEMAPHORE_A..D (0x1b00): address, payload, NVIDIA's 0x10000004
                p.method(push.SUBCH_COMPUTE, 0x1b00, &.{ @truncate(g.progress_gpu >> 32), @truncate(g.progress_gpu), v, 0x1000_0004 });
            },
        }
        p.release(r.va + 0x8_0000, 0x7700 + v);
        const words: u32 = @intCast(p.len);
        // straight into the ring, no fence entry: rung by hand
        const ring: [*]volatile u64 = @ptrCast(@alignCast(g.ring.cpu.ptr));
        ring[@intCast(g.put % dxg.gpu.GPFIFO_ENTRIES)] = push.gpEntry(pb_va, words) | dxg.nv.ENTRY_SUBROUTINE;
        g.put += 1;
        ring[@intCast(g.put % dxg.gpu.GPFIFO_ENTRIES)] = 0;
        g.fence += 1;
        dxg.nv.submit(&g.submit_data, g.fence);
        var s = dxg.kmt.SubmitToHwQueue{ .queue = g.queue, .progress_fence = g.fence, .command_buffer = dxg.nv.SUBMIT_COMMAND_BUFFER, .command_length = 1, .priv_size = dxg.nv.SUBMIT_BYTES, .priv = @intFromPtr(&g.submit_data) };
        _ = dxg.kmt.call(g.fd, .submit_to_hw_queue, &s) catch {};
        var t: u32 = 0;
        while (t < 500 and sem.* != 0x7700 + v) : (t += 1) {
            const ms: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
            _ = linux.nanosleep(&ms, null);
        }
        out("   {s}: progress {d} (want {d}), GPU {s}\n", .{ name, g.progress.*, v, if (sem.* == 0x7700 + v) "still running" else "STOPPED" });
    }
}

var g: dxg.Gpu = .{};
var dev: dxg.DxgDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var work: gpu.selftest.Work = undefined;

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    const ring = mapMemory(dxg.gpu.RING_BYTES);
    const t0 = nowUs();
    g.open(ring, .{ .name = "zpm-dxgtest" }) catch |e| {
        out("dxgtest: open: {s} (call {x}, status {d})\n", .{ @errorName(e), dxg.kmt.last_nr, dxg.kmt.last_status });
        linux.exit(1);
    };
    out("open: {x}:{x} (adapter {x}), device {x}, context {x}, queue {x}, ring 0x{x}, progress at 0x{x} = {d} ({d} us)\n", .{
        g.ids.vendor, g.ids.device, g.adapter, g.device, g.context, g.queue, g.ring.va, g.progress_gpu, g.progress.*, nowUs() - t0,
    });

    // 1. a semaphore release
    const mem = mapMemory(1 << 20);
    const r = g.mapSystem(mem) catch |e| {
        out("dxgtest: map: {s} (status {d})\n", .{ @errorName(e), dxg.kmt.last_status });
        linux.exit(1);
    };
    const pb: [*]u32 = @ptrCast(@alignCast(mem.ptr));
    const sem: *volatile u32 = @ptrCast(@alignCast(mem.ptr + 0x8_0000));
    sem.* = 0;
    const n = push.hostRelease(pb[0..16], r.va + 0x8_0000, 0x600d_0001) catch unreachable;
    const t1 = nowUs();
    const f = g.submit(r.va, @intCast(n)) catch |e| {
        out("dxgtest: submit: {s} (status {d})\n", .{ @errorName(e), dxg.kmt.last_status });
        linux.exit(1);
    };
    g.wait(f, 1_000_000) catch {
        out("1. FAILED: fence {d} not reached (progress {d}, semaphore {x})\n", .{ f, g.progress.*, sem.* });
        probeFence(r, mem);
        linux.exit(1);
    };
    out("1. semaphore release: {s} ({d} us, fence {d})\n", .{ if (sem.* == 0x600d_0001) "ok" else "WRONG", nowUs() - t1, f });

    // 2. 1100 submissions: the ring wraps
    const t2 = nowUs();
    var i: u32 = 0;
    var bad: u32 = 0;
    while (i < 1100) : (i += 1) {
        _ = push.hostRelease(pb[0..16], r.va + 0x8_0000, i) catch unreachable;
        const fi = g.submit(r.va, @intCast(n)) catch {
            bad += 1;
            break;
        };
        const ts = nowUs();
        g.wait(fi, 1_000_000) catch {
            out("2. submission {d} (ring entry {d}): progress {d} after 1 s; semaphore {d}\n", .{ i, g.put, g.progress.*, sem.* });
            g.wait(fi, 4_000_000) catch {
                out("   still {d} after 5 s; ringing again\n", .{g.progress.*});
                g.ring_again() catch {};
                g.wait(fi, 1_000_000) catch {
                    out("   FAILED: still {d}\n", .{g.progress.*});
                    linux.exit(1);
                };
                out("   ran after a second doorbell\n", .{});
                continue;
            };
            out("   ran late: {d} us\n", .{nowUs() - ts});
            continue;
        };
        if (sem.* != i) {
            if (bad < 4) out("   submission {d} (entries to {d}, fence {d}): semaphore {d}, progress {d}\n", .{ i, g.put, fi, sem.*, g.progress.* });
            bad += 1;
        }
    }
    out("2. {d} submissions (ring entries {d}): {d} wrong, {d} us each\n", .{ i, g.put, bad, (nowUs() - t2) / @max(i, 1) });

    if (argv.len < 2 or !std.mem.eql(u8, std.mem.span(argv[1]), "selftest")) {
        g.close();
        return;
    }
    // 3. zpm's GPU self-test over DxgDevice
    const arena = mapMemory(256 << 20);
    dev.init(&g, arena);
    const d = gpu.nvidia_device.over(&adapter, dev.device(), null, gpu.nvidia_device.rtx5070(arena.len));
    const t3 = nowUs();
    const res = gpu.selftest.runAll(d, &work, logLine, 2_000_000);
    out("3. self-test: {d} passed, {d} failed, {d} skipped ({d} ms)\n", .{ res.passed, res.failed, res.skipped, (nowUs() - t3) / 1000 });
    g.close();
    linux.exit(if (res.failed == 0) 0 else 3);
}
