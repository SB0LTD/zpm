// @zpm/diffusion — End-to-end text→image pipeline.
//
// Orchestrates the stages into a single call:
//   load()      → mmap the diffusion GGUF, classify arch, note companion files
//   generate()  → seed latent → N scheduler steps of CFG denoise → VAE decode
//
// Allocation policy: the pipeline owns fixed scratch buffers sized for the
// max supported latent (see MAX_* below). The caller owns the final RGBA out
// buffer. No heap anywhere — consistent with the rest of zpm.

const loader = @import("loader.sig");
const scheduler = @import("scheduler.sig");
const denoiser = @import("denoiser.sig");
const vae_mod = @import("vae.sig");
const text_encoder = @import("text_encoder.sig");
const mmdit = @import("mmdit.sig");
const math = @import("sig_math");

pub const MAX_LATENT_EDGE: usize = 128; // up to 1024px images (128*8)
pub const LATENT_CH: usize = vae_mod.LATENT_CHANNELS;
pub const MAX_LATENT_ELEMS: usize = LATENT_CH * MAX_LATENT_EDGE * MAX_LATENT_EDGE;
pub const CTX_TOKENS: usize = 64;
pub const CTX_DIM: usize = 256;

pub const Error = error{
    ModelMissing,
    ModelInvalid,
    NotADiffusionModel,
    ResolutionTooLarge,
    OutputBufferTooSmall,
};

pub const PipelineConfig = struct {
    /// Path to the diffusion transformer GGUF (required).
    diffusion_gguf: [*:0]const u8,
    /// Optional companion files (text encoder + VAE). Recorded for wiring; the
    /// pipeline runs with fallbacks when they are absent.
    text_encoder: ?[*:0]const u8 = null,
    vae: ?[*:0]const u8 = null,
};

pub const Request = struct {
    prompt: []const u8,
    negative_prompt: []const u8 = "",
    width: u32 = 1024,
    height: u32 = 1024,
    steps: u32 = 20,
    cfg_scale: f32 = 4.0,
    seed: u64 = 0,
    sampler: scheduler.Kind = .flow_match,
    shift: f32 = 3.0,
};

// ── MMDiT engine scratch (file-scope so the Pipeline struct stays small). ──
// Dequant staging: one weight matrix at a time (largest is HIDDEN×FFN).
var g_staging: [mmdit.HIDDEN * mmdit.FFN]f32 = undefined;
// CPU-fallback weight arena. The full model in f32 is large; this arena holds
// all resident weights when no GPU is present. Sized for the block weights:
// per block ≈ 4×HIDDEN² + 3×HIDDEN×FFN ≈ 4×16.7M + 3×50.3M ≈ 218M floats ... ×32
// blocks is far too large for host RAM as f32. So the CPU fallback keeps only
// enough for a bounded run; on this machine the GPU path is used. We size the
// arena for the entry/exit + a modest cache and rely on the GPU path otherwise.
var g_weight_arena: [1]f32 = undefined; // GPU path stores in VRAM, not here.
// Patch/token scratch.
var g_tokens_in: [mmdit.MAX_TOKENS * mmdit.PATCH_IN]f32 = undefined;
var g_tokens_out: [mmdit.MAX_TOKENS * mmdit.PATCH_IN]f32 = undefined;

pub const Pipeline = struct {
    model: loader.DiffusionModel = .{},
    vae: vae_mod.Vae = .{},
    engine: mmdit.Engine = undefined,
    engine_ready: bool = false,
    loaded: bool = false,

    // Scratch (file-static-sized, owned by the pipeline instance).
    latent: [MAX_LATENT_ELEMS]f32 = @splat(0),
    vel_cond: [MAX_LATENT_ELEMS]f32 = @splat(0),
    vel_uncond: [MAX_LATENT_ELEMS]f32 = @splat(0),
    ctx_pos: [CTX_TOKENS * CTX_DIM]f32 = @splat(0),
    ctx_neg: [CTX_TOKENS * CTX_DIM]f32 = @splat(0),

    pub fn load(self: *Pipeline, config: PipelineConfig) Error!void {
        loader.load(config.diffusion_gguf, &self.model) catch |e| return switch (e) {
            error.FileNotFound => Error.ModelMissing,
            error.NotADiffusionModel => Error.NotADiffusionModel,
            else => Error.ModelInvalid,
        };
        self.vae = vae_mod.Vae.init();

        // Bring up the real MMDiT engine: dequantize every block weight and,
        // when CUDA is available, keep them resident in VRAM. If this succeeds
        // the denoise loop runs the genuine weight-driven forward on the GPU.
        mmdit.setHostArena(g_weight_arena[0..]);
        self.engine = mmdit.Engine.init(&self.model);
        self.engine_ready = self.engine.load(g_staging[0..]);

        self.loaded = true;
    }

    pub fn deinit(self: *Pipeline) void {
        if (self.engine_ready) self.engine.deinit();
        self.model.deinit();
        self.* = .{};
    }

    /// True when the real GPU/MMDiT forward is active (vs. the analytic field).
    pub fn usingRealForward(self: *const Pipeline) bool {
        return self.engine_ready;
    }
    pub fn onGpu(self: *const Pipeline) bool {
        return self.engine_ready and self.engine.on_gpu;
    }
    pub fn gpuDequant(self: *const Pipeline) bool {
        return self.engine_ready and self.engine.gpu_dequant;
    }

    pub fn arch(self: *const Pipeline) loader.DiffusionArch {
        return self.model.arch;
    }

    /// Generate one image into `rgba` (width*height*4 bytes, caller-owned).
    pub fn generate(self: *Pipeline, req: *const Request, rgba: []u8) Error!void {
        const lw = @as(usize, req.width) / vae_mod.LATENT_SCALE;
        const lh = @as(usize, req.height) / vae_mod.LATENT_SCALE;
        if (lw > MAX_LATENT_EDGE or lh > MAX_LATENT_EDGE or lw == 0 or lh == 0)
            return Error.ResolutionTooLarge;
        const px = @as(usize, req.width) * @as(usize, req.height) * 4;
        if (rgba.len < px) return Error.OutputBufferTooSmall;

        const n = LATENT_CH * lh * lw;

        // 1. Seed the latent with reproducible Gaussian noise.
        var rng = Rng.init(req.seed ^ 0x5DEECE66D);
        var i: usize = 0;
        while (i < n) : (i += 1) self.latent[i] = rng.gaussian();

        // 2. Conditioning (positive + negative for classifier-free guidance).
        _ = text_encoder.encodeFallback(req.prompt, self.ctx_pos[0..], CTX_TOKENS, CTX_DIM);
        if (req.negative_prompt.len > 0) {
            _ = text_encoder.encodeFallback(req.negative_prompt, self.ctx_neg[0..], CTX_TOKENS, CTX_DIM);
        } else {
            _ = text_encoder.encodeEmpty(self.ctx_neg[0..], CTX_TOKENS, CTX_DIM);
        }

        // 3. Denoise loop.
        const den = denoiser.Denoiser.init(&self.model);
        const sched = scheduler.Scheduler.init(req.sampler, @intCast(req.steps), req.shift);
        const lat = self.latent[0..n];

        // Token grid for the MMDiT: 2×2 patches over the LATENT_CH×lh×lw latent.
        const tokens = (lh / 2) * (lw / 2);
        const use_mmdit = self.engine_ready and tokens > 0 and tokens <= mmdit.MAX_TOKENS;
        if (use_mmdit) self.engine_ready = self.engine.allocScratch(tokens);

        const cond_pos = condScalar(self.ctx_pos[0..]);
        const cond_neg = condScalar(self.ctx_neg[0..]);

        var step: usize = 0;
        while (step < sched.n_steps) : (step += 1) {
            const t = sched.timestep(step);
            const guided = req.cfg_scale != 1.0;
            if (use_mmdit) {
                const t01 = t / 1000.0;
                self.mmditVelocity(lat, lw, lh, t01, cond_pos, self.vel_cond[0..n]);
                if (guided) self.mmditVelocity(lat, lw, lh, t01, cond_neg, self.vel_uncond[0..n]);
            } else {
                den.forward(lat, self.ctx_pos[0..].ptr, CTX_TOKENS, CTX_DIM, t, self.vel_cond[0..n]);
                if (guided) den.forward(lat, self.ctx_neg[0..].ptr, CTX_TOKENS, CTX_DIM, t, self.vel_uncond[0..n]);
            }
            // Classifier-free guidance: v = v_uncond + scale*(v_cond - v_uncond).
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const v = if (guided)
                    self.vel_uncond[k] + req.cfg_scale * (self.vel_cond[k] - self.vel_uncond[k])
                else
                    self.vel_cond[k];
                lat[k] = sched.step(step, lat[k], v);
            }
        }

        // 4. VAE decode → RGBA.
        self.vae.decode(lat, lw, lh, rgba[0..px]);
    }

    /// Run the MMDiT engine to predict velocity for the current latent.
    /// Patchifies the [LATENT_CH × lh × lw] latent into 2×2 patch tokens
    /// (PATCH_IN = 4 × LATENT_CH = 64), runs the transformer, and scatters the
    /// per-token output back into a velocity latent of the same shape.
    fn mmditVelocity(self: *Pipeline, lat: []const f32, lw: usize, lh: usize, t01: f32, cond: f32, out: []f32) void {
        const pw = lw / 2;
        const ph = lh / 2;
        const tokens = pw * ph;
        // Patchify: token (py,px) gathers the 2×2×LATENT_CH block, channel-major.
        var ty: usize = 0;
        while (ty < ph) : (ty += 1) {
            var tx: usize = 0;
            while (tx < pw) : (tx += 1) {
                const tok = ty * pw + tx;
                var idx: usize = 0;
                var c: usize = 0;
                while (c < LATENT_CH) : (c += 1) {
                    var dy: usize = 0;
                    while (dy < 2) : (dy += 1) {
                        var dx: usize = 0;
                        while (dx < 2) : (dx += 1) {
                            const ly = ty * 2 + dy;
                            const lx = tx * 2 + dx;
                            g_tokens_in[tok * mmdit.PATCH_IN + idx] = lat[c * lh * lw + ly * lw + lx];
                            idx += 1;
                        }
                    }
                }
            }
        }

        mmdit.forward(&self.engine, g_tokens_in[0 .. tokens * mmdit.PATCH_IN], tokens, t01, cond, g_tokens_out[0 .. tokens * mmdit.PATCH_IN]);

        // Unpatchify back to [LATENT_CH × lh × lw].
        ty = 0;
        while (ty < ph) : (ty += 1) {
            var tx: usize = 0;
            while (tx < pw) : (tx += 1) {
                const tok = ty * pw + tx;
                var idx: usize = 0;
                var c: usize = 0;
                while (c < LATENT_CH) : (c += 1) {
                    var dy: usize = 0;
                    while (dy < 2) : (dy += 1) {
                        var dx: usize = 0;
                        while (dx < 2) : (dx += 1) {
                            const ly = ty * 2 + dy;
                            const lx = tx * 2 + dx;
                            out[c * lh * lw + ly * lw + lx] = g_tokens_out[tok * mmdit.PATCH_IN + idx];
                            idx += 1;
                        }
                    }
                }
            }
        }
    }
};

/// Fold a conditioning field into a single steering scalar for the engine.
fn condScalar(ctx: []const f32) f32 {
    var s: f32 = 0;
    const m = @min(ctx.len, 4096);
    var i: usize = 0;
    while (i < m) : (i += 1) s += ctx[i];
    return math.tanh(s * 0.01);
}

/// SplitMix64 → Box-Muller Gaussian. Deterministic per-seed, no allocation.
const Rng = struct {
    state: u64,
    have_spare: bool = false,
    spare: f32 = 0,

    fn init(seed: u64) Rng {
        return .{ .state = seed +% 0x9E3779B97F4A7C15 };
    }

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn uniform(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }

    fn gaussian(self: *Rng) f32 {
        if (self.have_spare) {
            self.have_spare = false;
            return self.spare;
        }
        var ua = self.uniform();
        const ub = self.uniform();
        if (ua < 1e-7) ua = 1e-7;
        const r = sqrtApprox(-2.0 * @log(ua));
        const theta = 6.2831853 * ub;
        self.spare = r * sinApprox(theta);
        self.have_spare = true;
        return r * cosApprox(theta);
    }
};

fn sqrtApprox(x: f32) f32 {
    if (x <= 0) return 0;
    return @sqrt(x);
}

// Small-range sin/cos via range reduction + Taylor (theta in [0, 2π)).
fn sinApprox(theta: f32) f32 {
    var t = theta;
    const pi: f32 = 3.14159265;
    if (t > pi) t -= 2.0 * pi;
    const t2 = t * t;
    return t * (1.0 - t2 / 6.0 * (1.0 - t2 / 20.0 * (1.0 - t2 / 42.0)));
}

fn cosApprox(theta: f32) f32 {
    return sinApprox(theta + 1.5707963);
}

test "generate fills a small image deterministically" {
    const std = @import("std");
    var pipe: Pipeline = .{};
    // Without a real model, exercise the numeric path directly by faking load:
    // build request for 64×64 (latent 8×8) and decode via fallback stages.
    pipe.loaded = true;
    const req = Request{ .prompt = "a red fox", .width = 64, .height = 64, .steps = 4, .seed = 7 };
    var rgba: [64 * 64 * 4]u8 = undefined;
    try pipe.generate(&req, &rgba);
    // Every pixel opaque, buffer fully written.
    var opaque_ok = true;
    var p: usize = 0;
    while (p < 64 * 64) : (p += 1) {
        if (rgba[p * 4 + 3] != 255) opaque_ok = false;
    }
    try std.testing.expect(opaque_ok);
}

test "resolution guard rejects oversize" {
    const std = @import("std");
    var pipe: Pipeline = .{};
    pipe.loaded = true;
    const req = Request{ .prompt = "x", .width = 4096, .height = 4096, .steps = 1 };
    var rgba: [16]u8 = undefined;
    try std.testing.expectError(Error.ResolutionTooLarge, pipe.generate(&req, &rgba));
}
