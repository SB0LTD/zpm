//! @zpm/gfxapi gles — OpenGL ES 3.0's objects and state, over the engine:
//! what libgles.sig's C entry points call, and what EGL makes current.
//!
//! This stage has the part of ES 3.0 that needs no shaders: errors as Mesa
//! keeps them (the first one, until glGetError), the enable bits, the
//! clear state and masks, viewport and scissor, pixel store state; buffer
//! objects; 2D textures (level 0, RGBA8 and BGRA8); renderbuffers (RGBA8,
//! BGRA8, depth, stencil, depth-stencil); framebuffer objects with four
//! color attachments, draw and read buffers and ES 3.0's completeness;
//! glClear and glClearBuffer*, glReadPixels (pack buffers too),
//! glTexImage2D, glTexSubImage2D, glTexStorage2D (unpack buffers too),
//! glCopyTexSubImage2D, glCopyTexImage2D; EGLImages as textures and
//! renderbuffers (OES_EGL_image, OES_EGL_image_external: the memory is
//! the image (shared). Vertex arrays and draws (raster.sig), with the GLSL
//! program in use (program.sig); samplers, queries and sync objects later.
//!
//! Objects (textures, buffers, renderbuffers) live in an Objects table a
//! share group's contexts hold; framebuffers are each context's. A name is
//! its slot plus one; a name glGen* gave is named, and bound once it is
//! made (glIs* say true). An image attached to a framebuffer that is not
//! bound stays until it is detached, though its name is deleted (refs,
//! orphan), as GL says.
//!
//! The default framebuffer is the EGL surface's: setSurface gives its
//! images (a window's buffer is top-down: the engine flips rows).
//!
//! Allocation-free: every table is fixed (MAX_*), in memory the caller
//! owns (a context and its Objects, each at a fixed address).

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.sig");
const report = @import("report.sig");
pub const debug_output = @import("debug_output.sig");
const raster = @import("raster.sig");
const program = @import("program.sig");
const texture = @import("texture.sig");
const texfmt = @import("texfmt.sig");
const g = @import("glenum.sig");
const Engine = engine.Engine;
const Image = engine.Image;
const Format = engine.Format;
const Rect = engine.Rect;

pub const MAX_TEXTURES = 4096;
pub const MAX_BUFFERS = 4096;
pub const MAX_RENDERBUFFERS = 512;
pub const MAX_FRAMEBUFFERS = 512;
/// The largest texture, renderbuffer and viewport side.
pub const MAX_SIZE = 8192;
pub const MAX_UNITS = 32;
pub const MAX_COLOR = 4;
/// uniform blocks a shader may have (MAX_VERTEX_UNIFORM_BLOCKS, MAX_FRAGMENT_UNIFORM_BLOCKS)
const glsl_max_blocks = program.glsl.sema.MAX_BLOCKS;
pub const MAX_VAOS = 256;
pub const MAX_SAMPLERS = 256;
pub const MAX_ATTRS = raster.MAX_ATTRS;

pub const VENDOR_STRING: [:0]const u8 = "Galaxy";
pub const VERSION_STRING: [:0]const u8 = "OpenGL ES 3.0 Galaxy 0.1";
pub const GLSL_STRING: [:0]const u8 = "OpenGL ES GLSL ES 3.00";
/// What GL_EXTENSIONS names: what the driver has (WebRender asks for
/// BGRA and external textures in ESSL 3.00; GLSL ES 1.00 programs for
/// derivatives and texture LOD; ES 2 apps for sized renderbuffers and
/// texture storage; video's 10- to 16-bit planes for norm16, sampled
/// only). The GLSL compiler's #extension takes the shading ones.
pub const EXTENSIONS = [_][:0]const u8{
    "GL_EXT_read_format_bgra",
    "GL_EXT_texture_format_BGRA8888",
    "GL_EXT_texture_norm16",
    "GL_EXT_texture_storage",
    "GL_EXT_shader_texture_lod",
    "GL_OES_EGL_image",
    "GL_OES_EGL_image_external",
    "GL_OES_EGL_image_external_essl3",
    "GL_OES_standard_derivatives",
    "GL_OES_depth24",
    "GL_OES_packed_depth_stencil",
    "GL_OES_rgb8_rgba8",
    "GL_OES_texture_npot",
    // (a lost GPU: glGetGraphicsResetStatus, the reset strategy, and
    // CONTEXT_LOST once; the n-forms of ReadPixels and GetUniform)
    "GL_EXT_robustness",
    "GL_KHR_robustness",
    "GL_EXT_debug_marker",
    "GL_KHR_debug",
};

/// EGL's EGLImage handles to their images (egl.sig sets it): what
/// glEGLImageTargetTexture2DOES takes.
pub var egl_image: ?*const fn (?*anyopaque) ?*Image = null;
pub const EXTENSIONS_STRING: [:0]const u8 = blk: {
    var s: [:0]const u8 = "";
    for (EXTENSIONS, 0..) |e, i| s = s ++ (if (i == 0) "" else " ") ++ e;
    break :blk s;
};

pub const TexParams = struct {
    min: u32 = g.NEAREST_MIPMAP_LINEAR,
    mag: u32 = g.LINEAR,
    wrap_s: u32 = g.REPEAT,
    wrap_t: u32 = g.REPEAT,
    wrap_r: u32 = g.REPEAT,
    base_level: i32 = 0,
    max_level: i32 = 1000,
    min_lod: i32 = -1000,
    max_lod: i32 = 1000,
    compare_mode: u32 = g.NONE,
    compare_func: u32 = g.LEQUAL,
    /// TEXTURE_SWIZZLE_R, _G, _B, _A (a texture's, not a sampler's)
    swizzle: [4]u32 = .{ g.RED, g.GREEN, g.BLUE, g.ALPHA },
};

/// A sampler object (glGenSamplers): filters and wraps in place of its
/// unit's texture's.
pub const Smp = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    params: TexParams = .{},
};

pub var stream_changed: ?*const fn () void = null;

pub const Tex = struct {
    stream_owner: ?*anyopaque = null,
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    /// deleted while attached somewhere: freed at the last detach
    orphan: bool = false,
    refs: u32 = 0,
    target: u32 = 0,
    img: Image = .{},
    slice_share: engine.Shared = .{},
    internal: u32 = 0,
    levels: u32 = 0,
    layers: u32 = 1,
    /// the levels specified (bit l: level l), stored in img's chain
    defined: u16 = 0,
    extra_levels: [engine.MAX_LEVELS]u16 = @splat(0),
    cube_faces: [6][engine.MAX_LEVELS]u16 = @splat(@splat(0)),
    immutable: bool = false,
    params: TexParams = .{},
    /// GL's R, G, B, A as the stored texel's channels (LUMINANCE ...),
    /// and sRGB
    fswz: [4]u3 = .{ 0, 1, 2, 3 },
    srgb: bool = false,

    fn disconnectStream(t: *Tex) void {
        if (t.stream_owner == null) return;
        t.stream_owner = null;
        if (stream_changed) |notify| notify();
    }
};

pub const Buf = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    store: Image = .{},
    size: usize = 0,
    usage: u32 = g.STATIC_DRAW,
    immutable: bool = false,
    storage_flags: u32 = 0,
    /// glMapBufferRange's: the range the CPU has (none: not mapped)
    map: ?[]u8 = null,
    map_off: usize = 0,
    map_access: u32 = 0,

    pub fn mapped(b: *const Buf) bool {
        return b.map != null;
    }
};

/// glMapBufferRange's access bits.
const MAP_READ = 0x1;
const MAP_WRITE = 0x2;
const MAP_INVALIDATE_RANGE = 0x4;
const MAP_INVALIDATE_BUFFER = 0x8;
const MAP_FLUSH_EXPLICIT = 0x10;
const MAP_UNSYNCHRONIZED = 0x20;
const MAP_PERSISTENT = 0x40;
const MAP_COHERENT = 0x80;
const DYNAMIC_STORAGE = 0x100;
const CLIENT_STORAGE = 0x200;
const CLIENT_MAPPED_BUFFER_BARRIER = 0x4000;

pub const Rb = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    orphan: bool = false,
    refs: u32 = 0,
    img: Image = .{},
    internal: u32 = g.RGBA4,
    samples: u32 = 0,
};

/// A share group's objects (every context created sharing with another
/// holds the same Objects).
/// GL sync objects a share group may have at once.
pub const MAX_SYNCS = 1024;

/// A fence: the engine's mark after the work before it.
pub const Sync = struct { used: bool = false, mark: u64 = 0, label: debug_output.Label = .{} };

const ExtraLevel = struct {
    used: bool = false,
    img: Image = .{},
    share: engine.Shared = .{},
    internal: u32 = 0,
    layers: u32 = 1,
    srgb: bool = false,
    swizzle: [4]u3 = .{ 0, 1, 2, 3 },
};

pub const Objects = struct {
    tex: [MAX_TEXTURES]Tex = undefined,
    extra_levels: [512]ExtraLevel = undefined,
    bufs: [MAX_BUFFERS]Buf = undefined,
    rbs: [MAX_RENDERBUFFERS]Rb = undefined,
    samplers: [MAX_SAMPLERS]Smp = undefined,
    syncs: [MAX_SYNCS]Sync = undefined,
    /// contexts holding it
    users: u32 = 0,

    pub fn init(o: *Objects) void {
        for (&o.tex) |*t| t.* = .{};
        for (&o.extra_levels) |*mip| mip.* = .{};
        for (&o.bufs) |*b| b.* = .{};
        for (&o.rbs) |*b| b.* = .{};
        for (&o.samplers) |*s| s.* = .{};
        for (&o.syncs) |*s| s.* = .{};
        o.users = 0;
    }

    /// Every object's memory goes back (the last context left).
    fn release(o: *Objects, eng: *Engine) void {
        program.dropOwner(o);
        for (&o.tex) |*t| eng.freeImage(&t.img);
        for (&o.extra_levels) |*mip| eng.freeImage(&mip.img);
        for (&o.bufs) |*b| eng.freeImage(&b.store);
        for (&o.rbs) |*b| eng.freeImage(&b.img);
        o.init();
    }
};

pub const Attach = struct {
    pub const Kind = enum(u8) { none, tex, rb };
    kind: Kind = .none,
    name: u32 = 0,
    level: u32 = 0,
    layer: u32 = 0,
    face: u32 = 0,
    slice: Image = .{},
};

pub const Fbo = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    color: [MAX_COLOR]Attach = [_]Attach{.{}} ** MAX_COLOR,
    depth: Attach = .{},
    stencil: Attach = .{},
    draw: [MAX_COLOR]u32 = .{ g.COLOR_ATTACHMENT0, g.NONE, g.NONE, g.NONE },
    read: u32 = g.COLOR_ATTACHMENT0,
};

/// A framebuffer as an operation sees it.
const View = struct {
    status: u32 = g.FRAMEBUFFER_COMPLETE,
    /// by draw buffer
    color: [MAX_COLOR]?*Image = [_]?*Image{null} ** MAX_COLOR,
    read: ?*Image = null,
    depth: ?*Image = null,
    stencil: ?*Image = null,
    width: u32 = 0,
    height: u32 = 0,

    fn bounds(v: *const View) Rect {
        return .{ .x0 = 0, .y0 = 0, .x1 = v.width, .y1 = v.height };
    }
};

/// glPixelStorei's state, for packing or unpacking.
const Store = struct {
    alignment: i32 = 4,
    row_length: i32 = 0,
    skip_rows: i32 = 0,
    skip_pixels: i32 = 0,
    image_height: i32 = 0,
    skip_images: i32 = 0,

    /// Bytes from one row to the next, and to the first pixel, of w
    /// pixels of `bpp` bytes.
    fn layout(s: Store, w: u32, bpp: u32) struct { row: usize, first: usize } {
        const len: usize = if (s.row_length > 0) @intCast(s.row_length) else w;
        const a: usize = @intCast(s.alignment);
        const row = std.mem.alignForward(usize, len * bpp, a);
        return .{ .row = row, .first = @as(usize, @intCast(s.skip_rows)) * row + @as(usize, @intCast(s.skip_pixels)) * bpp };
    }
};

/// Bytes a w x h rectangle of `bpp`-byte pixels spans in client memory.
fn spanOf(first: usize, row: usize, w: u32, h: u32, bpp: u32) usize {
    if (w == 0 or h == 0) return 0;
    return first + (@as(usize, h) - 1) * row + @as(usize, w) * bpp;
}

/// A vertex attribute's array (glVertexAttribPointer).
pub const VAttr = struct {
    enabled: bool = false,
    size: u8 = 4,
    ty: u32 = g.FLOAT,
    normalized: bool = false,
    integer: bool = false,
    stride: u32 = 0,
    /// the pointer: an offset into `buffer`
    offset: usize = 0,
    buffer: u32 = 0,
    divisor: u32 = 0,
};

pub const Vao = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    made: bool = false,
    attrs: [MAX_ATTRS]VAttr = [_]VAttr{.{}} ** MAX_ATTRS,
    /// ELEMENT_ARRAY_BUFFER's binding (a vertex array's in ES 3.0)
    element: u32 = 0,
};

const BufBinds = struct {
    array: u32 = 0,
    pack: u32 = 0,
    unpack: u32 = 0,
    uniform: u32 = 0,
    copy_read: u32 = 0,
    copy_write: u32 = 0,
    xfb: u32 = 0,
};

/// GL ES 3.0's transform feedback limits: separate buffers (and
/// attributes), components a vertex writes interleaved, objects
pub const MAX_FEEDBACK_BUFFERS = 4;
pub const MAX_FEEDBACK_COMPONENTS = 64;
pub const MAX_FEEDBACKS = 32;

/// A transform feedback object: its buffers' binding points, and while
/// active, the primitive mode and program begun with and the vertices
/// captured so far (each buffer's next vertex).
pub const Feedback = struct {
    named: bool = false,
    made: bool = false,
    bufs: [MAX_FEEDBACK_BUFFERS]Indexed = @splat(.{}),
    active: bool = false,
    paused: bool = false,
    mode: u32 = 0,
    program: u32 = 0,
    vertices: u64 = 0,
};

/// An indexed binding point (glBindBufferBase, glBindBufferRange): a
/// buffer, and the range of it (the whole, from offset, when not ranged).
pub const Indexed = struct {
    buf: u32 = 0,
    offset: usize = 0,
    size: usize = 0,
    ranged: bool = false,
};

fn capBit(cap: u32) ?u5 {
    return switch (cap) {
        g.CULL_FACE => 0,
        g.DEPTH_TEST => 1,
        g.STENCIL_TEST => 2,
        g.DITHER => 3,
        g.BLEND => 4,
        g.SCISSOR_TEST => 5,
        g.POLYGON_OFFSET_FILL => 6,
        g.SAMPLE_ALPHA_TO_COVERAGE => 7,
        g.SAMPLE_COVERAGE => 8,
        g.RASTERIZER_DISCARD => 9,
        g.PRIMITIVE_RESTART_FIXED_INDEX => 10,
        else => null,
    };
}

fn bitOf(cap: u32) u32 {
    return @as(u32, 1) << capBit(cap).?;
}

/// float in [0, 1] to an n-bit unsigned normalized integer, rounded to
/// nearest even as Mesa's _mesa_float_to_unorm.
fn unorm(x: f32, comptime bits: u5) u32 {
    const max: f64 = @floatFromInt((@as(u32, 1) << bits) - 1);
    const c: f64 = if (x != x) 0 else std.math.clamp(@as(f64, x), 0, 1);
    const t = c * max;
    var n = @floor(t);
    const d = t - n;
    if (d > 0.5 or (d == 0.5 and @mod(n, 2) == 1)) n += 1;
    return @intFromFloat(n);
}

/// A pixel of `fmt` from RGBA in [0, 1].
fn packColor(fmt: Format, c: [4]f32) u32 {
    const r = unorm(c[0], 8);
    const gr = unorm(c[1], 8);
    const b = unorm(c[2], 8);
    const a = unorm(c[3], 8);
    return switch (fmt) {
        .rgba8 => r | gr << 8 | b << 16 | a << 24,
        .bgra8 => b | gr << 8 | r << 16 | a << 24,
        .rg8 => r | gr << 8,
        .r8 => r,
        else => unreachable,
    };
}

/// The bits of a `fmt` pixel the color mask keeps (masked off).
fn colorKeep(fmt: Format, m: [4]bool) u32 {
    const chan = switch (fmt) {
        .bgra8 => [4]u5{ 16, 8, 0, 24 },
        .rgba8, .rg8, .r8 => [4]u5{ 0, 8, 16, 24 },
        else => unreachable,
    };
    var keep: u32 = 0;
    for (m, chan, 0..) |on, sh, n| {
        if (!on and n < fmt.channels()) keep |= @as(u32, 0xff) << sh;
    }
    return keep;
}

/// What a GL format and type in client memory are, as an engine format
/// (four bytes a pixel), or the error GL gives.
fn clientFormat(format: u32, ty: u32) union(enum) { ok: Format, err: u32 } {
    if (ty == g.UNSIGNED_BYTE) {
        if (format == g.RGBA) return .{ .ok = .rgba8 };
        if (format == g.BGRA_EXT) return .{ .ok = .bgra8 };
        // (an R8 or RG8 framebuffer's own: its read format)
        if (format == g.RED) return .{ .ok = .r8 };
        if (format == g.RG) return .{ .ok = .rg8 };
    }
    const known_format = switch (format) {
        g.RGBA, g.BGRA_EXT, g.RGB, g.ALPHA, g.LUMINANCE, g.LUMINANCE_ALPHA, g.RED, g.RG, g.RGBA_INTEGER, g.DEPTH_COMPONENT, g.DEPTH_STENCIL => true,
        else => false,
    };
    const known_type = switch (ty) {
        g.UNSIGNED_BYTE, g.UNSIGNED_SHORT, g.UNSIGNED_INT, g.FLOAT, g.UNSIGNED_INT_24_8 => true,
        else => false,
    };
    return .{ .err = if (known_format and known_type) g.INVALID_OPERATION else g.INVALID_ENUM };
}

/// A renderbuffer internal format as the engine stores it.
fn rbFormat(internal: u32) ?Format {
    return switch (internal) {
        // (the 16-bit ones ES 2.0 and WebGL 1 require are kept at 8 bits a
        // channel)
        g.RGBA8, g.RGBA4, g.RGB5_A1, g.RGB565 => .rgba8,
        g.BGRA8_EXT => .bgra8,
        g.R8 => .r8,
        g.RG8 => .rg8,
        g.DEPTH_COMPONENT16, g.DEPTH_COMPONENT24, g.DEPTH24_STENCIL8, g.STENCIL_INDEX8 => .d24s8,
        else => null,
    };
}

/// A texture's internal format is color-renderable (ES 3.0's table, the
/// ones stored as a renderable format: RGBA8's 16-bit forms are widened
/// to it; sRGB is not drawn into yet).
fn renderableInternal(internal: u32) bool {
    return switch (internal) {
        g.RGBA8, g.RGBA, g.RGB8, g.RGB, g.RGB565, g.RGBA4, g.RGB5_A1, g.BGRA8_EXT, g.BGRA_EXT, g.R8, g.RG8 => true,
        else => false,
    };
}

fn hasDepth(internal: u32) bool {
    return internal == g.DEPTH_COMPONENT16 or internal == g.DEPTH_COMPONENT24 or internal == g.DEPTH24_STENCIL8;
}

fn hasStencil(internal: u32) bool {
    return internal == g.DEPTH24_STENCIL8 or internal == g.STENCIL_INDEX8;
}

fn validUsage(u: u32) bool {
    return switch (u) {
        g.STREAM_DRAW, g.STREAM_READ, g.STREAM_COPY, g.STATIC_DRAW, g.STATIC_READ, g.STATIC_COPY, g.DYNAMIC_DRAW, g.DYNAMIC_READ, g.DYNAMIC_COPY => true,
        else => false,
    };
}

/// glGen*'s names: the lowest free slots (neither named nor held by an
/// attachment).
fn genIn(comptime T: type, table: []T, out: []u32) bool {
    var at: usize = 0;
    for (out) |*n| {
        while (at < table.len) : (at += 1) {
            const t = &table[at];
            const held = if (@hasField(T, "orphan")) t.orphan else false;
            if (!t.named and !t.made and !held) break;
        } else return false;
        table[at].named = true;
        n.* = @intCast(at + 1);
        at += 1;
    }
    return true;
}

fn slotIn(comptime T: type, table: []T, name: u32) ?*T {
    if (name == 0 or name > table.len) return null;
    return &table[name - 1];
}

/// The object `name` names, made (bound once).
fn madeIn(comptime T: type, table: []T, name: u32) ?*T {
    const t = slotIn(T, table, name) orelse return null;
    return if (t.made) t else null;
}

/// Bind's object: made now if only named, or not named yet (ES lets a
/// name glGen* did not give be bound); null when the slot is out of
/// range or an attachment still holds its old object.
fn makeIn(comptime T: type, table: []T, name: u32) ?*T {
    const t = slotIn(T, table, name) orelse return null;
    if (@hasField(T, "orphan") and t.orphan) return null;
    t.named = true;
    t.made = true;
    return t;
}

/// Sets a texture's or a sampler object's parameter; GL's error, or
/// NO_ERROR. (External textures filter without mipmaps and clamp; the
/// swizzle and the levels are a texture's.)
fn setParam(p: *TexParams, ext: bool, sampler: bool, pname: u32, param: i32) u32 {
    const v: u32 = @bitCast(param);
    const filter_min = switch (v) {
        g.NEAREST, g.LINEAR, g.NEAREST_MIPMAP_NEAREST, g.LINEAR_MIPMAP_NEAREST, g.NEAREST_MIPMAP_LINEAR, g.LINEAR_MIPMAP_LINEAR => true,
        else => false,
    };
    const wrap = v == g.CLAMP_TO_EDGE or (!ext and (v == g.REPEAT or v == g.MIRRORED_REPEAT));
    const chan = v == g.RED or v == g.GREEN or v == g.BLUE or v == g.ALPHA or v == g.ZERO or v == g.ONE;
    const func = v >= g.NEVER and v <= g.NEVER + 7;
    switch (pname) {
        g.TEXTURE_MIN_FILTER => if (filter_min and (!ext or v == g.NEAREST or v == g.LINEAR)) {
            p.min = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_MAG_FILTER => if (v == g.NEAREST or v == g.LINEAR) {
            p.mag = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_WRAP_S => if (wrap) {
            p.wrap_s = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_WRAP_T => if (wrap) {
            p.wrap_t = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_WRAP_R => if (wrap) {
            p.wrap_r = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_MIN_LOD => p.min_lod = param,
        g.TEXTURE_MAX_LOD => p.max_lod = param,
        g.TEXTURE_COMPARE_MODE => if (v == g.NONE or v == g.COMPARE_REF_TO_TEXTURE) {
            p.compare_mode = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_COMPARE_FUNC => if (func) {
            p.compare_func = v;
        } else return g.INVALID_ENUM,
        g.TEXTURE_BASE_LEVEL => if (sampler) return g.INVALID_ENUM else if (param >= 0) {
            p.base_level = param;
        } else return g.INVALID_VALUE,
        g.TEXTURE_MAX_LEVEL => if (sampler) return g.INVALID_ENUM else if (param >= 0) {
            p.max_level = param;
        } else return g.INVALID_VALUE,
        g.TEXTURE_SWIZZLE_R, g.TEXTURE_SWIZZLE_G, g.TEXTURE_SWIZZLE_B, g.TEXTURE_SWIZZLE_A => if (sampler) return g.INVALID_ENUM else if (chan) {
            p.swizzle[pname - g.TEXTURE_SWIZZLE_R] = v;
        } else return g.INVALID_ENUM,
        else => return g.INVALID_ENUM,
    }
    return g.NO_ERROR;
}

fn getParam(p: *const TexParams, sampler: bool, pname: u32) ?i32 {
    const v: u32 = switch (pname) {
        g.TEXTURE_MIN_FILTER => p.min,
        g.TEXTURE_MAG_FILTER => p.mag,
        g.TEXTURE_WRAP_S => p.wrap_s,
        g.TEXTURE_WRAP_T => p.wrap_t,
        g.TEXTURE_WRAP_R => p.wrap_r,
        g.TEXTURE_MIN_LOD => @bitCast(p.min_lod),
        g.TEXTURE_MAX_LOD => @bitCast(p.max_lod),
        g.TEXTURE_COMPARE_MODE => p.compare_mode,
        g.TEXTURE_COMPARE_FUNC => p.compare_func,
        g.TEXTURE_BASE_LEVEL => if (sampler) return null else @bitCast(p.base_level),
        g.TEXTURE_MAX_LEVEL => if (sampler) return null else @bitCast(p.max_level),
        g.TEXTURE_SWIZZLE_R, g.TEXTURE_SWIZZLE_G, g.TEXTURE_SWIZZLE_B, g.TEXTURE_SWIZZLE_A => if (sampler) return null else p.swizzle[pname - g.TEXTURE_SWIZZLE_R],
        else => return null,
    };
    return @bitCast(v);
}

fn wrapOf(w: u32) texture.Wrap {
    return switch (w) {
        g.CLAMP_TO_EDGE => .clamp,
        g.MIRRORED_REPEAT => .mirror,
        else => .repeat,
    };
}

pub const TIME_ELAPSED_EXT = 0x88BF;
pub const TIMESTAMP_EXT = 0x8E28;
/// A query object (glGenQueries, glGenQueriesEXT: one name space): a
/// timer's, an occlusion query's (its word, set where a sample passes,
/// and the engine's mark after its draws), transform feedback's
/// primitives (counted as they are captured).
const TimerQuery = struct {
    label: debug_output.Label = .{},
    named: bool = false,
    target: u32 = 0,
    value: u64 = 0,
    ready: bool = false,
    word: Image = .{},
    mark: u64 = 0,
};

const StencilState = struct {
    func: u32 = g.ALWAYS,
    reference: u8 = 0,
    value_mask: u32 = 0xffffffff,
    fail: raster.StencilOp = .keep,
    depth_fail: raster.StencilOp = .keep,
    pass: raster.StencilOp = .keep,

    fn draw(state: StencilState, write_mask: u32) raster.Stencil {
        return .{
            .func = @intCast(state.func - g.NEVER),
            .reference = state.reference,
            .value_mask = @truncate(state.value_mask),
            .write_mask = @truncate(write_mask),
            .fail = state.fail,
            .depth_fail = state.depth_fail,
            .pass = state.pass,
        };
    }
};

/// GL's internal format for an EGLImage's memory (a dma-buf's format:
/// egl.sig's fourccs).
fn imageInternal(f: Format) u32 {
    return switch (f) {
        .bgra8 => g.BGRA8_EXT,
        .r8 => g.R8,
        .rg8 => g.RG8,
        .r16 => g.R16_EXT,
        .rg16 => g.RG16_EXT,
        else => g.RGBA8,
    };
}

fn stencilOpOf(op: u32) ?raster.StencilOp {
    return switch (op) {
        g.KEEP => .keep,
        g.ZERO => .zero,
        g.REPLACE => .replace,
        g.INCR => .incr,
        g.DECR => .decr,
        g.INVERT => .invert,
        g.INCR_WRAP => .incr_wrap,
        g.DECR_WRAP => .decr_wrap,
        else => null,
    };
}

fn stencilEnum(op: raster.StencilOp) u32 {
    return switch (op) {
        .keep => g.KEEP,
        .zero => g.ZERO,
        .replace => g.REPLACE,
        .incr => g.INCR,
        .decr => g.DECR,
        .invert => g.INVERT,
        .incr_wrap => g.INCR_WRAP,
        .decr_wrap => g.DECR_WRAP,
    };
}

pub const Context = struct {
    eng: *Engine,
    objs: *Objects,
    err: u32 = g.NO_ERROR,
    reset_told: bool = false,
    marker_depth: u32 = 0,
    debug: debug_output.Output = .{},
    debug_context: bool = false,
    timers: [128]TimerQuery = @splat(.{}),
    elapsed: u32 = 0,
    elapsed_begin: u64 = 0,
    /// the occlusion query and the primitives query active (0: none)
    occlusion: u32 = 0,
    primitives: u32 = 0,
    timer_disjoint: bool = false,
    /// EGL's reset notification strategy is LOSE_CONTEXT_ON_RESET (else
    /// NO_RESET_NOTIFICATION, which says nothing of a reset)
    lose_on_reset: bool = false,
    lost_told: bool = false,
    fbos: [MAX_FRAMEBUFFERS]Fbo = undefined,
    // the default framebuffer: the EGL surfaces' images
    surf_draw: ?*Image = null,
    surf_read: ?*Image = null,
    surf_depth: ?*Image = null,
    surf_seen: bool = false,
    default_draw: u32 = g.BACK,
    default_read: u32 = g.BACK,
    draw_fb: u32 = 0,
    read_fb: u32 = 0,
    rb: u32 = 0,
    clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    clear_depth: f32 = 1,
    clear_stencil: i32 = 0,
    color_mask: [4]bool = .{ true, true, true, true },
    depth_mask: bool = true,
    stencil_mask: u32 = 0xffff_ffff,
    stencil_back_mask: u32 = 0xffff_ffff,
    stencil_front: StencilState = .{},
    stencil_back: StencilState = .{},
    viewport: [4]i32 = .{ 0, 0, 0, 0 },
    scissor: [4]i32 = .{ 0, 0, 0, 0 },
    enabled: u32 = 1 << 3, // (DITHER is on at first)
    unit: u32 = 0,
    tex2d: [MAX_UNITS]u32 = [_]u32{0} ** MAX_UNITS,
    layered: [3][MAX_UNITS]u32 = @splat(@splat(0)),
    tex_ext: [MAX_UNITS]u32 = [_]u32{0} ** MAX_UNITS,
    /// texture 0 of TEXTURE_2D and of TEXTURE_EXTERNAL_OES (each context
    /// has its own)
    default_tex: Tex = .{ .named = true, .made = true, .target = g.TEXTURE_2D },
    default_ext: Tex = .{ .named = true, .made = true, .target = g.TEXTURE_EXTERNAL_OES, .params = .{ .min = g.LINEAR, .wrap_s = g.CLAMP_TO_EDGE, .wrap_t = g.CLAMP_TO_EDGE, .wrap_r = g.CLAMP_TO_EDGE } },
    bufs: BufBinds = .{},
    /// the uniform buffer binding points a program's blocks read
    ubo: [program.MAX_UNIFORM_BUFFER_BINDINGS]Indexed = @splat(.{}),
    /// transform feedback objects (a context's own, not shared), the
    /// default one (0), the one bound
    feedbacks: [MAX_FEEDBACKS]Feedback = @splat(.{}),
    feedback0: Feedback = .{ .named = true, .made = true },
    xfb: u32 = 0,
    pack: Store = .{},
    unpack: Store = .{},
    hint_mipmap: u32 = g.DONT_CARE,
    hint_derivative: u32 = g.DONT_CARE,
    vaos: [MAX_VAOS]Vao = undefined,
    vao0: Vao = .{ .named = true, .made = true },
    vao: u32 = 0,
    /// glVertexAttrib*'s values (where an array is off), and whether each is an integer one
    generic: [MAX_ATTRS][4]u32 = [_][4]u32{.{ 0, 0, 0, 0x3f80_0000 }} ** MAX_ATTRS,
    generic_int: [MAX_ATTRS]bool = [_]bool{false} ** MAX_ATTRS,
    generic_unsigned: [MAX_ATTRS]bool = @splat(false),
    blend_src_rgb: u32 = g.ONE,
    blend_dst_rgb: u32 = g.ZERO,
    blend_src_a: u32 = g.ONE,
    blend_dst_a: u32 = g.ZERO,
    blend_eq_rgb: u32 = g.FUNC_ADD,
    blend_eq_a: u32 = g.FUNC_ADD,
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    depth_func: u32 = g.LESS,
    depth_range: [2]f32 = .{ 0, 1 },
    cull_mode: u32 = g.BACK,
    front_face: u32 = g.CCW,
    /// what draws run: a pipeline and its uniforms (the next stage's GLSL
    /// programs make them; for now the driver's own)
    pipeline: ?*raster.Pipeline = null,
    uniforms: []const u32 = &.{},
    /// glUseProgram's (program.sig): while one is in use, draws run it
    program: u32 = 0,
    /// each unit's sampler object (0: its textures' own state)
    smp: [MAX_UNITS]u32 = [_]u32{0} ** MAX_UNITS,
    /// a draw's uniforms: the program's, then its textures' descriptors
    draw_words: [program.UNIFORM_WORDS + texture.MAX_TEX * texture.DESC_WORDS]u32 = undefined,
    /// EGL's check of the default framebuffer (a window resized: a back
    /// buffer of its new size), before an operation reaches it
    revalidate: ?Revalidate = null,
    /// what the context is used for, said every few seconds (report.sig)
    usage: report.Usage = .{},

    pub const Revalidate = struct {
        ctx: *anyopaque,
        f: *const fn (*anyopaque) void,
        stale: *const std.atomic.Value(bool),
    };

    /// A context in place over `eng`, holding `objs` (a new share group's,
    /// initialized by the caller, or another context's).
    fn timerAvailable(c: *const Context) bool {
        return c.eng.onGpu() and c.eng.dev.?.vtable.timestampNs != null;
    }

    fn timerSample(c: *Context) ?u64 {
        if (!c.timerAvailable()) {
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        c.eng.flush();
        if (!c.timerAvailable()) {
            c.timer_disjoint = true;
            return null;
        }
        const d = c.eng.dev.?;
        return d.vtable.timestampNs.?(d.ctx, engine.TIMEOUT_US) catch {
            c.timer_disjoint = true;
            c.fail(g.INVALID_OPERATION);
            return null;
        };
    }

    pub fn genTimerQueries(c: *Context, out: []u32) void {
        var free: usize = 0;
        for (c.timers, 0..) |q, i| {
            if (!q.named and c.elapsed != i + 1) free += 1;
        }
        if (free < out.len) return c.fail(g.OUT_OF_MEMORY);
        var n: usize = 0;
        for (&c.timers, 0..) |*q, i| {
            if (n == out.len) break;
            if (q.named or c.elapsed == i + 1) continue;
            q.* = .{ .named = true };
            out[n] = @intCast(i + 1);
            n += 1;
        }
    }

    fn timerOf(c: *Context, name: u32) ?*TimerQuery {
        if (name == 0 or name > c.timers.len) return null;
        const q = &c.timers[name - 1];
        return if (q.named) q else null;
    }

    pub fn isTimerQuery(c: *Context, name: u32) bool {
        const q = c.timerOf(name) orelse return false;
        return q.target != 0;
    }

    pub fn deleteTimerQueries(c: *Context, names: []const u32) void {
        for (names) |name| {
            if (c.timerOf(name)) |q| {
                if (c.occlusion == name) c.occlusion = 0;
                if (c.primitives == name) c.primitives = 0;
                if (c.elapsed == name) c.elapsed = 0;
                c.eng.freeImage(&q.word);
                q.* = .{};
            }
        }
    }

    /// glBeginQuery: a timer, an occlusion query (ANY_SAMPLES_PASSED, and
    /// its CONSERVATIVE form: exact here), transform feedback's primitives.
    pub fn beginQuery(c: *Context, target: u32, name: u32) void {
        switch (target) {
            TIME_ELAPSED_EXT => return c.beginTimer(target, name),
            g.ANY_SAMPLES_PASSED, g.ANY_SAMPLES_PASSED_CONSERVATIVE, g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN => {},
            else => return c.fail(g.INVALID_ENUM),
        }
        const q = c.timerOf(name) orelse return c.fail(g.INVALID_OPERATION);
        const occ = target != g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN;
        const busy_name = if (occ) c.occlusion else c.primitives;
        if (busy_name != 0 or (q.target != 0 and q.target != target) or c.elapsed == name or c.occlusion == name or c.primitives == name) return c.fail(g.INVALID_OPERATION);
        q.target = target;
        q.ready = false;
        q.value = 0;
        if (occ) {
            // (a word of its own, zeroed: the draws set it)
            c.eng.freeImage(&q.word);
            q.word = c.eng.newBuffer(16) orelse return c.fail(g.OUT_OF_MEMORY);
            c.occlusion = name;
        } else c.primitives = name;
    }

    pub fn endQuery(c: *Context, target: u32) void {
        switch (target) {
            TIME_ELAPSED_EXT => return c.endTimer(target),
            g.ANY_SAMPLES_PASSED, g.ANY_SAMPLES_PASSED_CONSERVATIVE => {
                const q = c.timerOf(c.occlusion) orelse return c.fail(g.INVALID_OPERATION);
                if (q.target != target) return c.fail(g.INVALID_OPERATION);
                c.occlusion = 0;
                q.mark = c.eng.mark();
            },
            g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN => {
                const q = c.timerOf(c.primitives) orelse return c.fail(g.INVALID_OPERATION);
                c.primitives = 0;
                q.ready = true;
            },
            else => c.fail(g.INVALID_ENUM),
        }
    }

    /// glGetQueryiv: CURRENT_QUERY (and a timer's counter bits).
    pub fn queryState(c: *Context, target: u32, pname: u32) ?i32 {
        if (target == TIME_ELAPSED_EXT or target == TIMESTAMP_EXT) return c.timerState(target, pname);
        if (pname != g.CURRENT_QUERY) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        return switch (target) {
            g.ANY_SAMPLES_PASSED, g.ANY_SAMPLES_PASSED_CONSERVATIVE => blk: {
                const q = c.timerOf(c.occlusion) orelse break :blk 0;
                break :blk if (q.target == target) @intCast(c.occlusion) else 0;
            },
            g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN => @intCast(c.primitives),
            else => blk: {
                c.fail(g.INVALID_ENUM);
                break :blk null;
            },
        };
    }

    /// glGetQueryObject*: QUERY_RESULT_AVAILABLE, QUERY_RESULT (waited for).
    pub fn queryResult(c: *Context, name: u32, pname: u32) ?u64 {
        const q = c.timerOf(name) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
        switch (q.target) {
            g.ANY_SAMPLES_PASSED, g.ANY_SAMPLES_PASSED_CONSERVATIVE => {},
            g.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN => {
                if (c.primitives == name) {
                    c.fail(g.INVALID_OPERATION);
                    return null;
                }
                return switch (pname) {
                    g.QUERY_RESULT_AVAILABLE => 1,
                    g.QUERY_RESULT => q.value,
                    else => blk: {
                        c.fail(g.INVALID_ENUM);
                        break :blk null;
                    },
                };
            },
            else => return c.timerResult(name, pname),
        }
        if (c.occlusion == name) {
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        if (!q.ready) {
            if (pname == g.QUERY_RESULT_AVAILABLE and !c.eng.markDone(q.mark)) return 0;
            var w: [4]u8 = .{ 0, 0, 0, 0 };
            if (q.word.buf.cpu.len >= 4) c.eng.readBytes(&q.word, 0, &w);
            q.value = @intFromBool(std.mem.readInt(u32, &w, .little) != 0);
            q.ready = true;
            c.eng.freeImage(&q.word);
        }
        return switch (pname) {
            g.QUERY_RESULT_AVAILABLE => 1,
            g.QUERY_RESULT => q.value,
            else => blk: {
                c.fail(g.INVALID_ENUM);
                break :blk null;
            },
        };
    }

    // ── Transform feedback objects ─────────────────────────────────────────

    pub fn genTransformFeedbacks(c: *Context, out: []u32) void {
        if (!genIn(Feedback, &c.feedbacks, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn deleteTransformFeedbacks(c: *Context, names: []const u32) void {
        for (names) |name| {
            const t = slotIn(Feedback, &c.feedbacks, name) orelse continue;
            if (t.active) {
                c.fail(g.INVALID_OPERATION);
                continue;
            }
            if (c.xfb == name) c.xfb = 0;
            t.* = .{};
        }
    }

    pub fn isTransformFeedback(c: *Context, name: u32) bool {
        return madeIn(Feedback, &c.feedbacks, name) != null;
    }

    pub fn bindTransformFeedback(c: *Context, target: u32, name: u32) void {
        if (target != g.TRANSFORM_FEEDBACK) return c.fail(g.INVALID_ENUM);
        if (c.feedbackOf()) |t| {
            if (t.active and !t.paused) return c.fail(g.INVALID_OPERATION);
        }
        if (name != 0) {
            const t = slotIn(Feedback, &c.feedbacks, name) orelse return c.fail(g.INVALID_OPERATION);
            if (!t.named) return c.fail(g.INVALID_OPERATION);
            t.made = true;
        }
        c.xfb = name;
    }

    pub fn beginTransformFeedback(c: *Context, mode: u32) void {
        if (mode != g.POINTS and mode != g.LINES and mode != g.TRIANGLES) return c.fail(g.INVALID_ENUM);
        const t = c.feedbackOf() orelse return;
        if (t.active or c.program == 0) return c.fail(g.INVALID_OPERATION);
        const ds = program.drawState(c) orelse return c.fail(g.INVALID_OPERATION);
        var any = false;
        for (ds.xfb_stride, 0..) |stride, i| {
            if (stride == 0) continue;
            any = true;
            if (t.bufs[i].buf == 0) return c.fail(g.INVALID_OPERATION);
        }
        if (!any) return c.fail(g.INVALID_OPERATION);
        t.active = true;
        t.paused = false;
        t.mode = mode;
        t.program = c.program;
        t.vertices = 0;
    }

    pub fn endTransformFeedback(c: *Context) void {
        const t = c.feedbackOf() orelse return;
        if (!t.active) return c.fail(g.INVALID_OPERATION);
        t.active = false;
        t.paused = false;
    }

    pub fn pauseTransformFeedback(c: *Context) void {
        const t = c.feedbackOf() orelse return;
        if (!t.active or t.paused) return c.fail(g.INVALID_OPERATION);
        t.paused = true;
    }

    pub fn resumeTransformFeedback(c: *Context) void {
        const t = c.feedbackOf() orelse return;
        if (!t.active or !t.paused or c.program != t.program) return c.fail(g.INVALID_OPERATION);
        t.paused = false;
    }

    /// A draw's capture: its whole primitives' vertices (each instance's)
    /// through the vertex code into the buffers, after those captured
    /// since the begin; INVALID_OPERATION when a buffer has no room.
    fn feedbackCapture(c: *Context, t: *Feedback, d: *const raster.Draw, mode: u32) bool {
        const ds = program.drawState(c) orelse {
            c.fail(g.INVALID_OPERATION);
            return false;
        };
        const per: u32 = switch (mode) {
            g.POINTS => 1,
            g.LINES => 2,
            else => 3,
        };
        const prims = d.count / per;
        if (prims == 0) return true;
        const n: u64 = @as(u64, prims) * per * d.instances;
        var outs: [raster.MAX_CAPTURE_BUFFERS]?*Image = @splat(null);
        var bases: [raster.MAX_CAPTURE_BUFFERS]u32 = @splat(0);
        for (ds.xfb_stride, 0..) |stride, i| {
            if (stride == 0) continue;
            const s = t.bufs[i];
            const b = madeIn(Buf, &c.objs.bufs, s.buf) orelse {
                c.fail(g.INVALID_OPERATION);
                return false;
            };
            const room: u64 = if (s.offset >= b.size) 0 else if (s.ranged) @min(s.size, b.size - s.offset) else b.size - s.offset;
            if ((t.vertices + n) * stride * 4 > room or b.store.buf.cpu.len < b.size) {
                c.fail(g.INVALID_OPERATION);
                return false;
            }
            if (!c.notMapped(b)) return false;
            outs[i] = &b.store;
            bases[i] = @intCast(s.offset / 4 + t.vertices * stride);
        }
        var cd = d.*;
        cd.count = prims * per;
        if (!c.eng.capture(&cd, outs, bases)) {
            c.fail(g.OUT_OF_MEMORY);
            return false;
        }
        t.vertices += n;
        if (c.timerOf(c.primitives)) |q| q.value += @as(u64, prims) * d.instances;
        return true;
    }

    pub fn beginTimer(c: *Context, target: u32, name: u32) void {
        if (target != TIME_ELAPSED_EXT) return c.fail(g.INVALID_ENUM);
        const q = c.timerOf(name) orelse return c.fail(g.INVALID_OPERATION);
        if (c.elapsed != 0 or (q.target != 0 and q.target != target)) return c.fail(g.INVALID_OPERATION);
        const t = c.timerSample() orelse return;
        q.target = target;
        q.ready = false;
        c.elapsed = name;
        c.elapsed_begin = t;
    }

    pub fn endTimer(c: *Context, target: u32) void {
        if (target != TIME_ELAPSED_EXT) return c.fail(g.INVALID_ENUM);
        if (c.elapsed == 0) return c.fail(g.INVALID_OPERATION);
        const name = c.elapsed;
        c.elapsed = 0;
        const q = c.timerOf(name) orelse return;
        const t = c.timerSample() orelse return;
        if (t < c.elapsed_begin) c.timer_disjoint = true;
        q.value = t -| c.elapsed_begin;
        q.ready = true;
    }

    pub fn timerCounter(c: *Context, name: u32, target: u32) void {
        if (target != TIMESTAMP_EXT) return c.fail(g.INVALID_ENUM);
        const q = c.timerOf(name) orelse return c.fail(g.INVALID_OPERATION);
        if (c.elapsed == name or (q.target != 0 and q.target != target)) return c.fail(g.INVALID_OPERATION);
        const t = c.timerSample() orelse return;
        q.target = target;
        q.ready = true;
        q.value = t;
    }

    pub fn timerState(c: *Context, target: u32, pname: u32) ?i32 {
        if (target == TIME_ELAPSED_EXT or target == TIMESTAMP_EXT) {
            if (pname == 0x8864) return if (c.timerAvailable()) 64 else 0;
            if (pname == 0x8865 and target == TIME_ELAPSED_EXT) return @intCast(c.elapsed);
        }
        c.fail(g.INVALID_ENUM);
        return null;
    }

    pub fn timerResult(c: *Context, name: u32, pname: u32) ?u64 {
        const q = c.timerOf(name) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
        if (q.target == 0 or c.elapsed == name) {
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        if (pname == 0x8867) return @intFromBool(q.ready);
        if (pname == 0x8866) {
            if (q.ready) return q.value;
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        c.fail(g.INVALID_ENUM);
        return null;
    }

    pub fn debugMarker(c: *Context, kind: enum { event, push, pop }, length: i32, marker: ?[*]const u8) void {
        if (kind == .pop) {
            if (c.marker_depth == 0) return;
            c.marker_depth -= 1;
            report.say(.marker, "GL marker: end group at depth {d}", .{c.marker_depth});
            return;
        }
        if (length < 0 or (kind == .event and marker == null)) return;
        var label: [128]u8 = undefined;
        var n: usize = 0;
        if (marker) |s| {
            const limit = if (length == 0) label.len else @min(label.len, @as(usize, @intCast(length)));
            while (n < limit) : (n += 1) {
                const ch = s[n];
                if (length == 0 and ch == 0) break;
                label[n] = if (ch >= 0x20 and ch < 0x7f) ch else '?';
            }
        }
        report.say(.marker, "GL marker: {s} at depth {d}: {s}", .{ @tagName(kind), c.marker_depth, label[0..n] });
        if (kind == .push) c.marker_depth +|= 1;
    }

    pub fn init(c: *Context, eng: *Engine, objs: *Objects) void {
        c.* = .{ .eng = eng, .objs = objs };
        for (&c.fbos) |*f| f.* = .{};
        for (&c.vaos) |*v| v.* = .{};
        objs.users += 1;
    }

    /// Its framebuffers go; the share group's objects go with its last
    /// context.
    pub fn deinit(c: *Context) void {
        program.leave(c);
        for (&c.fbos) |*f| {
            if (f.made) c.detachAll(f);
        }
        c.eng.freeImage(&c.default_tex.img);
        c.dropExtraLevels(&c.default_tex);
        c.eng.freeImage(&c.default_ext.img);
        c.objs.users -= 1;
        if (c.objs.users == 0) c.objs.release(c.eng);
    }

    /// The default framebuffer's images (eglMakeCurrent): drawn to, read
    /// from, depth and stencil. The first surface sets the viewport and
    /// scissor box to its size.
    pub fn setSurface(c: *Context, draw: ?*Image, read: ?*Image, depth: ?*Image) void {
        c.surf_draw = draw;
        c.surf_read = read;
        c.surf_depth = depth;
        if (!c.surf_seen) {
            if (draw) |d| {
                c.viewport = .{ 0, 0, @intCast(d.width), @intCast(d.height) };
                c.scissor = c.viewport;
                c.surf_seen = true;
            }
        }
    }

    pub fn fail(c: *Context, e: u32) void {
        report.say(.gl_error, "GL error 0x{x}", .{e});
        c.recordError(e);
    }

    pub fn invalidEnum(c: *Context, comptime op: []const u8, value: u32) void {
        report.say(.gl_error, "{s}: GL_INVALID_ENUM (0x{x})", .{ op, value });
        c.recordError(g.INVALID_ENUM);
    }

    fn recordError(c: *Context, e: u32) void {
        if (c.err == g.NO_ERROR) c.err = e;
        if (c.debug.enabled) {
            var buf: [32]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "GL error 0x{x}", .{e}) catch return;
            c.debug.emit(debug_output.API, debug_output.ERROR, e, debug_output.HIGH, msg);
        }
    }

    // ── Errors, strings, state ─────────────────────────────────────────────

    pub fn getError(c: *Context) u32 {
        // KHR_robustness: a context that loses itself on a reset says so
        // (once: the engine goes on on the CPU, so later calls still work)
        if (c.lose_on_reset and c.eng.lost and !c.lost_told) {
            c.lost_told = true;
            return g.CONTEXT_LOST;
        }
        const e = c.err;
        c.err = g.NO_ERROR;
        return e;
    }

    /// EXT_ and KHR_robustness: a reset once (the GPU was lost: the
    /// engine went on on the CPU), then none; nothing for a context whose
    /// strategy is NO_RESET_NOTIFICATION.
    pub fn getGraphicsResetStatus(c: *Context) u32 {
        if (!c.lose_on_reset or !c.eng.lost or c.reset_told) return g.NO_ERROR;
        c.reset_told = true;
        return g.UNKNOWN_CONTEXT_RESET;
    }

    pub fn getString(c: *Context, name: u32) ?[*:0]const u8 {
        return switch (name) {
            g.VENDOR => VENDOR_STRING.ptr,
            g.RENDERER => if (c.eng.onGpu()) "Galaxy (GPU)" else "Galaxy (CPU)",
            g.VERSION => VERSION_STRING.ptr,
            g.SHADING_LANGUAGE_VERSION => GLSL_STRING.ptr,
            g.EXTENSIONS => EXTENSIONS_STRING.ptr,
            else => {
                c.invalidEnum("glGetString", name);
                return null;
            },
        };
    }

    pub fn getStringi(c: *Context, name: u32, index: u32) ?[*:0]const u8 {
        if (name != g.EXTENSIONS) {
            c.invalidEnum("glGetStringi", name);
            return null;
        }
        if (index >= EXTENSIONS.len) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        return EXTENSIONS[index].ptr;
    }

    pub fn enable(c: *Context, cap: u32, on: bool) void {
        if (cap == debug_output.OUTPUT) {
            c.debug.enabled = on;
            return;
        }
        if (cap == debug_output.SYNCHRONOUS) {
            c.debug.synchronous = on;
            return;
        }
        const b = capBit(cap) orelse return if (on) c.invalidEnum("glEnable", cap) else c.invalidEnum("glDisable", cap);
        const m = @as(u32, 1) << b;
        if (on) c.enabled |= m else c.enabled &= ~m;
    }

    pub fn isEnabled(c: *Context, cap: u32) bool {
        if (cap == debug_output.OUTPUT) return c.debug.enabled;
        if (cap == debug_output.SYNCHRONOUS) return c.debug.synchronous;
        const b = capBit(cap) orelse {
            c.invalidEnum("glIsEnabled", cap);
            return false;
        };
        return c.enabled & (@as(u32, 1) << b) != 0;
    }

    pub fn hint(c: *Context, target: u32, mode: u32) void {
        if (mode != g.DONT_CARE and mode != g.FASTEST and mode != g.NICEST) return c.invalidEnum("glHint mode", mode);
        switch (target) {
            g.GENERATE_MIPMAP_HINT => c.hint_mipmap = mode,
            g.FRAGMENT_SHADER_DERIVATIVE_HINT => c.hint_derivative = mode,
            else => c.invalidEnum("glHint target", target),
        }
    }

    pub fn pixelStore(c: *Context, pname: u32, param: i32) void {
        const is_align = pname == g.PACK_ALIGNMENT or pname == g.UNPACK_ALIGNMENT;
        if (is_align and param != 1 and param != 2 and param != 4 and param != 8) return c.fail(g.INVALID_VALUE);
        if (!is_align and param < 0) return c.fail(g.INVALID_VALUE);
        switch (pname) {
            g.PACK_ALIGNMENT => c.pack.alignment = param,
            g.PACK_ROW_LENGTH => c.pack.row_length = param,
            g.PACK_SKIP_ROWS => c.pack.skip_rows = param,
            g.PACK_SKIP_PIXELS => c.pack.skip_pixels = param,
            g.UNPACK_ALIGNMENT => c.unpack.alignment = param,
            g.UNPACK_ROW_LENGTH => c.unpack.row_length = param,
            g.UNPACK_SKIP_ROWS => c.unpack.skip_rows = param,
            g.UNPACK_SKIP_PIXELS => c.unpack.skip_pixels = param,
            g.UNPACK_IMAGE_HEIGHT => c.unpack.image_height = param,
            g.UNPACK_SKIP_IMAGES => c.unpack.skip_images = param,
            else => c.invalidEnum("glPixelStorei", pname),
        }
    }

    pub fn flush(c: *Context) void {
        c.eng.flush();
        if (report.sink != null) c.usageTick(report.nowUs());
    }

    pub fn finish(c: *Context) void {
        c.eng.finish();
        if (report.sink != null) c.usageTick(report.nowUs());
    }

    /// The context's usage line, if one is due at `now_us` (asked at each
    /// flush, finish and swap: a clock read and a compare when it is not).
    pub fn usageTick(c: *Context, now_us: u64) void {
        if (!c.usage.due(now_us)) return;
        c.usage.tell(now_us, if (c.eng.onGpu()) c.eng.dev.?.caps.name else null, c.eng.usage());
    }

    /// An eglSwapBuffers of this context's done at `now_us`, having taken
    /// `took_us`.
    pub fn usageSwap(c: *Context, now_us: u64, took_us: u64) void {
        c.usage.swapped(took_us, c.eng.stats.wait_us);
        c.usageTick(now_us);
    }

    pub fn clearColor(c: *Context, r: f32, gr: f32, b: f32, a: f32) void {
        // (ES 3.0 keeps them clamped to [0, 1])
        c.clear_color = .{ clamp01(r), clamp01(gr), clamp01(b), clamp01(a) };
    }

    pub fn clearDepth(c: *Context, d: f32) void {
        c.clear_depth = clamp01(d);
    }

    pub fn clearStencil(c: *Context, s: i32) void {
        c.clear_stencil = s;
    }

    pub fn colorMask(c: *Context, r: bool, gr: bool, b: bool, a: bool) void {
        c.color_mask = .{ r, gr, b, a };
    }

    pub fn depthMask(c: *Context, on: bool) void {
        c.depth_mask = on;
    }

    pub fn stencilMaskSeparate(c: *Context, face: u32, mask: u32) void {
        switch (face) {
            0x0404 => c.stencil_mask = mask, // FRONT
            0x0405 => c.stencil_back_mask = mask, // BACK
            0x0408 => { // FRONT_AND_BACK
                c.stencil_mask = mask;
                c.stencil_back_mask = mask;
            },
            else => c.fail(g.INVALID_ENUM),
        }
    }

    pub fn stencilFuncSeparate(c: *Context, face: u32, func: u32, reference: i32, mask: u32) void {
        if (face != g.FRONT and face != g.BACK and face != g.FRONT_AND_BACK) return c.fail(g.INVALID_ENUM);
        if (func < g.NEVER or func > g.ALWAYS) return c.fail(g.INVALID_ENUM);
        const ref: u8 = @intCast(std.math.clamp(reference, 0, 255));
        if (face != g.BACK) {
            c.stencil_front.func = func;
            c.stencil_front.reference = ref;
            c.stencil_front.value_mask = mask;
        }
        if (face != g.FRONT) {
            c.stencil_back.func = func;
            c.stencil_back.reference = ref;
            c.stencil_back.value_mask = mask;
        }
    }

    pub fn stencilOpSeparate(c: *Context, face: u32, stencil_fail: u32, depth_fail: u32, pass: u32) void {
        if (face != g.FRONT and face != g.BACK and face != g.FRONT_AND_BACK) return c.fail(g.INVALID_ENUM);
        const sf = stencilOpOf(stencil_fail) orelse return c.fail(g.INVALID_ENUM);
        const df = stencilOpOf(depth_fail) orelse return c.fail(g.INVALID_ENUM);
        const dp = stencilOpOf(pass) orelse return c.fail(g.INVALID_ENUM);
        if (face != g.BACK) {
            c.stencil_front.fail = sf;
            c.stencil_front.depth_fail = df;
            c.stencil_front.pass = dp;
        }
        if (face != g.FRONT) {
            c.stencil_back.fail = sf;
            c.stencil_back.depth_fail = df;
            c.stencil_back.pass = dp;
        }
    }

    pub fn viewportSet(c: *Context, x: i32, y: i32, w: i32, h: i32) void {
        if (w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        c.viewport = .{ x, y, @min(w, MAX_SIZE), @min(h, MAX_SIZE) };
    }

    pub fn scissorSet(c: *Context, x: i32, y: i32, w: i32, h: i32) void {
        if (w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        c.scissor = .{ x, y, w, h };
    }

    // ── Queries ────────────────────────────────────────────────────────────

    /// A state value for glGet*: up to four of one kind.
    pub const Value = struct {
        kind: enum { int, float, boolean } = .int,
        n: u8 = 1,
        i: [4]i64 = .{ 0, 0, 0, 0 },
        f: [4]f32 = .{ 0, 0, 0, 0 },
        /// glGetIntegerv maps it from [-1, 1] to the whole int range
        /// (colors and depths)
        normalized: bool = false,
    };

    fn int(v: i64) Value {
        return .{ .i = .{ v, 0, 0, 0 } };
    }

    fn ints(vs: []const i64) Value {
        var x = Value{ .n = @intCast(vs.len) };
        @memcpy(x.i[0..vs.len], vs);
        return x;
    }

    fn boolean(b: bool) Value {
        return .{ .kind = .boolean, .i = .{ @intFromBool(b), 0, 0, 0 } };
    }

    /// pname's value, or null (INVALID_ENUM).
    pub fn get(c: *Context, pname: u32) ?Value {
        if (capBit(pname) != null) return boolean(c.enabled & bitOf(pname) != 0);
        if (pname >= g.DRAW_BUFFER0 and pname < g.DRAW_BUFFER0 + MAX_COLOR) {
            const i = pname - g.DRAW_BUFFER0;
            if (c.draw_fb == 0) return int(if (i == 0) c.default_draw else g.NONE);
            return int(c.fbos[c.draw_fb - 1].draw[i]);
        }
        return switch (pname) {
            TIMESTAMP_EXT => int(@intCast(@min(c.timerSample() orelse return null, std.math.maxInt(i64)))),
            0x8FBB => blk: {
                const value = c.timer_disjoint or c.eng.lost;
                c.timer_disjoint = false;
                break :blk boolean(value);
            },
            0x821E => int(if (c.debug_context) 2 else 0), // CONTEXT_FLAGS
            debug_output.OUTPUT => boolean(c.debug.enabled),
            debug_output.SYNCHRONOUS => boolean(c.debug.synchronous),
            0x9143 => int(debug_output.MAX_TEXT), // MAX_DEBUG_MESSAGE_LENGTH
            0x9144 => int(debug_output.MAX_MESSAGES), // MAX_DEBUG_LOGGED_MESSAGES
            0x82E8 => int(debug_output.MAX_LABEL_LENGTH),
            0x826C => int(debug_output.MAX_GROUP_DEPTH), // MAX_DEBUG_GROUP_STACK_DEPTH
            0x826D => int(@intCast(c.debug.group_len + 1)), // DEBUG_GROUP_STACK_DEPTH
            0x9145 => int(@intCast(c.debug.len)), // DEBUG_LOGGED_MESSAGES
            0x8243 => int(@intCast(c.debug.nextLength())), // DEBUG_NEXT_LOGGED_MESSAGE_LENGTH
            g.VIEWPORT => ints(&.{ c.viewport[0], c.viewport[1], c.viewport[2], c.viewport[3] }),
            g.SCISSOR_BOX => ints(&.{ c.scissor[0], c.scissor[1], c.scissor[2], c.scissor[3] }),
            g.COLOR_CLEAR_VALUE => .{ .kind = .float, .n = 4, .f = c.clear_color, .normalized = true },
            g.DEPTH_CLEAR_VALUE => .{ .kind = .float, .f = .{ c.clear_depth, 0, 0, 0 }, .normalized = true },
            g.STENCIL_CLEAR_VALUE => int(c.clear_stencil),
            g.COLOR_WRITEMASK => .{ .kind = .boolean, .n = 4, .i = .{ @intFromBool(c.color_mask[0]), @intFromBool(c.color_mask[1]), @intFromBool(c.color_mask[2]), @intFromBool(c.color_mask[3]) } },
            g.DEPTH_WRITEMASK => boolean(c.depth_mask),
            g.STENCIL_WRITEMASK => int(c.stencil_mask),
            g.STENCIL_BACK_WRITEMASK => int(c.stencil_back_mask),
            g.STENCIL_FUNC => int(c.stencil_front.func),
            g.STENCIL_REF => int(c.stencil_front.reference),
            g.STENCIL_VALUE_MASK => int(c.stencil_front.value_mask),
            g.STENCIL_FAIL => int(stencilEnum(c.stencil_front.fail)),
            g.STENCIL_PASS_DEPTH_FAIL => int(stencilEnum(c.stencil_front.depth_fail)),
            g.STENCIL_PASS_DEPTH_PASS => int(stencilEnum(c.stencil_front.pass)),
            g.STENCIL_BACK_FUNC => int(c.stencil_back.func),
            g.STENCIL_BACK_REF => int(c.stencil_back.reference),
            g.STENCIL_BACK_VALUE_MASK => int(c.stencil_back.value_mask),
            g.STENCIL_BACK_FAIL => int(stencilEnum(c.stencil_back.fail)),
            g.STENCIL_BACK_PASS_DEPTH_FAIL => int(stencilEnum(c.stencil_back.depth_fail)),
            g.STENCIL_BACK_PASS_DEPTH_PASS => int(stencilEnum(c.stencil_back.pass)),
            g.MAX_TEXTURE_SIZE, g.MAX_CUBE_MAP_TEXTURE_SIZE, g.MAX_RENDERBUFFER_SIZE => int(MAX_SIZE),
            g.MAX_VIEWPORT_DIMS => ints(&.{ MAX_SIZE, MAX_SIZE }),
            g.MAX_COLOR_ATTACHMENTS, g.MAX_DRAW_BUFFERS => int(MAX_COLOR),
            // (GL ES 3.0's: WebGL 2 asks them at a context's start)
            g.MAX_3D_TEXTURE_SIZE, g.MAX_ARRAY_TEXTURE_LAYERS => int(2048),
            g.MAX_ELEMENT_INDEX => int(std.math.maxInt(u32)),
            g.MAX_TEXTURE_LOD_BIAS => .{ .kind = .float, .f = .{ 16, 0, 0, 0 } },
            g.MAX_UNIFORM_BUFFER_BINDINGS => int(program.MAX_UNIFORM_BUFFER_BINDINGS),
            g.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS => int(program.MAX_XFB_COMPONENTS),
            g.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS => int(MAX_FEEDBACK_BUFFERS),
            g.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS => int(program.MAX_XFB_SEPARATE_COMPONENTS),
            g.TRANSFORM_FEEDBACK_BINDING => int(c.xfb),
            g.TRANSFORM_FEEDBACK_BUFFER_BINDING => int(c.bufs.xfb),
            g.TRANSFORM_FEEDBACK_ACTIVE => boolean(if (c.feedbackOf()) |t| t.active else false),
            g.TRANSFORM_FEEDBACK_PAUSED => boolean(if (c.feedbackOf()) |t| t.paused else false),
            g.MAX_VERTEX_UNIFORM_BLOCKS, g.MAX_FRAGMENT_UNIFORM_BLOCKS => int(glsl_max_blocks),
            g.MAX_COMBINED_UNIFORM_BLOCKS => int(program.MAX_BLOCKS),
            g.MAX_UNIFORM_BLOCK_SIZE => int(program.MAX_UNIFORM_BLOCK_SIZE),
            g.UNIFORM_BUFFER_OFFSET_ALIGNMENT => int(program.UNIFORM_BUFFER_OFFSET_ALIGNMENT),
            g.MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS => int(program.MAX_VERTEX_UNIFORM_VECTORS * 4 + glsl_max_blocks * program.MAX_UNIFORM_BLOCK_SIZE / 4),
            g.MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS => int(program.MAX_FRAGMENT_UNIFORM_VECTORS * 4 + glsl_max_blocks * program.MAX_UNIFORM_BLOCK_SIZE / 4),
            g.MAX_TEXTURE_IMAGE_UNITS => int(16),
            g.MAX_COMBINED_TEXTURE_IMAGE_UNITS => int(MAX_UNITS),
            g.MAX_SAMPLES => int(1),
            // (lines and points are one pixel: Firefox's WebGL asks both at
            // a context's start and gives the context up on an error)
            g.ALIASED_LINE_WIDTH_RANGE, g.ALIASED_POINT_SIZE_RANGE => .{ .kind = .float, .n = 2, .f = .{ 1, 1, 0, 0 } },
            g.RESET_NOTIFICATION_STRATEGY => int(if (c.lose_on_reset) g.LOSE_CONTEXT_ON_RESET else g.NO_RESET_NOTIFICATION),
            // (out-of-range reads are not promised to be safe: no
            // robust_buffer_access_behavior)
            g.CONTEXT_ROBUST_ACCESS => boolean(false),
            g.SAMPLES, g.SAMPLE_BUFFERS => int(0),
            g.SUBPIXEL_BITS => int(4),
            g.MAJOR_VERSION => int(3),
            g.MINOR_VERSION => int(0),
            g.NUM_EXTENSIONS => int(EXTENSIONS.len),
            g.DRAW_FRAMEBUFFER_BINDING => int(c.draw_fb),
            g.READ_FRAMEBUFFER_BINDING => int(c.read_fb),
            g.RENDERBUFFER_BINDING => int(c.rb),
            g.TEXTURE_BINDING_2D => int(c.tex2d[c.unit]),
            g.TEXTURE_BINDING_3D => int(c.layered[0][c.unit]),
            g.TEXTURE_BINDING_2D_ARRAY => int(c.layered[1][c.unit]),
            g.TEXTURE_BINDING_CUBE_MAP => int(c.layered[2][c.unit]),
            g.TEXTURE_BINDING_EXTERNAL_OES => int(c.tex_ext[c.unit]),
            g.SAMPLER_BINDING => int(c.smp[c.unit]),
            g.REQUIRED_TEXTURE_IMAGE_UNITS_OES => int(1),
            g.ACTIVE_TEXTURE => int(g.TEXTURE0 + c.unit),
            g.ARRAY_BUFFER_BINDING => int(c.bufs.array),
            g.ELEMENT_ARRAY_BUFFER_BINDING => int(c.curVao().element),
            g.VERTEX_ARRAY_BINDING => int(c.vao),
            g.MAX_VERTEX_ATTRIBS => int(MAX_ATTRS),
            g.CURRENT_PROGRAM => int(c.program),
            g.SHADER_COMPILER => boolean(true),
            g.NUM_SHADER_BINARY_FORMATS, g.NUM_PROGRAM_BINARY_FORMATS => int(0),
            g.MAX_VERTEX_UNIFORM_VECTORS => int(program.MAX_VERTEX_UNIFORM_VECTORS),
            g.MAX_FRAGMENT_UNIFORM_VECTORS => int(program.MAX_FRAGMENT_UNIFORM_VECTORS),
            g.MAX_VERTEX_UNIFORM_COMPONENTS => int(program.MAX_VERTEX_UNIFORM_VECTORS * 4),
            g.MAX_FRAGMENT_UNIFORM_COMPONENTS => int(program.MAX_FRAGMENT_UNIFORM_VECTORS * 4),
            g.MAX_VARYING_VECTORS => int(program.MAX_VARYING_VECTORS),
            g.MAX_VARYING_COMPONENTS, g.MAX_FRAGMENT_INPUT_COMPONENTS => int(program.MAX_VARYING_VECTORS * 4),
            g.MAX_VERTEX_OUTPUT_COMPONENTS => int(16 * 4),
            g.MAX_VERTEX_TEXTURE_IMAGE_UNITS => int(16),
            g.MIN_PROGRAM_TEXEL_OFFSET => int(-8),
            g.MAX_PROGRAM_TEXEL_OFFSET => int(7),
            g.BLEND_SRC_RGB => int(c.blend_src_rgb),
            g.BLEND_DST_RGB => int(c.blend_dst_rgb),
            g.BLEND_SRC_ALPHA => int(c.blend_src_a),
            g.BLEND_DST_ALPHA => int(c.blend_dst_a),
            g.BLEND_EQUATION_RGB => int(c.blend_eq_rgb),
            g.BLEND_EQUATION_ALPHA => int(c.blend_eq_a),
            g.BLEND_COLOR => .{ .kind = .float, .n = 4, .f = c.blend_color, .normalized = true },
            g.DEPTH_FUNC => int(c.depth_func),
            g.DEPTH_RANGE => .{ .kind = .float, .n = 2, .f = .{ c.depth_range[0], c.depth_range[1], 0, 0 }, .normalized = true },
            g.CULL_FACE_MODE => int(c.cull_mode),
            g.FRONT_FACE => int(c.front_face),
            g.PIXEL_PACK_BUFFER_BINDING => int(c.bufs.pack),
            g.PIXEL_UNPACK_BUFFER_BINDING => int(c.bufs.unpack),
            g.UNIFORM_BUFFER_BINDING => int(c.bufs.uniform),
            g.COPY_READ_BUFFER => int(c.bufs.copy_read),
            g.COPY_WRITE_BUFFER => int(c.bufs.copy_write),
            g.PACK_ALIGNMENT => int(c.pack.alignment),
            g.PACK_ROW_LENGTH => int(c.pack.row_length),
            g.PACK_SKIP_ROWS => int(c.pack.skip_rows),
            g.PACK_SKIP_PIXELS => int(c.pack.skip_pixels),
            g.UNPACK_ALIGNMENT => int(c.unpack.alignment),
            g.UNPACK_ROW_LENGTH => int(c.unpack.row_length),
            g.UNPACK_SKIP_ROWS => int(c.unpack.skip_rows),
            g.UNPACK_SKIP_PIXELS => int(c.unpack.skip_pixels),
            g.UNPACK_IMAGE_HEIGHT => int(c.unpack.image_height),
            g.UNPACK_SKIP_IMAGES => int(c.unpack.skip_images),
            g.READ_BUFFER => int(if (c.read_fb == 0) c.default_read else c.fbos[c.read_fb - 1].read),
            g.IMPLEMENTATION_COLOR_READ_FORMAT => blk: {
                const v = c.view(c.read_fb, true);
                const img = v.read orelse break :blk int(g.RGBA);
                break :blk int(switch (img.format) {
                    .bgra8 => g.BGRA_EXT,
                    .r8 => g.RED,
                    .rg8 => g.RG,
                    else => g.RGBA,
                });
            },
            g.IMPLEMENTATION_COLOR_READ_TYPE => int(g.UNSIGNED_BYTE),
            g.RED_BITS, g.GREEN_BITS, g.BLUE_BITS => int(if (c.view(c.draw_fb, false).color[0]) |img| (if (img.format.channels() > pname - g.RED_BITS) 8 else 0) else 0),
            g.ALPHA_BITS => int(if (c.view(c.draw_fb, false).color[0]) |img| (if (img.no_alpha or img.format.channels() < 4) 0 else 8) else 0),
            g.DEPTH_BITS => int(if (c.view(c.draw_fb, false).depth != null) 24 else 0),
            g.STENCIL_BITS => int(if (c.view(c.draw_fb, false).stencil != null) 8 else 0),
            g.GENERATE_MIPMAP_HINT => int(c.hint_mipmap),
            g.FRAGMENT_SHADER_DERIVATIVE_HINT => int(c.hint_derivative),
            // (glWaitSync waits for nothing: no timeout but TIMEOUT_IGNORED)
            g.MAX_SERVER_WAIT_TIMEOUT => int(0),
            else => null,
        };
    }

    pub fn getIntegers(c: *Context, pname: u32, out: []i32) void {
        const v = c.get(pname) orelse return c.invalidEnum("glGetIntegerv", pname);
        for (0..@min(v.n, out.len)) |i| {
            out[i] = switch (v.kind) {
                .int, .boolean => @truncate(v.i[i]),
                .float => if (v.normalized)
                    @intFromFloat(std.math.clamp(@round(@as(f64, v.f[i]) * 2147483647.0), -2147483648.0, 2147483647.0))
                else
                    @intFromFloat(@round(v.f[i])),
            };
        }
    }

    pub fn getFloats(c: *Context, pname: u32, out: []f32) void {
        const v = c.get(pname) orelse return c.invalidEnum("glGetFloatv", pname);
        for (0..@min(v.n, out.len)) |i| {
            out[i] = switch (v.kind) {
                .int, .boolean => @floatFromInt(v.i[i]),
                .float => v.f[i],
            };
        }
    }

    pub fn getBooleans(c: *Context, pname: u32, out: []u8) void {
        const v = c.get(pname) orelse return c.invalidEnum("glGetBooleanv", pname);
        for (0..@min(v.n, out.len)) |i| {
            out[i] = @intFromBool(switch (v.kind) {
                .int, .boolean => v.i[i] != 0,
                .float => v.f[i] != 0,
            });
        }
    }

    // ── Framebuffers as operations see them ────────────────────────────────

    fn rbOf(c: *Context, name: u32) ?*Rb {
        return slotIn(Rb, &c.objs.rbs, name);
    }

    /// The image an attachment names, and whether it may be attached
    /// there: null with `ok` when nothing is attached.
    fn attached(c: *Context, a: *Attach, want: enum { color, depth, stencil }) struct { img: ?*Image, ok: bool } {
        switch (a.kind) {
            .none => return .{ .img = null, .ok = true },
            .tex => {
                const t = slotIn(Tex, &c.objs.tex, a.name) orelse return .{ .img = null, .ok = false };
                const face = if (a.face != 0 and !t.immutable) c.cubeFace(t, a.level, a.layer) else null;
                const mip = if (face) |f| levelOfExtra(f) else c.textureLevel(t, a.level) orelse return .{ .img = null, .ok = false };
                const layer = if (face != null) 0 else a.layer;
                if (!mip.img.live() or layer >= mip.layers) return .{ .img = null, .ok = false };
                const ok = switch (want) {
                    .color => mip.img.format.renderable() and renderableInternal(mip.internal) and !mip.srgb,
                    .depth => hasDepth(mip.internal),
                    .stencil => hasStencil(mip.internal),
                };
                if (t.target == g.TEXTURE_2D and mip.level == 0) return .{ .img = mip.img, .ok = ok };
                a.slice = engine.borrowSlice(mip.img, mip.share, mip.level, layer);
                return .{ .img = &a.slice, .ok = ok };
            },
            .rb => {
                const rb = c.rbOf(a.name) orelse return .{ .img = null, .ok = false };
                if (!rb.img.live()) return .{ .img = null, .ok = false };
                const ok = switch (want) {
                    .color => rb.img.format.renderable(),
                    .depth => hasDepth(rb.internal),
                    .stencil => hasStencil(rb.internal),
                };
                return .{ .img = &rb.img, .ok = ok };
            },
        }
    }

    /// Framebuffer `name` (0: the default one) as drawing (or, with
    /// `for_read`, reading) sees it, and its completeness.
    fn view(c: *Context, name: u32, for_read: bool) View {
        var v = View{};
        if (name == 0) {
            if (c.revalidate) |rv| {
                if (rv.stale.load(.acquire)) rv.f(rv.ctx);
            }
            const draw = if (c.default_draw == g.BACK) c.surf_draw else null;
            if (c.surf_draw == null and c.surf_read == null and c.surf_depth == null) {
                v.status = g.FRAMEBUFFER_UNDEFINED;
                return v;
            }
            v.color[0] = draw;
            v.read = if (c.default_read == g.BACK) c.surf_read else null;
            v.depth = c.surf_depth;
            v.stencil = c.surf_depth;
            const base = if (for_read) (c.surf_read orelse c.surf_depth) else (c.surf_draw orelse c.surf_depth);
            if (base) |b| {
                v.width = b.width;
                v.height = b.height;
            }
            return v;
        }
        const f = &c.fbos[name - 1];
        var any = false;
        var w: u32 = std.math.maxInt(u32);
        var h: u32 = std.math.maxInt(u32);
        var bad = false;
        var colors: [MAX_COLOR]?*Image = [_]?*Image{null} ** MAX_COLOR;
        for (&f.color, 0..) |*a, i| {
            const x = c.attached(a, .color);
            if (!x.ok) bad = true;
            colors[i] = x.img;
        }
        const d = c.attached(&f.depth, .depth);
        var s = c.attached(&f.stencil, .stencil);
        if (d.ok and s.ok and f.depth.kind == .tex and f.stencil.kind == .tex and
            f.depth.name == f.stencil.name and f.depth.level == f.stencil.level and f.depth.layer == f.stencil.layer)
            s.img = d.img;
        if (!d.ok or !s.ok) bad = true;
        var all: [MAX_COLOR + 2]?*Image = undefined;
        @memcpy(all[0..MAX_COLOR], &colors);
        all[MAX_COLOR] = d.img;
        all[MAX_COLOR + 1] = s.img;
        for (all) |img| {
            const im = img orelse continue;
            any = true;
            w = @min(w, im.width);
            h = @min(h, im.height);
        }
        v.status = if (bad)
            g.FRAMEBUFFER_INCOMPLETE_ATTACHMENT
        else if (!any)
            g.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT
        else
            g.FRAMEBUFFER_COMPLETE;
        if (v.status != g.FRAMEBUFFER_COMPLETE) return v;
        v.width = w;
        v.height = h;
        for (f.draw, 0..) |db, i| {
            v.color[i] = if (db == g.NONE) null else colors[db - g.COLOR_ATTACHMENT0];
        }
        v.read = if (f.read == g.NONE) null else colors[f.read - g.COLOR_ATTACHMENT0];
        v.depth = d.img;
        v.stencil = s.img;
        return v;
    }

    /// The draw framebuffer, complete; else INVALID_FRAMEBUFFER_OPERATION.
    fn drawView(c: *Context) ?View {
        const v = c.view(c.draw_fb, false);
        if (v.status != g.FRAMEBUFFER_COMPLETE) {
            c.fail(g.INVALID_FRAMEBUFFER_OPERATION);
            return null;
        }
        return v;
    }

    /// What a clear of `v` reaches: all of it, or the scissor box's part.
    fn clearRect(c: *const Context, v: *const View) Rect {
        var a = v.bounds();
        if (c.enabled & bitOf(g.SCISSOR_TEST) != 0) {
            const s = c.scissor;
            const x0: i64 = @max(s[0], 0);
            const y0: i64 = @max(s[1], 0);
            const x1: i64 = @max(@as(i64, s[0]) + s[2], 0);
            const y1: i64 = @max(@as(i64, s[1]) + s[3], 0);
            const cap = struct {
                fn f(x: i64) u32 {
                    return @intCast(@min(x, MAX_SIZE));
                }
            }.f;
            a = a.meet(.{ .x0 = cap(x0), .y0 = cap(y0), .x1 = cap(x1), .y1 = cap(y1) });
        }
        return a;
    }

    // ── Clears ─────────────────────────────────────────────────────────────

    pub fn clear(c: *Context, mask: u32) void {
        if (mask & ~(g.COLOR_BUFFER_BIT | g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT) != 0) return c.fail(g.INVALID_VALUE);
        var v = c.drawView() orelse return;
        // (Mesa: a clear draws nothing while rasterizer discard is on)
        if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
        const a = c.clearRect(&v);
        if (a.empty()) return;
        if (mask & g.COLOR_BUFFER_BIT != 0) {
            for (v.color) |img| {
                if (img) |im| c.fillColor(im, a, c.clear_color);
            }
        }
        c.fillDepthStencil(&v, a, mask & g.DEPTH_BUFFER_BIT != 0, c.clear_depth, mask & g.STENCIL_BUFFER_BIT != 0, c.clear_stencil);
    }

    fn fillColor(c: *Context, img: *Image, a: Rect, rgba: [4]f32) void {
        const keep = colorKeep(img.format, c.color_mask);
        c.eng.fill(img, a, packColor(img.format, .{ clamp01(rgba[0]), clamp01(rgba[1]), clamp01(rgba[2]), clamp01(rgba[3]) }), keep);
    }

    fn fillDepthStencil(c: *Context, v: *View, a: Rect, depth: bool, d: f32, stencil: bool, s: i32) void {
        const dimg = if (depth and c.depth_mask) v.depth else null;
        const smask = c.stencil_mask & 0xff;
        const simg = if (stencil and smask != 0) v.stencil else null;
        const dval = unorm(clamp01(d), 24);
        const sval = (@as(u32, @bitCast(s)) & 0xff) << 24;
        if (dimg != null and simg != null and dimg.? == simg.?) {
            const write = 0x00ff_ffff | (smask << 24);
            return c.eng.fill(dimg.?, a, dval | sval, ~write);
        }
        if (dimg) |im| c.eng.fill(im, a, dval, 0xff00_0000);
        if (simg) |im| c.eng.fill(im, a, sval, ~(smask << 24));
    }

    /// glClearBufferfv: COLOR (buffer: a draw buffer) or DEPTH (0).
    pub fn clearBufferf(c: *Context, buffer: u32, drawbuffer: i32, value: []const f32) void {
        switch (buffer) {
            g.COLOR => {
                if (drawbuffer < 0 or drawbuffer >= MAX_COLOR) return c.fail(g.INVALID_VALUE);
                var v = c.drawView() orelse return;
                if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
                const img = v.color[@intCast(drawbuffer)] orelse return;
                const a = c.clearRect(&v);
                if (!a.empty()) c.fillColor(img, a, value[0..4].*);
            },
            g.DEPTH => {
                if (drawbuffer != 0) return c.fail(g.INVALID_VALUE);
                var v = c.drawView() orelse return;
                if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
                const a = c.clearRect(&v);
                if (!a.empty()) c.fillDepthStencil(&v, a, true, value[0], false, 0);
            },
            else => c.fail(g.INVALID_ENUM),
        }
    }

    /// glClearBufferiv: STENCIL (0), or COLOR (integer buffers: none here,
    /// so nothing, as for any normalized buffer).
    pub fn clearBufferi(c: *Context, buffer: u32, drawbuffer: i32, value: []const i32) void {
        switch (buffer) {
            g.STENCIL => {
                if (drawbuffer != 0) return c.fail(g.INVALID_VALUE);
                var v = c.drawView() orelse return;
                if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
                const a = c.clearRect(&v);
                if (!a.empty()) c.fillDepthStencil(&v, a, false, 0, true, value[0]);
            },
            g.COLOR => if (drawbuffer < 0 or drawbuffer >= MAX_COLOR) c.fail(g.INVALID_VALUE),
            else => c.fail(g.INVALID_ENUM),
        }
    }

    /// glClearBufferuiv: COLOR only (integer buffers: none here).
    pub fn clearBufferu(c: *Context, buffer: u32, drawbuffer: i32) void {
        if (buffer != g.COLOR) return c.fail(g.INVALID_ENUM);
        if (drawbuffer < 0 or drawbuffer >= MAX_COLOR) c.fail(g.INVALID_VALUE);
    }

    /// glClearBufferfi: DEPTH_STENCIL (0).
    pub fn clearBufferfi(c: *Context, buffer: u32, drawbuffer: i32, depth: f32, stencil: i32) void {
        if (buffer != g.DEPTH_STENCIL) return c.fail(g.INVALID_ENUM);
        if (drawbuffer != 0) return c.fail(g.INVALID_VALUE);
        var v = c.drawView() orelse return;
        if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
        const a = c.clearRect(&v);
        if (!a.empty()) c.fillDepthStencil(&v, a, true, depth, true, stencil);
    }

    // ── Reading pixels ─────────────────────────────────────────────────────

    /// glReadPixels: pixels outside the framebuffer are left as they were.
    /// glReadnPixels (robustness): as readPixels, writing at most
    /// buf_size bytes; more needed: INVALID_OPERATION, nothing written.
    pub fn readnPixels(c: *Context, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, buf_size: i32, pixels: ?*anyopaque) void {
        if (buf_size < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        const want = switch (clientFormat(format, ty)) {
            .ok => |f| f,
            .err => |e| return c.fail(e),
        };
        const bpp = want.bytes();
        const l = c.pack.layout(@intCast(w), bpp);
        if (spanOf(l.first, l.row, @intCast(w), @intCast(h), bpp) > @as(usize, @intCast(buf_size))) return c.fail(g.INVALID_OPERATION);
        c.readPixels(x, y, w, h, format, ty, pixels);
    }

    pub fn readPixels(c: *Context, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, pixels: ?*anyopaque) void {
        if (w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        const want = switch (clientFormat(format, ty)) {
            .ok => |f| f,
            .err => |e| return c.fail(e),
        };
        const v = c.view(c.read_fb, true);
        if (v.status != g.FRAMEBUFFER_COMPLETE) return c.fail(g.INVALID_FRAMEBUFFER_OPERATION);
        const src = v.read orelse return c.fail(g.INVALID_OPERATION);
        // (RED and RG: only as the framebuffer is, its read format)
        if (!want.isColor() and want != src.format) return c.fail(g.INVALID_OPERATION);
        const bpp = want.bytes();
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const l = c.pack.layout(uw, bpp);
        const span = spanOf(l.first, l.row, uw, uh, bpp);
        if (span == 0) return;
        var pbo: ?*Buf = null;
        const dst: []u8 = if (c.bufs.pack != 0) blk: {
            const b = madeIn(Buf, &c.objs.bufs, c.bufs.pack) orelse return c.fail(g.INVALID_OPERATION);
            if (!c.notMapped(b)) return;
            const off = addr(pixels);
            if (off > b.size or span > b.size - off) return c.fail(g.INVALID_OPERATION);
            pbo = b;
            break :blk c.eng.hostView(&b.store, off, span);
        } else blk: {
            const p = pixels orelse return;
            break :blk @as([*]u8, @ptrCast(p))[0..span];
        };
        // (the part inside the framebuffer)
        const x0: i64 = @max(x, 0);
        const y0: i64 = @max(y, 0);
        const x1: i64 = @min(@as(i64, x) + w, v.width);
        const y1: i64 = @min(@as(i64, y) + h, v.height);
        if (x1 <= x0 or y1 <= y0) return;
        const at = l.first + @as(usize, @intCast(y0 - y)) * l.row + @as(usize, @intCast(x0 - x)) * bpp;
        c.eng.read(src, @intCast(x0), @intCast(y0), @intCast(x1 - x0), @intCast(y1 - y0), dst[at..], l.row, want);
        if (pbo) |b| c.eng.wrote(&b.store, addr(pixels), span);
    }

    // ── Textures ───────────────────────────────────────────────────────────

    pub fn genTextures(c: *Context, out: []u32) void {
        if (!genIn(Tex, &c.objs.tex, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn isTexture(c: *Context, name: u32) bool {
        return madeIn(Tex, &c.objs.tex, name) != null;
    }

    pub fn activeTexture(c: *Context, unit: u32) void {
        if (unit < g.TEXTURE0 or unit >= g.TEXTURE0 + MAX_UNITS) return c.fail(g.INVALID_ENUM);
        c.unit = unit - g.TEXTURE0;
    }

    pub fn bindTexture(c: *Context, target: u32, name: u32) void {
        const binding = c.textureBinding(target) orelse return c.fail(g.INVALID_ENUM);
        if (name != 0) {
            const t = slotIn(Tex, &c.objs.tex, name) orelse return c.fail(g.OUT_OF_MEMORY);
            if (t.made and t.target != target) return c.fail(g.INVALID_OPERATION);
            const fresh = !t.made;
            const m = makeIn(Tex, &c.objs.tex, name) orelse return c.fail(g.OUT_OF_MEMORY);
            m.target = target;
            // (an external texture's defaults: linear, clamped)
            if (fresh and target == g.TEXTURE_EXTERNAL_OES) m.params = c.default_ext.params;
        }
        binding.* = name;
    }

    fn textureBinding(c: *Context, target: u32) ?*u32 {
        return switch (target) {
            g.TEXTURE_2D => &c.tex2d[c.unit],
            g.TEXTURE_EXTERNAL_OES => &c.tex_ext[c.unit],
            g.TEXTURE_3D => &c.layered[0][c.unit],
            g.TEXTURE_2D_ARRAY => &c.layered[1][c.unit],
            g.TEXTURE_CUBE_MAP => &c.layered[2][c.unit],
            else => null,
        };
    }

    fn boundLayered(c: *Context, target: u32) ?*Tex {
        const binding = c.textureBinding(target) orelse {
            c.fail(g.INVALID_ENUM);
            return null;
        };
        return madeIn(Tex, &c.objs.tex, binding.*) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
    }

    /// The texture bound to `target` on the active unit.
    fn boundTex(c: *Context, target: u32) ?*Tex {
        const name = switch (target) {
            g.TEXTURE_2D => c.tex2d[c.unit],
            g.TEXTURE_EXTERNAL_OES => c.tex_ext[c.unit],
            g.TEXTURE_3D, g.TEXTURE_2D_ARRAY, g.TEXTURE_CUBE_MAP => return c.boundLayered(target),
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
        if (name == 0) return if (target == g.TEXTURE_2D) &c.default_tex else &c.default_ext;
        return madeIn(Tex, &c.objs.tex, name);
    }

    /// boundTex for what only a 2D texture takes (an external texture's
    /// storage is an EGLImage's).
    fn boundTex2D(c: *Context, target: u32) ?*Tex {
        if (target != g.TEXTURE_2D) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        return c.boundTex(target);
    }

    /// glEGLImageTargetTexture2DOES: the bound texture's storage becomes
    /// the EGLImage's (shared: drawn into, read, by either).
    pub fn eglImageTargetTexture2D(c: *Context, target: u32, image: ?*anyopaque) void {
        if (target != g.TEXTURE_2D and target != g.TEXTURE_EXTERNAL_OES) return c.fail(g.INVALID_ENUM);
        const t = c.boundTex(target) orelse return;
        const resolve = egl_image orelse return c.fail(g.INVALID_OPERATION);
        const src = resolve(image) orelse return c.fail(g.INVALID_VALUE);
        if (t.immutable) return c.fail(g.INVALID_OPERATION);
        t.disconnectStream();
        c.eng.freeImage(&t.img);
        t.img = engine.alias(src);
        t.internal = imageInternal(src.format);
        t.levels = 1;
        t.defined = 1;
        t.fswz = .{ 0, 1, 2, 3 };
        t.srgb = false;
    }

    /// EGL_KHR_gl_texture_2D_image: level 0 of texture `name` (a
    /// TEXTURE_2D of this context's share group) as an EGLImage's memory,
    /// `sh` holding it and the texture its first name. Its memory moves to
    /// a GPU buffer of its own first (engine.shareOwn), so the image's
    /// dma-buf can be exported (EGL_MESA_image_dma_buf_export: Firefox's
    /// dma-buf surfaces are textures made so).
    pub fn textureImage(c: *Context, name: u32, sh: *engine.Shared) error{ BadParameter, BadMatch, BadAccess, BadAlloc }!*Image {
        if (name == 0) return error.BadParameter;
        const t = madeIn(Tex, &c.objs.tex, name) orelse return error.BadParameter;
        if (t.target != g.TEXTURE_2D) return error.BadParameter;
        if (!t.img.live() or t.defined & 1 == 0) return error.BadMatch;
        // (an EGLImage's sibling already: EGL_KHR_image_base's BAD_ACCESS;
        // or its levels are framebuffer slices)
        if (t.img.share != null or !t.img.own or t.img.top_down) return error.BadAccess;
        t.disconnectStream();
        if (!c.eng.shareOwn(&t.img, sh)) return error.BadAlloc;
        return &t.img;
    }

    pub fn streamTexture(c: *Context) ?*Tex {
        const t = madeIn(Tex, &c.objs.tex, c.tex_ext[c.unit]) orelse return null;
        return if (t.target == g.TEXTURE_EXTERNAL_OES and !t.immutable) t else null;
    }

    /// glEGLImageTargetRenderbufferStorageOES.
    pub fn eglImageTargetRenderbufferStorage(c: *Context, target: u32, image: ?*anyopaque) void {
        if (target != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        const rb = madeIn(Rb, &c.objs.rbs, c.rb) orelse return c.fail(g.INVALID_OPERATION);
        const resolve = egl_image orelse return c.fail(g.INVALID_OPERATION);
        const src = resolve(image) orelse return c.fail(g.INVALID_VALUE);
        // (a renderbuffer is drawn into: no unorm16 plane)
        if (!src.format.renderable()) return c.fail(g.INVALID_OPERATION);
        c.eng.freeImage(&rb.img);
        rb.img = engine.alias(src);
        rb.internal = imageInternal(src.format);
        rb.samples = 0;
    }

    pub fn deleteTextures(c: *Context, names: []const u32) void {
        for (names) |name| {
            const t = madeIn(Tex, &c.objs.tex, name) orelse {
                if (slotIn(Tex, &c.objs.tex, name)) |s| s.named = false;
                continue;
            };
            for (&c.tex2d) |*b| {
                if (b.* == name) b.* = 0;
            }
            for (&c.tex_ext) |*b| {
                if (b.* == name) b.* = 0;
            }
            for (&c.layered) |*units| {
                for (units) |*b| {
                    if (b.* == name) b.* = 0;
                }
            }
            // (detached from the framebuffers bound here, as GL says)
            c.detachFromBound(.tex, name);
            t.disconnectStream();
            t.named = false;
            t.made = false;
            if (t.refs > 0) {
                t.orphan = true;
            } else c.dropTex(t);
        }
    }

    fn dropTex(c: *Context, t: *Tex) void {
        c.dropExtraLevels(t);
        c.eng.freeImage(&t.img);
        t.* = .{};
    }

    fn extraLevel(c: *Context, t: *Tex, level: u32) ?*ExtraLevel {
        return c.extraAt(t.extra_levels[level]);
    }

    fn extraAt(c: *Context, index: u16) ?*ExtraLevel {
        return if (index != 0) &c.objs.extra_levels[index - 1] else null;
    }

    fn cubeFace(c: *Context, t: *Tex, level: u32, face: u32) ?*ExtraLevel {
        return c.extraAt(t.cube_faces[face][level]);
    }

    fn dropExtraLevel(c: *Context, t: *Tex, level: u32) void {
        const mip = c.extraLevel(t, level) orelse return;
        c.eng.freeImage(&mip.img);
        mip.* = .{};
        t.extra_levels[level] = 0;
    }

    fn dropExtraLevels(c: *Context, t: *Tex) void {
        for (0..engine.MAX_LEVELS) |level| c.dropExtraLevel(t, @intCast(level));
        for (&t.cube_faces) |*face| {
            for (face) |*index| {
                const mip = c.extraAt(index.*) orelse continue;
                c.eng.freeImage(&mip.img);
                mip.* = .{};
                index.* = 0;
            }
        }
    }

    fn putExtraLevel(c: *Context, t: *Tex, level: u32, image: Image, internal: u32, layers: u32, srgb: bool) ?*ExtraLevel {
        const slot = c.putExtra(&t.extra_levels[level], image, internal, layers, srgb) orelse return null;
        t.defined &= ~(@as(u16, 1) << @intCast(level));
        return slot;
    }

    fn putExtra(c: *Context, index: *u16, image: Image, internal: u32, layers: u32, srgb: bool) ?*ExtraLevel {
        const slot = c.extraAt(index.*) orelse blk: {
            for (&c.objs.extra_levels, 0..) |*candidate, i| {
                if (candidate.used) continue;
                index.* = @intCast(i + 1);
                break :blk candidate;
            }
            return null;
        };
        c.eng.freeImage(&slot.img);
        slot.* = .{ .used = true, .img = image, .internal = internal, .layers = layers, .srgb = srgb };
        return slot;
    }

    const TextureLevel = struct { img: *Image, share: *engine.Shared, level: u32, internal: u32, layers: u32, srgb: bool };

    fn levelOfExtra(mip: *ExtraLevel) TextureLevel {
        return .{ .img = &mip.img, .share = &mip.share, .level = 0, .internal = mip.internal, .layers = mip.layers, .srgb = mip.srgb };
    }

    fn textureLevel(c: *Context, t: *Tex, level: u32) ?TextureLevel {
        if (c.extraLevel(t, level)) |mip| {
            return levelOfExtra(mip);
        }
        if (level >= t.img.levels or t.defined & (@as(u16, 1) << @intCast(level)) == 0) return null;
        return .{ .img = &t.img, .share = &t.slice_share, .level = level, .internal = t.internal, .layers = layerCount(t.target, t.layers, level), .srgb = t.srgb };
    }

    fn allocateExtraLevel(c: *Context, t: *Tex, level: u32, internal: u32, w: i32, h: i32, depth: i32, up: texfmt.Upload) ?*ExtraLevel {
        var img: Image = .{};
        if (w != 0 and h != 0 and depth != 0) {
            img = c.newLayerImage(t.target, 1, w, h, depth, up.store) orelse {
                c.fail(g.OUT_OF_MEMORY);
                return null;
            };
        }
        const mip = c.putExtraLevel(t, level, img, internal, @intCast(depth), up.srgb) orelse {
            c.eng.freeImage(&img);
            c.fail(g.OUT_OF_MEMORY);
            return null;
        };
        mip.swizzle = up.swizzle;
        return mip;
    }

    /// Move independently defined mip levels out of a base allocation
    /// before its layout changes. Each migrated level remains usable
    /// even if a later allocation fails.
    fn preservePackedLevels(c: *Context, t: *Tex) bool {
        for (1..t.img.levels) |at| {
            const level: u32 = @intCast(at);
            if (t.defined & (@as(u16, 1) << @intCast(level)) == 0) continue;
            const layers = layerCount(t.target, t.layers, level);
            var image = c.newLayerImage(t.target, 1, @intCast(t.img.levelWidth(level)), @intCast(t.img.levelHeight(level)), @intCast(layers), t.img.format) orelse {
                c.fail(g.OUT_OF_MEMORY);
                return false;
            };
            const bytes = @as(usize, image.stride) * image.height * layers;
            const source = c.eng.hostView(&t.img, t.img.level_at[level], bytes);
            @memcpy(c.eng.hostView(&image, 0, bytes), source);
            c.eng.wrote(&image, 0, bytes);
            const mip = c.putExtraLevel(t, level, image, t.internal, layers, t.srgb) orelse {
                c.eng.freeImage(&image);
                c.fail(g.OUT_OF_MEMORY);
                return false;
            };
            mip.swizzle = t.fswz;
        }
        return true;
    }

    fn joinLevel(c: *Context, t: *Tex, level: u32) bool {
        const extra = c.extraLevel(t, level) orelse return t.defined & (@as(u16, 1) << @intCast(level)) != 0;
        if (t.img.share != null and t.img.share != &t.slice_share) return false;
        if (!extra.img.live() or extra.internal != t.internal or extra.img.format != t.img.format or
            extra.img.width != t.img.levelWidth(level) or extra.img.height != t.img.levelHeight(level) or
            extra.layers != layerCount(t.target, t.layers, level) or !std.mem.eql(u3, &extra.swizzle, &t.fswz)) return false;
        if (level >= t.img.levels) {
            var img = c.newLayerImage(t.target, @intCast(level + 1), @intCast(t.img.width), @intCast(t.img.height), @intCast(t.layers), t.img.format) orelse return false;
            const prefix = img.level_at[t.img.levels];
            @memcpy(c.eng.hostView(&img, 0, prefix), c.eng.hostView(&t.img, 0, prefix));
            c.eng.wrote(&img, 0, prefix);
            c.eng.freeImage(&t.img);
            t.img = img;
            t.levels = level + 1;
        }
        const bytes = @as(usize, extra.img.stride) * extra.img.height * extra.layers;
        const offset = t.img.level_at[level];
        @memcpy(c.eng.hostView(&t.img, offset, bytes), c.eng.hostView(&extra.img, 0, bytes));
        c.eng.wrote(&t.img, offset, bytes);
        c.dropExtraLevel(t, level);
        t.defined |= @as(u16, 1) << @intCast(level);
        return true;
    }

    fn joinCompatibleLevels(c: *Context, t: *Tex) void {
        if (!t.img.live()) return;
        const side = @max(t.img.width, t.img.height, if (t.target == g.TEXTURE_3D) t.layers else 1);
        const levels = std.math.log2_int(u32, side) + 1;
        for (1..levels) |at| {
            const level: u32 = @intCast(at);
            if (t.extra_levels[level] != 0) _ = c.joinLevel(t, level);
        }
    }

    /// The texture's level 0 becomes w x h of `fmt` (none for 0 x 0); its
    /// other levels stay if its size and format do.
    fn defineTex(c: *Context, t: *Tex, w: u32, h: u32, fmt: Format, internal: u32) bool {
        if (t.img.live() and t.img.width == w and t.img.height == h and t.img.format == fmt and t.internal == internal) {
            t.internal = internal;
            t.defined |= 1;
            return true;
        }
        var img: Image = .{};
        if (w != 0 and h != 0) {
            img = c.eng.newImage(w, h, fmt) orelse {
                c.fail(g.OUT_OF_MEMORY);
                return false;
            };
        }
        if (!c.preservePackedLevels(t)) {
            c.eng.freeImage(&img);
            return false;
        }
        c.eng.freeImage(&t.img);
        t.internal = internal;
        t.levels = 1;
        t.defined = 0;
        t.img = img;
        if (img.live()) t.defined = 1;
        return true;
    }

    /// Levels a full chain from level 0 has: log2 of the larger side, + 1.
    fn fullLevels(img: *const Image) u32 {
        return std.math.log2_int(u32, @max(img.width, img.height)) + 1;
    }

    /// The texture's image holds `n` levels at least: a chain made, its
    /// levels so far copied in (an EGLImage's memory cannot grow one).
    fn growChain(c: *Context, t: *Tex, n: u32) bool {
        if (t.img.levels >= n) return true;
        if ((t.img.share != null and t.img.share != &t.slice_share) or t.img.top_down) {
            c.fail(g.INVALID_OPERATION);
            return false;
        }
        var img = c.eng.newImageChain(t.img.width, t.img.height, t.img.format, n) orelse {
            c.fail(g.OUT_OF_MEMORY);
            return false;
        };
        for (0..t.img.levels) |l| {
            const lv: u32 = @intCast(l);
            const len = @as(usize, t.img.levelStride(lv)) * t.img.levelHeight(lv);
            const from = c.eng.hostView(&t.img, t.img.level_at[l], len);
            @memcpy(c.eng.hostView(&img, img.level_at[l], len), from);
            c.eng.wrote(&img, img.level_at[l], len);
        }
        c.eng.freeImage(&t.img);
        t.img = img;
        return true;
    }

    /// The pixels a texture upload reads: client memory, or the unpack
    /// buffer's at the offset `pixels` gives. Null with nothing to read
    /// (no pointer), or after an error.
    fn unpackSource(c: *Context, pixels: ?*const anyopaque, w: u32, h: u32, bpp: u32) ?struct { bytes: []const u8, row: usize } {
        const l = c.unpack.layout(w, bpp);
        const span = spanOf(l.first, l.row, w, h, bpp);
        if (span == 0) return null;
        if (c.bufs.unpack != 0) {
            const b = madeIn(Buf, &c.objs.bufs, c.bufs.unpack) orelse {
                c.fail(g.INVALID_OPERATION);
                return null;
            };
            if (!c.notMapped(b)) return null;
            const off = addr(pixels);
            if (off > b.size or span > b.size - off) {
                c.fail(g.INVALID_OPERATION);
                return null;
            }
            const all = c.eng.hostView(&b.store, off, span);
            return .{ .bytes = all[l.first..], .row = l.row };
        }
        const p = pixels orelse return null;
        return .{ .bytes = @as([*]const u8, @ptrCast(p))[l.first..span], .row = l.row };
    }

    /// Rows of client texels into level `level` of img at (x, y), converted
    /// as `up` says.
    fn uploadRows(c: *Context, img: *Image, level: u32, up: texfmt.Upload, x: u32, y: u32, w: u32, h: u32, src: []const u8, row: usize) void {
        c.uploadLayer(img, level, 0, up, x, y, w, h, src, row);
    }

    fn uploadLayer(c: *Context, img: *Image, level: u32, layer: u32, up: texfmt.Upload, x: u32, y: u32, w: u32, h: u32, src: []const u8, row: usize) void {
        const bpp: usize = img.format.bytes();
        c.usage.upload(@as(usize, w) * h * bpp);
        for (0..h) |j| {
            const gy = y + @as(u32, @intCast(j));
            const mrow = if (level == 0) img.rowOf(gy) else gy;
            const off = img.level_at[level] + (@as(usize, layer) * img.levelHeight(level) + mrow) * img.levelStride(level) + @as(usize, x) * bpp;
            const len = @as(usize, w) * bpp;
            const dst = c.eng.hostView(img, off, len);
            texfmt.convert(up, src[j * row ..], dst, w);
            c.eng.wrote(img, off, len);
        }
    }

    /// Matching mips share the base allocation. Other levels retain their
    /// own size and format until a compatible base is defined.
    pub fn texImage2D(c: *Context, target: u32, level: i32, internal: i32, w: i32, h: i32, border: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        const cube = target >= g.TEXTURE_CUBE_MAP_POSITIVE_X and target <= g.TEXTURE_CUBE_MAP_NEGATIVE_Z;
        const t = (if (cube) c.boundLayered(g.TEXTURE_CUBE_MAP) else c.boundTex2D(target)) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or w < 0 or h < 0 or w > MAX_SIZE or h > MAX_SIZE or border != 0) return c.fail(g.INVALID_VALUE);
        if (cube and (w != h or w > @as(i32, MAX_SIZE) >> @as(u5, @intCast(level)))) return c.fail(g.INVALID_VALUE);
        const ifmt: u32 = @bitCast(internal);
        const up = switch (texfmt.upload(ifmt, format, ty)) {
            .ok => |x| x,
            .err => |e| return c.fail(e),
        };
        if (t.immutable) return c.fail(g.INVALID_OPERATION);
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const l: u32 = @intCast(level);
        if (cube) {
            const index = &t.cube_faces[target - g.TEXTURE_CUBE_MAP_POSITIVE_X][l];
            var image: Image = .{};
            if (uw != 0) image = c.eng.newImage(uw, uh, up.store) orelse return c.fail(g.OUT_OF_MEMORY);
            const mip = c.putExtra(index, image, ifmt, 1, up.srgb) orelse {
                c.eng.freeImage(&image);
                return c.fail(g.OUT_OF_MEMORY);
            };
            mip.swizzle = up.swizzle;
            const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
            c.uploadRows(&mip.img, 0, up, 0, 0, uw, uh, src.bytes, src.row);
            return;
        }
        if (l > 0) {
            const bit = @as(u16, 1) << @intCast(l);
            const fits = t.img.live() and ifmt == t.internal and up.store == t.img.format and l < fullLevels(&t.img) and uw == t.img.levelWidth(l) and uh == t.img.levelHeight(l);
            if (!fits or (t.img.share != null and t.img.share != &t.slice_share)) {
                const mip = c.allocateExtraLevel(t, l, ifmt, w, h, 1, up) orelse return;
                const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
                c.uploadRows(&mip.img, 0, up, 0, 0, uw, uh, src.bytes, src.row);
                return;
            }
            if (!c.growChain(t, fullLevels(&t.img))) return;
            c.dropExtraLevel(t, l);
            t.defined |= bit;
            const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
            c.uploadRows(&t.img, l, up, 0, 0, uw, uh, src.bytes, src.row);
            return;
        }
        if (!c.defineTex(t, uw, uh, up.store, ifmt)) return;
        t.fswz = up.swizzle;
        t.srgb = up.srgb;
        c.joinCompatibleLevels(t);
        const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
        c.uploadRows(&t.img, 0, up, 0, 0, uw, uh, src.bytes, src.row);
    }

    pub fn texSubImage2D(c: *Context, target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        if (target >= g.TEXTURE_CUBE_MAP_POSITIVE_X and target <= g.TEXTURE_CUBE_MAP_NEGATIVE_Z) {
            const tex = c.boundLayered(g.TEXTURE_CUBE_MAP) orelse return;
            const face = target - g.TEXTURE_CUBE_MAP_POSITIVE_X;
            if (tex.immutable) return c.subLayers(tex, level, x, y, @intCast(face), w, h, 1, format, ty, pixels, false);
            if (level < 0 or level >= engine.MAX_LEVELS or x < 0 or y < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
            const mip = c.cubeFace(tex, @intCast(level), face) orelse return c.fail(g.INVALID_OPERATION);
            return c.subLayerImage(levelOfExtra(mip), x, y, 0, w, h, 1, format, ty, pixels, false);
        }
        const t = c.boundTex2D(target) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or x < 0 or y < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        const l: u32 = @intCast(level);
        const mip = c.textureLevel(t, l) orelse return c.fail(g.INVALID_OPERATION);
        if (!mip.img.live() or @as(i64, x) + w > mip.img.levelWidth(mip.level) or @as(i64, y) + h > mip.img.levelHeight(mip.level)) return c.fail(g.INVALID_VALUE);
        const up = texfmt.subUpload(mip.img.format, format, ty) orelse return c.fail(if (texfmt.known(format, ty)) g.INVALID_OPERATION else g.INVALID_ENUM);
        if (w == 0 or h == 0) return;
        const src = c.unpackSource(pixels, @intCast(w), @intCast(h), up.client_bytes) orelse return;
        c.uploadRows(mip.img, mip.level, up, @intCast(x), @intCast(y), @intCast(w), @intCast(h), src.bytes, src.row);
    }

    pub fn texStorage2D(c: *Context, target: u32, levels: i32, internal: u32, w: i32, h: i32) void {
        if (target == g.TEXTURE_CUBE_MAP) {
            if (w != h) return c.fail(g.INVALID_VALUE);
            return c.storageLayers(target, levels, internal, w, h, 6);
        }
        const t = c.boundTex2D(target) orelse return;
        if (levels < 1 or w < 1 or h < 1 or w > MAX_SIZE or h > MAX_SIZE) return c.fail(g.INVALID_VALUE);
        const up = texfmt.storage(internal) orelse return c.fail(g.INVALID_ENUM);
        const most = std.math.log2_int(u32, @intCast(@max(w, h))) + 1;
        if (levels > most) return c.fail(g.INVALID_OPERATION);
        if (t.immutable or t == &c.default_tex) return c.fail(g.INVALID_OPERATION);
        const img = c.eng.newImageChain(@intCast(w), @intCast(h), up.store, @intCast(levels)) orelse return c.fail(g.OUT_OF_MEMORY);
        c.dropExtraLevels(t);
        c.eng.freeImage(&t.img);
        t.img = img;
        t.internal = internal;
        t.fswz = up.swizzle;
        t.srgb = up.srgb;
        t.levels = @intCast(levels);
        t.defined = @intCast((@as(u32, 1) << @intCast(levels)) - 1);
        t.immutable = true;
    }

    fn layerCount(target: u32, depth: u32, level: u32) u32 {
        return if (target == g.TEXTURE_3D) @max(depth >> @intCast(level), 1) else depth;
    }

    pub fn texStorage3D(c: *Context, target: u32, levels: i32, internal: u32, w: i32, h: i32, depth: i32) void {
        if (target != g.TEXTURE_3D and target != g.TEXTURE_2D_ARRAY) return c.fail(g.INVALID_ENUM);
        c.storageLayers(target, levels, internal, w, h, depth);
    }

    fn storageLayers(c: *Context, target: u32, levels: i32, internal: u32, w: i32, h: i32, depth: i32) void {
        const t = c.boundLayered(target) orelse return;
        if (levels < 1 or levels > engine.MAX_LEVELS or w < 1 or h < 1 or depth < 1 or
            w > MAX_SIZE or h > MAX_SIZE or depth > MAX_SIZE) return c.fail(g.INVALID_VALUE);
        const side = @max(w, h, if (target == g.TEXTURE_3D) depth else 1);
        if (t.immutable or levels > std.math.log2_int(u32, @intCast(side)) + 1) return c.fail(g.INVALID_OPERATION);
        const up = texfmt.storage(internal) orelse return c.fail(g.INVALID_ENUM);
        const img = c.newLayerImage(target, levels, w, h, depth, up.store) orelse return c.fail(g.OUT_OF_MEMORY);
        c.dropExtraLevels(t);
        c.eng.freeImage(&t.img);
        t.img = img;
        t.internal = internal;
        t.levels = @intCast(levels);
        t.layers = @intCast(depth);
        t.defined = @intCast((@as(u32, 1) << @intCast(levels)) - 1);
        t.fswz = up.swizzle;
        t.srgb = up.srgb;
        t.immutable = true;
    }

    fn newLayerImage(c: *Context, target: u32, levels: i32, w: i32, h: i32, depth: i32, format: Format) ?Image {
        const layers: u32 = @intCast(depth);
        var layout = Image{
            .width = @intCast(w),
            .height = @intCast(h),
            .format = format,
            .levels = @intCast(levels),
            .stride = std.mem.alignForward(u32, @as(u32, @intCast(w)) * format.bytes(), 4),
        };
        var bytes: usize = 0;
        for (0..@intCast(levels)) |at| {
            const level: u32 = @intCast(at);
            layout.level_at[at] = std.math.cast(u32, bytes) orelse return null;
            bytes += @as(usize, layout.levelStride(level)) * layout.levelHeight(level) * layerCount(target, layers, level);
        }
        if (bytes > std.math.maxInt(u32)) return null;
        var img = c.eng.newBuffer(bytes) orelse return null;
        img.width = layout.width;
        img.height = layout.height;
        img.stride = layout.stride;
        img.format = layout.format;
        img.levels = layout.levels;
        img.level_at = layout.level_at;
        return img;
    }

    pub fn texSubImage3D(c: *Context, target: u32, level: i32, x: i32, y: i32, z: i32, w: i32, h: i32, depth: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        if (target != g.TEXTURE_3D and target != g.TEXTURE_2D_ARRAY) return c.fail(g.INVALID_ENUM);
        const t = c.boundLayered(target) orelse return;
        c.subLayers(t, level, x, y, z, w, h, depth, format, ty, pixels, true);
    }

    pub fn texImage3D(c: *Context, target: u32, level: i32, internal: i32, w: i32, h: i32, depth: i32, border: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        if (target != g.TEXTURE_3D and target != g.TEXTURE_2D_ARRAY) return c.fail(g.INVALID_ENUM);
        const t = c.boundLayered(target) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or w < 0 or h < 0 or depth < 0 or
            w > MAX_SIZE or h > MAX_SIZE or depth > MAX_SIZE or border != 0) return c.fail(g.INVALID_VALUE);
        if (t.immutable) return c.fail(g.INVALID_OPERATION);
        const ifmt: u32 = @bitCast(internal);
        const up = switch (texfmt.upload(ifmt, format, ty)) {
            .ok => |value| value,
            .err => |err| return c.fail(err),
        };
        const lv: u32 = @intCast(level);
        const bit = @as(u16, 1) << @intCast(lv);
        if (lv == 0) {
            if (w == 0 or h == 0 or depth == 0) {
                if (!c.preservePackedLevels(t)) return;
                c.eng.freeImage(&t.img);
                t.defined = 0;
                t.levels = 0;
                return;
            }
            if (!t.img.live() or t.img.width != w or t.img.height != h or t.layers != depth or t.internal != ifmt or t.img.format != up.store) {
                var img = c.newLayerImage(target, 1, w, h, depth, up.store) orelse return c.fail(g.OUT_OF_MEMORY);
                if (!c.preservePackedLevels(t)) {
                    c.eng.freeImage(&img);
                    return;
                }
                c.eng.freeImage(&t.img);
                t.img = img;
                t.levels = 1;
                t.layers = @intCast(depth);
                t.defined = 0;
            }
            t.internal = ifmt;
            t.fswz = up.swizzle;
            t.srgb = up.srgb;
        } else {
            const side = @max(t.img.width, t.img.height, if (target == g.TEXTURE_3D) t.layers else 1);
            if (!t.img.live() or lv > std.math.log2_int(u32, side) or t.internal != ifmt or t.img.levelWidth(lv) != w or
                t.img.levelHeight(lv) != h or layerCount(target, t.layers, lv) != depth)
            {
                const mip = c.allocateExtraLevel(t, lv, ifmt, w, h, depth, up) orelse return;
                c.uploadLayers(&mip.img, 0, 0, 0, 0, w, h, depth, up, pixels, true);
                return;
            }
            if (lv >= t.levels) {
                var img = c.newLayerImage(target, @intCast(lv + 1), @intCast(t.img.width), @intCast(t.img.height), @intCast(t.layers), t.img.format) orelse return c.fail(g.OUT_OF_MEMORY);
                const prefix = img.level_at[t.levels];
                @memcpy(c.eng.hostView(&img, 0, prefix), c.eng.hostView(&t.img, 0, prefix));
                c.eng.wrote(&img, 0, prefix);
                c.eng.freeImage(&t.img);
                t.img = img;
                t.levels = lv + 1;
            }
        }
        c.dropExtraLevel(t, lv);
        t.defined |= bit;
        if (lv == 0) c.joinCompatibleLevels(t);
        c.uploadLayers(&t.img, lv, 0, 0, 0, w, h, depth, up, pixels, true);
    }

    fn subLayers(c: *Context, t: *Tex, level: i32, x: i32, y: i32, z: i32, w: i32, h: i32, depth: i32, format: u32, ty: u32, pixels: ?*const anyopaque, volume: bool) void {
        if (level < 0 or x < 0 or y < 0 or z < 0 or w < 0 or h < 0 or depth < 0) return c.fail(g.INVALID_VALUE);
        if (level >= engine.MAX_LEVELS) return c.fail(g.INVALID_VALUE);
        const lv: u32 = @intCast(level);
        const mip = c.textureLevel(t, lv) orelse return c.fail(g.INVALID_OPERATION);
        c.subLayerImage(mip, x, y, z, w, h, depth, format, ty, pixels, volume);
    }

    fn subLayerImage(c: *Context, mip: TextureLevel, x: i32, y: i32, z: i32, w: i32, h: i32, depth: i32, format: u32, ty: u32, pixels: ?*const anyopaque, volume: bool) void {
        if (!mip.img.live() or @as(i64, x) + w > mip.img.levelWidth(mip.level) or @as(i64, y) + h > mip.img.levelHeight(mip.level) or
            @as(i64, z) + depth > mip.layers) return c.fail(g.INVALID_VALUE);
        const up = texfmt.subUpload(mip.img.format, format, ty) orelse return c.fail(if (texfmt.known(format, ty)) g.INVALID_OPERATION else g.INVALID_ENUM);
        c.uploadLayers(mip.img, mip.level, x, y, z, w, h, depth, up, pixels, volume);
    }

    fn uploadLayers(c: *Context, img: *Image, lv: u32, x: i32, y: i32, z: i32, w: i32, h: i32, depth: i32, up: texfmt.Upload, pixels: ?*const anyopaque, volume: bool) void {
        if (w == 0 or h == 0 or depth == 0) return;
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const row_pixels: usize = if (c.unpack.row_length > 0) @intCast(c.unpack.row_length) else uw;
        const row = std.mem.alignForward(usize, row_pixels * up.client_bytes, @intCast(c.unpack.alignment));
        const skipped_rows = std.math.mul(usize, @intCast(c.unpack.skip_rows), row) catch return c.fail(g.INVALID_VALUE);
        const first = std.math.add(usize, skipped_rows, @as(usize, @intCast(c.unpack.skip_pixels)) * up.client_bytes) catch return c.fail(g.INVALID_VALUE);
        const image_rows: usize = @intCast(if (volume and c.unpack.image_height > 0) c.unpack.image_height else h);
        const pitch = std.math.mul(usize, row, image_rows) catch return c.fail(g.INVALID_VALUE);
        const skip: usize = @intCast(if (volume) c.unpack.skip_images else 0);
        const start = std.math.mul(usize, pitch, skip) catch return c.fail(g.INVALID_VALUE);
        const end = std.math.mul(usize, pitch, skip + @as(usize, @intCast(depth - 1))) catch return c.fail(g.INVALID_VALUE);
        const last_slice = std.math.add(usize, first, spanOf(0, row, uw, uh, up.client_bytes)) catch return c.fail(g.INVALID_VALUE);
        const span = std.math.add(usize, end, last_slice) catch return c.fail(g.INVALID_VALUE);
        if (span > std.math.maxInt(isize)) return c.fail(g.INVALID_VALUE);
        const data = if (c.bufs.unpack != 0) blk: {
            const b = madeIn(Buf, &c.objs.bufs, c.bufs.unpack) orelse return c.fail(g.INVALID_OPERATION);
            if (!c.notMapped(b)) return;
            const off = addr(pixels);
            if (off > b.size or span > b.size - off) return c.fail(g.INVALID_OPERATION);
            break :blk c.eng.hostView(&b.store, off, span);
        } else blk: {
            const p = pixels orelse return;
            break :blk @as([*]const u8, @ptrCast(p))[0..span];
        };
        for (0..@intCast(depth)) |i| {
            c.uploadLayer(img, lv, @intCast(@as(usize, @intCast(z)) + i), up, @intCast(x), @intCast(y), uw, uh, data[start + i * pitch + first ..], row);
        }
    }

    /// glGenerateMipmap: the levels past the base, to the last a complete
    /// texture has (MAX_LEVEL, or the immutable texture's), made from the
    /// base (2 x 2 texels averaged per layer, or 2 x 2 x 2 for a volume). Unorm
    /// textures of 1, 2 or 4 bytes a texel (what ES 3.0 lets filter and
    /// render); others INVALID_OPERATION.
    pub fn generateMipmap(c: *Context, target: u32) void {
        if (target != g.TEXTURE_2D and target != g.TEXTURE_2D_ARRAY and target != g.TEXTURE_3D and target != g.TEXTURE_CUBE_MAP)
            return c.fail(g.INVALID_ENUM);
        const t = c.boundTex(target) orelse return;
        var base: u32 = @intCast(@max(t.params.base_level, 0));
        if (t.immutable) base = @min(base, t.levels - 1);
        if (base >= engine.MAX_LEVELS) return c.fail(g.INVALID_OPERATION);
        if (target != g.TEXTURE_2D or c.extraLevel(t, base) != null) {
            return c.generateLayerMips(t, base);
        }
        if (!t.img.live()) return c.fail(g.INVALID_OPERATION);
        if (base >= engine.MAX_LEVELS or t.defined & (@as(u16, 1) << @intCast(base)) == 0) return c.fail(g.INVALID_OPERATION);
        if (!t.img.format.renderable()) return c.fail(g.INVALID_OPERATION);
        const full = fullLevels(&t.img);
        var last: u32 = @min(full - 1, @as(u32, @intCast(@max(t.params.max_level, 0))));
        if (t.immutable) last = @min(last, t.levels - 1);
        if (last <= base) return;
        if (!t.immutable and !c.growChain(t, full)) return;
        if (!c.eng.mipmap(&t.img, base, last)) return c.fail(g.OUT_OF_MEMORY);
        var l = base;
        while (l <= last) : (l += 1) {
            c.dropExtraLevel(t, l);
            t.defined |= @as(u16, 1) << @intCast(l);
        }
    }

    fn generateLayerMips(c: *Context, t: *Tex, base: u32) void {
        const mutable_cube = t.target == g.TEXTURE_CUBE_MAP and !t.immutable;
        const first_face = if (mutable_cube) c.cubeFace(t, base, 0) else null;
        const first = (if (first_face) |face| levelOfExtra(face) else c.textureLevel(t, base)) orelse return c.fail(g.INVALID_OPERATION);
        if (!first.img.live() or !first.img.format.renderable()) return c.fail(g.INVALID_OPERATION);
        const w = first.img.levelWidth(first.level);
        const h = first.img.levelHeight(first.level);
        const volume = t.target == g.TEXTURE_3D;
        const layers = if (mutable_cube) 6 else first.layers;
        const depth = if (volume) layers else 1;
        var last = @min(engine.MAX_LEVELS - 1, base + std.math.log2_int(u32, @max(w, h, depth)));
        last = @min(last, @as(u32, @intCast(@max(t.params.max_level, 0))));
        if (t.immutable) last = @min(last, t.levels - 1);
        if (last <= base) {
            if (mutable_cube and !c.cubeLevelComplete(t, base, w, first_face.?)) c.fail(g.INVALID_OPERATION);
            return;
        }
        if (t.immutable) {
            if (!c.eng.mipmapLayers(&t.img, base, last, layers, volume)) c.fail(g.OUT_OF_MEMORY);
            return;
        }
        var cube_base: Image = .{};
        defer c.eng.freeImage(&cube_base);
        if (mutable_cube and !c.gatherCube(t, base, base, first_face.?, &cube_base)) {
            return c.fail(g.INVALID_OPERATION);
        }
        const src = if (mutable_cube) &cube_base else first.img;
        const src_level = if (mutable_cube) 0 else first.level;
        var chain = c.newLayerImage(t.target, @intCast(last - base + 1), @intCast(w), @intCast(h), @intCast(layers), src.format) orelse return c.fail(g.OUT_OF_MEMORY);
        defer c.eng.freeImage(&chain);
        const bytes = @as(usize, chain.stride) * h * layers;
        const src_stride = src.levelStride(src_level);
        const rows = @as(usize, h) * layers;
        const row_bytes = @as(usize, w) * src.format.bytes();
        const src_data = c.eng.hostView(src, src.level_at[src_level], (rows - 1) * src_stride + row_bytes);
        const dst = c.eng.hostView(&chain, 0, bytes);
        for (0..rows) |row| @memcpy(dst[row * chain.stride ..][0..row_bytes], src_data[row * src_stride ..][0..row_bytes]);
        c.eng.wrote(&chain, 0, bytes);
        if (!c.eng.mipmapLayers(&chain, 0, last - base, layers, volume)) return c.fail(g.OUT_OF_MEMORY);
        const format_level = if (first_face != null) first_face else c.extraLevel(t, base);
        const swizzle = if (format_level) |mip| mip.swizzle else t.fswz;
        for (base + 1..last + 1) |at| {
            const lv: u32 = @intCast(at);
            const rel = lv - base;
            const slices: usize = if (mutable_cube) 6 else 1;
            const per_image = if (mutable_cube) 1 else layerCount(t.target, layers, rel);
            const copy_bytes = @as(usize, chain.levelStride(rel)) * chain.levelHeight(rel) * per_image;
            for (0..slices) |face| {
                var img = c.newLayerImage(t.target, 1, @intCast(chain.levelWidth(rel)), @intCast(chain.levelHeight(rel)), @intCast(per_image), chain.format) orelse return c.fail(g.OUT_OF_MEMORY);
                const off = chain.level_at[rel] + face * copy_bytes;
                @memcpy(c.eng.hostView(&img, 0, copy_bytes), c.eng.hostView(&chain, off, copy_bytes));
                c.eng.wrote(&img, 0, copy_bytes);
                const mip = (if (mutable_cube)
                    c.putExtra(&t.cube_faces[face][lv], img, first.internal, 1, first.srgb)
                else
                    c.putExtraLevel(t, lv, img, first.internal, per_image, first.srgb)) orelse {
                    c.eng.freeImage(&img);
                    return c.fail(g.OUT_OF_MEMORY);
                };
                mip.swizzle = swizzle;
            }
        }
        if (base == 0 and !mutable_cube) c.joinCompatibleLevels(t);
    }

    pub fn texParameteri(c: *Context, target: u32, pname: u32, param: i32) void {
        const t = c.boundTex(target) orelse return;
        const e = setParam(&t.params, t.target == g.TEXTURE_EXTERNAL_OES, false, pname, param);
        if (e != g.NO_ERROR) c.fail(e);
    }

    pub fn getTexParameteri(c: *Context, target: u32, pname: u32) ?i32 {
        const t = c.boundTex(target) orelse return null;
        switch (pname) {
            g.TEXTURE_IMMUTABLE_FORMAT => return @intFromBool(t.immutable),
            g.TEXTURE_IMMUTABLE_LEVELS => return @intCast(if (t.immutable) t.levels else 0),
            else => {},
        }
        return getParam(&t.params, false, pname) orelse {
            c.fail(g.INVALID_ENUM);
            return null;
        };
    }

    // ── Sampler objects ────────────────────────────────────────────────────

    pub fn genSamplers(c: *Context, out: []u32) void {
        if (!genIn(Smp, &c.objs.samplers, out)) return c.fail(g.OUT_OF_MEMORY);
        // (a sampler's name is one at once, as GL says)
        for (out) |name| _ = makeIn(Smp, &c.objs.samplers, name);
    }

    pub fn deleteSamplers(c: *Context, names: []const u32) void {
        for (names) |name| {
            const s = slotIn(Smp, &c.objs.samplers, name) orelse continue;
            for (&c.smp) |*b| {
                if (b.* == name) b.* = 0;
            }
            s.* = .{};
        }
    }

    pub fn isSampler(c: *Context, name: u32) bool {
        return madeIn(Smp, &c.objs.samplers, name) != null;
    }

    pub fn bindSampler(c: *Context, unit: u32, name: u32) void {
        if (unit >= MAX_UNITS) return c.fail(g.INVALID_VALUE);
        if (name != 0 and madeIn(Smp, &c.objs.samplers, name) == null) return c.fail(g.INVALID_OPERATION);
        c.smp[unit] = name;
    }

    pub fn samplerParameteri(c: *Context, name: u32, pname: u32, param: i32) void {
        const s = madeIn(Smp, &c.objs.samplers, name) orelse return c.fail(g.INVALID_OPERATION);
        const e = setParam(&s.params, false, true, pname, param);
        if (e != g.NO_ERROR) c.fail(e);
    }

    pub fn getSamplerParameteri(c: *Context, name: u32, pname: u32) ?i32 {
        const s = madeIn(Smp, &c.objs.samplers, name) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
        return getParam(&s.params, true, pname) orelse {
            c.fail(g.INVALID_ENUM);
            return null;
        };
    }

    /// What texture slot `sl` of a draw reads: its unit's texture (bound
    /// to the slot's target) with the unit's sampler object's state, or
    /// the texture's.
    /// Gather a complete mip range into one binding for the draw. Keep
    /// independently defined levels authoritative for uploads and FBOs.
    fn gatherMips(c: *Context, t: *Tex, base: u32, last: u32, first: TextureLevel, scratch: *Image) bool {
        const w = first.img.levelWidth(first.level);
        const h = first.img.levelHeight(first.level);
        if (first.img.top_down) return false;
        for (base..last + 1) |at| {
            const mip = c.textureLevel(t, @intCast(at)) orelse return false;
            const rel: u32 = @intCast(at - base);
            if (!mip.img.live() or mip.img.top_down or mip.img.format != first.img.format or mip.internal != first.internal or
                mip.srgb != first.srgb or mip.img.no_alpha != first.img.no_alpha or
                mip.img.levelWidth(mip.level) != @max(w >> @intCast(rel), 1) or
                mip.img.levelHeight(mip.level) != @max(h >> @intCast(rel), 1) or mip.layers != layerCount(t.target, first.layers, rel)) return false;
        }
        scratch.* = c.newLayerImage(t.target, @intCast(last - base + 1), @intCast(w), @intCast(h), @intCast(first.layers), first.img.format) orelse {
            c.fail(g.OUT_OF_MEMORY);
            return false;
        };
        scratch.no_alpha = first.img.no_alpha;
        for (base..last + 1) |at| {
            const mip = c.textureLevel(t, @intCast(at)).?;
            const rel: u32 = @intCast(at - base);
            const stride = scratch.levelStride(rel);
            const row_bytes = scratch.levelWidth(rel) * scratch.format.bytes();
            const src_stride = mip.img.levelStride(mip.level);
            const rows = @as(usize, scratch.levelHeight(rel)) * mip.layers;
            const src = c.eng.hostView(mip.img, mip.img.level_at[mip.level], rows * src_stride);
            const dst = c.eng.hostView(scratch, scratch.level_at[rel], rows * stride);
            for (0..rows) |row| @memcpy(dst[row * stride ..][0..row_bytes], src[row * src_stride ..][0..row_bytes]);
            c.eng.wrote(scratch, scratch.level_at[rel], rows * stride);
        }
        return true;
    }

    fn cubeLevelComplete(c: *Context, t: *Tex, level: u32, size: u32, first: *ExtraLevel) bool {
        for (0..6) |face| {
            const mip = c.cubeFace(t, level, @intCast(face)) orelse return false;
            if (!mip.img.live() or mip.img.width != size or mip.img.height != size or mip.internal != first.internal or
                mip.img.format != first.img.format or mip.srgb != first.srgb or !std.mem.eql(u3, &mip.swizzle, &first.swizzle)) return false;
        }
        return true;
    }

    fn gatherCube(c: *Context, t: *Tex, base: u32, last: u32, first: *ExtraLevel, scratch: *Image) bool {
        const width = first.img.width;
        for (base..last + 1) |level| {
            const size = @max(width >> @intCast(level - base), 1);
            if (!c.cubeLevelComplete(t, @intCast(level), size, first)) return false;
        }
        scratch.* = c.newLayerImage(g.TEXTURE_CUBE_MAP, @intCast(last - base + 1), @intCast(width), @intCast(width), 6, first.img.format) orelse {
            c.fail(g.OUT_OF_MEMORY);
            return false;
        };
        for (base..last + 1) |level| {
            const rel: u32 = @intCast(level - base);
            const bytes = @as(usize, scratch.levelStride(rel)) * scratch.levelHeight(rel);
            for (0..6) |face| {
                const mip = c.cubeFace(t, @intCast(level), @intCast(face)).?;
                const offset = scratch.level_at[rel] + face * bytes;
                @memcpy(c.eng.hostView(scratch, offset, bytes), c.eng.hostView(&mip.img, 0, bytes));
                c.eng.wrote(scratch, offset, bytes);
            }
        }
        return true;
    }

    fn slotState(c: *Context, sl: program.Slot, values: []const u32, scratch: *Image) texture.State {
        if (sl.unsupported) return .{};
        const unit = values[sl.word];
        if (unit >= MAX_UNITS) return .{};
        const name = if (sl.volume) c.layered[0][unit] else if (sl.array) c.layered[1][unit] else if (sl.cube) c.layered[2][unit] else if (sl.external) c.tex_ext[unit] else c.tex2d[unit];
        if ((sl.array or sl.volume or sl.cube) and name == 0) return .{};
        const t: *Tex = if (name == 0) (if (sl.external) &c.default_ext else &c.default_tex) else (madeIn(Tex, &c.objs.tex, name) orelse return .{});
        const p: *const TexParams = if (c.smp[unit] != 0) (if (madeIn(Smp, &c.objs.samplers, c.smp[unit])) |s| &s.params else &t.params) else &t.params;
        // the levels read, and completeness (GL ES 3.0 3.8.13): the base
        // level there; with a mipmap filter, every level to the last
        const mip: texture.Mip = switch (p.min) {
            g.NEAREST_MIPMAP_NEAREST, g.LINEAR_MIPMAP_NEAREST => .nearest,
            g.NEAREST_MIPMAP_LINEAR, g.LINEAR_MIPMAP_LINEAR => .linear,
            else => .none,
        };
        var base: u32 = @intCast(@max(t.params.base_level, 0));
        if (t.immutable) base = @min(base, t.levels - 1);
        if (base >= engine.MAX_LEVELS) return .{};
        const mutable_cube = sl.cube and !t.immutable;
        const extra = if (mutable_cube) c.cubeFace(t, base, 0) else c.extraLevel(t, base);
        const base_image = if (extra) |separate| levelOfExtra(separate) else c.textureLevel(t, base) orelse return .{};
        if (!base_image.img.live() or (sl.shadow and (!hasDepth(base_image.internal) or p.compare_mode != g.COMPARE_REF_TO_TEXTURE))) return .{};
        var image = base_image.img;
        var storage_base = base_image.level;
        var layers = if (extra != null) base_image.layers else t.layers;
        var last = base_image.level;
        var gl_last = base;
        if (mip != .none) {
            const depth = if (sl.volume) base_image.layers else 1;
            const top = base + std.math.log2_int(u32, @max(base_image.img.levelWidth(base_image.level), base_image.img.levelHeight(base_image.level), depth));
            if (t.params.max_level < base) return .{};
            gl_last = @min(top, @as(u32, @intCast(t.params.max_level)));
            if (t.immutable) gl_last = @min(gl_last, t.levels - 1);
            if (gl_last >= engine.MAX_LEVELS) return .{};
            var contiguous = extra == null and gl_last < t.img.levels;
            for (base..gl_last + 1) |l| {
                contiguous = contiguous and t.defined & (@as(u16, 1) << @intCast(l)) != 0;
            }
            if (mutable_cube) {
                // All faces are gathered below, including one-level cubes.
            } else if (contiguous) {
                last = gl_last;
            } else if (gl_last != base) {
                if (!c.gatherMips(t, base, gl_last, base_image, scratch)) return .{};
                image = scratch;
                storage_base = 0;
                layers = base_image.layers;
                last = gl_last - base;
            }
        }
        if (mutable_cube) {
            if (!c.gatherCube(t, base, gl_last, extra orelse return .{}, scratch)) return .{};
            image = scratch;
            storage_base = 0;
            layers = 6;
            last = gl_last - base;
        }
        // GL's R, G, B, A as the stored channels: bgra8's bytes are B, G, R, A
        const order: [4]u3 = if (base_image.img.format == .bgra8) .{ 2, 1, 0, 3 } else .{ 0, 1, 2, 3 };
        var rgba: [4]u3 = undefined;
        for (if (extra) |m| m.swizzle else t.fswz, 0..) |s, i| rgba[i] = if (s < 4) order[s] else s;
        var swz: [4]u3 = undefined;
        for (t.params.swizzle, 0..) |s, i| swz[i] = switch (s) {
            g.RED => rgba[0],
            g.GREEN => rgba[1],
            g.BLUE => rgba[2],
            g.ALPHA => rgba[3],
            g.ZERO => texture.SWZ_ZERO,
            else => texture.SWZ_ONE,
        };
        return .{
            .img = image,
            .layers = layers,
            .srgb = base_image.srgb,
            .swizzle = if (sl.shadow) .{ 0, 1, 2, 3 } else swz,
            .wrap_s = wrapOf(p.wrap_s),
            .wrap_t = wrapOf(p.wrap_t),
            .wrap_r = wrapOf(p.wrap_r),
            .compare = @truncate(p.compare_func),
            .linear = p.mag == g.LINEAR,
            .min_linear = p.min == g.LINEAR or p.min == g.LINEAR_MIPMAP_NEAREST or p.min == g.LINEAR_MIPMAP_LINEAR,
            .mip = mip,
            .base = @intCast(storage_base),
            .last = @intCast(last),
            .min_lod = @floatFromInt(p.min_lod),
            .max_lod = @floatFromInt(p.max_lod),
        };
    }

    /// The read framebuffer's read image, complete; else the error.
    fn readSource(c: *Context) ?struct { img: *Image, v: View } {
        const v = c.view(c.read_fb, true);
        if (v.status != g.FRAMEBUFFER_COMPLETE) {
            c.fail(g.INVALID_FRAMEBUFFER_OPERATION);
            return null;
        }
        const img = v.read orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
        return .{ .img = img, .v = v };
    }

    /// The part of (x, y, w, h) inside the read framebuffer copied to
    /// (dx, dy) of `dst` and on.
    fn copyFrom(c: *Context, src: *Image, v: View, x: i32, y: i32, w: i32, h: i32, dst: *Image, dx: i32, dy: i32) void {
        const x0: i64 = @max(x, 0);
        const y0: i64 = @max(y, 0);
        const x1: i64 = @min(@as(i64, x) + w, v.width);
        const y1: i64 = @min(@as(i64, y) + h, v.height);
        if (x1 <= x0 or y1 <= y0) return;
        c.eng.copy(src, @intCast(x0), @intCast(y0), dst, @intCast(dx + (x0 - x)), @intCast(dy + (y0 - y)), @intCast(x1 - x0), @intCast(y1 - y0));
    }

    /// glBlitFramebuffer: the read framebuffer's rectangle onto the draw
    /// framebuffer's, scaled and flipped as the rectangles say, inside
    /// the scissor box: color (the read buffer into each draw buffer,
    /// converted as copies convert; NEAREST or LINEAR), depth and stencil
    /// (NEAREST). Color masks and the depth and stencil write masks do
    /// not apply (GL: only the scissor test does).
    pub fn blitFramebuffer(c: *Context, sx0: i32, sy0: i32, sx1: i32, sy1: i32, dx0: i32, dy0: i32, dx1: i32, dy1: i32, mask: u32, filter: u32) void {
        const ds = g.DEPTH_BUFFER_BIT | g.STENCIL_BUFFER_BIT;
        if (mask & ~(g.COLOR_BUFFER_BIT | ds) != 0) return c.fail(g.INVALID_VALUE);
        if (filter != g.NEAREST and filter != g.LINEAR) return c.fail(g.INVALID_ENUM);
        if (filter == g.LINEAR and mask & ds != 0) return c.fail(g.INVALID_OPERATION);
        const rv = c.view(c.read_fb, true);
        var dv = c.view(c.draw_fb, false);
        if (rv.status != g.FRAMEBUFFER_COMPLETE or dv.status != g.FRAMEBUFFER_COMPLETE) return c.fail(g.INVALID_FRAMEBUFFER_OPERATION);
        // (an image both read and drawn)
        if (mask & g.COLOR_BUFFER_BIT != 0) {
            if (rv.read) |s| {
                for (dv.color) |d| {
                    if (d == s) return c.fail(g.INVALID_OPERATION);
                }
            }
        }
        if (mask & g.DEPTH_BUFFER_BIT != 0 and rv.depth != null and rv.depth == dv.depth) return c.fail(g.INVALID_OPERATION);
        if (mask & g.STENCIL_BUFFER_BIT != 0 and rv.stencil != null and rv.stencil == dv.stencil) return c.fail(g.INVALID_OPERATION);
        if (sx0 == sx1 or sy0 == sy1 or dx0 == dx1 or dy0 == dy1 or mask == 0) return;
        const cap = struct {
            fn f(x: i32) u32 {
                return @intCast(std.math.clamp(x, 0, MAX_SIZE));
            }
        }.f;
        const dst_rect = Rect{ .x0 = cap(@min(dx0, dx1)), .y0 = cap(@min(dy0, dy1)), .x1 = cap(@max(dx0, dx1)), .y1 = cap(@max(dy0, dy1)) };
        const a = dst_rect.meet(c.clearRect(&dv));
        if (a.empty()) return;
        const scale = struct {
            fn f(s0: i32, s1: i32, d0: i32, d1: i32) f32 {
                return @floatCast(@as(f64, @floatFromInt(@as(i64, s1) - s0)) / @as(f64, @floatFromInt(@as(i64, d1) - d0)));
            }
        }.f;
        var b = engine.Blit{
            .rect = a,
            .dx0 = dx0,
            .sx0 = @floatFromInt(sx0),
            .scale_x = scale(sx0, sx1, dx0, dx1),
            .dy0 = dy0,
            .sy0 = @floatFromInt(sy0),
            .scale_y = scale(sy0, sy1, dy0, dy1),
            .linear = filter == g.LINEAR,
        };
        if (mask & g.COLOR_BUFFER_BIT != 0) {
            if (rv.read) |s| {
                for (dv.color) |d| {
                    const img = d orelse continue;
                    if (!c.eng.blit(s, img, b)) return c.fail(g.OUT_OF_MEMORY);
                }
            }
        }
        // depth and stencil: the 24 and 8 bits of their images (one blit
        // where both are one image each side)
        b.linear = false;
        const want_d = mask & g.DEPTH_BUFFER_BIT != 0 and rv.depth != null and dv.depth != null;
        const want_s = mask & g.STENCIL_BUFFER_BIT != 0 and rv.stencil != null and dv.stencil != null;
        if (want_d and want_s and rv.depth == rv.stencil and dv.depth == dv.stencil) {
            if (!c.eng.blit(rv.depth.?, dv.depth.?, b)) return c.fail(g.OUT_OF_MEMORY);
            return;
        }
        if (want_d) {
            b.wmask = 0x00ff_ffff;
            if (!c.eng.blit(rv.depth.?, dv.depth.?, b)) return c.fail(g.OUT_OF_MEMORY);
        }
        if (want_s) {
            b.wmask = 0xff00_0000;
            if (!c.eng.blit(rv.stencil.?, dv.stencil.?, b)) return c.fail(g.OUT_OF_MEMORY);
        }
    }

    /// A copy from a framebuffer of `from` into a texture of `to`: both
    /// renderable, `to` of `from`'s channels or fewer (ES 3.0).
    fn copyable(from: Format, to: Format) bool {
        return from.renderable() and to.renderable() and to.channels() <= from.channels();
    }

    const CopyImage = struct { img: *Image, internal: u32, samples: u32, layers: u32 = 1, level: u32 = 0 };

    fn copyImageOf(c: *Context, name: u32, target: u32, level: i32, face: ?u32) ?CopyImage {
        if (level < 0 or level >= engine.MAX_LEVELS) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        switch (target) {
            g.TEXTURE_2D, g.TEXTURE_3D, g.TEXTURE_2D_ARRAY, g.TEXTURE_CUBE_MAP => {
                const tex = madeIn(Tex, &c.objs.tex, name) orelse {
                    c.fail(g.INVALID_VALUE);
                    return null;
                };
                if (tex.target != target) {
                    c.fail(g.INVALID_ENUM);
                    return null;
                }
                const mip = (if (face) |index| blk: {
                    if (index >= 6) break :blk null;
                    const image = c.cubeFace(tex, @intCast(level), index) orelse break :blk null;
                    break :blk levelOfExtra(image);
                } else c.textureLevel(tex, @intCast(level))) orelse {
                    c.fail(g.INVALID_VALUE);
                    return null;
                };
                if (!mip.img.live()) {
                    c.fail(g.INVALID_VALUE);
                    return null;
                }
                return .{ .img = mip.img, .internal = mip.internal, .samples = 0, .layers = mip.layers, .level = mip.level };
            },
            g.RENDERBUFFER => {
                const rb = madeIn(Rb, &c.objs.rbs, name) orelse {
                    c.fail(g.INVALID_VALUE);
                    return null;
                };
                if (level != 0 or rb.img.buf.cpu.len == 0) {
                    c.fail(g.INVALID_VALUE);
                    return null;
                }
                return .{ .img = &rb.img, .internal = rb.internal, .samples = rb.samples };
            },
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        }
    }

    /// Raw copies between supported images. Do not reinterpret channels
    /// or use framebuffer state. Wait for pending access to both objects.
    pub fn copyImageSubData(c: *Context, sn: u32, st: u32, sl: i32, sx: i32, sy: i32, sz: i32, dn: u32, dt: u32, dl: i32, dx: i32, dy: i32, dz: i32, w: i32, h: i32, depth: i32) void {
        const source_cube = st == g.TEXTURE_CUBE_MAP and c.mutableCube(sn);
        const dest_cube = dt == g.TEXTURE_CUBE_MAP and c.mutableCube(dn);
        if (source_cube or dest_cube) {
            if (sz < 0 or dz < 0 or depth < 0 or depth > 6 or
                (source_cube and @as(i64, sz) + depth > 6) or (dest_cube and @as(i64, dz) + depth > 6) or
                @as(i64, sz) + depth > std.math.maxInt(i32) or @as(i64, dz) + depth > std.math.maxInt(i32))
                return c.fail(g.INVALID_VALUE);
            if (depth == 0) return;
            var sources: [6]CopyImage = undefined;
            var destinations: [6]CopyImage = undefined;
            for (0..@intCast(depth)) |layer| {
                const z: i32 = @intCast(layer);
                sources[layer] = c.copyImageOf(sn, st, sl, if (source_cube) @intCast(sz + z) else null) orelse return;
                destinations[layer] = c.copyImageOf(dn, dt, dl, if (dest_cube) @intCast(dz + z) else null) orelse return;
                if (!c.validateImageCopy(sources[layer], destinations[layer], sx, sy, if (source_cube) 0 else sz + z, dx, dy, if (dest_cube) 0 else dz + z, w, h, 1)) return;
            }
            if (w == 0 or h == 0) return;
            for (0..@intCast(depth)) |layer| {
                const z: i32 = @intCast(layer);
                c.copyImageRegion(sources[layer], destinations[layer], sx, sy, if (source_cube) 0 else sz + z, dx, dy, if (dest_cube) 0 else dz + z, w, h, 1);
            }
            return;
        }
        const src = c.copyImageOf(sn, st, sl, null) orelse return;
        const dst = c.copyImageOf(dn, dt, dl, null) orelse return;
        if (!c.validateImageCopy(src, dst, sx, sy, sz, dx, dy, dz, w, h, depth)) return;
        if (w == 0 or h == 0 or depth == 0) return;
        c.copyImageRegion(src, dst, sx, sy, sz, dx, dy, dz, w, h, depth);
    }

    fn mutableCube(c: *Context, name: u32) bool {
        const t = madeIn(Tex, &c.objs.tex, name) orelse return false;
        return t.target == g.TEXTURE_CUBE_MAP and !t.immutable;
    }

    fn validateImageCopy(c: *Context, src: CopyImage, dst: CopyImage, sx: i32, sy: i32, sz: i32, dx: i32, dy: i32, dz: i32, w: i32, h: i32, depth: i32) bool {
        if (src.internal != dst.internal or src.img.format != dst.img.format or src.samples != dst.samples) {
            c.fail(g.INVALID_OPERATION);
            return false;
        }
        if (sx < 0 or sy < 0 or sz < 0 or dx < 0 or dy < 0 or dz < 0 or
            w < 0 or h < 0 or depth < 0 or @as(i64, sz) + depth > src.layers or @as(i64, dz) + depth > dst.layers)
        {
            c.fail(g.INVALID_VALUE);
            return false;
        }
        if (@as(i64, sx) + w > src.img.levelWidth(src.level) or @as(i64, sy) + h > src.img.levelHeight(src.level) or
            @as(i64, dx) + w > dst.img.levelWidth(dst.level) or @as(i64, dy) + h > dst.img.levelHeight(dst.level))
        {
            c.fail(g.INVALID_VALUE);
            return false;
        }
        return true;
    }

    fn copyImageRegion(c: *Context, src: CopyImage, dst: CopyImage, sx: i32, sy: i32, sz: i32, dx: i32, dy: i32, dz: i32, w: i32, h: i32, depth: i32) void {
        const slevel = src.level;
        const dlevel = dst.level;
        const sh = src.img.levelHeight(slevel);
        const dh = dst.img.levelHeight(dlevel);
        const sa = @intFromPtr(src.img.buf.cpu.ptr);
        const da = @intFromPtr(dst.img.buf.cpu.ptr);
        const apart = if (sa <= da) src.img.buf.cpu.len <= da - sa else dst.img.buf.cpu.len <= sa - da;
        // The existing GPU copy is bit-preserving for these base-level
        // formats. Other layouts need the raw row path below.
        if (slevel == 0 and dlevel == 0 and sz == 0 and dz == 0 and depth == 1 and src.img.format.bytes() <= 4 and
            !src.img.no_alpha and (src.img.buf.handle != dst.img.buf.handle or apart))
        {
            c.eng.copy(src.img, @intCast(sx), @intCast(sy), dst.img, @intCast(dx), @intCast(dy), @intCast(w), @intCast(h));
            return;
        }
        const sdata = c.eng.hostView(src.img, 0, src.img.buf.cpu.len);
        const ddata = c.eng.hostView(dst.img, 0, dst.img.buf.cpu.len);
        const bpp: usize = src.img.format.bytes();
        const n = @as(usize, @intCast(w)) * bpp;
        const ss: usize = src.img.levelStride(slevel);
        const ds: usize = dst.img.levelStride(dlevel);
        for (0..@intCast(depth)) |layer| {
            const sbase = src.img.level_at[slevel] + (@as(usize, @intCast(sz)) + layer) * sh * ss;
            const dbase = dst.img.level_at[dlevel] + (@as(usize, @intCast(dz)) + layer) * dh * ds;
            for (0..@intCast(h)) |row| {
                const srow = @as(usize, @intCast(sy)) + row;
                const drow = @as(usize, @intCast(dy)) + row;
                const so = sbase + (if (src.img.top_down) sh - 1 - srow else srow) * ss + @as(usize, @intCast(sx)) * bpp;
                const do = dbase + (if (dst.img.top_down) dh - 1 - drow else drow) * ds + @as(usize, @intCast(dx)) * bpp;
                std.mem.copyForwards(u8, ddata[do..][0..n], sdata[so..][0..n]);
                c.eng.wrote(dst.img, do, n);
            }
        }
    }

    pub fn copyTexSubImage2D(c: *Context, target: u32, level: i32, dx: i32, dy: i32, x: i32, y: i32, w: i32, h: i32) void {
        const t = c.boundTex2D(target) orelse return;
        if (level != 0 or dx < 0 or dy < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        if (@as(i64, dx) + w > t.img.width or @as(i64, dy) + h > t.img.height) return c.fail(g.INVALID_VALUE);
        const s = c.readSource() orelse return;
        if (!copyable(s.img.format, t.img.format) or t.srgb or s.img == &t.img) return c.fail(g.INVALID_OPERATION);
        c.copyFrom(s.img, s.v, x, y, w, h, &t.img, dx, dy);
    }

    pub fn copyTexSubImage3D(c: *Context, target: u32, level: i32, dx: i32, dy: i32, dz: i32, x: i32, y: i32, w: i32, h: i32) void {
        if (target != g.TEXTURE_3D and target != g.TEXTURE_2D_ARRAY) return c.fail(g.INVALID_ENUM);
        const t = c.boundLayered(target) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or dx < 0 or dy < 0 or dz < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        const mip = c.textureLevel(t, @intCast(level)) orelse return c.fail(g.INVALID_OPERATION);
        if (@as(i64, dx) + w > mip.img.levelWidth(mip.level) or @as(i64, dy) + h > mip.img.levelHeight(mip.level) or dz >= mip.layers)
            return c.fail(g.INVALID_VALUE);
        const src = c.readSource() orelse return;
        if (!copyable(src.img.format, mip.img.format) or mip.srgb) return c.fail(g.INVALID_OPERATION);
        var dst = engine.borrowSlice(mip.img, mip.share, mip.level, @intCast(dz));
        if (src.img.buf.cpu.ptr == dst.buf.cpu.ptr) return c.fail(g.INVALID_OPERATION);
        c.copyFrom(src.img, src.v, x, y, w, h, &dst, dx, dy);
    }

    pub fn copyTexImage2D(c: *Context, target: u32, level: i32, internal: u32, x: i32, y: i32, w: i32, h: i32, border: i32) void {
        const t = c.boundTex2D(target) orelse return;
        if (level != 0 or w < 0 or h < 0 or w > MAX_SIZE or h > MAX_SIZE or border != 0) return c.fail(g.INVALID_VALUE);
        const fmt: Format = switch (internal) {
            g.RGBA, g.RGBA8 => .rgba8,
            g.BGRA_EXT, g.BGRA8_EXT => .bgra8,
            g.R8 => .r8,
            g.RG8 => .rg8,
            g.RGB, g.ALPHA, g.LUMINANCE, g.LUMINANCE_ALPHA, g.RGB8, g.RGB565, g.RGBA4, g.RGB5_A1 => return c.fail(g.INVALID_OPERATION),
            else => return c.fail(g.INVALID_ENUM),
        };
        if (t.immutable) return c.fail(g.INVALID_OPERATION);
        const s = c.readSource() orelse return;
        if (!copyable(s.img.format, fmt) or s.img == &t.img) return c.fail(g.INVALID_OPERATION);
        if (!c.defineTex(t, @intCast(w), @intCast(h), fmt, internal)) return;
        t.fswz = .{ 0, 1, 2, 3 };
        t.srgb = false;
        c.copyFrom(s.img, s.v, x, y, w, h, &t.img, 0, 0);
    }

    // ── Buffers ────────────────────────────────────────────────────────────

    pub fn genBuffers(c: *Context, out: []u32) void {
        if (!genIn(Buf, &c.objs.bufs, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn isBuffer(c: *Context, name: u32) bool {
        return madeIn(Buf, &c.objs.bufs, name) != null;
    }

    fn bindingOf(c: *Context, target: u32) ?*u32 {
        return switch (target) {
            g.ARRAY_BUFFER => &c.bufs.array,
            g.ELEMENT_ARRAY_BUFFER => &c.curVao().element,
            g.PIXEL_PACK_BUFFER => &c.bufs.pack,
            g.PIXEL_UNPACK_BUFFER => &c.bufs.unpack,
            g.UNIFORM_BUFFER => &c.bufs.uniform,
            g.COPY_READ_BUFFER => &c.bufs.copy_read,
            g.COPY_WRITE_BUFFER => &c.bufs.copy_write,
            g.TRANSFORM_FEEDBACK_BUFFER => &c.bufs.xfb,
            else => null,
        };
    }

    /// glBindBufferBase and glBindBufferRange (range: size > 0): an
    /// indexed binding point, and the target's own one too, as GL says.
    pub fn bindBufferRange(c: *Context, target: u32, index: u32, name: u32, offset: isize, size: isize, ranged: bool) void {
        const slot: *Indexed = switch (target) {
            g.UNIFORM_BUFFER => blk: {
                if (index >= program.MAX_UNIFORM_BUFFER_BINDINGS) return c.fail(g.INVALID_VALUE);
                if (ranged and @mod(offset, program.UNIFORM_BUFFER_OFFSET_ALIGNMENT) != 0) return c.fail(g.INVALID_VALUE);
                break :blk &c.ubo[index];
            },
            g.TRANSFORM_FEEDBACK_BUFFER => blk: {
                const t = c.feedbackOf() orelse return;
                if (index >= MAX_FEEDBACK_BUFFERS) return c.fail(g.INVALID_VALUE);
                if (t.active) return c.fail(g.INVALID_OPERATION);
                if (ranged and (@mod(offset, 4) != 0 or @mod(size, 4) != 0)) return c.fail(g.INVALID_VALUE);
                break :blk &t.bufs[index];
            },
            else => return c.fail(g.INVALID_ENUM),
        };
        if (ranged and name != 0 and (offset < 0 or size <= 0)) return c.fail(g.INVALID_VALUE);
        if (name != 0 and makeIn(Buf, &c.objs.bufs, name) == null) return c.fail(g.OUT_OF_MEMORY);
        slot.* = if (name == 0) .{} else .{ .buf = name, .offset = if (ranged) @intCast(offset) else 0, .size = if (ranged) @intCast(size) else 0, .ranged = ranged };
        (c.bindingOf(target) orelse unreachable).* = name;
    }

    /// The transform feedback object bound.
    pub fn feedbackOf(c: *Context) ?*Feedback {
        if (c.xfb == 0) return &c.feedback0;
        return madeIn(Feedback, &c.feedbacks, c.xfb);
    }

    /// glGetIntegeri_v and glGetInteger64i_v: an indexed binding point's
    /// buffer, start and size.
    pub fn getIndexed(c: *Context, pname: u32, index: u32) ?i64 {
        const uniform = pname == g.UNIFORM_BUFFER_BINDING or pname == g.UNIFORM_BUFFER_START or pname == g.UNIFORM_BUFFER_SIZE;
        const xfb = pname == g.TRANSFORM_FEEDBACK_BUFFER_BINDING or pname == g.TRANSFORM_FEEDBACK_BUFFER_START or pname == g.TRANSFORM_FEEDBACK_BUFFER_SIZE;
        if (!uniform and !xfb) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        const s: Indexed = if (uniform) blk: {
            if (index >= program.MAX_UNIFORM_BUFFER_BINDINGS) {
                c.fail(g.INVALID_VALUE);
                return null;
            }
            break :blk c.ubo[index];
        } else blk: {
            if (index >= MAX_FEEDBACK_BUFFERS) {
                c.fail(g.INVALID_VALUE);
                return null;
            }
            const t = c.feedbackOf() orelse return null;
            break :blk t.bufs[index];
        };
        return switch (pname) {
            g.UNIFORM_BUFFER_BINDING, g.TRANSFORM_FEEDBACK_BUFFER_BINDING => s.buf,
            g.UNIFORM_BUFFER_START, g.TRANSFORM_FEEDBACK_BUFFER_START => @intCast(s.offset),
            else => @intCast(s.size),
        };
    }

    /// The bytes a uniform block bound at `binding` reads (at most
    /// `want`): its buffer's range, as the CPU sees it now; none when no
    /// buffer is bound there.
    pub fn uniformBytes(c: *Context, binding: u32, want: u32) []const u8 {
        if (binding >= program.MAX_UNIFORM_BUFFER_BINDINGS) return &.{};
        const s = c.ubo[binding];
        const b = madeIn(Buf, &c.objs.bufs, s.buf) orelse return &.{};
        if (s.offset >= b.size) return &.{};
        var len = b.size - s.offset;
        if (s.ranged) len = @min(len, s.size);
        len = @min(len, want);
        if (len == 0 or b.store.buf.cpu.len < s.offset + len) return &.{};
        return c.eng.hostView(&b.store, s.offset, len);
    }

    /// glGetInternalformativ: no multisampled renderbuffers (MAX_SAMPLES
    /// is 1), so every renderable format has no sample counts.
    pub fn internalformat(c: *Context, target: u32, pname: u32, out: []i32) void {
        if (target != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        switch (pname) {
            g.NUM_SAMPLE_COUNTS => {
                if (out.len > 0) out[0] = 0;
            },
            g.SAMPLES => {},
            else => c.fail(g.INVALID_ENUM),
        }
    }

    pub fn bindBuffer(c: *Context, target: u32, name: u32) void {
        const b = c.bindingOf(target) orelse return c.fail(g.INVALID_ENUM);
        if (name != 0 and makeIn(Buf, &c.objs.bufs, name) == null) return c.fail(g.OUT_OF_MEMORY);
        b.* = name;
    }

    fn boundBuf(c: *Context, target: u32) ?*Buf {
        const b = c.bindingOf(target) orelse {
            c.fail(g.INVALID_ENUM);
            return null;
        };
        return madeIn(Buf, &c.objs.bufs, b.*) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
    }

    pub fn bufferData(c: *Context, target: u32, size: isize, data: ?*const anyopaque, usage: u32) void {
        if (c.bindingOf(target) == null) return c.fail(g.INVALID_ENUM);
        if (size < 0) return c.fail(g.INVALID_VALUE);
        if (!validUsage(usage)) return c.fail(g.INVALID_ENUM);
        const b = c.boundBuf(target) orelse return;
        if (b.immutable) return c.fail(g.INVALID_OPERATION);
        const n: usize = @intCast(size);
        c.unmap(b);
        // (new storage: what the GPU may still read of the old goes once it is done)
        c.eng.freeImage(&b.store);
        b.size = 0;
        b.usage = usage;
        b.storage_flags = MAP_READ | MAP_WRITE | DYNAMIC_STORAGE;
        if (n == 0) return;
        b.store = c.eng.newBuffer(n) orelse return c.fail(g.OUT_OF_MEMORY);
        b.size = n;
        if (data) |p| c.eng.writeBytes(&b.store, 0, @as([*]const u8, @ptrCast(p))[0..n]);
    }

    /// Immutable storage. Keep the old store
    /// alive until the replacement has been allocated and initialized.
    pub fn bufferStorage(c: *Context, target: u32, size: isize, data: ?*const anyopaque, flags: u32) void {
        const b = c.boundBuf(target) orelse return;
        if (size <= 0 or flags & ~@as(u32, MAP_READ | MAP_WRITE | MAP_PERSISTENT | MAP_COHERENT | DYNAMIC_STORAGE | CLIENT_STORAGE) != 0 or
            (flags & MAP_PERSISTENT != 0 and flags & (MAP_READ | MAP_WRITE) == 0) or
            (flags & MAP_COHERENT != 0 and flags & MAP_PERSISTENT == 0))
            return c.fail(g.INVALID_VALUE);
        if (b.immutable) return c.fail(g.INVALID_OPERATION);
        // Explicit flushes and client barriers synchronize noncoherent
        // mappings. Coherent mappings need snooped RTX system memory.
        if (flags & MAP_COHERENT != 0 and c.eng.onGpu() and
            !(builtin.cpu.arch == .x86_64 and c.eng.dev.?.caps.target == .sm_120))
            return c.fail(g.OUT_OF_MEMORY);
        const n: usize = @intCast(size);
        var store = c.eng.newBuffer(n) orelse return c.fail(g.OUT_OF_MEMORY);
        if (data) |p| c.eng.writeBytes(&store, 0, @as([*]const u8, @ptrCast(p))[0..n]);
        c.unmap(b);
        c.eng.freeImage(&b.store);
        b.store = store;
        b.size = n;
        b.usage = g.DYNAMIC_DRAW;
        b.immutable = true;
        b.storage_flags = flags;
    }

    pub fn bufferSubData(c: *Context, target: u32, offset: isize, size: isize, data: ?*const anyopaque) void {
        if (c.bindingOf(target) == null) return c.fail(g.INVALID_ENUM);
        if (offset < 0 or size < 0) return c.fail(g.INVALID_VALUE);
        const b = c.boundBuf(target) orelse return;
        const off: usize = @intCast(offset);
        const n: usize = @intCast(size);
        if (off > b.size or n > b.size - off) return c.fail(g.INVALID_VALUE);
        if (!c.notMapped(b)) return;
        if (b.immutable and b.storage_flags & DYNAMIC_STORAGE == 0) return c.fail(g.INVALID_OPERATION);
        const p = data orelse return;
        c.eng.writeBytes(&b.store, off, @as([*]const u8, @ptrCast(p))[0..n]);
    }

    pub fn copyBufferSubData(c: *Context, read_target: u32, write_target: u32, read_offset: isize, write_offset: isize, size: isize) void {
        if (c.bindingOf(read_target) == null or c.bindingOf(write_target) == null) return c.fail(g.INVALID_ENUM);
        if (read_offset < 0 or write_offset < 0 or size < 0) return c.fail(g.INVALID_VALUE);
        const src = c.boundBuf(read_target) orelse return;
        const dst = c.boundBuf(write_target) orelse return;
        const from: usize = @intCast(read_offset);
        const to: usize = @intCast(write_offset);
        const n: usize = @intCast(size);
        if (from > src.size or n > src.size - from or to > dst.size or n > dst.size - to) return c.fail(g.INVALID_VALUE);
        if (src == dst and n != 0 and from < to + n and to < from + n) return c.fail(g.INVALID_VALUE);
        if (!c.notMapped(src) or !c.notMapped(dst)) return;
        if (n == 0) return;
        const source = c.eng.hostView(&src.store, from, n);
        const target = c.eng.hostView(&dst.store, to, n);
        @memcpy(target, source);
        c.eng.wrote(&dst.store, to, n);
    }

    /// glMapBufferRange: the buffer's bytes [offset, offset + length) for
    /// the CPU, in its memory (no copy). A synchronized map waits for the
    /// GPU's use of the buffer; MAP_UNSYNCHRONIZED_BIT does not; and
    /// MAP_INVALIDATE_BUFFER_BIT on a buffer the GPU uses gives it new
    /// storage instead of waiting (the old goes once the GPU is done).
    pub fn mapBufferRange(c: *Context, target: u32, offset: isize, length: isize, access: u32) ?*anyopaque {
        if (c.bindingOf(target) == null) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        const b = c.boundBuf(target) orelse return null;
        if (offset < 0 or length < 0 or access & ~@as(u32, 0xff) != 0) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        const off: usize = @intCast(offset);
        const n: usize = @intCast(length);
        if (off > b.size or n > b.size - off) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        const read = access & MAP_READ != 0;
        const write = access & MAP_WRITE != 0;
        const bad = n == 0 or b.mapped() or (!read and !write) or
            (access & (MAP_READ | MAP_WRITE | MAP_PERSISTENT | MAP_COHERENT) & ~b.storage_flags != 0) or
            (access & MAP_COHERENT != 0 and access & MAP_PERSISTENT == 0) or
            (read and access & (MAP_INVALIDATE_RANGE | MAP_INVALIDATE_BUFFER | MAP_UNSYNCHRONIZED) != 0) or
            (access & MAP_FLUSH_EXPLICIT != 0 and !write);
        if (bad) {
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        if (!b.immutable and access & MAP_INVALIDATE_BUFFER != 0 and c.eng.busy(&b.store)) {
            const fresh = c.eng.newBuffer(b.size) orelse {
                c.fail(g.OUT_OF_MEMORY);
                return null;
            };
            c.eng.freeImage(&b.store);
            b.store = fresh;
        }
        const span = if (access & MAP_UNSYNCHRONIZED != 0) c.eng.hostViewNow(&b.store, off, n) else c.eng.hostView(&b.store, off, n);
        b.map = span;
        b.map_off = off;
        b.map_access = access;
        return span.ptr;
    }

    /// glUnmapBuffer: what a write map wrote goes to the GPU (all of it,
    /// or with MAP_FLUSH_EXPLICIT_BIT what was flushed).
    pub fn unmapBuffer(c: *Context, target: u32) bool {
        if (c.bindingOf(target) == null) {
            c.fail(g.INVALID_ENUM);
            return false;
        }
        const b = c.boundBuf(target) orelse return false;
        if (!b.mapped()) {
            c.fail(g.INVALID_OPERATION);
            return false;
        }
        c.unmap(b);
        return true;
    }

    fn unmap(c: *Context, b: *Buf) void {
        const m = b.map orelse return;
        if (b.map_access & MAP_WRITE != 0 and b.map_access & MAP_FLUSH_EXPLICIT == 0) c.eng.wrote(&b.store, b.map_off, m.len);
        b.map = null;
        b.map_off = 0;
        b.map_access = 0;
    }

    /// glFlushMappedBufferRange: [offset, offset + length) of the map (a
    /// MAP_FLUSH_EXPLICIT_BIT one) goes to the GPU.
    pub fn flushMappedBufferRange(c: *Context, target: u32, offset: isize, length: isize) void {
        if (c.bindingOf(target) == null) return c.fail(g.INVALID_ENUM);
        const b = c.boundBuf(target) orelse return;
        if (offset < 0 or length < 0) return c.fail(g.INVALID_VALUE);
        const m = b.map orelse return c.fail(g.INVALID_OPERATION);
        if (b.map_access & MAP_FLUSH_EXPLICIT == 0) return c.fail(g.INVALID_OPERATION);
        const off: usize = @intCast(offset);
        const n: usize = @intCast(length);
        if (off > m.len or n > m.len - off) return c.fail(g.INVALID_VALUE);
        c.eng.wrote(&b.store, b.map_off + off, n);
    }

    /// glGetBufferPointerv(BUFFER_MAP_POINTER).
    pub fn getBufferPointer(c: *Context, target: u32, pname: u32) ?*anyopaque {
        if (pname != g.BUFFER_MAP_POINTER) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        if (c.bindingOf(target) == null) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        const b = c.boundBuf(target) orelse return null;
        return if (b.map) |m| m.ptr else null;
    }

    /// A buffer a command reads or writes is not mapped (else
    /// INVALID_OPERATION).
    fn notMapped(c: *Context, b: *const Buf) bool {
        if (!b.mapped() or b.map_access & MAP_PERSISTENT != 0) return true;
        c.fail(g.INVALID_OPERATION);
        return false;
    }

    /// Publish server writes to noncoherent persistent client mappings.
    /// Waiting here is conservative and avoids retaining ranges past unmap.
    pub fn clientMappedBarrier(c: *Context, bits: u32) void {
        if (bits == 0) return;
        if (bits != CLIENT_MAPPED_BUFFER_BARRIER and bits != 0xffff_ffff)
            return c.fail(g.INVALID_VALUE);
        c.eng.finish();
        for (&c.objs.bufs) |*b| {
            if (b.map_access & (MAP_READ | MAP_PERSISTENT) != (MAP_READ | MAP_PERSISTENT)) continue;
            if (b.map) |m| _ = c.eng.hostView(&b.store, b.map_off, m.len);
        }
    }

    pub fn getBufferParameter(c: *Context, target: u32, pname: u32) ?i64 {
        const b = c.boundBuf(target) orelse return null;
        return switch (pname) {
            g.BUFFER_SIZE => @intCast(b.size),
            g.BUFFER_USAGE => b.usage,
            0x821F => @intFromBool(b.immutable), // GL_BUFFER_IMMUTABLE_STORAGE_EXT
            0x8220 => b.storage_flags, // GL_BUFFER_STORAGE_FLAGS_EXT
            g.BUFFER_MAPPED => @intFromBool(b.mapped()),
            g.BUFFER_ACCESS_FLAGS => b.map_access,
            g.BUFFER_MAP_LENGTH => @intCast(if (b.map) |m| m.len else 0),
            g.BUFFER_MAP_OFFSET => @intCast(b.map_off),
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    pub fn deleteBuffers(c: *Context, names: []const u32) void {
        for (names) |name| {
            const b = madeIn(Buf, &c.objs.bufs, name) orelse {
                if (slotIn(Buf, &c.objs.bufs, name)) |s| s.named = false;
                continue;
            };
            inline for (@typeInfo(BufBinds).@"struct".field_names) |f| {
                if (@field(c.bufs, f) == name) @field(c.bufs, f) = 0;
            }
            // (and from the indexed binding points)
            for (&c.ubo) |*s| {
                if (s.buf == name) s.* = .{};
            }
            if (c.feedbackOf()) |t| {
                for (&t.bufs) |*s| {
                    if (s.buf == name) s.* = .{};
                }
            }
            // (and from the bound vertex array, as GL says)
            const va = c.curVao();
            if (va.element == name) va.element = 0;
            for (&va.attrs) |*a| {
                if (a.buffer == name) a.buffer = 0;
            }
            c.unmap(b);
            c.eng.freeImage(&b.store);
            b.* = .{};
        }
    }

    // ── Sync objects ───────────────────────────────────────────────────────
    //
    // A fence is the engine's mark after the work recorded before it (that
    // work is run then). A GLsync is the share group's slot, plus one.

    pub fn objectLabel(c: *Context, identifier: u32, name: u32) ?*debug_output.Label {
        const label: ?*debug_output.Label = switch (identifier) {
            0x82E0 => if (madeIn(Buf, &c.objs.bufs, name)) |o| &o.label else null,
            0x82E1, 0x82E2 => program.objectLabel(c, name, identifier == 0x82E1),
            0x8074 => if (madeIn(Vao, &c.vaos, name)) |o| &o.label else null,
            0x82E6 => if (madeIn(Smp, &c.objs.samplers, name)) |o| &o.label else null,
            g.TEXTURE => if (madeIn(Tex, &c.objs.tex, name)) |o| &o.label else null,
            g.RENDERBUFFER => if (madeIn(Rb, &c.objs.rbs, name)) |o| &o.label else null,
            g.FRAMEBUFFER => if (madeIn(Fbo, &c.fbos, name)) |o| &o.label else null,
            // These namespaces exist in the API, but this driver has no live objects in them.
            0x82E3 => if (c.isTimerQuery(name)) &c.timers[name - 1].label else null,
            0x82E4, 0x8E22 => null,
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
        if (label == null) c.fail(g.INVALID_VALUE);
        return label;
    }

    pub fn pointerLabel(c: *Context, h: ?*const anyopaque) ?*debug_output.Label {
        const s = c.syncOf(h) orelse {
            c.fail(g.INVALID_VALUE);
            return null;
        };
        return &s.label;
    }

    fn syncOf(c: *Context, h: ?*const anyopaque) ?*Sync {
        const x = @intFromPtr(h);
        if (x == 0 or x > MAX_SYNCS) return null;
        const s = &c.objs.syncs[x - 1];
        return if (s.used) s else null;
    }

    /// glFenceSync; null (no error) when the share group has no room.
    pub fn fenceSync(c: *Context, condition: u32, flags: u32) ?*anyopaque {
        if (condition != g.SYNC_GPU_COMMANDS_COMPLETE) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        if (flags != 0) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        for (&c.objs.syncs, 0..) |*s, ix| {
            if (s.used) continue;
            s.* = .{ .used = true, .mark = c.eng.mark() };
            return @ptrFromInt(ix + 1);
        }
        return null;
    }

    /// glClientWaitSync: ALREADY_SIGNALED, CONDITION_SATISFIED (done while
    /// waiting), TIMEOUT_EXPIRED, or WAIT_FAILED (with an error).
    pub fn clientWaitSync(c: *Context, h: ?*const anyopaque, flags: u32, timeout_ns: u64) u32 {
        const s = c.syncOf(h) orelse {
            c.fail(g.INVALID_VALUE);
            return g.WAIT_FAILED;
        };
        if (flags & ~g.SYNC_FLUSH_COMMANDS_BIT != 0) {
            c.fail(g.INVALID_VALUE);
            return g.WAIT_FAILED;
        }
        if (c.eng.markDone(s.mark)) return g.ALREADY_SIGNALED;
        if (timeout_ns == 0) return g.TIMEOUT_EXPIRED;
        const us = timeout_ns / 1000 + @intFromBool(timeout_ns % 1000 != 0);
        return if (c.eng.waitMark(s.mark, us)) g.CONDITION_SATISFIED else g.TIMEOUT_EXPIRED;
    }

    /// glWaitSync: the GPU's ring runs in order, so nothing to wait for.
    pub fn waitSync(c: *Context, h: ?*const anyopaque, flags: u32, timeout: u64) void {
        _ = c.syncOf(h) orelse return c.fail(g.INVALID_VALUE);
        if (flags != 0 or timeout != g.TIMEOUT_IGNORED) return c.fail(g.INVALID_VALUE);
    }

    pub fn deleteSync(c: *Context, h: ?*const anyopaque) void {
        if (h == null) return;
        const s = c.syncOf(h) orelse return c.fail(g.INVALID_VALUE);
        s.* = .{};
    }

    pub fn isSync(c: *Context, h: ?*const anyopaque) bool {
        return c.syncOf(h) != null;
    }

    /// glGetSynciv's value, or null (with an error).
    pub fn getSync(c: *Context, h: ?*const anyopaque, pname: u32) ?i32 {
        const s = c.syncOf(h) orelse {
            c.fail(g.INVALID_VALUE);
            return null;
        };
        return switch (pname) {
            g.OBJECT_TYPE => g.SYNC_FENCE,
            g.SYNC_STATUS => if (c.eng.markDone(s.mark)) g.SIGNALED else g.UNSIGNALED,
            g.SYNC_CONDITION => g.SYNC_GPU_COMMANDS_COMPLETE,
            g.SYNC_FLAGS => 0,
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    // ── Renderbuffers ──────────────────────────────────────────────────────

    pub fn genRenderbuffers(c: *Context, out: []u32) void {
        if (!genIn(Rb, &c.objs.rbs, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn isRenderbuffer(c: *Context, name: u32) bool {
        return madeIn(Rb, &c.objs.rbs, name) != null;
    }

    pub fn bindRenderbuffer(c: *Context, target: u32, name: u32) void {
        if (target != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        if (name != 0 and makeIn(Rb, &c.objs.rbs, name) == null) return c.fail(g.OUT_OF_MEMORY);
        c.rb = name;
    }

    pub fn renderbufferStorage(c: *Context, target: u32, samples: i32, internal: u32, w: i32, h: i32) void {
        if (target != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        const fmt = rbFormat(internal) orelse return c.fail(g.INVALID_ENUM);
        if (w < 0 or h < 0 or w > MAX_SIZE or h > MAX_SIZE or samples < 0) return c.fail(g.INVALID_VALUE);
        if (samples > 1) return c.fail(g.INVALID_OPERATION);
        const rb = madeIn(Rb, &c.objs.rbs, c.rb) orelse return c.fail(g.INVALID_OPERATION);
        c.eng.freeImage(&rb.img);
        rb.internal = internal;
        rb.samples = 0;
        if (w == 0 or h == 0) return;
        rb.img = c.eng.newImage(@intCast(w), @intCast(h), fmt) orelse return c.fail(g.OUT_OF_MEMORY);
    }

    pub fn getRenderbufferParameter(c: *Context, target: u32, pname: u32) ?i32 {
        if (target != g.RENDERBUFFER) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        const rb = madeIn(Rb, &c.objs.rbs, c.rb) orelse {
            c.fail(g.INVALID_OPERATION);
            return null;
        };
        const chans: u32 = if (rb.img.live() and rb.img.format.renderable()) rb.img.format.channels() else 0;
        return switch (pname) {
            g.RENDERBUFFER_WIDTH => @intCast(rb.img.width),
            g.RENDERBUFFER_HEIGHT => @intCast(rb.img.height),
            g.RENDERBUFFER_INTERNAL_FORMAT => @bitCast(rb.internal),
            g.RENDERBUFFER_SAMPLES => @intCast(rb.samples),
            g.RENDERBUFFER_RED_SIZE, g.RENDERBUFFER_RED_SIZE + 1, g.RENDERBUFFER_RED_SIZE + 2, g.RENDERBUFFER_RED_SIZE + 3 => if (chans > pname - g.RENDERBUFFER_RED_SIZE) 8 else 0,
            g.RENDERBUFFER_RED_SIZE + 4 => if (rb.img.live() and hasDepth(rb.internal)) 24 else 0,
            g.RENDERBUFFER_STENCIL_SIZE => if (rb.img.live() and hasStencil(rb.internal)) 8 else 0,
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    pub fn deleteRenderbuffers(c: *Context, names: []const u32) void {
        for (names) |name| {
            const rb = madeIn(Rb, &c.objs.rbs, name) orelse {
                if (slotIn(Rb, &c.objs.rbs, name)) |s| s.named = false;
                continue;
            };
            if (c.rb == name) c.rb = 0;
            c.detachFromBound(.rb, name);
            rb.named = false;
            rb.made = false;
            if (rb.refs > 0) {
                rb.orphan = true;
            } else {
                c.eng.freeImage(&rb.img);
                rb.* = .{};
            }
        }
    }

    // ── Framebuffers ───────────────────────────────────────────────────────

    pub fn genFramebuffers(c: *Context, out: []u32) void {
        if (!genIn(Fbo, &c.fbos, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn isFramebuffer(c: *Context, name: u32) bool {
        return madeIn(Fbo, &c.fbos, name) != null;
    }

    pub fn bindFramebuffer(c: *Context, target: u32, name: u32) void {
        if (target != g.FRAMEBUFFER and target != g.READ_FRAMEBUFFER and target != g.DRAW_FRAMEBUFFER) return c.fail(g.INVALID_ENUM);
        if (name != 0 and makeIn(Fbo, &c.fbos, name) == null) return c.fail(g.OUT_OF_MEMORY);
        if (target != g.READ_FRAMEBUFFER) c.draw_fb = name;
        if (target != g.DRAW_FRAMEBUFFER) c.read_fb = name;
    }

    /// The framebuffer bound to `target`, by name; null with an error.
    fn fbTarget(c: *Context, target: u32) ?u32 {
        return switch (target) {
            g.FRAMEBUFFER, g.DRAW_FRAMEBUFFER => c.draw_fb,
            g.READ_FRAMEBUFFER => c.read_fb,
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    /// The attachment points `attachment` names in f (two for
    /// DEPTH_STENCIL_ATTACHMENT), or null with an error.
    fn points(c: *Context, f: *Fbo, attachment: u32) ?[2]?*Attach {
        if (attachment >= g.COLOR_ATTACHMENT0 and attachment < g.COLOR_ATTACHMENT0 + 32) {
            const i = attachment - g.COLOR_ATTACHMENT0;
            if (i >= MAX_COLOR) {
                c.fail(g.INVALID_OPERATION);
                return null;
            }
            return .{ &f.color[i], null };
        }
        return switch (attachment) {
            g.DEPTH_ATTACHMENT => .{ &f.depth, null },
            g.STENCIL_ATTACHMENT => .{ &f.stencil, null },
            g.DEPTH_STENCIL_ATTACHMENT => .{ &f.depth, &f.stencil },
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    fn refsOf(c: *Context, a: Attach) ?*u32 {
        return switch (a.kind) {
            .none => null,
            .tex => if (slotIn(Tex, &c.objs.tex, a.name)) |t| &t.refs else null,
            .rb => if (slotIn(Rb, &c.objs.rbs, a.name)) |r| &r.refs else null,
        };
    }

    /// `p` holds `a` from now on: the old object let go (freed, if it was
    /// deleted and nothing else holds it), the new one held.
    fn setAttach(c: *Context, p: *Attach, a: Attach) void {
        if (c.refsOf(a)) |n| n.* += 1;
        const old = p.*;
        p.* = a;
        const n = c.refsOf(old) orelse return;
        n.* -= 1;
        if (n.* != 0) return;
        switch (old.kind) {
            .none => {},
            .tex => {
                const t = slotIn(Tex, &c.objs.tex, old.name).?;
                if (t.orphan) c.dropTex(t);
            },
            .rb => {
                const r = slotIn(Rb, &c.objs.rbs, old.name).?;
                if (r.orphan) {
                    c.eng.freeImage(&r.img);
                    r.* = .{};
                }
            },
        }
    }

    fn detachAll(c: *Context, f: *Fbo) void {
        for (&f.color) |*p| c.setAttach(p, .{});
        c.setAttach(&f.depth, .{});
        c.setAttach(&f.stencil, .{});
    }

    /// Object `name` detached from the framebuffers bound here.
    fn detachFromBound(c: *Context, kind: Attach.Kind, name: u32) void {
        for ([2]u32{ c.draw_fb, c.read_fb }, 0..) |fb, i| {
            if (fb == 0 or (i == 1 and fb == c.draw_fb)) continue;
            const f = &c.fbos[fb - 1];
            for (&f.color) |*p| {
                if (p.kind == kind and p.name == name) c.setAttach(p, .{});
            }
            if (f.depth.kind == kind and f.depth.name == name) c.setAttach(&f.depth, .{});
            if (f.stencil.kind == kind and f.stencil.name == name) c.setAttach(&f.stencil, .{});
        }
    }

    pub fn framebufferTexture2D(c: *Context, target: u32, attachment: u32, textarget: u32, name: u32, level: i32) void {
        const fb = c.fbTarget(target) orelse return;
        if (fb == 0) return c.fail(g.INVALID_OPERATION);
        const pts = c.points(&c.fbos[fb - 1], attachment) orelse return;
        var a = Attach{};
        if (name != 0) {
            const cube = textarget >= g.TEXTURE_CUBE_MAP_POSITIVE_X and textarget <= g.TEXTURE_CUBE_MAP_NEGATIVE_Z;
            if (!cube and textarget != g.TEXTURE_2D) return c.fail(g.INVALID_ENUM);
            const t = madeIn(Tex, &c.objs.tex, name) orelse return c.fail(g.INVALID_OPERATION);
            if (t.target != (if (cube) g.TEXTURE_CUBE_MAP else g.TEXTURE_2D)) return c.fail(g.INVALID_OPERATION);
            if (level < 0 or level >= engine.MAX_LEVELS) return c.fail(g.INVALID_VALUE);
            a = .{ .kind = .tex, .name = name, .level = @intCast(level), .layer = if (cube) textarget - g.TEXTURE_CUBE_MAP_POSITIVE_X else 0, .face = if (cube) textarget else 0 };
        }
        for (pts) |p| {
            if (p) |x| c.setAttach(x, a);
        }
    }

    pub fn framebufferTextureLayer(c: *Context, target: u32, attachment: u32, name: u32, level: i32, layer: i32) void {
        const fb = c.fbTarget(target) orelse return;
        if (fb == 0) return c.fail(g.INVALID_OPERATION);
        const pts = c.points(&c.fbos[fb - 1], attachment) orelse return;
        var a = Attach{};
        if (name != 0) {
            const t = madeIn(Tex, &c.objs.tex, name) orelse return c.fail(g.INVALID_OPERATION);
            if (t.target != g.TEXTURE_3D and t.target != g.TEXTURE_2D_ARRAY) return c.fail(g.INVALID_OPERATION);
            if (level < 0 or level >= engine.MAX_LEVELS or layer < 0 or layer >= MAX_SIZE) return c.fail(g.INVALID_VALUE);
            a = .{ .kind = .tex, .name = name, .level = @intCast(level), .layer = @intCast(layer) };
        }
        for (pts) |p| {
            if (p) |x| c.setAttach(x, a);
        }
    }

    pub fn framebufferRenderbuffer(c: *Context, target: u32, attachment: u32, rbtarget: u32, name: u32) void {
        const fb = c.fbTarget(target) orelse return;
        if (rbtarget != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        if (fb == 0) return c.fail(g.INVALID_OPERATION);
        const pts = c.points(&c.fbos[fb - 1], attachment) orelse return;
        var a = Attach{};
        if (name != 0) {
            _ = madeIn(Rb, &c.objs.rbs, name) orelse return c.fail(g.INVALID_OPERATION);
            a = .{ .kind = .rb, .name = name };
        }
        for (pts) |p| {
            if (p) |x| c.setAttach(x, a);
        }
    }

    pub fn checkFramebufferStatus(c: *Context, target: u32) u32 {
        const fb = c.fbTarget(target) orelse return 0;
        return c.view(fb, target == g.READ_FRAMEBUFFER).status;
    }

    pub fn deleteFramebuffers(c: *Context, names: []const u32) void {
        for (names) |name| {
            const f = madeIn(Fbo, &c.fbos, name) orelse {
                if (slotIn(Fbo, &c.fbos, name)) |s| s.named = false;
                continue;
            };
            if (c.draw_fb == name) c.draw_fb = 0;
            if (c.read_fb == name) c.read_fb = 0;
            c.detachAll(f);
            f.* = .{};
        }
    }

    pub fn drawBuffers(c: *Context, bufs: []const u32) void {
        if (bufs.len > MAX_COLOR) return c.fail(g.INVALID_VALUE);
        if (c.draw_fb == 0) {
            if (bufs.len != 1 or (bufs[0] != g.BACK and bufs[0] != g.NONE)) return c.fail(g.INVALID_OPERATION);
            c.default_draw = bufs[0];
            return;
        }
        for (bufs, 0..) |b, i| {
            if (b != g.NONE and b != g.COLOR_ATTACHMENT0 + i) return c.fail(g.INVALID_OPERATION);
        }
        const f = &c.fbos[c.draw_fb - 1];
        for (&f.draw, 0..) |*d, i| d.* = if (i < bufs.len) bufs[i] else g.NONE;
    }

    pub fn readBuffer(c: *Context, src: u32) void {
        if (c.read_fb == 0) {
            if (src != g.BACK and src != g.NONE) return c.fail(g.INVALID_OPERATION);
            c.default_read = src;
            return;
        }
        if (src != g.NONE and (src < g.COLOR_ATTACHMENT0 or src >= g.COLOR_ATTACHMENT0 + MAX_COLOR)) return c.fail(g.INVALID_OPERATION);
        c.fbos[c.read_fb - 1].read = src;
    }

    /// glInvalidateFramebuffer: checked, then nothing (a hint the tiled
    /// rasterizer will use).
    pub fn invalidateFramebuffer(c: *Context, target: u32, attachments: []const u32) void {
        const fb = c.fbTarget(target) orelse return;
        for (attachments) |a| {
            const ok = if (fb == 0)
                a == g.COLOR or a == g.DEPTH or a == g.STENCIL
            else
                a == g.DEPTH_ATTACHMENT or a == g.STENCIL_ATTACHMENT or a == g.DEPTH_STENCIL_ATTACHMENT or
                    (a >= g.COLOR_ATTACHMENT0 and a < g.COLOR_ATTACHMENT0 + MAX_COLOR);
            if (!ok) return c.fail(if (fb != 0 and a >= g.COLOR_ATTACHMENT0 and a < g.COLOR_ATTACHMENT0 + 32) g.INVALID_OPERATION else g.INVALID_ENUM);
        }
    }

    // ── Vertex arrays ──────────────────────────────────────────────────────

    fn curVao(c: *Context) *Vao {
        return if (c.vao == 0) &c.vao0 else &c.vaos[c.vao - 1];
    }

    pub fn genVertexArrays(c: *Context, out: []u32) void {
        if (!genIn(Vao, &c.vaos, out)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn isVertexArray(c: *Context, name: u32) bool {
        return madeIn(Vao, &c.vaos, name) != null;
    }

    /// (ES 3.0: only names glGenVertexArrays gave)
    pub fn bindVertexArray(c: *Context, name: u32) void {
        if (name != 0) {
            const v = slotIn(Vao, &c.vaos, name) orelse return c.fail(g.INVALID_OPERATION);
            if (!v.named) return c.fail(g.INVALID_OPERATION);
            v.made = true;
        }
        c.vao = name;
    }

    pub fn deleteVertexArrays(c: *Context, names: []const u32) void {
        for (names) |name| {
            const v = slotIn(Vao, &c.vaos, name) orelse continue;
            if (!v.named) continue;
            if (c.vao == name) c.vao = 0;
            v.* = .{};
        }
    }

    fn attrIndex(c: *Context, index: u32) ?*VAttr {
        if (index >= MAX_ATTRS) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        return &c.curVao().attrs[index];
    }

    /// glVertexAttribPointer (integer: glVertexAttribIPointer).
    pub fn vertexAttribPointer(c: *Context, index: u32, size: i32, ty: u32, normalized: bool, stride: i32, pointer: usize, integer: bool) void {
        const a = c.attrIndex(index) orelse return;
        if (size < 1 or size > 4 or stride < 0 or stride > 2048) return c.fail(g.INVALID_VALUE);
        if (!knownAttrType(ty)) return c.fail(g.INVALID_ENUM);
        if (integer and (ty == g.FLOAT or ty == g.HALF_FLOAT or ty == g.FIXED or ty == 0x8D9F or ty == 0x8368)) return c.fail(g.INVALID_ENUM);
        // (a pointer into client memory: only without a vertex array object)
        if (c.bufs.array == 0 and pointer != 0 and c.vao != 0) return c.fail(g.INVALID_OPERATION);
        a.* = .{ .enabled = a.enabled, .divisor = a.divisor, .size = @intCast(size), .ty = ty, .normalized = normalized, .integer = integer, .stride = @intCast(stride), .offset = pointer, .buffer = c.bufs.array };
    }

    pub fn enableVertexAttribArray(c: *Context, index: u32, on: bool) void {
        const a = c.attrIndex(index) orelse return;
        a.enabled = on;
    }

    pub fn vertexAttribDivisor(c: *Context, index: u32, divisor: u32) void {
        const a = c.attrIndex(index) orelse return;
        a.divisor = divisor;
    }

    /// glVertexAttrib*: the value an attribute has where its array is off.
    pub fn vertexAttrib(c: *Context, index: u32, v: [4]u32, integer: bool) void {
        if (index >= MAX_ATTRS) return c.fail(g.INVALID_VALUE);
        c.generic[index] = v;
        c.generic_int[index] = integer;
        c.generic_unsigned[index] = false;
    }

    pub fn vertexAttribUnsigned(c: *Context, index: u32, v: [4]u32) void {
        if (index >= MAX_ATTRS) return c.fail(g.INVALID_VALUE);
        c.vertexAttrib(index, v, true);
        c.generic_unsigned[index] = true;
    }

    pub fn vertexAttribValues(c: *Context, comptime T: type, index: u32, pname: u32, out: [*]T) void {
        _ = c.attrIndex(index) orelse return;
        if (pname != g.CURRENT_VERTEX_ATTRIB) {
            const value = c.getVertexAttrib(index, pname) orelse return;
            out[0] = if (T == f32) @floatFromInt(value) else @bitCast(value);
            return;
        }
        for (c.generic[index], 0..) |bits, i| {
            if (c.generic_int[index]) {
                out[i] = if (T == f32)
                    (if (c.generic_unsigned[index]) @floatFromInt(bits) else @floatFromInt(@as(i32, @bitCast(bits))))
                else
                    @bitCast(bits);
            } else {
                const value: f32 = @bitCast(bits);
                if (T == f32) {
                    out[i] = value;
                } else {
                    const rounded = if (std.math.isNan(value)) 0 else @round(@as(f64, value));
                    out[i] = @intFromFloat(std.math.clamp(rounded, @as(f64, @floatFromInt(std.math.minInt(T))), @as(f64, @floatFromInt(std.math.maxInt(T)))));
                }
            }
        }
    }

    pub fn vertexAttribPointerValue(c: *Context, index: u32, pname: u32) ?usize {
        const attr = c.attrIndex(index) orelse return null;
        if (pname != g.VERTEX_ATTRIB_ARRAY_POINTER) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        return attr.offset;
    }

    pub fn getVertexAttrib(c: *Context, index: u32, pname: u32) ?i32 {
        const a = c.attrIndex(index) orelse return null;
        return switch (pname) {
            g.VERTEX_ATTRIB_ARRAY_ENABLED => @intFromBool(a.enabled),
            g.VERTEX_ATTRIB_ARRAY_SIZE => a.size,
            g.VERTEX_ATTRIB_ARRAY_STRIDE => @intCast(a.stride),
            g.VERTEX_ATTRIB_ARRAY_TYPE => @bitCast(a.ty),
            g.VERTEX_ATTRIB_ARRAY_NORMALIZED => @intFromBool(a.normalized),
            g.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING => @intCast(a.buffer),
            g.VERTEX_ATTRIB_ARRAY_INTEGER => @intFromBool(a.integer),
            g.VERTEX_ATTRIB_ARRAY_DIVISOR => @intCast(a.divisor),
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    // ── Draw state ─────────────────────────────────────────────────────────

    pub fn blendFunc(c: *Context, src_rgb: u32, dst_rgb: u32, src_a: u32, dst_a: u32) void {
        if (!validFactor(src_rgb) or !validFactor(dst_rgb) or !validFactor(src_a) or !validFactor(dst_a)) return c.fail(g.INVALID_ENUM);
        c.blend_src_rgb = src_rgb;
        c.blend_dst_rgb = dst_rgb;
        c.blend_src_a = src_a;
        c.blend_dst_a = dst_a;
    }

    pub fn blendEquation(c: *Context, rgb: u32, a: u32) void {
        if (equationOf(rgb) == null or equationOf(a) == null) return c.fail(g.INVALID_ENUM);
        c.blend_eq_rgb = rgb;
        c.blend_eq_a = a;
    }

    pub fn blendColor(c: *Context, r: f32, gr: f32, b: f32, a: f32) void {
        c.blend_color = .{ clamp01(r), clamp01(gr), clamp01(b), clamp01(a) };
    }

    pub fn depthFunc(c: *Context, func: u32) void {
        if (func < g.NEVER or func > g.ALWAYS) return c.fail(g.INVALID_ENUM);
        c.depth_func = func;
    }

    pub fn depthRange(c: *Context, n: f32, f_: f32) void {
        c.depth_range = .{ clamp01(n), clamp01(f_) };
    }

    pub fn cullFace(c: *Context, mode: u32) void {
        if (mode != g.FRONT and mode != g.BACK and mode != g.FRONT_AND_BACK) return c.fail(g.INVALID_ENUM);
        c.cull_mode = mode;
    }

    pub fn frontFace(c: *Context, mode: u32) void {
        if (mode != g.CW and mode != g.CCW) return c.fail(g.INVALID_ENUM);
        c.front_face = mode;
    }

    /// What draws run (the driver's own pipelines until GLSL programs).
    pub fn usePipeline(c: *Context, p: ?*raster.Pipeline, uniforms: []const u32) void {
        c.pipeline = p;
        c.uniforms = uniforms;
    }

    // ── Draws ──────────────────────────────────────────────────────────────

    pub fn drawArrays(c: *Context, mode: u32, first: i32, count: i32, instances: i32) void {
        if (first < 0) return c.fail(g.INVALID_VALUE);
        c.drawCall(mode, @intCast(first), count, 0, 0, instances);
    }

    pub fn drawElements(c: *Context, mode: u32, count: i32, ty: u32, offset: usize, instances: i32) void {
        if (ty != g.UNSIGNED_BYTE and ty != g.UNSIGNED_SHORT and ty != g.UNSIGNED_INT) return c.fail(g.INVALID_ENUM);
        c.drawCall(mode, 0, count, ty, offset, instances);
    }

    fn drawCall(c: *Context, mode: u32, first: u32, count: i32, index_ty: u32, offset: usize, instances: i32) void {
        const topology: ?raster.Topology = switch (mode) {
            g.TRIANGLES => .triangles,
            g.TRIANGLE_STRIP => .strip,
            g.TRIANGLE_FAN => .fan,
            // (points and lines: captured by transform feedback, not drawn yet)
            g.POINTS, g.LINES, g.LINE_LOOP, g.LINE_STRIP => null,
            else => return c.fail(g.INVALID_ENUM),
        };
        if (count < 0 or instances < 0) return c.fail(g.INVALID_VALUE);
        // transform feedback on: the begun mode's primitives, from arrays
        // (GL ES 3.0's rules)
        var xfb: ?*Feedback = null;
        if (c.feedbackOf()) |t| {
            if (t.active and !t.paused) xfb = t;
        }
        if (xfb) |t| {
            const same = switch (t.mode) {
                g.POINTS => mode == g.POINTS,
                g.LINES => mode == g.LINES,
                else => mode == g.TRIANGLES,
            };
            if (!same or index_ty != 0) return c.fail(g.INVALID_OPERATION);
        }
        const discard = c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0;
        if (xfb == null and (topology == null or discard)) return;
        var v = c.drawView() orelse return;
        // the program in use (its pipeline, its uniforms), else the driver's own
        var pipe: *raster.Pipeline = undefined;
        var uniforms: []const u32 = undefined;
        if (c.program != 0) {
            const ds = program.drawState(c) orelse return;
            pipe = ds.pipe;
            uniforms = ds.uniforms;
        } else {
            pipe = c.pipeline orelse return;
            uniforms = c.uniforms;
        }
        const color_or = v.color[0];
        if (color_or == null and xfb == null) return;
        if (count == 0 or instances == 0) return;
        // (a capture alone draws no pixel: any image stands for the color)
        const color = color_or orelse &c.eng.zero;
        var d = raster.Draw{ .pipe = pipe, .color = color, .topology = topology orelse .triangles, .first = first, .count = @intCast(count), .instances = @intCast(instances), .uniforms = uniforms };
        d.restart = c.enabled & bitOf(g.PRIMITIVE_RESTART_FIXED_INDEX) != 0;
        var sampled_mips: [texture.MAX_TEX]Image = @splat(.{});
        defer for (&sampled_mips) |*image| c.eng.freeImage(image);
        if (c.program != 0) {
            // the textures: each slot's image, its descriptor after the uniforms
            const ds = program.drawState(c) orelse return;
            const n = ds.uniforms.len;
            @memcpy(c.draw_words[0..n], ds.uniforms);
            // (the uniform blocks' members from their buffers)
            program.fillBlocks(c, c.draw_words[0..n]);
            for (ds.slots, 0..) |sl, i| {
                const st = c.slotState(sl, ds.uniforms, &sampled_mips[i]);
                texture.descriptor(st, c.draw_words[n + i * texture.DESC_WORDS ..][0..texture.DESC_WORDS]);
                d.textures[i] = st.img;
            }
            d.uniforms = c.draw_words[0 .. n + ds.slots.len * texture.DESC_WORDS];
        }
        // the attributes: arrays from buffers, else the generic values
        const va = c.curVao();
        for (0..pipe.shaders.attrs) |j| {
            const a = va.attrs[j];
            if (!a.enabled) {
                d.attrs[j] = .{ .constant = c.generic[j], .integer = c.generic_int[j] };
                continue;
            }
            // (arrays in client memory, divisors past 1, half floats and
            // packed types: not drawn yet)
            const b = madeIn(Buf, &c.objs.bufs, a.buffer) orelse return c.fail(g.INVALID_OPERATION);
            if (!b.store.live() and b.store.buf.cpu.len == 0) return c.fail(g.INVALID_OPERATION);
            if (!c.notMapped(b)) return;
            const t = attrType(a.ty) orelse return c.fail(g.INVALID_OPERATION);
            if (a.divisor > 1) return c.fail(g.INVALID_OPERATION);
            d.attrs[j] = .{
                .buf = &b.store,
                .offset = @intCast(a.offset),
                .stride = if (a.stride != 0) a.stride else @as(u32, a.size) * t.size,
                .comps = a.size,
                .size = t.size,
                .float = t.float,
                .signed = t.signed,
                .normalized = a.normalized,
                .integer = a.integer,
                .divisor = a.divisor,
            };
        }
        if (index_ty != 0) {
            const b = madeIn(Buf, &c.objs.bufs, va.element) orelse return c.fail(g.INVALID_OPERATION);
            if (b.store.buf.cpu.len == 0) return c.fail(g.INVALID_OPERATION);
            if (!c.notMapped(b)) return;
            d.index = &b.store;
            d.index_offset = @intCast(offset);
            d.index_size = switch (index_ty) {
                g.UNSIGNED_BYTE => 1,
                g.UNSIGNED_SHORT => 2,
                else => 4,
            };
        }
        if (xfb) |t| {
            if (!c.feedbackCapture(t, &d, mode)) return;
        }
        if (topology == null or discard or color_or == null) return;
        // an occlusion query: its word
        if (c.timerOf(c.occlusion)) |q| d.query = &q.word;
        // viewport and depth range
        const vp = c.viewport;
        const hw = @as(f32, @floatFromInt(vp[2])) / 2;
        const hh = @as(f32, @floatFromInt(vp[3])) / 2;
        d.half = .{ hw, hh };
        d.center = .{ @as(f32, @floatFromInt(vp[0])) + hw, @as(f32, @floatFromInt(vp[1])) + hh };
        const n = c.depth_range[0];
        const f_ = c.depth_range[1];
        d.depth_scale = (f_ - n) / 2;
        d.depth_bias = (f_ + n) / 2;
        d.zmin = @min(n, f_);
        d.zmax = @max(n, f_);
        // the pixels: the viewport, the framebuffer, the scissor
        const cap = struct {
            fn f(x: i64) u32 {
                return @intCast(std.math.clamp(x, 0, MAX_SIZE));
            }
        }.f;
        var rect = v.bounds().meet(.{ .x0 = cap(vp[0]), .y0 = cap(vp[1]), .x1 = cap(@as(i64, vp[0]) + vp[2]), .y1 = cap(@as(i64, vp[1]) + vp[3]) });
        if (c.enabled & bitOf(g.SCISSOR_TEST) != 0) rect = rect.meet(c.clearRect(&v));
        d.rect = rect;
        if (c.enabled & bitOf(g.CULL_FACE) != 0) d.cull = switch (c.cull_mode) {
            g.FRONT => 1,
            g.BACK => 2,
            else => 3,
        };
        d.front_ccw = c.front_face == g.CCW;
        if (c.enabled & bitOf(g.DEPTH_TEST) != 0) {
            if (v.depth) |dp| {
                d.depth = dp;
                d.depth_test = true;
                d.depth_func = @intCast(c.depth_func - g.NEVER);
                d.depth_write = c.depth_mask;
            }
        }
        if (c.enabled & bitOf(g.STENCIL_TEST) != 0) {
            d.stencil = v.stencil;
            d.stencil_front = c.stencil_front.draw(c.stencil_mask);
            d.stencil_back = c.stencil_back.draw(c.stencil_back_mask);
        }
        if (c.enabled & bitOf(g.BLEND) != 0) {
            const bc = c.blend_color;
            d.blend = .{
                .src_rgb = factorOf(c.blend_src_rgb, bc) orelse .{},
                .dst_rgb = factorOf(c.blend_dst_rgb, bc).?,
                .src_a = factorOf(c.blend_src_a, bc) orelse .{ .c = .{ 1, 1, 1, 1 } },
                .dst_a = factorOf(c.blend_dst_a, bc).?,
                .saturate = c.blend_src_rgb == g.SRC_ALPHA_SATURATE,
                .eq_rgb = equationOf(c.blend_eq_rgb).?,
                .eq_a = equationOf(c.blend_eq_a).?,
            };
        }
        d.keep = colorKeep(color.format, c.color_mask);
        c.usage.draw(index_ty != 0, d.instances, @as(u64, d.triangles()) * d.instances);
        if (!c.eng.draw(&d)) c.fail(g.OUT_OF_MEMORY);
    }

    pub fn getFramebufferAttachmentParameter(c: *Context, target: u32, attachment: u32, pname: u32) ?i32 {
        const fb = c.fbTarget(target) orelse return null;
        if (fb == 0) {
            if (attachment != g.BACK and attachment != g.DEPTH and attachment != g.STENCIL) {
                c.fail(g.INVALID_ENUM);
                return null;
            }
            return switch (pname) {
                g.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE => @intCast(g.FRAMEBUFFER_DEFAULT),
                else => 0,
            };
        }
        const pts = c.points(&c.fbos[fb - 1], attachment) orelse return null;
        const a = pts[0].?.*;
        return switch (pname) {
            g.FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE => switch (a.kind) {
                .none => @intCast(g.NONE),
                .tex => @intCast(g.TEXTURE),
                .rb => @intCast(g.RENDERBUFFER),
            },
            g.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME => @intCast(a.name),
            g.FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL => @intCast(a.level),
            g.FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER => @intCast(if (a.face == 0) a.layer else 0),
            g.FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE => @intCast(a.face),
            g.FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE => @intCast(g.UNSIGNED_NORMALIZED),
            g.FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING => @intCast(g.LINEAR),
            else => {
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }
};

/// A client pointer as a number (an offset into a bound pack or unpack
/// buffer).
fn addr(p: ?*const anyopaque) usize {
    return if (p) |x| @intFromPtr(x) else 0;
}

// ── Vertex arrays and draws ────────────────────────────────────────────────

/// A blend factor as raster's linear form (c + ks*s + kd*d + ksa*s.a +
/// kda*d.a), for RGB or alpha; null: not a factor (or SRC_ALPHA_SATURATE,
/// which the caller handles).
fn factorOf(e: u32, constant: [4]f32) ?raster.Factor {
    const ca = constant[3];
    return switch (e) {
        g.ZERO => .{},
        g.ONE => .{ .c = .{ 1, 1, 1, 1 } },
        g.SRC_COLOR => .{ .ks = 1 },
        g.ONE_MINUS_SRC_COLOR => .{ .c = .{ 1, 1, 1, 1 }, .ks = -1 },
        g.DST_COLOR => .{ .kd = 1 },
        g.ONE_MINUS_DST_COLOR => .{ .c = .{ 1, 1, 1, 1 }, .kd = -1 },
        g.SRC_ALPHA => .{ .ksa = 1 },
        g.ONE_MINUS_SRC_ALPHA => .{ .c = .{ 1, 1, 1, 1 }, .ksa = -1 },
        g.DST_ALPHA => .{ .kda = 1 },
        g.ONE_MINUS_DST_ALPHA => .{ .c = .{ 1, 1, 1, 1 }, .kda = -1 },
        g.CONSTANT_COLOR => .{ .c = constant },
        g.ONE_MINUS_CONSTANT_COLOR => .{ .c = .{ 1 - constant[0], 1 - constant[1], 1 - constant[2], 1 - constant[3] } },
        g.CONSTANT_ALPHA => .{ .c = .{ ca, ca, ca, ca } },
        g.ONE_MINUS_CONSTANT_ALPHA => .{ .c = .{ 1 - ca, 1 - ca, 1 - ca, 1 - ca } },
        else => null,
    };
}

fn validFactor(e: u32) bool {
    return e == g.SRC_ALPHA_SATURATE or factorOf(e, .{ 0, 0, 0, 0 }) != null;
}

fn equationOf(e: u32) ?raster.Equation {
    return switch (e) {
        g.FUNC_ADD => .add,
        g.FUNC_SUBTRACT => .subtract,
        g.FUNC_REVERSE_SUBTRACT => .reverse_subtract,
        g.MIN => .min,
        g.MAX => .max,
        else => null,
    };
}

/// An attribute type's bytes a component, and whether it is signed or a
/// float; null: not one draws take yet (HALF_FLOAT, FIXED, the packed ones).
fn attrType(ty: u32) ?struct { size: u8, signed: bool, float: bool } {
    return switch (ty) {
        g.BYTE => .{ .size = 1, .signed = true, .float = false },
        g.UNSIGNED_BYTE => .{ .size = 1, .signed = false, .float = false },
        g.SHORT => .{ .size = 2, .signed = true, .float = false },
        g.UNSIGNED_SHORT => .{ .size = 2, .signed = false, .float = false },
        g.INT => .{ .size = 4, .signed = true, .float = false },
        g.UNSIGNED_INT => .{ .size = 4, .signed = false, .float = false },
        g.FLOAT => .{ .size = 4, .signed = true, .float = true },
        else => null,
    };
}

fn knownAttrType(ty: u32) bool {
    return attrType(ty) != null or ty == g.HALF_FLOAT or ty == g.FIXED or ty == 0x8D9F or ty == 0x8368;
}

fn clamp01(x: f32) f32 {
    return if (x != x) 0 else std.math.clamp(x, 0, 1);
}

test "gles: float to unorm rounds to nearest even, as Mesa" {
    try std.testing.expectEqual(@as(u32, 0), unorm(0, 8));
    try std.testing.expectEqual(@as(u32, 255), unorm(1, 8));
    try std.testing.expectEqual(@as(u32, 128), unorm(0.5, 8)); // 127.5: to 128 (even)
    try std.testing.expectEqual(@as(u32, 0xff_ffff), unorm(1, 24));
    try std.testing.expectEqual(@as(u32, 0), unorm(std.math.nan(f32), 8));
    try std.testing.expectEqual(@as(u32, 0x8040_2010), packColor(.rgba8, .{ 16.0 / 255.0, 32.0 / 255.0, 64.0 / 255.0, 128.0 / 255.0 }));
    try std.testing.expectEqual(@as(u32, 0x8010_2040), packColor(.bgra8, .{ 16.0 / 255.0, 32.0 / 255.0, 64.0 / 255.0, 128.0 / 255.0 }));
    try std.testing.expectEqual(@as(u32, 0xff00_ff00), colorKeep(.rgba8, .{ true, false, true, false }));
    try std.testing.expectEqual(@as(u32, 0x00ff_0000), colorKeep(.bgra8, .{ false, true, true, true }));
}
