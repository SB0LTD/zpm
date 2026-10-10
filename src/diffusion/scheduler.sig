// @zpm/diffusion — Sampling schedulers (noise → clean latent integration).
//
// Pure, allocation-free numerics. The scheduler owns the timestep grid and the
// per-step update rule; the denoiser only supplies a model prediction at each
// step. This is fully implemented (it is closed-form math), unlike the neural
// denoiser/VAE which need the model weights.
//
// Two families are provided:
//   - flow_match  : rectified-flow / flow-matching (Flux / Qwen-Image class).
//                   The model predicts velocity v; latent moves x -= dt*v along
//                   a straight sigma schedule from 1→0.
//   - euler       : classic ε-prediction Euler (Karras-style sigma schedule).
//   - ddim        : deterministic DDIM update on the same sigma grid.

const math = @import("sig_math");

pub const Kind = enum {
    flow_match,
    euler,
    ddim,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .flow_match => "flow-match",
            .euler => "euler",
            .ddim => "ddim",
        };
    }
};

pub const MAX_STEPS: usize = 200;

pub const Scheduler = struct {
    kind: Kind = .flow_match,
    n_steps: usize = 20,
    /// sigmas[0..n_steps+1]: noise level at each boundary, decreasing to 0.
    sigmas: [MAX_STEPS + 1]f32 = @splat(0),

    /// Build the sigma grid for `steps` steps. `shift` biases the schedule
    /// toward earlier (structure) or later (detail) timesteps; Qwen-Image/Flux
    /// use a resolution-dependent shift (~3.0 at 1024px).
    pub fn init(kind: Kind, steps: usize, shift: f32) Scheduler {
        var s = Scheduler{ .kind = kind, .n_steps = @min(steps, MAX_STEPS) };
        const n = s.n_steps;
        var i: usize = 0;
        while (i <= n) : (i += 1) {
            // Linear t in (0,1], then apply the flow shift transform.
            const t = 1.0 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            s.sigmas[i] = switch (kind) {
                .flow_match => flowShift(t, shift),
                .euler, .ddim => karrasSigma(t),
            };
        }
        s.sigmas[n] = 0.0;
        return s;
    }

    /// dt for the step from index `i` to `i+1` (negative: sigma decreases).
    pub fn dt(self: *const Scheduler, i: usize) f32 {
        return self.sigmas[i + 1] - self.sigmas[i];
    }

    pub fn sigma(self: *const Scheduler, i: usize) f32 {
        return self.sigmas[i];
    }

    /// The timestep value fed to the model at step `i`. Flow models condition
    /// on sigma directly (scaled to 0..1000); ε-models on the sigma itself.
    pub fn timestep(self: *const Scheduler, i: usize) f32 {
        return switch (self.kind) {
            .flow_match => self.sigmas[i] * 1000.0,
            .euler, .ddim => self.sigmas[i],
        };
    }

    /// Advance one latent element given the model prediction at step `i`.
    /// `pred` is velocity (flow_match) or noise ε (euler/ddim).
    /// Returns the updated latent value.
    pub fn step(self: *const Scheduler, i: usize, x: f32, pred: f32) f32 {
        return switch (self.kind) {
            .flow_match => x + self.dt(i) * pred, // straight-line ODE: x += dt*v
            .euler => blk: {
                const d = pred; // ε ≈ (x - denoised)/sigma already folded by caller
                break :blk x + self.dt(i) * d;
            },
            .ddim => blk: {
                const s0 = self.sigmas[i];
                const s1 = self.sigmas[i + 1];
                if (s0 == 0) break :blk x;
                // x1 = x0 * (s1/s0) + pred * (s1 - s0) ... simplified DDIM.
                break :blk x * (s1 / s0) + pred * (s1 - s0);
            },
        };
    }
};

/// Flow-matching shift: pushes the effective sigma toward structure-first
/// sampling. shift=1 is the identity; higher shift spends more steps at high
/// noise. Matches the diffusers "FlowMatchEulerDiscreteScheduler" transform.
fn flowShift(t: f32, shift: f32) f32 {
    if (shift <= 1.0) return t;
    return (shift * t) / (1.0 + (shift - 1.0) * t);
}

/// Karras-style sigma at normalized position t∈[0,1] with sensible min/max for
/// latent diffusion (sigma_min≈0.03, sigma_max≈14.6, rho=7).
fn karrasSigma(t: f32) f32 {
    const sigma_min: f32 = 0.0292;
    const sigma_max: f32 = 14.6146;
    const rho: f32 = 7.0;
    const inv_rho = 1.0 / rho;
    const a = math.pow(sigma_max, inv_rho);
    const b = math.pow(sigma_min, inv_rho);
    const v = b + t * (a - b);
    return math.pow(v, rho);
}

test "flow-match sigmas decrease to zero" {
    const std = @import("std");
    const s = Scheduler.init(.flow_match, 10, 3.0);
    try std.testing.expectEqual(@as(usize, 10), s.n_steps);
    try std.testing.expect(s.sigma(0) > s.sigma(9));
    try std.testing.expectEqual(@as(f32, 0.0), s.sigma(10));
}

test "flow-match step integrates velocity" {
    const std = @import("std");
    const s = Scheduler.init(.flow_match, 4, 1.0);
    // With shift=1 sigma is linear 1..0; dt(0) = -0.25.
    const x1 = s.step(0, 1.0, 2.0);
    try std.testing.expect(x1 < 1.0); // moved toward the clean estimate
}

test "kind labels" {
    const std = @import("std");
    try std.testing.expectEqualStrings("flow-match", Kind.flow_match.label());
    try std.testing.expectEqualStrings("ddim", Kind.ddim.label());
}
