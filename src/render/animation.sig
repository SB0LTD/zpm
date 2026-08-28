// Animation easing and interpolation — smooth motion primitives
// Layer 2: Render (pure math, no platform deps beyond timing)
//
// Provides easing functions, spring physics, and interpolation
// for smooth UI transitions. All functions are pure — caller manages time.

/// Easing functions — input t is 0.0 to 1.0, output is eased value
pub const Ease = struct {
    /// Linear (no easing)
    pub fn linear(t: f32) f32 { return t; }

    /// Cubic ease-out — fast start, smooth deceleration
    pub fn outCubic(t: f32) f32 {
        const x = 1.0 - t;
        return 1.0 - x * x * x;
    }

    /// Cubic ease-in — slow start, fast end
    pub fn inCubic(t: f32) f32 { return t * t * t; }

    /// Cubic ease-in-out — smooth start and end
    pub fn inOutCubic(t: f32) f32 {
        return if (t < 0.5) 4.0 * t * t * t
        else 1.0 - blk: {
            const x = -2.0 * t + 2.0;
            break :blk x * x * x / 2.0;
        };
    }

    /// Exponential ease-out — snappy, very smooth tail
    pub fn outExpo(t: f32) f32 {
        return if (t >= 1.0) 1.0 else 1.0 - pow2(-10.0 * t);
    }

    /// Elastic ease-out — overshoot with bounce
    pub fn outElastic(t: f32) f32 {
        if (t <= 0.0) return 0.0;
        if (t >= 1.0) return 1.0;
        const c4 = 6.283185 / 3.0; // 2π/3
        return pow2(-10.0 * t) * @sin((t * 10.0 - 0.75) * c4) + 1.0;
    }

    /// Back ease-out — slight overshoot then settle
    pub fn outBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3 = c1 + 1.0;
        const x = t - 1.0;
        return 1.0 + c3 * x * x * x + c1 * x * x;
    }

    /// Bounce ease-out
    pub fn outBounce(t: f32) f32 {
        var x = t;
        if (x < 1.0 / 2.75) return 7.5625 * x * x;
        if (x < 2.0 / 2.75) { x -= 1.5 / 2.75; return 7.5625 * x * x + 0.75; }
        if (x < 2.5 / 2.75) { x -= 2.25 / 2.75; return 7.5625 * x * x + 0.9375; }
        x -= 2.625 / 2.75;
        return 7.5625 * x * x + 0.984375;
    }
};

/// Interpolate between two values using an easing function.
pub fn lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * t;
}

/// Interpolate with easing applied to t.
pub fn lerpEased(from: f32, to: f32, t: f32, comptime ease_fn: fn (f32) f32) f32 {
    return from + (to - from) * ease_fn(clamp01(t));
}

/// Spring interpolation — overshoots then settles (damped oscillation).
/// stiffness: higher = faster, damping: higher = less bounce
pub const Spring = struct {
    position: f32 = 0,
    velocity: f32 = 0,
    target: f32 = 0,
    stiffness: f32 = 180.0,
    damping: f32 = 12.0,

    pub fn update(self: *Spring, dt: f32) void {
        const force = -self.stiffness * (self.position - self.target);
        const damping_force = -self.damping * self.velocity;
        self.velocity += (force + damping_force) * dt;
        self.position += self.velocity * dt;
    }

    pub fn isSettled(self: *const Spring) bool {
        return @abs(self.position - self.target) < 0.01 and @abs(self.velocity) < 0.01;
    }

    pub fn setTarget(self: *Spring, target: f32) void {
        self.target = target;
    }

    pub fn snap(self: *Spring, value: f32) void {
        self.position = value;
        self.target = value;
        self.velocity = 0;
    }
};

/// Timed animation — tracks progress over a duration.
pub const Tween = struct {
    elapsed: f32 = 0,
    duration: f32 = 0.3,
    active: bool = false,

    pub fn start(self: *Tween, dur: f32) void {
        self.elapsed = 0;
        self.duration = dur;
        self.active = true;
    }

    pub fn update(self: *Tween, dt: f32) void {
        if (!self.active) return;
        self.elapsed += dt;
        if (self.elapsed >= self.duration) {
            self.elapsed = self.duration;
            self.active = false;
        }
    }

    pub fn progress(self: *const Tween) f32 {
        if (self.duration <= 0) return 1.0;
        return clamp01(self.elapsed / self.duration);
    }

    pub fn isDone(self: *const Tween) bool {
        return !self.active;
    }
};

/// Pulse animation — oscillates 0→1→0 continuously
pub fn pulse(time: f32, frequency: f32) f32 {
    return (@sin(time * frequency * 6.283185) + 1.0) * 0.5;
}

/// Glow intensity — ramps up fast, fades slow
pub fn glow(t: f32) f32 {
    return Ease.outExpo(t) * (1.0 - t * t);
}

fn clamp01(v: f32) f32 {
    return @max(0.0, @min(1.0, v));
}

fn pow2(x: f32) f32 {
    // Approximate 2^x using exp(x * ln2)
    return @exp(x * 0.693147);
}
