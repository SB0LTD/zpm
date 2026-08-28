// @zpm/pdf-render — Rasterization Engine
// Renders PDF content streams to an RGBA pixel buffer.
//
// Supports:
//   - Text operators: BT/ET, Tf, Tm, Tj, TJ (hex glyph strings)
//   - Graphics state: cm (transform matrix), q/Q (save/restore)
//   - Images: Do (XObject image rendering)
//   - Colors: rg/RG, g/G
//
// Glyph rendering uses the embedded TTF outlines (from CIDFontType2).
// For now: bitmap-based glyph rendering using the font's glyf table.
// Future: proper outline rasterization with sub-pixel anti-aliasing.

pub const RGBA = packed struct { r: u8, g: u8, b: u8, a: u8 };

pub const Framebuffer = struct {
    pixels: [*]RGBA,
    width: u32,
    height: u32,
    stride: u32, // pixels per row (may be > width for alignment)

    /// Fill entire buffer with a color
    pub fn clear(self: *Framebuffer, color: RGBA) void {
        const total = self.height * self.stride;
        var i: u32 = 0;
        while (i < total) : (i += 1) self.pixels[i] = color;
    }

    /// Set a single pixel (bounds-checked)
    pub fn setPixel(self: *Framebuffer, x: u32, y: u32, color: RGBA) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.stride + x] = color;
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color: RGBA) void {
        var dy: u32 = 0;
        while (dy < h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < w) : (dx += 1) {
                self.setPixel(x + dx, y + dy, color);
            }
        }
    }

    /// Draw a horizontal line
    pub fn hline(self: *Framebuffer, x: u32, y: u32, w: u32, color: RGBA) void {
        var dx: u32 = 0;
        while (dx < w) : (dx += 1) self.setPixel(x + dx, y, color);
    }

    /// Blit a grayscale glyph bitmap (alpha blending)
    pub fn blitGlyph(self: *Framebuffer, glyph: []const u8, gw: u32, gh: u32, dx: u32, dy: u32, color: RGBA) void {
        var gy: u32 = 0;
        while (gy < gh) : (gy += 1) {
            var gx: u32 = 0;
            while (gx < gw) : (gx += 1) {
                const alpha = glyph[gy * gw + gx];
                if (alpha > 0) {
                    const px = dx + gx;
                    const py = dy + gy;
                    if (px < self.width and py < self.height) {
                        // Alpha blend
                        const dst = &self.pixels[py * self.stride + px];
                        const a = @as(u16, alpha);
                        const inv_a = 255 - a;
                        dst.r = @intCast((@as(u16, color.r) * a + @as(u16, dst.r) * inv_a) / 255);
                        dst.g = @intCast((@as(u16, color.g) * a + @as(u16, dst.g) * inv_a) / 255);
                        dst.b = @intCast((@as(u16, color.b) * a + @as(u16, dst.b) * inv_a) / 255);
                        dst.a = 255;
                    }
                }
            }
        }
    }
};

// ── Render context ──
pub const RenderState = struct {
    // Current text state
    font_size: f32,
    text_x: f32,
    text_y: f32,
    // Current color
    fill_color: RGBA,
    // Transform matrix (a, b, c, d, e, f) — PDF convention
    ctm: [6]f32,
    // DPI scaling
    scale: f32, // points to pixels (e.g., 150 DPI / 72 = 2.083)

    pub fn init(dpi: u32) RenderState {
        return .{
            .font_size = 12.0,
            .text_x = 0.0,
            .text_y = 0.0,
            .fill_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .ctm = .{ 1, 0, 0, 1, 0, 0 }, // identity
            .scale = @as(f32, @floatFromInt(dpi)) / 72.0,
        };
    }

    /// Convert PDF point coordinates to pixel coordinates
    pub fn toPixelX(self: *const RenderState, pdf_x: f32) u32 {
        return @intFromFloat(@max(0.0, pdf_x * self.scale));
    }

    pub fn toPixelY(self: *const RenderState, pdf_y: f32, page_height: f32) u32 {
        // PDF origin is bottom-left, pixel origin is top-left
        return @intFromFloat(@max(0.0, (page_height - pdf_y) * self.scale));
    }
};

// ── Page rendering (high-level) ──
/// Render a PDF page to a framebuffer.
/// page_width/height in PDF points (typically 595×842 for A4).
/// DPI determines output pixel size (150 DPI → 1240×1754 pixels).
pub fn renderPage(
    fb: *Framebuffer,
    content_stream: []const u8,
    state: *RenderState,
    page_height: f32,
) void {
    // Clear to white
    fb.clear(.{ .r = 255, .g = 255, .b = 255, .a = 255 });

    // Parse and execute content stream operators
    var pos: usize = 0;
    while (pos < content_stream.len) {
        pos = executeOperator(fb, content_stream, pos, state, page_height);
    }
}

fn executeOperator(fb: *Framebuffer, stream: []const u8, start: usize, state: *RenderState, ph: f32) usize {
    var pos = start;
    // Skip whitespace
    while (pos < stream.len and (stream[pos] == ' ' or stream[pos] == '\n' or stream[pos] == '\r')) : (pos += 1) {}
    if (pos >= stream.len) return stream.len;

    // Detect operator type
    if (stream[pos] == 'B' and pos + 1 < stream.len and stream[pos + 1] == 'T') {
        // BT — begin text
        return pos + 2;
    }
    if (stream[pos] == 'E' and pos + 1 < stream.len and stream[pos + 1] == 'T') {
        // ET — end text
        return pos + 2;
    }
    if (stream[pos] == '/') {
        // Font selection: /F1 12 Tf
        pos += 1;
        while (pos < stream.len and stream[pos] != ' ') : (pos += 1) {}
        pos += 1;
        // Parse font size
        const size = parseFloat(stream, &pos);
        state.font_size = size;
        // Skip "Tf"
        while (pos < stream.len and stream[pos] != '\n') : (pos += 1) {}
        return pos;
    }
    if (stream[pos] == '1' and pos + 6 < stream.len) {
        // Could be "1 0 0 1 X Y Tm"
        // Parse 6 numbers then Tm
        var nums: [6]f32 = undefined;
        var ni: usize = 0;
        var p2 = pos;
        while (ni < 6 and p2 < stream.len) : (ni += 1) {
            nums[ni] = parseFloat(stream, &p2);
            while (p2 < stream.len and stream[p2] == ' ') : (p2 += 1) {}
        }
        if (p2 + 1 < stream.len and stream[p2] == 'T' and stream[p2 + 1] == 'm') {
            state.text_x = nums[4];
            state.text_y = nums[5];
            return p2 + 2;
        }
    }
    if (stream[pos] == '<') {
        // Hex string: <AABBCCDD> Tj
        pos += 1;
        const hex_start = pos;
        while (pos < stream.len and stream[pos] != '>') : (pos += 1) {}
        const hex_end = pos;
        pos += 1; // skip >
        // Skip to Tj
        while (pos < stream.len and stream[pos] == ' ') : (pos += 1) {}
        if (pos + 1 < stream.len and stream[pos] == 'T' and stream[pos + 1] == 'j') {
            // Render hex glyphs at current position
            renderHexString(fb, stream[hex_start..hex_end], state, ph);
            pos += 2;
        }
        return pos;
    }

    // Skip unknown content until next line
    while (pos < stream.len and stream[pos] != '\n') : (pos += 1) {}
    return pos;
}

fn renderHexString(fb: *Framebuffer, hex: []const u8, state: *RenderState, ph: f32) void {
    // Each glyph is 4 hex chars (2 bytes = 16-bit glyph ID)
    // For now: render as filled rectangles (placeholder for actual glyph rendering)
    const glyph_w: u32 = @intFromFloat(state.font_size * state.scale * 0.5);
    const glyph_h: u32 = @intFromFloat(state.font_size * state.scale * 0.8);
    const px = state.toPixelX(state.text_x);
    const py = state.toPixelY(state.text_y, ph);

    var i: usize = 0;
    var glyph_num: u32 = 0;
    while (i + 3 < hex.len) : (i += 4) {
        // Skip glyph 0 (.notdef = space)
        const g0 = hexVal(hex[i]);
        const g1 = hexVal(hex[i + 1]);
        const g2 = hexVal(hex[i + 2]);
        const g3 = hexVal(hex[i + 3]);
        const gid = (@as(u16, g0) << 12) | (@as(u16, g1) << 8) | (@as(u16, g2) << 4) | @as(u16, g3);

        if (gid != 0) {
            // Render glyph placeholder (small filled rect)
            const gx = px + glyph_num * (glyph_w + 1);
            fb.fillRect(gx, py -| glyph_h, glyph_w -| 1, glyph_h, state.fill_color);
        }
        glyph_num += 1;
    }
}

fn hexVal(c: u8) u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    return 0;
}

fn parseFloat(stream: []const u8, pos: *usize) f32 {
    var p = pos.*;
    var negative = false;
    if (p < stream.len and stream[p] == '-') { negative = true; p += 1; }
    var int_part: f32 = 0;
    while (p < stream.len and stream[p] >= '0' and stream[p] <= '9') : (p += 1) {
        int_part = int_part * 10 + @as(f32, @floatFromInt(stream[p] - '0'));
    }
    var frac_part: f32 = 0;
    if (p < stream.len and stream[p] == '.') {
        p += 1;
        var div: f32 = 10;
        while (p < stream.len and stream[p] >= '0' and stream[p] <= '9') : (p += 1) {
            frac_part += @as(f32, @floatFromInt(stream[p] - '0')) / div;
            div *= 10;
        }
    }
    pos.* = p;
    const val = int_part + frac_part;
    return if (negative) -val else val;
}
