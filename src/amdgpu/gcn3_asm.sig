//! @zpm/amdgpu gcn3_asm — compute kernels from GCN3 assembly text.
//!
//! A kernel is LLVM AMDGPU syntax (see gcn3.sig), one instruction per line,
//! with labels, comments (`;` or `//`) and LLVM's own `.amdhsa_*` directive
//! names for what the kernel descriptor holds, so the same text also
//! assembles with LLVM's `.amdhsa_kernel` block:
//!
//!   .amdhsa_user_sgpr_kernarg_segment_ptr 1   the kernarg pointer in s[0:1]
//!   .amdhsa_system_sgpr_workgroup_id_y 1      workgroup ids after the user SGPRs
//!   .amdhsa_system_vgpr_workitem_id 1         workitem ids x, y in v0, v1
//!   .amdhsa_group_segment_fixed_size 2048     LDS bytes
//!   .amdhsa_kernarg_size 28
//!   .amdhsa_next_free_vgpr / _sgpr N          optional: else counted
//!   .amdhsa_reserve_vcc / _flat_scratch 0|1   optional: else from use
//!   .workgroup_size 16 16 1                   (not LLVM's) for the dispatch
//!   loop:                                     a label; s_cbranch_scc1 loop
//!
//! Out come the code words, the dispatch.Config (register counts, user and
//! system SGPRs, LDS, scratch, float mode) and the workgroup size.
//!
//! Waits are the author's: s_waitcnt and s_nop are written in the text; the
//! emulator (gcn3_emu.sig) reports a missing one as a hazard.
//!
//! Allocation-free: the caller owns the working storage and the output.

const std = @import("std");
const gcn3 = @import("gcn3.sig");
const dispatch = @import("dispatch.sig");

pub const Instr = gcn3.Instr;

pub const MAX_INSTRS = 8192;
pub const MAX_LABELS = 256;

pub const Error = gcn3.Error || error{
    TooManyInstructions,
    TooManyLabels,
    UnknownLabel,
    DuplicateLabel,
    BadDirective,
    BranchOutOfRange,
    TooManyRegisters,
};

/// What the code itself uses, whatever the directives declare.
pub const Counted = struct {
    next_free_vgpr: u16 = 0,
    next_free_sgpr: u16 = 0,
    vcc: bool = false,
    flat_scratch: bool = false,
};

pub const Kernel = struct {
    code: []const u32,
    config: dispatch.Config,
    workgroup_size: [3]u16 = .{ 64, 1, 1 },
    /// Instructions (not dwords).
    instructions: usize = 0,
    counted: Counted = .{},

    pub fn descriptor(k: *const Kernel, entry_offset: i64) dispatch.Descriptor {
        return dispatch.Descriptor.from(&k.config, entry_offset);
    }
};

const Label = struct { name: []const u8, pc: u32 };

pub const Work = struct {
    instrs: [MAX_INSTRS]Instr = undefined,
    pcs: [MAX_INSTRS]u32 = undefined,
    /// The label a branch names (resolved in the second pass).
    targets: [MAX_INSTRS]?[]const u8 = undefined,
    /// Where each instruction came from (1-based), for errors.
    lines: [MAX_INSTRS]u32 = undefined,
    labels: [MAX_LABELS]Label = undefined,
    n: usize = 0,
    nlabels: usize = 0,
    /// The line of the last error.
    error_line: u32 = 0,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '$';
}

fn stripComment(line: []const u8) []const u8 {
    var end = line.len;
    var quote = false;
    for (line, 0..) |c, i| {
        if (c == '"') quote = !quote;
        if (quote) continue;
        if (c == ';' or (c == '/' and i + 1 < line.len and line[i + 1] == '/')) {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, line[0..end], " \t\r");
}

fn parseNum(s: []const u8) Error!u32 {
    const x = std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 0) catch return error.BadDirective;
    return x;
}

fn directive(cfg: *dispatch.Config, wg: *[3]u16, explicit: *Explicit, line: []const u8) Error!void {
    var it = std.mem.tokenizeAny(u8, line, " \t,");
    const name = it.next() orelse return error.BadDirective;
    if (std.mem.eql(u8, name, ".workgroup_size")) {
        for (wg) |*w| {
            const x = try parseNum(it.next() orelse return error.BadDirective);
            if (x == 0 or x > 1024) return error.BadDirective;
            w.* = @intCast(x);
        }
        return;
    }
    const val = try parseNum(it.next() orelse return error.BadDirective);
    const user = [_]struct { []const u8, dispatch.UserSgpr }{
        .{ ".amdhsa_user_sgpr_private_segment_buffer", .private_segment_buffer },
        .{ ".amdhsa_user_sgpr_dispatch_ptr", .dispatch_ptr },
        .{ ".amdhsa_user_sgpr_queue_ptr", .queue_ptr },
        .{ ".amdhsa_user_sgpr_kernarg_segment_ptr", .kernarg_segment_ptr },
        .{ ".amdhsa_user_sgpr_dispatch_id", .dispatch_id },
        .{ ".amdhsa_user_sgpr_flat_scratch_init", .flat_scratch_init },
        .{ ".amdhsa_user_sgpr_private_segment_size", .private_segment_size },
    };
    for (user) |u| {
        if (std.mem.eql(u8, name, u[0])) {
            const bit = @as(u8, 1) << @intFromEnum(u[1]);
            if (val != 0) cfg.user_sgprs |= bit else cfg.user_sgprs &= ~bit;
            return;
        }
    }
    const b = val != 0;
    if (std.mem.eql(u8, name, ".amdhsa_system_sgpr_workgroup_id_x")) cfg.workgroup_id[0] = b //
    else if (std.mem.eql(u8, name, ".amdhsa_system_sgpr_workgroup_id_y")) cfg.workgroup_id[1] = b //
    else if (std.mem.eql(u8, name, ".amdhsa_system_sgpr_workgroup_id_z")) cfg.workgroup_id[2] = b //
    else if (std.mem.eql(u8, name, ".amdhsa_system_sgpr_workgroup_info")) cfg.workgroup_info = b //
    else if (std.mem.eql(u8, name, ".amdhsa_system_sgpr_private_segment_wavefront_offset")) cfg.private_segment_wave_offset = b //
    else if (std.mem.eql(u8, name, ".amdhsa_system_vgpr_workitem_id")) {
        if (val > 2) return error.BadDirective;
        cfg.workitem_id = @intCast(val);
    } else if (std.mem.eql(u8, name, ".amdhsa_group_segment_fixed_size")) {
        if (val > 65536) return error.BadDirective;
        cfg.group_segment_bytes = val;
    } else if (std.mem.eql(u8, name, ".amdhsa_private_segment_fixed_size")) cfg.private_segment_bytes = val //
    else if (std.mem.eql(u8, name, ".amdhsa_kernarg_size")) cfg.kernarg_bytes = val //
    else if (std.mem.eql(u8, name, ".amdhsa_next_free_vgpr")) {
        if (val > 256) return error.BadDirective;
        cfg.next_free_vgpr = @intCast(val);
        explicit.vgpr = true;
    } else if (std.mem.eql(u8, name, ".amdhsa_next_free_sgpr")) {
        if (val > gcn3.SGPRS) return error.BadDirective;
        cfg.next_free_sgpr = @intCast(val);
        explicit.sgpr = true;
    } else if (std.mem.eql(u8, name, ".amdhsa_reserve_vcc")) {
        cfg.reserve_vcc = b;
        explicit.vcc = true;
    } else if (std.mem.eql(u8, name, ".amdhsa_reserve_flat_scratch")) {
        cfg.reserve_flat_scratch = b;
        explicit.flat_scratch = true;
    } else if (std.mem.eql(u8, name, ".amdhsa_float_round_mode_32")) cfg.float_round_mode_32 = @intCast(val & 3) //
    else if (std.mem.eql(u8, name, ".amdhsa_float_round_mode_16_64")) cfg.float_round_mode_16_64 = @intCast(val & 3) //
    else if (std.mem.eql(u8, name, ".amdhsa_float_denorm_mode_32")) cfg.float_denorm_mode_32 = @intCast(val & 3) //
    else if (std.mem.eql(u8, name, ".amdhsa_float_denorm_mode_16_64")) cfg.float_denorm_mode_16_64 = @intCast(val & 3) //
    else if (std.mem.eql(u8, name, ".amdhsa_dx10_clamp")) cfg.dx10_clamp = b //
    else if (std.mem.eql(u8, name, ".amdhsa_ieee_mode")) cfg.ieee_mode = b //
    else return error.BadDirective;
}

const Explicit = struct { vgpr: bool = false, sgpr: bool = false, vcc: bool = false, flat_scratch: bool = false };

/// Assemble `src` into `out` (dwords). The kernel's code is a slice of
/// `out`.
pub fn assemble(src: []const u8, work: *Work, out: []u32) Error!Kernel {
    var cfg = dispatch.Config{};
    var wg = [3]u16{ 64, 1, 1 };
    var explicit = Explicit{};
    work.n = 0;
    work.nlabels = 0;
    var pc: u32 = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var lineno: u32 = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        work.error_line = lineno;
        var line = stripComment(raw);
        // labels (several may share a line with an instruction)
        while (true) {
            var i: usize = 0;
            while (i < line.len and isIdent(line[i])) i += 1;
            if (i == 0 or i >= line.len or line[i] != ':') break;
            const name = line[0..i];
            for (work.labels[0..work.nlabels]) |l| {
                if (std.mem.eql(u8, l.name, name)) return error.DuplicateLabel;
            }
            if (work.nlabels == MAX_LABELS) return error.TooManyLabels;
            work.labels[work.nlabels] = .{ .name = name, .pc = pc };
            work.nlabels += 1;
            line = std.mem.trim(u8, line[i + 1 ..], " \t");
        }
        if (line.len == 0) continue;
        if (line[0] == '.') {
            try directive(&cfg, &wg, &explicit, line);
            continue;
        }
        if (work.n == MAX_INSTRS) return error.TooManyInstructions;
        var target: ?[]const u8 = null;
        const in = try gcn3.parseLabel(line, &target);
        work.instrs[work.n] = in;
        work.targets[work.n] = target;
        work.pcs[work.n] = pc;
        work.lines[work.n] = lineno;
        work.n += 1;
        pc += in.dwords();
    }
    if (pc > out.len) return error.BufferTooSmall;
    // Branches, then the words.
    var max_v: u16 = 0;
    var max_s: u16 = 0;
    var uses_vcc = false;
    var uses_flat_scratch = false;
    var at: usize = 0;
    for (work.instrs[0..work.n], 0..) |*in, i| {
        work.error_line = work.lines[i];
        if (work.targets[i]) |name| {
            var found: ?u32 = null;
            for (work.labels[0..work.nlabels]) |l| {
                if (std.mem.eql(u8, l.name, name)) found = l.pc;
            }
            const t = found orelse return error.UnknownLabel;
            const rel = @as(i64, t) - (@as(i64, work.pcs[i]) + 1);
            if (rel < -32768 or rel > 32767) return error.BranchOutOfRange;
            in.imm = @as(u16, @bitCast(@as(i16, @intCast(rel))));
        }
        at += try gcn3.encode(in, out[at..]);
        const rl = gcn3.regs(in);
        for (rl.readSlice()) |r| note(r, &max_v, &max_s, &uses_vcc, &uses_flat_scratch);
        for (rl.writeSlice()) |r| note(r, &max_v, &max_s, &uses_vcc, &uses_flat_scratch);
        for (in.src) |c| {
            if (c == gcn3.VCCZ) uses_vcc = true;
        }
    }
    if (!explicit.vgpr) cfg.next_free_vgpr = max_v;
    if (!explicit.sgpr) cfg.next_free_sgpr = max_s;
    if (!explicit.vcc) cfg.reserve_vcc = uses_vcc;
    if (!explicit.flat_scratch) cfg.reserve_flat_scratch = uses_flat_scratch;
    if (cfg.vgprs() > 256 or cfg.sgprs() > 104) return error.TooManyRegisters;
    if (cfg.userSgprCount() > 16) return error.TooManyRegisters;
    return .{
        .code = out[0..at],
        .config = cfg,
        .workgroup_size = wg,
        .instructions = work.n,
        .counted = .{ .next_free_vgpr = max_v, .next_free_sgpr = max_s, .vcc = uses_vcc, .flat_scratch = uses_flat_scratch },
    };
}

fn note(r: gcn3.RegRef, max_v: *u16, max_s: *u16, vcc: *bool, flat: *bool) void {
    if (r.code >= gcn3.VGPR0) {
        max_v.* = @max(max_v.*, r.code - gcn3.VGPR0 + r.n);
    } else if (r.code < gcn3.SGPRS) {
        max_s.* = @max(max_s.*, r.code + r.n);
    } else if (r.code == gcn3.VCC_LO or r.code == gcn3.VCC_HI) {
        vcc.* = true;
    } else if (r.code == gcn3.FLAT_SCRATCH_LO or r.code == gcn3.FLAT_SCRATCH_LO + 1) {
        flat.* = true;
    }
}

/// The kernel as text again: one instruction per line, with its dword
/// offset (a listing).
pub fn listing(code: []const u32, buf: []u8) gcn3.Error![]const u8 {
    var t = gcn3.Text{ .buf = buf };
    var at: usize = 0;
    while (at < code.len) {
        var in: Instr = undefined;
        const n = gcn3.decode(code[at..], &in) catch {
            t.print("{x:0>4}: .long 0x{x:0>8}\n", .{ at * 4, code[at] });
            at += 1;
            continue;
        };
        t.print("{x:0>4}: ", .{at * 4});
        try gcn3.formatInto(&t, &in);
        t.str("\n");
        at += n;
    }
    if (t.overflow) return error.BufferTooSmall;
    return t.text();
}

// ── Tests ───────────────────────────────────────────────────────────────────

var test_work: Work = .{};

test "labels, branches both ways, comments and directives" {
    const src =
        \\ ; a loop
        \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
        \\ .amdhsa_system_vgpr_workitem_id 1
        \\ .amdhsa_group_segment_fixed_size 1024
        \\ .workgroup_size 8, 8, 1
        \\     s_mov_b32 s4, 10           // count
        \\ top:
        \\     s_sub_u32 s4, s4, 1
        \\     s_cmp_lg_u32 s4, 0
        \\     s_cbranch_scc1 top
        \\     s_branch end
        \\     v_mov_b32_e32 v7, 0x12345678
        \\ end: s_endpgm
    ;
    var out: [64]u32 = undefined;
    const k = try assemble(src, &test_work, &out);
    try std.testing.expectEqual(@as(usize, 7), k.instructions);
    try std.testing.expectEqual(@as(usize, 8), k.code.len);
    // s_cbranch_scc1 at dword 3 back to dword 1: -3; s_branch at 4 to 7: +2
    try std.testing.expectEqual(@as(u32, 0xbf85fffd), k.code[3]);
    try std.testing.expectEqual(@as(u32, 0xbf820002), k.code[4]);
    try std.testing.expectEqual(@as(u16, 8), k.config.next_free_vgpr);
    try std.testing.expectEqual(@as(u16, 5), k.config.next_free_sgpr);
    try std.testing.expect(!k.config.reserve_vcc);
    try std.testing.expectEqual(@as(u16, 8), k.workgroup_size[1]);
    try std.testing.expectEqual(@as(u32, 1024), k.config.group_segment_bytes);
    var buf: [512]u8 = undefined;
    const text = try listing(k.code, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "0010: s_branch 2") != null);
}

/// The kernels in testdata/, each also built by LLVM (kernels_llvm.txt).
pub const test_kernels = [_]struct { []const u8, []const u8 }{
    .{ "copy", @embedFile("testdata/copy.s") },
    .{ "matmul", @embedFile("testdata/matmul.s") },
    .{ "branch", @embedFile("testdata/branch.s") },
};

test "the test kernels: LLVM's code words and kernel descriptors, byte for byte" {
    const data = @embedFile("testdata/kernels_llvm.txt");
    var out: [1024]u32 = undefined;
    var checked: usize = 0;
    for (test_kernels) |tk| {
        const k = try assemble(tk[1], &test_work, &out);
        // the declared counts are what the code uses
        try std.testing.expectEqual(k.counted.next_free_vgpr, k.config.next_free_vgpr);
        try std.testing.expectEqual(k.counted.next_free_sgpr, k.config.next_free_sgpr);
        try std.testing.expectEqual(k.counted.vcc, k.config.reserve_vcc);
        try std.testing.expectEqual(k.counted.flat_scratch, k.config.reserve_flat_scratch);
        var lines = std.mem.splitScalar(u8, data, '\n');
        var found = false;
        while (lines.next()) |raw| {
            // (a Windows checkout may carry CRLF)
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (!std.mem.startsWith(u8, line, "kernel ") or !std.mem.eql(u8, line[7..], tk[0])) continue;
            found = true;
            const code_line = std.mem.trimEnd(u8, lines.next().?, "\r");
            const kd_line = std.mem.trimEnd(u8, lines.next().?, "\r");
            var words = std.mem.tokenizeScalar(u8, code_line["code ".len..], ' ');
            var n: usize = 0;
            while (words.next()) |hx| : (n += 1) {
                const want = try std.fmt.parseInt(u32, hx, 16);
                if (n >= k.code.len or k.code[n] != want) {
                    std.debug.print("{s}: dword {d}: got {x:0>8} want {x:0>8}\n", .{ tk[0], n, if (n < k.code.len) k.code[n] else 0, want });
                    return error.TestUnexpectedResult;
                }
            }
            try std.testing.expectEqual(n, k.code.len);
            var want_kd: [64]u8 = undefined;
            _ = try std.fmt.hexToBytes(&want_kd, kd_line["descriptor ".len..]);
            const got_kd = k.descriptor(0).bytes();
            if (!std.mem.eql(u8, &want_kd, &got_kd)) {
                std.debug.print("{s}: descriptor\n got  {x}\n want {x}\n", .{ tk[0], got_kd, want_kd });
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(test_kernels.len, checked);
}

test "register counts include VCC and the hardware's SGPRs" {
    const src =
        \\ .amdhsa_user_sgpr_kernarg_segment_ptr 1
        \\ .amdhsa_system_sgpr_workgroup_id_y 1
        \\ v_add_u32_e32 v3, vcc, s2, v0
        \\ s_endpgm
    ;
    var out: [16]u32 = undefined;
    const k = try assemble(src, &test_work, &out);
    try std.testing.expect(k.config.reserve_vcc);
    // s0..s1 kernarg, s2 wg.x, s3 wg.y: 4 SGPRs + VCC
    try std.testing.expectEqual(@as(u16, 6), k.config.sgprs());
    try std.testing.expectEqual(@as(u16, 4), k.config.vgprs());
    try std.testing.expectError(error.UnknownLabel, assemble("s_branch nowhere", &test_work, &out));
    try std.testing.expectError(error.DuplicateLabel, assemble("a:\na:\ns_endpgm", &test_work, &out));
}
