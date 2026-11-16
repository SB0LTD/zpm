//! @zpm/hlsl ast — what the parser makes and the generator reads: types
//! (interned), symbols (variables, functions, types, constant buffers) and
//! the nodes of expressions and statements, all in fixed tables indexed by
//! u32 (0: none).
//!
//! Names are resolved as the parser reads them (HLSL declares before use),
//! so a node names its symbol, not a string. Function calls keep the name's
//! newest declaration: overloads are chosen by the generator, which knows
//! the arguments' types.

const std = @import("std");

pub const NONE: u32 = 0;

// ── Types ──────────────────────────────────────────────────────────────────

pub const Base = enum(u8) { none, void, bool, int, uint, float, half, double, min16float, min10float, min16int, min12int, min16uint, string };

pub const Class = enum(u8) { void, scalar, vector, matrix, structure, array, texture, sampler, stream, rwtexture, sbuffer, string };

/// D3D_SRV_DIMENSION's numbering (reflection's).
pub const TexDim = enum(u8) { unknown = 0, buffer = 1, tex1d = 2, tex1darray = 3, tex2d = 4, tex2darray = 5, tex2dms = 6, tex2dmsarray = 7, tex3d = 8, cube = 9, cubearray = 10 };

pub const Pack = enum(u8) { default, row, column };

pub const StreamKind = enum(u8) { point, line, triangle };

pub const Type = struct {
    class: Class,
    base: Base = .none,
    rows: u8 = 1,
    cols: u8 = 1,
    /// matrices: their packing (row_major, column_major or the default)
    pack: Pack = .default,
    /// textures: TexDim; samplers: 1 for SamplerComparisonState; streams: StreamKind
    dim: u8 = 0,
    /// arrays: the element; textures: the return type; streams: the vertex
    elem: u32 = 0,
    /// arrays: the length; structs: the member count; tex2dms: samples
    len: u32 = 0,
    /// structs: the first member (Ast.members)
    first: u32 = 0,
    /// structs: the name (pool offset and length)
    name_off: u32 = 0,
    name_len: u16 = 0,
};

pub const Member = struct {
    name_off: u32,
    name_len: u16,
    ty: u32,
    sem_off: u32 = 0,
    sem_len: u16 = 0,
    sem_index: u32 = 0,
    /// interpolation modifiers (Sym flags' INTERP bits)
    flags: u32 = 0,
};

// ── Symbols ────────────────────────────────────────────────────────────────

pub const SymKind = enum(u8) { variable, function, typename, cbuffer };

pub const Storage = enum(u8) {
    local,
    param,
    /// a global (uniform) variable: $Globals
    global,
    /// a static global (the shader's own, in temps)
    static_global,
    /// a cbuffer's or tbuffer's member
    cbuffer_member,
    groupshared,
};

// Sym.flags
pub const F_CONST: u32 = 1 << 0;
pub const F_STATIC: u32 = 1 << 1;
pub const F_UNIFORM: u32 = 1 << 2;
pub const F_EXTERN: u32 = 1 << 3;
pub const F_IN: u32 = 1 << 4;
pub const F_OUT: u32 = 1 << 5;
pub const F_ROW_MAJOR: u32 = 1 << 6;
pub const F_COL_MAJOR: u32 = 1 << 7;
pub const F_NOINTERP: u32 = 1 << 8;
pub const F_LINEAR: u32 = 1 << 9;
pub const F_CENTROID: u32 = 1 << 10;
pub const F_NOPERSP: u32 = 1 << 11;
pub const F_SAMPLE: u32 = 1 << 12;
pub const F_PRECISE: u32 = 1 << 13;
pub const F_GS_POINT: u32 = 1 << 14;
pub const F_GS_LINE: u32 = 1 << 15;
pub const F_GS_TRIANGLE: u32 = 1 << 16;
pub const F_GS_LINEADJ: u32 = 1 << 17;
pub const F_GS_TRIADJ: u32 = 1 << 18;
pub const F_TBUFFER: u32 = 1 << 19;
pub const F_GROUPSHARED: u32 = 1 << 20;
/// a function with a body (not only declared)
pub const F_DEFINED: u32 = 1 << 21;
/// a variable some code assigns to (or passes as out/inout)
pub const F_ASSIGNED: u32 = 1 << 22;
pub const F_INLINE: u32 = 1 << 23;
pub const INTERP = F_NOINTERP | F_LINEAR | F_CENTROID | F_NOPERSP | F_SAMPLE;
pub const GS_PRIM = F_GS_POINT | F_GS_LINE | F_GS_TRIANGLE | F_GS_LINEADJ | F_GS_TRIADJ;

pub const Sym = struct {
    kind: SymKind,
    storage: Storage = .local,
    name_off: u32 = 0,
    name_len: u16 = 0,
    /// variables: the type; functions: the return type
    ty: u32 = 0,
    flags: u32 = 0,
    /// variables: the initializer (a node), or a parameter's default
    init: u32 = NONE,
    sem_off: u32 = 0,
    sem_len: u16 = 0,
    sem_index: u32 = 0,
    /// register(x#): its letter (0: none) and number
    reg_kind: u8 = 0,
    reg_index: u32 = 0,
    /// packoffset(c#.x): its byte offset (0xffffffff: none)
    packoffset: u32 = 0xffff_ffff,
    /// cbuffer members: their buffer's symbol; cbuffers: their first member
    cbuf: u32 = 0,
    /// functions: the first parameter (they are consecutive) and the count;
    /// cbuffers: the member count
    params: u32 = 0,
    nparams: u32 = 0,
    /// functions: the body (a block node)
    body: u32 = NONE,
    /// functions: the same name's previous declaration (overloads)
    prev: u32 = NONE,
    /// functions: [maxvertexcount(n)]
    max_vertex: u32 = 0,
    line: u32 = 0,
};

// ── Nodes ──────────────────────────────────────────────────────────────────

pub const NodeKind = enum(u8) {
    none,
    // expressions
    ident,
    lit_int,
    lit_float,
    lit_bool,
    unary,
    preinc,
    predec,
    postinc,
    postdec,
    binary,
    assign,
    ternary,
    call,
    method,
    construct,
    cast,
    member,
    index,
    init_list,
    comma,
    // statements
    block,
    decl,
    expr,
    if_,
    for_,
    while_,
    do_,
    switch_,
    case_,
    default_,
    break_,
    continue_,
    return_,
    discard_,
    empty,
};

// flow attributes (Node.attr)
pub const A_LOOP: u8 = 1;
pub const A_UNROLL: u8 = 2;
pub const A_BRANCH: u8 = 4;
pub const A_FLATTEN: u8 = 8;
pub const A_FASTOPT: u8 = 16;
pub const A_FORCECASE: u8 = 32;

/// lit_int: `unsigned` in Node.op
pub const LIT_UNSIGNED: u8 = 1;

pub const Node = struct {
    kind: NodeKind = .none,
    /// unary/binary/assign: the operator (a lex.Kind)
    op: u8 = 0,
    attr: u8 = 0,
    /// a token: the place (and names: member, method, call)
    tok: u32 = 0,
    a: u32 = NONE,
    b: u32 = NONE,
    c: u32 = NONE,
    d: u32 = NONE,
    /// the next node in a list (arguments, statements)
    next: u32 = NONE,
};

// The node fields, by kind:
//   ident:      a = symbol
//   lit_int:    a = low 32 bits, b = high, op = LIT_UNSIGNED
//   lit_float:  a = f32 bits
//   lit_bool:   a = 0 or 1
//   unary, pre/post inc/dec: a = operand
//   binary:     a, b
//   assign:     op = the assignment's kind, a = target, b = value
//   ternary:    a = condition, b, c
//   call:       tok = the name, a = first argument, c = argument count,
//               d = the newest function of that name (none: an intrinsic)
//   method:     a = the object, tok = the method's name, b = first argument, c = count
//   construct:  a = type, b = first argument, c = count
//   cast:       a = type, b = operand
//   member:     a = operand, tok = the member's name (or swizzle)
//   index:      a = operand, b = index
//   init_list:  a = first element, c = count
//   comma:      a, b
//   block:      a = first statement
//   decl:       a = the variable's symbol
//   expr:       a = expression
//   if_:        a = condition, b = then, c = else
//   for_:       a = init (statement), b = condition, c = step, d = body
//   while_, do_: a = condition, d = body
//   switch_:    a = selector, b = body (a block)
//   case_:      a = value
//   return_:    a = value (none: void)

pub const MAX_TYPES = 8192;
pub const MAX_MEMBERS = 8192;
pub const MAX_SYMS = 16384;
pub const MAX_NODES = 1 << 17;

pub const Ast = struct {
    types: [MAX_TYPES]Type,
    ntypes: u32,
    members: [MAX_MEMBERS]Member,
    nmembers: u32,
    syms: [MAX_SYMS]Sym,
    nsyms: u32,
    nodes: [MAX_NODES]Node,
    nnodes: u32,
    /// the globals in the order declared: variables, cbuffers, functions
    globals: [MAX_SYMS]u32,
    nglobals: u32,
    pool: []const u8,

    pub fn reset(a: *Ast, pool: []const u8) void {
        a.ntypes = 1;
        a.types[0] = .{ .class = .void, .base = .void };
        a.nmembers = 1;
        a.nsyms = 1;
        a.syms[0] = .{ .kind = .variable };
        a.nnodes = 1;
        a.nodes[0] = .{};
        a.nglobals = 0;
        a.pool = pool;
    }

    pub fn name(a: *const Ast, off: u32, len: u16) []const u8 {
        return a.pool[off..][0..len];
    }

    pub fn symName(a: *const Ast, s: u32) []const u8 {
        return a.name(a.syms[s].name_off, a.syms[s].name_len);
    }

    /// A cbuffer's k-th member (its members are the variables declared in
    /// it, in order; a struct declared inside has a symbol among them).
    pub fn cbMember(a: *const Ast, cb: u32, k: u32) u32 {
        var i = a.syms[cb].cbuf;
        var n: u32 = 0;
        while (i < a.nsyms) : (i += 1) {
            const s = a.syms[i];
            if (s.kind == .variable and s.storage == .cbuffer_member and s.cbuf == cb) {
                if (n == k) return i;
                n += 1;
            }
        }
        return 0;
    }

    pub fn semName(a: *const Ast, s: u32) []const u8 {
        return a.name(a.syms[s].sem_off, a.syms[s].sem_len);
    }

    pub fn node(a: *Ast, kind: NodeKind, tok: u32) ?u32 {
        if (a.nnodes >= MAX_NODES) return null;
        const n = a.nnodes;
        a.nodes[n] = .{ .kind = kind, .tok = tok };
        a.nnodes += 1;
        return n;
    }

    // ── type interning ──

    pub fn intern(a: *Ast, t: Type) u32 {
        var i: u32 = 0;
        while (i < a.ntypes) : (i += 1) {
            const x = a.types[i];
            if (x.class == t.class and x.class != .structure and x.base == t.base and x.rows == t.rows and x.cols == t.cols and x.pack == t.pack and x.dim == t.dim and x.elem == t.elem and x.len == t.len) return i;
        }
        if (a.ntypes >= MAX_TYPES) return 0;
        a.types[a.ntypes] = t;
        a.ntypes += 1;
        return a.ntypes - 1;
    }

    pub fn scalar(a: *Ast, b: Base) u32 {
        return a.intern(.{ .class = .scalar, .base = b });
    }

    pub fn vector(a: *Ast, b: Base, n: u8) u32 {
        if (n == 1) return a.scalar(b);
        return a.intern(.{ .class = .vector, .base = b, .cols = n });
    }

    pub fn matrix(a: *Ast, b: Base, rows: u8, cols: u8, pack: Pack) u32 {
        return a.intern(.{ .class = .matrix, .base = b, .rows = rows, .cols = cols, .pack = pack });
    }

    pub fn array(a: *Ast, elem: u32, len: u32) u32 {
        return a.intern(.{ .class = .array, .elem = elem, .len = len });
    }

    /// A numeric type of `base` shaped as `shape` (scalar, vector or matrix).
    pub fn withBase(a: *Ast, shape: u32, b: Base) u32 {
        const t = a.types[shape];
        return switch (t.class) {
            .scalar => a.scalar(b),
            .vector => a.vector(b, t.cols),
            .matrix => a.matrix(b, t.rows, t.cols, t.pack),
            else => shape,
        };
    }

    /// The same matrix type with another packing (other types as they are;
    /// arrays of matrices too).
    pub fn withPack(a: *Ast, ty: u32, p: Pack) u32 {
        const t = a.types[ty];
        return switch (t.class) {
            .matrix => a.matrix(t.base, t.rows, t.cols, p),
            .array => a.array(a.withPack(t.elem, p), t.len),
            else => ty,
        };
    }

    pub fn isNumeric(a: *const Ast, ty: u32) bool {
        const c = a.types[ty].class;
        return c == .scalar or c == .vector or c == .matrix;
    }

    /// Scalar components of a numeric type.
    pub fn comps(a: *const Ast, ty: u32) u32 {
        const t = a.types[ty];
        return switch (t.class) {
            .scalar => 1,
            .vector => t.cols,
            .matrix => @as(u32, t.rows) * t.cols,
            .array => t.len * a.comps(t.elem),
            .structure => blk: {
                var n: u32 = 0;
                for (0..t.len) |k| n += a.comps(a.members[t.first + k].ty);
                break :blk n;
            },
            else => 0,
        };
    }

    pub fn typeName(a: *const Ast, ty: u32, buf: []u8) []const u8 {
        const t = a.types[ty];
        const b = @tagName(t.base);
        return switch (t.class) {
            .scalar => b,
            .vector => std.fmt.bufPrint(buf, "{s}{d}", .{ b, t.cols }) catch b,
            .matrix => std.fmt.bufPrint(buf, "{s}{d}x{d}", .{ b, t.rows, t.cols }) catch b,
            .structure => a.name(t.name_off, t.name_len),
            .array => "array",
            .texture => "texture",
            .sampler => "sampler",
            else => @tagName(t.class),
        };
    }
};

/// Whether a base is computed as a float (half and min-precision floats are
/// floats in Shader Model 4 and 5).
pub fn isFloat(b: Base) bool {
    return b == .float or b == .half or b == .min16float or b == .min10float or b == .double;
}

pub fn isInt(b: Base) bool {
    return b == .int or b == .uint or b == .min16int or b == .min12int or b == .min16uint;
}

pub fn isUnsigned(b: Base) bool {
    return b == .uint or b == .min16uint;
}

/// The base computed in: half and min precision as float, int, uint.
pub fn canon(b: Base) Base {
    return switch (b) {
        .half, .min16float, .min10float => .float,
        .min16int, .min12int => .int,
        .min16uint => .uint,
        else => b,
    };
}
