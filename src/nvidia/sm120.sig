//! @zpm/nvidia sm120 — NVIDIA's sm_120 shader instructions (Blackwell's
//! GeForce generation: the RTX 50 series, the Legion 5's RTX 5070 Laptop
//! GPU), as 128-bit instruction words.
//!
//! An instruction is written as NVIDIA's disassembler (nvdisasm) prints it,
//! after its control field:
//!
//!   [B------:R-:W0:Y:S01] S2R R5, SR_TID.X
//!   [B0-----:R-:W-:Y:S01] @!P0 IMAD.WIDE.U32 R2, R5.reuse, 0x4, R2
//!
//! and comes out as the two 64-bit words ptxas emits for it (the first is
//! bits 63..0, as the code stream holds them). The control field is the
//! scheduling every instruction carries above bit 104, which the hardware
//! does not work out itself:
//!
//!   B  the scoreboards to wait on (bits 116..121): a digit for each, else -
//!   R  the scoreboard this instruction's reads release (113..115), or -
//!   W  the scoreboard its result releases (110..112), or -
//!   Y  bit 109 set (ptxas sets it on most instructions), - when clear
//!   S  cycles to stall before the next instruction (105..108)
//!
//! and `.reuse` on an ALU operand sets that operand slot's bit in 122..125.
//!
//! Three ways through one description: `encode` (an instruction's 128
//! bits), `decode` (the instruction back from them) and `format` (its text,
//! as nvdisasm prints it). Each mnemonic has one codec, a function that
//! visits its fields in the order nvdisasm prints them: encoding, it takes
//! the operands and modifiers and puts their bits; decoding, it reads the
//! bits and appends the operands and modifiers (so a decoded instruction's
//! modifiers come out in nvdisasm's order). `decode` encodes what it read
//! again and refuses a word with any bit it did not account for, so what it
//! returns is exactly the word.
//!
//! The forms and their bit positions are Mesa's NAK compiler's
//! (src/nouveau/compiler/nak/sm70_encode.rs, MIT license, read as
//! documentation only: none of it is copied), and for what NAK does not
//! emit, ptxas's own output: the two-source IADD and IADD.64, MOV.64 and
//! UMOV.64, STL's 0x387, VIMNMX, SEL.64, I2FP and F2IP, CALL and RET,
//! LDS's and STS's uniform register, BAR's barrier and thread count,
//! WARPSYNC's register, the second source's reuse slot in FADD and HADD2,
//! and the constant bits ptxas sets. The tests assemble every instruction
//! in sm120_vectors.txt (ptxas output for LFM3-shaped kernels, see
//! tools/gen_sm120_vectors.py), compare all 128 bits, decode the words
//! again and print them as nvdisasm did.
//!
//! What nvdisasm prints that `format` cannot: a branch's label (.L_x_3) is
//! the kernel's numbering of its targets, which one instruction does not
//! know, so a decoded branch prints its absolute byte target, `(0x1a0),
//! and parses back as one. Everything else, floats included (%.20g below
//! 1e9, %.20e from there, +INF with its trailing space), prints as
//! nvdisasm prints it.
//!
//! Allocation-free: instructions are plain values parsed in place from the
//! caller's text; decoded ones point only at static strings.

const std = @import("std");

pub const Error = error{
    /// Text that is not an instruction, or an operand this module cannot
    /// read.
    Syntax,
    /// A mnemonic, or a form of it, this module does not encode; a word it
    /// does not decode.
    Unknown,
    /// A register, immediate or offset that does not fit its field.
    OutOfRange,
    /// A branch whose label is not known.
    NoTarget,
};

// ── Words ───────────────────────────────────────────────────────────────────

pub const Word = struct {
    bits: u128 = 0,

    pub fn lo(w: Word) u64 {
        return @truncate(w.bits);
    }

    pub fn hi(w: Word) u64 {
        return @truncate(w.bits >> 64);
    }

    pub fn of(lo_word: u64, hi_word: u64) Word {
        return .{ .bits = @as(u128, hi_word) << 64 | lo_word };
    }

    /// Bits [at, at + n) set to v's low n bits.
    pub fn put(w: *Word, at: u7, n: u7, v: u64) void {
        const mask: u128 = (@as(u128, 1) << n) - 1;
        w.bits = (w.bits & ~(mask << at)) | ((@as(u128, v) & mask) << at);
    }

    pub fn bit(w: *Word, at: u7, on: bool) void {
        w.put(at, 1, @intFromBool(on));
    }

    pub fn get(w: Word, at: u7, n: u7) u64 {
        const mask: u128 = (@as(u128, 1) << n) - 1;
        return @truncate((w.bits >> at) & mask);
    }
};

// ── The control field ───────────────────────────────────────────────────────

pub const Control = struct {
    wait: u6 = 0,
    read: u3 = NONE,
    write: u3 = NONE,
    yield: bool = false,
    stall: u4 = 0,

    /// No scoreboard.
    pub const NONE: u3 = 7;

    /// "[B------:R-:W-:Y:S01]"
    pub fn parse(t: []const u8) Error!Control {
        if (t.len != 21 or t[0] != '[' or t[1] != 'B' or t[8] != ':' or t[9] != 'R' or t[11] != ':' or
            t[12] != 'W' or t[14] != ':' or t[16] != ':' or t[17] != 'S' or t[20] != ']') return error.Syntax;
        var c = Control{};
        for (t[2..8], 0..) |ch, i| {
            if (ch == '-') continue;
            if (ch != '0' + @as(u8, @intCast(i))) return error.Syntax;
            c.wait |= @as(u6, 1) << @intCast(i);
        }
        c.read = try board(t[10]);
        c.write = try board(t[13]);
        c.yield = switch (t[15]) {
            'Y' => true,
            '-' => false,
            else => return error.Syntax,
        };
        const s = std.fmt.parseInt(u8, t[18..20], 10) catch return error.Syntax;
        if (s > 15) return error.OutOfRange;
        c.stall = @intCast(s);
        return c;
    }

    fn board(ch: u8) Error!u3 {
        if (ch == '-') return NONE;
        if (ch < '0' or ch > '5') return error.Syntax;
        return @intCast(ch - '0');
    }

    pub fn apply(c: Control, w: *Word) void {
        w.put(105, 4, c.stall);
        w.bit(109, c.yield);
        w.put(110, 3, c.write);
        w.put(113, 3, c.read);
        w.put(116, 6, c.wait);
    }

    /// The field `w` carries (a scoreboard number 6 does not exist: it
    /// comes back as itself, and `decode` refuses it).
    pub fn of(w: Word) Control {
        return .{
            .stall = @intCast(w.get(105, 4)),
            .yield = w.get(109, 1) == 1,
            .write = @intCast(w.get(110, 3)),
            .read = @intCast(w.get(113, 3)),
            .wait = @intCast(w.get(116, 6)),
        };
    }

    /// The text `parse` reads, into buf (21 bytes).
    pub fn format(c: Control, buf: *[21]u8) []const u8 {
        buf.* = "[B------:R-:W-:-:S00]".*;
        for (0..6) |i| {
            if (c.wait & (@as(u6, 1) << @intCast(i)) != 0) buf[2 + i] = '0' + @as(u8, @intCast(i));
        }
        if (c.read != NONE) buf[10] = '0' + @as(u8, c.read);
        if (c.write != NONE) buf[13] = '0' + @as(u8, c.write);
        if (c.yield) buf[15] = 'Y';
        const s: u8 = c.stall;
        buf[18] = '0' + s / 10;
        buf[19] = '0' + s % 10;
        return buf;
    }
};

// ── Operands ────────────────────────────────────────────────────────────────

/// The zero register (RZ, URZ) and the true predicate (PT, UPT).
pub const RZ: u8 = 255;
pub const PT: u3 = 7;

/// A register's selector suffix: which halves an fp16 op reads (.H0_H0,
/// .H1_H1), which byte I2F converts (.B1..B3), an IMMA operand's layout
/// (.ROW, .COL: always so, printed by nvdisasm).
pub const Sel = enum { none, h0_h0, h1_h1, b1, b2, b3, row, col };

const SEL_NAMES = [_][]const u8{ "", ".H0_H0", ".H1_H1", ".B1", ".B2", ".B3", ".ROW", ".COL" };

pub const Reg = struct {
    n: u8,
    neg: bool = false,
    abs: bool = false,
    reuse: bool = false,
    sel: Sel = .none,
};

pub const Pred = struct {
    n: u3 = PT,
    not: bool = false,
};

/// c[bank][offset], or c[bank][Rn+offset] through an index register (LDC;
/// a uniform one, c[0x3][UR4], for LDCU); an ALU source may be negated or
/// its absolute value taken.
pub const CBuf = struct {
    bank: u5,
    offset: u32,
    reg: u8 = RZ,
    ureg: bool = false,
    neg: bool = false,
    abs: bool = false,
};

/// A memory address: [Rn(.64)+offset], [Rn+URm+offset] (shared memory adds
/// a uniform register), or desc[URd][Rn.64+offset] (a global address
/// through the 64-bit descriptor URd:URd+1).
pub const Addr = struct {
    desc: ?u8 = null,
    reg: u8 = RZ,
    wide: bool = false,
    ureg: ?u8 = null,
    offset: i32 = 0,
};

/// How nvdisasm prints an immediate (and how its text is read).
pub const ImmKind = enum {
    /// 0x10: an unsigned integer, or bits.
    hex,
    /// -0x40: a 32-bit two's complement integer.
    signed,
    /// 1.5, +INF: a float's bits.
    f32,
    /// One half of a pair (HFMA2's c is printed "1.875, 0", the high half
    /// first): the half's 16 bits.
    f16,
};

/// A decoded immediate: the field's bits as encoded (a sign-extended
/// integer is its field's two's complement).
pub const Imm = struct {
    bits: u64,
    kind: ImmKind = .hex,
};

pub const Operand = union(enum) {
    gpr: Reg,
    ugpr: Reg,
    pred: Pred,
    upred: Pred,
    /// A number as written: what it means (an integer, a float, two
    /// halves) depends on the instruction.
    num: []const u8,
    /// A number as decoded.
    imm: Imm,
    cbuf: CBuf,
    addr: Addr,
    /// A special register's number (SR_TID.X: 0x21).
    sreg: u8,
    label: []const u8,
    /// A branch's target, the absolute byte address in its kernel (decoded,
    /// or written `(0x1a0)).
    target: u64,
    /// A convergence barrier register, B0..B15 (BSSY, BSYNC).
    barrier: u8,
};

pub const MAX_OPERANDS = 8;
pub const MAX_MODS = 8;

pub const Instr = struct {
    control: Control = .{},
    guard: Pred = .{},
    /// The guard is a uniform predicate (@!UP0): the uniform datapath's ops
    /// take theirs from that file.
    uguard: bool = false,
    op: []const u8 = "",
    mods: [MAX_MODS][]const u8 = undefined,
    n_mods: usize = 0,
    ops: [MAX_OPERANDS]Operand = undefined,
    n_ops: usize = 0,

    pub fn has(in: *const Instr, m: []const u8) bool {
        for (in.mods[0..in.n_mods]) |x| {
            if (std.mem.eql(u8, x, m)) return true;
        }
        return false;
    }

    pub fn operands(in: *const Instr) []const Operand {
        return in.ops[0..in.n_ops];
    }

    /// The branch target's label, for an instruction that has one.
    pub fn label(in: *const Instr) ?[]const u8 {
        for (in.operands()) |o| {
            if (o == .label) return o.label;
        }
        return null;
    }
};

/// Special registers by name (envytools' and NAK's numbering).
const SREGS = [_]struct { []const u8, u8 }{
    .{ "SR_LANEID", 0x00 },
    .{ "SR_TID", 0x20 },
    .{ "SR_TID.X", 0x21 },
    .{ "SR_TID.Y", 0x22 },
    .{ "SR_TID.Z", 0x23 },
    .{ "SR_CTAID.X", 0x25 },
    .{ "SR_CTAID.Y", 0x26 },
    .{ "SR_CTAID.Z", 0x27 },
    .{ "SR_EQMASK", 0x38 },
    .{ "SR_LTMASK", 0x39 },
    .{ "SR_LEMASK", 0x3a },
    .{ "SR_GTMASK", 0x3b },
    .{ "SR_GEMASK", 0x3c },
    .{ "SR_CLOCKLO", 0x50 },
    .{ "SR_CLOCKHI", 0x51 },
    .{ "SR_GLOBALTIMERLO", 0x52 },
    .{ "SR_GLOBALTIMERHI", 0x53 },
    // (the CTA's index in its cluster, which ptxas reads for shared
    // memory's window)
    .{ "SR_CgaCtaId", 0x88 },
};

fn sregName(n: u8) ?[]const u8 {
    for (SREGS) |s| {
        if (s[1] == n) return s[0];
    }
    return null;
}

fn number(t: []const u8) Error!i64 {
    var s = t;
    var neg = false;
    if (s.len > 0 and s[0] == '-') {
        neg = true;
        s = s[1..];
    }
    const v: u64 = if (std.mem.startsWith(u8, s, "0x"))
        std.fmt.parseInt(u64, s[2..], 16) catch return error.Syntax
    else
        std.fmt.parseInt(u64, s, 10) catch return error.Syntax;
    const sv: i64 = @bitCast(v);
    return if (neg) -%sv else sv;
}

/// "R5", "RZ", "UR4", "URZ" (after any sign): the file and number.
fn regName(t: []const u8) ?struct { uniform: bool, n: u8 } {
    if (std.mem.eql(u8, t, "RZ")) return .{ .uniform = false, .n = RZ };
    if (std.mem.eql(u8, t, "URZ")) return .{ .uniform = true, .n = RZ };
    const uniform = std.mem.startsWith(u8, t, "UR");
    const digits = if (uniform) t[2..] else if (t.len > 1 and t[0] == 'R') t[1..] else return null;
    if (digits.len == 0 or !std.ascii.isDigit(digits[0])) return null;
    const n = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (n == RZ) return null;
    return .{ .uniform = uniform, .n = n };
}

fn predName(t: []const u8) ?struct { uniform: bool, n: u3 } {
    if (std.mem.eql(u8, t, "PT")) return .{ .uniform = false, .n = PT };
    if (std.mem.eql(u8, t, "UPT")) return .{ .uniform = true, .n = PT };
    const uniform = std.mem.startsWith(u8, t, "UP");
    const d = if (uniform) t[2..] else if (t.len == 2 and t[0] == 'P') t[1..] else return null;
    if (d.len != 1 or d[0] < '0' or d[0] > '6') return null;
    return .{ .uniform = uniform, .n = @intCast(d[0] - '0') };
}

/// One term of an address: "R2", "R2.64", "UR4", "0x40", "-0x10".
fn addrTerm(t: []const u8, a: *Addr, seen_reg: *bool) Error!void {
    if (t.len == 0) return error.Syntax;
    if (t[0] == '-' or std.ascii.isDigit(t[0])) {
        a.offset = std.math.cast(i32, try number(t)) orelse return error.OutOfRange;
        return;
    }
    var s = t;
    var wide = false;
    if (std.mem.endsWith(u8, s, ".64")) {
        wide = true;
        s = s[0 .. s.len - 3];
    }
    const r = regName(s) orelse return error.Syntax;
    if (r.uniform) {
        if (wide or a.ureg != null) return error.Syntax;
        a.ureg = r.n;
    } else {
        if (seen_reg.*) return error.Syntax;
        seen_reg.* = true;
        a.reg = r.n;
        a.wide = wide;
    }
}

/// "Rn", "Rn.64", "Rn+0x8", "Rn.64+-0x10", "R2+UR4+0x700", "UR4", "0x40":
/// an address's registers and offset.
fn addrInner(t: []const u8, a: *Addr) Error!void {
    const s = std.mem.trim(u8, t, " ");
    if (s.len == 0) return;
    var seen = false;
    var terms = std.mem.splitScalar(u8, s, '+');
    while (terms.next()) |raw| {
        var term = std.mem.trim(u8, raw, " ");
        // ("R2-0x10")
        if (term.len > 0 and term[0] != '-') {
            if (std.mem.indexOfScalar(u8, term, '-')) |m| {
                try addrTerm(term[0..m], a, &seen);
                term = term[m..];
            }
        }
        try addrTerm(term, a, &seen);
    }
}

/// "c[0x0][0x37c]", "c[0x3][R2+0x10]", "c[0x3][UR4]": a constant buffer
/// reference.
fn cbufOf(t: []const u8) Error!CBuf {
    const mid = std.mem.indexOf(u8, t, "][") orelse return error.Syntax;
    if (!std.mem.endsWith(u8, t, "]")) return error.Syntax;
    const bank = try number(t[2..mid]);
    if (bank < 0 or bank > 31) return error.OutOfRange;
    const inner = t[mid + 2 .. t.len - 1];
    var cb = CBuf{ .bank = @intCast(bank), .offset = 0 };
    var a = Addr{};
    try addrInner(inner, &a);
    if (a.wide or a.offset < 0 or a.desc != null) return error.Syntax;
    if (a.ureg) |u| {
        if (a.reg != RZ) return error.Syntax;
        cb.reg = u;
        cb.ureg = true;
    } else cb.reg = a.reg;
    cb.offset = @intCast(a.offset);
    return cb;
}

pub fn parseOperand(text: []const u8) Error!Operand {
    var t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return error.Syntax;
    if (std.mem.startsWith(u8, t, "`(") and std.mem.endsWith(u8, t, ")")) {
        const name = t[2 .. t.len - 1];
        if (std.mem.startsWith(u8, name, "0x")) {
            const v = try number(name);
            if (v < 0) return error.Syntax;
            return .{ .target = @intCast(v) };
        }
        return .{ .label = name };
    }
    if (std.mem.startsWith(u8, t, "desc[")) {
        const mid = std.mem.indexOf(u8, t, "][") orelse return error.Syntax;
        if (!std.mem.endsWith(u8, t, "]")) return error.Syntax;
        const u = regName(t[5..mid]) orelse return error.Syntax;
        if (!u.uniform) return error.Syntax;
        var a = Addr{ .desc = u.n };
        try addrInner(t[mid + 2 .. t.len - 1], &a);
        return .{ .addr = a };
    }
    if (t[0] == '[') {
        if (!std.mem.endsWith(u8, t, "]")) return error.Syntax;
        var a = Addr{};
        try addrInner(t[1 .. t.len - 1], &a);
        return .{ .addr = a };
    }
    if (std.mem.startsWith(u8, t, "SR_")) {
        for (SREGS) |s| {
            if (std.mem.eql(u8, s[0], t)) return .{ .sreg = s[1] };
        }
        return error.Unknown;
    }
    if (t.len >= 2 and t.len <= 3 and t[0] == 'B' and std.ascii.isDigit(t[1])) {
        const n = std.fmt.parseInt(u8, t[1..], 10) catch return error.Syntax;
        if (n > 15) return error.OutOfRange;
        return .{ .barrier = n };
    }
    var neg = false;
    var not = false;
    var abs = false;
    if (t[0] == '-' and t.len > 1 and !std.ascii.isDigit(t[1]) and t[1] != 'I' and t[1] != 'Q') {
        neg = true;
        t = t[1..];
    } else if (t[0] == '!') {
        not = true;
        t = t[1..];
    }
    var sel: Sel = .none;
    for (SEL_NAMES[1..], 1..) |name, i| {
        if (std.mem.endsWith(u8, t, name)) {
            sel = @enumFromInt(i);
            t = t[0 .. t.len - name.len];
            break;
        }
    }
    var reuse = false;
    if (std.mem.endsWith(u8, t, ".reuse")) {
        reuse = true;
        t = t[0 .. t.len - 6];
    }
    if (t.len > 2 and t[0] == '|' and t[t.len - 1] == '|') {
        abs = true;
        t = t[1 .. t.len - 1];
    }
    if (std.mem.endsWith(u8, t, ".reuse")) {
        // (|R5.reuse| too)
        if (reuse) return error.Syntax;
        reuse = true;
        t = t[0 .. t.len - 6];
    }
    if (std.mem.startsWith(u8, t, "c[")) {
        if (not or reuse or sel != .none) return error.Syntax;
        var cb = try cbufOf(t);
        cb.neg = neg;
        cb.abs = abs;
        return .{ .cbuf = cb };
    }
    if (predName(t)) |p| {
        if (neg or abs or reuse or sel != .none) return error.Syntax;
        const v = Pred{ .n = p.n, .not = not };
        return if (p.uniform) .{ .upred = v } else .{ .pred = v };
    }
    if (regName(t)) |r| {
        if (not) return error.Syntax;
        const v = Reg{ .n = r.n, .neg = neg, .abs = abs, .reuse = reuse, .sel = sel };
        return if (r.uniform) .{ .ugpr = v } else .{ .gpr = v };
    }
    if (not or abs or reuse or neg or sel != .none) return error.Syntax;
    // (a number: a leading - stays in the text)
    return .{ .num = std.mem.trim(u8, text, " ") };
}

/// One line: "[control] @!P0 OP.MOD.MOD a, b, c". The control field may
/// be left out (all zero then: the assembler works it out, or the caller
/// sets it).
pub fn parse(line: []const u8) Error!Instr {
    var in = Instr{};
    var t = std.mem.trim(u8, line, " \t\r");
    if (t.len > 0 and t[0] == '[') {
        const end = std.mem.indexOfScalar(u8, t, ']') orelse return error.Syntax;
        in.control = try Control.parse(t[0 .. end + 1]);
        t = std.mem.trimStart(u8, t[end + 1 ..], " ");
    }
    if (t.len > 0 and t[0] == '@') {
        const end = std.mem.indexOfScalar(u8, t, ' ') orelse return error.Syntax;
        var g = t[1..end];
        if (g.len > 0 and g[0] == '!') {
            in.guard.not = true;
            g = g[1..];
        }
        const p = predName(g) orelse return error.Syntax;
        in.uguard = p.uniform;
        in.guard.n = p.n;
        t = std.mem.trimStart(u8, t[end + 1 ..], " ");
    }
    t = std.mem.trimEnd(u8, t, " ;");
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    var names = std.mem.splitScalar(u8, t[0..sp], '.');
    in.op = names.next() orelse return error.Syntax;
    if (in.op.len == 0) return error.Syntax;
    while (names.next()) |m| {
        if (in.n_mods == MAX_MODS) return error.Syntax;
        in.mods[in.n_mods] = m;
        in.n_mods += 1;
    }
    const rest = std.mem.trim(u8, t[sp..], " ");
    if (rest.len == 0) return in;
    // Operands split on commas outside brackets (and before a target that
    // follows a register without one: RET.REL.NODEC R12 `(kernel)).
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const ch: u8 = if (i < rest.len) rest[i] else ',';
        const split_target = ch == ' ' and depth == 0 and i + 1 < rest.len and rest[i + 1] == '`' and
            std.mem.trim(u8, rest[start..i], " ").len > 0;
        switch (ch) {
            '[', '(' => depth += 1,
            ']', ')' => depth -|= 1,
            else => {},
        }
        if ((ch == ',' and depth == 0) or split_target) {
            if (in.n_ops == MAX_OPERANDS) return error.Syntax;
            in.ops[in.n_ops] = try parseOperand(rest[start..i]);
            in.n_ops += 1;
            start = i + 1;
        }
    }
    return in;
}

// ── Immediates ──────────────────────────────────────────────────────────────

fn floatOf(t: []const u8) ?f64 {
    if (std.mem.eql(u8, t, "+INF")) return std.math.inf(f64);
    if (std.mem.eql(u8, t, "-INF")) return -std.math.inf(f64);
    if (std.mem.eql(u8, t, "+QNAN")) return std.math.nan(f64);
    if (std.mem.eql(u8, t, "-QNAN")) return -std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch null;
}

/// An immediate operand's bits for an `n`-bit field.
fn immValue(o: Operand, kind: ImmKind, n: u7) Error!u64 {
    const v: u64 = switch (o) {
        .imm => |x| x.bits,
        .num => |t| switch (kind) {
            .hex, .signed => blk: {
                const s = try number(t);
                if (s < 0) {
                    if (n < 64 and s < -(@as(i64, 1) << @intCast(n - 1))) return error.OutOfRange;
                    const u: u64 = @bitCast(s);
                    break :blk if (n < 64) u & ((@as(u64, 1) << @intCast(n)) - 1) else u;
                }
                break :blk @bitCast(s);
            },
            .f32 => blk: {
                if (std.mem.startsWith(u8, t, "0x")) break :blk std.fmt.parseInt(u32, t[2..], 16) catch return error.Syntax;
                const f = floatOf(t) orelse return error.Syntax;
                if (std.math.isNan(f)) break :blk if (std.math.signbit(f)) 0xffc00000 else 0x7fffffff;
                break :blk @as(u32, @bitCast(@as(f32, @floatCast(f))));
            },
            .f16 => blk: {
                const f = floatOf(t) orelse return error.Syntax;
                if (std.math.isNan(f)) break :blk if (std.math.signbit(f)) 0xfe00 else 0x7fff;
                break :blk @as(u16, @bitCast(@as(f16, @floatCast(f))));
            },
        },
        else => return error.Syntax,
    };
    if (n < 64 and v >> @intCast(n) != 0) return error.OutOfRange;
    return v;
}

// ── The codec ───────────────────────────────────────────────────────────────

const Dir = enum { enc, dec };

/// One instruction going one way: encoding, `in` is read and `w` written;
/// decoding, `w` is read and `in` built.
const Cx = struct {
    dir: Dir,
    w: Word = .{},
    in: Instr,
    /// Encoding: the operands taken so far.
    taken: usize = 0,
    /// Encoding: the modifiers matched, a bit each.
    used: u32 = 0,
    pc: u64,
    target: ?u64 = null,

    fn enc(cx: *const Cx) bool {
        return cx.dir == .enc;
    }

    fn get(cx: *const Cx, at: u7, n: u7) u64 {
        return cx.w.get(at, n);
    }

    /// A field encoding sets; decoding leaves it to the check that encodes
    /// what was read again.
    fn put(cx: *Cx, at: u7, n: u7, v: u64) void {
        if (cx.enc()) cx.w.put(at, n, v);
    }

    fn take(cx: *Cx) Error!Operand {
        if (cx.taken >= cx.in.n_ops) return error.Syntax;
        cx.taken += 1;
        return cx.in.ops[cx.taken - 1];
    }

    /// Encoding: the next operand, not taken.
    fn peek(cx: *const Cx) ?Operand {
        return if (cx.taken < cx.in.n_ops) cx.in.ops[cx.taken] else null;
    }

    fn push(cx: *Cx, o: Operand) Error!void {
        if (cx.in.n_ops == MAX_OPERANDS) return error.Unknown;
        cx.in.ops[cx.in.n_ops] = o;
        cx.in.n_ops += 1;
    }

    /// Encoding: the first modifier not yet matched that is `m`, matched.
    fn hasMod(cx: *Cx, m: []const u8) bool {
        for (cx.in.mods[0..cx.in.n_mods], 0..) |x, i| {
            const bit = @as(u32, 1) << @intCast(i);
            if (cx.used & bit == 0 and std.mem.eql(u8, x, m)) {
                cx.used |= bit;
                return true;
            }
        }
        return false;
    }

    fn addMod(cx: *Cx, m: []const u8) Error!void {
        if (cx.in.n_mods == MAX_MODS) return error.Unknown;
        cx.in.mods[cx.in.n_mods] = m;
        cx.in.n_mods += 1;
    }

    /// A modifier field, its value's bits at `bits` (low first): value v
    /// prints as names[v]; "" prints nothing (the first "" is what encoding
    /// puts when no name is written), "?" is no form this module knows.
    /// Encoding takes the first modifier not yet matched that is one of the
    /// names: the fields are visited in nvdisasm's order, so repeated names
    /// (IDP.4A.S8.S8) go to their fields in turn.
    fn modBits(cx: *Cx, bits: []const u7, names: []const []const u8) Error!u64 {
        if (cx.enc()) {
            var pick: ?usize = null;
            outer: for (cx.in.mods[0..cx.in.n_mods], 0..) |x, i| {
                const bit = @as(u32, 1) << @intCast(i);
                if (cx.used & bit != 0) continue;
                for (names, 0..) |name, v| {
                    if (name.len > 0 and !eql(name, "?") and eql(name, x)) {
                        cx.used |= bit;
                        pick = v;
                        break :outer;
                    }
                }
            }
            if (pick == null) {
                for (names, 0..) |name, v| {
                    if (name.len == 0) {
                        pick = v;
                        break;
                    }
                }
            }
            const v = pick orelse return error.Unknown;
            for (bits, 0..) |at, k| cx.w.bit(at, (v >> @intCast(k)) & 1 == 1);
            return v;
        }
        var v: u64 = 0;
        for (bits, 0..) |at, k| v |= cx.get(at, 1) << @intCast(k);
        if (v >= names.len or eql(names[v], "?")) return error.Unknown;
        if (names[v].len > 0) try cx.addMod(names[v]);
        return v;
    }

    /// A modifier field of `n` bits at `at`.
    fn mod(cx: *Cx, at: u7, n: u7, names: []const []const u8) Error!u64 {
        var bits: [8]u7 = undefined;
        for (0..n) |k| bits[k] = at + @as(u7, @intCast(k));
        return cx.modBits(bits[0..n], names);
    }

    /// A one-bit modifier, printed when set.
    fn flag(cx: *Cx, at: u7, name: []const u8) Error!bool {
        return (try cx.mod(at, 1, &.{ "", name })) == 1;
    }

    /// A modifier the mnemonic always carries (LOP3.LUT).
    fn always(cx: *Cx, name: []const u8) Error!void {
        if (cx.enc()) {
            if (!cx.hasMod(name)) return error.Unknown;
        } else try cx.addMod(name);
    }

    /// A modifier no single field holds: an opcode's, or nvdisasm's name
    /// for an operand pattern (IMAD.SHL); decoding, `on` says.
    fn derived(cx: *Cx, name: []const u8, on: bool) Error!bool {
        if (cx.enc()) return cx.hasMod(name);
        if (on) try cx.addMod(name);
        return on;
    }

    /// Whether a modifier is written (decoding: `on`), before its field's
    /// place in nvdisasm's order is reached: what a form or an immediate's
    /// reading depends on. Nothing is matched.
    fn sense(cx: *const Cx, name: []const u8, on: bool) bool {
        if (!cx.enc()) return on;
        for (cx.in.mods[0..cx.in.n_mods]) |x| {
            if (eql(x, name)) return true;
        }
        return false;
    }

    // Operands -------------------------------------------------------------

    /// A general (or uniform) register in an 8-bit field, without
    /// modifiers.
    fn regOf(cx: *Cx, at: u7, uniform: bool) Error!u8 {
        if (cx.enc()) {
            const o = try cx.take();
            const r = switch (o) {
                .gpr => |g| if (uniform) return error.Syntax else g,
                .ugpr => |g| if (uniform) g else return error.Syntax,
                else => return error.Syntax,
            };
            if (r.neg or r.abs or r.reuse or r.sel != .none) return error.Syntax;
            cx.w.put(at, 8, r.n);
            return r.n;
        }
        const n: u8 = @intCast(cx.get(at, 8));
        try cx.push(if (uniform) .{ .ugpr = .{ .n = n } } else .{ .gpr = .{ .n = n } });
        return n;
    }

    fn reg(cx: *Cx, at: u7) Error!u8 {
        return cx.regOf(at, false);
    }

    fn ureg(cx: *Cx, at: u7) Error!u8 {
        return cx.regOf(at, true);
    }

    /// A register read at a fixed place (not an ALU slot): its `.reuse` bit
    /// at `slot`, and a selector nvdisasm always prints (IMMA's .ROW).
    fn srcReg(cx: *Cx, at: u7, slot: ?u7, decor: Sel) Error!void {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .gpr) return error.Syntax;
            const r = o.gpr;
            if (r.neg or r.abs or (r.reuse and slot == null) or (r.sel != .none and r.sel != decor)) return error.Syntax;
            cx.w.put(at, 8, r.n);
            if (slot) |s| cx.w.bit(s, r.reuse);
            return;
        }
        try cx.push(.{ .gpr = .{
            .n = @intCast(cx.get(at, 8)),
            .reuse = if (slot) |s| cx.get(s, 1) == 1 else false,
            .sel = decor,
        } });
    }

    /// A predicate written (no negation) in a 3-bit field.
    fn pred(cx: *Cx, at: u7, uniform: bool) Error!u3 {
        if (cx.enc()) {
            const p = try predIn(try cx.take(), uniform);
            if (p.not) return error.Syntax;
            cx.w.put(at, 3, p.n);
            return p.n;
        }
        const p = Pred{ .n = @intCast(cx.get(at, 3)) };
        try cx.push(if (uniform) .{ .upred = p } else .{ .pred = p });
        return p.n;
    }

    /// A predicate written that nvdisasm prints only when it is not PT
    /// (LOP3's, LEA's carry out).
    fn optPred(cx: *Cx, at: u7, uniform: bool) Error!void {
        if (cx.enc()) {
            if (cx.peek()) |o| {
                if ((o == .pred and !uniform) or (o == .upred and uniform)) {
                    _ = try cx.pred(at, uniform);
                    return;
                }
            }
            cx.w.put(at, 3, PT);
            return;
        }
        if (cx.get(at, 3) != PT) _ = try cx.pred(at, uniform);
    }

    /// A predicate read: three bits, its negation in the fourth.
    fn predNot(cx: *Cx, at: u7, uniform: bool) Error!Pred {
        if (cx.enc()) {
            const p = try predIn(try cx.take(), uniform);
            cx.w.put(at, 3, p.n);
            cx.w.bit(at + 3, p.not);
            return p;
        }
        const p = Pred{ .n = @intCast(cx.get(at, 3)), .not = cx.get(at + 3, 1) == 1 };
        try cx.push(if (uniform) .{ .upred = p } else .{ .pred = p });
        return p;
    }

    /// A predicate read that nvdisasm prints only when it is not PT (a
    /// branch's condition).
    fn optPredNot(cx: *Cx, at: u7, uniform: bool) Error!void {
        if (cx.enc()) {
            if (cx.peek()) |o| {
                if ((o == .pred and !uniform) or (o == .upred and uniform)) {
                    _ = try cx.predNot(at, uniform);
                    return;
                }
            }
            cx.w.put(at, 4, PT);
            return;
        }
        if (cx.get(at, 4) != PT) _ = try cx.predNot(at, uniform);
    }

    /// An immediate operand in an `n`-bit field.
    fn imm(cx: *Cx, at: u7, n: u7, kind: ImmKind) Error!u64 {
        if (cx.enc()) {
            const v = try immValue(try cx.take(), kind, n);
            cx.w.put(at, n, v);
            return v;
        }
        const v = cx.get(at, n);
        try cx.push(.{ .imm = .{ .bits = v, .kind = kind } });
        return v;
    }

    fn sreg(cx: *Cx, at: u7) Error!void {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .sreg) return error.Syntax;
            cx.w.put(at, 8, o.sreg);
            return;
        }
        const n: u8 = @intCast(cx.get(at, 8));
        if (sregName(n) == null) return error.Unknown;
        try cx.push(.{ .sreg = n });
    }

    /// A convergence barrier register in a 4-bit field.
    fn barrier(cx: *Cx, at: u7) Error!void {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .barrier) return error.Syntax;
            cx.w.put(at, 4, o.barrier);
            return;
        }
        try cx.push(.{ .barrier = @intCast(cx.get(at, 4)) });
    }

    /// A target's distance in instruction words of 4 bytes from the next
    /// instruction (encoding: from the label's address or a .target).
    fn relTo(cx: *Cx) Error!i64 {
        const to: u64 = switch (try cx.take()) {
            .label => cx.target orelse return error.NoTarget,
            .target => |t| t,
            else => return error.Syntax,
        };
        const d = @as(i64, @intCast(to)) - @as(i64, @intCast(cx.pc + 16));
        if (@mod(d, 4) != 0) return error.OutOfRange;
        return @divExact(d, 4);
    }

    fn pushTarget(cx: *Cx, rel: i64) Error!void {
        const to = @as(i64, @intCast(cx.pc + 16)) + rel * 4;
        if (to < 0) return error.Unknown;
        try cx.push(.{ .target = @intCast(to) });
    }

    /// A branch target: the low 8 bits of the distance in 16..23, the rest
    /// in 34..81 (sm_100's split).
    fn branch(cx: *Cx) Error!void {
        if (cx.enc()) {
            const bits: u64 = @bitCast(try cx.relTo());
            cx.w.put(16, 8, bits & 0xff);
            cx.w.put(34, 48, bits >> 8);
            return;
        }
        const raw: u64 = cx.get(16, 8) | cx.get(34, 48) << 8;
        // (56 bits, signed)
        try cx.pushTarget(@as(i64, @bitCast(raw << 8)) >> 8);
    }

    /// BSSY's target: the distance in 34..63.
    fn rel30(cx: *Cx) Error!void {
        if (cx.enc()) {
            const rel = try cx.relTo();
            if (rel < -(1 << 29) or rel >= (1 << 29)) return error.OutOfRange;
            cx.w.put(34, 30, @as(u64, @bitCast(rel)));
            return;
        }
        const raw = cx.get(34, 30);
        try cx.pushTarget(@as(i64, @bitCast(raw << 34)) >> 34);
    }

    /// A memory address: its register at 24 (with `wide`, .64 allowed), a
    /// signed offset, a descriptor's uniform register at `desc`, a uniform
    /// register added at `ureg` (present when bit 91 is set).
    fn addr(cx: *Cx, a: AddrForm) Error!Addr {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .addr) return error.Syntax;
            const x = o.addr;
            if ((x.desc != null) != (a.desc != null)) return error.Syntax;
            if (x.wide and a.wide == null) return error.Syntax;
            if (x.ureg != null and a.ureg == null) return error.Syntax;
            cx.w.put(24, 8, x.reg);
            if (a.wide) |b| cx.w.bit(b, x.wide);
            if (a.desc) |d| cx.w.put(d, 8, x.desc.?);
            if (a.ureg) |u| {
                cx.w.put(u, 8, x.ureg orelse 0);
                cx.w.bit(91, x.ureg != null);
            }
            const lim = @as(i64, 1) << @intCast(a.off_n - 1);
            if (x.offset < -lim or x.offset >= lim) return error.OutOfRange;
            cx.w.put(a.off_at, a.off_n, @as(u64, @bitCast(@as(i64, x.offset))));
            return x;
        }
        var x = Addr{ .reg = @intCast(cx.get(24, 8)) };
        if (a.wide) |b| x.wide = cx.get(b, 1) == 1;
        if (a.desc) |d| x.desc = @intCast(cx.get(d, 8));
        if (a.ureg) |u| {
            if (cx.get(91, 1) == 1) x.ureg = @intCast(cx.get(u, 8));
        }
        const raw = cx.get(a.off_at, a.off_n);
        const shift: u6 = @intCast(64 - @as(u7, a.off_n));
        x.offset = @intCast(@as(i64, @bitCast(raw << shift)) >> shift);
        try cx.push(.{ .addr = x });
        return x;
    }
};

const AddrForm = struct {
    desc: ?u7 = null,
    wide: ?u7 = null,
    ureg: ?u7 = null,
    off_at: u7 = 40,
    off_n: u7 = 24,
};

fn predIn(o: Operand, uniform: bool) Error!Pred {
    return switch (o) {
        .pred => |p| if (uniform) error.Syntax else p,
        .upred => |p| if (uniform) p else error.Syntax,
        else => error.Syntax,
    };
}

// ── ALU sources ─────────────────────────────────────────────────────────────

/// What a register's two selector bits mean in an op's source slots.
const SelKind = enum { none, half, byte };

/// What a printed ALU source may be: how an immediate in its place reads,
/// whether it takes - and |..|, what its selector bits mean.
const SrcSpec = struct {
    imm: ImmKind = .hex,
    neg: bool = false,
    abs: bool = false,
    sel: SelKind = .none,
};

const Slot = union(enum) {
    /// Not in the encoding.
    none,
    /// RZ, not printed.
    rz,
    src: SrcSpec,
};

const INT: Slot = .{ .src = .{} };
const SINT: Slot = .{ .src = .{ .imm = .signed } };
const SNEG: Slot = .{ .src = .{ .imm = .signed, .neg = true } };
const F32_NEG: SrcSpec = .{ .imm = .f32, .neg = true };
const F32_ABS: SrcSpec = .{ .imm = .f32, .neg = true, .abs = true };
const FNEG: Slot = .{ .src = F32_NEG };
const FABS: Slot = .{ .src = F32_ABS };
const HALF_SPEC: SrcSpec = .{ .imm = .f16, .neg = true, .abs = true, .sel = .half };
const HALF: Slot = .{ .src = HALF_SPEC };

const Alu = struct {
    op: u9,
    /// A uniform-datapath op: its registers are uniform ones.
    uniform: bool = false,
    a: Slot = .none,
    b: Slot = .none,
    c: Slot = .none,
    /// One printed second source in b's place when a register, else in
    /// c's (FADD's, HADD2's); its `.reuse` is c's slot's either way.
    bc: ?SrcSpec = null,
    /// fp16 ops: c's sign bits at 83 and 84.
    half: bool = false,
};

/// The operand slots an ALU instruction reads, for `.reuse` (bits 122..).
const SLOT_A: u7 = 122;
const SLOT_B: u7 = 123;
const SLOT_C: u7 = 124;

/// A source register's place: the register, its sign bits, its `.reuse`
/// bit and its selector's two bits.
const RegAt = struct { at: u7, abs: u7, neg: u7, slot: u7, sel: u7 };

const AT_A = RegAt{ .at = 24, .abs = 73, .neg = 72, .slot = SLOT_A, .sel = 74 };
const AT_B = RegAt{ .at = 32, .abs = 62, .neg = 63, .slot = SLOT_B, .sel = 60 };

fn atC(half: bool) RegAt {
    return .{ .at = 64, .abs = if (half) 83 else 74, .neg = if (half) 84 else 75, .slot = SLOT_C, .sel = 81 };
}

const Src = union(enum) {
    none,
    /// A register of the op's own file.
    reg: Reg,
    /// A uniform register read by a non-uniform op.
    ureg: Reg,
    imm: u32,
    cbuf: CBuf,
};

/// A source's selector as its two bits.
fn selBits(r: Reg, kind: SelKind) Error!u2 {
    return switch (kind) {
        .none => if (r.sel == .none) 0 else error.Syntax,
        .half => switch (r.sel) {
            .none => 0,
            .h0_h0 => 2,
            .h1_h1 => 3,
            else => error.Syntax,
        },
        .byte => switch (r.sel) {
            .none => 0,
            .b1 => 1,
            .b2 => 2,
            .b3 => 3,
            else => error.Syntax,
        },
    };
}

fn selOf(v: u64, kind: SelKind) Error!Sel {
    return switch (kind) {
        .none => .none,
        .half => switch (v) {
            0 => .none,
            2 => .h0_h0,
            3 => .h1_h1,
            else => error.Unknown,
        },
        .byte => switch (v) {
            0 => .none,
            1 => .b1,
            2 => .b2,
            else => .b3,
        },
    };
}

/// A source as encoding reads it, with the bits its selector takes.
const In = struct { src: Src, sel: u2 = 0 };

fn srcIn(cx: *Cx, o: Operand, s: SrcSpec, uniform: bool) Error!In {
    switch (o) {
        .gpr, .ugpr => |r| {
            if ((r.neg and !s.neg) or (r.abs and !s.abs)) return error.Syntax;
            const sel = try selBits(r, s.sel);
            if ((o == .gpr) == uniform) {
                if (uniform) return error.Syntax;
                return .{ .src = .{ .ureg = r }, .sel = sel };
            }
            return .{ .src = .{ .reg = r }, .sel = sel };
        },
        .cbuf => |cb| {
            if (uniform or cb.reg != RZ or (cb.neg and !s.neg) or (cb.abs and !s.abs)) return error.Syntax;
            if (cb.offset > 0xffff) return error.OutOfRange;
            return .{ .src = .{ .cbuf = cb } };
        },
        .num, .imm => {
            if (s.imm == .f16) {
                // (two operands: the high half, then the low)
                const h = try immValue(o, .f16, 16);
                const l = try immValue(try cx.take(), .f16, 16);
                return .{ .src = .{ .imm = @intCast(h << 16 | l) } };
            }
            return .{ .src = .{ .imm = @intCast(try immValue(o, s.imm, 32)) } };
        },
        else => return error.Syntax,
    }
}

fn putReg(w: *Word, f: RegAt, r: Reg, sel: u2) void {
    w.put(f.at, 8, r.n);
    if (r.abs) w.bit(f.abs, true);
    if (r.neg) w.bit(f.neg, true);
    if (r.reuse) w.bit(f.slot, true);
    if (sel != 0) w.put(f.sel, 2, sel);
}

fn putCbuf(w: *Word, cb: CBuf) void {
    w.put(38, 16, cb.offset);
    w.put(54, 5, cb.bank);
    if (cb.abs) w.bit(62, true);
    if (cb.neg) w.bit(63, true);
}

/// NAK's encode_alu_base: source a in 24..31; b and c by the form in bits
/// 9..11 (1: b and c registers; 2: c an immediate, b in c's slot; 3: c a
/// constant; 4: b an immediate; 5: b a constant; 6: b uniform; 7: c
/// uniform). A uniform op's registers are all uniform, and it has no
/// constant or mixed forms.
fn alu(cx: *Cx, d: Alu) Error!void {
    const at_c = atC(d.half);
    if (!cx.enc()) return aluDecode(cx, d, at_c);
    var a: In = .{ .src = .none };
    var b: In = .{ .src = .none };
    var c: In = .{ .src = .none };
    switch (d.a) {
        .none => {},
        .rz => a = .{ .src = .{ .reg = .{ .n = RZ } } },
        .src => |s| a = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    if (a.src != .none and a.src != .reg) return error.Syntax;
    switch (d.b) {
        .none => {},
        .rz => b = .{ .src = .{ .reg = .{ .n = RZ } } },
        .src => |s| b = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    var at_b = AT_B;
    if (d.bc) |s| {
        const x = try srcIn(cx, try cx.take(), s, d.uniform);
        if (x.src == .reg) b = x else c = x;
        at_b.slot = SLOT_C;
    }
    switch (d.c) {
        .none => {},
        .rz => c = .{ .src = .{ .reg = .{ .n = RZ } } },
        .src => |s| c = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    const w = &cx.w;
    if (a.src == .reg) putReg(w, AT_A, a.src.reg, a.sel);
    const form: u3 = switch (c.src) {
        .none, .reg => blk: {
            if (c.src == .reg) putReg(w, at_c, c.src.reg, c.sel);
            break :blk switch (b.src) {
                .none => 1,
                .reg => |r| inner: {
                    putReg(w, at_b, r, b.sel);
                    break :inner 1;
                },
                .ureg => |r| inner: {
                    putReg(w, AT_B, r, b.sel);
                    w.bit(91, true);
                    break :inner 6;
                },
                .imm => |v| inner: {
                    w.put(32, 32, v);
                    break :inner 4;
                },
                .cbuf => |cb| inner: {
                    putCbuf(w, cb);
                    break :inner 5;
                },
            };
        },
        .ureg, .imm, .cbuf => blk: {
            switch (b.src) {
                .none => {},
                .reg => |r| putReg(w, at_c, r, b.sel),
                else => return error.Unknown,
            }
            switch (c.src) {
                .ureg => |r| {
                    putReg(w, AT_B, r, c.sel);
                    w.bit(91, true);
                    break :blk 7;
                },
                .imm => |v| {
                    w.put(32, 32, v);
                    break :blk 2;
                },
                .cbuf => |cb| {
                    putCbuf(w, cb);
                    break :blk 3;
                },
                else => unreachable,
            }
        },
    };
    if (d.uniform and (form == 3 or form == 5 or form == 6 or form == 7)) return error.Syntax;
    w.put(0, 9, d.op);
    w.put(9, 3, form);
    if (d.uniform) w.bit(91, true);
}

const Where = enum { reg32, ureg32, imm32, cbuf32, reg64 };

fn aluDecode(cx: *Cx, d: Alu, at_c: RegAt) Error!void {
    const form = cx.get(9, 3);
    if (d.a == .src) try pushSrc(cx, AT_A, d.a.src, d.uniform);
    var b_at: Where = undefined;
    var c_at: Where = undefined;
    switch (form) {
        1 => {
            b_at = .reg32;
            c_at = .reg64;
        },
        2 => {
            c_at = .imm32;
            b_at = .reg64;
        },
        3 => {
            c_at = .cbuf32;
            b_at = .reg64;
        },
        4 => {
            b_at = .imm32;
            c_at = .reg64;
        },
        5 => {
            b_at = .cbuf32;
            c_at = .reg64;
        },
        6 => {
            b_at = .ureg32;
            c_at = .reg64;
        },
        7 => {
            c_at = .ureg32;
            b_at = .reg64;
        },
        else => return error.Unknown,
    }
    if (d.uniform and form != 1 and form != 2 and form != 4) return error.Unknown;
    if (d.bc) |s| {
        const at = if (form == 1 or form == 4 or form == 5 or form == 6) b_at else c_at;
        if (at == .reg32) {
            var f = AT_B;
            f.slot = SLOT_C;
            return pushSrc(cx, f, s, d.uniform);
        }
        return pushWhere(cx, at, s, d.uniform, at_c);
    }
    if (d.b == .src) try pushWhere(cx, b_at, d.b.src, d.uniform, at_c);
    if (d.c == .src) try pushWhere(cx, c_at, d.c.src, d.uniform, at_c);
}

fn pushSrc(cx: *Cx, f: RegAt, s: SrcSpec, uniform: bool) Error!void {
    const r = Reg{
        .n = @intCast(cx.get(f.at, 8)),
        .abs = s.abs and cx.get(f.abs, 1) == 1,
        .neg = s.neg and cx.get(f.neg, 1) == 1,
        .reuse = cx.get(f.slot, 1) == 1,
        .sel = try selOf(if (s.sel != .none) cx.get(f.sel, 2) else 0, s.sel),
    };
    try cx.push(if (uniform) .{ .ugpr = r } else .{ .gpr = r });
}

fn pushWhere(cx: *Cx, at: Where, s: SrcSpec, uniform: bool, at_c: RegAt) Error!void {
    switch (at) {
        .reg32 => try pushSrc(cx, AT_B, s, uniform),
        .ureg32 => try pushSrc(cx, AT_B, s, true),
        .reg64 => try pushSrc(cx, at_c, s, uniform),
        .imm32 => {
            const v = cx.get(32, 32);
            if (s.imm == .f16) {
                try cx.push(.{ .imm = .{ .bits = v >> 16, .kind = .f16 } });
                try cx.push(.{ .imm = .{ .bits = v & 0xffff, .kind = .f16 } });
            } else try cx.push(.{ .imm = .{ .bits = v, .kind = s.imm } });
        },
        .cbuf32 => try cx.push(.{ .cbuf = .{
            .bank = @intCast(cx.get(54, 5)),
            .offset = @intCast(cx.get(38, 16)),
            .abs = s.abs and cx.get(62, 1) == 1,
            .neg = s.neg and cx.get(63, 1) == 1,
        } }),
    }
}

// ── Modifier tables ─────────────────────────────────────────────────────────

/// Loads' and stores' sizes (73..75).
const SIZES = [_][]const u8{ "U8", "S8", "U16", "S16", "", "64", "128", "?" };
/// Global memory's ordering (77..80): weak, or .CONSTANT (read-only for
/// the kernel: ld.global.nc).
const ORDER = [_][]const u8{ "", "?", "?", "?", "CONSTANT" };
/// ISETP's comparisons (76..78) and how the result joins the accumulator
/// (74..75).
const ICMP = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "T" };
const BOOL = [_][]const u8{ "AND", "OR", "XOR", "?" };
/// FSETP's comparisons (76..79): ordered, then unordered (NaN true).
const FCMP = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "NUM", "NAN", "LTU", "EQU", "LEU", "GTU", "NEU", "GEU", "T" };
/// Rounding (78..79 in float ops).
const RND = [_][]const u8{ "", "RM", "RP", "RZ" };
/// Float to integer rounding.
const FRND = [_][]const u8{ "", "FLOOR", "CEIL", "TRUNC" };
/// Integer types by size (log2 of bytes) and signedness: index size * 2 +
/// signed; the second leaves S32 unprinted (F2I's, I2F's default).
const ITYPES = [_][]const u8{ "U8", "S8", "U16", "S16", "U32", "S32", "U64", "S64" };
const ITYPES_S32 = [_][]const u8{ "U8", "S8", "U16", "S16", "U32", "", "U64", "S64" };
/// Float types by size; the second leaves F32 unprinted.
const FTYPES = [_][]const u8{ "?", "F16", "F32", "F64" };
const FTYPES_F32 = [_][]const u8{ "?", "F16", "", "F64" };
/// The special-function unit's functions (74..79).
const MUFU = [_][]const u8{ "COS", "SIN", "EX2", "LG2", "RCP", "RSQ", "RCP64H", "RSQ64H", "SQRT", "TANH" };

// ── The codecs ──────────────────────────────────────────────────────────────

// Control flow ---------------------------------------------------------------

fn cNop(cx: *Cx) Error!void {
    cx.put(0, 12, 0x918);
}

fn cExit(cx: *Cx) Error!void {
    cx.put(0, 12, 0x94d);
    cx.put(87, 3, PT);
}

/// BRA (its condition printed when not PT), or BRA.U on a uniform
/// predicate.
fn cBra(cx: *Cx) Error!void {
    if (try cx.derived("U", cx.get(0, 12) == 0x547)) {
        cx.put(0, 12, 0x547);
        _ = try cx.predNot(24, true);
        cx.put(32, 1, 1);
        cx.put(87, 3, PT);
        cx.put(91, 1, 1);
    } else {
        cx.put(0, 12, 0x947);
        try cx.optPredNot(87, false);
    }
    try cx.branch();
}

/// CALL.REL.NOINC `(subroutine): ptxas's call into its own slow paths
/// (the return address in a register the caller set).
fn cCall(cx: *Cx) Error!void {
    try cx.always("REL");
    try cx.always("NOINC");
    cx.put(0, 12, 0x944);
    cx.put(86, 4, 0xf);
    try cx.branch();
}

/// RET.REL.NODEC Rn `(kernel): back to the kernel's start plus Rn.
fn cRet(cx: *Cx) Error!void {
    try cx.always("REL");
    try cx.always("NODEC");
    cx.put(0, 12, 0x950);
    _ = try cx.reg(24);
    cx.put(86, 4, 0xf);
    try cx.branch();
}

/// BSSY(.RECONVERGENT) Bn, `(join): where the warp's threads meet again.
fn cBssy(cx: *Cx) Error!void {
    cx.put(0, 12, 0x945);
    _ = try cx.flag(73, "RECONVERGENT");
    try cx.barrier(16);
    try cx.rel30();
    cx.put(87, 3, PT);
}

fn cBsync(cx: *Cx) Error!void {
    cx.put(0, 12, 0x941);
    _ = try cx.flag(73, "RECONVERGENT");
    try cx.barrier(16);
    cx.put(87, 3, PT);
}

/// WARPSYNC Rn: the lanes in Rn's mask wait for each other.
fn cWarpsync(cx: *Cx) Error!void {
    cx.put(0, 12, 0x348);
    _ = try cx.reg(24);
    cx.put(87, 3, PT);
}

/// BAR.SYNC.DEFER_BLOCKING id(, threads): the CTA's barrier `id` (the
/// thread count, printed when not 0, in 42..53).
fn cBar(cx: *Cx) Error!void {
    cx.put(0, 12, 0xb1d);
    _ = try cx.mod(77, 2, &.{ "SYNC", "ARV", "RED", "SCAN" });
    _ = try cx.flag(80, "DEFER_BLOCKING");
    _ = try cx.imm(54, 4, .hex);
    if (cx.enc()) {
        if (cx.peek() != null) _ = try cx.imm(42, 12, .hex);
    } else if (cx.get(42, 12) != 0) _ = try cx.imm(42, 12, .hex);
}

// Special registers ------------------------------------------------------------

fn cS2r(cx: *Cx) Error!void {
    cx.put(0, 12, 0x919);
    _ = try cx.reg(16);
    try cx.sreg(72);
}

fn cS2ur(cx: *Cx) Error!void {
    cx.put(0, 12, 0x9c3);
    _ = try cx.ureg(16);
    try cx.sreg(72);
}

/// CS2R(.32) Rd, SR: the clock without a scoreboard (.32: one register).
fn cCs2r(cx: *Cx) Error!void {
    cx.put(0, 12, 0x805);
    _ = try cx.mod(80, 1, &.{ "32", "" });
    _ = try cx.reg(16);
    try cx.sreg(72);
}

fn cR2ur(cx: *Cx) Error!void {
    cx.put(0, 12, 0x2ca);
    _ = try cx.ureg(16);
    _ = try cx.reg(24);
    cx.put(81, 3, PT);
}

// Constant, global, local and shared memory ------------------------------------

/// LDC Rd, c[bank][offset] (a register index in 24); LDCU URd, ...
/// (offset in 37..53, a uniform index in 24).
fn cLdc(cx: *Cx, uniform: bool) Error!void {
    _ = try cx.mod(73, 3, &SIZES);
    if (uniform) {
        cx.put(0, 12, 0x7ac);
        _ = try cx.ureg(16);
        cx.put(91, 1, 1);
    } else {
        cx.put(0, 12, 0xb82);
        _ = try cx.reg(16);
    }
    const off_at: u7 = if (uniform) 37 else 38;
    const off_n: u7 = if (uniform) 17 else 16;
    if (cx.enc()) {
        const o = try cx.take();
        if (o != .cbuf) return error.Syntax;
        const cb = o.cbuf;
        if (cb.neg or cb.abs or (cb.reg != RZ and cb.ureg != uniform)) return error.Syntax;
        if (cb.offset >> @intCast(off_n) != 0) return error.OutOfRange;
        cx.w.put(24, 8, cb.reg);
        cx.w.put(off_at, off_n, cb.offset);
        cx.w.put(54, 5, cb.bank);
        return;
    }
    const index: u8 = @intCast(cx.get(24, 8));
    try cx.push(.{ .cbuf = .{
        .bank = @intCast(cx.get(54, 5)),
        .offset = @intCast(cx.get(off_at, off_n)),
        .reg = index,
        .ureg = uniform and index != RZ,
    } });
}

fn cLdcR(cx: *Cx) Error!void {
    return cLdc(cx, false);
}

fn cLdcU(cx: *Cx) Error!void {
    return cLdc(cx, true);
}

fn cLdg(cx: *Cx) Error!void {
    cx.put(0, 12, 0x981);
    _ = try cx.flag(76, "E");
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.mod(77, 4, &ORDER);
    _ = try cx.reg(16);
    _ = try cx.addr(.{ .desc = 32, .wide = 90 });
    cx.put(72, 1, 1); // (the descriptor is 64 bits)
    cx.put(81, 3, PT);
    cx.put(84, 3, 1); // (eviction: normal)
    cx.put(91, 1, 1);
}

fn cStg(cx: *Cx) Error!void {
    cx.put(0, 12, 0x986);
    _ = try cx.flag(76, "E");
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.addr(.{ .desc = 64, .wide = 90 });
    _ = try cx.reg(32);
    cx.put(72, 1, 1);
    cx.put(84, 3, 1);
    cx.put(91, 1, 1);
}

fn cLdl(cx: *Cx) Error!void {
    cx.put(0, 12, 0x983);
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.reg(16);
    _ = try cx.addr(.{});
    cx.put(84, 3, 1);
}

fn cStl(cx: *Cx) Error!void {
    cx.put(0, 12, 0x387);
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.addr(.{});
    _ = try cx.reg(32);
    cx.put(84, 3, 1);
}

/// LDS Rd, [Ra+URb+offset] (the uniform register in 32 when bit 91 is set).
fn cLds(cx: *Cx) Error!void {
    cx.put(0, 12, 0x984);
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.reg(16);
    _ = try cx.addr(.{ .ureg = 32 });
}

/// STS [Ra(+URb)+offset], Rd: with a uniform register the opcode is 0x988
/// and it sits in 64.
fn cSts(cx: *Cx) Error!void {
    const with_u = if (cx.enc()) blk: {
        const o = cx.peek() orelse return error.Syntax;
        break :blk o == .addr and o.addr.ureg != null;
    } else cx.get(0, 12) == 0x988;
    cx.put(0, 12, if (with_u) 0x988 else 0x388);
    _ = try cx.mod(73, 3, &SIZES);
    _ = try cx.addr(if (with_u) .{ .ureg = 64 } else .{});
    _ = try cx.reg(32);
}

// Moves and integers -----------------------------------------------------------

fn cMov(cx: *Cx) Error!void {
    if (try cx.derived("64", cx.get(9, 3) == 2)) {
        // MOV.64 Rd, imm64: the immediate in bits 24..87
        cx.put(0, 12, 0x402);
        _ = try cx.reg(16);
        _ = try cx.imm(24, 64, .hex);
        return;
    }
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x002, .b = INT });
    cx.put(72, 4, 0xf);
}

/// UMOV URd, imm or URs (encoded as a warp ALU op with a uniform source);
/// UMOV.64 URd, imm64.
fn cUmov(cx: *Cx) Error!void {
    if (try cx.derived("64", cx.get(9, 3) == 2)) {
        cx.put(0, 12, 0x482);
        _ = try cx.ureg(16);
        _ = try cx.imm(24, 64, .hex);
        cx.put(91, 1, 1); // (a uniform destination)
        return;
    }
    _ = try cx.ureg(16);
    try alu(cx, .{ .op = 0x082, .b = INT });
}

/// sm_100's two-source add; .64 adds register pairs.
fn cIadd(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x035, .a = .{ .src = .{ .neg = true } }, .b = SNEG });
    _ = try cx.flag(73, "64");
    cx.put(81, 3, PT);
    cx.put(87, 4, 0xf); // (!PT)
}

/// IADD3 Rd, Pcarry0, Pcarry1, a, b, c (UIADD3 on the uniform datapath).
fn iadd3(cx: *Cx, uniform: bool) Error!void {
    _ = try cx.regOf(16, uniform);
    _ = try cx.pred(81, uniform);
    _ = try cx.pred(84, uniform);
    try alu(cx, .{ .op = if (uniform) 0x090 else 0x010, .uniform = uniform, .a = SNEG, .b = SNEG, .c = SNEG });
    cx.put(77, 4, 0xf);
    cx.put(87, 4, 0xf);
}

fn cIadd3(cx: *Cx) Error!void {
    return iadd3(cx, false);
}

fn cUiadd3(cx: *Cx) Error!void {
    return iadd3(cx, true);
}

/// IMAD(.WIDE)(.HI)(.U32) Rd, a, b, c. nvdisasm names IMAD.U32 by a power
/// of two and no addend IMAD.SHL.
fn cImad(cx: *Cx) Error!void {
    const op9 = cx.get(0, 9);
    const wide = cx.sense("WIDE", op9 == 0x025);
    const hi = cx.sense("HI", op9 == 0x027);
    const unsigned = cx.sense("U32", cx.get(73, 1) == 0);
    const s = Slot{ .src = .{ .imm = if (unsigned) .hex else .signed } };
    _ = try cx.reg(16);
    try alu(cx, .{ .op = if (wide) 0x025 else if (hi) 0x027 else 0x024, .a = s, .b = s, .c = s });
    cx.put(81, 3, PT);
    cx.put(87, 4, 0xf);
    _ = try cx.derived("WIDE", wide);
    _ = try cx.derived("HI", hi);
    const o = cx.in.ops[0..cx.in.n_ops];
    const shl = !cx.enc() and !wide and !hi and unsigned and o.len == 4 and o[2] == .imm and
        o[2].imm.bits != 0 and std.math.isPowerOfTwo(o[2].imm.bits) and o[3] == .gpr and o[3].gpr.n == RZ;
    _ = try cx.derived("SHL", shl);
    _ = try cx.mod(73, 1, &.{ "U32", "" });
}

/// ISETP.cmp(.U32 | .U64 | .S64).bool Pd, Pd1, a, b, Paccum (UISETP on
/// the uniform datapath).
fn isetp(cx: *Cx, uniform: bool) Error!void {
    const signed = if (cx.enc()) !(cx.sense("U32", false) or cx.sense("U64", false)) else cx.get(73, 1) == 1;
    _ = try cx.pred(81, uniform);
    _ = try cx.pred(84, uniform);
    try alu(cx, .{
        .op = if (uniform) 0x08c else 0x00c,
        .uniform = uniform,
        .a = INT,
        .b = .{ .src = .{ .imm = if (signed) .signed else .hex } },
    });
    _ = try cx.predNot(87, uniform);
    cx.put(68, 4, PT);
    _ = try cx.mod(76, 3, &ICMP);
    _ = try cx.modBits(&.{ 73, 80 }, &.{ "U32", "", "U64", "S64" });
    _ = try cx.mod(74, 2, &BOOL);
}

fn cIsetp(cx: *Cx) Error!void {
    return isetp(cx, false);
}

fn cUisetp(cx: *Cx) Error!void {
    return isetp(cx, true);
}

/// LOP3.LUT (Pd,) Rd, a, b, c, lut, Psrc: a predicate result (whether the
/// result is not zero) is printed first when there is one.
fn lop3(cx: *Cx, uniform: bool) Error!void {
    try cx.always("LUT");
    try cx.optPred(81, uniform);
    _ = try cx.regOf(16, uniform);
    try alu(cx, .{ .op = if (uniform) 0x092 else 0x012, .uniform = uniform, .a = INT, .b = INT, .c = INT });
    _ = try cx.imm(72, 8, .hex);
    _ = try cx.predNot(87, uniform);
}

fn cLop3(cx: *Cx) Error!void {
    return lop3(cx, false);
}

fn cUlop3(cx: *Cx) Error!void {
    return lop3(cx, true);
}

/// PLOP3.LUT Pd0, Pd1, P0, P1, P2, lut0, lut1 (lut0 split: 64..66 and
/// 72..76); UPLOP3 on uniform predicates.
fn plop3(cx: *Cx, uniform: bool) Error!void {
    try cx.always("LUT");
    cx.put(0, 12, if (uniform) 0x89c else 0x81c);
    _ = try cx.pred(81, uniform);
    _ = try cx.pred(84, uniform);
    _ = try cx.predNot(87, uniform);
    _ = try cx.predNot(77, uniform);
    _ = try cx.predNot(68, uniform);
    if (cx.enc()) {
        const l0 = try immValue(try cx.take(), .hex, 8);
        cx.w.put(64, 3, l0 & 7);
        cx.w.put(72, 5, l0 >> 3);
    } else try cx.push(.{ .imm = .{ .bits = cx.get(64, 3) | cx.get(72, 5) << 3 } });
    _ = try cx.imm(16, 8, .hex);
}

fn cPlop3(cx: *Cx) Error!void {
    return plop3(cx, false);
}

fn cUplop3(cx: *Cx) Error!void {
    return plop3(cx, true);
}

/// LEA(.HI)(.X)(.SX32) Rd, (Pd,) a, b, (c,) shift(, Pcarry): (a << shift)
/// + b, or with .HI the high part of (c:a << shift) + b; c is printed with
/// .HI unless .SX32 (a's sign), the carry in with .X.
fn lea(cx: *Cx, uniform: bool) Error!void {
    const hi = cx.sense("HI", cx.get(80, 1) == 1);
    const x = cx.sense("X", cx.get(74, 1) == 1);
    const sx = cx.sense("SX32", cx.get(73, 1) == 1);
    _ = try cx.regOf(16, uniform);
    try cx.optPred(81, uniform);
    try alu(cx, .{
        .op = if (uniform) 0x091 else 0x011,
        .uniform = uniform,
        .a = .{ .src = .{ .neg = true } },
        .b = INT,
        .c = if (hi and !sx) INT else .rz,
    });
    _ = try cx.imm(75, 5, .hex);
    if (x) _ = try cx.predNot(87, uniform) else cx.put(87, 4, 0xf);
    _ = try cx.flag(80, "HI");
    _ = try cx.flag(74, "X");
    _ = try cx.flag(73, "SX32");
}

fn cLea(cx: *Cx) Error!void {
    return lea(cx, false);
}

fn cUlea(cx: *Cx) Error!void {
    return lea(cx, true);
}

/// SHF.L/R(.W).type(.HI) Rd, low, shift, high: a funnel shift.
fn shf(cx: *Cx, uniform: bool) Error!void {
    _ = try cx.regOf(16, uniform);
    try alu(cx, .{ .op = if (uniform) 0x099 else 0x019, .uniform = uniform, .a = INT, .b = INT, .c = INT });
    _ = try cx.mod(76, 1, &.{ "L", "R" });
    _ = try cx.flag(75, "W");
    _ = try cx.mod(73, 2, &.{ "S64", "U64", "S32", "U32" });
    _ = try cx.flag(80, "HI");
}

fn cShf(cx: *Cx) Error!void {
    return shf(cx, false);
}

fn cUshf(cx: *Cx) Error!void {
    return shf(cx, true);
}

/// PRMT Rd, a, selector, c: bytes of c:a picked.
fn cPrmt(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x016, .a = INT, .b = INT, .c = INT });
    _ = try cx.mod(72, 3, &.{ "", "F4E", "B4E", "RC8", "ECL", "ECR", "RC16", "?" });
}

/// SEL(.64) Rd, a, b, P: a where P, else b (.64: register pairs).
fn cSel(cx: *Cx) Error!void {
    if (try cx.derived("64", cx.get(0, 12) == 0x607)) {
        cx.put(0, 12, 0x607);
        _ = try cx.reg(16);
        try cx.srcReg(24, SLOT_A, .none);
        try cx.srcReg(32, SLOT_B, .none);
    } else {
        _ = try cx.reg(16);
        try alu(cx, .{ .op = 0x007, .a = INT, .b = INT });
    }
    _ = try cx.predNot(87, false);
}

/// VIMNMX.S32/U32 Rd, a, b, Pmin: min when the predicate is true, else max.
fn cVimnmx(cx: *Cx) Error!void {
    const signed = cx.sense("S32", cx.get(72, 1) == 1);
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x048, .a = INT, .b = .{ .src = .{ .imm = if (signed) .signed else .hex } } });
    _ = try cx.predNot(87, false);
    cx.put(81, 6, 0x3f);
    _ = try cx.mod(72, 1, &.{ "U32", "S32" });
}

fn oneSource(cx: *Cx, op: u9) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = op, .b = INT });
}

fn cIabs(cx: *Cx) Error!void {
    return oneSource(cx, 0x013);
}

fn cPopc(cx: *Cx) Error!void {
    return oneSource(cx, 0x109);
}

fn cBrev(cx: *Cx) Error!void {
    return oneSource(cx, 0x101);
}

/// FLO(.U32)(.SH) Rd, b: the highest set bit's position (or, signed, the
/// highest bit unlike the sign).
fn cFlo(cx: *Cx) Error!void {
    try oneSource(cx, 0x100);
    cx.put(81, 3, PT);
    _ = try cx.mod(73, 1, &.{ "U32", "" });
    _ = try cx.flag(74, "SH");
}

/// IDP.4A.(U8|S8).(U8|S8) Rd, a, b, c: c + the dot of a's and b's bytes.
fn cIdp(cx: *Cx) Error!void {
    try cx.always("4A");
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x026, .a = INT, .b = INT, .c = INT });
    _ = try cx.mod(73, 1, &.{ "U8", "S8" });
    _ = try cx.mod(74, 1, &.{ "U8", "S8" });
}

// Warp operations ----------------------------------------------------------------

/// SHFL.op Pin, Rd, Ra, lane, clamp: the lane and the clamp each a
/// register (32, 64) or an immediate (53..57, 40..52), which the opcode
/// says.
fn cShfl(cx: *Cx) Error!void {
    _ = try cx.mod(58, 2, &.{ "IDX", "UP", "DOWN", "BFLY" });
    _ = try cx.pred(81, false);
    _ = try cx.reg(16);
    _ = try cx.reg(24);
    var lane_imm: bool = undefined;
    var c_imm: bool = undefined;
    if (cx.enc()) {
        if (cx.in.n_ops != 5) return error.Syntax;
        lane_imm = cx.in.ops[3] != .gpr;
        c_imm = cx.in.ops[4] != .gpr;
    } else {
        const op = cx.get(0, 12);
        lane_imm = op == 0x989 or op == 0xf89;
        c_imm = op == 0x589 or op == 0xf89;
        if (op != 0x389 and !lane_imm and !c_imm) return error.Unknown;
    }
    cx.put(0, 12, if (lane_imm and c_imm) 0xf89 else if (lane_imm) 0x989 else if (c_imm) 0x589 else 0x389);
    if (lane_imm) _ = try cx.imm(53, 5, .hex) else _ = try cx.reg(32);
    if (c_imm) _ = try cx.imm(40, 13, .hex) else _ = try cx.reg(64);
}

/// VOTE.ALL/ANY/EQ (Rd,) Pd, Psrc: the ballot in Rd (printed when not RZ),
/// the vote in Pd.
fn cVote(cx: *Cx) Error!void {
    cx.put(0, 12, 0x806);
    _ = try cx.mod(72, 2, &.{ "ALL", "ANY", "EQ", "?" });
    if (cx.enc()) {
        if (cx.peek()) |o| {
            if (o == .gpr) _ = try cx.reg(16) else cx.w.put(16, 8, RZ);
        }
    } else if (cx.get(16, 8) != RZ) _ = try cx.reg(16);
    _ = try cx.pred(81, false);
    _ = try cx.predNot(87, false);
}

/// VOTEU.ANY URd, UPd, Psrc: the ballot into a uniform register.
fn cVoteu(cx: *Cx) Error!void {
    cx.put(0, 12, 0x886);
    _ = try cx.mod(72, 2, &.{ "ALL", "ANY", "EQ", "?" });
    _ = try cx.ureg(16);
    _ = try cx.pred(81, true);
    _ = try cx.predNot(87, false);
}

// Floats ---------------------------------------------------------------------------

fn fmods(cx: *Cx) Error!void {
    _ = try cx.mod(78, 2, &RND);
    _ = try cx.flag(80, "FTZ");
    _ = try cx.flag(77, "SAT");
}

fn ffma(cx: *Cx, uniform: bool) Error!void {
    _ = try cx.regOf(16, uniform);
    try alu(cx, .{ .op = if (uniform) 0x055 else 0x023, .uniform = uniform, .a = FNEG, .b = FNEG, .c = FNEG });
    try fmods(cx);
}

fn cFfma(cx: *Cx) Error!void {
    return ffma(cx, false);
}

fn cUffma(cx: *Cx) Error!void {
    return ffma(cx, true);
}

fn cFadd(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x021, .a = FABS, .bc = F32_ABS });
    try fmods(cx);
}

fn cFmul(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x020, .a = FNEG, .b = FNEG });
    try fmods(cx);
    cx.put(84, 3, 4);
}

/// FMNMX Rd, a, b, Pmin: min when the predicate is true, else max.
fn cFmnmx(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x009, .a = FABS, .b = FABS });
    _ = try cx.predNot(87, false);
    _ = try cx.flag(80, "FTZ");
}

/// FSEL Rd, a, b, P: a where P, else b.
fn cFsel(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x008, .a = FABS, .b = FABS });
    _ = try cx.predNot(87, false);
}

/// FSETP.cmp(.FTZ).bool Pd, Pd1, a, b, Paccum
fn cFsetp(cx: *Cx) Error!void {
    _ = try cx.pred(81, false);
    _ = try cx.pred(84, false);
    try alu(cx, .{ .op = 0x00b, .a = FABS, .b = FABS });
    _ = try cx.predNot(87, false);
    _ = try cx.mod(76, 4, &FCMP);
    _ = try cx.flag(80, "FTZ");
    _ = try cx.mod(74, 2, &BOOL);
}

/// FCHK Pd, a, b: whether a / b needs the slow path (IEEE division).
fn cFchk(cx: *Cx) Error!void {
    _ = try cx.pred(81, false);
    try alu(cx, .{ .op = 0x102, .a = INT, .b = .{ .src = .{ .imm = .f32 } } });
}

/// MUFU.fn Rd, b: the special-function unit (exp2, rcp, rsqrt, ...).
fn cMufu(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x108, .b = FABS });
    _ = try cx.mod(74, 6, &MUFU);
}

// Halves ---------------------------------------------------------------------------

fn hmods(cx: *Cx, f32_bit: bool) Error!void {
    if (f32_bit) _ = try cx.flag(78, "F32");
    _ = try cx.flag(85, "BF16_V2");
    _ = try cx.flag(80, "FTZ");
    _ = try cx.flag(77, "SAT");
}

/// HADD2(.F32) Rd, a, b: two halves at once (.F32: one f32 result, how
/// ptxas widens a half).
fn cHadd2(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x030, .a = HALF, .bc = HALF_SPEC, .half = true });
    try hmods(cx, true);
}

fn cHmul2(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x032, .a = HALF, .b = HALF, .half = true });
    try hmods(cx, false);
}

/// HFMA2 Rd, a, b, c (an immediate b or c as two halves)
fn cHfma2(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x031, .a = HALF, .b = HALF, .c = HALF, .half = true });
    try hmods(cx, true);
}

fn cHmnmx2(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x040, .a = HALF, .b = HALF, .half = true });
    _ = try cx.predNot(87, false);
    _ = try cx.flag(85, "BF16_V2");
    _ = try cx.flag(80, "FTZ");
}

// Conversions ----------------------------------------------------------------------

/// F2FP.(F16|BF16).F32.PACK_AB Rd, a, b: two f32 rounded into halves, a's
/// high, b's low.
fn cF2fp(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x03e, .a = INT, .b = INT, .c = .rz });
    _ = try cx.mod(76, 1, &.{ "F16", "BF16" });
    try cx.always("F32");
    try cx.always("PACK_AB");
}

/// After a conversion's types: the 64-bit opcode when either is 64 bits.
fn wideOp(cx: *Cx, op64: u9) void {
    if (cx.enc() and (cx.w.get(76, 1) == 1 and cx.w.get(75, 1) == 1 or cx.w.get(84, 2) == 3)) cx.w.put(0, 9, op64);
}

/// F2I(.type)(.F64)(.round)(.NTZ) Rd, b
fn cF2i(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x105, .b = FABS });
    _ = try cx.modBits(&.{ 72, 75, 76 }, &ITYPES_S32);
    _ = try cx.mod(84, 2, &FTYPES_F32);
    _ = try cx.mod(78, 2, &FRND);
    _ = try cx.flag(77, "NTZ");
    _ = try cx.flag(80, "FTZ");
    wideOp(cx, 0x111);
}

/// I2F(.F64)(.type)(.round) Rd, b (a byte of b with .B1..B3)
fn cI2f(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x106, .b = .{ .src = .{ .imm = .signed, .sel = .byte } } });
    _ = try cx.mod(75, 2, &FTYPES_F32);
    _ = try cx.modBits(&.{ 74, 84, 85 }, &ITYPES_S32);
    _ = try cx.mod(78, 2, &RND);
    wideOp(cx, 0x112);
}

/// F2F.dst.src(.round)(.FTZ) Rd, b
fn cF2f(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x104, .b = FABS });
    _ = try cx.mod(75, 2, &FTYPES);
    _ = try cx.mod(84, 2, &FTYPES);
    _ = try cx.mod(78, 2, &RND);
    _ = try cx.flag(80, "FTZ");
    wideOp(cx, 0x110);
}

/// I2FP.F32.U32 / .S32 Rd, b (sm_90's integer to float)
fn cI2fp(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x045, .b = SINT });
    _ = try cx.mod(75, 2, &FTYPES);
    _ = try cx.modBits(&.{ 74, 84, 85 }, &ITYPES);
}

/// F2IP.U8.F32.NTZ Rd, a, b, c: a float to a saturated byte (the one
/// form ptxas emits for cvt.rni.sat.u8.f32; its fields are not otherwise
/// known).
fn cF2ip(cx: *Cx) Error!void {
    try cx.always("U8");
    try cx.always("F32");
    try cx.always("NTZ");
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x043, .a = INT, .b = INT, .c = INT });
    cx.put(74, 1, 1);
}

// Tensor cores ---------------------------------------------------------------------

/// HMMA.shape.dst(.src) Rd, a, b, c: f16 (or bf16) a, b; f16 or f32 c, d.
fn cHmma(cx: *Cx) Error!void {
    cx.put(0, 12, 0x23c);
    _ = try cx.modBits(&.{ 75, 78, 79 }, &.{ "1688", "16816", "1684", "?" });
    _ = try cx.mod(76, 1, &.{ "F16", "F32" });
    _ = try cx.mod(82, 2, &.{ "", "BF16", "TF32", "?" });
    _ = try cx.reg(16);
    try cx.srcReg(24, SLOT_A, .none);
    try cx.srcReg(32, SLOT_B, .none);
    try cx.srcReg(64, SLOT_C, .none);
}

/// IMMA.shape.atype.btype Rd, a.ROW, b.COL, c: int8 (or int4) a, b; s32
/// c, d.
fn cImma(cx: *Cx) Error!void {
    const types = [_][]const u8{ "U8", "S8", "U4", "S4" };
    cx.put(0, 12, 0x237);
    _ = try cx.modBits(&.{ 75, 85, 86 }, &.{ "8816", "?", "8832", "?", "16816", "16832", "16864", "?" });
    _ = try cx.modBits(&.{ 76, 83 }, &types);
    _ = try cx.modBits(&.{ 78, 84 }, &types);
    _ = try cx.flag(82, "SAT");
    _ = try cx.reg(16);
    try cx.srcReg(24, SLOT_A, .row);
    try cx.srcReg(32, SLOT_B, .col);
    try cx.srcReg(64, SLOT_C, .none);
    cx.put(74, 1, 1); // (b is column-major)
}

// ── The forms ───────────────────────────────────────────────────────────────

const Codec = *const fn (*Cx) Error!void;

const Form = struct {
    name: []const u8,
    /// Bits 0..11, or with `alu` bits 0..8 (the form in 9..11 any).
    opcode: u12,
    alu: bool = false,
    /// On the uniform datapath: its guard is a uniform predicate.
    uniform: bool = false,
    codec: Codec,
};

const FORMS = [_]Form{
    .{ .name = "NOP", .opcode = 0x918, .codec = cNop },
    .{ .name = "EXIT", .opcode = 0x94d, .codec = cExit },
    .{ .name = "BRA", .opcode = 0x947, .codec = cBra },
    .{ .name = "BRA", .opcode = 0x547, .codec = cBra },
    .{ .name = "CALL", .opcode = 0x944, .codec = cCall },
    .{ .name = "RET", .opcode = 0x950, .codec = cRet },
    .{ .name = "BSSY", .opcode = 0x945, .codec = cBssy },
    .{ .name = "BSYNC", .opcode = 0x941, .codec = cBsync },
    .{ .name = "WARPSYNC", .opcode = 0x348, .codec = cWarpsync },
    .{ .name = "BAR", .opcode = 0xb1d, .codec = cBar },
    .{ .name = "S2R", .opcode = 0x919, .codec = cS2r },
    .{ .name = "S2UR", .opcode = 0x9c3, .codec = cS2ur },
    .{ .name = "CS2R", .opcode = 0x805, .codec = cCs2r },
    .{ .name = "R2UR", .opcode = 0x2ca, .codec = cR2ur },
    .{ .name = "LDC", .opcode = 0xb82, .codec = cLdcR },
    .{ .name = "LDCU", .opcode = 0x7ac, .codec = cLdcU },
    .{ .name = "LDG", .opcode = 0x981, .codec = cLdg },
    .{ .name = "STG", .opcode = 0x986, .codec = cStg },
    .{ .name = "LDL", .opcode = 0x983, .codec = cLdl },
    .{ .name = "STL", .opcode = 0x387, .codec = cStl },
    .{ .name = "LDS", .opcode = 0x984, .codec = cLds },
    .{ .name = "STS", .opcode = 0x388, .codec = cSts },
    .{ .name = "STS", .opcode = 0x988, .codec = cSts },
    .{ .name = "PLOP3", .opcode = 0x81c, .codec = cPlop3 },
    .{ .name = "UPLOP3", .opcode = 0x89c, .uniform = true, .codec = cUplop3 },
    .{ .name = "SEL", .opcode = 0x607, .codec = cSel },
    .{ .name = "SHFL", .opcode = 0x389, .codec = cShfl },
    .{ .name = "SHFL", .opcode = 0x589, .codec = cShfl },
    .{ .name = "SHFL", .opcode = 0x989, .codec = cShfl },
    .{ .name = "SHFL", .opcode = 0xf89, .codec = cShfl },
    .{ .name = "VOTE", .opcode = 0x806, .codec = cVote },
    .{ .name = "VOTEU", .opcode = 0x886, .codec = cVoteu },
    .{ .name = "HMMA", .opcode = 0x23c, .codec = cHmma },
    .{ .name = "IMMA", .opcode = 0x237, .codec = cImma },
    .{ .name = "MOV", .opcode = 0x002, .alu = true, .codec = cMov },
    .{ .name = "UMOV", .opcode = 0x082, .alu = true, .codec = cUmov },
    .{ .name = "IADD", .opcode = 0x035, .alu = true, .codec = cIadd },
    .{ .name = "IADD3", .opcode = 0x010, .alu = true, .codec = cIadd3 },
    .{ .name = "UIADD3", .opcode = 0x090, .alu = true, .uniform = true, .codec = cUiadd3 },
    .{ .name = "IMAD", .opcode = 0x024, .alu = true, .codec = cImad },
    .{ .name = "IMAD", .opcode = 0x025, .alu = true, .codec = cImad },
    .{ .name = "IMAD", .opcode = 0x027, .alu = true, .codec = cImad },
    .{ .name = "ISETP", .opcode = 0x00c, .alu = true, .codec = cIsetp },
    .{ .name = "UISETP", .opcode = 0x08c, .alu = true, .uniform = true, .codec = cUisetp },
    .{ .name = "LOP3", .opcode = 0x012, .alu = true, .codec = cLop3 },
    .{ .name = "ULOP3", .opcode = 0x092, .alu = true, .uniform = true, .codec = cUlop3 },
    .{ .name = "LEA", .opcode = 0x011, .alu = true, .codec = cLea },
    .{ .name = "ULEA", .opcode = 0x091, .alu = true, .uniform = true, .codec = cUlea },
    .{ .name = "SHF", .opcode = 0x019, .alu = true, .codec = cShf },
    .{ .name = "USHF", .opcode = 0x099, .alu = true, .uniform = true, .codec = cUshf },
    .{ .name = "PRMT", .opcode = 0x016, .alu = true, .codec = cPrmt },
    .{ .name = "SEL", .opcode = 0x007, .alu = true, .codec = cSel },
    .{ .name = "VIMNMX", .opcode = 0x048, .alu = true, .codec = cVimnmx },
    .{ .name = "IABS", .opcode = 0x013, .alu = true, .codec = cIabs },
    .{ .name = "POPC", .opcode = 0x109, .alu = true, .codec = cPopc },
    .{ .name = "BREV", .opcode = 0x101, .alu = true, .codec = cBrev },
    .{ .name = "FLO", .opcode = 0x100, .alu = true, .codec = cFlo },
    .{ .name = "IDP", .opcode = 0x026, .alu = true, .codec = cIdp },
    .{ .name = "FFMA", .opcode = 0x023, .alu = true, .codec = cFfma },
    .{ .name = "UFFMA", .opcode = 0x055, .alu = true, .uniform = true, .codec = cUffma },
    .{ .name = "FADD", .opcode = 0x021, .alu = true, .codec = cFadd },
    .{ .name = "FMUL", .opcode = 0x020, .alu = true, .codec = cFmul },
    .{ .name = "FMNMX", .opcode = 0x009, .alu = true, .codec = cFmnmx },
    .{ .name = "FSEL", .opcode = 0x008, .alu = true, .codec = cFsel },
    .{ .name = "FSETP", .opcode = 0x00b, .alu = true, .codec = cFsetp },
    .{ .name = "FCHK", .opcode = 0x102, .alu = true, .codec = cFchk },
    .{ .name = "MUFU", .opcode = 0x108, .alu = true, .codec = cMufu },
    .{ .name = "HADD2", .opcode = 0x030, .alu = true, .codec = cHadd2 },
    .{ .name = "HMUL2", .opcode = 0x032, .alu = true, .codec = cHmul2 },
    .{ .name = "HFMA2", .opcode = 0x031, .alu = true, .codec = cHfma2 },
    .{ .name = "HMNMX2", .opcode = 0x040, .alu = true, .codec = cHmnmx2 },
    .{ .name = "F2FP", .opcode = 0x03e, .alu = true, .codec = cF2fp },
    .{ .name = "F2I", .opcode = 0x105, .alu = true, .codec = cF2i },
    .{ .name = "F2I", .opcode = 0x111, .alu = true, .codec = cF2i },
    .{ .name = "I2F", .opcode = 0x106, .alu = true, .codec = cI2f },
    .{ .name = "I2F", .opcode = 0x112, .alu = true, .codec = cI2f },
    .{ .name = "F2F", .opcode = 0x104, .alu = true, .codec = cF2f },
    .{ .name = "F2F", .opcode = 0x110, .alu = true, .codec = cF2f },
    .{ .name = "I2FP", .opcode = 0x045, .alu = true, .codec = cI2fp },
    .{ .name = "F2IP", .opcode = 0x043, .alu = true, .codec = cF2ip },
};

fn formOf(name: []const u8) ?*const Form {
    for (&FORMS) |*f| {
        if (eql(f.name, name)) return f;
    }
    return null;
}

fn formAt(op12: u12) ?*const Form {
    for (&FORMS) |*f| {
        if (!f.alu and f.opcode == op12) return f;
    }
    for (&FORMS) |*f| {
        if (f.alu and f.opcode == op12 & 0x1ff) return f;
    }
    return null;
}

/// Whether `in` runs on the uniform datapath (its guard a uniform
/// predicate).
pub fn isUniform(in: *const Instr) bool {
    const f = formOf(in.op) orelse return false;
    return f.uniform;
}

// ── Encoding and decoding ───────────────────────────────────────────────────

/// `in`'s 128 bits, as the instruction at byte `pc` of its kernel; a branch
/// goes to byte `target` (or to its own .target operand).
pub fn encode(in: *const Instr, pc: u64, target: ?u64) Error!Word {
    const form = formOf(in.op) orelse return error.Unknown;
    // (a uniform op's guard is a uniform predicate, a warp op's a warp one)
    if (in.uguard != form.uniform and (in.guard.n != PT or in.guard.not)) return error.Syntax;
    var cx = Cx{ .dir = .enc, .in = in.*, .pc = pc, .target = target };
    cx.w.put(12, 3, in.guard.n);
    cx.w.bit(15, in.guard.not);
    try form.codec(&cx);
    if (cx.taken != in.n_ops) return error.Syntax;
    // (every modifier written must mean something)
    if (cx.used != (@as(u32, 1) << @intCast(in.n_mods)) - 1) return error.Unknown;
    in.control.apply(&cx.w);
    return cx.w;
}

/// The instruction in words `lo` (bits 63..0) and `hi`, at byte `pc` of its
/// kernel (a branch's target comes back absolute, as `.target`). Its `op`
/// and `mods` are static strings, its numbers `.imm`. A word with any bit
/// this module does not account for is error.Unknown.
pub fn decode(lo: u64, hi: u64, pc: u64) Error!Instr {
    const w = Word.of(lo, hi);
    const form = formAt(@intCast(w.get(0, 12))) orelse return error.Unknown;
    var cx = Cx{ .dir = .dec, .w = w, .in = .{ .op = form.name, .uguard = form.uniform }, .pc = pc };
    cx.in.control = Control.of(w);
    if (cx.in.control.read == 6 or cx.in.control.write == 6) return error.Unknown;
    cx.in.guard = .{ .n = @intCast(w.get(12, 3)), .not = w.get(15, 1) == 1 };
    try form.codec(&cx);
    const again = try encode(&cx.in, pc, null);
    if (again.bits != w.bits) return error.Unknown;
    return cx.in;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── Printing ────────────────────────────────────────────────────────────────

pub const FormatError = error{NoSpaceLeft};

const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn str(o: *Out, s: []const u8) FormatError!void {
        if (o.len + s.len > o.buf.len) return error.NoSpaceLeft;
        @memcpy(o.buf[o.len..][0..s.len], s);
        o.len += s.len;
    }

    fn print(o: *Out, comptime f: []const u8, args: anytype) FormatError!void {
        const s = std.fmt.bufPrint(o.buf[o.len..], f, args) catch return error.NoSpaceLeft;
        o.len += s.len;
    }
};

/// `in` as nvdisasm prints it, with its control field, into `buf`:
/// "[B------:R-:W0:Y:S01] @!P0 IMAD.WIDE.U32 R2, R5.reuse, 0x4, R2". A
/// branch's target prints as its address (`(0x1a0)), where nvdisasm names
/// it with a label of the kernel's.
pub fn format(in: *const Instr, buf: []u8) FormatError![]const u8 {
    var o = Out{ .buf = buf };
    var cb: [21]u8 = undefined;
    try o.str(in.control.format(&cb));
    try o.str(" ");
    if (in.guard.n != PT or in.guard.not) {
        try o.str("@");
        try fmtPred(&o, if (in.uguard) "UP" else "P", in.guard);
        try o.str(" ");
    }
    try o.str(in.op);
    for (in.mods[0..in.n_mods]) |m| {
        try o.str(".");
        try o.str(m);
    }
    for (in.operands(), 0..) |x, i| {
        // (RET's target follows its register with no comma)
        const bare = i > 0 and eql(in.op, "RET") and (x == .target or x == .label);
        try o.str(if (i == 0 or bare) " " else ", ");
        try fmtOperand(&o, x);
    }
    // (nvdisasm prints +INF and QNAN with a space after; not at the end)
    while (o.len > 0 and o.buf[o.len - 1] == ' ') o.len -= 1;
    return o.buf[0..o.len];
}

fn fmtPred(o: *Out, file: []const u8, p: Pred) FormatError!void {
    if (p.not) try o.str("!");
    try o.str(file);
    if (p.n == PT) try o.str("T") else try o.print("{d}", .{p.n});
}

fn fmtReg(o: *Out, file: []const u8, r: Reg) FormatError!void {
    if (r.neg) try o.str("-");
    if (r.abs) try o.str("|");
    try o.str(file);
    if (r.n == RZ) try o.str("Z") else try o.print("{d}", .{r.n});
    if (r.abs) try o.str("|");
    if (r.reuse) try o.str(".reuse");
    try o.str(SEL_NAMES[@intFromEnum(r.sel)]);
}

fn fmtSigned(o: *Out, v: i64) FormatError!void {
    if (v < 0) try o.print("-0x{x}", .{@as(u64, @intCast(-v))}) else try o.print("0x{x}", .{@as(u64, @intCast(v))});
}

fn fmtOperand(o: *Out, x: Operand) FormatError!void {
    switch (x) {
        .gpr => |r| try fmtReg(o, "R", r),
        .ugpr => |r| try fmtReg(o, "UR", r),
        .pred => |p| try fmtPred(o, "P", p),
        .upred => |p| try fmtPred(o, "UP", p),
        .num => |t| try o.str(t),
        .imm => |i| switch (i.kind) {
            .hex => try o.print("0x{x}", .{i.bits}),
            .signed => try fmtSigned(o, @as(i32, @bitCast(@as(u32, @truncate(i.bits))))),
            .f32 => try fmtFloat(o, @bitCast(@as(u32, @truncate(i.bits)))),
            .f16 => try fmtFloat(o, @as(f16, @bitCast(@as(u16, @truncate(i.bits))))),
        },
        .cbuf => |c| {
            if (c.neg) try o.str("-");
            if (c.abs) try o.str("|");
            try o.print("c[0x{x}][", .{c.bank});
            if (c.reg != RZ) {
                try o.print("{s}{d}", .{ if (c.ureg) "UR" else "R", c.reg });
                if (c.offset != 0) try o.print("+0x{x}", .{c.offset});
            } else try o.print("0x{x}", .{c.offset});
            try o.str("]");
            if (c.abs) try o.str("|");
        },
        .addr => |a| {
            if (a.desc) |d| {
                try o.str("desc[");
                try fmtReg(o, "UR", .{ .n = d });
                try o.str("]");
            }
            try o.str("[");
            var any = false;
            if (a.reg != RZ) {
                try o.print("R{d}", .{a.reg});
                if (a.wide) try o.str(".64");
                any = true;
            }
            if (a.ureg) |u| {
                if (any) try o.str("+");
                try fmtReg(o, "UR", .{ .n = u });
                any = true;
            }
            if (a.offset != 0 or !any) {
                if (any) try o.str("+");
                if (!any and a.offset == 0) try o.str("RZ") else try fmtSigned(o, a.offset);
            }
            try o.str("]");
        },
        .sreg => |n| try o.str(sregName(n) orelse "SR_?"),
        .label => |l| try o.print("`({s})", .{l}),
        .target => |t| try o.print("`(0x{x})", .{t}),
        .barrier => |b| try o.print("B{d}", .{b}),
    }
}

/// A float as nvdisasm prints it: below 1e9, C's %.20g of its value (the
/// float's exact decimal expansion rounded half to even at 20 digits,
/// trailing zeros dropped); from 1e9 up, %.20e (21 digits, all kept); and
/// +INF, -INF, +QNAN, -QNAN, which nvdisasm follows with a space.
fn fmtFloat(o: *Out, x: f32) FormatError!void {
    const bits: u32 = @bitCast(x);
    const neg = bits >> 31 == 1;
    const e_bits: u32 = (bits >> 23) & 0xff;
    const frac: u32 = bits & 0x7fffff;
    if (e_bits == 0xff) return o.str(if (frac != 0) (if (neg) "-QNAN " else "+QNAN ") else if (neg) "-INF " else "+INF ");
    if (neg) try o.str("-");
    if (e_bits == 0 and frac == 0) return o.str("0");
    var m: u32 = if (e_bits == 0) frac else frac | (1 << 23);
    var e: i32 = if (e_bits == 0) -149 else @as(i32, @intCast(e_bits)) - 150;
    while (m & 1 == 0) {
        m >>= 1;
        e += 1;
    }
    // m * 2^e = N * 10^p exactly, N an integer
    var n = Big{};
    n.limbs[0] = m;
    n.len = 1;
    var p: i32 = 0;
    if (e >= 0) n.mulPow(2, @intCast(e)) else {
        n.mulPow(5, @intCast(-e));
        p = e;
    }
    var digits: [160]u8 = undefined;
    var nd = n.decimal(&digits);
    // the first digit's power of ten
    var x10: i32 = @as(i32, @intCast(nd)) + p - 1;
    const sci = x10 >= 9;
    const keep: usize = if (sci) 21 else 20;
    if (nd > keep) {
        const up = blk: {
            if (digits[keep] != '5') break :blk digits[keep] > '5';
            for (digits[keep + 1 .. nd]) |dg| {
                if (dg != '0') break :blk true;
            }
            break :blk (digits[keep - 1] - '0') % 2 == 1;
        };
        nd = keep;
        if (up) {
            var i: usize = keep;
            while (i > 0) {
                i -= 1;
                if (digits[i] != '9') {
                    digits[i] += 1;
                    break;
                }
                digits[i] = '0';
            } else {
                digits[0] = '1';
                x10 += 1;
            }
        }
    }
    if (sci) {
        // %.20e: the digits padded to 21
        while (nd < 21) : (nd += 1) digits[nd] = '0';
        try o.str(digits[0..1]);
        try o.str(".");
        try o.str(digits[1..21]);
        try o.print("e+{d:0>2}", .{@as(u32, @intCast(x10))});
        return;
    }
    while (nd > 1 and digits[nd - 1] == '0') nd -= 1;
    if (x10 < -4) {
        try o.str(digits[0..1]);
        if (nd > 1) {
            try o.str(".");
            try o.str(digits[1..nd]);
        }
        try o.print("e-{d:0>2}", .{@as(u32, @intCast(-x10))});
    } else if (x10 >= 0) {
        const whole: usize = @intCast(x10 + 1);
        if (nd <= whole) {
            try o.str(digits[0..nd]);
            for (nd..whole) |_| try o.str("0");
        } else {
            try o.str(digits[0..whole]);
            try o.str(".");
            try o.str(digits[whole..nd]);
        }
    } else {
        try o.str("0.");
        for (0..@as(usize, @intCast(-x10 - 1))) |_| try o.str("0");
        try o.str(digits[0..nd]);
    }
}

/// A fixed-size unsigned integer (enough for a float's exact decimal
/// expansion: 2^24 * 5^149 is under 2^371).
const Big = struct {
    limbs: [13]u32 = .{0} ** 13,
    len: usize = 0,

    fn mulSmall(b: *Big, k: u32) void {
        var carry: u64 = 0;
        for (b.limbs[0..b.len]) |*l| {
            const v = @as(u64, l.*) * k + carry;
            l.* = @truncate(v);
            carry = v >> 32;
        }
        if (carry != 0 and b.len < b.limbs.len) {
            b.limbs[b.len] = @intCast(carry);
            b.len += 1;
        }
    }

    fn mulPow(b: *Big, base: u32, count: u32) void {
        // (in steps that fit 32 bits: 5^13, 2^31)
        const step: u32 = if (base == 5) 13 else 31;
        const big: u32 = if (base == 5) 1220703125 else 1 << 31;
        var left = count;
        while (left >= step) : (left -= step) b.mulSmall(big);
        var k: u32 = 1;
        for (0..left) |_| k *= base;
        b.mulSmall(k);
    }

    fn divSmall(b: *Big, d: u32) u32 {
        var rem: u64 = 0;
        var i = b.len;
        while (i > 0) {
            i -= 1;
            const v = rem << 32 | b.limbs[i];
            b.limbs[i] = @intCast(v / d);
            rem = v % d;
        }
        while (b.len > 0 and b.limbs[b.len - 1] == 0) b.len -= 1;
        return @intCast(rem);
    }

    /// Its decimal digits, most significant first, into `out`.
    fn decimal(b: *Big, out: []u8) usize {
        var rev: [160]u8 = undefined;
        var n: usize = 0;
        while (b.len > 0) {
            var chunk = b.divSmall(1_000_000_000);
            const last = b.len == 0;
            var k: usize = 0;
            while (k < 9 and (!last or chunk != 0)) : (k += 1) {
                rev[n] = '0' + @as(u8, @intCast(chunk % 10));
                chunk /= 10;
                n += 1;
            }
        }
        for (0..n) |i| out[i] = rev[n - 1 - i];
        return n;
    }
};

/// The registers a load's destination or a store's data spans: 4 for
/// .128, 2 for .64.
pub fn dataWidth(in: *const Instr) u8 {
    if (in.has("128")) return 4;
    if (in.has("64")) return 2;
    return 1;
}

/// How many consecutive registers operand `i` of `in` spans, when it is a
/// register: a load's destination or a store's data (dataWidth), MOV.64's
/// and LDCU.64's destination, every register of IADD.64 and SEL.64,
/// IMAD.WIDE's destination and c, 64-bit compares' sources, conversions'
/// 64-bit sides, CS2R's pair, the MMAs' fragments (m16n8k16: a four, b
/// two, c and d four).
pub fn regsAt(in: *const Instr, i: usize) u8 {
    const op = in.op;
    if (eql(op, "HMMA") or eql(op, "IMMA")) {
        const hmma = eql(op, "HMMA");
        const small = in.has("1688") or in.has("16816") and !hmma;
        return switch (i) {
            0, 3 => if (hmma and in.has("F16")) 2 else 4,
            1 => if (small) 2 else 4,
            2 => if (small) 1 else 2,
            else => 1,
        };
    }
    if (eql(op, "IADD") or eql(op, "SEL")) return dataWidth(in);
    if (isData(in, i)) return dataWidth(in);
    if (eql(op, "ISETP") or eql(op, "UISETP")) return if ((in.has("U64") or in.has("S64")) and (i == 2 or i == 3)) 2 else 1;
    if (eql(op, "IMAD")) return if (in.has("WIDE") and (i == 0 or i == 3)) 2 else 1;
    if (eql(op, "CS2R")) return if (i == 0 and !in.has("32")) 2 else 1;
    if (eql(op, "F2I") or eql(op, "I2F") or eql(op, "F2F")) {
        const int64 = in.has("S64") or in.has("U64");
        const dst64 = if (eql(op, "F2I")) int64 else if (eql(op, "I2F")) in.has("F64") else in.n_mods > 0 and eql(in.mods[0], "F64");
        const src64 = if (eql(op, "F2I")) in.has("F64") else if (eql(op, "I2F")) int64 else in.n_mods > 1 and eql(in.mods[1], "F64");
        return if ((i == 0 and dst64) or (i == 1 and src64)) 2 else 1;
    }
    if (i == 0) return dataWidth(in);
    return 1;
}

/// The highest general register an instruction touches (regsAt's groups
/// included), or null.
pub fn highestGpr(in: *const Instr) ?u8 {
    var top: ?u8 = null;
    for (in.operands(), 0..) |o, i| {
        const t: u8 = switch (o) {
            .gpr => |g| if (g.n != RZ) g.n + regsAt(in, i) - 1 else continue,
            .addr => |a| if (a.reg != RZ) a.reg + @as(u8, if (a.wide) 1 else 0) else continue,
            .cbuf => |c| if (c.reg != RZ and !c.ureg) c.reg else continue,
            else => continue,
        };
        top = if (top) |x| @max(x, t) else t;
    }
    return top;
}

fn isData(in: *const Instr, i: usize) bool {
    return (eql(in.op, "STG") or eql(in.op, "STL") or eql(in.op, "STS")) and i == 1;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "the control field: parsed, put in bits 105..121, printed" {
    const c = try Control.parse("[B0-2---:R1:W3:Y:S06]");
    try testing.expectEqual(@as(u6, 0b101), c.wait);
    try testing.expectEqual(@as(u3, 1), c.read);
    try testing.expectEqual(@as(u3, 3), c.write);
    try testing.expect(c.yield);
    try testing.expectEqual(@as(u4, 6), c.stall);
    var w = Word{};
    c.apply(&w);
    try testing.expectEqual(@as(u64, 6), w.get(105, 4));
    try testing.expectEqual(@as(u64, 0b101), w.get(116, 6));
    try testing.expectEqual(c, Control.of(w));
    var buf: [21]u8 = undefined;
    try testing.expectEqualStrings("[B0-2---:R1:W3:Y:S06]", c.format(&buf));
    try testing.expectError(error.Syntax, Control.parse("[B------:R-:W-:Y:S1]"));
}

test "operands: registers, predicates, constants, addresses, labels" {
    const in = try parse("[B------:R-:W-:-:S05] @!P1 LOP3.LUT R5, -R5.reuse, c[0x3][0x10], URZ, 0xfc, !PT");
    try testing.expectEqual(Pred{ .n = 1, .not = true }, in.guard);
    try testing.expectEqualStrings("LOP3", in.op);
    try testing.expect(in.has("LUT"));
    try testing.expectEqual(@as(usize, 6), in.n_ops);
    try testing.expectEqual(Reg{ .n = 5, .neg = true, .reuse = true }, in.ops[1].gpr);
    try testing.expectEqual(CBuf{ .bank = 3, .offset = 0x10 }, in.ops[2].cbuf);
    try testing.expectEqual(RZ, in.ops[3].ugpr.n);
    try testing.expectEqual(Pred{ .n = PT, .not = true }, in.ops[5].pred);
    const ld = try parse("LDG.E.128 R12, desc[UR4][R2.64+-0x10]");
    try testing.expectEqual(Addr{ .desc = 4, .reg = 2, .wide = true, .offset = -0x10 }, ld.ops[1].addr);
    const st = try parse("STL [R1+0x8], R0");
    try testing.expectEqual(Addr{ .reg = 1, .offset = 8 }, st.ops[0].addr);
    const br = try parse("@P2 BRA `(.L_x_2)");
    try testing.expectEqualStrings(".L_x_2", br.label().?);
    const to = try parse("BRA `(0x1a0)");
    try testing.expectEqual(@as(u64, 0x1a0), to.ops[0].target);
    const sh = try parse("LDS.U8 R21, [R2+UR4+0x700]");
    try testing.expectEqual(Addr{ .reg = 2, .ureg = 4, .offset = 0x700 }, sh.ops[1].addr);
    const hs = try parse("HADD2.F32 R6, -RZ, R4.reuse.H0_H0");
    try testing.expectEqual(Reg{ .n = 4, .reuse = true, .sel = .h0_h0 }, hs.ops[2].gpr);
    const ret = try parse("RET.REL.NODEC R12 `(lfm3_q80_quant)");
    try testing.expectEqual(@as(usize, 2), ret.n_ops);
    try testing.expectEqualStrings("lfm3_q80_quant", ret.label().?);
    const ug = try parse("@!UPT UIADD3 URZ, UPT, UPT, URZ, URZ, URZ");
    try testing.expect(ug.uguard and ug.guard.not);
    try testing.expectEqual(@as(u8, 3), (try parseOperand("B3")).barrier);
    const fa = try parse("FADD R0, -|R2|.reuse, -c[0x0][R3+0x10]");
    try testing.expectEqual(Reg{ .n = 2, .neg = true, .abs = true, .reuse = true }, fa.ops[1].gpr);
    try testing.expectEqual(CBuf{ .bank = 0, .offset = 0x10, .reg = 3, .neg = true }, fa.ops[2].cbuf);
    try testing.expectEqualStrings("-INF", (try parseOperand("-INF")).num);
}

test "floats as nvdisasm prints them (%.20g below 1e9, %.20e from it)" {
    const cases = [_]struct { f32, []const u8 }{
        .{ 1.0, "1" },
        .{ 0.5, "0.5" },
        .{ -2.0, "-2" },
        .{ 0.0, "0" },
        .{ 1.4426950408889634, "1.4426950216293334961" },
        .{ 1.1754943508222875e-38, "1.175494350822287508e-38" },
        .{ 3.4028234663852886e38, "3.40282346638528859812e+38" },
        .{ 1e20, "1.00000002004087734272e+20" },
        .{ 1e9, "1.00000000000000000000e+09" },
        .{ 1e8, "100000000" },
        .{ 123456.789, "123456.7890625" },
        .{ 0.0001, "9.9999997473787516356e-05" },
        .{ 1e-10, "1.00000001335143196e-10" },
        .{ 0.1, "0.10000000149011611938" },
        .{ 1.875, "1.875" },
        // (nvdisasm's own output for these, from a probe kernel)
        .{ 1e10, "1.00000000000000000000e+10" },
        .{ 1e14, "1.00000000376832000000e+14" },
        .{ 4294967296.0, "4.29496729600000000000e+09" },
        .{ 1e25, "9.99999956202352624743e+24" },
        .{ 65504.0, "65504" },
        .{ 0.3, "0.30000001192092895508" },
        .{ 1e-3, "0.0010000000474974513054" },
        .{ 3.14159265, "3.1415927410125732422" },
        .{ 1e-20, "9.999999682655225389e-21" },
        .{ 1e-40, "9.9999461011147595815e-41" },
        .{ 1e-45, "1.4012984643248170709e-45" },
        .{ std.math.inf(f32), "+INF" },
        .{ -std.math.inf(f32), "-INF" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var o = Out{ .buf = &buf };
        try fmtFloat(&o, c[0]);
        try testing.expectEqualStrings(c[1], std.mem.trimEnd(u8, o.buf[0..o.len], " "));
    }
}

/// The vectors' kernels: each instruction with its words and address, and
/// the labels' addresses (to print a branch's target as format does).
const Vectors = struct {
    const data = @embedFile("sm120_vectors.txt");

    const Line = struct { lo: u64, hi: u64, text: []const u8, pc: u64 };

    const Kernel = struct {
        lines: [4096]Line = undefined,
        n: usize = 0,
        labels: [256]struct { name: []const u8, at: u64 } = undefined,
        n_labels: usize = 0,

        fn at(k: *const Kernel, name: []const u8) ?u64 {
            for (k.labels[0..k.n_labels]) |l| {
                if (eql(l.name, name)) return l.at;
            }
            return null;
        }
    };

    fn read(block: []const u8, k: *Kernel) !void {
        k.n = 0;
        k.n_labels = 0;
        var pc: u64 = 0;
        var lines = std.mem.splitScalar(u8, block, '\n');
        _ = lines.next(); // (the kernel's name: its label follows)
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[line.len - 1] == ':') {
                k.labels[k.n_labels] = .{ .name = line[0 .. line.len - 1], .at = pc };
                k.n_labels += 1;
                continue;
            }
            // "<hi>_<lo> <control> <text>"
            k.lines[k.n] = .{
                .hi = try std.fmt.parseInt(u64, line[0..16], 16),
                .lo = try std.fmt.parseInt(u64, line[17..33], 16),
                .text = line[34..],
                .pc = pc,
            };
            k.n += 1;
            pc += 16;
        }
    }

    var kernel: Kernel = .{};
};

test "ptxas's vectors: every instruction's 128 bits (sm120_vectors.txt)" {
    var kernels = std.mem.splitSequence(u8, Vectors.data, "# kernel ");
    _ = kernels.next();
    var n: usize = 0;
    var failures: usize = 0;
    const k = &Vectors.kernel;
    while (kernels.next()) |block| {
        try Vectors.read(block, k);
        for (k.lines[0..k.n]) |l| {
            n += 1;
            const in = parse(l.text) catch |e| {
                std.debug.print("parse  \"{s}\": {s}\n", .{ l.text, @errorName(e) });
                failures += 1;
                continue;
            };
            const target: ?u64 = if (in.label()) |name| k.at(name) else null;
            const w = encode(&in, l.pc, target) catch |e| {
                std.debug.print("encode \"{s}\": {s}\n", .{ l.text, @errorName(e) });
                failures += 1;
                continue;
            };
            if (w.lo() != l.lo or w.hi() != l.hi) {
                std.debug.print("encode \"{s}\": got {x:0>16}_{x:0>16} want {x:0>16}_{x:0>16} (diff {x:0>16}_{x:0>16})\n", .{ l.text, w.hi(), w.lo(), l.hi, l.lo, w.hi() ^ l.hi, w.lo() ^ l.lo });
                failures += 1;
            }
        }
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} vectors failed\n", .{ failures, n });
        return error.TestUnexpectedResult;
    }
    try testing.expect(n > 2500);
}

/// The vector's text as format prints it: a branch's label as its address.
fn normalized(text: []const u8, k: *const Vectors.Kernel, buf: []u8) ![]const u8 {
    const open = std.mem.indexOf(u8, text, "`(") orelse return text;
    const close = std.mem.indexOfScalarPos(u8, text, open, ')') orelse return error.TestUnexpectedResult;
    const at = k.at(text[open + 2 .. close]) orelse return error.TestUnexpectedResult;
    return std.fmt.bufPrint(buf, "{s}`(0x{x}){s}", .{ text[0..open], at, text[close + 1 ..] });
}

test "ptxas's vectors decoded: the same 128 bits encoded again, nvdisasm's text printed" {
    var kernels = std.mem.splitSequence(u8, Vectors.data, "# kernel ");
    _ = kernels.next();
    var n: usize = 0;
    var failures: usize = 0;
    const k = &Vectors.kernel;
    while (kernels.next()) |block| {
        try Vectors.read(block, k);
        for (k.lines[0..k.n]) |l| {
            n += 1;
            const in = decode(l.lo, l.hi, l.pc) catch |e| {
                std.debug.print("decode \"{s}\": {s}\n", .{ l.text, @errorName(e) });
                failures += 1;
                continue;
            };
            const w = try encode(&in, l.pc, null);
            if (w.lo() != l.lo or w.hi() != l.hi) {
                std.debug.print("decoded \"{s}\" encodes to {x:0>16}_{x:0>16}\n", .{ l.text, w.hi(), w.lo() });
                failures += 1;
                continue;
            }
            var b1: [256]u8 = undefined;
            var b2: [256]u8 = undefined;
            const got = try format(&in, &b1);
            const want = try normalized(l.text, k, &b2);
            if (!eql(got, want)) {
                std.debug.print("format: \"{s}\"\n  want: \"{s}\"\n", .{ got, want });
                failures += 1;
                continue;
            }
            // (and the printed text reads back as the same instruction)
            const again = try parse(got);
            const w2 = try encode(&again, l.pc, null);
            if (w2.bits != w.bits) {
                std.debug.print("reparsed \"{s}\" encodes differently\n", .{got});
                failures += 1;
            }
        }
    }
    if (failures != 0) {
        std.debug.print("{d} of {d} vectors failed\n", .{ failures, n });
        return error.TestUnexpectedResult;
    }
}

/// `text` encoded at `pc`, then decoded: what an emulator sees.
fn roundTrip(text: []const u8, pc: u64) !Instr {
    const in = try parse(text);
    const w = try encode(&in, pc, null);
    return decode(w.lo(), w.hi(), pc);
}

test "decoded operands: what the emulator sees" {
    // a shuffle: the in-range predicate, then lane and clamp as numbers
    const sh = try roundTrip("SHFL.BFLY PT, R0, R3, 0x4, 0x181f", 0);
    try testing.expectEqualStrings("SHFL", sh.op);
    try testing.expectEqualStrings("BFLY", sh.mods[0]);
    try testing.expectEqual(Pred{}, sh.ops[0].pred);
    try testing.expectEqual(@as(u8, 0), sh.ops[1].gpr.n);
    try testing.expectEqual(Imm{ .bits = 4 }, sh.ops[3].imm);
    try testing.expectEqual(Imm{ .bits = 0x181f }, sh.ops[4].imm);
    // shared memory: a register, a uniform register and an offset
    const ld = try roundTrip("LDS.U8 R21, [R2+UR4+0x700]", 0);
    try testing.expectEqual(Addr{ .reg = 2, .ureg = 4, .offset = 0x700 }, ld.ops[1].addr);
    const st = try roundTrip("STS.128 [R3+-0x10], R8", 0);
    try testing.expectEqual(Addr{ .reg = 3, .offset = -0x10 }, st.ops[0].addr);
    // a branch and a convergence barrier: absolute targets
    const bra = try roundTrip("@!P0 BRA `(0x1a0)", 0x100);
    try testing.expectEqual(@as(u64, 0x1a0), bra.ops[0].target);
    try testing.expectEqual(Pred{ .n = 0, .not = true }, bra.guard);
    const bssy = try roundTrip("BSSY.RECONVERGENT B1, `(0x40)", 0x200);
    try testing.expectEqual(@as(u8, 1), bssy.ops[0].barrier);
    try testing.expectEqual(@as(u64, 0x40), bssy.ops[1].target);
    // two halves of an immediate, high first
    const hf = try roundTrip("HFMA2 R0, R4, 1, 1, R5.reuse", 0);
    try testing.expectEqual(Imm{ .bits = 0x3c00, .kind = .f16 }, hf.ops[2].imm);
    try testing.expectEqual(Reg{ .n = 5, .reuse = true }, hf.ops[4].gpr);
    // a half's selector, a byte's
    const ha = try roundTrip("HADD2.F32 R7, -RZ, R4.H1_H1", 0);
    try testing.expectEqual(Reg{ .n = RZ, .neg = true }, ha.ops[1].gpr);
    try testing.expectEqual(Sel.h1_h1, ha.ops[2].gpr.sel);
    try testing.expectEqual(Sel.b2, (try roundTrip("I2F.U8 R11, R0.B2", 0)).ops[1].gpr.sel);
    // a float immediate's bits; the special function in the modifiers
    const mu = try roundTrip("MUFU.RSQ R13, -QNAN", 0);
    try testing.expectEqualStrings("RSQ", mu.mods[0]);
    try testing.expectEqual(Imm{ .bits = 0xffc00000, .kind = .f32 }, mu.ops[1].imm);
    // the operands printed only when they are not RZ or PT
    const vo = try roundTrip("VOTE.ANY P3, P1", 0);
    try testing.expectEqual(@as(usize, 2), vo.n_ops);
    try testing.expectEqual(@as(usize, 3), (try roundTrip("VOTE.ANY R21, PT, P1", 0)).n_ops);
    const lp = try roundTrip("LOP3.LUT P0, RZ, R9, 0x7, RZ, 0xc0, !PT", 0);
    try testing.expectEqual(Pred{ .n = 0 }, lp.ops[0].pred);
    try testing.expectEqual(@as(usize, 7), lp.n_ops);
    const lx = try roundTrip("LEA.HI.X R9, R4, R3, R5, 0x3, P0", 0);
    try testing.expectEqual(@as(usize, 6), lx.n_ops);
    const bar = try roundTrip("BAR.SYNC.DEFER_BLOCKING 0x2, 0x40", 0);
    try testing.expectEqual(Imm{ .bits = 0x40 }, bar.ops[1].imm);
    // the uniform datapath's guard
    const ug = try roundTrip("@!UPT UIADD3 URZ, UPT, UPT, URZ, URZ, URZ", 0);
    try testing.expect(ug.uguard);
    // an IMMA's layouts and fragments
    const im = try roundTrip("IMMA.16832.S8.S8 R20, R4.ROW, R2.reuse.COL, R8", 0);
    try testing.expectEqual(Sel.row, im.ops[1].gpr.sel);
    try testing.expectEqual(@as(u8, 4), regsAt(&im, 1));
    try testing.expectEqual(@as(u8, 2), regsAt(&im, 2));
    try testing.expectEqual(@as(?u8, 23), highestGpr(&im));
}

test "decode refuses words it does not account for" {
    // (a NOP with a stray bit; an opcode no form has; scoreboard 6)
    try testing.expectError(error.Unknown, decode(0x0000_0000_0001_7918, 0x000f_c000_0000_0000, 0));
    try testing.expectError(error.Unknown, decode(0x0000_0000_0000_7fff, 0x000f_c000_0000_0000, 0));
    try testing.expectError(error.Unknown, decode(0x0000_0000_0000_7918, 0x000f_8000_0000_0000, 0));
    // (a decoded instruction's modifiers come out in nvdisasm's order)
    const in = try parse("ISETP.U32.GE.AND P0, PT, R2, R5, PT");
    const w = try encode(&in, 0, null);
    const d = try decode(w.lo(), w.hi(), 0);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("[B------:R-:W-:-:S00] ISETP.GE.U32.AND P0, PT, R2, R5, PT", try format(&d, &buf));
    // (a modifier that means nothing to the mnemonic is not dropped)
    const what = try parse("EXIT.WHAT");
    try testing.expectError(error.Unknown, encode(&what, 0, null));
}

test "every alu form's opcode stays clear of the exact ones (but its own: SEL.64 is SEL's unused form 3)" {
    for (FORMS) |f| {
        if (!f.alu) continue;
        for (1..8) |form| {
            const op: u12 = @intCast(f.opcode | form << 9);
            for (FORMS) |g| {
                if (!g.alu and g.opcode == op) try testing.expect(g.codec == f.codec);
            }
        }
    }
}
