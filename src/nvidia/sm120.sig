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
//! documentation only: none of it is copied), and for what NAK does not emit
//! (the two-source IADD and IADD.64, MOV.64 and UMOV.64, STL's 0x387, the
//! constant bits ptxas sets), ptxas's own output. The tests assemble every
//! instruction in sm120_vectors.txt (ptxas output, see
//! tools/gen_sm120_vectors.py), compare all 128 bits, decode the words
//! again and print them as nvdisasm did.
//!
//! What nvdisasm prints that `format` cannot: a branch's label (.L_x_3) is
//! the kernel's numbering of its targets, which one instruction does not
//! know, so a decoded branch prints its absolute byte target, `(0x1a0),
//! and parses back as one.
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

pub const Reg = struct {
    n: u8,
    neg: bool = false,
    abs: bool = false,
    reuse: bool = false,
};

pub const Pred = struct {
    n: u3 = PT,
    not: bool = false,
};

/// c[bank][offset], or c[bank][Rn+offset] through an index register (LDC);
/// an ALU source may be negated or its absolute value taken.
pub const CBuf = struct {
    bank: u5,
    offset: u32,
    reg: u8 = RZ,
    neg: bool = false,
    abs: bool = false,
};

/// A memory address: [Rn(.64)+offset], or desc[URd][Rn.64+offset] (a
/// global address through the 64-bit descriptor URd:URd+1).
pub const Addr = struct {
    desc: ?u8 = null,
    reg: u8 = RZ,
    wide: bool = false,
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
};

pub const MAX_OPERANDS = 8;
pub const MAX_MODS = 8;

pub const Instr = struct {
    control: Control = .{},
    guard: Pred = .{},
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

/// "Rn", "Rn.64", "Rn+0x8", "Rn.64+-0x10", "0x40": an address's register
/// part and offset.
fn addrInner(t: []const u8, a: *Addr) Error!void {
    var s = t;
    const cut = std.mem.indexOfAny(u8, s, "+-") orelse s.len;
    const head = std.mem.trim(u8, s[0..cut], " ");
    if (cut < s.len) {
        a.offset = std.math.cast(i32, try number(std.mem.trim(u8, s[cut..], " +"))) orelse return error.OutOfRange;
        if (s[cut] == '-') a.offset = -a.offset;
    }
    if (head.len == 0) return;
    if (head[0] == '0' or std.ascii.isDigit(head[0])) {
        a.offset = std.math.cast(i32, try number(head)) orelse return error.OutOfRange;
        return;
    }
    s = head;
    if (std.mem.endsWith(u8, s, ".64")) {
        a.wide = true;
        s = s[0 .. s.len - 3];
    }
    const r = regName(s) orelse return error.Syntax;
    if (r.uniform) return error.Syntax;
    a.reg = r.n;
}

/// "c[0x0][0x37c]", "c[0x3][R2+0x10]": a constant buffer reference.
fn cbufOf(t: []const u8) Error!CBuf {
    const mid = std.mem.indexOf(u8, t, "][") orelse return error.Syntax;
    if (!std.mem.endsWith(u8, t, "]")) return error.Syntax;
    const bank = try number(t[2..mid]);
    if (bank < 0 or bank > 31) return error.OutOfRange;
    const inner = t[mid + 2 .. t.len - 1];
    var cb = CBuf{ .bank = @intCast(bank), .offset = 0 };
    if (inner.len > 0 and inner[0] == 'R') {
        var a = Addr{};
        try addrInner(inner, &a);
        if (a.wide or a.offset < 0) return error.Syntax;
        cb.reg = a.reg;
        cb.offset = @intCast(a.offset);
    } else {
        const off = try number(inner);
        if (off < 0 or off > 0xffff) return error.OutOfRange;
        cb.offset = @intCast(off);
    }
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
        if (not or reuse) return error.Syntax;
        var cb = try cbufOf(t);
        cb.neg = neg;
        cb.abs = abs;
        return .{ .cbuf = cb };
    }
    if (predName(t)) |p| {
        if (neg or abs or reuse) return error.Syntax;
        const v = Pred{ .n = p.n, .not = not };
        return if (p.uniform) .{ .upred = v } else .{ .pred = v };
    }
    if (regName(t)) |r| {
        if (not) return error.Syntax;
        const v = Reg{ .n = r.n, .neg = neg, .abs = abs, .reuse = reuse };
        return if (r.uniform) .{ .ugpr = v } else .{ .gpr = v };
    }
    if (not or abs or reuse or neg) return error.Syntax;
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
        if (p.uniform) return error.Unknown;
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
    // Operands split on commas outside brackets.
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const ch: u8 = if (i < rest.len) rest[i] else ',';
        switch (ch) {
            '[', '(' => depth += 1,
            ']', ')' => depth -|= 1,
            ',' => if (depth == 0) {
                if (in.n_ops == MAX_OPERANDS) return error.Syntax;
                in.ops[in.n_ops] = try parseOperand(rest[start..i]);
                in.n_ops += 1;
                start = i + 1;
            },
            else => {},
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
                break :blk @as(u32, @bitCast(@as(f32, @floatCast(f))));
            },
            .f16 => blk: {
                const f = floatOf(t) orelse return error.Syntax;
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

    fn hasMod(cx: *Cx, m: []const u8) bool {
        for (cx.in.mods[0..cx.in.n_mods], 0..) |x, i| {
            if (std.mem.eql(u8, x, m)) {
                cx.used |= @as(u32, 1) << @intCast(i);
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

    /// A modifier field: value v prints as names[v] ("" prints nothing; the
    /// first "" is what encoding puts when none of the names is written).
    fn mod(cx: *Cx, at: u7, n: u7, names: []const []const u8) Error!u64 {
        if (cx.enc()) {
            var pick: ?usize = null;
            for (names, 0..) |name, i| {
                if (name.len > 0 and cx.hasMod(name)) {
                    pick = i;
                    break;
                }
            }
            if (pick == null) {
                for (names, 0..) |name, i| {
                    if (name.len == 0) {
                        pick = i;
                        break;
                    }
                }
            }
            const v = pick orelse return error.Unknown;
            cx.w.put(at, n, v);
            return v;
        }
        const v = cx.get(at, n);
        if (v >= names.len) return error.Unknown;
        if (names[v].len > 0) try cx.addMod(names[v]);
        return v;
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

    /// Whether a modifier is in force (decoding: `on`), before its place in
    /// nvdisasm's order is reached: what an operand's form depends on.
    fn sense(cx: *Cx, name: []const u8, on: bool) bool {
        return if (cx.enc()) cx.hasMod(name) else on;
    }

    // Operands -------------------------------------------------------------

    /// A general register in an 8-bit field, without modifiers.
    fn reg(cx: *Cx, at: u7) Error!u8 {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .gpr) return error.Syntax;
            const r = o.gpr;
            if (r.neg or r.abs or r.reuse) return error.Syntax;
            cx.w.put(at, 8, r.n);
            return r.n;
        }
        const n: u8 = @intCast(cx.get(at, 8));
        try cx.push(.{ .gpr = .{ .n = n } });
        return n;
    }

    fn ureg(cx: *Cx, at: u7) Error!u8 {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .ugpr) return error.Syntax;
            const r = o.ugpr;
            if (r.neg or r.abs or r.reuse) return error.Syntax;
            cx.w.put(at, 8, r.n);
            return r.n;
        }
        const n: u8 = @intCast(cx.get(at, 8));
        try cx.push(.{ .ugpr = .{ .n = n } });
        return n;
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

    /// A branch target, in instruction words of 4 bytes from the next
    /// instruction: the low 8 bits in 16..23, the rest in 34..81 (sm_100's
    /// split).
    fn branch(cx: *Cx) Error!void {
        if (cx.enc()) {
            const to: u64 = switch (try cx.take()) {
                .label => cx.target orelse return error.NoTarget,
                .target => |t| t,
                else => return error.Syntax,
            };
            const d = @as(i64, @intCast(to)) - @as(i64, @intCast(cx.pc + 16));
            if (@mod(d, 4) != 0) return error.OutOfRange;
            const bits: u64 = @bitCast(@divExact(d, 4));
            cx.w.put(16, 8, bits & 0xff);
            cx.w.put(34, 48, bits >> 8);
            return;
        }
        const raw: u64 = cx.get(16, 8) | cx.get(34, 48) << 8;
        // (56 bits, signed)
        const rel: i64 = @as(i64, @bitCast(raw << 8)) >> 8;
        const to = @as(i64, @intCast(cx.pc + 16)) + rel * 4;
        if (to < 0) return error.Unknown;
        try cx.push(.{ .target = @intCast(to) });
    }

    /// A memory address: its register at 24 (with `wide_at`, .64 allowed),
    /// a signed offset, a descriptor's uniform register when `desc_at`.
    fn addr(cx: *Cx, a: AddrForm) Error!Addr {
        if (cx.enc()) {
            const o = try cx.take();
            if (o != .addr) return error.Syntax;
            const x = o.addr;
            if ((x.desc != null) != (a.desc != null)) return error.Syntax;
            if (x.wide and a.wide == null) return error.Syntax;
            cx.w.put(24, 8, x.reg);
            if (a.wide) |b| cx.w.bit(b, x.wide);
            if (a.desc) |d| cx.w.put(d, 8, x.desc.?);
            const lim = @as(i64, 1) << @intCast(a.off_n - 1);
            if (x.offset < -lim or x.offset >= lim) return error.OutOfRange;
            cx.w.put(a.off_at, a.off_n, @as(u64, @bitCast(@as(i64, x.offset))));
            return x;
        }
        var x = Addr{ .reg = @intCast(cx.get(24, 8)) };
        if (a.wide) |b| x.wide = cx.get(b, 1) == 1;
        if (a.desc) |d| x.desc = @intCast(cx.get(d, 8));
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

/// What a printed ALU source may be: how an immediate in its place reads,
/// and whether it takes - and |..|.
const SrcSpec = struct {
    imm: ImmKind = .hex,
    neg: bool = false,
    abs: bool = false,
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

const Alu = struct {
    op: u9,
    /// A uniform-datapath op: its registers are uniform ones.
    uniform: bool = false,
    a: Slot = .none,
    b: Slot = .none,
    c: Slot = .none,
    /// One printed second source in b's place when a register, else in
    /// c's (FADD's).
    bc: ?SrcSpec = null,
    /// fp16 ops: c's sign bits at 83 and 84.
    half: bool = false,
};

/// The operand slots an ALU instruction reads, for `.reuse` (bits 122..).
const SLOT_A: u7 = 122;
const SLOT_B: u7 = 123;
const SLOT_C: u7 = 124;

const Src = union(enum) {
    none,
    /// A register of the op's own file.
    reg: Reg,
    /// A uniform register read by a non-uniform op.
    ureg: Reg,
    imm: u32,
    cbuf: CBuf,
};

fn srcIn(cx: *Cx, o: Operand, s: SrcSpec, uniform: bool) Error!Src {
    switch (o) {
        .gpr, .ugpr => |r| {
            if ((r.neg and !s.neg) or (r.abs and !s.abs)) return error.Syntax;
            if ((o == .gpr) == uniform) {
                if (uniform) return error.Syntax;
                return .{ .ureg = r };
            }
            return .{ .reg = r };
        },
        .cbuf => |cb| {
            if (uniform or cb.reg != RZ or (cb.neg and !s.neg) or (cb.abs and !s.abs)) return error.Syntax;
            if (cb.offset > 0xffff) return error.OutOfRange;
            return .{ .cbuf = cb };
        },
        .num, .imm => {
            if (s.imm == .f16) {
                // (two operands: the high half, then the low)
                const h = try immValue(o, .f16, 16);
                const l = try immValue(try cx.take(), .f16, 16);
                return .{ .imm = @intCast(h << 16 | l) };
            }
            return .{ .imm = @intCast(try immValue(o, s.imm, 32)) };
        },
        else => return error.Syntax,
    }
}

fn putReg(w: *Word, at: u7, r: Reg, abs_bit: u7, neg_bit: u7, slot: u7) void {
    w.put(at, 8, r.n);
    if (r.abs) w.bit(abs_bit, true);
    if (r.neg) w.bit(neg_bit, true);
    if (r.reuse) w.bit(slot, true);
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
    const c_abs: u7 = if (d.half) 83 else 74;
    const c_neg: u7 = if (d.half) 84 else 75;
    if (!cx.enc()) return aluDecode(cx, d, c_abs, c_neg);
    var a: Src = .none;
    var b: Src = .none;
    var c: Src = .none;
    switch (d.a) {
        .none => {},
        .rz => a = .{ .reg = .{ .n = RZ } },
        .src => |s| a = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    if (a != .none and a != .reg) return error.Syntax;
    switch (d.b) {
        .none => {},
        .rz => b = .{ .reg = .{ .n = RZ } },
        .src => |s| b = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    if (d.bc) |s| {
        const x = try srcIn(cx, try cx.take(), s, d.uniform);
        if (x == .reg) b = x else c = x;
    }
    switch (d.c) {
        .none => {},
        .rz => c = .{ .reg = .{ .n = RZ } },
        .src => |s| c = try srcIn(cx, try cx.take(), s, d.uniform),
    }
    const w = &cx.w;
    if (a == .reg) putReg(w, 24, a.reg, 73, 72, SLOT_A);
    const form: u3 = switch (c) {
        .none, .reg => blk: {
            if (c == .reg) putReg(w, 64, c.reg, c_abs, c_neg, SLOT_C);
            break :blk switch (b) {
                .none => 1,
                .reg => |r| inner: {
                    putReg(w, 32, r, 62, 63, SLOT_B);
                    break :inner 1;
                },
                .ureg => |r| inner: {
                    putReg(w, 32, r, 62, 63, SLOT_B);
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
            switch (b) {
                .none => {},
                .reg => |r| putReg(w, 64, r, c_abs, c_neg, SLOT_C),
                else => return error.Unknown,
            }
            switch (c) {
                .ureg => |r| {
                    putReg(w, 32, r, 62, 63, SLOT_B);
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

fn aluDecode(cx: *Cx, d: Alu, c_abs: u7, c_neg: u7) Error!void {
    const form = cx.get(9, 3);
    if (d.a == .src) try pushSrc(cx, .{ .at = 24, .abs = 73, .neg = 72, .slot = SLOT_A }, d.a.src, d.uniform);
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
        return pushWhere(cx, at, s, d.uniform, c_abs, c_neg);
    }
    if (d.b == .src) try pushWhere(cx, b_at, d.b.src, d.uniform, c_abs, c_neg);
    if (d.c == .src) try pushWhere(cx, c_at, d.c.src, d.uniform, c_abs, c_neg);
}

const RegAt = struct { at: u7, abs: u7, neg: u7, slot: u7 };

fn pushSrc(cx: *Cx, f: RegAt, s: SrcSpec, uniform: bool) Error!void {
    const r = Reg{
        .n = @intCast(cx.get(f.at, 8)),
        .abs = s.abs and cx.get(f.abs, 1) == 1,
        .neg = s.neg and cx.get(f.neg, 1) == 1,
        .reuse = cx.get(f.slot, 1) == 1,
    };
    try cx.push(if (uniform) .{ .ugpr = r } else .{ .gpr = r });
}

fn pushWhere(cx: *Cx, at: Where, s: SrcSpec, uniform: bool, c_abs: u7, c_neg: u7) Error!void {
    switch (at) {
        .reg32 => try pushSrc(cx, .{ .at = 32, .abs = 62, .neg = 63, .slot = SLOT_B }, s, uniform),
        .ureg32 => try pushSrc(cx, .{ .at = 32, .abs = 62, .neg = 63, .slot = SLOT_B }, s, true),
        .reg64 => try pushSrc(cx, .{ .at = 64, .abs = c_abs, .neg = c_neg, .slot = SLOT_C }, s, uniform),
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
const SIZES = [_][]const u8{ "U8", "S8", "U16", "S16", "", "64", "128", "" };
/// ISETP's comparisons (76..78) and how the result joins the accumulator
/// (74..75).
const ICMP = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "T" };
const BOOL = [_][]const u8{ "AND", "OR", "XOR", "" };
/// Rounding (78..79 in float ops).
const RND = [_][]const u8{ "", "RM", "RP", "RZ" };

// ── The codecs ──────────────────────────────────────────────────────────────

fn cNop(cx: *Cx) Error!void {
    cx.put(0, 12, 0x918);
}

fn cExit(cx: *Cx) Error!void {
    cx.put(0, 12, 0x94d);
    cx.put(87, 3, PT);
}

fn cBra(cx: *Cx) Error!void {
    cx.put(0, 12, 0x947);
    cx.put(87, 3, PT);
    try cx.branch();
}

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

fn cR2ur(cx: *Cx) Error!void {
    cx.put(0, 12, 0x2ca);
    _ = try cx.ureg(16);
    _ = try cx.reg(24);
    cx.put(81, 3, PT);
}

/// LDC Rd, c[bank][offset] (an index register in 24); LDCU URd, ...
/// (offset in 37..53).
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
        if (cb.neg or cb.abs or (uniform and cb.reg != RZ)) return error.Syntax;
        if (cb.offset >> @intCast(off_n) != 0) return error.OutOfRange;
        cx.w.put(24, 8, cb.reg);
        cx.w.put(off_at, off_n, cb.offset);
        cx.w.put(54, 5, cb.bank);
        return;
    }
    try cx.push(.{ .cbuf = .{
        .bank = @intCast(cx.get(54, 5)),
        .offset = @intCast(cx.get(off_at, off_n)),
        .reg = if (uniform) RZ else @intCast(cx.get(24, 8)),
    } });
}

fn cLdcR(cx: *Cx) Error!void {
    return cLdc(cx, false);
}

fn cLdcU(cx: *Cx) Error!void {
    return cLdc(cx, true);
}

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

fn cUmov(cx: *Cx) Error!void {
    if (!try cx.derived("64", cx.get(9, 3) == 2)) return error.Unknown;
    cx.put(0, 12, 0x482);
    _ = try cx.ureg(16);
    _ = try cx.imm(24, 64, .hex);
    cx.put(91, 1, 1); // (a uniform destination)
}

/// sm_100's two-source add; .64 adds register pairs.
fn cIadd(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x035, .a = .{ .src = .{ .neg = true } }, .b = .{ .src = .{ .imm = .signed, .neg = true } } });
    _ = try cx.flag(73, "64");
    cx.put(81, 3, PT);
    cx.put(87, 4, 0xf); // (!PT)
}

/// IADD3 Rd, Pcarry0, Pcarry1, a, b, c
fn cIadd3(cx: *Cx) Error!void {
    const s = Slot{ .src = .{ .imm = .signed, .neg = true } };
    _ = try cx.reg(16);
    _ = try cx.pred(81, false);
    _ = try cx.pred(84, false);
    try alu(cx, .{ .op = 0x010, .a = s, .b = s, .c = s });
    cx.put(77, 4, 0xf);
    cx.put(87, 4, 0xf);
}

/// IMAD(.WIDE)(.U32) Rd, a, b, c. nvdisasm names IMAD.U32 by a power of
/// two and no addend IMAD.SHL; ptxas's moves IMAD.MOV (a and b RZ).
fn cImad(cx: *Cx) Error!void {
    const wide = cx.sense("WIDE", cx.get(0, 9) == 0x025);
    const unsigned = cx.sense("U32", cx.get(73, 1) == 0);
    const s = Slot{ .src = .{ .imm = if (unsigned) .hex else .signed } };
    _ = try cx.reg(16);
    try alu(cx, .{ .op = if (wide) 0x025 else 0x024, .a = s, .b = s, .c = s });
    cx.put(81, 3, PT);
    cx.put(87, 4, 0xf);
    _ = try cx.derived("WIDE", wide);
    const o = cx.in.ops[0..cx.in.n_ops];
    const shl = !cx.enc() and !wide and unsigned and o.len == 4 and o[2] == .imm and
        o[2].imm.bits != 0 and std.math.isPowerOfTwo(o[2].imm.bits) and o[3] == .gpr and o[3].gpr.n == RZ;
    _ = try cx.derived("SHL", shl);
    _ = try cx.mod(73, 1, &.{ "U32", "" });
}

/// ISETP.cmp(.U32).bool Pd, Pd1, a, b, Paccum
fn cIsetp(cx: *Cx) Error!void {
    const unsigned = cx.sense("U32", cx.get(73, 1) == 0);
    _ = try cx.pred(81, false);
    _ = try cx.pred(84, false);
    try alu(cx, .{ .op = 0x00c, .a = INT, .b = .{ .src = .{ .imm = if (unsigned) .hex else .signed } } });
    _ = try cx.predNot(87, false);
    cx.put(68, 4, PT);
    _ = try cx.mod(76, 3, &ICMP);
    _ = try cx.mod(73, 1, &.{ "U32", "" });
    _ = try cx.mod(74, 2, &BOOL);
}

/// LOP3.LUT Rd, a, b, c, lut, Psrc
fn cLop3(cx: *Cx) Error!void {
    try cx.always("LUT");
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x012, .a = INT, .b = INT, .c = INT });
    _ = try cx.imm(72, 8, .hex);
    _ = try cx.predNot(87, false);
    cx.put(81, 3, PT);
}

/// PLOP3.LUT Pd0, Pd1, P0, P1, P2, lut0, lut1 (lut0 split: 64..66 and
/// 72..76)
fn cPlop3(cx: *Cx) Error!void {
    try cx.always("LUT");
    cx.put(0, 12, 0x81c);
    _ = try cx.pred(81, false);
    _ = try cx.pred(84, false);
    _ = try cx.predNot(87, false);
    _ = try cx.predNot(77, false);
    _ = try cx.predNot(68, false);
    if (cx.enc()) {
        const l0 = try immValue(try cx.take(), .hex, 8);
        cx.w.put(64, 3, l0 & 7);
        cx.w.put(72, 5, l0 >> 3);
    } else try cx.push(.{ .imm = .{ .bits = cx.get(64, 3) | cx.get(72, 5) << 3 } });
    _ = try cx.imm(16, 8, .hex);
}

const F32_NEG: SrcSpec = .{ .imm = .f32, .neg = true };
const F32_ABS: SrcSpec = .{ .imm = .f32, .neg = true, .abs = true };

fn fmods(cx: *Cx) Error!void {
    _ = try cx.mod(78, 2, &RND);
    _ = try cx.flag(80, "FTZ");
    _ = try cx.flag(77, "SAT");
}

fn cFfma(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x023, .a = .{ .src = F32_NEG }, .b = .{ .src = F32_NEG }, .c = .{ .src = F32_NEG } });
    try fmods(cx);
}

fn cFadd(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x021, .a = .{ .src = F32_ABS }, .bc = F32_ABS });
    try fmods(cx);
}

fn cFmul(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x020, .a = .{ .src = F32_NEG }, .b = .{ .src = F32_NEG }, .c = .rz });
    try fmods(cx);
    cx.put(84, 3, 4);
}

/// HFMA2 Rd, a, b, c (or c's immediate as two halves)
fn cHfma2(cx: *Cx) Error!void {
    const h = Slot{ .src = .{ .imm = .f16, .neg = true, .abs = true } };
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x031, .a = h, .b = h, .c = h, .half = true });
    _ = try cx.flag(78, "F32");
    _ = try cx.flag(80, "FTZ");
}

/// Integer types as conversions name them: the size (log2 of its bytes)
/// and signedness.
const ITYPES = [_][]const u8{ "U8", "S8", "U16", "S16", "U32", "S32", "U64", "S64" };

/// I2FP.F32.U32 / .S32 Rd, b (sm_90's integer to float)
fn cI2fp(cx: *Cx) Error!void {
    _ = try cx.reg(16);
    try alu(cx, .{ .op = 0x045, .b = SINT });
    // (NAK's I2F fields: the destination's size as log2 of its bytes, then
    // the source signed and its size)
    _ = try cx.mod(75, 2, &.{ "", "F16", "F32", "F64" });
    try intType(cx, 74, 84);
}

/// An integer type split over a signedness bit and a size field.
fn intType(cx: *Cx, sign_at: u7, size_at: u7) Error!void {
    if (cx.enc()) {
        for (ITYPES, 0..) |name, i| {
            if (cx.hasMod(name)) {
                cx.w.put(sign_at, 1, i & 1);
                cx.w.put(size_at, 2, i >> 1);
                return;
            }
        }
        return error.Unknown;
    }
    try cx.addMod(ITYPES[cx.get(size_at, 2) * 2 + cx.get(sign_at, 1)]);
}

fn cLdg(cx: *Cx) Error!void {
    cx.put(0, 12, 0x981);
    _ = try cx.flag(76, "E");
    _ = try cx.mod(73, 3, &SIZES);
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

// ── The forms ───────────────────────────────────────────────────────────────

const Codec = *const fn (*Cx) Error!void;

const Form = struct {
    name: []const u8,
    /// Bits 0..11, or with `alu` bits 0..8 (the form in 9..11 any).
    opcode: u12,
    alu: bool = false,
    codec: Codec,
};

const FORMS = [_]Form{
    .{ .name = "NOP", .opcode = 0x918, .codec = cNop },
    .{ .name = "EXIT", .opcode = 0x94d, .codec = cExit },
    .{ .name = "BRA", .opcode = 0x947, .codec = cBra },
    .{ .name = "S2R", .opcode = 0x919, .codec = cS2r },
    .{ .name = "S2UR", .opcode = 0x9c3, .codec = cS2ur },
    .{ .name = "R2UR", .opcode = 0x2ca, .codec = cR2ur },
    .{ .name = "LDC", .opcode = 0xb82, .codec = cLdcR },
    .{ .name = "LDCU", .opcode = 0x7ac, .codec = cLdcU },
    .{ .name = "PLOP3", .opcode = 0x81c, .codec = cPlop3 },
    .{ .name = "LDG", .opcode = 0x981, .codec = cLdg },
    .{ .name = "STG", .opcode = 0x986, .codec = cStg },
    .{ .name = "LDL", .opcode = 0x983, .codec = cLdl },
    .{ .name = "STL", .opcode = 0x387, .codec = cStl },
    .{ .name = "MOV", .opcode = 0x002, .alu = true, .codec = cMov },
    .{ .name = "UMOV", .opcode = 0x082, .alu = true, .codec = cUmov },
    .{ .name = "IADD", .opcode = 0x035, .alu = true, .codec = cIadd },
    .{ .name = "IADD3", .opcode = 0x010, .alu = true, .codec = cIadd3 },
    .{ .name = "IMAD", .opcode = 0x024, .alu = true, .codec = cImad },
    .{ .name = "IMAD", .opcode = 0x025, .alu = true, .codec = cImad },
    .{ .name = "ISETP", .opcode = 0x00c, .alu = true, .codec = cIsetp },
    .{ .name = "LOP3", .opcode = 0x012, .alu = true, .codec = cLop3 },
    .{ .name = "FFMA", .opcode = 0x023, .alu = true, .codec = cFfma },
    .{ .name = "FADD", .opcode = 0x021, .alu = true, .codec = cFadd },
    .{ .name = "FMUL", .opcode = 0x020, .alu = true, .codec = cFmul },
    .{ .name = "HFMA2", .opcode = 0x031, .alu = true, .codec = cHfma2 },
    .{ .name = "I2FP", .opcode = 0x045, .alu = true, .codec = cI2fp },
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

// ── Encoding and decoding ───────────────────────────────────────────────────

/// `in`'s 128 bits, as the instruction at byte `pc` of its kernel; a branch
/// goes to byte `target` (or to its own .target operand).
pub fn encode(in: *const Instr, pc: u64, target: ?u64) Error!Word {
    const form = formOf(in.op) orelse return error.Unknown;
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
    var cx = Cx{ .dir = .dec, .w = w, .in = .{ .op = form.name }, .pc = pc };
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
        try fmtPred(&o, "P", in.guard);
        try o.str(" ");
    }
    try o.str(in.op);
    for (in.mods[0..in.n_mods]) |m| {
        try o.str(".");
        try o.str(m);
    }
    for (in.operands(), 0..) |x, i| {
        try o.str(if (i == 0) " " else ", ");
        try fmtOperand(&o, x);
    }
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
                try o.print("R{d}", .{c.reg});
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
            if (a.reg != RZ) {
                try o.print("R{d}", .{a.reg});
                if (a.wide) try o.str(".64");
                if (a.offset != 0) {
                    try o.str("+");
                    try fmtSigned(o, a.offset);
                }
            } else try fmtSigned(o, a.offset);
            try o.str("]");
        },
        .sreg => |n| try o.str(sregName(n) orelse "SR_?"),
        .label => |l| try o.print("`({s})", .{l}),
        .target => |t| try o.print("`(0x{x})", .{t}),
    }
}

/// A float as nvdisasm prints it: C's %.20g of its value (exact: the
/// float's decimal expansion, rounded half to even at 20 digits, trailing
/// zeros dropped), or +INF, -INF, +QNAN, -QNAN.
fn fmtFloat(o: *Out, x: f32) FormatError!void {
    const bits: u32 = @bitCast(x);
    const neg = bits >> 31 == 1;
    const e_bits: u32 = (bits >> 23) & 0xff;
    const frac: u32 = bits & 0x7fffff;
    if (e_bits == 0xff) return o.str(if (frac != 0) (if (neg) "-QNAN" else "+QNAN") else if (neg) "-INF" else "+INF");
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
    if (nd > 20) {
        const up = blk: {
            if (digits[20] != '5') break :blk digits[20] > '5';
            for (digits[21..nd]) |dg| {
                if (dg != '0') break :blk true;
            }
            break :blk (digits[19] - '0') % 2 == 1;
        };
        nd = 20;
        if (up) {
            var i: usize = 20;
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
    while (nd > 1 and digits[nd - 1] == '0') nd -= 1;
    if (x10 < -4 or x10 >= 20) {
        try o.str(digits[0..1]);
        if (nd > 1) {
            try o.str(".");
            try o.str(digits[1..nd]);
        }
        const ax: u32 = @intCast(if (x10 < 0) -x10 else x10);
        try o.print("e{c}{d:0>2}", .{ @as(u8, if (x10 < 0) '-' else '+'), ax });
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

/// The highest general register an instruction touches (its 64- and
/// 128-bit operands' pairs and quads included), or null.
pub fn highestGpr(in: *const Instr) ?u8 {
    const width: u8 = blk: {
        if (in.has("128")) break :blk 4;
        if (in.has("64") or in.has("WIDE")) break :blk 2;
        break :blk 1;
    };
    var top: ?u8 = null;
    for (in.operands(), 0..) |o, i| {
        const r: u8 = switch (o) {
            .gpr => |g| g.n,
            .addr => |a| if (a.reg != RZ) a.reg + @as(u8, if (a.wide) 1 else 0) else continue,
            .cbuf => |c| if (c.reg != RZ) c.reg else continue,
            else => continue,
        };
        if (r == RZ) continue;
        // (a load's destination, a store's data, a wide result: the whole
        // register group; IMAD.WIDE's c is a pair too)
        const group: u8 = if (o == .gpr and (i == 0 or isData(in, i) or (in.has("WIDE") and i == 3))) width else 1;
        const t = r + group - 1;
        top = if (top) |x| @max(x, t) else t;
    }
    return top;
}

fn isData(in: *const Instr, i: usize) bool {
    return (eql(in.op, "STG") or eql(in.op, "STL")) and i == 1;
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
    const fa = try parse("FADD R0, -|R2|.reuse, -c[0x0][R3+0x10]");
    try testing.expectEqual(Reg{ .n = 2, .neg = true, .abs = true, .reuse = true }, fa.ops[1].gpr);
    try testing.expectEqual(CBuf{ .bank = 0, .offset = 0x10, .reg = 3, .neg = true }, fa.ops[2].cbuf);
    try testing.expectEqualStrings("-INF", (try parseOperand("-INF")).num);
}

test "floats as nvdisasm prints them (%.20g)" {
    const cases = [_]struct { f32, []const u8 }{
        .{ 1.0, "1" },
        .{ 0.5, "0.5" },
        .{ -2.0, "-2" },
        .{ 0.0, "0" },
        .{ 1.4426950408889634, "1.4426950216293334961" },
        .{ 1.1754943508222875e-38, "1.175494350822287508e-38" },
        .{ 3.4028234663852886e38, "3.4028234663852885981e+38" },
        .{ 1e20, "1.0000000200408773427e+20" },
        .{ 1e19, "9999999980506447872" },
        .{ 0.0001, "9.9999997473787516356e-05" },
        .{ 1.875, "1.875" },
        .{ std.math.inf(f32), "+INF" },
        .{ -std.math.inf(f32), "-INF" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var o = Out{ .buf = &buf };
        try fmtFloat(&o, c[0]);
        try testing.expectEqualStrings(c[1], o.buf[0..o.len]);
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
        _ = lines.next(); // (the kernel's name)
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
    try testing.expect(n > 250);
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

test "every alu form's opcode stays clear of the exact ones" {
    for (FORMS) |f| {
        if (!f.alu) continue;
        for (1..8) |form| {
            const op: u12 = @intCast(f.opcode | form << 9);
            for (FORMS) |g| {
                if (!g.alu) try testing.expect(g.opcode != op);
            }
        }
    }
}
