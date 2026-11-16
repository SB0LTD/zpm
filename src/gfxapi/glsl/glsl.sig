//! @zpm/gfxapi glsl — the GLSL ES compiler's front: a shader's source
//! (1.00 or 3.00 es) preprocessed, parsed and checked, its log in Mesa's
//! form, and its interface (inputs, outputs, uniforms: struct uniforms
//! flattened to GL's names, each with its type, location and whether the
//! shader uses it; uniform blocks, their members laid out std140) copied
//! out where a link can keep it.
//!
//! One Scratch holds a compile (its tokens, nodes, symbols); the caller
//! keeps it and runs one compile in it at a time. A shader keeps only its
//! source: a link compiles its shaders again.
//!
//! Allocation-free: the Scratch's fixed tables.

const std = @import("std");
pub const lex = @import("lex.sig");
pub const pp = @import("pp.sig");
pub const parse = @import("parse.sig");
pub const sema = @import("sema.sig");
pub const gen = @import("gen.sig");

pub const Type = sema.Type;
pub const Base = sema.Base;
pub const Stage = sema.Stage;
pub const Q = parse.Q;

pub const MAX_SOURCE = 512 * 1024;
pub const MAX_TOKENS = 65536;
pub const MAX_WORK = 16384;
pub const MAX_NODES = 65536;
pub const LOG_BYTES = 8192;

pub const Scratch = struct {
    clean: [MAX_SOURCE]u8 = undefined,
    toks: [MAX_TOKENS]lex.Token = undefined,
    work: [MAX_WORK]lex.Token = undefined,
    nodes: [MAX_NODES]parse.Node = undefined,
    logbuf: [LOG_BYTES]u8 = undefined,
    log: pp.Log = undefined,
    pre: pp.Pp = undefined,
    parser: parse.Parser = undefined,
    checker: sema.Checker = undefined,
    root: u32 = 0,
    stage: Stage = .vertex,
    /// the code generator's tables
    gen: gen.Store = undefined,

    /// Compiles `src` as `stage`: whether it is a good shader. The log
    /// (log.text()) says what is wrong; after a good compile the checker
    /// holds the shader (its interface, its typed tree).
    pub fn compile(s: *Scratch, src: []const u8, stage: Stage) bool {
        s.log = .{ .buf = &s.logbuf };
        s.stage = stage;
        s.root = 0;
        if (src.len > s.clean.len) {
            s.log.err(0, "the shader is too long ({d} bytes at most)", .{s.clean.len});
            return false;
        }
        s.pre = .{ .log = &s.log, .out = &s.toks, .work = &s.work, .fragment = stage == .fragment };
        s.pre.run(src, s.clean[0..src.len]);
        if (s.log.errors != 0) return false;
        s.parser = .{ .toks = s.toks[0..s.pre.n], .nodes = &s.nodes, .log = &s.log, .version = s.pre.version };
        const root = s.parser.run();
        if (root == 0) {
            s.log.err(0, "the shader is too long ({d} nodes at most)", .{s.nodes.len});
            return false;
        }
        if (s.log.errors != 0) return false;
        s.checker = .{ .p = &s.parser, .log = &s.log, .stage = stage, .version = s.pre.version, .ext = s.pre.ext };
        s.checker.run(root);
        if (s.log.errors != 0) return false;
        s.root = root;
        return true;
    }

    pub fn logText(s: *const Scratch) []const u8 {
        return s.log.text();
    }

    /// The good compile's interface, into `out`; false when it does not
    /// fit (`out` says why in its overflow).
    pub fn interface(s: *Scratch, out: *Iface) bool {
        const c = &s.checker;
        out.* = .{ .stage = s.stage, .version = s.pre.version, .has_main = c.has_main, .frag_color = c.uses_frag_color, .frag_data = c.uses_frag_data, .point_size = c.uses_point_size, .point_coord = c.uses_point_coord, .frag_depth = c.uses_frag_depth, .front_facing = c.uses_front_facing };
        for (c.inputs[0..c.ninputs]) |v| out.add(v, .input, c.syms[v.sym].used, c);
        for (c.outputs[0..c.noutputs]) |v| out.add(v, .output, c.syms[v.sym].used, c);
        for (c.uniforms[0..c.nuniforms]) |v| {
            if (v.block == 0) out.add(v, .uniform, c.syms[v.sym].used, c);
        }
        for (c.blocks[0..c.nblocks]) |b| out.addBlock(b, c);
        return !out.overflow;
    }
};

pub const MAX_IVARS = 512;
pub const IFACE_NAMES = 16384;

pub const IKind = enum(u8) { input, output, uniform };

/// A variable of a compiled shader's interface. A struct uniform is its
/// members ("s.m", "s[1].m"), each a variable here; an array keeps its
/// length in the type.
pub const IVar = struct {
    kind: IKind,
    ty: Type,
    q: u16,
    loc: i32,
    used: bool,
    name_at: u16,
    name_len: u16,
    /// a uniform block's member: the block's index + 1 (0: none), and its
    /// std140 place: its (first element's) byte offset in the block, an
    /// array's stride, a matrix's column (row-major: row) stride
    block: u8 = 0,
    offset: u32 = 0,
    array_stride: u32 = 0,
    matrix_stride: u32 = 0,
    row_major: bool = false,
};

/// A uniform block of a compiled shader: its name, its instance's name's
/// length (0: anonymous; its members' names start with the instance's),
/// its std140 size, whether the shader uses it (all its members active).
pub const IBlock = struct {
    name_at: u16,
    name_len: u16,
    inst_len: u16 = 0,
    size: u32 = 0,
    used: bool = false,
};

pub const Iface = struct {
    stage: Stage = .vertex,
    version: u32 = 100,
    has_main: bool = false,
    /// 1.00 fragment shaders: gl_FragColor or gl_FragData written
    frag_color: bool = false,
    frag_data: bool = false,
    /// gl_PointSize, gl_PointCoord, gl_FragDepth used
    point_size: bool = false,
    point_coord: bool = false,
    frag_depth: bool = false,
    /// gl_FrontFacing read
    front_facing: bool = false,
    vars: [MAX_IVARS]IVar = undefined,
    n: usize = 0,
    blocks: [sema.MAX_BLOCKS]IBlock = undefined,
    nblocks: usize = 0,
    names: [IFACE_NAMES]u8 = undefined,
    nnames: usize = 0,
    overflow: bool = false,

    pub fn name(f: *const Iface, v: IVar) []const u8 {
        return f.names[v.name_at..][0..v.name_len];
    }

    fn put(f: *Iface, parts: []const []const u8) ?struct { at: u16, len: u16 } {
        const at = f.nnames;
        for (parts) |p| {
            if (f.nnames + p.len > f.names.len) {
                f.overflow = true;
                return null;
            }
            @memcpy(f.names[f.nnames..][0..p.len], p);
            f.nnames += p.len;
        }
        return .{ .at = @intCast(at), .len = @intCast(f.nnames - at) };
    }

    fn push(f: *Iface, v: IVar) void {
        if (f.n == f.vars.len) {
            f.overflow = true;
            return;
        }
        f.vars[f.n] = v;
        f.n += 1;
    }

    fn add(f: *Iface, v: sema.Var, kind: IKind, used: bool, c: *const sema.Checker) void {
        f.leaf(v.name, &.{}, v.ty, v.q, v.loc, kind, used, c, 0);
    }

    pub fn blockName(f: *const Iface, b: IBlock) []const u8 {
        return f.names[b.name_at..][0..b.name_len];
    }

    /// A uniform block: its members' leaves (named as the code names them:
    /// "inst.m", or an anonymous block's "m"), each with its std140 place.
    fn addBlock(f: *Iface, b: sema.Block, c: *const sema.Checker) void {
        if (f.nblocks == f.blocks.len) {
            f.overflow = true;
            return;
        }
        const nm = f.put(&.{b.name}) orelse return;
        var used = false;
        for (c.uniforms[b.first..][0..b.n]) |v| used = used or c.syms[v.sym].used;
        const bi = f.nblocks;
        f.nblocks += 1;
        const fields = c.structFields(.{ .base = .structure, .strukt = b.strukt });
        var cur: u32 = 0;
        for (fields) |fd| {
            const rm = switch (fd.layout) {
                .block => b.row_major,
                .row_major => true,
                .column_major => false,
            };
            cur = std.mem.alignForward(u32, cur, std140Align(fd.ty));
            if (b.instance.len > 0)
                f.blockLeaf(b.instance, &.{ ".", fd.name }, fd.ty, rm, cur, bi, used, c, 0)
            else
                f.blockLeaf(fd.name, &.{}, fd.ty, rm, cur, bi, used, c, 0);
            cur += std140Size(fd.ty, rm, c);
        }
        f.blocks[bi] = .{ .name_at = nm.at, .name_len = nm.len, .inst_len = @intCast(b.instance.len), .size = std.mem.alignForward(u32, cur, 16), .used = used };
    }

    /// A block member at byte `at`: a leaf, or a struct's members (each
    /// element of an array of structs), std140.
    fn blockLeaf(f: *Iface, base: []const u8, parts: []const []const u8, t: Type, rm: bool, at: u32, bi: usize, used: bool, c: *const sema.Checker, depth: u32) void {
        if (depth > 8) return;
        var all: [20][]const u8 = undefined;
        const np = @min(parts.len, all.len - 4);
        all[0] = base;
        @memcpy(all[1..][0..np], parts[0..np]);
        if (t.base != .structure) {
            const nm = f.put(all[0 .. 1 + np]) orelse return;
            const e = t.elem();
            f.push(.{
                .kind = .uniform,
                .ty = t,
                .q = Q.uniform,
                .loc = -1,
                .used = used,
                .name_at = nm.at,
                .name_len = nm.len,
                .block = @intCast(bi + 1),
                .offset = at,
                .array_stride = if (t.array != 0) std140Size(t, rm, c) / t.array else 0,
                .matrix_stride = if (e.matrix()) 16 else 0,
                .row_major = rm and e.matrix(),
            });
            return;
        }
        const n_el: u32 = if (t.array != 0) t.array else 1;
        const esize = std140Size(t.elem(), rm, c);
        for (0..n_el) |e| {
            var idx: [12]u8 = undefined;
            const istr = if (t.array != 0) (std.fmt.bufPrint(&idx, "[{d}]", .{e}) catch return) else "";
            var cur: u32 = 0;
            for (c.structFields(t)) |fd| {
                const frm = switch (fd.layout) {
                    .block => rm,
                    .row_major => true,
                    .column_major => false,
                };
                cur = std.mem.alignForward(u32, cur, std140Align(fd.ty));
                all[1 + np] = istr;
                all[2 + np] = ".";
                all[3 + np] = fd.name;
                f.blockLeaf(base, all[1 .. 4 + np], fd.ty, frm, at + @as(u32, @intCast(e)) * esize + cur, bi, used, c, depth + 1);
                cur += std140Size(fd.ty, frm, c);
            }
        }
    }

    /// `prefix ++ parts` named variable(s) of type `t`: a leaf, or a
    /// struct's members (each element of an array of structs).
    fn leaf(f: *Iface, base: []const u8, parts: []const []const u8, t: Type, q: u16, loc: i32, kind: IKind, used: bool, c: *const sema.Checker, depth: u32) void {
        if (depth > 8) return;
        var all: [20][]const u8 = undefined;
        const np = @min(parts.len, all.len - 4);
        all[0] = base;
        @memcpy(all[1..][0..np], parts[0..np]);
        if (t.base != .structure) {
            const nm = f.put(all[0 .. 1 + np]) orelse return;
            f.push(.{ .kind = kind, .ty = t, .q = q, .loc = loc, .used = used, .name_at = nm.at, .name_len = nm.len });
            return;
        }
        const n_el: u32 = if (t.array != 0) t.array else 1;
        for (0..n_el) |e| {
            var idx: [12]u8 = undefined;
            const istr = if (t.array != 0) (std.fmt.bufPrint(&idx, "[{d}]", .{e}) catch return) else "";
            for (c.structFields(t)) |fd| {
                all[1 + np] = istr;
                all[2 + np] = ".";
                all[3 + np] = fd.name;
                f.leaf(base, all[1 .. 4 + np], fd.ty, q, loc, kind, used, c, depth + 1);
            }
        }
    }
};

// ── std140 (GL ES 3.0's 2.12.6.4) ──────────────────────────────────────────

/// A type's base alignment: a scalar's 4, a vec2's 8, a vec3's and a
/// vec4's 16; an array's, a matrix's and a struct's a vec4's (16).
pub fn std140Align(t: Type) u32 {
    if (t.array != 0 or t.base == .structure or t.matrix()) return 16;
    return switch (t.rows) {
        1 => 4,
        2 => 8,
        else => 16,
    };
}

/// A type's size: a scalar or vector's components; a matrix's columns
/// (row-major: rows) of a vec4 each; an array's elements, each rounded up
/// to a vec4; a struct's members, their alignments kept, rounded up to a
/// vec4.
pub fn std140Size(t: Type, row_major: bool, c: *const sema.Checker) u32 {
    const e = t.elem();
    const one: u32 = if (e.base == .structure) blk: {
        var cur: u32 = 0;
        for (c.structFields(e)) |fd| {
            const rm = switch (fd.layout) {
                .block => row_major,
                .row_major => true,
                .column_major => false,
            };
            cur = std.mem.alignForward(u32, cur, std140Align(fd.ty));
            cur += std140Size(fd.ty, rm, c);
        }
        break :blk std.mem.alignForward(u32, cur, 16);
    } else if (e.matrix())
        @as(u32, if (row_major) e.rows else e.cols) * 16
    else if (t.array != 0)
        16
    else
        @as(u32, e.rows) * 4;
    return if (t.array != 0) one * t.array else one;
}

// ── GL's names of types ────────────────────────────────────────────────────

/// The GL enum of a (non-array) type: GL_FLOAT_VEC4, GL_SAMPLER_2D ...
pub fn glType(t: Type) u32 {
    const e = t.elem();
    return switch (e.base) {
        .float => if (e.cols > 1) switch (@as(u32, e.cols) * 8 + e.rows) {
            2 * 8 + 2 => 0x8B5A,
            3 * 8 + 3 => 0x8B5B,
            4 * 8 + 4 => 0x8B5C,
            2 * 8 + 3 => 0x8B65,
            2 * 8 + 4 => 0x8B66,
            3 * 8 + 2 => 0x8B67,
            3 * 8 + 4 => 0x8B68,
            4 * 8 + 2 => 0x8B69,
            4 * 8 + 3 => 0x8B6A,
            else => 0,
        } else switch (e.rows) {
            1 => 0x1406,
            else => 0x8B50 + @as(u32, e.rows) - 2,
        },
        .int => if (e.rows == 1) 0x1404 else 0x8B53 + @as(u32, e.rows) - 2,
        .uint => if (e.rows == 1) 0x1405 else 0x8DC6 + @as(u32, e.rows) - 2,
        .bool => if (e.rows == 1) 0x8B56 else 0x8B57 + @as(u32, e.rows) - 2,
        .sampler2D => 0x8B5E,
        .sampler3D => 0x8B5F,
        .samplerCube => 0x8B60,
        .sampler2DShadow => 0x8B62,
        .sampler2DArray => 0x8DC1,
        .sampler2DArrayShadow => 0x8DC4,
        .samplerCubeShadow => 0x8DC5,
        .isampler2D => 0x8DCA,
        .isampler3D => 0x8DCB,
        .isamplerCube => 0x8DCC,
        .isampler2DArray => 0x8DCF,
        .usampler2D => 0x8DD2,
        .usampler3D => 0x8DD3,
        .usamplerCube => 0x8DD4,
        .usampler2DArray => 0x8DD7,
        .samplerExternalOES => 0x8D66,
        else => 0,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

var t_scratch: Scratch = .{};
var t_iface: Iface = .{};

test "glsl: a compile and its interface, struct uniforms flattened" {
    const vs =
        \\#version 300 es
        \\struct Light { vec3 dir; vec4 color; };
        \\uniform Light uLights[2];
        \\uniform mat4 uMvp;
        \\uniform float uUnused;
        \\layout(location = 3) in vec3 aPos;
        \\in vec3 aNormal;
        \\out vec4 vColor;
        \\void main() {
        \\    float d = max(dot(aNormal, uLights[1].dir), 0.0);
        \\    vColor = uLights[0].color * d;
        \\    gl_Position = uMvp * vec4(aPos, 1.0);
        \\}
    ;
    try std.testing.expect(t_scratch.compile(vs, .vertex));
    try std.testing.expect(t_scratch.interface(&t_iface));
    try std.testing.expectEqual(@as(usize, 2 + 1 + 4 + 1 + 1), t_iface.n);
    var names: [16][]const u8 = undefined;
    for (t_iface.vars[0..t_iface.n], 0..) |v, i| names[i] = t_iface.name(v);
    try std.testing.expectEqualStrings("aPos", names[0]);
    try std.testing.expectEqual(@as(i32, 3), t_iface.vars[0].loc);
    try std.testing.expectEqualStrings("vColor", names[2]);
    try std.testing.expectEqualStrings("uLights[0].dir", names[3]);
    try std.testing.expectEqualStrings("uLights[1].color", names[6]);
    try std.testing.expectEqualStrings("uUnused", names[8]);
    try std.testing.expect(!t_iface.vars[8].used);
    try std.testing.expect(t_iface.vars[7].used);
    try std.testing.expectEqual(@as(u32, 0x8B5C), glType(t_iface.vars[7].ty));
    try std.testing.expectEqual(@as(u32, 0x8B52), glType(t_iface.vars[4].ty));
    // a bad one: its log
    try std.testing.expect(!t_scratch.compile("#version 300 es\nvoid main() { gl_Position = 1.0; }", .vertex));
    try std.testing.expect(std.mem.indexOf(u8, t_scratch.logText(), "0:2: error: cannot assign float to vec4") != null);
}
