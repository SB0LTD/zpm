//! voicebench: LFM3-Audio's depthformer (zpm's shared GPU layer,
//! lfm3_any_audio) on the real GPU behind /dev/dxg (WSL), with its weights
//! and buffers in VRAM the CPU has no view of (Adapter.gpu_only: as the
//! forwarded RTX in Galaxy's VM). One frame's calls (projectState, three
//! code passes) are checked against the CPU's and timed, then one code pass
//! is profiled dispatch by dispatch: each dispatch's GPU time from the end
//! of the one before, by kernel, the slowest listed.
//!
//!   voicebench <mmproj-LFM3-Audio-2B-Q8_0.gguf>

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const gpu = @import("gpu");
const gguf = @import("gguf");
const gen = @import("lfm3_audio_gen");
const any = @import("lfm3_any");
const any_audio = @import("lfm3_any_audio");

fn out(comptime fmt: []const u8, args: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn nowUs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn mapMemory(bytes: usize) []align(4096) u8 {
    const m: isize = @bitCast(linux.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0));
    if (m < 0) {
        out("voicebench: no memory ({d} bytes)\n", .{bytes});
        linux.exit(2);
    }
    const p: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..bytes];
}

fn mapFile(path: [*:0]const u8) []const u8 {
    const fd: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) {
        out("voicebench: cannot open {s}\n", .{std.mem.span(path)});
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

const CAP = 1024;
var g: dxg.Gpu = .{};
var ch: dxg.Channel = .{};
var ch2: dxg.Channel = .{};
var sys: dxg.DxgDevice = undefined;
var vram: dxg.VramDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var work: any.Work = .{};
var index: gguf.Index(CAP) = .{};
var plan: gen.Plan = .{};
var depth_work: gen.DepthWorkspace(gen.lfm3_audio_limits) = .{};
var ends: [any.MAX_DISPATCHES]u64 = undefined;

const Row = struct { name: []const u8, ns: u64 = 0, n: u32 = 0 };
var rows: [64]Row = undefined;

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        out("usage: voicebench <mmproj.gguf>\n", .{});
        linux.exit(2);
    }
    const memory = Memory{ .bytes = mapFile(argv[1]) };
    const src = memory.source();
    gguf.parse(CAP, src, &index) catch |e| {
        out("gguf: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    gen.build(CAP, src, &index, &plan) catch |e| {
        out("plan: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    const dp = &plan.depth;
    out("depthformer: {d} layers, hidden {d}, ff {d}, {d} heads of {d} ({d} KV), vocabulary {d}\n", .{ dp.layer_count, dp.hidden, dp.feed_forward, dp.heads, dp.head_size, dp.kv_heads, plan.vocabulary });

    const ring = mapMemory(dxg.gpu.RING_BYTES);
    g.open(.{ .name = "zpm-voicebench" }) catch |e| {
        out("open: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    // VB_NOTIFY=1: the channel writes each submission's fence to system
    // memory as well, as gpud's channels for a guest do
    var notify: u64 = 0;
    for (init.minimal.environ.block.slice) |e| {
        const kv = std.mem.span(e orelse continue);
        if (!std.mem.startsWith(u8, kv, "VB_NOTIFY=")) continue;
        const page: []align(4096) u8 = @alignCast(mapMemory(64 << 10));
        notify = (g.mapSystem(page) catch linux.exit(1)).va;
        out("the channel notifies (fences to system memory at 0x{x})\n", .{notify});
    }
    ch.open(&g, ring, .{ .name = "zpm-voicebench", .notify = notify }) catch |e| {
        out("channel: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    sys.init(&g, &ch, mapMemory(256 << 20));
    // VB_SECOND=1: a second channel as gpud opens a guest's (a notify
    // address), one submission run on it, then left idle: does an idle
    // channel of ours take the GPU's time?
    for (init.minimal.environ.block.slice) |e| {
        const kv = std.mem.span(e orelse continue);
        if (!std.mem.startsWith(u8, kv, "VB_SECOND=")) continue;
        const status = sys.device().alloc(4096) catch linux.exit(1);
        ch2.open(&g, mapMemory(dxg.gpu.RING_BYTES), .{ .name = "zpm-voicebench-2", .notify = status.va }) catch |err| {
            out("second channel: {s}\n", .{@errorName(err)});
            linux.exit(1);
        };
        const f = ch2.submitMany(&.{}) catch linux.exit(1);
        ch2.wait(f, 1_000_000) catch linux.exit(1);
        out("a second channel open, one submission done, now idle\n", .{});
    }
    vram.init(&g, &ch);
    const d = gpu.nvidia_device.over(&adapter, sys.device(), sys.device(), gpu.nvidia_device.rtx5070(8 << 30));
    adapter.gpu_only = vram.device();

    const t0 = nowUs();
    // VB_LAYOUT=lanes,slots,unroll: the Q8_0 matrices' layout (default:
    // lfm3_kir.Layout.wide)
    var lay: @FieldType(any_audio.Options, "matrix") = null;
    for (init.minimal.environ.block.slice) |e| {
        const kv = std.mem.span(e orelse continue);
        if (!std.mem.startsWith(u8, kv, "VB_LAYOUT=")) continue;
        var it = std.mem.splitScalar(u8, kv[10..], ',');
        var n: [3]u32 = .{ 4, 1, 1 };
        for (&n) |*x| x.* = std.fmt.parseInt(u32, it.next() orelse break, 10) catch x.*;
        lay = .{ .lanes = n[0], .slots = n[1], .unroll = n[2] };
    }
    var depth = any_audio.Depth(CAP).init(d, &plan, &index, src, .{ .import = false, .matrix = lay }, &work) catch |e| {
        out("depth init: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    out("set up in {d} ms (kernels built, weights staged into VRAM)\n", .{(nowUs() - t0) / 1000});
    const used = depth.matrixLayout();
    out("matrices: lanes {d}, slots {d}, unroll {d}\n", .{ used.lanes, used.slots, used.unroll });

    var state: [4096]f32 = undefined;
    const hs = state[0..plan.backbone];
    var seed: u32 = 77;
    for (hs) |*v| {
        seed = seed *% 1664525 +% 1013904223;
        v.* = (@as(f32, @floatFromInt(seed >> 8)) / 16777216.0 - 0.5) * 4;
    }
    const masks = [3][gen.CODEBOOKS]i32{
        .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
        .{ 17, -1, -1, 1200, -1, -1, 5, -1, -1, 2015, -1, -1 },
        .{ 17, 300, -1, 1200, 44, -1, 5, 8, -1, 2015, 999, -1 },
    };
    const n_logits = gen.CODEBOOKS * plan.vocabulary;
    // VB_FRAMES=n: n frames back to back (default 3), each printed
    var frames: usize = 3;
    for (init.minimal.environ.block.slice) |e| {
        const kv = std.mem.span(e orelse continue);
        if (std.mem.startsWith(u8, kv, "VB_FRAMES=")) frames = std.fmt.parseInt(usize, kv[10..], 10) catch 3;
    }
    for (0..frames) |round| {
        var cpu_us: u64 = 0;
        var gpu_us: u64 = 0;
        var calls: [4]u64 = undefined;
        var worst: f32 = 0;
        var at = nowUs();
        gen.projectState(CAP, gen.lfm3_audio_limits, src, &index, &plan, &depth_work, hs, .{}) catch linux.exit(1);
        cpu_us += nowUs() - at;
        at = nowUs();
        depth.projectState(hs) catch |e| {
            out("gpu projectState: {s}\n", .{@errorName(e)});
            linux.exit(1);
        };
        calls[0] = nowUs() - at;
        gpu_us += calls[0];
        for (masks, 1..) |codes, k| {
            at = nowUs();
            gen.codePass(CAP, gen.lfm3_audio_limits, src, &index, &plan, &depth_work, &codes, .{}) catch linux.exit(1);
            cpu_us += nowUs() - at;
            at = nowUs();
            const got = depth.codePass(&codes) catch |e| {
                out("gpu codePass: {s}\n", .{@errorName(e)});
                linux.exit(1);
            };
            calls[k] = nowUs() - at;
            gpu_us += calls[k];
            var scale: f32 = 0;
            var diff: f32 = 0;
            for (depth_work.logits[0..n_logits], got[0..n_logits]) |a, b| {
                scale = @max(scale, @abs(a));
                diff = @max(diff, @abs(a - b));
            }
            worst = @max(worst, diff / @max(scale, 1e-6));
        }
        out("frame {d}: GPU {d} us (calls {d} {d} {d} {d}), CPU one thread {d} us, logits within {e}\n", .{ round, gpu_us, calls[0], calls[1], calls[2], calls[3], cpu_us, worst });
    }

    // one code pass profiled
    if (!d.profile(true)) {
        out("no profiling on this device\n", .{});
        linux.exit(0);
    }
    const t1 = nowUs();
    _ = depth.codePass(&masks[1]) catch linux.exit(1);
    const wall = nowUs() - t1;
    const n = d.dispatchNs(&ends);
    _ = d.profile(false);
    var nrows: usize = 0;
    var total: u64 = 0;
    var prev: u64 = 0;
    for (0..n) |i| {
        const ns = if (ends[i] > prev) ends[i] - prev else 0;
        prev = ends[i];
        total += ns;
        const name = work.descs[i].kernel;
        const r = for (rows[0..nrows]) |*x| {
            if (std.mem.eql(u8, x.name, name)) break x;
        } else blk: {
            if (nrows == rows.len) continue;
            rows[nrows] = .{ .name = name };
            nrows += 1;
            break :blk &rows[nrows - 1];
        };
        r.ns += ns;
        r.n += 1;
    }
    out("profiled code pass: {d} dispatches, {d} us of GPU time, {d} us wall (run {d} ns)\n", .{ n, total / 1000, wall, d.lastRunNs() });
    for (rows[0..nrows]) |r| out("  {s}: {d} dispatches, {d} us\n", .{ r.name, r.n, r.ns / 1000 });
    // the matrices one by one: rows x blocks, tokens, time, the weights'
    // bytes over it (MB/s)
    prev = 0;
    for (0..n) |i| {
        const ns = if (ends[i] > prev) ends[i] - prev else 0;
        prev = ends[i];
        const ds = work.descs[i];
        if (!std.mem.eql(u8, ds.kernel, "matrix q8_0")) continue;
        const words = work.dispatches[i].params;
        const row_bytes: u64 = words[0];
        const nrow: u64 = words[2];
        out("  matrix {d}: {d} rows x {d} blocks, tokens {d}+{d}, {d} us, {d} MB/s\n", .{ ds.tensor orelse 0, nrow, words[1], ds.first, ds.count, ns / 1000, if (ns > 0) row_bytes * nrow * 1000 / ns else 0 });
    }
    depth.deinit();
    ch.close();
    g.close();
    linux.exit(0);
}
