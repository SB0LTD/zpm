//! @zpm/gfxapi engine — the pixel work under the GL and EGL layers: images
//! in GPU memory, filled and copied by KIR kernels through any gpu.Device
//! (the Adreno through ir3, the RTX through sm_120, EmuDevice through the
//! interpreter), batched, with the same work done on the CPU when there is
//! no GPU, it is lost, or an image has no GPU address.
//!
//! - **Batched.** Fills and copies are recorded and run together, one
//!   Device.run (one submission, one fence) per batch: at a flush, a
//!   finish, a CPU access to an image the batch touches, or when the batch
//!   is full. The CPU goes on while the GPU works.
//! - **Waits only where needed.** Each image remembers the last batch that
//!   used it. A CPU read or write waits for that batch alone; an image no
//!   batch in flight uses is touched at once.
//! - **Cache upkeep.** Before the CPU reads what the GPU wrote: fromDevice
//!   of the rows read. Before the CPU writes: fromDevice of the rows it
//!   writes, when the GPU wrote the image (a partly written cache line
//!   would otherwise carry stale bytes back), then toDevice of them.
//! - **Frees after the GPU.** A buffer a batch in flight may still use is
//!   freed once that batch is done (`doomed`), never under the GPU.
//! - **The CPU fallback.** Each op has a CPU form with the same result, bit
//!   for bit. When a run fails, its batch is done again on the CPU and the
//!   engine stays on the CPU (`lost`, which GL reports as a reset).
//!
//! Images are 32 bits a pixel (Format). Rectangles are in GL's
//! coordinates, y from the bottom; an image whose row 0 is its top (a
//! window's buffer) says so (`top_down`) and the engine flips rows.
//!
//! Allocation-free: the engine is the caller's, at a fixed address (its
//! dispatches point into it); images come from the device, or from `pool`,
//! caller memory handed out first fit.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const r = kir.r;
const u = kir.u;

pub const Format = enum(u8) {
    /// bytes R, G, B, A: GL's RGBA8, DRM's ABGR8888
    rgba8,
    /// bytes B, G, R, A: GL's BGRA8_EXT, DRM's ARGB8888 and XRGB8888
    bgra8,
    /// depth in the low 24 bits, stencil in the top 8: GL's
    /// DEPTH24_STENCIL8 (and its depth-only and stencil-only formats)
    d24s8,

    pub fn isColor(f: Format) bool {
        return f != .d24s8;
    }
};

/// A rectangle in GL's coordinates (x, y from the bottom left), x0 <= x1.
pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn empty(a: Rect) bool {
        return a.x1 <= a.x0 or a.y1 <= a.y0;
    }
    pub fn meet(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x0, b.x0);
        const y0 = @max(a.y0, b.y0);
        return .{ .x0 = x0, .y0 = y0, .x1 = @max(x0, @min(a.x1, b.x1)), .y1 = @max(y0, @min(a.y1, b.y1)) };
    }
    pub fn width(a: Rect) u32 {
        return a.x1 - a.x0;
    }
    pub fn height(a: Rect) u32 {
        return a.y1 - a.y0;
    }
};

pub const Image = struct {
    buf: gpu.Buffer = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// bytes from one row to the next (a multiple of 4)
    stride: u32 = 0,
    format: Format = .rgba8,
    /// row 0 is the top (a window's buffer), not GL's bottom
    top_down: bool = false,
    /// the engine made it (freeImage gives it back); else the caller's
    /// (a window's dma-buf)
    own: bool = false,
    /// in the engine's pool (CPU memory: no GPU address)
    pooled: bool = false,
    /// the last batch that used it on the GPU (0: none)
    last: u64 = 0,
    /// the GPU wrote it since the CPU last fetched it
    gpu_wrote: bool = false,

    pub fn bounds(img: *const Image) Rect {
        return .{ .x0 = 0, .y0 = 0, .x1 = img.width, .y1 = img.height };
    }
    /// The memory row of GL row y.
    pub fn rowOf(img: *const Image, y: u32) u32 {
        return if (img.top_down) img.height - 1 - y else y;
    }
    pub fn live(img: *const Image) bool {
        return img.width != 0 and img.buf.cpu.len != 0;
    }
    fn words(img: *const Image) []u32 {
        return img.buf.words();
    }
};

/// An image over memory someone else has (a window's buffer): `buf` with
/// a CPU view, rows `stride` bytes apart.
pub fn wrap(buf: gpu.Buffer, width: u32, height: u32, stride: u32, format: Format, top_down: bool) Image {
    return .{ .buf = buf, .width = width, .height = height, .stride = stride, .format = format, .top_down = top_down };
}

// ── The pool: CPU memory for images when the GPU gives none ───────────────

pub const MAX_SPANS = 1024;
const POOL_ALIGN = 64;

/// The caller's bytes, handed out first fit (64-byte aligned) and taken
/// back in any order; the spans in use kept sorted.
pub const Pool = struct {
    mem: []u8 = &.{},
    spans: [MAX_SPANS][2]usize = undefined,
    n: usize = 0,

    pub fn init(mem: []u8) Pool {
        return .{ .mem = mem };
    }

    pub fn alloc(p: *Pool, bytes: usize) ?[]u8 {
        if (bytes == 0 or p.n == MAX_SPANS) return null;
        const base = @intFromPtr(p.mem.ptr);
        const size = std.mem.alignForward(usize, bytes, POOL_ALIGN);
        var at = std.mem.alignForward(usize, base, POOL_ALIGN) - base;
        var i: usize = 0;
        while (i <= p.n) : (i += 1) {
            const end = if (i < p.n) p.spans[i][0] else p.mem.len;
            if (at <= end and end - at >= size) {
                std.mem.copyBackwards([2]usize, p.spans[i + 1 .. p.n + 1], p.spans[i..p.n]);
                p.spans[i] = .{ at, size };
                p.n += 1;
                return p.mem[at..][0..bytes];
            }
            if (i < p.n) at = p.spans[i][0] + p.spans[i][1];
        }
        return null;
    }

    pub fn free(p: *Pool, s: []u8) void {
        if (s.len == 0) return;
        const at = @intFromPtr(s.ptr) -% @intFromPtr(p.mem.ptr);
        for (p.spans[0..p.n], 0..) |sp, i| {
            if (sp[0] != at) continue;
            std.mem.copyForwards([2]usize, p.spans[i .. p.n - 1], p.spans[i + 1 .. p.n]);
            p.n -= 1;
            return;
        }
    }

    pub fn owns(p: *const Pool, s: []const u8) bool {
        const a = @intFromPtr(s.ptr);
        const b = @intFromPtr(p.mem.ptr);
        return s.len != 0 and a >= b and a < b + p.mem.len;
    }
};

// ── The kernels ────────────────────────────────────────────────────────────

/// Threads per group (a row of pixels: one thread each).
pub const GROUP = 64;

const Prog = enum(u8) { fill, fill_masked, copy };
const N_PROGS = @typeInfo(Prog).@"enum".field_names.len;
/// A program's code as the backend emits it (ir3, sm_120 or KIR's own).
pub const CODE_BYTES = 16 * 1024;
const MAX_PARAMS = 12;

/// fill: rows y0.. (memory rows, one group row each), pixels x0..x0+w:
///   params 0 x0, 1 y0, 2 w, 3 stride (words), 4 value, and for
///   fill_masked 5 keep: the bits of each pixel kept (value has none of
///   them): pixel = (pixel & keep) | value.
fn fillKernel(s: kir.Storage, masked: bool) kir.Kernel {
    var k = kir.Kernel.init(s, if (masked) "gfx_fill_masked" else "gfx_fill", .{ GROUP, 1, 1 });
    const img = k.binding();
    const x0 = k.param(.u32, 0);
    const y0 = k.param(.u32, 1);
    const w = k.param(.u32, 2);
    const stride = k.param(.u32, 3);
    const value = k.param(.u32, 4);
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(w))));
    const row = k.op2(.iadd, .u32, r(y0), r(k.gid(1)));
    const at = k.op3(.imad, .u32, r(row), r(stride), r(k.op2(.iadd, .u32, r(x0), r(x))));
    const off = k.op2(.shl, .u32, r(at), u(2));
    var v = value;
    if (masked) {
        const keep = k.param(.u32, 5);
        const old = k.load(.u32, kir.global(img, 32), r(off));
        v = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(old), r(keep))), r(value));
    }
    k.store(.u32, kir.global(img, 32), r(off), r(v));
    k.endif();
    return k;
}

/// copy: w pixels of each of h rows, row y of the rectangle from source
/// row sy0 + y * sstep (pixels sx0..) to destination row dy0 + y * dstep
/// (pixels dx0..); steps are +1 or -1 (a flip between the images' row
/// orders). Bytes 0 and 2 of each pixel swap where `keep` lacks them (R
/// and B between rgba8 and bgra8): pixel = (v & keep) | (swapped(v) & ~keep).
///   params 0 sx0, 1 sy0, 2 sstep (i32), 3 sstride, 4 dx0, 5 dy0,
///   6 dstep (i32), 7 dstride, 8 w, 9 keep, 10 ~keep.
fn copyKernel(s: kir.Storage) kir.Kernel {
    var k = kir.Kernel.init(s, "gfx_copy", .{ GROUP, 1, 1 });
    const src = k.binding();
    const dst = k.binding();
    const x = k.op3(.imad, .u32, r(k.gid(0)), u(GROUP), r(k.tid(0)));
    k.ifp(r(k.cmp(.u32, .lt, r(x), r(k.param(.u32, 8)))));
    const y = k.gid(1);
    const srow = k.op3(.imad, .i32, r(y), r(k.param(.i32, 2)), r(k.param(.i32, 1)));
    const drow = k.op3(.imad, .i32, r(y), r(k.param(.i32, 6)), r(k.param(.i32, 5)));
    const sat = k.op3(.imad, .u32, r(srow), r(k.param(.u32, 3)), r(k.op2(.iadd, .u32, r(k.param(.u32, 0)), r(x))));
    const dat = k.op3(.imad, .u32, r(drow), r(k.param(.u32, 7)), r(k.op2(.iadd, .u32, r(k.param(.u32, 4)), r(x))));
    const v = k.load(.u32, kir.global(src, 32), r(k.op2(.shl, .u32, r(sat), u(2))));
    const lo = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, r(v), u(16))), u(0xff));
    const hi = k.op2(.@"and", .u32, r(k.op2(.shl, .u32, r(v), u(16))), u(0xff_0000));
    const swapped = k.op2(.@"and", .u32, r(k.op2(.@"or", .u32, r(lo), r(hi))), r(k.param(.u32, 10)));
    const out = k.op2(.@"or", .u32, r(k.op2(.@"and", .u32, r(v), r(k.param(.u32, 9)))), r(swapped));
    k.store(.u32, kir.global(dst, 32), r(k.op2(.shl, .u32, r(dat), u(2))), r(out));
    k.endif();
    return k;
}

fn swapRB(v: u32) u32 {
    return (v & 0xff00_ff00) | ((v >> 16) & 0xff) | ((v & 0xff) << 16);
}

/// The bits `copy` keeps of each pixel from `from` to `to`.
fn keepOf(from: Format, to: Format) u32 {
    return if (from != to and from.isColor() and to.isColor()) 0xff00_ff00 else 0xffff_ffff;
}

// ── The engine ─────────────────────────────────────────────────────────────

pub const MAX_OPS = 256;
pub const MAX_DOOMED = 128;
const RING = 64;
/// How long a CPU access waits for the GPU before calling it lost.
pub const TIMEOUT_US: u64 = 2_000_000;

/// A backend (gpu.compile, or gpu.compileFor with the targets an image
/// links).
pub const Compiler = *const fn (k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary;

/// gpu.compile: every backend linked (tests, tools).
pub fn compileAny(k: *const kir.Kernel, caps: gpu.Caps, work: *gpu.Work, out: []u8) anyerror!gpu.Binary {
    return gpu.compile(k, caps, work, out);
}

/// What `init` needs.
pub const Config = struct {
    /// The GPU; none: everything on the CPU.
    dev: ?gpu.Device = null,
    compiler: Compiler = compileAny,
    /// Scratch for compiling the kernels, at init only (the backend's
    /// WORK_BYTES: kir_ir3's, kir_sm120's; little for the interpreter).
    work: []u8 = &.{},
    /// CPU memory for images when the GPU gives none (it is lost, or there
    /// is none).
    pool: []u8 = &.{},
};

pub const Stats = struct {
    /// Device.run calls, dispatches recorded, ops done on the CPU, CPU
    /// waits for the GPU.
    batches: u64 = 0,
    dispatches: u64 = 0,
    cpu_ops: u64 = 0,
    waits: u64 = 0,
};

pub const Engine = struct {
    dev: ?gpu.Device = null,
    /// A run or wait failed: the GPU is not asked again (GL reports a reset).
    lost: bool = false,
    /// Why the engine is on the CPU, when it is.
    why: ?anyerror = null,
    pool: Pool = .{},
    progs: [N_PROGS]gpu.Program = undefined,
    code: [N_PROGS][CODE_BYTES]u8 align(16) = undefined,
    ops: [MAX_OPS]gpu.Dispatch = undefined,
    op_bufs: [MAX_OPS][2]gpu.Buffer = undefined,
    op_params: [MAX_OPS][MAX_PARAMS]u32 = undefined,
    /// the CPU form of each op (for a batch the GPU could not run)
    op_cpu: [MAX_OPS]CpuOp = undefined,
    n_ops: usize = 0,
    /// The open batch: ops recorded and not run yet belong to it.
    batch: u64 = 1,
    /// The last batch run, and the last one known done.
    ran: u64 = 0,
    done_upto: u64 = 0,
    fences: [RING]gpu.Fence = [_]gpu.Fence{0} ** RING,
    doomed: [MAX_DOOMED]Doomed = undefined,
    n_doomed: usize = 0,
    stats: Stats = .{},

    const Doomed = struct { buf: gpu.Buffer, batch: u64 };
    /// (the images as they were when the op was recorded: a batch done
    /// again on the CPU writes where the GPU would have, whatever a table
    /// holds since)
    const CpuOp = union(enum) {
        fill: struct { img: Image, rect: Rect, value: u32, keep: u32 },
        copy: struct { src: Image, sx: u32, sy: u32, dst: Image, dx: u32, dy: u32, w: u32, h: u32 },
    };

    /// The engine in place (it must stay at `e`): the kernels compiled and
    /// loaded for cfg.dev; if any fails, everything runs on the CPU.
    pub fn init(e: *Engine, cfg: Config) void {
        e.* = .{ .pool = Pool.init(cfg.pool) };
        const d = cfg.dev orelse return;
        e.loadAll(d, cfg.compiler, cfg.work) catch |err| {
            e.why = err;
            return;
        };
        e.dev = d;
    }

    fn loadAll(e: *Engine, d: gpu.Device, compiler: Compiler, work_mem: []u8) !void {
        var loaded: usize = 0;
        errdefer for (e.progs[0..loaded]) |*p| d.unload(p);
        for (0..N_PROGS) |i| {
            var insts: [96]kir.Inst = undefined;
            var tys: [96]kir.Ty = undefined;
            const s = kir.Storage{ .insts = &insts, .tys = &tys };
            var k = switch (@as(Prog, @enumFromInt(i))) {
                .fill => fillKernel(s, false),
                .fill_masked => fillKernel(s, true),
                .copy => copyKernel(s),
            };
            try k.finish();
            var w = gpu.Work.init(work_mem);
            const bin = try compiler(&k, d.caps, &w, &e.code[i]);
            e.progs[i] = try d.load(&bin);
            loaded += 1;
        }
    }

    /// The kernels go and the device is let go (images are the caller's to
    /// free first).
    pub fn deinit(e: *Engine) void {
        e.finish();
        e.reap(true);
        if (e.dev) |d| {
            if (!e.lost) for (&e.progs) |*p| d.unload(p);
        }
        e.dev = null;
    }

    /// The GPU does the work (not lost, and there is one).
    pub fn onGpu(e: *const Engine) bool {
        return e.dev != null and !e.lost;
    }

    // ── Memory ─────────────────────────────────────────────────────────────

    /// Memory for an image or a GL buffer: the GPU's, else the pool's.
    /// Fresh memory reads as zeros.
    fn allocBytes(e: *Engine, bytes: usize) ?struct { buf: gpu.Buffer, pooled: bool } {
        if (e.onGpu()) {
            if (e.dev.?.alloc(bytes, .host)) |b| {
                if (b.cpu.len >= bytes) return .{ .buf = b, .pooled = false };
                e.dev.?.free(b);
            } else |_| {}
        }
        const s = e.pool.alloc(bytes) orelse return null;
        @memset(s, 0);
        return .{ .buf = .{ .cpu = s, .bytes = bytes, .kind = .host }, .pooled = true };
    }

    fn freeBytes(e: *Engine, b: gpu.Buffer, pooled: bool, last: u64) void {
        if (pooled) return e.pool.free(b.cpu);
        if (b.kind == .external) return;
        const d = e.dev orelse return;
        if (e.lost or last <= e.done_upto or last == 0) return d.free(b);
        if (e.n_doomed == MAX_DOOMED) {
            e.waitBatch(e.ran);
            e.reap(false);
        }
        if (e.n_doomed == MAX_DOOMED) return d.free(b);
        e.doomed[e.n_doomed] = .{ .buf = b, .batch = last };
        e.n_doomed += 1;
    }

    /// Buffers whose batches are done are freed (all of them with `all`).
    fn reap(e: *Engine, all: bool) void {
        if (e.n_doomed == 0) return;
        if (!all) e.poll();
        var i: usize = 0;
        while (i < e.n_doomed) {
            const x = e.doomed[i];
            if (all or e.lost or x.batch <= e.done_upto) {
                if (e.dev) |d| d.free(x.buf);
                e.n_doomed -= 1;
                e.doomed[i] = e.doomed[e.n_doomed];
            } else i += 1;
        }
    }

    /// An image of width x height in `format` (rows width * 4 bytes), or
    /// null when there is no memory for it.
    pub fn newImage(e: *Engine, width: u32, height: u32, format: Format) ?Image {
        if (width == 0 or height == 0) return null;
        const stride = width * 4;
        const m = e.allocBytes(@as(usize, stride) * height) orelse return null;
        return .{ .buf = m.buf, .width = width, .height = height, .stride = stride, .format = format, .own = true, .pooled = m.pooled };
    }

    /// The image's memory goes back (after the GPU is done with it), if it
    /// is the engine's; the image is empty after.
    pub fn freeImage(e: *Engine, img: *Image) void {
        if (img.own and img.buf.cpu.len != 0) e.freeBytes(img.buf, img.pooled, img.last);
        img.* = .{};
    }

    /// Storage for a GL buffer object of `bytes` (zeros).
    pub fn newBuffer(e: *Engine, bytes: usize) ?Image {
        const m = e.allocBytes(bytes) orelse return null;
        return .{ .buf = m.buf, .width = 0, .height = 0, .own = true, .pooled = m.pooled };
    }

    // ── Batches ────────────────────────────────────────────────────────────

    /// Run what is recorded (it goes on while the CPU does).
    pub fn flush(e: *Engine) void {
        if (e.n_ops == 0) return;
        const d = e.dev.?;
        const n = e.n_ops;
        e.n_ops = 0;
        const f = d.run(e.ops[0..n]) catch |err| {
            e.loseGpu(err);
            // (the batch again, on the CPU: nothing it did is lost)
            for (e.op_cpu[0..n]) |op| e.cpuDo(op);
            return;
        };
        e.fences[e.batch % RING] = f;
        e.ran = e.batch;
        e.batch += 1;
        e.stats.batches += 1;
        e.reap(false);
    }

    /// Run what is recorded and wait until the GPU is done.
    pub fn finish(e: *Engine) void {
        e.flush();
        e.waitBatch(e.ran);
        e.reap(false);
    }

    fn loseGpu(e: *Engine, err: anyerror) void {
        e.lost = true;
        if (e.why == null) e.why = err;
        e.n_ops = 0;
    }

    /// done_upto moved to the last batch run, if its fence is done.
    fn poll(e: *Engine) void {
        if (!e.onGpu() or e.done_upto >= e.ran) return;
        if (e.dev.?.done(e.fences[e.ran % RING])) e.done_upto = e.ran;
    }

    /// The CPU waits until batch `b` is done (the GPU's batches finish in
    /// order: a later fence covers an earlier one).
    fn waitBatch(e: *Engine, b: u64) void {
        if (b == 0 or !e.onGpu()) return;
        if (b >= e.batch) e.flush();
        if (!e.onGpu() or b <= e.done_upto) return;
        const upto = if (e.ran - b >= RING) e.ran else b;
        e.stats.waits += 1;
        e.dev.?.wait(e.fences[upto % RING], TIMEOUT_US) catch |err| {
            e.loseGpu(err);
            return;
        };
        e.done_upto = upto;
    }

    /// The CPU may touch img: no batch in flight uses it.
    fn settle(e: *Engine, img: *Image) void {
        if (img.last > e.done_upto) e.waitBatch(img.last);
    }

    fn gpuUsable(e: *const Engine, img: *const Image) bool {
        return e.onGpu() and !img.pooled and img.buf.gpu != 0;
    }

    /// Room for one more op in the open batch.
    fn room(e: *Engine) void {
        if (e.n_ops == MAX_OPS) e.flush();
    }

    fn record(e: *Engine, prog: Prog, groups: [3]u32, bufs: []const *Image, params: []const u32, cpu: CpuOp) void {
        e.room();
        const i = e.n_ops;
        for (bufs, 0..) |img, j| {
            e.op_bufs[i][j] = img.buf;
            img.last = e.batch;
        }
        bufs[bufs.len - 1].gpu_wrote = true;
        @memcpy(e.op_params[i][0..params.len], params);
        e.ops[i] = .{ .prog = &e.progs[@intFromEnum(prog)], .groups = groups, .buffers = e.op_bufs[i][0..bufs.len], .params = e.op_params[i][0..params.len] };
        e.op_cpu[i] = cpu;
        e.n_ops += 1;
        e.stats.dispatches += 1;
    }

    // ── Ops ────────────────────────────────────────────────────────────────

    /// Pixels of `rect` (GL's coordinates, inside img) become
    /// (pixel & keep) | (value & ~keep).
    pub fn fill(e: *Engine, img: *Image, rect: Rect, value: u32, keep: u32) void {
        const a = rect.meet(img.bounds());
        if (a.empty() or keep == 0xffff_ffff) return;
        const op = CpuOp{ .fill = .{ .img = img.*, .rect = a, .value = value & ~keep, .keep = keep } };
        if (!e.gpuUsable(img)) {
            e.settle(img);
            return e.cpuDo(op);
        }
        // (memory rows: a top-down image's GL rows are flipped)
        const y0 = if (img.top_down) img.height - a.y1 else a.y0;
        const groups = [3]u32{ std.math.divCeil(u32, a.width(), GROUP) catch unreachable, a.height(), 1 };
        const p = [_]u32{ a.x0, y0, a.width(), img.stride / 4, value & ~keep, keep };
        if (keep == 0)
            e.record(.fill, groups, &.{img}, p[0..5], op)
        else
            e.record(.fill_masked, groups, &.{img}, &p, op);
    }

    /// w x h pixels from (sx, sy) in src to (dx, dy) in dst (GL's
    /// coordinates; both inside their images), converted between rgba8
    /// and bgra8. src and dst may be the same image only apart.
    pub fn copy(e: *Engine, src: *Image, sx: u32, sy: u32, dst: *Image, dx: u32, dy: u32, w: u32, h: u32) void {
        if (w == 0 or h == 0) return;
        std.debug.assert(sx + w <= src.width and sy + h <= src.height and dx + w <= dst.width and dy + h <= dst.height);
        const op = CpuOp{ .copy = .{ .src = src.*, .sx = sx, .sy = sy, .dst = dst.*, .dx = dx, .dy = dy, .w = w, .h = h } };
        if (!e.gpuUsable(src) or !e.gpuUsable(dst)) {
            e.settle(src);
            e.settle(dst);
            return e.cpuDo(op);
        }
        const keep = keepOf(src.format, dst.format);
        const s0: i32 = @intCast(src.rowOf(sy));
        const d0: i32 = @intCast(dst.rowOf(dy));
        const ss: i32 = if (src.top_down) -1 else 1;
        const ds: i32 = if (dst.top_down) -1 else 1;
        const p = [_]u32{ sx, @bitCast(s0), @bitCast(ss), src.stride / 4, dx, @bitCast(d0), @bitCast(ds), dst.stride / 4, w, keep, ~keep };
        e.record(.copy, .{ std.math.divCeil(u32, w, GROUP) catch unreachable, h, 1 }, &.{ src, dst }, &p, op);
    }

    /// Rows of pixels from the CPU into img's rectangle (x, y, w, h: GL's
    /// coordinates, inside img). Source row j (GL row y + j) starts at
    /// `src[j * src_stride ..]`, in `src_format` (converted to img's).
    pub fn write(e: *Engine, img: *Image, x: u32, y: u32, w: u32, h: u32, src: []const u8, src_stride: usize, src_format: Format) void {
        if (w == 0 or h == 0) return;
        e.settle(img);
        const swap = keepOf(src_format, img.format) != 0xffff_ffff;
        const dw = img.words();
        for (0..h) |j| {
            const row = img.rowOf(y + @as(u32, @intCast(j)));
            const off = @as(usize, row) * img.stride + @as(usize, x) * 4;
            if (img.gpu_wrote) e.fromDevice(img, off, @as(usize, w) * 4);
            const s = src[j * src_stride ..][0 .. @as(usize, w) * 4];
            const base = off / 4;
            for (0..w) |i| {
                const v = std.mem.readInt(u32, s[i * 4 ..][0..4], .little);
                dw[base + i] = if (swap) swapRB(v) else v;
            }
            e.toDevice(img, off, @as(usize, w) * 4);
        }
        e.stats.cpu_ops += 1;
    }

    /// Rows of img's rectangle (GL's coordinates, inside img) to the CPU:
    /// GL row y + j at `dst[j * dst_stride ..]`, in `want` (converted).
    pub fn read(e: *Engine, img: *Image, x: u32, y: u32, w: u32, h: u32, dst: []u8, dst_stride: usize, want: Format) void {
        if (w == 0 or h == 0) return;
        e.settle(img);
        const swap = keepOf(img.format, want) != 0xffff_ffff;
        const sw = img.words();
        for (0..h) |j| {
            const row = img.rowOf(y + @as(u32, @intCast(j)));
            const off = @as(usize, row) * img.stride + @as(usize, x) * 4;
            if (img.gpu_wrote) e.fromDevice(img, off, @as(usize, w) * 4);
            const d = dst[j * dst_stride ..][0 .. @as(usize, w) * 4];
            const base = off / 4;
            for (0..w) |i| {
                const v = sw[base + i];
                std.mem.writeInt(u32, d[i * 4 ..][0..4], if (swap) swapRB(v) else v, .little);
            }
        }
        e.stats.cpu_ops += 1;
    }

    /// img's bytes [off, off + len) for the CPU, once no batch in flight
    /// uses img (fetched, if the GPU wrote it). After the CPU writes into
    /// it: `wrote`.
    pub fn hostView(e: *Engine, img: *Image, off: usize, len: usize) []u8 {
        e.settle(img);
        if (img.gpu_wrote) e.fromDevice(img, off, len);
        return img.buf.cpu[off..][0..len];
    }

    /// The CPU wrote img's bytes [off, off + len) (in a hostView): handed
    /// to the GPU.
    pub fn wrote(e: *Engine, img: *const Image, off: usize, len: usize) void {
        e.toDevice(img, off, len);
    }

    /// Bytes from the CPU into a GL buffer's storage at `off`.
    pub fn writeBytes(e: *Engine, b: *Image, off: usize, src: []const u8) void {
        if (src.len == 0) return;
        e.settle(b);
        if (b.gpu_wrote) e.fromDevice(b, off, src.len);
        @memcpy(b.buf.cpu[off..][0..src.len], src);
        e.toDevice(b, off, src.len);
    }

    /// A GL buffer's bytes at `off` to the CPU.
    pub fn readBytes(e: *Engine, b: *Image, off: usize, dst: []u8) void {
        if (dst.len == 0) return;
        e.settle(b);
        if (b.gpu_wrote) e.fromDevice(b, off, dst.len);
        @memcpy(dst, b.buf.cpu[off..][0..dst.len]);
    }

    fn toDevice(e: *Engine, img: *const Image, off: usize, len: usize) void {
        if (!e.gpuUsable(img)) return;
        e.dev.?.toDevice(img.buf, off, len);
    }

    fn fromDevice(e: *Engine, img: *const Image, off: usize, len: usize) void {
        if (!e.gpuUsable(img)) return;
        e.dev.?.fromDevice(img.buf, off, len);
    }

    // ── The CPU forms ──────────────────────────────────────────────────────

    fn cpuDo(e: *Engine, op_in: CpuOp) void {
        e.stats.cpu_ops += 1;
        var op = op_in;
        switch (op) {
            .fill => |*f| {
                const img = &f.img;
                const w = img.words();
                var y = f.rect.y0;
                while (y < f.rect.y1) : (y += 1) {
                    const off = @as(usize, img.rowOf(y)) * img.stride + @as(usize, f.rect.x0) * 4;
                    const len = @as(usize, f.rect.width()) * 4;
                    // (the GPU's writes first, the CPU's after: a lost GPU
                    // leaves its memory as it was)
                    if (img.gpu_wrote) e.fromDevice(img, off, len);
                    const row = w[off / 4 ..][0..f.rect.width()];
                    for (row) |*p| p.* = (p.* & f.keep) | f.value;
                    e.toDevice(img, off, len);
                }
            },
            .copy => |*c| {
                const swap = keepOf(c.src.format, c.dst.format) != 0xffff_ffff;
                const sw = c.src.words();
                const dw = c.dst.words();
                for (0..c.h) |j| {
                    const jj: u32 = @intCast(j);
                    const so = @as(usize, c.src.rowOf(c.sy + jj)) * c.src.stride + @as(usize, c.sx) * 4;
                    const do_ = @as(usize, c.dst.rowOf(c.dy + jj)) * c.dst.stride + @as(usize, c.dx) * 4;
                    const len = @as(usize, c.w) * 4;
                    if (c.src.gpu_wrote) e.fromDevice(&c.src, so, len);
                    if (c.dst.gpu_wrote) e.fromDevice(&c.dst, do_, len);
                    for (0..c.w) |i| {
                        const v = sw[so / 4 + i];
                        dw[do_ / 4 + i] = if (swap) swapRB(v) else v;
                    }
                    e.toDevice(&c.dst, do_, len);
                }
            },
        }
    }
};

// ── Tests (the CPU forms; the GPU's are tests/test_gfxapi.sig's) ──────────

test "engine: the pool hands out, takes back and reuses" {
    var mem: [4096]u8 align(64) = undefined;
    var p = Pool.init(&mem);
    const a = p.alloc(100).?;
    const b = p.alloc(1000).?;
    try std.testing.expect(@intFromPtr(b.ptr) >= @intFromPtr(a.ptr) + 128);
    try std.testing.expect(p.alloc(4096) == null);
    p.free(a);
    const c = p.alloc(64).?;
    try std.testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(c.ptr));
    p.free(b);
    p.free(c);
    try std.testing.expectEqual(@as(usize, 0), p.n);
    try std.testing.expect(p.alloc(4096) != null);
}

test "engine: on the CPU: fill with a mask, copy with a flip and a swap, write and read" {
    var mem: [64 * 1024]u8 align(64) = undefined;
    var e: Engine = undefined;
    e.init(.{ .pool = &mem });
    try std.testing.expect(!e.onGpu());
    var a = e.newImage(8, 4, .rgba8).?;
    var b = e.newImage(8, 4, .bgra8).?;
    b.top_down = true;
    e.fill(&a, a.bounds(), 0x4433_2211, 0);
    e.fill(&a, .{ .x0 = 2, .y0 = 1, .x1 = 4, .y1 = 2 }, 0xaabb_ccdd, 0xff00_0000);
    var px: [4]u8 = undefined;
    e.read(&a, 2, 1, 1, 1, &px, 4, .rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0x44 }, &px);
    // into the top-down bgra8 image: GL row 1 is its memory row 2
    e.copy(&a, 0, 0, &b, 0, 0, 8, 4);
    try std.testing.expectEqual(swapRB(0x44bb_ccdd), b.words()[2 * 8 + 2]);
    e.read(&b, 2, 1, 1, 1, &px, 4, .rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 0xdd, 0xcc, 0xbb, 0x44 }, &px);
    // a row written from the CPU in rgba8 lands swapped in bgra8
    e.write(&b, 0, 3, 1, 1, &.{ 1, 2, 3, 4 }, 4, .rgba8);
    try std.testing.expectEqual(@as(u32, 0x0401_0203), b.words()[0]);
    e.freeImage(&a);
    e.freeImage(&b);
    try std.testing.expectEqual(@as(usize, 0), e.pool.n);
}
