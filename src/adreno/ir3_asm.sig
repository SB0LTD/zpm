//! @zpm/adreno ir3_asm — compute kernels from ir3 assembly text.
//!
//! A kernel is written in Mesa's disassembly syntax (see ir3.sig), with
//! labels and a few headers, and comes out as instruction words plus what
//! the command stream needs to run it (local size, register footprint,
//! constants, where the hardware puts the ids).
//!
//!   @localsize 64, 1, 1        workgroup size
//!   @invocationid(r0.x)        local invocation id (x, y, z) arrives here
//!   @wgid(r48.x)               workgroup id (x, y, z), a shared register
//!   @consts 8                  vec4 constants the dispatch provides
//!   @shared 4096               bytes of workgroup (local) memory
//!   @branchstack 4             divergent control flow depth
//!   @threadsize 128            fibers per wave (64 or 128)
//!   loop:                      a label; branches name it: br p0.x, #loop
//!
//! What the hardware does not interlock is done here, as Mesa's
//! ir3_legalize does it (used as documentation): delay slots between ALU
//! results and their readers (nops, or (nopN) on the producer), (ss) after
//! SFU results and local loads, (sy) after global loads, the same for
//! write-after-read hazards on registers a load or store still reads, and
//! (jp) on branch targets. Control flow is followed through branches, loops
//! included, until the hazard state settles.
//!
//! Allocation-free: the caller owns the working storage (Work) and the
//! output words.

const std = @import("std");
const ir3 = @import("ir3.sig");

pub const Instr = ir3.Instr;
pub const Src = ir3.Src;

pub const MAX_INSTRS = 4096;
pub const MAX_LABELS = 128;
/// The register id meaning "not delivered" (Mesa's INVALID_REG, r63.x).
pub const INVALID_REG: u8 = 0xfc;

pub const Error = ir3.Error || error{
    TooManyInstructions,
    TooManyLabels,
    UnknownLabel,
    DuplicateLabel,
    BadHeader,
};

/// a7xx delay slots (Mesa ir3_compiler.c, gen 7).
pub const Delays = struct {
    alu_to_alu: u8 = 2,
    non_alu: u8 = 5,
    cat3_src2_read: u8 = 1,
    half_mismatch: u8 = 3,

    pub fn forGen(gen: u16) Delays {
        return if (gen >= ir3.A7XX) .{} else .{ .alu_to_alu = 3, .non_alu = 6, .cat3_src2_read = 2 };
    }
};

pub const Kernel = struct {
    gen: u16,
    /// Encoded instructions, padded with nops to `instrlen * 16` (and at
    /// least 4 past the last one).
    code: []const u64,
    /// Instructions before the padding.
    count: u32,
    /// SP_CS_INSTR_SIZE: length in units of 16 instructions.
    instrlen: u32,
    local_size: [3]u16 = .{ 1, 1, 1 },
    localid_reg: u8 = INVALID_REG,
    wgid_reg: u8 = INVALID_REG,
    /// Register footprint: highest full / half vec4 register used, plus one.
    full_regs: u8 = 0,
    half_regs: u8 = 0,
    /// vec4 constants read (aligned to 4).
    constlen: u16 = 0,
    branchstack: u8 = 0,
    shared_bytes: u32 = 0,
    threadsize: u8 = 64,
};

const Item = struct {
    in: Instr,
    /// Label a branch names (index into the label table), if any.
    target: ?u16 = null,
    line: u32 = 0,
};

const Label = struct {
    name: [32]u8 = undefined,
    len: u8 = 0,
    /// Index of the first item after it.
    at: u32 = 0,
    used: bool = false,

    fn eql(l: *const Label, s: []const u8) bool {
        return std.mem.eql(u8, l.name[0..l.len], s);
    }
};

/// Hazard state at one point of the program (Mesa's ir3_legalize_state,
/// plus ALU readiness). Register "units" are half registers: full rN.c
/// covers half units 2*num and 2*num+1 (merged register file).
const UNITS = 512;
const Bits = struct {
    w: [UNITS / 64]u64 = [_]u64{0} ** (UNITS / 64),

    fn initEmpty() Bits {
        return .{};
    }
    fn set(b: *Bits, u: usize) void {
        b.w[u >> 6] |= @as(u64, 1) << @intCast(u & 63);
    }
    fn setValue(b: *Bits, u: usize, v: bool) void {
        if (v) b.set(u) else b.w[u >> 6] &= ~(@as(u64, 1) << @intCast(u & 63));
    }
    fn isSet(b: *const Bits, u: usize) bool {
        return b.w[u >> 6] >> @intCast(u & 63) & 1 != 0;
    }
    fn setUnion(b: *Bits, o: Bits) void {
        for (&b.w, o.w) |*x, y| x.* |= y;
    }
    fn eql(a: Bits, b: Bits) bool {
        return std.mem.eql(u64, &a.w, &b.w);
    }
};

const State = struct {
    needs_ss: Bits = Bits.initEmpty(),
    needs_sy: Bits = Bits.initEmpty(),
    ss_war: Bits = Bits.initEmpty(),
    sy_war: Bits = Bits.initEmpty(),
    ss_or_sy_war: Bits = Bits.initEmpty(),
    force_ss: bool = false,
    force_sy: bool = false,
    /// Slots still to wait before an ALU / non-ALU reader may read the
    /// unit (relative to the point this state describes).
    rem_alu: [UNITS]u8 = [_]u8{0} ** UNITS,
    rem_non: [UNITS]u8 = [_]u8{0} ** UNITS,
    /// The unit was last written as a half register.
    wrote_half: Bits = Bits.initEmpty(),

    fn merge(a: *State, b: *const State) bool {
        var changed = false;
        inline for (.{ "needs_ss", "needs_sy", "ss_war", "sy_war", "ss_or_sy_war", "wrote_half" }) |fld| {
            const before = @field(a, fld);
            @field(a, fld).setUnion(@field(b, fld));
            if (!@field(a, fld).eql(before)) changed = true;
        }
        if (b.force_ss and !a.force_ss) {
            a.force_ss = true;
            changed = true;
        }
        if (b.force_sy and !a.force_sy) {
            a.force_sy = true;
            changed = true;
        }
        for (0..UNITS) |u| {
            if (b.rem_alu[u] > a.rem_alu[u]) {
                a.rem_alu[u] = b.rem_alu[u];
                changed = true;
            }
            if (b.rem_non[u] > a.rem_non[u]) {
                a.rem_non[u] = b.rem_non[u];
                changed = true;
            }
        }
        return changed;
    }

    fn advance(st: *State, slots: u32) void {
        if (slots == 0) return;
        const s: u8 = @intCast(@min(slots, 255));
        for (0..UNITS) |u| {
            st.rem_alu[u] -|= s;
            st.rem_non[u] -|= s;
        }
    }

    fn applySs(st: *State) void {
        st.needs_ss = Bits.initEmpty();
        st.ss_war = Bits.initEmpty();
        st.ss_or_sy_war = Bits.initEmpty();
        st.force_ss = false;
    }

    fn applySy(st: *State) void {
        st.needs_sy = Bits.initEmpty();
        st.sy_war = Bits.initEmpty();
        st.ss_or_sy_war = Bits.initEmpty();
        st.force_sy = false;
    }
};

/// Caller-owned working storage (about 1.5 MB: keep it static).
pub const Work = struct {
    items: [MAX_INSTRS]Item = undefined,
    n_items: u32 = 0,
    labels: [MAX_LABELS]Label = undefined,
    n_labels: u32 = 0,
    /// Output of legalization (before encoding).
    out: [MAX_INSTRS]Item = undefined,
    n_out: u32 = 0,
    /// Item index -> output index of its first instruction (labels resolve here).
    item_at: [MAX_INSTRS + 1]u32 = undefined,
    block_in: [MAX_LABELS + 1]State = undefined,
    scratch: State = .{},
    /// Line of the last error (1-based), 0 when none.
    err_line: u32 = 0,
    header: Kernel = undefined,
};

// ── Registers an instruction reads and writes ──────────────────────────────

const RegRange = struct { num: u16, count: u16, half: bool, step: bool = true };

fn unitsOf(r: RegRange, i: u16, out: *[2]u16) usize {
    const num = r.num + (if (r.step) i else 0);
    if (r.half) {
        out[0] = num;
        return 1;
    }
    out[0] = num * 2;
    out[1] = num * 2 + 1;
    return 2;
}

/// Whether a register number is a real GPR (not a0/p0, not shared).
fn isGprNum(num: u16, half: bool) bool {
    if (half) return num < 0x100;
    return num < ir3.A0_X;
}

const Access = struct {
    dst: [5]RegRange = undefined,
    n_dst: usize = 0,
    src: [6]RegRange = undefined,
    /// For each src range: which source operand index it is (for mad's
    /// late third-source read).
    src_idx: [6]u8 = undefined,
    n_src: usize = 0,

    fn d(a: *Access, r: RegRange) void {
        a.dst[a.n_dst] = r;
        a.n_dst += 1;
    }
    fn s(a: *Access, r: RegRange, idx: u8) void {
        a.src[a.n_src] = r;
        a.src_idx[a.n_src] = idx;
        a.n_src += 1;
    }
};

fn srcRange(src: Src, rpt: u8) ?RegRange {
    return switch (src.kind) {
        .gpr => .{ .num = src.num, .count = if (src.r) rpt + 1 else 1, .half = src.half, .step = src.r },
        // (relative reads: any register; tracked as r0.x only — kernels
        // here do not read registers relatively.)
        else => null,
    };
}

fn access(in: *const Instr) Access {
    var a = Access{};
    const rpt: u16 = in.repeat;
    switch (in.op.category()) {
        0 => switch (in.op) {
            .br, .bany, .ball, .kill => a.s(.{ .num = ir3.P0_X + in.comp1, .count = 1, .half = false }, 0),
            .brao, .braa => {
                a.s(.{ .num = ir3.P0_X + in.comp1, .count = 1, .half = false }, 0);
                a.s(.{ .num = ir3.P0_X + in.comp2, .count = 1, .half = false }, 1);
            },
            else => {},
        },
        1 => switch (in.op) {
            .mov, .movs => {
                if (!in.dst.rel) a.d(.{ .num = in.dst.num, .count = rpt + 1, .half = in.dst.half });
                if (srcRange(in.src[0], @intCast(rpt))) |r| a.s(r, 0);
            },
            .swz => {
                a.d(.{ .num = in.dst.num, .count = 1, .half = in.dst.half });
                a.d(.{ .num = in.dsts[0], .count = 1, .half = in.dst.half });
                a.s(.{ .num = in.src[0].num, .count = 1, .half = in.src[0].half }, 0);
                a.s(.{ .num = in.src[1].num, .count = 1, .half = in.src[1].half }, 1);
            },
            .gat => {
                a.d(.{ .num = in.dst.num, .count = 4, .half = in.dst.half });
                for (0..4) |k| a.s(.{ .num = in.src[k].num, .count = 1, .half = in.src[k].half }, @intCast(k));
            },
            .sct => {
                a.d(.{ .num = in.dst.num, .count = 1, .half = in.dst.half });
                for (in.dsts) |dn| a.d(.{ .num = dn, .count = 1, .half = in.dst.half });
                a.s(.{ .num = in.src[0].num, .count = 4, .half = in.src[0].half }, 0);
            },
            .movmsk => a.d(.{ .num = in.dst.num, .count = rpt + 1, .half = false }),
            else => {},
        },
        2, 3, 4 => {
            a.d(.{ .num = in.dst.num, .count = rpt + 1, .half = in.dst.half });
            const n: usize = switch (in.op.category()) {
                2 => 2,
                3 => 3,
                else => 1,
            };
            for (0..n) |k| if (srcRange(in.src[k], @intCast(rpt))) |r| a.s(r, @intCast(k));
        },
        6 => switch (in.op) {
            .ldg, .ldl, .ldp, .ldlw => {
                a.d(.{ .num = in.dst.num, .count = @intCast(@max(in.size, 1)), .half = in.dst.half });
                if (in.op == .ldg) a.s(.{ .num = in.src[0].num, .count = 2, .half = false }, 0) else a.s(.{ .num = in.src[0].num, .count = 1, .half = false }, 0);
            },
            .ldg_a => {
                a.d(.{ .num = in.dst.num, .count = @intCast(@max(in.size, 1)), .half = in.dst.half });
                if (in.src[0].kind == .gpr) a.s(.{ .num = in.src[0].num, .count = 2, .half = false }, 0);
                a.s(.{ .num = in.src[1].num, .count = 1, .half = false }, 1);
            },
            .stg, .stg_a => {
                if (in.src[0].kind == .gpr) a.s(.{ .num = in.src[0].num, .count = 2, .half = false }, 0);
                if (in.op == .stg_a) a.s(.{ .num = in.src[1].num, .count = 1, .half = false }, 1);
                a.s(.{ .num = in.src[2].num, .count = @intCast(@max(in.size, 1)), .half = in.src[2].half }, 2);
            },
            .stl, .stp, .stlw => {
                a.s(.{ .num = in.src[0].num, .count = 1, .half = false }, 0);
                a.s(.{ .num = in.src[1].num, .count = @intCast(@max(in.size, 1)), .half = in.src[1].half }, 1);
            },
            .shfl => {
                a.d(.{ .num = in.dst.num, .count = 1, .half = in.dst.half });
                a.s(.{ .num = in.src[0].num, .count = 1, .half = in.src[0].half }, 0);
                if (in.src[1].kind == .gpr) a.s(.{ .num = in.src[1].num, .count = 1, .half = false }, 1);
            },
            .getspid, .getwid, .getfiberid => a.d(.{ .num = in.dst.num, .count = 1, .half = false }),
            .atomic_g_add, .atomic_g_sub, .atomic_g_xchg, .atomic_g_inc, .atomic_g_dec, .atomic_g_cmpxchg, .atomic_g_min, .atomic_g_max, .atomic_g_and, .atomic_g_or, .atomic_g_xor => {
                a.d(.{ .num = in.dst.num, .count = 1, .half = false });
                if (in.src[0].kind == .gpr) a.s(.{ .num = in.src[0].num, .count = 2, .half = false }, 0);
                if (in.src[1].kind == .gpr) a.s(.{ .num = in.src[1].num, .count = if (in.op == .atomic_g_cmpxchg) 2 else 1, .half = false }, 1);
            },
            .atomic_add, .atomic_sub, .atomic_xchg, .atomic_inc, .atomic_dec, .atomic_cmpxchg, .atomic_min, .atomic_max, .atomic_and, .atomic_or, .atomic_xor => {
                a.d(.{ .num = in.dst.num, .count = 1, .half = false });
                if (in.src[0].kind == .gpr) a.s(.{ .num = in.src[0].num, .count = 1, .half = false }, 0);
                if (in.src[1].kind == .gpr) a.s(.{ .num = in.src[1].num, .count = 1, .half = false }, 1);
            },
            else => {},
        },
        else => {},
    }
    return a;
}

fn isAlu(in: *const Instr) bool {
    return switch (in.op.category()) {
        1, 2, 3 => true,
        else => false,
    };
}

fn isSfu(in: *const Instr) bool {
    return in.op.category() == 4;
}

fn isGlobalLoad(op: ir3.Op) bool {
    return switch (op) {
        .ldg, .ldg_a, .ldg_k, .ldib_b, .ldc, .ldc_k, .ldp => true,
        else => false,
    };
}

fn isLocalLoad(op: ir3.Op) bool {
    return switch (op) {
        .ldl, .ldlw, .ldlv => true,
        else => false,
    };
}

fn isStore(op: ir3.Op) bool {
    return switch (op) {
        .stg, .stg_a, .stl, .stp, .stlw, .stib_b, .stc => true,
        else => false,
    };
}

fn isGlobalAtomic(op: ir3.Op) bool {
    const v = @intFromEnum(op);
    return v >= @intFromEnum(ir3.Op.atomic_g_add) and v <= @intFromEnum(ir3.Op.atomic_g_xor);
}

fn isLocalAtomic(op: ir3.Op) bool {
    const v = @intFromEnum(op);
    return v >= @intFromEnum(ir3.Op.atomic_add) and v <= @intFromEnum(ir3.Op.atomic_xor);
}

fn isBranch(op: ir3.Op) bool {
    return switch (op) {
        .br, .bany, .ball, .brao, .braa, .brac, .brax, .jump, .getone, .getlast => true,
        else => false,
    };
}

fn supportsSs(in: *const Instr) bool {
    const c = in.op.category();
    return c < 5 or c == 7;
}

// ── Parsing the source ──────────────────────────────────────────────────────

fn trimLine(line: []const u8) []const u8 {
    var l = line;
    if (std.mem.indexOfScalar(u8, l, ';')) |i| l = l[0..i];
    if (std.mem.indexOf(u8, l, "//")) |i| l = l[0..i];
    return std.mem.trim(u8, l, " \t\r");
}

fn findLabel(w: *Work, name: []const u8) ?u16 {
    for (w.labels[0..w.n_labels], 0..) |*l, i| if (l.eql(name)) return @intCast(i);
    return null;
}

fn labelRef(w: *Work, name: []const u8) Error!u16 {
    if (findLabel(w, name)) |i| return i;
    if (w.n_labels >= MAX_LABELS or name.len > 32) return error.TooManyLabels;
    const i = w.n_labels;
    w.labels[i] = .{ .len = @intCast(name.len), .at = std.math.maxInt(u32) };
    @memcpy(w.labels[i].name[0..name.len], name);
    w.n_labels += 1;
    return @intCast(i);
}

fn parseRegId(s: []const u8) Error!u8 {
    // "r0.x" -> regid
    var t = std.mem.trim(u8, s, " ()\t");
    if (t.len < 4 or t[0] != 'r') return error.BadHeader;
    t = t[1..];
    const dot = std.mem.indexOfScalar(u8, t, '.') orelse return error.BadHeader;
    const n = std.fmt.parseInt(u8, t[0..dot], 10) catch return error.BadHeader;
    const c = std.mem.indexOfScalar(u8, "xyzw", t[dot + 1]) orelse return error.BadHeader;
    return n * 4 + @as(u8, @intCast(c));
}

fn parseHeader(w: *Work, line: []const u8) Error!void {
    const k = &w.header;
    var it = std.mem.tokenizeAny(u8, line[1..], " ,(\t");
    const name = it.next() orelse return error.BadHeader;
    if (std.mem.eql(u8, name, "localsize")) {
        for (0..3) |i| k.local_size[i] = std.fmt.parseInt(u16, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
    } else if (std.mem.eql(u8, name, "invocationid")) {
        k.localid_reg = try parseRegId(it.rest());
    } else if (std.mem.eql(u8, name, "wgid")) {
        k.wgid_reg = try parseRegId(it.rest());
    } else if (std.mem.eql(u8, name, "consts")) {
        k.constlen = std.fmt.parseInt(u16, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
    } else if (std.mem.eql(u8, name, "shared")) {
        k.shared_bytes = std.fmt.parseInt(u32, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
    } else if (std.mem.eql(u8, name, "branchstack")) {
        k.branchstack = std.fmt.parseInt(u8, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
    } else if (std.mem.eql(u8, name, "threadsize")) {
        k.threadsize = std.fmt.parseInt(u8, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
        if (k.threadsize != 64 and k.threadsize != 128) return error.BadHeader;
    } else return error.BadHeader;
}

/// Parse `src` into the work list (instructions and labels).
fn load(gen: u16, w: *Work, src: []const u8) Error!void {
    w.n_items = 0;
    w.n_labels = 0;
    w.err_line = 0;
    w.header = .{ .gen = gen, .code = &.{}, .count = 0, .instrlen = 0 };
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        w.err_line = line_no;
        var line = trimLine(raw);
        if (line.len == 0) continue;
        if (line[0] == '@') {
            try parseHeader(w, line);
            continue;
        }
        // Labels (possibly followed by an instruction).
        while (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t(") != null) break;
            const li = try labelRef(w, name);
            if (w.labels[li].at != std.math.maxInt(u32)) return error.DuplicateLabel;
            w.labels[li].at = w.n_items;
            line = std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        if (line.len == 0) continue;
        if (w.n_items >= MAX_INSTRS) return error.TooManyInstructions;
        // A branch to a label: "#name" is replaced by #0, resolved later.
        var target: ?u16 = null;
        var buf: [256]u8 = undefined;
        var text = line;
        if (std.mem.lastIndexOfScalar(u8, line, '#')) |h| {
            const rest = std.mem.trim(u8, line[h + 1 ..], " \t");
            if (rest.len > 0 and (std.ascii.isAlphabetic(rest[0]) or rest[0] == '_')) {
                target = try labelRef(w, rest);
                if (h + 2 > buf.len) return error.Syntax;
                @memcpy(buf[0 .. h + 1], line[0 .. h + 1]);
                buf[h + 1] = '0';
                text = buf[0 .. h + 2];
            }
        }
        const in = try ir3.parse(gen, text);
        w.items[w.n_items] = .{ .in = in, .target = target, .line = line_no };
        w.n_items += 1;
    }
    w.err_line = 0;
    for (w.labels[0..w.n_labels]) |l| if (l.at == std.math.maxInt(u32)) return error.UnknownLabel;
}

// ── Legalization ────────────────────────────────────────────────────────────

/// Blocks start at item 0, at every label and after every branch/jump.
fn isBlockStart(w: *const Work, i: u32) bool {
    if (i == 0) return true;
    for (w.labels[0..w.n_labels]) |l| if (l.at == i) return true;
    const prev = &w.items[i - 1].in;
    return isBranch(prev.op) or prev.op == .end;
}

fn blockIndex(w: *const Work, i: u32) u32 {
    var b: u32 = 0;
    var k: u32 = 1;
    while (k <= i) : (k += 1) {
        if (isBlockStart(w, k)) b += 1;
    }
    return b;
}

const Emit = struct {
    w: *Work,
    delays: Delays,
    /// Emitting for real (false: only computing the state).
    real: bool,
    n: u32 = 0,
    /// The last emitted instruction belongs to this block (nops may merge).
    prev_in_block: bool = false,

    fn put(e: *Emit, item: Item) Error!void {
        if (e.real) {
            if (e.w.n_out >= MAX_INSTRS) return error.TooManyInstructions;
            e.w.out[e.w.n_out] = item;
            e.w.n_out += 1;
        }
        e.n += 1;
    }

    fn last(e: *Emit) ?*Instr {
        if (!e.real or e.w.n_out == 0 or !e.prev_in_block) return null;
        return &e.w.out[e.w.n_out - 1].in;
    }
};

fn requiredFlags(st: *const State, in: *const Instr, acc: *const Access) struct { ss: bool, sy: bool } {
    var ss = st.force_ss;
    var sy = st.force_sy;
    var tmp: [2]u16 = undefined;
    for (acc.src[0..acc.n_src]) |r| {
        for (0..r.count) |i| {
            const n = unitsOf(r, @intCast(i), &tmp);
            for (tmp[0..n]) |u| {
                if (st.needs_ss.isSet(u)) ss = true;
                if (st.needs_sy.isSet(u)) sy = true;
            }
        }
    }
    for (acc.dst[0..acc.n_dst]) |r| {
        for (0..r.count) |i| {
            const n = unitsOf(r, @intCast(i), &tmp);
            for (tmp[0..n]) |u| {
                if (st.needs_ss.isSet(u)) ss = true;
                if (st.needs_sy.isSet(u)) sy = true;
                if (st.sy_war.isSet(u)) sy = true;
                if (st.ss_war.isSet(u)) ss = true;
            }
        }
    }
    // (ss) or (sy) both settle a pending read; (sy) already chosen covers it.
    if (!sy) {
        for (acc.dst[0..acc.n_dst]) |r| {
            for (0..r.count) |i| {
                const n = unitsOf(r, @intCast(i), &tmp);
                for (tmp[0..n]) |u| if (st.ss_or_sy_war.isSet(u)) {
                    ss = true;
                };
            }
        }
    }
    _ = in;
    return .{ .ss = ss, .sy = sy };
}

fn delayNeeded(e: *const Emit, st: *const State, in: *const Instr, acc: *const Access) u32 {
    var need: u32 = 0;
    const alu = isAlu(in);
    var tmp: [2]u16 = undefined;
    for (acc.src[0..acc.n_src], acc.src_idx[0..acc.n_src]) |r, idx| {
        for (0..r.count) |i| {
            const n = unitsOf(r, @intCast(i), &tmp);
            for (tmp[0..n]) |u| {
                var d: u32 = if (alu) st.rem_alu[u] else st.rem_non[u];
                if (alu and d > 0) {
                    if (st.wrote_half.isSet(u) != r.half) d += e.delays.half_mismatch;
                    // mad/madsh read their third source a cycle later.
                    if (idx == 2 and in.op.category() == 3 and isMad(in.op)) d -|= e.delays.cat3_src2_read;
                }
                // (rpt) reads register i on the i-th cycle.
                if (r.step) d -|= @intCast(i);
                need = @max(need, d);
            }
        }
    }
    return need;
}

fn isMad(op: ir3.Op) bool {
    return switch (op) {
        .mad_u16, .madsh_u16, .mad_s16, .madsh_m16, .mad_u24, .mad_s24, .mad_f16, .mad_f32, .mad_f16_mul2, .mad_f32_mul2, .mad_f16_div2, .mad_f32_div2 => true,
        else => false,
    };
}

fn emitNops(e: *Emit, st: *State, count: u32, ss: bool, sy: bool) Error!void {
    var left = count;
    var first = true;
    // Merge into the previous cat2/cat3's (nopN) where possible.
    if (!ss and !sy) if (e.last()) |prev| {
        const c = prev.op.category();
        if ((c == 2 or c == 3) and prev.repeat == 0 and prev.nop < 3 and !(prev.src[0].r or prev.src[1].r)) {
            const add = @min(left, 3 - prev.nop);
            prev.nop += @intCast(add);
            left -= add;
            st.advance(add);
        }
    };
    while (left > 0 or (first and (ss or sy))) {
        const k = @min(@max(left, 1), 8);
        var nop = Instr{ .op = .nop, .repeat = @intCast(k - 1) };
        if (first) {
            nop.ss = ss;
            nop.sy = sy;
        }
        try e.put(.{ .in = nop });
        if (first) {
            if (ss) st.applySs();
            if (sy) st.applySy();
        }
        st.advance(k);
        left -|= k;
        first = false;
    }
}

/// One instruction through the state: sync flags, delays, then its effect.
fn step(e: *Emit, st: *State, item: Item) Error!void {
    var in = item.in;
    const acc = access(&in);
    const flags = requiredFlags(st, &in, &acc);
    // cat5/cat6 have no (ss) bit: a (ss)nop goes first.
    if (flags.ss and !supportsSs(&in)) {
        try emitNops(e, st, 1, true, false);
    } else if (flags.ss) in.ss = true;
    if (flags.sy) in.sy = true;
    if (in.ss) st.applySs();
    if (in.sy) st.applySy();
    // Delay slots (sync flags do not cover ALU latency).
    const need = delayNeeded(e, st, &in, &acc);
    if (need > 0) try emitNops(e, st, need, false, false);
    try e.put(.{ .in = in, .target = item.target, .line = item.line });
    e.prev_in_block = true;
    // Barriers make the next instruction wait for everything.
    const barrier = in.op == .bar or in.op == .fence;
    // The slots of this instruction (its repeats, its (nopN)) pass for
    // everything written before it.
    const slots: u32 = 1 + @as(u32, in.repeat) + in.nop;
    st.advance(slots);
    // Its own results: the write of repeat i lands on slot i, and an ALU
    // reader may follow `wait` slots after that.
    var tmp: [2]u16 = undefined;
    const alu = isAlu(&in);
    const mova = in.op == .mov and !in.dst.rel and (in.dst.num == ir3.A0_X or in.dst.num == ir3.A1_X);
    const alu_wait: u32 = if (mova) e.delays.non_alu else e.delays.alu_to_alu;
    for (acc.dst[0..acc.n_dst]) |r| {
        for (0..r.count) |i| {
            const n = unitsOf(r, @intCast(i), &tmp);
            const at: u32 = if (r.step) @intCast(i) else 0;
            for (tmp[0..n]) |u| {
                if (alu) {
                    st.rem_alu[u] = @intCast((at + 1 + alu_wait) -| slots);
                    st.rem_non[u] = @intCast((at + 1 + e.delays.non_alu) -| slots);
                    st.wrote_half.setValue(u, r.half);
                } else {
                    st.rem_alu[u] = 0;
                    st.rem_non[u] = 0;
                }
                if (isSfu(&in) or isLocalLoad(in.op) or isLocalAtomic(in.op) or in.op == .shfl) st.needs_ss.set(u);
                if (isGlobalLoad(in.op) or isGlobalAtomic(in.op)) st.needs_sy.set(u);
                // A vector write of a shared register is read through (ss).
                if (alu and !r.half and r.num >= ir3.SHARED_BASE and r.num < ir3.A0_X) st.needs_ss.set(u);
            }
        }
    }
    // Write-after-read: the source registers of instructions that read
    // them late.
    const late = in.op.category() == 5 or in.op.category() == 6 or isSfu(&in);
    if (late) {
        const ss_kind = isSfu(&in) or isStore(in.op) or isLocalLoad(in.op) or in.op == .shfl;
        for (acc.src[0..acc.n_src]) |r| {
            for (0..r.count) |i| {
                const n = unitsOf(r, @intCast(i), &tmp);
                for (tmp[0..n]) |u| {
                    if (ss_kind) st.ss_war.set(u) else st.ss_or_sy_war.set(u);
                }
            }
        }
    }
    st.force_ss = barrier;
    st.force_sy = barrier;
}

fn targetsOf(w: *const Work, li: u32) bool {
    for (w.items[0..w.n_items]) |it| if (it.target != null and it.target.? == li) return true;
    return false;
}

/// Successor blocks' entry states pick up `st` at the end of block `b`.
fn legalize(gen: u16, w: *Work) Error!void {
    const delays = Delays.forGen(gen);
    // Block table: start item of each block.
    var starts: [MAX_LABELS * 2 + 2]u32 = undefined;
    var n_blocks: u32 = 0;
    var i: u32 = 0;
    while (i < w.n_items) : (i += 1) {
        if (isBlockStart(w, i)) {
            if (n_blocks >= starts.len) return error.TooManyLabels;
            starts[n_blocks] = i;
            n_blocks += 1;
        }
    }
    if (n_blocks == 0) return;
    if (n_blocks > w.block_in.len) return error.TooManyLabels;
    for (w.block_in[0..n_blocks]) |*s| s.* = .{};
    // Iterate the block states to a fixed point.
    var rounds: u32 = 0;
    while (true) : (rounds += 1) {
        var changed = false;
        for (0..n_blocks) |b| {
            const st = &w.scratch;
            st.* = w.block_in[b];
            var e = Emit{ .w = w, .delays = delays, .real = false };
            const end = if (b + 1 < n_blocks) starts[b + 1] else w.n_items;
            for (w.items[starts[b]..end]) |it| try step(&e, st, it);
            const last = &w.items[end - 1].in;
            // Fall through.
            if (b + 1 < n_blocks and last.op != .jump and last.op != .end) {
                if (w.block_in[b + 1].merge(st)) changed = true;
            }
            // Branch target.
            if (w.items[end - 1].target) |li| {
                const at = w.labels[li].at;
                for (starts[0..n_blocks], 0..) |s, k| if (s == at) {
                    if (w.block_in[k].merge(st)) changed = true;
                };
            }
        }
        if (!changed) break;
        if (rounds > 64) break;
    }
    // Emit.
    w.n_out = 0;
    for (0..n_blocks) |b| {
        const st = &w.scratch;
        st.* = w.block_in[b];
        var e = Emit{ .w = w, .delays = delays, .real = true };
        const end = if (b + 1 < n_blocks) starts[b + 1] else w.n_items;
        var k = starts[b];
        while (k < end) : (k += 1) {
            w.item_at[k] = w.n_out;
            try step(&e, st, w.items[k]);
            // (the block's first real instruction is where its label points)
            if (k == starts[b]) w.item_at[k] = firstReal(w, w.item_at[k]);
        }
    }
    w.item_at[w.n_items] = w.n_out;
}

fn firstReal(w: *const Work, from: u32) u32 {
    // Labels point at the first instruction of the block, nops included:
    // a branch must also wait for the inserted syncs.
    _ = w;
    return from;
}

// ── Assembly ────────────────────────────────────────────────────────────────

fn footprint(k: *Kernel, w: *const Work) void {
    var max_full: i32 = -1;
    var max_half: i32 = -1;
    var max_const: i32 = -1;
    for (w.out[0..w.n_out]) |it| {
        const acc = access(&it.in);
        for (acc.dst[0..acc.n_dst]) |r| note(r, &max_full, &max_half);
        for (acc.src[0..acc.n_src]) |r| note(r, &max_full, &max_half);
        for (it.in.src) |s| {
            if (s.kind == .cnst) max_const = @max(max_const, @as(i32, s.num >> 2));
            if (s.kind == .rel_cnst) max_const = @max(max_const, 511);
        }
    }
    k.full_regs = @intCast(max_full + 1);
    k.half_regs = @intCast(max_half + 1);
    const used: u16 = @intCast(max_const + 1);
    k.constlen = std.mem.alignForward(u16, @max(k.constlen, used), 4);
}

fn note(r: RegRange, max_full: *i32, max_half: *i32) void {
    const last = r.num + (if (r.step) r.count - 1 else 0);
    if (r.half) {
        if (last < 0x100) {
            max_half.* = @max(max_half.*, @as(i32, last >> 2));
            // merged registers: a half register occupies part of a full one
            max_full.* = @max(max_full.*, @as(i32, (last >> 1) >> 2));
        }
    } else if (last < ir3.SHARED_BASE) {
        max_full.* = @max(max_full.*, @as(i32, last >> 2));
    }
}

/// Assemble `src` into `out`. The returned kernel's `code` is a slice of
/// `out`. On error, `work.err_line` names the line.
pub fn assemble(gen: u16, src: []const u8, work: *Work, out: []u64) Error!Kernel {
    try load(gen, work, src);
    try legalize(gen, work);
    // (jp) on branch targets, then the branch offsets.
    for (work.items[0..work.n_items]) |it| if (it.target) |li| {
        const at = work.item_at[work.labels[li].at];
        if (at < work.n_out) work.out[at].in.jp = true;
    };
    for (work.out[0..work.n_out], 0..) |*it, oi| if (it.target) |li| {
        const at = work.item_at[work.labels[li].at];
        it.in.imm = @as(i32, @intCast(at)) - @as(i32, @intCast(oi));
    };
    var k = work.header;
    k.gen = gen;
    k.count = work.n_out;
    k.instrlen = (work.n_out + 15) / 16;
    const total = @max(k.instrlen * 16, work.n_out + 4);
    if (out.len < total) return error.BufferTooSmall;
    for (work.out[0..work.n_out], 0..) |*it, oi| {
        out[oi] = ir3.encode(gen, &it.in) catch |e| {
            work.err_line = it.line;
            return e;
        };
    }
    for (out[work.n_out..total]) |*x| x.* = 0; // nop
    footprint(&k, work);
    var has_branch = false;
    for (work.out[0..work.n_out]) |it| if (isBranch(it.in.op)) {
        has_branch = true;
    };
    if (has_branch and k.branchstack == 0) k.branchstack = 4;
    k.code = out[0..total];
    return k;
}

/// The legalized program as text (for logs and tests).
pub fn listing(work: *const Work, gen: u16, buf: []u8) []const u8 {
    var t = ir3.Text{ .buf = buf };
    var line: [160]u8 = undefined;
    for (work.out[0..work.n_out]) |it| {
        const s = ir3.format(gen, &it.in, &line) catch "?";
        t.s(s);
        t.s("\n");
    }
    return t.text();
}

// ── Tests ───────────────────────────────────────────────────────────────────

var test_work: Work = .{};

fn expectListing(src: []const u8, want: []const u8) !void {
    var out: [256]u64 = undefined;
    _ = assemble(ir3.A7XX, src, &test_work, &out) catch |e| {
        std.debug.print("assemble failed at line {d}: {s}\n", .{ test_work.err_line, @errorName(e) });
        return e;
    };
    var buf: [8192]u8 = undefined;
    const got = listing(&test_work, ir3.A7XX, &buf);
    if (!std.mem.eql(u8, std.mem.trim(u8, got, "\n"), std.mem.trim(u8, want, "\n"))) {
        std.debug.print("got:\n{s}\nwant:\n{s}\n", .{ got, want });
        return error.TestUnexpectedResult;
    }
}

test "ALU results wait two slots on a7xx, merged into (nopN)" {
    try expectListing(
        \\add.f r0.x, r1.x, r1.y
        \\mul.f r0.y, r0.x, r0.x
        \\end
    ,
        \\(nop2) add.f r0.x, r1.x, r1.y
        \\mul.f r0.y, r0.x, r0.x
        \\end
    );
}

test "an SFU result is read through (ss), a global load through (sy)" {
    try expectListing(
        \\rcp r0.x, r1.x
        \\ldg.u32 r2.x, g[r4.x], 1
        \\add.f r0.y, r0.x, r2.x
        \\end
    ,
        \\rcp r0.x, r1.x
        \\ldg.u32 r2.x, g[r4.x], 1
        \\(sy)(ss)add.f r0.y, r0.x, r2.x
        \\end
    );
}

test "an ALU result feeding memory waits five slots" {
    try expectListing(
        \\add.u r2.x, r2.x, 4
        \\stg.u32 g[r4.x], r2.x, 1
        \\end
    ,
        \\(nop3) add.u r2.x, r2.x, 4
        \\(rpt1)nop
        \\stg.u32 g[r4.x], r2.x, 1
        \\end
    );
}

test "overwriting a register a store still reads takes (ss)" {
    try expectListing(
        \\stg.u32 g[r4.x], r2.x, 1
        \\mov.u32u32 r2.x, 5
        \\end
    ,
        \\stg.u32 g[r4.x], r2.x, 1
        \\(ss)mov.u32u32 r2.x, 5
        \\end
    );
}

test "a loop: the back edge carries hazards, its target gets (jp)" {
    try expectListing(
        \\@localsize 64, 1, 1
        \\mov.u32u32 r1.x, 0
        \\loop:
        \\ldg.u32 r2.x, g[r4.x], 1
        \\add.u r1.x, r1.x, r2.x
        \\cmps.u.lt p0.x, r1.x, 100
        \\br p0.x, #loop
        \\end
    ,
        \\mov.u32u32 r1.x, 0
        \\(jp)ldg.u32 r2.x, g[r4.x], 1
        \\nop
        \\(sy)(nop2) add.u r1.x, r1.x, r2.x
        \\(nop3) cmps.u.lt p0.x, r1.x, 100
        \\(rpt1)nop
        \\br p0.x, #-5
        \\end
    );
}

test "the delay ALU results need is counted through the repeats" {
    try expectListing(
        \\(rpt3)mov.f32f32 r0.x, (r)r4.x
        \\add.f r1.x, r0.w, r0.x
        \\end
    ,
        \\(rpt3)mov.f32f32 r0.x, (r)r4.x
        \\(rpt1)nop
        \\add.f r1.x, r0.w, r0.x
        \\end
    );
}

test "kernel header and footprint" {
    var out: [64]u64 = undefined;
    const k = try assemble(ir3.A7XX,
        \\@localsize 32, 2, 1
        \\@invocationid(r0.x)
        \\@wgid(r48.x)
        \\@consts 6
        \\mov.u32u32 r3.w, c5.y
        \\end
    , &test_work, &out);
    try std.testing.expectEqual([3]u16{ 32, 2, 1 }, k.local_size);
    try std.testing.expectEqual(@as(u8, 0), k.localid_reg);
    try std.testing.expectEqual(@as(u8, 192), k.wgid_reg);
    try std.testing.expectEqual(@as(u8, 4), k.full_regs);
    try std.testing.expectEqual(@as(u16, 8), k.constlen);
    try std.testing.expectEqual(@as(u32, 1), k.instrlen);
    try std.testing.expectEqual(@as(usize, 16), k.code.len);
}
