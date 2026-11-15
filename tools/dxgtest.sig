//! dxgtest: zpm's dxg module on the real GPU (WSL, /dev/dxg), no NVIDIA
//! library, no libc:
//!   1. a host semaphore release run and waited for (Gpu.submit, wait);
//!   2. 1100 submissions in a row: the GPFIFO ring (1024 entries) wraps;
//!   3. `selftest`: zpm's GPU self-test (KIR kernels compiled for sm_120,
//!      run through gpu.nvidia_device over dxg's DxgDevice, every result
//!      checked against KIR's interpreter);
//!   4. `draw` (`draw edges`): the 3D engine's hardware test
//!      (gpu.nvidia_draw.hardwareTest: each case drawn by the rasteriser and
//!      compared pixel for pixel with the CPU's, then the fill rate);
//!   `bisect3d`: which method of the 3D engine's state a channel faults on.
//! DXGTEST_CLIENT (the context's client kind, default 5) and
//! DXGTEST_ENGINES (the queue's engines, hex, default 900) for trying
//! others.
//!
//!   sig build-exe -target x86_64-linux -OReleaseSafe
//!     --dep dxg --dep gpu --dep nvidia -Mroot=tools/dxgtest.sig
//!     --dep nvidia -Mdxg=src/dxg/dxg.sig
//!     --dep nvidia --dep adreno --dep amdgpu -Mgpu=src/gpu/gpu.sig
//!     -Mnvidia=src/nvidia/nvidia.sig -Madreno=src/adreno/adreno.sig
//!     -Mamdgpu=src/amdgpu/amdgpu.sig --name dxgtest
//!   ./dxgtest [selftest | draw [edges] | bisect3d]

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

/// Which method of the 3D engine's state (nvidia.draw.setup, then a
/// target) the channel faults on: the first N methods sent on a fresh
/// channel each time, N bisected.
fn bisect3d(ring: []align(4096) u8, client: u32) noreturn {
    const mem = mapMemory(4 << 20);
    var words: [4096]u32 = undefined;
    var starts: [1024]usize = undefined; // each method header's index
    var nstarts: usize = 0;
    var lo: usize = 0; // methods known good
    var hi: usize = 0; // methods known bad (set after the first full run)
    var round: u32 = 0;
    var have_hi = false;
    while (true) : (round += 1) {
        ch.close();
        g.close();
        openAll(ring, client);
        const r = g.mapSystem(mem) catch linux.exit(1);
        // the state, built at this mapping's addresses
        var p = push.Push{ .buf = &words };
        nvidia.draw.setup(&p, r.va + 0x10_0000, r.va + 0x11_0000, r.va + 0x12_0000, 64);
        nvidia.draw.target(&p, .{ .va = r.va + 0x20_0000, .width = 64, .height = 32, .pitch = 256, .format = .bgra8 });
        p.check() catch linux.exit(1);
        if (nstarts == 0) {
            var i: usize = 0;
            while (i < p.len) {
                starts[nstarts] = i;
                nstarts += 1;
                const h = push.parseHeader(words[i]);
                i += 1 + (if (h.op == 4) 0 else h.count);
            }
            hi = nstarts;
        }
        const n = if (!have_hi) nstarts else (lo + hi) / 2;
        const dwords: usize = if (n >= nstarts) p.len else starts[n];
        const pb: [*]u32 = @ptrCast(@alignCast(mem.ptr));
        @memcpy(pb[0..dwords], words[0..dwords]);
        const f = ch.submit(r.va, @intCast(dwords)) catch linux.exit(1);
        const ok = if (ch.wait(f, 500_000)) |_| true else |_| false;
        out("bisect: first {d} of {d} methods: {s}\n", .{ n, nstarts, if (ok) "ok" else "FAULT" });
        if (!have_hi) {
            if (ok) {
                out("bisect: the whole state runs\n", .{});
                linux.exit(0);
            }
            have_hi = true;
            continue;
        }
        if (ok) lo = n else hi = n;
        if (hi - lo <= 1) {
            const at = starts[lo];
            const h = push.parseHeader(words[at]);
            out("bisect: method {d} faults: subchannel {d}, method 0x{x}, op {d}, {d} words:", .{ lo, h.subch, h.method, h.op, h.count });
            const cnt: usize = if (h.op == 4) 0 else h.count;
            for (words[at + 1 ..][0..@min(cnt, 8)]) |w| out(" {x}", .{w});
            out("\n", .{});
            linux.exit(0);
        }
    }
}

var g: dxg.Gpu = .{};
var ch: dxg.Channel = .{};

fn openAll(ring: []align(4096) u8, client: u32) void {
    g.open(.{ .name = "zpm-dxgtest" }) catch |e| {
        out("dxgtest: open: {s} (call {x}, status {d})\n", .{ @errorName(e), dxg.kmt.last_nr, dxg.kmt.last_status });
        linux.exit(1);
    };
    ch.open(&g, ring, .{ .name = "zpm-dxgtest", .client = client, .engines = engines }) catch |e| {
        out("dxgtest: channel: {s} (call {x}, status {d})\n", .{ @errorName(e), dxg.kmt.last_nr, dxg.kmt.last_status });
        linux.exit(1);
    };
}
var engines: u32 = 0;
var dev: dxg.DxgDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var work: gpu.selftest.Work = undefined;
var over3d: gpu.nvidia_draw.Over = undefined;
var kst: gpu.nvidia_device.kir_sm120.State = undefined;
var model: gpu.draw.Reference = undefined;

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    const ring = mapMemory(dxg.gpu.RING_BYTES);
    const t0 = nowUs();
    // DXGTEST_CLIENT: the context's client kind (default CUDA's 5)
    var client: u32 = 5;
    engines = dxg.nv.ENGINES_DIRECT;
    for (init.minimal.environ.block.slice) |e| {
        const kv = std.mem.span(e orelse continue);
        if (std.mem.startsWith(u8, kv, "DXGTEST_CLIENT=")) client = std.fmt.parseInt(u32, kv[15..], 10) catch 5;
        if (std.mem.startsWith(u8, kv, "DXGTEST_ENGINES=")) engines = std.fmt.parseInt(u32, kv[16..], 16) catch engines;
    }
    openAll(ring, client);
    out("open: {x}:{x} (adapter {x}), device {x}, context {x}, queue {x}, ring 0x{x}, progress at 0x{x} = {d} ({d} us)\n", .{
        g.ids.vendor, g.ids.device, g.adapter, g.device, ch.context, ch.queue, ch.ring.va, ch.progress_gpu, ch.progress.*, nowUs() - t0,
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
    const f = ch.submit(r.va, @intCast(n)) catch |e| {
        out("dxgtest: submit: {s} (status {d})\n", .{ @errorName(e), dxg.kmt.last_status });
        linux.exit(1);
    };
    ch.wait(f, 1_000_000) catch {
        out("1. FAILED: fence {d} not reached (progress {d}, semaphore {x})\n", .{ f, ch.progress.*, sem.* });
        linux.exit(1);
    };
    out("1. semaphore release: {s} ({d} us, fence {d})\n", .{ if (sem.* == 0x600d_0001) "ok" else "WRONG", nowUs() - t1, f });

    // 2. 1100 submissions: the ring wraps
    const t2 = nowUs();
    var i: u32 = 0;
    var bad: u32 = 0;
    while (i < 1100) : (i += 1) {
        _ = push.hostRelease(pb[0..16], r.va + 0x8_0000, i) catch unreachable;
        const fi = ch.submit(r.va, @intCast(n)) catch {
            bad += 1;
            break;
        };
        const ts = nowUs();
        ch.wait(fi, 1_000_000) catch {
            out("2. submission {d} (ring entry {d}): progress {d} after 1 s; semaphore {d}\n", .{ i, ch.put, ch.progress.*, sem.* });
            ch.wait(fi, 4_000_000) catch {
                out("   still {d} after 5 s; ringing again\n", .{ch.progress.*});
                ch.ringAgain() catch {};
                ch.wait(fi, 1_000_000) catch {
                    out("   FAILED: still {d}\n", .{ch.progress.*});
                    linux.exit(1);
                };
                out("   ran after a second doorbell\n", .{});
                continue;
            };
            out("   ran late: {d} us\n", .{nowUs() - ts});
            continue;
        };
        if (sem.* != i) {
            if (bad < 4) out("   submission {d} (entries to {d}, fence {d}): semaphore {d}, progress {d}\n", .{ i, ch.put, fi, sem.*, ch.progress.* });
            bad += 1;
        }
    }
    out("2. {d} submissions (ring entries {d}): {d} wrong, {d} us each\n", .{ i, ch.put, bad, (nowUs() - t2) / @max(i, 1) });

    const mode: []const u8 = if (argv.len < 2) "" else std.mem.span(argv[1]);
    if (std.mem.eql(u8, mode, "bisect3d")) bisect3d(ring, client);
    if (std.mem.eql(u8, mode, "bench3d")) bench3d();
    if (std.mem.eql(u8, mode, "draw")) {
        // 4. the 3D engine (the rasteriser), step by step, each pass's
        // pixels compared with the CPU reference's
        const arena = mapMemory(256 << 20);
        dev.init(&g, &ch, arena);
        const d = gpu.nvidia_device.over(&adapter, dev.device(), null, gpu.nvidia_device.withGraphics(gpu.nvidia_device.rtx5070(arena.len)));
        model = .{ .mem = mapMemory(64 << 20) };
        // ("draw edges": step 4 too, the graphics dispatches through the
        // GPU-neutral adapter)
        const edges = argv.len > 2 and std.mem.eql(u8, std.mem.span(argv[2]), "edges");
        const t4 = nowUs();
        const h = gpu.nvidia_draw.hardwareTest(dev.device(), if (edges) d else null, &over3d, &kst, &model, logLine, nowUs);
        out("4. 3D engine: started {}, object {}, state {}, {d} passed, {d} failed, lost {}, {d} Mpx/s ({d} ms)\n", .{ h.started, h.object, h.state, h.passed, h.failed, h.lost, h.mpx_per_s, (nowUs() - t4) / 1000 });
        ch.close();
        g.close();
        linux.exit(if (h.failed == 0 and !h.lost and h.object) 0 else 3);
    }
    if (!std.mem.eql(u8, mode, "selftest")) {
        ch.close();
        g.close();
        return;
    }
    // 3. zpm's GPU self-test over DxgDevice
    const arena = mapMemory(256 << 20);
    dev.init(&g, &ch, arena);
    const d = gpu.nvidia_device.over(&adapter, dev.device(), null, gpu.nvidia_device.rtx5070(arena.len));
    const t3 = nowUs();
    const res = gpu.selftest.runAll(d, &work, logLine, 2_000_000);
    out("3. self-test: {d} passed, {d} failed, {d} skipped ({d} ms)\n", .{ res.passed, res.failed, res.skipped, (nowUs() - t3) / 1000 });
    ch.close();
    g.close();
    linux.exit(if (res.failed == 0) 0 else 3);
}

// â”€â”€ bench3d: what a frame's pass costs on the 3D engine â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

var bench_work: nvidia.sm120_asm.Work = .{};
var bench_r: nvidia.draw.Renderer = undefined;

/// Timings of one pass each (submit to fence, 5 runs, the best): a 1280 x
/// 800 image read from system memory, then from VRAM, into a VRAM target
/// and a system-memory one; 48 retargets (each a WAIT_FOR_IDLE) with a
/// small blur between; 266 small rectangles.
fn bench3d() noreturn {
    const W = 1280;
    const H = 800;
    const bytes = W * H * 4;
    const arena = mapMemory(64 << 20);
    dev.init(&g, &ch, arena);
    const d = dev.device();
    bench_r.init(d, &bench_work, .{ .stream_bytes = 512 * 1024, .rects = 1024, .textures = 255 }) catch |e| {
        out("bench: renderer: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    const sys_img = d.alloc(bytes) catch linux.exit(1);
    const sys_tgt = d.alloc(bytes) catch linux.exit(1);
    for (0..W * H) |i| std.mem.writeInt(u32, sys_img.cpu[i * 4 ..][0..4], @intCast(0xff00_0000 | (i *% 2654435761) & 0xffffff), .little);
    const vimg = g.allocVideo(std.mem.alignForward(u64, bytes, 64 << 10)) catch linux.exit(1);
    const vtgt = g.allocVideo(std.mem.alignForward(u64, bytes, 64 << 10)) catch linux.exit(1);
    const scratch = g.allocVideo(4 << 20) catch linux.exit(1);
    const full = [4]f32{ 0, 0, W, H };
    const one = [4]f32{ 1, 1, 1, 1 };
    const Tex = nvidia.draw.Texture;
    const Tgt = nvidia.draw.Target;
    const tex_sys = Tex{ .va = sys_img.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8, .filter = .nearest };
    const tex_vid = Tex{ .va = vimg.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8, .filter = .nearest };
    const t_vid = Tgt{ .va = vtgt.va, .width = W, .height = H, .pitch = W * 4 };
    const t_sys = Tgt{ .va = sys_tgt.va, .width = W, .height = H, .pitch = W * 4 };
    const cases = [_][]const u8{ "empty pass (VRAM target)", "image sys -> VRAM", "image VRAM -> VRAM", "image sys -> sys", "image VRAM -> sys", "48 retargets + blurs (VRAM)", "266 rects 64x64 over (VRAM)" };
    for (cases, 0..) |name, k| {
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| {
            bench_r.begin(if (k == 3 or k == 4) t_sys else t_vid);
            switch (k) {
                0 => {},
                1 => bench_r.image(full, tex_sys, full, one, .replace),
                2 => bench_r.image(full, tex_vid, full, one, .replace),
                3 => bench_r.image(full, tex_sys, full, one, .replace),
                4 => bench_r.image(full, tex_vid, full, one, .replace),
                5 => {
                    const st = Tgt{ .va = scratch.va, .width = 320, .height = 64, .pitch = 2048 };
                    const sx = Tex{ .va = scratch.va, .width = 320, .height = 64, .pitch = 2048, .format = .bgra8, .filter = .linear };
                    for (0..48) |_| {
                        bench_r.retarget(st);
                        _ = bench_r.box(.{ 0, 0, 320, 64 }, sx, true, 6, .replace);
                    }
                    bench_r.retarget(t_vid);
                },
                else => {
                    for (0..266) |i| {
                        const x: f32 = @floatFromInt((i * 97) % (W - 64));
                        const y: f32 = @floatFromInt((i * 53) % (H - 64));
                        bench_r.fill(.{ x, y, x + 64, y + 64 }, .{ 0.2, 0.3, 0.4, 0.5 }, .over);
                    }
                },
            }
            const t0 = nowUs();
            bench_r.run(2_000_000) catch |e| {
                out("bench {s}: {s}\n", .{ name, @errorName(e) });
                linux.exit(1);
            };
            best = @min(best, nowUs() - t0);
        }
        out("bench: {s}: {d} us\n", .{ name, best });
    }
    linux.exit(0);
}
