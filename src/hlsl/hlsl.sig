//! @zpm/hlsl — an HLSL compiler: HLSL (Shader Model 4 and 5 vertex, pixel
//! and geometry shaders) in, a DXBC container out, as Microsoft's
//! D3DCompile makes them: the program (SHDR/SHEX), its input and output
//! signatures, its reflection (RDEF) and statistics (STAT), signed with
//! DXBC's checksum. Pure and allocation-free: a Compiler holds every table
//! it uses (tens of MiB: keep it in static memory), and one compile runs
//! in it at a time.
//!
//!   var c: hlsl.Compiler = undefined;
//!   const r = c.compile(source, .{ .entry = "main", .target = "ps_4_0" });
//!   // r.blob: the container; r.messages: errors and warnings

const std = @import("std");
pub const lex = @import("lex.sig");
pub const pp = @import("pp.sig");
pub const ast = @import("ast.sig");
pub const parse = @import("parse.sig");
pub const ir = @import("ir.sig");
pub const gen = @import("gen.sig");
pub const container = @import("container.sig");
pub const live = @import("live.sig");
pub const disasm = @import("disasm.sig");

pub const Include = pp.Include;
pub const Define = pp.Define;

/// D3DCOMPILE_* flags (all accepted; the ones that change code are read).
pub const flags = struct {
    pub const DEBUG: u32 = 1 << 0;
    pub const SKIP_VALIDATION: u32 = 1 << 1;
    pub const SKIP_OPTIMIZATION: u32 = 1 << 2;
    pub const PACK_MATRIX_ROW_MAJOR: u32 = 1 << 3;
    pub const PACK_MATRIX_COLUMN_MAJOR: u32 = 1 << 4;
    pub const PARTIAL_PRECISION: u32 = 1 << 5;
    pub const AVOID_FLOW_CONTROL: u32 = 1 << 9;
    pub const PREFER_FLOW_CONTROL: u32 = 1 << 10;
    pub const ENABLE_STRICTNESS: u32 = 1 << 11;
    pub const ENABLE_BACKWARDS_COMPATIBILITY: u32 = 1 << 12;
    pub const IEEE_STRICTNESS: u32 = 1 << 13;
    pub const OPTIMIZATION_LEVEL0: u32 = 1 << 14;
    pub const OPTIMIZATION_LEVEL3: u32 = 1 << 15;
    pub const WARNINGS_ARE_ERRORS: u32 = 1 << 18;
};

pub const Options = struct {
    entry: []const u8 = "main",
    /// a profile: vs_4_0, vs_4_1, vs_5_0, ps_*, gs_*
    target: []const u8,
    flags: u32 = 0,
    defines: []const Define = &.{},
    include: ?Include = null,
    source_name: []const u8 = "",
};

pub const Result = struct {
    ok: bool,
    blob: []const u8,
    messages: []const u8,
};

pub const CREATOR = "Galaxy HLSL Compiler (zpm) 1.0";

const TEXT = 2 << 20;
const RAW_TOKENS = 1 << 17;
const OUT_TOKENS = 1 << 17;
const MACRO_TOKENS = 1 << 16;
const SCRATCH_TOKENS = 1 << 16;
const BLOB = 1 << 20;
const CODE_WORDS = 1 << 18;

pub const Compiler = struct {
    pool: [TEXT]u8,
    raw: [RAW_TOKENS]lex.Token,
    out: [OUT_TOKENS]lex.Token,
    mtoks: [MACRO_TOKENS]lex.Token,
    scratch: [SCRATCH_TOKENS]lex.Token,
    xout: [SCRATCH_TOKENS]lex.Token,
    macros: [pp.MAX_MACROS]pp.Macro,
    ast: ast.Ast,
    prog: ir.Program,
    srcs: [gen.MAX_SRCS]gen.Src,
    locs: [gen.MAX_LOCS]gen.Loc,
    binds: [ast.MAX_SYMS]gen.Bind,
    vflags: [gen.MAX_VREGS]u8,
    tycache: [ast.MAX_NODES]u32,
    reads: [gen.MAX_VREGS]u8,
    intervals: [gen.MAX_VREGS]ir.Interval,
    vmap: [gen.MAX_VREGS]u32,
    sorted: [gen.MAX_VREGS]u32,
    loops: [4096][2]u32,
    live_arena: [8 << 20]u8,
    live_match: [ir.MAX_INSTS]u32,
    live_dead: [ir.MAX_INSTS]bool,
    code: [CODE_WORDS]u32,
    blob: [BLOB]u8,
    chunk: [BLOB]u8,
    msgs: [64 * 1024]u8,
    refl: container.Reflection,
    /// reflection's names made here (array elements: "name[3]")
    names: [256][96]u8,
    log: pp.Log,
    pp: pp.Pp,
    parser: parse.Parser,
    g: gen.Gen,

    /// Compiles `src`; the blob and messages stay valid until the next
    /// compile.
    pub fn compile(c: *Compiler, src: []const u8, o: Options) Result {
        c.log = .{ .buf = &c.msgs, .file_name = if (o.source_name.len > 0) o.source_name else "hlsl" };
        const target = parseTarget(o.target) orelse {
            c.log.err(0, "invalid target '{s}' (vs_4_0, vs_4_1, vs_5_0, ps_*, gs_*)", .{o.target});
            return c.failed();
        };
        // the preprocessor
        c.pp = .{ .pool = &c.pool, .raw = &c.raw, .out = &c.out, .mtoks = &c.mtoks, .scratch = &c.scratch, .xout = &c.xout, .macros = &c.macros, .log = &c.log, .include = o.include };
        predefine(&c.pp, target);
        for (o.defines) |d| c.pp.defineText(d.name, d.value);
        if (!c.pp.run(src, c.log.file_name)) return c.failed();
        // the parser
        c.ast.reset(c.pool[0..c.pp.pool_len]);
        c.parser = .{ .a = &c.ast, .t = c.out[0 .. c.pp.out_len + 1], .pool = c.pool[0..c.pp.pool_len], .log = &c.log };
        if (!c.parser.parse()) return c.failed();
        // the code
        c.prog.reset();
        for (c.binds[0..c.ast.nsyms]) |*b| b.* = .{};
        c.g = .{ .a = &c.ast, .p = &c.prog, .log = &c.log, .toks = c.parser.t, .target = target, .flags = o.flags, .srcs = &c.srcs, .locs = &c.locs, .binds = &c.binds, .vflags = &c.vflags, .tycache = &c.tycache };
        @memset(c.tycache[0..c.ast.nnodes], 0);
        if (!c.g.run(o.entry)) return c.failed();
        if (o.flags & flags.WARNINGS_ARE_ERRORS != 0 and c.log.len > 0) return c.failed();
        ir.deadComponents(&c.prog, &c.reads);
        if (c.prog.nvregs > 0) {
            var lv = live.Live{ .p = &c.prog, .arena = &c.live_arena, .n = c.prog.nvregs, .match = &c.live_match, .dead = &c.live_dead };
            if (lv.run()) ir.deadComponents(&c.prog, &c.reads);
        }
        var ntemps = ir.allocate(&c.prog, &c.intervals, &c.vmap, &c.loops, &c.sorted);
        if (c.prog.nvregs == 0) ntemps = 0;
        const n = c.assemble(target, o.flags, ntemps) orelse return c.failed();
        return .{ .ok = true, .blob = c.blob[0..n], .messages = c.log.text() };
    }

    /// The preprocessed source (D3DPreprocess): the tokens, a line each as
    /// the source has them, `#line` where a file changes.
    pub fn preprocess(c: *Compiler, src: []const u8, o: Options) Result {
        c.log = .{ .buf = &c.msgs, .file_name = if (o.source_name.len > 0) o.source_name else "hlsl" };
        c.pp = .{ .pool = &c.pool, .raw = &c.raw, .out = &c.out, .mtoks = &c.mtoks, .scratch = &c.scratch, .xout = &c.xout, .macros = &c.macros, .log = &c.log, .include = o.include };
        for (o.defines) |d| c.pp.defineText(d.name, d.value);
        if (!c.pp.run(src, c.log.file_name)) return c.failed();
        var w = container.W{ .buf = &c.blob };
        var line: u32 = 1;
        var file: u8 = 0;
        for (c.out[0..c.pp.out_len], 0..) |t, k| {
            if (k > 0 and (t.line() != line or t.file() != file)) {
                w.bytes("\n");
                if (t.file() != file) {
                    var b: [32]u8 = undefined;
                    w.bytes(std.fmt.bufPrint(&b, "#line {d}\n", .{t.line()}) catch "");
                }
            } else if (k > 0) w.bytes(" ");
            line = t.line();
            file = t.file();
            switch (t.kind) {
                .pragma_row_major => w.bytes("#pragma pack_matrix(row_major)"),
                .pragma_column_major => w.bytes("#pragma pack_matrix(column_major)"),
                else => w.bytes(c.pp.text(t)),
            }
        }
        w.bytes("\n");
        if (w.over) {
            c.log.err(0, "preprocessed text too long", .{});
            return c.failed();
        }
        return .{ .ok = true, .blob = c.blob[0..w.n], .messages = c.log.text() };
    }

    fn failed(c: *Compiler) Result {
        if (c.log.len == 0) c.log.err(0, "compilation failed", .{});
        return .{ .ok = false, .blob = &.{}, .messages = c.log.text() };
    }

    // ── the container ──

    fn assemble(c: *Compiler, t: gen.Target, fl: u32, ntemps: u32) ?usize {
        const g = &c.g;
        c.scanUsage();
        // the program
        var o = ir.Out{ .buf = &c.code };
        const ver: u32 = (@as(u32, @intFromEnum(t.stage)) << 16) | (@as(u32, t.major) << 4) | t.minor;
        o.put(ver);
        o.put(0);
        c.declarations(&o, t, ntemps);
        for (c.prog.insts[0..c.prog.n]) |*i| ir.encodeInst(&o, i);
        if (o.over) {
            c.log.err(0, "shader too long", .{});
            return null;
        }
        c.code[1] = @intCast(o.n);
        // the chunks, each in its part of `chunk`
        var w = container.W{ .buf = &c.chunk };
        const rdef_at = w.n;
        c.reflection(t, fl);
        c.refl.write(&w, t.major >= 5);
        const rdef_end = w.n;
        // (elements in register order: a packed one after its register's first)
        sortElems(g.ins[0..g.nins]);
        if (t.stage != .pixel) sortElems(g.outs[0..g.nouts]);
        var isg: [64]container.SigElem = undefined;
        for (g.ins[0..g.nins], 0..) |e, k| isg[k] = .{ .name = e.name, .index = e.index, .sys = e.sys, .comp = e.comp, .reg = e.reg, .mask = e.mask, .rw = e.used };
        const isgn_at = w.n;
        container.signature(&w, isg[0..g.nins], false);
        const isgn_end = w.n;
        var osg: [64]container.SigElem = undefined;
        for (g.outs[0..g.nouts], 0..) |e, k| osg[k] = .{ .name = e.name, .index = e.index, .sys = e.sys, .comp = e.comp, .reg = e.reg, .mask = e.mask, .rw = (~e.used) & 0xf };
        // (a pixel shader's outputs carry no system value: fxc knows
        // SV_Target and SV_Depth by name)
        if (t.stage == .pixel) {
            for (osg[0..g.nouts]) |*x| x.sys = 0;
        }
        const osgn_at = w.n;
        container.signature(&w, osg[0..g.nouts], false);
        const osgn_end = w.n;
        const code_at = w.n;
        for (c.code[0..o.n]) |word| w.u32_(word);
        const code_end = w.n;
        const stat_at = w.n;
        c.stats(&w, t, ntemps);
        const stat_end = w.n;
        if (w.over) {
            c.log.err(0, "shader too long", .{});
            return null;
        }
        const chunks = [_]container.Chunk{
            .{ .tag = "RDEF", .data = c.chunk[rdef_at..rdef_end] },
            .{ .tag = "ISGN", .data = c.chunk[isgn_at..isgn_end] },
            .{ .tag = "OSGN", .data = c.chunk[osgn_at..osgn_end] },
            .{ .tag = if (t.major >= 5) "SHEX" else "SHDR", .data = c.chunk[code_at..code_end] },
            .{ .tag = "STAT", .data = c.chunk[stat_at..stat_end] },
        };
        return container.container(&c.blob, &chunks) orelse {
            c.log.err(0, "shader too long", .{});
            return null;
        };
    }

    /// What the code reads, now dead code is gone: inputs' components,
    /// constant buffers' rows and variables, resources.
    fn scanUsage(c: *Compiler) void {
        const g = &c.g;
        for (g.ins[0..g.nins]) |*e| e.used = 0;
        for (g.cbs[0..g.ncbs]) |*b| {
            b.used = false;
            b.rows = 0;
        }
        for (g.res[0..g.nres]) |*r| r.used = false;
        for (c.prog.insts[0..c.prog.n]) |*i| {
            for (i.ops[0..i.n], 0..) |op, k| {
                if (k < i.ndst) continue;
                const comps: u8 = ir.readMask(i, k);
                switch (op.reg) {
                    .input => {
                        const r = if (op.dims == 2) op.idx[1] else op.idx[0];
                        for (g.ins[0..g.nins]) |*e| if (e.reg == r) {
                            e.used |= comps & e.mask;
                        };
                    },
                    .cb => {
                        for (g.cbs[0..g.ncbs]) |*b| if (b.slot == op.idx[0]) {
                            b.used = true;
                            b.rows = @max(b.rows, op.idx[1] + 1);
                            if (op.rel.on) b.dynamic = true;
                        };
                    },
                    .resource, .sampler => {
                        const kind: u8 = if (op.reg == .resource) 't' else 's';
                        for (g.res[0..g.nres]) |*r| if (r.kind == kind and r.slot == op.idx[0]) {
                            r.used = true;
                        };
                    },
                    else => {},
                }
            }
        }
    }

    // ── declarations ──

    fn declarations(c: *Compiler, o: *ir.Out, t: gen.Target, ntemps: u32) void {
        const g = &c.g;
        if (t.major >= 5) {
            ir.encodeInst(o, &.{ .op = .dcl_global_flags, .ndst = 0, .ctl = 1 });
        }
        if (g.nicb > 0) {
            o.put(53 | (3 << 11));
            o.put(2 + g.nicb);
            for (g.icb[0..g.nicb]) |w| o.put(w);
        }
        // constant buffers, by slot
        var slot: u32 = 0;
        while (slot < 16) : (slot += 1) {
            for (g.cbs[0..g.ncbs]) |b| {
                if (b.slot != slot or !b.used) continue;
                const rows = if (b.dynamic) @max((b.size + 15) / 16, b.rows) else b.rows;
                var i = ir.Inst{ .op = .dcl_constant_buffer, .ndst = 0, .n = 1, .ctl = if (b.dynamic) 1 else 0 };
                i.ops[0] = .{ .reg = .cb, .comps = 4, .dims = 2, .idx = .{ b.slot, rows } };
                ir.encodeInst(o, &i);
            }
        }
        // samplers, then textures, by register
        for ([_]u8{ 's', 't' }) |kind| {
            var r: u32 = 0;
            while (r < 128) : (r += 1) {
                for (g.res[0..g.nres]) |x| {
                    if (x.kind != kind or x.slot != r or !x.used) continue;
                    const ty = c.ast.types[resElemTy(c, x.sym)];
                    var i = ir.Inst{ .op = if (kind == 's') .dcl_sampler else .dcl_resource, .ndst = 0, .n = 1 };
                    if (kind == 's') {
                        i.ctl = if (ty.dim == 1) 1 else 0;
                        i.ops[0] = .{ .reg = .sampler, .comps = 0, .dims = 1, .idx = .{ r, 0 } };
                        ir.encodeInst(o, &i);
                    } else {
                        const dim = gen_intrin_resDim(@enumFromInt(ty.dim));
                        i.ctl = @intCast(dim | (@min(ty.len, 127) << 5));
                        i.ops[0] = .{ .reg = .resource, .comps = 0, .dims = 1, .idx = .{ r, 0 } };
                        const at = o.n;
                        ir.encodeInst(o, &i);
                        // the return type token, one nibble per component
                        const et = c.ast.types[if (ty.elem == 0) c.ast.vector(.float, 4) else ty.elem];
                        const rt: u32 = switch (ast.canon(et.base)) {
                            .int => 3,
                            .uint, .bool => 4,
                            else => 5,
                        };
                        o.put(rt | rt << 4 | rt << 8 | rt << 12);
                        c.code[at] += 1 << 24;
                    }
                }
            }
        }
        // geometry shaders' primitive declarations
        if (t.stage == .geometry) {
            ir.encodeInst(o, &.{ .op = .dcl_gs_input_primitive, .ndst = 0, .ctl = @intCast(g.gs_input_prim) });
        }
        // inputs
        for (g.ins[0..g.nins]) |e| {
            if (e.used == 0) continue;
            var i = ir.Inst{ .op = .dcl_input, .ndst = 0, .n = 1 };
            if (t.stage == .geometry) {
                i.ops[0] = .{ .reg = .input, .comps = 4, .mode = .mask, .mask = @intCast(e.used), .dims = 2, .idx = .{ g.gs_in_vertices, e.reg } };
            } else i.ops[0] = .{ .reg = .input, .comps = 4, .mode = .mask, .mask = @intCast(e.used), .dims = 1, .idx = .{ e.reg, 0 } };
            var name: ?u32 = null;
            const sgv = e.sys == 6 or e.sys == 7 or e.sys == 8 or e.sys == 9 or e.sys == 10;
            if (t.stage == .pixel) {
                var interp: u16 = interpMode(e.flags);
                if (e.comp != 3 or sgv) interp = 1;
                if (e.sys == 1 and e.flags & ast.INTERP == 0) interp = 4;
                i.ctl = interp;
                if (e.sys != 0) {
                    i.op = if (sgv) .dcl_input_ps_sgv else .dcl_input_ps_siv;
                    name = e.sys;
                } else i.op = .dcl_input_ps;
            } else if (e.sys != 0) {
                i.op = if (sgv) .dcl_input_sgv else .dcl_input_siv;
                name = e.sys;
            }
            const at = o.n;
            ir.encodeInst(o, &i);
            if (name) |nm| {
                o.put(nm);
                c.code[at] += 1 << 24;
            }
        }
        // GS: SV_PrimitiveID
        if (t.stage == .geometry) {
            var uses_prim = false;
            for (c.prog.insts[0..c.prog.n]) |ins| {
                for (ins.ops[0..ins.n]) |op| uses_prim = uses_prim or op.reg == .input_primitive_id;
            }
            if (uses_prim) {
                var i = ir.Inst{ .op = .dcl_input, .ndst = 0, .n = 1 };
                i.ops[0] = .{ .reg = .input_primitive_id, .comps = 0, .dims = 0 };
                ir.encodeInst(o, &i);
            }
        }
        if (t.stage == .geometry and g.gs_output_topo != 0) {
            ir.encodeInst(o, &.{ .op = .dcl_gs_output_primitive_topology, .ndst = 0, .ctl = @intCast(g.gs_output_topo) });
        }
        // outputs
        for (g.outs[0..g.nouts]) |e| {
            var i = ir.Inst{ .op = .dcl_output, .ndst = 0, .n = 1 };
            if (e.special == .output_depth) {
                i.ops[0] = .{ .reg = .output_depth, .comps = 1, .dims = 0 };
                ir.encodeInst(o, &i);
                continue;
            }
            i.ops[0] = .{ .reg = .output, .comps = 4, .mode = .mask, .mask = @intCast(e.mask), .dims = 1, .idx = .{ e.reg, 0 } };
            var name: ?u32 = null;
            if (e.sys != 0 and e.sys < 64) {
                i.op = .dcl_output_siv;
                name = e.sys;
            }
            const at = o.n;
            ir.encodeInst(o, &i);
            if (name) |nm| {
                o.put(nm);
                c.code[at] += 1 << 24;
            }
        }
        if (ntemps > 0) {
            ir.encodeInst(o, &.{ .op = .dcl_temps, .ndst = 0 });
            o.buf[o.n - 1] += 1 << 24;
            o.put(ntemps);
        }
        if (t.stage == .geometry) {
            ir.encodeInst(o, &.{ .op = .dcl_max_output_vertex_count, .ndst = 0 });
            o.buf[o.n - 1] += 1 << 24;
            o.put(g.gs_max_vertex);
        }
    }

    fn interpMode(f: u32) u16 {
        if (f & ast.F_NOINTERP != 0) return 1;
        const np = f & ast.F_NOPERSP != 0;
        if (f & ast.F_SAMPLE != 0) return if (np) 7 else 6;
        if (f & ast.F_CENTROID != 0) return if (np) 5 else 3;
        return if (np) 4 else 2;
    }

    fn resElemTy(c: *Compiler, sym: u32) u32 {
        var t = c.ast.syms[sym].ty;
        while (c.ast.types[t].class == .array) t = c.ast.types[t].elem;
        return t;
    }

    // ── reflection ──

    fn reflection(c: *Compiler, t: gen.Target, fl: u32) void {
        const g = &c.g;
        const r = &c.refl;
        r.* = .{};
        const kind: u32 = switch (t.stage) {
            .vertex => 0xFFFE,
            .pixel => 0xFFFF,
            .geometry => 0x4753,
        };
        r.program = (kind << 16) | (@as(u32, t.major) << 8) | t.minor;
        r.flags = (fl & 0xffff) | 0x100;
        r.creator = CREATOR;
        // the bindings: samplers, textures, then constant buffers. An
        // array of them: Shader Model 5 binds each element read
        // ("name[i]"), 4 the array from its first register to the last
        // element read.
        var nnames: usize = 0;
        for ([_]u8{ 's', 't' }) |k| {
            var reg: u32 = 0;
            while (reg < 128) : (reg += 1) {
                for (g.res[0..g.nres]) |x| {
                    if (x.kind != k or x.slot != reg or !x.used or r.nbinds >= container.MAX_R) continue;
                    const sym = c.ast.syms[x.sym];
                    var name: []const u8 = c.ast.symName(x.sym);
                    var bind = reg;
                    var count: u32 = 1;
                    if (c.ast.types[sym.ty].class == .array) {
                        if (t.major >= 5) {
                            if (nnames < c.names.len) {
                                name = std.fmt.bufPrint(&c.names[nnames], "{s}[{d}]", .{ name, x.elem }) catch name;
                                nnames += 1;
                            }
                        } else {
                            // (once per array: at its lowest element read)
                            var first = true;
                            var top: u32 = 0;
                            for (g.res[0..g.nres]) |y| {
                                if (y.sym != x.sym or y.kind != k or !y.used) continue;
                                if (y.elem < x.elem) first = false;
                                top = @max(top, y.elem + 1);
                            }
                            if (!first) continue;
                            bind = reg - x.elem;
                            count = top;
                        }
                    }
                    const userpacked: u32 = if (sym.reg_kind == k) 1 else 0;
                    const ty = c.ast.types[resElemTy(c, x.sym)];
                    if (k == 's') {
                        r.binds[r.nbinds] = .{ .name = name, .type = 3, .bind = bind, .count = count, .flags = (if (ty.dim == 1) @as(u32, 2) else 0) | userpacked };
                    } else {
                        const et = c.ast.types[if (ty.elem == 0) c.ast.vector(.float, 4) else ty.elem];
                        const rt: u32 = switch (ast.canon(et.base)) {
                            .int => 3,
                            .uint, .bool => 4,
                            else => 5,
                        };
                        const ncomp: u32 = if (et.class == .vector) et.cols else 1;
                        const ms = ty.dim == @intFromEnum(ast.TexDim.tex2dms) or ty.dim == @intFromEnum(ast.TexDim.tex2dmsarray);
                        r.binds[r.nbinds] = .{ .name = name, .type = 2, .ret = rt, .dim = ty.dim, .samples = if (ms) ty.len else 0xffff_ffff, .bind = bind, .count = count, .flags = ((ncomp - 1) << 2) | userpacked };
                    }
                    r.nbinds += 1;
                }
            }
        }
        // constant buffers, by slot
        var cslot: u32 = 0;
        while (cslot < 16) : (cslot += 1) {
            for (g.cbs[0..g.ncbs]) |b| {
                if (b.slot != cslot or !b.used or r.nbinds >= container.MAX_R) continue;
                const name = if (b.sym == 0) "$Globals" else c.ast.symName(b.sym);
                r.binds[r.nbinds] = .{ .name = name, .type = if (b.tbuffer) 1 else 0, .bind = b.slot, .flags = if (b.userpacked) 1 else 0 };
                r.nbinds += 1;
            }
        }
        // (bindings in fxc's order: by type, then register)
        for (g.cbs[0..g.ncbs], 0..) |b, bi| {
            if (!b.used or r.nbufs >= r.bufs.len) continue;
            const first = r.nvars;
            if (b.sym == 0) {
                for (c.ast.globals[0..c.ast.nglobals]) |s| {
                    const sy = c.ast.syms[s];
                    if (sy.kind != .variable or sy.storage != .global or g.isObjectTy(sy.ty) or sy.flags & ast.F_STATIC != 0) continue;
                    c.addVar(s, bi);
                }
            } else {
                const sy = c.ast.syms[b.sym];
                for (0..sy.nparams) |k| c.addVar(c.ast.cbMember(b.sym, @intCast(k)), bi);
            }
            r.bufs[r.nbufs] = .{ .name = if (b.sym == 0) "$Globals" else c.ast.symName(b.sym), .first = first, .nvars = r.nvars - first, .size = b.size, .kind = if (b.tbuffer) 1 else 0 };
            r.nbufs += 1;
        }
    }

    fn addVar(c: *Compiler, s: u32, cb_index: usize) void {
        const g = &c.g;
        const r = &c.refl;
        if (r.nvars >= container.MAX_R) return;
        const bind = g.binds[s];
        const off = bind.val.off;
        const size = g.cbSize(c.ast.syms[s].ty);
        const used = c.varUsed(g.cbs[cb_index].slot, off, size);
        r.vars[r.nvars] = .{ .name = c.ast.symName(s), .offset = off, .size = size, .flags = if (used) 2 else 0, .ty = c.rtype(c.ast.syms[s].ty) };
        r.nvars += 1;
    }

    /// Whether any operand reads bytes [off, off+size) of the buffer in `slot`.
    fn varUsed(c: *Compiler, slot: u32, off: u32, size: u32) bool {
        for (c.prog.insts[0..c.prog.n]) |*i| {
            for (i.ops[0..i.n], 0..) |op, k| {
                if (k < i.ndst or op.reg != .cb or op.idx[0] != slot) continue;
                const row = op.idx[1];
                if (op.rel.on) {
                    // a dynamic index: the variable the base row is in
                    if (row * 16 >= off / 16 * 16 and row * 16 < off + size) return true;
                    continue;
                }
                const comps: u8 = ir.readMask(i, k);
                for (0..4) |cc| {
                    if (comps & (@as(u8, 1) << @intCast(cc)) == 0) continue;
                    const byte = row * 16 + @as(u32, @intCast(cc)) * 4;
                    if (byte >= off and byte < off + size) return true;
                }
            }
        }
        return false;
    }

    /// A reflection type for an Ast type.
    fn rtype(c: *Compiler, ty: u32) u32 {
        const r = &c.refl;
        const g = &c.g;
        const x = c.ast.types[ty];
        var nb: [32]u8 = undefined;
        switch (x.class) {
            .scalar, .vector, .matrix => {
                const vt: u16 = switch (ast.canon(x.base)) {
                    .bool => container.SVT.bool_,
                    .int => container.SVT.int,
                    .uint => container.SVT.uint,
                    .double => container.SVT.double,
                    else => container.SVT.float,
                };
                const class: u16 = switch (x.class) {
                    .scalar => container.SVC.scalar,
                    .vector => container.SVC.vector,
                    else => if (g.effPackPub(x) == .row) container.SVC.matrix_rows else container.SVC.matrix_columns,
                };
                const name = c.internName(c.ast.typeName(ty, &nb));
                return r.addType(.{ .class = class, .type = vt, .rows = x.rows, .cols = x.cols, .elements = 0, .name = name });
            },
            .array => {
                var len: u32 = x.len;
                var et = x.elem;
                while (c.ast.types[et].class == .array) {
                    len *= c.ast.types[et].len;
                    et = c.ast.types[et].elem;
                }
                const e = c.rtype(et);
                var t = r.types[e];
                t.elements = @intCast(len);
                return r.addType(t);
            },
            .structure => {
                const first = r.nmembers;
                if (r.nmembers + x.len > r.members.len) return 0;
                r.nmembers += x.len;
                for (0..x.len) |k| {
                    const m = c.ast.members[x.first + k];
                    r.members[first + k] = .{ .name = c.ast.name(m.name_off, m.name_len), .ty = c.rtype(m.ty), .offset = g.cbMemberOff(ty, k) };
                }
                return r.addType(.{ .class = container.SVC.structure, .type = container.SVT.void_, .rows = 1, .cols = @intCast(c.ast.comps(ty)), .elements = 0, .first = first, .nmembers = @intCast(x.len), .name = c.ast.name(x.name_off, x.name_len) });
            },
            else => return r.addType(.{ .class = container.SVC.object, .type = 0, .rows = 1, .cols = 1, .elements = 0 }),
        }
    }

    /// Type names live as long as the result: built-in names from a table.
    fn internName(c: *Compiler, s: []const u8) []const u8 {
        _ = c;
        for (type_names) |n| if (std.mem.eql(u8, n, s)) return n;
        return "";
    }

    fn stats(c: *Compiler, w: *container.W, t: gen.Target, ntemps: u32) void {
        // STAT: 29 counters (37 in Shader Model 5), what fxc reports
        var s = [_]u32{0} ** 37;
        var n_inst: u32 = 0;
        for (c.prog.insts[0..c.prog.n]) |i| {
            n_inst += 1;
            switch (i.op) {
                .add, .mul, .div, .mad, .min, .max, .dp2, .dp3, .dp4, .frc, .exp, .log, .rsq, .sqrt, .rcp, .round_ne, .round_ni, .round_pi, .round_z, .sincos, .eq, .ne, .lt, .ge => s[4] += 1,
                .iadd, .imul, .imad, .imax, .imin, .ineg, .ishl, .ishr, .ieq, .ine, .ilt, .ige => s[5] += 1,
                .udiv, .umax, .umin, .ushr, .ult, .uge, .@"and", .@"or", .xor, .not => s[6] += 1,
                .sample, .sample_b, .sample_c, .sample_c_lz, .sample_d, .sample_l, .gather4 => s[12] += 1,
                .ld, .ld_ms => s[13] += 1,
                .mov => s[19] += 1,
                .movc => s[20] += 1,
                .ftoi, .ftou, .itof, .utof => s[21] += 1,
                .@"if", .loop, .breakc, .@"break", .@"continue", .continuec => s[8] += 1,
                .emit => s[11] += 1,
                .cut => s[10] += 1,
                else => {},
            }
        }
        s[0] = n_inst;
        s[1] = ntemps;
        s[3] = c.g.nins + c.g.nouts;
        const nw: usize = if (t.major >= 5) 37 else 29;
        for (s[0..nw]) |x| w.u32_(x);
    }
};

const type_names = [_][]const u8{
    "float",    "float1",   "float2",   "float3",   "float4",   "int",      "int1",     "int2",     "int3",     "int4",
    "uint",     "uint1",    "uint2",    "uint3",    "uint4",    "bool",     "bool1",    "bool2",    "bool3",    "bool4",
    "float1x1", "float1x2", "float1x3", "float1x4", "float2x1", "float2x2", "float2x3", "float2x4", "float3x1", "float3x2",
    "float3x3", "float3x4", "float4x1", "float4x2", "float4x3", "float4x4", "half",     "half2",    "half3",    "half4",
    "int2x2",   "int3x3",   "int4x4",   "double",   "min16float", "min16int", "min16uint",
};

fn sortElems(e: []gen.Elem) void {
    std.sort.insertion(gen.Elem, e, {}, struct {
        fn lt(_: void, a: gen.Elem, b: gen.Elem) bool {
            if (a.reg != b.reg) return a.reg < b.reg;
            return @ctz(a.mask) < @ctz(b.mask);
        }
    }.lt);
}

fn gen_intrin_resDim(d: ast.TexDim) u32 {
    return @import("intrin.sig").resDim(d);
}

/// vs_4_0, ps_5_0, gs_4_1 ...
pub fn parseTarget(s: []const u8) ?gen.Target {
    if (s.len != 6 or s[2] != '_' or s[4] != '_') return null;
    const stage: gen.Stage = if (std.mem.startsWith(u8, s, "vs")) .vertex else if (std.mem.startsWith(u8, s, "ps")) .pixel else if (std.mem.startsWith(u8, s, "gs")) .geometry else return null;
    const major = s[3];
    const minor = s[5];
    if (major == '4' and (minor == '0' or minor == '1')) return .{ .stage = stage, .major = 4, .minor = minor - '0' };
    if (major == '5' and minor == '0') return .{ .stage = stage, .major = 5, .minor = 0 };
    return null;
}

fn predefine(p: *pp.Pp, t: gen.Target) void {
    // fxc's: the target's stage and version
    var b: [8]u8 = undefined;
    const stage: u32 = switch (t.stage) {
        .pixel => 0,
        .vertex => 1,
        .geometry => 2,
    };
    p.defineText("__SHADER_TARGET_STAGE", std.fmt.bufPrint(&b, "{d}", .{stage}) catch "0");
    p.defineText("__SHADER_TARGET_MAJOR", std.fmt.bufPrint(&b, "{d}", .{t.major}) catch "4");
    p.defineText("__SHADER_TARGET_MINOR", std.fmt.bufPrint(&b, "{d}", .{t.minor}) catch "0");
}

test {
    _ = lex;
    _ = pp;
    _ = ir;
    _ = container;
    _ = disasm;
    _ = @import("tests.sig");
}
