//! @zpm/nvidia sm75 — sm_75 (Turing: the RTX 20 series, the RTX 2080 Ti's
//! TU102) kernels, checked end to end without a card or NVIDIA's tools.
//!
//! sm_75 is not a second toolchain. The instructions are sm120.sig's with
//! the shader model given (`sm120.encodeFor(.sm_75, ...)`), the control
//! fields sm120_sched.sig's with sm_75's latencies, the assembler
//! sm120_asm.sig's `assembleFor`, the emulator sm120_emu.sig's with
//! `Work.sm`, the launch qmd.sig's version 02_02 and push.sig's
//! TURING_COMPUTE_A methods, and device.sig's EmuDevice with `sm`. Each of
//! those files says what differs and where it is documented (Mesa's NAK,
//! which NVK is conformant with on Turing, and NVIDIA's class headers).
//!
//! There is no ptxas and no nvdisasm here, and no Turing card that can be
//! reached, so nothing in this file compares with NVIDIA's own output. Two
//! kinds of test stand in:
//!
//! - **Words worked out by hand** from NAK's encoder (sm70_encode.rs), bit
//!   by bit, for one instruction of each form that differs on sm_75 and a
//!   few that do not: the encoder must give exactly those, and the decoder
//!   read them back. They test this module's reading of NAK, not NAK.
//! - **Kernels run on the emulated Turing GPU**: Galaxy's M4 probe written
//!   for sm_75, assembled, scheduled, launched through a pushbuffer and a
//!   version 02_02 QMD on an `EmuDevice` whose `sm` is sm_75, its timing
//!   checked. They test that the pieces fit each other.
//!
//! What only a card can say: whether TU102's SMs take these words (the
//! encodings NAK does not emit are refused, so every word here is one NVK
//! runs on Turing), whether sm_75's simple latency model is enough on the
//! chip, and whether the compute engine takes the QMD.
//!
//! Allocation-free: tests only.

const std = @import("std");
const sm120 = @import("sm120.sig");
const sm120_asm = @import("sm120_asm.sig");
const sched = @import("sm120_sched.sig");
const emu = @import("sm120_emu.sig");
const qmd = @import("qmd.sig");
const push = @import("push.sig");
const device = @import("device.sig");

pub const Sm = sm120.Sm;

/// Galaxy's M4 probe for sm_75, as nv_chan launches it on a Turing GPU:
/// each of a CTA's threads stores 0x600d0000 | its index to the word it
/// owns at 0x20_0005_0000. sm_120's (sm120_asm.sig's test, ptxas's output)
/// with Turing's forms: no memory descriptor, the base built from two
/// 32-bit moves (MOV.64 is sm_100's), the store's ordering NAK's.
pub const M4 =
    \\// galaxy_m4 for sm_75: no parameters, no stack
    \\S2R R5, SR_TID.X
    \\MOV R2, 0x50000
    \\MOV R3, 0x20
    \\IMAD.WIDE.U32 R2, R5, 0x4, R2
    \\LOP3.LUT R5, R5, 0x600d0000, RZ, 0xfc, !PT
    \\STG.E.STRONG.SYS [R2.64], R5
    \\EXIT
    \\hang:
    \\BRA `(hang)
;

/// M4 assembled and scheduled (`assembleFor(.sm_75, M4)`: the test below
/// keeps them equal), two words an instruction: what Galaxy's kernel puts
/// in the code slot on a Turing GPU, with no assembler in the kernel. Its
/// QMD's register count is M4_REGISTERS; it has no stack and no
/// parameters.
pub const M4_CODE = [_]u64{
    0x0000000000057919, 0x000e020000002100, // S2R R5, SR_TID.X
    0x0005000000027802, 0x000fc20000000f00, // MOV R2, 0x50000
    0x0000002000037802, 0x000fcc0000000f00, // MOV R3, 0x20
    0x0000000405027825, 0x001fc800078e0002, // IMAD.WIDE.U32 R2, R5, 0x4, R2
    0x600d000005057812, 0x000fcc00078efcff, // LOP3.LUT R5, R5, 0x600d0000, RZ, 0xfc, !PT
    0x0000000502007986, 0x0001c4000c11693f, // STG.E.STRONG.SYS [R2.64], R5
    0x000000000000794d, 0x001fc20003800000, // EXIT
    0xfffffff000007947, 0x000fc2000383ffff, // BRA `(hang)
};
pub const M4_REGISTERS: u32 = 8;
/// Where M4 stores (system memory in Galaxy's layout: nv_chan's OUT_VA),
/// and what thread i's word is: M4_WORD | i.
pub const M4_OUT_VA: u64 = 0x20_0005_0000;
pub const M4_WORD: u32 = 0x600d_0000;

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The control field of an instruction with nothing set: no scoreboards
/// (7 in the read and write fields), no stall.
const NO_CONTROL: u64 = 0x000f_c000_0000_0000;

fn words(text: []const u8, pc: u64) ![2]u64 {
    const in = try sm120.parse(text);
    const w = try sm120.encodeFor(.sm_75, &in, pc, null);
    // (and back: the decoder reads the same instruction from them)
    const back = try sm120.decodeFor(.sm_75, w.lo(), w.hi(), pc);
    const again = try sm120.encodeFor(.sm_75, &back, pc, null);
    try testing.expectEqual(w.bits, again.bits);
    return .{ w.lo(), w.hi() };
}

fn expectWords(text: []const u8, lo: u64, hi: u64) !void {
    const w = try words(text, 0);
    errdefer std.debug.print("{s}: {x:0>16} {x:0>16}, want {x:0>16} {x:0>16}\n", .{ text, w[0], w[1], lo, hi | NO_CONTROL });
    try testing.expectEqual(lo, w[0]);
    try testing.expectEqual(hi | NO_CONTROL, w[1]);
}

test "sm_75 words that differ from sm_120's, worked out from NAK's fields" {
    // BRA to itself: the distance (-4 words) whole in 34..81, nothing in
    // 16..23 (sm_120: fffffffc00fc7947).
    try expectWords("BRA `(0x0)", 0xffff_fff0_0000_7947, 0x0383_ffff);
    // LDG: no descriptor (bit 76 clear), URZ as 63 in six bits at 32, the
    // registers' .64 flags (90, 72), the scope (SYS: 3 at 77) and ordering
    // (STRONG: 2 at 79) in fields of their own, bit 91.
    try expectWords("LDG.E.STRONG.SYS R4, [R2.64]", 0x0000_003f_0204_7981, 0x0c1f_6900);
    // STG: URZ at 64, the data in 32, the offset at 40.
    try expectWords("STG.E.STRONG.SYS [R2.64+0x10], R5", 0x0000_1005_0200_7986, 0x0c11_693f);
    // (weak, the CTA's scope: nothing printed for either)
    try expectWords("LDG.E R4, [R2.64]", 0x0000_003f_0204_7981, 0x0c1e_8900);
    // LDL and STL with their uniform register (URZ), STL's opcode 0x987.
    try expectWords("LDL R0, [R1+0x8]", 0x0000_083f_0100_7983, 0x0810_0800);
    try expectWords("STL [R1+0x8], R0", 0x0000_0800_0100_7987, 0x0810_083f);
    // LDS and STS (0x988) the same way.
    try expectWords("LDS R0, [R1+0x8]", 0x0000_083f_0100_7984, 0x0800_0800);
    try expectWords("STS [R1+0x8], R0", 0x0000_0800_0100_7988, 0x0800_083f);
    // IMNMX (0x017): the signedness at 73, the min predicate at 87.
    try expectWords("IMNMX.S32 R0, R1, R2, PT", 0x0000_0002_0100_7217, 0x0380_0200);
    try expectWords("IMNMX.U32 R0, R1, R2, !PT", 0x0000_0002_0100_7217, 0x0780_0000);
    // BSSY without .RECONVERGENT (bit 73 clear), 12 words ahead.
    try expectWords("BSSY B0, `(0x40)", 0x0000_0030_0000_7945, 0x0380_0000);
    try expectWords("BSYNC B0", 0x0000_0000_0000_7941, 0x0380_0000);
    // NAK's barrier: the opcode and zeros.
    try expectWords("BAR.SYNC 0x0", 0x0000_0000_0000_7b1d, 0);
}

test "sm_75 words that are sm_120's too (NAK has one encoding for every SM)" {
    // IADD3: the three sources, both carries' predicates PT, their inputs
    // !PT (the four ones at 77 and at 87).
    try expectWords("IADD3 R0, PT, PT, R1, R2, RZ", 0x0000_0002_0100_7210, 0x07ff_e0ff);
    try expectWords("EXIT", 0x0000_0000_0000_794d, 0x0380_0000);
    try expectWords("NOP", 0x0000_0000_0000_7918, 0);
    // S2R: the special register's number at 72 (SR_TID.X is 0x21).
    try expectWords("S2R R5, SR_TID.X", 0x0000_0000_0005_7919, 0x0000_2100);
    // each is the word sm_120 has for it
    for ([_][]const u8{ "IADD3 R0, PT, PT, R1, R2, RZ", "EXIT", "NOP", "S2R R5, SR_TID.X", "MOV R2, 0x50000", "LOP3.LUT R5, R5, 0x600d0000, RZ, 0xfc, !PT", "IMAD.WIDE.U32 R2, R5, 0x4, R2", "FFMA R0, R1, R2, R3", "ISETP.GE.U32.AND P0, PT, R1, R2, PT", "SEL R0, R1, R2, P0", "LDC R1, c[0x0][0x37c]" }) |text| {
        const in = try sm120.parse(text);
        const a = try sm120.encodeFor(.sm_75, &in, 0, null);
        const b = try sm120.encode(&in, 0, null);
        try testing.expectEqual(b.bits, a.bits);
    }
}

test "what NAK does not emit for Turing is refused for sm_75, and Turing's own forms for sm_120" {
    const only_120 = [_][]const u8{
        "IADD R0, R1, R2",
        "MOV.64 R2, 0x2000050000",
        "VIMNMX.S32 R0, R1, R2, PT",
        "I2FP.F32.S32 R0, R1",
        "LDCU.64 UR4, c[0x0][0x358]",
        "UMOV UR4, 0x1",
        "WARPSYNC R2",
        "BSSY.RECONVERGENT B0, `(0x40)",
        "BAR.SYNC.DEFER_BLOCKING 0x0",
        "LDG.E R4, desc[UR4][R2.64]",
        "STG.E desc[UR4][R2.64], R5",
        "TEX.B.DXY R2, R0, R4, R6, 2D",
    };
    for (only_120) |text| {
        const in = try sm120.parse(text);
        _ = try sm120.encode(&in, 0, null);
        if (sm120.encodeFor(.sm_75, &in, 0, null)) |_| {
            std.debug.print("sm_75 took: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const only_75 = [_][]const u8{ "IMNMX.S32 R0, R1, R2, PT", "IMNMX.U32 R0, R1, 0x20, PT" };
    for (only_75) |text| {
        const in = try sm120.parse(text);
        _ = try sm120.encodeFor(.sm_75, &in, 0, null);
        if (sm120.encode(&in, 0, null)) |_| {
            std.debug.print("sm_120 took: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    // (a text both take is not the same word on both: a global load's
    // uniform register and ordering are other bits)
    const ld = try sm120.parse("LDG.E.STRONG.SYS R4, [R2.64]");
    try testing.expect((try sm120.encodeFor(.sm_75, &ld, 0, null)).bits != (try sm120.encode(&ld, 0, null)).bits);
    try testing.expect(sm120.has(.sm_75, "IMNMX") and !sm120.has(.sm_120, "IMNMX"));
    try testing.expect(sm120.has(.sm_120, "VIMNMX") and !sm120.has(.sm_75, "VIMNMX"));
    // a word of the other generation does not decode: sm_120's M4 has
    // LDCU, MOV.64 and a descriptor store
    try testing.expectError(error.Unknown, sm120.decodeFor(.sm_75, 0x0000_6b00_ff04_77ac, 0x000e_6200_0800_0a00, 0));
    try testing.expectError(error.Unknown, sm120.decodeFor(.sm_75, 0x2000_0500_0002_7402, 0x000f_cc00_0000_0000, 0));
    try testing.expectError(error.Unknown, sm120.decodeFor(.sm_75, 0x0000_0005_0200_7986, 0x002f_e200_0c10_1904, 0));
}

test "sm_75's latencies: NAK's model before it had a chip's tables" {
    const add = try sched.usesOfFor(.sm_75, &try sm120.parse("IADD3 R0, PT, PT, R1, R2, RZ"));
    const d = add.dsts()[0];
    try testing.expectEqual(sched.CAT75, d.cat);
    // a general register's result: 6 cycles to a reader, no scoreboard;
    // written again after 6; a register it read can be written after 4
    try testing.expectEqual(sched.Need{ .cycles = 6, .sb = false }, sched.need(.raw, d, false, d));
    try testing.expectEqual(sched.Need{ .cycles = 6, .sb = false }, sched.need(.waw, d, false, d));
    try testing.expectEqual(sched.Need{ .cycles = 4, .sb = false }, sched.need(.war, add.srcs()[0], false, d));
    // a predicate: 13
    const cmp = try sched.usesOfFor(.sm_75, &try sm120.parse("ISETP.GE.U32.AND P0, PT, R1, R2, PT"));
    try testing.expectEqual(sched.File.pred, cmp.dsts()[0].file);
    try testing.expectEqual(@as(u8, 13), sched.need(.raw, cmp.dsts()[0], false, cmp.dsts()[0]).cycles);
    // a load: variable latency, a scoreboard
    const ld = try sched.usesOfFor(.sm_75, &try sm120.parse("LDG.E.STRONG.SYS R4, [R2.64]"));
    try testing.expect(ld.decoupled);
    try testing.expect(sched.need(.raw, ld.dsts()[0], true, d).sb);
    // the packed halves: variable latency on Turing, and their cycles too
    const h = try sched.usesOfFor(.sm_75, &try sm120.parse("HADD2 R0, R1, R2"));
    try testing.expect(h.decoupled);
    try testing.expectEqual(sched.Need{ .cycles = 13, .sb = true }, sched.need(.raw, h.dsts()[0], true, d));
    // (on sm_120 they are fixed-latency, as they were)
    try testing.expect(!(try sched.usesOfFor(.sm_120, &try sm120.parse("HADD2 R0, R1, R2"))).decoupled);
    try testing.expect((try sched.usesOf(&try sm120.parse("IADD3 R0, PT, PT, R1, R2, RZ"))).dsts()[0].cat < sched.CAT75);
}

var asm_work: sm120_asm.Work = .{};
var emu_work: emu.Work = .{};
var arena: [1 << 20]u8 align(4096) = undefined;

test "M4 for sm_75: assembled and scheduled, then launched on an emulated Turing GPU" {
    var code: [64]u64 = undefined;
    const k = try sm120_asm.assembleFor(.sm_75, M4, &code, &asm_work);
    try testing.expect(k.scheduled);
    // (the words the kernel carries for a Turing GPU are these)
    try testing.expectEqualSlices(u64, &M4_CODE, k.code);
    try testing.expectEqual(M4_REGISTERS, k.registers);
    try testing.expectEqual(@as(u32, 8), k.registers); // (R5: 5 + 3)
    // (its own check of the schedule it made: nothing open)
    var slots: [16]sched.Slot = undefined;
    for (asm_work.slots[0..8], 0..) |s, i| slots[i] = s;
    const rep = try sched.check(asm_work.instrs[0..8], slots[0..8], &asm_work.sched);
    try testing.expectEqual(@as(u32, 0), rep.open);
    // the S2R's result is waited for by a scoreboard; the store waits on
    // the IMAD's and the LOP3's cycles
    try testing.expect(asm_work.slots[0].control.write != sm120.Control.NONE);

    // An emulated Turing GPU: its compute class, QMD version 02_02.
    emu_work.check_hazards = true;
    emu_work.strict = true;
    var dev = device.EmuDevice{ .arena = &arena, .work = &emu_work, .sm = .sm_75, .tpcs = 1, .warps_per_sm = 32 };
    const d = dev.device();
    // (the kernel's addresses are Galaxy's: system memory at 0x20_0000_0000)
    const sys = dev.allocAt(0x20_0000_0000, 0x6_0000) orelse return error.OutOfMemory;
    const out = std.mem.bytesAsSlice(u32, sys.cpu[0x5_0000..][0 .. 32 * 4]);
    @memset(std.mem.sliceAsBytes(out), 0);
    @memcpy(std.mem.sliceAsBytes(@as([]align(1) u64, @alignCast(std.mem.bytesAsSlice(u64, sys.cpu[0x4_0000..][0 .. k.code.len * 8])))), std.mem.sliceAsBytes(k.code));
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(sys.cpu[0x3_0000..].ptr));
    try qmd.buildFor(.sm_75, q, .{
        .prog_va = sys.va + 0x4_0000,
        .prog_bytes = k.code.len * 8,
        .cbuf_va = sys.va + 0x3_0200,
        .registers = k.registers,
        .block = .{ 32, 1, 1 },
    });
    const cb: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(sys.cpu[0x3_0200..].ptr));
    try qmd.cbuf0(cb, .{ 1, 1, 1 }, .{ 32, 1, 1 }, &.{});
    const pb = std.mem.bytesAsSlice(u32, sys.cpu[0x1_0000..][0 .. 64 * 4]);
    const n = try push.batchPushFor(.sm_75, @alignCast(pb), &.{sys.va + 0x3_0000}, null, sys.va + 0x2_0000, 0x1234);
    d.toDevice(sys, 0, sys.cpu.len);
    dev.execute(sys.va + 0x1_0000, @intCast(n)) catch |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("{s}\n", .{emu.explain(&emu_work, &buf)});
        return e;
    };
    d.fromDevice(sys, 0, sys.cpu.len);
    for (out, 0..) |w, i| try testing.expectEqual(@as(u32, 0x600d_0000) | @as(u32, @intCast(i)), w);
    try testing.expectEqual(@as(u32, 0x1234), std.mem.readInt(u32, sys.cpu[0x2_0000..][0..4], .little));
    try testing.expectEqual(@as(u64, 1), dev.launches);

    // The same stream on an emulated Blackwell GPU is refused at its first
    // method (TURING_COMPUTE_A is not its class), and sm_120's on this one.
    dev.sm = .sm_120;
    try testing.expectError(error.BadStream, dev.execute(sys.va + 0x1_0000, @intCast(n)));
    dev.sm = .sm_75;
    const n5 = try push.batchPush(@alignCast(pb), &.{sys.va + 0x3_0000}, null, sys.va + 0x2_0000, 0x1234);
    d.toDevice(sys, 0, sys.cpu.len);
    try testing.expectError(error.BadStream, dev.execute(sys.va + 0x1_0000, @intCast(n5)));
    // (and a Blackwell QMD behind Turing's methods: not version 02_02)
    try qmd.build(q, .{ .prog_va = sys.va + 0x4_0000, .prog_bytes = k.code.len * 8, .cbuf_va = sys.va + 0x3_0200, .registers = k.registers, .block = .{ 32, 1, 1 } });
    const n6 = try push.batchPushFor(.sm_75, @alignCast(pb), &.{sys.va + 0x3_0000}, null, sys.va + 0x2_0000, 0x1234);
    d.toDevice(sys, 0, sys.cpu.len);
    try testing.expectError(error.BadStream, dev.execute(sys.va + 0x1_0000, @intCast(n6)));
}
