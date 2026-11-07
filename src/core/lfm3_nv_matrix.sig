//! @zpm/lfm3-nv-matrix — LFM3's quantized matrix products and activation
//! quantization on NVIDIA's sm_120 (the Legion 5's RTX 5070 Laptop GPU), as
//! sm_120 assembly text for sm120_asm, and how each is launched. The twin
//! of lfm3_gpu_kernels.sig's Adreno kernels, with the CPU's numerics
//! (quantized_linear.sig) to the bit.
//!
//! # The kernels
//!
//! | text                      | computes                                     | params            |
//! |---------------------------|----------------------------------------------|-------------------|
//! | `q4kMatrix(tokens)`       | out[t][row] = Q4_K row . Q8_K activations t  | MatrixParams      |
//! | `q6kMatrix(tokens)`       | out[t][row] = Q6_K row . Q8_K activations t  | MatrixParams      |
//! | `q80Matrix(tokens)`       | out[t][row] = Q8_0 row . Q8_0 activations t  | MatrixParams      |
//! | `q8kQuant(false, 1)`      | rows of f32 to Q8_K (quantizeQ8K)            | QuantParams       |
//! | `q8kQuant(true, waves)`   | RMSNorm, the normalized rows out, then Q8_K  | QuantParams       |
//! | `q80Quant()`              | rows of f32 to Q8_0 (quantizeQ80)            | Q80QuantParams    |
//!
//! `tokens` is 1 (decode: a matrix-vector product) to MAX_TOKENS (prefill:
//! one pass over the weights for up to eight tokens). Each text starts with
//! `.params N` and has no control fields: sm120_asm works them out. Each
//! kernel's parameters are an `extern struct` the launch copies into
//! constant buffer 0 from 0x380 (qmd.cbuf0); `matrixLaunch`, `quantLaunch`
//! and `q80QuantLaunch` give the grid, the block and the kernel's own shared
//! bytes (qmd.Shape.shared_bytes: the reserved 1 KiB comes on top).
//!
//! # Data in memory (all little-endian, GPU virtual addresses)
//!
//! - Weights: GGUF's rows as the file has them, `row_bytes` apart, rows
//!   16-byte aligned (GGUF's 32-byte tensor alignment and these widths give
//!   that): Q4_K blocks of 144 bytes, Q6_K of 210, Q8_0 of 34. Q6_K needs
//!   whole groups of 8 blocks a row (K a multiple of 2048, LFM3's widths):
//!   then every eighth block is 16-byte aligned and the kernel knows each
//!   block's offset from it. The weight buffer must be readable 16 bytes
//!   past its last row (the Q8_0 kernel reads whole 16-byte lines).
//! - Q8_K activations (Q4_K, Q6_K): three arrays, token after token, as the
//!   Adreno kernels have them: `act_q` the i8 values (K a token), `act_d`
//!   one f32 scale a 256-lane block (K / 256 a token), `act_sums` the
//!   sixteen i16 sums of 16 a block (K / 16 a token).
//! - Q8_0 activations: `act_q` (K a token) and `act_d` (one f32 a 32-lane
//!   block: the f16-rounded scale as f32, quantized_linear's Q80Block.d).
//! - Results: f32, `out + t * out_stride + row * 4`.
//! - Quantization input: f32 rows of K, token after token (`x + t * K * 4`);
//!   RMSNorm's weights K f32; the normalized rows written like x.
//! - Every buffer starts 16-byte aligned (the kernels move activations,
//!   rows of f32 and RMSNorm's weights in 16-byte loads and stores).
//!
//! # Numerics
//!
//! The matrix kernels keep quantized_linear's eight f32 lanes per row: lane
//! l holds elements 4l..4l+3 of every 32 of a block, its integer dot (IDP.4A,
//! exact) gets the block's float epilogue in the CPU's order and is added to
//! that lane's sum block after block, and the lanes are added at the end as
//! the CPU adds them (in order for Q4_K and Q6_K, GGML's AVX pairs for
//! Q8_0). The GPU's FFMA is fused like the CPU's @mulAdd, so Q8_0 is
//! bit-exact too. Divisions (quantizeQ8K's -127 / max and 1 / inverse,
//! quantizeQ80's amax / 127 and 127 / amax) are ptxas's div.rn fast path
//! (MUFU.RCP, a Newton step, one remainder correction): IEEE-rounded for
//! normal operands with exponents well inside f32's range (FCHK's fast-path
//! domain), which activations are. Rounding to integers is the CPU's
//! (x + 1.5 * 2^23). RMSNorm sums squares in f32 (the CPU in f64) and takes
//! MUFU.RSQ: a float path within 2e-6; the quantization after it is exact
//! for the values it writes out.
//!
//! # Launch shapes
//!
//! - Matrices: CTAs of 64 threads (two warps) for 32 rows, two threads a
//!   row (thread h has the CPU's lanes 4h..4h+3), grid ceil(rows / 32). A
//!   last CTA past `rows` reads the last row and stores nothing. The
//!   activations go through shared memory a tile of 2048 columns at a time
//!   (2336 bytes a token for Q8_K, 2304 for Q8_0).
//! - Q8_K quantization: a warp a 256-lane block, 8 values a lane; without
//!   the norm CTAs of 4 warps, grid (ceil(blocks / 4), tokens); with it a
//!   CTA a row of `waves` = K / 256 warps (up to 32), grid (1, tokens).
//! - Q8_0 quantization: 8 lanes a 32-lane block, CTAs of 256 threads (32
//!   blocks), grid (ceil(blocks / 32), tokens).
//!
//! # The RTX's bandwidth
//!
//! Decode reads every weight once; activations come from L2 (all CTAs read
//! the same ones). A row is two threads, so each weight load is a 16-byte
//! LDG.E.128.CONSTANT and the two threads of a row read 32 contiguous bytes
//! a load (full sectors), 16 rows a warp: a warp has 16 x 144 = 2.3 KiB of
//! Q4_K weights in flight a block. Weights a token a row: K * 144 / 256
//! bytes for Q4_K (0.56 B a column), K * 210 / 256 for Q6_K (0.82), K * 34
//! / 32 for Q8_0 (1.06), plus the CTA's activation tile from L2 (2.3 KiB a
//! token for 32 rows, about 6 % of the Q4_K weights at K = 2048).
//!
//! Issue, a thread a block for one token: Q4_K about 190 instructions (72
//! weight bytes: 2.6 a byte) and about 120 more a token, Q6_K about 280
//! (105 bytes) and 120 more a token, Q8_0 about 50 (17 bytes) and 15 more a
//! token. At 300 GB/s one token is under a fifth of the SMs' issue rate;
//! eight tokens (prefill) come near it, so a pass of eight costs about one
//! pass of the weights. Kernel sizes (sm120_asm's count) and registers:
//! Q4_K 275 instructions and 150 registers for one token, 1297 and 178 for
//! eight; Q6_K 1424 and 158, 2439 and 186 (its eight blocks' loads written
//! out); Q8_0 119 and 94, 427 and 122; the quantizations under 260 and 51.
//! At 150 to 186 registers an SM holds 11 to 13 warps, 25 KiB or more of
//! weights in flight, well over what 300 GB/s needs (about 5 KiB an SM at
//! 600 ns). A row's blocks are summed in order, so a row is serial over
//! its blocks: a small matrix (512 rows of LFM3's KV projections) runs at
//! the latency of its K / 256 loads one after another, a few microseconds.
//!
//! Allocation-free: the texts are comptime constants, the launch helpers
//! return values.

const std = @import("std");

pub const QK_K = 256;
pub const Q4_K_BLOCK = 144;
pub const Q6_K_BLOCK = 210;
pub const QK8_0 = 32;
pub const Q8_0_BLOCK = 34;
pub const MAX_TOKENS = 8;
/// Rows a matrix CTA (64 threads: two a row).
pub const ROWS_PER_CTA = 32;
pub const MATRIX_THREADS = 64;
/// Columns of activations a matrix CTA stages in shared memory at a time.
pub const TILE_COLUMNS = 2048;
/// Shared bytes a token of a tile: Q8_K's values, sums and scales; Q8_0's
/// values and scales.
pub const Q8K_TILE_BYTES = TILE_COLUMNS + TILE_COLUMNS / 16 * 2 + TILE_COLUMNS / QK_K * 4;
pub const Q80_TILE_BYTES = TILE_COLUMNS + TILE_COLUMNS / QK8_0 * 4;
/// Q8_K quantization with RMSNorm: a CTA a row, a warp a 256-lane block.
pub const MAX_NORM_WAVES = 32;
pub const QUANT_WARPS = 4;
pub const Q80_QUANT_THREADS = 256;

pub const Error = error{
    /// A shape the kernels do not take: no rows or tokens, more than
    /// MAX_TOKENS, K not in whole blocks, Q6_K rows not in groups of 8
    /// blocks, a norm row over MAX_NORM_WAVES blocks.
    Unsupported,
};

// ── Parameters (constant buffer 0 from 0x380) ───────────────────────────────

/// The matrix kernels' parameters. `act_sums` is not read by the Q8_0
/// kernel. `out_stride`: bytes from token t's results to t + 1's (rows * 4
/// for a dense [tokens][rows] array).
pub const MatrixParams = extern struct {
    weights: u64, // 0x380
    act_q: u64, // 0x388
    act_d: u64, // 0x390
    act_sums: u64 = 0, // 0x398
    out: u64, // 0x3a0
    row_bytes: u32, // 0x3a8
    blocks: u32, // 0x3ac
    rows: u32, // 0x3b0
    out_stride: u32, // 0x3b4
};

/// Q8_K quantization's parameters. Without the norm only x, the three
/// activation arrays and k are read. `inv_k` is 1 / k (the mean of the
/// squares is their sum times it).
pub const QuantParams = extern struct {
    x: u64, // 0x380
    norm_weight: u64 = 0, // 0x388
    normalized: u64 = 0, // 0x390
    act_q: u64, // 0x398
    act_d: u64, // 0x3a0
    act_sums: u64, // 0x3a8
    k: u32, // 0x3b0
    epsilon: f32 = 0, // 0x3b4
    inv_k: f32 = 0, // 0x3b8
    _pad: u32 = 0,

    pub fn of(x: u64, act_q: u64, act_d: u64, act_sums: u64, k: u32) QuantParams {
        return .{ .x = x, .act_q = act_q, .act_d = act_d, .act_sums = act_sums, .k = k, .inv_k = 1.0 / @as(f32, @floatFromInt(k)) };
    }
};

pub const Q80QuantParams = extern struct {
    x: u64, // 0x380
    act_q: u64, // 0x388
    act_d: u64, // 0x390
    k: u32, // 0x398
    _pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(MatrixParams) == 0x38);
    std.debug.assert(@sizeOf(QuantParams) == 0x40);
    std.debug.assert(@sizeOf(Q80QuantParams) == 0x20);
}

// ── Launches ────────────────────────────────────────────────────────────────

/// A launch: the grid, the block, and the kernel's own shared bytes (after
/// the reserved 1 KiB: qmd.Shape.shared_bytes).
pub const Shape = struct {
    grid: [3]u32,
    block: [3]u32,
    shared: u32 = 0,
};

pub const Format = enum { q4_k, q6_k, q8_0 };

/// The matrix kernel for `tokens` tokens of a `rows` x `blocks` matrix.
pub fn matrixLaunch(format: Format, tokens: u32, rows: u32, blocks: u32) Error!Shape {
    if (tokens == 0 or tokens > MAX_TOKENS or rows == 0 or blocks == 0) return error.Unsupported;
    if (format == .q6_k and blocks % 8 != 0) return error.Unsupported;
    const per_token: u32 = if (format == .q8_0) Q80_TILE_BYTES else Q8K_TILE_BYTES;
    return .{
        .grid = .{ (rows + ROWS_PER_CTA - 1) / ROWS_PER_CTA, 1, 1 },
        .block = .{ MATRIX_THREADS, 1, 1 },
        .shared = tokens * per_token,
    };
}

/// Q8_K quantization of `tokens` rows of `k` (with the norm: the text is
/// q8kQuant(true, k / 256)).
pub fn quantLaunch(norm: bool, tokens: u32, k: u32) Error!Shape {
    if (tokens == 0 or k == 0 or k % QK_K != 0) return error.Unsupported;
    const blocks = k / QK_K;
    if (norm) {
        if (blocks > MAX_NORM_WAVES) return error.Unsupported;
        return .{ .grid = .{ 1, tokens, 1 }, .block = .{ 32 * blocks, 1, 1 }, .shared = 4 * MAX_NORM_WAVES };
    }
    return .{ .grid = .{ (blocks + QUANT_WARPS - 1) / QUANT_WARPS, tokens, 1 }, .block = .{ 32 * QUANT_WARPS, 1, 1 } };
}

pub fn q80QuantLaunch(tokens: u32, k: u32) Error!Shape {
    if (tokens == 0 or k == 0 or k % QK8_0 != 0) return error.Unsupported;
    const per_cta = Q80_QUANT_THREADS / 8;
    return .{ .grid = .{ (k / QK8_0 + per_cta - 1) / per_cta, tokens, 1 }, .block = .{ Q80_QUANT_THREADS, 1, 1 } };
}

// ── Writing kernels at comptime ─────────────────────────────────────────────

/// A kernel's text, built line by line at comptime (into a buffer: a few
/// thousand lines concatenated one by one would cost quadratic time).
const Text = struct {
    buf: [256 * 1024]u8 = undefined,
    len: usize = 0,
    labels: usize = 0,

    /// A line, with an address's zero offset left out as nvdisasm prints
    /// it ([R17+0x0] is [R17]).
    fn put(t: *Text, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.comptimePrint(fmt ++ "\n", args);
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (std.mem.startsWith(u8, s[i..], "+0x0]")) i += 4;
            t.buf[t.len] = s[i];
            t.len += 1;
        }
    }

    fn done(comptime t: *const Text) []const u8 {
        const out = t.buf[0..t.len].*;
        return &out;
    }
};

/// LOP3's truth tables (a = 0xf0, b = 0xcc, c = 0xaa).
const AND = 0xc0;
const OR = 0xfc;
/// (a & b) | c
const AND_OR = 0xea;
/// PRMT selectors: byte k zero-extended (b = RZ), sign-extended.
fn zext(comptime k: u32) u32 {
    return 0x4440 | k;
}
fn sext(comptime k: u32) u32 {
    const sel = [4]u32{ 0x8880, 0x9991, 0xaaa2, 0xbbb3 };
    return sel[k];
}

// ── The matrix kernels ──────────────────────────────────────────────────────
//
// One skeleton, three block bodies. Thread tid of a CTA: row ctaid * 32 +
// tid / 2, h = tid & 1 (the CPU's lanes 4h..4h+3). The row loop goes over
// tiles of 2048 columns: the CTA copies the tile's activations of every
// token to shared memory (BAR), each thread runs the tile's blocks, BAR.
// At the end the two threads of a row add their lanes (SHFL) and h = 0
// stores.
//
// Shared memory from 0x400: token t's values at 2048 t (a block's at
// 256 i, or 32 i for Q8_0); Q8_K's sums at 2048 T + 256 t (32 i); the
// scales at 2048 T (+ 256 T for Q8_K) + (32 or 256) t (4 i).

/// Registers every matrix kernel has.
const M = struct {
    const TID = 0;
    const TID4 = 1;
    const CTA = 2;
    const H = 3;
    /// weights, then out (64 bits)
    const WB = 4;
    const RB = 6; // row bytes, then out_stride
    const NBLK = 7; // blocks
    const ROWS = 8;
    const ROW = 9;
    /// the row's (or the tile's) weights, and + 16 h (64 bits each)
    const WP = 10;
    const WH = 12;
    const TB = 14; // the tile's first block
    const NB = 15; // its blocks
    const I = 16; // the block in the tile
    const SA = 17; // shared: this block's values (+ 16 h)
    const SB = 18; // its sums (+ 16 h)
    const SD = 19; // its scale
    const KB = 20; // a token's value bytes (K)
    const TID16 = 21;
    const AQ = 22; // act_q, act_sums, act_d (64 bits each)
    const AS = 24;
    const AD = 26;
    const X0 = 28;
    const X1 = 29;
    const XA = 30; // (64 bits)
    const H16 = 32;
    const SELE = 33; // Q6_K: PRMT selectors of byte h, 2 + h, sign-extended
    const SELO = 34;
};

const Kind = enum { q4_k, q6_k, q8_0 };

/// Per-kind constants: blocks a tile, a block's columns, the copy's temp
/// registers, the first lane sum register.
fn Layout(comptime kind: Kind, comptime tokens: u32) type {
    return struct {
        const q8k = kind != .q8_0;
        const tile_blocks: u32 = if (q8k) TILE_COLUMNS / QK_K else TILE_COLUMNS / QK8_0;
        const block_cols: u32 = if (q8k) QK_K else QK8_0;
        /// shared offsets (from 0)
        const aq: u32 = 0x400;
        const bs: u32 = 0x400 + TILE_COLUMNS * tokens;
        const ad: u32 = 0x400 + TILE_COLUMNS * tokens + (if (q8k) 256 * tokens else 0);
        const ad_token: u32 = if (q8k) 4 * (TILE_COLUMNS / QK_K) else 4 * (TILE_COLUMNS / QK8_0);
        /// registers free during the copy (quads: 4-aligned)
        const ct: u32 = switch (kind) {
            .q4_k => 88,
            .q6_k => 96,
            .q8_0 => 44,
        };
        const ct_quads: u32 = switch (kind) {
            .q4_k => 8,
            .q6_k => 14,
            .q8_0 => 7,
        };
        /// lane sums S[t][j]
        const s: u32 = switch (kind) {
            .q4_k => 144,
            .q6_k => 152,
            .q8_0 => 88,
        };
    };
}

fn sumReg(comptime L: type, comptime t: u32, comptime j: u32) u32 {
    return L.s + 4 * t + j;
}

fn matrixKernel(comptime kind: Kind, comptime tokens: u32) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000_000);
        if (tokens < 1 or tokens > MAX_TOKENS) @compileError("tokens: 1 to MAX_TOKENS");
        const L = Layout(kind, tokens);
        var t = Text{};
        t.put("// lfm3 {s} x {s}, {d} token(s): out[t][row] = row . activations[t]", .{ @tagName(kind), if (kind == .q8_0) "q8_0" else "q8_k", tokens });
        t.put(".params {d}", .{@sizeOf(MatrixParams)});
        prologue(&t, kind, tokens, L);
        t.put("tile:", .{});
        tileCopy(&t, tokens, L);
        switch (kind) {
            .q4_k => q4kBlocks(&t, tokens, L),
            .q6_k => q6kBlocks(&t, tokens, L),
            .q8_0 => q80Blocks(&t, tokens, L),
        }
        t.put("BAR.SYNC.DEFER_BLOCKING 0x0", .{});
        t.put("IADD R{d}, R{d}, 0x{x}", .{ M.TB, M.TB, L.tile_blocks });
        if (kind == .q6_k) {
            // (Q6_K's pointers are a tile's: 8 blocks of 210 bytes on)
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WP, M.WP, 8 * Q6_K_BLOCK });
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WH, M.WH, 8 * Q6_K_BLOCK });
        }
        t.put("ISETP.LT.U32.AND P0, PT, R{d}, R{d}, PT", .{ M.TB, M.NBLK });
        t.put("@P0 BRA `(tile)", .{});
        epilogue(&t, kind, tokens, L);
        return t.done();
    }
}

/// tid, the row, its weights; the sums zeroed.
fn prologue(t: *Text, comptime kind: Kind, comptime tokens: u32, comptime L: type) void {
    t.put("S2R R{d}, SR_TID.X", .{M.TID});
    t.put("S2R R{d}, SR_CTAID.X", .{M.CTA});
    t.put("LDCU.64 UR4, c[0x0][0x358]", .{});
    t.put("LDC.64 R{d}, c[0x0][0x380]", .{M.WB});
    t.put("LDC.64 R{d}, c[0x0][0x388]", .{M.AQ});
    t.put("LDC.64 R{d}, c[0x0][0x390]", .{M.AD});
    if (kind != .q8_0) t.put("LDC.64 R{d}, c[0x0][0x398]", .{M.AS});
    t.put("LDC R{d}, c[0x0][0x3a8]", .{M.RB});
    t.put("LDC R{d}, c[0x0][0x3ac]", .{M.NBLK});
    t.put("LDC R{d}, c[0x0][0x3b0]", .{M.ROWS});
    t.put("LOP3.LUT R{d}, R{d}, 0x1, RZ, 0x{x}, !PT", .{ M.H, M.TID, AND });
    t.put("ISETP.NE.AND P2, PT, R{d}, RZ, PT", .{M.H});
    t.put("SHF.R.U32.HI R{d}, RZ, 0x1, R{d}", .{ M.ROW, M.TID });
    t.put("LEA R{d}, R{d}, R{d}, 0x5", .{ M.ROW, M.CTA, M.ROW });
    // (a row past the last reads the last)
    t.put("IADD R{d}, R{d}, -0x1", .{ M.X0, M.ROWS });
    t.put("VIMNMX.U32 R{d}, R{d}, R{d}, PT", .{ M.X0, M.ROW, M.X0 });
    t.put("IMAD.WIDE.U32 R{d}, R{d}, R{d}, R{d}", .{ M.WP, M.X0, M.RB, M.WB });
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x10, RZ", .{ M.H16, M.H });
    if (kind == .q8_0) {
        // WH: this thread's quants (+ 2 + 16 h); WP: the block's scale
        t.put("IADD R{d}, R{d}, 0x2", .{ M.X0, M.H16 });
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ M.WH, M.X0, M.WP });
    } else {
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ M.WH, M.H16, M.WP });
    }
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x{x}, RZ", .{ M.KB, M.NBLK, L.block_cols });
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x10, RZ", .{ M.TID16, M.TID });
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x4, RZ", .{ M.TID4, M.TID });
    if (kind == .q6_k) {
        t.put("MOV R{d}, 0x{x}", .{ M.SELE, sext(0) });
        t.put("IMAD R{d}, R{d}, 0x1111, R{d}", .{ M.SELE, M.H, M.SELE });
        t.put("MOV R{d}, 0x{x}", .{ M.SELO, sext(2) });
        t.put("IMAD R{d}, R{d}, 0x1111, R{d}", .{ M.SELO, M.H, M.SELO });
    }
    t.put("MOV R{d}, RZ", .{M.TB});
    for (0..tokens) |tok| {
        for (0..4) |j| t.put("MOV R{d}, RZ", .{sumReg(L, tok, j)});
    }
}

/// One copy into shared memory: a 16-byte line (or a word), from
/// `base64 + off` (off a register) to [reg + soff].
const Copy = struct { quad: bool, pred: u32, off: u32, goff: u32, sreg: u32, soff: u32 };

/// The tile's activations of every token to shared memory, then BAR.
fn tileCopy(t: *Text, comptime tokens: u32, comptime L: type) void {
    t.put("IADD R{d}, R{d}, -R{d}", .{ M.NB, M.NBLK, M.TB });
    t.put("VIMNMX.U32 R{d}, R{d}, 0x{x}, PT", .{ M.NB, M.NB, L.tile_blocks });
    // P3, P4: value lines tid, tid + 64 within the tile's nb blocks; P5: a
    // sums line; P6: a scale word
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x{x}, RZ", .{ M.X0, M.NB, L.block_cols });
    t.put("ISETP.LT.U32.AND P3, PT, R{d}, R{d}, PT", .{ M.TID16, M.X0 });
    t.put("IADD R{d}, R{d}, 0x400", .{ M.X1, M.TID16 });
    t.put("ISETP.LT.U32.AND P4, PT, R{d}, R{d}, PT", .{ M.X1, M.X0 });
    if (L.q8k) {
        t.put("IMAD.SHL.U32 R{d}, R{d}, 0x20, RZ", .{ M.X0, M.NB });
        t.put("ISETP.LT.U32.AND P5, PT, R{d}, R{d}, PT", .{ M.TID16, M.X0 });
    }
    t.put("ISETP.LT.U32.AND P6, PT, R{d}, R{d}, PT", .{ M.TID, M.NB });
    // The copies, in batches of the free quads: all loads, then all stores.
    var items: [4 * MAX_TOKENS]struct { what: u8, tok: u32 } = undefined;
    var n: usize = 0;
    for (0..tokens) |tok| {
        items[n] = .{ .what = 'q', .tok = tok };
        n += 1;
        if (L.q8k) {
            items[n] = .{ .what = 's', .tok = tok };
            n += 1;
        }
        items[n] = .{ .what = 'd', .tok = tok };
        n += 1;
    }
    var first: usize = 0;
    while (first < n) {
        // quads this batch: values take two, sums and scales one
        var quads: u32 = 0;
        var last = first;
        while (last < n) {
            const need: u32 = if (items[last].what == 'q') 2 else 1;
            if (quads + need > L.ct_quads) break;
            quads += need;
            last += 1;
        }
        var q: u32 = 0;
        var dst: [4 * MAX_TOKENS]u32 = undefined;
        for (first..last) |k| {
            const it = items[k];
            dst[k] = L.ct + 4 * q;
            q += if (it.what == 'q') 2 else 1;
            const tok = it.tok;
            switch (it.what) {
                'q' => {
                    // act_q + t * K + tb * cols + 16 tid (and + 0x400)
                    t.put("IMAD R{d}, R{d}, 0x{x}, R{d}", .{ M.X0, M.TB, L.block_cols, M.TID16 });
                    // (a multiplier of 1 is nvdisasm's IMAD.IADD: the same word)
                    if (tok == 1) t.put("IMAD.IADD R{d}, R{d}, 0x1, R{d}", .{ M.X0, M.KB, M.X0 }) else if (tok > 0) t.put("IMAD R{d}, R{d}, 0x{x}, R{d}", .{ M.X0, M.KB, tok, M.X0 });
                    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ M.XA, M.X0, M.AQ });
                    t.put("@P3 LDG.E.128 R{d}, desc[UR4][R{d}.64]", .{ dst[k], M.XA });
                    t.put("@P4 LDG.E.128 R{d}, desc[UR4][R{d}.64+0x400]", .{ dst[k] + 4, M.XA });
                },
                's' => {
                    // act_sums + (t * blocks + tb) * 32 + 16 tid
                    if (tok > 0) {
                        if (tok == 1) t.put("IMAD.IADD R{d}, R{d}, 0x1, R{d}", .{ M.X0, M.NBLK, M.TB }) else t.put("IMAD R{d}, R{d}, 0x{x}, R{d}", .{ M.X0, M.NBLK, tok, M.TB });
                        t.put("IMAD R{d}, R{d}, 0x20, R{d}", .{ M.X0, M.X0, M.TID16 });
                    } else t.put("IMAD R{d}, R{d}, 0x20, R{d}", .{ M.X0, M.TB, M.TID16 });
                    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ M.XA, M.X0, M.AS });
                    t.put("@P5 LDG.E.128 R{d}, desc[UR4][R{d}.64]", .{ dst[k], M.XA });
                },
                else => {
                    // act_d + (t * blocks + tb + tid) * 4
                    if (tok > 0) {
                        if (tok == 1) t.put("IMAD.IADD R{d}, R{d}, 0x1, R{d}", .{ M.X0, M.NBLK, M.TB }) else t.put("IMAD R{d}, R{d}, 0x{x}, R{d}", .{ M.X0, M.NBLK, tok, M.TB });
                        t.put("IADD R{d}, R{d}, R{d}", .{ M.X0, M.X0, M.TID });
                    } else t.put("IADD R{d}, R{d}, R{d}", .{ M.X0, M.TB, M.TID });
                    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ M.XA, M.X0, M.AD });
                    t.put("@P6 LDG.E R{d}, desc[UR4][R{d}.64]", .{ dst[k], M.XA });
                },
            }
        }
        for (first..last) |k| {
            const it = items[k];
            const tok = it.tok;
            switch (it.what) {
                'q' => {
                    t.put("@P3 STS.128 [R{d}+0x{x}], R{d}", .{ M.TID16, L.aq + TILE_COLUMNS * tok, dst[k] });
                    t.put("@P4 STS.128 [R{d}+0x{x}], R{d}", .{ M.TID16, L.aq + TILE_COLUMNS * tok + 0x400, dst[k] + 4 });
                },
                's' => t.put("@P5 STS.128 [R{d}+0x{x}], R{d}", .{ M.TID16, L.bs + 256 * tok, dst[k] }),
                else => t.put("@P6 STS [R{d}+0x{x}], R{d}", .{ M.TID4, L.ad + L.ad_token * tok, dst[k] }),
            }
        }
        first = last;
    }
    t.put("BAR.SYNC.DEFER_BLOCKING 0x0", .{});
    // this thread's first block in the tile
    t.put("IADD R{d}, R{d}, 0x{x}", .{ M.SA, M.H16, L.aq });
    if (L.q8k) t.put("IADD R{d}, R{d}, 0x{x}", .{ M.SB, M.H16, L.bs });
    t.put("MOV R{d}, 0x{x}", .{ M.SD, L.ad });
    t.put("MOV R{d}, RZ", .{M.I});
}

/// The next block: pointers on, the block loop's branch.
fn nextBlock(t: *Text, comptime kind: Kind, comptime label: []const u8) void {
    switch (kind) {
        .q4_k => {
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WP, M.WP, Q4_K_BLOCK });
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WH, M.WH, Q4_K_BLOCK });
        },
        .q8_0 => {
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WP, M.WP, Q8_0_BLOCK });
            t.put("IADD.64 R{d}, R{d}, 0x{x}", .{ M.WH, M.WH, Q8_0_BLOCK });
        },
        .q6_k => {},
    }
    t.put("IADD R{d}, R{d}, 0x{x}", .{ M.SA, M.SA, if (kind == .q8_0) QK8_0 else QK_K });
    if (kind != .q8_0) t.put("IADD R{d}, R{d}, 0x20", .{ M.SB, M.SB });
    t.put("IADD R{d}, R{d}, 0x4", .{ M.SD, M.SD });
    t.put("IADD R{d}, R{d}, 0x1", .{ M.I, M.I });
    t.put("ISETP.LT.U32.AND P0, PT, R{d}, R{d}, PT", .{ M.I, M.NB });
    t.put("@P0 BRA `({s})", .{label});
}

/// The row's lanes added as the CPU adds them, stored by h = 0.
fn epilogue(t: *Text, comptime kind: Kind, comptime tokens: u32, comptime L: type) void {
    const F = M.X0; // the token's result
    const G = 36; // the partner's lane, and Q8_0's pairs
    t.put("LDC R{d}, c[0x0][0x3b0]", .{M.ROWS});
    t.put("LDC R{d}, c[0x0][0x3b4]", .{M.RB});
    t.put("LDC.64 R{d}, c[0x0][0x3a0]", .{M.WB});
    t.put("ISETP.LT.U32.AND P1, PT, R{d}, R{d}, PT", .{ M.ROW, M.ROWS });
    t.put("ISETP.EQ.AND P1, PT, R{d}, RZ, P1", .{M.H});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ M.WB, M.ROW, M.WB });
    for (0..tokens) |tok| {
        if (kind == .q8_0) {
            // GGML's AVX reduction: (l4 + l0, l5 + l1, l6 + l2, l7 + l3),
            // then (q0 + q2) + (q1 + q3)
            for (0..4) |j| t.put("SHFL.BFLY PT, R{d}, R{d}, 0x1, 0x1f", .{ G + j, sumReg(L, tok, j) });
            for (0..4) |j| t.put("FADD R{d}, R{d}, R{d}", .{ G + j, G + j, sumReg(L, tok, j) });
            t.put("FADD R{d}, R{d}, R{d}", .{ G, G, G + 2 });
            t.put("FADD R{d}, R{d}, R{d}", .{ G + 1, G + 1, G + 3 });
            t.put("FADD R{d}, R{d}, R{d}", .{ F, G, G + 1 });
        } else {
            // lanes 0..7 in order: @reduce(.Add)
            for (0..4) |j| t.put("SHFL.BFLY PT, R{d}, R{d}, 0x1, 0x1f", .{ G + j, sumReg(L, tok, j) });
            t.put("FADD R{d}, R{d}, R{d}", .{ F, sumReg(L, tok, 0), sumReg(L, tok, 1) });
            t.put("FADD R{d}, R{d}, R{d}", .{ F, F, sumReg(L, tok, 2) });
            t.put("FADD R{d}, R{d}, R{d}", .{ F, F, sumReg(L, tok, 3) });
            for (0..4) |j| t.put("FADD R{d}, R{d}, R{d}", .{ F, F, G + j });
        }
        t.put("@P1 STG.E desc[UR4][R{d}.64], R{d}", .{ M.WB, F });
        if (tok + 1 < tokens) t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ M.WB, M.RB, M.WB });
    }
    t.put("EXIT", .{});
}

// ── Q4_K ────────────────────────────────────────────────────────────────────
//
// A 144-byte block: d, dmin (f16), 12 bytes of 6-bit scales and minimums,
// 128 bytes of nibbles in four 32-byte pairs (pair p: low nibbles are
// sub-block 2p, high 2p + 1). Thread h loads the header and the 16 bytes
// 16h..16h+15 of each pair (its lanes' four bytes of each sub-block).

const Q4 = struct {
    const HD = 36; // the header (4)
    const QW = 40; // the quants (16), then their high nibbles
    const LO = 56; // low nibbles (16)
    const SC = 72; // the 8 scales
    const MN = 80; // this thread's 4 minimums
    const DD = 84;
    const DM = 85;
    const T0 = 86;
    const T1 = 87;
    const A = 88; // a token's values: pair p's low at 88 + 8p, high + 4
    const BS = 120; // its sums (lanes' pairs)
    const ADV = 124;
    const XV = 125; // d * ad
    const YV = 126; // dmin * ad
    const DT = 128; // the dots (4)
    const IA = 132; // the lanes' integers (4)
    const MT = 136; // the minimums' integers (4)
    const FT = 140; // floats (4)
};

fn q4kBlocks(t: *Text, comptime tokens: u32, comptime L: type) void {
    t.put("q4blk:", .{});
    t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64]", .{ Q4.HD, M.WP });
    for (0..4) |p| t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64+0x{x}]", .{ Q4.QW + 4 * p, M.WH, 0x10 + 0x20 * p });
    // The 6-bit scales and minimums, GGML's mask sequence (quantized_linear
    // unpackScalesQ4K): scales 0..3, 4..7; this thread's minimums.
    const S0 = Q4.HD + 1;
    const S1 = Q4.HD + 2;
    const S2 = Q4.HD + 3;
    t.put("LOP3.LUT R{d}, R{d}, 0x3f3f3f3f, RZ, 0x{x}, !PT", .{ Q4.T0, S0, AND });
    t.put("SHF.R.U32.HI R{d}, RZ, 0x2, R{d}", .{ Q4.T1, S0 });
    t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ Q4.T1, Q4.T1, AND });
    t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ Q4.T1, S2, Q4.T1, AND_OR });
    for (0..4) |k| t.put("PRMT R{d}, R{d}, 0x{x}, RZ", .{ Q4.SC + k, Q4.T0, zext(k) });
    for (0..4) |k| t.put("PRMT R{d}, R{d}, 0x{x}, RZ", .{ Q4.SC + 4 + k, Q4.T1, zext(k) });
    t.put("LOP3.LUT R{d}, R{d}, 0x3f3f3f3f, RZ, 0x{x}, !PT", .{ Q4.T0, S1, AND });
    t.put("SHF.R.U32.HI R{d}, RZ, 0x4, R{d}", .{ Q4.T1, S2 });
    t.put("SHF.R.U32.HI R{d}, RZ, 0x2, R{d}", .{ Q4.DT, S1 });
    t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ Q4.DT, Q4.DT, AND });
    t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ Q4.T1, Q4.T1, Q4.DT, AND_OR });
    t.put("SEL R{d}, R{d}, R{d}, P2", .{ Q4.T0, Q4.T1, Q4.T0 });
    for (0..4) |k| t.put("PRMT R{d}, R{d}, 0x{x}, RZ", .{ Q4.MN + k, Q4.T0, zext(k) });
    t.put("HADD2.F32 R{d}, -RZ, R{d}.H0_H0", .{ Q4.DD, Q4.HD });
    t.put("HADD2.F32 R{d}, -RZ, R{d}.H1_H1", .{ Q4.DM, Q4.HD });
    // nibbles: low into LO, high in place
    for (0..16) |k| {
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, RZ, 0x{x}, !PT", .{ Q4.LO + k, Q4.QW + k, AND });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x4, R{d}", .{ Q4.QW + k, Q4.QW + k });
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, RZ, 0x{x}, !PT", .{ Q4.QW + k, Q4.QW + k, AND });
    }
    for (0..tokens) |tok| {
        for (0..4) |p| {
            t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q4.A + 8 * p, M.SA, TILE_COLUMNS * tok + 64 * p });
            t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q4.A + 8 * p + 4, M.SA, TILE_COLUMNS * tok + 64 * p + 32 });
        }
        t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q4.BS, M.SB, 256 * tok });
        t.put("LDS R{d}, [R{d}+0x{x}]", .{ Q4.ADV, M.SD, L.ad_token * tok });
        // integer: sum over sub-blocks of scale * dot(nibbles, values)
        for (0..4) |p| {
            for (0..4) |j| {
                t.put("IDP.4A.U8.S8 R{d}, R{d}, R{d}, RZ", .{ Q4.DT + j, Q4.LO + 4 * p + j, Q4.A + 8 * p + j });
                if (p == 0) {
                    t.put("IMAD R{d}, R{d}, R{d}, RZ", .{ Q4.IA + j, Q4.DT + j, Q4.SC + 2 * p });
                } else t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ Q4.IA + j, Q4.DT + j, Q4.SC + 2 * p, Q4.IA + j });
                t.put("IDP.4A.U8.S8 R{d}, R{d}, R{d}, RZ", .{ Q4.DT + j, Q4.QW + 4 * p + j, Q4.A + 8 * p + 4 + j });
                t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ Q4.IA + j, Q4.DT + j, Q4.SC + 2 * p + 1, Q4.IA + j });
            }
        }
        // sums += (d * ad) * float(I) - (dmin * ad) * float(min * (bsum + bsum'))
        t.put("FMUL R{d}, R{d}, R{d}", .{ Q4.XV, Q4.DD, Q4.ADV });
        t.put("FMUL R{d}, R{d}, R{d}", .{ Q4.YV, Q4.DM, Q4.ADV });
        for (0..4) |j| {
            // (the two i16 sums: their sum is the top half of w + (w << 16))
            t.put("IMAD R{d}, R{d}, 0x10000, R{d}", .{ Q4.MT + j, Q4.BS + j, Q4.BS + j });
            t.put("SHF.R.S32.HI R{d}, RZ, 0x10, R{d}", .{ Q4.MT + j, Q4.MT + j });
            t.put("IMAD R{d}, R{d}, R{d}, RZ", .{ Q4.MT + j, Q4.MT + j, Q4.MN + j });
            t.put("I2FP.F32.S32 R{d}, R{d}", .{ Q4.FT + j, Q4.IA + j });
            t.put("I2FP.F32.S32 R{d}, R{d}", .{ Q4.MT + j, Q4.MT + j });
            t.put("FMUL R{d}, R{d}, R{d}", .{ Q4.FT + j, Q4.XV, Q4.FT + j });
            t.put("FMUL R{d}, R{d}, R{d}", .{ Q4.MT + j, Q4.YV, Q4.MT + j });
            t.put("FADD R{d}, R{d}, -R{d}", .{ Q4.FT + j, Q4.FT + j, Q4.MT + j });
            t.put("FADD R{d}, R{d}, R{d}", .{ sumReg(L, tok, j), sumReg(L, tok, j), Q4.FT + j });
        }
    }
    nextBlock(t, .q4_k, "q4blk");
}

// ── Q6_K ────────────────────────────────────────────────────────────────────
//
// A 210-byte block: ql (128 bytes: low nibbles), qh (64: the top two bits),
// 16 i8 scales, d (f16) at 208. Thread h needs 16 bytes at 16h + 32k (k =
// 0..5: ql's four pieces, qh's two), the scales and d. Blocks are 2 bytes
// off 16 one after another, so the loads go a tile (8 blocks, 1680 bytes,
// 16-aligned) at a time: block i of the tile starts 2i bytes into line
// 13i, and each block's loads and the bytes it picks out of them are fixed.
// A warp-uniform branch on i picks one of the eight.

const Q6 = struct {
    const Q = 36; // assembled 6-bit quants: half * 16 + quarter * 4 + w
    const SC = 68; // the multipliers of the 8 (half, quarter): scales[8 half + 2 quarter + h]
    const OSC = 76; // the offsets' scales: scales[8h + 2w + e]
    const D = 84;
    const T = 85; // temps (4)
    const OW = 89;
    const RAW = 96; // the block's lines (14 quads), dead after the assembly
    // a token's (over RAW)
    const A = 96; // values: (half, quarter) at 96 + 16 half + 4 quarter
    const BS = 128;
    const ADV = 132;
    const SCL = 133;
    const DT = 134;
    const IA = 138;
    const OT = 142;
    const FT = 146;
};

fn q6kBlocks(t: *Text, comptime tokens: u32, comptime L: type) void {
    t.put("q6blk:", .{});
    // the warp-uniform 8-way branch on i
    t.put("LOP3.LUT P0, RZ, R{d}, 0x4, RZ, 0x{x}, !PT", .{ M.I, AND });
    t.put("@P0 BRA `(q6d4)", .{});
    t.put("LOP3.LUT P0, RZ, R{d}, 0x2, RZ, 0x{x}, !PT", .{ M.I, AND });
    t.put("@P0 BRA `(q6d2)", .{});
    q6kDispatch(t, 0);
    t.put("q6d2:", .{});
    q6kDispatch(t, 2);
    t.put("q6d4:", .{});
    t.put("LOP3.LUT P0, RZ, R{d}, 0x2, RZ, 0x{x}, !PT", .{ M.I, AND });
    t.put("@P0 BRA `(q6d6)", .{});
    q6kDispatch(t, 4);
    t.put("q6d6:", .{});
    q6kDispatch(t, 6);
    t.put("q6c:", .{});
    for (0..tokens) |tok| {
        for (0..2) |half| for (0..4) |q| {
            t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q6.A + 16 * half + 4 * q, M.SA, TILE_COLUMNS * tok + 128 * half + 32 * q });
        };
        t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q6.BS, M.SB, 256 * tok });
        t.put("LDS R{d}, [R{d}+0x{x}]", .{ Q6.ADV, M.SD, L.ad_token * tok });
        for (0..2) |half| for (0..4) |q| {
            const sub = 4 * half + q;
            for (0..4) |w| {
                t.put("IDP.4A.U8.S8 R{d}, R{d}, R{d}, RZ", .{ Q6.DT + w, Q6.Q + 16 * half + 4 * q + w, Q6.A + 16 * half + 4 * q + w });
                if (sub == 0) {
                    t.put("IMAD R{d}, R{d}, R{d}, RZ", .{ Q6.IA + w, Q6.DT + w, Q6.SC + sub });
                } else t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ Q6.IA + w, Q6.DT + w, Q6.SC + sub, Q6.IA + w });
            }
        };
        // sums += (d * ad) * (float(I) - 32 * float(offset)), offset =
        // bsums[2l] scales[2l] + bsums[2l + 1] scales[2l + 1]
        t.put("FMUL R{d}, R{d}, R{d}", .{ Q6.SCL, Q6.D, Q6.ADV });
        for (0..4) |w| {
            t.put("PRMT R{d}, R{d}, 0x9910, RZ", .{ Q6.DT + w, Q6.BS + w });
            t.put("SHF.R.S32.HI R{d}, RZ, 0x10, R{d}", .{ Q6.FT + w, Q6.BS + w });
            t.put("IMAD R{d}, R{d}, R{d}, RZ", .{ Q6.OT + w, Q6.DT + w, Q6.OSC + 2 * w });
            t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ Q6.OT + w, Q6.FT + w, Q6.OSC + 2 * w + 1, Q6.OT + w });
            t.put("I2FP.F32.S32 R{d}, R{d}", .{ Q6.FT + w, Q6.IA + w });
            t.put("I2FP.F32.S32 R{d}, R{d}", .{ Q6.OT + w, Q6.OT + w });
            // (32 * offset is exact: one rounding either way)
            t.put("FFMA R{d}, R{d}, -32, R{d}", .{ Q6.FT + w, Q6.OT + w, Q6.FT + w });
            t.put("FMUL R{d}, R{d}, R{d}", .{ Q6.FT + w, Q6.SCL, Q6.FT + w });
            t.put("FADD R{d}, R{d}, R{d}", .{ sumReg(L, tok, w), sumReg(L, tok, w), Q6.FT + w });
        }
    }
    nextBlock(t, .q6_k, "q6blk");
}

/// Blocks first and first + 1 (bit 0 of i picks).
fn q6kDispatch(t: *Text, comptime first: u32) void {
    t.put("LOP3.LUT P0, RZ, R{d}, 0x1, RZ, 0x{x}, !PT", .{ M.I, AND });
    t.put("@P0 BRA `(q6p{d})", .{first + 1});
    q6kPrep(t, first);
    t.put("BRA `(q6c)", .{});
    t.put("q6p{d}:", .{first + 1});
    q6kPrep(t, first + 1);
    if (first + 1 != 7) t.put("BRA `(q6c)", .{});
}

/// Block i of the tile: its lines, realigned, the 6-bit quants assembled,
/// the scales and d.
fn q6kPrep(t: *Text, comptime i: u32) void {
    const RAW = Q6.RAW;
    // pieces: lines 13i + h + j (j = 0..11) from WH; scales and d: lines
    // 13i + 12, 13i + 13 from WP. Block 0 is aligned: one line a piece.
    for (0..12) |j| {
        if (i == 0 and j % 2 == 1) continue;
        t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64+0x{x}]", .{ RAW + 4 * j, M.WH, 208 * i + 16 * j });
    }
    t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64+0x{x}]", .{ RAW + 48, M.WP, 208 * i + 192 });
    t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64+0x{x}]", .{ RAW + 52, M.WP, 208 * i + 208 });
    // piece k's word w: bytes 2i + 4w of lines 2k, 2k + 1, realigned in
    // place (into raw[8k + i/2 + w]) when 2i is not a word's start
    const x0 = i / 2;
    if (i % 2 == 1) {
        for (0..6) |k| for (0..4) |w| {
            const x = RAW + 8 * k + x0 + w;
            t.put("PRMT R{d}, R{d}, 0x5432, R{d}", .{ x, x, x + 1 });
        };
    }
    const TT = Q6.T;
    for (0..2) |half| for (0..4) |w| {
        const lo = RAW + 8 * (2 * half) + x0 + w;
        const nx = RAW + 8 * (2 * half + 1) + x0 + w;
        const hi = RAW + 8 * (4 + half) + x0 + w;
        const q = Q6.Q + 16 * half + w;
        // q0 = (lo & 0xf) | (hi & 3) << 4; q1 = (nx & 0xf) | (hi >> 2 & 3) << 4
        // q2 = (lo >> 4) | (hi >> 4 & 3) << 4; q3 = (nx >> 4) | (hi >> 6) << 4
        t.put("IMAD.SHL.U32 R{d}, R{d}, 0x10, RZ", .{ TT, hi });
        t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ TT, TT, AND });
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ q, lo, TT, AND_OR });
        t.put("IMAD.SHL.U32 R{d}, R{d}, 0x4, RZ", .{ TT + 1, hi });
        t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ TT + 1, TT + 1, AND });
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ q + 4, nx, TT + 1, AND_OR });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x4, R{d}", .{ TT + 2, lo });
        t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ TT + 3, hi, AND });
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ q + 8, TT + 2, TT + 3, AND_OR });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x4, R{d}", .{ TT + 2, nx });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x2, R{d}", .{ TT + 3, hi });
        t.put("LOP3.LUT R{d}, R{d}, 0x30303030, RZ, 0x{x}, !PT", .{ TT + 3, TT + 3, AND });
        t.put("LOP3.LUT R{d}, R{d}, 0xf0f0f0f, R{d}, 0x{x}, !PT", .{ q + 12, TT + 2, TT + 3, AND_OR });
    };
    // multipliers: scale byte 8 half + 2 quarter + h sits 2i bytes into
    // the scale lines: word (i + s) / 2, byte 2 ((i + s) % 2) + h
    for (0..8) |s| {
        t.put("PRMT R{d}, R{d}, R{d}, RZ", .{ Q6.SC + s, RAW + 48 + (i + s) / 2, if ((i + s) % 2 == 0) M.SELE else M.SELO });
    }
    // offsets' scales 8h + 2w + e: word (i + w) / 2 + 2h, byte 2 ((i + w) % 2) + e
    for (0..4) |w| {
        const wd = RAW + 48 + (i + w) / 2;
        t.put("SEL R{d}, R{d}, R{d}, P2", .{ Q6.OW, wd + 2, wd });
        for (0..2) |e| t.put("PRMT R{d}, R{d}, 0x{x}, RZ", .{ Q6.OSC + 2 * w + e, Q6.OW, sext(2 * ((i + w) % 2) + e) });
    }
    // d: 2i bytes into line 13i + 13
    t.put("HADD2.F32 R{d}, -RZ, R{d}.{s}", .{ Q6.D, RAW + 52 + i / 2, if (i % 2 == 0) "H0_H0" else "H1_H1" });
}

// ── Q8_0 ────────────────────────────────────────────────────────────────────
//
// A 34-byte block: d (f16), 32 i8. Thread h's lanes are bytes 2 + 16h ..
// 17 + 16h, which are 2 bytes off 16 differently from row to row and block
// to block: two aligned 16-byte loads and the 16 bytes picked out of their
// 32 by the address's low bits (a select on bit 3, one on bit 2, a PRMT
// for bit 1). d is a 16-bit load.

const Q8 = struct {
    const PA = 38; // the aligned address (64 bits)
    const C = 44; // the two lines (8)
    const X = 52; // (6)
    const Y = 58; // (5)
    const W = 64; // the lanes' words (4)
    const DW = 68;
    const DH = 69;
    const SEL = 70;
    // a token's
    const A = 72;
    const ADV = 76;
    const XS = 77;
    const DT = 80;
    const FT = 84;
};

fn q80Blocks(t: *Text, comptime tokens: u32, comptime L: type) void {
    t.put("q8blk:", .{});
    t.put("LOP3.LUT R{d}, R{d}, 0xfffffff0, RZ, 0x{x}, !PT", .{ Q8.PA, M.WH, AND });
    t.put("MOV R{d}, R{d}", .{ Q8.PA + 1, M.WH + 1 });
    t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64]", .{ Q8.C, Q8.PA });
    t.put("LDG.E.128.CONSTANT R{d}, desc[UR4][R{d}.64+0x10]", .{ Q8.C + 4, Q8.PA });
    t.put("LDG.E.U16.CONSTANT R{d}, desc[UR4][R{d}.64]", .{ Q8.DH, M.WP });
    t.put("LOP3.LUT P0, RZ, R{d}, 0x8, RZ, 0x{x}, !PT", .{ M.WH, AND });
    t.put("LOP3.LUT P1, RZ, R{d}, 0x4, RZ, 0x{x}, !PT", .{ M.WH, AND });
    t.put("LOP3.LUT P5, RZ, R{d}, 0x2, RZ, 0x{x}, !PT", .{ M.WH, AND });
    t.put("MOV R{d}, 0x3210", .{Q8.SEL});
    t.put("@P5 MOV R{d}, 0x5432", .{Q8.SEL});
    for (0..6) |w| t.put("SEL R{d}, R{d}, R{d}, P0", .{ Q8.X + w, Q8.C + w + 2, Q8.C + w });
    for (0..5) |w| t.put("SEL R{d}, R{d}, R{d}, P1", .{ Q8.Y + w, Q8.X + w + 1, Q8.X + w });
    for (0..4) |w| t.put("PRMT R{d}, R{d}, R{d}, R{d}", .{ Q8.W + w, Q8.Y + w, Q8.SEL, Q8.Y + w + 1 });
    t.put("HADD2.F32 R{d}, -RZ, R{d}.H0_H0", .{ Q8.DW, Q8.DH });
    for (0..tokens) |tok| {
        t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ Q8.A, M.SA, TILE_COLUMNS * tok });
        t.put("LDS R{d}, [R{d}+0x{x}]", .{ Q8.ADV, M.SD, L.ad_token * tok });
        t.put("FMUL R{d}, R{d}, R{d}", .{ Q8.XS, Q8.DW, Q8.ADV });
        for (0..4) |w| {
            t.put("IDP.4A.S8.S8 R{d}, R{d}, R{d}, RZ", .{ Q8.DT + w, Q8.W + w, Q8.A + w });
            t.put("I2FP.F32.S32 R{d}, R{d}", .{ Q8.FT + w, Q8.DT + w });
            // the CPU's @mulAdd
            t.put("FFMA R{d}, R{d}, R{d}, R{d}", .{ sumReg(L, tok, w), Q8.XS, Q8.FT + w, sumReg(L, tok, w) });
        }
    }
    nextBlock(t, .q8_0, "q8blk");
}

/// out[t][row] = Q4_K row . Q8_K activations of token t (quantized_linear
/// dotQ4KQ8KTile, to the bit).
pub fn q4kMatrix(comptime tokens: u32) []const u8 {
    return comptime matrixKernel(.q4_k, tokens);
}

/// out[t][row] = Q6_K row . Q8_K activations of token t (dotQ6KQ8KTile,
/// to the bit). Rows of whole groups of 8 blocks.
pub fn q6kMatrix(comptime tokens: u32) []const u8 {
    return comptime matrixKernel(.q6_k, tokens);
}

/// out[t][row] = Q8_0 row . Q8_0 activations of token t (dotQ80Q80Tile,
/// to the bit: FFMA is fused as @mulAdd).
pub fn q80Matrix(comptime tokens: u32) []const u8 {
    return comptime matrixKernel(.q8_0, tokens);
}

// ── Activation quantization ─────────────────────────────────────────────────

/// dst = a / b, ptxas's div.rn fast path: the reciprocal, a Newton step,
/// the quotient and one correction by its exact remainder. `a` is a
/// register or an f32 immediate; tmp: three registers.
fn fdiv(t: *Text, comptime dst: u32, comptime a: []const u8, comptime a_imm: bool, comptime b: u32, comptime tmp: [3]u32) void {
    const r = tmp[0];
    const e = tmp[1];
    t.put("MUFU.RCP R{d}, R{d}", .{ r, b });
    t.put("FFMA R{d}, -R{d}, R{d}, 1", .{ e, b, r });
    t.put("FFMA R{d}, R{d}, R{d}, R{d}", .{ r, r, e, r });
    if (a_imm) t.put("FFMA R{d}, R{d}, {s}, RZ", .{ dst, r, a }) else t.put("FFMA R{d}, {s}, R{d}, RZ", .{ dst, a, r });
    t.put("FFMA R{d}, -R{d}, R{d}, {s}", .{ tmp[2], b, dst, a });
    t.put("FFMA R{d}, R{d}, R{d}, R{d}", .{ dst, r, tmp[2], dst });
}

/// x + 1.5 * 2^23's mantissa: quantized_linear.nearestInt (ties to even).
fn nearest(t: *Text, comptime d: u32, comptime x: u32) void {
    t.put("FADD R{d}, R{d}, 12582912", .{ d, x });
    t.put("IADD R{d}, R{d}, -0x4b400000", .{ d, d });
}

/// Registers of the Q8_K quantization (under 61: a CTA of 32 warps).
const QK = struct {
    const TID = 0;
    const CTA = 2;
    const TOK = 3;
    const K = 4;
    const LANE = 5;
    const BLK = 6;
    const NBLK = 7;
    const EL = 8; // t * k + block * 256 + lane * 8
    const COL = 9; // block * 256 + lane * 8
    const B64 = 10;
    const A64 = 12;
    const V = 16; // the 8 values
    const Q = 24; // |v|, then the quants
    const MAX = 32;
    const SH = 33;
    const KEY0 = 34;
    const KEY = 35;
    const TK = 36;
    const MX = 37; // the signed maximum
    const DIV = 38; // (3)
    const INV = 41;
    const DQ = 42;
    const PK = 44; // packed (2), then the sums
    const G = 48; // t * blocks + block
};

fn q8kQuantKernel(comptime norm: bool, comptime waves: u32) []const u8 {
    comptime {
        @setEvalBranchQuota(50_000_000);
        if (norm and (waves < 1 or waves > MAX_NORM_WAVES)) @compileError("waves: 1 to MAX_NORM_WAVES");
        var t = Text{};
        if (norm) {
            t.put("// lfm3 rmsnorm + q8_k quantization: a row of {d} blocks a CTA", .{waves});
        } else t.put("// lfm3 q8_k quantization: a warp a 256-lane block", .{});
        t.put(".params {d}", .{@sizeOf(QuantParams)});
        t.put("S2R R{d}, SR_TID.X", .{QK.TID});
        if (!norm) t.put("S2R R{d}, SR_CTAID.X", .{QK.CTA});
        t.put("S2R R{d}, SR_CTAID.Y", .{QK.TOK});
        t.put("LDCU.64 UR4, c[0x0][0x358]", .{});
        t.put("LDC R{d}, c[0x0][0x3b0]", .{QK.K});
        t.put("LOP3.LUT R{d}, R{d}, 0x1f, RZ, 0x{x}, !PT", .{ QK.LANE, QK.TID, AND });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x5, R{d}", .{ QK.BLK, QK.TID });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x8, R{d}", .{ QK.NBLK, QK.K });
        if (!norm) {
            t.put("LEA R{d}, R{d}, R{d}, 0x2", .{ QK.BLK, QK.CTA, QK.BLK });
            // (a warp past the row's blocks: the whole warp leaves)
            t.put("ISETP.GE.U32.AND P0, PT, R{d}, R{d}, PT", .{ QK.BLK, QK.NBLK });
            t.put("@P0 EXIT", .{});
        }
        t.put("IMAD.SHL.U32 R{d}, R{d}, 0x100, RZ", .{ QK.COL, QK.BLK });
        t.put("LEA R{d}, R{d}, R{d}, 0x3", .{ QK.COL, QK.LANE, QK.COL });
        t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ QK.EL, QK.TOK, QK.K, QK.COL });
        t.put("LDC.64 R{d}, c[0x0][0x380]", .{QK.B64});
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ QK.A64, QK.EL, QK.B64 });
        t.put("LDG.E.128 R{d}, desc[UR4][R{d}.64]", .{ QK.V, QK.A64 });
        t.put("LDG.E.128 R{d}, desc[UR4][R{d}.64+0x10]", .{ QK.V + 4, QK.A64 });
        if (norm) rmsNorm(&t, waves);
        q8kTail(&t);
        return t.done();
    }
}

/// RMSNorm of the row (8 values a lane, a warp a block, `waves` warps) in
/// place, the normalized values written out: x * (1 / sqrt(mean + eps)) * w.
fn rmsNorm(t: *Text, comptime waves: u32) void {
    const S = QK.Q; // the sum of squares
    const W = 28; // the weights (8)
    t.put("FMUL R{d}, R{d}, R{d}", .{ S, QK.V, QK.V });
    for (1..8) |k| t.put("FFMA R{d}, R{d}, R{d}, R{d}", .{ S, QK.V + k, QK.V + k, S });
    for ([_]u32{ 1, 2, 4, 8, 16 }) |m| {
        t.put("SHFL.BFLY PT, R{d}, R{d}, 0x{x}, 0x1f", .{ S + 1, S, m });
        t.put("FADD R{d}, R{d}, R{d}", .{ S, S, S + 1 });
    }
    // each warp's sum to shared memory, then every thread adds them in order
    t.put("ISETP.NE.AND P0, PT, R{d}, RZ, PT", .{QK.LANE});
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x4, RZ", .{ S + 2, QK.BLK });
    t.put("@!P0 STS [R{d}+0x400], R{d}", .{ S + 2, S });
    t.put("BAR.SYNC.DEFER_BLOCKING 0x0", .{});
    t.put("MOV R{d}, 0x400", .{S + 2});
    var w: u32 = 0;
    while (w < waves) : (w += 4) {
        t.put("LDS.128 R{d}, [R{d}+0x{x}]", .{ W, S + 2, 4 * w });
        for (0..@min(4, waves - w)) |k| {
            if (w + k == 0) {
                t.put("MOV R{d}, R{d}", .{ S, W });
            } else t.put("FADD R{d}, R{d}, R{d}", .{ S, S, W + k });
        }
    }
    t.put("LDC R{d}, c[0x0][0x3b8]", .{S + 1});
    t.put("FMUL R{d}, R{d}, R{d}", .{ S, S, S + 1 });
    t.put("LDC R{d}, c[0x0][0x3b4]", .{S + 1});
    t.put("FADD R{d}, R{d}, R{d}", .{ S, S, S + 1 });
    t.put("MUFU.RSQ R{d}, R{d}", .{ S, S });
    t.put("LDC.64 R{d}, c[0x0][0x388]", .{QK.B64});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ QK.A64, QK.COL, QK.B64 });
    t.put("LDG.E.128 R{d}, desc[UR4][R{d}.64]", .{ W, QK.A64 });
    t.put("LDG.E.128 R{d}, desc[UR4][R{d}.64+0x10]", .{ W + 4, QK.A64 });
    for (0..8) |k| {
        t.put("FMUL R{d}, R{d}, R{d}", .{ QK.V + k, QK.V + k, S });
        t.put("FMUL R{d}, R{d}, R{d}", .{ QK.V + k, QK.V + k, W + k });
    }
    t.put("LDC.64 R{d}, c[0x0][0x390]", .{QK.B64});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ QK.A64, QK.EL, QK.B64 });
    t.put("STG.E.128 desc[UR4][R{d}.64], R{d}", .{ QK.A64, QK.V });
    t.put("STG.E.128 desc[UR4][R{d}.64+0x10], R{d}", .{ QK.A64, QK.V + 4 });
}

/// quantizeQ8K of the warp's 256 values (8 a lane in V): the first value
/// of the largest magnitude is the maximum, inverse = -127 / maximum,
/// q = min(127, nearest(inverse * v)), d = 1 / inverse; a zero block all
/// zeros. Stores the values, the sums of 16 and d.
fn q8kTail(t: *Text) void {
    const V = QK.V;
    const Q = QK.Q;
    for (0..8) |k| t.put("LOP3.LUT R{d}, R{d}, 0x7fffffff, RZ, 0x{x}, !PT", .{ Q + k, V + k, AND });
    // (|v| as bits orders like the magnitudes)
    t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ QK.MAX, Q, Q + 1 });
    for (2..8) |k| t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ QK.MAX, QK.MAX, Q + k });
    for ([_]u32{ 1, 2, 4, 8, 16 }) |m| {
        t.put("SHFL.BFLY PT, R{d}, R{d}, 0x{x}, 0x1f", .{ QK.SH, QK.MAX, m });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ QK.MAX, QK.MAX, QK.SH });
    }
    // the first such value: key = index << 1 | sign, the warp's least
    t.put("IMAD.SHL.U32 R{d}, R{d}, 0x10, RZ", .{ QK.KEY0, QK.LANE });
    t.put("MOV R{d}, 0xffffffff", .{QK.KEY});
    var k: u32 = 8;
    while (k > 0) {
        k -= 1;
        t.put("SHF.R.U32.HI R{d}, RZ, 0x1f, R{d}", .{ QK.TK, V + k });
        // (the immediate second: GB206 takes none as IADD3's third source)
        t.put("IADD3 R{d}, PT, PT, R{d}, 0x{x}, R{d}", .{ QK.TK, QK.KEY0, 2 * k, QK.TK });
        t.put("ISETP.EQ.U32.AND P0, PT, R{d}, R{d}, PT", .{ Q + k, QK.MAX });
        t.put("SEL R{d}, R{d}, R{d}, P0", .{ QK.KEY, QK.TK, QK.KEY });
    }
    for ([_]u32{ 1, 2, 4, 8, 16 }) |m| {
        t.put("SHFL.BFLY PT, R{d}, R{d}, 0x{x}, 0x1f", .{ QK.SH, QK.KEY, m });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, PT", .{ QK.KEY, QK.KEY, QK.SH });
    }
    t.put("SHF.L.U32 R{d}, R{d}, 0x1f, RZ", .{ QK.TK, QK.KEY });
    t.put("LOP3.LUT R{d}, R{d}, R{d}, RZ, 0x{x}, !PT", .{ QK.MX, QK.MAX, QK.TK, OR });
    t.put("ISETP.NE.U32.AND P1, PT, R{d}, RZ, PT", .{QK.MAX});
    fdiv(t, QK.INV, "-127", true, QK.MX, .{ QK.DIV, QK.DIV + 1, QK.DIV + 2 });
    fdiv(t, QK.DQ, "1", true, QK.INV, .{ QK.DIV, QK.DIV + 1, QK.DIV + 2 });
    t.put("SEL R{d}, R{d}, RZ, P1", .{ QK.DQ, QK.DQ });
    for (0..8) |j| {
        t.put("FMUL R{d}, R{d}, R{d}", .{ Q + j, QK.INV, V + j });
        nearest(t, Q + j, Q + j);
        t.put("VIMNMX.S32 R{d}, R{d}, 0x7f, PT", .{ Q + j, Q + j });
        t.put("SEL R{d}, R{d}, RZ, P1", .{ Q + j, Q + j });
    }
    // the values: four bytes a word, two words a lane
    for (0..2) |w| {
        t.put("PRMT R{d}, R{d}, 0x40, R{d}", .{ QK.SH, Q + 4 * w, Q + 4 * w + 1 });
        t.put("PRMT R{d}, R{d}, 0x40, R{d}", .{ QK.TK, Q + 4 * w + 2, Q + 4 * w + 3 });
        t.put("PRMT R{d}, R{d}, 0x5410, R{d}", .{ QK.PK + w, QK.SH, QK.TK });
    }
    t.put("LDC.64 R{d}, c[0x0][0x398]", .{QK.B64});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ QK.A64, QK.EL, QK.B64 });
    t.put("STG.E.64 desc[UR4][R{d}.64], R{d}", .{ QK.A64, QK.PK });
    // the sums of 16: lanes 2m and 2m + 1; lane 2m stores sum m (byte 2m)
    const SUM = QK.PK + 2;
    t.put("IADD3 R{d}, PT, PT, R{d}, R{d}, R{d}", .{ SUM, Q, Q + 1, Q + 2 });
    t.put("IADD3 R{d}, PT, PT, R{d}, R{d}, R{d}", .{ SUM, SUM, Q + 3, Q + 4 });
    t.put("IADD3 R{d}, PT, PT, R{d}, R{d}, R{d}", .{ SUM, SUM, Q + 5, Q + 6 });
    t.put("IADD R{d}, R{d}, R{d}", .{ SUM, SUM, Q + 7 });
    t.put("SHFL.BFLY PT, R{d}, R{d}, 0x1, 0x1f", .{ SUM + 1, SUM });
    t.put("IADD R{d}, R{d}, R{d}", .{ SUM, SUM, SUM + 1 });
    t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ QK.G, QK.TOK, QK.NBLK, QK.BLK });
    t.put("LDC.64 R{d}, c[0x0][0x3a8]", .{QK.B64});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x20, R{d}", .{ QK.A64, QK.G, QK.B64 });
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ QK.A64, QK.LANE, QK.A64 });
    t.put("LOP3.LUT P0, RZ, R{d}, 0x1, RZ, 0x{x}, !PT", .{ QK.LANE, AND });
    t.put("@!P0 STG.E.U16 desc[UR4][R{d}.64], R{d}", .{ QK.A64, SUM });
    t.put("ISETP.NE.AND P0, PT, R{d}, RZ, PT", .{QK.LANE});
    t.put("@P0 EXIT", .{});
    t.put("LDC.64 R{d}, c[0x0][0x3a0]", .{QK.B64});
    t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ QK.A64, QK.G, QK.B64 });
    t.put("STG.E desc[UR4][R{d}.64], R{d}", .{ QK.A64, QK.DQ });
    t.put("EXIT", .{});
}

/// Registers of the Q8_0 quantization.
const Q8Q = struct {
    const TID = 0;
    const CTA = 2;
    const TOK = 3;
    const K = 4;
    const LANE = 5; // in the block's 8
    const BLK = 6;
    const NBLK = 7;
    const EL = 8;
    const LAST = 9;
    const CB = 10; // the block, clamped into the row
    const B64 = 12;
    const A64 = 14;
    const V = 16;
    const Q = 20;
    const MAX = 24;
    const SH = 25;
    const C127 = 26;
    const DIV = 27; // (3)
    const DQ = 30;
    const INV = 31;
    const PK = 32;
    const PK2 = 33;
    const G = 34;
};

fn q80QuantKernel() []const u8 {
    comptime {
        @setEvalBranchQuota(20_000_000);
        const R = Q8Q;
        var t = Text{};
        t.put("// lfm3 q8_0 quantization: 8 lanes a 32-lane block, 32 blocks a CTA", .{});
        t.put(".params {d}", .{@sizeOf(Q80QuantParams)});
        t.put("S2R R{d}, SR_TID.X", .{R.TID});
        t.put("S2R R{d}, SR_CTAID.X", .{R.CTA});
        t.put("S2R R{d}, SR_CTAID.Y", .{R.TOK});
        t.put("LDCU.64 UR4, c[0x0][0x358]", .{});
        t.put("LDC R{d}, c[0x0][0x398]", .{R.K});
        t.put("LOP3.LUT R{d}, R{d}, 0x7, RZ, 0x{x}, !PT", .{ R.LANE, R.TID, AND });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x3, R{d}", .{ R.BLK, R.TID });
        t.put("LEA R{d}, R{d}, R{d}, 0x5", .{ R.BLK, R.CTA, R.BLK });
        t.put("SHF.R.U32.HI R{d}, RZ, 0x5, R{d}", .{ R.NBLK, R.K });
        // (a block past the row's last reads the last and stores nothing)
        t.put("ISETP.LT.U32.AND P1, PT, R{d}, R{d}, PT", .{ R.BLK, R.NBLK });
        t.put("IADD R{d}, R{d}, -0x1", .{ R.LAST, R.NBLK });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, PT", .{ R.CB, R.BLK, R.LAST });
        t.put("IMAD.SHL.U32 R{d}, R{d}, 0x20, RZ", .{ R.EL, R.CB });
        t.put("LEA R{d}, R{d}, R{d}, 0x2", .{ R.EL, R.LANE, R.EL });
        t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ R.EL, R.TOK, R.K, R.EL });
        t.put("LDC.64 R{d}, c[0x0][0x380]", .{R.B64});
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ R.A64, R.EL, R.B64 });
        t.put("LDG.E.128 R{d}, desc[UR4][R{d}.64]", .{ R.V, R.A64 });
        for (0..4) |k| t.put("LOP3.LUT R{d}, R{d}, 0x7fffffff, RZ, 0x{x}, !PT", .{ R.Q + k, R.V + k, AND });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ R.MAX, R.Q, R.Q + 1 });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ R.MAX, R.MAX, R.Q + 2 });
        t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ R.MAX, R.MAX, R.Q + 3 });
        for ([_]u32{ 1, 2, 4 }) |m| {
            t.put("SHFL.BFLY PT, R{d}, R{d}, 0x{x}, 0x1f", .{ R.SH, R.MAX, m });
            t.put("VIMNMX.U32 R{d}, R{d}, R{d}, !PT", .{ R.MAX, R.MAX, R.SH });
        }
        t.put("ISETP.NE.U32.AND P0, PT, R{d}, RZ, PT", .{R.MAX});
        // d = f16(amax / 127); inverse = 127 / amax, 0 for a zero block
        t.put("MOV R{d}, 0x42fe0000", .{R.C127});
        fdiv(&t, R.DQ, std.fmt.comptimePrint("R{d}", .{R.MAX}), false, R.C127, .{ R.DIV, R.DIV + 1, R.DIV + 2 });
        t.put("F2FP.F16.F32.PACK_AB R{d}, RZ, R{d}", .{ R.DQ, R.DQ });
        t.put("HADD2.F32 R{d}, -RZ, R{d}.H0_H0", .{ R.DQ, R.DQ });
        fdiv(&t, R.INV, "127", true, R.MAX, .{ R.DIV, R.DIV + 1, R.DIV + 2 });
        t.put("SEL R{d}, R{d}, RZ, P0", .{ R.INV, R.INV });
        for (0..4) |k| {
            t.put("FMUL R{d}, R{d}, R{d}", .{ R.Q + k, R.V + k, R.INV });
            nearest(&t, R.Q + k, R.Q + k);
            t.put("VIMNMX.S32 R{d}, R{d}, 0x7f, PT", .{ R.Q + k, R.Q + k });
            t.put("VIMNMX.S32 R{d}, R{d}, -0x7f, !PT", .{ R.Q + k, R.Q + k });
        }
        t.put("PRMT R{d}, R{d}, 0x40, R{d}", .{ R.PK, R.Q, R.Q + 1 });
        t.put("PRMT R{d}, R{d}, 0x40, R{d}", .{ R.PK2, R.Q + 2, R.Q + 3 });
        t.put("PRMT R{d}, R{d}, 0x5410, R{d}", .{ R.PK, R.PK, R.PK2 });
        t.put("@!P1 EXIT", .{});
        t.put("LDC.64 R{d}, c[0x0][0x388]", .{R.B64});
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x1, R{d}", .{ R.A64, R.EL, R.B64 });
        t.put("STG.E desc[UR4][R{d}.64], R{d}", .{ R.A64, R.PK });
        t.put("ISETP.NE.AND P0, PT, R{d}, RZ, PT", .{R.LANE});
        t.put("@P0 EXIT", .{});
        t.put("IMAD R{d}, R{d}, R{d}, R{d}", .{ R.G, R.TOK, R.NBLK, R.CB });
        t.put("LDC.64 R{d}, c[0x0][0x390]", .{R.B64});
        t.put("IMAD.WIDE.U32 R{d}, R{d}, 0x4, R{d}", .{ R.A64, R.G, R.B64 });
        t.put("STG.E desc[UR4][R{d}.64], R{d}", .{ R.A64, R.DQ });
        t.put("EXIT", .{});
        return t.done();
    }
}

/// Rows of f32 to Q8_K activations, quantizeQ8K's to the bit. With `norm`,
/// RMSNorm first (a CTA a row of `waves` = K / 256 blocks), the normalized
/// rows written to `normalized` and quantized as written. Without, `waves`
/// is not used (pass 1).
pub fn q8kQuant(comptime norm: bool, comptime waves: u32) []const u8 {
    return comptime q8kQuantKernel(norm, if (norm) waves else 1);
}

/// Rows of f32 to Q8_0 activations, quantizeQ80's to the bit (GGML's x86
/// rule). Magnitudes are normal floats or zero.
pub fn q80Quant() []const u8 {
    return comptime q80QuantKernel();
}

/// The matrix kernel's text for a token count known at run time (a forward
/// pass assembles the eight variants of each format once).
pub fn matrixSource(format: Format, tokens: u32) Error![]const u8 {
    if (tokens == 0 or tokens > MAX_TOKENS) return error.Unsupported;
    return switch (tokens) {
        inline 1...MAX_TOKENS => |n| switch (format) {
            .q4_k => q4kMatrix(n),
            .q6_k => q6kMatrix(n),
            .q8_0 => q80Matrix(n),
        },
        else => unreachable,
    };
}

/// The fused RMSNorm and Q8_K quantization's text for a row of `waves`
/// blocks (a power of two up to MAX_NORM_WAVES: hidden sizes of 256 to
/// 8192), or the plain quantization's (`norm` false, any waves).
pub fn q8kQuantSource(norm: bool, waves: u32) Error![]const u8 {
    if (!norm) return q8kQuant(false, 1);
    return switch (waves) {
        inline 1, 2, 4, 8, 16, 32 => |w| q8kQuant(true, w),
        else => error.Unsupported,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// Every kernel is sm120_asm's (its control fields worked out), runs on
// nvidia.device's emulated RTX from a QMD, constant buffer 0 and a
// pushbuffer as Galaxy's driver makes them (the GPU's memory apart from
// the CPU's, as VRAM behind BAR1), with the emulator checking the control
// fields at NAK's level (strict), and is compared with quantized_linear.

const nvidia = @import("nvidia");
const quantized = @import("quantized_linear");
const testing = std.testing;
const sm120 = nvidia.sm120;
const sm120_asm = nvidia.sm120_asm;
const sched = nvidia.sm120_sched;
const emu = nvidia.sm120_emu;
const qmd = nvidia.qmd;
const push = nvidia.push;
const device = nvidia.device;

/// Print each kernel's size and registers from the text test.
const PRINT_SIZES = false;

const T = struct {
    var arena: [20 << 20]u8 align(4096) = undefined;
    var gpu_view: [20 << 20]u8 align(4096) = undefined;
    var dev: device.EmuDevice = undefined;
    var work: emu.Work = .{};
    var asm_work: sm120_asm.Work = .{};
    var code: [2 * sm120_asm.MAX_INSTRS]u64 = undefined;
    /// NAK's level (what sm120_sched guarantees); off: the hardware's.
    var strict: bool = true;
};

fn fresh() device.Device {
    T.dev = .{ .arena = &T.arena, .gpu_view = &T.gpu_view, .work = &T.work, .tpcs = 1 };
    return T.dev.device();
}

const Kernel = struct { code: device.Buffer, bytes: usize, registers: u32, params: u32 };

fn load(d: device.Device, text: []const u8) !Kernel {
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    try testing.expect(k.scheduled);
    const b = try d.alloc(k.code.len * 8 + 4096);
    @memcpy(@as([]u64, @alignCast(std.mem.bytesAsSlice(u64, b.cpu[0 .. k.code.len * 8]))), k.code);
    d.toDevice(b, 0, b.cpu.len);
    return .{ .code = b, .bytes = k.code.len * 8, .registers = k.registers, .params = k.params };
}

/// One launch as Galaxy's runBatch makes it, run and waited for. A CTA
/// stride runs only every stride-th CTA (a big grid sampled).
fn launch(d: device.Device, k: Kernel, s: Shape, params: anytype, stride: u64) !void {
    const bytes = std.mem.asBytes(params);
    try testing.expectEqual(@as(usize, k.params), bytes.len);
    const slot = try d.alloc(0x800);
    const q: *[qmd.QMD_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0..qmd.QMD_BYTES]));
    try qmd.build(q, .{ .prog_va = k.code.va, .prog_bytes = k.bytes, .cbuf_va = slot.va + 0x200, .registers = k.registers, .grid = s.grid, .block = s.block, .shared_bytes = s.shared });
    const c0: *[qmd.CBUF0_WORDS]u32 = @ptrCast(@alignCast(slot.cpu[0x200..][0..qmd.CBUF0_BYTES]));
    try qmd.cbuf0(c0, s.grid, s.block, bytes);
    d.toDevice(slot, 0, slot.cpu.len);
    const sem = try d.alloc(16);
    const pb = try d.alloc(4096);
    const n = try push.batchPush(pb.words(), &.{slot.va}, null, sem.va, 0x600d);
    T.work.strict = T.strict;
    defer T.work.strict = false;
    T.dev.cta_stride = stride;
    defer T.dev.cta_stride = 1;
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

fn uniform(seed: *u32) f32 {
    return @as(f32, @floatFromInt(lcg(seed) >> 8)) / 16777216.0;
}

fn upload(d: device.Device, b: device.Buffer) void {
    d.toDevice(b, 0, b.cpu.len);
}

fn f32s(b: device.Buffer) []f32 {
    return @alignCast(std.mem.bytesAsSlice(f32, b.cpu));
}

const Weights = enum {
    random,
    /// Random, with some blocks all zero.
    zero_blocks,
    /// Every 6-bit scale and minimum 63 (Q4_K), every scale -128 or 127
    /// (Q6_K), d and dmin up to 65504.
    max_scales,
};

/// A sane f16 scale: 2^-10 to 2^-6.
fn smallHalf(seed: *u32) u16 {
    return @intCast(0x1400 + (lcg(seed) >> 22));
}

fn fillWeights(comptime format: Format, w: []u8, rows: u32, blocks: u32, seed: *u32, mode: Weights) void {
    const bb: usize = switch (format) {
        .q4_k => Q4_K_BLOCK,
        .q6_k => Q6_K_BLOCK,
        .q8_0 => Q8_0_BLOCK,
    };
    for (w) |*b| b.* = @truncate(lcg(seed) >> 13);
    for (0..rows * blocks) |blk| {
        const b = w[blk * bb ..][0..bb];
        switch (format) {
            .q4_k => {
                std.mem.writeInt(u16, b[0..2], smallHalf(seed), .little);
                std.mem.writeInt(u16, b[2..4], smallHalf(seed), .little);
                if (mode == .max_scales) {
                    @memset(b[4..16], 0xff);
                    std.mem.writeInt(u16, b[0..2], if (blk % 2 == 0) 0x7bff else 0x5bff, .little);
                    std.mem.writeInt(u16, b[2..4], 0x7bff, .little);
                }
            },
            .q6_k => {
                std.mem.writeInt(u16, b[208..210], smallHalf(seed), .little);
                if (mode == .max_scales) {
                    for (b[192..208], 0..) |*s, i| s.* = if ((i + blk) % 3 == 0) 0x80 else 0x7f;
                    std.mem.writeInt(u16, b[208..210], 0x7bff, .little);
                }
            },
            .q8_0 => {
                const sign: u16 = @intCast((lcg(seed) >> 7) & 1);
                std.mem.writeInt(u16, b[0..2], smallHalf(seed) | (sign << 15), .little);
                for (b[2..]) |*q| q.* = @bitCast(@as(i8, @intCast(@as(i32, @intCast((lcg(seed) >> 8) % 255)) - 127)));
                if (mode == .max_scales) std.mem.writeInt(u16, b[0..2], 0x7bff | (sign << 15), .little);
            },
        }
        if (mode == .zero_blocks and (blk % 5 == 1 or blk % 7 == 3)) @memset(b, 0);
    }
}

/// Activations of `tokens` rows of `k`: random in [-1.5, 1.5), a zero block
/// in the second token, ties of magnitude.
fn fillInputs(x: []f32, tokens: u32, k: u32, block: u32, seed: *u32) void {
    for (x, 0..) |*v, i| {
        v.* = (uniform(seed) - 0.5) * 3.0;
        if (i % 613 == 7) v.* = 2.25;
        if (i % 613 == 11) v.* = -2.25;
    }
    if (tokens > 1 and k >= 2 * block) @memset(x[k + block ..][0..block], 0);
}

const MAX_TEST_BLOCKS = MAX_TOKENS * 64;

fn runMatrix(comptime format: Format, comptime tokens: u32, rows: u32, blocks: u32, mode: Weights, stride: u64) !void {
    const d = fresh();
    const bb: u32 = switch (format) {
        .q4_k => Q4_K_BLOCK,
        .q6_k => Q6_K_BLOCK,
        .q8_0 => Q8_0_BLOCK,
    };
    const qk: u32 = if (format == .q8_0) QK8_0 else QK_K;
    const k_cols = blocks * qk;
    const row_bytes = blocks * bb;
    var seed: u32 = 0x5eed + rows * 31 + blocks * 7 + tokens;
    // (16 bytes readable past the last row)
    const w = try d.alloc(rows * row_bytes + 16);
    fillWeights(format, w.cpu[0 .. rows * row_bytes], rows, blocks, &seed, mode);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const abs = try d.alloc(tokens * blocks * 32);
    const out = try d.alloc(tokens * rows * 4);
    var x: [MAX_TOKENS * 8192]f32 = undefined;
    fillInputs(x[0 .. tokens * k_cols], tokens, k_cols, qk, &seed);
    const S = struct {
        var q8k: [MAX_TEST_BLOCKS]quantized.Q8KBlock = undefined;
        var q80: [MAX_TOKENS * 256]quantized.Q80Block = undefined;
    };
    const vq = std.mem.bytesAsSlice(i8, aq.cpu);
    const vd = f32s(ad);
    if (format == .q8_0) {
        try quantized.quantizeQ80(x[0 .. tokens * k_cols], S.q80[0 .. tokens * blocks]);
        for (S.q80[0 .. tokens * blocks], 0..) |b, i| {
            @memcpy(vq[i * QK8_0 ..][0..QK8_0], &b.qs);
            vd[i] = b.d;
        }
    } else {
        try quantized.quantizeQ8K(x[0 .. tokens * k_cols], S.q8k[0 .. tokens * blocks]);
        const vs: []i16 = @alignCast(std.mem.bytesAsSlice(i16, abs.cpu));
        for (S.q8k[0 .. tokens * blocks], 0..) |b, i| {
            @memcpy(vq[i * QK_K ..][0..QK_K], &b.qs);
            vd[i] = b.d;
            @memcpy(vs[i * 16 ..][0..16], &b.bsums);
        }
    }
    @memset(out.cpu, 0xee);
    for ([_]device.Buffer{ w, aq, ad, abs, out }) |b| upload(d, b);
    const src = comptime switch (format) {
        .q4_k => q4kMatrix(tokens),
        .q6_k => q6kMatrix(tokens),
        .q8_0 => q80Matrix(tokens),
    };
    const k = try load(d, src);
    const shape = try matrixLaunch(format, tokens, rows, blocks);
    const p = MatrixParams{ .weights = w.va, .act_q = aq.va, .act_d = ad.va, .act_sums = if (format == .q8_0) 0 else abs.va, .out = out.va, .row_bytes = row_bytes, .blocks = blocks, .rows = rows, .out_stride = rows * 4 };
    try launch(d, k, shape, &p, stride);
    d.fromDevice(out, 0, out.cpu.len);
    const got = f32s(out);
    var mismatches: usize = 0;
    var checked: usize = 0;
    for (0..rows) |row| {
        const ran = (row / ROWS_PER_CTA) % stride == 0;
        const wrow = w.cpu[row * row_bytes ..][0..row_bytes];
        for (0..tokens) |tok| {
            const g = got[tok * rows + row];
            if (!ran) {
                try testing.expectEqual(@as(u32, 0xeeeeeeee), @as(u32, @bitCast(g)));
                continue;
            }
            const want = switch (format) {
                .q4_k => quantized.dotQ4KQ8KTile(1, wrow, .{S.q8k[tok * blocks ..].ptr}, blocks)[0],
                .q6_k => quantized.dotQ6KQ8KTile(1, wrow, .{S.q8k[tok * blocks ..].ptr}, blocks)[0],
                .q8_0 => quantized.dotQ80Q80Tile(1, wrow, .{S.q80[tok * blocks ..].ptr}, blocks)[0],
            };
            checked += 1;
            if (@as(u32, @bitCast(g)) != @as(u32, @bitCast(want))) {
                if (mismatches < 5) std.debug.print("{s} row {d} token {d}: {e} want {e}\n", .{ @tagName(format), row, tok, g, want });
                mismatches += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
    try testing.expect(checked > 0);
}

test "Q4_K x Q8_K, one token: bit-exact with dotQ4KQ8KTile (33 rows: a last CTA of one; a 9-block row: a tile and a block)" {
    try runMatrix(.q4_k, 1, 33, 9, .random, 1);
}

test "Q4_K x Q8_K, two and eight tokens: bit-exact (a zero activation block)" {
    try runMatrix(.q4_k, 2, 21, 8, .random, 1);
    try runMatrix(.q4_k, 8, 16, 3, .random, 1);
}

test "Q4_K x Q8_K edge cases: all-zero weight blocks, maximum scales and minimums" {
    try runMatrix(.q4_k, 1, 7, 4, .zero_blocks, 1);
    try runMatrix(.q4_k, 3, 5, 2, .max_scales, 1);
}

test "Q6_K x Q8_K, one token: bit-exact with dotQ6KQ8KTile (every block's offset in its tile)" {
    try runMatrix(.q6_k, 1, 35, 8, .random, 1);
    try runMatrix(.q6_k, 1, 3, 16, .random, 1);
}

test "Q6_K x Q8_K, four and eight tokens; zero blocks; scales of -128 and 127" {
    try runMatrix(.q6_k, 4, 9, 8, .random, 1);
    try runMatrix(.q6_k, 8, 4, 8, .zero_blocks, 1);
    try runMatrix(.q6_k, 2, 5, 8, .max_scales, 1);
}

test "Q8_0 x Q8_0: bit-exact with dotQ80Q80Tile (37 blocks: odd rows of any alignment; two tiles)" {
    try runMatrix(.q8_0, 1, 21, 37, .random, 1);
    try runMatrix(.q8_0, 3, 9, 72, .random, 1);
    try runMatrix(.q8_0, 8, 4, 16, .zero_blocks, 1);
    try runMatrix(.q8_0, 1, 6, 8, .max_scales, 1);
}

test "a big matrix sampled with the CTA stride: Q4_K and Q6_K decode at LFM3's width" {
    try runMatrix(.q4_k, 1, 2048, 8, .random, 13);
    try runMatrix(.q6_k, 1, 1024, 8, .random, 11);
}

test "the hardware's level of hazard checking too" {
    T.strict = false;
    defer T.strict = true;
    try runMatrix(.q4_k, 1, 32, 2, .random, 1);
    try runMatrix(.q6_k, 2, 32, 8, .random, 1);
    try runMatrix(.q8_0, 1, 32, 5, .random, 1);
}

fn runQuant(comptime norm: bool, tokens: u32, comptime k_cols: u32) !void {
    const d = fresh();
    const blocks = k_cols / QK_K;
    const xb = try d.alloc(tokens * k_cols * 4);
    const wb = try d.alloc(k_cols * 4);
    const yb = try d.alloc(tokens * k_cols * 4);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    const abs = try d.alloc(tokens * blocks * 32);
    var seed: u32 = 5 + k_cols;
    const x = f32s(xb);
    const w = f32s(wb);
    for (x, 0..) |*v, i| {
        v.* = (uniform(&seed) - 0.5) * 6.0;
        // a block of zeros; ties of magnitude of either sign; tiny values
        if (i / QK_K == 1) v.* = 0;
        if (i % 997 == 5) v.* = 9.0;
        if (i % 997 == 9) v.* = -9.0;
        if (i % 251 == 3) v.* = 1e-3;
    }
    for (w) |*v| v.* = 0.5 + uniform(&seed);
    for ([_]device.Buffer{ xb, wb, yb, aq, ad, abs }) |b| upload(d, b);
    const k = try load(d, comptime q8kQuant(norm, k_cols / QK_K));
    var p = QuantParams.of(xb.va, aq.va, ad.va, abs.va, k_cols);
    p.norm_weight = wb.va;
    p.normalized = yb.va;
    p.epsilon = 1e-5;
    try launch(d, k, try quantLaunch(norm, tokens, k_cols), &p, 1);
    for ([_]device.Buffer{ yb, aq, ad, abs }) |b| d.fromDevice(b, 0, b.cpu.len);
    const y = f32s(yb);
    if (norm) {
        // lfm3_executor's RMSNorm: squares summed in f64
        var worst: f64 = 0;
        for (0..tokens) |tok| {
            var squares: f64 = 0;
            for (x[tok * k_cols ..][0..k_cols]) |v| squares += @as(f64, v) * v;
            const mean: f32 = @floatCast(squares / @as(f64, @floatFromInt(k_cols)));
            const inverse = 1.0 / @sqrt(mean + 1e-5);
            for (0..k_cols) |i| {
                const want = x[tok * k_cols + i] * inverse * w[i];
                worst = @max(worst, @abs(@as(f64, y[tok * k_cols + i]) - want) / @max(@abs(@as(f64, want)), 1e-3));
            }
        }
        try testing.expect(worst < 2e-6);
    }
    const S = struct {
        var cpu: [MAX_TEST_BLOCKS]quantized.Q8KBlock = undefined;
    };
    try quantized.quantizeQ8K((if (norm) y else x)[0 .. tokens * k_cols], S.cpu[0 .. tokens * blocks]);
    const gq = std.mem.bytesAsSlice(i8, aq.cpu);
    const gd = f32s(ad);
    const gs: []const i16 = @alignCast(std.mem.bytesAsSlice(i16, abs.cpu));
    for (S.cpu[0 .. tokens * blocks], 0..) |b, i| {
        if (@as(u32, @bitCast(b.d)) != @as(u32, @bitCast(gd[i]))) {
            std.debug.print("block {d}: d {e} want {e}\n", .{ i, gd[i], b.d });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualSlices(i8, &b.qs, gq[i * QK_K ..][0..QK_K]);
        try testing.expectEqualSlices(i16, &b.bsums, gs[i * 16 ..][0..16]);
    }
}

test "Q8_K quantization: bit-exact with quantizeQ8K (a zero block, magnitude ties, 5 blocks: a part-empty CTA)" {
    try runQuant(false, 3, 5 * QK_K);
}

test "RMSNorm then Q8_K: the norm within 2e-6 of the CPU's, the quantization of what it wrote bit-exact" {
    try runQuant(true, 2, 2048);
    try runQuant(true, 1, 6 * QK_K);
}

fn runQ80Quant(tokens: u32, k_cols: u32) !void {
    const d = fresh();
    const blocks = k_cols / QK8_0;
    const xb = try d.alloc(tokens * k_cols * 4);
    const aq = try d.alloc(tokens * k_cols);
    const ad = try d.alloc(tokens * blocks * 4);
    var seed: u32 = 11;
    const x = f32s(xb);
    for (x, 0..) |*v, i| {
        v.* = (uniform(&seed) - 0.5) * 6.0;
        // a zero block, ties of magnitude, values on the half steps
        if (i / QK8_0 == 2) v.* = 0;
        if (i % 331 == 5) v.* = 9.0;
        if (i % 331 == 9) v.* = -9.0;
        if (i % 331 == 13) v.* = 9.0 * 2.5 / 127.0;
    }
    upload(d, xb);
    upload(d, aq);
    upload(d, ad);
    const k = try load(d, comptime q80Quant());
    const p = Q80QuantParams{ .x = xb.va, .act_q = aq.va, .act_d = ad.va, .k = k_cols };
    try launch(d, k, try q80QuantLaunch(tokens, k_cols), &p, 1);
    d.fromDevice(aq, 0, aq.cpu.len);
    d.fromDevice(ad, 0, ad.cpu.len);
    const S = struct {
        var cpu: [4 * 128]quantized.Q80Block = undefined;
    };
    try quantized.quantizeQ80(x[0 .. tokens * k_cols], S.cpu[0 .. tokens * blocks]);
    const gq = std.mem.bytesAsSlice(i8, aq.cpu);
    const gd = f32s(ad);
    for (S.cpu[0 .. tokens * blocks], 0..) |b, i| {
        if (@as(u32, @bitCast(b.d)) != @as(u32, @bitCast(gd[i]))) {
            std.debug.print("block {d}: d {e} want {e}\n", .{ i, gd[i], b.d });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualSlices(i8, &b.qs, gq[i * QK8_0 ..][0..QK8_0]);
    }
}

test "Q8_0 quantization: bit-exact with quantizeQ80 (a zero block, ties, a last part-empty CTA)" {
    try runQ80Quant(3, 32 * 37);
}

test "launch shapes: grids, blocks, shared bytes; shapes the kernels do not take" {
    const s = try matrixLaunch(.q4_k, 1, 2048, 8);
    try testing.expectEqual([3]u32{ 64, 1, 1 }, s.grid);
    try testing.expectEqual([3]u32{ 64, 1, 1 }, s.block);
    try testing.expectEqual(@as(u32, 2336), s.shared);
    try testing.expectEqual(@as(u32, 8 * 2304), (try matrixLaunch(.q8_0, 8, 33, 37)).shared);
    try testing.expectEqual([3]u32{ 2, 1, 1 }, (try matrixLaunch(.q8_0, 8, 33, 37)).grid);
    try testing.expectError(error.Unsupported, matrixLaunch(.q6_k, 1, 64, 9));
    try testing.expectError(error.Unsupported, matrixLaunch(.q4_k, 9, 64, 8));
    try testing.expectError(error.Unsupported, matrixLaunch(.q4_k, 0, 64, 8));
    try testing.expectError(error.Unsupported, matrixLaunch(.q4_k, 1, 0, 8));
    const qn = try quantLaunch(true, 3, 2048);
    try testing.expectEqual([3]u32{ 1, 3, 1 }, qn.grid);
    try testing.expectEqual([3]u32{ 256, 1, 1 }, qn.block);
    try testing.expectEqual([3]u32{ 2, 3, 1 }, (try quantLaunch(false, 3, 5 * 256)).grid);
    try testing.expectError(error.Unsupported, quantLaunch(true, 1, 33 * 256));
    try testing.expectError(error.Unsupported, quantLaunch(false, 1, 100));
    try testing.expectEqual([3]u32{ 2, 4, 1 }, (try q80QuantLaunch(4, 32 * 37)).grid);
    try testing.expectError(error.Unsupported, q80QuantLaunch(1, 48));
    // (every shape fits the QMD's shared memory)
    _ = try qmd.sharedTotal((try matrixLaunch(.q6_k, 8, 1, 8)).shared);
    // the run-time selectors
    try testing.expectEqualStrings(q6kMatrix(3), try matrixSource(.q6_k, 3));
    try testing.expectEqualStrings(q80Matrix(8), try matrixSource(.q8_0, 8));
    try testing.expectError(error.Unsupported, matrixSource(.q4_k, 0));
    try testing.expectError(error.Unsupported, matrixSource(.q4_k, 9));
    try testing.expectEqualStrings(q8kQuant(true, 8), try q8kQuantSource(true, 8));
    try testing.expectEqualStrings(q8kQuant(false, 1), try q8kQuantSource(false, 3));
    try testing.expectError(error.Unsupported, q8kQuantSource(true, 6));
}

/// A kernel's text: every form the emulator runs, assembled by sm120_asm
/// with its schedule leaving nothing open by sm120_sched's own check, every
/// word decoding and printing back as the line it came from.
fn checkText(name: []const u8, text: []const u8) !void {
    try emu.loadText(&T.work, text);
    for (T.work.ops[0..T.work.n_ops]) |op| try testing.expect(op.kind != .unsupported and op.kind != .invalid);
    const k = try sm120_asm.assemble(text, &T.code, &T.asm_work);
    try testing.expect(k.scheduled);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var t = raw;
        if (std.mem.indexOf(u8, t, "//")) |c| t = t[0..c];
        t = std.mem.trim(u8, t, " \t\r");
        if (t.len == 0 or t[0] == '.' or t[t.len - 1] == ':') continue;
        const slot: usize = @intCast(T.asm_work.at[n] / 16);
        const dec = try sm120.decode(k.code[2 * slot], k.code[2 * slot + 1], slot * 16);
        var buf: [160]u8 = undefined;
        const printed = try sm120.format(&dec, &buf);
        if (T.asm_work.instrs[n].label() == null) try testing.expectEqualStrings(t, printed[22..]);
        n += 1;
    }
    const rep = try sched.check(T.asm_work.instrs[0..n], T.asm_work.slots[0..n], &T.asm_work.sched);
    try testing.expectEqual(@as(u32, 0), rep.open);
    if (PRINT_SIZES) std.debug.print("{s}: {d} instructions (scheduled: {d}), {d} registers\n", .{ name, n, k.count, k.registers });
}

test "every kernel's text: forms the emulator runs, assembled by sm120_asm, decoded back to its lines" {
    inline for (1..MAX_TOKENS + 1) |tok| {
        try checkText(std.fmt.comptimePrint("q4k x{d}", .{tok}), comptime q4kMatrix(tok));
        try checkText(std.fmt.comptimePrint("q6k x{d}", .{tok}), comptime q6kMatrix(tok));
        try checkText(std.fmt.comptimePrint("q80 x{d}", .{tok}), comptime q80Matrix(tok));
    }
    try checkText("q8k quant", comptime q8kQuant(false, 1));
    inline for (.{ 1, 6, 8, 16, 32 }) |w| try checkText(std.fmt.comptimePrint("rmsnorm q8k x{d}", .{w}), comptime q8kQuant(true, w));
    try checkText("q80 quant", comptime q80Quant());
    // (a CTA of 32 warps fits the SM's registers)
    const k = try sm120_asm.assemble(comptime q8kQuant(true, 32), &T.code, &T.asm_work);
    try testing.expect(k.registers * 1024 <= emu.SM_REGISTERS);
}
