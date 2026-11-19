//! The translator's decoder (jit.sig): one guest instruction from its
//! bytes into what the code generators need, decoded exactly as cpu.sig's
//! interpreter decodes it (the same prefixes, the same default segments,
//! the same 16- and 32-bit addressing). For each instruction it says how
//! long it is, whether a native template may run it (`kind`), whether the
//! block must end after it (`term`), and which arithmetic flags it reads
//! and writes (as the interpreter computes them: block-local liveness).
//! Anything the templates do not have is `.helper`: the interpreter runs
//! exactly that instruction. Written from Intel's opcode maps.

const regs = @import("regs.sig");

pub const CF = regs.CF;
pub const PF = regs.PF;
pub const AF = regs.AF;
pub const ZF = regs.ZF;
pub const SF = regs.SF;
pub const OF = regs.OF;
/// The six flags arithmetic writes.
pub const ARITH: u16 = @intCast(CF | PF | AF | ZF | SF | OF);

pub const NOSEG: u3 = 7;
/// No register (in an address).
pub const NONE: u4 = 8;

/// A memory operand: seg:(base + index << scale + disp), 16-bit addresses
/// wrapped at 64 KiB.
pub const Ea = struct {
    seg: u3 = regs.DS,
    base: u4 = NONE,
    index: u4 = NONE,
    scale: u2 = 0,
    disp: u32 = 0,
    a16: bool = false,
};

pub const Loc = enum(u3) { none, reg, mem, imm, acc };

pub const Kind = enum(u8) {
    /// The interpreter runs it.
    helper,
    /// sub: 0 ADD 1 OR 2 ADC 3 SBB 4 AND 5 SUB 6 XOR 7 CMP; dst op= src.
    alu,
    test_,
    mov,
    lea,
    /// sub 0 INC, 1 DEC.
    incdec,
    not_,
    neg,
    /// PUSH src (a register, an immediate, memory).
    push,
    /// POP into a register (dreg).
    pop,
    /// sub: the condition; target.
    jcc,
    jmp,
    call,
    /// imm: bytes to release after the return address.
    ret,
    /// An indirect JMP/CALL through src (a register or memory).
    jmp_ind,
    call_ind,
    /// sub: 0 ROL 1 ROR 4 SHL 5 SHR 7 SAR, imm the count (not 0, < 32).
    shift,
    movzx,
    movsx,
    /// IMUL dreg, src (2-operand, 0F AF) or dreg, src, imm (69, 6B).
    imul,
    /// CBW/CWDE (98).
    cwde,
    /// CWD/CDQ (99).
    cdq,
    /// XCHG dst(reg or mem), sreg.
    xchg,
    /// SETcc dst (sub: the condition).
    setcc,
    nop,
    /// sub: 0 CLC 1 STC 2 CMC 3 CLD 4 STD.
    flagop,
    /// An x87 instruction (D8-DF): the FPU's own code with the address
    /// computed here (`mod` false: a register form).
    x87,
    /// LEAVE.
    leave,
    /// MOV r/m16, Sreg (8C).
    movsreg,
    /// BSWAP.
    bswap,
    /// PUSHF(D).
    pushf,
    /// SHLD (sub 0) / SHRD (sub 1) dst, sreg, imm (the count, not 0).
    shxd,
    /// F6/F7 /4-/7 (sub): MUL IMUL DIV IDIV on src.
    muldiv,
};

pub const Ins = struct {
    len: u8 = 0,
    kind: Kind = .helper,
    /// The operand size (1, 2, 4); for MOVZX/MOVSX also `ssz`, the
    /// source's.
    sz: u8 = 4,
    ssz: u8 = 0,
    sub: u8 = 0,
    dst: Loc = .none,
    src: Loc = .none,
    dreg: u3 = 0,
    sreg: u3 = 0,
    mem: bool = false,
    ea: Ea = .{},
    imm: u32 = 0,
    /// A direct branch's target (EIP).
    target: u32 = 0,
    o32: bool = false,
    a32: bool = false,
    rep: u2 = 0,
    /// The opcode (0F xx as 0x0Fxx), its ModRM byte.
    op: u16 = 0,
    modrm: u8 = 0,
    /// The block ends after it.
    term: bool = false,
    /// The arithmetic flags it reads and writes (regs' bits).
    fr: u16 = 0,
    fw: u16 = 0,
};

/// The flags condition `cc` (Jcc's low nibble) reads.
pub fn ccReads(cc: u4) u16 {
    return switch (@as(u3, @truncate(cc >> 1))) {
        0 => OF,
        1 => CF,
        2 => ZF,
        3 => CF | ZF,
        4 => SF,
        5 => PF,
        6 => SF | OF,
        7 => ZF | SF | OF,
    };
}

const Rd = struct {
    p: [*]const u8,
    n: u32,
    i: u32 = 0,
    ok: bool = true,

    fn b(r: *Rd) u8 {
        if (r.i >= r.n) {
            r.ok = false;
            return 0;
        }
        const x = r.p[r.i];
        r.i += 1;
        return x;
    }
    fn w(r: *Rd) u16 {
        const lo = r.b();
        return lo | (@as(u16, r.b()) << 8);
    }
    fn d(r: *Rd) u32 {
        const lo = r.w();
        return lo | (@as(u32, r.w()) << 16);
    }
    fn v(r: *Rd, o32: bool) u32 {
        return if (o32) r.d() else r.w();
    }
};

fn sx8(b: u8) u32 {
    const s: i32 = @as(i8, @bitCast(b));
    return @bitCast(s);
}
fn sx16(x: u16) u32 {
    const s: i32 = @as(i16, @bitCast(x));
    return @bitCast(s);
}

fn modrm(r: *Rd, ins: *Ins, seg: u3, a32: bool) void {
    const m = r.b();
    ins.modrm = m;
    ins.sreg = @truncate(m >> 3);
    const md: u2 = @truncate(m >> 6);
    const rm: u3 = @truncate(m);
    if (md == 3) {
        ins.mem = false;
        ins.dreg = rm;
        return;
    }
    ins.mem = true;
    var e = Ea{ .a16 = !a32 };
    if (!a32) {
        switch (rm) {
            0 => {
                e.base = regs.EBX;
                e.index = regs.ESI;
            },
            1 => {
                e.base = regs.EBX;
                e.index = regs.EDI;
            },
            2 => {
                e.base = regs.EBP;
                e.index = regs.ESI;
                e.seg = regs.SS;
            },
            3 => {
                e.base = regs.EBP;
                e.index = regs.EDI;
                e.seg = regs.SS;
            },
            4 => e.base = regs.ESI,
            5 => e.base = regs.EDI,
            6 => if (md != 0) {
                e.base = regs.EBP;
                e.seg = regs.SS;
            },
            7 => e.base = regs.EBX,
        }
        switch (md) {
            0 => if (rm == 6) {
                e.disp = r.w();
            },
            1 => e.disp = sx8(r.b()) & 0xFFFF,
            else => e.disp = r.w(),
        }
    } else {
        if (rm == 4) {
            const sib = r.b();
            const base: u3 = @truncate(sib);
            const idx: u3 = @truncate(sib >> 3);
            e.scale = @truncate(sib >> 6);
            if (base == 5 and md == 0) {
                e.disp = r.d();
            } else {
                e.base = base;
                if (base == regs.ESP or base == regs.EBP) e.seg = regs.SS;
            }
            if (idx != 4) e.index = idx;
        } else if (rm == 5 and md == 0) {
            e.disp = r.d();
        } else {
            e.base = rm;
            if (rm == regs.EBP) e.seg = regs.SS;
        }
        switch (md) {
            0 => {},
            1 => e.disp +%= sx8(r.b()),
            2 => e.disp +%= r.d(),
            else => unreachable,
        }
    }
    if (seg != NOSEG) e.seg = seg;
    ins.ea = e;
}

/// Decodes the instruction at `p` (`n` bytes there may be read: the rest
/// of the page, of CS's limit, of the 64 KiB IP wrap) whose EIP is `eip`,
/// for code of `d32` (a 32-bit code segment in protected mode). Null when
/// it does not fit in the `n` bytes (or has more than 14 prefixes: the
/// interpreter's #GP).
pub fn decode(p: [*]const u8, n: u32, d32: bool, eip: u32, wrap: u32) ?Ins {
    var r = Rd{ .p = p, .n = n };
    var ins = Ins{};
    var o32 = d32;
    var a32 = d32;
    var seg: u3 = NOSEG;
    var rep: u2 = 0;
    var npfx: u32 = 0;
    var op: u16 = r.b();
    while (true) : (op = r.b()) {
        switch (op) {
            0x26, 0x2E, 0x36, 0x3E => seg = @truncate((op >> 3) & 3),
            0x64 => seg = regs.FS,
            0x65 => seg = regs.GS,
            0x66 => o32 = !d32,
            0x67 => a32 = !d32,
            0xF0 => {},
            0xF2 => rep = 2,
            0xF3 => rep = 1,
            else => break,
        }
        npfx += 1;
        if (npfx > 14 or !r.ok) return null;
    }
    if (!r.ok) return null;
    ins.o32 = o32;
    ins.a32 = a32;
    ins.rep = rep;
    const vsz: u8 = if (o32) 4 else 2;
    const ALL = ARITH;
    // (the defaults: a helper that may read and write every flag)
    ins.fr = ALL;
    ins.fw = ALL;
    switch (op) {
        0x00...0x3F => |b| {
            const lo = b & 7;
            if (b == 0x0F) {
                op = 0x0F00 | @as(u16, r.b());
                decode0F(&r, &ins, op, seg, a32, vsz);
            } else if (lo < 6 and (b & 0xC0) == 0) {
                const sub: u8 = @truncate(b >> 3);
                ins.kind = .alu;
                ins.sub = sub;
                ins.fr = if (sub == 2 or sub == 3) CF else 0;
                ins.fw = ALL;
                switch (lo) {
                    0, 1 => {
                        ins.sz = if (lo == 0) 1 else vsz;
                        modrm(&r, &ins, seg, a32);
                        ins.dst = if (ins.mem) .mem else .reg;
                        ins.src = .reg;
                    },
                    2, 3 => {
                        ins.sz = if (lo == 2) 1 else vsz;
                        modrm(&r, &ins, seg, a32);
                        // (dst the ModRM reg, src the r/m)
                        ins.src = if (ins.mem) .mem else .reg;
                        const t = ins.dreg;
                        ins.dreg = ins.sreg;
                        ins.sreg = t;
                        ins.dst = .reg;
                    },
                    4, 5 => {
                        ins.sz = if (lo == 4) 1 else vsz;
                        ins.imm = if (lo == 4) r.b() else r.v(o32);
                        ins.dst = .reg;
                        ins.dreg = 0;
                        ins.src = .imm;
                    },
                    else => unreachable,
                }
                if (ins.src == .reg and ins.dst == .mem) {} // (dreg unused)
            } else {
                // push/pop sreg, DAA DAS AAA AAS, and the prefixes' gaps
                switch (b) {
                    0x06, 0x0E, 0x16, 0x1E => {
                        ins.fr = 0;
                        ins.fw = 0;
                    },
                    0x07, 0x17, 0x1F => {
                        ins.fr = 0;
                        ins.fw = 0;
                        ins.term = true;
                    },
                    else => {},
                }
            }
        },
        0x40...0x4F => |b| {
            ins.kind = .incdec;
            ins.sub = @intFromBool(b >= 0x48);
            ins.sz = vsz;
            ins.dst = .reg;
            ins.dreg = @truncate(b);
            ins.fr = 0;
            ins.fw = ALL & ~@as(u16, CF);
        },
        0x50...0x57 => |b| {
            ins.kind = .push;
            ins.sz = vsz;
            ins.src = .reg;
            ins.sreg = @truncate(b);
            ins.fr = 0;
            ins.fw = 0;
        },
        0x58...0x5F => |b| {
            ins.kind = .pop;
            ins.sz = vsz;
            ins.dst = .reg;
            ins.dreg = @truncate(b);
            ins.fr = 0;
            ins.fw = 0;
            // (POP ESP: the interpreter's order; leave it to it)
            if (ins.dreg == regs.ESP) ins.kind = .helper;
        },
        0x60, 0x61 => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0x62, 0x63 => {
            modrm(&r, &ins, seg, a32);
            ins.fr = ALL;
            ins.fw = ALL;
        },
        0x68 => {
            ins.kind = .push;
            ins.sz = vsz;
            ins.src = .imm;
            ins.imm = r.v(o32);
            ins.fr = 0;
            ins.fw = 0;
        },
        0x6A => {
            ins.kind = .push;
            ins.sz = vsz;
            ins.src = .imm;
            ins.imm = sx8(r.b());
            ins.fr = 0;
            ins.fw = 0;
        },
        0x69, 0x6B => {
            ins.kind = .imul;
            ins.sz = vsz;
            modrm(&r, &ins, seg, a32);
            ins.src = if (ins.mem) .mem else .reg;
            const t = ins.dreg;
            ins.dreg = ins.sreg;
            ins.sreg = t;
            ins.dst = .reg;
            ins.imm = if (op == 0x6B) sx8(r.b()) else r.v(o32);
            if (!o32 and op == 0x69) ins.imm = ins.imm & 0xFFFF;
            ins.sub = 3; // (three operands)
            ins.fr = 0;
            ins.fw = ALL;
        },
        0x6C...0x6F => ins.term = true,
        0x70...0x7F => |b| {
            ins.kind = .jcc;
            ins.sub = @truncate(b & 0xF);
            const d = sx8(r.b());
            ins.target = d;
            ins.fr = ccReads(@truncate(b));
            ins.fw = 0;
            ins.term = true;
        },
        0x80, 0x81, 0x82, 0x83 => {
            ins.kind = .alu;
            ins.sz = if (op == 0x80 or op == 0x82) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            ins.sub = ins.sreg;
            ins.dst = if (ins.mem) .mem else .reg;
            ins.src = .imm;
            ins.imm = if (op == 0x81) r.v(o32) else if (op == 0x83) sx8(r.b()) else r.b();
            if (ins.sz == 2) ins.imm &= 0xFFFF;
            ins.fr = if (ins.sub == 2 or ins.sub == 3) CF else 0;
            ins.fw = ALL;
        },
        0x84, 0x85 => {
            ins.kind = .test_;
            ins.sz = if (op == 0x84) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            ins.dst = if (ins.mem) .mem else .reg;
            ins.src = .reg;
            ins.fr = 0;
            ins.fw = ALL;
        },
        0x86, 0x87 => {
            ins.kind = .xchg;
            ins.sz = if (op == 0x86) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            ins.dst = if (ins.mem) .mem else .reg;
            ins.src = .reg;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x88...0x8B => {
            ins.kind = .mov;
            ins.sz = if (op & 1 == 0) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            if (op < 0x8A) {
                ins.dst = if (ins.mem) .mem else .reg;
                ins.src = .reg;
            } else {
                ins.src = if (ins.mem) .mem else .reg;
                const t = ins.dreg;
                ins.dreg = ins.sreg;
                ins.sreg = t;
                ins.dst = .reg;
            }
            ins.fr = 0;
            ins.fw = 0;
        },
        0x8C => {
            modrm(&r, &ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
            if (ins.sreg <= 5) {
                ins.kind = .movsreg;
                ins.dst = if (ins.mem) .mem else .reg;
                ins.sz = if (ins.mem) 2 else vsz;
            } else ins.term = true;
        },
        0x8D => {
            modrm(&r, &ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
            if (ins.mem) {
                ins.kind = .lea;
                ins.sz = vsz;
                ins.dreg = ins.sreg;
                ins.dst = .reg;
            } else ins.term = true;
        },
        0x8E => {
            modrm(&r, &ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0x8F => {
            modrm(&r, &ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
        },
        0x90 => {
            ins.kind = .nop;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x91...0x97 => |b| {
            ins.kind = .xchg;
            ins.sz = vsz;
            ins.dst = .reg;
            ins.dreg = @truncate(b);
            ins.src = .reg;
            ins.sreg = regs.EAX;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x98 => {
            ins.kind = .cwde;
            ins.sz = vsz;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x99 => {
            ins.kind = .cdq;
            ins.sz = vsz;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x9A, 0xEA => {
            ins.imm = r.v(o32);
            _ = r.w();
            ins.term = true;
        },
        0x9B => {
            ins.kind = .nop;
            ins.fr = 0;
            ins.fw = 0;
        },
        0x9C => {
            ins.kind = .pushf;
            ins.sz = vsz;
            ins.fw = 0;
        },
        0x9D => {
            ins.fr = 0;
            ins.term = true;
        },
        0x9E => ins.fr = 0,
        0x9F => ins.fw = 0,
        0xA0...0xA3 => {
            ins.kind = .mov;
            ins.sz = if (op & 1 == 0) 1 else vsz;
            ins.mem = true;
            ins.ea = .{ .seg = if (seg != NOSEG) seg else regs.DS, .disp = if (a32) r.d() else r.w(), .a16 = !a32 };
            if (op < 0xA2) {
                ins.dst = .reg;
                ins.dreg = 0;
                ins.src = .mem;
            } else {
                ins.dst = .mem;
                ins.src = .reg;
                ins.sreg = 0;
            }
            ins.fr = 0;
            ins.fw = 0;
        },
        0xA4, 0xA5, 0xAA, 0xAB, 0xAC, 0xAD => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0xA6, 0xA7, 0xAE, 0xAF => {
            ins.fr = if (rep != 0) ALL else 0;
        },
        0xA8, 0xA9 => {
            ins.kind = .test_;
            ins.sz = if (op == 0xA8) 1 else vsz;
            ins.imm = if (op == 0xA8) r.b() else r.v(o32);
            ins.dst = .reg;
            ins.dreg = 0;
            ins.src = .imm;
            ins.fr = 0;
            ins.fw = ALL;
        },
        0xB0...0xBF => |b| {
            ins.kind = .mov;
            ins.sz = if (b < 0xB8) 1 else vsz;
            ins.dst = .reg;
            ins.dreg = @truncate(b);
            ins.src = .imm;
            ins.imm = if (b < 0xB8) r.b() else r.v(o32);
            ins.fr = 0;
            ins.fw = 0;
        },
        0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => {
            ins.sz = if (op & 1 == 0) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            const sub = ins.sreg;
            var count: u32 = 0;
            const by_cl = op >= 0xD2;
            if (op <= 0xC1) count = r.b() else if (op <= 0xD1) count = 1;
            count &= 31;
            if (!by_cl and count == 0) {
                // (no change at all, flags included: but the operand is
                // read, and may fault)
                ins.fr = 0;
                ins.fw = 0;
            } else if (!by_cl and (sub == 0 or sub == 1 or sub == 4 or sub == 5 or sub == 6 or sub == 7)) {
                ins.kind = .shift;
                ins.sub = if (sub == 6) 4 else sub;
                ins.imm = count;
                ins.dst = if (ins.mem) .mem else .reg;
                ins.fr = 0;
                ins.fw = if (sub <= 1) CF | OF else ALL;
            }
        },
        0xC2 => {
            ins.kind = .ret;
            ins.imm = r.w();
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xC3 => {
            ins.kind = .ret;
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xC4, 0xC5 => {
            modrm(&r, &ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xC6, 0xC7 => {
            ins.sz = if (op == 0xC6) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            ins.imm = if (op == 0xC6) r.b() else r.v(o32);
            ins.kind = .mov;
            ins.dst = if (ins.mem) .mem else .reg;
            ins.src = .imm;
            ins.fr = 0;
            ins.fw = 0;
        },
        0xC8 => {
            _ = r.w();
            _ = r.b();
            ins.fr = 0;
            ins.fw = 0;
        },
        0xC9 => {
            ins.kind = .leave;
            ins.sz = vsz;
            ins.fr = 0;
            ins.fw = 0;
        },
        0xCA => {
            _ = r.w();
            ins.term = true;
        },
        0xCB, 0xCC, 0xCE, 0xCF, 0xF1, 0xF4 => ins.term = true,
        0xCD => {
            _ = r.b();
            ins.term = true;
        },
        0xD4, 0xD5 => _ = r.b(),
        0xD6 => {
            ins.fw = 0;
        },
        0xD7 => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0xD8...0xDF => {
            const m = r.p[if (r.i < r.n) r.i else 0];
            if (r.i >= r.n) return null;
            if (m < 0xC0) {
                modrm(&r, &ins, seg, a32);
            } else {
                _ = r.b();
                ins.modrm = m;
            }
            ins.kind = .x87;
            ins.fr = 0;
            ins.fw = 0;
        },
        0xE0...0xE3 => {
            _ = r.b();
            ins.fr = if (op <= 0xE1) ZF else 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xE4...0xE7 => {
            _ = r.b();
            ins.term = true;
        },
        0xE8 => {
            ins.kind = .call;
            ins.target = if (o32) r.d() else r.w();
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xE9 => {
            ins.kind = .jmp;
            ins.target = if (o32) r.d() else r.w();
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xEB => {
            ins.kind = .jmp;
            ins.target = sx8(r.b());
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xEC...0xEF => ins.term = true,
        0xF5 => {
            ins.kind = .flagop;
            ins.sub = 2;
            ins.fr = CF;
            ins.fw = CF;
        },
        0xF6, 0xF7 => {
            ins.sz = if (op == 0xF6) 1 else vsz;
            modrm(&r, &ins, seg, a32);
            ins.dst = if (ins.mem) .mem else .reg;
            switch (ins.sreg) {
                0, 1 => {
                    ins.kind = .test_;
                    ins.imm = if (op == 0xF6) r.b() else r.v(o32);
                    ins.src = .imm;
                    ins.fr = 0;
                },
                2 => {
                    ins.kind = .not_;
                    ins.fr = 0;
                    ins.fw = 0;
                },
                3 => {
                    ins.kind = .neg;
                    ins.fr = 0;
                },
                4, 5 => ins.fr = 0,
                // (DIV leaves the flags as they were)
                6, 7 => {
                    ins.fr = 0;
                    ins.fw = 0;
                },
            }
            if (ins.sreg >= 4) {
                ins.kind = .muldiv;
                ins.sub = ins.sreg;
                ins.src = if (ins.mem) .mem else .reg;
                ins.sreg = ins.dreg;
            }
        },
        0xF8, 0xF9 => {
            ins.kind = .flagop;
            ins.sub = @intCast(op - 0xF8);
            ins.fr = 0;
            ins.fw = CF;
        },
        0xFA => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0xFB => {
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xFC, 0xFD => {
            ins.kind = .flagop;
            ins.sub = @intCast(op - 0xFC + 3);
            ins.fr = 0;
            ins.fw = 0;
        },
        0xFE => {
            const m = if (r.i < r.n) r.p[r.i] else return null;
            if (m == 0x38 or m == 0x39) {
                // The HLE trap: FE 38 vv / FE 39 vv.
                _ = r.b();
                _ = r.b();
                ins.term = true;
            } else {
                ins.sz = 1;
                modrm(&r, &ins, seg, a32);
                if (ins.sreg <= 1) {
                    ins.kind = .incdec;
                    ins.sub = ins.sreg;
                    ins.dst = if (ins.mem) .mem else .reg;
                    ins.fr = 0;
                    ins.fw = ALL & ~@as(u16, CF);
                } else ins.term = true;
            }
        },
        0xFF => {
            ins.sz = vsz;
            modrm(&r, &ins, seg, a32);
            switch (ins.sreg) {
                0, 1 => {
                    ins.kind = .incdec;
                    ins.sub = ins.sreg;
                    ins.dst = if (ins.mem) .mem else .reg;
                    ins.fr = 0;
                    ins.fw = ALL & ~@as(u16, CF);
                },
                2 => {
                    ins.kind = .call_ind;
                    ins.src = if (ins.mem) .mem else .reg;
                    ins.sreg = ins.dreg;
                    ins.fr = 0;
                    ins.fw = 0;
                    ins.term = true;
                },
                4 => {
                    ins.kind = .jmp_ind;
                    ins.src = if (ins.mem) .mem else .reg;
                    ins.sreg = ins.dreg;
                    ins.fr = 0;
                    ins.fw = 0;
                    ins.term = true;
                },
                6 => {
                    ins.kind = .push;
                    ins.src = if (ins.mem) .mem else .reg;
                    ins.sreg = ins.dreg;
                    ins.fr = 0;
                    ins.fw = 0;
                },
                else => ins.term = true,
            }
        },
        else => ins.term = true,
    }
    if (!r.ok) return null;
    ins.op = op;
    ins.len = @intCast(r.i);
    // (relative targets from the next instruction; 16 bits unless o32)
    switch (ins.kind) {
        .jcc, .jmp, .call => {
            const mask: u32 = if (o32) wrap else 0xFFFF;
            ins.target = (eip +% ins.len +% ins.target) & mask;
        },
        else => {},
    }
    return ins;
}

fn decode0F(r: *Rd, ins: *Ins, op: u16, seg: u3, a32: bool, vsz: u8) void {
    const o32 = vsz == 4;
    const ALL = ARITH;
    switch (op & 0xFF) {
        0x00, 0x01, 0x02, 0x03 => {
            modrm(r, ins, seg, a32);
            ins.term = true;
        },
        0x06, 0x08, 0x09 => ins.term = true,
        0x20...0x23 => {
            _ = r.b();
            ins.term = true;
        },
        0x24, 0x26 => {
            _ = r.b();
            ins.fr = 0;
            ins.fw = 0;
        },
        0x80...0x8F => |b| {
            ins.kind = .jcc;
            ins.sub = @truncate(b & 0xF);
            ins.target = if (o32) r.d() else sx16(r.w());
            ins.fr = ccReads(@truncate(b));
            ins.fw = 0;
            ins.term = true;
        },
        0x90...0x9F => |b| {
            ins.sz = 1;
            modrm(r, ins, seg, a32);
            ins.kind = .setcc;
            ins.sub = @truncate(b & 0xF);
            ins.dst = if (ins.mem) .mem else .reg;
            ins.fr = ccReads(@truncate(b));
            ins.fw = 0;
        },
        0xA0, 0xA8 => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0xA1, 0xA9 => {
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xA2 => {
            ins.fr = 0;
            ins.fw = 0;
        },
        0xA3, 0xAB, 0xB3, 0xBB => {
            modrm(r, ins, seg, a32);
            ins.fr = ALL & ~@as(u16, CF);
            ins.fw = CF;
            // (the bit's other flags unchanged: they pass through)
            ins.fr = 0;
        },
        0xBA => {
            modrm(r, ins, seg, a32);
            _ = r.b();
            if (ins.sreg < 4) {
                ins.term = true;
            } else {
                ins.fr = 0;
                ins.fw = CF;
            }
        },
        0xA4, 0xAC => {
            ins.sz = vsz;
            modrm(r, ins, seg, a32);
            const n = r.b() & 31;
            if (n != 0) {
                ins.kind = .shxd;
                ins.sub = @intFromBool(op & 0xFF == 0xAC);
                ins.imm = n;
                ins.dst = if (ins.mem) .mem else .reg;
                ins.src = .reg;
                ins.fr = 0;
                ins.fw = ALL;
            } else {
                ins.fr = 0;
                ins.fw = 0;
            }
        },
        0xA5, 0xAD => modrm(r, ins, seg, a32),
        0xAF => {
            ins.kind = .imul;
            ins.sz = vsz;
            modrm(r, ins, seg, a32);
            ins.src = if (ins.mem) .mem else .reg;
            const t = ins.dreg;
            ins.dreg = ins.sreg;
            ins.sreg = t;
            ins.dst = .reg;
            ins.sub = 2;
            ins.fr = 0;
            ins.fw = ALL;
        },
        0xB0, 0xB1, 0xC0, 0xC1 => {
            modrm(r, ins, seg, a32);
            ins.fr = 0;
        },
        0xB2, 0xB4, 0xB5 => {
            modrm(r, ins, seg, a32);
            ins.fr = 0;
            ins.fw = 0;
            ins.term = true;
        },
        0xB6, 0xB7, 0xBE, 0xBF => |b| {
            ins.kind = if (b < 0xBE) .movzx else .movsx;
            ins.sz = vsz;
            ins.ssz = if (b & 1 == 0) 1 else 2;
            modrm(r, ins, seg, a32);
            ins.src = if (ins.mem) .mem else .reg;
            const t = ins.dreg;
            ins.dreg = ins.sreg;
            ins.sreg = t;
            ins.dst = .reg;
            ins.fr = 0;
            ins.fw = 0;
        },
        0xBC, 0xBD => modrm(r, ins, seg, a32),
        0xC8...0xCF => |b| {
            ins.kind = .bswap;
            ins.dreg = @truncate(b);
            ins.fr = 0;
            ins.fw = 0;
        },
        else => ins.term = true,
    }
}
