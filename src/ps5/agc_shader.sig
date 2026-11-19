//! @zpm/ps5 agc_shader — libSceAgc's shader calls: a shader object as a
//! game holds it, the call that makes one usable, and the calls that work
//! out the registers linking a vertex-side shader to a pixel shader
//! (agc.sig has the library's table). Allocation-free.
//!
//! A game's shader is two things it loaded itself: a header (`Shader`,
//! with tables after it: registers to set, what the shader reads and
//! writes, where its resources are) and the machine code. The header's
//! pointers are offsets in the file, each from its own field.
//! `sceAgcCreateShader` turns them into addresses, writes the code's
//! address into the header's own register list (the pair a game later
//! puts in a command buffer), and lists the shader here under that
//! address: a renderer finds a draw's shaders by what the program
//! registers hold (`byCode`).
//!
//! The header stays the game's memory. It is read again whenever its
//! shader is looked up, as the GPU reads the register lists in it when a
//! buffer runs: a game keeps it for as long as it draws with the shader.
//!
//! Not here: joining two halves of a shader (`sceAgcFuseShaderHalves`),
//! and the versioned twins of the interpolant calls, whose NIDs are not
//! in the public list.
//!
//! No Sony code: the structures and what each call writes are as open
//! projects document them (AnyPS5 and Kyty, which declare the same
//! structures). x86-64 only.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.sig");
const abi = @import("abi.sig");
const pthread = @import("pthread.sig");
const core = @import("agc_buffer.sig");

pub const ShaderRegister = core.ShaderRegister;

/// A register list in a game's memory (any alignment: a file's layout).
pub const Registers = [*]align(1) ShaderRegister;

// ── Numbers and structures ──────────────────────────────────────────────────

pub const MAGIC: u32 = 0x3433_3231;
pub const VERSION: u32 = 0x18;

/// The answer to a shader that is not one, or does not fit the call.
pub const INVALID_SHADER: i32 = @bitCast(@as(u32, 0x8A6C_0005));

/// What a shader is for (`Shader.type`).
pub const TYPE = struct {
    pub const COMPUTE: u8 = 0;
    pub const PIXEL: u8 = 1;
    /// The vertex side: the PS5 has no plain vertex shader, only this
    /// merged one (AMD's "NGG").
    pub const VERTEX: u8 = 2;
    pub const HULL: u8 = 3;
    pub const VERTEX_FRONT: u8 = 4;
    pub const HULL_FRONT: u8 = 5;
    pub const VERTEX_BACK: u8 = 6;
    pub const HULL_BACK: u8 = 7;
    pub const FETCH: u8 = 8;
    pub const LAST: u8 = 8;

    /// The shader register (SH bank) that holds the low word of a
    /// shader's code address; the high word is the next one. Null for the
    /// halves and the fetch routine, which no register points at.
    pub fn programRegister(t: u8) ?u32 {
        return switch (t) {
            COMPUTE => 0x20C,
            PIXEL => 0x008,
            VERTEX => 0x0C8,
            HULL => 0x148,
            VERTEX_BACK => 0x088,
            HULL_BACK => 0x108,
            else => null,
        };
    }
};

/// Register numbers the calls here write (each in its own bank).
pub const REG = struct {
    /// Context: which input of the pixel shader comes from which output
    /// of the vertex side, thirty-two of them.
    pub const PS_INPUT_CNTL_0: u32 = 0x191;
    pub const GS_OUT_PRIM_TYPE: u32 = 0x29B;
    pub const SHADER_STAGES_EN: u32 = 0x2D5;
    /// User configuration.
    pub const PRIMITIVE_TYPE: u32 = 0x242;
    pub const GE_CNTL: u32 = 0x25B;
    pub const GE_PC_ALLOC: u32 = 0x260;
    pub const GE_USER_VGPR_EN: u32 = 0x262;
    /// Shader.
    pub const PGM_RSRC4_GS: u32 = 0x081;
};

/// Bits of the stages register.
pub const STAGES = struct {
    pub const HULL: u32 = 0x04;
    pub const GEOMETRY: u32 = 0x20;
    /// The vertex side, then the hull side, runs 32 lanes wide, not 64.
    pub const HULL_WAVE32: u32 = 1 << 21;
    pub const VERTEX_WAVE32: u32 = 1 << 22;
};

/// What a draw's vertices make (`VGT_PRIMITIVE_TYPE`).
pub const PRIMITIVE = struct {
    pub const NONE: u32 = 0;
    pub const POINTS: u32 = 1;
    pub const LINES: u32 = 2;
    pub const LINE_STRIP: u32 = 3;
    pub const TRIANGLES: u32 = 4;
    pub const TRIANGLE_FAN: u32 = 5;
    pub const TRIANGLE_STRIP: u32 = 6;
    pub const RECTANGLES: u32 = 7;
    pub const PATCHES: u32 = 9;
    pub const LINES_ADJACENT: u32 = 10;
    pub const LINE_STRIP_ADJACENT: u32 = 11;
    pub const TRIANGLES_ADJACENT: u32 = 12;
    pub const TRIANGLE_STRIP_ADJACENT: u32 = 13;
    pub const RECTANGLES_OLD: u32 = 17;
    pub const LINE_LOOP: u32 = 18;
    pub const QUADS: u32 = 19;
    pub const QUAD_STRIP: u32 = 20;
    pub const POLYGON: u32 = 21;

    /// What the rasteriser is handed for it (`VGT_GS_OUT_PRIM_TYPE`:
    /// 0 points, 1 lines, 2 triangles, 3 and 4 the two rectangles). Null:
    /// no such kind.
    pub fn rasterised(kind: u32) ?u32 {
        return switch (kind) {
            POINTS => 0,
            LINES, LINE_STRIP, LINES_ADJACENT, LINE_STRIP_ADJACENT, LINE_LOOP => 1,
            RECTANGLES => 3,
            RECTANGLES_OLD => 4,
            NONE, TRIANGLES, TRIANGLE_FAN, TRIANGLE_STRIP, PATCHES, TRIANGLES_ADJACENT, TRIANGLE_STRIP_ADJACENT, QUADS, QUAD_STRIP, POLYGON => 2,
            else => null,
        };
    }
};

/// One thing a shader reads or writes: an input of the vertex side (a
/// vertex attribute), or a value passed from the vertex side to the pixel
/// shader.
pub const Semantic = packed struct(u32) {
    /// What it is. For a vertex input, the entry of the attribute table.
    semantic: u8 = 0,
    /// Vertex input: the first register it is loaded into. Vertex output:
    /// the slot it is written to.
    hardware_mapping: u8 = 0,
    size_in_elements: u4 = 0,
    /// Bit 0: the low 16-bit half is used; bit 1: the high half. 0 is a
    /// full 32-bit value.
    is_f16: u2 = 0,
    is_flat_shaded: bool = false,
    is_linear: bool = false,
    is_custom: bool = false,
    static_vb_index: bool = false,
    static_attribute: bool = false,
    reserved: u1 = 0,
    /// What the pixel shader reads when nothing wrote it: 0 (0,0,0,0),
    /// 1 (0,0,0,1), 2 (1,1,1,0), 3 (1,1,1,1).
    default_value: u2 = 0,
    default_value_hi: u2 = 0,
};

/// Registers a shader brings that are not in its lists: a game's calls
/// (`sceAgcCreatePrimState`) put them where they go.
pub const Specials = extern struct {
    ge_cntl: ShaderRegister = .{ .offset = REG.GE_CNTL, .value = 0 },
    stages: ShaderRegister = .{ .offset = REG.SHADER_STAGES_EN, .value = 0 },
    dispatch_modifier: u32 = 0,
    user_data_range: [2]u16 = .{ 0, 0 },
    draw_modifier: [2]u32 = .{ 0, 0 },
    out_primitive: ShaderRegister = .{ .offset = REG.GS_OUT_PRIM_TYPE, .value = 0 },
    user_vgpr_en: ShaderRegister = .{ .offset = REG.GE_USER_VGPR_EN, .value = 0 },
};

/// The kinds of resource a shader finds through a user-data register
/// (`UserData.direct`): the entry for a kind is the register's number.
pub const DIRECT = struct {
    pub const RESOURCE_TABLE: u16 = 1;
    pub const FETCH_ROUTINE: u16 = 2;
    pub const EXTENDED_USER_DATA: u16 = 5;
    /// A table of buffer descriptors, one a vertex buffer.
    pub const VERTEX_BUFFERS: u16 = 8;
    /// A table of words, one a vertex attribute (`Semantic.semantic` is
    /// its index).
    pub const VERTEX_ATTRIBUTES: u16 = 10;
    pub const KINDS: u16 = 11;
    pub const ABSENT: u16 = 0xFFFF;
};

/// One texture, sampler or buffer a shader names: where its descriptor
/// starts in the user data (in words), and bit 15 for the short kind.
pub const Sharp = packed struct(u16) {
    offset_dw: u15 = 0,
    short: bool = false,

    pub const UNUSED: u15 = 0x7FFF;
};

/// Where a shader's resources are.
pub const UserData = extern struct {
    /// u16[direct_count], by `DIRECT`.
    direct: usize = 0,
    /// Sharp[sharp_count[c]] for each of four classes.
    sharps: [4]usize = .{ 0, 0, 0, 0 },
    extended_dw: u16 = 0,
    resource_table_dw: u16 = 0,
    direct_count: u16 = 0,
    sharp_count: [4]u16 = .{ 0, 0, 0, 0 },

    /// The user-data register that holds a resource of `kind`.
    pub fn directOf(u: *align(1) const UserData, kind: u16) ?u16 {
        if (u.direct == 0 or kind >= u.direct_count) return null;
        const list: [*]align(1) const u16 = @ptrFromInt(u.direct);
        return if (list[kind] == DIRECT.ABSENT) null else list[kind];
    }
};

/// A shader's header. The seven pointers are, in a file, offsets from
/// their own fields (0: none); after `sceAgcCreateShader`, addresses.
pub const Shader = extern struct {
    magic: u32 = MAGIC,
    version: u32 = VERSION,
    user_data: usize = 0,
    /// 0 in a file: where the code is, once created.
    code: usize = 0,
    cx_registers: usize = 0,
    sh_registers: usize = 0,
    specials: usize = 0,
    input_semantics: usize = 0,
    output_semantics: usize = 0,
    header_size: u32 = 0,
    /// The code's length, in bytes.
    shader_size: u32 = 0,
    /// Constants after the code, in 16-byte units.
    embedded_constants_dqw: u32 = 0,
    target: u32 = 0,
    num_input_semantics: u32 = 0,
    scratch_dw_per_thread: u16 = 0,
    num_output_semantics: u16 = 0,
    specials_bytes: u16 = 0,
    type: u8 = 0,
    num_cx_registers: u8 = 0,
    num_sh_registers: u8 = 0,

    fn list(comptime T: type, at: usize, n: usize) []align(1) T {
        if (at == 0) return &.{};
        const p: [*]align(1) T = @ptrFromInt(at);
        return p[0..n];
    }

    /// The registers to set for this shader, shader bank then context.
    pub fn sh(s: *const Shader) []align(1) ShaderRegister {
        return list(ShaderRegister, s.sh_registers, s.num_sh_registers);
    }
    pub fn cx(s: *const Shader) []align(1) ShaderRegister {
        return list(ShaderRegister, s.cx_registers, s.num_cx_registers);
    }
    pub fn inputs(s: *const Shader) []align(1) const Semantic {
        return list(Semantic, s.input_semantics, s.num_input_semantics);
    }
    pub fn outputs(s: *const Shader) []align(1) const Semantic {
        return list(Semantic, s.output_semantics, s.num_output_semantics);
    }
    pub fn special(s: *const Shader) ?*align(1) const Specials {
        return if (s.specials == 0) null else @ptrFromInt(s.specials);
    }
    pub fn user(s: *const Shader) ?*align(1) const UserData {
        return if (s.user_data == 0) null else @ptrFromInt(s.user_data);
    }

    /// The code, as words.
    pub fn words(s: *const Shader) []align(1) const u32 {
        return list(u32, s.code, s.shader_size / 4);
    }

    /// The output with a semantic's number.
    pub fn output(s: *const Shader, semantic: u8) ?Semantic {
        for (s.outputs()) |o| {
            if (o.semantic == semantic) return o;
        }
        return null;
    }
};

comptime {
    std.debug.assert(@sizeOf(Shader) == 0x60);
    std.debug.assert(@offsetOf(Shader, "header_size") == 0x40);
    std.debug.assert(@offsetOf(Shader, "type") == 0x5A);
    std.debug.assert(@sizeOf(UserData) == 0x38);
    std.debug.assert(@offsetOf(UserData, "direct_count") == 0x2C);
    std.debug.assert(@sizeOf(Specials) == 0x30);
    std.debug.assert(@offsetOf(Specials, "out_primitive") == 0x20);
    std.debug.assert(@sizeOf(Semantic) == 4);
}

/// A shader a game passes to a call: one that was created. Null when it is
/// none, or not a header, or still a file's image (its pointers offsets),
/// or not at a multiple of eight bytes (a header is a structure with
/// pointers in it: a compiler puts it nowhere else).
fn created(p: ?*const anyopaque) ?*const Shader {
    const at = @intFromPtr(p orelse return null);
    if ((at & 7) != 0) return null;
    const s: *const Shader = @ptrFromInt(at);
    if (s.magic != MAGIC or s.version != VERSION or s.code == 0) return null;
    return s;
}

// ── The shaders a game has made ─────────────────────────────────────────────

/// Created shaders by the address their code runs at. Open addressing in
/// a fixed table. An address is never taken out (the library has no call
/// that destroys a shader): a shader made at one takes the old one's
/// place, and a shader made again somewhere else leaves its old address
/// with nothing at it.
const made = struct {
    const SLOTS = 1 << 14;
    /// (more than this and lookups get long: a game with more shaders is
    /// told once, and the rest are still created, only not found)
    const MOST = SLOTS / 4 * 3;

    var lock: pthread.Lock = .{};
    var keys: [SLOTS]u64 = [_]u64{0} ** SLOTS;
    var values: [SLOTS]usize = [_]usize{0} ** SLOTS;
    var count: u32 = 0;
    var told: bool = false;

    fn slot(address: u64) usize {
        // (code is 256-byte aligned: the low byte says nothing)
        return @intCast(((address >> 8) *% 0x9E37_79B9_7F4A_7C15) >> (64 - 14));
    }

    fn put(address: u64, s: *const Shader) void {
        lock.lock();
        defer lock.unlock();
        var i = slot(address);
        while (keys[i] != 0 and keys[i] != address) i = (i + 1) & (SLOTS - 1);
        if (keys[i] == 0) {
            if (count >= MOST) {
                if (!told) say("more shaders than the list holds: the rest will not be found by a renderer");
                told = true;
                return;
            }
            @atomicStore(u32, &count, count + 1, .monotonic);
            keys[i] = address;
        }
        values[i] = @intFromPtr(s);
    }

    /// `s` is no longer at `address` (if it is what is listed there).
    fn drop(address: u64, s: *const Shader) void {
        if (address == 0) return;
        lock.lock();
        defer lock.unlock();
        var i = slot(address);
        while (keys[i] != 0) : (i = (i + 1) & (SLOTS - 1)) {
            if (keys[i] != address) continue;
            if (values[i] == @intFromPtr(s)) values[i] = 0;
            return;
        }
    }

    fn get(address: u64) ?*const Shader {
        if (address == 0) return null;
        lock.lock();
        defer lock.unlock();
        var i = slot(address);
        while (keys[i] != 0) : (i = (i + 1) & (SLOTS - 1)) {
            if (keys[i] == address) return if (values[i] == 0) null else @ptrFromInt(values[i]);
        }
        return null;
    }
};

/// The shader whose code runs at `address` (what a pair of program
/// registers holds: `programAddress`), if a game created one there.
pub fn byCode(address: u64) ?*const Shader {
    return made.get(address);
}

/// How many shaders are listed.
pub fn listed() u32 {
    return @atomicLoad(u32, &made.count, .monotonic);
}

/// The address a pair of program registers holds: the low register is
/// the address without its low byte, the high one's low byte is bits 40
/// to 47.
pub fn programAddress(lo: u32, hi: u32) u64 {
    return (@as(u64, lo) << 8) | (@as(u64, hi & 0xFF) << 40);
}

fn say(comptime text: []const u8) void {
    // (a test's host is not this kernel)
    if (builtin.is_test) return;
    const msg = "[ps5] agc: " ++ text ++ "\n";
    _ = sys.call(abi.Sys.write, 2, @intFromPtr(msg.ptr), msg.len, 0, 0, 0);
}

// ── Making a shader ─────────────────────────────────────────────────────────

/// A pointer field of a file's image as an address: its value from its
/// own place. 0 stays none.
fn resolved(field: *align(1) const usize) usize {
    return if (field.* == 0) 0 else field.* +% @intFromPtr(field);
}

/// `sceAgcCreateShader(dst, header, code)`: a header and its code made
/// one shader. `*dst` is the header. Refused (`INVALID_SHADER`, nothing
/// changed): what is not a header of this version, code not at a multiple
/// of 256 bytes below 2^48, a length that is 0 or not whole words, a
/// shader that needs a program register and does not list the pair.
///
/// A header created before (its `code` not 0) keeps its tables and has
/// its program register moved by as much as the code moved.
pub fn sceAgcCreateShader(dst: ?*align(1) usize, header: ?*anyopaque, code: ?*const anyopaque) callconv(.c) i32 {
    const out = dst orelse return INVALID_SHADER;
    const at = @intFromPtr(header orelse return INVALID_SHADER);
    const base: u64 = @intFromPtr(code orelse return INVALID_SHADER);
    if ((at & 7) != 0) return INVALID_SHADER;
    const h: *Shader = @ptrFromInt(at);

    if (h.magic != MAGIC or h.version != VERSION) return INVALID_SHADER;
    if ((base & 0xFFFF_0000_0000_00FF) != 0) return INVALID_SHADER;
    if (h.shader_size == 0 or (h.shader_size & 3) != 0) return INVALID_SHADER;
    if (h.type > TYPE.LAST) return INVALID_SHADER;

    // Everything that can refuse comes before the first write: the pair of
    // program registers is looked for where the list will be.
    const fresh = h.code == 0;
    const previous: u64 = h.code;
    const sh_at = if (fresh) resolved(&h.sh_registers) else h.sh_registers;
    var program: u64 = base;
    var was_at: u64 = previous;
    var pair: ?[*]align(1) ShaderRegister = null;
    if (TYPE.programRegister(h.type)) |lo| {
        if (sh_at == 0) return INVALID_SHADER;
        const regs: [*]align(1) ShaderRegister = @ptrFromInt(sh_at);
        const n: usize = h.num_sh_registers;
        var i: usize = 0;
        while (i < n and regs[i].offset != lo) i += 1;
        if (i + 1 >= n or regs[i + 1].offset != lo + 1) return INVALID_SHADER;
        // (what the pair holds already is an offset into the code: from
        // nothing in a file, from the old address in a shader made before)
        const held = programAddress(regs[i].value, regs[i + 1].value);
        if (held < previous) return INVALID_SHADER;
        const within = held - previous;
        if (within > 0xFFFF_FFFF_FFFF - base) return INVALID_SHADER;
        program = base + within;
        was_at = held;
        pair = regs + i;
    }

    if (fresh) {
        h.cx_registers = resolved(&h.cx_registers);
        h.sh_registers = sh_at;
        h.user_data = resolved(&h.user_data);
        h.specials = resolved(&h.specials);
        h.input_semantics = resolved(&h.input_semantics);
        h.output_semantics = resolved(&h.output_semantics);
        if (h.user_data != 0) {
            const u: *align(1) UserData = @ptrFromInt(h.user_data);
            u.direct = resolved(&u.direct);
            for (&u.sharps) |*s| s.* = resolved(s);
        }
    }
    h.code = @intCast(base);
    if (pair) |p| {
        p[0].value = @truncate(program >> 8);
        p[1].value = (p[1].value & 0xFFFF_FF00) | @as(u32, @truncate((program >> 40) & 0xFF));
    }
    if (!fresh and was_at != program) made.drop(was_at, h);
    made.put(program, h);
    out.* = at;
    return 0;
}

// ── The primitive state ─────────────────────────────────────────────────────

/// What `sceAgcCreatePrimState` writes: two context registers and three
/// of user configuration.
const PrimState = struct {
    cx: [2]ShaderRegister,
    uc: [3]ShaderRegister,
};

/// The registers that say which stages run and what they hand the
/// rasteriser, from a vertex-side shader, a hull shader if there is one,
/// and the kind of primitive drawn. Null: shaders of the wrong kind or
/// without their special registers, or no such primitive.
fn primState(hs: ?*const Shader, gs: *const Shader, kind: u32) ?PrimState {
    const from_kind = PRIMITIVE.rasterised(kind) orelse return null;
    if (gs.type != TYPE.VERTEX) return null;
    const g = gs.special() orelse return null;
    if (g.stages.offset != REG.SHADER_STAGES_EN or g.ge_cntl.offset != REG.GE_CNTL) return null;
    var hull: ?*align(1) const Specials = null;
    if (hs) |h| {
        if (h.type != TYPE.HULL) return null;
        hull = h.special() orelse return null;
        if (hull.?.stages.offset != REG.SHADER_STAGES_EN) return null;
    }

    var stages = g.stages;
    if (hull) |h| stages.value |= h.stages.value;
    // What reaches the rasteriser is the geometry stage's to say when it
    // runs, else the hull shader's, else it follows from the primitive.
    var out: ShaderRegister = .{ .offset = REG.GS_OUT_PRIM_TYPE, .value = from_kind };
    if ((stages.value & STAGES.GEOMETRY) != 0) {
        if (g.out_primitive.offset != REG.GS_OUT_PRIM_TYPE) return null;
        out = g.out_primitive;
    } else if (hull) |h| {
        if (h.out_primitive.offset != REG.GS_OUT_PRIM_TYPE) return null;
        out = h.out_primitive;
    }
    return .{
        .cx = .{ stages, out },
        .uc = .{ g.ge_cntl, if (hull) |h| h.user_vgpr_en else g.user_vgpr_en, .{ .offset = REG.PRIMITIVE_TYPE, .value = kind } },
    };
}

/// `sceAgcCreatePrimState(cx, uc, hs, gs, kind)`: two context registers
/// to `cx` and three of user configuration to `uc` (either may be null).
pub fn sceAgcCreatePrimState(cx: ?Registers, uc: ?Registers, hs: ?*const anyopaque, gs: ?*const anyopaque, kind: u32) callconv(.c) i32 {
    if (cx == null and uc == null) return 0;
    const g = created(gs) orelse return INVALID_SHADER;
    var hull: ?*const Shader = null;
    if (hs != null) hull = created(hs) orelse return INVALID_SHADER;
    const state = primState(hull, g, kind) orelse return INVALID_SHADER;
    if (cx) |to| @memcpy(to[0..2], &state.cx);
    if (uc) |to| @memcpy(to[0..3], &state.uc);
    return 0;
}

/// `sceAgcUpdatePrimState(cx, uc, kind)`: the same registers for another
/// kind of primitive. What reaches the rasteriser changes only when
/// neither a geometry stage nor a hull shader says it; only then does a
/// kind there is no primitive of matter, and it is refused with nothing
/// written.
pub fn sceAgcUpdatePrimState(cx: ?Registers, uc: ?Registers, kind: u32) callconv(.c) i32 {
    if (cx) |c| {
        if ((c[0].value & (STAGES.GEOMETRY | STAGES.HULL)) == 0) {
            const from_kind = PRIMITIVE.rasterised(kind) orelse return INVALID_SHADER;
            c[1].value = (c[1].value & ~@as(u32, 7)) | from_kind;
        }
    }
    if (uc) |u| u[2].value = (u[2].value & ~@as(u32, 0x1F)) | kind;
    return 0;
}

// ── Interpolants ────────────────────────────────────────────────────────────

/// Bits of a pixel-input register.
pub const INPUT = struct {
    /// The vertex side's output slot it reads.
    pub const SLOT: u32 = 0x1F;
    /// It reads the default value, not a slot.
    pub const DEFAULT: u32 = 1 << 5;
    pub const DEFAULT_VALUE_SHIFT = 8;
    /// One vertex's value for the whole primitive. With `DEFAULT` too:
    /// each vertex's own value, not interpolated.
    pub const FLAT: u32 = 1 << 10;
    /// Two 16-bit halves, each with its own validity and default.
    pub const HALVES: u32 = 1 << 19;
    pub const DEFAULT_HIGH: u32 = 1 << 20;
    pub const DEFAULT_HIGH_VALUE_SHIFT = 21;
    pub const HALF_VALID_SHIFT = 24;
    pub const COUNT = 32;
};

/// The register for a pixel shader's input, given the vertex side's
/// output with the same semantic (null: it writes none).
fn interpolant(ps: Semantic, gs: ?Semantic) u32 {
    var v: u32 = @as(u32, ps.default_value) << INPUT.DEFAULT_VALUE_SHIFT;
    if (ps.is_f16 != 0) {
        // Each half reads the default unless both shaders use that half.
        const both: u2 = if (gs) |g| ps.is_f16 & g.is_f16 else 0;
        v |= INPUT.HALVES | (@as(u32, ps.is_f16) << INPUT.HALF_VALID_SHIFT);
        if ((both & 1) == 0) v |= INPUT.DEFAULT;
        if ((both & 2) == 0) v |= INPUT.DEFAULT_HIGH;
        v |= @as(u32, ps.default_value_hi) << INPUT.DEFAULT_HIGH_VALUE_SHIFT;
    } else if (ps.is_custom or gs == null) {
        v |= INPUT.DEFAULT;
    }
    if (gs) |g| {
        v |= g.hardware_mapping & INPUT.SLOT;
        if (ps.is_flat_shaded or ps.is_custom) v |= INPUT.FLAT;
    }
    return v;
}

/// The same for the calls a game finds by their plain names: a flat
/// 32-bit input also has `DEFAULT` set. (So does the one open library
/// that has both forms; why the newer form differs is not known.)
fn interpolantPlain(ps: Semantic, gs: ?Semantic) u32 {
    const v = interpolant(ps, gs);
    return if (ps.is_f16 == 0 and ps.is_flat_shaded) v | INPUT.DEFAULT else v;
}

const Rule = *const fn (ps: Semantic, gs: ?Semantic) u32;

/// The pixel-input registers for a pair of shaders, into `out`: one for
/// each input of the pixel shader, and with `rest` the others up to
/// thirty-two, each reading the slot of its own number. Returns how many
/// were written; null when the shaders do not fit.
fn mapping(out: *[INPUT.COUNT]ShaderRegister, gs: ?*const Shader, ps: ?*const Shader, rule: Rule, rest: bool) ?usize {
    var n: usize = 0;
    if (ps) |p| {
        if (p.type != TYPE.PIXEL or p.num_input_semantics > INPUT.COUNT) return null;
        const ins = p.inputs();
        if (ins.len != p.num_input_semantics) return null;
        if (ins.len != 0) {
            const g = gs orelse return null;
            if (g.outputs().len != g.num_output_semantics) return null;
            for (ins) |in| {
                out[n] = .{ .offset = REG.PS_INPUT_CNTL_0 + @as(u32, @intCast(n)), .value = rule(in, g.output(in.semantic)) };
                n += 1;
            }
        }
    }
    if (!rest) return n;
    while (n < INPUT.COUNT) : (n += 1) {
        out[n] = .{ .offset = REG.PS_INPUT_CNTL_0 + @as(u32, @intCast(n)), .value = @intCast(n) };
    }
    return n;
}

fn mapInto(regs: ?Registers, gs: ?*const anyopaque, ps: ?*const anyopaque, rest: bool) i32 {
    const to = regs orelse return INVALID_SHADER;
    var pixel: ?*const Shader = null;
    if (ps != null) pixel = created(ps) orelse return INVALID_SHADER;
    var vertex: ?*const Shader = null;
    if (gs != null) vertex = created(gs) orelse return INVALID_SHADER;
    // (an update is of a pixel shader's own inputs: it needs one)
    if (pixel == null and !rest) return INVALID_SHADER;
    var values: [INPUT.COUNT]ShaderRegister = undefined;
    const n = mapping(&values, vertex, pixel, interpolantPlain, rest) orelse return INVALID_SHADER;
    @memcpy(to[0..n], values[0..n]);
    return 0;
}

/// `sceAgcCreateInterpolantMapping(regs, gs, ps)`: thirty-two context
/// registers to `regs`, linking `ps`'s inputs to `gs`'s outputs of the
/// same semantic. With no pixel shader each input reads its own slot.
pub fn sceAgcCreateInterpolantMapping(regs: ?Registers, gs: ?*const anyopaque, ps: ?*const anyopaque) callconv(.c) i32 {
    return mapInto(regs, gs, ps, true);
}

/// `sceAgcUpdateInterpolantMapping(regs, gs, ps)`: only the registers of
/// `ps`'s own inputs, the rest of `regs` left as it was.
pub fn sceAgcUpdateInterpolantMapping(regs: ?Registers, gs: ?*const anyopaque, ps: ?*const anyopaque) callconv(.c) i32 {
    return mapInto(regs, gs, ps, false);
}

/// `sceAgcLinkShaders(context, primitive, reserved, vertex, pixel, kind)`:
/// all a draw needs set for a vertex-side shader and a pixel shader, in
/// one call: thirty-four context registers (the two of the primitive
/// state, then the thirty-two inputs) and three of user configuration.
/// Nothing is written when anything is refused.
pub fn sceAgcLinkShaders(context: ?Registers, primitive: ?Registers, reserved: ?*const anyopaque, vertex: ?*const anyopaque, pixel: ?*const anyopaque, kind: u32) callconv(.c) i32 {
    const cx = context orelse return INVALID_SHADER;
    const uc = primitive orelse return INVALID_SHADER;
    if (reserved != null) return INVALID_SHADER;
    const v = created(vertex) orelse return INVALID_SHADER;
    var p: ?*const Shader = null;
    if (pixel != null) p = created(pixel) orelse return INVALID_SHADER;

    const state = primState(null, v, kind) orelse return INVALID_SHADER;
    var inputs: [INPUT.COUNT]ShaderRegister = undefined;
    _ = mapping(&inputs, v, p, interpolant, true) orelse return INVALID_SHADER;
    @memcpy(cx[0..2], &state.cx);
    @memcpy(cx[2..][0..INPUT.COUNT], &inputs);
    @memcpy(uc[0..3], &state.uc);
    return 0;
}

/// `sceAgcGetGsOversubscription(regs, gs, budget, factor)`: two registers
/// that tune how much room the GPU keeps for a vertex-side shader's
/// output (user configuration 0x260, shader 0x081). A console works the
/// amounts out from the shader and the budget. Here the answer is none
/// for a budget of 0 and the most for any other: nothing in this project
/// reads either register.
pub fn sceAgcGetGsOversubscription(regs: ?Registers, gs: ?*const anyopaque, budget: u32, factor: f32) callconv(.c) i32 {
    _ = gs;
    _ = factor;
    const to = regs orelse return INVALID_SHADER;
    to[0] = .{ .offset = REG.GE_PC_ALLOC, .value = if (budget == 0) 0 else 0x7FF };
    to[1] = .{ .offset = REG.PGM_RSRC4_GS, .value = if (budget == 0) 0 else 0x007F_0000 };
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A shader as a file holds it: the header, then its tables, every
/// pointer an offset from its own field.
const Image = extern struct {
    head: Shader = .{},
    sh: [4]ShaderRegister = undefined,
    cx: [2]ShaderRegister = undefined,
    specials: Specials = .{},
    inputs: [4]u32 = .{ 0, 0, 0, 0 },
    outputs: [4]u32 = .{ 0, 0, 0, 0 },
    user: UserData = .{},
    direct: [DIRECT.KINDS]u16 = [_]u16{DIRECT.ABSENT} ** DIRECT.KINDS,
    sharp: [2]u16 = .{ 3, 0x8005 },

    fn from(field: *usize, target: *const anyopaque) void {
        field.* = @intFromPtr(target) -% @intFromPtr(field);
    }

    /// Filled in place (the offsets are from where it is).
    fn init(img: *Image, kind: u8, ins: []const Semantic, outs: []const Semantic) void {
        img.* = .{};
        const lo = TYPE.programRegister(kind) orelse 0x300;
        img.sh = .{
            .{ .offset = 0x00A, .value = 0x1111 },
            .{ .offset = lo, .value = 0 },
            .{ .offset = lo + 1, .value = 0xABCD_EF00 },
            .{ .offset = 0x00B, .value = 0x2222 },
        };
        img.cx = .{ .{ .offset = 0x1B1, .value = 5 }, .{ .offset = 0x207, .value = 6 } };
        for (ins, 0..) |s, i| img.inputs[i] = @bitCast(s);
        for (outs, 0..) |s, i| img.outputs[i] = @bitCast(s);
        img.direct[DIRECT.VERTEX_BUFFERS] = 2;
        img.direct[DIRECT.VERTEX_ATTRIBUTES] = 4;
        img.user.direct_count = DIRECT.KINDS;
        from(&img.user.direct, &img.direct);
        img.user.sharp_count[2] = 2;
        from(&img.user.sharps[2], &img.sharp);
        img.head = .{
            .header_size = @sizeOf(Image),
            .shader_size = 64,
            .type = kind,
            .num_sh_registers = 4,
            .num_cx_registers = 2,
            .num_input_semantics = @intCast(ins.len),
            .num_output_semantics = @intCast(outs.len),
            .specials_bytes = @sizeOf(Specials),
        };
        from(&img.head.sh_registers, &img.sh);
        from(&img.head.cx_registers, &img.cx);
        from(&img.head.specials, &img.specials);
        from(&img.head.user_data, &img.user);
        if (ins.len != 0) from(&img.head.input_semantics, &img.inputs);
        if (outs.len != 0) from(&img.head.output_semantics, &img.outputs);
    }
};

const Code = struct {
    var a: [512]u8 align(256) = undefined;
    var b: [512]u8 align(256) = undefined;
    var c: [512]u8 align(256) = undefined;
    var d: [512]u8 align(256) = undefined;
};

test "a file's shader made usable: pointers, the program registers, the list" {
    var img: Image = undefined;
    img.init(TYPE.VERTEX, &.{.{ .semantic = 3, .hardware_mapping = 9, .size_in_elements = 3 }}, &.{.{ .semantic = 15, .hardware_mapping = 0 }});
    var got: usize = 0;
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &img, &Code.a));
    try testing.expectEqual(@intFromPtr(&img), got);

    const s = &img.head;
    try testing.expectEqual(@intFromPtr(&Code.a), s.code);
    try testing.expectEqual(@intFromPtr(&img.sh), @intFromPtr(s.sh().ptr));
    try testing.expectEqual(@as(usize, 4), s.sh().len);
    try testing.expectEqual(@as(u32, 5), s.cx()[0].value);
    try testing.expectEqual(@as(u8, 9), s.inputs()[0].hardware_mapping);
    try testing.expectEqual(@as(u8, 15), s.outputs()[0].semantic);
    try testing.expectEqual(@intFromPtr(&img.specials), @intFromPtr(s.special().?));
    try testing.expectEqual(@as(?u16, 2), s.user().?.directOf(DIRECT.VERTEX_BUFFERS));
    try testing.expectEqual(@as(?u16, 4), s.user().?.directOf(DIRECT.VERTEX_ATTRIBUTES));
    try testing.expectEqual(@as(?u16, null), s.user().?.directOf(DIRECT.RESOURCE_TABLE));
    try testing.expectEqual(@as(?u16, null), s.user().?.directOf(DIRECT.KINDS));
    // (a class's list where there is one, none where there is none)
    try testing.expectEqual(@intFromPtr(&img.sharp), s.user().?.sharps[2]);
    try testing.expectEqual(@as(usize, 0), s.user().?.sharps[0]);
    try testing.expectEqual(@as(usize, 16), s.words().len);

    // The pair: the address without its low byte, then bits 40 to 47 in
    // the low byte of the next, whose other bits stay. Nothing else moved.
    const addr: u64 = @intFromPtr(&Code.a);
    try testing.expectEqual(@as(u32, @truncate(addr >> 8)), img.sh[1].value);
    try testing.expectEqual(0xABCD_EF00 | @as(u32, @truncate((addr >> 40) & 0xFF)), img.sh[2].value);
    try testing.expectEqual(@as(u32, 0x1111), img.sh[0].value);
    try testing.expectEqual(@as(u32, 0x2222), img.sh[3].value);
    try testing.expectEqual(addr, programAddress(img.sh[1].value, img.sh[2].value));
    try testing.expectEqual(@as(?*const Shader, s), byCode(addr));
    try testing.expectEqual(@as(?*const Shader, null), byCode(addr + 256));
    try testing.expectEqual(@as(?*const Shader, null), byCode(0));

    // Made again with its code somewhere else: the tables stay where they
    // are (its user data's too), the pair follows the code, and it is
    // found where it is now and no longer where it was.
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &img, &Code.b));
    try testing.expectEqual(@intFromPtr(&Code.b), s.code);
    try testing.expectEqual(@intFromPtr(&img.sh), @intFromPtr(s.sh().ptr));
    try testing.expectEqual(@intFromPtr(&img.sharp), s.user().?.sharps[2]);
    try testing.expectEqual(@as(u64, @intFromPtr(&Code.b)), programAddress(img.sh[1].value, img.sh[2].value));
    try testing.expectEqual(@as(?*const Shader, s), byCode(@intFromPtr(&Code.b)));
    try testing.expectEqual(@as(?*const Shader, null), byCode(addr));
    // Another shader made where it was is not disturbed by its moving on.
    var other: Image = undefined;
    other.init(TYPE.VERTEX, &.{}, &.{});
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &other, &Code.a));
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &img, &Code.c));
    try testing.expectEqual(@as(?*const Shader, &other.head), byCode(addr));
    try testing.expectEqual(@as(?*const Shader, null), byCode(@intFromPtr(&Code.b)));
    try testing.expectEqual(@as(?*const Shader, s), byCode(@intFromPtr(&Code.c)));

    // A made shader whose pair was written over (it holds less than the
    // code's address): refused, and left as it is.
    img.sh[1].value = 0;
    img.sh[2].value &= 0xFFFF_FF00;
    const was = img;
    got = 77;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateShader(&got, &img, &Code.d));
    try testing.expectEqual(@as(usize, 77), got);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&was), std.mem.asBytes(&img));
    try testing.expectEqual(@as(?*const Shader, s), byCode(@intFromPtr(&Code.c)));
}

test "a program that starts inside its code keeps its place; a half has no register" {
    // The file's pair holds 0x200: the program begins two blocks in.
    var img: Image = undefined;
    img.init(TYPE.PIXEL, &.{}, &.{});
    img.sh[1].value = 2;
    var got: usize = 0;
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &img, &Code.c));
    const start: u64 = @intFromPtr(&Code.c) + 0x200;
    try testing.expectEqual(start, programAddress(img.sh[1].value, img.sh[2].value));
    try testing.expectEqual(@as(?*const Shader, &img.head), byCode(start));
    // Moved: still two blocks in.
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &img, &Code.d));
    try testing.expectEqual(@as(u64, @intFromPtr(&Code.d)) + 0x200, programAddress(img.sh[1].value, img.sh[2].value));

    // The front half of a shader: no register points at it, its list is
    // not searched, and it is found by where its code is.
    var half: Image = undefined;
    half.init(TYPE.VERTEX_FRONT, &.{}, &.{});
    const before = half.sh;
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &half, &Code.a));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&half.sh));
    try testing.expectEqual(@as(?*const Shader, &half.head), byCode(@intFromPtr(&Code.a)));
}

test "what is not a shader is refused and left as it was" {
    const Case = struct {
        fn refused(change: *const fn (*Image) void, code: ?*const anyopaque) !void {
            var img: Image = undefined;
            img.init(TYPE.VERTEX, &.{}, &.{});
            change(&img);
            const was = img;
            var got: usize = 77;
            try testing.expectEqual(INVALID_SHADER, sceAgcCreateShader(&got, &img, code));
            try testing.expectEqual(@as(usize, 77), got);
            try testing.expectEqualSlices(u8, std.mem.asBytes(&was), std.mem.asBytes(&img));
        }
        fn nothing(_: *Image) void {}
        fn magic(i: *Image) void {
            i.head.magic = 0x3433_3232;
        }
        fn version(i: *Image) void {
            i.head.version = 0x17;
        }
        fn empty(i: *Image) void {
            i.head.shader_size = 0;
        }
        fn ragged(i: *Image) void {
            i.head.shader_size = 62;
        }
        fn kind(i: *Image) void {
            i.head.type = 9;
        }
        fn noPair(i: *Image) void {
            i.sh[2].offset = 0x0CA;
        }
        fn pairLast(i: *Image) void {
            i.sh[3] = i.sh[1];
            i.sh[1].offset = 0x00C;
        }
        fn noList(i: *Image) void {
            i.head.sh_registers = 0;
        }
        /// A start so far into the code that its address would pass 2^48.
        fn farStart(i: *Image) void {
            i.sh[1].value = 0xFFFF_FFFF;
            i.sh[2].value = 0xFF;
        }
    };
    try Case.refused(Case.magic, &Code.a);
    try Case.refused(Case.version, &Code.a);
    try Case.refused(Case.empty, &Code.a);
    try Case.refused(Case.ragged, &Code.a);
    try Case.refused(Case.kind, &Code.a);
    try Case.refused(Case.noPair, &Code.a);
    try Case.refused(Case.pairLast, &Code.a);
    try Case.refused(Case.noList, &Code.a);
    try Case.refused(Case.farStart, &Code.a);
    // Code not on a 256-byte line, above 2^48, or none.
    try Case.refused(Case.nothing, &Code.a[4]);
    try Case.refused(Case.nothing, @ptrFromInt(0x1_0000_0000_0000));
    try Case.refused(Case.nothing, null);

    var img: Image = undefined;
    img.init(TYPE.VERTEX, &.{}, &.{});
    var got: usize = 0;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateShader(null, &img, &Code.a));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateShader(&got, null, &Code.a));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateShader(&got, @ptrFromInt(@intFromPtr(&img) + 4), &Code.a));
}

test "the primitive state: which stages run and what they hand the rasteriser" {
    var got: usize = 0;
    var vs: Image = undefined;
    vs.init(TYPE.VERTEX, &.{}, &.{});
    vs.specials.stages.value = 0x0240_2000;
    vs.specials.ge_cntl.value = 0x8040;
    vs.specials.user_vgpr_en.value = 3;
    vs.specials.out_primitive.value = 1;
    var cx: [2]ShaderRegister = undefined;
    var uc: [3]ShaderRegister = undefined;

    // A shader still a file's image is not one yet.
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, null, &vs, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &vs, &Code.a));

    // No geometry stage, no hull shader: the output follows the primitive.
    for ([_][2]u32{
        .{ PRIMITIVE.POINTS, 0 },      .{ PRIMITIVE.LINES, 1 },          .{ PRIMITIVE.LINE_LOOP, 1 },
        .{ PRIMITIVE.TRIANGLES, 2 },   .{ PRIMITIVE.TRIANGLE_STRIP, 2 }, .{ PRIMITIVE.QUADS, 2 },
        .{ PRIMITIVE.RECTANGLES, 3 },  .{ PRIMITIVE.RECTANGLES_OLD, 4 }, .{ PRIMITIVE.NONE, 2 },
    }) |c| {
        try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(&cx, &uc, null, &vs, c[0]));
        try testing.expectEqual(ShaderRegister{ .offset = 0x2D5, .value = 0x0240_2000 }, cx[0]);
        try testing.expectEqual(ShaderRegister{ .offset = 0x29B, .value = c[1] }, cx[1]);
        try testing.expectEqual(ShaderRegister{ .offset = 0x25B, .value = 0x8040 }, uc[0]);
        try testing.expectEqual(ShaderRegister{ .offset = 0x262, .value = 3 }, uc[1]);
        try testing.expectEqual(ShaderRegister{ .offset = 0x242, .value = c[0] }, uc[2]);
    }
    // No such primitive: refused, nothing written. One list alone is fine;
    // none at all is nothing to do.
    cx[0].value = 0x5555;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, null, &vs, 8));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, null, &vs, 22));
    try testing.expectEqual(@as(u32, 0x5555), cx[0].value);
    try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(null, &uc, null, &vs, PRIMITIVE.POINTS));
    try testing.expectEqual(@as(u32, PRIMITIVE.POINTS), uc[2].value);
    try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(null, null, null, null, 99));

    // Another primitive for the same registers.
    try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(&cx, &uc, null, &vs, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(i32, 0), sceAgcUpdatePrimState(&cx, &uc, PRIMITIVE.LINE_STRIP));
    try testing.expectEqual(@as(u32, 1), cx[1].value);
    try testing.expectEqual(@as(u32, PRIMITIVE.LINE_STRIP), uc[2].value);
    try testing.expectEqual(INVALID_SHADER, sceAgcUpdatePrimState(&cx, &uc, 8));
    try testing.expectEqual(@as(u32, PRIMITIVE.LINE_STRIP), uc[2].value);

    // A geometry stage says what comes out, whatever goes in; an update
    // leaves that alone.
    vs.specials.stages.value |= STAGES.GEOMETRY;
    try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(&cx, &uc, null, &vs, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(u32, 1), cx[1].value);
    try testing.expectEqual(@as(i32, 0), sceAgcUpdatePrimState(&cx, &uc, PRIMITIVE.POINTS));
    try testing.expectEqual(@as(u32, 1), cx[1].value);
    try testing.expectEqual(@as(u32, PRIMITIVE.POINTS), uc[2].value);
    vs.specials.stages.value &= ~STAGES.GEOMETRY;

    // With a hull shader: its stage bits join, its output and its
    // user-register enables are the ones used.
    var hs: Image = undefined;
    hs.init(TYPE.HULL, &.{}, &.{});
    hs.specials.stages.value = STAGES.HULL | 1;
    // (patches alone would give 2)
    hs.specials.out_primitive.value = 1;
    hs.specials.user_vgpr_en.value = 5;
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &hs, &Code.b));
    try testing.expectEqual(@as(i32, 0), sceAgcCreatePrimState(&cx, &uc, &hs, &vs, PRIMITIVE.PATCHES));
    try testing.expectEqual(@as(u32, 0x0240_2005), cx[0].value);
    try testing.expectEqual(@as(u32, 1), cx[1].value);
    try testing.expectEqual(@as(u32, 5), uc[1].value);
    try testing.expectEqual(@as(u32, 0x8040), uc[0].value);
    // An update leaves the hull shader's word alone too, and then does not
    // ask what the primitive would give: any kind is written.
    try testing.expectEqual(@as(i32, 0), sceAgcUpdatePrimState(&cx, &uc, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(u32, 1), cx[1].value);
    try testing.expectEqual(@as(u32, PRIMITIVE.TRIANGLES), uc[2].value);
    try testing.expectEqual(@as(i32, 0), sceAgcUpdatePrimState(&cx, &uc, 8));
    try testing.expectEqual(@as(u32, 8), uc[2].value);
    try testing.expectEqual(@as(i32, 0), sceAgcUpdatePrimState(null, &uc, PRIMITIVE.POINTS));
    try testing.expectEqual(@as(u32, PRIMITIVE.POINTS), uc[2].value);

    // The two the wrong way round, a vertex side where the hull shader
    // goes, a special register that is another register.
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, &vs, &hs, PRIMITIVE.PATCHES));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, &vs, &vs, PRIMITIVE.PATCHES));
    vs.specials.ge_cntl.offset = 0x25C;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, null, &vs, PRIMITIVE.TRIANGLES));
    vs.specials.ge_cntl.offset = REG.GE_CNTL;
    vs.head.specials = 0;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreatePrimState(&cx, &uc, null, &vs, PRIMITIVE.TRIANGLES));
}

test "one pixel input's register, from the two shaders' words" {
    const out7: Semantic = .{ .semantic = 20, .hardware_mapping = 7 };
    // Found: the slot. Not found: the default, with the value asked for.
    try testing.expectEqual(@as(u32, 7), interpolant(.{ .semantic = 20 }, out7));
    try testing.expectEqual(@as(u32, 0x20), interpolant(.{ .semantic = 20 }, null));
    try testing.expectEqual(@as(u32, 0x320), interpolant(.{ .semantic = 20, .default_value = 3 }, null));
    try testing.expectEqual(@as(u32, 0x107), interpolant(.{ .semantic = 20, .default_value = 1 }, out7));
    // (only five bits of the slot)
    try testing.expectEqual(@as(u32, 0x1F), interpolant(.{}, .{ .hardware_mapping = 0xFF }));
    // Flat; custom (flat, and each vertex's own value).
    try testing.expectEqual(@as(u32, 0x407), interpolant(.{ .is_flat_shaded = true }, out7));
    try testing.expectEqual(@as(u32, 0x427), interpolant(.{ .is_custom = true }, out7));
    try testing.expectEqual(@as(u32, 0x20), interpolant(.{ .is_flat_shaded = true }, null));
    // The plain-named calls: a flat 32-bit input reads each vertex's value
    // too; anything else is the same.
    try testing.expectEqual(@as(u32, 0x427), interpolantPlain(.{ .is_flat_shaded = true }, out7));
    try testing.expectEqual(@as(u32, 7), interpolantPlain(.{}, out7));
    try testing.expectEqual(interpolant(.{ .is_f16 = 1, .is_flat_shaded = true }, out7), interpolantPlain(.{ .is_f16 = 1, .is_flat_shaded = true }, out7));

    // Halves: valid bits from the pixel shader; a half is the default
    // unless both shaders use it.
    const halves: Semantic = .{ .semantic = 20, .hardware_mapping = 7, .is_f16 = 3 };
    try testing.expectEqual(@as(u32, 0x0308_0007), interpolant(.{ .is_f16 = 3 }, halves));
    try testing.expectEqual(@as(u32, 0x0318_0007), interpolant(.{ .is_f16 = 3 }, .{ .hardware_mapping = 7, .is_f16 = 1 }));
    try testing.expectEqual(@as(u32, 0x0308_0027), interpolant(.{ .is_f16 = 3 }, .{ .hardware_mapping = 7, .is_f16 = 2 }));
    try testing.expectEqual(@as(u32, 0x0118_0007), interpolant(.{ .is_f16 = 1 }, halves));
    try testing.expectEqual(@as(u32, 0x0218_0027), interpolant(.{ .is_f16 = 2 }, out7));
    try testing.expectEqual(@as(u32, 0x0318_0020), interpolant(.{ .is_f16 = 3 }, null));
    try testing.expectEqual(@as(u32, 0x0378_0220), interpolant(.{ .is_f16 = 3, .default_value = 2, .default_value_hi = 3 }, null));
    try testing.expectEqual(@as(u32, 0x0348_0407), interpolant(.{ .is_f16 = 3, .is_flat_shaded = true, .default_value_hi = 2 }, halves));
}

test "the inputs of a pixel shader linked to a vertex side's outputs" {
    var got: usize = 0;
    var vs: Image = undefined;
    // Outputs in an order of their own: found by semantic, not by place.
    vs.init(TYPE.VERTEX, &.{}, &.{
        .{ .semantic = 17, .hardware_mapping = 2 },
        .{ .semantic = 15, .hardware_mapping = 0 },
        .{ .semantic = 16, .hardware_mapping = 1 },
    });
    vs.specials.stages.value = 0x2000;
    var ps: Image = undefined;
    ps.init(TYPE.PIXEL, &.{
        .{ .semantic = 16 },
        .{ .semantic = 17, .is_flat_shaded = true },
        .{ .semantic = 30, .default_value = 1 },
    }, &.{});
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &vs, &Code.a));
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &ps, &Code.b));

    var regs: [33]ShaderRegister = undefined;
    @memset(&regs, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(@as(i32, 0), sceAgcCreateInterpolantMapping(&regs, &vs, &ps));
    try testing.expectEqual(ShaderRegister{ .offset = 0x191, .value = 1 }, regs[0]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x192, .value = 0x422 }, regs[1]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x193, .value = 0x120 }, regs[2]);
    // The rest: each its own slot. Thirty-two and no more.
    for (3..32) |i| try testing.expectEqual(ShaderRegister{ .offset = 0x191 + @as(u32, @intCast(i)), .value = @intCast(i) }, regs[i]);
    try testing.expectEqual(@as(u32, 0xEEEE), regs[32].value);

    // An update writes the pixel shader's own three.
    @memset(&regs, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(@as(i32, 0), sceAgcUpdateInterpolantMapping(&regs, &vs, &ps));
    try testing.expectEqual(ShaderRegister{ .offset = 0x193, .value = 0x120 }, regs[2]);
    try testing.expectEqual(@as(u32, 0xEEEE), regs[3].value);
    try testing.expectEqual(INVALID_SHADER, sceAgcUpdateInterpolantMapping(&regs, &vs, null));

    // No pixel shader: every input its own slot. A pixel shader with no
    // inputs, and no vertex side at all: the same.
    try testing.expectEqual(@as(i32, 0), sceAgcCreateInterpolantMapping(&regs, &vs, null));
    for (0..32) |i| try testing.expectEqual(@as(u32, @intCast(i)), regs[i].value);
    var bare: Image = undefined;
    bare.init(TYPE.PIXEL, &.{}, &.{});
    try testing.expectEqual(@as(i32, 0), sceAgcCreateShader(&got, &bare, &Code.c));
    @memset(&regs, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(@as(i32, 0), sceAgcCreateInterpolantMapping(&regs, null, &bare));
    for (0..32) |i| try testing.expectEqual(ShaderRegister{ .offset = 0x191 + @as(u32, @intCast(i)), .value = @intCast(i) }, regs[i]);
    try testing.expectEqual(@as(i32, 0), sceAgcUpdateInterpolantMapping(&regs, null, &bare));

    // Refused, and nothing written: no list, a vertex side where the pixel
    // shader goes, inputs with no vertex side, more than thirty-two.
    @memset(&regs, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateInterpolantMapping(null, &vs, &ps));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateInterpolantMapping(&regs, &vs, &vs));
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateInterpolantMapping(&regs, null, &ps));
    ps.head.num_input_semantics = 33;
    try testing.expectEqual(INVALID_SHADER, sceAgcCreateInterpolantMapping(&regs, &vs, &ps));
    ps.head.num_input_semantics = 3;
    try testing.expectEqual(@as(u32, 0xEEEE), regs[0].value);

    // Linked in one call: the primitive state's two, then the thirty-two
    // (by the rule without the flat default), and three for the primitive.
    var cx: [35]ShaderRegister = undefined;
    var uc: [4]ShaderRegister = undefined;
    @memset(&cx, .{ .offset = 0xEEEE, .value = 0xEEEE });
    @memset(&uc, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(@as(i32, 0), sceAgcLinkShaders(&cx, &uc, null, &vs, &ps, PRIMITIVE.TRIANGLE_STRIP));
    try testing.expectEqual(ShaderRegister{ .offset = 0x2D5, .value = 0x2000 }, cx[0]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x29B, .value = 2 }, cx[1]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x191, .value = 1 }, cx[2]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x192, .value = 0x402 }, cx[3]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x193, .value = 0x120 }, cx[4]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x1B0, .value = 31 }, cx[33]);
    try testing.expectEqual(@as(u32, 0xEEEE), cx[34].value);
    try testing.expectEqual(ShaderRegister{ .offset = 0x242, .value = PRIMITIVE.TRIANGLE_STRIP }, uc[2]);
    try testing.expectEqual(@as(u32, 0xEEEE), uc[3].value);
    // With no pixel shader it still links.
    try testing.expectEqual(@as(i32, 0), sceAgcLinkShaders(&cx, &uc, null, &vs, null, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(ShaderRegister{ .offset = 0x191, .value = 0 }, cx[2]);
    // A geometry stage's own word for what comes out is the one linked.
    vs.specials.stages.value |= STAGES.GEOMETRY;
    vs.specials.out_primitive.value = 1;
    try testing.expectEqual(@as(i32, 0), sceAgcLinkShaders(&cx, &uc, null, &vs, &ps, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(ShaderRegister{ .offset = 0x29B, .value = 1 }, cx[1]);
    try testing.expectEqual(@as(u32, 0x2020), cx[0].value);
    vs.specials.stages.value &= ~STAGES.GEOMETRY;

    // Refused whole: a reserved argument, no such primitive, the shaders
    // the wrong way round, a list missing.
    @memset(&cx, .{ .offset = 0xEEEE, .value = 0xEEEE });
    @memset(&uc, .{ .offset = 0xEEEE, .value = 0xEEEE });
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(&cx, &uc, &vs, &vs, &ps, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(&cx, &uc, null, &vs, &ps, 8));
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(&cx, &uc, null, &ps, &vs, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(null, &uc, null, &vs, &ps, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(&cx, null, null, &vs, &ps, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(INVALID_SHADER, sceAgcLinkShaders(&cx, &uc, null, null, &ps, PRIMITIVE.TRIANGLES));
    try testing.expectEqual(@as(u32, 0xEEEE), cx[0].value);
    try testing.expectEqual(@as(u32, 0xEEEE), uc[0].value);

    // The oversubscription registers: none for no budget, the most else.
    var two: [2]ShaderRegister = undefined;
    try testing.expectEqual(@as(i32, 0), sceAgcGetGsOversubscription(&two, &vs, 0, 0.5));
    try testing.expectEqual(ShaderRegister{ .offset = 0x260, .value = 0 }, two[0]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x081, .value = 0 }, two[1]);
    try testing.expectEqual(@as(i32, 0), sceAgcGetGsOversubscription(&two, &vs, 4096, 0.5));
    try testing.expectEqual(ShaderRegister{ .offset = 0x260, .value = 0x7FF }, two[0]);
    try testing.expectEqual(ShaderRegister{ .offset = 0x081, .value = 0x007F_0000 }, two[1]);
}

test "many shaders are listed and found; a full list drops the rest and keeps what it has" {
    // Addresses a game's code could be at, never read: one header for all.
    var img: Image = undefined;
    img.init(TYPE.VERTEX_FRONT, &.{}, &.{});
    img.head.code = 1;
    const base: u64 = 0x7_0000_0000;
    // (the list is emptied after: tests that follow start with room)
    defer {
        @memset(&made.keys, 0);
        @memset(&made.values, 0);
        made.count = 0;
        made.told = false;
    }
    const was = listed();
    const room = made.MOST - was;
    for (0..room + 50) |i| made.put(base + 256 * @as(u64, i), &img.head);
    try testing.expectEqual(@as(u32, made.MOST), listed());
    try testing.expect(made.told);
    for (0..room) |i| try testing.expectEqual(@as(?*const Shader, &img.head), byCode(base + 256 * @as(u64, i)));
    try testing.expectEqual(@as(?*const Shader, null), byCode(base + 256 * @as(u64, room)));
    // One already listed is still replaced when the list is full.
    var other: Image = undefined;
    other.init(TYPE.VERTEX_FRONT, &.{}, &.{});
    made.put(base, &other.head);
    try testing.expectEqual(@as(?*const Shader, &other.head), byCode(base));
    try testing.expectEqual(@as(u32, made.MOST), listed());
}
