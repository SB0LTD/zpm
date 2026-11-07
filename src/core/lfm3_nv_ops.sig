//! @zpm/lfm3-nv-ops — LFM3's layer kernels for NVIDIA's sm_120 (the RTX 50
//! series: the Legion 5's RTX 5070 Laptop GPU), in pure Sig: the residual
//! add (with LFM3's sandwich post-norms), SwiGLU, the gated short
//! convolution, the attention prepare (per-head RMSNorm of the queries and
//! keys, NeoX RoPE, the f16 KV cache rows) and attention itself. The
//! quantized matrices and the activation quantization are
//! lfm3_nv_matrix's; the Adreno twins are lfm3_gpu_kernels'.
//!
//! Each kernel is sm_120 assembly text in nvdisasm's syntax with no control
//! fields: nvidia.sm120_asm schedules and encodes it (`.params N` heads
//! it). Each has, in its namespace:
//!
//!   Params            the extern struct at constant buffer 0's 0x380
//!   source(...)       the text (comptime: its shape's variant)
//!   launch(...)       the grid, the block and the kernel's own shared
//!                     bytes (from 0x400: qmd.Shape.shared_bytes, the QMD
//!                     adds the reserved 1 KiB), or why not
//!   params(...)       where a field is derived (the KV cache's addresses)
//!
//! Addresses are GPU virtual addresses, read through the memory descriptor
//! at c[0x0][0x358] (desc[UR4]). f32 rows are 16-byte aligned where a
//! kernel loads them 128 bits at a time (residual, SwiGLU, the cache rows)
//! and 4 elsewhere. Shared memory is addressed from 0x400, the first 1 KiB
//! being the SM's; launches are plain grids (no clusters), so a CTA's
//! window starts at 0.
//!
//! ## The kernels (T tokens of a call, from the cache's position P)
//!
//!   residual   hidden[t] += rmsnorm(block[t]) * weight (postnorm), or
//!              += block[t]: lfm3_executor's ResidualTask. Grid (T), 256
//!              threads; a thread holds width / 256 elements, in float4s
//!              256 apart; with the norm, each warp's sum of squares by
//!              SHFL.BFLY and the eight warps' through shared memory
//!              (BAR.SYNC), MUFU.RSQ. 32 shared bytes.
//!   swiglu     out = (g / (1 + exp(-g))) * u over `count` elements (out
//!              may be gate: SwiGluQuantizeTask's arithmetic before its
//!              quantization, which lfm3_nv_matrix's Q8_K kernel does
//!              next). 256 threads of four elements, count / 1024 CTAs
//!              rounded up.
//!   conv       lfm3_executor.shortConvChannels: one thread a channel, the
//!              tokens in order, the window in registers. 128 threads,
//!              hidden / 128 CTAs rounded up.
//!   prepare    PrepareTask: one warp a head (lane l holds elements l,
//!              l + 32, l + 64, l + 96: two RoPE pairs); grid (heads +
//!              2 kv_heads, T): the query heads (norm, RoPE, rounded
//!              through f16, back in place as f32), then the key heads
//!              (norm, RoPE, f16 into the cache), then the value heads (f16
//!              into the cache). 32 threads.
//!   attention  AttentionTask: one CTA a (query head, token), grid (group,
//!              kv_heads, T) with group = heads / kv_heads, so the CTA's
//!              KV head is its y and no division is needed; 128 threads in
//!              16 groups of 8. The query goes to shared memory; group g
//!              takes positions visible + g, + 16, ... with an online
//!              softmax of its own (running maximum and sum, MUFU.EX2): a
//!              position's score is its 8 threads' dot products of 16
//!              elements (the f16 key widened with HADD2.F32, f32 sums)
//!              added by SHFL.BFLY 1, 2, 4. The 16 groups' (maximum, sum,
//!              128 partial outputs) meet in shared memory, and thread e
//!              combines element e, times the head's sigmoid gate. 8832
//!              shared bytes. Every lane runs every pass (positions past
//!              the span are masked), so the shuffles never diverge.
//!
//! ## Layouts
//!
//! - Activations: f32 rows per token, as lfm3_executor's Workspace has them
//!   (query [T][heads][128], key and value [T][kv_heads][128], gate
//!   [T][heads], mixed [T][B | C | X] of hidden each).
//! - The KV cache: lfm3_executor's u16 (f16) elements, the row of
//!   (layer slot s, keys or values v, KV head h, position p) at element
//!   ((((s * 2 + v) * max_kv_heads + h) * context) + p) * 128. `KvCache`
//!   gives the byte addresses the kernels take: a layer's key and value
//!   blocks (head 0) and the bytes between heads (context * 256).
//! - The conv state: f32 rows of hidden, the oldest first, (taps - 1) of
//!   them per short-conv layer slot: layer slot s's at element
//!   s * (taps - 1) * hidden (lfm3_executor.Cache.conv). The taps: f32
//!   [hidden][taps] (the model's conv tensor).
//! - RoPE tables (`ropeTable`, made on the host per call as lfm3_gpu's
//!   rope_full and rope_swa buffers are): f32 [T][64][2], the cosine then
//!   the sine of lane pair i at the token's position, exactly
//!   lfm3_executor.ropeNeox's angles (full layers with the frequency
//!   factors and rope_frequency_base, sliding ones with
//!   rope_frequency_base_swa and none).
//!
//! ## Numerics against the CPU
//!
//! Exact (the CPU's floats to the bit, the same operations in the same
//! order: separate multiplies and adds where the CPU has no fused ones):
//! the residual without the norm, the short convolution and its state,
//! RoPE given the same inputs, the f16 roundings, the value rows of the
//! cache. Float paths, compared with tolerances (the emulator's MUFU is
//! exact; the GPU's is approximate, about 2^-22 relative, far inside
//! them): the RMSNorms (f32 sums by a tree where the CPU sums in f64 in
//! order; MUFU.RSQ), within 1e-5 relative (the tests see 8e-7), so a query
//! or key element may come out one f16 ulp off; SwiGLU (MUFU.EX2 and
//! MUFU.RCP), within 1e-5 relative (seen: 5e-7), and -0 where a gate under
//! about -87 makes the CPU's result smaller than 1e-36 (MUFU.RCP flushes
//! the denormal sigmoid); attention (the online softmax rescales where the
//! CPU subtracts the maximum first, sums in f32 where the CPU sums in f64,
//! and its weights are not rounded through f16 as the CPU's are, which is
//! most of the difference), within 5e-3 of max(|out|, 0.05) as the Adreno
//! tests have it (seen: 1.8e-3 at most, with equal scores).
//!
//! The longest attention span is MAX_ATTENTION_SPAN positions, as on the
//! Adreno: attention.launch says error.LongContext past it, and the host
//! runs the call on the CPU.
//!
//! Allocation-free: the kernels' text is comptime; the host functions
//! write into the caller's memory.

const std = @import("std");
const nvidia = @import("nvidia");

const qmd = nvidia.qmd;

pub const HEAD_SIZE = 128;
/// The most positions one attention row reads (lfm3_gpu's limit).
pub const MAX_ATTENTION_SPAN = 4096;

pub const Error = error{
    /// A shape the kernels do not do (a width not in 1024s, a group of
    /// heads that does not divide, no tokens, a grid past the GPU's).
    Unsupported,
    /// The call's attention reaches further back than MAX_ATTENTION_SPAN
    /// positions: the CPU's call (lfm3_gpu.Error.LongContext).
    LongContext,
};

/// What a QMD needs from a kernel's shape.
pub const Launch = struct {
    grid: [3]u32,
    block: [3]u32,
    /// The kernel's own shared memory, after the reserved 1 KiB.
    shared_bytes: u32 = 0,
};

// ── Text ────────────────────────────────────────────────────────────────────

fn ln(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.comptimePrint(fmt ++ "\n", args);
}

/// A parameter of `P` in constant buffer 0: "c[0x0][0x388]".
fn cb(comptime P: type, comptime field: []const u8) []const u8 {
    return std.fmt.comptimePrint("c[0x0][0x{x}]", .{qmd.PARAMS_OFFSET + @offsetOf(P, field)});
}

fn header(comptime P: type) []const u8 {
    return std.fmt.comptimePrint(".params {d}\n", .{@sizeOf(P)});
}

/// An address's offset: "" or "+0x40".
fn off(comptime n: comptime_int) []const u8 {
    return if (n == 0) "" else std.fmt.comptimePrint("+0x{x}", .{n});
}

/// The low (H0) or high (H1) half of R`n`, as a source of HADD2: "R5.H1_H1".
fn halfOf(comptime n: comptime_int, comptime high: bool) []const u8 {
    return std.fmt.comptimePrint("R{d}.{s}", .{ n, if (high) "H1_H1" else "H0_H0" });
}

/// -log2(e) and log2(e) as ptxas prints the f32s.
const MINUS_LOG2E = "-1.4426950216293334961";
const LOG2E: f32 = 1.4426950216293334961;

/// A warp's sum of R`v` into every lane (R`t` scratch): SHFL.BFLY 16, 8,
/// 4, 2, 1.
fn warpSum(comptime v: comptime_int, comptime t: comptime_int) []const u8 {
    comptime {
        var s: []const u8 = "";
        for ([_]u32{ 0x10, 0x8, 0x4, 0x2, 0x1 }) |m| {
            s = s ++ ln("SHFL.BFLY PT, R{d}, R{d}, 0x{x}, 0x1f", .{ t, v, m });
            s = s ++ ln("FADD R{d}, R{d}, R{d}", .{ v, v, t });
        }
        return s;
    }
}

// ── Residual ────────────────────────────────────────────────────────────────

pub const residual = struct {
    pub const Params = extern struct {
        /// The residual stream, f32 [T][width], updated in place.
        hidden: u64,
        /// The block's output, f32 [T][width] (read).
        block: u64,
        /// The post-norm's weights, f32 [width] (postnorm only).
        weight: u64 = 0,
        epsilon: f32 = 0,
        /// 1 / width (postnorm only).
        inv_width: f32 = 0,
    };

    pub const THREADS = 256;
    /// Widths in 1024s up to this (a thread holds width / 256 elements).
    pub const MAX_WIDTH = 8192;

    pub fn params(hidden: u64, block: u64, weight: u64, width: u32, epsilon: f32) Params {
        return .{ .hidden = hidden, .block = block, .weight = weight, .epsilon = epsilon, .inv_width = 1.0 / @as(f32, @floatFromInt(width)) };
    }

    /// One CTA a token row of `width` (a multiple of 1024).
    pub fn source(comptime postnorm: bool, comptime width: u32) []const u8 {
        comptime {
            @setEvalBranchQuota(2_000_000);
            if (width == 0 or width % 1024 != 0 or width > MAX_WIDTH) @compileError("residual width");
            const v = width / 1024;
            // R14..R31 scalars (R24..R31 the warps' sums), then:
            const X = 32; // the block's elements
            const W = X + 4 * v; // the weights
            const H = W + 4 * v; // the residual stream's
            var s: []const u8 = header(Params);
            s = s ++ "S2R R0, SR_TID.X\n";
            s = s ++ "S2R R1, SR_CTAID.X\n";
            s = s ++ "LDCU.64 UR4, c[0x0][0x358]\n";
            s = s ++ ln("LDC.64 R2, {s}", .{cb(Params, "block")});
            s = s ++ ln("LDC.64 R4, {s}", .{cb(Params, "hidden")});
            // the thread's float4s: row t, bytes tid * 16 + c * 4096
            s = s ++ "IMAD.SHL.U32 R9, R0, 0x10, RZ\n";
            s = s ++ ln("IMAD R8, R1, 0x{x}, R9", .{width * 4});
            s = s ++ "IMAD.WIDE.U32 R10, R8, 0x1, R2\n";
            s = s ++ "IMAD.WIDE.U32 R12, R8, 0x1, R4\n";
            for (0..v) |c| s = s ++ ln("LDG.E.128 R{d}, desc[UR4][R10.64{s}]", .{ X + 4 * c, off(c * 4096) });
            if (postnorm) {
                // the sum of squares: the thread's, its warp's, the CTA's
                s = s ++ ln("FMUL R16, R{d}, R{d}", .{ X, X });
                for (1..4 * v) |e| s = s ++ ln("FFMA R16, R{d}, R{d}, R16", .{ X + e, X + e });
                s = s ++ warpSum(16, 17);
                s = s ++ "LOP3.LUT R18, R0, 0x1f, RZ, 0xc0, !PT\n";
                s = s ++ "ISETP.EQ.U32.AND P0, PT, R18, RZ, PT\n";
                s = s ++ "SHF.R.U32.HI R19, RZ, 0x3, R0\n";
                s = s ++ "LOP3.LUT R19, R19, 0x7c, RZ, 0xc0, !PT\n"; // (warp * 4)
                s = s ++ "@P0 STS [R19+0x400], R16\n";
                s = s ++ "BAR.SYNC.DEFER_BLOCKING 0x0\n";
                s = s ++ "LDS.128 R24, [0x400]\n";
                s = s ++ "LDS.128 R28, [0x410]\n";
                s = s ++ "FADD R16, R24, R25\n";
                for (26..32) |r| s = s ++ ln("FADD R16, R16, R{d}", .{r});
                // inverse = 1 / sqrt(mean + epsilon)
                s = s ++ ln("LDC R14, {s}", .{cb(Params, "inv_width")});
                s = s ++ ln("LDC R15, {s}", .{cb(Params, "epsilon")});
                s = s ++ "FMUL R16, R16, R14\n";
                s = s ++ "FADD R16, R16, R15\n";
                s = s ++ "MUFU.RSQ R16, R16\n";
                s = s ++ ln("LDC.64 R6, {s}", .{cb(Params, "weight")});
                s = s ++ "IMAD.WIDE.U32 R6, R9, 0x1, R6\n";
                for (0..v) |c| s = s ++ ln("LDG.E.128 R{d}, desc[UR4][R6.64{s}]", .{ W + 4 * c, off(c * 4096) });
                // value * inverse * weight, in the CPU's order
                for (0..4 * v) |e| {
                    s = s ++ ln("FMUL R{d}, R{d}, R16", .{ X + e, X + e });
                    s = s ++ ln("FMUL R{d}, R{d}, R{d}", .{ X + e, X + e, W + e });
                }
            }
            for (0..v) |c| s = s ++ ln("LDG.E.128 R{d}, desc[UR4][R12.64{s}]", .{ H + 4 * c, off(c * 4096) });
            for (0..4 * v) |e| s = s ++ ln("FADD R{d}, R{d}, R{d}", .{ H + e, H + e, X + e });
            for (0..v) |c| s = s ++ ln("STG.E.128 desc[UR4][R12.64{s}], R{d}", .{ off(c * 4096), H + 4 * c });
            s = s ++ "EXIT\n";
            return s;
        }
    }

    pub fn launch(postnorm: bool, width: u32, tokens: u32) Error!Launch {
        if (width == 0 or width % 1024 != 0 or width > MAX_WIDTH) return error.Unsupported;
        if (tokens == 0 or tokens > 0x7fff_ffff) return error.Unsupported;
        return .{ .grid = .{ tokens, 1, 1 }, .block = .{ THREADS, 1, 1 }, .shared_bytes = if (postnorm) 32 else 0 };
    }
};

// ── SwiGLU ──────────────────────────────────────────────────────────────────

pub const swiglu = struct {
    pub const Params = extern struct {
        /// f32 [count]: the FFN's gate projection.
        gate: u64,
        /// f32 [count]: its up projection.
        up: u64,
        /// f32 [count]: silu(gate) * up (may be `gate`).
        out: u64,
        /// Elements (T * feed_forward), a multiple of 4.
        count: u32,
        _pad: u32 = 0,
    };

    pub const THREADS = 256;

    pub fn source() []const u8 {
        comptime {
            @setEvalBranchQuota(200_000);
            var s: []const u8 = header(Params);
            s = s ++ "S2R R0, SR_TID.X\n";
            s = s ++ "S2R R1, SR_CTAID.X\n";
            s = s ++ ln("LDC R3, {s}", .{cb(Params, "count")});
            s = s ++ "IMAD R2, R1, 0x100, R0\n"; // the float4
            s = s ++ "IMAD.SHL.U32 R10, R2, 0x4, RZ\n"; // its first element
            s = s ++ "ISETP.GE.U32.AND P0, PT, R10, R3, PT\n";
            s = s ++ "@P0 EXIT\n";
            s = s ++ "LDCU.64 UR4, c[0x0][0x358]\n";
            s = s ++ ln("LDC.64 R4, {s}", .{cb(Params, "gate")});
            s = s ++ ln("LDC.64 R6, {s}", .{cb(Params, "up")});
            s = s ++ ln("LDC.64 R8, {s}", .{cb(Params, "out")});
            s = s ++ "IMAD.SHL.U32 R11, R2, 0x10, RZ\n";
            s = s ++ "IMAD.WIDE.U32 R4, R11, 0x1, R4\n";
            s = s ++ "IMAD.WIDE.U32 R6, R11, 0x1, R6\n";
            s = s ++ "IMAD.WIDE.U32 R8, R11, 0x1, R8\n";
            s = s ++ "LDG.E.128 R12, desc[UR4][R4.64]\n";
            s = s ++ "LDG.E.128 R16, desc[UR4][R6.64]\n";
            // g * (1 / (1 + 2^(-g log2 e))) * u
            for (0..4) |i| {
                s = s ++ ln("FMUL R{d}, R{d}, " ++ MINUS_LOG2E, .{ 20 + i, 12 + i });
                s = s ++ ln("MUFU.EX2 R{d}, R{d}", .{ 20 + i, 20 + i });
                s = s ++ ln("FADD R{d}, R{d}, 1", .{ 20 + i, 20 + i });
                s = s ++ ln("MUFU.RCP R{d}, R{d}", .{ 20 + i, 20 + i });
                s = s ++ ln("FMUL R{d}, R{d}, R{d}", .{ 12 + i, 12 + i, 20 + i });
                s = s ++ ln("FMUL R{d}, R{d}, R{d}", .{ 12 + i, 12 + i, 16 + i });
            }
            s = s ++ "STG.E.128 desc[UR4][R8.64], R12\n";
            s = s ++ "EXIT\n";
            return s;
        }
    }

    pub fn launch(count: u32) Error!Launch {
        if (count == 0 or count % 4 != 0) return error.Unsupported;
        return .{ .grid = .{ (count + 4 * THREADS - 1) / (4 * THREADS), 1, 1 }, .block = .{ THREADS, 1, 1 } };
    }
};

// ── The gated short convolution ─────────────────────────────────────────────

pub const conv = struct {
    pub const Params = extern struct {
        /// f32 [T][3 * hidden]: B, C and X of each token (in_proj's output).
        mixed: u64,
        /// f32 [hidden][taps].
        taps: u64,
        /// f32 [taps - 1][hidden], the oldest row first: read, then the
        /// last taps - 1 inputs written back.
        state: u64,
        /// f32 [T][hidden].
        out: u64,
        hidden: u32,
        tokens: u32,
    };

    pub const THREADS = 128;
    pub const MIN_TAPS = 2;
    pub const MAX_TAPS = 8;

    /// window = the state's rows then B * X; sum = 0 + w0 * window0 + ...,
    /// oldest first, each product rounded then added (the CPU's floats);
    /// out = C * sum; the window shifts. `taps` from 2 to 8.
    pub fn source(comptime taps: u32) []const u8 {
        comptime {
            @setEvalBranchQuota(1_000_000);
            if (taps < MIN_TAPS or taps > MAX_TAPS) @compileError("conv taps");
            const hist = taps - 1;
            // R8.. the weights, R16.. the window (R16 + hist the new input),
            // R40.. the state rows' addresses, R56.. the products
            var s: []const u8 = header(Params);
            s = s ++ "S2R R0, SR_TID.X\n";
            s = s ++ "S2R R1, SR_CTAID.X\n";
            s = s ++ ln("LDC R3, {s}", .{cb(Params, "hidden")});
            s = s ++ "IMAD R2, R1, 0x80, R0\n"; // the channel
            s = s ++ "ISETP.GE.U32.AND P0, PT, R2, R3, PT\n";
            s = s ++ "@P0 EXIT\n";
            s = s ++ "LDCU.64 UR4, c[0x0][0x358]\n";
            s = s ++ ln("LDC R4, {s}", .{cb(Params, "tokens")});
            s = s ++ "IMAD.SHL.U32 R5, R3, 0x4, RZ\n"; // a row of hidden: bytes
            s = s ++ "IMAD R30, R3, 0xc, RZ\n"; // a token's mixed row
            s = s ++ ln("LDC.64 R6, {s}", .{cb(Params, "taps")});
            s = s ++ ln("IMAD.WIDE.U32 R6, R2, 0x{x}, R6", .{taps * 4});
            for (0..taps) |j| s = s ++ ln("LDG.E R{d}, desc[UR4][R6.64{s}]", .{ 8 + j, off(4 * j) });
            s = s ++ ln("LDC.64 R24, {s}", .{cb(Params, "state")});
            s = s ++ "IMAD.WIDE.U32 R24, R2, 0x4, R24\n";
            for (0..hist) |r| {
                s = s ++ ln("IMAD.WIDE.U32 R{d}, R5, 0x{x}, R24", .{ 40 + 2 * r, r });
                s = s ++ ln("LDG.E R{d}, desc[UR4][R{d}.64]", .{ 16 + r, 40 + 2 * r });
            }
            s = s ++ ln("LDC.64 R26, {s}", .{cb(Params, "mixed")});
            s = s ++ "IMAD.WIDE.U32 R26, R2, 0x4, R26\n";
            s = s ++ ln("LDC.64 R28, {s}", .{cb(Params, "out")});
            s = s ++ "IMAD.WIDE.U32 R28, R2, 0x4, R28\n";
            s = s ++ "MOV R31, RZ\n";
            s = s ++ "loop:\n";
            s = s ++ "IMAD.WIDE.U32 R32, R5, 0x1, R26\n"; // C
            s = s ++ "IMAD.WIDE.U32 R34, R5, 0x2, R26\n"; // X
            s = s ++ "LDG.E R36, desc[UR4][R26.64]\n";
            s = s ++ "LDG.E R37, desc[UR4][R32.64]\n";
            s = s ++ "LDG.E R38, desc[UR4][R34.64]\n";
            s = s ++ ln("FMUL R{d}, R36, R38", .{16 + hist});
            for (0..taps) |j| s = s ++ ln("FMUL R{d}, R{d}, R{d}", .{ 56 + j, 16 + j, 8 + j });
            s = s ++ "FADD R39, RZ, R56\n"; // (from +0, as the CPU's sum)
            for (1..taps) |j| s = s ++ ln("FADD R39, R39, R{d}", .{56 + j});
            s = s ++ "FMUL R39, R37, R39\n";
            s = s ++ "STG.E desc[UR4][R28.64], R39\n";
            for (0..hist) |j| s = s ++ ln("MOV R{d}, R{d}", .{ 16 + j, 17 + j });
            s = s ++ "IMAD.WIDE.U32 R26, R30, 0x1, R26\n";
            s = s ++ "IMAD.WIDE.U32 R28, R5, 0x1, R28\n";
            s = s ++ "IADD R31, R31, 0x1\n";
            s = s ++ "ISETP.LT.U32.AND P0, PT, R31, R4, PT\n";
            s = s ++ "@P0 BRA `(loop)\n";
            for (0..hist) |r| s = s ++ ln("STG.E desc[UR4][R{d}.64], R{d}", .{ 40 + 2 * r, 16 + r });
            s = s ++ "EXIT\n";
            return s;
        }
    }

    pub fn launch(taps: u32, hidden: u32, tokens: u32) Error!Launch {
        if (taps < MIN_TAPS or taps > MAX_TAPS or hidden == 0 or tokens == 0) return error.Unsupported;
        // (byte offsets of a call's mixed rows stay in 32 bits)
        if (@as(u64, hidden) * 12 > 0xffff_ffff or @as(u64, hidden) * taps * 4 > 0xffff_ffff) return error.Unsupported;
        return .{ .grid = .{ (hidden + THREADS - 1) / THREADS, 1, 1 }, .block = .{ THREADS, 1, 1 } };
    }
};

// ── The KV cache ────────────────────────────────────────────────────────────

/// A sequence's f16 KV cache in lfm3_executor's layout, as the kernels
/// address it.
pub const KvCache = struct {
    /// The GPU address of its first element.
    kv: u64,
    /// Positions a head's block holds (Cache.context).
    context: u32,
    max_kv_heads: u32,

    /// Bytes between one KV head's block and the next.
    pub fn headStride(c: KvCache) u32 {
        return c.context * HEAD_SIZE * 2;
    }

    /// The byte address of the row of (slot, keys or values, head, position).
    pub fn row(c: KvCache, slot: u32, values: bool, head: u32, position: u32) u64 {
        const block = (@as(u64, slot) * 2 + @intFromBool(values)) * c.max_kv_heads + head;
        return c.kv + ((block * c.context) + position) * HEAD_SIZE * 2;
    }
};

// ── Attention: prepare ──────────────────────────────────────────────────────

pub const prepare = struct {
    pub const Params = extern struct {
        /// f32 [T][heads][128]: normed, rotated and rounded through f16 in
        /// place.
        query: u64,
        /// f32 [T][kv_heads][128] (read).
        key: u64,
        /// f32 [T][kv_heads][128] (read).
        value: u64,
        /// f32 [128] each.
        query_norm: u64,
        key_norm: u64,
        /// f32 [T][64][2] (ropeTable).
        rope: u64,
        /// The rows of KV head 0 at the call's first position, in the
        /// layer's key and value blocks (KvCache.row).
        k_cache: u64,
        v_cache: u64,
        /// KvCache.headStride.
        head_stride: u32,
        heads: u32,
        kv_heads: u32,
        epsilon: f32,
    };

    pub const THREADS = 32;

    pub const Shape = struct {
        query: u64,
        key: u64,
        value: u64,
        query_norm: u64,
        key_norm: u64,
        rope: u64,
        cache: KvCache,
        /// The layer's attention slot.
        slot: u32,
        heads: u32,
        kv_heads: u32,
        first_position: u32,
        epsilon: f32,
    };

    pub fn params(a: Shape) Params {
        return .{
            .query = a.query,
            .key = a.key,
            .value = a.value,
            .query_norm = a.query_norm,
            .key_norm = a.key_norm,
            .rope = a.rope,
            .k_cache = a.cache.row(a.slot, false, 0, a.first_position),
            .v_cache = a.cache.row(a.slot, true, 0, a.first_position),
            .head_stride = a.cache.headStride(),
            .heads = a.heads,
            .kv_heads = a.kv_heads,
            .epsilon = a.epsilon,
        };
    }

    /// The row in R12..R15 (elements lane, + 32, + 64, + 96): RMSNorm by
    /// the weights at R16:R17 (the warp's sum, MUFU.RSQ), in place.
    fn norm() []const u8 {
        comptime {
            var s: []const u8 = "";
            s = s ++ "FMUL R18, R12, R12\n";
            s = s ++ "FFMA R18, R13, R13, R18\n";
            s = s ++ "FFMA R18, R14, R14, R18\n";
            s = s ++ "FFMA R18, R15, R15, R18\n";
            s = s ++ warpSum(18, 19);
            s = s ++ "FMUL R18, R18, 0.0078125\n"; // (/ 128, exactly)
            s = s ++ "FADD R18, R18, R39\n";
            s = s ++ "MUFU.RSQ R18, R18\n";
            s = s ++ "IMAD.WIDE.U32 R16, R3, 0x1, R16\n";
            for (0..4) |i| s = s ++ ln("LDG.E R{d}, desc[UR4][R16.64{s}]", .{ 20 + i, off(0x80 * i) });
            for (0..4) |i| s = s ++ ln("FMUL R{d}, R{d}, R18", .{ 12 + i, 12 + i });
            for (0..4) |i| s = s ++ ln("FMUL R{d}, R{d}, R{d}", .{ 12 + i, 12 + i, 20 + i });
            return s;
        }
    }

    /// The cosines and sines of lane pairs lane and lane + 32 into R32..R35.
    fn ropeLoad() []const u8 {
        comptime {
            var s: []const u8 = "";
            s = s ++ ln("LDC.64 R24, {s}", .{cb(Params, "rope")});
            s = s ++ "IMAD R26, R2, 0x40, R0\n";
            s = s ++ "IMAD.WIDE.U32 R24, R26, 0x8, R24\n";
            s = s ++ "LDG.E.64 R32, desc[UR4][R24.64]\n";
            s = s ++ "LDG.E.64 R34, desc[UR4][R24.64+0x100]\n";
            return s;
        }
    }

    /// NeoX: low' = low cos - high sin, high' = low sin + high cos, each
    /// product rounded (the CPU's floats).
    fn ropeApply() []const u8 {
        comptime {
            var s: []const u8 = "";
            for (0..2) |p| {
                const lo = 12 + p;
                const hi = 14 + p;
                const c = 32 + 2 * p;
                s = s ++ ln("FMUL R36, R{d}, R{d}", .{ lo, c });
                s = s ++ ln("FMUL R37, R{d}, R{d}", .{ hi, c + 1 });
                s = s ++ "FADD R38, R36, -R37\n";
                s = s ++ ln("FMUL R36, R{d}, R{d}", .{ lo, c + 1 });
                s = s ++ ln("FMUL R37, R{d}, R{d}", .{ hi, c });
                s = s ++ ln("FADD R{d}, R36, R37", .{hi});
                s = s ++ ln("MOV R{d}, R38", .{lo});
            }
            return s;
        }
    }

    /// The four f32s of row R8:R9's lane into R12..R15.
    fn loadRow() []const u8 {
        comptime {
            var s: []const u8 = "";
            for (0..4) |i| s = s ++ ln("LDG.E R{d}, desc[UR4][R8.64{s}]", .{ 12 + i, off(0x80 * i) });
            return s;
        }
    }

    pub fn source() []const u8 {
        comptime {
            @setEvalBranchQuota(1_000_000);
            // R0 lane, R1 the CTA's head (queries, keys, values in turn),
            // R2 token, R3 lane * 4, R4 heads, R5 kv_heads
            var s: []const u8 = header(Params);
            s = s ++ "S2R R0, SR_TID.X\n";
            s = s ++ "S2R R1, SR_CTAID.X\n";
            s = s ++ "S2R R2, SR_CTAID.Y\n";
            s = s ++ "LDCU.64 UR4, c[0x0][0x358]\n";
            s = s ++ "IMAD.SHL.U32 R3, R0, 0x4, RZ\n";
            s = s ++ ln("LDC R4, {s}", .{cb(Params, "heads")});
            s = s ++ ln("LDC R5, {s}", .{cb(Params, "kv_heads")});
            s = s ++ ln("LDC R39, {s}", .{cb(Params, "epsilon")});
            s = s ++ "ISETP.GE.U32.AND P0, PT, R1, R4, PT\n";
            s = s ++ "@P0 BRA `(kv)\n";
            // a query head: row t * heads + h, back in place
            s = s ++ "IMAD R6, R2, R4, R1\n";
            s = s ++ "IMAD R6, R6, 0x200, R3\n";
            s = s ++ ln("LDC.64 R8, {s}", .{cb(Params, "query")});
            s = s ++ "IMAD.WIDE.U32 R8, R6, 0x1, R8\n";
            s = s ++ loadRow();
            s = s ++ ropeLoad();
            s = s ++ ln("LDC.64 R16, {s}", .{cb(Params, "query_norm")});
            s = s ++ norm();
            s = s ++ ropeApply();
            // rounded through f16 (ggml multiplies the keys with an f16 copy)
            s = s ++ "F2FP.F16.F32.PACK_AB R28, R13, R12\n";
            s = s ++ "F2FP.F16.F32.PACK_AB R29, R15, R14\n";
            s = s ++ ln("HADD2.F32 R12, -RZ, {s}", .{halfOf(28, false)});
            s = s ++ ln("HADD2.F32 R13, -RZ, {s}", .{halfOf(28, true)});
            s = s ++ ln("HADD2.F32 R14, -RZ, {s}", .{halfOf(29, false)});
            s = s ++ ln("HADD2.F32 R15, -RZ, {s}", .{halfOf(29, true)});
            for (0..4) |i| s = s ++ ln("STG.E desc[UR4][R8.64{s}], R{d}", .{ off(0x80 * i), 12 + i });
            s = s ++ "EXIT\n";
            s = s ++ "kv:\n";
            s = s ++ "IADD R6, -R4, R1\n";
            s = s ++ "ISETP.GE.U32.AND P1, PT, R6, R5, PT\n";
            s = s ++ "@P1 BRA `(value)\n";
            // a key head (R6): norm, RoPE
            s = s ++ "IMAD R7, R2, R5, R6\n";
            s = s ++ "IMAD R7, R7, 0x200, R3\n";
            s = s ++ ln("LDC.64 R8, {s}", .{cb(Params, "key")});
            s = s ++ "IMAD.WIDE.U32 R8, R7, 0x1, R8\n";
            s = s ++ loadRow();
            s = s ++ ropeLoad();
            s = s ++ ln("LDC.64 R16, {s}", .{cb(Params, "key_norm")});
            s = s ++ norm();
            s = s ++ ropeApply();
            s = s ++ ln("LDC.64 R10, {s}", .{cb(Params, "k_cache")});
            s = s ++ "BRA `(store)\n";
            s = s ++ "value:\n";
            s = s ++ "IADD R6, -R5, R6\n";
            s = s ++ "IMAD R7, R2, R5, R6\n";
            s = s ++ "IMAD R7, R7, 0x200, R3\n";
            s = s ++ ln("LDC.64 R8, {s}", .{cb(Params, "value")});
            s = s ++ "IMAD.WIDE.U32 R8, R7, 0x1, R8\n";
            s = s ++ loadRow();
            s = s ++ ln("LDC.64 R10, {s}", .{cb(Params, "v_cache")});
            // the cache row: + head * head_stride + t * 256, the lane's halves
            s = s ++ "store:\n";
            s = s ++ ln("LDC R7, {s}", .{cb(Params, "head_stride")});
            s = s ++ "IMAD.SHL.U32 R40, R0, 0x2, RZ\n";
            s = s ++ "IMAD R40, R2, 0x100, R40\n";
            s = s ++ "IMAD R40, R6, R7, R40\n";
            s = s ++ "IMAD.WIDE.U32 R10, R40, 0x1, R10\n";
            for (0..4) |i| s = s ++ ln("F2FP.F16.F32.PACK_AB R{d}, RZ, R{d}", .{ 28 + i, 12 + i });
            for (0..4) |i| s = s ++ ln("STG.E.U16 desc[UR4][R10.64{s}], R{d}", .{ off(0x40 * i), 28 + i });
            s = s ++ "EXIT\n";
            return s;
        }
    }

    pub fn launch(heads: u32, kv_heads: u32, tokens: u32) Error!Launch {
        if (heads == 0 or kv_heads == 0 or tokens == 0 or tokens > 0xffff) return error.Unsupported;
        return .{ .grid = .{ heads + 2 * kv_heads, tokens, 1 }, .block = .{ THREADS, 1, 1 } };
    }
};

/// The cosines and sines the prepare kernel rotates by, for `tokens`
/// positions from `first_position`: exactly lfm3_executor.ropeNeox's angles
/// (theta from the position, times base^(-2/d) per lane pair, divided by
/// the optional factors) and its f32 @cos/@sin. out[(t * half + lane) * 2]
/// is the cosine, + 1 the sine.
pub fn ropeTable(out: []f32, first_position: usize, tokens: usize, head_size: usize, base: f32, factors: ?[]const f32) void {
    const half = head_size / 2;
    const exponent = -2.0 / @as(f64, @floatFromInt(head_size));
    const theta_scale: f32 = @floatCast(@exp(exponent * @log(@as(f64, base))));
    for (0..tokens) |t| {
        var theta: f32 = @floatFromInt(first_position + t);
        for (0..half) |lane| {
            const angle = if (factors) |divisors| theta / divisors[lane] else theta;
            out[(t * half + lane) * 2] = @cos(angle);
            out[(t * half + lane) * 2 + 1] = @sin(angle);
            theta *= theta_scale;
        }
    }
}

// ── Attention ───────────────────────────────────────────────────────────────

pub const attention = struct {
    pub const Params = extern struct {
        /// f32 [T][heads][128] (prepared).
        query: u64,
        /// f32 [T][heads]: the output gate's logits.
        gate: u64,
        /// f32 [T][heads][128].
        out: u64,
        /// The layer's key and value blocks, KV head 0 position 0.
        k_cache: u64,
        v_cache: u64,
        head_stride: u32,
        heads: u32,
        /// heads / kv_heads.
        group: u32,
        first_position: u32,
        /// The sliding window's positions, or 0 (all of them).
        window: u32,
        /// log2(e) / sqrt(128): scores come out in base 2.
        scale: f32,
    };

    pub const THREADS = 128;
    /// Positions a CTA's groups take a pass, and a group's threads.
    const GROUPS = 16;
    /// Shared memory (from 0x400): the query, each group's 128 partial
    /// outputs, its maximum and its sum.
    const Q_AT = 0x400;
    const ACC_AT = Q_AT + HEAD_SIZE * 4;
    const MAX_AT = ACC_AT + GROUPS * HEAD_SIZE * 4;
    const SUM_AT = MAX_AT + GROUPS * 4;
    pub const SHARED_BYTES = SUM_AT + GROUPS * 4 - 0x400;

    pub const Shape = struct {
        query: u64,
        gate: u64,
        out: u64,
        cache: KvCache,
        slot: u32,
        heads: u32,
        kv_heads: u32,
        first_position: u32,
        window: u32 = 0,
    };

    pub fn params(a: Shape) Params {
        return .{
            .query = a.query,
            .gate = a.gate,
            .out = a.out,
            .k_cache = a.cache.row(a.slot, false, 0, 0),
            .v_cache = a.cache.row(a.slot, true, 0, 0),
            .head_stride = a.cache.headStride(),
            .heads = a.heads,
            .group = a.heads / @max(a.kv_heads, 1),
            .first_position = a.first_position,
            .window = a.window,
            .scale = LOG2E / @sqrt(@as(f32, HEAD_SIZE)),
        };
    }

    /// The most positions a row of a call reads (its last token's).
    pub fn span(first_position: u32, tokens: u32, window: u32) u64 {
        const end = @as(u64, first_position) + tokens;
        return if (window != 0) @min(end, window) else end;
    }

    pub fn source() []const u8 {
        comptime {
            @setEvalBranchQuota(4_000_000);
            // R0 tid, R1/R2/R3 the CTA (head in group, KV head, token),
            // R4 head, R5 position, R7 first visible, R8 span, R9 passes,
            // R10 query row, R11 its element tid, R16 group g, R17 its
            // thread s, R20:R21 / R22:R23 the group's key / value row,
            // R25 maximum, R26 sum, R27 pass, R28 scale, R40..R55 the
            // query's 16 elements of thread s, R56..R71 a key and a value
            // row's 16 halves, R72..R87 the partial outputs, R88.. scratch.
            var s: []const u8 = header(Params);
            s = s ++ "S2R R0, SR_TID.X\n";
            s = s ++ "S2R R1, SR_CTAID.X\n";
            s = s ++ "S2R R2, SR_CTAID.Y\n";
            s = s ++ "S2R R3, SR_CTAID.Z\n";
            s = s ++ "LDCU.64 UR4, c[0x0][0x358]\n";
            s = s ++ ln("LDC R4, {s}", .{cb(Params, "group")});
            s = s ++ ln("LDC R5, {s}", .{cb(Params, "first_position")});
            s = s ++ ln("LDC R6, {s}", .{cb(Params, "window")});
            s = s ++ ln("LDC R10, {s}", .{cb(Params, "heads")});
            s = s ++ "IMAD R4, R2, R4, R1\n";
            s = s ++ "IADD R5, R5, R3\n";
            // visible = window and pos >= window ? pos - window + 1 : 0
            s = s ++ "ISETP.GE.U32.AND P0, PT, R5, R6, PT\n";
            s = s ++ "ISETP.NE.U32.AND P0, PT, R6, RZ, P0\n";
            s = s ++ "IADD R7, -R6, R5\n";
            s = s ++ "IADD R7, R7, 0x1\n";
            s = s ++ "SEL R7, R7, RZ, P0\n";
            s = s ++ "IADD R8, -R7, R5\n";
            s = s ++ "IADD R8, R8, 0x1\n";
            s = s ++ "IADD R9, R8, 0xf\n";
            s = s ++ "SHF.R.U32.HI R9, RZ, 0x4, R9\n";
            // the query to shared memory
            s = s ++ "IMAD R10, R3, R10, R4\n";
            s = s ++ "IMAD R11, R10, 0x80, R0\n";
            s = s ++ ln("LDC.64 R12, {s}", .{cb(Params, "query")});
            s = s ++ "IMAD.WIDE.U32 R12, R11, 0x4, R12\n";
            s = s ++ "LDG.E R14, desc[UR4][R12.64]\n";
            s = s ++ "IMAD.SHL.U32 R15, R0, 0x4, RZ\n";
            s = s ++ ln("STS [R15+0x{x}], R14", .{Q_AT});
            s = s ++ "SHF.R.U32.HI R16, RZ, 0x3, R0\n";
            s = s ++ "LOP3.LUT R17, R0, 0x7, RZ, 0xc0, !PT\n";
            // the rows: head * head_stride + visible * 256 + s * 32
            s = s ++ ln("LDC R18, {s}", .{cb(Params, "head_stride")});
            s = s ++ "IMAD.SHL.U32 R19, R17, 0x20, RZ\n";
            s = s ++ "IMAD R19, R7, 0x100, R19\n";
            s = s ++ "IMAD R19, R2, R18, R19\n";
            s = s ++ ln("LDC.64 R20, {s}", .{cb(Params, "k_cache")});
            s = s ++ "IMAD.WIDE.U32 R20, R19, 0x1, R20\n";
            s = s ++ ln("LDC.64 R22, {s}", .{cb(Params, "v_cache")});
            s = s ++ "IMAD.WIDE.U32 R22, R19, 0x1, R22\n";
            s = s ++ ln("LDC R28, {s}", .{cb(Params, "scale")});
            s = s ++ "BAR.SYNC.DEFER_BLOCKING 0x0\n";
            s = s ++ "IMAD.SHL.U32 R24, R17, 0x40, RZ\n";
            for (0..4) |i| s = s ++ ln("LDS.128 R{d}, [R24+0x{x}]", .{ 40 + 4 * i, Q_AT + 16 * i });
            s = s ++ "MOV R25, 0xff800000\n"; // (-inf)
            s = s ++ "MOV R26, RZ\n";
            s = s ++ "MOV R27, RZ\n";
            for (0..16) |j| s = s ++ ln("MOV R{d}, RZ", .{72 + j});
            s = s ++ "loop:\n";
            // the group's position this pass; one past the span reads the
            // first visible row instead, and counts for nothing
            s = s ++ "IMAD R29, R27, 0x10, R16\n";
            s = s ++ "ISETP.LT.U32.AND P1, PT, R29, R8, PT\n";
            s = s ++ "SEL R30, R29, RZ, P1\n";
            s = s ++ "IMAD.SHL.U32 R30, R30, 0x100, RZ\n";
            s = s ++ "IMAD.WIDE.U32 R32, R30, 0x1, R20\n";
            s = s ++ "IMAD.WIDE.U32 R34, R30, 0x1, R22\n";
            s = s ++ "LDG.E.128 R56, desc[UR4][R32.64]\n";
            s = s ++ "LDG.E.128 R60, desc[UR4][R32.64+0x10]\n";
            s = s ++ "LDG.E.128 R64, desc[UR4][R34.64]\n";
            s = s ++ "LDG.E.128 R68, desc[UR4][R34.64+0x10]\n";
            // q . k: two chains of 8, then the group's 8 threads
            for (0..16) |j| s = s ++ ln("HADD2.F32 R{d}, -RZ, {s}", .{ 88 + j, halfOf(56 + j / 2, j % 2 == 1) });
            s = s ++ "FMUL R36, R40, R88\n";
            s = s ++ "FMUL R37, R41, R89\n";
            for (2..16) |j| s = s ++ ln("FFMA R{d}, R{d}, R{d}, R{d}", .{ 36 + j % 2, 40 + j, 88 + j, 36 + j % 2 });
            s = s ++ "FADD R36, R36, R37\n";
            for ([_]u32{ 0x1, 0x2, 0x4 }) |m| {
                s = s ++ ln("SHFL.BFLY PT, R37, R36, 0x{x}, 0x1f", .{m});
                s = s ++ "FADD R36, R36, R37\n";
            }
            s = s ++ "FMUL R36, R36, R28\n";
            // the online softmax: m' = max(m, x); c = 2^(m - m'); w = 2^(x - m')
            s = s ++ "FMNMX R37, R25, R36, !PT\n";
            s = s ++ "FSEL R37, R37, R25, P1\n";
            s = s ++ "FADD R38, R25, -R37\n";
            s = s ++ "FADD R39, R36, -R37\n";
            s = s ++ "MUFU.EX2 R38, R38\n";
            s = s ++ "MUFU.EX2 R39, R39\n";
            s = s ++ "FSEL R38, R38, 1, P1\n";
            s = s ++ "FSEL R39, R39, RZ, P1\n";
            s = s ++ "MOV R25, R37\n";
            s = s ++ "FFMA R26, R26, R38, R39\n";
            for (0..16) |j| {
                s = s ++ ln("HADD2.F32 R{d}, -RZ, {s}", .{ 88 + j, halfOf(64 + j / 2, j % 2 == 1) });
                s = s ++ ln("FMUL R{d}, R{d}, R38", .{ 72 + j, 72 + j });
                s = s ++ ln("FFMA R{d}, R39, R{d}, R{d}", .{ 72 + j, 88 + j, 72 + j });
            }
            s = s ++ "IADD R27, R27, 0x1\n";
            s = s ++ "ISETP.LT.U32.AND P0, PT, R27, R9, PT\n";
            s = s ++ "@P0 BRA `(loop)\n";
            // the groups' partials to shared memory
            s = s ++ "IMAD.SHL.U32 R29, R16, 0x200, RZ\n";
            s = s ++ "IMAD R29, R17, 0x40, R29\n";
            for (0..4) |i| s = s ++ ln("STS.128 [R29+0x{x}], R{d}", .{ ACC_AT + 16 * i, 72 + 4 * i });
            s = s ++ "ISETP.EQ.U32.AND P2, PT, R17, RZ, PT\n";
            s = s ++ "IMAD.SHL.U32 R30, R16, 0x4, RZ\n";
            s = s ++ ln("@P2 STS [R30+0x{x}], R25", .{MAX_AT});
            s = s ++ ln("@P2 STS [R30+0x{x}], R26", .{SUM_AT});
            s = s ++ "BAR.SYNC.DEFER_BLOCKING 0x0\n";
            // element tid: M = max of the groups' maxima; out = sum of
            // partial * 2^(m - M) / sum of sum * 2^(m - M), times the gate
            for (0..4) |i| s = s ++ ln("LDS.128 R{d}, [0x{x}]", .{ 40 + 4 * i, MAX_AT + 16 * i });
            for (0..4) |i| s = s ++ ln("LDS.128 R{d}, [0x{x}]", .{ 56 + 4 * i, SUM_AT + 16 * i });
            for (0..GROUPS) |g| s = s ++ ln("LDS R{d}, [R15+0x{x}]", .{ 72 + g, ACC_AT + g * HEAD_SIZE * 4 });
            s = s ++ "FMNMX R24, R40, R41, !PT\n";
            for (2..GROUPS) |g| s = s ++ ln("FMNMX R24, R24, R{d}, !PT", .{40 + g});
            for (0..GROUPS) |g| {
                s = s ++ ln("FADD R{d}, R{d}, -R24", .{ 88 + g, 40 + g });
                s = s ++ ln("MUFU.EX2 R{d}, R{d}", .{ 88 + g, 88 + g });
            }
            s = s ++ "MOV R25, RZ\n";
            s = s ++ "MOV R26, RZ\n";
            for (0..GROUPS) |g| {
                s = s ++ ln("FFMA R25, R{d}, R{d}, R25", .{ 56 + g, 88 + g });
                s = s ++ ln("FFMA R26, R{d}, R{d}, R26", .{ 72 + g, 88 + g });
            }
            s = s ++ "MUFU.RCP R25, R25\n";
            s = s ++ "FMUL R26, R26, R25\n";
            // the gate: 1 / (1 + 2^(-logit log2 e))
            s = s ++ ln("LDC.64 R32, {s}", .{cb(Params, "gate")});
            s = s ++ "IMAD.WIDE.U32 R32, R10, 0x4, R32\n";
            s = s ++ "LDG.E R34, desc[UR4][R32.64]\n";
            s = s ++ "FMUL R34, R34, " ++ MINUS_LOG2E ++ "\n";
            s = s ++ "MUFU.EX2 R34, R34\n";
            s = s ++ "FADD R34, R34, 1\n";
            s = s ++ "MUFU.RCP R34, R34\n";
            s = s ++ "FMUL R26, R26, R34\n";
            s = s ++ ln("LDC.64 R32, {s}", .{cb(Params, "out")});
            s = s ++ "IMAD.WIDE.U32 R32, R11, 0x4, R32\n";
            s = s ++ "STG.E desc[UR4][R32.64], R26\n";
            s = s ++ "EXIT\n";
            return s;
        }
    }

    /// Grid (heads / kv_heads, kv_heads, T). error.LongContext when a row
    /// would read more than MAX_ATTENTION_SPAN positions.
    pub fn launch(heads: u32, kv_heads: u32, tokens: u32, first_position: u32, window: u32) Error!Launch {
        if (heads == 0 or kv_heads == 0 or heads % kv_heads != 0 or tokens == 0) return error.Unsupported;
        if (kv_heads > 0xffff or tokens > 0xffff) return error.Unsupported;
        if (span(first_position, tokens, window) > MAX_ATTENTION_SPAN) return error.LongContext;
        return .{ .grid = .{ heads / kv_heads, kv_heads, tokens }, .block = .{ THREADS, 1, 1 }, .shared_bytes = SHARED_BYTES };
    }
};

// ── Host tests ──────────────────────────────────────────────────────────────
//
// Every kernel runs on nvidia.device's emulated RTX from a pushbuffer, a
// QMD and constant buffer 0 as Galaxy's driver makes them, against
// lfm3_executor's arithmetic. Each is sm120_asm's: the device decodes its
// words (sm120.decode), and the emulator checks the control fields
// sm120_sched worked out at NAK's level (strict), so a hazard fails a test
// as surely as a wrong number.

const testing = std.testing;
const executor = @import("lfm3_executor");
const sm120 = nvidia.sm120;
const sm120_asm = nvidia.sm120_asm;
const emu = nvidia.sm120_emu;
const sched = nvidia.sm120_sched;
const push = nvidia.push;
const device = nvidia.device;

const T = struct {
    var arena: [16 << 20]u8 align(4096) = undefined;
    var gpu_view: [16 << 20]u8 align(4096) = undefined;
    var dev: device.EmuDevice = undefined;
    var work: emu.Work = .{};
    var asm_work: sm120_asm.Work = .{};
    var code: [2 * sm120_asm.MAX_INSTRS]u64 = undefined;
};

/// A fresh emulated RTX whose memory the CPU sees only through toDevice
/// and fromDevice (as VRAM behind BAR1).
fn fresh() device.Device {
    T.dev = .{ .arena = &T.arena, .gpu_view = &T.gpu_view, .work = &T.work, .tpcs = 1 };
    return T.dev.device();
}

const Kernel = struct {
    code: device.Buffer,
    bytes: usize,
    registers: u32,
    params: u32,
};

/// `text` assembled by sm120_asm (its control fields worked out) into a
/// code buffer of its own, handed to the GPU.
fn load(d: device.Device, text: []const u8) !Kernel {
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    try testing.expect(k.scheduled);
    const b = try d.alloc(k.code.len * 8 + 4096);
    @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, b.cpu[0 .. k.code.len * 8]))), k.code);
    d.toDevice(b, 0, b.cpu.len);
    return .{ .code = b, .bytes = k.code.len * 8, .registers = k.registers, .params = k.params };
}

/// One launch as Galaxy's runBatch makes it, run and waited for.
fn run(d: device.Device, k: Kernel, l: Launch, params: anytype) !void {
    const bytes = std.mem.asBytes(params);
    try testing.expectEqual(@as(usize, k.params), bytes.len);
    const slot = try d.alloc(0x800);
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
    try qmd.build(q, .{ .prog_va = k.code.va, .prog_bytes = k.bytes, .cbuf_va = slot.va + 0x200, .registers = k.registers, .grid = l.grid, .block = l.block, .shared_bytes = l.shared_bytes });
    const c0: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0x200..][0..qmd.CBUF0_BYTES]));
    try qmd.cbuf0(c0, l.grid, l.block, bytes);
    d.toDevice(slot, 0, slot.cpu.len);
    const sem = try d.alloc(16);
    const pb = try d.alloc(4096);
    const n = try push.batchPush(pb.words(), &.{slot.va}, null, sem.va, 0x600d);
    T.work.strict = true;
    defer T.work.strict = false;
    d.run(pb, @intCast(n), 1_000_000) catch |e| {
        var buf: [256]u8 = undefined;
        std.debug.print("emulated RTX: {s}: {s}\n", .{ if (T.dev.last_error) |x| @errorName(x) else "-", emu.explain(&T.work, &buf) });
        return e;
    };
    d.fromDevice(sem, 0, 4);
    try testing.expectEqual(@as(u32, 0x600d), sem.words()[0]);
}

fn lcg(seed: *u32) u32 {
    seed.* = seed.* *% 1664525 +% 1013904223;
    return seed.*;
}

fn random(seed: *u32, scale: f32, bias: f32) f32 {
    return (@as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0 - 0.5) * scale + bias;
}

fn f32s(b: device.Buffer) []f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, b.cpu));
}

fn u16s(b: device.Buffer) []u16 {
    return @alignCast(std.mem.bytesAsSlice(u16, b.cpu));
}

/// A buffer of `n` random f32s, handed to the GPU.
fn randomBuffer(d: device.Device, n: usize, seed: *u32, scale: f32, bias: f32) !device.Buffer {
    const b = try d.alloc(n * 4);
    for (f32s(b)) |*x| x.* = random(seed, scale, bias);
    d.toDevice(b, 0, b.cpu.len);
    return b;
}

fn fetch(d: device.Device, b: device.Buffer) void {
    d.fromDevice(b, 0, b.cpu.len);
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

fn widen(h: u16) f32 {
    return @floatCast(@as(f16, @bitCast(h)));
}

fn halfBits(x: f32) u16 {
    return @bitCast(@as(f16, @floatCast(x)));
}

/// f16 bit patterns at most one ulp apart.
fn withinUlp(a: u16, b: u16) bool {
    if (a == b) return true;
    if ((a ^ b) & 0x8000 != 0) return (a | b) & 0x7fff <= 1;
    const d = if (a > b) a - b else b - a;
    return d <= 1;
}

// CPU references: lfm3_executor's arithmetic, step for step (its tasks
// are private; ropeNeox and shortConvChannels are its own).
const ref = struct {
    fn rmsNormRow(input: []const f32, weight: []const f32, output: []f32, epsilon: f32) void {
        var squares: f64 = 0;
        for (input) |value| squares += @as(f64, value) * value;
        const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(input.len)));
        const inverse = 1.0 / @sqrt(mean + epsilon);
        for (input, weight, output[0..input.len]) |value, scale, *destination| destination.* = value * inverse * scale;
    }

    /// dotHalf: eight lane sums, then added in order.
    fn dotHalf(query: []const f32, key: []const u16) f32 {
        var lanes = [_]f32{0} ** 8;
        var i: usize = 0;
        while (i + 8 <= query.len) : (i += 8) {
            for (0..8) |l| lanes[l] += query[i + l] * widen(key[i + l]);
        }
        var total = lanes[0];
        for (1..8) |l| total += lanes[l];
        return total;
    }

    const Attend = struct {
        kv: []const u16,
        cache: KvCache,
        slot: u32,
        heads: u32,
        kv_heads: u32,
        first_position: u32,
        window: u32,
        query: []const f32,
        gate: []const f32,
        output: []f32,
    };

    /// AttentionTask over every (token, head) of `tokens`.
    fn attend(a: Attend, tokens: u32) void {
        var scores: [MAX_ATTENTION_SPAN]f32 = undefined;
        const hd = HEAD_SIZE;
        const width = a.heads * hd;
        const group = a.heads / a.kv_heads;
        const scale = 1.0 / @sqrt(@as(f32, hd));
        const elements_per_block = @as(usize, a.cache.context) * hd;
        for (0..tokens * a.heads) |unit| {
            const slot = unit / a.heads;
            const head = unit % a.heads;
            const kv_head = head / group;
            const position = a.first_position + slot;
            const visible = if (a.window == 0 or position < a.window) 0 else position - a.window + 1;
            const query = a.query[slot * width + head * hd ..][0..hd];
            const keys = a.kv[((a.slot * 2 + 0) * a.cache.max_kv_heads + kv_head) * elements_per_block ..];
            const values = a.kv[((a.slot * 2 + 1) * a.cache.max_kv_heads + kv_head) * elements_per_block ..];
            var maximum: f32 = -std.math.inf(f32);
            for (visible..position + 1) |p| {
                const score = dotHalf(query, keys[p * hd ..][0..hd]) * scale;
                scores[p - visible] = score;
                maximum = @max(maximum, score);
            }
            const length = position + 1 - visible;
            var total: f64 = 0;
            for (scores[0..length]) |*score| {
                score.* = @exp(score.* - maximum);
                total += score.*;
            }
            const inverse: f32 = @floatCast(1.0 / total);
            const destination = a.output[slot * width + head * hd ..][0..hd];
            @memset(destination, 0);
            for (scores[0..length], visible..) |score, p| {
                const weight = widen(halfBits(score * inverse));
                for (destination, values[p * hd ..][0..hd]) |*accumulator, element| accumulator.* += weight * widen(element);
            }
            const g = 1.0 / (1.0 + @exp(-a.gate[slot * a.heads + head]));
            for (destination) |*element| element.* *= g;
        }
    }
};

// ── Residual ──

fn runResidual(comptime postnorm: bool, comptime width: u32, tokens: u32) !void {
    const d = fresh();
    var seed: u32 = 11 + width + @intFromBool(postnorm);
    const hid = try randomBuffer(d, tokens * width, &seed, 4.0, 0);
    const blk = try randomBuffer(d, tokens * width, &seed, 2.0, 0);
    const w = try randomBuffer(d, width, &seed, 0.5, 1.0);
    // (the second row zeros: the norm of nothing is nothing)
    @memset(f32s(blk)[width .. 2 * width], 0);
    d.toDevice(blk, 0, blk.cpu.len);
    const eps: f32 = 1e-5;
    const S = struct {
        var want: [3 * residual.MAX_WIDTH]f32 = undefined;
        var delta: [3 * residual.MAX_WIDTH]f32 = undefined;
    };
    @memcpy(S.delta[0 .. tokens * width], f32s(blk));
    for (0..tokens) |t| {
        const row = S.delta[t * width ..][0..width];
        if (postnorm) ref.rmsNormRow(row, f32s(w), row, eps);
        for (S.want[t * width ..][0..width], f32s(hid)[t * width ..][0..width], row) |*o, h, x| {
            o.* = h;
            o.* += x;
        }
    }
    const k = try load(d, comptime residual.source(postnorm, width));
    try run(d, k, try residual.launch(postnorm, width, tokens), &residual.params(hid.va, blk.va, w.va, width, eps));
    fetch(d, hid);
    for (S.want[0 .. tokens * width], f32s(hid), S.delta[0 .. tokens * width]) |a, b, x| {
        if (!postnorm) {
            try testing.expectEqual(bits(a), bits(b));
        } else if (@abs(a - b) > 1e-5 * @abs(x) + 0x1p-23 * @abs(a)) {
            std.debug.print("residual: {d} want {d}\n", .{ b, a });
            return error.TestUnexpectedResult;
        }
    }
}

test "residual add: the CPU's floats exactly (two widths, three tokens)" {
    try runResidual(false, 1024, 3);
    try runResidual(false, 2048, 3);
}

test "residual add with the sandwich post-norm: warp and CTA sums, within 1e-5 (a zero row too)" {
    try runResidual(true, 1024, 3);
    try runResidual(true, 2048, 3);
}

// ── SwiGLU ──

test "SwiGLU: silu(gate) * up within 1e-5, in place, a last partial CTA, saturated gates" {
    const d = fresh();
    const count = 3 * 1280;
    var seed: u32 = 5;
    const g = try randomBuffer(d, count, &seed, 16.0, 0);
    const u = try randomBuffer(d, count, &seed, 4.0, 0);
    const special = [_]f32{ 0, -0.0, 100, -100, 20, -20, 1e-30, -88 };
    @memcpy(f32s(g)[0..special.len], &special);
    d.toDevice(g, 0, g.cpu.len);
    var want: [count]f32 = undefined;
    for (&want, f32s(g), f32s(u)) |*o, value, scale| o.* = (value / (1.0 + @exp(-value))) * scale;
    const k = try load(d, comptime swiglu.source());
    try run(d, k, try swiglu.launch(count), &swiglu.Params{ .gate = g.va, .up = u.va, .out = g.va, .count = count });
    fetch(d, g);
    // (gates below about -87: 1 / (1 + e^-g) is under f32's normals, which
    // MUFU.RCP flushes, so the GPU's product is -0 where the CPU's is a
    // number under 1e-36)
    for (want, f32s(g)) |a, b| {
        if (@abs(a - b) > 1e-5 * @abs(a) + 1e-36) {
            std.debug.print("swiglu: {d} want {d}\n", .{ b, a });
            return error.TestUnexpectedResult;
        }
    }
}

// ── Short convolution ──

fn runConv(comptime taps: u32, hidden: u32, tokens: u32) !void {
    const d = fresh();
    const hist = taps - 1;
    var seed: u32 = 23 + taps * 7 + tokens;
    const mixed = try randomBuffer(d, tokens * 3 * hidden, &seed, 2.0, 0);
    const tw = try randomBuffer(d, hidden * taps, &seed, 2.0, 0);
    const state = try randomBuffer(d, hist * hidden, &seed, 2.0, 0);
    const out = try d.alloc(tokens * hidden * 4);
    // Channel 3: every input zero and every weight negative, so each
    // product is -0 and only a sum from +0 (the CPU's) gives +0.
    for (0..hist) |r| f32s(state)[r * hidden + 3] = 0;
    for (0..tokens) |t| f32s(mixed)[t * 3 * hidden + 3] = 0;
    for (0..taps) |j| f32s(tw)[3 * taps + j] = -1.5;
    for (0..tokens) |t| f32s(mixed)[t * 3 * hidden + hidden + 3] = 1.0; // (C)
    d.toDevice(mixed, 0, mixed.cpu.len);
    d.toDevice(tw, 0, tw.cpu.len);
    d.toDevice(state, 0, state.cpu.len);
    const S = struct {
        var cpu_state: [8 * 256]f32 = undefined;
        var cpu_out: [8 * 256]f32 = undefined;
    };
    @memcpy(S.cpu_state[0 .. hist * hidden], f32s(state));
    executor.shortConvChannels(taps, hidden, f32s(tw), S.cpu_state[0 .. hist * hidden], f32s(mixed), tokens, S.cpu_out[0 .. tokens * hidden], 0, hidden);
    const k = try load(d, comptime conv.source(taps));
    try run(d, k, try conv.launch(taps, hidden, tokens), &conv.Params{ .mixed = mixed.va, .taps = tw.va, .state = state.va, .out = out.va, .hidden = hidden, .tokens = tokens });
    fetch(d, out);
    fetch(d, state);
    for (S.cpu_out[0 .. tokens * hidden], f32s(out)) |a, b| try testing.expectEqual(bits(a), bits(b));
    for (S.cpu_state[0 .. hist * hidden], f32s(state)) |a, b| try testing.expectEqual(bits(a), bits(b));
    try testing.expectEqual(@as(u32, 0), bits(f32s(out)[3]));
}

test "short convolution, taps 2 to 8: shortConvChannels' floats and state exactly (a partial CTA, one token, a +0 sum)" {
    inline for (conv.MIN_TAPS..conv.MAX_TAPS + 1) |taps| try runConv(taps, 200, 5);
    try runConv(3, 256, 1);
}

// ── Prepare ──

test "ropeTable: lfm3_executor.ropeNeox's angles exactly (with frequency factors and without)" {
    var seed: u32 = 3;
    var factors: [64]f32 = undefined;
    for (&factors) |*f| f.* = random(&seed, 4.0, 3.0);
    var table: [2 * 64 * 2]f32 = undefined;
    for ([_]?[]const f32{ null, &factors }) |fs| {
        ropeTable(&table, 4000, 2, HEAD_SIZE, 1_000_000.0, fs);
        for (0..2) |t| {
            var row: [HEAD_SIZE]f32 = undefined;
            for (&row) |*x| x.* = random(&seed, 2.0, 0);
            var want = row;
            executor.ropeNeox(&want, 1, HEAD_SIZE, 4000 + t, 1_000_000.0, fs);
            for (0..64) |lane| {
                const c = table[(t * 64 + lane) * 2];
                const s = table[(t * 64 + lane) * 2 + 1];
                const lo = row[lane] * c - row[lane + 64] * s;
                const hi = row[lane] * s + row[lane + 64] * c;
                try testing.expectEqual(bits(want[lane]), bits(lo));
                try testing.expectEqual(bits(want[lane + 64]), bits(hi));
            }
        }
    }
}

const PrepareCase = struct {
    heads: u32 = 4,
    kv_heads: u32 = 2,
    max_kv_heads: u32 = 3,
    context: u32 = 40,
    slot: u32 = 1,
    first: u32 = 21,
    tokens: u32 = 3,
    factors: bool = true,
};

const Prepared = struct {
    query: device.Buffer,
    kv: device.Buffer,
    gate: device.Buffer,
    cache: KvCache,
};

/// The CPU's PrepareTask on random rows and a random cache, the GPU's
/// prepare kernel on the same; their results compared. Hands back the GPU's
/// query and cache.
fn runPrepare(d: device.Device, c: PrepareCase, seed: *u32) !Prepared {
    const hd = HEAD_SIZE;
    const qn = c.tokens * c.heads * hd;
    const kn = c.tokens * c.kv_heads * hd;
    const q = try randomBuffer(d, qn, seed, 4.0, 0);
    const kb = try randomBuffer(d, kn, seed, 4.0, 0);
    const vb = try randomBuffer(d, kn, seed, 2.0, 0);
    const qw = try randomBuffer(d, hd, seed, 0.5, 1.0);
    const kw = try randomBuffer(d, hd, seed, 0.5, 1.0);
    const gate = try randomBuffer(d, c.tokens * c.heads, seed, 4.0, 0);
    const factors = try randomBuffer(d, hd / 2, seed, 2.0, 2.0);
    const rope = try d.alloc(c.tokens * 64 * 2 * 4);
    const elements = (c.slot + 1) * 2 * c.max_kv_heads * c.context * hd;
    const kv = try d.alloc(elements * 2);
    for (u16s(kv)) |*e| e.* = halfBits(random(seed, 2.0, 0));
    d.toDevice(kv, 0, kv.cpu.len);
    const cache = KvCache{ .kv = kv.va, .context = c.context, .max_kv_heads = c.max_kv_heads };
    const base: f32 = if (c.factors) 1_000_000.0 else 10_000.0;
    const fs: ?[]const f32 = if (c.factors) f32s(factors) else null;
    ropeTable(f32s(rope), c.first, c.tokens, hd, base, fs);
    d.toDevice(rope, 0, rope.cpu.len);
    // CPU
    const S = struct {
        var cpu_q: [4 * 8 * HEAD_SIZE]f32 = undefined;
        var cpu_k: [4 * 4 * HEAD_SIZE]f32 = undefined;
        var cpu_kv: [2 * 2 * 4 * 320 * HEAD_SIZE]u16 = undefined;
    };
    @memcpy(S.cpu_q[0..qn], f32s(q));
    @memcpy(S.cpu_k[0..kn], f32s(kb));
    @memcpy(S.cpu_kv[0..elements], u16s(kv));
    const eps: f32 = 1e-5;
    const row = struct {
        fn at(cc: PrepareCase, values: bool, head: usize, position: usize) usize {
            return ((((cc.slot * 2 + @as(usize, @intFromBool(values))) * cc.max_kv_heads + head) * cc.context) + position) * HEAD_SIZE;
        }
    }.at;
    for (0..c.tokens) |t| {
        const position = c.first + t;
        const query = S.cpu_q[t * c.heads * hd ..][0 .. c.heads * hd];
        const key = S.cpu_k[t * c.kv_heads * hd ..][0 .. c.kv_heads * hd];
        for (0..c.heads) |h| ref.rmsNormRow(query[h * hd ..][0..hd], f32s(qw), query[h * hd ..][0..hd], eps);
        for (0..c.kv_heads) |h| ref.rmsNormRow(key[h * hd ..][0..hd], f32s(kw), key[h * hd ..][0..hd], eps);
        executor.ropeNeox(query, c.heads, hd, position, base, fs);
        executor.ropeNeox(key, c.kv_heads, hd, position, base, fs);
        for (query) |*e| e.* = widen(halfBits(e.*));
        for (0..c.kv_heads) |h| for (0..hd) |e| {
            S.cpu_kv[row(c, false, h, position) + e] = halfBits(key[h * hd + e]);
            S.cpu_kv[row(c, true, h, position) + e] = halfBits(f32s(vb)[(t * c.kv_heads + h) * hd + e]);
        };
    }
    // GPU
    const k = try load(d, comptime prepare.source());
    const p = prepare.params(.{ .query = q.va, .key = kb.va, .value = vb.va, .query_norm = qw.va, .key_norm = kw.va, .rope = rope.va, .cache = cache, .slot = c.slot, .heads = c.heads, .kv_heads = c.kv_heads, .first_position = c.first, .epsilon = eps });
    try run(d, k, try prepare.launch(c.heads, c.kv_heads, c.tokens), &p);
    fetch(d, q);
    fetch(d, kv);
    // the queries and keys within an f16 ulp (the norm is a float path),
    // the values exactly, nothing else in the cache touched
    var near: usize = 0;
    for (S.cpu_q[0..qn], f32s(q)) |a, b| {
        try testing.expect(withinUlp(halfBits(a), halfBits(b)));
        try testing.expectEqual(bits(b), bits(widen(halfBits(b))));
        near += @intFromBool(bits(a) != bits(b));
    }
    for (S.cpu_kv[0..elements], u16s(kv), 0..) |a, b, i| {
        const in_values = (i / (c.context * hd)) % (2 * c.max_kv_heads) >= c.max_kv_heads;
        if (in_values) try testing.expectEqual(a, b) else try testing.expect(withinUlp(a, b));
        near += @intFromBool(a != b);
    }
    // (an ulp off is rare: the norms agree to about 1e-7)
    try testing.expect(near * 50 < qn + 2 * kn);
    return .{ .query = q, .kv = kv, .gate = gate, .cache = cache };
}

test "attention prepare: q/k head norms, NeoX RoPE (with factors and without), f16 KV rows in the executor's layout" {
    var seed: u32 = 41;
    _ = try runPrepare(fresh(), .{}, &seed);
    _ = try runPrepare(fresh(), .{ .factors = false, .heads = 2, .kv_heads = 1, .max_kv_heads = 1, .slot = 0, .first = 0, .tokens = 1, .context = 4 }, &seed);
}

// ── Attention ──

const AttendCase = struct {
    heads: u32,
    kv_heads: u32,
    max_kv_heads: u32,
    context: u32,
    slot: u32 = 1,
    first: u32,
    tokens: u32,
    window: u32 = 0,
    /// Head 0's query all zeros (equal scores), token 0's gate logits 0.
    zeros: bool = false,
};

fn runAttention(c: AttendCase) !void {
    const d = fresh();
    var seed: u32 = 97 + c.first + c.window;
    const hd = HEAD_SIZE;
    const width = c.heads * hd;
    // the prepared query (f16 values), the gates, a random f16 cache
    const q = try d.alloc(c.tokens * width * 4);
    for (f32s(q)) |*x| x.* = widen(halfBits(random(&seed, 6.0, 0)));
    const gate = try randomBuffer(d, c.tokens * c.heads, &seed, 4.0, 0);
    if (c.zeros) {
        for (0..c.tokens) |t| @memset(f32s(q)[t * width ..][0..hd], 0);
        @memset(f32s(gate)[0..c.heads], 0);
    }
    d.toDevice(q, 0, q.cpu.len);
    d.toDevice(gate, 0, gate.cpu.len);
    const elements = (c.slot + 1) * 2 * c.max_kv_heads * c.context * hd;
    const kv = try d.alloc(elements * 2);
    for (u16s(kv)) |*e| e.* = halfBits(random(&seed, 2.0, 0));
    d.toDevice(kv, 0, kv.cpu.len);
    const out = try d.alloc(c.tokens * width * 4);
    const cache = KvCache{ .kv = kv.va, .context = c.context, .max_kv_heads = c.max_kv_heads };
    try attendAndCompare(d, c, cache, kv, q, gate, out);
}

/// The GPU's attention on `q` and the cache against the CPU's.
fn attendAndCompare(d: device.Device, c: AttendCase, cache: KvCache, kv: device.Buffer, q: device.Buffer, gate: device.Buffer, out: device.Buffer) !void {
    const S = struct {
        var want: [4 * 8 * HEAD_SIZE]f32 = undefined;
    };
    const n = c.tokens * c.heads * HEAD_SIZE;
    ref.attend(.{ .kv = u16s(kv), .cache = cache, .slot = c.slot, .heads = c.heads, .kv_heads = c.kv_heads, .first_position = c.first, .window = c.window, .query = f32s(q), .gate = f32s(gate), .output = S.want[0..n] }, c.tokens);
    const k = try load(d, comptime attention.source());
    const p = attention.params(.{ .query = q.va, .gate = gate.va, .out = out.va, .cache = cache, .slot = c.slot, .heads = c.heads, .kv_heads = c.kv_heads, .first_position = c.first, .window = c.window });
    try run(d, k, try attention.launch(c.heads, c.kv_heads, c.tokens, c.first, c.window), &p);
    fetch(d, out);
    var worst: f64 = 0;
    for (S.want[0..n], f32s(out)) |a, b| worst = @max(worst, @abs(@as(f64, a) - b) / @max(@abs(@as(f64, a)), 0.05));
    if (worst > 5e-3) {
        std.debug.print("attention: worst relative error {e}\n", .{worst});
        return error.TestUnexpectedResult;
    }
}

test "attention: grouped heads over spans of 291 to 293 positions, online softmax within 5e-3 of the CPU's" {
    try runAttention(.{ .heads = 4, .kv_heads = 2, .max_kv_heads = 2, .context = 300, .first = 290, .tokens = 3 });
}

test "attention: the sliding window's boundary (positions 62 to 65 of a 64 window), one KV head for two" {
    try runAttention(.{ .heads = 2, .kv_heads = 1, .max_kv_heads = 2, .context = 80, .first = 62, .tokens = 4, .window = 64 });
}

test "attention: a span of one position, a group of one; zero queries and gates" {
    try runAttention(.{ .heads = 2, .kv_heads = 2, .max_kv_heads = 2, .context = 8, .slot = 0, .first = 0, .tokens = 1 });
    try runAttention(.{ .heads = 2, .kv_heads = 1, .max_kv_heads = 1, .context = 40, .first = 17, .tokens = 2, .zeros = true });
}

test "attention after prepare, as a layer runs them: the GPU's own query and cache rows" {
    const d = fresh();
    var seed: u32 = 77;
    const c = PrepareCase{ .heads = 4, .kv_heads = 2, .max_kv_heads = 2, .context = 64, .slot = 1, .first = 37, .tokens = 3 };
    const p = try runPrepare(d, c, &seed);
    const out = try d.alloc(c.tokens * c.heads * HEAD_SIZE * 4);
    try attendAndCompare(d, .{ .heads = c.heads, .kv_heads = c.kv_heads, .max_kv_heads = c.max_kv_heads, .context = c.context, .slot = c.slot, .first = c.first, .tokens = c.tokens }, p.cache, p.kv, p.query, p.gate, out);
}

// ── Shapes ──

test "launch shapes: grids, blocks, shared bytes; the span limit; shapes the kernels do not do" {
    const a = try attention.launch(32, 8, 3, 100, 0);
    try testing.expectEqual([3]u32{ 4, 8, 3 }, a.grid);
    try testing.expectEqual([3]u32{ 128, 1, 1 }, a.block);
    try testing.expectEqual(@as(u32, 8832), a.shared_bytes);
    try testing.expectEqual(@as(u32, 0x2680), try qmd.sharedTotal(a.shared_bytes));
    _ = try attention.launch(4, 2, 1, MAX_ATTENTION_SPAN - 1, 0);
    try testing.expectError(error.LongContext, attention.launch(4, 2, 1, MAX_ATTENTION_SPAN, 0));
    try testing.expectError(error.LongContext, attention.launch(4, 2, 2, MAX_ATTENTION_SPAN - 1, 0));
    _ = try attention.launch(4, 2, 64, 1_000_000, 512); // (a sliding layer reads its window only)
    try testing.expectError(error.Unsupported, attention.launch(6, 4, 1, 0, 0));
    try testing.expectError(error.Unsupported, attention.launch(4, 2, 0, 0, 0));
    try testing.expectEqual(@as(u64, 4096), attention.span(4000, 96, 0));
    try testing.expectEqual(@as(u64, 512), attention.span(4000, 96, 512));
    const p = try prepare.launch(32, 8, 5);
    try testing.expectEqual([3]u32{ 48, 5, 1 }, p.grid);
    try testing.expectEqual([3]u32{ 32, 1, 1 }, p.block);
    const r = try residual.launch(true, 2048, 7);
    try testing.expectEqual([3]u32{ 7, 1, 1 }, r.grid);
    try testing.expectEqual(@as(u32, 32), r.shared_bytes);
    try testing.expectEqual(@as(u32, 0), (try residual.launch(false, 2048, 7)).shared_bytes);
    try testing.expectError(error.Unsupported, residual.launch(true, 1000, 1));
    try testing.expectError(error.Unsupported, residual.launch(false, 2048, 0));
    try testing.expectEqual([3]u32{ 30, 1, 1 }, (try swiglu.launch(4 * 7680)).grid);
    try testing.expectError(error.Unsupported, swiglu.launch(6));
    try testing.expectEqual([3]u32{ 16, 1, 1 }, (try conv.launch(3, 2048, 64)).grid);
    try testing.expectError(error.Unsupported, conv.launch(9, 2048, 1));
    try testing.expectError(error.Unsupported, conv.launch(3, 2048, 0));
    // the cache's addresses: lfm3_executor's element offsets, in bytes
    const c = KvCache{ .kv = 0x10_0000_0000, .context = 4096, .max_kv_heads = 8 };
    try testing.expectEqual(@as(u32, 4096 * 256), c.headStride());
    try testing.expectEqual(c.kv + ((((3 * 2 + 1) * 8 + 5) * 4096) + 77) * 256, c.row(3, true, 5, 77));
    // parameters as the kernels read them (their .params headers)
    try testing.expectEqual(@as(usize, 32), @sizeOf(residual.Params));
    try testing.expectEqual(@as(usize, 32), @sizeOf(swiglu.Params));
    try testing.expectEqual(@as(usize, 40), @sizeOf(conv.Params));
    try testing.expectEqual(@as(usize, 80), @sizeOf(prepare.Params));
    try testing.expectEqual(@as(usize, 64), @sizeOf(attention.Params));
}

/// A variant's text: the emulator runs every form in it; sm120_asm
/// assembles it, its schedule leaving nothing open by sm120_sched's own
/// check; and every word decodes and prints back as the line it came from
/// (a branch's label as its address).
fn checkText(text: []const u8) !void {
    try emu.loadText(&T.work, text);
    for (T.work.ops[0..T.work.n_ops]) |op| try testing.expect(op.kind != .unsupported and op.kind != .invalid);
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    try testing.expect(k.scheduled);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0 or t[0] == '.' or t[t.len - 1] == ':') continue;
        const slot: usize = @intCast(T.asm_work.at[n] / 16);
        const d = try sm120.decode(k.code[2 * slot], k.code[2 * slot + 1], slot * 16);
        var buf: [160]u8 = undefined;
        const printed = try sm120.format(&d, &buf);
        // (after the control field: "[B------:R-:W-:-:S01] ")
        if (T.asm_work.instrs[n].label() == null) try testing.expectEqualStrings(t, printed[22..]);
        n += 1;
    }
    const rep = try sched.check(T.asm_work.instrs[0..n], T.asm_work.slots[0..n], &T.asm_work.sched);
    try testing.expectEqual(@as(u32, 0), rep.open);
}

test "every kernel's text: forms the emulator runs, assembled by sm120_asm, decoded back to its lines" {
    inline for (.{ 1024, 2048, 4096, 8192 }) |w| {
        try checkText(comptime residual.source(false, w));
        try checkText(comptime residual.source(true, w));
    }
    try checkText(comptime swiglu.source());
    inline for (conv.MIN_TAPS..conv.MAX_TAPS + 1) |taps| try checkText(comptime conv.source(taps));
    try checkText(comptime prepare.source());
    try checkText(comptime attention.source());
}
