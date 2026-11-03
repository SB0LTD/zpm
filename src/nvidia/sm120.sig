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
//! The forms and their bit positions are Mesa's NAK compiler's
//! (src/nouveau/compiler/nak/sm70_encode.rs, MIT license, read as
//! documentation only: none of it is copied), and for what NAK does not emit
//! (the two-source IADD and IADD.64, MOV.64 and UMOV.64, STL's 0x387, the
//! constant bits ptxas sets), ptxas's own output. The tests assemble every
//! instruction in sm120_vectors.txt (ptxas output, see
//! tools/gen_sm120_vectors.py) and compare all 128 bits.
//!
//! Allocation-free: instructions are plain values parsed in place from the
//! caller's text.

const std = @import("std");

pub const Error = error{
    /// Text that is not an instruction, or an operand this module cannot
    /// read.
    Syntax,
    /// A mnemonic, or a form of it, this module does not encode.
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

pub const CBuf = struct { bank: u5, offset: u32 };

/// A memory address: [Rn(.64)+offset], or desc[URd][Rn.64+offset] (a
/// global address through the 64-bit descriptor URd:URd+1).
pub const Addr = struct {
    desc: ?u8 = null,
    reg: u8 = RZ,
    wide: bool = false,
    offset: i32 = 0,
};

pub const Operand = union(enum) {
    gpr: Reg,
    ugpr: Reg,
    pred: Pred,
    upred: Pred,
    /// A number as written: what it means (an integer, a float, two
    /// halves) depends on the instruction.
    num: []const u8,
    cbuf: CBuf,
    addr: Addr,
    /// A special register's number (SR_TID.X: 0x21).
    sreg: u8,
    label: []const u8,
};

pub const MAX_OPERANDS = 8;
pub const MAX_MODS = 6;

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

/// "Rn", "Rn.64", "Rn+0x8", "Rn.64-0x10", "0x40": an address's register
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

pub fn parseOperand(text: []const u8) Error!Operand {
    var t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return error.Syntax;
    if (std.mem.startsWith(u8, t, "`(") and std.mem.endsWith(u8, t, ")")) return .{ .label = t[2 .. t.len - 1] };
    if (std.mem.startsWith(u8, t, "c[")) {
        // c[bank][offset]
        const mid = std.mem.indexOf(u8, t, "][") orelse return error.Syntax;
        if (!std.mem.endsWith(u8, t, "]")) return error.Syntax;
        const bank = try number(t[2..mid]);
        const off = try number(t[mid + 2 .. t.len - 1]);
        if (bank < 0 or bank > 31 or off < 0 or off > 0xffff) return error.OutOfRange;
        return .{ .cbuf = .{ .bank = @intCast(bank), .offset = @intCast(off) } };
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
    if (t[0] == '-' and t.len > 1 and !std.ascii.isDigit(t[1])) {
        neg = true;
        t = t[1..];
    } else if (t[0] == '!') {
        not = true;
        t = t[1..];
    }
    if (t.len > 2 and t[0] == '|' and t[t.len - 1] == '|') {
        abs = true;
        t = t[1 .. t.len - 1];
    }
    var reuse = false;
    if (std.mem.endsWith(u8, t, ".reuse")) {
        reuse = true;
        t = t[0 .. t.len - 6];
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
    if (not or abs or reuse) return error.Syntax;
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

// ── Encoding helpers ────────────────────────────────────────────────────────

const Src = union(enum) {
    none,
    gpr: Reg,
    ugpr: Reg,
    imm: u32,
    cbuf: CBuf,
};

/// The operand slots an ALU instruction reads, for `.reuse` (bits 122..).
const SLOT_A: u7 = 122;
const SLOT_B: u7 = 123;
const SLOT_C: u7 = 124;

fn reg8(r: Reg) u8 {
    return r.n;
}

fn gprAt(w: *Word, at: u7, r: Reg, abs_bit: u7, neg_bit: u7, slot: u7) void {
    w.put(at, 8, reg8(r));
    if (r.abs) w.bit(abs_bit, true);
    if (r.neg) w.bit(neg_bit, true);
    if (r.reuse) w.bit(slot, true);
}

fn cbufAt(w: *Word, cb: CBuf) Error!void {
    w.put(38, 16, cb.offset);
    w.put(54, 5, cb.bank);
    w.bit(91, false);
}

const Half = enum { no, yes };

/// NAK's encode_alu_base: source a in 24..31; b and c by the form in bits
/// 9..11 (1: b and c registers; 2: c an immediate, b in c's slot; 3: c a
/// constant; 4: b an immediate; 5: b a constant; 6: b uniform; 7: c
/// uniform).
fn alu(w: *Word, op: u9, dst: ?u8, a: Src, b: Src, c: Src, half: Half) Error!void {
    if (dst) |d| w.put(16, 8, d);
    switch (a) {
        .none => {},
        .gpr => |r| gprAt(w, 24, r, 73, 72, SLOT_A),
        else => return error.Unknown,
    }
    const c_abs: u7 = if (half == .yes) 83 else 74;
    const c_neg: u7 = if (half == .yes) 84 else 75;
    const form: u3 = switch (c) {
        .none, .gpr => blk: {
            if (c == .gpr) gprAt(w, 64, c.gpr, c_abs, c_neg, SLOT_C);
            break :blk switch (b) {
                .none => 1,
                .gpr => |r| inner: {
                    gprAt(w, 32, r, 62, 63, SLOT_B);
                    break :inner 1;
                },
                .ugpr => |r| inner: {
                    gprAt(w, 32, r, 62, 63, SLOT_B);
                    w.bit(91, true);
                    break :inner 6;
                },
                .imm => |v| inner: {
                    w.put(32, 32, v);
                    break :inner 4;
                },
                .cbuf => |cb| inner: {
                    try cbufAt(w, cb);
                    break :inner 5;
                },
            };
        },
        .ugpr => |r| blk: {
            gprAt(w, 32, r, 62, 63, SLOT_B);
            w.bit(91, true);
            if (b == .gpr) gprAt(w, 64, b.gpr, c_abs, c_neg, SLOT_C) else if (b != .none) return error.Unknown;
            break :blk 7;
        },
        .imm => |v| blk: {
            w.put(32, 32, v);
            if (b == .gpr) gprAt(w, 64, b.gpr, c_abs, c_neg, SLOT_C) else if (b != .none) return error.Unknown;
            break :blk 2;
        },
        .cbuf => |cb| blk: {
            try cbufAt(w, cb);
            if (b == .gpr) gprAt(w, 64, b.gpr, c_abs, c_neg, SLOT_C) else if (b != .none) return error.Unknown;
            break :blk 3;
        },
    };
    w.put(0, 9, op);
    w.put(9, 3, form);
}

const Kind = enum { int, f32, f16x2 };

fn src(o: Operand, kind: Kind) Error!Src {
    return switch (o) {
        .gpr => |r| .{ .gpr = r },
        .ugpr => |r| .{ .ugpr = r },
        .cbuf => |cb| .{ .cbuf = cb },
        .num => |t| .{ .imm = try immediate(t, kind) },
        else => error.Syntax,
    };
}

/// A 32-bit immediate: an integer (signed or not), or a float's bits.
fn immediate(t: []const u8, kind: Kind) Error!u32 {
    switch (kind) {
        .int => {
            const v = try number(t);
            if (v < std.math.minInt(i32) or v > std.math.maxInt(u32)) return error.OutOfRange;
            return @truncate(@as(u64, @bitCast(v)));
        },
        .f32 => {
            if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u32, t[2..], 16) catch error.Syntax;
            const f = floatOf(t) orelse return error.Syntax;
            return @bitCast(@as(f32, @floatCast(f)));
        },
        .f16x2 => return error.Syntax, // (two operands: see halves)
    }
}

fn floatOf(t: []const u8) ?f64 {
    if (std.mem.eql(u8, t, "+INF")) return std.math.inf(f64);
    if (std.mem.eql(u8, t, "-INF")) return -std.math.inf(f64);
    if (std.mem.eql(u8, t, "+QNAN")) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, t) catch null;
}

/// HFMA2's immediate: two halves, printed high first ("1.875, 0" is
/// 0x3f800000).
fn halves(hi_t: []const u8, lo_t: []const u8) Error!u32 {
    const h = floatOf(hi_t) orelse return error.Syntax;
    const l = floatOf(lo_t) orelse return error.Syntax;
    const hb: u16 = @bitCast(@as(f16, @floatCast(h)));
    const lb: u16 = @bitCast(@as(f16, @floatCast(l)));
    return @as(u32, hb) << 16 | lb;
}

fn want(in: *const Instr, n: usize) Error!void {
    if (in.n_ops != n) return error.Syntax;
}

fn gprOf(o: Operand) Error!Reg {
    return switch (o) {
        .gpr => |r| r,
        else => error.Syntax,
    };
}

fn ugprOf(o: Operand) Error!Reg {
    return switch (o) {
        .ugpr => |r| r,
        else => error.Syntax,
    };
}

fn predOf(o: Operand) Error!Pred {
    return switch (o) {
        .pred => |p| p,
        else => error.Syntax,
    };
}

fn numOf(o: Operand) Error![]const u8 {
    return switch (o) {
        .num => |t| t,
        else => error.Syntax,
    };
}

fn pred3(w: *Word, at: u7, p: Pred) void {
    w.put(at, 3, p.n);
    w.bit(at + 3, p.not);
}

/// Loads' and stores' size (73..75).
fn memType(in: *const Instr) u3 {
    if (in.has("U8")) return 0;
    if (in.has("S8")) return 1;
    if (in.has("U16")) return 2;
    if (in.has("S16")) return 3;
    if (in.has("64")) return 5;
    if (in.has("128")) return 6;
    return 4;
}

fn offset24(w: *Word, off: i32) Error!void {
    if (off < -(1 << 23) or off >= (1 << 23)) return error.OutOfRange;
    w.put(40, 24, @as(u32, @bitCast(off)));
}

/// ISETP's comparisons (76..78) and how the result joins the accumulator
/// (74..75).
fn cmpOf(in: *const Instr) Error!u3 {
    const names = [_][]const u8{ "F", "LT", "EQ", "LE", "GT", "NE", "GE", "T" };
    for (names, 0..) |n, i| {
        if (in.has(n)) return @intCast(i);
    }
    return error.Unknown;
}

fn boolOpOf(in: *const Instr) Error!u2 {
    if (in.has("AND")) return 0;
    if (in.has("OR")) return 1;
    if (in.has("XOR")) return 2;
    return error.Unknown;
}

// ── Encoding ────────────────────────────────────────────────────────────────

/// `in`'s 128 bits, as the instruction at byte `pc` of its kernel; a branch
/// goes to byte `target`.
pub fn encode(in: *const Instr, pc: u64, target: ?u64) Error!Word {
    var w = Word{};
    w.put(12, 3, in.guard.n);
    w.bit(15, in.guard.not);
    const o = in.operands();
    const op = in.op;
    if (eql(op, "NOP")) {
        try want(in, 0);
        w.put(0, 12, 0x918);
    } else if (eql(op, "EXIT")) {
        try want(in, 0);
        w.put(0, 12, 0x94d);
        w.put(87, 3, PT);
    } else if (eql(op, "BRA")) {
        try want(in, 1);
        if (o[0] != .label) return error.Syntax;
        const to = target orelse return error.NoTarget;
        w.put(0, 12, 0x947);
        w.put(87, 3, PT);
        // (in instruction words of 4 bytes from the next instruction)
        const rel: i64 = @divExact(@as(i64, @intCast(to)) - @as(i64, @intCast(pc + 16)), 4);
        const bits: u64 = @bitCast(rel);
        w.put(16, 8, bits & 0xff);
        w.put(34, 48, bits >> 8);
    } else if (eql(op, "S2R") or eql(op, "S2UR")) {
        try want(in, 2);
        const d = if (eql(op, "S2R")) try gprOf(o[0]) else try ugprOf(o[0]);
        if (o[1] != .sreg) return error.Syntax;
        w.put(0, 12, if (eql(op, "S2R")) 0x919 else 0x9c3);
        w.put(16, 8, d.n);
        w.put(72, 8, o[1].sreg);
    } else if (eql(op, "R2UR")) {
        try want(in, 2);
        w.put(0, 12, 0x2ca);
        w.put(16, 8, (try ugprOf(o[0])).n);
        w.put(24, 8, (try gprOf(o[1])).n);
        w.put(81, 3, PT);
    } else if (eql(op, "LDC") or eql(op, "LDCU")) {
        try want(in, 2);
        if (o[1] != .cbuf) return error.Unknown;
        const cb = o[1].cbuf;
        if (eql(op, "LDC")) {
            w.put(0, 12, 0xb82);
            w.put(16, 8, (try gprOf(o[0])).n);
            w.put(24, 8, RZ);
            w.put(38, 16, cb.offset);
        } else {
            w.put(0, 12, 0x7ac);
            w.put(16, 8, (try ugprOf(o[0])).n);
            w.put(24, 8, RZ);
            w.put(37, 17, cb.offset);
            w.bit(91, true);
        }
        w.put(54, 5, cb.bank);
        w.put(73, 3, memType(in));
    } else if (eql(op, "MOV")) {
        try want(in, 2);
        if (in.has("64")) {
            // MOV.64 Rd, imm64: the immediate in bits 24..87
            w.put(0, 12, 0x402);
            w.put(16, 8, (try gprOf(o[0])).n);
            const v: u64 = @bitCast(try number(try numOf(o[1])));
            w.put(24, 64, v);
        } else {
            try alu(&w, 0x002, (try gprOf(o[0])).n, .none, try src(o[1], .int), .none, .no);
            w.put(72, 4, 0xf);
        }
    } else if (eql(op, "UMOV")) {
        try want(in, 2);
        if (!in.has("64")) return error.Unknown;
        w.put(0, 12, 0x482);
        w.put(16, 8, (try ugprOf(o[0])).n);
        const v: u64 = @bitCast(try number(try numOf(o[1])));
        w.put(24, 64, v);
        w.bit(91, true); // (a uniform destination)
    } else if (eql(op, "IADD")) {
        // (sm_100's two-source add; .64 adds register pairs)
        try want(in, 3);
        try alu(&w, 0x035, (try gprOf(o[0])).n, try src(o[1], .int), try src(o[2], .int), .none, .no);
        w.bit(73, in.has("64"));
        w.put(81, 3, PT);
        pred3(&w, 87, .{ .n = PT, .not = true });
    } else if (eql(op, "IADD3")) {
        // IADD3 Rd, Pcarry0, Pcarry1, a, b, c
        try want(in, 6);
        try alu(&w, 0x010, (try gprOf(o[0])).n, try src(o[3], .int), try src(o[4], .int), try src(o[5], .int), .no);
        pred3(&w, 77, .{ .n = PT, .not = true });
        w.put(81, 3, (try predOf(o[1])).n);
        w.put(84, 3, (try predOf(o[2])).n);
        pred3(&w, 87, .{ .n = PT, .not = true });
    } else if (eql(op, "IMAD")) {
        // IMAD(.WIDE)(.U32)(.SHL) Rd, a, b, c (.SHL only names a shift)
        try want(in, 4);
        const opc: u9 = if (in.has("WIDE")) 0x025 else 0x024;
        try alu(&w, opc, (try gprOf(o[0])).n, try src(o[1], .int), try src(o[2], .int), try src(o[3], .int), .no);
        w.bit(73, !in.has("U32"));
        w.put(81, 3, PT);
        pred3(&w, 87, .{ .n = PT, .not = true });
    } else if (eql(op, "ISETP")) {
        // ISETP.cmp(.U32).bool Pd, Pd1, a, b, Paccum
        try want(in, 5);
        try alu(&w, 0x00c, null, try src(o[2], .int), try src(o[3], .int), .none, .no);
        pred3(&w, 68, .{});
        w.bit(73, !in.has("U32"));
        w.put(74, 2, try boolOpOf(in));
        w.put(76, 3, try cmpOf(in));
        w.put(81, 3, (try predOf(o[0])).n);
        w.put(84, 3, (try predOf(o[1])).n);
        pred3(&w, 87, try predOf(o[4]));
    } else if (eql(op, "LOP3")) {
        // LOP3.LUT Rd, a, b, c, lut, Psrc
        try want(in, 6);
        if (!in.has("LUT")) return error.Unknown;
        try alu(&w, 0x012, (try gprOf(o[0])).n, try src(o[1], .int), try src(o[2], .int), try src(o[3], .int), .no);
        const lut = try number(try numOf(o[4]));
        if (lut < 0 or lut > 0xff) return error.OutOfRange;
        w.put(72, 8, @intCast(lut));
        w.put(81, 3, PT);
        pred3(&w, 87, try predOf(o[5]));
    } else if (eql(op, "PLOP3")) {
        // PLOP3.LUT Pd0, Pd1, P0, P1, P2, lut0, lut1
        try want(in, 7);
        w.put(0, 12, 0x81c);
        const l0 = try number(try numOf(o[5]));
        const l1 = try number(try numOf(o[6]));
        if (l0 < 0 or l0 > 0xff or l1 < 0 or l1 > 0xff) return error.OutOfRange;
        pred3(&w, 87, try predOf(o[2]));
        pred3(&w, 77, try predOf(o[3]));
        pred3(&w, 68, try predOf(o[4]));
        w.put(16, 8, @intCast(l1));
        w.put(64, 3, @intCast(l0 & 7));
        w.put(72, 5, @intCast(l0 >> 3));
        w.put(81, 3, (try predOf(o[0])).n);
        w.put(84, 3, (try predOf(o[1])).n);
    } else if (eql(op, "FFMA")) {
        try want(in, 4);
        try alu(&w, 0x023, (try gprOf(o[0])).n, try src(o[1], .f32), try src(o[2], .f32), try src(o[3], .f32), .no);
        try fmods(&w, in);
    } else if (eql(op, "FADD")) {
        // (b is not read: the second source goes in c's place)
        try want(in, 3);
        try alu(&w, 0x021, (try gprOf(o[0])).n, try src(o[1], .f32), .none, try src(o[2], .f32), .no);
        try fmods(&w, in);
    } else if (eql(op, "FMUL")) {
        try want(in, 3);
        try alu(&w, 0x020, (try gprOf(o[0])).n, try src(o[1], .f32), try src(o[2], .f32), .none, .no);
        try fmods(&w, in);
    } else if (eql(op, "HFMA2")) {
        // HFMA2 Rd, a, b, c (or c's immediate as two halves)
        if (in.n_ops != 4 and in.n_ops != 5) return error.Syntax;
        const c: Src = if (in.n_ops == 5) .{ .imm = try halves(try numOf(o[3]), try numOf(o[4])) } else try src(o[3], .f16x2);
        try alu(&w, 0x031, (try gprOf(o[0])).n, try src(o[1], .f16x2), try src(o[2], .f16x2), c, .yes);
        w.bit(78, in.has("F32"));
        w.bit(80, in.has("FTZ"));
    } else if (eql(op, "I2FP")) {
        // I2FP.F32.U32 / .S32 Rd, a (sm_90's integer to float)
        try want(in, 2);
        if (!in.has("F32")) return error.Unknown;
        try alu(&w, 0x045, (try gprOf(o[0])).n, .none, try src(o[1], .int), .none, .no);
        // (NAK's I2F fields: the source signed, then the destination's and
        // the source's sizes as log2 of their bytes)
        w.bit(74, in.has("S32"));
        w.put(75, 2, 2);
        w.put(84, 2, 2);
    } else if (eql(op, "LDG") or eql(op, "STG")) {
        const load = eql(op, "LDG");
        try want(in, 2);
        const a = (if (load) o[1] else o[0]);
        if (a != .addr or a.addr.desc == null) return error.Unknown;
        const ad = a.addr;
        w.put(0, 12, if (load) 0x981 else 0x986);
        w.put(24, 8, ad.reg);
        w.bit(90, ad.wide);
        if (load) {
            w.put(16, 8, (try gprOf(o[0])).n);
            w.put(32, 8, ad.desc.?);
            w.put(81, 3, PT);
        } else {
            w.put(32, 8, (try gprOf(o[1])).n);
            w.put(64, 8, ad.desc.?);
        }
        try offset24(&w, ad.offset);
        w.bit(72, true); // (the descriptor is 64 bits)
        w.put(73, 3, memType(in));
        w.bit(76, in.has("E"));
        w.put(84, 3, 1); // (eviction: normal)
        w.bit(91, true);
    } else if (eql(op, "LDL") or eql(op, "STL")) {
        const load = eql(op, "LDL");
        try want(in, 2);
        const a = (if (load) o[1] else o[0]);
        if (a != .addr or a.addr.desc != null or a.addr.wide) return error.Unknown;
        w.put(0, 12, if (load) 0x983 else 0x387);
        w.put(24, 8, a.addr.reg);
        if (load) w.put(16, 8, (try gprOf(o[0])).n) else w.put(32, 8, (try gprOf(o[1])).n);
        try offset24(&w, a.addr.offset);
        w.put(73, 3, memType(in));
        w.put(84, 3, 1);
    } else return error.Unknown;
    in.control.apply(&w);
    return w;
}

fn fmods(w: *Word, in: *const Instr) Error!void {
    w.bit(77, in.has("SAT"));
    w.put(78, 2, if (in.has("RM")) 1 else if (in.has("RP")) 2 else if (in.has("RZ")) 3 else 0);
    w.bit(80, in.has("FTZ"));
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

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
}

test "ptxas's vectors: every instruction's 128 bits (sm120_vectors.txt)" {
    const data = @embedFile("sm120_vectors.txt");
    // Pass 1 per kernel: its labels' addresses. Pass 2: encode and compare.
    var kernels = std.mem.splitSequence(u8, data, "# kernel ");
    _ = kernels.next();
    var n: usize = 0;
    var failures: usize = 0;
    while (kernels.next()) |block| {
        var labels: [32]struct { name: []const u8, at: u64 } = undefined;
        var n_labels: usize = 0;
        var pc: u64 = 0;
        var lines = std.mem.splitScalar(u8, block, '\n');
        _ = lines.next(); // (the kernel's name)
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[line.len - 1] == ':') {
                labels[n_labels] = .{ .name = line[0 .. line.len - 1], .at = pc };
                n_labels += 1;
            } else pc += 16;
        }
        pc = 0;
        lines = std.mem.splitScalar(u8, block, '\n');
        _ = lines.next();
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#' or line[line.len - 1] == ':') continue;
            // "<hi>_<lo> <control> <text>"
            const hi_w = try std.fmt.parseInt(u64, line[0..16], 16);
            const lo_w = try std.fmt.parseInt(u64, line[17..33], 16);
            const text = line[34..];
            n += 1;
            defer pc += 16;
            const in = parse(text) catch |e| {
                std.debug.print("parse  \"{s}\": {s}\n", .{ text, @errorName(e) });
                failures += 1;
                continue;
            };
            var target: ?u64 = null;
            if (in.label()) |l| {
                for (labels[0..n_labels]) |x| {
                    if (std.mem.eql(u8, x.name, l)) target = x.at;
                }
            }
            const w = encode(&in, pc, target) catch |e| {
                std.debug.print("encode \"{s}\": {s}\n", .{ text, @errorName(e) });
                failures += 1;
                continue;
            };
            if (w.lo() != lo_w or w.hi() != hi_w) {
                std.debug.print("encode \"{s}\": got {x:0>16}_{x:0>16} want {x:0>16}_{x:0>16} (diff {x:0>16}_{x:0>16})\n", .{ text, w.hi(), w.lo(), hi_w, lo_w, w.hi() ^ hi_w, w.lo() ^ lo_w });
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
