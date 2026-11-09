//! @zpm/gfxapi glsl/gen — a checked GLSL shader as KIR, emitted into a
//! raster kernel (raster.sig) where its vertex or fragment code runs.
//!
//! A value is a list of KIR operands, one per scalar component (a
//! struct's and an array's flattened in order): registers, or immediates
//! for constants. Swizzles, fields and constant indices only pick from
//! the list; no code. Bools are preds; floats f32; ints i32; uints and
//! samplers u32.
//!
//! Variables are SSA: a variable is its components' current values, and
//! an assignment in straight code only rebinds them (no instruction).
//! Before an if, a loop, a switch or a function's early-return loop, the
//! variables it may write (found in it, and in the functions it calls)
//! move into registers of their own, which writes inside then `set`. (A
//! register written more than once lives through every loop around it,
//! the raster's triangle loop too: the fewer, the more a GPU's group
//! fits.)
//!
//! - Uniforms are words of the uniform binding (the link's tight layout):
//!   small ones loaded once at the shader's start, arrays loaded where
//!   indexed (a dynamic index clamped to the array: the GPU never reads
//!   past it).
//! - A dynamic index into registers picks among every element (a select
//!   chain for a read, a select per element for a write); an index out of
//!   range reads the first element and writes none.
//! - Functions are inlined (GLSL ES has no recursion). A function whose
//!   `return` is not its last statement runs in a loop it leaves: a
//!   `return` breaks out, through the loops around it with a flag.
//! - Loops are KIR loops: `for` runs its step at the top of each pass but
//!   the first, so `continue` (KIR's cont) still steps. A switch is a loop
//!   left by `break`, its cases a flag that falls through.
//! - `discard` drops the fragment (the raster's discard pred); in main it
//!   also returns.
//! - Integer division is exact: shifts for powers of two, else 32 steps
//!   of long division.
//! - Samplers are their texture slots (immediates, so passed to functions
//!   as values); a texture function reads the slot's binding through its
//!   descriptor (texture.sig). A fragment shader's implicit level of
//!   detail comes from its coordinates' derivatives (so such a program
//!   runs whole quads), plus a bias if given; textureLod's and
//!   textureGrad's are their arguments'; a vertex shader's is the base
//!   level.
//! - Derivatives (dFdx, dFdy, fwidth) are differences with the quad's
//!   neighbour pixel, through a shuffle: the raster runs whole quads for a
//!   program that takes them (FragmentIO.quads). In control flow that is
//!   not uniform (an if, a loop's exit, a return or discard on a value
//!   that differs between pixels) GL leaves them undefined: here they
//!   are 0 (`flattenDerivs`).
//! - Not yet: a sampler chosen at run time, gl_FragDepth, gl_PointSize.
//!
//! Allocation-free: its tables are the Scratch's (Store).

const std = @import("std");
const gpu = @import("gpu");
const raster = @import("../raster.sig");
const texture = @import("../texture.sig");
const glsl = @import("glsl.sig");
const lex = @import("lex.sig");
const pp = @import("pp.sig");
const parse = @import("parse.sig");
const sema = @import("sema.sig");

const kir = gpu.kir;
const V = kir.V;
const Arg = kir.Arg;
const Ty = kir.Ty;
const r = kir.r;
const u = kir.u;
const f = kir.f;
const no = kir.no;
const Type = sema.Type;
const Base = sema.Base;
const Node = parse.Node;
const Q = parse.Q;
const Kind = lex.Kind;
const FLOAT = sema.FLOAT;
const INT = sema.INT;
const BOOL = sema.BOOL;

/// Where the program put each name of the interface (the link's answers).
pub const Layout = struct {
    ctx: *const anyopaque,
    /// a vertex input's location
    attrib: *const fn (*const anyopaque, []const u8) ?u32,
    /// a uniform's first word (a struct's or an array's first leaf)
    uniform: *const fn (*const anyopaque, []const u8) ?u32,
    /// a varying's first scalar
    varying: *const fn (*const anyopaque, []const u8) ?u32,
    /// a fragment output's location
    output: *const fn (*const anyopaque, []const u8) ?u32,
    /// a sampler's texture slot, by its uniform word
    sampler: *const fn (*const anyopaque, u32) ?u32,
    /// where the slots' descriptors start in the uniform binding
    desc_base: u32,
};

/// A sampler the program has no slot for.
const NO_SLOT: u32 = 0xffff;

pub const MAX_COMPS = 1 << 18;
pub const MAX_VARS = 4096;
pub const MAX_FUNCS = 512;
/// Shuffles derivatives make in a shader (a vector's take one a component).
pub const MAX_DERIVS = 1024;
/// Instructions and registers the derivatives' flow check covers (a kernel
/// past them: every derivative 0).
const FLOW_BITS = 65536;
const MAX_FRAMES = 32;
const MAX_LOOPS = 64;
const MAX_SCOPES = 256;
/// elements a dynamic index may choose among
const MAX_CAND = 256;
/// a uniform this small (words), with no array in it, is loaded at the start
const PRELOAD_WORDS = 16;

const Var = struct {
    name: []const u8,
    ty: Type,
    at: u32 = 0,
    mem: bool = false,
    word: u32 = 0,
    /// never written (const, uniforms, inputs)
    ro: bool = false,
};

/// The generator's tables (in the Scratch).
pub const Store = struct {
    comps: [MAX_COMPS]Arg = undefined,
    /// an lvalue's components: the slot (in comps) each one writes
    slots: [MAX_COMPS]u32 = undefined,
    vars: [MAX_VARS]Var = undefined,
    funcs: [MAX_FUNCS]u32 = undefined,
    /// registers variables live in (written with `set`), a bit each
    mut: [65536 / 8]u8 = undefined,
    /// the derivatives' shuffles (instruction indices), and whether each
    /// is in control flow that is not uniform
    derivs: [MAX_DERIVS]u32 = undefined,
    deriv_div: [MAX_DERIVS]bool = undefined,
    /// flattenDerivs': divergent registers; loops left in divergent flow;
    /// loops that run one pass (each a bit, by instruction)
    div: [FLOW_BITS / 8]u8 = undefined,
    loop_div: [FLOW_BITS / 8]u8 = undefined,
    one_pass: [FLOW_BITS / 8]u8 = undefined,
};

/// A value: `ncand` candidates of size(ty) operands at comps[at..] (a
/// dynamic index chooses one by idx), or words of the uniform binding.
const Val = struct {
    ty: Type,
    at: u32 = 0,
    ncand: u32 = 1,
    idx: Arg = no,
    mem: bool = false,
    word: u32 = 0,
    /// a dynamic byte offset (u32) in the uniform binding
    dyn: Arg = no,
    /// a variable's components: slots[at..] are where writes go
    lval: bool = false,
};

const LoopKind = enum { user, swtch, func };

const Loop = struct {
    kind: LoopKind,
    /// a return inside: after it ends, the next loop out is left too
    ret_inside: bool = false,
    /// a switch: a `continue` inside it (for the loop around), and whether
    /// one was written
    cont: V = .none,
    used_cont: bool = false,
};

const Frame = struct {
    ret: ?Val,
    wrapper: bool,
    done: V = .none,
    loop_base: u32,
    var_base: u32,
    main: bool,
};

const Gen = struct {
    s: *glsl.Scratch,
    st: *Store,
    k: *kir.Kernel,
    lay: Layout,
    log: *pp.Log,
    stage: sema.Stage,
    uni: u8,
    /// the first texture's binding
    texb: u8,
    ncomps: u32 = 0,
    nvars: u32 = 0,
    nglobals: u32 = 0,
    nfuncs: u32 = 0,
    scopes: [MAX_SCOPES]u32 = undefined,
    nscopes: u32 = 0,
    frames: [MAX_FRAMES]Frame = undefined,
    nframes: u32 = 0,
    loops: [MAX_LOOPS]Loop = undefined,
    nloops: u32 = 0,
    discard: V = .none,
    failed: bool = false,
    /// fragment: whole quads run (derivatives are shuffles), and each
    /// pixel's place in its quad
    quads: bool = false,
    odd_x: V = .none,
    odd_y: V = .none,
    nderivs: u32 = 0,
    /// a derivative was generated
    derivatives: bool = false,

    fn node(g: *Gen, i: u32) *Node {
        return &g.s.parser.nodes[i];
    }
    fn text(g: *Gen, tok: u32) []const u8 {
        return g.s.parser.toks[tok].text;
    }

    fn fail(g: *Gen, line: u32, comptime fmt: []const u8, args: anytype) void {
        if (!g.failed) g.log.err(line, fmt, args);
        g.failed = true;
    }

    // ── Types ──────────────────────────────────────────────────────────────

    fn size(g: *Gen, t: Type) u32 {
        const one: u32 = if (t.base == .structure) blk: {
            var n: u32 = 0;
            for (g.s.checker.structFields(t)) |fd| n += g.size(fd.ty);
            break :blk n;
        } else if (t.sampler()) 1 else t.comps();
        return if (t.array != 0) one * t.array else one;
    }

    /// The base type of flattened component i of t.
    fn baseAt(g: *Gen, t: Type, first: u32) Base {
        const e = t.elem();
        var ix = first % @max(g.size(e), 1);
        if (e.base != .structure) return e.base;
        for (g.s.checker.structFields(e)) |fd| {
            const n = g.size(fd.ty);
            if (ix < n) return g.baseAt(fd.ty, ix);
            ix -= n;
        }
        return .float;
    }

    fn hasSampler(g: *Gen, t: Type) bool {
        if (t.sampler()) return true;
        if (t.base != .structure) return false;
        for (g.s.checker.structFields(t)) |fd| {
            if (g.hasSampler(fd.ty)) return true;
        }
        return false;
    }

    fn hasArray(g: *Gen, t: Type) bool {
        if (t.array != 0) return true;
        if (t.base != .structure) return false;
        for (g.s.checker.structFields(t)) |fd| {
            if (g.hasArray(fd.ty)) return true;
        }
        return false;
    }

    // ── Component lists ────────────────────────────────────────────────────

    fn alloc(g: *Gen, n: u32) u32 {
        if (g.ncomps + n > MAX_COMPS) {
            g.fail(0, "the shader is too large to generate", .{});
            g.ncomps = 0;
        }
        const at = g.ncomps;
        g.ncomps += n;
        return at;
    }

    fn cp(g: *Gen, at: u32, i: u32) Arg {
        return g.st.comps[at + i];
    }

    fn put(g: *Gen, at: u32, i: u32, a: Arg) void {
        g.st.comps[at + i] = a;
    }

    fn isMut(g: *Gen, a: Arg) bool {
        if (a != .reg or a.reg == .none) return false;
        const x = @intFromEnum(a.reg);
        return g.st.mut[x >> 3] & (@as(u8, 1) << @intCast(x & 7)) != 0;
    }

    fn markMut(g: *Gen, v: V) void {
        const x = @intFromEnum(v);
        g.st.mut[x >> 3] |= @as(u8, 1) << @intCast(x & 7);
    }

    /// A variable's register as a value: copied (a later write would
    /// change it); anything else as it is.
    fn snap(g: *Gen, a: Arg) Arg {
        if (!g.isMut(a)) return a;
        return r(g.k.mov(g.k.tys[@intFromEnum(a.reg)], a));
    }

    fn snapVal(g: *Gen, v0: Val) Val {
        const v = g.rv(v0);
        const n = g.size(v.ty);
        const at = g.alloc(n);
        for (0..n) |ix| g.put(at, @intCast(ix), g.snap(g.cp(v.at, @intCast(ix))));
        return .{ .ty = v.ty, .at = at };
    }

    /// Fresh registers of the variables' kind (written with `set`), unset,
    /// as a place.
    fn mutVal(g: *Gen, t: Type) Val {
        const n = g.size(t);
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            const v = g.k.reg(kty(g.baseAt(t, i_)));
            g.markMut(v);
            g.put(at, i_, r(v));
            g.st.slots[at + i_] = at + i_;
        }
        return .{ .ty = t, .at = at, .lval = true };
    }

    /// A place of its own for a value of t, holding `value` (or zeros).
    fn selfVal(g: *Gen, t: Type, value: ?Val) Val {
        const n = g.size(t);
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            g.put(at, i_, if (value) |v| g.snap(g.cp(v.at, i_)) else u(0));
            g.st.slots[at + i_] = at + i_;
        }
        return .{ .ty = t, .at = at, .lval = true };
    }

    /// A new variable bound to `value` (an rvalue), or zeros.
    fn bind(g: *Gen, name: []const u8, t: Type, value: ?Val, ro: bool) void {
        const v = g.selfVal(t, value);
        g.declare(.{ .name = name, .ty = t, .at = v.at, .ro = ro });
    }

    /// A variable as a place: its components now, and their slots.
    fn place(g: *Gen, v: *const Var) Val {
        if (v.mem) return .{ .ty = v.ty, .mem = true, .word = v.word };
        const n = g.size(v.ty);
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            g.put(at, i_, g.cp(v.at, i_));
            g.st.slots[at + i_] = v.at + i_;
        }
        return .{ .ty = v.ty, .at = at, .lval = !v.ro };
    }

    /// Component `from` of v into at[i], and its slot when v is a place.
    fn pick(g: *Gen, at: u32, i_: u32, v: Val, from: u32) void {
        g.put(at, i_, g.cp(v.at, from));
        if (v.lval) g.st.slots[at + i_] = g.st.slots[v.at + from];
    }

    /// The variable into registers of its own (before a construct that
    /// may write it).
    fn materialize(g: *Gen, v: *const Var) void {
        if (v.ro or v.mem) return;
        const n = g.size(v.ty);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            const cur = g.cp(v.at, i_);
            if (g.isMut(cur)) continue;
            const reg = g.k.reg(kty(g.baseAt(v.ty, i_)));
            g.k.set(reg, .mov, cur, no, no);
            g.markMut(reg);
            g.put(v.at, i_, r(reg));
        }
    }

    // ── What a construct writes ────────────────────────────────────────────

    const Names = struct {
        list: [64][]const u8 = undefined,
        n: usize = 0,
        all: bool = false,

        fn add(ns: *Names, name: ?[]const u8) void {
            const nm = name orelse return;
            for (ns.list[0..ns.n]) |x| {
                if (std.mem.eql(u8, x, nm)) return;
            }
            if (ns.n == ns.list.len) {
                ns.all = true;
                return;
            }
            ns.list[ns.n] = nm;
            ns.n += 1;
        }
    };

    /// The variable an lvalue expression writes (its root name).
    fn rootName(g: *Gen, e: u32) ?[]const u8 {
        var x = e;
        while (x != 0) {
            const nd = g.node(x);
            switch (nd.kind) {
                .ident => return g.text(nd.tok),
                .field, .index => x = nd.a,
                else => return null,
            }
        }
        return null;
    }

    /// The names s may write: assignments, ++ and --, a call's arguments
    /// (out ones), and what the functions it calls write.
    fn scan(g: *Gen, s0: u32, ns: *Names, depth: u32) void {
        if (s0 == 0) return;
        const nd = g.node(s0);
        switch (nd.kind) {
            .block => {
                var c = nd.a;
                while (c != 0) : (c = g.node(c).next) g.scan(c, ns, depth);
            },
            .decl => {
                var v = nd.b;
                while (v != 0) : (v = g.node(v).next) g.scan(g.node(v).b, ns, depth);
            },
            .assign, .pre_inc, .pre_dec, .post_inc, .post_dec => {
                ns.add(g.rootName(nd.a));
                g.scan(nd.a, ns, depth);
                g.scan(nd.b, ns, depth);
            },
            .call => {
                const user = nd.a == 0 and nd.value == 0;
                const modf = nd.a == 0 and std.mem.eql(u8, g.text(nd.tok), "modf");
                var a = nd.b;
                var ix: u32 = 0;
                while (a != 0) : (a = g.node(a).next) {
                    if (user or (modf and ix == 1)) ns.add(g.rootName(a));
                    g.scan(a, ns, depth);
                    ix += 1;
                }
                if (user and depth < 16) {
                    const name = g.text(nd.tok);
                    for (g.st.funcs[0..g.nfuncs]) |fx| {
                        if (std.mem.eql(u8, g.text(g.node(fx).tok), name)) g.scan(g.node(fx).c, ns, depth + 1);
                    }
                }
            },
            .ident, .int_lit, .uint_lit, .float_lit, .bool_lit, .type_spec => {},
            else => {
                g.scan(nd.a, ns, depth);
                g.scan(nd.b, ns, depth);
                g.scan(nd.c, ns, depth);
                g.scan(nd.d, ns, depth);
            },
        }
    }

    /// Before a construct of these parts: what they may write, into
    /// registers.
    fn prepare(g: *Gen, parts: []const u32) void {
        var ns = Names{};
        for (parts) |p| g.scan(p, &ns, 0);
        if (ns.all) {
            for (g.st.vars[0..g.nvars]) |*v| g.materialize(v);
            return;
        }
        for (ns.list[0..ns.n]) |name| {
            if (g.findVar(name)) |v| g.materialize(v);
        }
    }

    /// Whether a loop body has a continue of its own (not an inner loop's).
    fn hasContinue(g: *Gen, s0: u32) bool {
        if (s0 == 0) return false;
        const nd = g.node(s0);
        return switch (nd.kind) {
            .@"continue" => true,
            .block => blk: {
                var c = nd.a;
                while (c != 0) : (c = g.node(c).next) {
                    if (g.hasContinue(c)) break :blk true;
                }
                break :blk false;
            },
            .@"if" => g.hasContinue(nd.b) or g.hasContinue(nd.c),
            .@"switch" => g.hasContinue(nd.b),
            else => false,
        };
    }

    /// Whether a return (or main's discard) sits in a loop or switch of s.
    fn retIn(g: *Gen, s0: u32, main: bool, inloop: bool) bool {
        if (s0 == 0) return false;
        const nd = g.node(s0);
        return switch (nd.kind) {
            .@"return" => inloop,
            .discard => inloop and main,
            .block => blk: {
                var c = nd.a;
                while (c != 0) : (c = g.node(c).next) {
                    if (g.retIn(c, main, inloop)) break :blk true;
                }
                break :blk false;
            },
            .@"if" => g.retIn(nd.b, main, inloop) or g.retIn(nd.c, main, inloop),
            .@"for" => g.retIn(nd.d, main, true),
            .@"while" => g.retIn(nd.b, main, true),
            .do => g.retIn(nd.a, main, true),
            .@"switch" => g.retIn(nd.b, main, true),
            else => false,
        };
    }

    fn imms(g: *Gen, t: Type, vals: []const Arg) Val {
        const at = g.alloc(@intCast(vals.len));
        for (vals, 0..) |a, ix| g.put(at, @intCast(ix), a);
        return .{ .ty = t, .at = at };
    }

    fn zeros(g: *Gen, t: Type) Val {
        const n = g.size(t);
        const at = g.alloc(n);
        for (0..n) |ix| g.put(at, @intCast(ix), u(0));
        return .{ .ty = t, .at = at };
    }

    /// The value with one candidate in operands (loaded, or chosen).
    fn rv(g: *Gen, v: Val) Val {
        const n = g.size(v.ty);
        if (v.mem) {
            const at = g.alloc(n);
            for (0..n) |ix| {
                const i_: u32 = @intCast(ix);
                g.put(at, i_, g.loadUni(g.baseAt(v.ty, i_), v.word + i_, v.dyn));
            }
            return .{ .ty = v.ty, .at = at };
        }
        if (v.ncand <= 1) return .{ .ty = v.ty, .at = v.at };
        var preds: [MAX_CAND]V = undefined;
        for (1..v.ncand) |c| preds[c] = g.k.cmp(.u32, .eq, v.idx, u(@intCast(c)));
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            const ty = kty(g.baseAt(v.ty, i_));
            var res = g.cp(v.at, i_);
            for (1..v.ncand) |c| res = r(g.k.sel(ty, r(preds[c]), g.cp(v.at, @as(u32, @intCast(c)) * n + i_), res));
            g.put(at, i_, res);
        }
        return .{ .ty = v.ty, .at = at };
    }

    fn loadUni(g: *Gen, b: Base, word: u32, dyn: Arg) Arg {
        var m = kir.global(g.uni, 32);
        m.imm = @intCast(word * 4);
        const off = if (dyn == .reg and dyn.reg != .none) dyn else u(0);
        if (b == .bool) {
            const w = g.k.load(.u32, m, off);
            return r(g.k.cmp(.u32, .ne, r(w), u(0)));
        }
        return r(g.k.load(kty(b), m, off));
    }

    /// A component of an rvalue, a scalar broadcast.
    fn ca(g: *Gen, v: Val, i_: u32) Arg {
        return if (g.size(v.ty) == 1) g.cp(v.at, 0) else g.cp(v.at, i_);
    }

    /// Writes `src` into the place `dst`: a component in a register is
    /// `set`; any other is rebound to the new value (no code).
    fn store(g: *Gen, dst: Val, src0: Val) void {
        if (!dst.lval) return g.fail(0, "this cannot be written", .{});
        const n = g.size(dst.ty);
        var src = g.rv(src0);
        if (dst.ncand <= 1) {
            // (a source that reads a register this writes, elsewhere: copied first)
            var hazard = false;
            for (0..n) |ix| {
                const d = g.cp(g.st.slots[dst.at + ix], 0);
                if (!g.isMut(d)) continue;
                for (0..n) |jx| {
                    if (jx != ix and sameReg(d, g.cp(src.at, @intCast(jx)))) hazard = true;
                }
            }
            if (hazard) src = g.copy(src);
            for (0..n) |ix| {
                const i_: u32 = @intCast(ix);
                const slot = g.st.slots[dst.at + i_];
                const cur = g.cp(slot, 0);
                const a = g.cp(src.at, i_);
                if (g.isMut(cur)) {
                    if (!sameReg(cur, a)) g.k.set(cur.reg, .mov, a, no, no);
                } else g.put(slot, 0, g.snap(a));
            }
            return;
        }
        for (0..dst.ncand) |c| {
            const p = r(g.k.cmp(.u32, .eq, dst.idx, u(@intCast(c))));
            for (0..n) |ix| {
                const i_: u32 = @intCast(ix);
                const slot = g.st.slots[dst.at + @as(u32, @intCast(c)) * n + i_];
                const cur = g.cp(slot, 0);
                const a = g.cp(src.at, i_);
                if (g.isMut(cur)) {
                    g.k.set(cur.reg, .sel, a, cur, p);
                } else g.put(slot, 0, g.sel(kty(g.baseAt(dst.ty, i_)), p, g.snap(a), cur));
            }
        }
    }

    /// The value in fresh registers.
    fn copy(g: *Gen, v0: Val) Val {
        const v = g.rv(v0);
        const n = g.size(v.ty);
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            g.put(at, i_, r(g.k.mov(kty(g.baseAt(v.ty, i_)), g.cp(v.at, i_))));
        }
        return .{ .ty = v.ty, .at = at };
    }

    // ── Names ──────────────────────────────────────────────────────────────

    fn push(g: *Gen) void {
        if (g.nscopes == MAX_SCOPES) return g.fail(0, "blocks nest too deep", .{});
        g.scopes[g.nscopes] = g.nvars;
        g.nscopes += 1;
    }

    fn pop(g: *Gen) void {
        if (g.nscopes == 0) return;
        g.nscopes -= 1;
        g.nvars = g.scopes[g.nscopes];
    }

    fn declare(g: *Gen, v: Var) void {
        if (g.nvars == MAX_VARS) return g.fail(0, "too many variables", .{});
        g.st.vars[g.nvars] = v;
        g.nvars += 1;
    }

    fn findVar(g: *Gen, name: []const u8) ?*Var {
        const base = if (g.nframes > 0) g.frames[g.nframes - 1].var_base else g.nglobals;
        var ix = g.nvars;
        while (ix > base) {
            ix -= 1;
            if (std.mem.eql(u8, g.st.vars[ix].name, name)) return &g.st.vars[ix];
        }
        ix = @min(g.nglobals, g.nvars);
        while (ix > 0) {
            ix -= 1;
            if (std.mem.eql(u8, g.st.vars[ix].name, name)) return &g.st.vars[ix];
        }
        return null;
    }


    // ── Arithmetic on operands (immediates folded where exact) ─────────────

    fn fop2(g: *Gen, op: kir.Op, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) {
            const x: f32 = @bitCast(a.imm);
            const y: f32 = @bitCast(b.imm);
            const z: ?f32 = switch (op) {
                .fadd => x + y,
                .fsub => x - y,
                .fmul => x * y,
                .fdiv => x / y,
                else => null,
            };
            if (z) |v| return f(v);
        }
        if (op == .fdiv) {
            // x / 2^k is x * 2^-k exactly (the same real number, rounded
            // once); by another constant, x times its reciprocal (1.5 ulp)
            if (b == .imm) {
                const y: f32 = @bitCast(b.imm);
                return r(g.k.op2(.fmul, .f32, a, f(1.0 / y)));
            }
            const y = g.recip(b);
            if (a == .imm and a.imm == @as(u32, @bitCast(@as(f32, 1)))) return y;
            return r(g.k.op2(.fmul, .f32, a, y));
        }
        return r(g.k.op2(op, .f32, a, b));
    }

    /// 1 / b within GLSL's precision (2 ulp; a division x / b is x times
    /// it, 2.5 ulp as GLSL allows): frcp's seed (2^-21) and one Newton
    /// step, as GPUs divide (Mesa's ir3: rcp, then a multiply), not KIR's
    /// exact fdiv, which takes some 40 to 80 instructions. 0 and inf keep
    /// the seed's inf and 0.
    fn recip(g: *Gen, b: Arg) Arg {
        const k = g.k;
        const y0 = k.op1(.frcp, .f32, b);
        const t = k.op2(.fmul, .f32, b, r(y0));
        const y1 = k.op2(.fmul, .f32, r(y0), r(k.op2(.fsub, .f32, f(2), r(t))));
        // (b 0 or inf: b * y0 is NaN)
        return r(k.sel(.f32, r(k.cmp(.f32, .eq, r(t), r(t))), r(y1), r(y0)));
    }

    /// sqrt(x) within GLSL's precision (1 / inversesqrt's): frsq's seed and
    /// one Newton step, times x; 0 and inf themselves, < 0 NaN.
    fn sqrtOf(g: *Gen, x: Arg) Arg {
        if (x == .imm) return f(@sqrt(@as(f32, @bitCast(x.imm))));
        const k = g.k;
        const r0 = k.op1(.frsq, .f32, x);
        const h = k.op2(.fmul, .f32, x, f(0.5));
        const e = k.op2(.fsub, .f32, f(1.5), r(k.op2(.fmul, .f32, r(h), r(k.op2(.fmul, .f32, r(r0), r(r0))))));
        const s = k.op2(.fmul, .f32, x, r(k.op2(.fmul, .f32, r(r0), r(e))));
        // (0 and inf make NaN above: they are their own roots; < 0 NaN)
        const fallback = k.sel(.f32, r(k.cmp(.f32, .lt, x, f(0))), u(0x7fc0_0000), x);
        return r(k.sel(.f32, r(k.cmp(.f32, .eq, r(s), r(s))), r(s), r(fallback)));
    }

    fn fop1(g: *Gen, op: kir.Op, a: Arg) Arg {
        if (a == .imm and op == .fneg) return u(a.imm ^ 0x8000_0000);
        return r(g.k.op1(op, .f32, a));
    }

    fn iop2(g: *Gen, op: kir.Op, ty: Ty, a: Arg, b: Arg) Arg {
        if (a == .imm and b == .imm) {
            const x = a.imm;
            const y = b.imm;
            const z: ?u32 = switch (op) {
                .iadd => x +% y,
                .isub => x -% y,
                .imul => x *% y,
                .@"and" => x & y,
                .@"or" => x | y,
                .xor => x ^ y,
                .shl => x << @intCast(y & 31),
                .shr => if (ty == .i32) @as(u32, @bitCast(@as(i32, @bitCast(x)) >> @intCast(y & 31))) else x >> @intCast(y & 31),
                else => null,
            };
            if (z) |v| return u(v);
        }
        return r(g.k.op2(op, ty, a, b));
    }

    fn sel(g: *Gen, ty: Ty, p: Arg, a: Arg, b: Arg) Arg {
        if (p == .imm) return if (p.imm != 0) a else b;
        return r(g.k.sel(ty, p, a, b));
    }

    fn pnot(g: *Gen, p: Arg) Arg {
        if (p == .imm) return u(@intFromBool(p.imm == 0));
        return r(g.k.op1(.pnot, .pred, p));
    }

    fn pand(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm) return if (a.imm != 0) b else u(0);
        if (b == .imm) return if (b.imm != 0) a else u(0);
        return r(g.k.op2(.pand, .pred, a, b));
    }

    fn por(g: *Gen, a: Arg, b: Arg) Arg {
        if (a == .imm) return if (a.imm != 0) u(1) else b;
        if (b == .imm) return if (b.imm != 0) u(1) else a;
        return r(g.k.op2(.por, .pred, a, b));
    }

    fn cmpOf(g: *Gen, b: Base, c: kir.Cmp, x: Arg, y: Arg) Arg {
        if (b == .bool) {
            // (preds: equal when both or neither)
            const eq = g.por(g.pand(x, y), g.pand(g.pnot(x), g.pnot(y)));
            return if (c == .eq) eq else g.pnot(eq);
        }
        return r(g.k.cmp(kty(b), c, x, y));
    }

    /// Converts a component from one base type to another (GLSL's
    /// constructors).
    fn convert(g: *Gen, a: Arg, from: Base, to: Base) Arg {
        const fb: Base = if (isSampler(from)) .uint else from;
        if (fb == to) return a;
        if (a == .imm) {
            const x = a.imm;
            return switch (to) {
                .float => switch (fb) {
                    .int => f(@floatFromInt(@as(i32, @bitCast(x)))),
                    .uint => f(@floatFromInt(x)),
                    .bool => f(if (x != 0) 1 else 0),
                    else => a,
                },
                .int, .uint => switch (fb) {
                    .float => blk: {
                        const v: f32 = @bitCast(x);
                        if (std.math.isNan(v)) break :blk u(0);
                        if (to == .int) break :blk u(@bitCast(@as(i32, @intFromFloat(std.math.clamp(@trunc(v), -2147483648.0, 2147483520.0)))));
                        break :blk u(@intFromFloat(std.math.clamp(@trunc(v), 0, 4294967040.0)));
                    },
                    .bool => u(@intFromBool(x != 0)),
                    else => a,
                },
                .bool => u(@intFromBool(x != 0 and !(fb == .float and x == 0x8000_0000))),
                else => a,
            };
        }
        const k = g.k;
        return switch (to) {
            .float => switch (fb) {
                .int => r(k.cvt(.i32, .f32, .rne, a)),
                .uint => r(k.cvt(.u32, .f32, .rne, a)),
                .bool => g.sel(.f32, a, f(1), f(0)),
                else => a,
            },
            .int => switch (fb) {
                .float => r(k.cvt(.f32, .i32, .rz, a)),
                .bool => g.sel(.i32, a, u(1), u(0)),
                else => a,
            },
            .uint => switch (fb) {
                .float => r(k.cvt(.f32, .u32, .rz, a)),
                .bool => g.sel(.u32, a, u(1), u(0)),
                else => a,
            },
            .bool => switch (fb) {
                .float => r(k.cmp(.f32, .ne, a, f(0))),
                else => r(k.cmp(.u32, .ne, a, u(0))),
            },
            else => a,
        };
    }

    // ── Integer division, exact ────────────────────────────────────────────

    fn udiv(g: *Gen, a: Arg, b: Arg) [2]Arg {
        if (a == .imm and b == .imm) {
            if (b.imm == 0) return .{ u(0xffff_ffff), a };
            return .{ u(a.imm / b.imm), u(a.imm % b.imm) };
        }
        if (b == .imm and b.imm != 0 and std.math.isPowerOfTwo(b.imm)) {
            const sh: u32 = std.math.log2_int(u32, b.imm);
            return .{ g.iop2(.shr, .u32, a, u(sh)), g.iop2(.@"and", .u32, a, u(b.imm - 1)) };
        }
        const k = g.k;
        // long division, one bit a step (SSA: each step's values new)
        var q: Arg = u(0);
        var rem: Arg = u(0);
        var bit: u32 = 32;
        while (bit > 0) {
            bit -= 1;
            const in_bit = r(k.op3(.bfe, .u32, a, u(bit), u(1)));
            rem = g.iop2(.@"or", .u32, g.iop2(.shl, .u32, rem, u(1)), in_bit);
            const ge = r(k.cmp(.u32, .ge, rem, b));
            rem = g.sel(.u32, ge, g.iop2(.isub, .u32, rem, b), rem);
            q = g.iop2(.@"or", .u32, q, g.sel(.u32, ge, u(@as(u32, 1) << @intCast(bit)), u(0)));
        }
        return .{ q, rem };
    }

    /// Signed division and remainder, truncated toward zero.
    fn sdiv(g: *Gen, a: Arg, b: Arg) [2]Arg {
        if (a == .imm and b == .imm) {
            const x: i32 = @bitCast(a.imm);
            const y: i32 = @bitCast(b.imm);
            if (y == 0 or (y == -1 and x == std.math.minInt(i32))) return .{ u(0), a };
            return .{ u(@bitCast(@divTrunc(x, y))), u(@bitCast(@rem(x, y))) };
        }
        const k = g.k;
        if (b == .imm and @as(i32, @bitCast(b.imm)) > 0 and std.math.isPowerOfTwo(b.imm)) {
            const sh: u32 = std.math.log2_int(u32, b.imm);
            if (sh == 0) return .{ a, u(0) };
            const bias = k.op2(.shr, .u32, r(k.op2(.shr, .i32, a, u(31))), u(32 - sh));
            const q = k.op2(.shr, .i32, r(k.op2(.iadd, .i32, a, r(bias))), u(sh));
            const rem = k.op2(.isub, .i32, a, r(k.op2(.imul, .i32, r(q), b)));
            return .{ r(q), r(rem) };
        }
        const ua = r(k.op1(.iabs, .i32, a));
        const ub = if (b == .imm) u(@abs(@as(i32, @bitCast(b.imm)))) else r(k.op1(.iabs, .i32, b));
        const qr = g.udiv(ua, ub);
        const neg_q = k.cmp(.i32, .lt, r(k.op2(.xor, .i32, a, b)), u(0));
        const neg_r = k.cmp(.i32, .lt, a, u(0));
        const q = k.sel(.i32, r(neg_q), r(k.op1(.ineg, .i32, qr[0])), qr[0]);
        const rem = k.sel(.i32, r(neg_r), r(k.op1(.ineg, .i32, qr[1])), qr[1]);
        return .{ r(q), r(rem) };
    }

    // ── Expressions ────────────────────────────────────────────────────────

    fn expr(g: *Gen, e: u32) Val {
        const nd = g.node(e);
        const t = Type.of(nd.ty);
        return switch (nd.kind) {
            .int_lit, .uint_lit, .float_lit, .bool_lit => g.imms(t, &.{u(nd.value)}),
            .ident => g.ident(nd),
            .binary => g.binary(nd, t),
            .unary => g.unary(nd, t),
            .pre_inc, .pre_dec, .post_inc, .post_dec => g.incdec(nd, t),
            .assign => g.assign(nd),
            .ternary => g.ternary(nd, t),
            .sequence => blk: {
                _ = g.expr(nd.a);
                break :blk g.expr(nd.b);
            },
            .index => g.index(nd, t),
            .field => g.field(nd, t),
            .call => if (nd.a != 0) g.construct(nd, t) else g.call(nd, t),
            else => blk: {
                g.fail(nd.line, "this expression cannot be generated", .{});
                break :blk g.zeros(t);
            },
        };
    }

    /// A bool expression's pred.
    fn cond(g: *Gen, e: u32) Arg {
        const v = g.rv(g.expr(e));
        return g.cp(v.at, 0);
    }

    fn ident(g: *Gen, nd: *Node) Val {
        const name = g.text(nd.tok);
        const v = g.findVar(name) orelse {
            g.fail(nd.line, "`{s}` has no storage", .{name});
            return g.zeros(Type.of(nd.ty));
        };
        return g.place(v);
    }

    /// Whether evaluating e changes nothing (then both sides of ?:, && and
    /// || may run).
    fn pure(g: *Gen, e: u32) bool {
        if (e == 0) return true;
        const nd = g.node(e);
        switch (nd.kind) {
            .assign, .pre_inc, .pre_dec, .post_inc, .post_dec => return false,
            .call => {
                if (nd.a == 0) {
                    const name = g.text(nd.tok);
                    if (nd.value == 0 and !std.mem.eql(u8, name, "outerProduct")) return false;
                    if (std.mem.eql(u8, name, "modf")) return false;
                }
                var a = nd.b;
                while (a != 0) : (a = g.node(a).next) {
                    if (!g.pure(a)) return false;
                }
                return true;
            },
            .int_lit, .uint_lit, .float_lit, .bool_lit, .ident => return true,
            .field => return g.pure(nd.a),
            else => return g.pure(nd.a) and g.pure(nd.b) and g.pure(nd.c),
        }
    }

    fn binary(g: *Gen, nd: *Node, t: Type) Val {
        const op: Kind = @enumFromInt(nd.op);
        switch (op) {
            .and_and, .or_or => {
                const a = g.cond(nd.a);
                if (g.pure(nd.b)) {
                    const b = g.cond(nd.b);
                    return g.imms(BOOL, &.{if (op == .and_and) g.pand(a, b) else g.por(a, b)});
                }
                g.prepare(&.{nd.b});
                const res = g.k.reg(.pred);
                g.k.set(res, .mov, a, no, no);
                g.k.ifp(if (op == .and_and) a else g.pnot(a));
                g.k.set(res, .mov, g.cond(nd.b), no, no);
                g.k.endif();
                return g.imms(BOOL, &.{r(res)});
            },
            .xor_xor => {
                const a = g.cond(nd.a);
                const b = g.cond(nd.b);
                return g.imms(BOOL, &.{g.cmpOf(.bool, .ne, a, b)});
            },
            else => {},
        }
        const a = g.rv(g.expr(nd.a));
        const b = g.rv(g.expr(nd.b));
        return g.arith(op, a, b, t, nd.line);
    }

    /// `a op b` of type t (operands already rvalues).
    fn arith(g: *Gen, op: Kind, a: Val, b: Val, t: Type, line: u32) Val {
        switch (op) {
            .eq, .ne => {
                const n = g.size(a.ty);
                var all = u(1);
                for (0..n) |ix| {
                    const i_: u32 = @intCast(ix);
                    all = g.pand(all, g.cmpOf(g.baseAt(a.ty, i_), .eq, g.cp(a.at, i_), g.cp(b.at, i_)));
                }
                return g.imms(BOOL, &.{if (op == .eq) all else g.pnot(all)});
            },
            .lt, .gt, .le, .ge => {
                const c: kir.Cmp = switch (op) {
                    .lt => .lt,
                    .gt => .gt,
                    .le => .le,
                    else => .ge,
                };
                return g.imms(BOOL, &.{g.cmpOf(a.ty.base, c, g.cp(a.at, 0), g.cp(b.at, 0))});
            },
            else => {},
        }
        if (op == .star and (a.ty.matrix() or b.ty.matrix()) and !(a.ty.scalar() or b.ty.scalar())) return g.linear(a, b, t);
        const n = g.size(t);
        const at = g.alloc(n);
        const base = t.base;
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            const x = g.ca(a, i_);
            const y = g.ca(b, i_);
            g.put(at, i_, g.scalarOp(op, base, x, y, line));
        }
        return .{ .ty = t, .at = at };
    }

    fn scalarOp(g: *Gen, op: Kind, base: Base, x: Arg, y: Arg, line: u32) Arg {
        if (base == .float) {
            return switch (op) {
                .plus => g.fop2(.fadd, x, y),
                .minus => g.fop2(.fsub, x, y),
                .star => g.fop2(.fmul, x, y),
                .slash => g.fop2(.fdiv, x, y),
                else => blk: {
                    g.fail(line, "this float operator cannot be generated", .{});
                    break :blk f(0);
                },
            };
        }
        const ty: Ty = if (base == .int) .i32 else .u32;
        return switch (op) {
            .plus => g.iop2(.iadd, ty, x, y),
            .minus => g.iop2(.isub, ty, x, y),
            .star => g.iop2(.imul, ty, x, y),
            .slash => if (ty == .i32) g.sdiv(x, y)[0] else g.udiv(x, y)[0],
            .percent => if (ty == .i32) g.sdiv(x, y)[1] else g.udiv(x, y)[1],
            .amp => g.iop2(.@"and", ty, x, y),
            .pipe => g.iop2(.@"or", ty, x, y),
            .caret => g.iop2(.xor, ty, x, y),
            .shl => g.iop2(.shl, ty, x, y),
            .shr => g.iop2(.shr, ty, x, y),
            else => blk: {
                g.fail(line, "this integer operator cannot be generated", .{});
                break :blk u(0);
            },
        };
    }

    /// Matrix products: mat x mat, mat x vec, vec x mat (column-major).
    fn linear(g: *Gen, a: Val, b: Val, t: Type) Val {
        const n = g.size(t);
        const at = g.alloc(n);
        if (a.ty.matrix() and b.ty.matrix()) {
            const ra: u32 = a.ty.rows;
            const inner: u32 = a.ty.cols;
            for (0..b.ty.cols) |jx| {
                for (0..ra) |ix| {
                    var s: Arg = f(0);
                    for (0..inner) |kx| {
                        const p = g.fop2(.fmul, g.cp(a.at, @intCast(kx * ra + ix)), g.cp(b.at, @intCast(jx * inner + kx)));
                        s = if (kx == 0) p else g.fop2(.fadd, s, p);
                    }
                    g.put(at, @intCast(jx * ra + ix), s);
                }
            }
        } else if (a.ty.matrix()) {
            const ra: u32 = a.ty.rows;
            for (0..ra) |ix| {
                var s: Arg = f(0);
                for (0..a.ty.cols) |kx| {
                    const p = g.fop2(.fmul, g.cp(a.at, @intCast(kx * ra + ix)), g.cp(b.at, @intCast(kx)));
                    s = if (kx == 0) p else g.fop2(.fadd, s, p);
                }
                g.put(at, @intCast(ix), s);
            }
        } else {
            const rb: u32 = b.ty.rows;
            for (0..b.ty.cols) |jx| {
                var s: Arg = f(0);
                for (0..rb) |kx| {
                    const p = g.fop2(.fmul, g.cp(a.at, @intCast(kx)), g.cp(b.at, @intCast(jx * rb + kx)));
                    s = if (kx == 0) p else g.fop2(.fadd, s, p);
                }
                g.put(at, @intCast(jx), s);
            }
        }
        return .{ .ty = t, .at = at };
    }

    fn unary(g: *Gen, nd: *Node, t: Type) Val {
        const a = g.rv(g.expr(nd.a));
        const op: Kind = @enumFromInt(nd.op);
        if (op == .plus) return a;
        const n = g.size(t);
        const at = g.alloc(n);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            const x = g.cp(a.at, i_);
            g.put(at, i_, switch (op) {
                .bang => g.pnot(x),
                .tilde => g.iop2(.xor, .u32, x, u(0xffff_ffff)),
                else => if (t.base == .float) g.fop1(.fneg, x) else g.iop2(.isub, .i32, u(0), x),
            });
        }
        return .{ .ty = t, .at = at };
    }

    fn incdec(g: *Gen, nd: *Node, t: Type) Val {
        const dst = g.expr(nd.a);
        const cur = g.rv(dst);
        const post = nd.kind == .post_inc or nd.kind == .post_dec;
        const old = if (post) g.snapVal(cur) else cur;
        const one = if (t.base == .float) f(1) else u(1);
        const n = g.size(t);
        const at = g.alloc(n);
        const op: Kind = if (nd.kind == .pre_inc or nd.kind == .post_inc) .plus else .minus;
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            g.put(at, i_, g.scalarOp(op, t.base, g.cp(cur.at, i_), one, nd.line));
        }
        const nv = Val{ .ty = t, .at = at };
        g.store(dst, nv);
        return if (post) old else nv;
    }

    fn assign(g: *Gen, nd: *Node) Val {
        const dst = g.expr(nd.a);
        const op: Kind = @enumFromInt(nd.op);
        if (op == .assign) {
            const v = g.rv(g.expr(nd.b));
            g.store(dst, v);
            return v;
        }
        const bop: Kind = switch (op) {
            .add_assign => .plus,
            .sub_assign => .minus,
            .mul_assign => .star,
            .div_assign => .slash,
            .mod_assign => .percent,
            .shl_assign => .shl,
            .shr_assign => .shr,
            .and_assign => .amp,
            .xor_assign => .caret,
            else => .pipe,
        };
        const rhs = g.rv(g.expr(nd.b));
        const cur = g.rv(dst);
        const res = g.arith(bop, cur, rhs, dst.ty, nd.line);
        g.store(dst, res);
        return res;
    }

    fn ternary(g: *Gen, nd: *Node, t: Type) Val {
        const c = g.cond(nd.a);
        if (g.pure(nd.b) and g.pure(nd.c)) {
            const a = g.rv(g.expr(nd.b));
            const b = g.rv(g.expr(nd.c));
            const n = g.size(t);
            const at = g.alloc(n);
            for (0..n) |ix| {
                const i_: u32 = @intCast(ix);
                g.put(at, i_, g.sel(kty(g.baseAt(t, i_)), c, g.cp(a.at, i_), g.cp(b.at, i_)));
            }
            return .{ .ty = t, .at = at };
        }
        g.prepare(&.{ nd.b, nd.c });
        const tmp = g.mutVal(t);
        g.k.ifp(c);
        g.store(tmp, g.expr(nd.b));
        g.k.els();
        g.store(tmp, g.expr(nd.c));
        g.k.endif();
        return .{ .ty = t, .at = tmp.at };
    }

    /// Element `ix` (an operand) of v, whose elements are `esize` operands
    /// each, `len` of them, of type et.
    fn element(g: *Gen, v: Val, ix: Arg, et: Type, esize: u32, len: u32) Val {
        const n = g.size(v.ty);
        if (v.mem) {
            if (ix == .imm) {
                const kx = @min(ix.imm, len - 1);
                return .{ .ty = et, .mem = true, .word = v.word + kx * esize, .dyn = v.dyn };
            }
            const clamped = r(g.k.op2(.imin, .u32, ix, u(len - 1)));
            const off = g.iop2(.imul, .u32, clamped, u(esize * 4));
            const dyn = if (v.dyn == .reg and v.dyn.reg != .none) g.iop2(.iadd, .u32, v.dyn, off) else off;
            return .{ .ty = et, .mem = true, .word = v.word, .dyn = dyn };
        }
        if (ix == .imm) {
            const kx = @min(ix.imm, len - 1);
            const at = g.alloc(v.ncand * esize);
            for (0..v.ncand) |c| {
                for (0..esize) |jx| g.pick(at, @intCast(c * esize + jx), v, @intCast(c * n + kx * esize + jx));
            }
            return .{ .ty = et, .at = at, .ncand = v.ncand, .idx = v.idx, .lval = v.lval };
        }
        const ncand = v.ncand * len;
        if (ncand > MAX_CAND) {
            g.fail(0, "dynamic indices choose among too many elements ({d})", .{ncand});
            return g.zeros(et);
        }
        const at = g.alloc(ncand * esize);
        for (0..v.ncand) |c| {
            for (0..len) |e| {
                for (0..esize) |jx| g.pick(at, @intCast((c * len + e) * esize + jx), v, @intCast(c * n + e * esize + jx));
            }
        }
        const idx = if (v.ncand <= 1) ix else g.iop2(.iadd, .u32, g.iop2(.imul, .u32, v.idx, u(len)), ix);
        return .{ .ty = et, .at = at, .ncand = ncand, .idx = idx, .lval = v.lval };
    }

    fn index(g: *Gen, nd: *Node, t: Type) Val {
        const base = g.expr(nd.a);
        const ixv = g.rv(g.expr(nd.b));
        const ix = g.cp(ixv.at, 0);
        const bt = base.ty;
        const len: u32 = if (bt.array != 0) bt.array else if (bt.matrix()) bt.cols else bt.rows;
        return g.element(base, ix, t, g.size(t), len);
    }

    fn field(g: *Gen, nd: *Node, t: Type) Val {
        if (nd.op == 1) return g.imms(INT, &.{u(nd.value)});
        var base = g.expr(nd.a);
        const name = g.text(nd.tok);
        if (base.ty.base == .structure) {
            var off: u32 = 0;
            for (g.s.checker.structFields(base.ty)) |fd| {
                if (std.mem.eql(u8, fd.name, name)) break;
                off += g.size(fd.ty);
            }
            const fs = g.size(t);
            if (base.mem) return .{ .ty = t, .mem = true, .word = base.word + off, .dyn = base.dyn };
            const n = g.size(base.ty);
            const at = g.alloc(base.ncand * fs);
            for (0..base.ncand) |c| {
                for (0..fs) |jx| g.pick(at, @intCast(c * fs + jx), base, @intCast(c * n + off + jx));
            }
            return .{ .ty = t, .at = at, .ncand = base.ncand, .idx = base.idx, .lval = base.lval };
        }
        // a swizzle
        if (base.mem) base = g.rv(base);
        const n = g.size(base.ty);
        const at = g.alloc(base.ncand * @as(u32, @intCast(name.len)));
        for (0..base.ncand) |c| {
            for (name, 0..) |ch, jx| {
                const kx: u32 = switch (ch) {
                    'x', 'r', 's' => 0,
                    'y', 'g', 't' => 1,
                    'z', 'b', 'p' => 2,
                    else => 3,
                };
                g.pick(at, @intCast(c * name.len + jx), base, @intCast(c * n + kx));
            }
        }
        return .{ .ty = t, .at = at, .ncand = base.ncand, .idx = base.idx, .lval = base.lval };
    }

    // ── Constructors ───────────────────────────────────────────────────────

    fn construct(g: *Gen, nd: *Node, t: Type) Val {
        var args: [16]Val = undefined;
        var nargs: usize = 0;
        var a = nd.b;
        while (a != 0 and nargs < args.len) : (a = g.node(a).next) {
            args[nargs] = g.rv(g.expr(a));
            nargs += 1;
        }
        const n = g.size(t);
        const at = g.alloc(n);
        // structs and arrays: the arguments in order
        if (t.base == .structure or t.array != 0) {
            var w: u32 = 0;
            for (args[0..nargs]) |v| {
                const m = g.size(v.ty);
                for (0..m) |ix| {
                    if (w < n) g.put(at, w, g.cp(v.at, @intCast(ix)));
                    w += 1;
                }
            }
            return .{ .ty = t, .at = at };
        }
        const to = t.base;
        // one scalar: a vector filled, a matrix's diagonal
        if (nargs == 1 and g.size(args[0].ty) == 1) {
            const x = g.convert(g.cp(args[0].at, 0), args[0].ty.base, to);
            if (t.matrix()) {
                for (0..t.cols) |cx| {
                    for (0..t.rows) |rx| g.put(at, @intCast(cx * t.rows + rx), if (cx == rx) x else f(0));
                }
            } else for (0..n) |ix| g.put(at, @intCast(ix), x);
            return .{ .ty = t, .at = at };
        }
        // a matrix of a matrix: what overlaps, the identity elsewhere
        if (nargs == 1 and t.matrix() and args[0].ty.matrix()) {
            const m = args[0].ty;
            for (0..t.cols) |cx| {
                for (0..t.rows) |rx| {
                    const v = if (cx < m.cols and rx < m.rows) g.cp(args[0].at, @intCast(cx * m.rows + rx)) else if (cx == rx) f(1) else f(0);
                    g.put(at, @intCast(cx * t.rows + rx), v);
                }
            }
            return .{ .ty = t, .at = at };
        }
        // the arguments' components in order, converted
        var w: u32 = 0;
        for (args[0..nargs]) |v| {
            const m = g.size(v.ty);
            for (0..m) |ix| {
                if (w >= n) break;
                g.put(at, w, g.convert(g.cp(v.at, @intCast(ix)), v.ty.base, to));
                w += 1;
            }
        }
        while (w < n) : (w += 1) g.put(at, w, u(0));
        return .{ .ty = t, .at = at };
    }

    // ── Calls ──────────────────────────────────────────────────────────────

    fn call(g: *Gen, nd: *Node, t: Type) Val {
        const name = g.text(nd.tok);
        if (nd.value != 0 or std.mem.eql(u8, name, "outerProduct")) {
            if (nd.value == 0 and g.findFunc(nd, name) != null) return g.userCall(nd, t, name);
            return g.builtin(nd, t, name);
        }
        return g.userCall(nd, t, name);
    }

    /// The definition the call names (by its arguments' types).
    fn findFunc(g: *Gen, nd: *Node, name: []const u8) ?u32 {
        for (g.st.funcs[0..g.nfuncs]) |fx| {
            const fnode = g.node(fx);
            if (!std.mem.eql(u8, g.text(fnode.tok), name)) continue;
            var p = fnode.b;
            var a = nd.b;
            var ok = true;
            while (p != 0 and a != 0) {
                if (!Type.of(g.node(p).ty).eq(Type.of(g.node(a).ty))) ok = false;
                p = g.node(p).next;
                a = g.node(a).next;
            }
            if (ok and p == 0 and a == 0) return fx;
        }
        return null;
    }

    fn userCall(g: *Gen, nd: *Node, t: Type, name: []const u8) Val {
        const fx = g.findFunc(nd, name) orelse {
            g.fail(nd.line, "`{s}` has no definition", .{name});
            return g.zeros(t);
        };
        if (g.nframes >= MAX_FRAMES) {
            g.fail(nd.line, "calls nest too deep", .{});
            return g.zeros(t);
        }
        const fnode = g.node(fx);
        // the arguments, before the call: values for in, places for out
        var places: [32]Val = undefined;
        var vals: [32]Val = undefined;
        var np: usize = 0;
        var p = fnode.b;
        var a = nd.b;
        while (p != 0 and a != 0 and np < places.len) {
            const q = g.node(p).flags;
            const v = g.expr(a);
            places[np] = v;
            vals[np] = if (q & Q.in != 0 or q & Q.out == 0) g.rv(v) else v;
            np += 1;
            p = g.node(p).next;
            a = g.node(a).next;
        }
        const var_base = g.nvars;
        g.push();
        // the parameters: in ones bound to the arguments, out ones to zeros
        p = fnode.b;
        var ix: usize = 0;
        while (p != 0 and ix < np) : (ix += 1) {
            const pn = g.node(p);
            const pt = Type.of(pn.ty);
            const q = pn.flags;
            const pname = if (pn.tok != 0) g.text(pn.tok) else "";
            g.bind(pname, pt, if (q & Q.in != 0 or q & Q.out == 0) vals[ix] else null, false);
            p = pn.next;
        }
        const body = fnode.c;
        const wrapper = g.needsWrapper(body, false);
        // (the result: rebound by a lone last return, else registers each return sets)
        const ret: ?Val = if (t.base == .void) null else if (wrapper) g.mutVal(t) else g.selfVal(t, null);
        g.frames[g.nframes] = .{ .ret = ret, .wrapper = wrapper, .loop_base = g.nloops, .var_base = var_base, .main = false };
        g.nframes += 1;
        g.runBody(body, wrapper);
        g.nframes -= 1;
        // out and inout: the parameters back into the places
        p = fnode.b;
        ix = 0;
        while (p != 0 and ix < np) : (ix += 1) {
            const pn = g.node(p);
            if (pn.flags & Q.out != 0) {
                const v = g.findParam(var_base, ix);
                g.store(places[ix], v);
            }
            p = pn.next;
        }
        g.pop();
        return if (ret) |rv_| .{ .ty = t, .at = rv_.at } else g.zeros(t);
    }

    fn findParam(g: *Gen, base: u32, ix: usize) Val {
        const v = &g.st.vars[base + ix];
        return .{ .ty = v.ty, .at = v.at };
    }

    /// The body of a function (or main), in a loop when a return is not
    /// its last statement.
    fn runBody(g: *Gen, body: u32, wrapper: bool) void {
        const fr = &g.frames[g.nframes - 1];
        if (wrapper) {
            // (what the body writes may be left half done by a return: registers)
            g.prepare(&.{body});
            if (g.retIn(body, fr.main, false)) {
                fr.done = g.k.reg(.pred);
                g.k.set(fr.done, .mov, u(0), no, no);
            }
            g.openLoop(.func);
            g.k.loop();
        }
        g.push();
        var s = g.node(body).a;
        while (s != 0) : (s = g.node(s).next) g.stmt(s);
        g.pop();
        if (wrapper) {
            g.k.brk(u(1));
            g.k.endloop();
            g.nloops -= 1;
        }
    }

    /// Whether a body's returns need the loop: one is not its last
    /// statement (or a discard in main).
    fn needsWrapper(g: *Gen, body: u32, main: bool) bool {
        var last: u32 = 0;
        var s = g.node(body).a;
        while (s != 0) : (s = g.node(s).next) last = s;
        const n = g.countReturns(body, main);
        if (n == 0) return false;
        if (n == 1 and last != 0 and g.node(last).kind == .@"return") return false;
        return true;
    }

    fn countReturns(g: *Gen, s: u32, main: bool) u32 {
        if (s == 0) return 0;
        const nd = g.node(s);
        return switch (nd.kind) {
            .@"return" => 1,
            .discard => @intFromBool(main),
            .block => blk: {
                var n: u32 = 0;
                var c = nd.a;
                while (c != 0) : (c = g.node(c).next) n += g.countReturns(c, main);
                break :blk n;
            },
            .@"if" => g.countReturns(nd.b, main) + g.countReturns(nd.c, main),
            .@"for" => g.countReturns(nd.d, main),
            .@"while" => g.countReturns(nd.b, main),
            .do => g.countReturns(nd.a, main),
            .@"switch" => g.countReturns(nd.b, main),
            else => 0,
        };
    }

    // ── Built-in functions ─────────────────────────────────────────────────

    const Fn = enum {
        radians,
        degrees,
        sin,
        cos,
        tan,
        asin,
        acos,
        atan,
        sinh,
        cosh,
        tanh,
        asinh,
        acosh,
        atanh,
        pow,
        exp,
        log,
        exp2,
        log2,
        sqrt,
        inversesqrt,
        abs,
        sign,
        floor,
        trunc,
        round,
        roundEven,
        ceil,
        fract,
        mod,
        modf,
        min,
        max,
        clamp,
        mix,
        step,
        smoothstep,
        isnan,
        isinf,
        floatBitsToInt,
        floatBitsToUint,
        intBitsToFloat,
        uintBitsToFloat,
        packSnorm2x16,
        unpackSnorm2x16,
        packUnorm2x16,
        unpackUnorm2x16,
        packHalf2x16,
        unpackHalf2x16,
        length,
        distance,
        dot,
        cross,
        normalize,
        faceforward,
        reflect,
        refract,
        matrixCompMult,
        transpose,
        determinant,
        inverse,
        outerProduct,
        lessThan,
        lessThanEqual,
        greaterThan,
        greaterThanEqual,
        equal,
        notEqual,
        any,
        all,
        not,
        dFdx,
        dFdy,
        fwidth,
    };

    fn builtin(g: *Gen, nd: *Node, t: Type, name: []const u8) Val {
        var args: [6]Val = undefined;
        var nargs: usize = 0;
        var a = nd.b;
        while (a != 0 and nargs < args.len) : (a = g.node(a).next) {
            args[nargs] = g.expr(a);
            nargs += 1;
        }
        if (std.meta.stringToEnum(TexFn, name)) |tf| return g.textureCall(nd, t, tf, args[0..nargs]);
        const which = std.meta.stringToEnum(Fn, name) orelse {
            g.fail(nd.line, "`{s}` cannot be generated yet", .{name});
            return g.zeros(t);
        };
        // (every argument a value, but modf's second: a place)
        var v: [6]Val = undefined;
        for (args[0..nargs], 0..) |x, ix| v[ix] = if (which == .modf and ix == 1) x else g.rv(x);
        const n = g.size(t);
        const at = g.alloc(@max(n, 1));
        const out = Val{ .ty = t, .at = at };
        switch (which) {
            .radians, .degrees => {
                const m: f32 = if (which == .radians) std.math.pi / 180.0 else 180.0 / std.math.pi;
                for (0..n) |ix| g.put(at, @intCast(ix), g.fop2(.fmul, g.ca(v[0], @intCast(ix)), f(m)));
            },
            .sin, .cos, .exp2, .log2, .floor, .ceil, .trunc, .round, .roundEven => {
                const op: kir.Op = switch (which) {
                    .sin => .fsin,
                    .cos => .fcos,
                    .exp2 => .fexp2,
                    .log2 => .flog2,
                    .floor => .ffloor,
                    .ceil => .fceil,
                    .trunc => .ftrunc,
                    else => .frne,
                };
                for (0..n) |ix| g.put(at, @intCast(ix), g.fop1(op, g.ca(v[0], @intCast(ix))));
            },
            .sqrt => for (0..n) |ix| g.put(at, @intCast(ix), g.sqrtOf(g.ca(v[0], @intCast(ix)))),
            .inversesqrt => for (0..n) |ix| g.put(at, @intCast(ix), g.fop1(.frsq, g.ca(v[0], @intCast(ix)))),
            .tan => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), g.fop2(.fdiv, g.fop1(.fsin, x), g.fop1(.fcos, x)));
            },
            .exp => for (0..n) |ix| g.put(at, @intCast(ix), g.fop1(.fexp2, g.fop2(.fmul, g.ca(v[0], @intCast(ix)), f(std.math.log2e)))),
            .log => for (0..n) |ix| g.put(at, @intCast(ix), g.fop2(.fmul, g.fop1(.flog2, g.ca(v[0], @intCast(ix))), f(std.math.ln2))),
            .pow => for (0..n) |ix| g.put(at, @intCast(ix), g.fop1(.fexp2, g.fop2(.fmul, g.ca(v[1], @intCast(ix)), g.fop1(.flog2, g.ca(v[0], @intCast(ix)))))),
            .atan => for (0..n) |ix| {
                const y = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), if (nargs == 2) g.atan2(y, g.ca(v[1], @intCast(ix))) else g.atan2(y, f(1)));
            },
            .asin, .acos => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const c = g.sqrtOf(g.fop2(.fsub, f(1), g.fop2(.fmul, x, x)));
                g.put(at, @intCast(ix), if (which == .asin) g.atan2(x, c) else g.atan2(c, x));
            },
            .sinh, .cosh, .tanh => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const ep = g.fop1(.fexp2, g.fop2(.fmul, x, f(std.math.log2e)));
                const em = g.fop1(.fexp2, g.fop2(.fmul, x, f(-std.math.log2e)));
                const res = switch (which) {
                    .sinh => g.fop2(.fmul, g.fop2(.fsub, ep, em), f(0.5)),
                    .cosh => g.fop2(.fmul, g.fop2(.fadd, ep, em), f(0.5)),
                    else => blk: {
                        const e2 = g.fop1(.fexp2, g.fop2(.fmul, x, f(2 * std.math.log2e)));
                        break :blk g.fop2(.fsub, f(1), g.fop2(.fdiv, f(2), g.fop2(.fadd, e2, f(1))));
                    },
                };
                g.put(at, @intCast(ix), res);
            },
            .asinh, .acosh, .atanh => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const ln2 = f(std.math.ln2);
                const res = switch (which) {
                    .asinh => blk: {
                        const ax = g.fop1(.fabs, x);
                        const l = g.fop2(.fmul, g.fop1(.flog2, g.fop2(.fadd, ax, g.sqrtOf(g.fop2(.fadd, g.fop2(.fmul, x, x), f(1))))), ln2);
                        break :blk g.sel(.f32, r(g.k.cmp(.f32, .lt, x, f(0))), g.fop1(.fneg, l), l);
                    },
                    .acosh => g.fop2(.fmul, g.fop1(.flog2, g.fop2(.fadd, x, g.sqrtOf(g.fop2(.fsub, g.fop2(.fmul, x, x), f(1))))), ln2),
                    else => g.fop2(.fmul, g.fop1(.flog2, g.fop2(.fdiv, g.fop2(.fadd, f(1), x), g.fop2(.fsub, f(1), x))), f(0.5 * std.math.ln2)),
                };
                g.put(at, @intCast(ix), res);
            },
            .abs => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), if (t.base == .float) g.fop1(.fabs, x) else r(g.k.op1(.iabs, .i32, x)));
            },
            .sign => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                if (t.base == .float) {
                    g.put(at, @intCast(ix), g.sel(.f32, r(g.k.cmp(.f32, .gt, x, f(0))), f(1), g.sel(.f32, r(g.k.cmp(.f32, .lt, x, f(0))), f(-1), f(0))));
                } else {
                    g.put(at, @intCast(ix), g.sel(.i32, r(g.k.cmp(.i32, .gt, x, u(0))), u(1), g.sel(.i32, r(g.k.cmp(.i32, .lt, x, u(0))), u(0xffff_ffff), u(0))));
                }
            },
            .fract => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), g.fop2(.fsub, x, g.fop1(.ffloor, x)));
            },
            .mod => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const y = g.ca(v[1], @intCast(ix));
                g.put(at, @intCast(ix), g.fop2(.fsub, x, g.fop2(.fmul, y, g.fop1(.ffloor, g.fop2(.fdiv, x, y)))));
            },
            .modf => {
                const whole = g.zeros(t);
                for (0..n) |ix| {
                    const x = g.ca(v[0], @intCast(ix));
                    const w = g.fop1(.ftrunc, x);
                    g.put(whole.at, @intCast(ix), w);
                    g.put(at, @intCast(ix), g.fop2(.fsub, x, w));
                }
                g.store(v[1], whole);
            },
            .min, .max => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const y = g.ca(v[1], @intCast(ix));
                const ty = kty(t.base);
                const op: kir.Op = if (ty == .f32) (if (which == .min) .fmin else .fmax) else (if (which == .min) .imin else .imax);
                g.put(at, @intCast(ix), r(g.k.op2(op, ty, x, y)));
            },
            .clamp => for (0..n) |ix| {
                const ty = kty(t.base);
                const lo = r(g.k.op2(if (ty == .f32) .fmax else .imax, ty, g.ca(v[0], @intCast(ix)), g.ca(v[1], @intCast(ix))));
                g.put(at, @intCast(ix), r(g.k.op2(if (ty == .f32) .fmin else .imin, ty, lo, g.ca(v[2], @intCast(ix)))));
            },
            .mix => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                const y = g.ca(v[1], @intCast(ix));
                const m = g.ca(v[2], @intCast(ix));
                if (v[2].ty.base == .bool) {
                    g.put(at, @intCast(ix), g.sel(.f32, m, y, x));
                } else {
                    g.put(at, @intCast(ix), g.fop2(.fadd, g.fop2(.fmul, x, g.fop2(.fsub, f(1), m)), g.fop2(.fmul, y, m)));
                }
            },
            .step => for (0..n) |ix| {
                g.put(at, @intCast(ix), g.sel(.f32, r(g.k.cmp(.f32, .lt, g.ca(v[1], @intCast(ix)), g.ca(v[0], @intCast(ix)))), f(0), f(1)));
            },
            .smoothstep => for (0..n) |ix| {
                const e0 = g.ca(v[0], @intCast(ix));
                const e1 = g.ca(v[1], @intCast(ix));
                const x = g.ca(v[2], @intCast(ix));
                const q = g.fop2(.fdiv, g.fop2(.fsub, x, e0), g.fop2(.fsub, e1, e0));
                const c = r(g.k.op2(.fmin, .f32, r(g.k.op2(.fmax, .f32, q, f(0))), f(1)));
                g.put(at, @intCast(ix), g.fop2(.fmul, g.fop2(.fmul, c, c), g.fop2(.fsub, f(3), g.fop2(.fmul, f(2), c))));
            },
            .isnan => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), r(g.k.cmp(.f32, .ne, x, x)));
            },
            .isinf => for (0..n) |ix| {
                g.put(at, @intCast(ix), r(g.k.cmp(.f32, .eq, g.fop1(.fabs, g.ca(v[0], @intCast(ix))), u(0x7f80_0000))));
            },
            .floatBitsToInt, .floatBitsToUint, .intBitsToFloat, .uintBitsToFloat => for (0..n) |ix| {
                const x = g.ca(v[0], @intCast(ix));
                g.put(at, @intCast(ix), if (x == .imm) x else r(g.k.mov(kty(t.base), x)));
            },
            .packUnorm2x16, .packSnorm2x16, .packHalf2x16 => {
                var halves: [2]Arg = undefined;
                for (0..2) |ix| {
                    const x = g.cp(v[0].at, @intCast(ix));
                    halves[ix] = switch (which) {
                        .packUnorm2x16 => r(g.k.cvt(.f32, .u32, .rne, g.fop2(.fmul, r(g.k.op2(.fmin, .f32, r(g.k.op2(.fmax, .f32, x, f(0))), f(1))), f(65535)))),
                        .packSnorm2x16 => g.iop2(.@"and", .u32, r(g.k.cvt(.f32, .i32, .rne, g.fop2(.fmul, r(g.k.op2(.fmin, .f32, r(g.k.op2(.fmax, .f32, x, f(-1))), f(1))), f(32767)))), u(0xffff)),
                        else => g.toHalf(x),
                    };
                }
                g.put(at, 0, g.iop2(.@"or", .u32, halves[0], g.iop2(.shl, .u32, halves[1], u(16))));
            },
            .unpackUnorm2x16, .unpackSnorm2x16, .unpackHalf2x16 => {
                const p = g.cp(v[0].at, 0);
                for (0..2) |ix| {
                    const sh = u(@intCast(16 * ix));
                    g.put(at, @intCast(ix), switch (which) {
                        .unpackUnorm2x16 => g.fop2(.fdiv, r(g.k.cvt(.u32, .f32, .rne, r(g.k.op3(.bfe, .u32, p, sh, u(16))))), f(65535)),
                        .unpackSnorm2x16 => r(g.k.op2(.fmax, .f32, g.fop2(.fdiv, r(g.k.cvt(.i32, .f32, .rne, r(g.k.op3(.bfe, .i32, p, sh, u(16))))), f(32767)), f(-1))),
                        else => g.fromHalf(r(g.k.op3(.bfe, .u32, p, sh, u(16)))),
                    });
                }
            },
            .length, .distance => {
                const m = g.size(v[0].ty);
                var s: Arg = f(0);
                for (0..m) |ix| {
                    const x = if (which == .distance) g.fop2(.fsub, g.cp(v[0].at, @intCast(ix)), g.cp(v[1].at, @intCast(ix))) else g.cp(v[0].at, @intCast(ix));
                    const sq = g.fop2(.fmul, x, x);
                    s = if (ix == 0) sq else g.fop2(.fadd, s, sq);
                }
                g.put(at, 0, g.sqrtOf(s));
            },
            .dot => g.put(at, 0, g.dot(v[0], v[1])),
            .cross => {
                const A = v[0];
                const B = v[1];
                for (0..3) |ix| {
                    const j: u32 = @intCast((ix + 1) % 3);
                    const kx: u32 = @intCast((ix + 2) % 3);
                    g.put(at, @intCast(ix), g.fop2(.fsub, g.fop2(.fmul, g.cp(A.at, j), g.cp(B.at, kx)), g.fop2(.fmul, g.cp(A.at, kx), g.cp(B.at, j))));
                }
            },
            .normalize => {
                const inv = g.fop1(.frsq, g.dot(v[0], v[0]));
                for (0..n) |ix| g.put(at, @intCast(ix), g.fop2(.fmul, g.cp(v[0].at, @intCast(ix)), inv));
            },
            .faceforward => {
                const neg = r(g.k.cmp(.f32, .lt, g.dot(v[2], v[1]), f(0)));
                for (0..n) |ix| {
                    const x = g.cp(v[0].at, @intCast(ix));
                    g.put(at, @intCast(ix), g.sel(.f32, neg, x, g.fop1(.fneg, x)));
                }
            },
            .reflect => {
                const d2 = g.fop2(.fmul, f(2), g.dot(v[1], v[0]));
                for (0..n) |ix| g.put(at, @intCast(ix), g.fop2(.fsub, g.cp(v[0].at, @intCast(ix)), g.fop2(.fmul, d2, g.cp(v[1].at, @intCast(ix)))));
            },
            .refract => {
                const eta = g.cp(v[2].at, 0);
                const d = g.dot(v[1], v[0]);
                const kk = g.fop2(.fsub, f(1), g.fop2(.fmul, g.fop2(.fmul, eta, eta), g.fop2(.fsub, f(1), g.fop2(.fmul, d, d))));
                const neg = r(g.k.cmp(.f32, .lt, kk, f(0)));
                const m = g.fop2(.fadd, g.fop2(.fmul, eta, d), g.sqrtOf(kk));
                for (0..n) |ix| {
                    const x = g.fop2(.fsub, g.fop2(.fmul, eta, g.cp(v[0].at, @intCast(ix))), g.fop2(.fmul, m, g.cp(v[1].at, @intCast(ix))));
                    g.put(at, @intCast(ix), g.sel(.f32, neg, f(0), x));
                }
            },
            .matrixCompMult => for (0..n) |ix| g.put(at, @intCast(ix), g.fop2(.fmul, g.cp(v[0].at, @intCast(ix)), g.cp(v[1].at, @intCast(ix)))),
            .transpose => {
                const m = v[0].ty;
                for (0..m.cols) |cx| {
                    for (0..m.rows) |rx| g.put(at, @intCast(rx * m.cols + cx), g.cp(v[0].at, @intCast(cx * m.rows + rx)));
                }
            },
            .determinant => {
                var m: [16]Arg = undefined;
                const dim: u32 = v[0].ty.cols;
                for (0..dim * dim) |ix| m[ix] = g.cp(v[0].at, @intCast(ix));
                g.put(at, 0, g.det(m[0 .. dim * dim], dim));
            },
            .inverse => g.invert(v[0], at),
            .outerProduct => {
                const c = v[0];
                const rr = v[1];
                for (0..t.cols) |cx| {
                    for (0..t.rows) |rx| g.put(at, @intCast(cx * t.rows + rx), g.fop2(.fmul, g.cp(c.at, @intCast(rx)), g.cp(rr.at, @intCast(cx))));
                }
            },
            .lessThan, .lessThanEqual, .greaterThan, .greaterThanEqual, .equal, .notEqual => {
                const c: kir.Cmp = switch (which) {
                    .lessThan => .lt,
                    .lessThanEqual => .le,
                    .greaterThan => .gt,
                    .greaterThanEqual => .ge,
                    .equal => .eq,
                    else => .ne,
                };
                for (0..n) |ix| g.put(at, @intCast(ix), g.cmpOf(v[0].ty.base, c, g.cp(v[0].at, @intCast(ix)), g.cp(v[1].at, @intCast(ix))));
            },
            .any, .all => {
                var acc = u(@intFromBool(which == .all));
                for (0..g.size(v[0].ty)) |ix| {
                    const x = g.cp(v[0].at, @intCast(ix));
                    acc = if (which == .any) g.por(acc, x) else g.pand(acc, x);
                }
                g.put(at, 0, acc);
            },
            .not => for (0..n) |ix| g.put(at, @intCast(ix), g.pnot(g.cp(v[0].at, @intCast(ix)))),
            .dFdx, .dFdy, .fwidth => {
                g.derivatives = true;
                for (0..n) |ix| {
                    const x = g.cp(v[0].at, @intCast(ix));
                    const d = switch (which) {
                        .dFdx => g.deriv(x, false),
                        .dFdy => g.deriv(x, true),
                        else => g.fadd(g.fabs(g.deriv(x, false)), g.fabs(g.deriv(x, true))),
                    };
                    g.put(at, @intCast(ix), d);
                }
            },
        }
        return out;
    }

    /// x's difference with the quad's neighbour pixel's x, across (or
    /// up): the right one's less the left one's, for both. 0 where the
    /// raster runs pixels alone, and for an immediate.
    fn deriv(g: *Gen, x: Arg, up: bool) Arg {
        if (!g.quads or x == .imm) return f(0);
        if (g.nderivs == MAX_DERIVS) {
            g.fail(0, "more than {d} derivatives", .{MAX_DERIVS});
            return f(0);
        }
        const k = g.k;
        const xv = asF32(g, x);
        const o = k.shfl(.f32, .xor, r(xv), u(if (up) raster.QUAD_Y else raster.QUAD_X));
        g.st.derivs[g.nderivs] = @intCast(k.n - 1);
        g.nderivs += 1;
        const odd = if (up) g.odd_y else g.odd_x;
        return r(k.sel(.f32, r(odd), r(k.op2(.fsub, .f32, r(xv), r(o))), r(k.op2(.fsub, .f32, r(o), r(xv)))));
    }

    fn fabs(g: *Gen, x: Arg) Arg {
        if (x == .imm) return f(@abs(@as(f32, @bitCast(x.imm))));
        return r(g.k.op1(.fabs, .f32, x));
    }

    fn fadd(g: *Gen, a: Arg, b: Arg) Arg {
        return r(g.k.op2(.fadd, .f32, a, b));
    }

    // ── Textures ───────────────────────────────────────────────────────────

    const TexFn = enum {
        texture,
        textureProj,
        textureLod,
        textureOffset,
        texelFetch,
        texelFetchOffset,
        textureProjOffset,
        textureLodOffset,
        textureProjLod,
        textureProjLodOffset,
        textureGrad,
        textureGradOffset,
        textureProjGrad,
        textureProjGradOffset,
        textureSize,
        texture2D,
        texture2DProj,
        texture2DLod,
        texture2DProjLod,
        textureCube,
        textureCubeLod,
        texture2DLodEXT,
        texture2DProjLodEXT,
        textureCubeLodEXT,
        texture2DGradEXT,
        texture2DProjGradEXT,
        textureCubeGradEXT,
    };

    /// A texture function's level of detail: given (the *Lod ones), its
    /// gradients (the *Grad ones), or implicit: in a fragment shader the
    /// derivatives of (s, t) through the quad, plus the bias argument if
    /// there is one; elsewhere the base level.
    fn lodOf(g: *Gen, which: TexFn, args: []Val, s: Arg, t: Arg, depth: ?Arg, cube: ?texture.CubeProjection, kind: texture.Kind) texture.Lod {
        if (kind != .float) return .base;
        switch (which) {
            .textureLod, .textureLodOffset, .textureProjLod, .textureProjLodOffset, .texture2DLod, .texture2DProjLod, .texture2DLodEXT, .texture2DProjLodEXT, .textureCubeLod, .textureCubeLodEXT => {
                return .{ .level = if (args.len > 2) g.cp(g.rv(args[2]).at, 0) else f(0) };
            },
            .textureGrad, .textureGradOffset, .textureProjGrad, .textureProjGradOffset, .texture2DGradEXT, .texture2DProjGradEXT, .textureCubeGradEXT => {
                if (args.len < 4) return .base;
                const dx = g.rv(args[2]);
                const dy = g.rv(args[3]);
                if (cube) |p| {
                    const x = texture.cubeGradient(g.k, p, g.cp(dx.at, 0), g.cp(dx.at, 1), g.cp(dx.at, 2));
                    const y = texture.cubeGradient(g.k, p, g.cp(dy.at, 0), g.cp(dy.at, 1), g.cp(dy.at, 2));
                    return .{ .grad = .{ .dsdx = x[0], .dtdx = x[1], .dsdy = y[0], .dtdy = y[1], .bias = f(0) } };
                }
                return .{ .grad = .{ .dsdx = g.cp(dx.at, 0), .dtdx = g.cp(dx.at, 1), .dsdy = g.cp(dy.at, 0), .dtdy = g.cp(dy.at, 1), .bias = f(0), .drdx = if (depth != null) g.cp(dx.at, 2) else f(0), .drdy = if (depth != null) g.cp(dy.at, 2) else f(0) } };
            },
            else => {},
        }
        if (g.stage != .fragment) return .base;
        const bias_at: usize = switch (which) {
            .textureOffset, .textureProjOffset => 3,
            else => 2,
        };
        const bias = if (bias_at < args.len) g.cp(g.rv(args[bias_at]).at, 0) else f(0);
        // (the program runs whole quads: derivatives are its neighbours')
        g.derivatives = true;
        if (cube) |projection| {
            const coords = g.rv(args[1]);
            const x = g.cp(coords.at, 0);
            const y = g.cp(coords.at, 1);
            const z = g.cp(coords.at, 2);
            const dx = texture.cubeGradient(g.k, projection, g.deriv(x, false), g.deriv(y, false), g.deriv(z, false));
            const dy = texture.cubeGradient(g.k, projection, g.deriv(x, true), g.deriv(y, true), g.deriv(z, true));
            return .{ .grad = .{ .dsdx = dx[0], .dtdx = dx[1], .dsdy = dy[0], .dtdy = dy[1], .bias = bias } };
        }
        return .{ .grad = .{ .dsdx = g.deriv(s, false), .dtdx = g.deriv(t, false), .dsdy = g.deriv(s, true), .dtdy = g.deriv(t, true), .bias = bias, .drdx = if (depth) |z| g.deriv(z, false) else f(0), .drdy = if (depth) |z| g.deriv(z, true) else f(0) } };
    }

    /// A constant ivec2 argument (an offset): its two ints.
    fn offsetOf(g: *Gen, v: Val) [2]i32 {
        const a = g.rv(v);
        var out: [2]i32 = .{ 0, 0 };
        for (0..2) |ix| {
            const x = g.cp(a.at, @intCast(ix));
            if (x == .imm) out[ix] = @bitCast(x.imm);
        }
        return out;
    }

    fn textureCall(g: *Gen, nd: *Node, t: Type, which: TexFn, args: []Val) Val {
        const n = g.size(t);
        const at = g.alloc(n);
        for (0..n) |ix| g.put(at, @intCast(ix), u(0));
        const out = Val{ .ty = t, .at = at };
        const sv = g.rv(args[0]);
        const sa = g.cp(sv.at, 0);
        if (sa != .imm) {
            g.fail(nd.line, "a sampler chosen at run time cannot be generated yet", .{});
            return out;
        }
        const slot = sa.imm;
        const base = args[0].ty.base;
        const kind: texture.Kind = switch (base) {
            .isampler2D, .isampler2DArray, .isampler3D, .isamplerCube => .int,
            .usampler2D, .usampler2DArray, .usampler3D, .usamplerCube => .uint,
            else => .float,
        };
        const shadow = base == .sampler2DShadow or base == .sampler2DArrayShadow or base == .samplerCubeShadow;
        const array = base == .sampler2DArray or base == .isampler2DArray or base == .usampler2DArray or base == .sampler2DArrayShadow;
        const volume = base == .sampler3D or base == .isampler3D or base == .usampler3D;
        const cube = base == .samplerCube or base == .isamplerCube or base == .usamplerCube or base == .samplerCubeShadow;
        const layered = array or volume;
        const two_d = base == .sampler2D or base == .isampler2D or base == .usampler2D or base == .samplerExternalOES;
        if (slot == NO_SLOT or !(two_d or layered or cube or shadow)) {
            if (n == 4) g.put(at, 3, if (kind == .float) f(1) else u(1));
            return out;
        }
        var ts = texture.Slot{ .b = g.texb + @as(u8, @intCast(slot)), .uni = g.uni, .word = g.lay.desc_base + slot * texture.DESC_WORDS, .volume = volume, .cube = cube };
        const k = g.k;
        var res: [4]Arg = undefined;
        switch (which) {
            .textureSize => {
                const lod = if (args.len > 1) g.cp(g.rv(args[1]).at, 0) else u(0);
                const sz = texture.size(k, ts, lod);
                g.put(at, 0, sz[0]);
                if (n > 1) g.put(at, 1, sz[1]);
                if (layered and n > 2) g.put(at, 2, texture.layerSize(k, ts, lod));
                return out;
            },
            .texelFetch, .texelFetchOffset => {
                const p = g.rv(args[1]);
                const off = if (which == .texelFetchOffset) g.offsetOf(args[3]) else [2]i32{ 0, 0 };
                const lod = if (args.len > 2) g.cp(g.rv(args[2]).at, 0) else u(0);
                if (volume and which == .texelFetchOffset) ts.offset_z = g.offsetZ(args[3]);
                res = texture.fetchArray(k, ts, g.cp(p.at, 0), g.cp(p.at, 1), if (layered) g.cp(p.at, 2) else null, kind, off, lod);
            },
            else => {
                const p = g.rv(args[1]);
                var s = g.cp(p.at, 0);
                var tt = g.cp(p.at, 1);
                var z: ?Arg = if (layered) g.cp(p.at, 2) else null;
                if (shadow) ts.shadow = g.cp(p.at, if (array or cube) 3 else 2);
                const projection = if (cube) texture.cubeProject(k, s, tt, g.cp(p.at, 2)) else null;
                if (projection) |uv| {
                    s = uv.s;
                    tt = uv.t;
                    z = uv.face;
                }
                const proj = switch (which) {
                    .textureProj, .textureProjOffset, .textureProjLod, .textureProjLodOffset, .textureProjGrad, .textureProjGradOffset, .texture2DProj, .texture2DProjLod, .texture2DProjLodEXT, .texture2DProjGradEXT => true,
                    else => false,
                };
                if (proj) {
                    const q = g.cp(p.at, g.size(p.ty) - 1);
                    s = g.fop2(.fdiv, s, q);
                    tt = g.fop2(.fdiv, tt, q);
                    if (volume) z = g.fop2(.fdiv, z.?, q);
                    if (ts.shadow) |reference| ts.shadow = g.fop2(.fdiv, reference, q);
                }
                // the offset: after the coordinates, a lod, or two gradients
                const off_at: ?usize = switch (which) {
                    .textureOffset, .textureProjOffset => 2,
                    .textureLodOffset, .textureProjLodOffset => 3,
                    .textureGradOffset, .textureProjGradOffset => 4,
                    else => null,
                };
                const off = if (off_at) |ix| (if (ix < args.len) g.offsetOf(args[ix]) else [2]i32{ 0, 0 }) else [2]i32{ 0, 0 };
                if (volume) {
                    if (off_at) |ix| ts.offset_z = g.offsetZ(args[ix]);
                }
                res = texture.sampleArray(k, ts, s, tt, z, kind, off, g.lodOf(which, args, s, tt, if (volume) z else null, projection, kind));
            },
        }
        for (0..@min(n, 4)) |ix| g.put(at, @intCast(ix), res[ix]);
        return out;
    }

    fn offsetZ(g: *Gen, v: Val) i32 {
        const arg = g.cp(g.rv(v).at, 2);
        return if (arg == .imm) @bitCast(arg.imm) else 0;
    }

    fn dot(g: *Gen, a: Val, b: Val) Arg {
        var s: Arg = f(0);
        for (0..g.size(a.ty)) |ix| {
            const p = g.fop2(.fmul, g.cp(a.at, @intCast(ix)), g.cp(b.at, @intCast(ix)));
            s = if (ix == 0) p else g.fop2(.fadd, s, p);
        }
        return s;
    }

    /// atan(y / x) in the right quadrant: a polynomial on [0, 1] (error
    /// about 1e-5), folded.
    fn atan2(g: *Gen, y: Arg, x: Arg) Arg {
        const k = g.k;
        const ax = g.fop1(.fabs, x);
        const ay = g.fop1(.fabs, y);
        const mx = r(k.op2(.fmax, .f32, ax, ay));
        const mn = r(k.op2(.fmin, .f32, ax, ay));
        const z = g.sel(.f32, r(k.cmp(.f32, .eq, mx, f(0))), f(0), g.fop2(.fdiv, mn, mx));
        const z2 = g.fop2(.fmul, z, z);
        var p = g.fop2(.fsub, g.fop2(.fmul, f(0.0208351), z2), f(0.0851330));
        p = g.fop2(.fadd, g.fop2(.fmul, p, z2), f(0.1801410));
        p = g.fop2(.fsub, g.fop2(.fmul, p, z2), f(0.3302995));
        p = g.fop2(.fadd, g.fop2(.fmul, p, z2), f(0.9998660));
        p = g.fop2(.fmul, p, z);
        p = g.sel(.f32, r(k.cmp(.f32, .gt, ay, ax)), g.fop2(.fsub, f(std.math.pi / 2.0), p), p);
        p = g.sel(.f32, r(k.cmp(.f32, .lt, x, f(0))), g.fop2(.fsub, f(std.math.pi), p), p);
        return g.sel(.f32, r(k.cmp(.f32, .lt, y, f(0))), g.fop1(.fneg, p), p);
    }

    /// The determinant of an n x n matrix (column-major), by cofactors.
    fn det(g: *Gen, m: []const Arg, n: u32) Arg {
        if (n == 1) return m[0];
        if (n == 2) return g.fop2(.fsub, g.fop2(.fmul, m[0], m[3]), g.fop2(.fmul, m[2], m[1]));
        var s: Arg = f(0);
        for (0..n) |cx| {
            var sub: [9]Arg = undefined;
            g.minor(m, n, @intCast(cx), 0, &sub);
            const term = g.fop2(.fmul, m[cx * n], g.det(sub[0 .. (n - 1) * (n - 1)], n - 1));
            s = if (cx == 0) term else if (cx % 2 == 1) g.fop2(.fsub, s, term) else g.fop2(.fadd, s, term);
        }
        return s;
    }

    /// m without column `col` and row `row`.
    fn minor(g: *Gen, m: []const Arg, n: u32, col: u32, row: u32, out: []Arg) void {
        _ = g;
        var w: usize = 0;
        for (0..n) |cx| {
            if (cx == col) continue;
            for (0..n) |rx| {
                if (rx == row) continue;
                out[w] = m[cx * n + rx];
                w += 1;
            }
        }
    }

    fn invert(g: *Gen, v: Val, at: u32) void {
        const n: u32 = v.ty.cols;
        var m: [16]Arg = undefined;
        for (0..n * n) |ix| m[ix] = g.cp(v.at, @intCast(ix));
        const inv_det = g.fop2(.fdiv, f(1), g.det(m[0 .. n * n], n));
        for (0..n) |cx| {
            for (0..n) |rx| {
                // inverse[cx][rx] = cofactor(rx, cx) / det (the adjugate)
                var sub: [9]Arg = undefined;
                g.minor(m[0 .. n * n], n, @intCast(rx), @intCast(cx), &sub);
                var c = if (n == 1) f(1) else g.det(sub[0 .. (n - 1) * (n - 1)], n - 1);
                if ((cx + rx) % 2 == 1) c = g.fop1(.fneg, c);
                g.put(at, @intCast(cx * n + rx), g.fop2(.fmul, c, inv_det));
            }
        }
    }

    /// An f32 as the bits of the nearest f16 (round to nearest even).
    fn toHalf(g: *Gen, x: Arg) Arg {
        const k = g.k;
        const bits = if (x == .imm) x else r(k.mov(.u32, x));
        const sign = g.iop2(.@"and", .u32, g.iop2(.shr, .u32, bits, u(16)), u(0x8000));
        const e = r(k.op3(.bfe, .u32, bits, u(23), u(8)));
        const m = g.iop2(.@"and", .u32, bits, u(0x7f_ffff));
        const e16 = r(k.op2(.isub, .i32, e, u(112))); // e - 127 + 15
        // normal: the top 10 bits of m, rounded
        const nh = g.iop2(.@"or", .u32, g.iop2(.shl, .u32, e16, u(10)), g.iop2(.shr, .u32, m, u(13)));
        const nrem = g.iop2(.@"and", .u32, m, u(0x1fff));
        const nup = g.por(r(k.cmp(.u32, .gt, nrem, u(0x1000))), g.pand(r(k.cmp(.u32, .eq, nrem, u(0x1000))), r(k.cmp(.u32, .ne, g.iop2(.@"and", .u32, nh, u(1)), u(0)))));
        const normal = g.iop2(.iadd, .u32, nh, g.sel(.u32, nup, u(1), u(0)));
        // subnormal: (m | 1 << 23) >> (14 - e16), rounded
        const sh = r(k.op2(.imin, .u32, r(k.op2(.isub, .u32, u(14), e16)), u(31)));
        const full = g.iop2(.@"or", .u32, m, u(0x80_0000));
        const sh_v = g.iop2(.shr, .u32, full, sh);
        const srem = g.iop2(.@"and", .u32, full, g.iop2(.isub, .u32, g.iop2(.shl, .u32, u(1), sh), u(1)));
        const half = g.iop2(.shl, .u32, u(1), g.iop2(.isub, .u32, sh, u(1)));
        const sup = g.por(r(k.cmp(.u32, .gt, srem, half)), g.pand(r(k.cmp(.u32, .eq, srem, half)), r(k.cmp(.u32, .ne, g.iop2(.@"and", .u32, sh_v, u(1)), u(0)))));
        const sub = g.iop2(.iadd, .u32, sh_v, g.sel(.u32, sup, u(1), u(0)));
        var h = g.sel(.u32, r(k.cmp(.i32, .ge, e16, u(31))), u(0x7c00), normal);
        h = g.sel(.u32, r(k.cmp(.i32, .le, e16, u(0))), g.sel(.u32, r(k.cmp(.i32, .lt, e16, u(@bitCast(@as(i32, -10))))), u(0), sub), h);
        // infinities and NaNs (a NaN stays one)
        const special = g.iop2(.@"or", .u32, u(0x7c00), g.sel(.u32, r(k.cmp(.u32, .ne, m, u(0))), u(0x200), u(0)));
        h = g.sel(.u32, r(k.cmp(.u32, .eq, e, u(255))), special, h);
        return g.iop2(.@"or", .u32, sign, h);
    }

    /// The f16 bits (low 16) as an f32.
    fn fromHalf(g: *Gen, hbits: Arg) Arg {
        const k = g.k;
        const sign = g.iop2(.shl, .u32, g.iop2(.@"and", .u32, hbits, u(0x8000)), u(16));
        const e = r(k.op3(.bfe, .u32, hbits, u(10), u(5)));
        const m = g.iop2(.@"and", .u32, hbits, u(0x3ff));
        const normal = g.iop2(.@"or", .u32, g.iop2(.shl, .u32, g.iop2(.iadd, .u32, e, u(112)), u(23)), g.iop2(.shl, .u32, m, u(13)));
        const inf = g.iop2(.@"or", .u32, u(0x7f80_0000), g.iop2(.shl, .u32, m, u(13)));
        // subnormal: m * 2^-24, exact
        const subf = g.fop2(.fmul, r(k.cvt(.u32, .f32, .rne, m)), f(1.0 / 16777216.0));
        const sub = r(k.mov(.u32, subf));
        var bits = g.sel(.u32, r(k.cmp(.u32, .eq, e, u(31))), inf, normal);
        bits = g.sel(.u32, r(k.cmp(.u32, .eq, e, u(0))), sub, bits);
        return r(k.mov(.f32, g.iop2(.@"or", .u32, bits, sign)));
    }

    // ── Statements ─────────────────────────────────────────────────────────

    fn openLoop(g: *Gen, kind: LoopKind) void {
        if (g.nloops == MAX_LOOPS) return g.fail(0, "loops nest too deep", .{});
        g.loops[g.nloops] = .{ .kind = kind };
        g.nloops += 1;
    }

    /// Ends the innermost user loop or switch: endloop, then a return
    /// inside it leaves the loop around too (and a switch's continue
    /// continues the loop around).
    fn closeLoop(g: *Gen) void {
        g.k.endloop();
        if (g.nloops == 0) return;
        g.nloops -= 1;
        const lp = g.loops[g.nloops];
        if (lp.ret_inside) {
            const fr = &g.frames[g.nframes - 1];
            if (fr.done != .none) g.k.brk(r(fr.done));
        }
        if (lp.kind == .swtch and lp.used_cont and g.nloops > 0) {
            const outer = &g.loops[g.nloops - 1];
            if (outer.kind == .user) {
                g.k.cont(r(lp.cont));
            } else if (outer.kind == .swtch) {
                g.k.set(outer.cont, .por, r(outer.cont), r(lp.cont), no);
                outer.used_cont = true;
                g.k.brk(r(lp.cont));
            }
        }
    }

    fn stmts(g: *Gen, first: u32) void {
        var s = first;
        while (s != 0) : (s = g.node(s).next) g.stmt(s);
    }

    fn scoped(g: *Gen, s: u32) void {
        if (s == 0) return;
        g.push();
        g.stmt(s);
        g.pop();
    }

    fn stmt(g: *Gen, s: u32) void {
        if (g.failed) return;
        const nd = g.node(s);
        const k = g.k;
        switch (nd.kind) {
            .block => {
                g.push();
                g.stmts(nd.a);
                g.pop();
            },
            .decl_stmt => if (g.node(nd.a).kind == .decl) g.declLocal(nd.a),
            .expr_stmt => if (nd.a != 0) {
                _ = g.expr(nd.a);
            },
            .@"if" => {
                const c = g.cond(nd.a);
                g.prepare(&.{ nd.b, nd.c });
                k.ifp(c);
                g.scoped(nd.b);
                if (nd.c != 0) {
                    k.els();
                    g.scoped(nd.c);
                }
                k.endif();
            },
            .@"while" => {
                g.prepare(&.{ nd.a, nd.b });
                g.openLoop(.user);
                k.loop();
                g.push();
                k.brk(g.pnot(g.cond(nd.a)));
                g.scoped(nd.b);
                g.pop();
                g.closeLoop();
            },
            .@"for" => {
                g.push();
                if (nd.a != 0) g.stmt(nd.a);
                g.prepare(&.{ nd.b, nd.c, nd.d });
                // (a continue must still step: then the step runs at the
                // top of each pass but the first; else at the bottom)
                const first: V = if (nd.c != 0 and g.hasContinue(nd.d)) k.reg(.pred) else .none;
                if (first != .none) k.set(first, .mov, u(1), no, no);
                g.openLoop(.user);
                k.loop();
                if (first != .none) {
                    k.ifp(g.pnot(r(first)));
                    _ = g.expr(nd.c);
                    k.endif();
                    k.set(first, .mov, u(0), no, no);
                }
                if (nd.b != 0) k.brk(g.pnot(g.cond(nd.b)));
                g.scoped(nd.d);
                if (first == .none and nd.c != 0) _ = g.expr(nd.c);
                g.closeLoop();
                g.pop();
            },
            .do => {
                g.prepare(&.{ nd.a, nd.b });
                if (!g.hasContinue(nd.a)) {
                    g.openLoop(.user);
                    k.loop();
                    g.scoped(nd.a);
                    k.brk(g.pnot(g.cond(nd.b)));
                    g.closeLoop();
                    return;
                }
                const first = k.reg(.pred);
                k.set(first, .mov, u(1), no, no);
                g.openLoop(.user);
                k.loop();
                k.ifp(g.pnot(r(first)));
                k.brk(g.pnot(g.cond(nd.b)));
                k.endif();
                k.set(first, .mov, u(0), no, no);
                g.scoped(nd.a);
                g.closeLoop();
            },
            .@"switch" => g.switchStmt(nd),
            .@"break" => k.brk(u(1)),
            .@"continue" => {
                if (g.nloops > 0 and g.loops[g.nloops - 1].kind == .swtch) {
                    const lp = &g.loops[g.nloops - 1];
                    lp.used_cont = true;
                    k.set(lp.cont, .mov, u(1), no, no);
                    k.brk(u(1));
                } else k.cont(u(1));
            },
            .@"return" => g.doReturn(nd.a),
            .discard => {
                if (g.discard != .none) k.set(g.discard, .mov, u(1), no, no);
                if (g.nframes > 0 and g.frames[g.nframes - 1].main) g.doReturn(0);
            },
            .empty, .case, .default => {},
            else => g.fail(nd.line, "this statement cannot be generated", .{}),
        }
    }

    fn doReturn(g: *Gen, value: u32) void {
        if (g.nframes == 0) return;
        const fr = &g.frames[g.nframes - 1];
        if (value != 0) {
            const v = g.expr(value);
            if (fr.ret) |dst| g.store(dst, v);
        }
        if (!fr.wrapper) return;
        if (g.nloops > fr.loop_base + 1 and fr.done != .none) {
            g.k.set(fr.done, .mov, u(1), no, no);
            for (g.loops[fr.loop_base + 1 .. g.nloops]) |*lp| lp.ret_inside = true;
        }
        g.k.brk(u(1));
    }

    fn switchStmt(g: *Gen, nd: *Node) void {
        const k = g.k;
        const sv = g.rv(g.expr(nd.a));
        const x = g.cp(sv.at, 0);
        const body = g.node(nd.b).a;
        // a case matches, or none (default's)
        var any = u(0);
        var c = body;
        while (c != 0) : (c = g.node(c).next) {
            const cn = g.node(c);
            if (cn.kind != .case) continue;
            const lv = g.rv(g.expr(cn.a));
            any = g.por(any, r(k.cmp(.u32, .eq, x, g.cp(lv.at, 0))));
        }
        g.prepare(&.{nd.b});
        const fall = k.reg(.pred);
        k.set(fall, .mov, u(0), no, no);
        // (a continue inside: its flag, made before the loop)
        const cont: V = if (g.hasContinue(nd.b)) k.reg(.pred) else .none;
        if (cont != .none) k.set(cont, .mov, u(0), no, no);
        g.openLoop(.swtch);
        g.loops[g.nloops - 1].cont = cont;
        k.loop();
        g.push();
        var open = false;
        c = body;
        while (c != 0) : (c = g.node(c).next) {
            const cn = g.node(c);
            if (cn.kind == .case or cn.kind == .default) {
                if (open) {
                    k.endif();
                    open = false;
                }
                const hit = if (cn.kind == .case) blk: {
                    const lv = g.rv(g.expr(cn.a));
                    break :blk r(k.cmp(.u32, .eq, x, g.cp(lv.at, 0)));
                } else g.pnot(any);
                k.set(fall, .por, r(fall), hit, no);
                continue;
            }
            if (!open) {
                k.ifp(r(fall));
                open = true;
            }
            g.stmt(c);
        }
        if (open) k.endif();
        g.pop();
        k.brk(u(1));
        g.closeLoop();
    }

    fn declLocal(g: *Gen, d: u32) void {
        const dn = g.node(d);
        const is_const = dn.flags & Q.@"const" != 0;
        var v = dn.b;
        while (v != 0) : (v = g.node(v).next) {
            const vn = g.node(v);
            const t = Type.of(vn.ty);
            const name = g.text(vn.tok);
            const init: ?Val = if (vn.b != 0) g.rv(g.expr(vn.b)) else null;
            g.bind(name, t, init, is_const and vn.b != 0);
        }
    }
};

fn kty(b: Base) Ty {
    return switch (b) {
        .float => .f32,
        .int => .i32,
        .bool => .pred,
        else => .u32,
    };
}

fn isSampler(b: Base) bool {
    return @intFromEnum(b) >= @intFromEnum(Base.sampler2D) and @intFromEnum(b) <= @intFromEnum(Base.samplerExternalOES);
}

fn sameReg(a: Arg, b: Arg) bool {
    return a == .reg and b == .reg and a.reg == b.reg and a.reg != .none;
}

// ── The shader's globals, then main ────────────────────────────────────────

/// An output variable (its index in vars): its varying's first scalar
/// (vertex) or location (fragment).
const Out = struct { var_ix: u32, word: u32, loc: u32 };

/// The globals in order (inputs, outputs, uniforms, plain ones), the
/// functions noted; main's node, or 0.
fn globals(g: *Gen, vio: ?*raster.VertexIO, fio: ?*raster.FragmentIO, outs: *[64]Out, nouts: *usize) u32 {
    const s = g.s;
    const k = g.k;
    var main: u32 = 0;
    var d = s.parser.nodes[s.root].a;
    while (d != 0) : (d = g.node(d).next) {
        const dn = g.node(d);
        if (dn.kind == .func) {
            if (dn.c == 0) continue;
            if (std.mem.eql(u8, g.text(dn.tok), "main")) main = d;
            if (g.nfuncs < MAX_FUNCS) {
                g.st.funcs[g.nfuncs] = d;
                g.nfuncs += 1;
            }
            continue;
        }
        if (dn.kind != .decl) continue;
        var v = dn.b;
        while (v != 0) : (v = g.node(v).next) {
            const vn = g.node(v);
            const t = Type.of(vn.ty);
            const name = g.text(vn.tok);
            const q = vn.flags;
            if (q & Q.uniform != 0) {
                const word = g.lay.uniform(g.lay.ctx, name) orelse {
                    const z = g.zeros(t);
                    // (an unused sampler: no slot)
                    for (0..g.size(t)) |ix| {
                        if (isSampler(g.baseAt(t, @intCast(ix)))) g.put(z.at, @intCast(ix), u(NO_SLOT));
                    }
                    g.declare(.{ .name = name, .ty = t, .at = z.at, .ro = true });
                    continue;
                };
                if (g.hasSampler(t)) {
                    // samplers are their texture slots; the rest is loaded
                    const n = g.size(t);
                    const at = g.alloc(n);
                    for (0..n) |ix| {
                        const i_: u32 = @intCast(ix);
                        const b = g.baseAt(t, i_);
                        g.put(at, i_, if (isSampler(b)) u(g.lay.sampler(g.lay.ctx, word + i_) orelse NO_SLOT) else g.loadUni(b, word + i_, no));
                    }
                    g.declare(.{ .name = name, .ty = t, .at = at, .ro = true });
                    continue;
                }
                const mem = Val{ .ty = t, .mem = true, .word = word };
                if (g.size(t) <= PRELOAD_WORDS and !g.hasArray(t)) {
                    const loaded = g.rv(mem);
                    g.declare(.{ .name = name, .ty = t, .at = loaded.at, .ro = true });
                } else g.declare(.{ .name = name, .ty = t, .mem = true, .word = word, .ro = true });
                continue;
            }
            const is_in = q & Q.in != 0 or (q & Q.varying != 0 and g.stage == .fragment);
            const is_out = q & Q.out != 0 or (q & Q.varying != 0 and g.stage == .vertex);
            if (is_in and g.stage == .vertex) {
                // an attribute: its location's registers, as its type
                const io = vio.?;
                const loc = g.lay.attrib(g.lay.ctx, name) orelse {
                    g.declare(.{ .name = name, .ty = t, .at = g.zeros(t).at, .ro = true });
                    continue;
                };
                const n = g.size(t);
                const at = g.alloc(n);
                const rows: u32 = t.rows;
                for (0..n) |ix| {
                    const i_: u32 = @intCast(ix);
                    const col = i_ / rows;
                    const row = i_ % rows;
                    const src = if (loc + col < raster.MAX_ATTRS) io.attr[loc + col][row] else V.none;
                    g.put(at, i_, if (src == .none) u(0) else r(k.mov(kty(t.base), r(src))));
                }
                g.declare(.{ .name = name, .ty = t, .at = at, .ro = true });
                continue;
            }
            if (is_in) {
                // a varying in: the raster's interpolated (or flat) scalars
                const io = fio.?;
                const word = g.lay.varying(g.lay.ctx, name) orelse {
                    g.declare(.{ .name = name, .ty = t, .at = g.zeros(t).at, .ro = true });
                    continue;
                };
                const n = g.size(t);
                const at = g.alloc(n);
                for (0..n) |ix| {
                    const i_: u32 = @intCast(ix);
                    const b = g.baseAt(t, i_);
                    const src = if (word + i_ < raster.MAX_VARYINGS) io.varying[word + i_] else V.none;
                    g.put(at, i_, if (src == .none) u(0) else if (b == .float) r(src) else r(k.mov(kty(b), r(src))));
                }
                g.declare(.{ .name = name, .ty = t, .at = at, .ro = true });
                continue;
            }
            const init: ?Val = if (vn.b != 0) g.rv(g.expr(vn.b)) else null;
            g.bind(name, t, init, q & Q.@"const" != 0 and vn.b != 0);
            if (is_out and nouts.* < outs.len) {
                const word: u32 = if (g.stage == .vertex) (g.lay.varying(g.lay.ctx, name) orelse 0xffff_ffff) else 0;
                const loc: u32 = if (g.stage == .fragment) (g.lay.output(g.lay.ctx, name) orelse 0xffff_ffff) else 0;
                outs[nouts.*] = .{ .var_ix = g.nvars - 1, .word = word, .loc = loc };
                nouts.* += 1;
            }
        }
    }
    return main;
}

fn begin(s: *glsl.Scratch, lay: Layout, k: *kir.Kernel, log: *pp.Log, stage: sema.Stage, uni: u8, texb: u8) Gen {
    @memset(&s.gen.mut, 0);
    return .{ .s = s, .st = &s.gen, .k = k, .lay = lay, .log = log, .stage = stage, .uni = uni, .texb = texb };
}

/// A component as an f32 register (a register's bits, or an immediate's).
fn asF32(g: *Gen, a: Arg) V {
    if (a == .reg and a.reg != .none and g.k.tys[@intFromEnum(a.reg)] == .f32) return a.reg;
    return g.k.mov(.f32, a);
}

fn runMain(g: *Gen, main: u32) void {
    if (main == 0) return g.fail(0, "no main()", .{});
    const body = g.node(main).c;
    const wrapper = g.needsWrapper(body, true);
    g.frames[0] = .{ .ret = null, .wrapper = wrapper, .loop_base = g.nloops, .var_base = g.nglobals, .main = true };
    g.nframes = 1;
    g.runBody(body, wrapper);
    g.nframes = 0;
}

/// The vertex shader in the scratch (compiled) as the vertex kernel's
/// code: io's position and varyings set. False (the log says why) when it
/// cannot be generated.
pub fn vertex(s: *glsl.Scratch, lay: Layout, k: *kir.Kernel, io: *raster.VertexIO, log: *pp.Log) bool {
    var g = begin(s, lay, k, log, .vertex, io.uniforms, io.textures);
    g.bind("gl_Position", sema.vecT(.float, 4), null, false);
    const pos_ix = g.nvars - 1;
    g.bind("gl_PointSize", FLOAT, null, false);
    g.declare(.{ .name = "gl_VertexID", .ty = INT, .at = g.imms(INT, &.{r(k.mov(.i32, r(io.vertex_id)))}).at, .ro = true });
    g.declare(.{ .name = "gl_InstanceID", .ty = INT, .at = g.imms(INT, &.{r(k.mov(.i32, r(io.instance_id)))}).at, .ro = true });
    var outs: [64]Out = undefined;
    var nouts: usize = 0;
    const main = globals(&g, io, null, &outs, &nouts);
    g.nglobals = g.nvars;
    runMain(&g, main);
    const pos = g.st.vars[pos_ix];
    for (0..4) |c| io.position[c] = asF32(&g, g.cp(pos.at, @intCast(c)));
    for (outs[0..nouts]) |o| {
        if (o.word == 0xffff_ffff) continue;
        const v = g.st.vars[o.var_ix];
        const n = g.size(v.ty);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            if (o.word + i_ >= raster.MAX_VARYINGS) break;
            io.varying[o.word + i_] = asF32(&g, g.cp(v.at, i_));
        }
    }
    return !g.failed;
}

/// The fragment shader in the scratch (compiled) as the raster kernel's
/// fragment code: io's color (location 0) and discard set.
pub fn fragment(s: *glsl.Scratch, lay: Layout, k: *kir.Kernel, io: *raster.FragmentIO, log: *pp.Log) bool {
    const lo = k.n;
    var g = begin(s, lay, k, log, .fragment, io.uniforms, io.textures);
    g.quads = io.quads and io.odd_x != .none and io.odd_y != .none;
    g.odd_x = io.odd_x;
    g.odd_y = io.odd_y;
    const v4 = sema.vecT(.float, 4);
    g.declare(.{ .name = "gl_FragCoord", .ty = v4, .at = g.imms(v4, &.{ r(io.frag_coord[0]), r(io.frag_coord[1]), r(io.frag_coord[2]), r(io.frag_coord[3]) }).at, .ro = true });
    g.declare(.{ .name = "gl_FrontFacing", .ty = BOOL, .at = g.imms(BOOL, &.{if (io.front_facing == .none) u(1) else r(io.front_facing)}).at, .ro = true });
    g.declare(.{ .name = "gl_PointCoord", .ty = sema.vecT(.float, 2), .at = g.imms(sema.vecT(.float, 2), &.{ f(0), f(0) }).at, .ro = true });
    g.bind("gl_FragColor", v4, null, false);
    const color_ix = g.nvars - 1;
    var fd_t = v4;
    fd_t.array = 4;
    g.bind("gl_FragData", fd_t, null, false);
    const data_ix = g.nvars - 1;
    g.bind("gl_FragDepth", FLOAT, null, false);
    g.discard = k.reg(.pred);
    k.set(g.discard, .mov, u(0), no, no);
    var outs: [64]Out = undefined;
    var nouts: usize = 0;
    const main = globals(&g, null, io, &outs, &nouts);
    g.nglobals = g.nvars;
    runMain(&g, main);
    // the color: location 0's output, else gl_FragColor (or gl_FragData[0])
    var color: [4]Arg = .{ f(0), f(0), f(0), f(1) };
    if (s.checker.uses_frag_data) {
        for (0..4) |c| color[c] = g.cp(g.st.vars[data_ix].at, @intCast(c));
    } else if (s.checker.version < 300) {
        for (0..4) |c| color[c] = g.cp(g.st.vars[color_ix].at, @intCast(c));
    }
    for (outs[0..nouts]) |o| {
        if (o.loc != 0) continue;
        const v = g.st.vars[o.var_ix];
        const n = @min(g.size(v.ty.elem()), 4);
        for (0..n) |ix| {
            const i_: u32 = @intCast(ix);
            color[ix] = g.convert(g.cp(v.at, i_), g.baseAt(v.ty, i_), .float);
        }
        break;
    }
    for (0..4) |c| io.color[c] = asF32(&g, color[c]);
    io.discard = g.discard;
    io.derivatives = g.derivatives;
    if (g.nderivs > 0) flattenDerivs(k, lo, g.st, g.st.derivs[0..g.nderivs]);
    return !g.failed;
}

// ── Derivatives in control flow that is not uniform ────────────────────────

fn bitOf(set: []const u8, n: usize) bool {
    return set[n >> 3] & (@as(u8, 1) << @intCast(n & 7)) != 0;
}

fn setBit(set: []u8, n: usize) void {
    set[n >> 3] |= @as(u8, 1) << @intCast(n & 7);
}

/// GL leaves a derivative undefined in control flow that is not uniform;
/// here it is 0. A quad's lanes enter the fragment code together (the
/// raster runs it for whole quads), and stay together only while its
/// control flow is uniform: a shuffle elsewhere could read a lane that is
/// not there (a trap in KIR's interpreter, garbage on a GPU). So each of
/// the derivatives' shuffles (`derivs`) at a place in the code from `lo`
/// (the shader's) where a lane may have left, or not come, becomes a copy
/// of the lane's own value.
///
/// Uniform values are alike in every lane of the group: immediates,
/// parameters, group ids, a load from a uniform address, what is computed
/// from uniform values where every lane runs. Divergent: thread and lane
/// ids, atomics, shuffles, what is computed from a divergent value or
/// written in divergent flow. Flow from `lo` on is divergent under an if
/// on a divergent value; after a break or continue on one (or under one)
/// to the end of that pass of its loop; through the whole of a loop left
/// that way that runs more than one pass; after a return. A fixpoint: a
/// register once divergent stays so (every write of it counts, wherever).
fn flattenDerivs(k: *kir.Kernel, lo: usize, st: *Store, derivs: []const u32) void {
    const insts = k.insts[0..k.n];
    if (insts.len > FLOW_BITS) {
        for (derivs) |at| flatten(k, at);
        return;
    }
    @memset(&st.div, 0);
    @memset(&st.loop_div, 0);
    @memset(&st.one_pass, 0);
    const Fr = struct { loop: bool, start: u32, div: bool, has_cont: bool = false };
    var frames: [256]Fr = undefined;
    // the loops that run one pass: no continue, a break last
    {
        var depth: usize = 0;
        for (insts, 0..) |in, ix| {
            switch (in.op) {
                .loop, .@"if" => {
                    if (depth == frames.len) return for (derivs) |at| flatten(k, at);
                    frames[depth] = .{ .loop = in.op == .loop, .start = @intCast(ix), .div = false };
                    depth += 1;
                },
                .cont => {
                    var f_ = depth;
                    while (f_ > 0) : (f_ -= 1) {
                        if (frames[f_ - 1].loop) {
                            frames[f_ - 1].has_cont = true;
                            break;
                        }
                    }
                },
                .endif => depth -|= 1,
                .endloop => {
                    if (depth == 0) continue;
                    depth -= 1;
                    const prev = insts[ix - 1];
                    const last_brk = prev.op == .brk and prev.a == .imm and prev.a.imm != 0;
                    if (last_brk and !frames[depth].has_cont) setBit(&st.one_pass, frames[depth].start);
                },
                else => {},
            }
        }
    }
    const isDiv = struct {
        fn f_(set: []const u8, a: Arg) bool {
            return a == .reg and a.reg != .none and bitOf(set, @intFromEnum(a.reg));
        }
    }.f_;
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 64) : (rounds += 1) {
        changed = false;
        var depth: usize = 0;
        var after_ret = false;
        var dp: usize = 0;
        for (insts, 0..) |in, ix| {
            const region = ix >= lo;
            var cd = after_ret;
            for (frames[0..depth]) |fr| cd = cd or fr.div;
            if (dp < derivs.len and derivs[dp] == ix) {
                st.deriv_div[dp] = cd;
                dp += 1;
            }
            switch (in.op) {
                .@"if" => {
                    frames[depth] = .{ .loop = false, .start = @intCast(ix), .div = region and isDiv(&st.div, in.a) };
                    depth += 1;
                },
                .loop => {
                    const again = !bitOf(&st.one_pass, ix) and bitOf(&st.loop_div, ix);
                    frames[depth] = .{ .loop = true, .start = @intCast(ix), .div = region and again };
                    depth += 1;
                },
                .@"else" => {},
                .endif, .endloop => depth -|= 1,
                .brk, .cont => if (region) {
                    // the loop it leaves (or goes round), and whether some
                    // lanes may take it and others not
                    var l = depth;
                    while (l > 0 and !frames[l - 1].loop) l -= 1;
                    if (l == 0) continue;
                    var inner = isDiv(&st.div, in.a);
                    for (frames[l..depth]) |fr| inner = inner or fr.div;
                    if (inner) {
                        frames[l - 1].div = true;
                        if (!bitOf(&st.loop_div, frames[l - 1].start)) {
                            setBit(&st.loop_div, frames[l - 1].start);
                            changed = true;
                        }
                    }
                },
                .ret => after_ret = after_ret or region,
                else => {
                    if (in.dst == .none) continue;
                    const d: bool = switch (in.op) {
                        .tid, .lane, .atom, .shfl => true,
                        .gid, .gsize, .subgroup, .param, .vote => cd and region,
                        else => (region and cd) or isDiv(&st.div, in.a) or isDiv(&st.div, in.b) or isDiv(&st.div, in.c),
                    };
                    if (!d) continue;
                    const nregs: usize = if (in.op == .ld) kir.memRegs(@bitCast(in.aux)) else 1;
                    for (0..nregs) |j| {
                        const v = @as(usize, @intFromEnum(in.dst)) + j;
                        if (v >= FLOW_BITS or bitOf(&st.div, v)) continue;
                        setBit(&st.div, v);
                        changed = true;
                    }
                },
            }
        }
    }
    for (derivs, 0..) |at, j| {
        if (changed or st.deriv_div[j]) flatten(k, at);
    }
}

/// A derivative's shuffle becomes a copy of the lane's own value.
fn flatten(k: *kir.Kernel, at: u32) void {
    const in = k.insts[at];
    k.insts[at] = .{ .op = .mov, .ty = in.ty, .dst = in.dst, .a = in.a, .b = no, .c = no, .aux = 0 };
}
