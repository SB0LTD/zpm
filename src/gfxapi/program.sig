//! @zpm/gfxapi program — OpenGL ES's shader and program objects, over the
//! GLSL front end (glsl/): glCreateShader .. glDeleteProgram, sources,
//! compiles and their logs, links (attribute locations, varyings matched
//! by name, type and interpolation, uniforms merged across the stages,
//! fragment outputs), uniform locations and values (glUniform*, glGet-
//! Uniform*), the active attributes and uniforms, as Mesa answers them.
//!
//! Uniform blocks (GLSL ES 3.00, std140; shared and packed laid out as
//! std140): a block's members are uniform words of the program too, with
//! no location, their std140 places kept. A draw copies each block's
//! bytes from the buffer range bound to its binding point into those
//! words (`fillBlocks`), so the code reads a block member as any uniform.
//!
//! Transform feedback: glTransformFeedbackVaryings' names, taken at the
//! next link (gl_Position, or the vertex shader's outputs, the fragment
//! shader's or not), interleaved in one buffer or one buffer each; the
//! pipeline's capture kernel writes them (raster.captureKernel).
//!
//! A link makes the program's interface, its uniform storage (tight
//! words: a float, an int, a bool or a sampler's unit each one), where
//! each varying goes, and its pipeline (raster.sig): the shaders' code,
//! generated (glsl/gen.sig) into the draw kernels when the engine builds
//! them, from copies of the sources the link kept. The link generates
//! both once to check them (what cannot be generated fails the link).
//!
//! Program binaries (glGetProgramBinary, glProgramBinary: WebRender's
//! shader disk cache): what a link made, in progbin.sig's format, taken
//! back as that link; one from another driver build or GPU, or damaged,
//! is refused (see "Program binaries" below).
//!
//! Shaders and programs share one namespace, as GL says; names are the
//! process's (one table), each object its share group's (another share
//! group's name is no name). A shader keeps its source and log in a text
//! pool (compacted when full); a link compiles its two shaders again, in
//! the one compile scratch. Every call takes this file's lock.
//!
//! Allocation-free: fixed tables (MAX_*), in this file's memory.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const gles = @import("gles.sig");
const g = @import("glenum.sig");
const engine = @import("engine.sig");
const report = @import("report.sig");
const raster = @import("raster.sig");
const texture = @import("texture.sig");
pub const progbin = @import("progbin.sig");
pub const glsl = @import("glsl/glsl.sig");
const kir = gpu.kir;
const Context = gles.Context;
const Objects = gles.Objects;
const Type = glsl.Type;

pub const MAX_NAMES = 2048;
pub const MAX_PROGRAMS = 256;
pub const POOL_BYTES = 8 << 20;
pub const MAX_ATTRIBS = 16;
pub const MAX_UNIFORMS = 256;
pub const MAX_LOCATIONS = 1024;
pub const MAX_VARYINGS = 32;
pub const MAX_OUTPUTS = 4;
pub const MAX_BINDINGS = 32;
pub const UNIFORM_WORDS = 4096;
/// GL ES 3.0's uniform block limits, as glGetIntegerv tells them: blocks a
/// program may have (MAX_COMBINED_UNIFORM_BLOCKS), binding points, a
/// block's bytes (its members' words count in UNIFORM_WORDS too)
pub const MAX_BLOCKS = 24;
pub const MAX_UNIFORM_BUFFER_BINDINGS = 24;
pub const MAX_UNIFORM_BLOCK_SIZE = 16384;
pub const UNIFORM_BUFFER_OFFSET_ALIGNMENT = 16;
/// a block's member another shader names by another instance name
const MAX_ALIASES = 64;
/// transform feedback: variables captured, components a vertex writes
/// (GL ES 3.0's MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS), one
/// separate buffer's components
pub const MAX_XFB = 32;
pub const MAX_XFB_COMPONENTS = 64;
pub const MAX_XFB_SEPARATE_COMPONENTS = 4;
pub const PROGRAM_NAMES = 4096;
/// GL's limits, as glGetIntegerv tells them
pub const MAX_VERTEX_UNIFORM_VECTORS = 256;
pub const MAX_FRAGMENT_UNIFORM_VECTORS = 224;
pub const MAX_VARYING_VECTORS = 15;
comptime {
    std.debug.assert(MAX_VARYING_VECTORS * 4 <= raster.MAX_VARYINGS);
}
pub const MAX_TEXTURE_UNITS = 32;

const Ref = struct { at: u32 = 0, len: u32 = 0 };
const Name = struct { at: u16 = 0, len: u16 = 0 };

const Kind = enum(u8) { free, shader, program };

const Obj = struct {
    label: gles.debug_output.Label = .{},
    kind: Kind = .free,
    owner: ?*Objects = null,
    /// glDelete* said so: it goes when nothing holds it (a shader: its
    /// programs; a program: the contexts using it)
    doomed: bool = false,
    refs: u32 = 0,
    log: Ref = .{},
    // a shader's
    stage: glsl.Stage = .vertex,
    compiled: bool = false,
    source: Ref = .{},
    has_source: bool = false,
    // a program's: progs[prog]
    prog: u16 = 0,
};

pub const Attrib = struct { name: Name, ty: Type, loc: u32 };

pub const Uniform = struct {
    /// the name without "[0]" (an array's length is in ty.array), as the
    /// code names it
    name: Name,
    ty: Type,
    /// its first location (an array: one per element; a block's member:
    /// none)
    loc: u32,
    /// its first word in values (an element: comps words, a sampler one)
    word: u32,
    /// the stages using it: 1 vertex, 2 fragment
    stages: u8,
    /// GL's name, where it is not the code's: a named block's member
    /// ("Block.m"; the code says "inst.m")
    api: Name = .{},
    /// a uniform block's member: the block (-1: the default block), and
    /// its std140 place: its first element's byte offset, an array's
    /// stride, a matrix's column (row-major: row) stride
    block: i16 = -1,
    offset: u32 = 0,
    array_stride: u32 = 0,
    matrix_stride: u32 = 0,
    row_major: bool = false,
};

/// A uniform block of a program: its name, std140 size, binding point
/// (glUniformBlockBinding), stages and member count.
pub const UBlock = struct {
    name: Name,
    size: u32,
    binding: u32 = 0,
    stages: u8 = 0,
    members: u32 = 0,
};

/// A block member's name in a shader that names its instance otherwise:
/// the member's words.
const Alias = struct { name: Name, word: u32 };

/// A variable transform feedback captures: its buffer and its first word
/// in that buffer's record of a vertex.
pub const Xfb = struct { name: Name, ty: Type, buffer: u8, word: u32 };

pub const Varying = struct { name: Name, ty: Type, flat: bool, word: u32 };

/// A sampler (an element of a sampler uniform): its word (the unit's
/// number), the target its unit's texture is bound to, what it returns.
pub const Slot = struct {
    word: u32,
    external: bool,
    array: bool = false,
    volume: bool = false,
    cube: bool = false,
    shadow: bool = false,
    kind: texture.Kind,
    unsupported: bool = false,
};
pub const Output = struct { name: Name, ty: Type, loc: u32 };

/// A link's result: the program's interface and its uniforms' values.
pub const Linked = struct {
    version: u32 = 300,
    attribs: [MAX_ATTRIBS]Attrib = undefined,
    nattribs: usize = 0,
    uniforms: [MAX_UNIFORMS]Uniform = undefined,
    nuniforms: usize = 0,
    /// a location's uniform
    locs: [MAX_LOCATIONS]u16 = undefined,
    nlocs: usize = 0,
    varyings: [MAX_VARYINGS]Varying = undefined,
    nvaryings: usize = 0,
    /// the words a vertex hands the fragment shader
    vary_words: u32 = 0,
    outputs: [MAX_OUTPUTS]Output = undefined,
    noutputs: usize = 0,
    /// 1.00: gl_FragColor (every color buffer), gl_FragData[n]
    frag_color: bool = false,
    frag_data: bool = false,
    names: [PROGRAM_NAMES]u8 = undefined,
    nnames: usize = 0,
    values: [UNIFORM_WORDS]u32 = undefined,
    nwords: u32 = 0,
    /// the samplers: texture slot i reads its unit's texture (the draw's
    /// binding i, its descriptor at nwords + i * DESC_WORDS)
    slots: [texture.MAX_TEX]Slot = undefined,
    nslots: usize = 0,
    blocks: [MAX_BLOCKS]UBlock = undefined,
    nblocks: usize = 0,
    aliases: [MAX_ALIASES]Alias = undefined,
    naliases: usize = 0,
    /// transform feedback: what is captured, the components the capture
    /// kernel writes, each buffer's words a vertex, the mode
    xfb: [MAX_XFB]Xfb = undefined,
    nxfb: usize = 0,
    capture: [MAX_XFB_COMPONENTS]raster.Capture = undefined,
    ncapture: usize = 0,
    xfb_stride: [raster.MAX_CAPTURE_BUFFERS]u32 = @splat(0),
    xfb_mode: u32 = g.INTERLEAVED_ATTRIBS,

    pub fn name(l: *const Linked, n: Name) []const u8 {
        return l.names[n.at..][0..n.len];
    }

    /// A uniform's name as GL's queries give it.
    pub fn apiName(l: *const Linked, u: Uniform) []const u8 {
        return l.name(if (u.api.len > 0) u.api else u.name);
    }

    fn findApi(l: *const Linked, s: []const u8) ?*const Uniform {
        for (l.uniforms[0..l.nuniforms]) |*u| {
            if (std.mem.eql(u8, l.apiName(u.*), s)) return u;
        }
        return null;
    }

    fn keep(l: *Linked, s: []const u8) ?Name {
        if (l.nnames + s.len > l.names.len) return null;
        @memcpy(l.names[l.nnames..][0..s.len], s);
        defer l.nnames += s.len;
        return .{ .at = @intCast(l.nnames), .len = @intCast(s.len) };
    }

    pub fn findUniform(l: *const Linked, s: []const u8) ?*const Uniform {
        for (l.uniforms[0..l.nuniforms]) |*u| {
            if (std.mem.eql(u8, l.name(u.name), s)) return u;
        }
        return null;
    }

    /// The uniform at a location, and the element it is.
    pub fn atLocation(l: *Linked, loc: i32) ?struct { u: *Uniform, elem: u32 } {
        if (loc < 0 or @as(usize, @intCast(loc)) >= l.nlocs) return null;
        const u = &l.uniforms[l.locs[@intCast(loc)]];
        return .{ .u = u, .elem = @as(u32, @intCast(loc)) - u.loc };
    }

    /// A name's location ("u", "u[3]", "s.m", "s[1].m[2]"), or -1.
    pub fn location(l: *const Linked, s: []const u8) i32 {
        // (a block's members have none)
        if (l.findUniform(s)) |u| return if (u.block >= 0) -1 else @intCast(u.loc);
        // a trailing [k] of an array
        if (s.len < 4 or s[s.len - 1] != ']') return -1;
        const open = std.mem.lastIndexOfScalar(u8, s, '[') orelse return -1;
        const digits = s[open + 1 .. s.len - 1];
        if (digits.len == 0 or digits.len > 6) return -1;
        // (no leading zeros or signs, as Mesa)
        if (digits.len > 1 and digits[0] == '0') return -1;
        const k = std.fmt.parseInt(u32, digits, 10) catch return -1;
        const u = l.findUniform(s[0..open]) orelse return -1;
        if (u.block >= 0 or u.ty.array == 0 or k >= u.ty.array) return -1;
        return @intCast(u.loc + k);
    }
};

pub const Binding = struct { name: [64]u8 = undefined, len: u8 = 0, loc: u32 = 0 };

pub const Program = struct {
    vs: u32 = 0,
    fs: u32 = 0,
    linked: bool = false,
    validated: bool = false,
    binary_hint: bool = false,
    /// glTransformFeedbackVaryings' names (each ended by a 0) and mode,
    /// taken at the next link
    xfb_names: Ref = .{},
    xfb_count: u32 = 0,
    xfb_mode: u32 = g.INTERLEAVED_ATTRIBS,
    binds: [MAX_BINDINGS]Binding = undefined,
    nbinds: usize = 0,
    out: Linked = .{},
    /// the linked shaders' sources (the pool's), which the pipeline's
    /// code is generated from
    vs_src: Ref = .{},
    fs_src: Ref = .{},
    /// the pipeline draws run, and the engine that may have loaded it
    pipe: raster.Pipeline = undefined,
    has_pipe: bool = false,
    eng: ?*engine.Engine = null,

    fn unloadPipe(p: *Program) void {
        if (!p.has_pipe) return;
        if (p.eng) |e| e.unloadPipeline(&p.pipe);
        p.has_pipe = false;
    }

    fn boundTo(p: *const Program, s: []const u8) ?u32 {
        for (p.binds[0..p.nbinds]) |*b| {
            if (std.mem.eql(u8, b.name[0..b.len], s)) return b.loc;
        }
        return null;
    }
};

// ── The table, its lock ────────────────────────────────────────────────────

var objs: [MAX_NAMES]Obj = undefined;
var progs: [MAX_PROGRAMS]Program = undefined;
var prog_used: [MAX_PROGRAMS]bool = undefined;
var pool: [POOL_BYTES]u8 = undefined;
var pool_top: u32 = 0;
var next_name: u32 = 0;
var ready = false;
var scratch: glsl.Scratch = undefined;
var iface_vs: glsl.Iface = undefined;
var iface_fs: glsl.Iface = undefined;

var lock_word = std.atomic.Value(u32).init(0);

fn lock() void {
    if (lock_word.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
    while (lock_word.swap(2, .acquire) != 0) {
        if (comptime builtin.os.tag == .linux) {
            _ = std.os.linux.syscall4(.futex, @intFromPtr(&lock_word.raw), 128, 2, 0); // FUTEX_WAIT_PRIVATE
        } else std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    if (lock_word.swap(0, .release) == 2 and comptime builtin.os.tag == .linux) {
        _ = std.os.linux.syscall3(.futex, @intFromPtr(&lock_word.raw), 129, 1); // FUTEX_WAKE_PRIVATE
    }
}

fn start() void {
    lock();
    if (ready) return;
    for (&objs) |*o| o.* = .{};
    for (&prog_used) |*u| u.* = false;
    pool_top = 0;
    next_name = 0;
    ready = true;
}

// ── The text pool ──────────────────────────────────────────────────────────

fn poolText(r: Ref) []const u8 {
    return pool[r.at..][0..r.len];
}

/// Room for `len` bytes (the pool compacted when full), or null.
fn poolAlloc(len: usize) ?Ref {
    if (len > POOL_BYTES) return null;
    if (pool_top + len > POOL_BYTES) compact();
    if (pool_top + len > POOL_BYTES) return null;
    const r = Ref{ .at = pool_top, .len = @intCast(len) };
    pool_top += @intCast(len);
    return r;
}

/// A copy of the pool's text `src` (which a compaction may move: read
/// after the room is made).
fn poolDup(src: *const Ref) ?Ref {
    if (src.len == 0) return .{};
    const r = poolAlloc(src.len) orelse return null;
    std.mem.copyForwards(u8, pool[r.at..][0..r.len], pool[src.at..][0..src.len]);
    return r;
}

fn poolKeep(s: []const u8) ?Ref {
    if (s.len == 0) return .{};
    const r = poolAlloc(s.len) orelse return null;
    @memcpy(pool[r.at..][0..r.len], s);
    return r;
}

/// The live texts moved down, in order: each time the lowest not yet
/// moved (moved ones end below `cursor`, the others start at or above it).
fn compact() void {
    var cursor: u32 = 0;
    while (true) {
        var best: ?*Ref = null;
        for (&objs) |*o| {
            if (o.kind == .free) continue;
            for ([_]*Ref{ &o.source, &o.log }) |r| {
                if (r.len == 0 or r.at < cursor) continue;
                if (best == null or r.at < best.?.at) best = r;
            }
        }
        for (&progs, prog_used) |*p, used| {
            if (!used) continue;
            for ([_]*Ref{ &p.vs_src, &p.fs_src }) |r| {
                if (r.len == 0 or r.at < cursor) continue;
                if (best == null or r.at < best.?.at) best = r;
            }
        }
        const r = best orelse break;
        if (r.at != cursor) std.mem.copyForwards(u8, pool[cursor..][0..r.len], pool[r.at..][0..r.len]);
        r.at = cursor;
        cursor += r.len;
    }
    pool_top = cursor;
}

// ── Names ──────────────────────────────────────────────────────────────────

fn newName(owner: *Objects, kind: Kind) u32 {
    var k: u32 = 0;
    while (k < MAX_NAMES) : (k += 1) {
        const i = (next_name + k) % MAX_NAMES;
        if (objs[i].kind != .free) continue;
        objs[i] = .{ .kind = kind, .owner = owner };
        next_name = (i + 1) % MAX_NAMES;
        return i + 1;
    }
    return 0;
}

fn objOf(c: *Context, name: u32) ?*Obj {
    if (name == 0 or name > MAX_NAMES) return null;
    const o = &objs[name - 1];
    if (o.kind == .free or o.owner != c.objs) return null;
    return o;
}

pub fn objectLabel(c: *Context, name: u32, shader: bool) ?*gles.debug_output.Label {
    const o = objOf(c, name) orelse return null;
    if (o.kind != (if (shader) Kind.shader else Kind.program)) return null;
    return &o.label;
}

/// A shader by name: INVALID_VALUE for no name, INVALID_OPERATION for a program's.
fn shaderOf(c: *Context, name: u32) ?*Obj {
    const o = objOf(c, name) orelse {
        c.fail(g.INVALID_VALUE);
        return null;
    };
    if (o.kind != .shader) {
        c.fail(g.INVALID_OPERATION);
        return null;
    }
    return o;
}

fn programOf(c: *Context, name: u32) ?*Program {
    const o = objOf(c, name) orelse {
        c.fail(g.INVALID_VALUE);
        return null;
    };
    if (o.kind != .program) {
        c.fail(g.INVALID_OPERATION);
        return null;
    }
    return &progs[o.prog];
}

fn freeObj(o: *Obj) void {
    if (o.kind == .program) {
        const p = &progs[o.prog];
        p.unloadPipe();
        p.vs_src = .{};
        p.fs_src = .{};
        for ([_]u32{ p.vs, p.fs }) |s| {
            if (s != 0) dropShader(&objs[s - 1]);
        }
        prog_used[o.prog] = false;
    }
    o.* = .{};
}

fn dropShader(s: *Obj) void {
    if (s.refs > 0) s.refs -= 1;
    if (s.refs == 0 and s.doomed) freeObj(s);
}

fn dropProgram(o: *Obj) void {
    if (o.refs > 0) o.refs -= 1;
    if (o.refs == 0 and o.doomed) freeObj(o);
}

/// The context goes (eglDestroyContext): its program with it.
pub fn leave(c: *Context) void {
    start();
    defer unlock();
    if (c.program != 0) {
        if (c.program <= MAX_NAMES) dropProgram(&objs[c.program - 1]);
        c.program = 0;
    }
}

/// The share group goes: its shaders and programs with it.
pub fn dropOwner(owner: *Objects) void {
    start();
    defer unlock();
    for (&objs) |*o| {
        if (o.kind == .program and o.owner == owner) progs[o.prog].unloadPipe();
        if (o.kind != .free and o.owner == owner) o.* = .{};
    }
    // (their programs' slots: those no live name holds)
    for (&prog_used, 0..) |*u, i| {
        if (!u.*) continue;
        var held = false;
        for (&objs) |*o| {
            if (o.kind == .program and o.prog == i) held = true;
        }
        if (!held) u.* = false;
    }
}

// ── Out to the caller ──────────────────────────────────────────────────────

/// GL's way to hand a string out: at most bufSize - 1 bytes and a NUL,
/// the length without it.
fn copyOut(s: []const u8, buf_size: i32, length: ?*i32, out: ?[*]u8) void {
    if (buf_size <= 0 or out == null) {
        if (length) |l| l.* = 0;
        return;
    }
    const n = @min(s.len, @as(usize, @intCast(buf_size)) - 1);
    @memcpy(out.?[0..n], s[0..n]);
    out.?[n] = 0;
    if (length) |l| l.* = @intCast(n);
}

fn logLen(r: Ref) i32 {
    return if (r.len == 0) 0 else @intCast(r.len + 1);
}

// ── Shaders ────────────────────────────────────────────────────────────────

pub fn createShader(c: *Context, kind: u32) u32 {
    start();
    defer unlock();
    const stage: glsl.Stage = switch (kind) {
        g.VERTEX_SHADER => .vertex,
        g.FRAGMENT_SHADER => .fragment,
        else => {
            c.fail(g.INVALID_ENUM);
            return 0;
        },
    };
    const name = newName(c.objs, .shader);
    if (name == 0) {
        c.fail(g.OUT_OF_MEMORY);
        return 0;
    }
    objs[name - 1].stage = stage;
    return name;
}

pub fn deleteShader(c: *Context, name: u32) void {
    if (name == 0) return;
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    o.doomed = true;
    if (o.refs == 0) freeObj(o);
}

pub fn isShader(c: *Context, name: u32) bool {
    start();
    defer unlock();
    const o = objOf(c, name) orelse return false;
    return o.kind == .shader;
}

/// glShaderSource: the strings joined (lengths: each one's, negative
/// for a NUL-terminated one; null: all are).
pub fn shaderSource(c: *Context, name: u32, count: i32, strings: ?[*]const ?[*]const u8, lengths: ?[*]const i32) void {
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    if (count < 0) return c.fail(g.INVALID_VALUE);
    const n: usize = @intCast(count);
    var total: usize = 0;
    for (0..n) |i| total += partLen(strings, lengths, i);
    o.source = .{};
    const r = poolAlloc(total) orelse return c.fail(g.OUT_OF_MEMORY);
    var at: usize = r.at;
    for (0..n) |i| {
        const len = partLen(strings, lengths, i);
        if (len == 0) continue;
        @memcpy(pool[at..][0..len], strings.?[i].?[0..len]);
        at += len;
    }
    o.source = r;
    o.has_source = true;
}

fn partLen(strings: ?[*]const ?[*]const u8, lengths: ?[*]const i32, i: usize) usize {
    const s = (strings orelse return 0)[i] orelse return 0;
    if (lengths) |l| {
        if (l[i] >= 0) return @intCast(l[i]);
    }
    return std.mem.len(@as([*:0]const u8, @ptrCast(s)));
}

pub fn compileShader(c: *Context, name: u32) void {
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    o.compiled = scratch.compile(poolText(o.source), o.stage);
    o.log = .{};
    o.log = poolKeep(scratch.logText()) orelse .{};
}

pub fn getShaderiv(c: *Context, name: u32, pname: u32, out: *i32) void {
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    out.* = switch (pname) {
        g.SHADER_TYPE => @intCast(if (o.stage == .vertex) g.VERTEX_SHADER else g.FRAGMENT_SHADER),
        g.DELETE_STATUS => @intFromBool(o.doomed),
        g.COMPILE_STATUS => @intFromBool(o.compiled),
        g.INFO_LOG_LENGTH => logLen(o.log),
        g.SHADER_SOURCE_LENGTH => if (o.has_source and o.source.len > 0) @intCast(o.source.len + 1) else 0,
        else => return c.fail(g.INVALID_ENUM),
    };
}

pub fn getShaderInfoLog(c: *Context, name: u32, buf_size: i32, length: ?*i32, out: ?[*]u8) void {
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    if (buf_size < 0) return c.fail(g.INVALID_VALUE);
    copyOut(poolText(o.log), buf_size, length, out);
}

pub fn getShaderSource(c: *Context, name: u32, buf_size: i32, length: ?*i32, out: ?[*]u8) void {
    start();
    defer unlock();
    const o = shaderOf(c, name) orelse return;
    if (buf_size < 0) return c.fail(g.INVALID_VALUE);
    copyOut(poolText(o.source), buf_size, length, out);
}

/// The precision of what shaders compute: every precision is IEEE single
/// (and 32-bit integers) here.
pub fn getShaderPrecisionFormat(c: *Context, shader_type: u32, precision_type: u32, range: ?*[2]i32, precision: ?*i32) void {
    if (shader_type != g.VERTEX_SHADER and shader_type != g.FRAGMENT_SHADER) return c.fail(g.INVALID_ENUM);
    const is_float = switch (precision_type) {
        g.LOW_FLOAT, g.MEDIUM_FLOAT, g.HIGH_FLOAT => true,
        g.LOW_INT, g.MEDIUM_INT, g.HIGH_INT => false,
        else => return c.fail(g.INVALID_ENUM),
    };
    if (range) |x| x.* = if (is_float) .{ 127, 127 } else .{ 31, 30 };
    if (precision) |x| x.* = if (is_float) 23 else 0;
}

// ── Programs ───────────────────────────────────────────────────────────────

pub fn createProgram(c: *Context) u32 {
    start();
    defer unlock();
    const slot = for (&prog_used, 0..) |u, i| {
        if (!u) break i;
    } else {
        c.fail(g.OUT_OF_MEMORY);
        return 0;
    };
    const name = newName(c.objs, .program);
    if (name == 0) {
        c.fail(g.OUT_OF_MEMORY);
        return 0;
    }
    prog_used[slot] = true;
    objs[name - 1].prog = @intCast(slot);
    const p = &progs[slot];
    p.vs = 0;
    p.fs = 0;
    p.linked = false;
    p.validated = false;
    p.binary_hint = false;
    p.nbinds = 0;
    p.vs_src = .{};
    p.fs_src = .{};
    p.has_pipe = false;
    p.eng = null;
    p.out.nattribs = 0;
    p.out.nuniforms = 0;
    p.out.nlocs = 0;
    p.out.nvaryings = 0;
    p.out.noutputs = 0;
    p.out.nnames = 0;
    p.out.nwords = 0;
    p.out.nslots = 0;
    p.out.nblocks = 0;
    p.out.naliases = 0;
    p.out.nxfb = 0;
    p.out.ncapture = 0;
    p.out.xfb_stride = @splat(0);
    // (a slot used before: its transform feedback names went with it)
    p.xfb_names = .{};
    p.xfb_count = 0;
    p.xfb_mode = g.INTERLEAVED_ATTRIBS;
    return name;
}

pub fn deleteProgram(c: *Context, name: u32) void {
    if (name == 0) return;
    start();
    defer unlock();
    _ = programOf(c, name) orelse return;
    const o = &objs[name - 1];
    o.doomed = true;
    if (o.refs == 0) freeObj(o);
}

pub fn isProgram(c: *Context, name: u32) bool {
    start();
    defer unlock();
    const o = objOf(c, name) orelse return false;
    return o.kind == .program;
}

pub fn attachShader(c: *Context, prog: u32, shader: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const s = shaderOf(c, shader) orelse return;
    if (p.vs == shader or p.fs == shader) return c.fail(g.INVALID_OPERATION);
    const slot = if (s.stage == .vertex) &p.vs else &p.fs;
    if (slot.* != 0) return c.fail(g.INVALID_OPERATION);
    slot.* = shader;
    s.refs += 1;
}

pub fn detachShader(c: *Context, prog: u32, shader: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const s = shaderOf(c, shader) orelse return;
    if (p.vs == shader) p.vs = 0 else if (p.fs == shader) p.fs = 0 else return c.fail(g.INVALID_OPERATION);
    dropShader(s);
}

pub fn getAttachedShaders(c: *Context, prog: u32, max_count: i32, count: ?*i32, out: ?[*]u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (max_count < 0) return c.fail(g.INVALID_VALUE);
    var n: usize = 0;
    for ([_]u32{ p.vs, p.fs }) |s| {
        if (s == 0 or n >= @as(usize, @intCast(max_count))) continue;
        if (out) |o| o[n] = s;
        n += 1;
    }
    if (count) |x| x.* = @intCast(n);
}

pub fn bindAttribLocation(c: *Context, prog: u32, index: u32, name: [*:0]const u8) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (index >= MAX_ATTRIBS) return c.fail(g.INVALID_VALUE);
    const s = std.mem.span(name);
    if (std.mem.startsWith(u8, s, "gl_")) return c.fail(g.INVALID_OPERATION);
    if (s.len > 64) return c.fail(g.OUT_OF_MEMORY);
    for (p.binds[0..p.nbinds]) |*b| {
        if (std.mem.eql(u8, b.name[0..b.len], s)) {
            b.loc = index;
            return;
        }
    }
    if (p.nbinds == MAX_BINDINGS) return c.fail(g.OUT_OF_MEMORY);
    const b = &p.binds[p.nbinds];
    @memcpy(b.name[0..s.len], s);
    b.len = @intCast(s.len);
    b.loc = index;
    p.nbinds += 1;
}

/// Sets the program's log (pool text).
fn setLog(o: *Obj, s: []const u8) void {
    o.log = .{};
    o.log = poolKeep(s) orelse .{};
}

pub fn linkProgram(c: *Context, prog: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    // (the program transform feedback runs: GL ES 3.0 says no)
    if (c.feedbackOf()) |t| {
        if (t.active and t.program == prog) return c.fail(g.INVALID_OPERATION);
    }
    const o = &objs[prog - 1];
    var logbuf: [2048]u8 = undefined;
    var log = glsl.pp.Log{ .buf = &logbuf };
    p.unloadPipe();
    p.vs_src = .{};
    p.fs_src = .{};
    p.linked = link(p, &log);
    if (p.linked) p.eng = c.eng else report.say(.link, "a program did not link: {s}", .{report.firstLine(log.text())});
    if (p.linked) {
        // (whose shaders these are, for the context's usage line)
        var whose: report.Whose = .{};
        for (p.out.uniforms[0..p.out.nuniforms]) |u| whose.see(p.out.name(u.name));
        c.usage.linked(whose);
    }
    p.validated = false;
    setLog(o, log.text());
}

pub fn validateProgram(c: *Context, prog: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    p.validated = p.linked;
    if (!p.linked) setLog(&objs[prog - 1], "0:0: error: the program is not linked\n");
}

pub fn useProgram(c: *Context, prog: u32) void {
    start();
    defer unlock();
    if (c.feedbackOf()) |t| {
        if (t.active and !t.paused) return c.fail(g.INVALID_OPERATION);
    }
    if (prog != 0) {
        const p = programOf(c, prog) orelse return;
        if (!p.linked) return c.fail(g.INVALID_OPERATION);
        objs[prog - 1].refs += 1;
    }
    if (c.program != 0 and c.program <= MAX_NAMES) dropProgram(&objs[c.program - 1]);
    c.program = prog;
}

pub fn programParameteri(c: *Context, prog: u32, pname: u32, value: i32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    switch (pname) {
        g.PROGRAM_BINARY_RETRIEVABLE_HINT => {
            if (value != 0 and value != 1) return c.fail(g.INVALID_VALUE);
            p.binary_hint = value == 1;
        },
        else => c.fail(g.INVALID_ENUM),
    }
}

pub fn getProgramiv(c: *Context, prog: u32, pname: u32, out: *i32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const o = &objs[prog - 1];
    const l = &p.out;
    out.* = switch (pname) {
        g.DELETE_STATUS => @intFromBool(o.doomed),
        g.LINK_STATUS => @intFromBool(p.linked),
        g.VALIDATE_STATUS => @intFromBool(p.validated),
        g.INFO_LOG_LENGTH => logLen(o.log),
        g.ATTACHED_SHADERS => @as(i32, @intFromBool(p.vs != 0)) + @intFromBool(p.fs != 0),
        g.ACTIVE_ATTRIBUTES => if (p.linked) @intCast(l.nattribs) else 0,
        g.ACTIVE_ATTRIBUTE_MAX_LENGTH => blk: {
            if (!p.linked) break :blk 0;
            var m: usize = 0;
            for (l.attribs[0..l.nattribs]) |a| m = @max(m, a.name.len + 1);
            break :blk @intCast(m);
        },
        g.ACTIVE_UNIFORMS => if (p.linked) @intCast(l.nuniforms) else 0,
        g.ACTIVE_UNIFORM_MAX_LENGTH => blk: {
            if (!p.linked) break :blk 0;
            var m: usize = 0;
            for (l.uniforms[0..l.nuniforms]) |u| m = @max(m, l.apiName(u).len + 1 + @as(usize, if (u.ty.array != 0) 3 else 0));
            break :blk @intCast(m);
        },
        g.ACTIVE_UNIFORM_BLOCKS => if (p.linked) @intCast(l.nblocks) else 0,
        g.ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH => blk: {
            if (!p.linked) break :blk 0;
            var m: usize = 0;
            for (l.blocks[0..l.nblocks]) |b| m = @max(m, b.name.len + 1);
            break :blk @intCast(m);
        },
        g.TRANSFORM_FEEDBACK_BUFFER_MODE => @intCast(if (p.linked) l.xfb_mode else p.xfb_mode),
        g.TRANSFORM_FEEDBACK_VARYINGS => if (p.linked) @intCast(l.nxfb) else 0,
        g.TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH => blk: {
            if (!p.linked) break :blk 0;
            var m: usize = 0;
            for (l.xfb[0..l.nxfb]) |x| m = @max(m, x.name.len + 1);
            break :blk @intCast(m);
        },
        g.PROGRAM_BINARY_RETRIEVABLE_HINT => @intFromBool(p.binary_hint),
        g.PROGRAM_BINARY_LENGTH => if (p.linked) @intCast(binaryLength(p)) else 0,
        else => return c.fail(g.INVALID_ENUM),
    };
}

pub fn getProgramInfoLog(c: *Context, prog: u32, buf_size: i32, length: ?*i32, out: ?[*]u8) void {
    start();
    defer unlock();
    _ = programOf(c, prog) orelse return;
    if (buf_size < 0) return c.fail(g.INVALID_VALUE);
    copyOut(poolText(objs[prog - 1].log), buf_size, length, out);
}

// ── Program binaries ───────────────────────────────────────────────────────
//
// glGetProgramBinary writes what the link made (progbin.sig's format: the
// interface tables, the pipeline's flags, both stages' kept code) and
// glProgramBinary takes it back, refusing a binary of another driver
// build, of another GPU, or a damaged one: then the program is not linked
// and its log says why (no GL error: GL ES 3.0 lets a binary be refused
// so, and the app links from source again). A binary taken is a link as
// the one that wrote it: the same locations, uniforms (their values zero,
// as after a link), blocks (each at binding 0, as after a link) and
// transform feedback, without compiling or checking the code again; the
// draws' kernels are made from the kept code at the first draw, as after
// a link.

/// The bytes glGetProgramBinary writes for a linked program.
fn binaryLength(p: *const Program) usize {
    var w = progbin.Writer.counter();
    encodeBinary(p, &w);
    return w.n;
}

fn gpuIdOf(c: *Context) u64 {
    return progbin.gpuId(if (c.eng.dev) |d| d.caps else null);
}

fn putName(w: *progbin.Writer, n: Name) void {
    w.u_16(n.at);
    w.u_16(n.len);
}

fn encodeBinary(p: *const Program, w: *progbin.Writer) void {
    const l = &p.out;
    w.begin(progbin.LINK);
    w.u_32(l.version);
    w.u_32(@intCast(l.nnames));
    w.bytes(l.names[0..l.nnames]);
    w.u_32(@intCast(l.nattribs));
    for (l.attribs[0..l.nattribs]) |a| {
        putName(w, a.name);
        w.u_32(a.ty.bits());
        w.u_32(a.loc);
    }
    w.u_32(@intCast(l.nuniforms));
    for (l.uniforms[0..l.nuniforms]) |u| {
        putName(w, u.name);
        w.u_32(u.ty.bits());
        w.u_32(u.loc);
        w.u_32(u.word);
        w.u_8(u.stages);
        putName(w, u.api);
        w.u_16(@bitCast(u.block));
        w.u_32(u.offset);
        w.u_32(u.array_stride);
        w.u_32(u.matrix_stride);
        w.flag(u.row_major);
    }
    w.u_32(@intCast(l.nlocs));
    for (l.locs[0..l.nlocs]) |x| w.u_16(x);
    w.u_32(@intCast(l.nvaryings));
    for (l.varyings[0..l.nvaryings]) |v| {
        putName(w, v.name);
        w.u_32(v.ty.bits());
        w.flag(v.flat);
        w.u_32(v.word);
    }
    w.u_32(l.vary_words);
    w.u_32(@intCast(l.noutputs));
    for (l.outputs[0..l.noutputs]) |o| {
        putName(w, o.name);
        w.u_32(o.ty.bits());
        w.u_32(o.loc);
    }
    w.flag(l.frag_color);
    w.flag(l.frag_data);
    w.u_32(l.nwords);
    w.u_32(@intCast(l.nslots));
    for (l.slots[0..l.nslots]) |sl| {
        w.u_32(sl.word);
        var bits: u8 = 0;
        for ([_]bool{ sl.external, sl.array, sl.volume, sl.cube, sl.shadow, sl.unsupported }, 0..) |b, i| bits |= @as(u8, @intFromBool(b)) << @intCast(i);
        w.u_8(bits);
        w.u_8(@intCast(@backingInt(sl.kind)));
    }
    w.u_32(@intCast(l.nblocks));
    for (l.blocks[0..l.nblocks]) |b| {
        putName(w, b.name);
        w.u_32(b.size);
        w.u_8(b.stages);
        w.u_32(b.members);
    }
    w.u_32(@intCast(l.naliases));
    for (l.aliases[0..l.naliases]) |a| {
        putName(w, a.name);
        w.u_32(a.word);
    }
    w.u_32(@intCast(l.nxfb));
    for (l.xfb[0..l.nxfb]) |x| {
        putName(w, x.name);
        w.u_32(x.ty.bits());
        w.u_8(x.buffer);
        w.u_32(x.word);
    }
    w.u_32(@intCast(l.ncapture));
    for (l.capture[0..l.ncapture]) |cp| {
        w.flag(cp.position);
        w.u_8(cp.src);
        w.u_8(cp.buffer);
        w.u_16(cp.word);
    }
    for (l.xfb_stride) |x| w.u_32(x);
    w.u_32(l.xfb_mode);
    w.end();
    const sh = &p.pipe.shaders;
    w.begin(progbin.PIPE);
    w.flag(sh.quads);
    w.flag(sh.point_size);
    w.flag(sh.point_coord);
    w.flag(sh.frag_depth);
    w.end();
    w.begin(progbin.VSRC);
    w.bytes(poolText(p.vs_src));
    w.end();
    w.begin(progbin.FSRC);
    w.bytes(poolText(p.fs_src));
    w.end();
}

/// A name read back: inside the names read.
fn getName(r: *progbin.Reader, nnames: usize) Name {
    const n = Name{ .at = r.u_16(), .len = r.u_16() };
    if (@as(usize, n.at) + n.len > nnames) r.bad = true;
    return n;
}

/// A type read back: one of GLSL's bases.
fn getType(r: *progbin.Reader) Type {
    const bits = r.u_32();
    if (bits & 0x1f > @backingInt(glsl.Base.err)) {
        r.bad = true;
        return .{};
    }
    return Type.of(bits);
}

fn elemsOf(t: Type) u32 {
    return if (t.array != 0) t.array else 1;
}

/// The LINK section into the program's tables, each count and index
/// checked against them (what a draw or a query indexes stays inside).
fn decodeLinked(l: *Linked, r: *progbin.Reader) bool {
    l.version = r.u_32();
    if (l.version != 100 and l.version != 300) return false;
    l.nnames = r.count(PROGRAM_NAMES);
    const names = r.bytes(l.nnames);
    if (r.bad) return false;
    @memcpy(l.names[0..l.nnames], names);
    const nn = l.nnames;
    l.nattribs = r.count(MAX_ATTRIBS);
    for (l.attribs[0..l.nattribs]) |*a| {
        a.* = .{ .name = getName(r, nn), .ty = getType(r), .loc = r.u_32() };
        if (r.bad or a.loc + slotsOf(a.ty) > MAX_ATTRIBS) return false;
    }
    l.nuniforms = r.count(MAX_UNIFORMS);
    for (l.uniforms[0..l.nuniforms]) |*u| {
        u.* = .{ .name = getName(r, nn), .ty = getType(r), .loc = r.u_32(), .word = r.u_32(), .stages = r.u_8() };
        u.api = getName(r, nn);
        u.block = @bitCast(r.u_16());
        u.offset = r.u_32();
        u.array_stride = r.u_32();
        u.matrix_stride = r.u_32();
        u.row_major = r.flag();
    }
    l.nlocs = r.count(MAX_LOCATIONS);
    for (l.locs[0..l.nlocs]) |*x| {
        x.* = r.u_16();
        if (x.* >= l.nuniforms) return false;
    }
    l.nvaryings = r.count(MAX_VARYINGS);
    for (l.varyings[0..l.nvaryings]) |*v| {
        v.* = .{ .name = getName(r, nn), .ty = getType(r), .flat = r.flag(), .word = r.u_32() };
    }
    l.vary_words = r.u_32();
    if (r.bad or l.vary_words > raster.MAX_VARYINGS) return false;
    for (l.varyings[0..l.nvaryings]) |v| {
        if (v.word + wordsOf(v.ty) > l.vary_words) return false;
    }
    l.noutputs = r.count(MAX_OUTPUTS);
    for (l.outputs[0..l.noutputs]) |*o| {
        o.* = .{ .name = getName(r, nn), .ty = getType(r), .loc = r.u_32() };
        if (r.bad or o.loc + elemsOf(o.ty) > MAX_OUTPUTS) return false;
    }
    l.frag_color = r.flag();
    l.frag_data = r.flag();
    l.nwords = r.u_32();
    if (r.bad or l.nwords > UNIFORM_WORDS) return false;
    l.nslots = r.count(texture.MAX_TEX);
    for (l.slots[0..l.nslots]) |*sl| {
        const word = r.u_32();
        const bits = r.u_8();
        const kind = r.u_8();
        if (r.bad or word >= l.nwords or bits >= 1 << 6 or kind > @backingInt(texture.Kind.uint)) return false;
        sl.* = .{ .word = word, .external = bits & 1 != 0, .array = bits & 2 != 0, .volume = bits & 4 != 0, .cube = bits & 8 != 0, .shadow = bits & 16 != 0, .unsupported = bits & 32 != 0, .kind = @fromBackingInt(@intCast(kind)) };
    }
    l.nblocks = r.count(MAX_BLOCKS);
    for (l.blocks[0..l.nblocks]) |*b| {
        b.* = .{ .name = getName(r, nn), .size = r.u_32(), .stages = r.u_8(), .members = r.u_32() };
        if (r.bad or b.size > MAX_UNIFORM_BLOCK_SIZE) return false;
    }
    // (the uniforms, now their blocks and words are known)
    for (l.uniforms[0..l.nuniforms]) |u| {
        if (u.word + wordsOf(u.ty) > l.nwords) return false;
        if (u.block >= 0) {
            if (u.block >= l.nblocks) return false;
        } else if (u.block != -1 or u.loc + elemsOf(u.ty) > l.nlocs) return false;
    }
    l.naliases = r.count(MAX_ALIASES);
    for (l.aliases[0..l.naliases]) |*a| {
        a.* = .{ .name = getName(r, nn), .word = r.u_32() };
        if (a.word >= l.nwords) return false;
    }
    l.nxfb = r.count(MAX_XFB);
    for (l.xfb[0..l.nxfb]) |*x| {
        x.* = .{ .name = getName(r, nn), .ty = getType(r), .buffer = r.u_8(), .word = r.u_32() };
        if (r.bad or x.buffer >= raster.MAX_CAPTURE_BUFFERS) return false;
    }
    l.ncapture = r.count(l.capture.len);
    for (l.capture[0..l.ncapture]) |*cp| {
        cp.* = .{ .position = r.flag(), .src = r.u_8(), .buffer = r.u_8(), .word = r.u_16() };
        if (r.bad or cp.buffer >= raster.MAX_CAPTURE_BUFFERS or cp.word >= MAX_XFB_COMPONENTS) return false;
        if (if (cp.position) cp.src >= 4 else cp.src >= l.vary_words) return false;
    }
    for (&l.xfb_stride) |*x| {
        x.* = r.u_32();
        if (x.* > MAX_XFB_COMPONENTS) return false;
    }
    l.xfb_mode = r.u_32();
    if (l.xfb_mode != g.INTERLEAVED_ATTRIBS and l.xfb_mode != g.SEPARATE_ATTRIBS) return false;
    // (the values: zero, as after a link)
    @memset(l.values[0..l.nwords], 0);
    return r.done();
}

/// A binary's program into `p` (its tables, pipeline and kept code), or
/// why not. The header is checked before anything is read.
fn decodeBinary(c: *Context, p: *Program, bin: []const u8) ?progbin.Refusal {
    if (progbin.check(bin, gpuIdOf(c))) |why| return why;
    var r = progbin.Reader.of(bin);
    var link_s = r.section(progbin.LINK);
    if (!decodeLinked(&p.out, &link_s)) return .malformed;
    var pipe_s = r.section(progbin.PIPE);
    const f = PipeFlags{ .quads = pipe_s.flag(), .point_size = pipe_s.flag(), .point_coord = pipe_s.flag(), .frag_depth = pipe_s.flag() };
    if (!pipe_s.done()) return .malformed;
    var vs_s = r.section(progbin.VSRC);
    const vs = vs_s.bytes(vs_s.b.len);
    var fs_s = r.section(progbin.FSRC);
    const fs = fs_s.bytes(fs_s.b.len);
    if (!r.done() or vs.len == 0 or fs.len == 0) return .malformed;
    if (vs.len > glsl.MAX_SOURCE or fs.len > glsl.MAX_SOURCE) return .too_large;
    p.vs_src = poolKeep(vs) orelse return .too_large;
    p.fs_src = poolKeep(fs) orelse return .too_large;
    makePipe(p, f);
    return null;
}

/// glGetProgramBinary: the linked program's binary into `out` (bufSize at
/// least PROGRAM_BINARY_LENGTH), its format progbin.FORMAT.
pub fn getProgramBinary(c: *Context, prog: u32, buf_size: i32, length: ?*i32, format: ?*u32, out: ?[*]u8) void {
    start();
    defer unlock();
    if (length) |x| x.* = 0;
    const p = programOf(c, prog) orelse return;
    if (buf_size < 0) return c.fail(g.INVALID_VALUE);
    if (!p.linked) return c.fail(g.INVALID_OPERATION);
    const n = binaryLength(p);
    if (@as(usize, @intCast(buf_size)) < n) return c.fail(g.INVALID_OPERATION);
    const buf = out orelse return c.fail(g.INVALID_OPERATION);
    var w = progbin.Writer.into(buf[0..n]);
    encodeBinary(p, &w);
    const bin = w.finish(gpuIdOf(c)) orelse return c.fail(g.INVALID_OPERATION);
    if (length) |x| x.* = @intCast(bin.len);
    if (format) |x| x.* = progbin.FORMAT;
}

/// glProgramBinary: a binary glGetProgramBinary wrote, taken as a link,
/// or refused (the program then not linked, its log saying why).
pub fn programBinary(c: *Context, prog: u32, format: u32, binary: ?[*]const u8, length: i32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (format != progbin.FORMAT) return c.fail(g.INVALID_ENUM);
    if (length < 0 or (length > 0 and binary == null)) return c.fail(g.INVALID_VALUE);
    if (c.feedbackOf()) |t| {
        if (t.active and t.program == prog) return c.fail(g.INVALID_OPERATION);
    }
    const o = &objs[prog - 1];
    p.unloadPipe();
    p.vs_src = .{};
    p.fs_src = .{};
    p.linked = false;
    p.validated = false;
    const bin: []const u8 = if (length == 0) &.{} else binary.?[0..@intCast(length)];
    if (decodeBinary(c, p, bin)) |why| {
        // (whatever was read goes: the program is not linked)
        p.vs_src = .{};
        p.fs_src = .{};
        p.has_pipe = false;
        report.say(.link, "a program binary was refused: {s}", .{why.text()});
        var buf: [160]u8 = undefined;
        setLog(o, std.fmt.bufPrint(&buf, "0:0: error: {s}\n", .{why.text()}) catch why.text());
        return;
    }
    p.linked = true;
    p.eng = c.eng;
    var whose: report.Whose = .{};
    for (p.out.uniforms[0..p.out.nuniforms]) |u| whose.see(p.out.name(u.name));
    c.usage.linked(whose);
    setLog(o, "");
}

// ── The link ───────────────────────────────────────────────────────────────

fn compileFor(s: *Obj, out: *glsl.Iface, log: *glsl.pp.Log, what: []const u8) bool {
    if (!s.compiled) {
        log.err(0, "the {s} shader did not compile", .{what});
        return false;
    }
    if (!scratch.compile(poolText(s.source), s.stage) or !scratch.interface(out)) {
        log.err(0, "the {s} shader: {s}", .{ what, if (out.overflow) "its interface is too large" else "it no longer compiles" });
        return false;
    }
    if (!out.has_main) {
        log.err(0, "the {s} shader has no main()", .{what});
        return false;
    }
    return true;
}

/// Locations an attribute takes (a matrix: one per column).
fn slotsOf(t: Type) u32 {
    return if (t.matrix()) t.cols else 1;
}

/// Words a uniform or varying takes: an element's components (a sampler: one) times its elements.
fn wordsOf(t: Type) u32 {
    const per: u32 = if (t.sampler()) 1 else t.comps();
    return per * (if (t.array != 0) @as(u32, t.array) else 1);
}

fn link(p: *Program, log: *glsl.pp.Log) bool {
    const l = &p.out;
    l.nattribs = 0;
    l.nuniforms = 0;
    l.nlocs = 0;
    l.nvaryings = 0;
    l.vary_words = 0;
    l.noutputs = 0;
    l.nnames = 0;
    l.nwords = 0;
    l.nblocks = 0;
    l.naliases = 0;
    l.frag_color = false;
    l.frag_data = false;
    if (p.vs == 0 or p.fs == 0) {
        log.err(0, "a program needs a vertex shader and a fragment shader", .{});
        return false;
    }
    if (!compileFor(&objs[p.vs - 1], &iface_vs, log, "vertex")) return false;
    if (!compileFor(&objs[p.fs - 1], &iface_fs, log, "fragment")) return false;
    const vs = &iface_vs;
    const fs = &iface_fs;
    if (vs.version != fs.version) {
        log.err(0, "the vertex shader is GLSL ES {d}, the fragment shader {d}", .{ vs.version, fs.version });
        return false;
    }
    l.version = vs.version;
    if (!linkAttribs(p, vs, log)) return false;
    if (!linkVaryings(l, vs, fs, log)) return false;
    if (!linkFeedback(p, vs, log)) return false;
    if (!linkUniforms(l, vs, fs, log)) return false;
    if (!linkOutputs(l, fs, log)) return false;
    if (!linkSlots(l, log)) return false;
    @memset(l.values[0..l.nwords], 0);
    // the sources kept, the code checked, the pipeline made
    p.vs_src = poolDup(&objs[p.vs - 1].source) orelse return outOfPool(log);
    p.fs_src = poolDup(&objs[p.fs - 1].source) orelse return outOfPool(log);
    var quads = false;
    if (!checkCode(p, log, &quads)) return false;
    makePipe(p, .{ .quads = quads, .point_size = vs.point_size, .point_coord = fs.point_coord, .frag_depth = fs.frag_depth });
    return true;
}

/// What the pipeline takes from the shaders' code rather than from the
/// interface: a program binary keeps these too.
const PipeFlags = struct { quads: bool = false, point_size: bool = false, point_coord: bool = false, frag_depth: bool = false };

/// The linked program's pipeline (its draws' kernels come from the kept
/// sources when the engine builds them).
fn makePipe(p: *Program, f: PipeFlags) void {
    const l = &p.out;
    var attrs: u32 = 0;
    for (l.attribs[0..l.nattribs]) |a| attrs = @max(attrs, a.loc + slotsOf(a.ty));
    var flat: u64 = 0;
    for (l.varyings[0..l.nvaryings]) |v| {
        if (!v.flat) continue;
        for (0..wordsOf(v.ty)) |w| flat |= @as(u64, 1) << @intCast(v.word + w);
    }
    p.pipe = raster.Pipeline.init(.{ .ctx = p, .attrs = @intCast(attrs), .varyings = @intCast(l.vary_words), .flat = flat, .textures = @intCast(l.nslots), .quads = f.quads, .capture = l.capture[0..l.ncapture], .capture_stride = l.xfb_stride, .point_size = f.point_size, .point_coord = f.point_coord, .frag_depth = f.frag_depth, .vertex = emitVertex, .fragment = emitFragment });
    p.has_pipe = true;
}

fn outOfPool(log: *glsl.pp.Log) bool {
    log.err(0, "no room to keep the program's sources", .{});
    return false;
}

// ── The code ───────────────────────────────────────────────────────────────

fn layAttrib(ctx: *const anyopaque, name: []const u8) ?u32 {
    const l = &@as(*const Program, @ptrCast(@alignCast(ctx))).out;
    for (l.attribs[0..l.nattribs]) |a| {
        if (std.mem.eql(u8, l.name(a.name), name)) return a.loc;
    }
    return null;
}

/// A uniform's first word: its own, or its first leaf's ("s.m", "s[0].m").
fn layUniform(ctx: *const anyopaque, name: []const u8) ?u32 {
    const l = &@as(*const Program, @ptrCast(@alignCast(ctx))).out;
    for (l.uniforms[0..l.nuniforms]) |un| {
        const nm = l.name(un.name);
        if (std.mem.eql(u8, nm, name)) return un.word;
        if (nm.len > name.len and std.mem.startsWith(u8, nm, name) and (nm[name.len] == '.' or nm[name.len] == '[')) return un.word;
    }
    // (a block's members as another shader names its instance)
    for (l.aliases[0..l.naliases]) |a| {
        const nm = l.name(a.name);
        if (std.mem.eql(u8, nm, name)) return a.word;
        if (nm.len > name.len and std.mem.startsWith(u8, nm, name) and (nm[name.len] == '.' or nm[name.len] == '[')) return a.word;
    }
    return null;
}

fn layVarying(ctx: *const anyopaque, name: []const u8) ?u32 {
    const l = &@as(*const Program, @ptrCast(@alignCast(ctx))).out;
    for (l.varyings[0..l.nvaryings]) |v| {
        if (std.mem.eql(u8, l.name(v.name), name)) return v.word;
    }
    return null;
}

fn layOutput(ctx: *const anyopaque, name: []const u8) ?u32 {
    const l = &@as(*const Program, @ptrCast(@alignCast(ctx))).out;
    for (l.outputs[0..l.noutputs]) |o| {
        if (std.mem.eql(u8, l.name(o.name), name)) return o.loc;
    }
    return null;
}

fn laySampler(ctx: *const anyopaque, word: u32) ?u32 {
    const l = &@as(*const Program, @ptrCast(@alignCast(ctx))).out;
    for (l.slots[0..l.nslots], 0..) |s, i| {
        if (s.word == word) return @intCast(i);
    }
    return null;
}

fn layoutOf(p: *const Program) glsl.gen.Layout {
    return .{ .ctx = p, .attrib = layAttrib, .uniform = layUniform, .varying = layVarying, .output = layOutput, .sampler = laySampler, .desc_base = p.out.nwords };
}

/// A texture slot for each sampler the program uses (an array's each
/// element).
fn linkSlots(l: *Linked, log: *glsl.pp.Log) bool {
    l.nslots = 0;
    for (l.uniforms[0..l.nuniforms]) |un| {
        const t = un.ty.elem();
        if (!t.sampler()) continue;
        const kind: texture.Kind = switch (t.base) {
            .isampler2D, .isampler3D, .isamplerCube, .isampler2DArray => .int,
            .usampler2D, .usampler3D, .usamplerCube, .usampler2DArray => .uint,
            else => .float,
        };
        const shadow = t.base == .sampler2DShadow or t.base == .sampler2DArrayShadow or t.base == .samplerCubeShadow;
        const array = t.base == .sampler2DArray or t.base == .isampler2DArray or t.base == .usampler2DArray or t.base == .sampler2DArrayShadow;
        const volume = t.base == .sampler3D or t.base == .isampler3D or t.base == .usampler3D;
        const cube = t.base == .samplerCube or t.base == .isamplerCube or t.base == .usamplerCube or t.base == .samplerCubeShadow;
        const supported = shadow or array or volume or cube or t.base == .sampler2D or t.base == .isampler2D or t.base == .usampler2D or t.base == .samplerExternalOES;
        const n: u32 = if (un.ty.array != 0) un.ty.array else 1;
        for (0..n) |e| {
            if (l.nslots == texture.MAX_TEX) {
                log.err(0, "too many samplers ({d} at most)", .{texture.MAX_TEX});
                return false;
            }
            l.slots[l.nslots] = .{ .word = un.word + @as(u32, @intCast(e)), .external = t.base == .samplerExternalOES, .array = array, .volume = volume, .cube = cube, .shadow = shadow, .kind = kind, .unsupported = !supported };
            l.nslots += 1;
        }
    }
    return true;
}

/// The vertex shader's code in a draw's vertex kernel (the engine builds
/// it: at the pipeline's first draw on the GPU, at every draw on the CPU).
fn emitVertex(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
    const p: *const Program = @ptrCast(@alignCast(ctx.?));
    start();
    defer unlock();
    var logbuf: [256]u8 = undefined;
    var log = glsl.pp.Log{ .buf = &logbuf };
    if (!scratch.compile(poolText(p.vs_src), .vertex) or !glsl.gen.vertex(&scratch, layoutOf(p), k, io, &log)) {
        if (k.err == null) k.err = error.BadOperand;
    }
}

fn emitFragment(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
    const p: *const Program = @ptrCast(@alignCast(ctx.?));
    start();
    defer unlock();
    var logbuf: [256]u8 = undefined;
    var log = glsl.pp.Log{ .buf = &logbuf };
    if (!scratch.compile(poolText(p.fs_src), .fragment) or !glsl.gen.fragment(&scratch, layoutOf(p), k, io, &log)) {
        if (k.err == null) k.err = error.BadOperand;
    }
}

var check_insts: [engine.MAX_KIR]kir.Inst = undefined;
var check_tys: [engine.MAX_KIR]kir.Ty = undefined;

/// Both shaders generated once, into a kernel of their own, and verified:
/// what cannot be generated fails the link, not a draw. `quads`: the
/// fragment shader takes derivatives (its draws run whole quads).
fn checkCode(p: *const Program, log: *glsl.pp.Log, quads: *bool) bool {
    const st = kir.Storage{ .insts = &check_insts, .tys = &check_tys };
    {
        var k = kir.Kernel.init(st, "glsl_vertex", .{ raster.VERTEX_GROUP, 1, 1 });
        var io = raster.VertexIO{ .uniforms = k.binding() };
        io.textures = k.bindings;
        for (0..p.out.nslots) |_| _ = k.binding();
        for (&io.attr) |*a| {
            for (a) |*c| c.* = k.reg(.u32);
        }
        io.vertex_id = k.reg(.u32);
        io.instance_id = k.reg(.u32);
        if (!scratch.compile(poolText(p.vs_src), .vertex)) return codeFailed(log, "vertex", "it no longer compiles");
        if (!glsl.gen.vertex(&scratch, layoutOf(p), &k, &io, log)) return codeFailed(log, "vertex", "");
        for (io.position) |v| {
            if (v != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(v));
        }
        if (io.point_size != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(io.point_size));
        k.finish() catch |err| return codeFailed(log, "vertex", @errorName(err));
    }
    {
        var k = kir.Kernel.init(st, "glsl_fragment", .{ raster.TILE, raster.TILE, 1 });
        var io = raster.FragmentIO{ .uniforms = k.binding() };
        io.textures = k.bindings;
        for (0..p.out.nslots) |_| _ = k.binding();
        for (&io.varying) |*v| v.* = k.reg(.f32);
        for (&io.frag_coord) |*v| v.* = k.reg(.f32);
        io.front_facing = k.reg(.pred);
        io.point_coord = .{ k.reg(.f32), k.reg(.f32) };
        io.quads = true;
        io.odd_x = k.reg(.pred);
        io.odd_y = k.reg(.pred);
        if (!scratch.compile(poolText(p.fs_src), .fragment)) return codeFailed(log, "fragment", "it no longer compiles");
        if (!glsl.gen.fragment(&scratch, layoutOf(p), &k, &io, log)) return codeFailed(log, "fragment", "");
        quads.* = io.derivatives;
        for (io.color) |v| {
            if (v != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(v));
        }
        // (the other outputs, gl_FragDepth: their code checked too)
        for (io.colors[1..]) |cs| {
            for (cs) |v| {
                if (v != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(v));
            }
        }
        if (io.depth != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(io.depth));
        k.finish() catch |err| return codeFailed(log, "fragment", @errorName(err));
    }
    return true;
}

fn codeFailed(log: *glsl.pp.Log, what: []const u8, why: []const u8) bool {
    if (why.len > 0) log.err(0, "the {s} shader's code: {s}", .{ what, why });
    return false;
}

pub const DrawState = struct {
    pipe: *raster.Pipeline,
    uniforms: []const u32,
    slots: []const Slot,
    /// transform feedback: each buffer's words a vertex (0: not captured)
    xfb_stride: [raster.MAX_CAPTURE_BUFFERS]u32 = @splat(0),
};

/// What a draw with the program in use runs: its pipeline and uniforms.
pub fn drawState(c: *Context) ?DrawState {
    start();
    defer unlock();
    if (c.program == 0 or c.program > MAX_NAMES) return null;
    const o = &objs[c.program - 1];
    if (o.kind != .program) return null;
    const p = &progs[o.prog];
    if (!p.has_pipe) return null;
    if (p.eng == null) p.eng = c.eng;
    return .{ .pipe = &p.pipe, .uniforms = p.out.values[0..p.out.nwords], .slots = p.out.slots[0..p.out.nslots], .xfb_stride = p.out.xfb_stride };
}

fn linkAttribs(p: *Program, vs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    const l = &p.out;
    var taken: u32 = 0; // a bit per location
    var where: [glsl.MAX_IVARS]u32 = undefined;
    // first the placed ones (a layout location, then glBindAttribLocation's), then the rest
    for (0..2) |pass| {
        for (vs.vars[0..vs.n], 0..) |v, vi| {
            if (v.kind != .input or !v.used) continue;
            const nm = vs.name(v);
            const placed: ?u32 = if (v.loc >= 0) @intCast(v.loc) else p.boundTo(nm);
            if ((pass == 0) != (placed != null)) continue;
            const n = slotsOf(v.ty);
            const mask = (@as(u32, 1) << @intCast(n)) - 1;
            var at: u32 = 0;
            if (placed) |x| {
                at = x;
                if (at + n > MAX_ATTRIBS) {
                    log.err(0, "attribute `{s}` at {d} does not fit ({d} locations)", .{ nm, at, MAX_ATTRIBS });
                    return false;
                }
                if (taken & (mask << @intCast(at)) != 0) {
                    log.err(0, "attribute `{s}`: location {d} is another attribute's", .{ nm, at });
                    return false;
                }
            } else {
                while (at + n <= MAX_ATTRIBS and taken & (mask << @intCast(at)) != 0) at += 1;
                if (at + n > MAX_ATTRIBS) {
                    log.err(0, "too many vertex attributes ({d} locations)", .{MAX_ATTRIBS});
                    return false;
                }
            }
            taken |= mask << @intCast(at);
            where[vi] = at;
        }
    }
    // (listed in the order the shader declares them, as Mesa lists them)
    for (vs.vars[0..vs.n], 0..) |v, vi| {
        if (v.kind != .input or !v.used) continue;
        if (l.nattribs == MAX_ATTRIBS) {
            log.err(0, "too many vertex attributes", .{});
            return false;
        }
        const kept = l.keep(vs.name(v)) orelse return tooLong(log);
        l.attribs[l.nattribs] = .{ .name = kept, .ty = v.ty, .loc = where[vi] };
        l.nattribs += 1;
    }
    return true;
}

fn tooLong(log: *glsl.pp.Log) bool {
    log.err(0, "the program's names are too long ({d} bytes at most)", .{PROGRAM_NAMES});
    return false;
}

fn findVar(f: *const glsl.Iface, kind: glsl.IKind, nm: []const u8) ?glsl.IVar {
    for (f.vars[0..f.n]) |v| {
        if (v.kind == kind and std.mem.eql(u8, f.name(v), nm)) return v;
    }
    return null;
}

fn linkVaryings(l: *Linked, vs: *const glsl.Iface, fs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    for (fs.vars[0..fs.n]) |v| {
        if (v.kind != .input) continue;
        const nm = fs.name(v);
        const w = findVar(vs, .output, nm) orelse {
            if (!v.used) continue;
            log.err(0, "the fragment shader's `{s}` is not an output of the vertex shader", .{nm});
            return false;
        };
        if (!w.ty.eq(v.ty)) {
            log.err(0, "varying `{s}`: the shaders give it different types", .{nm});
            return false;
        }
        const flat = v.q & glsl.Q.flat != 0;
        if (l.version >= 300 and flat != (w.q & glsl.Q.flat != 0)) {
            log.err(0, "varying `{s}`: flat in one shader, not in the other", .{nm});
            return false;
        }
        if (l.nvaryings == MAX_VARYINGS or l.vary_words + wordsOf(v.ty) > MAX_VARYING_VECTORS * 4) {
            log.err(0, "too many varyings ({d} vectors at most)", .{MAX_VARYING_VECTORS});
            return false;
        }
        const kept = l.keep(nm) orelse return tooLong(log);
        l.varyings[l.nvaryings] = .{ .name = kept, .ty = v.ty, .flat = flat, .word = l.vary_words };
        l.nvaryings += 1;
        l.vary_words += wordsOf(v.ty);
    }
    return true;
}

fn linkUniforms(l: *Linked, vs: *const glsl.Iface, fs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    // a uniform both shaders declare: one type
    for (vs.vars[0..vs.n]) |v| {
        if (v.kind != .uniform) continue;
        const w = findVar(fs, .uniform, vs.name(v)) orelse continue;
        if (!w.ty.eq(v.ty)) {
            log.err(0, "uniform `{s}`: the shaders give it different types", .{vs.name(v)});
            return false;
        }
    }
    for ([_]*const glsl.Iface{ vs, fs }, 0..) |f, si| {
        const bit: u8 = @as(u8, 1) << @intCast(si);
        for (f.vars[0..f.n]) |v| {
            if (v.kind != .uniform or !v.used) continue;
            const nm = f.name(v);
            if (v.block != 0) {
                if (!linkBlockMember(l, f, v, bit, log)) return false;
                continue;
            }
            if (l.findUniform(nm)) |u| {
                if (u.block >= 0) {
                    log.err(0, "uniform `{s}`: one shader puts it in a uniform block, the other outside", .{nm});
                    return false;
                }
                @constCast(u).stages |= bit;
                continue;
            }
            const elems: u32 = if (v.ty.array != 0) v.ty.array else 1;
            if (l.nuniforms == MAX_UNIFORMS or l.nlocs + elems > MAX_LOCATIONS) {
                log.err(0, "too many uniforms", .{});
                return false;
            }
            if (l.nwords + wordsOf(v.ty) > UNIFORM_WORDS) {
                log.err(0, "the uniforms are too large ({d} words at most)", .{UNIFORM_WORDS});
                return false;
            }
            const kept = l.keep(nm) orelse return tooLong(log);
            l.uniforms[l.nuniforms] = .{ .name = kept, .ty = v.ty, .loc = @intCast(l.nlocs), .word = l.nwords, .stages = bit };
            for (0..elems) |_| {
                l.locs[l.nlocs] = @intCast(l.nuniforms);
                l.nlocs += 1;
            }
            l.nuniforms += 1;
            l.nwords += wordsOf(v.ty);
        }
    }
    return true;
}

/// A uniform block's member: its block (one by its name, laid out alike
/// in both shaders), its words (no location), GL's name ("Block.m" for an
/// instance's "inst.m").
fn linkBlockMember(l: *Linked, f: *const glsl.Iface, v: glsl.IVar, bit: u8, log: *glsl.pp.Log) bool {
    const ib = f.blocks[v.block - 1];
    const bname = f.blockName(ib);
    const nm = f.name(v);
    var api_buf: [512]u8 = undefined;
    const api = if (ib.inst_len > 0) (std.fmt.bufPrint(&api_buf, "{s}{s}", .{ bname, nm[ib.inst_len..] }) catch return tooLong(log)) else nm;
    const bi: usize = for (l.blocks[0..l.nblocks], 0..) |b, i| {
        if (std.mem.eql(u8, l.name(b.name), bname)) break i;
    } else blk: {
        if (l.nblocks == MAX_BLOCKS) {
            log.err(0, "too many uniform blocks ({d} at most)", .{MAX_BLOCKS});
            return false;
        }
        if (ib.size > MAX_UNIFORM_BLOCK_SIZE) {
            log.err(0, "uniform block `{s}` is {d} bytes ({d} at most)", .{ bname, ib.size, MAX_UNIFORM_BLOCK_SIZE });
            return false;
        }
        const kept = l.keep(bname) orelse return tooLong(log);
        l.blocks[l.nblocks] = .{ .name = kept, .size = ib.size };
        l.nblocks += 1;
        break :blk l.nblocks - 1;
    };
    const b = &l.blocks[bi];
    if (b.size != ib.size) {
        log.err(0, "uniform block `{s}`: the shaders lay it out differently", .{bname});
        return false;
    }
    b.stages |= bit;
    if (l.findApi(api)) |found| {
        const u = @constCast(found);
        if (u.block != @as(i16, @intCast(bi)) or !u.ty.eq(v.ty) or u.offset != v.offset or u.row_major != v.row_major) {
            log.err(0, "uniform block `{s}`: the shaders declare `{s}` differently", .{ bname, api });
            return false;
        }
        u.stages |= bit;
        if (!std.mem.eql(u8, l.name(u.name), nm)) {
            // (this shader names the instance otherwise: the same words)
            if (l.naliases == MAX_ALIASES) {
                log.err(0, "too many uniform block instances", .{});
                return false;
            }
            l.aliases[l.naliases] = .{ .name = l.keep(nm) orelse return tooLong(log), .word = u.word };
            l.naliases += 1;
        }
        return true;
    }
    if (l.nuniforms == MAX_UNIFORMS) {
        log.err(0, "too many uniforms", .{});
        return false;
    }
    if (l.nwords + wordsOf(v.ty) > UNIFORM_WORDS) {
        log.err(0, "the uniforms are too large ({d} words at most)", .{UNIFORM_WORDS});
        return false;
    }
    const kept = l.keep(nm) orelse return tooLong(log);
    const kept_api: Name = if (ib.inst_len > 0) (l.keep(api) orelse return tooLong(log)) else .{};
    l.uniforms[l.nuniforms] = .{
        .name = kept,
        .api = kept_api,
        .ty = v.ty,
        .loc = 0,
        .word = l.nwords,
        .stages = bit,
        .block = @intCast(bi),
        .offset = v.offset,
        .array_stride = v.array_stride,
        .matrix_stride = v.matrix_stride,
        .row_major = v.row_major,
    };
    b.members += 1;
    l.nuniforms += 1;
    l.nwords += wordsOf(v.ty);
    return true;
}

/// Transform feedback's variables: gl_Position, or the vertex shader's
/// outputs (one the fragment shader does not read gets varying words of
/// its own: the vertex code writes it), each buffer's record laid out.
fn linkFeedback(p: *Program, vs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    const l = &p.out;
    l.nxfb = 0;
    l.ncapture = 0;
    l.xfb_stride = @splat(0);
    l.xfb_mode = p.xfb_mode;
    if (p.xfb_count == 0) return true;
    const separate = p.xfb_mode == g.SEPARATE_ATTRIBS;
    var it = std.mem.splitScalar(u8, poolText(p.xfb_names), 0);
    var k: u32 = 0;
    while (it.next()) |nm| : (k += 1) {
        if (k == p.xfb_count) break;
        for (l.xfb[0..l.nxfb]) |x| {
            if (std.mem.eql(u8, l.name(x.name), nm)) {
                log.err(0, "transform feedback: `{s}` is captured twice", .{nm});
                return false;
            }
        }
        var ty: Type = undefined;
        var src: u32 = 0;
        const position = std.mem.eql(u8, nm, "gl_Position");
        if (position) {
            ty = .{ .base = .float, .rows = 4 };
        } else {
            const v = findVar(vs, .output, nm) orelse {
                log.err(0, "transform feedback: `{s}` is not an output of the vertex shader", .{nm});
                return false;
            };
            ty = v.ty;
            src = layVaryingIn(l, nm) orelse blk: {
                if (l.nvaryings == MAX_VARYINGS or l.vary_words + wordsOf(ty) > raster.MAX_VARYINGS) {
                    log.err(0, "transform feedback: too many outputs", .{});
                    return false;
                }
                const word = l.vary_words;
                l.varyings[l.nvaryings] = .{ .name = l.keep(nm) orelse return tooLong(log), .ty = ty, .flat = v.q & glsl.Q.flat != 0, .word = word };
                l.nvaryings += 1;
                l.vary_words += wordsOf(ty);
                break :blk word;
            };
        }
        const comps = wordsOf(ty);
        const buffer: u8 = if (separate) @intCast(k) else 0;
        if (buffer >= raster.MAX_CAPTURE_BUFFERS or l.nxfb == MAX_XFB) {
            log.err(0, "transform feedback: too many variables", .{});
            return false;
        }
        if (separate and comps > MAX_XFB_SEPARATE_COMPONENTS) {
            log.err(0, "transform feedback: `{s}` is more than {d} components (separate buffers)", .{ nm, MAX_XFB_SEPARATE_COMPONENTS });
            return false;
        }
        const word = l.xfb_stride[buffer];
        if (word + comps > MAX_XFB_COMPONENTS or l.ncapture + comps > l.capture.len) {
            log.err(0, "transform feedback: more than {d} components", .{MAX_XFB_COMPONENTS});
            return false;
        }
        l.xfb[l.nxfb] = .{ .name = l.keep(nm) orelse return tooLong(log), .ty = ty, .buffer = buffer, .word = word };
        l.nxfb += 1;
        for (0..comps) |ci| {
            const c_: u32 = @intCast(ci);
            l.capture[l.ncapture] = .{ .position = position, .src = @intCast(if (position) c_ else src + c_), .buffer = buffer, .word = @intCast(word + c_) };
            l.ncapture += 1;
        }
        l.xfb_stride[buffer] += comps;
    }
    return true;
}

fn layVaryingIn(l: *const Linked, name: []const u8) ?u32 {
    for (l.varyings[0..l.nvaryings]) |v| {
        if (std.mem.eql(u8, l.name(v.name), name)) return v.word;
    }
    return null;
}

/// glTransformFeedbackVaryings: taken at the program's next link.
pub fn transformFeedbackVaryings(c: *Context, prog: u32, count: i32, names: [*]const [*:0]const u8, mode: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (mode != g.INTERLEAVED_ATTRIBS and mode != g.SEPARATE_ATTRIBS) return c.fail(g.INVALID_ENUM);
    if (count < 0 or (mode == g.SEPARATE_ATTRIBS and count > raster.MAX_CAPTURE_BUFFERS)) return c.fail(g.INVALID_VALUE);
    if (c.feedbackOf()) |t| {
        if (t.active and t.program == prog) return c.fail(g.INVALID_OPERATION);
    }
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    for (names[0..@intCast(count)]) |nm| {
        const s = std.mem.span(nm);
        if (len + s.len + 1 > buf.len) return c.fail(g.OUT_OF_MEMORY);
        @memcpy(buf[len..][0..s.len], s);
        buf[len + s.len] = 0;
        len += s.len + 1;
    }
    const kept = poolKeep(buf[0..len]) orelse return c.fail(g.OUT_OF_MEMORY);
    p.xfb_names = kept;
    p.xfb_count = @intCast(count);
    p.xfb_mode = mode;
}

pub fn getTransformFeedbackVarying(c: *Context, prog: u32, index: u32, buf_size: i32, length: ?*i32, size: ?*i32, kind: ?*u32, name: ?[*]u8) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const l = &p.out;
    if (!p.linked or index >= l.nxfb or buf_size < 0) return c.fail(g.INVALID_VALUE);
    const x = l.xfb[index];
    copyOut(l.name(x.name), buf_size, length, name);
    if (size) |s| s.* = if (x.ty.array != 0) x.ty.array else 1;
    if (kind) |k| k.* = glsl.glType(x.ty);
}

fn linkOutputs(l: *Linked, fs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    if (fs.version < 300) {
        l.frag_color = fs.frag_color;
        l.frag_data = fs.frag_data;
        return true;
    }
    var taken: u32 = 0;
    var count: u32 = 0;
    // (the outputs the shader uses; one it never names, without a
    // location, is no output of the program's)
    for (fs.vars[0..fs.n]) |v| {
        if (v.kind == .output and v.used) count += 1;
    }
    for (fs.vars[0..fs.n]) |v| {
        if (v.kind != .output) continue;
        if (!v.used and v.loc < 0) continue;
        const nm = fs.name(v);
        const at: u32 = if (v.loc >= 0) @intCast(v.loc) else if (count == 1) 0 else {
            log.err(0, "output `{s}` needs a layout location", .{nm});
            return false;
        };
        const n: u32 = if (v.ty.array != 0) v.ty.array else 1;
        if (at + n > MAX_OUTPUTS) {
            log.err(0, "output `{s}`: location {d} past the {d} draw buffers", .{ nm, at + n - 1, MAX_OUTPUTS });
            return false;
        }
        const mask = ((@as(u32, 1) << @intCast(n)) - 1) << @intCast(at);
        if (taken & mask != 0) {
            log.err(0, "output `{s}`: location {d} is another output's", .{ nm, at });
            return false;
        }
        taken |= mask;
        const kept = l.keep(nm) orelse return tooLong(log);
        l.outputs[l.noutputs] = .{ .name = kept, .ty = v.ty, .loc = at };
        l.noutputs += 1;
    }
    return true;
}

// ── The interface, asked ───────────────────────────────────────────────────

fn linkedOf(c: *Context, prog: u32) ?*Linked {
    const p = programOf(c, prog) orelse return null;
    if (!p.linked) {
        c.fail(g.INVALID_OPERATION);
        return null;
    }
    return &p.out;
}

pub fn getAttribLocation(c: *Context, prog: u32, name: [*:0]const u8) i32 {
    start();
    defer unlock();
    const l = linkedOf(c, prog) orelse return -1;
    const s = std.mem.span(name);
    for (l.attribs[0..l.nattribs]) |a| {
        if (std.mem.eql(u8, l.name(a.name), s)) return @intCast(a.loc);
    }
    return -1;
}

pub fn getActiveAttrib(c: *Context, prog: u32, index: u32, buf_size: i32, length: ?*i32, size: ?*i32, kind: ?*u32, name: ?[*]u8) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const l = &p.out;
    if (!p.linked or index >= l.nattribs or buf_size < 0) return c.fail(g.INVALID_VALUE);
    const a = l.attribs[index];
    copyOut(l.name(a.name), buf_size, length, name);
    if (size) |x| x.* = 1;
    if (kind) |x| x.* = glsl.glType(a.ty);
}

pub fn getUniformLocation(c: *Context, prog: u32, name: [*:0]const u8) i32 {
    start();
    defer unlock();
    const l = linkedOf(c, prog) orelse return -1;
    return l.location(std.mem.span(name));
}

pub fn getActiveUniform(c: *Context, prog: u32, index: u32, buf_size: i32, length: ?*i32, size: ?*i32, kind: ?*u32, name: ?[*]u8) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const l = &p.out;
    if (!p.linked or index >= l.nuniforms or buf_size < 0) return c.fail(g.INVALID_VALUE);
    const u = l.uniforms[index];
    // an array is named by its first element, as Mesa names it
    var buf: [PROGRAM_NAMES + 3]u8 = undefined;
    const nm = l.apiName(u);
    @memcpy(buf[0..nm.len], nm);
    var len = nm.len;
    if (u.ty.array != 0) {
        @memcpy(buf[len..][0..3], "[0]");
        len += 3;
    }
    copyOut(buf[0..len], buf_size, length, name);
    if (size) |x| x.* = if (u.ty.array != 0) u.ty.array else 1;
    if (kind) |x| x.* = glsl.glType(u.ty);
}

/// glGetActiveUniformsiv: the uniforms' type, size, name length, and a
/// block member's block, std140 offset and strides (-1 outside blocks).
pub fn getActiveUniformsiv(c: *Context, prog: u32, count: i32, indices: [*]const u32, pname: u32, out: [*]i32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const l = &p.out;
    if (count < 0) return c.fail(g.INVALID_VALUE);
    const n: usize = @intCast(count);
    for (indices[0..n]) |ix| {
        if (!p.linked or ix >= l.nuniforms) return c.fail(g.INVALID_VALUE);
    }
    switch (pname) {
        g.UNIFORM_TYPE, g.UNIFORM_SIZE, g.UNIFORM_NAME_LENGTH, g.UNIFORM_BLOCK_INDEX, g.UNIFORM_OFFSET, g.UNIFORM_ARRAY_STRIDE, g.UNIFORM_MATRIX_STRIDE, g.UNIFORM_IS_ROW_MAJOR => {},
        else => return c.fail(g.INVALID_ENUM),
    }
    for (indices[0..n], 0..) |ix, k| {
        const u = l.uniforms[ix];
        const in_block = u.block >= 0;
        out[k] = switch (pname) {
            g.UNIFORM_TYPE => @intCast(glsl.glType(u.ty)),
            g.UNIFORM_SIZE => if (u.ty.array != 0) u.ty.array else 1,
            g.UNIFORM_NAME_LENGTH => @intCast(l.apiName(u).len + 1 + @as(usize, if (u.ty.array != 0) 3 else 0)),
            g.UNIFORM_BLOCK_INDEX => u.block,
            g.UNIFORM_OFFSET => if (in_block) @intCast(u.offset) else -1,
            g.UNIFORM_ARRAY_STRIDE => if (in_block) @intCast(u.array_stride) else -1,
            g.UNIFORM_MATRIX_STRIDE => if (in_block) @intCast(u.matrix_stride) else -1,
            g.UNIFORM_IS_ROW_MAJOR => @intFromBool(u.row_major),
            else => -1,
        };
    }
}

pub fn getUniformIndices(c: *Context, prog: u32, count: i32, names: [*]const [*:0]const u8, out: [*]u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (count < 0) return c.fail(g.INVALID_VALUE);
    const n: usize = @intCast(count);
    for (0..n) |k| {
        out[k] = g.INVALID_INDEX;
        if (!p.linked) continue;
        // by GL's name ("u", "u[0]", "Block.m"), block members too
        const s = std.mem.span(names[k]);
        const l = &p.out;
        for (l.uniforms[0..l.nuniforms], 0..) |u, i| {
            const nm = l.apiName(u);
            if (std.mem.eql(u8, nm, s) or (u.ty.array != 0 and s.len == nm.len + 3 and std.mem.startsWith(u8, s, nm) and std.mem.endsWith(u8, s, "[0]"))) {
                out[k] = @intCast(i);
                break;
            }
        }
    }
}

// ── Uniform blocks ─────────────────────────────────────────────────────────

pub fn getUniformBlockIndex(c: *Context, prog: u32, name: [*:0]const u8) u32 {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return g.INVALID_INDEX;
    if (!p.linked) return g.INVALID_INDEX;
    const s = std.mem.span(name);
    for (p.out.blocks[0..p.out.nblocks], 0..) |b, i| {
        if (std.mem.eql(u8, p.out.name(b.name), s)) return @intCast(i);
    }
    return g.INVALID_INDEX;
}

pub fn getActiveUniformBlockName(c: *Context, prog: u32, index: u32, buf_size: i32, length: ?*i32, out: ?[*]u8) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (!p.linked or index >= p.out.nblocks or buf_size < 0) return c.fail(g.INVALID_VALUE);
    copyOut(p.out.name(p.out.blocks[index].name), buf_size, length, out);
}

pub fn getActiveUniformBlockiv(c: *Context, prog: u32, index: u32, pname: u32, out: [*]i32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    const l = &p.out;
    if (!p.linked or index >= l.nblocks) return c.fail(g.INVALID_VALUE);
    const b = l.blocks[index];
    switch (pname) {
        g.UNIFORM_BLOCK_BINDING => out[0] = @intCast(b.binding),
        g.UNIFORM_BLOCK_DATA_SIZE => out[0] = @intCast(b.size),
        g.UNIFORM_BLOCK_NAME_LENGTH => out[0] = @intCast(b.name.len + 1),
        g.UNIFORM_BLOCK_ACTIVE_UNIFORMS => out[0] = @intCast(b.members),
        g.UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES => {
            var k: usize = 0;
            for (l.uniforms[0..l.nuniforms], 0..) |u, i| {
                if (u.block != @as(i16, @intCast(index))) continue;
                out[k] = @intCast(i);
                k += 1;
            }
        },
        g.UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER => out[0] = @intFromBool(b.stages & 1 != 0),
        g.UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER => out[0] = @intFromBool(b.stages & 2 != 0),
        else => c.fail(g.INVALID_ENUM),
    }
}

pub fn uniformBlockBinding(c: *Context, prog: u32, index: u32, binding: u32) void {
    start();
    defer unlock();
    const p = programOf(c, prog) orelse return;
    if (!p.linked or index >= p.out.nblocks or binding >= MAX_UNIFORM_BUFFER_BINDINGS) return c.fail(g.INVALID_VALUE);
    p.out.blocks[index].binding = binding;
}

/// The program in use's uniform blocks into `words` (its uniform words as
/// a draw takes them): each member's std140 bytes from the range bound to
/// its block's binding point (gles.uniformBytes), as the code reads them
/// (tight, column-major); zero past the range, or with no buffer bound.
pub fn fillBlocks(c: *Context, words: []u32) void {
    start();
    defer unlock();
    const l = current(c) orelse return;
    if (l.nblocks == 0) return;
    var bytes: [MAX_BLOCKS][]const u8 = undefined;
    for (l.blocks[0..l.nblocks], 0..) |b, i| bytes[i] = c.uniformBytes(b.binding, b.size);
    for (l.uniforms[0..l.nuniforms]) |u| {
        if (u.block < 0) continue;
        const src = bytes[@intCast(u.block)];
        const e = u.ty.elem();
        const n: u32 = if (u.ty.array != 0) u.ty.array else 1;
        var w = u.word;
        for (0..n) |k| {
            const base = u.offset + @as(u32, @intCast(k)) * u.array_stride;
            if (e.matrix()) {
                for (0..e.cols) |col| {
                    for (0..e.rows) |row| {
                        const cc: u32 = @intCast(col);
                        const rr: u32 = @intCast(row);
                        const at = base + if (u.row_major) rr * u.matrix_stride + cc * 4 else cc * u.matrix_stride + rr * 4;
                        if (w < words.len) words[w] = blockWord(src, at, false);
                        w += 1;
                    }
                }
            } else {
                for (0..e.comps()) |j| {
                    if (w < words.len) words[w] = blockWord(src, base + @as(u32, @intCast(j)) * 4, e.base == .bool);
                    w += 1;
                }
            }
        }
    }
}

/// A block's word at byte `at` (0 past its bytes); a bool's as 0 or 1.
fn blockWord(src: []const u8, at: u32, boolean: bool) u32 {
    if (@as(usize, at) + 4 > src.len) return 0;
    const v = std.mem.readInt(u32, src[at..][0..4], .little);
    return if (boolean) @intFromBool(v != 0) else v;
}

pub fn getFragDataLocation(c: *Context, prog: u32, name: [*:0]const u8) i32 {
    start();
    defer unlock();
    const l = linkedOf(c, prog) orelse return -1;
    const s = std.mem.span(name);
    for (l.outputs[0..l.noutputs]) |o| {
        if (std.mem.eql(u8, l.name(o.name), s)) return @intCast(o.loc);
    }
    return -1;
}

// ── Uniform values ─────────────────────────────────────────────────────────

pub const Data = enum { f, i, u };

/// glUniform{1,2,3,4}{f,i,ui}[v] on the current program: `count` elements
/// of `comps` components from `data` (f32 or i32 or u32 bits).
pub fn uniform(c: *Context, loc: i32, count: i32, comps: u32, data_kind: Data, data: [*]const u32) void {
    start();
    defer unlock();
    if (count < 0) return c.fail(g.INVALID_VALUE);
    if (c.program == 0) return c.fail(g.INVALID_OPERATION);
    if (loc == -1) return;
    const l = &progs[objs[c.program - 1].prog].out;
    const at = l.atLocation(loc) orelse return c.fail(g.INVALID_OPERATION);
    const t = at.u.ty.elem();
    if (t.matrix() or t.rows != comps) return c.fail(g.INVALID_OPERATION);
    const fits = switch (t.base) {
        .float => data_kind == .f,
        .int => data_kind == .i,
        .uint => data_kind == .u,
        .bool => true,
        else => t.sampler() and data_kind == .i and comps == 1,
    };
    if (!fits) return c.fail(g.INVALID_OPERATION);
    if (count > 1 and at.u.ty.array == 0) return c.fail(g.INVALID_OPERATION);
    const len: u32 = if (at.u.ty.array != 0) at.u.ty.array else 1;
    const n = @min(@as(u32, @intCast(count)), len - at.elem);
    if (t.sampler()) {
        for (data[0..n]) |x| {
            if (@as(i32, @bitCast(x)) < 0 or x >= MAX_TEXTURE_UNITS) return c.fail(g.INVALID_VALUE);
        }
    }
    const per: u32 = if (t.sampler()) 1 else comps;
    const dst = l.values[at.u.word + at.elem * per ..][0 .. n * per];
    for (dst, data[0 .. n * per]) |*d, x| {
        d.* = if (t.base != .bool) x else @intFromBool(if (data_kind == .f) @as(f32, @bitCast(x)) != 0 else x != 0);
    }
}

/// glUniformMatrix{2,3,4,2x3,..}fv: `count` matrices of cols x rows,
/// column by column (or row by row: transpose).
pub fn uniformMatrix(c: *Context, loc: i32, count: i32, transpose: bool, cols: u32, rows: u32, data: [*]const u32) void {
    start();
    defer unlock();
    if (count < 0) return c.fail(g.INVALID_VALUE);
    if (c.program == 0) return c.fail(g.INVALID_OPERATION);
    if (loc == -1) return;
    const l = &progs[objs[c.program - 1].prog].out;
    const at = l.atLocation(loc) orelse return c.fail(g.INVALID_OPERATION);
    const t = at.u.ty.elem();
    if (!t.matrix() or t.cols != cols or t.rows != rows) return c.fail(g.INVALID_OPERATION);
    if (count > 1 and at.u.ty.array == 0) return c.fail(g.INVALID_OPERATION);
    const len: u32 = if (at.u.ty.array != 0) at.u.ty.array else 1;
    const n = @min(@as(u32, @intCast(count)), len - at.elem);
    const per = cols * rows;
    for (0..n) |m| {
        const dst = l.values[at.u.word + (at.elem + @as(u32, @intCast(m))) * per ..][0..per];
        const src = data[m * per ..][0..per];
        for (0..cols) |j| {
            for (0..rows) |i| dst[j * rows + i] = if (transpose) src[i * cols + j] else src[j * rows + i];
        }
    }
}

/// glGetUniform{f,i,ui}v: the element at `loc`, converted.
/// glGetUniform*, and glGetnUniform* (robustness): the value written as
/// `want`, in at most `limit` bytes (more needed: INVALID_OPERATION).
pub fn getUniform(c: *Context, prog: u32, loc: i32, want: Data, limit: usize, out: [*]u32) void {
    start();
    defer unlock();
    const l = linkedOf(c, prog) orelse return;
    const at = l.atLocation(loc) orelse return c.fail(g.INVALID_OPERATION);
    const t = at.u.ty.elem();
    const per: u32 = if (t.sampler()) 1 else t.comps();
    if (@as(usize, per) * 4 > limit) return c.fail(g.INVALID_OPERATION);
    const src = l.values[at.u.word + at.elem * per ..][0..per];
    for (src, 0..) |x, k| {
        const have: Data = switch (t.base) {
            .float => .f,
            .uint => .u,
            else => .i,
        };
        out[k] = convert(x, have, want);
    }
}

fn convert(x: u32, have: Data, want: Data) u32 {
    if (have == want) return x;
    return switch (want) {
        .f => @bitCast(switch (have) {
            .i => @as(f32, @floatFromInt(@as(i32, @bitCast(x)))),
            else => @as(f32, @floatFromInt(x)),
        }),
        .i => switch (have) {
            .f => @bitCast(@as(i32, @intFromFloat(std.math.clamp(@round(@as(f32, @bitCast(x))), -2147483648.0, 2147483520.0)))),
            else => x,
        },
        .u => switch (have) {
            .f => @intFromFloat(std.math.clamp(@round(@as(f32, @bitCast(x))), 0, 4294967040.0)),
            else => x,
        },
    };
}

/// The current program's link (null: none, or the driver's own pipeline).
pub fn current(c: *Context) ?*Linked {
    if (c.program == 0 or c.program > MAX_NAMES) return null;
    const o = &objs[c.program - 1];
    if (o.kind != .program) return null;
    return &progs[o.prog].out;
}
