//! The HLSL compiler against Microsoft's (the test oracle): every shader of
//! tests/hlsl (ANGLE-shaped HLSL, as ANGLE's translator writes WebGL's
//! shaders) compiled by both, for Shader Model 4 and 5, and compared:
//!
//! - **signatures**: every input and output element (name, index, system
//!   value, type, register, mask, used components), exactly;
//! - **reflection**: constant buffers (names, sizes, every variable's
//!   offset, size, type and whether it is used) and resource bindings,
//!   exactly;
//! - **behaviour**: both programs drawn by zpm's DXBC front end
//!   (gfxapi/dxbc) on the CPU engine with the same inputs (vertices,
//!   constant buffers, a texture), every pixel compared (rgba8, two steps of
//!   tolerance for fxc's own approximations). Bytes need not match.
//!
//! Microsoft's compiler is Windows' own d3dcompiler_47.dll, loaded at run
//! time: elsewhere this test is skipped. It is never part of anything zpm
//! or Galaxy ships.

const std = @import("std");
const builtin = @import("builtin");
const hlsl = @import("hlsl");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const raster = gfxapi.raster;
const texture = gfxapi.texture;
const dxbc = gfxapi.dxbc;
const dgen = gfxapi.dxbc_gen;
const ct = hlsl.container;
const warp = @import("hlsl_warp.sig");

const Case = struct { name: []const u8, src: []const u8 };

const corpus = [_]Case{
    .{ .name = "vs_basic", .src = @embedFile("hlsl/vs_basic.hlsl") },
    .{ .name = "ps_texture", .src = @embedFile("hlsl/ps_texture.hlsl") },
    .{ .name = "ps_color", .src = @embedFile("hlsl/ps_color.hlsl") },
    .{ .name = "vs_lighting", .src = @embedFile("hlsl/vs_lighting.hlsl") },
    .{ .name = "ps_lighting", .src = @embedFile("hlsl/ps_lighting.hlsl") },
    .{ .name = "ps_loop", .src = @embedFile("hlsl/ps_loop.hlsl") },
    .{ .name = "ps_mod", .src = @embedFile("hlsl/ps_mod.hlsl") },
    .{ .name = "ps_trig", .src = @embedFile("hlsl/ps_trig.hlsl") },
    .{ .name = "vs_skinning", .src = @embedFile("hlsl/vs_skinning.hlsl") },
    .{ .name = "ps_struct_uniform", .src = @embedFile("hlsl/ps_struct_uniform.hlsl") },
    .{ .name = "ps_int_ops", .src = @embedFile("hlsl/ps_int_ops.hlsl") },
    .{ .name = "ps_switch", .src = @embedFile("hlsl/ps_switch.hlsl") },
    .{ .name = "ps_early_return", .src = @embedFile("hlsl/ps_early_return.hlsl") },
    .{ .name = "ps_fragcoord", .src = @embedFile("hlsl/ps_fragcoord.hlsl") },
    .{ .name = "vs_point_size", .src = @embedFile("hlsl/vs_point_size.hlsl") },
    .{ .name = "ps_mrt", .src = @embedFile("hlsl/ps_mrt.hlsl") },
    .{ .name = "ps_frontfacing", .src = @embedFile("hlsl/ps_frontfacing.hlsl") },
    .{ .name = "ps_bvec", .src = @embedFile("hlsl/ps_bvec.hlsl") },
    .{ .name = "ps_matrix", .src = @embedFile("hlsl/ps_matrix.hlsl") },
    .{ .name = "vs_instancing", .src = @embedFile("hlsl/vs_instancing.hlsl") },
    .{ .name = "ps_texture_lod", .src = @embedFile("hlsl/ps_texture_lod.hlsl") },
    .{ .name = "ps_cube", .src = @embedFile("hlsl/ps_cube.hlsl") },
    .{ .name = "ps_shadow", .src = @embedFile("hlsl/ps_shadow.hlsl") },
    .{ .name = "ps_array_local", .src = @embedFile("hlsl/ps_array_local.hlsl") },
    .{ .name = "ps_uniform_block", .src = @embedFile("hlsl/ps_uniform_block.hlsl") },
    .{ .name = "ps_inout", .src = @embedFile("hlsl/ps_inout.hlsl") },
    .{ .name = "ps_derivatives", .src = @embedFile("hlsl/ps_derivatives.hlsl") },
    .{ .name = "ps_casts", .src = @embedFile("hlsl/ps_casts.hlsl") },
    .{ .name = "ps_preprocessor", .src = @embedFile("hlsl/ps_preprocessor.hlsl") },
    .{ .name = "ps_blend_modes", .src = @embedFile("hlsl/ps_blend_modes.hlsl") },
    .{ .name = "gs_point_sprite", .src = @embedFile("hlsl/gs_point_sprite.hlsl") },
    .{ .name = "ps_texture_array", .src = @embedFile("hlsl/ps_texture_array.hlsl") },
    .{ .name = "vs_webgl2", .src = @embedFile("hlsl/vs_webgl2.hlsl") },
    .{ .name = "ps_while_do", .src = @embedFile("hlsl/ps_while_do.hlsl") },
};

// ── Microsoft's compiler (Windows only) ────────────────────────────────────

const Blob = extern struct {
    vt: *const extern struct {
        qi: *const anyopaque,
        addref: *const anyopaque,
        release: *const fn (*Blob) callconv(.winapi) u32,
        ptr: *const fn (*Blob) callconv(.winapi) [*]u8,
        size: *const fn (*Blob) callconv(.winapi) usize,
    },
};

const D3DCompileFn = *const fn (src: [*]const u8, len: usize, name: ?[*:0]const u8, defines: ?*const anyopaque, include: ?*const anyopaque, entry: [*:0]const u8, target: [*:0]const u8, f1: u32, f2: u32, code: *?*Blob, errs: *?*Blob) callconv(.winapi) i32;

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(m: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
} else struct {};

var ms_compile: ?D3DCompileFn = null;

// ── real Direct3D 11 (Windows' runtime and a driver): what it accepts ─────

const D3D11CreateDeviceFn = *const fn (adapter: ?*anyopaque, driver: u32, software: ?*anyopaque, flags: u32, levels: ?[*]const u32, nlevels: u32, sdk: u32, dev: *?*anyopaque, level: ?*u32, ctx: ?*?*anyopaque) callconv(.winapi) i32;
const CreateShaderFn = *const fn (dev: *anyopaque, code: [*]const u8, len: usize, linkage: ?*anyopaque, out: *?*anyopaque) callconv(.winapi) i32;
const ReleaseFn = *const fn (obj: *anyopaque) callconv(.winapi) u32;

/// Devices: a hardware one (its driver compiles the DXBC) and WARP.
var d3d_devs: [2]?*anyopaque = .{ null, null };
var d3d_tried = false;
var checksum_refused = false;
var listing: [256 * 1024]u8 = undefined;

fn d3dDevices() void {
    if (builtin.os.tag != .windows or d3d_tried) return;
    d3d_tried = true;
    const m = win.LoadLibraryA("d3d11.dll") orelse return;
    const create: D3D11CreateDeviceFn = @ptrCast(win.GetProcAddress(m, "D3D11CreateDevice") orelse return);
    const levels = [_]u32{0xb000};
    // (D3D_DRIVER_TYPE_HARDWARE 1, WARP 5)
    for ([_]u32{ 1, 5 }, 0..) |driver, k| {
        var dev: ?*anyopaque = null;
        if (create(null, driver, null, 0, &levels, 1, 7, &dev, null, null) >= 0) d3d_devs[k] = dev;
    }
}

fn vtFn(obj: *anyopaque, index: usize) *const anyopaque {
    const vt: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return vt.*[index];
}

/// Whether every device takes the blob as a shader of its stage
/// (ID3D11Device::CreateVertexShader 12, CreateGeometryShader 13,
/// CreatePixelShader 15).
fn d3dAccepts(blob: []const u8, stage: dxbc.Stage, name: []const u8) bool {
    var ok = true;
    for (d3d_devs, 0..) |d, k| {
        const dev = d orelse continue;
        const slot: usize = switch (stage) {
            .vertex => 12,
            .geometry => 13,
            else => 15,
        };
        const f: CreateShaderFn = @ptrCast(vtFn(dev, slot));
        var sh: ?*anyopaque = null;
        const hres = f(dev, blob.ptr, blob.len, null, &sh);
        if (hres < 0) {
            std.debug.print("  {s}: Direct3D 11 ({s}) refused our shader: 0x{x}\n", .{ name, if (k == 0) "hardware" else "WARP", @as(u32, @bitCast(hres)) });
            ok = false;
        } else if (sh) |s| {
            const rel: ReleaseFn = @ptrCast(vtFn(s, 2));
            _ = rel(s);
        }
    }
    return ok;
}

fn loadMs() bool {
    if (builtin.os.tag != .windows) return false;
    if (ms_compile != null) return true;
    const m = win.LoadLibraryA("d3dcompiler_47.dll") orelse return false;
    ms_compile = @ptrCast(win.GetProcAddress(m, "D3DCompile") orelse return false);
    return true;
}

var ms_out: [1 << 20]u8 = undefined;
var ms_err: [16 * 1024]u8 = undefined;

/// Microsoft's blob (a copy in `out`), or null with its messages printed.
fn msCompile(src: []const u8, target: []const u8, out: []u8) ?[]u8 {
    var code: ?*Blob = null;
    var errs: ?*Blob = null;
    var tz: [16]u8 = undefined;
    @memcpy(tz[0..target.len], target);
    tz[target.len] = 0;
    const hr = ms_compile.?(src.ptr, src.len, "corpus.hlsl", null, null, "main", @ptrCast(&tz), 0, 0, &code, &errs);
    if (errs) |e| {
        const t = e.vt.ptr(e)[0..e.vt.size(e)];
        const n = @min(t.len, ms_err.len);
        @memcpy(ms_err[0..n], t[0..n]);
        _ = e.vt.release(e);
        if (hr < 0) std.debug.print("  (Microsoft's compiler refused it: {s})\n", .{ms_err[0..n]});
    }
    if (hr < 0) return null;
    const c = code.?;
    const b = c.vt.ptr(c)[0..c.vt.size(c)];
    @memcpy(out[0..b.len], b);
    _ = c.vt.release(c);
    return out[0..b.len];
}

// ── the comparisons ────────────────────────────────────────────────────────

const Tally = struct {
    cases: u32 = 0,
    ms_refused: u32 = 0,
    ours_failed: u32 = 0,
    sig_same: u32 = 0,
    sig_diff: u32 = 0,
    refl_same: u32 = 0,
    refl_diff: u32 = 0,
    draw_same: u32 = 0,
    draw_diff: u32 = 0,
    /// the front end could not run Microsoft's program (nothing to compare)
    draw_skipped: u32 = 0,
    /// the front end ran Microsoft's program but not ours
    draw_ours_refused: u32 = 0,
    pixels: u64 = 0,
    /// both programs drawn by Direct3D 11 on WARP: the same pixels or not
    warp_same: u32 = 0,
    warp_diff: u32 = 0,
    warp_failed: u32 = 0,
    warp_pixels: u64 = 0,
    /// Direct3D 11's runtime and drivers took our blob (or refused it)
    d3d_accepted: u32 = 0,
    d3d_refused: u32 = 0,
};

var tally = Tally{};
var compiler: hlsl.Compiler = undefined;

fn sigSame(name: []const u8, which: []const u8, a: ?dxbc.Signature, b: ?dxbc.Signature) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.count != y.count) {
        std.debug.print("  {s}: {s} has {d} elements, Microsoft's {d}\n", .{ name, which, y.count, x.count });
        return false;
    }
    var ok = true;
    for (0..x.count) |k| {
        const e = x.get(@intCast(k)).?;
        const f = y.get(@intCast(k)).?;
        if (!std.ascii.eqlIgnoreCase(e.name, f.name) or e.index != f.index or e.sys != f.sys or e.comp != f.comp or e.register != f.register or e.mask != f.mask or e.rw_mask != f.rw_mask) {
            std.debug.print("  {s}: {s}[{d}]: ours {s}{d} sys {d} type {d} r{d} mask {x} rw {x}; Microsoft's {s}{d} sys {d} type {d} r{d} mask {x} rw {x}\n", .{ name, which, k, f.name, f.index, @intFromEnum(f.sys), @intFromEnum(f.comp), f.register, f.mask, f.rw_mask, e.name, e.index, @intFromEnum(e.sys), @intFromEnum(e.comp), e.register, e.mask, e.rw_mask });
            ok = false;
        }
    }
    return ok;
}

var refl_ms: ct.Reflection = undefined;
var refl_ours: ct.Reflection = undefined;

fn reflSame(name: []const u8, ms: []const u8, ours: []const u8) bool {
    const a = &refl_ms;
    const b = &refl_ours;
    if (!a.read(ct.findChunk(ms, "RDEF") orelse return false)) return false;
    if (!b.read(ct.findChunk(ours, "RDEF") orelse return false)) {
        std.debug.print("  {s}: our RDEF does not read back\n", .{name});
        return false;
    }
    var ok = true;
    if (a.nbinds != b.nbinds) {
        std.debug.print("  {s}: {d} bindings, Microsoft's {d}\n", .{ name, b.nbinds, a.nbinds });
        for (a.binds[0..a.nbinds]) |x| std.debug.print("    ms: {s} type {d} bind {d}\n", .{ x.name, x.type, x.bind });
        for (b.binds[0..b.nbinds]) |x| std.debug.print("    ours: {s} type {d} bind {d}\n", .{ x.name, x.type, x.bind });
        ok = false;
    } else for (a.binds[0..a.nbinds], b.binds[0..b.nbinds]) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or x.type != y.type or x.ret != y.ret or x.dim != y.dim or x.samples != y.samples or x.bind != y.bind or x.count != y.count or x.flags != y.flags) {
            std.debug.print("  {s}: binding ours {s} t{d} r{d} d{d} s{x} b{d} n{d} f{x}; Microsoft's {s} t{d} r{d} d{d} s{x} b{d} n{d} f{x}\n", .{ name, y.name, y.type, y.ret, y.dim, y.samples, y.bind, y.count, y.flags, x.name, x.type, x.ret, x.dim, x.samples, x.bind, x.count, x.flags });
            ok = false;
        }
    }
    if (a.nbufs != b.nbufs) {
        std.debug.print("  {s}: {d} constant buffers, Microsoft's {d}\n", .{ name, b.nbufs, a.nbufs });
        return false;
    }
    for (a.bufs[0..a.nbufs], b.bufs[0..b.nbufs]) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or x.size != y.size or x.nvars != y.nvars or x.kind != y.kind) {
            std.debug.print("  {s}: cbuffer ours {s} {d} bytes {d} vars; Microsoft's {s} {d} bytes {d} vars\n", .{ name, y.name, y.size, y.nvars, x.name, x.size, x.nvars });
            ok = false;
            continue;
        }
        for (0..x.nvars) |k| {
            const u = a.vars[x.first + k];
            const v = b.vars[y.first + k];
            if (!std.mem.eql(u8, u.name, v.name) or u.offset != v.offset or u.size != v.size or (u.flags & 2) != (v.flags & 2) or !ct.Reflection.sameType(a, u.ty, b, v.ty)) {
                const tu = a.types[u.ty];
                const tv = b.types[v.ty];
                std.debug.print("  {s}: {s}.{s}: ours @{d} {d}B f{x} c{d}t{d} {d}x{d}[{d}]m{d}; Microsoft's @{d} {d}B f{x} c{d}t{d} {d}x{d}[{d}]m{d}\n", .{ name, x.name, u.name, v.offset, v.size, v.flags, tv.class, tv.type, tv.rows, tv.cols, tv.elements, tv.nmembers, u.offset, u.size, u.flags, tu.class, tu.type, tu.rows, tu.cols, tu.elements, tu.nmembers });
                ok = false;
            }
        }
    }
    return ok;
}

// ── drawing ────────────────────────────────────────────────────────────────

const W = 16;
const H = 16;

var pool_mem: [16 << 20]u8 align(64) = undefined;
var cpu_work: [8 << 20]u8 align(64) = undefined;
var eng: engine.Engine = undefined;
var eng_ready = false;

fn engineCpu() *engine.Engine {
    if (!eng_ready) {
        eng.init(.{ .pool = &pool_mem, .cpu_work = &cpu_work });
        eng_ready = true;
    }
    return &eng;
}

/// One stage's layout: its constant buffers' words and texture slots in
/// the shared uniforms, its varyings by semantic.
const Lay = struct {
    cb_word: [16]u32 = [_]u32{0} ** 16,
    cb_vecs: [16]u32 = [_]u32{0} ** 16,
    /// varyings: (name, index) per word block of 4
    names: [32][]const u8 = undefined,
    idx: [32]u32 = undefined,
    base: [32]u32 = undefined,
    nvary: u32 = 0,
    /// varying words in all (each element as wide as its mask)
    words: u32 = 0,

    fn varyingOf(l: *const Lay, name: []const u8, index: u32) ?u32 {
        for (0..l.nvary) |k| if (std.ascii.eqlIgnoreCase(l.names[k], name) and l.idx[k] == index) return l.base[k];
        return null;
    }

    fn varying(ctx: ?*const anyopaque, name: []const u8, index: u32) ?u32 {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        return l.varyingOf(name, index);
    }

    fn cbuffer(ctx: ?*const anyopaque, slot: u32) ?dgen.CBuffer {
        const l: *const Lay = @ptrCast(@alignCast(ctx.?));
        if (slot >= 16 or l.cb_vecs[slot] == 0) return null;
        return .{ .word = l.cb_word[slot], .vecs = l.cb_vecs[slot] };
    }

    fn tex(_: ?*const anyopaque, t: u32, s: u32) ?u32 {
        _ = s;
        return if (t < NTEX) t else null;
    }
};

var lay_store: [2]Lay = undefined;

/// Fills a stage's constant buffers (from Microsoft's reflection: the
/// values depend on variables' types, not on whose blob reads them).
fn fillUniforms(r: *const ct.Reflection, lay: *Lay, uni: []u32, next: *u32) void {
    for (r.binds[0..r.nbinds]) |b| {
        if (b.type != 0 or b.bind >= 16) continue;
        var size: u32 = 0;
        var buf: ?*const ct.RBuffer = null;
        for (r.bufs[0..r.nbufs]) |*x| if (std.mem.eql(u8, x.name, b.name)) {
            buf = x;
            size = x.size;
        };
        const vecs = (size + 15) / 16;
        lay.cb_word[b.bind] = next.*;
        lay.cb_vecs[b.bind] = vecs;
        const base = next.*;
        next.* += vecs * 4;
        // a default pattern: floats in (0.2, 0.9), then variables by type
        for (0..vecs * 4) |k| uni[base + k] = @bitCast(@as(f32, 0.2) + @as(f32, @floatFromInt((k * 7) % 8)) * 0.1);
        const bf = buf orelse continue;
        for (0..bf.nvars) |k| {
            const v = r.vars[bf.first + k];
            fillVar(r, v.ty, uni[base..][0 .. vecs * 4], v.offset);
        }
    }
}

fn fillVar(r: *const ct.Reflection, ty: u32, words: []u32, off: u32) void {
    const t = r.types[ty];
    const n: u32 = if (t.elements == 0) 1 else t.elements;
    var e: u32 = 0;
    while (e < n) : (e += 1) {
        const at = off + e * stride(r, ty);
        if (t.class == 5) {
            for (0..t.nmembers) |m| fillVar(r, r.members[t.first + m].ty, words, at + r.members[t.first + m].offset);
            continue;
        }
        const rows: u32 = if (t.class == 3) t.cols else t.rows;
        const cols: u32 = if (t.class == 3) t.rows else t.cols;
        for (0..rows) |rr| for (0..cols) |cc| {
            const w = (at + @as(u32, @intCast(rr)) * 16 + @as(u32, @intCast(cc)) * 4) / 4;
            if (w >= words.len) continue;
            words[w] = switch (t.type) {
                // ints and uints small (loop bounds, indices)
                2, 19 => @intCast(1 + (e + rr + cc) % 3),
                1 => 1,
                else => if (t.class >= 2 and t.class <= 3 and t.rows == t.cols) @bitCast(@as(f32, if (rr == cc) 1.0 else 0.0)) else words[w],
            };
        };
    }
}

fn stride(r: *const ct.Reflection, ty: u32) u32 {
    const t = r.types[ty];
    var one = t;
    one.elements = 0;
    // (an element's size, rounded to a row)
    const rows: u32 = switch (one.class) {
        2 => one.rows,
        3 => one.cols,
        5 => blk: {
            var end: u32 = 0;
            for (0..one.nmembers) |m| {
                const mm = r.members[one.first + m];
                end = @max(end, mm.offset + 16 * rowsOf(r, mm.ty));
            }
            break :blk (end + 15) / 16;
        },
        else => 1,
    };
    return rows * 16;
}

fn rowsOf(r: *const ct.Reflection, ty: u32) u32 {
    const t = r.types[ty];
    const n: u32 = if (t.elements == 0) 1 else t.elements;
    return n * (stride(r, ty) / 16);
}

const Vert4 = [4]f32;

fn setLog(log: *dgen.Log, m: []const u8) void {
    @memcpy(log.buf[0..m.len], m);
    log.len = m.len;
}

/// Draws vs+ps; the pixels (rgba32f) and whether the front end took them.
fn draw(vs: []const u8, ps: []const u8, uni: []const u32, vlay: *const Lay, play: *const Lay, img: ?*engine.Image, ntex: u8, attrs: u32, out: *[W * H * 4]f32, log: *dgen.Log) bool {
    const e = engineCpu();
    var target = e.newImage(W, H, .rgba8) orelse {
        setLog(log, "no target image");
        return false;
    };
    defer e.freeImage(&target);
    e.fill(&target, .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H }, 0, 0);
    // three vertices covering the target; every attribute a variation of it
    var vb_data: [16 * 3]Vert4 = undefined;
    const pos = [3][4]f32{ .{ -1, -1, 0.5, 1 }, .{ 3, -1, 0.5, 1 }, .{ -1, 3, 0.5, 1 } };
    for (0..16) |a| for (0..3) |v| {
        vb_data[a * 3 + v] = if (a == 0) pos[v] else .{ pos[v][0] * 0.5 + 0.1 * @as(f32, @floatFromInt(a)), pos[v][1] * 0.25 + 0.5, 0.3 + 0.05 * @as(f32, @floatFromInt(a)), 1 };
    };
    var vb = e.newBuffer(@sizeOf(@TypeOf(vb_data))) orelse {
        setLog(log, "no vertex buffer");
        return false;
    };
    defer e.freeImage(&vb);
    e.writeBytes(&vb, 0, std.mem.asBytes(&vb_data));
    const lay_v = dgen.Layout{ .ctx = vlay, .varying = Lay.varying, .cbuffer = Lay.cbuffer, .texture = Lay.tex, .desc_base = UNI_DESC };
    const lay_p = dgen.Layout{ .ctx = play, .varying = Lay.varying, .cbuffer = Lay.cbuffer, .texture = Lay.tex, .desc_base = UNI_DESC };
    const pair = dgen.Pair{ .vs = vs, .ps = ps, .lay = lay_v, .ps_lay = lay_p, .log = log };
    var pipe = raster.Pipeline.init(pair.shaders(@intCast(@min(attrs, raster.MAX_ATTRS)), @intCast(@min(play.words, raster.MAX_VARYINGS)), ntex));
    defer e.unloadPipeline(&pipe);
    var d = raster.Draw{
        .pipe = &pipe,
        .color = &target,
        .count = 3,
        .center = .{ W / 2, H / 2 },
        .half = .{ W / 2, H / 2 },
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H },
        .uniforms = uni,
    };
    for (0..@min(attrs, raster.MAX_ATTRS)) |a| d.attrs[a] = .{ .buf = &vb, .offset = @intCast(a * 3 * 16), .stride = 16, .comps = 4 };
    if (img) |t| for (0..ntex) |k| {
        d.textures[k] = t;
    };
    if (!e.draw(&d)) {
        if (log.len == 0) {
            const m = std.fmt.bufPrint(&log.buf, "the engine refused the draw: {any} pc {d}", .{ e.why_pipe, e.trap.pc }) catch "the engine refused the draw";
            log.len = m.len;
        }
        return false;
    }
    e.finish();
    if (log.len != 0) return false;
    var px: [W * H * 4]u8 = undefined;
    e.read(&target, 0, 0, W, H, &px, W * 4, .rgba8);
    for (px, 0..) |b, k| out[k] = @as(f32, @floatFromInt(b)) / 255.0;
    return true;
}

const UNI_WORDS = raster.MAX_UNIFORM_WORDS;
/// (four texture slots' descriptors at the end)
const NTEX = 4;
const UNI_DESC = UNI_WORDS - NTEX * texture.DESC_WORDS;

var px_ms: [W * H * 4]f32 = undefined;
var px_ours: [W * H * 4]f32 = undefined;
var partner_buf: [8][1 << 16]u8 = undefined;
var src_buf: [16 * 1024]u8 = undefined;
var tex_img: engine.Image = undefined;
var tex_ready = false;

fn testTexture(uni: []u32) *engine.Image {
    const e = engineCpu();
    if (!tex_ready) {
        tex_img = e.newImage(8, 8, .rgba8).?;
        var texels: [8 * 8 * 4]u8 = undefined;
        for (0..64) |i| {
            const x = i % 8;
            const y = i / 8;
            texels[i * 4 + 0] = @intCast(x * 32);
            texels[i * 4 + 1] = @intCast(y * 32);
            texels[i * 4 + 2] = @intCast(((x ^ y) & 1) * 255);
            texels[i * 4 + 3] = @intCast(128 + x * 8);
        }
        e.write(&tex_img, 0, 0, 8, 8, &texels, 32, .rgba8);
        tex_ready = true;
    }
    var dw: [texture.DESC_WORDS]u32 = undefined;
    texture.descriptor(.{ .img = &tex_img }, &dw);
    for (0..NTEX) |k| @memcpy(uni[UNI_DESC + k * texture.DESC_WORDS ..][0..texture.DESC_WORDS], &dw);
    return &tex_img;
}

fn layVaryings(lay: *Lay, sig: dxbc.Signature) void {
    lay.nvary = 0;
    lay.words = 0;
    for (0..sig.count) |k| {
        const e = sig.get(@intCast(k)).?;
        if (e.sys != .none and e.sys != .clip_distance) continue;
        if (lay.nvary >= 16) break;
        lay.names[lay.nvary] = e.name;
        lay.idx[lay.nvary] = e.index;
        lay.base[lay.nvary] = lay.words;
        lay.words += @popCount(e.mask);
        lay.nvary += 1;
    }
}

fn hlslType(comp: dxbc.CompType, n: u32, buf: []u8) []const u8 {
    const b = switch (comp) {
        .sint32 => "int",
        .uint32 => "uint",
        else => "float",
    };
    return std.fmt.bufPrint(buf, "{s}{d}", .{ b, n }) catch "float4";
}

/// A pixel shader writing one vertex shader output element as its color.
fn partnerPs(e: dxbc.Element, out: []u8) []const u8 {
    const n: u32 = @popCount(e.mask) + @ctz(e.mask);
    var tb: [16]u8 = undefined;
    const t = hlslType(e.comp, n, &tb);
    const nointerp = if (e.comp != .float32) "nointerpolation " else "";
    const pad = switch (n) {
        1 => ", 0, 0, 1",
        2 => ", 0, 1",
        3 => ", 1",
        else => "",
    };
    return std.fmt.bufPrint(out, "float4 main(float4 p : SV_Position, {s}{s} v : {s}{d}) : SV_Target {{ return float4(v{s}); }}\n", .{ nointerp, t, e.name, e.index, pad }) catch "";
}

/// A vertex shader feeding a pixel shader's inputs: its position covering
/// the target, every other input a different gradient.
fn partnerVs(sig: dxbc.Signature, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    w.writeAll("struct VO { float4 pos : SV_Position;\n") catch return "";
    var k: u32 = 0;
    while (k < sig.count) : (k += 1) {
        const e = sig.get(k).?;
        if (e.sys != .none) continue;
        const n: u32 = @popCount(e.mask) + @ctz(e.mask);
        var tb: [16]u8 = undefined;
        w.print("  {s}{s} v{d} : {s}{d};\n", .{ if (e.comp != .float32) "nointerpolation " else "", hlslType(e.comp, n, &tb), k, e.name, e.index }) catch return "";
    }
    w.writeAll("};\nVO main(float4 p : POSITION) { VO o; o.pos = p;\n") catch return "";
    k = 0;
    while (k < sig.count) : (k += 1) {
        const e = sig.get(k).?;
        if (e.sys != .none) continue;
        const n: u32 = @popCount(e.mask) + @ctz(e.mask);
        const f: f32 = @floatFromInt(k);
        var tb: [16]u8 = undefined;
        if (e.comp == .float32) {
            w.print("  o.v{d} = ({s})float4(p.x * 0.5 + 0.5, p.y * 0.4 + 0.45, {d} * 0.1 + 0.1, 1.0 - p.x * 0.25);\n", .{ k, hlslType(e.comp, n, &tb), f }) catch return "";
        } else {
            w.print("  o.v{d} = ({s})int4(p.x * 4 + 4, p.y * 3 + 4, {d}, 2);\n", .{ k, hlslType(e.comp, n, &tb), k }) catch return "";
        }
    }
    w.writeAll("  return o; }\n") catch return "";
    return w.buffered();
}

var ms_blob_buf: [1 << 20]u8 = undefined;
var partner_blobs: [8][1 << 16]u8 = undefined;

fn compareDraw(name: []const u8, ms: []const u8, ours: []const u8, stage: dxbc.Stage, ms_refl: *const ct.Reflection) void {
    var uni: [UNI_WORDS]u32 = [_]u32{0} ** UNI_WORDS;
    var vlay = Lay{};
    var play = Lay{};
    var next: u32 = 0;
    const img = testTexture(&uni);
    const mc = dxbc.Container.parse(ms) catch return;
    var ntex: u8 = 0;
    for (ms_refl.binds[0..ms_refl.nbinds]) |b| {
        if (b.type == 2 and b.bind < NTEX) ntex = @max(ntex, @as(u8, @intCast(b.bind + 1)));
    }
    var drawn: u32 = 0;
    var same = true;
    var ran = false;
    if (stage == .pixel) {
        fillUniforms(ms_refl, &play, &uni, &next);
        const isg = mc.signature(false) orelse return;
        layVaryings(&play, isg);
        vlay = play;
        const vsrc = partnerVs(isg, &src_buf);
        const vs = msCompile(vsrc, "vs_4_0", &partner_blobs[0]) orelse {
            std.debug.print("  {s}: its partner vertex shader did not compile:\n{s}\n", .{ name, vsrc });
            return;
        };
        var log_ms = dgen.Log{};
        if (!draw(vs, ms, &uni, &vlay, &play, img, ntex, 1, &px_ms, &log_ms)) {
            tally.draw_skipped += 1;
            std.debug.print("  {s}: (the front end does not run Microsoft's program: {s})\n", .{ name, log_ms.text() });
            return;
        }
        var log_o = dgen.Log{};
        if (!draw(vs, ours, &uni, &vlay, &play, img, ntex, 1, &px_ours, &log_o)) {
            tally.draw_ours_refused += 1;
            std.debug.print("  {s}: the front end refused our program: {s}\n", .{ name, log_o.text() });
            return;
        }
        ran = true;
        same = comparePixels(name, "", &drawn);
    } else if (stage == .vertex) {
        fillUniforms(ms_refl, &vlay, &uni, &next);
        const osg = mc.signature(true) orelse return;
        const isg = mc.signature(false);
        const attrs: u32 = if (isg) |s| s.count else 0;
        layVaryings(&vlay, osg);
        play = vlay;
        // each output element through a pixel shader of its own
        var k: u32 = 0;
        while (k < osg.count) : (k += 1) {
            const e = osg.get(k).?;
            if (e.sys != .none) continue;
            const psrc = partnerPs(e, &src_buf);
            const ps = msCompile(psrc, "ps_4_0", &partner_blobs[1]) orelse {
                std.debug.print("  {s}: a partner pixel shader did not compile:\n{s}\n", .{ name, psrc });
                return;
            };
            var log_ms = dgen.Log{};
            if (!draw(ms, ps, &uni, &vlay, &play, img, ntex, attrs, &px_ms, &log_ms)) {
                tally.draw_skipped += 1;
                std.debug.print("  {s}: (the front end does not run Microsoft's program: {s})\n", .{ name, log_ms.text() });
                return;
            }
            var log_o = dgen.Log{};
            if (!draw(ours, ps, &uni, &vlay, &play, img, ntex, attrs, &px_ours, &log_o)) {
                tally.draw_ours_refused += 1;
                std.debug.print("  {s}: the front end refused our program: {s}\n", .{ name, log_o.text() });
                return;
            }
            ran = true;
            if (!comparePixels(name, e.name, &drawn)) same = false;
        }
        if (!ran) {
            // (no varyings: the position alone, through a constant color)
            tally.draw_skipped += 1;
            return;
        }
    } else {
        tally.draw_skipped += 1;
        return;
    }
    if (!ran) return;
    if (same) tally.draw_same += 1 else tally.draw_diff += 1;
    tally.pixels += drawn;
}

fn comparePixels(name: []const u8, what: []const u8, drawn: *u32) bool {
    var bad: u32 = 0;
    var first: usize = 0;
    for (0..W * H) |p| {
        var any = false;
        for (0..4) |c| any = any or px_ms[p * 4 + c] != 0;
        if (any) drawn.* += 1;
        for (0..4) |c| {
            const a = px_ms[p * 4 + c];
            const b = px_ours[p * 4 + c];
            const both_nan = std.math.isNan(a) and std.math.isNan(b);
            const tol: f32 = 2.5 / 255.0;
            if (!both_nan and !(@abs(a - b) <= tol)) {
                if (bad == 0) first = p * 4 + c;
                bad += 1;
            }
        }
    }
    if (bad > 0) {
        std.debug.print("  {s} {s}: {d} values differ; first at pixel {d} comp {d}: ours {d}, Microsoft's {d}\n", .{ name, what, bad, first / 4, first % 4, px_ours[first], px_ms[first] });
    }
    return bad == 0;
}

// ── the second renderer: Direct3D 11 on WARP ──────────────────────────────

var wpx_ms: [warp.W * warp.H * 4]f32 = undefined;
var wpx_ours: [warp.W * warp.H * 4]f32 = undefined;
var warp_partner: [3][1 << 16]u8 = undefined;
var warp_src: [16 * 1024]u8 = undefined;

/// A stage's constant buffers' words, as fillUniforms made them.
fn stageCbs(r: *const ct.Reflection, uni: *[UNI_WORDS]u32) warp.Stage {
    var lay = Lay{};
    var next: u32 = 0;
    fillUniforms(r, &lay, uni, &next);
    var st = warp.Stage{ .blob = &.{} };
    for (0..16) |slot| {
        if (lay.cb_vecs[slot] > 0) st.cbs[slot] = uni[lay.cb_word[slot]..][0 .. lay.cb_vecs[slot] * 4];
    }
    return st;
}

/// The vertex shader's inputs: one buffer each, 3 vertices over the target
/// (the first element) or a variation of them.
fn attrsOf(sig: ?dxbc.Signature, out: []warp.Attr) []warp.Attr {
    const s = sig orelse return out[0..0];
    const pos = [3][4]f32{ .{ -1, -1, 0.5, 1 }, .{ 3, -1, 0.5, 1 }, .{ -1, 3, 0.5, 1 } };
    var n: usize = 0;
    var k: u32 = 0;
    while (k < s.count and n < out.len) : (k += 1) {
        const e = s.get(k).?;
        if (e.sys != .none and !(e.sys == .position)) continue;
        var a = warp.Attr{ .name = e.name.ptr[0..e.name.len :0], .index = e.index, .format = switch (e.comp) {
            .sint32 => 4,
            .uint32 => 3,
            else => 2,
        }, .data = undefined };
        for (0..3) |v| {
            for (0..4) |c| {
                const f: f32 = if (n == 0) pos[v][c] else switch (c) {
                    0 => pos[v][0] * 0.5 + 0.1 * @as(f32, @floatFromInt(n)),
                    1 => pos[v][1] * 0.25 + 0.5,
                    2 => 0.3 + 0.05 * @as(f32, @floatFromInt(n)),
                    else => 1,
                };
                a.data[v][c] = if (e.comp == .float32) @bitCast(f) else @intCast(@as(u32, @intCast(v)) + @as(u32, @intCast(c)) + n);
            }
        }
        out[n] = a;
        n += 1;
    }
    return out[0..n];
}

fn warpPixels(name: []const u8, what: []const u8) bool {
    var bad: u32 = 0;
    var first: usize = 0;
    for (0..warp.W * warp.H * 4) |i| {
        const a = wpx_ms[i];
        const b = wpx_ours[i];
        if (std.math.isNan(a) and std.math.isNan(b)) continue;
        if (!(@abs(a - b) <= 2e-3 + @abs(a) * 1e-3)) {
            if (bad == 0) first = i;
            bad += 1;
        }
    }
    for (0..warp.W * warp.H) |p| {
        if (wpx_ms[p * 4] != 0 or wpx_ms[p * 4 + 1] != 0 or wpx_ms[p * 4 + 2] != 0 or wpx_ms[p * 4 + 3] != 0) tally.warp_pixels += 1;
    }
    if (bad > 0) std.debug.print("  {s} {s} (WARP): {d} values differ; first at pixel {d} comp {d}: ours {d}, Microsoft's {d}" ++ "\n", .{ name, what, bad, first / 4, first % 4, wpx_ours[first], wpx_ms[first] });
    return bad == 0;
}

fn compareWarp(name: []const u8, ms: []const u8, ours: []const u8, stage: dxbc.Stage, ms_refl: *const ct.Reflection) void {
    if (!warp.device()) return;
    const mc = dxbc.Container.parse(ms) catch return;
    var uni: [UNI_WORDS]u32 = [_]u32{0} ** UNI_WORDS;
    var st = stageCbs(ms_refl, &uni);
    var attrs: [16]warp.Attr = undefined;
    var same = true;
    var drew = false;
    switch (stage) {
        .pixel => {
            const isg = mc.signature(false) orelse return;
            const vs = msCompile(partnerVs(isg, &warp_src), "vs_4_0", &warp_partner[0]) orelse return;
            const a = [_]warp.Attr{.{ .name = "POSITION", .index = 0, .format = 2, .data = .{ .{ @bitCast(@as(f32, -1)), @bitCast(@as(f32, -1)), @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 1)) }, .{ @bitCast(@as(f32, 3)), @bitCast(@as(f32, -1)), @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 1)) }, .{ @bitCast(@as(f32, -1)), @bitCast(@as(f32, 3)), @bitCast(@as(f32, 0.5)), @bitCast(@as(f32, 1)) } } }};
            st.blob = ms;
            warp.draw(.{ .vs = .{ .blob = vs }, .ps = st, .attrs = &a }, &wpx_ms) catch |e| return warpFail(name, e);
            st.blob = ours;
            warp.draw(.{ .vs = .{ .blob = vs }, .ps = st, .attrs = &a }, &wpx_ours) catch |e| return warpFail(name, e);
            drew = true;
            same = warpPixels(name, "");
        },
        .vertex, .geometry => {
            // (a geometry shader: fed by a vertex shader made for its inputs,
            // three points)
            var vs_st = st;
            var gs: ?warp.Stage = null;
            var gs_ours: ?warp.Stage = null;
            var at: []warp.Attr = undefined;
            const osg = mc.signature(true) orelse return;
            if (stage == .geometry) {
                const isg = mc.signature(false) orelse return;
                const vsrc = partnerVs(isg, &warp_src);
                vs_st = .{ .blob = msCompile(vsrc, "vs_4_0", &warp_partner[0]) orelse return };
                gs = st;
                gs.?.blob = ms;
                gs_ours = st;
                gs_ours.?.blob = ours;
                at = attrsOf(dxbc.Signature.parse(ct.findChunk(vs_st.blob, "ISGN").?, false) catch return, &attrs);
            } else at = attrsOf(mc.signature(false), &attrs);
            var k: u32 = 0;
            while (k < osg.count) : (k += 1) {
                const e = osg.get(k).?;
                if (e.sys != .none) continue;
                const ps = msCompile(partnerPs(e, &warp_src), "ps_4_0", &warp_partner[1]) orelse return;
                const topo: u32 = if (stage == .geometry) 1 else 4;
                var v1 = vs_st;
                if (stage == .vertex) v1.blob = ms;
                warp.draw(.{ .vs = v1, .gs = gs, .ps = .{ .blob = ps }, .attrs = at, .topology = topo }, &wpx_ms) catch |err| return warpFail(name, err);
                var v2 = vs_st;
                if (stage == .vertex) v2.blob = ours;
                warp.draw(.{ .vs = v2, .gs = gs_ours, .ps = .{ .blob = ps }, .attrs = at, .topology = topo }, &wpx_ours) catch |err| return warpFail(name, err);
                drew = true;
                if (!warpPixels(name, e.name)) same = false;
            }
        },
        else => return,
    }
    if (!drew) return;
    if (same) tally.warp_same += 1 else tally.warp_diff += 1;
}

fn warpFail(name: []const u8, e: anyerror) void {
    tally.warp_failed += 1;
    std.debug.print("  {s}: WARP did not draw: {s}" ++ "\n", .{ name, @errorName(e) });
}

fn runCase(c: Case, target: []const u8) void {
    tally.cases += 1;
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{s} ({s})", .{ c.name, target }) catch c.name;
    const ms = msCompile(c.src, target, &ms_blob_buf) orelse {
        tally.ms_refused += 1;
        return;
    };
    const r = compiler.compile(c.src, .{ .target = target, .source_name = c.name });
    if (!r.ok) {
        tally.ours_failed += 1;
        std.debug.print("  {s}: ours failed:\n{s}\n", .{ label, r.messages });
        return;
    }
    const mc = dxbc.Container.parse(ms) catch return;
    const oc = dxbc.Container.parse(r.blob) catch {
        tally.ours_failed += 1;
        std.debug.print("  {s}: our container does not parse\n", .{label});
        return;
    };
    // our checksum is what Direct3D will check
    const sum = ct.checksum(r.blob[20..]);
    var sum_ok = true;
    for (0..4) |k| sum_ok = sum_ok and sum[k] == std.mem.readInt(u32, r.blob[4 + k * 4 ..][0..4], .little);
    if (!sum_ok) std.debug.print("  {s}: checksum wrong\n", .{label});
    const s1 = sigSame(label, "input", mc.signature(false), oc.signature(false));
    const s2 = sigSame(label, "output", mc.signature(true), oc.signature(true));
    if (s1 and s2) tally.sig_same += 1 else tally.sig_diff += 1;
    if (reflSame(label, ms, r.blob)) tally.refl_same += 1 else tally.refl_diff += 1;
    const stage = (mc.program() catch return).stage;
    // (both containers list as D3DDisassemble gives them)
    _ = hlsl.disasm.disassemble(ms, &listing) catch |e| std.debug.print("  {s}: Microsoft's blob does not list: {s}\n", .{ label, @errorName(e) });
    _ = hlsl.disasm.disassemble(r.blob, &listing) catch |e| std.debug.print("  {s}: ours does not list: {s}\n", .{ label, @errorName(e) });
    if (d3d_devs[0] != null or d3d_devs[1] != null) {
        if (d3dAccepts(r.blob, stage, label)) tally.d3d_accepted += 1 else tally.d3d_refused += 1;
        // (the control: one checksum bit wrong, and Direct3D must refuse it)
        if (tally.cases == 1) {
            var bad: [1 << 16]u8 = undefined;
            @memcpy(bad[0..r.blob.len], r.blob);
            bad[4] ^= 1;
            std.debug.print("  (a damaged checksum, expected to be refused:)\n", .{});
            checksum_refused = !d3dAccepts(bad[0..r.blob.len], stage, label);
        }
    }
    // (refl_ms holds Microsoft's reflection now)
    var keep: ct.Reflection = refl_ms;
    compareDraw(label, ms, r.blob, stage, &keep);
    compareWarp(label, ms, r.blob, stage, &keep);
}

test "the HLSL compiler against Microsoft's: signatures, reflection, pixels" {
    if (!loadMs()) return error.SkipZigTest;
    tally = .{};
    d3dDevices();
    for (corpus) |c| {
        const gs = std.mem.startsWith(u8, c.name, "gs_");
        const v4 = if (std.mem.startsWith(u8, c.name, "vs_")) "vs_4_0" else if (gs) "gs_4_0" else "ps_4_0";
        const v5 = if (std.mem.startsWith(u8, c.name, "vs_")) "vs_5_0" else if (gs) "gs_5_0" else "ps_5_0";
        runCase(c, v4);
        runCase(c, v5);
    }
    std.debug.print(
        \\
        \\HLSL oracle: {d} compiles ({d} refused by Microsoft's compiler, {d} failed in ours)
        \\  signatures: {d} same, {d} different
        \\  reflection: {d} same, {d} different
        \\  pixels:     {d} same, {d} different ({d} pixels drawn); {d} not drawable by the front end, {d} ours refused
        \\  WARP (Direct3D 11's own rasterizer): {d} same, {d} different ({d} pixels drawn), {d} not drawn
        \\  Direct3D 11 (hardware and WARP): {d} of our shaders accepted, {d} refused
        \\
    , .{ tally.cases, tally.ms_refused, tally.ours_failed, tally.sig_same, tally.sig_diff, tally.refl_same, tally.refl_diff, tally.draw_same, tally.draw_diff, tally.pixels, tally.draw_skipped, tally.draw_ours_refused, tally.warp_same, tally.warp_diff, tally.warp_pixels, tally.warp_failed, tally.d3d_accepted, tally.d3d_refused });
    try std.testing.expectEqual(@as(u32, 0), tally.ours_failed);
    try std.testing.expectEqual(@as(u32, 0), tally.sig_diff);
    try std.testing.expectEqual(@as(u32, 0), tally.refl_diff);
    try std.testing.expectEqual(@as(u32, 0), tally.draw_diff);
    try std.testing.expectEqual(@as(u32, 0), tally.draw_ours_refused);
    try std.testing.expectEqual(@as(u32, 0), tally.d3d_refused);
    try std.testing.expectEqual(@as(u32, 0), tally.warp_diff);
    try std.testing.expectEqual(@as(u32, 0), tally.warp_failed);
    if (d3d_devs[0] != null or d3d_devs[1] != null) try std.testing.expect(checksum_refused);
}
