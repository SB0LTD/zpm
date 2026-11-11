//! @zpm/gfxapi glsl/sema — GLSL ES's rules on the AST (1.00 and 3.00):
//! every expression's type, scopes, structs, arrays, swizzles,
//! constructors, operators (no implicit conversions: ES has none),
//! built-in variables and functions (a table of signatures whose genType
//! patterns bind a size per call), l-values, qualifiers by stage and
//! version, default precision in fragment shaders, constant integers (for
//! array sizes). What it gives a link: the shader's interface (its
//! inputs, outputs and uniforms, with their types and locations).
//!
//! Allocation-free: fixed tables in the Checker, which the caller keeps.

const std = @import("std");
const lex = @import("lex.sig");
const pp = @import("pp.sig");
const parse = @import("parse.sig");
const Kw = lex.Kw;
const Kind = lex.Kind;
const N = parse.N;
const Q = parse.Q;
const Node = parse.Node;

pub const Base = enum(u5) {
    void,
    bool,
    int,
    uint,
    float,
    sampler2D,
    sampler3D,
    samplerCube,
    sampler2DShadow,
    samplerCubeShadow,
    sampler2DArray,
    sampler2DArrayShadow,
    isampler2D,
    isampler3D,
    isamplerCube,
    isampler2DArray,
    usampler2D,
    usampler3D,
    usamplerCube,
    usampler2DArray,
    samplerExternalOES,
    structure,
    /// a type already found wrong (no more errors from it)
    err,
};

/// A type in 32 bits: base, columns (matrices), rows (a vector's size),
/// struct, array length (0: not an array).
pub const Type = packed struct(u32) {
    base: Base = .void,
    cols: u3 = 1,
    rows: u3 = 1,
    strukt: u8 = 0,
    array: u13 = 0,

    pub fn eq(a: Type, b: Type) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
    pub fn bits(t: Type) u32 {
        return @bitCast(t);
    }
    pub fn of(b: u32) Type {
        return @bitCast(b);
    }
    pub fn isErr(t: Type) bool {
        return t.base == .err;
    }
    pub fn numeric(t: Type) bool {
        return t.array == 0 and (t.base == .int or t.base == .uint or t.base == .float);
    }
    pub fn integer(t: Type) bool {
        return t.array == 0 and (t.base == .int or t.base == .uint);
    }
    pub fn scalar(t: Type) bool {
        return t.array == 0 and t.cols == 1 and t.rows == 1 and @backingInt(t.base) <= @backingInt(Base.float) and t.base != .void;
    }
    pub fn vector(t: Type) bool {
        return t.array == 0 and t.cols == 1 and t.rows > 1;
    }
    pub fn matrix(t: Type) bool {
        return t.array == 0 and t.cols > 1;
    }
    pub fn sampler(t: Type) bool {
        return @backingInt(t.base) >= @backingInt(Base.sampler2D) and @backingInt(t.base) <= @backingInt(Base.samplerExternalOES);
    }
    /// components of a scalar, vector or matrix
    pub fn comps(t: Type) u32 {
        return @as(u32, t.cols) * t.rows;
    }
    pub fn elem(t: Type) Type {
        var e = t;
        e.array = 0;
        return e;
    }
};

pub fn scalarT(b: Base) Type {
    return .{ .base = b };
}
pub fn vecT(b: Base, n: u32) Type {
    return .{ .base = b, .rows = @intCast(n) };
}
pub fn matT(c: u32, rr: u32) Type {
    return .{ .base = .float, .cols = @intCast(c), .rows = @intCast(rr) };
}
pub const ERR = Type{ .base = .err };
pub const BOOL = scalarT(.bool);
pub const INT = scalarT(.int);
pub const FLOAT = scalarT(.float);

/// A type keyword's type.
pub fn typeOfKw(kw: Kw) ?Type {
    return switch (kw) {
        .void => scalarT(.void),
        .bool => BOOL,
        .int => INT,
        .uint => scalarT(.uint),
        .float => FLOAT,
        .vec2 => vecT(.float, 2),
        .vec3 => vecT(.float, 3),
        .vec4 => vecT(.float, 4),
        .bvec2 => vecT(.bool, 2),
        .bvec3 => vecT(.bool, 3),
        .bvec4 => vecT(.bool, 4),
        .ivec2 => vecT(.int, 2),
        .ivec3 => vecT(.int, 3),
        .ivec4 => vecT(.int, 4),
        .uvec2 => vecT(.uint, 2),
        .uvec3 => vecT(.uint, 3),
        .uvec4 => vecT(.uint, 4),
        .mat2, .mat2x2 => matT(2, 2),
        .mat3, .mat3x3 => matT(3, 3),
        .mat4, .mat4x4 => matT(4, 4),
        .mat2x3 => matT(2, 3),
        .mat2x4 => matT(2, 4),
        .mat3x2 => matT(3, 2),
        .mat3x4 => matT(3, 4),
        .mat4x2 => matT(4, 2),
        .mat4x3 => matT(4, 3),
        .sampler2D => scalarT(.sampler2D),
        .sampler3D => scalarT(.sampler3D),
        .samplerCube => scalarT(.samplerCube),
        .sampler2DShadow => scalarT(.sampler2DShadow),
        .samplerCubeShadow => scalarT(.samplerCubeShadow),
        .sampler2DArray => scalarT(.sampler2DArray),
        .sampler2DArrayShadow => scalarT(.sampler2DArrayShadow),
        .isampler2D => scalarT(.isampler2D),
        .isampler3D => scalarT(.isampler3D),
        .isamplerCube => scalarT(.isamplerCube),
        .isampler2DArray => scalarT(.isampler2DArray),
        .usampler2D => scalarT(.usampler2D),
        .usampler3D => scalarT(.usampler3D),
        .usamplerCube => scalarT(.usamplerCube),
        .usampler2DArray => scalarT(.usampler2DArray),
        .samplerExternalOES => scalarT(.samplerExternalOES),
        else => null,
    };
}

pub const Stage = enum { vertex, fragment };

// ── Built-in functions ─────────────────────────────────────────────────────
//
// One line each: [flags:] name return args... Patterns: F I U B (genType:
// scalar or vector, one size per call), f i u b (scalars), VF VI VU VB
// (vectors, one size), v2..v4 iv2.. uv2.. (fixed), M (a matrix), MS (a
// square one), MT (M transposed), gS2 gS3 gSC gSA (samplers of any kind:
// float, int, uint, bound per call) and gv4 (that kind's vec4), s2 sC
// s2S sCS s2AS sE (fixed samplers), oF (an out genType). Flags: 3 (3.00
// only), 1 (1.00 only), V (vertex only in 1.00), D (derivatives: fragment
// shaders; 1.00 with GL_OES_standard_derivatives), L (1.00 lod:
// GL_EXT_shader_texture_lod in fragment shaders).

const builtin_text =
    \\radians F F
    \\degrees F F
    \\sin F F
    \\cos F F
    \\tan F F
    \\asin F F
    \\acos F F
    \\atan F F F
    \\atan F F
    \\3:sinh F F
    \\3:cosh F F
    \\3:tanh F F
    \\3:asinh F F
    \\3:acosh F F
    \\3:atanh F F
    \\pow F F F
    \\exp F F
    \\log F F
    \\exp2 F F
    \\log2 F F
    \\sqrt F F
    \\inversesqrt F F
    \\abs F F
    \\3:abs I I
    \\sign F F
    \\3:sign I I
    \\floor F F
    \\3:trunc F F
    \\3:round F F
    \\3:roundEven F F
    \\ceil F F
    \\fract F F
    \\mod F F F
    \\mod F F f
    \\3:modf F F oF
    \\min F F F
    \\min F F f
    \\3:min I I I
    \\3:min I I i
    \\3:min U U U
    \\3:min U U u
    \\max F F F
    \\max F F f
    \\3:max I I I
    \\3:max I I i
    \\3:max U U U
    \\3:max U U u
    \\clamp F F F F
    \\clamp F F f f
    \\3:clamp I I I I
    \\3:clamp I I i i
    \\3:clamp U U U U
    \\3:clamp U U u u
    \\mix F F F F
    \\mix F F F f
    \\3:mix F F F B
    \\step F F F
    \\step F f F
    \\smoothstep F F F F
    \\smoothstep F f f F
    \\3:isnan B F
    \\3:isinf B F
    \\3:floatBitsToInt I F
    \\3:floatBitsToUint U F
    \\3:intBitsToFloat F I
    \\3:uintBitsToFloat F U
    \\3:packSnorm2x16 u v2
    \\3:unpackSnorm2x16 v2 u
    \\3:packUnorm2x16 u v2
    \\3:unpackUnorm2x16 v2 u
    \\3:packHalf2x16 u v2
    \\3:unpackHalf2x16 v2 u
    \\length f F
    \\distance f F F
    \\dot f F F
    \\cross v3 v3 v3
    \\normalize F F
    \\faceforward F F F F
    \\reflect F F F
    \\refract F F F f
    \\matrixCompMult M M M
    \\3:transpose MT M
    \\3:determinant f MS
    \\3:inverse MS MS
    \\lessThan VB VF VF
    \\lessThan VB VI VI
    \\3:lessThan VB VU VU
    \\lessThanEqual VB VF VF
    \\lessThanEqual VB VI VI
    \\3:lessThanEqual VB VU VU
    \\greaterThan VB VF VF
    \\greaterThan VB VI VI
    \\3:greaterThan VB VU VU
    \\greaterThanEqual VB VF VF
    \\greaterThanEqual VB VI VI
    \\3:greaterThanEqual VB VU VU
    \\equal VB VF VF
    \\equal VB VI VI
    \\3:equal VB VU VU
    \\equal VB VB VB
    \\notEqual VB VF VF
    \\notEqual VB VI VI
    \\3:notEqual VB VU VU
    \\notEqual VB VB VB
    \\any b VB
    \\all b VB
    \\not VB VB
    \\3:textureSize iv2 gS2 i
    \\3:textureSize iv3 gS3 i
    \\3:textureSize iv2 gSC i
    \\3:textureSize iv3 gSA i
    \\3:textureSize iv2 s2S i
    \\3:textureSize iv2 sCS i
    \\3:textureSize iv3 s2AS i
    \\3:textureSize iv2 sE i
    \\3:texture gv4 gS2 v2
    \\3:texture gv4 gS2 v2 f
    \\3:texture gv4 gS3 v3
    \\3:texture gv4 gS3 v3 f
    \\3:texture gv4 gSC v3
    \\3:texture gv4 gSC v3 f
    \\3:texture gv4 gSA v3
    \\3:texture gv4 gSA v3 f
    \\3:texture f s2S v3
    \\3:texture f s2S v3 f
    \\3:texture f sCS v4
    \\3:texture f sCS v4 f
    \\3:texture f s2AS v4
    \\3:texture v4 sE v2
    \\3:textureProj gv4 gS2 v3
    \\3:textureProj gv4 gS2 v3 f
    \\3:textureProj gv4 gS2 v4
    \\3:textureProj gv4 gS2 v4 f
    \\3:textureProj gv4 gS3 v4
    \\3:textureProj gv4 gS3 v4 f
    \\3:textureProj f s2S v4
    \\3:textureProj f s2S v4 f
    \\3:textureProj v4 sE v3
    \\3:textureProj v4 sE v4
    \\3:textureLod gv4 gS2 v2 f
    \\3:textureLod gv4 gS3 v3 f
    \\3:textureLod gv4 gSC v3 f
    \\3:textureLod gv4 gSA v3 f
    \\3:textureLod f s2S v3 f
    \\3:textureOffset gv4 gS2 v2 iv2
    \\3:textureOffset gv4 gS2 v2 iv2 f
    \\3:textureOffset gv4 gS3 v3 iv3
    \\3:textureOffset gv4 gS3 v3 iv3 f
    \\3:textureOffset gv4 gSA v3 iv2
    \\3:textureOffset gv4 gSA v3 iv2 f
    \\3:textureOffset f s2S v3 iv2
    \\3:textureOffset f s2S v3 iv2 f
    \\3:texelFetch gv4 gS2 iv2 i
    \\3:texelFetch gv4 gS3 iv3 i
    \\3:texelFetch gv4 gSA iv3 i
    \\3:texelFetch v4 sE iv2 i
    \\3:texelFetchOffset gv4 gS2 iv2 i iv2
    \\3:texelFetchOffset gv4 gS3 iv3 i iv3
    \\3:texelFetchOffset gv4 gSA iv3 i iv2
    \\3:textureProjOffset gv4 gS2 v3 iv2
    \\3:textureProjOffset gv4 gS2 v4 iv2
    \\3:textureProjOffset gv4 gS3 v4 iv3
    \\3:textureLodOffset gv4 gS2 v2 f iv2
    \\3:textureLodOffset gv4 gS3 v3 f iv3
    \\3:textureLodOffset gv4 gSA v3 f iv2
    \\3:textureProjLod gv4 gS2 v3 f
    \\3:textureProjLod gv4 gS2 v4 f
    \\3:textureProjLod gv4 gS3 v4 f
    \\3:textureGrad gv4 gS2 v2 v2 v2
    \\3:textureGrad gv4 gS3 v3 v3 v3
    \\3:textureGrad gv4 gSC v3 v3 v3
    \\3:textureGrad gv4 gSA v3 v2 v2
    \\3:textureGrad f s2S v3 v2 v2
    \\3:textureGradOffset gv4 gS2 v2 v2 v2 iv2
    \\3:textureGradOffset gv4 gSA v3 v2 v2 iv2
    \\3:textureProjGrad gv4 gS2 v3 v2 v2
    \\3:textureProjGrad gv4 gS2 v4 v2 v2
    \\1:texture2D v4 s2 v2
    \\1:texture2D v4 s2 v2 f
    \\1:texture2D v4 sE v2
    \\1:texture2DProj v4 s2 v3
    \\1:texture2DProj v4 s2 v3 f
    \\1:texture2DProj v4 s2 v4
    \\1:texture2DProj v4 s2 v4 f
    \\1:texture2DProj v4 sE v3
    \\1:texture2DProj v4 sE v4
    \\1:textureCube v4 sC v3
    \\1:textureCube v4 sC v3 f
    \\1V:texture2DLod v4 s2 v2 f
    \\1V:texture2DProjLod v4 s2 v3 f
    \\1V:texture2DProjLod v4 s2 v4 f
    \\1V:textureCubeLod v4 sC v3 f
    \\1L:texture2DLodEXT v4 s2 v2 f
    \\1L:texture2DProjLodEXT v4 s2 v3 f
    \\1L:texture2DProjLodEXT v4 s2 v4 f
    \\1L:textureCubeLodEXT v4 sC v3 f
    \\1L:texture2DGradEXT v4 s2 v2 v2 v2
    \\1L:textureCubeGradEXT v4 sC v3 v3 v3
    \\D:dFdx F F
    \\D:dFdy F F
    \\D:fwidth F F
;

pub const Pat = enum(u8) { genF, genI, genU, genB, f, i, u, b, vF, vI, vU, vB, v2, v3, v4, iv2, iv3, iv4, uv2, uv3, uv4, m, ms, mt, gS2, gS3, gSC, gSA, gv4, s2, sC, s2S, sCS, s2AS, sE, out_genF };

pub const Builtin = struct {
    name: []const u8,
    ret: Pat,
    args: [6]Pat = undefined,
    nargs: u8 = 0,
    v300: bool = false,
    v100: bool = false,
    vertex_only_100: bool = false,
    deriv: bool = false,
    lod_ext: bool = false,
};

fn patOf(s: []const u8) Pat {
    const map = .{
        .{ "F", Pat.genF },      .{ "I", Pat.genI },  .{ "U", Pat.genU },  .{ "B", Pat.genB },    .{ "f", Pat.f },
        .{ "i", Pat.i },         .{ "u", Pat.u },     .{ "b", Pat.b },     .{ "VF", Pat.vF },     .{ "VI", Pat.vI },
        .{ "VU", Pat.vU },       .{ "VB", Pat.vB },   .{ "v2", Pat.v2 },   .{ "v3", Pat.v3 },     .{ "v4", Pat.v4 },
        .{ "iv2", Pat.iv2 },     .{ "iv3", Pat.iv3 }, .{ "iv4", Pat.iv4 }, .{ "uv2", Pat.uv2 },   .{ "uv3", Pat.uv3 },
        .{ "uv4", Pat.uv4 },     .{ "M", Pat.m },     .{ "MS", Pat.ms },   .{ "MT", Pat.mt },     .{ "gS2", Pat.gS2 },
        .{ "gS3", Pat.gS3 },     .{ "gSC", Pat.gSC }, .{ "gSA", Pat.gSA }, .{ "gv4", Pat.gv4 },   .{ "s2", Pat.s2 },
        .{ "sC", Pat.sC },       .{ "s2S", Pat.s2S }, .{ "sCS", Pat.sCS }, .{ "s2AS", Pat.s2AS }, .{ "sE", Pat.sE },
        .{ "oF", Pat.out_genF },
    };
    inline for (map) |e| {
        if (std.mem.eql(u8, s, e[0])) return e[1];
    }
    @compileError("unknown builtin pattern");
}

pub const builtins: []const Builtin = blk: {
    @setEvalBranchQuota(400_000);
    var list: [256]Builtin = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, builtin_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var rest = line;
        var b = Builtin{ .name = "", .ret = .f };
        if (std.mem.indexOfScalar(u8, line, ':')) |c| {
            for (line[0..c]) |fl| switch (fl) {
                '3' => b.v300 = true,
                '1' => b.v100 = true,
                'V' => b.vertex_only_100 = true,
                'D' => b.deriv = true,
                'L' => b.lod_ext = true,
                else => @compileError("unknown builtin flag"),
            };
            rest = line[c + 1 ..];
        }
        var words = std.mem.tokenizeScalar(u8, rest, ' ');
        b.name = words.next().?;
        b.ret = patOf(words.next().?);
        while (words.next()) |w| {
            b.args[b.nargs] = patOf(w);
            b.nargs += 1;
        }
        list[n] = b;
        n += 1;
    }
    const final: [n]Builtin = list[0..n].*;
    break :blk &final;
};

/// What a call's patterns bound: a genType's size, a matrix's shape, a
/// sampler's kind.
const Binding = struct { n: ?u32 = null, cols: u32 = 0, rows: u32 = 0, g: ?Base = null };

fn samplerKind(b: Base, dims: enum { d2, d3, cube, array }) ?Base {
    return switch (dims) {
        .d2 => switch (b) {
            .sampler2D => .float,
            .isampler2D => .int,
            .usampler2D => .uint,
            else => null,
        },
        .d3 => switch (b) {
            .sampler3D => .float,
            .isampler3D => .int,
            .usampler3D => .uint,
            else => null,
        },
        .cube => switch (b) {
            .samplerCube => .float,
            .isamplerCube => .int,
            .usamplerCube => .uint,
            else => null,
        },
        .array => switch (b) {
            .sampler2DArray => .float,
            .isampler2DArray => .int,
            .usampler2DArray => .uint,
            else => null,
        },
    };
}

/// Whether argument type `t` fits pattern `p`, binding as it goes.
fn fits(p: Pat, t: Type, bnd: *Binding) bool {
    if (t.array != 0) return false;
    const gen = struct {
        fn f(bb: *Binding, tt: Type, base: Base, vectors_only: bool) bool {
            if (tt.base != base or tt.cols != 1) return false;
            if (vectors_only and tt.rows < 2) return false;
            if (bb.n) |n| return n == tt.rows;
            bb.n = tt.rows;
            return true;
        }
    }.f;
    const fixed = struct {
        fn f(tt: Type, want: Type) bool {
            return tt.eq(want);
        }
    }.f;
    return switch (p) {
        .genF, .out_genF => gen(bnd, t, .float, false),
        .genI => gen(bnd, t, .int, false),
        .genU => gen(bnd, t, .uint, false),
        .genB => gen(bnd, t, .bool, false),
        .vF => gen(bnd, t, .float, true),
        .vI => gen(bnd, t, .int, true),
        .vU => gen(bnd, t, .uint, true),
        .vB => gen(bnd, t, .bool, true),
        .f => fixed(t, FLOAT),
        .i => fixed(t, INT),
        .u => fixed(t, scalarT(.uint)),
        .b => fixed(t, BOOL),
        .v2 => fixed(t, vecT(.float, 2)),
        .v3 => fixed(t, vecT(.float, 3)),
        .v4 => fixed(t, vecT(.float, 4)),
        .iv2 => fixed(t, vecT(.int, 2)),
        .iv3 => fixed(t, vecT(.int, 3)),
        .iv4 => fixed(t, vecT(.int, 4)),
        .uv2 => fixed(t, vecT(.uint, 2)),
        .uv3 => fixed(t, vecT(.uint, 3)),
        .uv4 => fixed(t, vecT(.uint, 4)),
        .m, .ms => blk: {
            if (!t.matrix()) break :blk false;
            if (p == .ms and t.cols != t.rows) break :blk false;
            if (bnd.cols != 0) break :blk bnd.cols == t.cols and bnd.rows == t.rows;
            bnd.cols = t.cols;
            bnd.rows = t.rows;
            break :blk true;
        },
        .gS2, .gS3, .gSC, .gSA => blk: {
            const k = samplerKind(t.base, switch (p) {
                .gS2 => .d2,
                .gS3 => .d3,
                .gSC => .cube,
                else => .array,
            }) orelse break :blk false;
            if (bnd.g) |g| break :blk g == k;
            bnd.g = k;
            break :blk true;
        },
        .s2 => t.base == .sampler2D,
        .sC => t.base == .samplerCube,
        .s2S => t.base == .sampler2DShadow,
        .sCS => t.base == .samplerCubeShadow,
        .s2AS => t.base == .sampler2DArrayShadow,
        .sE => t.base == .samplerExternalOES,
        .mt, .gv4 => false,
    };
}

fn retOf(p: Pat, bnd: Binding) Type {
    const n = bnd.n orelse 1;
    return switch (p) {
        .genF, .vF, .out_genF => vecT(.float, n),
        .genI, .vI => vecT(.int, n),
        .genU, .vU => vecT(.uint, n),
        .genB, .vB => vecT(.bool, n),
        .f => FLOAT,
        .i => INT,
        .u => scalarT(.uint),
        .b => BOOL,
        .v2 => vecT(.float, 2),
        .v3 => vecT(.float, 3),
        .v4 => vecT(.float, 4),
        .iv2 => vecT(.int, 2),
        .iv3 => vecT(.int, 3),
        .iv4 => vecT(.int, 4),
        .uv2 => vecT(.uint, 2),
        .uv3 => vecT(.uint, 3),
        .uv4 => vecT(.uint, 4),
        .m, .ms => matT(bnd.cols, bnd.rows),
        .mt => matT(bnd.rows, bnd.cols),
        .gv4 => vecT(bnd.g orelse .float, 4),
        else => ERR,
    };
}

// ── Symbols ────────────────────────────────────────────────────────────────

pub const MAX_SYMS = 2048;
pub const MAX_STRUCTS = 128;
pub const MAX_FIELDS = 1024;
pub const MAX_PARAMS = 2048;
pub const MAX_IO = 64;
pub const MAX_UNIFORMS = 256;
/// uniform blocks a shader may declare (GL ES 3.0's MAX_VERTEX_UNIFORM_BLOCKS)
pub const MAX_BLOCKS = 12;
const MAX_DEPTH = 64;

pub const SymKind = enum(u8) { variable, function, strukt };

pub const Sym = struct {
    name: []const u8,
    kind: SymKind,
    ty: Type = ERR,
    q: u16 = 0,
    depth: u16 = 0,
    /// a built-in variable (gl_*): read only unless an output
    builtin: bool = false,
    /// a constant integer's value (array sizes, const ints)
    konst: ?i64 = null,
    /// functions: params[params .. params + nparams], defined or not
    params: u32 = 0,
    nparams: u8 = 0,
    defined: bool = false,
    loc: i32 = -1,
    /// named in an expression (a variable the shader uses: GL's "active")
    used: bool = false,
};

/// A struct's member; a uniform block's says its matrices' layout
/// (layout(row_major) or (column_major): else the block's).
pub const Field = struct { name: []const u8, ty: Type, layout: enum(u2) { block, row_major, column_major } = .block };

/// A uniform block (GLSL ES 3.00): its members are uniforms[first ..
/// first + n] (an instance's: the one struct uniform), laid out std140.
pub const Block = struct {
    name: []const u8,
    /// its instance's name ("": an anonymous block, its members global)
    instance: []const u8 = "",
    row_major: bool = false,
    first: u32 = 0,
    n: u32 = 0,
    line: u32 = 0,
    /// its members as a struct (structs[strukt]: their layouts)
    strukt: u8 = 0,
};
pub const Struct = struct { name: []const u8, first: u32, n: u32 };
pub const Param = struct { ty: Type, q: u16 };

/// A variable of the shader's interface.
pub const Var = struct {
    name: []const u8,
    ty: Type,
    q: u16,
    /// layout location, or -1
    loc: i32 = -1,
    line: u32 = 0,
    /// its symbol (syms[sym].used: whether the shader uses it)
    sym: u32 = 0,
    /// a uniform block's member: the block's index + 1 (0: none)
    block: u8 = 0,
};

pub const Checker = struct {
    p: *parse.Parser,
    log: *pp.Log,
    stage: Stage,
    version: u32,
    ext: pp.Extensions = .{},
    syms: [MAX_SYMS]Sym = undefined,
    nsyms: usize = 0,
    scopes: [MAX_DEPTH]usize = undefined,
    depth: usize = 0,
    structs: [MAX_STRUCTS]Struct = undefined,
    nstructs: usize = 1,
    fields: [MAX_FIELDS]Field = undefined,
    nfields: usize = 0,
    params: [MAX_PARAMS]Param = undefined,
    nparams: usize = 0,
    /// the interface
    inputs: [MAX_IO]Var = undefined,
    ninputs: usize = 0,
    outputs: [MAX_IO]Var = undefined,
    noutputs: usize = 0,
    uniforms: [MAX_UNIFORMS]Var = undefined,
    nuniforms: usize = 0,
    blocks: [MAX_BLOCKS]Block = undefined,
    nblocks: usize = 0,
    has_main: bool = false,
    /// the function being checked: its return type, loops and switches open
    ret: Type = ERR,
    loops: u32 = 0,
    switches: u32 = 0,
    /// fragment shaders: a default float precision (global `precision`)
    float_prec: bool = false,
    told_prec: bool = false,
    uses_frag_data: bool = false,
    uses_frag_color: bool = false,
    /// gl_PointSize (vertex), gl_PointCoord and gl_FragDepth (fragment)
    /// read or written
    uses_point_size: bool = false,
    uses_point_coord: bool = false,
    uses_frag_depth: bool = false,

    fn node(c: *Checker, i: u32) *Node {
        return &c.p.nodes[i];
    }
    fn tokText(c: *Checker, tok: u32) []const u8 {
        return c.p.toks[tok].text;
    }

    // ── Scopes ─────────────────────────────────────────────────────────────

    fn push(c: *Checker) void {
        if (c.depth == MAX_DEPTH) return;
        c.scopes[c.depth] = c.nsyms;
        c.depth += 1;
    }
    fn pop(c: *Checker) void {
        if (c.depth == 0) return;
        c.depth -= 1;
        c.nsyms = c.scopes[c.depth];
    }

    fn add(c: *Checker, s: Sym, line: u32) ?*Sym {
        // (a name declared twice in one scope; functions overload)
        const start = if (c.depth > 0) c.scopes[c.depth - 1] else 0;
        for (c.syms[start..c.nsyms]) |*o| {
            if (std.mem.eql(u8, o.name, s.name) and !(o.kind == .function and s.kind == .function)) {
                c.log.err(line, "`{s}` is already declared here", .{s.name});
                return null;
            }
        }
        if (c.nsyms == MAX_SYMS) {
            c.log.err(line, "too many names", .{});
            return null;
        }
        var x = s;
        x.depth = @intCast(c.depth);
        c.syms[c.nsyms] = x;
        c.nsyms += 1;
        return &c.syms[c.nsyms - 1];
    }

    fn find(c: *Checker, name: []const u8) ?*Sym {
        var i = c.nsyms;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, c.syms[i].name, name)) return &c.syms[i];
        }
        return null;
    }

    fn builtinVar(c: *Checker, name: []const u8, ty: Type, q: u16) void {
        _ = c.add(.{ .name = name, .kind = .variable, .ty = ty, .q = q, .builtin = true }, 0);
    }

    fn builtinConst(c: *Checker, name: []const u8, v: i64) void {
        _ = c.add(.{ .name = name, .kind = .variable, .ty = INT, .q = Q.@"const", .builtin = true, .konst = v }, 0);
    }

    // ── The shader ─────────────────────────────────────────────────────────

    /// Checks the tree under `root`; the log has what is wrong.
    pub fn run(c: *Checker, root: u32) void {
        c.push();
        if (c.stage == .vertex) {
            c.builtinVar("gl_Position", vecT(.float, 4), Q.out);
            c.builtinVar("gl_PointSize", FLOAT, Q.out);
            if (c.version >= 300) {
                c.builtinVar("gl_VertexID", INT, Q.in);
                c.builtinVar("gl_InstanceID", INT, Q.in);
            }
        } else {
            c.builtinVar("gl_FragCoord", vecT(.float, 4), Q.in);
            c.builtinVar("gl_FrontFacing", BOOL, Q.in);
            c.builtinVar("gl_PointCoord", vecT(.float, 2), Q.in);
            if (c.version >= 300) {
                c.builtinVar("gl_FragDepth", FLOAT, Q.out);
            } else {
                c.builtinVar("gl_FragColor", vecT(.float, 4), Q.out);
                var fd = vecT(.float, 4);
                fd.array = 4;
                c.builtinVar("gl_FragData", fd, Q.out);
            }
        }
        c.builtinConst("gl_MaxVertexAttribs", 16);
        c.builtinConst("gl_MaxVertexUniformVectors", 256);
        c.builtinConst("gl_MaxFragmentUniformVectors", 224);
        c.builtinConst("gl_MaxVertexTextureImageUnits", 16);
        c.builtinConst("gl_MaxCombinedTextureImageUnits", 32);
        c.builtinConst("gl_MaxTextureImageUnits", 16);
        c.builtinConst("gl_MaxDrawBuffers", 4);
        if (c.version >= 300) {
            c.builtinConst("gl_MaxVertexOutputVectors", 16);
            c.builtinConst("gl_MaxFragmentInputVectors", 15);
            c.builtinConst("gl_MinProgramTexelOffset", -8);
            c.builtinConst("gl_MaxProgramTexelOffset", 7);
        } else c.builtinConst("gl_MaxVaryingVectors", 15);
        // (a vertex shader's floats are highp by default; a fragment shader
        // must say)
        if (c.stage == .vertex) c.float_prec = true;
        c.push();
        var i = c.node(root).a;
        while (i != 0) : (i = c.node(i).next) c.external(i);
        // (several outputs the shader uses: each needs its location. One
        // unused does not count, as Mesa links them: glamor's GLES 3
        // glyphs declare color0 and color1 for dual-source blending and
        // write frag_color alone)
        if (c.stage == .fragment and c.version >= 300) {
            var active: usize = 0;
            for (c.outputs[0..c.noutputs]) |o| {
                if (c.syms[o.sym].used) active += 1;
            }
            if (active > 1) for (c.outputs[0..c.noutputs]) |o| {
                if (o.loc < 0 and c.syms[o.sym].used) c.log.err(o.line, "with several outputs, `{s}` needs a layout location", .{o.name});
            };
        }
        if (c.uses_frag_color and c.uses_frag_data) c.log.err(0, "gl_FragColor and gl_FragData both written", .{});
    }

    fn external(c: *Checker, i: u32) void {
        const nd = c.node(i);
        switch (nd.kind) {
            .precision => {
                const kw = c.p.toks[nd.tok].kw;
                if (kw == .float and c.depth <= 2) c.float_prec = true;
                if (kw != .float and kw != .int and !(typeOfKw(kw) orelse ERR).sampler()) c.log.err(nd.line, "precision is for float, int and sampler types", .{});
            },
            .decl => c.declaration(i, true),
            .func => c.function(i),
            .invariant => {
                const s = c.find(c.tokText(nd.tok));
                if (s == null or s.?.q & Q.out == 0 and s.?.q & Q.varying == 0) c.log.err(nd.line, "`invariant {s}`: not an output", .{c.tokText(nd.tok)});
            },
            .block_decl => c.blockDecl(i),
            else => {},
        }
    }

    // ── Types ──────────────────────────────────────────────────────────────

    /// A constant integer expression's value (array sizes), or null.
    pub fn constInt(c: *Checker, e: u32) ?i64 {
        if (e == 0) return null;
        const nd = c.node(e);
        return switch (nd.kind) {
            .int_lit, .uint_lit => nd.value,
            .bool_lit => nd.value,
            .ident => blk: {
                const s = c.find(c.tokText(nd.tok)) orelse break :blk null;
                break :blk s.konst;
            },
            .unary => blk: {
                const v = c.constInt(nd.a) orelse break :blk null;
                break :blk switch (@as(Kind, @fromBackingInt(@intCast(nd.op)))) {
                    .minus => -%v,
                    .plus => v,
                    .tilde => ~v,
                    .bang => @intFromBool(v == 0),
                    else => null,
                };
            },
            .binary => blk: {
                const a = c.constInt(nd.a) orelse break :blk null;
                const b = c.constInt(nd.b) orelse break :blk null;
                break :blk switch (@as(Kind, @fromBackingInt(@intCast(nd.op)))) {
                    .plus => a +% b,
                    .minus => a -% b,
                    .star => a *% b,
                    .slash => if (b == 0 or (b == -1 and a == std.math.minInt(i64))) null else @divTrunc(a, b),
                    .percent => if (b == 0 or b == -1) null else @rem(a, b),
                    .shl => a << @intCast(std.math.clamp(b, 0, 62)),
                    .shr => a >> @intCast(std.math.clamp(b, 0, 62)),
                    .amp => a & b,
                    .pipe => a | b,
                    .caret => a ^ b,
                    .lt => @intFromBool(a < b),
                    .gt => @intFromBool(a > b),
                    .le => @intFromBool(a <= b),
                    .ge => @intFromBool(a >= b),
                    .eq => @intFromBool(a == b),
                    .ne => @intFromBool(a != b),
                    .and_and => @intFromBool(a != 0 and b != 0),
                    .or_or => @intFromBool(a != 0 or b != 0),
                    else => null,
                };
            },
            .ternary => blk: {
                const cv = c.constInt(nd.a) orelse break :blk null;
                break :blk if (cv != 0) c.constInt(nd.b) else c.constInt(nd.c);
            },
            .call => blk: {
                // int(x), uint(x) of a constant
                if (nd.a != 0 and nd.b != 0 and c.node(nd.b).next == 0) {
                    const kw = c.p.toks[c.node(nd.a).tok].kw;
                    if (kw == .int or kw == .uint) break :blk c.constInt(nd.b);
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn arraySize(c: *Checker, e: u32, line: u32) u13 {
        _ = c.expr(e);
        const v = c.constInt(e) orelse {
            c.log.err(line, "an array size must be a constant integer", .{});
            return 1;
        };
        if (v <= 0 or v > 4096) {
            c.log.err(line, "array size {d} is out of range", .{v});
            return 1;
        }
        return @intCast(v);
    }

    /// A type_spec node's type (structs defined here declared too).
    fn typeSpec(c: *Checker, ts: u32) Type {
        const nd = c.node(ts);
        var t: Type = undefined;
        if (nd.a != 0) {
            t = c.structDef(nd.a);
        } else {
            const tok = c.p.toks[nd.tok];
            if (typeOfKw(tok.kw)) |x| {
                t = x;
                if (t.base == .samplerExternalOES and !c.ext.egl_image_external) c.log.err(nd.line, "samplerExternalOES needs GL_OES_EGL_image_external", .{});
            } else if (c.find(tok.text)) |s| {
                if (s.kind != .strukt) {
                    c.log.err(nd.line, "`{s}` is not a type", .{tok.text});
                    return ERR;
                }
                t = s.ty;
            } else {
                c.log.err(nd.line, "unknown type `{s}`", .{tok.text});
                return ERR;
            }
        }
        if (nd.b != 0) t.array = c.arraySize(nd.b, nd.line);
        nd.ty = t.bits();
        return t;
    }

    fn structDef(c: *Checker, sd: u32) Type {
        const nd = c.node(sd);
        if (c.nstructs == MAX_STRUCTS) {
            c.log.err(nd.line, "too many structs", .{});
            return ERR;
        }
        const id = c.nstructs;
        c.nstructs += 1;
        const name = if (nd.tok != 0) c.tokText(nd.tok) else "";
        c.structs[id] = .{ .name = name, .first = @intCast(c.nfields), .n = 0 };
        var m = nd.a;
        while (m != 0) : (m = c.node(m).next) {
            const md = c.node(m);
            const mt = c.typeSpec(md.a);
            if (mt.base == .void or mt.sampler()) c.log.err(md.line, "a struct member cannot be {s}", .{if (mt.base == .void) "void" else "a sampler"});
            var v = md.b;
            while (v != 0) : (v = c.node(v).next) {
                const vn = c.node(v);
                var ft = mt;
                if (vn.a != 0) ft.array = c.arraySize(vn.a, vn.line);
                const fname = c.tokText(vn.tok);
                for (c.fields[c.structs[id].first..c.nfields]) |f| {
                    if (std.mem.eql(u8, f.name, fname)) c.log.err(vn.line, "struct member `{s}` declared twice", .{fname});
                }
                if (c.nfields == MAX_FIELDS) {
                    c.log.err(vn.line, "too many struct members", .{});
                    break;
                }
                c.fields[c.nfields] = .{ .name = fname, .ty = ft, .layout = if (md.flags & Q.row_major != 0) .row_major else if (md.flags & Q.column_major != 0) .column_major else .block };
                c.nfields += 1;
                c.structs[id].n += 1;
            }
        }
        const t = Type{ .base = .structure, .strukt = @intCast(id) };
        if (name.len > 0) _ = c.add(.{ .name = name, .kind = .strukt, .ty = t }, nd.line);
        return t;
    }

    pub fn structFields(c: *const Checker, t: Type) []const Field {
        const s = c.structs[t.strukt];
        return c.fields[s.first..][0..s.n];
    }

    fn hasSampler(c: *const Checker, t: Type) bool {
        if (t.sampler()) return true;
        if (t.base != .structure) return false;
        for (c.structFields(t)) |f| {
            if (c.hasSampler(f.ty)) return true;
        }
        return false;
    }

    fn needPrecision(c: *Checker, t: Type, q: u16, line: u32) void {
        if (c.stage != .fragment or c.float_prec or q & Q.precision != 0 or c.told_prec) return;
        if (t.base == .float) {
            c.log.err(line, "no precision for float: a fragment shader needs `precision mediump float;` (or highp)", .{});
            c.told_prec = true;
        }
    }

    // ── Declarations ───────────────────────────────────────────────────────

    fn declaration(c: *Checker, d: u32, global: bool) void {
        const nd = c.node(d);
        const base_t = c.typeSpec(nd.a);
        const q = nd.flags;
        var v = nd.b;
        if (v == 0 and base_t.base != .structure) c.log.warn(nd.line, "a declaration that declares nothing", .{});
        while (v != 0) : (v = c.node(v).next) {
            const vn = c.node(v);
            const name = c.tokText(vn.tok);
            var t = base_t;
            if (vn.a != 0) {
                if (t.array != 0) c.log.err(vn.line, "arrays of arrays are not GLSL ES", .{});
                t.array = c.arraySize(vn.a, vn.line);
            }
            const unsized = vn.op == 1 or c.node(nd.a).op == 1;
            if (t.base == .void) {
                c.log.err(vn.line, "`{s}` cannot be void", .{name});
                t = ERR;
            }
            c.needPrecision(t, q, vn.line);
            if (std.mem.startsWith(u8, name, "gl_")) c.log.err(vn.line, "names beginning gl_ are reserved: {s}", .{name});
            if (std.mem.indexOf(u8, name, "__") != null and c.version >= 300) c.log.err(vn.line, "names with __ are reserved: {s}", .{name});
            if (vn.b != 0) {
                const it = c.expr(vn.b);
                if (unsized and it.array != 0 and it.elem().eq(t.elem())) t = it;
                if (!it.isErr() and !t.isErr() and !it.eq(t)) c.log.err(vn.line, "`{s}` is {s} but its initializer is {s}", .{ name, c.typeName(t), c.typeName(it) });
                if (q & (Q.uniform | Q.in | Q.out | Q.attribute | Q.varying) != 0) c.log.err(vn.line, "`{s}`: {s} variables take no initializer", .{ name, c.storageName(q) });
            } else if (q & Q.@"const" != 0) c.log.err(vn.line, "const `{s}` needs an initializer", .{name});
            if (unsized and t.array == 0) c.log.err(vn.line, "`{s}` needs an array size", .{name});
            if (c.hasSampler(t) and q & Q.uniform == 0) c.log.err(vn.line, "samplers can only be uniforms (or parameters): {s}", .{name});
            if (global) c.checkGlobal(name, t, q, vn);
            var s = Sym{ .name = name, .kind = .variable, .ty = t, .q = q, .loc = @as(i32, @intCast(vn.value)) - 1 };
            if (q & Q.@"const" != 0 and t.integer() and t.scalar()) s.konst = c.constInt(vn.b);
            if (q & Q.@"const" != 0 and t.eq(BOOL)) s.konst = c.constInt(vn.b);
            vn.ty = t.bits();
            _ = c.add(s, vn.line);
        }
    }

    /// A uniform block (GLSL ES 3.00): an instance's members are its
    /// struct uniform's ("inst.m"), an anonymous block's each a uniform
    /// of their own; the block notes them for its std140 layout.
    fn blockDecl(c: *Checker, i: u32) void {
        const nd = c.node(i);
        const bname = c.tokText(nd.tok);
        if (c.version < 300) return c.log.err(nd.line, "interface blocks are GLSL ES 3.00's: {s}", .{bname});
        if (nd.flags & Q.uniform == 0 or nd.flags & (Q.in | Q.out) != 0) return c.log.err(nd.line, "only uniform blocks are GLSL ES 3.00's: {s}", .{bname});
        if (std.mem.startsWith(u8, bname, "gl_")) return c.log.err(nd.line, "names beginning gl_ are reserved: {s}", .{bname});
        for (c.blocks[0..c.nblocks]) |b| {
            if (std.mem.eql(u8, b.name, bname)) return c.log.err(nd.line, "uniform block `{s}` declared twice", .{bname});
        }
        if (c.nblocks == MAX_BLOCKS) return c.log.err(nd.line, "too many uniform blocks ({d} at most)", .{MAX_BLOCKS});
        const st = c.structDef(nd.a);
        if (st.isErr()) return;
        nd.ty = st.bits();
        const bi = c.nblocks;
        c.blocks[bi] = .{ .name = bname, .row_major = nd.flags & Q.row_major != 0, .first = @intCast(c.nuniforms), .line = nd.line, .strukt = st.strukt };
        c.nblocks += 1;
        if (nd.b != 0) {
            const vn = c.node(nd.b);
            const name = c.tokText(vn.tok);
            if (vn.a != 0) return c.log.err(vn.line, "arrays of uniform blocks are not supported yet: {s}", .{name});
            c.blocks[bi].instance = name;
            c.blockVar(name, st, vn.line, bi);
            vn.ty = st.bits();
        } else {
            for (c.structFields(st)) |fd| c.blockVar(fd.name, fd.ty, nd.line, bi);
        }
        c.blocks[bi].n = @intCast(c.nuniforms - c.blocks[bi].first);
    }

    fn blockVar(c: *Checker, name: []const u8, t: Type, line: u32, bi: usize) void {
        if (std.mem.startsWith(u8, name, "gl_")) return c.log.err(line, "names beginning gl_ are reserved: {s}", .{name});
        if (c.nuniforms == MAX_UNIFORMS) return c.log.err(line, "too many uniforms", .{});
        const sym: u32 = @intCast(c.nsyms);
        _ = c.add(.{ .name = name, .kind = .variable, .ty = t, .q = Q.uniform }, line) orelse return;
        c.uniforms[c.nuniforms] = .{ .name = name, .ty = t, .q = Q.uniform, .line = line, .sym = sym, .block = @intCast(bi + 1) };
        c.nuniforms += 1;
    }

    fn storageName(c: *Checker, q: u16) []const u8 {
        _ = c;
        if (q & Q.uniform != 0) return "uniform";
        if (q & Q.attribute != 0) return "attribute";
        if (q & Q.varying != 0) return "varying";
        if (q & Q.in != 0) return "in";
        if (q & Q.out != 0) return "out";
        return "these";
    }

    /// A global's qualifiers by stage and version; the interface noted.
    fn checkGlobal(c: *Checker, name: []const u8, t: Type, q0: u16, vn: *Node) void {
        var q = q0;
        const v3 = c.version >= 300;
        if (!v3 and q & (Q.in | Q.out) != 0 and q & Q.attribute == 0) {
            c.log.err(vn.line, "`in` and `out` globals are GLSL ES 3.00's: use attribute or varying in 1.00", .{});
            return;
        }
        if (q & Q.attribute != 0 and c.stage != .vertex) c.log.err(vn.line, "attributes are for vertex shaders", .{});
        // 1.00's varying: an output of the vertex shader, an input of the fragment shader
        if (q & Q.varying != 0) q |= if (c.stage == .vertex) Q.out else Q.in;
        const loc: i32 = @as(i32, @intCast(vn.value)) - 1;
        if (loc >= 0 and !((c.stage == .vertex and q & Q.in != 0) or (c.stage == .fragment and q & Q.out != 0))) c.log.err(vn.line, "layout(location) is for vertex inputs and fragment outputs", .{});
        const v = Var{ .name = name, .ty = t, .q = q, .loc = loc, .line = vn.line, .sym = @intCast(c.nsyms) };
        if (q & Q.uniform != 0) {
            if (c.nuniforms < MAX_UNIFORMS) {
                c.uniforms[c.nuniforms] = v;
                c.nuniforms += 1;
            } else c.log.err(vn.line, "too many uniforms", .{});
            return;
        }
        if (q & (Q.in | Q.out) == 0) return;
        const is_in = q & Q.in != 0;
        const integer_t = t.base == .int or t.base == .uint;
        if (t.base == .bool or t.sampler()) c.log.err(vn.line, "`{s}`: {s} variables cannot be {s}", .{ name, c.storageName(q), c.typeName(t) });
        if (c.stage == .vertex and is_in) {
            if (t.array != 0 or t.base == .structure) c.log.err(vn.line, "vertex inputs cannot be arrays or structs: {s}", .{name});
        } else if (c.stage == .fragment and !is_in) {
            if (t.matrix() or t.base == .structure) c.log.err(vn.line, "fragment outputs cannot be matrices or structs: {s}", .{name});
        } else {
            // a varying
            if (integer_t and q & Q.flat == 0 and v3) c.log.err(vn.line, "integer varyings must be flat: {s}", .{name});
            if (!v3 and (integer_t or t.base == .structure)) c.log.err(vn.line, "1.00's varyings are floats: {s}", .{name});
        }
        if (is_in) {
            if (c.ninputs < MAX_IO) {
                c.inputs[c.ninputs] = v;
                c.ninputs += 1;
            }
        } else if (c.noutputs < MAX_IO) {
            c.outputs[c.noutputs] = v;
            c.noutputs += 1;
        }
    }

    // ── Functions ──────────────────────────────────────────────────────────

    fn function(c: *Checker, f: u32) void {
        const nd = c.node(f);
        const name = c.tokText(nd.tok);
        const ret = c.typeSpec(nd.a);
        c.needPrecision(ret, c.node(nd.a).flags, nd.line);
        if (ret.sampler()) c.log.err(nd.line, "a function cannot return a sampler", .{});
        // the parameters
        const pstart = c.nparams;
        var pm = nd.b;
        var np: u8 = 0;
        while (pm != 0) : (pm = c.node(pm).next) {
            const pn = c.node(pm);
            var t = c.typeSpec(pn.a);
            if (pn.b != 0) t.array = c.arraySize(pn.b, pn.line);
            if (t.base == .void) c.log.err(pn.line, "a parameter cannot be void", .{});
            c.needPrecision(t, pn.flags, pn.line);
            if (pn.flags & ~(Q.in | Q.out | Q.@"const" | Q.precision) != 0) c.log.err(pn.line, "parameters take in, out, inout, const", .{});
            if (t.sampler() and pn.flags & Q.out != 0) c.log.err(pn.line, "a sampler parameter cannot be out", .{});
            pn.ty = t.bits();
            if (c.nparams == MAX_PARAMS) break;
            c.params[c.nparams] = .{ .ty = t, .q = pn.flags };
            c.nparams += 1;
            np += 1;
        }
        if (std.mem.startsWith(u8, name, "gl_")) c.log.err(nd.line, "names beginning gl_ are reserved: {s}", .{name});
        if (std.mem.eql(u8, name, "main")) {
            if (ret.base != .void or np != 0) c.log.err(nd.line, "main must be `void main()`", .{});
            if (nd.c != 0) c.has_main = true;
        }
        // an earlier prototype or definition of the same signature
        var existing: ?*Sym = null;
        for (c.syms[0..c.nsyms]) |*s| {
            if (s.kind != .function or !std.mem.eql(u8, s.name, name) or s.nparams != np) continue;
            var same = true;
            for (0..np) |k| {
                if (!c.params[s.params + k].ty.eq(c.params[pstart + k].ty)) same = false;
            }
            if (same) existing = s;
        }
        // (3.00 forbids redeclaring a built-in; 1.00 lets shaders overload them)
        if (c.version >= 300 and isBuiltinName(name)) c.log.err(nd.line, "`{s}` is a built-in function: it cannot be redeclared in GLSL ES 3.00", .{name});
        if (existing) |s| {
            if (!s.ty.eq(ret)) c.log.err(nd.line, "`{s}` redeclared with another return type", .{name});
            if (s.defined and nd.c != 0) c.log.err(nd.line, "`{s}` defined twice", .{name});
            if (nd.c != 0) s.defined = true;
            c.nparams = pstart;
        } else {
            _ = c.add(.{ .name = name, .kind = .function, .ty = ret, .params = @intCast(pstart), .nparams = np, .defined = nd.c != 0 }, nd.line);
        }
        if (nd.c == 0) return;
        // the body, its parameters in scope
        c.push();
        pm = nd.b;
        while (pm != 0) : (pm = c.node(pm).next) {
            const pn = c.node(pm);
            if (pn.tok != 0) _ = c.add(.{ .name = c.tokText(pn.tok), .kind = .variable, .ty = Type.of(pn.ty), .q = pn.flags & ~@as(u16, Q.precision) }, pn.line);
        }
        c.ret = ret;
        c.statements(c.node(nd.c).a);
        c.pop();
    }

    // ── Statements ─────────────────────────────────────────────────────────

    fn statements(c: *Checker, first: u32) void {
        var s = first;
        while (s != 0) : (s = c.node(s).next) c.statement(s);
    }

    fn condition(c: *Checker, e: u32, line: u32, what: []const u8) void {
        const t = c.expr(e);
        if (!t.isErr() and !t.eq(BOOL)) c.log.err(line, "{s} needs a bool, not {s}", .{ what, c.typeName(t) });
    }

    fn statement(c: *Checker, s: u32) void {
        const nd = c.node(s);
        switch (nd.kind) {
            .block => {
                c.push();
                c.statements(nd.a);
                c.pop();
            },
            .decl_stmt => {
                const d = c.node(nd.a);
                if (d.kind == .decl) c.declaration(nd.a, false) else if (d.kind == .precision) c.external(nd.a) else c.log.err(nd.line, "not a declaration here", .{});
            },
            .expr_stmt => {
                if (nd.a != 0) _ = c.expr(nd.a);
            },
            .@"if" => {
                c.condition(nd.a, nd.line, "`if`");
                c.scoped(nd.b);
                if (nd.c != 0) c.scoped(nd.c);
            },
            .@"for" => {
                c.push();
                if (nd.a != 0) c.statement(nd.a);
                if (nd.b != 0) c.condition(nd.b, nd.line, "`for`");
                if (nd.c != 0) _ = c.expr(nd.c);
                c.loops += 1;
                c.scoped(nd.d);
                c.loops -= 1;
                c.pop();
            },
            .@"while" => {
                c.condition(nd.a, nd.line, "`while`");
                c.loops += 1;
                c.scoped(nd.b);
                c.loops -= 1;
            },
            .do => {
                c.loops += 1;
                c.scoped(nd.a);
                c.loops -= 1;
                c.condition(nd.b, nd.line, "`do ... while`");
            },
            .@"switch" => {
                if (c.version < 300) c.log.err(nd.line, "switch is GLSL ES 3.00's", .{});
                const t = c.expr(nd.a);
                if (!t.isErr() and !(t.eq(INT) or t.eq(scalarT(.uint)))) c.log.err(nd.line, "switch needs an int or uint, not {s}", .{c.typeName(t)});
                c.switches += 1;
                c.push();
                var k = c.node(nd.b).a;
                var seen: [64]i64 = undefined;
                var nseen: usize = 0;
                while (k != 0) : (k = c.node(k).next) {
                    const kn = c.node(k);
                    if (kn.kind == .case) {
                        const ct = c.expr(kn.a);
                        const v = c.constInt(kn.a) orelse {
                            c.log.err(kn.line, "a case label must be a constant integer", .{});
                            continue;
                        };
                        if (!ct.isErr() and !t.isErr() and !ct.eq(t)) c.log.err(kn.line, "case label is {s}, the switch {s}", .{ c.typeName(ct), c.typeName(t) });
                        for (seen[0..nseen]) |x| {
                            if (x == v) c.log.err(kn.line, "case {d} twice", .{v});
                        }
                        if (nseen < seen.len) {
                            seen[nseen] = v;
                            nseen += 1;
                        }
                    } else if (kn.kind != .default) c.statement(k);
                }
                c.pop();
                c.switches -= 1;
            },
            .case, .default => c.log.err(nd.line, "case and default belong in a switch", .{}),
            .@"break" => if (c.loops == 0 and c.switches == 0) c.log.err(nd.line, "break outside a loop or switch", .{}),
            .@"continue" => if (c.loops == 0) c.log.err(nd.line, "continue outside a loop", .{}),
            .discard => if (c.stage != .fragment) c.log.err(nd.line, "discard is for fragment shaders", .{}),
            .@"return" => {
                if (nd.a == 0) {
                    if (c.ret.base != .void and !c.ret.isErr()) c.log.err(nd.line, "return needs a value of {s}", .{c.typeName(c.ret)});
                } else {
                    const t = c.expr(nd.a);
                    if (c.ret.base == .void) c.log.err(nd.line, "a void function returns no value", .{}) else if (!t.isErr() and !c.ret.isErr() and !t.eq(c.ret)) c.log.err(nd.line, "returns {s}, the function {s}", .{ c.typeName(t), c.typeName(c.ret) });
                }
            },
            .empty => {},
            else => c.log.err(nd.line, "not a statement", .{}),
        }
    }

    fn scoped(c: *Checker, s: u32) void {
        if (s == 0) return;
        c.push();
        c.statement(s);
        c.pop();
    }

    // ── Expressions ────────────────────────────────────────────────────────

    pub fn typeName(c: *Checker, t: Type) []const u8 {
        if (t.base == .structure) return c.structs[t.strukt].name;
        const kws = [_]Kw{ .void, .bool, .int, .uint, .float, .vec2, .vec3, .vec4, .bvec2, .bvec3, .bvec4, .ivec2, .ivec3, .ivec4, .uvec2, .uvec3, .uvec4, .mat2, .mat3, .mat4, .mat2x3, .mat2x4, .mat3x2, .mat3x4, .mat4x2, .mat4x3, .sampler2D, .sampler3D, .samplerCube, .sampler2DShadow, .samplerCubeShadow, .sampler2DArray, .sampler2DArrayShadow, .isampler2D, .isampler3D, .isamplerCube, .isampler2DArray, .usampler2D, .usampler3D, .usamplerCube, .usampler2DArray, .samplerExternalOES };
        const e = t.elem();
        for (kws) |kw| {
            if (typeOfKw(kw).?.eq(e)) return if (t.array != 0) "an array" else @tagName(kw);
        }
        return "a type gone wrong";
    }

    fn set(c: *Checker, e: u32, t: Type) Type {
        c.node(e).ty = t.bits();
        return t;
    }

    /// The expression's type (on its node too).
    pub fn expr(c: *Checker, e: u32) Type {
        if (e == 0) return ERR;
        const nd = c.node(e);
        const t: Type = switch (nd.kind) {
            .int_lit => INT,
            .uint_lit => blk: {
                if (c.version < 300) c.log.err(nd.line, "unsigned literals are GLSL ES 3.00's", .{});
                break :blk scalarT(.uint);
            },
            .float_lit => FLOAT,
            .bool_lit => BOOL,
            .ident => c.identExpr(nd),
            .binary => c.binaryExpr(nd),
            .unary => c.unaryExpr(nd),
            .pre_inc, .pre_dec, .post_inc, .post_dec => blk: {
                const it = c.expr(nd.a);
                if (it.isErr()) break :blk ERR;
                if (!it.numeric()) {
                    c.log.err(nd.line, "++ and -- need a number, not {s}", .{c.typeName(it)});
                    break :blk ERR;
                }
                c.needLvalue(nd.a, nd.line);
                break :blk it;
            },
            .assign => c.assignExpr(nd),
            .ternary => blk: {
                c.condition(nd.a, nd.line, "`?:`");
                const a = c.expr(nd.b);
                const b = c.expr(nd.c);
                if (a.isErr() or b.isErr()) break :blk ERR;
                if (!a.eq(b)) {
                    c.log.err(nd.line, "`?:`'s two values differ: {s} and {s}", .{ c.typeName(a), c.typeName(b) });
                    break :blk ERR;
                }
                break :blk a;
            },
            .sequence => blk: {
                _ = c.expr(nd.a);
                break :blk c.expr(nd.b);
            },
            .index => c.indexExpr(nd),
            .field => c.fieldExpr(nd),
            .call => if (nd.a != 0) c.construct(nd) else c.callExpr(nd),
            .empty => ERR,
            else => blk: {
                c.log.err(nd.line, "not an expression", .{});
                break :blk ERR;
            },
        };
        return c.set(e, t);
    }

    fn identExpr(c: *Checker, nd: *Node) Type {
        const name = c.tokText(nd.tok);
        const s = c.find(name) orelse {
            c.log.err(nd.line, "`{s}` is not declared", .{name});
            return ERR;
        };
        if (s.kind != .variable) {
            c.log.err(nd.line, "`{s}` is not a variable", .{name});
            return ERR;
        }
        s.used = true;
        if (s.builtin and c.stage == .fragment and c.version < 300) {
            if (std.mem.eql(u8, name, "gl_FragColor")) c.uses_frag_color = true;
            if (std.mem.eql(u8, name, "gl_FragData")) c.uses_frag_data = true;
        }
        if (s.builtin) c.noteBuiltin(name);
        return s.ty;
    }

    /// The symbol a name, field, swizzle or index chain starts from.
    fn rootSym(c: *Checker, e: u32) ?*Sym {
        const nd = c.node(e);
        return switch (nd.kind) {
            .ident => c.find(c.tokText(nd.tok)),
            .field, .index => c.rootSym(nd.a),
            else => null,
        };
    }

    fn needLvalue(c: *Checker, e: u32, line: u32) void {
        const nd = c.node(e);
        if (nd.kind != .ident and nd.kind != .field and nd.kind != .index) {
            c.log.err(line, "this cannot be assigned to", .{});
            return;
        }
        if (nd.kind == .field and nd.op != 1 and nd.value == 1) c.log.err(line, "a swizzle with a component twice cannot be assigned to", .{});
        if (nd.kind == .field and nd.op == 1) c.log.err(line, "length() cannot be assigned to", .{});
        const s = c.rootSym(e) orelse return;
        if (s.q & Q.@"const" != 0) c.log.err(line, "`{s}` is const", .{s.name});
        if (s.q & Q.uniform != 0) c.log.err(line, "`{s}` is a uniform: read only", .{s.name});
        // (globals in: read only; a parameter `in` is a local copy)
        if (s.q & Q.in != 0 and s.q & Q.out == 0 and (s.depth <= 2 or s.builtin)) c.log.err(line, "`{s}` is an input: read only", .{s.name});
        if (s.q & Q.varying != 0 and c.stage == .fragment) c.log.err(line, "`{s}` is an input: read only", .{s.name});
        if (s.q & Q.attribute != 0) c.log.err(line, "`{s}` is an attribute: read only", .{s.name});
        if (s.builtin and s.q & Q.out == 0) c.log.err(line, "`{s}` is read only", .{s.name});
        if (s.builtin and c.stage == .fragment and c.version < 300) {
            if (std.mem.eql(u8, s.name, "gl_FragColor")) c.uses_frag_color = true;
            if (std.mem.eql(u8, s.name, "gl_FragData")) c.uses_frag_data = true;
        }
        if (s.builtin) c.noteBuiltin(s.name);
    }

    fn noteBuiltin(c: *Checker, name: []const u8) void {
        if (std.mem.eql(u8, name, "gl_PointSize")) c.uses_point_size = true;
        if (std.mem.eql(u8, name, "gl_PointCoord")) c.uses_point_coord = true;
        if (std.mem.eql(u8, name, "gl_FragDepth")) c.uses_frag_depth = true;
    }

    fn binaryExpr(c: *Checker, nd: *Node) Type {
        const a = c.expr(nd.a);
        const b = c.expr(nd.b);
        if (a.isErr() or b.isErr()) return ERR;
        const op: Kind = @fromBackingInt(@intCast(nd.op));
        return c.binaryType(op, a, b, nd.line);
    }

    /// The type of `a op b` (also what `a op= b` needs), or ERR with a message.
    fn binaryType(c: *Checker, op: Kind, a: Type, b: Type, line: u32) Type {
        switch (op) {
            .and_and, .or_or, .xor_xor => {
                if (!a.eq(BOOL) or !b.eq(BOOL)) return c.badOp(op, a, b, line);
                return BOOL;
            },
            .eq, .ne => {
                if (!a.eq(b) or c.hasSampler(a)) return c.badOp(op, a, b, line);
                if (a.array != 0 and c.version < 300) return c.badOp(op, a, b, line);
                return BOOL;
            },
            .lt, .gt, .le, .ge => {
                if (!a.eq(b) or !a.scalar() or !a.numeric()) return c.badOp(op, a, b, line);
                return BOOL;
            },
            .shl, .shr => {
                if (c.version < 300) return c.badOp(op, a, b, line);
                if (!a.integer() or !b.integer() or a.matrix() or b.matrix()) return c.badOp(op, a, b, line);
                if (!b.scalar() and b.rows != a.rows) return c.badOp(op, a, b, line);
                return a;
            },
            .amp, .pipe, .caret, .percent => {
                if (c.version < 300) return c.badOp(op, a, b, line);
                if (!a.integer() or !b.integer() or a.base != b.base) return c.badOp(op, a, b, line);
                if (a.eq(b)) return a;
                if (a.scalar()) return b;
                if (b.scalar()) return a;
                return c.badOp(op, a, b, line);
            },
            .plus, .minus, .star, .slash => {
                if (!a.numeric() or !b.numeric() or a.base != b.base) return c.badOp(op, a, b, line);
                if (op == .star and (a.matrix() or b.matrix()) and !(a.scalar() or b.scalar())) {
                    // linear algebra: mat x mat, mat x vec, vec x mat
                    if (a.matrix() and b.matrix()) {
                        if (a.cols != b.rows) return c.badOp(op, a, b, line);
                        return matT(b.cols, a.rows);
                    }
                    if (a.matrix()) {
                        if (a.cols != b.rows) return c.badOp(op, a, b, line);
                        return vecT(.float, a.rows);
                    }
                    if (b.rows != a.rows) return c.badOp(op, a, b, line);
                    return vecT(.float, b.cols);
                }
                if (a.eq(b)) return a;
                if (a.scalar()) return b;
                if (b.scalar()) return a;
                return c.badOp(op, a, b, line);
            },
            else => return c.badOp(op, a, b, line),
        }
    }

    fn opText(op: Kind) []const u8 {
        return switch (op) {
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .shl => "<<",
            .shr => ">>",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .eq => "==",
            .ne => "!=",
            .and_and => "&&",
            .or_or => "||",
            .xor_xor => "^^",
            else => "?",
        };
    }

    fn badOp(c: *Checker, op: Kind, a: Type, b: Type, line: u32) Type {
        c.log.err(line, "`{s}` cannot take {s} and {s}", .{ opText(op), c.typeName(a), c.typeName(b) });
        return ERR;
    }

    fn unaryExpr(c: *Checker, nd: *Node) Type {
        const t = c.expr(nd.a);
        if (t.isErr()) return ERR;
        switch (@as(Kind, @fromBackingInt(@intCast(nd.op)))) {
            .bang => if (!t.eq(BOOL)) {
                c.log.err(nd.line, "`!` needs a bool, not {s}", .{c.typeName(t)});
                return ERR;
            },
            .tilde => if (!t.integer() or t.matrix() or c.version < 300) {
                c.log.err(nd.line, "`~` needs an int or uint, not {s}", .{c.typeName(t)});
                return ERR;
            },
            else => if (!t.numeric()) {
                c.log.err(nd.line, "unary + and - need a number, not {s}", .{c.typeName(t)});
                return ERR;
            },
        }
        return t;
    }

    fn assignExpr(c: *Checker, nd: *Node) Type {
        const a = c.expr(nd.a);
        const b = c.expr(nd.b);
        c.needLvalue(nd.a, nd.line);
        if (a.isErr() or b.isErr()) return ERR;
        const op: Kind = @fromBackingInt(@intCast(nd.op));
        if (op == .assign) {
            if (!a.eq(b)) {
                c.log.err(nd.line, "cannot assign {s} to {s}", .{ c.typeName(b), c.typeName(a) });
                return ERR;
            }
            if (c.hasSampler(a)) c.log.err(nd.line, "samplers cannot be assigned", .{});
            if (a.array != 0 and c.version < 300) c.log.err(nd.line, "arrays cannot be assigned in GLSL ES 1.00", .{});
            return a;
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
            .or_assign => .pipe,
            else => .plus,
        };
        const r = c.binaryType(bop, a, b, nd.line);
        if (r.isErr()) return ERR;
        if (!r.eq(a)) {
            c.log.err(nd.line, "the result is {s}, the target {s}", .{ c.typeName(r), c.typeName(a) });
            return ERR;
        }
        return a;
    }

    fn indexExpr(c: *Checker, nd: *Node) Type {
        const a = c.expr(nd.a);
        const b = c.expr(nd.b);
        if (a.isErr() or b.isErr()) return ERR;
        if (!(b.eq(INT) or b.eq(scalarT(.uint)))) {
            c.log.err(nd.line, "an index must be an int or uint, not {s}", .{c.typeName(b)});
            return ERR;
        }
        const size: u32 = if (a.array != 0) a.array else if (a.matrix()) a.cols else if (a.vector()) a.rows else {
            c.log.err(nd.line, "{s} cannot be indexed", .{c.typeName(a)});
            return ERR;
        };
        if (c.constInt(nd.b)) |k| {
            if (k < 0 or k >= size) c.log.err(nd.line, "index {d} is out of range (0..{d})", .{ k, size - 1 });
        }
        if (a.array != 0) return a.elem();
        if (a.matrix()) return vecT(.float, a.rows);
        return scalarT(a.base);
    }

    fn fieldExpr(c: *Checker, nd: *Node) Type {
        const a = c.expr(nd.a);
        if (a.isErr()) return ERR;
        const name = c.tokText(nd.tok);
        if (nd.op == 1) {
            // length(): an array's
            if (a.array == 0) {
                c.log.err(nd.line, "length() is for arrays", .{});
                return ERR;
            }
            if (c.version < 300) c.log.err(nd.line, "length() is GLSL ES 3.00's", .{});
            nd.value = a.array;
            return INT;
        }
        if (a.base == .structure and a.array == 0) {
            for (c.structFields(a)) |f| {
                if (std.mem.eql(u8, f.name, name)) return f.ty;
            }
            c.log.err(nd.line, "{s} has no member `{s}`", .{ c.typeName(a), name });
            return ERR;
        }
        if (!a.vector()) {
            c.log.err(nd.line, "`.{s}` on {s}", .{ name, c.typeName(a) });
            return ERR;
        }
        // a swizzle: up to four of xyzw, rgba or stpq, one set
        const sets = [3][]const u8{ "xyzw", "rgba", "stpq" };
        var set_i: ?usize = null;
        var seen: u8 = 0;
        if (name.len == 0 or name.len > 4) {
            c.log.err(nd.line, "bad swizzle `{s}`", .{name});
            return ERR;
        }
        for (name) |ch| {
            var found = false;
            for (sets, 0..) |st, si| {
                if (std.mem.indexOfScalar(u8, st, ch)) |k| {
                    if (set_i != null and set_i.? != si) {
                        c.log.err(nd.line, "swizzle `{s}` mixes component sets", .{name});
                        return ERR;
                    }
                    set_i = si;
                    if (k >= a.rows) {
                        c.log.err(nd.line, "swizzle `{s}`: {s} has {d} components", .{ name, c.typeName(a), a.rows });
                        return ERR;
                    }
                    if (seen & (@as(u8, 1) << @intCast(k)) != 0) nd.value = 1;
                    seen |= @as(u8, 1) << @intCast(k);
                    found = true;
                }
            }
            if (!found) {
                c.log.err(nd.line, "bad swizzle `{s}`", .{name});
                return ERR;
            }
        }
        return vecT(a.base, @intCast(name.len));
    }

    /// The types of a call's arguments (at most 16).
    fn argTypes(c: *Checker, first: u32, out: []Type) usize {
        var n: usize = 0;
        var a = first;
        while (a != 0) : (a = c.node(a).next) {
            const t = c.expr(a);
            if (n < out.len) out[n] = t;
            n += 1;
        }
        return n;
    }

    fn construct(c: *Checker, nd: *Node) Type {
        var target = c.typeSpec(nd.a);
        const unsized = c.node(nd.a).op == 1;
        if (unsized) target.array = 0;
        var ts: [16]Type = undefined;
        const n = c.argTypes(nd.b, &ts);
        if (target.isErr()) return ERR;
        for (ts[0..@min(n, 16)]) |t| {
            if (t.isErr()) return ERR;
        }
        if (n == 0) {
            c.log.err(nd.line, "a constructor needs arguments", .{});
            return ERR;
        }
        if (n > 16) {
            c.log.err(nd.line, "too many arguments", .{});
            return ERR;
        }
        const args = ts[0..n];
        // arrays: T[n](a, b, ...)
        if (target.array != 0 or unsized) {
            if (c.version < 300) c.log.err(nd.line, "array constructors are GLSL ES 3.00's", .{});
            const want: u32 = if (unsized) @intCast(n) else target.array;
            if (n != want) {
                c.log.err(nd.line, "the array constructor needs {d} arguments, not {d}", .{ want, n });
                return ERR;
            }
            for (args) |t| {
                if (!t.eq(target.elem())) {
                    c.log.err(nd.line, "an array of {s} cannot hold {s}", .{ c.typeName(target.elem()), c.typeName(t) });
                    return ERR;
                }
            }
            target.array = @intCast(want);
            return target;
        }
        if (target.base == .structure) {
            const fs = c.structFields(target);
            if (fs.len != n) {
                c.log.err(nd.line, "{s}'s constructor needs {d} arguments, not {d}", .{ c.typeName(target), fs.len, n });
                return ERR;
            }
            for (fs, args) |f, t| {
                if (!f.ty.eq(t)) {
                    c.log.err(nd.line, "{s}'s member `{s}` is {s}, not {s}", .{ c.typeName(target), f.name, c.typeName(f.ty), c.typeName(t) });
                    return ERR;
                }
            }
            return target;
        }
        if (target.sampler() or target.base == .void) {
            c.log.err(nd.line, "{s} has no constructor", .{c.typeName(target)});
            return ERR;
        }
        for (args) |t| {
            if (t.array != 0 or t.base == .structure or t.sampler()) {
                c.log.err(nd.line, "{s} cannot be made of {s}", .{ c.typeName(target), c.typeName(t) });
                return ERR;
            }
        }
        if (n == 1) return target; // (a scalar to fill or a diagonal; a vector, a matrix: the first components)
        // the components, every argument used, the last perhaps in part
        var have: u32 = 0;
        const need = target.comps();
        for (args, 0..) |t, k| {
            if (target.matrix() and t.matrix()) {
                c.log.err(nd.line, "a matrix is made of a single matrix, or of scalars and vectors", .{});
                return ERR;
            }
            if (have >= need) {
                c.log.err(nd.line, "too many arguments for {s} (argument {d} unused)", .{ c.typeName(target), k + 1 });
                return ERR;
            }
            have += t.comps();
        }
        if (have < need) {
            c.log.err(nd.line, "not enough components for {s}: {d} of {d}", .{ c.typeName(target), have, need });
            return ERR;
        }
        if (target.matrix() and have != need) {
            c.log.err(nd.line, "too many components for {s}", .{c.typeName(target)});
            return ERR;
        }
        return target;
    }

    fn callExpr(c: *Checker, nd: *Node) Type {
        const name = c.tokText(nd.tok);
        var ts: [16]Type = undefined;
        const n = c.argTypes(nd.b, &ts);
        if (n > ts.len) {
            c.log.err(nd.line, "too many arguments to `{s}`", .{name});
            return ERR;
        }
        for (ts[0..@min(n, 16)]) |t| {
            if (t.isErr()) return ERR;
        }
        // the shader's own functions first (they cannot overload built-ins)
        var named = false;
        for (c.syms[0..c.nsyms]) |s| {
            if (s.kind == .function and std.mem.eql(u8, s.name, name)) {
                named = true;
                if (s.nparams != n) continue;
                var ok = true;
                for (0..n) |k| {
                    if (!c.params[s.params + k].ty.eq(ts[k])) ok = false;
                }
                if (!ok) continue;
                // out and inout arguments: l-values
                var a = nd.b;
                for (0..n) |k| {
                    if (c.params[s.params + k].q & Q.out != 0) c.needLvalue(a, nd.line);
                    a = c.node(a).next;
                }
                nd.value = 0;
                return s.ty;
            }
        }
        if (c.find(name)) |s| {
            if (s.kind != .function) {
                c.log.err(nd.line, "`{s}` is not a function", .{name});
                return ERR;
            }
        }
        // the built-ins
        if (std.mem.eql(u8, name, "outerProduct") and c.version >= 300 and n == 2) {
            if (ts[0].vector() and ts[1].vector() and ts[0].base == .float and ts[1].base == .float) return matT(ts[1].rows, ts[0].rows);
        }
        for (builtins, 0..) |b, bi| {
            if (!std.mem.eql(u8, b.name, name)) continue;
            named = true;
            if (b.nargs != n) continue;
            if (b.v300 and c.version < 300) continue;
            if (b.v100 and c.version >= 300) continue;
            if (b.vertex_only_100 and c.stage != .vertex) continue;
            if (b.lod_ext and (c.stage != .fragment or !c.ext.texture_lod)) continue;
            if (b.deriv and (c.stage != .fragment or (c.version < 300 and !c.ext.derivatives))) continue;
            var bnd = Binding{};
            var ok = true;
            for (0..n) |k| {
                if (!fits(b.args[k], ts[k], &bnd)) ok = false;
            }
            if (!ok) continue;
            var a = nd.b;
            for (0..n) |k| {
                if (b.args[k] == .out_genF) c.needLvalue(a, nd.line);
                a = c.node(a).next;
            }
            nd.value = @intCast(bi + 1);
            return retOf(b.ret, bnd);
        }
        if (named) {
            var buf: [256]u8 = undefined;
            var w: usize = 0;
            for (ts[0..@min(n, 16)], 0..) |t, k| {
                const s = std.fmt.bufPrint(buf[w..], "{s}{s}", .{ if (k > 0) ", " else "", c.typeName(t) }) catch break;
                w += s.len;
            }
            c.log.err(nd.line, "no `{s}` takes ({s})", .{ name, buf[0..w] });
        } else c.log.err(nd.line, "`{s}` is not a function", .{name});
        return ERR;
    }
};

fn isBuiltinName(name: []const u8) bool {
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────

var t_checker: Checker = undefined;

/// The shader `src` checked as `stage`: the log's text ("" when it is fine).
pub fn testCheck(src: []const u8, stage: Stage) []const u8 {
    const r = parse.testParse(src);
    t_checker_parser = r.p;
    t_checker = .{ .p = &t_checker_parser, .log = r.p.log, .stage = stage, .version = r.p.version, .ext = r.ext };
    if (r.root != 0 and r.p.log.errors == 0) t_checker.run(r.root);
    return r.p.log.text();
}
var t_checker_parser: parse.Parser = undefined;

test "sema: the built-ins' table" {
    try std.testing.expect(builtins.len > 180);
    var bnd = Binding{};
    try std.testing.expect(fits(.genF, vecT(.float, 3), &bnd));
    try std.testing.expect(!fits(.genF, vecT(.float, 2), &bnd));
    try std.testing.expect(fits(.f, FLOAT, &bnd));
    try std.testing.expect(retOf(.genB, bnd).eq(vecT(.bool, 3)));
}

test "sema: a vertex and a fragment shader, as WebRender writes them, check" {
    const vs =
        \\#version 300 es
        \\#define WR_VERTEX_SHADER
        \\precision highp float;
        \\struct RectWithSize { vec2 p0; vec2 size; };
        \\uniform mat4 uTransform;
        \\uniform sampler2D sGpuCache;
        \\in vec2 aPosition;
        \\in ivec4 aData;
        \\flat out vec4 vColor;
        \\out vec2 vUv;
        \\flat out ivec2 vLayer;
        \\const int N = 2;
        \\vec4 fetch(int address) {
        \\    ivec2 uv = ivec2(address % 1024, address / 1024);
        \\    return texelFetch(sGpuCache, uv, 0);
        \\}
        \\RectWithSize rect(vec4 v) { return RectWithSize(v.xy, v.zw); }
        \\void main() {
        \\    vec4 data[N] = vec4[N](fetch(aData.x), fetch(aData.x + 1));
        \\    RectWithSize r = rect(data[0]);
        \\    vec2 p = r.p0 + aPosition * r.size;
        \\    vColor = data[1].bgra;
        \\    vUv = clamp(p / vec2(textureSize(sGpuCache, 0)), vec2(0.0), vec2(1.0));
        \\    vLayer = aData.yz;
        \\    for (int i = 0; i < N; ++i) { if (data[i].x > 0.5) break; }
        \\    gl_Position = uTransform * vec4(p, 0.0, 1.0);
        \\}
    ;
    const log = testCheck(vs, .vertex);
    if (log.len != 0) std.debug.print("{s}", .{log});
    try std.testing.expectEqualStrings("", log);
    try std.testing.expectEqual(@as(usize, 2), t_checker.ninputs);
    try std.testing.expectEqual(@as(usize, 3), t_checker.noutputs);
    try std.testing.expectEqual(@as(usize, 2), t_checker.nuniforms);
    try std.testing.expect(t_checker.has_main);
    const fs =
        \\#version 300 es
        \\#extension GL_OES_EGL_image_external_essl3 : require
        \\precision mediump float;
        \\uniform samplerExternalOES sVideo;
        \\uniform sampler2D sColor0;
        \\flat in vec4 vColor;
        \\in vec2 vUv;
        \\flat in ivec2 vLayer;
        \\layout(location = 0) out vec4 oFragColor;
        \\void main() {
        \\    vec4 c = texture(sColor0, vUv) * vColor + texture(sVideo, vUv);
        \\    if (c.a < 0.01) discard;
        \\    oFragColor = vec4(c.rgb * c.a, c.a) * float(vLayer.x);
        \\}
    ;
    const log2 = testCheck(fs, .fragment);
    if (log2.len != 0) std.debug.print("{s}", .{log2});
    try std.testing.expectEqualStrings("", log2);
    try std.testing.expectEqual(@as(i32, 0), t_checker.outputs[0].loc);
}

test "sema: a 1.00 shader (as WebGL 1 and ANGLE write them) checks" {
    const fs =
        \\precision mediump float;
        \\varying vec2 vUv;
        \\uniform sampler2D uTex;
        \\uniform vec4 uColor[2];
        \\void main() { gl_FragColor = texture2D(uTex, vUv) * uColor[1]; }
    ;
    const log = testCheck(fs, .fragment);
    if (log.len != 0) std.debug.print("{s}", .{log});
    try std.testing.expectEqualStrings("", log);
}

fn expectErr(src: []const u8, stage: Stage, want: []const u8) !void {
    const log = testCheck(src, stage);
    if (std.mem.indexOf(u8, log, want) == null) {
        std.debug.print("wanted `{s}` in:\n{s}\n", .{ want, log });
        return error.TestExpectedError;
    }
}

test "sema: what GLSL ES forbids" {
    const H = "#version 300 es\nprecision highp float;\n";
    try expectErr(H ++ "void main() { float x = 1; }", .vertex, "`x` is float but its initializer is int");
    try expectErr(H ++ "void main() { y = 1.0; }", .vertex, "`y` is not declared");
    try expectErr(H ++ "uniform float u; void main() { u = 1.0; }", .vertex, "`u` is a uniform: read only");
    try expectErr(H ++ "void main() { vec4 v = vec3(1.0).xyzw; }", .vertex, "swizzle `xyzw`: vec3 has 3 components");
    try expectErr(H ++ "void main() { vec2 v = vec2(1.0, 2.0, 3.0); }", .vertex, "too many arguments for vec2");
    try expectErr(H ++ "void main() { vec4 v = vec4(1.0, 2.0); }", .vertex, "not enough components for vec4");
    try expectErr(H ++ "void main() { float x = pow(1.0); }", .vertex, "no `pow` takes (float)");
    try expectErr(H ++ "out int v; void main() {}", .vertex, "integer varyings must be flat");
    try expectErr(H ++ "void main() { mat2 m; vec3 v = m * vec3(1.0); }", .vertex, "`*` cannot take mat2 and vec3");
    try expectErr(H ++ "void main() { discard; }", .vertex, "discard is for fragment shaders");
    try expectErr(H ++ "void main() { break; }", .vertex, "break outside a loop or switch");
    try expectErr(H ++ "float f() { return 1; } void main() {}", .vertex, "returns int, the function float");
    try expectErr("#version 300 es\nout vec4 o; void main() { o = vec4(0.0); }", .fragment, "no precision for float");
    try expectErr(H ++ "out vec4 a; out vec4 b; void main() { a = vec4(0.0); b = vec4(1.0); }", .fragment, "needs a layout location");
    // (one of them unused: no matter, as Mesa links it)
    try std.testing.expectEqualStrings("", testCheck(H ++ "out vec4 a; out vec4 b; void main() { a = vec4(0.0); }", .fragment));
    try expectErr(H ++ "void main() { int a[2]; int x = a[2]; }", .vertex, "index 2 is out of range");
    try expectErr(H ++ "void main() { const int k; }", .vertex, "const `k` needs an initializer");
    try expectErr(H ++ "in vec4 v; void main() { v = vec4(0.0); }", .vertex, "`v` is an input: read only");
}
