// Bitmap font atlas — renders system font to GL texture at init, then draws textured quads
// Uses Win32 GDI for rasterization, zero external dependencies
// Layer 2: Atoms

const gl = @import("gl");
const w32 = @import("win32");
const Color = @import("color").Color;

const FIRST_CHAR: u8 = 32; // space
const LAST_CHAR: u8 = 126; // tilde
const GLYPH_COUNT: usize = LAST_CHAR - FIRST_CHAR + 1;

/// Per-glyph metrics stored after atlas creation
const GlyphInfo = struct {
    u0: f32, // texture coords
    v0: f32,
    u1: f32,
    v1: f32,
    width: f32, // pixel width of this glyph
    advance: f32, // how far to move cursor after drawing
};

pub const FontAtlas = struct {
    texture_id: u32 = 0,
    glyphs: [GLYPH_COUNT]GlyphInfo = undefined,
    char_height: f32 = 0,
    atlas_w: i32 = 0,
    atlas_h: i32 = 0,

    /// Create font atlas from a Win32 system font.
    /// Call once at startup after GL context is created.
    pub fn init(font_name: ?w32.LPCWSTR, font_size: i32) FontAtlas {
        var self = FontAtlas{};

        // Create GDI font
        const hfont = w32.CreateFontW(
            -font_size,
            0,
            0,
            0,
            w32.FW_NORMAL,
            0,
            0,
            0, // no italic/underline/strikeout
            w32.DEFAULT_CHARSET,
            w32.OUT_TT_PRECIS,
            w32.CLIP_DEFAULT_PRECIS,
            w32.CLEARTYPE_QUALITY,
            0,
            font_name,
        ) orelse return self;

        // Create memory DC
        const hdc = w32.CreateCompatibleDC(null) orelse return self;
        _ = w32.SelectObject(hdc, @ptrCast(hfont));
        _ = w32.SetTextColor(hdc, 0x00FFFFFF); // white text
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        // Get metrics
        var tm: w32.TEXTMETRICW = .{};
        _ = w32.GetTextMetricsW(hdc, &tm);
        self.char_height = @floatFromInt(tm.tmHeight);

        // Measure all glyphs to determine atlas size
        var abc_widths: [GLYPH_COUNT]w32.ABC = undefined;
        _ = w32.GetCharABCWidthsW(hdc, FIRST_CHAR, LAST_CHAR, &abc_widths);

        // Calculate atlas dimensions — single row for simplicity
        var total_w: i32 = 0;
        for (0..GLYPH_COUNT) |i| {
            const abc = abc_widths[i];
            const gw = abc.abcA + @as(i32, @intCast(abc.abcB)) + abc.abcC;
            total_w += @max(gw, tm.tmAveCharWidth) + 2; // 2px padding
        }
        self.atlas_w = total_w;
        self.atlas_h = tm.tmHeight + 2;

        // Create DIB section (32-bit BGRA bitmap)
        var bmi = w32.BITMAPINFO{
            .bmiHeader = .{
                .biWidth = self.atlas_w,
                .biHeight = -self.atlas_h, // top-down
                .biBitCount = 32,
                .biCompression = w32.BI_RGB,
            },
        };
        var bits: ?*anyopaque = null;
        const hbmp = w32.CreateDIBSection(hdc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse return self;
        _ = w32.SelectObject(hdc, @ptrCast(hbmp));

        // Re-select font after bitmap selection
        _ = w32.SelectObject(hdc, @ptrCast(hfont));
        _ = w32.SetTextColor(hdc, 0x00FFFFFF);
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        // Render each glyph
        var cursor_x: i32 = 1;
        const aw: f32 = @floatFromInt(self.atlas_w);
        const ah: f32 = @floatFromInt(self.atlas_h);

        for (0..GLYPH_COUNT) |i| {
            const ch: u16 = @intCast(FIRST_CHAR + i);
            const char_buf = [1]u16{ch};

            // Get exact size
            var sz: w32.SIZE = .{};
            _ = w32.GetTextExtentPoint32W(hdc, &char_buf, 1, &sz);

            // Draw glyph
            _ = w32.TextOutW(hdc, cursor_x, 1, &char_buf, 1);

            const gw: f32 = @floatFromInt(sz.cx);
            self.glyphs[i] = .{
                .u0 = @as(f32, @floatFromInt(cursor_x)) / aw,
                .v0 = 0.0,
                .u1 = @as(f32, @floatFromInt(cursor_x)) / aw + gw / aw,
                .v1 = @as(f32, @floatFromInt(sz.cy)) / ah,
                .width = gw,
                .advance = gw + 1.0,
            };

            cursor_x += sz.cx + 2;
        }

        // Extract alpha channel from BGRA bitmap and upload to GL
        const pixel_count: usize = @intCast(self.atlas_w * self.atlas_h);
        const bgra: [*]const u8 = @ptrCast(bits.?);

        // We'll reuse the same memory — write alpha-only into the first pixel_count bytes
        const alpha_buf: [*]u8 = @ptrCast(bits.?);
        for (0..pixel_count) |pi| {
            // Use the blue channel as alpha (white text = all channels equal)
            alpha_buf[pi] = bgra[pi * 4];
        }

        // Upload to OpenGL
        gl.glGenTextures(1, &self.texture_id);
        gl.glBindTexture(gl.TEXTURE_2D, self.texture_id);
        gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl.TEXTURE_2D, 0, @intCast(gl.ALPHA), self.atlas_w, self.atlas_h, 0, gl.ALPHA, gl.UNSIGNED_BYTE, @ptrCast(alpha_buf));
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.glBindTexture(gl.TEXTURE_2D, 0);

        // Cleanup GDI
        _ = w32.DeleteObject(@ptrCast(hbmp));
        _ = w32.DeleteObject(@ptrCast(hfont));
        _ = w32.DeleteDC(hdc);

        return self;
    }

    pub fn deinit(self: *FontAtlas) void {
        if (self.texture_id != 0) {
            gl.glDeleteTextures(1, &self.texture_id);
            self.texture_id = 0;
        }
    }

    /// Draw a string at (x, y) with given color and scale.
    /// y is the baseline (bottom of text).
    pub fn drawString(self: *const FontAtlas, str: []const u8, x: f32, y: f32, scale: f32, color: Color) f32 {
        if (self.texture_id == 0) return 0;

        gl.glEnable(gl.TEXTURE_2D);
        gl.glBindTexture(gl.TEXTURE_2D, self.texture_id);
        gl.glColor4f(color.r, color.g, color.b, color.a);

        gl.glBegin(gl.QUADS);
        var cx = x;
        const h = self.char_height * scale;
        for (str) |ch| {
            if (ch < FIRST_CHAR or ch > LAST_CHAR) {
                cx += 4.0 * scale; // space for unknown chars
                continue;
            }
            const gi = self.glyphs[ch - FIRST_CHAR];
            const w = gi.width * scale;

            gl.glTexCoord2f(gi.u0, gi.v0);
            gl.glVertex2f(cx, y + h);
            gl.glTexCoord2f(gi.u1, gi.v0);
            gl.glVertex2f(cx + w, y + h);
            gl.glTexCoord2f(gi.u1, gi.v1);
            gl.glVertex2f(cx + w, y);
            gl.glTexCoord2f(gi.u0, gi.v1);
            gl.glVertex2f(cx, y);

            cx += gi.advance * scale;
        }
        gl.glEnd();

        gl.glBindTexture(gl.TEXTURE_2D, 0);
        gl.glDisable(gl.TEXTURE_2D);

        return cx - x;
    }

    /// Draw a formatted number. Returns width drawn.
    pub fn drawNumber(self: *const FontAtlas, value: f64, decimals: u8, x: f32, y: f32, scale: f32, color: Color) f32 {
        var buf: [32]u8 = undefined;
        const len = formatFloat(&buf, value, decimals);
        return self.drawString(buf[0..len], x, y, scale, color);
    }

    /// Measure a formatted number width without drawing
    pub fn measureNumber(self: *const FontAtlas, value: f64, decimals: u8, scale: f32) f32 {
        var buf: [32]u8 = undefined;
        const len = formatFloat(&buf, value, decimals);
        return self.measureString(buf[0..len], scale);
    }

    /// Measure string width without drawing
    pub fn measureString(self: *const FontAtlas, str: []const u8, scale: f32) f32 {
        var w: f32 = 0;
        for (str) |ch| {
            if (ch < FIRST_CHAR or ch > LAST_CHAR) {
                w += 4.0 * scale;
                continue;
            }
            w += self.glyphs[ch - FIRST_CHAR].advance * scale;
        }
        return w;
    }
};

/// Format f64 into a fixed-decimal ASCII string. Returns length.
fn formatFloat(buf: []u8, value: f64, decimals: u8) usize {
    var pos: usize = 0;
    var v = value;

    if (v < 0) {
        buf[pos] = '-';
        pos += 1;
        v = -v;
    }

    var int_part: u64 = @intFromFloat(v);
    var frac = v - @as(f64, @floatFromInt(int_part));

    // Integer digits
    if (int_part == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var tmp: [20]u8 = undefined;
        var tlen: usize = 0;
        while (int_part > 0) : (int_part /= 10) {
            tmp[tlen] = @intCast(int_part % 10 + '0');
            tlen += 1;
        }
        var ri = tlen;
        while (ri > 0) : (ri -= 1) {
            buf[pos] = tmp[ri - 1];
            pos += 1;
        }
    }

    if (decimals > 0) {
        buf[pos] = '.';
        pos += 1;
        var d: u8 = 0;
        while (d < decimals) : (d += 1) {
            frac *= 10.0;
            const digit: u8 = @intFromFloat(frac);
            buf[pos] = digit + '0';
            pos += 1;
            frac -= @as(f64, @floatFromInt(digit));
        }
    }

    return pos;
}
