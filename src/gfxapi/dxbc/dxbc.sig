//! @zpm/gfxapi dxbc — Direct3D's shader bytecode, read in place: the DXBC
//! container (its chunks, the input and output signatures) and Shader
//! Model 4 and 5's tokens (declarations and instructions), as Microsoft's
//! tokenized program format defines them (d3d11TokenizedProgramFormat.hpp).
//! Pure and allocation-free: every slice points into the caller's bytes,
//! and the instruction reader steps through the program one token run at
//! a time.

const std = @import("std");

pub const Error = error{ NotDxbc, Truncated, NoShader, BadToken };

// ── The container ──────────────────────────────────────────────────────────

/// "DXBC", a 16-byte checksum, version 1, the total size, the chunk count,
/// then each chunk's offset; a chunk is a tag, its size, its bytes.
pub const Container = struct {
    bytes: []const u8,
    count: u32,

    pub fn parse(b: []const u8) Error!Container {
        if (b.len < 32 or !std.mem.eql(u8, b[0..4], "DXBC")) return error.NotDxbc;
        const total = rd(b, 24);
        const count = rd(b, 28);
        if (total > b.len or total < 32 or count > (total - 32) / 4) return error.Truncated;
        const c = Container{ .bytes = b[0..total], .count = count };
        var i: u32 = 0;
        while (i < count) : (i += 1) _ = try c.chunkAt(i);
        return c;
    }

    fn chunkAt(c: Container, i: u32) Error!Chunk {
        const off = rd(c.bytes, 32 + i * 4);
        if (off > c.bytes.len - 8) return error.Truncated;
        const size = rd(c.bytes, off + 4);
        if (size > c.bytes.len - off - 8) return error.Truncated;
        return .{ .tag = c.bytes[off..][0..4].*, .data = c.bytes[off + 8 ..][0..size] };
    }

    /// The first chunk with one of `tags`, in the order the container has them.
    pub fn find(c: Container, tags: []const *const [4]u8) ?Chunk {
        var i: u32 = 0;
        while (i < c.count) : (i += 1) {
            const ch = c.chunkAt(i) catch return null;
            for (tags) |t| if (std.mem.eql(u8, &ch.tag, t)) return ch;
        }
        return null;
    }

    /// The program's tokens (SHDR: Shader Model 4, SHEX: 5).
    pub fn program(c: Container) Error!Program {
        const ch = c.find(&.{ "SHEX", "SHDR" }) orelse return error.NoShader;
        return Program.parse(ch.data);
    }

    /// The input (`out` false) or output signature.
    pub fn signature(c: Container, out: bool) ?Signature {
        const ch = (if (out) c.find(&.{ "OSG5", "OSGN" }) else c.find(&.{"ISGN"})) orelse return null;
        return Signature.parse(ch.data, std.mem.eql(u8, &ch.tag, "OSG5")) catch null;
    }
};

pub const Chunk = struct { tag: [4]u8, data: []const u8 };

fn rd(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

// ── Signatures (ISGN, OSGN, OSG5) ───────────────────────────────────────────

/// D3D_NAME: what a signature element is to the system.
pub const SysValue = enum(u32) {
    none = 0,
    position = 1,
    clip_distance = 2,
    cull_distance = 3,
    render_target_array_index = 4,
    viewport_array_index = 5,
    vertex_id = 6,
    primitive_id = 7,
    instance_id = 8,
    is_front_face = 9,
    sample_index = 10,
    target = 64,
    depth = 65,
    coverage = 66,
    _,
};

/// D3D_REGISTER_COMPONENT_TYPE.
pub const CompType = enum(u32) { unknown = 0, uint32 = 1, sint32 = 2, float32 = 3, _ };

pub const Element = struct {
    name: []const u8,
    index: u32,
    sys: SysValue,
    comp: CompType,
    register: u32,
    mask: u8,
    rw_mask: u8,
};

pub const Signature = struct {
    data: []const u8,
    count: u32,
    /// OSG5's elements start with their stream (28 bytes, not 24).
    stride: u32,

    pub fn parse(d: []const u8, streams: bool) Error!Signature {
        if (d.len < 8) return error.Truncated;
        const count = rd(d, 0);
        const stride: u32 = if (streams) 28 else 24;
        if (count > (d.len - 8) / stride) return error.Truncated;
        return .{ .data = d, .count = count, .stride = stride };
    }

    pub fn get(s: Signature, i: u32) ?Element {
        if (i >= s.count) return null;
        const at = 8 + i * s.stride + (s.stride - 24);
        const name_off = rd(s.data, at);
        if (name_off >= s.data.len) return null;
        const name = std.mem.sliceTo(s.data[name_off..], 0);
        return .{
            .name = name,
            .index = rd(s.data, at + 4),
            .sys = @enumFromInt(rd(s.data, at + 8)),
            .comp = @enumFromInt(rd(s.data, at + 12)),
            .register = rd(s.data, at + 16),
            .mask = s.data[at + 20],
            .rw_mask = s.data[at + 21],
        };
    }

    /// The element at register `reg` (the first of its components).
    pub fn atRegister(s: Signature, reg: u32) ?Element {
        var i: u32 = 0;
        while (i < s.count) : (i += 1) {
            const e = s.get(i) orelse return null;
            if (e.register == reg) return e;
        }
        return null;
    }
};

// ── The program: header and tokens ─────────────────────────────────────────

pub const Stage = enum(u16) { pixel = 0, vertex = 1, geometry = 2, hull = 3, domain = 4, compute = 5, _ };

pub const Program = struct {
    stage: Stage,
    major: u8,
    minor: u8,
    tokens: []align(1) const u32,

    pub fn parse(d: []const u8) Error!Program {
        if (d.len < 8 or d.len % 4 != 0) return error.Truncated;
        const ver = rd(d, 0);
        const len = rd(d, 4);
        if (len < 2 or len > d.len / 4) return error.Truncated;
        return .{
            .stage = @enumFromInt(@as(u16, @truncate(ver >> 16))),
            .major = @truncate((ver >> 4) & 0xf),
            .minor = @truncate(ver & 0xf),
            .tokens = tokensOf(d)[2..len],
        };
    }

    pub fn reader(p: Program) Reader {
        return .{ .t = p.tokens };
    }
};

/// The bytes as little-endian 32-bit tokens (DXBC's chunks are 4-aligned
/// within the container; a caller's buffer may not be, so tokens are read
/// as unaligned words).
fn tokensOf(d: []const u8) []align(1) const u32 {
    const p: [*]align(1) const u32 = @ptrCast(d.ptr);
    return p[0 .. d.len / 4];
}

// ── Opcodes (D3D10_SB_OPCODE_TYPE, D3D11_SB_OPCODE_TYPE) ───────────────────

pub const Op = enum(u11) {
    add = 0,
    @"and" = 1,
    @"break" = 2,
    breakc = 3,
    call = 4,
    callc = 5,
    case = 6,
    @"continue" = 7,
    continuec = 8,
    cut = 9,
    default = 10,
    deriv_rtx = 11,
    deriv_rty = 12,
    discard = 13,
    div = 14,
    dp2 = 15,
    dp3 = 16,
    dp4 = 17,
    @"else" = 18,
    emit = 19,
    emitthencut = 20,
    endif = 21,
    endloop = 22,
    endswitch = 23,
    eq = 24,
    exp = 25,
    frc = 26,
    ftoi = 27,
    ftou = 28,
    ge = 29,
    iadd = 30,
    @"if" = 31,
    ieq = 32,
    ige = 33,
    ilt = 34,
    imad = 35,
    imax = 36,
    imin = 37,
    imul = 38,
    ine = 39,
    ineg = 40,
    ishl = 41,
    ishr = 42,
    itof = 43,
    label = 44,
    ld = 45,
    ld_ms = 46,
    log = 47,
    loop = 48,
    lt = 49,
    mad = 50,
    min = 51,
    max = 52,
    customdata = 53,
    mov = 54,
    movc = 55,
    mul = 56,
    ne = 57,
    nop = 58,
    not = 59,
    @"or" = 60,
    resinfo = 61,
    ret = 62,
    retc = 63,
    round_ne = 64,
    round_ni = 65,
    round_pi = 66,
    round_z = 67,
    rsq = 68,
    sample = 69,
    sample_c = 70,
    sample_c_lz = 71,
    sample_l = 72,
    sample_d = 73,
    sample_b = 74,
    sqrt = 75,
    @"switch" = 76,
    sincos = 77,
    udiv = 78,
    ult = 79,
    uge = 80,
    umul = 81,
    umad = 82,
    umax = 83,
    umin = 84,
    ushr = 85,
    utof = 86,
    xor = 87,
    dcl_resource = 88,
    dcl_constant_buffer = 89,
    dcl_sampler = 90,
    dcl_index_range = 91,
    dcl_gs_output_primitive_topology = 92,
    dcl_gs_input_primitive = 93,
    dcl_max_output_vertex_count = 94,
    dcl_input = 95,
    dcl_input_sgv = 96,
    dcl_input_siv = 97,
    dcl_input_ps = 98,
    dcl_input_ps_sgv = 99,
    dcl_input_ps_siv = 100,
    dcl_output = 101,
    dcl_output_sgv = 102,
    dcl_output_siv = 103,
    dcl_temps = 104,
    dcl_indexable_temp = 105,
    dcl_global_flags = 106,
    lod = 108,
    gather4 = 109,
    sample_pos = 110,
    sample_info = 111,
    deriv_rtx_coarse = 122,
    deriv_rtx_fine = 123,
    deriv_rty_coarse = 124,
    deriv_rty_fine = 125,
    gather4_c = 126,
    gather4_po = 127,
    gather4_po_c = 128,
    rcp = 129,
    f32tof16 = 130,
    f16tof32 = 131,
    uaddc = 132,
    usubb = 133,
    countbits = 134,
    firstbit_hi = 135,
    firstbit_lo = 136,
    firstbit_shi = 137,
    ubfe = 138,
    ibfe = 139,
    bfi = 140,
    bfrev = 141,
    swapc = 142,
    dcl_thread_group = 155,
    _,
};

/// customdata's classes (bits 11-31 of its opcode token).
pub const CUSTOMDATA_IMMEDIATE_CONSTANT_BUFFER: u32 = 3;

// ── Operands ───────────────────────────────────────────────────────────────

/// D3D10_SB_OPERAND_TYPE.
pub const Reg = enum(u8) {
    temp = 0,
    input = 1,
    output = 2,
    indexable_temp = 3,
    immediate32 = 4,
    immediate64 = 5,
    sampler = 6,
    resource = 7,
    constant_buffer = 8,
    immediate_constant_buffer = 9,
    label = 10,
    input_primitive_id = 11,
    output_depth = 12,
    null = 13,
    rasterizer = 14,
    output_coverage_mask = 15,
    stream = 16,
    function_body = 17,
    function_table = 18,
    interface = 19,
    function_input = 20,
    function_output = 21,
    output_control_point_id = 22,
    input_fork_instance_id = 23,
    input_join_instance_id = 24,
    input_control_point = 25,
    output_control_point = 26,
    input_patch_constant = 27,
    input_domain_point = 28,
    this_pointer = 29,
    unordered_access_view = 30,
    thread_group_shared_memory = 31,
    input_thread_id = 32,
    input_thread_group_id = 33,
    input_thread_id_in_group = 34,
    input_coverage_mask = 35,
    input_thread_id_in_group_flattened = 36,
    input_gs_instance_id = 37,
    output_depth_greater_equal = 38,
    output_depth_less_equal = 39,
    cycle_counter = 40,
    _,
};

/// An index: an immediate, a register (`rel`) plus an immediate, or both.
pub const Index = struct {
    imm: u32 = 0,
    /// relative: the register and component whose value is added
    rel: bool = false,
    rel_reg: Reg = .temp,
    rel_num: u32 = 0,
    /// the indexable temp's array, for x#[r]
    rel_num2: u32 = 0,
    rel_comp: u2 = 0,
};

pub const Operand = struct {
    reg: Reg,
    /// components: 0, 1 or 4
    comps: u3 = 4,
    /// a destination's write mask (bit 0: x)
    mask: u4 = 0xf,
    /// a source's swizzle: the component each of x, y, z, w reads
    swizzle: [4]u2 = .{ 0, 1, 2, 3 },
    dims: u2 = 0,
    index: [3]Index = .{ .{}, .{}, .{} },
    /// immediate32's values (comps of them)
    imm: [4]u32 = .{ 0, 0, 0, 0 },
    neg: bool = false,
    abs: bool = false,
};

pub const MAX_OPERANDS = 8;

/// An instruction or declaration, decoded.
pub const Inst = struct {
    op: Op,
    /// its whole token run (the opcode token first)
    raw: []align(1) const u32,
    saturate: bool = false,
    /// conditionals: true tests nonzero (_nz), false zero (_z)
    nonzero: bool = false,
    /// sample controls' texel offsets (aoffimmi), and the extended tokens'
    /// resource dimension and return type, as read
    offset: [3]i8 = .{ 0, 0, 0 },
    operands: [MAX_OPERANDS]Operand = undefined,
    n: u8 = 0,
    /// customdata: its words (an immediate constant buffer's: 4 per entry)
    data: []align(1) const u32 = &.{},
};

/// Steps through a program's tokens, one instruction or declaration at a
/// time. Declarations that have no operands of the usual form (temps, the
/// global flags, a resource's return types) keep their tokens in `raw`.
pub const Reader = struct {
    t: []align(1) const u32,
    at: usize = 0,

    pub fn next(r: *Reader) Error!?Inst {
        if (r.at >= r.t.len) return null;
        const tok = r.t[r.at];
        const op: Op = @enumFromInt(@as(u11, @truncate(tok)));
        if (op == .customdata) {
            if (r.at + 1 >= r.t.len) return error.Truncated;
            const len = r.t[r.at + 1];
            if (len < 2 or r.at + len > r.t.len) return error.Truncated;
            const raw = r.t[r.at..][0..len];
            r.at += len;
            return Inst{ .op = op, .raw = raw, .data = raw[2..], .n = 0, .nonzero = (tok >> 11) == CUSTOMDATA_IMMEDIATE_CONSTANT_BUFFER };
        }
        const len: usize = (tok >> 24) & 0x7f;
        if (len == 0 or r.at + len > r.t.len) return error.BadToken;
        const raw = r.t[r.at..][0..len];
        r.at += len;
        var inst = Inst{
            .op = op,
            .raw = raw,
            .saturate = tok & (1 << 13) != 0,
            .nonzero = tok & (1 << 18) != 0,
        };
        var p: usize = 1;
        // extended opcode tokens: sample controls (texel offsets), resource
        // dimension, return type
        var ext = tok & 0x8000_0000 != 0;
        while (ext) {
            if (p >= raw.len) return error.Truncated;
            const e = raw[p];
            p += 1;
            ext = e & 0x8000_0000 != 0;
            if (e & 0x3f == 1) {
                inst.offset = .{ sx4(e >> 9), sx4(e >> 13), sx4(e >> 17) };
            }
        }
        if (!hasOperands(op)) return inst;
        while (p < raw.len and inst.n < MAX_OPERANDS) {
            const o = try operand(raw, &p);
            inst.operands[inst.n] = o;
            inst.n += 1;
            // (a declaration's operand is followed by its own words: what
            // those are, the caller reads from `raw`)
            if (declTail(op)) break;
        }
        return inst;
    }
};

fn sx4(v: u32) i8 {
    const n: u4 = @truncate(v);
    return @as(i8, @as(i4, @bitCast(n)));
}

/// Declarations whose tokens are not operands at all.
fn hasOperands(op: Op) bool {
    return switch (op) {
        .dcl_temps, .dcl_global_flags, .dcl_indexable_temp, .dcl_gs_output_primitive_topology, .dcl_gs_input_primitive, .dcl_max_output_vertex_count, .dcl_thread_group, .nop => false,
        else => true,
    };
}

/// Declarations with one operand followed by words of their own (a
/// resource's return types, an input's system value, ...).
fn declTail(op: Op) bool {
    const n = @intFromEnum(op);
    return n >= @intFromEnum(Op.dcl_resource) and n <= @intFromEnum(Op.dcl_global_flags);
}

fn operand(raw: []align(1) const u32, p: *usize) Error!Operand {
    if (p.* >= raw.len) return error.Truncated;
    const tok = raw[p.*];
    p.* += 1;
    var o = Operand{ .reg = @enumFromInt(@as(u8, @truncate(tok >> 12))) };
    o.comps = switch (tok & 3) {
        0 => 0,
        1 => 1,
        2 => 4,
        else => return error.BadToken,
    };
    if (o.comps == 4) {
        switch ((tok >> 2) & 3) {
            0 => o.mask = @truncate(tok >> 4),
            1 => o.swizzle = .{ @truncate(tok >> 4), @truncate(tok >> 6), @truncate(tok >> 8), @truncate(tok >> 10) },
            2 => {
                const c: u2 = @truncate(tok >> 4);
                o.swizzle = .{ c, c, c, c };
                o.mask = @as(u4, 1) << c;
            },
            else => return error.BadToken,
        }
    }
    o.dims = @truncate(tok >> 20);
    if (tok & 0x8000_0000 != 0) {
        if (p.* >= raw.len) return error.Truncated;
        const e = raw[p.*];
        p.* += 1;
        if (e & 0x3f == 1) {
            const m = (e >> 6) & 0xff;
            o.neg = m == 1 or m == 3;
            o.abs = m == 2 or m == 3;
        }
    }
    // immediates' values
    if (o.reg == .immediate32) {
        const n: usize = if (o.comps == 0) 0 else o.comps;
        if (p.* + n > raw.len) return error.Truncated;
        for (0..n) |i| o.imm[i] = raw[p.* + i];
        p.* += n;
        return o;
    }
    if (o.reg == .immediate64) return error.BadToken;
    var d: u2 = 0;
    while (d < o.dims) : (d += 1) {
        const rep = (tok >> (22 + @as(u5, d) * 3)) & 7;
        var ix = Index{};
        switch (rep) {
            0 => {
                if (p.* >= raw.len) return error.Truncated;
                ix.imm = raw[p.*];
                p.* += 1;
            },
            2, 3 => {
                if (rep == 3) {
                    if (p.* >= raw.len) return error.Truncated;
                    ix.imm = raw[p.*];
                    p.* += 1;
                }
                const rel = try operand(raw, p);
                if (rel.comps == 4 and rel.swizzle[0] != rel.swizzle[1] and rel.mask != 0xf) return error.BadToken;
                ix.rel = true;
                ix.rel_reg = rel.reg;
                ix.rel_num = rel.index[0].imm;
                ix.rel_num2 = rel.index[1].imm;
                ix.rel_comp = rel.swizzle[0];
            },
            else => return error.BadToken,
        }
        o.index[d] = ix;
    }
    return o;
}

// ── Tests: shaders compiled by Microsoft's compiler (fxc's, D3DCompiler_47) ─

const testing = std.testing;
const fixtures = @import("fixtures.sig");

fn ops(blob: []const u8, out: []Op) !usize {
    const c = try Container.parse(blob);
    var r = (try c.program()).reader();
    var n: usize = 0;
    while (try r.next()) |i| {
        out[n] = i.op;
        n += 1;
    }
    return n;
}

test "a vertex shader: its signatures and program" {
    const c = try Container.parse(&fixtures.vs40);
    const p = try c.program();
    try testing.expectEqual(Stage.vertex, p.stage);
    try testing.expectEqual(@as(u8, 4), p.major);
    const in = c.signature(false).?;
    try testing.expectEqual(@as(u32, 2), in.count);
    try testing.expectEqualStrings("POSITION", in.get(0).?.name);
    try testing.expectEqualStrings("COLOR", in.get(1).?.name);
    try testing.expectEqual(@as(u8, 0x7), in.get(0).?.mask);
    const out = c.signature(true).?;
    try testing.expectEqual(SysValue.position, out.get(0).?.sys);
    try testing.expectEqualStrings("SV_Position", out.get(0).?.name);
    var o: [32]Op = undefined;
    const n = try ops(&fixtures.vs40, &o);
    const want = [_]Op{ .dcl_constant_buffer, .dcl_input, .dcl_input, .dcl_output_siv, .dcl_output, .dcl_temps, .mov, .mov, .dp4, .dp4, .dp4, .dp4, .mov, .ret };
    try testing.expectEqualSlices(Op, &want, o[0..n]);
}

test "operands: masks, swizzles, immediates, constant buffers" {
    const c = try Container.parse(&fixtures.vs40);
    var r = (try c.program()).reader();
    var seen: usize = 0;
    while (try r.next()) |i| {
        switch (i.op) {
            .mov => if (seen == 0) {
                // mov r0.xyz, v0.xyzx
                try testing.expectEqual(Reg.temp, i.operands[0].reg);
                try testing.expectEqual(@as(u4, 0x7), i.operands[0].mask);
                try testing.expectEqual(Reg.input, i.operands[1].reg);
                try testing.expectEqual([4]u2{ 0, 1, 2, 0 }, i.operands[1].swizzle);
                seen += 1;
            } else if (seen == 1) {
                // mov r0.w, l(1.0)
                try testing.expectEqual(@as(u4, 0x8), i.operands[0].mask);
                try testing.expectEqual(Reg.immediate32, i.operands[1].reg);
                try testing.expectEqual(@as(u32, 0x3f80_0000), i.operands[1].imm[0]);
                seen += 1;
            },
            .dp4 => if (seen == 2) {
                // dp4 o0.x, r0.xyzw, cb0[0].xyzw
                try testing.expectEqual(Reg.output, i.operands[0].reg);
                try testing.expectEqual(Reg.constant_buffer, i.operands[2].reg);
                try testing.expectEqual(@as(u2, 2), i.operands[2].dims);
                try testing.expectEqual(@as(u32, 0), i.operands[2].index[0].imm);
                try testing.expectEqual(@as(u32, 0), i.operands[2].index[1].imm);
                seen += 1;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a pixel shader: sample, discard, a loop, the immediate constant buffer" {
    var o: [48]Op = undefined;
    const n = try ops(&fixtures.pstex40, &o);
    const want = [_]Op{ .customdata, .dcl_constant_buffer, .dcl_sampler, .dcl_resource, .dcl_input_ps, .dcl_output, .dcl_temps, .sample, .lt, .discard, .mov, .loop, .ige, .breakc, .dp4, .iadd, .itof, .mad, .endloop, .mul, .frc, .ret };
    try testing.expectEqualSlices(Op, &want, o[0..n]);
    const c = try Container.parse(&fixtures.pstex40);
    var r = (try c.program()).reader();
    while (try r.next()) |i| {
        switch (i.op) {
            .customdata => {
                try testing.expect(i.nonzero); // (an immediate constant buffer)
                try testing.expectEqual(@as(usize, 16), i.data.len);
                try testing.expectEqual(@as(u32, 0x3f80_0000), i.data[0]);
                try testing.expectEqual(@as(u32, 0x3f80_0000), i.data[5]);
            },
            .discard, .breakc => try testing.expect(i.nonzero),
            .dp4 => {
                // dp4 r1.z, r0.xyzw, icb[r1.y + 0].xyzw
                const icb = i.operands[2];
                try testing.expectEqual(Reg.immediate_constant_buffer, icb.reg);
                try testing.expect(icb.index[0].rel);
                try testing.expectEqual(Reg.temp, icb.index[0].rel_reg);
                try testing.expectEqual(@as(u32, 1), icb.index[0].rel_num);
                try testing.expectEqual(@as(u2, 1), icb.index[0].rel_comp);
            },
            .sample => {
                try testing.expectEqual(Reg.resource, i.operands[2].reg);
                try testing.expectEqual(Reg.sampler, i.operands[3].reg);
            },
            else => {},
        }
    }
}

test "integer ops: modifiers, udiv's two destinations, movc" {
    var o: [48]Op = undefined;
    const n = try ops(&fixtures.psint40, &o);
    const want = [_]Op{ .dcl_input_ps, .dcl_output, .dcl_temps, .mul, .ftoi, .ftou, .iadd, .xor, .imax, .@"and", .udiv, .itof, .mul, .ineg, .movc, .itof, .mul, .ishl, .ushr, .@"and", .movc, .xor, .@"or", .utof, .mul, .ret };
    try testing.expectEqualSlices(Op, &want, o[0..n]);
    const c = try Container.parse(&fixtures.psint40);
    var r = (try c.program()).reader();
    while (try r.next()) |i| {
        switch (i.op) {
            .imax => try testing.expect(i.operands[2].neg), // imax r0.y, r0.y, -r0.y
            .udiv => {
                try testing.expectEqual(@as(u8, 4), i.n);
                try testing.expectEqual(Reg.null, i.operands[1].reg);
            },
            else => {},
        }
    }
}

test "Shader Model 5 (SHEX, the same tokens)" {
    var o: [48]Op = undefined;
    const n = try ops(&fixtures.pstex50, &o);
    try testing.expect(n > 10);
    const c = try Container.parse(&fixtures.vs50);
    try testing.expectEqual(@as(u8, 5), (try c.program()).major);
}

test "damaged blobs are refused, never read past" {
    try testing.expectError(error.NotDxbc, Container.parse("DXBD"));
    var b = fixtures.vs40;
    std.mem.writeInt(u32, b[24..28], 0x7fff_ffff, .little);
    try testing.expectError(error.Truncated, Container.parse(&b));
    var c = fixtures.vs40;
    // (the first chunk's offset past the end)
    std.mem.writeInt(u32, c[32..36], @intCast(c.len), .little);
    try testing.expectError(error.Truncated, Container.parse(&c));
}
