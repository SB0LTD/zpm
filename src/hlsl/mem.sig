//! @zpm/hlsl mem — places in memory, as Shader Model 5 has them:
//! groupshared variables (g#), structured and byte address buffers (t# to
//! read, u# to write) and typed UAVs (RWTexture*, RWBuffer: u#).
//!
//! - **Layout.** fxc lays groupshared variables and structured buffers'
//!   elements out tightly, four bytes a component: a float3 then a uint
//!   take 16 bytes, a matrix its rows * cols components (column-major:
//!   each column's components together), an array its elements one after
//!   another. A groupshared array is a structured g# (its element's size
//!   and count), anything else a raw one (its bytes).
//! - **Places.** A place (Val kind .mem) is a register, the element chosen
//!   (structured: srcs[at]), a byte offset known now (Val.off) and one known
//!   at run time (srcs[at + 1]); members, elements and swizzles move it
//!   without code. Reading it loads the components it covers (ld_raw,
//!   ld_structured: up to four in one when they lie within four dwords);
//!   writing it stores runs of consecutive dwords (store_raw,
//!   store_structured), as fxc does.
//! - **Typed UAVs** are read and written a whole element at a time
//!   (ld_uav_typed, store_uav_typed: fxc refuses partial writes).
//! - **Atomics** (Interlocked*, the buffers' counters, Append/Consume) on
//!   any of them, with the original value (imm_atomic_*) or without
//!   (atomic_*).

const std = @import("std");
const ast = @import("ast.sig");
const ir = @import("ir.sig");
const gen = @import("gen.sig");
const intrin = @import("intrin.sig");

const Gen = gen.Gen;
const Val = gen.Val;
const Src = gen.Src;
const Mem = gen.Mem;
const LVal = gen.LVal;
const imm1 = Gen.imm1;
const component = Gen.component;
const mkVal = Gen.mkVal;

// ── layout ─────────────────────────────────────────────────────────────────

/// A type's bytes in memory (tightly packed).
pub fn size(g: *const Gen, t: u32) u32 {
    const x = g.a.types[t];
    return switch (x.class) {
        .scalar => if (ast.canon(x.base) == .double) 8 else 4,
        .vector => 4 * @as(u32, x.cols),
        .matrix => 4 * @as(u32, x.rows) * x.cols,
        .array => x.len * size(g, x.elem),
        .structure => blk: {
            var n: u32 = 0;
            for (0..x.len) |k| n += size(g, g.a.members[x.first + k].ty);
            break :blk n;
        },
        else => 0,
    };
}

/// A struct member's byte offset in memory.
pub fn memberOff(g: *const Gen, st: u32, k: usize) u32 {
    const x = g.a.types[st];
    var off: u32 = 0;
    for (0..k) |j| off += size(g, g.a.members[x.first + j].ty);
    return off;
}

/// A matrix component's dword from the matrix's start.
fn matDword(g: *const Gen, x: ast.Type, r: u32, c: u32) u32 {
    if (g.effPackPub(x) == .row) return r * x.cols + c;
    return c * x.rows + r;
}

/// D3D10_SB_RESOURCE_RETURN_TYPE of an element's base.
pub fn retKind(b: ast.Base) u32 {
    return switch (ast.canon(b)) {
        .int => 3,
        .uint, .bool => 4,
        else => 5,
    };
}

/// A texture's or typed UAV's return type: unorm (1), snorm (2), or its
/// element's base.
pub fn objRet(g: *const Gen, t: ast.Type) u32 {
    if (t.first == 1) return 1;
    if (t.first == 2) return 2;
    return retKind(g.a.types[if (t.elem == 0) g.a.vector(.float, 4) else t.elem].base);
}

/// The return type token (a nibble per component) of a texture or typed UAV.
pub fn objRetToken(g: *const Gen, t: ast.Type) u16 {
    const rt = objRet(g, t);
    return @intCast(rt | rt << 4 | rt << 8 | rt << 12);
}

/// A resource variable's object type (an array's element).
fn objectType(g: *const Gen, sym: u32) ast.Type {
    var t = g.a.types[g.a.syms[sym].ty];
    while (t.class == .array) t = g.a.types[t.elem];
    return t;
}

/// Coordinates a typed UAV takes (RWTexture*, RWBuffer).
pub fn typedCoords(d: ast.TexDim) u8 {
    return switch (d) {
        .buffer, .tex1d => 1,
        .tex1darray, .tex2d => 2,
        else => 3,
    };
}

// ── places ─────────────────────────────────────────────────────────────────

fn place(g: *Gen, ty: u32, m: Mem, ix: Src, dyn: Src, off: u32, sym: u32, elem: u32) Val {
    const at = g.newSrcs(2);
    g.srcs[at] = ix;
    g.srcs[at + 1] = dyn;
    return .{ .ty = ty, .kind = .mem, .at = at, .n = 2, .off = off, .sym = sym, .elem = elem, .m = m };
}

/// The same place with srcs of its own (to change).
fn derive(g: *Gen, v: Val) Val {
    return place(g, v.ty, v.m, g.srcs[v.at], g.srcs[v.at + 1], v.off, v.sym, v.elem);
}

fn regOf(m: Mem) ir.Reg {
    return switch (m.space) {
        .tgsm => .tgsm,
        .uav => .uav,
        .srv => .resource,
    };
}

/// A groupshared variable's place (its g# given on first use).
pub fn tgsmPlace(g: *Gen, sym: u32) Val {
    const s = g.a.syms[sym];
    if (g.target.stage != .compute) {
        g.failCode(3579, "{s} does not support groupshared", .{g.targetName()});
        return g.immVal(g.scalarTy(.float), 0);
    }
    const t = g.a.types[s.ty];
    const structured = t.class == .array;
    var reg: ?u32 = null;
    for (g.tgsm[0..g.ntgsm]) |x| if (x.sym == sym) {
        reg = x.reg;
    };
    if (reg == null) {
        if (g.ntgsm >= g.tgsm.len) {
            g.fail("too many groupshared variables", .{});
            return g.immVal(g.scalarTy(.float), 0);
        }
        reg = gen.TGSM_PROVISIONAL + g.ntgsm;
        g.tgsm[g.ntgsm] = .{ .sym = sym, .reg = reg.?, .structured = structured, .stride = if (structured) size(g, t.elem) else size(g, s.ty), .count = if (structured) t.len else 1 };
        g.ntgsm += 1;
    }
    const m = Mem{ .space = .tgsm, .kind = if (structured) .structured else .raw, .reg = reg.?, .stride = if (structured) size(g, t.elem) else 0 };
    return place(g, s.ty, m, imm1(0), imm1(0), 0, sym, 0);
}

/// A structured buffer's element `iv` (StructuredBuffer, RWStructuredBuffer).
fn sbPlace(g: *Gen, obj: Val, iv: Val) Val {
    const t = g.a.types[obj.ty];
    const k: ast.BufKind = @enumFromInt(t.dim);
    if (k != .structured and k != .rw_structured) {
        g.fail("'[]' is not defined on this buffer", .{});
        return g.immVal(g.scalarTy(.float), 0);
    }
    const rw = ast.bufWritable(k);
    const reg = g.resource(obj.sym, obj.elem, if (rw) 'u' else 't');
    const m = Mem{ .space = if (rw) .uav else .srv, .kind = .structured, .reg = reg, .stride = size(g, t.elem), .indexed = true };
    return place(g, t.elem, m, g.indexSrc(iv), imm1(0), 0, obj.sym, obj.elem);
}

/// A byte address buffer's place at a byte address, seen as `ty`.
pub fn rawPlace(g: *Gen, obj: Val, addr: Src, ty: u32) Val {
    const t = g.a.types[obj.ty];
    const rw = ast.bufWritable(@enumFromInt(t.dim));
    const reg = g.resource(obj.sym, obj.elem, if (rw) 'u' else 't');
    const m = Mem{ .space = if (rw) .uav else .srv, .kind = .raw, .reg = reg };
    return place(g, ty, m, imm1(0), g.plain(addr), 0, obj.sym, obj.elem);
}

/// A typed UAV's element at `iv` (its coordinates).
fn typedPlace(g: *Gen, obj: Val, iv: Val) Val {
    const t = g.a.types[obj.ty];
    const reg = g.resource(obj.sym, obj.elem, 'u');
    const m = Mem{ .space = .uav, .kind = .typed, .reg = reg, .stride = t.dim };
    return place(g, t.elem, m, coords(g, t, iv), imm1(0), 0, obj.sym, obj.elem);
}

/// The coordinates of a typed UAV's element: uints, as many as it has.
fn coords(g: *Gen, t: ast.Type, iv: Val) Src {
    const n = typedCoords(@enumFromInt(t.dim));
    const r = g.canonRows(g.convert(iv, g.a.vector(.uint, n)));
    var s = g.plain(g.srcs[r.at]);
    if (s.n > n) s.n = n;
    return s;
}

/// `obj[iv]` read as a value (textures and typed UAVs: their element now)
/// or a place (structured buffers).
pub fn objectIndex(g: *Gen, obj: Val, iv: Val) Val {
    const t = g.a.types[obj.ty];
    switch (t.class) {
        .texture => return intrin.textureIndex(g, obj, iv),
        .rwtexture => return typedLoad(g, typedPlace(g, obj, iv)),
        .sbuffer => return sbPlace(g, obj, iv),
        else => {
            g.fail("subscript of a non-array", .{});
            return g.immVal(g.scalarTy(.float), 0);
        },
    }
}

/// A member or swizzle of a place.
pub fn member(g: *Gen, v: Val, name: []const u8) Val {
    const t = g.a.types[v.ty];
    var r = derive(g, v);
    switch (t.class) {
        .structure => {
            for (0..t.len) |k| {
                const m = g.a.members[t.first + k];
                if (!std.mem.eql(u8, g.a.name(m.name_off, m.name_len), name)) continue;
                r.ty = m.ty;
                r.off = v.off + memberOff(g, v.ty, k);
                r.m.ncomp = 0;
                return r;
            }
            g.fail("'{s}' is not a member of '{s}'", .{ name, g.tyName(v.ty) });
        },
        .scalar, .vector => {
            var sw: [4]u2 = undefined;
            const n = gen.swizzle(name, t.cols, &sw) orelse {
                g.fail("invalid swizzle '{s}'", .{name});
                return r;
            };
            const base = comps(v);
            for (0..n) |k| r.m.comp[k] = base[sw[k]];
            r.m.ncomp = n;
            r.ty = g.a.vector(t.base, n);
            return r;
        },
        .matrix => {
            var idx: [4][2]u8 = undefined;
            const n = gen.matSwizzle(name, &idx) orelse {
                g.fail("invalid matrix swizzle '{s}'", .{name});
                return r;
            };
            for (0..n) |k| r.m.comp[k] = @intCast(matDword(g, t, idx[k][0], idx[k][1]));
            r.m.ncomp = @intCast(n);
            r.ty = g.a.vector(t.base, @intCast(n));
            return r;
        },
        else => g.fail("'{s}' has no members", .{g.tyName(v.ty)}),
    }
    return r;
}

/// A vector place's components (dwords from its offset).
fn comps(v: Val) [4]u8 {
    if (v.m.ncomp > 0) return v.m.comp;
    return .{ 0, 1, 2, 3 };
}

/// `dyn + x` (a run-time byte offset).
fn addDyn(g: *Gen, dyn: Src, x: Src) Src {
    if (dyn.reg == .imm32 and dyn.imm[0] == 0) return x;
    return g.alu(.iadd, 1, &.{ g.plain(dyn), x });
}

/// An element of a place: a structured array's element, an array's, a
/// vector's component, a matrix's row.
pub fn index(g: *Gen, v: Val, iv: Val) Val {
    const t = g.a.types[v.ty];
    var r = derive(g, v);
    const ci = g.constIndex(iv);
    if (t.class == .array) {
        if (ci) |i| if (i >= t.len) {
            g.fail("array index out of bounds", .{});
            return r;
        };
        r.ty = t.elem;
        if (v.m.kind == .structured and !v.m.indexed) {
            // (the groupshared array's element: the structured index)
            g.srcs[r.at] = g.indexSrc(iv);
            r.m.indexed = true;
            return r;
        }
        const st = size(g, t.elem);
        if (ci) |i| {
            r.off += i * st;
        } else g.srcs[r.at + 1] = addDyn(g, g.srcs[v.at + 1], g.alu(.imul, 1, &.{ g.indexSrc(iv), imm1(st) }));
        return r;
    }
    if (t.class == .vector or t.class == .scalar) {
        r.ty = g.a.scalar(t.base);
        if (ci) |i| {
            if (i >= t.cols) {
                g.fail("vector index out of bounds", .{});
                return r;
            }
            r.m.comp[0] = comps(v)[i];
            r.m.ncomp = 1;
            return r;
        }
        if (v.m.ncomp > 0) {
            g.fail("a swizzle indexed at run time", .{});
            return r;
        }
        g.srcs[r.at + 1] = addDyn(g, g.srcs[v.at + 1], g.alu(.ishl, 1, &.{ g.indexSrc(iv), imm1(2) }));
        return r;
    }
    if (t.class == .matrix) {
        r.ty = g.a.vector(t.base, t.cols);
        const row = g.effPackPub(t) == .row;
        if (ci) |i| {
            if (i >= t.rows) {
                g.fail("matrix row index out of bounds", .{});
                return r;
            }
            if (row) {
                r.off += i * t.cols * 4;
                r.m.ncomp = 0;
            } else {
                for (0..t.cols) |c| r.m.comp[c] = @intCast(matDword(g, t, i, @intCast(c)));
                r.m.ncomp = t.cols;
            }
            return r;
        }
        // (a row chosen at run time: its first component's dword moves)
        const step: u32 = if (row) t.cols * 4 else 4;
        g.srcs[r.at + 1] = addDyn(g, g.srcs[v.at + 1], g.alu(.imul, 1, &.{ g.indexSrc(iv), imm1(step) }));
        if (!row) {
            for (0..t.cols) |c| r.m.comp[c] = @intCast(c * t.rows);
            r.m.ncomp = t.cols;
        } else r.m.ncomp = 0;
        return r;
    }
    g.fail("subscript of a non-array", .{});
    return r;
}

// ── as lvalues ─────────────────────────────────────────────────────────────

pub fn lmember(g: *Gen, pl: Val, name: []const u8) LVal {
    if (pl.kind == .mem and pl.m.kind == .typed) {
        g.failCode(4596, "typed UAV stores must write all declared components.", .{});
        return .{ .ty = pl.ty };
    }
    if (pl.kind != .mem) {
        g.fail("'{s}' has no members", .{g.tyName(pl.ty)});
        return .{ .ty = pl.ty };
    }
    const r = member(g, pl, name);
    return .{ .ty = r.ty, .place = r };
}

pub fn lindex(g: *Gen, pl: Val, idx_node: u32) LVal {
    const iv = g.expr(idx_node);
    if (g.failed) return .{ .ty = pl.ty };
    if (pl.kind == .object) {
        const t = g.a.types[pl.ty];
        const r = switch (t.class) {
            .array => g.indexVal(pl, iv),
            .rwtexture => typedPlace(g, pl, iv),
            .sbuffer => sbPlace(g, pl, iv),
            else => {
                g.failCode(3025, "l-value specifies const object", .{});
                return .{ .ty = pl.ty };
            },
        };
        return .{ .ty = r.ty, .place = r };
    }
    if (pl.kind != .mem) {
        g.fail("l-value required", .{});
        return .{ .ty = pl.ty };
    }
    if (pl.m.kind == .typed) {
        g.failCode(4596, "typed UAV stores must write all declared components.", .{});
        return .{ .ty = pl.ty };
    }
    const r = index(g, pl, iv);
    return .{ .ty = r.ty, .place = r };
}

// ── reading ────────────────────────────────────────────────────────────────

/// A place's value: its components loaded (rows as a constant buffer's
/// are: a column-major matrix gives its columns).
pub fn read(g: *Gen, v: Val) Val {
    // (an object passed inout, a stream to a helper: itself)
    if (v.kind != .mem) return v;
    if (v.m.kind == .typed) return typedLoad(g, v);
    const n = g.cbRowCount(v.ty);
    const first = g.newSrcs(n);
    var k: u32 = 0;
    if (v.m.kind == .structured and !v.m.indexed) {
        // (a whole groupshared array: each element)
        const t = g.a.types[v.ty];
        for (0..t.len) |e| {
            var ev = derive(g, v);
            g.srcs[ev.at] = imm1(@intCast(e));
            ev.m.indexed = true;
            ev.ty = t.elem;
            readInto(g, t.elem, ev, 0, null, first, &k);
        }
    } else readInto(g, v.ty, v, 0, if (v.m.ncomp > 0) v.m.comp[0..v.m.ncomp] else null, first, &k);
    return mkVal(v.ty, first, n);
}

fn readInto(g: *Gen, t: u32, v: Val, rel: u32, cs: ?[]const u8, first: u32, k: *u32) void {
    const x = g.a.types[t];
    switch (x.class) {
        .scalar, .vector => {
            const natural = [4]u8{ 0, 1, 2, 3 };
            var s = load(g, v, rel, cs orelse natural[0..x.cols]);
            if (ast.canon(x.base) == .bool) s = g.alu(.ine, x.cols, &.{ s, imm1(0) });
            g.srcs[first + k.*] = s;
            k.* += 1;
        },
        .matrix => {
            const row = g.effPackPub(x) == .row;
            const nv: u32 = if (row) x.rows else x.cols;
            const per: u8 = if (row) x.cols else x.rows;
            const natural = [4]u8{ 0, 1, 2, 3 };
            for (0..nv) |r| {
                var s = load(g, v, rel + @as(u32, @intCast(r)) * per * 4, natural[0..per]);
                s.col = !row;
                g.srcs[first + k.*] = s;
                k.* += 1;
            }
        },
        .array => {
            const st = size(g, x.elem);
            for (0..x.len) |e| readInto(g, x.elem, v, rel + @as(u32, @intCast(e)) * st, null, first, k);
        },
        .structure => {
            for (0..x.len) |m| readInto(g, g.a.members[x.first + m].ty, v, rel + memberOff(g, t, m), null, first, k);
        },
        else => g.fail("{s} cannot be read from memory", .{g.tyName(t)}),
    }
}

/// The components `cs` (dwords from rel) of a place: one load when they lie
/// within four dwords, else one each.
fn load(g: *Gen, v: Val, rel: u32, cs: []const u8) Src {
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (cs) |c| {
        lo = @min(lo, c);
        hi = @max(hi, c);
    }
    if (hi - lo < 4) {
        var sw: [4]u2 = undefined;
        for (cs, 0..) |c, j| sw[j] = @intCast(c - lo);
        return loadRun(g, v, rel + @as(u32, lo) * 4, sw, @intCast(cs.len));
    }
    var sc: [4]Src = undefined;
    for (cs, 0..) |c, j| sc[j] = loadRun(g, v, rel + @as(u32, c) * 4, .{ 0, 0, 0, 0 }, 1);
    return g.pack(sc[0..cs.len]);
}

/// The run-time byte offset plus `c`: an immediate or a temp.
fn offsetSrc(g: *Gen, v: Val, c: u32) Src {
    const dyn = g.srcs[v.at + 1];
    const at = v.off + c;
    if (dyn.reg == .imm32) return imm1(dyn.imm[0] +% at);
    if (at == 0) return g.plain(dyn);
    return g.alu(.iadd, 1, &.{ g.plain(dyn), imm1(at) });
}

/// Coordinates as an operand of four components (an immediate too).
fn coordOpnd(g: *Gen, s: Src, n: u8) ir.Opnd {
    var o = g.opnd(s, .{ 0, 1, 2, 3 }, n);
    if (o.reg == .imm32 and o.comps == 1) {
        o.comps = 4;
        o.imm = .{ o.imm[0], o.imm[0], o.imm[0], o.imm[0] };
    }
    return o;
}

/// A scalar operand (select1, or a one-component immediate).
fn scalarOpnd(g: *Gen, s: Src) ir.Opnd {
    return g.condOpnd(g.plain(s));
}

fn memOpnd(m: Mem, sw: [4]u2, n: u8) ir.Opnd {
    var full = sw;
    for (n..4) |j| full[j] = sw[0];
    return .{ .reg = regOf(m), .comps = 4, .mode = .swizzle, .swz = full, .dims = 1, .idx = .{ m.reg, 0 } };
}

/// The resource dimension and return type tokens fxc puts on loads from
/// buffers (not groupshared memory).
fn bufferTokens(i: *ir.Inst, m: Mem) void {
    if (m.space == .tgsm) return;
    i.res_dim = if (m.kind == .structured) ir.DIM_STRUCTURED else ir.DIM_RAW;
    i.res_stride = if (m.kind == .structured) @intCast(m.stride) else 0;
    i.res_ret = ir.RET_MIXED;
}

/// n dwords from byte `rel` of a place, dst component j the dword sw[j].
fn loadRun(g: *Gen, v: Val, rel: u32, sw: [4]u2, n: u8) Src {
    const dst = g.vreg();
    var i = ir.Inst{ .op = .ld_raw, .n = 3 };
    i.ops[0] = Gen.dstOpnd(dst, .{ 0, 1, 2, 3 }, n);
    if (v.m.kind == .structured) {
        i.op = .ld_structured;
        i.ops[1] = scalarOpnd(g, g.srcs[v.at]);
        i.ops[2] = scalarOpnd(g, offsetSrc(g, v, rel));
        i.ops[3] = memOpnd(v.m, sw, n);
        i.n = 4;
    } else {
        i.ops[1] = scalarOpnd(g, offsetSrc(g, v, rel));
        i.ops[2] = memOpnd(v.m, sw, n);
    }
    bufferTokens(&i, v.m);
    g.emit(i);
    return Gen.tempSrc(dst, n);
}

/// A typed UAV's element (ld_uav_typed).
fn typedLoad(g: *Gen, v: Val) Val {
    const et = v.ty;
    const x = g.a.types[et];
    const n: u8 = if (x.class == .vector) x.cols else 1;
    const dim: ast.TexDim = @enumFromInt(v.m.stride);
    const nc = typedCoords(dim);
    const dst = g.vreg();
    var i = ir.Inst{ .op = .ld_uav_typed, .n = 3 };
    i.ops[0] = Gen.dstOpnd(dst, .{ 0, 1, 2, 3 }, n);
    i.ops[1] = coordOpnd(g, g.srcs[v.at], nc);
    i.ops[2] = memOpnd(v.m, .{ 0, 1, 2, 3 }, 4);
    i.res_dim = @intCast(intrin.resDim(dim));
    i.res_ret = objRetToken(g, objectType(g, v.sym));
    g.emit(i);
    const first = g.newSrcs(1);
    g.srcs[first] = Gen.tempSrc(dst, n);
    return mkVal(et, first, 1);
}

// ── writing ────────────────────────────────────────────────────────────────

/// Stores `v` (of the place's type) to a place.
pub fn write(g: *Gen, pl: Val, v: Val) void {
    if (g.failed) return;
    // (an inout object back to its argument: the same object, nothing to do)
    if (pl.kind == .object and v.kind == .object) return;
    if (pl.kind != .mem) return g.fail("l-value required", .{});
    if (pl.m.space == .srv) return g.failCode(3025, "l-value specifies const object", .{});
    const rows = g.canonRows(v);
    if (pl.m.kind == .typed) return typedStore(g, pl, g.srcs[rows.at]);
    var k: u32 = 0;
    if (pl.m.kind == .structured and !pl.m.indexed) {
        const t = g.a.types[pl.ty];
        for (0..t.len) |e| {
            var ev = derive(g, pl);
            g.srcs[ev.at] = imm1(@intCast(e));
            ev.m.indexed = true;
            ev.ty = t.elem;
            writeFrom(g, t.elem, ev, 0, null, rows, &k);
        }
        return;
    }
    writeFrom(g, pl.ty, pl, 0, if (pl.m.ncomp > 0) pl.m.comp[0..pl.m.ncomp] else null, rows, &k);
}

fn writeFrom(g: *Gen, t: u32, pl: Val, rel: u32, cs: ?[]const u8, rows: Val, k: *u32) void {
    const x = g.a.types[t];
    switch (x.class) {
        .scalar, .vector => {
            const natural = [4]u8{ 0, 1, 2, 3 };
            storeComps(g, pl, rel, cs orelse natural[0..x.cols], g.srcs[rows.at + k.*]);
            k.* += 1;
        },
        .matrix => {
            // (canonical rows: a column-major row's components lie apart)
            for (0..x.rows) |r| {
                var d: [4]u8 = undefined;
                for (0..x.cols) |c| d[c] = @intCast(matDword(g, x, @intCast(r), @intCast(c)));
                storeComps(g, pl, rel, d[0..x.cols], g.srcs[rows.at + k.*]);
                k.* += 1;
            }
        },
        .array => {
            const st = size(g, x.elem);
            for (0..x.len) |e| writeFrom(g, x.elem, pl, rel + @as(u32, @intCast(e)) * st, null, rows, k);
        },
        .structure => {
            for (0..x.len) |m| writeFrom(g, g.a.members[x.first + m].ty, pl, rel + memberOff(g, t, m), null, rows, k);
        },
        else => g.fail("{s} cannot be written to memory", .{g.tyName(t)}),
    }
}

/// Value components [j, j + n) as a source of n components.
fn part(s: Src, j: usize, n: u8) Src {
    var x = s;
    for (0..n) |c| {
        const from = if (s.n == 1) 0 else j + c;
        if (s.reg == .imm32) x.imm[c] = s.imm[from] else x.swz[c] = s.swz[from];
    }
    x.n = n;
    return x;
}

/// Stores a value's components to dwords `cs` (from rel): each run of
/// consecutive dwords one store.
fn storeComps(g: *Gen, pl: Val, rel: u32, cs: []const u8, value0: Src) void {
    const value = g.plain(value0);
    var j: usize = 0;
    while (j < cs.len) {
        var e = j + 1;
        while (e < cs.len and cs[e] == cs[e - 1] + 1) e += 1;
        storeRun(g, pl, rel + @as(u32, cs[j]) * 4, part(value, j, @intCast(e - j)));
        j = e;
    }
}

fn storeRun(g: *Gen, pl: Val, rel: u32, value: Src) void {
    const n = value.n;
    var i = ir.Inst{ .op = .store_raw, .n = 3 };
    i.ops[0] = .{ .reg = regOf(pl.m), .comps = 4, .mode = .mask, .mask = @intCast((@as(u32, 1) << @intCast(n)) - 1), .dims = 1, .idx = .{ pl.m.reg, 0 } };
    if (pl.m.kind == .structured) {
        i.op = .store_structured;
        i.ops[1] = scalarOpnd(g, g.srcs[pl.at]);
        i.ops[2] = scalarOpnd(g, offsetSrc(g, pl, rel));
        i.ops[3] = g.opnd(value, .{ 0, 1, 2, 3 }, n);
        i.n = 4;
    } else {
        i.ops[1] = scalarOpnd(g, offsetSrc(g, pl, rel));
        i.ops[2] = g.opnd(value, .{ 0, 1, 2, 3 }, n);
    }
    g.emit(i);
}

/// A typed UAV's whole element (store_uav_typed).
fn typedStore(g: *Gen, pl: Val, value: Src) void {
    const x = g.a.types[pl.ty];
    const n: u8 = if (x.class == .vector) x.cols else 1;
    const nc = typedCoords(@enumFromInt(pl.m.stride));
    var i = ir.Inst{ .op = .store_uav_typed, .n = 3 };
    i.ops[0] = .{ .reg = .uav, .comps = 4, .mode = .mask, .mask = 0xf, .dims = 1, .idx = .{ pl.m.reg, 0 } };
    i.ops[1] = coordOpnd(g, g.srcs[pl.at], nc);
    i.ops[2] = coordOpnd(g, g.plain(value), n);
    g.emit(i);
}

// ── atomics ────────────────────────────────────────────────────────────────

pub const Atomic = enum { add, min, max, @"and", @"or", xor, exchange, cmp_exchange, cmp_store };

/// An atomic operation on a scalar place: its original value (with
/// `want`), as a uint/int source; null when it failed.
pub fn atomic(g: *Gen, pl: Val, what: Atomic, a: Src, b: ?Src, want: bool) ?Src {
    if (!atomicTarget(g, pl, what)) return null;
    const signed = ast.canon(g.a.types[pl.ty].base) == .int;
    const op: ir.Op = switch (what) {
        .add => if (want) .imm_atomic_iadd else .atomic_iadd,
        .min => if (signed) (if (want) .imm_atomic_imin else .atomic_imin) else (if (want) .imm_atomic_umin else .atomic_umin),
        .max => if (signed) (if (want) .imm_atomic_imax else .atomic_imax) else (if (want) .imm_atomic_umax else .atomic_umax),
        .@"and" => if (want) .imm_atomic_and else .atomic_and,
        .@"or" => if (want) .imm_atomic_or else .atomic_or,
        .xor => if (want) .imm_atomic_xor else .atomic_xor,
        .exchange => .imm_atomic_exch,
        .cmp_exchange => .imm_atomic_cmp_exch,
        .cmp_store => .atomic_cmp_store,
    };
    const imm_form = @intFromEnum(op) >= @intFromEnum(ir.Op.imm_atomic_alloc);
    var i = ir.Inst{ .op = op, .n = 0, .ndst = 1 };
    var dst: u32 = 0;
    if (imm_form) {
        dst = g.vreg();
        i.ops[0] = Gen.dstOpnd(dst, .{ 0, 1, 2, 3 }, 1);
        i.ndst = 2;
        i.n = 1;
    }
    i.ops[i.n] = .{ .reg = regOf(pl.m), .comps = 0, .dims = 1, .idx = .{ pl.m.reg, 0 } };
    i.n += 1;
    i.ops[i.n] = address(g, pl);
    i.n += 1;
    i.ops[i.n] = scalarOpnd(g, a);
    i.n += 1;
    if (b) |x| {
        i.ops[i.n] = scalarOpnd(g, x);
        i.n += 1;
    }
    g.emit(i);
    return if (imm_form) Gen.tempSrc(dst, 1) else null;
}

/// Whether a place takes atomics: a UAV's or groupshared scalar int or
/// uint (a float only exchanged); an error as fxc gives it when not.
pub fn atomicTarget(g: *Gen, pl: Val, what: Atomic) bool {
    if (pl.kind != .mem) {
        g.failCode(3549, "interlocked targets must be groupshared or UAV elements", .{});
        return false;
    }
    if (pl.m.space == .srv) {
        g.failCode(3025, "l-value specifies const object", .{});
        return false;
    }
    const t = g.a.types[pl.ty];
    const base = ast.canon(t.base);
    const intish = base == .int or base == .uint;
    if (t.class != .scalar or !(intish or (what == .exchange and base == .float))) {
        g.failCode(3681, "{s} only supports interlocked operations on scalar int or uint data", .{g.targetName()});
        return false;
    }
    return true;
}

/// An atomic's address operand: a typed element's coordinates, a raw
/// byte address, or a structured element and byte (two components).
fn address(g: *Gen, pl: Val) ir.Opnd {
    const c: u32 = if (pl.m.ncomp > 0) @as(u32, pl.m.comp[0]) * 4 else 0;
    switch (pl.m.kind) {
        .typed => {
            const nc = typedCoords(@enumFromInt(pl.m.stride));
            if (nc == 1) return scalarOpnd(g, g.srcs[pl.at]);
            return g.opnd(g.srcs[pl.at], .{ 0, 1, 2, 3 }, nc);
        },
        .raw => return scalarOpnd(g, offsetSrc(g, pl, c)),
        .structured => {
            const ix = component(g.plain(g.srcs[pl.at]), 0);
            const off = offsetSrc(g, pl, c);
            const s = g.pack(&.{ ix, component(off, 0) });
            return g.opnd(s, .{ 0, 1, 2, 3 }, 2);
        },
    }
}

/// A structured buffer's hidden counter: IncrementCounter (or Append's
/// slot: imm_atomic_alloc) and DecrementCounter (or Consume's:
/// imm_atomic_consume); the element index it gives.
pub fn counter(g: *Gen, obj: Val, inc: bool, mark: bool) Src {
    const k = g.resEntry(obj.sym, obj.elem, 'u') orelse return imm1(0);
    if (mark) {
        g.res[k].counter |= if (inc) 1 else 2;
        if (g.res[k].counter == 3) {
            g.failCode(4595, "RWStructuredBuffers may increment or decrement their counters, but not both.", .{});
            return imm1(0);
        }
    }
    const dst = g.vreg();
    var i = ir.Inst{ .op = if (inc) .imm_atomic_alloc else .imm_atomic_consume, .n = 2, .ndst = 2 };
    i.ops[0] = Gen.dstOpnd(dst, .{ 0, 1, 2, 3 }, 1);
    i.ops[1] = .{ .reg = .uav, .comps = 0, .dims = 1, .idx = .{ g.res[k].slot, 0 } };
    g.emit(i);
    return Gen.tempSrc(dst, 1);
}

/// The element `index` of a UAV structured buffer (Append, Consume,
/// counters).
pub fn uavElement(g: *Gen, obj: Val, ix: Src) Val {
    const t = g.a.types[obj.ty];
    const reg = g.resource(obj.sym, obj.elem, 'u');
    const m = Mem{ .space = .uav, .kind = .structured, .reg = reg, .stride = size(g, t.elem), .indexed = true };
    return place(g, t.elem, m, ix, imm1(0), 0, obj.sym, obj.elem);
}

/// bufinfo: a buffer's element count (structured, typed) or bytes (raw).
pub fn bufinfo(g: *Gen, obj: Val, kind: u8) Src {
    const t = g.a.types[obj.ty];
    const reg = g.resource(obj.sym, obj.elem, kind);
    const dst = g.vreg();
    var i = ir.Inst{ .op = .bufinfo, .n = 2 };
    i.ops[0] = Gen.dstOpnd(dst, .{ 0, 1, 2, 3 }, 1);
    i.ops[1] = .{ .reg = if (kind == 'u') .uav else .resource, .comps = 4, .mode = .swizzle, .dims = 1, .idx = .{ reg, 0 } };
    switch (t.class) {
        .sbuffer => {
            const structured = ast.bufStructured(@enumFromInt(t.dim));
            i.res_dim = if (structured) ir.DIM_STRUCTURED else ir.DIM_RAW;
            i.res_stride = if (structured) @intCast(size(g, t.elem)) else 0;
            i.res_ret = ir.RET_MIXED;
        },
        else => {
            i.res_dim = 1;
            i.res_ret = objRetToken(g, t);
        },
    }
    g.emit(i);
    return Gen.tempSrc(dst, 1);
}

test "tight layout: a struct's members one after another, a matrix by columns" {
    const hlsl = @import("hlsl.sig");
    const S = struct {
        var c: hlsl.Compiler = undefined;
    };
    const r = S.c.compile(
        \\struct T { float3 p; uint f; float2 uv; float4x4 m; int a[3]; };
        \\RWStructuredBuffer<T> b;
        \\[numthreads(1, 1, 1)] void main(uint3 id : SV_DispatchThreadID) { b[id.x].m[2].y = 3; b[id.x].a[1] = 5; }
    , .{ .target = "cs_5_0" });
    if (!r.ok) std.debug.print("{s}\n", .{r.messages});
    try std.testing.expect(r.ok);
    // (fxc: p@0 f@12 uv@16 m@24 a@88, 100 bytes; m[2].y is row 2 column 1)
    try std.testing.expectEqual(@as(u32, 100), size(&S.c.g, S.c.ast.types[S.c.ast.syms[S.c.g.res[0].sym].ty].elem));
    var found_48 = false;
    var found_92 = false;
    for (S.c.prog.insts[0..S.c.prog.n]) |i| {
        if (i.op != .store_structured) continue;
        if (i.ops[2].reg == .imm32 and i.ops[2].imm[0] == 48) found_48 = true;
        if (i.ops[2].reg == .imm32 and i.ops[2].imm[0] == 92) found_92 = true;
    }
    try std.testing.expect(found_48 and found_92);
}
