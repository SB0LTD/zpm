//! Gated-DeltaNet (GDN) recurrent decode step — pure host reference (Layer 0).
//!
//! This is the numerical oracle for the fused CUDA `gdn_step` kernel. It
//! implements the Qwen3-Next / Qwen3.5 gated delta rule for a SINGLE token
//! given already-projected inputs, mutating the caller-owned recurrent state.
//! It performs no I/O, no allocation, and no matmuls (those are separate,
//! already-validated matvec kernels) — only the per-head recurrence, gating,
//! L2-norm, and gated output RMSNorm.
//!
//! Recurrence (coreai-torch GatedDeltaUpdate, matches Qwen3-Next):
//!   retrieved[dv] = sum_dk k[dk] * S[dk][dv]
//!   delta[dv]     = v[dv] - retrieved[dv]
//!   S[dk][dv]     = g * S[dk][dv] + beta * k[dk] * delta[dv]
//!   o[dv]         = sum_dk q[dk] * S[dk][dv]
//! with q,k L2-normalized per head first. g = exp(-exp(A_log)*softplus(a+dt)),
//! beta = sigmoid(b). K/Q heads repeat_interleave to match V heads.
//!
//! Then a gated RMSNorm produces the mixer output per v-head:
//!   o_out[dv] = rmsnorm(o, ssm_norm_weight)[dv] * silu(z[dv])
//!
//! Dimensions (4B distill): kq_heads=16, v_heads=32, head_dim=128 (D_k=D_v).

const math = @import("sig_math");

pub const Error = error{ InvalidDimensions, StateCapacity };

/// Hard caps sized for the 4B distill; fixed storage, no allocation.
pub const MAX_V_HEADS: usize = 64;
pub const MAX_HEAD_DIM: usize = 256;
pub const MAX_STATE: usize = MAX_V_HEADS * MAX_HEAD_DIM * MAX_HEAD_DIM;

pub const GdnDims = struct {
    kq_heads: usize, // Q and K head count (16)
    v_heads: usize, // V and output head count (32)
    head_dim: usize, // per-head dim, D_k == D_v (128)

    pub fn valid(self: GdnDims) bool {
        return self.kq_heads != 0 and self.v_heads != 0 and self.head_dim != 0 and
            self.v_heads <= MAX_V_HEADS and self.head_dim <= MAX_HEAD_DIM and
            self.v_heads % self.kq_heads == 0 and
            self.v_heads * self.head_dim * self.head_dim <= MAX_STATE;
    }
    /// Number of f32 elements in the recurrent state (v_heads * D_k * D_v).
    pub fn stateElements(self: GdnDims) usize {
        return self.v_heads * self.head_dim * self.head_dim;
    }
    pub fn qkDim(self: GdnDims) usize {
        return self.kq_heads * self.head_dim;
    }
    pub fn vDim(self: GdnDims) usize {
        return self.v_heads * self.head_dim;
    }
};

pub fn silu(x: f32) f32 {
    return x / (1.0 + @exp(-x));
}

pub fn softplus(x: f32) f32 {
    // Numerically-stable log(1+exp(x)).
    if (x > 20.0) return x;
    if (x < -20.0) return @exp(x);
    return @log(1.0 + @exp(x));
}

/// L2-normalize `v` in place (over its own length).
pub fn l2normInPlace(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    const inv = 1.0 / @sqrt(sum + 1.0e-6);
    for (v) |*x| x.* *= inv;
}

/// One GDN recurrent step (reference). Inputs are already conv+SiLU'd and split.
/// - q, k: length kq_heads*head_dim (will be L2-normed per head, copies used)
/// - v:    length v_heads*head_dim
/// - z:    length v_heads*head_dim (output gate, pre-activation)
/// - a_raw, b_raw: length v_heads (alpha, beta projections)
/// - a_log, dt_bias: length v_heads (ssm_a, ssm_dt.bias)
/// - ssm_norm_w: length head_dim (gated RMSNorm weight)
/// - state: v_heads*head_dim*head_dim f32, layout [head][dk][dv]; mutated
/// - out:  length v_heads*head_dim, receives the gated-normed mixer output
pub fn step(
    dims: GdnDims,
    q_in: []const f32,
    k_in: []const f32,
    v: []const f32,
    z: []const f32,
    a_raw: []const f32,
    b_raw: []const f32,
    a_coeff: []const f32, // GGUF ssm_a = -exp(A_log), the decay coefficient
    dt_bias: []const f32,
    ssm_norm_w: []const f32,
    rms_eps: f32,
    state: []f32,
    out: []f32,
) Error!void {
    if (!dims.valid()) return error.InvalidDimensions;
    const hd = dims.head_dim;
    if (q_in.len != dims.qkDim() or k_in.len != dims.qkDim() or v.len != dims.vDim() or
        z.len != dims.vDim() or out.len != dims.vDim() or
        a_raw.len != dims.v_heads or b_raw.len != dims.v_heads or
        a_coeff.len != dims.v_heads or dt_bias.len != dims.v_heads or
        ssm_norm_w.len != hd) return error.InvalidDimensions;
    if (state.len < dims.stateElements()) return error.StateCapacity;

    var qh: [MAX_HEAD_DIM]f32 = undefined;
    var kh: [MAX_HEAD_DIM]f32 = undefined;
    var oh: [MAX_HEAD_DIM]f32 = undefined;

    for (0..dims.v_heads) |h| {
        // qwen35 uses a plain repeat (tile), not repeat_interleave, to expand the
        // num_k_heads Q/K heads to num_v_heads: v-head h uses kq-head (h % kq_heads).
        const kq = h % dims.kq_heads;
        // Copy + L2-norm this head's q and k.
        @memcpy(qh[0..hd], q_in[kq * hd ..][0..hd]);
        @memcpy(kh[0..hd], k_in[kq * hd ..][0..hd]);
        l2normInPlace(qh[0..hd]);
        l2normInPlace(kh[0..hd]);
        // Qwen3-Next scales the query by 1/sqrt(head_dim) after L2-norm (key is
        // not scaled). Matches torch_recurrent_gated_delta_rule.
        const qscale = 1.0 / @sqrt(@as(f32, @floatFromInt(hd)));
        for (qh[0..hd]) |*x| x.* *= qscale;

        // llama.cpp bakes ssm_a = -exp(A_log) into the GGUF (SSM_A_NOSCAN), so
        // the log-decay is g_log = ssm_a * softplus(a_raw + dt_bias) and the
        // per-step decay multiplier is exp(g_log). (`a_coeff` carries ssm_a.)
        const g = @exp(a_coeff[h] * softplus(a_raw[h] + dt_bias[h]));
        const beta = 1.0 / (1.0 + @exp(-b_raw[h])); // sigmoid

        const base = h * hd * hd; // state[base + dk*hd + dv]
        const vv = v[h * hd ..][0..hd];

        // Gated delta rule (order matches torch_recurrent_gated_delta_rule):
        //   1. decay:      S = g * S
        //   2. retrieve:   retrieved[dv] = sum_dk k[dk] * S[dk][dv]  (DECAYED S)
        //   3. delta:      delta[dv] = (v[dv] - retrieved[dv]) * beta
        //   4. update:     S[dk][dv] += k[dk] * delta[dv]
        //   5. output:     o[dv] = sum_dk q[dk] * S[dk][dv]
        for (0..hd) |dk| {
            const row = base + dk * hd;
            for (0..hd) |dv| state[row + dv] *= g;
        }
        var retrieved: [MAX_HEAD_DIM]f32 = undefined;
        for (0..hd) |dv| {
            var acc: f32 = 0;
            for (0..hd) |dk| acc += kh[dk] * state[base + dk * hd + dv];
            retrieved[dv] = acc;
        }
        for (0..hd) |dv| oh[dv] = 0;
        for (0..hd) |dk| {
            const kdk = kh[dk];
            const qdk = qh[dk];
            const row = base + dk * hd;
            for (0..hd) |dv| {
                const delta = (vv[dv] - retrieved[dv]) * beta;
                const s = state[row + dv] + kdk * delta;
                state[row + dv] = s;
                oh[dv] += qdk * s;
            }
        }
        // Gated RMSNorm: rmsnorm(o) * silu(z), per head.
        var ss: f32 = 0;
        for (0..hd) |dv| ss += oh[dv] * oh[dv];
        const inv = 1.0 / @sqrt(ss / @as(f32, @floatFromInt(hd)) + rms_eps);
        const zh = z[h * hd ..][0..hd];
        const oo = out[h * hd ..][0..hd];
        for (0..hd) |dv| oo[dv] = (oh[dv] * inv * ssm_norm_w[dv]) * silu(zh[dv]);
        if (dbg_capture_o and h == dbg_capture_head) {
            for (0..@min(hd, dbg_o.len)) |dv| dbg_o[dv] = oh[dv];
        }
    }
}

/// Debug: capture the raw per-head delta output `o` (pre gated-norm).
pub var dbg_capture_o: bool = false;
pub var dbg_capture_head: usize = 0;
pub var dbg_o: [MAX_HEAD_DIM]f32 = @splat(0);

// Tests — exercise the recurrence on a tiny deterministic case.

test "gdn dims and stateElements" {
    const d = GdnDims{ .kq_heads = 16, .v_heads = 32, .head_dim = 128 };
    if (!d.valid()) return error.TestUnexpectedResult;
    if (d.stateElements() != 32 * 128 * 128) return error.TestUnexpectedResult;
    if (d.qkDim() != 2048 or d.vDim() != 4096) return error.TestUnexpectedResult;
}

test "gdn step runs and is finite on a small case" {
    const d = GdnDims{ .kq_heads = 1, .v_heads = 1, .head_dim = 4 };
    var state: [1 * 4 * 4]f32 = @splat(0);
    var out: [4]f32 = @splat(0);
    const q = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const k = [_]f32{ 0.5, 0.1, 0.2, 0.1 };
    const v = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const z = [_]f32{ 0.5, 0.5, 0.5, 0.5 };
    const a_raw = [_]f32{0.1};
    const b_raw = [_]f32{0.0}; // sigmoid(0)=0.5
    const a_log = [_]f32{0.0};
    const dt_bias = [_]f32{0.0};
    const nw = [_]f32{ 1, 1, 1, 1 };
    try step(d, &q, &k, &v, &z, &a_raw, &b_raw, &a_log, &dt_bias, &nw, 1.0e-6, &state, &out);
    for (out) |x| if (!math.isFinite(x)) return error.TestUnexpectedResult;
    // First step from zero state: retrieved=0, delta=v, S=beta*k outer v.
    // o[dv] = sum_dk q_norm[dk]*S[dk][dv]; just assert non-trivial output.
    var any: bool = false;
    for (out) |x| any = any or (x != 0);
    if (!any) return error.TestUnexpectedResult;
}
