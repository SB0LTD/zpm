// ZPM game UI material system
// Layer 2: reusable materials, depth, lighting, and component surfaces.
//
// The application renderer should compose these primitives instead of drawing
// isolated flat rectangles. Everything is allocation-free and compatible with
// the existing OpenGL immediate-mode backend.

const gl = @import("gl");

pub const Color = [4]f32;

pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Interaction = enum(u8) {
    idle,
    hover,
    pressed,
    disabled,
    selected,
};

pub const Theme = struct {
    // Foundation
    pub const backdrop = Color{ 0.010, 0.012, 0.028, 1.0 };
    pub const canvas = Color{ 0.018, 0.021, 0.046, 1.0 };
    pub const surface = Color{ 0.035, 0.040, 0.082, 0.96 };
    pub const surface_raised = Color{ 0.060, 0.066, 0.124, 0.98 };
    pub const surface_high = Color{ 0.090, 0.096, 0.170, 1.0 };

    // Brand light
    pub const violet = Color{ 0.62, 0.39, 1.00, 1.0 };
    pub const violet_hot = Color{ 0.78, 0.58, 1.00, 1.0 };
    pub const cyan = Color{ 0.22, 0.76, 1.00, 1.0 };
    pub const mint = Color{ 0.20, 0.94, 0.67, 1.0 };
    pub const amber = Color{ 1.00, 0.68, 0.20, 1.0 };
    pub const danger = Color{ 0.96, 0.20, 0.38, 1.0 };

    // Content
    pub const text = Color{ 0.94, 0.93, 1.00, 1.0 };
    pub const text_muted = Color{ 0.58, 0.57, 0.72, 0.90 };
    pub const stroke = Color{ 0.28, 0.27, 0.46, 0.58 };
    pub const highlight = Color{ 1.0, 1.0, 1.0, 0.16 };
    pub const shadow = Color{ 0.0, 0.0, 0.0, 0.46 };
};

pub fn withAlpha(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], alpha };
}

pub fn scaleRgb(color: Color, amount: f32) Color {
    return .{
        @min(color[0] * amount, 1.0),
        @min(color[1] * amount, 1.0),
        @min(color[2] * amount, 1.0),
        color[3],
    };
}

pub fn mix(a: Color, b: Color, t: f32) Color {
    const k = @min(@max(t, 0.0), 1.0);
    return .{
        a[0] + (b[0] - a[0]) * k,
        a[1] + (b[1] - a[1]) * k,
        a[2] + (b[2] - a[2]) * k,
        a[3] + (b[3] - a[3]) * k,
    };
}

// ── Geometry ───────────────────────────────────────────────────────

pub fn rect(box: Box, color: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(box.x, box.y);
    gl.glVertex2f(box.x + box.w, box.y);
    gl.glVertex2f(box.x + box.w, box.y + box.h);
    gl.glVertex2f(box.x, box.y + box.h);
    gl.glEnd();
}

pub fn gradientV(box: Box, bottom: Color, top: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(bottom[0], bottom[1], bottom[2], bottom[3]);
    gl.glVertex2f(box.x, box.y);
    gl.glVertex2f(box.x + box.w, box.y);
    gl.glColor4f(top[0], top[1], top[2], top[3]);
    gl.glVertex2f(box.x + box.w, box.y + box.h);
    gl.glVertex2f(box.x, box.y + box.h);
    gl.glEnd();
}

pub fn gradientH(box: Box, left: Color, right: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(left[0], left[1], left[2], left[3]);
    gl.glVertex2f(box.x, box.y);
    gl.glVertex2f(box.x, box.y + box.h);
    gl.glColor4f(right[0], right[1], right[2], right[3]);
    gl.glVertex2f(box.x + box.w, box.y + box.h);
    gl.glVertex2f(box.x + box.w, box.y);
    gl.glEnd();
}

pub fn rectOutline(box: Box, color: Color, width: f32) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_LOOP);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(box.x, box.y);
    gl.glVertex2f(box.x + box.w, box.y);
    gl.glVertex2f(box.x + box.w, box.y + box.h);
    gl.glVertex2f(box.x, box.y + box.h);
    gl.glEnd();
    gl.glLineWidth(1.0);
}

pub fn line(x1: f32, y1: f32, x2: f32, y2: f32, color: Color, width: f32) void {
    gl.glLineWidth(width);
    gl.glBegin(gl.LINES);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(x1, y1);
    gl.glVertex2f(x2, y2);
    gl.glEnd();
    gl.glLineWidth(1.0);
}

pub fn circle(cx: f32, cy: f32, radius: f32, color: Color) void {
    ellipse(cx, cy, radius, radius, color);
}

pub fn ellipse(cx: f32, cy: f32, rx: f32, ry: f32, color: Color) void {
    const segments = 64;
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 6.283185 / segments;
        gl.glVertex2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
    }
    gl.glEnd();
}

pub fn radialEllipse(cx: f32, cy: f32, rx: f32, ry: f32, center: Color, edge: Color) void {
    const segments = 64;
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(center[0], center[1], center[2], center[3]);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 6.283185 / segments;
        gl.glColor4f(edge[0], edge[1], edge[2], edge[3]);
        gl.glVertex2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
    }
    gl.glEnd();
}

pub fn ellipseOutline(cx: f32, cy: f32, rx: f32, ry: f32, color: Color, width: f32) void {
    const segments = 64;
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_LOOP);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    var i: u32 = 0;
    while (i < segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 6.283185 / segments;
        gl.glVertex2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
    }
    gl.glEnd();
    gl.glLineWidth(1.0);
}

pub fn arc(cx: f32, cy: f32, rx: f32, ry: f32, start: f32, end: f32, color: Color, width: f32) void {
    const segments = 40;
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_STRIP);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / segments;
        const angle = start + (end - start) * t;
        gl.glVertex2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
    }
    gl.glEnd();
    gl.glLineWidth(1.0);
}

pub fn roundedRect(box: Box, radius: f32, color: Color) void {
    const r = @min(radius, @min(box.w, box.h) / 2.0);
    rect(.{ .x = box.x + r, .y = box.y, .w = box.w - r * 2.0, .h = box.h }, color);
    rect(.{ .x = box.x, .y = box.y + r, .w = box.w, .h = box.h - r * 2.0 }, color);
    circle(box.x + r, box.y + r, r, color);
    circle(box.x + box.w - r, box.y + r, r, color);
    circle(box.x + r, box.y + box.h - r, r, color);
    circle(box.x + box.w - r, box.y + box.h - r, r, color);
}

// ── Materials and depth ────────────────────────────────────────────

pub fn glow(box: Box, radius: f32, color: Color, strength: f32) void {
    var layer: u8 = 4;
    while (layer > 0) : (layer -= 1) {
        const spread = @as(f32, @floatFromInt(layer)) * 4.0;
        const alpha = strength * (5.0 - @as(f32, @floatFromInt(layer))) * 0.035;
        roundedRect(.{
            .x = box.x - spread,
            .y = box.y - spread,
            .w = box.w + spread * 2.0,
            .h = box.h + spread * 2.0,
        }, radius + spread, withAlpha(color, alpha));
    }
}

pub fn panel(box: Box, radius: f32, base: Color, accent: Color, elevation: f32) void {
    // Deep ambient shadow and a tighter contact shadow create physical lift.
    roundedRect(.{ .x = box.x + elevation * 0.8, .y = box.y - elevation * 1.35, .w = box.w, .h = box.h }, radius + 1.0, withAlpha(Theme.shadow, 0.22 + elevation * 0.025));
    roundedRect(.{ .x = box.x + 1.0, .y = box.y - 3.0, .w = box.w, .h = box.h }, radius, withAlpha(Theme.shadow, 0.42));

    // Body, upper light wash, perimeter, and contact highlights.
    roundedRect(box, radius, base);
    roundedRect(.{ .x = box.x + 1.0, .y = box.y + box.h * 0.48, .w = box.w - 2.0, .h = box.h * 0.52 - 1.0 }, @max(radius - 1.0, 1.0), withAlpha(scaleRgb(base, 1.42), 0.24));
    roundedRect(.{ .x = box.x + 1.0, .y = box.y + 1.0, .w = box.w - 2.0, .h = box.h - 2.0 }, @max(radius - 1.0, 1.0), withAlpha(Theme.backdrop, 0.08));
    roundedOutline(box, radius, withAlpha(accent, 0.52), 1.0);
    line(box.x + radius, box.y + box.h - 1.5, box.x + box.w - radius, box.y + box.h - 1.5, withAlpha(Theme.highlight, 0.66), 1.0);
    line(box.x + radius, box.y + 1.5, box.x + box.w - radius, box.y + 1.5, withAlpha(Theme.shadow, 0.62), 1.0);
}

pub fn inset(box: Box, radius: f32, base: Color, accent: Color) void {
    roundedRect(box, radius, withAlpha(Theme.shadow, 0.56));
    roundedRect(.{ .x = box.x + 1.0, .y = box.y - 1.0, .w = box.w - 2.0, .h = box.h }, @max(radius - 1.0, 1.0), base);
    roundedOutline(box, radius, withAlpha(accent, 0.34), 1.0);
    line(box.x + radius, box.y + box.h - 1.0, box.x + box.w - radius, box.y + box.h - 1.0, withAlpha(Theme.shadow, 0.68), 1.0);
}

pub fn buttonSurface(box: Box, radius: f32, color: Color, state: Interaction) void {
    const active = state == .hover or state == .selected;
    const pressed = state == .pressed;
    const disabled = state == .disabled;
    const lift: f32 = if (pressed) 1.0 else 4.0;
    const body = if (disabled) mix(color, Theme.surface, 0.68) else if (active) scaleRgb(color, 1.18) else color;

    if (active and !disabled) glow(box, radius, color, 0.78);
    roundedRect(.{ .x = box.x, .y = box.y - lift, .w = box.w, .h = box.h }, radius, withAlpha(scaleRgb(color, 0.38), 0.90));
    roundedRect(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, radius, body);
    roundedRect(.{ .x = box.x + 2.0, .y = box.y + box.h * 0.54, .w = box.w - 4.0, .h = box.h * 0.42 }, @max(radius - 2.0, 1.0), withAlpha(Theme.highlight, if (disabled) 0.04 else 0.15));
    roundedOutline(box, radius, withAlpha(if (active) Theme.text else scaleRgb(color, 1.35), if (disabled) 0.16 else 0.55), 1.0);
}

pub fn badge(box: Box, color: Color) void {
    roundedRect(box, box.h / 2.0, withAlpha(scaleRgb(color, 0.26), 0.92));
    roundedOutline(box, box.h / 2.0, withAlpha(color, 0.62), 1.0);
}

pub fn divider(x: f32, y: f32, width: f32, accent: Color) void {
    gradientH(.{ .x = x, .y = y, .w = width, .h = 1.0 }, withAlpha(accent, 0.0), withAlpha(accent, 0.70));
    gradientH(.{ .x = x + width, .y = y, .w = width, .h = 1.0 }, withAlpha(accent, 0.70), withAlpha(accent, 0.0));
}

pub fn diamond(cx: f32, cy: f32, radius: f32, color: Color) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(cx, cy - radius);
    gl.glVertex2f(cx + radius, cy);
    gl.glVertex2f(cx, cy + radius);
    gl.glVertex2f(cx - radius, cy);
    gl.glEnd();
}

pub fn roundedOutline(box: Box, radius: f32, color: Color, width: f32) void {
    const r = @min(radius, @min(box.w, box.h) / 2.0);
    const segments = 9;
    gl.glLineWidth(width);
    gl.glBegin(gl.LINE_LOOP);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    var corner: u32 = 0;
    while (corner < 4) : (corner += 1) {
        const center_x = if (corner == 0 or corner == 3) box.x + r else box.x + box.w - r;
        const center_y = if (corner < 2) box.y + r else box.y + box.h - r;
        const start_angle: f32 = switch (corner) {
            0 => 3.141593,
            1 => 4.712389,
            2 => 0.0,
            else => 1.570796,
        };
        var i: u32 = 0;
        while (i <= segments) : (i += 1) {
            const angle = start_angle + @as(f32, @floatFromInt(i)) * 1.570796 / segments;
            gl.glVertex2f(center_x + @cos(angle) * r, center_y + @sin(angle) * r);
        }
    }
    gl.glEnd();
    gl.glLineWidth(1.0);
}

// A subtle perspective grid gives large empty canvases spatial depth without
// competing with content. It is intentionally sparse and low alpha.
pub fn perspectiveGrid(box: Box, vanishing_x: f32, vanishing_y: f32, color: Color) void {
    var i: u8 = 0;
    while (i <= 10) : (i += 1) {
        const x = box.x + box.w * @as(f32, @floatFromInt(i)) / 10.0;
        line(vanishing_x, vanishing_y, x, box.y, withAlpha(color, 0.10), 1.0);
    }
    var row: u8 = 0;
    while (row < 6) : (row += 1) {
        const t = @as(f32, @floatFromInt(row + 1)) / 7.0;
        const eased = t * t;
        const y = vanishing_y + (box.y - vanishing_y) * eased;
        line(box.x, y, box.x + box.w, y, withAlpha(color, 0.08 + t * 0.05), 1.0);
    }
}
