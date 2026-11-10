//! @zpm/gfxapi report — what the driver says of itself on the app's stderr
//! (on Galaxy, an app's stderr is the kernel log): the device it draws
//! with, and what would otherwise go unseen. That covers an entry point an
//! app asked for that the driver does not have, a program that does not
//! link, a pipeline the GPU does not take (its draws then run on the CPU),
//! the GPU lost, the first GL errors, and what a check of the GPU against
//! the CPU found (GALAXY_GL_CHECK). Each kind is said a few times at
//! most, so a busy app cannot flood the log.
//!
//! And what a GL context is used for (`Usage`): one line every 5 seconds
//! while it is in use, with its swaps, draws, texture uploads, whose
//! shaders its programs are, and the GPU's batches and the time spent
//! waiting for them. That line tells an app that draws its pages on the
//! GPU (Firefox's WebRender) from one that draws them in software and has
//! GL only put the result on the window, and shows where the time goes.
//!
//! On in the Linux library (libgalaxy-gl.so); off in tests and on other
//! hosts, unless `sink` is set.
//!
//! Allocation-free: a line is formatted on the stack, a context's counters
//! are fixed fields.

const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum(u4) { device, missing, link, pipeline, lost, gl_error, check, egl_error, marker, slow, usage };

/// How many lines of each kind a process says (0: no such limit; a usage
/// line is limited by time instead, one per context every USAGE_US).
const LIMITS = [_]u8{ 4, 64, 16, 16, 4, 16, 32, 32, 16, 8, 0 };

pub var sink: ?*const fn ([]const u8) void = if (builtin.os.tag == .linux and !builtin.is_test) &stderrLine else null;

var counts = [_]u8{0} ** LIMITS.len;

fn stderrLine(line: []const u8) void {
    _ = std.os.linux.write(2, line.ptr, line.len);
}

/// One line, "galaxy-gl: ..." (with the process's id where it has one), if
/// this kind has lines left.
pub fn say(kind: Kind, comptime fmt: []const u8, args: anytype) void {
    sayIn(640, kind, fmt, args);
}

/// `say` with a line of up to `cap` bytes.
fn sayIn(comptime cap: usize, kind: Kind, comptime fmt: []const u8, args: anytype) void {
    const s = sink orelse return;
    const i = @intFromEnum(kind);
    var last = false;
    if (LIMITS[i] != 0) {
        // (counted without a lock: two threads at the limit may say one more)
        if (counts[i] >= LIMITS[i]) return;
        counts[i] += 1;
        last = counts[i] == LIMITS[i];
    }
    var buf: [cap]u8 = undefined;
    const pid: i64 = if (builtin.os.tag == .linux) @intCast(std.os.linux.getpid()) else 0;
    const line = std.fmt.bufPrint(&buf, "galaxy-gl[{d}]: " ++ fmt ++ "{s}\n", .{pid} ++ args ++ .{if (last) " (the last of these said)" else ""}) catch return;
    s(line);
}

// ── Time ───────────────────────────────────────────────────────────────────

/// Microseconds on a clock that only goes up (Linux's CLOCK_MONOTONIC):
/// what usage lines are spaced by, and what the engine times its waits
/// for the GPU with. Off Linux there is none (0), unless a test sets one.
pub var clock: *const fn () u64 = &monotonicUs;

pub fn nowUs() u64 {
    return clock();
}

fn monotonicUs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

// ── Usage ──────────────────────────────────────────────────────────────────

/// How far apart a context's usage lines are, at least.
pub const USAGE_US: u64 = 5_000_000;

/// Uniform names that say whose shaders a program's are. WebRender's own
/// (Firefox draws the page on the GPU: its brush_*, ps_*, cs_* and
/// composite programs read these samplers), or the layers compositor's
/// (Firefox's CompositorOGL: WebRender drew in software, and GL only
/// puts its tiles on the window).
const NAMES = [_]struct { name: []const u8, webrender: bool }{
    .{ .name = "sColor0", .webrender = true },
    .{ .name = "sGpuCache", .webrender = true },
    .{ .name = "sRenderTasks", .webrender = true },
    .{ .name = "sTransformPalette", .webrender = true },
    .{ .name = "sPrimitiveHeadersF", .webrender = true },
    .{ .name = "uLayerTransform", .webrender = false },
    .{ .name = "uMatrixProj", .webrender = false },
    .{ .name = "uRenderTargetOffset", .webrender = false },
};

/// The names of NAMES a program has: bit i, NAMES[i].
pub const Whose = struct {
    bits: u16 = 0,

    /// One of the program's uniform names.
    pub fn see(w: *Whose, name: []const u8) void {
        for (NAMES, 0..) |n, i| {
            if (std.mem.eql(u8, name, n.name)) w.bits |= @as(u16, 1) << @intCast(i);
        }
    }

    fn any(w: Whose, webrender: bool) bool {
        for (NAMES, 0..) |n, i| {
            if (n.webrender == webrender and w.bits & (@as(u16, 1) << @intCast(i)) != 0) return true;
        }
        return false;
    }
};

/// The engine's counters a usage line reports. They are the process's:
/// every context's work goes through the one engine.
pub const Gpu = struct {
    /// batches run on the GPU, and the kernel runs in them
    batches: u64 = 0,
    kernels: u64 = 0,
    /// microseconds spent handing batches to the GPU
    submit_us: u64 = 0,
    /// times the CPU waited for the GPU, and for how long
    waits: u64 = 0,
    wait_us: u64 = 0,
    /// draws done on the CPU (the GPU lost, or it did not take a program)
    cpu_draws: u64 = 0,
};

/// What a GL context is used for: counters (the context's own thread
/// writes them, no lock) and the line that reports them. The counts are
/// of the time since the last line, but for the programs, which are of
/// the context's life.
pub const Usage = struct {
    /// the context's number in its process (EGL counts them from 1; 0: a
    /// context EGL did not make)
    id: u32 = 0,
    /// the OpenGL ES version eglCreateContext was asked for (0: not
    /// known), and whether a reset is to lose the context (robustness).
    /// Firefox asks for ES 3 with robustness for WebRender on the GPU,
    /// and for ES 2 without for its layers compositor
    es: u8 = 0,
    robust: bool = false,
    /// when the time counted began (0: at the next tick)
    since_us: u64 = 0,
    swaps: u32 = 0,
    /// microseconds inside eglSwapBuffers (the compositor's pace: a frame
    /// callback or a free buffer waited for)
    swap_us: u64 = 0,
    draws: u32 = 0,
    /// draws with an element array (glDrawElements and its kin)
    indexed: u32 = 0,
    instances: u64 = 0,
    triangles: u64 = 0,
    uploads: u32 = 0,
    upload_bytes: u64 = 0,
    /// the longest the CPU waited for the GPU between two swaps
    swap_wait_us: u64 = 0,
    programs: u32 = 0,
    webrender_programs: u32 = 0,
    layers_programs: u32 = 0,
    names: Whose = .{},
    /// the engine's counters when the time counted began, and its waits
    /// at the last swap (once there was one)
    gpu: Gpu = .{},
    wait_at_swap_us: u64 = 0,
    swapped_once: bool = false,

    /// A draw the engine was given.
    pub fn draw(u: *Usage, indexed: bool, instances: u32, triangles: u64) void {
        u.draws +%= 1;
        if (indexed) u.indexed +%= 1;
        u.instances +%= instances;
        u.triangles +%= triangles;
    }

    /// Texels written into a texture (glTexImage2D, glTexSubImage2D and
    /// their 3D kin): the bytes as stored.
    pub fn upload(u: *Usage, bytes: usize) void {
        u.uploads +%= 1;
        u.upload_bytes +%= bytes;
    }

    /// A program linked, with these names among its uniforms.
    pub fn linked(u: *Usage, whose: Whose) void {
        u.programs +%= 1;
        if (whose.any(true)) u.webrender_programs +%= 1;
        if (whose.any(false)) u.layers_programs +%= 1;
        u.names.bits |= whose.bits;
    }

    /// An eglSwapBuffers that took `took_us`; `wait_us`: the engine's
    /// time waiting for the GPU so far.
    pub fn swapped(u: *Usage, took_us: u64, wait_us: u64) void {
        u.swaps +%= 1;
        u.swap_us +%= took_us;
        if (u.swapped_once) u.swap_wait_us = @max(u.swap_wait_us, wait_us -| u.wait_at_swap_us);
        u.wait_at_swap_us = wait_us;
        u.swapped_once = true;
    }

    /// Whether `tell` has something to do at `now_us`: the time counted
    /// to begin (the first call), or a line to say (USAGE_US later).
    /// Cheap: a context asks at each swap, flush and finish.
    pub fn due(u: *const Usage, now_us: u64) bool {
        if (sink == null) return false;
        return u.since_us == 0 or now_us -| u.since_us >= USAGE_US;
    }

    /// The line, and the counters begin again. `on`: the GPU's name, or
    /// none when the CPU draws; `gpu`: the engine's counters now. Nothing
    /// is said of a stretch in which the context neither swapped, drew
    /// nor uploaded.
    pub fn tell(u: *Usage, now_us: u64, on: ?[]const u8, gpu: Gpu) void {
        if (u.since_us == 0) {
            // (the first call: the time counts from here, and what was
            // counted before it is the first line's too)
            u.since_us = @max(now_us, 1);
            u.gpu = gpu;
            return;
        }
        if (u.swaps != 0 or u.draws != 0 or u.uploads != 0) {
            const span = now_us -| u.since_us;
            const then = u.gpu;
            var names: [160]u8 = undefined;
            var n: usize = 0;
            for (NAMES, 0..) |nm, i| {
                if (u.names.bits & (@as(u16, 1) << @intCast(i)) == 0) continue;
                const part = std.fmt.bufPrint(names[n..], "{s}{s}", .{ if (n == 0) ", names seen: " else " ", nm.name }) catch break;
                n += part.len;
            }
            var es: [32]u8 = undefined;
            const asked = if (u.es == 0) "" else std.fmt.bufPrint(&es, " (ES {d} asked{s})", .{ u.es, if (u.robust) ", robust" else "" }) catch "";
            sayIn(1024, .usage, "context {d}{s} in {d}.{d} s on {s}{s}{s}: " ++
                "{d} swaps ({d} ms in them); " ++
                "{d} draws ({d} indexed, {d} instances, {d} triangles, {d} on the CPU); " ++
                "{d} uploads, {d} kB; " ++
                "programs: {d} linked, {d} WebRender's, {d} the layers compositor's{s}; " ++
                "GPU: {d} batches of {d} kernel runs, {d} ms submitting, {d} ms waiting in {d} waits ({d} ms at most between two swaps)", .{
                u.id,
                asked,
                span / 1_000_000,
                span / 100_000 % 10,
                if (on != null) "the GPU (" else "the CPU",
                on orelse "",
                if (on != null) ")" else "",
                u.swaps,
                u.swap_us / 1000,
                u.draws,
                u.indexed,
                u.instances,
                u.triangles,
                gpu.cpu_draws -| then.cpu_draws,
                u.uploads,
                (u.upload_bytes +| 512) / 1024,
                u.programs,
                u.webrender_programs,
                u.layers_programs,
                names[0..n],
                gpu.batches -| then.batches,
                gpu.kernels -| then.kernels,
                (gpu.submit_us -| then.submit_us) / 1000,
                (gpu.wait_us -| then.wait_us) / 1000,
                gpu.waits -| then.waits,
                u.swap_wait_us / 1000,
            });
        }
        u.since_us = @max(now_us, 1);
        u.swaps = 0;
        u.swap_us = 0;
        u.draws = 0;
        u.indexed = 0;
        u.instances = 0;
        u.triangles = 0;
        u.uploads = 0;
        u.upload_bytes = 0;
        u.swap_wait_us = 0;
        u.gpu = gpu;
    }
};

/// A log's first line (what to say of a failed link).
pub fn firstLine(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(end, 300)];
}

var test_buf: [1024]u8 = undefined;
var test_len: usize = 0;

fn testSink(line: []const u8) void {
    @memcpy(test_buf[test_len..][0..line.len], line);
    test_len += line.len;
}

test "report: a kind says its lines, then no more" {
    const old = sink;
    defer sink = old;
    sink = &testSink;
    counts = [_]u8{0} ** LIMITS.len;
    test_len = 0;
    for (0..6) |n| say(.lost, "the GPU is lost ({d})", .{n});
    const out = test_buf[0..test_len];
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "the GPU is lost"));
    try std.testing.expect(std.mem.indexOf(u8, out, "(3) (the last of these said)") != null);
    try std.testing.expectEqualStrings("0:3: error: x", firstLine("\n0:3: error: x\n0:4: more\n"));
}

var test_lines: usize = 0;

fn countSink(line: []const u8) void {
    _ = line;
    test_lines += 1;
}

test "report: a context's usage is counted, and said once in five seconds" {
    const old = sink;
    defer sink = old;
    sink = &testSink;
    test_len = 0;
    const sec: u64 = 1_000_000;
    var u: Usage = .{ .id = 3, .es = 3, .robust = true };
    var gpu: Gpu = .{ .batches = 10, .kernels = 40, .waits = 2, .wait_us = 9_000 };
    // the first call begins the time counted and says nothing
    try std.testing.expect(u.due(100 * sec));
    u.tell(100 * sec, "Some GPU", gpu);
    try std.testing.expectEqual(@as(usize, 0), test_len);
    // what the context does: two programs (one with WebRender's names),
    // seven instanced draws and a plain one, two uploads, two swaps
    var mine: Whose = .{};
    for ([_][]const u8{ "uTransform", "sGpuCache", "sRenderTasks" }) |name| mine.see(name);
    u.linked(mine);
    var other: Whose = .{};
    other.see("uColor");
    u.linked(other);
    for (0..7) |_| u.draw(true, 4, 8);
    u.draw(false, 1, 2);
    u.upload(64 * 1024);
    u.upload(1024);
    gpu.wait_us += 3_000;
    u.swapped(2_000, gpu.wait_us);
    gpu.wait_us += 12_000;
    gpu.waits += 3;
    u.swapped(4_000, gpu.wait_us);
    gpu.batches += 5;
    gpu.kernels += 24;
    gpu.submit_us += 7_000;
    gpu.cpu_draws += 1;
    // not due before five seconds are over, however often it is asked
    for (0..1000) |i| try std.testing.expect(!u.due(100 * sec + i * 4999));
    try std.testing.expectEqual(@as(usize, 0), test_len);
    try std.testing.expect(u.due(105 * sec + 300_000));
    u.tell(105 * sec + 300_000, "Some GPU", gpu);
    // (after "galaxy-gl[pid]: ")
    const line = test_buf[0..test_len];
    const at = (std.mem.indexOf(u8, line, "]: ") orelse return error.NoLine) + 3;
    try std.testing.expectEqualStrings("context 3 (ES 3 asked, robust) in 5.3 s on the GPU (Some GPU): " ++
        "2 swaps (6 ms in them); 8 draws (7 indexed, 29 instances, 58 triangles, 1 on the CPU); 2 uploads, 65 kB; " ++
        "programs: 2 linked, 1 WebRender's, 0 the layers compositor's, names seen: sGpuCache sRenderTasks; " ++
        "GPU: 5 batches of 24 kernel runs, 7 ms submitting, 15 ms waiting in 3 waits (12 ms at most between two swaps)\n", line[at..]);
    // the counters began again, and the next line is five seconds off
    try std.testing.expect(!u.due(105 * sec + 300_001));
    try std.testing.expect(!u.due(110 * sec));
    // a stretch with nothing done says nothing
    test_len = 0;
    try std.testing.expect(u.due(111 * sec));
    u.tell(111 * sec, "Some GPU", gpu);
    try std.testing.expectEqual(@as(usize, 0), test_len);
    // the layers compositor's program, a draw on the CPU: the GPU is gone
    var layers: Whose = .{};
    layers.see("uLayerTransform");
    u.linked(layers);
    u.draw(false, 1, 2);
    gpu.cpu_draws += 1;
    u.tell(117 * sec, null, gpu);
    const out = test_buf[0..test_len];
    try std.testing.expect(std.mem.indexOf(u8, out, " in 6.0 s on the CPU: 0 swaps (0 ms in them); 1 draws (0 indexed, 1 instances, 2 triangles, 1 on the CPU); 0 uploads, 0 kB; programs: 3 linked, 1 WebRender's, 1 the layers compositor's, names seen: sGpuCache sRenderTasks uLayerTransform; GPU: 0 batches") != null);
    // no count limits these lines (only the time does), and none are said
    // with the report off
    sink = &countSink;
    test_lines = 0;
    for (0..300) |i| {
        u.draw(true, 1, 2);
        const now = (200 + 5 * @as(u64, i)) * sec;
        if (u.due(now)) u.tell(now, null, gpu);
    }
    try std.testing.expectEqual(@as(usize, 300), test_lines);
    sink = null;
    try std.testing.expect(!u.due(9000 * sec));
}
