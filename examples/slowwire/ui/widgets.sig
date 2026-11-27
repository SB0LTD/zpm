//! Reusable glass cards and data-driven device widgets (Layer 3).
const prim = @import("primitives");
const Color = @import("color").Color;
const Font = @import("text").FontAtlas;
const theme = @import("ui_theme");
const model = @import("ui_model");
const Model = model.Model;
fn fy(height: f32, top: f32, scale: f32) f32 {
    return height - top - 14 * scale;
}
pub fn text(font: *const Font, height: f32, value: []const u8, x: f32, top: f32, scale: f32, color: Color) void {
    _ = font.drawString(value, x, fy(height, top, scale), scale, color);
}
pub fn panel(x: f32, top: f32, w: f32, h: f32, screen_h: f32, accent: Color) void {
    const y = screen_h - top - h;
    prim.rect(x, y, w, h, theme.glass);
    prim.line(x, y, x + w, y, 1, theme.stroke);
    prim.line(x, y + h, x + w, y + h, 1, theme.stroke);
    prim.line(x, y, x, y + h, 1, theme.stroke);
    prim.line(x + w, y, x + w, y + h, 1, theme.stroke);
    prim.gradientRect(x + 1, y + h - 2, w - 2, 1, accent.withAlpha(0), accent.withAlpha(0.8));
}
pub fn dot(x: f32, top: f32, radius: f32, screen_h: f32, color: Color) void {
    prim.glow(x, screen_h - top, radius * 3.2, color, 0.14);
    prim.circle(x, screen_h - top, radius, color);
}
pub fn pill(font: *const Font, height: f32, label: []const u8, x: f32, top: f32, width: f32, color: Color) void {
    const y = height - top - 24;
    prim.rect(x, y, width, 24, color.withAlpha(0.12));
    prim.line(x, y, x + width, y, 1, color.withAlpha(0.26));
    prim.line(x, y + 24, x + width, y + 24, 1, color.withAlpha(0.26));
    text(font, height, label, x + 10, top + 5, 0.68, color);
}
pub fn metric(font: *const Font, height: f32, x: f32, top: f32, w: f32, name: []const u8, value: []const u8, unit: []const u8, accent: Color) void {
    panel(x, top, w, 94, height, accent);
    dot(x + 17, top + 20, 3, height, accent);
    text(font, height, name, x + 30, top + 13, 0.66, theme.muted);
    text(font, height, value, x + 16, top + 40, 1.3, theme.text);
    if (unit.len != 0) text(font, height, unit, x + 84, top + 49, 0.65, theme.muted);
}
pub fn chart(font: *const Font, data: *const Model, x: f32, top: f32, w: f32, h: f32, screen_h: f32) void {
    panel(x, top, w, h, screen_h, theme.cyan);
    text(font, screen_h, "SINGLE-WIRE CAPACITIVE ELECTRODE", x + 20, top + 15, 0.70, theme.muted);
    text(font, screen_h, "Charge response", x + 20, top + 37, 0.92, theme.text);
    text(font, screen_h, "RELATIVE LOOP COUNTS", x + w - 173, top + 21, 0.60, theme.faint);
    const gx = x + 48;
    const gy = screen_h - top - h + 36;
    const gw = w - 68;
    const gh = h - 112;
    for (0..5) |i| {
        const fyv: f32 = @as(f32, @floatFromInt(i)) / 4;
        const yy = gy + fyv * gh;
        prim.line(gx, yy, gx + gw, yy, 1, theme.grid);
        var value: [5]u8 = undefined;
        const raw: u16 = @intFromFloat(fyv * 4095);
        const n = decimal(raw, &value);
        _ = font.drawString(value[0..n], x + 10, yy - 4, 0.56, theme.faint);
    }
    for (0..7) |i| {
        const xx = gx + gw * @as(f32, @floatFromInt(i)) / 6;
        prim.line(xx, gy, xx, gy + gh, 1, theme.grid);
    }
    if (data.sample_count > 1) {
        const range: f32 = 4095;
        for (1..data.sample_count) |i| {
            const ax = gx + gw * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(data.sample_count - 1));
            const bx = gx + gw * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(data.sample_count - 1));
            const av = @as(f32, @floatFromInt(data.sample(i - 1))) / range;
            const bv = @as(f32, @floatFromInt(data.sample(i))) / range;
            prim.line(ax, gy + av * gh, bx, gy + bv * gh, 2, theme.cyan.withAlpha(0.85));
        }
        const last = @as(f32, @floatFromInt(data.sample(data.sample_count - 1))) / range;
        prim.glow(gx + gw, gy + last * gh, 12, theme.cyan, 0.26);
        prim.circle(gx + gw, gy + last * gh, 3.5, theme.text);
    }
    text(font, screen_h, "LIVE DEVICE SAMPLE   ·   4 Hz", gx, top + h - 26, 0.6, theme.faint);
    text(font, screen_h, "Touch / near-field response · not a distance measurement", gx + 215, top + h - 26, 0.6, theme.amber);
}
pub fn eventFeed(font: *const Font, data: *const Model, x: f32, top: f32, w: f32, h: f32, screen_h: f32) void {
    panel(x, top, w, h, screen_h, theme.violet);
    text(font, screen_h, "SIGNAL TRACE", x + 16, top + 14, 0.68, theme.violet);
    const shown = @min(data.event_count, 7);
    for (0..shown) |j| {
        const index = data.event_count - shown + j;
        const event = data.eventAt(index);
        const color = switch (event.level) {
            .info => theme.muted,
            .success => theme.mint,
            .warning => theme.amber,
            .fault => theme.rose,
        };
        dot(x + 18, top + 48 + @as(f32, @floatFromInt(j)) * 25, 2.5, screen_h, color);
        text(font, screen_h, event.text[0..event.len], x + 30, top + 41 + @as(f32, @floatFromInt(j)) * 25, 0.65, color);
    }
}
fn decimal(value: u16, out: *[5]u8) usize {
    if (value == 0) {
        out[0] = '0';
        return 1;
    }
    var n: usize = 0;
    var v = value;
    while (v != 0) : (v /= 10) {
        out[n] = @intCast('0' + v % 10);
        n += 1;
    }
    for (0..n / 2) |i| {
        const j = n - i - 1;
        const temp = out[i];
        out[i] = out[j];
        out[j] = temp;
    }
    return n;
}
