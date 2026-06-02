// Pure math utilities — no I/O, no rendering
// Layer 0: Foundation

/// Linear interpolation
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Smooth step (3t²-2t³) — ease in/out curve for 0..1 range
pub fn smoothstep(t: f32) f32 {
    const c = @min(@max(t, 0.0), 1.0);
    return c * c * (3.0 - 2.0 * c);
}

/// Fast sine approximation (Bhaskara I, accurate to ~0.2% for animation use)
pub fn sinApprox(x_in: f32) f32 {
    const pi: f32 = 3.14159265;
    const two_pi: f32 = 6.28318530;

    var x = x_in - @floor(x_in / two_pi) * two_pi;
    if (x < 0) x += two_pi;

    var sign: f32 = 1.0;
    if (x > pi) {
        x -= pi;
        sign = -1.0;
    }

    const num = 16.0 * x * (pi - x);
    const den = 5.0 * pi * pi - 4.0 * x * (pi - x);
    return sign * num / den;
}

/// Organic value in 0..1 from layered sine waves (avoids repetitive look)
pub fn organicWave(t: f32, seed: f32) f32 {
    const a = sinApprox(t * 0.7 + seed) * 0.5;
    const b = sinApprox(t * 1.3 + seed * 2.17) * 0.3;
    const c = sinApprox(t * 2.1 + seed * 0.73) * 0.2;
    const raw = (a + b + c + 1.0) * 0.5;
    return @min(@max(raw, 0.0), 1.0);
}

/// Smooth upward-trending price path with organic noise.
/// Uses incommensurate frequencies so the pattern doesn't visibly repeat.
/// Result is in 0..1 range (clamped).
pub fn bullishPrice(t: f32, speed: f32) f32 {
    const s = t * speed;

    // Multiple rising waves at irrational-ratio frequencies — never repeats visibly
    // Each contributes a different "momentum regime"
    const trend1 = (sinApprox(s * 0.13) + 1.0) * 0.5; // very slow ~48s cycle
    const trend2 = (sinApprox(s * 0.31 + 1.0) + 1.0) * 0.5; // ~20s cycle
    const trend3 = (sinApprox(s * 0.071 + 3.0) + 1.0) * 0.5; // ultra slow ~88s

    // Weighted blend — slow components dominate for overall upward shape
    const base = trend3 * 0.45 + trend1 * 0.35 + trend2 * 0.20;

    // Medium noise — creates the candle-to-candle variation
    const n1 = sinApprox(s * 1.7 + 2.7) * 0.06;
    const n2 = sinApprox(s * 2.9 + 7.3) * 0.04;

    // Fast micro-noise — tiny jitter so adjacent candles aren't too smooth
    const n3 = sinApprox(s * 5.3 + 11.1) * 0.02;

    const raw = base + n1 + n2 + n3;
    return @min(@max(raw, 0.0), 1.0);
}

/// A mini OHLC candle derived from a price path, suitable for decorative rendering.
pub const MiniCandle = struct {
    open: f32,
    close: f32,
    high: f32,
    low: f32,
    bullish: bool,
};

/// Generate a mini candle by sampling the bullish price path at two time points.
/// `t` is the candle's start time, `dt` is candle duration, `seed` adds per-candle variation.
pub fn miniCandle(t: f32, dt: f32, seed: f32) MiniCandle {
    const open = bullishPrice(t, 1.0);
    const close = bullishPrice(t + dt, 1.0);

    // Wicks: small extensions beyond body, varied per candle
    const wick_ext_lo = organicWave(t * 0.5, seed + 20.0) * 0.04 + 0.01;
    const wick_ext_hi = organicWave(t * 0.6, seed + 30.0) * 0.04 + 0.01;

    const body_lo = @min(open, close);
    const body_hi = @max(open, close);

    return .{
        .open = open,
        .close = close,
        .high = @min(body_hi + wick_ext_hi, 1.0),
        .low = @max(body_lo - wick_ext_lo, 0.0),
        .bullish = close >= open,
    };
}
