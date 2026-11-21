//! @zpm/hlsl — an HLSL compiler: HLSL (Shader Model 4 and 5 vertex, pixel
//! and geometry shaders; Shader Model 5 compute shaders) in, a DXBC
//! container out, as Microsoft's
//! D3DCompile makes them: the program (SHDR/SHEX), its input and output
//! signatures, its reflection (RDEF), the optional features it needs
//! (SFI0) and statistics (STAT), signed with
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
pub const mem = @import("mem.sig");

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
    /// a profile: vs_4_0, vs_4_1, vs_5_0, ps_*, gs_*, cs_5_0
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
            c.log.err(0, "invalid target '{s}' (vs_4_0, vs_4_1, vs_5_0, ps_*, gs_*, cs_5_0)", .{o.target});
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
        pruneBarriers(&c.prog);
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
        if (!c.placeCbSlots()) return null;
        if (!c.placeResources(t)) return null;
        if (!c.placeTgsm()) return null;
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
        // (SFI0: the optional features the program needs, when any)
        const sfi_at = w.n;
        const feats = c.features();
        if (feats != 0) {
            w.u32_(@truncate(feats));
            w.u32_(@truncate(feats >> 32));
        }
        const sfi_end = w.n;
        const stat_at = w.n;
        c.stats(&w, t, ntemps);
        const stat_end = w.n;
        if (w.over) {
            c.log.err(0, "shader too long", .{});
            return null;
        }
        const all = [_]container.Chunk{
            .{ .tag = "RDEF", .data = c.chunk[rdef_at..rdef_end] },
            .{ .tag = "ISGN", .data = c.chunk[isgn_at..isgn_end] },
            .{ .tag = "OSGN", .data = c.chunk[osgn_at..osgn_end] },
            .{ .tag = if (t.major >= 5) "SHEX" else "SHDR", .data = c.chunk[code_at..code_end] },
            .{ .tag = "SFI0", .data = c.chunk[sfi_at..sfi_end] },
            .{ .tag = "STAT", .data = c.chunk[stat_at..stat_end] },
        };
        var chunks: [all.len]container.Chunk = undefined;
        var nch: usize = 0;
        for (all) |ch| {
            if (std.mem.eql(u8, ch.tag, "SFI0") and ch.data.len == 0) continue;
            chunks[nch] = ch;
            nch += 1;
        }
        return container.container(&c.blob, chunks[0..nch]) orelse {
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
        for (g.tgsm[0..g.ntgsm]) |*x| x.used = false;
        for (c.prog.insts[0..c.prog.n]) |*i| {
            for (i.ops[0..i.n], 0..) |op, k| {
                // (UAVs and groupshared memory are written as destinations)
                if (op.reg == .uav) {
                    for (g.res[0..g.nres]) |*r| if (r.kind == 'u' and r.slot == op.idx[0]) {
                        r.used = true;
                    };
                }
                if (op.reg == .tgsm) {
                    for (g.tgsm[0..g.ntgsm]) |*x| if (x.reg == op.idx[0]) {
                        x.used = true;
                    };
                }
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

    /// Each implicitly placed constant buffer the code reads gets its real
    /// slot (the lowest one free, register(b#)'s reserved), and the code's
    /// operands follow; one never read gets none. False: more than 14.
    fn placeCbSlots(c: *Compiler) bool {
        const g = &c.g;
        var used_slots = g.cb_explicit;
        for (g.cbs[0..g.ncbs]) |*b| {
            if (!b.implicit or !b.used) continue;
            const slot = gen.Gen.lowestFree(used_slots);
            if (slot >= 14) {
                c.log.err(0, "maximum cbuffer exceeded. target has 14 slots", .{});
                return false;
            }
            used_slots |= @as(u32, 1) << @intCast(slot);
            const old = b.slot;
            b.slot = slot;
            for (c.prog.insts[0..c.prog.n]) |*i| {
                for (i.ops[0..i.n]) |*op| {
                    if (op.reg == .cb and op.idx[0] == old) op.idx[0] = slot;
                }
            }
        }
        return true;
    }

    fn regOfKind(kind: u8) ir.Reg {
        return switch (kind) {
            's' => .sampler,
            'u' => .uav,
            else => .resource,
        };
    }

    /// Rewrites operands of register type `reg` numbered `old` to `new`.
    fn renumber(c: *Compiler, reg: ir.Reg, old: u32, new: u32) void {
        for (c.prog.insts[0..c.prog.n]) |*i| {
            for (i.ops[0..i.n]) |*op| {
                if (op.reg == reg and op.idx[0] == old) op.idx[0] = new;
            }
        }
    }

    /// Each implicitly placed resource (s#, t#, u#) the code uses gets its
    /// register as fxc gives them: in the order declared, a variable (an
    /// array: all its elements) at the lowest free registers, register(x#)'s
    /// reserved, used or not. A pixel shader's UAVs come after its render
    /// targets. False: none free, or a register(u#) on a render target's.
    fn placeResources(c: *Compiler, t: gen.Target) bool {
        const g = &c.g;
        for ([_]u8{ 's', 't', 'u' }) |kind| {
            var taken = [_]bool{false} ** 128;
            const base: u32 = if (kind == 'u' and t.stage == .pixel) g.rt_count else 0;
            var s: u32 = 1;
            while (s < c.ast.nsyms) : (s += 1) {
                const sy = c.ast.syms[s];
                if (sy.kind != .variable or sy.reg_kind != kind or !g.isObjectTy(sy.ty)) continue;
                const cnt = g.arrayCount(sy.ty);
                for (sy.reg_index..@min(sy.reg_index + cnt, 128)) |k| taken[k] = true;
                if (kind == 'u' and sy.reg_index < base and c.symUsed(s, kind)) {
                    c.log.col = 0;
                    c.log.errCode(sy.line, 4509, "UAV registers live in the same name space as outputs, so they must be bound to at least u{d}, manual bind to slot u{d} failed", .{ base, sy.reg_index });
                    return false;
                }
            }
            s = 1;
            while (s < c.ast.nsyms) : (s += 1) {
                const sy = c.ast.syms[s];
                if (sy.reg_kind == kind or !c.symUsed(s, kind)) continue;
                const cnt = g.arrayCount(sy.ty);
                var b: u32 = base;
                while (b + cnt <= 128) : (b += 1) {
                    var free = true;
                    for (b..b + cnt) |k| free = free and !taken[k];
                    if (free) break;
                }
                if (b + cnt > 128) {
                    c.log.err(0, "too many resources", .{});
                    return false;
                }
                for (b..b + cnt) |k| taken[k] = true;
                for (g.res[0..g.nres]) |*r| {
                    if (r.sym != s or r.kind != kind) continue;
                    const slot = b + r.elem;
                    c.renumber(regOfKind(kind), r.slot, slot);
                    r.slot = slot;
                }
            }
        }
        return true;
    }

    fn symUsed(c: *Compiler, s: u32, kind: u8) bool {
        for (c.g.res[0..c.g.nres]) |r| if (r.sym == s and r.kind == kind and r.used) return true;
        return false;
    }

    /// The groupshared variables the code uses: g0, g1, ... in the order
    /// declared. False: more than the 32 KiB of a thread group.
    fn placeTgsm(c: *Compiler) bool {
        const g = &c.g;
        var next: u32 = 0;
        var total: u32 = 0;
        var s: u32 = 1;
        while (s < c.ast.nsyms) : (s += 1) {
            for (g.tgsm[0..g.ntgsm]) |*x| {
                if (x.sym != s or !x.used) continue;
                c.renumber(.tgsm, x.reg, next);
                x.reg = next;
                next += 1;
                total += x.stride * x.count;
            }
        }
        if (total > 32768) {
            c.log.errCode(0, 4586, "The total amount of group shared memory ({d} bytes) exceeds the {s} limit of 32768 bytes", .{ total, g.targetName() });
            return false;
        }
        return true;
    }

    /// SFI0's flags: typed UAV loads of more than one 32-bit component
    /// (0x800), UAVs past u7 (0x8).
    fn features(c: *Compiler) u64 {
        const g = &c.g;
        var f: u64 = 0;
        for (c.prog.insts[0..c.prog.n]) |i| {
            if (i.op != .ld_uav_typed) continue;
            for (g.res[0..g.nres]) |r| {
                if (r.kind != 'u' or r.slot != i.ops[2].idx[0]) continue;
                const et = c.ast.types[c.ast.types[resElemTy(c, r.sym)].elem];
                if (et.class == .vector and et.cols > 1) f |= 0x800;
            }
        }
        for (g.res[0..g.nres]) |r| {
            if (r.kind == 'u' and r.used and r.slot >= 8) f |= 0x8;
        }
        return f;
    }

    // ── declarations ──

    fn declarations(c: *Compiler, o: *ir.Out, t: gen.Target, ntemps: u32) void {
        const g = &c.g;
        if (t.major >= 5) {
            // (refactoringAllowed; [earlydepthstencil]: forceEarlyDepthStencil)
            const early: u16 = if (c.ast.syms[g.entry].flags & ast.F_EARLY_DEPTH != 0) 4 else 0;
            ir.encodeInst(o, &.{ .op = .dcl_global_flags, .ndst = 0, .ctl = 1 | early });
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
        // samplers, then textures and buffers, then UAVs, by register
        for ([_]u8{ 's', 't', 'u' }) |kind| {
            var r: u32 = 0;
            while (r < 128) : (r += 1) {
                for (g.res[0..g.nres]) |x| {
                    if (x.kind != kind or x.slot != r or !x.used) continue;
                    const ty = c.ast.types[resElemTy(c, x.sym)];
                    var i = ir.Inst{ .op = if (kind == 's') .dcl_sampler else .dcl_resource, .ndst = 0, .n = 1 };
                    if (kind == 'u' or ty.class == .sbuffer) {
                        c.declareBuffer(o, x, ty);
                    } else if (kind == 's') {
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
                        const rt = mem.objRet(&c.g, ty);
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
        if (t.stage == .compute) c.threadInputs(o);
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
        if (t.stage == .compute) {
            // groupshared memory by g#, then the thread group
            var r: u32 = 0;
            while (r < g.ntgsm) : (r += 1) {
                for (g.tgsm[0..g.ntgsm]) |x| {
                    if (x.reg != r or !x.used) continue;
                    var i = ir.Inst{ .op = if (x.structured) .dcl_tgsm_structured else .dcl_tgsm_raw, .ndst = 0, .n = 1 };
                    i.ops[0] = .{ .reg = .tgsm, .comps = 0, .dims = 1, .idx = .{ r, 0 } };
                    putWords(o, &i, if (x.structured) &.{ x.stride, x.count } else &.{x.stride});
                }
            }
            const th = c.ast.syms[g.entry].threads;
            putWords(o, &.{ .op = .dcl_thread_group, .ndst = 0 }, &th);
        }
    }

    /// A declaration followed by words of its own (sizes, counts).
    fn putWords(o: *ir.Out, i: *const ir.Inst, words: []const u32) void {
        const at = o.n;
        ir.encodeInst(o, i);
        for (words) |w| o.put(w);
        if (at < o.buf.len) o.buf[at] += @as(u32, @intCast(words.len)) << 24;
    }

    /// A UAV's or an SRV buffer's declaration: dcl_uav_typed (its
    /// dimension and return type), dcl_uav_structured / raw (globally
    /// coherent, with a counter), dcl_resource_structured / raw.
    fn declareBuffer(c: *Compiler, o: *ir.Out, x: gen.Res, ty: ast.Type) void {
        const sy = c.ast.syms[x.sym];
        const glc: u16 = if (sy.flags & ast.F_GLOBALLYCOHERENT != 0) 1 << 5 else 0;
        const uav = x.kind == 'u';
        var i = ir.Inst{ .op = .dcl_uav_typed, .ndst = 0, .n = 1 };
        i.ops[0] = .{ .reg = if (uav) .uav else .resource, .comps = 0, .dims = 1, .idx = .{ x.slot, 0 } };
        if (ty.class == .rwtexture) {
            i.ctl = @intCast(gen_intrin_resDim(@enumFromInt(ty.dim)) | glc);
            const g = &c.g;
            return putWords(o, &i, &.{mem.objRetToken(g, ty)});
        }
        const k: ast.BufKind = @enumFromInt(ty.dim);
        if (ast.bufStructured(k)) {
            const counter = k == .rw_structured and x.counter != 0;
            i.op = if (uav) .dcl_uav_structured else .dcl_resource_structured;
            if (uav) i.ctl = glc | (if (counter) @as(u16, 1) << 12 else 0);
            return putWords(o, &i, &.{mem.size(&c.g, ty.elem)});
        }
        i.op = if (uav) .dcl_uav_raw else .dcl_resource_raw;
        if (uav) i.ctl = glc;
        putWords(o, &i, &.{});
    }

    /// A compute shader's thread ids, each read (fxc's order: the
    /// flattened index, the group, the thread in the group, the thread).
    fn threadInputs(c: *Compiler, o: *ir.Out) void {
        const order = [_]ir.Reg{ .input_thread_id_in_group_flattened, .input_thread_group_id, .input_thread_id_in_group, .input_thread_id };
        for (order) |reg| {
            var mask: u4 = 0;
            for (c.prog.insts[0..c.prog.n]) |*ins| {
                for (ins.ops[0..ins.n], 0..) |op, k| {
                    if (op.reg == reg and k >= ins.ndst) mask |= ir.readMask(ins, k);
                }
            }
            if (mask == 0) continue;
            var i = ir.Inst{ .op = .dcl_input, .ndst = 0, .n = 1 };
            i.ops[0] = if (reg == .input_thread_id_in_group_flattened)
                .{ .reg = reg, .comps = 0, .dims = 0 }
            else
                .{ .reg = reg, .comps = 4, .mode = .mask, .mask = mask, .dims = 0 };
            ir.encodeInst(o, &i);
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
            .compute => 0x4353,
        };
        r.program = (kind << 16) | (@as(u32, t.major) << 8) | t.minor;
        r.flags = (fl & 0xffff) | 0x100;
        r.creator = CREATOR;
        // the bindings: samplers, textures and buffers, UAVs, then constant
        // buffers. An array of them: Shader Model 5 binds each element read
        // ("name[i]"), 4 the array from its first register to the last
        // element read.
        var nnames: usize = 0;
        // (structured buffers' bindings, described after the cbuffers)
        var sbs: [64]struct { bind: u32, sym: u32 } = undefined;
        var nsbs: usize = 0;
        for ([_]u8{ 's', 't', 'u' }) |k| {
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
                    if (k == 'u' or ty.class == .sbuffer) {
                        r.binds[r.nbinds] = c.bufferBinding(x, ty, name, bind, count, userpacked);
                        if (ty.class == .sbuffer and ast.bufStructured(@enumFromInt(ty.dim)) and nsbs < sbs.len) {
                            sbs[nsbs] = .{ .bind = r.nbinds, .sym = x.sym };
                            nsbs += 1;
                        }
                    } else if (k == 's') {
                        r.binds[r.nbinds] = .{ .name = name, .type = 3, .bind = bind, .count = count, .flags = (if (ty.dim == 1) @as(u32, 2) else 0) | userpacked };
                    } else {
                        const et = c.ast.types[if (ty.elem == 0) c.ast.vector(.float, 4) else ty.elem];
                        const rt = mem.objRet(&c.g, ty);
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
        // structured buffers: their element ($Element), laid out tightly
        for (sbs[0..nsbs]) |sb| {
            if (r.nbufs >= r.bufs.len or r.nvars >= container.MAX_R) break;
            const et = c.ast.types[resElemTy(c, sb.sym)].elem;
            const stride = mem.size(g, et);
            r.vars[r.nvars] = .{ .name = "$Element", .offset = 0, .size = stride, .flags = 2, .ty = c.rtypeIn(et, true) };
            r.bufs[r.nbufs] = .{ .name = r.binds[sb.bind].name, .first = r.nvars, .nvars = 1, .size = stride, .kind = 3 };
            r.nvars += 1;
            r.nbufs += 1;
        }
    }

    /// A UAV's or an SRV buffer's binding (D3D_SHADER_INPUT_TYPE: 4 typed
    /// UAV, 5 structured, 6 RW structured, 7 byte address, 8 RW byte
    /// address, 9 append, 10 consume, 11 RW structured with a counter).
    fn bufferBinding(c: *Compiler, x: gen.Res, ty: ast.Type, name: []const u8, bind: u32, count: u32, userpacked: u32) container.RBind {
        if (ty.class == .rwtexture) {
            const et = c.ast.types[ty.elem];
            const ncomp: u32 = if (et.class == .vector) et.cols else 1;
            return .{ .name = name, .type = 4, .ret = mem.objRet(&c.g, ty), .dim = ty.dim, .samples = 0xffff_ffff, .bind = bind, .count = count, .flags = ((ncomp - 1) << 2) | userpacked };
        }
        const k: ast.BufKind = @enumFromInt(ty.dim);
        const stride: u32 = if (ast.bufStructured(k)) mem.size(&c.g, ty.elem) else 0;
        const typ: u32 = switch (k) {
            .structured => 5,
            .rw_structured => if (x.counter != 0) 11 else 6,
            .byte_address => 7,
            .rw_byte_address => 8,
            .append => 9,
            .consume => 10,
        };
        return .{ .name = name, .type = typ, .ret = 6, .dim = 1, .samples = stride, .bind = bind, .count = count, .flags = userpacked };
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
        return c.rtypeIn(ty, false);
    }

    /// A reflection type, its members' offsets as constant buffers lay
    /// them out or (`tight`) as memory does.
    fn rtypeIn(c: *Compiler, ty: u32, tight: bool) u32 {
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
                // (fxc names a scalar uint "dword")
                const name = if (x.class == .scalar and x.base == .uint) "dword" else c.internName(c.ast.typeName(ty, &nb));
                return r.addType(.{ .class = class, .type = vt, .rows = x.rows, .cols = x.cols, .elements = 0, .name = name });
            },
            .array => {
                var len: u32 = x.len;
                var et = x.elem;
                while (c.ast.types[et].class == .array) {
                    len *= c.ast.types[et].len;
                    et = c.ast.types[et].elem;
                }
                const e = c.rtypeIn(et, tight);
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
                    r.members[first + k] = .{ .name = c.ast.name(m.name_off, m.name_len), .ty = c.rtypeIn(m.ty, tight), .offset = if (tight) mem.memberOff(g, ty, k) else g.cbMemberOff(ty, k) };
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
    "int2x2",   "int3x3",   "int4x4",   "double",   "min16float", "min16int", "min16uint", "dword",
};

fn sortElems(e: []gen.Elem) void {
    std.sort.insertion(gen.Elem, e, {}, struct {
        fn lt(_: void, a: gen.Elem, b: gen.Elem) bool {
            if (a.reg != b.reg) return a.reg < b.reg;
            return @ctz(a.mask) < @ctz(b.mask);
        }
    }.lt);
}

/// fxc drops a barrier when no memory of its kinds (groupshared memory,
/// UAVs) is touched both before and after it (inside a loop, the loop's
/// whole body is both).
fn pruneBarriers(p: *ir.Program) void {
    var w: u32 = 0;
    var k: u32 = 0;
    while (k < p.n) : (k += 1) {
        const i = p.insts[k];
        if (i.op == .sync and !barrierNeeded(p, k)) continue;
        p.insts[w] = i;
        w += 1;
    }
    p.n = w;
}

fn barrierNeeded(p: *const ir.Program, k: u32) bool {
    const fl = p.insts[k].ctl;
    // (the outermost loop around the barrier)
    var lo: u32 = k;
    var hi: u32 = k;
    var depth: i32 = 0;
    var j: u32 = k;
    while (j > 0) {
        j -= 1;
        switch (p.insts[j].op) {
            .endloop => depth += 1,
            .loop => if (depth == 0) {
                lo = j;
            } else {
                depth -= 1;
            },
            else => {},
        }
    }
    if (lo != k) {
        depth = 0;
        j = lo + 1;
        while (j < p.n) : (j += 1) {
            if (p.insts[j].op == .loop) depth += 1;
            if (p.insts[j].op == .endloop) {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        hi = j;
    }
    for ([_]struct { flag: u16, reg: ir.Reg }{ .{ .flag = ir.SYNC_TGSM, .reg = .tgsm }, .{ .flag = ir.SYNC_UAV_GLOBAL | ir.SYNC_UAV_GROUP, .reg = .uav } }) |kind| {
        if (fl & kind.flag == 0) continue;
        var before = false;
        var after = false;
        for (p.insts[0..p.n], 0..) |*x, at| {
            if (!touches(x, kind.reg)) continue;
            if (at < k or (at >= lo and at <= hi)) before = true;
            if (at > k or (at >= lo and at <= hi)) after = true;
        }
        if (before and after) return true;
    }
    return false;
}

/// Whether an instruction reads or writes memory of register type `reg`.
fn touches(i: *const ir.Inst, reg: ir.Reg) bool {
    const n = @intFromEnum(i.op);
    const access = n >= @intFromEnum(ir.Op.ld_uav_typed) and n <= @intFromEnum(ir.Op.imm_atomic_umin);
    if (!access) return false;
    for (i.ops[0..i.n]) |op| if (op.reg == reg) return true;
    return false;
}

fn gen_intrin_resDim(d: ast.TexDim) u32 {
    return @import("intrin.sig").resDim(d);
}

/// vs_4_0, ps_5_0, gs_4_1 ...
pub fn parseTarget(s: []const u8) ?gen.Target {
    if (s.len != 6 or s[2] != '_' or s[4] != '_') return null;
    const stage: gen.Stage = if (std.mem.startsWith(u8, s, "vs")) .vertex else if (std.mem.startsWith(u8, s, "ps")) .pixel else if (std.mem.startsWith(u8, s, "gs")) .geometry else if (std.mem.startsWith(u8, s, "cs")) .compute else return null;
    const major = s[3];
    const minor = s[5];
    // (compute: Shader Model 5's; cs_4_x's one-UAV subset is not made)
    if (stage == .compute) return if (major == '5' and minor == '0') .{ .stage = .compute, .major = 5, .minor = 0 } else null;
    if (major == '4' and (minor == '0' or minor == '1')) return .{ .stage = stage, .major = 4, .minor = minor - '0' };
    if (major == '5' and minor == '0') return .{ .stage = stage, .major = 5, .minor = 0 };
    return null;
}

fn predefine(p: *pp.Pp, t: gen.Target) void {
    // fxc's: the target's stage and version
    var b: [8]u8 = undefined;
    const stage: u32 = @intFromEnum(t.stage);
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
    _ = mem;
    _ = @import("tests.sig");
}
