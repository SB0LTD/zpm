//! @zpm/adreno draw — rectangles drawn by the Adreno's graphics pipeline,
//! over any Device (Galaxy's kernel driver, or EmuDevice in the tests).
//!
//! What a compositor draws with: a solid color, an image (a texture times a
//! color), a mask (an 8-bit coverage texture times a color), each a
//! rectangle in window pixels, replacing the target's pixels or blended
//! over them (premultiplied alpha), inside a scissor. The rasterizer walks
//! the rectangle, the texture unit filters, the render backend blends: no
//! compute kernel, no per-pixel command lists.
//!
//! One pass is one command stream: begin(target), the rectangles in order,
//! then submit. The programs are four small pieces of ir3 (a vertex program
//! for a rectangle's two corners, a fragment program per kind), assembled
//! at init.
//!
//! Colors are premultiplied, four floats (r, g, b, a) in [0, 1]. The
//! hardware rounds to the target's 8 bits; a blend's result is the
//! blender's own arithmetic, within a step of 255 of the exact value.
//!
//! Allocation-free: three device buffers (the programs, the textures'
//! descriptors, the stream), sized at init.

const std = @import("std");
const ir3 = @import("ir3.sig");
const ir3_asm = @import("ir3_asm.sig");
const a7xx = @import("a7xx.sig");
const dr = @import("a7xx_draw.sig");
const device = @import("device.sig");

pub const Device = device.Device;
pub const Buffer = device.Buffer;
pub const Fence = device.Fence;
pub const Target = dr.Target;
pub const Texture = dr.Texture;
pub const Format = dr.Format;
pub const Filter = dr.Filter;
pub const Blend = dr.Blend;

pub const Error = device.Error || ir3_asm.Error || error{
    /// The pass's rectangles did not fit the stream.
    StreamFull,
    /// Its textures' descriptors did not fit their buffer.
    StateFull,
    BadKernel,
    /// A rectangle before begin(), or begin() twice.
    NoPass,
};

/// What a rectangle's pixels are.
pub const Kind = enum(u8) { solid, image, mask };
const KINDS = 3;

/// A rectangle's corners: x0, y0, x1, y1 (pixels; x1 and y1 past the end).
pub const Rect = [4]f32;
/// Premultiplied r, g, b, a.
pub const Color = [4]f32;

// ── The programs ────────────────────────────────────────────────────────────
// They are the programs turnip's own clears and blits run (Mesa compiled
// them; the tests hold the words here to its): the vertex's index arrives
// in r0.x; the position leaves in r0.yzw and r1.x, the varyings (the
// texture coordinates) in r1.yz. A fragment's barycentrics arrive in
// r0.xy, and where it has a texture the pipeline has already sampled it
// at the varyings into r0.zw and r1.xy (a prefetch: the program has no
// sample instruction and reads the result through (sy)). Its color leaves
// in r0 (solid) or from r1.z.

/// c0: the first corner (x, y, u, v); c1: the second. Vertex 0 gets c0 and
/// vertex 1 gets c1; z is 0 and w is 1.
const VS =
    \\@out r0.y, 4
    \\@out r1.y, 2
    \\mov.u32u32 r0.w, 0
    \\mov.u32u32 r1.x, 0x3f800000
    \\(rpt1)sel.b32 r0.y, (r)c1.x, r0.x, (r)c0.x
    \\(rpt1)sel.b32 r1.y, (r)c1.z, r0.x, (r)c0.z
    \\end
;

/// c0: the color.
const FS_SOLID =
    \\@threadsize 128
    \\@out r0.x, 4
    \\mov.u32u32 r0.x, c0.x
    \\mov.u32u32 r0.y, c0.y
    \\mov.u32u32 r0.z, c0.z
    \\mov.u32u32 r0.w, c0.w
    \\end
;

/// The prefetched texel times c0.
const FS_IMAGE =
    \\@threadsize 128
    \\@out r1.z, 4
    \\bary.f (ei)r63.x, 0, (last)r0.x
    \\(sy)(rpt3)mul.f r1.z, (last)(r)r0.z, (r)c0.x
    \\end
;

/// The prefetched texel's first channel (coverage) times c0.
const FS_MASK =
    \\@threadsize 128
    \\@out r1.z, 4
    \\bary.f (ei)r63.x, 0, (last)r0.x
    \\(sy)(rpt3)mul.f r1.z, r0.z, (r)c0.x
    \\end
;

const SOURCES = [1 + KINDS][]const u8{ VS, FS_SOLID, FS_IMAGE, FS_MASK };
/// Instruction words a program may take (with its padding).
const WORDS = 64;
const CODE_BYTES = 4096;
/// Where the border colors' zeros are in the code buffer.
const BORDER_AT = CODE_BYTES - 256;
/// Bytes a texture's descriptors take in the state buffer.
const BINDING = 128;

pub const Options = struct {
    /// Bytes of command stream a pass may take (24 dwords a rectangle,
    /// more where the kind, the blend or the texture changes).
    stream_bytes: usize = 256 * 1024,
    /// Bytes of texture descriptors a pass may take (BINDING a change of
    /// texture).
    state_bytes: usize = 64 * 1024,
};

pub const Stats = struct {
    rects: u32 = 0,
    /// Changes of program, and of texture.
    programs: u32 = 0,
    bindings: u32 = 0,
    stream_dwords: u32 = 0,
};

/// The renderer: at a fixed address once init has run (its programs point
/// into it).
pub const Renderer = struct {
    dev: Device,
    code: Buffer,
    state: Buffer,
    ib: Buffer,
    kernels: [1 + KINDS]ir3_asm.Kernel,
    words: [1 + KINDS][WORDS]u64,
    progs: [KINDS]dr.Program,
    // The pass being recorded.
    s: dr.Stream,
    in_pass: bool,
    state_used: usize,
    state_full: bool,
    kind: ?Kind,
    blend: ?Blend,
    tex: ?Texture,
    stats: Stats,

    /// Assemble the programs and take the buffers. `work` is scratch.
    pub fn init(r: *Renderer, dev: Device, work: *ir3_asm.Work, opts: Options) Error!void {
        r.dev = dev;
        r.in_pass = false;
        r.stats = .{};
        for (SOURCES, 0..) |src, i| {
            r.kernels[i] = try ir3_asm.assemble(ir3.A7XX, src, work, &r.words[i]);
            if (r.kernels[i].code.len * 8 > 512) return error.BadKernel;
        }
        r.code = try dev.alloc(CODE_BYTES);
        errdefer dev.free(r.code);
        r.state = try dev.alloc(opts.state_bytes);
        errdefer dev.free(r.state);
        r.ib = try dev.alloc(opts.stream_bytes);
        @memset(r.code.cpu, 0);
        for (r.kernels, 0..) |k, i| {
            const dst: []u64 = @alignCast(std.mem.bytesAsSlice(u64, r.code.cpu[i * 512 ..][0..512]));
            @memcpy(dst[0..k.code.len], k.code);
        }
        dev.toDevice(r.code, 0, CODE_BYTES);
        const vs_va = r.code.va;
        for (0..KINDS) |k| {
            const sampled = k != @intFromEnum(Kind.solid);
            r.progs[k] = .{
                .vs = &r.kernels[0],
                .vs_va = vs_va,
                .fs = &r.kernels[1 + k],
                .fs_va = r.code.va + (1 + k) * 512,
                .vertexid_reg = 0,
                .pos_reg = 1,
                .vary_reg = if (sampled) 5 else ir3_asm.INVALID_REG,
                .varyings = if (sampled) 2 else 0,
                .ij_reg = if (sampled) 0 else ir3_asm.INVALID_REG,
                .color_reg = if (sampled) 6 else 0,
                .textures = if (sampled) 1 else 0,
                .prefetch_reg = if (sampled) 2 else ir3_asm.INVALID_REG,
            };
        }
    }

    pub fn deinit(r: *Renderer) void {
        r.dev.free(r.ib);
        r.dev.free(r.state);
        r.dev.free(r.code);
    }

    /// Start a pass on `t`: its pixels as they are, the scissor the whole
    /// target.
    pub fn begin(r: *Renderer, t: Target) void {
        r.s = .{ .buf = r.ib.words() };
        r.in_pass = true;
        r.state_used = 0;
        r.state_full = false;
        r.kind = null;
        r.blend = null;
        r.tex = null;
        r.stats = .{};
        dr.setup(&r.s, r.code.va + BORDER_AT);
        dr.begin(&r.s, t);
    }

    /// Draw only inside [x0, x1) x [y0, y1) from here on.
    pub fn scissor(r: *Renderer, x0: u32, y0: u32, x1: u32, y1: u32) void {
        if (!r.in_pass) return;
        dr.scissor(&r.s, x0, y0, x1, y1);
    }

    fn use(r: *Renderer, kind: Kind, b: Blend) void {
        if (r.kind == null or r.kind.? != kind) {
            // (the programs were checked at init: this cannot fail)
            dr.program(&r.s, &r.progs[@intFromEnum(kind)]) catch unreachable;
            r.kind = kind;
            r.tex = null;
            r.stats.programs += 1;
        }
        if (r.blend == null or r.blend.? != b) {
            dr.blend(&r.s, b);
            r.blend = b;
        }
    }

    fn bind(r: *Renderer, t: Texture) void {
        if (r.tex) |cur| if (std.meta.eql(cur, t)) return;
        if (r.state_used + BINDING > r.state.cpu.len) {
            r.state_full = true;
            return;
        }
        const at = r.state_used;
        const out: []u32 = @alignCast(std.mem.bytesAsSlice(u32, r.state.cpu[at..][0..BINDING]));
        dr.descriptors(&.{t}, out);
        dr.textures(&r.s, 1, r.state.va + at);
        r.state_used += BINDING;
        r.tex = t;
        r.stats.bindings += 1;
    }

    fn corners(r: *Renderer, rc: Rect, uv: [4]f32, color: Color) void {
        const v = [8]f32{ rc[0], rc[1], uv[0], uv[1], rc[2], rc[3], uv[2], uv[3] };
        dr.vsConstants(&r.s, @ptrCast(&v));
        dr.fsConstants(&r.s, @ptrCast(&color));
        dr.rect(&r.s);
        r.stats.rects += 1;
    }

    /// A rectangle of one color.
    pub fn fill(r: *Renderer, rc: Rect, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.solid, b);
        r.corners(rc, .{ 0, 0, 0, 0 }, color);
    }

    /// `t`'s texels from (uv[0], uv[1]) to (uv[2], uv[3]) across the
    /// rectangle, each times `tint`.
    pub fn image(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, tint: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.image, b);
        r.bind(t);
        r.corners(rc, uv, tint);
    }

    /// `color` times the coverage in `t` (an r8 texture), as text is drawn.
    pub fn mask(r: *Renderer, rc: Rect, t: Texture, uv: [4]f32, color: Color, b: Blend) void {
        if (!r.in_pass or !(rc[2] > rc[0] and rc[3] > rc[1])) return;
        r.use(.mask, b);
        r.bind(t);
        r.corners(rc, uv, color);
    }

    /// End the pass and hand it to the GPU. The target's pixels are in
    /// memory once the fence is done (fromDevice them before the CPU reads).
    pub fn submit(r: *Renderer) Error!Fence {
        if (!r.in_pass) return error.NoPass;
        r.in_pass = false;
        dr.end(&r.s);
        if (r.state_full) return error.StateFull;
        r.s.check() catch return error.StreamFull;
        r.stats.stream_dwords = @intCast(r.s.len);
        if (r.state_used != 0) r.dev.toDevice(r.state, 0, r.state_used);
        r.dev.toDevice(r.ib, 0, r.s.len * 4);
        return r.dev.submit(r.ib, @intCast(r.s.len));
    }

    /// submit, and wait for it.
    pub fn run(r: *Renderer, timeout_us: u64) Error!void {
        const f = try r.submit();
        try r.dev.wait(f, timeout_us);
    }
};

// ── Tests: the streams on the emulated device ───────────────────────────────

const T = struct {
    var arena: [8 << 20]u8 align(4096) = undefined;
    var gpu_view: [8 << 20]u8 align(4096) = undefined;
    var dev: device.EmuDevice = undefined;
    var asm_work: ir3_asm.Work = .{};
    var r: Renderer = undefined;
    const W = 64;
    const H = 32;
    var target: Buffer = undefined;

    fn log(line: []const u8) void {
        std.debug.print("emu: {s}\n", .{line});
    }

    fn start() !Target {
        dev = .{ .arena = &arena, .gpu_view = &gpu_view, .log = &log };
        const d = dev.device();
        try r.init(d, &asm_work, .{ .stream_bytes = 64 * 1024, .state_bytes = 4096 });
        target = try d.alloc(W * H * 4);
        return .{ .va = target.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8 };
    }

    fn pixels() []const u32 {
        dev.device().fromDevice(target, 0, W * H * 4);
        return @alignCast(std.mem.bytesAsSlice(u32, target.cpu));
    }

    fn at(x: u32, y: u32) u32 {
        return pixels()[y * W + x];
    }
};

fn near(want: u32, got: u32, tol: i32) bool {
    for (0..4) |c| {
        const a: i32 = @intCast((want >> @intCast(8 * c)) & 0xff);
        const b: i32 = @intCast((got >> @intCast(8 * c)) & 0xff);
        if (@abs(a - b) > tol) return false;
    }
    return true;
}

fn expectNear(want: u32, got: u32, tol: i32) !void {
    if (!near(want, got, tol)) {
        std.debug.print("pixel: want {x:0>8}, got {x:0>8}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

test "the programs are turnip's, word for word" {
    _ = try T.start();
    defer T.r.deinit();
    // (from its X1-45 streams: the 3D blit's vertex program without the
    // layer coordinate, the clear's fragment program, and the fragment
    // program of a textured draw whose texel is prefetched)
    const vs = [_]u64{ 0x204cc003_00000000, 0x204cc004_3f800000, 0x64800901_30001004, 0x64800905_30021006, 0x03000000_00000000 };
    const solid = [_]u64{ 0x202cc000_00000000, 0x202cc001_00000001, 0x202cc002_00000002, 0x202cc003_00000003, 0x03000000_00000000 };
    const image = [_]u64{ 0x473080fc_04002000, 0x50780b06_10000402, 0x03000000_00000000 };
    try std.testing.expectEqualSlices(u64, &vs, T.r.kernels[0].code[0..vs.len]);
    try std.testing.expectEqualSlices(u64, &solid, T.r.kernels[1].code[0..solid.len]);
    try std.testing.expectEqualSlices(u64, &image, T.r.kernels[2].code[0..image.len]);
    for (T.r.kernels) |k| try std.testing.expect(k.instrlen == 1);
    // footprints as Mesa counts them: the vertex program's two full
    // registers, the solid program's one, the image program's three (its
    // color ends in r2.y), no half registers
    try std.testing.expectEqual(@as(u8, 2), T.r.kernels[0].full_regs);
    try std.testing.expectEqual(@as(u8, 1), T.r.kernels[1].full_regs);
    try std.testing.expectEqual(@as(u8, 3), T.r.kernels[2].full_regs);
    try std.testing.expectEqual(@as(u8, 0), T.r.kernels[0].half_regs);
}

test "solid rectangles: where the rasterizer puts them, the scissor, the blend" {
    const t = try T.start();
    defer T.r.deinit();
    T.r.begin(t);
    // the whole target dark blue (0xAARRGGBB words: bytes B, G, R, A)
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0.5, 1 }, .replace);
    // an opaque red rectangle, [4, 20) x [2, 10)
    T.r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    // half-transparent green over both, [10, 30) x [6, 16) (premultiplied)
    T.r.fill(.{ 10, 6, 30, 16 }, .{ 0, 0.5, 0, 0.5 }, .over);
    // white, but only inside the scissor [40, 50) x [20, 30)
    T.r.scissor(40, 20, 50, 30);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 1, 1, 1, 1 }, .replace);
    try T.r.run(1_000_000);
    try std.testing.expectEqual(@as(u32, 4), T.dev.draws);
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(0, 0));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(63, 31));
    // the red rectangle's corners, inside and just outside
    try std.testing.expectEqual(@as(u32, 0xffff0000), T.at(4, 2));
    try std.testing.expectEqual(@as(u32, 0xffff0000), T.at(9, 5));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(3, 2));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(4, 1));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(20, 5));
    // green over red: red halves, green half, alpha stays one
    try expectNear(0xff808000, T.at(10, 6), 1);
    try expectNear(0xff808000, T.at(19, 9), 1);
    // green over blue
    try expectNear(0xff008040, T.at(25, 12), 1);
    // the scissored white
    try std.testing.expectEqual(@as(u32, 0xffffffff), T.at(40, 20));
    try std.testing.expectEqual(@as(u32, 0xffffffff), T.at(49, 29));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(39, 20));
    try std.testing.expectEqual(@as(u32, 0xff000080), T.at(50, 29));
}

test "an image: copied texel for texel, stretched with the bilinear filter, tinted and blended" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    // an 8 x 4 texture: red rises with x, green with y, opaque
    const tex_buf = try d.alloc(8 * 4 * 4);
    const tw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, tex_buf.cpu));
    for (0..4) |y| for (0..8) |x| {
        tw[y * 8 + x] = 0xff000000 | (@as(u32, @intCast(x * 32)) << 16) | (@as(u32, @intCast(y * 64)) << 8);
    };
    d.toDevice(tex_buf, 0, 8 * 4 * 4);
    const nearest = Texture{ .va = tex_buf.va, .width = 8, .height = 4, .pitch = 32, .format = .bgra8, .filter = .nearest };
    var linear = nearest;
    linear.filter = .linear;
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 0, 1 }, .replace);
    // texel for texel at (2, 1)
    T.r.image(.{ 2, 1, 10, 5 }, nearest, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    // twice the size at (20, 4), filtered
    T.r.image(.{ 20, 4, 36, 12 }, linear, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    // at half opacity over the black, at (40, 20)
    T.r.image(.{ 40, 20, 48, 24 }, nearest, .{ 0, 0, 8, 4 }, .{ 0.5, 0.5, 0.5, 0.5 }, .over);
    try T.r.run(1_000_000);
    for (0..4) |y| for (0..8) |x| {
        try std.testing.expectEqual(tw[y * 8 + x], T.at(@intCast(2 + x), @intCast(1 + y)));
    };
    try std.testing.expectEqual(@as(u32, 0xff000000), T.at(10, 1));
    // stretched: pixel (20 + 2i + 1, 4 + 2j + 1)'s centre is at texel
    // (i + 0.75, j + 0.75): a quarter of the way from texel i to i + 1
    try expectNear(0xff000000 | (@as(u32, 32 * 3 + 8) << 16) | (@as(u32, 64 + 16) << 8), T.at(27, 7), 2);
    // (clamped at the edges: the first pixel is the first texel)
    try expectNear(tw[0], T.at(20, 4), 2);
    // half of texel (7, 3) over opaque black
    try expectNear(0xff000000 | (@as(u32, 7 * 32 / 2) << 16) | (@as(u32, 3 * 64 / 2) << 8), T.at(47, 23), 2);
    try std.testing.expectEqual(@as(u32, 3), T.r.stats.bindings);
}

test "a mask: coverage times a color, over what is there" {
    const t = try T.start();
    defer T.r.deinit();
    const d = T.dev.device();
    // 4 x 2 coverage: 0, 85, 170, 255 in both rows
    const m_buf = try d.alloc(64);
    for (0..2) |y| for (0..4) |x| {
        m_buf.cpu[y * 4 + x] = @intCast(x * 85);
    };
    d.toDevice(m_buf, 0, 64);
    const m = Texture{ .va = m_buf.va, .width = 4, .height = 2, .pitch = 4, .format = .r8, .filter = .nearest };
    T.r.begin(t);
    T.r.fill(.{ 0, 0, T.W, T.H }, .{ 0, 0, 1, 1 }, .replace);
    // white text over blue
    T.r.mask(.{ 8, 8, 12, 10 }, m, .{ 0, 0, 4, 2 }, .{ 1, 1, 1, 1 }, .over);
    try T.r.run(1_000_000);
    try expectNear(0xff0000ff, T.at(8, 8), 1);
    try expectNear(0xff5555ff, T.at(9, 8), 1);
    try expectNear(0xffaaaaff, T.at(10, 9), 1);
    try expectNear(0xffffffff, T.at(11, 9), 1);
}

test "a pass that does not fit says so; a wrong stream is refused by the emulated GPU" {
    const t = try T.start();
    defer T.r.deinit();
    try std.testing.expectError(error.NoPass, T.r.submit());
    T.r.begin(t);
    for (0..4000) |_| T.r.fill(.{ 0, 0, 4, 4 }, .{ 1, 1, 1, 1 }, .replace);
    try std.testing.expectError(error.StreamFull, T.r.submit());
    // a draw with no target marked for direct rendering
    const d = T.dev.device();
    T.dev.log = null;
    T.dev.marker = 0;
    var s = dr.Stream{ .buf = T.r.ib.words() };
    dr.rect(&s);
    try std.testing.expectError(error.DeviceLost, d.run(T.r.ib, @intCast(s.len), 1_000_000));
}

/// The last value a stream writes to each register (type-4 packets).
fn lastWrites(words: []const u32, out: *[0x10000]u32, seen: *[0x10000]bool) void {
    @memset(seen, false);
    var i: usize = 0;
    while (i < words.len) {
        const h = words[i];
        if (h >> 28 == 4) {
            const reg = (h >> 8) & 0x3ffff;
            const cnt = h & 0x7f;
            for (0..cnt) |k| if (reg + k < out.len and i + 1 + k < words.len) {
                out[reg + k] = words[i + 1 + k];
                seen[reg + k] = true;
            };
            i += 1 + cnt;
        } else i += 1 + (h & 0x3fff);
    }
}

test "the state is turnip's: the values its X1-45 streams carry for the same draws" {
    const t = try T.start();
    defer T.r.deinit();
    const S = struct {
        var regs: [0x10000]u32 = undefined;
        var seen: [0x10000]bool = undefined;
    };
    const d = T.dev.device();
    const tex_buf = try d.alloc(16 * 16 * 4);
    const tx = Texture{ .va = tex_buf.va, .width = 16, .height = 16, .pitch = 256, .format = .rgba8, .filter = .linear };
    T.r.begin(t);
    T.r.fill(.{ 16, 8, 80, 40 }, .{ 0.25, 0.5, 0.75, 1 }, .replace);
    const solid_end = T.r.s.len;
    lastWrites(T.r.s.words(), &S.regs, &S.seen);
    // Per stream (tu6_init_static_regs as the X1-45) and per pass
    // (tu6_sysmem_render_begin), then a rectangle of one color (its clear).
    const solid = [_][2]u32{
        .{ 0x8e07, 0x00000068 }, .{ 0xb600, 0x13100000 }, .{ 0xb602, 0x00040724 }, .{ 0xae03, 0x10001402 },
        .{ 0x8120, 0x09510840 }, .{ 0x8121, 0x00000a62 }, .{ 0xab00, 0x00000005 }, .{ 0xa009, 0x00000003 },
        .{ 0x8811, 0x00000010 }, .{ 0xb309, 0x000000a2 }, .{ 0x8e09, 0x00000007 }, .{ 0x9885, 0x00020000 },
        .{ 0x9886, 0x00002000 }, .{ 0x88e5, 0x60000000 },
        .{ 0x80a1, 0x03c00000 }, .{ 0x8800, 0x03c00000 }, .{ 0x8812, 0x000003ff }, .{ 0x88e4, 0x00000000 },
        .{ 0x8000, 0x00000381 }, .{ 0x80a0, 0x00000002 }, .{ 0x9108, 0x00000003 }, .{ 0x9809, 0x00000003 },
        .{ 0x9307, 0x00000003 }, .{ 0x80a3, 0x00000004 }, .{ 0x8803, 0x00000004 }, .{ 0x8891, 0x00000001 },
        .{ 0x8820, 0x00000780 }, .{ 0x8865, 0xffff0000 }, .{ 0x9208, 0x00000009 }, .{ 0x9212, 0xffffffff },
        .{ 0x9304, 0xff00ff00 }, .{ 0x910c, 0x00000006 }, .{ 0x9b07, 0x00000006 }, .{ 0xa008, 0x00000006 },
        .{ 0xa001, 0xfcfcfc00 }, .{ 0xa002, 0x0000fcfc }, .{ 0xa003, 0xfcfcfcfc }, .{ 0xa004, 0x000000fc },
        .{ 0xa005, 0x0000fcfc }, .{ 0xa800, 0x00100100 }, .{ 0xa980, 0x81100080 }, .{ 0xa99e, 0x01ff7fc8 },
        .{ 0xa9ae, 0x00000300 }, .{ 0xa9c6, 0x00000001 }, .{ 0xa9c7, 0x00000007 }, .{ 0xa9c8, 0xfcfcfcfc },
        .{ 0xa9c9, 0xfcfcfcfc }, .{ 0xa9ca, 0xfcfcfcfc }, .{ 0xa9cb, 0x0000fcfc }, .{ 0xa98c, 0xfcfcfc00 },
        .{ 0xa98e, 0x00000000 }, .{ 0xa98b, 0x0000000f }, .{ 0x880d, 0x0000000f }, .{ 0xab04, 0x00000100 },
        .{ 0xa823, 0x00000100 },
    };
    for (solid) |g| {
        if (!S.seen[g[0]] or S.regs[g[0]] != g[1]) {
            std.debug.print("register {x:0>4}: turnip {x:0>8}, here {x:0>8} (written: {})\n", .{ g[0], g[1], S.regs[g[0]], S.seen[g[0]] });
            return error.TestUnexpectedResult;
        }
    }
    // A textured rectangle blended over (its 3D blit's linkage and
    // prefetch; a blended draw's fragment state and blend).
    T.r.image(.{ 32, 16, 160, 80 }, tx, .{ 0, 0, 16, 16 }, .{ 1, 1, 1, 1 }, .over);
    lastWrites(T.r.s.words()[solid_end..], &S.regs, &S.seen);
    const image = [_][2]u32{
        .{ 0xa802, 0x00000002 }, .{ 0xa803, 0x0f010305 }, .{ 0xa813, 0x00000200 }, .{ 0x9301, 0x00ff0206 },
        .{ 0x9b01, 0x00000006 }, .{ 0x9304, 0xff01ff06 }, .{ 0x9212, 0xfffffffc }, .{ 0x9208, 0x00000009 },
        .{ 0x8005, 0x00000001 }, .{ 0x8809, 0x00000401 }, .{ 0xa9c9, 0xfcfcfc00 }, .{ 0xa9ae, 0x00000302 },
        .{ 0xa9c6, 0x00000003 }, .{ 0xa99e, 0x01ff7fd1 }, .{ 0xa99f, 0x04784000 }, .{ 0xa9a3, 0x00000000 },
        .{ 0xa980, 0x85500180 }, .{ 0xa98e, 0x00000006 }, .{ 0xa9a7, 0x00000001 }, .{ 0xab04, 0x00020300 },
        .{ 0x8820, 0x00000783 }, .{ 0x8821, 0x07010701 }, .{ 0x8865, 0xffff0101 }, .{ 0xa989, 0x00000101 },
    };
    for (image) |g| {
        if (!S.seen[g[0]] or S.regs[g[0]] != g[1]) {
            std.debug.print("register {x:0>4}: turnip {x:0>8}, here {x:0>8} (written: {})\n", .{ g[0], g[1], S.regs[g[0]], S.seen[g[0]] });
            return error.TestUnexpectedResult;
        }
    }
    // The texture's descriptor: a 16 x 16 RGBA8 linear image as turnip
    // describes it (its address apart).
    const desc: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, T.r.state.cpu[0..80]));
    try std.testing.expectEqual(@as(u32, 0x0006092a), desc[0]);
    try std.testing.expectEqual(@as(u32, 0x00000060), desc[1]);
    try std.testing.expectEqualSlices(u32, &.{ 0x0c006880, 0x00080010, 0x20008002, 0x00000001 }, desc[4..8]);
    try std.testing.expectEqual(@as(u32, 1 << 17), desc[9] & 0xfffe0000);
}

// ── The self-test: the pipeline on the real GPU ─────────────────────────────
// What the tests above check on the emulated device, drawn on any Device
// and compared with the values the arithmetic gives, case by case and each
// in a pass of its own, so the log names the first thing the hardware does
// differently (or the pass it does not finish). Then how fast it fills.

pub const SelfTest = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    /// A pass did not finish (the GPU hung or faulted): the cases after
    /// it did not run.
    lost: bool = false,
    /// The fill rate measured (megapixels a second; 0: not measured).
    mpx_per_s: u32 = 0,
};

const Probe = struct { x: u32, y: u32, want: u32, tol: i32 = 1 };

const Run = struct {
    r: *Renderer,
    dev: Device,
    target: Target,
    pixels: Buffer,
    log: *const fn (line: []const u8) void,
    res: SelfTest = .{},

    fn say(c: *Run, comptime fmt: []const u8, args: anytype) void {
        var buf: [240]u8 = undefined;
        c.log(std.fmt.bufPrint(&buf, fmt, args) catch "draw self-test: (a line too long)");
    }

    /// Run the pass recorded and compare the probes.
    fn check(c: *Run, name: []const u8, probes: []const Probe) void {
        if (c.res.lost) return;
        c.say("draw self-test: {s} ...", .{name});
        c.r.run(2_000_000) catch |e| {
            c.say("draw self-test: {s}: the pass did not finish ({s}, {d} dwords, {d} rectangles)", .{ name, @errorName(e), c.r.stats.stream_dwords, c.r.stats.rects });
            c.res.lost = e == error.Timeout or e == error.DeviceLost;
            c.res.failed += 1;
            return;
        };
        const bytes = c.target.pitch * c.target.height;
        c.dev.fromDevice(c.pixels, 0, bytes);
        const px: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, c.pixels.cpu[0..bytes]));
        const stride = c.target.pitch / 4;
        for (probes) |p| {
            const got = px[p.y * stride + p.x];
            if (!near(p.want, got, p.tol)) {
                c.say("draw self-test: {s}: pixel ({d}, {d}) is {x:0>8}, not {x:0>8}; the row starts {x:0>8} {x:0>8} {x:0>8} {x:0>8}", .{ name, p.x, p.y, got, p.want, px[p.y * stride], px[p.y * stride + 1], px[p.y * stride + 2], px[p.y * stride + 3] });
                c.res.failed += 1;
                return;
            }
        }
        c.res.passed += 1;
    }
};

/// Draw the cases on `dev` and say what happened, a line a case. `r` is
/// the caller's storage for the renderer (not yet started) and `asm_work`
/// the assembler's scratch; `now_us` (a clock) lets the last case measure
/// the fill rate.
pub fn selfTest(dev: Device, r: *Renderer, asm_work: *ir3_asm.Work, log: *const fn (line: []const u8) void, now_us: ?*const fn () u64) SelfTest {
    const W = 64;
    const H = 32;
    r.init(dev, asm_work, .{ .stream_bytes = 64 * 1024, .state_bytes = 4096 }) catch |e| {
        var buf: [120]u8 = undefined;
        log(std.fmt.bufPrint(&buf, "draw self-test: the renderer did not start ({s})", .{@errorName(e)}) catch "draw self-test: the renderer did not start");
        return .{ .failed = 1 };
    };
    defer r.deinit();
    const pixels = dev.alloc(W * H * 4) catch return .{ .failed = 1 };
    defer dev.free(pixels);
    const tex_buf = dev.alloc(4096) catch return .{ .failed = 1 };
    defer dev.free(tex_buf);
    const t = Target{ .va = pixels.va, .width = W, .height = H, .pitch = W * 4, .format = .bgra8 };
    var c = Run{ .r = r, .dev = dev, .target = t, .pixels = pixels, .log = log };
    c.say("draw self-test: the graphics pipeline (rectangles, textures, blending), programs at 0x{x}, a {d} x {d} target at 0x{x}", .{ r.code.va, W, H, pixels.va });

    const BLUE = Color{ 0, 0, 0.5, 1 };
    const blue: u32 = 0xff000080;
    // An 8 x 4 texture (red rises with x, green with y) and, after it, a
    // 4 x 2 coverage mask (0, 85, 170, 255).
    const tw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, tex_buf.cpu[0 .. 8 * 4 * 4]));
    for (0..4) |y| for (0..8) |x| {
        tw[y * 8 + x] = 0xff000000 | (@as(u32, @intCast(x * 32)) << 16) | (@as(u32, @intCast(y * 64)) << 8);
    };
    for (0..2) |y| for (0..4) |x| {
        tex_buf.cpu[256 + y * 64 + x] = @intCast(x * 85);
    };
    dev.toDevice(tex_buf, 0, 4096);
    const nearest = Texture{ .va = tex_buf.va, .width = 8, .height = 4, .pitch = 32, .format = .bgra8, .filter = .nearest };
    var linear = nearest;
    linear.filter = .linear;
    const mask = Texture{ .va = tex_buf.va + 256, .width = 4, .height = 2, .pitch = 64, .format = .r8, .filter = .nearest };

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    c.check("one color over the whole target", &.{ .{ .x = 0, .y = 0, .want = blue }, .{ .x = 63, .y = 0, .want = blue }, .{ .x = 0, .y = 31, .want = blue }, .{ .x = 63, .y = 31, .want = blue }, .{ .x = 31, .y = 15, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    c.check("a rectangle's edges", &.{ .{ .x = 4, .y = 2, .want = 0xffff0000 }, .{ .x = 19, .y = 9, .want = 0xffff0000 }, .{ .x = 3, .y = 2, .want = blue }, .{ .x = 4, .y = 1, .want = blue }, .{ .x = 20, .y = 9, .want = blue }, .{ .x = 19, .y = 10, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.scissor(40, 20, 50, 30);
    r.fill(.{ 0, 0, W, H }, .{ 1, 1, 1, 1 }, .replace);
    c.check("the scissor", &.{ .{ .x = 40, .y = 20, .want = 0xffffffff }, .{ .x = 49, .y = 29, .want = 0xffffffff }, .{ .x = 39, .y = 20, .want = blue }, .{ .x = 50, .y = 29, .want = blue }, .{ .x = 40, .y = 19, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, BLUE, .replace);
    r.fill(.{ 4, 2, 20, 10 }, .{ 1, 0, 0, 1 }, .replace);
    r.fill(.{ 10, 6, 30, 16 }, .{ 0, 0.5, 0, 0.5 }, .over);
    c.check("a half-transparent color blended over", &.{ .{ .x = 10, .y = 6, .want = 0xff808000, .tol = 2 }, .{ .x = 25, .y = 12, .want = 0xff008040, .tol = 2 }, .{ .x = 9, .y = 6, .want = 0xffff0000 }, .{ .x = 30, .y = 12, .want = blue } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 2, 1, 10, 5 }, nearest, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    c.check("an image, texel for texel", &.{ .{ .x = 2, .y = 1, .want = tw[0] }, .{ .x = 9, .y = 1, .want = tw[7] }, .{ .x = 2, .y = 4, .want = tw[24] }, .{ .x = 9, .y = 4, .want = tw[31] }, .{ .x = 5, .y = 2, .want = tw[11] }, .{ .x = 10, .y = 1, .want = 0xff000000 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 20, 4, 36, 12 }, linear, .{ 0, 0, 8, 4 }, .{ 1, 1, 1, 1 }, .replace);
    c.check("an image stretched, filtered", &.{ .{ .x = 27, .y = 7, .want = 0xff000000 | (@as(u32, 32 * 3 + 8) << 16) | (@as(u32, 64 + 16) << 8), .tol = 3 }, .{ .x = 20, .y = 4, .want = tw[0], .tol = 3 }, .{ .x = 35, .y = 11, .want = tw[31], .tol = 3 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 0, 1 }, .replace);
    r.image(.{ 40, 20, 48, 24 }, nearest, .{ 0, 0, 8, 4 }, .{ 0.5, 0.5, 0.5, 0.5 }, .over);
    c.check("an image at half opacity over", &.{ .{ .x = 47, .y = 23, .want = 0xff000000 | (@as(u32, 7 * 32 / 2) << 16) | (@as(u32, 3 * 64 / 2) << 8), .tol = 2 }, .{ .x = 40, .y = 20, .want = 0xff000000, .tol = 2 } });

    r.begin(t);
    r.fill(.{ 0, 0, W, H }, .{ 0, 0, 1, 1 }, .replace);
    r.mask(.{ 8, 8, 12, 10 }, mask, .{ 0, 0, 4, 2 }, .{ 1, 1, 1, 1 }, .over);
    c.check("a coverage mask (text)", &.{ .{ .x = 8, .y = 8, .want = 0xff0000ff, .tol = 2 }, .{ .x = 9, .y = 8, .want = 0xff5555ff, .tol = 2 }, .{ .x = 10, .y = 9, .want = 0xffaaaaff, .tol = 2 }, .{ .x = 11, .y = 9, .want = 0xffffffff, .tol = 2 } });

    // How fast it fills: a 1024 x 1024 target, an image the same size over
    // it once and a half-transparent color 31 times (32 megapixels blended).
    if (!c.res.lost and c.res.failed == 0) speed: {
        const clock = now_us orelse break :speed;
        const N = 1024;
        const big = dev.alloc(N * N * 4) catch break :speed;
        defer dev.free(big);
        const src = dev.alloc(N * N * 4) catch break :speed;
        defer dev.free(src);
        const sw: []u32 = @alignCast(std.mem.bytesAsSlice(u32, src.cpu));
        for (sw, 0..) |*p, i| p.* = 0xff000000 | @as(u32, @truncate(i * 2654435761));
        dev.toDevice(src, 0, N * N * 4);
        const bt = Target{ .va = big.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8 };
        const st = Texture{ .va = src.va, .width = N, .height = N, .pitch = N * 4, .format = .bgra8, .filter = .linear };
        r.begin(bt);
        r.image(.{ 0, 0, N, N }, st, .{ 0, 0, N, N }, .{ 1, 1, 1, 1 }, .replace);
        for (0..31) |_| r.fill(.{ 0, 0, N, N }, .{ 0.01, 0.01, 0.01, 0.02 }, .over);
        c.say("draw self-test: the fill rate ...", .{});
        const t0 = clock();
        r.run(5_000_000) catch |e| {
            c.say("draw self-test: the fill rate: the pass did not finish ({s})", .{@errorName(e)});
            c.res.lost = true;
            c.res.failed += 1;
            break :speed;
        };
        const us = @max(clock() - t0, 1);
        c.res.mpx_per_s = @intCast(@min(@as(u64, 32) * N * N / us, std.math.maxInt(u32)));
        dev.fromDevice(big, 0, 16);
        const first: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, big.cpu[0..16]));
        c.say("draw self-test: 32 megapixels blended in {d} us: {d} megapixels a second (first pixel {x:0>8})", .{ us, c.res.mpx_per_s, first[0] });
    }
    c.say("draw self-test: {d} passed, {d} failed{s}", .{ c.res.passed, c.res.failed, if (c.res.lost) ", and the GPU did not finish a pass" else "" });
    return c.res;
}

fn testLog(line: []const u8) void {
    if (std.mem.indexOf(u8, line, " is ") != null or std.mem.indexOf(u8, line, "did not") != null) std.debug.print("{s}\n", .{line});
}

test "the self-test passes on the emulated device" {
    T.dev = .{ .arena = &T.arena, .gpu_view = &T.gpu_view, .log = &T.log };
    // (no clock: the fill-rate case's megapixels would take the emulator minutes)
    const res = selfTest(T.dev.device(), &T.r, &T.asm_work, &testLog, null);
    try std.testing.expectEqual(@as(u32, 8), res.passed);
    try std.testing.expectEqual(@as(u32, 0), res.failed);
    try std.testing.expect(!res.lost);
}
