//! The sm_120 encoding sweep's first half: every sm_120 program zpm makes,
//! written out as raw words for NVIDIA's own disassembler to judge.
//!
//! With a directory `.sm120-sweep` in the working directory (which
//! tools/sweep_sm120.py makes), this test writes there, for each program, NAME.bin
//! (its code words, 16 bytes an instruction, bits 63..0 first, as a QMD's
//! program address holds them) and NAME.txt (sm120.decode then
//! sm120.format of each word: what zpm thinks it encoded, one line an
//! instruction, the control field first). tools/sweep_sm120.py runs it,
//! then `nvdisasm -b SM120` on each .bin, and reports every word nvdisasm
//! calls illegal, or prints otherwise than sm120.format (a field zpm sets
//! that the hardware reads differently). Without the directory (and so
//! without CUDA) the tests skip.
//!
//! The programs: lfm3_nv's kernels (every variant lfm3_nv assembles:
//! the Q4_K and Q6_K matrices for 1 to 8 tokens, Q8_0's, the Q8_K
//! quantizations with and without RMSNorm, Q8_0's, the residuals, SwiGLU,
//! the convolutions, the attention prepare and attention), and kir_sm120's
//! output for the GPU self-test's kernels (every case, captured as
//! nvidia_device.Emu loads it) and for lfm3_kir's kernels (lfm3_any's and
//! the audio networks', for the RTX's caps).

const std = @import("std");
const nvidia = @import("nvidia");
const gpu = @import("gpu");
const matrix = @import("lfm3_nv_matrix");
const ops = @import("lfm3_nv_ops");
const lk = @import("lfm3_kir");
const sm120 = nvidia.sm120;
const sm120_asm = nvidia.sm120_asm;

const S = struct {
    var asm_work: sm120_asm.Work = .{};
    var words: [2 * sm120_asm.MAX_INSTRS]u64 = undefined;
    var dir: ?std.Io.Dir = null;
    var count: usize = 0;
    var text: [1 << 20]u8 = undefined;
};

fn dumpWords(name: []const u8, code: []const u64) !void {
    const dir = S.dir orelse return;
    var path: [256]u8 = undefined;
    const bin = try std.fmt.bufPrint(&path, "{s}.bin", .{name});
    try dir.writeFile(std.testing.io, .{ .sub_path = bin, .data = std.mem.sliceAsBytes(code) });
    // zpm's reading of each word
    var len: usize = 0;
    var i: usize = 0;
    while (i + 1 < code.len) : (i += 2) {
        const pc: u64 = i * 8;
        var line: [512]u8 = undefined;
        const s = blk: {
            const in = sm120.decode(code[i], code[i + 1], pc) catch |e| break :blk try std.fmt.bufPrint(&line, "?? {s}", .{@errorName(e)});
            var buf: [400]u8 = undefined;
            const t = sm120.format(&in, &buf) catch |e| break :blk try std.fmt.bufPrint(&line, "?? format {s}", .{@errorName(e)});
            break :blk try std.fmt.bufPrint(&line, "{s}", .{t});
        };
        const head = try std.fmt.bufPrint(S.text[len..], "{x:0>4} {s}\n", .{ pc, s });
        len += head.len;
    }
    const txt = try std.fmt.bufPrint(&path, "{s}.txt", .{name});
    try dir.writeFile(std.testing.io, .{ .sub_path = txt, .data = S.text[0..len] });
    S.count += 1;
}

fn dumpText(name: []const u8, text: []const u8) !void {
    const k = sm120_asm.assemble(text, &S.words, &S.asm_work) catch |e| {
        std.debug.print("sweep: {s}: does not assemble: {s}\n", .{ name, @errorName(e) });
        return e;
    };
    try dumpWords(name, k.code);
}

/// The output directory: `.sm120-sweep` in the working directory, which
/// tools/sweep_sm120.py makes (none: the tests skip).
fn openDir() bool {
    const cwd: std.Io.Dir = .cwd();
    S.dir = cwd.openDir(std.testing.io, ".sm120-sweep", .{}) catch return false;
    return true;
}

test "sweep: lfm3_nv's kernels, every variant, as raw words" {
    if (!openDir()) return error.SkipZigTest;
    var name: [64]u8 = undefined;
    inline for (1..matrix.MAX_TOKENS + 1) |t| {
        try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_q4k_{d}", .{t}), comptime matrix.q4kMatrix(t));
        try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_q6k_{d}", .{t}), comptime matrix.q6kMatrix(t));
        try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_q80_{d}", .{t}), comptime matrix.q80Matrix(t));
    }
    inline for ([_]u32{ 1, 2, 4, 8, 16, 32 }) |w| try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_normquant_{d}", .{w}), comptime matrix.q8kQuant(true, w));
    try dumpText("lfm3_nv_quant", comptime matrix.q8kQuant(false, 1));
    try dumpText("lfm3_nv_q80quant", comptime matrix.q80Quant());
    inline for ([_]u32{ 1024, 2048, 4096, 8192 }) |w| {
        try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_residual_post_{d}", .{w}), comptime ops.residual.source(true, w));
        try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_residual_{d}", .{w}), comptime ops.residual.source(false, w));
    }
    try dumpText("lfm3_nv_swiglu", comptime ops.swiglu.source());
    inline for (ops.conv.MIN_TAPS..ops.conv.MAX_TAPS + 1) |taps| try dumpText(try std.fmt.bufPrint(&name, "lfm3_nv_conv_{d}", .{taps}), comptime ops.conv.source(taps));
    try dumpText("lfm3_nv_prepare", comptime ops.prepare.source());
    try dumpText("lfm3_nv_attention", comptime ops.attention.source());
    std.debug.print("sweep: {d} programs written\n", .{S.count});
}

// ── kir_sm120's output: the self-test's kernels, as the emulated RTX loads them ──

const Capture = struct {
    var inner: gpu.Device = undefined;
    var vt: gpu.Device.VTable = undefined;
    var n: usize = 0;
    var dumped: usize = 0;

    fn load(ctx: *anyopaque, bin: *const gpu.Binary) gpu.Error!gpu.Program {
        if (bin.target == .sm_120) {
            var name: [64]u8 = undefined;
            const nm = std.fmt.bufPrint(&name, "kir_selftest_{d:0>2}", .{n}) catch "kir_selftest";
            n += 1;
            const words: []const u64 = @alignCast(std.mem.bytesAsSlice(u64, bin.code));
            dumpWords(nm, words) catch {};
            dumped += 1;
        }
        return inner.vtable.load(ctx, bin);
    }

    fn device(d: gpu.Device) gpu.Device {
        inner = d;
        vt = d.vtable.*;
        vt.load = load;
        return .{ .ctx = d.ctx, .vtable = &vt, .caps = d.caps };
    }
};

const R = struct {
    var arena: [24 << 20]u8 align(4096) = undefined;
    var view: [24 << 20]u8 align(4096) = undefined;
    var emu_work: nvidia.sm120_emu.Work = undefined;
    var dev: gpu.nvidia_device.Emu = undefined;
    var work: gpu.selftest.Work = undefined;
};

fn quiet(line: []const u8) void {
    _ = line;
}

test "sweep: kir_sm120's output for the self-test's kernels" {
    if (S.dir == null and !openDir()) return error.SkipZigTest;
    R.dev.init(&R.arena, &R.view, &R.emu_work);
    const d = Capture.device(R.dev.device());
    const res = gpu.selftest.runWith(gpu.all_targets, d, &R.work, quiet, .{ .stop_when_lost = false });
    std.debug.print("sweep: self-test {d} passed, {d} failed; {d} sm_120 programs written\n", .{ res.passed, res.failed, Capture.dumped });
}

// ── kir_sm120's output: lfm3_kir's kernels for the RTX ──────────────────────

const L = struct {
    var insts: [16384]gpu.kir.Inst = undefined;
    var tys: [32768]gpu.kir.Ty = undefined;
    var st: gpu.nvidia_device.kir_sm120.State = .{};
    var code: [512 * 1024]u8 align(16) = undefined;
};

fn sweepKir(name: []const u8, built: anyerror!gpu.kir.Kernel) !void {
    const k = built catch |e| {
        std.debug.print("sweep: {s}: not built ({s})\n", .{ name, @errorName(e) });
        return;
    };
    const caps = gpu.nvidia_device.rtx5070(8 << 30);
    const bin = gpu.nvidia_device.kir_sm120.compileIn(&k, caps, &L.st, &L.code, .{}) catch |e| {
        std.debug.print("sweep: {s}: does not compile ({s})\n", .{ name, @errorName(e) });
        return e;
    };
    try dumpWords(name, @alignCast(std.mem.bytesAsSlice(u64, bin.code)));
    const st = L.st.stats;
    if (st.div_collectives + st.nobar_collectives > 0) std.debug.print("sweep: {s}: {d} SHFL/VOTE in divergent code, {d} in a loop out of step\n", .{ name, st.div_collectives, st.nobar_collectives });
}

test "sweep: kir_sm120's output for lfm3_kir's kernels" {
    if (S.dir == null and !openDir()) return error.SkipZigTest;
    const caps = gpu.nvidia_device.rtx5070(8 << 30);
    const st: gpu.kir.Storage = .{ .insts = &L.insts, .tys = &L.tys };
    var name: [64]u8 = undefined;
    for ([_]lk.Format{ .q4_k, .q6_k, .q8_0 }) |f| {
        for (1..lk.MAX_TOKENS + 1) |t| try sweepKir(try std.fmt.bufPrint(&name, "kir_lfm3_{s}_{d}", .{ @tagName(f), t }), lk.matrix(st, caps, f, @intCast(t)));
    }
    for ([_]lk.QuantMode{ .plain, .norm, .swiglu }) |m| try sweepKir(try std.fmt.bufPrint(&name, "kir_lfm3_quant_{s}", .{@tagName(m)}), lk.quant(st, caps, m));
    try sweepKir("kir_lfm3_q80quant", lk.q80Quant(st, caps));
    try sweepKir("kir_lfm3_residual", lk.residual(st, caps, false));
    try sweepKir("kir_lfm3_residual_post", lk.residual(st, caps, true));
    for (lk.MIN_TAPS..lk.MAX_TAPS + 1) |taps| try sweepKir(try std.fmt.bufPrint(&name, "kir_lfm3_conv_{d}", .{taps}), lk.conv(st, caps, @intCast(taps)));
    try sweepKir("kir_lfm3_prepare", lk.prepare(st, caps));
    for ([_]u32{ 1, 2, 4, 8 }) |hg| {
        for ([_]u32{ 1, 2, 4, 8 }) |tt| {
            if (hg * tt > 8) continue;
            try sweepKir(try std.fmt.bufPrint(&name, "kir_lfm3_scores_{d}x{d}", .{ hg, tt }), lk.attnScores(st, caps, hg, tt));
            try sweepKir(try std.fmt.bufPrint(&name, "kir_lfm3_values_{d}x{d}", .{ hg, tt }), lk.attnValues(st, caps, hg, tt));
        }
    }
    try sweepKir("kir_lfm3_softmax", lk.attnSoftmax(st, caps));
    try sweepKir("kir_lfm3_combine", lk.attnCombine(st, caps));
    try sweepKir("kir_lfm3_copy", lk.copy(st, caps));
    try sweepKir("kir_lfm3_normrows", lk.normRows(st, caps, false));
    try sweepKir("kir_lfm3_normrows_twice", lk.normRows(st, caps, true));
    try sweepKir("kir_lfm3_headnormrope", lk.headNormRope(st, caps, 32));
    try sweepKir("kir_lfm3_attend", lk.attendGgml(st, caps, false));
    try sweepKir("kir_lfm3_attend_gated", lk.attendGgml(st, caps, true));
    try sweepKir("kir_lfm3_glu", lk.gluGgml(st, caps));
    try sweepKir("kir_lfm3_depthinput", lk.depthInput(st, caps));
    try sweepKir("kir_lfm3_addbias", lk.addBias(st, caps));
    std.debug.print("sweep: lfm3_kir done, {d} programs in all\n", .{S.count});
}
