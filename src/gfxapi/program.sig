//! @zpm/gfxapi program — OpenGL ES's shader and program objects, over the
//! GLSL front end (glsl/): glCreateShader .. glDeleteProgram, sources,
//! compiles and their logs, links (attribute locations, varyings matched
//! by name, type and interpolation, uniforms merged across the stages,
//! fragment outputs), uniform locations and values (glUniform*, glGet-
//! Uniform*), the active attributes and uniforms, as Mesa answers them.
//!
//! A link makes the program's interface, its uniform storage (tight
//! words: a float, an int, a bool or a sampler's unit each one), where
//! each varying goes, and its pipeline (raster.sig): the shaders' code,
//! generated (glsl/gen.sig) into the draw kernels when the engine builds
//! them, from copies of the sources the link kept. The link generates
//! both once to check them (what cannot be generated fails the link).
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
const raster = @import("raster.sig");
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
pub const UNIFORM_WORDS = 2048;
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
    /// the name without "[0]" (an array's length is in ty.array)
    name: Name,
    ty: Type,
    /// its first location (an array: one per element)
    loc: u32,
    /// its first word in values (an element: comps words, a sampler one)
    word: u32,
    /// the stages using it: 1 vertex, 2 fragment
    stages: u8,
};

pub const Varying = struct { name: Name, ty: Type, flat: bool, word: u32 };
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

    pub fn name(l: *const Linked, n: Name) []const u8 {
        return l.names[n.at..][0..n.len];
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
        if (l.findUniform(s)) |u| return @intCast(u.loc);
        // a trailing [k] of an array
        if (s.len < 4 or s[s.len - 1] != ']') return -1;
        const open = std.mem.lastIndexOfScalar(u8, s, '[') orelse return -1;
        const digits = s[open + 1 .. s.len - 1];
        if (digits.len == 0 or digits.len > 6) return -1;
        // (no leading zeros or signs, as Mesa)
        if (digits.len > 1 and digits[0] == '0') return -1;
        const k = std.fmt.parseInt(u32, digits, 10) catch return -1;
        const u = l.findUniform(s[0..open]) orelse return -1;
        if (u.ty.array == 0 or k >= u.ty.array) return -1;
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
    const o = &objs[prog - 1];
    var logbuf: [2048]u8 = undefined;
    var log = glsl.pp.Log{ .buf = &logbuf };
    p.unloadPipe();
    p.vs_src = .{};
    p.fs_src = .{};
    p.linked = link(p, &log);
    if (p.linked) p.eng = c.eng;
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
            for (l.uniforms[0..l.nuniforms]) |u| m = @max(m, u.name.len + 1 + @as(usize, if (u.ty.array != 0) 3 else 0));
            break :blk @intCast(m);
        },
        g.ACTIVE_UNIFORM_BLOCKS, g.ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH => 0,
        g.TRANSFORM_FEEDBACK_BUFFER_MODE => @intCast(g.INTERLEAVED_ATTRIBS),
        g.TRANSFORM_FEEDBACK_VARYINGS, g.TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH => 0,
        g.PROGRAM_BINARY_RETRIEVABLE_HINT => @intFromBool(p.binary_hint),
        g.PROGRAM_BINARY_LENGTH => 0,
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
    if (!linkUniforms(l, vs, fs, log)) return false;
    if (!linkOutputs(l, fs, log)) return false;
    @memset(l.values[0..l.nwords], 0);
    // the sources kept, the code checked, the pipeline made
    p.vs_src = poolDup(&objs[p.vs - 1].source) orelse return outOfPool(log);
    p.fs_src = poolDup(&objs[p.fs - 1].source) orelse return outOfPool(log);
    if (!checkCode(p, log)) return false;
    var attrs: u32 = 0;
    for (l.attribs[0..l.nattribs]) |a| attrs = @max(attrs, a.loc + slotsOf(a.ty));
    var flat: u64 = 0;
    for (l.varyings[0..l.nvaryings]) |v| {
        if (!v.flat) continue;
        for (0..wordsOf(v.ty)) |w| flat |= @as(u64, 1) << @intCast(v.word + w);
    }
    p.pipe = raster.Pipeline.init(.{ .ctx = p, .attrs = @intCast(attrs), .varyings = @intCast(l.vary_words), .flat = flat, .vertex = emitVertex, .fragment = emitFragment });
    p.has_pipe = true;
    return true;
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

fn layoutOf(p: *const Program) glsl.gen.Layout {
    return .{ .ctx = p, .attrib = layAttrib, .uniform = layUniform, .varying = layVarying, .output = layOutput };
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
/// what cannot be generated fails the link, not a draw.
fn checkCode(p: *const Program, log: *glsl.pp.Log) bool {
    const st = kir.Storage{ .insts = &check_insts, .tys = &check_tys };
    {
        var k = kir.Kernel.init(st, "glsl_vertex", .{ raster.VERTEX_GROUP, 1, 1 });
        var io = raster.VertexIO{ .uniforms = k.binding() };
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
        k.finish() catch |err| return codeFailed(log, "vertex", @errorName(err));
    }
    {
        var k = kir.Kernel.init(st, "glsl_fragment", .{ raster.TILE, raster.TILE, 1 });
        var io = raster.FragmentIO{ .uniforms = k.binding() };
        for (&io.varying) |*v| v.* = k.reg(.f32);
        for (&io.frag_coord) |*v| v.* = k.reg(.f32);
        io.front_facing = k.reg(.pred);
        if (!scratch.compile(poolText(p.fs_src), .fragment)) return codeFailed(log, "fragment", "it no longer compiles");
        if (!glsl.gen.fragment(&scratch, layoutOf(p), &k, &io, log)) return codeFailed(log, "fragment", "");
        for (io.color) |v| {
            if (v != .none) k.store(.f32, kir.global(io.uniforms, 32), kir.u(0), kir.r(v));
        }
        k.finish() catch |err| return codeFailed(log, "fragment", @errorName(err));
    }
    return true;
}

fn codeFailed(log: *glsl.pp.Log, what: []const u8, why: []const u8) bool {
    if (why.len > 0) log.err(0, "the {s} shader's code: {s}", .{ what, why });
    return false;
}

pub const DrawState = struct { pipe: *raster.Pipeline, uniforms: []const u32 };

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
    return .{ .pipe = &p.pipe, .uniforms = p.out.values[0..p.out.nwords] };
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
            if (l.findUniform(nm)) |u| {
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

fn linkOutputs(l: *Linked, fs: *const glsl.Iface, log: *glsl.pp.Log) bool {
    if (fs.version < 300) {
        l.frag_color = fs.frag_color;
        l.frag_data = fs.frag_data;
        return true;
    }
    var taken: u32 = 0;
    var count: u32 = 0;
    for (fs.vars[0..fs.n]) |v| {
        if (v.kind == .output) count += 1;
    }
    for (fs.vars[0..fs.n]) |v| {
        if (v.kind != .output) continue;
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
    const nm = l.name(u.name);
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

/// glGetActiveUniformsiv: the uniforms' type, size, name length (none
/// is in a block: their block, offset and strides are -1).
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
        out[k] = switch (pname) {
            g.UNIFORM_TYPE => @intCast(glsl.glType(u.ty)),
            g.UNIFORM_SIZE => if (u.ty.array != 0) u.ty.array else 1,
            g.UNIFORM_NAME_LENGTH => @intCast(u.name.len + 1 + @as(usize, if (u.ty.array != 0) 3 else 0)),
            g.UNIFORM_IS_ROW_MAJOR => 0,
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
        const loc = p.out.location(std.mem.span(names[k]));
        if (loc >= 0) out[k] = p.out.locs[@intCast(loc)];
    }
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
pub fn getUniform(c: *Context, prog: u32, loc: i32, want: Data, out: [*]u32) void {
    start();
    defer unlock();
    const l = linkedOf(c, prog) orelse return;
    const at = l.atLocation(loc) orelse return c.fail(g.INVALID_OPERATION);
    const t = at.u.ty.elem();
    const per: u32 = if (t.sampler()) 1 else t.comps();
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
