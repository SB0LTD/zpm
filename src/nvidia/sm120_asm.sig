//! @zpm/nvidia sm120_asm — sm_120 compute kernels from assembly text.
//!
//! A kernel is instructions in nvdisasm's syntax, each after its control
//! field (see sm120.sig), with labels, comments and two headers:
//!
//!   .params 28            bytes of parameters (constant buffer 0 from 0x380)
//!   .stack 64             bytes of stack (local memory) a thread
//!   loop:                 a label; a branch names it: @P0 BRA `(loop)
//!   # a comment           (and // to the end of a line)
//!   [B------:R-:W0:Y:S01] S2R R5, SR_TID.X
//!
//! It comes out as the words a QMD's program address points at (two a
//! instruction, bits 63..0 first), padded with NOPs to whole 128-byte lines
//! as ptxas pads, and what a launch needs: the registers a thread uses
//! (ptxas's count, the highest register plus 3), its stack and parameter
//! bytes.
//!
//! The control fields are the author's: a kernel copied from nvdisasm's
//! listing of ptxas's output assembles to ptxas's words exactly (the tests
//! do it for Galaxy's five probe kernels and more), and a new one needs its stalls
//! and scoreboards worked out as ptxas would. Working them out here, as
//! ir3_asm does Adreno's delay slots, is the next step.
//!
//! Allocation-free: the caller owns the output words.

const std = @import("std");
const sm120 = @import("sm120.sig");

pub const MAX_INSTRS = 4096;
pub const MAX_LABELS = 128;

pub const Error = sm120.Error || error{
    TooManyInstructions,
    TooManyLabels,
    UnknownLabel,
    DuplicateLabel,
    BadHeader,
    /// An instruction without its control field.
    NoControl,
    BufferTooSmall,
};

pub const Kernel = struct {
    /// Two words an instruction, padded with NOPs to 128-byte lines.
    code: []const u64,
    /// Instructions before the padding.
    count: u32,
    /// Registers a thread (the QMD's register count).
    registers: u32,
    /// Stack bytes a thread (local memory).
    stack: u32 = 0,
    /// Parameter bytes, from constant buffer 0's 0x380.
    params: u32 = 0,
};

/// ptxas's NOP: no waits, no stall ([B------:R-:W-:-:S00] NOP).
pub const NOP_LO: u64 = 0x0000_0000_0000_7918;
pub const NOP_HI: u64 = 0x000f_c000_0000_0000;

/// ptxas pads a kernel's code to 128 bytes: 8 instructions.
const LINE: usize = 8;

/// What a line of the text is.
const Line = union(enum) {
    blank,
    label: []const u8,
    header: struct { name: []const u8, value: u32 },
    instr: []const u8,
};

fn classify(raw: []const u8) Error!Line {
    var t = raw;
    if (std.mem.indexOf(u8, t, "//")) |c| t = t[0..c];
    t = std.mem.trim(u8, t, " \t\r");
    if (t.len == 0 or t[0] == '#') return .blank;
    if (std.mem.startsWith(u8, t, ".params") or std.mem.startsWith(u8, t, ".stack")) {
        const sp = std.mem.indexOfAny(u8, t, " \t") orelse return error.BadHeader;
        const v = std.fmt.parseInt(u32, std.mem.trim(u8, t[sp..], " \t"), 0) catch return error.BadHeader;
        return .{ .header = .{ .name = t[1..sp], .value = v } };
    }
    if (t[t.len - 1] == ':') {
        const name = t[0 .. t.len - 1];
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t[]@") != null) return error.Syntax;
        return .{ .label = name };
    }
    if (t[0] != '[') return error.NoControl;
    return .{ .instr = t };
}

const Label = struct { name: []const u8, at: u64 };

/// `text`'s kernel into `out` (two u64 an instruction, at least
/// count rounded up to 8, times 2).
pub fn assemble(text: []const u8, out: []u64) Error!Kernel {
    var labels: [MAX_LABELS]Label = undefined;
    var n_labels: usize = 0;
    var k = Kernel{ .code = out[0..0], .count = 0, .registers = 0 };
    // Pass 1: the labels' addresses, the headers.
    var pc: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        switch (try classify(raw)) {
            .blank => {},
            .header => |h| {
                if (std.mem.eql(u8, h.name, "params")) k.params = h.value else k.stack = h.value;
            },
            .label => |name| {
                for (labels[0..n_labels]) |l| {
                    if (std.mem.eql(u8, l.name, name)) return error.DuplicateLabel;
                }
                if (n_labels == MAX_LABELS) return error.TooManyLabels;
                labels[n_labels] = .{ .name = name, .at = pc };
                n_labels += 1;
            },
            .instr => pc += 16,
        }
    }
    const count = pc / 16;
    if (count > MAX_INSTRS) return error.TooManyInstructions;
    const padded = (count + LINE - 1) / LINE * LINE;
    if (out.len < padded * 2) return error.BufferTooSmall;
    // Pass 2: encode.
    var top: ?u8 = null;
    pc = 0;
    lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const t = switch (try classify(raw)) {
            .instr => |t| t,
            else => continue,
        };
        const in = try sm120.parse(t);
        var target: ?u64 = null;
        if (in.label()) |name| {
            for (labels[0..n_labels]) |l| {
                if (std.mem.eql(u8, l.name, name)) target = l.at;
            }
            if (target == null) return error.UnknownLabel;
        }
        const w = try sm120.encode(&in, pc, target);
        const i = pc / 16;
        out[i * 2] = w.lo();
        out[i * 2 + 1] = w.hi();
        if (sm120.highestGpr(&in)) |r| top = if (top) |x| @max(x, r) else r;
        pc += 16;
    }
    var i = count;
    while (i < padded) : (i += 1) {
        out[i * 2] = NOP_LO;
        out[i * 2 + 1] = NOP_HI;
    }
    k.code = out[0 .. padded * 2];
    k.count = @intCast(count);
    k.registers = @as(u32, top orelse 0) + 3;
    return k;
}

// ── Host tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Galaxy's M4 kernel, written out: each of 32 threads stores
/// 0x600d0000 | its index to the word it owns at 0x20_0005_0000.
const M4 =
    \\// galaxy_m4: no parameters, no stack
    \\[B------:R-:W-:Y:S01] LDC R1, c[0x0][0x37c]            // the stack's top
    \\[B------:R-:W0:Y:S01] S2R R5, SR_TID.X                 // scoreboard 0: the thread index
    \\[B------:R-:W1:Y:S01] LDCU.64 UR4, c[0x0][0x358]       // scoreboard 1: the memory descriptor
    \\[B------:R-:W-:-:S06] MOV.64 R2, 0x2000050000
    \\[B0-----:R-:W-:Y:S01] IMAD.WIDE.U32 R2, R5.reuse, 0x4, R2
    \\[B------:R-:W-:-:S05] LOP3.LUT R5, R5, 0x600d0000, RZ, 0xfc, !PT
    \\[B-1----:R-:W-:Y:S01] STG.E desc[UR4][R2.64], R5
    \\[B------:R-:W-:Y:S05] EXIT
    \\hang:
    \\[B------:R-:W-:-:S00] BRA `(hang)
;

test "a kernel: labels, comments, padding, registers" {
    var out: [64]u64 = undefined;
    const k = try assemble(M4, &out);
    try testing.expectEqual(@as(u32, 9), k.count);
    try testing.expectEqual(@as(usize, 32), k.code.len); // (16 instructions: two lines)
    try testing.expectEqual(@as(u32, 8), k.registers); // (R5: 5 + 3)
    try testing.expectEqual(@as(u64, 0x0000_df00_ff01_7b82), k.code[0]);
    try testing.expectEqual(@as(u64, 0xffff_fffc_00fc_7947), k.code[16]); // (BRA to itself)
    try testing.expectEqual(NOP_LO, k.code[18]);
    try testing.expectEqual(NOP_HI, k.code[31]);
    try testing.expectError(error.NoControl, assemble("EXIT", &out));
    try testing.expectError(error.UnknownLabel, assemble("[B------:R-:W-:-:S00] BRA `(nowhere)", &out));
    try testing.expectError(error.BufferTooSmall, assemble(M4, out[0..16]));
}

test "ptxas's kernels from their listings (Galaxy's five probes, the coverage one): its words, registers, stack, parameters" {
    const data = @embedFile("sm120_vectors.txt");
    var kernels = std.mem.splitSequence(u8, data, "# kernel ");
    _ = kernels.next();
    var n: usize = 0;
    while (kernels.next()) |block| {
        // "<name> (<file>): registers R, stack S, params P"
        const head_end = std.mem.indexOfScalar(u8, block, '\n') orelse return error.TestUnexpectedResult;
        const head = block[0..head_end];
        const want = struct {
            fn field(h: []const u8, name: []const u8) !u32 {
                const at = (std.mem.indexOf(u8, h, name) orelse return error.TestUnexpectedResult) + name.len + 1;
                var end = at;
                while (end < h.len and std.ascii.isDigit(h[end])) end += 1;
                return std.fmt.parseInt(u32, h[at..end], 10);
            }
        };
        // The listing's text without its words, as an author would write it;
        // the words are kept to compare.
        var text: [48 * 1024]u8 = undefined;
        var len: usize = 0;
        var words: [2 * MAX_INSTRS]u64 = undefined;
        var n_words: usize = 0;
        const hdr = try std.fmt.bufPrint(text[len..], ".params {d}\n.stack {d}\n", .{ try want.field(head, "params"), try want.field(head, "stack") });
        len += hdr.len;
        var lines = std.mem.splitScalar(u8, block[head_end + 1 ..], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            const body = if (line[line.len - 1] == ':') line else blk: {
                words[n_words] = try std.fmt.parseInt(u64, line[17..33], 16);
                words[n_words + 1] = try std.fmt.parseInt(u64, line[0..16], 16);
                n_words += 2;
                break :blk line[34..];
            };
            @memcpy(text[len..][0..body.len], body);
            text[len + body.len] = '\n';
            len += body.len + 1;
        }
        var out: [2 * MAX_INSTRS]u64 = undefined;
        const k = try assemble(text[0..len], &out);
        try testing.expectEqualSlices(u64, words[0..n_words], k.code);
        try testing.expectEqual(try want.field(head, "registers"), k.registers);
        try testing.expectEqual(try want.field(head, "stack"), k.stack);
        try testing.expectEqual(try want.field(head, "params"), k.params);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 6), n);
}
