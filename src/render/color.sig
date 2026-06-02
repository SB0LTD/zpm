// Color definitions and theme palette
// Layer 2: Atoms

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }
};

/// Trading dashboard dark theme
pub const theme = struct {
    // Backgrounds
    pub const bg_dark = Color{ .r = 0.04, .g = 0.04, .b = 0.08 };
    pub const bg_light = Color{ .r = 0.08, .g = 0.08, .b = 0.14 };

    // Grid
    pub const grid = Color{ .r = 0.2, .g = 0.25, .b = 0.35, .a = 0.3 };

    // Candles
    pub const bullish = Color{ .r = 0.0, .g = 0.85, .b = 0.55 };
    pub const bearish = Color{ .r = 0.9, .g = 0.2, .b = 0.3 };

    // Indicators
    pub const ma_line = Color{ .r = 0.2, .g = 0.7, .b = 1.0, .a = 0.7 };
    pub const price_level = Color{ .r = 0.2, .g = 0.7, .b = 1.0, .a = 0.4 };
    pub const glow = Color{ .r = 0.2, .g = 0.7, .b = 1.0 };
};

/// Vertex with position and color for line strip rendering.
pub const ColorVertex = struct {
    x: f32,
    y: f32,
    color: Color,
};
