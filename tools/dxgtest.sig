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
    ch.open(&g, ring, .{ .name = "zpm-dxgtest", .client = client, .engines = engines, .context_data = if (ctx_len != 0) ctx_data[0..ctx_len] else null, .context_flags = ctx_flags, .node = node, .queue_flags = queue_flags }) catch |e| {
        out("dxgtest: channel: {s} (call {x}, status {d})\n", .{ @errorName(e), dxg.kmt.last_nr, dxg.kmt.last_status });
        linux.exit(1);
    };
}
var engines: u32 = 0;
/// DXGTEST_CTXDATA=file: the context's private data as recorded (any
/// length up to MAX_CONTEXT_BYTES), DXGTEST_CTXFLAGS=hex: the call's
/// flags; DXGTEST_NODE=n: the context's node; DXGTEST_QFLAGS=hex: the
/// queue's flags.
var ctx_data: [dxg.gpu.MAX_CONTEXT_BYTES]u8 = undefined;
var ctx_len: usize = 0;
var node: ?u32 = null;
var queue_flags: u32 = 1;
/// DXGTEST_PRELUDE=file ((method, value) u32 pairs; DXGTEST_FROM / _TO:
/// the part sent): gl3d.prelude.
var prelude_buf: [2048][2]u32 = undefined;
var prelude_n: usize = 0;
var prelude_from: usize = 0;
var prelude_to: usize = 1 << 30;

/// DXGTEST_POSTLUDE=file: (method, value) u32 pairs sent after the depth
/// target's binding (gl3d.postlude).
var postlude_buf: [256][2]u32 = undefined;

fn loadPostlude(path: [*:0]const u8) void {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), std.mem.sliceAsBytes(&postlude_buf).ptr, @sizeOf(@TypeOf(postlude_buf)));
    nvidia.gl3d.postlude = postlude_buf[0 .. n / 8];
    out("postlude: {d} methods\n", .{n / 8});
}

fn loadPrelude(path: [*:0]const u8) void {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    const n = linux.read(@intCast(fd), std.mem.sliceAsBytes(&prelude_buf).ptr, @sizeOf(@TypeOf(prelude_buf)));
    prelude_n = n / 8;
}
var ctx_flags: u32 = 0;

fn loadCtx(path: [*:0]const u8) void {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return;
    defer _ = linux.close(@intCast(fd));
    ctx_len = linux.read(@intCast(fd), &ctx_data, ctx_data.len);
    if (ctx_len > ctx_data.len) ctx_len = 0;
}
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
        if (std.mem.startsWith(u8, kv, "DXGTEST_CTXDATA=")) loadCtx(@ptrCast(kv[16..].ptr));
        if (std.mem.startsWith(u8, kv, "DXGTEST_CTXFLAGS=")) ctx_flags = std.fmt.parseInt(u32, kv[17..], 16) catch 0;
        if (std.mem.startsWith(u8, kv, "DXGTEST_NODE=")) node = std.fmt.parseInt(u32, kv[13..], 10) catch null;
        if (std.mem.startsWith(u8, kv, "DXGTEST_QFLAGS=")) queue_flags = std.fmt.parseInt(u32, kv[15..], 16) catch 1;
        if (std.mem.startsWith(u8, kv, "DXGTEST_PRELUDE=")) loadPrelude(@ptrCast(kv[16..].ptr));
        if (std.mem.startsWith(u8, kv, "DXGTEST_POSTLUDE=")) loadPostlude(@ptrCast(kv[17..].ptr));
        if (std.mem.startsWith(u8, kv, "DXGTEST_FROM=")) prelude_from = std.fmt.parseInt(usize, kv[13..], 10) catch 0;
        if (std.mem.startsWith(u8, kv, "DXGTEST_TO=")) prelude_to = std.fmt.parseInt(usize, kv[11..], 10) catch prelude_to;
    }
    if (prelude_n != 0) {
        const to = @min(prelude_to, prelude_n);
        const from = @min(prelude_from, to);
        nvidia.gl3d.prelude = prelude_buf[from..to];
        out("prelude: methods {d}..{d} of {d}\n", .{ from, to, prelude_n });
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
    // ("vprobe SUBCH METHOD VALUE ...": those methods (hex) on the channel,
    // one each, then the host's fence: whether the channel's engine takes
    // them; a video engine's own channel (DXGTEST_NODE, _CTXDATA,
    // _CTXFLAGS, _QFLAGS, _ENGINES) answers with its fence, a channel with
    // no such engine is lost)
    if (std.mem.eql(u8, mode, "vprobe")) {
        sem.* = 0;
        var nw: u32 = 0;
        var ai: usize = 2;
        while (ai + 2 < argv.len) : (ai += 3) {
            const s = std.fmt.parseInt(u32, std.mem.span(argv[ai]), 16) catch 0;
            const m = std.fmt.parseInt(u32, std.mem.span(argv[ai + 1]), 16) catch 0;
            // ("hi", "lo": the semaphore word's GPU address, its halves)
            const vs = std.mem.span(argv[ai + 2]);
            const sem_va = r.va + 0x8_0000;
            const v = if (std.mem.eql(u8, vs, "hi")) @as(u32, @truncate(sem_va >> 32)) else if (std.mem.eql(u8, vs, "lo")) @as(u32, @truncate(sem_va)) else std.fmt.parseInt(u32, vs, 16) catch 0;
            pb[0x400 + nw] = push.header(s, m, 1);
            pb[0x401 + nw] = v;
            nw += 2;
        }
        const vf = ch.submit(r.va + 0x1000, nw) catch |e| {
            out("vprobe: not sent ({s}, status {d})\n", .{ @errorName(e), dxg.kmt.last_status });
            linux.exit(3);
        };
        const tv = nowUs();
        while (ch.progress.* < vf and nowUs() - tv < 2_000_000) {}
        const done = ch.progress.* >= vf and ch.progress.* < 0x4000_0000;
        out("vprobe: {d} methods, fence {d}: progress {d} after {d} us: {s}; the semaphore word 0x{x}\n", .{ nw / 2, vf, ch.progress.*, nowUs() - tv, if (done) "TAKEN" else "NOT TAKEN", sem.* });
        if (!done) if (g.fault()) |pf| out("   the device: execution state {d}, page fault at 0x{x} (stage {d}, flags 0x{x}, code 0x{x})\n", .{ pf.execution, pf.va, pf.stage, pf.flags, pf.code });
        ch.close();
        g.close();
        linux.exit(if (done) 0 else 3);
    }
    // ("nodes": each of the adapter's nodes, KMTQAITYPE_NODEMETADATA:
    // its engine type, DXGK_ENGINE_TYPE: 1 3D, 2 video decode, 3 video
    // encode, 4 video processing, 6 copy; and its name)
    if (std.mem.eql(u8, mode, "nodes")) {
        var ni: u32 = 0;
        while (ni < 16) : (ni += 1) {
            var md: [96]u8 = @splat(0);
            var ok = false;
            for ([_]u32{ 76, 78, 80, 84, 88 }) |size| {
                @memset(&md, 0);
                std.mem.writeInt(u32, md[0..4], ni, .little);
                var q = dxg.kmt.QueryAdapterInfo{ .adapter = g.adapter, .type = 24, .data = @intFromPtr(&md), .size = size };
                if (dxg.kmt.call(g.fd, .query_adapter_info, &q)) |_| {
                    ok = true;
                    break;
                } else |e| out("node {d}, {d} bytes: {s} (status {d})\n", .{ ni, size, @errorName(e), dxg.kmt.last_status });
            }
            if (!ok) break;
            var name: [32]u8 = undefined;
            for (&name, 0..) |*c, k| c.* = md[8 + 2 * k];
            const end = std.mem.indexOfScalar(u8, &name, 0) orelse name.len;
            out("node {d}: engine type {d}, '{s}', flags 0x{x}\n", .{ ni, std.mem.readInt(u32, md[4..8], .little), name[0..end], std.mem.readInt(u32, md[72..76], .little) });
        }
        ch.close();
        g.close();
        return;
    }
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
        // ("draw edges nodepth": step 4's draws without their depth target)
        if (argv.len > 3 and std.mem.eql(u8, std.mem.span(argv[3]), "nodepth")) gpu.nvidia_draw.edges_depth = false;
        // ("draw edges blobdepth FILE": step 4's depth target an allocation
        // made with NVIDIA's private data from FILE: its D3D12 driver's
        // depth surface, recorded)
        if (argv.len > 4 and std.mem.eql(u8, std.mem.span(argv[3]), "blobdepth")) {
            var data: [dxg.nv.ALLOCATION_BYTES]u8 = undefined;
            const fd: isize = @bitCast(linux.open(argv[4], .{ .ACCMODE = .RDONLY }, 0));
            if (fd < 0) linux.exit(1);
            const got = linux.read(@intCast(fd), &data, data.len);
            if (got != data.len) linux.exit(1);
            const z = g.allocWith(&data, 0x80000, null) catch |e| {
                out("blobdepth: {s} (status {d})\n", .{ @errorName(e), dxg.kmt.last_status });
                linux.exit(1);
            };
            out("blobdepth: allocation at 0x{x}\n", .{z.va});
            gpu.nvidia_draw.edges_depth_va = z.va;
        }
        // ("draw edges zprobe FILE": step 5 a probe of the depth target's
        // layout, its bytes into FILE: nvidia_draw.z_probe)
        var zbuf: [8192]u8 = undefined;
        if (argv.len > 4 and std.mem.eql(u8, std.mem.span(argv[3]), "zprobe")) gpu.nvidia_draw.z_probe = &zbuf;
        // ("draw edges zprobes FILE": the stencil's probe)
        if (argv.len > 4 and std.mem.eql(u8, std.mem.span(argv[3]), "zprobes")) {
            gpu.nvidia_draw.z_probe = &zbuf;
            gpu.nvidia_draw.z_probe_stencil = true;
        }
        // ("draw edges vramdepth": step 4's depth target in VRAM)
        if (argv.len > 3 and std.mem.eql(u8, std.mem.span(argv[3]), "vramdepth")) {
            const z = g.allocVideo(1 << 20) catch linux.exit(1);
            gpu.nvidia_draw.edges_depth_va = z.va;
        }
        const t4 = nowUs();
        const h = gpu.nvidia_draw.hardwareTest(dev.device(), if (edges) d else null, &over3d, &kst, &model, logLine, nowUs);
        out("4. 3D engine: started {}, object {}, state {}, {d} passed, {d} failed, lost {}, {d} Mpx/s ({d} ms)\n", .{ h.started, h.object, h.state, h.passed, h.failed, h.lost, h.mpx_per_s, (nowUs() - t4) / 1000 });
        if (gpu.nvidia_draw.z_probe != null) {
            const zf: isize = @bitCast(linux.open(argv[4], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644));
            if (zf >= 0) {
                _ = linux.write(@intCast(zf), &zbuf, zbuf.len);
                _ = linux.close(@intCast(zf));
            }
        }
        if (h.lost or h.failed != 0) if (g.fault()) |pf| out("   the device: execution state {d}, page fault at 0x{x} (stage {d}, flags 0x{x}, code 0x{x})\n", .{ pf.execution, pf.va, pf.stage, pf.flags, pf.code });
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
