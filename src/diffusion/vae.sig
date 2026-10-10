// @zpm/diffusion — VAE latent → RGB decode.
//
// The diffusion loop works in a compressed latent space (typically 16 channels
// at 1/8 spatial resolution). The VAE decoder upsamples that latent to an RGB
// image. The full decoder is a conv-resnet stack whose weights live in the VAE
// safetensors; running it needs those weights bound.
//
// This module implements the decode *contract* (latent[C,h,w] → rgba[H,W,4],
// H=h*scale, W=w*scale) with a deterministic tiled-upsample fallback so the
// pipeline produces a real image buffer before the conv weights are wired.
// `bound()` reports whether the true decoder weights were resolved.

const math = @import("sig_math");

pub const LATENT_SCALE: usize = 8; // pixels per latent cell (each edge)
pub const LATENT_CHANNELS: usize = 16;

pub const Vae = struct {
    weights: ?*const anyopaque = null,
    scale: usize = LATENT_SCALE,
    channels: usize = LATENT_CHANNELS,

    pub fn init() Vae {
        return .{};
    }

    pub fn bound(self: *const Vae) bool {
        return self.weights != null;
    }

    /// Decode latent[channels * lh * lw] into rgba[(lh*scale)*(lw*scale)*4].
    /// The fallback maps the first 3 latent channels to RGB with a smooth
    /// bilinear upsample and a tanh tone-map, producing a coherent image whose
    /// structure follows the denoised latent.
    pub fn decode(self: *const Vae, latent: []const f32, lw: usize, lh: usize, rgba: []u8) void {
        const s = self.scale;
        const ow = lw * s;
        const oh = lh * s;
        const c = self.channels;
        var y: usize = 0;
        while (y < oh) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(s));
            const ly0 = @min(@as(usize, @intFromFloat(fy)), lh - 1);
            const ly1 = @min(ly0 + 1, lh - 1);
            const wy = fy - @as(f32, @floatFromInt(ly0));
            var x: usize = 0;
            while (x < ow) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(s));
                const lx0 = @min(@as(usize, @intFromFloat(fx)), lw - 1);
                const lx1 = @min(lx0 + 1, lw - 1);
                const wx = fx - @as(f32, @floatFromInt(lx0));

                var ch: usize = 0;
                var rgb: [3]f32 = .{ 0, 0, 0 };
                while (ch < 3) : (ch += 1) {
                    const base = ch * lh * lw;
                    const v00 = latent[base + ly0 * lw + lx0];
                    const v01 = latent[base + ly0 * lw + lx1];
                    const v10 = latent[base + ly1 * lw + lx0];
                    const v11 = latent[base + ly1 * lw + lx1];
                    const top = v00 * (1 - wx) + v01 * wx;
                    const bot = v10 * (1 - wx) + v11 * wx;
                    rgb[ch] = top * (1 - wy) + bot * wy;
                }
                _ = c;
                const px = (y * ow + x) * 4;
                rgba[px + 0] = toU8(rgb[0]);
                rgba[px + 1] = toU8(rgb[1]);
                rgba[px + 2] = toU8(rgb[2]);
                rgba[px + 3] = 255;
            }
        }
    }
};

/// Map a latent value (roughly [-4,4]) to 0..255 via tanh tone-mapping.
fn toU8(v: f32) u8 {
    const t = (math.tanh(v * 0.5) + 1.0) * 0.5; // 0..1
    const scaled = t * 255.0;
    const clamped = math.clamp(scaled, 0.0, 255.0);
    return @intFromFloat(clamped);
}

test "decode fills the full rgba buffer with valid alpha" {
    const std = @import("std");
    var vae = Vae.init();
    // 16 channels × 2×2 latent → 16×16 image.
    var latent: [16 * 2 * 2]f32 = @splat(0.3);
    var rgba: [16 * 16 * 4]u8 = undefined;
    vae.decode(&latent, 2, 2, &rgba);
    var px: usize = 0;
    while (px < 16 * 16) : (px += 1) {
        try std.testing.expectEqual(@as(u8, 255), rgba[px * 4 + 3]);
    }
}
