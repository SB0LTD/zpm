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
const engine = @import("engine.sig");
const report = @import("report.sig");
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
pub const MAX_VAOS = 256;
pub const MAX_SAMPLERS = 256;
pub const MAX_ATTRS = raster.MAX_ATTRS;

pub const VENDOR_STRING: [:0]const u8 = "Galaxy";
pub const VERSION_STRING: [:0]const u8 = "OpenGL ES 3.0 Galaxy 0.1";
pub const GLSL_STRING: [:0]const u8 = "OpenGL ES GLSL ES 3.00";
/// What GL_EXTENSIONS names: what the driver has (WebRender asks for
/// BGRA and external textures in ESSL 3.00; GLSL ES 1.00 programs for
/// derivatives and texture LOD; ES 2 apps for sized renderbuffers and
/// texture storage). The GLSL compiler's #extension takes the shading ones.
pub const EXTENSIONS = [_][:0]const u8{
    "GL_EXT_read_format_bgra",
    "GL_EXT_texture_format_BGRA8888",
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
    named: bool = false,
    made: bool = false,
    params: TexParams = .{},
};

pub const Tex = struct {
    named: bool = false,
    made: bool = false,
    /// deleted while attached somewhere: freed at the last detach
    orphan: bool = false,
    refs: u32 = 0,
    target: u32 = 0,
    img: Image = .{},
    internal: u32 = 0,
    levels: u32 = 0,
    /// the levels specified (bit l: level l), stored in img's chain
    defined: u16 = 0,
    immutable: bool = false,
    params: TexParams = .{},
    /// GL's R, G, B, A as the stored texel's channels (LUMINANCE ...),
    /// and sRGB
    fswz: [4]u3 = .{ 0, 1, 2, 3 },
    srgb: bool = false,
};

pub const Buf = struct {
    named: bool = false,
    made: bool = false,
    store: Image = .{},
    size: usize = 0,
    usage: u32 = g.STATIC_DRAW,
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

pub const Rb = struct {
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
pub const Sync = struct { used: bool = false, mark: u64 = 0 };

pub const Objects = struct {
    tex: [MAX_TEXTURES]Tex = undefined,
    bufs: [MAX_BUFFERS]Buf = undefined,
    rbs: [MAX_RENDERBUFFERS]Rb = undefined,
    samplers: [MAX_SAMPLERS]Smp = undefined,
    syncs: [MAX_SYNCS]Sync = undefined,
    /// contexts holding it
    users: u32 = 0,

    pub fn init(o: *Objects) void {
        for (&o.tex) |*t| t.* = .{};
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
        for (&o.bufs) |*b| eng.freeImage(&b.store);
        for (&o.rbs) |*b| eng.freeImage(&b.img);
        o.init();
    }
};

pub const Attach = struct {
    pub const Kind = enum(u8) { none, tex, rb };
    kind: Kind = .none,
    name: u32 = 0,
};

pub const Fbo = struct {
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
        g.RGBA8 => .rgba8,
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

pub const Context = struct {
    eng: *Engine,
    objs: *Objects,
    err: u32 = g.NO_ERROR,
    reset_told: bool = false,
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
    viewport: [4]i32 = .{ 0, 0, 0, 0 },
    scissor: [4]i32 = .{ 0, 0, 0, 0 },
    enabled: u32 = 1 << 3, // (DITHER is on at first)
    unit: u32 = 0,
    tex2d: [MAX_UNITS]u32 = [_]u32{0} ** MAX_UNITS,
    tex_ext: [MAX_UNITS]u32 = [_]u32{0} ** MAX_UNITS,
    /// texture 0 of TEXTURE_2D and of TEXTURE_EXTERNAL_OES (each context
    /// has its own)
    default_tex: Tex = .{ .named = true, .made = true, .target = g.TEXTURE_2D },
    default_ext: Tex = .{ .named = true, .made = true, .target = g.TEXTURE_EXTERNAL_OES, .params = .{ .min = g.LINEAR, .wrap_s = g.CLAMP_TO_EDGE, .wrap_t = g.CLAMP_TO_EDGE, .wrap_r = g.CLAMP_TO_EDGE } },
    bufs: BufBinds = .{},
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

    pub const Revalidate = struct {
        ctx: *anyopaque,
        f: *const fn (*anyopaque) void,
        stale: *const std.atomic.Value(bool),
    };

    /// A context in place over `eng`, holding `objs` (a new share group's,
    /// initialized by the caller, or another context's).
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
        if (c.err == g.NO_ERROR) c.err = e;
        report.say(.gl_error, "GL error 0x{x}", .{e});
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
                c.fail(g.INVALID_ENUM);
                return null;
            },
        };
    }

    pub fn getStringi(c: *Context, name: u32, index: u32) ?[*:0]const u8 {
        if (name != g.EXTENSIONS) {
            c.fail(g.INVALID_ENUM);
            return null;
        }
        if (index >= EXTENSIONS.len) {
            c.fail(g.INVALID_VALUE);
            return null;
        }
        return EXTENSIONS[index].ptr;
    }

    pub fn enable(c: *Context, cap: u32, on: bool) void {
        const b = capBit(cap) orelse return c.fail(g.INVALID_ENUM);
        const m = @as(u32, 1) << b;
        if (on) c.enabled |= m else c.enabled &= ~m;
    }

    pub fn isEnabled(c: *Context, cap: u32) bool {
        const b = capBit(cap) orelse {
            c.fail(g.INVALID_ENUM);
            return false;
        };
        return c.enabled & (@as(u32, 1) << b) != 0;
    }

    pub fn hint(c: *Context, target: u32, mode: u32) void {
        if (mode != g.DONT_CARE and mode != g.FASTEST and mode != g.NICEST) return c.fail(g.INVALID_ENUM);
        switch (target) {
            g.GENERATE_MIPMAP_HINT => c.hint_mipmap = mode,
            g.FRAGMENT_SHADER_DERIVATIVE_HINT => c.hint_derivative = mode,
            else => c.fail(g.INVALID_ENUM),
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
            else => c.fail(g.INVALID_ENUM),
        }
    }

    pub fn flush(c: *Context) void {
        c.eng.flush();
    }

    pub fn finish(c: *Context) void {
        c.eng.finish();
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
            g.VIEWPORT => ints(&.{ c.viewport[0], c.viewport[1], c.viewport[2], c.viewport[3] }),
            g.SCISSOR_BOX => ints(&.{ c.scissor[0], c.scissor[1], c.scissor[2], c.scissor[3] }),
            g.COLOR_CLEAR_VALUE => .{ .kind = .float, .n = 4, .f = c.clear_color, .normalized = true },
            g.DEPTH_CLEAR_VALUE => .{ .kind = .float, .f = .{ c.clear_depth, 0, 0, 0 }, .normalized = true },
            g.STENCIL_CLEAR_VALUE => int(c.clear_stencil),
            g.COLOR_WRITEMASK => .{ .kind = .boolean, .n = 4, .i = .{ @intFromBool(c.color_mask[0]), @intFromBool(c.color_mask[1]), @intFromBool(c.color_mask[2]), @intFromBool(c.color_mask[3]) } },
            g.DEPTH_WRITEMASK => boolean(c.depth_mask),
            g.STENCIL_WRITEMASK => int(c.stencil_mask),
            g.STENCIL_BACK_WRITEMASK => int(c.stencil_back_mask),
            g.MAX_TEXTURE_SIZE, g.MAX_RENDERBUFFER_SIZE => int(MAX_SIZE),
            g.MAX_VIEWPORT_DIMS => ints(&.{ MAX_SIZE, MAX_SIZE }),
            g.MAX_COLOR_ATTACHMENTS, g.MAX_DRAW_BUFFERS => int(MAX_COLOR),
            g.MAX_TEXTURE_IMAGE_UNITS => int(16),
            g.MAX_COMBINED_TEXTURE_IMAGE_UNITS => int(MAX_UNITS),
            g.MAX_SAMPLES => int(1),
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
        const v = c.get(pname) orelse return c.fail(g.INVALID_ENUM);
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
        const v = c.get(pname) orelse return c.fail(g.INVALID_ENUM);
        for (0..@min(v.n, out.len)) |i| {
            out[i] = switch (v.kind) {
                .int, .boolean => @floatFromInt(v.i[i]),
                .float => v.f[i],
            };
        }
    }

    pub fn getBooleans(c: *Context, pname: u32, out: []u8) void {
        const v = c.get(pname) orelse return c.fail(g.INVALID_ENUM);
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
    fn attached(c: *Context, a: Attach, want: enum { color, depth, stencil }) struct { img: ?*Image, ok: bool } {
        switch (a.kind) {
            .none => return .{ .img = null, .ok = true },
            .tex => {
                const t = slotIn(Tex, &c.objs.tex, a.name) orelse return .{ .img = null, .ok = false };
                if (!t.img.live()) return .{ .img = null, .ok = false };
                const ok = want == .color and t.img.format.renderable() and !t.srgb and renderableInternal(t.internal);
                return .{ .img = &t.img, .ok = ok };
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
        for (f.color, 0..) |a, i| {
            const x = c.attached(a, .color);
            if (!x.ok) bad = true;
            colors[i] = x.img;
        }
        const d = c.attached(f.depth, .depth);
        const s = c.attached(f.stencil, .stencil);
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
        else if (d.img != null and s.img != null and d.img.? != s.img.?)
            // (depth and stencil share one image here)
            g.FRAMEBUFFER_UNSUPPORTED
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
        if (target != g.TEXTURE_2D and target != g.TEXTURE_EXTERNAL_OES) return c.fail(g.INVALID_ENUM);
        if (name != 0) {
            const t = slotIn(Tex, &c.objs.tex, name) orelse return c.fail(g.OUT_OF_MEMORY);
            if (t.made and t.target != target) return c.fail(g.INVALID_OPERATION);
            const fresh = !t.made;
            const m = makeIn(Tex, &c.objs.tex, name) orelse return c.fail(g.OUT_OF_MEMORY);
            m.target = target;
            // (an external texture's defaults: linear, clamped)
            if (fresh and target == g.TEXTURE_EXTERNAL_OES) m.params = c.default_ext.params;
        }
        if (target == g.TEXTURE_2D) c.tex2d[c.unit] = name else c.tex_ext[c.unit] = name;
    }

    /// The texture bound to `target` (TEXTURE_2D or TEXTURE_EXTERNAL_OES)
    /// on the active unit.
    fn boundTex(c: *Context, target: u32) ?*Tex {
        const name = switch (target) {
            g.TEXTURE_2D => c.tex2d[c.unit],
            g.TEXTURE_EXTERNAL_OES => c.tex_ext[c.unit],
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
        c.eng.freeImage(&t.img);
        t.img = engine.alias(src);
        t.internal = if (src.format == .bgra8) g.BGRA8_EXT else g.RGBA8;
        t.levels = 1;
        t.defined = 1;
        t.fswz = .{ 0, 1, 2, 3 };
        t.srgb = false;
    }

    /// glEGLImageTargetRenderbufferStorageOES.
    pub fn eglImageTargetRenderbufferStorage(c: *Context, target: u32, image: ?*anyopaque) void {
        if (target != g.RENDERBUFFER) return c.fail(g.INVALID_ENUM);
        const rb = madeIn(Rb, &c.objs.rbs, c.rb) orelse return c.fail(g.INVALID_OPERATION);
        const resolve = egl_image orelse return c.fail(g.INVALID_OPERATION);
        const src = resolve(image) orelse return c.fail(g.INVALID_VALUE);
        c.eng.freeImage(&rb.img);
        rb.img = engine.alias(src);
        rb.internal = if (src.format == .bgra8) g.BGRA8_EXT else g.RGBA8;
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
            // (detached from the framebuffers bound here, as GL says)
            c.detachFromBound(.tex, name);
            t.named = false;
            t.made = false;
            if (t.refs > 0) {
                t.orphan = true;
            } else c.dropTex(t);
        }
    }

    fn dropTex(c: *Context, t: *Tex) void {
        c.eng.freeImage(&t.img);
        t.* = .{};
    }

    /// The texture's level 0 becomes w x h of `fmt` (none for 0 x 0); its
    /// other levels stay if its size and format do.
    fn defineTex(c: *Context, t: *Tex, w: u32, h: u32, fmt: Format, internal: u32) bool {
        if (t.img.live() and t.img.width == w and t.img.height == h and t.img.format == fmt) {
            t.internal = internal;
            t.defined |= 1;
            return true;
        }
        c.eng.freeImage(&t.img);
        t.internal = internal;
        t.levels = 1;
        t.defined = 0;
        if (w == 0 or h == 0) return true;
        t.img = c.eng.newImage(w, h, fmt) orelse {
            c.fail(g.OUT_OF_MEMORY);
            return false;
        };
        t.defined = 1;
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
        if (t.img.share != null or t.img.top_down) {
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
        const bpp: usize = img.format.bytes();
        for (0..h) |j| {
            const gy = y + @as(u32, @intCast(j));
            const mrow = if (level == 0) img.rowOf(gy) else gy;
            const off = img.level_at[level] + @as(usize, mrow) * img.levelStride(level) + @as(usize, x) * bpp;
            const len = @as(usize, w) * bpp;
            const dst = c.eng.hostView(img, off, len);
            texfmt.convert(up, src[j * row ..], dst, w);
            c.eng.wrote(img, off, len);
        }
    }

    /// glTexImage2D. A level past 0 is stored in the texture's chain when
    /// level 0 is there, of its format, and the level's size is level 0's
    /// halved; otherwise it is taken and not stored (a texture that needs
    /// it is incomplete).
    pub fn texImage2D(c: *Context, target: u32, level: i32, internal: i32, w: i32, h: i32, border: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        const t = c.boundTex2D(target) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or w < 0 or h < 0 or w > MAX_SIZE or h > MAX_SIZE or border != 0) return c.fail(g.INVALID_VALUE);
        const ifmt: u32 = @bitCast(internal);
        const up = switch (texfmt.upload(ifmt, format, ty)) {
            .ok => |x| x,
            .err => |e| return c.fail(e),
        };
        if (t.immutable) return c.fail(g.INVALID_OPERATION);
        const uw: u32 = @intCast(w);
        const uh: u32 = @intCast(h);
        const l: u32 = @intCast(level);
        if (l > 0) {
            const bit = @as(u16, 1) << @intCast(l);
            t.defined &= ~bit;
            const fits = t.img.live() and up.store == t.img.format and l < fullLevels(&t.img) and uw == t.img.levelWidth(l) and uh == t.img.levelHeight(l);
            if (!fits or t.img.share != null) return;
            if (!c.growChain(t, fullLevels(&t.img))) return;
            t.defined |= bit;
            const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
            c.uploadRows(&t.img, l, up, 0, 0, uw, uh, src.bytes, src.row);
            return;
        }
        if (!c.defineTex(t, uw, uh, up.store, ifmt)) return;
        t.fswz = up.swizzle;
        t.srgb = up.srgb;
        const src = c.unpackSource(pixels, uw, uh, up.client_bytes) orelse return;
        c.uploadRows(&t.img, 0, up, 0, 0, uw, uh, src.bytes, src.row);
    }

    pub fn texSubImage2D(c: *Context, target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, pixels: ?*const anyopaque) void {
        const t = c.boundTex2D(target) orelse return;
        if (level < 0 or level >= engine.MAX_LEVELS or x < 0 or y < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        const l: u32 = @intCast(level);
        if (l > 0 and t.defined & (@as(u16, 1) << @intCast(l)) == 0) return c.fail(g.INVALID_OPERATION);
        if (@as(i64, x) + w > t.img.levelWidth(l) or @as(i64, y) + h > t.img.levelHeight(l)) return c.fail(g.INVALID_VALUE);
        const up = texfmt.subUpload(t.img.format, format, ty) orelse return c.fail(if (texfmt.known(format, ty)) g.INVALID_OPERATION else g.INVALID_ENUM);
        if (w == 0 or h == 0) return;
        const src = c.unpackSource(pixels, @intCast(w), @intCast(h), up.client_bytes) orelse return;
        c.uploadRows(&t.img, l, up, @intCast(x), @intCast(y), @intCast(w), @intCast(h), src.bytes, src.row);
    }

    pub fn texStorage2D(c: *Context, target: u32, levels: i32, internal: u32, w: i32, h: i32) void {
        const t = c.boundTex2D(target) orelse return;
        if (levels < 1 or w < 1 or h < 1 or w > MAX_SIZE or h > MAX_SIZE) return c.fail(g.INVALID_VALUE);
        const up = texfmt.storage(internal) orelse return c.fail(g.INVALID_ENUM);
        const most = std.math.log2_int(u32, @intCast(@max(w, h))) + 1;
        if (levels > most) return c.fail(g.INVALID_OPERATION);
        if (t.immutable or t == &c.default_tex) return c.fail(g.INVALID_OPERATION);
        if (!c.defineTex(t, @intCast(w), @intCast(h), up.store, internal)) return;
        if (levels > 1 and !c.growChain(t, @intCast(levels))) return;
        t.fswz = up.swizzle;
        t.srgb = up.srgb;
        t.levels = @intCast(levels);
        t.defined = @intCast((@as(u32, 1) << @intCast(levels)) - 1);
        t.immutable = true;
    }

    /// glGenerateMipmap: the levels past the base, to the last a complete
    /// texture has (MAX_LEVEL, or the immutable texture's), made from the
    /// base (the engine's mip kernel: 2 x 2 texels averaged). Unorm
    /// textures of 1, 2 or 4 bytes a texel (what ES 3.0 lets filter and
    /// render); others INVALID_OPERATION.
    pub fn generateMipmap(c: *Context, target: u32) void {
        const t = c.boundTex2D(target) orelse return;
        if (!t.img.live()) return c.fail(g.INVALID_OPERATION);
        const base: u32 = @intCast(@max(t.params.base_level, 0));
        if (base >= engine.MAX_LEVELS or t.defined & (@as(u16, 1) << @intCast(base)) == 0) return c.fail(g.INVALID_OPERATION);
        if (!t.img.format.renderable()) return c.fail(g.INVALID_OPERATION);
        const full = fullLevels(&t.img);
        var last: u32 = @min(full - 1, @as(u32, @intCast(@max(t.params.max_level, 0))));
        if (t.immutable) last = @min(last, t.levels - 1);
        if (last <= base) return;
        if (!t.immutable and !c.growChain(t, full)) return;
        if (!c.eng.mipmap(&t.img, base, last)) return c.fail(g.OUT_OF_MEMORY);
        var l = base;
        while (l <= last) : (l += 1) t.defined |= @as(u16, 1) << @intCast(l);
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
    fn slotState(c: *Context, sl: program.Slot, values: []const u32) texture.State {
        if (sl.unsupported) return .{};
        const unit = values[sl.word];
        if (unit >= MAX_UNITS) return .{};
        const name = if (sl.external) c.tex_ext[unit] else c.tex2d[unit];
        const t: *Tex = if (name == 0) (if (sl.external) &c.default_ext else &c.default_tex) else (madeIn(Tex, &c.objs.tex, name) orelse return .{});
        if (!t.img.live()) return .{};
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
        if (base >= engine.MAX_LEVELS or t.defined & (@as(u16, 1) << @intCast(base)) == 0) return .{};
        var last = base;
        if (mip != .none) {
            const top = base + std.math.log2_int(u32, @max(t.img.levelWidth(base), t.img.levelHeight(base)));
            if (t.params.max_level < base) return .{};
            last = @min(top, @as(u32, @intCast(t.params.max_level)));
            if (t.immutable) last = @min(last, t.levels - 1);
            if (last >= t.img.levels) return .{};
            var l = base;
            while (l <= last) : (l += 1) {
                if (t.defined & (@as(u16, 1) << @intCast(l)) == 0) return .{};
            }
        }
        // GL's R, G, B, A as the stored channels: bgra8's bytes are B, G, R, A
        const order: [4]u3 = if (t.img.format == .bgra8) .{ 2, 1, 0, 3 } else .{ 0, 1, 2, 3 };
        var rgba: [4]u3 = undefined;
        for (t.fswz, 0..) |s, i| rgba[i] = if (s < 4) order[s] else s;
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
            .img = &t.img,
            .srgb = t.srgb,
            .swizzle = swz,
            .wrap_s = wrapOf(p.wrap_s),
            .wrap_t = wrapOf(p.wrap_t),
            .linear = p.mag == g.LINEAR,
            .min_linear = p.min == g.LINEAR or p.min == g.LINEAR_MIPMAP_NEAREST or p.min == g.LINEAR_MIPMAP_LINEAR,
            .mip = mip,
            .base = @intCast(base),
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

    pub fn copyTexSubImage2D(c: *Context, target: u32, level: i32, dx: i32, dy: i32, x: i32, y: i32, w: i32, h: i32) void {
        const t = c.boundTex2D(target) orelse return;
        if (level != 0 or dx < 0 or dy < 0 or w < 0 or h < 0) return c.fail(g.INVALID_VALUE);
        if (@as(i64, dx) + w > t.img.width or @as(i64, dy) + h > t.img.height) return c.fail(g.INVALID_VALUE);
        const s = c.readSource() orelse return;
        if (!copyable(s.img.format, t.img.format) or t.srgb or s.img == &t.img) return c.fail(g.INVALID_OPERATION);
        c.copyFrom(s.img, s.v, x, y, w, h, &t.img, dx, dy);
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
        const n: usize = @intCast(size);
        c.unmap(b);
        // (new storage: what the GPU may still read of the old goes once it is done)
        c.eng.freeImage(&b.store);
        b.size = 0;
        b.usage = usage;
        if (n == 0) return;
        b.store = c.eng.newBuffer(n) orelse return c.fail(g.OUT_OF_MEMORY);
        b.size = n;
        if (data) |p| c.eng.writeBytes(&b.store, 0, @as([*]const u8, @ptrCast(p))[0..n]);
    }

    pub fn bufferSubData(c: *Context, target: u32, offset: isize, size: isize, data: ?*const anyopaque) void {
        if (c.bindingOf(target) == null) return c.fail(g.INVALID_ENUM);
        if (offset < 0 or size < 0) return c.fail(g.INVALID_VALUE);
        const b = c.boundBuf(target) orelse return;
        const off: usize = @intCast(offset);
        const n: usize = @intCast(size);
        if (off > b.size or n > b.size - off) return c.fail(g.INVALID_VALUE);
        if (b.mapped()) return c.fail(g.INVALID_OPERATION);
        const p = data orelse return;
        c.eng.writeBytes(&b.store, off, @as([*]const u8, @ptrCast(p))[0..n]);
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
        if (offset < 0 or length < 0 or access & ~@as(u32, 0x3f) != 0) {
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
            (read and access & (MAP_INVALIDATE_RANGE | MAP_INVALIDATE_BUFFER | MAP_UNSYNCHRONIZED) != 0) or
            (access & MAP_FLUSH_EXPLICIT != 0 and !write);
        if (bad) {
            c.fail(g.INVALID_OPERATION);
            return null;
        }
        if (access & MAP_INVALIDATE_BUFFER != 0 and c.eng.busy(&b.store)) {
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
        if (!b.mapped()) return true;
        c.fail(g.INVALID_OPERATION);
        return false;
    }

    pub fn getBufferParameter(c: *Context, target: u32, pname: u32) ?i64 {
        const b = c.boundBuf(target) orelse return null;
        return switch (pname) {
            g.BUFFER_SIZE => @intCast(b.size),
            g.BUFFER_USAGE => b.usage,
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
            if (textarget != g.TEXTURE_2D) return c.fail(g.INVALID_ENUM);
            const t = madeIn(Tex, &c.objs.tex, name) orelse return c.fail(g.INVALID_OPERATION);
            if (t.target != g.TEXTURE_2D) return c.fail(g.INVALID_OPERATION);
            if (level != 0) return c.fail(g.INVALID_VALUE);
            a = .{ .kind = .tex, .name = name };
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
        const topology: raster.Topology = switch (mode) {
            g.TRIANGLES => .triangles,
            g.TRIANGLE_STRIP => .strip,
            g.TRIANGLE_FAN => .fan,
            // (points and lines: not drawn yet)
            g.POINTS, g.LINES, g.LINE_LOOP, g.LINE_STRIP => return,
            else => return c.fail(g.INVALID_ENUM),
        };
        if (count < 0 or instances < 0) return c.fail(g.INVALID_VALUE);
        var v = c.drawView() orelse return;
        if (c.enabled & bitOf(g.RASTERIZER_DISCARD) != 0) return;
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
        const color = v.color[0] orelse return;
        if (count == 0 or instances == 0) return;
        var d = raster.Draw{ .pipe = pipe, .color = color, .topology = topology, .first = first, .count = @intCast(count), .instances = @intCast(instances), .uniforms = uniforms };
        if (c.program != 0) {
            // the textures: each slot's image, its descriptor after the uniforms
            const ds = program.drawState(c) orelse return;
            const n = ds.uniforms.len;
            @memcpy(c.draw_words[0..n], ds.uniforms);
            for (ds.slots, 0..) |sl, i| {
                const st = c.slotState(sl, ds.uniforms);
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
            g.FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL => 0,
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
