// Icon texture loader — .ico bytes → GL texture
// Layer 2: Atoms
//
// Generic icon loading from embedded .ico data. Source-agnostic:
// callers provide the raw bytes, this module handles Win32 GDI
// rasterization and GL texture upload.

const gl = @import("gl");
const w32 = @import("win32");

pub const IconTexture = struct {
    texture_id: u32 = 0,
    size: f32 = 0,

    /// Load an icon texture from raw .ico file bytes at the given pixel size.
    pub fn initFromIco(ico_data: [*]const u8, ico_len: usize, size: i32) IconTexture {
        var self = IconTexture{ .size = @floatFromInt(size) };

        const offset = w32.LookupIconIdFromDirectoryEx(ico_data, 1, size, size, 0);
        if (offset <= 0) return self;
        const off: usize = @intCast(offset);
        if (off >= ico_len) return self;

        const hicon: w32.HICON = @ptrCast(w32.CreateIconFromResourceEx(
            ico_data + off,
            @intCast(ico_len - off),
            1,
            0x00030000,
            size,
            size,
            0,
        ));
        if (hicon == null) return self;

        const hdc = w32.CreateCompatibleDC(null) orelse return self;
        var bmi = w32.BITMAPINFO{
            .bmiHeader = .{ .biWidth = size, .biHeight = -size, .biBitCount = 32, .biCompression = w32.BI_RGB },
        };
        var bits: ?*anyopaque = null;
        const hbmp = w32.CreateDIBSection(hdc, &bmi, w32.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w32.DeleteDC(hdc);
            _ = w32.DestroyIcon(hicon);
            return self;
        };
        _ = w32.SelectObject(hdc, @ptrCast(hbmp));
        _ = w32.DrawIconEx(hdc, 0, 0, hicon, size, size, 0, null, w32.DI_NORMAL);

        // BGRA → RGBA swizzle
        const pixel_data: [*]u8 = @ptrCast(bits.?);
        const pixel_count: usize = @intCast(size * size);
        for (0..pixel_count) |i| {
            const b = pixel_data[i * 4];
            pixel_data[i * 4] = pixel_data[i * 4 + 2];
            pixel_data[i * 4 + 2] = b;
        }

        gl.glGenTextures(1, &self.texture_id);
        gl.glBindTexture(gl.TEXTURE_2D, self.texture_id);
        gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA), size, size, 0, gl.RGBA, gl.UNSIGNED_BYTE, @ptrCast(pixel_data));
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.glBindTexture(gl.TEXTURE_2D, 0);

        _ = w32.DeleteObject(@ptrCast(hbmp));
        _ = w32.DeleteDC(hdc);
        _ = w32.DestroyIcon(hicon);
        return self;
    }

    /// Draw the icon centered at (cx, cy) with the given display size and alpha.
    pub fn drawAt(self: *const IconTexture, cx: f32, cy: f32, display_size: f32, alpha: f32) void {
        if (self.texture_id == 0) return;
        const half = display_size * 0.5;
        gl.glEnable(gl.TEXTURE_2D);
        gl.glBindTexture(gl.TEXTURE_2D, self.texture_id);
        gl.glColor4f(1, 1, 1, alpha);
        gl.glBegin(gl.QUADS);
        gl.glTexCoord2f(0, 0);
        gl.glVertex2f(cx - half, cy + half);
        gl.glTexCoord2f(1, 0);
        gl.glVertex2f(cx + half, cy + half);
        gl.glTexCoord2f(1, 1);
        gl.glVertex2f(cx + half, cy - half);
        gl.glTexCoord2f(0, 1);
        gl.glVertex2f(cx - half, cy - half);
        gl.glEnd();
        gl.glBindTexture(gl.TEXTURE_2D, 0);
        gl.glDisable(gl.TEXTURE_2D);
    }

    pub fn deinit(self: *IconTexture) void {
        if (self.texture_id != 0) {
            gl.glDeleteTextures(1, &self.texture_id);
            self.texture_id = 0;
        }
    }
};
