//! Live-GPU dequant validation for the qwen35 GPU-streaming path.
//!
//! Maps the Qwen3.8-4B-Distill GGUF, finds the first Q4_K (ggml type 12) and
//! first Q6_K (type 14) weight tensor, reads the first 256-element super-block
//! of each, and runs `qwen35_kernels.selfTestDequant` — which dequantizes on
//! the GPU (NVRTC-compiled kernels) and on the host and requires every lane to
//! agree. Prints a PASS/stage-code line. Host I/O only maps the file and reads
//! arguments; all math is in ZPM modules.
//!
//! Run from a shell with CUDA bin\x64 on PATH:
//!   probe-qwen35-dequant <model.gguf>

const std = @import("std");
const process = @import("sig_process");
const gguf = @import("gguf");
const kernels = @import("qwen35_kernels");
const mem = @import("sig_mem");

const capacity = 2048;
var index: gguf.Index(capacity) = .{};

// Large GDN test buffers live in static storage (the recurrent state alone is
// 2 MB) to keep them off the limited Windows thread stack.
const gdn_mod = @import("qwen35_gdn");
var g_state: [gdn_mod.MAX_STATE]f32 = undefined;

const Memory = struct {
    bytes: []const u8,
    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        return true;
    }
    fn map(context: *const anyopaque, offset: u64, len: usize, alignment: usize) ?[*]const u8 {
        const self: *const Memory = @ptrCast(@alignCast(context));
        if (offset > self.bytes.len or len > self.bytes.len - offset or alignment == 0) return null;
        const pointer = self.bytes[@intCast(offset)..].ptr;
        if (@intFromPtr(pointer) % alignment != 0) return null;
        return pointer;
    }
    fn source(self: *const Memory) gguf.Source {
        return .{ .context = self, .size = self.bytes.len, .read_at = read, .map_at = map };
    }
};

fn firstTensorOfType(ggml_type: u32) ?*const gguf.TensorInfo {
    for (index.tensors[0..index.tensor_count]) |*t| {
        if (t.ggml_type == ggml_type and t.dimension_count >= 1 and t.dimensions[0] >= kernels.QK_K)
            return t;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var argv_buffer: [32768]u8 = undefined;
    var argv = process.Argv_Iterator.init(init.minimal.args.vector, &argv_buffer);
    _ = try argv.next();
    var path_buffer: [4096]u8 = undefined;
    const raw_path = try argv.next() orelse return error.ExpectedModelPath;
    if (raw_path.len > path_buffer.len) return error.ModelPathTooLong;
    @memcpy(path_buffer[0..raw_path.len], raw_path);
    const path = path_buffer[0..raw_path.len];

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const size = try file.length(init.io);
    if (size > ~@as(usize, 0)) return error.ModelTooLarge;
    var mapping = try file.createMemoryMap(init.io, .{ .len = @intCast(size), .protection = .{ .read = true, .write = false }, .populate = true });
    defer mapping.destroy(init.io);
    if (mapping.section == null) return error.NativeMappingRequired;
    const memory = Memory{ .bytes = mapping.memory };
    const source = memory.source();
    try gguf.parse(capacity, source, &index);

    var output_buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    const out = &writer.interface;

    // Dump blk.31 and blk.32 tensor names to see the last-layer structure.
    for (index.tensors[0..index.tensor_count]) |*t| {
        const nm = t.nameSlice();
        if (mem.startsWith(u8, nm, "blk.31.") or mem.startsWith(u8, nm, "blk.32."))
            try out.print("LAST {s} type={d}\n", .{ nm, t.ggml_type });
    }
    try out.flush();

    // Dump every distinct blk.* suffix present in the model (to find any
    // tensor the plan binder doesn't yet handle).
    {
        var seen: [64][48]u8 = undefined;
        var seen_len: [64]usize = @splat(0);
        var nseen: usize = 0;
        for (index.tensors[0..index.tensor_count]) |*t| {
            const nm = t.nameSlice();
            if (!mem.startsWith(u8, nm, "blk.")) continue;
            var p: usize = 4;
            while (p < nm.len and nm[p] != '.') p += 1;
            if (p + 1 >= nm.len) continue;
            const suf = nm[p + 1 ..];
            var dup = false;
            for (0..nseen) |i| if (mem.eql(u8, seen[i][0..seen_len[i]], suf)) {
                dup = true;
                break;
            };
            if (!dup and nseen < seen.len and suf.len <= 48) {
                @memcpy(seen[nseen][0..suf.len], suf);
                seen_len[nseen] = suf.len;
                nseen += 1;
                try out.print("SUFFIX {s}\n", .{suf});
            }
        }
        try out.flush();
    }

    const q4 = firstTensorOfType(12) orelse return error.NoQ4KTensor;
    const q6 = firstTensorOfType(14) orelse return error.NoQ6KTensor;
    try out.print("tensors={d} q4k_off={d} q6k_off={d}\n", .{ index.tensor_count, q4.file_offset, q6.file_offset });
    // Dump shapes of full-attn layer 3 (idx 3, (3+1)%4==0) + a GDN layer 0.
    for (index.tensors[0..index.tensor_count]) |*t| {
        const nm = t.nameSlice();
        const is_l3 = mem.startsWith(u8, nm, "blk.3.");
        const is_l0 = mem.startsWith(u8, nm, "blk.0.");
        if (is_l3 or is_l0) {
            try out.print("  {s} type={d} dims=[", .{ nm, t.ggml_type });
            for (0..t.dimension_count) |di| try out.print("{d}{s}", .{ t.dimensions[di], if (di + 1 < t.dimension_count) "," else "" });
            try out.writeAll("]\n");
        }
    }
    try out.flush();

    var q4_block: [kernels.Q4_K_BLOCK_BYTES]u8 = undefined;
    var q6_block: [kernels.Q6_K_BLOCK_BYTES]u8 = undefined;
    if (!Memory.read(&memory, q4.file_offset, &q4_block)) return error.ReadFailed;
    if (!Memory.read(&memory, q6.file_offset, &q6_block)) return error.ReadFailed;

    const stage = kernels.selfTestDequant(&q4_block, &q6_block, 1.0e-3);
    if (stage == 0) {
        try out.writeAll("DEQUANT_GPU_PARITY=PASS\n");
    } else {
        try out.print("DEQUANT_GPU_PARITY=FAIL stage={d}\n", .{stage});
    }
    try out.flush();
    if (stage != 0) return error.DequantParityFailure;

    // ── GPU matvec parity: first n rows of a Q4_K weight vs host matvecQ4K ──
    // Pick a Q4_K 2-D weight with k a multiple of 256 (dimensions[0] = k = cols,
    // dimensions[1] = n = rows in GGUF's [in, out] convention).
    const wt = q4; // first Q4_K tensor; dimensions[0] is the row length k
    const k: usize = wt.dimensions[0];
    if (wt.dimension_count != 2 or k % kernels.QK_K != 0) return error.UnsuitableWeight;
    const n: usize = 8; // small row slice keeps host + device scratch tiny
    const row_bytes = (k / kernels.QK_K) * kernels.Q4_K_BLOCK_BYTES;
    var weight_buf: [8 * 64 * kernels.Q4_K_BLOCK_BYTES]u8 = undefined; // n=8, k<=16384
    const weight = weight_buf[0 .. n * row_bytes];
    if (!Memory.read(&memory, wt.file_offset, weight)) return error.ReadFailed;

    var input_buf: [16384]f32 = undefined;
    const input = input_buf[0..k];
    for (input, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.01) * 0.5; // deterministic

    var gpu_dbg: [8]f32 = @splat(0);
    var host_dbg: [8]f32 = @splat(0);
    const mv = kernels.selfTestMatvecQ4KDiag(weight, input, n, k, 1.0e-3, &gpu_dbg, &host_dbg);
    if (mv == 0) {
        try out.print("MATVEC_GPU_PARITY=PASS n={d} k={d}\n", .{ n, k });
    } else {
        try out.print("MATVEC_GPU_PARITY=FAIL stage={d} n={d} k={d}\n", .{ mv, n, k });
        for (0..n) |i| try out.print("  row{d} gpu={d:.5} host={d:.5}\n", .{ i, gpu_dbg[i], host_dbg[i] });
    }
    try out.flush();
    if (mv != 0) return error.MatvecParityFailure;

    // ── GDN recurrent step parity: GPU gdn_step vs host qwen35_gdn.step ──
    const gdn = gdn_mod;
    const dims = gdn.GdnDims{ .kq_heads = 16, .v_heads = 32, .head_dim = 128 };
    const qkd = dims.qkDim();
    const vd = dims.vDim();
    const ste = dims.stateElements();
    // Deterministic pseudo-random inputs (bounded, exercises the recurrence).
    var g_q: [2048]f32 = undefined;
    var g_k: [2048]f32 = undefined;
    var g_v: [4096]f32 = undefined;
    var g_z: [4096]f32 = undefined;
    var g_ar: [32]f32 = undefined;
    var g_br: [32]f32 = undefined;
    var g_al: [32]f32 = undefined;
    var g_dt: [32]f32 = undefined;
    var g_nw: [128]f32 = undefined;
    for (0..qkd) |i| {
        g_q[i] = @sin(@as(f32, @floatFromInt(i)) * 0.017) * 0.7;
        g_k[i] = @cos(@as(f32, @floatFromInt(i)) * 0.023) * 0.6;
    }
    for (0..vd) |i| {
        g_v[i] = @sin(@as(f32, @floatFromInt(i)) * 0.011 + 1.0) * 0.9;
        g_z[i] = @cos(@as(f32, @floatFromInt(i)) * 0.019 + 0.5) * 0.8;
    }
    for (0..dims.v_heads) |i| {
        g_ar[i] = @sin(@as(f32, @floatFromInt(i)) * 0.3) * 0.5;
        g_br[i] = @cos(@as(f32, @floatFromInt(i)) * 0.4) * 1.5;
        g_al[i] = -0.5 + @sin(@as(f32, @floatFromInt(i)) * 0.2) * 0.3; // A_log
        g_dt[i] = 0.1 * @as(f32, @floatFromInt(i % 5));
    }
    for (0..dims.head_dim) |i| g_nw[i] = 1.0 + @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.1;
    // Nonzero initial state so the recurrence path (retrieved != 0) is exercised.
    for (0..ste) |i| g_state[i] = @sin(@as(f32, @floatFromInt(i)) * 0.0007) * 0.05;

    const gd = kernels.selfTestGdn(
        dims,
        g_q[0..qkd],
        g_k[0..qkd],
        g_v[0..vd],
        g_z[0..vd],
        g_ar[0..dims.v_heads],
        g_br[0..dims.v_heads],
        g_al[0..dims.v_heads],
        g_dt[0..dims.v_heads],
        g_nw[0..dims.head_dim],
        g_state[0..ste],
        1.0e-6,
        2.0e-3,
    );
    if (gd == 0) {
        try out.writeAll("GDN_GPU_PARITY=PASS\n");
    } else {
        try out.print("GDN_GPU_PARITY=FAIL stage={d}\n", .{gd});
    }
    try out.flush();
    if (gd != 0) return error.GdnParityFailure;
}
