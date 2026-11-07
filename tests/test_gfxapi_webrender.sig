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
//! slowest compile are reported.
//!
//! Firefox's sources are not part of zpm (they are Mozilla's, under the
//! MPL): set GFXAPI_WR_RES to a checkout's `gfx/wr/webrender/res`. Without
//! it the test is skipped.
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
const g = gfxapi.glenum;

const Variant = struct { name: []const u8, features: []const u8 };

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
    var failed: usize = 0;
    var no_code: usize = 0;
    var reported: usize = 0;
    for (variants) |v| {
        const vs = try build(dir, io, v, true, &vs_buf, &builder);
        const fs = try build(dir, io, v, false, &fs_buf, &builder);
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
            failed += 1;
            std.debug.print("FAIL {s} [{s}] {s}: {s}\n", .{ v.name, v.features, what, head(why, 3) });
            _ = c.getError();
            continue;
        }
        // the draw kernels, for each GPU
        program.useProgram(c, p);
        const ds = program.drawState(c) orelse return error.NoPipeline;
        std.debug.print("ok   {s} [{s}]", .{ v.name, v.features });
        for (targets) |t| {
            for ([_]Stage{ .vertex, .setup, .raster }) |st| {
                const r = compileStage(ds.pipe, st, t) catch |e| {
                    if (t.required) no_code += 1 else reported += 1;
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
                        const named = std.fmt.bufPrint(&max_what, "{s} [{s}] {s}", .{ v.name, v.features, @tagName(st) }) catch "";
                        max_what_len = named.len;
                    }
                }
            }
        }
        std.debug.print("\n", .{});
        program.useProgram(c, 0);
        _ = c.getError();
    }
    std.debug.print("webrender: {d} of {d} variants link; {d} kernels do not compile ({d} not required)\n", .{ variants.len - failed, variants.len, no_code, reported });
    std.debug.print("webrender on sm_120: the largest kernel {d} KIR, {d} machine instructions; the slowest compile {d} us ({s}); inside the backend at most {d} KIR expanded, {d} MI, {d} vregs\n", .{ max_kir, max_mi, @divTrunc(max_ns, 1000), max_what[0..max_what_len], max_xkir, max_xmi, max_vregs });
    try std.testing.expectEqual(@as(usize, 0), failed);
    try std.testing.expectEqual(@as(usize, 0), no_code);
}
