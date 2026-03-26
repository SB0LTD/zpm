// GPU drawing primitives — the atoms of all rendering
// Layer 2: Atoms

const gl = @import("gl");
const Color = @import("color").Color;
pub const ColorVertex = @import("color").ColorVertex;

/// Draw a filled rectangle.
pub fn rect(x: f32, y: f32, w: f32, h: f32, color: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

/// Draw a vertical gradient quad (bottom_color at y, top_color at y+h).
pub fn gradientRect(x: f32, y: f32, w: f32, h: f32, bottom: Color, top_color: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor3f(bottom.r, bottom.g, bottom.b);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glColor3f(top_color.r, top_color.g, top_color.b);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

/// Draw a horizontal line that fades from transparent (left) to full alpha (right).
/// `fade_start` is the x where the fade begins; line is fully opaque from fade_start to x2.
pub fn fadingLineH(x1: f32, x2: f32, y: f32, width: f32, color: Color, fade_start: f32) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x1, y);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(fade_start, y);
    gl.glEnd();
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(fade_start, y);
    gl.glVertex2f(x2, y);
    gl.glEnd();
}

/// Draw a horizontal glow band — a soft vertical gradient rect centered on y.
/// `half_h` is the half-height of the band, alpha falls off toward edges.
pub fn glowBandH(x1: f32, x2: f32, y: f32, half_h: f32, color: Color, fade_start: f32) void {
    const w = x2 - x1;
    if (w <= 0 or half_h <= 0) return;
    // Draw as a quad with alpha: 0 at top/bottom edges, peak at center
    // Use two quads: bottom half and top half, each with gradient
    const fade_w = @max(fade_start - x1, 1.0);

    gl.glBegin(gl.QUADS);
    // Bottom half (y to y - half_h): alpha 0 at bottom, peak at center
    // Left side (fading in)
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x1, y - half_h);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x1, y);
    gl.glColor4f(color.r, color.g, color.b, color.a * (1.0 - @min((fade_start - x1) / fade_w, 1.0)));
    gl.glVertex2f(fade_start, y);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(fade_start, y - half_h);

    // Right side (full alpha)
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(fade_start, y - half_h);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(fade_start, y);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(x2, y);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x2, y - half_h);

    // Top half (y to y + half_h)
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x1, y);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x1, y + half_h);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(fade_start, y + half_h);
    gl.glColor4f(color.r, color.g, color.b, color.a * (1.0 - @min((fade_start - x1) / fade_w, 1.0)));
    gl.glVertex2f(fade_start, y);

    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(fade_start, y);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(fade_start, y + half_h);
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    gl.glVertex2f(x2, y + half_h);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(x2, y);
    gl.glEnd();
}

/// Draw an expanding ripple ring (circle outline with alpha that fades as it expands).
/// `phase` is 0..1 — 0=just born (small, bright), 1=fully expanded (large, invisible).
pub fn rippleRing(cx: f32, cy: f32, max_radius: f32, phase: f32, color: Color) void {
    const segs: usize = 48;
    const radius = max_radius * phase;
    const alpha = color.a * (1.0 - phase) * (1.0 - phase); // quadratic fade
    if (alpha < 0.005) return;
    gl.glLineWidth(1.5);
    gl.glBegin(gl.LINE_LOOP);
    gl.glColor4f(color.r, color.g, color.b, alpha);
    for (0..segs) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 6.28318;
        gl.glVertex2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    gl.glEnd();
}

/// Draw a single line segment.
pub fn line(x1: f32, y1: f32, x2: f32, y2: f32, width: f32, color: Color) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(x1, y1);
    gl.glVertex2f(x2, y2);
    gl.glEnd();
}

/// Draw a horizontal dashed line.
pub fn dashedLineH(x1: f32, x2: f32, y: f32, dash_len: f32, gap_len: f32, width: f32, color: Color) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    var x: f32 = x1;
    while (x < x2) : (x += dash_len + gap_len) {
        gl.glVertex2f(x, y);
        gl.glVertex2f(@min(x + dash_len, x2), y);
    }
    gl.glEnd();
}

/// Draw a vertical dashed line.
pub fn dashedLineV(x: f32, y1: f32, y2: f32, dash_len: f32, gap_len: f32, width: f32, color: Color) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    var y: f32 = y1;
    while (y < y2) : (y += dash_len + gap_len) {
        gl.glVertex2f(x, y);
        gl.glVertex2f(x, @min(y + dash_len, y2));
    }
    gl.glEnd();
}

/// Draw a single candlestick (wick + body) centered at cx.
pub fn candle(cx: f32, wick_lo: f32, wick_hi: f32, body_bot: f32, body_top: f32, body_w: f32, body_color: Color, wick_color: Color) void {
    // Wick (thin vertical line)
    line(cx, wick_lo, cx, wick_hi, 1.0, wick_color);
    // Body (filled rect)
    const h = @max(body_top - body_bot, 1.5);
    rect(cx - body_w * 0.5, body_bot, body_w, h, body_color);
}

/// Draw a soft glow circle (triangle fan with alpha falloff).
pub fn glow(cx: f32, cy: f32, radius: f32, color: Color, intensity: f32) void {
    const segs: usize = 32;
    gl.glBegin(gl.TRIANGLE_FAN);
    // Center: bright
    gl.glColor4f(color.r, color.g, color.b, 0.25 * intensity);
    gl.glVertex2f(cx, cy);
    // Edge: transparent
    gl.glColor4f(color.r, color.g, color.b, 0.0);
    for (0..segs + 1) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 6.28318;
        gl.glVertex2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    gl.glEnd();
}

/// Draw a filled circle centered at (cx, cy).
pub fn circle(cx: f32, cy: f32, radius: f32, color: Color) void {
    const segs: usize = 24;
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(cx, cy);
    for (0..segs + 1) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs)) * 6.28318;
        gl.glVertex2f(cx + @cos(angle) * radius, cy + @sin(angle) * radius);
    }
    gl.glEnd();
}

/// Draw a connected line strip from an array of (x,y,color) vertices.
/// Caller builds the vertex array, this handles the GL calls.
pub fn lineStrip(verts: []const ColorVertex, width: f32) void {
    if (verts.len < 2) return;
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_STRIP);
    for (verts) |v| {
        gl.glColor4f(v.color.r, v.color.g, v.color.b, v.color.a);
        gl.glVertex2f(v.x, v.y);
    }
    gl.glEnd();
}

/// Draw disconnected line segments from an array of (x,y) pairs with a single color.
/// Every two consecutive vertices form one segment.
pub fn lineSegments(verts: []const [2]f32, width: f32, color: Color) void {
    if (verts.len < 2) return;
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    for (verts) |v| {
        gl.glVertex2f(v[0], v[1]);
    }
    gl.glEnd();
}

/// Draw a rounded rectangle using triangle fans for corners.
/// `r` is the corner radius (clamped to half the smallest dimension).
pub fn roundedRect(x: f32, y: f32, w: f32, h: f32, r_in: f32, color: Color) void {
    const r = @min(r_in, @min(w * 0.5, h * 0.5));
    if (r < 1.0) {
        rect(x, y, w, h, color);
        return;
    }
    gl.glColor4f(color.r, color.g, color.b, color.a);

    // Center cross (two rects)
    rect(x + r, y, w - 2 * r, h, color);
    rect(x, y + r, r, h - 2 * r, color);
    rect(x + w - r, y + r, r, h - 2 * r, color);

    // Four corner arcs (triangle fans)
    const segs: usize = 8;
    const pi_half: f32 = 1.5707963;
    cornerArc(x + r, y + r, r, pi_half * 2, pi_half * 3, segs, color); // bottom-left
    cornerArc(x + w - r, y + r, r, pi_half * 3, pi_half * 4, segs, color); // bottom-right
    cornerArc(x + w - r, y + h - r, r, 0, pi_half, segs, color); // top-right
    cornerArc(x + r, y + h - r, r, pi_half, pi_half * 2, segs, color); // top-left
}

fn cornerArc(cx: f32, cy: f32, r: f32, start: f32, end: f32, segs: usize, color: Color) void {
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    gl.glVertex2f(cx, cy);
    const step = (end - start) / @as(f32, @floatFromInt(segs));
    for (0..segs + 1) |i| {
        const angle = start + step * @as(f32, @floatFromInt(i));
        gl.glVertex2f(cx + @cos(angle) * r, cy + @sin(angle) * r);
    }
    gl.glEnd();
}

/// Draw a rounded rectangle outline (border only).
pub fn roundedRectOutline(x: f32, y: f32, w: f32, h: f32, r_in: f32, width: f32, color: Color) void {
    const r = @min(r_in, @min(w * 0.5, h * 0.5));
    if (r < 1.0) {
        line(x, y, x + w, y, width, color);
        line(x, y + h, x + w, y + h, width, color);
        line(x, y, x, y + h, width, color);
        line(x + w, y, x + w, y + h, width, color);
        return;
    }
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_LOOP);
    gl.glColor4f(color.r, color.g, color.b, color.a);
    const segs: usize = 8;
    const pi_half: f32 = 1.5707963;
    // Bottom-left arc
    arcVerts(x + r, y + r, r, pi_half * 2, pi_half * 3, segs);
    // Bottom-right arc
    arcVerts(x + w - r, y + r, r, pi_half * 3, pi_half * 4, segs);
    // Top-right arc
    arcVerts(x + w - r, y + h - r, r, 0, pi_half, segs);
    // Top-left arc
    arcVerts(x + r, y + h - r, r, pi_half, pi_half * 2, segs);
    gl.glEnd();
}

fn arcVerts(cx: f32, cy: f32, r: f32, start: f32, end: f32, segs: usize) void {
    const step = (end - start) / @as(f32, @floatFromInt(segs));
    for (0..segs + 1) |i| {
        const angle = start + step * @as(f32, @floatFromInt(i));
        gl.glVertex2f(cx + @cos(angle) * r, cy + @sin(angle) * r);
    }
}

/// Enable scissor test for a rectangular region.
pub fn scissorBegin(x: f32, y: f32, w: f32, h: f32) void {
    gl.glEnable(gl.SCISSOR_TEST);
    gl.glScissor(@intFromFloat(x), @intFromFloat(y), @intFromFloat(w), @intFromFloat(h));
}

/// Disable scissor test.
pub fn scissorEnd() void {
    gl.glDisable(gl.SCISSOR_TEST);
}
