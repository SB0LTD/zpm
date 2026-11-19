//! @zpm/ps5gfx recompile — a PS5 shader's machine code (AMD gfx10, LLVM's
//! gfx1013) as the 3D engine's shader code: KIR emitted into the raster's
//! kernels (gfxapi/raster.sig), so a game's draws run on the same engine as
//! GL's and Direct3D's, on any GPU or the CPU.
//!
//! One lane of the shader is one KIR thread. A shader's instructions are
//! split in two by what they touch:
//!
//! - **The scalar side** (SOP1, SOP2, SOPC, SOPK and the SMEM loads) reads
//!   only scalar registers, constants and memory: the same value for every
//!   lane. It is not translated. It runs on the CPU once a draw
//!   (recompile_scalar.sig), with the draw's user-data words as its first
//!   registers and the game's memory read through `Memory`: `evaluate`.
//! - **The lane side** (VOP1, VOP2, VOP3, VOPC, VINTRP, EXP, and the MUBUF
//!   and MTBUF loads) becomes KIR (recompile_emit.sig). Each VGPR is a KIR
//!   u32 register, reinterpreted as f32 where an instruction computes in
//!   floats.
//!
//! The two sides meet three ways, each found here by `analyse`:
//!
//! 1. A scalar register a lane instruction reads is a uniform word: a slot
//!    a read site gets (`Read`), shared by the reads of one definition (a
//!    register redefined between two reads gets two slots). The scalar run
//!    records its value; the KIR loads the word.
//! 2. A buffer descriptor (V#) a lane load reads through is a `Site`: the
//!    scalar run turns the descriptor into a window of game memory (an
//!    address and a size: a buffer binding) and three uniform words (the
//!    stride, the record count, the window's bytes). The KIR computes the
//!    byte offset itself and checks it against the window: a load outside
//!    gives 0, as the hardware's does. What the emitted code depends on
//!    (a format load's format and channel routing, which window a site
//!    reads) is hashed into `Evaluation.key`: when it changes, the caller
//!    builds the pipeline again.
//! 3. A lane mask (what a compare writes into VCC or an SGPR pair) is one
//!    KIR pred register a lane. The scalar logic applied to masks (s_and,
//!    s_or, s_xor, s_andn2, s_orn2, s_not, s_mov) becomes pred logic. So
//!    the analysis knows, for every scalar register at every point,
//!    whether it holds a scalar or a mask; EXEC is always a mask (every
//!    lane), and the constants 0 and -1 may stand for no lane and every
//!    lane. Any other mixing of the two in one instruction is refused.
//!
//! The invariant that lets one compiled pipeline serve every draw with the
//! same key: the emitters read from an `Evaluation` only what `key` covers.
//! Every per-draw value (a scalar, a descriptor's stride and size, the
//! base vertex) reaches the KIR as a uniform word.
//!
//! Entry and exit: the vertex side's v5 is the vertex index and v8 the
//! instance index (the engine's ids plus a base vertex and a first
//! instance word), its user data start at s8; `exp pos0` is the position
//! and `exp paramN` varyings 4N..4N+3. The pixel shader's user data start
//! at s0, its entry VGPRs are placed by `state.PixelSetup`; `v_interp_*`
//! read the engine's interpolated varying (input N, channel c is varying
//! 4 * slot + c, `state.PixelInput`); `exp mrtN` is target N's colour
//! (`compr`: two halves a word), `exp mrtz` the depth.
//!
//! Not here: branches and any write to EXEC (straight-line code only),
//! calls and jumps; image instructions (textures), LDS, GDS, stores and
//! atomics; the 16-bit and 64-bit VALU ops, DPP, v_readlane and kin, a
//! carry in (v_add_co_ci_u32); `exp pos1..3` and `exp prim` (skipped:
//! point size, clip distances and the NGG primitive export are not
//! used); swizzled buffers and add_tid; the packed buffer formats
//! (10_11_11, 2_10_10_10 and kin); a V#'s oob_select (every load is
//! checked against the window's bytes and, when indexed with a stride,
//! the record count); windows shared between the two stages (each
//! stage's identical windows share a binding, the stages' do not).
//! Pixel shaders: the f16 interpolation modes; linear (not perspective)
//! interpolation (which I/J pair v_interp_p1/p2 read is not looked at: the
//! engine interpolates every smooth varying with perspective);
//! v_interp_mov_f32's P10 and P20, and its P0 of a smooth input;
//! SPI_BARYC_CNTL (the position is the pixel's centre, the facing is
//! +1.0 or -1.0, never FRONT_FACE_ALL_BITS's integer); the 16-bit colour
//! formats other than FP16_ABGR; dropping pixels (EXEC is never written,
//! so nothing is killed); an each-vertex input interpolated by
//! v_interp_p1/p2. KIR's own rules, not this file's: a NaN's payload (KIR
//! gives its own NaN), and multiply-adds (KIR's fmad, rounded once or
//! twice by the device).
//!
//! Lane masks are tracked at the wave's width (`analyse`'s lanes): in
//! 64-lane code a compare writes a pair, and only the _b64 logic on whole
//! pairs written by one instruction is translated; in 32-lane code a mask
//! is one register and only the _b32 logic. Touching part of a mask, a
//! mask at the wrong width, a scalar instruction reading a mask register,
//! or a pair made of two masks' halves is refused by name; a scalar write
//! to one half of a pair leaves the other half unusable as a mask. A
//! scalar made all ones or all zeros at a mask's width by scalar
//! instructions (`s_cselect_b64 s[4:5], -1, 0` with a scalar SCC) is a
//! uniform mask: a pred from its uniform word.
//!
//! Allocation-free: a Program and an Evaluation are fixed-size values the
//! caller owns; nothing in them points anywhere.

const std = @import("std");
const amdgpu = @import("amdgpu");
const gfxapi = @import("gfxapi");
const gpu = @import("gpu");
pub const state = @import("state.sig");
const scalar = @import("recompile_scalar.sig");
const emit = @import("recompile_emit.sig");

pub const gfx10 = amdgpu.gfx10;
const kir = gpu.kir;
const raster = gfxapi.raster;
const Instr = gfx10.Instr;

pub const Stage = enum { vertex, pixel };

pub const Error = error{
    /// An instruction, an operand or a descriptor this cut does not
    /// translate (the Log names it).
    Unsupported,
    /// More code, read sites or buffer loads than a Program holds.
    TooLong,
    /// Words that are not gfx10 instructions, or code without s_endpgm.
    BadCode,
    /// The game's memory could not be read where the scalar side loads
    /// (not in the brief's set: a draw's bad pointer is neither code nor
    /// an unsupported feature).
    BadMemory,
};

/// Instructions a Program holds.
pub const MAX_INSTS = 768;
/// Uniform read slots (scalar values lane code reads) a Program holds.
pub const MAX_READS = 96;
/// Lane buffer loads a Program holds.
pub const MAX_SITES = 32;
/// Windows (buffer bindings) one stage's loads may read at once: the two
/// stages' together are the engine's raster.MAX_BUFFERS.
pub const MAX_WINDOWS = 16;
/// The largest window a descriptor may make (256 MiB): a V# with no
/// stride and a record count near 2^32 (a common "no limit" descriptor)
/// would otherwise ask the caller to hand over 4 GiB. A larger one is
/// refused with a message.
pub const MAX_WINDOW_BYTES: u32 = 256 << 20;
/// Uniform words a stage's evaluation gives: the read slots, then three
/// words a site (stride, records, bytes).
pub const MAX_WORDS = MAX_READS + 3 * MAX_SITES;
pub const NO_SLOT: u16 = 0xffff;
pub const NO_SITE: u8 = 0xff;
/// A site whose window is empty: its loads give 0 (no binding).
pub const NO_WINDOW: u8 = 0xff;

/// Why an analysis or an evaluation failed.
pub const Log = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(l: *const Log) []const u8 {
        return l.buf[0..l.len];
    }

    pub fn set(l: *Log, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&l.buf, "ps5 recompile: " ++ fmt, args) catch {
            l.len = l.buf.len;
            return;
        };
        l.len = s.len;
    }
};

/// What an instruction is to the translation.
pub const Side = enum(u8) {
    /// no effect here (s_nop, s_waitcnt, s_sendmsg, exp prim, ...)
    skip,
    /// run on the CPU by the scalar interpreter
    scalar,
    /// emitted as KIR
    lane,
    /// scalar logic on lane masks: emitted as pred logic
    mask,
};

/// A scalar value lane code reads: register `reg` (a scalar operand code)
/// as it is just before instruction `at` runs. `ver` is the analysis's
/// count of the register's definitions there (reads of one definition
/// share a slot).
pub const Read = struct { reg: u16, ver: u16, at: u16 };

pub const SiteKind = enum(u8) {
    /// buffer_load_dword*, ubyte, sbyte, ushort, sshort
    raw,
    /// buffer_load_format_*: the V#'s format
    format,
    /// tbuffer_load_format_*: the instruction's format
    tformat,
};

/// A lane buffer load: its descriptor is the four registers from `rsrc`
/// just before instruction `at`.
pub const Site = struct { rsrc: u16, at: u16, kind: SiteKind };

/// The analysis of one shader's code: fixed capacity, caller-owned, no
/// pointers (the instructions are kept decoded).
pub const Program = struct {
    stage: Stage,
    /// lanes the code runs at once (32 or 64): a lane mask is one
    /// register or a pair
    lanes: u8,
    /// instructions up to and including s_endpgm
    n: u16,
    insts: [MAX_INSTS]Instr,
    side: [MAX_INSTS]Side,
    /// each instruction's first word, counted from the code's start
    word: [MAX_INSTS]u16,
    /// a lane instruction's read slot for each source (NO_SLOT: not a
    /// scalar register); a buffer load's soffset is source 2
    slot: [MAX_INSTS][3]u16,
    /// a buffer load's site
    site: [MAX_INSTS]u8,
    reads: [MAX_READS]Read,
    n_reads: u16,
    sites: [MAX_SITES]Site,
    n_sites: u8,
    /// vertex side: the params exported (bit N: exp paramN), and pos0
    params: u32,
    position: bool,
    /// pixel shader: the inputs read (bit N: attrN), the targets
    /// exported (bit N: exp mrtN), those exported compressed, and mrtz
    inputs: u32,
    /// the inputs v_interp_mov_f32 reads (one vertex's value: the input
    /// must be flat, or have no slot)
    flat_reads: u32,
    /// the inputs v_interp_p1/p2_f32 read (interpolated)
    interp_reads: u32,
    mrts: u8,
    compr: u8,
    mrtz: bool,

    /// The uniform words this stage's evaluation gives.
    pub fn words(p: *const Program) u32 {
        return @as(u32, p.n_reads) + 3 * @as(u32, p.n_sites);
    }
    /// The buffer bindings this stage takes (Pair lays them out).
    pub fn bindings(p: *const Program) u8 {
        return @min(p.n_sites, MAX_WINDOWS);
    }
    /// The first of site `s`'s three words (stride, records, bytes).
    pub fn siteWord(p: *const Program, s: u8) u32 {
        return @as(u32, p.n_reads) + 3 * @as(u32, s);
    }
};

/// Reads `out.len` bytes of the game's memory at `address`; false when it
/// cannot.
pub const Memory = struct {
    ctx: ?*anyopaque,
    read: *const fn (ctx: ?*anyopaque, address: u64, out: []u8) bool,
};

/// A range of game memory lane code reads (a buffer binding).
pub const Window = struct { address: u64, bytes: u32 };

/// One draw's values for one program.
pub const Evaluation = struct {
    /// the uniform words this stage reads, in slot order (Program.words)
    words: [MAX_WORDS]u32 = undefined,
    n_words: u32 = 0,
    /// the memory the lane code reads, one binding each
    windows: [MAX_WINDOWS]Window = undefined,
    n_windows: u8 = 0,
    // What the emitted code depends on, a site each (covered by `key`):
    /// the window a site reads (NO_WINDOW: none, its loads give 0)
    window_of: [MAX_SITES]u8 = undefined,
    /// a format load's format code (section 4.6 of the notes; kept for a
    /// descriptor that reads nothing too: its "one" channels are 1 in the
    /// format's kind) and its channel routing (the V#'s dst_sel, 12 bits)
    format: [MAX_SITES]u8 = undefined,
    dst_sel: [MAX_SITES]u16 = undefined,
    /// a hash of everything above that the emitted code depends on
    key: u64 = 0,
};

/// What the emitters are told about the pipeline around them.
pub const Layout = struct {
    /// this stage's first word in Draw.uniforms
    uniform_base: u32 = 0,
    /// this stage's first buffer among Shaders.buffers
    buffer_base: u8 = 0,
    // the vertex side
    /// the words (relative to uniform_base) holding the base vertex and
    /// the first instance, added to the engine's ids for v5 and v8
    base_vertex_word: u32 = 0,
    first_instance_word: u32 = 0,
    /// the pipeline's varyings (Shaders.varyings): those the code does
    /// not export are 0
    varyings: u8 = 0,
    // the pixel shader
    setup: state.PixelSetup = no_setup,
    inputs: [32]state.PixelInput = [_]state.PixelInput{no_input} ** 32,
    /// the pipeline takes the shader's depth (DB_SHADER_CONTROL's
    /// Z_EXPORT_ENABLE): exp mrtz is the fragment's depth
    depth_export: bool = false,
    /// the word (relative to uniform_base) holding the colour target's
    /// height in pixels as an f32: the engine counts y from the bottom
    /// (GL's way), the console from the top, so the pixel's console y is
    /// height - the engine's (render.sig: engine row y is console row
    /// height - y)
    height_word: u32 = 0,
    /// colour target 0 holds sRGB: the colour exported to it is encoded
    /// from linear before the engine stores it (render.Request.target_srgb)
    srgb: bool = false,
};

pub const no_setup = state.PixelSetup{ .inputs = 0, .lanes = 64, .enabled = 0, .placed = 0, .color_formats = 0, .may_kill = false, .writes_depth = false };
pub const no_input = state.PixelInput{ .slot = null, .flat = false, .default = 0, .halves = false };

/// The varyings a pixel shader's inputs make flat (raster.Shaders.flat):
/// bit 4 * slot + c for each channel of a flat (or each-vertex) input
/// that has a slot.
pub fn flatVaryings(lay: Layout) u64 {
    var m: u64 = 0;
    for (lay.inputs[0..@min(lay.setup.inputs, 32)]) |in| {
        const s = in.slot orelse continue;
        if (!in.flat and !in.each_vertex) continue;
        const first = 4 * @as(u32, s);
        if (first + 4 > 64) continue;
        m |= @as(u64, 0xf) << @intCast(first);
    }
    return m;
}

// ── The emitters ────────────────────────────────────────────────────────────

/// The vertex side's code as the raster's vertex code: io's position and
/// varyings set. Only the parts of `ev` its key covers are read. Never
/// fails: a Program that analysed is one these can emit.
pub fn emitVertex(p: *const Program, ev: *const Evaluation, lay: Layout, k: *kir.Kernel, io: *raster.VertexIO) void {
    emit.vertex(p, ev, lay, k, io);
}

/// The pixel shader's code as the raster's fragment code: io's colours
/// (and depth) set. As emitVertex; `checkPixel` is what makes the layout
/// one this can emit.
pub fn emitFragment(p: *const Program, ev: *const Evaluation, lay: Layout, k: *kir.Kernel, io: *raster.FragmentIO) void {
    emit.fragment(p, ev, lay, k, io);
}

// ── The analysis ────────────────────────────────────────────────────────────

const op = gfx10.op;

/// What a scalar register holds at a point of the code. A lane mask is
/// one register in 32-lane code (`one`) and a pair in 64-lane code (`lo`
/// and `hi`, written by one instruction). The `u` kinds are scalars a
/// scalar instruction made all ones or all zeros at a mask's width
/// (`s_cselect_b64 s[4:5], -1, 0` and kin): numbers to the scalar side,
/// and masks of every lane or none to the lane side.
const Kind = enum(u8) {
    scalar,
    lo,
    hi,
    one,
    ulo,
    uhi,
    uone,

    fn lane(k: Kind) bool {
        return k == .lo or k == .hi or k == .one;
    }
};

const Analysis = struct {
    p: *Program,
    why: *Log,
    kind: [128]Kind,
    /// the instruction that last wrote each register (a mask pair's two
    /// halves must come from one)
    def: [128]u16,
    ver: [128]u16,
    /// SCC was last set by logic on lane masks (it is a lane-dependent
    /// value no scalar instruction may read)
    scc_lane: bool,
    i: u16,
    at_word: u32,

    fn refuse(a: *Analysis, in: *const Instr, comptime why_fmt: []const u8, args: anytype) Error {
        var buf: [128]u8 = undefined;
        // (at the wave's width; a mask register the wave64 text cannot
        // name, an odd one, is printed as wave32's)
        const text = gfx10.formatWave(in, if (a.p.lanes == 64) .wave64 else .wave32, &buf) catch gfx10.formatWave(in, .wave32, &buf) catch "?";
        var msg: [160]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, why_fmt, args) catch "";
        a.why.set("'{s}' at word {d}: {s}", .{ text, a.at_word, m });
        return error.Unsupported;
    }

    /// Registers a lane mask takes.
    fn maskWidth(a: *const Analysis) u8 {
        return a.p.lanes / 32;
    }

    fn define(a: *Analysis, reg: u16, k: Kind) void {
        if (reg >= 128 or reg == gfx10.NULL) return;
        a.kind[reg] = k;
        a.def[reg] = a.i;
        a.ver[reg] +%= 1;
    }

    fn defineRange(a: *Analysis, reg: u16, n: u8, k: Kind) void {
        for (0..n) |j| a.define(reg + @as(u16, @intCast(j)), k);
    }

    /// `reg` (and the register after it in 64-lane code) now hold a mask
    /// this instruction made: a lane mask, or a uniform one.
    fn defineMask(a: *Analysis, reg: u16, uniform: bool) void {
        if (a.maskWidth() == 2) {
            a.define(reg, if (uniform) .ulo else .lo);
            a.define(reg + 1, if (uniform) .uhi else .hi);
        } else a.define(reg, if (uniform) .uone else .one);
    }

    /// The read slot for register `reg` as lane code reads it now.
    fn readSlot(a: *Analysis, reg: u16) Error!u16 {
        const p = a.p;
        for (p.reads[0..p.n_reads], 0..) |rd, s| {
            if (rd.reg == reg and rd.ver == a.ver[reg]) return @intCast(s);
        }
        if (p.n_reads >= MAX_READS) {
            a.why.set("more than {d} scalar values read by lane code", .{MAX_READS});
            return error.TooLong;
        }
        p.reads[p.n_reads] = .{ .reg = reg, .ver = a.ver[reg], .at = a.i };
        p.n_reads += 1;
        return p.n_reads - 1;
    }

    /// Registers `code` .. `code + n - 1` hold a whole mask of `lane`
    /// (or uniform) kind, written by one instruction.
    fn whole(a: *const Analysis, code: u16, n: u8, uniform: bool) bool {
        if (n != a.maskWidth()) return false;
        if (n == 1) return a.kind[code] == (if (uniform) Kind.uone else Kind.one);
        return a.kind[code] == (if (uniform) Kind.ulo else Kind.lo) and a.kind[code + 1] == (if (uniform) Kind.uhi else Kind.hi) and a.def[code] == a.def[code + 1];
    }
};

/// What an operand is to the scalar side and the masks.
const Operand = enum {
    /// a number
    scalar,
    /// a whole lane mask
    mask,
    /// a whole uniform mask (a number too)
    umask,
    /// the constants 0 and -1: no lane, every lane, or the numbers
    either,
    /// a register neither side models
    bad,
    /// part of a lane mask, a lane mask at the wrong width, or the halves
    /// of two
    part,
};

/// Operand `code` read `n` registers wide.
fn operandOf(a: *const Analysis, code: u16, n: u8) Operand {
    return switch (code) {
        // (EXEC: every lane, at the mask's width only)
        gfx10.EXEC_LO => if (n == a.maskWidth()) .mask else .bad,
        gfx10.EXEC_HI => .bad,
        128, 193 => .either,
        129...192, 194...208, 240...248, gfx10.LITERAL => .scalar,
        gfx10.SCC => .scalar,
        gfx10.NULL => .scalar,
        0...gfx10.SGPRS - 1, gfx10.VCC_LO, gfx10.VCC_HI, gfx10.M0 => blk: {
            if (@as(u32, code) + n > 128) break :blk .bad;
            var any_lane = false;
            for (0..n) |j| {
                if (a.kind[code + j].lane()) any_lane = true;
            }
            // (a register right after a 32-lane mask is its own: only a
            // read that covers a mask register is looked at)
            if (any_lane) break :blk if (a.whole(code, n, false)) .mask else .part;
            if (a.whole(code, n, true)) break :blk .umask;
            break :blk .scalar;
        },
        else => .bad,
    };
}

/// Analyses `code` (one stage's, from its first instruction to s_endpgm)
/// into `out`, for a wave of `lanes` lanes (32 or 64: a lane mask is one
/// register or a pair). `why` receives a message naming the instruction
/// when the answer is Unsupported, and the reason for the other errors.
pub fn analyse(code: []align(1) const u32, stage: Stage, lanes: u8, out: *Program, why: *Log) Error!void {
    if (lanes != 32 and lanes != 64) {
        why.set("a wave of {d} lanes (32 or 64)", .{lanes});
        return error.Unsupported;
    }
    out.stage = stage;
    out.lanes = lanes;
    out.n = 0;
    out.n_reads = 0;
    out.n_sites = 0;
    out.params = 0;
    out.position = false;
    out.inputs = 0;
    out.flat_reads = 0;
    out.interp_reads = 0;
    out.mrts = 0;
    out.compr = 0;
    out.mrtz = false;
    var a = Analysis{ .p = out, .why = why, .kind = [_]Kind{.scalar} ** 128, .def = [_]u16{0xffff} ** 128, .ver = [_]u16{0} ** 128, .scc_lane = false, .i = 0, .at_word = 0 };
    var w: usize = 0;
    while (true) {
        if (w >= code.len) {
            why.set("no s_endpgm before the code's end (word {d})", .{w});
            return error.BadCode;
        }
        if (out.n >= MAX_INSTS or w > 0xffff) {
            why.set("more than {d} instructions", .{MAX_INSTS});
            return error.TooLong;
        }
        // (the decoder takes aligned words: an instruction is 5 at most)
        var tmp: [8]u32 = undefined;
        const nw = @min(code.len - w, tmp.len);
        for (0..nw) |j| tmp[j] = code[w + j];
        const i = out.n;
        const in = &out.insts[i];
        const len = gfx10.decode(tmp[0..nw], in) catch {
            why.set("word {d} (0x{x:0>8}) is not a gfx10 instruction this decoder knows", .{ w, code[w] });
            return error.BadCode;
        };
        out.word[i] = @intCast(w);
        out.slot[i] = .{ NO_SLOT, NO_SLOT, NO_SLOT };
        out.site[i] = NO_SITE;
        a.i = i;
        a.at_word = @intCast(w);
        out.n += 1;
        w += len;
        const end = try classify(&a, in);
        if (end) return;
    }
}

/// Decides instruction `in`'s side and records what it reads and writes;
/// true at s_endpgm.
fn classify(a: *Analysis, in: *const Instr) Error!bool {
    const i = a.i;
    const p = a.p;
    p.side[i] = .skip;
    switch (in.enc()) {
        .sopp => {
            switch (in.op) {
                op("s_endpgm") => return true,
                // (waits, scheduling hints, and the vertex side's
                // allocation request: nothing a value depends on)
                op("s_nop"), op("s_waitcnt"), op("s_sendmsg"), op("s_waitcnt_depctr"), op("s_clause"), op("s_inst_prefetch"), op("s_setprio") => return false,
                op("s_branch"), op("s_cbranch_scc0"), op("s_cbranch_scc1"), op("s_cbranch_vccz"), op("s_cbranch_vccnz"), op("s_cbranch_execz"), op("s_cbranch_execnz") => return a.refuse(in, "branches are not translated (straight-line code only)", .{}),
                else => return a.refuse(in, "not translated", .{}),
            }
        },
        .sop1, .sop2, .sopc, .sopk => try classifySalu(a, in),
        .smem => try classifySmem(a, in),
        .vop1, .vop2, .vop3, .vopc => try classifyValu(a, in),
        .vintrp => {
            if (p.stage != .pixel) return a.refuse(in, "interpolation in a vertex shader", .{});
            if (in.attr >= 32) return a.refuse(in, "a pixel shader has 32 inputs", .{});
            const bit = @as(u32, 1) << @intCast(in.attr);
            p.inputs |= bit;
            if (in.op == op("v_interp_mov_f32")) {
                // (P10 and P20 are differences between the vertices'
                // values, which the engine does not keep)
                if (in.src[0] != 2) return a.refuse(in, "P10 and P20 are not translated", .{});
                p.flat_reads |= bit;
            } else p.interp_reads |= bit;
            p.side[i] = .lane;
        },
        .exp => try classifyExport(a, in),
        .mubuf, .mtbuf => try classifyBuffer(a, in),
        .mimg => return a.refuse(in, "image instructions are not translated", .{}),
    }
    return false;
}

fn isMaskLogic(o: gfx10.Op) bool {
    return switch (o) {
        op("s_and_b32"), op("s_and_b64"), op("s_or_b32"), op("s_or_b64"), op("s_xor_b32"), op("s_xor_b64"), op("s_andn2_b32"), op("s_andn2_b64"), op("s_orn2_b32"), op("s_orn2_b64"), op("s_not_b32"), op("s_not_b64"), op("s_mov_b32"), op("s_mov_b64") => true,
        else => false,
    };
}

/// The scalar instructions the interpreter runs.
pub fn isScalarOp(o: gfx10.Op) bool {
    return switch (o) {
        op("s_mov_b32"), op("s_mov_b64"), op("s_movk_i32"), op("s_not_b32"), op("s_not_b64"), op("s_getpc_b64"),
        op("s_add_u32"), op("s_sub_u32"), op("s_add_i32"), op("s_sub_i32"), op("s_addc_u32"), op("s_subb_u32"), op("s_addk_i32"), op("s_mul_i32"),
        op("s_and_b32"), op("s_or_b32"), op("s_xor_b32"), op("s_andn2_b32"), op("s_orn2_b32"),
        op("s_and_b64"), op("s_or_b64"), op("s_xor_b64"), op("s_andn2_b64"), op("s_orn2_b64"),
        op("s_lshl_b32"), op("s_lshr_b32"), op("s_ashr_i32"), op("s_lshl_b64"), op("s_lshr_b64"),
        op("s_lshl1_add_u32"), op("s_lshl2_add_u32"), op("s_lshl3_add_u32"), op("s_lshl4_add_u32"),
        op("s_bfe_u32"), op("s_bfe_i32"), op("s_bfm_b32"), op("s_min_i32"), op("s_min_u32"), op("s_max_i32"), op("s_max_u32"),
        op("s_cselect_b32"), op("s_cselect_b64"),
        op("s_cmp_eq_i32"), op("s_cmp_lg_i32"), op("s_cmp_gt_i32"), op("s_cmp_ge_i32"), op("s_cmp_lt_i32"), op("s_cmp_le_i32"),
        op("s_cmp_eq_u32"), op("s_cmp_lg_u32"), op("s_cmp_gt_u32"), op("s_cmp_ge_u32"), op("s_cmp_lt_u32"), op("s_cmp_le_u32"),
        op("s_cmp_eq_u64"), op("s_cmp_lg_u64"),
        op("s_cmpk_eq_i32"), op("s_cmpk_lg_i32"), op("s_cmpk_gt_i32"), op("s_cmpk_ge_i32"), op("s_cmpk_lt_i32"), op("s_cmpk_le_i32"),
        op("s_cmpk_eq_u32"), op("s_cmpk_lg_u32"), op("s_cmpk_gt_u32"), op("s_cmpk_ge_u32"), op("s_cmpk_lt_u32"), op("s_cmpk_le_u32"),
        => true,
        else => false,
    };
}

/// The instructions that read SCC.
fn readsScc(o: gfx10.Op) bool {
    return switch (o) {
        op("s_cselect_b32"), op("s_cselect_b64"), op("s_addc_u32"), op("s_subb_u32") => true,
        else => false,
    };
}

/// The instructions that leave SCC as it was.
fn keepsScc(o: gfx10.Op) bool {
    return switch (o) {
        op("s_mov_b32"), op("s_mov_b64"), op("s_movk_i32"), op("s_getpc_b64"), op("s_mul_i32"), op("s_bfm_b32"), op("s_cselect_b32"), op("s_cselect_b64") => true,
        else => false,
    };
}

fn isExec(code: u16) bool {
    return code == gfx10.EXEC_LO or code == gfx10.EXEC_HI;
}

fn classifySalu(a: *Analysis, in: *const Instr) Error!void {
    const df = in.d();
    const p = a.p;
    switch (in.op) {
        op("s_setpc_b64"), op("s_swappc_b64") => return a.refuse(in, "calls and jumps are not translated", .{}),
        op("s_waitcnt_vscnt"), op("s_waitcnt_vmcnt"), op("s_waitcnt_expcnt"), op("s_waitcnt_lgkmcnt") => return,
        else => {},
    }
    if (std.mem.indexOf(u8, df.name, "exec") != null) return a.refuse(in, "writes EXEC (straight-line code only)", .{});
    if (!isScalarOp(in.op)) return a.refuse(in, "not translated", .{});
    // the sources and their widths (SOPK's is its destination register)
    var srcs: [2]u16 = undefined;
    var widths: [2]u8 = undefined;
    var ns: usize = 0;
    switch (df.shape) {
        .sop2, .sopc => {
            srcs = .{ in.src[0], in.src[1] };
            widths = .{ @max(df.s[0].dwords(), 1), @max(df.s[1].dwords(), 1) };
            ns = 2;
        },
        .sop1 => {
            srcs[0] = in.src[0];
            widths[0] = @max(df.s[0].dwords(), 1);
            ns = 1;
        },
        .sopk => if (in.op != op("s_movk_i32")) {
            srcs[0] = in.dst;
            widths[0] = 1;
            ns = 1;
        },
        else => {},
    }
    // (s_cmpk_* only read their register; s_movk and s_addk write it)
    const writes = switch (df.shape) {
        .sop2, .sop1, .sop1_dst => true,
        .sopk => in.op == op("s_movk_i32") or in.op == op("s_addk_i32"),
        else => false,
    };
    const dw: u8 = @max(df.d.dwords(), 1);
    if (writes and (isExec(in.dst) or (dw == 2 and in.dst + 1 == gfx10.EXEC_LO))) return a.refuse(in, "writes EXEC (straight-line code only)", .{});
    if (writes and in.dst >= gfx10.TTMP0 and in.dst < gfx10.TTMP0 + 16) return a.refuse(in, "writes a trap register", .{});
    // lane masks in, lane masks out?
    var kinds: [2]Operand = undefined;
    var masks = false;
    for (0..ns) |j| {
        kinds[j] = operandOf(a, srcs[j], widths[j]);
        switch (kinds[j]) {
            .mask => masks = true,
            .bad => return a.refuse(in, "reads a register the scalar side does not model (EXEC only as a whole {d}-lane mask)", .{p.lanes}),
            .part => return a.refuse(in, "reads part of a lane mask, or one at the wrong width for {d}-lane code", .{p.lanes}),
            else => {},
        }
    }
    if (masks) {
        if (!isMaskLogic(in.op)) return a.refuse(in, "uses a lane mask as a scalar value", .{});
        for (0..ns) |j| {
            switch (kinds[j]) {
                .scalar => return a.refuse(in, "mixes a lane mask with a scalar value", .{}),
                // (a uniform mask: a pred from its word)
                .umask => a.p.slot[a.i][j] = try a.readSlot(srcs[j]),
                else => {},
            }
        }
        p.side[a.i] = .mask;
        a.defineMask(in.dst, false);
        if (in.op != op("s_mov_b32") and in.op != op("s_mov_b64")) a.scc_lane = true;
        return;
    }
    if (readsScc(in.op) and a.scc_lane) return a.refuse(in, "reads SCC set by logic on lane masks", .{});
    for (srcs[0..ns]) |c| {
        if (c == gfx10.SCC and a.scc_lane) return a.refuse(in, "reads SCC set by logic on lane masks", .{});
    }
    p.side[a.i] = .scalar;
    if (writes) {
        // a number that is all ones or all zeros at a mask's width, made
        // from such numbers: a uniform mask too
        var uniform = dw == a.maskWidth() and (in.op == op("s_cselect_b32") or in.op == op("s_cselect_b64") or isMaskLogic(in.op));
        for (0..ns) |j| {
            if (kinds[j] != .either and kinds[j] != .umask) uniform = false;
        }
        if (uniform) a.defineMask(in.dst, true) else a.defineRange(in.dst, dw, .scalar);
    }
    if (!keepsScc(in.op)) a.scc_lane = false;
}

/// Whether registers `code` .. `code + n - 1` hold numbers (no lane mask).
fn scalarRegs(a: *const Analysis, code: u16, n: u8) bool {
    for (0..n) |j| {
        const c = @as(usize, code) + j;
        if (c >= 128 or (c >= gfx10.TTMP0 and c < gfx10.TTMP0 + 16) or c == gfx10.NULL or isExec(@intCast(c)) or a.kind[c].lane()) return false;
    }
    return true;
}

fn classifySmem(a: *Analysis, in: *const Instr) Error!void {
    const df = in.d();
    switch (in.op) {
        op("s_load_dword"), op("s_load_dwordx2"), op("s_load_dwordx4"), op("s_load_dwordx8"), op("s_load_dwordx16"), op("s_buffer_load_dword"), op("s_buffer_load_dwordx2"), op("s_buffer_load_dwordx4"), op("s_buffer_load_dwordx8"), op("s_buffer_load_dwordx16") => {},
        else => return a.refuse(in, "not translated", .{}),
    }
    if (!scalarRegs(a, in.src[0], df.s[0].dwords())) return a.refuse(in, "its address is not in scalar registers", .{});
    if (in.src[1] != gfx10.NULL and !scalarRegs(a, in.src[1], 1)) return a.refuse(in, "its offset is not a scalar register", .{});
    if (isExec(in.dst) or (in.dst < gfx10.EXEC_LO and in.dst + df.d.dwords() > gfx10.EXEC_LO)) return a.refuse(in, "writes EXEC (straight-line code only)", .{});
    a.p.side[a.i] = .scalar;
    a.defineRange(in.dst, df.d.dwords(), .scalar);
}

/// The VALU instructions the emitter translates.
pub fn isLaneOp(o: gfx10.Op) bool {
    return switch (o) {
        op("v_mov_b32"), op("v_add_f32"), op("v_sub_f32"), op("v_subrev_f32"), op("v_mul_f32"), op("v_mad_f32"), op("v_fma_f32"), op("v_mac_f32"), op("v_fmac_f32"), op("v_madmk_f32"), op("v_madak_f32"),
        op("v_min_f32"), op("v_max_f32"), op("v_rcp_f32"), op("v_rsq_f32"), op("v_sqrt_f32"), op("v_floor_f32"), op("v_ceil_f32"), op("v_trunc_f32"), op("v_rndne_f32"), op("v_fract_f32"),
        op("v_cvt_f32_i32"), op("v_cvt_f32_u32"), op("v_cvt_i32_f32"), op("v_cvt_u32_f32"), op("v_cvt_pkrtz_f16_f32"),
        op("v_cvt_f32_ubyte0"), op("v_cvt_f32_ubyte1"), op("v_cvt_f32_ubyte2"), op("v_cvt_f32_ubyte3"),
        op("v_and_b32"), op("v_or_b32"), op("v_xor_b32"), op("v_not_b32"), op("v_lshlrev_b32"), op("v_lshrrev_b32"), op("v_ashrrev_i32"),
        op("v_add_nc_u32"), op("v_sub_nc_u32"), op("v_subrev_nc_u32"), op("v_add_co_u32"), op("v_sub_co_u32"), op("v_subrev_co_u32"),
        op("v_mul_lo_u32"), op("v_mul_hi_u32"), op("v_mul_u32_u24"), op("v_mul_i32_i24"), op("v_mad_u32_u24"),
        op("v_bfe_u32"), op("v_bfe_i32"), op("v_bfm_b32"), op("v_bfi_b32"), op("v_lshl_add_u32"), op("v_lshl_or_b32"), op("v_and_or_b32"), op("v_add3_u32"),
        op("v_min_i32"), op("v_max_i32"), op("v_min_u32"), op("v_max_u32"),
        op("v_cndmask_b32"),
        => true,
        else => isCompare(o),
    };
}

pub fn isCompare(o: gfx10.Op) bool {
    const df = gfx10.def(o);
    if (df.shape != .vopc) return false;
    const n = df.name;
    if (!std.mem.startsWith(u8, n, "v_cmp_")) return false;
    if (std.mem.startsWith(u8, n, "v_cmp_class")) return false;
    return std.mem.endsWith(u8, n, "_f32") or std.mem.endsWith(u8, n, "_i32") or std.mem.endsWith(u8, n, "_u32");
}

/// Ops whose result is a float (clamp and omod apply).
pub fn floatResult(o: gfx10.Op) bool {
    return gfx10.def(o).d == .f32;
}

fn classifyValu(a: *Analysis, in: *const Instr) Error!void {
    const df = in.d();
    const p = a.p;
    if (df.shape == .vopcx) return a.refuse(in, "writes EXEC (straight-line code only)", .{});
    if (df.shape == .vop_sdst) return a.refuse(in, "writes a scalar register from a lane", .{});
    if (in.op == op("v_nop")) return;
    if (!isLaneOp(in.op)) return a.refuse(in, "not translated", .{});
    if (in.op_sel != 0) return a.refuse(in, "op_sel is not translated", .{});
    // (clamp and omod are translated on float results only)
    if ((in.clamp or in.omod != 0) and !floatResult(in.op)) return a.refuse(in, "clamp or omod on a result that is not a float", .{});
    // sources
    const ns: usize = df.nsrc();
    for (0..ns) |ix| {
        const c = in.src[ix];
        if (c >= gfx10.VGPR0) continue;
        switch (c) {
            128...208, 240...248, gfx10.LITERAL => continue,
            gfx10.SCC, gfx10.NULL => return a.refuse(in, "reads SCC or null as a lane value", .{}),
            else => {},
        }
        switch (operandOf(a, c, 1)) {
            .scalar, .umask => p.slot[a.i][ix] = try a.readSlot(c),
            .mask, .part => return a.refuse(in, "reads a lane mask as a value", .{}),
            else => return a.refuse(in, "reads a register lane code does not model", .{}),
        }
    }
    if (df.shape == .vop_carry_in) return a.refuse(in, "a carry-in is not translated", .{});
    if (df.shape == .vop_cndmask) {
        switch (operandOf(a, in.src[2], a.maskWidth())) {
            .mask, .either => {},
            .umask => p.slot[a.i][2] = try a.readSlot(in.src[2]),
            .part => return a.refuse(in, "its mask is part of a lane mask, or one at the wrong width for {d}-lane code", .{p.lanes}),
            else => return a.refuse(in, "its mask is not a lane mask", .{}),
        }
    }
    // destinations: a compare's or a carry's mask
    if (df.shape == .vopc or df.shape == .vop_carry) {
        const d = in.sdst;
        if (isExec(d) or (a.maskWidth() == 2 and d + 1 == gfx10.EXEC_LO)) return a.refuse(in, "writes EXEC (straight-line code only)", .{});
        if (d != gfx10.NULL) {
            if (a.maskWidth() == 2 and d % 2 != 0) return a.refuse(in, "a 64-lane mask into an odd register", .{});
            if (d >= gfx10.TTMP0 and d != gfx10.VCC_LO and d != gfx10.VCC_HI) return a.refuse(in, "a mask into a register lane masks are not kept in", .{});
            a.defineMask(d, false);
        }
    }
    p.side[a.i] = .lane;
}

fn classifyExport(a: *Analysis, in: *const Instr) Error!void {
    const p = a.p;
    const t = in.target;
    switch (p.stage) {
        .vertex => switch (t) {
            12 => {
                if (in.compr) return a.refuse(in, "a compressed position", .{});
                p.position = true;
                p.side[a.i] = .lane;
            },
            // (pos1..3: point size, clip distances; prim: NGG's primitive
            // export; null)
            9, 13...16, 20 => {},
            32...63 => {
                if (in.compr) return a.refuse(in, "a compressed parameter", .{});
                p.params |= @as(u32, 1) << @intCast(t - 32);
                p.side[a.i] = .lane;
            },
            else => return a.refuse(in, "not a vertex-side export", .{}),
        },
        .pixel => switch (t) {
            0...7 => {
                p.mrts |= @as(u8, 1) << @intCast(t);
                if (in.compr) p.compr |= @as(u8, 1) << @intCast(t) else p.compr &= ~(@as(u8, 1) << @intCast(t));
                p.side[a.i] = .lane;
            },
            8 => {
                if (in.compr) return a.refuse(in, "a compressed depth", .{});
                p.mrtz = true;
                p.side[a.i] = .lane;
            },
            9 => {},
            else => return a.refuse(in, "not a pixel shader export", .{}),
        },
    }
}

fn classifyBuffer(a: *Analysis, in: *const Instr) Error!void {
    const p = a.p;
    const kind: SiteKind = switch (in.op) {
        op("buffer_load_dword"), op("buffer_load_dwordx2"), op("buffer_load_dwordx3"), op("buffer_load_dwordx4"), op("buffer_load_ubyte"), op("buffer_load_sbyte"), op("buffer_load_ushort"), op("buffer_load_sshort") => .raw,
        op("buffer_load_format_x"), op("buffer_load_format_xy"), op("buffer_load_format_xyz"), op("buffer_load_format_xyzw") => .format,
        op("tbuffer_load_format_x"), op("tbuffer_load_format_xy"), op("tbuffer_load_format_xyz"), op("tbuffer_load_format_xyzw") => .tformat,
        else => return a.refuse(in, "not translated (loads only)", .{}),
    };
    if (in.tfe or in.lwe) return a.refuse(in, "tfe and lwe are not translated", .{});
    if (in.src[1] + 4 > gfx10.SGPRS or !scalarRegs(a, in.src[1], 4)) return a.refuse(in, "its descriptor is not in scalar registers", .{});
    const so = in.src[2];
    switch (so) {
        128...208, 240...248, gfx10.NULL => {},
        else => switch (operandOf(a, so, 1)) {
            .scalar, .umask => p.slot[a.i][2] = try a.readSlot(so),
            else => return a.refuse(in, "its offset is not a scalar value", .{}),
        },
    }
    if (p.n_sites >= MAX_SITES) {
        a.why.set("more than {d} buffer loads", .{MAX_SITES});
        return error.TooLong;
    }
    p.sites[p.n_sites] = .{ .rsrc = in.src[1], .at = a.i, .kind = kind };
    p.site[a.i] = p.n_sites;
    p.n_sites += 1;
    p.side[a.i] = .lane;
}

/// Whether the emitter can draw the pixel shader `p` in layout `lay`: the
/// inputs it reads are in the setup and 32-bit, each exported target's
/// colour format (SPI_SHADER_COL_FORMAT) is one this unpacks.
pub fn checkPixel(p: *const Program, lay: Layout, why: *Log) Error!void {
    var ins = p.inputs;
    while (ins != 0) {
        const n: u5 = @intCast(@ctz(ins));
        ins &= ins - 1;
        if (n >= lay.setup.inputs) {
            why.set("the shader reads input {d}, the setup has {d}", .{ n, lay.setup.inputs });
            return error.Unsupported;
        }
        if (lay.inputs[n].halves) {
            why.set("input {d} is interpolated as 16-bit halves", .{n});
            return error.Unsupported;
        }
        // (v_interp_mov_f32 p0 is the first vertex's value: the engine
        // has it only where every vertex's is the provoking one's)
        if ((p.flat_reads >> n) & 1 != 0 and lay.inputs[n].slot != null and !lay.inputs[n].flat and !lay.inputs[n].each_vertex) {
            why.set("v_interp_mov_f32 reads input {d}, which is not flat", .{n});
            return error.Unsupported;
        }
        // (an each-vertex input hands the shader the three vertices'
        // values to combine itself; the engine has only one of them)
        if ((p.interp_reads >> n) & 1 != 0 and lay.inputs[n].slot != null and lay.inputs[n].each_vertex) {
            why.set("v_interp_p1/p2 interpolate input {d}, whose values are each vertex's", .{n});
            return error.Unsupported;
        }
    }
    for (0..8) |t| {
        if ((p.mrts >> @intCast(t)) & 1 == 0) continue;
        const cf: u4 = @truncate(lay.setup.color_formats >> @intCast(4 * t));
        const compr = (p.compr >> @intCast(t)) & 1 != 0;
        const ok = if (compr) cf == 4 or cf == 0 else (cf == 0 or cf == 1 or cf == 2 or cf == 3 or cf == 9);
        if (!ok) {
            why.set("mrt{d}: colour format {d} with {s} export", .{ t, cf, if (compr) "a compressed" else "a 32-bit" });
            return error.Unsupported;
        }
    }
}

// ── The scalar side ─────────────────────────────────────────────────────────

pub const Scalar = scalar.Scalar;

/// Runs the scalar side of `p` with `user` as its user data (in s8.. for
/// the vertex side, s0.. for the pixel shader), the code at
/// `code_address` (s_getpc), memory read through `mem`; `out` receives the
/// uniform words, windows and key the lane code needs for this draw.
pub fn evaluate(p: *const Program, user: []const u32, code_address: u64, mem: Memory, out: *Evaluation, why: *Log) Error!void {
    var regs: Scalar = .{};
    try scalar.run(p, user, code_address, mem, &regs, out, why);
}

/// The scalar side alone, its registers at s_endpgm into `regs` (for
/// tests and tools): evaluate without the evaluation.
pub fn runScalar(p: *const Program, user: []const u32, code_address: u64, mem: Memory, regs: *Scalar, why: *Log) Error!void {
    try scalar.run(p, user, code_address, mem, regs, null, why);
}

// ── Buffer formats ──────────────────────────────────────────────────────────

pub const Nfmt = enum(u8) { unorm, snorm, uscaled, sscaled, uint, sint, float };

/// A buffer format the emitter converts: `comps` components of `bits` each.
pub const Format = struct { bits: u8, comps: u8, nfmt: Nfmt };

const Family = struct { first: u8, last: u8, name: []const u8, nfmt0: u8, bits: u8, comps: u8 };

/// Section 4.6's unified buffer formats up to 77, by family; bits 0: a
/// packed family this does not convert.
const families = [_]Family{
    .{ .first = 1, .last = 6, .name = "8", .nfmt0 = 0, .bits = 8, .comps = 1 },
    .{ .first = 7, .last = 13, .name = "16", .nfmt0 = 0, .bits = 16, .comps = 1 },
    .{ .first = 14, .last = 19, .name = "8_8", .nfmt0 = 0, .bits = 8, .comps = 2 },
    .{ .first = 20, .last = 22, .name = "32", .nfmt0 = 4, .bits = 32, .comps = 1 },
    .{ .first = 23, .last = 29, .name = "16_16", .nfmt0 = 0, .bits = 16, .comps = 2 },
    .{ .first = 30, .last = 36, .name = "10_11_11", .nfmt0 = 0, .bits = 0, .comps = 3 },
    .{ .first = 37, .last = 43, .name = "11_11_10", .nfmt0 = 0, .bits = 0, .comps = 3 },
    .{ .first = 44, .last = 49, .name = "10_10_10_2", .nfmt0 = 0, .bits = 0, .comps = 4 },
    .{ .first = 50, .last = 55, .name = "2_10_10_10", .nfmt0 = 0, .bits = 0, .comps = 4 },
    .{ .first = 56, .last = 61, .name = "8_8_8_8", .nfmt0 = 0, .bits = 8, .comps = 4 },
    .{ .first = 62, .last = 64, .name = "32_32", .nfmt0 = 4, .bits = 32, .comps = 2 },
    .{ .first = 65, .last = 71, .name = "16_16_16_16", .nfmt0 = 0, .bits = 16, .comps = 4 },
    .{ .first = 72, .last = 74, .name = "32_32_32", .nfmt0 = 4, .bits = 32, .comps = 3 },
    .{ .first = 75, .last = 77, .name = "32_32_32_32", .nfmt0 = 4, .bits = 32, .comps = 4 },
};

const nfmt_names = [_][]const u8{ "unorm", "snorm", "uscaled", "sscaled", "uint", "sint", "float" };

/// The format code `code` as the emitter converts it, or null.
pub fn formatOf(code: u8) ?Format {
    for (families) |fam| {
        if (code < fam.first or code > fam.last) continue;
        if (fam.bits == 0) return null;
        return .{ .bits = fam.bits, .comps = fam.comps, .nfmt = @enumFromInt(fam.nfmt0 + (code - fam.first)) };
    }
    return null;
}

/// A format code's name ("8_8_8_8 unorm"), into `buf`.
pub fn formatName(code: u8, buf: []u8) []const u8 {
    for (families) |fam| {
        if (code < fam.first or code > fam.last) continue;
        return std.fmt.bufPrint(buf, "{s} {s}", .{ fam.name, nfmt_names[fam.nfmt0 + (code - fam.first)] }) catch "?";
    }
    return std.fmt.bufPrint(buf, "code {d}", .{code}) catch "?";
}

// ── Two stages as one pipeline ──────────────────────────────────────────────

/// FNV-1a, a 64-bit word at a time (its bytes).
pub const Hash = struct {
    h: u64 = 0xcbf2_9ce4_8422_2325,

    pub fn add(x: *Hash, v: u64) void {
        var k: u64 = v;
        for (0..8) |_| {
            x.h ^= k & 0xff;
            x.h *%= 0x0000_0100_0000_01b3;
            k >>= 8;
        }
    }
};

/// A hash of everything in a Layout the emitted code depends on.
pub fn layoutKey(lay: Layout) u64 {
    var h = Hash{};
    h.add(lay.uniform_base);
    h.add(lay.buffer_base);
    h.add(lay.base_vertex_word);
    h.add(lay.first_instance_word);
    h.add(lay.varyings);
    h.add(lay.height_word);
    h.add(@intFromBool(lay.depth_export));
    h.add(@intFromBool(lay.srgb));
    const st = lay.setup;
    h.add(st.inputs);
    h.add(st.lanes);
    h.add(st.enabled);
    h.add(st.placed);
    h.add(st.color_formats);
    h.add(@intFromBool(st.may_kill));
    h.add(@intFromBool(st.writes_depth));
    for (lay.inputs) |in| {
        h.add(if (in.slot) |sl| @as(u64, sl) else 0xff);
        h.add(@intFromBool(in.flat));
        h.add(in.default);
        h.add(@intFromBool(in.halves));
        h.add(@intFromBool(in.each_vertex));
        h.add(@intFromBool(in.low_default));
        h.add(@intFromBool(in.high_default));
        h.add(in.default_high);
    }
    return h.h;
}

/// A vertex side and a pixel shader as one raster pipeline's emitters: it
/// owns both programs, their evaluations and their layouts. The uniform
/// words: the vertex side's, its base vertex and first instance words,
/// then the pixel shader's, then the target's height. The buffers: the
/// vertex side's bindings, then the pixel shader's. Big: keep it in
/// static storage.
///
/// A pipeline cache must key on all of: the identity of both stages'
/// code (its address and words, as analysed), `key()` (what a draw's
/// descriptors make the code depend on: re-evaluate every draw) and
/// `layoutKey()` (the pixel setup, every input, the colour formats, depth
/// export, sRGB, both stages' lanes, the varyings and the words' places).
/// Two draws equal in all three can share one built pipeline; per-draw
/// values reach it through `fillUniforms` and `window`.
pub const Pair = struct {
    vs: Program = undefined,
    ps: Program = undefined,
    vs_ev: Evaluation = .{},
    ps_ev: Evaluation = .{},
    vs_lay: Layout = .{},
    ps_lay: Layout = .{},
    varyings: u8 = 0,

    /// Analyses both stages' code and lays the pipeline out: the vertex
    /// side runs `vs_lanes` lanes at once (state.Stages.vertexLanes), the
    /// pixel shader `setup.lanes`. `setup` and `inputs` are the pixel
    /// shader's (state.pixelSetup, pixelInput); `srgb`: colour target 0
    /// holds sRGB (render.Request.target_srgb). An input whose slot the
    /// vertex side does not export reads its default value.
    pub fn init(pr: *Pair, vs_code: []align(1) const u32, vs_lanes: u8, ps_code: []align(1) const u32, setup: state.PixelSetup, inputs: []const state.PixelInput, srgb: bool, why: *Log) Error!void {
        try analyse(vs_code, .vertex, vs_lanes, &pr.vs, why);
        try analyse(ps_code, .pixel, setup.lanes, &pr.ps, why);
        pr.vs_ev = .{};
        pr.ps_ev = .{};
        const vw = pr.vs.words();
        pr.ps_lay = .{ .uniform_base = vw + 2, .buffer_base = pr.vs.bindings(), .setup = setup, .depth_export = setup.writes_depth, .height_word = pr.ps.words(), .srgb = srgb };
        for (inputs, 0..) |in, n| {
            if (n >= 32) break;
            var x = in;
            if (x.slot) |sl| {
                if ((pr.vs.params >> sl) & 1 == 0) x.slot = null;
            }
            pr.ps_lay.inputs[n] = x;
        }
        try checkPixel(&pr.ps, pr.ps_lay, why);
        // the varyings: every param exported
        const top: u32 = if (pr.vs.params == 0) 0 else 32 - @as(u32, @clz(pr.vs.params));
        if (4 * top > raster.MAX_VARYINGS) {
            why.set("{d} parameters: the engine takes {d}", .{ top, raster.MAX_VARYINGS / 4 });
            return error.Unsupported;
        }
        pr.varyings = @intCast(4 * top);
        pr.vs_lay = .{ .uniform_base = 0, .buffer_base = 0, .base_vertex_word = vw, .first_instance_word = vw + 1, .varyings = pr.varyings };
    }

    /// Runs both scalar sides for a draw; returns the pipeline's key (the
    /// two stages' keys mixed): when it is not the key the pipeline was
    /// built with, build it again.
    pub fn evaluate(pr: *Pair, vs_user: []const u32, vs_code_address: u64, ps_user: []const u32, ps_code_address: u64, mem: Memory, why: *Log) Error!u64 {
        try recompileEvaluate(&pr.vs, vs_user, vs_code_address, mem, &pr.vs_ev, why);
        try recompileEvaluate(&pr.ps, ps_user, ps_code_address, mem, &pr.ps_ev, why);
        return pr.key();
    }

    pub fn key(pr: *const Pair) u64 {
        return pr.vs_ev.key ^ std.math.rotl(u64, pr.ps_ev.key, 29) ^ 0x9e37_79b9_7f4a_7c15;
    }

    /// Everything in both layouts the emitted code depends on (with the
    /// stages' lanes).
    pub fn layoutKey(pr: *const Pair) u64 {
        var h = Hash{};
        h.add(recompileLayoutKey(pr.vs_lay));
        h.add(recompileLayoutKey(pr.ps_lay));
        h.add(pr.vs.lanes);
        h.add(pr.ps.lanes);
        return h.h;
    }

    /// The pixel shader reads a value that is one vertex's for a whole
    /// primitive (a flat input, or one marked each_vertex):
    /// render.Shading.flat.
    pub fn flat(pr: *const Pair) bool {
        for (pr.ps_lay.inputs, 0..) |in, n| {
            if ((pr.ps.inputs >> @intCast(n)) & 1 == 0) continue;
            if (in.slot != null and (in.flat or in.each_vertex)) return true;
        }
        return false;
    }

    /// The raster's shaders (the Pair must outlive the pipeline).
    pub fn shaders(pr: *const Pair) raster.Shaders {
        const fb = state.builtinRegister(pr.ps_lay.setup, state.BUILTIN.FRONT_FACE) != null;
        return .{
            .ctx = pr,
            .attrs = 0,
            .varyings = pr.varyings,
            .flat = flatVaryings(pr.ps_lay),
            .buffers = pr.bufferCount(),
            .frag_depth = pr.ps_lay.depth_export and pr.ps.mrtz,
            .front_facing = fb,
            .vertex = vtx,
            .fragment = frag,
        };
    }

    /// Words a draw's Draw.uniforms takes.
    pub fn uniformWords(pr: *const Pair) u32 {
        return pr.ps_lay.uniform_base + pr.ps.words() + 1;
    }

    /// A draw's uniform words (the last evaluation's, the base vertex and
    /// first instance, the colour target's height in pixels) into `out`
    /// (uniformWords long at least).
    pub fn fillUniforms(pr: *const Pair, base_vertex: u32, first_instance: u32, height: f32, out: []u32) void {
        const vw = pr.vs.words();
        @memcpy(out[0..vw], pr.vs_ev.words[0..vw]);
        out[vw] = base_vertex;
        out[vw + 1] = first_instance;
        const pw = pr.ps.words();
        @memcpy(out[pr.ps_lay.uniform_base..][0..pw], pr.ps_ev.words[0..pw]);
        out[pr.ps_lay.uniform_base + pr.ps_lay.height_word] = @bitCast(height);
    }

    /// Buffers the pipeline binds (raster.Shaders.buffers).
    pub fn bufferCount(pr: *const Pair) u8 {
        return pr.vs.bindings() + pr.ps.bindings();
    }

    /// The game memory buffer `b` (of bufferCount) holds for this draw;
    /// null: none (the engine binds zeros).
    pub fn window(pr: *const Pair, b: u8) ?Window {
        const nv = pr.vs.bindings();
        if (b < nv) {
            return if (b < pr.vs_ev.n_windows) pr.vs_ev.windows[b] else null;
        }
        const j = b - nv;
        return if (j < pr.ps_ev.n_windows) pr.ps_ev.windows[j] else null;
    }

    fn vtx(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.VertexIO) void {
        const pr: *const Pair = @ptrCast(@alignCast(ctx.?));
        emitVertex(&pr.vs, &pr.vs_ev, pr.vs_lay, k, io);
    }

    fn frag(ctx: ?*const anyopaque, k: *kir.Kernel, io: *raster.FragmentIO) void {
        const pr: *const Pair = @ptrCast(@alignCast(ctx.?));
        emitFragment(&pr.ps, &pr.ps_ev, pr.ps_lay, k, io);
    }
};

fn recompileLayoutKey(lay: Layout) u64 {
    return layoutKey(lay);
}

fn recompileEvaluate(p: *const Program, user: []const u32, code_address: u64, mem: Memory, out: *Evaluation, why: *Log) Error!void {
    return evaluate(p, user, code_address, mem, out, why);
}

test {
    _ = @import("recompile_test.sig");
    _ = @import("recompile_draw_test.sig");
}
