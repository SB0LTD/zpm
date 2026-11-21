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
    0x0000000502007986, 0x000bc4000c11693f, // STG.E.STRONG.SYS [R2.64], R5
    0x000000000000794d, 0x020fc20003800000, // EXIT
    0xfffffff000007947, 0x000fc2000383ffff, // BRA `(hang)
};
pub const M4_REGISTERS: u32 = 8;
/// M4 as a Probe (below), for what takes any of the kernels.
pub const M4_PROBE = Probe{ .code = &M4_CODE, .registers = M4_REGISTERS };
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
    // TEX through a handle (0x361 with bit 59; sm_120's is 0xd61 with bit
    // 91 and its uniform registers): the results' registers at 16 and 64,
    // the coordinates' at 24, the handle's at 32, the dimension at 61 (2D:
    // 1), all four channels at 72, no fault predicate (7 at 81).
    try expectWords("TEX.B R2, R0, R4, R6, 2D", 0x2800_0006_0400_7361, 0x000e_0f02);
    // (level zero: 1 in 87..89; .NODEP bit 90; two channels, no second
    // register)
    try expectWords("TEX.B.LZ.NODEP RZ, R0, R4, R6, 2D, 0x3", 0x2800_0006_0400_7361, 0x048e_03ff);
    // (a bias and a clamp: 5; a packed offset bit 76, .NDV 77, the depth
    // comparison 78)
    try expectWords("TEX.B.LB.LC.AOFFI.NDV.DC R2, R0, R4, R6, 2D", 0x2800_0006_0400_7361, 0x028e_7f02);
    // TLD (0x367): the level 1 (.LZ) or 3 (.LL) in 87..89, .MS bit 78.
    try expectWords("TLD.B.LZ R2, R0, R4, R6, 2D", 0x2800_0006_0400_7367, 0x008e_0f02);
    try expectWords("TLD.B.LL.MS R2, R0, R4, R6, 2D", 0x2800_0006_0400_7367, 0x018e_4f02);
}

test "the graphics stages' instructions on sm_75: sm_120's words (NAK has one form of each), and the texture forms each generation's own" {
    for ([_][]const u8{ "ALD R0, a[0x2fc]", "ALD.128 R4, a[0x80]", "AST.128 a[0x70], R4", "AST.64 a[0x80], R10", "IPA.PASS R0, a[0x7c]", "IPA.CONSTANT R4, a[0x80]", "PIXLD.COVMASK R0", "KILL" }) |text| {
        const in = try sm120.parse(text);
        const a = try sm120.encodeFor(.sm_75, &in, 0, null);
        const b = try sm120.encode(&in, 0, null);
        errdefer std.debug.print("{s}\n", .{text});
        try testing.expectEqual(b.bits, a.bits);
        const back = try sm120.decodeFor(.sm_75, a.lo(), a.hi(), 0);
        try testing.expectEqual(a.bits, (try sm120.encodeFor(.sm_75, &back, 0, null)).bits);
    }
    // a texture through a handle: the same text, another word
    const tex = try sm120.parse("TEX.B R2, R0, R4, R6, 2D");
    try testing.expect((try sm120.encodeFor(.sm_75, &tex, 0, null)).bits != (try sm120.encode(&tex, 0, null)).bits);
    // sm_120's word does not decode as sm_75's, nor sm_75's as sm_120's
    const w120 = try sm120.encode(&tex, 0, null);
    const w75 = try sm120.encodeFor(.sm_75, &tex, 0, null);
    try testing.expectError(error.Unknown, sm120.decodeFor(.sm_75, w120.lo(), w120.hi(), 0));
    try testing.expectError(error.Unknown, sm120.decode(w75.lo(), w75.hi(), 0));
    // what sm_75's texture forms have not: a uniform register for the
    // handle, sm_120's derivative mode, the modes NAK never emits
    for ([_][]const u8{ "TEX.B.DXY R2, R0, R4, R6, 2D", "TEX.B R2, R0, R4, R6, UR4, 2D", "TEX.B.ULB R2, R0, R4, R6, 2D", "TEX.B.UAOFFI R2, R0, R4, R6, 2D", "TLD.B.ULL R2, R0, R4, R6, 2D", "TLD.B.LZ.UMS R2, R0, R4, R6, 2D" }) |text| {
        const in = try sm120.parse(text);
        if (sm120.encodeFor(.sm_75, &in, 0, null)) |_| {
            std.debug.print("sm_75 took: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
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

// ── Galaxy's bench kernels for sm_75 ────────────────────────────────────────
//
// nv_bench's four (NV.TXT `bench`: local memory, fill, copy, matmul) are
// ptxas's sm_120 code on the Legion. These are the same kernels written by
// hand for sm_75 (no ptxas for it here), compact, not ptxas's unrolled
// ones: the same parameters at constant buffer 0's 0x380 (nv_bench's
// structs), the same results (its checks), with Turing's forms: plain
// [R.64] addresses, IADD3, no uniform registers. Each is text (what the
// assembler takes) and words (what Galaxy's kernel carries; a test keeps
// them the assembler's).

/// A kernel as Galaxy's nv_kernels.Kernel has one: its words, the QMD's
/// register count, its stack and parameter bytes.
pub const Probe = struct { code: []const u64, registers: u32, stack: u32 = 0, params: u32 = 0 };

/// fill(dst: u64, n: u32, seed: u32): dst[i] = (i * 0x9e3779b1) ^ seed, a
/// grid-stride loop (thread i0 = ctaid.x * ntid.x + tid.x, then every
/// nctaid.x * ntid.x th word).
pub const FILL_TEXT =
    \\.params 16
    \\S2R R3, SR_TID.X
    \\S2R R8, SR_CTAID.X
    \\LDC R6, c[0x0][0x360]
    \\LDC R9, c[0x0][0x370]
    \\LDC R10, c[0x0][0x388]
    \\IMAD R0, R6, R8, R3
    \\IMAD R6, R6, R9, RZ
    \\ISETP.GE.U32.AND P0, PT, R0, R10, PT
    \\@P0 EXIT
    \\LDC.64 R4, c[0x0][0x380]
    \\LDC R11, c[0x0][0x38c]
    \\loop:
    \\IMAD R7, R0, -0x61c8864f, RZ
    \\IMAD.WIDE.U32 R2, R0, 0x4, R4
    \\IADD3 R0, PT, PT, R6, R0, RZ
    \\LOP3.LUT R7, R7, R11, RZ, 0x3c, !PT
    \\ISETP.GE.U32.AND P0, PT, R0, R10, PT
    \\STG.E.STRONG.SYS [R2.64], R7
    \\@!P0 BRA `(loop)
    \\EXIT
    \\hang:
    \\BRA `(hang)
;

/// copy(dst: u64, src: u64, n4: u32): n4 16-byte words, the same loop.
pub const COPY_TEXT =
    \\.params 20
    \\S2R R3, SR_TID.X
    \\S2R R11, SR_CTAID.X
    \\LDC R10, c[0x0][0x360]
    \\LDC R18, c[0x0][0x370]
    \\LDC R19, c[0x0][0x390]
    \\IMAD R0, R10, R11, R3
    \\IMAD R10, R10, R18, RZ
    \\ISETP.GE.U32.AND P0, PT, R0, R19, PT
    \\@P0 EXIT
    \\LDC.64 R8, c[0x0][0x380]
    \\LDC.64 R6, c[0x0][0x388]
    \\loop:
    \\IMAD.WIDE.U32 R2, R0, 0x10, R6
    \\LDG.E.128.STRONG.SYS R12, [R2.64]
    \\IMAD.WIDE.U32 R4, R0, 0x10, R8
    \\IADD3 R0, PT, PT, R10, R0, RZ
    \\ISETP.GE.U32.AND P0, PT, R0, R19, PT
    \\STG.E.128.STRONG.SYS [R4.64], R12
    \\@!P0 BRA `(loop)
    \\EXIT
    \\hang:
    \\BRA `(hang)
;

/// local(out: u64): a 64-byte array on the thread's stack (local memory:
/// the stack's top is constant buffer 0's 0x37c), word (tid + j) & 15 of
/// it written tid * 16 + j for j = 0..15, then summed: out[tid] = tid *
/// 256 + 120.
pub const LOCAL_TEXT =
    \\.params 8
    \\.stack 64
    \\LDC R1, c[0x0][0x37c]
    \\S2R R19, SR_TID.X
    \\IADD3 R1, PT, PT, R1, -0x40, RZ
    \\IMAD R0, R19, 0x10, RZ
    \\MOV R2, RZ
    \\store:
    \\IADD3 R3, PT, PT, R19, R2, RZ
    \\LOP3.LUT R3, R3, 0xf, RZ, 0xc0, !PT
    \\IMAD R3, R3, 0x4, R1
    \\IADD3 R4, PT, PT, R0, R2, RZ
    \\IADD3 R2, PT, PT, R2, 0x1, RZ
    \\STL [R3], R4
    \\ISETP.LT.U32.AND P0, PT, R2, 0x10, PT
    \\@P0 BRA `(store)
    \\MOV R2, RZ
    \\MOV R5, RZ
    \\sum:
    \\IMAD R3, R2, 0x4, R1
    \\IADD3 R2, PT, PT, R2, 0x1, RZ
    \\LDL R4, [R3]
    \\ISETP.LT.U32.AND P0, PT, R2, 0x10, PT
    \\IADD3 R5, PT, PT, R5, R4, RZ
    \\@P0 BRA `(sum)
    \\LDC.64 R6, c[0x0][0x380]
    \\IMAD.WIDE.U32 R6, R19, 0x4, R6
    \\STG.E.STRONG.SYS [R6.64], R5
    \\EXIT
    \\hang:
    \\BRA `(hang)
;

/// matmul(c: u64, a: u64, b: u64, n: u32): c[row][col] = the sum over k of
/// a[row][k] * b[k][col] in fp32, fused, one thread an element (row =
/// ctaid.y * ntid.y + tid.y, col the same in x), naive.
pub const MATMUL_TEXT =
    \\.params 28
    \\S2R R7, SR_TID.Y
    \\S2R R3, SR_TID.X
    \\S2R R8, SR_CTAID.Y
    \\S2R R9, SR_CTAID.X
    \\LDC R0, c[0x0][0x360]
    \\LDC R2, c[0x0][0x364]
    \\LDC R5, c[0x0][0x398]
    \\IMAD R2, R2, R8, R7
    \\IMAD R0, R0, R9, R3
    \\ISETP.GE.U32.AND P0, PT, R2, R5, PT
    \\ISETP.GE.U32.OR P0, PT, R0, R5, P0
    \\@P0 EXIT
    \\LDC.64 R10, c[0x0][0x388]
    \\LDC.64 R12, c[0x0][0x390]
    \\LDC.64 R14, c[0x0][0x380]
    \\IMAD R7, R2, R5, RZ
    \\MOV R4, RZ
    \\MOV R6, RZ
    \\loop:
    \\IADD3 R16, PT, PT, R7, R6, RZ
    \\IMAD R18, R6, R5, R0
    \\IMAD.WIDE.U32 R16, R16, 0x4, R10
    \\IMAD.WIDE.U32 R18, R18, 0x4, R12
    \\IADD3 R6, PT, PT, R6, 0x1, RZ
    \\LDG.E.STRONG.SYS R20, [R16.64]
    \\LDG.E.STRONG.SYS R21, [R18.64]
    \\ISETP.LT.U32.AND P0, PT, R6, R5, PT
    \\FFMA R4, R20, R21, R4
    \\@P0 BRA `(loop)
    \\IADD3 R7, PT, PT, R7, R0, RZ
    \\IMAD.WIDE.U32 R14, R7, 0x4, R14
    \\STG.E.STRONG.SYS [R14.64], R4
    \\EXIT
    \\hang:
    \\BRA `(hang)
;

const FILL_CODE = [_]u64{
    0x0000000000037919, 0x000e020000002100, 0x0000000000087919, 0x000e420000002500,
    0x0000d800ff067b82, 0x000e820000000800, 0x0000dc00ff097b82, 0x000ec20000000800,
    0x0000e200ff0a7b82, 0x000f020000000800, 0x0000000806007224, 0x007fc800078e0203,
    0x0000000906067224, 0x008fc400078e02ff, 0x0000000a0000720c, 0x010fda0003f06070,
    0x000000000000094d, 0x000fc80003800000, 0x0000e000ff047b82, 0x000e020000000a00,
    0x0000e300ff0b7b82, 0x000e420000000800, 0x9e3779b100077824, 0x000fc200078e02ff,
    0x0000000400027825, 0x001fc800078e0004, 0x0000000006007210, 0x000fc20007ffe0ff,
    0x0000000b07077212, 0x002fca00078e3cff, 0x0000000a0000720c, 0x000fc20003f06070,
    0x0000000702007986, 0x000bd8000c11693f, 0xffffff9000008947, 0x020fc8000383ffff,
    0x000000000000794d, 0x000fc20003800000, 0xfffffff000007947, 0x000fc2000383ffff,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
};
const COPY_CODE = [_]u64{
    0x0000000000037919, 0x000e020000002100, 0x00000000000b7919, 0x000e420000002500,
    0x0000d800ff0a7b82, 0x000e820000000800, 0x0000dc00ff127b82, 0x000ec20000000800,
    0x0000e400ff137b82, 0x000f020000000800, 0x0000000b0a007224, 0x007fc800078e0203,
    0x000000120a0a7224, 0x008fc400078e02ff, 0x000000130000720c, 0x010fda0003f06070,
    0x000000000000094d, 0x000fc80003800000, 0x0000e000ff087b82, 0x000e020000000a00,
    0x0000e200ff067b82, 0x000e440000000a00, 0x0000001000027825, 0x002fcc00078e0006,
    0x0000003f020c7981, 0x000a42000c1f6d00, 0x0000001000047825, 0x001fc800078e0008,
    0x000000000a007210, 0x000fcc0007ffe0ff, 0x000000130000720c, 0x000fc20003f06070,
    0x0000000c04007986, 0x002bd8000c116d3f, 0xffffff9000008947, 0x020fc8000383ffff,
    0x000000000000794d, 0x000fc20003800000, 0xfffffff000007947, 0x000fc2000383ffff,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
};
const LOCAL_CODE = [_]u64{
    0x0000df00ff017b82, 0x000e020000000800, 0x0000000000137919, 0x000e420000002100,
    0xffffffc001017810, 0x001fc20007ffe0ff, 0x0000001013007824, 0x002fc200078e02ff,
    0x000000ff00027202, 0x000fcc0000000f00, 0x0000000213037210, 0x000fcc0007ffe0ff,
    0x0000000f03037812, 0x000fcc00078ec0ff, 0x0000000403037824, 0x000fc200078e0201,
    0x0000000200047210, 0x000fc80007ffe0ff, 0x0000000102027810, 0x000fc40007ffe0ff,
    0x0000000403007987, 0x000bc8000810083f, 0x000000100200780c, 0x000fda0003f01070,
    0xffffff8000000947, 0x020fc8000383ffff, 0x000000ff00027202, 0x000fc20000000f00,
    0x000000ff00057202, 0x000fca0000000f00, 0x0000000402037824, 0x000fc800078e0201,
    0x0000000102027810, 0x000fc40007ffe0ff, 0x0000003f03047983, 0x000a080008100800,
    0x000000100200780c, 0x000fc20003f01070, 0x0000000405057210, 0x001fd80007ffe0ff,
    0xffffffa000000947, 0x020fc8000383ffff, 0x0000e000ff067b82, 0x000e040000000a00,
    0x0000000413067825, 0x001fcc00078e0006, 0x0000000506007986, 0x000bc4000c11693f,
    0x000000000000794d, 0x020fc20003800000, 0xfffffff000007947, 0x000fc2000383ffff,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
};
const MATMUL_CODE = [_]u64{
    0x0000000000077919, 0x000e020000002200, 0x0000000000037919, 0x000e420000002100,
    0x0000000000087919, 0x000e820000002600, 0x0000000000097919, 0x000ec20000002500,
    0x0000d800ff007b82, 0x000f020000000800, 0x0000d900ff027b82, 0x000f020000000800,
    0x0000e600ff057b82, 0x000f040000000800, 0x0000000802027224, 0x015fc200078e0207,
    0x0000000900007224, 0x00afca00078e0203, 0x000000050200720c, 0x000fda0003f06070,
    0x000000050000720c, 0x000fda0000706470, 0x000000000000094d, 0x000fc80003800000,
    0x0000e200ff0a7b82, 0x000e020000000a00, 0x0000e400ff0c7b82, 0x000e420000000a00,
    0x0000e000ff0e7b82, 0x000e820000000a00, 0x0000000502077224, 0x000fc200078e02ff,
    0x000000ff00047202, 0x000fc20000000f00, 0x000000ff00067202, 0x000fcc0000000f00,
    0x0000000607107210, 0x000fc20007ffe0ff, 0x0000000506127224, 0x000fca00078e0200,
    0x0000000410107825, 0x001fc200078e000a, 0x0000000412127825, 0x002fc200078e000c,
    0x0000000106067810, 0x000fc80007ffe0ff, 0x0000003f10147981, 0x000a02000c1f6900,
    0x0000003f12157981, 0x000a42000c1f6900, 0x000000050600720c, 0x000fc20003f01070,
    0x0000001514047223, 0x003fd80000000004, 0xffffff6000000947, 0x024fc8000383ffff,
    0x0000000007077210, 0x000fcc0007ffe0ff, 0x00000004070e7825, 0x000fcc00078e000e,
    0x000000040e007986, 0x000bc4000c11693f, 0x000000000000794d, 0x020fc20003800000,
    0xfffffff000007947, 0x000fc2000383ffff, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
    0x0000000000007918, 0x000fc00000000000, 0x0000000000007918, 0x000fc00000000000,
};
pub const FILL = Probe{ .code = &FILL_CODE, .registers = 14, .params = 16 };
pub const COPY = Probe{ .code = &COPY_CODE, .registers = 22, .params = 20 };
pub const LOCAL = Probe{ .code = &LOCAL_CODE, .registers = 22, .stack = 64, .params = 8 };
pub const MATMUL = Probe{ .code = &MATMUL_CODE, .registers = 24, .params = 28 };

var asm_work: sm120_asm.Work = .{};
var emu_work: emu.Work = .{};
var arena: [4 << 20]u8 align(4096) = undefined;

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

// ── The bench kernels: assembled, then run as nv_bench runs them ────────────

const Run = struct { grid: [3]u32 = .{ 1, 1, 1 }, block: [3]u32 = .{ 1, 1, 1 }, params: []const u8 = &.{}, local: ?push.Local = null, local_bytes: u32 = 0 };

/// One launch on the emulated Turing GPU, as Galaxy lays it out in its
/// system memory `sys` (the pushbuffer at 0x1_0000, the semaphore at
/// 0x2_0000, the QMD at 0x3_0000 with constant buffer 0 behind it, the
/// code at 0x4_0000).
fn run75(dev: *device.EmuDevice, sys: device.Buffer, k: Probe, r: Run) !void {
    const d = dev.device();
    @memset(sys.cpu[0x4_0000..][0..0x2000], 0);
    @memcpy(sys.cpu[0x4_0000..][0 .. k.code.len * 8], std.mem.sliceAsBytes(k.code));
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(sys.cpu[0x3_0000..].ptr));
    try qmd.buildFor(.sm_75, q, .{ .prog_va = sys.va + 0x4_0000, .prog_bytes = k.code.len * 8, .cbuf_va = sys.va + 0x3_0200, .registers = k.registers, .grid = r.grid, .block = r.block, .local_bytes = r.local_bytes });
    const cb: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(sys.cpu[0x3_0200..].ptr));
    try qmd.cbuf0(cb, r.grid, r.block, r.params);
    const pb = std.mem.bytesAsSlice(u32, sys.cpu[0x1_0000..][0 .. 64 * 4]);
    const n = try push.batchPushFor(.sm_75, @alignCast(pb), &.{sys.va + 0x3_0000}, r.local, sys.va + 0x2_0000, 0x1234);
    std.mem.writeInt(u32, sys.cpu[0x2_0000..][0..4], 0, .little);
    d.toDevice(sys, 0, sys.cpu.len);
    dev.execute(sys.va + 0x1_0000, @intCast(n)) catch |e| {
        var buf: [512]u8 = undefined;
        std.debug.print("{s}\n", .{emu.explain(&emu_work, &buf)});
        return e;
    };
    d.fromDevice(sys, 0, sys.cpu.len);
    try testing.expectEqual(@as(u32, 0x1234), std.mem.readInt(u32, sys.cpu[0x2_0000..][0..4], .little));
}

fn fillWord(i: u32, seed: u32) u32 {
    return (i *% 0x9e37_79b1) ^ seed;
}
fn aOf(r: u32, k: u32) f32 {
    return @floatFromInt(@as(i32, @intCast((r * 3 + k) % 7)) - 3);
}
fn bOf(k: u32, c: u32) f32 {
    return @floatFromInt(@as(i32, @intCast((k * 3 + c * 2) % 5)) - 2);
}
fn cOf(r: u32, c: u32, n: u32) f32 {
    var s: f32 = 0;
    var k: u32 = 0;
    while (k < n) : (k += 1) s += aOf(r, k) * bOf(k, c);
    return s;
}

// (The words follow the scheduler's choices, which scoreboard it takes
// among them: when sm120_sched changes, this test prints each kernel's new
// words, to be put in place of the old ones, not edited by hand.)
test "M4 and the bench kernels for sm_75: their words are the assembler's" {
    var bad = false;
    inline for (.{ .{ "m4", M4, M4_PROBE }, .{ "fill", FILL_TEXT, FILL }, .{ "copy", COPY_TEXT, COPY }, .{ "local", LOCAL_TEXT, LOCAL }, .{ "matmul", MATMUL_TEXT, MATMUL } }) |c| {
        var code: [256]u64 = undefined;
        const k = try sm120_asm.assembleFor(.sm_75, c[1], &code, &asm_work);
        try testing.expect(k.scheduled);
        try testing.expectEqual(c[2].stack, k.stack);
        try testing.expectEqual(c[2].params, k.params);
        if (!std.mem.eql(u64, c[2].code, k.code) or c[2].registers != k.registers) {
            std.debug.print("{s} for sm_75: registers {d}, {d} words:\n", .{ c[0], k.registers, k.code.len });
            for (k.code, 0..) |w, i| std.debug.print("0x{x:0>16},{s}", .{ w, if (i % 4 == 3) "\n" else " " });
            std.debug.print("\n", .{});
            bad = true;
        }
    }
    if (bad) return error.TestUnexpectedResult;
}

test "the bench kernels for sm_75 on an emulated Turing GPU: nv_bench's checks (local memory, fill and copy, matmul)" {
    emu_work.check_hazards = true;
    emu_work.strict = true;
    var dev = device.EmuDevice{ .arena = &arena, .work = &emu_work, .sm = .sm_75, .tpcs = 1, .warps_per_sm = 32 };
    const d = dev.device();
    const sys = dev.allocAt(0x20_0000_0000, 0x6_0000) orelse return error.OutOfMemory;
    @memset(sys.cpu, 0);
    // local: 32 threads, a 64-byte stack array each, local memory sized as
    // Galaxy sizes it
    {
        const out = try d.alloc(4096);
        const s = qmd.localSize(LOCAL.stack, dev.warps_per_sm, dev.sms_per_tpc, dev.tpcs);
        const lm = try d.alloc(@intCast(s.total));
        const p = extern struct { out: u64 }{ .out = out.va };
        try run75(&dev, sys, LOCAL, .{ .block = .{ 32, 1, 1 }, .params = std.mem.asBytes(&p), .local = .{ .va = lm.va, .per_tpc = s.per_tpc }, .local_bytes = s.per_thread });
        d.fromDevice(out, 0, 128);
        for (out.words()[0..32], 0..) |v, t| try testing.expectEqual(@as(u32, @intCast(t)) * 256 + 120, v);
    }
    // fill and copy: 64 KiB filled by 8 CTAs of 256 (8 words a thread),
    // copied in 16-byte words, every word checked
    {
        const count: u32 = 16384;
        const src = try d.alloc(count * 4);
        const dst = try d.alloc(count * 4);
        const fp = extern struct { dst: u64, n: u32, seed: u32 }{ .dst = src.va, .n = count, .seed = 0x5eed_6a1a };
        try run75(&dev, sys, FILL, .{ .grid = .{ 8, 1, 1 }, .block = .{ 256, 1, 1 }, .params = std.mem.asBytes(&fp) });
        const cp = extern struct { dst: u64, src: u64, n4: u32 }{ .dst = dst.va, .src = src.va, .n4 = count / 4 };
        try run75(&dev, sys, COPY, .{ .grid = .{ 4, 1, 1 }, .block = .{ 256, 1, 1 }, .params = std.mem.asBytes(&cp)[0..20] });
        d.fromDevice(dst, 0, dst.cpu.len);
        for (dst.words()[0..count], 0..) |v, i| {
            if (v != fillWord(@intCast(i), 0x5eed_6a1a)) {
                std.debug.print("copy: word {d} is {x}\n", .{ i, v });
                return error.TestUnexpectedResult;
            }
        }
        // (a grid with more threads than words: the ones past the end exit)
        @memset(dst.cpu, 0);
        d.toDevice(dst, 0, dst.cpu.len);
        const few = extern struct { dst: u64, n: u32, seed: u32 }{ .dst = dst.va, .n = 100, .seed = 7 };
        try run75(&dev, sys, FILL, .{ .grid = .{ 2, 1, 1 }, .block = .{ 256, 1, 1 }, .params = std.mem.asBytes(&few) });
        d.fromDevice(dst, 0, dst.cpu.len);
        for (dst.words()[0..200], 0..) |v, i| try testing.expectEqual(if (i < 100) fillWord(@intCast(i), 7) else 0, v);
    }
    // matmul: 32 x 32 of small integers, every element exact
    {
        const n: u32 = 32;
        const a = try d.alloc(n * n * 4);
        const b = try d.alloc(n * n * 4);
        const c = try d.alloc(n * n * 4);
        for (0..n) |r| {
            for (0..n) |k| {
                a.words()[r * n + k] = @bitCast(aOf(@intCast(r), @intCast(k)));
                b.words()[r * n + k] = @bitCast(bOf(@intCast(r), @intCast(k)));
            }
        }
        d.toDevice(a, 0, a.cpu.len);
        d.toDevice(b, 0, b.cpu.len);
        const mp = extern struct { c: u64, a: u64, b: u64, n: u32 }{ .c = c.va, .a = a.va, .b = b.va, .n = n };
        try run75(&dev, sys, MATMUL, .{ .grid = .{ n / 16, n / 16, 1 }, .block = .{ 16, 16, 1 }, .params = std.mem.asBytes(&mp)[0..28] });
        d.fromDevice(c, 0, c.cpu.len);
        for (0..n) |r| {
            for (0..n) |col| try testing.expectEqual(@as(u32, @bitCast(cOf(@intCast(r), @intCast(col), n))), c.words()[r * n + col]);
        }
    }
}
