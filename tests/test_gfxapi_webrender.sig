//! WebRender's shaders through gfxapi's GLSL compiler: every variant a GLES
//! device asks for, assembled as WebRender assembles them, compiled and
//! linked through GL's shader and program objects (which also generate
//! and verify both stages' KIR); then each program's draw kernels
//! (vertices, setup, tiles) built and compiled for the Surface's Adreno
//! (ir3) and the PC's RTX (sm_120), as a first draw would. Every variant
//! must link and every kernel compile for both, each in the 16 MiB of
//! compile work Galaxy's gfx_render gives (WebRender's largest kernels
//! are several times what sm_120 took before 2026-11-07: 4096 KIR
//! instructions after the expansions). The largest sm_120 kernel and the
//! slowest compile are reported. Each variant's tile kernel then runs on
//! the emulated RTX over one tile (its fragment code inside the raster's
//! scan and lists, as on the PC), the CTA's warps in each order, with
//! neutral inputs and with random ones (varyings, uniforms, every texture
//! slot bound to random texels: the branches real data takes): a fault, a
//! hazard or a divergence there names the variant and the seed.
//!
//! Firefox's sources are not part of zpm (they are Mozilla's, under the
//! MPL): set GFXAPI_WR_RES to a checkout's `gfx/wr/webrender/res`. Without
//! it the test is skipped.
//! For a different Firefox release, set GFXAPI_WR_VARIANTS to a manifest
//! from that release's get_shader_features, one shader:FEATURE,FEATURE
//! per line. The colon is required even when there are no features.
//! tests/webrender_variants_151.txt is Firefox 151's (Galaxy's), for a
//! GLES device with external textures, dithering and the debug shaders.
//! Its optimized shaders are not another set to check here: a Linux
//! Firefox carries them for desktop GL only (webrender's build.rs), so on
//! GLES it builds these either way.
//!
//! The same checks run over Xwayland's glamor (the second test): every
//! program glamor 24.1 builds on a GLES 3 context, from a directory
//! GFXAPI_GLAMOR_SHADERS names (tests/generate_glamor_shaders.py writes
//! it from Xwayland's source; X.Org's, MIT); skipped without it.
//!
//! The variants are webrender_build's `get_shader_features` for a GLES
//! device with external textures (ESSL 3 and 1), dithering, every path
//! antialiasing mode and the debug shaders: each is `#version 300 es`
//! (or 100 for ESSL 1's external textures), WebRender's defines
//! (WR_VERTEX_SHADER or WR_FRAGMENT_SHADER, WR_MAX_VERTEX_TEXTURE_WIDTH,
//! WR_FEATURE_*), then the shader's file with its `#include`s expanded
//! (each file once).

const std = @import("std");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const raster = gfxapi.raster;
const kir = gpu.kir;
const engine = gfxapi.engine;
const gles = gfxapi.gles;
const program = gfxapi.program;
const texture = gfxapi.texture;
const g = gfxapi.glenum;

const Variant = struct { name: []const u8, features: []const u8 };
var manifest_bytes: [16 * 1024]u8 = undefined;
var manifest_variants: [256]Variant = undefined;

fn selectedVariants(io: std.Io, allocator: std.mem.Allocator) ![]const Variant {
    const path = std.testing.environ.getAlloc(allocator, "GFXAPI_WR_VARIANTS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return &variants,
        else => return err,
    };
    const data = try std.Io.Dir.cwd().readFile(io, path, &manifest_bytes);
    if (data.len == manifest_bytes.len) return error.VariantManifestTooLong;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidVariant;
        const name = line[0..colon];
        if (name.len == 0 or count == manifest_variants.len) return error.InvalidVariant;
        for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidVariant;
        }
        manifest_variants[count] = .{ .name = name, .features = line[colon + 1 ..] };
        count += 1;
    }
    if (count == 0) return error.EmptyVariantManifest;
    return manifest_variants[0..count];
}

/// webrender_build's get_shader_features(GLES | TEXTURE_EXTERNAL |
/// TEXTURE_EXTERNAL_ESSL1 | DITHERING | PATH_AA_ALL_MODES | DEBUG).
const variants = [_]Variant{
    .{ .name = "cs_blur", .features = "ALPHA_TARGET" },
    .{ .name = "cs_blur", .features = "COLOR_TARGET" },
    .{ .name = "ps_quad_mask", .features = "" },
    .{ .name = "ps_quad_mask", .features = "FAST_PATH" },
    .{ .name = "ps_quad_mask", .features = "SUPERELLIPSE" },
    .{ .name = "cs_line_decoration", .features = "" },
    .{ .name = "cs_svg_filter_node", .features = "" },
    .{ .name = "cs_path_tile", .features = "PATH_SSAA4" },
    .{ .name = "cs_path_tile", .features = "PATH_SSAA8" },
    .{ .name = "cs_path_tile", .features = "" },
    .{ .name = "cs_border_segment", .features = "" },
    .{ .name = "cs_border_segment", .features = "SUPERELLIPSE" },
    .{ .name = "cs_border_solid", .features = "" },
    .{ .name = "cs_border_solid", .features = "SUPERELLIPSE" },
    .{ .name = "cs_scale", .features = "TEXTURE_2D" },
    .{ .name = "cs_scale", .features = "TEXTURE_EXTERNAL" },
    .{ .name = "cs_scale", .features = "TEXTURE_EXTERNAL_ESSL1" },
    .{ .name = "composite", .features = "TEXTURE_2D" },
    .{ .name = "composite", .features = "TEXTURE_EXTERNAL" },
    .{ .name = "composite", .features = "TEXTURE_EXTERNAL_ESSL1" },
    .{ .name = "composite", .features = "TEXTURE_2D,YUV" },
    .{ .name = "composite", .features = "TEXTURE_EXTERNAL,YUV" },
    .{ .name = "composite", .features = "FAST_PATH,TEXTURE_2D" },
    .{ .name = "composite", .features = "FAST_PATH,TEXTURE_2D,YUV" },
    .{ .name = "composite", .features = "FAST_PATH,TEXTURE_EXTERNAL" },
    .{ .name = "composite", .features = "FAST_PATH,TEXTURE_EXTERNAL,YUV" },
    .{ .name = "composite", .features = "FAST_PATH,TEXTURE_EXTERNAL_ESSL1" },
    .{ .name = "ps_text_run", .features = "ALPHA_PASS,TEXTURE_2D" },
    .{ .name = "ps_text_run", .features = "ALPHA_PASS,GLYPH_TRANSFORM,TEXTURE_2D" },
    .{ .name = "ps_text_run", .features = "DEBUG_OVERDRAW,TEXTURE_2D" },
    .{ .name = "ps_split_composite", .features = "" },
    .{ .name = "ps_quad_textured", .features = "TEXTURE_2D" },
    .{ .name = "ps_quad_textured", .features = "TEXTURE_EXTERNAL" },
    .{ .name = "ps_quad_repeat", .features = "" },
    .{ .name = "ps_quad_box_shadow", .features = "" },
    .{ .name = "ps_quad_box_shadow", .features = "SUPERELLIPSE" },
    .{ .name = "ps_quad_yuv", .features = "TEXTURE_2D" },
    .{ .name = "ps_quad_yuv", .features = "TEXTURE_EXTERNAL" },
    .{ .name = "ps_quad_backdrop", .features = "TEXTURE_2D" },
    .{ .name = "ps_quad_blend", .features = "TEXTURE_2D" },
    .{ .name = "ps_quad_mix_blend", .features = "TEXTURE_2D" },
    .{ .name = "ps_quad_gradient", .features = "DITHERING" },
    .{ .name = "ps_clear", .features = "" },
    .{ .name = "ps_copy", .features = "" },
    .{ .name = "debug_color", .features = "" },
    .{ .name = "debug_font", .features = "" },
};

const SRC_BYTES = 512 * 1024;
const FILE_BYTES = 256 * 1024;
const MAX_INCLUDED = 64;

/// A shader's source as WebRender builds it.
const Builder = struct {
    dir: std.Io.Dir,
    io: std.Io,
    out: []u8,
    n: usize = 0,
    included: [MAX_INCLUDED][64]u8 = undefined,
    included_len: [MAX_INCLUDED]usize = undefined,
    nincluded: usize = 0,
    file_bufs: [8][FILE_BYTES]u8 = undefined,
    depth: usize = 0,
    err: ?anyerror = null,

    fn put(b: *Builder, s: []const u8) void {
        if (b.n + s.len > b.out.len) {
            b.err = error.TooLong;
            return;
        }
        @memcpy(b.out[b.n..][0..s.len], s);
        b.n += s.len;
    }

    fn seen(b: *Builder, name: []const u8) bool {
        for (0..b.nincluded) |ix| {
            if (std.mem.eql(u8, b.included[ix][0..b.included_len[ix]], name)) return true;
        }
        if (b.nincluded == MAX_INCLUDED or name.len > 64) {
            b.err = error.TooManyIncludes;
            return true;
        }
        @memcpy(b.included[b.nincluded][0..name.len], name);
        b.included_len[b.nincluded] = name.len;
        b.nincluded += 1;
        return false;
    }

    /// The file `name`.glsl, its `#include`s expanded in place.
    fn file(b: *Builder, name: []const u8) void {
        if (b.depth == b.file_bufs.len) {
            b.err = error.TooDeep;
            return;
        }
        var path: [96]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}.glsl", .{name}) catch {
            b.err = error.TooLong;
            return;
        };
        const text = b.dir.readFile(b.io, p, &b.file_bufs[b.depth]) catch |e| {
            b.err = e;
            return;
        };
        b.depth += 1;
        defer b.depth -= 1;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (std.mem.startsWith(u8, line, "#include ")) {
                var names = std.mem.splitScalar(u8, line["#include ".len..], ',');
                while (names.next()) |inc| {
                    if (!b.seen(inc)) {
                        b.file(inc);
                    } else {
                        b.put("// ");
                        b.put(inc);
                        b.put(" is already included\n");
                    }
                }
            } else {
                b.put(line);
                b.put("\n");
            }
        }
    }
};

fn build(dir: std.Io.Dir, io: std.Io, v: Variant, vertex: bool, out: []u8, b: *Builder) ![:0]const u8 {
    b.* = .{ .dir = dir, .io = io, .out = out };
    const essl1 = std.mem.indexOf(u8, v.features, "TEXTURE_EXTERNAL_ESSL1") != null;
    b.put(if (essl1) "#version 100\n" else "#version 300 es\n");
    b.put("// shader: ");
    b.put(v.name);
    b.put(" ");
    b.put(v.features);
    b.put("\n");
    b.put(if (vertex) "#define WR_VERTEX_SHADER\n" else "#define WR_FRAGMENT_SHADER\n");
    b.put("#define WR_MAX_VERTEX_TEXTURE_WIDTH 1024U\n");
    if (v.features.len > 0) {
        var fs = std.mem.splitScalar(u8, v.features, ',');
        while (fs.next()) |f| {
            b.put("#define WR_FEATURE_");
            b.put(f);
            b.put("\n");
        }
    }
    _ = b.seen(v.name);
    b.file(v.name);
    b.put("\x00");
    if (b.err) |e| return e;
    return out[0 .. b.n - 1 :0];
}

var objs: gles.Objects = undefined;
var ctx: gles.Context = undefined;
var pool_mem: [8 << 20]u8 align(64) = undefined;
var cpu_work: [4 << 20]u8 align(64) = undefined;
var eng: engine.Engine = undefined;
var vs_buf: [SRC_BYTES]u8 = undefined;
var fs_buf: [SRC_BYTES]u8 = undefined;
var builder: Builder = undefined;
var log: [4096]u8 = undefined;
var k_insts: [engine.MAX_KIR]kir.Inst = undefined;
var k_tys: [engine.MAX_KIR]kir.Ty = undefined;
var code: [engine.PIPE_CODE]u8 align(16) = undefined;
var work_mem: [@max(gpu.kir_ir3.WORK_BYTES, gpu.nvidia_device.kir_sm120.WORK_BYTES)]u8 align(64) = undefined;

const Target = struct { name: []const u8, caps: gpu.Caps, required: bool };
const targets = [_]Target{
    .{ .name = "ir3", .caps = gpu.adreno_device.x1_45_caps(1 << 30), .required = true },
    .{ .name = "sm_120", .caps = gpu.nvidia_device.rtx5070(8 << 30), .required = true },
};

const Stage = enum { vertex, setup, raster };
var last_insts: usize = 0;

/// The largest sm_120 kernel (KIR instructions as built; machine
/// instructions) and the slowest sm_120 compile (ns), and which.
var max_kir: usize = 0;
var max_mi: u32 = 0;
/// Inside the backend: KIR after the expansions, machine instructions and
/// labels before the text, virtual registers (kir_sm120's MAX_INSTS,
/// MAX_MI, MAX_VREGS).
var max_xkir: u32 = 0;
var max_xmi: u32 = 0;
var max_vregs: u32 = 0;
var max_ns: i96 = 0;
var max_what: [96]u8 = undefined;
var max_what_len: usize = 0;

/// A pipeline's kernel built and compiled for `t`: its KIR instructions,
/// registers, code bytes and machine instructions (sm_120), and the
/// compile's time, or why not.
fn compileStage(pipe: *const raster.Pipeline, st: Stage, t: Target) !struct { insts: usize, regs: u32, bytes: usize, mi: u32, ns: i96 } {
    const storage = kir.Storage{ .insts = &k_insts, .tys = &k_tys };
    var k = switch (st) {
        .vertex => raster.vertexKernel(storage, pipe),
        .setup => raster.setupKernel(storage, pipe),
        .raster => raster.rasterKernel(storage, pipe),
    };
    try k.finish();
    last_insts = k.n;
    var w = gpu.Work.init(&work_mem);
    const t0 = std.Io.Clock.awake.now(std.testing.io);
    const bin = try gpu.compile(&k, t.caps, &w, &code);
    const ns = t0.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds;
    const sm = gpu.nvidia_device.kir_sm120;
    const mi: u32 = if (t.caps.target == .sm_120) bin.extra[sm.EXTRA_INSTRUCTIONS] else 0;
    if (t.caps.target == .sm_120) {
        max_xkir = @max(max_xkir, bin.extra[sm.EXTRA_KIR]);
        max_xmi = @max(max_xmi, bin.extra[sm.EXTRA_MI_VREGS] >> 16);
        max_vregs = @max(max_vregs, (bin.extra[sm.EXTRA_MI_VREGS] & 0xffff) * 2);
    }
    return .{ .insts = k.n, .regs = bin.regs, .bytes = bin.code.len, .mi = mi, .ns = ns };
}
var env_mem: [256 * 1024]u8 = undefined;

/// The emulated RTX (sm120_emu behind the PC's adapter), for running a
/// variant's tile kernel.
const Nv = struct {
    const nvidia = @import("nvidia");
    var arena: [32 << 20]u8 align(4096) = undefined;
    var view: [32 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
};

/// Triangle records for one 8x8 tile: TILE_TRIS of them, these live (the
/// others not valid, so the compaction skips them), each covering the
/// whole tile (zero edges), its depth 0, its 1/w 1, its varyings 0.
const TILE_TRIS = 66;
const LIVE = [_]u32{ 0, 40, 65 };

/// A variant's tile kernel (sm_120, the PC's caps) run on the emulated RTX
/// over one tile: the fragment code inside the raster's scan and lists, as
/// on the PC. Null when it ran clean; else the emulator's sentence.
/// A random word for a varying, a uniform or a texel: a small integer's
/// bits (a flat index, a count, a mode) or a float.
fn fuzzWord(r: std.Random, lo: f32, hi: f32) u32 {
    if (r.uintLessThan(u32, 10) < 4) return r.uintLessThan(u32, 48);
    return @bitCast(lo + (hi - lo) * r.float(f32));
}

const FUZZ_SIDE = 32;
var fuzz_imgs: [texture.MAX_TEX]engine.Image = undefined;

fn runTile(pipe: *const raster.Pipeline, uniforms: []const u32, nslots: usize, reverse: bool, why: []u8) !?[]const u8 {
    return runTileSeed(pipe, uniforms, nslots, reverse, 0, why);
}

/// `seed` 0: the triangles' varyings, the uniforms and the textures as
/// above (0, as linked, unbound). Else random: about half of the
/// triangles live, each varying a random plane, the uniforms random, and
/// every texture slot bound to a FUZZ_SIDE^2 image of random texels
/// (RGBA8, RGBA32F or RGBA32I by the seed), so the fragment code takes
/// the branches real data takes. A run past the emulator's step budget is
/// error.Timeout (a loop random data made long), not a fault.
fn runTileSeed(pipe: *const raster.Pipeline, uniforms: []const u32, nslots: usize, reverse: bool, seed: u64, why: []u8) !?[]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const fmt: engine.Format = switch (seed % 3) {
        0 => .rgba8,
        1 => .rgba32f,
        else => .rgba32i,
    };
    const storage = kir.Storage{ .insts = &k_insts, .tys = &k_tys };
    var k = raster.rasterKernel(storage, pipe);
    try k.finish();
    var w = gpu.Work.init(&work_mem);
    const bin = try gpu.compile(&k, targets[1].caps, &w, &code);
    Nv.dev.init(&Nv.arena, &Nv.view, &Nv.emu_work);
    Nv.emu_work.reverse_warps = reverse;
    const d = Nv.dev.device();
    const prog = try d.load(&bin);
    defer d.unload(&prog);
    var color = engine.Image{ .width = 8, .height = 8, .stride = 32, .format = .rgba8 };
    const draw = raster.Draw{ .pipe = pipe, .color = &color, .rect = .{ .x0 = 0, .y0 = 0, .x1 = 8, .y1 = 8 }, .count = 3 * TILE_TRIS };
    var rp: [raster.RASTER_PARAMS]u32 = undefined;
    const params = raster.rasterParams(&draw, .{}, &rp);
    // (color, depth, triangles, uniforms, the textures, an occlusion
    // query's word)
    var bufs: [5 + texture.MAX_TEX]gpu.Buffer = undefined;
    const ntex: usize = pipe.shaders.textures;
    const nb = 5 + ntex;
    for (bufs[0..nb], 0..) |*b, i| {
        const bytes: u64 = switch (i) {
            2 => TILE_TRIS * @as(u64, pipe.sstride) * 4,
            3 => (uniforms.len + nslots * texture.DESC_WORDS + 4) * 4,
            0, 1 => 256,
            else => if (i == nb - 1) 256 else if (seed != 0) FUZZ_SIDE * FUZZ_SIDE * @as(u64, fmt.bytes()) else 256,
        };
        b.* = try d.alloc(bytes, .host);
        @memset(b.cpu, 0);
    }
    defer for (bufs[0..nb]) |b| d.free(b);
    const recs: []u32 = @alignCast(std.mem.bytesAsSlice(u32, bufs[2].cpu));
    for (LIVE) |t| {
        const rec = recs[t * pipe.sstride ..][0..pipe.sstride];
        rec[0] = 1; // valid
        rec[1] = 0; // box: x0, y0, x1, y1 (inclusive)
        rec[2] = 0;
        rec[3] = 7;
        rec[4] = 7;
        rec[26] = @bitCast(@as(f32, 1)); // 1/w's plane: 1, flat
    }
    const uni: []u32 = @alignCast(std.mem.bytesAsSlice(u32, bufs[3].cpu));
    @memcpy(uni[0..uniforms.len], uniforms);
    if (seed != 0) {
        for (0..TILE_TRIS) |t| {
            const rec = recs[t * pipe.sstride ..][0..pipe.sstride];
            const live = r.boolean();
            rec[0] = @intFromBool(live);
            rec[1] = 0;
            rec[2] = 0;
            rec[3] = 7;
            rec[4] = 7;
            rec[26] = @bitCast(@as(f32, 1));
            // each varying a plane: its value at the tile's first pixel and
            // its slopes (0, or small)
            var at: usize = 29;
            while (at + 3 <= pipe.sstride) : (at += 3) {
                rec[at] = fuzzWord(r, -3, 3);
                rec[at + 1] = if (r.boolean()) 0 else @bitCast(r.float(f32) * 0.4 - 0.2);
                rec[at + 2] = if (r.boolean()) 0 else @bitCast(r.float(f32) * 0.4 - 0.2);
            }
        }
        for (uni[0..uniforms.len]) |*u| u.* = fuzzWord(r, -2, 2);
        const n = @min(ntex, nslots);
        for (0..n) |j| {
            const b = bufs[4 + j];
            const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, b.cpu));
            for (words) |*x| x.* = switch (fmt) {
                .rgba8 => r.int(u32),
                .rgba32f => fuzzWord(r, -1, 40),
                else => r.uintLessThan(u32, 64),
            };
            fuzz_imgs[j] = .{ .buf = b, .width = FUZZ_SIDE, .height = FUZZ_SIDE, .stride = FUZZ_SIDE * fmt.bytes(), .format = fmt };
            texture.descriptor(.{ .img = &fuzz_imgs[j] }, uni[uniforms.len + j * texture.DESC_WORDS ..][0..texture.DESC_WORDS]);
        }
    }
    for (bufs[0..nb]) |b| d.toDevice(b, 0, b.cpu.len);
    const fence = try d.run(&.{.{ .prog = &prog, .groups = .{ 1, 1, 1 }, .buffers = bufs[0..nb], .params = params }});
    d.wait(fence, 60_000_000) catch |e| {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(why, "{s}: {s}", .{ @errorName(e), Nv.dev.explain(&buf) }) catch "(too long)";
    };
    if (Nv.dev.lastError()) |e| {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(why, "{s}: {s}", .{ @errorName(e), Nv.dev.explain(&buf) }) catch "(too long)";
    }
    return null;
}

/// The first `lines` lines of a log.
fn head(s: []const u8, lines: usize) []const u8 {
    var n: usize = 0;
    for (s, 0..) |ch, ix| {
        if (ch == '\n') {
            n += 1;
            if (n == lines) return s[0..ix];
        }
    }
    return s;
}

/// What a set of programs came to (and on the 3D engine: drawn through
/// it, not eligible yet, a draw that went wrong there).
const Stats = struct { failed: usize = 0, ran_bad: usize = 0, ran_long: usize = 0, no_code: usize = 0, reported: usize = 0, drawn3d: usize = 0, not3d: usize = 0, bad3d: usize = 0, long3d: usize = 0, why3d: [8][]const u8 = @splat(""), why3d_n: [8]usize = @splat(0) };

// ── The emulated RTX's 3D engine (the PC's GL draws through BLACKWELL_B) ────

const Nv3 = struct {
    const nvidia = @import("nvidia");
    var engine3d: nvidia.emu3d.Engine = .{};
    var slabs: [16]engine.Slab = undefined;
    var eng: engine.Engine = undefined;
    var attr_bytes: [64 * 1024]u8 align(16) = undefined;
    var uni: [8192]u32 = undefined;
    var texels: [FUZZ_SIDE * FUZZ_SIDE * 4]u8 = undefined;
};

/// A variant's draw through the emulated RTX's 3D engine (its two stage
/// programs compiled from the pipeline's KIR, gl3d's state, emu3d): 6
/// vertices, 3 instances, every attribute a buffer of random floats, the
/// uniforms and the textures as runTileSeed has them for `seed`. Null
/// when it drew clean through the engine; else the sentence.
fn run3d(pipe: *raster.Pipeline, uniforms: []const u32, nslots: usize, seed: u64, why: []u8) !?[]const u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    Nv.dev.init(&Nv.arena, &Nv.view, &Nv.emu_work);
    Nv.dev.withEngine(&Nv3.engine3d);
    const e = &Nv3.eng;
    e.init(.{ .dev = Nv.dev.device(), .work = &work_mem, .cpu_work = &cpu_work, .slabs = &Nv3.slabs, .graphics = true });
    defer e.deinit();
    defer e.unloadPipeline(pipe);
    var color = e.newImage(64, 64, .rgba8) orelse return error.OutOfMemory;
    defer e.freeImage(&color);
    for (&Nv3.attr_bytes) |*b| b.* = 0;
    const fl: []f32 = @alignCast(std.mem.bytesAsSlice(f32, &Nv3.attr_bytes));
    for (fl) |*x| x.* = if (seed == 0) 0 else @bitCast(fuzzWord(r, -1.5, 1.5));
    var ab = e.newBuffer(Nv3.attr_bytes.len) orelse return error.OutOfMemory;
    defer e.freeImage(&ab);
    e.writeBytes(&ab, 0, &Nv3.attr_bytes);
    var tex: [texture.MAX_TEX]engine.Image = undefined;
    const ntex: usize = @min(pipe.shaders.textures, nslots);
    for (tex[0..ntex]) |*t| {
        t.* = e.newImage(FUZZ_SIDE, FUZZ_SIDE, .rgba8) orelse return error.OutOfMemory;
        for (&Nv3.texels) |*b| b.* = if (seed == 0) 0 else r.int(u8);
        e.write(t, 0, 0, FUZZ_SIDE, FUZZ_SIDE, &Nv3.texels, FUZZ_SIDE * 4, .rgba8);
    }
    defer for (tex[0..ntex]) |*t| e.freeImage(t);
    const nu = uniforms.len + nslots * texture.DESC_WORDS;
    if (nu > Nv3.uni.len) return error.OutOfMemory;
    @memcpy(Nv3.uni[0..uniforms.len], uniforms);
    @memset(Nv3.uni[uniforms.len..nu], 0);
    if (seed != 0) for (Nv3.uni[0..uniforms.len]) |*x| {
        x.* = fuzzWord(r, -2, 2);
    };
    for (0..ntex) |j| texture.descriptor(.{ .img = &tex[j] }, Nv3.uni[uniforms.len + j * texture.DESC_WORDS ..][0..texture.DESC_WORDS]);
    var d = raster.Draw{ .pipe = pipe, .color = &color, .rect = .{ .x0 = 0, .y0 = 0, .x1 = 64, .y1 = 64 }, .count = 6, .instances = 3, .center = .{ 32, 32 }, .half = .{ 32, 32 }, .uniforms = Nv3.uni[0..nu] };
    for (0..pipe.shaders.attrs) |a| d.attrs[a] = .{ .buf = &ab, .offset = @intCast(a * 64), .stride = 16, .comps = 4, .divisor = @intFromBool(a % 2 == 1) };
    for (0..ntex) |j| d.textures[j] = &tex[j];
    const before = e.stats.graphics_draws;
    if (!e.draw(&d)) return std.fmt.bufPrint(why, "the engine did not draw it", .{}) catch "?";
    e.finish();
    if (Nv.dev.lastError()) |le| {
        var buf: [256]u8 = undefined;
        return std.fmt.bufPrint(why, "{s}: {s}; the 3D engine: {s}", .{ @errorName(le), Nv.dev.explain(&buf), Nv3.engine3d.why }) catch "(too long)";
    }
    if (e.lost) return std.fmt.bufPrint(why, "the engine lost the GPU ({?s}); the 3D engine: {s}", .{ if (e.why) |w| @errorName(w) else null, Nv3.engine3d.why }) catch "?";
    if (e.stats.graphics_draws == before) return std.fmt.bufPrint(why, "drawn on the compute kernels ({?s})", .{if (e.why_pipe) |w| @errorName(w) else null}) catch "?";
    return null;
}

// ── ps_clear through GL, on the CPU and on the emulated 3D engine ──────────

const CW = 64;
const CH = 48;
var objs3: gles.Objects = undefined;
var ctx3: gles.Context = undefined;
var clear_cpu: [CW * CH * 4]u8 = undefined;
var clear_3d: [CW * CH * 4]u8 = undefined;

/// WebRender's ps_clear as WebRender draws it (an instance a rectangle: its
/// corners and color, aPosition the unit quad's six vertices; uTransform
/// an orthographic projection), into an RGBA8 framebuffer: four rectangles,
/// overlapping, at whole and half pixels. Its pixels into `out`.
fn clearDraw(c: *gles.Context, vs: [:0]const u8, fs: [:0]const u8, out: []u8) !void {
    const sv = program.createShader(c, g.VERTEX_SHADER);
    const sf = program.createShader(c, g.FRAGMENT_SHADER);
    defer program.deleteShader(c, sv);
    defer program.deleteShader(c, sf);
    for ([_]u32{ sv, sf }, [_][:0]const u8{ vs, fs }) |s, src| {
        const parts = [_]?[*]const u8{src.ptr};
        program.shaderSource(c, s, 1, &parts, null);
        program.compileShader(c, s);
    }
    const p = program.createProgram(c);
    defer program.deleteProgram(c, p);
    program.attachShader(c, p, sv);
    program.attachShader(c, p, sf);
    program.linkProgram(c, p);
    var ok: i32 = 0;
    program.getProgramiv(c, p, g.LINK_STATUS, &ok);
    if (ok != 1) return error.LinkFailed;
    program.useProgram(c, p);
    var tex: [1]u32 = undefined;
    c.genTextures(&tex);
    c.bindTexture(g.TEXTURE_2D, tex[0]);
    c.texStorage2D(g.TEXTURE_2D, 1, g.RGBA8, CW, CH);
    var fb: [1]u32 = undefined;
    c.genFramebuffers(&fb);
    c.bindFramebuffer(g.FRAMEBUFFER, fb[0]);
    c.framebufferTexture2D(g.FRAMEBUFFER, g.COLOR_ATTACHMENT0, g.TEXTURE_2D, tex[0], 0);
    if (c.checkFramebufferStatus(g.FRAMEBUFFER) != g.FRAMEBUFFER_COMPLETE) return error.Incomplete;
    c.viewportSet(0, 0, CW, CH);
    c.clearColor(0.1, 0.2, 0.3, 1);
    c.clear(g.COLOR_BUFFER_BIT);
    var bufs: [2]u32 = undefined;
    c.genBuffers(&bufs);
    const quad = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1 };
    // (x0, y0, x1, y1, r, g, b, a) an instance
    const inst = [_]f32{
        2,    3,    30,   20,   1,    0, 0, 1,
        20.5, 10.5, 50.5, 40.5, 0,    1, 0, 0.5,
        40,   0,    64,   48,   0,    0, 1, 1,
        0,    30,   16,   48,   0.25, 0.5, 0.75, 1,
    };
    const loc_pos = program.getAttribLocation(c, p, "aPosition");
    const loc_rect = program.getAttribLocation(c, p, "aRect");
    const loc_color = program.getAttribLocation(c, p, "aColor");
    if (loc_pos < 0 or loc_rect < 0 or loc_color < 0) return error.NoAttribute;
    c.bindBuffer(g.ARRAY_BUFFER, bufs[0]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), &quad, g.STATIC_DRAW);
    c.vertexAttribPointer(@intCast(loc_pos), 2, g.FLOAT, false, 8, 0, false);
    c.enableVertexAttribArray(@intCast(loc_pos), true);
    c.bindBuffer(g.ARRAY_BUFFER, bufs[1]);
    c.bufferData(g.ARRAY_BUFFER, @sizeOf(@TypeOf(inst)), &inst, g.STATIC_DRAW);
    c.vertexAttribPointer(@intCast(loc_rect), 4, g.FLOAT, false, 32, 0, false);
    c.vertexAttribPointer(@intCast(loc_color), 4, g.FLOAT, false, 32, 16, false);
    for ([_]i32{ loc_rect, loc_color }) |l| {
        c.enableVertexAttribArray(@intCast(l), true);
        c.vertexAttribDivisor(@intCast(l), 1);
    }
    const ortho = [16]f32{ 2.0 / @as(f32, CW), 0, 0, 0, 0, 2.0 / @as(f32, CH), 0, 0, 0, 0, -1, 0, -1, -1, 0, 1 };
    const loc_t = program.getUniformLocation(c, p, "uTransform");
    if (loc_t < 0) return error.NoUniform;
    program.uniformMatrix(c, loc_t, 1, false, 4, 4, @ptrCast(&ortho));
    c.drawArrays(g.TRIANGLES, 0, 6, 4);
    c.readPixels(0, 0, CW, CH, g.RGBA, g.UNSIGNED_BYTE, out.ptr);
    if (c.getError() != g.NO_ERROR) return error.GlError;
    c.finish();
}

/// ps_clear on the CPU and on the emulated RTX's 3D engine: the same
/// pixels within `tol`; how many differ.
fn clearCompare(dir: std.Io.Dir, io: std.Io) !void {
    var v: ?Variant = null;
    for (variants) |x| {
        if (std.mem.eql(u8, x.name, "ps_clear")) v = x;
    }
    const pc = v orelse return error.NoPsClear;
    const vs = try build(dir, io, pc, true, &vs_buf, &builder);
    const fs = try build(dir, io, pc, false, &fs_buf, &builder);
    try clearDraw(&ctx, vs, fs, &clear_cpu);
    Nv.dev.init(&Nv.arena, &Nv.view, &Nv.emu_work);
    Nv.dev.withEngine(&Nv3.engine3d);
    const e = &Nv3.eng;
    e.init(.{ .dev = Nv.dev.device(), .work = &work_mem, .cpu_work = &cpu_work, .slabs = &Nv3.slabs, .graphics = true });
    defer e.deinit();
    objs3.init();
    ctx3.init(e, &objs3);
    defer ctx3.deinit();
    try clearDraw(&ctx3, vs, fs, &clear_3d);
    var bad: u32 = 0;
    var most: u8 = 0;
    var i: usize = 0;
    while (i < clear_cpu.len) : (i += 1) {
        const d = if (clear_cpu[i] > clear_3d[i]) clear_cpu[i] - clear_3d[i] else clear_3d[i] - clear_cpu[i];
        most = @max(most, d);
        if (d > 2) {
            if (bad < 4) std.debug.print("ps_clear: byte {d} (pixel {d}, {d}): the CPU {d}, the 3D engine {d}\n", .{ i, (i / 4) % CW, (i / 4) / CW, clear_cpu[i], clear_3d[i] });
            bad += 1;
        }
    }
    std.debug.print("webrender ps_clear: {d} draw(s) through the emulated 3D engine ({d} on the compute kernels), {d} bytes more than 2 from the CPU's (the most {d}); the emulated engine shaded {d} pixels\n", .{ e.stats.graphics_draws, e.stats.compute_draws, bad, most, Nv3.engine3d.pixels });
    try std.testing.expect(e.stats.graphics_draws >= 1);
    try std.testing.expectEqual(@as(u32, 0), bad);
}

fn note3d(stats: *Stats, why: []const u8) void {
    for (&stats.why3d, &stats.why3d_n) |*w, *n| {
        if (w.len == 0) w.* = why;
        if (w.ptr == why.ptr) {
            n.* += 1;
            return;
        }
    }
}

/// One program (`vs` and `fs`, named `name` [`features`]): compiled and
/// linked through GL's objects, its draw kernels built and compiled for
/// each GPU, its tile kernel run on the emulated RTX (neutral and random
/// inputs, the warps in each order); what went wrong counted in `stats`.
fn checkProgram(c: *gles.Context, name: []const u8, features: []const u8, vs: [:0]const u8, fs: [:0]const u8, stats: *Stats) !void {
    const sv = program.createShader(c, g.VERTEX_SHADER);
    const sf = program.createShader(c, g.FRAGMENT_SHADER);
    defer program.deleteShader(c, sv);
    defer program.deleteShader(c, sf);
    var why: []const u8 = "";
    var what: []const u8 = "link";
    for ([_]u32{ sv, sf }, [_][:0]const u8{ vs, fs }, [_][]const u8{ "vertex", "fragment" }) |s, src, stage| {
        const parts = [_]?[*]const u8{src.ptr};
        program.shaderSource(c, s, 1, &parts, null);
        program.compileShader(c, s);
        var ok: i32 = 0;
        program.getShaderiv(c, s, g.COMPILE_STATUS, &ok);
        if (ok != 1 and why.len == 0) {
            var len: i32 = 0;
            program.getShaderInfoLog(c, s, log.len, &len, &log);
            why = log[0..@intCast(len)];
            what = stage;
        }
    }
    const p = program.createProgram(c);
    defer program.deleteProgram(c, p);
    if (why.len == 0) {
        program.attachShader(c, p, sv);
        program.attachShader(c, p, sf);
        program.linkProgram(c, p);
        var ok: i32 = 0;
        program.getProgramiv(c, p, g.LINK_STATUS, &ok);
        if (ok != 1) {
            var len: i32 = 0;
            program.getProgramInfoLog(c, p, log.len, &len, &log);
            why = log[0..@intCast(len)];
            if (why.len == 0) why = "(no log)";
        }
    }
    if (why.len > 0) {
        stats.failed += 1;
        std.debug.print("FAIL {s} [{s}] {s}: {s}\n", .{ name, features, what, head(why, 3) });
        _ = c.getError();
        return;
    }
    // the draw kernels, for each GPU
    program.useProgram(c, p);
    const ds = program.drawState(c) orelse return error.NoPipeline;
    std.debug.print("ok   {s} [{s}]", .{ name, features });
    for (targets) |t| {
        for ([_]Stage{ .vertex, .setup, .raster }) |st| {
            const r = compileStage(ds.pipe, st, t) catch |e| {
                if (t.required) stats.no_code += 1 else stats.reported += 1;
                std.debug.print(" {s} {s}: {s} ({d} KIR)", .{ t.name, @tagName(st), @errorName(e), last_insts });
                continue;
            };
            if (st == .raster) std.debug.print(" | {s} raster {d} KIR, {d} regs, {d} B", .{ t.name, r.insts, r.regs, r.bytes });
            if (t.caps.target == .sm_120) {
                if (st == .vertex) std.debug.print(" | sm_120 vertex {d} KIR, {d} instrs, {d} regs, {d} us", .{ r.insts, r.mi, r.regs, @divTrunc(r.ns, 1000) });
                if (r.insts > max_kir) max_kir = r.insts;
                if (r.mi > max_mi) max_mi = r.mi;
                if (r.ns > max_ns) {
                    max_ns = r.ns;
                    const named = std.fmt.bufPrint(&max_what, "{s} [{s}] {s}", .{ name, features, @tagName(st) }) catch "";
                    max_what_len = named.len;
                }
            }
        }
    }
    std.debug.print("\n", .{});
    // through the emulated RTX's 3D engine, where the pipeline is one it
    // takes: neutral inputs and random ones
    if (raster.pipelineWhyNot(ds.pipe.shaders)) |w| {
        stats.not3d += 1;
        note3d(stats, w);
    } else {
        var drew = true;
        for ([_]u64{ 0, 1, 2 }) |seed| {
            var why3: [512]u8 = undefined;
            const bad = run3d(@constCast(ds.pipe), ds.uniforms, ds.slots.len, seed, &why3) catch |e| blk: {
                break :blk std.fmt.bufPrint(&why3, "{s}", .{@errorName(e)}) catch "?";
            };
            if (bad) |s| {
                if (std.mem.startsWith(u8, s, "Timeout")) {
                    stats.long3d += 1;
                    continue;
                }
                drew = false;
                stats.bad3d += 1;
                std.debug.print("3D   {s} [{s}] on the emulated 3D engine, seed {d}: {s}\n", .{ name, features, seed, s });
            }
        }
        if (drew) stats.drawn3d += 1;
    }
    // the tile kernel on the emulated RTX, the warps in each order,
    // with neutral inputs (seed 0) and random ones
    for ([_]u64{ 0, 1, 2, 3 }) |seed| {
        for ([_]bool{ false, true }) |reverse| {
            var why_run: [512]u8 = undefined;
            const bad = runTileSeed(ds.pipe, ds.uniforms, ds.slots.len, reverse, seed, &why_run) catch |e| blk: {
                break :blk std.fmt.bufPrint(&why_run, "{s}", .{@errorName(e)}) catch "?";
            };
            if (bad) |s| {
                if (std.mem.startsWith(u8, s, "Timeout")) {
                    stats.ran_long += 1;
                    continue;
                }
                stats.ran_bad += 1;
                std.debug.print("RUN  {s} [{s}] tile on the emulated RTX, seed {d}{s}: {s}\n", .{ name, features, seed, if (reverse) " (warps reversed)" else "", s });
            }
        }
    }
    program.useProgram(c, 0);
    _ = c.getError();
}

test "webrender: every shader variant compiles and links" {
    const io = std.testing.io;
    var fba = std.heap.FixedBufferAllocator.init(&env_mem);
    const res = std.testing.environ.getAlloc(fba.allocator(), "GFXAPI_WR_RES") catch |e| {
        std.debug.print("webrender: GFXAPI_WR_RES: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    var dir = std.Io.Dir.cwd().openDir(io, res, .{}) catch |e| {
        std.debug.print("webrender: {s}: {s}\n", .{ res, @errorName(e) });
        return error.SkipZigTest;
    };
    defer dir.close(io);
    eng.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
    defer eng.deinit();
    objs.init();
    const c = &ctx;
    c.init(&eng, &objs);
    defer c.deinit();
    var st = Stats{};
    const selected = try selectedVariants(io, fba.allocator());
    for (selected) |v| {
        const vs = try build(dir, io, v, true, &vs_buf, &builder);
        const fs = try build(dir, io, v, false, &fs_buf, &builder);
        try checkProgram(c, v.name, v.features, vs, fs, &st);
    }
    std.debug.print("webrender: {d} of {d} variants link; {d} kernels do not compile ({d} not required)\n", .{ selected.len - st.failed, selected.len, st.no_code, st.reported });
    std.debug.print("webrender on sm_120: the largest kernel {d} KIR, {d} machine instructions; the slowest compile {d} us ({s}); inside the backend at most {d} KIR expanded, {d} MI, {d} vregs\n", .{ max_kir, max_mi, @divTrunc(max_ns, 1000), max_what[0..max_what_len], max_xkir, max_xmi, max_vregs });
    std.debug.print("webrender: {d} tile kernel runs on the emulated RTX went wrong, {d} ran past the step budget\n", .{ st.ran_bad, st.ran_long });
    try clearCompare(dir, io);
    std.debug.print("webrender on the 3D engine: {d} variants drew through the emulated engine, {d} went wrong there ({d} runs past the step budget), {d} not taken yet:", .{ st.drawn3d, st.bad3d, st.long3d, st.not3d });
    for (st.why3d, st.why3d_n) |w, n| if (w.len != 0) std.debug.print(" {s} {d};", .{ w, n });
    std.debug.print("\n", .{});
    try std.testing.expectEqual(@as(usize, 0), st.bad3d);
    try std.testing.expectEqual(@as(usize, 0), st.failed);
    try std.testing.expectEqual(@as(usize, 0), st.no_code);
    try std.testing.expectEqual(@as(usize, 0), st.ran_bad);
}

// ── Prebuilt program sets (Xwayland's glamor) ─────────────────────────────
//
// GFXAPI_GLAMOR_SHADERS: a directory of programs as glamor builds them on a
// GLES 3 context (tests/generate_glamor_shaders.py makes it from Xwayland's
// source): LIST names one per line (`name ...`; `#` lines are notes), each
// as name.vert and name.frag. Every one goes through checkProgram, as
// WebRender's variants do. Without it the test is skipped.

var list_buf: [64 * 1024]u8 = undefined;

test "glamor: every program Xwayland's glamor builds on GLES compiles, links and runs" {
    const io = std.testing.io;
    var fba = std.heap.FixedBufferAllocator.init(&env_mem);
    const where = std.testing.environ.getAlloc(fba.allocator(), "GFXAPI_GLAMOR_SHADERS") catch |e| {
        std.debug.print("glamor: GFXAPI_GLAMOR_SHADERS: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    var dir = std.Io.Dir.cwd().openDir(io, where, .{}) catch |e| {
        std.debug.print("glamor: {s}: {s}\n", .{ where, @errorName(e) });
        return error.SkipZigTest;
    };
    defer dir.close(io);
    const list = try dir.readFile(io, "LIST", &list_buf);
    if (list.len == list_buf.len) return error.ListTooLong;
    eng.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
    defer eng.deinit();
    objs.init();
    const c = &ctx;
    c.init(&eng, &objs);
    defer c.deinit();
    var st = Stats{};
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const name = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
        var path: [160]u8 = undefined;
        const vs_bytes = try dir.readFile(io, try std.fmt.bufPrint(&path, "{s}.vert", .{name}), vs_buf[0 .. vs_buf.len - 1]);
        vs_buf[vs_bytes.len] = 0;
        const fs_bytes = try dir.readFile(io, try std.fmt.bufPrint(&path, "{s}.frag", .{name}), fs_buf[0 .. fs_buf.len - 1]);
        fs_buf[fs_bytes.len] = 0;
        try checkProgram(c, name, "glamor", vs_buf[0..vs_bytes.len :0], fs_buf[0..fs_bytes.len :0], &st);
        n += 1;
    }
    std.debug.print("glamor: {d} of {d} programs link; {d} kernels do not compile ({d} not required); {d} tile runs went wrong, {d} ran past the step budget\n", .{ n - st.failed, n, st.no_code, st.reported, st.ran_bad, st.ran_long });
    try std.testing.expect(n > 0);
    try std.testing.expectEqual(@as(usize, 0), st.failed);
    try std.testing.expectEqual(@as(usize, 0), st.no_code);
    try std.testing.expectEqual(@as(usize, 0), st.ran_bad);
}
