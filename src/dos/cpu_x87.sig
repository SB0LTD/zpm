//! The x87 FPU as a 486DX has it built in: the escape opcodes D8-DF.
//! Written from Intel's 80387/80486 Programmer's Reference (the opcode
//! map, the status/control/tag words, the real-mode FSTENV and FSAVE
//! layouts); no emulator's code.
//!
//! Numbers: the eight registers hold f64. An 80-bit load (FLD m80,
//! FRSTOR) converts exactly when the value fits in a double (53-bit
//! significand, double's exponent range) and rounds to nearest otherwise.
//! So that programs which only move 80-bit or 64-bit-integer data through
//! the FPU (FLD/FSTP m80, FILD/FISTP m64 copy loops, FSAVE/FRSTOR) get
//! their bits back unchanged, each register also keeps the exact 80-bit
//! image it was loaded with until an operation changes it.
//!
//! Rounding control is honoured where results become integers or narrow:
//! FIST/FISTP, FBSTP, FRNDINT, FST/FSTP m32. Arithmetic itself rounds to
//! nearest (the host's mode); precision control 24-bit rounds results to
//! single, 53 and 64 leave doubles. Exceptions set their status bits (IE
//! with SF on stack faults, ZE, PE on inexact integer stores) and the
//! masked response; an unmasked one sets ES and B but raises no #MF/IRQ13.

const std = @import("std");
const math = std.math;
const Regs = @import("regs.sig").Regs;

// Status word.
pub const IE: u16 = 1 << 0;
pub const DE: u16 = 1 << 1;
pub const ZE: u16 = 1 << 2;
pub const OE: u16 = 1 << 3;
pub const UE: u16 = 1 << 4;
pub const PE: u16 = 1 << 5;
pub const SF: u16 = 1 << 6;
pub const ES: u16 = 1 << 7;
pub const C0: u16 = 1 << 8;
pub const C1: u16 = 1 << 9;
pub const C2: u16 = 1 << 10;
pub const C3: u16 = 1 << 14;
pub const BUSY: u16 = 1 << 15;
const CC: u16 = C0 | C1 | C2 | C3;
const TOP_MASK: u16 = 0x3800;

/// The "real indefinite" a masked invalid operation produces.
const INDEF: f64 = @bitCast(@as(u64, 0xFFF8_0000_0000_0000));
const INDEF80: u80 = 0xFFFF_C000_0000_0000_0000;

pub const Fpu = struct {
    /// Physical registers R0-R7; ST(i) is R[(top + i) mod 8].
    st: [8]f64 = [_]f64{0} ** 8,
    /// The exact 80-bit image of R[i], valid while bit i of `exact` is set.
    raw: [8]u80 = [_]u80{0} ** 8,
    exact: u8 = 0,
    /// Bit i: R[i] is empty (tag 11).
    empty: u8 = 0xFF,
    top: u3 = 0,
    cw: u16 = 0x037F,
    /// The status word without TOP (kept in `top`).
    sw: u16 = 0,
    /// The last non-control instruction: its linear address, opcode (11
    /// bits) and operand's linear address.
    fip: u32 = 0,
    fop: u16 = 0,
    fdp: u32 = 0,

    pub fn init(f: *Fpu) void {
        f.* = .{};
    }

    pub fn status(f: *const Fpu) u16 {
        return (f.sw & ~TOP_MASK) | (@as(u16, f.top) << 11);
    }

    inline fn bit(p: u3) u8 {
        return @as(u8, 1) << p;
    }

    fn exc(f: *Fpu, e: u16) void {
        f.sw |= e;
        if (e & ~f.cw & 0x3F != 0) f.sw |= ES | BUSY;
    }

    fn rc(f: *const Fpu) u2 {
        return @truncate(f.cw >> 10);
    }

    fn isEmpty(f: *const Fpu, i: u3) bool {
        return f.empty & bit(f.top +% i) != 0;
    }

    /// ST(i); an empty register is a stack underflow (indefinite).
    fn get(f: *Fpu, i: u3) f64 {
        const p = f.top +% i;
        if (f.empty & bit(p) != 0) {
            f.exc(IE | SF);
            f.sw &= ~C1;
            return INDEF;
        }
        return f.st[p];
    }

    fn put(f: *Fpu, i: u3, v: f64) void {
        const p = f.top +% i;
        f.st[p] = v;
        f.empty &= ~bit(p);
        f.exact &= ~bit(p);
    }

    /// Pushes; false (indefinite pushed) on a stack overflow.
    fn push(f: *Fpu, v: f64) bool {
        f.top -%= 1;
        const p = f.top;
        f.exact &= ~bit(p);
        if (f.empty & bit(p) == 0) {
            f.exc(IE | SF);
            f.sw |= C1;
            f.st[p] = INDEF;
            return false;
        }
        f.st[p] = v;
        f.empty &= ~bit(p);
        return true;
    }

    fn pushRaw(f: *Fpu, raw: u80) void {
        if (f.push(fromExt(raw))) {
            f.raw[f.top] = raw;
            f.exact |= bit(f.top);
        }
    }

    fn pop(f: *Fpu) void {
        f.empty |= bit(f.top);
        f.exact &= ~bit(f.top);
        f.top +%= 1;
    }

    /// ST(i)'s 80-bit image (exact if it has one).
    fn ext(f: *const Fpu, i: u3) u80 {
        const p = f.top +% i;
        if (f.exact & bit(p) != 0) return f.raw[p];
        return toExt(f.st[p]);
    }

    /// Copies ST(src) into ST(dst), its exact image too.
    fn copy(f: *Fpu, dst: u3, src: u3) void {
        const s = f.top +% src;
        const v = f.get(src);
        const was = f.exact & bit(s) != 0;
        const raw = f.raw[s];
        f.put(dst, v);
        if (was) {
            const d = f.top +% dst;
            f.raw[d] = raw;
            f.exact |= bit(d);
        }
    }

    /// An arithmetic result through precision control.
    fn prec(f: *const Fpu, v: f64) f64 {
        if (f.cw & 0x300 == 0) return @floatCast(@as(f32, @floatCast(v)));
        return v;
    }

    /// op: 0 add, 1 mul, 4 a-b, 5 b-a, 6 a/b, 7 b/a.
    fn arith(f: *Fpu, op: u3, a: f64, b: f64) f64 {
        var x = a;
        var y = b;
        if (op == 5 or op == 7) {
            x = b;
            y = a;
        }
        const r = switch (op) {
            0 => x + y,
            1 => x * y,
            4, 5 => x - y,
            else => blk: {
                if (y == 0 and x != 0 and !math.isNan(x) and !math.isInf(x)) f.exc(ZE);
                break :blk x / y;
            },
        };
        if (math.isNan(r) and !math.isNan(a) and !math.isNan(b)) f.exc(IE);
        return f.prec(r);
    }

    fn compare(f: *Fpu, a: f64, b: f64, quiet: bool) void {
        f.sw &= ~CC;
        if (math.isNan(a) or math.isNan(b)) {
            f.sw |= C0 | C2 | C3;
            if (!quiet) f.exc(IE);
            return;
        }
        if (a < b) {
            f.sw |= C0;
        } else if (a == b) {
            f.sw |= C3;
        }
    }

    /// The D8/DC/DA/DE memory forms and D8's register forms: ST(0) op v.
    fn st0Op(f: *Fpu, reg: u3, v: f64) void {
        const a = f.get(0);
        switch (reg) {
            2 => f.compare(a, v, false),
            3 => {
                f.compare(a, v, false);
                f.pop();
            },
            else => f.put(0, f.arith(reg, a, v)),
        }
    }

    fn toInt(f: *Fpu, comptime I: type, v: f64) I {
        const x = roundRc(v, f.rc());
        const lim: f64 = comptime @floatFromInt(@as(i128, math.maxInt(I)) + 1);
        if (!(x >= -lim and x < lim)) {
            f.exc(IE);
            return math.minInt(I);
        }
        if (x != v) f.exc(PE);
        return @intFromFloat(x);
    }

    /// FIST m64 with an exact image that is an integer: no rounding through f64.
    fn toI64(f: *Fpu, i: u3) i64 {
        const p = f.top +% i;
        if (f.exact & bit(p) != 0) {
            if (extInt(f.raw[p])) |n| return n;
        }
        return f.toInt(i64, f.get(i));
    }

    fn toF32(f: *const Fpu, v: f64) f32 {
        var r: f32 = @floatCast(v);
        const back: f64 = r;
        switch (f.rc()) {
            0 => {},
            1 => if (back > v) {
                r = math.nextAfter(f32, r, -math.inf(f32));
            },
            2 => if (back < v) {
                r = math.nextAfter(f32, r, math.inf(f32));
            },
            3 => if (@abs(back) > @abs(v)) {
                r = math.nextAfter(f32, r, 0);
            },
        }
        return r;
    }

    fn tagWord(f: *const Fpu) u16 {
        var tw: u16 = 0;
        var p: u4 = 0;
        while (p < 8) : (p += 1) {
            const q: u3 = @intCast(p);
            const t: u16 = if (f.empty & bit(q) != 0) 3 else blk: {
                const v = f.st[q];
                if (v == 0) break :blk 1;
                if (math.isNan(v) or math.isInf(v)) break :blk 2;
                break :blk 0;
            };
            tw |= t << (@as(u4, q) * 2);
        }
        return tw;
    }

    fn storeEnv(f: *Fpu, bus: anytype, a: u32, o32: bool) u32 {
        const sw = f.status();
        const tw = f.tagWord();
        if (o32) {
            bus.wr32(a, 0xFFFF_0000 | @as(u32, f.cw));
            bus.wr32(a +% 4, 0xFFFF_0000 | @as(u32, sw));
            bus.wr32(a +% 8, 0xFFFF_0000 | @as(u32, tw));
            bus.wr32(a +% 12, f.fip & 0xFFFF);
            bus.wr32(a +% 16, ((f.fip >> 16) << 12) | (f.fop & 0x7FF));
            bus.wr32(a +% 20, f.fdp & 0xFFFF);
            bus.wr32(a +% 24, (f.fdp >> 16) << 12);
            return 28;
        }
        bus.wr16(a, f.cw);
        bus.wr16(a +% 2, sw);
        bus.wr16(a +% 4, tw);
        bus.wr16(a +% 6, @truncate(f.fip));
        bus.wr16(a +% 8, @truncate((((f.fip >> 16) & 0xF) << 12) | (f.fop & 0x7FF)));
        bus.wr16(a +% 10, @truncate(f.fdp));
        bus.wr16(a +% 12, @truncate(((f.fdp >> 16) & 0xF) << 12));
        return 14;
    }

    fn loadEnv(f: *Fpu, bus: anytype, a: u32, o32: bool) u32 {
        var cw: u16 = undefined;
        var sw: u16 = undefined;
        var tw: u16 = undefined;
        if (o32) {
            cw = @truncate(bus.rd32(a));
            sw = @truncate(bus.rd32(a +% 4));
            tw = @truncate(bus.rd32(a +% 8));
            const ip_lo = bus.rd32(a +% 12) & 0xFFFF;
            const ip_hi = bus.rd32(a +% 16);
            f.fip = ip_lo | ((ip_hi >> 12) << 16);
            f.fop = @truncate(ip_hi & 0x7FF);
            f.fdp = (bus.rd32(a +% 20) & 0xFFFF) | ((bus.rd32(a +% 24) >> 12) << 16);
        } else {
            cw = bus.rd16(a);
            sw = bus.rd16(a +% 2);
            tw = bus.rd16(a +% 4);
            const ip_hi = bus.rd16(a +% 8);
            f.fip = @as(u32, bus.rd16(a +% 6)) | (@as(u32, ip_hi >> 12) << 16);
            f.fop = ip_hi & 0x7FF;
            f.fdp = @as(u32, bus.rd16(a +% 10)) | (@as(u32, bus.rd16(a +% 12) >> 12) << 16);
        }
        f.cw = cw;
        f.sw = sw & ~TOP_MASK;
        f.top = @truncate(sw >> 11);
        var p: u4 = 0;
        f.empty = 0;
        while (p < 8) : (p += 1) {
            const q: u3 = @intCast(p);
            if ((tw >> (@as(u4, q) * 2)) & 3 == 3) f.empty |= bit(q);
        }
        return if (o32) 28 else 14;
    }

    /// One escape instruction: `op` D8-DF, its ModRM byte, the operand's
    /// linear address (memory forms), the operand size (FSTENV/FSAVE
    /// layouts), the instruction's linear address. False: no such
    /// instruction on a 486 (the caller raises #UD).
    pub fn esc(f: *Fpu, bus: anytype, r: *Regs, op: u8, modrm: u8, lin: u32, o32: bool, ip_lin: u32) bool {
        const reg: u3 = @truncate(modrm >> 3);
        const rm: u3 = @truncate(modrm);
        const mem = modrm < 0xC0;
        const control = switch (op) {
            0xD9 => mem and reg >= 4,
            0xDB => !mem and reg == 4,
            0xDD => mem and (reg == 4 or reg >= 6),
            0xDF => !mem and reg == 4,
            else => false,
        };
        if (!control) {
            f.fip = ip_lin;
            f.fop = (@as(u16, op & 7) << 8) | modrm;
            if (mem) f.fdp = lin;
        }
        if (mem) return f.escMem(bus, r, op, reg, lin, o32);
        return f.escReg(r, op, reg, rm);
    }

    fn escMem(f: *Fpu, bus: anytype, r: *Regs, op: u8, reg: u3, a: u32, o32: bool) bool {
        _ = r;
        switch (op) {
            0xD8 => f.st0Op(reg, @as(f32, @bitCast(bus.rd32(a)))),
            0xDC => f.st0Op(reg, @bitCast(rd64(bus, a))),
            0xDA => f.st0Op(reg, @floatFromInt(@as(i32, @bitCast(bus.rd32(a))))),
            0xDE => f.st0Op(reg, @floatFromInt(@as(i16, @bitCast(bus.rd16(a))))),
            0xD9 => switch (reg) {
                0 => _ = f.push(@as(f32, @bitCast(bus.rd32(a)))),
                2, 3 => {
                    bus.wr32(a, @as(u32, @bitCast(f.toF32(f.get(0)))));
                    if (reg == 3) f.pop();
                },
                4 => _ = f.loadEnv(bus, a, o32),
                5 => f.cw = bus.rd16(a),
                6 => {
                    _ = f.storeEnv(bus, a, o32);
                    f.cw |= 0x3F;
                },
                7 => bus.wr16(a, f.cw),
                else => return false,
            },
            0xDB => switch (reg) {
                0 => {
                    const n: i32 = @bitCast(bus.rd32(a));
                    f.pushRaw(intToExt(n));
                },
                2, 3 => {
                    bus.wr32(a, @as(u32, @bitCast(f.toInt(i32, f.get(0)))));
                    if (reg == 3) f.pop();
                },
                5 => f.pushRaw(rd80(bus, a)),
                7 => {
                    const x = f.ext(0);
                    _ = f.get(0);
                    wr80(bus, a, if (f.isEmpty(0)) INDEF80 else x);
                    f.pop();
                },
                else => return false,
            },
            0xDD => switch (reg) {
                0 => _ = f.push(@bitCast(rd64(bus, a))),
                2, 3 => {
                    wr64(bus, a, @as(u64, @bitCast(f.get(0))));
                    if (reg == 3) f.pop();
                },
                4 => {
                    const n = f.loadEnv(bus, a, o32);
                    var i: u4 = 0;
                    while (i < 8) : (i += 1) {
                        const raw = rd80(bus, a +% n +% @as(u32, i) * 10);
                        const p = f.top +% @as(u3, @intCast(i));
                        f.st[p] = fromExt(raw);
                        f.raw[p] = raw;
                        f.exact |= bit(p);
                    }
                },
                6 => {
                    const n = f.storeEnv(bus, a, o32);
                    var i: u4 = 0;
                    while (i < 8) : (i += 1) wr80(bus, a +% n +% @as(u32, i) * 10, f.ext(@intCast(i)));
                    f.init();
                },
                7 => bus.wr16(a, f.status()),
                else => return false,
            },
            0xDF => switch (reg) {
                0 => f.pushRaw(intToExt(@as(i16, @bitCast(bus.rd16(a))))),
                2, 3 => {
                    bus.wr16(a, @as(u16, @bitCast(f.toInt(i16, f.get(0)))));
                    if (reg == 3) f.pop();
                },
                4 => f.pushRaw(bcdLoad(bus, a)),
                5 => f.pushRaw(intToExt(@bitCast(rd64(bus, a)))),
                6 => {
                    f.bcdStore(bus, a);
                    f.pop();
                },
                7 => {
                    wr64(bus, a, @as(u64, @bitCast(f.toI64(0))));
                    f.pop();
                },
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    fn escReg(f: *Fpu, r: *Regs, op: u8, reg: u3, i: u3) bool {
        switch (op) {
            0xD8 => f.st0Op(reg, f.get(i)),
            0xDC, 0xDE => {
                // ST(i) = ST(i) op ST(0), with the SUB/SUBR and DIV/DIVR
                // encodings swapped against D8's.
                switch (reg) {
                    2 => f.compare(f.get(0), f.get(i), false),
                    3 => {
                        if (op == 0xDE and i != 1) return false;
                        f.compare(f.get(0), f.get(i), false);
                        f.pop();
                        if (op == 0xDE) f.pop();
                        return true;
                    },
                    else => {
                        const sw: u3 = switch (reg) {
                            4 => 5,
                            5 => 4,
                            6 => 7,
                            7 => 6,
                            else => reg,
                        };
                        f.put(i, f.arith(sw, f.get(i), f.get(0)));
                    },
                }
                if (op == 0xDE) f.pop();
            },
            0xD9 => switch (reg) {
                0 => {
                    const p = f.top +% i;
                    const v = f.get(i);
                    const was = f.exact & bit(p) != 0;
                    const raw = f.raw[p];
                    if (f.push(v) and was) {
                        f.raw[f.top] = raw;
                        f.exact |= bit(f.top);
                    }
                },
                1 => f.fxch(i),
                2 => if (i != 0) return false,
                3 => {
                    f.copy(i, 0);
                    f.pop();
                },
                4 => switch (i) {
                    0 => f.put(0, -f.get(0)),
                    1 => f.put(0, @abs(f.get(0))),
                    4 => f.compare(f.get(0), 0, false),
                    5 => f.fxam(),
                    else => return false,
                },
                5 => {
                    const k: f64 = switch (i) {
                        0 => 1.0,
                        1 => 3.321928094887362347870319429489390175864831393,
                        2 => math.log2e,
                        3 => math.pi,
                        4 => 0.301029995663981195213738894724493026768189881,
                        5 => math.ln2,
                        6 => 0.0,
                        7 => return false,
                    };
                    _ = f.push(k);
                },
                6 => f.trans1(i),
                7 => f.trans2(i),
            },
            0xDA => {
                if (reg == 5 and i == 1) {
                    f.compare(f.get(0), f.get(1), true);
                    f.pop();
                    f.pop();
                } else return false;
            },
            0xDB => {
                if (reg != 4) return false;
                switch (i) {
                    0, 1, 4 => {}, // FENI, FDISI (8087), FSETPM (287): no-ops
                    2 => f.sw &= ~(@as(u16, 0x80FF)),
                    3 => f.init(),
                    else => return false,
                }
            },
            0xDD => switch (reg) {
                0 => {
                    const p = f.top +% i;
                    f.empty |= bit(p);
                    f.exact &= ~bit(p);
                },
                1 => f.fxch(i),
                2, 3 => {
                    f.copy(i, 0);
                    if (reg == 3) f.pop();
                },
                4, 5 => {
                    f.compare(f.get(0), f.get(i), true);
                    if (reg == 5) f.pop();
                },
                else => return false,
            },
            0xDF => switch (reg) {
                0 => {
                    const p = f.top +% i;
                    f.empty |= bit(p);
                    f.exact &= ~bit(p);
                    f.pop();
                },
                1 => f.fxch(i),
                2, 3 => {
                    f.copy(i, 0);
                    f.pop();
                },
                4 => {
                    if (i != 0) return false;
                    r.set16(0, f.status());
                },
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    /// FXCH; an empty one is a stack underflow whose masked response
    /// makes it indefinite before the exchange.
    fn fxch(f: *Fpu, i: u3) void {
        const a = f.top;
        const b = f.top +% i;
        for ([_]u3{ a, b }) |p| if (f.empty & bit(p) != 0) {
            f.exc(IE | SF);
            f.st[p] = INDEF;
            f.exact &= ~bit(p);
            f.empty &= ~bit(p);
        };
        std.mem.swap(f64, &f.st[a], &f.st[b]);
        std.mem.swap(u80, &f.raw[a], &f.raw[b]);
        const xa = f.exact & bit(a) != 0;
        const xb = f.exact & bit(b) != 0;
        f.exact = (f.exact & ~(bit(a) | bit(b))) | (if (xb) bit(a) else 0) | (if (xa) bit(b) else 0);
        f.sw &= ~C1;
    }

    fn fxam(f: *Fpu) void {
        f.sw &= ~CC;
        const p = f.top;
        const v = f.st[p];
        if (math.signbit(v)) f.sw |= C1;
        if (f.empty & bit(p) != 0) {
            f.sw |= C3 | C0;
        } else if (math.isNan(v)) {
            f.sw |= C0;
        } else if (math.isInf(v)) {
            f.sw |= C2 | C0;
        } else if (v == 0) {
            f.sw |= C3;
        } else {
            // (a double's denormals are normals in the 80-bit format)
            f.sw |= C2;
        }
    }

    /// D9 F0-F7.
    fn trans1(f: *Fpu, i: u3) void {
        switch (i) {
            0 => { // F2XM1
                const x = f.get(0);
                f.put(0, f.prec(math.expm1(x * math.ln2)));
            },
            1 => { // FYL2X
                const x = f.get(0);
                const y = f.get(1);
                if (x < 0) f.exc(IE) else if (x == 0) f.exc(ZE);
                f.put(1, f.prec(y * math.log2(x)));
                f.pop();
            },
            2 => { // FPTAN
                const x = f.get(0);
                f.sw &= ~(C2 | C1);
                if (@abs(x) >= 0x1p63) {
                    f.sw |= C2;
                    return;
                }
                f.put(0, f.prec(@tan(x)));
                _ = f.push(1.0);
            },
            3 => { // FPATAN
                const x = f.get(0);
                const y = f.get(1);
                f.put(1, f.prec(math.atan2(y, x)));
                f.pop();
            },
            4 => { // FXTRACT
                const x = f.get(0);
                if (x == 0) {
                    f.exc(ZE);
                    f.put(0, -math.inf(f64));
                    _ = f.push(x);
                    return;
                }
                if (math.isInf(x)) {
                    f.put(0, math.inf(f64));
                    _ = f.push(x);
                    return;
                }
                if (math.isNan(x)) {
                    _ = f.push(x);
                    return;
                }
                const fr = math.frexp(x);
                f.put(0, @floatFromInt(fr.exponent - 1));
                _ = f.push(fr.significand * 2);
            },
            5 => f.prem(true), // FPREM1
            6 => { // FDECSTP
                f.top -%= 1;
                f.sw &= ~C1;
            },
            7 => { // FINCSTP
                f.top +%= 1;
                f.sw &= ~C1;
            },
        }
    }

    /// D9 F8-FF.
    fn trans2(f: *Fpu, i: u3) void {
        switch (i) {
            0 => f.prem(false), // FPREM
            1 => { // FYL2XP1
                const x = f.get(0);
                const y = f.get(1);
                f.put(1, f.prec(y * math.log1p(x) * math.log2e));
                f.pop();
            },
            2 => { // FSQRT
                const x = f.get(0);
                if (x < 0) f.exc(IE);
                f.put(0, f.prec(@sqrt(x)));
            },
            3, 6, 7 => { // FSINCOS, FSIN, FCOS
                const x = f.get(0);
                f.sw &= ~(C2 | C1);
                if (@abs(x) >= 0x1p63) {
                    f.sw |= C2;
                    return;
                }
                switch (i) {
                    6 => f.put(0, f.prec(@sin(x))),
                    7 => f.put(0, f.prec(@cos(x))),
                    else => {
                        f.put(0, f.prec(@sin(x)));
                        _ = f.push(f.prec(@cos(x)));
                    },
                }
            },
            4 => f.put(0, roundRc(f.get(0), f.rc())), // FRNDINT
            5 => { // FSCALE
                const x = f.get(0);
                const s = @trunc(f.get(1));
                if (math.isNan(s) or math.isNan(x)) {
                    f.put(0, x + s);
                    return;
                }
                const n: i32 = if (s > 100000) 100000 else if (s < -100000) -100000 else @intFromFloat(s);
                f.put(0, f.prec(math.ldexp(x, n)));
            },
        }
    }

    /// FPREM (truncating quotient) and FPREM1 (IEEE: nearest-even), done
    /// in one step (C2 = 0) with the quotient's low three bits in C0 C3 C1.
    fn prem(f: *Fpu, ieee: bool) void {
        const a = f.get(0);
        const b = f.get(1);
        f.sw &= ~CC;
        if (b == 0 or math.isInf(a) or math.isNan(a) or math.isNan(b)) {
            f.exc(IE);
            f.put(0, INDEF);
            return;
        }
        if (math.isInf(b)) return;
        var rem = @rem(a, b);
        var q = @trunc((a - rem) / b);
        if (ieee) {
            const half = @abs(b) / 2;
            const odd = @rem(@abs(q), 2) == 1;
            if (@abs(rem) > half or (@abs(rem) == half and odd)) {
                rem -= math.copysign(b, a);
                q += if ((a < 0) != (b < 0)) @as(f64, -1) else @as(f64, 1);
            }
        }
        const qa = @abs(q);
        const qb: u64 = if (qa < 0x1p63) @intFromFloat(qa) else 0;
        if (qb & 1 != 0) f.sw |= C1;
        if (qb & 2 != 0) f.sw |= C3;
        if (qb & 4 != 0) f.sw |= C0;
        f.put(0, rem);
    }

    fn bcdStore(f: *Fpu, bus: anytype, a: u32) void {
        const v = roundRc(f.get(0), f.rc());
        if (!(@abs(v) < 1e18)) {
            f.exc(IE);
            wr80(bus, a, INDEF80);
            return;
        }
        var n: u64 = @intFromFloat(@abs(v));
        var i: u32 = 0;
        while (i < 9) : (i += 1) {
            const lo: u8 = @intCast(n % 10);
            n /= 10;
            const hi: u8 = @intCast(n % 10);
            n /= 10;
            bus.wr8(a +% i, (hi << 4) | lo);
        }
        bus.wr8(a +% 9, if (math.signbit(v)) 0x80 else 0);
    }
};

fn bcdLoad(bus: anytype, a: u32) u80 {
    var n: i64 = 0;
    var i: u32 = 9;
    while (i > 0) {
        i -= 1;
        const b = bus.rd8(a +% i);
        n = n * 100 + @as(i64, b >> 4) * 10 + (b & 0xF);
    }
    const x = intToExt(n);
    return if (bus.rd8(a +% 9) & 0x80 != 0) x | (@as(u80, 1) << 79) else x;
}

fn rd64(bus: anytype, a: u32) u64 {
    return @as(u64, bus.rd32(a)) | (@as(u64, bus.rd32(a +% 4)) << 32);
}
fn wr64(bus: anytype, a: u32, v: u64) void {
    bus.wr32(a, @truncate(v));
    bus.wr32(a +% 4, @truncate(v >> 32));
}
fn rd80(bus: anytype, a: u32) u80 {
    return @as(u80, rd64(bus, a)) | (@as(u80, bus.rd16(a +% 8)) << 64);
}
fn wr80(bus: anytype, a: u32, v: u80) void {
    wr64(bus, a, @truncate(v));
    bus.wr16(a +% 8, @truncate(v >> 64));
}

/// Rounds to an integer by the control word's RC: nearest-even, down, up, chop.
pub fn roundRc(v: f64, mode: u2) f64 {
    return switch (mode) {
        0 => blk: {
            const t = @trunc(v);
            const d = v - t;
            if (@abs(d) == 0.5) break :blk if (@rem(t, 2) == 0) t else t + math.copysign(@as(f64, 1), v);
            break :blk @round(v);
        },
        1 => @floor(v),
        2 => @ceil(v),
        3 => @trunc(v),
    };
}

/// An 80-bit extended value as a double: exact when it fits, else nearest.
pub fn fromExt(raw: u80) f64 {
    const neg = (raw >> 79) != 0;
    const e: u32 = @truncate((raw >> 64) & 0x7FFF);
    const m: u64 = @truncate(raw);
    var v: f64 = undefined;
    if (e == 0x7FFF) {
        if (m << 1 == 0) {
            v = math.inf(f64);
        } else {
            var frac: u64 = (m >> 11) & ((@as(u64, 1) << 52) - 1);
            if (frac == 0) frac = @as(u64, 1) << 51;
            v = @bitCast((@as(u64, 0x7FF) << 52) | frac);
        }
    } else if (m == 0) {
        v = 0;
    } else {
        const ex: i32 = (if (e == 0) @as(i32, 1) else @as(i32, @intCast(e))) - 16383 - 63;
        // (two steps: 64 bits to 53 by the conversion, then the exponent,
        // exact unless the result is a double denormal)
        if (ex < -1074 - 64 + 1) {
            v = 0;
        } else if (ex > 1023) {
            v = math.inf(f64);
        } else {
            v = math.ldexp(@as(f64, @floatFromInt(m)), ex);
        }
    }
    return if (neg) -v else v;
}

/// A double as 80-bit extended (always exact).
pub fn toExt(v: f64) u80 {
    const b: u64 = @bitCast(v);
    const sign: u80 = @as(u80, b >> 63) << 79;
    const e: u32 = @truncate((b >> 52) & 0x7FF);
    const frac: u64 = b & ((@as(u64, 1) << 52) - 1);
    if (e == 0x7FF) {
        const m: u64 = (@as(u64, 1) << 63) | (frac << 11);
        return sign | (@as(u80, 0x7FFF) << 64) | m;
    }
    if (e == 0) {
        if (frac == 0) return sign;
        const lz: u32 = @clz(frac);
        const m = frac << @intCast(lz);
        const ex: u32 = @intCast(@as(i32, -1074 + 63 + 16383) - @as(i32, @intCast(lz)));
        return sign | (@as(u80, ex) << 64) | m;
    }
    const m: u64 = (@as(u64, 1) << 63) | (frac << 11);
    return sign | (@as(u80, e + 16383 - 1023) << 64) | m;
}

/// An integer as 80-bit extended (exact: 64 significant bits).
pub fn intToExt(n: i64) u80 {
    if (n == 0) return 0;
    const neg = n < 0;
    const mag: u64 = if (neg) @as(u64, @bitCast(-%n)) else @intCast(n);
    const lz: u32 = @clz(mag);
    const m = mag << @intCast(lz);
    const ex: u80 = 16383 + 63 - lz;
    return (if (neg) @as(u80, 1) << 79 else 0) | (ex << 64) | m;
}

/// An 80-bit value that is an integer within i64, exactly; null otherwise.
fn extInt(raw: u80) ?i64 {
    const neg = (raw >> 79) != 0;
    const e: i32 = @intCast((raw >> 64) & 0x7FFF);
    const m: u64 = @truncate(raw);
    if (m == 0) return 0;
    if (e == 0x7FFF) return null;
    const shift = 16383 + 63 - e;
    if (shift < 0 or shift > 63) return null;
    const s: u6 = @intCast(shift);
    if (m & ((@as(u64, 1) << s) - 1) != 0) return null;
    const mag = m >> s;
    if (neg) {
        if (mag > (@as(u64, 1) << 63)) return null;
        return @bitCast(0 -% mag);
    }
    if (mag > math.maxInt(i64)) return null;
    return @intCast(mag);
}

test "x87: 80-bit conversions" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 1.0), fromExt(toExt(1.0)));
    try t.expectEqual(@as(f64, -0.1), fromExt(toExt(-0.1)));
    try t.expectEqual(@as(f64, 5e-324), fromExt(toExt(5e-324)));
    try t.expectEqual(@as(u80, 0x3FFF_8000_0000_0000_0000), toExt(1.0));
    try t.expectEqual(@as(u80, 0x3FFF_8000_0000_0000_0000), intToExt(1));
    try t.expectEqual(@as(?i64, -5), extInt(intToExt(-5)));
    try t.expectEqual(@as(?i64, math.minInt(i64)), extInt(intToExt(math.minInt(i64))));
    try t.expectEqual(@as(?i64, math.maxInt(i64)), extInt(intToExt(math.maxInt(i64))));
    try t.expect(math.isInf(fromExt(0x7FFF_8000_0000_0000_0000)));
    try t.expect(math.isNan(fromExt(INDEF80)));
    try t.expectEqual(@as(f64, 2), roundRc(2.5, 0));
    try t.expectEqual(@as(f64, -2), roundRc(-2.5, 0));
    try t.expectEqual(@as(f64, 4), roundRc(3.5, 0));
    try t.expectEqual(@as(f64, -3), roundRc(-2.5, 1));
}
