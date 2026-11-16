//! @zpm/va convert — a surface's picture between its block-linear planes
//! (the decoder's, in VRAM) and a pitch-linear copy in system memory: what
//! a CPU reader gets (vaGetImage, a derived image mapped, FFmpeg's
//! hwdownload) and what a CPU writer gives (vaPutImage, an encode's
//! input). Only then: a picture that goes to the screen is exported block
//! linear and never converted (driver.sig).
//!
//! A converter is a type the driver is made with (driver.DriverWith):
//!
//!   pub const wants_fds: bool   whether a Job carries the buffers as
//!                               dma-buf fds (a converter on another GPU
//!                               context imports them)
//!   pub fn run(c: *Self, j: Job, say: Say) Done
//!   pub fn deinit(c: *Self) void
//!
//! `Cpu` here is the CPU's (tiling.convertPicture through the node's
//! mappings: VRAM is read through BAR1, uncached, so this is the slow
//! path): the tests' converter and the last resort. gpu_convert.sig's runs
//! a KIR kernel on the RTX (the shared library's).
//!
//! Allocation-free.

const std = @import("std");
const tiling = @import("tiling.sig");
const node = @import("node.sig");

pub const Direction = enum { to_linear, to_tiled };

/// One conversion of a whole picture (both planes).
pub const Job = struct {
    /// the surface's block-linear buffer and its layout
    tiled: node.Buf,
    layout: tiling.Nv12,
    /// its pitch-linear copy and its layout
    linear: node.Buf,
    lin: tiling.Linear,
    width: u32,
    height: u32,
    /// which GPU's GOB layouts the planes are in
    gob: tiling.Gob,
    dir: Direction,
    /// the two buffers as dma-buf fds (the driver's, held: a converter
    /// dups or imports them, never closes them); -1 unless `wants_fds`
    tiled_fd: i32 = -1,
    linear_fd: i32 = -1,
};

/// How a conversion went.
pub const Done = enum {
    /// on the GPU, finished
    gpu,
    /// on the CPU
    cpu,
    /// not done (the GPU was lost mid-way and the CPU could not either)
    failed,
};

/// A line for stderr (the driver's `say`).
pub const Say = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn line(s: Say, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const l = std.fmt.bufPrint(&buf, "galaxy-va: " ++ fmt ++ "\n", args) catch return;
        s.f(s.ctx, l);
    }
};

/// The CPU's conversion of `j`, through the buffers' mappings.
pub fn onCpu(j: Job) void {
    tiling.convertPicture(j.layout, j.lin, j.gob, j.tiled.bytes(), j.linear.bytes(), j.width, j.height, j.dir == .to_linear);
}

/// The CPU's converter: counts what it did (the tests read it).
pub const Cpu = struct {
    pub const wants_fds = false;
    runs: u32 = 0,

    pub fn run(c: *Cpu, j: Job, _: Say) Done {
        onCpu(j);
        c.runs += 1;
        return .cpu;
    }

    pub fn deinit(_: *Cpu) void {}
};

test "convert: the CPU's, both ways, through a node's buffers" {
    var k = node.Fake{};
    var n = node.Node(*node.Fake){ .sys = &k, .fd = 3 };
    const w = 70;
    const h = 30;
    const layout = tiling.Nv12.of(w, h);
    const lin = tiling.Linear.of(w, h);
    var t = n.alloc(@intCast(layout.bytes), node.G_VRAM).?;
    defer n.free(&t);
    var l = n.alloc(lin.bytes, 0).?;
    defer n.free(&l);
    for (l.bytes()[0..lin.bytes], 0..) |*b, i| b.* = @truncate(i * 31 + 7);
    var c = Cpu{};
    var noop: u8 = 0;
    const say = Say{ .ctx = &noop, .f = struct {
        fn f(_: *anyopaque, _: []const u8) void {}
    }.f };
    const job = Job{ .tiled = t, .layout = layout, .linear = l, .lin = lin, .width = w, .height = h, .gob = .blackwell, .dir = .to_tiled };
    try std.testing.expectEqual(Done.cpu, c.run(job, say));
    // Y (70, 3) and UV pair 5 of row 2, where the formula puts them
    try std.testing.expectEqual(l.bytes()[3 * lin.pitch + 69], t.bytes()[layout.luma.offsetOf(.blackwell8, 69, 3)]);
    try std.testing.expectEqual(l.bytes()[lin.uv_offset + 2 * lin.pitch + 11], t.bytes()[@as(usize, @intCast(layout.chroma_offset)) + layout.chroma.offsetOf(.blackwell16, 11, 2)]);
    @memset(l.bytes(), 0);
    var back = job;
    back.dir = .to_linear;
    try std.testing.expectEqual(Done.cpu, c.run(back, say));
    try std.testing.expectEqual(@as(u8, @truncate((3 * lin.pitch + 69) * 31 + 7)), l.bytes()[3 * lin.pitch + 69]);
    try std.testing.expectEqual(@as(u32, 2), c.runs);
}
