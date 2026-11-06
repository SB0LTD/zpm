//! @zpm/gfxapi dxbc/gen — a Direct3D shader (DXBC, Shader Model 4 and 5)
//! as KIR, emitted into a raster kernel (raster.sig) where its vertex or
//! pixel code runs: the same emitters GLSL's programs are (glsl/gen.sig),
//! so Direct3D's draws run on the same engine, GPU or CPU, bit for bit.
//!
//! - **Registers.** DXBC's are typeless vectors of four 32-bit words. Each
//!   temp's and output's component is a KIR u32 register of its own, `set`
//!   by every write; an instruction reads it as the type it computes in
//!   (KIR's `mov` reinterprets any 32-bit value). An instruction reads all
//!   its sources before it writes (`mov r0.yx, r0.xy` swaps).
//! - **Inputs.** A vertex shader's v# are its input layout's attributes; a
//!   pixel shader's are varyings, by their signature element's semantic,
//!   component by component (one register may pack two elements);
//!   SV_Position is the fragment's coordinate, SV_IsFrontFace its facing,
//!   SV_VertexID and SV_InstanceID the vertex's ids.
//! - **Outputs.** SV_Position is the clip-space position; the other
//!   outputs are varyings by semantic; a pixel shader's SV_Target0 is the
//!   color.
//! - **Constant buffers** are words of the uniform binding
//!   (Layout.cbuffer): an immediate index reads its word, a relative one
//!   loads it at run time, clamped to the buffer (no read past it). The
//!   immediate constant buffer is the shader's own: a constant index is an
//!   immediate, a relative one a select chain.
//! - **Flow.** if/else, loops with break and continue (conditional too),
//!   discard (the raster's discard pred), and a return at the end. An
//!   early return, switch, subroutines and indexable temps are refused,
//!   with a log, for now.
//! - **Textures.** sample, sample_l, sample_b, sample_d, ld and resinfo
//!   on 2D textures, through texture.sig: a resource and sampler pair is
//!   one texture slot (Layout.texture). A pixel shader's implicit level of
//!   detail comes from its coordinates' derivatives across the quad (so
//!   it runs whole quads: needsQuads); inside an if or a loop, where some
//!   pixels of a quad may not run, derivatives are 0 (as GLSL's are).
//!
//! Allocation-free: its tables are the Gen's, on the caller's stack.

const std = @import("std");
const gpu = @import("gpu");
const kir = gpu.kir;
const raster = @import("../raster.sig");
const texture = @import("../texture.sig");
const dxbc = @import("dxbc.sig");

const V = kir.V;
const Arg = kir.Arg;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;

pub const MAX_TEMPS = 128;
pub const MAX_REGS = 32;
pub const MAX_ICB = 1024;

/// A constant buffer's place in the uniform binding.
pub const CBuffer = struct {
    /// its first word
    word: u32,
    /// its size in 16-byte vectors
    vecs: u32,
};

/// ld and resinfo read their resource with no sampler.
pub const NO_SAMPLER: u32 = 0xffff_ffff;

/// What the pipeline gives the shader: where its inputs, varyings,
/// constant buffers and textures are.
pub const Layout = struct {
    ctx: ?*const anyopaque = null,
    /// a vertex shader's input register v#: the raster attribute it reads
    /// (null: none bound: 0, 0, 0, 1)
    attr: *const fn (?*const anyopaque, u32) ?u32 = attrSame,
    /// a varying's first word: a vertex shader's output or a pixel
    /// shader's input element, by its semantic (null: not linked)
    varying: *const fn (?*const anyopaque, []const u8, u32) ?u32,
    /// a constant buffer slot's words (null: none bound: reads 0)
    cbuffer: *const fn (?*const anyopaque, u32) ?CBuffer,
    /// the texture slot resource t# is read through with sampler s#
    /// (NO_SAMPLER: ld, resinfo)
    texture: *const fn (?*const anyopaque, u32, u32) ?u32 = noTexture,
    /// where the slots' descriptors start in the uniform binding
    desc_base: u32 = 0,
};

fn attrSame(_: ?*const anyopaque, reg: u32) ?u32 {
    return if (reg < raster.MAX_ATTRS) reg else null;
}

fn noTexture(_: ?*const anyopaque, _: u32, _: u32) ?u32 {
    return null;
}

/// A failed generation's reason.
pub const Log = struct {
    buf: [192]u8 = undefined,
    len: usize = 0,

    pub fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }
};

// ── What a pipeline needs to know before it builds ─────────────────────────

/// A pixel shader takes derivatives (an implicit-LOD sample, or deriv_*):
/// the raster runs it for whole quads (raster.Shaders.quads).
pub fn needsQuads(blob: []const u8) bool {
    const c = dxbc.Container.parse(blob) catch return false;
    const p = c.program() catch return false;
    if (p.stage != .pixel) return false;
    var rd = p.reader();
    while (rd.next() catch return false) |i| switch (i.op) {
        .sample, .sample_b, .sample_c, .deriv_rtx, .deriv_rty, .deriv_rtx_coarse, .deriv_rtx_fine, .deriv_rty_coarse, .deriv_rty_fine => return true,
        else => {},
    };
    return false;
}

/// The varyings a pixel shader interpolates flat (D3D's `constant`
/// interpolation): bit i for varying word i (raster.Shaders.flat).
pub fn flatVaryings(blob: []const u8, lay: Layout) u64 {
    const c = dxbc.Container.parse(blob) catch return 0;
    const p = c.program() catch return 0;
    const sig = c.signature(false) orelse return 0;
    var bits: u64 = 0;
    var rd = p.reader();
    while (rd.next() catch return bits) |i| {
        if (i.op != .dcl_input_ps or i.n == 0) continue;
        // (the interpolation mode: bits 11-14 of the opcode token; 1: constant)
        if ((i.raw[0] >> 11) & 0xf != 1) continue;
        const o = i.operands[0];
        for (0..4) |c_| {
            if (o.mask & (@as(u4, 1) << @intCast(c_)) == 0) continue;
            if (wordOf(sig, lay, o.index[0].imm, @intCast(c_))) |w| {
                if (w < 64) bits |= @as(u64, 1) << @intCast(w);
            }
        }
    }
    return bits;
}

/// The varying word of a signature's register `reg`, component `c`: its
/// element's semantic's first word, plus the component's place in it.
fn wordOf(sig: dxbc.Signature, lay: Layout, reg: u32, c: u2) ?u32 {
    var i: u32 = 0;
    while (i < sig.count) : (i += 1) {
        const e = sig.get(i) orelse return null;
        if (e.register != reg or e.mask & (@as(u8, 1) << c) == 0) continue;
        if (e.sys != .none and e.sys != .clip_distance and e.sys != .cull_distance) return null;
        const base = lay.varying(lay.ctx, e.name, e.index) orelse return null;
        const first: u32 = @ctz(e.mask);
        return base + @as(u32, c) - first;
    }
    return null;
}

// ── The emitters ───────────────────────────────────────────────────────────

/// The vertex shader `blob` as the raster's vertex code: io's position and
/// varyings set. False (with `log`) when it can't be generated.
pub fn vertex(blob: []const u8, lay: Layout, k: *kir.Kernel, io: *raster.VertexIO, log: *Log) bool {
    var g: Gen = undefined;
    if (!g.begin(blob, lay, k, log, .vertex, io.uniforms, io.textures)) return false;
    g.vio = io;
    g.run();
    if (g.failed) return false;
    // the outputs: the position, and the varyings by semantic
    const sig = g.c.signature(true) orelse return g.fail("no output signature", .{});
    var i: u32 = 0;
    while (i < sig.count) : (i += 1) {
        const e = sig.get(i) orelse break;
        if (e.register >= MAX_REGS) continue;
        for (0..4) |c_| {
            const c: u2 = @intCast(c_);
            if (e.mask & (@as(u8, 1) << c) == 0) continue;
            const v = g.outs[e.register][c];
            if (v == .none) continue;
            if (e.sys == .position) {
                io.position[c] = k.mov(.f32, r(v));
            } else if (wordOf(sig, lay, e.register, c)) |w| {
                if (w < raster.MAX_VARYINGS) io.varying[w] = k.mov(.f32, r(v));
            }
        }
    }
    for (0..4) |c| {
        if (io.position[c] == .none) io.position[c] = k.mov(.f32, f(if (c == 3) 1 else 0));
    }
    return true;
}

/// The pixel shader `blob` as the raster's fragment code: io's color
/// (SV_Target0) and discard set.
pub fn fragment(blob: []const u8, lay: Layout, k: *kir.Kernel, io: *raster.FragmentIO, log: *Log) bool {
    var g: Gen = undefined;
    if (!g.begin(blob, lay, k, log, .pixel, io.uniforms, io.textures)) return false;
    g.fio = io;
    g.quads = io.quads and io.odd_x != .none and io.odd_y != .none;
    g.discard = k.reg(.pred);
    k.set(g.discard, .mov, u(0), no, no);
    g.run();
    if (g.failed) return false;
    const sig = g.c.signature(true) orelse return g.fail("no output signature", .{});
    var i: u32 = 0;
    while (i < sig.count) : (i += 1) {
        const e = sig.get(i) orelse break;
        // (fxc writes SV_Target's system value as 0: it is known by name)
        const target = e.sys == .target or std.ascii.eqlIgnoreCase(e.name, "SV_Target");
        if (!target or e.index != 0 or e.register >= MAX_REGS) continue;
        for (0..4) |c| {
            const v = g.outs[e.register][c];
            io.color[c] = k.mov(.f32, if (v == .none) f(if (c == 3) 1 else 0) else r(v));
        }
    }
    for (0..4) |c| {
        if (io.color[c] == .none) io.color[c] = k.mov(.f32, f(if (c == 3) 1 else 0));
    }
    io.discard = g.discard;
    io.derivatives = g.quads;
    return true;
}

// ── The generator ──────────────────────────────────────────────────────────

const Gen = struct {
    k: *kir.Kernel,
    lay: Layout,
    log: *Log,
    stage: dxbc.Stage,
    c: dxbc.Container,
    prog: dxbc.Program,
    insig: ?dxbc.Signature,
    uni: u8,
    texb: u8,
    vio: ?*raster.VertexIO = null,
    fio: ?*raster.FragmentIO = null,
    /// temps' and outputs' components (u32 registers; none: not declared)
    temps: [MAX_TEMPS][4]V,
    ntemps: u32,
    outs: [MAX_REGS][4]V,
    /// inputs' components, as u32 operands (read at the start)
    ins: [MAX_REGS][4]Arg,
    /// the immediate constant buffer's words
    icb: []align(1) const u32,
    discard: V,
    quads: bool,
    /// if and loop nesting: derivatives only at 0
    depth: u32,
    failed: bool,

    fn begin(g: *Gen, blob: []const u8, lay: Layout, k: *kir.Kernel, log: *Log, want: dxbc.Stage, uni: u8, texb: u8) bool {
        g.* = .{
            .k = k,
            .lay = lay,
            .log = log,
            .stage = want,
            .c = undefined,
            .prog = undefined,
            .insig = null,
            .uni = uni,
            .texb = texb,
            .temps = undefined,
            .ntemps = 0,
            .outs = undefined,
            .ins = undefined,
            .icb = &.{},
            .discard = .none,
            .quads = false,
            .depth = 0,
            .failed = false,
        };
        for (&g.outs) |*o| o.* = .{ .none, .none, .none, .none };
        for (&g.ins) |*i| i.* = .{ u(0), u(0), u(0), u(0x3f80_0000) };
        g.c = dxbc.Container.parse(blob) catch return g.fail("not a DXBC shader", .{});
        g.prog = g.c.program() catch return g.fail("no shader program in the DXBC", .{});
        if (g.prog.stage != want) return g.fail("a {s} shader where a {s} one was wanted", .{ @tagName(g.prog.stage), @tagName(want) });
        g.insig = g.c.signature(false);
        return true;
    }

    fn fail(g: *Gen, comptime fmt: []const u8, args: anytype) bool {
        if (!g.failed) {
            const s = std.fmt.bufPrint(&g.log.buf, "dxbc: " ++ fmt, args) catch g.log.buf[0..];
            g.log.len = s.len;
        }
        g.failed = true;
        return false;
    }

    fn run(g: *Gen) void {
        var rd = g.prog.reader();
        while (true) {
            const one = rd.next() catch {
                _ = g.fail("a damaged instruction", .{});
                return;
            } orelse break;
            g.inst(&one);
            if (g.failed) return;
        }
        if (g.depth != 0) _ = g.fail("unbalanced flow", .{});
    }

    // ── Declarations ──

    fn declare(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        switch (i.op) {
            .dcl_temps => {
                const n = if (i.raw.len > 1) i.raw[1] else 0;
                if (n > MAX_TEMPS) {
                    _ = g.fail("{d} temps (at most {d})", .{ n, MAX_TEMPS });
                    return;
                }
                for (0..n) |t| {
                    for (0..4) |c| {
                        const v = k.reg(.u32);
                        k.set(v, .mov, u(0), no, no);
                        g.temps[t][c] = v;
                    }
                }
                g.ntemps = n;
            },
            .dcl_output, .dcl_output_sgv, .dcl_output_siv => {
                const o = i.operands[0];
                if (o.reg != .output) return; // (oDepth, oMask: not yet)
                const n = o.index[0].imm;
                if (n >= MAX_REGS) {
                    _ = g.fail("output o{d}", .{n});
                    return;
                }
                for (0..4) |c| {
                    if (g.outs[n][c] != .none) continue;
                    const v = k.reg(.u32);
                    k.set(v, .mov, u(if (c == 3) 0x3f80_0000 else 0), no, no);
                    g.outs[n][c] = v;
                }
            },
            .dcl_input, .dcl_input_sgv, .dcl_input_siv, .dcl_input_ps, .dcl_input_ps_sgv, .dcl_input_ps_siv => g.declareInput(i),
            .customdata => if (i.nonzero) {
                g.icb = i.data;
            },
            .dcl_indexable_temp => _ = g.fail("indexable temps (x#[]) not yet", .{}),
            .dcl_resource => {
                // (bits 11-15: the dimension; 3: texture2d)
                const dim = (i.raw[0] >> 11) & 0x1f;
                if (dim != 3) _ = g.fail("a resource of dimension {d} (only 2D textures yet)", .{dim});
            },
            else => {}, // constant buffers, samplers, global flags: nothing to emit
        }
    }

    fn declareInput(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        const o = i.operands[0];
        const sys: dxbc.SysValue = switch (i.op) {
            .dcl_input_sgv, .dcl_input_siv, .dcl_input_ps_sgv, .dcl_input_ps_siv => @enumFromInt(i.raw[i.raw.len - 1] & 0xffff),
            else => .none,
        };
        switch (o.reg) {
            .input => {},
            else => {
                // (vThreadID and the like: compute and other stages)
                _ = g.fail("input register {s}", .{@tagName(o.reg)});
                return;
            },
        }
        const n = o.index[0].imm;
        if (n >= MAX_REGS) {
            _ = g.fail("input v{d}", .{n});
            return;
        }
        for (0..4) |c_| {
            const c: u2 = @intCast(c_);
            if (o.mask & (@as(u4, 1) << c) == 0) continue;
            g.ins[n][c] = switch (g.stage) {
                .vertex => blk: {
                    const io = g.vio.?;
                    if (sys == .vertex_id and io.vertex_id != .none) break :blk r(k.mov(.u32, r(io.vertex_id)));
                    if (sys == .instance_id and io.instance_id != .none) break :blk r(k.mov(.u32, r(io.instance_id)));
                    const a = g.lay.attr(g.lay.ctx, n) orelse break :blk u(if (c == 3) 0x3f80_0000 else 0);
                    if (a >= raster.MAX_ATTRS or io.attr[a][c] == .none) break :blk u(if (c == 3) 0x3f80_0000 else 0);
                    break :blk r(k.mov(.u32, r(io.attr[a][c])));
                },
                .pixel => blk: {
                    const io = g.fio.?;
                    if (sys == .position) break :blk r(k.mov(.u32, r(io.frag_coord[c])));
                    if (sys == .is_front_face) {
                        if (io.front_facing == .none) break :blk u(0xffff_ffff);
                        break :blk r(k.sel(.u32, r(io.front_facing), u(0xffff_ffff), u(0)));
                    }
                    const sig = g.insig orelse break :blk u(0);
                    const w = wordOf(sig, g.lay, n, c) orelse break :blk u(0);
                    if (w >= raster.MAX_VARYINGS or io.varying[w] == .none) break :blk u(0);
                    break :blk r(k.mov(.u32, r(io.varying[w])));
                },
                else => u(0),
            };
        }
    }

    // ── Operands ──

    /// A source's component `c` (after its swizzle) as raw bits: a u32
    /// operand, no modifier applied.
    fn bits(g: *Gen, o: *const dxbc.Operand, c: u2) Arg {
        const sc = o.swizzle[c];
        switch (o.reg) {
            .temp => {
                const t = o.index[0].imm;
                if (t >= g.ntemps) {
                    _ = g.fail("r{d} read but not declared", .{t});
                    return u(0);
                }
                return r(g.temps[t][sc]);
            },
            .output => {
                const n = o.index[0].imm;
                if (n >= MAX_REGS or g.outs[n][sc] == .none) return u(0);
                return r(g.outs[n][sc]);
            },
            .input => {
                const n = o.index[0].imm;
                if (o.index[0].rel or n >= MAX_REGS) {
                    _ = g.fail("an input read by a relative index", .{});
                    return u(0);
                }
                return g.ins[n][sc];
            },
            .immediate32 => return u(if (o.comps == 1) o.imm[0] else o.imm[c]),
            .constant_buffer => return g.cbuf(o, sc),
            .immediate_constant_buffer => return g.icbRead(o, sc),
            else => {
                _ = g.fail("a source register {s}", .{@tagName(o.reg)});
                return u(0);
            },
        }
    }

    /// A relative index's value: its register's component, as a u32.
    fn relValue(g: *Gen, ix: dxbc.Index) Arg {
        const o = dxbc.Operand{ .reg = ix.rel_reg, .comps = 4, .swizzle = .{ ix.rel_comp, ix.rel_comp, ix.rel_comp, ix.rel_comp }, .dims = 1, .index = .{ .{ .imm = ix.rel_num }, .{}, .{} } };
        return g.bits(&o, 0);
    }

    fn cbuf(g: *Gen, o: *const dxbc.Operand, comp: u2) Arg {
        const k = g.k;
        const slot = o.index[0].imm;
        const cb = g.lay.cbuffer(g.lay.ctx, slot) orelse return u(0);
        const ix = o.index[1];
        if (!ix.rel) {
            if (ix.imm >= cb.vecs) return u(0);
            return r(raster.uniform(k, .u32, g.uni, cb.word + ix.imm * 4 + comp));
        }
        if (cb.vecs == 0) return u(0);
        // vec = clamp(rel + imm, 0, vecs - 1): never past the buffer
        const vec = k.op2(.imin, .u32, r(k.op2(.iadd, .u32, g.relValue(ix), u(ix.imm))), u(cb.vecs - 1));
        const off = k.op2(.shl, .u32, r(vec), u(4));
        var m = kir.global(g.uni, 32);
        m.imm = @intCast((cb.word + comp) * 4);
        return r(k.load(.u32, m, r(off)));
    }

    fn icbRead(g: *Gen, o: *const dxbc.Operand, comp: u2) Arg {
        const k = g.k;
        const ix = o.index[0];
        const entries = g.icb.len / 4;
        if (!ix.rel) {
            if (ix.imm >= entries) return u(0);
            return u(g.icb[ix.imm * 4 + comp]);
        }
        if (entries == 0) return u(0);
        if (entries > 64) {
            _ = g.fail("an immediate constant buffer of {d} entries read by a relative index (at most 64 yet)", .{entries});
            return u(0);
        }
        // a select chain over the entries (an index past them reads 0)
        const at = k.op2(.iadd, .u32, g.relValue(ix), u(ix.imm));
        var acc: Arg = u(0);
        for (0..entries) |e| {
            const hit = k.cmp(.u32, .eq, r(at), u(@intCast(e)));
            acc = r(k.sel(.u32, r(hit), u(g.icb[e * 4 + comp]), acc));
        }
        return acc;
    }

    /// A float source: the bits as f32, its modifiers applied.
    fn fsrc(g: *Gen, o: *const dxbc.Operand, c: u2) Arg {
        const k = g.k;
        var a = g.bits(o, c);
        if (a == .reg) a = r(k.mov(.f32, a));
        if (o.abs) a = r(k.op1(.fabs, .f32, a));
        if (o.neg) a = r(k.op1(.fneg, .f32, a));
        return a;
    }

    /// An integer source (`ty` i32 or u32), its modifiers applied as two's
    /// complement (D3D's integer negate).
    fn isrc(g: *Gen, o: *const dxbc.Operand, c: u2, ty: kir.Ty) Arg {
        const k = g.k;
        var a = g.bits(o, c);
        if (a == .reg and ty != .u32) a = r(k.mov(ty, a));
        if (o.abs) a = r(k.op1(.iabs, .i32, if (ty == .i32) a else r(k.mov(.i32, a))));
        if (o.neg) a = r(k.op1(.ineg, ty, a));
        return a;
    }

    /// A u32 condition's pred: nonzero (`nz`) or zero.
    fn cond(g: *Gen, o: *const dxbc.Operand, nz: bool) Arg {
        return r(g.k.cmp(.u32, if (nz) .ne else .eq, g.bits(o, 0), u(0)));
    }

    /// The destination's component register (none: not written).
    fn dstReg(g: *Gen, o: *const dxbc.Operand, c: u2) V {
        if (o.mask & (@as(u4, 1) << c) == 0) return .none;
        switch (o.reg) {
            .null => return .none,
            .temp => {
                const t = o.index[0].imm;
                if (t >= g.ntemps) {
                    _ = g.fail("r{d} written but not declared", .{t});
                    return .none;
                }
                return g.temps[t][c];
            },
            .output => {
                const n = o.index[0].imm;
                if (n >= MAX_REGS) return .none;
                if (g.outs[n][c] == .none) {
                    const v = g.k.reg(.u32);
                    g.k.set(v, .mov, u(0), no, no);
                    g.outs[n][c] = v;
                }
                return g.outs[n][c];
            },
            else => {
                _ = g.fail("a destination register {s}", .{@tagName(o.reg)});
                return .none;
            },
        }
    }

    /// Writes each component's value (after all are read), a float's
    /// clamped to [0, 1] when the instruction saturates.
    fn write(g: *Gen, o: *const dxbc.Operand, vals: [4]?Arg, sat: bool) void {
        const k = g.k;
        for (0..4) |c_| {
            const c: u2 = @intCast(c_);
            const v = vals[c] orelse continue;
            const d = g.dstReg(o, c);
            if (d == .none) continue;
            var x = v;
            if (sat) {
                const fx = if (x == .reg) r(k.mov(.f32, x)) else x;
                x = r(k.op2(.fmin, .f32, r(k.op2(.fmax, .f32, fx, f(0))), f(1)));
            }
            k.set(d, .mov, x, no, no);
        }
    }

    fn masked(o: *const dxbc.Operand, c: u2) bool {
        return o.reg != .null and o.mask & (@as(u4, 1) << c) != 0;
    }

    // ── Instructions ──

    fn inst(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        const op = i.op;
        const n = @intFromEnum(op);
        if (op == .customdata or (n >= @intFromEnum(dxbc.Op.dcl_resource) and n <= @intFromEnum(dxbc.Op.dcl_global_flags)) or op == .dcl_thread_group) return g.declare(i);
        const sat = i.saturate;
        switch (op) {
            .nop, .label => {},
            // float ops, componentwise
            .add, .mul, .div, .min, .max, .mad, .mov, .frc, .round_ne, .round_ni, .round_pi, .round_z, .exp, .log, .rsq, .sqrt, .rcp, .eq, .ne, .lt, .ge => {
                const d = &i.operands[0];
                var vals: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (!masked(d, c)) continue;
                    vals[c] = g.floatOp(op, i, c);
                }
                g.write(d, vals, sat and !isCompare(op));
            },
            .movc => {
                const d = &i.operands[0];
                var vals: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (!masked(d, c)) continue;
                    const p = k.cmp(.u32, .ne, g.bits(&i.operands[1], c), u(0));
                    // (sources with modifiers move as floats)
                    const a = if (i.operands[2].neg or i.operands[2].abs) g.fsrc(&i.operands[2], c) else g.bits(&i.operands[2], c);
                    const b = if (i.operands[3].neg or i.operands[3].abs) g.fsrc(&i.operands[3], c) else g.bits(&i.operands[3], c);
                    vals[c] = r(k.sel(.u32, r(p), asU32(k, a), asU32(k, b)));
                }
                g.write(d, vals, sat);
            },
            .dp2, .dp3, .dp4 => {
                const len: usize = switch (op) {
                    .dp2 => 2,
                    .dp3 => 3,
                    else => 4,
                };
                var acc = k.op2(.fmul, .f32, g.fsrc(&i.operands[1], 0), g.fsrc(&i.operands[2], 0));
                for (1..len) |c| acc = k.op3(.fmad, .f32, g.fsrc(&i.operands[1], @intCast(c)), g.fsrc(&i.operands[2], @intCast(c)), r(acc));
                const d = &i.operands[0];
                var vals: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c| {
                    if (masked(d, @intCast(c))) vals[c] = r(acc);
                }
                g.write(d, vals, sat);
            },
            .sincos => {
                // two destinations: sin, cos (either null)
                var vs: [4]?Arg = .{ null, null, null, null };
                var vc: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (masked(&i.operands[0], c)) vs[c] = r(k.op1(.fsin, .f32, g.fsrc(&i.operands[2], c)));
                    if (masked(&i.operands[1], c)) vc[c] = r(k.op1(.fcos, .f32, g.fsrc(&i.operands[2], c)));
                }
                g.write(&i.operands[0], vs, sat);
                g.write(&i.operands[1], vc, sat);
            },
            // integer ops, componentwise
            .iadd, .@"and", .@"or", .xor, .not, .ishl, .ishr, .ushr, .imin, .imax, .umin, .umax, .ineg, .ieq, .ine, .ilt, .ige, .ult, .uge, .imad, .umad, .ftoi, .ftou, .itof, .utof, .ubfe, .ibfe => {
                const d = &i.operands[0];
                var vals: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (!masked(d, c)) continue;
                    vals[c] = g.intOp(op, i, c);
                }
                g.write(d, vals, sat and (op == .itof or op == .utof));
            },
            .imul, .umul => {
                // dst0: the high 32 bits, dst1: the low
                const ty: kir.Ty = if (op == .imul) .i32 else .u32;
                var hi: [4]?Arg = .{ null, null, null, null };
                var lo: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    const a = g.isrc(&i.operands[2], c, ty);
                    const b = g.isrc(&i.operands[3], c, ty);
                    if (masked(&i.operands[0], c)) hi[c] = r(k.mov(.u32, r(k.op2(.imulhi, ty, a, b))));
                    if (masked(&i.operands[1], c)) lo[c] = r(k.mov(.u32, r(k.op2(.imul, ty, a, b))));
                }
                g.write(&i.operands[0], hi, false);
                g.write(&i.operands[1], lo, false);
            },
            .udiv => {
                // dst0: the quotient, dst1: the remainder
                var q: [4]?Arg = .{ null, null, null, null };
                var rm: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (!masked(&i.operands[0], c) and !masked(&i.operands[1], c)) continue;
                    const qr = g.udivmod(g.isrc(&i.operands[2], c, .u32), g.isrc(&i.operands[3], c, .u32));
                    if (masked(&i.operands[0], c)) q[c] = r(qr[0]);
                    if (masked(&i.operands[1], c)) rm[c] = r(qr[1]);
                }
                g.write(&i.operands[0], q, false);
                g.write(&i.operands[1], rm, false);
            },
            // flow
            .@"if" => {
                k.ifp(g.cond(&i.operands[0], i.nonzero));
                g.depth += 1;
            },
            .@"else" => k.els(),
            .endif => {
                k.endif();
                g.depth -|= 1;
            },
            .loop => {
                k.loop();
                g.depth += 1;
            },
            .endloop => {
                k.endloop();
                g.depth -|= 1;
            },
            .@"break" => k.brk(u(1)),
            .breakc => k.brk(g.cond(&i.operands[0], i.nonzero)),
            .@"continue" => k.cont(u(1)),
            .continuec => k.cont(g.cond(&i.operands[0], i.nonzero)),
            .discard => {
                const p = g.cond(&i.operands[0], i.nonzero);
                if (g.discard != .none) k.set(g.discard, .por, r(g.discard), p, no);
            },
            .ret => if (g.depth != 0) {
                _ = g.fail("a return inside flow (an early return) not yet", .{});
            },
            .deriv_rtx, .deriv_rty, .deriv_rtx_coarse, .deriv_rtx_fine, .deriv_rty_coarse, .deriv_rty_fine => {
                const up = op == .deriv_rty or op == .deriv_rty_coarse or op == .deriv_rty_fine;
                const d = &i.operands[0];
                var vals: [4]?Arg = .{ null, null, null, null };
                for (0..4) |c_| {
                    const c: u2 = @intCast(c_);
                    if (masked(d, c)) vals[c] = g.deriv(g.fsrc(&i.operands[1], c), up);
                }
                g.write(d, vals, sat);
            },
            .sample, .sample_l, .sample_b, .sample_d => g.sample(i),
            .ld => g.ld(i),
            .resinfo => g.resinfo(i),
            else => _ = g.fail("instruction {s} not yet", .{@tagName(op)}),
        }
    }

    fn isCompare(op: dxbc.Op) bool {
        return op == .eq or op == .ne or op == .lt or op == .ge;
    }

    fn floatOp(g: *Gen, op: dxbc.Op, i: *const dxbc.Inst, c: u2) Arg {
        const k = g.k;
        const s = i.operands[1..];
        return switch (op) {
            .mov => if (s[0].neg or s[0].abs) g.fsrc(&s[0], c) else g.bits(&s[0], c),
            .add => r(k.op2(.fadd, .f32, g.fsrc(&s[0], c), g.fsrc(&s[1], c))),
            .mul => r(k.op2(.fmul, .f32, g.fsrc(&s[0], c), g.fsrc(&s[1], c))),
            .div => r(k.div(g.fsrc(&s[0], c), g.fsrc(&s[1], c))),
            .min => r(k.op2(.fmin, .f32, g.fsrc(&s[0], c), g.fsrc(&s[1], c))),
            .max => r(k.op2(.fmax, .f32, g.fsrc(&s[0], c), g.fsrc(&s[1], c))),
            .mad => r(k.op3(.fmad, .f32, g.fsrc(&s[0], c), g.fsrc(&s[1], c), g.fsrc(&s[2], c))),
            .frc => blk: {
                const x = g.fsrc(&s[0], c);
                break :blk r(k.op2(.fsub, .f32, x, r(k.op1(.ffloor, .f32, x))));
            },
            .round_ne => r(k.op1(.frne, .f32, g.fsrc(&s[0], c))),
            .round_ni => r(k.op1(.ffloor, .f32, g.fsrc(&s[0], c))),
            .round_pi => r(k.op1(.fceil, .f32, g.fsrc(&s[0], c))),
            .round_z => r(k.op1(.ftrunc, .f32, g.fsrc(&s[0], c))),
            .exp => r(k.op1(.fexp2, .f32, g.fsrc(&s[0], c))),
            .log => r(k.op1(.flog2, .f32, g.fsrc(&s[0], c))),
            .rsq => r(k.op1(.frsq, .f32, g.fsrc(&s[0], c))),
            .sqrt => r(k.sqrt(g.fsrc(&s[0], c))),
            .rcp => r(k.op1(.frcp, .f32, g.fsrc(&s[0], c))),
            .eq, .ne, .lt, .ge => blk: {
                const cmp: kir.Cmp = switch (op) {
                    .eq => .eq,
                    .ne => .ne,
                    .lt => .lt,
                    else => .ge,
                };
                const p = k.cmp(.f32, cmp, g.fsrc(&s[0], c), g.fsrc(&s[1], c));
                break :blk r(k.sel(.u32, r(p), u(0xffff_ffff), u(0)));
            },
            else => u(0),
        };
    }

    fn intOp(g: *Gen, op: dxbc.Op, i: *const dxbc.Inst, c: u2) Arg {
        const k = g.k;
        const s = i.operands[1..];
        return switch (op) {
            .iadd => r(k.op2(.iadd, .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .@"and" => r(k.op2(.@"and", .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .@"or" => r(k.op2(.@"or", .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .xor => r(k.op2(.xor, .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .not => r(k.op1(.not, .u32, g.isrc(&s[0], c, .u32))),
            // (shift counts are their low 5 bits)
            .ishl => r(k.op2(.shl, .u32, g.isrc(&s[0], c, .u32), r(k.op2(.@"and", .u32, g.isrc(&s[1], c, .u32), u(31))))),
            .ushr => r(k.op2(.shr, .u32, g.isrc(&s[0], c, .u32), r(k.op2(.@"and", .u32, g.isrc(&s[1], c, .u32), u(31))))),
            .ishr => r(k.mov(.u32, r(k.op2(.shr, .i32, g.isrc(&s[0], c, .i32), r(k.mov(.i32, r(k.op2(.@"and", .u32, g.isrc(&s[1], c, .u32), u(31))))))))),
            .imin => r(k.mov(.u32, r(k.op2(.imin, .i32, g.isrc(&s[0], c, .i32), g.isrc(&s[1], c, .i32))))),
            .imax => r(k.mov(.u32, r(k.op2(.imax, .i32, g.isrc(&s[0], c, .i32), g.isrc(&s[1], c, .i32))))),
            .umin => r(k.op2(.imin, .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .umax => r(k.op2(.imax, .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32))),
            .ineg => r(k.op1(.ineg, .u32, g.isrc(&s[0], c, .u32))),
            .imad => r(k.mov(.u32, r(k.op3(.imad, .i32, g.isrc(&s[0], c, .i32), g.isrc(&s[1], c, .i32), g.isrc(&s[2], c, .i32))))),
            .umad => r(k.op3(.imad, .u32, g.isrc(&s[0], c, .u32), g.isrc(&s[1], c, .u32), g.isrc(&s[2], c, .u32))),
            .ieq, .ine, .ilt, .ige, .ult, .uge => blk: {
                const ty: kir.Ty = if (op == .ult or op == .uge) .u32 else .i32;
                const cmp: kir.Cmp = switch (op) {
                    .ieq => .eq,
                    .ine => .ne,
                    .ilt, .ult => .lt,
                    else => .ge,
                };
                const p = k.cmp(ty, cmp, g.isrc(&s[0], c, ty), g.isrc(&s[1], c, ty));
                break :blk r(k.sel(.u32, r(p), u(0xffff_ffff), u(0)));
            },
            // (D3D's float to integer rounds toward zero)
            .ftoi => r(k.mov(.u32, r(k.cvt(.f32, .i32, .rz, g.fsrc(&s[0], c))))),
            .ftou => r(k.mov(.u32, r(k.cvt(.f32, .u32, .rz, g.fsrc(&s[0], c))))),
            .itof => r(k.cvt(.i32, .f32, .rne, g.isrc(&s[0], c, .i32))),
            .utof => r(k.cvt(.u32, .f32, .rne, g.isrc(&s[0], c, .u32))),
            // bit fields: width (low 5 bits), offset, value
            .ubfe => r(k.op3(.bfe, .u32, g.isrc(&s[2], c, .u32), r(k.op2(.@"and", .u32, g.isrc(&s[1], c, .u32), u(31))), r(k.op2(.@"and", .u32, g.isrc(&s[0], c, .u32), u(31))))),
            .ibfe => r(k.mov(.u32, r(k.op3(.bfe, .i32, g.isrc(&s[2], c, .i32), r(k.mov(.i32, r(k.op2(.@"and", .u32, g.isrc(&s[1], c, .u32), u(31))))), r(k.mov(.i32, r(k.op2(.@"and", .u32, g.isrc(&s[0], c, .u32), u(31))))))))),
            else => u(0),
        };
    }

    /// a / b and a % b, unsigned: 32 steps of long division (D3D: by 0,
    /// both are 0xffffffff).
    fn udivmod(g: *Gen, a: Arg, b: Arg) [2]V {
        const k = g.k;
        const q = k.reg(.u32);
        const rem = k.reg(.u32);
        const bit = k.reg(.u32);
        k.set(q, .mov, u(0), no, no);
        k.set(rem, .mov, u(0), no, no);
        k.set(bit, .mov, u(32), no, no);
        k.loop();
        k.brk(r(k.cmp(.u32, .eq, r(bit), u(0))));
        k.set(bit, .isub, r(bit), u(1), no);
        const top = k.op2(.@"and", .u32, r(k.op2(.shr, .u32, a, r(bit))), u(1));
        k.set(rem, .@"or", r(k.op2(.shl, .u32, r(rem), u(1))), r(top), no);
        const ge = k.cmp(.u32, .ge, r(rem), b);
        k.set(rem, .sel, r(k.op2(.isub, .u32, r(rem), b)), r(rem), r(ge));
        k.set(q, .sel, r(k.op2(.@"or", .u32, r(q), r(k.op2(.shl, .u32, u(1), r(bit))))), r(q), r(ge));
        k.endloop();
        const zero = k.cmp(.u32, .eq, b, u(0));
        return .{ k.sel(.u32, r(zero), u(0xffff_ffff), r(q)), k.sel(.u32, r(zero), u(0xffff_ffff), r(rem)) };
    }

    /// x's difference across the quad (x: right minus left; up: top minus
    /// bottom); 0 outside whole quads or inside flow.
    fn deriv(g: *Gen, x: Arg, up: bool) Arg {
        if (!g.quads or g.depth != 0 or x == .imm) return f(0);
        const k = g.k;
        const io = g.fio.?;
        const xv = asF32(k, x);
        const o = k.shfl(.f32, .xor, r(xv), u(if (up) raster.QUAD_Y else raster.QUAD_X));
        const odd = if (up) io.odd_y else io.odd_x;
        return r(k.sel(.f32, r(odd), r(k.op2(.fsub, .f32, r(xv), r(o))), r(k.op2(.fsub, .f32, r(o), r(xv)))));
    }

    // ── Textures ──

    fn slotOf(g: *Gen, t: *const dxbc.Operand, s: ?*const dxbc.Operand) ?texture.Slot {
        if (t.reg != .resource) {
            _ = g.fail("a texture read of {s}", .{@tagName(t.reg)});
            return null;
        }
        const tn = t.index[0].imm;
        const sn = if (s) |x| x.index[0].imm else NO_SAMPLER;
        const slot = g.lay.texture(g.lay.ctx, tn, sn) orelse return null;
        if (slot >= texture.MAX_TEX) return null;
        return .{ .b = g.texb + @as(u8, @intCast(slot)), .uni = g.uni, .word = g.lay.desc_base + slot * texture.DESC_WORDS };
    }

    /// The four results to the destination, through the resource's swizzle.
    fn writeTexel(g: *Gen, d: *const dxbc.Operand, res: *const dxbc.Operand, t: [4]Arg) void {
        var vals: [4]?Arg = .{ null, null, null, null };
        for (0..4) |c_| {
            const c: u2 = @intCast(c_);
            if (masked(d, c)) vals[c] = asU32(g.k, t[res.swizzle[c]]);
        }
        g.write(d, vals, false);
    }

    fn sample(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        const d = &i.operands[0];
        const res = &i.operands[2];
        const smp = &i.operands[3];
        const s = g.fsrc(&i.operands[1], 0);
        const t = g.fsrc(&i.operands[1], 1);
        const off = [2]i32{ i.offset[0], i.offset[1] };
        const lod: texture.Lod = switch (i.op) {
            .sample_l => .{ .level = g.fsrc(&i.operands[4], 0) },
            .sample_d => .{ .grad = .{ .dsdx = g.fsrc(&i.operands[4], 0), .dtdx = g.fsrc(&i.operands[4], 1), .dsdy = g.fsrc(&i.operands[5], 0), .dtdy = g.fsrc(&i.operands[5], 1), .bias = f(0) } },
            else => if (g.stage == .pixel) .{ .grad = .{
                .dsdx = g.deriv(s, false),
                .dtdx = g.deriv(t, false),
                .dsdy = g.deriv(s, true),
                .dtdy = g.deriv(t, true),
                .bias = if (i.op == .sample_b) g.fsrc(&i.operands[4], 0) else f(0),
            } } else .base,
        };
        const slot = g.slotOf(res, smp) orelse {
            g.writeTexel(d, res, .{ f(0), f(0), f(0), f(1) });
            return;
        };
        g.writeTexel(d, res, texture.sample(k, slot, s, t, .float, off, lod));
    }

    fn ld(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        const d = &i.operands[0];
        const res = &i.operands[2];
        const slot = g.slotOf(res, null) orelse {
            g.writeTexel(d, res, .{ f(0), f(0), f(0), f(1) });
            return;
        };
        const x = g.isrc(&i.operands[1], 0, .u32);
        const y = g.isrc(&i.operands[1], 1, .u32);
        const lvl = g.isrc(&i.operands[1], 3, .u32);
        g.writeTexel(d, res, texture.fetch(k, slot, x, y, .float, .{ i.offset[0], i.offset[1] }, lvl));
    }

    fn resinfo(g: *Gen, i: *const dxbc.Inst) void {
        const k = g.k;
        const d = &i.operands[0];
        const res = &i.operands[2];
        const slot = g.slotOf(res, null) orelse return;
        const sz = texture.size(k, slot, g.isrc(&i.operands[1], 0, .u32));
        // (bits 11-12: the return type: 0 float, 1 1/float, 2 uint)
        const rt = (i.raw[0] >> 11) & 3;
        var t: [4]Arg = undefined;
        for (0..2) |c| {
            const w = asU32(k, sz[c]);
            t[c] = switch (rt) {
                2 => w,
                1 => r(k.op1(.frcp, .f32, r(k.cvt(.u32, .f32, .rne, w)))),
                else => r(k.cvt(.u32, .f32, .rne, w)),
            };
        }
        t[2] = if (rt == 2) u(0) else f(0);
        t[3] = if (rt == 2) u(1) else f(1);
        g.writeTexel(d, res, t);
    }
};

fn asU32(k: *kir.Kernel, a: Arg) Arg {
    return if (a == .reg) r(k.mov(.u32, a)) else a;
}

fn asF32(k: *kir.Kernel, a: Arg) kir.V {
    return k.mov(.f32, a);
}

// ── A pipeline's shaders ───────────────────────────────────────────────────

/// A Direct3D pipeline's vertex and pixel shaders and their layout, as the
/// raster's Shaders (ctx: this Pair, which must outlive the pipeline). A
/// shader that can't be generated draws nothing useful: its log says why
/// (check it once, at the pipeline's first build).
pub const Pair = struct {
    vs: []const u8,
    ps: []const u8,
    lay: Layout,
    log: *Log,

    pub fn shaders(p: *const Pair, attrs: u8, varyings: u8, textures: u8) raster.Shaders {
        return .{
            .ctx = p,
            .attrs = attrs,
            .varyings = varyings,
            .textures = textures,
            .flat = flatVaryings(p.ps, p.lay),
            .quads = needsQuads(p.ps),
            .vertex = vtx,
            .fragment = frag,
        };
    }

    fn vtx(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        const p: *const Pair = @ptrCast(@alignCast(ctx.?));
        _ = vertex(p.vs, p.lay, k, io, p.log);
    }

    fn frag(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        const p: *const Pair = @ptrCast(@alignCast(ctx.?));
        _ = fragment(p.ps, p.lay, k, io, p.log);
    }
};

test {
    _ = @import("draw_test.sig");
}
