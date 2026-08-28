// Playing card rendering — beautiful card visuals via GL primitives
// Layer 2: Render
//
// Renders playing cards as styled rectangles with rank/suit symbols.
// Cards have rounded corners (approximated), drop shadows, and glow effects.
// No textures needed — pure immediate-mode GL drawing.

const gl = @import("../platform/gl.sig");

/// Card suit
pub const Suit = enum(u2) { spades = 0, hearts = 1, diamonds = 2, clubs = 3 };

/// Card rank (0=2, 1=3, ..., 8=T, 9=J, 10=Q, 11=K, 12=A)
pub const Rank = u4;

/// Standard card dimensions
pub const CARD_W: f32 = 72;
pub const CARD_H: f32 = 100;
pub const CARD_RADIUS: f32 = 8;

/// Card colors
pub const RED = [4]f32{ 0.92, 0.22, 0.22, 1.0 };
pub const BLACK = [4]f32{ 0.12, 0.12, 0.16, 1.0 };
pub const CARD_FACE = [4]f32{ 0.98, 0.97, 0.95, 1.0 };
pub const CARD_BACK = [4]f32{ 0.15, 0.08, 0.45, 1.0 };
pub const CARD_BACK_PATTERN = [4]f32{ 0.22, 0.12, 0.55, 1.0 };
pub const CARD_SHADOW = [4]f32{ 0.0, 0.0, 0.0, 0.35 };
pub const CARD_GLOW_WIN = [4]f32{ 0.4, 1.0, 0.6, 0.4 };

pub const RANK_CHARS = [13]u8{ '2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A' };
pub const SUIT_CHARS = [4]u8{ 'S', 'H', 'D', 'C' }; // for text rendering

/// Draw a face-up card at (x, y) with optional glow.
pub fn drawCard(x: f32, y: f32, rank: Rank, suit: Suit, scale: f32, glow_intensity: f32) void {
    const w = CARD_W * scale;
    const h = CARD_H * scale;

    // Drop shadow (offset down-right)
    fillRoundedRect(x + 3 * scale, y - 3 * scale, w, h, CARD_RADIUS * scale, CARD_SHADOW);

    // Glow (behind card, larger)
    if (glow_intensity > 0.01) {
        const gw = w + 12 * scale * glow_intensity;
        const gh = h + 12 * scale * glow_intensity;
        const gx = x - 6 * scale * glow_intensity;
        const gy = y - 6 * scale * glow_intensity;
        const glow_color = [4]f32{ CARD_GLOW_WIN[0], CARD_GLOW_WIN[1], CARD_GLOW_WIN[2], CARD_GLOW_WIN[3] * glow_intensity };
        fillRoundedRect(gx, gy, gw, gh, (CARD_RADIUS + 4) * scale, glow_color);
    }

    // Card face
    fillRoundedRect(x, y, w, h, CARD_RADIUS * scale, CARD_FACE);

    // Suit color
    const color = if (suit == .hearts or suit == .diamonds) RED else BLACK;

    // Inner accent stripe (subtle)
    const stripe_h = h * 0.03;
    fillRect(x + 4 * scale, y + h - 6 * scale - stripe_h, w - 8 * scale, stripe_h, color);
}

/// Draw a face-down card at (x, y).
pub fn drawCardBack(x: f32, y: f32, scale: f32) void {
    const w = CARD_W * scale;
    const h = CARD_H * scale;

    // Shadow
    fillRoundedRect(x + 3 * scale, y - 3 * scale, w, h, CARD_RADIUS * scale, CARD_SHADOW);

    // Back
    fillRoundedRect(x, y, w, h, CARD_RADIUS * scale, CARD_BACK);

    // Inner pattern (diamond grid approximation)
    const margin = 6 * scale;
    fillRoundedRect(x + margin, y + margin, w - margin * 2, h - margin * 2, (CARD_RADIUS - 2) * scale, CARD_BACK_PATTERN);

    // Center diamond accent
    const cx = x + w / 2;
    const cy = y + h / 2;
    const diamond_size = 12 * scale;
    drawDiamond(cx, cy, diamond_size, .{ 0.85, 0.55, 0.08, 0.8 });
}

/// Draw the dealing animation card (rotated, moving)
pub fn drawCardDealing(x: f32, y: f32, scale: f32, rotation: f32) void {
    _ = rotation; // TODO: implement rotation via GL matrix
    drawCardBack(x, y, scale);
}

/// Draw a chip stack at position
pub fn drawChip(x: f32, y: f32, radius: f32, color: [4]f32) void {
    // Simplified chip as concentric circles
    drawCircle(x, y, radius + 1, .{ 0.0, 0.0, 0.0, 0.3 }); // shadow
    drawCircle(x, y, radius, color);
    drawCircle(x, y, radius * 0.7, .{ color[0] * 0.7, color[1] * 0.7, color[2] * 0.7, 1.0 });
    drawCircle(x, y, radius * 0.3, color);
}

// ── GL primitive helpers ────────────────────────────────────────────

fn fillRect(x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(x, y);
    gl.glVertex2f(x + w, y);
    gl.glVertex2f(x + w, y + h);
    gl.glVertex2f(x, y + h);
    gl.glEnd();
}

fn fillRoundedRect(x: f32, y: f32, w: f32, h: f32, r: f32, color: [4]f32) void {
    // Approximate rounded rect: center + four rounded corners via triangle fan
    gl.glColor4f(color[0], color[1], color[2], color[3]);

    // Inner rect (no corners)
    gl.glBegin(gl.QUADS);
    gl.glVertex2f(x + r, y);
    gl.glVertex2f(x + w - r, y);
    gl.glVertex2f(x + w - r, y + h);
    gl.glVertex2f(x + r, y + h);
    gl.glEnd();

    // Left strip
    gl.glBegin(gl.QUADS);
    gl.glVertex2f(x, y + r);
    gl.glVertex2f(x + r, y + r);
    gl.glVertex2f(x + r, y + h - r);
    gl.glVertex2f(x, y + h - r);
    gl.glEnd();

    // Right strip
    gl.glBegin(gl.QUADS);
    gl.glVertex2f(x + w - r, y + r);
    gl.glVertex2f(x + w, y + r);
    gl.glVertex2f(x + w, y + h - r);
    gl.glVertex2f(x + w - r, y + h - r);
    gl.glEnd();

    // Four corner arcs (8 segments each)
    drawCornerArc(x + r, y + r, r, 3.14159, 4.71239, color); // bottom-left
    drawCornerArc(x + w - r, y + r, r, 4.71239, 6.28318, color); // bottom-right
    drawCornerArc(x + w - r, y + h - r, r, 0, 1.5708, color); // top-right
    drawCornerArc(x + r, y + h - r, r, 1.5708, 3.14159, color); // top-left
}

fn drawCornerArc(cx: f32, cy: f32, r: f32, start_angle: f32, end_angle: f32, color: [4]f32) void {
    const SEGMENTS = 8;
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(cx, cy); // center
    const step = (end_angle - start_angle) / SEGMENTS;
    var i: u32 = 0;
    while (i <= SEGMENTS) : (i += 1) {
        const angle = start_angle + step * @as(f32, @floatFromInt(i));
        gl.glVertex2f(cx + @cos(angle) * r, cy + @sin(angle) * r);
    }
    gl.glEnd();
}

fn drawCircle(cx: f32, cy: f32, r: f32, color: [4]f32) void {
    const SEGMENTS = 24;
    gl.glBegin(gl.TRIANGLE_FAN);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(cx, cy);
    var i: u32 = 0;
    while (i <= SEGMENTS) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) * 6.28318 / SEGMENTS;
        gl.glVertex2f(cx + @cos(angle) * r, cy + @sin(angle) * r);
    }
    gl.glEnd();
}

fn drawDiamond(cx: f32, cy: f32, size: f32, color: [4]f32) void {
    gl.glBegin(gl.QUADS);
    gl.glColor4f(color[0], color[1], color[2], color[3]);
    gl.glVertex2f(cx, cy - size); // top
    gl.glVertex2f(cx + size * 0.6, cy); // right
    gl.glVertex2f(cx, cy + size); // bottom
    gl.glVertex2f(cx - size * 0.6, cy); // left
    gl.glEnd();
}
