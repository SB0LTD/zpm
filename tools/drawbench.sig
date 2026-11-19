//! drawbench: what a draw costs through gfxapi's engine on the real GPU
//! behind /dev/dxg (WSL), the 3D engine on: a fixed-function game's frame
//! (DirectX 6's, as galaxy-pe's ddraw sends it to pe_gpu): a clear, N
//! small textured, depth-tested triangle lists, each with its own texture
//! (of T) and constants, a few texture uploads, and the target read back
//! once a frame (a game drawing its interface on the CPU).
//!
//! Per frame: the draws' time on the CPU (each engine.draw, and the runs
//! and waits inside them), the readback's (its wait for the GPU, then the
//! copy), and the engine's counters (runs, waits, time waiting).
//!
//!   drawbench [frames]
//!
//! DB_DRAWS=200 draws a frame, DB_TRIS=4 triangles a draw (DB_SIZE=4:
//! about 25 x 24 pixels each, 0 none drawn), DB_TEX=32 textures (64 x 64,
//! B8G8R8A8), DB_UPLOADS=2 uploads a frame, DB_READ=0 no readback,
//! DB_READ=2 the readback a frame late (Engine.readStart after frame N's
//! draws, readFinish after frame N+1's), DB_W/DB_H the target (640 x
//! 480), DB_PLAIN=1 no texture (the colour times the tint), DB_VRAM=0
//! textures in system memory, DB_SERIAL=1 each draw waiting for the one
//! before on the GPU (nvidia_device's Adapter.serial_draws), DB_CHECK=0 no
//! pixel check (else the drawn pixels counted and hashed: the same hash
//! for every DB_SERIAL and DB_READ).
//!
//! The Legion's RTX 5070 Laptop in WSL, 200 draws of 4 triangles (11-19):
//! 70-80 us a draw on the CPU and a 15-18 ms frame before (each draw
//! asked the GPU whether its batches were done, a spin of 20000 pauses
//! in dxg.Channel.wait, and made its uniforms a buffer, freed with a wait
//! for the GPU every 128 draws; on the GPU each draw waited for the one
//! before); 1 us a draw and a 6-7 ms frame after, the GPU's time, most
//! of it the pixels' (texture.sig's sampling).
//!
//!   sig build-exe -target x86_64-linux -OReleaseSafe
//!     --dep gpu --dep dxg --dep gfxapi -Mroot=tools/drawbench.sig
//!     --dep gpu --dep adreno --dep nvidia --dep gfxapi -Mgfxapi=src/gfxapi/gfxapi.sig
//!     --dep nvidia -Mdxg=src/dxg/dxg.sig
//!     --dep nvidia --dep adreno --dep amdgpu --dep lfm3_nv_matrix -Mgpu=src/gpu/gpu.sig
//!     --dep nvidia --dep quantized_linear -Mlfm3_nv_matrix=src/core/lfm3_nv_matrix.sig
//!     -Mquantized_linear=src/core/quantized_linear.sig -Mnvidia=src/nvidia/nvidia.sig
//!     -Madreno=src/adreno/adreno.sig -Mamdgpu=src/amdgpu/amdgpu.sig --name drawbench

const std = @import("std");
const linux = std.os.linux;
const dxg = @import("dxg");
const gpu = @import("gpu");
const gfxapi = @import("gfxapi");
const engine = gfxapi.engine;
const raster = gfxapi.raster;
const texture = gfxapi.texture;
const gen = gfxapi.dxbc_gen;
const fx = gfxapi.dxbc_fixtures;

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
        out("drawbench: no memory ({d} bytes)\n", .{bytes});
        linux.exit(2);
    }
    const p: [*]align(4096) u8 = @ptrFromInt(@as(usize, @intCast(m)));
    return p[0..bytes];
}

fn env(environ: []const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    for (environ) |e| {
        const s = std.mem.span(e orelse continue);
        if (s.len > name.len and std.mem.startsWith(u8, s, name) and s[name.len] == '=') return s[name.len + 1 ..];
    }
    return null;
}

fn envNum(environ: []const ?[*:0]const u8, name: []const u8, default: u32) u32 {
    const s = env(environ, name) orelse return default;
    return std.fmt.parseInt(u32, s, 10) catch default;
}

var g: dxg.Gpu = .{};
var ch: dxg.Channel = .{};
var sys: dxg.DxgDevice = undefined;
var vram: dxg.VramDevice = undefined;
var adapter: gpu.nvidia_device.Adapter = .{};
var eng: engine.Engine = undefined;
var work: [gpu.nvidia_device.kir_sm120.WORK_BYTES]u8 align(64) = undefined;
var cpu_work: [16 << 20]u8 align(64) = undefined;
var cpu_kernels: [1 << 16]gpu.kir.Inst = undefined;
var slabs: [16]engine.Slab = undefined;

// ── The pipeline: zpm's Direct3D fixtures (a Shader Model 4 vertex shader,
// POSITION and COLOR; ps_tex: a sample times cb0's tint), laid out as
// pe_gpu lays out a pipeline's words: cb0's five vectors, then t0's
// descriptor ──

const CB_WORDS = 20;

fn varying(_: ?*const anyopaque, name: []const u8, index: u32) ?u32 {
    if (std.ascii.eqlIgnoreCase(name, "COLOR") and index == 0) return 0;
    return null;
}

fn cbuffer(_: ?*const anyopaque, slot: u32) ?gen.CBuffer {
    return if (slot == 0) .{ .word = 0, .vecs = 5 } else null;
}

fn texOf(_: ?*const anyopaque, t: u32, s: u32) ?u32 {
    return if (t == 0 and (s == 0 or s == gen.NO_SAMPLER)) 0 else null;
}

var log: gen.Log = .{};
var pair: gen.Pair = undefined;
var pipe: raster.Pipeline = undefined;

const Vert = extern struct { pos: [3]f32, color: [4]f32 };

const MAX_DRAWS = 2048;
const MAX_TRIS = 64;
const MAX_TEX = 256;
const TEX = 64;

var verts: [MAX_DRAWS * MAX_TRIS * 3]Vert = undefined;
var idx: [MAX_DRAWS * MAX_TRIS * 3]u16 = undefined;
var uni: [MAX_DRAWS][CB_WORDS + texture.DESC_WORDS]u32 = undefined;
var texels: [TEX * TEX * 4]u8 = undefined;
var texs: [MAX_TEX]engine.Image = undefined;
var readback: []u8 = &.{};

/// A texture upload as pe_gpu makes one (its stagedWrite): into a fresh
/// image copied in by the GPU when a batch in flight still reads the
/// texture, else in place.
fn upload(t: *engine.Image, seed: u32) void {
    for (0..TEX * TEX) |i| {
        const v: u32 = @truncate(@as(u64, i) *% 2654435761 +% seed *% 40503);
        std.mem.writeInt(u32, texels[i * 4 ..][0..4], v | 0xff00_0000, .little);
    }
    if (eng.busy(t)) {
        var tmp = eng.newImage(TEX, TEX, t.format) orelse return;
        eng.write(&tmp, 0, 0, TEX, TEX, &texels, TEX * 4, t.format);
        eng.copy(&tmp, 0, 0, t, 0, 0, TEX, TEX);
        eng.freeImage(&tmp);
    } else eng.write(t, 0, 0, TEX, TEX, &texels, TEX * 4, t.format);
}

const Sum = struct {
    frames: u64 = 0,
    draw_us: u64 = 0,
    flush_us: u64 = 0,
    read_us: u64 = 0,
    read_wait_us: u64 = 0,
    frame_us: u64 = 0,
    batches: u64 = 0,
    waits: u64 = 0,
    wait_us: u64 = 0,
    run_us: u64 = 0,
    draw_wait_us: u64 = 0,
    gfx: u64 = 0,
    compute: u64 = 0,
};

pub fn main(init: std.process.Init) void {
    const argv = init.minimal.args.vector;
    const environ = init.minimal.environ.block.slice;
    const frames: u32 = if (argv.len > 1) std.fmt.parseInt(u32, std.mem.span(argv[1]), 10) catch 60 else 60;
    const ndraws = @min(envNum(environ, "DB_DRAWS", 200), MAX_DRAWS);
    const ntris = @min(@max(envNum(environ, "DB_TRIS", 4), 1), MAX_TRIS);
    const ntex = @min(@max(envNum(environ, "DB_TEX", 32), 1), MAX_TEX);
    const nup = envNum(environ, "DB_UPLOADS", 2);
    const read_mode = envNum(environ, "DB_READ", 1);
    const W = envNum(environ, "DB_W", 640);
    const H = envNum(environ, "DB_H", 480);
    const check = envNum(environ, "DB_CHECK", 1) != 0;
    // (DB_SIZE=n: each triangle n/4 the size: 4 is about 25 x 24 pixels)
    const size: f32 = @as(f32, @floatFromInt(envNum(environ, "DB_SIZE", 4))) / 4;

    const ring = mapMemory(dxg.gpu.RING_BYTES);
    g.open(.{ .name = "zpm-drawbench" }) catch |e| {
        out("open: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    ch.open(&g, ring, .{ .name = "zpm-drawbench" }) catch |e| {
        out("channel: {s}\n", .{@errorName(e)});
        linux.exit(1);
    };
    sys.init(&g, &ch, mapMemory(512 << 20));
    vram.init(&g, &ch);
    const d = gpu.nvidia_device.over(&adapter, sys.device(), sys.device(), gpu.nvidia_device.withGraphics(gpu.nvidia_device.rtx5070(8 << 30)));
    adapter.gpu_only = vram.device();
    // (DB_SERIAL=1: each draw waits for the one before, as before draws overlapped)
    adapter.serial_draws = envNum(environ, "DB_SERIAL", 0) != 0;
    eng.init(.{ .dev = d, .work = &work, .pool = mapMemory(64 << 20), .slabs = &slabs, .cpu_work = &cpu_work, .cpu_kernels = &cpu_kernels, .graphics = true, .vram_images = envNum(environ, "DB_VRAM", 1) != 0 });
    if (!eng.onGpu()) {
        out("drawbench: the engine is on the CPU ({s})\n", .{if (eng.why) |w| @errorName(w) else "-"});
        linux.exit(1);
    }

    // (DB_PLAIN=1: ps_main, the colour times the tint: no texture)
    const plain = envNum(environ, "DB_PLAIN", 0) != 0;
    pair = .{ .vs = &fx.vs40, .ps = if (plain) &fx.ps40 else &fx.pstex40, .lay = .{ .varying = varying, .cbuffer = cbuffer, .texture = texOf, .desc_base = CB_WORDS }, .log = &log };
    pipe = raster.Pipeline.init(pair.shaders(2, 4, if (plain) 0 else 1));

    var target = eng.newImage(W, H, .bgra8) orelse linux.exit(1);
    var depth = eng.newDepthImage(W, H) orelse linux.exit(1);
    _ = eng.promote(&target);
    for (texs[0..ntex], 0..) |*t, i| {
        t.* = eng.newImage(TEX, TEX, .bgra8) orelse linux.exit(1);
        upload(t, @intCast(i));
    }
    readback = mapMemory(std.mem.alignForward(usize, @as(usize, W) * H * 4, 4096));

    // vertices and indices: two buffers a frame apart (a ring, as ddraw's:
    // a frame's data never written over while the GPU may read it)
    const vbytes = @as(usize, ndraws) * ntris * 3 * @sizeOf(Vert);
    const ibytes = std.mem.alignForward(usize, @as(usize, ndraws) * ntris * 3 * 2, 4);
    var vb = [2]engine.Image{ eng.newBuffer(vbytes) orelse linux.exit(1), eng.newBuffer(vbytes) orelse linux.exit(1) };
    var ib = [2]engine.Image{ eng.newBuffer(ibytes) orelse linux.exit(1), eng.newBuffer(ibytes) orelse linux.exit(1) };

    out("drawbench: {d} frames of {d} draws ({d} triangles each, {d} textures, {d} uploads), a {d}x{d} BGRA8 target with depth, readback {s}\n", .{ frames, ndraws, ntris, ntex, nup, W, H, switch (read_mode) {
        0 => "none",
        2 => "a frame late",
        else => "each frame",
    } });

    var sum: Sum = .{};
    const warm: u32 = @min(5, frames / 4);
    var frame: u32 = 0;
    var bad_px: u64 = 0;
    var rbs: [2]engine.Engine.Readback = .{ .{}, .{} };
    while (frame < frames + warm) : (frame += 1) {
        const measured = frame >= warm;
        const s0 = eng.stats;
        const f0 = nowUs();
        const half = frame % 2;
        // the clear
        eng.fill(&target, target.bounds(), 0xff20_4060, 0);
        eng.fillDepth(&depth, depth.bounds(), 1.0, 0, 0xff);
        // a few uploads
        for (0..nup) |u| upload(&texs[(frame * 7 + @as(u32, @intCast(u))) % ntex], frame * 31 + @as(u32, @intCast(u)));
        // the frame's vertices and indices, written once (no wait: the
        // other half is the one in flight)
        for (0..ndraws) |k| {
            const fk: f32 = @floatFromInt(k);
            const cx = -0.9 + 1.8 * @mod(fk * 0.137, 1.0);
            const cy = -0.9 + 1.8 * @mod(fk * 0.291, 1.0);
            for (0..ntris) |t| {
                const ft: f32 = @floatFromInt(t);
                const at = (k * ntris + t) * 3;
                const z = 0.1 + 0.8 * @mod(fk * 0.07 + ft * 0.01, 1.0);
                verts[at + 0] = .{ .pos = .{ cx + 0.02 * ft, cy, z }, .color = .{ 0, 0, 0, 1 } };
                verts[at + 1] = .{ .pos = .{ cx + 0.02 * ft + 0.08 * size, cy, z }, .color = .{ 1, 0, 0, 1 } };
                verts[at + 2] = .{ .pos = .{ cx + 0.02 * ft, cy + 0.1 * size, z }, .color = .{ 0, 1, 0, 1 } };
                for (0..3) |c| idx[at + c] = @intCast(t * 3 + c);
            }
        }
        @memcpy(eng.hostViewNow(&vb[half], 0, vbytes), std.mem.sliceAsBytes(verts[0 .. @as(usize, ndraws) * ntris * 3]));
        eng.wrote(&vb[half], 0, vbytes);
        @memcpy(eng.hostViewNow(&ib[half], 0, @as(usize, ndraws) * ntris * 3 * 2), std.mem.sliceAsBytes(idx[0 .. @as(usize, ndraws) * ntris * 3]));
        eng.wrote(&ib[half], 0, ibytes);
        // the draws: each its texture, its constants (an identity
        // transform, a tint), its scissor the whole target
        const d0 = nowUs();
        const w0 = eng.stats.wait_us;
        for (0..ndraws) |k| {
            const u = &uni[k];
            @memset(u, 0);
            for (0..4) |i| u[i * 4 + i] = @bitCast(@as(f32, 1));
            const tint = [4]f32{ 1, 1 - @as(f32, @floatFromInt(k % 8)) / 16, 1, 1 };
            for (0..4) |c| u[16 + c] = @bitCast(tint[c]);
            const tx = &texs[k % ntex];
            var dw: [texture.DESC_WORDS]u32 = undefined;
            texture.descriptor(.{ .img = tx, .linear = true, .min_linear = true }, &dw);
            @memcpy(u[CB_WORDS..][0..texture.DESC_WORDS], &dw);
            var dr = raster.Draw{
                .pipe = &pipe,
                .color = &target,
                .depth = &depth,
                .count = ntris * 3,
                .center = .{ @as(f32, @floatFromInt(W)) / 2, @as(f32, @floatFromInt(H)) / 2 },
                .half = .{ @as(f32, @floatFromInt(W)) / 2, @as(f32, @floatFromInt(H)) / 2 },
                .rect = target.bounds(),
                .uniforms = u,
                .depth_test = true,
                .depth_write = true,
                .depth_func = 0b011,
            };
            const voff: u32 = @intCast(k * ntris * 3 * @sizeOf(Vert));
            dr.attrs[0] = .{ .buf = &vb[half], .offset = voff, .stride = @sizeOf(Vert), .comps = 3 };
            dr.attrs[1] = .{ .buf = &vb[half], .offset = voff + 12, .stride = @sizeOf(Vert), .comps = 4 };
            dr.index = &ib[half];
            dr.index_size = 2;
            dr.index_offset = @intCast(k * ntris * 3 * 2);
            if (!plain) dr.textures[0] = tx;
            if (!eng.draw(&dr)) {
                out("drawbench: draw {d} refused ({s})\n", .{ k, if (eng.why_pipe) |w| @errorName(w) else "-" });
                linux.exit(1);
            }
        }
        const d1 = nowUs();
        const dwait = eng.stats.wait_us - w0;
        eng.flush();
        const d2 = nowUs();
        // the readback
        const r0 = eng.stats.wait_us;
        if (read_mode == 1) {
            eng.read(&target, 0, 0, W, H, readback, @as(usize, W) * 4, .bgra8);
        } else if (read_mode == 2) {
            // this frame's read begun; the one before's finished (its
            // copy done while this frame's draws were sent)
            const this = &rbs[frame % 2];
            const before = &rbs[(frame + 1) % 2];
            if (!eng.readStart(&target, 0, 0, W, H, .bgra8, this)) {
                out("drawbench: readStart refused\n", .{});
                linux.exit(1);
            }
            if (before.pending() and !eng.readFinish(before, readback, @as(usize, W) * 4)) {
                out("drawbench: readFinish failed\n", .{});
                linux.exit(1);
            }
        }
        const d3 = nowUs();
        // (a frame late: frame `warm`'s pixels are read in the frame after)
        if (check and read_mode != 0 and frame == warm + @intFromBool(read_mode == 2)) {
            // (the clear's colour where no triangle is: the bottom row's
            // last pixel; somewhere a texel's)
            const last = (@as(usize, H - 1) * W + W - 1) * 4;
            if (std.mem.readInt(u32, readback[last..][0..4], .little) != 0xff20_4060) bad_px += 1;
            var drawn: u64 = 0;
            for (0..@as(usize, W) * H) |i| {
                if (std.mem.readInt(u32, readback[i * 4 ..][0..4], .little) != 0xff20_4060) drawn += 1;
            }
            // (the frame's pixels as one number: the same whatever the draws' order on the GPU)
            const sum_px = std.hash.Fnv1a_64.hash(readback[0 .. @as(usize, W) * H * 4]);
            out("check: {d} of {d} pixels drawn, the corner {s}, pixels' hash {x}\n", .{ drawn, @as(u64, W) * H, if (bad_px == 0) "the clear's" else "NOT the clear's", sum_px });
        }
        if (!measured) continue;
        const s1 = eng.stats;
        sum.frames += 1;
        sum.draw_us += d1 - d0;
        sum.draw_wait_us += dwait;
        sum.flush_us += d2 - d1;
        sum.read_us += d3 - d2;
        sum.read_wait_us += eng.stats.wait_us - r0;
        sum.frame_us += d3 - f0;
        sum.batches += s1.batches - s0.batches;
        sum.waits += s1.waits - s0.waits;
        sum.wait_us += s1.wait_us - s0.wait_us;
        sum.run_us += s1.run_us - s0.run_us;
        sum.gfx += s1.graphics_draws - s0.graphics_draws;
        sum.compute += s1.compute_draws - s0.compute_draws;
    }
    eng.finish();
    if (log.len != 0) out("generation: {s}\n", .{log.text()});
    const n = @max(sum.frames, 1);
    const nd = n * ndraws;
    out("frame {d} us: draws {d} us ({d}.{d} us a draw, {d} us of it waiting for the GPU), flush {d} us, readback {d} us ({d} us waiting)\n", .{ sum.frame_us / n, sum.draw_us / n, sum.draw_us / nd, (sum.draw_us * 10 / nd) % 10, sum.draw_wait_us / n, sum.flush_us / n, sum.read_us / n, sum.read_wait_us / n });
    out("a frame: {d}.{d} runs, {d}.{d} waits ({d} us), {d} us handing runs over; {d} draws on the 3D engine, {d} on the compute kernels\n", .{ sum.batches / n, (sum.batches * 10 / n) % 10, sum.waits / n, (sum.waits * 10 / n) % 10, sum.wait_us / n, sum.run_us / n, sum.gfx / n, sum.compute / n });
    out("GPU: the last run {d} us\n", .{d.lastRunNs() / 1000});
    ch.close();
    g.close();
    linux.exit(if (bad_px == 0 and sum.compute == 0) 0 else 3);
}
