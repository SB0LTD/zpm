//! @zpm/hlsl gen — the Ast to DXBC instructions: an entry point and every
//! function it calls, inlined (HLSL has no recursion), into ir.Program.
//!
//! - **Values.** An expression's value is a list of register rows (Src):
//!   a temp, an input, a constant buffer's row, an immediate; a vector is
//!   one row read through a swizzle, a matrix its rows (or its columns,
//!   when it comes column-major from a constant buffer: transpose is then
//!   free), a struct or array its members' rows. Constant buffer variables
//!   stay as (slot, offset) until a row is read, so indexing an array of a
//!   thousand vectors costs one operand. Immediates fold at compile time
//!   (static consts, sampler indices, loop bounds).
//! - **Variables** are virtual temps, one per row; locals that are never
//!   assigned are their initializer (no copy).
//! - **Flow.** if/else, for/while/do with break and continue, switch as a
//!   loop that runs once (its cases tested in order, falling through),
//!   early returns as a break out of a once-loop around the inlined body,
//!   with a flag carried out of inner loops. No `ret` inside flow: what
//!   zpm's DXBC front end runs.
//! - **Interface.** The entry's parameters and return value (structs
//!   flattened) are the input and output signatures; `uniform` globals are
//!   $Globals; cbuffers and resources keep their registers (or get the
//!   lowest free); reflection is built from what the code still reads
//!   after dead code is gone.

const std = @import("std");
const ast = @import("ast.sig");
const ir = @import("ir.sig");
const lex = @import("lex.sig");
const pp = @import("pp.sig");
const ct = @import("container.sig");
const intrin = @import("intrin.sig");

const Ast = ast.Ast;
const NONE = ast.NONE;
const Reg = ir.Reg;
const Op = ir.Op;

pub const Stage = enum(u8) { pixel = 0, vertex = 1, geometry = 2 };

pub const Target = struct { stage: Stage, major: u8, minor: u8 };

// D3DCOMPILE_* flags the generator reads
pub const PACK_ROW_MAJOR: u32 = 1 << 3;
pub const PACK_COLUMN_MAJOR: u32 = 1 << 4;
pub const ENABLE_BACKWARDS_COMPATIBILITY: u32 = 1 << 12;

pub const MAX_SRCS = 1 << 18;
pub const MAX_LOCS = 1 << 16;
pub const MAX_VREGS = 1 << 18;
const MAX_CB = 16;
const MAX_RES = 256;
pub const MAX_ICB = 4096;
const MAX_ELEMS = 64;
const MAX_FLOW = 64;

// ── values ─────────────────────────────────────────────────────────────────

/// One register row of a value.
pub const Src = struct {
    reg: Reg = .imm32,
    /// temps: the virtual temp; inputs: v#; cb: the slot
    idx: u32 = 0,
    /// cb, icb: the row; GS inputs: the register (idx is the vertex)
    row: u32 = 0,
    swz: [4]u2 = .{ 0, 1, 2, 3 },
    /// logical components (1-4)
    n: u8 = 1,
    /// float modifiers: 1 neg, 2 abs, 3 both (abs first)
    mods: u2 = 0,
    /// a relative index on the row (cb, icb)
    rel: ir.Rel = .{},
    imm: [4]u32 = .{ 0, 0, 0, 0 },
    /// a matrix's column (else a row)
    col: bool = false,
    /// GS inputs: 2D (v[vertex][reg])
    gs: bool = false,
};

pub const ValKind = enum(u8) { srcs, cb, object, none };

pub const Val = struct {
    ty: u32,
    kind: ValKind = .srcs,
    at: u32 = 0,
    n: u32 = 0,
    /// cb: slot, byte offset, and a row offset register (rel)
    slot: u32 = 0,
    off: u32 = 0,
    rel: ir.Rel = .{},
    /// objects: the resource variable and the element (arrays of them)
    sym: u32 = 0,
    elem: u32 = 0,
};

/// A row a store writes: the temp and the component each logical
/// component goes to.
pub const Loc = struct { vreg: u32, n: u8, comp: [4]u2 = .{ 0, 1, 2, 3 } };

pub const LVal = struct {
    ty: u32,
    at: u32 = 0,
    n: u32 = 0,
    /// a dynamic index: the rows of every element (count of them, `per`
    /// rows each), the one written chosen by `dyn_idx`
    dyn: bool = false,
    dyn_idx: Src = .{},
    dyn_count: u32 = 0,
    dyn_per: u32 = 0,
};

const BindKind = enum(u8) { none, regs, val, cb, object, gs_input, stream };

pub const Bind = struct {
    kind: BindKind = .none,
    /// regs: the first virtual temp (one per row)
    base: u32 = 0,
    val: Val = .{ .ty = 0, .kind = .none },
};

const CB = struct {
    /// the cbuffer's symbol (0: $Globals)
    sym: u32,
    slot: u32,
    size: u32 = 0,
    used: bool = false,
    rows: u32 = 0,
    dynamic: bool = false,
    tbuffer: bool = false,
    userpacked: bool = false,
};

const Res = struct {
    sym: u32,
    elem: u32,
    /// 't' or 's'
    kind: u8,
    slot: u32,
    used: bool = false,
};

pub const Elem = struct {
    name: []const u8,
    index: u32,
    sys: u32,
    /// D3D_REGISTER_COMPONENT_TYPE
    comp: u32,
    reg: u32,
    mask: u8,
    /// inputs: components read; outputs: components written
    used: u8 = 0,
    flags: u32 = 0,
    /// outputs: the virtual temp holding it (written at the end)
    vreg: u32 = 0,
    /// oDepth / oMask / vCoverage and such: not o#/v#
    special: Reg = .null,
    stream: u32 = 0,
};

const FlowKind = enum(u8) { loop, switch_wrap, func_wrap };

const Flow = struct {
    kind: FlowKind,
    /// for: the step expression; do: the condition (re-tested on continue)
    step: u32 = NONE,
    cond: u32 = NONE,
    /// switch wrappers: a flag set by `continue` inside (none: no flag)
    cont_flag: u32 = 0xffff_ffff,
};

const FnCtx = struct {
    ret_ty: u32,
    /// the return value's rows (none: direct)
    ret_base: u32 = 0,
    ret_rows: u32 = 0,
    direct: bool = false,
    direct_val: Val = .{ .ty = 0, .kind = .none },
    wrapped: bool = false,
    /// set by a return from inside inner loops
    ret_flag: u32 = 0xffff_ffff,
    flow_base: usize = 0,
    sym: u32,
};

pub const Gen = struct {
    a: *Ast,
    p: *ir.Program,
    log: *pp.Log,
    toks: []const lex.Token,
    target: Target,
    flags: u32 = 0,
    srcs: *[MAX_SRCS]Src,
    nsrcs: u32 = 0,
    locs: *[MAX_LOCS]Loc,
    nlocs: u32 = 0,
    binds: *[ast.MAX_SYMS]Bind,
    /// per virtual temp: 1 when it belongs to a variable
    vflags: *[MAX_VREGS]u8,
    cbs: [MAX_CB]CB = undefined,
    ncbs: u32 = 0,
    res: [MAX_RES]Res = undefined,
    nres: u32 = 0,
    icb: [MAX_ICB]u32 = undefined,
    nicb: u32 = 0,
    ins: [MAX_ELEMS]Elem = undefined,
    nins: u32 = 0,
    outs: [MAX_ELEMS]Elem = undefined,
    nouts: u32 = 0,
    flow: [MAX_FLOW]Flow = undefined,
    nflow: usize = 0,
    fns: [64]FnCtx = undefined,
    nfns: usize = 0,
    failed: bool = false,
    cur_line: u32 = 0,
    /// GS: the input primitive, output topology, max vertices
    gs_input_prim: u32 = 0,
    gs_output_topo: u32 = 0,
    gs_max_vertex: u32 = 0,
    gs_in_vertices: u32 = 0,
    /// the entry's symbol
    entry: u32 = 0,
    /// whether derivatives / sample are used (statistics)
    globals_cb: u32 = 0xffff_ffff,

    // ── errors ──

    pub fn fail(g: *Gen, comptime fmt: []const u8, args: anytype) void {
        if (!g.failed) g.log.err(g.cur_line, fmt, args);
        g.failed = true;
    }

    fn locate(g: *Gen, n: u32) void {
        const t = g.a.nodes[n].tok;
        if (t < g.toks.len) g.cur_line = g.toks[t].line();
    }

    pub fn tokText(g: *const Gen, t: u32) []const u8 {
        const tk = g.toks[@min(t, g.toks.len - 1)];
        return g.a.pool[tk.off..][0..tk.len];
    }

    // ── types ──

    pub fn ty(g: *const Gen, t: u32) ast.Type {
        return g.a.types[t];
    }

    pub fn baseOf(g: *const Gen, t: u32) ast.Base {
        return ast.canon(g.a.types[t].base);
    }

    pub fn effPackPub(g: *const Gen, t: ast.Type) ast.Pack {
        return g.effPack(t);
    }

    fn effPack(g: *const Gen, t: ast.Type) ast.Pack {
        if (t.pack != .default) return t.pack;
        if (g.flags & PACK_ROW_MAJOR != 0) return .row;
        return .column;
    }

    /// Canonical rows: a vector 1, a matrix its rows, a struct and an
    /// array their members' and elements'.
    pub fn rowsOf(g: *const Gen, t: u32) u32 {
        const x = g.a.types[t];
        return switch (x.class) {
            .scalar, .vector => 1,
            .matrix => x.rows,
            .array => x.len * g.rowsOf(x.elem),
            .structure => blk: {
                var n: u32 = 0;
                for (0..x.len) |k| n += g.rowsOf(g.a.members[x.first + k].ty);
                break :blk n;
            },
            else => 0,
        };
    }

    /// The components of canonical row `r` and its scalar type.
    pub fn rowInfo(g: *const Gen, t: u32, r: u32) struct { n: u8, base: ast.Base } {
        const x = g.a.types[t];
        switch (x.class) {
            .scalar, .vector => return .{ .n = x.cols, .base = ast.canon(x.base) },
            .matrix => return .{ .n = x.cols, .base = ast.canon(x.base) },
            .array => {
                const per = g.rowsOf(x.elem);
                return g.rowInfo(x.elem, if (per == 0) 0 else r % per);
            },
            .structure => {
                var rr = r;
                for (0..x.len) |k| {
                    const m = g.a.members[x.first + k].ty;
                    const n = g.rowsOf(m);
                    if (rr < n) return g.rowInfo(m, rr);
                    rr -= n;
                }
                return .{ .n = 1, .base = .float };
            },
            else => return .{ .n = 1, .base = .float },
        }
    }

    pub fn isObjectTy(g: *const Gen, t: u32) bool {
        var x = g.a.types[t];
        while (x.class == .array) x = g.a.types[x.elem];
        return x.class == .texture or x.class == .sampler or x.class == .rwtexture or x.class == .sbuffer or x.class == .stream;
    }

    // ── constant buffer layout (HLSL's packing) ──

    /// A type's size in a constant buffer (bytes; arrays' last element
    /// unpadded).
    pub fn cbSize(g: *const Gen, t: u32) u32 {
        const x = g.a.types[t];
        return switch (x.class) {
            .scalar => 4,
            .vector => 4 * @as(u32, x.cols),
            .matrix => if (g.effPack(x) == .row) (@as(u32, x.rows) - 1) * 16 + 4 * @as(u32, x.cols) else (@as(u32, x.cols) - 1) * 16 + 4 * @as(u32, x.rows),
            .array => if (x.len == 0) 0 else (x.len - 1) * g.cbStride(x.elem) + g.cbSize(x.elem),
            .structure => blk: {
                var off: u32 = 0;
                for (0..x.len) |k| {
                    const m = g.a.members[x.first + k].ty;
                    off = g.cbPlace(off, m) + g.cbSize(m);
                }
                break :blk off;
            },
            else => 0,
        };
    }

    /// An array element's stride (16-byte rows).
    pub fn cbStride(g: *const Gen, t: u32) u32 {
        return (g.cbSize(t) + 15) / 16 * 16;
    }

    /// Where a member of type `t` goes after `off` bytes: arrays, matrices
    /// and structs start a row; others start one when they would cross it.
    pub fn cbPlace(g: *const Gen, off: u32, t: u32) u32 {
        const x = g.a.types[t];
        if (x.class == .array or x.class == .matrix or x.class == .structure) return (off + 15) / 16 * 16;
        const size = g.cbSize(t);
        if (off / 16 != (off + size - 1) / 16) return (off + 15) / 16 * 16;
        return off;
    }

    /// A struct member's offset in a constant buffer.
    pub fn cbMemberOff(g: *const Gen, st: u32, k: usize) u32 {
        const x = g.a.types[st];
        var off: u32 = 0;
        for (0..x.len) |j| {
            const m = g.a.members[x.first + j].ty;
            off = g.cbPlace(off, m);
            if (j == k) return off;
            off += g.cbSize(m);
        }
        return off;
    }

    // ── pools ──

    pub fn newSrcs(g: *Gen, n: u32) u32 {
        if (g.nsrcs + n > MAX_SRCS) {
            g.fail("shader too complex (values)", .{});
            g.nsrcs = 0;
            return 0;
        }
        const s = g.nsrcs;
        g.nsrcs += n;
        return s;
    }

    pub fn src(g: *Gen, v: Val, k: u32) *Src {
        return &g.srcs[v.at + k];
    }

    pub fn vreg(g: *Gen) u32 {
        if (g.p.nvregs >= MAX_VREGS) {
            g.fail("shader too complex (temps)", .{});
            return 0;
        }
        const v = g.p.vreg();
        g.vflags[v] = 0;
        return v;
    }

    pub fn vregs(g: *Gen, n: u32) u32 {
        const b = g.p.nvregs;
        for (0..n) |_| _ = g.vreg();
        return b;
    }

    /// A value of `t` from `n` rows starting at `first` (srcs).
    pub fn mkVal(t: u32, first: u32, n: u32) Val {
        return .{ .ty = t, .at = first, .n = n };
    }

    pub fn imm1(v: u32) Src {
        return .{ .reg = .imm32, .n = 1, .imm = .{ v, v, v, v } };
    }

    pub fn immVal(g: *Gen, t: u32, v: u32) Val {
        const s = g.newSrcs(1);
        const n: u8 = @intCast(@max(g.a.types[t].cols, 1));
        g.srcs[s] = .{ .reg = .imm32, .n = n, .imm = .{ v, v, v, v } };
        return mkVal(t, s, 1);
    }

    pub fn tempSrc(v: u32, n: u8) Src {
        return .{ .reg = .temp, .idx = v, .n = n };
    }

    pub fn scalarTy(g: *Gen, b: ast.Base) u32 {
        return g.a.scalar(b);
    }

    // ── emitting ──

    pub fn emit(g: *Gen, i: ir.Inst) void {
        if (g.failed) return;
        if (!g.p.add(i)) g.fail("shader too long (instructions)", .{});
    }

    /// An operand reading `s` for a destination whose logical component k
    /// is at `map[k]` (n of them).
    pub fn opnd(g: *Gen, s0: Src, map: [4]u2, n: u8) ir.Opnd {
        _ = g;
        const s = s0;
        if (s.reg == .imm32) {
            if (n == 1 and map[0] == 0) return .{ .reg = .imm32, .comps = 1, .imm = .{ s.imm[0], 0, 0, 0 } };
            var o = ir.Opnd{ .reg = .imm32, .comps = 4, .imm = .{ 0, 0, 0, 0 } };
            for (0..n) |k| o.imm[map[k]] = if (s.n == 1) s.imm[0] else s.imm[k];
            return o;
        }
        var o = ir.Opnd{ .reg = s.reg, .comps = 4, .mode = .swizzle, .mods = s.mods };
        var sw: [4]u2 = .{ s.swz[0], s.swz[0], s.swz[0], s.swz[0] };
        for (0..n) |k| sw[map[k]] = if (s.n == 1) s.swz[0] else s.swz[k];
        o.swz = sw;
        switch (s.reg) {
            .cb => {
                o.dims = 2;
                o.idx = .{ s.idx, s.row };
                if (s.rel.on) {
                    o.rel = s.rel;
                    o.rel_dim = 1;
                }
            },
            .icb => {
                o.dims = 1;
                o.idx = .{ s.row, 0 };
                if (s.rel.on) {
                    o.rel = s.rel;
                    o.rel_dim = 0;
                }
            },
            .input => {
                if (s.gs) {
                    o.dims = 2;
                    o.idx = .{ s.idx, s.row };
                    if (s.rel.on) {
                        o.rel = s.rel;
                        o.rel_dim = 0;
                    }
                } else {
                    o.dims = 1;
                    o.idx = .{ s.idx, 0 };
                }
            },
            .input_primitive_id, .input_coverage_mask => {
                o.dims = 0;
                o.comps = 1;
            },
            else => {
                o.dims = 1;
                o.idx = .{ s.idx, 0 };
            },
        }
        return o;
    }

    const ident4: [4]u2 = .{ 0, 1, 2, 3 };

    pub fn dstOpnd(v: u32, map: [4]u2, n: u8) ir.Opnd {
        var mask: u4 = 0;
        for (0..n) |k| mask |= @as(u4, 1) << map[k];
        return .{ .reg = .temp, .comps = 4, .mode = .mask, .mask = mask, .idx = .{ v, 0 } };
    }

    /// `op` over n components into a new temp (folded when every source is
    /// an immediate and the op folds).
    pub fn alu(g: *Gen, op: Op, n: u8, s: []const Src) Src {
        return g.aluSat(op, n, s, false);
    }

    pub fn aluSat(g: *Gen, op: Op, n: u8, s: []const Src, sat: bool) Src {
        var all_imm = true;
        for (s) |x| all_imm = all_imm and x.reg == .imm32;
        if (all_imm) {
            if (foldN(op, n, s, sat)) |r| return r;
        }
        const v = g.vreg();
        var i = ir.Inst{ .op = op, .n = @intCast(1 + s.len), .ctl = if (sat) ir.CTL_SAT else 0 };
        i.ops[0] = dstOpnd(v, ident4, n);
        var at: usize = 1;
        if (op == .imul or op == .umul) {
            // (the high half to null, the low half kept)
            i.ops[0] = .{ .reg = .null, .comps = 0, .dims = 0 };
            i.ops[1] = dstOpnd(v, ident4, n);
            i.ndst = 2;
            i.n += 1;
            at = 2;
        }
        for (s, 0..) |x, k| i.ops[at + k] = g.opnd(x, ident4, n);
        g.emit(i);
        return tempSrc(v, n);
    }

    /// `op` into a stored row (its components as `loc` maps them).
    pub fn aluInto(g: *Gen, op: Op, loc: Loc, s: []const Src) void {
        var i = ir.Inst{ .op = op, .n = @intCast(1 + s.len) };
        i.ops[0] = dstOpnd(loc.vreg, loc.comp, loc.n);
        for (s, 0..) |x, k| i.ops[1 + k] = g.opnd(x, loc.comp, loc.n);
        g.emit(i);
    }

    /// A source without float modifiers (a mov when it has them).
    pub fn plain(g: *Gen, s: Src) Src {
        if (s.mods == 0) return s;
        var x = s;
        if (x.reg == .imm32) {
            for (&x.imm) |*w| w.* = applyMods(w.*, s.mods);
            x.mods = 0;
            return x;
        }
        return g.alu(.mov, s.n, &.{s});
    }

    /// A source in a temp, an immediate or an input (not a cb row: for
    /// relative indices and conditions that need a temp).
    pub fn inTemp(g: *Gen, s: Src) Src {
        if (s.reg == .temp and s.mods == 0) return s;
        return g.alu(.mov, s.n, &.{s});
    }

    pub fn component(s: Src, c: u32) Src {
        var x = s;
        if (s.reg == .imm32) {
            const v = if (s.n == 1) s.imm[0] else s.imm[c];
            x.imm = .{ v, v, v, v };
        } else {
            const w = if (s.n == 1) s.swz[0] else s.swz[c];
            x.swz = .{ w, w, w, w };
        }
        x.n = 1;
        return x;
    }

    // ── values: reading ──

    /// The value's rows as Srcs (a constant buffer's read now).
    pub fn rows(g: *Gen, v: Val) Val {
        if (v.kind == .srcs) return v;
        if (v.kind == .cb) {
            const n = g.cbRowCount(v.ty);
            const first = g.newSrcs(n);
            var k: u32 = 0;
            g.cbRows(v.ty, v.slot, v.off, v.rel, first, &k);
            return mkVal(v.ty, first, n);
        }
        g.fail("an object used as a value", .{});
        return g.immVal(g.scalarTy(.float), 0);
    }

    /// Rows a constant buffer value reads: a column-major matrix gives its
    /// columns.
    fn cbRowCount(g: *const Gen, t: u32) u32 {
        const x = g.a.types[t];
        return switch (x.class) {
            .matrix => if (g.effPack(x) == .row) x.rows else x.cols,
            .array => x.len * g.cbRowCount(x.elem),
            .structure => blk: {
                var n: u32 = 0;
                for (0..x.len) |k| n += g.cbRowCount(g.a.members[x.first + k].ty);
                break :blk n;
            },
            else => 1,
        };
    }

    fn cbRows(g: *Gen, t: u32, slot: u32, off: u32, rel: ir.Rel, first: u32, k: *u32) void {
        const x = g.a.types[t];
        switch (x.class) {
            .scalar, .vector => {
                const c: u2 = @intCast((off % 16) / 4);
                var s = Src{ .reg = .cb, .idx = slot, .row = off / 16, .n = x.cols, .rel = rel };
                for (0..4) |j| s.swz[j] = @intCast(@min(@as(u32, c) + j, 3));
                g.srcs[first + k.*] = s;
                k.* += 1;
            },
            .matrix => {
                const rowm = g.effPack(x) == .row;
                const nr: u32 = if (rowm) x.rows else x.cols;
                for (0..nr) |r| {
                    g.srcs[first + k.*] = .{ .reg = .cb, .idx = slot, .row = off / 16 + @as(u32, @intCast(r)), .n = if (rowm) x.cols else x.rows, .rel = rel, .col = !rowm };
                    k.* += 1;
                }
            },
            .array => {
                const st = g.cbStride(x.elem);
                for (0..x.len) |e| g.cbRows(x.elem, slot, off + @as(u32, @intCast(e)) * st, rel, first, k);
            },
            .structure => {
                for (0..x.len) |m| g.cbRows(g.a.members[x.first + m].ty, slot, off + g.cbMemberOff(t, m), rel, first, k);
            },
            else => {},
        }
    }

    /// Canonical rows (a column-major matrix's rows gathered).
    pub fn canonRows(g: *Gen, v0: Val) Val {
        const v = g.rows(v0);
        if (!g.hasCols(v)) return v;
        const x = g.a.types[v.ty];
        if (x.class == .matrix) return g.matRows(v);
        // a struct or array holding column-major matrices: each leaf
        const n = g.rowsOf(v.ty);
        const first = g.newSrcs(n);
        var k: u32 = 0;
        var at: u32 = 0;
        g.canonInto(v.ty, v, &at, first, &k);
        return mkVal(v.ty, first, n);
    }

    fn canonInto(g: *Gen, t: u32, v: Val, at: *u32, first: u32, k: *u32) void {
        const x = g.a.types[t];
        switch (x.class) {
            .matrix => {
                const isc = g.srcs[v.at + at.*].col;
                const cnt: u32 = if (isc) x.cols else x.rows;
                const sub = mkVal(t, v.at + at.*, cnt);
                const r = if (isc) g.matRows(sub) else sub;
                for (0..x.rows) |j| g.srcs[first + k.* + j] = g.srcs[r.at + j];
                k.* += x.rows;
                at.* += cnt;
            },
            .array => for (0..x.len) |_| g.canonInto(x.elem, v, at, first, k),
            .structure => for (0..x.len) |m| g.canonInto(g.a.members[x.first + m].ty, v, at, first, k),
            else => {
                g.srcs[first + k.*] = g.srcs[v.at + at.*];
                k.* += 1;
                at.* += 1;
            },
        }
    }

    pub fn hasCols(g: *Gen, v: Val) bool {
        for (0..v.n) |k| if (g.srcs[v.at + k].col) return true;
        return false;
    }

    /// A matrix value's rows.
    pub fn matRows(g: *Gen, v0: Val) Val {
        const v = g.rows(v0);
        const x = g.a.types[v.ty];
        if (v.n == 0 or !g.srcs[v.at].col) return v;
        // columns: row r = (col0[r], col1[r], ...)
        const first = g.newSrcs(x.rows);
        for (0..x.rows) |r| {
            var sc: [4]Src = undefined;
            for (0..x.cols) |c| sc[c] = component(g.srcs[v.at + c], @intCast(r));
            g.srcs[first + r] = g.pack(sc[0..x.cols]);
        }
        return mkVal(v.ty, first, x.rows);
    }

    /// A matrix value's columns (marked col).
    pub fn matCols(g: *Gen, v0: Val) Val {
        const v = g.rows(v0);
        const x = g.a.types[v.ty];
        if (v.n > 0 and g.srcs[v.at].col) return v;
        const first = g.newSrcs(x.cols);
        for (0..x.cols) |c| {
            var sc: [4]Src = undefined;
            for (0..x.rows) |r| sc[r] = component(g.srcs[v.at + r], @intCast(c));
            var s = g.pack(sc[0..x.rows]);
            s.col = true;
            g.srcs[first + c] = s;
        }
        return mkVal(v.ty, first, x.cols);
    }

    /// Scalars packed into one row: an immediate, a swizzle of one
    /// register, or movs into a new temp.
    pub fn pack(g: *Gen, sc: []const Src) Src {
        const n: u8 = @intCast(sc.len);
        var all_imm = true;
        for (sc) |s| all_imm = all_imm and s.reg == .imm32;
        if (all_imm) {
            var r = Src{ .reg = .imm32, .n = n };
            for (sc, 0..) |s, k| r.imm[k] = applyMods(s.imm[0], s.mods);
            for (sc.len..4) |k| r.imm[k] = r.imm[0];
            return r;
        }
        if (sameReg(sc)) {
            var r = sc[0];
            r.n = n;
            r.col = false;
            for (sc, 0..) |s, k| r.swz[k] = s.swz[0];
            return r;
        }
        const v = g.vreg();
        var k: usize = 0;
        while (k < sc.len) {
            // a run of components from one register
            var e = k + 1;
            while (e < sc.len and sameReg2(sc[k], sc[e])) e += 1;
            var map: [4]u2 = undefined;
            var s = sc[k];
            for (k..e, 0..) |j, m| {
                map[m] = @intCast(j);
                if (s.reg == .imm32) s.imm[m] = sc[j].imm[0] else s.swz[m] = sc[j].swz[0];
            }
            s.n = @intCast(e - k);
            g.aluInto(.mov, .{ .vreg = v, .n = @intCast(e - k), .comp = map }, &.{s});
            k = e;
        }
        return tempSrc(v, n);
    }

    fn sameReg2(a: Src, b: Src) bool {
        if (a.reg != b.reg or a.mods != b.mods) return false;
        if (a.reg == .imm32) return true;
        return a.idx == b.idx and a.row == b.row and a.rel.on == b.rel.on and a.rel.idx == b.rel.idx and a.rel.comp == b.rel.comp and a.rel.reg == b.rel.reg and a.gs == b.gs;
    }

    fn sameReg(sc: []const Src) bool {
        for (sc[1..]) |s| if (s.reg == .imm32 or !sameReg2(sc[0], s)) return false;
        return sc[0].reg != .imm32;
    }

    /// Every scalar of a value, in order (matrices row by row).
    pub fn flatten(g: *Gen, v0: Val, out: []Src) usize {
        const v = g.canonRows(v0);
        var n: usize = 0;
        for (0..v.n) |k| {
            const s = g.srcs[v.at + k];
            for (0..s.n) |c| {
                if (n >= out.len) {
                    g.fail("too many components", .{});
                    return n;
                }
                out[n] = component(s, @intCast(c));
                n += 1;
            }
        }
        return n;
    }

    /// A value of type `t` from scalars (already of `t`'s bases).
    pub fn build(g: *Gen, t: u32, sc: []const Src) Val {
        const n = g.rowsOf(t);
        const first = g.newSrcs(n);
        var at: usize = 0;
        for (0..n) |r| {
            const info = g.rowInfo(t, @intCast(r));
            if (at + info.n > sc.len) {
                g.fail("not enough values to build a {s}", .{g.tyName(t)});
                return mkVal(t, first, n);
            }
            g.srcs[first + r] = g.pack(sc[at .. at + info.n]);
            at += info.n;
        }
        return mkVal(t, first, n);
    }

    pub fn tyName(g: *const Gen, t: u32) []const u8 {
        const S = struct {
            var buf: [32]u8 = undefined;
        };
        return g.a.typeName(t, &S.buf);
    }

    // ── conversions ──

    /// `v` as type `to` (HLSL's implicit and explicit conversions).
    pub fn convert(g: *Gen, v0: Val, to: u32) Val {
        if (v0.ty == to) return v0;
        const from = g.a.types[v0.ty];
        const dst = g.a.types[to];
        if (v0.kind == .object or g.isObjectTy(to)) {
            if (v0.kind == .object and g.isObjectTy(to)) {
                var r = v0;
                r.ty = to;
                return r;
            }
            g.fail("cannot convert between objects and values", .{});
            return g.immVal(to, 0);
        }
        const fnum = from.class == .scalar or from.class == .vector or from.class == .matrix;
        const tnum = dst.class == .scalar or dst.class == .vector or dst.class == .matrix;
        if (fnum and tnum) return g.convertNum(v0, to);
        // a scalar to a struct or array: every scalar
        if (from.class == .scalar and (dst.class == .structure or dst.class == .array)) {
            const v = g.rows(v0);
            const n = g.rowsOf(to);
            const first = g.newSrcs(n);
            for (0..n) |r| {
                const info = g.rowInfo(to, @intCast(r));
                const c = g.convertSrc(g.srcs[v.at], g.baseOf(v.ty), info.base, info.n);
                g.srcs[first + r] = c;
            }
            return mkVal(to, first, n);
        }
        // same shape structs/arrays (or flat casts): scalar by scalar
        if (g.a.comps(v0.ty) >= g.a.comps(to)) {
            if (from.class == .structure and dst.class == .structure and from.first == dst.first) {
                var r = v0;
                r.ty = to;
                return r;
            }
            var buf: [1024]Src = undefined;
            const n = g.flatten(v0, &buf);
            const fb = g.flatBases(v0.ty);
            var tb: [1024]ast.Base = undefined;
            const want = g.basesOf(to, &tb);
            if (n < want) {
                g.fail("cannot convert {s} to {s}", .{ g.tyName(v0.ty), g.tyName(to) });
                return g.immVal(to, 0);
            }
            for (0..want) |k| buf[k] = g.convertSrc(buf[k], fb.get(g, v0.ty, k), tb[k], 1);
            return g.build(to, buf[0..want]);
        }
        g.fail("cannot convert {s} to {s}", .{ g.tyName(v0.ty), g.tyName(to) });
        return g.immVal(to, 0);
    }

    const FlatBases = struct {
        fn get(_: FlatBases, g: *Gen, t: u32, k: usize) ast.Base {
            var tb: [1024]ast.Base = undefined;
            const n = g.basesOf(t, &tb);
            return if (k < n) tb[k] else .float;
        }
    };

    fn flatBases(_: *Gen, _: u32) FlatBases {
        return .{};
    }

    /// Each scalar's base, in flatten order.
    pub fn basesOf(g: *Gen, t: u32, out: []ast.Base) usize {
        const n = g.rowsOf(t);
        var k: usize = 0;
        for (0..n) |r| {
            const info = g.rowInfo(t, @intCast(r));
            for (0..info.n) |_| {
                if (k < out.len) out[k] = info.base;
                k += 1;
            }
        }
        return @min(k, out.len);
    }

    fn convertNum(g: *Gen, v0: Val, to: u32) Val {
        const from = g.a.types[v0.ty];
        const dst = g.a.types[to];
        const fb = ast.canon(from.base);
        const tb = ast.canon(dst.base);
        if (tb == .double or fb == .double) {
            g.fail("double is not supported", .{});
            return g.immVal(to, 0);
        }
        // shape first
        var v = g.rows(v0);
        if (dst.class == .matrix) {
            if (from.class == .matrix) {
                if (from.rows < dst.rows or from.cols < dst.cols) {
                    g.fail("cannot convert {s} to {s}", .{ g.tyName(v0.ty), g.tyName(to) });
                    return g.immVal(to, 0);
                }
                const rv = g.matRows(v);
                const first = g.newSrcs(dst.rows);
                for (0..dst.rows) |r| {
                    var s = g.srcs[rv.at + r];
                    s.n = dst.cols;
                    g.srcs[first + r] = g.convertSrc(s, fb, tb, dst.cols);
                }
                return mkVal(to, first, dst.rows);
            }
            if (from.class == .scalar) {
                const first = g.newSrcs(dst.rows);
                const c = g.convertSrc(g.srcs[v.at], fb, tb, dst.cols);
                for (0..dst.rows) |r| g.srcs[first + r] = c;
                return mkVal(to, first, dst.rows);
            }
            // a vector of rows*cols components to a matrix
            var sc: [16]Src = undefined;
            const n = g.flatten(v, &sc);
            if (n < @as(usize, dst.rows) * dst.cols) {
                g.fail("cannot convert {s} to {s}", .{ g.tyName(v0.ty), g.tyName(to) });
                return g.immVal(to, 0);
            }
            for (0..n) |k| sc[k] = g.convertSrc(sc[k], fb, tb, 1);
            return g.build(to, sc[0 .. @as(usize, dst.rows) * dst.cols]);
        }
        // to a scalar or vector
        const want: u8 = dst.cols;
        var s: Src = undefined;
        if (from.class == .matrix) {
            // (a matrix's first row, or its components in order)
            var sc: [16]Src = undefined;
            const n = g.flatten(v, &sc);
            if (n < want) {
                g.fail("cannot convert {s} to {s}", .{ g.tyName(v0.ty), g.tyName(to) });
                return g.immVal(to, 0);
            }
            s = g.pack(sc[0..want]);
        } else {
            s = g.srcs[v.at];
            if (from.class == .vector and from.cols < want) {
                g.fail("cannot implicitly convert from '{s}' to '{s}'", .{ g.tyName(v0.ty), g.tyName(to) });
                return g.immVal(to, 0);
            }
            if (from.class == .scalar and want > 1) {
                s = component(s, 0);
            }
        }
        const first = g.newSrcs(1);
        var c = g.convertSrc(s, fb, tb, want);
        if (c.n > want) c.n = want;
        g.srcs[first] = c;
        v = mkVal(to, first, 1);
        return v;
    }

    /// One row from base `fb` to `tb` (n components; a scalar broadcast).
    pub fn convertSrc(g: *Gen, s0: Src, fb: ast.Base, tb: ast.Base, n: u8) Src {
        var s = s0;
        if (s.n == 1 and n > 1) s = broadcast(s, n);
        if (s.n > n) s.n = n;
        const f = ast.canon(fb);
        const t = ast.canon(tb);
        if (f == t) return s;
        if ((f == .int and t == .uint) or (f == .uint and t == .int)) return s;
        const one_f: u32 = 0x3f80_0000;
        return switch (t) {
            .float => switch (f) {
                .int => g.alu(.itof, s.n, &.{g.plain(s)}),
                .uint => g.alu(.utof, s.n, &.{g.plain(s)}),
                .bool => g.alu(.@"and", s.n, &.{ g.plain(s), imm1(one_f) }),
                else => s,
            },
            .int => switch (f) {
                .float => g.alu(.ftoi, s.n, &.{s}),
                .bool => g.alu(.@"and", s.n, &.{ g.plain(s), imm1(1) }),
                else => s,
            },
            .uint => switch (f) {
                .float => g.alu(.ftou, s.n, &.{s}),
                .bool => g.alu(.@"and", s.n, &.{ g.plain(s), imm1(1) }),
                else => s,
            },
            .bool => switch (f) {
                .float => g.alu(.ne, s.n, &.{ s, imm1(0) }),
                .int, .uint => g.alu(.ine, s.n, &.{ g.plain(s), imm1(0) }),
                else => s,
            },
            else => s,
        };
    }

    pub fn broadcast(s: Src, n: u8) Src {
        var x = component(s, 0);
        x.n = n;
        return x;
    }

    /// The type both operands of a binary operator go to.
    pub fn common(g: *Gen, ta: u32, tb: u32, op_base: ?ast.Base) ?u32 {
        const x = g.a.types[ta];
        const y = g.a.types[tb];
        const nx = x.class == .scalar or x.class == .vector or x.class == .matrix;
        const ny = y.class == .scalar or y.class == .vector or y.class == .matrix;
        if (!nx or !ny) return null;
        const bx = ast.canon(x.base);
        const by = ast.canon(y.base);
        var b: ast.Base = if (bx == .float or by == .float) .float else if (bx == .uint or by == .uint) .uint else if (bx == .int or by == .int) .int else .bool;
        if (op_base) |ob| b = ob;
        if (x.class == .scalar) return g.a.withBase(tb, b);
        if (y.class == .scalar) return g.a.withBase(ta, b);
        if (x.class == .matrix and y.class == .matrix) return g.a.matrix(b, @min(x.rows, y.rows), @min(x.cols, y.cols), .default);
        if (x.class == .vector and y.class == .vector) return g.a.vector(b, @min(x.cols, y.cols));
        // a vector and a matrix of as many components
        if (g.a.comps(ta) == g.a.comps(tb)) return g.a.withBase(ta, b);
        return null;
    }

    // ── values: variables ──

    pub fn markVar(g: *Gen, base: u32, n: u32) void {
        for (0..n) |k| g.vflags[base + k] = 1;
    }

    /// A value that does not change when variables are assigned (no
    /// variable's temps in it): can be bound without a copy.
    pub fn stable(g: *Gen, v: Val) bool {
        if (v.kind != .srcs) return true;
        for (0..v.n) |k| {
            const s = g.srcs[v.at + k];
            if (s.reg == .temp and g.vflags[s.idx] != 0) return false;
            if (s.rel.on and s.rel.reg == .temp and g.vflags[s.rel.idx] != 0) return false;
        }
        return true;
    }

    /// New variable storage for type `t`: virtual temps, one per row.
    pub fn storage(g: *Gen, t: u32) u32 {
        const n = g.rowsOf(t);
        const b = g.vregs(n);
        g.markVar(b, n);
        return b;
    }

    /// The value stored at `base`.
    pub fn readStorage(g: *Gen, t: u32, base: u32) Val {
        const n = g.rowsOf(t);
        const first = g.newSrcs(n);
        for (0..n) |r| g.srcs[first + r] = tempSrc(base + @as(u32, @intCast(r)), g.rowInfo(t, @intCast(r)).n);
        return mkVal(t, first, n);
    }

    /// Stores `v` (already of `t`) at `base`.
    pub fn writeStorage(g: *Gen, t: u32, base: u32, v0: Val) void {
        const v = g.canonRows(v0);
        const n = g.rowsOf(t);
        if (v.n != n) {
            g.fail("internal: a value of {d} rows into {d}", .{ v.n, n });
            return;
        }
        for (0..n) |r| {
            const info = g.rowInfo(t, @intCast(r));
            g.aluInto(.mov, .{ .vreg = base + @as(u32, @intCast(r)), .n = info.n }, &.{g.srcs[v.at + r]});
        }
    }

    pub fn storageLVal(g: *Gen, t: u32, base: u32) LVal {
        const n = g.rowsOf(t);
        const first = g.newLocs(n);
        for (0..n) |r| g.locs[first + r] = .{ .vreg = base + @as(u32, @intCast(r)), .n = g.rowInfo(t, @intCast(r)).n };
        return .{ .ty = t, .at = first, .n = n };
    }

    pub fn newLocs(g: *Gen, n: u32) u32 {
        if (g.nlocs + n > MAX_LOCS) {
            g.fail("shader too complex (stores)", .{});
            g.nlocs = 0;
            return 0;
        }
        const s = g.nlocs;
        g.nlocs += n;
        return s;
    }

    /// A variable's value.
    pub fn readVar(g: *Gen, sym: u32) Val {
        const b = g.binds[sym];
        const s = g.a.syms[sym];
        switch (b.kind) {
            .regs => return g.readStorage(s.ty, b.base),
            .val, .cb, .object, .gs_input, .stream => return b.val,
            .none => {},
        }
        // globals bound on first use
        switch (s.storage) {
            .global, .cbuffer_member => {
                if (g.isObjectTy(s.ty)) {
                    g.binds[sym] = .{ .kind = .object, .val = .{ .ty = s.ty, .kind = .object, .sym = sym } };
                    return g.binds[sym].val;
                }
                g.fail("internal: global '{s}' unplaced", .{g.a.symName(sym)});
            },
            .static_global => {
                g.fail("internal: static '{s}' unplaced", .{g.a.symName(sym)});
            },
            else => g.fail("'{s}' used before it is declared", .{g.a.symName(sym)}),
        }
        return g.immVal(g.scalarTy(.float), 0);
    }

    // ── declarations ──

    /// A local (or static) variable: its storage and initial value.
    pub fn declareVar(g: *Gen, sym: u32) void {
        const s = g.a.syms[sym];
        if (g.isObjectTy(s.ty)) {
            if (s.init != NONE) {
                const v = g.expr(s.init);
                g.binds[sym] = .{ .kind = .object, .val = v };
            }
            return;
        }
        var init: ?Val = null;
        if (s.init != NONE) init = g.initValue(s.init, s.ty);
        if (g.failed) return;
        // consts and never-assigned locals with a stable value: the value itself
        if (init) |v| {
            if (s.flags & ast.F_ASSIGNED == 0 and (s.flags & ast.F_CONST != 0 or g.stable(v))) {
                g.binds[sym] = .{ .kind = .val, .val = v };
                return;
            }
        }
        const base = g.storage(s.ty);
        g.binds[sym] = .{ .kind = .regs, .base = base };
        if (init) |v| g.writeStorage(s.ty, base, v) else {
            // (uninitialized: zero, so reads are defined)
            if (s.storage == .static_global) g.writeStorage(s.ty, base, g.convert(g.immVal(g.scalarTy(.int), 0), s.ty));
        }
    }

    /// An initializer (an expression or a {...} list) as type `t`.
    pub fn initValue(g: *Gen, n: u32, t: u32) Val {
        const node = g.a.nodes[n];
        if (node.kind == .init_list) {
            var buf: [2048]Src = undefined;
            var bases: [2048]ast.Base = undefined;
            var cnt: usize = 0;
            g.flattenList(n, &buf, &bases, &cnt);
            var tb: [2048]ast.Base = undefined;
            const want = g.basesOf(t, &tb);
            if (cnt != want) {
                // (a single element initializes every scalar)
                if (cnt == 1) {
                    for (1..want) |k| {
                        buf[k] = buf[0];
                        bases[k] = bases[0];
                    }
                } else {
                    g.fail("initializer has {d} values, {s} needs {d}", .{ cnt, g.tyName(t), want });
                    return g.immVal(t, 0);
                }
            }
            for (0..want) |k| buf[k] = g.convertSrc(buf[k], bases[k], tb[k], 1);
            return g.build(t, buf[0..want]);
        }
        const v = g.expr(n);
        if (g.failed) return g.immVal(t, 0);
        return g.convert(v, t);
    }

    fn flattenList(g: *Gen, n: u32, buf: []Src, bases: []ast.Base, cnt: *usize) void {
        var e = g.a.nodes[n].a;
        while (e != NONE) : (e = g.a.nodes[e].next) {
            if (g.a.nodes[e].kind == .init_list) {
                g.flattenList(e, buf, bases, cnt);
                continue;
            }
            const v = g.expr(e);
            if (g.failed) return;
            var tb: [1024]ast.Base = undefined;
            const nb = g.basesOf(v.ty, &tb);
            const m = g.flatten(v, buf[cnt.*..]);
            for (0..m) |k| bases[cnt.* + k] = if (k < nb) tb[k] else .float;
            cnt.* += m;
        }
    }

    // ── lvalues ──

    pub fn lvalue(g: *Gen, n: u32) LVal {
        const node = g.a.nodes[n];
        g.locate(n);
        switch (node.kind) {
            .ident => {
                const sym = node.a;
                const s = g.a.syms[sym];
                var b = g.binds[sym];
                if (b.kind == .val) {
                    // a never-assigned binding being written (an out argument):
                    // give it storage now
                    const base = g.storage(s.ty);
                    g.writeStorage(s.ty, base, b.val);
                    g.binds[sym] = .{ .kind = .regs, .base = base };
                    b = g.binds[sym];
                }
                if (b.kind != .regs) {
                    g.fail("'{s}' cannot be assigned", .{g.a.symName(sym)});
                    return .{ .ty = s.ty };
                }
                return g.storageLVal(s.ty, b.base);
            },
            .member => {
                const base = g.lvalue(node.a);
                return g.lmember(base, node.tok);
            },
            .index => {
                const base = g.lvalue(node.a);
                return g.lindex(base, node.b);
            },
            .cast => {
                // ((float)x = ...): the same storage seen as the cast type
                var l = g.lvalue(node.b);
                l.ty = node.a;
                return l;
            },
            else => {
                g.fail("l-value required", .{});
                return .{ .ty = 0 };
            },
        }
    }

    fn lmember(g: *Gen, base: LVal, tok: u32) LVal {
        const name = g.tokText(tok);
        const t = g.a.types[base.ty];
        if (t.class == .structure) {
            var row: u32 = 0;
            for (0..t.len) |k| {
                const m = g.a.members[t.first + k];
                const mn = g.a.name(m.name_off, m.name_len);
                const nr = g.rowsOf(m.ty);
                if (std.mem.eql(u8, mn, name)) {
                    if (base.dyn) return g.ldynSub(base, row, nr, m.ty);
                    return .{ .ty = m.ty, .at = base.at + row, .n = nr };
                }
                row += nr;
            }
            g.fail("'{s}' is not a member of '{s}'", .{ name, g.tyName(base.ty) });
            return base;
        }
        if (t.class == .scalar or t.class == .vector) {
            var sw: [4]u2 = undefined;
            const n = swizzle(name, t.cols, &sw) orelse {
                g.fail("invalid swizzle '{s}'", .{name});
                return base;
            };
            const nt = g.a.vector(t.base, n);
            const per: u32 = 1;
            const count: u32 = if (base.dyn) base.dyn_count else 1;
            const first = g.newLocs(count * per);
            for (0..count) |e| {
                const l = g.locs[base.at + e];
                var nl = Loc{ .vreg = l.vreg, .n = n };
                for (0..n) |k| nl.comp[k] = l.comp[sw[k]];
                g.locs[first + e] = nl;
            }
            var r = base;
            r.ty = nt;
            r.at = first;
            r.n = if (base.dyn) count else 1;
            if (base.dyn) r.dyn_per = 1;
            return r;
        }
        if (t.class == .matrix) {
            // _m00 / _11 swizzles of one row's components only
            var idx: [4][2]u8 = undefined;
            const n = matSwizzle(name, &idx) orelse {
                g.fail("invalid matrix swizzle '{s}'", .{name});
                return base;
            };
            const r0 = idx[0][0];
            for (idx[0..n]) |e| if (e[0] != r0) {
                g.fail("writing a matrix swizzle across rows is not supported", .{});
                return base;
            };
            if (base.dyn) {
                g.fail("dynamically indexed matrix swizzle", .{});
                return base;
            }
            const l = g.locs[base.at + r0];
            const first = g.newLocs(1);
            var nl = Loc{ .vreg = l.vreg, .n = @intCast(n) };
            for (0..n) |k| nl.comp[k] = l.comp[idx[k][1]];
            g.locs[first] = nl;
            return .{ .ty = g.a.vector(t.base, @intCast(n)), .at = first, .n = 1 };
        }
        g.fail("'{s}' has no members", .{g.tyName(base.ty)});
        return base;
    }

    /// The sub-rows [row, row+nr) of each element of a dynamic lvalue.
    fn ldynSub(g: *Gen, base: LVal, row: u32, nr: u32, t: u32) LVal {
        const first = g.newLocs(base.dyn_count * nr);
        for (0..base.dyn_count) |e| {
            for (0..nr) |k| g.locs[first + e * nr + k] = g.locs[base.at + e * base.dyn_per + row + k];
        }
        var r = base;
        r.ty = t;
        r.at = first;
        r.n = base.dyn_count * nr;
        r.dyn_per = nr;
        return r;
    }

    fn lindex(g: *Gen, base: LVal, idx_node: u32) LVal {
        const t = g.a.types[base.ty];
        const iv = g.expr(idx_node);
        if (g.failed) return base;
        const ci = g.constIndex(iv);
        switch (t.class) {
            .array => {
                const per = g.rowsOf(t.elem);
                if (ci) |i| {
                    if (i >= t.len) {
                        g.fail("array index out of bounds", .{});
                        return base;
                    }
                    if (base.dyn) return g.ldynSub(base, i * per, per, t.elem);
                    return .{ .ty = t.elem, .at = base.at + i * per, .n = per };
                }
                if (base.dyn) {
                    g.fail("more than one dynamic index in an assignment", .{});
                    return base;
                }
                var r = base;
                r.ty = t.elem;
                r.dyn = true;
                r.dyn_idx = g.indexSrc(iv);
                r.dyn_count = t.len;
                r.dyn_per = per;
                return r;
            },
            .matrix => {
                if (ci) |i| {
                    if (i >= t.rows) {
                        g.fail("matrix row index out of bounds", .{});
                        return base;
                    }
                    if (base.dyn) return g.ldynSub(base, i, 1, g.a.vector(t.base, t.cols));
                    return .{ .ty = g.a.vector(t.base, t.cols), .at = base.at + i, .n = 1 };
                }
                if (base.dyn) {
                    g.fail("more than one dynamic index in an assignment", .{});
                    return base;
                }
                var r = base;
                r.ty = g.a.vector(t.base, t.cols);
                r.dyn = true;
                r.dyn_idx = g.indexSrc(iv);
                r.dyn_count = t.rows;
                r.dyn_per = 1;
                return r;
            },
            .vector, .scalar => {
                if (ci) |i| {
                    if (i >= t.cols) {
                        g.fail("vector index out of bounds", .{});
                        return base;
                    }
                    const count: u32 = if (base.dyn) base.dyn_count else 1;
                    const first = g.newLocs(count);
                    for (0..count) |e| {
                        const l = g.locs[base.at + e];
                        g.locs[first + e] = .{ .vreg = l.vreg, .n = 1, .comp = .{ l.comp[i], 0, 0, 0 } };
                    }
                    var r = base;
                    r.ty = g.a.scalar(t.base);
                    r.at = first;
                    r.n = count;
                    if (base.dyn) r.dyn_per = 1;
                    return r;
                }
                if (base.dyn) {
                    g.fail("more than one dynamic index in an assignment", .{});
                    return base;
                }
                // a component chosen at run time: one location per component
                const l = g.locs[base.at];
                const first = g.newLocs(t.cols);
                for (0..t.cols) |c| g.locs[first + c] = .{ .vreg = l.vreg, .n = 1, .comp = .{ l.comp[c], 0, 0, 0 } };
                return .{ .ty = g.a.scalar(t.base), .at = first, .n = t.cols, .dyn = true, .dyn_idx = g.indexSrc(iv), .dyn_count = t.cols, .dyn_per = 1 };
            },
            else => {
                g.fail("subscript of a non-array", .{});
                return base;
            },
        }
    }

    /// An integer index value as a scalar u32 source.
    pub fn indexSrc(g: *Gen, v: Val) Src {
        const iv = g.convert(v, g.scalarTy(.uint));
        return g.plain(g.srcs[g.rows(iv).at]);
    }

    /// An index's value when it is known now.
    pub fn constIndex(g: *Gen, v: Val) ?u32 {
        if (v.kind != .srcs or v.n != 1) return null;
        const s = g.srcs[v.at];
        if (s.reg != .imm32) return null;
        const b = g.baseOf(v.ty);
        const w = s.imm[0];
        return switch (b) {
            .float => @intFromFloat(@max(@trunc(@as(f32, @bitCast(applyMods(w, s.mods)))), 0)),
            .int => if (@as(i32, @bitCast(w)) < 0) 0xffff_ffff else w,
            else => w,
        };
    }

    /// Stores `v` (converted to the lvalue's type).
    pub fn store(g: *Gen, l: LVal, v0: Val) void {
        if (g.failed) return;
        const v = g.canonRows(g.convert(v0, l.ty));
        if (!l.dyn) {
            if (v.n != l.n) {
                g.fail("internal: storing {d} rows into {d}", .{ v.n, l.n });
                return;
            }
            for (0..l.n) |r| g.aluInto(.mov, g.locs[l.at + r], &.{g.srcs[v.at + r]});
            return;
        }
        // each element: written where the index is its own
        const idx = g.inTemp(l.dyn_idx);
        for (0..l.dyn_count) |e| {
            const hit = g.alu(.ieq, 1, &.{ idx, imm1(@intCast(e)) });
            for (0..l.dyn_per) |r| {
                const loc = g.locs[l.at + e * l.dyn_per + r];
                const old = Src{ .reg = .temp, .idx = loc.vreg, .n = loc.n, .swz = loc.comp };
                g.aluInto(.movc, loc, &.{ broadcast(hit, loc.n), g.srcs[v.at + r], old });
            }
        }
    }

    /// The current value of an lvalue.
    pub fn loadL(g: *Gen, l: LVal) Val {
        if (!l.dyn) {
            const first = g.newSrcs(l.n);
            for (0..l.n) |r| {
                const loc = g.locs[l.at + r];
                g.srcs[first + r] = .{ .reg = .temp, .idx = loc.vreg, .n = loc.n, .swz = loc.comp };
            }
            return mkVal(l.ty, first, l.n);
        }
        // the element at the index: a select over all of them
        const first = g.newSrcs(l.dyn_per);
        const idx = g.inTemp(l.dyn_idx);
        for (0..l.dyn_per) |r| {
            const l0 = g.locs[l.at + r];
            var acc = Src{ .reg = .temp, .idx = l0.vreg, .n = l0.n, .swz = l0.comp };
            for (1..l.dyn_count) |e| {
                const loc = g.locs[l.at + e * l.dyn_per + r];
                const hit = g.alu(.ieq, 1, &.{ idx, imm1(@intCast(e)) });
                acc = g.alu(.movc, loc.n, &.{ broadcast(hit, loc.n), .{ .reg = .temp, .idx = loc.vreg, .n = loc.n, .swz = loc.comp }, acc });
            }
            g.srcs[first + r] = acc;
        }
        return mkVal(l.ty, first, l.dyn_per);
    }

    // ── expressions ──

    pub fn expr(g: *Gen, n: u32) Val {
        if (g.failed) return .{ .ty = 0, .kind = .none };
        if (n == NONE) {
            g.fail("an expression expected", .{});
            return .{ .ty = 0, .kind = .none };
        }
        const node = g.a.nodes[n];
        g.locate(n);
        return switch (node.kind) {
            .lit_int => blk: {
                const t = g.scalarTy(if (node.op == ast.LIT_UNSIGNED) .uint else .int);
                break :blk g.immVal(t, node.a);
            },
            .lit_float => g.immVal(g.scalarTy(.float), node.a),
            .lit_bool => g.immVal(g.scalarTy(.bool), if (node.a != 0) 0xffff_ffff else 0),
            .ident => g.readVar(node.a),
            .unary => g.unaryExpr(node),
            .preinc, .predec, .postinc, .postdec => g.incDec(node),
            .binary => g.binaryExpr(@enumFromInt(node.op), g.expr(node.a), g.expr(node.b)),
            .assign => g.assignExpr(node),
            .ternary => g.ternaryExpr(node),
            .call => g.callExpr(n),
            .method => intrin.method(g, n),
            .construct => g.construct(node.a, node.b),
            .cast => blk: {
                const v = g.expr(node.b);
                break :blk g.convert(v, node.a);
            },
            .member => g.memberExpr(g.expr(node.a), node.tok),
            .index => g.indexExpr(g.expr(node.a), node.b),
            .init_list => blk: {
                g.fail("an initializer list where a value was expected", .{});
                break :blk g.immVal(g.scalarTy(.float), 0);
            },
            .comma => blk: {
                _ = g.expr(node.a);
                break :blk g.expr(node.b);
            },
            else => blk: {
                g.fail("an expression expected", .{});
                break :blk g.immVal(g.scalarTy(.float), 0);
            },
        };
    }

    fn construct(g: *Gen, t: u32, first_arg: u32) Val {
        const x = g.a.types[t];
        var buf: [256]Src = undefined;
        var bases: [256]ast.Base = undefined;
        var cnt: usize = 0;
        var e = first_arg;
        while (e != NONE) : (e = g.a.nodes[e].next) {
            const v = g.expr(e);
            if (g.failed) return g.immVal(t, 0);
            var tb: [256]ast.Base = undefined;
            const nb = g.basesOf(v.ty, &tb);
            const m = g.flatten(v, buf[cnt..]);
            for (0..m) |k| bases[cnt + k] = if (k < nb) tb[k] else .float;
            cnt += m;
        }
        const want = g.a.comps(t);
        if (cnt == 1 and want > 1) {
            for (1..want) |k| {
                buf[k] = buf[0];
                bases[k] = bases[0];
            }
            cnt = want;
        }
        if (cnt != want) {
            g.fail("wrong number of arguments for {s}: {d}", .{ g.tyName(t), cnt });
            return g.immVal(t, 0);
        }
        const b = ast.canon(x.base);
        for (0..want) |k| buf[k] = g.convertSrc(buf[k], bases[k], b, 1);
        return g.build(t, buf[0..want]);
    }

    pub fn memberExpr(g: *Gen, v: Val, tok: u32) Val {
        const name = g.tokText(tok);
        const t = g.a.types[v.ty];
        if (t.class == .structure) {
            var row: u32 = 0;

            for (0..t.len) |k| {
                const m = g.a.members[t.first + k];
                const mn = g.a.name(m.name_off, m.name_len);
                if (std.mem.eql(u8, mn, name)) {
                    if (v.kind == .cb) {
                        var r = v;
                        r.ty = m.ty;
                        r.off = v.off + g.cbMemberOff(v.ty, k);
                        return r;
                    }
                    if (v.kind == .object) {
                        g.fail("members of objects", .{});
                        return v;
                    }
                    // (a struct of srcs: rows counted as stored: a
                    // column-major matrix member has its columns)

                    const nr = g.storedRows(v, row, m.ty);
                    return mkVal(m.ty, v.at + row, nr);
                }
                row += g.storedRows(v, row, m.ty);
            }
            g.fail("'{s}' is not a member of '{s}'", .{ name, g.tyName(v.ty) });
            return g.immVal(g.scalarTy(.float), 0);
        }
        if (t.class == .scalar or t.class == .vector) {
            var sw: [4]u2 = undefined;
            const n = swizzle(name, t.cols, &sw) orelse {
                g.fail("invalid swizzle '{s}'", .{name});
                return v;
            };
            const r = g.rows(v);
            const s = g.srcs[r.at];
            var x = s;
            x.n = n;
            for (0..n) |k| {
                if (s.reg == .imm32) x.imm[k] = if (s.n == 1) s.imm[0] else s.imm[sw[k]] else x.swz[k] = if (s.n == 1) s.swz[0] else s.swz[sw[k]];
            }
            if (s.reg == .imm32) for (n..4) |k| {
                x.imm[k] = x.imm[0];
            };
            const first = g.newSrcs(1);
            g.srcs[first] = x;
            return mkVal(g.a.vector(t.base, n), first, 1);
        }
        if (t.class == .matrix) {
            var idx: [4][2]u8 = undefined;
            const n = matSwizzle(name, &idx) orelse {
                g.fail("invalid matrix swizzle '{s}'", .{name});
                return v;
            };
            const r = g.matRows(v);
            var sc: [4]Src = undefined;
            for (0..n) |k| sc[k] = component(g.srcs[r.at + idx[k][0]], idx[k][1]);
            const first = g.newSrcs(1);
            g.srcs[first] = g.pack(sc[0..n]);
            return mkVal(g.a.vector(t.base, @intCast(n)), first, 1);
        }
        g.fail("'{s}' has no members", .{g.tyName(v.ty)});
        return v;
    }

    /// How many srcs a member of type `t` takes in a value at `row` (a
    /// column-major matrix from a constant buffer has its columns).
    fn storedRows(g: *Gen, v: Val, row: u32, t: u32) u32 {
        const x = g.a.types[t];
        switch (x.class) {
            .matrix => {
                if (row < v.n and g.srcs[v.at + row].col) return x.cols;
                return x.rows;
            },
            .array => {
                var n: u32 = 0;
                for (0..x.len) |_| n += g.storedRows(v, row + n, x.elem);
                return n;
            },
            .structure => {
                var n: u32 = 0;
                for (0..x.len) |k| n += g.storedRows(v, row + n, g.a.members[x.first + k].ty);
                return n;
            },
            else => return 1,
        }
    }

    pub fn indexExpr(g: *Gen, v: Val, idx_node: u32) Val {
        const iv = g.expr(idx_node);
        if (g.failed) return v;
        return g.indexVal(v, iv);
    }

    pub fn indexVal(g: *Gen, v: Val, iv: Val) Val {
        const t = g.a.types[v.ty];
        const ci = g.constIndex(iv);
        switch (t.class) {
            .array => {
                if (v.kind == .object) {
                    // an array of textures or samplers: a known index only
                    const i = ci orelse {
                        g.fail("sampler array index must be a literal expression", .{});
                        return v;
                    };
                    if (i >= t.len) {
                        g.fail("array index out of bounds", .{});
                        return v;
                    }
                    var r = v;
                    r.ty = t.elem;
                    r.elem = v.elem * t.len + i;
                    return r;
                }
                if (v.kind == .cb) {
                    var r = v;
                    r.ty = t.elem;
                    const st = g.cbStride(t.elem);
                    if (ci) |i| {
                        r.off = v.off + i * st;
                        return r;
                    }
                    // a row offset register: index * stride rows (+ any already)
                    var idx = g.indexSrc(iv);
                    if (st != 16) idx = g.alu(.imul, 1, &.{ idx, imm1(st / 16) });
                    if (v.rel.on) idx = g.alu(.iadd, 1, &.{ idx, .{ .reg = v.rel.reg, .idx = v.rel.idx, .swz = .{ v.rel.comp, 0, 0, 0 }, .n = 1 } });
                    idx = g.inTemp(idx);
                    r.rel = .{ .on = true, .reg = .temp, .idx = idx.idx, .comp = idx.swz[0] };
                    g.markCbDynamic(v.slot);
                    return r;
                }
                const vr = g.rows(v);
                const per = g.storedRows(vr, 0, t.elem);
                if (ci) |i| {
                    if (i >= t.len) {
                        g.fail("array index out of bounds", .{});
                        return g.immVal(t.elem, 0);
                    }
                    return mkVal(t.elem, vr.at + i * per, per);
                }
                return g.selectElem(vr, t.elem, t.len, per, g.indexSrc(iv));
            },
            .matrix => {
                const rt = g.a.vector(t.base, t.cols);
                const mr = g.matRows(v);
                if (ci) |i| {
                    if (i >= t.rows) {
                        g.fail("matrix row index out of bounds", .{});
                        return g.immVal(rt, 0);
                    }
                    return mkVal(rt, mr.at + i, 1);
                }
                return g.selectElem(mr, rt, t.rows, 1, g.indexSrc(iv));
            },
            .vector, .scalar => {
                const r = g.rows(v);
                const st = g.a.scalar(t.base);
                if (ci) |i| {
                    if (i >= t.cols) {
                        g.fail("vector index out of bounds", .{});
                        return g.immVal(st, 0);
                    }
                    const first = g.newSrcs(1);
                    g.srcs[first] = component(g.srcs[r.at], i);
                    return mkVal(st, first, 1);
                }
                const s = g.srcs[r.at];
                const idx = g.inTemp(g.indexSrc(iv));
                var acc = component(s, 0);
                for (1..t.cols) |c| {
                    const hit = g.alu(.ieq, 1, &.{ idx, imm1(@intCast(c)) });
                    acc = g.alu(.movc, 1, &.{ hit, component(s, @intCast(c)), acc });
                }
                const first = g.newSrcs(1);
                g.srcs[first] = acc;
                return mkVal(st, first, 1);
            },
            else => {
                g.fail("subscript of a non-array", .{});
                return v;
            },
        }
    }

    /// The element at a run-time index: an immediate array goes to the
    /// immediate constant buffer; others are a select over the elements.
    fn selectElem(g: *Gen, v: Val, et: u32, count: u32, per: u32, idx0: Src) Val {
        var all_imm = true;
        for (0..v.n) |k| all_imm = all_imm and g.srcs[v.at + k].reg == .imm32;
        if (all_imm and v.n == count * per) {
            // the immediate constant buffer: each row an entry
            const base = g.nicb / 4;
            if (g.nicb + v.n * 4 > MAX_ICB) {
                g.fail("immediate constant buffer too large", .{});
                return g.immVal(et, 0);
            }
            for (0..v.n) |k| {
                const s = g.srcs[v.at + k];
                for (0..4) |c| g.icb[g.nicb + c] = if (c < s.n) applyMods(s.imm[c], s.mods) else 0;
                g.nicb += 4;
            }
            var idx = g.plain(idx0);
            if (per != 1) idx = g.alu(.imul, 1, &.{ idx, imm1(per) });
            idx = g.inTemp(idx);
            const first = g.newSrcs(per);
            for (0..per) |r| {
                const s0 = g.srcs[v.at + r];
                g.srcs[first + r] = .{ .reg = .icb, .row = base + @as(u32, @intCast(r)), .n = s0.n, .rel = .{ .on = true, .reg = .temp, .idx = idx.idx, .comp = idx.swz[0] } };
            }
            return mkVal(et, first, per);
        }
        const idx = g.inTemp(g.plain(idx0));
        const first = g.newSrcs(per);
        for (0..per) |r| {
            var acc = g.srcs[v.at + r];
            for (1..count) |e| {
                const s = g.srcs[v.at + e * per + r];
                const hit = g.alu(.ieq, 1, &.{ idx, imm1(@intCast(e)) });
                acc = g.alu(.movc, s.n, &.{ broadcast(hit, s.n), s, acc });
            }
            g.srcs[first + r] = acc;
        }
        return mkVal(et, first, per);
    }

    fn markCbDynamic(g: *Gen, slot: u32) void {
        for (g.cbs[0..g.ncbs]) |*c| if (c.slot == slot) {
            c.dynamic = true;
        };
    }

    // ── operators ──

    fn unaryExpr(g: *Gen, node: ast.Node) Val {
        const v = g.expr(node.a);
        if (g.failed) return v;
        const k: lex.Kind = @enumFromInt(node.op);
        const b = g.baseOf(v.ty);
        switch (k) {
            .plus => return v,
            .minus => {
                const t = if (b == .bool) g.a.withBase(v.ty, .int) else v.ty;
                const cv = g.rows(g.convert(v, t));
                const first = g.newSrcs(cv.n);
                for (0..cv.n) |r| {
                    var s = g.srcs[cv.at + r];
                    if (ast.canon(g.a.types[t].base) == .float) {
                        if (s.reg == .imm32) {
                            for (&s.imm) |*w| w.* = applyMods(w.*, s.mods) ^ 0x8000_0000;
                            s.mods = 0;
                        } else s.mods ^= 1;
                    } else s = g.alu(.ineg, s.n, &.{g.plain(s)});
                    g.srcs[first + r] = s;
                }
                return mkVal(t, first, cv.n);
            },
            .bang => {
                const bt = g.a.withBase(v.ty, .bool);
                const cv = g.rows(g.convert(v, bt));
                return g.mapRows(bt, cv, null, .not);
            },
            .tilde => {
                const t = if (b == .float or b == .bool) g.a.withBase(v.ty, .int) else v.ty;
                const cv = g.rows(g.convert(v, t));
                return g.mapRows(t, cv, null, .not);
            },
            else => {
                g.fail("bad unary operator", .{});
                return v;
            },
        }
    }

    /// `op` row by row over one or two values of type `t`.
    pub fn mapRows(g: *Gen, t: u32, a: Val, b: ?Val, op: Op) Val {
        const ar = g.canonRows(a);
        const br = if (b) |x| g.canonRows(x) else ar;
        const first = g.newSrcs(ar.n);
        for (0..ar.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const sa = g.srcs[ar.at + r];
            g.srcs[first + r] = if (b != null) g.alu(op, n, &.{ g.forOp(op, sa), g.forOp(op, g.srcs[br.at + r]) }) else g.alu(op, n, &.{g.forOp(op, sa)});
        }
        return mkVal(t, first, ar.n);
    }

    /// A source as an op reads it: integer and bit ops take no float
    /// modifiers.
    pub fn forOp(g: *Gen, op: Op, s: Src) Src {
        return if (floatOp(op)) s else g.plain(s);
    }

    pub fn binaryExpr(g: *Gen, k: lex.Kind, a: Val, b: Val) Val {
        if (g.failed) return a;
        const logic = k == .and_and or k == .or_or;
        const bitop = k == .amp or k == .pipe or k == .caret or k == .shl or k == .shr or k == .percent;
        var ct_ty = g.common(a.ty, b.ty, if (logic) .bool else null) orelse {
            g.fail("operator {s} on {s} and {s}", .{ lex.spelling(k), g.tyName(a.ty), g.tyName(b.ty) });
            return a;
        };
        var base = g.baseOf(ct_ty);
        if (bitop and k != .percent and (base == .float or base == .bool)) {
            if (base == .float) {
                g.fail("operator {s} needs integers", .{lex.spelling(k)});
                return a;
            }
            ct_ty = g.a.withBase(ct_ty, .int);
            base = .int;
        }
        if ((k == .plus or k == .minus or k == .star or k == .slash or k == .percent) and base == .bool) {
            ct_ty = g.a.withBase(ct_ty, .int);
            base = .int;
        }
        const x = g.canonRows(g.convert(a, ct_ty));
        const y = g.canonRows(g.convert(b, ct_ty));
        if (g.failed) return a;
        const bool_ty = g.a.withBase(ct_ty, .bool);
        const fl = base == .float;
        const un = base == .uint;
        return switch (k) {
            .plus => g.mapRows(ct_ty, x, y, if (fl) .add else .iadd),
            .minus => blk: {
                const ny = g.negate(ct_ty, y);
                break :blk g.mapRows(ct_ty, x, ny, if (fl) .add else .iadd);
            },
            .star => g.mapRows(ct_ty, x, y, if (fl) .mul else .imul),
            .slash => if (fl) g.mapRows(ct_ty, x, y, .div) else g.intDiv(ct_ty, x, y, un, false),
            .percent => if (fl) g.fmod(ct_ty, x, y) else g.intDiv(ct_ty, x, y, un, true),
            .amp => g.mapRows(ct_ty, x, y, .@"and"),
            .pipe => g.mapRows(ct_ty, x, y, .@"or"),
            .caret => g.mapRows(ct_ty, x, y, .xor),
            .shl => g.mapRows(ct_ty, x, y, .ishl),
            .shr => g.mapRows(ct_ty, x, y, if (un) .ushr else .ishr),
            .and_and => g.mapRows(ct_ty, x, y, .@"and"),
            .or_or => g.mapRows(ct_ty, x, y, .@"or"),
            .lt => g.mapRows(bool_ty, x, y, if (fl) .lt else if (un) .ult else .ilt),
            .gt => g.mapRows(bool_ty, y, x, if (fl) .lt else if (un) .ult else .ilt),
            .le => g.mapRows(bool_ty, y, x, if (fl) .ge else if (un) .uge else .ige),
            .ge => g.mapRows(bool_ty, x, y, if (fl) .ge else if (un) .uge else .ige),
            .eq => g.mapRows(bool_ty, x, y, if (fl) .eq else .ieq),
            .ne => g.mapRows(bool_ty, x, y, if (fl) .ne else .ine),
            else => blk: {
                g.fail("bad operator", .{});
                break :blk a;
            },
        };
    }

    pub fn negate(g: *Gen, t: u32, v: Val) Val {
        const fl = g.baseOf(t) == .float;
        const first = g.newSrcs(v.n);
        for (0..v.n) |r| {
            var s = g.srcs[v.at + r];
            if (fl) {
                if (s.reg == .imm32) {
                    for (&s.imm) |*w| w.* = applyMods(w.*, s.mods) ^ 0x8000_0000;
                    s.mods = 0;
                } else s.mods ^= 1;
            } else s = g.alu(.ineg, s.n, &.{g.plain(s)});
            g.srcs[first + r] = s;
        }
        return mkVal(t, first, v.n);
    }

    /// Integer / and %: unsigned by udiv; signed through the magnitudes
    /// with the sign put back (D3D's integer division rounds to zero).
    fn intDiv(g: *Gen, t: u32, x: Val, y: Val, unsigned: bool, rem: bool) Val {
        const first = g.newSrcs(x.n);
        for (0..x.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const a = g.plain(g.srcs[x.at + r]);
            const b = g.plain(g.srcs[y.at + r]);
            if (unsigned) {
                g.srcs[first + r] = g.udiv(n, a, b, rem);
                continue;
            }
            const aa = g.alu(.imax, n, &.{ a, g.alu(.ineg, n, &.{a}) });
            const ab = g.alu(.imax, n, &.{ b, g.alu(.ineg, n, &.{b}) });
            const q = g.udiv(n, aa, ab, rem);
            // the result's sign: the dividend's (%) or both's (/)
            const sgn = if (rem) a else g.alu(.xor, n, &.{ a, b });
            const neg = g.alu(.ilt, n, &.{ sgn, imm1(0) });
            g.srcs[first + r] = g.alu(.movc, n, &.{ neg, g.alu(.ineg, n, &.{q}), q });
        }
        return mkVal(t, first, x.n);
    }

    fn udiv(g: *Gen, n: u8, a: Src, b: Src, rem: bool) Src {
        if (a.reg == .imm32 and b.reg == .imm32) {
            var r = Src{ .reg = .imm32, .n = n };
            for (0..4) |c| {
                const x = if (a.n == 1) a.imm[0] else a.imm[c];
                const y = if (b.n == 1) b.imm[0] else b.imm[c];
                r.imm[c] = if (y == 0) 0xffff_ffff else if (rem) x % y else x / y;
            }
            return r;
        }
        const v = g.vreg();
        var i = ir.Inst{ .op = .udiv, .n = 4, .ndst = 2 };
        const d = dstOpnd(v, ident4, n);
        i.ops[0] = if (rem) .{ .reg = .null, .comps = 0, .dims = 0 } else d;
        i.ops[1] = if (rem) d else .{ .reg = .null, .comps = 0, .dims = 0 };
        i.ops[2] = g.opnd(a, ident4, n);
        i.ops[3] = g.opnd(b, ident4, n);
        g.emit(i);
        return tempSrc(v, n);
    }

    /// x % y for floats, as fxc computes it: the fraction of |x/y| with
    /// x/y's sign, times y.
    pub fn fmod(g: *Gen, t: u32, x: Val, y: Val) Val {
        const first = g.newSrcs(x.n);
        for (0..x.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const a = g.srcs[x.at + r];
            const b = g.srcs[y.at + r];
            const d = g.alu(.div, n, &.{ a, b });
            var nd = d;
            nd.mods ^= 1;
            const ge = g.alu(.ge, n, &.{ d, nd });
            var ad = d;
            ad.mods = 2;
            const fr = g.alu(.frc, n, &.{ad});
            var nfr = fr;
            nfr.mods ^= 1;
            const sel = g.alu(.movc, n, &.{ ge, fr, nfr });
            g.srcs[first + r] = g.alu(.mul, n, &.{ sel, b });
        }
        return mkVal(t, first, x.n);
    }

    fn assignExpr(g: *Gen, node: ast.Node) Val {
        const k: lex.Kind = @enumFromInt(node.op);
        const l = g.lvalue(node.a);
        if (g.failed) return .{ .ty = 0, .kind = .none };
        var v: Val = undefined;
        if (k == .assign) {
            const rn = g.a.nodes[node.b];
            v = if (rn.kind == .init_list) g.initValue(node.b, l.ty) else g.expr(node.b);
        } else {
            const cur = g.loadL(l);
            const rhs = g.expr(node.b);
            const bk: lex.Kind = switch (k) {
                .add_assign => .plus,
                .sub_assign => .minus,
                .mul_assign => .star,
                .div_assign => .slash,
                .mod_assign => .percent,
                .shl_assign => .shl,
                .shr_assign => .shr,
                .and_assign => .amp,
                .xor_assign => .caret,
                .or_assign => .pipe,
                else => .plus,
            };
            v = g.binaryExpr(bk, cur, rhs);
        }
        if (g.failed) return v;
        // (the value is computed before it is stored: copy rows that read
        // the target itself, so the stored value is what is returned)
        g.store(l, v);
        return g.loadL(l);
    }

    fn incDec(g: *Gen, node: ast.Node) Val {
        const l = g.lvalue(node.a);
        if (g.failed) return .{ .ty = 0, .kind = .none };
        const cur = g.loadL(l);
        const post = node.kind == .postinc or node.kind == .postdec;
        const inc = node.kind == .preinc or node.kind == .postinc;
        var old = cur;
        if (post) {
            // a copy of the old value (dropped when unused)
            const first = g.newSrcs(cur.n);
            const cr = g.canonRows(cur);
            for (0..cr.n) |r| g.srcs[first + r] = g.alu(.mov, g.srcs[cr.at + r].n, &.{g.srcs[cr.at + r]});
            old = mkVal(cur.ty, first, cr.n);
        }
        const one = g.immVal(g.scalarTy(.int), 1);
        const nv = g.binaryExpr(if (inc) .plus else .minus, cur, one);
        g.store(l, nv);
        return if (post) old else g.loadL(l);
    }

    fn ternaryExpr(g: *Gen, node: ast.Node) Val {
        const c = g.expr(node.a);
        const a = g.expr(node.b);
        const b = g.expr(node.c);
        if (g.failed) return a;
        return g.select(c, a, b);
    }

    /// c ? a : b, componentwise (both sides computed).
    pub fn select(g: *Gen, c: Val, a: Val, b: Val) Val {
        var t = a.ty;
        if (g.isObjectTy(a.ty) or g.isObjectTy(b.ty)) {
            const ci = g.constIndex(g.convert(c, g.scalarTy(.uint)));
            if (ci) |x| return if (x != 0) a else b;
            g.fail("objects chosen at run time", .{});
            return a;
        }
        if (g.a.isNumeric(a.ty) and g.a.isNumeric(b.ty)) t = g.common(a.ty, b.ty, null) orelse a.ty;
        const x = g.canonRows(g.convert(a, t));
        const y = g.canonRows(g.convert(b, t));
        const ctc = g.a.types[c.ty];
        const scalar_c = ctc.class == .scalar or !g.a.isNumeric(t) or g.a.types[t].class == .scalar;
        const cb = g.canonRows(g.convert(c, if (scalar_c) g.scalarTy(.bool) else g.a.withBase(t, .bool)));
        if (g.failed) return a;
        // a known condition picks a side
        if (cb.n >= 1 and g.srcs[cb.at].reg == .imm32 and (scalar_c or g.a.types[t].class == .scalar)) {
            return if (g.srcs[cb.at].imm[0] != 0) x else y;
        }
        const first = g.newSrcs(x.n);
        for (0..x.n) |r| {
            const n = g.rowInfo(t, @intCast(r)).n;
            const cs = if (scalar_c) broadcast(g.srcs[cb.at], n) else g.srcs[cb.at + r];
            g.srcs[first + r] = g.alu(.movc, n, &.{ g.plain(cs), g.srcs[x.at + r], g.srcs[y.at + r] });
        }
        return mkVal(t, first, x.n);
    }

    // ── calls ──

    fn callExpr(g: *Gen, n: u32) Val {
        const node = g.a.nodes[n];
        if (node.d == NONE) return intrin.call(g, n);
        // the overload: arguments' count, then the fewest conversions
        var args: [32]Val = undefined;
        var argc: usize = 0;
        var e = node.a;
        var arg_nodes: [32]u32 = undefined;
        while (e != NONE) : (e = g.a.nodes[e].next) {
            if (argc >= args.len) {
                g.fail("too many arguments", .{});
                return .{ .ty = 0, .kind = .none };
            }
            arg_nodes[argc] = e;
            argc += 1;
        }
        // out arguments are lvalues: their types without evaluating twice
        const f = g.pickOverload(node.d, arg_nodes[0..argc]) orelse {
            // (a name that is also an intrinsic, shadowed only by other arity)
            return intrin.call(g, n);
        };
        if (g.a.syms[f].flags & ast.F_DEFINED == 0) {
            // a prototype: the body is a later declaration of the same signature
            const body = g.findDefinition(f) orelse {
                g.fail("function '{s}' is declared but not defined", .{g.a.symName(f)});
                return .{ .ty = 0, .kind = .none };
            };
            return g.inlineCall(body, arg_nodes[0..argc], &args);
        }
        return g.inlineCall(f, arg_nodes[0..argc], &args);
    }

    fn findDefinition(g: *Gen, proto: u32) ?u32 {
        const p = g.a.syms[proto];
        var i: u32 = 1;
        while (i < g.a.nsyms) : (i += 1) {
            const s = g.a.syms[i];
            if (s.kind != .function or s.flags & ast.F_DEFINED == 0) continue;
            if (!std.mem.eql(u8, g.a.symName(i), g.a.symName(proto)) or s.nparams != p.nparams) continue;
            var same = true;
            for (0..s.nparams) |k| same = same and g.a.syms[s.params + k].ty == g.a.syms[p.params + k].ty;
            if (same) return i;
        }
        return null;
    }

    /// The best overload for the argument nodes (their types read without
    /// generating code: a dry type of each).
    fn pickOverload(g: *Gen, newest: u32, argn: []const u32) ?u32 {
        var best: ?u32 = null;
        var best_cost: u32 = 0xffff_ffff;
        var tys: [32]u32 = undefined;
        for (argn, 0..) |e, k| tys[k] = g.typeOf(e);
        var f = newest;
        while (f != NONE) : (f = g.a.syms[f].prev) {
            const s = g.a.syms[f];
            if (s.kind != .function) break;
            if (argn.len > s.nparams) continue;
            // (missing arguments need defaults)
            var ok = true;
            for (argn.len..s.nparams) |k| ok = ok and g.a.syms[s.params + k].init != NONE;
            if (!ok) continue;
            var cost: u32 = 0;
            for (argn, 0..) |_, k| {
                const pt = g.a.syms[s.params + k].ty;
                const c = g.convCost(tys[k], pt) orelse {
                    ok = false;
                    break;
                };
                cost += c;
            }
            if (!ok) continue;
            if (cost < best_cost) {
                best_cost = cost;
                best = f;
            }
        }
        return best;
    }

    /// How far `from` is from `to` (null: no conversion).
    pub fn convCost(g: *Gen, from: u32, to: u32) ?u32 {
        if (from == to) return 0;
        const x = g.a.types[from];
        const y = g.a.types[to];
        if (g.isObjectTy(from) or g.isObjectTy(to)) {
            if (x.class == y.class and x.dim == y.dim) return 0;
            if (x.class == .array and y.class == .array) return 0;
            return null;
        }
        const nx = g.a.isNumeric(from);
        const ny = g.a.isNumeric(to);
        if (nx and ny) {
            var c: u32 = 0;
            if (ast.canon(x.base) != ast.canon(y.base)) c += 1;
            if (x.class != y.class or x.cols != y.cols or x.rows != y.rows) {
                if (x.class == .scalar) {
                    c += 2;
                } else if (x.class == .vector and y.class == .vector and x.cols > y.cols) {
                    c += 4;
                } else if (x.class == .vector and y.class == .scalar) {
                    c += 4;
                } else if (x.class == .matrix and y.class == .matrix and x.rows >= y.rows and x.cols >= y.cols) {
                    c += 4;
                } else return null;
            }
            return c;
        }
        if (x.class == .structure and y.class == .structure) return if (x.first == y.first) 0 else null;
        if (x.class == .array and y.class == .array) return if (x.len == y.len) g.convCost(x.elem, y.elem) else null;
        return null;
    }

    /// An expression's type, without generating code (for overloads).
    pub fn typeOf(g: *Gen, n: u32) u32 {
        const save_n = g.p.n;
        const save_v = g.p.nvregs;
        const save_s = g.nsrcs;
        const save_l = g.nlocs;
        const save_icb = g.nicb;
        const save_failed = g.failed;
        const save_len = g.log.len;
        const save_err = g.log.errors;
        // (a dry run: everything it made is dropped)
        const v = g.expr(n);
        const t = v.ty;
        g.p.n = save_n;
        g.p.nvregs = save_v;
        g.nsrcs = save_s;
        g.nlocs = save_l;
        g.nicb = save_icb;
        g.failed = save_failed;
        g.log.len = save_len;
        g.log.errors = save_err;
        return t;
    }

    fn inlineCall(g: *Gen, f: u32, argn: []const u32, args: *[32]Val) Val {
        const s = g.a.syms[f];
        if (g.nfns >= g.fns.len) {
            g.fail("calls nested too deep (recursion is not allowed)", .{});
            return .{ .ty = 0, .kind = .none };
        }
        for (g.fns[0..g.nfns]) |c| if (c.sym == f) {
            g.fail("recursive call to '{s}'", .{g.a.symName(f)});
            return .{ .ty = 0, .kind = .none };
        };
        // the arguments, in order: values for in, places for out
        var louts: [32]LVal = undefined;
        for (0..s.nparams) |k| {
            const ps = g.a.syms[s.params + k];
            const out = ps.flags & ast.F_OUT != 0;
            const in = ps.flags & ast.F_IN != 0;
            if (k >= argn.len) {
                args[k] = g.convert(g.expr(ps.init), ps.ty);
                continue;
            }
            if (out) {
                louts[k] = g.lvalue(argn[k]);
                if (in) args[k] = g.convert(g.loadL(louts[k]), ps.ty);
            } else {
                args[k] = g.convert(g.expr(argn[k]), ps.ty);
            }
            if (g.failed) return .{ .ty = 0, .kind = .none };
        }
        // bind the parameters (saving what an outer call bound: none, as
        // there is no recursion, but a sibling call's bindings are replaced)
        for (0..s.nparams) |k| {
            const psym = s.params + @as(u32, @intCast(k));
            const ps = g.a.syms[psym];
            const out = ps.flags & ast.F_OUT != 0;
            const in = ps.flags & ast.F_IN != 0;
            if (g.isObjectTy(ps.ty)) {
                g.binds[psym] = .{ .kind = .object, .val = args[k] };
                continue;
            }
            if (!out and ps.flags & ast.F_ASSIGNED == 0 and g.stable(args[k])) {
                g.binds[psym] = .{ .kind = .val, .val = args[k] };
                continue;
            }
            const base = g.storage(ps.ty);
            g.binds[psym] = .{ .kind = .regs, .base = base };
            if (in) g.writeStorage(ps.ty, base, args[k]);
        }
        // the body
        var ctx = FnCtx{ .ret_ty = s.ty, .sym = f, .flow_base = g.nflow };
        const body = s.body;
        const nret = countReturns(g.a, body);
        const last = lastStmt(g.a, body);
        ctx.direct = nret == 1 and last != NONE and g.a.nodes[last].kind == .return_;
        ctx.wrapped = nonTailReturn(g.a, body, true);
        if (s.ty != 0 and !ctx.direct) {
            ctx.ret_rows = g.rowsOf(s.ty);
            ctx.ret_base = g.storage(s.ty);
        }
        if (ctx.wrapped) {
            ctx.ret_flag = g.vreg();
            g.aluInto(.mov, .{ .vreg = ctx.ret_flag, .n = 1 }, &.{imm1(0)});
        }
        g.fns[g.nfns] = ctx;
        g.nfns += 1;
        if (ctx.wrapped) {
            g.emit(.{ .op = .loop, .ndst = 0 });
            g.pushFlow(.{ .kind = .func_wrap });
        }
        g.stmt(body, !ctx.wrapped);
        if (ctx.wrapped) {
            g.emit(.{ .op = .@"break", .ndst = 0 });
            g.emit(.{ .op = .endloop, .ndst = 0 });
            g.nflow -= 1;
        }
        g.nfns -= 1;
        const done = g.fns[g.nfns];
        // out parameters back to their arguments
        for (0..@min(s.nparams, argn.len)) |k| {
            const psym = s.params + @as(u32, @intCast(k));
            const ps = g.a.syms[psym];
            if (ps.flags & ast.F_OUT == 0) continue;
            const v = g.readVar(psym);
            g.store(louts[k], v);
        }
        if (s.ty == 0) return .{ .ty = 0, .kind = .none };
        if (done.direct) return done.direct_val;
        return g.readStorage(s.ty, done.ret_base);
    }

    // ── statements ──

    pub fn pushFlow(g: *Gen, f: Flow) void {
        if (g.nflow >= MAX_FLOW) return g.fail("flow nested too deep", .{});
        g.flow[g.nflow] = f;
        g.nflow += 1;
    }

    /// A statement; `tail`: nothing of the function runs after it.
    pub fn stmt(g: *Gen, n: u32, tail: bool) void {
        if (g.failed or n == NONE) return;
        const node = g.a.nodes[n];
        g.locate(n);
        switch (node.kind) {
            .block => {
                var s = node.a;
                while (s != NONE and !g.failed) : (s = g.a.nodes[s].next) {
                    g.stmt(s, tail and g.a.nodes[s].next == NONE);
                }
            },
            .decl => g.declareVar(node.a),
            .expr => _ = g.expr(node.a),
            .empty, .case_, .default_ => {},
            .if_ => g.ifStmt(node, tail),
            .for_, .while_, .do_ => g.loopStmt(node),
            .switch_ => g.switchStmt(node),
            .break_ => g.breakStmt(),
            .continue_ => g.continueStmt(),
            .return_ => g.returnStmt(node, tail),
            .discard_ => {
                if (g.target.stage != .pixel) return g.fail("discard is for pixel shaders", .{});
                var i = ir.Inst{ .op = .discard, .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
                i.ops[0] = .{ .reg = .imm32, .comps = 1, .imm = .{ 0xffff_ffff, 0, 0, 0 } };
                g.emit(i);
            },
            else => _ = g.expr(n),
        }
    }

    /// A condition as a scalar bool source a test reads (a temp or an
    /// immediate).
    pub fn condSrc(g: *Gen, n: u32) Src {
        const v = g.expr(n);
        if (g.failed) return imm1(0);
        const t = g.a.types[v.ty];
        if (t.class != .scalar) {
            if (t.class == .vector) {
                g.log.warn(g.cur_line, "implicit truncation of a vector condition", .{});
                const s = g.rows(v);
                const first = g.newSrcs(1);
                g.srcs[first] = component(g.srcs[s.at], 0);
                return g.condOf(mkVal(g.a.scalar(t.base), first, 1));
            }
            g.fail("conditional expression must be a scalar", .{});
            return imm1(0);
        }
        return g.condOf(v);
    }

    fn condOf(g: *Gen, v: Val) Src {
        const b = g.baseOf(v.ty);
        const r = g.rows(v);
        var s = g.srcs[r.at];
        // (ints and bools test nonzero as they are; floats compare)
        if (b == .float) s = g.srcs[g.rows(g.convert(r, g.scalarTy(.bool))).at];
        s = g.plain(s);
        if (s.reg == .imm32) return s;
        return s;
    }

    pub fn condOpnd(g: *Gen, s: Src) ir.Opnd {
        if (s.reg == .imm32) return .{ .reg = .imm32, .comps = 1, .imm = .{ s.imm[0], 0, 0, 0 } };
        var o = g.opnd(s, ident4, 1);
        o.mode = .select1;
        o.swz = .{ s.swz[0], 0, 0, 0 };
        return o;
    }

    fn ifStmt(g: *Gen, node: ast.Node, tail: bool) void {
        const c = g.condSrc(node.a);
        if (g.failed) return;
        if (c.reg == .imm32) {
            // a known condition: only its side
            if (c.imm[0] != 0) g.stmt(node.b, tail) else g.stmt(node.c, tail);
            return;
        }
        var i = ir.Inst{ .op = .@"if", .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
        i.ops[0] = g.condOpnd(c);
        g.emit(i);
        g.stmt(node.b, tail);
        if (node.c != NONE) {
            g.emit(.{ .op = .@"else", .ndst = 0 });
            g.stmt(node.c, tail);
        }
        g.emit(.{ .op = .endif, .ndst = 0 });
    }

    fn breakc(g: *Gen, c: Src, nz: bool) void {
        var i = ir.Inst{ .op = .breakc, .ndst = 0, .n = 1, .ctl = if (nz) ir.CTL_NZ else 0 };
        i.ops[0] = g.condOpnd(c);
        g.emit(i);
    }

    fn loopStmt(g: *Gen, node: ast.Node) void {
        if (node.kind == .for_ and node.a != NONE) g.stmt(node.a, false);
        if (g.failed) return;
        if (node.kind == .for_ or node.kind == .while_) {
            // a loop that never runs: nothing
            if (node.a != NONE or node.kind == .for_) {
                const cn = if (node.kind == .for_) node.b else node.a;
                if (cn != NONE) {
                    const save = g.p.n;
                    const c = g.condSrc(cn);
                    g.p.n = save;
                    if (!g.failed and c.reg == .imm32 and c.imm[0] == 0) return;
                }
            }
        }
        g.emit(.{ .op = .loop, .ndst = 0 });
        g.pushFlow(.{ .kind = .loop, .step = if (node.kind == .for_) node.c else NONE, .cond = if (node.kind == .do_) node.a else NONE });
        const cn = if (node.kind == .for_) node.b else node.a;
        if (node.kind != .do_ and cn != NONE) {
            const c = g.condSrc(cn);
            if (!(c.reg == .imm32 and c.imm[0] != 0)) g.breakc(c, false);
        }
        g.stmt(node.d, false);
        if (node.kind == .do_) {
            const c = g.condSrc(node.a);
            if (!(c.reg == .imm32 and c.imm[0] != 0)) g.breakc(c, false);
        }
        if (node.kind == .for_ and node.c != NONE) _ = g.expr(node.c);
        g.emit(.{ .op = .endloop, .ndst = 0 });
        g.nflow -= 1;
        g.afterInner(containsReturn(g.a, node.d));
    }

    /// After an inner loop or switch: a return inside it leaves the
    /// enclosing one too (its flag).
    fn afterInner(g: *Gen, has_return: bool) void {
        if (!has_return or g.nfns == 0) return;
        const f = g.fns[g.nfns - 1];
        if (f.ret_flag == 0xffff_ffff) return;
        // (only when there is an enclosing flow of this function)
        if (g.nflow <= f.flow_base) return;
        g.breakc(tempSrc(f.ret_flag, 1), true);
    }

    fn switchStmt(g: *Gen, node: ast.Node) void {
        const sel0 = g.expr(node.a);
        if (g.failed) return;
        const st = g.a.types[sel0.ty];
        if (st.class != .scalar or !ast.isInt(st.base)) {
            if (!(st.class == .scalar and ast.isInt(ast.canon(st.base)))) return g.fail("switch needs an integer scalar", .{});
        }
        const sel = g.inTemp(g.plain(g.srcs[g.rows(sel0).at]));
        // the case values, in order
        const body = g.a.nodes[node.b];
        var has_default = false;
        var vals: [256]u32 = undefined;
        var nv: usize = 0;
        var s = body.a;
        while (s != NONE) : (s = g.a.nodes[s].next) {
            const k = g.a.nodes[s].kind;
            if (k == .default_) has_default = true;
            if (k == .case_) {
                const cv = g.expr(g.a.nodes[s].a);
                const ci = if (cv.kind == .srcs and cv.n == 1 and g.srcs[cv.at].reg == .imm32) g.srcs[g.rows(g.convert(cv, g.scalarTy(.int))).at].imm[0] else null;
                if (ci == null) return g.fail("case values must be literal integers", .{});
                if (nv < vals.len) {
                    vals[nv] = ci.?;
                    nv += 1;
                }
            }
        }
        // default: none of the values
        var is_default: Src = imm1(0xffff_ffff);
        if (has_default) {
            for (vals[0..nv]) |v| is_default = g.alu(.@"and", 1, &.{ is_default, g.alu(.ine, 1, &.{ sel, imm1(v) }) });
        }
        const matched = g.vreg();
        g.aluInto(.mov, .{ .vreg = matched, .n = 1 }, &.{imm1(0)});
        const cont_flag = g.vreg();
        const has_cont = containsContinue(g.a, node.b);
        if (has_cont) g.aluInto(.mov, .{ .vreg = cont_flag, .n = 1 }, &.{imm1(0)});
        g.emit(.{ .op = .loop, .ndst = 0 });
        g.pushFlow(.{ .kind = .switch_wrap, .cont_flag = if (has_cont) cont_flag else 0xffff_ffff });
        // each label sets `matched`; each run of statements runs if matched
        var open_if = false;
        s = body.a;
        while (s != NONE and !g.failed) : (s = g.a.nodes[s].next) {
            const sn = g.a.nodes[s];
            if (sn.kind == .case_ or sn.kind == .default_) {
                if (open_if) {
                    g.emit(.{ .op = .endif, .ndst = 0 });
                    open_if = false;
                }
                var hit: Src = undefined;
                if (sn.kind == .case_) {
                    const cv = g.convert(g.expr(sn.a), g.scalarTy(.int));
                    hit = g.alu(.ieq, 1, &.{ sel, g.srcs[g.rows(cv).at] });
                } else hit = is_default;
                g.aluInto(.@"or", .{ .vreg = matched, .n = 1 }, &.{ tempSrc(matched, 1), hit });
                continue;
            }
            if (!open_if) {
                var i = ir.Inst{ .op = .@"if", .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
                i.ops[0] = g.condOpnd(tempSrc(matched, 1));
                g.emit(i);
                open_if = true;
            }
            g.stmt(s, false);
        }
        if (open_if) g.emit(.{ .op = .endif, .ndst = 0 });
        g.emit(.{ .op = .@"break", .ndst = 0 });
        g.emit(.{ .op = .endloop, .ndst = 0 });
        g.nflow -= 1;
        if (has_cont) {
            var i = ir.Inst{ .op = .continuec, .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
            i.ops[0] = g.condOpnd(tempSrc(cont_flag, 1));
            // (the enclosing loop's step first: a for loop's)
            if (g.nflow > 0) {
                const outer = g.flow[g.nflow - 1];
                if (outer.kind == .loop and outer.step != NONE) {
                    var j = ir.Inst{ .op = .@"if", .ndst = 0, .n = 1, .ctl = ir.CTL_NZ };
                    j.ops[0] = i.ops[0];
                    g.emit(j);
                    _ = g.expr(outer.step);
                    g.emit(.{ .op = .endif, .ndst = 0 });
                }
            }
            g.emit(i);
        }
        g.afterInner(containsReturn(g.a, node.b));
    }

    fn breakStmt(g: *Gen) void {
        if (g.nflow == 0 or g.flow[g.nflow - 1].kind == .func_wrap) return g.fail("break must be inside a loop or switch", .{});
        g.emit(.{ .op = .@"break", .ndst = 0 });
    }

    fn continueStmt(g: *Gen) void {
        // the innermost loop; switches between set their flag and break
        var k = g.nflow;
        while (k > 0) {
            k -= 1;
            const f = g.flow[k];
            if (f.kind == .func_wrap) break;
            if (f.kind == .switch_wrap) {
                if (k + 1 != g.nflow) return g.fail("continue through nested switches is not supported", .{});
                g.aluInto(.mov, .{ .vreg = f.cont_flag, .n = 1 }, &.{imm1(0xffff_ffff)});
                g.emit(.{ .op = .@"break", .ndst = 0 });
                return;
            }
            if (f.kind == .loop) {
                if (f.step != NONE) _ = g.expr(f.step);
                if (f.cond != NONE) {
                    const c = g.condSrc(f.cond);
                    if (!(c.reg == .imm32 and c.imm[0] != 0)) g.breakc(c, false);
                }
                g.emit(.{ .op = .@"continue", .ndst = 0 });
                return;
            }
        }
        g.fail("continue must be inside a loop", .{});
    }

    fn returnStmt(g: *Gen, node: ast.Node, tail: bool) void {
        if (g.nfns == 0) return g.fail("return outside a function", .{});
        const f = &g.fns[g.nfns - 1];
        if (node.a != NONE) {
            if (f.ret_ty == 0) return g.fail("void function returning a value", .{});
            const rn = g.a.nodes[node.a];
            const v = if (rn.kind == .init_list) g.initValue(node.a, f.ret_ty) else g.convert(g.expr(node.a), f.ret_ty);
            if (g.failed) return;
            if (f.direct) {
                f.direct_val = v;
            } else g.writeStorage(f.ret_ty, f.ret_base, v);
        }
        if (tail and g.nflow == f.flow_base) return;
        if (!f.wrapped) {
            // (a tail return inside if/else at the end: nothing after it runs)
            if (tail) return;
            return g.fail("internal: a return needs its function wrapped", .{});
        }
        // inside inner loops: the flag, then out of each
        if (g.nflow > f.flow_base + 1) g.aluInto(.mov, .{ .vreg = f.ret_flag, .n = 1 }, &.{imm1(0xffff_ffff)});
        g.emit(.{ .op = .@"break", .ndst = 0 });
    }

    // ── the entry point ──

    /// Generates `entry`: its globals placed, its body, its outputs.
    pub fn run(g: *Gen, entry_name: []const u8) bool {
        // the entry: the newest function of that name with a body
        var f: u32 = 0;
        var i: u32 = g.a.nsyms;
        while (i > 1) {
            i -= 1;
            const s = g.a.syms[i];
            if (s.kind == .function and s.flags & ast.F_DEFINED != 0 and std.mem.eql(u8, g.a.symName(i), entry_name)) {
                f = i;
                break;
            }
        }
        if (f == 0) {
            g.fail("entrypoint not found", .{});
            return false;
        }
        g.entry = f;
        g.cur_line = g.a.syms[f].line;
        g.placeGlobals();
        if (g.failed) return false;
        g.entryInputs(f);
        if (g.failed) return false;
        // statics: their initial values, in order
        for (g.a.globals[0..g.a.nglobals]) |s| {
            const sy = g.a.syms[s];
            if (sy.kind == .variable and sy.storage == .static_global) {
                g.cur_line = sy.line;
                g.declareVar(s);
                if (g.failed) return false;
            }
        }
        // the body, inlined as any call
        const fs = g.a.syms[f];
        var ctx = FnCtx{ .ret_ty = fs.ty, .sym = f, .flow_base = 0 };
        const nret = countReturns(g.a, fs.body);
        const last = lastStmt(g.a, fs.body);
        ctx.direct = nret == 1 and last != NONE and g.a.nodes[last].kind == .return_;
        ctx.wrapped = nonTailReturn(g.a, fs.body, true);
        if (fs.ty != 0 and !ctx.direct) {
            ctx.ret_rows = g.rowsOf(fs.ty);
            ctx.ret_base = g.storage(fs.ty);
        }
        if (ctx.wrapped) {
            ctx.ret_flag = g.vreg();
            g.aluInto(.mov, .{ .vreg = ctx.ret_flag, .n = 1 }, &.{imm1(0)});
            g.emit(.{ .op = .loop, .ndst = 0 });
            g.pushFlow(.{ .kind = .func_wrap });
        }
        g.fns[0] = ctx;
        g.nfns = 1;
        g.stmt(fs.body, !ctx.wrapped);
        if (ctx.wrapped) {
            g.emit(.{ .op = .@"break", .ndst = 0 });
            g.emit(.{ .op = .endloop, .ndst = 0 });
            g.nflow -= 1;
        }
        if (g.failed) return false;
        g.entryOutputs(f, g.fns[0]);
        g.emit(.{ .op = .ret, .ndst = 0 });
        return !g.failed;
    }

    /// cbuffers' slots, $Globals' variables, resources' registers.
    fn placeGlobals(g: *Gen) void {
        // explicit cbuffer slots first
        var used_slots: u32 = 0;
        for (g.a.globals[0..g.a.nglobals]) |s| {
            const sy = g.a.syms[s];
            if (sy.kind == .cbuffer and sy.reg_kind == 'b') used_slots |= @as(u32, 1) << @intCast(@min(sy.reg_index, 31));
        }
        // $Globals (when any uniform global exists)
        var has_globals = false;
        for (g.a.globals[0..g.a.nglobals]) |s| {
            const sy = g.a.syms[s];
            if (sy.kind == .variable and sy.storage == .global and !g.isObjectTy(sy.ty) and sy.flags & ast.F_STATIC == 0) has_globals = true;
        }
        if (has_globals) {
            const slot = lowestFree(used_slots);
            used_slots |= @as(u32, 1) << @intCast(slot);
            g.globals_cb = g.ncbs;
            g.cbs[g.ncbs] = .{ .sym = 0, .slot = slot };
            g.ncbs += 1;
            var off: u32 = 0;
            for (g.a.globals[0..g.a.nglobals]) |s| {
                const sy = g.a.syms[s];
                if (sy.kind != .variable or sy.storage != .global or g.isObjectTy(sy.ty) or sy.flags & ast.F_STATIC != 0) continue;
                var o: u32 = undefined;
                if (sy.reg_kind == 'c') {
                    o = sy.reg_index * 16;
                } else if (sy.packoffset != 0xffff_ffff) {
                    o = sy.packoffset;
                } else o = g.cbPlace(off, sy.ty);
                off = @max(off, o + g.cbSize(sy.ty));
                g.binds[s] = .{ .kind = .cb, .val = .{ .ty = sy.ty, .kind = .cb, .slot = slot, .off = o } };
            }
            g.cbs[g.globals_cb].size = (off + 15) / 16 * 16;
        }
        for (g.a.globals[0..g.a.nglobals]) |s| {
            const sy = g.a.syms[s];
            if (sy.kind != .cbuffer) continue;
            if (g.ncbs >= MAX_CB) return g.fail("too many constant buffers", .{});
            var slot: u32 = undefined;
            if (sy.reg_kind == 'b') slot = sy.reg_index else {
                slot = lowestFree(used_slots);
                used_slots |= @as(u32, 1) << @intCast(slot);
            }
            const ci = g.ncbs;
            g.cbs[ci] = .{ .sym = s, .slot = slot, .tbuffer = sy.flags & ast.F_TBUFFER != 0, .userpacked = sy.reg_kind == 'b' };
            g.ncbs += 1;
            var off: u32 = 0;
            for (0..sy.nparams) |k| {
                const m = sy.cbuf + @as(u32, @intCast(k));
                const ms = g.a.syms[m];
                var o: u32 = undefined;
                if (ms.packoffset != 0xffff_ffff) {
                    o = ms.packoffset;
                } else o = g.cbPlace(off, ms.ty);
                off = @max(off, o + g.cbSize(ms.ty));
                g.binds[m] = .{ .kind = .cb, .val = .{ .ty = ms.ty, .kind = .cb, .slot = slot, .off = o } };
            }
            g.cbs[ci].size = (off + 15) / 16 * 16;
        }
    }

    fn lowestFree(used: u32) u32 {
        var k: u32 = 0;
        while (k < 14 and used & (@as(u32, 1) << @intCast(k)) != 0) k += 1;
        return k;
    }

    /// A resource element's register (t# or s#): its own, or the lowest
    /// free one.
    pub fn resource(g: *Gen, sym: u32, elem: u32, kind: u8) u32 {
        for (g.res[0..g.nres]) |*r| if (r.sym == sym and r.elem == elem and r.kind == kind) return r.slot;
        const sy = g.a.syms[sym];
        var slot: u32 = 0;
        if (sy.reg_kind == kind) slot = sy.reg_index + elem else {
            // (the lowest register no other resource of this kind has)
            var free: u32 = 0;
            while (true) : (free += 1) {
                var taken = false;
                for (g.a.globals[0..g.a.nglobals]) |s2| {
                    const o = g.a.syms[s2];
                    if (o.kind == .variable and o.reg_kind == kind) {
                        const cnt = arrayCount(g, o.ty);
                        if (free >= o.reg_index and free < o.reg_index + cnt) taken = true;
                    }
                }
                for (g.res[0..g.nres]) |r| if (r.kind == kind and r.slot == free) {
                    taken = true;
                };
                if (!taken) break;
            }
            slot = free;
        }
        if (g.nres < MAX_RES) {
            g.res[g.nres] = .{ .sym = sym, .elem = elem, .kind = kind, .slot = slot };
            g.nres += 1;
        }
        return slot;
    }

    fn arrayCount(g: *Gen, t: u32) u32 {
        var x = g.a.types[t];
        var n: u32 = 1;
        while (x.class == .array) {
            n *= x.len;
            x = g.a.types[x.elem];
        }
        return n;
    }

    // ── signatures ──

    const SysName = struct { s: []const u8, v: u32 };
    const sysnames = [_]SysName{
        .{ .s = "SV_POSITION", .v = 1 },
        .{ .s = "SV_CLIPDISTANCE", .v = 2 },
        .{ .s = "SV_CULLDISTANCE", .v = 3 },
        .{ .s = "SV_RENDERTARGETARRAYINDEX", .v = 4 },
        .{ .s = "SV_VIEWPORTARRAYINDEX", .v = 5 },
        .{ .s = "SV_VERTEXID", .v = 6 },
        .{ .s = "SV_PRIMITIVEID", .v = 7 },
        .{ .s = "SV_INSTANCEID", .v = 8 },
        .{ .s = "SV_ISFRONTFACE", .v = 9 },
        .{ .s = "SV_SAMPLEINDEX", .v = 10 },
        .{ .s = "SV_TARGET", .v = 64 },
        .{ .s = "SV_DEPTH", .v = 65 },
        .{ .s = "SV_COVERAGE", .v = 66 },
    };

    fn sysValue(name: []const u8) ?u32 {
        var up: [64]u8 = undefined;
        if (name.len > up.len) return null;
        const u_ = std.ascii.upperString(&up, name);
        for (sysnames) |s| if (std.mem.eql(u8, u_, s.s)) return s.v;
        if (std.mem.startsWith(u8, u_, "SV_")) return 0xffff;
        return null;
    }

    fn compType(b: ast.Base) u32 {
        return switch (ast.canon(b)) {
            .int => 2,
            .uint, .bool => 1,
            else => 3,
        };
    }

    /// Each leaf of the entry's parameters with a semantic: inputs read
    /// from v# (their values bound to the parameters), outputs to temps.
    fn entryInputs(g: *Gen, f: u32) void {
        const fs = g.a.syms[f];
        var reg: u32 = 0;
        // GS: the input primitive and the stream
        for (0..fs.nparams) |k| {
            const psym = fs.params + @as(u32, @intCast(k));
            const ps = g.a.syms[psym];
            const t = g.a.types[ps.ty];
            if (t.class == .stream) {
                g.gs_output_topo = switch (t.dim) {
                    0 => 1,
                    1 => 3,
                    else => 5,
                };
                g.binds[psym] = .{ .kind = .stream, .val = .{ .ty = ps.ty, .kind = .object, .sym = psym } };
                continue;
            }
            if (ps.flags & ast.F_IN == 0) continue;
            if (g.target.stage == .geometry and ps.flags & ast.GS_PRIM != 0) {
                g.gsInput(psym, &reg);
                continue;
            }
            const v = g.inputLeaves(ps.ty, ps.sem_off, ps.sem_len, ps.sem_index, ps.flags, &reg);
            if (g.failed) return;
            if (ps.flags & ast.F_OUT != 0 or ps.flags & ast.F_ASSIGNED != 0) {
                const base = g.storage(ps.ty);
                g.writeStorage(ps.ty, base, v);
                g.binds[psym] = .{ .kind = .regs, .base = base };
            } else g.binds[psym] = .{ .kind = .val, .val = v };
        }
        // out parameters: storage now, written out at the end
        for (0..fs.nparams) |k| {
            const psym = fs.params + @as(u32, @intCast(k));
            const ps = g.a.syms[psym];
            if (ps.flags & ast.F_OUT == 0 or ps.flags & ast.F_IN != 0) continue;
            g.binds[psym] = .{ .kind = .regs, .base = g.storage(ps.ty) };
        }
        g.gs_max_vertex = fs.max_vertex;
    }

    fn gsInput(g: *Gen, psym: u32, reg: *u32) void {
        const ps = g.a.syms[psym];
        const t = g.a.types[ps.ty];
        if (t.class != .array) return g.fail("a geometry shader's input must be an array", .{});
        g.gs_in_vertices = t.len;
        g.gs_input_prim = if (ps.flags & ast.F_GS_POINT != 0) 1 else if (ps.flags & ast.F_GS_LINE != 0) 2 else if (ps.flags & ast.F_GS_TRIANGLE != 0) 3 else if (ps.flags & ast.F_GS_LINEADJ != 0) 6 else 7;
        // the elements of one vertex (registers), then each vertex's values
        const first_reg = reg.*;
        const one = g.inputLeaves(t.elem, ps.sem_off, ps.sem_len, ps.sem_index, ps.flags, reg);
        if (g.failed) return;
        const per = one.n;
        const all = g.newSrcs(per * t.len);
        for (0..t.len) |vtx| {
            for (0..per) |r| {
                var s = g.srcs[one.at + r];
                if (s.reg == .input) {
                    s.gs = true;
                    s.row = s.idx;
                    s.idx = @intCast(vtx);
                }
                g.srcs[all + vtx * per + r] = s;
            }
        }
        _ = first_reg;
        g.binds[psym] = .{ .kind = .gs_input, .val = mkVal(ps.ty, all, per * @as(u32, t.len)) };
    }

    /// Input elements for a value of type `t` (a struct's members each
    /// with its own semantic); the value reading them.
    fn inputLeaves(g: *Gen, t: u32, sem_off: u32, sem_len: u16, sem_index: u32, flags: u32, reg: *u32) Val {
        const x = g.a.types[t];
        if (x.class == .structure) {
            var parts: [64]Val = undefined;
            var np: usize = 0;
            var total: u32 = 0;
            for (0..x.len) |k| {
                const m = g.a.members[x.first + k];
                const v = g.inputLeaves(m.ty, m.sem_off, m.sem_len, m.sem_index, flags | m.flags, reg);
                if (g.failed) return v;
                if (np < parts.len) {
                    parts[np] = v;
                    np += 1;
                }
                total += v.n;
            }
            const first = g.newSrcs(total);
            var at: u32 = 0;
            for (parts[0..np]) |v| {
                for (0..v.n) |r| g.srcs[first + at + r] = g.srcs[v.at + r];
                at += v.n;
            }
            return mkVal(t, first, total);
        }
        if (sem_len == 0) {
            g.fail("missing semantic for an entry parameter", .{});
            return g.immVal(t, 0);
        }
        const name = g.a.name(sem_off, sem_len);
        const sys = sysValue(name);
        if (sys != null and sys.? == 0xffff) {
            g.fail("unknown system value '{s}'", .{name});
            return g.immVal(t, 0);
        }
        const n = g.rowsOf(t);
        const first = g.newSrcs(n);
        for (0..n) |r| {
            const info = g.rowInfo(t, @intCast(r));
            const mask: u8 = @intCast((@as(u32, 1) << @intCast(info.n)) - 1);
            var sv: u32 = sys orelse 0;
            // (SV_Position into a vertex shader is not a system value; SV_Target is an output's)
            if (g.target.stage == .vertex and sv == 1) sv = 0;
            var special: Reg = .null;
            if (sv == 7 and g.target.stage != .geometry) special = .null;
            if (sv == 66) special = .input_coverage_mask;
            if (sv == 7 and g.target.stage == .geometry) special = .input_primitive_id;
            if (special != .null) {
                g.srcs[first + r] = .{ .reg = special, .n = 1 };
                continue;
            }
            if (g.nins >= MAX_ELEMS) {
                g.fail("too many inputs", .{});
                return g.immVal(t, 0);
            }
            const vreg_ = reg.*;
            g.ins[g.nins] = .{ .name = name, .index = sem_index + @as(u32, @intCast(r)), .sys = sv, .comp = compType(info.base), .reg = vreg_, .mask = mask, .flags = flags };
            g.nins += 1;
            reg.* += 1;
            g.srcs[first + r] = .{ .reg = .input, .idx = vreg_, .n = info.n };
            // (bools come in as uints: 0 or 1 becomes false or true)
            if (info.base == .bool and sv != 9) g.srcs[first + r] = g.alu(.ine, info.n, &.{ g.srcs[first + r], imm1(0) });
        }
        return mkVal(t, first, n);
    }

    fn entryOutputs(g: *Gen, f: u32, ctx: FnCtx) void {
        const fs = g.a.syms[f];
        var reg: u32 = 0;
        if (g.target.stage == .geometry) {
            // GS outputs are declared by the stream's vertex type, written at Append
            return;
        }
        if (fs.ty != 0) {
            const v = if (ctx.direct) ctx.direct_val else g.readStorage(fs.ty, ctx.ret_base);
            g.outputLeaves(fs.ty, fs.sem_off, fs.sem_len, fs.sem_index, 0, v, &reg);
        }
        for (0..fs.nparams) |k| {
            const psym = fs.params + @as(u32, @intCast(k));
            const ps = g.a.syms[psym];
            if (ps.flags & ast.F_OUT == 0) continue;
            g.outputLeaves(ps.ty, ps.sem_off, ps.sem_len, ps.sem_index, 0, g.readVar(psym), &reg);
        }
    }

    /// Output elements for a value; their values moved to o# now.
    pub fn outputLeaves(g: *Gen, t: u32, sem_off: u32, sem_len: u16, sem_index: u32, flags: u32, v0: Val, reg: *u32) void {
        const x = g.a.types[t];
        const v = g.canonRows(v0);
        if (x.class == .structure) {
            var row: u32 = 0;
            for (0..x.len) |k| {
                const m = g.a.members[x.first + k];
                const nr = g.rowsOf(m.ty);
                g.outputLeaves(m.ty, m.sem_off, m.sem_len, m.sem_index, flags | m.flags, mkVal(m.ty, v.at + row, nr), reg);
                row += nr;
            }
            return;
        }
        if (sem_len == 0) return g.fail("missing semantic for the entry's output", .{});
        const name = g.a.name(sem_off, sem_len);
        const sys = sysValue(name);
        if (sys != null and sys.? == 0xffff) return g.fail("unknown system value '{s}'", .{name});
        const n = g.rowsOf(t);
        for (0..n) |r| {
            const info = g.rowInfo(t, @intCast(r));
            const mask: u8 = @intCast((@as(u32, 1) << @intCast(info.n)) - 1);
            const sv: u32 = sys orelse 0;
            const index = sem_index + @as(u32, @intCast(r));
            var o_reg: u32 = reg.*;
            var special: Reg = .null;
            if (g.target.stage == .pixel) {
                if (sv == 64 or sv == 0) {
                    o_reg = index;
                } else if (sv == 65) {
                    special = .output_depth;
                    o_reg = 0xffff_ffff;
                } else if (sv == 66) {
                    o_reg = 0xffff_ffff;
                }
            } else reg.* += 1;
            if (g.nouts >= MAX_ELEMS) return g.fail("too many outputs", .{});
            g.outs[g.nouts] = .{ .name = name, .index = index, .sys = if (g.target.stage == .pixel and sv == 0) 64 else sv, .comp = compType(info.base), .reg = o_reg, .mask = mask, .used = mask, .flags = flags, .special = special };
            g.nouts += 1;
            // (bools go out as 0 or 1? D3D keeps their bits)
            const s = g.srcs[v.at + r];
            var i = ir.Inst{ .op = .mov, .n = 2 };
            if (special == .output_depth) {
                i.ops[0] = .{ .reg = .output_depth, .comps = 1, .dims = 0, .mode = .mask };
                i.ops[1] = g.opnd(s, ident4, 1);
            } else {
                i.ops[0] = .{ .reg = .output, .comps = 4, .mode = .mask, .mask = @intCast(mask), .idx = .{ o_reg, 0 } };
                i.ops[1] = g.opnd(s, ident4, info.n);
            }
            g.emit(i);
        }
    }
};

// ── statement scans ────────────────────────────────────────────────────────

pub fn countReturns(a: *const Ast, n: u32) u32 {
    if (n == NONE) return 0;
    const node = a.nodes[n];
    return switch (node.kind) {
        .return_ => 1,
        .block => blk: {
            var c: u32 = 0;
            var s = node.a;
            while (s != NONE) : (s = a.nodes[s].next) c += countReturns(a, s);
            break :blk c;
        },
        .if_ => countReturns(a, node.b) + countReturns(a, node.c),
        .for_, .while_, .do_ => countReturns(a, node.d),
        .switch_ => countReturns(a, node.b),
        else => 0,
    };
}

pub fn containsReturn(a: *const Ast, n: u32) bool {
    return countReturns(a, n) > 0;
}

pub fn containsContinue(a: *const Ast, n: u32) bool {
    if (n == NONE) return false;
    const node = a.nodes[n];
    return switch (node.kind) {
        .continue_ => true,
        .block => blk: {
            var s = node.a;
            while (s != NONE) : (s = a.nodes[s].next) if (containsContinue(a, s)) break :blk true;
            break :blk false;
        },
        .if_ => containsContinue(a, node.b) or containsContinue(a, node.c),
        // (a loop inside has its own continues)
        .switch_ => containsContinue(a, node.b),
        else => false,
    };
}

pub fn lastStmt(a: *const Ast, n: u32) u32 {
    if (n == NONE) return NONE;
    const node = a.nodes[n];
    if (node.kind != .block) return n;
    var s = node.a;
    var last: u32 = NONE;
    while (s != NONE) : (s = a.nodes[s].next) last = s;
    return last;
}

/// Whether a return appears where code of the function would still run
/// after it (so the body needs a once-loop to leave by).
pub fn nonTailReturn(a: *const Ast, n: u32, tail: bool) bool {
    if (n == NONE) return false;
    const node = a.nodes[n];
    return switch (node.kind) {
        .return_ => !tail,
        .block => blk: {
            var s = node.a;
            while (s != NONE) : (s = a.nodes[s].next) {
                if (nonTailReturn(a, s, tail and a.nodes[s].next == NONE)) break :blk true;
            }
            break :blk false;
        },
        .if_ => nonTailReturn(a, node.b, tail) or nonTailReturn(a, node.c, tail),
        .for_, .while_, .do_ => containsReturn(a, node.d),
        .switch_ => containsReturn(a, node.b),
        else => false,
    };
}

// ── swizzles ───────────────────────────────────────────────────────────────

/// `xyzw` / `rgba` names: their components (null: not a swizzle of a
/// `cols`-wide vector).
pub fn swizzle(s: []const u8, cols: u8, out: *[4]u2) ?u8 {
    if (s.len == 0 or s.len > 4) return null;
    var set: u8 = 0;
    for (s, 0..) |c, k| {
        const v: u2, const which: u8 = switch (c) {
            'x' => .{ 0, 1 },
            'y' => .{ 1, 1 },
            'z' => .{ 2, 1 },
            'w' => .{ 3, 1 },
            'r' => .{ 0, 2 },
            'g' => .{ 1, 2 },
            'b' => .{ 2, 2 },
            'a' => .{ 3, 2 },
            else => return null,
        };
        if (set != 0 and set != which) return null;
        set = which;
        if (v >= cols) return null;
        out[k] = v;
    }
    return @intCast(s.len);
}

/// `_m00_m11` (zero-based) and `_11_22` (one-based) matrix swizzles.
pub fn matSwizzle(s: []const u8, out: *[4][2]u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '_' or n >= 4) return null;
        i += 1;
        if (i < s.len and s[i] == 'm') {
            if (i + 2 >= s.len + 0 and i + 2 > s.len) return null;
            if (i + 2 >= s.len + 1) return null;
            const r = s[i + 1];
            const c = s[i + 2];
            if (r < '0' or r > '3' or c < '0' or c > '3') return null;
            out[n] = .{ r - '0', c - '0' };
            i += 3;
        } else {
            if (i + 1 >= s.len + 0 and i + 1 > s.len) return null;
            if (i + 1 >= s.len) return null;
            const r = s[i];
            const c = s[i + 1];
            if (r < '1' or r > '4' or c < '1' or c > '4') return null;
            out[n] = .{ r - '1', c - '1' };
            i += 2;
        }
        n += 1;
    }
    return if (n > 0) n else null;
}

// ── folding ────────────────────────────────────────────────────────────────

pub fn applyMods(w: u32, mods: u2) u32 {
    var x = w;
    if (mods & 2 != 0) x &= 0x7fff_ffff;
    if (mods & 1 != 0) x ^= 0x8000_0000;
    return x;
}

pub fn floatOp(op: Op) bool {
    return switch (op) {
        .add, .mul, .div, .mad, .min, .max, .eq, .ne, .lt, .ge, .frc, .round_ne, .round_ni, .round_pi, .round_z, .exp, .log, .rsq, .sqrt, .rcp, .mov, .movc, .dp2, .dp3, .dp4, .ftoi, .ftou, .deriv_rtx, .deriv_rty, .deriv_rtx_coarse, .deriv_rtx_fine, .deriv_rty_coarse, .deriv_rty_fine, .sincos, .f32tof16 => true,
        else => false,
    };
}

fn foldN(op: Op, n: u8, s: []const Src, sat: bool) ?Src {
    var r = Src{ .reg = .imm32, .n = n };
    for (0..4) |c| {
        var w: [3]u32 = .{ 0, 0, 0 };
        for (s, 0..) |x, k| {
            const v = if (x.n == 1) x.imm[0] else x.imm[@min(c, 3)];
            w[k] = if (floatOp(op)) applyMods(v, x.mods) else v;
        }
        var res = fold(op, w[0], w[1], w[2]) orelse return null;
        if (sat) {
            const f: f32 = @bitCast(res);
            res = @bitCast(std.math.clamp(f, 0.0, 1.0));
        }
        r.imm[c] = res;
    }
    return r;
}

fn F(w: u32) f32 {
    return @bitCast(w);
}

fn B(f: f32) u32 {
    return @bitCast(f);
}

fn I(w: u32) i32 {
    return @bitCast(w);
}

fn bl(b: bool) u32 {
    return if (b) 0xffff_ffff else 0;
}

/// An op on immediates (the scalar each component computes); null when it
/// is not folded.
pub fn fold(op: Op, a: u32, b: u32, c: u32) ?u32 {
    return switch (op) {
        .mov => a,
        .movc => if (a != 0) b else c,
        .add => B(F(a) + F(b)),
        .mul => B(F(a) * F(b)),
        .div => B(F(a) / F(b)),
        .mad => B(F(a) * F(b) + F(c)),
        .min => B(@min(F(a), F(b))),
        .max => B(@max(F(a), F(b))),
        .eq => bl(F(a) == F(b)),
        .ne => bl(F(a) != F(b)),
        .lt => bl(F(a) < F(b)),
        .ge => bl(F(a) >= F(b)),
        .frc => B(F(a) - @floor(F(a))),
        .round_ne => B(@round(F(a))),
        .round_ni => B(@floor(F(a))),
        .round_pi => B(@ceil(F(a))),
        .round_z => B(@trunc(F(a))),
        .sqrt => B(@sqrt(F(a))),
        .rsq => B(1.0 / @sqrt(F(a))),
        .rcp => B(1.0 / F(a)),
        .exp => B(@exp2(F(a))),
        .log => B(@log2(F(a))),
        .iadd => a +% b,
        .imul => a *% b,
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .not => ~a,
        .ineg => 0 -% a,
        .ishl => a << @intCast(b & 31),
        .ushr => a >> @intCast(b & 31),
        .ishr => @bitCast(I(a) >> @intCast(b & 31)),
        .ieq => bl(a == b),
        .ine => bl(a != b),
        .ilt => bl(I(a) < I(b)),
        .ige => bl(I(a) >= I(b)),
        .ult => bl(a < b),
        .uge => bl(a >= b),
        .imin => @bitCast(@min(I(a), I(b))),
        .imax => @bitCast(@max(I(a), I(b))),
        .umin => @min(a, b),
        .umax => @max(a, b),
        .imad => a *% b +% c,
        .umad => a *% b +% c,
        .itof => B(@floatFromInt(I(a))),
        .utof => B(@floatFromInt(a)),
        .ftoi => blk: {
            const f = F(a);
            if (std.math.isNan(f)) break :blk 0;
            break :blk @bitCast(@as(i32, @intFromFloat(std.math.clamp(@trunc(f), -2147483648.0, 2147483520.0))));
        },
        .ftou => blk: {
            const f = F(a);
            if (std.math.isNan(f) or f <= 0) break :blk 0;
            break :blk @intFromFloat(@min(@trunc(f), 4294967040.0));
        },
        .bfrev => @bitReverse(a),
        .countbits => @popCount(a),
        else => null,
    };
}
