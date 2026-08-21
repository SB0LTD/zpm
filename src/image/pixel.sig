// pixel.sig — RGBA pixel type and color operations
// Layer 0: Pure computation

/// RGBA pixel — 4 bytes, packed for direct memory layout
pub const RGBA = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent = RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black = RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white = RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 };

    /// Create an opaque RGB pixel
    pub fn rgb(r: u8, g: u8, b: u8) RGBA {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// Create an RGBA pixel
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) RGBA {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Parse a hex color string (6 chars, with or without leading #)
    pub fn fromHex(hex: []const u8) ?RGBA {
        if (hex.len < 6) return null;
        const start: usize = if (hex[0] == '#') 1 else 0;
        if (hex.len - start < 6) return null;
        const r = parseHexByte(hex[start..][0..2]) orelse return null;
        const g = parseHexByte(hex[start + 2 ..][0..2]) orelse return null;
        const b = parseHexByte(hex[start + 4 ..][0..2]) orelse return null;
        return RGBA.rgb(r, g, b);
    }

    /// Alpha-blend `src` over `self` (Porter-Duff src-over)
    pub fn blend(dst: RGBA, src: RGBA) RGBA {
        if (src.a == 255) return src;
        if (src.a == 0) return dst;

        const sa: u16 = src.a;
        const inv_sa: u16 = 255 - sa;

        return .{
            .r = @intCast((@as(u16, src.r) * sa + @as(u16, dst.r) * inv_sa) / 255),
            .g = @intCast((@as(u16, src.g) * sa + @as(u16, dst.g) * inv_sa) / 255),
            .b = @intCast((@as(u16, src.b) * sa + @as(u16, dst.b) * inv_sa) / 255),
            .a = @intCast(@min(255, @as(u16, dst.a) + sa)),
        };
    }

    /// Multiply brightness by a factor
    pub fn brighten(self: RGBA, factor: f32) RGBA {
        return .{
            .r = clampFloat(@as(f32, @floatFromInt(self.r)) * factor),
            .g = clampFloat(@as(f32, @floatFromInt(self.g)) * factor),
            .b = clampFloat(@as(f32, @floatFromInt(self.b)) * factor),
            .a = self.a,
        };
    }

    /// Adjust saturation (1.0 = unchanged, 0.0 = grayscale, >1.0 = more vivid)
    pub fn saturate(self: RGBA, factor: f32) RGBA {
        const gray: f32 = (@as(f32, @floatFromInt(self.r)) * 0.299 +
            @as(f32, @floatFromInt(self.g)) * 0.587 +
            @as(f32, @floatFromInt(self.b)) * 0.114);
        return .{
            .r = clampFloat(gray + (@as(f32, @floatFromInt(self.r)) - gray) * factor),
            .g = clampFloat(gray + (@as(f32, @floatFromInt(self.g)) - gray) * factor),
            .b = clampFloat(gray + (@as(f32, @floatFromInt(self.b)) - gray) * factor),
            .a = self.a,
        };
    }

    /// Apply opacity (multiply alpha)
    pub fn withOpacity(self: RGBA, opacity: f32) RGBA {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = clampFloat(@as(f32, @floatFromInt(self.a)) * opacity),
        };
    }
};

/// Linear interpolation between two colors
pub fn lerpColor(a: RGBA, b: RGBA, t: f32) RGBA {
    const inv_t = 1.0 - t;
    return .{
        .r = clampFloat(@as(f32, @floatFromInt(a.r)) * inv_t + @as(f32, @floatFromInt(b.r)) * t),
        .g = clampFloat(@as(f32, @floatFromInt(a.g)) * inv_t + @as(f32, @floatFromInt(b.g)) * t),
        .b = clampFloat(@as(f32, @floatFromInt(a.b)) * inv_t + @as(f32, @floatFromInt(b.b)) * t),
        .a = clampFloat(@as(f32, @floatFromInt(a.a)) * inv_t + @as(f32, @floatFromInt(b.a)) * t),
    };
}

// ── Helpers ──

fn clampFloat(v: f32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intFromFloat(v);
}

fn parseHexByte(hex: *const [2]u8) ?u8 {
    const hi = hexDigit(hex[0]) orelse return null;
    const lo = hexDigit(hex[1]) orelse return null;
    return hi * 16 + lo;
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}
