//! brainbench: LFM3's brain (zpm's shared GPU layer, lfm3_any) on the real
//! GPU behind /dev/dxg (WSL), its weights and buffers in VRAM the CPU has no
//! view of (Adapter.gpu_only: as the forwarded RTX in Galaxy's VM).
//!
//! 1. The check: a 16-token prompt and 8 greedy steps on the GPU against
//!    the CPU executor (one thread): the tokens, and the logits' worst
//!    difference over their largest magnitude.
//! 2. Prompt reading: prompts of 64, 256 and 1024 tokens (sent as
//!    galaxy-think sends them, Options.max_batch at a time), tokens a second.
//! 3. Decode: 64 greedy steps after a prompt, ms a token (wall and GPU).
//! 4. Profiles: one decode step and one max_batch prompt chunk, each
//!    dispatch's GPU time by kernel and by the tensor a matrix reads (GB/s).
//!
//!   brainbench <model.gguf>
//!
//! BB_CHECK=0 skips the check (the CPU's minute); BB_PROMPTS=64,256 the
//! prompt lengths; BB_STEPS=n the decode steps.

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const gpu = @import("gpu");
const gguf = @import("gguf");
const lfm3 = @import("lfm3_plan");
const executor = @import("lfm3_executor");
const any = @import("lfm3_any");

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn mapMemory(bytes: usize) []align(4096) u8 {
    const m: isize = @bitCast(linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
    if (m < 0) {
        out("brainbench: no memory ({d} bytes)\n", .{bytes});
        linux.exit(2);
    }
    const p: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..bytes];
}

fn mapFile(path: [*:0]const u8) []const u8 {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) {
        out("brainbench: cannot open {s}\n", .{std.mem.span(path)});
        linux.exit(2);
    }
    const end: isize = @bitCast(linux.lseek(@intCast(fd), 0, linux.SEEK.END));
    if (end <= 0) linux.exit(2);
    const size: usize = @intCast(end);
    const m: isize = @bitCast(linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE, .POPULATE = true }, @intCast(fd), 0));
    if (m < 0) linux.exit(2);
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..size];
}

const Memory = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, len: usize, alignment: usize) ?[*]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or len > self.bytes.len - offset or alignment == 0) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Memory) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};

const CAP = 512;
const LIMITS = blk: {
    var l = executor.lfm3_audio_2b_limits;
    l.batch = 16;
    l.context = 64;
    break :blk l;
};
const CONTEXT = 4096;
const Backend = any.Backend(CAP);

var g: dxg.Gpu = .{};
var ch: dxg.Channel = .{};
var sys: dxg.DxgDevice = undefined;
var vram: dxg.VramDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var work: any.Work = .{};
var index: gguf.Index(CAP) = .{};
var plan: lfm3.Plan = .{};
var cpu_work: executor.Workspace(LIMITS) = .{};
var cpu_kv: [16 * 2 * 8 * LIMITS.context * 128]u16 = @splat(0);
var cpu_conv: [24 * 8 * LIMITS.hidden]f32 = @splat(0);
const unpacked: executor.PackedWeights(CAP) = .{};
var tokens: [CONTEXT]u32 = undefined;

// BB_ALONE: each dispatch of a decode step run alone (lfm3_any's diagnose
// mode); its time is the device's for that run, taken as the next one is
// named
var alone_dev: ?gpu.Device = null;
var alone_kind: [64]u8 = undefined;
var alone_kind_len: usize = 0;
const AloneRow = struct { name: [64]u8 = undefined, len: usize = 0, ns: u64 = 0, n: u32 = 0 };
var alone_rows: [48]AloneRow = undefined;
var alone_n: usize = 0;

fn aloneAdd() void {
    if (alone_kind_len == 0) return;
    const ns = alone_dev.?.lastRunNs();
    const name = alone_kind[0..alone_kind_len];
    for (alone_rows[0..alone_n]) |*r| {
        if (std.mem.eql(u8, r.name[0..r.len], name)) {
            r.ns += ns;
            r.n += 1;
            return;
        }
    }
    if (alone_n == alone_rows.len) return;
    alone_rows[alone_n] = .{ .len = name.len, .ns = ns, .n = 1 };
    @memcpy(alone_rows[alone_n].name[0..name.len], name);
    alone_n += 1;
}

fn aloneLog(what: []const u8) void {
    // "lfm3-any: dispatch 12, layer 2 of 24 (attention): matrix q4k, blk.2.attn_q.weight, tokens ..."
    if (!std.mem.startsWith(u8, what, "lfm3-any: dispatch ")) {
        aloneAdd();
        alone_kind_len = 0;
        return;
    }
    aloneAdd();
    const a = (std.mem.indexOf(u8, what, "): ") orelse return) + 3;
    var rest = what[a..];
    var e = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    if (std.mem.startsWith(u8, rest, "matrix")) {
        // with the tensor's role
        if (std.mem.indexOf(u8, rest[e..], "blk.")) |bi| {
            const t = rest[e + bi + 4 ..];
            const dot = std.mem.indexOfScalar(u8, t, '.') orelse 0;
            const tend = std.mem.indexOfScalar(u8, t, ',') orelse t.len;
            var buf: [64]u8 = undefined;
            const n = (std.fmt.bufPrint(&buf, "{s} {s}", .{ rest[0..e], t[dot + 1 .. tend] }) catch rest[0..e]).len;
            @memcpy(alone_kind[0..n], buf[0..n]);
            alone_kind_len = n;
            return;
        }
    }
    e = @min(e, alone_kind.len);
    rest = rest[0..e];
    @memcpy(alone_kind[0..rest.len], rest);
    alone_kind_len = rest.len;
}

fn env(environ: anytype, name: []const u8) ?[]const u8 {
    for (environ) |e| {
        const kv = std.mem.span(e orelse continue);
        if (kv.len > name.len and std.mem.startsWith(u8, kv, name) and kv[name.len] == '=') return kv[name.len + 1 ..];
    }
    return null;
}

fn token(i: usize) u32 {
    // (ordinary text tokens, spread over the vocabulary's common part)
    return @intCast(1000 + (i * 7919) % 30000);
}

/// A prompt of n tokens from position 0 on a fresh cache, max_batch at a
/// time: its wall time (ns) and the device's.
fn prompt(b: *Backend, c: *any.Cache, n: usize) struct { wall: u64, gpu: u64 } {
    const step: usize = b.options.max_batch;
    var at: usize = 0;
    var gpu_ns: u64 = 0;
    const t0 = nowNs();
    while (at < n) {
        const m = @min(step, n - at);
        _ = b.forward(c, .{ .tokens = tokens[at..][0..m] }, if (at + m == n) .logits else .none) catch |e| {
            out("prompt forward at {d}: {s}\n", .{ at, @errorName(e) });
            linux.exit(1);
        };
        gpu_ns += b.last_ns;
        at += m;
    }
    return .{ .wall = nowNs() - t0, .gpu = gpu_ns };
}

fn printProfile(what: []const u8, p: *const any.Profile) void {
    out("{s}: {d} dispatches in {d} runs, GPU {d} us (tail {d} us); CPU: list {d} us, runs {d} us, results {d} us\n", .{ what, p.dispatches, p.runs, p.gpu_ns / 1000, p.tail_ns / 1000, p.begin_ns / 1000, p.runs_ns / 1000, p.complete_ns / 1000 });
    // the slowest first
    var order: [any.MAX_PROFILE]usize = undefined;
    for (0..p.n) |i| order[i] = i;
    const S = struct {
        fn lt(pp: *const any.Profile, a: usize, x: usize) bool {
            return pp.entries[a].ns > pp.entries[x].ns;
        }
    };
    std.mem.sort(usize, order[0..p.n], p, S.lt);
    for (order[0..p.n]) |i| {
        const e = &p.entries[i];
        const pct = if (p.gpu_ns > 0) e.ns * 1000 / p.gpu_ns else 0;
        if (e.bytes > 0 and e.ns > 0) {
            out("  {s}: {d} x, {d} us ({d}.{d}%), {d} GB/s\n", .{ e.nameSlice(), e.count, e.ns / 1000, pct / 10, pct % 10, e.bytes / e.ns });
        } else {
            out("  {s}: {d} x, {d} us ({d}.{d}%)\n", .{ e.nameSlice(), e.count, e.ns / 1000, pct / 10, pct % 10 });
        }
    }
}

// BB_CLOCK: the shader clock, from a chain of dependent float adds (each
// waits for the one before: NAK's 4 cycles and sm_120's pad, 5 a step) in
// one warp, timed by the device
var probe_insts: [4096]gpu.kir.Inst = undefined;
var probe_tys: [4096]gpu.kir.Ty = undefined;
var probe_code: [256 << 10]u8 align(16) = undefined;
var probe_mem: [24 << 20]u8 align(16) = undefined;

fn clockProbe(d: gpu.Device) void {
    clockProbeWith(d, 256, 4000);
    // straight-line code run once, then twice (the second time from the
    // instruction caches): is a cold kernel's time its code's fetch?
    clockProbeWith(d, 3072, 0);
}

fn clockProbeWith(d: gpu.Device, comptime CHAIN: u32, comptime ITERS: u32) void {
    const K = any.kernels;
    var k = K.begin(.{ .insts = &probe_insts, .tys = &probe_tys }, "clock_probe", 32);
    var bld = K.Builder.init(&k, d.caps);
    const OUT = k.binding();
    k.param_words = 1;
    const x = bld.mov(.f32, K.F(1.0));
    const n = bld.mov(.u32, K.U(0));
    bld.loop();
    for (0..CHAIN) |_| bld.set(x, .fadd, .f32, K.R(x), K.F(1.0), K.NO);
    bld.set(n, .iadd, .u32, K.R(n), K.U(1), K.NO);
    bld.brk(bld.icmp(.u32, .ge, K.R(n), K.R(bld.param(0))));
    bld.endloop();
    bld.st(OUT, K.R(bld.shl(K.R(bld.tid(0)), 2)), 0, 5, x);
    k.finish() catch |e| {
        out("probe: {s}\n", .{@errorName(e)});
        return;
    };
    var cw = gpu.Work.init(&probe_mem);
    const bin = gpu.compile(&k, d.caps, &cw, &probe_code) catch |e| {
        out("probe compile: {s}\n", .{@errorName(e)});
        return;
    };
    const prog = d.load(&bin) catch |e| {
        out("probe load: {s}\n", .{@errorName(e)});
        return;
    };
    const buf = d.alloc(4096, .host) catch return;
    const runs = if (ITERS == 0) [_]u32{ 1, 2, 4 } else [_]u32{ ITERS / 4, ITERS, ITERS * 4 };
    for (runs) |iters| {
        const words = [_]u32{iters};
        const bufs = [_]gpu.Buffer{buf};
        const disp = [_]gpu.Dispatch{.{ .prog = &prog, .groups = .{ 1, 1, 1 }, .buffers = &bufs, .params = &words }};
        var best: u64 = std.math.maxInt(u64);
        for (0..5) |_| {
            const f = d.run(&disp) catch |e| {
                out("probe run: {s}\n", .{@errorName(e)});
                return;
            };
            d.wait(f, 5_000_000) catch |e| {
                out("probe wait: {s}\n", .{@errorName(e)});
                return;
            };
            best = @min(best, d.lastRunNs());
        }
        const adds: u64 = @as(u64, iters) * CHAIN;
        // cycles: 5 an add (and the loop's few, ignored)
        out("clock probe: {d} dependent adds in {d} us: {d} MHz at 5 cycles an add\n", .{ adds, best / 1000, adds * 5 * 1000 / @max(best, 1) });
    }
}

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    const environ = init.minimal.environ.block.slice;
    if (argv.len < 2) {
        out("usage: brainbench <model.gguf>\n", .{});
        linux.exit(2);
    }
    const memory = Memory{ .bytes = mapFile(argv[1]) };
    const src = memory.source();
    gguf.parse(CAP, src, &index) catch |e| {
        out("gguf: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    lfm3.build(CAP, src, &index, &plan) catch |e| {
        out("plan: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    out("model: {d} layers ({d} attention), hidden {d}, ff {d}, vocabulary {d}, {d} MB\n", .{ plan.layer_count, plan.attention_layer_count, plan.hidden_size, plan.feed_forward_size, plan.vocabulary_size, src.size >> 20 });
    for (&tokens, 0..) |*t, i| t.* = token(i);

    const ring = mapMemory(dxg.gpu.RING_BYTES);
    g.open(.{ .name = "zpm-brainbench" }) catch |e| {
        out("open: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    ch.open(&g, ring, .{ .name = "zpm-brainbench" }) catch |e| {
        out("channel: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    sys.init(&g, &ch, mapMemory(512 << 20));
    vram.init(&g, &ch);
    const d = gpu.nvidia_device.over(&adapter, sys.device(), sys.device(), gpu.nvidia_device.rtx5070(8 << 30));
    adapter.gpu_only = vram.device();

    if (env(environ, "BB_CLOCK") != null) {
        clockProbe(d);
        if (std.mem.eql(u8, env(environ, "BB_CLOCK").?, "only")) linux.exit(0);
    }
    const t0 = nowNs();
    var b = Backend.init(d, &plan, &index, src, .{ .import = false, .clock = nowNs }, &work) catch |e| {
        out("backend init: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    out("set up in {d} ms (kernels built, weights staged into VRAM, matrices tuned)\n", .{(nowNs() - t0) / 1_000_000});

    // 1. the check against the CPU
    if (!std.mem.eql(u8, env(environ, "BB_CHECK") orelse "1", "0")) {
        var gc = b.newCache(CONTEXT) catch |e| {
            out("cache: {s}\n", .{@errorName(e)});
            linux.exit(1);
        };
        var cc = executor.Cache{
            .kv = cpu_kv[0 .. executor.requiredKvElements(&plan, LIMITS.context) catch linux.exit(1)],
            .conv = cpu_conv[0 .. executor.requiredConvElements(&plan) catch linux.exit(1)],
            .context = LIMITS.context,
        };
        cc.reset();
        const p = tokens[0..16];
        var worst: f32 = 0;
        var same: u32 = 0;
        var ct = (executor.forwardInput(CAP, LIMITS, src, &index, &plan, &unpacked, &cpu_work, &cc, .{ .tokens = p }, .logits, .{}) catch |e| {
            out("cpu: {s}\n", .{@errorName(e)});
            linux.exit(1);
        }).?;
        var gt = (b.forward(&gc, .{ .tokens = p }, .logits) catch |e| {
            out("gpu: {s}\n", .{@errorName(e)});
            linux.exit(1);
        }).?;
        for (0..9) |step| {
            var scale: f32 = 0;
            var diff: f32 = 0;
            for (cpu_work.logits[0..plan.vocabulary_size], b.logits()) |x, y| {
                scale = @max(scale, @abs(x));
                diff = @max(diff, @abs(x - y));
            }
            worst = @max(worst, diff / @max(scale, 1e-6));
            if (ct == gt) same += 1;
            if (step == 8) break;
            // (both go on from the CPU's token, so one tie does not part them)
            const next = ct;
            ct = (executor.forwardInput(CAP, LIMITS, src, &index, &plan, &unpacked, &cpu_work, &cc, .{ .tokens = &.{next} }, .logits, .{}) catch linux.exit(1)).?;
            gt = (b.forward(&gc, .{ .tokens = &.{next} }, .logits) catch linux.exit(1)).?;
        }
        out("check: {d} of 9 greedy tokens the CPU's, logits within {e} of their largest\n", .{ same, worst });
        b.freeCache(&gc);
    }

    // 2. prompt reading
    var lens: [8]usize = undefined;
    var nl: usize = 0;
    var it = std.mem.splitScalar(u8, env(environ, "BB_PROMPTS") orelse "64,256,1024", ',');
    while (it.next()) |s| {
        if (nl == lens.len) break;
        lens[nl] = @min(std.fmt.parseInt(usize, s, 10) catch continue, CONTEXT - 128);
        nl += 1;
    }
    for (lens[0..nl]) |n| {
        var best: u64 = std.math.maxInt(u64);
        var best_gpu: u64 = 0;
        for (0..3) |_| {
            var c = b.newCache(CONTEXT) catch linux.exit(1);
            const r = prompt(&b, &c, n);
            b.freeCache(&c);
            if (r.wall < best) {
                best = r.wall;
                best_gpu = r.gpu;
            }
        }
        out("prompt {d} tokens: {d} ms ({d} tokens/s), GPU {d} ms\n", .{ n, best / 1_000_000, n * 1_000_000_000 / @max(best, 1), best_gpu / 1_000_000 });
    }

    // 3. decode
    const steps = std.fmt.parseInt(usize, env(environ, "BB_STEPS") orelse "64", 10) catch 64;
    {
        var c = b.newCache(CONTEXT) catch linux.exit(1);
        out("cache: KV {d} MB, {s}\n", .{ c.kv.bytes >> 20, if (c.kv.cpu.len == 0) "in VRAM (no CPU view)" else "with a CPU view (system memory here)" });
        // BB_AT=n: the steps after a prompt of n tokens (default 64)
        const at = @min(std.fmt.parseInt(usize, env(environ, "BB_AT") orelse "64", 10) catch 64, CONTEXT - steps - 8);
        _ = prompt(&b, &c, at);
        var t: u32 = tokens[at];
        var gpu_ns: u64 = 0;
        const ts = nowNs();
        for (0..steps) |_| {
            t = (b.forward(&c, .{ .tokens = &.{t} }, .logits) catch |e| {
                out("decode: {s}\n", .{@errorName(e)});
                linux.exit(1);
            }).?;
            gpu_ns += b.last_ns;
        }
        const wall = nowNs() - ts;
        out("decode: {d} steps, {d} us a token ({d} tokens/s), GPU {d} us a token\n", .{ steps, wall / 1000 / steps, steps * 1_000_000_000 / @max(wall, 1), gpu_ns / 1000 / steps });

        // 4. profiles
        if (b.profileStep(&c, t)) |p| printProfile("decode step", p) else out("no profiling on this device\n", .{});
        if (env(environ, "BB_ALONE") != null) {
            alone_dev = b.dev;
            b.options.diagnose = aloneLog;
            _ = b.forward(&c, .{ .tokens = &.{t} }, .logits) catch linux.exit(1);
            b.options.diagnose = null;
            var total: u64 = 0;
            for (alone_rows[0..alone_n]) |r| total += r.ns;
            out("decode step, each dispatch alone: {d} us in all\n", .{total / 1000});
            for (alone_rows[0..alone_n]) |r| out("  {s}: {d} x, {d} us ({d} us each)\n", .{ r.name[0..r.len], r.n, r.ns / 1000, r.ns / 1000 / r.n });
        }
        b.freeCache(&c);
    }
    {
        var c = b.newCache(CONTEXT) catch linux.exit(1);
        _ = prompt(&b, &c, 64);
        if (b.dev.profile(true)) {
            b.prof = .{};
            b.profiling = true;
            _ = b.forward(&c, .{ .tokens = tokens[64..][0..b.options.max_batch] }, .logits) catch linux.exit(1);
            b.profiling = false;
            _ = b.dev.profile(false);
            var title: [64]u8 = undefined;
            printProfile(std.fmt.bufPrint(&title, "prompt chunk of {d} at 64", .{b.options.max_batch}) catch "prompt chunk", &b.prof);
        }
        b.freeCache(&c);
    }
    b.deinit();
    ch.close();
    g.close();
    linux.exit(0);
}
